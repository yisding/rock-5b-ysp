# Controlled delay reproduces the ROCK 5B FIT zero-DTB race

> Scope: ROCK 5B vendor U-Boot FIT packaging (`downloads/uboot-race-test-39cd`)
> Source: `39cd993e5d`, `Makefile` `u-boot.dtb` and `u-boot.itb` rules (~951, ~1059), plus generated `u-boot.its`
> Date: 2026-07-13
> Trust: MEASURED, SOURCE-INSPECTED

## Result

The vendor FIT rule invokes `mkimage` on `u-boot.its`, which embeds
`./u-boot.dtb`, but the original `u-boot.itb` prerequisite list named only
`dts/dt.dtb`. When `u-boot.dtb` and `u-boot.itb` were requested in parallel,
the FIT packer could therefore read `u-boot.dtb` before its `COPY` recipe had
finished. A controlled three-second delay before that copy made the failure
deterministic: the resulting FIT's `fdt` image had a 0-byte payload, despite
the copied `u-boot.dtb` finishing at 12,752 bytes.

Changing the FIT rule to depend on `u-boot.dtb` serializes the producer and
consumer. With the same delay and an initially empty output file, the FIT's
`fdt` payload was 12,752 bytes and the log ordered `COPY u-boot.dtb` before
`MKIMAGE u-boot.itb`.

```diff
-u-boot.itb: u-boot-nodtb.bin dts/dt.dtb $(U_BOOT_ITS) FORCE
+u-boot.itb: u-boot-nodtb.bin u-boot.dtb $(U_BOOT_ITS) FORCE
```

## Evidence and reproduction

- **Identity:** vendor U-Boot source at `39cd993e5d`; initial valid FIT control
  DTB was 12,752 bytes.
- **Inspection:** `u-boot.its` declares
  `data = /incbin/("./u-boot.dtb");`; the original Makefile rule did not name
  that file as a prerequisite.
- **Exercise:** truncate `u-boot.dtb`, temporarily sleep three seconds before
  its `COPY` recipe, then run `make -j2 u-boot.dtb u-boot.itb`.
- **Pre-fix signal:** `tools/dumpimage -l u-boot.itb` reported the `fdt` image
  `Data Size: 0 Bytes`; the final copied `u-boot.dtb` was 12,752 bytes.
- **Post-fix signal:** the same inspection reported `Data Size: 12752 Bytes`;
  the build log placed `COPY u-boot.dtb` before `MKIMAGE u-boot.itb`.
- **Artifacts:** ignored local capture directory
  `downloads/uboot-race-test-39cd/.race-artifacts/` contains the pre-fix and
  post-fix FITs and logs. The temporary delay was removed after the test.

## Boundary

This establishes the build-graph race and verifies that the dependency fix
prevents this induced scheduling window. It does not by itself prove which
historical production artifact, if any, was created through this exact window,
nor does it validate a board boot from the rebuilt FIT.

## Why it matters / follow-up

The fix makes the Makefile dependency match the file actually consumed by the
FIT source, replacing a probabilistic packaging defect with explicit ordering.
The next hardware-facing check is booting a full, nonzero-control-DTB FIT made
with the corrected rule.
