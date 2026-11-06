#!/usr/bin/env bash
# Flash these sticks over EDL (Sahara -> firehose), the download door they actually have.
#
#   scripts/78-flash-over-edl.sh status                      # programmer + GPT, read-only
#   scripts/78-flash-over-edl.sh w rootfs out/alpine-rootfs-ufi103s.img     # plan (dry run)
#   COMMIT=1 I_WIPE_ROOTFS=yes scripts/78-flash-over-edl.sh w rootfs out/alpine-rootfs-ufi103s.img
#   scripts/78-flash-over-edl.sh verify rootfs out/alpine-rootfs-ufi103s.img
#   scripts/78-flash-over-edl.sh reboot
#
# Why this exists next to fastboot. Two reasons, both measured here:
#   * the button. Holding it while plugging in puts this unit into EDL (`05c6:9008`), not into
#     fastboot - so when the installed userspace does not boot there is no software way back
#     into the bootloader, and EDL is the only door left. That is exactly the situation this
#     script was written in.
#   * readback. Neither aboot implements `fastboot fetch`, so a fastboot write can only be
#     verified by booting it. EDL can READ partitions (`r`/`rs`), so `verify` below compares
#     what is on the eMMC against the image that was written, byte for byte, without booting.
#
# The programmer is the DragonBoard 410c one (vendor/db410c-firmware, pinned by vendor.lock).
# Measured on the UFI103s: Sahara accepts it, and the firehose reports TargetName=MSM8916,
# MemoryName=eMMC and reads the board's real GPT - so no vendor-specific loader is needed.
#
# Nothing here writes a calibration partition. EDL has no idea which board it is talking to
# (every MSM8916 stick enumerates as 05c6:9008), so the cross-board protection is the deny
# list plus the single-device check, not a serial.
. "$(dirname "$0")/lib.sh"

EDL_PY=${EDL_PY:-$OUT/edl-venv/bin/python}
EDL_MAIN=${EDL_MAIN:-$OUT/edl-src/edl.py}
LOADER=${LOADER:-$ROOT/vendor/db410c-firmware/prog_emmc_firehose_8916.mbn}
GPT_CACHE=${GPT_CACHE:-$OUT/edl-gpt-$BOARD_TAG.txt}
# Partitions EDL will refuse to touch on any board. CALIB_PARTS from the board env plus the
# radio-identity ones, whether or not this board's env happens to name them all.
NEVER="modemst1 modemst2 fsg fsc sec cdt devinfo persist misc tzapp spla"
WRITABLE="sbl1 rpm tz hyp aboot boot rootfs"
# Reading 3.3 GiB back over EDL takes longer than writing it, so verify compares two windows
# that together cover the whole ext4 superblock, group descriptors and journal start.
VERIFY_BYTES=${VERIFY_BYTES:-$((64 * 1024 * 1024))}

[ -x "$EDL_PY" ] || die "no $EDL_PY - create the venv:
   python3 -m venv $OUT/edl-venv && $OUT/edl-venv/bin/pip install pyusb pyserial docopt colorama pycryptodome"
[ -s "$EDL_MAIN" ] || die "no $EDL_MAIN - bkerler/edl is not on PyPI under this name (the PyPI
   'edl' is an Edit Decision List library). Fetch the sources:
   https://api.github.com/repos/bkerler/edl/git/trees/master?recursive=1 | then curl each .py
   from raw.githubusercontent.com/bkerler/edl/master/<path> - ~800 KB, far faster than the
   65 MB repo tarball, most of which is loader binaries this board does not need."
[ -s "$LOADER" ] || die "no firehose programmer at $LOADER (see vendor.lock)"

# An ARRAY, not a function: every call below is `timeout N edl ...` and timeout execs a real
# binary. As a function the call dies with "No such file or directory" - which is exactly the
# bug that made config/flashpack/flash.sh report successful flashes it never performed.
EDL=( "$EDL_PY" "$EDL_MAIN" --loader="$LOADER" )

# The GPT straight off the device, which is the only partition map worth trusting here.
read_gpt() {
  local out
  out=$(timeout 180 "${EDL[@]}" printgpt 2>&1) || { printf '%s\n' "$out" | tail -8
    die "printgpt failed - is the board in EDL? (hold the button while plugging in, then
       lsusb | grep 05c6:9008). Output above."; }
  printf '%s\n' "$out" | tee "$GPT_CACHE" >/dev/null
}

# part_info <name> -> "offset_hex length_hex" from the cached (or freshly read) GPT
part_info() {
  [ -s "$GPT_CACHE" ] || read_gpt >/dev/null
  awk -v p="$1:" '$1 == p {
      for (i = 1; i <= NF; i++) { if ($i ~ /^Offset/) o = $(i + 1); if ($i ~ /^Length/) l = $(i + 1) }
      sub(/,$/, "", o); sub(/,$/, "", l); print o, l; exit }' "$GPT_CACHE"
}

# EDL is the one door that cannot identify a board: every MSM8916 stick enumerates as
# 05c6:9008 with no serial, and USB port paths move between plugs (measured: this stick was
# 3-3 in Debian and 3-2 in QDL). So ask the eMMC itself: read the `boot` partition, which the
# ladder never writes, and check the model string in its stock DTB. That is this unit's own
# vendor firmware describing itself, and it is the only per-unit proof available here.
assert_edl_board() {
  local info probe tagfile other
  info=$(part_info boot)
  [ -n "$info" ] || die "no boot partition in the EDL device's GPT - cannot identify the board"
  probe="$OUT/edl-boot-probe.bin"
  # Read the partition by name, all of it: in this Android boot image the DTB sits *after* a
  # 9,451,356-byte kernel, so a small head read (4 MiB, tried first) finds no model string at
  # all and reports an unidentifiable board. 64 MiB over EDL is ~20 s.
  if ! timeout 600 "${EDL[@]}" r boot "$probe" >/dev/null 2>&1; then
    die "could not read the 'boot' partition over EDL, so this script cannot prove which
     board is attached. Refusing to write: with two sticks in the drawer and no serial in
     QDL mode, guessing is how one board gets the other's images."
  fi
  tagfile="$OUT/edl-boot-probe.strings"
  strings -a "$probe" > "$tagfile" 2>/dev/null || true
  if grep -qi "$BOARD_TAG" "$tagfile"; then
    echo "  ok: the EDL device's own stock boot partition names $BOARD_TAG"
  elif grep -qiE 'ufi-?001c|ufi-?001b|ufi-?103s|ufi-?003|openstick' "$tagfile"; then
    other=$(grep -oiE 'ufi-?[0-9]+[a-z]?' "$tagfile" | sort -u | tr '\n' ' ')
    rm -f "$probe"
    die "the EDL device's boot partition names [$other] but this run is configured for
     $BOARD_TAG (BOARD_ENV=$BOARD_ENV). That is the other stick - unplug it, or re-run with
     BOARD_ENV pointing at that board's env. NOT writing."
  else
    rm -f "$probe"
    die "the EDL device's boot partition carries no recognizable board model string - cannot
     prove which board this is, so nothing is written over EDL without it."
  fi
  rm -f "$probe" "$tagfile"
}

cmd=${1:-status}
shift || true

case "$cmd" in
# ------------------------------------------------------------------ status
status)
  log "1/3 EDL door"
  n=$(lsusb 2>/dev/null | grep -c '05c6:9008')
  [ "$n" = 1 ] || die "$n devices are in EDL. EDL carries no serial, so with more than one
     attached this script cannot tell which stick it is about to write. Unplug the others."
  echo "  one board in QDL: $(lsusb | grep '05c6:9008')"
  echo "  programmer: $LOADER ($(stat -c %s "$LOADER") bytes)"
  log "2/3 firehose identity + GPT"
  read_gpt >/dev/null
  # TargetName/MemoryName/Version are only printed when this call is the one that loads the
  # programmer; if the board is already sitting in a firehose session from an earlier call, edl
  # goes straight to the table. So report what is there, and say so when it is absent - with
  # pipefail a bare `grep` that matches nothing would end the script at a read-only status run.
  grep -E 'Mode detected|TargetName|MemoryName|Version=|^Total disk' "$GPT_CACHE" |
    sed 's/^/  /' || echo "  (identity lines absent - the programmer was already loaded by an earlier call)"
  log "3/3 partitions"
  grep -oE '^[a-z0-9_]+: +Offset 0x[0-9a-fA-F]+, Length 0x[0-9a-fA-F]+' "$GPT_CACHE" |
    sed 's/Offset//g; s/Length//g; s/,//g' | awk '{printf "  %-12s %18s %18s%s\n", $1, $2, $3,
      ($1 ~ /^(modemst1|modemst2|fsg|fsc|sec|cdt|devinfo)$/) ? "   <- calibration, never written" : ""}'
  echo "  $(grep -cE '^[a-z0-9_]+: +Offset' "$GPT_CACHE") partitions, cached at $GPT_CACHE"
  ;;
# ------------------------------------------------------------------ write
w|flash)
  part=${1:?usage: 78-flash-over-edl.sh w <partition> <image>}
  img=${2:?usage: 78-flash-over-edl.sh w <partition> <image>}
  [ -s "$img" ] || die "no image at $img"
  case " $NEVER " in *" $part "*) die "refusing to write '$part': it carries radio/calibration identity" ;; esac
  case " $WRITABLE " in *" $part "*) : ;; *) die "'$part' is not in the writable set ($WRITABLE)" ;; esac
  if [ "$part" = rootfs ] && [ "${COMMIT:-0}" = 1 ] && [ "${I_WIPE_ROOTFS:-}" != yes ]; then
    die "rootfs holds the installed system. Re-run with I_WIPE_ROOTFS=yes to confirm the wipe."
  fi
  n=$(lsusb 2>/dev/null | grep -c '05c6:9008')
  [ "$n" = 1 ] || die "$n devices in EDL; EDL has no serial, so this cannot be resolved by pinning"
  read_gpt >/dev/null
  assert_edl_board
  info=$(part_info "$part")
  [ -n "$info" ] || die "partition '$part' is not in this board's GPT ($GPT_CACHE)"
  poff=${info%% *}; plen=${info##* }
  psz=$((  plen ))
  isz=$(stat -c %s "$img")
  [ "$isz" -le "$psz" ] || die "$img ($isz B) is larger than partition $part ($psz B)"
  log "write $part over EDL"
  printf '  partition  %s @ %s, %d bytes (%d%% of it filled by the image)\n' \
    "$part" "$poff" "$psz" "$(( isz * 100 / psz ))"
  printf '  image      %s (%d bytes)\n' "$img" "$isz"
  printf '  command    edl --loader=%s w %s %s\n' "$(basename "$LOADER")" "$part" "$img"
  if [ "${COMMIT:-0}" != 1 ]; then
    echo "  DRY RUN - nothing was written. Re-run with COMMIT=1"
    [ "$part" = rootfs ] && echo "  (rootfs also needs I_WIPE_ROOTFS=yes)"
    exit 0
  fi
  rc=0
  timeout 3600 "${EDL[@]}" w "$part" "$img" 2>&1 | grep -viE 'DEBUG|logbuf|Trying|Running|Supported|^\s*$|^-{5,}|^firehose$' |
    sed 's/^/    /' || rc=$?
  [ "$rc" = 0 ] || die "edl w $part exited $rc"
  echo "  written. Now verify it before rebooting: $0 verify $part $img"
  ;;
# ------------------------------------------------------------------ verify
verify)
  part=${1:?usage: 78-flash-over-edl.sh verify <partition> <image>}
  img=${2:?usage: 78-flash-over-edl.sh verify <partition> <image>}
  [ -s "$img" ] || die "no image at $img"
  read_gpt >/dev/null
  assert_edl_board          # a verified write to the wrong board is worse than no write
  info=$(part_info "$part")
  [ -n "$info" ] || die "partition '$part' is not in this board's GPT (run: $0 status)"
  # `rs <sector>` addresses the LUN, not the partition: reading sector 0 gives the GPT, which
  # matches nothing in the image and looks like a corrupt write. `w <name>` resolves the offset
  # internally (the write log said "to sector 659456"), so a readback has to add it itself.
  # 0x14200000/512 = 659456, which is the sector the write log reported using ✔ same arithmetic.
  start=$(( ${info%% *} / 512 ))
  isz=$(stat -c %s "$img")
  want=$(( VERIFY_BYTES < isz ? VERIFY_BYTES : isz ))
  log "read back $part (partition starts at LUN sector $start) and compare the first $want bytes"
  tmp="$OUT/edl-readback-$part.bin"
  secs=$(( (want + 511) / 512 ))
  rc=0
  timeout 1800 "${EDL[@]}" rs "$start" "$secs" "$tmp" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 0 ] || die "readback failed (rc=$rc) - EDL reads are supported, so this is not the
     'fastboot cannot fetch' limitation; check the board is still in EDL"
  [ -s "$tmp" ] || die "readback produced an empty file"
  # The read is a whole number of sectors, so it can run past the image by up to 511 bytes of
  # whatever follows it in the partition. Hash exactly `want` bytes from both sides, or a
  # perfectly written small partition (aboot: 322540 B -> 322560 B read) reports a mismatch.
  got=$(stat -c %s "$tmp")
  [ "$got" -ge "$want" ] || die "readback returned $got bytes, expected at least $want"
  have=$(head -c "$want" "$tmp" | sha256sum | cut -d' ' -f1)
  exp=$(head -c "$want" "$img" | sha256sum | cut -d' ' -f1)
  if [ "$have" = "$exp" ]; then
    echo "  ok: the partition's first $want bytes match the image (sha256 ${have:0:16}...)"
  else
    die "$part on the eMMC does not match the image: sha256 ${have:0:16} vs expected ${exp:0:16}
     over the first $want bytes. Do not reboot into it - flash again or restore."
  fi
  if [ "$isz" -gt "$want" ]; then
    tailwant=$(( VERIFY_BYTES < isz - want ? VERIFY_BYTES : isz - want ))
    tailrel=$(( (isz - tailwant) / 512 * 512 ))
    tailsec=$(( start + tailrel / 512 ))
    log "and the last $(( tailwant / 1024 / 1024 )) MiB (image offset $tailrel = LUN sector $tailsec)"
    timeout 1800 "${EDL[@]}" rs "$tailsec" $(( (tailwant + 511) / 512 )) "$tmp.tail" >/dev/null 2>&1 ||
      die "tail readback failed"
    a=$(sha256sum "$tmp.tail" | cut -c1-16)
    b=$(dd if="$img" bs=1 skip="$tailrel" status=none | sha256sum | cut -c1-16)
    if [ "$a" = "$b" ]; then echo "  ok: tail matches ($a)"; else die "tail mismatch: eMMC $a vs image $b"; fi
    rm -f "$tmp.tail"
  fi
  rm -f "$tmp"
  echo "  verified without booting, which fastboot cannot do on this board."
  ;;
# ------------------------------------------------------------------ reboot
reboot)
  log "leaving EDL"
  # `reset --resetmode=reboot` asks the firehose to reboot; many MSM8916 sticks come back at the
  # PBL instead, so the power cycle is part of the instructions rather than a fallback hope.
  timeout 60 "${EDL[@]}" reset --resetmode=reboot 2>&1 | tail -3 | sed 's/^/  /' || true
  echo "  If nothing enumerates within ~30 s, unplug the stick, wait 5 s and plug it in again:"
  echo "    watch: lsusb | grep -E '18d1|05c6|1d6b:0104'   adb devices   fastboot devices"
  ;;
*) die "unknown command '$cmd' (status | w | verify | reboot)" ;;
esac
