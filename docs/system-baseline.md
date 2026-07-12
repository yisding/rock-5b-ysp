# System baseline — identify the board, userspace, kernel, and build host

A result is reproducible only when readers can tell **which ROCK 5B**, **which
boot path**, **which kernel**, and **which userspace** produced it. This page is
the canonical capture contract. It does not freeze another copy of project
status; it points each changing claim to its existing dated owner.

## Keep these environments separate

| Layer | What to record | Common confusion |
|-------|----------------|------------------|
| Target board | Board model/revision, RK3588 architecture, relevant attached storage or display. | Calling a build VM “the ROCK 5B.” |
| Boot path | SPI/raw-SD loader family, root medium, overlays, and recovery path. | Treating an intact SD loader and SPI fallback as the same boot. |
| Runtime kernel | `uname`, package version, profile name, patch/commit or PHASH, and built-in vs module delivery. | Treating 6.18 combined, PPA forward-port, DKMS, vendor 6.1, and rewrite kernels as interchangeable. |
| Target userspace | Ubuntu/Armbian release plus installed MPP, librga, FFmpeg, GRD, Kodi, and Mesa/package versions relevant to the result. | Calling Ubuntu 26.04 the native kernel **build host**. |
| Build host | Host OS/architecture, native vs Docker mode, Armbian-build commit, and resource limits. | Assuming a successful package build proves the package booted on hardware. |

Ubuntu 26.04 Resolute is the target userspace for this repository. The documented
native Armbian build-host baseline is Armbian or Ubuntu 24.04 Noble; other Linux
hosts use Docker. The distinction and current upstream requirements are owned by
[`install.md`](../install.md) §2.

## Where current truth lives

| Question | Canonical source |
|----------|------------------|
| What works, what is incomplete, and what proof comes next? | [`status.md`](../status.md) dashboard and next gates. |
| Which kernel build has real codec/RGA hardware evidence? | [`kernel-drivers/docs/forward-port-status.md`](../kernel-drivers/docs/forward-port-status.md) and the PHASH log in [`install.md`](../install.md). |
| Which PPA packages are public or still gated? | [`packaging/ppa/README.md`](../packaging/ppa/README.md) and watchlist item [W05](../status.md#watch-w05). |
| What is known about SPI, raw SD, and NVMe boot? | Dashboard track 12 and watchlist/detail evidence under [`findings/`](../findings/README.md). |
| What build machine and Armbian branch map were measured? | [`findings/2026-07-08-armbian-builder-setup.md`](../findings/2026-07-08-armbian-builder-setup.md) and watchlist item [W14](../status.md#watch-w14). |
| Which external source contents do code citations mean? | [`source-trees.md`](source-trees.md). |

Do not copy those values into a new finding without a reason. Link to the owner,
then record only the baseline facts specific to the new run.

## Minimum result header

Every hardware validation, performance number, or failure report should make
this block answerable:

```text
Capture date:       YYYY-MM-DDThh:mm:ss±hh:mm
Board:              Radxa ROCK 5B / RK3588 / relevant RAM or peripherals
Boot path:          SPI→NVMe | SPI→SD | raw SD | other
OS/userspace:       Armbian release + Ubuntu/Debian release and architecture
Kernel profile:     forward-port | rewrite | vendor | DKMS | descriptive variant
Kernel identity:    uname + package version + PHASH or source commit
Media userspace:    MPP + librga + FFmpeg package/source versions
Test/evidence:      exact command + output directory + pass/fail signal
```

Use an exact timestamp and profile name. “Current,” “stock,” and “the board” are
not identities. A PHASH identifies an Armbian patch/config combination; it does
not replace `uname`, package version, or a source pin.

## Capture it with the existing collector

The tracked conformance collector is the canonical machine-readable starting
point:

```bash
PROFILE=forward-port \
  bash kernel-drivers/tests/conformance/scripts/collect-system-info.sh
```

It writes a timestamped directory under
`kernel-drivers/tests/conformance/logs/<profile>/` and prints that path. The
directory is ignored by Git. The external `../rockchip-conformance` bundle gets
the same script from `bootstrap-workspaces.sh`, so paired conformance runs can
use:

```bash
PROFILE=forward-port ./scripts/collect-system-info.sh
PROFILE=rewrite      ./scripts/collect-system-info.sh
```

`system.txt` records:

- profile, timestamp, `uname`, architecture, board model, and compatible list;
- `/etc/os-release` and `/etc/armbian-release` when present;
- kernel command line and selected `armbianEnv.txt` keys, with root/resume
  identifiers redacted;
- installed kernel and media-support packages;
- FFmpeg path/version and exposed Rockchip codecs/filters;
- relevant kernel configuration, device-node ownership, RGA version, MPP
  proc/debugfs state, and loaded Rockchip modules.

The collector also writes `dmesg.txt` and `dmesg-tail.txt`. On systems with
`kernel.dmesg_restrict=1`, those files can be empty unless the surrounding test
run has sufficient privilege. An empty dmesg capture is a missing evidence
channel, not proof that no fault occurred.

## Privacy and publication

The collector deliberately avoids network addresses, disk serial numbers, and
unredacted root/resume identifiers. It still records the hostname through
`uname`, package versions, device paths, boot options, and kernel logs. Review a
bundle before publishing it; kernel logs can contain unexpected device-specific
or application data.

Do not commit raw capture directories. Summarize the result in a dated
[`findings/`](../findings/README.md) entry, link or checksum any externally kept
log bundle, and promote stable conclusions through the workflow in
[`CONTRIBUTING.md`](../CONTRIBUTING.md).

## What the capture does not prove

- Device nodes existing does not prove jobs ran on hardware.
- A package appearing in `dpkg-query` does not prove its binary was selected.
- A successful build does not prove install, boot, rollback, or runtime safety.
- A clean dmesg tail does not replace output correctness, counters, or paired
  forward-port/rewrite evidence.

Use the project test named by the relevant status next gate. The baseline tells
future readers what was tested; the test's pass criteria tell them whether it
worked.
