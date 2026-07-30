# BSP-audit HIGH findings ported to the current forward-port tip

> Scope: the 16 HIGH reviewer rows in `kernel-drivers/docs/bsp-audit.md`,
> reconciled from audited base `5614909e5803` to the maintained RK3588
> MPP/RGA/AV1 forward-port through `0058@570519704bd46`
> Source: [`kernel-drivers/docs/bsp-audit.md`](../kernel-drivers/docs/bsp-audit.md)
> and the forward-port series
> [`kernel-drivers/patches/forward-port-rk3588/`](../kernel-drivers/patches/forward-port-rk3588/README.md);
> booted build `Pabd5-C4ad2`.
> Date: 2026-07-22
> Trust: CODE-INSPECTED / COMPILE-VERIFIED / PACKAGE-VERIFIED / BOOT-VERIFIED /
> KASAN-CLEAN (correctness + destructive gates, see the 2026-07-22 evening
> update) / PARTIAL (root-only; production and perf gates still open)

## Result

The audit's 16 HIGH rows collapse to 13 distinct bugs. Two bugs were already
absent from the `0058` source:

- `23ff47eab6f682` unwinds RKVENC2 core-probe failures through
  `rkvenc2_free_rcbbuf()`, `rkvenc_detach_ccu()`, and `mpp_dev_remove()`.
- `b6ea72cb5f56e` makes RGA request-submit failures and async result-copy
  failures reach the shared `rga_request_put()` epilogue. This closes both
  duplicate `rga_drv.c:804` HIGH rows.

The other 13 reviewer rows / 11 distinct bugs are ported onto the evolved
source as `0059`-`0069`:

| Patch | Distinct HIGH fix |
|---|---|
| `0059@ee1128afb52f7` | handle failed MPP task-message allocation |
| `0060@bc9ce80684451` | validate `MPP_CMD_SET_SESSION_FD` file operations before using `private_data` |
| `0061@058b7ba10cbcd` | bound the userspace RKVDEC2 RCB register index |
| `0062@da664db65a8ae` | test the iterated decoder core's disable flag |
| `0063@61fa807b5a5be` | bound RKVENC2 class request arrays |
| `0064@cc2e9c31ed7d6` | balance every RGA acquire-fence reference |
| `0065@8b35725f5e7fc` | perform queued-job shutdown cleanup outside `irq_lock` |
| `0066@5beedb0d19f48` | reject missing required multi-plane handle buffers |
| `0067@8524d74a79252` | balance `rga_mm_get_buffer()` errors and clear its out-pointer |
| `0068@ec97d2f16203f` | unwind partial RGA handle acquisition idempotently |
| `0069@62f82902f6a1a` | require an RGA core feature superset |

`0066` and `0068` are semantic forward ports rather than mechanical replays.
They preserve the current `0050`/`0051` RGA2 page-table DMA ownership and
transient bounce mappings: missing optional zero-sized planes are skipped,
required planes are rejected before page-table construction, bounce mappings
are released before origin references, and per-job page-table DMA mappings are
unmapped once before their pages are freed.

## Verification

- all 11 commits: `scripts/checkpatch.pl --no-tree` — 0 errors, 0 warnings;
- `git diff --check 570519704bd46..62f82902f6a1a` — clean;
- native build with `PATH=/usr/sbin:/usr/bin:/sbin:/bin`:
  `make -j8 drivers/video/rockchip/` — all modified MPP/RGA objects compiled
  and both `built-in.a` archives linked;
- the ABI probe's new opt-in `ABI_PROBE_ENABLE_MPP_FOREIGN_FD=1` case passes a
  valid `/dev/null` fd to `MPP_CMD_SET_SESSION_FD` and requires `-EBADF`; its C
  source passes `-Wall -Wextra -Werror -fsyntax-only`.

## Debug package

Pinned-6.18.38 KASAN/lockdep build `Pabd5-C4ad2` completed on 2026-07-22:

- Armbian/Docker runtime: 66:32; kernel phase: 3,797 seconds; packaging: 67
  seconds;
- ccache remained enabled but the debug config transition was effectively cold:
  `hit=108 miss=14453 (0%)`;
- `linux-image`, `linux-dtb`, `linux-headers`, and `linux-libc-dev` are non-empty
  arm64 `26.08.0-trunk` Debian packages with the same full build identity;
- the packaged config enables KASAN generic/inline/vmalloc, lockdep,
  `DMA_API_DEBUG`, MPP RKVENC2/RKVDEC2/AV1, multi-RGA, pstore, and ramoops, and
  contains `# CONFIG_PANIC_ON_OOPS is not set`;
- the packaged ROCK 5B DTB contains the debug `ramoops@118000` reservation; and
- all seven source files touched by `0059`-`0069` compare byte-for-byte with
  `bsp-high-port-20260722@62f82902f6a1a` in the patched Armbian build worktree.

Package SHA-256 values:

| Package | SHA-256 |
|---|---|
| `linux-image-current-rockchip64` | `7c5b76cdff5581a2c7f34ec6938a201fc8a9b39d8ffe3f438f51021c94c580fd` |
| `linux-dtb-current-rockchip64` | `346a3d3b45f00892e8c171783c18b23635a44dca3a3cd2646da59fe95144ada9` |
| `linux-headers-current-rockchip64` | `ced3a3d4a5833c8c117f15da0425e4d9cf8d6d8e25b222df781a656bb6c429b2` |
| `linux-libc-dev-current-rockchip64` | `8dae2cb9c38207f4d81aace2ba3688d9aede2b3b4a80bc5aa1a8799d06a949cf` |

## Remaining gate

No runtime claim is made for `0059`-`0069`. Install and boot `Pabd5-C4ad2`, then
run the foreign-fd gate, crafted RCB/request bounds cases, async
acquire-fence stress, missing-plane and partial-handle failures, shutdown, and
the full MPP/librga/ABI/FFmpeg regression sweep with a clean kernel journal.
The currently booted `Pd222-C4ad2` kernel validates only through `0058` and
therefore still carries the 11 distinct bugs until replaced.

## 2026-07-22 evening update — installed, booted, first gates green

`Pabd5-C4ad2` was installed at 17:16 and booted at 17:21 PDT. Identity per the
[validation runbook](../kernel-drivers/docs/kernel-validation-runbook.md):
`/boot/vmlinuz-6.18.38-current-rockchip64` md5
`d058837408638134c0e63639f9be5c98` equals the `Pabd5-C4ad2-H17f8` image-deb
payload (the `Pd222` payload differs), `CONFIG_KASAN=y` +
`CONFIG_PROVE_LOCKING=y` confirmed in `/proc/config.gz`. Note the pinned
kernel timestamp makes `uname -a` still read `#5 … Jul 4` — only the md5
fingerprint distinguishes this build.

Evidence so far, in
`~/Code/rock-5b/rockchip-conformance/logs/forward-port/20260722-172558-pabd5-full-validation/`:

- Boot health clean: `tainted=0`, both encoder cores, all three decoder cores,
  RGA3×2 + RGA2 probed, AV1DEC/RKVDEC/RKVENC advertised.
- One flagged boot-journal item: a lockdep "possible recursive locking"
  report during PCI probe. Triaged **not ours** — the trace is entirely
  upstream `dwc_pcie_pmu_notifier` → `platform_device_register_full` nesting
  two bus-notifier rwsems of the same lockdep class (missing nesting
  annotation in the DWC PCIe PMU driver); no rockchip/mpp/rga/iommu-provider
  frames.
- Four-codec HW-vs-SW decode differential: H.264, H.265, VP9, AV1 all
  **bit-exact** (`decode_differential_rc=0`).
- KASAN MPP suite: `suite_status=0`, `flagged_kernel_lines=0`.

Still open from the gate list above: the targeted `0059`-`0069` hostile-ioctl
gates (foreign-fd, RCB/request bounds, acquire-fence, missing-plane /
partial-handle), librga smoke, ABI replay, and the FFmpeg + GStreamer suites
on this boot.

### 2026-07-22 ~19:20–19:34 — full exercise on `Pabd5-C4ad2`

The remaining ladder was run on this boot (logs under
`rockchip-conformance/logs/forward-port/2026072*` and this session's
scratchpad). Board stayed up throughout (`uptime` continuous, no reboot).

**Conformance / correctness — green:**

- **FFmpeg suite 24/24** (`20260722-191912-ffmpeg-suite`) — H.264/H.265/VP9/AV1
  bit-exact PSNR and Main10→P010 RGA. Strongest correctness gate, clean.
- **ABI replay** `rc=0`.
- **GStreamer 129 pass / 4 fail** (`20260722-191946-gstreamer-suite`) — the 4
  fails are the documented userspace gaps
  ([finding](2026-07-22-gstreamer-suite-forward-port-userspace-gaps.md)):
  `generated_transcode_h264_dmabuf_to_h265`, `event_flush_dec_h264`,
  `generated_dec_h265_10_rga_scale`, `generated_dec_h265_10_env_disable_nv12_10`.
- Four-codec decode differential (17:29 run) and KASAN MPP suite (17:30) already
  green on this boot.

**Destructive / hostile-ioctl — the fixes under test hold:**

| Gate | Fix | Result |
|------|-----|--------|
| foreign-fd (`ABI_PROBE_ENABLE_MPP_FOREIGN_FD=1`) | `0060` | batch returns `-EBADF` (`-9`) as required; no crash |
| raw physical import | `0039` | safely rejected `-EINVAL`; no crash. (Probe reported FAIL only because this run mis-set the *rewrite*-profile `EXPECT_RGA_PHYSICAL_REJECT=EOPNOTSUPP`; forward-port `0039` rejects with `EINVAL` by design.) |
| RESET_SESSION double-free | `0042` | `kasan-narrowed-repro.sh` clean, `flagged_kernel_lines=0` |
| clientless `RELEASE_FD` | `0058` | ioctl returns `-1`/`-EINVAL`, board up ("kernel is NOT vulnerable") |
| cross-session request/job UAF | `0052`/`0057` | `cross`: iters=2000, **async_submits=64000**, submit_fail=0, **0 KASAN flags** — strongest result; the race window genuinely opened (below-4G CMA) and stayed clean |
| ioctl fuzz smoke | — | exits PASS, but surfaced a **new** unprivileged list-corruption WARN (below) |

**Root-only gates NOT run** (owner decision — `sudo` needs a password):
encoder-tiny, transcode pipeline, `iommu-machinery-fuzz`, `mpp-debug-capture`,
`mpp-vp9-show-existing-repro`. These stay OPEN.

**librga suites — environment, not kernel:** the official 48-sample
`librga-suite` (7 pass / 41 fail / 5 missing) and `librga-smoke` fail on
`Could not open /data/…bin` (samples hardcode `/data/` inputs) and
`alloc dma32_heap/CMA buffer failed!` (no dma32 heap; CMA limited to `cma=256M`),
plus userspace format-enum gaps (P010 `0x4000` "unknown", AFBC32x8/RFBC64x4).
Every RGA op not needing those — rotate/flip/center-rotate transforms, dma-buf
roundtrips — reported `running success!`. No `no core match`, no `EOPNOTSUPP`,
no driver fault: `0069`'s feature-superset check is **not** over-rejecting.

**New defect surfaced:** the ioctl fuzz tripped a `CONFIG_DEBUG_LIST`
"list_add double add" WARN in `mpp_process_request()` — unprivileged-reachable,
WARN-level, in BSP-shared core code untouched by `0059`-`0069`. Recorded
separately:
[list_add double-add finding](2026-07-22-mpp-process-request-list-add-double-add-warn.md).
