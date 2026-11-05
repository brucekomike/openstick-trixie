#!/usr/bin/env bash
# Build the ext2 `boot` partition image that a mainline kernel needs on this board:
#   /vmlinuz  /dtbs/qcom/*.dtb  /extlinux/extlinux.conf
#
#   scripts/68-make-mainline-boot.sh
#
# Requires the community aboot (scripts/74-flash-mainline-bootchain.sh): the factory aboot on
# these sticks has no extlinux parser at all (`strings part-aboot.bin | grep -c extlinux` = 0,
# and it carries `Unable to load boot.img from ext2. Continuing legacy boot`), so an ext2 boot
# partition is only readable once aboot/hyp are the OpenStick-Builder v0.2 ones.
#
# Layout and key format match the community's own known-good boot.bin byte-for-byte in shape:
# lowercase `linux`/`fdt`/`append`, no `initrd` line, no LABEL block. Verified by unpacking
# OpenStick-Builder v0.2's boot.bin (Linux 6.6.0-msm8916 + extlinux + /dtbs/qcom/).
. "$(dirname "$0")/lib.sh"

OUT_IMG=${OUT_IMG:-$OUT/boot-mainline.img}
STAGE=${STAGE:-$OUT/boot-mainline}
KERNEL=${KERNEL:-$OUT/vmlinuz-mainline.gz}
# Community DTB is the default: it is the one pmOS pairs with this model
# (device-generic-zhihe-kernel-ufi001c -> deviceinfo_dtb="qcom/msm8916-thwc-ufi001c"), and it
# carries the rmtfs@/mpss@ reserved-memory nodes the vendor DTB lacks - without them the modem
# probe fails with "unable to resolve mpss region" and there is no LTE at all.
# Named exactly as the kernel package installs it, because /boot is a real mounted partition:
# after `apk upgrade linux-postmarketos-qcom-msm8916`, the DTB lands at this same path, and an
# extlinux.conf pointing at a private name would silently stop matching.
DTB_NAME=${DTB_NAME:-msm8916-thwc-ufi001c.dtb}
DTB=${DTB:-$OUT/$DTB_NAME}
DTB_ALT=${DTB_ALT:-$OUT/bootimg-current/dtb0.dtb}   # this board's own stock DTB
DTB_ALT_NAME=${DTB_ALT_NAME:-msm8916-handsome-openstick.dtb}
PMOS_APK=${PMOS_APK:-$(ls -1 "$OUT"/linux-postmarketos-qcom-msm8916*.apk 2>/dev/null | head -1)}

# apk payloads are tar.gz; unpack into a scratch dir, never into $OUT, which may already hold a
# boot/ tree from other scripts (a colliding rmdir would abort this one under `set -e`).
apk_get() { # $1=path inside the apk  $2=destination
  [ -s "$PMOS_APK" ] || return 1
  local tmp; tmp=$(mktemp -d)
  if tar -xzf "$PMOS_APK" -C "$tmp" "$1" 2>/dev/null && [ -s "$tmp/$1" ]; then
    install -m 644 "$tmp/$1" "$2" && rm -rf "$tmp" && return 0
  fi
  rm -rf "$tmp"; return 1
}

log "1/5 sources"
[ -s "$KERNEL" ] || apk_get boot/vmlinuz "$KERNEL" || true
[ -s "$KERNEL" ] || die "no kernel at $KERNEL (set KERNEL=, or drop a linux-postmarketos-qcom-msm8916*.apk in out/)"
[ -s "$DTB" ] || apk_get "boot/dtbs/qcom/$DTB_NAME" "$DTB" || true
[ -s "$DTB" ] || die "no DTB at $DTB"
# The stock DTB comes from this board's own backup, verified against the live model string by
# scripts/54-build-alpine-onstick.sh; never take it from a path that could be another board's.
if [ ! -s "$DTB_ALT" ]; then
  require_backup boot-stock.bin
  python3 "$ROOT/tools/bootimg.py" unpack "$BACKUP/boot-stock.bin" "$OUT/bootimg-current" >/dev/null
fi
# The root PARTUUID must be read from the device, not trusted from an env file named for another
# board. adb is gone once the rootfs is musl, so try ssh first, then adb, then the env value.
SSH_KEY=${SSH_KEY:-$OUT/openstick_key}
UUID=$(timeout 15 ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=6 root@192.168.5.1 "tr -d '\0' < /proc/cmdline" 2>/dev/null |
  grep -oE 'PARTUUID=[0-9a-fA-F-]+' | head -1 | cut -d= -f2)
if [ -z "$UUID" ]; then
  UUID=$(dev "tr -d '\0' < /proc/cmdline" 2>/dev/null | grep -oE 'PARTUUID=[0-9a-fA-F-]+' | head -1 | cut -d= -f2)
fi
if [ -z "$UUID" ]; then
  UUID=$ROOT_PARTUUID
  warn "could not read root=PARTUUID from the device; using the env value $UUID"
fi
log "kernel $(stat -c %s "$KERNEL") B, dtb $(basename "$DTB"), alt $([ -s "$DTB_ALT" ] && basename "$DTB_ALT" || echo none), root=PARTUUID=$UUID"

log "2/5 staging tree"
rm -rf "$STAGE"; mkdir -p "$STAGE/extlinux" "$STAGE/dtbs/qcom"
install -m 644 "$KERNEL" "$STAGE/vmlinuz"
install -m 644 "$DTB" "$STAGE/dtbs/qcom/$DTB_NAME"
if [ -s "$DTB_ALT" ]; then
  install -m 644 "$DTB_ALT" "$STAGE/dtbs/qcom/$DTB_ALT_NAME"
fi
# The vendor 5.15 kernel + Debian initrd stay on the partition as a labelled fallback: they are
# the only thing known to boot if a mainline kernel ever stops working.
for k in "$OUT"/vmlinuz-5.15* "$OUT"/boot/vmlinuz-5.15*; do
  if [ -s "$k" ]; then install -m 644 "$k" "$STAGE/vmlinuz-5.15"; break; fi
done
for r in "$OUT"/initrd-5.15* "$OUT"/boot/initrd.img-5.15*; do
  if [ -s "$r" ]; then install -m 644 "$r" "$STAGE/initrd-5.15"; break; fi
done
if [ ! -s "$STAGE/vmlinuz-5.15" ] && [ -s "$BACKUP/boot-stock.bin" ]; then
  python3 "$ROOT/tools/bootimg.py" unpack "$BACKUP/boot-stock.bin" "$OUT/bootimg-current" >/dev/null 2>&1 || true
  [ -s "$OUT/bootimg-current/kernel-only.gz" ] && install -m 644 "$OUT/bootimg-current/kernel-only.gz" "$STAGE/vmlinuz-5.15"
  [ -s "$OUT/bootimg-current/ramdisk.img" ] && install -m 644 "$OUT/bootimg-current/ramdisk.img" "$STAGE/initrd-5.15"
fi

mk_conf() { # $1=fdt $2=linux $3=initrd $4=out
  {
    echo "linux $2"
    [ -n "$3" ] && echo "initrd $3"
    echo "fdt $1"
    echo "append earlycon root=PARTUUID=$UUID console=ttyMSM0,115200 no_framebuffer=true rw rootwait"
  } > "$4"
  chmod 644 "$4"
}
mk_conf "/dtbs/qcom/$DTB_NAME" /vmlinuz "" "$STAGE/extlinux/extlinux.conf"
if [ -s "$DTB_ALT" ]; then
  mk_conf "/dtbs/qcom/$DTB_ALT_NAME" /vmlinuz "" "$STAGE/extlinux/extlinux-handsome.conf"
fi
if [ -s "$STAGE/vmlinuz-5.15" ]; then
  mk_conf "/dtbs/qcom/$DTB_ALT_NAME" /vmlinuz-5.15 /initrd-5.15 "$STAGE/extlinux/extlinux-5.15.conf"
fi
cat "$STAGE/extlinux/extlinux.conf" | sed 's/^/  /'

log "3/5 mke2fs -d (no mount, no loop device, no sudo)"
USED=$(du -sm "$STAGE" | cut -f1)
rm -f "$OUT_IMG"
truncate -s 64M "$OUT_IMG"
mke2fs -q -F -L boot -t ext2 -d "$STAGE" "$OUT_IMG" || die "mke2fs failed (staged ${USED} MB)"

log "4/5 verify what is actually in the image"
debugfs -R "cat /extlinux/extlinux.conf" "$OUT_IMG" 2>/dev/null | sed 's/^/  | /'
debugfs -R "ls /" "$OUT_IMG" 2>/dev/null | tr -s ' ' '\n' | grep -vE '^[0-9()]+$|^\.$|^\.\.$|^$' | sed 's/^/  /' | tr '\n' ' '; echo
debugfs -R "dump /vmlinuz $OUT/.verify-vmlinuz" "$OUT_IMG" 2>/dev/null
cmp -s "$OUT/.verify-vmlinuz" "$KERNEL" && echo "  ok: /vmlinuz byte-identical to the source kernel" || die "/vmlinuz in the image differs"
rm -f "$OUT/.verify-vmlinuz"
e2fsck -fn "$OUT_IMG" >/dev/null 2>&1 && echo "  ok: e2fsck clean" || warn "e2fsck reported problems"

log "5/5 result"
echo "  $OUT_IMG  $(stat -c %s "$OUT_IMG") bytes (${USED} MB of payload)"
cat <<EOF

Flash it (the stick must be in fastboot - scripts/72-enter-fastboot.sh gets it there from Linux):
  fastboot flash boot $OUT_IMG
Switching kernel or DTB afterwards needs no reflashing: /boot is a real ext2 partition, so
  cp /boot/extlinux/extlinux-handsome.conf /boot/extlinux/extlinux.conf && reboot
EOF
