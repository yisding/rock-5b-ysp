# Gotchas & workarounds

Every trap we hit, with the fix. Roughly ordered build → DT → driver → runtime →
userspace → infra.

## Build / patching

**`hack/` files look deletable — they aren't.** `mpp_rkvdec2.c` `#include`s
`hack/mpp_rkvdec2_hack_rk3568.c`; removing the `hack/` dir fails the build
(`No such file or directory`). The other-SoC bodies are `#ifdef`'d out on RK3588
but must exist. Keep all six.

**Armbian's Python patcher is last-write-wins, core-after-user.**
`lib/tools/patching.py` indexes patches by basename; **core** patches are appended
*after* userpatches, so for a same-name file **core wins**. A same-named empty
userpatch will **not** shadow/disable a core patch (this is the opposite of the
older bash `patching.sh`). To neutralize a core patch you must either edit it or
work *around* its output (we chose convert-in-place — `docs/08`).

**Two `base.dtsi` patches can collide on the same hunk.** Our encoder/`rkvdec_ccu`
block and Armbian's `media-0001` `vdec` block both land in the
`vepu121_3_mmu → av1d` gap, so we relocate ours to **after `av1d`** to stop the
hunks overlapping. Exact `@@` anchors and reasoning in
[`docs/08`](08-armbian-packaging.md) (§ the `av1d` relocation).

**ccache silently off if passed as an env var.** Armbian relaunches in Docker and
only forwards parsed `KEY=VALUE` **cmdline** args (`ARMBIAN_CLI_RELAUNCH_PARAMS`,
parsed in `lib/functions/cli/utils-cli.sh`); `USE_CCACHE=yes ./compile.sh`
(env var) is dropped → `Ccache result: hit=0 miss=0 (0%)`. Pass it as an
**argument**: `./compile.sh kernel BOARD=rock-5b … USE_CCACHE=yes`
(`scripts/build-combined-kernel.sh` does this). First build is cold (~80–90 min,
seeds ~5 GB); subsequent patch-only builds hit the cache (~10–15 min). Worktree
re-patching churns mtimes and defeats Armbian's *worktree-incremental*, but
content-addressed ccache survives it.

**Config-hash component changes legitimately.** Moving config into Kconfig
defaults and reverting the built-in config changes the Armbian deb name's `C####`
component (e.g. `C89d0` → `Cb831`). Update `install-combined-kernel.sh`'s `PHASH`.

## Device tree

**Missing aliases → no `core_id` → crash.** `of_alias_get_id(np,"rkvenc"/"rkvdec")`
must resolve. Without `aliases { rkvenc0 = …; rkvdec0 = …; }`, cores get bad
`core_id`, none becomes core 0, decoder defers/oopses.

**DT-overlay aliases resolve to the wrong path.** In a configfs/overlay DT, an
alias resolves to `/fragment@0/__overlay__/rkvdec-core@…`, not the merged node, so
`of_alias_get_id` fails. **Use an in-tree DT** (built-in kernel), not an overlay.

**`fdc40000` vs `fdc48000` for decoder core 1.** Vendor BSP says `fdc48000`;
TRM-canonical (and mainline/Armbian) is `fdc40000` — the BSP address is the
`+0x8000` mirror in the 64 KB window. Use `fdc40000`. Confirmed on hardware.

**Reg/unit-address "mismatch" warnings are benign.** Node is `…@fdc38000` but
`reg[0]` starts at `fdc38100` (the function window). DTC warns; it's harmless and
pre-exists in mainline's own nodes.

## Driver / probe

**A `*-core@…` node *requires* its CCU.** Both encoder and decoder dispatch by
`strstr(np->name,"core")` to a CCU-attaching probe with no standalone fallback.
Enable the CCU with the cores or you get `attach ccu failed` and an absent core.
(We spent a build discovering this when the encoder regressed: `rkvenc_ccu` was
left disabled while `rkvenc0` still referenced it.)

**Probe ordering: defer, don't fail.** A core can probe before its CCU sets
`drvdata`, or a secondary core before core 0. The BSP returned `-ENOMEM`/oopsed;
we return `-EPROBE_DEFER` (and publish CCU `drvdata` last). Six sites — see
`docs/05`.

**`iommu_set_fault_handler()` WARNs on 6.18.** New `cookie_type != IOMMU_COOKIE_NONE`
assertion fires because the BSP sets a handler on the DMA default domain. Guard
the call with `domain->cookie_type == IOMMU_COOKIE_NONE`.

**`CONFIG_CPU_RK3588` is never defined** in mainline/Armbian configs, so the BSP's
guarded `of_device_id` entries don't register. Make the RK3588 match entries
unconditional.

**Node-name dispatch blocks node *reuse*.** Because dispatch keys off the node
*name*, you can't rename Armbian's `video-codec@…` nodes via a label override.
Solution: also dispatch by **compatible** (`of_device_is_compatible`), which lets
the generic-named node reach `core_probe` — the enabler for convert-in-place.

## Runtime

**Never `rmdir` a live configfs DT overlay.** Removing/re-applying a configfs
overlay at runtime deadlocks configfs (`D`-state, cascades to an `rtnl_lock`
wedge; unrecoverable without reboot). Apply once per boot; to reset, **reboot**.
(Another reason the project uses a built-in kernel, not overlays.)

**KASAN/vermagic kernel-variant collision (early `.ko` phase).** The Armbian debug
(KASAN) kernel and stock kernel share the same `uname -r`, so they collide in
`/lib/modules` + `/usr/src`. A `.ko` must be built against headers matching the
*running* kernel's KASAN/MODVERSIONS setting or it won't load. Moot once the
driver is `=y` built-in.

**HW codec nodes are root-only — and the `mpp_service` rule alone isn't enough.**
`/dev/mpp_service`, `/dev/rga`, *and* the DMA-heaps under `/dev/dma_heap/` all
default to `crw------- root root`. The non-obvious trap: granting only the codec
ioctl node (`mpp_service`) still leaves the encoder **dead**, because `rkmpp`
allocates every frame/stream buffer from a DMA-heap (its allocator wants
`system-uncached`, remaps down to `system`). Without dma-heap access, MPP init
fails — even though `mpp_service` opens fine:

```
mpp_dma_heap: open dma heap ... failed!
mpp_buffer:   MppBufferService get_group failed to get allocater ... type 1
hal_h264e_vepu580: init vepu buffer failed ret: -1
mpp: error found on mpp initialization        →  Conversion failed!
```

Install `scripts/99-rockchip-codec.rules`, which grants the **`video`** group all
three: `KERNEL=="mpp_service"`, `KERNEL=="rga"`, and **`SUBSYSTEM=="dma_heap"`**
(matched by subsystem because the heap node's kernel name is just `system`, not
something codec-specific). Then be in the `video` group. Upstreamed to Armbian as
PR [armbian/build#10085](https://github.com/armbian/build/pull/10085).

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
`madisongh/rockchip-librga`. We linked airockchip's prebuilt aarch64 `.so` purely
for convenience — it works because it shares the BSP lineage with the kernel
`/dev/rga` driver (the transcode test confirms the ABI matches). Build from the
JeffyCN source if you want a from-source userspace. `rkrga` is also optional in
ffmpeg (`h264_rkmpp`/`hevc_rkmpp` work without it; you'd lose HW scale/CSC).

**ffmpeg-rockchip fails to build on `vulkan_av1.c`.** The fork pins an older
FFmpeg that uses the *provisional MESA* Vulkan-AV1 types; modern Vulkan headers
only ship the *KHR* ones. **`--disable-vulkan`** — unrelated to the rk codecs.

**`scale_rkrga` preserves aspect ratio by default.** `force_original_aspect_ratio`
defaults to `decrease`, so `scale_rkrga=w=640:h=480` from a 16:9 source yields
640×360, not 640×480. Add `:force_original_aspect_ratio=disable` for exact dims.

**MPP/RGA pkg-config + header layout.** ffmpeg-rockchip's `configure` requires
`rockchip_mpp >= 1.3.9` with `rockchip/rk_mpi.h` and `librga` with
`rga/RgaApi.h` + `rga/im2d.h` (symbols `mpp_create`, `c_RkRgaBlit`,
`querystring`). Stage headers under `include/rockchip/` and `include/rga/` and
hand-write the two `.pc` files (see `ffmpeg/`). Link with `-Wl,-rpath,<stage>/lib`
so the binary finds the libs.

## Infra / netboot

**Netboot the ROCK 5B is feasible on current mainline U-Boot, but not stock.** The
only usable NIC is an RTL8125B 2.5GbE over PCIe; the RK3588 internal MAC isn't
wired on this board. PCIe + RTL8125B support **is upstream now**
(`rock5b-rk3588_defconfig` has `PCIE_DW_ROCKCHIP=y` + `RTL8169=y`; the rtl8169
driver carries the `0x8125` id), so it's a U-Boot **config rebuild** (enable
`CMD_DHCP`/`CMD_TFTP`/`CMD_PXE`), not a driver port — and ~100 Mbps. For kernel
iteration, `scp` the deb + reboot is simpler than netboot.
