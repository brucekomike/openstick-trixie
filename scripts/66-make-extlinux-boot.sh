#!/usr/bin/env bash
# Build the ext2 `boot` image this stick's lk2nd reads, using THIS BOARD'S OWN DTB.
#
# Why this exists: the aboot partition contains lk2nd strings (lk2nd_skip,
# /mnt/lk2nd_rproc_mode) and hyp contains qhypstub, so the boot chain is already the community
# one - which supports extlinux.conf - and the builder's committed extlinux.conf carries this
# device's exact root PARTUUID. That means route B/C is normal here, not a gamble, and the only
# thing missing was a correct device tree. dtb0.dtb (extracted from the working boot partition)
# is that piece.
#
# Default is deliberately conservative: it packs the STOCK kernel + STOCK initrd + STOCK DTB,
# so the artifact proves the pipeline without changing anything that boots. To try a newer
# kernel, point KERNEL/INITRD at extracted files from a postmarketOS .apk (its /boot/vmlinuz and
# /boot/initrd, plus /usr/share/dtb or the dtbs inside the apk if you want that tree's DTB):
#
#   KERNEL=/tmp/pmoss/vmlinuz INITRD=/tmp/pmoss/initrd scripts/66-make-extlinux-boot.sh
#
# Nothing here writes to the stick. Flashing this image replaces the Android boot.img in the
# `boot` partition, so keep backup/boot-stock.bin until the new kernel boots:
#   scripts/90-restore.sh boot
. "$(dirname "$0")/lib.sh"
require_backup boot-stock.bin
[ -s "$OUT/bootimg/dtb0.dtb" ] || die "run: scripts/60-build-bootimg.sh unpack (needs out/bootimg/dtb0.dtb)"

SIZE=$((64 * 1024 * 1024))
STAGE="$OUT/boot-extlinux"
IMG="$OUT/boot-extlinux.raw"

log "extract stock vmlinuz + initrd from the kernel backup"
rm -rf "$STAGE"; mkdir -p "$STAGE/extlinux" "$STAGE/dtbs/qcom"
zstd -dc "$BACKUP/kernel-boot.tar.zst" | tar -xf - -C "$OUT" boot 2>/dev/null ||
  die "could not unpack boot/ from kernel-boot.tar.zst"
VBMPATH=$(ls "$OUT"/boot/vmlinuz-* 2>/dev/null | head -1)
INITPATH=$(ls "$OUT"/boot/initrd.img-* 2>/dev/null | head -1)
KERNEL="${KERNEL:-$VBMPATH}"
INITRD="${INITRD:-$INITPATH}"
[ -n "$KERNEL" ] && [ -s "$KERNEL" ] || die "no kernel found: set KERNEL=<path>"
[ -n "$INITRD" ] && [ -s "$INITRD" ] || die "no initrd found: set INITRD=<path>"

log "assemble the boot filesystem"
install -m644 "$KERNEL" "$STAGE/vmlinuz"
install -m644 "$INITRD" "$STAGE/initrd"
install -m644 "$OUT/bootimg/dtb0.dtb" "$STAGE/dtbs/qcom/msm8916-handsome-openstick.dtb"
# APPEND is the cmdline as stored in the boot.img header, plus rootwait - NOT /proc/cmdline,
# whose androidboot.* tags lk2nd injects itself. Matches the builder's own extlinux.conf line,
# which is the format this aboot is known to accept.
sed -e "s|^  KERNEL .*|  KERNEL /vmlinuz|" \
    -e "s|^  INITRD .*|  INITRD /initrd|" \
    -e "s|^  FDT .*|  FDT /dtbs/qcom/msm8916-handsome-openstick.dtb|" \
    -e "s|^  APPEND .*|  APPEND earlycon root=PARTUUID=${ROOT_PARTUUID} console=ttyMSM0,115200 no_framebuffer=true rw rootwait|" \
    "$CONF/extlinux-ufi103s.conf" > "$STAGE/extlinux/extlinux.conf"

log "write $IMG ($SIZE bytes, ext2)"
rm -f "$IMG"
dd if=/dev/zero of="$IMG" bs=1M count=0 seek=$((SIZE / 1024 / 1024)) status=none
# -d populates from a directory without needing root or a loop mount
mkfs.ext4 -q -F -L boot -d "$STAGE" "$IMG"

log "verify the image without mounting it (debugfs, no root needed)"
if command -v debugfs >/dev/null 2>&1; then
  debugfs -R "ls -l /" "$IMG" 2>/dev/null | sed 's/^/  /'
  debugfs -R "ls -l /dtbs/qcom" "$IMG" 2>/dev/null | sed 's/^/  /'
  debugfs -R "cat /extlinux/extlinux.conf" "$IMG" 2>/dev/null | grep -v '^#' | sed 's/^/  | /'
  # the DTB that actually went into the image must still parse, and still be THIS board
  debugfs -R "dump /dtbs/qcom/msm8916-handsome-openstick.dtb $OUT/packed.dtb" "$IMG" 2>/dev/null
  if [ -s "$OUT/packed.dtb" ]; then
    echo "  packaged DTB: $(cmp -s "$OUT/packed.dtb" "$OUT/bootimg/dtb0.dtb" && echo byte-identical to stock || echo DIFFERS-FROM-STOCK) / $(python3 "$ROOT/tools/fdt.py" prop "$OUT/packed.dtb" / 2>/dev/null | head -1)"
    if cmp -s "$OUT/packed.dtb" "$OUT/bootimg/dtb0.dtb"; then rm -f "$OUT/packed.dtb"; fi
  else
    warn "could not extract the DTB from the image for verification"
  fi
else
  warn "debugfs missing - install e2fsprogs to verify"
fi

log "sizes"
printf '  kernel %s  initrd %s  dtb %s\n' \
  "$(stat -c %s "$STAGE/vmlinuz")" "$(stat -c %s "$STAGE/initrd")" \
  "$(stat -c %s "$STAGE/dtbs/qcom/msm8916-handsome-openstick.dtb")"
used=$(du -sx --block-size=1 "$STAGE" | cut -f1)
echo "  payload $used bytes vs $SIZE byte partition - $(( (SIZE - used) / 1048576 )) MiB headroom"
echo
echo "Next (host needs fastboot; lk2nd is confirmed present in aboot):"
echo "  1. confirm the entry point from your terminal:  adb -s $ADB_SERIAL reboot bootloader"
echo "     then:  fastboot devices        <- a serial here means fastboot works"
echo "  2. flash:  fastboot flash boot $IMG      (scripts/70-flash.sh boot $IMG)"
echo "  3. if it does not come up:  scripts/90-restore.sh boot   (restores boot-stock.bin)"
echo
echo "Note: this replaces the Android boot.img with a filesystem image. lk2nd reads both, but"
echo "only the extlinux form lets you change kernel/dtb without repacking - that is the point."
