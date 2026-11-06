# UFI001C (Handsome OpenStick, `<serial-001c>`) — board file

Everything here was **measured on this unit on 2026-11-05**, not copied from a vendor table or
from the notes for the other stick in this probe. Where a claim corrects something this repo
already said, the correction is called out explicitly.

> **This is one of two supported targets.** The other unit — *UFI103s*, `backup-ufi103s/`,
> `config/board-ufi103s.env` — has its own board file in
> [`BOARD-ufi103s.md`](BOARD-ufi103s.md), and differs in the ways that break flashes: its own
> stock DTB, an *empty* `version-special` on the factory aboot, a button that enters **EDL**
> rather than fastboot, and a rootfs built offline in a container because its Wi-Fi will not
> associate. Do not carry measurements from this file across.

> **Per-unit identifiers are redacted.** `<serial-001c>` / `<serial-103s>` stand in for each
> board's eMMC serial (readable as `/proc/device-tree/serial-number`, and as
> `androidboot.serialno=` on the vendor kernel), and `<redacted>` for the modem IMEI. Substitute
> your own board's values in `config/board-*.env`; they are also what `adb devices` and
> `fastboot devices` print, so the commands below read the same once you do. Everything else —
> partition hashes, DTB digests, the root PARTUUID, the gadget MACs (which are upstream's own
> defaults, not this unit's) — is real and reproducible.

**Current state: Alpine Linux v3.24.2 on mainline kernel `6.12.1-msm8916`**, booted by the
community `lk1st` in `aboot` from an ext2 `boot` partition with `extlinux.conf`. Wi-Fi associated,
Bluetooth `hci0` present, **LTE modem fully probed** (IMEI read, all bands enumerated — only
`sim-missing`), rootfs grown to the full 3.3 GiB, **four admin doors open** — a root `adb shell`
as `<serial-001c>` (§4a), ssh over NCM, a passwordless root shell over USB serial, and a software-only
path back into fastboot. The factory bootloader chain is in `backup/` and one command restores it.

Getting there took two false starts, and both are documented below because each one is a trap that
looks like a hardware limit and is not.

---

## 1. Identity — and why `adb devices` cannot tell these boards apart

Every stick in this family answers adb as `0123456789` with `product:occam model:Nexus_4
device:mako`. That serial is a placeholder, so **it identifies nothing**. The only reliable
identifiers:

| | this board | the other stick in this probe |
|---|---|---|
| `/proc/device-tree/model` (vendor DTB) | `Handsome OpenStick  jsbsbxjxh66-bianyi UFI001C` (two spaces after "OpenStick") | `…bianyi UFI103s` |
| `/proc/device-tree/model` (mainline DTB) | `ufi-001c/ufi-001b 4G Modem Stick` | not measured |
| `androidboot.serialno` (`/proc/cmdline`, and `fastboot devices`) | **`<serial-001c>`** | `<serial-103s>` |
| factory `boot` md5 | `8b84db6afcfb5e82df7ccd30dd19fb7f` | `5921b8a4a37e61395e706c2cd8615e15` |
| stock DTB sha256 | `33cad00d7e8463de18d4fb4e6b0ec5fce37090340fb29024e335c1fe4f2ff02e` (49,653 B) | `2730cc4b…` |
| `compatible` | `"handsome,openstick", "qcom,msm8916"` | identical |
| root PARTUUID | `a7ab80e8-e9d1-e8cd-f157-93f69b1d141e` | identical |

Same `compatible`, same PARTUUID, same partition numbering, same vendor kernel — and still two
different boards with two different device trees. The PARTUUID matches because the GPT was laid out
by the same tooling, not because the boards are the same.

**Consequence that already bit us:** a full `backup/` (including the extracted DTB) taken from one
stick is silently wrong for the other. `scripts/54-build-alpine-onstick.sh` therefore refuses to
build unless the DTB it unpacked from `backup/boot-stock.bin` matches the *live* model tag and board
`compatible`. This unit's backups live in `backup/`; the other stick's in `backup-ufi103s/`.

`config/board-ufi103s.env` is the other board's file. Two of its values are wrong for this one:
`HOST_GADGET_IF` (the host-side interface is re-created on every replug — read it live with
`ip -br link`) and the `androidboot.serialno` inside `BOOT_CMDLINE`.

## 2. Hardware, measured

| | |
|---|---|
| SoC | `qcom,msm8916`, 4× Cortex-A53, aarch64 |
| RAM | 462 MB total, ~403 MB available under Alpine; zram swap 230 MB |
| eMMC | 3.64 GiB; `rootfs` = 3,571,432,960 B, `boot` = 67,108,864 B |
| kernel now | **`6.12.1-msm8916 #3 SMP PREEMPT Sun Dec  7 23:30:58 UTC 2025`** (postmarketOS v25.12 apk) |
| kernel before | `5.15.0-jsbsbxjxh66+ #2 SMP PREEMPT Sat Dec 10 21:46:02 CST 2022` — in no repository |
| cmdline | `earlycon root=PARTUUID=a7ab80e8-… console=ttyMSM0,115200 no_framebuffer=true rw rootwait` |
| Wi-Fi | WCNSS over SMD: `remoteproc a204000` up, `WCNSS Version 1.5 1.2`, `wlan0` client-associated, `phy0` in rfkill |
| Bluetooth | `hci0` present via `btqcomsmd`/`btqca`, not soft/hard blocked |
| LTE modem | **works**: `remoteproc 4080000` running, `MBA booted … loading mpss`, IMEI read (`<redacted>`), fw `UFI001CT 20211106`, ports `wwan0(net) wwan0at0/1(at) wwan0qmi0(qmi)`; `state: failed / failed reason: sim-missing` = no SIM inserted |
| USB | device-side gadget only; host sees `1d6b:0104` (NCM+ACM) under Linux, `18d1:d00d` in fastboot, `05c6:9008` in EDL |

GPT by partition label (`/dev/disk/by-partlabel`):

```
cdt p1   rpm p2   sbl1 p3   hyp p4   sec p5   tz p6   modemst1 p7   modemst2 p8
fsc p9   fsg p10  qdss:part0 p11   boot p12   aboot p13   rootfs p14   devinfo p15
p16 is labelled both `edl` and `qdss:part5`
```

There is **no `modem` partition**: the MPSS/DSP/WCNSS blobs are ordinary files in `/lib/firmware`
(83 entries; `modem.b00…b05`, `mba.mbn`, `wcnss.b00…`). A new rootfs that does not carry them loses
the radio entirely — `20-backup.sh` archives them as `backup/lib-firmware.tar.zst`, and the Alpine
build copies the live tree in.

The GPT here is **not** the layout in the upstream builder's `extract_fw.sh` (theirs: `fsc fsg modem
modemst1 modemst2 persist sec hyp rpm sbl1 tz aboot boot rootfs`; ours has no `modem`/`persist` and
different numbering) and **not** the one in `gpt_both0.bin` from the OpenStick release either. Do
not flash a foreign GPT: the release's template describes a 179 MB image with a 1 MB `rootfs`.
Labels and the root PARTUUID already match, so nothing needs repartitioning.

## 3. Boot chain — two aboots, and only one of them parses extlinux

Both `aboot` images are lk1st builds, and they behave differently. This is the single most
important fact on this page.

**Factory aboot (THWC's, `backup/part-aboot.bin`, 1 MiB, `fastboot getvar version` → `0.5`,
`version-special` → `qhypstub 0.3-r3`).** `strings` gives:

```
LK1ST_MSM8916            lk2nd_skip            /mnt/lk2nd_rproc_mode
ext2   ext4   ext2_read_file: not a file   ext2_list_directory: not a directory
Unable to load boot.img from ext2. Continuing legacy boot
Found an appended flattened device tree (%s - %u %u 0x%x)
Only one appended non-skales DTB, select it.
Jumping to kernel via monitor      Failed to jump to kernel
kernel/ramdisk addresses are not valid.
```

and `grep -c extlinux` = **0**. So it supports exactly two shapes: a raw Android boot image in
`boot`, or an ext2 `boot` containing a *file named `boot.img`*. An ext2 tree with
`extlinux/extlinux.conf` makes it fall through to legacy boot, find nothing, and drop to fastboot.

**Community aboot (`vendor/openstick-alpine-v0.2/aboot.mbn`, 322,540 B, sha256 `441d314b452d…`).**
`strings` gives `lk1st-msm8916`, `Failed to parse extlinux.conf`, `Failed to find matching lk2nd
device node`, `Failed to read 'lk2nd,dtb-files'`, `lk2nd,gpio` — i.e. a current upstream lk1st with
extlinux **and** lk2nd device matching. `fastboot getvar version-special` becomes empty, which is a
quick way to tell which one is answering.

Upstream lk2nd's own README describes the arrangement this board was missing: lk2nd is flashed to
the **`boot`** partition and the real OS image sits at **+512 KiB**; `lk1st` is the primary
bootloader for SBCs. Our factory chain had lk1st jumping straight at the kernel with no lk2nd layer.

fastboot works and needs no sudo here (`/lib/udev/rules.d/51-android.rules` + `plugdev`):

```
$ fastboot getvar version               → 0.5
$ fastboot getvar partition-size:rootfs → 0xd4dfbe00  (= 3,571,432,960)
$ fastboot getvar partition-size:boot   → 0x4000000   (= 67,108,864)
$ fastboot getvar max-download-size     → 0x10000000  (= 256 MiB; images are auto-sliced)
$ fastboot getvar all                   → empty: `all` is Android-only, lk2nd does not implement it
$ fastboot fetch …                      → "Device does not support fetch command" (both aboots)
$ fastboot fetch boot:0:512 …           → "Invalid partition size for partition boot:0:512"
```

`fetch` being unsupported is why nothing can be read back after a flash — verification has to
happen by booting it.

**Entering fastboot without hands** (this is the piece that makes everything else iterable):
`adb reboot bootloader` is just `reboot(2)` with `LINUX_REBOOT_CMD_RESTART2` and the string
`"bootloader"`, and this board's bootloader honours that reason. `scripts/device/reboot-bootloader.py`
issues the syscall; `scripts/72-enter-fastboot.sh` runs it over ssh and waits. Measured: fastboot
appears in **~3–4 s**, under both the vendor 5.15 kernel and mainline 6.12, and it works whether
the aboot is the factory one or the community one. If Linux is not running, the physical fallback
is the button — per the nura.eco wiki, on `UFI103S / UFI001C(B) / UFI003` *"the only button is the
EDL button"*, held while plugging in, released after power is applied.

There is no `misc` partition, so the Android "write `boot-fastboot` to misc" route is unavailable.

## 4. What runs on it now

Alpine v3.24.2 (musl, OpenRC). rootfs = `out/alpine-rootfs.img`, built **on the stick itself** by
`scripts/54-build-alpine-onstick.sh` then patched by `scripts/55-patch-alpine-image.sh`; boot =
`out/boot-mainline.img` from `scripts/68-make-mainline-boot.sh`.

* **boot chain**: community `aboot.mbn` + `hyp.mbn`; `sbl1`/`rpm`/`tz` left **exactly as they were**.
  `boot` = 64 MiB ext2 holding `/vmlinuz` (6.12.1), `/dtbs/qcom/{msm8916-thwc-ufi001c.dtb,
  msm8916-handsome-openstick.dtb}`, `/extlinux/extlinux.conf` (+ `-handsome` and `-5.15`
  alternates), and the vendor 5.15 kernel + Debian initrd as a labelled fallback.
* `/boot` is a real mounted partition now (`/dev/disk/by-partlabel/boot`, ext2, fstab `defaults`),
  so **switching kernel or DTB is a file copy plus `reboot`** — no fastboot, no reflash:
  `cp /boot/extlinux/extlinux-handsome.conf /boot/extlinux/extlinux.conf && reboot`.
* both module trees are in the rootfs: `/lib/modules/6.12.1-msm8916` (from the apk, `depmod` run)
  and `/lib/modules/5.15.0-jsbsbxjxh66+` (copied from the vendor system, `modules.dep` intact).
* `/lib/firmware` copied from the running Debian (83 entries, `modem.b00` md5-verified identical) —
  that is why WCNSS/Wi-Fi and the modem firmware load.
* packages: openrc, eudev, dbus, dropbear, networkmanager (+`-cli`/`-tui`/`-dnsmasq`/`-wifi`/`-wwan`),
  modemmanager, libqmi, rmtfs, msm-firmware-loader, chrony, iw, wpa_supplicant, dnsmasq,
  e2fsprogs(+extra), parted, iproute2, iptables, usbutils, zstd, python3, **gcompat** (for adb, below).
* admin doors, all four verified:
  * **`adb -s <serial-001c> shell` — a root shell** (`id -u` = 0), and `adb push`/`pull` are binary-safe
    (1 MiB of `/dev/urandom`, md5 identical host→device→host). Added 2026-11-06; see §4a for how
    and why it needs three files that no package provides. `adb exec-out` still answers
    `error: closed`, exactly as the vendor adbd on the Debian image does, so `scripts/lib.sh`'s
    per-run probe and its stage-then-pull path are still the right design.
  * `ssh -i out/openstick_key root@192.168.5.1` — dropbear, key auth. `user`/`1` also exists
    (upstream's default — change it). Over Wi-Fi the same key works on the DHCP address
    (`root@192.168.24.162` here), which is the door that survives a USB gadget that will not
    come up — it is how the two gadget bugs below were diagnosed.
  * `/dev/ttyACM0` on the host → `ttyGS0::respawn:/bin/sh` — a **passwordless root shell** on the
    USB serial console (configfs ACM function). Deliberate: it is the only door that works when
    networking is what broke, and it is how the gadget bring-up bug was diagnosed. Needs `dialout`.
  * `scripts/72-enter-fastboot.sh` — software-only fastboot entry (§3).
* USB gadget: configfs **NCM + ACM + ffs.adb** (`config/alpine-gadget/setup_gadget.sh`) created by a
  udev rule on UDC add. `usb0` = 192.168.5.1/24, brought up by `gadget-net-up.sh` from `/etc/inittab`
  (`::once:`), with dnsmasq serving 192.168.5.20–60 so the host needs no configuration.

Host-side gotchas worth remembering: ModemManager on the laptop grabs `/dev/ttyACM0` to probe it
(and fires AT commands at your console), and `cu` reports `Line in use` / `Permission denied`
because it checks your real account, not the effective root — `dialout` was empty. Adding the user
to `dialout` fixes access; `ENV{ID_MM_DEVICE_IGNORE}="1"` for `1d6b:0104` fixes the probing. Also:
`ping 192.168.5.1` "succeeds" even with the stick unreachable, because the LAN gateway answers it
(`ttl=253`, 0.7 ms) — always check `ip route get 192.168.5.1` first. That false positive nearly got
recorded as a successful boot.

## 4a. adb on a musl rootfs — what does not work, and the three files that do

Added and verified 2026-11-06. `adb -s <serial-001c> shell` gives **uid 0**, and push/pull are
binary-safe. This section exists because the obvious routes are all dead ends, and each dead end
looks like a packaging oversight rather than what it actually is.

**Alpine has no adbd.** `android-tools-adb-35.0.2-r21` contains exactly one file, `usr/bin/adb` —
the client. There is no `-adbd` subpackage in v3.24 main, community, or the pmOS v25.12 overlay.

**The one that does exist is the wrong daemon.** `adbd-0_git20261018-r0` in **edge/testing** (from
`gitlab.com/android_translation_layer/art_standalone`, the build Waydroid uses) is musl-native,
which makes it look like the answer. It is not: neither it nor the three libraries it links
(`libbase.so`, `libcutils.so`, `liblog.so`) contains a `/dev/usb-ffs` path or a
`FUNCTIONFS_DESCRIPTORS_MAGIC` — **no USB gadget transport**. It also depends on `art_standalone`,
a whole Android runtime: 29.5 MB installed with `dalvikvm`/`dex2oat`/`libart`, needing
`libicui18n.so.78`/`libicuuc.so.78` that only exist in edge, so it would drag an ICU upgrade into a
v3.24 system. For comparison the three libs adbd actually needs total 268 KB.

**The vendor adbd is the right one, and it runs.** `backup/usr-bin-adbd` (md5 `3f26a5bd…`, identical
in both boards' backups) has `usb_linux_client.c`, `init_functionfs` and the literal
`/dev/usb-ffs/adb/ep0..ep2`. It is glibc — but its dependency set is only `libc.so.6`,
`libpthread.so.0` (both from **`gcompat`**), `libz.so.1` (already in the base image) and
`libcrypto.so.1.1`, because **libcutils is statically linked in**. Its highest glibc symbol version
is `GLIBC_2.17`, well inside gcompat's reach. Running it prints
`install_listener('tcp:5037','*smartsocket*')` and, once functionfs is mounted, `ep1`/`ep2` appear —
the proof that it wrote its descriptors.

`libcrypto.so.1.1` cannot be substituted. adbd references the **versioned** symbol
`RSA_verify@OPENSSL_1_1_0`; Alpine 3.24 ships `libcrypto.so.3` exporting
`RSA_verify@@OPENSSL_3.0.0`, so a symlink does not resolve. It comes from Debian 11's `libssl1.1`
(arm64, `1.1.1w-0+deb11u5`, sha256 `9c51e429…`), whose own extra dependency `libdl.so.2` is
satisfied by symlinking it to `libgcompat.so.0` — the same shim gcompat uses for `libc.so.6`.

Three files, ~3.4 MB total, none of them packaged:

| file | from | to |
|---|---|---|
| `adbd` (610,608 B) | `backup/usr-bin-adbd` | `/usr/local/sbin/adbd` 0755 |
| `libcrypto.so.1.1` (2,752,240 B) | Debian 11 `libssl1.1` arm64 | `/usr/lib/libcrypto.so.1.1` 0644 |
| `libdl.so.2` | symlink → `libgcompat.so.0` | `/lib/libdl.so.2` |

plus `apk add gcompat` (pulls `musl-obstack`, `libucontext`).

Reproduce:

```
scripts/76-fetch-adbd-payload.sh     # assemble out/adbd-payload/ and verify all five properties
scripts/55-patch-alpine-image.sh     # inject into out/alpine-rootfs.img with debugfs, then e2fsck
```

`76-` refuses to continue unless the payload really has the versioned `RSA_verify`, really NEEDs
`libcrypto.so.1.1`, and really carries the functionfs transport; `55-` refuses to inject into an
image without `libgcompat.so.0`. On a running board the same three files can be pushed over ssh
(`cat f | ssh … 'cat > /path'` — dropbear has no sftp-server) and `setup_gadget.sh` picks them up.

**The gadget side, where both bugs were.** `setup_gadget.sh` now creates `ffs.adb` and links it, and
the ordering is not negotiable:

1. `mkdir functions/ffs.adb` **before** mounting. The kernel only allocates the ffs device when the
   configfs instance is created, so `mount -t functionfs adb /dev/usb-ffs/adb` returns **ENODEV**
   if it runs first — leaving an empty directory with no `ep0`. The mount *source* must also equal
   the instance name (`adb`); `mount -t functionfs dev …` fails the same way.
2. Start adbd, then **wait for `ep1`**. Its appearance is the proof the descriptors were written.
3. Only then `ln -s functions/ffs.adb configs/c.1/`. Linking a not-yet-active ffs function gives
   **EINVAL**, and a config cannot be modified at all while the gadget is bound to a UDC — so a
   live rebind needs `echo "" > UDC` first (writing the UDC name again is a *bind* request and
   fails EBUSY). Do that over the Wi-Fi door: unbinding drops NCM *and* ACM together.
4. `echo <udc> > UDC` last.

adbd inherits its environment and cwd from whoever started it, and it hands both to every
`adb shell`. Started from a udev rule that has `cd`'d into configfs, that produced two symptoms
which both look like a broken rootfs and are not: the shell landed in
`/sys/kernel/config/usb_gadget/ncm-acm-gadget`, and **`apk` was "not found"** because Alpine keeps
it at `/sbin/apk` and the inherited environment had no `PATH` at all. ssh and the `ttyGS0` console
were unaffected, which is the tell. `setup_gadget.sh` therefore launches adbd from a subshell
`cd`'d to `/root` with an explicit `PATH` (including `/sbin`), `HOME=/root` and `TERM=linux`.

The gadget's `serialnumber` is read from **`/proc/device-tree/serial-number`** (the eMMC serial,
`<serial-001c>`) instead of upstream's hardcoded `fedcba9876543210`. That is what finally makes the two
sticks distinguishable in `adb devices` — under the vendor images both report the placeholder
`0123456789` (§1).

Two measurement traps worth keeping: `debugfs -R "stat <path>"` **exits 0 for a path that does not
exist**, so it is useless as a presence test (list and match instead); and `grep -q` exits on first
match, sending SIGPIPE to a large producer, so under `set -o pipefail` a *successful*
`readelf --dyn-syms | grep -q` reports failure — turn pipefail off for that kind of check.

## 5. Getting a newer kernel: what failed, and what actually fixed it

postmarketOS v25.12 ships `linux-postmarketos-qcom-msm8916` **6.12.1-r2** (28.9 MB apk, 566
modules, `/boot/vmlinuz` = gzip'd arm64 `Image` → 21,364,736 B, `ARMd` magic at +56, 282 DTBs in
`/boot/dtbs/qcom/`) and `device-generic-zhihe-kernel-ufi001c` ("UFI103S / UFI-001C(B) / UFI003"),
whose `deviceinfo` picks `qcom/msm8916-thwc-ufi001c`, `deviceinfo_append_dtb="true"`,
`deviceinfo_flash_offset_base="0x80000000"` + `kernel="0x00080000"` → `0x80080000`, pagesize 2048,
tags `0x01e00000` — **identical to this board's stock boot header**, which ruled out load addresses
as a cause.

Facts established before flashing anything:

* `mmc`, `sdhci` and `ext4` are in **none** of the 566 modules → built in, so 6.12 mounts this
  rootfs with no initrd. No UDC/PHY modules either → the gadget comes up.
* The stock DTB and the community `msm8916-thwc-ufi001c.dtb` share the same mainline bindings
  (`qcom,sdhci-msm-v4`, `qcom,rpm-pm8916-regulators`, `qcom,smd*`, `qcom,msm8916-mss-pil`,
  `qcom,wcn3620`, `qcom,wcnss-wlan`, `smp2p-wcnss`), so "vendor DTB with old bindings" was not the
  blocker either. Node *names* differ (`sdhci@7824000` vs newer `mmc@…`), which does not affect binding.
* Both kernels have the same arm64 `Image` header shape: `text_offset=0`, `flags=0xa` (4K pages,
  flexible physical placement), `ARMd` magic, and `code0=0xfa405a4d` — the **MZ/EFI-stub** header —
  on the pmOS build vs `0xd503201f` (a real `nop`) on the vendor one.

### The failures

Five flash-and-reboot cycles, each observed from the host (`lsusb`: `1d6b:0104` = Linux,
`18d1:d00d` = fastboot):

| # | aboot | boot partition | result |
|---|---|---|---|
| 1 | factory | ext2 + `extlinux.conf` (6.12) | fastboot — no extlinux parser |
| 2 | factory | Android img, 6.12 + stock DTB, no initrd | fastboot |
| 3 | factory | Android img, 6.12 + stock DTB + stock initrd | fastboot |
| 4 | factory | Android img, 6.12 + `thwc-ufi001c` DTB + stock initrd | fastboot |
| 5 (**control**) | factory | Android img, stock pieces, byte-identical no-op repack | **booted**, gadget at t≈8 s |

The control is what makes this a finding rather than a shrug: `tools/bootimg.py repack` with only
stock inputs reproduces `backup/boot-stock.bin` **byte-for-byte** across its first 16,150,528 B
(`cmp` reports EOF there; the stock file is the same content zero-padded to 64 MiB), and that
unpadded image boots. So the repack tool, the appended-DTB layout, the flash path and
shorter-than-partition images were all exonerated. The factory aboot simply cannot start a mainline
arm64 kernel — every failure returned to fastboot rather than hanging, consistent with its own
`Failed to jump to kernel` / `kernel/ramdisk addresses are not valid.` strings.

### The fix

`OpenStick-Builder` release **v0.2** ships `openstick-alpine.zip` (47,564,725 B) containing a
complete known-good chain: `aboot.mbn`, `hyp.mbn`, DB410c `sbl1.mbn`/`rpm.mbn`/`tz.mbn`,
`gpt_both0.bin`, `boot.bin`, `alpine_rootfs.bin`. Unpacking `boot.bin` (Android **sparse**,
magic `3aff26ed` → `tools/simg2img.py`) gives a 64 MiB ext2 with `/vmlinuz` =
**Linux 6.6.0-msm8916** (gzip'd, `code0=0xfa405a4d`, same EFI-stub header as 6.12), `/dtbs/qcom/`
(~250 DTBs including `msm8916-thwc-ufi001c.dtb`) and `/extlinux/extlinux.conf`:

```
linux /vmlinuz
fdt /dtbs/qcom/msm8916-yiming-uz801v3.dtb
append earlycon root=PARTUUID=a7ab80e8-e9d1-e8cd-f157-93f69b1d141e console=ttyMSM0,115200 no_framebuffer=true rw rootwait
```

So a mainline arm64 kernel *does* boot on this dongle family — from ext2 + extlinux, with an
EFI-stub gzipped Image and no initrd. The only missing piece was the bootloader.

What was actually flashed, in this order:

1. `fastboot flash aboot vendor/openstick-alpine-v0.2/aboot.mbn` + `flash hyp …/hyp.mbn`
   → reboot → **the stock Android image still booted** (vendor 5.15 + Alpine rootfs), so the
   community aboot keeps the legacy path. Intermediate state verified before going further.
2. `fastboot flash boot out/boot-612-extlinux.img` (ext2 + extlinux + 6.12 + `thwc-ufi001c`)
   → reboot → **`6.12.1-msm8916` running**, gadget up at t≈8 s, clean reboot cycle repeated.

**`sbl1`/`rpm`/`tz` were never touched.** The nura.eco wiki says mainline arm64 needs Dragon Board
410c firmware, and that is only partly true here: this board's `tz` is *already* byte-identical to
DB410c's (`TZ.BF.3.0-00714`, md5 `ce11a70e` on the first 605,312 B), while `sbl1`
(`IMAGE_VARIANT_STRING=HAAAANAZA`) and `rpm` (`RPM.BF.2.0.C3.2-00005`,
`OEM_IMAGE_VERSION_STRING=wingtech-desktop`) are vendor Wingtech builds vs DB410c's
`RPM.BF.2.0-00186`. 6.12 boots with the vendor `sbl1`/`rpm` in place, so the riskiest flash on this
SoC turned out to be unnecessary. `vendor/db410c-firmware/` keeps them (plus
`prog_emmc_firehose_8916.mbn`) in case a future kernel needs them; the archive is pinned by
`extract_fw.sh`'s sha256 `a37c4e82…` and all 12 files verify against its `MD5SUMS.txt`.

Reproducing all of it:

```
scripts/68-make-mainline-boot.sh                 # ext2 + extlinux + 6.12 + both DTBs
scripts/72-enter-fastboot.sh                     # RESTART2 over ssh, no hands
COMMIT=1 scripts/74-flash-mainline-bootchain.sh aboot
COMMIT=1 scripts/74-flash-mainline-bootchain.sh boot
COMMIT=1 scripts/74-flash-mainline-bootchain.sh restore   # every partition back to factory
```

### Still unexplained

Why the factory aboot refuses a mainline Image is **not confirmed** — no UART was attached, so its
own error string was never read. The EFI-stub `code0` is the visible difference from the vendor
kernel, but the community aboot boots EFI-stub images fine, so it is a property of the older lk1st
build, not of the kernel. Upstream lk2nd offers `fastboot oem log && fastboot get_staged <file>`;
the factory aboot's support for that was not tested. If it ever matters, the 3.3 V UART pads are
labelled on this board family (wiki: 3.3 V for UFI103S/UFI001C(B)/UFI003, unlike the 1.8 V UZ801).

Whether the **stock `handsome,openstick` DTB** boots 6.12 is also untested — it is on the partition
as `extlinux-handsome.conf`, one `cp` away. It describes the dual-SIM mux
(`sim_sel/sim_en/sim_sel2/sim_en2`) that `thwc-ufi001c` collapses to a single external slot, so if
a second SIM slot is ever needed, that is the file to try.

## 6. Known broken / open

* **No SIM inserted**, so LTE is unproven end-to-end: `mmcli -m 0` reports `state: failed`,
  `failed reason: sim-missing`, `power state: off`. Everything below that layer works — MPSS is
  up, QMI answers, IMEI and bands are read. Under the *vendor* DTB the modem never even probed
  (`qcom-q6v5-mss 4080000.remoteproc: unable to resolve mpss region`, `-22`); the community DTB's
  `rmtfs@86700000` (896 KiB) and `mpss@86800000` (87,040 KiB) reserved-memory regions fixed that.
* `qcom-wcnss-pil a204000.remoteproc: unexpected response to sysmon event` at boot — Wi-Fi and BT
  work regardless; uninvestigated.
* `msm_hsusb 78d9000.usb: Failed to create device link (0x180) with remoteproc` — cosmetic; the
  gadget works.
* The stock DTB is *not* the one in use, so the board's own dual-SIM mux GPIOs are not being driven.
  Unknown whether this unit physically has a second slot.
* ~~No `adb`, ever, on this rootfs: the vendor `/usr/bin/adbd` is glibc and musl cannot exec it.~~
  **Corrected 2026-11-06:** musl cannot exec it *directly*, but `gcompat` can, and adb now works
  with a root shell — see §4a for the three files it needs and the two packaging dead ends.
  `scp` still does not work (dropbear has no sftp-server), but `adb push`/`pull` now does and is
  binary-safe, which is the better tool for large images.
* `adb exec-out` still answers `error: closed` on this daemon, so `scripts/lib.sh` keeps probing it
  per run and staging binaries for `adb pull` rather than piping through a PTY.
* `util-linux` is not installed: no `lsblk`. Use `fdisk -l` / `sfdisk -d`.

## 7. Recovery

`backup/` for this unit is complete and `sha256sum -c MANIFEST.sha256` clean (20 files):
`boot-stock.bin` (67,108,864 B, md5-verified against the device before anything was written), every
firmware and calibration partition (`part-{sbl1,rpm,tz,hyp,aboot,cdt,sec,devinfo,fsc,fsg,modemst1,modemst2}.bin`),
`lib-firmware.tar.zst`, `kernel-boot.tar.zst`, `rootfs-files.tar.zst` (241 MB file-level Debian 11
archive), `usr-bin-adbd`, `usr-bin-gc`.

* **Everything back to factory**: `COMMIT=1 scripts/74-flash-mainline-bootchain.sh restore` —
  re-flashes `aboot`, `hyp`, `sbl1`, `rpm`, `tz` and `boot` from `backup/`.
* Boot partition only: `fastboot flash boot backup/boot-stock.bin`.
* Get into fastboot from a running system: `scripts/72-enter-fastboot.sh` (no hands). From a dead
  system: hold the EDL/reset button while plugging in.
* EDL last resort: the button gives `05c6:9008`, and `vendor/db410c-firmware/prog_emmc_firehose_8916.mbn`
  is the programmer. The `edl` tool is **not installed** (no `pip` on this laptop; needs
  `sudo apt install python3-pip`). EDL entry has not been verified on this unit.
* Debian 11 back: `boot-stock.bin` + the file-level archive unpacked onto a fresh ext4. There is no
  raw Debian rootfs image, because reading one needs `fetch` (unsupported) or EDL (unproven).
* While Linux still runs, `boot` can be rewritten with `dd` over ssh — the images can be served over
  the gadget link (`wget -qO- http://<host>:8001/boot-stock.bin | dd of=/dev/disk/by-partlabel/boot bs=1M`).
  Only when the system still boots; a bad `boot` leaves the button as the only door.

## 8. Runbook for the next board

Order matters; every step here is one that was skipped or done out of order on this one.

1. **Identify before trusting anything.** `adb shell "tr -d '\0' < /proc/device-tree/model"` and
   `grep -o 'androidboot.serialno=[0-9a-f]*' /proc/cmdline`. If they do not match the board the
   existing `backup/` came from, move it aside (`mv backup backup-<board>`) — `20-backup.sh` skips
   files that already exist, so it will silently *not* back up the new board.
2. `scripts/20-backup.sh` (device read-only, ~7 min), then `scripts/90-restore.sh verify`.
3. **Prove the fastboot door before flashing anything** — hold reset, replug, `fastboot devices`,
   and note whether you get `18d1:d00d` (fastboot) or `05c6:9008` (EDL). On this board that was
   only proven *after* the first flash, which is why a gadget-bring-up bug briefly left it with no
   software door at all.
4. Get the stick online (Wi-Fi via `nmcli device wifi connect`, or the USB NAT in `30-net-up.sh`).
5. `COMMIT=1 scripts/54-build-alpine-onstick.sh` — builds natively on the stick, pulls
   hash-verified images. Then, **before** flashing: `scripts/76-fetch-adbd-payload.sh` (assembles
   and verifies the adbd payload) and `scripts/55-patch-alpine-image.sh` (injects the gadget files
   and that payload). Patching afterwards costs another whole flash cycle.
6. `fastboot flash rootfs out/alpine-rootfs.img` (~6.5 min for 940 MB), `fastboot reboot`. Verify:
   `1d6b:0104` in `lsusb`, a `192.168.5.x` lease, ssh banner says `dropbear`, and
   `adb -s <serial> shell id` says `uid=0(root)` — the serial is the board's own
   `<serial-001c>`-style value from `/proc/device-tree/serial-number`, not a placeholder. Then `resize2fs
   /dev/disk/by-partlabel/rootfs`, install the ssh key, change the `user`/`1` password.
7. Only now the bootloader: `scripts/68-make-mainline-boot.sh`, `scripts/72-enter-fastboot.sh`,
   `COMMIT=1 scripts/74-flash-mainline-bootchain.sh aboot`, reboot and confirm Linux still comes up,
   then `… boot`. Flashing the ext2 image **before** swapping aboot just lands you in fastboot.
8. If a board's DT model tag is not `UFI001C`, re-check which DTB `68-make-mainline-boot.sh` picks
   (`DTB_NAME=`) — `msm8916-thwc-ufi001c` is right for UFI001C/UFI001B, and the wiki lists
   UFI103S/UFI003 in the same family, but that is unverified on those units.

## 9. Repo defects found while doing this

* `README.md` / `ALPINE.md` / `DTS-DIFF-ufi001c.md` claimed "lk2nd also accepts `extlinux.conf`, so
  a newer kernel needs only a `boot` swap". **Half right, and the half that was wrong cost the most
  time**: true of the community aboot, false of the factory one, and the repo never said which was
  installed. All three now carry a correction pointing here.
* `scripts/66-make-extlinux-boot.sh`: superseded by `scripts/68-make-mainline-boot.sh`, which uses
  the DTB from the *current* backup, names files the way the kernel apk does, and keeps a 5.15
  fallback label. The old script also hardcoded `$OUT/bootimg/dtb0.dtb` — the *other* board's DTB
  unless that directory was unpacked from the current backup.
* `config/board-ufi103s.env`: stale `HOST_GADGET_IF`, and `scripts/lib.sh` sources it
  unconditionally for every board.
* Upstream builder deltas that are wrong on this GPT: `/etc/fstab` mounting `/dev/mmcblk0p14` (the
  rootfs!) on `/boot`; `hotspot.nmconnection`/`lte.nmconnection` with no `autoconnect=false` (the
  stick comes up as an AP named `Openstick` and fights the client connection); installing only
  `networkmanager`, which on Alpine 3.24 yields no `nmcli` (split into `-cli`/`-tui`/`-dnsmasq`);
  and the nested-`/usr/local`-chroot NetworkManager extraction from v3.20, which is unnecessary now
  that Alpine 3.24 ships NM natively.
* Bugs of mine worth remembering, all found by running things: a job backgrounded inside one
  `adb shell` dies with that session's process group (no log ever appears) — use one long-lived
  foreground session, as `20-backup.sh` does; under `set -euo pipefail` a progress `grep` with no
  match aborts the poll loop; `apk add @pmos pkg` treats `@pmos` as a package name (the tag is a
  *suffix*: `pkg@pmos`); a multi-line variable passed to `sh -c` runs its second line as a command;
  `[ -f x ] && cmd` as the last statement of a `set -e` script is fatal when the test fails; and
  `pkill -f "http.server 8000"` matched the shell running it.
* Clock + TLS: this board has no RTC battery, and the converted Alpine image has nothing that
  syncs time before `apk` runs — so a cold-booted stick sits at 1970 and apk rejects the
  postmarketos mirror with "TLS: server certificate not trusted" (every certificate is "not yet
  valid"). The vendor system set the clock itself, which is why the same build worked on the
  Debian board. `54` now stamps the host's UTC onto the stick before the on-stick build and
  refuses to proceed if that fails.
* `mirrors.ustc.edu.cn` answers **403 to GNU wget's User-Agent** but 200 to `curl` and apk's own
  fetcher. Probing the pmos repo with `wget` from the stick looks like an outage; it is not.
