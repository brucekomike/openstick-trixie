#!/usr/bin/env bash
# Pull everything that makes the stick restorable. Device side is READ-ONLY except for
# scratch files under /var/tmp on the stick, which are md5-verified and removed.
#
# What each artifact protects against:
#   boot-stock.bin   -> rollback for any kernel/boot.img experiment (the only copy)
#   firmware chain   -> EDL recovery if the boot chain is ever rewritten
#   modemst*/fsg/fsc -> IMEI + RF calibration; losing these costs the radio permanently
#   lib-firmware.*   -> /lib/firmware holds the modem/DSP blobs: this board has NO modem
#                       partition, so a new rootfs without them boots with no LTE
#   kernel-boot.*    -> the 5.15 kernel is a vendor .deb, absent from every repo
#   usr-bin-adbd/gc  -> neither is dpkg-owned; without a copy adb is gone after an upgrade
#
# Default stops before the big rootfs copy; add --rootfs for it.
. "$(dirname "$0")/lib.sh"
mkdir -p "$BACKUP"
WANT_ROOTFS=0
if [ "${1:-}" = "--rootfs" ]; then WANT_ROOTFS=1; fi

require_device
log "target $BACKUP"
log "checking scratch space on the stick for staging"
FREE_DEV=$(dev_avail_mb)
if [ "${FREE_DEV:-0}" -lt 800 ]; then
  die "only ${FREE_DEV}MB free on the stick - binary pulls need ~800MB of scratch at $STAGE_DIR.*"
fi
echo "  ${FREE_DEV}MB free on / (staging under $STAGE_DIR.*, removed after each pull)"

# pull_part <label> <host-file>  - exact partition copy: dd to stick scratch, adb pull, md5
pull_part() {
  local label="$1" host="$2" want got staged
  if [ -s "$host" ]; then echo "  have $(basename "$host")"; return 0; fi
  want=$(dev "blockdev --getsize64 /dev/disk/by-partlabel/$label" | tr -dc '0-9')
  if [ -z "$want" ]; then warn "no partition labelled $label - skipped"; return 1; fi
  staged=$(dev_write "dd if=/dev/disk/by-partlabel/$label bs=4M" "$label") || return 1
  if [ "${staged:-0}" != "$want" ]; then
    warn "$label: staged $staged bytes but partition is $want - dd did not read it all"
    dev "rm -f $STAGE_DIR.$label" >/dev/null; return 1
  fi
  pull "$label" "$host" || return 1
  got=$(stat -c %s "$host")
  echo "  $label: $want bytes -> $(basename "$host") ($got)"
  if [ "$got" != "$want" ]; then warn "$label size mismatch - do not trust this copy"; return 1; fi
}

log "1/6 boot partition (64 MiB, exact)"
pull_part "$BOOT_PARTLABEL" "$BACKUP/boot-stock.bin" || die "boot backup failed - nothing else is safe without it"

log "2/6 firmware chain + calibration partitions"
FAILED_CHAIN=""
for n in $FIRMWARE_PARTS $CALIB_PARTS; do
  pull_part "$n" "$BACKUP/part-${n}.bin" || FAILED_CHAIN="$FAILED_CHAIN $n"
done
if [ -n "$FAILED_CHAIN" ]; then
  warn "these did not back up:$FAILED_CHAIN"
  warn "Do not flash the boot chain or repartition until they are present - they are the
  only path back from a bad aboot/sbl1, and the only copy of the radio calibration."
fi

log "3/6 /lib/firmware (modem + wcn36xx blobs)"
if [ ! -s "$BACKUP/lib-firmware.tar.zst" ]; then
  dev_write "tar -C / -cf - lib/firmware" "fw" >/dev/null || die "tar of /lib/firmware failed"
  pull "fw" "$BACKUP/lib-firmware.tar" || die "pull of firmware tar failed"
  zstd -q -19 -o "$BACKUP/lib-firmware.tar.zst" "$BACKUP/lib-firmware.tar" && rm -f "$BACKUP/lib-firmware.tar"
  echo "  $(du -h "$BACKUP/lib-firmware.tar.zst" | cut -f1) compressed"
else
  echo "  already have lib-firmware.tar.zst"
fi

log "4/6 vendor kernel (/lib/modules/$KVER + /boot)"
if [ ! -s "$BACKUP/kernel-boot.tar.zst" ]; then
  dev_write "tar -C / -cf - lib/modules/$KVER boot" "kern" >/dev/null || die "tar of kernel failed"
  pull "kern" "$BACKUP/kernel-boot.tar" || die "pull of kernel tar failed"
  zstd -q -12 -o "$BACKUP/kernel-boot.tar.zst" "$BACKUP/kernel-boot.tar" && rm -f "$BACKUP/kernel-boot.tar"
  echo "  $(du -h "$BACKUP/kernel-boot.tar.zst" | cut -f1)"
else
  echo "  already have kernel-boot.tar.zst"
fi

log "5/6 adbd + gadget tool (not owned by any package)"
for pair in "/usr/bin/adbd:usr-bin-adbd" "/usr/bin/gc:usr-bin-gc" "/usr/sbin/mobian-usb-gadget:mobian-usb-gadget"; do
  p=${pair%%:*}; name=${pair##*:}
  if [ -s "$BACKUP/$name" ]; then echo "  have $name"; continue; fi
  if dev "test -x $p; echo yes" | grep -q yes; then
    "${ADB_BIN[@]}" pull "$p" "$BACKUP/$name" >/dev/null 2>&1 &&
      echo "  $p -> $name ($(stat -c %s "$BACKUP/$name") bytes)" || warn "pull $p failed"
    # Verify what came over the wire is the kind of file we expected. `mobian-usb-gadget`
    # is a shell script, so an ELF-only test would cry corrupt over a perfectly good copy.
    desc=$(file -b "$BACKUP/$name" 2>/dev/null || echo "unknown (file not installed)")
    case "$desc" in
      *ELF*|*script*|*text*) echo "  ok: $desc" ;;
      *) warn "$name looks wrong: $desc" ;;
    esac
  else
    warn "$p absent on device"
  fi
done
dev "ls -lR /sys/kernel/config/usb_gadget/g1; echo UDC=\$(cat /sys/kernel/config/usb_gadget/g1/UDC); ls /sys/class/udc" > "$BACKUP/gadget-live.txt"

log "6/6 rootfs"
if [ "$WANT_ROOTFS" = 1 ]; then
  [ "${COMMIT:-0}" = "1" ] || die "raw rootfs copy takes minutes and needs ~3.4G of scratch: rerun with COMMIT=1 --rootfs"
  echo "  raw block copy of $ROOT_DEV"
  echo "  A crash-consistent image is only as good as e2fsck after restore, and fsfreeze /"
  echo "  on a running stick blocks journald AND adb - it then looks hung with no way back"
  echo "  except power. For a quiescent image read it from EDL/fastboot instead:"
  echo "    edl r rootfs rootfs.bin"
  if [ "${FSFREEZE:-0}" = 1 ]; then
    warn "FSFREEZE=1 accepted - adb will stop responding during the copy. Only do this with"
    warn "a serial console attached to ttyMSM0."
    dev "fsfreeze -f /"
  fi
  if [ "${FREE_DEV:-0}" -lt 3600 ]; then
    die "raw copy needs 3.4G of scratch and / has ${FREE_DEV}MB free - read it from EDL instead"
  fi
  dev_write "dd if=$ROOT_DEV bs=4M" "rootfs.img" >/dev/null || die "raw dd failed"
  pull "rootfs.img" "$BACKUP/rootfs-raw.bin" || die "pull of raw rootfs failed"
  if [ "${FSFREEZE:-0}" = 1 ]; then dev "fsfreeze -u /"; fi
  pigz -1 -p 4 "$BACKUP/rootfs-raw.bin" && echo "  $(du -h "$BACKUP/rootfs-raw.bin.gz" | cut -f1) compressed"
else
  if [ ! -s "$BACKUP/rootfs-files.tar.zst" ] && [ ! -s "$BACKUP/rootfs-files.tar.gz" ]; then
    echo "  file-level snapshot, gzip'd on the stick (fits in scratch, ~10 min over adb)"
    dev_write "tar -C / --one-file-system -czf - --exclude=./proc --exclude=./sys --exclude=./dev --exclude=./run --exclude=./tmp --exclude=./var/tmp ." "rootfs.tar.gz" >/dev/null ||
      die "device-side tar failed"
    pull "rootfs.tar.gz" "$BACKUP/rootfs-files.tar.gz" || die "pull failed"
    if zstd -q -12 -T0 -o "$BACKUP/rootfs-files.tar.zst" "$BACKUP/rootfs-files.tar.gz"; then
      rm -f "$BACKUP/rootfs-files.tar.gz"
    else
      warn "zstd re-encode failed - keeping rootfs-files.tar.gz as the archive"
    fi
    du -h "$BACKUP"/rootfs-files.tar.* 2>/dev/null | sed 's/^/  /'
  else
    echo "  already have the rootfs file-level archive"
  fi
fi

log "checksums"
( cd "$BACKUP" && sha256sum * 2>/dev/null > MANIFEST.sha256 && echo "  MANIFEST.sha256: $(wc -l < MANIFEST.sha256) entries" )
log "verify the boot image parses"
python3 "$ROOT/tools/bootimg.py" info "$BACKUP/boot-stock.bin" | sed 's/^/  /'
warn "backup/ is gitignored - it holds IMEI-bearing partitions and vendor binaries."
echo "Done. Route A may start; anything that touches boot/rootfs needs this directory."
