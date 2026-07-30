# Ramoops retention works on the 6.18.40-era kernels — the all-zero failure was kernel-generation-scoped, not firmware-scoped

> Maintained current synthesis:
> [`boot-firmware/docs/ramoops-retention.md`](../boot-firmware/docs/ramoops-retention.md).
> This finding is the dated record of the reversal: the measured evidence, the
> flip window, why three days of firmware forensics missed it, and the A/B that
> remains open.

> Scope: ROCK 5B (this board), firmware stack `ddr-v1.20-b8ce94f14b /
> bl31-v1.48 / uboot-rmbian-201-06/05/2026` — **identical on both sides of the
> flip** (cmdline `androidboot.fwver`, no u-boot package change in apt history,
> SPI untouched since the 2026-07-06 backup). Kernels: failures on
> `6.18.38-current-rockchip64` and the 6.18.38-era debug builds (2026-07-21..24);
> successes on `6.18.40-ysp-rockchip64`, `6.18.40-video-port-kasan-rockchip-rk3588`,
> and `6.18.40-video-rewrite-kasan-rockchip64` (2026-07-26..27).
> Source: live-board journal (retention begins 2026-07-25 01:00, boot
> `4ec59366`), `/var/lib/systemd/pstore/`, `/var/log/dpkg.log`,
> `/var/log/apt/history.log`, `dtc` extraction of the installed DTBs, repo git
> (`49b115e`), `~/Code/rock-5b/kernel/linux` `v6.18.38..v6.18.40`.
> Date: 2026-07-28
> Trust: **MEASURED** (every recovery event, the flip timeline, the constants) /
> **CONFIG-INSPECTED** (DTB byte-compare, systemd-pstore state both eras) /
> **INFERRED** (kernel-generation scoping — the strongest available reading, A/B
> pending) / **UNVERIFIED** (that 6.18.38 still fails today; which change fixed it).

## Result — the short version

1. **MEASURED: ramoops records cross warm resets on this board, repeatedly,
   right now.** The clearest single event: the 2026-07-27 19:38:08 GRD-SG oops
   (`Internal error: Oops: 0000000096000145 [#1] SMP`, boot `6b1f269c`) wrote a
   dump record; that boot ended in a clean `systemd-reboot` at 20:06:33; the
   next kernel (boot `e4b2d74c`, up 20:06:43) recovered it from DRAM and
   `systemd-pstore` archived it: `PStore dmesg-ramoops-0 moved to
   /var/lib/systemd/pstore/dmesg-ramoops-0` (file mtime = record time, Jul 27
   19:38). At least nine recovery events are in the retained journal
   (2026-07-26 12:14 onward). The oops trace the GRD investigation has been
   chasing over serial is sitting in that archive.

2. **MEASURED: the flip coincides exactly with the 6.18.38 → 6.18.40 rebuild
   wave, with the firmware held constant.** Last measured failures: 2026-07-23,
   kernel `6.18.38-current-rockchip64`
   ([07-24 finding §3.1](2026-07-24-bsp-vs-armbian-ramoops-gap.md), which
   verified `systemd-pstore.service … skipped, unmet condition
   ConditionDirectoryNotEmpty` on every boot — i.e. genuinely empty pstore).
   Then: repo `49b115e` "follow rolling 6.18.y stable" 2026-07-25 14:59; first
   6.18.40 kernel installed 19:20 (dpkg.log) and booted 19:22:07; **first
   recovery in the retained journal 2026-07-26 12:14:21** (boot `e6c7dc79`
   recovering the record written by the first 6.18.40 boot). No 6.18.40-era
   boot has ever shown the failure; no 6.18.38-era boot ever showed a success.

3. **INFERRED, and this replaces the standing hypothesis: the zeroing actor
   tracked the kernel generation, not the boot firmware.** The DTB ramoops node
   is byte-identical between `dtb-6.18.38-current-rockchip64` and
   `dtb-6.18.40-ysp-rockchip64` (same reg/no-map/sizes/ecc, same phandle), the
   cmdline is identical, systemd-pstore was enabled-stock in both eras, and the
   firmware stamp never changed. Three different 6.18.40 trees/configs
   (production ysp, two KASAN debug flavors) all retain; stock Armbian
   6.18.38-current and the 6.18.38-era debug builds all failed. The
   TPL/SPL/BL31/U-Boot audits' null results — no recovered firmware writer
   into `0x118000–0x1e7fff` — are under this reading the *expected* outcome,
   not an anomaly pointing at controller-assisted DDR phases.

## The measured recovery record

Captured 2026-07-27 ~22:10 PDT (indices relative to that session; current boot
`e4b2d74c`). "Recovery" = a `systemd-pstore … moved` journal line in that boot,
which requires the previous kernel's bytes to have crossed the reset in DRAM:

```
boot -15  (unknown; journal head truncated)               | no recovery
boot -14  6.18.40-video-port-kasan    0xd0000@0x118000    | no recovery
boot -13  6.18.40-video-rewrite-kasan 0xd0000@0x118000    | RECOVERED dmesg
boot -12  6.18.40-video-rewrite-kasan 0xd0000@0x118000    | RECOVERED dmesg
boot -11  6.18.40-video-rewrite-kasan 0xd0000@0x118000    | RECOVERED dmesg
boot -10  6.18.40-video-rewrite-kasan 0xd0000@0x118000    | no recovery
boot  -9  6.18.40-video-rewrite-kasan 0xd0000@0x118000    | no recovery
boot  -8  6.1.115-vendor-rk35xx (BSP) 0xe0000@0x110000    | no recovery
boot  -7  6.18.40-video-rewrite-kasan 0xd0000@0x118000    | no recovery
boot  -6  6.18.40-video-rewrite-kasan 0xd0000@0x118000    | RECOVERED console+dmesg
boot  -5  6.1.115-vendor-rk35xx (BSP) 0xe0000@0x110000    | no recovery
boot  -4  6.18.40-video-rewrite-kasan 0xd0000@0x118000    | RECOVERED console+dmesg
boot  -3  6.18.40-ysp                 0xd0000@0x118000    | RECOVERED console
boot  -2  6.18.40-video-port-kasan    0xd0000@0x118000    | RECOVERED dmesg
boot  -1  6.18.40-ysp                 0xd0000@0x118000    | RECOVERED console
boot   0  6.18.40-ysp                 0xd0000@0x118000    | RECOVERED dmesg
```

The no-recovery rows have mundane readings, not failure readings: boots −10 and
−9 followed **clean, oops-free** boots — systemd-pstore erases each zone after
archiving it, a clean boot writes no new dump record, and at `loglevel=1`
pstore's console mirror receives almost nothing (the 07-24 finding's own
qualification) — so there was nothing left to recover. Boots −8/−5 are the BSP
kernel reading a different, overlapping window (`0xe0000@0x110000`, ecc 0), and
−7 follows a BSP boot that had overwritten part of the ysp window. Zone-level
accounting across the BSP interleavings has not been modeled further; the
load-bearing fact is the nine impossible-under-the-old-model recoveries.

## Why three days of forensics missed a working channel

- **`/sys/fs/pstore` is empty within seconds of every boot, by design.**
  `systemd-pstore.service` (enabled-stock, `Storage=external`) archives each
  record to `/var/lib/systemd/pstore/` and unlinks it, which zaps the DRAM
  zone. Every human/agent check of `/sys/fs/pstore` after early boot sees
  empty — including the verification step
  `enable-ramoops-capture.sh` itself prints. Nobody rechecked the archive
  directory after 2026-07-24.
- **The condition-skip line cuts both ways, and that is what makes both eras
  trustworthy.** On the 2026-07-23 boots the journal shows
  `systemd-pstore.service … skipped, unmet condition
  ConditionDirectoryNotEmpty=/sys/fs/pstore` — proof the failures were real
  (pstore genuinely empty at service start, before any archiver race). On the
  2026-07-26..27 boots the same instrument shows `Starting … PStore … moved` —
  proof the successes are real. Same signal, same provenance, opposite result.
- **The 2026-07-26/27 audits made no board measurements.** The SPL audit
  records it explicitly: `/dev/mem` unavailable, sudo blocked in that session.
  Both audits were static analysis premised on a failure that had already
  stopped reproducing the day before they were written.

## What stands, what is retired

Stands, unmodified:

- The 2026-07-21..24 **measured failures on the 6.18.38-era kernels** (probe
  ZEROED, RS-ECC silence, wrapped-console loss) — real, verified, and now
  scoped to that kernel generation.
- Every §3.2 refutation in the 07-24 finding (PMIC RST_FUN, GLB_SRST_SND,
  scrambling, BL31 pool, U-Boot, minidump, userspace) — none of these was the
  mechanism, and none is needed now.
- The 07-26/27 **binary facts** about the TPL blob and SPL (writer bounds,
  extraction pins). Only the framing changes: their null results corroborate
  the kernel-side reading instead of pointing deeper into firmware.

Retired as working hypotheses (do not repeat):

- **"DDR initialization is the leading unresolved phase."** The leading
  hypothesis is now a 6.18.38-era kernel-side actor (on the way down or the
  way up) fixed or removed by the 6.18.40-era rebuilds.
- **"No address inside `0x110000–0x1f0000` can survive under this
  firmware."** `0x118000–0x1e7fff` demonstrably carries records across warm
  resets under this exact firmware today.
- **"Serial/netconsole is mandatory because ramoops can never work here."**
  Serial remains best practice for hard locks and power loss, but pstore
  recovery is measurably functioning on current kernels.
- **"An empty `/sys/fs/pstore` after boot means nothing was captured."** Check
  `journalctl -b -u systemd-pstore` and `/var/lib/systemd/pstore/` instead.

## Boundary

- **The fixing change is unidentified.** `v6.18.38..v6.18.40` is 2113 commits;
  a targeted sweep (fs/pstore — zero commits, drivers/of, mm/memblock,
  arch/arm64/mm, plus keyword greps) surfaced nothing that obviously repairs
  reserved-region retention. The Armbian family patchset and the repo patch
  revisions (`fwport20260724 → 20260725`) moved together with the stable bump,
  so the fix could live in any of the three layers.
- **"6.18.38 still fails" has not been re-confirmed post-flip.** The scoping
  inference rests on the timeline plus the held constants, not on a same-day
  A/B. A confounder that changed on 2026-07-24/25 outside the kernel packages
  is not fully excluded — nothing in apt/dpkg/armbianEnv/journal shows one.
- **Provenance caution on the 2026-07-22 probe verdicts:** they date to the
  window of the 2026-07-23 fabricated-task-notification incident. The 07-23
  journal-based mechanisms (RS silence, console wrap) are independently
  re-verifiable from the finding's own quotes; the probe's ZEROED verdicts are
  not. The A/B below re-covers them either way.
- **The BSP kernel's window contains ours and corrupts it.** `0xe0000@0x110000`
  spans `0x110000–0x1effff`; its zone init and console mirror write inside
  `0x118000–0x1e7fff`. Any retention comparison interleaved with a BSP boot
  (including the incidental 2026-07-27 EXP-2-shaped boots) is confounded.
  Separately: pstore's zone signature `PERSISTENT_RAM_SIG` is the ASCII bytes
  `DBGC` — the same four bytes as the TPL debug-ring tag — so `DBGC` sightings
  in DRAM dumps at `0x110000+` after a BSP boot are ambiguous between pstore
  headers and the firmware ring.
- The 2026-07-22 island results (1 GB ZEROED, 2/6 GB "GARBAGE", never
  hexdumped) were also read by 6.18.38-era kernels and carry the same scoping
  caveat; current-kernel island behavior is unmeasured.

## Verification gate — the kernel A/B (4 reboots, nothing to flash)

`6.18.38-current-rockchip64` (kernel, initrd, DTB with the identical ramoops
node) is still installed. Using
[`ramoops-persistence-probe.sh`](../kernel-drivers/scripts/debug-kernel/ramoops-persistence-probe.sh)
with `initcall_blacklist=ramoops_init` per its runbook:

1. On `6.18.40-ysp`: `write` → warm `reboot` → `read`. Expected **INTACT**
   (already implied by the recovery record; this makes it explicit under the
   probe's own classifier).
2. Repoint `/boot/Image`, `/boot/uInitrd`, `/boot/dtb` at the 6.18.38-current
   set, boot, `write` → warm `reboot` → `read`.

| 6.18.38 result | 6.18.40 result | Reading |
|---|---|---|
| ZEROED | INTACT | Kernel-side actor confirmed; split upstream-stable vs patchset (build 6.18.38 base + new patches, or 6.18.40 base + old patches) before any 2113-commit bisect. |
| INTACT | INTACT | The 07-21..24 environment had a confound the timeline hides (or the probe-era results were unsound); reopen with the archived evidence, not the firmware. |
| ZEROED | ZEROED | Would contradict the measured recoveries — recheck the probe itself before anything else. |

## Why it matters / follow-up

- `/var/lib/systemd/pstore/dmesg-ramoops-0` (root-only) holds the full
  2026-07-27 19:38:08 GRD-SG oops record — captured by the channel the
  workflow had written off. Read it before the next serial session.
- Crash capture guidance, the retention doc, the capture script's verification
  steps, and the SPL-entry-witness experiment priority all change; see the
  updated [`ramoops-retention.md`](../boot-firmware/docs/ramoops-retention.md).
