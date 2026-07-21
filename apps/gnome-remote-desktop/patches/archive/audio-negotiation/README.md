# Audio negotiation probes

Historical `0020`–`0022` patches used one diagnostic package to inspect the
Microsoft macOS client's RDP audio offer and to probe A-law/MS ADPCM/IMA ADPCM.
They established that the client accepted the exact A-law tuple and PCM but
rejected both tested ADPCM tuples. Playback remained PCM because the legacy
formats were negotiation-only and GRD has no A-law encoder path yet.

These patches contain verbose logging and temporary behavior changes, including
an Opus-offer suppression. They are archived for reproducibility and must not be
included in a release build. The implementation plan for future A-law support
is recorded in [`../../../docs/audio-redirection.md`](../../../docs/audio-redirection.md).
