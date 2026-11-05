# OpenStick UFI103s → Debian 13 (trixie) toolchain

> **Two boards answer the same adb serial.** Everything below was measured on the stick whose DT
> model says *UFI103s*, which is still stock (vendor 5.15 + Debian 11). A second unit (*UFI001C*,
> `androidboot.serialno=<serial-001c>`) is the one that has actually been reflashed and now runs
> **Alpine v3.24 + mainline `6.12.1-msm8916`**; it differs where it matters — its *factory* aboot
> had no `extlinux` support (replaced by the community one), its DTB is different, and its LTE
> modem only probes under the community DTB, not the stock one. Read
> **[`BOARD-ufi001c.md`](BOARD-ufi001c.md)** first — `adb devices` shows the identical
> `0123456789` for both, so nothing else in this repo tells you which board is plugged in.
> Every script takes `BACKUP=` and `BOARD_ENV=` for that reason, and `require_board` in
> `scripts/lib.sh` refuses to run when the live device, the env file and the backup tree
> disagree. This stick's tree is `backup-ufi103s/`; `backup/` is the UFI001C's.

Prepares the Debian 13 route for the MSM8916 / Snapdragon 410C-class stick that shows up
on adb as `0123456789` (`occam/Nexus_4/mako` placeholder strings). Nothing here writes to
the stick unless you pass `COMMIT=1`, and the one script that can flash raw partitions
additionally needs `I_WIPE_ROOTFS=yes`.

## What the hardware actually is (measured 2026-11-04 over adb, not from docs)

| | |
|---|---|
| board | `compatible = "handsome,openstick", "qcom,msm8916"`, model *Handsome OpenStick jsbsbxjxh66-bianyi UFI103s* |
| CPU | 4× Cortex-A53 (0xd03), ARMv8.0, aarch64, 4 KB pages, `CONFIG_COMPAT=y` |
| RAM | **461 MB** total, 387 MB available, zram0 230 MB swap |
| storage | 3.64 GiB eMMC `H4G2a`; GPT: `sbl1 rpm tz hyp sec cdt modemst1 modemst2 boot(64M) rootfs(3.3G) fsc devinfo aboot(1M) fsg` |
| boot chain | **lk1st + qhypstub**, **no UEFI**. Two aboot builds exist and they behave differently — see `BOARD-ufi001c.md` §3. The **factory** one (`backup/part-aboot.bin`, `LK1ST_MSM8916`, `version: 0.5` / `version-special: qhypstub 0.3-r3`) has **no `extlinux` string at all** and only boots a raw Android image or a file named `boot.img` inside an ext2 `boot`; it also refuses a mainline arm64 kernel (5 flash cycles, one byte-identical no-op control that booted). The **community** one (`vendor/openstick-alpine-v0.2/aboot.mbn`, `lk1st-msm8916`, `Failed to parse extlinux.conf`) boots ext2 + `extlinux.conf` and runs **`6.12.1-msm8916`** on this board. `boot` header: Android **v0**, page_size 2048, kernel with appended DTB. **Correction (2026-11-05): the earlier claim "lk2nd also accepts extlinux.conf, so a newer kernel needs only a `boot` swap" was true of the community aboot and false of the factory one, and this repo never said which was installed** |
| kernel | `5.15.0-jsbsbxjxh66+`, packaged as `…-10.00.Custom` — **exists in no repository** |
| userland | Debian 11 (glibc 2.31, systemd 247) with Mobian config services |
| radio | `remoteproc a204000` running, `qrtr-ns`, `rmtfs`, ModemManager, wcn36xx over smd-edge. **There is no `modem` partition** — the modem/DSP blobs are `/lib/firmware` files (~46 MB) |

## Second trap: the adb transport itself

Measured: this `adbd` build answers **`adb exec-out` with `error: closed`** — no raw binary
stream is available, and `adb shell` goes through a PTY that rewrites bytes (`\n` → `\r\n`).
So a `dd ... | ssh-style pipe` backup would have been silently corrupt, and it is the reason
`20-backup.sh` stages every binary on the stick (`/data/local/tmp`) and moves it with
`adb pull`. `scripts/lib.sh` probes exec-out once per run and falls back to `adb shell` for
text only.

## Why the route is "userspace only"

Two hard constraints, both measured:

1. **No UEFI/uboot.** No distro installer or cloud image can be used as-is: Debian 13 arm64
   documents 512 MB minimum / 640 MB for the graphical installer, and this stick has 461 MB
   *and* no way to boot a d-i. Everything must arrive as `boot.img` + rootfs partition.
2. **No device tree for this board.** `handsome/openstick/uz801/ufi/zhihe` appear **nowhere**
   in the 47 msm8916 DTs in `torvalds/linux` master, and the community kernel's release branch
   (`msm8916-mainline/linux`, default `wip/msm8916/7.0`) only carries `thwc-uf896`,
   `thwc-ufi001c`, `yiming-uz801v3`. A `handsome-openstick` dtsi exists only on a WIP branch.

So the only device tree guaranteed to match this hardware is the one already inside the stock
`boot` partition. **Route A keeps the stock kernel and boot.img and upgrades only the
userspace** — that is the whole design decision. Route B (new rootfs image) also keeps the
stock boot.img and copies the 5.15 modules + firmware in. Route C (newer kernel) is prepared
but explicitly experimental, because a 5.15-era FDT is not guaranteed to bind to a 6.x kernel.

## The trap that makes or breaks this

`adbd` is `/usr/bin/adbd` (2022 build, owned by **no dpkg package**) and
`/usr/sbin/mobian-usb-gadget` builds the gadget by calling `gc` (gadget-tools, also not a
Debian package). After a distribution upgrade — or in a fresh rootfs — `gc` is gone, the
gadget unit fails, and **you lose adb on a headless stick**. This is exactly what the public
trixie reports describe.

Countermeasures in this repo:
* `config/usb-adb-gadget.sh` + `.service` — configfs-only RNDIS+ADB bring-up, no `gc`, no
  libusbgx; installed by the staging step **disabled** (it and the Mobian unit both own `g1`).
* `20-backup.sh` copies `adbd`, `gc` and the Mobian script out of the running rootfs.
* Order of doors if adb disappears: `ssh root@10.42.0.1` → serial console
  (`console=ttyMSM0,115200` is on the kernel cmdline) → `systemctl enable --now usb-adb-gadget`.
  Verified on this stick: ssh is **socket-activated**, so `systemctl is-active ssh` reports
  `inactive` while `ssh.socket` is active and pid 1 holds `*:22` in LISTEN — probe the port
  (`ss -ltn | grep ':22 '`, or from the host `/dev/tcp/10.42.0.1/22`), not the service name,
  or you will conclude the wrong thing and go quiet on a headless board.

## Scripts

| run | effect |
|---|---|
| `scripts/00-host-check.sh` | host prerequisites; prints the one `sudo apt install` line (never sudo itself) |
| `scripts/05-fetch-vendor.sh` | shallow-clones + pins `kinsamanka/OpenStick-Builder` → `vendor.lock` |
| `scripts/06-vendor-fixup.sh` | trixie `libconfig9→libconfig11` patch, board-target deltas, lists the builder steps that **repartition eMMC** (do not run those) |
| `scripts/10-snapshot.sh` | read-only dump of the stick into `notes/` |
| `scripts/20-backup.sh` | `boot` partition exact, firmware+calibration partitions, `/lib/firmware`, `/lib/modules`+`/boot`, `adbd`/`gc`, manifest; `--rootfs` for the raw image |
| `scripts/30-net-up.sh` | internet for the stick via USB-gadget NAT (`--down` to revert) |
| `scripts/40-inplace-upgrade.sh` | **route A**: preflight, then stage bookworm/trixie with the kernel held and the fallback unit installed |
| `scripts/50-build-rootfs.sh` | **route B**: docker/debootstrap trixie rootfs + firmware + 5.15 modules + gadget unit → `out/rootfs-trixie.img` |
| `scripts/60-build-bootimg.sh` | `info`/`unpack`/`repack` the Android boot image (`tools/bootimg.py`, stdlib only) |
| `scripts/66-make-extlinux-boot.sh` | build the 64 MiB ext2 `boot` image lk2nd reads, packing **this board's own DTB** (`DTS-DIFF-ufi001c.md` explains why not `thwc-ufi001c`) |
| `scripts/70-flash.sh` | the only partition writer; dry-run by default; refuses calibration labels |
| `scripts/90-restore.sh` | `verify` / restore `boot` / guarded rootfs paths |

`make help` lists the same thing.

## Alternative distro: Alpine

`ALPINE.md` assesses the builder's `alpine` branch (Alpine v3.24 + a postmarketOS v25.12
overlay, `linux-postmarketos-qcom-msm8916` and `msm-firmware-loader` as **apk packages**,
OpenRC, and **dropbear over NCM** instead of adb). Conclusion there: Alpine is maintained in
lockstep with the Debian branch and is the lighter, better-kernel-maintained option, but it is
the **destructive** route — lk2nd + a rewritten GPT + a non-Android ext2 boot partition — so it
cannot be attempted the way route A can. Same unresolved DTB problem for `handsome,openstick`,
which the extracted `out/bootimg/dtb0.dtb` is the asset for.

## Quickstart

```sh
make check vendor snapshot backup     # host + read-only device work
# then, from your own terminal (host NAT needs your password, apt needs a TTY):
scripts/30-net-up.sh                  # read, run the printed sudo lines
COMMIT=1 scripts/30-net-up.sh         # apply the stick-side route
COMMIT=1 scripts/40-inplace-upgrade.sh --to bookworm
#   … run the printed apt sequence in `adb shell -t`, reboot, verify
COMMIT=1 scripts/40-inplace-upgrade.sh --to trixie
```

## What the backup proved about the boot image

`20-backup.sh` pulled the `boot` partition (67,108,864 bytes, md5-verified against the
device's own md5) and `tools/bootimg.py unpack` then split it for real:

| part | measured | note |
|---|---|---|
| kernel payload | 9,451,356 B gzip → 22,726,664 B | matches `/boot/vmlinuz-5.15.0-jsbsbxjxh66+` |
| appended DTB | 49,653 B, `out/bootimg/dtb0.dtb` sha256 `2730cc4b…` | strings carry *"Handsome OpenStick jsbsbxjxh66-bianyi UFI103s"* and `handsome,openstick` + `qcom,msm8916` |
| ramdisk | 6,644,810 B gzip → 15,644,160 B | `mkinitramfs-MAIN_Uzpm4Y`, dated **2022-12-10** |
| header | `page_size 2048`, `second_size 0`, `dtb_size field 0` | so `repack`'s stage2 guard does not trip on this image |
| cmdline | `earlycon root=PARTUUID=a7ab80e8-e9d1-e8cd-f157-93f69b1d141e console=ttyMSM0,115200 no_framebuffer=true rw` | identical to `/proc/cmdline` minus the `androidboot.*` tags aboot appends |

Two consequences that matter for the plan:

* The **DTB is now a file**, so route C (`60-build-bootimg.sh repack --dtb out/bootimg/dtb0.dtb`)
  is a concrete thing rather than a guess — still experimental for the 5.15-FDT-on-6.x-kernel
  reason stated above, but no longer blocked on "where do we get a DTB".
* The initrd is a plain Debian `mkinitramfs`, and all it has to do is find
  `root=PARTUUID=…` and mount ext4. It does not care that the userspace underneath it became
  trixie, which is exactly why the userspace-only route does not need a new initrd at all.

## Status of this directory

**Proven by running it** on 2026-11-04:
* `make test` — 7/7 boot-image round-trip tests pass, every script parses (`bash -n`).
* `00-host-check.sh`, `05-fetch-vendor.sh` (pin `5724497`), `06-vendor-fixup.sh`,
  `10-snapshot.sh` (18 files in `notes/`), `20-backup.sh`, `90-restore.sh verify`.
* `20-backup.sh` end to end: `boot-stock.bin` = 67,108,864 B exactly, every firmware and
  calibration partition matched its `blockdev` size **and** its device-side md5, `/lib/firmware`
  (25 MB zst) and `/lib/modules`+`/boot` (20 MB zst) pulled, `adbd` + `gc` confirmed valid
  aarch64 ELF and the Mobian script confirmed as a shell script, rootfs file-level archive
  272 MB, device scratch left clean, `MANIFEST.sha256` written, and `bootimg.py info/unpack`
  decoded the real image.
* Three bugs that only a real run would show, now fixed: `adb exec-out` unsupported by this
  adbd, `df -BG` GiB-vs-MB unit confusion in the preflight, and `local name=$2 tmp=…$name`
  expanding `$name` before it was assigned.

**Not yet run / unproven:**
* `50-build-rootfs.sh` — needs arm64 binfmt for docker, which this host lacks today
  (`docker run --platform linux/arm64` gives `exec format error`).
* `60-build-bootimg.sh repack` — the tool is unit-tested and the stock DTB is extracted, but no
  newer kernel binary has been fed through it, and a 5.15-era FDT on a 6.x kernel is unverified.
* `70-flash.sh` — never executed. **fastboot and EDL entry on this stick are still unconfirmed**,
  so the rootfs rollback path is not yet proven. Test that (PLAN step 6) before flashing anything
  but `boot`.
* The apt upgrade itself, and the configfs fallback unit on a live trixie system.

Rollback story, stated honestly: `backup/boot-stock.bin` restores the kernel/boot path and is
md5-verified; `backup/rootfs-files.tar.zst` is a file-level snapshot of Debian 11 (not a
partition image). A *clean* rootfs rollback needs either fastboot (`fastboot flash rootfs`,
sparse-aware) or EDL (`edl w rootfs …`), and neither has been confirmed reachable on this stick
yet.

`backup/`, `notes/`, `out/`, `vendor/` are gitignored: the dumps contain IMEI-bearing
partitions and vendor binaries.
