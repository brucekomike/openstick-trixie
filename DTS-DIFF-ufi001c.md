# Is this stick really covered by the "UFI001B / UFI001C → `thwc-ufi001c.dtb` → supported" row?

Measured 2026-11-04 by comparing the **stock DTB extracted from this stick's own boot
partition** (`out/bootimg/dtb0.dtb`, 49,653 B) against the community sources
(`vendor/dts/msm8916-thwc-ufi001c.dts`, `vendor/dts/msm8916-ufi.dtsi`).

> **Three corrections from the 2026-11-05 flashing session** ([`BOARD-ufi001c.md`](BOARD-ufi001c.md)):
> 1. This file analyses the *UFI103s* DTB (`2730cc4b…`). The board that was actually flashed is a
>    different unit whose model string says UFI001C and whose stock DTB is `33cad00d…` — same
>    `handsome,openstick` compatible, same four `sim_*` dual-SIM nodes, different bytes.
> 2. The claim below that "lk2nd's `extlinux.conf` path is available today" is **false for the
>    factory aboot**: the string `extlinux` does not appear in `part-aboot.bin` at all. It *is*
>    true of OpenStick-Builder v0.2's community `aboot.mbn`, which is what now sits on that board.
> 3. "Would probably *boot*" was the wrong thing to be uncertain about. Both DTBs were tried with
>    the pmOS 6.12 kernel **under the factory aboot**; neither booted, and a byte-identical no-op
>    repack of the stock image did — so the DTB choice was not the deciding variable, the
>    bootloader was. Once the community aboot was flashed, `thwc-ufi001c` booted 6.12 first try.
>
> What the DTB *did* decide is the radio: the stock `handsome,openstick` DTB has no
> `rmtfs@`/`mpss@` reserved-memory, so `qcom-q6v5-mss` fails with `unable to resolve mpss region`
> and there is no modem at all. `thwc-ufi001c` carries both and the modem probes (IMEI read). Its
> cost is the dual-SIM mux this file describes — it drives one external slot on gpio0–3 instead.

## What is genuinely shared (so `thwc-ufi001c.dtb` would probably *boot*)

| aspect | stock UFI103s DTB | `thwc-ufi001c` family |
|---|---|---|
| SoC | `qcom,msm8916` | `qcom,msm8916` |
| root compatible | `"handsome,openstick", "qcom,msm8916"` | `"thwc,ufi001c", "qcom,msm8916"` |
| PMIC | `qcom,pm8916`, `qcom,rpm-pm8916-regulators`, `pm8916-pon/wdt/pwm/vib/lbc/mpp/bms-vm`, `qcom,pm8916-wcd-analog-codec` | includes `msm8916-pm8916.dtsi` |
| modem/BT link | `qcom,smd`, `wcnss@8df00000`, `smp2p-wcnss`, `qcom,msm8916-mss-pil` | same SoC-level nodes |
| storage | `sdhci@7824000`, `sdhci@7864000` (`qcom,msm8916-sdhci`) | same |
| input/LED style | `gpio-keys` ("GPIO Buttons") + `gpio-leds` | `gpio-keys` + `gpio-leds` |

Same SoC, same PMIC, same controller set: console, USB, eMMC and the modem Pil come from the
SoC-level `.dtsi` files, not the board file. So a borrowed `thwc-ufi001c.dtb` is not a
"won't come up at all" risk.

## Where it is NOT this board (and why that matters more than booting)

| | stock UFI103s | `thwc-ufi001c.dts` |
|---|---|---|
| SIM switching | **four** nodes: `sim_sel`, `sim_en`, `sim_sel2`, `sim_en2` → dual-SIM selector | one external slot: `esim-sel-pins` gpio0+gpio3 (output-low), `sim-en-pins` gpio1 (output-low), `sim-sel-pins` gpio2 (**output-high**), comment "selects the external SIM card slot by default" |
| MPSS pinctrl | (stock values, unknown to the community tree) | `&mpss { pinctrl-0 = <&sim_ctrl_default>; }` |
| buttons | stock `gpio_keys_default` | restart button forced to **gpio37** |
| LEDs | stock `msmgpio-leds` | led_b/g/r forced to **gpio20/21/22** |

That is the crux: the row says the *board* is supported, and this stick is a different board in
the same family (`handsome,openstick`, model string *UFI103s*). Booting with the wrong board file
leaves the SIM multiplexer driven on the wrong pins — on a 4G stick that is not a cosmetic
failure, it is the device's only job. LEDs and the button are wrong too, harmless but misleading
when you later debug by looking at them.

## Correction found while writing this: the boot chain is already community lk2nd

Reading the backed-up bootloader partitions:

| partition | evidence in `strings` | meaning |
|---|---|---|
| `aboot` | `lk2nd_skip`, `/mnt/lk2nd_rproc_mode`, `app/aboot/aboot.c`, `app/aboot/fastboot.c` | **lk2nd**, not vendor LK |
| `hyp` | `qhypstub` | the open hypervisor stub, built by `build_hyp_aboot.sh` |
| builder repo | its committed `configs/extlinux.conf` contains `root=PARTUUID=a7ab80e8-e9d1-e8cd-f157-93f69b1d141e` — this device's exact root PARTUUID | the GPT came from the same tooling |

So "route B/C replaces the boot chain" was the wrong framing: the chain is *already* the
community one, lk2nd's `extlinux.conf` path is available today, and fastboot is compiled into
the aboot that is running. What was actually missing was a correct device tree — and that is
what `scripts/66-make-extlinux-boot.sh` now packages: `out/bootimg/dtb0.dtb`, verified
byte-identical to stock inside the built image.

This does not change the recommendation order (route A first, because it needs no flashing at
all), but it removes most of the risk from routes B/C: no GPT rewrite is needed to get a newer
kernel onto this stick, only a `boot` partition swap that `backup/boot-stock.bin` reverses.

## Decision, and why it is not really a trade-off

1. **Route A (in-place Debian 13) needs no DTB at all** — the stock `boot` partition stays
   untouched, so the question does not arise. That remains the first thing to do.
2. **For any community/lk2nd route (Alpine or a newer kernel), use this board's own DTB**, which
   is already extracted: `out/bootimg/dtb0.dtb`. `config/extlinux-ufi103s.conf` +
   `scripts/66-make-extlinux-boot.sh` build a boot image that keeps the exact hardware
   description instead of borrowing `thwc-ufi001c`.

So: "supported" is true for UFI001B/C. For the UFI103s the accurate statement is *same family,
different board file* — and because we hold the correct DTB, we never have to gamble on the
borrowed one.

Unverified, stated as such: whether `linux-postmarketos-qcom-msm8916` ships a
`msm8916-handsome-openstick*.dtb`. The community fork's default branch
(`wip/msm8916/7.0`) contains only `thwc-uf896`, `thwc-ufi001c`, `yiming-uz801v3` and
`msm8916-ufi.dtsi`; a `msm8916-handsome-openstick-common.dtsi` was reported on a WIP/next
branch, and I could not fetch it from the branch names I tried (`linux-next` returned no
handsome entries). That gap is exactly what `dtb0.dtb` works around.
