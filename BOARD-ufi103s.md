# BOARD-ufi103s.md — the Handsome OpenStick UFI103s unit

Everything here was measured on **this** unit over adb / fastboot / EDL on 2026-11-06, on the
host it is developed from. Where something was *not* measured, it says so. Read
[`BOARD-ufi001c.md`](BOARD-ufi001c.md) for the other unit — the two share a partition layout, a
root `PARTUUID` and an adb serial, and differ in exactly the ways that matter.

| | |
|---|---|
| DT model string | `Handsome OpenStick  jsbsbxjxh66-bianyi UFI103s` |
| `compatible` | `handsome,openstick`, `qcom,msm8916` |
| per-unit serial | `<serial-103s>` (`androidboot.serialno` on the vendor image, and the fastboot serial) |
| backup tree | `backup-ufi103s/` — **`backup/` is the UFI001C's and is not interchangeable** |
| board env | `config/board-ufi103s.env` (the default `BOARD_ENV` in `scripts/lib.sh`) |
| stock DTB | `2730cc4bae81…`, 49,653 B, unpacked from `backup-ufi103s/boot-stock.bin` |
| the other unit's DTB | `33cad00d7e8463de…` — if you see this hash, you are holding the wrong board's artifacts |

`adb devices` shows `0123456789` for **both** sticks, so nothing in the transport identifies a
board. Use `BOARD_TAG` matching (`require_board` in `scripts/lib.sh`) and, over EDL, the check in
`scripts/78-flash-over-edl.sh`.

---

## 1. State of this unit right now

Written and **read back byte-identical over EDL** on 2026-11-06:

| partition | contents | sha256 (first 12) | size |
|---|---|---|---|
| `aboot` | community lk1st, `vendor/openstick-alpine-v0.2/aboot.mbn` | `441d314b452d` | 322,540 |
| `hyp` | matching `hyp.mbn` | `c6414843b635` | 10,424 |
| `boot` | `out/boot-mainline-ufi103s.img` — ext2 + `extlinux.conf`, 6.12.1-msm8916 | `2cfc31c91674` | 67,108,864 |
| `rootfs` | `out/alpine-rootfs-ufi103s.img` — Alpine 3.24.2, v0.1 minimal toolset, cross-built offline | `21bede77989c` | 939,524,096 |

Never written: `sbl1`, `rpm`, `tz`, and every calibration partition (`modemst1/2`, `fsg`, `fsc`,
`sec`, `cdt`, `devinfo`). The factory images for `aboot`/`hyp`/`sbl1`/`rpm`/`tz`/`boot` are in
`backup-ufi103s/part-*.bin` + `boot-stock.bin` and also inside this board's pack under `restore/`;
`backup-ufi103s/MANIFEST.sha256` verifies (20 entries).

**It boots, and the boot path is measured.** `edl reset --resetmode=reboot` on this unit is a
*warm* reset that re-enumerates as `05c6:9008` — it never attempts a boot, which is why the first
"did it come up?" check misled me into reading another stick's presence as this board's success.
`--resetmode=reset` does cold-boot it. What has since been observed, on this board:

| check | result |
|---|---|
| boot chain after the swap | `6.12.1-msm8916`, model `ufi-001c/ufi-001b 4G Modem Stick` — i.e. the community **thwc** DTB is what the default label loads, so §4's unresolved DTB question is live, not theoretical |
| v0.1 rootfs, rung 1 via fastboot | gadget up at **~8 s**, `adb -s <serial-103s> shell` → `uid=0(root)` |
| the broken rootfs (with `metadata_csum_seed`) | 150 s of no USB at all — the failure mode §6a describes, seen firsthand |
| Wi-Fi out of the box | `nmcli -t device` → `wlan0:wifi:disconnected:` (managed), plugin present in the image, `wpa_supplicant` in the boot runlevel. **Joining a network is still unverified** — it needs the owner's SSID/PSK |
| ssh out of the box | `dropbear` **not** in the default runlevel, as intended; `networking` now starts (the missing `/etc/network/interfaces` was the old cause) |
| toolset | `ssh`/`scp`/`ssh-keygen`/`nano` present; `nmap`/`tcpdump` absent — correct for `minimal`; `full` is the 0.2 set |
| uplink share to host | `nat-share.sh` + the NM dispatcher hook present, and it correctly does nothing with no default route. **End-to-end internet through the stick is not yet verified** |
| clock | `uptime -s` → 1970-01-01 until chrony gets an uplink: no RTC, as documented |

Still not observed on this unit: LTE registration (no SIM: `failed reason: sim-missing` at the
QMI level, while MBA+MPSS load and ModemManager sees a `gsm` device), either SIM slot, whether
the stock `handsome` DTB boots under mainline at all, and the rootfs expansion in §8.


**Consequence of a bug found later, specific to this unit:** the v0.1 rootfs flashed here on
2026-11-06 contains `nat-share.sh` before its uplink parsing was fixed, so if this board ever
becomes the one with an uplink, its NAT rule would read `-o 192.168.24.1` (a gateway, not an
interface) — accepted by iptables, matching nothing, sharing silently absent. Either reflash the
rootfs from the regenerated pack or push the corrected file:

```sh
adb -s <serial-103s> push config/alpine-gadget/nat-share.sh /usr/local/bin/nat-share.sh
adb -s <serial-103s> shell 'chmod 755 /usr/local/bin/nat-share.sh; /usr/local/bin/nat-share.sh status'
```

The UFI001C was reflashed with the fixed build and verified for NAT: after a reboot with
forwarding off and no rules, the image reconnected Wi-Fi, set `ip_forward=1` and installed
`-o wlan0` MASQUERADE by itself. It did **not** verify DNS, and DNS was broken: `collect_dns()`
wrote bare IPs into the file dnsmasq reads as `--resolv-file`, which expects `nameserver <ip>`
lines, so dnsmasq had no upstreams and answered `REFUSED` — while `nat-share.sh status` listed
resolvers and port 53 was open. Fixed after the fact; the resolution proof is
`nslookup ossmedia.cn 192.168.5.1` returning an answer. Both boards' flashed rootfses from
before that fix carry the bad writer, so both need the one-file push above, not just this unit.

## 2. The download doors, measured here

**fastboot — works, and is reachable from a running system.** `adb reboot bootloader` →
in fastboot ~3 s later as its own serial:

```
version                 0.5
version-special         (empty)          <- see below
partition-size:boot     0x4000000        (67,108,864)
partition-size:rootfs   0xd4dfbe00       (3,571,432,960)
max-download-size       0x10000000       (256 MiB; fastboot auto-slices larger images)
fastboot fetch …        unsupported      (both aboots) → nothing can be read back over fastboot
```

Two consequences:

* `version-special` is **empty on this unit's factory aboot**, so the
  `case "$ver_special" in *qhypstub*)` heuristic in `config/flashpack/flash.sh` never fires here.
  The rung *order* is what protects the board, not that warning.
* A `fastboot flash rootfs` of the 896 MiB image sends only 222 MiB (sparse-trimmed) and takes
  ~6 min; `Writing 'rootfs' OKAY [352.9s]`.

**EDL — the button goes here, not to fastboot.** Holding the button while plugging in yields
`05c6:9008` (QDL) — measured twice, and a 10 s hold afterwards does nothing else. So *when the
installed userspace does not boot, EDL is the only door*, and the ladder's "get back into
fastboot" advice does not apply to this unit.

EDL works, with the DragonBoard loader already pinned in this repo:

```
scripts/78-flash-over-edl.sh status      # read-only: programmer + GPT + identity
LOADER=vendor/db410c-firmware/prog_emmc_firehose_8916.mbn
  → TargetName=MSM8916  MemoryName=eMMC  (no vendor-specific loader needed)
  → reads the board's real GPT, writes partitions by label, and READS THEM BACK
```

Reading back is the point: fastboot cannot verify anything on this board, EDL can. Both the
`rootfs` write (first and last 64 MiB) and the `aboot`/`hyp`/`boot` writes were confirmed by
hashing eMMC bytes against the source images.

**EDL has no serial**, which is a real hazard with two sticks in the drawer. The guard in `78-`
reads the device's own `boot` partition and looks for the model string in it
(`ok: the EDL device's own stock boot partition names UFI103s`), and refuses to write if it
cannot prove the board. Note why the probe is the whole 64 MiB partition: the DTB sits *after* a
9,451,356-byte kernel, so a 4 MiB head read finds no model string at all and reports an
unidentifiable board.

## 3. Partition table, read off this device

| label | offset | length |
|---|---|---|
| cdt | 0x04000000 | 0x800 |
| sbl1 | 0x08000000 | 0x80000 |
| rpm | 0x08080000 | 0x80000 |
| tz | 0x08100000 | 0x100000 |
| hyp | 0x08200000 | 0x80000 |
| sec | 0x08280000 | 0x4000 |
| modemst1 | 0x08284000 | 0x200000 |
| modemst2 | 0x08484000 | 0x200000 |
| fsc | 0x08684000 | 0x400 |
| fsg | 0x0c000000 | 0x200000 |
| aboot | 0x10000000 | 0x100000 |
| boot | 0x10100000 | 0x4000000 |
| devinfo | 0x14100000 | 0x100000 |
| rootfs | 0x14200000 | 0xd4dfbe00 |

Total disk `0xe9000000` (3.87 GB), 0x748000 sectors of 512. `rootfs` starts at LUN sector
**659456** — which is why a readback must add the partition offset itself: `edl rs 0 …` reads the
GPT, not the partition, and looks exactly like a corrupt write.

## 4. Boot chain and the DTB question

The factory `aboot` (`backup-ufi103s/part-aboot.bin`, 1 MiB) is `LK1ST_MSM8916` + `lk2nd_skip`
with `qhypstub` hyp, and contains **zero** `extlinux` strings — it cannot read an ext2
`/boot/extlinux/extlinux.conf`, so a mainline kernel needs the community aboot swap first. That
is what rung 2 of the ladder is for, and it is now done on this unit.

`out/boot-mainline-ufi103s.img` (built by `scripts/68-make-mainline-boot.sh`) carries:

* `/vmlinuz` = 6.12.1-msm8916, `/dtbs/qcom/msm8916-thwc-ufi001c.dtb` (default in `extlinux.conf`)
* `/dtbs/qcom/msm8916-handsome-openstick.dtb` = **this unit's own stock DTB**, via
  `extlinux-handsome.conf`
* `/vmlinuz-5.15` + `/initrd-5.15` = the vendor kernel and Debian initrd from
  `backup-ufi103s/boot-stock.bin`, via `extlinux-5.15.conf`

The default is unresolved on this board, and it is not a cosmetic choice:

* the community `thwc-ufi001c` tree carries the `rmtfs@`/`mpss@` reserved-memory nodes; on the
  UFI001C the modem does not probe without them (`qcom-q6v5-mss: unable to resolve mpss region`).
* this unit's own DTB describes a **dual-SIM mux** (`sim_sel`/`sim_en`/`sim_sel2`/`sim_en2`) that
  the thwc board file collapses to one external slot — but a 2022-era vendor FDT binding to a 6.12
  kernel is exactly the thing `README.md` calls unverified.

Both are on the partition, and `/boot` is a real ext2 filesystem, so deciding this is a file copy
plus reboot, not a reflash:

```sh
cp /boot/extlinux/extlinux-handsome.conf /boot/extlinux/extlinux.conf && reboot
```

Which one actually works on this unit — and whether LTE, either SIM slot, and Wi-Fi come up — is
**not measured**. Same for the whole USB-gadget path under mainline.

## 5. How this board's images get built (no internet on the stick)

`54-build-alpine-onstick.sh` builds Alpine *on the stick*, which needs the stick online. This
unit's Wi-Fi does not associate reliably, so the rootfs was built **offline on the host** by
`scripts/53-build-alpine-cross.sh`: same build script (`scripts/device/alpine-onstick.sh`,
unchanged) running in an arm64-emulating container, with every input the on-device build would
read from its own running system staged instead out of `backup-ufi103s/`:

| container path | staged from |
|---|---|
| `/lib/firmware` | `lib-firmware.tar.zst` (95 files, 46 MB — there is no `modem` partition on this board) |
| `/lib/modules/5.15.0-jsbsbxjxh66+` | `kernel-boot.tar.zst` (320 `.ko`) |
| `/boot/vmlinuz`, `/boot/initrd.img` | `kernel-boot.tar.zst` |
| `incoming/board.dtb` | unpacked from `boot-stock.bin` |
| `ROOT_PARTUUID` | read live from `/proc/cmdline` over adb |
| `BOARD_MODEL` | the live DT model string (a container has no `/proc/device-tree`) |

Requirements: docker (or podman) and a registered arm64 binfmt handler —
`docker run --rm --privileged multiarch/qemu-user-static --reset -p yes`, or
`sudo apt install qemu-user-static binfmt-support`. `53` probes that door with an aarch64 binary
from the backup and refuses to build if it is not open. Build takes ~9 min and leaves
`out/alpine-rootfs-ufi103s.img` (+ `out/cross-ufi103s/`).

The board-specific filenames are deliberate: `out/` is shared scratch, and the UFI001C's
`out/alpine-rootfs.img` was still sitting there — built on *that* unit, per its own
`/etc/openstick-build`. Anything named per board cannot be packed onto the wrong one by accident.

## 6. Two things that went wrong here, and what now catches them

**6a — ext4 features the vendor kernel cannot mount.** The first rootfs image was written with
`mke2fs` 1.47.4's defaults, which include `metadata_csum_seed` (RO_COMPAT, needs kernel ≥ 6.3) and
`orphan_file`. On reboot the stock 5.15.0 initrd could not mount root read-write, and the board
produced **nothing** on USB for 150 s: no adb, no gadget, no fastboot. Rung 1 of the ladder is
supposed to be the reversible checkpoint, and it was not this.

The trap is that the obvious check passes: comparing this image's feature list against the
UFI001C's image shows *zero* differences — because that image has the same bits and was only ever
mounted by mainline 6.12, never by the vendor kernel that rung 1 relies on. "Alpine boots on the
stock `boot.img`" was an inherited assumption, not a measurement.

Now caught in two places: `scripts/53-build-alpine-cross.sh` (`ROOTFS_FORBID`, and `MKFS_EXTRA`
switches them off at creation) and `scripts/80-build-flashpack.sh`, which refuses to **pack** a
rootfs image carrying any forbidden bit.

**6b — `timeout` cannot exec a shell function.** The pack installers called every fastboot
command as `timeout 1200 fb flash …` where `fb` is a function. `timeout` execs a binary, so the
command never ran; the error went to stderr into a `| grep -E 'Sending|OKAY|FAILED'`, and with no
`pipefail` the pipeline's status was grep's. The result: **rung 1 reported a successful 896 MB
flash in seconds, printed nothing, and rebooted a board it had never written** — and the same
defect was in `restore.sh`, i.e. in the recovery path, where a silent no-op is worst of all.
Fixed in both to build an argv array (`FB_CMD=( … )`), with failures now captured and reported
before anything is printed, plus a tab-tolerant `getvar` parse (`fastboot` separates
`partition-size:rootfs:` from its value with a TAB, which made the image-fits-partition check
silently degrade to "could not read"). `tests/test_flashpack.py` now greps every script for
`timeout <n> <shell-function>` so this cannot come back.

## 7. Recovery recipes for this unit

All of these go through EDL, which is the door that works when nothing boots. Keep the board in
QDL (hold the button while plugging in) and only one stick attached.

```sh
# back to the factory boot chain (this unit's own images)
COMMIT=1 scripts/78-flash-over-edl.sh w aboot backup-ufi103s/part-aboot.bin
COMMIT=1 scripts/78-flash-over-edl.sh w hyp   backup-ufi103s/part-hyp.bin
COMMIT=1 scripts/78-flash-over-edl.sh w boot  backup-ufi103s/boot-stock.bin
# or, from the pack, all six at once including sbl1/rpm/tz:
cd out/flashpack/openstick-flashpack-ufi103s-* && COMMIT=1 I_RESTORE_FACTORY=yes ./restore.sh
```

Restoring the boot chain does **not** restore the userspace: no raw image of the original Debian 11
rootfs was ever taken (`fastboot fetch` is unimplemented and the dump over adb was skipped), so
what exists is `backup-ufi103s/rootfs-files.tar.zst`. To go back to Debian with that archive,
build an image the vendor kernel can actually mount — the flags below are the measured set:

```sh
truncate -s 3300M rootfs-rebuild.img
mke2fs -q -F -L rootfs -t ext4 -m 0 -O ^metadata_csum_seed,^orphan_file rootfs-rebuild.img
# unpack the archive into it (mount, or debugfs/e2cp), then:
COMMIT=1 I_WIPE_ROOTFS=yes scripts/78-flash-over-edl.sh w rootfs rootfs-rebuild.img
scripts/78-flash-over-edl.sh verify rootfs rootfs-rebuild.img
```

After a first successful boot: `resize2fs /dev/disk/by-partlabel/rootfs`, `passwd user`
(upstream's default is user/1), and note `adb exec-out` is broken on the injected vendor `adbd` —
use `adb shell` for text and `adb push`/`pull` for binaries.

## 8. Unverified on this unit (do not quote these as facts)

* that the current `aboot`+`hyp`+`boot`+`rootfs` combination boots — never cold-booted yet (§1).
* which DTB works, and whether LTE probes, under mainline 6.12.
* the SIM mux: does either/both slot work under thwc; the vendor DTB describes two.
* Wi-Fi association (the reason this board was built offline) and whether the Alpine Wi-Fi
  profiles ever connect here.
* the USB gadget (NCM + ACM + adb) under **mainline** on this unit; under the vendor kernel it is
  the untested half of rung 1.
* that `modemst1/2`+`fsg` survive the OS change intact — they were never written, so this is
  expected, but not checked by reading them back.
