# BSP-audit HIGH findings ported to the current forward-port tip

> Scope: the 16 HIGH reviewer rows in `kernel-drivers/docs/bsp-audit.md`,
> reconciled from audited base `5614909e5803` to the maintained RK3588
> MPP/RGA/AV1 forward-port through `0058@570519704bd46`
> Date: 2026-07-22
> Trust: CODE-INSPECTED / COMPILE-VERIFIED / PACKAGE-VERIFIED; runtime validation pending

## Result

The audit's 16 HIGH rows collapse to 13 distinct bugs. Two bugs were already
absent from the `0058` source:

- `23ff47eab6f682` unwinds RKVENC2 core-probe failures through
  `rkvenc2_free_rcbbuf()`, `rkvenc_detach_ccu()`, and `mpp_dev_remove()`.
- `b6ea72cb5f56e` makes RGA request-submit failures and async result-copy
  failures reach the shared `rga_request_put()` epilogue. This closes both
  duplicate `rga_drv.c:804` HIGH rows.

The other 13 reviewer rows / 11 distinct bugs are ported onto the evolved
source as `0059`-`0069`:

| Patch | Distinct HIGH fix |
|---|---|
| `0059@ee1128afb52f7` | handle failed MPP task-message allocation |
| `0060@bc9ce80684451` | validate `MPP_CMD_SET_SESSION_FD` file operations before using `private_data` |
| `0061@058b7ba10cbcd` | bound the userspace RKVDEC2 RCB register index |
| `0062@da664db65a8ae` | test the iterated decoder core's disable flag |
| `0063@61fa807b5a5be` | bound RKVENC2 class request arrays |
| `0064@cc2e9c31ed7d6` | balance every RGA acquire-fence reference |
| `0065@8b35725f5e7fc` | perform queued-job shutdown cleanup outside `irq_lock` |
| `0066@5beedb0d19f48` | reject missing required multi-plane handle buffers |
| `0067@8524d74a79252` | balance `rga_mm_get_buffer()` errors and clear its out-pointer |
| `0068@ec97d2f16203f` | unwind partial RGA handle acquisition idempotently |
| `0069@62f82902f6a1a` | require an RGA core feature superset |

`0066` and `0068` are semantic forward ports rather than mechanical replays.
They preserve the current `0050`/`0051` RGA2 page-table DMA ownership and
transient bounce mappings: missing optional zero-sized planes are skipped,
required planes are rejected before page-table construction, bounce mappings
are released before origin references, and per-job page-table DMA mappings are
unmapped once before their pages are freed.

## Verification

- all 11 commits: `scripts/checkpatch.pl --no-tree` — 0 errors, 0 warnings;
- `git diff --check 570519704bd46..62f82902f6a1a` — clean;
- native build with `PATH=/usr/sbin:/usr/bin:/sbin:/bin`:
  `make -j8 drivers/video/rockchip/` — all modified MPP/RGA objects compiled
  and both `built-in.a` archives linked;
- the ABI probe's new opt-in `ABI_PROBE_ENABLE_MPP_FOREIGN_FD=1` case passes a
  valid `/dev/null` fd to `MPP_CMD_SET_SESSION_FD` and requires `-EBADF`; its C
  source passes `-Wall -Wextra -Werror -fsyntax-only`.

## Debug package

Pinned-6.18.38 KASAN/lockdep build `Pabd5-C4ad2` completed on 2026-07-22:

- Armbian/Docker runtime: 66:32; kernel phase: 3,797 seconds; packaging: 67
  seconds;
- ccache remained enabled but the debug config transition was effectively cold:
  `hit=108 miss=14453 (0%)`;
- `linux-image`, `linux-dtb`, `linux-headers`, and `linux-libc-dev` are non-empty
  arm64 `26.08.0-trunk` Debian packages with the same full build identity;
- the packaged config enables KASAN generic/inline/vmalloc, lockdep,
  `DMA_API_DEBUG`, MPP RKVENC2/RKVDEC2/AV1, multi-RGA, pstore, and ramoops, and
  contains `# CONFIG_PANIC_ON_OOPS is not set`;
- the packaged ROCK 5B DTB contains the debug `ramoops@118000` reservation; and
- all seven source files touched by `0059`-`0069` compare byte-for-byte with
  `bsp-high-port-20260722@62f82902f6a1a` in the patched Armbian build worktree.

Package SHA-256 values:

| Package | SHA-256 |
|---|---|
| `linux-image-current-rockchip64` | `7c5b76cdff5581a2c7f34ec6938a201fc8a9b39d8ffe3f438f51021c94c580fd` |
| `linux-dtb-current-rockchip64` | `346a3d3b45f00892e8c171783c18b23635a44dca3a3cd2646da59fe95144ada9` |
| `linux-headers-current-rockchip64` | `ced3a3d4a5833c8c117f15da0425e4d9cf8d6d8e25b222df781a656bb6c429b2` |
| `linux-libc-dev-current-rockchip64` | `8dae2cb9c38207f4d81aace2ba3688d9aede2b3b4a80bc5aa1a8799d06a949cf` |

## Remaining gate

No runtime claim is made for `0059`-`0069`. Install and boot `Pabd5-C4ad2`, then
run the foreign-fd gate, crafted RCB/request bounds cases, async
acquire-fence stress, missing-plane and partial-handle failures, shutdown, and
the full MPP/librga/ABI/FFmpeg regression sweep with a clean kernel journal.
The currently booted `Pd222-C4ad2` kernel validates only through `0058` and
therefore still carries the 11 distinct bugs until replaced.
