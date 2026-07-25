# The board wedges by thrash livelock, not by OOM — zram saturation plus a page-cache flood, with no daemon to break it

> Scope: ROCK 5B board operations; Armbian kernel builds (`kernel-drivers/scripts/build-kernel.sh`)
> Source: live board `6.18.38-ysp-rockchip64`; `/var/log/sysstat/sa2[1-5]`, `journalctl -b -1`, `/proc/*/mountinfo`, armbian-build `lib/functions/host/tmpfs-utils.sh`
> Date: 2026-07-25
> Trust: MEASURED (sar/journal/live process and mount inspection) / INFERRED (attribution of the page-cache flood) / FIX-RUNTIME-VERIFIED (earlyoom running with the intended thresholds)

## Result

The board did not run out of memory. It **livelocked while reclaim was still
succeeding**, which is why nothing killed anything and why it had to be
power-cycled.

The kernel OOM killer never fired — **zero OOM kills exist in the journal across
every recorded boot**. It could not fire, because reclaim kept technically
working: with swap 100% full the only reclaimable memory left was page cache, so
the kernel evicted all of it and kept scanning. At the last recorded sample
(`01:59:05`) the board was scanning **1,800,665 pages/s**, taking 2,140 major
faults/s, reading **479,176 blocks/s from disk and writing 2.42** — pure refault
traffic, zero forward progress. Load average 114.93. Page cache had collapsed
from 5.4 GB to 585 MB and buffers from 837 MB to 11 MB.

The mechanism has two stages, a day apart:

**Stage 1 — swap gets consumed by an eviction, not by a leak (Jul 24, 18:50–19:40).**
Page cache exploded from 2.83 GB to 11.22 GB in ten minutes *while swap was still
at zero*. Anonymous memory did not grow (`kbanonpg` stayed between 2.0 and
3.1 GB the whole time). The kernel made room for the cache by pushing cold
anonymous pages into zram: swap went 0 → 1.03 GB → 3.60 GB → 7.43 GB → 98.5% in
forty minutes, at load 1.5–4.1. It then **stayed pinned at 87–98% all night**,
including hours at load 0.13, because nothing ever touched those pages again.
This is benign in isolation and looks alarming in monitoring — but it left the
board with **zero swap headroom**.

**Stage 2 — a build arrives to a board with no headroom (Jul 25, 00:25–02:00).**
An Armbian kernel build started at 00:25. It needed memory; there was no swap
left to evict anon into, so every byte of pressure landed on page cache — which
the build itself constantly re-reads. Cache eviction and refault became the only
activity. sar **dropped its 01:30, 01:40 and 01:50 samples entirely** (the
collector could not get scheduled), recorded one last sample at 01:59, and
stopped. The journal continued only for already-resident daemons and went silent
after `03:11:09`. Recovery required a power cycle at `07:00:30`.

Swap saturation is **new behavior**, not the steady state: daily peaks were 36%
(Jul 21), 15.5% (Jul 22), 14.3% (Jul 23), then 98.2% on Jul 24 and 100% by
01:00 Jul 25.

### Two aggravating facts found while investigating

**Armbian mounts build directories as tmpfs at 99% of RAM.**
`prepare_tmpfs_for()` in `lib/functions/host/tmpfs-utils.sh` mounts **both**
WORKDIR and LOGDIR with `-o size=99%`, on every build, opt-out only via
`USE_TMPFS=no`, with no size knob. Confirmed live in a running build's mount
namespace: two tmpfs mounts of `size=16021764k` each against a `MemTotal` of
`16183596 kB`. The in-tree comment is explicit — *"size=50% is the Linux
default, but we need more."* **An OOM daemon cannot recover from a tmpfs fill**:
tmpfs pages can only be pushed to swap, never dropped like page cache, and they
outlive the process that wrote them, so killing the writer frees nothing.

**A transient Claude Code worker reached 8.8 GB RSS / 18.3 GB virtual in under
four minutes**, observed live at 07:40 on Jul 25 while investigating (`claude
bg-spare`, comm `2.1.220`, parented to a `claude daemon run --origin transient`
process). It exited on its own; memory recovered. Interactive Claude sessions
sit at 270–500 MB, so largest-RSS victim selection distinguishes the two
cleanly. The same signature — commit charge jumping 4.6 → 11.1 GB with resident
anon flat — appears at 19:00 on Jul 24.

## Boundary

- **The Jul 24 cache flood is not attributed.** sar does not break out `Shmem`
  from `kbcached`, so tmpfs pages and file-backed pages are indistinguishable in
  the historical data. Evidence leans file-backed: at 19:40–19:50 cache regrew
  1.8 → 8.8 GB while swap stayed flat at ~7.95 GB, and tmpfs cannot regrow
  without swapping back in (which would have lowered swap). But the 19:30
  collapse (8.8 → 1.8 GB) is equally consistent with a build-end tmpfs unmount.
  Not resolved.
- **The wedge was not observed live.** Everything above is reconstructed from
  sar and the journal. The true moment of death is bounded, not known: last sar
  sample 01:59:05, last journal entry 03:11:09.
- **No crash evidence exists.** `/sys/fs/pstore` is root-only and empty, and
  `/var/lib/systemd/pstore` is empty; this was a livelock, not a panic, so there
  would be nothing to capture regardless.
- **Why the Claude worker grew is unknown.** Only its size, lifetime, parentage
  and exit were observed. Whether it is a leak, a legitimate large operation, or
  a pathological retry loop is not established, and it was not reproduced.
- **zram is not the villain.** `mm_stat` showed 5.55 GB of data held in 1.32 GB
  of physical RAM — about 4.6:1 with `lzo-rle`. Compression is working well; the
  problem is that a full zram offers no further reclaim, not that it is
  expensive.
- **earlyoom's thresholds are verified as configured, not as fired.** No kill
  has occurred. The replay below is arithmetic against recorded sar rows, not an
  observed rescue.

## Evidence

- **Identity:** ROCK 5B, 16 GB, `6.18.38-ysp-rockchip64`, Armbian 26.5.1
  resolute. Swap is `/dev/zram0` only, `disksize=8286003200` (7.72 GiB),
  `lzo-rle`. `zram1`/`zram2` exist but are `disksize=0`, unconfigured and
  unmounted — **there is no zram-backed filesystem**; `armbian-ramlog` is
  `ENABLED=false`. `/tmp` is a plain fstab tmpfs, default-capped at 50% of RAM.
- **Boot boundary:** boot `d9e8a173` 2026-07-24 17:28:59 → last entry
  2026-07-25 03:11:09; boot `4ec59366` begins 07:00:30.
- **Exercise:** `sar -f /var/log/sysstat/sa2{4,5} -q -r ALL -S -B -b`,
  `journalctl -b -1`, `/proc/<pid>/mountinfo` of a live build process.
- **Pass/fail signal:** absence of `oom-kill`/`Killed process` in every boot,
  together with `pgscank/s` ≈ 1.8M and `wtps` ≈ 0, is the livelock signature.

Key sar rows, Jul 25:

| Time | ldavg-1 | avail | cached | buffers | swap used | pgscank/s | wtps |
|------|---------|-------|--------|---------|-----------|-----------|------|
| 01:00 | 17.20 | 3.98 G | 3.58 G | 22 M | 100% | 5,917 | 59.5 |
| 01:20 | 23.11 | 2.51 G | 2.29 G | 25 M | 100% | 5,731 | 137.9 |
| 01:59 | **114.93** | **0.82 G** | **0.59 G** | **11 M** | 100% | **1,800,665** | **2.42** |

## Fix

1. **`scripts/rock5b-oom-protection-apply.sh`** installs and configures earlyoom
   as the backstop. Thresholds `-m 12,6 -s 10,5`: SIGTERM under 12% available
   memory **and** 10% free swap, SIGKILL at 6%/5%. earlyoom ANDs the two
   conditions, which is precisely why it fits a board that idles at 95% swap —
   a swap-only trigger would fire during healthy operation.

   Replayed against the recorded rows (earlyoom measures against *user mem
   total*, 14,666 MiB, not `MemTotal`):

   | Sample | avail | swap used | verdict |
   |--------|-------|-----------|---------|
   | Jul 24 20:00–23:00 | 63% | 95% | no fire — correct, board healthy |
   | Jul 25 00:50 | 25% | 99% | no fire |
   | Jul 25 01:20 | 16% | 100% | no fire (just above gate) |
   | Jul 25 01:59 | **5.4%** | 100% | **SIGKILL** — livelock averted |

   No `--prefer` is configured, deliberately: earlyoom multiplies a preferred
   process's badness by 10, so preferring compilers would let a ~1 GB `cc1`
   outrank a multi-gigabyte leak, killing something `make` respawns in seconds
   while the real hog survives. Default largest-RSS selection picks the 8.8 GB
   worker over both the compilers and the 270–500 MB interactive sessions.

   Runtime-verified: `earlyoom v1.9.0` running with `-m 12,6 -s 10,5 -r 900`,
   and the journal confirms the avoid-regex parsed — the one real risk, since
   systemd word-splits `$EARLYOOM_ARGS` without shell quote processing, so any
   regex containing a space or surrounding quotes silently fails to match.

2. **`USE_TMPFS=no` is now the default in `build-kernel.sh`** (both the debug and
   production `compile.sh` call sites), passed as a command-line argument rather
   than an environment variable for the same reason `USE_CCACHE` is — Armbian
   relaunches through Docker or sudo, and the Docker path was previously
   observed dropping bare env vars. Override with `ARMBIAN_USE_TMPFS=yes`.

**systemd-oomd was evaluated and rejected** for this board. Its swap policy
fires at ~90% swap usage, which here is a normal healthy state (Jul 24
20:00–23:00: swap 95%, load 0.13, 9.9 GB available), so it would kill during
idle. It can be configured around — PSI-driven via `ManagedOOMMemoryPressure`
with the swap policy disabled — and PSI is the better signal in principle, since
`MemAvailable` counts reclaimable cache and can read healthy during a livelock.
It was rejected on kill granularity: systemd-oomd kills whole cgroups, and each
tmux pane is its own scope, so a kill takes an entire interactive session rather
than the single runaway worker.

## Why it matters / follow-up

The board had run this way for weeks; what changed was arriving at a build with
swap already saturated from the previous evening. Any future combination of
"something floods page cache" plus "a build starts" reproduces it.

Open items:

- `/tmp` and `/dev/shm` remain at the 50%-of-RAM default (7.7 GB each). Bounding
  `/tmp` to ~2 GB in fstab closes the other unreclaimable pool; not yet done.
- The 8.8 GB `claude bg-spare` worker is unexplained and unreproduced. earlyoom
  now bounds the damage but does not address the cause.
- KASAN builds currently run `make -j12` on 8 cores with `USE_CCACHE=no`. Worth
  dropping to `-j6`/`-j8`, since KASAN substantially inflates per-TU compile
  memory.
