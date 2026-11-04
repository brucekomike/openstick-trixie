# Execution plan — Debian 13 on the UFI103s, step by step

Each step says what a good result looks like, so one line of output tells you whether to
continue. Steps 1–4 are read-only on the stick. Nothing after step 4 is destructive until
step 9.

## 1. Host prerequisites
```sh
scripts/00-host-check.sh
```
*Route A expects `ready: adb + python3 + sha256sum present`.* Anything under "route B" being
missing is fine for now. Note the docker line: `NO: exec format error` means arm64 containers
can't exec yet — only blocks route B.

## 2. Pin the upstream toolchain
```sh
scripts/05-fetch-vendor.sh && scripts/06-vendor-fixup.sh
```
*Expect `vendor.lock` with commit `5724497…`, `patched scripts/setup.sh`, and the warning list.*
The fixup output also names the two builder steps that **rewrite the GPT** — never run those on
this stick until step 9 proves a recovery path.

## 3. Snapshot + back up (the step that makes everything else safe)
```sh
scripts/10-snapshot.sh
scripts/20-backup.sh
```
*Expect in `backup/`: `boot-stock.bin` (67108864 bytes), `part-{sbl1,rpm,tz,hyp,aboot,modemst1,modemst2,fsg,fsc,…}.bin`
each printing `want N got N bytes` + `md5 verified`, `lib-firmware.tar.zst`, `kernel-boot.tar.zst`,
`usr-bin-adbd`, `MANIFEST.sha256`, and finally a decoded boot header
(`cmdline earlycon root=PARTUUID=a7ab80e8-e9d1-e8cd-f157-93f69b1d141e console=ttyMSM0,115200 …`).*

Measured on this stick, so the timing is not a surprise: `adb exec-out` is broken on this
`adbd` (`error: closed`), so every binary is written to `/var/tmp/openstick-stage.*` on the
stick, pulled with `adb pull`, and compared by md5 (device-side `dd` runs at ~60 MB/s; the
pull over adb is the slow part). The step-by-step file-level rootfs archive is the long one —
about ten minutes. There is no `/data/local/tmp` here: that path is Android, not Debian.

- Any `size mismatch` / `md5 mismatch` / `did not back up` line → stop, re-run that partition.
- `usr-bin-gc … absent` is fine only if you plan to use the configfs fallback unit.
- `boot` is the one you must never lose: it is the only copy of a working kernel+DTB for this board.

## 4. Verify the backup is usable
```sh
scripts/90-restore.sh verify
python3 tools/bootimg.py unpack backup/boot-stock.bin out/bootimg && ls -l out/bootimg
```
*Expect every sha256 line `OK`, and `split kernel blob: payload=… dtb=… -> dtb0.dtb`.*
If no FDT is found inside the kernel blob, stop and re-read the header — the assumption that
the DTB is appended to the kernel would be wrong, and route C changes shape.

## 5. Internet for the stick
```sh
scripts/30-net-up.sh          # prints the sudo lines; run them yourself
COMMIT=1 scripts/30-net-up.sh # applies the stick-side route and tests it
```
*Expect `ok: 10.42.0.1 answers`, then on the stick `0% packet loss` for 1.1.1.1 and the mirror.*
Ping to the mirror failing while 1.1.1.1 works = DNS; add `nameserver 1.1.1.1` (the script does).

## 6. Prove the recovery doors before changing anything (needs your hands)
```sh
ssh root@10.42.0.1                 # door 2 - set a root password first if needed
adb reboot bootloader; fastboot devices
```
*`fastboot devices` listing a serial ⇒ aboot exposes fastboot, which makes route B/C reversible.*
If it hangs with no adb and no fastboot, power-cycle; the stick should come back. If it does not
come back, you need EDL (`adb reboot edl`, then `lsusb | grep 05c6:9008`) — **do not proceed to
step 9 until one of fastboot/EDL is confirmed**, because that is the only way to restore a
`rootfs` partition.

## 7. Stage the hop (kernel protected, fallback gadget installed)
```sh
COMMIT=1 scripts/40-inplace-upgrade.sh --to bookworm
```
*Expect `current release on stick: bullseye; target: bookworm`, preflight lines with no
`xx`, `held` for `linux-image-5.15.0-jsbsbxjxh66+`, `usb-adb-gadget.service` installed and
reporting `disabled`, and the apt sequence printed.*

A preflight warning about free space is real: a full dist hop wants ~1.5 GB of the 3.3 GB
partition, of which 2.2 GB is free today.

## 8. Run the upgrade itself (interactive, in your terminal)
```sh
adb -s 0123456789 shell -t
  fallocate -l 512M /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  apt-get update
  apt-get -o APT::Get::Download-Only=true full-upgrade   # download only
  apt-get upgrade --without-new-pkgs
  apt-get full-upgrade                                   # READ the removal list
  dpkg -l linux-image-5.15.0-jsbsbxjxh66+ | tail -1      # must still be installed
  free -m; systemctl is-enabled mobian-usb-gadget; ls -l /usr/bin/adbd
  swapoff /swapfile; rm /swapfile
  reboot
```
*Good result: after ~60 s `adb devices` lists the stick again and `/etc/os-release` says
bookworm, kernel unchanged.* Then repeat 7–8 with `--to trixie`.

Interpretation guide:
- `apt full-upgrade` proposes removing `linux-image-5.15.0-jsbsbxjxh66+` → **abort** (`n`);
  that package is in no repo, and without it the boot partition has no modules.
- adb disappears at reboot but `ssh 10.42.0.1` works → expected `gc`/adbd casualty. Fix as a
  service problem: `systemctl disable mobian-usb-gadget; systemctl enable --now usb-adb-gadget`.
- Neither adb nor ssh works → serial console on `ttyMSM0` 115200, then `scripts/90-restore.sh`
  is not needed: the rootfs is still Debian, this is a gadget unit problem.

## 9. Only if you want a clean image instead (route B/C)
```sh
COMMIT=1 TARGET=trixie scripts/50-build-rootfs.sh     # needs arm64 binfmt
scripts/60-build-bootimg.sh repack --kernel <Image.gz> --dtb out/bootimg/dtb0.dtb
scripts/70-flash.sh boot                              # COMMIT=1, reads back 1 MiB
```
*Stop before this unless step 6 confirmed fastboot or EDL.* Flashing `rootfs` also needs
`I_WIPE_ROOTFS=yes` and is refused in-place by design, since that partition is mounted as `/`.
