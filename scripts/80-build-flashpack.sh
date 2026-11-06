#!/usr/bin/env bash
# Build a self-contained installation flash pack: every image needed to take one of these
# boards from factory to Alpine + a mainline kernel, plus its own installer, its own factory
# restore images, and a manifest. The result needs nothing from this repository to use.
#
#   scripts/80-build-flashpack.sh              # assemble from the artifacts already in out/
#   scripts/80-build-flashpack.sh --build      # drive the whole pipeline first (needs a stick)
#   scripts/80-build-flashpack.sh --tar        # also emit out/<name>.tar.zst
#   BOOT_IMG=... ROOTFS_IMG=... scripts/80-build-flashpack.sh
#
# Output: out/flashpack/<name>/{INSTALL.md,MANIFEST.sha256,flash.sh,restore.sh,pack.env,
#                               bootloader/,boot/,rootfs/,adbd-payload/,restore/}
#
# This script writes nothing to any board. With --build it delegates to the scripts that do
# the device work (54, 76, 55, 68), each of which keeps its own COMMIT/dry-run gating.
. "$(dirname "$0")/lib.sh"

DO_BUILD=0; DO_TAR=0
for a in "$@"; do
  case "$a" in
    --build) DO_BUILD=1 ;;
    --tar)   DO_TAR=1 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) die "unknown argument '$a' (--build | --tar)" ;;
  esac
done

REPO_VERSION=${REPO_VERSION:-$(cat "$ROOT/VERSION" 2>/dev/null | tr -d " \n" || echo 0.1)}
VENDOR_REL=${VENDOR_REL:-$ROOT/vendor/openstick-alpine-v0.2}
BOOT_IMG=${BOOT_IMG:-$OUT/boot-mainline.img}
ROOTFS_IMG=${ROOTFS_IMG:-$OUT/alpine-rootfs.img}
PAYLOAD=${PAYLOAD:-$OUT/adbd-payload}
PACK_ROOT=${PACK_ROOT:-$OUT/flashpack}
TEMPLATE="$ROOT/config/flashpack/INSTALL.md.in"

# ---------------------------------------------------------------- helpers
# debugfs's `stat` exits 0 even for a path that does not exist, so presence is tested by
# listing the parent directory and matching - never by stat's exit status.
img_ls() { debugfs -R "ls -l $2" "$1" 2>/dev/null || true; }
img_has() { # $1=image $2=dir $3=regex
  local listing; listing=$(img_ls "$1" "$2")
  printf '%s\n' "$listing" | grep -qE "$3"
}
img_cat() { debugfs -R "cat $2" "$1" 2>/dev/null || true; }

need_file() { [ -s "$1" ] || die "$2: no such file ($1)"; }

# ---------------------------------------------------------------- 0. optional full build
if [ "$DO_BUILD" = 1 ]; then
  log "0/6 --build: running the pipeline that produces the inputs"
  require_device          # also proves $BACKUP belongs to the board that is plugged in
  echo "  1/4 Alpine rootfs + boot image, built natively on the stick"
  COMMIT=1 "$ROOT/scripts/54-build-alpine-onstick.sh" || die "54-build-alpine-onstick.sh failed"
  echo "  2/4 adb payload"
  "$ROOT/scripts/76-fetch-adbd-payload.sh" || die "76-fetch-adbd-payload.sh failed"
  echo "  3/4 patch the rootfs image (gadget, ACM console, adb)"
  "$ROOT/scripts/55-patch-alpine-image.sh" "$ROOTFS_IMG" || die "55-patch-alpine-image.sh failed"
  echo "  4/4 ext2 + extlinux boot image"
  BOOT_IMG="$BOOT_IMG" "$ROOT/scripts/68-make-mainline-boot.sh" || die "68-make-mainline-boot.sh failed"
fi

# ---------------------------------------------------------------- 1. inputs
log "1/6 inputs"
need_file "$VENDOR_REL/aboot.mbn" "community aboot"
need_file "$VENDOR_REL/hyp.mbn"   "community hyp"
need_file "$BOOT_IMG"   "boot image (scripts/68-make-mainline-boot.sh)"
need_file "$ROOTFS_IMG" "rootfs image (scripts/54- then 55-)"
need_file "$PAYLOAD/adbd"             "adbd payload (scripts/76-fetch-adbd-payload.sh)"
need_file "$PAYLOAD/libcrypto.so.1.1" "adbd payload"
need_file "$TEMPLATE" "INSTALL.md template"
for f in "$ROOT/config/flashpack/flash.sh" "$ROOT/config/flashpack/restore.sh"; do
  need_file "$f" "pack installer"
done

# The vendor bootloader set is hash-pinned upstream; re-check rather than trust the directory.
if [ -s "$VENDOR_REL/SHA256SUMS" ]; then
  if ( cd "$VENDOR_REL" && sha256sum -c --strict SHA256SUMS ) >/dev/null 2>&1; then
    echo "  ok: vendor bootloader images match their own SHA256SUMS"
  else
    warn "vendor SHA256SUMS did not verify cleanly - packing aboot.mbn/hyp.mbn anyway,"
    warn "but check $VENDOR_REL/SHA256SUMS by hand before trusting this pack"
  fi
fi
echo "  aboot.mbn  $(stat -c %s "$VENDOR_REL/aboot.mbn") B  sha256 $(sha256sum "$VENDOR_REL/aboot.mbn" | cut -c1-12)"
echo "  boot       $(stat -c %s "$BOOT_IMG") B"
echo "  rootfs     $(stat -c %s "$ROOTFS_IMG") B"

# ---------------------------------------------------------------- 2. verify the images
log "2/6 verify the boot image is one the community aboot can actually read"
extlinux=$(img_cat "$BOOT_IMG" /extlinux/extlinux.conf)
[ -n "$extlinux" ] || die "$BOOT_IMG has no /extlinux/extlinux.conf - the factory aboot cannot
   boot it and neither can the community one. Re-run scripts/68-make-mainline-boot.sh."
img_has "$BOOT_IMG" / 'vmlinuz' || die "$BOOT_IMG has no /vmlinuz"
DEFAULT_DTB=$(printf '%s\n' "$extlinux" | awk '/^fdt /{print $2; exit}')
[ -n "$DEFAULT_DTB" ] || die "no fdt line in $BOOT_IMG's extlinux.conf"
printf '%s\n' "$extlinux" | sed 's/^/  | /'
echo "  default DTB: $DEFAULT_DTB"
# `|| true` on every pipeline below whose grep may legitimately not match, or whose `head -1`
# closes the pipe early: under lib.sh's `set -euo pipefail` either one makes the command
# substitution fail, and the script then aborts silently with no error at all.
alt=$(img_ls "$BOOT_IMG" /extlinux | grep -oE 'extlinux-[a-z0-9.]+\.conf' | sort -u | tr '\n' ' ' || true)
echo "  alternates on the partition: ${alt:-none}"
# extlinux.conf records paths, not versions, so the kernel release comes out of the image's
# strings - the gzipped Image still carries its own version banner.
KERNEL_VER=$(strings -a "$BOOT_IMG" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+-msm8916' | head -1 || true)
[ -n "$KERNEL_VER" ] || KERNEL_VER=unknown

log "3/6 verify the rootfs image was actually patched"
# An unpatched image boots with no USB gadget at all: no adb, no ssh, no serial console. That
# is unrecoverable without EDL, so it is worth refusing the pack here rather than at the board.
for pair in "/usr/local/bin:setup_gadget\.sh" "/usr/local/bin:gadget-net-up\.sh" \
            "/usr/local/bin:nat-share\.sh" "/etc/NetworkManager/dispatcher.d:90-nat-share" \
            "/etc/udev/rules.d:10-udc\.rules" "/etc/udev/rules.d:11-gadget-net\.rules" \
            "/usr/local/sbin:adbd" "/usr/lib:libcrypto\.so\.1\.1" "/lib:libgcompat\.so\.0" \
            "/lib:libdl\.so\.2" "/etc/network:interfaces"; do
  d=${pair%%:*}; f=${pair##*:}
  # tr -d '\\' strips only the regex escape; '\\.' would also eat the dots in the filename.
  pretty=$(printf '%s' "$f" | tr -d '\\')
  img_has "$ROOTFS_IMG" "$d" "$f" || die "$ROOTFS_IMG is missing $d/$pretty -
   it was not patched. Run scripts/55-patch-alpine-image.sh $ROOTFS_IMG first."
  echo "  ok   $d/$pretty"
done
inittab=$(img_cat "$ROOTFS_IMG" /etc/inittab)
printf '%s\n' "$inittab" | grep -q 'ttyGS0' || die "no ttyGS0 console in the image's /etc/inittab"
printf '%s\n' "$inittab" | grep -q 'gadget-net-up.sh' || die "no gadget bring-up in /etc/inittab"
echo "  ok   /etc/inittab has the ACM console and the gadget bring-up"

# The last gate before a board can be written: the rootfs must be mountable read-write by the
# VENDOR kernel, because rung 1 leaves the stock boot.img in place and boots that kernel.
# metadata_csum_seed (needed by kernel >= 6.3) went unnoticed on the other board because that
# one was moved to mainline 6.12 - and on the UFI103s it produced a board that panicked before
# enumerating anything, which is the one rung-1 outcome that is not supposed to exist.
FORBID=${FORBID:-metadata_csum_seed stable_inodes orphan_file fast_commit casefold bigtime}
imgfeats=$(dumpe2fs -h "$ROOTFS_IMG" 2>/dev/null | awk -F': *' '/Filesystem features/{print $2}' | tr -s ' ' '\n' | grep -v '^$' || true)
bad=""
for f in $FORBID; do
  printf '%s\n' "$imgfeats" | grep -qx "$f" && bad="$bad $f"
done
if [ -n "$bad" ]; then
  die "$ROOTFS_IMG sets ext4 features the vendor kernel cannot mount:$bad
     Rebuild it with those names in MKFS_EXTRA (scripts/53-build-alpine-cross.sh) - an image
     like this fails rung 1 with no adb, no gadget and no fastboot, only EDL."
fi
echo "  ok   ext4 features are all mountable by the vendor kernel: $(printf '%s ' $imgfeats)"
setup=$(img_cat "$ROOTFS_IMG" /usr/local/bin/setup_gadget.sh)
printf '%s\n' "$setup" | grep -q 'ffs.adb' || die "the image's setup_gadget.sh has no ffs.adb - no adb"
printf '%s\n' "$setup" | grep -q 'serial-number' || warn "setup_gadget.sh does not read serial-number; adb serial may be the shared default"
echo "  ok   setup_gadget.sh creates ffs.adb and derives the serial"

# The README promises a toolset; the pack is the last place that can refuse an image that
# does not carry it. Same TOOLSET word as the build and as scripts/55-patch-alpine-image.sh,
# so "what was asked for", "what was installed" and "what ships" cannot drift apart.
case " ${TOOLSET:-minimal} " in
  *full*)
    TOOL_CHECK=${TOOL_CHECK:-"ssh scp ssh-keygen nano nmap ncat nc tcpdump dig iperf3 mtr traceroute whois socat"}
    TOOLSET_TAG=full ;;
  *)  TOOL_CHECK=${TOOL_CHECK:-"ssh scp ssh-keygen nano"}; TOOLSET_TAG=minimal ;;
esac
binlist=$(debugfs -R "ls /usr/bin" "$ROOTFS_IMG" 2>/dev/null | tr -s ' ' '\n' || true)
toolmiss=""
for t in $TOOL_CHECK; do
  printf '%s\n' "$binlist" | grep -qx "$t" || toolmiss="$toolmiss $t"
done
[ -z "$toolmiss" ] || die "$ROOTFS_IMG is missing$toolmiss (TOOLSET=${TOOLSET:-minimal}).
   Rebuild with the matching toolset; do not pack an image that contradicts the README."
echo "  ok   toolset present: $TOOL_CHECK"

# The build writes /etc/openstick-build naming the board it was built on. That is the only
# in-image evidence of provenance, so it is checked against this run's BOARD_TAG. The
# board= line is the *live model string*, which on a converted board reads
# "ufi-001c/ufi-001b 4G Modem Stick" (lowercase, hyphenated) instead of the vendor
# "...UFI001C" - so match both and normalise before comparing.
PROV=$(img_cat "$ROOTFS_IMG" /etc/openstick-build)
BUILT_FOR=$(printf '%s\n' "$PROV" | grep -ioE 'ufi-?[a-z0-9]+' | head -1 | tr -d '-' | tr 'a-z' 'A-Z' || true)
if [ -n "$BUILT_FOR" ]; then
  if [ "${BOARD_TAG:-}" ] && [ "${BUILT_FOR,,}" != "${BOARD_TAG,,}" ]; then
    die "this rootfs was built on a $BUILT_FOR but this run is configured for $BOARD_TAG.
       Rebuild it on the right board, or set BOARD_ENV= to match."
  fi
  echo "  ok   image records its build board: $BUILT_FOR"
  # strings over the ext2 boot image finds no version banner when the kernel is compressed
  # and renamed to /vmlinuz; the provenance file's kernel= line is the authoritative one.
  if [ "$KERNEL_VER" = unknown ]; then
    PROV_K=$(printf '%s\n' "$PROV" | grep -oE 'kernel=[0-9]+\.[0-9]+\.[0-9]+-[a-z0-9]+' | head -1 | cut -d= -f2 || true)
    [ -n "$PROV_K" ] && KERNEL_VER="$PROV_K" && echo "  ok   kernel version from provenance: $KERNEL_VER"
  fi
else
  warn "no /etc/openstick-build in the image - cannot confirm which board it was built on"
  BUILT_FOR="${BOARD_TAG:-unknown}"
fi
ALPINE_VER=$(img_cat "$ROOTFS_IMG" /etc/alpine-release | tr -d '[:space:]')
ROOT_PARTUUID_IMG=$(printf '%s\n' "$extlinux" | grep -oE 'PARTUUID=[0-9a-fA-F-]+' | head -1 | cut -d= -f2 || true)
echo "  alpine ${ALPINE_VER:-?}, root PARTUUID ${ROOT_PARTUUID_IMG:-?}"

# ---------------------------------------------------------------- 4. factory images
log "4/6 factory restore images from $BACKUP"
RESTORE_OK=1
for f in part-aboot.bin part-hyp.bin part-sbl1.bin part-rpm.bin part-tz.bin boot-stock.bin; do
  if [ -s "$BACKUP/$f" ]; then
    printf '  have %-18s %10d B\n' "$f" "$(stat -c %s "$BACKUP/$f")"
  else
    printf '  MISSING %s\n' "$f"; RESTORE_OK=0
  fi
done
if [ "$RESTORE_OK" = 1 ]; then
  # These are per-unit: prove they belong to the board this pack is for before packing them.
  # restore.sh would otherwise happily write another unit's bootloader.
  if python3 "$ROOT/tools/bootimg.py" info "$BACKUP/boot-stock.bin" 2>/dev/null |
     grep -qi "${BOARD_TAG:-__none__}"; then
    echo "  ok: boot-stock.bin mentions ${BOARD_TAG}, matching this pack"
  else
    warn "boot-stock.bin does not mention ${BOARD_TAG:-<no BOARD_TAG>} - the restore/ images may be"
    warn "another unit's. restore.sh will still flash them, so check before using it."
  fi
  if [ -s "$BACKUP/MANIFEST.sha256" ]; then
    ( cd "$BACKUP" && sha256sum -c --strict MANIFEST.sha256 ) >/dev/null 2>&1 &&
      echo "  ok: backup MANIFEST.sha256 verifies" ||
      warn "backup MANIFEST.sha256 did not verify - re-run scripts/90-restore.sh verify"
  fi
else
  warn "restore/ will be incomplete: ./restore.sh refuses to run without all six images."
  warn "Run scripts/20-backup.sh against this board to get them."
fi

# ---------------------------------------------------------------- 5. assemble
# The tier is in the directory name, in pack.env and in INSTALL.md, because "which pack is
# this" has to be answerable from the filename alone once both variants are published.
NAME="openstick-flashpack-${BUILT_FOR,,}-v${REPO_VERSION}-${KERNEL_VER}-${TOOLSET_TAG:-minimal}-$(date -u +%Y%m%d)"
PACK="$PACK_ROOT/$NAME"
log "5/6 assemble $PACK"
rm -rf "$PACK"
mkdir -p "$PACK/bootloader" "$PACK/boot" "$PACK/rootfs" "$PACK/adbd-payload" "$PACK/restore"
install -m 644 "$VENDOR_REL/aboot.mbn" "$PACK/bootloader/aboot.mbn"
install -m 644 "$VENDOR_REL/hyp.mbn"   "$PACK/bootloader/hyp.mbn"
install -m 644 "$BOOT_IMG"   "$PACK/boot/boot-mainline.img"
install -m 644 "$ROOTFS_IMG" "$PACK/rootfs/alpine-rootfs.img"
install -m 644 "$PAYLOAD/adbd" "$PACK/adbd-payload/adbd"
install -m 644 "$PAYLOAD/libcrypto.so.1.1" "$PACK/adbd-payload/libcrypto.so.1.1"
# `if` and not `[ -s x ] && install`: under `set -e` a bare failing AND-list as a statement
# is exactly the pattern that has bitten this repo before.
if [ -s "$PAYLOAD/SHA256SUMS" ]; then
  install -m 644 "$PAYLOAD/SHA256SUMS" "$PACK/adbd-payload/SHA256SUMS"
fi
if [ "$RESTORE_OK" = 1 ]; then
  for f in part-aboot.bin part-hyp.bin part-sbl1.bin part-rpm.bin part-tz.bin boot-stock.bin; do
    install -m 644 "$BACKUP/$f" "$PACK/restore/$f"
  done
else
  rmdir "$PACK/restore" 2>/dev/null || true
fi
install -m 755 "$ROOT/config/flashpack/flash.sh"    "$PACK/flash.sh"
install -m 755 "$ROOT/config/flashpack/restore.sh"  "$PACK/restore.sh"

cat > "$PACK/pack.env" <<EOF
# Generated by scripts/80-build-flashpack.sh - read by flash.sh and restore.sh.
PACK_NAME="$NAME"
PACK_BOARD_TAG="${BUILT_FOR}"
PACK_KERNEL="${KERNEL_VER}"
PACK_ALPINE="${ALPINE_VER:-unknown}"
PACK_DEFAULT_DTB="${DEFAULT_DTB}"
PACK_ROOT_PARTUUID="${ROOT_PARTUUID_IMG:-${ROOT_PARTUUID:-}}"
PACK_BUILT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
PACK_TOOLSET="${TOOLSET_TAG:-minimal}"
PACK_REPO_VERSION="${REPO_VERSION}"
PACK_BUILT_BY="$(basename "$0") on $(uname -srm)"
PACK_HAS_RESTORE=$([ "$RESTORE_OK" = 1 ] && echo yes || echo no)
# Empty on purpose: a pack is not tied to one unit's serial, and the value would be a
# per-unit identifier in a distributable artifact. Set SERIAL= when flashing to pin the
# device; flash.sh then refuses to write to any other board.
PACK_SERIAL=""
EOF

sed -e "s|@PACK_NAME@|$NAME|g" \
    -e "s|@BUILT@|$(date -u +%Y-%m-%d) (UTC)|g" \
    -e "s|@BOARD_TAG@|${BUILT_FOR}|g" \
    -e "s|@ALPINE@|${ALPINE_VER:-unknown}|g" \
    -e "s|@KERNEL@|${KERNEL_VER}|g" \
    -e "s|@DEFAULT_DTB@|${DEFAULT_DTB}|g" \
    -e "s|@PARTUUID@|${ROOT_PARTUUID_IMG:-unknown}|g" \
    -e "s|@ROOTFS_BYTES@|$(stat -c %s "$PACK/rootfs/alpine-rootfs.img")|g" \
    -e "s|@BOOT_BYTES@|$(stat -c %s "$PACK/boot/boot-mainline.img")|g" \
    -e "s|@HAS_RESTORE@|$([ "$RESTORE_OK" = 1 ] && echo 'present (6 images, this unit'"'"'s own)' || echo 'ABSENT - ./restore.sh will refuse to run')|g" \
    -e "s|@TOOLSET@|${TOOLSET_TAG:-minimal}|g" \
    -e "s|@REPO_VERSION@|$REPO_VERSION|g" \
    "$TEMPLATE" > "$PACK/INSTALL.md"
if grep -q '@[A-Z_]*@' "$PACK/INSTALL.md"; then
  warn "unsubstituted token left in INSTALL.md: $(grep -o '@[A-Z_]*@' "$PACK/INSTALL.md" | sort -u | tr '\n' ' ')"
fi

log "6/6 manifest + self-check"
( cd "$PACK" && find . -type f ! -name MANIFEST.sha256 -printf '%P\n' | sort |
  xargs -r sha256sum > MANIFEST.sha256 )
echo "  $(wc -l < "$PACK/MANIFEST.sha256") entries"
( cd "$PACK" && sha256sum -c --strict MANIFEST.sha256 ) >/dev/null 2>&1 ||
  die "the pack does not verify against its own manifest"
echo "  ok: sha256sum -c --strict passes"

# Prove the installer runs and refuses correctly, rather than assuming the heredocs are right.
dry=$(cd "$PACK" && ./flash.sh 2>&1) || die "the pack's own flash.sh dry run failed:
$(printf '%s\n' "$dry" | tail -5)"
printf '%s\n' "$dry" | grep -q 'DRY RUN' || die "flash.sh dry run did not reach its DRY RUN banner"
printf '%s\n' "$dry" | grep -q 'rung 1/3\|rootfs' || die "flash.sh plan does not list the rootfs rung"
echo "  ok: ./flash.sh dry run lists all three rungs"
if [ "$RESTORE_OK" = 1 ]; then
  rdry=$(cd "$PACK" && ./restore.sh 2>&1) || die "the pack's own restore.sh dry run failed:
$(printf '%s\n' "$rdry" | tail -5)"
  printf '%s\n' "$rdry" | grep -q 'DRY RUN' || die "restore.sh dry run did not reach its DRY RUN banner"
  echo "  ok: ./restore.sh dry run lists all six partitions"
fi
# A dry run cannot exercise the lines that write, so check them statically instead. `timeout N
# fb flash …` where fb is a shell function does not run at all - timeout execs a binary - and
# with the output filtered through `| grep 'Sending|OKAY'` and no pipefail, a flash that never
# happened reported success and the ladder rebooted a board it had not written. Measured on the
# UFI103s, where rung 1 "completed" in seconds with nothing printed.
for f in flash.sh restore.sh; do
  # Strip comment lines before looking: the fix is documented in these files in the exact
  # `timeout 300 fb flash …` form this check hunts for, so grepping raw text reports the
  # explanation as if it were the defect. (tests/test_flashpack.py skips comments too.)
  code=$(sed 's/^[[:space:]]*#.*//' "$PACK/$f")
  if printf '%s\n' "$code" | grep -nE 'timeout [0-9]+ fb ' >/dev/null 2>&1; then
    die "$f still calls fastboot through a shell function under timeout:
     $(printf '%s\n' "$code" | grep -nE 'timeout [0-9]+ fb ' | sed 's/^/       /')
     Every one of those lines is a no-op that reports success. Use the FB_CMD array."
  fi
  if printf '%s\n' "$code" | grep -nE 'fb flash .*[|] *grep' >/dev/null 2>&1; then
    die "$f filters a flash through grep, which hides every message that is not OKAY"
  fi
  grep -q 'FB_CMD' "$PACK/$f" || die "$f does not build an FB_CMD argv array"
done
echo "  ok: neither installer calls fastboot through timeout+function or hides its output"
# COMMIT=1 without the guard word must be refused - that is the whole point of the guard.
if ( cd "$PACK" && COMMIT=1 ./flash.sh >/dev/null 2>&1 ); then
  die "flash.sh accepted COMMIT=1 without I_WIPE_ROOTFS=yes - the guard is broken"
fi
echo "  ok: COMMIT=1 without I_WIPE_ROOTFS=yes is refused"

du -sh "$PACK" | sed 's/^/  pack: /'
find "$PACK" -maxdepth 2 -type f -printf '    %P  %s bytes\n' | sort | sed 's/$//'

if [ "$DO_TAR" = 1 ]; then
  TAR="$PACK_ROOT/$NAME.tar.zst"
  log "compressing to $TAR"
  tar -C "$PACK_ROOT" -cf - "$NAME" | zstd -q -T0 -19 -o "$TAR" || die "zstd failed"
  ( cd "$PACK_ROOT" && sha256sum "$NAME.tar.zst" > "$NAME.tar.zst.sha256" )
  echo "  $(du -h "$TAR" | cut -f1)  sha256 $(sha256sum "$TAR" | cut -c1-16)"
fi

cat <<EOF

Pack ready: $PACK

Copy it to the host that will do the flashing (the whole directory, or the .tar.zst), then:
  ./flash.sh                                  # dry run - verifies the manifest, prints the plan
  COMMIT=1 I_WIPE_ROOTFS=yes ./flash.sh       # the three-rung ladder
Nothing in this pack writes sbl1/rpm/tz or any calibration partition.
EOF
