# scripts/ — surfaceless Mesa rebuild + reproducer/dEQP/piglit runners

The **build → run → validate** entry point for the Mali-G610 transfer
investigation: configure and build a surfaceless (no-X11) Panfrost Mesa on the
board, point the loader at that uninstalled build, then drive the
[`../reproducers/`](../reproducers/README.md) probes, the dEQP transfer
cluster, and the piglit subset against it. The narrative log of *using* these
scripts — the environment gotchas each one encodes and the latest on-device
results — is [`../docs/rebuild-and-test.md`](../docs/rebuild-and-test.md).

## Package brief

| Field | Contents |
|-------|----------|
| User outcome | Rebuild a local Panfrost Mesa and re-run the whole correctness battery (reproducers + dEQP + piglit) with one command each, without an X11 sysroot. |
| Developer focus | Preserve the hard-won environment fixes baked into each script: surfaceless reconfigure over the wiped `/tmp` build state, `/usr/bin/python3` ahead of a `mise` shadow, the glvnd-vendor path piglit needs, and the writable-cwd/caselist rules for dEQP. |
| Owns | `build-mesa-surfaceless.sh`, `mesa-panfrost-env.sh`, `run-repro.sh`, `run-deqp.sh`, `run-piglit.sh`, and the `deqp-gles3-transfer-cases.txt` caselist. |
| Depends on | A Mesa worktree (default `/home/yi/Code/mesa`), the reproducer sources in [`../reproducers/`](../reproducers/README.md), and external dEQP/piglit checkouts (paths overridable via env). |
| Current state | These scripts produced the 0-regression on-device results recorded in [`../docs/rebuild-and-test.md`](../docs/rebuild-and-test.md). |

## Files

| Path | One-liner |
|---|---|
| [`build-mesa-surfaceless.sh`](build-mesa-surfaceless.sh) | Reconstructs the `/tmp` native-file + llvm-config wrapper meson still references and reconfigures the tree to a **surfaceless** build (drops the X11 sysroot); pins `/usr/bin/python3` ahead of a `mise` python that lacks `mako`/`packaging`, and uses `-fuse-ld=lld`. |
| [`mesa-panfrost-env.sh`](mesa-panfrost-env.sh) | Sources runtime env for the *uninstalled* surfaceless build — `LIBGL_DRIVERS_PATH`, `GBM_BACKENDS_PATH`, `LD_LIBRARY_PATH`, `MESA_LOADER_DRIVER_OVERRIDE=panfrost`, `EGL_PLATFORM=surfaceless`. Every reproducer prints `GL_RENDERER`/`GL_VERSION` so you can confirm the local driver (not system Mesa) is exercised. |
| [`run-repro.sh`](run-repro.sh) | Compiles (if needed) and runs the blit reproducers, summarizing PASS/FAIL by "0 mismatches". Sources `mesa-panfrost-env.sh`; `MESA_BUILD` and `REPRO_SRC` overridable. |
| [`run-deqp.sh`](run-deqp.sh) | Runs a dEQP-GLES3 caselist against the surfaceless build from a writable cwd (the module dir is root-owned), pbuffer surface, explicit caselist file (wildcards are rejected; full enumeration OOM-kills here). Tails the Passed/Failed/Not-supported/Warnings summary. |
| [`run-piglit.sh`](run-piglit.sh) | Runs a piglit subset via the **glvnd EGL-vendor** mechanism (`__EGL_VENDOR_LIBRARY_FILENAMES`), *not* an `LD_LIBRARY_PATH` libEGL override — piglit binaries link glvnd and SIGSEGV on an ABI-mismatched or version-skewed libEGL. Needs a `-Dglvnd=enabled` Mesa installed to a prefix. |
| [`deqp-gles3-transfer-cases.txt`](deqp-gles3-transfer-cases.txt) | The 25-case dEQP-GLES3 transfer/precision caselist (pbo + `builtin_functions.precision.*`) fed to `run-deqp.sh`. |

## Typical flow

```bash
# 1. build (on the board; ~/Code/mesa by default)
bash build-mesa-surfaceless.sh

# 2. reproducers
MESA_BUILD=/home/yi/Code/mesa/build-codex-main bash run-repro.sh

# 3. dEQP transfer cluster
MESA_BUILD=/home/yi/Code/mesa/build-codex-main \
  DEQP=/tmp/deqp-gles-ci/modules/gles3/deqp-gles3 \
  bash run-deqp.sh deqp-gles3-transfer-cases.txt

# 4. piglit subset (needs a glvnd-enabled install prefix)
MESA_PREFIX=/home/yi/Code/mesa/install-glvnd \
  bash run-piglit.sh /tmp/piglit-results -t getteximage -t '@pbo' -t readpixels -t fbo-blit
```

See [`../docs/rebuild-and-test.md`](../docs/rebuild-and-test.md) for the full
gotcha list and the recorded results, and
[`../reproducers/README.md`](../reproducers/README.md) for what each probe checks.
