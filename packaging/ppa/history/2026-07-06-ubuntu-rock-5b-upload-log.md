# PPA upload and archive-migration incident record

> **Frozen dated audit.** This record preserves two material incidents from the
> 2026-07-06 through 2026-07-14 packaging campaign. It does not own current
> package versions, publication state, build inputs, or validation. Use the
> [PPA front door](../README.md), [W05](../../../status.md#watch-w05), and each
> package's artifact record for those answers.

## Scope and disposition

The original working log mixed build commands, repeated publication polls,
ordinary upload chronology, source experiments, runtime results, and two
load-bearing operational lessons. Routine chronology was removed on 2026-08-05
after its current facts were traced to Debian/Launchpad metadata, changelogs,
package owners, status, and dated findings. The two incidents below remain
because they explain recovery behavior that artifact metadata alone does not.

The maintained [sign/upload/recovery runbook](../README.md#sign-upload-and-recover)
owns the procedure derived from these incidents. This file owns only their
dated evidence and decision basis.

## Incident 1 — non-deterministic orig tarballs rejected

Launchpad rejected a packaging-only librga revision because an orig tarball
with the same filename already existed but the new upload had different bytes:

```text
File librga_2.2.0+git20260703.a632217.orig.tar.gz already exists in
Ubuntu Rock 5B Support, but uploaded version has different contents.
```

The mismatch was measured, not inferred:

| Package | Accepted orig SHA-256 / size | Regenerated orig SHA-256 / size |
|---------|-----------------------------|--------------------------------|
| librga | `1e1d12fb4eacd7dcbfdddf316691b2026c0e020f59aef1a84b932f483ad71679` / 8,040,158 | `5f8083361c895198b12bc883a5f93a61d030a8163167c55a606194974aa92c72` / 8,040,176 |
| MPP | `d096f57c355e70437f95e224c1f4a53d23ad96f8bed399aa7c8bb1351eefb321` / 3,824,069 | `c8607e4bca78e1b7b5441202287faec8ada3fc75e76d8b07dea84c44d79ffd94` / 3,824,068 |

The helper regenerated `.orig.tar.gz` on every build. File ordering, metadata,
and gzip headers made a logically identical source export byte-different. That
is invalid for a Debian-only revision because Launchpad identifies the upstream
payload by filename and requires the already-accepted bytes.

Recovery was:

1. retrieve the accepted orig tarballs from the PPA;
2. verify them against the accepted `.dsc` checksums;
3. rebuild the Debian revisions around those exact payloads;
4. reverify the new `.dsc` and source `.changes`; and
5. use `dput --force` only because rejected attempts had left local
   `*.ppa.upload` markers while the API/source index proved no corrected source
   had been accepted.

The helper was changed to reuse an existing orig by default and to reject a
stale orig whose extracted tree differs from the intended export. New origs use
sorted entries, fixed ownership, a source-derived timestamp, and `gzip -n`.
`FORCE_ORIG=1` is now reserved for a genuinely new upstream version. Those
enforced mechanics, not this audit, are the current authority.

## Incident 2 — incompatible ABI forced a deliberate archive split

The first normal PPA had accepted FFmpeg 8.1-era packages, while the target
Ubuntu Resolute desktop stack needed an ABI-compatible FFmpeg 8.0 line.
Launchpad would not accept the lower replacement source version into that same
archive. Treating the problem as an ordinary upload or package downgrade could
not produce a coherent archive.

Before deleting anything, the migration:

- created dedicated archives for upstream FFmpeg 8.1, Rockchip FFmpeg 8.1, and
  the two rewrite-kernel lines;
- copied recoverable source and binary publications to those archives;
- copied the compatible main-stack source/binaries to the experimental holding
  PPA and downloaded the stable arm64 binary set with package/version/hash
  verification;
- recorded archive dependencies and reverse-dependency effects; and
- prepared ABI-62 FFmpeg, matching GRD, and codec-udev sources before the cut.

Launchpad accepted deletion of `ppa:yi-ding/ubuntu-rock-5b` on 2026-07-14 at
about 09:10 PDT. The old archive remained a disabled/redacted object, and its
name could not be reused during the deletion grace period. The name became
available about 46 minutes later. The recreated archive was configured arm64
only and retained the owner's signing-key identity.

Compatible MPP, librga, co-installable FFmpeg 6.1, and forward-port kernel
publications were restored from the holding archive. ABI-compatible FFmpeg 8.0,
GRD, and codec-udev were then built in dependency order. A temporary dependency
on the holding archive was removed after the required development packages were
available; the recreated normal PPA ended with zero extra archive dependencies.

This incident justifies the archive topology and recovery rule; it does not
serve as a publication list. The maintained [PPA layout](../README.md#ppa-layout)
owns current archive roles, and W05 owns external freshness.

## Promoted or independently retained results

- Orig reuse, signing, upload confirmation, dependency ordering, failed-build
  capture, and archive-recreation safeguards live in the current
  [runbook](../README.md#sign-upload-and-recover).
- FFmpeg 8.1 baseline recovery and its missing `frei0r-plugins` build dependency
  live in [`../ffmpeg-baseline/README.md`](../ffmpeg-baseline/README.md).
- Forward-port kernel `mkimage`/`u-boot-tools` retries and source/build identities
  live in [`../kernel-forward-port/README.md`](../kernel-forward-port/README.md).
- Current and historical package artifacts are reconstructible from their
  `.dsc`, `.buildinfo`, `.changes`, checksums, Launchpad publication/build IDs,
  and package changelogs; the PPA front door links the maintained records.
- Runtime conclusions remain in project owners and dated findings. They are not
  package-upload provenance merely because the working log once mentioned them.

## Boundary

Do not append routine uploads or service rechecks here. Add another dated
history record only for otherwise-unavailable artifact reconstruction, a
material incident explanation, or a reusable operational lesson that cannot be
expressed safely in the live runbook. Git history retains the removed diary if
forensic chronology is ever required.
