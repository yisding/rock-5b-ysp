# Gotchas & workarounds — the whole-repo trap index

The kernel-port and ffmpeg-userspace traps are **canonical on this page**: every
trap we hit during the port, with the fix, roughly ordered build → DT → driver →
runtime → userspace → infra. The repo has since grown whole subsystems
(`apps/gnome-remote-desktop/`, `video-libraries/mesa/`, `packaging/`) whose traps are
canonical in their own trees — the index table below points at each so this page
stays the master list.

## Traps that live elsewhere (one-line index)

| Area | Trap | Canonical write-up |
|------|------|--------------------|
| GRD | Mutter's RemoteDesktop/ScreenCast D-Bus API is **single-tenant** — starting a second GRD instance evicts the live session, including the RDP client you may be connected through | [`apps/gnome-remote-desktop/docs/testing.md` § 1](../apps/gnome-remote-desktop/docs/testing.md) |
| GRD | The backend's startup **smoke encode consumes the encoder's one natural IDR** → client decodes nothing, RDPGFX frame controller throttles to 0 slots → permanently frozen desktop | [`apps/gnome-remote-desktop/README.md` § The three bugs](../apps/gnome-remote-desktop/README.md) |
| GRD | Headless/smoke-test numbers are soft — mutter often delivers nothing to the virtual monitor; validate with a **real client** plus the "is it actually on hardware?" checklist | [`apps/gnome-remote-desktop/docs/testing.md` §§ 5, 7](../apps/gnome-remote-desktop/docs/testing.md), [`profiling.md`](../apps/gnome-remote-desktop/docs/profiling.md) |
| GRD | PipeWire buffer-negotiation `EINVAL`: mutter advertises `dataType = 1<<SPA_DATA_DmaBuf`, GRD demands `1<<SPA_DATA_MemFd` — a *reconciliation* failure, not an allocation one (and forcing MemFd needs explicit `SPA_PARAM_BUFFERS` shm geometry too) | [`apps/gnome-remote-desktop/docs/capture-path.md` § 1](../apps/gnome-remote-desktop/docs/capture-path.md), [`baseline.md` § 4](../apps/gnome-remote-desktop/docs/baseline.md) |
| GRD audio | A successful `RDPSND`/PCM negotiation can still be silent when applications use standalone PulseAudio and GRD watches an empty native PipeWire graph; install the complete `pipewire-audio` stack so the PulseAudio API, sinks, streams, and GRD share one graph | [`apps/gnome-remote-desktop/docs/audio-redirection.md`](../apps/gnome-remote-desktop/docs/audio-redirection.md), [`findings/2026-07-20-grd-rdp-audio-split-stack.md`](../findings/2026-07-20-grd-rdp-audio-split-stack.md) |
| Mesa | **BLIT-based texture transfers are unsafe on Mali-G610** — the texel coordinate arrives through lossy `LD_VAR_IMM` interpolation, corrupting integer format-changing transfers; the COMPUTE-only fix direction was rejected in Mesa review 2026-07-01 (compute cannot write AFBC) — surviving directions in [`video-libraries/mesa/README.md` § Status](../video-libraries/mesa/README.md) | [`video-libraries/mesa/docs/blit-precision.md`](../video-libraries/mesa/docs/blit-precision.md), [`validation.md` § Current MR State](../video-libraries/mesa/docs/validation.md) |
| Packaging | **Combined (`=y`) kernel and the DKMS module are mutually exclusive** — building DKMS against a kernel that has the drivers built-in fails modpost with `'…' exported twice` | [`packaging/dkms/README.md` § Caveats](../packaging/dkms/README.md); chooser in [`install.md`](../install.md) |
| Packaging | A future Ubuntu ffmpeg (`7:8.1.x`) silently supersedes the local `+rkmpp` debs — `apt-mark hold` them; exact-version rollback recipe exists | [`packaging/README.md` § Operations](../packaging/README.md) |
| Permissions | HW codec nodes (`/dev/mpp_service`, `/dev/rga`, **and the `/dev/dma_heap/*` heaps**) default to root-only; granting `mpp_service` alone leaves the encoder **dead** at MPP init (`MppBufferService get_group failed … type 1`) because rkmpp allocates every buffer from a DMA-heap — the udev rule must also grant `SUBSYSTEM=="dma_heap"` to the `video` group | [`packaging/codec-udev/README.md` § Why the dma-heap grant is required](../packaging/codec-udev/README.md) |
| Userspace libraries | Rockchip `*-dma32` dma-heaps are about low DMA-addressable memory for 32-bit-limited hardware, **not** 32-bit ARM applications. Missing DMA32 heap names on the 6.18 forward-port are a BSP ABI/sample-compatibility gap, not a known correctness requirement for maintained MPP/RGA paths | [`vendor-libraries/docs/how-the-userspace-libs-work.md` § A5.1](../vendor-libraries/docs/how-the-userspace-libs-work.md), [`kernel-drivers/rga/docs/userptr-iommu.md`](../kernel-drivers/rga/docs/userptr-iommu.md) |
| RGA | `RGA3_core0 INTR[0x2]` is the **RGA MMU interrupt**, not the DMA32 heap problem. The direct librga virtual-buffer samples exposed a forward Rockchip IOMMU gap: losing BSP's `dma_set_max_seg_size(..., DMA_BIT_MASK(32))` let `dma_map_sg()` return fragmented IOVA ranges even though RGA programs only the first segment as a single span | [`kernel-drivers/rga/docs/userptr-iommu.md`](../kernel-drivers/rga/docs/userptr-iommu.md), [`kernel-drivers/docs/forward-port-status.md`](../kernel-drivers/docs/forward-port-status.md) |
| Userspace libraries | RKRGA `P010`/`P210` through legacy `c_RkRgaBlit()` depends on librga copying the 10-bit layout fields; older sources can silently submit compact 10-bit instead of padded 10-bit, while the fixed source is `github.com/yisding/librga` `main` at `a632217` | [`vendor-libraries/rga/docs/librga-p010-p210-rkrga.md`](../vendor-libraries/rga/docs/librga-p010-p210-rkrga.md) |
| Debug kernels | Everything about capturing a crash (ramoops/pstore, KASAN, lockdep) without breaking vermagic | [debug-kernel guide](../kernel-drivers/docs/debug-kernel.md); the KASAN/vermagic collision entry below stays canonical here |

## Build / patching

> The two ccache traps below are expanded into a complete operational guide:
> [kernel build ccache guide](../kernel-drivers/docs/kernel-build-ccache.md).

**`hack/` files look deletable — they aren't.** `mpp_rkvdec2.c` `#include`s
`hack/mpp_rkvdec2_hack_rk3568.c`; removing the `hack/` dir fails the build
(`No such file or directory`). The other-SoC bodies are `#ifdef`'d out on RK3588
but must exist. Keep all six.

**Armbian's Python patcher is last-write-wins, core-after-user.**
`lib/tools/patching.py` indexes patches by basename; **core** patches are appended
*after* userpatches, so for a same-name file **core wins**. A same-named empty
userpatch will **not** shadow/disable a core patch (this is the opposite of the
older bash `patching.sh`). To neutralize a core patch you must either edit it or
work *around* its output (we chose **convert-in-place** — overriding Armbian's
existing DT nodes where they sit instead of replacing them — see
[Armbian packaging guide](../packaging/docs/armbian-packaging.md)).

**Two `base.dtsi` patches can collide on the same hunk.** Our encoder/`rkvdec_ccu`
block and Armbian's `media-0001` `vdec` block both land in the
`vepu121_3_mmu → av1d` gap, so we relocate ours to **after `av1d`** to stop the
hunks overlapping. Exact `@@` anchors and reasoning in
[Armbian packaging guide](../packaging/docs/armbian-packaging.md) (§ the `av1d` relocation).

**ccache silently off if passed as an env var.** Armbian prefers a Docker
relaunch when Docker is usable and otherwise supports a sudo/native relaunch on
Armbian or Ubuntu Noble. The Docker path only forwards parsed `KEY=VALUE`
**cmdline** args (`ARMBIAN_CLI_RELAUNCH_PARAMS`, parsed in
`lib/functions/cli/utils-cli.sh`); `USE_CCACHE=yes ./compile.sh` (env var) was
observed being dropped → `Ccache result: hit=0 miss=0 (0%)`. Pass it as an
**argument** in either mode: `./compile.sh kernel BOARD=rock-5b … USE_CCACHE=yes`
(`kernel-drivers/scripts/build-kernel.sh` does this). First build is cold (~80–90 min,
seeds ~5 GB); subsequent patch-only builds hit the cache (~10–15 min). Worktree
re-patching churns mtimes and defeats Armbian's *worktree-incremental*, but
content-addressed ccache survives it.

**In Docker mode, even arg-passed ccache silently misses if
`compiler_check=mtime`.** ccache's
default keys the cache on the compiler binary's **mtime**. Armbian periodically
rebuilds its Docker image (`--> CACHE MISS IN DOCKERFILE`), which does a fresh
`apt install gcc` → new mtime → ccache treats it as a different compiler and
**misses the entire cache**: another full cold build (`hit=63 miss=14628 (0%)`,
97 min) on unchanged source, cache still *growing* (it stores every miss).
Symptom: a build that should be warm reports ~0% hit. Fix: key on compiler
**content**, not mtime — drop `compiler_check = content` into
`$WORKSPACE/armbian-build/cache/ccache/ccache.conf` (the in-container ccache reads
it via `CCACHE_DIR`; `bootstrap-workspaces.sh` writes it). `CCACHE_BASEDIR` is
already set by Armbian to the in-container worktree path, so renaming the host
workspace dir does **not** invalidate the cache — only the compiler mtime does.

**Config-hash component changes legitimately.** Moving config into Kconfig
defaults and reverting the built-in config changes the `C####` component of the
Armbian deb name (the config-content hash — [`glossary.md`](../glossary.md)
explains the `P####-C####` deb-name scheme; e.g. `C89d0` → `Cb831`). Update the `PHASH` pin in
the `install-combined-kernel.sh` invocation so the installer matches the new deb.

## Device tree

**Missing aliases → no `core_id` → crash.** `of_alias_get_id(np,"rkvenc"/"rkvdec")`
(`mpp_rkvenc2.c:3132`, `mpp_rkvdec2.c:1936`) must resolve. Without
`aliases { rkvenc0 = …; rkvdec0 = …; }`, cores get bad `core_id`, none becomes
core 0, decoder defers/oopses.

**DT-overlay aliases resolve to the wrong path.** In a configfs/overlay DT, an
alias resolves to `/fragment@0/__overlay__/rkvdec-core@…`, not the merged node, so
`of_alias_get_id` fails. **Use an in-tree DT** (built-in kernel), not an overlay.

**`fdc40000` vs `fdc48000` for decoder core 1.** Vendor BSP says `fdc48000`;
TRM-canonical (and mainline/Armbian) is `fdc40000` — the BSP address is the
`+0x8000` mirror in the 64 KB window. Use `fdc40000`. Confirmed on hardware.

**Reg/unit-address "mismatch" warnings are benign.** Node is `…@fdc38000` but
`reg[0]` starts at `fdc38100` (the function window). DTC warns; it's harmless and
pre-exists in mainline's own nodes. (The *runtime* register-window bounds check is
a separate thing: `mpp_check_req` (`mpp_common.c:1914`) validates each request
against its window — and the BSP audit flags a latent clamp-arithmetic bug there
at `mpp_common.c:1943`, where the over-size path stores the overflow amount
instead of the remaining space. See [BSP audit](../kernel-drivers/docs/bsp-audit.md).)

**Plain-tree ROCK 5B DTB still needs the Armbian media-label patch.** The
convert-in-place decoder wiring overrides `&vdec0`, `&vdec1`, `&vdec0_mmu`, and
`&vdec1_mmu`. Those labels are supplied by Armbian's media patch, not by vanilla
6.18, so `make rockchip/rk3588-rock-5b.dtb` in the plain forward-port worktree
fails before packaging applies that patch. This is a packaging-order dependency,
not an AV1 or IOMMU regression.

## Driver / probe

> These are forward-port traps **we introduced or hit** porting to 6.18. For
> latent *pre-existing* BSP defects in the same files (`mpp_iommu.c`,
> `mpp_rkvdec2.c`, `mpp_rkvenc2.c`, `mpp_common.c`) — bugs that predate this work
> — see [BSP audit](../kernel-drivers/docs/bsp-audit.md), the BSP audit. Two entries below overlap it
> and link across.

**A `*-core@…` node *requires* its CCU.** Both encoder and decoder dispatch by
`strstr(np->name,"core")` (`rkvenc_probe`, `mpp_rkvenc2.c:3226-3228`;
`rkvdec2_probe`, `mpp_rkvdec2.c:2083-2090`) to a CCU-attaching probe with no
standalone fallback. Enable the CCU with the cores or `*_attach_ccu()` logs
`attach ccu failed` (`mpp_rkvenc2.c:3142`, `mpp_rkvdec2.c:1951`) and the core
never registers. (We spent a build discovering this when the encoder regressed:
`rkvenc_ccu` was left disabled while `rkvenc0` still referenced it.)

**Probe ordering: defer, don't fail.** A core can probe before its CCU sets
`drvdata`, or a secondary core before core 0. The BSP returned `-ENOMEM`/oopsed;
we return `-EPROBE_DEFER` (`rkvenc_attach_ccu`, `mpp_rkvenc2.c:2931`;
`rkvdec2_attach_ccu` in `mpp_rkvdec2.c`) and publish CCU `drvdata` last. Six sites,
enumerated in `vendor-forward-port.md`.

**Do not use `iommu_set_fault_handler()` for rewrite-media DMA-domain faults.** On 6.18,
`iommu_set_fault_handler()` rejects domains whose cookie is not
`IOMMU_COOKIE_NONE`; the codec buffers use the normal DMA default domain. The
forward-port therefore keeps mainline `drivers/iommu/rockchip-iommu.c` and adds a
small Rockchip provider hook/export layer (`rockchip_iommu_set_fault_handler()`,
mask/unmask, enable/disable/reset). MPP and RGA register their task-aware fault
callbacks through that provider hook. They do not fall back to the generic API: that
legacy domain handler is set-once and has no safe unregister lifetime for the
IOMMU-core-owned default DMA domain if a media module is removed. When a domain
is attached, missing provider-hook support therefore fails core probe; genuine
no-IOMMU operation remains allowed. A local MPP-only shim is not enough: it
cannot access the provider's private MMU bases, clocks, IRQ mask register, or
domain state.
The provider hook is local to one physical IOMMU, not to its DMA domain. On the
Rock 5B shared decoder domain, teardown must therefore clear the removed core's
provider hook unconditionally; using "another core has the same domain" as the
clear test leaves a stale callback and can redirect that controller's fault to
the surviving decoder. The same rule applies to RGA: a reported physical source
must match exactly rather than falling back to the first same-domain core, and
clearing the provider hook must wait for an IRQ callback that already copied the
old function pointer before driver or devm state is released.

**DMA-fence callbacks already run with the fence spinlock held.** Calling
`dma_fence_get_status()` from one recursively takes the same lock and deadlocks;
use `dma_fence_get_status_locked()`. RGA async acquire callbacks also share one
job/work reference, so close or last-core removal must not queue completion
while the submit path is still arming callbacks. Keep an arming sentinel in the
pending count and let callback removal or callback execution claim and drop each
waiter's share exactly once.

**A HARD-CCU IOMMU fault's physical source is not necessarily its software job
owner.** The CCU may execute a descriptor on a peer decoder whose `active_job`
slot is empty, so scheduling only that physical core's timeout work delays
recovery until the ordinary job timeout. Keep exact provider/controller
attribution first, then read the source link's `CFG_ADDR` descriptor IOVA and
route recovery to its active same-coordinator owner. If the descriptor is
unavailable or unmatched, schedule any active HARD-CCU job on that coordinator
so the existing force-stop and dependent-job abort path fails closed.
Publish the job's HARD-CCU-started ownership state before writing `CFG_DONE`,
and order it with the descriptor writes. Publishing it after the doorbell
allows an immediate descriptor-fetch fault to observe no eligible software
owner and route recovery to an empty physical peer.

**A recovery `mutex_trylock()` needs a guaranteed fallback.** After a HARD-CCU
force-stop, silently returning because a peer core is still in its serialized
start/completion section leaves that dependent job alive until the ordinary
500 ms timeout. Queue work that holds both the hardware and the exact active
job, but snapshot that job *before* the failed lock attempt and queue it only if
it still owns the slot. Recheck identity after taking the run lock and cancel
the timeout only after that exact claim. A generic "abort whatever is active
later" worker can reset a replacement; canceling before the identity check is
equally unsafe because it leaves the replacement active without a watchdog.

**One codec register IOVA is not a scatterlist.** MPP register translation
hands hardware one 32-bit base address, so accepting only the first DMA segment
of a fragmented dma-buf silently exposes unmapped memory after that segment.
The rewrite accepts a multi-entry mapped SG table only when its DMA entries form
one byte-contiguous span covering the full dma-buf inside the 32-bit aperture;
embedded plane offsets and later `SET_REG_ADDR_OFFSET` tuples are cumulative,
and that combined offset must stay strictly inside the allocation without
wrapping the 32-bit register IOVA.

**A dma-buf fd number is reusable, not an object identity.** Looking up an MPP
mapping by integer fd before `dma_buf_get()` can return a closed buffer's old
IOVA after the process reuses that number. The rewrite resolves and pins the
current dma-buf first, includes its object identity in the cache key, and drops
obsolete cache ownership without invalidating references already held by a job.

**`RESET_SESSION` must invalidate staged work, not only active work.** MPP
multi-message ioctls are collected before jobs enter the scheduler, so a reset
that only walks `active_jobs` can return and then submit an earlier register
message from the same or a racing ioctl. Staged jobs carry a session epoch and
immutable client/translation/codec/RCB snapshots; reset removes same-ioctl
staged jobs, advances the epoch before aborting, and publishes active-list plus
scheduler-queue ownership under one session-lock critical section. Import
lookup/insertion checks that epoch as well, preventing pre-reset translation
from repopulating the cleared cache. An initialized session may repeat its
client type but cannot rebind between encoder and decoder (`-EBUSY`).

**A slice-FIFO overflow must be recoverable.** If `POLL_HW_IRQ` checks a sticky
overflow bit before every FIFO pop, the first overflow makes every retry return
`-EOVERFLOW`; even a completed encoder job then remains forever at the session
head. Report the overflow once and clear its latch so later polls can drain
retained entries and consume completion. Also select the head job before
validating the slice-only flexible buffer: non-split jobs use the ordinary
full-frame path, while an empty session returns `-EIO` without touching it.

**A job reference does not pin its detachable hardware pointer.** Completion
drops `job->hw` early so platform removal is not held hostage by an unpolled
completed result. If reset/close abort merely loads that pointer, completion
can drop the final hardware reference and removal can free the devm object
before abort cancels timeout work or takes the run lock. Serialize pointer
pin/detach with the session lock and give abort its own hardware reference.

**`CONFIG_CPU_RK3588` is never defined** in mainline/Armbian configs, so the BSP's
guarded `of_device_id` entries don't register. Make the RK3588 match entries
unconditional — the `mpp_rkvdec2_dt_match[]` table (`mpp_rkvdec2.c:1683`) and
`mpp_rkvenc_dt_match[]` (`mpp_rkvenc2.c:2828`), specifically the
`rockchip,rkv-*-v2-ccu`/`-v2-core` entries that the BSP wrapped in
`#ifdef CONFIG_CPU_RK3588`.

**Node-name dispatch blocks node *reuse*.** Because probe dispatch keys off the
node *name* (`strstr(np->name,"core")`/`"ccu"`), you can't rename Armbian's
`video-codec@…` nodes via a label override. Solution: in `rkvdec2_probe`
(`mpp_rkvdec2.c:2083-2090`) also dispatch by **compatible**
(`of_device_is_compatible`), which lets the generic-named node reach
`rkvdec2_core_probe` — the enabler for convert-in-place (see
[Armbian packaging guide](../packaging/docs/armbian-packaging.md)). **Caveat (latent BSP asymmetry):** only the
*probe* path learned the compatible check; `rkvdec2_remove`/`shutdown`/runtime-PM
still dispatch by `strstr(dev_name,"ccu")` (`mpp_rkvdec2.c:2119`, `:2142`, `:2148`,
`:2182`), and `rkvenc_probe` (`mpp_rkvenc2.c:3226-3228`) never gained it at all —
flagged in [BSP audit](../kernel-drivers/docs/bsp-audit.md) as the `mpp_rkvdec2.c:2119`
dispatch-asymmetry finding.

## Runtime

**Never `rmdir` a live configfs DT overlay.** Removing/re-applying a configfs
overlay at runtime deadlocks configfs (`D`-state, cascades to an `rtnl_lock`
wedge; unrecoverable without reboot). Apply once per boot; to reset, **reboot**.
(Another reason the project uses a built-in kernel, not overlays.)

**KASAN/vermagic kernel-variant collision (early `.ko` phase).** The Armbian debug
(KASAN) kernel and stock kernel share the same `uname -r`, so they collide in
`/lib/modules` + `/usr/src`. A `.ko` must be built against headers matching the
*running* kernel's KASAN/MODVERSIONS setting or it won't load. Moot once the
driver is `=y` built-in. The full debug-kernel workflow (pinning Armbian to an
exact upstream tag so vermagic matches, ramoops/pstore capture, KASAN caveats)
is [debug-kernel guide](../kernel-drivers/docs/debug-kernel.md).

**HW codec nodes are root-only — and the `mpp_service` rule alone isn't enough.**
Granting only `mpp_service` leaves the encoder dead at MPP init
(`MppBufferService get_group failed … type 1`) because `rkmpp` allocates every
buffer from a DMA-heap; the udev rule must also grant `SUBSYSTEM=="dma_heap"` to
the `video` group. Canonical mechanism, the error dump, and the rule's design are
owned by the package that ships the rule:
[`packaging/codec-udev/README.md` § Why the dma-heap grant is required](../packaging/codec-udev/README.md).

**Benign boot noise** (not errors): `rkvdec2_init: No niu aclk/hclk reset resource
define` (optional NIU resets absent from DT); `failed to init_opp_table` /
`failed to add venc devfreq` (DVFS is tier-2, off — downgraded to `dev_dbg` in the
patch); `mpp_platform: client N driver is not ready!` (MPP enumerating un-ported
legacy codec blocks like VPU/VDPU1/jpeg).

## Userspace (ffmpeg-rockchip)

**`airockchip/librga` ships a prebuilt `.so`, but librga source IS available.**
The *official* `airockchip/librga` repo distributes only a prebuilt `.so` +
headers + samples (no library source) — easy to mistake for closed. The real
implementation is open (Apache-2.0) in the JeffyCN mirror lineage:
`JeffyCN/mirrors:linux-rga-multi`, maintained as `tsukumijima/librga-rockchip`
(full `core/` + `im2d_api/`, CMake/Meson, Debian packages) and
`madisongh/rockchip-librga`. The current fixed source tree is
`github.com/yisding/librga` `main` at `a632217`: it preserves the old open history
through `2cffdf6`, adds a latest-source layer matching `yisding/librga-mirror`,
and then layers nyanmisaka's fixes plus the local P010/P210 hardening. We linked
airockchip's prebuilt aarch64 `.so` purely for convenience — it works because it
shares the BSP lineage with the kernel `/dev/rga` driver (the transcode test
confirms the ABI matches), but do not assume that binary has the legacy P010/P210
fixes. `rkrga` is also optional in ffmpeg (`h264_rkmpp`/`hevc_rkmpp` work without
it; you'd lose HW scale/CSC).

**ffmpeg-rockchip fails to build on `vulkan_av1.c` (old `40c412dacc`-era fork
only).** That nyanmisaka tip pins an older FFmpeg using the *provisional MESA*
Vulkan-AV1 types while modern Vulkan headers ship only the *KHR* ones;
**`--disable-vulkan`** (unrelated to the rk codecs) works around it. The rebased
`ffmpeg-rockchip-81` successor no longer hits this — do not read it as a live
blocker; see [`video-libraries/ffmpeg/docs/rebase-notes.md` § 3](../video-libraries/ffmpeg/docs/rebase-notes.md).

**`scale_rkrga` preserves aspect ratio by default.** `force_original_aspect_ratio`
defaults to `decrease`, so `scale_rkrga=w=640:h=480` from a 16:9 source yields
640×360, not 640×480. Add `:force_original_aspect_ratio=disable` for exact dims.

**MPP/RGA pkg-config + header staging.** ffmpeg needs hand-written `.pc` files
plus staged headers under `include/rockchip/` and `include/rga/` — the exact
recipe (required versions, symbols, `-Wl,-rpath`) is owned by
[`video-libraries/ffmpeg/README.md`](../video-libraries/ffmpeg/README.md).

## Infra / netboot

**Netboot the ROCK 5B is feasible on current mainline U-Boot, but not stock.** The
only usable NIC is an RTL8125B 2.5GbE over PCIe; the RK3588 internal MAC isn't
wired on this board. PCIe + RTL8125B support **is upstream now**
(`rock5b-rk3588_defconfig` has `PCIE_DW_ROCKCHIP=y` + `RTL8169=y`; the rtl8169
driver carries the `0x8125` id), so it's a U-Boot **config rebuild** (enable
`CMD_DHCP`/`CMD_TFTP`/`CMD_PXE`), not a driver port — and ~100 Mbps. For kernel
iteration, `scp` the deb + reboot is simpler than netboot.
