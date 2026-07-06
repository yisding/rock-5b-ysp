# Rebuilding + on-board testing the Panfrost blit series

How to rebuild the surfaceless Panfrost driver on the Rock 5B and re-run the
reproducers + the previously-failing dEQP cluster, plus the environment
gotchas that cost time. Scripts live in [`../scripts/`](../scripts).

Context for the 2026-07-02 local run below: this validates the
`panfrost-blit-transfers` branch **plus two
uncommitted `u_blitter` cleanups** (finding #2: a shared
`blitter_target_supports_txf()` predicate; finding #3: the four
`blitter_get_fs_texfetch_*` helpers now report the chosen `use_txf_fragcoord`
via an out-param so `util_blitter_blit_generic` no longer recomputes it — which
also removed the three scattered `use_txf_fragcoord = false` pack-branch
resets). Both are behavior-preserving refactors; the run below is the
regression check.

## 2026-07-06 GitLab CI update

The local results below remain useful as the scoped Rock 5B reproducer/dEQP/
piglit-subset validation for the 2026-07-02 refactor state. They are **not** the
current full upstream CI result.

Current selected MR CI status:

- !42563 (`panfrost: clear shader image mask on trailing unbinds`): selected
  x86/arm64 build + G610 GL/piglit jobs green.
- !42679 (`u_blitter: use fragment position for unscaled TXF blits`): selected
  x86 build + clang + llvmpipe + softpipe jobs green. ARM hardware was not the
  useful signal there because the shared flag defaults off.
- !42613 (`panfrost: enable blit-based texture transfers`): first selected G610
  run at tip `3ab262af7fc` was red, classified, and force-pushed to
  `a9d6caeeb53`; pipeline 1700150 then got the crash/assert roots green and
  exposed only a stale `glx-copy-sub-buffer` G610 fail expectation. Current tip
  is `8875a22856d`; rerun pipeline 1700162 passed all four selected G610
  shards.
- !42614 (`panfrost: add a Gallium test for wide blit precision`): first
  selected G610 run at tip `5bd122bbf07` inherited the !42613 failures, now
  force-pushed to `4c23f1db1f9`; rerun pipeline 1700163 passed all four
  selected G610 shards.

The visible first-run !42613/!42614 failures were transfer/readback-heavy: dEQP
`packed_pixels.pbo_rectangle.*`, `dEQP-GLES3.functional.pbo.*`, and
`KHR-GLES31.core.texture_buffer.texture_buffer_operations_framebuffer_readback`
crashes, plus piglit `pbo-getteximage`, `gettextureimage-targets`,
`cubemap-getteximage-pbo`, `max-texture-size`, and `large-tex` crashes. They
were not generic flakes. Local repro found two root causes:

1. The pushed `panfrost-blit-transfers*` branches accidentally did not contain
   the reviewed !42563 unbind fix. Earlier end-to-end Piglit/dEQP testing had
   used experimental branches that still carried it, which is why the local
   result did not match the first split-stack CI result. Without the fix,
   trailing shader-image unbinds left stale `image_mask` bits and u_blitter
   draws could crash in image descriptor emission. `pbo-getteximage -auto`
   reproduced this locally and passes after the fix is present.
2. `max-texture-size -auto -fbo` exposed a state-tracker allocation-only upload
   bug: `st_TexImage(..., pixels = NULL)` called `st_TexSubImage`, and the BLIT
   path created a huge staging texture before discovering there was no client
   data. The branch now guards the upload with `if (pixels || unpack->BufferObj)`
   so ordinary allocation-only `glTexImage*` is a no-op upload while PBO offset
   zero remains valid.

Local smoke on the force-pushed stack: `ninja -C .codex-tmp/build-g610-debug`,
`pbo-getteximage -auto`, and `max-texture-size -auto -fbo` all pass on the Rock
5B / Mali-G610.

Follow-up from the first corrected-stack rerun: `panfrost-g610-piglit:arm64
2/2` failed only as `UnexpectedImprovement(Pass)` for `glx@glx-copy-sub-buffer`.
The branch now drops that stale expectation from
`src/panfrost/ci/panfrost-g610-fails.txt`. Final selected reruns 1700162
(!42613) and 1700163 (!42614) passed all four targeted G610 shards each.

## The build was wedged by wiped /tmp state

The `build-codex-*` trees were configured against three `/tmp` artifacts that a
reboot wipes, so `ninja -C build-codex-main` died at the meson *regen* step:

- `--native-file=/tmp/mesa-codex-llvm22-extracted.ini` (and
  `/tmp/mesa-codex-llvm22.ini` for `build-codex-gallium`) — **gone**.
- `/tmp/llvm-config-22-mesa-codex` — a 1-line wrapper
  (`exec /usr/bin/llvm-config-22 "$@"`) — survived here, recreated by the script if not.
- `/tmp/mesa-x11-dev-deps/` — a staged X11 dev sysroot for the `x11` platform —
  **gone and not reconstructable** without the original .debs.

Fix (in [`build-mesa-surfaceless.sh`](../scripts/build-mesa-surfaceless.sh)):
recreate the native file and **reconfigure to surfaceless** (`-Dplatforms=
-Dglx=disabled`), which drops the X11 sysroot need entirely. The reproducers are
GBM/EGL-surfaceless on `renderD128`, so X11 was never required for testing.
Reusing the existing `build-codex-main` tree kept ~84% ccache hits
(`.codex-ccache`); the reconfigure+build took a few minutes.

Two more gotchas the script encodes:

1. **`mise` python shadows system python.** meson picks `python`/`python3` off
   PATH; the mise `python3.14` lacks `mako`/`packaging` → meson aborts with
   "One of Python (3.x) packaging or distutils module is required". Fix: pin
   `python = '/usr/bin/python3'` in the native file **and** `export
   PATH=/usr/bin:$PATH` before meson.
2. **`-fuse-ld=lld`** is baked into the stored link args → `ld.lld` must exist.

## Local test tooling (better than the state BUG.md recorded)

- dEQP is built at `/tmp/deqp-gles-ci/modules/gles3/deqp-gles3` (+ gles31, glcts).
  Plaintext mustpass for building explicit lists:
  `/tmp/deqp-gles-ci/external/openglcts/modules/gl_cts/data/mustpass/gles/aosp_mustpass/main/gles3-main.txt`.
  Gotchas: run from a writable cwd (module dir is root-owned); `--deqp-caselist`
  wildcards are rejected; full `txt-caselist` enumeration OOM-killed — use
  explicit lists.
- **piglit: now built** at `/home/yi/Code/fdo/piglit` (2026-07-03). The earlier
  `build-codex-piglit` was a Mesa drm-shim build, not the suite. The suite needs
  a glvnd-enabled Mesa *install* (not an `LD_LIBRARY_PATH` override) — see the
  piglit section below for the full recipe and the SIGSEGV gotcha.

## Results (build `git-7a6829f5b4` + the #2/#3 u_blitter cleanups, Rock 5B / Mali-G610 MC4)

Driver string seen: `Mali-G610 MC4 (Panfrost) — OpenGL ES 3.1 Mesa 26.2.0-devel`.

Reproducers (`run-repro.sh`), all **0 mismatches**:

| repro | domain | result |
|---|---|---|
| repro_blit | RG32UI→RGBA32UI readback, W=16307 | 0 / 16307 |
| repro_blit_off | subregion readback (offset term) | 0 / 8307 |
| repro_blit_float | RG32F→RGBA32F (disqualifies integer-only fallback) | 0 / 16307 |
| repro_blit_flip | flipped glBlitFramebuffer, 4 orientations | 0 / 130456 |
| repro_blit_scissor | scissored wide identity blit | 0 / 32612 |
| repro_blit_array | 2D-array layer readback | 0 / 16307 |
| repro_afbc | wide RGBA8 FBO readback, AFBC CPU-map staging | 0 / 65536 |
| probe_const | constant smooth varying, K up to 16306.5 | 0 / 16307 |

Negative control — **system** driver `Mesa 26.0.3-1ubuntu1` (unfixed), same
`repro_blit_flip`: **81960 / 130456** wrong in all 4 orientations (first at
x≈6049). Confirms the reproducer is sensitive and the driver override actually
swaps the driver.

dEQP-GLES3 previously-failing cluster (`run-deqp.sh deqp-gles3-transfer-cases.txt`,
the MR-comment list): **24/25 Pass, 0 Fail**, 1 QualityWarning
(`precision.acos.mediump_fragment.vec2`, pre-existing/unrelated). Matches the
BUG.md expectation; `pbo.renderbuffer.rgba8_clears` passes here (the earlier
"negative-threshold" harness artifact was a different local deqp rebuild).

dEQP-GLES3 `fbo.msaa.*` (70 cases): **66 Pass, 4 NotSupported, 0 Fail** —
confirms the #3 flag-threading refactor did not break the MSAA exclusion (MSAA
resolve/copy shaders must keep consuming the plain coordinate attribute).

## piglit (transfer/blit/texture subset)

piglit is now cloned at `/home/yi/Code/fdo/piglit` (cmake+ninja, deps:
`cmake python3-numpy python3-mako python3-pil libwaffle-dev`; configure with
`-DPIGLIT_BUILD_CL_TESTS=OFF -DPIGLIT_BUILD_VK_TESTS=OFF
-DPIGLIT_BUILD_DMA_BUF_TESTS=OFF` — the last avoids an `xcb-dri2` hard error).

Runner: [`../scripts/run-piglit.sh`](../scripts/run-piglit.sh). Result of the
u_blitter-relevant subset (`getteximage`, `pbo`, `readpixels`, `texsubimage`,
`copyteximage`, `fbo-blit`, `framebuffer_blit`, `copy_image`) on the fixed
build via glvnd:

**2899 pass, 0 crash, 2 fail, 173 skip** (3074 total). Both fails —
`spec@!opengl 2.1@pbo` and `spec@ext_framebuffer_blit@fbo-blit-check-limits` —
are in `src/panfrost/ci/panfrost-g610-fails.txt` (pre-existing G610 baseline
failures, **not** regressions from the #2/#3 refactor). Skips are tests needing
GL > 3.1 (panfrost desktop-GL caps at 3.1) or unsupported extensions.

### THE big gotcha: piglit needs a glvnd-enabled Mesa *install*, not LD_LIBRARY_PATH

piglit's GL test binaries link **glvnd** (`libGLdispatch`, `libGLX`, glvnd
`libGL`/`libEGL`). The surfaceless build above is `-Dglvnd=disabled`, so
prepending its non-glvnd `libEGL` on `LD_LIBRARY_PATH` (the reproducer trick)
makes **every** test SIGSEGV at context creation. Loading the 26.2 megadriver
through the *system* glvnd libEGL (26.0.3) also crashes on loader/driver ABI
skew. Two dead ends that each looked like "the driver crashes 286 tests."

Fix: a second Mesa build/install with glvnd on, selected as the glvnd EGL vendor:
```
meson setup build-codex-main --reconfigure --native-file /tmp/mesa-codex-llvm22-extracted.ini \
  -Dglvnd=enabled -Dprefix=/home/yi/Code/fdo/mesa/install-glvnd
ninja -C build-codex-main && meson install -C build-codex-main
# then, keeping SYSTEM glvnd libGL/libEGL:
export __EGL_VENDOR_LIBRARY_FILENAMES=/home/yi/Code/fdo/mesa/install-glvnd/share/glvnd/egl_vendor.d/50_mesa.json
export LD_LIBRARY_PATH=/home/yi/Code/fdo/mesa/install-glvnd/lib/aarch64-linux-gnu   # libEGL_mesa.so.0, NOT libEGL.so.1
export LIBGL_DRIVERS_PATH=.../dri GBM_BACKENDS_PATH=.../gbm MESA_LOADER_DRIVER_OVERRIDE=panfrost
```
Verified: `getteximage-formats -auto -fbo` → `pass`, renderer
`Mali-G610 MC4 (Panfrost) — GL 3.1 Mesa 26.2.0-devel`. (The reproducers/dEQP
still use the simpler non-glvnd surfaceless env; only glvnd-linked piglit needs
the vendor path.) `run-piglit.sh` encodes all of this.

Also: piglit looks for binaries at `<piglit>/bin`; for the out-of-tree cmake
build, `ln -sfn build/bin /home/yi/Code/fdo/piglit/bin` (else every test reports
"Test executable not found" as a skip).

## Still outstanding

- The desktop `arb_shader_image_load_store` tests (incl. the trailing-unbind
  area of `833101f35ed`) need GL 4.2 and **skip** on panfrost (GL 3.1 max);
  that fix is exercised via GLES 3.1 image tests / dEQP-GLES31 instead, and is
  independent of the #2/#3 u_blitter refactor.
- Re-running against a clean upstream tree (these results include the
  uncommitted #2/#3 edits in the working tree).
