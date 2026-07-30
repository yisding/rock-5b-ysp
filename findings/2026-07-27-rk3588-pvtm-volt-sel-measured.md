# This ROCK 5B's BSP voltage-select index measured: L5 little / L7 both big clusters

> Scope: kernel bases (`kernel-versions/`) — RK3588 CPU DVFS voltage selection.
> Closes the open boundary in
> [`2026-07-25-rk3588-cpu-voltage-binning-bsp-vs-mainline.md`](./2026-07-25-rk3588-cpu-voltage-binning-bsp-vs-mainline.md)
> ("this die's BSP voltage-sel index is not derivable offline"). Watchlist
> [`W22`](../status.md#watch-w22). Port plan:
> [`kernel-versions/docs/pvtm-opp-binning-plan.md`](../kernel-versions/docs/pvtm-opp-binning-plan.md).
> Source: booted `6.1.115-vendor-rk35xx` (BSP) on the ROCK 5B ·
> `../rock-5b/kernel/rockchip-kernel` @ `b4ef083dc0c3` (6.1.141) ·
> `../rock-5b/kernel/linux-6.18-rkvenc-av1-fwport` @ `12a7da02bea83` ·
> `../rock-5b/kernel/linux` @ `fac7077731585` (`v7.2-rc5-252`)
> Date: 2026-07-27
> Trust: MEASURED (booted BSP dmesg + live regulators + live cpufreq) /
> SOURCE-INSPECTED (three pinned trees) / CONFIRMED (rail voltage and available-
> frequency set independently corroborate the index) / DESIGN (the port plan)

## Result

Booting the vendor BSP kernel on this exact board makes the previously
unknowable number observable. The BSP prints its selection per cluster:

```
cpu cpu0: bin=0   leakage=15   pvtm=1525   pvtm-volt-sel=5
cpu cpu4: bin=0   leakage=13   pvtm=1782   pvtm-volt-sel=7
cpu cpu6: bin=0   leakage=13   pvtm=1778   pvtm-volt-sel=7
```

Each index reproduces from the BSP `rockchip,pvtm-voltage-sel` bucket table for
its cluster: cluster0 `1507–1530 → 5`, cluster1 `1777–9999 → 7`, cluster2 same.
`bin=0` matches the OTP read recorded in the 2026-07-25 finding, so the non-`hw`,
non-`B4` table is the one selected (`rockchip_of_get_pvtm_sel()`,
`rockchip_opp_select.c:1176`).

### What this die is entitled to

`volt_sel` becomes `prop_name = "L<n>"`, selecting an `opp-microvolt-L<n>`
column. Mainline ships only the baseline column, so the delta is the entitlement:

| Cluster | OPP (MHz) | mainline `opp-microvolt` | this die | Δ | dynamic power ∝ V² |
|---|---|---|---|---|---|
| cluster0 (L5) | 1200 | 712500 | 675000 | −37.5 mV | −10% |
| | 1416 | 762500 | 725000 | −37.5 mV | −10% |
| | 1608 | 850000 | 800000 | −50 mV | −11% |
| | 1800 | 950000 | **887500** | −62.5 mV | −13% |
| cluster1/2 (L7) | 1416 | 725000 | 675000 | −50 mV | −13% |
| | 1608 | 762500 | 700000 | −62.5 mV | −16% |
| | 1800 | 850000 | 762500 | −87.5 mV | **−20%** |
| | 2016 | 925000 | 837500 | −87.5 mV | −18% |
| | 2208 | 987500 | 912500 | −75 mV | −15% |
| | 2400 | 1000000 | 1000000 | **0** | 0 |

**The top big-core OPP gets nothing.** L7's 2400 MHz entry equals the baseline at
1.0 V. Anything pinned to `performance` on the big clusters sees no benefit from
this entire mechanism; the win is confined to the 1416–2208 MHz band that
`schedutil` actually spends its time in. The V² column is dynamic power only —
leakage scales roughly linearly, so realized savings are smaller.

### Two independent live confirmations that the index is applied

Not inferred from the tables — observed on the booted BSP:

1. **Rail voltage.** `policy0` at 1800000 kHz reads `vdd_cpu_lit_s0 = 887500` µV.
   That is exactly cluster0's `opp-microvolt-L5` at 1800 MHz, and 62.5 mV below
   the 950000 the forward port applies at the same OPP.
2. **Available-frequency set.** `supported_hw[1] = BIT(volt_sel)` gates the four
   turbo steps, whose masks are 2256→`0x13`, 2304→`0x24`, 2352→`0x48`,
   2400→`0x80`. `BIT(7) = 0x80` matches only 2400, and the BSP indeed exposes
   `… 2016000 2208000 2400000` with 2256/2304/2352 absent. An index of 5 or 6
   would have exposed a different one of the four.

### The mechanism bottoms out in generic mainline API

`rockchip_opp_set_config()` (`rockchip_opp_select.c:1531`) ends at
`dev_pm_opp_set_config()` with `prop_name = "L<n>"` and
`supported_hw = {BIT(bin), BIT(volt_sel)}` — all of which mainline already has
and exports. The 7,600-line vendor stack exists to *compute* `volt_sel`, not to
apply it.

### PVTM on RK3588 CPUs does not use `rockchip_pvtm.c`

A scope correction worth recording, because it removes 932 lines from any port
estimate. The RK3588 cluster tables set `rockchip,pvtm-pvtpll`, which routes to
`rockchip_get_pvtm_pvtpll()` (`:1044`) — a direct syscon regmap read at
`rockchip,pvtm-offset` (`0x64` on `litcore_grf`, `0x18` on both `bigcore*_grf`),
after forcing the cluster to `rockchip,pvtm-freq` and 750 mV, then
temperature-compensated against `soc-thermal`. The older
`rockchip_get_pvtm_value()` in `rockchip_pvtm.c` is only reached through
`rockchip_get_pvtm_specific_value()` (`:354`), which these clusters never take.
The symbol still has to link, so it needs a stub, not a port.

### `leakage` does not select CPU voltage on RK3588

`leakage=15`/`13`/`13` is printed by the same code path and is easy to mistake
for the selector. The RK3588 CPU cluster tables carry **no**
`rockchip,leakage-voltage-sel`; `info->volt_sel = max(lkg_volt_sel, pvtm_volt_sel)`
(`rockchip_get_scale_volt_sel()`, `:1482`) therefore resolves to the PVTM value
alone. Leakage feeds the power model and scaling only. Other domains
(DMC/venc/VOP) *do* use the leakage selector — a different mechanism.

### `rk3588_change_length()` is not reachable on this die

`rockchip-cpufreq.c:311` encodes an `OPP_LENGTH_LOW` flag into `clk_set_rate()`,
reaching into `clk/rockchip/clk.h`. It only fires when
`volt_sel <= rockchip,pvtm-low-len-sel`, which is 3 on cluster1/2 and unset on
cluster0. At 5/7/7 this is dead code here — one of the four
mainline-incompatibility walls removed for free.

### Maxline rechecked: still nothing, three release candidates later

`W22` was last checked at `v7.2-rc2-242`. At `v7.2-rc5-252` (`fac7077731585`)
the picture is unchanged: `drivers/soc/rockchip/` is exactly
`Kconfig Makefile dtpm.c grf.c io-domain.c`; no `drivers/cpufreq/rockchip-*`; no
`litcore_grf`/`bigcore*_grf`/`dsu_grf`/`pvtpll`/`pvtm` in any rk3588 DT; rk3588
still absent from `cpufreq-dt-platdev.c`; and `rk3588-opp.dtsi` is **byte-identical
to the 6.18 forward port's** (`diff` clean, 190 lines), so one DT patch will serve
both trees.

Upstream *has* been active nearby, and none of it moves this forward:
`rockchip-otp` gained RK3528/RK3562/RK3568 plus an internal word-size fix
(`a255f352b0e0`, `7efe11aace70`, `902fa931a209`, `6c403594354d`) — the provider
keeps growing while the RK3588 cells stay unread. `75fb63ae0312`
("soc: rockchip: grf: Support multiple grf to be handled") reads promising by
title but is an RK3576 JTAG fix; `grf.c` still knows only
`rockchip,rk3588-sys-grf`, not the per-core GRFs this work needs. A
`--grep=pvtm --grep=opp-supported-hw` sweep over `drivers/` and
`arch/arm64/boot/dts/rockchip/` since 2025-01-01 returns one commit, and it is
Qualcomm's.

### Upstream precedent for the hard half exists — correcting an earlier read

The initial assessment that per-die *live measurement* has no mainline precedent
(only fuse reads, as in `imx-cpufreq-dt`/`qcom-cpufreq-nvmem`/`ti-cpufreq`) is
wrong, and it changes the recommended upstream shape:

- **`drivers/soc/mediatek/mtk-svs.c`** — 2,960 lines, in-tree,
  Collabora-maintained. Reads efuse via `nvmem_cell_read()`, reads a thermal zone
  via `thermal_zone_get_temp()`, drives a hardware voltage-scaling engine, and
  calls `dev_pm_opp_adjust_voltage()` (`:680`, `:1508`). Structurally this *is*
  PVTM.
- **`drivers/soc/samsung/exynos-asv.c`** — 169 lines, the minimal form of the
  same pattern.

So the upstreamable framing for PVTM is a `drivers/soc/rockchip/` process-monitor
driver feeding `dev_pm_opp_adjust_voltage()` / `dev_pm_opp_set_config()`, not a
cpufreq special case. That is reflected in the plan's Track B series 2.

## Boundary

- **No undervolt has been applied to any mainline-based kernel.** Nothing was
  built, patched, or booted. The delta table is what the BSP tables *say* this
  die is entitled to; that a forward-port kernel carrying those values is stable
  is **untested**.
- **`pvtm=` was read once, at one ambient temperature, on one boot.** The values
  are temperature-compensated by design (`(T − 25) × 244/1000` little,
  `270/1000` big) and the compensation was not itself validated across a
  temperature range. A cold-boot measurement could bucket differently near a
  boundary — 1782 and 1778 sit only 5 counts above the 1777 threshold for L7,
  which is the thinnest margin in this data.
- **`policy4`'s rail was sampled mid-transition** (675000/1000000 alternating at
  2400 MHz across three reads) and is not usable as a confirmation; the cluster0
  reading at a steady 1800 MHz is.
- **Cluster0's confirmation is single-point.** Only the 1800 MHz OPP was observed
  at the rail; the other nine table rows are transcription, not measurement.
- **No power measurement.** The V² column is arithmetic from the voltage tables.
  No wall power, board current, or thermal figure was recorded, so the realized
  saving is unknown.
- **Bin 0 only.** RK3588M/J derating remains inferred from the DT and bin logic;
  no such part was tested.
- **CPU clusters only.** GPU/NPU/DMC/VOP/venc use `rockchip,leakage-voltage-sel`
  and were not examined.

## Evidence and reproduction

- **Identity:** ROCK 5B booted on the vendor BSP kernel `6.1.115-vendor-rk35xx`
  (this is *not* one of the ysp forward-port kernels — the values below cannot be
  reproduced on a mainline-based boot, which is the entire point).
- **Exercise — selection:**
  `journalctl -k -b | grep -E 'cpu cpu(0|4|6): (bin=|leakage=|pvtm=|pvtm-volt-sel=|soc version=|speed=)'`
- **Exercise — rail:** `/sys/class/regulator/*/name` paired with `microvolts`,
  read alongside `/sys/devices/system/cpu/cpufreq/policy{0,4,6}/scaling_cur_freq`.
- **Exercise — OPP set:** `scaling_available_frequencies` per policy.
- **Exercise — tables:** brace-matched extraction of `opp-microvolt`, every
  `opp-microvolt-L<n>`, and `opp-supported-hw` from BSP `rk3588s.dtsi`
  `cluster{0,1,2}_opp_table` (lines 660/1066/1589), joined on frequency. The
  bin-0 node names are `opp-<digits>`; the derated M/J set is `opp-b-<digits>`
  and must be excluded deliberately, not by accident.
- **Exercise — maxline recheck:** `ls drivers/soc/rockchip/`;
  `git log --grep=pvtm --grep=opp-supported-hw --since=2025-01-01`;
  `diff` of `rk3588-opp.dtsi` between the two mainline trees.
- **Pass/fail signal:** three `pvtm-volt-sel` values each reproduce from their
  cluster's bucket table; the cluster0 rail matches L5 exactly; the exposed turbo
  frequency matches `BIT(7)` and no other index.
- **Artifacts:** none committed. The table extraction is a throwaway script,
  fully described above.

## Why it matters / follow-up

- The 2026-07-25 finding could describe the gap but not price it for this board.
  It now has a price: **37.5–87.5 mV, vendor-qualified, on nine of the ten
  non-trivial CPU OPPs.** Any BSP-vs-forward-port power or thermal comparison
  that does not state this is measuring the missing driver.
- The measured index also makes the cheap path real. A DT-supplied `volt-sel`
  needs no PVTM hardware code at all — see
  [`pvtm-opp-binning-plan.md`](../kernel-versions/docs/pvtm-opp-binning-plan.md)
  §A.4.
- The risks that are *not* closed by knowing the number are the ones that decide
  whether this ships: cold boot below 15 °C (the BSP raises the floor to 0.8 V,
  mainline has no equivalent), SRAM read margin at newly-paired
  voltage/frequency points, and the DSU sharing cluster0's rail. Plan §4.
- `W22` stays open — upstream gaining this is still an external fact that changes
  without a repository edit.
