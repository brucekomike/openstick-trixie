#!/bin/sh
# Build an Alpine v3.24 + postmarketOS v25.12 rootfs AND the lk2nd ext2 boot image
# for a Handsome OpenStick - by running ON THE STICK ITSELF.
#
# Why on the device. The upstream OpenStick-Builder `alpine` branch cross-executes an
# aarch64 chroot under qemu-aarch64-static on an x86 host, which is why it needs
# `sudo apt install qemu-user-static binfmt-support` and a root shell. This board is
# already aarch64 and already gives us root over adb, so `apk add` runs natively:
# no qemu, no binfmt, no host sudo, and no host chroot. It also means mke2fs here is
# e2fsprogs 1.46.2 - the same generation that produced the running rootfs - so the
# ext4 feature set is guaranteed mountable by the vendor 5.15 kernel, which the
# ladder in scripts/54-build-alpine-onstick.sh relies on.
#
# What it writes: only $WORK (/root/alpine-build). It does NOT touch any partition;
# flashing is scripts/70-flash.sh's job and needs fastboot.
#
# Deviations from the vendored builder, each because upstream's value is wrong HERE:
#   * NetworkManager comes from Alpine v3.24 directly. upstream extracts v3.20's NM
#     into a nested /usr/local chroot with bind-mounted /etc and `unshare -mr`; Alpine
#     3.24 ships networkmanager + modemmanager in main/community (checked against the
#     aarch64 APKINDEX), so the whole hack is unnecessary and its /etc bind loop is a
#     boot-time liability.
#   * /etc/fstab mounts /boot from by-partlabel, not /dev/mmcblk0p14: on this GPT
#     p14 IS the rootfs (boot is p12), so upstream's line would try to mount / on /boot.
#   * extlinux `fdt` points at THIS board's own DTB, taken out of the working boot
#     partition. pmOS's device-generic-zhihe-kernel-ufi001c deviceinfo says
#     msm8916-thwc-ufi001c, but that board file drives one external SIM slot on
#     gpio0-3 while this stick's stock DTB has sim_sel/sim_en/sim_sel2/sim_en2 -
#     a dual-SIM multiplexer. Wrong SIM pins is not a cosmetic failure on a modem.
#     The thwc DTB is packed alongside as the documented fallback.
#   * the vendor 5.15 modules and /lib/firmware are copied in, so the *unchanged*
#     stock Android boot.img can boot this rootfs. That is the reversible first step.
#   * no gadget-tool: setup_ncm_gadget.sh is pure configfs, and the adbd this board
#     runs is a glibc binary that cannot execute on musl. Admin is dropbear over NCM
#     plus the ttyMSM0 serial console.
set -eu

WORK=${WORK:-/root/alpine-build}
IN=$WORK/incoming
DL=$WORK/dl
ROOTFS=$WORK/rootfs
BOOTSTAGE=$WORK/boot
OUTD=$WORK/out

RELEASE=${RELEASE:-v3.24}
MIRROR=${MIRROR:-http://mirrors.aliyun.com/alpine}
PMOS_RELEASE=${PMOS_RELEASE:-v25.12}
PMOS_MIRROR=${PMOS_MIRROR:-https://mirrors.ustc.edu.cn/postmarketos}
MINIROOTFS=${MINIROOTFS:-alpine-minirootfs-3.24.2-aarch64.tar.gz}

VENDOR_KVER=${VENDOR_KVER:-5.15.0-jsbsbxjxh66+}
ROOT_PARTUUID=${ROOT_PARTUUID:?must come from the host driver (measured, not assumed)}
ALPINE_HOST=${ALPINE_HOST:-openstick-alpine}
# 896 MB keeps the peak (extracted tree + image + gz) inside the ~2.4 GB this board
# has free; the partition is 3.3 GB and resize2fs grows it after first boot.
ROOTFS_MB=${ROOTFS_MB:-896}

DTB_SRC=${DTB_SRC:-$IN/board.dtb}
NCM_SRC=${NCM_SRC:-$IN/setup_ncm_gadget.sh}
NM_CONNS=${NM_CONNS:-$IN/nmconnections}

say() { echo "[$(date -u +%H:%M:%S)] $*"; }
die() { say "BUILD_FAILED: $*"; exit 1; }
inbox() { chroot "$ROOTFS" /bin/sh -c "$*"; }

# --------------------------------------------------------------------------- 0 preflight
say "preflight"
[ "$(id -u)" = 0 ] || die "must run as root on the stick"
AVAIL=$(df -Pk / | awk 'NR==2{print $4}')
[ "$AVAIL" -ge $((1500 * 1024)) ] || die "need >=1500 MB free on /, have $((AVAIL / 1024)) MB"
[ -s "$DTB_SRC" ] || die "missing $DTB_SRC - pushed by scripts/54-build-alpine-onstick.sh"
[ -s "$NCM_SRC" ] || die "missing $NCM_SRC"
[ -d "$NM_CONNS" ] || die "missing $NM_CONNS"
wget -q -O /dev/null "$MIRROR/$RELEASE/main/aarch64/APKINDEX.tar.gz" ||
  die "no route to $MIRROR - give the stick wifi first: nmcli device wifi connect \"SSID\" password \"PSK\""
say "mirror reachable, $((AVAIL / 1024)) MB free"

# --------------------------------------------------------------------------- 1 base
say "1/8 alpine $RELEASE minirootfs"
mkdir -p "$DL" "$OUTD"
if [ ! -s "$DL/$MINIROOTFS" ]; then
  wget -q -O "$DL/$MINIROOTFS.part" "$MIRROR/$RELEASE/releases/aarch64/$MINIROOTFS" ||
    die "download of $MINIROOTFS failed"
  mv "$DL/$MINIROOTFS.part" "$DL/$MINIROOTFS"
fi
rm -rf "$ROOTFS"
mkdir -p "$ROOTFS"
tar -xzf "$DL/$MINIROOTFS" -C "$ROOTFS"

cat > "$ROOTFS/etc/apk/repositories" <<EOF
$MIRROR/$RELEASE/main
$MIRROR/$RELEASE/community
@pmos $PMOS_MIRROR/$PMOS_RELEASE
EOF
cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf"
mkdir -p "$ROOTFS/proc" "$ROOTFS/dev"
for spec in "null c 1 3" "zero c 1 5" "random c 1 8" "urandom c 1 9" "tty c 5 0"; do
  set -- $spec
  [ -e "$ROOTFS/dev/$1" ] || mknod -m 666 "$ROOTFS/dev/$1" "$2" "$3" "$4"
done
mount -t proc proc "$ROOTFS/proc"
trap 'umount -l "$ROOTFS/proc" 2>/dev/null || true' EXIT INT TERM

inbox "apk add --allow-untrusted alpine-keys ca-certificates curl wget kmod" ||
  die "bootstrap apk add failed - check the mirror"
inbox "apk add --allow-untrusted postmarketos-keys@pmos" ||
  die "postmarketos-keys failed - the @pmos repo line is wrong or unreachable"

# --------------------------------------------------------------------------- 2 packages
say "2/8 package set"
# One line, not a wrapped literal: inbox() hands this to `sh -c`, so an embedded newline
# ends the apk command and the next line is executed as a command name (which is how
# "chrony: not found" once appeared over a perfectly successful install).
PKGS="openrc eudev udev-init-scripts udev-init-scripts-openrc dbus dropbear shadow sudo"
PKGS="$PKGS chrony iw wireless-regdb iproute2 iptables bridge-utils dnsmasq"
PKGS="$PKGS e2fsprogs e2fsprogs-extra zstd parted"
# Alpine splits NetworkManager into daemon + cli + tui + dnsmasq + wifi + wwan. Installing
# only `networkmanager` gives a daemon with no nmcli, and the Wi-Fi door this board relies
# on would then need a hand-written wpa_supplicant conf. Found by verifying the first image.
PKGS="$PKGS networkmanager networkmanager-cli networkmanager-tui networkmanager-dnsmasq"
PKGS="$PKGS modemmanager libqmi usbutils"
PKGS="$PKGS rmtfs@pmos msm-firmware-loader@pmos linux-postmarketos-qcom-msm8916@pmos"
rc=0
inbox "apk add $PKGS" > "$WORK/pkg.log" 2>&1 || rc=1
if [ "$rc" != 0 ]; then
  # One unresolvable name would abort the whole set; retry per package so the build
  # continues and the log names exactly what is missing.
  say "group install failed (see $WORK/pkg.log), retrying individually"
  FAILED=""
  for p in $PKGS; do
    if inbox "apk add $p" >/dev/null 2>&1; then
      say "  ok   $p"
    else
      say "  MISS $p"
      FAILED="$FAILED $p"
    fi
  done
  for must in openrc eudev dropbear networkmanager linux-postmarketos-qcom-msm8916@pmos; do
    case "$FAILED" in *" $must"*) die "$must is required and did not install";; esac
  done
fi
KDIR=$(ls "$ROOTFS/lib/modules" | grep -v "$VENDOR_KVER" | head -1)
[ -n "$KDIR" ] || die "no kernel modules directory appeared in the rootfs"
say "kernel in rootfs: $KDIR"
inbox "depmod -a $KDIR" || say "WARN depmod failed - modprobe will not work for $KDIR"

# --------------------------------------------------------------------------- 3 firmware
say "3/8 radio firmware + vendor 5.15 modules"
# This board has no `modem` partition: the DSP/modem blobs live in /lib/firmware, so a
# new rootfs that does not carry them boots with no LTE at all.
mkdir -p "$ROOTFS/lib/firmware" "$ROOTFS/lib/modules"
cp -a /lib/firmware/. "$ROOTFS/lib/firmware/"
if [ -d "/lib/modules/$VENDOR_KVER" ]; then
  cp -a "/lib/modules/$VENDOR_KVER" "$ROOTFS/lib/modules/"
else
  say "WARN /lib/modules/$VENDOR_KVER absent - stock boot.img could not load modules"
fi

# --------------------------------------------------------------------------- 4 system glue
say "4/8 openrc/users/gadget"
echo "$ALPINE_HOST" > "$ROOTFS/etc/hostname"
sed -i "s/localhost/localhost $ALPINE_HOST/" "$ROOTFS/etc/hosts" || true

# upstream creates user/1 (builder default, NOPASSWD sudo). Root is left password-locked:
# over the NCM link you log in as `user` and sudo; change the password before any network
# the device does not own.
inbox "echo 'user:1::::/home/user:/bin/ash' | newusers" || say "WARN newusers failed"
echo 'user ALL=(ALL:ALL) NOPASSWD: ALL' > "$ROOTFS/etc/sudoers.d/user"
chmod 440 "$ROOTFS/etc/sudoers.d/user"

for f in "$NM_CONNS"/*.nmconnection; do
  [ -f "$f" ] || continue
  mkdir -p "$ROOTFS/etc/NetworkManager/system-connections"
  install -m 600 "$f" "$ROOTFS/etc/NetworkManager/system-connections/$(basename "$f")"
done
# Upstream's hotspot (wlan0 as an AP called "Openstick") and lte profiles carry no
# autoconnect key, so NM defaults them to true: the stick would come up broadcasting an
# AP instead of joining your network, and wwan retries would stall early boot. Both stay
# available on demand (`nmcli connection up hotspot`); the client profile wins.
for f in hotspot lte; do
  p="$ROOTFS/etc/NetworkManager/system-connections/$f.nmconnection"
  if [ -f "$p" ]; then
    sed -i '/^\[connection\]/a autoconnect=false' "$p"
  fi
done
install -m 755 "$NCM_SRC" "$ROOTFS/usr/local/bin/setup_ncm_gadget.sh"
mkdir -p "$ROOTFS/etc/udev/rules.d"
cat > "$ROOTFS/etc/udev/rules.d/10-udc.rules" <<'EOF'
ACTION=="add", SUBSYSTEM=="udc", RUN+="/sbin/modprobe libcomposite", RUN+="/usr/local/bin/setup_ncm_gadget.sh"
EOF
# OpenRC's `modules` service, not systemd's modules-load.d
printf 'modules="libcomposite"\n' >> "$ROOTFS/etc/conf.d/modules"

# /boot is the ext2 partition lk2nd reads. by-partlabel because the numbering is not
# upstream's, and noauto because on the first boot (stock Android boot.img still in
# place) that partition holds no filesystem and `mount -a` would only waste a boot delay.
cat > "$ROOTFS/etc/fstab" <<EOF
/dev/disk/by-partlabel/boot	/boot	ext2	defaults,noauto	0 0
EOF

# Last-resort door: a root shell on the serial console, which is what the plan falls back
# to when the gadget is dead. Physically attaching to ttyMSM0 therefore equals root.
sed -i 's/^tty/#tty/' "$ROOTFS/etc/inittab" || true
echo 'ttyMSM0::respawn:/bin/sh' >> "$ROOTFS/etc/inittab"

for s in "devfs sysinit" "dmesg sysinit" "udev sysinit" "udev-trigger sysinit" \
         "udev-settle sysinit" "hwclock boot" "modules boot" "hostname boot" \
         "sysctl boot" "bootmisc boot" "networking boot" "mount-ro shutdown" \
         "killprocs shutdown" "savecache shutdown" "dropbear default" "dbus default" \
         "networkmanager default" "rmtfs default" "modemmanager default"; do
  name=${s%% *}
  runlevel=${s##* }
  if [ -f "$ROOTFS/etc/init.d/$name" ]; then
    inbox "rc-update add $name $runlevel" >/dev/null 2>&1 || say "WARN rc-update $name"
  else
    say "  skip $name (no init.d script from this package set)"
  fi
done

cat > "$ROOTFS/etc/openstick-build" <<EOF
board=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo unknown)
dtb=msm8916-handsome-openstick.dtb (stock, sha256 $(sha256sum "$DTB_SRC" | cut -c1-16))
built=$(date -u +%Y-%m-%dT%H:%M:%SZ)
kernel=$KDIR + vendor $VENDOR_KVER
alpine=$RELEASE pmos=$PMOS_RELEASE
EOF

# --------------------------------------------------------------------------- 5 boot stage
say "5/8 ext2 boot partition contents"
rm -rf "$BOOTSTAGE"
mkdir -p "$BOOTSTAGE/extlinux" "$BOOTSTAGE/dtbs/qcom"
install -m 644 "$ROOTFS/boot/vmlinuz" "$BOOTSTAGE/vmlinuz"
install -m 644 "$ROOTFS/boot/dtbs/qcom/msm8916-thwc-ufi001c.dtb" \
  "$BOOTSTAGE/dtbs/qcom/msm8916-thwc-ufi001c.dtb"
install -m 644 "$DTB_SRC" "$BOOTSTAGE/dtbs/qcom/msm8916-handsome-openstick.dtb"
# The vendor kernel + Debian initrd as an alternate label: same DTB, 5.15, proven cmdline.
# Written as an if because `set -e` turns a false `[ -f ] && cmd` test into a fatal exit.
if [ -f "/boot/vmlinuz-$VENDOR_KVER" ] && [ -f "/boot/initrd.img-$VENDOR_KVER" ]; then
  install -m 644 "/boot/vmlinuz-$VENDOR_KVER" "$BOOTSTAGE/vmlinuz-5.15"
  install -m 644 "/boot/initrd.img-$VENDOR_KVER" "$BOOTSTAGE/initrd-5.15"
fi

# lk2nd reads exactly one file: extlinux/extlinux.conf, in the builder's key format
# (no LABEL block), which is the shape this aboot is known to accept.
mk_extlinux() { # $1=fdt  $2=kernel  $3=initrd(or empty)  $4=outfile
  {
    echo "linux $2"
    [ -n "$3" ] && echo "initrd $3"
    echo "fdt $1"
    echo "append earlycon root=PARTUUID=$ROOT_PARTUUID console=ttyMSM0,115200 no_framebuffer=true rw rootwait"
  } > "$4"
}
mk_extlinux /dtbs/qcom/msm8916-handsome-openstick.dtb /vmlinuz "" \
  "$BOOTSTAGE/extlinux/extlinux.conf"
mk_extlinux /dtbs/qcom/msm8916-thwc-ufi001c.dtb /vmlinuz "" \
  "$BOOTSTAGE/extlinux/extlinux-thwc.conf"
if [ -f "$BOOTSTAGE/vmlinuz-5.15" ]; then
  mk_extlinux /dtbs/qcom/msm8916-handsome-openstick.dtb \
    /vmlinuz-5.15 /initrd-5.15 "$BOOTSTAGE/extlinux/extlinux-5.15.conf"
fi
cat "$BOOTSTAGE/extlinux/extlinux.conf"

# --------------------------------------------------------------------------- 6 images
say "6/8 writing images"
umount -l "$ROOTFS/proc" 2>/dev/null || true
trap - EXIT INT TERM

rm -f "$OUTD/rootfs.img" "$OUTD/boot.img"
truncate -s "${ROOTFS_MB}M" "$OUTD/rootfs.img"
mke2fs -q -F -L rootfs -t ext4 -m 0 -d "$ROOTFS" "$OUTD/rootfs.img" ||
  die "mke2fs rootfs failed (image too small? used $(du -sh "$ROOTFS" | cut -f1) vs ${ROOTFS_MB} MB)"
truncate -s 64M "$OUTD/boot.img"
mke2fs -q -F -L boot -t ext2 -d "$BOOTSTAGE" "$OUTD/boot.img" || die "mke2fs boot failed"

say "7/8 compressing for the transfer over adb"
for i in rootfs boot; do
  gzip -1 -c "$OUTD/$i.img" > "$OUTD/$i.img.gz"
done
( cd "$OUTD" && sha256sum rootfs.img boot.img rootfs.img.gz boot.img.gz > SHA256SUMS )

say "8/8 result"
ls -l "$OUTD"
echo
echo "rootfs payload used: $(du -sh "$ROOTFS" | cut -f1) in a ${ROOTFS_MB} MB image"
echo "           after first boot: resize2fs /dev/disk/by-partlabel/rootfs"
echo "boot payload: $(du -sh "$BOOTSTAGE" | cut -f1) in a 64 MB partition"
echo "BUILD_DONE"
