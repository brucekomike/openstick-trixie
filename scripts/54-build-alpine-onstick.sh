#!/usr/bin/env bash
# Route D: Alpine on the stick, built ON the stick, pulled back ready for fastboot.
#
#   scripts/54-build-alpine-onstick.sh              # verification + plan only
#   COMMIT=1 scripts/54-build-alpine-onstick.sh     # push, build on device, pull images
#
# Why the device builds it: the upstream builder cross-executes an aarch64 chroot with
# qemu-user-static, so it needs host sudo + binfmt. This board is aarch64 with root over
# adb, so `apk add` is native here. See scripts/device/alpine-onstick.sh for what changes
# versus upstream and why each change is board-specific.
#
# Nothing in this script touches a partition. It writes only /root/alpine-build on the
# stick (scratch, ~1.4 GB) and out/ on the host. Flashing is scripts/70-flash.sh, which
# needs the stick in fastboot - prove that door first (see the end of this script's output).
. "$(dirname "$0")/lib.sh"
require_backup boot-stock.bin
require_device
# A second live run was real, not hypothetical: a relaunched build raced the one still
# driving /root/alpine-build, and both sides' images came out corrupt. One lock per device.
exec 9>"/tmp/openstick-54-${ADB_SERIAL}.lock"
flock -n 9 || die "another 54-build-alpine-onstick.sh is already driving $ADB_SERIAL -
       it owns /root/alpine-build on that stick; wait for it (or kill it) first"

WORK_DEV=/root/alpine-build
DEV_SCRIPT="$ROOT/scripts/device/alpine-onstick.sh"
ALPINE_DIR=${ALPINE_DIR:-$ROOT/vendor/OpenStick-Builder-alpine}

log "1/6 the DTB: taken from THIS backup, cross-checked against the live board"
# The guard against the mistake that made today's backup belong to the wrong stick: the
# DTB is never a hand-picked path, it is unpacked from backup/boot-stock.bin, which
# 20-backup.sh md5-verified against this device's own boot partition.
IMGDIR="$OUT/bootimg-current"
rm -rf "$IMGDIR"
python3 "$ROOT/tools/bootimg.py" unpack "$BACKUP/boot-stock.bin" "$IMGDIR" | sed 's/^/  /'
DTB="$IMGDIR/dtb0.dtb"
[ -s "$DTB" ] || die "no dtb0.dtb inside backup/boot-stock.bin"

# Board identity comes from require_board (called by require_device above), which prefers
# /proc/device-tree/serial-number - the one identifier that survives a board being converted
# to a mainline kernel and a community DTB. Deriving the tag from the live model string here
# is what this block used to do, and it only worked while the board was still on the vendor
# DTB: the community one reads "ufi-001c/ufi-001b 4G Modem Stick", which matched nothing, and
# under `set -euo pipefail` the empty grep aborted the whole script without a message.
# Every device grep below carries `|| true` for the same reason.
LIVE_MODEL=$(dev "tr '\\0' '\\n' < /proc/device-tree/model" | tr '\n' ' ' | sed 's/  */ /g; s/ $//' || true)
LIVE_BOARD_COMPAT=$(dev "tr '\\0' '\\n' < /proc/device-tree/compatible" | grep -oE '^[a-zA-Z0-9]+,[a-zA-Z0-9-]+' | head -1 || true)
log "live model: ${LIVE_MODEL:-<unreadable>} (tag $BOARD_TAG, already matched against the backup)"

# require_board has already proved $BACKUP/boot-stock.bin mentions $BOARD_TAG; repeat it here
# only because this script can be read on its own. Captured, not piped into grep -q: a
# `grep -q` that matches early SIGPIPEs the producer and pipefail reports the *match* as a
# failure.
info=$(python3 "$ROOT/tools/fdt.py" prop "$DTB" / 2>/dev/null || true)
bootinfo=$(python3 "$ROOT/tools/bootimg.py" info "$BACKUP/boot-stock.bin" 2>/dev/null || true)
printf '%s\n' "$bootinfo" | grep -qi "$BOARD_TAG" ||
  die "the DTB in backup/boot-stock.bin does not mention '$BOARD_TAG' - wrong board's backup, re-run scripts/20-backup.sh"

# The SoC half of `compatible` is a property of the DTB alone, so it is checked locally.
DTB_COMPS=$(printf '%s\n' "$info" | grep -oE '[a-zA-Z0-9]+,[a-zA-Z0-9-]+' || true)
DTB_BOARD_COMPAT=$(printf '%s\n' "$DTB_COMPS" | head -1)
[ -n "$DTB_BOARD_COMPAT" ] || die "no compatible list found in $DTB"
printf '%s\n' "$DTB_COMPS" | grep -qx 'qcom,msm8916' || die "stock DTB is not a qcom,msm8916 tree"

# The board-level compatible is only comparable while the board still runs the vendor DTB.
# Once it has been converted, the live tree is the community one (thwc,ufi001c) and differs by
# design - that is the whole point of the conversion, and the stock DTB is still the right one
# to pack because it is this unit's own. So: enforce equality on a vendor tree, explain a
# community one. A false negative here would block a perfectly safe build.
case "$LIVE_BOARD_COMPAT" in
  "$DTB_BOARD_COMPAT")
    echo "  ok: stock DTB matches the running board ($DTB_BOARD_COMPAT / $(printf '%s\n' "$DTB_COMPS" | tail -1))" ;;
  "")
    warn "could not read a live 'compatible' over the PTY - skipping the board-level comparison" ;;
  handsome,openstick)
    die "DTB board compatible ($DTB_BOARD_COMPAT) != live ($LIVE_BOARD_COMPAT), and the board is
       still on the vendor DTB, so this backup is not from this unit" ;;
  *)
    echo "  note: the board runs '$LIVE_BOARD_COMPAT' (a community DTB) while this backup's stock"
    echo "        DTB is '$DTB_BOARD_COMPAT'. Expected on an already-converted board; the stock DTB"
    echo "        is still packed because it is this unit's own and describes its dual-SIM mux." ;;
esac
echo "  sha256 $(sha256sum "$DTB" | cut -d' ' -f1)  $(stat -c %s "$DTB") bytes"

# root= PARTUUID must come from the device, not from the env file named for another stick.
LIVE_UUID=$(dev "tr -d '\0' < /proc/cmdline" | grep -oE 'PARTUUID=[0-9a-fA-F-]+' | head -1 | cut -d= -f2 || true)
[ -n "$LIVE_UUID" ] || die "could not read root=PARTUUID from /proc/cmdline"
if [ "$LIVE_UUID" != "$ROOT_PARTUUID" ]; then
  warn "config env says $ROOT_PARTUUID but the device says $LIVE_UUID - using the device"
fi
ROOT_PARTUUID="$LIVE_UUID"

log "2/6 space + mirror reachability on the stick"
FREE_DEV=$(dev_avail_mb)
echo "  ${FREE_DEV} MB free on / (build peak is ~1.4 GB under $WORK_DEV)"
[ "${FREE_DEV:-0}" -ge 1500 ] || die "need >= 1500 MB free on the stick to build there"
MIRROR=${MIRROR:-http://mirrors.aliyun.com/alpine}
if [ "${COMMIT:-0}" = "1" ]; then
  PROBE=$(dev 'wget -q -O /dev/null http://mirrors.aliyun.com/alpine/v3.24/main/aarch64/APKINDEX.tar.gz; echo rc=$?')
  case "$PROBE" in
    *rc=0*) echo "  ok: $MIRROR reachable from the stick" ;;
    *) die "the stick has no internet ($PROBE). Open the Wi-Fi door first, from your own shell:
       adb -s $ADB_SERIAL shell
         nmcli device wifi connect \"<SSID>\" password \"<PSK>\"
         ping -c2 1.1.1.1   # then re-run this script" ;;
  esac
fi

log "3/6 build inputs pushed to the stick"
[ -d "$ALPINE_DIR" ] || die "missing $ALPINE_DIR - fetch the builder's alpine branch (see ALPINE.md)"
devrun "mkdir -p $WORK_DEV/incoming/nmconnections"
if [ "${COMMIT:-0}" = "1" ]; then
  adb_cmd push "$DEV_SCRIPT" "$WORK_DEV/alpine-onstick.sh" >/dev/null
  adb_cmd push "$DTB" "$WORK_DEV/incoming/board.dtb" >/dev/null
  adb_cmd push "$ALPINE_DIR/scripts/setup_ncm_gadget.sh" "$WORK_DEV/incoming/" >/dev/null
  for f in "$ALPINE_DIR"/configs/*.nmconnection; do
    adb_cmd push "$f" "$WORK_DEV/incoming/nmconnections/$(basename "$f")" >/dev/null
  done
  dev "sed -i 's/\r$//' $WORK_DEV/alpine-onstick.sh $WORK_DEV/incoming/setup_ncm_gadget.sh 2>/dev/null; sh -n $WORK_DEV/alpine-onstick.sh && echo '  device script parses'" | sed 's/^/  /'
  echo "  pushed: alpine-onstick.sh, board.dtb, setup_ncm_gadget.sh, $(ls "$ALPINE_DIR"/configs/*.nmconnection | wc -l) nmconnections"
fi

log "4/6 run the build on the stick"
# This board has no RTC battery and nothing on the minimal image syncs time, so its clock
# can sit at 1970 - and apk then rejects every https certificate as "not yet valid"
# (the postmarketos repo line fails with "TLS: server certificate not trusted").
# Stamp the host's UTC onto the stick before the build starts.
DEV_YEAR=$(dev "date -u -s @$(date -u +%s) >/dev/null 2>&1; date -u +%Y" | grep -oE '[0-9]{4}' | tail -1 || true)
[ "$DEV_YEAR" = "$(date -u +%Y)" ] ||
  die "could not set the stick's clock from the host (device year: '${DEV_YEAR:-unreadable}') -
       apk will reject every mirror certificate while the clock reads 1970"
echo "  clock synced: device year $DEV_YEAR"
# One long foreground adb session, not a detached background job: this adbd kills the
# whole process group when its session closes, so `nohup … &` / `setsid … &` produced no
# build.log at all. A single long-lived `adb shell` is the mechanism 20-backup.sh already
# proved here (its ~10 minute device-side tar runs exactly this way).
RUN_CMD="cd $WORK_DEV && ROOT_PARTUUID=$ROOT_PARTUUID sh ./alpine-onstick.sh >build.log 2>&1; echo BUILD_RC=\$?"
RUNLOG="$OUT/alpine-onstick-run.log"
if [ "${COMMIT:-0}" = "1" ]; then
  printf '  [stick] %s\n' "$RUN_CMD"
  # The run goes into the background *on the host* so the device log can be polled while
  # it works; the deadline is the only thing that decides when to give up.
  # `timeout` needs a real binary, not the adb_cmd shell function.
  ( timeout 2400 adb -s "$ADB_SERIAL" shell "$RUN_CMD" > "$RUNLOG" 2>&1; echo "host_rc=$?" >> "$RUNLOG" ) &
  runpid=$!
  deadline=$((SECONDS + 2450))
  status=running
  while [ "$status" = running ] && [ "$SECONDS" -lt "$deadline" ]; do
    sleep 25
    # `|| echo` on the device: a failing tail there comes back non-zero through adb, and
    # `grep` with no match would abort this script under `set -euo pipefail`.
    tail_log=$(dev "tail -n 40 $WORK_DEV/build.log 2>/dev/null || echo '(no build.log yet)'" || true)
    case "$tail_log" in
      *BUILD_DONE*)   status=done ;;
      *BUILD_FAILED*) status=failed ;;
    esac
    if ! kill -0 "$runpid" 2>/dev/null && [ "$status" = running ]; then
      case "$(tail -3 "$RUNLOG" 2>/dev/null)" in
        *BUILD_RC=0*) status=done ;;
        *) status=died ;;
      esac
    fi
    last=$(echo "$tail_log" | grep '^\[' | tail -1 || true)
    printf '  %-72s\r' "${last:-starting (${status})}"
  done
  echo
  wait "$runpid" 2>/dev/null || true
  echo "  host side: $(tr -d '\r' < "$RUNLOG" | tail -2 | tr '\n' ' ')"
  echo "  ---- last 30 lines of the device build log ----"
  echo "$tail_log" | sed 's/^/  | /'
  [ "$status" = done ] || die "build did not finish (status=$status). Full log: adb -s $ADB_SERIAL shell cat $WORK_DEV/build.log"
else
  echo "  DRY RUN - rerun with COMMIT=1 to push and build:"
  printf '    COMMIT=1 scripts/54-build-alpine-onstick.sh\n'
  exit 0
fi

log "5/6 pull the images back (staged + md5 verified, because this adbd has no exec-out)"
for pair in "rootfs.img.gz:alpine-rootfs.img.gz:rootfs-gz" "boot.img.gz:alpine-boot.img.gz:boot-gz"; do
  devname=${pair%%:*}; rest=${pair#*:}; host=${rest%%:*}; stagename=${rest##*:}
  dev "cp $WORK_DEV/out/$devname $STAGE_DIR.$stagename" >/dev/null
  pull "$stagename" "$OUT/$host" || die "pull of $devname failed"
  echo "  $host: $(stat -c %s "$OUT/$host") bytes"
done
dev "cp $WORK_DEV/out/SHA256SUMS $STAGE_DIR.sums" >/dev/null
pull "sums" "$OUT/alpine-SHA256SUMS" >/dev/null

gunzip -kf "$OUT/alpine-rootfs.img.gz" && gunzip -kf "$OUT/alpine-boot.img.gz"
log "verify the pulled images"
# The device's SHA256SUMS lists bare filenames, so it has to be checked from inside out/.
( cd "$OUT" && sed 's/rootfs\.img/alpine-rootfs.img/; s/boot\.img/alpine-boot\.img/' \
    alpine-SHA256SUMS | grep -v 'img\.gz$' > expected.sha256 )
if ( cd "$OUT" && sha256sum -c --strict expected.sha256 ) 2>&1 | sed 's/^/  /'; then
  echo "  ok: pulled images hash-match what the stick built"
else
  die "hash mismatch after the pull - do not flash these"
fi
ROOTFS_SIZE=$(stat -c %s "$OUT/alpine-rootfs.img")
BOOT_SIZE=$(stat -c %s "$OUT/alpine-boot.img")
PART_ROOT=$(dev "blockdev --getsize64 /dev/disk/by-partlabel/$ROOT_PARTLABEL" | tr -dc '0-9')
[ "$BOOT_SIZE" = "$BOOT_PART_BYTES" ] || warn "boot image is $BOOT_SIZE, partition is $BOOT_PART_BYTES"
[ "$ROOTFS_SIZE" -le "$PART_ROOT" ] || die "rootfs image $ROOTFS_SIZE > partition $PART_ROOT"
echo "  rootfs.img $ROOTFS_SIZE of $PART_ROOT partition bytes ($(awk -v a=$ROOTFS_SIZE -v b=$PART_ROOT 'BEGIN{printf "%.0f", a*100/b}')%)"
echo "  after first boot: resize2fs /dev/disk/by-partlabel/rootfs"

log "6/6 what the boot image actually contains (debugfs, no mount)"
debugfs -R "ls -l /" "$OUT/alpine-boot.img" 2>/dev/null | sed 's/^/  /'
debugfs -R "cat /extlinux/extlinux.conf" "$OUT/alpine-boot.img" 2>/dev/null | sed 's/^/  | /'
debugfs -R "dump /dtbs/qcom/msm8916-handsome-openstick.dtb $OUT/packed.dtb" "$OUT/alpine-boot.img" 2>/dev/null
cmp -s "$OUT/packed.dtb" "$DTB" && echo "  ok: packed DTB is byte-identical to this board's stock DTB" ||
  warn "packed DTB differs from $DTB"
rm -f "$OUT/packed.dtb"

cat <<EOF

Next - the door has to be proven before any of this is written:

  1. fastboot (lk2nd is already in aboot, and fastboot is compiled into it):
       adb -s $ADB_SERIAL reboot bootloader
       $(command -v fastboot || echo ~/.local/bin/fastboot) devices     # a serial here = the door is open
     If nothing lists, power-cycle the stick; it comes back into Debian. Do NOT flash
     anything until one line shows a serial.

  2. ladder step 1 - Alpine rootfs only, stock Android boot.img stays exactly as it is.
     The rootfs keeps the vendor 5.15 modules + /lib/firmware, so the current kernel and
     the current initrd boot it, and the only thing that changed is the userspace:
       $(command -v fastboot || echo ~/.local/bin/fastboot) flash rootfs $OUT/alpine-rootfs.img
       $(command -v fastboot || echo ~/.local/bin/fastboot) reboot
     Admin after that is dropbear over NCM (192.168.5.1, user/1 - change it) and the
     serial console on ttyMSM0. adb is gone for good: the vendor adbd is a glibc binary
     and musl cannot run it.

  3. ladder step 2 - only once Alpine is up: the ext2 boot image with the pmOS 6.12
     kernel and THIS board's DTB:
       $(command -v fastboot || echo ~/.local/bin/fastboot) flash boot $OUT/alpine-boot.img
     Undo, either step:  scripts/90-restore.sh boot   (re-flashes boot-stock.bin)
     Switching kernel/DTB later needs no reflashing - /boot is a real filesystem and
     extlinux-{thwc,5.15}.conf are already on it.
EOF
