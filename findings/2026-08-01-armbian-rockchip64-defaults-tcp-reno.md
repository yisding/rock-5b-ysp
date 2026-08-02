# Armbian's rockchip64 kernel configs default TCP congestion control to reno

> Scope: Armbian `rockchip64` kernel configs (all three branches); the running
> `6.18.41-ysp-rockchip64` build inherits the setting
> Source: `armbian-build/config/kernel/linux-rockchip64-{current,edge,bleedingedge}.config`
> at `~/Code/rock-5b/armbian/armbian-build` (history at `88f02f40a`);
> `/boot/config-6.18.41-ysp-rockchip64`; live
> `sysctl net.ipv4.tcp_congestion_control`; upstream `net/ipv4/Kconfig`
> Date: 2026-08-01
> Trust: MEASURED, CONFIG-INSPECTED, SOURCE-INSPECTED, CONFIRMED

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

Reno is loss-based AIMD: the window grows one MSS per RTT and halves on any
loss signal, so recovery is linear and slow on a high bandwidth-delay-product
path. It also cannot distinguish congestion from **reordering**, which a Wi-Fi
plus userspace-WireGuard path produces routinely — see
[the RDP video-stall finding](2026-08-01-grd-rdp-video-stall-transport-congestion.md),
where the same socket showed `reordering:107`, `dsack_dups:215` and a collapsed
`cwnd:48 ssthresh:13` while `bytes_retrans` never moved.

## Reno is not *strictly* worse than CUBIC

An earlier draft of this finding said it was. That overstates the case, and the
reason is worth recording: **CUBIC contains Reno.** RFC 9438 defines a
Reno-friendly region in which CUBIC tracks what Reno's window would be
(`W_est`) and uses `max(W_cubic, W_est)`. It is active on this board:

```text
/sys/module/tcp_cubic/parameters/tcp_friendliness = 1
```

So in the low-BDP regime where Reno is competitive, CUBIC *is* Reno by
construction, and only diverges where Reno underperforms. CUBIC is therefore
≥ Reno in practice by containment, not by dominance. Reno remains preferable in
narrow cases: deliberately yielding to competing Reno flows, very shallow
buffers where CUBIC's convex probing induces more loss (not this board — it
runs `fq_codel`), and reproducible benchmarking, where Reno's AIMD is trivially
modelable.

## Regression risk of switching

**Reno → CUBIC is low risk.** Same algorithm class, so no new failure mode; it
only affects sockets that do not set `TCP_CONGESTION` themselves; and CUBIC is
what the board's own Ubuntu userspace, and essentially every peer it talks to,
already assumes. Three real caveats:

1. **It invalidates the measured baseline.** Every number in
   [the transport finding](2026-08-01-grd-rdp-video-stall-transport-congestion.md)
   was captured under reno. Changing congestion control and the encoder ceiling
   together makes neither attributable.
2. **Prefer a `sysctl.d` drop-in over a kernel-config change** on this board.
   Setting `CONFIG_DEFAULT_CUBIC` locally forks the config away from Armbian
   and adds a delta to carry through future regenerations — the exact mechanism
   that produced this bug. The upstream patch below is the right place for a
   config change; local use wants sysctl.
3. **HyStart is CUBIC-only** (`hystart=1`, `hystart_detect=3`). It exits
   slow-start on RTT/ACK-train signals, and on an RTT-noisy path it can exit
   early and undershoot on short flows. This is the one behaviour reno does not
   have.

**Reno → BBR is a different risk profile.** The shipped `tcp_bbr.ko` is
**BBRv1** — mainline 6.x has never carried v2 or v3, which live in Google's
out-of-tree branch. BBRv1 is documented to be unfair to loss-based flows
sharing a bottleneck, to sustain queues at high loss rates, and to dip
periodically as ProbeRTT drains cwnd. For a point-to-point RDP stream on an
otherwise idle LAN none of that bites, and its reordering tolerance is exactly
what the socket statistics call for — but it is not a safe blanket default for
the whole machine the way CUBIC is. BBR can be scoped to one path with
`ip route ... congctl bbr` instead, though Tailscale manages its own routes and
may clobber that.

## The fix

Locally, no rebuild is needed — both alternatives are already present:

```bash
# cubic: built in
sudo sysctl -w net.ipv4.tcp_congestion_control=cubic
# or BBR: module, present but unloaded
sudo modprobe tcp_bbr && sudo sysctl -w net.ipv4.tcp_congestion_control=bbr
```

Upstream, `fix/default-tcp-cubic@0fbef7eb2` against `armbian/build`
`origin/main@535528112` restores CUBIC across all nine distinct configs
(+11/−13). The patch and its verification procedure are in
[`findings/evidence/2026-08-01-armbian-default-tcp-cubic/`](evidence/2026-08-01-armbian-default-tcp-cubic/README.md).
**It has not been submitted.**

Two traps that only surfaced by running the kernel's own Kconfig parser over
the result, and that a reasoned-only patch would have got wrong:

- **Deleting `CONFIG_DEFAULT_RENO=y` is not enough.** Two of the configs also
  carry `# CONFIG_DEFAULT_CUBIC is not set`, which leaves reno as the only
  selectable entry; `olddefconfig` puts `CONFIG_DEFAULT_RENO=y` straight back.
  The line must be *replaced* with `CONFIG_DEFAULT_CUBIC=y`.
- **`linux-rockchip-rk3588-current.config` is a symlink** to the `-edge`
  config. `sed -i` over the glob replaces the symlink with a regular file,
  turning an 11-line diff into an 11,000-line one.

## It is drift, not a decision

Armbian originally shipped cubic. `git log -S` on the config file (searching for
`CONFIG_DEFAULT_RENO=y` rather than the bare symbol, which also matches the
`# ... is not set` form and misleadingly points at file creation) gives the
chain:

| when | commit | what happened |
| --- | --- | --- |
| 2019-11-19 | `150ac0c2a` "Remove K<4, change branches, new features (#1586)" | `linux-rockchip64-current.config` created with `CONFIG_DEFAULT_CUBIC=y`, `# CONFIG_DEFAULT_RENO is not set` |
| 2020-04-27 | `fea2ecb9f` "WIP: Merge kernel features from upstream (#1856)" | flipped to `CONFIG_DEFAULT_RENO=y` |
| 2023-01-01 | `48e45d0c9` "Mainline support for Rock 5B (#4606)" | `linux-rockchip-rk3588-*.config` created — **born with reno**, never had `CONFIG_DEFAULT_CUBIC=y` |
| 2025-01-04 | `fb979d96d` "`rockchip64`/`current`: rewrite-kernel-config, no changes" | dropped the explicit `CONFIG_TCP_CONG_{BIC,CUBIC,WESTWOOD,HTCP}` lines; `CONFIG_DEFAULT_RENO=y` survived |

The flip commit is a 13-file, +12237/−6780 bulk config regeneration whose
subject mentions no networking change at all. Only **2 of its 13** files
flipped — `linux-rockchip64-current` and `linux-sunxi64-current` — and
`CONFIG_TCP_CONG_CUBIC` was not touched anywhere in it. A deliberate policy
would not land in two files out of thirteen.

The mechanism is Kconfig's fallback. In `net/ipv4/Kconfig` the choice reads:

```text
config DEFAULT_CUBIC   bool "Cubic" if TCP_CONG_CUBIC=y
config DEFAULT_RENO    bool "Reno"
```

`DEFAULT_RENO` is the only unconditional entry, so any regeneration where cubic
is not `=y` at the moment the choice is resolved collapses to reno — and once
written, `olddefconfig` preserves that answer forever. The 2025 "no changes"
rewrite then removed the explicit `CONFIG_TCP_CONG_CUBIC=y` line; cubic still
comes back as `default y` from Kconfig at build time, which is why the built
kernel has cubic available while the stale `CONFIG_DEFAULT_RENO=y` still pins
the choice.

Nothing in Armbian's tracker or forum argues for reno. The only TCP-congestion
activity is [armbian/build#609](https://github.com/armbian/build/issues/609)
(2017) asking to *enable BBR*, which is why BBR ships as `=m`; the
[congestion-control forum thread](https://forum.armbian.com/topic/14113-congestion-control/)
shows a user whose system defaulted to **cubic** and developers replying only
about enabling BBR. Nobody discusses the reno default, in either direction.

Today the fleet is incoherent: of 112 kernel configs, **10** set
`CONFIG_DEFAULT_RENO=y` (all meson64, all rockchip64, all rockchip-rk3588,
plus `virtual-current`), **9** set `CONFIG_DEFAULT_CUBIC=y`, and the remaining
93 set neither and inherit upstream's cubic.

## Boundary

The archaeology above establishes *when* and *how* reno was introduced and that
no rationale was ever recorded. It does not prove intent — no Armbian developer
was asked, and PR #1856's discussion was not retrieved, only its commit.

**No A/B measurement of reno vs. cubic vs. BBR has been run on this board.**
The case for changing rests on the algorithms' documented behaviour plus the
socket statistics in the linked finding, not on a controlled comparison. The
claim that CUBIC would improve the observed RDP stalls is therefore INFERRED;
what is measured is only that the path is window- and queue-limited without
loss, which is the regime where reno is known to do badly.

The upstream patch is verified at the level of Kconfig resolution only: nine
configs in, nine `CONFIG_DEFAULT_CUBIC=y` out. No kernel was built from them
and none was booted, so nothing here establishes that the resulting kernels are
otherwise unchanged.

`CONFIG_DEFAULT_CUBIC` was checked against a 6.18 arm64 Kconfig tree. Four of
the nine configs target other families and two (`linux-virtual-current`,
`linux-meson64-oldlts`) may resolve against a different kernel version upstream;
the TCP choice is arch- and version-stable across the range in question, but
that was assumed rather than tested per-family.
