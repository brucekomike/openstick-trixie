#!/usr/bin/env bash
# Put a mainline kernel on this board: flash the OpenStick-Builder v0.2 aboot/hyp, then the
# ext2+extlinux boot image. Also the one-command undo.
#
#   scripts/74-flash-mainline-bootchain.sh status
#   COMMIT=1 scripts/74-flash-mainline-bootchain.sh aboot     # community lk1st + qhypstub
#   COMMIT=1 scripts/74-flash-mainline-bootchain.sh boot      # ext2 + extlinux + mainline kernel
#   COMMIT=1 scripts/74-flash-mainline-bootchain.sh all
#   COMMIT=1 scripts/74-flash-mainline-bootchain.sh restore   # every partition back to backup/
#
# Why the bootloader has to change at all (all measured on the UFI001C, 2026-11-05):
#   * the factory aboot has NO extlinux parser - `strings backup/part-aboot.bin | grep -c
#     extlinux` is 0, and it carries `Unable to load boot.img from ext2. Continuing legacy
#     boot`. An ext2+extlinux boot partition makes it fall straight back to fastboot.
#   * its legacy Android-image path will not start a mainline arm64 kernel either. pmOS
#     6.12.1 was tried three ways (stock DTB with no initrd, stock DTB with the stock initrd,
#     community thwc-ufi001c DTB with the stock initrd) and all three returned to fastboot,
#     while a byte-identical no-op repack of the stock image booted - so the tooling and the
#     flash path were exonerated and the payload was not.
#   * OpenStick-Builder v0.2's aboot.mbn is a current `lk1st-msm8916` with `Failed to parse
#     extlinux.conf` and lk2nd device matching in it, and its own boot.bin is ext2 with
#     /vmlinuz (Linux 6.6.0-msm8916) + /extlinux/extlinux.conf + /dtbs/qcom/. With that aboot
#     flashed, 6.12.1-msm8916 boots.
#   * sbl1/rpm/tz did NOT need replacing: this board's tz is already byte-identical to the
#     Dragon Board 410c one, and 6.12 boots with the vendor (Wingtech) sbl1/rpm left in place.
#     Touching sbl1/rpm is the riskiest flash on this SoC, so it is deliberately not done.
. "$(dirname "$0")/lib.sh"

FB=${FASTBOOT:-$HOME/.local/bin/fastboot}
command -v "$FB" >/dev/null 2>&1 || FB=$(command -v fastboot || true)
[ -n "$FB" ] || die "no fastboot binary"
V="$ROOT/vendor/openstick-alpine-v0.2"
BOOT_IMG=${BOOT_IMG:-$OUT/boot-mainline.img}
STAGE=${1:-status}

need_fb() {
  timeout 10 "$FB" devices 2>/dev/null | grep -q fastboot ||
    die "stick is not in fastboot. Run scripts/72-enter-fastboot.sh (from Linux, no hands), or
       hold the EDL/reset button while plugging it in."
}
# Every partition this script can write must have a verified backup first.
need_backups() {
  local f
  for f in "$@"; do
    [ -s "$BACKUP/$f" ] || die "missing backup/$f - run scripts/20-backup.sh before flashing anything"
  done
}

case "$STAGE" in
  status)
    log "boot chain: what is on the host, and what the stick is doing"
    for f in aboot.mbn hyp.mbn sbl1.mbn rpm.mbn tz.mbn; do
      if [ -s "$V/$f" ]; then
        printf '  community %-10s %9d B  sha256 %s\n' "$f" "$(stat -c %s "$V/$f")" "$(sha256sum "$V/$f" | cut -c1-12)"
      else
        printf '  community %-10s MISSING (see BOARD-ufi001c.md for the source)\n' "$f"
      fi
    done
    for f in part-aboot.bin part-hyp.bin part-sbl1.bin part-rpm.bin part-tz.bin boot-stock.bin; do
      [ -s "$BACKUP/$f" ] && printf '  backup    %-16s %9d B\n' "$f" "$(stat -c %s "$BACKUP/$f")" ||
        printf '  backup    %-16s MISSING\n' "$f"
    done
    [ -s "$BOOT_IMG" ] && printf '  boot img  %-16s %9d B  %s\n' "$(basename "$BOOT_IMG")" "$(stat -c %s "$BOOT_IMG")" \
      "$(debugfs -R 'cat /extlinux/extlinux.conf' "$BOOT_IMG" 2>/dev/null | grep '^fdt' || echo '(no extlinux.conf!)')"
    echo -n "  stick:    "
    if timeout 10 "$FB" devices 2>/dev/null | grep -q fastboot; then
      echo "fastboot ($("$FB" getvar version 2>&1 | grep -oE 'version: .*' | head -1))"
    elif lsusb | grep -q '05c6:9008'; then echo "EDL (9008)"
    elif lsusb | grep -q '1d6b:0104'; then echo "Linux, gadget up - use scripts/72-enter-fastboot.sh"
    else echo "not responding on USB"; fi
    ;;

  aboot|all)
    need_fb; need_backups part-aboot.bin part-hyp.bin
    [ "${COMMIT:-0}" = 1 ] || die "refusing to write aboot/hyp without COMMIT=1"
    for f in aboot.mbn hyp.mbn; do [ -s "$V/$f" ] || die "missing $V/$f"; done
    log "flashing community aboot + hyp (order matters: while the vendor sbl1 still loads aboot)"
    for pair in "aboot:aboot.mbn" "hyp:hyp.mbn"; do
      part=${pair%%:*}; file=${pair##*:}
      printf '  fastboot flash %-6s %s\n' "$part" "$file"
      timeout 120 "$FB" flash "$part" "$V/$file" 2>&1 | grep -E 'OKAY|FAILED' | sed 's/^/    /'
    done
    if [ "$STAGE" = all ]; then
      "$FB" reboot >/dev/null 2>&1 || true
      log "waiting to see whether the new aboot still boots the stock image"
      for i in $(seq 1 30); do
        sleep 4
        lsusb | grep -q '1d6b:0104' && { echo "  Linux came up under the new aboot at ~$((i * 4))s"; break; }
        if [ "$i" -ge 6 ] && timeout 8 "$FB" devices 2>/dev/null | grep -q fastboot; then
          echo "  sitting in the new aboot's fastboot at ~$((i * 4))s (fine - continuing)"; break
        fi
      done
      need_fb
      STAGE=boot
    else
      log "done. Reboot to check it still boots, then run: COMMIT=1 $0 boot"
      exit 0
    fi
    ;;&   # fall through to the boot stage when STAGE=all

  boot)
    need_fb; need_backups boot-stock.bin
    [ -s "$BOOT_IMG" ] || die "no boot image at $BOOT_IMG - run scripts/68-make-mainline-boot.sh"
    debugfs -R "cat /extlinux/extlinux.conf" "$BOOT_IMG" >/dev/null 2>&1 ||
      die "$BOOT_IMG has no /extlinux/extlinux.conf - the factory aboot cannot boot it either"
    [ "${COMMIT:-0}" = 1 ] || die "refusing to write boot without COMMIT=1"
    log "flashing $BOOT_IMG"
    debugfs -R "cat /extlinux/extlinux.conf" "$BOOT_IMG" 2>/dev/null | sed 's/^/  | /'
    timeout 300 "$FB" flash boot "$BOOT_IMG" 2>&1 | grep -E 'Sending|Writing|OKAY|FAILED' | sed 's/^/  /'
    log "rebooting"
    timeout 30 "$FB" reboot >/dev/null 2>&1 || true
    for i in $(seq 1 40); do
      sleep 4
      if lsusb | grep -q '1d6b:0104'; then
        echo "  gadget up at ~$((i * 4))s"
        SSH="ssh -i ${SSH_KEY:-$OUT/openstick_key} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 root@192.168.5.1"
        # The gadget appearing is not the same as being usable: the host still has to take a
        # DHCP lease from the stick's dnsmasq, and dropbear starts after that. Retry, don't guess.
        for t in 1 2 3 4 5 6; do
          if timeout 15 $SSH 'echo "  running: $(uname -r)"; echo "  dtb:     $(tr -d "\0" < /proc/device-tree/model)"' 2>/dev/null; then
            exit 0
          fi
          sleep 8
        done
        warn "gadget is up but ssh did not answer after ~60 s - check /dev/ttyACM0"
        exit 1
      fi
      if [ "$i" -ge 8 ] && timeout 8 "$FB" devices 2>/dev/null | grep -q fastboot; then
        echo "  back in fastboot at ~$((i * 4))s: the image did not boot"
        echo "  try the other DTB (no reflash needed once Linux runs, but from here: rebuild with DTB=)"
        echo "  undo:  COMMIT=1 $0 restore"
        exit 1
      fi
    done
    die "neither Linux nor fastboot after 160 s - power-cycle; if it shows 05c6:9008 it is in EDL"
    ;;

  restore)
    need_fb
    [ "${COMMIT:-0}" = 1 ] || die "refusing to restore without COMMIT=1"
    need_backups part-aboot.bin part-hyp.bin part-sbl1.bin part-rpm.bin part-tz.bin boot-stock.bin
    log "restoring every partition this project can write, from backup/"
    for pair in "aboot:part-aboot.bin" "hyp:part-hyp.bin" "sbl1:part-sbl1.bin" "rpm:part-rpm.bin" "tz:part-tz.bin" "boot:boot-stock.bin"; do
      part=${pair%%:*}; file=${pair##*:}
      printf '  fastboot flash %-6s %-18s ' "$part" "$file"
      timeout 600 "$FB" flash "$part" "$BACKUP/$file" 2>&1 | grep -oE 'OKAY|FAILED.*' | head -1
    done
    log "rebooting into the factory chain (vendor 5.15 + whatever is in rootfs)"
    timeout 30 "$FB" reboot >/dev/null 2>&1 || true
    ;;

  *)
    die "unknown stage '$STAGE' (status|aboot|boot|all|restore)"
    ;;
esac
