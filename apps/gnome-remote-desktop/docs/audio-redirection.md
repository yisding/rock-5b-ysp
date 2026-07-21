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

### Raw client format diagnostic

Local package
`50.1+rkmpp+git20260720.9.3e4480e+audiofmt1-0ubuntu1~exp8` applies tracked
patch [`0020`](../patches/0020-rdp-log-every-client-audio-format.patch). It
emits one normal-priority journal line for every `AUDIO_FORMAT` returned by the
client before GRD performs its strict comparison. Each line contains the
format tag, channels, sample rate, average encoded byte rate, block alignment,
sample depth, `cbSize`, and codec-specific data. Codec-specific data is capped
at 256 bytes so an untrusted client cannot create an unbounded journal entry.

After installing the package from a local or SSH session, restart the handover
daemon and make one fresh RDP connection. Restarting it disconnects any current
RDP session:

```bash
systemctl --user restart gnome-remote-desktop-handover.service
journalctl --user -b -u gnome-remote-desktop-handover.service \
  --grep='Client AUDIO_FORMAT|Client Formats'
```

Compare any returned compressed formats with GRD's exact tuples:

| Codec | Tag | Channels | Rate | Average bytes/s | Align | Bits | `cbSize` |
|---|---:|---:|---:|---:|---:|---:|---:|
| AAC | `0xA106` | 2 | 44100 | 12000 | 4 | 16 | 0 |
| Opus | `0x704F` | 2 | 48000 | 12000 | 4 | 16 | 0 |
| PCM | `0x0001` | 2 | 44100 | 176400 | 4 | 16 | 0 |

If `0xA106` or `0x704F` is absent, that codec is a client limitation for the
connection. If a tag is present but any other field differs, GRD's exact-match
test—not codec availability—is rejecting the near match. The diagnostic does
not force a codec or change the existing AAC, then Opus, then PCM priority.

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
