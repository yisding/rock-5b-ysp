#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: GPL-2.0-only
"""Corrupt slice payloads in an Annex-B elementary stream, keeping it parsable.

Some driver paths are only reachable when the *hardware* reports a decode
error: the rkvdec2 soft-CCU IRQ thread resets the core whenever the interrupt
status hits the error mask, and that reset is otherwise rare enough that a test
cannot provoke it in a useful time. Feeding the decoder a stream whose slice
data is damaged -- but whose parameter sets and NAL framing are intact -- turns
that path from "needs a fault" into "once per frame".

The damage is deliberately shallow:

* Parameter sets (VPS/SPS/PPS) and SEI are left alone, so userspace still
  configures the decoder and submits jobs rather than failing at init.
* The first slices are left alone (--skip-slices), so the sequence starts from
  a clean IDR and the decoder reaches the hardware at all.
* Every byte written is forced non-zero with bit 6 set, so no 00 00 01 start
  code can be synthesised and the NAL framing is preserved. That is asserted
  before the output is written.

Corrupting the slice header rather than the payload tends to make userspace
reject the slice without ever submitting it, so writes start --header-skip
bytes into the NAL.
"""

from __future__ import annotations

import argparse
import pathlib
import sys


# Slice NAL types, i.e. the ones carrying coded picture data.
H265_SLICE_TYPES = frozenset(range(0, 22))
H264_SLICE_TYPES = frozenset((1, 5))


def find_nals(data: bytes) -> list[tuple[int, int]]:
    """Return (payload_start, payload_end) for every Annex-B NAL."""
    starts = []
    pos = 0
    while True:
        pos = data.find(b"\x00\x00\x01", pos)
        if pos < 0:
            break
        starts.append(pos + 3)
        pos += 3

    return [
        (start, (starts[i + 1] - 3) if i + 1 < len(starts) else len(data))
        for i, start in enumerate(starts)
    ]


def nal_type(data: bytes, start: int, codec: str) -> int:
    if codec == "h265":
        return (data[start] >> 1) & 0x3F
    return data[start] & 0x1F


def slice_types(codec: str) -> frozenset[int]:
    return H265_SLICE_TYPES if codec == "h265" else H264_SLICE_TYPES


def corrupt(
    data: bytes,
    codec: str,
    skip_slices: int,
    stride: int,
    header_skip: int,
) -> tuple[bytes, int, int]:
    out = bytearray(data)
    wanted = slice_types(codec)
    touched = 0
    corrupted_slices = 0
    seen_slices = 0

    for start, end in find_nals(data):
        if start >= len(data):
            continue
        if nal_type(data, start, codec) not in wanted:
            continue

        seen_slices += 1
        if seen_slices <= skip_slices:
            continue

        body = start + header_skip
        if body >= end:
            continue

        for pos in range(body, end, stride):
            # Non-zero with bit 6 set: cannot start or complete a 00 00 01
            # sequence, so the NAL framing this file is parsed by survives.
            out[pos] = ((out[pos] ^ 0x5A) | 0x40) & 0xFF
            touched += 1
        corrupted_slices += 1

    return bytes(out), touched, corrupted_slices


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--codec", choices=("h265", "h264"), default=None,
                        help="default: inferred from the input suffix")
    parser.add_argument("--skip-slices", type=int, default=2,
                        help="leave this many leading slices intact")
    parser.add_argument("--stride", type=int, default=7,
                        help="corrupt one byte every N bytes of slice payload")
    parser.add_argument("--header-skip", type=int, default=8,
                        help="bytes to skip past the NAL header before writing")
    args = parser.parse_args()

    codec = args.codec
    if codec is None:
        suffix = args.input.suffix.lower().lstrip(".")
        codec = "h264" if suffix in ("h264", "264", "avc") else "h265"

    data = args.input.read_bytes()
    before_nals = data.count(b"\x00\x00\x01")
    out, touched, slices = corrupt(
        data, codec, args.skip_slices, args.stride, args.header_skip
    )

    after_nals = out.count(b"\x00\x00\x01")
    if after_nals != before_nals:
        print(
            f"error: NAL count changed {before_nals} -> {after_nals}; "
            "the corruption would have broken Annex-B framing",
            file=sys.stderr,
        )
        return 1
    if touched == 0:
        print(
            f"error: no {codec} slice payload was corrupted "
            f"(nals={before_nals}, skip-slices={args.skip_slices}); "
            "the output would decode cleanly and provoke nothing",
            file=sys.stderr,
        )
        return 1

    args.output.write_bytes(out)
    print(
        f"codec={codec} nals={before_nals} slices_corrupted={slices} "
        f"bytes_touched={touched}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
