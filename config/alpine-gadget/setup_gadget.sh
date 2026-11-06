#!/bin/sh
# Create the USB composite gadget: NCM (admin network) + ACM (serial console) + ffs.adb (adb).
#
# Based on vendor/OpenStick-Builder-alpine/scripts/setup_ncm_gadget.sh, with three deltas:
#   * an `acm.usb0` function, so the laptop also gets /dev/ttyACM0. Combined with the
#     ttyGS0 shell in /etc/inittab this is a second admin door that does not depend on
#     the gadget netif being configured - which is exactly what failed on the first
#     Alpine boot, and it is the only way in when the board has no UART header attached.
#   * an `ffs.adb` function, so the host gets a root `adb shell` and binary-safe
#     push/pull. The daemon is the vendor's own glibc adbd run under gcompat; see
#     scripts/55-patch-alpine-image.sh for why nothing packaged can be used instead.
#   * `gc` (gadget configfs helper) is not used: it is part of the un-packaged adb trio.
#
# ORDERING IS THE WHOLE TRICK for adb, and getting it wrong fails silently:
#   1. an ffs function can only be linked into a config once its userspace daemon has
#      opened ep0 and written the descriptors (ep1/ep2 appearing is the proof), and
#   2. a config cannot be modified at all while the gadget is bound to a UDC.
# So adbd is started here, waited on, and only then is the UDC written - last.
set -e

DEV_ADDR="${DEV_ADDR:-02:00:2a:85:da:41}"
NCM_HOST_ADDR="${NCM_HOST_ADDR:-2a:85:da:41:eb:f9}"
NCM_DEV_ADDR="${NCM_DEV_ADDR:-2a:85:da:41:eb:fa}"
OS_DESC_VENDOR_CODE="${OS_DESC_VENDOR_CODE:-0xcd}"
OS_DESC_COMPAT_ID="${OS_DESC_COMPAT_ID:-NCM}"
GADGET_NAME="${GADGET_NAME:-ncm-acm-gadget}"
CFGFS=/sys/kernel/config/usb_gadget

ADB_ENABLED="${ADB_ENABLED:-1}"
ADBD="${ADBD:-/usr/local/sbin/adbd}"
FFS_DIR="${FFS_DIR:-/dev/usb-ffs/adb}"
ADBD_LOG="${ADBD_LOG:-/var/log/adbd.log}"

# The adb serial is this board's own: /proc/device-tree/serial-number is the eMMC serial, which
# is unique per unit. Upstream's hardcoded "fedcba9876543210" makes every board
# flashed from this image answer `adb devices` identically - the same ambiguity that cost
# a whole session on the vendor images, where both sticks report the placeholder 0123456789.
SERIAL="${SERIAL:-$(tr -d '\0' < /proc/device-tree/serial-number 2>/dev/null)}"
[ -n "$SERIAL" ] || SERIAL=fedcba9876543210

mkdir -p "${CFGFS}/${GADGET_NAME}"
cd "${CFGFS}/${GADGET_NAME}"

echo 0x1d6b > idVendor
echo 0x0104 > idProduct
echo 0x0440 > bcdDevice
echo 0x0100 > bcdUSB

mkdir -p strings/0x409
echo "${SERIAL}" > strings/0x409/serialnumber
echo "Linux" > strings/0x409/manufacturer
echo "NCM+ACM+ADB Gadget" > strings/0x409/product

mkdir -p configs/c.1/strings/0x409
echo "NCM+ACM+ADB Config" > configs/c.1/strings/0x409/configuration

echo 1 > os_desc/use
printf '%d' "${OS_DESC_VENDOR_CODE}" > os_desc/b_vendor_code
echo "${OS_DESC_COMPAT_ID}" > os_desc/qw_sign

mkdir -p functions/ncm.usb0
echo "${NCM_HOST_ADDR}" > functions/ncm.usb0/host_addr
echo "${NCM_DEV_ADDR}" > functions/ncm.usb0/dev_addr
ln -sf functions/ncm.usb0 configs/c.1/

# The serial console is the door we use when the network door is broken, so failing to
# create it must not take the NCM function down with it.
ACM_OK=0
if mkdir -p functions/acm.usb0 2>/dev/null && ln -sf functions/acm.usb0 configs/c.1/ 2>/dev/null; then
  ACM_OK=1
fi

ADB_OK=0
if [ "${ADB_ENABLED}" = 1 ] && [ -x "${ADBD}" ]; then
  modprobe usb_f_fs 2>/dev/null || true
  # The configfs instance MUST exist before the mount: the kernel only allocates the ffs
  # device when functions/ffs.<name> is created, and `mount -t functionfs <name> ...`
  # returns ENODEV when no instance of that name exists yet. Mounting first (and creating
  # the instance after) leaves an empty /dev/usb-ffs/adb with no ep0, so adbd has nothing
  # to write descriptors to and the link below is correctly skipped - the gadget then comes
  # up with NCM+ACM but no adb, which is the failure this ordering comment is here to stop.
  mkdir -p functions/ffs.adb
  mkdir -p "${FFS_DIR}"
  if ! grep -q " ${FFS_DIR} " /proc/mounts; then
    # The mount source must equal the instance name ("adb"), not an arbitrary label.
    mount -t functionfs adb "${FFS_DIR}" 2>/dev/null ||
      echo "gadget: functionfs mount failed, no adb" > /dev/kmsg 2>/dev/null || true
  fi
  # `[a]dbd` rather than a plain pattern: the bracket stops grep matching its own command
  # line, which would make "already running" true on every call.
  if [ -e "${FFS_DIR}/ep0" ] && ! ps -o args 2>/dev/null | grep -q '[a]dbd'; then
    # The vendor adbd is glibc and this rootfs is musl, so it runs through gcompat's
    # loader; libcrypto.so.1.1 (its one non-gcompat dependency) sits in /usr/lib.
    #
    # PATH is set explicitly and MUST include /sbin. adbd hands its own environment to
    # every `adb shell`, and Alpine keeps its package manager at /sbin/apk. Launched from
    # this udev rule the inherited environment has no PATH at all, so `adb shell apk ...`
    # reports "not found" while ssh and the ttyGS0 console - which get the full path -
    # work fine. That asymmetry looks like a broken rootfs and is not.
    #
    # Started from a subshell whose cwd is /root, with HOME set. This script has already
    # `cd`'d into the configfs gadget directory, and adbd hands its own cwd and environment
    # to every `adb shell` - without this the shell lands in
    # /sys/kernel/config/usb_gadget/ncm-acm-gadget with HOME empty, so `cd ~` fails and
    # anything reading $HOME misbehaves.
    (
      cd /root || cd /
      setsid env HOME=/root TERM=linux \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        LD_LIBRARY_PATH=/usr/lib "${ADBD}" >>"${ADBD_LOG}" 2>&1 </dev/null &
    )
  fi
  i=0
  while [ ! -e "${FFS_DIR}/ep1" ] && [ "${i}" -lt 25 ]; do sleep 0.2; i=$((i + 1)); done
  # Only link it once the descriptors are really there: linking a not-yet-active ffs
  # function fails EINVAL and, worse, leaves the whole UDC bind failing afterwards.
  if [ -e "${FFS_DIR}/ep1" ] && ln -sf functions/ffs.adb configs/c.1/ 2>/dev/null; then
    ADB_OK=1
  fi
fi

printf 'gadget: ncm%s%s serial=%s\n' \
  "$([ "$ACM_OK" = 1 ] && echo '+acm' || echo '')" \
  "$([ "$ADB_OK" = 1 ] && echo '+adb' || echo '')" \
  "$SERIAL" > /dev/kmsg 2>/dev/null || true

UDC_NAME=$(ls /sys/class/udc | head -1)
echo "$UDC_NAME" > UDC
