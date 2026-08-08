#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: GPL-2.0-only
"""Inventory and guard failure-prone rewrite-driver ownership seams."""

from __future__ import annotations

import argparse
import collections
import dataclasses
import pathlib
import re
import subprocess
import sys
from collections.abc import Iterable


MPP_SOURCE = "drivers/video/rockchip/mpp-rewrite/mpp_rewrite.c"
RGA_SOURCE = "drivers/video/rockchip/rga-rewrite/rga_rewrite.c"
SOURCES = (MPP_SOURCE, RGA_SOURCE)

KUNIT_MARKERS = {
    MPP_SOURCE: "CONFIG_ROCKCHIP_MPP_REWRITE_KUNIT_TEST",
    RGA_SOURCE: "CONFIG_ROCKCHIP_RGA_REWRITE_KUNIT_TEST",
}

FUNCTION_RE = re.compile(
    r"\b([A-Za-z_]\w*)\s*\([^;{}]*\)\s*(?:__\w+(?:\([^)]*\))?\s*)*\{\s*$",
    re.DOTALL,
)
CONTROL_WORDS = {"if", "for", "while", "switch"}

POINTER_FIELD_TARGET = (
    r"(?:\b[A-Za-z_]\w*(?:\s*\[[^\]]+\])?\s*->|"
    r"\(\s*\*\s*[A-Za-z_]\w*\s*\)\s*\.)"
)
FIELD_TARGET = (
    rf"(?:{POINTER_FIELD_TARGET}|"
    r"\b[A-Za-z_]\w*(?:\s*\[[^\]]+\])?\s*\.)"
)
FIELD_MUTATION = r"(?:\+\+|--|[+\-*/%|&^]?=(?!=))"


def field_write_re(
    fields: str,
    publishers: str = "WRITE_ONCE",
    target: str = FIELD_TARGET,
) -> re.Pattern[str]:
    """Match direct and first-argument publisher writes to named fields."""

    return re.compile(
        rf"(?:{target}(?:{fields})\s*{FIELD_MUTATION}|"
        rf"\b(?:{publishers})\s*\(\s*&?[^,]*\b(?:{fields})\b)"
    )

RESET_CALL_RE = re.compile(
    r"\breset_control_(?:(?:bulk_)?(?:assert|deassert|reset)|rearm)\s*\("
)
ACTIVE_SLOT_WRITE_RE = re.compile(
    r"(?:\b[A-Za-z_]\w*(?:\s*\[[^\]]+\])?\s*(?:->|\.)\s*"
    r"(?:active_job|active_generation)\s*"
    r"(?:\+\+|--|[+\-*/]?=(?!=))|"
    r"\bWRITE_ONCE\s*\([^,]*\bactive_job\b\s*,)"
)
ACTIVE_SLOT_ACCESS_RE = re.compile(r"\b(?:active_job|active_generation)\b")
DISPATCH_LEASE_WRITE_RE = re.compile(
    r"\b(?:[A-Za-z_]\w*->)?(?:rkvdec_session_dispatch|"
    r"rkvdec_dispatch_active)\s*=(?!=)"
)
DISPATCH_LEASE_ACCESS_RE = re.compile(
    r"\b(?:rkvdec_session_dispatch|rkvdec_dispatch_active)\b"
)
POWER_FIELD_RE = re.compile(
    r"\b(?:rkvdec_ccu_powered_cores|rkvdec_ccu_powered_core_count|"
    r"rkvdec_ccu_powered)\b"
)
MPP_POWER_TRANSITION_RE = re.compile(r"\brk_mpp_hw_power_(?:on|off)\s*\(")
MPP_POWER_BACKEND_RE = re.compile(
    r"\b(?:pm_runtime_(?:resume_and_get|put_sync_suspend|put_autosuspend|"
    r"mark_last_busy)|clk_bulk_(?:prepare_enable|disable_unprepare))\s*\("
)
MPP_POWER_COUNT_WRITE_RE = re.compile(
    r"\b(?:atomic_inc|atomic_dec_if_positive|atomic_set)\s*\(\s*&?\s*"
    r"[A-Za-z_]\w*->power_count\b"
)
MPP_WATCHDOG_ARM_RE = re.compile(r"\brk_mpp_hw_schedule_timeout\s*\(")
RGA_WATCHDOG_ARM_RE = re.compile(r"\brk_rga_hw_schedule_timeout\s*\(")
MPP_IOMMU_RE = re.compile(
    r"\b(?:rk_mpp_hw_refresh_iommu|rk_mpp_dma_group_isolate)\s*\("
)
MPP_IOMMU_BACKEND_RE = re.compile(
    r"\b(?:vsi_iommu_refresh|iommu_flush_iotlb_all|iommu_attach_group)\s*\("
)
MPP_JOB_LIFECYCLE_WRITE_RE = field_write_re(r"result|state")
MPP_IRQ_SNAPSHOT_WRITE_RE = field_write_re(
    r"irq_status|av1_afbc_armed_generation|av1_afbc_status_generation|"
    r"av1_start_ns|av1_afbc_status_ns|av1_vcd_irq_ns|rkvenc_slice_done|"
    r"rkvenc_slice_overflow"
)
MPP_FAULT_SNAPSHOT_WRITE_RE = field_write_re(
    r"iommu_fault_pending|iommu_fault_generation"
)
MPP_TERMINAL_STATE_WRITE_RE = field_write_re(
    r"canceled|online|recovery_failed|terminally_stopped|"
    r"terminal_power_drained"
)
MPP_WATCHDOG_SNAPSHOT_WRITE_RE = field_write_re(
    r"timeout_job|timeout_generation|timeout_deadline_generation|"
    r"timeout_deadline"
)
MPP_ACTIVATION_TIMING_WRITE_RE = field_write_re(r"hw_start_ns|hw_elapsed_ns")
MPP_OUTCOME_PUBLISH_RE = re.compile(
    r"\brk_mpp_job_publish_outcome(?:_locked)?\s*\("
)
MPP_TERMINAL_RE = re.compile(
    r"\b(?:rk_mpp_job_complete|rk_mpp_hw_stop_active|"
    r"rk_mpp_hw_recover_active|rk_mpp_hw_abort_active(?:_recovery_locked)?)\s*\("
)
RGA_TASK_ADVANCE_RE = re.compile(
    r"\b[A-Za-z_]\w*->current_task\s*(?:\+\+|--|[+\-*/]?=(?!=))"
)
RGA_EXEC_MAP_OWNER_RE = re.compile(
    r"\b(?:__rk_rga_job_release_execution_mappings|"
    r"rk_rga_job_(?:release_execution_mappings_powered|"
    r"discard_execution_mappings))\s*\("
)
RGA_MAP_RELEASE_PRIMITIVE_RE = re.compile(
    r"\b(?:rk_rga_unmap_userptr_sgt|dma_buf_unmap_attachment(?:_unlocked)?|"
    r"dma_buf_detach|rk_rga_job_(?:clear|release)_rga2_mmu)\s*\("
)
RGA_COMMAND_RELEASE_RE = re.compile(
    r"\brk_rga_job_free_cmd\s*\(|"
    r"\bdma_free_coherent\s*\([^;]*\bcmd_(?:dev|size|vaddr|dma)\b"
)
RGA_IRQ_SNAPSHOT_WRITE_RE = field_write_re(
    r"intr_status|hw_status|cmd_status|work_cycle|parse_status|irq_result|"
    r"irq_seen"
)
RGA_FAULT_SNAPSHOT_WRITE_RE = field_write_re(r"iommu_fault_generation")
RGA_TERMINAL_STATE_WRITE_RE = field_write_re(r"recovery_failed|removing")
RGA_JOB_OUTCOME_WRITE_RE = field_write_re(
    r"result|done",
    publishers=r"WRITE_ONCE|smp_store_release",
    target=POINTER_FIELD_TARGET,
)
RGA_WATCHDOG_SNAPSHOT_WRITE_RE = field_write_re(
    r"timeout_job|timeout_generation"
)
RGA_ACTIVATION_TIMING_WRITE_RE = field_write_re(r"hw_start_ns|hw_elapsed_ns")
RGA_TERMINAL_RE = re.compile(
    r"\b(?:rk_rga_job_complete(?:_queued)?|rk_rga_hw_finish_job_locked|"
    r"rk_rga_hw_(?:recover_active|restore_active_after_reset_failure|"
    r"abort_(?:queued_jobs|jobs|session_jobs)|reset_for_recovery)|"
    r"rk_rga_job_abort_pending_acquire|"
    r"rk_rga_session_abort_pending_acquire_jobs|"
    r"rk_rga_session_abort_incompatible_pending_acquire_jobs(?:_slow)?|"
    r"rk_rga_abort_incompatible_pending_acquire_jobs|"
    r"rk_rga_session_abort_hw_jobs)\s*\("
)
RGA_COMMAND_WRITE_RE = re.compile(
    r"\brk_rga_cmd_write\s*\(|"
    r"\b(?:memset|memcpy)\s*\(\s*[A-Za-z_]\w*->cmd_vaddr\b"
)
MPP_START_WRITE_RE = re.compile(
    r"\bwritel(?:_relaxed)?\s*\([^;]*(?:RK_MPP_RKVENC_START_BASE|"
    r"RK_MPP_RKVDEC_START_BASE|RK_MPP_RKVDEC_CCU_CFG_DONE_BASE)|"
    r"\bwritel(?:_relaxed)?\s*\(\s*(?!0(?:[uUlL]*)?\s*,)[^;]*"
    r"RK_MPP_AV1_IRQ_BASE"
)
MPP_IRQ_ACK_WRITE_RE = re.compile(
    r"\bwritel(?:_relaxed)?\s*\(\s*0(?:[uUlL]*)?\s*,[^;]*"
    r"RK_MPP_AV1_IRQ_BASE"
)
RGA_START_WRITE_RE = re.compile(
    r"\brk_rga_write\s*\([^;]*(?:RK_RGA2_CMD_CTRL|RK_RGA3_CMD_CTRL)"
)
RAW_TASK_RE = re.compile(r"\bstruct\s+rga_req\s*\*|\bjob->tasks\b")
DEBUG_INTERFACE_RE = re.compile(
    r"\bdebugfs_create_(?:atomic_t|u32|bool|file)\s*\(|"
    r"\brk_(?:mpp|rga)_debugfs_create_(?:atomic64|core_counts|core_times|route_b)\s*\("
)
DEBUG_EVENT_DECLARATIONS = {
    MPP_SOURCE: ("enum rk_mpp_debug_event_type", "struct rk_mpp_debug_event"),
    RGA_SOURCE: ("enum rk_rga_debug_event_type", "struct rk_rga_debug_event"),
}


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
        return (self.category, self.source, self.function, self.text, self.ordinal)


@dataclasses.dataclass
class FunctionBody:
    name: str
    signature: str
    first_line: int
    statements: list[tuple[int, str]] = dataclasses.field(default_factory=list)

    @property
    def text(self) -> str:
        return " ".join(statement for _line, statement in self.statements)


def normalize(text: str) -> str:
    return " ".join(text.strip().split())


def strip_comments(lines: list[str]) -> list[str]:
    """Remove comments while preserving line count and string contents."""

    stripped: list[str] = []
    in_block = False
    for line in lines:
        output: list[str] = []
        index = 0
        quote: str | None = None
        while index < len(line):
            char = line[index]
            pair = line[index : index + 2]
            if in_block:
                if pair == "*/":
                    in_block = False
                    index += 2
                else:
                    index += 1
                continue
            if quote:
                output.append(char)
                if char == "\\" and index + 1 < len(line):
                    output.append(line[index + 1])
                    index += 2
                    continue
                if char == quote:
                    quote = None
                index += 1
                continue
            if pair == "/*":
                in_block = True
                index += 2
                continue
            if pair == "//":
                break
            if char in {'"', "'"}:
                quote = char
            output.append(char)
            index += 1
        stripped.append("".join(output))
    return stripped


def kunit_lines(lines: list[str], symbol: str) -> set[int]:
    marker = f"#if IS_ENABLED({symbol})"
    ignored: set[int] = set()
    for start, line in enumerate(lines):
        if line.strip() != marker:
            continue
        depth = 0
        for index in range(start, len(lines)):
            directive = lines[index].lstrip()
            ignored.add(index)
            if re.match(r"#\s*(?:if|ifdef|ifndef)\b", directive):
                depth += 1
            elif re.match(r"#\s*endif\b", directive):
                depth -= 1
                if depth == 0:
                    break
        else:
            raise ValueError(f"unterminated KUnit region at line {start + 1}")
    if not ignored:
        raise ValueError(f"missing KUnit region marker {marker}")
    return ignored


def brace_delta(text: str) -> int:
    """Count braces outside strings after comments have been removed."""

    delta = 0
    quote: str | None = None
    index = 0
    while index < len(text):
        char = text[index]
        if quote:
            if char == "\\":
                index += 2
                continue
            if char == quote:
                quote = None
        elif char in {'"', "'"}:
            quote = char
        elif char == "{":
            delta += 1
        elif char == "}":
            delta -= 1
        index += 1
    return delta


def parse_functions(source: pathlib.Path, symbol: str) -> list[FunctionBody]:
    raw_lines = source.read_text(encoding="utf-8").splitlines()
    lines = strip_comments(raw_lines)
    ignored = kunit_lines(lines, symbol)
    functions: list[FunctionBody] = []
    current: FunctionBody | None = None
    signature: list[str] = []
    statement: list[str] = []
    statement_line = 0
    depth = 0

    for index, line in enumerate(lines):
        if index in ignored:
            continue
        stripped = line.strip()
        if current is None:
            if not stripped or stripped.startswith("#"):
                signature.clear()
                continue
            signature.append(stripped)
            candidate = " ".join(signature)
            if "{" in stripped:
                match = FUNCTION_RE.search(candidate)
                if match and match.group(1) not in CONTROL_WORDS:
                    current = FunctionBody(
                        name=match.group(1),
                        signature=normalize(candidate),
                        first_line=index + 1,
                    )
                    functions.append(current)
                    depth = brace_delta(candidate)
                    signature.clear()
                    remainder = stripped.split("{", 1)[1]
                    if remainder:
                        statement = [remainder]
                        statement_line = index + 1
                    if depth <= 0:
                        current = None
                else:
                    signature.clear()
            elif ";" in stripped or len(signature) > 12:
                signature.clear()
            continue

        if stripped and not statement:
            statement_line = index + 1
        if stripped:
            statement.append(stripped)
        depth += brace_delta(line)
        joined = " ".join(statement)
        while ";" in joined:
            complete, joined = joined.split(";", 1)
            complete = normalize(complete + ";")
            if complete:
                current.statements.append((statement_line, complete))
            statement_line = index + 1
        statement = [joined] if joined.strip() else []
        if depth <= 0:
            current = None
            statement = []
            depth = 0

    return functions


def declaration_block(source: pathlib.Path, declaration: str) -> tuple[int, str]:
    lines = strip_comments(source.read_text(encoding="utf-8").splitlines())
    collecting = False
    depth = 0
    first_line = 0
    block: list[str] = []
    for index, line in enumerate(lines, start=1):
        if not collecting:
            if declaration not in line:
                continue
            collecting = True
            first_line = index
        block.append(line.strip())
        depth += brace_delta(line)
        if depth == 0 and ";" in line:
            return first_line, normalize(" ".join(block))
    raise ValueError(f"missing or unterminated declaration {declaration} in {source}")


def raw_signals(kernel_tree: pathlib.Path) -> list[tuple[str, str, str, str, int]]:
    found: list[tuple[str, str, str, str, int]] = []
    for relative in SOURCES:
        source = kernel_tree / relative
        if not source.is_file():
            raise ValueError(f"missing rewrite source: {source}")
        for declaration in DEBUG_EVENT_DECLARATIONS[relative]:
            line, text = declaration_block(source, declaration)
            found.append(
                ("debug-event-schema", relative, "<file-scope>", text, line)
            )
        functions = parse_functions(source, KUNIT_MARKERS[relative])
        for function in functions:
            command_writer = False
            for line, statement in function.statements:
                matches: list[tuple[str, re.Pattern[str]]] = []
                if relative == MPP_SOURCE:
                    matches.extend(
                        (
                            ("mpp-reset-control", RESET_CALL_RE),
                            ("mpp-active-slot-access", ACTIVE_SLOT_ACCESS_RE),
                            ("mpp-active-slot-write", ACTIVE_SLOT_WRITE_RE),
                            ("mpp-dispatch-lease-access", DISPATCH_LEASE_ACCESS_RE),
                            ("mpp-dispatch-lease-write", DISPATCH_LEASE_WRITE_RE),
                            ("mpp-power-field", POWER_FIELD_RE),
                            (
                                "mpp-power-transition-entry",
                                MPP_POWER_TRANSITION_RE,
                            ),
                            ("mpp-power-backend-op", MPP_POWER_BACKEND_RE),
                            (
                                "mpp-power-count-write",
                                MPP_POWER_COUNT_WRITE_RE,
                            ),
                            ("mpp-watchdog-arm-entry", MPP_WATCHDOG_ARM_RE),
                            ("mpp-iommu-transition", MPP_IOMMU_RE),
                            ("mpp-iommu-backend-op", MPP_IOMMU_BACKEND_RE),
                            (
                                "mpp-job-lifecycle-write",
                                MPP_JOB_LIFECYCLE_WRITE_RE,
                            ),
                            (
                                "mpp-irq-snapshot-write",
                                MPP_IRQ_SNAPSHOT_WRITE_RE,
                            ),
                            (
                                "mpp-fault-snapshot-write",
                                MPP_FAULT_SNAPSHOT_WRITE_RE,
                            ),
                            (
                                "mpp-terminal-state-write",
                                MPP_TERMINAL_STATE_WRITE_RE,
                            ),
                            (
                                "mpp-watchdog-snapshot-write",
                                MPP_WATCHDOG_SNAPSHOT_WRITE_RE,
                            ),
                            (
                                "mpp-outcome-publish-entry",
                                MPP_OUTCOME_PUBLISH_RE,
                            ),
                            (
                                "mpp-activation-timing-write",
                                MPP_ACTIVATION_TIMING_WRITE_RE,
                            ),
                            ("mpp-terminal-entry", MPP_TERMINAL_RE),
                            ("mpp-irq-ack-write", MPP_IRQ_ACK_WRITE_RE),
                            ("start-doorbell-write", MPP_START_WRITE_RE),
                        )
                    )
                else:
                    matches.extend(
                        (
                            ("rga-active-slot-access", ACTIVE_SLOT_ACCESS_RE),
                            ("rga-active-slot-write", ACTIVE_SLOT_WRITE_RE),
                            ("rga-exec-map-owner", RGA_EXEC_MAP_OWNER_RE),
                            (
                                "rga-map-release-primitive",
                                RGA_MAP_RELEASE_PRIMITIVE_RE,
                            ),
                            ("rga-command-release", RGA_COMMAND_RELEASE_RE),
                            (
                                "rga-irq-snapshot-write",
                                RGA_IRQ_SNAPSHOT_WRITE_RE,
                            ),
                            (
                                "rga-fault-snapshot-write",
                                RGA_FAULT_SNAPSHOT_WRITE_RE,
                            ),
                            (
                                "rga-terminal-state-write",
                                RGA_TERMINAL_STATE_WRITE_RE,
                            ),
                            (
                                "rga-job-outcome-write",
                                RGA_JOB_OUTCOME_WRITE_RE,
                            ),
                            (
                                "rga-watchdog-snapshot-write",
                                RGA_WATCHDOG_SNAPSHOT_WRITE_RE,
                            ),
                            ("rga-watchdog-arm-entry", RGA_WATCHDOG_ARM_RE),
                            (
                                "rga-activation-timing-write",
                                RGA_ACTIVATION_TIMING_WRITE_RE,
                            ),
                            ("rga-terminal-entry", RGA_TERMINAL_RE),
                            ("rga-task-advance", RGA_TASK_ADVANCE_RE),
                            ("start-doorbell-write", RGA_START_WRITE_RE),
                        )
                    )
                    if RGA_COMMAND_WRITE_RE.search(statement):
                        command_writer = True
                for category, pattern in matches:
                    if pattern.search(statement):
                        found.append(
                            (category, relative, function.name, statement, line)
                        )
                if DEBUG_INTERFACE_RE.search(statement):
                    found.append(
                        (
                            "debug-interface-registration",
                            relative,
                            function.name,
                            statement,
                            line,
                        )
                    )
            if relative == RGA_SOURCE:
                if command_writer:
                    found.append(
                        (
                            "rga-command-writer",
                            relative,
                            function.name,
                            function.signature,
                            function.first_line,
                        )
                    )
                if "emit" in function.name and RAW_TASK_RE.search(
                    f"{function.signature} {function.text}"
                ):
                    found.append(
                        (
                            "rga-raw-task-emitter",
                            relative,
                            function.name,
                            function.signature,
                            function.first_line,
                        )
                    )
    return found


def audit_tree(kernel_tree: pathlib.Path) -> list[Signal]:
    occurrences: collections.Counter[tuple[str, str, str, str]] = (
        collections.Counter()
    )
    signals: list[Signal] = []
    for category, source, function, text, line in raw_signals(kernel_tree):
        identity = (category, source, function, text)
        occurrences[identity] += 1
        signals.append(
            Signal(
                category=category,
                source=source,
                function=function,
                text=normalize(text),
                ordinal=occurrences[identity],
                line=line,
            )
        )
    return sorted(signals)


def encode(signal: Signal) -> str:
    return "\t".join(
        (
            signal.category,
            signal.source,
            signal.function,
            str(signal.ordinal),
            signal.text,
        )
    )


def read_baseline(
    path: pathlib.Path,
) -> tuple[
    set[tuple[str, str, str, str, int]],
    set[str],
    set[str],
]:
    baseline: set[tuple[str, str, str, str, int]] = set()
    source_heads: set[str] = set()
    categories: set[str] = set()
    for line_number, raw in enumerate(
        path.read_text(encoding="utf-8").splitlines(), start=1
    ):
        if raw.startswith("# source-head\t"):
            source_heads.add(raw.split("\t", 1)[1])
            continue
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
        categories.add(category)
    return baseline, source_heads, categories


def git_head(tree: pathlib.Path) -> str:
    result = subprocess.run(
        ["git", "-C", str(tree), "rev-parse", "HEAD"],
        capture_output=True,
        text=True,
        check=False,
    )
    return result.stdout.strip() if result.returncode == 0 else "unknown"


def baseline_lines(
    trees: Iterable[pathlib.Path], signals: Iterable[Signal]
) -> Iterable[str]:
    yield "# Rewrite ownership inventory; new signals fail, resolved signals are allowed."
    for head in sorted({git_head(tree) for tree in trees}):
        yield f"# source-head\t{head}"
    yield "# category\tsource\tfunction\tordinal\tnormalized source signal"
    yield from (encode(signal) for signal in signals)


def parse_args(argv: list[str]) -> argparse.Namespace:
    default_baseline = pathlib.Path(__file__).with_name(
        "rewrite-ownership-source-audit-baseline.tsv"
    )
    parser = argparse.ArgumentParser(
        description="Audit rewrite ownership seams against a checked inventory"
    )
    parser.add_argument("kernel_tree", nargs="+", type=pathlib.Path)
    parser.add_argument("--baseline", type=pathlib.Path, default=default_baseline)
    parser.add_argument("--emit-baseline", action="store_true")
    parser.add_argument("--update-baseline", action="store_true")
    return parser.parse_args(argv)


def category_counts(signals: Iterable[Signal]) -> str:
    counts = collections.Counter(signal.category for signal in signals)
    return ", ".join(f"{category}={counts[category]}" for category in sorted(counts))


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.emit_baseline and args.update_baseline:
        print("choose only one baseline-output mode", file=sys.stderr)
        return 2
    try:
        trees = [(tree.resolve(), audit_tree(tree.resolve())) for tree in args.kernel_tree]
        output = (
            "\n".join(
                baseline_lines((tree for tree, _signals in trees), trees[0][1])
            )
            + "\n"
        )
        if args.emit_baseline:
            print(output, end="")
            return 0
        if args.update_baseline:
            args.baseline.write_text(output, encoding="utf-8")
            print(f"updated {args.baseline} with {len(trees[0][1])} signals")
            return 0
        baseline, baseline_heads, baseline_categories = read_baseline(args.baseline)
        if not baseline_heads:
            raise ValueError(f"{args.baseline}: missing source-head pin")
    except (OSError, ValueError) as error:
        print(f"rewrite ownership source audit: {error}", file=sys.stderr)
        return 2

    failed = False
    reference = {signal.key for signal in trees[0][1]}
    for tree, signals in trees:
        keys = {signal.key for signal in signals}
        head = git_head(tree)
        new = [signal for signal in signals if signal.key not in baseline]
        resolved = baseline - keys
        current_categories = {signal.category for signal in signals}
        print(
            f"{tree}: {len(signals)} ownership signals, {len(new)} new, "
            f"{len(resolved)} baseline entries absent"
        )
        print(f"  {category_counts(signals)}")
        for signal in new:
            failed = True
            print(
                f"NEW\t{signal.category}\t{signal.source}:{signal.line}\t"
                f"{signal.function}\t{signal.text}",
                file=sys.stderr,
            )
        if baseline_heads and head not in baseline_heads:
            failed = True
            print(
                f"{tree}: source HEAD {head} is not pinned by {args.baseline}",
                file=sys.stderr,
            )
        missing_categories = baseline_categories - current_categories
        if missing_categories:
            failed = True
            print(
                f"{tree}: baseline categories disappeared: "
                f"{', '.join(sorted(missing_categories))}",
                file=sys.stderr,
            )
        if keys != reference:
            failed = True
            print(
                f"{tree}: ownership signals differ from {trees[0][0]}",
                file=sys.stderr,
            )
    if failed:
        print("rewrite ownership source audit failed", file=sys.stderr)
        return 1
    print("rewrite ownership source audit passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
