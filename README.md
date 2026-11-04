# OpenStick UFI103s → Debian 13 (trixie) toolchain

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
| boot chain | LK/**aboot**, **no UEFI**; `boot` = Android header **v0**, page_size 2048, kernel 9,501,009 B **with appended DTB**, ramdisk 6,644,810 B, cmdline `earlycon root=PARTUUID=… console=ttyMSM0,115200 no_framebuffer=true rw` |
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
* Order of doors if adb disappears: `ssh 10.42.0.1` (sshd is enabled) → serial console
  (`console=ttyMSM0,115200` is on the kernel cmdline) → `systemctl enable --now usb-adb-gadget`.

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
| `scripts/70-flash.sh` | the only partition writer; dry-run by default; refuses calibration labels |
| `scripts/90-restore.sh` | `verify` / restore `boot` / guarded rootfs paths |

`make help` lists the same thing.

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

## Status of this directory

Verified by running: `00-host-check.sh`, `05-fetch-vendor.sh`, `06-vendor-fixup.sh`,
`10-snapshot.sh`, `20-backup.sh` (device side read-only), `bootimg.py info/unpack`.
**Not yet run / unproven:** `50-build-rootfs.sh` (needs binfmt for arm64 containers, which
this host currently lacks), `60-build-bootimg.sh repack` (needs a newer kernel binary),
`70-flash.sh` (never executed — fastboot/EDL entry on this stick is still untested, so the
recovery path is not yet proven), and the apt upgrade itself.

Rollback story, stated honestly: `backup/boot-stock.bin` restores the kernel/boot path, and
`backup/rootfs-files.tar.zst` is a file-level snapshot of Debian 11. A *clean* rootfs rollback
needs either fastboot or EDL, and neither has been confirmed reachable on this stick yet —
test that **before** touching `rootfs`.

`backup/`, `notes/`, `out/`, `vendor/` are gitignored: the dumps contain IMEI-bearing
partitions and vendor binaries.
