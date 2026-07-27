# Why BSP ramoops "works" at 0x110000 and ours does not — consolidated answer, and a correction to our own record

> Scope: ROCK 5B (this board), Armbian firmware `ddr-v1.20-b8ce94f14b / bl31-v1.48 /
> uboot-rmbian-201-06/05/2026`, kernels `6.18.38-current-rockchip64` (ramoops debug
> build), `6.18.38-ysp-rockchip64` (running), `6.1.115-vendor-rk35xx` (BSP, installed
> but not booted). Compared against: Radxa Debian bookworm r6 (`6.1.84-8-rk2410`),
> Radxa Android 12 rkr14 (2024-04) and rkr10 (2022-11), Radxa maskrom loader
> `v1.15.113`, Radxa SPI image `gd1cf491` (2024-05).
> Source: 8 parallel investigation lanes + 4 adversarial verification passes,
> `analysis/L1..L8`, `analysis/verify-H1/H2/H3`, `analysis/completeness-critic.md`;
> Rockchip BSP kernel `rockchip-kernel@b4ef083dc0c3` (6.1.141), mainline
> `~/Code/kernel/linux`, `~/Code/kernel/linux-6.18-rkvenc`, u-boot
> `~/Code/u-boot/rock-5b-armbian-26.5.1-u-boot` (radxa/u-boot `39cd993`),
> `~/Code/u-boot/rkbin@02931bbd` (radxa `develop-v2026.01`), RK3588 TRM V1.0 Part1/2,
> RK806 Datasheet Rev 1.3, ROCK 5B v1.4.5 schematic.
> Date: 2026-07-24
> Trust: **MEASURED** (all live-board journal/DT/dpkg reads, every blob/DTB/config
> extraction, the ECC-silence result) / **SOURCE-INSPECTED** (kernel, TF-A, U-Boot,
> TRM, datasheet) / **INFERRED** (the identity of the zero-writer) / **UNVERIFIED**
> (that BSP ramoops has ever actually retained a record on any RK3588).

---

## Result — the short version

Three things, in decreasing order of confidence.

1. **MEASURED, and now confirmed by a second independent mechanism: on this
   firmware stack the ramoops window at `0x118000–0x1e7fff` comes back
   *all-zero* after a warm reset.** Not decayed, not scrambled, not random —
   zeroed. Nothing can persist there, and no DT tweak (dropping `no-map`,
   dropping `ecc-size`, moving to `0x110000`, copying the BSP node byte for
   byte) can recover a signature word that is not in DRAM.

2. **UNVERIFIED, and this is the honest headline: nobody has ever demonstrated
   that BSP ramoops retains anything across a reset on RK3588.** Not us, not any
   of the eight lanes, not any public artifact in English or Chinese, not any
   Rockchip document. What exists is *provisioning* (DT nodes, kernel configs,
   firmware parameters, a Rockchip release note calling previous-boot pstore loss
   a bug) — i.e. Rockchip clearly *designs for* cross-reset persistence — but zero
   evidence of a recovered `dmesg-ramoops-0` or `console-ramoops-0` on this SoC.
   **The premise of the question is not established.**

3. **INFERRED: if there is a real BSP-vs-us delta, the surviving candidate is the
   rkbin blob generation, not the kernel, the DT, the PMIC, or the reset path.**
   Every kernel-side, DT-side, reset-path and PMIC-side hypothesis was killed with
   direct evidence (§3). Our firmware is *newer* than every BSP image examined
   (ddr v1.20 + bl31 v1.48 vs the v1.08–v1.16 / bl31 v1.45 generation BSP images
   ship), and Rockchip documents our exact pairing as unsupported (v1.20's release
   note requires bl31 ≥ v1.53). The zero-writer lives in one of TPL/SPL/BL31 —
   all closed blobs, none audited.

The cheapest decisive experiment was missed by every lane and needs **no SD card,
no download and no flashing**: a complete Rockchip BSP kernel + BSP DT (with
`ramoops@110000` *and* `pmic-reset-func = <1>`) is **already installed on this
board** and is bootable by repointing three symlinks. See §5, EXP-2.

---

## 1. Does BSP ramoops on RK3588 actually work, and under what conditions?

**Answer: unproven. Not "yes", not "no".** State it that way in the repo.

### 1.1 What is provisioned (MEASURED)

Rockchip and Radxa ship the window configured for cross-reset use, consistently,
across four independently-extracted product images:

| Image / tree | ramoops node | cross-reset zones | boot-log zone |
|---|---|---|---|
| BSP source `rk3588-linux.dtsi:92-108` | `ramoops@110000 reg=<0 0x110000 0 0xe0000>` | record 0x14000, console 0x80000, pmsg 0x30000 | `boot-log-size=0x8000` (`/* do not change */`) |
| Radxa Debian r6 shipped DTB (`verify-2/radxa-r6.dts:11378`) | same | same | present but **inert** (`# CONFIG_PSTORE_BOOT_LOG is not set`) |
| Armbian vendor DTB on *this disk* (`/boot/dtb-6.1.115-vendor-rk35xx/.../rk3588-rock-5b.dtb:11451`) | same | same | present but inert |
| Radxa Android rkr14 DTB (`verify-0/rkr14.dts`) | same | same | **active** (`CONFIG_PSTORE_BOOT_LOG=y`) |
| Radxa Android rkr10 DTB (`verify-0/rkr10.dts:11044`) | `ramoops@110000 reg=<0 0x110000 0 0xf0000>` | record 0x20000, console 0x80000, pmsg 0x50000 | **none — feature did not exist** |

Verified myself on the live board:

```
$ dtc -I dtb -O dts /boot/dtb-6.1.115-vendor-rk35xx/rockchip/rk3588-rock-5b.dtb
11451:  ramoops@110000 {
11452:    compatible = "ramoops";
11453:    reg = <0x00 0x110000 0x00 0xe0000>;
11454:    boot-log-size = <0x8000>;   boot-log-count = <0x01>;
11456:    console-size = <0x80000>;   pmsg-size = <0x30000>;
11458:    ftrace-size = <0x00>;       record-size = <0x14000>;
6265:     pmic-reset-func = <0x01>;    (inside rk806single@0)
```

The rkr10 row is decisive against the "it's really just a same-boot firmware-log
handoff" reading (hypothesis H1, adjudicated **refuted**): a 2022 shipped Radxa
product reserves **960 KiB at 0x110000 that is 100 % dmesg + console + pmsg**, with
`CONFIG_PSTORE_CONSOLE=y`, `CONFIG_PSTORE_PMSG=y`, `CONFIG_PANIC_TIMEOUT=5`
(`verify-0/rkr10-config:6202-6205,6761`) — every one of those zones is meaningless
unless bytes survive a reset — on a loader whose DDR blob is v1.08 with the ddrbin
pstore word **zeroed** (`reserved_0 = 0x00000000`), i.e. predating the boot-log
feature entirely (it arrives at RK3588 ddr v1.09 / bl31 v1.30). The address was a
cross-reset ramoops window *before* the firmware-log handoff existed.

Corroborating, SOURCE-VERIFIED: `rkbin/doc/release/RK3568_CN.md:280` logs, as a
severity-重要 *fixed defect*, "DDR ECC使能时重启后**上一次开机的**pstore信息丢失"
— "with DDR ECC enabled, **the previous boot's** pstore information is lost after
restart". The English edition (`RK3568_EN.md:281`) drops the "previous boot"
qualifier, which is what made this ambiguous earlier. Rockchip treats cross-reset
pstore loss as a firmware bug. Likewise `rk_mini_dump.c:488-518` in the U-Boot **we
already run** reads a control struct the *previous* Linux wrote at `0x1f0000` and
`memcpy`s that dead kernel's `p_paddr` regions out, and `BOOT_WINUSB` is commented
"reboot by panic and capture ramdump in uboot through usb".

### 1.2 What is *not* demonstrated (MEASURED absence)

- No lane found a single public artifact — forum post, bug report, blog, CSDN
  article — showing recovered pstore *content* after a reset on any RK35xx. Only
  boot-time registration lines (`ramoops: using 0xf0000@0x110000, ecc: 0`). Direct
  fetches of the elecfans RK3588 thread and the OpenWrt NanoPi R6C thread confirm
  this; the OpenWrt thread is marked "Resolved" but posts no recovered file.
- There is **no Rockchip pstore/ramoops developer guide** anywhere in the public
  RKDocs mirrors (full `docs_list.txt` enumerated).
- Radxa's own mainline-track kernel (7.0.11, `~/Code/kernel/radxa-kernel`) **dropped
  the ramoops node** for rk3588 entirely.
- Radxa Debian r6 cannot even auto-reboot on panic (`# CONFIG_PANIC_ON_OOPS is not
  set`, `CONFIG_PANIC_TIMEOUT=0`, no `panic=` on its cmdline), so on that image the
  crash path is untestable without a reset button press. Only the Android images
  (`CONFIG_PANIC_TIMEOUT=5`) auto-reboot.
- With `ecc-size` absent from every BSP node, a BSP kernel that finds the window
  garbage says **nothing**: `ram_core.c:537` logs `pr_debug("no valid data in
  buffer")`, rewrites the signature and zaps. Silent empty `/sys/fs/pstore`, no
  error. A broken BSP ramoops on RK3588 would be trivially easy not to notice.

### 1.3 What would prove it

**EXP-3 in §5**: boot the official Radxa Debian r6 image from SD on this exact
board, confirm the ramoops registration line, `reboot` once cleanly, and look for
`console-ramoops-0`. Because `CONFIG_PSTORE_CONSOLE=y` on that image mirrors printk
into a 512 KiB PRZ continuously, **a clean reboot alone is a sufficient test** — no
crash needed. Empty ⇒ BSP ramoops does not work on RK3588 either and the entire
BSP-vs-us framing dissolves. Populated ⇒ the gap is real, and EXP-2 (which holds
firmware constant) tells you which side of the kernel/firmware line it lives on.

---

## 2. Itemised BSP/Radxa vs. our stack — every difference found

"Explains persistence?" is judged against the one thing that matters: could this
difference cause DRAM contents at 0x110000–0x1f0000 to survive, or not survive, a
warm reset?

### 2.1 Firmware

| Component | Ours (this board) | Radxa Debian r6 | Radxa loader v1.15.113 | Radxa SPI img 2024 | Android rkr14 (2024) | Android rkr10 (2022) | Explains persistence? |
|---|---|---|---|---|---|---|---|
| DDR blob | **v1.20 `b8ce94f14b`** (2025-09-26) | v1.22 `d4bf75a5a6` (2026-07-23) | v1.15 `d5483af87d` | v1.16 `9fffbe1e78` | V1.13 `25cee80c4f` | V1.08 (2022-06) | **MAYBE — the one live candidate.** Closed blob; the only unaudited actor that runs before every boot and can write anywhere in DRAM. Ours is newer than every BSP image except r6's. |
| BL31 | **v1.48** (ATF v2.3-868) | v1.54 (v2.3-964) | — | v1.45 | v2.3-639 | v2.3-405 | **PROBABLY NOT.** v1.48 disassembled: image occupies 0x40000–0xBE000 + 0xF0000–0xF6000 + 0xFF100000; SIP share pool is 64 KiB at 0x100000–0x10FFFF (`rk3588_def.h:155-158`), ending exactly where ramoops begins. `rockchip_soc_soft_reset` @0x602a0 = PLL slow-mode stores + `str 0xfdb9 → 0xfd7c0c08` + `wfi`. No memset of DRAM in any of 50 `plat/rockchip` files. |
| Blob pairing | **v1.20 + v1.48 — Rockchip documents this as unsupported** (`rkbin/doc/release/RK3588_EN.md:72`: "bl31 must be updated to version 1.53 or later"); Armbian pins it at `rockchip64_common.inc:165-166` | v1.22 + v1.54 (supported) | — | — | — | — | **MAYBE.** Note the release-note text scopes the requirement to "2 channel DDR", which a 4-channel ROCK 5B does not use. Cheap to A/B (EXP-5). |
| ddrbin pstore params | `pstore_base_addr=0x11` (→0x110000), `pstore_buf_size=0x8` (→0x8000), all five `*_log_en=1` | same addr/size, **all five `log_en=0`** ("pstore is disabled by default", v1.22 note) | identical to ours | — | `reserved_0=0x0011801f` — **byte-identical to ours** | `reserved_0=0x00000000` | **NO.** Re-measured on all three blobs. There is no BSP-only preservation flag to port. Affects only the 32 KiB ring at 0x110000–0x118000, which our node deliberately sits above. |
| DDR scrambling | not in use | not in use | — | — | — | — | **NO.** RK3588 TRM Part2 §2.3.3: the Scramble module "is defaultly bypassed". Zero `scrambl` hits across all of rkbin. |
| DDR link ECC | `link_ecc_en=0` (measured) | — | — | — | — | — | **NO.** Rules out the RK3568 "ECC init loses the pstore segment" mechanism for us. |
| U-Boot | radxa/u-boot **`39cd993`**, artifact `2017.09-S39cd-…` | u-boot-rk2410 **`2017.09-64-39cd993`** | SPL 2017.09-ge4e1249 | SPL 2017.09-gd1cf491 | 2017.09-ge7ca8ec2 | — | **NO.** *Same source revision.* The two control DTBs are byte-equivalent modulo node ordering (`verify-2/uboot-control.dts`). Both are BSP-lineage 2017.09 despite the branch name. |
| U-Boot `CONFIG_PSTORE` | not set | not set (`rock-5b-rk3588_defconfig`) | — | — | set (`rk3588_defconfig`, EVB build) | — | **NO** for the Linux images; only Rockchip's own EVB config enables it. |
| U-Boot 1–2 MB keep-out | present (`param.c:146`, `MEM_SHM` aliased "ramoops"/"minidump") | present (same source) | — | — | — | — | **NO.** Passive keep-out, identical on both. |
| PMIC `RST_FUN` programmed? | **no** (neither kernel nor U-Boot writes SYS_CFG3[7:6]) | **yes**, `pmic-reset-func = <1>` in DT → BSP `rk806-core.c:778-783` | — | — | yes | yes | **NO — refuted, see §3.2.** |

### 2.2 Device tree reserved-memory node

| Property | Our debug patch (`0001-…ramoops…patch`) | BSP (all four images + vendor DTB on this disk) | Explains persistence? |
|---|---|---|---|
| base / size | `0x118000` / `0xd0000` (832 KiB) | `0x110000` / `0xe0000` (960 KiB) | **NO.** Both outside System RAM (first DRAM bank starts at `0x200000`, decoded from `/sys/firmware/devicetree/base/memory/reg`), both take `persistent_ram_iomap()`. Our offset deliberately clears the 32 KiB firmware ring. |
| `no-map` | **present** | absent | **NO.** Changes `/dev/mem` `read()`/`write()` access and `/proc/iomem` visibility, nothing about retention. (Note: L1's stated mechanism — `pfn_valid()` true via `memmap_init_reserved_pages()` — is *wrong for this address*, since there is no `struct page` below 0x200000 at all. Same conclusion, wrong reasoning.) |
| `ecc-size` | **16** | absent | **NO for persistence — but it is the reason we can measure anything.** See §3.1. |
| `record-size` | 0x40000 | 0x14000 | NO |
| `console-size` | 0x80000 | 0x80000 | NO |
| `pmsg-size` | 0x10000 | 0x30000 | NO |
| `boot-log-size/count` | absent (mainline has no such property) | 0x8000 / 1 | **NO** on Linux BSP images (`CONFIG_PSTORE_BOOT_LOG` not set → parsed by nobody). Active only on Android rkr14. |

Resulting zone layouts (computed from `fs/pstore/ram.c:897-950`, verified against the
live `ramoops: using 0xd0000@0x118000` line):

- **ours**: `dmesg-0` @0x118000 (0x40000), `console` @0x158000 (0x80000), `pmsg` @0x1d8000 (0x10000) → ends 0x1e8000.
- **BSP w/ BOOT_LOG off** (Radxa r6, Armbian vendor 6.1.115): `dmesg-0` @0x110000 (0x18000), `dmesg-1` @0x128000 (0x18000), `console` @**0x140000** (0x80000), `pmsg` @0x1c0000 (0x30000) → ends 0x1f0000. Note the BSP's `dmesg-0` sits **directly on top of** the firmware log ring at 0x110000–0x118000, which our patch avoided; its `console` zone does not.
- **BSP w/ BOOT_LOG on** (Android rkr14): `boot-log` @0x110000 (0x8000), then `dmesg-0`/`dmesg-1`/`console`/`pmsg`.

### 2.3 Kernel

| Item | Ours | BSP | Explains persistence? |
|---|---|---|---|
| `fs/pstore/ram_core.c` | mainline 6.18 | **byte-identical to upstream v6.1.141** (`git diff --stat 58485ff1a74f HEAD -- fs/pstore/ram_core.c` → empty) | **NO.** The entire "read back what the last boot wrote" contract is unmodified. |
| `drivers/of/of_reserved_mem.c` | mainline | unpatched (only 21 Kconfig lines under `drivers/of/`) | **NO** |
| `fs/pstore/ram.c` | mainline | +349 lines: `boot-log` pseudo-zone, `#ifndef CONFIG_ARCH_ROCKCHIP` disabling pow-2 rounding, extra `pr_info`, minidump cross-registration | **NO.** All feature/cosmetic. |
| PSTORE config | debug build: `PSTORE_RAM=y`, `CONSOLE=y`, `ecc-size=16` | r6: `PSTORE=y`, `CONSOLE=y`, `RAM=y`; `PMSG`/`FTRACE`/`BOOT_LOG`/`MINIDUMP` **not set** | **NO — ours is strictly stronger.** |
| Rockchip minidump | absent | `CONFIG_ROCKCHIP_MINIDUMP` set by **no** BSP defconfig, `# not set` in r6, all three DT nodes `status="disabled"` | **NO.** Inert everywhere. And it *preserves* nothing — it publishes physical addresses for a post-reset bootloader, so it presupposes the same persistence rather than providing it. |
| `reboot-mode` / `BOOT_PANIC` | absent (no node, no `/sys/kernel/boot_mode`) | patched `reboot-mode.c` stamps `0x5242C307` into PMU0_GRF+0x80 from a panic notifier | **PROBABLY NOT** — no `0x5242C3xx` constant found in the TPL blob, SPL v1.14 or BL31 v1.54; and it cannot explain loss across a plain `reboot`, where BSP would also write no flag. Not fully excluded (immediates can be movz/movk-built). |
| FIQ debugger console | absent (`console=ttyS2`) | `console=ttyFIQ0,1500000n8`, `CONFIG_ROCKCHIP_FIQ_DEBUGGER=y` | **NO** for persistence, but it *is* an in-band crash-capture path we lack. |

### 2.4 Reset path

| Item | Ours | BSP | Explains persistence? |
|---|---|---|---|
| restart handler priority | `psci_sys_reset_nb` 129 > `rockchip_restart_handler` 128 | **identical** (BSP `psci.c:325`, `clk.c:734/740`, `clk-rk3588.c:2504`) | **NO. Both stacks take the same reset.** |
| what BL31 does | `CRU_GLB_SRST_FST = 0xfdb9` @ `0xfd7c0c08` (2 sites in our v1.48 blob; **0** occurrences of `0xeca8`/SND anywhere in any RK3588 software) | same blob family | **NO** |
| `SYSTEM_RESET2` / `reboot=warm` | `plat_psci_ops.system_reset2 == NULL` in v1.48 (decoded at 0x693a0) ⇒ `PSCI_FEATURES` says NOT_SUPPORTED ⇒ silently falls back to plain `SYSTEM_RESET` | same | **NO — there is no reset flavour to select.** |
| FST vs SND | TRM Part1 §2.17.3: the delta is **GRFs and GPIOs only**; neither spares the DDR controller/PHY | same | **NO** |
| PMU reset | BL31 writes `CRU_GLB_RST_CON = 0xffdf` with `glbrst_trig_pmu_en/sel=1` — the global reset resets the PMU domain that holds DDR-IO retention state | same | **NO** (identical), but it explains why the hardware DDR fail-safe retention path is unreachable. |

### 2.5 Userspace

| Item | Ours | BSP Debian r6 | BSP Android | Explains persistence? |
|---|---|---|---|---|
| `systemd-pstore.service` | enabled, stock | enabled, stock, unmodified `pstore.conf` | n/a | **NO** |
| `/sys/fs/pstore` mount | systemd | systemd (not in fstab) | stock AOSP `init.rc` boilerplate — present even in rkr10 | **NO** |
| harvesting agent | none | **none** (no Radxa script in `rsetup`/`radxa-bootutils`/`radxa-system-config-*`) | patched `dumpstate` reads `console-ramoops-0` (14 refs), `pmsg-ramoops-0` (11 refs) and `boot-log-ramoops-0` (1 ref) in both rkr14 and rkr10 super.img | **NO**, but note: Android *is* a real consumer of the **cross-reset** zones. (L8's "zero consumers" grep searched `dmesg-ramoops`, a filename AOSP never emits.) |

---

## 3. The best-supported explanation, and what was killed

### 3.1 What is actually measured on our side (MEASURED, two independent mechanisms)

**(a) The 2026-07-22 probe**: with `initcall_blacklist=ramoops_init` verified active
on both boots, six offsets stamped across `0x118000–0x1e7000` via `/dev/mem`, warm
`reboot`, all six read back **ZEROED**.

**(b) NEW, and stronger — the kernel's own Reed-Solomon decoder agrees.** Re-verified
by me on the live board just now, boots `-5`/`-4`/`-3`/`-2` (2026-07-23, kernel
`6.18.38-current-rockchip64`):

```
$ journalctl -k -b -5 | grep -iE 'ramoops|error in header|invalid buffer|ECC failed|uncorrectable'
OF: reserved mem: 0x0000000000118000..0x00000000001e7fff (832 KiB) nomap non-reusable ramoops@118000
printk: legacy console [ramoops-1] enabled
pstore: Registered ramoops as persistent store backend
ramoops: using 0xd0000@0x118000, ecc: 16
   (…identical on -4, -3, -2; systemd-pstore.service skipped, /sys/fs/pstore empty, every boot)
```

Chain of custody, all checked in `~/Code/kernel/linux-6.18-rkvenc`:

- `persistent_ram_init_ecc()` is called at `fs/pstore/ram_core.c:512`, **before** the
  signature comparison at `:520`, so with `ecc-size=16` the 12-byte header + 16
  parity bytes of **every zone** are RS-decoded on **every boot**, unconditionally.
- Its failure messages are `pr_info("error in header, %d")` (`:246`) and
  `pr_info_ratelimited("uncorrectable error in header")` (`:249`), plus
  `pr_info("found existing invalid buffer…")` (`:528`) and `pr_warn("ECC failed
  %s")` (`:514`) — **KERN_INFO or above, none of them `pr_debug`**.
- `KERN_INFO` from that same file demonstrably reaches the journal on those boots:
  `ramoops: using 0xd0000@0x118000, ecc: 16` *is* `pr_info` (`fs/pstore/ram.c:869`)
  and it is there. `loglevel=1` gates the console, not the kmsg ring journald reads.
- 4 boots × 3 zones = 12 header decodes, **zero complaints**.

An all-zero block is the trivial RS codeword and decodes clean. Random content
(power loss, decay, a re-keyed scrambler, reuse as ordinary RAM) and all-`0xFF`
both fail RS decode with overwhelming probability. **Conclusion (MEASURED): the
window comes back as zeros written by something, not as lost DRAM.**

**(c) And a third, cleanest measurement, needing neither `/dev/mem` nor a
classifier**: boot `-5` emitted **77 867 kernel messages at priority ≤ err** with
`console_loglevel = 4`, filling and wrapping the 512 KiB ramoops console PRZ many
times. It ended in a clean `systemd-shutdown` at 09:56:15; boot `-4` came up **one
second later**, re-registered ramoops at the same address, and logged
`systemd-pstore.service … skipped, unmet condition check
ConditionDirectoryNotEmpty=/sys/fs/pstore`. Reproduced for `-3` → `-2`. Since an
ECC *data* failure does **not** zap (it is repaired inside `persistent_ram_save_old`
at `:534`) and the "existing empty buffer" early return at `:521` is excluded by a
demonstrably non-empty buffer, an empty pstore here requires **signature loss**.
Guaranteed writer, guaranteed reader, whole-zone coverage, no sampling.

### 3.2 What was killed, and by what

| Hypothesis | Verdict | Killed by |
|---|---|---|
| **RK806 PMIC `RST_FUN=0` power-cycles the DDR rails** (the most attractive lead; carried by three lanes and one forum thread) | **REFUTED** | *No trigger path exists on a ROCK 5B.* The datasheet lists five RST_FUN triggers (§4.1.4, `docs/rk806_ds.txt:1656-1707`) and all five are unreachable from a software reboot: PWRON is physical; PWRCTRL1/2/3_FUN POR is `0x0 = no effect` and **both** stacks additionally program all three pins to `pin_fun0`; `RESET_L` is a strictly two-node net (RK806 pin 40 RESETB ↔ RK3588 ball M31 = **NPOR**, an input-only power-on-reset source per TRM Fig 2-2) with no button/MCU/third driver on the ROCK 5B v1.4.5 schematic; the RK806 WDT is never enabled by either driver; and `DEV_RST` is never written (mainline registers `SYS_OFF_MODE_RESTART` only for RK809/RK817 and logs "pmic controlled board reset not supported" for RK806; our U-Boot has no PMIC node at all). Additionally **our own BL31 v1.48 double-disarms the only hardware route**: it writes `0x03ff0000` to `0xfd58800c` (PMU0_GRF_SOC_CON3), zeroing `pmic0/1_sleep_iout_sel` (value `4'h9` would be "Chip reset output"), and contains **zero** references to `0xfeb2` (SPI2) so it cannot address the RK806 at all. Finally, the cited NanoPi R6C prior art does not support it: mainline U-Boot has written `RST_FUN` for every RK806 board since `f172575d92cd` (2024-03) defaulting to `0b10`, so that user's "fix" moved `0b10 → 0b01` — **both non-rail-cycling modes** — and the author of the very commit they backported writes that RK806 reset mode "does nothing useful … the ways to reset the device … doesn't interact with the RK8xx PMIC and simply does a CPU reset". |
| **The BSP has a kernel-side persistence mechanism we lack** | **REFUTED** | `fs/pstore/ram_core.c` byte-identical to upstream v6.1.141; `of_reserved_mem.c` unpatched; BSP pstore config strictly weaker than ours. |
| **`no-map` and/or `ecc-size` break it** | **REFUTED** | Both stacks are outside System RAM (first bank at 0x200000) and take the same `persistent_ram_iomap()` path. `ecc-size` cannot zap on a *data* failure. And the probe result was obtained with `ramoops_init` blacklisted, so the driver never ran at all. |
| **Rockchip minidump is the mechanism** | **REFUTED** | Enabled by no BSP defconfig, `# not set` in r6, all DT nodes `status="disabled"`, absent from the shipped vmlinuz strings — and it preserves nothing, it presupposes persistence. |
| **A DDR-preserving second global soft reset (`GLB_SRST_SND`)** | **REFUTED** | TRM §2.17.3: FST/SND differ in GRFs+GPIOs only. `0xeca8` appears in **no** RK3588 software. U-Boot forces FST on ARM64 because "Rockchip 64bit SOC need fst reset for cpu reset entry". |
| **`reboot=warm` / PSCI `SYSTEM_RESET2`** | **REFUTED** | `plat_psci_ops.system_reset2 == NULL` in the v1.48 blob we run; no Rockchip platform in upstream TF-A implements it. |
| **BL31's share-memory pool zeroes the 1–2 MB window** (the prior finding's prime suspect) | **REFUTED** | Pool is 64 KiB at `0x100000–0x10FFFF` (`rk3588_def.h:155-158`), ending exactly at 0x110000. No `memset`/`zeromem` of DRAM in any of 50 `plat/rockchip` files. The 1–2 MB figure was U-Boot's unrelated `MEM_SHM` keep-out. |
| **DDR data scrambling re-keyed per boot** | **REFUTED** | TRM Part2 §2.3.3: the Scramble module "is defaultly bypassed". Zero `scrambl` matches in all of rkbin. |
| **The ddrbin has a BSP-only preservation flag** | **REFUTED** | `reserved_0 = 0x0011801f` is byte-identical across our v1.20, Radxa's v1.15 loader and Android rkr14's v1.13. |
| **U-Boot / SPL is different** | **REFUTED** | Same source revision `39cd993`; control DTBs byte-equivalent. |
| **Userspace difference** | **REFUTED** | Stock `systemd-pstore.service` on both; no Radxa harvest script. |
| **"It's really a same-boot firmware-log handoff; cross-reset ramoops is folklore"** (H1) | **REFUTED** | rkr10 (2022): 960 KiB of 100 %-cross-reset zones with **no** boot-log feature and a v1.08 blob with the pstore word zeroed. Plus the RK3568_CN release note ("上一次开机的pstore信息丢失" = previous boot's) and mainline `rk3566-lckfb-tspi.dts:32-38`, which has the same node with no boot-log concept in the tree at all. |
| **"Our negative result is unsound; ramoops may be recoverable"** (H2) | **REFUTED as stated** | The `4096/4096 differ` statistic excludes *uniform-random* content, but **not** power-loss ground state (simulated: at ≤1 % bit-flip rate, 88–100 % of pages give **zero** ASCII matches). And the console-PRZ signature loss in §3.1(c) is independent of the probe entirely. See §4 for the parts of H2 that *do* stand. |

### 3.3 What remains standing

**The zero-writer is unidentified, and it lives in a closed blob.** Ruled out by
source audit: U-Boot proper (only DRAM memsets are ATAGS at 2 MB−8 KB and small
structs), BL31 (static footprint + no memset). Remaining: the **TPL DDR blob** and
**SPL** — neither disassembled. The 1 GB island reading ZEROED is a hint that the
agent is not confined to the low window; the 2 GB / 6 GB islands were never
hexdumped so their content is genuinely unknown.

**The single coherent BSP-vs-us delta that survives is the rkbin blob generation.**
Our ddr v1.20 is newer than the v1.08/v1.13/v1.15/v1.16 blobs in every BSP product
image, and it is paired with a BL31 that Rockchip's own release note says is too old
for it. The counter-argument is real and should be stated: Radxa Debian r6 ships an
even *newer* v1.22, so "newer = destructive" would predict r6 is broken too —
which nobody has tested. That is exactly what EXP-3 settles.

---

## 4. Status of our prior finding (`2026-07-21-ramoops-not-preserved-across-warm-reset-rk3588.md`)

**Verdict: the operative conclusion stands and is now better supported than when it
was written. The explanation, the universality claim, and one supporting argument
are wrong and must be corrected in place.**

### 4.1 STANDS — strengthened

- "ramoops/pstore does not survive a warm reset at 0x118000–0x1e7fff on this
  firmware stack." **Confirmed three ways** (§3.1): probe ZEROED, ECC-decoder
  silence, and console-PRZ signature loss with 77 867 guaranteed writes and a clean
  1-second warm reboot.
- "The window comes back **zeroed**, not decayed." **Confirmed independently** by
  the ECC-silence result.
- "Something in the boot chain deliberately writes zeros over the window."
  **Confirmed.** Still true; the actor is still unidentified.
- "Off-board capture (netconsole / ttyS2 @1500000) is the reliable path." **Stands.**
- "u-boot's own code has no bulk clearer for the region." **Stands** (re-audited).
- The 2026-07-21 follow-up's correction of its own earlier "Armbian firmware lacks
  the guard" claim was right to make.

### 4.2 WRONG — correct these

| Prior text | Correction |
|---|---|
| "**Final verdict: no ramoops address can survive a warm reset on this board + firmware stack.**" | **Over-extrapolated.** Basis: 3 islands × 1 × 4 KiB page each, all at the island's lowest offset, one reset, never repeated, and the two "GARBAGE" results were never hexdumped. 6.25 % coverage of each island. State it as: *no address inside 0x110000–0x1f0000 survives; three sampled pages elsewhere also did not; DRAM-wide loss is not established.* |
| "consistent with the DDR controller's **data scrambling being re-keyed**" | **Unsupported and almost certainly wrong.** RK3588 TRM Part2 §2.3.3 says the Scramble module "is defaultly bypassed"; rkbin has no scramble knob, doc or string for RK3588; the BSP kernel has no scrambling code. The absence of a knob was read as "fixed-on"; it is equally consistent with "no such feature in use". |
| "**100 %-of-bytes garbage** … means DRAM content is not readable after a warm reset *anywhere*" | **Uninterpretable as stated.** The reference block is 4096 bytes of repeating printable ASCII with 32 distinct values. Uniform-random content would coincidentally match ~16 of 4096 bytes (P(zero matches) = 1.09e-7). That rules out random/scrambled. But it does **not** rule out power-loss ground state (long 0x00/0xFF runs → 88–100 % of pages give zero matches at realistic flip rates), and the `ZEROED` classifier requires an *exact* all-NUL page, so a single stray byte reclassifies near-zero content as "GARBAGE 4096/4096". **1 GB, 2 GB and 6 GB may all be the same zeroed outcome.** |
| "there is **no supported firmware configuration** that changes this. The rkbin ddrbin_tool exposes no scramble/persistence knob" | **Unsupported.** That conclusion rested on one grep over two rkbin text files. Untested and coherent: swapping the DDR blob and BL31 to the versions Radxa ships (EXP-5), or to the BSP-era loader (EXP-6). |
| "no bad-ECC complaints … consistent with the region being **zeroed**" — *and L4's later refutation of it* | **The original argument was right; the refutation of it was wrong.** L4 claimed the relevant `ram_core` messages are `pr_debug` and invisible at `loglevel=1`. Measured: they are `pr_info`/`pr_warn` (`:246`, `:249`, `:528`, `:514`), the strings are in the shipped vmlinuz, `CONFIG_REED_SOLOMON_DEC8=y`, and `pr_info` from the same file reaches the journal on the same boots. Restore the original argument, with this evidence attached. |
| "How the Rockchip BSP Android stack makes 0x110000 persist **remains unknown**" | **Reframe.** The right statement is: *nobody has shown that it does.* Rockchip provisions and documents the window as cross-reset storage in shipped products, but no artifact of a recovered pstore record on any RK35xx was found. |
| Implicit premise: "the console zone is written every boot, so a clean reboot must leave `console-ramoops-0`" | **True here, but not self-evident — attach the evidence.** pstore's console has no loglevel bypass (`platform.c:409-424` + `printk.c:2989`/`:1282-1285`), so at `loglevel=1` only KERN_EMERG reaches it until userspace raises `console_loglevel`; and `printk.always_kmsg_dump=1` is inert for ramoops (`printk.c:4731` honours it only when `max_reason == KMSG_DUMP_UNDEF`, but ramoops sets `KMSG_DUMP_OOPS` at `ram.c:958`), so a clean reboot writes **no** dmesg record. The argument survives only because boot `-5` measurably emitted 77 867 err-priority messages at `console_loglevel = 4`. |

### 4.3 Also wrong, elsewhere in the repo

`kernel-versions/bsp/troubleshooting.md:102` still advises recovering a ramoops dump
with "a **cold power-off** (not a warm reboot)". That is **physically backwards** —
a cold power-off removes DRAM power and forces a full DDR re-init; a warm reset is
the only path with any chance. It contradicts the finding, was never tested, and
should be fixed.

---

## 5. EXPERIMENT RUNBOOK (ordered: cheapest and safest first)

Board safety context: `/home/yi/Code/rock-5b-ysp/spi-backups/` holds two verified
16 MiB SPI dumps (`rock5b-spi-before-erase-20260707T024822Z.bin` and
`…T025242Z.bin`, each with a `.sha256`), so SPI is recoverable — but **no experiment
below requires writing SPI, eMMC or NVMe**, and none should.

---

### EXP-1 — Read RK806 SYS_CFG3 (2 minutes, ZERO risk, read-only)

Four lanes independently named this the cheapest decisive read and all four were
blocked by a missing sudo password. It is now mostly of archival interest (H3 is
refuted on mechanism), but it closes the last inferred premise.

```bash
sudo grep -i '^72' /sys/kernel/debug/regmap/spi2.0/registers
# or, if the path differs:
sudo ls /sys/kernel/debug/regmap/ && sudo cat /sys/kernel/debug/regmap/*rk806*/registers | head -140
```

**Proves:** whether `RST_FUN` (bits 7:6 of 0x72) is at the silicon default `0b00`
today. Predicted `0b00` (nothing writes it on our stack). Anything else means the
inference chain in §3.2 had a hole. **Risk: none.**

---

### EXP-1b — Does firmware actually write the 0x110000 ring? (5 minutes, ZERO risk, read-only)

```bash
sudo python3 - <<'PY'
import mmap, os
f = os.open("/dev/mem", os.O_RDONLY)
m = mmap.mmap(f, 0x8000, mmap.MAP_SHARED, mmap.PROT_READ, offset=0x110000)
d = m[:0x8000]
print("sig:", d[:4].hex(), "(DBGC = 44424743 little-endian 0x43474244)")
print(d[:512])
print("nonzero bytes:", sum(1 for b in d if b))
PY
```

**Proves:** whether the ddrbin/TPL/SPL/BL31 `*_log_en=1` bits actually produce a
`persistent_ram_buffer` at 0x110000 on *our* stack. Three lanes asserted "firmware
actively writes it every boot" purely from the config bits; nobody verified it.
Empty ⇒ the ring is not written and the whole ddrbin-pstore thread is moot.
**Risk: none** (read-only; `0x110000` is outside System RAM so `STRICT_DEVMEM`
permits the mmap; a `read()`/`dd` would EFAULT, use mmap).

---

### EXP-2 — Boot the BSP kernel already installed on this disk (30 minutes, MEDIUM risk) ★ HIGHEST VALUE

**This is the single-variable experiment the whole investigation has been missing,
and every lane missed it.** A complete Rockchip BSP stack is already present:

```
ii  linux-image-vendor-rk35xx  26.5.1   /boot/vmlinuz-6.1.115-vendor-rk35xx (47 MB)
ii  linux-dtb-vendor-rk35xx    26.5.1   /boot/dtb-6.1.115-vendor-rk35xx/
                                        /boot/uInitrd-6.1.115-vendor-rk35xx
                                        /lib/modules/6.1.115-vendor-rk35xx/ (depmod done)
```

Its DTB carries **both** halves of the alleged BSP recipe (verified above):
`ramoops@110000 reg=<0 0x110000 0 0xe0000>` with no `no-map` and no `ecc-size`,
**and** `pmic-reset-func = <0x01>` at line 6265. Its config is byte-for-byte the
same pstore posture as Radxa's shipped `config-6.1.84-8-rk2410`
(`PSTORE`/`PSTORE_RAM`/`PSTORE_CONSOLE=y`; `PMSG`/`FTRACE`/`BOOT_LOG`/`MINIDUMP`
off). Booting it swaps **only kernel + DT + PMIC mode**, holding our firmware
(`ddr-v1.20 / bl31-v1.48 / uboot-rmbian-201`) constant — unlike EXP-3, which swaps
seven variables at once.

Steps:

```bash
# 0. record current state so you can put it back
ls -l /boot/{Image,vmlinuz,uInitrd,initrd.img,dtb}
cp /boot/armbianEnv.txt /boot/armbianEnv.txt.bak-exp2

# 1. repoint the three symlinks armbian's boot.cmd:44-47 actually uses
sudo ln -sfn vmlinuz-6.1.115-vendor-rk35xx /boot/Image
sudo ln -sfn uInitrd-6.1.115-vendor-rk35xx /boot/uInitrd
sudo ln -sfn dtb-6.1.115-vendor-rk35xx     /boot/dtb
#    (fdtfile=rockchip/rk3588-rock-5b.dtb resolves inside the vendor dtb dir;
#     user_overlays is unset and /boot/overlay-user/ is empty, so nothing conflicts)

# 2. reboot, then confirm the BSP stack actually came up
uname -r                                  # expect 6.1.115-vendor-rk35xx
dmesg | grep -i 'pmic-reset-func'         # BSP driver prints "pmic-reset-func missing!"
                                          # if the property did NOT take — expect silence
dmesg | grep -iE 'ramoops|pstore'         # expect: dmesg-0 0x18000@0x110000,
                                          #         dmesg-1 0x18000@0x128000,
                                          #         console 0x80000@0x140000,
                                          #         pmsg    0x30000@0x1c0000

# 3. THE TEST — no crash needed. PSTORE_CONSOLE=y mirrors every printk
#    into the 512 KiB console PRZ continuously.
sudo dmesg -n 7          # make sure console_loglevel is high so the PRZ fills
logger -p kern.emerg "EXP2 marker $(date -Is)"   # optional: recognisable payload
sudo reboot
ls -l /sys/fs/pstore/    # LOOK FOR console-ramoops-0, not dmesg-ramoops-0

# 4. only if step 3 is empty, escalate to the crash path
sudo sysctl -w kernel.panic=10 kernel.panic_on_oops=1
sudo sh -c 'echo c > /proc/sysrq-trigger'
ls -l /sys/fs/pstore/    # LOOK FOR dmesg-ramoops-0

# 5. REVERT (do this even on success, before any other work)
sudo ln -sfn vmlinuz-6.18.38-ysp-rockchip64 /boot/Image
sudo ln -sfn uInitrd-6.18.38-ysp-rockchip64 /boot/uInitrd
sudo ln -sfn dtb-6.18.38-ysp-rockchip64     /boot/dtb
sudo reboot
```

**Proves:**
- `console-ramoops-0` populated ⇒ **the gap is real and lives on the kernel/DT
  side**, under our own firmware. That would be a large surprise given §2.3, and
  the follow-up would be a bisect of BSP-DT-node vs `pmic-reset-func` (add each
  separately to our 6.18 DT via DTBO).
- Empty ⇒ **the BSP kernel + BSP DT + `pmic-reset-func=<1>` cannot save it on our
  firmware**, which pins the cause firmly to firmware (EXP-5/6) or kills the premise
  (EXP-3). Either way it is the highest-information single result available.

**Time:** ~30 min including two reboots. **Risk: MEDIUM.** The 6.1.115 BSP kernel
may fail to boot (older kernel, NVMe/eMMC root, different rootfs feature set). It is
reversible only *before* the reboot; recovery from a failed boot needs a serial
console on ttyS2 @1500000 or physical media access. Have the serial adapter attached
before doing this. Do it when you can afford the board being down.

---

### EXP-3 — Boot official Radxa Debian r6 from SD (1 hour, MEDIUM risk) ★ SETTLES THE PREMISE

Only if EXP-2 comes back empty, or if you want the premise settled independently.

```bash
# image is already downloaded and already decompressed:
#   /home/yi/Code/radxa-images/debian-r6/rock-5b_bookworm_kde_r6.output_512.img.xz
#   /home/yi/Code/radxa-images/extracted/debian-r6/rock-5b_bookworm_kde_r6.img  (7.2 GiB, raw)
lsblk                       # IDENTIFY THE SD CARD. Triple-check.
sudo dd if=/home/yi/Code/radxa-images/extracted/debian-r6/rock-5b_bookworm_kde_r6.img \
        of=/dev/sdX bs=4M status=progress conv=fsync   # SD ONLY
```

Then boot from SD. **Note the boot-order caveat recorded in
`findings/2026-07-24-rock5b-spi-vs-radxa-bsp-firmware-generation-gap.md`: with SPI
populated, the BootROM runs the SPI chain, so the SD image's own idbloader and
`u-boot.itb` never execute and the BSP OS runs on OUR firmware (ddr v1.20 /
bl31 v1.48).** That is a feature for EXP-2-style isolation but means EXP-3 does
**not** by itself test Radxa's firmware. To test the r6 firmware you must either
zero the SD raw-loader gap is *not* what you want here (that forces SPI), or
temporarily depopulate SPI — **do not do that**; use EXP-5 instead.

On the booted r6 image:

```bash
dmesg | grep -iE 'ramoops|pstore'   # expect console 0x80000@0x140000
sudo dmesg -n 7
sudo reboot
ls -l /sys/fs/pstore/               # console-ramoops-0 ?
# r6 has CONFIG_PANIC_TIMEOUT=0 and no panic= — for the crash path you must set it:
sudo sysctl -w kernel.panic=10 kernel.panic_on_oops=1
sudo sh -c 'echo c > /proc/sysrq-trigger'
```

**Proves:** whether a genuine, unmodified, shipped Rockchip BSP userspace+kernel
retains pstore on this exact silicon. Empty ⇒ **H1's residual survives, the premise
of the whole investigation is folklore, and we should close ramoops permanently.**
Populated ⇒ the gap is real; combined with EXP-2's result it localises to kernel/DT
vs firmware.

**Time:** ~20 min to write + ~40 min to boot/test. **Risk: MEDIUM-LOW.** Writing an
SD card is safe if you get the device node right; the risk is entirely
`dd`-to-wrong-device. Do not write SPI, eMMC or NVMe. Booting the r6 image will not
modify the internal storage (its rootfs is on SD), but it *will* run `rsetup`
first-boot logic on the SD card.

---

### EXP-4 — Cold power-cycle vs warm reset control (20 minutes, LOW risk)

Never run, and the repo currently gives backwards advice about it
(`kernel-versions/bsp/troubleshooting.md:102`).

Use the instrumented probe (see EXP-4b for the instrumentation fixes). On the
current ysp/current-rockchip64 kernel with the ramoops DT node:

```bash
# A. warm baseline
sudo bash kernel-drivers/scripts/debug-kernel/ramoops-persistence-probe.sh write 2>&1 | tee /var/tmp/exp4-write-warm.log
sudo reboot
sudo bash .../ramoops-persistence-probe.sh dump      # HEXDUMP FIRST
sudo bash .../ramoops-persistence-probe.sh read

# B. cold control — same stamp, then a full power removal (unplug ≥30 s)
sudo bash .../ramoops-persistence-probe.sh write 2>&1 | tee /var/tmp/exp4-write-cold.log
sudo poweroff        # then physically remove power for 30 s, reapply
sudo bash .../ramoops-persistence-probe.sh dump
sudo bash .../ramoops-persistence-probe.sh read
```

**Proves:** whether warm and cold differ at all on RK3588. If cold looks *identical*
to warm (both zeroed), that is strong evidence the boot chain re-creates the array
regardless and rules out any "keep the rails up" family of fixes. If cold is
0x00/0xFF-mottled and warm is uniformly zero, the warm zeroing is a software writer
and worth hunting. **Also: fix `troubleshooting.md:102` either way.**

**Time:** 20 min. **Risk: LOW** (a clean `poweroff` and a power cycle; nothing
written to persistent storage). Requires physical access to the power lead.

---

### EXP-4b — Re-run the island probe, instrumented (40 minutes, LOW risk)

The 2026-07-22 island run produced a verdict with no hexdump, no captured write
phase, no control island, and 1 × 4 KiB per island. Before any conclusion about
2 GB / 6 GB is used again, fix all four:

1. Extend `kernel-drivers/scripts/debug-kernel/ramoops-probe-nomap.dts` to 6–8
   islands spread over both DRAM banks (currently 3: `0x40000000`, `0x80000000`,
   `0x180000000`, 64 KiB each). **Leave one island deliberately unstamped as a
   control.**
2. Patch `ramoops-persistence-probe.sh`: sample ≥8 offsets per island (currently 1,
   always at the lowest offset — `:72`, `BLOCK=4096` at `:74`); make a read-back
   mismatch **fatal** rather than a stderr note (`:135-139`); and on read emit
   `od -A x -t x1z` of the full island plus a 256-bin byte histogram *before*
   classifying (the `ZEROED` test at `:158` requires an exact all-NUL page).
3. Capture the write phase: `… write 2>&1 | tee /var/tmp/ramoops-probe-write.log`.
4. Boot with `initcall_blacklist=ramoops_init` (verify `initcall ramoops_init
   blacklisted` in the log) and `sudo armbian-add-overlay ramoops-probe-nomap.dts`.

**Proves:** what the 2 GB / 6 GB content actually *is*. A histogram concentrated on
0x00 ⇒ a software zero-writer reaching 6 GB (extraordinary; hunt it). A 0x00/0xFF
bimodal histogram ⇒ power-loss ground state ⇒ the rails really do drop, and §3.2's
refutation of H3 needs re-opening on a mechanism nobody has found. A flat
high-entropy histogram ⇒ revive the scrambler story. **Risk: LOW** — `STRICT_DEVMEM`
makes stamping ordinary RAM structurally impossible (an unreserved offset returns
EPERM and `set -euo pipefail` aborts).

Cleanup afterwards: remove `initcall_blacklist=ramoops_init` from `extraargs` and
`ramoops-probe-nomap` from `user_overlays` in `/boot/armbianEnv.txt`, delete
`/boot/overlay-user/ramoops-probe-nomap.dtbo`.

---

### EXP-5 — Swap DDR blob + BL31 to Radxa's current pair (2 hours, MEDIUM-HIGH risk)

Coherent, and it is the top remaining firmware hypothesis. Both blobs are already
on disk in `~/Code/u-boot/rkbin/bin/rk35/`, and Armbian's variables are `${VAR:-default}`
overrides (`config/sources/families/include/rockchip64_common.inc:165-166`).

```bash
cd /home/yi/Code/armbian/armbian-build
DDR_BLOB=rk35/rk3588_ddr_lp4_2112MHz_lp5_2400MHz_v1.22.bin \
BL31_BLOB=rk35/rk3588_bl31_v1.54.elf \
  ./compile.sh BOARD=rock-5b BRANCH=current uboot
# write ONLY to a microSD card's bootloader area, never SPI/eMMC/NVMe:
#   idbloader.img  -> seek=64    (512-byte sectors)
#   u-boot.itb     -> seek=16384
sudo dd if=output/.../idbloader.img of=/dev/sdX seek=64    conv=notrunc,fsync
sudo dd if=output/.../u-boot.itb    of=/dev/sdX seek=16384 conv=notrunc,fsync
```

**CRITICAL CAVEAT (this is what makes it MEDIUM-HIGH rather than LOW):** with SPI
populated the BootROM prefers the SPI chain, so an SD-resident loader **will not
run** unless SPI is depopulated or the board is put in maskrom. See
`findings/2026-07-24-rock5b-spi-vs-radxa-bsp-firmware-generation-gap.md` and
`findings/2026-07-08-armbian-26.2.1-bl31-handoff-hang.md`. The realistic paths are:
(a) accept that you must reflash SPI (backups exist in
`/home/yi/Code/rock-5b-ysp/spi-backups/`, both with sha256, and the board has been
recovered from SPI erase before — but this is the only step in this runbook that
writes SPI, and it should be a deliberate decision, not a casual one); or (b) use
maskrom + `rkdeveloptool db` to run a loader from RAM without persisting it, which
is materially safer and is the recommended form.

**Proves:** whether the ddr v1.20 / bl31 v1.48 pairing (documented-unsupported) is
the zero-writer. Re-run EXP-4b under the new firmware. Unchanged ⇒ blob version is
not the cause and the last firmware hypothesis dies. **Time:** ~2 h. **Risk:
MEDIUM-HIGH — the only SPI-writing step in this document.**

---

### EXP-6 — Run the BSP-era loader from maskrom (1 hour, MEDIUM risk)

Safer variant of EXP-5, and it tests the *other* direction (older BSP-generation DDR
init under our kernel):

```bash
# board into maskrom, then load Radxa's own loader into RAM without flashing:
sudo rkdeveloptool db /home/yi/Code/radxa-images/loaders/rk3588_spl_loader_v1.15.113.bin
```

That loader contains `ddr-v1.15-d5483af87d` + SPL v1.13 — the BSP generation. If a
BSP-era DDR init preserves the window where v1.20 does not, EXP-5's flash becomes
justified. **Risk: MEDIUM** (maskrom entry needs the recovery button/pin; nothing is
written).

---

### EXP-7 — Make U-Boot testify (2 hours, LOW risk, no kernel involvement)

Nobody proposed this. Build our U-Boot with `CONFIG_PSTORE=y` (Rockchip's own
`configs/rk3588_defconfig:15` has it; `rock-5b-rk3588_defconfig` does not).
`arch/arm/mach-rockchip/pstore.c:112-127` rewrites the 12-byte header **only when
the signature mismatches**, so U-Boot itself reports, on the next boot, whether the
`0x43474244` signature survived — before Linux ever runs, and with no `/dev/mem`
access needed. Combine with EXP-6 (maskrom `db`) to avoid flashing. **Risk: LOW**
if delivered via maskrom; MEDIUM-HIGH if flashed.

---

### Not recommended

- **Adding `rockchip,reset-mode = <1>` to our `pmic@0` node.** It is a one-line DTBO
  and mainline `rk8xx-core.c:732` already supports it, so it is cheap — but §3.2
  refutes the mechanism from four independent directions and the binding warns some
  hardware *requires* mode 0. If you run it anyway, run it as EXP-4b's A/B and
  validate PCIe/NVMe/USB/eMMC re-init on a plain reboot before trusting it.
- **Writing `0x5242C301` or `0x5242C30F` to `0xfd588080`** (reboot-mode). Those
  select loader and ramdump-over-USB modes and will strand the board. Read-only
  inspection of that register is fine.
- **Enabling the WDT-to-second-global-reset route** or arming DDR fail-safe IO
  retention by MMIO write. TRM says it will not help, U-Boot says ARM64 needs FST
  for the CPU reset entry, and the boot chain has no resume-from-retention entry
  point.

---

## 6. What we would change in the debug-kernel workflow

1. **Stop treating ramoops as the primary crash channel on this board, and say so in
   the tooling.** `kernel-drivers/scripts/debug-kernel/README.md` and
   `install-kernel.sh` should default to **netconsole** (wired) or **ttyS2
   @1500000** and mention ramoops only as a bonus. Every crash finding from
   2026-07-17 onward that says "pstore was empty" cost a re-derivation.

2. **Fix `kernel-versions/bsp/troubleshooting.md:102`.** Replace "recover the dump
   with a cold power-off (not a warm reboot)" with the opposite: a warm reset is the
   only path with any chance, and on this stack neither currently works.

3. **Fix `ramoops-persistence-probe.sh` before it is used again** (details in
   EXP-4b): hexdump + byte histogram *before* classifying; ≥8 offsets per region;
   an untouched control region; a fatal (not stderr) read-back mismatch; and
   `tee` the write phase. The current `ZEROED` test (`:158`, exact all-NUL) and
   `GARBAGE` test (`:163`, byte-count only) produced a verdict that took three
   adversarial passes to interpret and is still partly unresolved.

4. **Reconcile the debug kernel's config with its own instrumentation fragment.**
   `ysp-debug-instrumentation.conf.sh:14-21` asks for `PSTORE_RAM/CONSOLE/PMSG/
   FTRACE=y` and `PSTORE_DEFAULT_KMSG_BYTES=262144`, but the installed
   `/boot/config-6.18.38-ysp-rockchip64` has `PSTORE_RAM=m`, CONSOLE/PMSG/FTRACE
   off and `KMSG_BYTES=10240`. Either make the fragment authoritative or delete the
   ramoops lines from it — the current state silently produces a kernel that cannot
   do what the fragment claims. (The currently-booted ysp kernel also has **no
   ramoops DT node at all**, so present-day empty pstore is not evidence of
   anything.)

5. **When ramoops *is* enabled, keep `ecc-size=16`.** Counter-intuitive given the
   BSP omits it, but §3.1(b) shows it is the only reason we can distinguish "zeroed
   by a writer" from "lost DRAM" without root or `/dev/mem`. It costs nothing (an
   ECC *data* failure does not zap) and turns every boot into a free measurement.
   Keeping it is a diagnostic decision, not a persistence one.

6. **Record the load-bearing negative controls in the finding, not just the
   verdict.** The 2026-07-22 probe's structural controls were genuinely sound
   (islands verifiably reserved; `CONFIG_STRICT_DEVMEM` + `set -euo pipefail` make
   stamping ordinary RAM impossible; Device-nGnRnE mapping with no cacheable alias;
   fresh process per read; `initcall ramoops_init blacklisted` in both boots;
   verified clean warm reboots) — but none of that was written down, so three lanes
   spent effort re-establishing it from an agent transcript after the physical
   evidence had been deleted.

7. **Preserve probe artifacts.** `/var/tmp/ramoops-probe/`, `/boot/overlay-user/`
   contents and the raw probe stdout were all deleted; the only surviving copy of the
   2026-07-22 island result is inside a Claude session JSONL. Copy probe output into
   `findings/evidence/<date>-<slug>/` before cleanup.

8. **Add a repo pointer to the BSP kernel already on disk.** `linux-image-vendor-rk35xx
   6.1.115` is installed with a full BSP DTB and was invisible to eight investigation
   lanes. It is the cheapest A/B rig we own for any "is this a BSP-vs-mainline
   difference?" question, not just this one.

---

## 7. Where the downloaded Radxa artifacts live (reuse, do not re-download)

All under `/home/yi/Code/radxa-images/`. `fetch.log` ends `ALL-DONE`, no FAILs.
Total on disk is roughly **45 GiB** including decompressed images — the big raw
`.img` files are the ones worth keeping or deleting deliberately.

### Original downloads

| Path | Size | What it is |
|---|---|---|
| `debian-r6/rock-5b_bookworm_kde_r6.output_512.img.xz` | 1.4 G | **Official Radxa Debian bookworm KDE r6.** Kernel `6.1.84-8-rk2410`, ddr v1.22, bl31 v1.54, u-boot `rk2410-2017.09-64-39cd993`. The BSP-Linux reference. Use for EXP-3. |
| `android/Rock5B_Android12_rkr14_20240419-gpt.zip` | 826 M | **Radxa Android 12 rkr14 (2024-04).** Only image with `CONFIG_PSTORE_BOOT_LOG=y`. ddr V1.13, ATF v2.3-639. |
| `android/ROCK-5B-Android12-rkr10-20221103-spi-nvme-rkupdate.zip` | 794 M | **Radxa Android 12 rkr10 (2022-11).** The H1-killer: 960 KiB pure cross-reset ramoops at 0x110000 with no boot-log feature; ddr V1.08, ATF v2.3-405. |
| `loaders/rk3588_spl_loader_v1.15.113.bin` | 484 K | Radxa official maskrom loader: `ddr-v1.15-d5483af87d` + SPL 2017.09-ge4e1249 (fwver v1.13). **Use for EXP-6 (`rkdeveloptool db`).** |
| `loaders/rock-5b-spi-image-gd1cf491-20240523.img` | 16 M | Radxa 2024 SPI image: `ddr-v1.16-9fffbe1e78`, bl31 v1.45 @0x40000, U-Boot 2017.09 @0x200000. Only read for version strings; the SPI-resident U-Boot's behaviour is unexamined. |

### Decompressed / loop-extracted images

| Path | Size | Notes |
|---|---|---|
| `extracted/debian-r6/rock-5b_bookworm_kde_r6.img` | 7.2 G | Raw r6 GPT image, ready for `dd` to SD (EXP-3). |
| `extracted/debian-r6/p1.img` / `p2_boot.img` / `p3_root.img` | 16 M / 300 M / 6.9 G | r6 partitions: "config" FAT16 / **empty ESP** / ext4 rootfs (read with `debugfs`, no sudo needed). |
| `extracted/debian-r6/boot32m/` | — | First 32 MiB of r6 (loader area) + extracted `uboot-control.dts`, `our-uboot-control.dts`. |
| `extracted/debian-r6/bl31/` | — | BL31 ELFs incl. `rk3588_bl31_v1.48.elf` recovered via `git -C ~/Code/u-boot/rkbin show 0f8ac860:bin/rk35/…`. |
| `extracted/debian-r6/rootfs/` | — | `rk3588-rock-5b.dtb` + `.dts`, `config-6.1.84-8-rk2410`, `vmlinuz-6.1.84-8-rk2410` pulled out with `debugfs`. |
| `extracted/L1-bsp-kernel/` | 5.5 G | Duplicate r6 full image + `radxa-config-6.1.84-8-rk2410`, `radxa-rk3588-rock-5b.dtb/.dts`, `radxa-vmlinuz-6.1.84`. **Safe to delete the 7.2 G duplicate.** |
| `extracted/android/Rock5B_Android12_rkr14_…-gpt.img` | 6.6 G | Unzipped rkr14 GPT image. |
| `extracted/android/ROCK-5B-Android12-rkr10-…-update.img` | 1.8 G | Unzipped rkr10 RKAF container. |
| `extracted/android/rkr14/` | — | `resource/rk-kernel.dtb+dts`, `kernel.Image`, `fit/{uboot.bin,atf-1.bin,uboot.dtb}`, `loader_lba64.bin`, `super.img`. |
| `extracted/android/rkr10/` | — | `rkfw0/`, `rkfw1/` (RKAF parts incl. `MiniLoaderAll.bin`, `parameter.txt`, `super.img`), `resource/`, `fit/`. |
| `extracted/L3-rkbin-ddr/` | 80 M | DDR blobs carved out of the images: `debian-r6-ddr-v1.22.bin` (78 K), `android-rkr14-ddr-v1.13.bin` (73 K), plus 40 MB heads of each image. |

### Tools written during the investigation (reusable)

| Path | What it does |
|---|---|
| `extracted/android/rkfw_unpack.py` | Unpacks Rockchip RKAF/RKFW update containers. |
| `extracted/android/rsce_unpack.py` | Extracts the `RSCE` resource blob from `boot.img` (gets `rk-kernel.dtb`). |
| `extracted/android/ddrbin_readparam.py` | Reads the ddrbin parameter block (incl. `reserved_0` = the pstore word) from any loader/DDR blob. Complements `~/Code/u-boot/rkbin/tools/ddrbin_tool.py`. |
| `extracted/debian-r6/fatread.py` | Hand-written FAT12/16 reader — opens the r6 "config"/ESP partitions with no sudo and no loop mount. |

### Documentation and fetched sources

| Path | What it is |
|---|---|
| `docs/rk3588_trm_part1.pdf` / `.txt` (57 M / 7 M) | RK3588 TRM V1.0 Part 1. §2.17.3 global resets @ `.txt:24631`; CRU_GLB_RST_CON bit map @ `:14028`; PMU0_GRF_SOC_CON3 @ `:45156`; pin table @ `:83833`. |
| `docs/rk3588_trm_part2.pdf` / `.txt` (56 M / 11 M) | Part 2. DDR Scramble "defaultly bypassed" @ `.txt:3366`. |
| `docs/rk806_datasheet_v13.pdf` / `rk806_ds.txt` | RK806 Datasheet Rev 1.3. SYS_CFG3/RST_FUN @ `.txt:5838`; §4.1.4 reset triggers @ `:1656`; PWRCTRLn_FUN @ `:4650`. |
| `extracted/verify-2/rock5b_schematic.pdf` / `rock5b_sch.txt` | ROCK 5B v1.4.5 schematic. `RESET_L` net @ `.txt:2962` and `:1302`; PMIC_SLEEP routing @ `:1318`, `:2949`. |
| `src/atf/`, `src/tfa/` | Upstream TF-A checkouts (`plat/rockchip/rk3588/…`) for BL31 source comparison. |
| `src/openwrt-ramoops.json`, `extracted/verify-2/openwrt.json` | Raw JSON of the NanoPi R6C OpenWrt thread (the `rockchip,reset-mode` prior art). |
| `src/uboot-rk8xx.c`, `extracted/verify-2/uboot-rk8xx-master.c` | Mainline U-Boot `drivers/power/pmic/rk8xx.c` for the RST_FUN default history. |
| `src/radxa-linux-6.1-stan-rkr5.1-rk3588-rock-5b.dts` | Radxa BSP board DTS (shows `rk3588-rk806-single.dtsi` + `rk3588-linux.dtsi` includes). |
| `src/radxa-linux-5.10-gen-rkr4.1-…dts`, `src/radxa-stable-5.10-rock5-…dts` | Fetched, **never used by any lane**. |
| `src/rockchip-ddrinuboot.html` | Rockchip DDR-in-U-Boot doc page. |
| `extracted/verify-0/` | `rkr10.dts`, `rkr14.dts` (re-decompiled), `rkr10-config`, `android-config` (extracted from IKCONFIG blobs in the Android kernel Images), `cfg-r6`. |
| `extracted/verify-1/ref.bin` | Byte-exact reconstruction of the probe's 4096-byte ASCII reference block (for the statistics). |
| `extracted/verify-2/` | `radxa-r6.dts`, `rk3588-rock-5b.dtb`, `uboot-control.dtb`/`.dts` (our U-Boot's control FDT, extracted from `u-boot.itb` at offset 0x161c00). |

### Lane notes (read these before re-deriving anything)

`analysis/L1-bsp-kernel.md` (BSP kernel diff), `L2-reset-path.md` (TRM + BL31
disassembly), `L3-rkbin-ddr.md` (ddrbin parameters), `L4-audit-our-probe.md` (audit
of our own negative), `L5`/`L6` (web + PMIC + DDR retention), `L7-radxa-debian-image.md`,
`L8-radxa-android-image.md`, plus the adversarial passes
`verify-H1-PREMISE-FALSE.md`, `verify-H2-OUR-NEGATIVE-UNSOUND.md`,
`verify-H3-PMIC-RST-FUN.md`, and `completeness-critic.md` (which found the installed
BSP kernel and the ECC-silence result).

---

## 2026-07-24 follow-up: narrowing the zero-writer to TPL, and the boundary-map test

Session follow-up after the workflow, prompted by "what exactly does BL31 do" and
"why would TPL/SPL zero memory". Adds four verified facts, one ruled-out mechanism,
and one new experiment. Nothing here changes the verdict; it narrows §3.3.

### F1. SPL's entire static footprint, and why it cannot reach the window

`include/configs/rk3588_common.h` in the exact source of our installed U-Boot
(`~/Code/u-boot/rock-5b-armbian-26.5.1-u-boot`, radxa/u-boot `39cd993`) —
**SOURCE-VERIFIED**:

```
CONFIG_SPL_TEXT_BASE          0x00000000   CONFIG_SPL_MAX_SIZE       0x00040000
CONFIG_SPL_BSS_START_ADDR     0x03fe0000   CONFIG_SPL_BSS_MAX_SIZE   0x00010000
CONFIG_SPL_STACK              0x03fe0000   CONFIG_SYS_INIT_SP_ADDR   0x00600000
CONFIG_SPL_LOAD_FIT_ADDRESS   0x2000000 / 0x10000000
```

Consolidated low-DRAM map (BL31 rows from §3.2/L2, ATAGS and U-Boot from the
2026-07-21 u-boot audit):

| Region | Address | Source |
|---|---|---|
| SPL text | `0x0 – 0x40000` | `CONFIG_SPL_TEXT_BASE` + `MAX_SIZE` |
| BL31 v1.48 image | `0x40000 – 0xbe000`, `0xf0000 – 0xf6000` | `readelf -SW` |
| BL31 share-mem pool (SCMI shmem at top) | `0x100000 – 0x10ffff` | `rk3588_def.h:155-158` |
| **firmware log ring** | **`0x110000 – 0x117fff`** | ddrbin param block, F3 |
| **our ramoops window — zeroed** | **`0x118000 – 0x1e7fff`** | measured, §3.1 |
| ATAGS | `0x1fe000 – 0x1fffff` | `rk_atags.c` |
| U-Boot proper | `0x200000` | `rk3588_common.h` |
| SPL BSS + stack | `0x03fe0000` | `CONFIG_SPL_BSS_START_ADDR` |
| FIT load buffer | `0x2000000` / `0x10000000` | `CONFIG_SPL_LOAD_FIT_ADDRESS` |

The window sits in a gap no static allocation claims, at either end.

### F2. The two U-Boot features that *would* touch it are compiled out

**MEASURED** in the installed build's `.config`:

```
$ grep -n "CONFIG_PSTORE\|CONFIG_ROCKCHIP_MINIDUMP" .config
224:# CONFIG_PSTORE is not set
226:# CONFIG_ROCKCHIP_MINIDUMP is not set
```

`arch/arm/mach-rockchip/Makefile:100` gates `pstore.o` on `CONFIG_PSTORE`, so
`pstore.c` — which would rewrite ring headers in this exact region — is not built.
`rk_mini_dump.c:329` carries the only large low-DRAM `memset` in the tree
(`memset(ram_image, 0x0, 0x18000)`, 96 KiB) and is likewise not built. Every
remaining `memset` in `arch/arm/mach-rockchip/*.c` is a vendor-storage buffer, a
serial-number string, or ATAGS. **SPL is clean by source audit, as BL31 was.**

### F3. The ddrbin log ring explains both DT layouts exactly

From L3's parameter dump — `pstore_base_addr = 0x11` ⇒ `0x11 << 16` = `0x110000`,
`pstore_buf_size = 0x8` ⇒ 32 KiB, with `tpl_log_en`, `spl_log_en`, `atf_log_en`,
`optee_log_en`, `uboot_log_en` all `1`, **byte-identical in our v1.20, Radxa's v1.15
and Android's v1.13**. So the ring is `0x110000 – 0x117fff`.

Two things fall out, and both check out:

- The BSP node is `ramoops@110000` with **`boot-log-size = <0x8000>`** — 32 KiB, the
  ring exactly. `arch/arm/mach-rockchip/pstore.c:11-17` (in our own U-Boot, unbuilt)
  carries that DT layout verbatim in its header comment. The BSP's boot-log zone
  *is* the firmware log ring, surfaced to Linux. It is a same-boot handoff and needs
  no persistence at all.
- Our debug patch's `0x118000` is the first byte **above** the ring. The two
  addresses are not competing choices; ours is Rockchip's with the firmware ring
  carved off the front.

### F4. Inline ECC initialisation is ruled out as the zeroing mechanism

Whole-array ECC initialisation is the textbook producer of uniform zeros, but it
costs roughly an eighth of capacity. **MEASURED**: `MemTotal: 16183596 kB` = 15.43
GiB of 16 GiB — normal reservation overhead, not a ~14 GiB inline-ECC penalty. Inline
ECC is off, so it is not what zeroes the window.

### Consequence: TPL is now the sole remaining candidate

BL31 (disassembled), U-Boot proper (audited 2026-07-21) and SPL (F1+F2) are all
clear. That leaves the **closed rkbin DDR blob**, which is also the one component
that touches DRAM as a *device* rather than as storage. Plausible mechanisms, ranked
by fit with the measured data — all **INFERRED**, none verified, the blob has never
been disassembled:

1. **Geometry / capacity detection.** Density, rank count and address mapping are
   determined by writing markers at power-of-2 offsets and reading back for
   aliasing, then clearing them. This is the only mechanism that predicts the island
   results: 1 GB read back ZEROED, and 2 GB / 6 GB flagged GARBAGE by a classifier
   that demands an exact all-NUL page. Power-of-2 offsets are exactly where a
   capacity detector writes.
2. **Log-ring init overshoot.** The blob must leave a valid ring header at
   `0x110000` every boot. A clear derived from a size field rather than the
   advertised 32 KiB would start at the ring and run a fixed distance — landing on
   our window.
3. **Training scratch cleanup.** Write levelling, read-gate training, ZQ and DQ
   deskew write patterns and may zero the scratch afterward. Explains localised
   zeros, not 832 KiB, unless the scratch is generously sized.
4. ~~Inline ECC init~~ — ruled out, F4.

### EXP-1c — Map the zero boundary (30 minutes, ZERO risk, read-only) ★ NEW

Run after EXP-1b, which reads the ring at `0x110000`. Both are read-only `mmap` of
`/dev/mem`; neither reboots or writes anything.

- If the **ring is intact** at `0x110000–0x117fff` but zeros begin exactly at
  `0x118000`, the actor is mechanism 2 and ramoops may simply need to move clear of
  it — the cheapest possible fix.
- If the **ring is also zeros**, the `*_log_en` bits are not producing writes and
  the whole ddrbin-pstore thread is moot.

Then walk the region at fine granularity and find where the zeros start and stop.
**A terminating boundary on 64 KiB / 1 MiB / 2 MiB characterises the loop that wrote
them, and any window surviving above that boundary is somewhere ramoops could
live.** This constrains the answer whichever way it comes out, at no risk, without
the blob swap of EXP-5/EXP-6.

If the boundary map points at the blob, disassembling it is tractable: it is small,
and the search is for bulk-zero idioms (`stp xzr, xzr` loops, `dc zva`).

---

## 2026-07-24 follow-up 2: the upstream-U-Boot angle, and a wider provisioning tally

Second session follow-up, prompted by "has anyone got ramoops working, maybe with
upstream U-Boot?". Two claims from the web were cross-checked against local sources
rather than taken at face value. Conclusion: **upstream U-Boot is not the lever**, and
the provisioned-but-never-demonstrated tally now stands at six independent stacks.

### F5. Upstream U-Boot keeps the exact component we suspect — SOURCE-VERIFIED

Mainline U-Boot's RK3588 support still requires Rockchip's closed DDR blob. In the
current mainline tree (`~/Code/u-boot/u-boot` @ `6741b0dfb41`, 2026-07-10):

```
arch/arm/mach-rockchip/Kconfig:652:  Enable this option and build with
                                     ROCKCHIP_TPL=/path/to/ddr.bin to …
```

and the u-boot-list series *"rockchip: Support getting DRAM banks from TPL for rk3568
and rk3588"* is precisely about SPL **reading the ATAGS the TPL blob produced**
("Allow RK3568 and RK3588 based boards to get the RAM bank configuration from the
ROCKCHIP_TPL stage instead of the current logic"), tested on Rock 5B 8 GB and 16 GB
— <https://www.mail-archive.com/u-boot@lists.denx.de/msg507999.html>.

Also **MEASURED**: `grep -rln ramoops arch/arm/mach-rockchip/` in mainline returns
nothing. The `pstore.c` that knows the `0x110000` layout (follow-up F3) exists only in
the Rockchip fork.

Consequence: switching to upstream U-Boot replaces SPL and U-Boot proper, and permits
upstream TF-A in place of the rkbin BL31 — **all three of which this document has
already cleared** (§3.2, follow-up F1/F2) — while keeping the TPL DDR blob byte for
byte. It cannot test the one remaining hypothesis. Do not spend a bring-up on it
expecting a ramoops answer.

### F6. Provisioned-but-never-demonstrated is now six stacks

Adding two third-party observations to the four product images in §1.1:

| Stack | ramoops node | Recovery demonstrated? |
|---|---|---|
| Rockchip BSP source `rk3588-linux.dtsi:92` | `@110000`, 0xe0000 | no artifact |
| Radxa Debian r6 shipped DTB | same | no artifact |
| Armbian vendor DTB on this disk | same | no artifact |
| Radxa Android rkr14 / rkr10 | same / 0xf0000 | no artifact |
| **nixos-rk3588 (third party, Armbian U-Boot 2017.09)** | `ramoops: using 0xf0000@0x110000, ecc: 0` | **no** — init log only |
| **linux-hardware.org RK3588 dmesg probes** | ramoops registers cleanly | **no** — init log only |

Sources: <https://github.com/ryan4yin/nixos-rk3588/blob/main/Debug.md>,
<https://linux-hardware.org/?log=dmesg&probe=59ae3d3d52>. Note the nixos case runs the
BSP node **with `ecc: 0`** — the configuration §1.2 predicts would fail silently.

### F7. The one claimed fix has no artifact — but is already testable here

The [OpenWrt RK3588 ramoops thread](https://forum.openwrt.org/t/is-there-a-way-to-enable-ramoops-on-rk3588-s/244208)
(NanoPi R6C) is marked *Resolved* by `jjm2473` via a kernel backport plus
`rockchip,reset-mode = <1>` on `&rk806_single`. Re-read in full: **no recovered pstore
content is posted anywhere in the thread**, and no end-to-end confirmation follows the
claim. It is the same resolved-without-evidence pattern §1.2 describes.

Three things verified locally that the thread does not say — all **MEASURED**:

- The cited commit is real and upstream: `db8db85cff331`, *"mfd: rk8xx-core: Allow to
  customize RK806 reset mode"*, Quentin Schulz, 2025-06-27.
- **It is already in our kernel** — `drivers/mfd/rk8xx-core.c:732-737` reads
  `rockchip,reset-mode` and writes `RK806_SYS_CFG3`/`RK806_RST_FUN_MSK`. No backport
  is needed on this board.
- Our RK806 is present and bound: `/sys/firmware/devicetree/base/spi@feb20000/pmic@0`,
  `/sys/bus/spi/devices/spi2.0`, `input: rk805 pwrkey … spi2/spi2.0`. Our live DT sets
  neither `rockchip,reset-mode` nor `pmic-reset-func` (exhaustive `find` over the DT).

So the OpenWrt fix reduces to a one-property DTBO here.

### EXP-1d — Set `rockchip,reset-mode = <1>` and retest (15 minutes, LOW risk)

Low expected value, listed because it is nearly free and closes the last loose end from
the public record. H3 was refuted on mechanism (§3.2: none of the five documented
RST_FUN triggers is reachable from a software reboot, and our BL31 cannot address SPI2
at all), so the prediction is **no change**. Add the property to `spi@feb20000/pmic@0`
via an overlay, reboot, and check `/sys/fs/pstore`. A positive result would overturn
§3.2 and should be treated as a major finding, not a footnote.

Prefer running this *after* EXP-1c, which costs nothing and does not require a reboot.

---

## Boundary — what this document does not establish

- **That BSP ramoops works.** No lane, no artifact, no document shows a recovered
  pstore record on any RK3588. EXP-2/EXP-3 are the tests.
- **Who writes the zeros.** The TPL DDR blob was never disassembled and is now the
  sole candidate. BL31 v1.48 was disassembled and is clear; U-Boot proper was
  audited and is clear; SPL is clear by source audit (follow-up F1/F2) — but "no
  static footprint and no compiled-in memset" is not the same as "never writes
  there", since SPL runs arbitrary loader code.
- **What the 2 GB / 6 GB content is.** Never hexdumped. "DRAM-wide destruction" is
  not established.
- **Whether a cold power-cycle differs from a warm reset here.** Never measured.
- **Whether the ddrbin `*_log_en=1` bits actually cause any stage to write
  0x110000 on our board.** Inferred from config bits only (EXP-1b).
- **Whether the closed TPL/ddrbin ever writes the RK806 over SPI**, or reads
  PMU0_GRF+0x80 before DDR init. Immediates can be movz/movk-built, so string and
  literal-pool scans are not proof. Both would be identical on the two stacks
  regardless.
- **Anything about the RK3588 `SCRAMBLE_KEY` block at 0xFD9C0000.** It exists in the
  address map with no register documentation; the TRM says the module is bypassed by
  default, and nothing suggests firmware enables it, but it is undocumented.
