#!/bin/sh
# Dependency-free USB gadget bring-up for the OpenStick UFI103s.
#
# Why this exists: the stock /usr/sbin/mobian-usb-gadget calls the `gc`
# (gadget-tools) binary, and neither `gc` nor `/usr/bin/adbd` is owned by a dpkg
# package. After a distribution upgrade (or a rebuilt rootfs) both are gone, so
# the stick comes back with no adb - the exact failure reported for trixie.
# This script touches nothing but configfs plus adbd, so it survives any distro.
#
# Usage: usb-adb-gadget {setup|reset|status}

set -e

G=/sys/kernel/config/usb_gadget/g1
FFS_DIR=/dev/usb-ffs/adb
FFS_NAME=adb
MANUF="Handsome"
PROD="OpenStick UFI103s"
SERIAL="0123456789"
# 0x18d1:google / 0x0002 = the VID/PID adb looks for; rndis keeps the 10.42.0.1 link.
VID=0x18d1
PID=0x0002

udc() { ls /sys/class/udc 2>/dev/null | head -1; }

reset() {
	[ -d "$G" ] || return 0
	# UDC must be released before the gadget tree can be removed.
	[ -n "$G/UDC" ] && echo "" > "$G/UDC" 2>/dev/null || true
	for l in "$G"/configs/c.1/*; do
		[ -L "$l" ] && rm -f "$l" || true
	done
	for f in "$G"/functions/*; do
		[ -e "$f" ] && rmdir "$f" 2>/dev/null || true
	done
	rmdir "$G"/configs/c.1/strings/0x409 "$G"/configs/c.1 2>/dev/null || true
	rmdir "$G"/strings/0x409 2>/dev/null || true
	rmdir "$G" 2>/dev/null || true
}

setup() {
	U=$(udc)
	[ -n "$U" ] || { echo "no UDC in /sys/class/udc - is the usb controller bound?" >&2; exit 1; }

	reset
	mkdir -p "$G/strings/0x409" "$G/configs/c.1/strings/0x409"
	echo "$VID" > "$G/idVendor"
	echo "$PID" > "$G/idProduct"
	echo "0x0601" > "$G/bcdUSB" 2>/dev/null || true
	echo "$MANUF" > "$G/strings/0x409/manufacturer"
	echo "$PROD" > "$G/strings/0x409/product"
	echo "$SERIAL" > "$G/strings/0x409/serialnumber"
	# 0xC0 = self-powered; these sticks are bus-powered so use 0x80 + 500mA.
	echo 0x80 > "$G/configs/c.1/bmAttributes"
	echo 500 > "$G/configs/c.1/MaxPower"
	echo "$MANUF" > "$G/configs/c.1/strings/0x409/manufacturer"
	echo "RNDIS+ADB" > "$G/configs/c.1/strings/0x409/configuration"

	mkdir -p "$G/functions/rndis.usb0"
	mkdir -p "$G/functions/ffs.$FFS_NAME"
	echo "$FFS_NAME" > "$G/functions/ffs.$FFS_NAME/name" 2>/dev/null || true

	mkdir -p "$FFS_DIR"
	mountpoint -q "$FFS_DIR" || mount -t functionfs "$FFS_NAME" "$FFS_DIR"
	mkdir -p "$FFS_DIR/strings/0x409" 2>/dev/null || true

	ln -s "$G/functions/rndis.usb0" "$G/configs/c.1/rndis.usb0"
	ln -s "$G/functions/ffs.$FFS_NAME" "$G/configs/c.1/ffs.$FFS_NAME"

	# adbd must be up before the UDC bind, otherwise enable fails with ENODEV.
	if [ -x /usr/bin/adbd ] || [ -x /usr/sbin/adbd ]; then
		ADBD=$(command -v adbd)
		"$ADBD" -D >/dev/null 2>&1 &
		i=0
		while [ ! -e "$FFS_DIR/ep0" ] && [ "$i" -lt 20 ]; do sleep 0.2; i=$((i+1)); done
	else
		echo "adbd not installed - gadget will not enable" >&2
	fi

	echo "$U" > "$G/UDC"
	echo "gadget $G bound to $U ($(cat "$G/UDC" 2>/dev/null))"
}

status() {
	echo "UDC=$(cat "$G/UDC" 2>/dev/null || echo none)"
	echo "functions: $(ls "$G/functions" 2>/dev/null | tr '\n' ' ')"
	echo "configfs links: $(ls "$G/configs/c.1" 2>/dev/null | tr '\n' ' ')"
	echo "ffs ep0: $([ -e "$FFS_DIR/ep0" ] && echo yes || echo no)"
	echo "adbd: $(pgrep -x adbd || echo stopped)"
	ip -o link show usb0 2>/dev/null || echo "usb0: absent"
}

case "${1:-}" in
	setup) setup ;;
	reset) reset ;;
	status) status ;;
	*) echo "usage: $0 {setup|reset|status}" >&2; exit 2 ;;
esac
