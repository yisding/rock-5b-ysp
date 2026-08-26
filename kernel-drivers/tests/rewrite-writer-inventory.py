#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: GPL-2.0-only
"""Writer-inventory gate for protected rewrite-driver state.

Implements the inventory-diff half of workstream W2 in
kernel-drivers/docs/rewrite-bug-resistance-plan.md: every production mention
of the active/timeout/IRQ slot references (reads included), every terminal
state write (RGA scoped to execution-lifecycle function names so broad
left-hand sides stay low-noise), generation-cookie writes including the
activation_generation_seq allocator and AV1 AFBC cookies, RKVDEC
dispatch-lease writes, reset-control API calls, and bare or prefixed
publish_and_start call sites is inventoried from production text (KUnit
regions stripped with the same marker discipline as the ownership audit).
Doorbell MMIO stays guarded by the ownership audit's start-doorbell-write
allowlist rather than a duplicate rule here. A signal that appears at the
current tips but is absent from the checked baseline fails the run, so a
future structural twin becomes a gate failure instead of a review finding.

The baseline IS the allowlist: new signals fail, resolved signals are
allowed, exactly like rewrite-ownership-source-audit. Scoping signals to a
function's owning module (the plan's "outside the owning module" refinement)
lands with the Coccinelle lane once host tooling exists; this file keeps one
inventory mechanism so there is never a second allowlist to drift.

Parsing primitives are imported from rewrite-ownership-source-audit.py so
comment stripping, KUnit-region markers, and function attribution can never
disagree between the two gates.
"""

from __future__ import annotations

import argparse
import collections
import contextlib
import io
import importlib.util
import pathlib
import re
import shutil
import sys
import tempfile

TEST_DIR = pathlib.Path(__file__).resolve().parent
BASELINE_PATH = TEST_DIR / "rewrite-writer-inventory-baseline.tsv"
OWNERSHIP_AUDIT = TEST_DIR / "rewrite-ownership-source-audit.py"


def _load_ownership_audit():
    spec = importlib.util.spec_from_file_location(
        "rewrite_ownership_source_audit", OWNERSHIP_AUDIT
    )
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot import {OWNERSHIP_AUDIT}")
    module = importlib.util.module_from_spec(spec)
    # Register before exec_module: the audit's frozen dataclasses resolve
    # their fields through sys.modules during class creation.
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


own = _load_ownership_audit()

REF_TOUCH = r"\b(?:{refs})\b"
GENERATION_WRITE = r"(?:->|\.)\s*\w*generation\w*\s*(?:=[^=]|\+\+|--)"

# Each rule is (source, category, statement regex, function-name filter).
# A None filter applies everywhere; otherwise only statements inside
# functions whose name matches the filter are inventoried, which lets broad
# LHS patterns such as "->state =" stay low-noise while still catching
# WRITE_ONCE and alias-variable right-hand sides inside the owning region.
RULES = (
    (
        own.MPP_SOURCE,
        "mpp-reset-control-call",
        r"\breset_control_(?:assert|deassert|reset|acquire|release|rearm|status)"
        r"[a-z_]*\s*\(",
        None,
    ),
    (
        own.MPP_SOURCE,
        "mpp-execution-ref-touch",
        REF_TOUCH.format(refs="active_ref|timeout_ref"),
        None,
    ),
    (
        own.MPP_SOURCE,
        "mpp-activation-state-write",
        r"->\s*(?:slot_state|resource_state)\s*=[^=]",
        None,
    ),
    (
        own.MPP_SOURCE,
        "mpp-dispatch-lease-write",
        r"\brkvdec_dispatch_owner\s*=[^=]",
        None,
    ),
    (own.MPP_SOURCE, "mpp-generation-write", GENERATION_WRITE, None),
    (own.MPP_SOURCE, "mpp-publish-start-call", r"\w*publish_and_start\s*\(", None),
    (
        own.RGA_SOURCE,
        "rga-execution-ref-touch",
        REF_TOUCH.format(refs="active_ref|timeout_ref|irq_ref"),
        None,
    ),
    (
        own.RGA_SOURCE,
        "rga-exec-state-write",
        # Direct enum assignment, alias-variable assignment, and the
        # WRITE_ONCE comma form are all covered by scoping this broad
        # left-hand-side match to execution-lifecycle functions.
        r"->\s*state\s*(?:=[^=]|,\s*RK_RGA_TASK_EXEC_)",
        r"exec|reclaim|retire|install|take_active|finish|recover|advance",
    ),
    (own.RGA_SOURCE, "rga-generation-write", GENERATION_WRITE, None),
    (own.RGA_SOURCE, "rga-publish-start-call", r"\w*publish_and_start\s*\(", None),
)

SELF_TEST_FUNCTION = """
static void rk_writer_inventory_self_test_violation(
\tstruct rk_mpp_session *session)
{
\tsession->rkvdec_dispatch_owner = NULL;
}
"""


def inventory_tree(kernel_tree: pathlib.Path) -> list:
    occurrences: dict = collections.Counter()
    signals = []
    for relative, category, pattern, function_filter in RULES:
        source = kernel_tree / relative
        if not source.is_file():
            raise ValueError(f"missing rewrite source: {source}")
        functions = own.parse_functions(
            source, own.KUNIT_MARKERS[relative]
        )
        regex = re.compile(pattern)
        name_regex = re.compile(function_filter) if function_filter else None
        for function in functions:
            if name_regex is not None and not name_regex.search(function.name):
                continue
            for _line, statement in function.statements:
                if not regex.search(statement):
                    continue
                text = own.normalize(statement)
                identity = (category, relative, function.name, text)
                occurrences[identity] += 1
                signals.append(
                    own.Signal(
                        category=category,
                        source=relative,
                        function=function.name,
                        text=text,
                        ordinal=occurrences[identity],
                        line=_line,
                    )
                )
    return sorted(signals)


def compare_with_baseline(kernel_tree: pathlib.Path, baseline: pathlib.Path) -> int:
    if not baseline.is_file():
        raise ValueError(
            f"baseline not found: {baseline} "
            "(generate it with --update-baseline)"
        )
    expected, heads, _categories = own.read_baseline(baseline)
    current_head = own.git_head(kernel_tree)
    if heads and current_head not in heads:
        print(
            f"FAIL baseline source-head pins do not include the current "
            f"{kernel_tree} HEAD {current_head}; regenerate with "
            f"--update-baseline after reviewing the diff.",
            file=sys.stderr,
        )
        return 1
    found = {signal.key for signal in inventory_tree(kernel_tree)}
    new = sorted(found - expected)
    resolved = sorted(expected - found)
    for key in new:
        print(
            f"FAIL new protected-state writer: {key[0]} {key[1]} "
            f"{key[2]} #{key[4]}: {key[3]}",
            file=sys.stderr,
        )
    for key in resolved:
        print(f"note resolved signal removed: {key[0]} {key[1]} {key[2]}")
    if new:
        print(
            f"{len(new)} new protected-state writer(s) in {kernel_tree}; "
            f"update the baseline only after reviewing them as owning-module "
            f"members.",
            file=sys.stderr,
        )
        return 1
    print(
        f"PASS writer inventory matches baseline in {kernel_tree} "
        f"({len(found)} signals across {len(RULES)} categories)"
    )
    return 0


def baseline_header(trees: list[pathlib.Path]) -> list[str]:
    lines = [
        "# Rewrite protected-state writer inventory;"
        " new signals fail, resolved signals are allowed."
    ]
    for head in sorted({own.git_head(tree) for tree in trees}):
        lines.append(f"# source-head\t{head}")
    lines.append("# category\tsource\tfunction\tordinal\tnormalized source signal")
    return lines


def write_baseline(trees: list[pathlib.Path], path: pathlib.Path) -> None:
    merged: dict = {}
    for tree in trees:
        for signal in inventory_tree(tree):
            merged[signal.key] = signal
    lines = baseline_header(trees)
    lines.extend(own.encode(merged[key]) for key in sorted(merged))
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"wrote baseline {path} ({len(merged)} signals)")


def self_test(trees: list[pathlib.Path]) -> int:
    """Prove the gate detects an injected twin without any kernel build.

    The baseline is generated from a pristine scratch mirror, not the real
    tree: both sides then share the same non-repo head ("unknown"), so the
    source-head pin guard passes and the signal comparison itself is what
    decides the injected case. The failing run must name the expected
    category and function in its diff output; a bare nonzero exit would also
    fire for unrelated reasons and prove nothing.
    """

    status = 0
    expected_category = "mpp-dispatch-lease-write"
    expected_function = "rk_writer_inventory_self_test_violation"
    # Scratch space belongs under ../tmp beside this repository (the same
    # default REWRITE_BUILD_TMP_ROOT uses), never /tmp.
    scratch_parent = TEST_DIR.parent.parent.parent / "tmp"
    scratch_parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix="writer-inventory-selftest.", dir=scratch_parent
    ) as tmp:
        scratch = pathlib.Path(tmp)
        pristine = scratch / "pristine"
        injected = scratch / "injected"

        def mirror(target_root: pathlib.Path) -> None:
            target_root.mkdir(parents=True, exist_ok=True)
            for relative in {rule_source for rule_source, _c, _p, _f in RULES}:
                path = target_root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(trees[0] / relative, path)

        mirror(pristine)
        baseline = scratch / "baseline.tsv"
        write_baseline([pristine], baseline)

        pristine_err = io.StringIO()
        with contextlib.redirect_stdout(io.StringIO()), \
                contextlib.redirect_stderr(pristine_err):
            pristine_result = compare_with_baseline(pristine, baseline)
        if pristine_result != 0:
            print(
                "self-test failed: pristine mirror drifted from its own "
                f"baseline:\n{pristine_err.getvalue()}",
                file=sys.stderr,
            )
            return 1

        mirror(injected)
        violation_source = injected / own.MPP_SOURCE
        with violation_source.open("a", encoding="utf-8") as handle:
            handle.write(SELF_TEST_FUNCTION)

        injected_out = io.StringIO()
        injected_err = io.StringIO()
        with contextlib.redirect_stdout(injected_out), \
                contextlib.redirect_stderr(injected_err):
            injected_result = compare_with_baseline(injected, baseline)
        combined = injected_out.getvalue() + injected_err.getvalue()
        detected = (
            injected_result != 0
            and expected_category in combined
            and expected_function in combined
        )
        if not detected:
            print(
                "self-test failed: injected violation was not reported as "
                f"{expected_category} in {expected_function}; gate output:",
                file=sys.stderr,
            )
            print(combined, file=sys.stderr, end="")
            status = 1
        else:
            print(
                "PASS self-test detected injected "
                f"{expected_category} in {expected_function}"
            )
    return status


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("kernel_tree", nargs="+", type=pathlib.Path)
    parser.add_argument("--baseline", type=pathlib.Path, default=BASELINE_PATH)
    parser.add_argument("--emit-baseline", action="store_true")
    parser.add_argument("--update-baseline", action="store_true")
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="inject a synthetic dispatch-lease writer and require detection",
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    trees = args.kernel_tree
    for tree in trees:
        if not tree.is_dir():
            raise ValueError(f"not a kernel tree: {tree}")
    if args.self_test:
        if len(trees) != 1:
            raise ValueError("--self-test takes exactly one kernel tree")
        return self_test(trees)
    if args.emit_baseline:
        for signal in inventory_tree(trees[0]):
            print(own.encode(signal))
        return 0
    if args.update_baseline:
        write_baseline(trees, args.baseline)
        return 0
    status = 0
    for tree in trees:
        status |= compare_with_baseline(tree, args.baseline)
    return status


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (ValueError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(2)
