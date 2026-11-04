#!/usr/bin/env bash
# Route A: move the userspace to Debian 13 while KEEPING the stock 5.15 kernel and the
# stock boot partition untouched. That is deliberate - this board's `handsome,openstick`
# DTB is not in mainline and not in the community kernel's release branch, so the only
# device tree guaranteed to match the hardware is the one already in boot-stock.bin.
#
#   scripts/40-inplace-upgrade.sh                     # preflight only (read-only)
#   COMMIT=1 scripts/40-inplace-upgrade.sh --to bookworm   # stage the upgrade
#   then run the printed apt commands in an interactive `adb shell -t`
#   COMMIT=1 scripts/40-inplace-upgrade.sh --to trixie     # same, one hop later
#
# bullseye -> trixie is NOT a supported single hop; the script enforces bookworm first.
. "$(dirname "$0")/lib.sh"
require_backup boot-stock.bin

TO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --to) TO="$2"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_device
CUR=$(dev 'grep -oP "(?<=^VERSION_CODENAME=)\S+" /etc/os-release' | tr -d '\r')
log "current release on stick: ${CUR:-unknown}; target: ${TO:-none (preflight only)}"

if [ -n "$TO" ]; then
  case "$TO" in
    bookworm) [ "$CUR" = bullseye ] || die "bookworm hop expects CUR=bullseye, got $CUR" ;;
    trixie)
      case "$CUR" in
        bookworm) : ;;
        bullseye) die "bullseye -> trixie is not a supported upgrade path. Run --to bookworm first." ;;
        trixie)   warn "already trixie - nothing to stage" ;;
        *) die "unexpected current release $CUR" ;;
      esac ;;
    *) die "--to takes bookworm|trixie" ;;
  esac
fi

# ---------------------------------------------------------------- preflight (read-only)
log "preflight"
fails=0
note() { printf '  %-26s %s\n' "$1" "$2"; }

AVAILNUM=$(dev_avail_mb)
FREE_TOTAL=$(dev "df -P --block-size=1M / | awk 'NR==2{print \$2}'" | tr -dc '0-9')
note "rootfs free" "${AVAILNUM} MB of ${FREE_TOTAL} MB (needs >= 1500 MB during full-upgrade)"
if [ "${AVAILNUM:-0}" -lt 1500 ]; then
  warn "only ${AVAILNUM} MB free - purge /var/cache/apt/archives and old logs first"
  fails=$((fails+1))
fi

SWAP=$(dev "free -m | awk '/Swap:/{print \$2}'" | tr -d '\r')
note "swap total" "${SWAP} MB (zram0 only - 461 MB RAM cannot unpack a full distro on zram alone)"

OWNER=$(dev "dpkg -S /lib/systemd/system/zramswap.service 2>&1 | head -1" | tr -d '\r')
note "zram unit owner" "$OWNER"
case "$OWNER" in
  *"no pattern found"*|*error*) warn "zramswap.service is not dpkg-owned: an upgrade will not keep it alive by package deps, so do NOT delete it. Confirm 'free -m' still shows swap after each hop." ;;
esac

KPKG_OK=$(dev "dpkg -l $KERNEL_PKG 2>/dev/null | awk '\$2==\"$KERNEL_PKG\"{print \$3}'" | tr -d '\r')
note "kernel package" "${KPKG_OK:-ABSENT}"
[ -n "$KPKG_OK" ] || { warn "$KERNEL_PKG not installed - the boot partition would have no modules"; fails=$((fails+1)); }

ADBD_OK=$(dev "test -x $ADBD_BIN && echo present || echo MISSING" | tr -d '\r')
GC_OK=$(dev "command -v $GADGET_TOOL || echo MISSING" | tr -d '\r')
note "adbd / gc" "$ADBD_OK / $GC_OK"
echo "  adbd and gc are NOT dpkg-owned here, which is why adb is reported lost after a"
echo "  distro upgrade: the Mobian gadget script calls 'gc' and nothing provides it."

SSH_STATE=$(dev "echo -n \"svc=\$(systemctl is-active ssh) sock=\$(systemctl is-active ssh.socket) port22=\$(ss -ltn 2>/dev/null | grep -c ':22 ')\"" | tr -d '\r')
note "ssh (2nd door)" "$SSH_STATE"
case "$SSH_STATE" in
  *port22=[1-9]*)
    echo "  port 22 answers. Note: sshd here is SOCKET-activated, so 'systemctl is-active ssh'"
    echo "  reads inactive even while the port is served by pid 1 - test the port, not the service." ;;
  *) warn "port 22 is not listening ($SSH_STATE). Open the second door BEFORE the hop:"
     warn "  adb -s $ADB_SERIAL shell systemctl enable --now ssh.socket   (and set a root password)" ;;
esac

[ "$fails" = 0 ] || warn "$fails preflight warning(s) - read them before staging"

# ---------------------------------------------------------------- staging (writes, gated)
if [ -n "$TO" ]; then
  log "staging $TO (device writes need COMMIT=1)"
  devrun "cp -a /etc/apt/sources.list /etc/apt/sources.list.pre-$TO.bak"
  run "adb -s $ADB_SERIAL push config/sources-$TO.list"
  if [ "${COMMIT:-0}" = "1" ]; then
    adb_cmd push "$CONF/sources-$TO.list" /etc/apt/sources.list >/dev/null
    echo "  pushed config/sources-$TO.list -> /etc/apt/sources.list"
  fi
  # keep the vendor kernel out of apt's reach: it exists in no repository
  devrun "apt-mark hold $KERNEL_PKG >/dev/null && apt-mark manual $KERNEL_PKG >/dev/null && echo held"
  # free space + do not keep .debs around during the biggest unpack of the upgrade
  devrun "apt-get clean"
  devrun "printf 'APT::Clean-Install \"true\";\\nAPT::Get::Show-Upgrades \"true\";\\n' > /etc/apt/apt.conf.d/99openstick-small-disk"
  # the recovery door: installed but left DISABLED, because it and the Mobian unit both
  # own gadget g1. Enable it only from serial/ssh if adb stops answering.
  devrun "test -f /usr/sbin/usb-adb-gadget || echo 'install step pending'"
  if [ "${COMMIT:-0}" = "1" ]; then
    adb_cmd push "$ROOT/config/usb-adb-gadget.sh" /tmp/usb-adb-gadget >/dev/null
    adb_cmd push "$ROOT/config/usb-adb-gadget.service" /tmp/usb-adb-gadget.service >/dev/null
    dev "install -m755 /tmp/usb-adb-gadget /usr/sbin/usb-adb-gadget && install -m644 /tmp/usb-adb-gadget.service /etc/systemd/system/usb-adb-gadget.service && rm -f /tmp/usb-adb-gadget /tmp/usb-adb-gadget.service && systemctl daemon-reload && systemctl preset usb-adb-gadget.service 2>/dev/null; systemctl is-enabled usb-adb-gadget.service" | sed 's/^/  fallback unit: /'
  fi
  devrun "apt-get update"
fi

# ---------------------------------------------------------------- what you run, in order
log "upgrade commands (run these yourself in an interactive adb shell - TTY matters for the prompts)"
cat <<EOF
  adb -s $ADB_SERIAL shell -t

  # 0. extra swap on disk, sized to survive dpkg on 461 MB RAM. Skip if free space is tight:
  fallocate -l 512M /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile

  # 1. fetch everything first, unpack nothing
  apt-get update
  apt-get -o APT::Get::Download-Only=true full-upgrade

  # 2. minimal upgrade: updates apt/dpkg/systemd plumbing before the big move
  apt-get upgrade --without-new-pkgs

  # 3. the actual distribution hop - READ the removal list before typing y
  apt-get full-upgrade

  # 4. before rebooting: prove adb will still work, prove the kernel survived
  dpkg -l $KERNEL_PKG | tail -1
  free -m
  systemctl is-enabled mobian-usb-gadget.service
  ls -l $ADBD_BIN

  # 5. reboot and re-check from the host
  reboot
EOF

log "if adb does not come back"
cat <<'EOF'
  Order of doors, best to worst:
    1. ssh 10.42.0.1        (the stick runs sshd; it is a second root channel already)
    2. serial console       console=ttyMSM0,115200 is in the boot cmdline - the board's
                            UART gives you login even with the gadget dead
    3. systemctl enable --now usb-adb-gadget   (from either door; the fallback unit
                            installed above does not need gc/adbd packages)
  Do not flash anything to get adb back. Fix it as a service problem first.
EOF
