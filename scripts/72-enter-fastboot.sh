#!/usr/bin/env bash
# Get the stick into fastboot without touching it - from Linux, over ssh.
#
#   scripts/72-enter-fastboot.sh
#
# Why this exists: once the rootfs is musl there is no adb (the vendor adbd is a glibc binary),
# and this GPT has no `misc` partition, so the Android "write boot-fastboot to misc" trick is
# unavailable. What `adb reboot bootloader` really does is reboot(2) with
# LINUX_REBOOT_CMD_RESTART2 and the string "bootloader"; the vendor kernel's restart handler
# records it and the bootloader honours it. scripts/device/reboot-bootloader.py issues exactly
# that syscall, and it is measured to work on this board under both the vendor 5.15 kernel and
# mainline 6.12 (fastboot appears in ~4 s).
#
# If it does not work, the fallback is physical: hold the EDL/reset button while plugging in.
. "$(dirname "$0")/lib.sh"

fb_resolve      # sets FB_BIN and the FB=(...) array, pinned to this board's BOARD_SERIALNO

if fb_present; then
  log "already in fastboot:"; "${FB[@]}" devices | sed 's/^/  /'; exit 0
fi

SSH_KEY=${SSH_KEY:-$OUT/openstick_key}
SSH_HOST=${SSH_HOST:-root@192.168.5.1}
SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 $SSH_HOST"

log "1/3 reach the stick over the gadget link"
if ! timeout 20 $SSH 'echo alive' 2>/dev/null | grep -q alive; then
  die "cannot ssh to $SSH_HOST. If Linux is not running, hold the EDL/reset button while
       plugging the stick in, then re-run; lsusb should show 18d1:d00d (fastboot) or
       05c6:9008 (EDL)."
fi
# This script reboots whatever answers $SSH_HOST. With two sticks attached both serve
# 192.168.5.1, so confirm the identity BEFORE pulling that trigger - rebooting the wrong
# board into fastboot is exactly the kind of cross-board mistake require_board exists to stop.
live_sn=$(timeout 20 $SSH 'tr -d "\0" < /proc/device-tree/serial-number' 2>/dev/null | tr -d '[:space:]')
if [ -n "${BOARD_SERIALNO:-}" ] && [ -n "$live_sn" ] && [ "$live_sn" != "$BOARD_SERIALNO" ]; then
  die "$SSH_HOST answered with serial '$live_sn' but this run is configured for '$BOARD_SERIALNO'.
       That is a different board; set BOARD_ENV=/SSH_HOST= or unplug the other stick."
fi
echo "  ok: $($SSH 'uname -r' 2>/dev/null) (serial ${live_sn:-<unreadable>})"

log "2/3 make sure the RESTART2 helper is installed"
if ! timeout 20 $SSH 'test -x /usr/local/bin/reboot-bootloader.py' 2>/dev/null; then
  [ -s "$ROOT/scripts/device/reboot-bootloader.py" ] || die "no scripts/device/reboot-bootloader.py"
  timeout 30 $SSH 'cat > /usr/local/bin/reboot-bootloader.py && chmod 755 /usr/local/bin/reboot-bootloader.py' \
    < "$ROOT/scripts/device/reboot-bootloader.py" 2>/dev/null || die "could not install the helper"
  echo "  installed"
else
  echo "  present"
fi

log "3/3 reboot(2) RESTART2 \"bootloader\""
timeout 25 $SSH 'sync; python3 /usr/local/bin/reboot-bootloader.py' 2>/dev/null || true
for i in $(seq 1 30); do
  sleep 3
  if fb_present; then
    echo "  in fastboot after ~$((i * 3))s"
    "${FB[@]}" devices | sed 's/^/  /'
    timeout 10 "${FB[@]}" getvar version 2>&1 | grep -v Finished | sed 's/^/  /'
    # version-special is how you tell which aboot is answering: the factory one reports
    # "qhypstub 0.3-r3", the community one reports empty (BOARD-ufi001c.md §3).
    timeout 10 "${FB[@]}" getvar version-special 2>&1 | grep -v Finished | sed 's/^/  /'
    exit 0
  fi
done
die "the stick did not appear in fastboot within 90 s. Power-cycle it holding the EDL/reset
     button; if lsusb then shows 05c6:9008 it is in EDL and needs the firehose loader
     (vendor/db410c-firmware/prog_emmc_firehose_8916.mbn) plus the edl tool."
