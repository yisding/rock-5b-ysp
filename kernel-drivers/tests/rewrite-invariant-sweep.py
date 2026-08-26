#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: GPL-2.0-only
"""Device-free model for the W4 debugfs invariant sweep.

This is the executable specification for the board sweep described in the
bug-resistance plan W4: a single command that samples the owner graph and
reports one of three verdicts per subsystem -- clean, violated, or
skipped-inconclusive -- using trylock discipline only, never holding a
run/coordinator lock while dumping.

The real sweep will live in the kernel (debugfs). This Python model mirrors
its logic on mock data so the three-verdict semantics and counter checks can
be reviewed and tested without a board. It is intentionally not a second
implementation to drift: the kernel sweep should be validated against this
model's self-tests.

Usage: python3 kernel-drivers/tests/rewrite-invariant-sweep.py
Exit 0 on self-test pass, 1 on failure.
"""

from __future__ import annotations

import dataclasses
from enum import Enum


class Verdict(Enum):
    CLEAN = "clean"
    VIOLATED = "violated"
    SKIPPED = "skipped-inconclusive"


@dataclasses.dataclass
class MockSubsystem:
    name: str
    # Lock states: True = trylock succeeded, False = contended
    lock_acquired: bool
    # Owner-graph state (only meaningful when lock_acquired)
    active_slot_state: str | None  # e.g. "RUNNING", "PUBLISHED", "IDLE", None
    deadline_armed: bool | None
    tombstone_refs_ok: bool | None
    counters_balanced: bool | None  # live == queued + active + completed_unpolled
    maps_vs_imports_ok: bool | None


def sweep_subsystem(sub: MockSubsystem) -> Verdict:
    """Trylock discipline: contended -> skipped, else check invariants."""
    if not sub.lock_acquired:
        return Verdict.SKIPPED
    # Active slot must be RUNNING/PUBLISHED with armed deadline, or IDLE.
    # Any other combination is violated; None fields when lock was acquired
    # should not happen but count as violated for fail-closed behavior.
    if sub.active_slot_state not in (None, "RUNNING", "PUBLISHED", "IDLE"):
        return Verdict.VIOLATED
    if sub.active_slot_state in ("RUNNING", "PUBLISHED"):
        if sub.deadline_armed is not True:
            return Verdict.VIOLATED
    if sub.tombstone_refs_ok is False:
        return Verdict.VIOLATED
    if sub.counters_balanced is False:
        return Verdict.VIOLATED
    if sub.maps_vs_imports_ok is False:
        return Verdict.VIOLATED
    # None checks that slipped through (missing data while lock held) -> violated
    if None in (sub.tombstone_refs_ok, sub.counters_balanced, sub.maps_vs_imports_ok):
        return Verdict.VIOLATED
    return Verdict.CLEAN


def sweep_all(subsystems: list[MockSubsystem]) -> dict[str, Verdict]:
    return {s.name: sweep_subsystem(s) for s in subsystems}


def self_test() -> int:
    cases = [
        # Clean: all invariants hold, lock acquired
        (MockSubsystem("mpp", True, "RUNNING", True, True, True, True), Verdict.CLEAN),
        (MockSubsystem("rga", True, "IDLE", False, True, True, True), Verdict.CLEAN),
        # Violated: deadline not armed while RUNNING
        (MockSubsystem("mpp", True, "RUNNING", False, True, True, True), Verdict.VIOLATED),
        # Violated: tombstone refs broken
        (MockSubsystem("rga", True, "PUBLISHED", True, False, True, True), Verdict.VIOLATED),
        # Violated: counter imbalance
        (MockSubsystem("mpp", True, "IDLE", False, True, False, True), Verdict.VIOLATED),
        # Violated: maps vs imports mismatch
        (MockSubsystem("rga", True, "IDLE", False, True, True, False), Verdict.VIOLATED),
        # Skipped: lock contended (wedged RETIRING holds run lock) -> not violated
        (MockSubsystem("mpp", False, "RUNNING", True, True, True, True), Verdict.SKIPPED),
        (MockSubsystem("rga", False, None, None, None, None, None), Verdict.SKIPPED),
        # Skipped takes precedence over violated fields when contended
        (MockSubsystem("mpp", False, "RUNNING", False, False, False, False), Verdict.SKIPPED),
    ]
    failures = 0
    for sub, expected in cases:
        got = sweep_subsystem(sub)
        if got != expected:
            print(f"FAIL: {sub} -> {got}, expected {expected}")
            failures += 1
    # Aggregate sweep: accept clean-or-skipped, fail on violated (matches plan)
    agg = sweep_all([
        MockSubsystem("mpp", True, "RUNNING", True, True, True, True),
        MockSubsystem("rga", False, None, None, None, None, None),
    ])
    if any(v == Verdict.VIOLATED for v in agg.values()):
        print("FAIL: aggregate should be clean-or-skipped")
        failures += 1
    agg2 = sweep_all([
        MockSubsystem("mpp", True, "RUNNING", False, True, True, True),
        MockSubsystem("rga", True, "IDLE", False, True, True, True),
    ])
    if not any(v == Verdict.VIOLATED for v in agg2.values()):
        print("FAIL: aggregate should have detected violated")
        failures += 1
    if failures:
        print(f"FAIL: {failures} self-test failures")
        return 1
    print(f"PASS: all {len(cases)+2} sweep cases (clean/violated/skipped discipline verified)")
    return 0


if __name__ == "__main__":
    raise SystemExit(self_test())
