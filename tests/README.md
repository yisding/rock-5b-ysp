# tests/

On-hardware smoke tests. All need the combined kernel booted (the four cores +
`/dev/rga` present) and run as **root** (the devices are root-only unless you
installed the udev rule).

> **Paths.** Like the scripts, these reference the original dev box layout
> (`/home/yi/Code/...`) for the MPP userspace binaries (`mpi_enc_test`,
> `mpi_dec_test` from `rockchip-linux/mpp`), the bundled clips, and the built
> `ffmpeg`. Adjust the variables near the top of each.

| Test | Exercises | Pass criterion |
|------|-----------|----------------|
| `test-decode.sh` | **decoder** (`rkvdec2`) | `mpi_dec_test` decodes bundled *software-encoded* H.264 + H.265 320×240 clips to NV12 → exit 0 + non-empty output. Software-encoded input means a failure implicates the **decoder**, not our encoder. |
| `encode-test-tiny.sh` | **encoder** (VEPU580) | `mpi_enc_test` H.264 + H.265 at 256² and 1280×720 → valid NAL-start bitstreams, exit 0, no IOMMU fault. Reports PSNR + fps. |
| `transcode-test.sh` | **full pipeline** (both decoders, both encoders, RGA ×2) | ffmpeg-rockchip: `h264_rkmpp` → `scale_rkrga` 1080p→720p → `hevc_rkmpp`, then the reverse. `rkmpp`/`rkrga` have no SW fallback, so a pass *is* proof the hardware ran. Verifies each output with `ffprobe`. |

## Run

```bash
sudo bash test-decode.sh        # decoder
sudo bash encode-test-tiny.sh   # encoder
sudo bash transcode-test.sh     # end-to-end (needs ffmpeg-rockchip built — see ../ffmpeg)
```

## Observed results (reference)

- decode: 30 frames each H.264/H.265, ~1200–1600 fps @ 320×240.
- encode: H.264 720p PSNR 53–55 dB @ ~359 fps; H.265 720p PSNR 60–62 dB @ ~297 fps.
- transcode: both directions pass at 17–42× realtime, no faults.

## Skipped / superseded

The early bring-up used a **configfs DT overlay** + an out-of-tree `.ko`
(`load.sh`, `install-boot-overlay.sh`, `probe-only.sh`, `rollback.sh`,
`run-encode-test.sh` in the original tree). That approach is **superseded** by the
built-in combined kernel and is intentionally **not** included here — the overlay
path hit an alias-resolution bug and a configfs-rmdir deadlock (see
[`docs/06`](../docs/06-gotchas.md)). There is no standalone `librga` functional
test; RGA is validated through `transcode-test.sh`.
