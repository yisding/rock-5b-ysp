# Forward port vs Rockchip 5.10, 6.1 and 6.6 BSP media drivers

Direct source comparison of the RK3588 MPP and RGA driver lineages. This note
answers three separate questions that are easy to conflate:

1. how much the original Linux 6.18 forward port changed its Rockchip donor;
2. whether Rockchip's `develop-6.6` branch contains a materially newer media
   architecture than `develop-6.1`; and
3. whether the numerically older `develop-5.10` branch contains later vendor
   driver work that never reached either newer-kernel branch.

> **Result.** The original forward port is a narrowly adapted copy of the 6.1
> BSP implementation, not a redesign. Rockchip's 6.6 MPP/RGA stack has the same
> architecture and the same public ioctl headers. Its MPP implementation differs
> from 6.1 by only 36 edited lines. RGA differs more, but primarily because the
> current 6.1 branch contains later 2025 fixes that never reached the older 6.6
> snapshot. Conversely, Rockchip continued developing RGA on `develop-5.10`
> through June 2026. That branch contains sequential hardware batching,
> RK3588 low-voltage workarounds, memory/IOMMU fixes, and format support absent
> from both 6.1 and 6.6. The newer AV1/IOMMU forward-port branch adds significant
> mapping, shared-domain, fault-recovery, and buffer-validation work, while
> retaining the BSP task, scheduler, and register-generation model.

## Compared revisions

The three Rockchip branch tips were verified against the official remote with
`git ls-remote` on 2026-07-16.

| Name | Revision | Role |
|------|----------|------|
| Rockchip 5.10 BSP | `rockchip-linux/kernel develop-5.10@bfa51d2ab08140d1309afc9a9fe0fc2878cee35a` | Numerically older kernel branch, but the newest RGA donor examined here |
| Rockchip 6.1 BSP | `rockchip-linux/kernel develop-6.1@b4ef083dc0c3608e744deabb43dc6b781aadbe6e` | Original MPP/RGA donor and byte-level oracle |
| Rockchip 6.6 BSP | `rockchip-linux/kernel develop-6.6@1ba51b059f25533c5529b7f68186190b47d6a7b3` | Vendor 6.6 comparison snapshot |
| Original forward-port import | `linux-rock5b@924f4232546d` | The superseded two-patch import represented by `patches/rk3588-rkvenc2-01-...patch` |
| Forward-port kernel | `linux-rock5b rk3588-video-6.18` | The single maintained line: AV1, shared-domain IOMMU, recovery, RGA userptr, and RCB hardening |

The last two rows are the same line at two points in time, not two kernels to
choose between. The current headline in
[`vendor-delta.md`](./vendor-delta.md) is measured against the maintained
tree; the older, smaller figure it also records belongs to the original
two-patch import. The series itself is summarized in
[`patches/forward-port-rk3588/`](../patches/forward-port-rk3588/README.md).

## Measurement method

All counts below are direct Git tree or `--no-index` diffs. "Forward-side lines
differing" means the `+` count when diffing `BSP -> forward-port`: a modified
line is counted once on the forward side, and a new line is counted once. It is
not a net line-count change.

The official branch identities can be rechecked with:

```sh
git ls-remote https://github.com/rockchip-linux/kernel.git \
    refs/heads/develop-5.10 refs/heads/develop-6.1 \
    refs/heads/develop-6.6
```

The direct BSP comparison was measured with:

```sh
git diff --numstat b4ef083dc0c3 1ba51b059f25 -- \
    drivers/video/rockchip/mpp drivers/video/rockchip/rga3
git diff b4ef083dc0c3 1ba51b059f25 -- \
    include/uapi/linux/rk-mpp.h drivers/video/rockchip/rga3/include/rga.h
```

The forward-port comparisons used only matching runtime files when reporting
the focused MPP/RGA counts. Deleting an unported BSP block is a scope decision,
not an edit to that block, so legacy VDPU/VEPU, JPEG, IEP, and VDPP files were
not allowed to dominate the like-for-like figures.

## Rockchip 6.1 vs Rockchip 6.6

### Quantitative result

| Subtree | Files changed | 6.6 additions | 6.6 deletions | Total edited lines |
|---------|--------------:|--------------:|--------------:|-------------------:|
| `drivers/video/rockchip/mpp/` | 6 | 14 | 22 | 36 |
| `drivers/video/rockchip/rga3/` | 13 | 258 | 364 | 622 |

The public headers are byte-identical:

| Header | 6.1 blob | 6.6 blob |
|--------|----------|----------|
| `include/uapi/linux/rk-mpp.h` | `9a24407001ec6a15ffce51f0294b26bf3ac41e7d` | same |
| `drivers/video/rockchip/rga3/include/rga.h` | `671867b22371b4931c989fc08c9209c9dfa2b81d` | same |

There is therefore no 6.1-to-6.6 MPP or RGA userspace ABI migration.

### MPP differences

Most of the 36 edited lines are kernel-API adjustments already required by the
forward port:

- `iommu_map()` gains the `GFP_KERNEL` argument;
- `class_create()` loses its `THIS_MODULE` argument.

Only two changes materially affect MPP runtime behavior:

- The current 6.1 code has the later RKVENC2 watchdog fix: VEPU510 uses the
  256-cycle formula while other encoder generations use the 1024-cycle formula.
  The 6.6 snapshot still applies the 256-cycle multiplier to every generation.
- The current 6.1 service clears stale load accounting when the measurement
  interval expires or no sessions remain. That cleanup is absent from 6.6;
  codec execution is unchanged, but procfs load values can remain stale.

The session/taskqueue model, RKVENC2/RKVDEC2 backends, CCU/DCHS model, register
transport, dma-buf ABI, and polling protocol are otherwise the same.

### RGA differences

The RGA delta is real but is not an architectural replacement. It mostly shows
that the live 6.1 branch received media commits after the 6.6 branch stopped.
The two BSP branches share a merge base at `243363ccfdc2` dated 2025-07-30;
`develop-6.6@1ba51b0` is dated 2025-09-01, while the current 6.1 branch contains
RGA fixes through December 2025.

| Area | Current 6.1 / baseline forward port | 6.6 snapshot |
|------|-------------------------------------|--------------|
| Command buffers | Per-scheduler DMA pool, with optional preallocated genpool | One coherent allocation per submitted job |
| Physical-address import behind an IOMMU | Build pages/sg-table and use `dma_map_sg()` | Use `dma_map_resource()` directly |
| 10-bit YUV422 sizing | Correct 20-bit accounting | Shares the 15-bit 420 calculation |
| RGA2 10-bit YUV422 | Includes the later read-path fix | Fix absent |
| RGA3 compact/endian control | Userspace can change raster 10-bit compact/endian mode | Older condition can retain the forced setting |
| Legacy global alpha | Foreground/background assignment typo fixed | Older duplicate-background assignment |
| Kernel MPI 90/270 rotation | Swaps destination active width/height | Older dimensions retained |
| Virtual-buffer physical offset | Includes the page-offset correction | Older base address behavior |
| Driver version | `1.3.11` | `1.3.10` |

These differences can surface in physical-address imports, special 10-bit RGA
profiles, legacy alpha composition, the in-kernel MPI interface, and allocation
pressure. Ordinary dma-buf blits still pass through the same global
`rga_drvdata`, policy scheduler, memory manager, backend vtable, and RGA2/RGA3
register emitters.

## Why Rockchip 5.10 is the newest RGA donor

Linux 5.10 is an older upstream kernel than Linux 6.1 or 6.6, but Rockchip's
vendor branches are maintained independently. The official branch tips make
the inversion concrete: `develop-6.6` stops in September 2025,
`develop-6.1` contains RGA work through December 2025, and `develop-5.10`
contains RGA work through June 2026.

A direct `develop-6.1..develop-5.10` RGA tree diff changes 20 files with 2,561
additions and 690 deletions. Those raw counts include branch-specific kernel-API
adaptation and are not a safe cherry-pick list. Comparing commit subjects and
then checking the resulting source found 46 RGA commits from 2025-2026 with no
same-subject counterpart in either 6.1 or 6.6. The major source-visible gaps
are:

| Area | 5.10-only work relevant to the comparison |
|------|--------------------------------------------|
| RK3588 reliability | Enable RGA3 `logic_clk_on` under low voltage (`561aab30f22b`); disable RGA2 `auto_rst` because it causes low-voltage timeouts (`718fad971319`) |
| Multi-task execution | Hardware command batching for sequential jobs (`02e0554b1e66`) and the required slave-mode-after-master-mode fix (`0c1499fbace4`) |
| Request lifecycle | Fix a failed multi-task-submit request leak (`3727985456c1`) and the acquire-fence callback race when the fence becomes signaled during installation (`f7643d9a9d22`) |
| Memory/IOMMU safety | Bound IOMMU prefetch correctly (`e78e66240ba6`); handle cache-line-unaligned user VAs with shadow pages (`a4afb82d881c`, `6a74aeec3409`, `31aa12084e3b`); reject discontinuous DMA IOVAs (`f2f903866ece`) |
| Formats and processing | RKCFA, secure access, Y1, RGBA/BGRA5551/4444 input, RGBA1010102/YUV101010, and full-CSC 10-bit |
| AFBC32x8 | Expanded YUV/src1 input, output, non-block-aligned overlay, src1-only correction, and compressed color fill support |
| Register/parameter fixes | Scale guards, MPI 90/270 output handling, tile4x4 base programming, slave-mode bounds checks, and CSC bit definitions |
| Additional SoCs | RK3538 and RK3572 hardware descriptions; useful to a general sync, but not needed for RK3588 |

### Sequential request semantics

Current librga names request bit 6 `IM_JOB_FLAGS_EXEC_SEQUENTIAL`. The 6.1 and
6.6 drivers store that bit in `request->flags` but never interpret it:
`rga_request_commit()` fans every task out as an independent `rga_job`, so
different cores can execute dependent tasks concurrently. The original 6.18
forward port faithfully inherited that behavior; it is not a forward-port
regression, but it is a compatibility bug against current librga.

Rockchip fixed the contract on `develop-5.10` in `02e0554b1e66`. Its kernel
header calls the same bit `RGA_REQUEST_FLAGS_EXEC_SEQUENTIAL`. A flagged request
becomes one multi-command hardware job and runs in command order; an unflagged
request retains the older independent per-task fan-out. The follow-up
`0c1499fbace4` is part of the functional unit because it restores correct
single-command slave-mode execution after hardware master mode has run.

### Forward-port implications

The 5.10 tree should be treated as a third donor, not copied wholesale. For the
RK3588 forward port, review changes in this order:

1. the two RK3588 low-voltage clock/reset workarounds;
2. request-leak and acquire-fence lifecycle fixes;
3. hardware batching together with its master/slave follow-up;
4. memory/IOMMU fixes compared semantically with the forward port's newer
   contiguous userptr mapping and 32-bit span hardening; and
5. formats only when current librga or a real consumer requires them.

The fourth item especially must not be a blind cherry-pick. The 6.18 forward
port already maps scattered driver-owned userptr sg-tables into a contiguous
IOMMU range and fails unsafe dma-buf mappings closed, which can supersede parts
of the 5.10 reject-only implementation while leaving other cache-line and
prefetch fixes applicable.

## MPP and AV1 changes unique to 5.10

The same subject-and-source comparison found only three MPP commits on 5.10
without a counterpart on either 6.1 or 6.6. Only one is a missing RK3588
runtime fix:

| 5.10 commit | Difference | RK3588 forward-port result |
|-------------|------------|----------------------------|
| `40b88680bb93` | Treat an RKVENC2 error interrupt as the last slice so a multi-slice encode cannot wait forever; use the full non-VEPU510 reset sequence and a realistic reset-poll timeout | Applicable and ported locally as `8d78edbe910c` |
| `576620f372f9` | Detach the previous shared IOMMU domain before attaching a different one | Already superseded: the forward port tracks the previous IOMMU owner, publishes explicit encoder/decoder CCU shared domains, detaches old shared domains, verifies fixed RCB windows, and fails unsafe reuse closed |
| `e06ea0131423` | Avoid an unnecessary GRF operation in the legacy VDPU1 backend | Not applicable to the Rock 5B RKVDEC2/VDPU383 path |

The encoder hang fix is small but significant. On an error during a split
encode, older code can leave the job waiting for another slice IRQ that will
never arrive. The port preserves the separate VEPU510 IRQ path while applying
the fix to the RK3588 RKVENC2 backend.

### Why the extra 5.10 AV1 code is not a newer feature

`develop-5.10` has 180 lines in `mpp_av1dec.c` that are absent from both 6.1
and 6.6. They implement a private `av1dec_bus`, manually create an
`av1d-master` platform device, and explicitly register the BSP-private AV1 IOMMU
driver. This is older kernel integration scaffolding, not a decoder enhancement.

Rockchip deliberately removed it while adapting AV1 to 6.1 in `0e31084baa89`,
then added the normal IOMMU provider in `2349ea26cbe4`. The 6.1 and 6.6 AV1
decoder files are byte-identical at the compared tips. The 6.18 forward port
goes further: it uses a standard `vsi-iommu` provider with normal DT probe
ordering, per-domain page tables, identity/paging-domain transitions,
runtime-PM-aware attach and TLB handling, and provider-local fault callbacks.
Reintroducing the 5.10 private bus would regress that design.

The AV1 audit therefore found no 5.10-only decoder fix to port. The useful AV1
changes are already forward-port-local hardening: register-request validation,
safe split-request accounting, one-time FD translation per valid register
class, spurious-IRQ guards, AFBC IRQ ownership, and the modern VSI IOMMU
integration documented in
[`av1-bsp-audit.md`](../av1/docs/av1-bsp-audit.md).

## 5.10 reconciliation status

As of 2026-07-16, the local `rkvenc-fwport-6.18` worktree has 21 focused commits
on top of the published AV1/IOMMU series at `18fae9957686`:

- RK3588 RGA low-voltage clock/reset workarounds;
- sequential hardware batching and its master/slave transition fix;
- request/fence lifetime fixes;
- IOMMU prefetch, unaligned-userptr shadow-page, mapping-size, and lookup-error
  fixes;
- applicable scale, interrupt, tile, rotation, and CSC parameter fixes; and
- the RKVENC2 multi-slice error-hang fix above.

The combined ARM64 build of `vsi-iommu`, MPP, and RGA3 passes at local commit
`8d78edbe910c`. Features that only advertise RK3538/RK3572 or RGA2P
capabilities—RKCFA, secure access, full-CSC 10-bit, and most AFBC32x8/format
expansions—were not copied into the RK3588 RGA2E/RGA3 target without a matching
hardware capability entry. The local kernel commits are not part of the
published YSP patch series yet.

The separate clean-room rewrite audit adapted its five applicable RGA change
groups at `rk3588-rewrite-6.18@0d71ded1690c` and
`rk3588-rewrite-mainline@32696e87c9c7`: the two low-voltage quirks, config-error
IRQ/status handling, per-mapping cache-line boundary shadows, and the narrow
RGA3 BT.709-limited CSC compatibility shape. Both rewrite tips pass the
normal/memory/race clean-source profiles; they still require the booted RK3588
gate in [`rewrite-5.10-reconciliation.md`](../rga/rewrite-5.10-reconciliation.md).

## Baseline forward port vs each BSP

The baseline import remains overwhelmingly a 6.1-derived driver. Focused
runtime-file counts are:

| Baseline comparison | Forward-side MPP lines differing | Forward-side RGA lines differing |
|---------------------|---------------------------------:|---------------------------------:|
| Against 6.1 BSP | 141 | 39 |
| Against 6.6 BSP | 151 | 380 |

The larger RGA distance from 6.6 is almost entirely the vendor 6.1-versus-6.6
branch delta above. Against 6.1, the complete **baseline** accounting remains
about 578 local lines out of 34,999 code/build lines: approximately 98% vendor
code. That figure describes the two-patch import only; the shipping tree was
re-audited 2026-07-24 at **4,626 differing lines out of 39,535 — ≈ 88%
byte-identical, and ≈ 90% Rockchip-authored once the `develop-5.10`
cherry-picks are counted on the vendor side** ([vendor delta](./vendor-delta.md#the-answer-90-rockchip-10-ours),
which is authoritative for current numbers).

The meaningful baseline changes are integration changes:

- post-6.1 kernel API adaptations;
- compatibility stubs for BSP-only OPP, system-monitor, PMU, DMC, SIP, and QoS
  services;
- fixed-rate clocks instead of the full BSP PVTM/devfreq stack;
- RK3588 CCU probe deferral/publication and compatible matching fixes;
- Kconfig/Makefile wiring for the mainline/Armbian tree;
- deliberate omission of legacy MPP blocks outside the Rock 5B target.

They do not replace the BSP task model, codec backend organization, or RGA
command generators.

## Current AV1/IOMMU forward-port superset

The current branch should not be described by the original 1.7% figure without
qualification. Against the BSP runtime files:

| Current comparison | Forward-side MPP lines differing | Forward-side RGA lines differing |
|--------------------|---------------------------------:|---------------------------------:|
| Against 6.1 BSP | 1,837 across the selected MPP+AV1 files | 584 |
| Against 6.6 BSP | 1,847 across the selected MPP+AV1 files | 917 |

> **Stale pin.** The two rows above were measured on `rkvenc-fwport-6.18@18fae9957686`,
> a branch retired in the 2026-07-23 cleanup, over a hand-selected file subset.
> The canonical branch is now `rk3588-video-6.18` (tip `710e6ad12af6`, tail
> `0001`–`0074`), and the whole-directory re-audit against 6.1 gives **MPP 1,826
> / RGA 2,433 differing lines**. Treat the rows above as historical and
> [vendor delta](./vendor-delta.md#the-answer-90-rockchip-10-ours) as current. The 6.6 column has not been re-measured at the new tip.

Those larger counts come from targeted functionality and hardening rather than
a new media-driver architecture:

- RKMPP AV1 plus the Verisilicon IOMMU provider;
- provider-local Rockchip/VSI IOMMU fault callbacks;
- explicit shared IOMMU domains for encoder/decoder CCU clusters;
- RCB fixed-window overlap checks and reset-time domain verification;
- reset-error propagation and recovery containment;
- full dma-buf span and 32-bit IOVA checks;
- restored large DMA-segment support in the Rockchip provider;
- an RGA 32-bit plane-offset wrap guard;
- contiguous IOMMU mapping for scattered RGA userptr buffers;
- optional encoder RCB SRAM.

The current MPP header is also a backward-compatible superset of both BSP
headers. It adds `MPP_CMD_SET_ERR_REF_HACK`, defines
`MPP_FLAGS_REG_OFFSET_ALONE` as the name/alias for bit `0x10`, and adds
`MPP_FLAGS_POLL_NON_BLOCK` (`0x20`). The current forward port implements
nonblocking generic and encoder-slice polling with `-EAGAIN`. It advertises
`SET_ERR_REF_HACK` and accepts it through the codec backend's unknown-command
no-op path; the rewrite is stricter and explicitly validates then discards its
payload.

RGA's public `rga.h` remains byte-identical to the 6.1 and 6.6 BSP branches,
but it predates the request flag and formats added on 5.10. Its RGA2 and RGA3
command emitters remain the 6.1 implementations. The current RGA
changes concentrate in DMA/IOMMU mapping, fault handling, and address safety.

## Significance

| Question | Verdict |
|----------|---------|
| Is the forward port a rewritten MPP/RGA architecture? | **No.** It retains the vendor service, taskqueue, policy, memory-manager, backend, and register-emission design. |
| Is Rockchip 6.6 a newer media architecture than 6.1? | **No.** The ABI and object model are the same. |
| Is 6.6 the better donor merely because its kernel is newer? | **No.** Its media snapshot misses later fixes present on `develop-6.1`. |
| Is 5.10 the newer kernel series? | **No**, but its RGA snapshot is newer and contains material fixes/features absent from both newer-kernel branches. |
| Does the original BSP/forward-port implement librga's sequential flag? | **No.** The first examined implementation is the later 5.10 hardware-batching series. |
| Are there meaningful runtime differences? | **Yes**, in watchdog timing, special RGA formats/imports, command-buffer allocation, IOMMU topology, fault recovery, and AV1 scope. |
| Will ordinary H.264/H.265 and common dma-buf RGA jobs use different codec/image algorithms? | **Generally no.** The userspace register recipes and vendor command generators remain the same lineage. |

For resync work, use the pinned 6.1 tree as the byte-lineage oracle, 6.6 as an
additional kernel-API/reference snapshot, and the newer 5.10 RGA commits as a
feature/fix donor. Review the current forward-port hardening as a separate local
series. Replacing the donor wholesale with either 6.6 or 5.10 would respectively
regress later fixes or discard 6.18-specific safety work; the correct target is
a semantic superset of all three.
