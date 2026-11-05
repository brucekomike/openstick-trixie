# Alpine as an alternative to Debian on this stick

> **Superseded in part — read this first.** The Alpine route was executed on the UFI001C on
> 2026-11-05, and it needed one thing this assessment did not anticipate: **a bootloader swap**.
> This unit's *factory* aboot has **no `extlinux.conf` support** (`grep -c extlinux` = 0), so the
> ext2 `boot.raw` the builder produces does not boot on it and `scripts/66-make-extlinux-boot.sh`
> is unusable there. Flashing OpenStick-Builder v0.2's community `aboot.mbn` + `hyp.mbn` fixes
> exactly that, and afterwards ext2 + `extlinux.conf` and the **pmOS `6.12.1-msm8916`** kernel both
> work. `sbl1`/`rpm`/`tz` were never touched. Alpine can also run on the *stock vendor 5.15* kernel
> from the untouched stock Android `boot` partition, which is the reversible first rung and needs
> no bootloader change at all. Details, evidence and the five flash/boot cycles (including the
> byte-identical no-op control that separated the bootloader from the kernel as the cause):
> [`BOARD-ufi001c.md`](BOARD-ufi001c.md) §3–§5.

Assessment asked for after the Debian route was prepared, because Debian support on these
MSM8916 sticks is community images rather than an official distro port. Short answer:
**Debian is still the mainstream choice in practice, but the Alpine route is real, maintained
in lockstep with the Debian one, and arguably the cleaner long-term base — at the cost of
being the destructive route.**

Evidence read directly from `kinsamanka/OpenStick-Builder`, branch `alpine`
(tip `61c375d64f13ff828cca3978f57dbe1c3c1c3454`; both branches' last commit:
`2026-08-06T08:16:58Z "Fix for missing Qualcomm firmware"`).
The `main` branch pin lives in `vendor.lock`; the `alpine` branch is **not** cloned here —
`scripts/05-fetch-vendor.sh` pins only `main`, so fetch it explicitly if you go this way.

## What the alpine branch actually builds

From `scripts/alpine_rootfs.sh`:

| | |
|---|---|
| base | Alpine **v3.24** `main` + `community`, plus a postmarketOS overlay `@pmos` for **v25.12** |
| bootstrap | `apk.static` (v3.0.6) `add --initdb -U --arch aarch64 --allow-untrusted alpine-base`, cross-exec via `qemu-aarch64-static` in the chroot |
| kernel | `linux-postmarketos-qcom-msm8916@pmos` — installed **as a package**, not hand-assembled |
| radio support | `msm-firmware-loader@pmos`, `rmtfs`, `modemmanager`, `qrtr` tooling |
| init | **OpenRC** + `eudev`, `dbus`, `shadow` |
| admin | **`dropbear`** (ssh) — and no `adbd` at all |
| gadget | `gadget-tool` + `scripts/setup_ncm_gadget.sh`: **NCM** (not RNDIS), VID `0x1d6b` / PID `0x0104`, fixed host/dev MACs, `MSFT100` OS descriptors so Windows auto-loads |

From `scripts/build_images.sh`, the image shapes:

* `boot.raw` = **64 MiB ext2**, populated by extracting `./boot` out of the rootfs tarball
  (`--exclude=./boot/linux.efi`) → lk2nd reads `extlinux.conf` from a filesystem, exactly like
  u-boot/depthcharge. **This is not an Android `boot.img`.**
* `rootfs.raw` = **1.5 GiB ext4**, then `img2simg` → sparse Android images
  (`files/alpine_rootfs.bin`, `files/boot.bin`).

## Why that matters for *this* stick

1. **It replaces the boot chain.** `build_hyp_aboot.sh` builds lk2nd + qhypstub,
   `extract_fw.sh` rewrites the GPT, and the README flashes `partition/aboot/hyp/rpm/sbl1/tz`
   before `boot`/`rootfs`. That is the path our `06-vendor-fixup.sh` explicitly warns about: it
   destroys the vendor layout that `backup/part-*.bin` is the only undo for. So Alpine cannot be
   tried in place the way Debian trixie can — **PLAN step 6 (fastboot/EDL confirmed reachable) is a
   hard prerequisite, not a suggestion.**
2. **The DTB question does not go away.** Alpine uses the same postmarketOS kernel as the Debian
   route, and the builder still defaults to `yiming-uz801v3` with only `fy-mf800`/`jz01-45-v33`
   DTBs shipped in `dtbs/`. I could not confirm whether
   `linux-postmarketos-qcom-msm8916` carries a `msm8916-handsome-openstick*.dtb`: the pmOS package
   file-list pages never surfaced any `/dtb` entries at all (a `file=dtb` query returned
   "No matching files found"), which means either the DTBs live in a subpackage I did not reach or
   the query interface was not showing them. **Treat "the Alpine/pmOS kernel has this board's DTB"
   as unverified.**
   The asset that settles it is already in this repo: `out/bootimg/dtb0.dtb` (49,653 B,
   sha256 `2730cc4b…`) is the *stock* DTB, extracted from the working boot partition. Dropping it
   onto the ext2 `boot` and pointing `extlinux.conf`/`fdt` at it avoids borrowing
   `thwc-ufi001c` and its wrong-GPIO risk.
3. **musl and OpenRC are real frictions.** Anything expecting glibc or systemd breaks: Docker and
   prebuilt-agent tarballs, Node native addons, `systemd-`-coupled units, and the Mobian services
   this stick's current image depends on. Conversely, Alpine is dramatically lighter — which on
   **461 MB RAM** is not cosmetic: `alpine-base` + dropbear + ModemManager leaves far more headroom
   than a Debian hop that needs a temporary swapfile just to survive `dpkg`.
4. **Rootfs sizing.** Their 1.5 GiB image against this board's 3.3 GiB `rootfs` partition means
   `resize2fs /dev/disk/by-partlabel/rootfs` after first boot (same as the Debian route).

## Verdict

| | Debian 13 (route A, prepared) | Alpine (alpine branch) |
|---|---|---|
| fits this stick's boot chain | **yes**, keeps vendor boot.img + stock DTB | no — needs lk2nd + new GPT |
| flashing required | none | full reflash; EDL/fastboot must be proven first |
| rollback | `backup/boot-stock.bin` + untouched rootfs | only `backup/part-*.bin` + EDL |
| kernel maintenance | vendor 5.15 forever, unless route C is built | **apk upgrade from the pmOS repo** |
| modem stack | rmtfs/qrtr already running | packaged (`rmtfs`, `msm-firmware-loader@pmos`) |
| admin channel | adb (un-packaged `adbd` + `gc` = the trap) | **dropbear over NCM** — no adb dependency at all |
| RAM/flash fit | tight; needs swapfile during the hop | comfortable |
| continuity with current image | same lineage (Mobian/Debian) | new libc + new init |
| published experience here | the majority of reports | mostly postmarketOS write-ups, and those report building custom firmware partitions and boot-partition size fights |

So: **keep Debian trixie as the route you execute**, and keep Alpine as the better *end state* if
you decide to reflash anyway — its two genuine advantages here are a kernel that is a package from
the tree that maintains these DTs, and an ssh/NCM admin path that never depends on the un-packaged
`adbd`/`gc` pair that makes adb vanish on Debian.

### Update after reading the backed-up bootloaders and openstick.de

The table above framed Alpine as "replaces the boot chain". That framing was wrong for this
device, in two ways:

* `part-aboot.bin` contains lk2nd (`lk2nd_skip`, `/mnt/lk2nd_rproc_mode`, `app/aboot/fastboot.c`)
  and `part-hyp.bin` contains `qhypstub` — the bootloader work `build_hyp_aboot.sh` does is
  **already done on this stick**.
* https://www.openstick.de/referenz-en.html describes the platform's bootloader as
  "lk2nd / lk1st (modified, supports an `extlinux.conf` similar to u-boot); fastboot stays
  usable", and its kernel as `msm8916-mainline` with "many images ship prebuilt postmarketOS
  kernels (6.6+)", listing Debian (Bullseye/Bookworm), **Alpine**, postmarketOS and OpenWrt
  (HandsomeMod) as the operating systems in use. It also states "OpenStick v1" = the original
  **Debian Bullseye images by HandsomeYingyan** — which is precisely this board's `compatible =
  "handsome,openstick"` and localversion `jsbsbxjxh66`.

Consequence: the only genuinely destructive step left in the Alpine flow is `extract_fw.sh`'s GPT
rewrite — and this stick's layout (its root PARTUUID equals the one committed in the builder's own
`extlinux.conf`) suggests that tooling already ran once here. A newer kernel therefore needs only a
`boot` + `rootfs` flash, and `scripts/66-make-extlinux-boot.sh` already produces a `boot` image that
keeps **this board's own DTB** rather than borrowing `thwc-ufi001c`.

## If you choose it, in order

```sh
git clone -b alpine --recurse-submodules https://github.com/kinsamanka/OpenStick-Builder.git
cd OpenStick-Builder
sudo scripts/install_deps.sh            # host pkgs incl. qemu-user-static
sudo scripts/build_hyp_aboot.sh         # lk2nd + qhypstub
sudo scripts/extract_fw.sh              # REWRITES THE GPT - backups must exist first
sudo scripts/alpine_rootfs.sh
sudo scripts/build_images.sh
# flash: partition/aboot/hyp/rpm/sbl1/tz, then boot.bin + alpine_rootfs.bin
# restore afterwards, exactly as the builder's README demands:
#   fsc fsg modem modemst1 modemst2 persist sec  <- from backup/part-*.bin
```
Before `fdt` in `extlinux.conf`, put `out/bootimg/dtb0.dtb` on the ext2 boot image instead of
`qcom/msm8916-yiming-uz801v3.dtb`, and keep `backup/` until Alpine boots and the modem registers.

Note the builder's own README warns these flashes "can potentially brick your device", and its
backup list expects a `modem` partition — this stick has none (the blobs are `/lib/firmware`
files, already archived as `backup/lib-firmware.tar.zst`), so that list must be adjusted for
this board.
