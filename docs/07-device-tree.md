# Device tree

`patches/rk3588-rkvenc2-02-vcodec-rga-dt.patch` touches two files:
`rk3588-base.dtsi` (the nodes, all `status = "disabled"` by default) and
`rk3588-rock-5b.dtsi` (the board enables them). The encoder and RGA are defined
**inline**; the decoder is **convert-in-place** for Armbian (see `docs/08`) or
inline for vanilla (see `docs/09`).

## Address map (from the RK3588 TRM)

| Block | Base | Notes |
|-------|------|-------|
| `rkvenc0` (VEPU580 core 0) | `fdbd0000` | + `rkvenc0_mmu@fdbdf000` |
| `rkvenc1` (VEPU580 core 1) | `fdbe0000` | + `rkvenc1_mmu@fdbef000` |
| `rkvenc_ccu` | (virtual) | coordinates the two encoder cores |
| `rkvdec_ccu` | `fdc30000` | VDPU381 CCU base |
| `rkvdec0` (VDPU381 core 0) | `fdc38000` | + `…_mmu@fdc38700` |
| `rkvdec1` (VDPU381 core 1) | `fdc40000` | + `…_mmu@fdc40700` |
| `rga3_core0` | `fdb60000` | RGA3 |
| `rga3_core1` | `fdb70000` | RGA3 |
| `rga2` | `fdb80000` | RGA2 |
| `mpp_srv` | (virtual) | shared MPP service coordinator (`/dev/mpp_service`) |

Each codec core's `reg` is two windows: function/regs (`+0x100`, size `0x400`)
and link (`+0x000`, size `0x100`), named `"regs"`, `"link"`.

### `fdc40000` vs `fdc48000` — resolved
The vendor BSP places decoder **core 1** at `fdc48000`; mainline (and Armbian's
`media-0001`) use `fdc40000`. The TRM "Address Mapping" table is decisive:
`VDPU381_core1_base = 0xFDC4_0000` (RKVDEC1, a 64 KB window). The vendor's
`fdc48000` is the `+0x8000` **mirror** inside that 64 KB window — both work, but
`fdc40000` is canonical, and it's what `media-0001` uses, so convert-in-place
requires it. **Confirmed on hardware**: core 1 probes clean at `fdc40100`. The
vendor driver has zero hard-coded decoder addresses (all access is DT
`reg_base + fixed offset`; the CCU coordinates via a logical `core-mask` bitmask,
not address), so the move is purely a DT change.

## Two things that *will* break the codecs if you forget them

### 1. Aliases are mandatory
The MPP framework derives each core's `core_id` from
`of_alias_get_id(np, "rkvenc"/"rkvdec")`. **Without the aliases**, it returns
`-ENODEV`, no core becomes core 0, and the decoder defers forever / oopses.

```dts
aliases {
    rkvenc0 = &rkvenc0;  rkvenc1 = &rkvenc1;
    rkvdec0 = &rkvdec0;  rkvdec1 = &rkvdec1;   /* or &vdec0/&vdec1 in convert-in-place */
};
```

> This bit us via a **DT overlay** alias bug: overlay aliases resolve to the
> fragment-internal path (`/fragment@0/__overlay__/rkvdec-core@…`), so
> `of_alias_get_id` failed and every core got a wrong `core_id`. In an **in-tree**
> DT, aliases resolve correctly. This is one reason the project moved from a
> configfs overlay to a built-in combined kernel.

### 2. Enable the CCU with the cores
A node named `*-core@…` always dispatches to the CCU-attaching probe (see
`docs/05`). Enable the CCU **and** both cores **and** both IOMMUs together, or you
get `attach ccu failed` and nothing registers:

```dts
&mpp_srv     { status = "okay"; };
&rkvenc_ccu  { status = "okay"; };
&rkvenc0     { status = "okay"; };   &rkvenc0_mmu { status = "okay"; };
&rkvenc1     { status = "okay"; };   &rkvenc1_mmu { status = "okay"; };
&rkvdec_ccu  { status = "okay"; };
/* + the decoder cores/mmus (inline) or the &vdec0/&vdec1 overrides (Armbian) */
```

## CCU / taskqueue / core-mask

- Encoder and decoder each share a `rockchip,taskqueue-node` (`7` for enc, `9`
  for dec) across their two cores.
- Decoder cores carry `rockchip,core-mask` (`0x00010001` core 0, `0x00020002`
  core 1) — the logical bitmask the CCU uses to schedule, independent of address.
- `rkvdec_ccu` uses `rockchip,ccu-mode = <1>` (soft CCU).

## SRAM / row-cache-buffer (RCB)

Each decoder core points at an on-chip SRAM pool via `rockchip,sram = <&vdecN_sram>`
(`@0` size `0x78000`, `@78000` size `0x77000`, children of `system_sram2@ff001000`)
and an `rcb-iova`/`rcb-info` map. The driver translates the SRAM phandle with
`of_address_to_resource()` and `iommu_map()`s the physical region as the RCB — it
does **not** use a gen_pool, which is why the convert-in-place reuses Armbian's
`pool;`-flavored SRAM nodes untouched (`docs/08`).
