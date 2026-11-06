#!/usr/bin/env bash
# Put every partition this project can write back to its factory image, from restore/.
#
#   ./restore.sh                                # dry run: verify the manifest, print the plan
#   COMMIT=1 I_RESTORE_FACTORY=yes ./restore.sh
#   SERIAL=<fastboot-serial> ./restore.sh       # pin the device (else pack.env's value)
#
# What this does and does not recover:
#   * aboot, hyp, sbl1, rpm, tz, boot -> the images read off THIS board before anything was
#     written, so the boot chain returns to exactly what the vendor shipped.
#   * rootfs -> NOT recovered. There is no raw image of the original filesystem: reading one
#     back needs `fastboot fetch` (unimplemented by both aboots on these boards) or EDL (not
#     proven on this family). What exists is a file-level archive, so putting the original
#     userspace back means creating a fresh ext4 on the partition and unpacking that archive
#     into it - see the recovery section of the board file that came with this pack.
#
# sbl1/rpm/tz are included here even though the install ladder never writes them: restoring
# them is free when the images are present, and it is the only way back to a byte-exact
# factory boot chain.
set -eu

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

[ -f "$HERE/pack.env" ] || die "no pack.env next to this script - not a flash pack directory"
# shellcheck source=/dev/null
. "$HERE/pack.env"

SERIAL="${SERIAL:-${PACK_SERIAL:-}}"
FB="${FASTBOOT:-}"
if [ -z "$FB" ]; then
  # `[ -x fastboot ]` on the bare name would fail even when it IS on PATH: resolve to the
  # real path first, and keep the common no-PATH install as the fallback.
  FB=$(command -v fastboot || true)
  [ -n "$FB" ] || FB="$HOME/.local/bin/fastboot"
fi
[ -x "$FB" ] || die "no fastboot binary (set FASTBOOT=/path/to/fastboot)"
# An ARRAY, not a `fb()` function: every call below is `timeout N fastboot …`, and timeout execs
# a real binary - `timeout 600 fb flash …` fails to run at all and, with the output filtered
# through `| grep OKAY`, reported a restore that never happened. This is the recovery script, so
# a silent no-op here is worse than a loud one: it claims the factory boot chain is back when
# the partition still holds whatever broke the board. Same rule as scripts/lib.sh.
FB_CMD=( "$FB" )
if [ -n "$SERIAL" ]; then FB_CMD+=( -s "$SERIAL" ); fi

# partition:file, in the order that keeps the board loadable at every step. aboot/hyp go
# first because they are what the vendor sbl1 loads; boot last because it is what aboot reads.
PARTS="aboot:part-aboot.bin hyp:part-hyp.bin sbl1:part-sbl1.bin rpm:part-rpm.bin tz:part-tz.bin boot:boot-stock.bin"

say "restore plan: factory images for ${PACK_BOARD_TAG:-this board}"
missing=0
for pair in $PARTS; do
  part=${pair%%:*}; file=${pair##*:}
  if [ -f "$HERE/restore/$file" ]; then
    printf '  fastboot flash %-6s restore/%-18s %10d bytes\n' "$part" "$file" "$(stat -c %s "$HERE/restore/$file")"
  else
    printf '  MISSING        restore/%s\n' "$file"; missing=1
  fi
done
[ "$missing" = 0 ] || die "restore/ is incomplete - this pack cannot fully restore the board"

say "verifying MANIFEST.sha256"
set +e
out=$( cd "$HERE" && sha256sum -c --strict MANIFEST.sha256 2>&1 ); rc=$?
set -e
[ "$rc" = 0 ] || { printf '%s\n' "$out" | grep -v ': OK$' | sed 's/^/  /'
  die "manifest verification FAILED - a corrupt factory image is worse than no restore at all"; }
echo "  ok: every file matches its recorded sha256"

if [ "${COMMIT:-0}" != 1 ]; then
  cat <<EOF

DRY RUN - nothing was written. To restore:
  COMMIT=1 I_RESTORE_FACTORY=yes ./restore.sh
The board must be in fastboot. This does not touch rootfs, modemst1/2, fsg, fsc, sec, cdt
or devinfo - calibration and radio identity are never written by anything in this pack.
EOF
  exit 0
fi

[ "${I_RESTORE_FACTORY:-}" = yes ] ||
  die "refusing to overwrite the boot chain without I_RESTORE_FACTORY=yes"

if [ -n "$SERIAL" ]; then
  timeout 10 "$FB" devices 2>/dev/null | grep -qE "^${SERIAL}[[:space:]]+fastboot" ||
    die "no board in fastboot with serial $SERIAL"
else
  timeout 10 "$FB" devices 2>/dev/null | grep -q fastboot ||
    die "no board in fastboot. Hold the EDL/reset button while plugging in, or use
       scripts/72-enter-fastboot.sh from a running system."
  n=$(timeout 10 "$FB" devices 2>/dev/null | grep -c fastboot || true)
  [ "$n" = 1 ] || die "$n boards are in fastboot and no SERIAL is set - refusing to guess
       which one gets the factory images. Re-run with SERIAL=<serial>."
fi

for pair in $PARTS; do
  part=${pair%%:*}; file=${pair##*:}
  printf '  fastboot flash %-6s %s\n' "$part" "$file"
  rout=$(timeout 600 "${FB_CMD[@]}" flash "$part" "$HERE/restore/$file" 2>&1) || {
    printf '%s\n' "$rout" | sed 's/^/    /'
    die "fastboot flash $part failed - the factory boot chain is NOT restored, do not reboot
         into hope. The output above says why."; }
  printf '%s\n' "$rout" | grep -oE 'OKAY|FAILED.*' | head -1 | sed 's/^/    /'
done

say "rebooting into the factory boot chain"
timeout 30 "${FB_CMD[@]}" reboot >/dev/null 2>&1 || true
for i in $(seq 1 45); do
  sleep 4
  if lsusb 2>/dev/null | grep -qE '1d6b:0104|18d1:d001'; then
    echo "  something came up at ~$((i * 4))s (1d6b:0104 = Linux gadget, 18d1:d001 = vendor adb)"
    echo "  rootfs was NOT restored, so whatever userspace is on that partition now is what boots."
    exit 0
  fi
  if [ "$i" -ge 5 ] && timeout 8 "${FB_CMD[@]}" devices 2>/dev/null | grep -q fastboot; then
    warn "back in fastboot at ~$((i * 4))s: the boot chain is factory again but the rootfs"
    warn "does not match it. Rebuild a rootfs the vendor kernel can boot, or unpack the"
    warn "file-level archive onto a fresh ext4 (see INSTALL.md, recovery)."
    exit 1
  fi
done
die "neither Linux nor fastboot after 180 s - power-cycle. If lsusb then shows 05c6:9008 the
     board is in EDL and needs the firehose loader plus the \`edl\` tool."
