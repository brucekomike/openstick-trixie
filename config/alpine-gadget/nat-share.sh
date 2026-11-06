#!/bin/sh
# Share the stick's uplink (Wi-Fi station, or the LTE modem) with the host over the USB
# gadget link, so plugging the stick in gives the laptop internet with no configuration on
# either side.
#
#   nat-share.sh             recompute the uplink and apply (what the dispatcher calls)
#   nat-share.sh status      what it decided, and why
#
# Why a hook on NetworkManager rather than a boot script: the uplink is not known when the
# gadget comes up. Wi-Fi associates seconds later (or never), and on a stick with no Wi-Fi
# the uplink is wwan0. NM's dispatcher reports exactly the event that decides this.
#
# The admin door does not depend on any of it: gadget addressing and DHCP are set up by
# gadget-net-up.sh from /etc/inittab, with no dbus and no NM. If this script fails outright,
# 192.168.5.1 is still reachable and still hands the host an address.
set -eu

GADGET_NET=${GADGET_NET:-192.168.5.0/24}
GADGET_GW=${GADGET_GW:-192.168.5.1}
DNS_DIR=${DNS_DIR:-/var/lib/nat-share}
DNS_FILE=$DNS_DIR/upstream-dns
LOG=${LOG:-/var/log/nat-share.log}

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >> "$LOG" 2>/dev/null || true; }

# The interface carrying the default route. "Connected" is not enough - a Wi-Fi network
# without a gateway must not capture the share.
#
# Take the word after `dev`, not field 3. `ip -4 route show default` prints
#   default via 192.168.24.1 dev wlan0 proto dhcp src 192.168.24.162 metric 600
# so field 3 is the GATEWAY, and the first version of this function returned it as the
# interface - producing `-o 192.168.24.1`, a rule iptables accepts and that matches nothing.
# NAT then silently does not happen, which is exactly the kind of failure that looks like a
# success. The `dev` scan also handles an on-link default ("default dev wlan0 ...") with no
# gateway at all. Measured 2026-11-06 while debugging a MacBook that got a lease and no route.
uplink() { ip -4 route show default 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1; }

gadget_iface() {
  for cand in usb0 ncm0 ecm0; do
    if [ -d "/sys/class/net/$cand" ]; then printf '%s\n' "$cand"; return 0; fi
  done
  # The gadget netdev is named differently on the vendor kernel than on mainline, so fall
  # back to whichever interface holds the gateway address.
  ip -o -4 addr show 2>/dev/null | awk -v gw="$GADGET_GW" \
    '$4 ~ ("^" gw "(/|$)") {print $2; exit}'
}

# Resolvers to hand the host: the ones the uplink was given. /etc/resolv.conf on this image
# points at the stick itself (that is what the host is told to ask), so it cannot be the
# source - NM writes the real per-connection servers to its own file.
collect_dns() {
  mkdir -p "$DNS_DIR"
  {
    sed -n 's/^nameserver \([0-9.]\{7,\}\).*/\1/p' /run/NetworkManager/resolv.conf 2>/dev/null || true
    sed -n 's/^nameserver \([0-9.]\{7,\}\).*/\1/p' /etc/resolv.conf 2>/dev/null || true
  } | grep -v "^$GADGET_GW$" | sort -u > "$DNS_FILE" 2>/dev/null || true
}

teardown() {
  sysctl -w net.ipv4.ip_forward=0 >/dev/null 2>&1 || true
  : > "$DNS_FILE"
}

apply() {
  up=$(uplink)
  gi=$(gadget_iface || true)
  if [ -z "$gi" ]; then
    log "no gadget interface yet; nothing to share onto"
    return 0
  fi
  if [ -z "$up" ] || [ "$up" = "$gi" ]; then
    # No uplink (or the gadget is itself the default route, which would be a loop). Leave
    # the door as it is: address + DHCP, no forwarding, no NAT.
    if [ -s "$DNS_FILE" ] || [ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" != 0 ]; then
      teardown
      log "no uplink (gadget=$gi): forwarding off, upstream DNS cleared"
    fi
    return 0
  fi

  log "sharing $up to the host through $gi"
  sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || log "WARN could not enable ip_forward"
  # Delete-then-add: the dispatcher fires on every DHCP renew, and appending each time would
  # grow the chain without bound. iptables exits non-zero when the rule was absent, which is
  # not a failure here.
  iptables -t nat -D POSTROUTING -s "$GADGET_NET" -o "$up" -j MASQUERADE 2>/dev/null || true
  iptables -D FORWARD -i "$gi" -o "$up" -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -i "$up" -o "$gi" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
  iptables -t nat -A POSTROUTING -s "$GADGET_NET" -o "$up" -j MASQUERADE
  iptables -A FORWARD -i "$gi" -o "$up" -j ACCEPT
  iptables -A FORWARD -i "$up" -o "$gi" -m state --state RELATED,ESTABLISHED -j ACCEPT

  collect_dns
  log "upstream DNS: $(tr '\n' ' ' < "$DNS_FILE")"
  # dnsmasq is started by gadget-net-up.sh and reads this file for upstreams; SIGHUP makes it
  # pick up a changed uplink without dropping the host's lease.
  pid=$(pidof dnsmasq 2>/dev/null | awk '{print $1}' || true)
  if [ -n "$pid" ]; then
    kill -HUP "$pid" 2>/dev/null && log "dnsmasq reloaded (pid $pid)" || log "WARN could not reload dnsmasq"
  else
    log "dnsmasq not running yet; it will read $DNS_FILE when gadget-net-up.sh starts it"
  fi
}

case "${1:-apply}" in
  apply|up|down|change|hostname|dhcp6-change|none) apply ;;
  status)
    up=$(uplink); gi=$(gadget_iface || true)
    echo "  uplink (default route): ${up:-none}"
    echo "  gadget iface:         ${gi:-none}"
    echo "  ip_forward:           $(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)"
    printf '  upstream DNS:\n'; sed 's/^/    /' "$DNS_FILE" 2>/dev/null || echo "    (none yet)"
    printf '  nat POSTROUTING:\n'; iptables -t nat -S POSTROUTING 2>/dev/null | sed 's/^/    /' || true
    printf '  recent events:\n'; tail -8 "$LOG" 2>/dev/null | sed 's/^/    /' || true
    ;;
  *) echo "usage: nat-share.sh [apply|status]" >&2; exit 2 ;;
esac
