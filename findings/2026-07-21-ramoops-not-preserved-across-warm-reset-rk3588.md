# ramoops/pstore does not survive a warm reset on this ROCK 5B: RK3588 re-inits DRAM on every reboot

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
2. **No bad-ECC complaints.** At the *previous*, high-DRAM address the patch
   used, every boot logged "bad ECC headers" — ramoops found the region full of
   garbage (retraining patterns) and rejected it. At the current low
   `0x118000` we get silent-empty with no ECC errors — ramoops finds no header
   at all, consistent with the region being **zeroed**. Different failure at
   different addresses, but both are "the contents did not make it across."

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

## Boundary / what is not yet known

- **Full-DRAM-loss vs targeted-clobber is unresolved.** Either the DDR-controller
  reset drops the whole array (then *no* ramoops address can work here — only
  getting the trace off-board can), or only this low ~1.1 MB window is
  clobbered (SPL/U-Boot/TF-A all load and run in low memory, right where
  `0x118000` sits), in which case some other reserved region might survive.
  Distinguishing needs a multi-address ramoops sweep across reboots, or reading
  what the `ddr` blob / TF-A do to low memory — firmware-level work the running
  kernel cannot answer. Prior leans toward "no address is a safe bet," because
  the DDR-controller-reset mechanism is address-agnostic, but that is not
  proven.
- The DDR/TF-A/U-Boot versions are specific to this Armbian firmware; a
  different bootloader (e.g. genuine Rockchip BSP U-Boot, or a mainline TF-A
  build that reserves the window) could change the result.

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
("the low persistent range … survives reset"): it survives only under BSP
firmware, not this Armbian stack.
