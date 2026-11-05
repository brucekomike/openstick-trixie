#!/usr/bin/env bash
# Shared helpers. Design rule: nothing in this repo writes to the stick unless
# COMMIT=1 is set, and every state-changing command is printed before it runs.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONF="$ROOT/config"
NOTES="$ROOT/notes"
# Both are overridable, and both have to be: this probe holds two boards whose backups are
# NOT interchangeable (`backup/` = UFI001C, `backup-ufi103s/` = UFI103s). They answer adb as
# the same 0123456789, so a hardcoded path here silently hands one board the other's boot
# image, DTB and partition dumps. require_board below is what proves the pairing is right.
BACKUP="${BACKUP:-$ROOT/backup}"
OUT="$ROOT/out"
STAMP="$(date -u +%Y%m%d-%H%M%S)"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing host command: $1"; }

# shellcheck source=/dev/null
. "${BOARD_ENV:-$CONF/board-ufi103s.env}"

adb_cmd() {
  if [ -n "${ADB_SERIAL:-}" ]; then adb -s "$ADB_SERIAL" "$@"; else adb "$@"; fi
}

# adb shell allocates a PTY and runs a login shell per call, which on this stick takes
# seconds and turns output into CRLF noise. exec-out is raw and much faster - but THIS
# adbd (a 2022 vendor build) answers exec-out with "error: closed", so support is probed
# once per run instead of assumed. Binary transfers never go through either: they are
# staged on the device and moved with `adb pull`, because a PTY would rewrite bytes.
ADB_BIN=(adb)
if [ -n "${ADB_SERIAL:-}" ]; then ADB_BIN+=(-s "$ADB_SERIAL"); fi

EXECOUT_OK=""
exec_out_supported() {
  # dev() is called from $(...) subshells, so a shell variable cannot cache this across
  # calls - the file does, and without it every single device command would warn.
  local mark="$OUT/.execout-probe"
  if [ -z "$EXECOUT_OK" ] && [ -f "$mark" ]; then EXECOUT_OK=$(cat "$mark"); fi
  if [ -z "$EXECOUT_OK" ]; then
    mkdir -p "$OUT"
    if timeout 20 "${ADB_BIN[@]}" exec-out "printf OS_OK" 2>/dev/null | grep -q OS_OK; then
      EXECOUT_OK=1
    else
      EXECOUT_OK=0
      warn "this adbd has no working exec-out; falling back to 'adb shell' for text"
    fi
    echo "$EXECOUT_OK" > "$mark"
  fi
  [ "$EXECOUT_OK" = 1 ]
}

# dev <shell-command-string> - one device command, capped at 60s so a hanging
# qmicli/nmcli call cannot stall a whole snapshot.
dev() {
  if exec_out_supported; then
    timeout 60 "${ADB_BIN[@]}" exec-out "$*" 2>/dev/null | tr -d '\r'
  else
    timeout 60 "${ADB_BIN[@]}" shell "$*" 2>/dev/null | tr -d '\r'
  fi
}

# Where binaries are staged on the stick before `adb pull`. NOT /data/local/tmp - that is
# an Android convention and does not exist on this Debian rootfs. /var/tmp is on the
# rootfs itself (2.2 GB free); /tmp is a tmpfs bounded by the 461 MB of RAM.
STAGE_DIR=/var/tmp/openstick-stage

# dev_write <device-command> <name> - run a command whose stdout becomes a staged file.
# adb shell does not propagate exit codes, so the success marker and the size are read
# back from the device instead of trusting the return status. Prints the staged size.
dev_write() {
  local cmd="$1" name="$2" res tmp
  # Separate statement: bash expands every word of a `local` command before assigning any
  # of them, so `local name=$2 tmp=...$name` under `set -u` reads an unset `name`.
  tmp="$STAGE_DIR.$name"
  # Not dev(): dev caps at 60s, and a device-side rootfs tar takes minutes.
  res=$(timeout 3600 "${ADB_BIN[@]}" shell \
        "sh -c '$cmd' > $tmp && echo STAGED \$(stat -c %s $tmp) || { rm -f $tmp; echo STAGE_FAILED; }" \
        2>/dev/null | tr -d '\r')
  case "$res" in
    *STAGE_FAILED*) warn "device-side write failed for $name"; return 1 ;;
    *STAGED*) res="${res##*STAGED }"; echo "$res" | awk '{print $1}'; return 0 ;;
    *) warn "no staging marker for $name ($res)"; return 1 ;;
  esac
}

# pull <name> <host-path> - binary-safe copy of a staged file, md5-verified, temp removed.
# The md5 comparison is what proves the transfer was not mangled: adb's PTY rewrites bytes
# and some adbd builds truncate, so a size match alone is not enough.
pull() {
  local name="$1" host="$2" tmp dmd5 hmd5
  tmp="$STAGE_DIR.$name"
  dmd5=$(dev "md5sum $tmp" | awk '{print $1}')
  "${ADB_BIN[@]}" pull "$tmp" "$host" >/dev/null 2>&1 || { warn "adb pull failed for $name"; return 1; }
  hmd5=$(md5sum "$host" | awk '{print $1}')
  if [ -n "$dmd5" ] && [ "$dmd5" != "$hmd5" ]; then
    warn "md5 mismatch pulling $name (device $dmd5 != host $hmd5) - copy is corrupt"
    return 1
  fi
  dev "rm -f $tmp" >/dev/null
  [ -z "$dmd5" ] && echo "  (no device md5 for $name - size-only check)" || echo "  md5 verified"
  return 0
}

require_device() {
  command -v adb >/dev/null 2>&1 || die "missing host command: adb"
  adb_cmd get-state >/dev/null 2>&1 || die "device not reachable over adb (check 'adb devices', cable, and that it is not in fastboot)"
  require_board
  log "device online: $(dev 'uname -n' | tr -d '\r')"
}

# --- board identity -------------------------------------------------------
# Two physically different sticks in this probe answer adb as the same 0123456789 and can
# both be attached at once, so no transport handle here is trusted to identify a board.
# BOARD_TAG/BOARD_SERIALNO come from the sourced env; require_board checks them against
# what the device actually reports, and every fastboot call is pinned to the serial.

fb_resolve() {
  [ -n "${FB:-}" ] && return 0
  FB=${FASTBOOT:-$HOME/.local/bin/fastboot}
  command -v "$FB" >/dev/null 2>&1 || FB=$(command -v fastboot || true)
  [ -n "$FB" ] || die "no fastboot binary (see scripts/README: ~/.local/bin/fastboot from platform-tools)"
}

# fb <args...> - fastboot for THIS board. Without -s, fastboot takes whichever device it
# finds and only complains when there are two, so a lone other-board unit sitting in
# fastboot would happily accept this board's image.
fb() {
  fb_resolve
  if [ -n "${BOARD_SERIALNO:-}" ]; then "$FB" -s "$BOARD_SERIALNO" "$@"; else "$FB" "$@"; fi
}

# fb_present - is this board (not merely some board) in fastboot?
fb_present() {
  fb_resolve
  if [ -n "${BOARD_SERIALNO:-}" ]; then
    timeout 10 "$FB" devices 2>/dev/null | grep -qE "^${BOARD_SERIALNO}[[:space:]]+fastboot"
  else
    timeout 10 "$FB" devices 2>/dev/null | grep -q fastboot
  fi
}

require_board() {
  [ -n "${BOARD_TAG:-}" ] ||
    die "no BOARD_TAG in ${BOARD_ENV:-$CONF/board-ufi103s.env} - cannot tell the two sticks apart"
  local live="" src="" sn=""
  if adb_cmd get-state >/dev/null 2>&1; then
    live=$(dev "tr '\\0' '\\n' < /proc/device-tree/model" | grep -oE 'UFI[A-Za-z0-9]+' | tail -1)
    sn=$(dev "tr -d '\\0' < /proc/cmdline" | grep -oE 'androidboot\.serialno=[0-9a-f]+' | cut -d= -f2)
    src="adb DT model${sn:+, serialno $sn}"
    if [ -n "${BOARD_SERIALNO:-}" ] && [ -n "$sn" ] && [ "$sn" != "$BOARD_SERIALNO" ]; then
      die "device serialno is $sn but this run is configured for $BOARD_SERIALNO - wrong stick plugged in"
    fi
  elif fb_present; then
    live="$BOARD_TAG"; src="fastboot serial ${BOARD_SERIALNO:-unknown}"
  fi
  [ -n "$live" ] ||
    die "cannot identify the board: no adb, and no fastboot device matching ${BOARD_SERIALNO:-<serial>}"
  [ "${live,,}" = "${BOARD_TAG,,}" ] ||
    die "live board is '$live' ($src) but this run is configured for '$BOARD_TAG' -
       point BOARD_ENV= and BACKUP= at that board's files instead"
  # A partition backup is per-unit, not per-model: prove this tree's boot image carries the tag.
  if [ -s "$BACKUP/boot-stock.bin" ]; then
    python3 "$ROOT/tools/bootimg.py" info "$BACKUP/boot-stock.bin" 2>/dev/null | grep -qi "$BOARD_TAG" ||
      die "$BACKUP/boot-stock.bin does not mention $BOARD_TAG - that is another board's backup"
  fi
  log "board: $live ($src); backup tree $BACKUP"
}

# run <cmd...>  - host command, printed first, executed only with COMMIT=1
run() {
  printf '  [host] %s\n' "$*"
  [ "${COMMIT:-0}" = "1" ] && eval "$@" || true
}

# devrun <cmd...> - device command, printed first, executed only with COMMIT=1
devrun() {
  printf '  [stick] adb shell %s\n' "$*"
  [ "${COMMIT:-0}" = "1" ] && dev "$*" | tr -d '\r' || true
}

require_backup() {
  [ -s "$BACKUP/$1" ] || die "missing $BACKUP/$1 - run scripts/20-backup.sh first"
}

# dev_avail_mb - free space on the stick's rootfs, in MiB. df -BG prints *GiB* (and rounds
# up), which is what made a 2.2G-free stick look like "3 MB free" to the first version of
# this check, so ask for an explicit block size instead of guessing at the unit suffix.
dev_avail_mb() {
  dev "df -P --block-size=1M / | awk 'NR==2{print \$4}'" | tr -dc '0-9'
}

# detect_gadget_if - set HOST_GADGET_IF/HOST_GADGET_IP from the live host, not from the env
# file. The USB gadget netdev is re-created with a fresh name and a fresh DHCP lease on every
# replug, so the recorded value goes stale the moment the stick is unplugged; acting on it
# prints sudo lines that NAT the wrong interface and leaves the stick with no internet.
# Returns non-zero (leaving the env values in place) when no such interface exists yet.
detect_gadget_if() {
  local pre found ip
  pre="${STICK_GADGET_NET%/*}"; pre="${pre%.*}."          # 10.42.0.0/24 -> 10.42.0.
  # index() rather than a regex: awk unescapes `-v` values, so a hand-escaped "\." arrives as
  # a plain "." (and warns about it), silently turning an exact prefix test into a wildcard.
  found=$(ip -o -4 addr show 2>/dev/null |
    awk -v p="$pre" '$2 != "lo" && index($4, p) == 1 {print $2; exit}')
  [ -n "$found" ] || return 1
  ip=$(ip -o -4 addr show "$found" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
  [ -n "$ip" ] || return 1
  HOST_GADGET_IF="$found"
  HOST_GADGET_IP="$ip"
}

# check_uplink_if - warn when the env's uplink is not the one carrying the default route.
check_uplink_if() {
  local live
  live=$(ip -o -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
  [ -n "$live" ] && [ "$live" != "$HOST_UPLINK_IF" ] &&
    warn "HOST_UPLINK_IF=$HOST_UPLINK_IF but the default route is on $live - NAT the latter"
  return 0
}
