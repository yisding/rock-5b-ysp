#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: GPL-2.0-or-later
"""Report likely competing documentation owners without failing the handoff gate.

This is a deliberately broad review aid.  Its output is evidence for human
review, not a score and not proof that a duplicate is wrong.  Keep blocking
owner checks in check-doc-consistency.py, where each assertion has a known
canonical owner.
"""

from __future__ import annotations

import argparse
import json
import re
from collections import Counter, defaultdict
from pathlib import Path
from typing import NamedTuple

from repo_files import finding_evidence_ownership, repository_markdown_files


LINK_RE = re.compile(r"!?\[([^\]]*)\]\([^)]*\)")
AUTOLINK_RE = re.compile(r"<https?://[^>]+>")
HTML_RE = re.compile(r"<[^>]+>")
WORD_RE = re.compile(r"[a-z0-9]+(?:[._+~-][a-z0-9]+)*")
SENTENCE_RE = re.compile(r"(?<=[.!?])\s+")
SHA_RE = re.compile(r"(?<![0-9A-Za-z])[0-9a-fA-F]{7,40}(?![0-9A-Za-z])")
VERSION_RE = re.compile(
    r"(?<![0-9A-Za-z/])v?\d+\.\d+(?:\.\d+)?"
    r"(?:[-+~:][0-9A-Za-z][0-9A-Za-z.+:~-]*)?(?![0-9A-Za-z])"
)
DATE_RE = re.compile(r"\b20\d{2}-\d{2}-\d{2}\b")
CURRENT_RE = re.compile(r"\b(?:current(?:ly)?|as\s+of)\b", re.IGNORECASE)
DASHBOARD_ROW_RE = re.compile(r"^\|\s*(\d+)\s*\|\s*([^|]+?)\s*\|")
LINK_TARGET_RE = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")

PROJECT_FRONT_DOORS = (
    "boot-firmware/README.md",
    "kernel-versions/README.md",
    "kernel-drivers/README.md",
    "kernel-drivers/mpp/README.md",
    "kernel-drivers/iep2/README.md",
    "kernel-drivers/rga/README.md",
    "kernel-drivers/av1/README.md",
    "kernel-drivers/iommu/README.md",
    "kernel-drivers/rknpu/README.md",
    "vendor-libraries/README.md",
    "vendor-libraries/mpp/README.md",
    "vendor-libraries/rga/README.md",
    "video-libraries/ffmpeg/README.md",
    "video-libraries/vaapi/README.md",
    "video-libraries/mesa/README.md",
    "apps/gnome-remote-desktop/README.md",
    "apps/kodi/README.md",
    "packaging/README.md",
)
PROJECT_BRIEF_CONCEPTS = {
    "purpose/user outcome": ("| Purpose |", "| User outcome |"),
    "developer focus": ("| Developer focus |",),
    "owns": ("| Owns |",),
    "depends on": ("| Depends on |",),
    "evidence boundary": ("| Evidence boundary |", "| Does not own |"),
}

# These files describe the organization contract rather than a mutable product
# assertion.  Dated findings/audits and status caches are legitimate owners of
# time-bounded language.  Everything else is reported for review, including
# source maps and project front doors.
NON_CONTENT_DOCS = {
    "CONTRIBUTING.md",
    "docs/repository-organization-proposal.md",
    "docs/repository-organization-migration.md",
}


class Block(NamedTuple):
    path: str
    line: int
    text: str


class Occurrence(NamedTuple):
    path: str
    line: int


def clean_markdown(text: str) -> str:
    """Remove link destinations and presentation markup from prose."""
    text = LINK_RE.sub(r"\1", text)
    text = AUTOLINK_RE.sub("", text)
    text = HTML_RE.sub(" ", text)
    text = re.sub(r"[`*_~]", "", text)
    text = re.sub(r"^\s*(?:#{1,6}|>|[-+*]|\d+[.)])\s*", "", text)
    return " ".join(text.split())


def words(text: str, *, mask_literals: bool = False) -> tuple[str, ...]:
    normalized = text.lower()
    if mask_literals:
        normalized = DATE_RE.sub(" date ", normalized)
        normalized = SHA_RE.sub(" sha ", normalized)
        normalized = VERSION_RE.sub(" version ", normalized)
    return tuple(WORD_RE.findall(normalized))


def prose_blocks(path: Path, relative: str) -> list[Block]:
    """Return prose paragraphs, excluding fenced code, tables, and comments."""
    blocks: list[Block] = []
    pending: list[str] = []
    start_line = 0
    in_fence = False
    in_comment = False

    def flush() -> None:
        nonlocal pending, start_line
        text = clean_markdown(" ".join(pending))
        if text:
            blocks.append(Block(relative, start_line, text))
        pending = []
        start_line = 0

    for line_number, raw_line in enumerate(
        path.read_text(encoding="utf-8", errors="replace").splitlines(), start=1
    ):
        stripped = raw_line.strip()
        if stripped.startswith("```") or stripped.startswith("~~~"):
            flush()
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        if in_comment:
            if "-->" in stripped:
                in_comment = False
            continue
        if stripped.startswith("<!--"):
            flush()
            in_comment = "-->" not in stripped
            continue
        if not stripped or stripped.startswith("|") or stripped.startswith("#"):
            flush()
            continue
        if not pending:
            start_line = line_number
        pending.append(stripped)
    flush()
    return blocks


def _reference(block: Block) -> dict[str, object]:
    return {"path": block.path, "line": block.line}


def find_identical_sentences(blocks: list[Block]) -> list[dict[str, object]]:
    groups: dict[str, list[Block]] = defaultdict(list)
    display: dict[str, str] = {}
    for block in blocks:
        for sentence in SENTENCE_RE.split(block.text):
            sentence = sentence.strip()
            tokens = words(sentence)
            if len(tokens) < 16 or len(sentence) < 100:
                continue
            key = " ".join(tokens)
            groups[key].append(Block(block.path, block.line, sentence))
            display.setdefault(key, sentence)

    findings = []
    for key, occurrences in groups.items():
        unique = sorted({(item.path, item.line) for item in occurrences})
        if len({path for path, _ in unique}) < 2:
            continue
        findings.append(
            {
                "text": display[key],
                "occurrences": [
                    {"path": path, "line": line} for path, line in unique
                ],
            }
        )
    return sorted(
        findings,
        key=lambda item: (
            -len(item["occurrences"]),
            item["occurrences"][0]["path"],
            item["occurrences"][0]["line"],
        ),
    )


def _shingles(tokens: tuple[str, ...], width: int = 4) -> frozenset[tuple[str, ...]]:
    return frozenset(
        tuple(tokens[index : index + width])
        for index in range(len(tokens) - width + 1)
    )


def find_similar_paragraphs(blocks: list[Block]) -> list[dict[str, object]]:
    """Find normalized prose pairs with at least 72% four-word-shingle overlap."""
    candidates: list[tuple[Block, frozenset[tuple[str, ...]]]] = []
    exact_groups: dict[tuple[str, ...], list[int]] = defaultdict(list)
    for block in blocks:
        tokens = words(block.text, mask_literals=True)
        if len(tokens) < 35:
            continue
        index = len(candidates)
        candidates.append((block, _shingles(tokens)))
        exact_groups[tokens].append(index)

    pairs: set[tuple[int, int]] = set()
    for indexes in exact_groups.values():
        for offset, left in enumerate(indexes):
            for right in indexes[offset + 1 :]:
                if candidates[left][0].path != candidates[right][0].path:
                    pairs.add((left, right))

    inverted: dict[tuple[str, ...], list[int]] = defaultdict(list)
    for index, (_, shingles) in enumerate(candidates):
        for shingle in shingles:
            inverted[shingle].append(index)

    shared: Counter[tuple[int, int]] = Counter()
    for indexes in inverted.values():
        # Very common boilerplate is neither useful nor safe to expand into a
        # quadratic candidate set. Exact copies were handled above.
        if len(indexes) > 40:
            continue
        for offset, left in enumerate(indexes):
            for right in indexes[offset + 1 :]:
                if candidates[left][0].path != candidates[right][0].path:
                    shared[(left, right)] += 1

    for (left, right), intersection in shared.items():
        left_set = candidates[left][1]
        right_set = candidates[right][1]
        union = len(left_set) + len(right_set) - intersection
        if union and intersection / union >= 0.72:
            pairs.add((left, right))

    findings = []
    for left, right in pairs:
        left_block, left_set = candidates[left]
        right_block, right_set = candidates[right]
        intersection = len(left_set & right_set)
        union = len(left_set | right_set)
        findings.append(
            {
                "similarity": round(intersection / union, 3) if union else 1.0,
                "left": _reference(left_block),
                "right": _reference(right_block),
            }
        )
    return sorted(
        findings,
        key=lambda item: (
            -item["similarity"],
            item["left"]["path"],
            item["left"]["line"],
            item["right"]["path"],
            item["right"]["line"],
        ),
    )


def find_repeated_literals(blocks: list[Block]) -> list[dict[str, object]]:
    occurrences: dict[tuple[str, str], set[Occurrence]] = defaultdict(set)
    for block in blocks:
        for literal in SHA_RE.findall(block.text):
            occurrences[("sha", literal.lower())].add(Occurrence(block.path, block.line))
        without_dates = DATE_RE.sub("", block.text)
        for literal in VERSION_RE.findall(without_dates):
            occurrences[("version", literal)].add(Occurrence(block.path, block.line))

    findings = []
    for (kind, literal), refs in occurrences.items():
        if len({ref.path for ref in refs}) < 2:
            continue
        findings.append(
            {
                "kind": kind,
                "literal": literal,
                "occurrences": [
                    {"path": ref.path, "line": ref.line} for ref in sorted(refs)
                ],
            }
        )
    return sorted(
        findings,
        key=lambda item: (
            -len(item["occurrences"]),
            item["kind"],
            item["literal"],
        ),
    )


def owns_time_bounded_language(relative: str) -> bool:
    return (
        relative == "status.md"
        or relative == "docs/status-ledger.md"
        or relative in NON_CONTENT_DOCS
        or re.fullmatch(r"findings/20\d{2}-\d{2}-\d{2}-.+\.md", relative)
        is not None
    )


def find_time_language(root: Path, paths: list[Path]) -> list[dict[str, object]]:
    findings = []
    for path in paths:
        relative = path.relative_to(root).as_posix()
        if owns_time_bounded_language(relative):
            continue
        in_fence = False
        for line_number, line in enumerate(
            path.read_text(encoding="utf-8", errors="replace").splitlines(), start=1
        ):
            stripped = line.strip()
            if stripped.startswith("```") or stripped.startswith("~~~"):
                in_fence = not in_fence
                continue
            if in_fence or not CURRENT_RE.search(line):
                continue
            findings.append(
                {
                    "path": relative,
                    "line": line_number,
                    "text": clean_markdown(line)[:180],
                }
            )
    return findings


def find_unowned_finding_evidence(root: Path) -> list[dict[str, object]]:
    return [
        {"path": bundle.relative_to(root.resolve()).as_posix()}
        for bundle, owners in finding_evidence_ownership(root).items()
        if not owners
    ]


def find_dashboard_route_candidates(root: Path) -> list[dict[str, object]]:
    """Report dashboard rows with many destinations for human boundary review."""
    status = root / "status.md"
    if not status.is_file():
        return []

    candidates = []
    in_dashboard = False
    for line_number, line in enumerate(
        status.read_text(encoding="utf-8", errors="replace").splitlines(), start=1
    ):
        if line == "## Dashboard":
            in_dashboard = True
            continue
        if in_dashboard and line.startswith("## "):
            break
        if not in_dashboard or not (row := DASHBOARD_ROW_RE.match(line)):
            continue
        routes = sorted(
            {
                target.strip().partition("#")[0]
                for target in LINK_TARGET_RE.findall(line)
                if target.strip().partition("#")[0]
            }
        )
        if len(routes) >= 4:
            candidates.append(
                {
                    "track": int(row.group(1)),
                    "name": clean_markdown(row.group(2)),
                    "line": line_number,
                    "routes": routes,
                }
            )
    return candidates


def find_project_brief_gaps(root: Path) -> list[dict[str, object]]:
    """Report missing interface concepts without enforcing one wording/style."""
    gaps = []
    for relative in PROJECT_FRONT_DOORS:
        path = root / relative
        if not path.is_file():
            gaps.append({"path": relative, "missing": ["front door"]})
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        missing = [
            concept
            for concept, markers in PROJECT_BRIEF_CONCEPTS.items()
            if not any(marker in text for marker in markers)
        ]
        if missing:
            gaps.append({"path": relative, "missing": missing})
    return gaps


def build_report(root: Path) -> dict[str, object]:
    root = root.resolve()
    paths = repository_markdown_files(root)
    blocks = [
        block
        for path in paths
        for block in prose_blocks(path, path.relative_to(root).as_posix())
    ]
    report = {
        "markdown_files": len(paths),
        "prose_blocks": len(blocks),
        "identical_long_sentences": find_identical_sentences(blocks),
        "similar_paragraphs": find_similar_paragraphs(blocks),
        "repeated_literals": find_repeated_literals(blocks),
        "time_language": find_time_language(root, paths),
        "unowned_finding_evidence": find_unowned_finding_evidence(root),
        "dashboard_route_candidates": find_dashboard_route_candidates(root),
        "project_brief_gaps": find_project_brief_gaps(root),
    }
    report["summary"] = {
        "identical_long_sentence_groups": len(report["identical_long_sentences"]),
        "similar_paragraph_pairs": len(report["similar_paragraphs"]),
        "repeated_version_or_sha_literals": len(report["repeated_literals"]),
        "time_language_occurrences": len(report["time_language"]),
        "time_language_files": len(
            {item["path"] for item in report["time_language"]}
        ),
        "unowned_finding_evidence_bundles": len(
            report["unowned_finding_evidence"]
        ),
        "dashboard_rows_with_many_routes": len(
            report["dashboard_route_candidates"]
        ),
        "project_front_doors_with_brief_gaps": len(report["project_brief_gaps"]),
    }
    return report


def print_text(report: dict[str, object], *, max_items: int, summary_only: bool) -> None:
    summary = report["summary"]
    print("Documentation duplication/owner report (informational)")
    print(f"Markdown files: {report['markdown_files']}")
    print(f"Prose blocks: {report['prose_blocks']}")
    print(
        "Identical long-sentence groups: "
        f"{summary['identical_long_sentence_groups']}"
    )
    print(f"Highly similar paragraph pairs: {summary['similar_paragraph_pairs']}")
    print(
        "Repeated version/SHA literals: "
        f"{summary['repeated_version_or_sha_literals']}"
    )
    print(
        "Current/as-of language outside designated owners: "
        f"{summary['time_language_occurrences']} occurrences in "
        f"{summary['time_language_files']} files"
    )
    print(
        "Finding-evidence bundles without a live owner: "
        f"{summary['unowned_finding_evidence_bundles']}"
    )
    print(
        "Dashboard rows with four or more routes: "
        f"{summary['dashboard_rows_with_many_routes']}"
    )
    print(
        "Project front doors with brief-concept gaps: "
        f"{summary['project_front_doors_with_brief_gaps']}"
    )
    if summary_only:
        return

    sections = (
        ("Identical long sentences", "identical_long_sentences"),
        ("Highly similar paragraphs", "similar_paragraphs"),
        ("Repeated version/SHA literals", "repeated_literals"),
        ("Current/as-of language", "time_language"),
        ("Unowned finding-evidence bundles", "unowned_finding_evidence"),
        ("Dashboard rows with many routes", "dashboard_route_candidates"),
        ("Project brief concept gaps", "project_brief_gaps"),
    )
    for title, key in sections:
        items = report[key]
        print(f"\n{title} (showing {min(len(items), max_items)} of {len(items)}):")
        for item in items[:max_items]:
            if key == "identical_long_sentences":
                refs = ", ".join(
                    f"{ref['path']}:{ref['line']}" for ref in item["occurrences"]
                )
                print(f"- {refs} :: {item['text'][:180]}")
            elif key == "similar_paragraphs":
                print(
                    f"- {item['similarity']:.3f} "
                    f"{item['left']['path']}:{item['left']['line']} <-> "
                    f"{item['right']['path']}:{item['right']['line']}"
                )
            elif key == "repeated_literals":
                refs = ", ".join(
                    f"{ref['path']}:{ref['line']}" for ref in item["occurrences"]
                )
                print(f"- {item['kind']} {item['literal']}: {refs}")
            else:
                if key == "time_language":
                    print(f"- {item['path']}:{item['line']} :: {item['text']}")
                elif key == "unowned_finding_evidence":
                    print(f"- {item['path']}")
                elif key == "dashboard_route_candidates":
                    print(
                        f"- status.md:{item['line']} track {item['track']} "
                        f"{item['name']}: {len(item['routes'])} routes"
                    )
                else:
                    print(f"- {item['path']}: missing {', '.join(item['missing'])}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", nargs="?", default=".", type=Path)
    parser.add_argument("--json", action="store_true", help="emit the complete JSON report")
    parser.add_argument("--summary", action="store_true", help="print counts only")
    parser.add_argument("--max-items", type=int, default=40, help="maximum details per category")
    args = parser.parse_args()

    report = build_report(args.root)
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print_text(report, max_items=max(0, args.max_items), summary_only=args.summary)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
