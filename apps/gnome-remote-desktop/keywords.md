# apps/gnome-remote-desktop — keywords

GRD hardware-encode terms. Cross-cutting vocabulary is in
[`../../glossary.md`](../../glossary.md).

- **GRD** — GNOME Remote Desktop; the app the hardware H.264 backend plugs into.
- **RDP** — the Remote Desktop Protocol GRD speaks; the backend feeds it encoded
  frames.
- **h264_rkmpp backend** — the FFmpeg MPP encoder path GRD uses for hardware encode
  (60 fps vsync-bound, ~1.26 ms median MPP encode).
- **AVC420 / CAPROGRESSIVE** — the RDP H.264 profile and the progressive-codec
  fallback; backpressure recovery cycles AVC420 → CAPROGRESSIVE → AVC420.
- **IDR** — instantaneous decoder refresh (key) frame; `MPP_ENC_SET_IDR_FRAME` /
  force-key-unit handling.
- **handover-reconnect** — the parked fork fix (`rdp-handover-reconnect`,
  `a3a1a32`) awaiting upstream submission.
- **zero-copy capture (PBO / MemFd)** — the async-PBO and MemFd prototype worktrees
  for the capture path (dev-box SPOFs on the status.md watchlist).
- **panvk RGB→NV12** — the color-convert step done on the Mali GPU; ties to
  [`../../video-libraries/mesa/`](../../video-libraries/mesa/README.md).
- **GDM greeter ACL** — the login-screen device-access rule (the `gdm-hwenc`
  packaging piece).
