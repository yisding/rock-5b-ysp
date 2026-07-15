# ROCK 5B zero-DTB race: controlled proof, Noble `cp`, and KSpace amplification

> Scope: ROCK 5B/RK3588 vendor U-Boot FIT packaging and Armbian issue
> [#8227](https://github.com/armbian/build/issues/8227)
> Source: Radxa U-Boot `39cd993e5d`, Armbian build
> `654bb1d7ffdda154a81d6d93729f4e8163702ce3`, Ubuntu Jammy/Noble
> coreutils source, and Linux 6.6 clone paths
> Date: 2026-07-13; expanded 2026-07-14
> Trust: MEASURED / SOURCE-INSPECTED / CONFIG-INSPECTED / INFERRED where noted

## Result

The Makefile dependency bug is sufficient to explain the 0-byte DTB. The
generated `u-boot.its` embeds `./u-boot.dtb`, but the original `u-boot.itb` rule
did not depend on `u-boot.dtb`. Armbian invokes both as sibling goals under
parallel Make. A controlled three-second delay before `COPY u-boot.dtb` made
`mkimage` deterministically package an empty payload; adding `u-boot.dtb` to
the FIT prerequisite list fixed the same test.

Jammy is not known to be immune. There is no evidence of a GNU Make semantic
difference: the current Armbian Jammy and Noble images both contain GNU Make
4.3. There is, however, a hard `cp` implementation difference:

- Jammy coreutils 8.32 defaults to `REFLINK_NEVER` and reaches buffered
  `read`/`write` directly.
- Noble coreutils 9.4 defaults to `REFLINK_AUTO`. After creating or truncating
  the named destination it tries `FICLONE`, then `copy_file_range`, then
  buffered `read`/`write` if the fast paths are unavailable.

That difference can extend the interval in which the named `u-boot.dtb` is
zero, but the unloaded local measurements were sub-millisecond. It is not a
complete explanation for a roughly 98% KSpace failure rate. The larger
amplifiers are:

1. Make can start `u-boot.itb` before the `u-boot.dtb` recipe starts at all.
2. KSpace exposed 64 CPUs to Docker and Armbian's formula implies `make -j96`
   for each job.
3. The public KSpace inventory listed 24 co-located runners.
4. The U-Boot worktree is a persistent host bind mount, so host filesystem
   contention, dirty-page writeback, inode locks, and descheduling can all
   stretch a normally tiny interval.

The host filesystem type and mount options were not logged, so a
filesystem-specific KSpace explanation remains a hypothesis. Docker overlay
storage is not the direct path for this file: on Linux Armbian bind-mounts
`cache/sources/u-boot-worktree` from the host.

## Controlled reproduction of the missing edge

The vendor FIT rule invokes `mkimage` on `u-boot.its`, which contains:

```dts
data = /incbin/("./u-boot.dtb");
```

The original rule waited for `dts/dt.dtb`, not the copied file named by the
`/incbin/`. When `u-boot.dtb` and `u-boot.itb` were requested in parallel, a
temporary three-second delay immediately before the copy produced:

- `MKIMAGE u-boot.itb` before `COPY u-boot.dtb` in the pre-fix log;
- a FIT `fdt` image with `Data Size: 0 Bytes`;
- a final on-disk `u-boot.dtb` of 12,752 bytes.

Changing the rule to depend on `u-boot.dtb` ordered `COPY` before `MKIMAGE`
and produced a 12,752-byte FIT payload under the same induced delay. The
[recorded patch](evidence/2026-07-13-u-boot-fit-dtb-race/Makefile-controlled-delay-and-fix.patch),
[pre-fix log](evidence/2026-07-13-u-boot-fit-dtb-race/controlled-delay-prepatch.log),
and
[post-fix log](evidence/2026-07-13-u-boot-fit-dtb-race/controlled-delay-postpatch.log)
preserve the test.

## What copy-on-write means here

It does **not** mean that GNU `cp` copies into an anonymous temporary file and
atomically renames it over `u-boot.dtb`. Noble's sequence is:

1. Open the source.
2. Open an existing destination with `O_TRUNC`, or create a new named
   destination with `O_CREAT|O_EXCL`. At this point the pathname exists with
   size zero.
3. Issue whole-file `FICLONE`.
4. If cloning is unsupported, try `copy_file_range`.
5. If that is unsupported before any bytes move, fall back to
   `read`/`write`.

`FICLONE` shares the source extents instead of physically copying the DTB
bytes. A successful clone can therefore make the destination appear complete
in one metadata operation, but the named zero-length destination exists
before the ioctl begins. Depending on filesystem locking, another reader can
observe zero, block until the clone finishes, or see the completed file. The
API's atomicity with respect to concurrent writes is not an atomic pathname
replacement guarantee.

The likely long-tail case is not “12.7 KiB is slowly copied but hidden.” Linux
6.6's generic reflink preparation waits for direct I/O and calls
`filemap_write_and_wait_range` on both mappings before remapping. Btrfs goes
further: it flushes the source and waits for ordered ranges before cloning.
If the just-built DTB is dirty, storage is congested, or the process is
descheduled while holding or waiting for locks, `FICLONE` can remain inside
the kernel while the destination is still zero. That can be much longer than
the unloaded syscall timings.

For a tiny DTB there are normally only one or a few extents, so “almost all
extents cloned while the size remains zero” is less plausible than “waiting
before the first extent.” There is a real partial-clone corner case, though.
Plain `FICLONE` passes a zero length meaning “to EOF,” so Linux's exact-length
check only applies to an explicitly sized `FICLONERANGE`. XFS remaps one
extent at a time, updates destination size per extent, and returns a positive
remapped count if any progress occurred even when a later extent failed. The
plain ioctl treats that nonnegative return as success, so `cp` can accept a
partial XFS clone in that rare path. Such a file should normally be nonzero,
so this is a possible silent-corruption mode rather than a good explanation
for the observed empty payload. Btrfs instead returns the requested length
only after its clone path succeeds.

`copy_file_range` can also return short positive counts. Coreutils 9.4 loops
after a short copy, but it only falls back to ordinary I/O if no bytes have
moved. An error after positive progress is fatal, not a retry. A compliant
modern local filesystem therefore does not normally “copy almost everything,
fail, reset to zero, and retry.” A single call may still block for filesystem
work before it publishes data.

## Partial data is not safer and there is no useful retry

Jammy's `read`/`write` path can make the destination size grow progressively,
whereas a one-call clone or offloaded copy may look more all-or-nothing. That
does not make the race safe on Jammy:

- The traced 12,752-byte DTB fit in one 128 KiB buffer and Jammy issued one
  12,752-byte `write`. For a file this small, the old path does not provide a
  dependable sequence of partially readable sizes either.
- `mkimage` accepted a zero-length `/incbin/` and returned success in the
  controlled reproduction.
- The FIT hash was the correct hash of the bytes actually embedded, including
  the empty payload. It did not validate that those bytes formed the complete
  expected DTB.
- There is no Make retry because both `cp` and `mkimage` return success.
- A nonzero partial file would most likely be embedded and hashed as a
  truncated payload, producing a less obvious corrupt FIT instead of
  triggering a retry.

The right fix is the dependency edge, not relying on partial visibility or
changing the copy engine.

## Exact Jammy and Noble comparison

The current Armbian images captured on 2026-07-14 were:

| Image | Immutable image/config ID | Make | coreutils | GCC | glibc |
|---|---|---:|---:|---:|---:|
| Jammy | `sha256:6ea94ee030d7fa69298baecaa155c73258bee13a91847b635d458167f4969231` | 4.3 | `8.32-4.1ubuntu1.3` | 11.4.0 | 2.35 |
| Noble | `sha256:09239184227e3576e8af92af6f9b9a2170957f9ab5f4b1e4e06710bf75aa3027` | 4.3 | `9.4-3ubuntu6.2` | 13.3.0 | 2.39 |

The default reflink change landed in coreutils 9.0; the
[release announcement](https://lists.gnu.org/archive/html/coreutils/2021-09/msg00113.html)
explicitly describes the new automatic CoW/copy-offload behavior. The exact
Ubuntu source packages are
[Jammy 8.32-4.1ubuntu1.3](https://launchpad.net/ubuntu/+source/coreutils/8.32-4.1ubuntu1.3)
and
[Noble 9.4-3ubuntu6.2](https://launchpad.net/ubuntu/+source/coreutils/9.4-3ubuntu6.2).
Ubuntu's Noble patches do not change the clone/copy engine.

A disposable-container `strace` of an existing 12,752-byte destination found:

| Case | Calls after `O_TRUNC` | Approx. interval to data-producing call |
|---|---|---:|
| Jammy, same container filesystem | `read`, `write` | 0.39 ms |
| Noble, same container filesystem | `FICLONE` → `EOPNOTSUPP`, `copy_file_range` succeeds | 0.39 ms |
| Noble, overlay source → tmpfs destination | `FICLONE` → `EXDEV`, `copy_file_range` → `EXDEV`, `read`, `write` | 1.05 ms |
| Noble, same cross-mount copy with `--reflink=never` | `read`, `write` | 0.55 ms |

These are single traced runs, not benchmarks; `strace` perturbs timing. They
show that the extra fallbacks can add about half a millisecond in an unloaded
forced-failure case, not that KSpace's tail was half a millisecond. The
[source and trace appendix](evidence/2026-07-13-u-boot-fit-dtb-race/coreutils-copy-path-comparison.md)
records the exact source anchors, package hashes, and relevant syscall lines.

The failing 2026 job used a different Noble image ID,
`sha256:7283efcbc74982aba2b45544c978d554debfb2e474193cc5181578a9584dc433`.
The workflow set `DOCKER_SKIP_UPDATE=yes` and used the locally cached mutable
`armbian-ubuntu-noble-latest` tag. That old image is no longer the object
served by the tag, so its exact package inventory cannot be reconstructed
from the current image. The GCC 13.3 log confirms the expected Noble
toolchain, but the current image comparison must not be mistaken for an exact
inspection of the failing container.

The issue also contains a report that Jammy reproduced the problem on an
Apple M2 Max, although no confirming artifact was posted. That is consistent
with Jammy changing probability rather than fixing the graph.

## Exact KSpace build environment

The concrete zero-DTB job was
[armbian/os run 28326623973, job 83921496847](https://github.com/armbian/os/actions/runs/28326623973/job/83921496847):

| Item | Captured value |
|---|---|
| Runner | self-hosted `kspace-36` on machine `kspace` |
| Public inventory | 24 runners, 128 vCPUs, 270,129 MB RAM |
| Docker server | 29.1.3, kernel `6.6.63-current-x86` |
| Docker-visible resources | 64 CPUs, 251.6 GiB RAM |
| Host OS | Armbian 26.5.1 Noble |
| Armbian build commit | `654bb1d7ffdda154a81d6d93729f4e8163702ce3` |
| U-Boot commit | `39cd993e5d6296635438e84f4576b3a9bf76f86e` |
| U-Boot worktree | `/armbian/cache/sources/u-boot-worktree/u-boot-rockchip64/next-dev-v2024.10` |
| Sibling Make goals | `spl/u-boot-spl.bin u-boot.dtb u-boot.itb` |
| Compiler | AArch64 GCC 13.3.0 |
| Free space | 930 GiB reported for both `/armbian/cache` and `/armbian/output` |
| Proxies/caches | no apt, OCI, Redis/ccache, or Git proxy advertised |

At the pinned Armbian commit, `CPUS` is the count from `/proc/cpuinfo` and
`CTHREADS` defaults to 1.5 times that value. The Docker launch code supplies
no `--cpus` or `--cpuset-cpus` limit. Combining that source with Docker's
64-CPU report implies `-j96` for this job. If all 24 runner services were busy,
their requested Make slots could sum to 2,304. That last number is a capacity
calculation, not evidence that all runners were concurrently compiling.

Issue comments report approximately 98% failures on KSpace, success on
`rack-ryzen-05` and `werner-02`, and 100% success after U-Boot jobs moved to
single-use GitHub-hosted runners. This strongly implicates runner load or
storage behavior as the probability amplifier, while the missing dependency
remains the deterministic correctness bug.

### Filesystem boundary

The pinned
[mountpoint configuration](https://github.com/armbian/build/blob/654bb1d7ffdda154a81d6d93729f4e8163702ce3/lib/functions/host/mountpoints.sh)
sets `cache/sources/u-boot-worktree` to a Linux host bind mount. The source
contains a separate Darwin policy: use a named volume because host bind
mounts are too slow. Thus:

- the KSpace DTB is not being copied in the container's normal overlay layer;
- the actual host backing filesystem and its mount options matter;
- neither the workflow nor the log records whether that filesystem is ext4,
  XFS, Btrfs, networked, or layered again below Docker.

The runner cleanup is not fully ephemeral: it only purges source caches above
a disk-usage threshold, while each U-Boot build does clean its selected Git
worktree. Persistent cache placement and competing jobs therefore remain
relevant.

The next known-bad run should record:

```bash
findmnt -T "$GITHUB_WORKSPACE/cache/sources/u-boot-worktree" -o SOURCE,FSTYPE,OPTIONS
stat -f -c 'host fs=%T block=%S' "$GITHUB_WORKSPACE/cache/sources/u-boot-worktree"
docker info --format 'driver={{.Driver}} driver_status={{json .DriverStatus}}'
docker image inspect ghcr.io/armbian/docker-armbian-build:armbian-ubuntu-noble-latest --format 'id={{.Id}} digests={{json .RepoDigests}}'
```

Inside the build container, record `findmnt` and `stat -f` for
`/armbian/cache/sources/u-boot-worktree` plus `uname -a`. For timing rather
than inference, trace `openat(O_TRUNC)`, `FICLONE`, `copy_file_range`, and the
concurrent `mkimage` open/read, or use eBPF scheduler and syscall latency
probes on the host.

## Docker Desktop, Colima, and Mac evidence

There is hard precedent for copy behavior changing in a Mac-hosted Linux VM,
but it does not directly identify the KSpace bug:

- [Docker for Mac #5570](https://github.com/docker/for-mac/issues/5570)
  documents Docker Desktop 3.3.x creating empty files. A trace showed a
  918-byte `copy_file_range` returning zero in the broken version where the
  prior release copied 918 bytes.
- The linked
  [Docker for Linux #1015](https://github.com/docker/for-linux/issues/1015)
  isolated an overlayfs/kernel regression. It affected Linux 5.6 through
  5.10.83 and was fixed in stable 5.10.84; Docker Desktop 4.6.0 users reported
  the fix. That history proves virtual/overlay filesystems can violate copy
  assumptions, but KSpace ran Linux 6.6 and its U-Boot worktree was a bind
  mount, so this particular bug does not match.
- [Colima #901](https://github.com/abiosoft/colima/issues/901) reports a
  profile clone using `cp` at roughly 60 MB/s versus about 300 MB/s with
  `rsync` on an M2 Pro. It is an open user report and does not establish which
  `cp` implementation or syscall caused the gap.
- [Colima #146](https://github.com/abiosoft/colima/issues/146) measured a
  70,000-file test at 21.65 seconds on a host-mounted tree versus 5.36 seconds
  after copying it into the VM-local filesystem. This supports the general
  shared-mount penalty.
- [Docker for Mac #3677](https://github.com/docker/for-mac/issues/3677)
  measured a roughly 100 MB write in 0.37 seconds on the container-local
  filesystem and 31.82 seconds on a bind mount. It is older osxfs-era
  evidence, not a current Noble `cp` benchmark.
- [Docker for Mac #6667](https://github.com/docker/for-mac/issues/6667)
  records backend- and release-specific regressions: one Intel report saw
  about 0.8 seconds per request with VirtioFS versus 0.07 with gRPC FUSE, and
  another saw Docker 4.16 C++ builds four times slower than 4.14. Other users
  reported the opposite ordering on Apple Silicon.

The defensible conclusion is that Mac shared-filesystem backends can create
large, version-specific latency tails and have had `copy_file_range`
correctness bugs. There is no hard evidence here of a general coreutils 9.4
`cp` performance regression on current Docker Desktop or Colima, and those
Mac reports should not be used as proof of KSpace's filesystem type. Armbian's
own Darwin named-volume policy is the most directly applicable design signal.

## Minimal Armbian PR to test the fix

[Armbian PR #9946](https://github.com/armbian/build/pull/9946) already merged
the guarded `uboot-makefile-fix-itb-deps` extension, but only EasePi-A2 enables
it. On Armbian main `1cdbc7ab7b7c513da761b0322a8f1386ae362916`, the smallest
RK3588 test PR is one added line:

```diff
--- a/config/sources/families/rockchip-rk3588.conf
+++ b/config/sources/families/rockchip-rk3588.conf
@@
 BOOTPATCHDIR="legacy/u-boot-radxa-rk35xx"
+enable_extension "uboot-makefile-fix-itb-deps"
 OVERLAY_PREFIX='rockchip-rk3588'
```

The extension checks that `u-boot.itb` exists and lacks `u-boot.dtb` before
editing, so the family-level enablement is narrowly guarded. The ready-to-use
[one-line patch](evidence/2026-07-13-u-boot-fit-dtb-race/armbian-rockchip-rk3588-enable-itb-deps-extension.patch)
is based on that main commit.

[Radxa PR #189](https://github.com/radxa/u-boot/pull/189) is still open and
targets `next-dev-v2026.01`, while Armbian's RK3588 family still tracks
`next-dev-v2024.10` at `39cd993e5d`. The Armbian extension therefore still
changes the exact source used by the failing job.

The discriminating CI test is:

1. Temporarily route the unmodified baseline and the one-line branch to a
   previously known-bad KSpace host.
2. Pin and print the Armbian commit, U-Boot commit, container image ID, host
   filesystem, Docker storage driver, CPU visibility, `CTHREADS`, and runner
   concurrency.
3. Run at least 20 clean U-Boot builds per arm. The reported 98% baseline
   failure rate should make this more than enough to distinguish the result.
4. For every build, assert both `u-boot.dtb` size and `dumpimage -l u-boot.itb`
   FDT size. Preserve failures and target-order logs.

If the baseline fails and the one-line branch does not, that directly tests
the Makefile diff without needing to prove which scheduler or filesystem
event selected the bad ordering. `cp --reflink=never` can be a useful
diagnostic third arm, but it is not an acceptable fix because it leaves the
consumer and producer unordered.

## Boundary

The controlled test proves the graph defect and its correction. The source
inspection proves the Jammy/Noble `cp` path difference and that Noble can
wait inside clone preparation after exposing a zero-length destination. The
KSpace load and filesystem mechanisms are plausible amplifiers, not yet
measured causes. The exact historical Noble image package inventory and the
KSpace host filesystem remain unknown.
