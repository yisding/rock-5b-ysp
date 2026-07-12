"""Discover maintained repository files without walking ignored build trees."""

from __future__ import annotations

import os
import subprocess
from pathlib import Path


def _git_markdown_files(root: Path) -> list[Path] | None:
    """Return Git-known Markdown files, or None outside a usable Git worktree."""
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
                "*.md",
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


def _skip_directory(relative_parts: tuple[str, ...]) -> bool:
    return (
        any(
            part in {".agents", ".codex", ".git", "__pycache__"}
            for part in relative_parts
        )
        or "downloads" in relative_parts
        or relative_parts[:3] == ("packaging", "ppa", "out")
    )


def _walk_markdown_files(root: Path) -> list[Path]:
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
            directory_path / name for name in child_files if name.endswith(".md")
        )
    return sorted(files)


def repository_markdown_files(root: Path) -> list[Path]:
    """Return tracked and non-ignored untracked Markdown files under root."""
    root = root.resolve()
    git_files = _git_markdown_files(root)
    return git_files if git_files is not None else _walk_markdown_files(root)
