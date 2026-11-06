#!/usr/bin/env bash
# Cross-build this board's Alpine rootfs ON THE HOST, with no internet on the stick.
#
#   scripts/53-build-alpine-cross.sh              # stage the inputs, verify them, print the plan
#   COMMIT=1 scripts/53-build-alpine-cross.sh     # run the build in an arm64-executing container
#
# Why this exists: scripts/54-build-alpine-onstick.sh builds on the stick, which needs the stick
# online (~40 min of native apk there plus a 940 MB pull back) and this unit's Wi-Fi does not
# associate reliably. The build is the same code - scripts/device/alpine-onstick.sh, unchanged -
# run inside a container where the host has the network. Everything that script reads from a
# running system is staged here out of this board's own backup instead:
#
#   /lib/firmware              <- backup/lib-firmware.tar.zst      (no `modem` partition exists,
#   /lib/modules/$VENDOR_KVER  <- backup/kernel-boot.tar.zst         so the DSP blobs are files)
#   /boot/vmlinuz,initrd       <- backup/kernel-boot.tar.zst
#   incoming/board.dtb         <- unpacked from backup/boot-stock.bin
#   ROOT_PARTUUID, BOARD_MODEL <- the live device over adb, or the stock boot image's own cmdline
#
# Two things a container build can get wrong that an on-device one cannot, both checked below:
#   * the ext4 feature set. Host mke2fs is 1.47.4 and its defaults include bits the *vendor*
#     kernel cannot mount, which fails rung 1 - the rung the ladder treats as the reversible
#     checkpoint - with a board that never enumerates USB at all. ROOTFS_FORBID is checked
#     against the finished image; MKFS_EXTRA switches the bits off at creation. (Comparing
#     against the other board's image is not the guard: see step 5.)
#   * provenance. 80-build-flashpack.sh refuses a rootfs whose /etc/openstick-build names the
#     other board, and a container has no /proc/device-tree, so BOARD_MODEL is passed in.
#
# Output: out/alpine-rootfs-<board>.img. Then scripts/55-patch-alpine-image.sh that image,
# scripts/68-make-mainline-boot.sh DTB_ALT=... for the boot partition, and
# scripts/80-build-flashpack.sh for the pack. Nothing here writes to a device.
. "$(dirname "$0")/lib.sh"

DOCKER=${DOCKER:-docker}
DOCKER_IMAGE=${DOCKER_IMAGE:-alpine:3.24}
STAGE=${STAGE:-$OUT/cross-${BOARD_TAG,,}}
BUILD_SH="$ROOT/scripts/device/alpine-onstick.sh"
VENDOR_ALPINE=${VENDOR_ALPINE:-$ROOT/vendor/OpenStick-Builder-alpine}
RELEASE=${RELEASE:-v3.24}
MIRROR=${MIRROR:-https://dl-cdn.alpinelinux.org/alpine}
PMOS_RELEASE=${PMOS_RELEASE:-v25.12}
PMOS_MIRROR=${PMOS_MIRROR:-https://mirror.postmarketos.org/postmarketos}
ROOTFS_MB=${ROOTFS_MB:-896}
# minimal = editor + ssh client, full = adds the network tools. Passed to the build AND to
# the gates in 55/80, because a mismatch between "asked for", "installed" and "promised in
# the README" is exactly how an image ships without something it documents.
TOOLSET=${TOOLSET:-minimal}
PROVEN_ROOTFS=${PROVEN_ROOTFS:-$(ls -1 "$OUT"/flashpack/*/rootfs/alpine-rootfs.img 2>/dev/null | head -1 || true)}
# ext4 feature bits the vendor kernel cannot mount. Measured the hard way on the UFI103s: an
# image with metadata_csum_seed (RO_COMPAT, kernel >= 6.3) written to the rootfs partition left
# the board silent on USB for 150 s - the stock initrd could not mount root read-write, so the
# 5.15.0 kernel (this vendor tree is dated 2022-12-10) panicked before any gadget existed.
# Comparing against the UFI001C's image did NOT catch it, because that image has the same bits
# and had only ever been mounted by mainline 6.12, never by the vendor kernel rung 1 relies on.
# orphan_file is upstream since 5.15 but this tree's date makes it unproven here, so it is out.
ROOTFS_FORBID=${ROOTFS_FORBID:-metadata_csum_seed stable_inodes orphan_file fast_commit casefold bigtime}
MKFS_EXTRA=${MKFS_EXTRA:--O ^metadata_csum_seed,^orphan_file}

TAGL="${BOARD_TAG,,}"
VERIFY_ONLY=${VERIFY_ONLY:-0}
DTB="$STAGE/bootimg/dtb0.dtb"          # set here too: the final hint prints it in VERIFY_ONLY mode
ROOTFS_IMG="$OUT/alpine-rootfs-$TAGL.img"
BUILDLOG="$OUT/alpine-cross-$TAGL-build.log"

# ---------------------------------------------------------------- steps 1-4: stage and build
# Wrapped so the checks can be re-run against a tree that is already built: re-checking an
# assertion should not cost another ten minutes of emulation.  VERIFY_ONLY=1 scripts/53-...sh
stage_and_build() {
# ---------------------------------------------------------------- 1. inputs
log "1/5 inputs: this board's backup at $BACKUP"
for f in boot-stock.bin lib-firmware.tar.zst kernel-boot.tar.zst; do
  [ -s "$BACKUP/$f" ] || die "missing $BACKUP/$f - run scripts/20-backup.sh against this stick"
done
[ -s "$BUILD_SH" ] || die "missing $BUILD_SH"
[ -d "$VENDOR_ALPINE/scripts" ] || die "missing $VENDOR_ALPINE - see ALPINE.md (the builder's alpine branch)"

# The backup tree is per-unit, so prove it belongs to the board configured for this run.
#
# OFFLINE=1 builds for a board that is NOT the one plugged in. That is safe here and nowhere
# else: this script reads backups and writes images, never a device, and the identity check
# that matters for a cross-board mistake is the one at flash time (`require_board` for
# fastboot, and the boot-partition model probe in 78-flash-over-edl.sh for EDL). Without it,
# a converted stick is actively misleading: a UFI103S running the community DTB reports model
# "ufi-001c/ufi-001b", so building the OTHER board's image while it is attached would have
# require_board confidently confirm the wrong thing.
MODEL_LIVE=""
ROOT_PARTUUID_LIVE=""
if [ "${OFFLINE:-0}" = 1 ]; then
  python3 "$ROOT/tools/bootimg.py" info "$BACKUP/boot-stock.bin" 2>/dev/null | grep -qi "$BOARD_TAG" ||
    die "$BACKUP/boot-stock.bin does not mention $BOARD_TAG - that is the other board's backup"
  log "board: $BOARD_TAG (OFFLINE=1: built from $BACKUP; nothing live was read and nothing was written to a device)"
elif adb_cmd get-state >/dev/null 2>&1; then
  require_board                      # also cross-checks the serial against the env file
  MODEL_LIVE=$(dev "tr '\\0' '\\n' < /proc/device-tree/model" | head -1 || true)
  ROOT_PARTUUID_LIVE=$(dev "tr -d '\\0' < /proc/cmdline" | grep -oE 'PARTUUID=[0-9a-fA-F-]+' | head -1 | cut -d= -f2 || true)
else
  python3 "$ROOT/tools/bootimg.py" info "$BACKUP/boot-stock.bin" 2>/dev/null | grep -qi "$BOARD_TAG" ||
    die "$BACKUP/boot-stock.bin does not mention $BOARD_TAG - that is the other board's backup"
  log "board: $BOARD_TAG (from $BACKUP/boot-stock.bin; no device attached, nothing live was read)"
fi

# ---------------------------------------------------------------- 2. stage
log "2/5 staging $STAGE from $BACKUP"
# The container builds as root, so everything under $STAGE comes back owned by root on the host
# and a plain `rm -rf` fails with EACCES on the first file. Remove it the way it was made.
wipe_stage() {
  rm -rf "$STAGE/build" "$STAGE/vendor" "$STAGE/bootimg" 2>/dev/null && return 0
  echo "  stage is root-owned from a previous run; clearing it in a container"
  "$DOCKER" run --rm -v "$STAGE:/wipe" "$DOCKER_IMAGE" \
    sh -c 'rm -rf /wipe/build /wipe/vendor /wipe/bootimg /wipe/probe-adbd' ||
    die "could not clear $STAGE - remove it by hand (sudo rm -rf $STAGE)"
}
wipe_stage
mkdir -p "$STAGE/vendor" "$STAGE/bootimg" "$STAGE/build/incoming/nmconnections"
python3 "$ROOT/tools/bootimg.py" unpack "$BACKUP/boot-stock.bin" "$STAGE/bootimg" | sed 's/^/  /'
DTB="$STAGE/bootimg/dtb0.dtb"
[ -s "$DTB" ] || die "no dtb0.dtb inside $BACKUP/boot-stock.bin"
zstd -qdc "$BACKUP/lib-firmware.tar.zst" | tar -x -C "$STAGE/vendor" || die "could not unpack lib-firmware.tar.zst"
zstd -qdc "$BACKUP/kernel-boot.tar.zst"  | tar -x -C "$STAGE/vendor" || die "could not unpack kernel-boot.tar.zst"
cp "$DTB" "$STAGE/build/incoming/board.dtb"
cp "$VENDOR_ALPINE/scripts/setup_ncm_gadget.sh" "$STAGE/build/incoming/"
for f in "$VENDOR_ALPINE"/configs/*.nmconnection; do
  if [ -f "$f" ]; then cp "$f" "$STAGE/build/incoming/nmconnections/"; fi
done

# What the build reads through the bind mounts, checked as files rather than assumed.
have() { # $1 = path under $STAGE/vendor  $2 = label
  if [ -e "$STAGE/vendor/$1" ]; then
    printf '  ok   %-34s %s\n' "$2" "$(du -sh "$STAGE/vendor/$1" 2>/dev/null | cut -f1)"
  else
    printf '  MISSING %s (%s)\n' "$2" "$1"; MISSING=1
  fi
}
MISSING=0
have "lib/firmware"           "modem/DSP firmware"
have "lib/modules/$KVER"      "vendor kernel modules"
have "boot/vmlinuz-$KVER"     "vendor kernel (fallback label)"
have "boot/initrd.img-$KVER"  "vendor initrd"
[ "$MISSING" = 0 ] || die "the staged vendor tree is incomplete - this backup cannot build a
   rootfs that boots on the stock kernel. Re-run scripts/20-backup.sh against this board."
echo "  $(find "$STAGE/vendor/lib/firmware" -type f | wc -l) firmware files, $(find "$STAGE/vendor/lib/modules/$KVER" -name '*.ko' | wc -l) .ko modules"

# The two values the build must not guess.
#
# Provenance order matters once a board has been converted: this stick running the community
# thwc DTB reports model "ufi-001c/ufi-001b 4G Modem Stick", i.e. the live model string now
# names the OTHER board. Taking provenance (or worse, identity) from it would either abort a
# correct build or let a UFI001C run be "proved" against a UFI103s. So: trust the live string
# only when it names this board, otherwise fall back to the model in this board's own stock
# DTB, which comes out of backup/boot-stock.bin and is the unit's own hardware description.
MODEL_DTB=$(strings -a "$DTB" | grep -m1 -oE 'Handsome OpenStick.*' || true)
BOARD_MODEL=${BOARD_MODEL:-}
if [ -z "$BOARD_MODEL" ]; then
  case "$MODEL_LIVE" in
    *"$BOARD_TAG"*) BOARD_MODEL="$MODEL_LIVE"; echo "  ok   provenance from the live DT model" ;;
    "") BOARD_MODEL="$MODEL_DTB"; echo "  note no live model string readable; using the stock DTB's" ;;
    *)  BOARD_MODEL="$MODEL_DTB"
        echo "  note live model says '$MODEL_LIVE' (a community DTB). Using this board's own stock"
        echo "        DTB model string for provenance instead - the live one names another board." ;;
  esac
fi
[ -n "$BOARD_MODEL" ] || die "cannot determine the DT model string for /etc/openstick-build;
   attach the stick over adb or pass BOARD_MODEL="
case "$BOARD_MODEL" in
  *"$BOARD_TAG"*) echo "  ok   model string: $BOARD_MODEL" ;;
  *) die "model string '$BOARD_MODEL' does not name $BOARD_TAG - not this board's DTB" ;;
esac
if [ -n "$ROOT_PARTUUID_LIVE" ]; then
  ROOT_PARTUUID="$ROOT_PARTUUID_LIVE"
  echo "  ok   root=PARTUUID read from the device: $ROOT_PARTUUID"
else
  UUID_IN_IMG=$(grep -oE 'PARTUUID=[0-9a-fA-F-]+' "$STAGE/bootimg/cmdline.txt" 2>/dev/null | head -1 | cut -d= -f2 || true)
  if [ -n "$UUID_IN_IMG" ] && [ "$UUID_IN_IMG" != "$ROOT_PARTUUID" ]; then
    warn "env says $ROOT_PARTUUID but $BACKUP/boot-stock.bin's own cmdline says $UUID_IN_IMG - using the backup"
    ROOT_PARTUUID="$UUID_IN_IMG"
  fi
  echo "  root=PARTUUID $ROOT_PARTUUID (from the backup's cmdline; the stick was not online)"
fi

# ---------------------------------------------------------------- 3. the exec door
log "3/5 arm64 execution door"
command -v "$DOCKER" >/dev/null 2>&1 || die "no docker binary (set DOCKER=podman)"
"$DOCKER" info >/dev/null 2>&1 || die "$DOCKER cannot reach a daemon (is it running, and are you in the docker group?)"
# What the build depends on is the kernel's binfmt handler executing an aarch64 ELF from inside
# an x86_64 container. Prove that with an aarch64 binary already on disk instead of trusting
# that qemu registration happened. The copy is chmod 755 on purpose: the backup stores adbd 644,
# and a bind-mounted non-executable ELF returns 126, which is indistinguishable from no binfmt.
PROBE_BIN=${PROBE_BIN:-$BACKUP/usr-bin-adbd}
[ -s "$PROBE_BIN" ] || die "no aarch64 binary to probe with (pass PROBE_BIN=)"
cp "$PROBE_BIN" "$STAGE/probe-adbd" && chmod 755 "$STAGE/probe-adbd"
probe=$(timeout 180 "$DOCKER" run --rm --platform linux/amd64 -v "$STAGE/probe-adbd:/probe-adbd:ro" "$DOCKER_IMAGE" \
        sh -c 'timeout 3 /probe-adbd >/dev/null 2>&1; echo "rc=$?"' 2>&1 | tr -d '\r' | tail -1 || true)
rm -f "$STAGE/probe-adbd"
case "$probe" in
  *rc=126*|*rc=127*)
    die "aarch64 binaries do not execute inside an x86_64 container here ($probe). Register qemu
     binfmt, e.g.  $DOCKER run --rm --privileged multiarch/qemu-user-static --reset -p yes
     or, with root on the host:  sudo apt install qemu-user-static binfmt-support" ;;
esac
echo "  ok: aarch64 ELF executes in an x86_64 container ($probe)"

# ---------------------------------------------------------------- 4. build
# The container needs its own tooling before the build script can run, and that fetch is
# separate from the target's repositories: dl-cdn.alpinelinux.org has been observed to fail
# with "TLS: unspecified error" mid-session, which would otherwise look like a broken build.
# Try the portable mirror first, then the one this host was actually able to reach; the
# target rootfs still gets $MIRROR, which is what ships to users.
# The speed of the build is decided here, not in the emulation setup. Installing the package
# set with the *target's* apk means every file write, every dependency solve and every
# extraction is aarch64 code running under qemu-user: measured ~9 min for this set. A native
# apk doing the same job against --root writes the tree at host speed (26 s for the probe set)
# and still runs the target's %post scripts, because apk itself chroots into the tree.
# apk.static is what the vendored upstream builder uses for its bootstrap, from the same
# project that publishes the indexes - so the version matches the repo format.
APK_STATIC=${APK_STATIC:-$OUT/tools/apk.static}
APK_STATIC_URL=${APK_STATIC_URL:-https://gitlab.alpinelinux.org/api/v4/projects/5/packages/generic/v3.0.6/x86_64/apk.static}
CROSS_APK_IN=""
if [ "${NATIVE_APK:-1}" = 1 ]; then
  mkdir -p "$(dirname "$APK_STATIC")"
  if [ ! -s "$APK_STATIC" ]; then
    log "fetching the native apk ($APK_STATIC_URL)"
    timeout 300 curl -sSfL -o "$APK_STATIC.part" "$APK_STATIC_URL" && mv "$APK_STATIC.part" "$APK_STATIC" ||
      { rm -f "$APK_STATIC.part"; warn "could not fetch apk.static - falling back to the emulated install"; }
  fi
  if [ -s "$APK_STATIC" ]; then
    chmod +x "$APK_STATIC"
    file "$APK_STATIC" 2>/dev/null | grep -q 'x86-64' ||
      die "$APK_STATIC is not an x86-64 binary - it must run natively, not under emulation"
    CROSS_APK_IN="$APK_STATIC"
    echo "  ok: native apk $("$APK_STATIC" --version 2>&1 | head -1)"
  fi
fi

BOOTSTRAP_MIRRORS=${BOOTSTRAP_MIRRORS:-"https://dl-cdn.alpinelinux.org/alpine https://mirrors.aliyun.com/alpine"}
# The container's own tooling is a separate concern from the target's repositories: dl-cdn has
# served "TLS: unspecified error" from this host mid-build, and that failure looks exactly like
# a broken build if only one mirror is tried.
BOOTSTRAP_SCRIPT='
    set -e
    rel=${RELEASE:-v3.24}
    for m in $BOOTSTRAP_MIRRORS; do
      printf "%s/%s/main\n%s/%s/community\n" "$m" "$rel" "$m" "$rel" > /etc/apk/repositories
      if apk add --no-cache e2fsprogs coreutils tar gzip wget >/dev/null 2>&1; then
        echo "  container tools from ${m#https://}"
        exec sh /build.sh
      fi
      echo "  mirror ${m#https://} could not serve the container tools; trying the next one"
    done
    echo "BUILD_FAILED: no bootstrap mirror worked - retry with BOOTSTRAP_MIRRORS=<url>" >&2
    exit 5'

DOCKER_CMD=( "$DOCKER" run --rm --privileged --platform linux/amd64
  -v "$STAGE/build:/root/alpine-build"
  -v "$STAGE/vendor/lib/firmware:/lib/firmware:ro"
  -v "$STAGE/vendor/lib/modules:/lib/modules:ro"
  -v "$STAGE/vendor/boot:/boot:ro"
  -v "$BUILD_SH:/build.sh:ro"
  -e ROOT_PARTUUID="$ROOT_PARTUUID"
  -e VENDOR_KVER="$KVER"
  -e BOARD_MODEL="$BOARD_MODEL"
  -e ALPINE_HOST="openstick-$TAGL"
  -e RELEASE="$RELEASE" -e MIRROR="$MIRROR"
  -e PMOS_RELEASE="$PMOS_RELEASE" -e PMOS_MIRROR="$PMOS_MIRROR"
  -e ROOTFS_MB="$ROOTFS_MB" -e MKFS_EXTRA="$MKFS_EXTRA"
  -e TOOLSET="$TOOLSET"
  -e BOOTSTRAP_MIRRORS="$BOOTSTRAP_MIRRORS" )

if [ -n "$CROSS_APK_IN" ]; then
  DOCKER_CMD+=( -v "$APK_STATIC:/tools/apk.static:ro" -e CROSS_APK=/tools/apk.static )
  echo "  build mode: native apk (NATIVE_APK=0 forces the emulated target apk)"
else
  echo "  build mode: emulated target apk (slow)"
fi
DOCKER_CMD+=( "$DOCKER_IMAGE" sh -c "$BOOTSTRAP_SCRIPT" )

if [ "${COMMIT:-0}" != "1" ]; then
  log "4/5 DRY RUN - the container command that would run"
  printf '  %q\n' "${DOCKER_CMD[@]}"
  cat <<EOF

Nothing was built and no board was touched. To run it (a few minutes with the native apk,
~10 under emulation; log: $BUILDLOG):
  COMMIT=1 scripts/53-build-alpine-cross.sh
EOF
  exit 0
fi

log "4/5 building in the container (log: $BUILDLOG)"
# --privileged buys exactly two things the build script needs: `mount -t proc` for the target
# chroot and mknod. The only host paths it can reach are the four binds above.
rc=0
"${DOCKER_CMD[@]}" > "$BUILDLOG" 2>&1 || rc=$?
tail -25 "$BUILDLOG" | sed 's/^/  | /'
[ "$rc" = 0 ] || die "the container build exited $rc - full log: $BUILDLOG"
grep -q 'BUILD_DONE' "$BUILDLOG" || die "the build log has no BUILD_DONE marker - do not use its output"
# Hand the tree back to this user: step 5 reads it as ordinary files, and the next run's
# wipe_stage then succeeds without a container.
"$DOCKER" run --rm -v "$STAGE:/wipe" "$DOCKER_IMAGE" chown -R "$(id -u):$(id -g)" /wipe >/dev/null 2>&1 ||
  warn "could not chown $STAGE back to $(id -un) - wipe_stage will use a container next run"
}

if [ "$VERIFY_ONLY" = 1 ]; then
  log "verify only - not staging, not building, using what is already under $STAGE/build"
else
  stage_and_build
fi

# ---------------------------------------------------------------- 5. collect + verify
log "5/5 collecting $ROOTFS_IMG"
SRC="$STAGE/build/out/rootfs.img"
[ -s "$SRC" ] || die "no $SRC after a BUILD_DONE (see $BUILDLOG)"
( cd "$STAGE/build/out" && sha256sum -c --strict SHA256SUMS ) >/dev/null 2>&1 ||
  die "the built images do not match the SHA256SUMS the build itself wrote"
cp "$SRC" "$ROOTFS_IMG" || die "could not copy $SRC to $ROOTFS_IMG"
[ "$(sha256sum "$SRC" | cut -d' ' -f1)" = "$(sha256sum "$ROOTFS_IMG" | cut -d' ' -f1)" ] ||
  die "$ROOTFS_IMG differs from the built image - do not flash it"
echo "  $(stat -c %s "$ROOTFS_IMG") bytes, sha256 $(sha256sum "$ROOTFS_IMG" | cut -c1-16)"

feats() { dumpe2fs -h "$1" 2>/dev/null | awk -F': *' '/Filesystem features/{print $2}' | tr -s ' ' '\n' | grep -v '^$' | sort; }
bad=""
for f in $ROOTFS_FORBID; do
  feats "$ROOTFS_IMG" | grep -qx "$f" && bad="$bad $f"
done
if [ -n "$bad" ]; then
  die "the rootfs image sets ext4 features the vendor kernel cannot mount:$bad
     Add them to MKFS_EXTRA (^name in the -O list) and rebuild the image. Feature names
     mke2fs does not recognise make it reject the whole -O list, so verify each with:
       mke2fs -q -n -F -O ^name <any-image>"
fi
echo "  ok: no ext4 feature beyond the vendor kernel ($KVER)"
if [ -n "$PROVEN_ROOTFS" ] && [ -s "$PROVEN_ROOTFS" ]; then
  # Kept as information only: this comparison passed on the image that then failed to boot,
  # because the proven image was built for mainline 6.12. A like-for-like image is not proof
  # that the *vendor* kernel can mount it, which is what ROOTFS_FORBID exists for.
  echo "  vs the other board's image: $(comm -13 <(feats "$PROVEN_ROOTFS") <(feats "$ROOTFS_IMG") | tr '\n' ' ')[no extras]"
fi
PART_ROOT=""
if adb_cmd get-state >/dev/null 2>&1; then
  PART_ROOT=$(dev "blockdev --getsize64 /dev/disk/by-partlabel/rootfs" | tr -dc '0-9')
fi
if [ -n "$PART_ROOT" ]; then
  IMG_BYTES=$(stat -c %s "$ROOTFS_IMG")
  [ "$IMG_BYTES" -le "$PART_ROOT" ] || die "rootfs image $IMG_BYTES B does not fit the $PART_ROOT B partition"
  # Computed before the echo rather than nested inside it: a `$(awk '...')` inside a quoted
  # `$( )` inside a quoted string does not parse.
  PCT=$(awk -v a="$IMG_BYTES" -v b="$PART_ROOT" 'BEGIN{printf "%.0f%%", a*100/b}')
  echo "  ok: fits the rootfs partition ($PCT of it)"
else
  warn "rootfs partition size unreadable (stick offline) - fit will be checked at flash time"
fi

log "what the image actually contains"
img_has() { # $1 = dir inside the image  $2 = regex
  debugfs -R "ls -l $1" "$ROOTFS_IMG" 2>/dev/null | grep -qiE "$2"
}
for pair in "/lib/firmware:modem" "/lib/modules:$KVER" "/etc:inittab" "/sbin:init" "/bin:busybox"; do
  d=${pair%%:*}; pat=${pair##*:}
  if img_has "$d" "$pat"; then echo "  ok   $d has $pat"; else die "$d has no $pat - the rootfs is incomplete"; fi
done
printf '  /etc/openstick-build:\n'
debugfs -R "cat /etc/openstick-build" "$ROOTFS_IMG" 2>/dev/null | sed 's/^/    /'
debugfs -R "cat /etc/apk/repositories" "$ROOTFS_IMG" 2>/dev/null | sed 's/^/  repos | /'

cat <<EOF

Rootfs image ready: $ROOTFS_IMG

Next (host-side, still writing nothing to a board):
  scripts/76-fetch-adbd-payload.sh
  scripts/55-patch-alpine-image.sh $ROOTFS_IMG
  scripts/68-make-mainline-boot.sh OUT_IMG=$OUT/boot-mainline-$TAGL.img \\
      DTB_ALT=$DTB FALLBACK_KERNEL=$STAGE/vendor/boot/vmlinuz-$KVER \\
      FALLBACK_INITRD=$STAGE/vendor/boot/initrd.img-$KVER
  BOARD_ENV=$ROOT/config/board-$TAGL.env BACKUP=$BACKUP BOOT_IMG=$OUT/boot-mainline-$TAGL.img \\
      ROOTFS_IMG=$ROOTFS_IMG scripts/80-build-flashpack.sh
EOF
