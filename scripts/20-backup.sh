#!/usr/bin/env bash
# Pull everything that makes the stick restorable. Device side is READ-ONLY.
#
# What this protects against:
#   boot-stock.bin   -> rollback for any kernel/boot.img experiment (the only copy)
#   firmware chain   -> EDL recovery if the boot chain is ever rewritten
#   modemst*/fsg/fsc -> IMEI + RF calibration; losing these costs the radio permanently
#   firmware.tar.zst -> /lib/firmware holds the modem/DSP blobs: this board has NO
#                       modem partition, so a new rootfs without them boots with no LTE
#   modules+boot     -> the 5.15 kernel is a vendor .deb, absent from every repo
#   adbd + gc        -> neither is dpkg-owned; without a copy adb is gone after an upgrade
#
# Default stops before the big rootfs copy; add --rootfs for it (see README).
. "$(dirname "$0")/lib.sh"
mkdir -p "$BACKUP"
WANT_ROOTFS=0
if [ "${1:-}" = "--rootfs" ]; then WANT_ROOTFS=1; fi

require_device
log "target $BACKUP"

# 1. the boot partition, byte exact (64 MiB)
log "1/6 boot partition (64 MiB, exact)"
if [ -s "$BACKUP/boot-stock.bin" ]; then
  echo "  already have it: $(sha256sum "$BACKUP/boot-stock.bin" | cut -c1-16)..."
else
  adb_cmd exec-out "dd if=/dev/$BOOT_PARTLABEL bs=1M 2>/dev/null" > "$BACKUP/boot-stock.bin" ||
    die "dd of boot failed"
  echo "  $(stat -c %s "$BACKUP/boot-stock.bin") bytes"
fi

# 2. boot chain + calibration partitions
log "2/6 firmware chain + calibration partitions"
for n in $FIRMWARE_PARTS $CALIB_PARTS; do
  f="$BACKUP/part-${n}.bin"
  if [ -s "$f" ]; then echo "  have ${n}"; continue; fi
  sz=$(adb_cmd shell "blockdev --getsize64 /dev/disk/by-partlabel/$n 2>/dev/null" | tr -d '\r ')
  [ -n "$sz" ] || { warn "no partition labelled $n - skipped"; continue; }
  adb_cmd exec-out "dd if=/dev/disk/by-partlabel/$n bs=1M 2>/dev/null" > "$f"
  got=$(stat -c %s "$f")
  echo "  $n: want $sz got $got bytes"
  [ "$got" = "$sz" ] || warn "$n size mismatch - do not trust this copy"
done

# 3. modem/DSP firmware that has no partition of its own
log "3/6 /lib/firmware (modem + wcn36xx blobs)"
if [ ! -s "$BACKUP/lib-firmware.tar.zst" ]; then
  adb_cmd exec-out "tar -C / -cf - lib/firmware" > "$BACKUP/lib-firmware.tar.zst.tmp"
  zstd -q -19 -o "$BACKUP/lib-firmware.tar.zst" "$BACKUP/lib-firmware.tar.zst.tmp" &&
    rm -f "$BACKUP/lib-firmware.tar.zst.tmp"
  echo "  $(du -h "$BACKUP/lib-firmware.tar.zst" | cut -f1) compressed"
else
  echo "  already have lib-firmware.tar.zst"
fi

# 4. the vendor kernel: package files + /boot, so a new rootfs can carry modules
log "4/6 vendor kernel (/lib/modules/$KVER + /boot)"
if [ ! -s "$BACKUP/kernel-boot.tar.zst" ]; then
  adb_cmd exec-out "tar -C / -cf - lib/modules/$KVER boot" > "$BACKUP/kernel-boot.tar.tmp"
  zstd -q -12 -o "$BACKUP/kernel-boot.tar.zst" "$BACKUP/kernel-boot.tar.tmp" && rm -f "$BACKUP/kernel-boot.tar.tmp"
  echo "  $(du -h "$BACKUP/kernel-boot.tar.zst" | cut -f1)"
else
  echo "  already have kernel-boot.tar.zst"
fi

# 5. the non-packaged binaries that keep adb alive
log "5/6 adbd + gadget tool (not owned by any package)"
for pair in "/usr/bin/adbd:usr-bin-adbd" "/usr/bin/gc:usr-bin-gc" "/usr/sbin/mobian-usb-gadget:mobian-usb-gadget"; do
  p=${pair%%:*}; name=${pair##*:}
  if adb_cmd shell "test -x $p" 2>/dev/null; then
    adb_cmd pull "$p" "$BACKUP/$name" >/dev/null 2>&1 && echo "  $p -> $name ($(stat -c %s "$BACKUP/$name") bytes)"
  else
    warn "$p absent on device"
  fi
done
# the live configfs description is what a recovery unit has to reproduce
adb_cmd shell "ls -lR /sys/kernel/config/usb_gadget/g1; cat /sys/kernel/config/usb_gadget/g1/UDC; ls /sys/class/udc" | tr -d '\r' > "$BACKUP/gadget-live.txt"

# 6. rootfs: file-level by default (consistent while mounted), raw on request
log "6/6 rootfs"
if [ "$WANT_ROOTFS" = 1 ]; then
  echo "  raw block copy of $ROOT_DEV"
  echo "  A crash-consistent image is fine as a second line of defence (restore it, then"
  echo "  e2fsck), but do NOT fsfreeze / on a running system to chase a clean image -"
  echo "  journald and adb themselves block on the frozen root and the stick looks hung."
  echo "  For a truly quiescent image, read the partition from EDL instead:"
  echo "    edl r rootfs rootfs.bin        # needs python3-edl + the stock firehose programmer"
  [ "${COMMIT:-0}" = "1" ] || die "raw rootfs copy takes minutes over adb: rerun with COMMIT=1 --rootfs"
  if [ "${FSFREEZE:-0}" = 1 ]; then
    warn "FSFREEZE=1 - unmounting nothing, freezing / for the copy; expect the device to"
    warn "stop responding to adb until it is unfrozen. Only do this from a serial console."
    dev "fsfreeze -f /"
  fi
  adb_cmd exec-out "dd if=$ROOT_DEV bs=4M 2>/dev/null" | pigz -1 > "$BACKUP/rootfs-raw.bin.gz"
  if [ "${FSFREEZE:-0}" = 1 ]; then dev "fsfreeze -u /"; fi
  echo "  $(du -h "$BACKUP/rootfs-raw.bin.gz" | cut -f1) - restore: gunzip -c rootfs-raw.bin.gz | adb_cmd exec-out 'dd of=$ROOT_DEV bs=4M'"
else
  if [ ! -s "$BACKUP/rootfs-files.tar.zst" ]; then
    adb_cmd exec-out "tar -C / --one-file-system -cf - --exclude=./proc --exclude=./sys --exclude=./dev --exclude=./run --exclude=./tmp --exclude=./var/tmp . 2>/dev/null" > "$BACKUP/rootfs-files.tar.tmp"
    zstd -q -10 -T0 -o "$BACKUP/rootfs-files.tar.zst" "$BACKUP/rootfs-files.tar.tmp" && rm -f "$BACKUP/rootfs-files.tar.tmp"
    echo "  $(du -h "$BACKUP/rootfs-files.tar.zst" | cut -f1) (file-level; a raw image is only crash-consistent while mounted - rerun with --rootfs for that)"
  else
    echo "  already have rootfs-files.tar.zst"
  fi
fi

log "checksums"
( cd "$BACKUP" && sha256sum * > MANIFEST.sha256 && echo "  MANIFEST.sha256: $(wc -l < MANIFEST.sha256) entries" )
log "verify the boot image parses"
python3 "$ROOT/tools/bootimg.py" info "$BACKUP/boot-stock.bin" | sed 's/^/  /'
warn "backup/ is gitignored - it contains IMEI-bearing partitions. Keep it off shared sync."
echo "Done. Route A may now start; anything that touches boot/rootfs needs this directory."
