#!/usr/bin/env bash
# Route B: build a fresh trixie rootfs image on the host, to be written to the `rootfs`
# partition while the STOCK boot partition (and therefore the stock 5.15 kernel +
# handsome-openstick DTB) stays in place.
#
# This is the "clean slate" variant of route A. It is prepared, NOT yet proven on this
# stick - it needs docker with arm64 binfmt (see scripts/00-host-check.sh).
#
# The two things a plain debootstrap always gets wrong on this board, handled here:
#   * /lib/firmware - this board has NO modem partition, so the LTE/DSP blobs live only
#     in the rootfs. Without them the radio is dead and there is no partition to reflash.
#   * /lib/modules/$KVER - the 5.15 kernel is a vendor .deb that exists in no repository.
. "$(dirname "$0")/lib.sh"
require_backup boot-stock.bin
require_backup lib-firmware.tar.zst
require_backup kernel-boot.tar.zst

TARGET="${TARGET:-trixie}"
MIRROR="${MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/debian}"
WORK="$OUT/rootfs-$TARGET"

command -v docker >/dev/null 2>&1 || die "docker missing"
log "docker arch check"
docker run --rm --platform linux/arm64 debian:trixie-slim /bin/true 2>/dev/null ||
  die "linux/arm64 containers cannot exec here. Register binfmt without sudo:
       docker run --privileged --rm tonistiigi/binfmt --install arm64"

mkdir -p "$WORK"
log "plan"
cat <<EOF
  1. debootstrap $TARGET into $WORK (arm64, via $MIRROR)
  2. install the package set the stick's hardware needs (incl. qrtr + rmtfs for the modem)
  3. copy IN from backup/:  lib/firmware blobs, /lib/modules/$KVER, /boot files,
     adbd + gc, usb-adb-gadget unit, apt sources, hostname
  4. produce out/rootfs-$TARGET.img (ext4, $(($(stat -c %s "$BACKUP/part-rootfs.bin" 2>/dev/null || echo 0))) bytes sized) OR out/rootfs-$TARGET.tar.zst
  Nothing is written to the stick by this script - use scripts/70-flash.sh for that.
EOF

if [ "${COMMIT:-0}" != "1" ]; then
  echo
  echo "  DRY RUN. Add COMMIT=1 to build. Expect several GB of downloads and ~15 min."
  exit 0
fi

log "1/4 debootstrap"
docker run --rm --platform linux/arm64 \
  -v "$WORK:/target" -v "$CONF:/config:ro" \
  debian:trixie-slim /bin/sh -c "
    set -e
    apt-get update -qq && apt-get install -y -qq --no-install-recommends debootstrap
    debootstrap --variant=minbase --arch=arm64 $TARGET /target $MIRROR
  " || die "debootstrap failed"

log "2/4 package set"
docker run --rm --platform linux/arm64 \
  -v "$WORK:/target" -v "$CONF:/config:ro" \
  debian:trixie-slim /usr/sbin/chroot /target /bin/sh -c "
    set -e
    cp /config/sources-$TARGET.list /etc/apt/sources.list
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends \
      systemd systemd-timesyncd iproute2 iptables nftables wpasupplicant \
      network-manager modemmanager libqmi-tools qrtr rmtfs \
      openssh-client openssh-server nano nmap sudo tzdata locales ca-certificates vim-tiny \
      usbutils pciutils ethtool file
    apt-get clean
    # These four are not optional and must not be assumed present. `openssh-server` does NOT
    # pull openssh-client, so a minbase arm64 rootfs can end up with a daemon and no `ssh` -
    # and without a client the stick cannot dial out, which is the only way to reach a stick
    # whose gadget link is dead (reverse tunnel) or to ssh the other stick at 192.168.5.1.
    # nmap is here because this device's whole job is being a radio on a network; Debian
    # installs it without the setuid bit on purpose, so privileged probes (raw ping, SYN)
    # need root - which is how this stick is administered anyway. Checked, not trusted:
    for t in ssh scp ssh-keygen nano nmap; do
      test -x "/usr/bin/$t" || { echo "FATAL: no /usr/bin/$t in the rootfs" >&2; exit 1; }
    done
    /usr/bin/ssh -V 2>&1 | head -1; /usr/bin/nmap --version 2>/dev/null | head -1
    # root login over adb/serial is how this stick is administered; set a password
    # before first boot with: docker run --rm -v $WORK:/t debian:trixie-slim \
    #   /usr/sbin/chroot /t passwd root
    true
  " || die "chroot package install failed"

log "3/4 copy the board-specific parts in from backup/"
zstd -dc "$BACKUP/lib-firmware.tar.zst" | tar -xf - -C "$WORK" || die "firmware restore failed"
zstd -dc "$BACKUP/kernel-boot.tar.zst" | tar -xf - -C "$WORK" || die "kernel/modules restore failed"
for pair in "usr-bin-adbd:/usr/bin/adbd" "usr-bin-gc:/usr/bin/gc" "mobian-usb-gadget:/usr/sbin/mobian-usb-gadget"; do
  src=${pair%%:*}; dst=${pair##*:}
  if [ -s "$BACKUP/$src" ]; then
    install -m755 "$BACKUP/$src" "$WORK$dst"
    echo "  $src -> $dst"
  else
    warn "no $src in backup/ - gadget/adb will not come up in the new rootfs"
  fi
done
install -m755 "$ROOT/config/usb-adb-gadget.sh" "$WORK/usr/sbin/usb-adb-gadget"
install -m644 "$ROOT/config/usb-adb-gadget.service" "$WORK/etc/systemd/system/usb-adb-gadget.service"
# the Mobian unit calls gc, which a stock trixie rootfs does not provide; use ours.
rm -f "$WORK/etc/systemd/system/multi-user.target.wants/mobian-usb-gadget.service"
ln -sf /etc/systemd/system/usb-adb-gadget.service \
  "$WORK/etc/systemd/system/multi-user.target.wants/usb-adb-gadget.service"
echo "$TARGET-stick" > "$WORK/etc/hostname"
printf '127.0.0.1 localhost\n127.0.1.1 %s-stick\n' "$TARGET" > "$WORK/etc/hosts"
# no /etc/fstab entries: root comes from the boot.img cmdline root=PARTUUID=...
mkdir -p "$WORK/etc/systemd/network"
printf '[Match]\nName=usb0\n[Network]\nAddress=%s/24\nGateway=%s\n' \
  "$STICK_GADGET_IP" "$HOST_GADGET_IP" > "$WORK/etc/systemd/network/10-usb0.network"

log "4/4 emit image"
SIZE_MB=3300
mkfs.ext4 -q -F -L rootfs -d "$WORK" "$OUT/rootfs-$TARGET.img" $((SIZE_MB*1024*1024))
tar -C "$WORK" --xattrs -cf - . 2>/dev/null | zstd -q -10 -T0 -o "$OUT/rootfs-$TARGET.tar.zst"
log "built"
echo "  $OUT/rootfs-$TARGET.img   ($(du -h "$OUT/rootfs-$TARGET.img" | cut -f1) sparse)"
echo "  $OUT/rootfs-$TARGET.tar.zst"
echo
echo "  Sanity-check before flashing:"
echo "    ls $WORK/lib/modules; ls $WORK/lib/firmware | head"
echo "    python3 tools/bootimg.py info backup/boot-stock.bin   # the cmdline that must"
echo "    # still match: root=PARTUUID=<rootfs uuid> - unchanged, since boot is untouched"
