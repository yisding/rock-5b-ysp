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

Note the scope: **only the decoder collides.** The encoder (`fdbd0000`/`fdbe0000`)
and the RGA cores (`fdb60000`/`fdb70000`/`fdb80000`) have no `media-0001`
counterpart, so they are added **inline / additively** in `base.dtsi` with no
conflict. Convert-in-place is a decoder-only dance.

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

1. **Dispatch by compatible** (the driver change in `docs/05`): once
   `rkvdec2_probe()` dispatches on `of_device_is_compatible("rockchip,rkv-decoder-v2")`,
   a node may keep the generic name `video-codec@…` and still reach the vendor
   `core_probe`. So we don't need to *rename* or *replace* media's nodes — we
   **override them in place**.
2. **SRAM is consumed by raw reg, not gen_pool.** The vendor decoder reads
   `rockchip,sram` via `of_address_to_resource()` (`mpp_rkvdec2.c:1834`) +
   `iommu_map()` (`:1852`) — it maps the raw physical SRAM into the codec IOMMU at
   the reserved RCB IOVA, never using the SRAM as a gen_pool and never
   `request_mem_region()`-ing it. So it does **not** conflict with media's
   `mmio-sram` driver owning the same `pool;`, and media's `pool;`/`codec-sram@`
   nodes are **reused untouched**.

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

### The convert-in-place delta — provided vs overridden vs inherited

A converted core (`&vdec0` in `rk3588-rock-5b.dtsi:151`) is a three-way merge of
the `media-0001` node and our override. Knowing which is which matters: anything
in the **inherited** column does *not* appear in our patch, so it silently
disappears if you copy this block to a board that lacks `media-0001`. (The three
columns are independent lists, not row-aligned.)

| `media-0001` provides | our override **changes** | **inherited** (kept as-is) |
|-----------------------|--------------------------|----------------------------|
| `video-codec@fdc38000` node + label `vdec0` | `compatible` → `rockchip,rkv-decoder-v2` | the node **name/unit-address** |
| `compatible = "rockchip,rk3588-vdec"` | `reg`/`reg-names` → vendor `regs`+`link` layout | **`interrupts`** (we set only `interrupt-names`!) |
| `reg`, `interrupts`, `iommus`, `power-domains` | `clocks`/`clock-names`, `resets`/`reset-names` | **`iommus = <&vdec0_mmu>`** |
| `vdec0_mmu` iommu node | all `rockchip,*` (`srv`/`ccu`/`core-mask`/`taskqueue-node`/`sram`/`rcb-*`) | **`power-domains`** |
| `vdec0_sram` / `vdec1_sram` RCB pools | `status` → `okay` | `vdec0_sram` / `vdec1_sram` (reused untouched) |

The **load-bearing inheritance is `interrupts`**: the converted `&vdec0` sets only
`interrupt-names = "irq_rkvdec0"` (`rk3588-rock-5b.dtsi:155`) and **inherits the
actual `interrupts`** from `media-0001`'s node. Copy this convert block to a board
**without** `media-0001` and the core has **no IRQ** —
`platform_get_irq(pdev, 0)` (`mpp_common.c:2206`) fails and the core never
probes. That is exactly why the vanilla/inline form (`docs/09`) must spell
`interrupts` out. The `vdecN_mmu` nodes are reused with a one-line delta
(`rockchip,disable-mmu-reset` + `status`); the `vdecN_sram` pools are reused with
no delta at all.

### Three forms of the same node

The decoder core appears in **three shapes** across these docs — same hardware,
different packaging:

| Form | Where | Looks like | Caveat |
|------|-------|-----------|--------|
| **Overlay alias** | `docs/07` | a fragment that re-aliases the cores | overlay aliases resolve to the fragment-internal path, so `of_alias_get_id` fails — why we went built-in |
| **Convert-in-place** | `docs/08` (this doc) | `&vdec0 { … }` retype of `media-0001`'s node | inherits `interrupts`/`iommus`/`power-domains` — Armbian-only |
| **Inline** | `docs/09` | a full `rkvdec-core@fdc38000 { … }` node | purely additive; must add `interrupts` + the `vdecN_sram` pools itself |

If a property is "missing" in one form, check whether the other form **inherited**
it rather than declaring it.

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
[`docs/10`](10-gotchas.md) (§ ccache).
