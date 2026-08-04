# Kernel build ccache guide

This guide explains how ccache interacts with Kbuild and the Armbian packaging
wrapper used by this repository. Its practical goal is simple: keep ordinary
source-only rebuilds warm without reusing state that should be discarded after
a configuration, toolchain, or kernel-base transition.

> **Repository invariant:** `~/Code/.ccache` is the only compiler-cache store
> for builds under `~/Code`. Build output may live under `../rock-5b/build/`,
> but ccache must not. Verify both host and container paths with
> `bash scripts/centralize-ccache.sh --status`; never work around a wiring issue
> by creating a project- or task-local cache.

The central distinction is:

> **Rebuilding is not the same as missing ccache.** Kbuild decides whether a
> compiler command must run. ccache decides whether that command can reuse a
> previously compiled result. A clean Kbuild tree can still be a warm ccache
> build, and an intact Kbuild tree can still miss ccache legitimately.

## The three layers of build identity

| Layer | What it remembers | What invalidates it | Correct response |
|---|---|---|---|
| Kbuild worktree | Object files, dependency files, generated headers, `.config`, link state | Source/header mtimes, command changes, generated config changes, cleaning or repatching the worktree | Let Kbuild rebuild, or use `CLEAN_LEVEL=make-kernel` when crossing config classes |
| ccache | Compiler results keyed from compiler identity, command line, source/preprocessor inputs, and relevant paths | Changed compiler bytes/identity, flags, generated headers, source content, architecture, or incompatible ccache settings | Preserve the cache; accept legitimate misses and fix only accidental key churn |
| Armbian artifact identity | Kernel base, patch-stack hash, config hash, and other package inputs encoded in the long package version | Any input represented by the corresponding hash component | Use the exact new `P####-C####` install hash; do not infer cache behavior from the package name alone |

Deleting Kbuild state is a correctness operation. Deleting ccache is almost
never part of that operation. The repository wrapper intentionally supports
this combination:

```bash
ARMBIAN_CLEAN_LEVEL=make-kernel \
  bash kernel-drivers/scripts/build-kernel.sh forward-port
```

That discards stale kernel objects and dependency metadata while retaining the
content-addressed compiler cache.

## What happened in the July 22 debug rebuild

The previous debug hook enabled `CONFIG_PANIC_ON_OOPS=y`. The current hook
explicitly disables it:

```text
CONFIG_PANIC_ON_OOPS=y  ->  # CONFIG_PANIC_ON_OOPS is not set
```

This is intentional. RK3588 firmware reinitializes DRAM during reset, so the
reserved ramoops region does not preserve the panic log. Keeping
`panic_on_oops=0` lets a process-context oops print its trace and leaves the
board alive long enough for persistent journald capture.

Armbian compared the new generated `.config` with the previous one and printed:

```text
Kernel configuration changed from previous build [ optimizing for correctness ]
```

That message describes **Kbuild state**, not deletion of ccache. Armbian could
not restore the old `.config` timestamp, so Kbuild had to revisit broad portions
of the tree. ccache remained enabled. Because kernel objects consume generated
configuration headers and config-dependent command lines, even a one-option
change can also cause many legitimate cache misses.

The measured result was `hit=108 miss=14453 (0%)`: 3,797 seconds for the kernel
phase and 66:32 end to end through Debian packaging. This is a concrete example
of ccache being enabled yet effectively cold because the generated build inputs
changed. The package identity also separated the inputs: the patch component
changed from `Pd222` to `Pabd5`, the unchanged seed-config component remained
`C4ad2`, and the later `H` component changed from `H5225` to `H17f8` with the
debug-hook policy.

The `0059`-`0069` HIGH-fix port is a different kind of input change. It modifies
only MPP/RGA source, so with an unchanged config, base, and toolchain it should
recompile a narrow object set and be a warm build.

## One-time cache setup

Every build under `~/Code` shares one ccache store at `~/Code/.ccache`. Create
and wire it with the tracked helper:

```bash
bash scripts/centralize-ccache.sh            # create the store and wire every build
bash scripts/centralize-ccache.sh --status   # inspect; no root, no writes
```

`bootstrap-workspaces.sh` calls the same helper, so a fresh machine is wired
automatically.

Splitting the cache per project buys nothing. ccache keys are content-addressed
over compiler identity, the full command line, and the preprocessed source, so
an aarch64 kernel cross-compile and a native Mesa build cannot collide in one
store. The only real cost of sharing is LRU competition, which is a sizing
question: the store is capped at 30 GB against a working set of roughly 13 GB.

The store's settings live in exactly one file, `~/Code/.ccache/ccache.conf`:

```ini
max_size = 30.0G
compiler_check = content
umask = 002
```

`compiler_check = content` is the correctness/performance setting that matters.
Armbian Docker images can be rebuilt with a freshly installed but byte-identical
GCC. ccache's default `compiler_check = mtime` treats the new compiler timestamp
as a different compiler and misses the entire old cache. `content` hashes the
compiler itself, so reinstalling identical bytes remains warm while a real
compiler change still misses correctly.

`umask = 002` is what keeps the store manageable. The Armbian container compiles
as **root**, so without it the cache fills with root-owned `0755` shard
directories that your own account can neither write to nor clean up. Combined
with the setgid bit the helper sets on the store, root-created entries stay
group-writable.

### Which config file ccache actually reads

ccache reads exactly one config file, and which one depends on whether
`CCACHE_DIR` is set:

| Invocation | Cache directory | Config file read |
|---|---|---|
| `CCACHE_DIR` set (Armbian container, Mesa script) | `$CCACHE_DIR` | `$CCACHE_DIR/ccache.conf` |
| `CCACHE_DIR` unset (a bare `ccache gcc` on the host) | `~/.cache/ccache` | `~/.config/ccache/ccache.conf` |

`~/.cache/ccache/ccache.conf` is **never** read. Pointing only the cache
directory at the shared store would leave host builds silently on the 5 GiB /
`mtime` defaults, so the helper links both:

```text
~/.cache/ccache               -> ~/Code/.ccache
~/.config/ccache/ccache.conf  -> ~/Code/.ccache/ccache.conf
```

The per-project paths are directory symlinks to the same store. Armbian
bind-mounts its path into the container, and Docker resolves a symlinked bind
source on the host, so the container sees the real store at
`/armbian/cache/ccache`.

Verify the store the way a build sees it:

```bash
ccache --show-config | grep -E \
  'cache_dir|compiler_check|max_size|base_dir|hash_dir|direct_mode'
ccache --show-stats
```

## Canonical build commands

Use the repository wrappers. They pin the kernel source, regenerate the patch
series, manage conflicting Armbian patches, and pass ccache correctly.

Production/combined kernel, Docker-backed by default:

```bash
PATH=/usr/sbin:/usr/bin:/sbin:/bin \
  bash kernel-drivers/scripts/build-kernel.sh forward-port
```

Debug KASAN/lockdep kernel:

```bash
PATH=/usr/sbin:/usr/bin:/sbin:/bin PREFER_DOCKER=yes \
  bash kernel-drivers/scripts/build-kernel.sh forward-port-debug
```

Native builds on a supported host must also use the system-only path so
Homebrew/Linuxbrew's `pkg-config` cannot hide Ubuntu multiarch metadata:

```bash
PATH=/usr/sbin:/usr/bin:/sbin:/bin PREFER_DOCKER=no \
  bash kernel-drivers/scripts/build-kernel.sh forward-port
```

The native Armbian path may relaunch through `sudo`; use Docker when the session
cannot satisfy that prompt.

If invoking `compile.sh` directly, `USE_CCACHE=yes` must be a **command-line
argument**:

```bash
./compile.sh kernel BOARD=rock-5b BRANCH=current \
  KERNEL_CONFIGURE=no USE_CCACHE=yes
```

This is wrong for an Armbian Docker relaunch:

```bash
USE_CCACHE=yes ./compile.sh kernel BOARD=rock-5b BRANCH=current
```

The Docker launcher reconstructs the command from parsed `KEY=VALUE` arguments
and can drop a bare environment assignment. The telltale result is
`hit=0 miss=0`: no compiler invocation was wrapped by ccache.

## Which changes should remain warm?

| Change | Kbuild behavior | Expected ccache behavior |
|---|---|---|
| Edit one MPP/RGA `.c` file | Recompile that object and relink consumers | Miss changed object; reuse unrelated compiled results |
| Change only commit message or patch filename while final source stays byte-identical | Repatching may churn worktree mtimes and trigger compiler commands | Mostly hits, because compiled content is unchanged |
| Recreate the kernel worktree at the same source/config | Kbuild state is cold | ccache should remain warm |
| Use `CLEAN_LEVEL=make-kernel` with unchanged inputs | Full Kbuild rebuild | Mostly warm ccache; link, BTF, and packaging still run |
| Rebuild the same source in a refreshed container with identical compiler bytes | Kbuild may rebuild | Warm only when `compiler_check=content` |
| Toggle a Kconfig option | Often broad recompilation/relinking | Mixed or cold depending on generated-header and command changes; legitimate |
| Switch production ↔ KASAN/lockdep config | Broad/full rebuild required | Many legitimate misses due instrumentation flags and config headers |
| Change compiler version or compiler bytes | Broad/full rebuild | Correctly cold for compiler outputs |
| Change `ARCH`, compiler family, `KCFLAGS`, `LOCALVERSION`, sanitizer flags, or kernel base | Broad/full rebuild | Correctly cold for affected outputs |
| Change only Debian metadata after compilation | No kernel compilation needed if the build system can reuse the staged image | ccache is irrelevant to packaging work |

Do not try to force hits across the rows marked legitimate. A cache hit is only
valuable when the previous result was produced from equivalent inputs.

## How paths and timestamps affect this workspace

Armbian invokes kernel make with `CCACHE_BASEDIR` set to the kernel worktree and
mounts the host build tree at a stable in-container path. This normalizes many
absolute source paths in cache keys. In the established Docker workflow,
renaming the host workspace has not invalidated the compiler cache because the
container continues to see `/armbian`.

> **That protection does not cover the worktree directory itself.** Armbian names
> the kernel worktree
> `linux-kernel-worktree/${KERNEL_MAJOR_MINOR}__${LINUXFAMILY}__${ARCH}`
> (`lib/functions/main/config-prepare.sh:284`). The kernel compiles with
> `-g -gdwarf-5` and **no** `-fdebug-prefix-map`, and ccache's `hash_dir` defaults
> to true, so the working directory is part of every object's cache key. Anything
> that changes `LINUXFAMILY` therefore relocates the worktree and invalidates the
> **entire kernel half** of the shared store — silently, and with no obvious
> symptom beyond a build that should have been warm coming back cold. This is
> exactly what happened when Armbian renamed rock-5b's `BOARDFAMILY` to
> `rockchip-rk3588`; both `6.18__rockchip64__arm64` and
> `6.18__rockchip-rk3588__arm64` still exist side by side under
> `cache/sources/linux-kernel-worktree/`. **The path cannot be pinned** —
> `LINUXFAMILY` and `LINUXSOURCEDIR` are both unconditional `declare -g`
> assignments in `config-prepare.sh` (`:141`, `:284`) that overwrite any config
> or command-line value. The mitigation is therefore to make the cache survive
> the move: `CCACHE_NOHASHDIR=1`, set from the `ysp-build-stamp` extension's
> `kernel_make_config` hook. Measured, same source in two directories with
> `-g -gdwarf-5` and `CCACHE_BASEDIR` set in both — `hits=0` by default,
> `hits=1` with `NOHASHDIR` — so `CCACHE_BASEDIR` does **not** cover the CWD.
> The cost, also measured: a reused object keeps the `DW_AT_comp_dir` of the
> build that first cached it. Full derivation:
> [`../../findings/2026-07-25-armbian-linuxfamily-rename-silent-patch-free-kernel.md`](../../findings/2026-07-25-armbian-linuxfamily-rename-silent-patch-free-kernel.md).

`-fdebug-prefix-map` is the alternative and would additionally fix
reproducibility, but it means injecting `KCFLAGS` — which this guide otherwise
tells you not to do — so `CCACHE_NOHASHDIR` was chosen as the smaller change.
The `DW_AT_comp_dir` cost is real for a KASAN kernel whose purpose is legible
traces; it was accepted deliberately, because discarding several GB of KASAN
objects every time Armbian renames something is the worse trade.

### Why a Kconfig change is not the whole story

`sloppiness` is deliberately empty in the shared store, and the reasoning is
recorded in `scripts/centralize-ccache.sh`. The short version: ccache's timestamp
check fires only when a source or include file is as new as the **current ccache
invocation**, and Armbian writes the generated headers minutes before any compile
starts — so relaxing it buys nothing here while widening the window for a
poisoned entry in a store shared with Mesa, MPP and FFmpeg. When a rebuild that
should be warm comes back cold, check the worktree path before reaching for
sloppiness.

Two timestamp effects remain distinct:

1. Regenerating and applying the patch stack changes source mtimes, so Kbuild
   may decide to invoke the compiler.
2. ccache hashes the relevant compiler inputs. If their content and command are
   equivalent, those invocations can still hit.

This is why a freshly patched worktree can report extensive Kbuild activity yet
finish much faster than a genuinely cold compile.

Avoid time-varying compiler inputs. Armbian already supplies stable
`SOURCE_DATE_EPOCH`, `KBUILD_BUILD_TIMESTAMP`, build user, and build host values.
Do not inject current timestamps, random paths, or changing `KCFLAGS` into the
kernel compile command.

## Observe every build

Armbian zeroes ccache statistics immediately before each build phase and prints
a summary afterward:

```text
Ccache result [ hit=... miss=... (...%) ]
```

Interpret it as follows:

| Result | Meaning |
|---|---|
| `hit=0 miss=0` | ccache was not in the compiler path, or no compilation occurred |
| Near-zero hits with thousands of misses on unchanged inputs | Compiler identity, config, flags, base, cache directory, or path normalization changed unexpectedly |
| A few misses after a small source edit | Healthy narrow rebuild |
| Many hits after `CLEAN_LEVEL=make-kernel` | Healthy cold Kbuild tree backed by a warm compiler cache |
| High hit rate but long link/BTF/package phase | Healthy; ccache does not cache linking, BTF generation, module installation, or Debian packaging |

For more detail, pass `SHOW_CCACHE=yes` as an Armbian argument where the wrapper
accepts extra compile arguments:

```bash
bash kernel-drivers/scripts/build-kernel.sh forward-port SHOW_CCACHE=yes
```

Or inspect the shared store separately. The host default and the Armbian cache
are now the same store, so no `CCACHE_DIR` override is needed:

```bash
ccache --show-stats --verbose
```

The debug wrapper currently accepts only its documented wrapper options, but it
still gets Armbian's normal per-phase ccache summary.

## Diagnose an unexpectedly cold build

Work down this list before clearing anything.

1. Confirm the log says `using CCACHE` and `Running ccache'd build`.
2. Confirm the result is not `hit=0 miss=0`. That pattern usually means
   `USE_CCACHE=yes` was passed as an environment variable instead of an argument.
3. Inspect the correct cache directory with `CCACHE_DIR=... ccache --show-config`.
4. Require `compiler_check = content`, especially after a Docker image refresh.
5. Compare the old and new final `.config`; do not compare only the tracked seed.
6. Check whether the kernel base commit, compiler version, `ARCH`, config class,
   sanitizer set, `LOCALVERSION`, or extra flags changed.
7. Confirm the build still resolves to the shared store, with
   `bash scripts/centralize-ccache.sh --status`. A per-project cache directory
   reappearing in place of its symlink means something recreated it locally.
8. Read verbose ccache statistics for preprocessor errors, unsupported compiler
   options, or uncacheable calls.
9. If correctness is in doubt, clean **Kbuild state first**, while preserving
   ccache:

   ```bash
   ARMBIAN_CLEAN_LEVEL=make-kernel \
     bash kernel-drivers/scripts/build-kernel.sh forward-port
   ```

10. Run a deliberately uncached comparison only when investigating a suspected
    ccache correctness problem:

    ```bash
    ARMBIAN_USE_CCACHE=no ARMBIAN_CLEAN_LEVEL=make-kernel \
      bash kernel-drivers/scripts/build-kernel.sh forward-port
    ```

That last command bypasses the cache without deleting it, so the existing warm
entries remain available after the comparison.

## Safe cleanup hierarchy

Use the least destructive level that addresses the problem:

1. Ordinary rebuild: keep Kbuild state and ccache.
2. Config-class or suspicious dependency transition: `CLEAN_LEVEL=make-kernel`,
   keep ccache.
3. Compiler-output comparison: set `ARMBIAN_USE_CCACHE=no`, keep ccache on disk.
4. Remove one bad cache entry only if ccache debugging identifies it precisely.
5. Clear the entire cache only after evidence of cache corruption, not because a
   build missed or a config changed.

Never use cache deletion as a routine response to a kernel build failure. Patch
application, Kconfig, compilation, link, BTF, and packaging failures each need
their own diagnosis; destroying correct compiler results makes that diagnosis
slower without fixing the cause.

## Pre-build checklist

- Kernel base is deliberately pinned.
- Forward-port source branch and patch count are the intended ones.
- Production versus debug config class is intentional.
- `PATH=/usr/sbin:/usr/bin:/sbin:/bin` is set for native package builds.
- `USE_CCACHE=yes` reaches `compile.sh` as an argument.
- `CCACHE_DIR` resolves to the shared store at `~/Code/.ccache`.
- `compiler_check=content` is present.
- Cache size and filesystem free space are sufficient.
- `CLEAN_LEVEL=make-kernel` is used only when Kbuild state must be discarded.
- The previous final `.config`, package hash, and ccache result are recorded when
  comparing build behavior.

Following this checklist preserves fast patch-only iteration while keeping
configuration and toolchain transitions conservative and reproducible.
