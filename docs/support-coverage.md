# ROCK 5B support coverage — what this repository has and has not assessed

This page is the repository's **scope inventory** for ROCK 5B support on
Armbian's Ubuntu 26.04 (Resolute) images. It answers a different question from
[`../status.md`](../status.md):

- this page says **which board areas the repository covers**;
- `status.md` says **what the dated evidence currently proves** for active
  workstreams; and
- an area marked `UNASSESSED` here is an explicit evidence gap, not a claim
  that the hardware is broken or unsupported by Armbian.

The inventory is shaped by Radxa's official
[ROCK 5B feature summary](https://docs.radxa.com/en/rock5/rock5b/getting-started/introduction)
and [hardware-interface reference](https://docs.radxa.com/en/rock5/rock5b/hardware-design/hardware-interface).
Those pages describe hardware capability. They do not prove that a particular
kernel, device tree, firmware, userspace, accessory, or board revision works in
this distro.

## Coverage states

| State | Meaning |
|-------|---------|
| `TRACKED` | The area has a dated status track or a maintained test/document set. Read the linked owner for whether it passes, is partial, or is still blocked. |
| `NARROW` | The repo contains useful evidence for one path, dependency, or incident, but not enough to characterize ordinary subsystem support. |
| `UNASSESSED` | The repo contains no runtime evidence that supports a distro-usage conclusion for this area. |

Coverage is about the **strength and breadth of this repository's evidence**,
not an upstream-support grade. Do not promote `UNASSESSED` to `NARROW` from
device-tree inspection alone, or `NARROW` to `TRACKED` from device-node
existence alone.

## Coverage inventory

Stable `C##` IDs let findings and test logs name the gap they address. Keep the
IDs when a row changes state; append new rows rather than renumbering old ones.

| ID | Board area | Coverage | What the repository owns today | First useful evidence to add |
|----|------------|----------|--------------------------------|------------------------------|
| C01 | Board, OS, kernel, and boot identity | `TRACKED` | [`system-baseline.md`](system-baseline.md) defines the capture contract and the conformance collector records it. | Attach a baseline capture to every hardware result; add board revision and attached peripherals manually when they matter. |
| C02 | Boot firmware and root-media selection | `TRACKED` | [`status.md` track 12](../status.md#dashboard) owns SPI, raw-SD, SD-root, and NVMe-root evidence. | Run the next gate in track 12 with UART output, exact image/build identity, and a recoverable media backup. |
| C03 | Kernel delivery, boot, validation, and rollback | `TRACKED` | Status tracks 1, 3, 4, and 9 distinguish the combined, DKMS, rewrite, and PPA paths; [`../install.md`](../install.md) owns the operator flow. | Complete the board install/reboot/revert gate for each delivery path before describing it as usable. |
| C04 | CPU cores, cpufreq, thermal control, fan, and throttling | `UNASSESSED` | No ordinary idle/load or thermal-policy result is recorded. | Capture governors and thermal zones at idle and under a bounded CPU load; record clocks, temperatures, throttling, cooling behavior, and dmesg. |
| C05 | RAM, CMA, swap, and memory-pressure behavior | `NARROW` | Media tests exercise dma-buf, IOMMU, and codec/RGA allocations, but do not characterize general memory pressure or all RAM SKUs. | Record RAM/CMA/swap configuration, then run a bounded pressure test alongside the affected workload and check for OOM/IOMMU faults. |
| C06 | microSD, eMMC, and NVMe runtime I/O | `NARROW` | Boot investigations cover selected SD and NVMe paths, not general media detection, integrity, performance, hotplug, or error recovery. | Inventory only installed media, exercise read/write integrity on disposable data, and record kernel errors and behavior across reboot. |
| C07 | 2.5 Gb Ethernet and optional PoE use | `NARROW` | [`gotchas.md`](gotchas.md) records kernel/driver history, but the repo has no dated link, throughput, loss, or reboot-resume result for this distro. | Record driver/firmware/link mode and run bidirectional `iperf3`, packet-loss, reboot, and—if used—PoE power-path checks. |
| C08 | Optional M.2 E-key Wi-Fi and Bluetooth | `UNASSESSED` | No adapter-specific runtime evidence is recorded; ROCK 5B has no onboard Wi-Fi. | Name the installed module, driver, and firmware; test association, throughput, Bluetooth discovery/use, rfkill, and reboot behavior. |
| C09 | USB 2/3 host and OTG roles | `UNASSESSED` | No port-by-port host, speed, power, disconnect, or OTG-role result is recorded. | Capture topology and negotiated speed, then exercise representative HID/storage devices and any required OTG role on each physical port. |
| C10 | DRM/KMS display outputs, hotplug, and local desktop | `NARROW` | Mesa, Kodi, GRD, and boot findings touch pieces of DRM/display, but no HDMI/USB-C-DP/DSI connector-and-mode matrix is maintained. | Record active connectors, modes, compositor/session, acceleration, hotplug, blanking, reboot, and resume for each tested output. |
| C11 | Mali-G610 GPU through Mesa/Panfrost | `TRACKED` | [`status.md` track 8](../status.md#dashboard) and [`../video-libraries/mesa/`](../video-libraries/mesa/README.md) own the current fixes and validation slices. | Follow track 8's dated next gate; do not generalize selected dEQP or reproducer results to every graphics API. |
| C12 | Audio devices, playback, and capture | `UNASSESSED` | No card/profile, playback, capture, routing, volume, or reboot result is recorded. | Record ALSA/PipeWire devices and profiles; test each physically used path for playback/capture, channel mapping, mute/volume, and reboot persistence. |
| C13 | MIPI CSI camera and ISP pipeline | `UNASSESSED` | BSP architecture notes describe the stack, but no sensor-specific ROCK 5B Resolute stream is recorded. | Name the sensor/module, capture the media graph, stream frames at a declared mode, verify output, and record ISP/IOMMU errors. |
| C14 | HDMI input/capture | `UNASSESSED` | No source lock, format negotiation, capture, audio, or long-run result is recorded. | Use a named source/mode, capture frames and audio where applicable, verify timestamps/content, and record reconnect behavior. |
| C15 | Hardware video codecs and RGA | `TRACKED` | Status tracks 1 and 5 plus [`../kernel-drivers/tests/`](../kernel-drivers/tests/README.md) own kernel, MPP, RGA, FFmpeg, and conformance evidence. | Run the owning next gate when any kernel, DT, MPP, librga, or FFmpeg input changes. |
| C16 | RK3588 NPU / RKNN runtime | `UNASSESSED` | BSP notes describe RKNPU concepts, but the repo has no userspace/runtime job on this distro. | Pin the RKNN runtime/model, record `/dev/rknpu` and driver identity, run a known-output sample on each selected core, and capture faults/performance. |
| C17 | 40-pin GPIO, I2C, SPI, UART, PWM, and related overlays | `UNASSESSED` | No pin/overlay/access-control matrix or loopback/peripheral result is recorded. | Record the exact pins, voltage-safe wiring, overlay, and userspace API; run a reversible loopback or named-peripheral test and preserve recovery access. |
| C18 | Accelerated applications: remote desktop and Kodi | `TRACKED` | Status tracks 7 and 11 distinguish the validated GRD path from Kodi's still-open build/playback gates. | Use each track's next proof and record the selected codec/render path rather than relying on a generic “hardware acceleration” toggle. |
| C19 | Package upgrade, coexistence, and recovery | `TRACKED` | Status tracks 9 and 10, [`../packaging/`](../packaging/README.md), and [`../install.md`](../install.md) own delivery and rollback constraints. | Test the exact apt transaction, reboot, functional smoke, stock rollback, and stale-package cleanup on the board. |
| C20 | Suspend/resume, shutdown, reboot, RTC, and watchdog behavior | `UNASSESSED` | Individual workflows reboot the board, but no power-management or repeated lifecycle campaign is recorded. | Run bounded repeated warm reboot and shutdown/power-on tests; separately test suspend/resume, wake sources, RTC, and watchdog only where configured. |

## Turning an unassessed area into evidence

1. Start with the machine capture in [`system-baseline.md`](system-baseline.md).
2. Test one declared hardware path and accessory set. Record detection,
   functional exercise, pass/fail signal, relevant logs, and recovery behavior.
3. Add a dated [`../findings/`](../findings/README.md) entry whose scope names
   the `C##` row. State the negative boundary: what the run did **not** test.
4. Change `UNASSESSED` to `NARROW` only when runtime evidence exists. Change a
   row to `TRACKED` when it has a durable owner and an explicit maintenance
   path—not merely because one smoke test passed.
5. Add a [`../status.md`](../status.md) track only for a user-visible support
   state or sustained workstream. The coverage inventory should expose missing
   areas without turning the dated dashboard into a speculative backlog.

## Minimum evidence shape

A useful support result has four layers:

| Layer | Required question |
|-------|-------------------|
| Identity | Which board revision, accessory, boot path, kernel, DT/overlay, firmware, and userspace produced the result? |
| Detection | Did the expected driver bind, and what device/interface did userspace actually select? |
| Exercise | What exact command or interaction moved real data through the hardware, and what made it pass or fail? |
| Durability | Did errors appear in kernel/service logs, and did the behavior survive the relevant reconnect, reboot, rollback, or resume boundary? |

The system collector supplies identity and discovery data; it intentionally does
not manufacture a pass result. Project- or subsystem-specific tests must supply
the exercise and durability evidence.
