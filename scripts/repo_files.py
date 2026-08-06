# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: GPL-2.0-or-later
"""Discover maintained repository files without walking ignored build trees."""

from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path
from urllib.parse import unquote


MARKDOWN_LINK_RE = re.compile(
    r"!?\[[^\]\n]*(?:\][^\[\]\n]*)*\]\(([^\)\n]+)\)"
)
SCHEME_RE = re.compile(r"^[a-zA-Z][a-zA-Z0-9+.-]*:")
DATED_FINDING_RE = re.compile(r"20\d{2}-\d{2}-\d{2}-.+\.md")
TOMBSTONE_RE = re.compile(r"^promoted → ", re.MULTILINE)


def _git_files(root: Path, patterns: tuple[str, ...]) -> list[Path] | None:
    """Return Git-known files matching pathspecs, or None outside Git."""
    if not (root / ".git").exists():
        return None

    try:
        result = subprocess.run(
            [
                "git",
                "-C",
                str(root),
                "ls-files",
                "--cached",
                "--others",
                "--exclude-standard",
                "-z",
                "--",
                *patterns,
            ],
            check=False,
            capture_output=True,
        )
    except OSError:
        return None

    if result.returncode != 0:
        return None

    files = [
        root / Path(os.fsdecode(raw_path))
        for raw_path in result.stdout.split(b"\0")
        if raw_path
    ]
    return sorted(path for path in files if path.is_file())


def tracked_file_modes(root: Path, pattern: str) -> list[tuple[str, str]] | None:
    """Return (index mode, repo-relative path) for tracked files, or None.

    Reads the mode from the index rather than the filesystem, because the index
    is what a fresh clone materializes. Untracked files are absent by
    construction: they have no index mode to check yet.
    """
    if not (root / ".git").exists():
        return None

    try:
        result = subprocess.run(
            ["git", "-C", str(root), "ls-files", "-s", "-z", "--", pattern],
            check=False,
            capture_output=True,
        )
    except OSError:
        return None

    if result.returncode != 0:
        return None

    entries = []
    for raw_entry in result.stdout.split(b"\0"):
        if not raw_entry:
            continue
        meta, _, relative = os.fsdecode(raw_entry).partition("\t")
        entries.append((meta.split()[0], relative))
    return sorted(entries, key=lambda entry: entry[1])


def _skip_directory(relative_parts: tuple[str, ...]) -> bool:
    return (
        any(
            part in {".agents", ".codex", ".git", "__pycache__"}
            for part in relative_parts
        )
        or "downloads" in relative_parts
        or relative_parts[:3] == ("packaging", "ppa", "out")
    )


def _walk_files(root: Path, suffixes: tuple[str, ...]) -> list[Path]:
    """Fallback for source archives: prune generated trees before descending."""
    files: list[Path] = []
    for directory, child_dirs, child_files in os.walk(root):
        directory_path = Path(directory)
        relative = directory_path.relative_to(root)
        child_dirs[:] = [
            name
            for name in child_dirs
            if not _skip_directory(relative.parts + (name,))
        ]
        files.extend(
            directory_path / name
            for name in child_files
            if name.endswith(suffixes)
        )
    return sorted(files)


def repository_files(root: Path) -> list[Path]:
    """Return every tracked or non-ignored untracked repository file."""
    root = root.resolve()
    git_files = _git_files(root, ("*",))
    return git_files if git_files is not None else _walk_files(root, ("",))


def repository_markdown_files(root: Path) -> list[Path]:
    """Return tracked and non-ignored untracked Markdown files under root."""
    root = root.resolve()
    git_files = _git_files(root, ("*.md",))
    return git_files if git_files is not None else _walk_files(root, (".md",))


def repository_operational_files(root: Path) -> list[Path]:
    """Return tracked and non-ignored untracked shell/Python tools."""
    root = root.resolve()
    git_files = _git_files(root, ("*.sh", "*.py"))
    return git_files if git_files is not None else _walk_files(root, (".sh", ".py"))


DOCUMENTED_SUFFIXES = (".md", ".sh", ".py", ".c", ".cpp", ".h")
DOCUMENTED_PATTERNS = tuple(f"*{suffix}" for suffix in DOCUMENTED_SUFFIXES)


def repository_documented_files(root: Path) -> list[Path]:
    """Return files that must be named by their nearest README.

    Prose, tools, and on-hardware reproducers alike: anything a reader could
    need to find. `debian/` subtrees are excluded because their layout is
    dictated by dpkg rather than by this repository's navigation contract.
    """
    root = root.resolve()
    git_files = _git_files(root, DOCUMENTED_PATTERNS)
    files = git_files if git_files is not None else _walk_files(root, DOCUMENTED_SUFFIXES)
    return [path for path in files if "debian" not in path.relative_to(root).parts]


def local_markdown_targets(source: Path, root: Path) -> set[Path]:
    """Resolve same-repository link targets from one Markdown document."""
    targets: set[Path] = set()
    text = source.read_text(encoding="utf-8", errors="replace")
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
        candidate = (source.parent / unquote(file_part)).resolve()
        try:
            candidate.relative_to(root)
        except ValueError:
            continue
        if candidate.is_dir():
            candidate /= "README.md"
        targets.add(candidate)
    return targets


def finding_evidence_ownership(root: Path) -> dict[Path, set[Path]]:
    """Map each temporary evidence bundle to its active dated finding owners.

    Ownership may be declared in either useful direction: a live finding links
    to material inside the bundle, or the bundle README links back to the live
    finding. Project-only links do not keep material in the intake area alive.
    """
    root = root.resolve()
    findings = root / "findings"
    evidence = findings / "evidence"
    if not evidence.is_dir():
        return {}

    maintained_files = {path.resolve() for path in repository_files(root)}
    bundle_names = set()
    for path in maintained_files:
        try:
            relative = path.relative_to(evidence.resolve())
        except ValueError:
            continue
        if len(relative.parts) >= 2:
            bundle_names.add(relative.parts[0])
    bundles = sorted(
        (evidence / name).resolve()
        for name in bundle_names
        if (evidence / name).is_dir()
    )
    ownership = {bundle: set() for bundle in bundles}
    live_findings = {
        path
        for path in maintained_files
        if path.parent == findings.resolve()
        if DATED_FINDING_RE.fullmatch(path.name)
        and not TOMBSTONE_RE.search(
            path.read_text(encoding="utf-8", errors="replace")
        )
    }

    by_name = {bundle.name: bundle for bundle in bundles}
    for finding in live_findings:
        for target in local_markdown_targets(finding, root):
            try:
                relative = target.relative_to(evidence.resolve())
            except ValueError:
                continue
            if relative.parts and relative.parts[0] in by_name:
                ownership[by_name[relative.parts[0]]].add(finding)

    for bundle in bundles:
        readme = bundle / "README.md"
        if readme.resolve() not in maintained_files:
            continue
        ownership[bundle].update(
            target
            for target in local_markdown_targets(readme, root)
            if target in live_findings
        )

    return ownership
