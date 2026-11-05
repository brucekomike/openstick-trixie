#!/usr/bin/env bash
# Assemble out/adbd-payload/ - the two files that give an Alpine (musl) OpenStick a working
# `adb shell` as root. Read-only on any device it touches.
#
#   scripts/76-fetch-adbd-payload.sh            # assemble + verify
#   FORCE=1 scripts/76-fetch-adbd-payload.sh    # re-pull even if the hashes already match
#
# Why these two files and not a package (all measured 2026-11-06):
#   * Alpine has NO adbd. `android-tools-adb` ships only usr/bin/adb (the client), and there
#     is no adbd subpackage in v3.24 main, community or the pmOS v25.12 overlay.
#   * Alpine edge/testing does have one (`adbd-0_git20261018-r0`, from
#     gitlab.com/android_translation_layer/art_standalone - the build Waydroid uses). It is
#     musl-native, which is attractive, but it is the wrong daemon: it contains no
#     `/dev/usb-ffs` path and no FUNCTIONFS_DESCRIPTORS_MAGIC in itself or in the three libs
#     it needs, i.e. no USB gadget transport. It also depends on `art_standalone`, which is a
#     whole Android runtime - 29.5 MB installed, dalvikvm/dex2oat/libart, and libicu*.so.78
#     that only exists in edge, so it would drag an ICU upgrade into a v3.24 system.
#   * The vendor adbd that shipped on these sticks is the right one: `usb_linux_client.c`,
#     `init_functionfs` and the literal `/dev/usb-ffs/adb/ep0..ep2` paths are all in it. It is
#     glibc, and this rootfs is musl, so it runs under `gcompat` (apk). Its whole dependency
#     set is libc.so.6 + libpthread.so.0 (both gcompat), libz.so.1 (already in the base image)
#     and libcrypto.so.1.1 - and libcutils is statically linked in, so no Android libs.
#   * libcrypto.so.1.1 cannot be substituted. adbd references the *versioned* symbol
#     `RSA_verify@OPENSSL_1_1_0`, and Alpine 3.24 ships libcrypto.so.3 which exports
#     `RSA_verify@@OPENSSL_3.0.0`. A symlink therefore does not resolve; the real 1.1 library
#     is required. It comes from Debian 11's libssl1.1 (arm64), whose own extra dependency
#     libdl.so.2 is satisfied by symlinking it to libgcompat.so.0.
. "$(dirname "$0")/lib.sh"

DEST="$OUT/adbd-payload"
LIBCRYPTO_DEV_PATH=/usr/lib/aarch64-linux-gnu/libcrypto.so.1.1
# Recorded from the payloads that were proven to work on the UFI001C (Alpine 3.24.2,
# kernel 6.12.1-msm8916): root `adb shell`, and binary-safe push/pull (md5 identical).
WANT_ADBD_SHA256=57a04a037a9489909b12f1f4d6f57d50f6bcc5c70bcd5c1253f666ae58b89a10
WANT_LIBCRYPTO_SHA256=9c51e429b006965f053fcee5fc012f428fa8b3d3669b30db1145e1476d15c228

mkdir -p "$DEST"
sha_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

log "1/4 adbd (the vendor daemon, from a partition backup - not a package)"
if [ "${FORCE:-0}" != 1 ] && [ "$(sha_of "$DEST/adbd")" = "$WANT_ADBD_SHA256" ]; then
  echo "  have it, sha256 matches"
else
  src=""
  for c in "$BACKUP/usr-bin-adbd" "$ROOT"/backup*/usr-bin-adbd; do
    [ -s "$c" ] && { src="$c"; break; }
  done
  if [ -z "$src" ] && adb_cmd get-state >/dev/null 2>&1; then
    echo "  no backup copy; pulling from the connected Debian stick"
    tmp="$STAGE_DIR.adbd"
    dev "cp $ADBD_BIN $tmp" >/dev/null
    pull "adbd" "$DEST/adbd" >/dev/null || die "adb pull of $ADBD_BIN failed"
    dev "rm -f $tmp" >/dev/null
    src="$DEST/adbd"
  fi
  [ -n "$src" ] || die "no adbd source. Run scripts/20-backup.sh against a stick still on the
     vendor Debian image, or copy its $ADBD_BIN to $DEST/adbd by hand."
  [ "$src" = "$DEST/adbd" ] || install -m 755 "$src" "$DEST/adbd"
  echo "  from $src"
fi
[ "$(sha_of "$DEST/adbd")" = "$WANT_ADBD_SHA256" ] ||
  warn "adbd sha256 is $(sha_of "$DEST/adbd"), expected $WANT_ADBD_SHA256 - a different vendor build?"

log "2/4 libcrypto.so.1.1 (Debian 11 libssl1.1, arm64 - the versioned RSA_verify provider)"
if [ "${FORCE:-0}" != 1 ] && [ "$(sha_of "$DEST/libcrypto.so.1.1")" = "$WANT_LIBCRYPTO_SHA256" ]; then
  echo "  have it, sha256 matches"
else
  if adb_cmd get-state >/dev/null 2>&1 && \
     dev "test -s $LIBCRYPTO_DEV_PATH && echo PRESENT" | grep -q PRESENT; then
    echo "  pulling $LIBCRYPTO_DEV_PATH from the connected Debian stick"
    # adb pull is binary-safe; adb shell is not (the PTY rewrites bytes), so never cat it.
    adb_cmd pull "$LIBCRYPTO_DEV_PATH" "$DEST/libcrypto.so.1.1" >/dev/null 2>&1 ||
      die "adb pull of $LIBCRYPTO_DEV_PATH failed"
  else
    die "no libcrypto.so.1.1 and no Debian 11 stick connected. Either plug one in and re-run,
       or extract it from Debian's arm64 libssl1.1 package:
         dpkg-deb -x libssl1.1_*_arm64.deb x && cp x$LIBCRYPTO_DEV_PATH $DEST/
       (Debian 11 is archived; see archive.debian.org/debian/pool/main/o/openssl/)"
  fi
fi
[ "$(sha_of "$DEST/libcrypto.so.1.1")" = "$WANT_LIBCRYPTO_SHA256" ] ||
  warn "libcrypto sha256 is $(sha_of "$DEST/libcrypto.so.1.1"), expected $WANT_LIBCRYPTO_SHA256"

log "3/4 verify the properties this whole approach rests on"
fail=0
chk() { # $1 = description, $2 = 0/1
  if [ "$2" = 0 ]; then echo "  ok   $1"; else echo "  FAIL $1"; fail=1; fi
}
# errexit AND pipefail off for the checks below, and both matter:
#   * errexit, because each check is *expected* to be able to fail and be reported rather
#     than abort the script at the first FAIL;
#   * pipefail, because `grep -q` exits the moment it matches, which closes the pipe and
#     kills the producer with SIGPIPE (141). With pipefail on, a *successful* match against
#     a large producer (readelf --dyn-syms, strings) reports the whole pipeline as failed -
#     so the checks with big outputs FAIL while the small ones pass. Measured, not theorised.
set +e
set +o pipefail
readelf -d "$DEST/adbd" 2>/dev/null | grep -q 'libcrypto.so.1.1'
chk "adbd NEEDs libcrypto.so.1.1" $?
readelf --dyn-syms -W "$DEST/adbd" 2>/dev/null | grep -q 'RSA_verify@OPENSSL_1_1_0'
chk "adbd wants the versioned RSA_verify@OPENSSL_1_1_0 (so .so.3 cannot substitute)" $?
readelf --dyn-syms -W "$DEST/libcrypto.so.1.1" 2>/dev/null | grep -q 'RSA_verify@@OPENSSL_1_1_0'
chk "libcrypto.so.1.1 provides RSA_verify@@OPENSSL_1_1_0" $?
strings -a "$DEST/adbd" | grep -q '/dev/usb-ffs/adb/ep0'
chk "adbd has the functionfs USB transport (/dev/usb-ffs/adb/ep0)" $?
readelf -d "$DEST/libcrypto.so.1.1" 2>/dev/null | grep -q 'libdl.so.2'
chk "libcrypto NEEDs libdl.so.2 (gcompat lacks it - the image patch symlinks it)" $?
set -e
set -o pipefail
# GLIBC_2.17 is the ceiling gcompat is comfortable with; a newer build could still work but
# is not what was tested, so say so rather than failing the run.
maxglibc=$(readelf --dyn-syms -W "$DEST/adbd" 2>/dev/null | grep -oE 'GLIBC_[0-9.]+' | sort -uV | tail -1)
echo "  info highest glibc symbol version required: ${maxglibc:-none}"
[ "$fail" = 0 ] || die "payload verification failed - do not patch an image with it"

log "4/4 result"
( cd "$DEST" && sha256sum adbd libcrypto.so.1.1 > SHA256SUMS )
ls -l "$DEST" | sed 's/^/  /'
cat <<EOF

  $DEST/SHA256SUMS written.

Consumed by scripts/55-patch-alpine-image.sh, which injects into the rootfs image:
    adbd              -> /usr/local/sbin/adbd          (0755)
    libcrypto.so.1.1  -> /usr/lib/libcrypto.so.1.1     (0644)
    /lib/libdl.so.2   -> symlink to libgcompat.so.0
and by config/alpine-gadget/setup_gadget.sh, which mounts functionfs, starts adbd with an
explicit PATH (must include /sbin, where apk lives), waits for ep1, then links ffs.adb.
The image also needs the \`gcompat\` apk - scripts/device/alpine-onstick.sh installs it.
EOF
