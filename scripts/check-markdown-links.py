#!/usr/bin/env python3
"""Check local Markdown file links and same-repo section anchors."""

from __future__ import annotations

import re
import sys
from pathlib import Path
from urllib.parse import unquote

LINK_RE = re.compile(r"!??\[[^\]\n]*(?:\][^\[\]\n]*)*\]\(([^\)\n]+)\)")
HEADING_RE = re.compile(r"^(#{1,6})\s+(.+?)\s*#*\s*$")
HTML_ANCHOR_RE = re.compile(
    r"<a\s+(?:[^>]*\s+)?(?:id|name)=[\"']([^\"']+)[\"']",
    re.IGNORECASE,
)
SCHEME_RE = re.compile(r"^[a-zA-Z][a-zA-Z0-9+.-]*:")


def github_like_anchor(text: str) -> str:
    """Approximate GitHub heading anchors; explicit HTML anchors cover hard cases."""
    text = re.sub(r"<[^>]+>", "", text)
    text = re.sub(r"[`*_~]", "", text)
    text = text.strip().lower()

    out: list[str] = []
    previous_dash = False
    for char in text:
        if char.isalnum() or char in {"-", "_"}:
            out.append(char)
            previous_dash = False
        elif char.isspace() or char == "-":
            if not previous_dash:
                out.append("-")
                previous_dash = True
    return "".join(out).strip("-")


def markdown_files(root: Path) -> list[Path]:
    return sorted(path for path in root.rglob("*.md") if ".git" not in path.parts)


def normalize_target(raw: str) -> str:
    target = raw.strip()
    if " " in target and not target.startswith("<"):
        target = target.split()[0]
    if target.startswith("<") and target.endswith(">"):
        target = target[1:-1]
    return target


def anchors_for(path: Path) -> set[str]:
    anchors: set[str] = set()
    counts: dict[str, int] = {}

    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        heading = HEADING_RE.match(line)
        if heading:
            base = github_like_anchor(heading.group(2))
            if base:
                count = counts.get(base, 0)
                counts[base] = count + 1
                anchors.add(base if count == 0 else f"{base}-{count}")

        for html_anchor in HTML_ANCHOR_RE.finditer(line):
            anchors.add(html_anchor.group(1))

    return anchors


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    missing_files: list[tuple[Path, str, Path]] = []
    missing_anchors: list[tuple[Path, str, Path, str]] = []
    anchor_cache: dict[Path, set[str]] = {}
    file_links = 0
    anchor_links = 0

    for path in markdown_files(root):
        text = path.read_text(encoding="utf-8", errors="replace")
        for match in LINK_RE.finditer(text):
            raw = match.group(1).strip()
            if not raw:
                continue

            target = normalize_target(raw)
            if target.startswith("#") or SCHEME_RE.match(target):
                candidate = path.resolve()
                fragment = target[1:] if target.startswith("#") else ""
            else:
                file_part, _, fragment = target.partition("#")
                if not file_part:
                    continue
                candidate = (path.parent / unquote(file_part)).resolve()

            try:
                candidate.relative_to(root)
            except ValueError:
                continue

            file_links += 1
            if not candidate.exists():
                missing_files.append((path.relative_to(root), raw, candidate.relative_to(root)))
                continue

            if not fragment:
                continue
            if candidate.suffix.lower() != ".md":
                continue

            anchor_links += 1
            fragment = unquote(fragment)
            if candidate not in anchor_cache:
                anchor_cache[candidate] = anchors_for(candidate)
            if fragment not in anchor_cache[candidate]:
                missing_anchors.append(
                    (path.relative_to(root), raw, candidate.relative_to(root), fragment)
                )

    for source, raw, candidate in missing_files:
        print(f"{source}: missing link {raw} -> {candidate}", file=sys.stderr)
    for source, raw, candidate, fragment in missing_anchors:
        print(
            f"{source}: missing anchor {raw} -> {candidate}#{fragment}",
            file=sys.stderr,
        )

    print(
        f"checked {len(markdown_files(root))} markdown files, "
        f"{file_links} local links, {anchor_links} local markdown anchors"
    )
    return 1 if missing_files or missing_anchors else 0


if __name__ == "__main__":
    raise SystemExit(main())
