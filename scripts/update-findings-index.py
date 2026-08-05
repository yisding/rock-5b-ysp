#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: GPL-2.0-or-later
"""Regenerate the compact findings index from filenames and H1 titles."""

from __future__ import annotations

import re
import sys
from pathlib import Path


START_MARKER = "<!-- findings-index:start -->"
END_MARKER = "<!-- findings-index:end -->"
FINDING_NAME_RE = re.compile(r"20\d{2}-\d{2}-\d{2}-[a-z0-9][a-z0-9.-]*\.md")
LEGACY_ROW_RE = re.compile(r"^- `` `20\d{2}-\d{2}-\d{2}-")


def finding_title(path: Path) -> str:
    first_line = path.read_text(encoding="utf-8", errors="replace").splitlines()[0]
    if not first_line.startswith("# ") or not first_line[2:].strip():
        raise ValueError(f"{path}: first line must be a non-empty H1")
    return first_line[2:].strip()


def generated_rows(findings: Path) -> list[str]:
    rows = []
    for path in sorted(findings.glob("20??-??-??-*.md"), reverse=True):
        rows.append(f"- [`{path.name}`]({path.name}) — {finding_title(path)}")
    return rows


def replace_index(readme: Path, rows: list[str]) -> str:
    lines = readme.read_text(encoding="utf-8", errors="replace").splitlines()
    if START_MARKER in lines or END_MARKER in lines:
        if lines.count(START_MARKER) != 1 or lines.count(END_MARKER) != 1:
            raise ValueError(f"{readme}: findings index markers must occur exactly once")
        start = lines.index(START_MARKER)
        end = lines.index(END_MARKER)
        if end <= start:
            raise ValueError(f"{readme}: findings index end marker precedes start")
        output = lines[: start + 1] + rows + lines[end:]
    else:
        legacy_rows = [index for index, line in enumerate(lines) if LEGACY_ROW_RE.match(line)]
        if not legacy_rows:
            raise ValueError(f"{readme}: no findings index markers or legacy rows found")
        start = legacy_rows[0]
        if legacy_rows != list(range(start, len(lines))):
            raise ValueError(f"{readme}: legacy findings rows are not one terminal block")
        output = lines[:start] + [START_MARKER] + rows + [END_MARKER]
    return "\n".join(output) + "\n"


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    findings = root / "findings"
    readme = findings / "README.md"
    try:
        updated = replace_index(readme, generated_rows(findings))
    except (IndexError, OSError, ValueError) as error:
        print(error, file=sys.stderr)
        return 1
    readme.write_text(updated, encoding="utf-8")
    print(f"updated {readme.relative_to(root)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
