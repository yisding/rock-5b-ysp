# Ramoops/pstore does not survive a warm reset on this ROCK 5B

> Maintained current synthesis:
> [`boot-firmware/docs/ramoops-retention.md`](../boot-firmware/docs/ramoops-retention.md).
> This finding preserves the initial observation and its explicitly corrected
> mechanism claims.

> **Evidence-boundary update 2026-07-28:**
> [`2026-07-28-ramoops-retention-works-on-6-18-40-kernels.md`](2026-07-28-ramoops-retention-works-on-6-18-40-kernels.md).
> The all-zero result stopped reproducing after the 2026-07-25 rebuild wave
> moved every installed kernel to a 6.18.40 base: cross-reset ramoops
> recoveries are now measured repeatedly on the identical firmware stack. The
> failures recorded here were real but are scoped to the 6.18.38-era kernels,
> and the firmware-phase inference is retired as the working hypothesis. The
> operative conclusion — off-board capture only — is softened accordingly;
> serial remains required for hard locks and power loss.

> Scope: ROCK 5B debug kernels (all of them — they carry the ramoops DT patch),
> firmware stack `ddr-v1.20-b8ce94f14b / bl31-v1.48 / uboot-rmbian-201`
> (Armbian, from the kernel cmdline `androidboot.fwver`).
> Source: measured on debug builds `P7589-C4ad2` (`#7`) and `P9c12-C4ad2`
> (`#1`); `kernel-drivers/patches/debug-kernel/0001-arm64-dts-rockchip-add-persistent-ramoops-to-rock-5b.patch`;
> `kernel-drivers/scripts/debug-kernel/enable-ramoops-capture.sh`.
> Date: 2026-07-21
> Trust: **MEASURED** (self-reboot + correct config → empty pstore, incl. the
> continuously-written console zone) / **INFERRED** (the RK3588 DDR-re-init
> mechanism and the BSP-firmware-cooperation gap) / **UNVERIFIED** (whether
> *any* address could survive — full-DRAM-loss vs targeted-clobber).

> **Corrected 2026-07-24** by
> [`2026-07-24-bsp-vs-armbian-ramoops-gap.md`](2026-07-24-bsp-vs-armbian-ramoops-gap.md),
> which compared this stack against official Radxa BSP artifacts. The operative
> conclusion below — *ramoops does not survive a warm reset at
> `0x118000–0x1e7fff` on this firmware stack, so use off-board capture* —
> **stands, and is now confirmed three independent ways**. Four supporting
> claims were wrong and are corrected in place, marked
> **[corrected 2026-07-24]**: the DRAM-wide universality claim, the
> DDR-scrambling explanation, the reading of "100 %-of-bytes garbage", and
> "no supported firmware configuration changes this". The premise that the
> BSP *does* get 0x110000 to persist is also downgraded — nobody has ever
> shown it.

## Result — ramoops cannot capture crashes on this board

The debug kernels are configured for ramoops correctly, but **nothing ever
lands in `/sys/fs/pstore`**, so the primary crash-capture mechanism the
debug-kernel workflow relies on does not work on this ROCK 5B. Two real crashes
this session (an RGA `rga_request` UAF, and a fatal MPP/`rk_vcodec` NULL-deref)
and one deliberate `echo c > /proc/sysrq-trigger` test all left pstore empty.

Crucially, the `echo c` test **self-rebooted** (panic → `panic=10` →
`emergency_restart`, confirmed by the operator: the board came back on its own,
no power-cycle) — a genuine warm PSCI reset — and pstore was **still** empty.
So the emptiness is not explained away by power-cycling; the reserved DRAM
region is not preserved across the reset itself.

## The config is correct — verified on the running kernel

- DT reserved-memory node live: `ramoops@118000`, `reg = <0x118000 0xd0000>`
  (832 KiB), `no-map`, `ecc-size = 16`, zones `record-size 0x40000` (256 KiB
  oops/panic) + `console-size 0x80000` (512 KiB) + `pmsg-size 0x10000` (64 KiB).
- Registered cleanly every boot: `pstore: Registered ramoops as persistent
  store backend`, `ramoops: using 0xd0000@0x118000, ecc: 16`,
  `legacy console [ramoops-1] enabled`. `/sys/fs/pstore` mounted; `/dev/pmsg0`
  present. **No** bad-ECC or registration errors.
- Triggers correct: `panic_on_oops=1`, `panic=10`, `pstore.backend=ramoops`,
  `pstore.kmsg_bytes=262144` (matches record-size), `printk.always_kmsg_dump=1`.

## Why this is a persistence failure, not a failed write

ramoops's whole premise is that a **reserved DRAM region keeps its bits across a
reboot**, so a fresh kernel reads back what the dying kernel wrote to the same
physical address. Two observations show the region itself is not surviving:

1. **The console zone is written continuously, every boot, crash or not**
   (`legacy console [ramoops-1] enabled` mirrors all printk into DRAM in real
   time). If DRAM persisted across the reset, even a clean reboot would leave
   the previous boot's whole console log as `console-ramoops-0`. It never
   appears. A zone written every second of every boot cannot vanish unless the
   memory itself is not carried over — which rules out "the panic dumper didn't
   run."

   **[qualified 2026-07-24 — true here, but attach the evidence.]** "Written
   every boot" is not automatic: pstore's console has no loglevel bypass
   (`fs/pstore/platform.c:409-424` + `kernel/printk/printk.c:2989`,
   `:1282-1285`), so at `loglevel=1` nothing below KERN_EMERG reaches the PRZ
   until userspace raises `console_loglevel`; and `printk.always_kmsg_dump=1`
   is inert for ramoops (`printk.c:4731` honours it only when
   `max_reason == KMSG_DUMP_UNDEF`, but ramoops sets `KMSG_DUMP_OOPS` at
   `fs/pstore/ram.c:958`), so a clean reboot writes **no** dmesg record at all.
   The argument holds because boot `-5` measurably emitted **77 867** messages
   at priority ≤ err with `console_loglevel = 4`, filling the 512 KiB console
   PRZ many times over, ended in a clean `systemd-shutdown`, and boot `-4` came
   up **one second later** to an empty `/sys/fs/pstore`. Guaranteed writer,
   guaranteed reader, whole-zone coverage, no sampling.
2. **No bad-ECC complaints.** At the *previous*, high-DRAM address the patch
   used, every boot logged "bad ECC headers" — ramoops found the region full of
   garbage (retraining patterns) and rejected it. At the current low
   `0x118000` we get silent-empty with no ECC errors — ramoops finds no header
   at all, consistent with the region being **zeroed**. Different failure at
   different addresses, but both are "the contents did not make it across."

   **[strengthened 2026-07-24 — this argument is load-bearing and it is
   sound.]** With `ecc-size=16`, `persistent_ram_init_ecc()`
   (`fs/pstore/ram_core.c:512`) runs **before** the signature comparison at
   `:520`, so the 12-byte header + 16 parity bytes of *every* zone are
   Reed-Solomon decoded on *every* boot, unconditionally. Its failure messages
   are `pr_info("error in header, %d")` (`:246`),
   `pr_info_ratelimited("uncorrectable error in header")` (`:249`),
   `pr_info("found existing invalid buffer…")` (`:528`) and
   `pr_warn("ECC failed %s")` (`:514`) — all KERN_INFO or above, **none**
   `pr_debug`, and `KERN_INFO` from that same file demonstrably reaches the
   journal on these boots (`ramoops: using 0xd0000@0x118000, ecc: 16` *is*
   `pr_info`, `fs/pstore/ram.c:869`; `loglevel=1` gates the console, not the
   kmsg ring journald reads). Four boots × three zones = 12 header decodes,
   **zero complaints**. An all-zero block is the trivial RS codeword and
   decodes clean; random content, all-`0xFF` and a re-keyed scrambler all fail
   RS decode with overwhelming probability. So the region really does come back
   as **zeros written by something**, not as lost DRAM.

## Mechanism (inferred): RK3588 rebuilds DRAM on every reset

On a PC a warm reboot leaves DRAM powered and in self-refresh, untouched. On
RK3588 a `SYSTEM_RESET` (what `panic=10` issues) resets the **whole SoC,
including the DDR controller and PHY**, so the boot chain
(BootROM → TPL `ddr` blob → SPL/U-Boot → TF-A → kernel) must **re-initialize
and re-train DRAM** on the way back up. That re-init is destructive: PHY
calibration / ZQ / read-write leveling write patterns into memory, and
resetting the DDR controller without a careful self-refresh handoff loses the
array. On this SoC a "reset" is closer to a mini power-on than to a PC's warm
reboot, so DRAM is effectively re-created, not carried over.

The debug patch moved ramoops to `0x118000` specifically because Rockchip's BSP
designates `0x110000–0x1f0000` as a survive-the-reset region (crash log /
reboot-reason / minidump). But survival there is **firmware cooperation**, not
a property of the address: the BSP's DDR blob + TF-A are built to preserve that
window across the reset. This board runs Armbian's stack
(`ddr-v1.20 / bl31-v1.48 / uboot-rmbian`), which empirically does **not** carry
that guard for this region. The patch inherited the address but not the
firmware behaviour that makes the address special — that is the gap.

## 2026-07-21 follow-up: audit of the installed u-boot (BSP protection is passive, and our build has it too)

Audited the exact source of the installed `linux-u-boot-rock-5b-current 26.5.1`
(extracted at `~/Code/rock-5b/build/u-boot/rock-5b-armbian-26.5.1-u-boot`; Armbian builds
`radxa/u-boot` branch `next-dev-v2024.10`, which **is** the Rockchip BSP u-boot
lineage — the `androidboot.fwver=` on our cmdline is that tree's own stamp).

How the BSP "protects" the window — all of it present in our build:

- `arch/arm/mach-rockchip/param.c:146` `param_parse_common_resv_mem()`: on
  ARM64 the range **1 MB–2 MB is reserved as `MEM_SHM`** (aliases "ramoops",
  "minidump", `arch/arm/mach-rockchip/memblk.c:44`) via
  `board_bidram_reserve()`. It is a *passive* keep-out for u-boot's own image
  placement — no preservation logic, no self-refresh handoff.
- The whole memory map already avoids 1–2 MB: SPL at `0x0–0x40000` (BSS/stack
  at `0x3fe0000`), u-boot proper at `0x200000`, ATAGS at 2 MB−8 KB,
  `kernel_addr_r=0x400000` — `include/configs/rk3588_common.h` even carries a
  comment naming "share memory region 0x100000~0x200000" as the reason the
  decompressed kernel starts at 4 MB.
- rkbin BL31 (v1.54 ELF inspected) loads at `0x60000–0xd1000` + `0xf0000–0xf6000`
  — below 1 MB, clear of the window.
- `CONFIG_PSTORE` in this u-boot (off in both Armbian `current` and `vendor`
  builds, and **also off in Radxa's own `rock-5b-rk3588_defconfig`**) only adds
  *u-boot's log* to the buffer; likewise the rkbin ddrbin params
  (`pstore_base_addr`, `tpl_log_en`, … — `rkbin/tools/ddrbin_tool_user_guide.txt`)
  make the *DDR blob's log* land there ("last log"). Neither is a preservation
  mechanism; BSP persistence rests on "nothing touches 1–2 MB + DRAM retains
  content across the short reset".

Consequence: **no component of our up-path (TPL blob / SPL / BL31 / u-boot)
statically writes 0x110000–0x1f0000**, and the reservation the BSP relies on is
compiled into the u-boot we already run. So "Armbian firmware lacks the guard"
(the inference above) is wrong in its strong form — either something clears the
window dynamically, or the content decays/scrambles across the reset, or the
kernel-side ramoops init (with `ecc-size=16`, it *zeroes* zones whose
header/ECC fails validation) destroyed the evidence before we looked — the
observed "silent zeros" is exactly what a post-zap read would show.

`kernel-drivers/scripts/debug-kernel/ramoops-persistence-probe.sh` settles it:
boot with `initcall_blacklist=ramoops_init`, stamp patterns across the window
via `/dev/mem`, warm-reboot, classify INTACT / CORRUPTED / ZEROED / GARBAGE.
INTACT/CORRUPTED → fix is kernel-side (likely drop `ecc-size=16`); ZEROED →
hunt the dynamic clearer (different rkbin DDR blob / ddrbin pstore config);
GARBAGE → DRAM truly lost, off-board capture is the only path.

(Probe implementation note: on arm64 `read()`/`write()` on `/dev/mem` reject
any `MEMBLOCK_NOMAP` range — `valid_phys_addr_range()`,
`arch/arm64/mm/mmap.c` — so `dd` gets EFAULT on the window; only `mmap()`
works, gated by `devmem_is_allowed()` which permits non-System-RAM pages.)

## 2026-07-22 probe result: the window is actively ZEROED across a warm reset

**MEASURED.** With `initcall_blacklist=ramoops_init` active on *both* boots
(verified: `initcall ramoops_init blacklisted` in the kernel log, no ramoops
platform driver, no `/dev/pmsg0`), all six stamped offsets
(0x118000/0x138000/0x158000/0x198000/0x1d8000/0x1e7000) read back
read-back-verified before a `reboot` warm reset — and came back **ZEROED**,
uniformly, after it.

What this rules out and rules in:

- **Not the kernel's ECC zap** — the ramoops driver never ran in either boot,
  so the `ecc-size=16` zap hypothesis from the 2026-07-21 follow-up is dead.
  Dropping `ecc-size` will not help.
- **Not bit decay / training scramble** — that would read as GARBAGE. Uniform
  zeros across 832 KiB mean **something in the boot chain deliberately writes
  zeros over the window on the way up**.
- u-boot's own code has no bulk clearer for the region (audited above; the
  only DRAM memsets are ATAGS at 2 MB−8 KB and small structs). TPL/SPL/BL31
  are the remaining candidates, and the prime suspect is ~~**BL31's
  share-memory pool init**: the 1–2 MB region is BL31's `SIP_SHARE_MEM`
  allocation pool (`sip_smc_request_share_mem()` hands out pages from it),
  and BL31's SCMI shmem at `0x10f000` — directly below the window, declared
  in the mainline DT and used by the kernel's clock driver every boot —
  proves BL31 actively manages this area on this stack. BL31 is a closed
  rkbin blob (`bl31-v1.48`), so this can't be confirmed in source.~~

  **[corrected 2026-07-24 — BL31 is exonerated.]** The share-memory pool is
  **64 KiB at `0x100000–0x10ffff`** (`plat/rockchip/rk3588/rk3588_def.h:155-158`
  in upstream TF-A), ending *exactly* where the window begins at `0x110000` —
  it cannot reach it. No `memset`/`zeromem` of DRAM appears in any of the 50
  `plat/rockchip` source files. The "1–2 MB" figure above was U-Boot's
  unrelated `MEM_SHM` keep-out, conflated with BL31's pool. The remaining
  candidates are the **TPL DDR blob** and **SPL** — both closed, neither
  disassembled.

Consequence: **no address inside 1–2 MB can work under this firmware**, and
the BSP's choice of 0x110000 presumably works on BSP stacks only because
their BL31/kernel share-mem handshake preserves it (or BSP pstore tolerates
it). The next question is whether the zeroing is specific to the share-mem
pool or DRAM-wide. `ramoops-probe-nomap.dts` (same directory) adds 64 KiB
no-map islands at 1 GB / 2 GB / 6 GB; install with
`sudo armbian-add-overlay ramoops-probe-nomap.dts`, reboot, then run the
probe with explicit offsets:
`ramoops-persistence-probe.sh write 0x40000000 0x80000000 0x180000000`,
warm-reboot, `read` with the same offsets.

- Any island INTACT/CORRUPTED → move the ramoops reservation there in the
  debug-kernel DT patch and ramoops works (plain, without ecc if CORRUPTED).
- All ZEROED/GARBAGE → DRAM-wide destruction (DDR blob scrub or retraining);
  off-board capture (netconsole / ttyS2 serial) is the only path.

## 2026-07-22 island probe result: nothing recovered at 1 GB / 2 GB / 6 GB either

*(Section title corrected 2026-07-24 — it read "DRAM-wide destruction — ramoops
is dead on this stack". The probe does not establish DRAM-wide loss; see the
correction below.)*

**MEASURED**, and it closes the question. With the islands installed and a
verified-clean warm reboot (systemd shutdown → back up 2 s later, no
power-cycle):

- `0x40000000` (1 GB): **ZEROED**
- `0x80000000` (2 GB): **GARBAGE** (4096/4096 bytes differ)
- `0x180000000` (6 GB): **GARBAGE** (4096/4096 bytes differ)

~~100%-of-bytes garbage at two widely separated addresses means DRAM content
is not readable after a warm reset *anywhere* — consistent with the DDR
controller's data scrambling being re-keyed (or retraining trashing the
array) on every re-init. The zeroing observed at 1 GB and in the 1–2 MB
window are just local actors (some boot-stage workspace; BL31's share-mem
pool) on top of that global loss. The rkbin `ddrbin_tool` exposes no
scramble/persistence knob (only skew, frequency, and log parameters), so
there is no supported firmware configuration that changes this.~~

**[corrected 2026-07-24 — three errors in the paragraph above.]**

- **"100 %-of-bytes garbage" is uninterpretable as stated.** The reference
  block is 4096 bytes of repeating printable ASCII with only 32 distinct
  values, so uniform-random content would coincidentally match ~16 of 4096
  bytes (P(zero matches) = 1.09e-7). The reading therefore excludes *random*
  content — but **not** a power-loss ground state: at realistic bit-flip
  rates (≤1 %), long `0x00`/`0xFF` runs give zero ASCII matches for 88–100 %
  of pages. And the `ZEROED` classifier demands an *exact* all-NUL page, so a
  single stray byte reclassifies near-zero content as "GARBAGE 4096/4096".
  **1 GB, 2 GB and 6 GB may all be the same zeroed outcome**; the two
  "GARBAGE" pages were never hexdumped, so their content is genuinely unknown.
- **Data scrambling is not the mechanism.** RK3588 TRM V1.0 Part 2 §2.3.3
  states the Scramble module "is defaultly bypassed"; rkbin has no scramble
  knob, doc or string for RK3588, and the BSP kernel has no scrambling code.
  The absence of a knob was read as "fixed-on"; it is equally consistent with
  "the feature is not in use".
- **"No supported firmware configuration changes this" is unsupported.** That
  rested on one grep over two rkbin text files. Swapping the DDR blob and BL31
  to the versions Radxa ships, or to the BSP-era loader, is untested and
  coherent — and our `ddr-v1.20 + bl31-v1.48` is *newer* than every BSP image
  (Radxa ships `ddr-v1.15`/`v1.16 + bl31-v1.45`) and is a pairing Rockchip's
  own release note calls unsupported (v1.20 requires bl31 ≥ v1.53).

**Verdict, as corrected: no address inside `0x110000–0x1f0000` survives a warm
reset on this board + firmware stack, and three sampled pages elsewhere did not
either — but DRAM-wide loss is *not* established** (3 islands × one 4 KiB page
each, all at the island's lowest offset, one reset, never repeated: 6.25 %
coverage per island). **Crash capture must be off-board today** — netconsole
(wired) or ttyS2 serial (1500000 baud), per the Consequences section below.
~~How the Rockchip BSP Android stack makes 0x110000 persist remains unknown.~~
**[corrected 2026-07-24]** The right statement is: *nobody has shown that it
does.* Rockchip provisions and documents the window as cross-reset storage in
shipped products, but no artifact of a recovered `dmesg-ramoops-0` or
`console-ramoops-0` on any RK35xx was found in English or Chinese sources — and
because every BSP node omits `ecc-size`, a broken BSP ramoops would fail
completely silently. The zero-writer on our stack is still unidentified and
lives in a closed blob (TPL or SPL; U-Boot proper and BL31 are ruled out by
source audit).

Cleanup after the experiment: remove `initcall_blacklist=ramoops_init`
from `extraargs` and `ramoops-probe-nomap` from `user_overlays` in
`/boot/armbianEnv.txt`, delete `/boot/overlay-user/ramoops-probe-nomap.dtbo`,
and optionally `rm -r /var/tmp/ramoops-probe`.

## Boundary / what is not yet known

- ~~**Full-DRAM-loss vs targeted-clobber: RESOLVED 2026-07-22 — it is both.**
  The island probe (above) measured garbage at 2 GB and 6 GB after a clean
  warm reset: the whole array is unreadable after re-init, with additional
  targeted zeroing of the 1–2 MB window and the 1 GB area. No address
  survives; only off-board capture works.~~
  **[corrected 2026-07-24 — still open.]** The window at
  `0x110000–0x1f0000` is settled (zeroed, three ways). Whether the rest of DRAM
  survives is **not**: the island probe sampled one 4 KiB page per island, at
  the lowest offset, once, and never hexdumped the two non-zero results. Re-run
  it instrumented (hexdump the first 256 bytes, several offsets per island,
  repeat) before treating DRAM-wide loss as fact.
- The DDR/TF-A/U-Boot versions are specific to this Armbian firmware; a
  different bootloader (e.g. genuine Rockchip BSP U-Boot, or a mainline TF-A
  build that reserves the window) could change the result. **As of 2026-07-24
  this is the leading remaining explanation**: our `ddr-v1.20 + bl31-v1.48` is
  newer than every shipped BSP image and is an unsupported pairing.
- **Untested and cheap**: a complete BSP kernel + BSP DT (`ramoops@110000`, no
  `no-map`, no `ecc-size`, plus `pmic-reset-func = <1>`) is already installed on
  this board as `linux-image-vendor-rk35xx 6.1.115`. Booting it holds our
  firmware constant and isolates the kernel/DT side — see the experiment runbook
  in [`2026-07-24-bsp-vs-armbian-ramoops-gap.md`](2026-07-24-bsp-vs-armbian-ramoops-gap.md).

## Consequences / how to actually capture a crash here

- **Do not rely on ramoops/pstore for crash capture on this board.** The
  debug-kernel workflow's "read `/sys/fs/pstore`" step will keep coming up
  empty. `journalctl -b -1` still gives the *pre-crash* tail and often the oops
  *header* line, but the call trace is lost (journald cannot flush during the
  crash, and ramoops does not survive to hold it).
- **Off-board capture is the reliable path**, because it gets the trace out
  before the board resets: a **serial console** on `ttyS2` (1500000 baud, needs
  a USB-TTL adapter on a second machine — immune to DRAM/reset entirely), or
  **netconsole** streaming kernel printk over the network to a listener
  (prefer wired ethernet; WiFi can wedge during a crash). Either records the
  full oops as it is printed, independent of DRAM persistence.
- **When a crash does happen, still let `panic=10` self-reboot rather than
  power-cycling** — not for ramoops (it will not survive anyway) but so the
  reboot is clean and the *next* boot's journal/state is intact.

Corrects the optimistic premise in
`kernel-drivers/patches/debug-kernel/0001-arm64-dts-rockchip-add-persistent-ramoops-to-rock-5b.patch`
("the low persistent range … survives reset"): it does not survive on this
Armbian stack. ~~It survives only under BSP firmware.~~ **[corrected
2026-07-24]** That it survives under BSP firmware is an assumption inherited
from the Rockchip DT comment, not something anyone has demonstrated — see
[`2026-07-24-bsp-vs-armbian-ramoops-gap.md`](2026-07-24-bsp-vs-armbian-ramoops-gap.md).
