# Forward-port 0095–0096 close RGA/MPP ownership and fault-admission gaps

> Scope: RK3588 Linux 6.18 forward-port RGA, MPP, and Rockchip/VSI IOMMU
> provider paths
> Source: `rk3588-video-6.18@7698e7018e3d5`, patches `0095`–`0096`;
> `drivers/video/rockchip/rga3/`, `drivers/video/rockchip/mpp/`,
> `drivers/iommu/rockchip-iommu.c`, and `drivers/iommu/vsi-iommu.c`
> Date: 2026-08-08
> Trust: **CODE-INSPECTED** / **CONFIRMED** / **FIX-COMPILE-VERIFIED** / **PARTIAL**

## Result

Two independently reviewed commits close the source-level gaps found after
the first 6.18.43 conformance run.

Patch `0095` corrects patch `0094`'s incomplete forward-port staging boundary.
The transient RGA2 path created a separate DMA-BUF attachment for each
channel/task. A high-memory attachment that SWIOTLB could map successfully was
therefore still unsafe for aliases: each use owned a separate bounce image and
teardown could copy an older image over a completed write. The forward port now
routes every high-address RGA2 DMA-BUF through one job-shared DMA32 staging
object keyed by acquired `struct dma_buf *` identity. It copies back once only
after successful, quiesced completion and enforces 64 MiB per-job, 128 MiB
per-session, and 256 MiB global active-byte limits.

The same patch makes imported handles session-authorized and import pools
transactional; balances pre-start, runtime-PM, mapping, and staging unwind;
and gives request configuration, submission, cancellation, fence callbacks,
completion, reusable MPI contexts, and scheduler shutdown explicit locking and
reference ownership. Shutdown drains running and queued work even when the
device cannot be resumed for a hardware reset.

Patch `0096` serializes MPP session state, result collection, and DMA-cache
identity/reference transitions. Task admission now reserves one provider owner,
masks and drains stale provider IRQ state before task publication, starts the
hardware, and then enables delivery without acknowledging a fault that latched
after START. Rockchip and VSI provider-link, shared-IRQ, callback-quiescence,
and runtime-PM error paths follow the same ownership boundary.

Hard RKVDEC2 CCU mode is deliberately disabled on this forward port. A DT
request for hard mode is forced to soft mode under the CCU lock before core
probe selects its task worker, IRQ, and fault hooks. The dormant hard-mode code
remains compiled, but it is not selectable at runtime.

## Compile and review evidence

The final `0001`–`0096` source passed:

- `git diff --check` and strict diff-only `checkpatch.pl`, with zero errors,
  warnings, or checks over 3,513 lines;
- an arm64 production-config `W=1 WERROR=1` build of the complete
  `drivers/video/rockchip/rga3/`, `drivers/video/rockchip/mpp/`, and
  `drivers/iommu/` directories; and
- a second arm64 `W=1 WERROR=1` build of the complete RGA directory with
  `CONFIG_ROCKCHIP_RGA_ASYNC=n`.

The disposable build directories are
`../rock-5b/build/forward-port-0095-0096-final/` and
`../rock-5b/build/forward-port-0095-0096-noasync/`; both use the shared
`~/Code/.ccache` store. Separate agents reviewed RGA, MPP/provider, and final
cross-subsystem locking/refcount behavior. The first reviews found additional
reachable lifetime and ordering gaps; the repair/re-review cycle ended with
clean verdicts from both final reviewers.

## Why the rewrite fix remains different

The rewrite already canonicalizes direct-fd aliases by `struct dma_buf *` and
reuses one `(import, hardware)` mapping for the whole job. A successful
SWIOTLB mapping is therefore shared there. Its recorded fallback should still
stage only after the exact size-limit `-EIO` and an unavailable RGA3 reroute.
The full rewrite design and its pending proof are in the
[rewrite staging finding](2026-08-08-rewrite-rga2-dmabuf-staging-design.md).

## Verification gate

Package, install, and boot exact `0001`–`0096` with a recovery kernel retained.
First pass the original three RGA2-only librga failures. Then force both a
below-limit high-memory alias whose direct SWIOTLB map would have succeeded and
an oversized high-memory DMA-BUF; require correct producer/consumer content,
one shared staging object, one success-only copy-back, and zero active staging
objects/bytes afterward.

Run the complete production conformance matrix, concurrent RGA request/MPI and
MPP session/result cases, cancellation/session-close and PM-failure injection,
and provider faults at each admission boundary. A hard-CCU DT request must emit
the fallback warning and select the soft worker. Repeat the exact tail under
KASAN/lockdep and require clean kernel logs, counters, fences, and recovery.

## Boundary

This tail is source-, style-, compile-, and independent-review verified only.
It is not packaged, installed, booted, sanitizer-tested, or runtime-verified.
The installed 6.18.43 package still ends at `0092` and retains its recorded
librga failure. CPU-inaccessible/secure exporters, raw high physical memory,
and buffers beyond the staging limits remain deliberately unsupported on
RGA2. No rewrite source was changed.
