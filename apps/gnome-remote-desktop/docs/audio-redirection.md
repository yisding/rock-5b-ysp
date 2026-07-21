# RDP audio redirection: protocol, GRD, and the PipeWire graph

This ROCK 5B does not hit an RDP audio protocol limitation. After completing
the PipeWire desktop-audio migration and rebooting, the Microsoft macOS client
audibly played GRD audio as stereo PCM over the static `RDPSND` channel. The
earlier silent connection had negotiated RDP audio successfully, but the
applications and GRD were attached to different audio servers:

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
[`findings/2026-07-20-grd-rdp-audio-split-stack.md`](../../../findings/2026-07-20-grd-rdp-audio-split-stack.md),
with the successful live result and Windows control summarized in
[`findings/2026-07-21-grd-rdp-audio-live-validation-and-codec-control.md`](../../../findings/2026-07-21-grd-rdp-audio-live-validation-and-codec-control.md).

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
GRD later logs. The trace then writes the separate 8-byte quality-mode PDU.
That first trace proved SVC negotiation but stopped short of proving wave
delivery; the later `exp9` GRD trace below closes that boundary.

The unsupported warning is consistent with the advertised Opus tuple, but the
client log does not name the rejected format. Removing Opus in `exp9` did not
make the client return AAC: with the reduced AAC-plus-PCM offer it still
returned only PCM. The warning alone therefore must not be used to attribute a
specific rejected tag.

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
the client is AAC then PCM. The server-side trace proves that the reduced offer
still produced a PCM-only response. A fresh client-side trace is still needed
to establish whether removing Opus also removes its single unsupported-format
warning.

For another run, install the package from a local or SSH session, restart the
handover daemon, and make one fresh RDP connection. Restarting it disconnects
any current RDP session:

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
`cbSize=0`. It returned neither AAC nor Opus. If a future compressed tag is
present but any other field differs, GRD's exact-match test—not codec
availability—is rejecting the near match. During `exp9`, Opus cannot be
selected because it is intentionally absent from the server offer; AAC remains
preferred over PCM if the client returns the exact AAC tuple.

`cbSize` is the number of codec-specific bytes appended after the fixed
`AUDIO_FORMAT` fields; it is not the size of the audio buffer or the format
structure. Zero is normal for this PCM tuple because no extra decoder
configuration is required. `nAvgBytesPerSec` describes the format's nominal
byte rate. For the returned PCM tuple it is exactly
`44100 samples/s * 2 channels * 16 bits / 8 = 176400 bytes/s` (1.4112 Mbit/s).
GRD advertises 12000 bytes/s (96 kbit/s) for each of its AAC and Opus tuples.

Tag `0xA106` in a `Server SNDC_FORMATS offer` line means that GRD offered its
Microsoft AAC tuple. It does not mean GRD sent AAC. The client omitted that
tuple from its response, GRD selected returned format 0 (PCM), and the live
trace explicitly labels every submitted packet `codec=PCM`.

### `exp9` live result: audible PCM end to end

After the complete PipeWire packages were installed and the machine rebooted,
a fresh connection advanced through every diagnostic boundary:

```text
Server SNDC_FORMATS offer: AAC=true, Opus=false, PCM=true
Failed to open AUDIO_PLAYBACK_DVC ... Trying SVC fallback
RDPSND SVC fallback opened
Client AUDIO_FORMAT[1/1]: tag=0x0001 (WAVE_FORMAT_PCM), ...
Selected client format ... codec=PCM
Received SNDC_TRAINING (Training Confirm)
Found PipeWire Audio/Sink: id=34, name=auto_null
PipeWire stream ... streaming
Queued first PipeWire PCM samples
Sent SNDC_WAVE2 codec=PCM raw_bytes=4096 wire_bytes=4096
Received SNDC_WAVECONFIRM
```

The first capture buffer was silent and later buffers contained nonzero
samples, which is normal during stream startup. Wave confirmations continued,
and the user heard the redirected audio. This proves source samples reached
GRD, GRD submitted PCM, and the macOS client received and rendered it.

### DVC rejection is not the AAC blocker

A control trace of the same macOS Windows App connecting to a Windows server
shows the same transport behavior as the GRD connection:

- the client registers and opens `RdpAudioOutputSVCPlugin` / `RDPSND`;
- the server attempts `AUDIO_PLAYBACK_DVC` twice;
- the client reports that it cannot find an `AUDIO_PLAYBACK_DVC` listener and
  returns `-1073741823` (`0xC0000001`, `STATUS_UNSUCCESSFUL`); and
- audio continues through the reliable legacy/SVC controller.

Later generic `DynVC` messages in that log are not proof that audio playback
changed transport; the client has dynamic listeners for channels such as
graphics, input, echo, and audio input, but not audio playback. Windows and GRD
therefore receive the same DVC rejection from this client and both fall back to
SVC. Repairing GRD's DVC attempt would not make this client advertise AAC, and
SVC and DVC use the same MS-RDPEA format negotiation.

<a id="sndc-wave-codec-boundary"></a>
### `SNDC_WAVE` names a PDU, not a codec

The Windows control advertises 30 server formats and later sends 8192-byte
`SNDC_WAVE` PDUs with `format: 1`. That does not by itself mean PCM:
`SNDC_WAVE` is an audio-data message, while the format index tells the client
which negotiated `AUDIO_FORMAT` describes its payload. The index is meaningful
only with the client's filtered format-response list, which the available log
does not print.

Two successive Windows packets have audio timestamps 51664 and 51852, a
188-ms delta. Treating one 8192-byte packet as approximately that much audio
gives about 43.6 kB/s. That is inconsistent with both GRD's PCM tuple
(176.4 kB/s; 8192 bytes is 46.4 ms) and GRD's AAC tuple (12 kB/s; 8192 bytes is
682.7 ms), but is close to common legacy RDP formats around 44 kB/s. The packet
is also exactly four 2048-byte blocks, which makes Microsoft or IMA/DVI ADPCM
particularly plausible. A-law at a matching average byte rate remains
possible. This rate/timestamp observation is evidence for a legacy compressed
format, not proof of its exact tag; the selected response tuple or a packet
capture is still required.

The observed rate is close to these concrete legacy tuples from the Windows
offer:

| Candidate | Channels/rate | Average bytes/s | Block align | 8192-byte duration |
|---|---:|---:|---:|---:|
| Microsoft ADPCM | 2 / 44100 | 44359 | 2048 | 184.7 ms |
| IMA/DVI ADPCM | 2 / 44100 | 44251 | 2048 | 185.1 ms |
| G.711 A-law | 2 / 22050 | 44100 | 2 | 185.8 ms |

All are close enough to the 188-ms observation that timing alone cannot
distinguish them. The four-block packet shape adds weight to ADPCM, but does
not eliminate A-law or transport scheduling effects.

The likely legacy codecs work differently:

- **G.711 A-law** (`WAVE_FORMAT_ALAW`, tag `0x0006`) lossily and
  logarithmically compands each linear PCM sample into one 8-bit value. It is
  simple and low latency, but is generally less efficient than modern music
  codecs.
- **ADPCM is lossy.** It predicts each sample and quantizes the prediction
  error, commonly into about four bits, so decoding reconstructs an
  approximation rather than the original PCM sample. Microsoft ADPCM
  (`WAVE_FORMAT_ADPCM`, `0x0002`) and IMA/DVI ADPCM
  (`WAVE_FORMAT_DVI_ADPCM`, `0x0011`) use different, incompatible block state
  and adaptation rules.

At roughly 44 kB/s these legacy formats use about 354 kbit/s, around one
quarter of this stereo PCM stream, but substantially more bandwidth than GRD's
96-kbit/s AAC/Opus configurations. They remain interesting because the client
appears to interoperate with them on the Windows control even though it does
not return GRD's AAC tuple.

GRD's current playback encoder cannot simply enable either candidate in its
offer. Its DSP has an A-law decoder for the opposite audio-input direction, but
the playback encode and packet-size cases for A-law assert as unreachable.
ADPCM is not represented in GRD's playback DSP codec enum. Supporting one of
these formats requires an encoder, block/packet sizing, a precise
`AUDIO_FORMAT` tuple, and interoperability tests; adding an array entry alone
would advertise data GRD cannot produce.

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

The live migration also shows why the reboot matters. After the new PipeWire
packages were installed, dpkg already showed the old `pulseaudio` package as
removed, but its pre-existing user daemon still owned
`/run/user/1000/pulse/native`; `pipewire-pulse` was inactive and `wpctl` still
showed no audio sinks. Restarting only GRD could not repair that split. The
reboot removed the stale process, brought up the new user audio graph, and let
GRD discover `Audio/Sink` node `auto_null`. A reboot is not a protocol
requirement, but it was the clean and necessary completion of this live audio
server replacement.

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

No new RDP transport or codec implementation was needed to fix the silence. A
GRD-only virtual sink would also not repair applications that remain connected
to a standalone PulseAudio server.

Two upstream-quality improvements remain reasonable:

- emit a delayed, rate-limited warning when audio negotiation succeeds but no
  PipeWire `Audio/Sink` appears; sinks may arrive later, so absence at registry
  startup is not immediately fatal; and
- define/test the expected fallback-sink behavior for headless remote-login
  sessions that have no `/dev/snd` ACL or physical output.

Those would improve diagnosis and headless behavior. The first functional fix
for this image was to unify desktop audio and GRD in the PipeWire graph.

Compressed playback is a separate interoperability improvement. The macOS
client does not accept GRD's AAC tuple, and its Windows control indicates a
legacy compressed format over SVC. The next discriminating experiment is to
capture the Windows client-format response or implement and offer one exact
legacy format at a time. Chasing DVC first has no supporting evidence: this
client rejects audio playback DVC against Windows too.

## Evidence boundary

The 2026-07-20 run establishes ALSA enumeration, a live PulseAudio playback
stream, successful RDP output-format negotiation, and an empty PipeWire audio
graph. The 2026-07-21 `exp9` run establishes the migration across one reboot,
native PipeWire sink discovery, nonzero PCM capture, PCM `SNDC_WAVE2`
submission, wave confirmation, and audible macOS client rendering over the SVC
fallback.

It does not establish AAC, A-law, or ADPCM selection, the exact codec in the
Windows control, microphone redirection, physical capture quality, HDMI or
Bluetooth audio, full channel-mapping coverage, or repeated
disconnect/reconnect durability. The temporary diagnostics and Opus-offer
change are not yet publication or upstream candidates.
