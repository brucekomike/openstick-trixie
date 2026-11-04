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
# seconds and turns output into CRLF noise. exec-out is raw and much faster, so use it
# for reads and fall back to shell if it is unavailable.
ADB_BIN=(adb)
if [ -n "${ADB_SERIAL:-}" ]; then ADB_BIN+=(-s "$ADB_SERIAL"); fi

# dev <shell-command-string> - one device command, capped at 60s so a hanging
# qmicli/nmcli call cannot stall a whole snapshot.
dev() {
  timeout 60 "${ADB_BIN[@]}" exec-out "$*" 2>/dev/null ||
    timeout 60 "${ADB_BIN[@]}" shell "$*" | tr -d '\r'
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
  [ -s "$BACKUP/$1" ] || die "missing $BACKUP/$1 - run scripts/20-device-backup.sh first"
}
