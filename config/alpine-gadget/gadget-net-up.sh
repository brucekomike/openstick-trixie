#!/bin/sh
# Bring the USB gadget network up deterministically, without depending on NetworkManager.
#
# Why this exists: measured 2026-11-05 on the UFI001C. The first Alpine image booted far
# enough that eudev ran setup_ncm_gadget.sh and the laptop got a real cdc_ncm interface
# (enx2a85da41ebf9 = the gadget's NCM_HOST_ADDR), but the host stayed NO-CARRIER because
# nothing on the device ever set the gadget netif UP. Upstream hands that job to a
# NetworkManager profile pinned to `interface-name=usb0`; the stock gadget on this board
# was rndis (which this kernel names usb0) while configfs NCM is ncm0 on mainline, so the
# profile can simply never match. This script is name-agnostic and NM-independent, which
# also means the admin door does not depend on dbus being up.
#
# Runs from /etc/inittab (`::once:`), invoked as `/bin/sh <path>` so it needs no exec bit.
ADDR=${GADGET_ADDR:-192.168.5.1/24}
DHCP_LO=${DHCP_LO:-192.168.5.20}
DHCP_HI=${DHCP_HI:-192.168.5.60}
LOG=/var/log/gadget-net.log

log() {
  printf 'gadget-net: %s\n' "$*" >> "$LOG" 2>/dev/null
  # Mirror to the serial console if one is attached; this is the only channel that works
  # when the gadget itself is what is broken.
  if [ -w /dev/ttyMSM0 ]; then
    printf 'gadget-net: %s\n' "$*" > /dev/ttyMSM0 2>/dev/null
  fi
}

log "waiting for a gadget netif (up to 60s)"
iface=""
i=0
while [ -z "$iface" ] && [ "$i" -lt 60 ]; do
  for d in /sys/class/net/*; do
    n=${d##*/}
    case "$n" in
      lo|wlan*|eth*) continue ;;
    esac
    # Measured on this board (Alpine, vendor 5.15): the gadget netdev is usb0 and its
    # sysfs `device` link resolves to a path *named* gadget - there is no `gadget`
    # subdirectory under it, which is what the first version of this test looked for.
    tgt=$(readlink -f "$d/device" 2>/dev/null)
    case "$tgt" in
      */gadget|*/gadget/*) iface=$n; break ;;
    esac
  done
  # Name fallback: if the sysfs shape ever changes again, usb0/ncm0 is still the gadget.
  if [ -z "$iface" ]; then
    for cand in usb0 ncm0 ecm0; do
      if [ -d "/sys/class/net/$cand" ]; then iface=$cand; break; fi
    done
  fi
  if [ -z "$iface" ]; then
    sleep 1
    i=$((i + 1))
  fi
done

if [ -z "$iface" ]; then
  log "FAILED: no gadget netif after 60s; netdevs seen: $(ls /sys/class/net | tr '\n' ' ')"
  exit 1
fi

log "found $iface; configuring $ADDR"
ip link set "$iface" up
ip addr flush dev "$iface" 2>/dev/null
ip addr add "$ADDR" dev "$iface"
ip link set "$iface" up

# Serve DHCP on the gadget link so the host needs no configuration of its own, and answer DNS
# too - the host is handed 192.168.5.1 as its resolver, so something must listen.
#
# Measured on the UFI103s: with `--port=0` dnsmasq did DHCP only, and the laptop got a lease,
# a route and a nameserver that was never answering. The upstream servers are not read from
# /etc/resolv.conf (on this image that points back at 127.0.0.1/192.168.5.1, which would make
# dnsmasq query itself); nat-share.sh maintains the real ones from the uplink in $DNS_FILE and
# sends dnsmasq SIGHUP when they change. `--bind-interfaces` keeps us on the gadget address
# only, so NM's own dnsmasq (used by the hotspot profile) can hold a different one.
DNS_DIR=${DNS_DIR:-/var/lib/nat-share}
DNS_FILE=$DNS_DIR/upstream-dns
mkdir -p "$DNS_DIR" 2>/dev/null || true
[ -f "$DNS_FILE" ] || : > "$DNS_FILE"
GADGET_IP=${GADGET_IP:-${ADDR%%/*}}
if ! pidof dnsmasq >/dev/null 2>&1; then
  dnsmasq --interface="$iface" --bind-interfaces \
    --dhcp-range="$DHCP_LO","$DHCP_HI",255.255.255.0,12h \
    --dhcp-option=6,"$GADGET_IP" --resolv-file="$DNS_FILE" --no-hosts \
    --log-dhcp --log-facility="$LOG" \
    && log "dnsmasq started on $iface (dhcp $DHCP_LO-$DHCP_HI, dns from $DNS_FILE)" \
    || log "WARN dnsmasq did not start"
else
  log "dnsmasq already running"
fi

log "carrier=$(cat "/sys/class/net/$iface/carrier" 2>/dev/null) operstate=$(cat "/sys/class/net/$iface/operstate" 2>/dev/null) addrs=$(ip -o addr show "$iface" | awk '{printf "%s ", $4}')"
log "done. host should now reach 192.168.5.1 (ssh user@192.168.5.1)"
