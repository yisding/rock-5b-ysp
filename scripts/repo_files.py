"""Discover maintained repository files without walking ignored build trees."""

from __future__ import annotations

import os
import subprocess
from pathlib import Path


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
