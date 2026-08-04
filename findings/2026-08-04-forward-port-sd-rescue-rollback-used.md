# Forward-port kernel rollback has been performed through an SD rescue boot

> Scope: forward-port kernel delivery and recovery; coverage rows C03 and C19
> Source: ROCK 5B operator report in the 2026-08-04 repository maintenance conversation
> Date: 2026-08-04
> Trust: USER-REPORTED / PARTIAL

## Result

The board operator reports that forward-port kernel rollbacks have been carried
out by booting from an SD card and using the exact `kernel-revert.sh` commands
documented in [`install.md` §3](../install.md#3-prepare-recovery-and-capture-the-old-baseline)
from that rescue environment. Those commands worked. This establishes that the
documented external rescue path and helper are usable in practice, and corrects
the repository's stronger statements that rollback had never been demonstrated
or had no evidence at all. The operator also considers the same documented
mechanism usable by a reader.

This is operator-level recovery evidence, not a retained evidence bundle. The
exact SD image, failed and restored kernel identities, mount target,
post-recovery boot fingerprint, and logs were not supplied with the report.

## Boundary

This does not independently replay the procedure with a second reader or
validate helper modes outside the documented rescue flow. It also does not
establish automatic boot fallback, clean migration, or stale-package cleanup.
Those separate transactions remain open; SD rescue rollback itself is not an
open release gate.

## Verification gate

For a stronger independently auditable record, capture a future SD-card
recovery with the pre-failure and restored `uname -r`, exact image/DTB package
versions, rescue image identity, mount and revert commands, selected `/boot`
entry, post-reboot identity, and a functional smoke test. This is evidence
hardening, not a prerequisite for using the documented recovery path.
