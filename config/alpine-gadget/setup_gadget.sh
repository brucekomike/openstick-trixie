#!/bin/sh
# Create a USB composite gadget: NCM (admin network) + ACM (serial console).
#
# Based on vendor/OpenStick-Builder-alpine/scripts/setup_ncm_gadget.sh, with two deltas:
#   * an `acm.usb0` function, so the laptop also gets /dev/ttyACM0. Combined with the
#     ttyGS0 shell in /etc/inittab this is a second admin door that does not depend on
#     the gadget netif being configured - which is exactly what failed on the first
#     Alpine boot, and it is the only way in when the board has no UART header attached.
#   * `gc` (gadget configfs helper) is not used: it is part of the un-packaged adb trio
#     and this image has no adbd anyway (the vendor one is glibc, musl cannot exec it).
set -e

DEV_ADDR="${DEV_ADDR:-02:00:2a:85:da:41}"
NCM_HOST_ADDR="${NCM_HOST_ADDR:-2a:85:da:41:eb:f9}"
NCM_DEV_ADDR="${NCM_DEV_ADDR:-2a:85:da:41:eb:fa}"
OS_DESC_VENDOR_CODE="${OS_DESC_VENDOR_CODE:-0xcd}"
OS_DESC_COMPAT_ID="${OS_DESC_COMPAT_ID:-NCM}"
GADGET_NAME="${GADGET_NAME:-ncm-acm-gadget}"
CFGFS=/sys/kernel/config/usb_gadget

mkdir -p "${CFGFS}/${GADGET_NAME}"
cd "${CFGFS}/${GADGET_NAME}"

echo 0x1d6b > idVendor
echo 0x0104 > idProduct
echo 0x0440 > bcdDevice
echo 0x0100 > bcdUSB
echo "${DEV_ADDR}" > UDC || true

mkdir -p strings/0x409
echo "fedcba9876543210" > strings/0x409/serialnumber
echo "Linux" > strings/0x409/manufacturer
echo "NCM+ACM Gadget" > strings/0x409/product

mkdir -p configs/c.1/strings/0x409
echo "NCM+ACM Config" > configs/c.1/strings/0x409/configuration

echo 1 > os_desc/use
printf '%d' "${OS_DESC_VENDOR_CODE}" > os_desc/b_vendor_code
echo "${OS_DESC_COMPAT_ID}" > os_desc/qw_sign

mkdir -p functions/ncm.usb0
echo "${NCM_HOST_ADDR}" > functions/ncm.usb0/host_addr
echo "${NCM_DEV_ADDR}" > functions/ncm.usb0/dev_addr
ln -sf functions/ncm.usb0 configs/c.1/

# The serial console is the door we use when the network door is broken, so failing to
# create it must not take the NCM function down with it.
if mkdir -p functions/acm.usb0 2>/dev/null && ln -sf functions/acm.usb0 configs/c.1/ 2>/dev/null; then
  echo "gadget: ncm + acm" > /dev/kmsg 2>/dev/null
else
  echo "gadget: ncm only (acm unavailable)" > /dev/kmsg 2>/dev/null
fi

UDC_NAME=$(ls /sys/class/udc | head -1)
echo "$UDC_NAME" > UDC
