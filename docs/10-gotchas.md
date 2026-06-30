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
work *around* its output (we chose **convert-in-place** — overriding Armbian's
existing DT nodes where they sit instead of replacing them — see
[`docs/08`](08-armbian-packaging.md)).

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
defaults and reverting the built-in config changes the `C####` component of the
Armbian deb name (the config-content hash — `docs/04` explains the `P####-C####`
deb-name scheme; e.g. `C89d0` → `Cb831`). Update the `PHASH` pin in
`scripts/install-combined-kernel.sh` so the installer matches the new deb.

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
instead of the remaining space. See [`docs/11`](11-bsp-audit.md).)

## Driver / probe

> These are forward-port traps **we introduced or hit** porting to 6.18. For
> latent *pre-existing* BSP defects in the same files (`mpp_iommu.c`,
> `mpp_rkvdec2.c`, `mpp_rkvenc2.c`, `mpp_common.c`) — bugs that predate this work
> — see [`docs/11`](11-bsp-audit.md), the BSP audit. Two entries below overlap it
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
enumerated in `docs/05`.

**`iommu_set_fault_handler()` WARNs on 6.18.** The new
`WARN_ON(!domain || domain->cookie_type != IOMMU_COOKIE_NONE)` inside
`iommu_set_fault_handler` (`drivers/iommu/iommu.c:2015`) fires because the BSP sets
a handler on the DMA default domain, which already owns a cookie. Guard the call
with `domain->cookie_type == IOMMU_COOKIE_NONE` in `mpp_iommu_dev_activate`
(`mpp_iommu.c:669-671`).

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
[`docs/08`](08-armbian-packaging.md)). **Caveat (latent BSP asymmetry):** only the
*probe* path learned the compatible check; `rkvdec2_remove`/`shutdown`/runtime-PM
still dispatch by `strstr(dev_name,"ccu")` (`mpp_rkvdec2.c:2119`, `:2142`, `:2148`,
`:2182`), and `rkvenc_probe` (`mpp_rkvenc2.c:3226-3228`) never gained it at all —
flagged in [`docs/11`](11-bsp-audit.md) as the `mpp_rkvdec2.c:2119`
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
