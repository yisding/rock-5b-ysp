# textureQueryLevels On Valhall (Mali-G610)

This documents the local Mesa commit that implements GLSL
`textureQueryLevels()` for Panfrost on Valhall (arch >= 9), and — more
durably — the Valhall texture-descriptor layout facts it encodes. These facts
were learned on the ROCK 5B and appear nowhere else in this repo.

Provenance (verified 2026-07-01 against the local Mesa tree):

| Item | Value |
|---|---|
| Commit | `a59b9dfcac1` "panfrost: lower textureQueryLevels on Valhall" (2026-06-30) |
| Branch | `panfrost-texture-blit`, pushed to `github.com/yisding/mesa` (branch of the same name) |
| Direct parent | `03184158582` — Joshua Watt's "panfrost: Enable hardware texture conversion" (2025-11-13), `Part-of:` Mesa MR [!38433](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/38433), `Reviewed-by:` Erik Faye-Lund; it flips `caps->texture_transfer_modes` from `0` to `PIPE_TEXTURE_TRANSFER_BLIT` in `pan_screen.c` |
| Upstream base | Mesa main `feeb6209135` (2026-01-27) |

MR !38433 is the same base the texture-transfer investigation grew from: the
BLIT enablement it carries is what exposed the interpolation-precision bug in
[`blit-precision.md`](blit-precision.md). One branch, two work products.

## 1. The Gap

`src/panfrost/ci/panfrost-g610-fails.txt` carried 16 `Crash` entries for
`textureQueryLevels()` — the full cross product of {`afbcp-` prefixed, plain}
x {`fs`, `vs`} x {`baselevel`, `maxlevel`, `miptree`, `nomips`}:

```text
[afbcp-]spec@arb_texture_query_levels@execution@fs-baselevel,Crash
[afbcp-]spec@arb_texture_query_levels@execution@fs-maxlevel,Crash
[afbcp-]spec@arb_texture_query_levels@execution@fs-miptree,Crash
[afbcp-]spec@arb_texture_query_levels@execution@fs-nomips,Crash
[afbcp-]spec@arb_texture_query_levels@execution@vs-baselevel,Crash
[afbcp-]spec@arb_texture_query_levels@execution@vs-maxlevel,Crash
[afbcp-]spec@arb_texture_query_levels@execution@vs-miptree,Crash
[afbcp-]spec@arb_texture_query_levels@execution@vs-nomips,Crash
```

The crash is `nir_texop_query_levels` reaching the Bifrost/Valhall backend
with no lowering: nothing consumed the texop, so the compiler aborted.

## 2. Design

Three-layer change, 56 insertions across 5 files
(`git show a59b9dfcac1 --stat`):

1. **New NIR intrinsic** — `load_texture_levels_pan` in
   `src/compiler/nir/nir_intrinsics.py`:
   `src[] = { resource_handle }`, `dest_comp=1`, `bit_sizes=[32]`,
   `CAN_ELIMINATE | CAN_REORDER`. Registered in
   `nir_divergence_analysis.c` alongside the other `_pan` resource-descriptor
   intrinsics (divergence follows the handle operand).
2. **Texop lowering** — in
   `src/gallium/drivers/panfrost/pan_nir_lower_res_indices.c` `lower_tex()`:
   `nir_texop_query_levels` is replaced with
   `nir_load_texture_levels_pan(res_handle)` where

   ```c
   res_handle = tex_offset != NULL
      ? nir_ior_imm(b, tex_offset, pan_res_handle(PAN_TABLE_TEXTURE, 0))
      : nir_imm_int(b, pan_res_handle(PAN_TABLE_TEXTURE, tex->texture_index));
   ```

   i.e. both the constant (`texture_index`) and the dynamic
   (`nir_tex_src_texture_offset`) indexing paths produce a normal Panfrost
   resource handle into `PAN_TABLE_TEXTURE`.
3. **Valhall codegen** — `va_emit_load_texture_levels()` in
   `src/panfrost/compiler/bifrost/bifrost_compile.c`
   (`assert(b->shader->arch >= 9)`; the intrinsic dispatch asserts that
   texture levels "are only lowered to descriptor loads on Valhall").

## 3. Valhall Descriptor Facts (The Durable Knowledge)

From `va_emit_load_texture_levels()` — all verified against the commit diff:

- **The lod count is readable from the shader with `LD_PKA`**
  (`bi_ld_pka_i32_to`), the same descriptor-load instruction the driver
  already uses for texel-buffer conversion descriptors
  (`va_emit_load_texel_buf_conversion_desc`, directly above it in
  `bifrost_compile.c`).
- **Descriptor table 62 is the table-of-resource-tables**: the `LD_PKA`
  table address is `pan_res_handle(62, tex_res_table)` — entry
  *tex_res_table* (e.g. `PAN_TABLE_TEXTURE`) inside table 62 yields the base
  of that resource table.
- **Texture descriptors are 32 bytes**; the byte offset of texture *i*'s
  word 2 is `32 * i + 8` (word 2 = third 32-bit word).
- **Bits 16..20 of word 2 hold `lod_count - 1`** (5-bit field, extracted with
  `bi_rshift_and_i32(word2, BITFIELD_MASK(5), 16)`); `textureQueryLevels()`
  is that field plus 1 (`bi_iadd_imm_i32_to(dst, lod_count, 1)`).
- **Const vs dynamic handle paths:** with a constant handle the table
  address and word offset are immediates
  (`bi_imm_u32(pan_res_handle(62, table))`, `bi_imm_u32(32 * index + 8)`);
  with a dynamic handle the table is `handle >> 24 & 0xff` and the index is
  `handle & 0xffffff`, so the codegen decodes the handle with
  rshift/lshift-and, multiplies the index by 32, and adds 8.

## 4. Validation

The commit removes all 16 `spec@arb_texture_query_levels@execution@*` Crash
entries (both `afbcp-` and plain variants) from
`src/panfrost/ci/panfrost-g610-fails.txt` — see §1 for the exact list.

UNVERIFIED: no local piglit run artifacts survive on the dev box (no piglit
checkout was found on 2026-07-01), so the removals are documented from the
commit itself; a fresh piglit `arb_texture_query_levels` run on the board
would re-confirm them.

## 5. Relation To The Transfer-Mode Work

Branch `panfrost-texture-blit` = upstream main `feeb6209135`
+ `03184158582` (!38433 BLIT enablement) + `a59b9dfcac1` (this commit).
The transfer-mode investigation ([`blit-precision.md`](blit-precision.md),
[`validation.md`](validation.md)) forked separately from a newer main
(`c05334058d5`, 2026-06-22) but is *conceptually* based on the same !38433
patch — see the provenance table in [`README.md`](README.md).

## 6. Build Notes (Board-Local)

Local Mesa builds on the ROCK 5B (`build-codex`, `build-codex-main`,
`build-codex-gallium`, `build-codex-piglit` in `/home/yi/Code/mesa`) use:

- a project-local ccache dir: `CCACHE_DIR=/home/yi/Code/mesa/.codex-ccache`
  (see the Build Checks section of [`validation.md`](validation.md));
- a meson **native file** (`.codex-tmp/mesa-codex-llvm22.ini`) that pins
  `llvm-config` to a two-line shell shim
  (`.codex-tmp/llvm-config-22-mesa-codex`, which just
  `exec /usr/bin/llvm-config-22 "$@"`) so Mesa configures against LLVM 22 on
  the board:

  ```ini
  [binaries]
  llvm-config = ['sh', '/home/yi/Code/mesa/.codex-tmp/llvm-config-22-mesa-codex']
  ```

Both are dev-box-local conveniences, recorded so the next Mesa build on this
board does not rediscover the LLVM pinning dance.
