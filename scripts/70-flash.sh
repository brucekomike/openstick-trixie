#!/usr/bin/env bash
# The only script in this repo that writes to the stick's raw partitions.
# Default is a dry run that prints everything; COMMIT=1 is required, and `rootfs`
# additionally requires the literal word to guard against a fat-fingered variable.
#
#   scripts/70-flash.sh boot            # flash out/boot-new.bin to the boot partition
#   scripts/70-flash.sh rootfs out/rootfs-trixie.img
#
# Two ways to write, picked automatically:
#   fastboot  - if the device is in the bootloader (safer: rootfs is not mounted)
#   in-place  - dd over adb; ONLY valid for `boot` (that partition is not mounted)
. "$(dirname "$0")/lib.sh"
require_backup boot-stock.bin

WHAT="${1:-}"; IMG="${2:-}"
[ -n "$WHAT" ] || die "usage: $0 {boot|rootfs} [image]"

case "$WHAT" in
  boot)   TARGET_PART="$BOOT_PARTLABEL"; SRC="${IMG:-$OUT/boot-new.bin}" ;;
  rootfs) TARGET_PART="$ROOT_PARTLABEL"; SRC="${IMG:?give an image path}";
          if [ -n "${I_WIPE_ROOTFS:-}" ] && [ "$I_WIPE_ROOTFS" != "yes" ]; then
            die "I_WIPE_ROOTFS must be exactly 'yes' (it was '$I_WIPE_ROOTFS')"
          fi
          [ "${I_WIPE_ROOTFS:-}" = "yes" ] || die "rootfs overwrite destroys the running Debian 11 - set I_WIPE_ROOTFS=yes"
          ;;
  *) die "refusing to flash '$WHAT'. Calibration partitions (modemst1/2 fsg fsc) are never flashable from here." ;;
esac

[ -s "$SRC" ] || die "no image at $SRC"
SRC_SIZE=$(stat -c %s "$SRC")
PART_SIZE=$(devrun "blockdev --getsize64 /dev/disk/by-partlabel/$TARGET_PART" | tr -d '\r ')
if [ -z "$PART_SIZE" ]; then PART_SIZE=$(dev "blockdev --getsize64 /dev/disk/by-partlabel/$TARGET_PART" | tr -d '\r '); fi
log "image $SRC ($SRC_SIZE bytes) -> partition $TARGET_PART ($PART_SIZE bytes)"
[ "$SRC_SIZE" -le "$PART_SIZE" ] || die "$SRC is larger than the $TARGET_PART partition"

MODE=in-place
if adb_cmd get-state 2>/dev/null | grep -qi fastboot; then MODE=fastboot; fi
STATE=$(adb_cmd get-state 2>&1 | tr -d '\r')
if [ "$STATE" != "device" ] && [ "$MODE" = "in-place" ]; then
  die "adb state is '$STATE', not 'device'. Put it in fastboot (adb reboot bootloader) or recover EDL; do not dd over a non-booting link."
fi

if [ "$WHAT" = rootfs ] && [ "$MODE" = in-place ]; then
  die "writing the rootfs partition while it is mounted as / is not supported here. Reboot into fastboot (or EDL) first, or unpack the tar over the running system deliberately."
fi

if [ "$MODE" = fastboot ]; then
  need fastboot
  log "fastboot path"
  run "fastboot flash $TARGET_PART $SRC"
  run "fastboot reboot"
else
  log "in-place path (boot partition is not mounted, so this is safe to do from the running system)"
  printf '  [stick] dd of=/dev/disk/by-partlabel/%s bs=1M\n' "$TARGET_PART"
  if [ "${COMMIT:-0}" = "1" ]; then
    cat "$SRC" | adb_cmd exec-out "dd of=/dev/disk/by-partlabel/$TARGET_PART bs=1M" 2>&1 | sed 's/^/  /'
    echo "  wrote $SRC_SIZE bytes. Do NOT reboot until you re-read it:"
    adb_cmd exec-out "dd if=/dev/disk/by-partlabel/$TARGET_PART bs=1M count=1 2>/dev/null" | cmp - <(head -c 1048576 "$SRC") &&
      echo "  first MiB matches - ok" || warn "readback differs - do not reboot, re-flash from backup"
  else
    echo "  DRY RUN: rerun with COMMIT=1"
  fi
fi

log "after flashing boot: does it actually come back?"
cat <<'EOF'
  1. leave the USB plugged in and watch:  watch -n1 'adb devices'
  2. within ~60s the stick should reappear as `device`. If it shows `fastboot` or nothing,
     the new kernel did not boot: hold the button / power-cycle, then
         scripts/90-restore.sh boot
  3. the boot chain itself is untouched, so a bad boot.img cannot brick past that step.
EOF
