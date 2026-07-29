# Upstreaming decisions — boot firmware

This package holds the U-Boot/BootROM/TF-A boot-chain work for the ROCK 5B;
this file records its upstream submission disposition, decided 2026-07-29.
Cross-package ordering and coupling constraints live in the central
[upstreaming ledger](../docs/upstreaming-ledger.md); dated claims below must be
re-verified before acting on them.

## Decision list

| ID | Item | Artifact | Upstream target | Decision | Priority | Gates / prerequisites |
|----|------|----------|------------------|----------|----------|------------------------|
| BOOT-1 | Order u-boot.itb after u-boot.dtb in the Radxa rk35xx U-Boot patch dir (zero-byte control DTB race) | Local branch `agent/fix-radxa-u-boot-itb-dependency` @ `88f02f40a`, plus the controlled proof and the alternative one-line family enablement | armbian/build (GitHub PR #10196) | MERGED | P1 | — |
| BOOT-2 | Same one-line Makefile prerequisite fix on the branch Armbian actually builds | One-line Makefile change (`u-boot.itb: … u-boot.dtb $(U_BOOT_ITS) FORCE`), already carried inside the Armbian patch | radxa/u-boot (GitHub PR, or a backport request on existing PR #189) | SUBMIT-NOW | P2 | — |
| BOOT-3 | Report the published-image blast radius: 38 shipping Armbian images carry a zero-byte U-Boot FIT DTB | Two dated audits plus the reusable streaming checkers and 447 rows of catalog evidence | armbian/build (GitHub issue #8227 follow-up report / image-rebuild request) | SUBMIT-NOW | P2 | — |
| BOOT-4 | Armbian build-time gate: fail the U-Boot artifact when a required FIT FDT component is zero bytes | None written yet — recommendation recorded in the version comparison | armbian/build (GitHub PR adding an artifact assertion) | HOLD | P3 | BOOT-1 / PR #10196 resolved first, so the gate is not competing with the actual fix; port the checker's FDT-size assertion from an image-side script to a build-side artifact hook and prove it fires on a deliberately broken u-boot.itb |

## Rationale and evidence

### BOOT-1 — Order u-boot.itb after u-boot.dtb (zero-byte control DTB race)

Highest-severity item in this track: the missing Make prerequisite lets
`mkimage` embed a zero-byte `/incbin/("./u-boot.dtb")`, producing a
structurally valid FIT with an empty required U-Boot control DTB, and the FIT
hash is the correct hash of the empty payload so nothing downstream errors.
armbian/build PR #10196 was merged into main on 2026-07-17, twelve days before
this triage; the in-repo record was last refreshed 2026-07-20 and had not
caught it, so no review follow-up remains. Evidence is a controlled build
reproduction (a 3 s delay before COPY reproduced `Data Size: 0 Bytes`; adding
the prerequisite ordered COPY before MKIMAGE and produced the 12,752-byte
payload), plus 38 measured broken published images (BOOT-3). With Armbian
fixed at the build layer, BOOT-2's Radxa one-liner now benefits non-Armbian
downstreams rather than closing this project's own exposure.

- Evidence: [findings/2026-07-13-rock5b-u-boot-fit-dtb-race.md](../findings/2026-07-13-rock5b-u-boot-fit-dtb-race.md), [findings/evidence/2026-07-13-u-boot-fit-dtb-race/Makefile-controlled-delay-and-fix.patch](../findings/evidence/2026-07-13-u-boot-fit-dtb-race/Makefile-controlled-delay-and-fix.patch), [findings/evidence/2026-07-13-u-boot-fit-dtb-race/controlled-delay-prepatch.log](../findings/evidence/2026-07-13-u-boot-fit-dtb-race/controlled-delay-prepatch.log), [findings/evidence/2026-07-13-u-boot-fit-dtb-race/controlled-delay-postpatch.log](../findings/evidence/2026-07-13-u-boot-fit-dtb-race/controlled-delay-postpatch.log), [findings/evidence/2026-07-13-u-boot-fit-dtb-race/armbian-rockchip-rk3588-enable-itb-deps-extension.patch](../findings/evidence/2026-07-13-u-boot-fit-dtb-race/armbian-rockchip-rk3588-enable-itb-deps-extension.patch), [boot-firmware/docs/version-comparison.md](docs/version-comparison.md), [status.md](../status.md)
- Coupled with: BOOT-2, BOOT-3, BOOT-4

### BOOT-2 — Same one-line Makefile prerequisite fix on the branch Armbian actually builds

Fixing it at Radxa retires Armbian's carried patch entirely and covers every
downstream consumer, not just Armbian. The change is one line with a
controlled reproduction behind it and no configuration risk. Two honest
caveats: Radxa PR #189 (not authored by this project — no fork remote or
local branch exists for it) already carries the same producer/consumer edge
but targets `next-dev-v2026.01`, while Armbian's RK3588 family tracks
`next-dev-v2024.10` at `39cd993e5d`, so this unit may reduce to a comment on
#189 asking for the branch Armbian consumes; Radxa PR #188 is a different edge
(`make_fit_atf.py` reading `./u-boot`) and does not close this one. Mainline
U-Boot is not a target since it no longer uses the custom generator.
Rescoped now that armbian/build #10196 merged on 2026-07-17: this no longer
closes this project's own exposure, it covers every other Radxa U-Boot
downstream.

- Evidence: [findings/2026-07-13-rock5b-u-boot-fit-dtb-race.md](../findings/2026-07-13-rock5b-u-boot-fit-dtb-race.md), [findings/evidence/2026-07-13-u-boot-fit-dtb-race/Makefile-controlled-delay-and-fix.patch](../findings/evidence/2026-07-13-u-boot-fit-dtb-race/Makefile-controlled-delay-and-fix.patch), [boot-firmware/docs/version-comparison.md](docs/version-comparison.md)
- Coupled with: BOOT-1

### BOOT-3 — Report the published-image blast radius

This is the report-worthy half of BOOT-1: merging the dependency fix does not
repair already-published artifacts, and the audit names the exact filenames
and Armbian-published SHA-256 identities (9 ROCK 5B images, 4 each for CM5 IO
/ E24C / ROCK 2A / IMB3588 / Mekotronics R58 4x4 / NanoPC T6 LTS / Orange Pi 5
Plus, 1 Banana Pi M5 Pro). Evidence is direct measurement of the shipped FIT
(`dumpimage -l` on the streamed 4 MiB window at raw offset 8 MiB), exactly
what the issue thread needs, and the checkers let Armbian reproduce it
without downloading full images. The report should state the recorded
boundary honestly: CLEAN proves only the absence of the zero-DTB signature,
catalog aliases are mutable so the result is a 2026-07-20 snapshot, and 95
rows are classified from board-config inspection rather than the FIT test.

- Evidence: [findings/2026-07-20-armbian-radxa-image-fit-audit.md](../findings/2026-07-20-armbian-radxa-image-fit-audit.md), [findings/2026-07-20-armbian-non-radxa-radxa-uboot-audit.md](../findings/2026-07-20-armbian-non-radxa-radxa-uboot-audit.md), [findings/evidence/2026-07-20-armbian-radxa-image-fit-audit/README.md](../findings/evidence/2026-07-20-armbian-radxa-image-fit-audit/README.md), [boot-firmware/scripts/audit-armbian-rockchip-fit.sh](scripts/audit-armbian-rockchip-fit.sh), [boot-firmware/scripts/audit-armbian-radxa-catalog.sh](scripts/audit-armbian-radxa-catalog.sh)
- Coupled with: BOOT-1

### BOOT-4 — Armbian build-time gate for zero-byte FIT FDT components

The finding establishes why a defence-in-depth gate is warranted: `mkimage`
accepted the zero-length `/incbin/` and returned success, the FIT hash
validated the empty payload, and neither `cp` nor `mkimage` produced a
non-zero exit, so nothing in the build could notice. But no implementation is
held here: the audit script consumes a published `.img.xz`, not a build tree,
and a build gate would touch Armbian's artifact pipeline. Submitting a design
note instead of code would not be accepted as a PR, so this waits until
someone writes and tests it.

- Evidence: [boot-firmware/docs/version-comparison.md](docs/version-comparison.md), [findings/2026-07-13-rock5b-u-boot-fit-dtb-race.md](../findings/2026-07-13-rock5b-u-boot-fit-dtb-race.md), [boot-firmware/scripts/audit-armbian-rockchip-fit.sh](scripts/audit-armbian-rockchip-fit.sh)
- Coupled with: BOOT-1
