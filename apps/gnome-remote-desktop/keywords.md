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
- **handover-reconnect** — the corrected fork series
  (`rdp-handover-reconnect-v2`, `eb91daf`): restore GNOME 50's two-stage
  `SetRemoteId` flow, fix handover ownership/timeout cleanup, and coalesce only
  sockets that are concurrently pending.
- **zero-copy capture (PBO / MemFd)** — the async-PBO and MemFd prototype
  worktrees for the capture path, still tracked as dev-box-only artifacts in
  the status watchlist.
- **panvk RGB→NV12** — the color-convert step done on the Mali GPU; ties to
  [`../../video-libraries/mesa/`](../../video-libraries/mesa/README.md).
- **GDM greeter ACL** — the login-screen device-access rule (the `gdm-hwenc`
  packaging piece).
