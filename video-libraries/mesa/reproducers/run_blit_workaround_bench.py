#!/usr/bin/env python3
"""Run the Mesa blit-workaround benchmark in controlled ABBA/BAAB blocks."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import math
import os
from pathlib import Path
import random
import statistics
import subprocess
import sys
from typing import Iterable


GPU_DEVFREQ = Path("/sys/devices/platform/fb000000.gpu/devfreq/fb000000.gpu")


@dataclass(frozen=True)
class Fit:
    intercept: float
    slope: float
    r2: float
    rms: float
    max_abs: float
    point_count: int


def percentile(values: Iterable[float], fraction: float) -> float:
    ordered = sorted(values)
    position = fraction * (len(ordered) - 1)
    low = math.floor(position)
    high = min(low + 1, len(ordered) - 1)
    weight = position - low
    return ordered[low] * (1.0 - weight) + ordered[high] * weight


def bootstrap_median_interval(
    values: list[float], samples: int
) -> tuple[float, float]:
    if not values:
        return math.nan, math.nan
    if len(values) == 1:
        return values[0], values[0]

    generator = random.Random(43161)
    medians = [
        statistics.median(generator.choices(values, k=len(values)))
        for _ in range(samples)
    ]
    return percentile(medians, 0.025), percentile(medians, 0.975)


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="ascii").strip()
    except OSError:
        return "unavailable"


def gpu_clocks() -> tuple[str, str, str]:
    return tuple(
        read_text(GPU_DEVFREQ / name)
        for name in ("min_freq", "max_freq", "cur_freq")
    )


def parse_assignment(text: str) -> tuple[str, str]:
    name, separator, value = text.partition("=")
    if (
        not separator
        or not name
        or not name.isascii()
        or not name.isidentifier()
    ):
        raise argparse.ArgumentTypeError("expected NAME=VALUE")
    return name, value


def parse_fit(line: str) -> tuple[tuple[str, str], Fit] | None:
    fields = line.split(",")
    if len(fields) != 10 or fields[0] != "FIT":
        return None
    key = (fields[2], fields[3])
    return key, Fit(
        intercept=float(fields[4]),
        slope=float(fields[5]),
        r2=float(fields[6]),
        rms=float(fields[7]),
        max_abs=float(fields[8]),
        point_count=int(fields[9]),
    )


def reject_reason(fits: Iterable[Fit], minimum_r2: float) -> str | None:
    fit_list = list(fits)
    if any(fit.slope <= 0.0 for fit in fit_list):
        return "non-positive-slope"
    if any(fit.r2 < minimum_r2 for fit in fit_list):
        return "fit-r2"
    return None


def run_process(
    binary: Path,
    common_args: list[str],
    label: str,
    assignment: tuple[str, str],
    cpu: int | None,
    schedule_order: str,
) -> dict[tuple[str, str], Fit]:
    environment = os.environ.copy()
    environment[assignment[0]] = assignment[1]
    command = [
        str(binary),
        "--label",
        label,
        "--order",
        schedule_order,
        *common_args,
    ]
    if cpu is not None:
        command = ["taskset", "-c", str(cpu), *command]

    completed = subprocess.run(
        command,
        env=environment,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    for line in completed.stderr.splitlines():
        print(f"CHILD-STDERR,{label},{line}", file=sys.stderr)
    print(completed.stdout, end="")
    acknowledgement = f"{assignment[0]}={assignment[1]}"
    if acknowledgement not in completed.stderr:
        raise RuntimeError(
            f"{label} driver did not acknowledge {acknowledgement}; "
            "refusing an unverified A/B label"
        )
    allowed_returncodes = {0, 2} if label == "off" else {0}
    if completed.returncode not in allowed_returncodes:
        raise RuntimeError(
            f"{label} benchmark process exited {completed.returncode}"
        )
    if completed.returncode == 2:
        print(
            "CHILD-STATUS,off,expected-baseline-correctness-failure",
            file=sys.stderr,
        )

    fits = {}
    for line in completed.stdout.splitlines():
        parsed = parse_fit(line)
        if parsed:
            fits[parsed[0]] = parsed[1]
    if not fits:
        raise RuntimeError(f"{label} benchmark process produced no FIT records")
    return fits


def run_in_process(
    binary: Path,
    common_args: list[str],
    blocks: int,
    off_assignment: tuple[str, str],
    on_assignment: tuple[str, str],
    cpu: int | None,
    expected_gpu_hz: int,
    single_context: bool,
    dynamic_option: str,
) -> list[dict[str, list[dict[tuple[str, str], Fit]]]]:
    if off_assignment[0] != on_assignment[0]:
        raise RuntimeError(
            "in-process A/B requires off and on to use the same option name"
        )

    command = [
        str(binary),
        "--in-process-blocks",
        str(blocks),
        "--context-option",
        off_assignment[0],
        "--context-a",
        off_assignment[1],
        "--context-b",
        on_assignment[1],
        *common_args,
    ]
    if single_context:
        command[1:1] = [
            "--single-context",
            "--dynamic-option",
            dynamic_option,
        ]
    if expected_gpu_hz:
        command[1:1] = ["--expect-gpu-hz", str(expected_gpu_hz)]
    if cpu is not None:
        command = ["taskset", "-c", str(cpu), *command]

    completed = subprocess.run(
        command,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    for line in completed.stderr.splitlines():
        print(f"CHILD-STDERR,in-process,{line}", file=sys.stderr)
    print(completed.stdout, end="")

    if single_context:
        acknowledgements = [f"{off_assignment[0]}=dynamic"]
        acknowledgements.extend(
            f"{dynamic_option}={value}"
            for value in {off_assignment[1], on_assignment[1]}
        )
    else:
        acknowledgements = [
            f"{off_assignment[0]}={off_assignment[1]}",
            f"{on_assignment[0]}={on_assignment[1]}",
        ]
    for acknowledgement in set(acknowledgements):
        required = acknowledgements.count(acknowledgement)
        if completed.stderr.count(acknowledgement) < required:
            raise RuntimeError(
                "driver did not acknowledge both in-process contexts; "
                f"missing {required} occurrence(s) of {acknowledgement}"
            )
    if completed.returncode not in {0, 2}:
        raise RuntimeError(
            f"in-process benchmark exited {completed.returncode}"
        )

    block_results: list[
        dict[str, list[dict[tuple[str, str], Fit]]]
    ] = [{"off": [], "on": []} for _ in range(blocks)]
    current_block: int | None = None
    current_label: str | None = None
    current_fits: dict[tuple[str, str], Fit] = {}
    verdicts: dict[str, str] = {}

    def finish_run() -> None:
        nonlocal current_block, current_label, current_fits
        if current_block is None or current_label is None:
            return
        if not current_fits:
            raise RuntimeError(
                f"in-process block {current_block} {current_label} "
                "produced no FIT records"
            )
        semantic_label = "off" if current_label == "a" else "on"
        block_results[current_block][semantic_label].append(current_fits)
        current_block = None
        current_label = None
        current_fits = {}

    for line in completed.stdout.splitlines():
        fields = line.split(",")
        if len(fields) == 4 and fields[0] == "INPROCESS-RUN":
            finish_run()
            current_block = int(fields[1])
            current_label = fields[3]
            if (
                not 0 <= current_block < blocks
                or current_label not in {"a", "b"}
            ):
                raise RuntimeError(f"invalid in-process run marker: {line}")
            continue
        parsed = parse_fit(line)
        if parsed and current_block is not None:
            current_fits[parsed[0]] = parsed[1]
        if len(fields) == 3 and fields[0] == "VERDICT":
            verdicts[fields[1]] = fields[2]
    finish_run()

    for block_index, block in enumerate(block_results):
        if len(block["off"]) != 2 or len(block["on"]) != 2:
            raise RuntimeError(
                f"in-process block {block_index} did not contain two "
                "runs per context"
            )
    if verdicts.get("b") != "PASS" and off_assignment != on_assignment:
        raise RuntimeError(
            "in-process context B failed correctness in a differential A/B"
        )
    return block_results


def verify_clock(expected: int, phase: str) -> None:
    minimum, maximum, current = gpu_clocks()
    print(f"CLOCK,{phase},{minimum},{maximum},{current}")
    if expected and (minimum, maximum, current) != (str(expected),) * 3:
        raise RuntimeError(
            f"GPU clock is not fixed at {expected} Hz during {phase}"
        )


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Run blit_workaround_bench in alternating off/on blocks and "
            "summarize fitted fixed and per-blit deltas."
        )
    )
    parser.add_argument(
        "--binary",
        type=Path,
        default=Path(__file__).with_name("blit_workaround_bench"),
    )
    parser.add_argument("--blocks", type=int, default=6)
    parser.add_argument(
        "--in-process",
        action="store_true",
        help="alternate off/on in one child (two contexts unless overridden)",
    )
    parser.add_argument(
        "--single-context",
        action="store_true",
        help=(
            "toggle the test-only dynamic selector in one EGL context and "
            "balance ascending/descending count order"
        ),
    )
    parser.add_argument(
        "--dynamic-option",
        default="PAN_BLIT_DEPTH_BIAS_DYNAMIC",
        metavar="NAME",
        help="test-only per-draw selector used by --single-context",
    )
    parser.add_argument(
        "--off-env",
        type=parse_assignment,
        default=("PAN_BLIT_DEPTH_BIAS", "off"),
        metavar="NAME=VALUE",
    )
    parser.add_argument(
        "--on-env",
        type=parse_assignment,
        default=("PAN_BLIT_DEPTH_BIAS", "on"),
        metavar="NAME=VALUE",
    )
    parser.add_argument("--cpu", type=int)
    parser.add_argument("--expect-gpu-hz", type=int, default=0)
    parser.add_argument(
        "--min-fit-r2",
        type=float,
        default=0.98,
        help="reject paired slope percentages below this per-process R²",
    )
    parser.add_argument(
        "--min-pairs",
        type=int,
        default=8,
        help="minimum accepted adjacent A/B pairs for a decision-grade summary",
    )
    parser.add_argument(
        "--min-blocks",
        type=int,
        default=6,
        help="minimum accepted ABBA/BAAB block contrasts",
    )
    parser.add_argument(
        "--bootstrap-samples",
        type=int,
        default=20000,
        help="resamples for the paired median-percentage 95%% interval",
    )
    parser.add_argument(
        "benchmark_args",
        nargs=argparse.REMAINDER,
        help="arguments passed to blit_workaround_bench (prefix with --)",
    )
    args = parser.parse_args()

    if args.blocks < 1:
        parser.error("--blocks must be positive")
    if args.single_context and not args.in_process:
        parser.error("--single-context requires --in-process")
    if not args.dynamic_option or "=" in args.dynamic_option:
        parser.error("--dynamic-option must be a non-empty option name")
    if args.cpu is not None and args.cpu < 0:
        parser.error("--cpu must be non-negative")
    if args.expect_gpu_hz < 0:
        parser.error("--expect-gpu-hz must be non-negative")
    if not 0.0 <= args.min_fit_r2 <= 1.0:
        parser.error("--min-fit-r2 must be between zero and one")
    if args.min_pairs < 1:
        parser.error("--min-pairs must be positive")
    if args.min_blocks < 1:
        parser.error("--min-blocks must be positive")
    if args.bootstrap_samples < 1:
        parser.error("--bootstrap-samples must be positive")
    if not args.binary.is_file() or not os.access(args.binary, os.X_OK):
        parser.error(f"benchmark binary is not executable: {args.binary}")
    common_args = args.benchmark_args
    if common_args[:1] == ["--"]:
        common_args = common_args[1:]
    owned_benchmark_options = {
        "--label",
        "--order",
        "--in-process-blocks",
        "--context-option",
        "--context-a",
        "--context-b",
        "--single-context",
        "--dynamic-option",
        "--expect-gpu-hz",
    }
    overlap = owned_benchmark_options.intersection(
        argument.partition("=")[0] for argument in common_args
    )
    if overlap:
        parser.error(
            "the runner owns benchmark option(s): "
            + ", ".join(sorted(overlap))
        )

    uname = os.uname()
    print(
        f"HOST,{uname.sysname},{uname.release},{uname.machine},"
        f"{args.cpu if args.cpu is not None else 'unpinned'}"
    )
    verify_clock(args.expect_gpu_hz, "start")

    if args.in_process:
        print(
            f"COMPARISON,"
            f"{'single-context' if args.single_context else 'in-process'},"
            f"{args.off_env[0]},"
            f"{args.off_env[1]},{args.on_env[1]}"
        )
        block_results = run_in_process(
            args.binary,
            common_args,
            args.blocks,
            args.off_env,
            args.on_env,
            args.cpu,
            args.expect_gpu_hz,
            args.single_context,
            args.dynamic_option,
        )
    else:
        block_results = []
        for block in range(args.blocks):
            order = (
                ("off", "on", "on", "off")
                if block % 2 == 0
                else ("on", "off", "off", "on")
            )
            schedule_order = (
                "batched-first" if block % 2 == 0 else "isolated-first"
            )
            print(f"BLOCK,{block},{'-'.join(order)},{schedule_order}")
            result: dict[
                str, list[dict[tuple[str, str], Fit]]
            ] = {"off": [], "on": []}
            for sequence, label in enumerate(order):
                verify_clock(
                    args.expect_gpu_hz,
                    f"block-{block}-run-{sequence}-pre",
                )
                assignment = args.off_env if label == "off" else args.on_env
                result[label].append(
                    run_process(
                        args.binary,
                        common_args,
                        label,
                        assignment,
                        args.cpu,
                        schedule_order,
                    )
                )
                verify_clock(
                    args.expect_gpu_hz,
                    f"block-{block}-run-{sequence}-post",
                )
            block_results.append(result)

    keys = set(block_results[0]["off"][0])
    for block in block_results:
        for label in ("off", "on"):
            for run in block[label]:
                if set(run) != keys:
                    raise RuntimeError("FIT record set changed between processes")

    for schedule, metric in sorted(keys):
        fixed_deltas = []
        block_off_slopes = []
        block_on_slopes = []
        slope_deltas = []
        slope_percentages = []
        for block_index, block in enumerate(block_results):
            off_fits = [
                run[(schedule, metric)] for run in block["off"]
            ]
            on_fits = [
                run[(schedule, metric)] for run in block["on"]
            ]
            reason = reject_reason(
                [*off_fits, *on_fits], args.min_fit_r2
            )
            if reason:
                print(
                    f"BLOCK-REJECT,{block_index},{schedule},{metric},"
                    f"{reason}"
                )
                continue
            off_fixed = statistics.fmean(
                fit.intercept for fit in off_fits
            )
            on_fixed = statistics.fmean(
                fit.intercept for fit in on_fits
            )
            off_slope = statistics.fmean(
                fit.slope for fit in off_fits
            )
            on_slope = statistics.fmean(
                fit.slope for fit in on_fits
            )
            fixed_delta = on_fixed - off_fixed
            slope_delta = on_slope - off_slope
            log_ratio = statistics.fmean(
                math.log(fit.slope) for fit in on_fits
            ) - statistics.fmean(
                math.log(fit.slope) for fit in off_fits
            )
            slope_percentage = math.expm1(log_ratio) * 100.0
            fixed_deltas.append(fixed_delta)
            block_off_slopes.append(off_slope)
            block_on_slopes.append(on_slope)
            slope_deltas.append(slope_delta)
            slope_percentages.append(slope_percentage)
            print(
                f"BLOCK-DELTA,{block_index},{schedule},{metric},"
                f"{fixed_delta:.6f},{slope_delta:.6f},"
                f"{slope_percentage:.6f}"
            )

        block_interval_low = math.nan
        block_interval_high = math.nan
        if slope_percentages:
            block_interval_low, block_interval_high = (
                bootstrap_median_interval(
                    slope_percentages, args.bootstrap_samples
                )
            )
            print(
                f"DELTA,{schedule},{metric},"
                f"{statistics.median(fixed_deltas):.6f},"
                f"{statistics.median(slope_deltas):.6f},"
                f"{statistics.median(slope_percentages):.6f},"
                f"{percentile(slope_deltas, 0.1):.6f},"
                f"{percentile(slope_deltas, 0.9):.6f},"
                f"{len(slope_percentages)}"
            )
            print(
                f"BLOCK-SUMMARY,{schedule},{metric},"
                f"{statistics.median(fixed_deltas):.6f},"
                f"{statistics.median(block_off_slopes):.6f},"
                f"{statistics.median(block_on_slopes):.6f},"
                f"{statistics.median(slope_deltas):.6f},"
                f"{statistics.median(slope_percentages):.6f},"
                f"{percentile(slope_percentages, 0.1):.6f},"
                f"{percentile(slope_percentages, 0.9):.6f},"
                f"{block_interval_low:.6f},"
                f"{block_interval_high:.6f},"
                f"{len(slope_percentages)},{len(block_results)}"
            )
        else:
            print(
                f"DELTA,{schedule},{metric},"
                "nan,nan,nan,nan,nan,0"
            )
            print(
                f"BLOCK-SUMMARY,{schedule},{metric},"
                "nan,nan,nan,nan,nan,nan,nan,nan,nan,"
                f"0,{len(block_results)}"
            )

        block_quality_gate = (
            "PASS" if len(slope_percentages) >= args.min_blocks else "FAIL"
        )
        print(
            f"BLOCK-QUALITY-GATE,{schedule},{metric},"
            f"{block_quality_gate},{len(slope_percentages)},"
            f"{args.min_blocks},{args.min_fit_r2:.6f}"
        )
        if block_quality_gate == "FAIL":
            block_effect = "INSUFFICIENT"
        elif block_interval_low > 0.0:
            block_effect = "SLOWER"
        elif block_interval_high < 0.0:
            block_effect = "FASTER"
        else:
            block_effect = "UNRESOLVED"
        print(
            f"BLOCK-EFFECT-GATE,{schedule},{metric},{block_effect},"
            f"{block_interval_low:.6f},{block_interval_high:.6f}"
        )

        pair_fixed_deltas = []
        pair_off_slopes = []
        pair_on_slopes = []
        pair_slope_deltas = []
        pair_percentages = []
        total_pairs = 0
        for block_index, block in enumerate(block_results):
            for pair_index, (off_run, on_run) in enumerate(
                zip(block["off"], block["on"], strict=True)
            ):
                total_pairs += 1
                off_fit = off_run[(schedule, metric)]
                on_fit = on_run[(schedule, metric)]
                reason = reject_reason(
                    [off_fit, on_fit], args.min_fit_r2
                )

                if reason:
                    print(
                        f"PAIR-REJECT,{block_index},{pair_index},"
                        f"{schedule},{metric},{reason},"
                        f"{off_fit.slope:.6f},{on_fit.slope:.6f},"
                        f"{off_fit.r2:.9f},{on_fit.r2:.9f}"
                    )
                    continue

                fixed_delta = on_fit.intercept - off_fit.intercept
                slope_delta = on_fit.slope - off_fit.slope
                slope_percentage = (on_fit.slope / off_fit.slope - 1.0) * 100.0
                pair_fixed_deltas.append(fixed_delta)
                pair_off_slopes.append(off_fit.slope)
                pair_on_slopes.append(on_fit.slope)
                pair_slope_deltas.append(slope_delta)
                pair_percentages.append(slope_percentage)
                print(
                    f"PAIR-DELTA,{block_index},{pair_index},"
                    f"{schedule},{metric},{fixed_delta:.6f},"
                    f"{slope_delta:.6f},{slope_percentage:.6f},"
                    f"{off_fit.r2:.9f},{on_fit.r2:.9f}"
                )

        interval_low = math.nan
        interval_high = math.nan
        if pair_percentages:
            interval_low, interval_high = bootstrap_median_interval(
                pair_percentages, args.bootstrap_samples
            )
            print(
                f"PAIRED-SUMMARY,{schedule},{metric},"
                f"{statistics.median(pair_fixed_deltas):.6f},"
                f"{statistics.median(pair_off_slopes):.6f},"
                f"{statistics.median(pair_on_slopes):.6f},"
                f"{statistics.median(pair_slope_deltas):.6f},"
                f"{statistics.median(pair_percentages):.6f},"
                f"{percentile(pair_percentages, 0.1):.6f},"
                f"{percentile(pair_percentages, 0.9):.6f},"
                f"{interval_low:.6f},{interval_high:.6f},"
                f"{len(pair_percentages)},{total_pairs}"
            )
        else:
            print(
                f"PAIRED-SUMMARY,{schedule},{metric},"
                "nan,nan,nan,nan,nan,nan,nan,nan,nan,"
                f"0,{total_pairs}"
            )

        quality_gate = (
            "PASS" if len(pair_percentages) >= args.min_pairs else "FAIL"
        )
        print(
            f"PAIR-QUALITY-GATE,{schedule},{metric},{quality_gate},"
            f"{len(pair_percentages)},{args.min_pairs},"
            f"{args.min_fit_r2:.6f}"
        )
        if quality_gate == "FAIL":
            effect = "INSUFFICIENT"
        elif interval_low > 0.0:
            effect = "SLOWER"
        elif interval_high < 0.0:
            effect = "FASTER"
        else:
            effect = "UNRESOLVED"
        print(
            f"EFFECT-GATE,{schedule},{metric},{effect},"
            f"{interval_low:.6f},{interval_high:.6f}"
        )

    verify_clock(args.expect_gpu_hz, "end")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
