# OpenStick → Alpine / Debian 13 toolchain for the Handsome MSM8916 sticks

> **This project supports both boards, as separate targets.** `adb devices` shows the identical
> `0123456789` for both, so nothing in the transport tells you which stick is plugged in — each
> board has its own env file, backup tree, build artifacts and flash pack, and every script picks
> them by `BOARD_ENV=`/`BACKUP=`. `require_board` in `scripts/lib.sh` refuses to run when the live
> device, the env file and the backup tree disagree, and `scripts/78-flash-over-edl.sh` refuses to
> write over EDL at all until it has read the board's own `boot` partition and matched the model
> string in it.
>
> | | UFI103s | UFI001C |
> |---|---|---|
> | board file | **[`BOARD-ufi103s.md`](BOARD-ufi103s.md)** | **[`BOARD-ufi001c.md`](BOARD-ufi001c.md)** |
> | env | `config/board-ufi103s.env` (default) | `config/board-ufi001c.env` |
> | backup tree | `backup-ufi103s/` | `backup/` |
> | DTB (stock) | `2730cc4bae81…` | `33cad00d7e84…` |
> | how its images were built | `53-build-alpine-cross.sh` (offline, host container — its Wi-Fi will not associate) | `54-build-alpine-onstick.sh` (native, on the stick) |
> | artifacts | `out/*-ufi103s.img`, `out/cross-ufi103s/` | `out/alpine-rootfs.img`, `out/boot-mainline.img` |
> | flash pack | `out/flashpack/openstick-flashpack-ufi103s-*` | `out/flashpack/openstick-flashpack-ufi001c-*` |
> | state | community `aboot`+`hyp`, 6.12 `boot`, Alpine `rootfs` — all written and read back byte-exact over EDL; **first cold boot not yet observed** | runs Alpine v3.24 + mainline `6.12.1-msm8916`, boot chain proven |
>
> They differ where it matters: different DTB, different per-unit serial, different download-door
> behaviour (see §2 of the board files), and the UFI001C's LTE only probes under the community DTB.
> Read the board file for the unit in front of you before flashing anything.

**Repo version: [`VERSION`](VERSION) — `v0.1`**, and every flash pack carries it in its
directory name (`openstick-flashpack-<board>-v0.1-<kernel>-<toolset>-<date>`) so a published
artifact says which release and which toolset it is. `minimal` / `full` are the two toolsets
described in the feature list below; they are not versions.

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
| `scripts/54-build-alpine-onstick.sh` | **route D**: build Alpine natively *on the stick* (no qemu/binfmt/host sudo), pull `out/alpine-{rootfs,boot}.img`; refuses to build unless the backup's DTB matches the live model tag |
| `scripts/53-build-alpine-cross.sh` | the same build, **cross** in a container, for a stick with no internet: stages `/lib/firmware`, the 5.15 modules, `/boot` and the stock DTB out of `backup-<board>/`, runs `device/alpine-onstick.sh` unchanged under arm64 emulation, and refuses images with ext4 features the vendor kernel cannot mount |
| `scripts/55-patch-alpine-image.sh` | patch a built image with debugfs before flashing: configfs gadget, ACM console, and the adb payload; refuses an image without `gcompat` |
| `scripts/60-build-bootimg.sh` | `info`/`unpack`/`repack` the Android boot image (`tools/bootimg.py`, stdlib only) |
| `scripts/66-make-extlinux-boot.sh` | **superseded by `68-`** — the factory aboot has no extlinux parser at all, so this image cannot boot without the aboot swap |
| `scripts/68-make-mainline-boot.sh` | build the 64 MiB ext2 + `extlinux.conf` boot image for a mainline kernel, packing both the community DTB and this board's own |
| `scripts/70-flash.sh` | the only partition writer; dry-run by default; refuses calibration labels |
| `scripts/72-enter-fastboot.sh` | get into fastboot from a running system with no hands: `reboot(2)` `RESTART2 "bootloader"` over ssh (~4 s) |
| `scripts/74-flash-mainline-bootchain.sh` | `status`/`aboot`/`boot`/`all`/`restore` — flash the community `aboot`+`hyp`, then the ext2 boot image; `restore` returns every partition it can write to factory |
| `scripts/78-flash-over-edl.sh` | `status`/`w`/`verify`/`reboot` over EDL (Sahara + the db410c firehose): the door that works when the installed userspace does not boot, and the only one that can **read a partition back** to prove a write. Identifies the board from its own `boot` partition, since QDL mode has no serial |
| `scripts/76-fetch-adbd-payload.sh` | assemble + verify `out/adbd-payload/` (vendor `adbd` + `libcrypto.so.1.1`), the three files that give a musl rootfs a root `adb shell` |
| `scripts/80-build-flashpack.sh` | assemble `out/flashpack/`: a self-contained install pack (images + `flash.sh` + `restore.sh` + `MANIFEST.sha256` + `INSTALL.md`) that needs nothing from this repo on the flashing host; `--build` reruns 54/76/55/68 first, `--tar` emits a `.tar.zst` |
| `scripts/90-restore.sh` | `verify` / restore `boot` / guarded rootfs paths |

`make help` lists the same thing. Every script also takes `BACKUP=` and `BOARD_ENV=`, because the two
boards' partition dumps are not interchangeable — `scripts/lib.sh`'s `require_board` refuses to run
when the live DT model, the env file and the backup tree disagree, and pins every fastboot call to
that board's serial.

## Feature list

Availability = measured on real hardware with a fresh build. Default = true after flashing, with
nothing run by hand.

| feature | availability | default |
|---|---|---|
| serial console over USB (`/dev/ttyACM0` → root shell) | ✓ | default |
| `adbd` (root `adb shell`, push/pull) | ✓ | default |
| NCM gadget link + DHCP to the host (`192.168.5.1`) | ✓ | default |
| DNS for the host (dnsmasq on the gadget link) | ✓ | default |
| share the stick's uplink with the host (NAT) | ✓ | default |
| `dropbear` ssh on the gadget link (`ssh user@192.168.5.1`) | ✓ (was broken: see notes) | **not default** — opt in |
| ssh **client** on the stick (`ssh`/`scp`/`ssh-keygen` out) | ✓ Alpine, ✓ Debian route (was missing there) | default (minimal toolset) |
| Wi-Fi station (`wlan0`) | ✓ (was broken: see notes) | default service, no saved network |
| Wi-Fi hotspot AP (`Openstick`) | ✓ | **not default** (`autoconnect=false`) |
| network tools: `nmap`/`ncat`, `tcpdump`, `dig`/`host`/`delv`, `iperf3`, `mtr`, `traceroute`, `whois`, `socat`, `nc`, `ping`/`tracepath` | ✓ in the **full** toolset | `make alpine-full` / `make alpine-cross-full`; **not in the minimal image** |
| LTE modem (`wwan0` via QMI, ModemManager) | ✓ probed, `sim-missing` | default |
| `chrony` time sync | ✓ | default (no RTC battery: clock starts at 1970) |
| mainline `6.12.1-msm8916` + community aboot | ✓ | default |
| this unit's own stock DTB / vendor 5.15 as boot labels | ✓ present on `/boot` | not the default label |
| `resize2fs` to the full 3.3 GiB partition | unexplained, do not rely on it | run it yourself |

Toggle anything on the stick with:

```sh
rc-update add dropbear default && rc-service dropbear start     # ssh door
nmcli connection up hotspot                                     # Wi-Fi AP instead of client
nmcli device wifi connect "<SSID>" password "<PSK>"             # your network, this device only
```

Three things behind those rows were **broken on both boards** until this build, and are worth
knowing because they are silent:

* **ssh never came up.** A CI/minirootfs image has no `/etc/network/interfaces`, so OpenRC
  `networking` fails (`ifquery: could not parse`), and dropbear — which `need net` — could never
  start. Port 22 was not listening on either unit while this repo documented ssh as an admin door.
* **Wi-Fi looked fine and was not.** `wcn36xx` binds, `iw phy0 info` lists `managed` mode and
  `iw dev wlan0 scan` returns BSSes, yet `nmcli device status` sat on `unavailable` forever:
  `networkmanager-wifi` (the device plugin) was missing from the package list, and separately
  NM cannot D-Bus-*activate* `wpa_supplicant` on OpenRC — the supplicant has to be running.
* **the host was given a DNS server that did not answer.** `gadget-net-up.sh` handed out
  `--dhcp-option=6,192.168.5.1` while starting dnsmasq with `--port=0`. The laptop got a lease, a
  route and a nameserver that never replied.

Login reality, since it differs from the old docs: **`root` is locked**; the account is `user` with
the builder's default password and passwordless sudo. `passwd user` before joining any network you
do not own. `adb exec-out` is answered with `error: closed` by this daemon — `adb shell` for text,
`adb push`/`pull` for bytes.

### Details behind each row

| capability | availability | enabled by default | how it was checked / how to use |
|---|---|---|---|
| `adb shell` as root over the gadget | ✓ | ✓ | `adb -s <serial> shell id` → `uid=0(root)`. The vendor `adbd` (glibc) runs on musl through `gcompat`. |
| USB serial console, no disassembly | ✓ | ✓ | host sees `/dev/ttyACM0`; `ttyGS0::respawn:/bin/sh` in `/etc/inittab` gives a passwordless root shell — the door that survives both a broken gadget network and a broken network config. |
| ssh over the NCM link | ✓ (was broken) | **not default** | Port 22 was never listening on either unit (notes above). Opt in with the two commands below. |
| Wi-Fi station | ✓ (was broken) | service on, no saved network | `nmcli device wifi list` returns real SSIDs with signal after this build. Credentials are per-device and never baked into a released image. |
| Wi-Fi hotspot AP (`Openstick`, 192.168.4.1) | ✓ | not default | `hotspot.nmconnection` ships with `autoconnect=false` so the stick joins your network instead of broadcasting one. |
| LTE modem (QMI `wwan0`) | ✓ probed, `sim-missing` | ✓ | MBA + MPSS load, `remoteproc1 … is now up`, ModemManager enumerates a `gsm` device with LTE bands. Registration on a live network is **not** verified — no SIM in this unit. |
| Shares its uplink with the host | ✓ stick-side verified 2026-11-06 (UFI001C): NAT rule, `ip_forward=1`, and DNS on `192.168.5.1` resolving real names from the host over the gadget link. **Client-side internet through the stick is still unconfirmed** — the MacBook that reported no access needs a retest | ✓ | Whoever holds the default route gets MASQUERADE + FORWARD + `ip_forward=1`, and dnsmasq answers DNS with that uplink's resolvers. No uplink → forwarding stays off. Inspect with `nat-share.sh status`. **Caught a real bug here:** the first version took field 3 of `ip -4 route show default`, which is the *gateway*, so the rule went in as `-o 192.168.24.1` — iptables accepts it, it matches nothing, and NAT silently never happens. Now it parses the word after `dev`, has a regression test, and the same fix was applied live to the board that was uplinked at the time. |
| Host gets an address with no configuration | ✓ | ✓ | dnsmasq DHCP 192.168.5.20-60 on the gadget iface, started from `/etc/inittab` — no dbus, no NetworkManager, so the admin door does not inherit the network stack's failures. |
| Switch kernel or DTB without reflashing | ✓ | — | `/boot` is a real ext2 partition with `extlinux.conf` (community DTB), `extlinux-handsome.conf` (this unit's own) and `extlinux-5.15.conf` (vendor kernel + Debian initrd). fstab marks it `noauto`, so `mount /boot` first. |
| Boot chain back to factory | ✓ | — | `restore/` in each pack holds that unit's own `aboot/hyp/sbl1/rpm/tz/boot`. There is no factory image of the userspace — no raw rootfs dump was ever taken. |
| Verify a write without booting it | EDL only | — | Neither aboot implements `fastboot fetch`. `scripts/78-flash-over-edl.sh verify` hashes the partition off the eMMC against the source image; every write in this session was confirmed that way. |
| Clock correct at boot | ✗ by design | — | No RTC battery: time starts at the epoch and `chrony` fixes it once an uplink exists, so early logs read 1970/Jan-01. |
| Rootfs already fills the 3.3 GiB partition | observed, cause unidentified | — | The image is 896 MiB; after first boot `tune2fs` reported the whole partition, with no `resize2fs` caller in the image and no online-resize line in the kernel log. Treated as luck, not a feature — run `resize2fs /dev/disk/by-partlabel/rootfs` yourself. |

## Alternative distro: Alpine

`ALPINE.md` assesses the builder's `alpine` branch (Alpine v3.24 + a postmarketOS v25.12
overlay, `linux-postmarketos-qcom-msm8916` and `msm-firmware-loader` as **apk packages**,
OpenRC, and **dropbear over NCM** instead of adb). Conclusion there: Alpine is maintained in
lockstep with the Debian branch and is the lighter, better-kernel-maintained option, but it is
the **destructive** route — lk2nd + a rewritten GPT + a non-Android ext2 boot partition — so it
cannot be attempted the way route A can. Same unresolved DTB problem for `handsome,openstick`,
which the extracted `out/bootimg/dtb0.dtb` is the asset for.

## Flashing what you built

Two doors, and which one you have depends on whether the stick still boots. Both are measured
on this unit; neither needs root on the host (you need `plugdev` for fastboot/EDL and `docker`
for the cross build).

| | the stick boots | the stick does not boot |
|---|---|---|
| door | fastboot (`adb reboot bootloader`, ~3 s) | EDL — hold the button **while plugging in** |
| tool | the pack's `flash.sh` | `scripts/78-flash-over-edl.sh` |
| can verify a write by reading it back | **no** (`fastboot fetch` is unimplemented on both aboots) | **yes** (`78- verify`, hashes against the source image) |
| can identify which board it is talking to | yes (fastboot reports the eMMC serial) | **no** — 05c6:9008 carries no serial, so `78-` reads the model string out of the board's own `boot` partition and refuses to write otherwise |

```sh
# 1. build (host, no stick internet needed)
COMMIT=1 TOOLSET=minimal scripts/53-build-alpine-cross.sh          # or make alpine-cross-minimal
scripts/55-patch-alpine-image.sh out/alpine-rootfs-ufi103s.img     # gadget, adb, toolset gates
scripts/68-make-mainline-boot.sh OUT_IMG=out/boot-mainline-ufi103s.img \
    DTB_ALT=out/cross-ufi103s/bootimg/dtb0.dtb                     # this unit's own stock DTB
scripts/80-build-flashpack.sh                                       # -> out/flashpack/<board>-v0.1-...

# 2a. fastboot ladder (board boots today)
adb -s 0123456789 reboot bootloader
cd out/flashpack/openstick-flashpack-ufi103s-v0.1-6.12.1-msm8916-minimal-*
COMMIT=1 I_WIPE_ROOTFS=yes SERIAL=<serial-103s> ./flash.sh

# 2b. EDL (board does not boot, or you want read-back verification)
COMMIT=1 I_WIPE_ROOTFS=yes scripts/78-flash-over-edl.sh w rootfs out/alpine-rootfs-ufi103s.img
COMMIT=1 scripts/78-flash-over-edl.sh w aboot vendor/openstick-alpine-v0.2/aboot.mbn
COMMIT=1 scripts/78-flash-over-edl.sh w hyp   vendor/openstick-alpine-v0.2/hyp.mbn
COMMIT=1 scripts/78-flash-over-edl.sh w boot  out/boot-mainline-ufi103s.img
# read each one back and hash it against the source - the verification fastboot cannot give
scripts/78-flash-over-edl.sh verify rootfs out/alpine-rootfs-ufi103s.img
scripts/78-flash-over-edl.sh verify aboot   vendor/openstick-alpine-v0.2/aboot.mbn
scripts/78-flash-over-edl.sh verify hyp     vendor/openstick-alpine-v0.2/hyp.mbn
scripts/78-flash-over-edl.sh verify boot    out/boot-mainline-ufi103s.img
scripts/78-flash-over-edl.sh reboot            # see the caveat below
```

* `78- reboot` sends `<power value="reboot"/>`; **on this unit that warm-resets straight back
  into QDL** (`05c6:9008` again, no OS boot attempted, no enumeration). `--resetmode=reset` does
  cold-boot it. When in doubt: unplug, 5 s, plug in without the button.
* Flash the rungs in order (`rootfs` → `aboot`+`hyp` → `boot`). The factory aboot has no
  `extlinux` parser, so a mainline `boot` image flashed first leaves the board in fastboot with
  no OS.
* Only one stick should be attached when you write over EDL, and never two when you write by
  name at all: both units answer adb as `0123456789`, share the root `PARTUUID`, and hand the
  host the *same* gadget MAC (`2a:85:da:41:eb:f9` — an upstream constant, not derived from the
  serial), so the interface name identifies nothing. The eMMC serial is the only discriminator.
* Nothing here writes `sbl1`/`rpm`/`tz` or any calibration partition (`modemst1/2`, `fsg`,
  `fsc`, `sec`, `cdt`, `devinfo`).

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
* `50-build-rootfs.sh` — the Debian route still needs arm64 binfmt on this host for docker
  (`docker run --platform linux/arm64` gave `exec format error` until qemu binfmt was registered
  with `docker run --privileged multiarch/qemu-user-static --reset -p yes`; the Alpine route,
  `53-build-alpine-cross.sh`, now uses that same door and is proven).
* `60-build-bootimg.sh repack` — the tool is unit-tested and the stock DTB is extracted, but no
  newer kernel binary has been fed through it, and a 5.15-era FDT on a 6.x kernel is unverified.
* The apt upgrade itself, and the configfs fallback unit on a live trixie system.

**Download doors, measured on this stick 2026-11-06 (both were listed as unconfirmed):**
* fastboot: `adb reboot bootloader` → in fastboot ~3 s later as its own serial,
  `getvar version` 0.5, `partition-size:boot` 0x4000000, `partition-size:rootfs` 0xd4dfbe00,
  `max-download-size` 0x10000000, and `fastboot reboot` returns it to Debian. Note
  `version-special` is **empty** on this unit's factory aboot, so the "this is the FACTORY aboot"
  heuristic in `config/flashpack/flash.sh` cannot fire here — the rung order is what protects it.
* EDL: **the button is not a fastboot entry.** Holding it while plugging in gives `05c6:9008`
  (QDL) - so when the installed userspace does not boot, there is no software path back into the
  bootloader and EDL is the only door. The db410c programmer in `vendor/db410c-firmware` works:
  firehose reports `TargetName=MSM8916 MemoryName=eMMC`, reads this board's real GPT, writes
  `rootfs`, and **reads it back byte-identical** - the verification `fastboot fetch` cannot give.
  EDL carries no serial, so `scripts/78-flash-over-edl.sh` identifies the board by reading its
  `boot` partition and matching the model string in its own stock DTB, and refuses to write if
  that does not agree with `BOARD_ENV`.

Rollback story, stated honestly: `backup-ufi103s/boot-stock.bin` restores the kernel/boot path and
is md5-verified; `backup-ufi103s/rootfs-files.tar.zst` is a file-level snapshot of Debian 11 (not a
partition image), and no raw rootfs image was taken - so the stock userspace is *not* restorable as
an image. What is now proven is the transport: both `fastboot flash rootfs` and `edl w rootfs`
work on this stick, and EDL additionally can read partitions back, so a rootfs write can be
verified without booting it.

`backup/`, `notes/`, `out/`, `vendor/` are gitignored: the dumps contain IMEI-bearing
partitions and vendor binaries.
