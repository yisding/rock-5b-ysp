# Jammy/Noble `cp`, Linux clone, and runner evidence

> Captured: 2026-07-14
> Purpose: reproducible evidence appendix for
> [the ROCK 5B zero-DTB finding](../../2026-07-13-rock5b-u-boot-fit-dtb-race.md)

## Container identities

The tags were inspected and then run directly:

| Tag | Image/config ID | Created | Packages |
|---|---|---|---|
| `ghcr.io/armbian/docker-armbian-build:armbian-ubuntu-jammy-latest` | `sha256:6ea94ee030d7fa69298baecaa155c73258bee13a91847b635d458167f4969231` | 2026-07-14T05:27:52Z | `make 4.3-4.1build1`, `coreutils 8.32-4.1ubuntu1.3`, `libc6 2.35-0ubuntu3.13`, GCC 11.4.0 |
| `ghcr.io/armbian/docker-armbian-build:armbian-ubuntu-noble-latest` | `sha256:09239184227e3576e8af92af6f9b9a2170957f9ab5f4b1e4e06710bf75aa3027` | 2026-07-05T06:37:54Z | `make 4.3-4.1build2`, `coreutils 9.4-3ubuntu6.2`, `libc6 2.39-0ubuntu8.7`, GCC 13.3.0 |

Commands:

```bash
docker image inspect IMAGE --format '{{.Id}} {{.Created}} {{json .RepoDigests}}'
docker run --rm IMAGE make --version
docker run --rm IMAGE dpkg-query -W coreutils make libc6
docker run --rm IMAGE gcc -dumpfullversion
```

These are current tag resolutions, not the historical failing image. Job
83921496847 logged local image/config ID
`sha256:7283efcbc74982aba2b45544c978d554debfb2e474193cc5181578a9584dc433`
with `DOCKER_SKIP_UPDATE=yes`. The tag is mutable and now resolves to a
different object.

## Ubuntu source packages

The source packages were downloaded with `apt-get source` from the matching
Ubuntu archives:

| File | SHA-256 |
|---|---|
| `coreutils_8.32-4.1ubuntu1.3.dsc` | `26959de3887a535d7929e5f3ac18eab6eaba5f221cdcf3b4cf7b43c68d32f92b` |
| `coreutils_8.32.orig.tar.xz` | `4458d8de7849df44ccab15e16b1548b285224dbba5f08fac070c1c0e0bcc4cfa` |
| `coreutils_8.32-4.1ubuntu1.3.debian.tar.xz` | `5ff54161038e479c904042f8848e40b40f5330bc4e4f2df9a474974f3d466061` |
| `coreutils_9.4-3ubuntu6.2.dsc` | `a16ffb435f38507bea51474f5e40a26e4c8191d2190da8770e8e4726c18e37ba` |
| `coreutils_9.4.orig.tar.xz` | `ea613a4cf44612326e917201bbbcdfbd301de21ffc3b59b6e5c07e040b275e52` |
| `coreutils_9.4-3ubuntu6.2.debian.tar.xz` | `6cd2ec4b6af4c52d5aa7bf6b5843bbb9b878be42d91b279de8b7afae843c8fa0` |

The Noble quilt series includes `cp-n.diff`, but that patch changes
no-clobber behavior, not reflink or copy offload. Searching the applied
Ubuntu patches for `FICLONE`, `copy_file_range`, and `reflink` found no copy
engine changes.

## Exact coreutils control flow

Source anchors:

- Jammy
  [`src/cp.c`](https://git.launchpad.net/ubuntu/+source/coreutils/tree/src/cp.c?h=ubuntu/jammy-updates)
  initializes `x->reflink_mode = REFLINK_NEVER`.
- Noble
  [`src/cp.c`](https://git.launchpad.net/ubuntu/+source/coreutils/tree/src/cp.c?h=ubuntu/noble-updates)
  initializes `x->reflink_mode = REFLINK_AUTO`.
- Noble `src/copy.c` opens an existing destination with `O_TRUNC`, then
  invokes `clone_file`, whose Linux implementation is `ioctl(FICLONE)`.
- Noble `sparse_copy` attempts `copy_file_range` when reflink/offload is
  allowed. It falls back only when no bytes have moved and the error is
  considered unsupported, or when the first call returns zero.
- Noble `handle_clone_fail` treats `EIO`, `ENOMEM`, `ENOSPC`, and `EDQUOT` as
  terminal. Other clone failures normally fall through to the data-copy path.

The locally extracted line anchors were:

| Behavior | Jammy 8.32 | Noble 9.4 |
|---|---:|---:|
| default reflink mode | `src/cp.c:796` | `src/cp.c:836` |
| existing-destination `O_TRUNC` | `src/copy.c:1099-1100` | `src/copy.c:1287-1292` |
| `FICLONE` wrapper | absent from default path | `src/copy.c:489-501` |
| clone fallback | absent from default path | `src/copy.c:1183-1216` |
| clone invocation | absent from default path | `src/copy.c:1510-1527` |
| `copy_file_range` loop | absent | `src/copy.c:332-384` |
| buffered write | `src/copy.c:271-315` | later fallback in `sparse_copy` |

The decisive source values are short:

```c
/* coreutils 8.32, cp.c */
x->reflink_mode = REFLINK_NEVER;

/* coreutils 9.4, cp.c */
x->reflink_mode = REFLINK_AUTO;

/* coreutils 9.4, copy.c */
return ioctl (dest_fd, FICLONE, src_fd);
```

## Disposable-container traces

`strace` was installed at runtime in disposable containers. The destination
was pre-created so both versions exercised the existing-file `O_TRUNC` path.
Payload bytes came from `/dev/urandom`.

### Jammy, 12,752 bytes, same container filesystem

```text
1784078737.328403 openat(..., "/tmp/src", O_RDONLY) = 3 <0.000039>
1784078737.328587 openat(..., "/tmp/dst", O_WRONLY|O_TRUNC) = 4 <0.000078>
1784078737.328948 read(3, ..., 131072) = 12752 <0.000041>
1784078737.329050 write(4, ..., 12752) = 12752 <0.000099>
```

There was about 0.39 ms from the return of `open(O_TRUNC)` to the start of
`write`.

### Noble, 12,752 bytes, same container filesystem

```text
1784078736.884533 openat(..., "/tmp/src", O_RDONLY) = 3 <0.000045>
1784078736.884724 openat(..., "/tmp/dst", O_WRONLY|O_TRUNC) = 4 <0.000166>
1784078736.884965 ioctl(4, FICLONE, 3) = -1 EOPNOTSUPP <0.000030>
1784078736.885281 copy_file_range(3, NULL, 4, NULL, ..., 0) = 12752 <0.000193>
1784078736.885537 copy_file_range(3, NULL, 4, NULL, ..., 0) = 0 <0.000057>
```

There was also about 0.39 ms from the return of `open(O_TRUNC)` to the start
of the successful `copy_file_range`. This run gives no evidence of a
universally longer Noble window.

### Noble, 39,811 bytes, container overlay to tmpfs

The cross-mount destination forced both fast paths to fail:

```text
1784078736.916372 openat(..., "/mnt/dst", O_WRONLY|O_TRUNC) = 4 <0.000059>
1784078736.916543 ioctl(4, FICLONE, 3) = -1 EXDEV <0.000098>
1784078736.916977 copy_file_range(3, NULL, 4, NULL, ..., 0) = -1 EXDEV <0.000033>
1784078736.917204 read(3, ..., 131072) = 39811 <0.000164>
1784078736.917485 write(4, ..., 39811) = 39811 <0.000069>
```

The interval from `O_TRUNC` return to `write` start was about 1.05 ms.
Repeating the same source/destination with `--reflink=never` produced:

```text
1784078736.946569 openat(..., "/mnt/dst2", O_WRONLY|O_TRUNC) = 4 <0.000045>
1784078736.946936 read(3, ..., 131072) = 39811 <0.000160>
1784078736.947159 write(4, ..., 39811) = 39811 <0.000087>
```

That interval was about 0.55 ms. The roughly 0.5 ms difference is one traced
sample under `strace`, not a latency distribution.

## Linux 6.6 clone path

Official `v6.6` source anchors:

- [`fs/ioctl.c`](https://github.com/torvalds/linux/blob/v6.6/fs/ioctl.c#L231-L250):
  `FICLONE` calls `vfs_clone_file_range`. The helper rejects a short
  positive result only when the caller supplied a nonzero length.
  Whole-file `FICLONE` passes zero to mean “to EOF,” so that exact-count
  guard does not apply.
- [`fs/remap_range.c`](https://github.com/torvalds/linux/blob/v6.6/fs/remap_range.c#L262-L368):
  generic preparation waits for direct I/O and calls
  `filemap_write_and_wait_range` for source and destination before remapping.
- [`fs/btrfs/reflink.c`](https://github.com/torvalds/linux/blob/v6.6/fs/btrfs/reflink.c#L794-L870):
  Btrfs flushes the source mapping and waits for ordered ranges on both files
  before entering the generic preparation path.
- The same Btrfs file updates `i_size` during clone transactions, can
  `cond_resched` between extents, and returns the requested length only
  after its clone path succeeds.
- [XFS `xfs_reflink_remap_blocks`](https://github.com/torvalds/linux/blob/v6.6/fs/xfs/xfs_reflink.c#L1350-L1422)
  remaps extent by extent, updates destination size per extent, and records
  both progress and a later error.
  [`xfs_file_remap_range`](https://github.com/torvalds/linux/blob/v6.6/fs/xfs/xfs_file.c#L1123-L1187)
  returns the positive remapped count if any progress occurred, even when
  `ret` later contains an error. Combined with whole-file `FICLONE`'s zero
  length sentinel, the ioctl can report success for a rare partial XFS clone.
  That is a possible nonzero partial-corruption path, not evidence for the
  observed empty DTB.

The
[FICLONE manual page](https://www.man7.org/linux/man-pages/man2/FICLONERANGE.2const.html)
describes shared storage and concurrency semantics; it does not describe a
temporary-file rename. The
[`copy_file_range` manual page](https://man7.org/linux/man-pages/man2/copy_file_range.2.html)
allows short copies and documents historical virtual-filesystem bugs.

## Pinned Armbian environment

The failing
[job](https://github.com/armbian/os/actions/runs/28326623973/job/83921496847)
checked out Armbian build
`654bb1d7ffdda154a81d6d93729f4e8163702ce3` and Radxa U-Boot
`39cd993e5d6296635438e84f4576b3a9bf76f86e`.

Pinned Armbian source facts:

- [`compilation-config.sh`](https://github.com/armbian/build/blob/654bb1d7ffdda154a81d6d93729f4e8163702ce3/lib/functions/configuration/compilation-config.sh)
  counts `/proc/cpuinfo` processors and sets `CTHREADS` to 1.5 times that
  count unless overridden.
- [`uboot.sh`](https://github.com/armbian/build/blob/654bb1d7ffdda154a81d6d93729f4e8163702ce3/lib/functions/compilation/uboot.sh)
  passes the U-Boot target string and `CTHREADS` to one parallel Make.
- [`mountpoints.sh`](https://github.com/armbian/build/blob/654bb1d7ffdda154a81d6d93729f4e8163702ce3/lib/functions/host/mountpoints.sh)
  makes the U-Boot worktree a Linux bind mount and a Darwin named volume.
- [`docker.sh`](https://github.com/armbian/build/blob/654bb1d7ffdda154a81d6d93729f4e8163702ce3/lib/functions/host/docker.sh)
  contains no Docker CPU quota/cpuset option in the launch path.

The job printed Docker-visible 64 CPUs, implying `-j96` from the pinned
formula. Its public runner record listed 24 runners and 128 host vCPUs. The
job did not print `findmnt`, `stat -f`, or the Docker storage driver, so the
host filesystem type remains unknown.

## Related container precedents

- [Docker for Mac #5570](https://github.com/docker/for-mac/issues/5570):
  Docker Desktop 3.3.1 trace where `copy_file_range` returned zero for a
  918-byte input and the destination remained empty.
- [Docker for Linux #1015](https://github.com/docker/for-linux/issues/1015):
  the underlying overlayfs regression and the stable-kernel fixes.
- [Colima #901](https://github.com/abiosoft/colima/issues/901): open report
  of about 60 MB/s using the clone command's `cp` versus about 300 MB/s with
  `rsync`.
- [Colima #146](https://github.com/abiosoft/colima/issues/146): host-mounted
  70,000-file workload about four times slower than VM-local storage.
- [Docker for Mac #3677](https://github.com/docker/for-mac/issues/3677):
  old but concrete local-versus-bind write benchmark.
- [Docker for Mac #6667](https://github.com/docker/for-mac/issues/6667):
  version-, backend-, and architecture-dependent VirtioFS/gRPC-FUSE
  performance reports.

These reports establish precedent and possible latency mechanisms. They are
not measurements of KSpace and do not establish a current coreutils 9.4
performance regression.
