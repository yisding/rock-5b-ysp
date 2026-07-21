# Pipeline investigation patches

Historical `0014`–`0019` series used to localize the Firefox/readback wedge and
two focus-return symptoms. Do not apply these on top of the release series.

The useful release behavior was rebuilt cleanly as:

- root `0014`: cached GPU-copy readback fix (historical `0017`);
- root `0015`: bounded hardware encode recovery without diagnostics;
- root `0016`: progress-gated ACK-resume recovery without transition spam.

The old starvation diagnostics, watchdog actuator, and idle-baseline patch are
not shipped because the watchdog was not the readback root fix.
