#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: GPL-2.0-or-later
"""Check substantive drift and completeness: version pins, portable defaults, index linkage.

Deliberately excludes documentation-formatting pedantry (finding headers,
dashboard/ledger date-matching, support-coverage schema, project-brief fields,
terminology). It reports only things that break navigation or ship wrong bits:
files no README names, unlinked/dangling findings, a findings index that is not
newest-first, watchlist halves that are missing or disagree on
name/last-checked date, dashboard tracks missing from the ledger or named
differently there, status tables split by blank lines or prose, drifted
packaging version pins, out-of-sync kernel package helpers, misplaced
root-level patch files, personal-home executable defaults, and shell files
whose shebang and executable bit disagree about whether they are run or
sourced.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path
from urllib.parse import unquote

from repo_files import (
    repository_documented_files,
    repository_markdown_files,
    repository_operational_files,
    tracked_file_modes,
)


FINDING_NAME_PATTERN = r"20\d{2}-\d{2}-\d{2}-[a-z0-9][a-z0-9.-]*\.md"
FINDING_NAME_RE = re.compile(FINDING_NAME_PATTERN)
FINDING_INDEX_ROW_RE = re.compile(
    rf"^- \[`(?P<name>{FINDING_NAME_PATTERN})`\]\((?P=name)\) — (?P<title>.+)$"
)
FINDINGS_INDEX_START = "<!-- findings-index:start -->"
FINDINGS_INDEX_END = "<!-- findings-index:end -->"
FINDINGS_TOPICS_START = "<!-- findings-topics:start -->"
FINDINGS_TOPICS_END = "<!-- findings-topics:end -->"
TOMBSTONE_RE = re.compile(r"^promoted → ", re.MULTILINE)
TOPIC_HEADING_RE = re.compile(r"^### (.+?) \((\d+)\)\s*$")
TOPIC_ROW_RE = re.compile(r"^- \[`\d{4}-\d{2}-\d{2}`\]\((20\d{2}-\d{2}-\d{2}-[^)]+\.md)\) — ")
WATCH_ID_RE = re.compile(r"^W\d{2}$")
WATCH_HEADING_RE = re.compile(r"^### (W\d{2}) — (.+?)\s*$")
WATCH_INDEX_NAME_RE = re.compile(r"^\[(.+)\]\(#watch-w\d{2}\)$")
WATCH_LAST_CHECKED_RE = re.compile(r"^-\s+\*\*Last checked:\*\*\s*(\d{4}-\d{2}-\d{2})")
ISO_DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
TRACK_ROW_RE = re.compile(r"^\|\s*(\d+)\s*\|\s*([^|]+?)\s*\|")
MARKDOWN_LINK_RE = re.compile(r"!?\[[^\]\n]*(?:\][^\[\]\n]*)*\]\(([^\)\n]+)\)")
SCHEME_RE = re.compile(r"^[a-zA-Z][a-zA-Z0-9+.-]*:")
PERSONAL_HOME_DEFAULT_RE = re.compile(
    r"(?:^[A-Z][A-Z0-9_]*=[\"']?/(?:home|Users)/|"
    r"\$\{[A-Za-z_][A-Za-z0-9_]*:-[\"']?/(?:home|Users)/)"
)
# The in-tree kernel packages share both helpers verbatim.
KERNEL_PACKAGE_DIRS = (
    "packaging/ppa/kernel-forward-port",
    "packaging/ppa/kernel-sgguard",
    "packaging/ppa/kernel-rewrite-alpha-6.18",
    "packaging/ppa/kernel-rewrite-alpha-7.2-rc3",
)
KERNEL_PACKAGE_HELPERS = (
    "debian/scripts/install-kernel-packages.sh",
    "debian/scripts/write-maintainer-scripts.sh",
)
# kernel-maxline builds out-of-tree from a separate kernel source, so its
# debian/rules.in passes install-kernel-packages.sh three extra arguments
# (localversion, build root, kernel source) and that helper is a deliberate
# variant, not drift. Everything it does share is still gated here — without
# this the package was outside the sync check entirely.
#
# The divergence is larger than the argument count, and this byte check cannot
# see it. maxline's copy also installs Module.symvers into the headers tree and
# restores the source include/ and arch/*/include/ trees after
# `make M=scripts clean`, while the three in-tree copies instead preserve
# include/config + autoconf.h as an `.armbian-build.tar.gz` sidecar and restore
# only scripts/module.lds. Those are two different strategies for the same
# hazard, not one copy missing a fix — but whether the sidecar approach leaves a
# complete headers tree has never been tested against an out-of-tree or DKMS
# build. Do not "resync" them without settling that first; the three now reject
# a nine-argument call rather than silently ignoring args 7-9.
KERNEL_PACKAGE_DIRS_ALL = KERNEL_PACKAGE_DIRS + ("packaging/ppa/kernel-maxline",)
KERNEL_PACKAGE_HELPERS_ALL = ("debian/scripts/write-maintainer-scripts.sh",)
PPA_GRD_PIN_DOCS = (
    "packaging/ppa/README.md",
    "packaging/ppa/gnome-remote-desktop/source-deltas/README.md",
    "docs/source-trees.md",
    "packaging/external-workspaces.md",
)
ROOT_PATCH_SUFFIXES = {".diff", ".patch"}


def check_root_patch_placement(root: Path, errors: list[str]) -> None:
    """Keep source patches with their owning project or evidence bundle."""
    for path in sorted(root.iterdir()):
        if path.is_file() and path.suffix in ROOT_PATCH_SUFFIXES:
            errors.append(
                f"{path.name}: root-level patch has no project owner; move it "
                "under the affected project's patches/ directory or a dated "
                "findings/evidence/ bundle"
            )


def check_portable_operational_defaults(root: Path, errors: list[str]) -> None:
    """Reject executable defaults tied to one developer's home directory."""
    for path in repository_operational_files(root):
        for line_number, line in enumerate(
            path.read_text(encoding="utf-8", errors="replace").splitlines(),
            start=1,
        ):
            if line.lstrip().startswith("#"):
                continue
            if PERSONAL_HOME_DEFAULT_RE.search(line):
                errors.append(
                    f"{path.relative_to(root)}:{line_number}: personal home path "
                    "used as an executable default; derive it from the repository "
                    "or a shared workspace variable"
                )


def check_findings_index(root: Path, errors: list[str]) -> None:
    """The generated filename/H1 index is complete, exact, and deterministic."""
    findings = root / "findings"
    readme = findings / "README.md"
    if not readme.is_file():
        return

    lines = readme.read_text(encoding="utf-8", errors="replace").splitlines()
    present = {path.name for path in findings.glob("20??-??-??-*.md")}
    if lines.count(FINDINGS_INDEX_START) != 1 or lines.count(FINDINGS_INDEX_END) != 1:
        errors.append(
            "findings/README.md: generated index markers must each occur exactly once; "
            "run scripts/update-findings-index.py"
        )
        return
    start = lines.index(FINDINGS_INDEX_START)
    end = lines.index(FINDINGS_INDEX_END)
    if end <= start:
        errors.append("findings/README.md: generated index end marker precedes start")
        return

    rows: list[tuple[str, str]] = []
    for line in lines[start + 1 : end]:
        match = FINDING_INDEX_ROW_RE.fullmatch(line)
        if not match:
            errors.append(
                "findings/README.md: generated index contains a non-canonical row; "
                "run scripts/update-findings-index.py"
            )
            continue
        rows.append((match.group("name"), match.group("title")))

    names = [name for name, _ in rows]
    indexed = set(names)
    for name in sorted(present - indexed):
        errors.append(f"findings/README.md: {name} is not linked from the index")
    for name in sorted(indexed - present):
        errors.append(f"findings/README.md: index links {name} but no such file exists")
    duplicates = sorted({name for name in names if names.count(name) > 1})
    for name in duplicates:
        errors.append(f"findings/README.md: index links {name} more than once")

    expected_order = sorted(present, reverse=True)
    if names != expected_order:
        errors.append(
            "findings/README.md: index order/content differs from reverse filename "
            "order; run scripts/update-findings-index.py"
        )

    for name, indexed_title in rows:
        path = findings / name
        if not path.is_file():
            continue
        first_line = path.read_text(encoding="utf-8", errors="replace").splitlines()[0]
        actual_title = first_line[2:].strip() if first_line.startswith("# ") else ""
        if not actual_title:
            errors.append(f"{path.relative_to(root)}: first line must be a non-empty H1")
        elif indexed_title != actual_title:
            errors.append(
                f"findings/README.md: title for {name} differs from its H1; "
                "run scripts/update-findings-index.py"
            )


def check_findings_topic_coverage(root: Path, errors: list[str]) -> None:
    """Every live finding sits in exactly one by-subsystem group.

    The chronological index is generated, so it cannot drift. The topic index is
    curated -- which is the point, since a machine cannot tell that a dma-buf
    oops filed under GRD is really a memory-plumbing finding -- but that makes it
    the half that silently rots. Enforcing coverage keeps the curation honest
    without dictating which group a finding lands in. Tombstones are excluded:
    they are pointers to a promoted target, and the chronology still lists them.
    """
    findings = root / "findings"
    readme = findings / "README.md"
    if not readme.is_file():
        return

    lines = readme.read_text(encoding="utf-8", errors="replace").splitlines()
    if lines.count(FINDINGS_TOPICS_START) != 1 or lines.count(FINDINGS_TOPICS_END) != 1:
        errors.append(
            "findings/README.md: topic index markers must each occur exactly once"
        )
        return
    start = lines.index(FINDINGS_TOPICS_START)
    end = lines.index(FINDINGS_TOPICS_END)
    if end <= start:
        errors.append("findings/README.md: topic index end marker precedes start")
        return

    live = set()
    for path in findings.glob("20??-??-??-*.md"):
        body = path.read_text(encoding="utf-8", errors="replace")
        if not TOMBSTONE_RE.search(body):
            live.add(path.name)

    grouped: dict[str, list[str]] = {}
    heading = None
    counts: dict[str, int] = {}
    for line in lines[start + 1 : end]:
        head = TOPIC_HEADING_RE.match(line)
        if head:
            heading = head.group(1)
            counts[heading] = int(head.group(2))
            grouped.setdefault(heading, [])
            continue
        row = TOPIC_ROW_RE.match(line)
        if row and heading is not None:
            grouped[heading].append(row.group(1))

    seen: dict[str, str] = {}
    for group, names in grouped.items():
        if len(names) != counts.get(group):
            errors.append(
                f"findings/README.md: topic group {group!r} says ({counts.get(group)}) "
                f"but lists {len(names)} findings"
            )
        for name in names:
            if not (findings / name).is_file():
                errors.append(
                    f"findings/README.md: topic group {group!r} links {name}, "
                    "but no such finding exists"
                )
            elif name not in live:
                errors.append(
                    f"findings/README.md: topic group {group!r} lists {name}, "
                    "which is a tombstone; topic groups carry live findings only"
                )
            elif name in seen:
                errors.append(
                    f"findings/README.md: {name} is in two topic groups "
                    f"({seen[name]!r} and {group!r}); pick the owning layer"
                )
            else:
                seen[name] = group

    for name in sorted(live - set(seen)):
        errors.append(
            f"findings/README.md: {name} is in no topic group; add it to the "
            "by-subsystem index so the finding is reachable by layer"
        )


def check_watchlist_pairing(root: Path, errors: list[str]) -> None:
    """Every watchlist W## entry has both halves, agreeing on name and date.

    The two halves are maintained by hand in one file and drifted seven ways in
    under two weeks, so name and last-checked exactness is enforced rather than
    left to convention. Ordering and prose are still not policed.
    """
    path = root / "status.md"
    if not path.is_file():
        errors.append("status.md: missing, so the watchlist pairing check cannot run")
        return

    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    heading = "## Watchlist — facts that go stale silently"
    if heading not in lines:
        # Returning quietly here disabled the whole check on any reword of the
        # heading -- even a trailing space -- while the stage still reported
        # success. If the heading is renamed deliberately, update it here too.
        errors.append(
            f"status.md: no {heading!r} heading, so the watchlist pairing check "
            "silently covered nothing; update the heading in "
            "check-doc-consistency.py if the rename was deliberate"
        )
        return
    section = lines[lines.index(heading) + 1 :]

    index: dict[str, tuple[str, str]] = {}
    details: dict[str, tuple[str, str | None]] = {}
    current: str | None = None
    for line in section:
        if line.startswith("## "):
            break
        if line.startswith("|"):
            cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
            if len(cells) >= 3 and WATCH_ID_RE.fullmatch(cells[0]):
                name = WATCH_INDEX_NAME_RE.match(cells[1])
                index[cells[0]] = (name.group(1) if name else cells[1], cells[2])
        detail = WATCH_HEADING_RE.match(line)
        if detail:
            current = str(detail.group(1))
            details[current] = (str(detail.group(2)), None)
        elif current is not None and details[current][1] is None:
            checked = WATCH_LAST_CHECKED_RE.match(line)
            if checked:
                details[current] = (details[current][0], checked.group(1))

    for watch_id in sorted(set(index) - set(details)):
        errors.append(f"status.md watchlist {watch_id}: index row has no detail block")
    for watch_id in sorted(set(details) - set(index)):
        errors.append(f"status.md watchlist {watch_id}: detail block has no index row")

    for watch_id in sorted(set(index) & set(details)):
        index_name, index_date = index[watch_id]
        detail_name, detail_date = details[watch_id]
        if index_name != detail_name:
            errors.append(
                f"status.md watchlist {watch_id}: name differs between halves "
                f"(index {index_name!r}, detail {detail_name!r})"
            )
        if not ISO_DATE_RE.fullmatch(index_date):
            errors.append(
                f"status.md watchlist {watch_id}: index date {index_date!r} "
                "is not YYYY-MM-DD"
            )
        if detail_date is None:
            errors.append(
                f"status.md watchlist {watch_id}: detail block has no "
                "'**Last checked:**' date"
            )
        elif detail_date != index_date:
            errors.append(
                f"status.md watchlist {watch_id}: last-checked date differs "
                f"between halves (index {index_date}, detail {detail_date})"
            )


def _numbered_tracks(path: Path) -> dict[str, str]:
    """Map track number -> track name from a leading `| N | Name | ...` table."""
    tracks: dict[str, str] = {}
    if not path.is_file():
        return tracks
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        match = TRACK_ROW_RE.match(line)
        if match:
            tracks[match.group(1)] = match.group(2).strip()
    return tracks


def check_status_ledger_tracks(root: Path, errors: list[str]) -> None:
    """The dashboard and its ledger carry the same track numbers and names.

    CONTRIBUTING.md requires a new track to be added to both files with one
    stable number; track 14 reached only the dashboard, and two more disagreed
    on capitalisation. Dated prose is still each file's own.
    """
    dashboard = _numbered_tracks(root / "status.md")
    ledger = _numbered_tracks(root / "docs/status-ledger.md")
    # An empty parse used to disable the comparison silently, so a table that
    # stopped matching TRACK_ROW_RE looked identical to a table with no drift.
    for label, tracks in (("status.md", dashboard), ("docs/status-ledger.md", ledger)):
        if not tracks:
            errors.append(
                f"{label}: no numbered track rows parsed, so the dashboard/ledger "
                "track comparison covered nothing"
            )
    if not dashboard or not ledger:
        return

    for number in sorted(set(dashboard) - set(ledger), key=int):
        errors.append(
            f"docs/status-ledger.md: no row for status.md track {number} "
            f"({dashboard[number]!r})"
        )
    for number in sorted(set(ledger) - set(dashboard), key=int):
        errors.append(
            f"status.md: no dashboard row for ledger track {number} "
            f"({ledger[number]!r})"
        )
    for number in sorted(set(dashboard) & set(ledger), key=int):
        if dashboard[number] != ledger[number]:
            errors.append(
                f"status.md track {number}: name differs from its ledger row "
                f"(dashboard {dashboard[number]!r}, ledger {ledger[number]!r})"
            )


def _check_contiguous_track_rows(
    label: str,
    numbered_lines: list[tuple[int, str]],
    errors: list[str],
) -> None:
    """A blank or prose line between rows ends the rendered Markdown table."""
    for (previous_line, previous_track), (line_number, track) in zip(
        numbered_lines, numbered_lines[1:]
    ):
        if line_number != previous_line + 1:
            errors.append(
                f"{label}:{line_number}: track {track} is separated from track "
                f"{previous_track}; numbered status rows must be contiguous "
                "because a blank or prose line ends the Markdown table"
            )


def check_status_table_layout(root: Path, errors: list[str]) -> None:
    """Keep the dashboard, next-gate queue, and ledger as rendered tables."""
    status_path = root / "status.md"
    if status_path.is_file():
        status_lines = status_path.read_text(
            encoding="utf-8", errors="replace"
        ).splitlines()
        for heading in ("## Dashboard", "## Next gates"):
            if heading not in status_lines:
                errors.append(
                    f"status.md: missing {heading!r}, so its table-layout check "
                    "cannot run"
                )
                continue
            start = status_lines.index(heading) + 1
            end = next(
                (
                    index
                    for index in range(start, len(status_lines))
                    if status_lines[index].startswith("## ")
                ),
                len(status_lines),
            )
            rows = [
                (index + 1, match.group(1))
                for index in range(start, end)
                if (match := TRACK_ROW_RE.match(status_lines[index]))
            ]
            if not rows:
                errors.append(f"status.md: {heading!r} has no numbered rows")
                continue
            _check_contiguous_track_rows(f"status.md {heading}", rows, errors)

    ledger_path = root / "docs/status-ledger.md"
    if ledger_path.is_file():
        ledger_lines = ledger_path.read_text(
            encoding="utf-8", errors="replace"
        ).splitlines()
        rows = [
            (index + 1, match.group(1))
            for index, line in enumerate(ledger_lines)
            if (match := TRACK_ROW_RE.match(line))
        ]
        if rows:
            _check_contiguous_track_rows("docs/status-ledger.md", rows, errors)


def check_kernel_package_helpers(
    root: Path,
    errors: list[str],
    package_dirs: tuple[str, ...] = KERNEL_PACKAGE_DIRS,
    helper_names: tuple[str, ...] = KERNEL_PACKAGE_HELPERS,
) -> None:
    """Keep source-package-local kernel helper copies synchronized."""
    for helper_name in helper_names:
        copies: list[tuple[str, bytes]] = []
        for package_dir in package_dirs:
            relative = f"{package_dir}/{helper_name}"
            path = root / relative
            if not path.is_file():
                errors.append(f"{relative}: missing kernel package helper")
                continue
            copies.append((relative, path.read_bytes()))

        if len(copies) < 2:
            continue
        reference_name, reference = copies[0]
        for relative, contents in copies[1:]:
            if contents != reference:
                errors.append(
                    f"{relative}: differs from synchronized helper {reference_name}"
                )


def check_ppa_ffmpeg_install_pin(root: Path, errors: list[str]) -> None:
    """Keep the FFmpeg candidate and documented live migration pin aligned."""
    changelog_path = root / "packaging/ppa/ffmpeg/debian/changelog"
    installer_path = root / "packaging/ppa/clean-install-system-stack.sh"
    for path in (changelog_path, installer_path):
        if not path.is_file():
            errors.append(
                f"{path.relative_to(root)}: missing, so the FFmpeg version-pin "
                "check cannot run; update the path here if the file moved"
            )
    if not changelog_path.is_file() or not installer_path.is_file():
        return

    changelog_match = re.search(
        r"^ffmpeg \(([^)]+)\)",
        changelog_path.read_text(encoding="utf-8", errors="replace"),
        re.MULTILINE,
    )
    installer_match = re.search(
        r'^FFMPEG_VERSION="([^"]+)"',
        installer_path.read_text(encoding="utf-8", errors="replace"),
        re.MULTILINE,
    )
    if changelog_match is None:
        errors.append("packaging/ppa/ffmpeg/debian/changelog: no leading ffmpeg version")
        return
    if installer_match is None:
        errors.append(
            "packaging/ppa/clean-install-system-stack.sh: no FFMPEG_VERSION pin"
        )
        return
    installer_version = installer_match.group(1)
    latest_version = changelog_match.group(1)
    if installer_version != latest_version:
        support_path = root / "docs/ppa-support.md"
        support_match = None
        if support_path.is_file():
            support_match = re.search(
                r"^<!-- ppa-live-ffmpeg: ([^ ]+) -->$",
                support_path.read_text(encoding="utf-8", errors="replace"),
                re.MULTILINE,
            )
        if support_match is None or installer_version != support_match.group(1):
            live_detail = (
                " and does not match the live version documented in "
                "docs/ppa-support.md"
                if support_match is not None
                else "; docs/ppa-support.md has no parseable ppa-live-ffmpeg marker"
            )
            errors.append(
                "packaging/ppa/clean-install-system-stack.sh: FFMPEG_VERSION "
                f"{installer_version!r} does not match latest changelog "
                f"{latest_version!r}{live_detail}"
            )

    readme_path = root / "packaging/ppa/README.md"
    if readme_path.is_file() and latest_version not in readme_path.read_text(
        encoding="utf-8", errors="replace"
    ):
        errors.append(
            "packaging/ppa/README.md: latest FFmpeg changelog version "
            f"{latest_version!r} is not documented"
        )

    exporter_path = root / "packaging/ppa/build-source-packages.sh"
    if exporter_path.is_file():
        exporter_match = re.search(
            r'FFMPEG_UPSTREAM_VERSION="\$\{FFMPEG_UPSTREAM_VERSION:-([^}]+)\}"',
            exporter_path.read_text(encoding="utf-8", errors="replace"),
        )
        if exporter_match is None:
            errors.append(
                "packaging/ppa/build-source-packages.sh: no default "
                "FFMPEG_UPSTREAM_VERSION"
            )
        elif exporter_match.group(1) not in latest_version:
            errors.append(
                "packaging/ppa/build-source-packages.sh: default FFmpeg upstream "
                f"version {exporter_match.group(1)!r} does not match latest "
                f"changelog {latest_version!r}"
            )


def check_ppa_grd_source_pin(root: Path, errors: list[str]) -> None:
    """Keep the GRD exporter, changelog, and reconstruction docs aligned."""
    exporter_path = root / "packaging/ppa/build-source-packages.sh"
    changelog_path = root / "packaging/ppa/gnome-remote-desktop/debian/changelog"
    for path in (exporter_path, changelog_path):
        if not path.is_file():
            errors.append(
                f"{path.relative_to(root)}: missing, so the GRD source-pin check "
                "cannot run; update the path here if the file moved"
            )
    if not exporter_path.is_file() or not changelog_path.is_file():
        return

    exporter_text = exporter_path.read_text(encoding="utf-8", errors="replace")
    commit_match = re.search(
        r'^GRD_COMMIT="\$\{GRD_COMMIT:-([^}]+)\}"',
        exporter_text,
        re.MULTILINE,
    )
    version_match = re.search(
        r'^GRD_UPSTREAM_VERSION="\$\{GRD_UPSTREAM_VERSION:-([^}]+)\}"',
        exporter_text,
        re.MULTILINE,
    )
    if commit_match is None:
        errors.append(
            "packaging/ppa/build-source-packages.sh: no default GRD_COMMIT"
        )
        return
    if version_match is None:
        errors.append(
            "packaging/ppa/build-source-packages.sh: no default "
            "GRD_UPSTREAM_VERSION"
        )
        return

    commit = commit_match.group(1)
    upstream_version = version_match.group(1)
    changelog_match = re.search(
        r"^gnome-remote-desktop \(([^)]+)\)",
        changelog_path.read_text(encoding="utf-8", errors="replace"),
        re.MULTILINE,
    )
    if changelog_match is None:
        errors.append(
            "packaging/ppa/gnome-remote-desktop/debian/changelog: no leading "
            "package version"
        )
        return

    package_version = changelog_match.group(1)
    if upstream_version not in package_version:
        errors.append(
            "packaging/ppa/build-source-packages.sh: default GRD upstream "
            f"version {upstream_version!r} does not match latest changelog "
            f"{package_version!r}"
        )
    if commit[:7] not in package_version:
        errors.append(
            "packaging/ppa/build-source-packages.sh: default GRD commit "
            f"{commit!r} does not match latest changelog {package_version!r}"
        )

    for relative in PPA_GRD_PIN_DOCS:
        path = root / relative
        if path.is_file() and commit not in path.read_text(
            encoding="utf-8", errors="replace"
        ):
            errors.append(
                f"{relative}: default GRD exporter commit {commit!r} is not "
                "documented"
            )


def check_readme_ownership(root: Path, errors: list[str]) -> None:
    """Every documented file is named by its nearest ancestor README.

    CONTRIBUTING.md makes the nearest README the front door for prose and for
    tracked tools alike, so that operational code never becomes an invisible
    entry point. A file reachable only by constructing its name at runtime is
    exactly the case this catches.
    """
    for path in repository_documented_files(root):
        if path.name == "README.md":
            continue

        directory = path.parent
        readme = None
        while True:
            candidate = directory / "README.md"
            if candidate.is_file():
                readme = candidate
                break
            if directory == root:
                break
            directory = directory.parent

        relative = path.relative_to(root)
        if readme is None:
            errors.append(f"{relative}: no ancestor README.md to own it")
            continue

        text = readme.read_text(encoding="utf-8", errors="replace")
        if path.name not in text:
            errors.append(
                f"{relative}: not named in its nearest README "
                f"({readme.relative_to(root)})"
            )


def _readme_link_targets(readme: Path, root: Path) -> set[Path]:
    """Resolve local Markdown file/directory links from one README."""
    targets: set[Path] = set()
    text = readme.read_text(encoding="utf-8", errors="replace")
    for match in MARKDOWN_LINK_RE.finditer(text):
        target = match.group(1).strip()
        if target.startswith("<") and target.endswith(">"):
            target = target[1:-1]
        elif " " in target:
            target = target.split()[0]
        if not target or target.startswith("#") or SCHEME_RE.match(target):
            continue

        file_part = target.partition("#")[0]
        if not file_part:
            continue
        candidate = (readme.parent / unquote(file_part)).resolve()
        try:
            candidate.relative_to(root)
        except ValueError:
            continue
        if candidate.is_dir():
            candidate /= "README.md"
        targets.add(candidate)
    return targets


def check_readme_navigation(root: Path, errors: list[str]) -> None:
    """Every nested README is linked from its nearest ancestor README."""
    for readme in repository_markdown_files(root):
        relative = readme.relative_to(root)
        if (
            readme.name != "README.md"
            or readme == root / "README.md"
            or "debian" in relative.parts
        ):
            continue

        directory = readme.parent.parent
        owner = None
        while True:
            candidate = directory / "README.md"
            if candidate.is_file():
                owner = candidate
                break
            if directory == root:
                break
            directory = directory.parent

        if owner is None:
            errors.append(f"{relative}: no ancestor README.md links this front door")
            continue
        if readme.resolve() not in _readme_link_targets(owner, root):
            errors.append(
                f"{relative}: not linked from its nearest ancestor README "
                f"({owner.relative_to(root)})"
            )


def check_shell_file_contract(root: Path, errors: list[str]) -> None:
    """A shell file is either executable-with-shebang or sourced-and-not.

    CONTRIBUTING.md § Shell conventions states both halves; before this check
    they were stated and unenforced, and five scripts had drifted to
    `#!/bin/bash` or `#!/bin/sh` while three source-only helpers kept a shebang
    and the executable bit they can do nothing with. The mode is read from the
    index, not the filesystem, because the index is what a clone gets.
    """
    entries = tracked_file_modes(root, "*.sh")
    if entries is None:
        return

    for mode, relative in entries:
        if "debian" in Path(relative).parts:
            continue

        first_line = (root / relative).read_text(
            encoding="utf-8", errors="replace"
        ).split("\n", 1)[0]

        if first_line == "#!/usr/bin/env bash":
            if mode != "100755":
                errors.append(
                    f"{relative}: has a shebang but is mode {mode}; an "
                    "executable script stays 0755"
                )
        elif first_line.startswith("# shellcheck shell=bash"):
            if mode != "100644":
                errors.append(
                    f"{relative}: is source-only but is mode {mode}; drop the "
                    "executable bit so it cannot be run by accident"
                )
        else:
            errors.append(
                f"{relative}:1: starts with {first_line!r}; must be either "
                "'#!/usr/bin/env bash' (mode 0755) or '# shellcheck shell=bash' "
                "(mode 0644, source-only)"
            )


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    errors: list[str] = []

    check_portable_operational_defaults(root, errors)
    check_shell_file_contract(root, errors)
    check_root_patch_placement(root, errors)
    check_readme_ownership(root, errors)
    check_readme_navigation(root, errors)
    check_findings_index(root, errors)
    check_findings_topic_coverage(root, errors)
    check_watchlist_pairing(root, errors)
    check_status_ledger_tracks(root, errors)
    check_status_table_layout(root, errors)
    check_kernel_package_helpers(root, errors)
    check_kernel_package_helpers(
        root, errors, KERNEL_PACKAGE_DIRS_ALL, KERNEL_PACKAGE_HELPERS_ALL
    )
    check_ppa_ffmpeg_install_pin(root, errors)
    check_ppa_grd_source_pin(root, errors)

    for error in errors:
        print(error, file=sys.stderr)
    if errors:
        print(f"documentation consistency check failed: {len(errors)} error(s)")
        return 1

    print("documentation consistency check passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
