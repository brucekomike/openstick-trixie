#!/usr/bin/env bash
# Shared helpers. Design rule: nothing in this repo writes to the stick unless
# COMMIT=1 is set, and every state-changing command is printed before it runs.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONF="$ROOT/config"
NOTES="$ROOT/notes"
BACKUP="$ROOT/backup"
OUT="$ROOT/out"
STAMP="$(date -u +%Y%m%d-%H%M%S)"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing host command: $1"; }

# shellcheck source=/dev/null
. "$CONF/board-ufi103s.env"

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
  if [ -z "$EXECOUT_OK" ]; then
    if timeout 20 "${ADB_BIN[@]}" exec-out "printf OS_OK" 2>/dev/null | grep -q OS_OK; then
      EXECOUT_OK=1
    else
      EXECOUT_OK=0
      warn "this adbd has no working exec-out; falling back to 'adb shell' for text"
    fi
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

# dev_write <device-command> <device-temp-path> - run a command whose stdout is a file
# on the stick (dd, tar, ...). Returns non-zero if the command failed.
dev_write() {
  local cmd="$1" tmp="$2"
  timeout 1800 "${ADB_BIN[@]}" shell "sh -c '$cmd > $tmp'" >/dev/null 2>&1
}

# pull <device-temp-path> <host-path> - binary-safe copy, then remove the temp.
pull() {
  local tmp="$1" host="$2"
  "${ADB_BIN[@]}" pull "$tmp" "$host" >/dev/null 2>&1 || return 1
  timeout 30 "${ADB_BIN[@]}" shell "rm -f $tmp" >/dev/null 2>&1 || true
}

require_device() {
  command -v adb >/dev/null 2>&1 || die "missing host command: adb"
  adb_cmd get-state >/dev/null 2>&1 || die "device not reachable over adb (check 'adb devices', cable, and that it is not in fastboot)"
  log "device online: $(dev 'uname -n' | tr -d '\r')"
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
