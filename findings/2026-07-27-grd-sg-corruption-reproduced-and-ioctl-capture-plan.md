# GRD system-heap oops reproduces 2/2 on production, and both corrupt pointers land 256 bytes below a 16 KiB boundary

> Scope: ROCK 5B kernel forward-port; the GNOME Remote Desktop RKMPP
> login-screen path. Supersedes the n=1 framing in
> [`2026-07-27-grd-sg-corruption-kasan-non-reproduction.md`](2026-07-27-grd-sg-corruption-kasan-non-reproduction.md).
>
> Source: booted production `6.18.40-ysp-rockchip64`
> (`6.18.40+rk3588av1fwport20260725-0ubuntu1~rk1`); two oops register blocks from
> the persistent journal (2026-07-27 16:36:07 and 19:38:08); production source at
> `packaging/ppa/out/work/linux-rockchip64-ysp-6.18.40+rk3588av1fwport20260725`
> (`include/uapi/linux/rk-mpp.h`, `drivers/video/rockchip/mpp/mpp_common.c`
> `mpp_dev_ioctl_common()`, `mpp_debug.h`).
>
> Date: 2026-07-27
>
> Trust: **MEASURED** / **SOURCE-INSPECTED** / **INFERRED** / **PARTIAL**

## Result

### It reproduces deterministically

Two production boots, two RDP logins, two oopses — each on the **first login of
the boot**, with no successful encoder session in between.

| | 16:36:07 (boot -1) | 19:38:08 (boot 0) | |
|---|---|---|---|
| failing entry index (`x23`) | 1 | 1 | **same** |
| entry length (`x1 - x0`) | `0x100000` (1 MiB) | `0x100000` (1 MiB) | **same** |
| `orig_nents` (`x21`) | `0x18` (24) | `0x18` (24) | **same** |
| direction (`x22`) | 0 (`DMA_BIDIRECTIONAL`) | 0 | **same** |
| ESR | `0x96000145` | `0x96000145` | **same** |
| CPU / UID | 7 / 60579 | 7 / 60579 | **same** |
| `vmemmap` (`x20`) | `fffffdffc0000000` | `fffffdffc0000000` | **same** |
| fault PFN | `0x1e0c1fc` | `0x1dbe8fc` | differs |
| recovered `page_link` | `0xfffffe0038307f00` | `0xfffffe0036fa3f00` | differs |
| `sgl` base (`x19`) | `ffff0001c3e59400` | `ffff000227370000` | differs (fresh alloc; both 1024-aligned) |

Both runs logged `Initialized FFmpeg/rkmpp encode backend` and **never**
`Created h264_rkmpp encode session`, with zero preceding DMA-API or WARNING
lines. `panic_on_oops=0`, so the board survived both.

Combined with the KASAN kernel's 9/9 clean logins and 1600 clean direct
`mpi_enc_test` sessions, KASAN masking is now the strongly supported reading.

### Both corrupt pointers share a 1-in-16384 fingerprint

The victim slot is structural but the stored value is not — and the two values
are not unrelated:

```text
page_link = x20 + PFN * 64          (x20 = vmemmap = 0xfffffdffc0000000)

16:36  PFN 0x1e0c1fc  ->  0xfffffe0038307f00
19:38  PFN 0x1dbe8fc  ->  0xfffffe0036fa3f00

both:  PFN & 0xff == 0xfc           (4 pages below a 256-page / 1 MiB boundary)
both:  page_link & 0x3fff == 0x3f00 (256 bytes below a 16 KiB boundary)
```

Entry 1 *is* an order-8 (1 MiB) chunk, so its legitimate `page_link` must be
256-page aligned. Both corrupt values instead sit exactly **4 struct pages
(256 bytes) below** a correctly 1 MiB-aligned `struct page` pointer, while the
aligned base itself is still far outside RAM.

So the stored value is not merely wild: it has the shape of a page pointer that
has been decremented by a fixed 256 bytes. Matching low 14 bits twice is a
~1-in-16384 coincidence per sample, which makes this the sharpest available clue
to the arithmetic that produced it. The reading — a `page - 4` style decrement,
or a read 256 bytes below a 16 KiB-aligned object — is **INFERRED**; only the
bit pattern is measured.

### What we do not have: the ioctl sequence

The **fatal** ioctl is certain from the trace
(`__arm64_sys_ioctl → dma_buf_ioctl → dma_buf_end_cpu_access →
system_heap_dma_buf_end_cpu_access`): `DMA_BUF_IOCTL_SYNC` (`0x40086200`) with
`DMA_BUF_SYNC_END`, and `x22 = 0` implies the `RW` direction.

Everything *before* it is source inference. The prior finding's chain —
`MPP_CMD_TRANS_FD_TO_IOVA`, then software headers, then `mpp_enc_hal_start()` →
`mpp_buffer_sync_partial_end()` → the full-buffer sync — has never been observed
on this machine.

An ABI detail reframes what "the exact ioctls" even means: MPP exposes only
**two** ioctls, `MPP_IOC_CFG_V1` (`0x40047601`) and `MPP_IOC_CFG_V2`
(`0x40047602`). Every `MPP_CMD_*` is a sub-command carried in
`struct mpp_request.cmd`, not a distinct ioctl. A raw ioctl trace would
therefore be short and nearly uninformative; the sub-command order is the
substance. (`strace` is not installed on this board, and MPP sub-commands would
be opaque to it regardless.)

## Next test — pre-registered

The vendor driver already carries the instrumentation, so this needs no patch,
no rebuild, and one root write. `mpp_dev_debug` is a live `0644` module
parameter, currently `0`:

| Bit | Flag | Logs |
|---|---|---|
| `0x10` | `DEBUG_IOCTL` | `cmd %x process` — every sub-command, in order |
| `0x08` | `DEBUG_IOMMU` | `fd %d => iova %08x` — the import/map step |

### Procedure

1. Reboot into production `6.18.40-ysp-rockchip64`; confirm `uname -r`, taint
   `0`, and a `0/0/0/0` baseline for handovers, backend inits, encoder sessions,
   and oopses.
2. Arm before connecting:
   `sudo sh -c 'echo 0x18 > /sys/module/rk_vcodec/parameters/mpp_dev_debug'`
3. One RDP login at `2064x1296`, exactly as in the two reproductions.
4. Capture `journalctl -k -b` and `journalctl -b` whole; the trace is chatty and
   `loglevel=1` keeps it off the console but not out of the journal.

### What each outcome means

- **Sub-command sequence ends at `0x401` (`MPP_CMD_TRANS_FD_TO_IOVA`) with an
  `fd => iova` line, then the oops** — confirms the inferred chain and pins the
  corruption window between a successful map and the first CPU-access-end sync.
- **Further sub-commands appear after the import** (register writes, a poll)
  — the window is wider than the prior finding assumed, and anything in that gap
  becomes a candidate writer.
- **No `fd => iova` line before the oops** — the buffer was never mapped through
  the path the finding assumes, which would invalidate the attribution of the
  faulting table to the encoder's own attachment.

Independently of which, the guard patch's `begin_cpu_access` / `end_cpu_access`
reports will interleave with these lines on a guarded kernel, giving one ordered
timeline of MPP sub-commands and dma-buf syncs.

## Boundary

- The writer is still unidentified. This records determinism, a value
  fingerprint, and a capture plan — not attribution.
- 2/2 is a small sample. It establishes "reproduces on the first login of a
  boot", not a rate under sustained use, and says nothing about whether a
  *second* login in the same boot would also fault.
- `mpp_dev_debug` observes only `/dev/mpp_service`. The fatal
  `DMA_BUF_IOCTL_SYNC` goes to the dma-buf fd and will **not** appear in this
  trace; only a guarded kernel or ftrace shows both sides.
- Enabling the trace changes timing on a path whose failure may be
  timing-sensitive. A non-reproduction under tracing is itself informative, but
  would not retire the two existing oopses.
- The `-256 byte` reading of the fingerprint is inferred from two samples. A
  third corrupt value that also satisfies `page_link & 0x3fff == 0x3f00` would
  make it near-certain; one that does not would retire it.
- `mpi_enc_test` has not been tried on the production kernel. It stayed clean
  for 1600 sessions under KASAN, but that is a different kernel, and the direct
  path omits the GPU/RGA imports GRD performs.

## Why it matters / follow-up

The guarded non-KASAN forward-port build (`rk3588-video-6.18-sgguard`, 76
patches) was started and deliberately stopped before completing; the worktree
and a warm ccache remain, so it can resume unchanged. The watchpoint extension
is written and applies cleanly on top of the guard but is not yet
compile-verified.

The fingerprint above gives that watchpoint a concrete prediction to test:
whatever code the watchpoint catches should be storing a value 256 bytes below a
16 KiB-aligned pointer. If the caught write does not have that shape, it is not
the writer this finding is about.
