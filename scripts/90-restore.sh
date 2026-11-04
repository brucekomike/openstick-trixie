#!/usr/bin/env bash
# Undo. Everything this repo can put right, from backup/.
#
#   scripts/90-restore.sh boot        # put the stock boot partition back (safe, not mounted)
#   scripts/90-restore.sh verify      # check backup integrity only
#   scripts/90-restore.sh rootfs      # raw rootfs image back (needs fastboot/EDL, see below)
#   scripts/90-restore.sh files       # untar rootfs-files.tar.zst over the running system (LAST resort)
. "$(dirname "$0")/lib.sh"
require_backup boot-stock.bin

case "${1:-verify}" in
  verify)
    log "backup integrity"
    ( cd "$BACKUP" && sha256sum -c MANIFEST.sha256 ) 2>&1 | sed 's/^/  /'
    python3 "$ROOT/tools/bootimg.py" info "$BACKUP/boot-stock.bin" | sed 's/^/  boot-stock.bin: /'
    for f in lib-firmware.tar.zst kernel-boot.tar.zst usr-bin-adbd; do
      if [ -s "$BACKUP/$f" ]; then echo "  ok  $f"; else warn "missing $f"; fi
    done
    ;;
  boot)
    log "restoring the stock boot partition"
    dev "blockdev --getsize64 /dev/disk/by-partlabel/$BOOT_PARTLABEL" | tr -d '\r' |
      { read -r sz; echo "  partition $sz bytes, image $(stat -c %s "$BACKUP/boot-stock.bin") bytes"; }
    printf '  [stick] dd of=/dev/disk/by-partlabel/boot  <- backup/boot-stock.bin\n'
    if [ "${COMMIT:-0}" = "1" ]; then
      adb_cmd get-state 2>/dev/null | grep -q device || die "adb is not in 'device' state - use fastboot: fastboot flash boot backup/boot-stock.bin"
      cat "$BACKUP/boot-stock.bin" | adb_cmd exec-out "dd of=/dev/disk/by-partlabel/$BOOT_PARTLABEL bs=1M"
      echo "  verifying readback of the first MiB"
      adb_cmd exec-out "dd if=/dev/disk/by-partlabel/$BOOT_PARTLABEL bs=1M count=1 2>/dev/null" |
        cmp - <(head -c 1048576 "$BACKUP/boot-stock.bin") && echo "  matches - reboot to take effect: adb reboot" ||
        die "readback differs - do not reboot; retry the restore"
    else
      echo "  DRY RUN: rerun with COMMIT=1"
    fi
    ;;
  rootfs)
    die "Do not dd the rootfs while it is mounted. Boot into fastboot and use:
         fastboot flash rootfs backup/rootfs-raw.bin.gz   (fastboot handles sparse, not gzip)
         or unpack the file-level tar from a working system instead: 'files' below.
         If the stick will not boot at all, this is an EDL job: edl w rootfs rootfs.bin"
    ;;
  files)
    warn "This untars backup/rootfs-files.tar.zst over the LIVE rootfs - it restores the"
    warn "Debian 11 userspace in place and will leave partially-upgraded dpkg state."
    warn "Use it only when the stick still boots and adb still works."
    require_backup rootfs-files.tar.zst
    devrun "mv / /old-$(date -u +%s) 2>/dev/null; mkdir -p /newroot"
    echo "  the safe form of this is: boot from the stock rootfs, then restore only the"
    echo "  packages apt damaged - 'apt-get install --reinstall' beats a file-level undo."
    if [ "${COMMIT:-0}" = "1" ]; then
      zstd -dc "$BACKUP/rootfs-files.tar.zst" | adb_cmd exec-out "tar -C / -xpzf - 2>/dev/null"
      echo "  files restored; run: dpkg --configure -a && apt-get -f install"
    fi
    ;;
  *) die "usage: $0 {verify|boot|rootfs|files}" ;;
esac
