# Armbian's rockchip64 kernel configs default TCP congestion control to reno

> Scope: Armbian `rockchip64` kernel configs (all three branches); the running
> `6.18.41-ysp-rockchip64` build inherits the setting
> Source: `armbian-build/config/kernel/linux-rockchip64-{current,edge,bleedingedge}.config`
> at `~/Code/rock-5b/armbian/armbian-build`; `/boot/config-6.18.41-ysp-rockchip64`;
> live `sysctl net.ipv4.tcp_congestion_control`
> Date: 2026-08-01
> Trust: MEASURED, CONFIG-INSPECTED, CONFIRMED

## Result

The board runs TCP **reno**, and it is not a sysctl — it is compiled in as the
kernel's default choice.

```text
net.ipv4.tcp_congestion_control = reno
net.ipv4.tcp_available_congestion_control = reno cubic
```

No file under `/etc/sysctl.conf`, `/etc/sysctl.d/`, or `/usr/lib/sysctl.d/`
mentions `congestion`. The setting comes from the kernel build config:

```text
CONFIG_TCP_CONG_CUBIC=y
CONFIG_TCP_CONG_BBR=m
# CONFIG_DEFAULT_CUBIC is not set
CONFIG_DEFAULT_RENO=y
CONFIG_DEFAULT_TCP_CONG="reno"
```

All three Armbian rockchip64 configs carry `CONFIG_DEFAULT_RENO=y`, so this is
an Armbian-wide default rather than a `ysp` local change:

| config | `CONFIG_DEFAULT_RENO` | `CONFIG_TCP_CONG_BBR` |
| --- | --- | --- |
| `linux-rockchip64-current` | `y` | `m` |
| `linux-rockchip64-edge` | `y` | `m` |
| `linux-rockchip64-bleedingedge` | `y` | `m` |

Upstream `net/ipv4/Kconfig` defaults this choice to `DEFAULT_CUBIC`, so reno was
selected, not inherited. Both alternatives are already present on the board:
cubic is **built in** (`CONFIG_TCP_CONG_CUBIC=y`, listed in `modules.builtin`),
and BBR ships as a module at
`/lib/modules/6.18.41-ysp-rockchip64/kernel/net/ipv4/tcp_bbr.ko` — unloaded.

Switching needs no rebuild:

```bash
# cubic — built in, no module needed
sudo sysctl -w net.ipv4.tcp_congestion_control=cubic
# or BBR
sudo modprobe tcp_bbr && sudo sysctl -w net.ipv4.tcp_congestion_control=bbr
```

## Why it matters

Reno is the weakest of the three on exactly the workloads this board runs.
It is loss-based with additive-increase/multiplicative-decrease: the window
grows one MSS per RTT and halves on any loss signal, so recovery is linear and
slow on a high bandwidth-delay-product path. It also cannot distinguish
congestion from **reordering**, which a Wi-Fi plus userspace-WireGuard path
produces routinely — see
[the RDP video-stall finding](2026-08-01-grd-rdp-video-stall-transport-congestion.md),
where the same socket showed `reordering:107` and `dsack_dups:215` with a
collapsed `cwnd:48 ssthresh:13`.

## Boundary

This records where the default comes from and that alternatives are available.
It does **not** establish why Armbian selected reno, and no A/B measurement of
reno vs. cubic vs. BBR throughput or latency has been run on this board yet —
the case for changing it rests on the algorithms' documented behaviour plus the
socket statistics in the linked finding, not on a controlled comparison here.
