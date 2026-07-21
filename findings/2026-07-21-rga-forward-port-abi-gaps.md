# RGA forward-port ABI replay gaps are fixed in source

> Scope: RK3588 RGA3/RGA2 forward port on Linux 6.18.38; legacy
> `RGA2_GET_RESULT` and modern `RGA_IOC_REQUEST_CONFIG` staging.
>
> Source: `rkvenc-fwport-6.18@655d178191807` plus fixes
> `72accfd1d5a1474e5790a9b1e46cd643ac18700f` and
> `27452e30a2cfd93ea518bb9cf0379e771808c06f`; ABI replay run
> `20260717-230531` and the later KASAN reruns.
>
> Date: 2026-07-21
>
> Trust: **MEASURED** (pre-fix ABI results) / **CODE-INSPECTED** /
> **COMPILE-VERIFIED** (fixes) / **OPEN** (booted replay pending).

## Result

The two persistent forward-port ABI replay failures have separate causes and
are now addressed by tracked patches `0044` and `0045`:

1. ioctl `0x601a` (`RGA2_GET_RESULT`) was absent from the RGA3 driver's command
   definitions and switch, so the default case returned `EINVAL`. Patch `0044`
   restores the legacy command as the same safe no-op as `RGA_GET_RESULT`.
2. `RGA_IOC_REQUEST_CONFIG` copied a task array into the live request without
   checking render modes or their required channels. A pattern-update task
   with no pattern handle therefore returned success instead of the wrapper's
   expected `EFAULT`; an unknown render mode was accepted for the same reason.
   Patch `0045` validates staged descriptors before replacement.

The second path also overwrote `request->task_list` on every successful CONFIG
without freeing the prior allocation. It allowed the list to be replaced while
the request was running. Patch `0045` rejects running-request reconfiguration,
swaps the validated list under `request->lock`, and frees the old list after
dropping the lock. A rejected replacement leaves the prior valid task list
installed.

## Verification completed

- Kernel `checkpatch.pl --strict` and `git diff --check` pass for both changes.
- Native arm64 objects `drivers/video/rockchip/rga3/rga_job.o` and
  `rga_drv.o` build from the fixed source using the installed KASAN kernel's
  exact `.config` and the system toolchain path.
- The ABI probe now distinguishes a missing required pattern channel from an
  actually unknown render mode; both require the public wrapper result
  `EFAULT`. Its normalized replay self-test covers both contract lines.

## Remaining gate

The currently booted KASAN kernel predates `0044`/`0045`, so it cannot prove
the runtime result. Rebuild and boot the exact forward-port tip, rerun
`abi-replay.sh`, and require:

- `RGA2_GET_RESULT` succeeds;
- valid CONFIG succeeds;
- missing-pattern and unknown-mode CONFIG both return `EFAULT`;
- the surrounding KASAN/fatal scan is empty.

These ABI fixes do not address the separately measured RGA2 page-table DMA
ownership violation; that remains tracked in
[`2026-07-20-rga2-unmapped-page-table-dma-sync.md`](./2026-07-20-rga2-unmapped-page-table-dma-sync.md).
