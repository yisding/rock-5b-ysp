#!/usr/bin/env python3
"""Check repository-specific documentation indexing and status contracts."""

from __future__ import annotations

import re
import sys
from collections import Counter
from pathlib import Path

from repo_files import repository_markdown_files, repository_operational_files


FINDING_NAME_RE = re.compile(r"20\d{2}-\d{2}-\d{2}-[a-z0-9][a-z0-9.-]*\.md")
DATE_RE = re.compile(r"20\d{2}-\d{2}-\d{2}")
WATCH_HEADING_RE = re.compile(r"^### (W\d{2}) — (.+)$")
WATCH_ID_RE = re.compile(r"^W\d{2}$")
WATCH_LINK_RE = re.compile(r"^\[(.+)\]\(#watch-(w\d{2})\)$", re.IGNORECASE)
COVERAGE_ID_RE = re.compile(r"^C\d{2}$")
COVERAGE_STATES = {"TRACKED", "NARROW", "UNASSESSED"}
MARKDOWN_LINK_RE = re.compile(r"\[[^\]]+\]\([^)]+\)")
DCHS_SOFTWARE_ONLY_RE = re.compile(
    r"(?:DCHS.{0,100}software-only|software-only.{0,100}DCHS)",
    re.IGNORECASE | re.DOTALL,
)
PERSONAL_HOME_DEFAULT_RE = re.compile(
    r"(?:^[A-Z][A-Z0-9_]*=[\"']?/(?:home|Users)/|"
    r"\$\{[A-Za-z_][A-Za-z0-9_]*:-[\"']?/(?:home|Users)/)"
)
PROJECT_BRIEF_READMES = (
    "kernel-versions/README.md",
    "kernel-drivers/README.md",
    "kernel-drivers/mpp/README.md",
    "kernel-drivers/rga/README.md",
    "kernel-drivers/av1/README.md",
    "kernel-drivers/iommu/README.md",
    "vendor-libraries/README.md",
    "vendor-libraries/mpp/README.md",
    "vendor-libraries/rga/README.md",
    "video-libraries/ffmpeg/README.md",
    "video-libraries/mesa/README.md",
    "apps/gnome-remote-desktop/README.md",
    "apps/kodi/README.md",
    "packaging/README.md",
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
TRUST_TAGS = {
    "CODE-INSPECTED",
    "COMPILE-VERIFIED",
    "CONFIG-INSPECTED",
    "CONFIRMED",
    "DESIGN",
    "HYPOTHESIS",
    "INFERRED",
    "MEASURED",
    "SOURCE-INSPECTED",
    "UNVERIFIED",
}
FINDING_TEMPLATE_MARKERS = (
    ("coverage-aware scope", "C##"),
    ("result section", "## Result"),
    ("evidence section", "## Evidence and reproduction"),
    ("identity prompt", "- **Identity:**"),
    ("detection prompt", "- **Detection:**"),
    ("exercise prompt", "- **Exercise:**"),
    ("pass/fail prompt", "- **Pass/fail signal:**"),
    ("artifact prompt", "- **Artifacts:**"),
    ("boundary section", "## Boundary"),
)


def check_readme_indexes(root: Path, errors: list[str]) -> None:
    """Require each Markdown file to be named by its nearest owning README."""
    for path in repository_markdown_files(root):
        if path.name in {"README.md", "TEMPLATE.md"}:
            continue

        owner = path.parent
        while owner != root and not (owner / "README.md").is_file():
            owner = owner.parent
        readme = owner / "README.md"
        if not readme.is_file():
            continue

        relative = path.relative_to(owner).as_posix()
        text = readme.read_text(encoding="utf-8", errors="replace")
        if relative not in text and path.name not in text:
            errors.append(
                f"{path.relative_to(root)}: not named in owning "
                f"{readme.relative_to(root)}"
            )


def check_operational_indexes(root: Path, errors: list[str]) -> None:
    """Require shell/Python tools to be named by their nearest README."""
    for path in repository_operational_files(root):
        owner = path.parent
        while owner != root and not (owner / "README.md").is_file():
            owner = owner.parent
        readme = owner / "README.md"
        if not readme.is_file():
            continue

        relative = path.relative_to(owner).as_posix()
        text = readme.read_text(encoding="utf-8", errors="replace")
        if relative not in text and path.name not in text:
            errors.append(
                f"{path.relative_to(root)}: operational file not named in owning "
                f"{readme.relative_to(root)}"
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
    """Require a complete, duplicate-free, newest-first findings index."""
    findings = root / "findings"
    readme = findings / "README.md"
    expected = {path.name for path in findings.glob("20??-??-??-*.md")}

    entries: list[str] = []
    for line in readme.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line.startswith("- "):
            continue
        match = FINDING_NAME_RE.search(line)
        if match:
            entries.append(match.group(0))

    counts = Counter(entries)
    for name in sorted(expected - set(entries)):
        errors.append(f"findings/README.md: missing index entry for {name}")
    for name in sorted(set(entries) - expected):
        errors.append(f"findings/README.md: index entry has no file: {name}")
    for name, count in sorted(counts.items()):
        if count > 1:
            errors.append(f"findings/README.md: {name} is indexed {count} times")

    dates = [name[:10] for name in entries]
    if dates != sorted(dates, reverse=True):
        errors.append("findings/README.md: index entries are not newest first")


def check_finding_template(root: Path, errors: list[str]) -> None:
    """Keep new findings aligned with the repository evidence contract."""
    path = root / "findings" / "TEMPLATE.md"
    if not path.is_file():
        errors.append("findings/TEMPLATE.md: missing finding intake template")
        return

    text = path.read_text(encoding="utf-8", errors="replace")
    for label, marker in FINDING_TEMPLATE_MARKERS:
        if marker not in text:
            errors.append(f"findings/TEMPLATE.md: missing {label} ({marker})")


def check_finding_headers(root: Path, errors: list[str]) -> None:
    """Validate metadata on active findings; promoted files are tombstones."""
    for path in sorted((root / "findings").glob("20??-??-??-*.md")):
        text = path.read_text(encoding="utf-8", errors="replace")
        if "promoted →" in text[:500]:
            continue

        header = text[:1500]
        for field in ("Scope", "Source", "Date", "Trust"):
            if f"> {field}:" not in header:
                errors.append(
                    f"{path.relative_to(root)}: active finding has no {field} header"
                )

        date_match = re.search(r"^> Date:\s*(20\d{2}-\d{2}-\d{2})", header, re.MULTILINE)
        if date_match and date_match.group(1) != path.name[:10]:
            errors.append(
                f"{path.relative_to(root)}: header date {date_match.group(1)} "
                f"does not match filename date {path.name[:10]}"
            )

        trust_start = header.find("> Trust:")
        trust_block = (
            header[trust_start:].split("\n\n", 1)[0] if trust_start >= 0 else ""
        )
        if trust_start >= 0 and not any(tag in trust_block for tag in TRUST_TAGS):
            errors.append(
                f"{path.relative_to(root)}: Trust header has no documented tag"
            )


def status_rows(path: Path, errors: list[str]) -> dict[int, tuple[str, str]]:
    """Extract numbered track name/date pairs from a status table."""
    rows: dict[int, tuple[str, str]] = {}
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line.startswith("|"):
            continue
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if len(cells) < 5 or not cells[0].isdigit():
            continue
        verified = next((cell for cell in cells[2:] if DATE_RE.fullmatch(cell)), None)
        if verified is None:
            continue
        number = int(cells[0])
        if number in rows:
            errors.append(f"{path.name}: duplicate status track {number}")
        rows[number] = (cells[1], verified)
    return rows


def check_status_ledger(root: Path, errors: list[str]) -> None:
    """Keep dashboard and audit-ledger track identities and dates aligned."""
    dashboard = status_rows(root / "status.md", errors)
    ledger = status_rows(root / "docs" / "status-ledger.md", errors)

    if not dashboard:
        errors.append("status.md: no numbered dashboard tracks found")
    if not ledger:
        errors.append("docs/status-ledger.md: no numbered ledger tracks found")

    for number in sorted(dashboard.keys() | ledger.keys()):
        if number not in dashboard:
            errors.append(f"docs/status-ledger.md: track {number} is absent from status.md")
            continue
        if number not in ledger:
            errors.append(f"status.md: track {number} is absent from docs/status-ledger.md")
            continue
        dashboard_name, dashboard_date = dashboard[number]
        ledger_name, ledger_date = ledger[number]
        if (
            dashboard_name.casefold() != ledger_name.casefold()
            or dashboard_date != ledger_date
        ):
            errors.append(
                f"status track {number}: dashboard {dashboard[number]!r} "
                f"does not match ledger {ledger[number]!r}"
            )


def section_table_rows(
    path: Path,
    heading: str,
    expected_columns: int,
    errors: list[str],
) -> dict[int, list[str]]:
    """Extract and validate numbered Markdown table rows under one heading."""
    in_section = False
    rows: dict[int, list[str]] = {}
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if line == heading:
            in_section = True
            continue
        if in_section and line.startswith("## "):
            break
        if not in_section or not line.startswith("|"):
            continue

        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if not cells[0].isdigit():
            continue
        number = int(cells[0])
        if len(cells) != expected_columns:
            errors.append(
                f"{path.name} {heading}: track {number} must have "
                f"{expected_columns} columns"
            )
            if len(cells) < expected_columns:
                cells.extend([""] * (expected_columns - len(cells)))
        if number in rows:
            errors.append(f"{path.name} {heading}: duplicate track {number}")
        rows[number] = cells
    if not rows:
        errors.append(f"{path.name}: no numbered rows found under {heading}")
    return rows


def check_dashboard_next_gates(root: Path, errors: list[str]) -> None:
    """Keep compact dashboard rows and their next-gate rows in lockstep."""
    path = root / "status.md"
    dashboard = section_table_rows(path, "## Dashboard", 5, errors)
    gates = section_table_rows(path, "## Next gates", 4, errors)

    for number in sorted(dashboard.keys() | gates.keys()):
        if number not in dashboard:
            errors.append(f"status.md: next gate {number} has no dashboard track")
            continue
        if number not in gates:
            errors.append(f"status.md: dashboard track {number} has no next gate")
            continue
        if dashboard[number][1] != gates[number][1]:
            errors.append(
                f"status.md: dashboard track {number} name "
                f"{dashboard[number][1]!r} does not match next-gate name "
                f"{gates[number][1]!r}"
            )
        if not gates[number][2]:
            errors.append(f"status.md: track {number} has an empty next gate")
        if not gates[number][3]:
            errors.append(f"status.md: track {number} has an empty action path")
        elif not MARKDOWN_LINK_RE.search(gates[number][3]):
            errors.append(
                f"status.md: track {number} action path has no Markdown link"
            )
        if not dashboard[number][1]:
            errors.append(f"status.md: dashboard track {number} has no name")
        if not dashboard[number][2]:
            errors.append(f"status.md: dashboard track {number} has no public state")
        if not DATE_RE.fullmatch(dashboard[number][3]):
            errors.append(
                f"status.md: dashboard track {number} has invalid verification date "
                f"{dashboard[number][3]!r}"
            )
        if not dashboard[number][4]:
            errors.append(f"status.md: dashboard track {number} has no detail link")


def check_watchlist(root: Path, errors: list[str]) -> None:
    """Keep the compact watchlist index and dated detail blocks synchronized."""
    path = root / "status.md"
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    heading = "## Watchlist — facts that go stale silently"
    try:
        start = lines.index(heading) + 1
    except ValueError:
        errors.append(f"status.md: missing {heading}")
        return

    section: list[str] = []
    for line in lines[start:]:
        if line.startswith("## "):
            break
        section.append(line)

    index_order: list[str] = []
    index: dict[str, tuple[str, str]] = {}
    for line in section:
        if not line.startswith("|"):
            continue
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if not cells or not WATCH_ID_RE.fullmatch(cells[0]):
            continue
        watch_id = cells[0]
        if len(cells) != 4:
            errors.append(f"status.md watchlist {watch_id}: index row must have 4 columns")
            if len(cells) < 4:
                cells.extend([""] * (4 - len(cells)))
        link = WATCH_LINK_RE.fullmatch(cells[1])
        if not link:
            errors.append(
                f"status.md watchlist {watch_id}: item must link to #watch-{watch_id.lower()}"
            )
            name = cells[1]
        else:
            name = link.group(1)
            if link.group(2).upper() != watch_id:
                errors.append(
                    f"status.md watchlist {watch_id}: link targets {link.group(2).upper()}"
                )
        if not DATE_RE.fullmatch(cells[2]):
            errors.append(
                f"status.md watchlist {watch_id}: invalid index date {cells[2]!r}"
            )
        if not cells[3]:
            errors.append(f"status.md watchlist {watch_id}: empty summary")
        if watch_id in index:
            errors.append(f"status.md watchlist: duplicate index ID {watch_id}")
        index_order.append(watch_id)
        index[watch_id] = (name, cells[2])

    details_order: list[str] = []
    details: dict[str, dict[str, str]] = {}
    current_id: str | None = None
    for line in section:
        detail_heading = WATCH_HEADING_RE.fullmatch(line)
        if detail_heading:
            current_id = detail_heading.group(1)
            if current_id in details:
                errors.append(f"status.md watchlist: duplicate detail ID {current_id}")
            details_order.append(current_id)
            details[current_id] = {"name": detail_heading.group(2)}
            continue
        if current_id is None:
            continue
        for field, prefix in (
            ("why", "- **Why recheck:**"),
            ("date", "- **Last checked:**"),
            ("state", "- **State then:**"),
        ):
            if line.startswith(prefix):
                value = line[len(prefix) :].strip()
                if field in details[current_id]:
                    errors.append(
                        f"status.md watchlist {current_id}: duplicate {field} field"
                    )
                details[current_id][field] = value

    if not index:
        errors.append("status.md: watchlist index has no items")
    if index_order != sorted(index_order):
        errors.append("status.md: watchlist index IDs are not ordered")
    if details_order != index_order:
        errors.append(
            "status.md: watchlist detail order does not match the compact index"
        )

    for watch_id in sorted(index.keys() | details.keys()):
        if watch_id not in index:
            errors.append(f"status.md: watchlist detail {watch_id} has no index row")
            continue
        if watch_id not in details:
            errors.append(f"status.md: watchlist index {watch_id} has no detail block")
            continue
        detail = details[watch_id]
        if detail.get("name") != index[watch_id][0]:
            errors.append(
                f"status.md watchlist {watch_id}: index name {index[watch_id][0]!r} "
                f"does not match detail name {detail.get('name')!r}"
            )
        if detail.get("date") != index[watch_id][1]:
            errors.append(
                f"status.md watchlist {watch_id}: index date {index[watch_id][1]!r} "
                f"does not match detail date {detail.get('date')!r}"
            )
        for field in ("why", "date", "state"):
            if not detail.get(field):
                errors.append(
                    f"status.md watchlist {watch_id}: missing or empty {field} field"
                )


def check_support_coverage(root: Path, errors: list[str]) -> None:
    """Validate stable IDs and the small schema of the coverage inventory."""
    path = root / "docs" / "support-coverage.md"
    if not path.is_file():
        errors.append("docs/support-coverage.md: missing coverage inventory")
        return

    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    heading = "## Coverage inventory"
    try:
        start = lines.index(heading) + 1
    except ValueError:
        errors.append(f"docs/support-coverage.md: missing {heading}")
        return

    rows: dict[str, list[str]] = {}
    order: list[str] = []
    for line in lines[start:]:
        if line.startswith("## "):
            break
        if not line.startswith("|"):
            continue
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if not cells or not COVERAGE_ID_RE.fullmatch(cells[0]):
            continue

        coverage_id = cells[0]
        if len(cells) != 5:
            errors.append(
                f"docs/support-coverage.md {coverage_id}: row must have 5 columns"
            )
            if len(cells) < 5:
                cells.extend([""] * (5 - len(cells)))
        if coverage_id in rows:
            errors.append(
                f"docs/support-coverage.md: duplicate coverage ID {coverage_id}"
            )
        rows[coverage_id] = cells
        order.append(coverage_id)

        state = cells[2].strip("`")
        if state not in COVERAGE_STATES:
            errors.append(
                f"docs/support-coverage.md {coverage_id}: invalid coverage state "
                f"{cells[2]!r}"
            )
        for index, field in ((1, "board area"), (3, "current owner"), (4, "first evidence")):
            if not cells[index]:
                errors.append(
                    f"docs/support-coverage.md {coverage_id}: empty {field} field"
                )

    if not rows:
        errors.append("docs/support-coverage.md: coverage inventory has no rows")
        return
    if order != sorted(order):
        errors.append("docs/support-coverage.md: coverage IDs are not ordered")


def check_load_bearing_terminology(root: Path, errors: list[str]) -> None:
    """Reject a known encoder-coordination conflation in maintained prose."""
    for path in repository_markdown_files(root):
        text = path.read_text(encoding="utf-8", errors="replace")
        if DCHS_SOFTWARE_ONLY_RE.search(text):
            errors.append(
                f"{path.relative_to(root)}: DCHS is a hardware handshake; only "
                "the encoder's virtual CCU/coordinator is software-only"
            )


def check_project_briefs(
    root: Path,
    errors: list[str],
    readmes: tuple[str, ...] = PROJECT_BRIEF_READMES,
) -> None:
    """Require each project front door to answer the orientation questions."""
    recognized = {
        "Purpose",
        "User outcome",
        "Developer focus",
        "Owns",
        "Depends on",
        "Current state",
    }
    for relative in readmes:
        path = root / relative
        if not path.is_file():
            errors.append(f"{relative}: missing project front door")
            continue

        fields: dict[str, str] = {}
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            if not line.startswith("|"):
                continue
            cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
            if len(cells) < 2 or cells[0] not in recognized:
                continue
            if cells[0] in fields:
                errors.append(f"{relative}: duplicate project brief field {cells[0]}")
            fields[cells[0]] = cells[1]

        if not fields.get("Purpose") and not fields.get("User outcome"):
            errors.append(f"{relative}: project brief has no purpose/user outcome")
        for field in ("Developer focus", "Owns", "Depends on", "Current state"):
            if not fields.get(field):
                errors.append(f"{relative}: project brief has no {field}")
        if fields.get("Current state") and "status.md" not in fields["Current state"]:
            errors.append(f"{relative}: Current state does not link to status.md")


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


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    errors: list[str] = []

    check_readme_indexes(root, errors)
    check_operational_indexes(root, errors)
    check_portable_operational_defaults(root, errors)
    check_findings_index(root, errors)
    check_finding_template(root, errors)
    check_finding_headers(root, errors)
    check_status_ledger(root, errors)
    check_dashboard_next_gates(root, errors)
    check_watchlist(root, errors)
    check_support_coverage(root, errors)
    check_load_bearing_terminology(root, errors)
    check_project_briefs(root, errors)
    check_kernel_package_helpers(root, errors)
    check_ppa_ffmpeg_install_pin(root, errors)

    for error in errors:
        print(error, file=sys.stderr)
    if errors:
        print(f"documentation consistency check failed: {len(errors)} error(s)")
        return 1

    print("documentation consistency check passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
