# RDP audio redirection: protocol, GRD, and the PipeWire graph

This ROCK 5B does not hit an RDP audio protocol limitation. The live client and
GNOME Remote Desktop (GRD) successfully negotiated server-to-client audio, but
the applications and GRD were attached to different audio servers:

```text
fluidsynth / desktop applications -> PulseAudio -> ALSA headphones
                                              X
GRD <- native PipeWire Audio/Sink nodes (none) -> RDP client
```

GRD can only forward samples that enter the native PipeWire graph. Installing
bare `pipewire` and `wireplumber` alongside a standalone PulseAudio daemon is
therefore insufficient, even though it satisfies GRD's screen-capture runtime
dependencies.

The dated hardware evidence behind this conclusion is
[`findings/2026-07-20-grd-rdp-audio-split-stack.md`](../../../findings/2026-07-20-grd-rdp-audio-split-stack.md).

## What RDP and GRD support

Microsoft's
[`MS-RDPEA` audio-output specification](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpea/bea2d5cf-e3b9-4419-92e5-0e074ff9bc5b)
defines server-to-client audio. It can use the static `RDPSND` virtual channel,
the dynamic `AUDIO_PLAYBACK_DVC` channel, or UDP after channel setup. A dynamic
channel failure is not fatal when the implementation successfully falls back to
the static channel.

The pinned GRD source at `3e4480e066d30ba44015ae1b8cb3bbb92fe6414e` has both
directions implemented:

- [`grd-session-rdp.c`](https://gitlab.gnome.org/yding/gnome-remote-desktop/-/blob/3e4480e066d30ba44015ae1b8cb3bbb92fe6414e/src/grd-session-rdp.c)
  enables `FreeRDP_AudioPlayback` and
  `FreeRDP_AudioCapture`. It creates the playback path when the client requests
  sound at the client rather than `RemoteConsoleAudio`.
- [`grd-rdp-dvc-audio-playback.c`](https://gitlab.gnome.org/yding/gnome-remote-desktop/-/blob/3e4480e066d30ba44015ae1b8cb3bbb92fe6414e/src/grd-rdp-dvc-audio-playback.c)
  first tries the dynamic playback channel and
  falls back to `RDPSND`. It negotiates AAC, Opus, or stereo PCM.
- after the training exchange, that class connects to PipeWire and enumerates
  every node whose `media.class` is `Audio/Sink`.
- [`grd-rdp-audio-output-stream.c`](https://gitlab.gnome.org/yding/gnome-remote-desktop/-/blob/3e4480e066d30ba44015ae1b8cb3bbb92fe6414e/src/grd-rdp-audio-output-stream.c)
  connects a capture stream to each discovered
  sink with `PW_DIRECTION_INPUT`; received PCM is queued, optionally encoded,
  and sent through FreeRDP.
- [`grd-rdp-dvc-audio-input.c`](https://gitlab.gnome.org/yding/gnome-remote-desktop/-/blob/3e4480e066d30ba44015ae1b8cb3bbb92fe6414e/src/grd-rdp-dvc-audio-input.c)
  implements the reverse microphone path by
  exporting a native PipeWire `Audio/Source` named
  `grd_remote_audio_source`.

The installed daemon is also linked to PipeWire, FDK-AAC, Opus, and the FreeRDP
server libraries. Audio was not compiled out.

## Live evidence from 2026-07-20

The observed system was `rock-5b`, kernel
`6.18.38-current-rockchip64`, with
`gnome-remote-desktop 50.1+rkmpp+git20260720.7e958e6-0ubuntu1~exp6`,
PipeWire 1.6.2, WirePlumber 0.5.13, and PulseAudio 17.0.

### 1. The client requested audio and negotiation completed

The handover daemon logged:

```text
[RDP.AUDIO_PLAYBACK] Failed to open AUDIO_PLAYBACK_DVC channel
  (CreationStatus -1073741823). Trying SVC fallback
[RDP.AUDIO_PLAYBACK] Client Formats: [AAC: false, Opus: false, PCM: true]
```

The second line occurs after the static-channel fallback. It proves that the
client and server found a common stereo PCM format. It also makes FDK-AAC
availability irrelevant to this particular connection.

The playback object would not exist if the client had requested that sound
remain at the remote console, so these messages also confirm the relevant
client-side redirection setting.

The Microsoft macOS Windows App trace from 2026-07-21 independently confirms
that fallback. Its active implementation is `RdpAudioOutputSVCPlugin`, and the
trace labels the path `-legacy-`; `fFromLossyChannel: 0` identifies the reliable
path. It receives the server's `SNDC_FORMATS` with three formats, emits one
`Unsupported sound format encountered` warning while choosing among them, and
writes a 42-byte client response. That is the complete fixed client-formats PDU
header/body plus one 18-byte `AUDIO_FORMAT`, consistent with the one PCM tuple
GRD later logs. The trace then writes the separate 8-byte quality-mode PDU but
contains no wave-data receipt, decoder, or renderer line. Therefore it
proves SVC negotiation, but does not prove that GRD ever called
`SendSamples2()` or that the client received `SNDC_WAVE2`.

The unsupported warning is consistent with the advertised Opus tuple, but the
client log does not name the rejected format. Removing Opus in `exp9` is an
experiment: disappearance of that single warning will establish the mapping;
otherwise AAC or another conversion boundary remains responsible.

### End-to-end audio diagnostic

Local package
`50.1+rkmpp+git20260721.10.3e4480e+audiotrace1-0ubuntu1~exp9` applies tracked
patches [`0020`](../patches/0020-rdp-log-every-client-audio-format.patch) and
[`0021`](../patches/0021-rdp-trace-audio-playback-and-disable-opus-offer.patch).
`0020` emits one normal-priority journal line for every client `AUDIO_FORMAT`,
including all scalar fields and at most 256 codec-specific bytes. `0021` adds
normal-priority markers for channel selection, formats/quality mode, training,
PipeWire setup, PCM capture, queueing, `SNDC_WAVE2` submission, and
`SNDC_WAVECONFIRM`. High-frequency capture, send, and confirm summaries are
limited to one line every five seconds.

For this temporary interoperability run, `0021` removes Opus only from the
server's advertised array. GRD still compiles and retains its Opus encoder and
matching code, so restoring the offer is a one-line change. The offer sent to
the client is AAC then PCM. This should also remove the Microsoft client's
single unsupported-server-format warning if that warning was caused by Opus;
the client trace is needed to prove that attribution.

After installing the package from a local or SSH session, restart the handover
daemon and make one fresh RDP connection. Restarting it disconnects any current
RDP session:

```bash
systemctl --user restart gnome-remote-desktop-handover.service
journalctl --user -b -u gnome-remote-desktop-handover.service \
  --grep='RDP.AUDIO_PLAYBACK'
```

The successful path should advance in this order:

```text
Server SNDC_FORMATS offer
RDPSND SVC fallback opened
Received client SNDC_FORMATS/QUALITYMODE
Client AUDIO_FORMAT
Selected client format
Sending SNDC_TRAINING
Received SNDC_TRAINING (Training Confirm)
PipeWire registry connected
Found PipeWire Audio/Sink
PipeWire stream ... streaming
PipeWire PCM capture
Queued first PipeWire PCM samples
Sent SNDC_WAVE2
Received SNDC_WAVECONFIRM
```

The first absent line localizes the stop. In particular, the delayed
`no Audio/Sink` warning proves that RDP negotiation finished but PipeWire had
nothing GRD could capture. Repeated `pcm_all_zero=true` or `sink_muted=true`
locates the failure in the captured signal. `Sent SNDC_WAVE2` without
`SNDC_WAVECONFIRM` moves the investigation to the client or transport. A wave
confirm proves client receipt, not necessarily successful speaker rendering.

Compare any returned compressed formats with GRD's exact tuples:

| Codec | Tag | Channels | Rate | Average bytes/s | Align | Bits | `cbSize` |
|---|---:|---:|---:|---:|---:|---:|---:|
| AAC | `0xA106` | 2 | 44100 | 12000 | 4 | 16 | 0 |
| Opus | `0x704F` | 2 | 48000 | 12000 | 4 | 16 | 0 |
| PCM | `0x0001` | 2 | 44100 | 176400 | 4 | 16 | 0 |

The captured Microsoft macOS client returned exactly one format: stereo
44.1-kHz, 16-bit PCM with `nAvgBytesPerSec=176400`, block alignment 4, and
`cbSize=0`. It offered neither AAC nor Opus. If a future compressed tag is
present but any other field differs, GRD's exact-match test—not codec
availability—is rejecting the near match. During `exp9`, Opus cannot be
selected because it is intentionally absent from the server offer; AAC remains
preferred over PCM if the client returns the exact AAC tuple.

### 2. ALSA and PulseAudio had real audio

ALSA exposed the ES8316 playback and capture device:

```text
0 [rk3588es8316]: rk3588-es8316 - rk3588-es8316
  playback: pcmC0D0p
  capture:  pcmC0D0c
```

PulseAudio reported the headphones sink as `RUNNING`, not muted, and at 48%
volume. It also had a live stereo 48 kHz sink input from FluidSynth:

```text
Default Sink: alsa_output.platform-analog-sound.HiFi__Headphones__sink
application.name = "ALSA plug-in [fluidsynth]"
application.process.binary = "fluidsynth"
```

This proves that an application was producing audio and the physical playback
path existed. It does not by itself prove that the headphone signal was
audibly correct.

### 3. PipeWire had no audio object for GRD to capture

At the same time, `wpctl status -n` showed empty `Devices`, `Sinks`, `Sources`,
and `Streams` sections under `Audio`. Only video devices were present.

The package state explained the split:

```text
installed:     pulseaudio, pipewire, wireplumber, libspa-0.2-modules
not installed: pipewire-pulse, pipewire-audio, pipewire-alsa
```

The standalone PulseAudio daemon owned the application/ALSA graph while GRD
looked exclusively at the separate native PipeWire graph. With no
`Audio/Sink` global, GRD never creates a `GrdRdpAudioOutputStream`, receives no
PCM buffers, and has nothing to place on the already-negotiated RDP channel.

Current `/dev/snd` ACLs granted the active GDM greeter access rather than the
headless user session. That is relevant to whether a remote session can open a
physical ALSA device, but it is not necessary for RDP output when PipeWire
provides a virtual/fallback sink. The decisive failure in this run is that the
application and GRD graphs do not meet at all.

## Fix the system graph

Use Ubuntu's complete PipeWire desktop-audio set, not bare PipeWire:

```bash
sudo apt install pipewire-audio
sudo reboot
```

On the captured Resolute system, `apt-get -s install pipewire-audio` proposed:

- install `pipewire-audio`, `pipewire-pulse`, `pipewire-alsa`, and the Bluetooth
  SPA dependencies;
- remove `pulseaudio` and `pulseaudio-module-bluetooth`; and
- keep desktop consumers by satisfying their PulseAudio API through
  `pipewire-pulse`.

The YSP system-stack installers now request `pipewire-audio` explicitly and
treat those two standalone-PulseAudio packages as intentional replacements.
Review the APT simulation before applying the clean-migration transaction.

After reboot, validate the graph before reconnecting RDP:

```bash
pactl info | grep '^Server Name'
wpctl status -n
```

Expected results:

- `pactl` identifies the PulseAudio-compatible server as PipeWire;
- `wpctl` lists at least one `Audio/Sink` (physical or fallback);
- application playback appears under PipeWire `Streams`; and
- the RDP client is configured to play remote audio on the client.

Then connect and play a known stereo signal. The acceptance gate is all of:

1. the GRD journal reaches `Client Formats` without terminating the audio
   protocol;
2. `wpctl status` shows the playback application and a sink while the RDP
   session is active;
3. the client renders the signal with the expected channel mapping and without
   sustained stutter;
4. local mute and volume changes behave as expected; and
5. the result survives a disconnect/reconnect and reboot.

## What belongs in GRD and what does not

No new RDP transport or codec implementation is needed for this failure. A
GRD-only virtual sink would also not repair applications that remain connected
to a standalone PulseAudio server.

Two upstream-quality improvements remain reasonable:

- emit a delayed, rate-limited warning when audio negotiation succeeds but no
  PipeWire `Audio/Sink` appears; sinks may arrive later, so absence at registry
  startup is not immediately fatal; and
- define/test the expected fallback-sink behavior for headless remote-login
  sessions that have no `/dev/snd` ACL or physical output.

Those would improve diagnosis and headless behavior. The first functional fix
for this image is still to unify desktop audio and GRD in the PipeWire graph.

## Evidence boundary

The 2026-07-20 run establishes ALSA enumeration, a live PulseAudio playback
stream, successful RDP output-format negotiation, and an empty PipeWire audio
graph. The PipeWire migration was only APT-simulated during diagnosis. It has
not yet established post-migration client playback, microphone redirection,
physical capture quality, HDMI audio, Bluetooth audio, channel mapping,
disconnect/reconnect durability, or reboot persistence.
