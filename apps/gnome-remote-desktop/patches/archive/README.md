# Investigation archive

These patches preserve experiments and instrumentation used to diagnose the
release fixes. They are **not part of the release series** and package tooling
must not add them to `debian/patches/series`.

- [`pipeline-investigation/`](pipeline-investigation/) contains the original
  `0014`–`0019` diagnostic/recovery sequence. It includes periodic pipeline
  counters, a watchdog actuator, an independent diagnostics thread, and routine
  acknowledgement-transition logging. The release replaces that sequence with
  three clean patches: root-level `0014`–`0016`.
- [`audio-negotiation/`](audio-negotiation/) contains the exact client-format
  dump, playback-path trace with temporary Opus suppression, and runtime
  A-law/ADPCM negotiation probe used during the Microsoft macOS client study.
  The findings remain useful, but none of this instrumentation ships.

Files retain their original numbers so historical findings and package names
can be mapped back to the experiment that produced them.
