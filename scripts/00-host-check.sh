#!/usr/bin/env bash
# Host-side prerequisites. Prints what to install; never installs (sudo here is
# interactive-only, so the user runs the line it hands back).
. "$(dirname "$0")/lib.sh"

need() { command -v "$1" >/dev/null 2>&1; }

missing=()
optional=()

# Route A (in-place upgrade over adb) needs only adb + python3.
for c in adb python3 sha256sum; do need "$c" || missing+=("$c"); done

# Route B (build a fresh trixie rootfs image) needs the heavy toolchain.
declare -A B=(
  [debootstrap]=debian-archive-keyring
  [qemu-aarch64-static]=qemu-user-static
  [binfmt-control]=binfmt-support
  [mkbootimg]=android-sdk-libsparse-utils
  [fastboot]=fastboot
  [dtc]=device-tree-compiler
  [edl]=python3-edl
  [gt]=gadget-tools
)
for c in "${!B[@]}"; do need "$c" || optional+=("$c (${B[$c]})"); done

log "route A - in-place upgrade over adb (the recommended trixie path)"
if [ ${#missing[@]} -eq 0 ]; then
  echo "  ready: adb + python3 + sha256sum present"
else
  echo "  MISSING: ${missing[*]}"
fi

log "route B - build a fresh rootfs/boot image on this host"
if [ ${#optional[@]} -eq 0 ]; then
  echo "  ready: builder toolchain present"
else
  printf '  not installed: %s\n' "${optional[*]}"
  echo
  echo "  run this yourself (needs your password - this script will not sudo):"
  echo "    sudo apt update && sudo apt install -y \\"
  echo "      debian-archive-keyring debootstrap qemu-user-static binfmt-support \\"
  echo "      device-tree-compiler android-sdk-libsparse-utils fastboot \\"
  echo "      gadget-tools android-tools-adb"
  echo "    pipx install --python python3 edl     # or: git clone https://github.com/bkerler/edl"
fi

log "docker arm64 exec test (needed by scripts/50-build-rootfs.sh)"
if need docker; then
  if docker run --rm --platform linux/arm64 debian:trixie-slim /bin/true 2>/dev/null; then
    echo "  ok: binfmt handles linux/arm64 containers"
  else
    echo "  NO: exec format error - register binfmt without sudo:"
    echo "    docker run --privileged --rm tonistiigi/binfmt --install arm64"
    echo "  (or install qemu-user-static + binfmt-support above)"
  fi
else
  echo "  docker absent"
fi

log "vendored builder"
if [ -d "$ROOT/vendor/OpenStick-Builder/.git" ]; then
  echo "  vendor/OpenStick-Builder @ $(git -C "$ROOT/vendor/OpenStick-Builder" rev-parse --short HEAD) (branch $(git -C "$ROOT/vendor/OpenStick-Builder" rev-parse --abbrev-ref HEAD))"
  echo "  submodules: $(git -C "$ROOT/vendor/OpenStick-Builder" submodule status | wc -l) not initialised (only needed for route B repartition path)"
else
  echo "  vendor/OpenStick-Builder missing - scripts/10-fetch-vendor.sh"
fi

log "device reachable?"
if adb get-state >/dev/null 2>&1; then
  NDEV=$(adb devices | awk 'NR>1 && $2=="device"' | wc -l)
  echo "  yes: $(adb ${ADB_SERIAL:+-s $ADB_SERIAL} shell 'uname -n' 2>/dev/null | tr -d '\r') ($NDEV adb device(s) listed)"
else
  echo "  no adb device in get-state - skip device steps until it is plugged in"
fi
