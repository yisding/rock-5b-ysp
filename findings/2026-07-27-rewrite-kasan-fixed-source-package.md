# Fixed-source rewrite KASAN package is built and package-verified

> Scope: ROCK 5B clean-room rewrite qualification kernel
> Source: 6.18 `835b19f81d2b41d7ab5269e61a7b022d901a6928`;
> mainline mirror `79a804a26e005d6b2eecff802fa7b40fc566600e`;
> Armbian build UUID `37722ae4-b7a1-413f-ac7e-fa2e13ca432d`
> Date: 2026-07-27
> Trust: SOURCE-INSPECTED / COMPILE-VERIFIED / PACKAGE-VERIFIED / PARTIAL

## Result

The fixed 6.18 source built successfully as KASAN/lockdep package
`P259b-Cad24`:

```text
6.18.40-S221f-D3dd5-P259b-Cad24-H9acc-HK01ba-Vc222-Bfe95-R448a
```

The package contains both rewrite drivers and both KUnit suites built in,
KASAN generic inline instrumentation, UBSAN, lockdep, DMA API debug, Debug
Objects, kmemleak, IOMMU debugfs, and KUnit debugfs/autostart. The conflicting
vendor MPP, multi-RGA, and V4L2 RGA drivers are unset. `CONFIG_DWC_PCIE_PMU` is
also unset so the unrelated same-class bus-notifier lockdep report cannot
disable lockdep before KUnit.

This is package proof, not boot proof. Nothing was installed, selected for
boot, or exercised on the board in this build session.

## Source repair included

The build stages 327 rewrite patches. Its final patch is:

```text
From 835b19f81d2b41d7ab5269e61a7b022d901a6928
Subject: [PATCH 327/327] media: rockchip: mpp-rewrite: move batch fixture off stack
```

That commit moves the large `struct rk_mpp_service` in
`rk_mpp_batch_server_wait_collect_reject_kunit()` to `kunit_kzalloc()`. The
mainline tree carries the byte-identical change at `79a804a26e005`. The applied
build worktree contains the heap-backed fixture, and the package control record
names stable base `221fc2f4d0eda59d02af2e751a9282fa013a8e97`, patch hash
`259befaeb85731ae`, and config hash `ad24efda480a1b5f`.

The old function's KASAN-inflated 2,928-byte frame warning is absent from the
new log. The log still reports 31 pre-existing `-Wframe-larger-than=2048`
warnings in other KUnit functions (13 MPP and 18 RGA), so this build is not
described as globally warning-free. Those warnings are compile-time stack-size
diagnostics; they are distinct from the booted Debug Objects lifetime reports
that prompted the KUnit repair.

## Reproduction and build behavior

The successful command was:

```bash
PATH=/usr/sbin:/usr/bin:/sbin:/bin \
  ARMBIAN_USE_CCACHE=yes \
  ARMBIAN_USE_TMPFS=no \
  bash kernel-drivers/scripts/build-kernel.sh rewrite-debug CPUTHREADS=4
```

The compile and install phase took 2,750 seconds, packaging took 172 seconds,
and the complete run took 53:18. Ccache reported 14,035 hits and 77 misses.

An earlier 12-job attempt failed in `fixdep` while two RK3566 overlay dependency
files were being produced. A serialized retry proved the targets themselves
were valid; four jobs avoided the overlay dependency-file race and completed
both the preceding build and this authoritative fixed-source rebuild. This was
a build-system concurrency failure, not a rewrite source failure.

## Package inspection

All packages are arm64, Debian version `26.08.0-trunk`:

| Package | SHA-256 |
|---------|---------|
| `linux-image-video-rewrite-kasan-rockchip64` | `28255293c0c162528fc4bd5cdcf4ea7a99a05ff0a6f99870063fb8058e592c96` |
| `linux-dtb-video-rewrite-kasan-rockchip64` | `9143ecca32c9a1e318b1db77e4d4e2d70bb76c175c664261054c183bf370e97c` |
| `linux-headers-video-rewrite-kasan-rockchip64` | `ae1828c0a7249e8e4bf61a2ce80b0d813c5101372d43aa67e3fd96defc45a512` |
| `linux-libc-dev-video-rewrite-kasan-rockchip64` | `a9fae88e2b327896a6b226efa2ea34eec365d1270e165f21661d3396944ce914` |

Payload fingerprints:

| Payload | SHA-256 |
|---------|---------|
| `vmlinuz-6.18.40-video-rewrite-kasan-rockchip64` | `fb219b03d1b2b99eef5b8f72f30cea7365782ce33ad219b2ccfcca9c8065140e` |
| packaged kernel config | `692216a4b48d2cf5fdd19e4fb27bbf21a0728efe6e70d8daa078a9acf3525c88` |
| packaged `rk3588-rock-5b.dtb` | `2961225a7738b16f4517ddf4a0452329b2d4792bcca1c7a748bab65a641c7849` |

The DTB package contains `rk3588-rock-5b.dtb` plus the Rock 5B Plus, PCIe EP,
and PCIe SRNS variants. The primary ROCK 5B DTB has:

- ramoops at `0x118000`, size `0xd0000`, with the expected record, console,
  pmsg, and ECC sizes;
- RGA3 core 0 at `0xfdb60000`, size `0x200`, GIC SPI 114; and
- RGA3 core 1 at `0xfdb70000`, size `0x200`, GIC SPI 115.

The disjoint `0x200` windows preserve the DT resource repair that allowed both
RGA3 cores to bind on build `#6`.

## Next gate

Install `P259b-Cad24` through the documented recovery-prepared kernel installer,
boot it, fingerprint the running image, and require:

1. 85/85 MPP plus 148/148 RGA KUnit results;
2. no Debug Objects or other fatal dmesg signature;
3. lockdep still enabled after KUnit;
4. RGA2 and both RGA3 cores bound; and
5. isolated ABI replay with clean dmesg and readable rewrite debugfs.
