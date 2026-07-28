# Ramoops next experiments: find the first boot stage that changes the bytes

> Maintained current synthesis:
> [`boot-firmware/docs/ramoops-retention.md`](../boot-firmware/docs/ramoops-retention.md).
> This finding remains the detailed experimental design.

> **Evidence-boundary update 2026-07-28:**
> [`2026-07-28-ramoops-retention-works-on-6-18-40-kernels.md`](2026-07-28-ramoops-retention-works-on-6-18-40-kernels.md).
> Cross-reset ramoops recoveries are now measured on the 6.18.40-era kernels
> under the same firmware, so the premise this design instruments — an
> ongoing boot-phase zeroer — no longer holds as stated. The SPL-entry
> witness is demoted to a contingency; the priority experiment is the
> four-reboot kernel A/B on the still-installed `6.18.38-current-rockchip64`
> image, defined in the 07-28 finding's verification gate.

> Scope: ROCK 5B ramoops retention at `0x118000–0x1e7fff`
> Source: measured warm-reset loss, exact TPL/SPL/BL31/U-Boot write audits, and
> the corrected evidence boundary in
> [`2026-07-27-rk3588-spl-ramoops-binary-audit.md`](2026-07-27-rk3588-spl-ramoops-binary-audit.md)
> Date: 2026-07-27
> Trust: **DESIGN** / **PARTIAL**

## Objective

Stop inferring the actor from a post-Linux all-zero read. Find the earliest boot
checkpoint at which known prior-boot bytes differ, then vary one input at a
time.

The current proof boundary is:

- `0x118000–0x1e7fff` returns all-zero after a software warm reset.
- No recovered ordinary TPL, SPL, BL31, or U-Boot store targets the interval.
- PHY calibration is not inherently destructive.
- DDR initialization is the leading unresolved phase, not a proven cause.

The highest-value new observation is therefore at **SPL entry**, immediately
after the DDR TPL and BootROM load path but before normal SPL initialization,
FIT loading, BL31, U-Boot proper, or Linux.

## Experimental discipline

Every reset trial should:

1. Reserve every sampled region from Linux and keep `ramoops_init` from touching
   it.
2. Write page-unique data, not a repeated string:
   - physical page address;
   - bitwise inverse of the address;
   - trial and sequence numbers;
   - a deterministic PRBS payload;
   - a checksum over the page.
3. Clean the written cache lines to the point of coherency, issue the required
   barriers, and verify the complete write before reboot.
4. Capture the complete post-reset bytes before classifying them. Preserve the
   binary dump, per-page checksum, 256-bin byte histogram, and bit-transition
   counts.
5. Include an unstamped control page and guard pages around every sampled
   interval.
6. Repeat each condition at least five times with three starting populations:
   mostly zero, mostly one, and balanced PRBS.
7. Hold kernel, DT, reset source, firmware components, temperature, and
   reset-to-observation timing constant unless that variable is the test.
8. Send results off-board over UART or another non-DRAM channel. Do not use
   ramoops to validate ramoops.

The page identity matters. It distinguishes content loss from an address-map
permutation, which a single signature or all-zero classifier cannot do.

## Phase 1 — spatial and transition fingerprint

First improve the existing persistence probe without changing firmware.

Sample:

- the DDR handoff areas below `0x110000`;
- the firmware ring at `0x110000–0x117fff`;
- every page in `0x118000–0x1e7fff`;
- ATAGS at `0x1fe000`;
- pages immediately above `0x200000`;
- multiple islands across every reported channel/rank and both DRAM banks.

Run matched warm-reset and cold-power-cycle trials. Save full dumps before any
summary.

| Result | Interpretation |
|---|---|
| Every starting pattern becomes the same zeros | deterministic overwrite, scrub, forced-zero read, or another deterministic initialization effect; not ordinary random decay |
| Stochastic loss correlated with time or temperature | refresh interruption or physical retention failure |
| Page payloads survive at different addresses | geometry/address-map change |
| Fixed nonzero patterns affect localized ranges | training or memory-test traffic |
| Stable reversible/XOR-like transformation | revisit scrambling or encryption |
| Sharp aligned start/end boundaries | range operation; alignment constrains but does not identify its issuer |
| Warm and cold have different transition distributions | reset-specific behavior exists |

This phase characterizes the failure but does not localize it in time.

## Phase 2 — SPL-entry witness

Build a diagnostic SPL that examines the marker range at its earliest safe
point. It should run after the exact DDR TPL/BootROM path and before SPL's normal
allocations or payload loading.

The witness should:

1. Avoid clearing or allocating inside the sampled interval.
2. Compute per-page checksums plus a compact histogram/transition summary.
3. Record a timer value so reset-to-observation latency is known.
4. Emit the result directly over the debug UART, or preserve it in a verified
   SRAM/PMU scratch location for later UART output.
5. Continue booting only after the evidence is safely off the tested DRAM.

Deliver the diagnostic loader through a RAM-only maskrom/recovery path where
possible. Do not modify SPI for the first implementation. Prove that the
diagnostic build reproduces the control boot before interpreting its memory
result.

| Earliest result | Causal boundary |
|---|---|
| Already changed at SPL entry | BootROM/TPL/controller phase |
| Intact at SPL entry, changed before BL31 handoff | SPL dynamic or hardware-side behavior missed by static recovery |
| Intact through BL31/U-Boot | Linux early boot or reserved-memory handling |
| Only `0x110000–0x117fff` changes | firmware log-ring behavior, not whole-window loss |

This is the highest-information experiment because it converts the current
phase inference into a direct before/after checkpoint.

## Phase 3 — one-variable DDR-blob A/B

Run this only if the bytes are already changed at SPL entry.

Hold constant:

- SPL;
- BL31;
- U-Boot proper and its control DTB;
- kernel and OS DT;
- reset source;
- marker data and observation code.

Change only the DDR/TPL blob. Start with:

- BSP-era v1.15;
- running v1.20;
- current v1.22.

Package every variant with the same diagnostic SPL and deliver it without
flashing SPI. Repeat each condition. A different retention fingerprint proves a
blob-generation dependency, not which internal command caused it.

If binary compatibility makes BL31 changes unavoidable, use a small factorial
matrix rather than comparing two bundled pairs:

| | BL31 v1.48 | BL31 v1.54 |
|---|---|---|
| DDR v1.20 | control | isolate later-stage BL31 effect |
| DDR v1.22 | isolate DDR effect | matched current pair |

The SPL-entry witness runs before BL31, so its result should remain the primary
DDR discriminator.

## Phase 4 — checkpoint the TPL initialization sequence

Run this only after Phase 2 places the transition before SPL and Phase 3 shows
whether it follows the blob.

Use JTAG breakpoints if available; otherwise add binary trampolines that hash
the target into SRAM or print over UART. Observe at:

1. TPL entry, before controller changes, if DRAM is still accessible.
2. After controller reset/configuration.
3. After DRAM reset and mode-register initialization.
4. After refresh is enabled.
5. After PHY training.
6. After geometry/rank detection.
7. After each destructive memory-test call.
8. Immediately before returning to BootROM/SPL.

The first changed checkpoint identifies the operation class. If DRAM is
inaccessible at TPL entry, record controller/PHY/reset status rather than
treating a failed read as zero data.

Once a phase is isolated, add discriminators:

- vary delay with refresh unavailable to test retention sensitivity;
- bypass one training/test phase at a time where safe;
- compare reset sources while holding the blob constant;
- compare entry in explicit self-refresh against ordinary active state.

Do not bypass required training on a persistent boot device until a RAM-only
recovery path and automatic fallback are proven.

## Separate track — does BSP persistence work at all?

Booting the installed BSP kernel or an official Radxa image answers a different
question: whether any supplied RK3588 stack recovers a prior-boot pstore record.
It does not identify the zero mechanism on the current stack.

Keep the existing BSP-kernel and official-image experiments, but report them
separately:

- success establishes the premise and motivates a controlled firmware/OS
  differential;
- failure weakens the premise but does not explain the current all-zero bytes.

## Priority and safety

1. **Read-only ring/boundary dump** — zero risk, low temporal information.
2. **Improved multi-pattern warm/cold probe** — low risk, high failure-shape
   information.
3. **RAM-only SPL-entry witness** — medium implementation/recovery risk, highest
   causal information.
4. **RAM-only one-variable DDR-blob matrix** — medium risk after the witness is
   trustworthy.
5. **JTAG/TPL phase checkpoints** — medium-to-high complexity, decisive within
   the DDR phase.
6. **SPI firmware replacement** — defer; it adds recovery risk without adding
   information unavailable from a RAM-only loader.

## Success criterion

This plan is complete when one experiment captures the same page-specific
marker immediately before and after the first operation that changes it.

A blob A/B that merely changes the final outcome establishes dependency, not
mechanism. A ROOT-CAUSED conclusion requires the transition checkpoint or an
equivalent direct observation.
