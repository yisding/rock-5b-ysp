# ROCK 5B failed boot completed every forward-port MPP probe

> Scope: ROCK 5B dev board, running debug (lockdep-enabled) `6.18.38-current-rockchip64` while hunting Rockchip video-codec (rkvdec2/rkvenc/mpp) driver bugs
> Source: on-board `journalctl` of boot `-1` (failed) vs boot `0` (healthy), captured 2026-07-22; exact installed-kernel source tree `/home/yi/Code/kernel/linux-6.18-rkvenc-av1-fwport` at `fa8c80ceccc5e28d93264962c56073375657919f`
> Date: 2026-07-22
> Trust: MEASURED for the boot outcomes and probe sequence; SOURCE-INSPECTED for the driver attribution; OPEN for the later systemd stall

## Result

The forward-port video driver did **not** cause this failed boot. Every
`mpp_service`, rkvdec2, rkvenc2, and AV1 probe emitted its matching completion by
monotonic 13.341 s, before systemd PID 1 began. The earlier finding that called
this a device-probe soft-hang was wrong.

The three later `sync_state() pending due to fdba*.video-codec` messages are not
forward-port rkvdec/rkvenc devices. They are mainline Hantro `vepu121_1/2/3`
JPEG encoder instances. Hantro deliberately declines the secondary instances
because it lacks multi-core support, and the exact same messages occur on the
healthy next boot. They are routine timing markers, not evidence that a probe
was still running.

The failed boot instead stopped making progress in the systemd transaction. It
finished udev settle at 17.826 s but never reached `sysinit.target`,
`basic.target`, or NetworkManager. The healthy boot reaches those at
18.578/18.729/19.742 s. The precise blocking systemd job is investigated
separately; this slice only closes the forward-port-driver hypothesis.

## Evidence and reproduction

- **Exact forward-port source:** branch `bsp-high-port-20260722`, commit
  `fa8c80ceccc5e28d93264962c56073375657919f`.
- **All MPP starts returned:** failed boot `-1` logs `mpp_service` probe
  start/success, rkvenc CCU start/finish, rkvdec CCU start/finish, AV1
  start/finish, both rkvdec cores start/finish, and both rkvenc cores
  start/finish. The last is `fdbe0000.rkvenc-core: probing finish` at 13.341 s.
  ```
  journalctl -b -1 -o short-monotonic --no-pager |
    grep -E 'mpp_service|mpp_rkv(dec2|enc2)|mpp_av1dec'
  ```
- **Probe is synchronous:** `mpp_service_probe()` registers each subdriver via
  `platform_driver_register()` before printing `probe success`. Each common
  device probe synchronously resumes runtime PM, clocks the block, reads its
  hardware ID, clocks it off, and calls `pm_runtime_put_sync()`. Therefore the
  completion lines close those paths; there is no unmatched forward-port probe.
- **Indefinite wait is not a boot path:** the unbounded
  `wait_event_interruptible(task->wait, TASK_STATE_DONE)` is in the userspace
  task-result ioctl path, after a session submits work. `mpp_dev_shutdown()` is
  bounded by a 200 ms `readx_poll_timeout()`.
- **`fdba*` attribution:** `rk3588-base.dtsi` names the three nodes
  `vepu121_1`, `vepu121_2`, and `vepu121_3`, compatible
  `rockchip,rk3588-vepu121`, under `RK3588_PD_VDPU`. `hantro_drv.c` prints
  `missing multi-core support, ignoring this instance` and returns `-ENODEV`
  for non-primary instances. Both failed and healthy boots log that sequence
  followed by the same three power-domain `sync_state()` messages.
- **Systemd boundary:** failed boot reaches `local-fs.target` and
  `network-pre.target`, finishes `systemd-udev-settle`, but never reaches
  `sysinit.target` or `basic.target`. The healthy boot reaches both immediately
  after udev settle, then starts NetworkManager. This places the stalled
  transaction after driver probe and before basic userspace startup.

## Boundary

This proves that the forward-port MPP probe path returned; it does not yet prove
why the systemd transaction stopped. The chronic
`systemd-networkd-wait-online` timeout also occurs on the healthy boot and does
not prevent that boot from reaching the display manager. The recurring PCIe PMU
lockdep warning is likewise followed by successful enumeration on both boots.

## Why it matters / follow-up

Do not bisect or blacklist the forward-port codecs for this incident. Compare
the failed and healthy systemd job streams and find the start without a matching
completion that holds `sysinit.target`.

Tracked as status.md watchlist [`W20`](../status.md#watch-w20).
