#!/usr/bin/env bash
# Build a new boot.img *around the stock DTB*, for anyone who wants a newer kernel
# without waiting for mainline to carry "handsome,openstick".
#
#   scripts/60-build-bootimg.sh info              # decode backup/boot-stock.bin
#   scripts/60-build-bootimg.sh unpack            # split kernel/dtb/ramdisk into out/
#   scripts/60-build-bootimg.sh repack --kernel <Image.gz> [--ramdisk <file>] [--cmdline "..."]
#
# Reality check, stated plainly: an FDT written for 5.15 is not guaranteed to bind to a
# 6.x/7.x kernel (smd/qrtr, iommu, pd, wcnss and PMIC node shapes all moved). Reusing the
# stock DTB removes the "wrong board" variable, not the "old bindings" one. Treat any boot
# here as a test with backup/boot-stock.bin one command away (scripts/90-restore.sh).
. "$(dirname "$0")/lib.sh"
require_backup boot-stock.bin
mkdir -p "$OUT/bootimg"

SUB="${1:-info}"; shift || true
case "$SUB" in
  info)
    python3 "$ROOT/tools/bootimg.py" info "$BACKUP/boot-stock.bin"
    ;;
  unpack)
    python3 "$ROOT/tools/bootimg.py" unpack "$BACKUP/boot-stock.bin" "$OUT/bootimg"
    echo
    echo "  dtb out of the stock image: $OUT/bootimg/dtb0.dtb"
    if command -v dtc >/dev/null 2>&1; then
      dtc -I dtb -O dts "$OUT/bootimg/dtb0.dtb" 2>/dev/null | sed -n '1,25p' | sed 's/^/  /'
    else
      echo "  (install device-tree-compiler to decompile it: sudo apt install device-tree-compiler)"
    fi
    echo "  cmdline to preserve: $(cat "$OUT/bootimg/cmdline.txt")"
    ;;
  repack)
    KERNEL=""; DTB=""; RAMDISK=""; CMDLINE=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --kernel) KERNEL="$2"; shift 2 ;;
        --dtb) DTB="$2"; shift 2 ;;
        --ramdisk) RAMDISK="$2"; shift 2 ;;
        --cmdline) CMDLINE="$2"; shift 2 ;;
        *) die "unknown flag $1" ;;
      esac
    done
    [ -n "$KERNEL" ] || die "repack needs --kernel <Image.gz> (else use route A: don't touch boot)"
    ARGS=(--template "$BACKUP/boot-stock.bin" --kernel "$KERNEL" -o "$OUT/boot-new.bin")
    if [ -n "$DTB" ]; then ARGS+=(--dtb "$DTB"); fi
    if [ -n "$RAMDISK" ]; then ARGS+=(--ramdisk "$RAMDISK"); fi
    if [ -n "$CMDLINE" ]; then ARGS+=(--cmdline "$CMDLINE"); fi
    if [ -z "$DTB" ]; then
      warn "no --dtb: the kernel payload must already carry a DTB, otherwise this will not boot"
      warn "(extract the stock one with: scripts/60-build-bootimg.sh unpack, pass --dtb out/bootimg/dtb0.dtb)"
    fi
    python3 "$ROOT/tools/bootimg.py" repack "${ARGS[@]}"
    python3 "$ROOT/tools/bootimg.py" info "$OUT/boot-new.bin" | sed 's/^/  /'
    echo
    echo "  flash with: scripts/70-flash.sh boot   (COMMIT=1 required)"
    echo "  undo with:  scripts/90-restore.sh boot"
    ;;
  *) die "usage: $0 {info|unpack|repack ...}" ;;
esac
