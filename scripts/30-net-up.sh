#!/usr/bin/env bash
# Give the stick an internet path over the USB gadget link, for apt.
# The stick has no default route today (only 10.42.0.0/24 dev usb0) and no uplink.
# Host side needs sudo, so it is printed for you; device side is reversible.
. "$(dirname "$0")/lib.sh"

DOWN=0
case "${1:-}" in --down) DOWN=1 ;; esac

require_device

if [ "$DOWN" = 1 ]; then
  log "removing the temporary route/DNS from the stick"
  devrun "ip route del default via $HOST_GADGET_IP dev usb0 2>/dev/null || true"
  devrun "rm -f /etc/resolv.conf.bak-openstick"
  echo "  host side, when you want it gone too:"
  echo "    sudo iptables -t nat -D POSTROUTING -o $HOST_UPLINK_IF -j MASQUERADE"
  echo "    sudo iptables -D FORWARD -i $HOST_GADGET_IF -o $HOST_UPLINK_IF -j ACCEPT"
  echo "    sudo iptables -D FORWARD -i $HOST_UPLINK_IF -o $HOST_GADGET_IF -m state --state RELATED,ESTABLISHED -j ACCEPT"
  exit 0
fi

log "1/3 host: is the gadget interface up and can it reach the stick?"
ip -o addr show "$HOST_GADGET_IF" 2>/dev/null | sed 's/^/  /' || warn "$HOST_GADGET_IF not found - replug, or the interface name changed (ip -br a)"
if ping -c1 -W2 "$STICK_GADGET_IP" >/dev/null 2>&1; then
  echo "  ok: $STICK_GADGET_IP answers"
else
  warn "$STICK_GADGET_IP does not answer - the stick's usb0 may be down; check 'adb shell ip -br a'"
fi

log "2/3 host: forwarding + NAT (needs your password - run these)"
cat <<EOF
  sudo sysctl -w net.ipv4.ip_forward=1
  sudo iptables -t nat -A POSTROUTING -o $HOST_UPLINK_IF -j MASQUERADE
  sudo iptables -A FORWARD -i $HOST_GADGET_IF -o $HOST_UPLINK_IF -j ACCEPT
  sudo iptables -A FORWARD -i $HOST_UPLINK_IF -o $HOST_GADGET_IF -m state --state RELATED,ESTABLISHED -j ACCEPT
EOF
echo
echo "  Also worth fixing while you are root on the host: this box currently has a"
echo "  stray 'default via $STICK_GADGET_IP dev $HOST_GADGET_IF' route. If the stick has"
echo "  no uplink, your laptop intermittently loses internet through it. Delete it with:"
echo "    sudo ip route del default via $STICK_GADGET_IP dev $HOST_GADGET_IF"

log "3/3 stick: temporary default route + DNS"
devrun "cp -a /etc/resolv.conf /etc/resolv.conf.bak-openstick 2>/dev/null; printf 'nameserver 1.1.1.1\\nnameserver 8.8.8.8\\n' > /etc/resolv.conf; ip route replace default via $HOST_GADGET_IP dev usb0"
if [ "${COMMIT:-0}" = "1" ]; then
  log "connectivity check from the stick"
  dev "ping -c2 -W3 1.1.1.1 2>&1 | tail -2; ping -c2 -W3 mirrors.tuna.tsinghua.edu.cn 2>&1 | tail -2" | sed 's/^/  /'
  echo "  If ping works but apt does not, the mirror is being redirected - check the"
  echo "  proxy: on this laptop the convention is 'proxy.sh <cmd>' for host commands."
else
  echo "  (dry run - rerun with COMMIT=1 to apply the stick-side route and test it)"
fi
