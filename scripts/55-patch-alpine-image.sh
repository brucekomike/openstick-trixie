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

CFG="$ROOT/config/alpine-gadget"
IMG=${1:-$OUT/alpine-rootfs.img}
[ -f "$IMG" ] || die "no image at $IMG - run scripts/54-build-alpine-onstick.sh first"
command -v debugfs >/dev/null || die "debugfs (e2fsprogs) is required"
for f in setup_gadget.sh gadget-net-up.sh nat-share.sh 90-nat-share \
         10-udc.rules 11-gadget-net.rules 99-gadget-unmanaged.conf; do
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
put "$CFG/nat-share.sh"             /usr/local/bin/nat-share.sh
# NetworkManager runs dispatcher scripts only if they are executable, and the directory does
# not exist in a base image that has never shared a connection.
debugfs -w -R "mkdir /etc/NetworkManager/dispatcher.d" "$IMG" >/dev/null 2>&1 || true
put "$CFG/90-nat-share"             /etc/NetworkManager/dispatcher.d/90-nat-share
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

log "repositories: what ships is not whichever mirror happened to be up"
# The build uses whatever mirror answers (dl-cdn has served "TLS: unspecified error" and
# "no route" from this network, and 53 then falls back to mirrors.aliyun.com). That choice
# belongs to the build, not to the released image, so the three repo lines are rewritten to
# the portable defaults here - same package content, mirror-independent URLs.
SHIP_MIRROR=${SHIP_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}
SHIP_PMOS=${SHIP_PMOS:-https://mirror.postmarketos.org/postmarketos}
debugfs -R "cat /etc/apk/repositories" "$IMG" 2>/dev/null > "$OUT/repos.orig" ||
  die "$IMG has no /etc/apk/repositories - is this an Alpine rootfs?"
rel=$(grep -oE '/v[0-9]+\.[0-9]+/' "$OUT/repos.orig" | head -1 | tr -d '/')
[ -n "$rel" ] || die "could not read the Alpine release from the image's repositories"
pmosrel=$(grep -B0 -oE '/v[0-9]+\.[0-9]+[^/]*$' "$OUT/repos.orig" | tail -1 | tr -d '/')
sed -e "s|^[^@ ].*main$|$SHIP_MIRROR/$rel/main|" \
    -e "s|^[^@ ].*community$|$SHIP_MIRROR/$rel/community|" \
    -e "s|^\(@pmos \).*|\1$SHIP_PMOS/${pmosrel:-v25.12}|" "$OUT/repos.orig" > "$OUT/repos.new"
printf '  before:\n'; sed 's/^/    /' "$OUT/repos.orig"
printf '  after:\n';  sed 's/^/    /' "$OUT/repos.new"
# Three lines: main, community, and the tagged @pmos overlay - whose line starts with the tag,
# not with the URL, which is why this counts "mentions a URL" rather than "^http".
[ "$(grep -c 'http' "$OUT/repos.new")" = 3 ] || die "rewrote repositories to something other than 3 URL lines"
[ "$(grep -c '^@pmos ' "$OUT/repos.new")" = 1 ] || die "the @pmos overlay line was lost"
debugfs -w -R "rm /etc/apk/repositories" "$IMG" >/dev/null 2>&1 || true
debugfs -w -R "write $OUT/repos.new /etc/apk/repositories" "$IMG" >/dev/null ||
  die "could not rewrite /etc/apk/repositories"
debugfs -w -R "set_inode_field /etc/apk/repositories mode 0100644" "$IMG" >/dev/null 2>&1 || true
back=$(debugfs -R "cat /etc/apk/repositories" "$IMG" 2>/dev/null)
[ "$back" = "$(cat "$OUT/repos.new")" ] || die "repositories read back differently"
rm -f "$OUT/repos.orig" "$OUT/repos.new"

# The toolset the stick is supposed to ship with. Each entry is a promise in the README
# feature list, so it is checked against the image rather than against the package list that
# was supposed to install it: `openssh-server` does not provide openssh-client, and an editor
# or a scanner dropped from a package list is discovered over adb - after a flash - which is
# not a check, it is an apology.
#
# TOOLSET is the same word scripts/device/alpine-onstick.sh takes: minimal (editor + ssh
# client) or full (adds the network tooling). Override the list with TOOL_CHECK if a tool is
# deliberately dropped from or added to an image.
case " ${TOOLSET:-minimal} " in
  *full*)
    TOOL_CHECK=${TOOL_CHECK:-"ssh scp ssh-keygen nano nmap ncat nc tcpdump dig iperf3 mtr traceroute whois socat"} ;;
  *)
    TOOL_CHECK=${TOOL_CHECK:-"ssh scp ssh-keygen nano"} ;;
esac
missing=""
binlist=$(debugfs -R "ls /usr/bin" "$IMG" 2>/dev/null | tr -s ' ' '\n' || true)
binlist="$binlist
$(debugfs -R "ls /bin" "$IMG" 2>/dev/null | tr -s ' ' '\n' || true)"
for t in $TOOL_CHECK; do
  printf '%s\n' "$binlist" | grep -qx "$t" || missing="$missing $t"
done
if [ -n "$missing" ]; then
  die "$IMG is missing tools the README promises:$missing   (TOOLSET=${TOOLSET:-minimal})
   Add them to PKGS in scripts/device/alpine-onstick.sh and rebuild, or pass the matching
   TOOLSET=std here. This image will not be packed."
fi
for t in $TOOL_CHECK; do echo "  ok        /usr/bin/$t"; done
log "runlevel policy: ssh opt-in, supplicant on, and the two fixes that make Wi-Fi real"
# Measured on both boards, and invisible from outside:
#   * dropbear sat in the default runlevel while its only credential is the builder's published
#     default password. Policy is opt-in, so the symlink comes out even if a build left it in.
#   * NetworkManager cannot D-Bus-activate wpa_supplicant on OpenRC (the service file's
#     SystemdService= key has nothing to act on), so wlan0 stays `unavailable` no matter what
#     the radio does - the supplicant has to already be running.
#   * without /etc/network/interfaces, OpenRC `networking` fails and everything that needs net
#     (dropbear, and in practice anything waiting on the network) fails with it.
debugfs -w -R "rm /etc/runlevels/default/dropbear" "$IMG" >/dev/null 2>&1 &&
  echo "  removed   /etc/runlevels/default/dropbear (ssh is opt-in)" ||
  echo "  ok        dropbear not enabled (ssh opt-in)"
# Alpine already ships /etc/runlevels/boot; asking debugfs to mkdir one that exists is at best
# an error and at worst a second directory entry, so only create it when it is genuinely absent.
debugfs -R "ls /etc/runlevels" "$IMG" 2>/dev/null | grep -qw boot ||
  debugfs -w -R "mkdir /etc/runlevels/boot" "$IMG" >/dev/null 2>&1 || true
debugfs -w -R "rm /etc/runlevels/boot/wpa_supplicant" "$IMG" >/dev/null 2>&1 || true
debugfs -w -R "symlink /etc/runlevels/boot/wpa_supplicant /etc/init.d/wpa_supplicant" "$IMG" >/dev/null ||
  die "could not enable the wpa_supplicant service in $IMG"
echo "  enabled   /etc/runlevels/boot/wpa_supplicant"

# `debugfs stat` exits 0 for a path that does not exist, so presence is tested by listing the
# parent - the same rule scripts/80-build-flashpack.sh documents.
debugfs -R "ls -l /etc/network" "$IMG" 2>/dev/null | grep -q 'interfaces' ||
  die "$IMG has no /etc/network/interfaces - OpenRC networking cannot start without it, and
   dropbear (which need net) fails with it. See scripts/device/alpine-onstick.sh."
echo "  ok        /etc/network/interfaces"
# The Wi-Fi device plugin lives in a version-named directory, so look for the directory first
# and then for the .so inside it - grepping the parent for "wifi" finds nothing and would have
# passed this check by accident.
nmver=$(debugfs -R "ls /usr/lib/NetworkManager" "$IMG" 2>/dev/null |
        tr -s ' ' '\n' | grep -E '^[0-9]+\.[0-9]+' | head -1 || true)
if [ -z "$nmver" ]; then
  die "no version directory under /usr/lib/NetworkManager in $IMG - NetworkManager is missing"
fi
debugfs -R "ls -l /usr/lib/NetworkManager/$nmver" "$IMG" 2>/dev/null |
  grep -q 'libnm-device-plugin-wifi\.so' ||
  die "networkmanager-wifi (the Wi-Fi device plugin) is not in $IMG - wlan0 will report
   'unavailable' forever even though iw can scan. Add it to PKGS in
   scripts/device/alpine-onstick.sh and rebuild."
echo "  ok        wifi plugin (/usr/lib/NetworkManager/$nmver/libnm-device-plugin-wifi.so)"

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
e2fsck -fn "$IMG" 2>&1 | tail -3 | sed 's/^/  /' || true
# e2fsck's exit status is a BITMASK, not an error count: 0 = already clean, 1 = errors
# corrected (that is a success), 2 = reboot required, 4 = left uncorrected, 8 = interrupted,
# 16 = the fs was skipped. `e2fsck -fy … || die` therefore declared any image it had just
# repaired to be broken - which is what happened here, after debugfs dirtied the journal.
rc=0
e2fsck -fy "$IMG" >/dev/null 2>&1 || rc=$?
[ "$rc" -le 1 ] || die "e2fsck could not clean $IMG (status $rc: $([ $rc -ge 4 ] && echo 'uncorrected errors')$([ $rc -ge 8 ] && echo ' / interrupted'))"
[ "$rc" = 0 ] && echo "  was already clean" || echo "  errors corrected by e2fsck (status 1, normal after debugfs writes)"
if e2fsck -fn "$IMG" >/dev/null 2>&1; then echo "  ok: clean"; else die "image still inconsistent after e2fsck"; fi

log "read back what was written"
for p in /usr/local/bin/setup_gadget.sh /usr/local/bin/gadget-net-up.sh \
         /usr/local/bin/nat-share.sh /etc/NetworkManager/dispatcher.d/90-nat-share \
         /etc/udev/rules.d/10-udc.rules /etc/udev/rules.d/11-gadget-net.rules \
         /etc/NetworkManager/conf.d/99-gadget-unmanaged.conf; do
  n=$(debugfs -R "cat $p" "$IMG" 2>/dev/null | wc -c)
  s=$(stat -c %s "$CFG/$(basename "$p")")
  if [ "$n" = "$s" ]; then echo "  ok   $p ($n bytes)"; else die "$p is $n bytes, source is $s"; fi
done
# The dispatcher must be executable or NetworkManager silently skips it - the share would
# then never happen and nothing would say so.
disp=$(debugfs -R "stat /etc/NetworkManager/dispatcher.d/90-nat-share" "$IMG" 2>/dev/null |
       grep -oE 'Mode: *[0-7]+' | grep -oE '[0-7]+$' || true)
case "$disp" in
  *7*|*5*) echo "  ok   dispatcher is executable (mode $disp)" ;;
  *) die "dispatcher mode is '$disp' - NetworkManager ignores a non-executable dispatcher" ;;
esac
for pair in "/usr/local/sbin/adbd:$PAYLOAD/adbd" "/usr/lib/libcrypto.so.1.1:$PAYLOAD/libcrypto.so.1.1"; do
  p=${pair%%:*}; src=${pair##*:}
  n=$(debugfs -R "cat $p" "$IMG" 2>/dev/null | wc -c)
  s=$(stat -c %s "$src")
  if [ "$n" = "$s" ]; then echo "  ok   $p ($n bytes)"; else die "$p is $n bytes, source is $s"; fi
done
# The symlink is the piece that is easiest to get silently wrong: debugfs reports it, and a
# wrong target only shows up at runtime as "libdl.so.2: cannot open shared object file".
link=$(debugfs -R "stat /lib/libdl.so.2" "$IMG" 2>/dev/null | grep -oE 'libgcompat\.so\.0' | head -1 || true)
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
