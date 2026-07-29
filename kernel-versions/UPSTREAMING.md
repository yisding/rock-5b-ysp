# Upstreaming decisions — kernel versions

This package holds the RK3588 kernel-base comparisons and the forward-port
narrative, including the PVTM/OPP per-die voltage-binning plan; this file
records its upstream submission disposition, decided 2026-07-29. Cross-package
ordering and coupling constraints live in the central
[upstreaming ledger](../docs/upstreaming-ledger.md); dated claims below must be
re-verified before acting on them.

## Decision list

| ID | Item | Artifact | Upstream target | Decision | Priority | Gates / prerequisites |
|----|------|----------|------------------|----------|----------|------------------------|
| KV-1 | RK3588 SKU-bin OPP selection: OTP cells, a rockchip-cpufreq driver, platdev blocklist entry, and the derated M/J OPP tables | `kernel-versions/docs/pvtm-opp-binning-plan.md` §B.2 (design only) | linux-pm / linux-rockchip | SUBMIT-AFTER-GATE | P2 | Author the four patches (DT cells, `drivers/cpufreq/rockchip-cpufreq.c`, platdev blocklist entry, derated `opp-b-*` node set); boot the series on the 6.18 forward port and show it reproduces this die's measured bin=0 read and leaves the bin-0 OPP set byte-unchanged; `dt_binding_check`/`dtbs_check` clean, and `rk3588-opp.dtsi` byte-identical between the 6.18 port and maxline; cover letter must state plainly that no RK3588J/M part was available, so derated tables are transcription-verified against the BSP rather than hardware-verified |
| KV-2 | RK3588 per-die voltage: a drivers/soc/rockchip PVTPLL process monitor plus per-die opp-microvolt-L* columns, GRF syscons, and its binding | `kernel-versions/docs/pvtm-opp-binning-plan.md` §1 and §B.3 (design only) | linux-rockchip / linux-pm (RFC series) | HOLD | P3 | Phase A0 on-board measurement (static L5/L7 override, voltage verified at the regulator); the full §5 validation plan (compute-verified load, per-cluster isolation, frequency sweep, column bisect, cold boot with recovery ready); resolve the SRAM read-margin question (D3); resolve the shared-DSU-rail exposure; a DT strategy for `rockchip,pvtm-voltage-sel` with a driver-side fallback keyed by compatible |
| KV-3 | Track A vendor straight port of rockchip_opp_select.c / rockchip-cpufreq.c onto 6.18 and 7.2 | `kernel-versions/docs/pvtm-opp-binning-plan.md` §2 (design only) | None — internal kernels and the PPA only | NEVER | P3 | — |

## Rationale and evidence

### KV-1 — RK3588 SKU-bin OPP selection (OTP cells, cpufreq driver, derated tables)

This is the half that stands on its own merits as a correctness fix rather
than an optimization: mainline ships the BSP's unbinned worst-die column
exactly (19/19 shared CPU OPPs match) with no `opp-supported-hw` anywhere, so
an RK3588J/M part runs past its rated frequency cap (little 1704 vs 1800, big
2016 vs 2400) and below its rated voltage (+25 to +75 mV wanted) at the same
time. The shape is precedented by `imx-cpufreq-dt.c`, the enabling pieces are
already upstream and unused (rockchip-otp provider plus the declared-but-
consumerless efuse cells at `rk3588-base.dtsi:3323`, `dev_pm_opp_set_config`
exported), and watchlist check W22 confirms the gap is still open at maxline
v7.2-rc5-252 after a targeted grep sweep since 2025-01-01 returned only a
Qualcomm commit. It is decoupled from the riskier KV-2 by design (plan §B.1),
so it is not held hostage to the PVTPLL RFC. The blocker is simply that
nothing is written yet; the target is alive and the framing is ready.

- Evidence: [kernel-versions/docs/pvtm-opp-binning-plan.md](docs/pvtm-opp-binning-plan.md), [findings/2026-07-25-rk3588-cpu-voltage-binning-bsp-vs-mainline.md](../findings/2026-07-25-rk3588-cpu-voltage-binning-bsp-vs-mainline.md), [findings/2026-07-27-rk3588-pvtm-volt-sel-measured.md](../findings/2026-07-27-rk3588-pvtm-volt-sel-measured.md), [status.md](../status.md), [docs/status-ledger.md](../docs/status-ledger.md)
- Coupled with: KV-2

### KV-2 — RK3588 per-die voltage: PVTPLL process monitor plus per-die OPP voltage columns

The entitlement is now priced rather than estimated: this die measures
`pvtm-volt-sel` 5/7/7, confirmed independently at the regulator (policy0 at
1800 MHz reads 887500 uV, exactly opp-microvolt-L5, 62.5 mV below what the
forward port applies) and by `supported_hw[1] = BIT(7)` gating the turbo step
to 2400 alone, giving -37.5 to -87.5 mV on nine of ten non-trivial OPPs and
exactly 0 mV at 2400. The upstream shape is correctly identified — `mtk-svs.c`
and `exynos-asv.c` establish in-tree precedent for live per-die measurement,
so this is a soc/rockchip process monitor rather than a cpufreq special case.
What is missing is everything an RFC undervolt series must carry: nothing has
been applied to a mainline-based kernel, no power was measured, and cold-boot,
read-margin, and shared-DSU-rail risks are all open as of 2026-07-27. Sending
an RFC that reprograms a live CPU's clock and rail at boot with zero on-board
validation would burn the credibility KV-1 needs.

- Evidence: [kernel-versions/docs/pvtm-opp-binning-plan.md](docs/pvtm-opp-binning-plan.md), [findings/2026-07-27-rk3588-pvtm-volt-sel-measured.md](../findings/2026-07-27-rk3588-pvtm-volt-sel-measured.md), [findings/2026-07-25-rk3588-cpu-voltage-binning-bsp-vs-mainline.md](../findings/2026-07-25-rk3588-cpu-voltage-binning-bsp-vs-mainline.md), [status.md](../status.md), [docs/status-ledger.md](../docs/status-ledger.md)
- Coupled with: KV-1, KV-3

### KV-3 — Track A vendor straight port onto 6.18 and 7.2

Recorded so nobody re-opens it as an upstream option. The plan's own track
table marks it Upstreamable: never, and the reason is structural:
`rockchip_opp_set_regulator_helper()` includes `../../opp/opp.h` and pokes
`opp_table->config_regulators` directly because `dev_pm_opp_set_config()` only
wires the helper for multiple regulators, and `rk3588_change_length()`
includes `../../clk/rockchip/clk.h` to encode `OPP_LENGTH_LOW` into the rate
passed to `clk_set_rate()`, an ABI mainline's rockchip clk driver does not
have. Private-header reach-through of that kind is unmergeable by
construction, and the audience is BSP parity on arbitrary silicon rather than
review. Its one shared artifact, the per-die DT voltage columns, is already
carried by KV-2, and plan §4.5 additionally forbids the static A0 pin from
ever reaching the PPA since it would apply one die's numbers to every board
booting the image.

- Evidence: [kernel-versions/docs/pvtm-opp-binning-plan.md](docs/pvtm-opp-binning-plan.md), [status.md](../status.md)
- Coupled with: KV-2
