# GRD audio is audible as PCM; Windows uses the same SVC fallback

> Scope: C12 audio and C18 GNOME Remote Desktop on ROCK 5B
> Source: live `exp9` GRD journal plus Microsoft macOS Windows App verbose
> traces against GRD and a Windows server
> Date: 2026-07-21
> Trust: MEASURED / CODE-INSPECTED / CONFIRMED / INFERRED

Promoted →
[`apps/gnome-remote-desktop/docs/audio-redirection.md`](../apps/gnome-remote-desktop/docs/audio-redirection.md)
(2026-07-21). The canonical guide preserves the post-reboot PipeWire sink and
stream trace, exact PCM selection, `SNDC_WAVE2`/confirmation boundary, audible
result, same-status Windows DVC control, format-field meanings, and bounded
ADPCM/A-law inference. Raw machine and proprietary client logs remain outside
git.
