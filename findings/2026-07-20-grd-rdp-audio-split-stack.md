# RDP audio negotiated successfully but PulseAudio bypassed GRD's PipeWire graph

> Scope: C12 audio and C18 GNOME Remote Desktop on ROCK 5B
> Source: live service/audio inspection plus
> `gnome-remote-desktop@3e4480e066d30ba44015ae1b8cb3bbb92fe6414e`
> Date: 2026-07-20
> Trust: MEASURED / CODE-INSPECTED / CONFIG-INSPECTED / CONFIRMED

Promoted →
[`apps/gnome-remote-desktop/docs/audio-redirection.md`](../apps/gnome-remote-desktop/docs/audio-redirection.md)
(2026-07-20). The canonical guide preserves the system identity, successful
`RDPSND`/PCM negotiation, live PulseAudio/FluidSynth path, empty native
PipeWire audio graph, GRD source path, remediation, and untested boundary.
