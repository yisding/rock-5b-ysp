# Armbian packaging — the `media-0001` conflict and the convert-in-place fix

This is the part that was genuinely tricky: **Armbian already backports a
mainline rkvdec driver**, and it collides head-on with our vendor decoder. The
goal was to ship everything as **userpatches with zero edits to Armbian's own
files** — and getting there took three attempts.

## The conflict

Armbian's `rockchip64-current` carries a backport patch:

```
patch/kernel/archive/rockchip64-6.18/media-0001-Add-rkvdec-Support-v5.patch
```

Among other things it adds the **mainline V4L2 stateless decoder** device-tree
nodes to `rk3588-base.dtsi`:

```dts
vdec0: video-codec@fdc38000 { compatible = "rockchip,rk3588-vdec"; ... iommus=<&vdec0_mmu>; sram=<&vdec0_sram>; };
vdec1: video-codec@fdc40000 { compatible = "rockchip,rk3588-vdec"; ... };
vdec0_mmu: iommu@fdc38700 { ... };   vdec1_mmu: iommu@fdc40700 { ... };
vdec0_sram / vdec1_sram   (RCB pools under system_sram2@ff001000)
```

Our **vendor** decoder lives at the **same addresses** (`fdc38000` / `fdc40000`,
mmus at `…700`, same SRAM pools). Two nodes at one address, two drivers fighting
for the same MMIO → you must remove one set. The whole question is *how*, without
editing `media-0001`.

## Attempt 1 — edit `media-0001` (the "hybrid"). Works, but a built-in edit.

`sed`-delete the `vdpu381` vdec sub-block out of the built-in patch, then let our
patch add the vendor nodes. **Functional** (this is how the `P8c75` build was
made) but it's a fragile line-number edit to an Armbian file that breaks whenever
Armbian updates `media-0001`. Rejected as the final form.

> Side discovery: Armbian's **Python** patcher (`lib/tools/patching.py`) resolves
> same-basename patches **last-write-wins with core appended *after*
> userpatches** — so a same-name userpatch override does **not** shadow a core
> patch (core wins). This is the *opposite* of the old bash `patching.sh`. So you
> can't neutralize `media-0001` with a same-named empty userpatch.

## Attempt 2 — delete-and-replace via `/delete-node/`. Collision hell.

Keep `media-0001` pristine; have our patch `/delete-node/ &vdec0` etc. and add
our own `rkvdec-core@fdc38000` nodes. Problems: our nodes collide with media's on
the `vdec0_sram`/`vdec1_sram` **labels** and the core/mmu **addresses**, all in
shared parents (`system_sram2`), needing delicate `/delete-node/` ordering that
only validates with full ~80-min builds. Abandoned.

## Attempt 3 — **convert-in-place** (the shipped solution). Zero edits.

Two insights collapse the whole problem:

1. **Dispatch by compatible** (the driver change in `docs/02`): once
   `rkvdec2_probe()` dispatches on `of_device_is_compatible("rockchip,rkv-decoder-v2")`,
   a node may keep the generic name `video-codec@…` and still reach the vendor
   `core_probe`. So we don't need to *rename* or *replace* media's nodes — we
   **override them in place**.
2. **SRAM is consumed by raw reg, not gen_pool.** The vendor decoder reads
   `rockchip,sram` via `of_address_to_resource()` + `iommu_map()` — it never uses
   the SRAM as a gen_pool and never `request_mem_region()`s it. So media's
   `pool;`/`codec-sram@` nodes are **reused untouched**.

The convert (in `patches/...-02-...dt.patch`, applied in `rk3588-rock-5b.dtsi`):

```dts
&rkvdec_ccu { status = "okay"; };            /* new node, no media equivalent */
&{/aliases} { rkvdec0 = &vdec0; rkvdec1 = &vdec1; };   /* of_alias_get_id needs these */
&vdec0 {                                     /* RETYPE media's node in place */
    compatible = "rockchip,rkv-decoder-v2";
    reg = <0x0 0xfdc38100 0x0 0x400>, <0x0 0xfdc38000 0x0 0x100>;  reg-names = "regs","link";
    clocks/clock-names/resets/reset-names = <vendor layout>;
    rockchip,ccu/srv/core-mask/taskqueue/sram/rcb-* = ...;
    status = "okay";
};
&vdec0_mmu { rockchip,disable-mmu-reset; status = "okay"; };   /* one-line delta */
&vdec1 { ... core-mask 0x00020002 ... };  &vdec1_mmu { ... };
/* vdec0_sram / vdec1_sram: reused untouched */
```

Result: **no `/delete-node/`, no relabels, no duplicate addresses**, because we
modify the *same* nodes. Retyping `compatible` also detaches them from the V4L2
`rockchip,rk3588-vdec` driver (mutually exclusive), so `CONFIG_VIDEO_ROCKCHIP_VDEC`
can stay `=m` and simply binds nothing.

### Patch-hunk collision — the `av1d` relocation
Our encoder + `rkvdec_ccu` block and media's `vdec` block both naturally land in
the `base.dtsi` gap **between `vepu121_3_mmu@fdbac800` and `av1d@fdc70000`** — both
generate `@@ -1353,6 …` hunks → they can't both apply. Fix: we **move our block to
*after* `av1d`** in `base.dtsi`, so our hunk anchors at `@@ -1366` and media's at
`@@ -1353` — non-overlapping. Both patches apply in either order.

## Config with zero built-in edits — Kconfig defaults

The drivers need `CONFIG_ROCKCHIP_MPP_SERVICE`, `…_RKVENC2`, `…_RKVDEC2`,
`ROCKCHIP_MULTI_RGA` (+ `SYNC_FILE`). Instead of editing Armbian's
`config/kernel/linux-rockchip64-current.config`, we put the enablement **in the
patch's Kconfig**:

- the sub-options (`RKVENC2`, `RKVDEC2`, `RGA_ASYNC`, …) were already `default y`,
  just **gated** by their tristate parents (`MPP_SERVICE`, `MULTI_RGA`) which had
  *no default* → `n`;
- so we add `default y` to those two parents and `select SYNC_FILE` on
  `MULTI_RGA`.

Armbian runs `make olddefconfig` (`lib/functions/compilation/kernel-config.sh`),
which **honors Kconfig `default y`** for options absent from the config. Verified
exactly as Armbian runs it: strip the options from the config, `olddefconfig`, and
they all come back `=y`. The built-in config is reverted to pristine.

→ **Net: `media-0001` pristine + kernel config pristine = zero built-in Armbian
edits.** Everything is in the two userpatches. (The config-hash component of the
Armbian deb name changes accordingly, e.g. `C89d0` → `Cb831`.)

## The ccache gotcha (build wrapper)

`USE_CCACHE` must be a compile.sh **command-line argument**, not a shell env var —
Armbian's Docker relaunch silently drops bare env vars, so ccache stays **off**
(`hit=0 miss=0`). `scripts/build-combined-kernel.sh` passes it correctly. Full
explanation (and the `ARMBIAN_CLI_RELAUNCH_PARAMS` mechanism) in
[`docs/06`](06-gotchas.md) (§ ccache).
