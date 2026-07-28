#!/usr/bin/env python3
"""Run the Mesa blit-workaround benchmark in paired ABBA/BAAB processes."""

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
            "Run blit_workaround_bench in alternating off/on process blocks "
            "and summarize fitted fixed and per-blit deltas."
        )
    )
    parser.add_argument(
        "--binary",
        type=Path,
        default=Path(__file__).with_name("blit_workaround_bench"),
    )
    parser.add_argument("--blocks", type=int, default=6)
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
    if args.cpu is not None and args.cpu < 0:
        parser.error("--cpu must be non-negative")
    if args.expect_gpu_hz < 0:
        parser.error("--expect-gpu-hz must be non-negative")
    if not 0.0 <= args.min_fit_r2 <= 1.0:
        parser.error("--min-fit-r2 must be between zero and one")
    if args.min_pairs < 1:
        parser.error("--min-pairs must be positive")
    if args.bootstrap_samples < 1:
        parser.error("--bootstrap-samples must be positive")
    if not args.binary.is_file() or not os.access(args.binary, os.X_OK):
        parser.error(f"benchmark binary is not executable: {args.binary}")
    common_args = args.benchmark_args
    if common_args[:1] == ["--"]:
        common_args = common_args[1:]
    if "--label" in common_args:
        parser.error("the runner owns --label")
    if "--order" in common_args:
        parser.error("the runner owns --order")

    uname = os.uname()
    print(
        f"HOST,{uname.sysname},{uname.release},{uname.machine},"
        f"{args.cpu if args.cpu is not None else 'unpinned'}"
    )
    verify_clock(args.expect_gpu_hz, "start")

    block_results: list[
        dict[str, list[dict[tuple[str, str], Fit]]]
    ] = []
    for block in range(args.blocks):
        order = ("off", "on", "on", "off") if block % 2 == 0 else (
            "on",
            "off",
            "off",
            "on",
        )
        schedule_order = (
            "batched-first" if block % 2 == 0 else "isolated-first"
        )
        print(f"BLOCK,{block},{'-'.join(order)},{schedule_order}")
        result: dict[
            str, list[dict[tuple[str, str], Fit]]
        ] = {"off": [], "on": []}
        for sequence, label in enumerate(order):
            verify_clock(args.expect_gpu_hz, f"block-{block}-run-{sequence}-pre")
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
                args.expect_gpu_hz, f"block-{block}-run-{sequence}-post"
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
        slope_deltas = []
        slope_percentages = []
        for block_index, block in enumerate(block_results):
            off_fixed = statistics.fmean(
                run[(schedule, metric)].intercept for run in block["off"]
            )
            on_fixed = statistics.fmean(
                run[(schedule, metric)].intercept for run in block["on"]
            )
            off_slope = statistics.fmean(
                run[(schedule, metric)].slope for run in block["off"]
            )
            on_slope = statistics.fmean(
                run[(schedule, metric)].slope for run in block["on"]
            )
            fixed_delta = on_fixed - off_fixed
            slope_delta = on_slope - off_slope
            slope_percentage = (
                (on_slope / off_slope - 1.0) * 100.0
                if off_slope
                else math.nan
            )
            fixed_deltas.append(fixed_delta)
            slope_deltas.append(slope_delta)
            slope_percentages.append(slope_percentage)
            print(
                f"BLOCK-DELTA,{block_index},{schedule},{metric},"
                f"{fixed_delta:.6f},{slope_delta:.6f},"
                f"{slope_percentage:.6f}"
            )

        print(
            f"DELTA,{schedule},{metric},"
            f"{statistics.median(fixed_deltas):.6f},"
            f"{statistics.median(slope_deltas):.6f},"
            f"{statistics.median(slope_percentages):.6f},"
            f"{percentile(slope_deltas, 0.1):.6f},"
            f"{percentile(slope_deltas, 0.9):.6f},"
            f"{len(block_results)}"
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
                reason = None
                if off_fit.slope <= 0.0 or on_fit.slope <= 0.0:
                    reason = "non-positive-slope"
                elif (
                    off_fit.r2 < args.min_fit_r2
                    or on_fit.r2 < args.min_fit_r2
                ):
                    reason = "fit-r2"

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
