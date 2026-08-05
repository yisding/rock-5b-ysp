#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: GPL-2.0-only
"""Reject new fixture-debt signals in the rewrite drivers' KUnit regions."""

from __future__ import annotations

import argparse
import collections
import dataclasses
import pathlib
import re
import sys
from collections.abc import Iterable


SOURCES = (
    (
        "drivers/video/rockchip/mpp-rewrite/mpp_rewrite.c",
        "CONFIG_ROCKCHIP_MPP_REWRITE_KUNIT_TEST",
    ),
    (
        "drivers/video/rockchip/rga-rewrite/rga_rewrite.c",
        "CONFIG_ROCKCHIP_RGA_REWRITE_KUNIT_TEST",
    ),
)

DETECTORS = (
    (
        "production-singleton-access",
        re.compile(r"\b(?:rk_mpp_srv|rk_rga)\b"),
    ),
    (
        "fd-acquisition",
        re.compile(
            r"\b(?:get_unused_fd_flags|fd_install|dma_buf_fd|"
            r"sync_file_create|anon_inode_getfd|"
            r"rk_rga_fence_create_fd)\s*\("
        ),
    ),
    (
        "raw-allocation",
        re.compile(
            r"(?<!kunit_)\b(?:kmalloc|kzalloc|kcalloc|kmalloc_array|"
            r"kvcalloc|kvmalloc|kvzalloc|vmalloc|vzalloc|kmemdup|"
            r"kzalloc_obj)\s*\("
        ),
    ),
    (
        "stack-async-owner",
        re.compile(
            r"\b(?:INIT_WORK_ONSTACK|INIT_DELAYED_WORK_ONSTACK)\s*\(|"
            r"\b(?:INIT_WORK|INIT_DELAYED_WORK|timer_setup|hrtimer_init)\s*"
            r"\(\s*&[A-Za-z_]\w*\."
        ),
    ),
    (
        "manual-list-link",
        re.compile(
            r"\b(?:list_add|list_add_tail|list_move|list_move_tail|"
            r"hlist_add_head|hlist_add_tail)\s*\("
        ),
    ),
)

ACQUISITION_RE = re.compile(
    r"\b(?:get_unused_fd_flags|fd_install|dma_buf_fd|sync_file_create|"
    r"anon_inode_getfd|rk_rga_fence_create_fd)\s*\(|"
    r"(?<!kunit_)\b(?:kmalloc|kzalloc|kcalloc|kmalloc_array|kvcalloc|"
    r"kvmalloc|kvzalloc|vmalloc|vzalloc|kmemdup|kzalloc_obj)\s*\("
)
FATAL_RE = re.compile(r"\b(?:KUNIT_ASSERT\w*|KUNIT_FAIL)\s*\(")
ACTION_RE = re.compile(r"\bkunit_add_action_or_reset\s*\(")
FUNCTION_RE = re.compile(
    r"\b([A-Za-z_]\w*)\s*\([^;{}]*\)\s*(?:__\w+\s*)?\{\s*$",
    re.DOTALL,
)


@dataclasses.dataclass(frozen=True, order=True)
class Signal:
    category: str
    source: str
    function: str
    text: str
    ordinal: int
    line: int = dataclasses.field(compare=False)

    @property
    def key(self) -> tuple[str, str, str, str, int]:
        return (
            self.category,
            self.source,
            self.function,
            self.text,
            self.ordinal,
        )


def normalize_line(line: str) -> str:
    return " ".join(line.strip().split())


def kunit_regions(
    source: pathlib.Path, config_symbol: str
) -> list[tuple[list[str], int]]:
    lines = source.read_text(encoding="utf-8").splitlines()
    marker = f"#if IS_ENABLED({config_symbol})"
    starts = [index for index, line in enumerate(lines) if line.strip() == marker]
    if not starts:
        raise ValueError(f"{source}: missing KUnit region marker {marker}")

    regions: list[tuple[list[str], int]] = []
    for start in starts:
        depth = 0
        end: int | None = None
        for index in range(start, len(lines)):
            directive = lines[index].lstrip()
            if re.match(r"#\s*(?:if|ifdef|ifndef)\b", directive):
                depth += 1
            elif re.match(r"#\s*endif\b", directive):
                depth -= 1
                if depth == 0:
                    end = index
                    break
        if end is None:
            raise ValueError(
                f"{source}: unterminated KUnit region at line {start + 1}"
            )
        regions.append((lines[start : end + 1], start + 1))

    if not any(
        "kunit_test_suite(" in line
        for region, _first_line in regions
        for line in region
    ):
        raise ValueError(f"{source}: missing kunit_test_suite() in KUnit regions")
    return regions


def function_names(lines: list[str]) -> list[str]:
    names: list[str] = []
    depth = 0
    current = "<kunit-region>"
    signature: list[str] = []

    for line in lines:
        if depth == 0:
            stripped = line.strip()
            if stripped and not stripped.startswith("#"):
                signature.append(stripped)
                candidate = " ".join(signature)
                if "{" in stripped:
                    match = FUNCTION_RE.search(candidate)
                    current = match.group(1) if match else "<kunit-region>"
                    signature.clear()
                elif ";" in stripped or len(signature) > 8:
                    signature.clear()

        names.append(current)
        depth += line.count("{") - line.count("}")
        if depth <= 0:
            depth = 0
            if "}" in line:
                current = "<kunit-region>"
    return names


def audit_source(
    kernel_tree: pathlib.Path, relative: str, config_symbol: str
) -> list[Signal]:
    source = kernel_tree / relative
    if not source.is_file():
        raise ValueError(f"missing rewrite source: {source}")
    found: list[tuple[str, str, str, int]] = []
    for lines, first_line in kunit_regions(source, config_symbol):
        functions = function_names(lines)
        pending_acquisition: dict[str, tuple[int, str] | None] = {}

        for offset, (line, function) in enumerate(
            zip(lines, functions, strict=True)
        ):
            text = normalize_line(line)
            line_number = first_line + offset
            if not text:
                continue

            for category, pattern in DETECTORS:
                if pattern.search(line):
                    found.append((category, function, text, line_number))

            if ACQUISITION_RE.search(line):
                pending_acquisition[function] = (line_number, text)
            if ACTION_RE.search(line):
                pending_acquisition[function] = None
            if FATAL_RE.search(line) and pending_acquisition.get(function):
                _acquired_line, acquired_text = pending_acquisition[function]  # type: ignore[misc]
                found.append(
                    (
                        "fatal-before-cleanup-action",
                        function,
                        f"acquire:{acquired_text} -> fatal:{text}",
                        line_number,
                    )
                )

    occurrences: collections.Counter[tuple[str, str, str]] = collections.Counter()
    signals: list[Signal] = []
    for category, function, text, line_number in found:
        identity = (category, function, text)
        occurrences[identity] += 1
        signals.append(
            Signal(
                category=category,
                source=relative,
                function=function,
                text=text,
                ordinal=occurrences[identity],
                line=line_number,
            )
        )
    return signals


def audit_tree(kernel_tree: pathlib.Path) -> list[Signal]:
    signals: list[Signal] = []
    for relative, config_symbol in SOURCES:
        signals.extend(audit_source(kernel_tree, relative, config_symbol))
    return sorted(signals)


def encode_signal(signal: Signal) -> str:
    return "\t".join(
        (
            signal.category,
            signal.source,
            signal.function,
            str(signal.ordinal),
            signal.text,
        )
    )


def read_baseline(path: pathlib.Path) -> set[tuple[str, str, str, str, int]]:
    baseline: set[tuple[str, str, str, str, int]] = set()
    for line_number, raw in enumerate(
        path.read_text(encoding="utf-8").splitlines(), start=1
    ):
        if not raw or raw.startswith("#"):
            continue
        fields = raw.split("\t", 4)
        if len(fields) != 5:
            raise ValueError(f"{path}:{line_number}: expected five TSV fields")
        category, source, function, ordinal_text, text = fields
        try:
            ordinal = int(ordinal_text)
        except ValueError as error:
            raise ValueError(
                f"{path}:{line_number}: invalid ordinal {ordinal_text!r}"
            ) from error
        baseline.add((category, source, function, text, ordinal))
    return baseline


def baseline_lines(signals: Iterable[Signal]) -> Iterable[str]:
    yield "# category\tsource\tfunction\tordinal\tnormalized source signal"
    yield from (encode_signal(signal) for signal in signals)


def parse_args(argv: list[str]) -> argparse.Namespace:
    default_baseline = pathlib.Path(__file__).with_name(
        "rewrite-kunit-source-audit-baseline.tsv"
    )
    parser = argparse.ArgumentParser(
        description=(
            "Audit rewrite KUnit regions against the checked fixture-debt baseline"
        )
    )
    parser.add_argument(
        "kernel_tree",
        nargs="+",
        type=pathlib.Path,
        help="kernel source tree containing both rewrite drivers",
    )
    parser.add_argument(
        "--baseline",
        type=pathlib.Path,
        default=default_baseline,
        help=f"known-debt TSV (default: {default_baseline})",
    )
    parser.add_argument(
        "--emit-baseline",
        action="store_true",
        help="print the first tree's detected signals as baseline TSV and exit",
    )
    parser.add_argument(
        "--update-baseline",
        action="store_true",
        help="replace --baseline with the first tree's detected signals and exit",
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    try:
        trees = [(tree.resolve(), audit_tree(tree.resolve())) for tree in args.kernel_tree]
        encoded_baseline = "\n".join(baseline_lines(trees[0][1])) + "\n"
        if args.emit_baseline:
            print(encoded_baseline, end="")
            return 0
        if args.update_baseline:
            args.baseline.write_text(encoded_baseline, encoding="utf-8")
            print(
                f"updated {args.baseline} with {len(trees[0][1])} "
                "known-debt signals"
            )
            return 0
        baseline = read_baseline(args.baseline)
    except (OSError, ValueError) as error:
        print(f"rewrite KUnit source audit: {error}", file=sys.stderr)
        return 2

    failed = False
    reference_keys = {signal.key for signal in trees[0][1]}
    for tree, signals in trees:
        keys = {signal.key for signal in signals}
        new = [signal for signal in signals if signal.key not in baseline]
        resolved = baseline - keys
        print(
            f"{tree}: {len(signals)} signals, {len(new)} new, "
            f"{len(resolved)} baseline entries absent"
        )
        for signal in new:
            failed = True
            print(
                f"NEW\t{signal.category}\t{signal.source}:{signal.line}\t"
                f"{signal.function}\t{signal.text}",
                file=sys.stderr,
            )
        if keys != reference_keys:
            failed = True
            print(
                f"{tree}: rewrite KUnit audit signals differ from "
                f"{trees[0][0]}",
                file=sys.stderr,
            )

    if failed:
        print("rewrite KUnit source audit failed", file=sys.stderr)
        return 1
    print("rewrite KUnit source audit passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
