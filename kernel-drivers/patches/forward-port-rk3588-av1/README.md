# forward-port-rk3588-av1/

Split AV1/RK3588 forward-port patch series generated from the external Armbian
kernel build workspace and kept here as source text.

## Provenance

Imported from:

```text
/home/yi/Code/kernel/rock5b-kernel-build/forward-port/patches/
```

That external `forward-port/` directory also contains generated fallback and
official-source `.deb` files. Those binaries are intentionally not copied here.
Only the `git format-patch` text series is source material.

## Contents

The series targets Armbian `rockchip64-current` / Linux 6.18 and carries the
self-contained-DT RK3588 MPP/RGA/AV1 forward port. It is the source line behind
the PPA kernel, but the Published package stops at `0041`; the tracked tail is
newer:

- `0001` imports the vendor RK3588 MPP/RGA driver base.
- `0002` adds VEPU580/rkvdec2/RGA device-tree plumbing.
- `0003` through `0017` carry the shared-domain, Verisilicon IOMMU, AV1, RGA,
  SRAM, and hardening forward-port work.
- `0018` through `0037` reconcile the newer Rockchip 5.10 RGA series: the
  RK3588 low-voltage workaround, hardware batching/sequential jobs, request
  lifetime fixes, shadow pages for cache-line-unaligned mappings, and the
  reviewed RGA2/RGA3 correctness fixes.
- `0038` fixes the RKVENC2 multi-slice terminal-error hang.
- `0039` rejects overflowed or non-System-RAM raw physical RGA imports before
  they reach `dma_map_sg()` cache maintenance.
- `0040` releases RGA session buffers through their kref on close instead of
  force-freeing objects still referenced by another session or in-flight job.
- `0041` unlinks MPP sessions from the procfs-visible service list before
  freeing device-private or DMA state.
- `0042` clears `session->dma` after `MPP_CMD_RESET_SESSION` destroys it,
  preventing the later async teardown from freeing the same object again.
- `0043` samples the RKVENC2 abort flag before the final task reference can be
  dropped, removing the forward-port-introduced post-free `task->state` read.
- `0044` accepts the legacy `RGA2_GET_RESULT` command as the BSP-compatible
  no-op already provided for `RGA_GET_RESULT`.
- `0045` validates staged RGA task descriptors, blocks reconfiguration while a
  request runs, and atomically replaces/frees the prior staged task list.
- `0046` accepts the legacy virtual-address convention (`uv_addr` populated,
  `yrgb_addr` zero) in the `0045` task check, fixing the regression that made
  every legacy `RGA_BLIT` virtual blit fail with `EFAULT`.
- `0047` reports the RGA2 under-4G memory exclusion distinctly: a clear log
  line plus `EOPNOTSUPP` (instead of a generic `EINVAL` "no core match") when
  below-4G buffers would make the job assignable.
- `0048` programs byte-literal WIN0/WIN1/WR raster strides for 10-bit
  semi-planar formats (incompact P010/P210 at 2 bytes/pixel, compact
  NV15/NV20 at 10 bits/pixel), fixing the measured incompact P010 read shear
  and the Jellyfin-known P010 write corruption; the compact raster leg is
  hardware-validated by the `rga-nv15-test` probe (semantic NV15→NV12 read,
  P010→NV15 write, bit-exact NV15 copy at 256/320/1920 widths).
- `0049` derives 10-bit plane offsets byte-literally in
  `rga_convert_addr()`: the 1 byte/pixel UV offset placed both the read and
  the write UV base in the middle of the Y plane for P010 (measured — Y
  bit-exact, chroma never written / read from Y row h/2), completing the
  `0048` byte-literal 10-bit fix.
- `0050` owns the RGA2 MMU page tables through the DMA API: the shared ring
  is mapped once against the RGA2 device at bind, per-job handle tables are
  mapped after their CPU fill and unmapped at put, the MMU base registers
  get the retained DMA address, and the illegal
  `virt_to_phys()`-based sync helper is removed (closes the July 20
  DMA-debug finding). Also declares a 4 GiB DMA max segment size (CMA
  imports exceed the 64 KiB default) and a page-preserving swiotlb
  min-align mask for RGA2.
- `0051` serves over-4G memory on RGA2 through DMA-API mappings of the
  32-bit RGA2 device (swiotlb bounces what sits above 4G): page-granular
  multi-segment mapping variants for per-job buffers, transient per-job
  re-mappings for handle buffers imported for another core, policy that
  keeps RGA2 a candidate for remappable buffers, and `EOPNOTSUPP` fallback
  when a mapping fails. Below-4G buffers remain the fast path; bounces cost
  a CPU copy per direction.
- `0052` drops a request's initial `rga_request_alloc()` reference exactly
  once. Four paths retire a request (async completion, cancel, submit-abort,
  owning-session close) and any two can race — a job completing in the RGA
  IRQ thread while the `/dev/rga` session closes — double-putting the
  reference and freeing the `rga_request` under a live
  `rga_request_release_signal()` (KASAN slab-use-after-free in `wake_up()`
  plus a refcount underflow). A new `rga_request_release_ref()` helper makes
  the drop idempotent under the pending-request-manager lock. Found by the
  `cross` session-close reproducer under KASAN.
- `0053` stops the MPP async task worker (`mpp_task_worker_default`) from
  oopsing when a pending task's session has no bound device: it fetches the
  device via `mpp_get_task_used_device()` and drops the orphaned task on NULL
  instead of dereferencing it, and makes the orphan disposable end-to-end
  (`mpp_taskqueue_pop_pending` no longer refuses NULL-device tasks — which had
  made the abort path spin and leak — and `mpp_free_task` /
  `try_process_running_task` skip the missing device). Turns a fatal
  `rk_vcodec` NULL-deref hard lockup (seen on the VP9 `show_existing_frame`
  vector) into a dropped task + error log. The upstream trigger (the VP9
  `show_existing_frame` refcount corruption in MPP userspace) is separate.
- `0054` guards the synchronous twin of `0053`: `mpp_wait_result_default()`
  fetched the task device and dereferenced it (`mpp->dev_ops->result`)
  without a NULL check, so a device-less session's task would NULL-deref on
  the poll/wait path too. It now fails and drops the dead task right after
  fetching the device, in every poll/blocking mode.

There is no `0012` in the imported sequence because that const-correctness
commit is already carried by the Armbian kernel base and the build wrapper
removes it through `SKIP_COMMITS`.

This snapshot was regenerated from `rkvenc-fwport-6.18` at
`e4c9b62669526` (`v6.18..HEAD`, with `0012`
omitted), matching the 53-file series generated by `build-armbian-deb.sh`.
KASAN verified the `0042` narrowed reproduction and the `0042`/`0043` memory
safety paths; corrected MPP and FFmpeg functional gates pass on that KASAN
build, while the complete current tip still needs a clean package rebuild and
boot. See the
[`0042` finding](../../../findings/2026-07-18-mpp-reset-session-dma-double-free-kasan.md)
and [`0043` finding](../../../findings/2026-07-18-rkvenc2-wait-result-task-uaf-kasan.md).
The `0044`/`0045` fixes pass booted KASAN ABI replay on rebuilt debug build
`Pb999-C4ad2` (`abi_status=0`, clean memory scan). See the
[`0044`/`0045` finding](../../../findings/2026-07-21-rga-forward-port-abi-gaps.md).
The `0046`–`0048` RGA fixes pass their booted gates on debug build
`P63dd-C4ad2`: legacy blits succeed, the under-4G exclusion returns
`EOPNOTSUPP` with the explanatory log, P010 luma is bit-exact, and the full
librga smoke, MPP, FFmpeg-required, and ABI replay suites are green. The
`0048` verification exposed the `0049` UV-offset defect. On debug build
`P9636-C4ad2`, `0049` and `0050` pass their booted gates: P010 copies are
bit-exact including chroma, FFmpeg Main10→P010 via RGA is bit-exact
(PSNR inf), and the full smoke/MPP/FFmpeg/ABI sweep runs with a completely
clean DMA-debug/KASAN journal — the page-table and segment-size warnings
are gone. The `0051` gate (the inverted `0047` probe — a small over-4G
system-heap imcopy on RGA2) got past `EOPNOTSUPP` onto the hardware but
read back stale destination data on two successive debug builds. Two
defects: the bounce copy-back post-clean was wrongly skipped for
IOMMU-mapped (default-map-core) origins (fixed on `P9636`, keyed on the
bounce direction instead), and — the first-order bug, exposed by the
`P9412` re-run — the transient dst bounce inherited the channel
*get-side* `DMA_TO_DEVICE` direction, so swiotlb never copied the
device output back at unmap. `0051` is amended (`162edad7bb9c7`) to map
every transient bounce `DMA_BIDIRECTIONAL`, matching the driver's
persistent mappings — and on debug build `P7589-C4ad2` (`#7`, carrying
that amendment) the gate closes: the full differential matrix is
content-exact (both-legs, dst-only, and userptr bounces), the
mapping-failure fallback stays a clean `EOPNOTSUPP`, and the
smoke/ABI/MPP/FFmpeg sweep is green with a zero-flagged-line journal.
`0044`–`0051` are all BOOT-VERIFIED. The `P7589` boot then surfaced a
*separate* request-lifetime use-after-free (the `cross` session-close
reproducer under KASAN): the `rga_request` initial reference is dropped
by four racing retire paths, freeing the request under a live IRQ-thread
completion. `0052@c46bfd6622ba6` makes that drop idempotent; its booted
gate — a quiet `cross` run with `async_submits > 0` — awaits the next
debug build (`0052` is boot-*loaded* on `P9c12-C4ad2`, gate not yet run).
A *second*, fatal blocker then emerged: the VP9 `show_existing_frame`
vector corrupts MPP buffer state and an async worker NULL-derefs a
torn-down session's task (`mpp_task_worker_default`), hard-locking the
board; `0053@98232d5c06fab` makes that worker (and the orphan
pop/free/running paths) fail safe. Its gate needs the serial/netconsole
capture the [ramoops finding](../../../findings/2026-07-21-ramoops-not-preserved-across-warm-reset-rk3588.md)
calls for, since the crash leaves no on-board trace. See
the
[conformance root-cause finding](../../../findings/2026-07-21-rga-ffmpeg-librga-conformance-root-causes.md),
the
[DMA scope finding](../../../findings/2026-07-21-rga2-dma-api-ownership-and-over-4g-scope.md),
and the
[request-completion UAF finding](../../../findings/2026-07-21-rga-request-completion-vs-session-close-uaf-kasan.md).

## Relationship To Other Patch Sets

The older top-level pair
`../rk3588-rkvenc2-01-vcodec-rga-drivers.patch` and
`../rk3588-rkvenc2-02-vcodec-rga-dt.patch` remains the validated non-AV1 base
described by the main patch README. This directory records the newer forward
port used for the co-installable PPA kernel source package.

Do not commit Armbian `output/debs/`, fallback `.deb`s, generated source
packages, or the exported patched kernel worktree here. Regenerate those from
the scripts and source inputs.
