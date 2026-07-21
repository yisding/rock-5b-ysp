# RGA forward-port ABI replay gaps are fixed and pass booted replay

> Scope: RK3588 RGA3/RGA2 forward port on Linux 6.18.38; legacy
> `RGA2_GET_RESULT` and modern `RGA_IOC_REQUEST_CONFIG` staging.
>
> Source: `rkvenc-fwport-6.18@27452e30a2cfd` (fast-forwarded over fixes
> `72accfd1d5a1474e5790a9b1e46cd643ac18700f` and
> `27452e30a2cfd93ea518bb9cf0379e771808c06f`); pre-fix ABI replay run
> `20260717-230531`, the later KASAN reruns, and post-fix booted run
> `20260721-034716-kasan-narrowed` on debug build `Pb999-C4ad2`.
>
> Date: 2026-07-21
>
> Trust: **MEASURED** (pre-fix and post-fix booted ABI replay) /
> **CODE-INSPECTED**.

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

## Booted replay result — gate closed

`rkvenc-fwport-6.18` was fast-forwarded to `27452e30a2cfd`, the KASAN debug
kernel was rebuilt as `Pb999-C4ad2` (same `C4ad2` debug config as the prior
`Ped06` build; Armbian's pinned `KBUILD_BUILD_TIMESTAMP` keeps the July 4 date
string, so the discriminators are the `#2` build counter, `CONFIG_KASAN=y`,
and an md5-verified `/boot/vmlinuz` against the deb), installed, and booted.
`kasan-narrowed-repro.sh` run `20260721-034716-kasan-narrowed` then met every
gate condition:

- `RGA2_GET_RESULT` returns 0 (previously `EINVAL`);
- valid CONFIG returns 0;
- missing-pattern and unknown-mode CONFIG both return `EFAULT`
  (unknown mode previously returned success);
- `abi_status=0` — the first fully green ABI replay on a forward-port kernel —
  with `flagged_kernel_lines=0` on the surrounding KASAN/fatal scan.

Contract evidence:
`kernel-drivers/tests/logs/abi-replay/kasan-narrowed-20260721-034716.contract.log`
and run directory
`../rockchip-conformance/logs/forward-port/20260721-034716-kasan-narrowed/`.
The production package still predates these patches; rebuild, upload,
exact-image conformance, and rollback remain tracked in
[`status.md`](../status.md).

These ABI fixes do not address the separately measured RGA2 page-table DMA
ownership violation; that remains tracked in
[`2026-07-20-rga2-unmapped-page-table-dma-sync.md`](./2026-07-20-rga2-unmapped-page-table-dma-sync.md).

**2026-07-21 follow-up:** `0045`'s task validation proved too strict for the
legacy blit convention — it required `yrgb_addr` on active channels, but
legacy virtual-address requests carry the pointer in `uv_addr` with
`yrgb_addr` zero, so every legacy virtual `RGA_BLIT` regressed to `EFAULT`.
Patch `0046` relaxes the presence test to either address slot while keeping
the empty-channel and unknown-mode rejections. Details in
[`2026-07-21-rga-ffmpeg-librga-conformance-root-causes.md`](./2026-07-21-rga-ffmpeg-librga-conformance-root-causes.md).
