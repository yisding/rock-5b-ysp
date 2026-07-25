#!/usr/bin/env python3
"""Check substantive drift and completeness: version pins, portable defaults, index linkage.

Deliberately excludes documentation-formatting pedantry (finding headers, entry
ordering, dashboard/ledger date-matching, support-coverage schema,
project-brief fields, terminology). It reports only things that break navigation
or ship wrong bits: unlinked/dangling findings, watchlist halves that are
missing or disagree on name/last-checked date, drifted packaging version pins,
out-of-sync kernel package helpers, and personal-home executable defaults.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

from repo_files import repository_operational_files


FINDING_NAME_RE = re.compile(r"20\d{2}-\d{2}-\d{2}-[a-z0-9][a-z0-9.-]*\.md")
WATCH_ID_RE = re.compile(r"^W\d{2}$")
WATCH_HEADING_RE = re.compile(r"^### (W\d{2}) — (.+?)\s*$")
WATCH_INDEX_NAME_RE = re.compile(r"^\[(.+)\]\(#watch-w\d{2}\)$")
WATCH_LAST_CHECKED_RE = re.compile(r"^-\s+\*\*Last checked:\*\*\s*(\d{4}-\d{2}-\d{2})")
ISO_DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
PERSONAL_HOME_DEFAULT_RE = re.compile(
    r"(?:^[A-Z][A-Z0-9_]*=[\"']?/(?:home|Users)/|"
    r"\$\{[A-Za-z_][A-Za-z0-9_]*:-[\"']?/(?:home|Users)/)"
)
KERNEL_PACKAGE_DIRS = (
    "packaging/ppa/kernel-forward-port",
    "packaging/ppa/kernel-rewrite-alpha-6.18",
    "packaging/ppa/kernel-rewrite-alpha-7.2-rc3",
)
KERNEL_PACKAGE_HELPERS = (
    "debian/scripts/install-kernel-packages.sh",
    "debian/scripts/write-maintainer-scripts.sh",
)
PPA_GRD_PIN_DOCS = (
    "packaging/ppa/README.md",
    "packaging/ppa/gnome-remote-desktop/source-deltas/README.md",
    "docs/source-trees.md",
    "packaging/external-workspaces.md",
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
    """Light completeness: every finding is linked, every link has a file.

    Intentionally does not enforce ordering, deduplication, or entry prose —
    only that no finding is invisible and no index entry dangles.
    """
    findings = root / "findings"
    readme = findings / "README.md"
    if not readme.is_file():
        return

    text = readme.read_text(encoding="utf-8", errors="replace")
    referenced = set(FINDING_NAME_RE.findall(text))
    present = {path.name for path in findings.glob("20??-??-??-*.md")}

    for name in sorted(present - referenced):
        errors.append(f"findings/README.md: {name} is not linked from the index")
    for name in sorted(referenced - present):
        if not (findings / name).is_file():
            errors.append(f"findings/README.md: index links {name} but no such file exists")


def check_watchlist_pairing(root: Path, errors: list[str]) -> None:
    """Every watchlist W## entry has both halves, agreeing on name and date.

    The two halves are maintained by hand in one file and drifted seven ways in
    under two weeks, so name and last-checked exactness is enforced rather than
    left to convention. Ordering and prose are still not policed.
    """
    path = root / "status.md"
    if not path.is_file():
        return

    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    heading = "## Watchlist — facts that go stale silently"
    if heading not in lines:
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
    """Keep PPA export, documentation, and migration on one FFmpeg version."""
    changelog_path = root / "packaging/ppa/ffmpeg/debian/changelog"
    installer_path = root / "packaging/ppa/clean-install-system-stack.sh"
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
    if installer_match.group(1) != changelog_match.group(1):
        errors.append(
            "packaging/ppa/clean-install-system-stack.sh: FFMPEG_VERSION "
            f"{installer_match.group(1)!r} does not match latest changelog "
            f"{changelog_match.group(1)!r}"
        )

    latest_version = changelog_match.group(1)
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


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    errors: list[str] = []

    check_portable_operational_defaults(root, errors)
    check_findings_index(root, errors)
    check_watchlist_pairing(root, errors)
    check_kernel_package_helpers(root, errors)
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
