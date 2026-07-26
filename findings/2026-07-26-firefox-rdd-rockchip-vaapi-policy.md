# Firefox 152.0.6 RDD needs both Rockchip broker paths and ioctl requests

> Scope: Firefox RDD sandbox policy for the `rockchip-vaapi` VA-API-over-MPP
> driver on arm64.
>
> Source: sibling `../rockchip-vaapi` commit `03e6cb6`; Mozilla
> `FIREFOX_152_0_6_RELEASE` versions of `SandboxFilter.cpp` and
> `SandboxBrokerPolicyFactory.cpp`; installed Firefox, MPP, and librga packages;
> hardware ioctl traces from the existing H.264 RGB encode and HEVC Main10
> decode gates.
>
> Date: 2026-07-26
>
> Trust: **SOURCE-INSPECTED / CODE-INSPECTED / MEASURED / IMPLEMENTED /
> PARTIAL-VALIDATION**

## Result

The earlier shorthand, "allow MPP `'v'` and dma-heap `'H'`", was incomplete.
Firefox 152.0.6 has two independent RDD controls:

1. `SandboxBrokerPolicyFactory::GetRDDPolicy()` controls which paths RDD may
   open. It already adds `/dev/dri`, but not `/dev/mpp_service`, `/dev/rga`, or
   `/dev/dma_heap`.
2. `RDDSandboxPolicy::EvaluateSyscall()` controls ioctl requests after a file
   is open. It allows DRM `'d'`, DMA-BUF `'b'`, and, on arm64, NVIDIA nvmap
   `'N'` and nvhost `'H'` ioctl families.

The existing arm64 nvhost rule therefore already admits dma-heap allocation
request `0xc0184800` because its ioctl type is also `'H'`. The dma-heap blocker
is the missing broker path, not a missing seccomp family. MPP and RGA still
need seccomp additions.

## Exact source contract

The installed browser is
`152.0.6+build1-0ubuntu0.26.04.1~mt1` on arm64. The patch is pinned to Mozilla's
matching `FIREFOX_152_0_6_RELEASE` preimages:

```text
7a9c7b4e56b5ed0401998f42242bd576bff5461e85df271d42f73844a2bf9f47  security/sandbox/linux/SandboxFilter.cpp
0bc000706b11d7dcf54c71f67bd1cb32d2214e939fbb67634e0bd0036b805af0  security/sandbox/linux/broker/SandboxBrokerPolicyFactory.cpp
```

Installed userspace versions during the trace were:

```text
librockchip-mpp 1.5.0+git20260529.1375813c+ds-0ubuntu2~rk1
librga           2.2.0+git20260725.26a50ef-0ubuntu1~rk1
```

## Measured request set

An `LD_PRELOAD` ioctl logger wrapped the existing hardware gates. Both the
48-frame BGRA DMA-BUF -> RGA -> H.264 encode path and the generated plus pinned
HEVC Main10 AFBC -> RGA P010 decode paths used this Rockchip request set:

| Device | Request | Purpose |
|---|---:|---|
| `/dev/mpp_service` | `0x40047601` | MPP v1 command transport |
| `/dev/rga` | `0x801c7201` | RGA driver version |
| `/dev/rga` | `0x80907202` | RGA hardware version |
| `/dev/rga` | `0x5017` | legacy synchronous blit |

The same traces observed `/dev/dma_heap/system` request `0xc0184800` and
DMA-BUF sync request `0x40086200`; Firefox's existing `'H'` and `'b'` rules
cover those requests.

## Implemented patch

`rockchip-vaapi@03e6cb6` adds a distribution source patch under
`contrib/firefox/` that:

- permits only the four measured MPP/RGA requests on arm64;
- adds broker access to `/dev/mpp_service` and `/dev/rga` only when each is an
  existing character device;
- adds `/dev/dma_heap` only when the directory exists;
- leaves the RDD sandbox enabled and does not introduce
  `MOZ_DISABLE_RDD_SANDBOX`;
- rejects source drift by checking both exact upstream SHA-256 preimages.

The offline contract check, shellcheck, and a dry-run plus real patch apply to
the exact Mozilla preimages pass. Existing H.264 RGB encode and HEVC Main10
hardware gates remain green while measuring the request set.

## Boundary

This is source-policy and hardware-ABI validation, not a completed Firefox app
gate. The matching Ubuntu source package has since been patched, configured,
formatted, and partially compiled, but the compile was stopped on request
before producing a binary package. It has not been installed, and this login
has no Wayland or X11 display socket for browser playback. See the
[package-build checkpoint](2026-07-26-firefox-rdd-package-build-checkpoint.md).
The remaining proof is a completed package build followed by live RDD hardware
decode with `MOZ_DISABLE_RDD_SANDBOX` unset and the RDD process still
sandboxed.
