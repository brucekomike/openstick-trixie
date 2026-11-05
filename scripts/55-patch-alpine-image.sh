#!/usr/bin/env bash
# Patch a built Alpine rootfs image in place with debugfs - no mount, no sudo, no rebuild.
#
#   scripts/55-patch-alpine-image.sh [image]
#
# Why patch instead of rebuild: the fix is four small files, and a rebuild means another
# 15 minute on-device apk run plus a 940 MB pull, while the stick is already sitting in
# fastboot waiting. debugfs writes into the ext4 image directly and e2fsck then proves the
# result is consistent.
#
# What it installs (all from config/alpine-gadget/, so `make alpine` and this stay in sync):
#   /usr/local/bin/setup_gadget.sh        NCM + ACM composite (ACM = second admin door)
#   /usr/local/bin/gadget-net-up.sh       name-agnostic bring-up: static IP + dnsmasq
#   /etc/udev/rules.d/10-udc.rules        runs the above via /bin/sh (no exec bit needed)
#   /etc/udev/rules.d/11-gadget-net.rules pins the gadget netdev name to usb0
#   /etc/NetworkManager/conf.d/99-...     keeps NM off usb0 so it cannot fight the above
#   /etc/inittab                          + ::once gadget-net-up.sh, + ttyGS0 root shell
. "$(dirname "$0")/lib.sh"

IMG=${1:-$OUT/alpine-rootfs.img}
CFG="$ROOT/config/alpine-gadget"
[ -f "$IMG" ] || die "no image at $IMG - run scripts/54-build-alpine-onstick.sh first"
command -v debugfs >/dev/null || die "debugfs (e2fsprogs) is required"
for f in setup_gadget.sh gadget-net-up.sh 10-udc.rules 11-gadget-net.rules 99-gadget-unmanaged.conf; do
  [ -s "$CFG/$f" ] || die "missing $CFG/$f"
done

log "patching $IMG ($(stat -c %s "$IMG") bytes)"
echo "  before: $(sha256sum "$IMG" | cut -c1-16)"

# debugfs `write` refuses to clobber, so remove first; ignore "not found".
put() { # $1 local file  $2 path inside the image
  debugfs -w -R "rm $2" "$IMG" >/dev/null 2>&1 || true
  debugfs -w -R "write $1 $2" "$IMG" >/dev/null || die "debugfs could not write $2"
  debugfs -w -R "set_inode_field $2 mode 0100755" "$IMG" >/dev/null 2>&1 || true
  echo "  wrote $2"
}

put "$CFG/setup_gadget.sh"          /usr/local/bin/setup_gadget.sh
put "$CFG/gadget-net-up.sh"         /usr/local/bin/gadget-net-up.sh
put "$CFG/10-udc.rules"             /etc/udev/rules.d/10-udc.rules
put "$CFG/11-gadget-net.rules"      /etc/udev/rules.d/11-gadget-net.rules
put "$CFG/99-gadget-unmanaged.conf" /etc/NetworkManager/conf.d/99-gadget-unmanaged.conf

log "adb payload: a root \`adb shell\` on a musl rootfs"
# Nothing here is packaged for Alpine, and the substitutions that look obvious do not work.
# scripts/76-fetch-adbd-payload.sh records the measurements and assembles + verifies both
# files; this step only injects them.
PAYLOAD="$OUT/adbd-payload"
[ -s "$PAYLOAD/adbd" ] && [ -s "$PAYLOAD/libcrypto.so.1.1" ] ||
  die "missing $PAYLOAD/{adbd,libcrypto.so.1.1} - run scripts/76-fetch-adbd-payload.sh"
( cd "$PAYLOAD" && sha256sum -c --strict SHA256SUMS ) >/dev/null 2>&1 ||
  warn "$PAYLOAD does not match its own SHA256SUMS - re-run scripts/76-fetch-adbd-payload.sh"
# The vendor adbd is glibc and runs through gcompat's loader, so gcompat must be in the
# image already - it comes from the apk list in scripts/device/alpine-onstick.sh.
# NOT `debugfs -R stat <path>`: that exits 0 even when the path does not exist (measured),
# so as a presence test it can never fail and the guard would be a no-op. List and match.
libs=$(debugfs -R "ls -l /lib" "$IMG" 2>/dev/null || true)
echo "$libs" | grep -q 'libgcompat\.so\.0' ||
  die "no /lib/libgcompat.so.0 in the image: gcompat is missing from the apk package list,
     so adbd would be injected into a rootfs that cannot execute it"

putm() { # $1 local file  $2 path inside the image  $3 inode mode
  debugfs -w -R "rm $2" "$IMG" >/dev/null 2>&1 || true
  debugfs -w -R "write $1 $2" "$IMG" >/dev/null || die "debugfs could not write $2"
  debugfs -w -R "set_inode_field $2 mode $3" "$IMG" >/dev/null 2>&1 || true
  echo "  wrote $2 (mode $3)"
}
# The minirootfs has /usr/local/bin but not /usr/local/sbin, and debugfs write will not
# create intermediate directories - it fails with the same "nonexistent directory" a shell
# redirect does.
debugfs -w -R "mkdir /usr/local/sbin" "$IMG" >/dev/null 2>&1 || true
putm "$PAYLOAD/adbd"             /usr/local/sbin/adbd      0100755
putm "$PAYLOAD/libcrypto.so.1.1" /usr/lib/libcrypto.so.1.1 0100644
# gcompat ships libc.so.6 and libpthread.so.0 as links to libgcompat.so.0 but no libdl.so.2,
# and the Debian libcrypto NEEDs it. Same shim, same relative target, so it resolves in /lib.
debugfs -w -R "rm /lib/libdl.so.2" "$IMG" >/dev/null 2>&1 || true
debugfs -w -R "symlink /lib/libdl.so.2 libgcompat.so.0" "$IMG" >/dev/null ||
  die "debugfs could not create /lib/libdl.so.2"
echo "  linked /lib/libdl.so.2 -> libgcompat.so.0"

log "inittab: gadget bring-up + ACM console"
debugfs -R "cat /etc/inittab" "$IMG" > "$OUT/inittab.orig" 2>/dev/null || die "cannot read /etc/inittab"
cp "$OUT/inittab.orig" "$OUT/inittab.new"
grep -q 'gadget-net-up.sh' "$OUT/inittab.new" || cat >> "$OUT/inittab.new" <<'EOF'

# openstick: bring the USB gadget network up without depending on NetworkManager
::once:/bin/sh /usr/local/bin/gadget-net-up.sh
# openstick: last-resort root shell on the USB serial console (/dev/ttyACM0 on the host)
ttyGS0::respawn:/bin/sh
EOF
put "$OUT/inittab.new" /etc/inittab
rm -f "$OUT/inittab.new"

log "filesystem consistency"
if e2fsck -fn "$IMG" 2>&1 | tail -3 | sed 's/^/  /'; then :; fi
e2fsck -fp "$IMG" >/dev/null 2>&1 || e2fsck -fy "$IMG" >/dev/null 2>&1 || die "e2fsck could not clean $IMG"
e2fsck -fn "$IMG" >/dev/null 2>&1 && echo "  ok: clean" || die "image still inconsistent after e2fsck"

log "read back what was written"
for p in /usr/local/bin/setup_gadget.sh /usr/local/bin/gadget-net-up.sh \
         /etc/udev/rules.d/10-udc.rules /etc/udev/rules.d/11-gadget-net.rules \
         /etc/NetworkManager/conf.d/99-gadget-unmanaged.conf; do
  n=$(debugfs -R "cat $p" "$IMG" 2>/dev/null | wc -c)
  s=$(stat -c %s "$CFG/$(basename "$p")")
  if [ "$n" = "$s" ]; then echo "  ok   $p ($n bytes)"; else die "$p is $n bytes, source is $s"; fi
done
for pair in "/usr/local/sbin/adbd:$PAYLOAD/adbd" "/usr/lib/libcrypto.so.1.1:$PAYLOAD/libcrypto.so.1.1"; do
  p=${pair%%:*}; src=${pair##*:}
  n=$(debugfs -R "cat $p" "$IMG" 2>/dev/null | wc -c)
  s=$(stat -c %s "$src")
  if [ "$n" = "$s" ]; then echo "  ok   $p ($n bytes)"; else die "$p is $n bytes, source is $s"; fi
done
# The symlink is the piece that is easiest to get silently wrong: debugfs reports it, and a
# wrong target only shows up at runtime as "libdl.so.2: cannot open shared object file".
link=$(debugfs -R "stat /lib/libdl.so.2" "$IMG" 2>/dev/null | grep -oE 'libgcompat\.so\.0' | head -1)
[ -n "$link" ] && echo "  ok   /lib/libdl.so.2 -> $link" || die "/lib/libdl.so.2 is not a link to libgcompat.so.0"
echo "  inittab tail:"; debugfs -R "cat /etc/inittab" "$IMG" 2>/dev/null | tail -4 | sed 's/^/    /'
echo "  after: $(sha256sum "$IMG" | cut -c1-16)"
cat <<EOF

Patched. Flash it (stick must be in fastboot):
  ~/.local/bin/fastboot devices
  ~/.local/bin/fastboot flash rootfs $IMG
  ~/.local/bin/fastboot reboot
Then on this laptop, in ~45 s:
  adb devices                      # the board's own serial (from /proc/device-tree/serial-number)
  adb -s <serial> shell id         # uid=0(root) - adbd runs as root, so the shell does too
  ip -br addr | grep -i enx        # a 192.168.5.x lease = the gadget came up
  ls -l /dev/ttyACM*               # the third door (needs dialout)
EOF
