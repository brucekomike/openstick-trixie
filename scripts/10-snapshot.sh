#!/usr/bin/env bash
# Read-only snapshot of the stick into notes/. Safe to run any number of times.
. "$(dirname "$0")/lib.sh"

require_device
mkdir -p "$NOTES"
N="$NOTES/snapshot-$(echo "$BOARD_NAME" | tr ' ' '-')-$STAMP"
mkdir -p "$N"

grab() { # grab <file> <device command> - never aborts the run on a single bad command
  printf '%s\n' "--- $2" > "$N/$1"
  if dev "$2" >> "$N/$1" 2>/dev/null; then :; else
    printf '(command failed or hit the 60s cap)\n' >> "$N/$1"
    warn "$1 incomplete"
  fi
  echo "  wrote notes/$(basename "$N")/$1 ($(wc -l < "$N/$1") lines)"
}

grab 00-os-release.txt        'cat /etc/os-release; echo; uname -a'
grab 01-cmdline.txt           'cat /proc/cmdline'
grab 02-cpu.txt               'grep -E "processor|model name|CPU part|Features" /proc/cpuinfo | sort -u; getconf PAGESIZE; nproc'
grab 03-memory.txt            'free -m; echo; swapon --show'
grab 04-storage.txt           'fdisk -l /dev/mmcblk0; echo; ls -l /dev/disk/by-partlabel/ /dev/disk/by-partuuid/'
grab 05-mounts.txt            'mount; df -h'
grab 06-devicetree.txt        'echo compatible=$(cat /proc/device-tree/compatible | tr -d "\0"); echo model=$(cat /proc/device-tree/model | tr -d "\0"); ls /sys/firmware'
grab 07-kernel.txt            "ls -l /boot/ /lib/modules/; echo; grep -E 'CONFIG_LOCALVERSION=|CONFIG_ARM64_4K_PAGES|CONFIG_COMPAT=|CONFIG_MODULES=|CONFIG_OVERLAY_FS' /boot/config-${KVER} 2>/dev/null"
grab 08-packages.txt          'dpkg -l'
grab 09-units.txt             'systemctl list-unit-files --state=enabled --no-pager; echo; systemctl list-units --type=service --state=running --no-pager --no-legend'
grab 10-gadget.txt            "ls -l /sys/kernel/config/usb_gadget/; for f in /sys/kernel/config/usb_gadget/*/configs/*/*; do echo \$f; done; cat /sys/kernel/config/usb_gadget/g1/UDC 2>/dev/null; ls /sys/class/udc; echo; cat $GADGET_SCRIPT 2>/dev/null; ls -l $ADBD_BIN \$(command -v $GADGET_TOOL 2>/dev/null)"
grab 11-firmware-list.txt     'ls /lib/firmware | sort; echo; du -sh /lib/firmware /lib/modules /boot'
grab 12-network.txt           'ip -br a; ip -br r; nmcli -t -f DEVICE,TYPE,STATE device 2>/dev/null'
grab 13-modem.txt             'ls -l /sys/class/remoteproc/; for r in /sys/class/remoteproc/*; do echo $r $(cat $r/name) $(cat $r/state); done; systemctl is-active qrtr-ns rmtfs ModemManager; qmicli -d /dev/cdc-wdm0 --dms-get-model 2>&1 | head -3'
grab 14-apt.txt               'cat /etc/apt/sources.list; echo; cat /etc/apt/sources.list.d/* 2>/dev/null; echo; apt-cache policy 2>/dev/null | head -20'
grab 15-boot-header.txt       "dd if=/dev/disk/by-partlabel/boot bs=2048 count=1 2>/dev/null | od -A d -t x1"

log "decoding the boot image header from the hex dump"
# The header is decoded from the od text, never from a binary pipe: adb's PTY rewrites
# bytes (\n -> \r\n), so a raw dd-through-shell backup would be silently corrupt.
if dev "dd if=/dev/disk/by-partlabel/boot bs=2048 count=1 2>/dev/null | od -An -tx1" > "$N/16-boot-header-hex.txt" 2>/dev/null; then
  python3 - "$N/16-boot-header-hex.txt" <<'PY'
import re, struct, sys
raw = bytes(int(b, 16) for b in re.findall(r"[0-9a-f]{2}", open(sys.argv[1]).read()))
if not raw.startswith(b"ANDROID!"):
    sys.exit("  header page is not an Android boot image")
k_sz, k_ad, r_sz, r_ad, s_sz, s_ad, tags, page, dtb_sz, os_ver = struct.unpack_from("<10I", raw, 8)
name = raw[48:64].split(b"\0")[0].decode(errors="replace")
cmdline = raw[64:576].split(b"\0")[0].decode(errors="replace")
for line in (f"kernel_size {k_sz} @0x{k_ad:08x}", f"ramdisk_size {r_sz} @0x{r_ad:08x}",
             f"second_size {s_sz}", f"tags_addr 0x{tags:08x}", f"page_size {page}",
             f"dtb_size_field {dtb_sz}", f"os_version 0x{os_ver:08x}",
             f"name {name}", f"cmdline {cmdline}"):
    print("  " + line)
open(sys.argv[1].replace("-hex.txt", ".txt"), "w").write(
    "\n".join([f"kernel_size {k_sz}", f"ramdisk_size {r_sz}", f"second_size {s_sz}",
               f"tags_addr 0x{tags:08x}", f"page_size {page}", f"name {name}",
               f"cmdline {cmdline}"]) + "\n")
PY
else
  warn "boot header dump failed"
fi

log "snapshot in $N"
echo "  nothing was written to the stick; notes/ is gitignored (it captures the"
echo "  partition UUIDs and model strings but no radio identifiers)."
echo "  full boot.img decode + dtb split: scripts/20-backup.sh then"
echo "  scripts/60-build-bootimg.sh unpack"
