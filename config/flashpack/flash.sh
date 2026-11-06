#!/usr/bin/env bash
# Self-contained installer for an OpenStick flash pack. Needs only `fastboot` and
# `sha256sum` on the host - nothing from the repository that built this pack.
#
#   ./flash.sh                       # dry run: verify the manifest, print the plan
#   COMMIT=1 ./flash.sh              # flash the full ladder, verifying each rung
#   COMMIT=1 ./flash.sh --only boot  # one rung only (rootfs | aboot | boot)
#   COMMIT=1 I_WIPE_ROOTFS=yes ./flash.sh          # required for the rootfs rung
#   SERIAL=<fastboot-serial> ./flash.sh            # pin the device (else pack.env's value)
#
# The order is the ladder that was measured to work, not an arbitrary one - see INSTALL.md.
# Each rung is verified before the next is attempted, because a failure at rung N is
# recoverable from rung N-1 and a failure at rung 3 with no checkpoint is not.
#
# This script never writes sbl1, rpm or tz (6.12 boots with the vendor ones in place, and
# they are the riskiest flash on this SoC) and never writes a calibration partition
# (modemst1/2, fsg, fsc, sec, cdt, devinfo) - those carry the radio identity.
set -eu

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACK_ENV="$HERE/pack.env"
MANIFEST="$HERE/MANIFEST.sha256"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

[ -f "$PACK_ENV" ] || die "no pack.env next to this script - not a flash pack directory"
# shellcheck source=/dev/null
. "$PACK_ENV"

ONLY=""
case "${1:-}" in
  --only) ONLY="${2:?--only needs rootfs|aboot|boot}" ;;
  "")     ;;
  *)      die "unknown argument '$1' (the only one is --only rootfs|aboot|boot)" ;;
esac
case "$ONLY" in ""|rootfs|aboot|boot) ;; *) die "--only takes rootfs, aboot or boot" ;; esac

SERIAL="${SERIAL:-${PACK_SERIAL:-}}"
FB="${FASTBOOT:-}"
if [ -z "$FB" ]; then
  # `[ -x fastboot ]` on the bare name would fail even when it IS on PATH: resolve to the
  # real path first, and keep the common no-PATH install as the fallback.
  FB=$(command -v fastboot || true)
  [ -n "$FB" ] || FB="$HOME/.local/bin/fastboot"
fi
[ -x "$FB" ] || die "no fastboot binary (set FASTBOOT=/path/to/fastboot)"

# The fastboot argv, pinned to one device when a serial is known. Without -s, fastboot takes
# whichever device it finds, so with two sticks attached it may not be the intended one.
# An ARRAY and not a `fb()` function, because every call site below is `timeout N fastboot …`
# and timeout execs a real binary: `timeout 300 fb flash rootfs …` fails to run at all, prints
# "No such file or directory" on stderr, and with no pipefail a `| grep OKAY` turns that into a
# successful exit status. Measured: rung 1 "flashed" 896 MB in seconds, printed nothing, and
# rebooted a board it had never written. scripts/lib.sh has the same rule for the same reason.
FB_CMD=( "$FB" )
if [ -n "$SERIAL" ]; then FB_CMD+=( -s "$SERIAL" ); fi

fb_present() {
  if [ -n "$SERIAL" ]; then
    timeout 10 "$FB" devices 2>/dev/null | grep -qE "^${SERIAL}[[:space:]]+fastboot"
  else
    timeout 10 "$FB" devices 2>/dev/null | grep -q fastboot
  fi
}

# ---------------------------------------------------------------- 0. integrity
say "flash pack: ${PACK_NAME:-unknown}"
echo "  board      ${PACK_BOARD_TAG:-?}   kernel ${PACK_KERNEL:-?}   alpine ${PACK_ALPINE:-?}"
echo "  built      ${PACK_BUILT:-?} by ${PACK_BUILT_BY:-?}"
echo "  default DTB ${PACK_DEFAULT_DTB:-?}"

[ -f "$MANIFEST" ] || die "no MANIFEST.sha256 - cannot verify this pack"
say "verifying MANIFEST.sha256"
# Hashed once and captured: the rootfs image is ~940 MB, so running the check twice to
# separate "show the failures" from "get the status" would double a multi-minute wait.
# --strict rejects lines naming files that are absent, so a truncated copy cannot pass.
set +e
manifest_out=$( cd "$HERE" && sha256sum -c --strict MANIFEST.sha256 2>&1 )
manifest_rc=$?
set -e
[ "$manifest_rc" = 0 ] || { printf '%s\n' "$manifest_out" | grep -v ': OK$' | sed 's/^/  /'
  die "manifest verification FAILED - do not flash this pack, re-copy it"; }
echo "  ok: $(printf '%s\n' "$manifest_out" | grep -c ': OK$' || true) files match their recorded sha256"

# ---------------------------------------------------------------- 1. the plan
say "plan"
plan() { # $1 = rung, $2 = partition, $3 = file, $4 = why
  [ -n "$ONLY" ] && [ "$ONLY" != "$1" ] && return 0
  local sz="(absent)"
  [ -f "$HERE/$3" ] && sz="$(stat -c %s "$HERE/$3") bytes"
  printf '  %-6s fastboot flash %-7s %-34s %s\n' "$1" "$2" "$(basename "$3")" "$sz"
  printf '         %s\n' "$4"
  return 0
}
plan rootfs rootfs rootfs/alpine-rootfs.img \
  "Alpine userspace; still boots on the STOCK boot.img and vendor 5.15 kernel (rung 1 is reversible)"
plan aboot  aboot  bootloader/aboot.mbn \
  "community lk1st: the factory aboot has no extlinux parser and will not start a mainline kernel"
plan aboot  hyp    bootloader/hyp.mbn \
  "matching qhypstub, flashed in the same rung while the vendor sbl1 still loads aboot"
plan boot   boot   boot/boot-mainline.img \
  "ext2 + extlinux.conf + mainline kernel; only readable by the community aboot"
[ -n "$ONLY" ] && echo "  (--only $ONLY: the other rungs are skipped)"

if [ "${COMMIT:-0}" != 1 ]; then
  cat <<EOF

DRY RUN - nothing was written. To flash:
  COMMIT=1 I_WIPE_ROOTFS=yes ./flash.sh
Read INSTALL.md first: the rootfs rung destroys whatever is on the stick today, and the
recovery path (./restore.sh) depends on the restore/ images in this pack matching the
board you are about to write.
EOF
  exit 0
fi

# The destructive guard fires before anything that needs a device: "you did not consent to
# wiping the rootfs" must be the answer you get with the stick unplugged, not "no board in
# fastboot" followed by a wait.
if { [ -z "$ONLY" ] || [ "$ONLY" = rootfs ]; } && [ "${I_WIPE_ROOTFS:-}" != yes ]; then
  die "the rootfs rung overwrites the stick's current system. Re-run with I_WIPE_ROOTFS=yes,
     or use '--only aboot' / '--only boot' to leave the rootfs alone."
fi

# ---------------------------------------------------------------- 2. preflight
say "preflight"
fb_present || die "no board in fastboot${SERIAL:+ matching serial $SERIAL}.
   From a running system: scripts/72-enter-fastboot.sh (or ./flash.sh from a host with adb).
   From a dead system: hold the EDL/reset button while plugging in."
echo "  fastboot devices: $(timeout 10 "$FB" devices 2>/dev/null | tr '\n' ' ')"

# Which aboot is answering decides whether the ext2 boot image can work at all.
ver_special=$(timeout 10 "${FB_CMD[@]}" getvar version-special 2>&1 | grep -oE 'version-special:[[:space:]]*.*' | head -1 || true)
echo "  version-special: ${ver_special:-<empty>}"
case "$ver_special" in
  *qhypstub*) warn "this is the FACTORY aboot (reports qhypstub). Flashing rung 3 before
       rung 2 lands you in fastboot with no OS. The ladder below does it in the right order." ;;
esac

# Partition sizes: an image larger than its partition is a hard stop, and fastboot's own
# error for it is easy to misread after 6 minutes of transfer.
fb_size() { # $1 = partition -> decimal bytes on stdout, empty if the bootloader will not say
  local h
  # `|| true`: getvar is unimplemented for some variables on some aboots, and a no-match grep
  # would otherwise fail the substitution under `set -e` instead of returning "unknown".
  # `[[:space:]]*` and not ` *`: fastboot separates the value with a TAB (`partition-size:rootfs:
  # \t 0xd4dfbe00`, measured on lk1st 37.0.1), so a space-only pattern never matches and the fit
  # check below silently degrades to "could not read partition-size".
  h=$(timeout 10 "${FB_CMD[@]}" getvar "partition-size:$1" 2>&1 |
      grep -oE 'partition-size:'"$1"':[[:space:]]*0x[0-9a-fA-F]+' | grep -oE '0x[0-9a-fA-F]+' | head -1 || true)
  if [ -n "$h" ]; then printf '%d' "$h" 2>/dev/null || true; fi
  return 0
}

# fb_flash <partition> <file> - flash one partition and never lose the reason it failed.
# A `fastboot flash … | grep 'Sending|OKAY|FAILED'` pipeline hid every other message (a stuck
# or refused transfer printed nothing at all), and with no pipefail the pipeline's status was
# grep's, so a failed flash was reported as success and the ladder walked on to reboot a board
# that had just been written. Capture everything, check the real status, then show it.
fb_flash() {
  local out rc=0
  out=$(timeout 1200 "${FB_CMD[@]}" flash "$1" "$2" 2>&1) || rc=$?
  printf '%s\n' "$out" | sed 's/^/    /'
  [ "$rc" = 0 ] || die "fastboot flash $1 $2 failed (rc=$rc) - the output above is why"
  return 0
}
for pair in "boot:boot/boot-mainline.img" "rootfs:rootfs/alpine-rootfs.img"; do
  part=${pair%%:*}; rel=${pair##*:}
  [ -f "$HERE/$rel" ] || continue
  img=$(stat -c %s "$HERE/$rel"); psz=$(fb_size "$part" || true)
  if [ -n "$psz" ]; then
    [ "$img" -le "$psz" ] || die "$rel ($img B) is larger than the $part partition ($psz B)"
    echo "  $part: image $img of $psz partition bytes ($(awk -v a="$img" -v b="$psz" 'BEGIN{printf "%.0f", a*100/b}')%)"
  else
    warn "could not read partition-size:$part - skipping the fit check"
  fi
done

# `fastboot fetch` is not implemented by either aboot on these boards, so nothing can be read
# back after a write. Verification is booting it, which is what wait_linux below is for.
wait_linux() { # $1 = seconds, $2 = label
  local i
  for i in $(seq 1 $(( $1 / 4 ))); do
    sleep 4
    if lsusb 2>/dev/null | grep -q '1d6b:0104'; then
      echo "  $2: USB gadget up at ~$((i * 4))s"
      return 0
    fi
    if [ "$i" -ge 4 ] && fb_present; then
      echo "  $2: back in fastboot at ~$((i * 4))s"
      return 1
    fi
  done
  echo "  $2: neither gadget nor fastboot after $1s"
  return 2
}

# ---------------------------------------------------------------- 3. rung 1: rootfs
if [ -z "$ONLY" ] || [ "$ONLY" = rootfs ]; then
  say "rung 1/3 - rootfs (Alpine userspace, stock boot.img untouched)"
  [ -f "$HERE/rootfs/alpine-rootfs.img" ] || die "rootfs/alpine-rootfs.img missing from the pack"
  printf '  fastboot flash rootfs  rootfs/alpine-rootfs.img\n'
  fb_flash rootfs "$HERE/rootfs/alpine-rootfs.img"
  say "rebooting to check rung 1 before touching the bootloader"
  timeout 30 "${FB_CMD[@]}" reboot >/dev/null 2>&1 || true
  if wait_linux 180 "rung 1"; then
    # Do not claim which kernel booted: the gadget appearing proves userspace came up, and the
    # stock boot.img is what rung 1 assumes - but a board whose `boot` partition was already
    # replaced (this repo did exactly that) answers with the *new* kernel here, and the old
    # wording asserted a fact this script never checked.
    echo "  ok: a Linux userspace came up on the current boot partition. If `boot` is still"
    echo "      factory, that is the vendor 5.15 kernel and restore/boot-stock.bin still"
    echo "      reverses it; check from the stick with: adb shell uname -r"
  else
    rc=$?
    die "rung 1 did not come up (rc=$rc). Stop here: the bootloader is still factory, so
       ./restore.sh or 'fastboot flash boot restore/boot-stock.bin' recovers it."
  fi
  fb_present || { say "re-entering fastboot for rung 2"; die "the board left fastboot and this
       pack cannot re-enter it without ssh. Use scripts/72-enter-fastboot.sh, or hold the
       EDL/reset button while plugging in, then re-run with '--only aboot'."; }
fi

# ---------------------------------------------------------------- 4. rung 2: aboot + hyp
if [ -z "$ONLY" ] || [ "$ONLY" = aboot ]; then
  say "rung 2/3 - community aboot + hyp"
  for f in bootloader/aboot.mbn bootloader/hyp.mbn; do
    [ -f "$HERE/$f" ] || die "$f missing from the pack"
  done
  # aboot first: while the vendor sbl1 is still loading it, a half-written pair is at worst
  # a board that falls back to fastboot rather than one that cannot start.
  printf '  fastboot flash aboot   bootloader/aboot.mbn\n'
  fb_flash aboot "$HERE/bootloader/aboot.mbn"
  printf '  fastboot flash hyp     bootloader/hyp.mbn\n'
  fb_flash hyp "$HERE/bootloader/hyp.mbn"
  say "rebooting: the stock Android boot.img must still work under the new aboot"
  timeout 30 "${FB_CMD[@]}" reboot >/dev/null 2>&1 || true
  if wait_linux 120 "rung 2"; then
    echo "  ok: the community aboot still boots the legacy Android image (expected)"
  else
    echo "  note: sitting in the new aboot's fastboot instead. That is acceptable here -"
    echo "        rung 3 replaces boot with the ext2 image the new aboot actually wants."
  fi
  fb_present || die "board is not in fastboot; get it back (72-enter-fastboot.sh or the button)
       and re-run with '--only boot'."
fi

# ---------------------------------------------------------------- 5. rung 3: boot
if [ -z "$ONLY" ] || [ "$ONLY" = boot ]; then
  say "rung 3/3 - ext2 + extlinux boot image (mainline kernel)"
  [ -f "$HERE/boot/boot-mainline.img" ] || die "boot/boot-mainline.img missing from the pack"
  printf '  fastboot flash boot    boot/boot-mainline.img\n'
  fb_flash boot "$HERE/boot/boot-mainline.img"
  say "rebooting into the mainline kernel"
  timeout 30 "${FB_CMD[@]}" reboot >/dev/null 2>&1 || true
  if wait_linux 180 "rung 3"; then
    echo "  ok: booted. First-boot tasks are in INSTALL.md (resize2fs, ssh key, password)."
  else
    die "rung 3 did not boot. Recovery: get back into fastboot and run ./restore.sh, which
       puts aboot/hyp/sbl1/rpm/tz/boot back to the factory images in restore/. If the
       default DTB is the problem, the alternates are already on the boot partition:
       cp /boot/extlinux/extlinux-handsome.conf /boot/extlinux/extlinux.conf && reboot"
  fi
fi

say "done"
