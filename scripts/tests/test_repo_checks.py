from __future__ import annotations

import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

from repo_files import repository_markdown_files, repository_operational_files  # noqa: E402


def load_doc_checker():
    spec = importlib.util.spec_from_file_location(
        "check_doc_consistency",
        SCRIPTS / "check-doc-consistency.py",
    )
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load check-doc-consistency.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


DOC_CHECKER = load_doc_checker()
REPO_ROOT = SCRIPTS.parent


class RepositoryMarkdownFilesTests(unittest.TestCase):
    def write(self, root: Path, relative: str, text: str = "# Test\n") -> Path:
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        return path

    def relative_files(self, root: Path) -> list[str]:
        return [
            path.relative_to(root).as_posix()
            for path in repository_markdown_files(root)
        ]

    def test_source_archive_fallback_prunes_generated_trees(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.write(root, "README.md")
            self.write(root, "docs/guide.md")
            self.write(root, "downloads/ignored.md")
            self.write(root, "packaging/ppa/out/ignored.md")

            self.assertEqual(
                self.relative_files(root),
                ["README.md", "docs/guide.md"],
            )

    def test_archive_nested_in_parent_git_tree_still_uses_fallback(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary)
            subprocess.run(
                ["git", "init", "--quiet", str(parent)],
                check=True,
            )
            root = parent / "archive"
            self.write(root, "README.md")
            self.write(root, "docs/guide.md")
            self.write(root, "downloads/ignored.md")

            self.assertEqual(
                self.relative_files(root),
                ["README.md", "docs/guide.md"],
            )

    def test_git_inventory_includes_tracked_and_nonignored_untracked_files(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            subprocess.run(
                ["git", "init", "--quiet", str(root)],
                check=True,
            )
            self.write(root, "tracked.md")
            subprocess.run(
                ["git", "-C", str(root), "add", "tracked.md"],
                check=True,
            )
            self.write(root, "untracked.md")
            self.write(root, "ignored.md")
            self.write(root, ".gitignore", "ignored.md\n")

            self.assertEqual(
                self.relative_files(root),
                ["tracked.md", "untracked.md"],
            )

    def test_operational_inventory_includes_shell_and_python_only(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.write(root, "tool.sh", "#!/usr/bin/env bash\n")
            self.write(root, "check.py", "print(\"ok\")\n")
            self.write(root, "guide.md")

            self.assertEqual(
                [path.name for path in repository_operational_files(root)],
                ["check.py", "tool.sh"],
            )


class MarkdownLinkCheckerTests(unittest.TestCase):
    def test_external_urls_are_not_counted_as_local_links(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "README.md").write_text(
                "# Top\n\n"
                "[same file](#top)\n"
                "[other file](other.md#target)\n"
                "[external](https://example.com/reference)\n",
                encoding="utf-8",
            )
            (root / "other.md").write_text("# Target\n", encoding="utf-8")

            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPTS / "check-markdown-links.py"),
                    str(root),
                ],
                check=False,
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(
                "checked 2 markdown files, 2 local links, "
                "2 local markdown anchors",
                result.stdout,
            )


class OperationalHelpTests(unittest.TestCase):
    def test_board_mutating_entry_points_have_safe_help(self) -> None:
        scripts = (
            "kernel-drivers/scripts/install-combined-kernel.sh",
            "kernel-drivers/scripts/kernel-revert.sh",
            "kernel-drivers/scripts/make-fallback-kernel-deb.sh",
            "kernel-drivers/scripts/debug-kernel/install-debug-kernel.sh",
            "kernel-drivers/scripts/debug-kernel/enable-ramoops-capture.sh",
            "kernel-drivers/scripts/debug-kernel/disable-ramoops-capture.sh",
            "kernel-drivers/scripts/debug-kernel/enable-persistent-journal.sh",
            "scripts/rock5b-spi-erase.sh",
            "scripts/rock5b-spi-restore-armbian.sh",
        )
        for relative in scripts:
            with self.subTest(script=relative):
                result = subprocess.run(
                    ["bash", str(REPO_ROOT / relative), "--help"],
                    cwd=REPO_ROOT,
                    check=False,
                    capture_output=True,
                    text=True,
                )
                output = result.stdout + result.stderr
                self.assertEqual(result.returncode, 0, output)
                self.assertIn("usage", output.casefold())


class DocumentationConsistencyTests(unittest.TestCase):
    def write_status(self, root: Path, text: str) -> None:
        (root / "status.md").write_text(text, encoding="utf-8")

    def test_valid_watchlist_index_and_detail_match(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.write_status(
                root,
                "## Watchlist — facts that go stale silently\n\n"
                "| ID | Watch item | Last checked | Summary |\n"
                "|----|------------|--------------|---------|\n"
                "| W01 | [Example](#watch-w01) | 2026-07-11 | Unchanged. |\n\n"
                '<a id="watch-w01"></a>\n'
                "### W01 — Example\n\n"
                "- **Why recheck:** External state can change.\n"
                "- **Last checked:** 2026-07-11\n"
                "- **State then:** It was unchanged.\n",
            )
            errors: list[str] = []

            DOC_CHECKER.check_watchlist(root, errors)

            self.assertEqual(errors, [])

    def test_watchlist_reports_date_mismatch_and_missing_state(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.write_status(
                root,
                "## Watchlist — facts that go stale silently\n\n"
                "| ID | Watch item | Last checked | Summary |\n"
                "|----|------------|--------------|---------|\n"
                "| W01 | [Example](#watch-w01) | 2026-07-11 | Unchanged. |\n\n"
                '<a id="watch-w01"></a>\n'
                "### W01 — Example\n\n"
                "- **Why recheck:** External state can change.\n"
                "- **Last checked:** 2026-07-10\n",
            )
            errors: list[str] = []

            DOC_CHECKER.check_watchlist(root, errors)

            self.assertTrue(any("does not match detail date" in e for e in errors))
            self.assertTrue(any("empty state field" in e for e in errors))

    def test_malformed_next_gate_row_reports_errors_without_crashing(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.write_status(
                root,
                "## Dashboard\n\n"
                "| # | Track | Public state | Verified | Detail |\n"
                "|---|-------|--------------|----------|--------|\n"
                "| 1 | Example | ✅ Works. | 2026-07-11 | detail.md |\n\n"
                "## Next gates\n\n"
                "| # | Track | Next proof |\n"
                "|---|-------|------------|\n"
                "| 1 |\n",
            )
            errors: list[str] = []

            DOC_CHECKER.check_dashboard_next_gates(root, errors)

            self.assertTrue(any("must have 4 columns" in e for e in errors))
            self.assertTrue(any("empty next gate" in e for e in errors))

    def test_next_gate_requires_linked_action_path(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.write_status(
                root,
                "## Dashboard\n\n"
                "| # | Track | Public state | Verified | Detail |\n"
                "|---|-------|--------------|----------|--------|\n"
                "| 1 | Example | ✅ Works. | 2026-07-11 | detail.md |\n\n"
                "## Next gates\n\n"
                "| # | Track | Next proof | Action path |\n"
                "|---|-------|------------|-------------|\n"
                "| 1 | Example | Re-run it. | Read the runbook. |\n",
            )
            errors: list[str] = []

            DOC_CHECKER.check_dashboard_next_gates(root, errors)

            self.assertTrue(any("action path has no Markdown link" in e for e in errors))

    def test_valid_support_coverage_schema(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            docs = root / "docs"
            docs.mkdir()
            (docs / "support-coverage.md").write_text(
                "## Coverage inventory\n\n"
                "| ID | Board area | Coverage | What the repository owns today | First useful evidence to add |\n"
                "|----|------------|----------|--------------------------------|------------------------------|\n"
                "| C01 | Example | `TRACKED` | Owner. | Run it. |\n"
                "| C02 | Other | `UNASSESSED` | None. | Capture it. |\n",
                encoding="utf-8",
            )
            errors: list[str] = []

            DOC_CHECKER.check_support_coverage(root, errors)

            self.assertEqual(errors, [])

    def test_support_coverage_reports_bad_state_order_and_empty_field(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            docs = root / "docs"
            docs.mkdir()
            (docs / "support-coverage.md").write_text(
                "## Coverage inventory\n\n"
                "| ID | Board area | Coverage | What the repository owns today | First useful evidence to add |\n"
                "|----|------------|----------|--------------------------------|------------------------------|\n"
                "| C02 | Example | `UNKNOWN` | | Run it. |\n"
                "| C01 | Other | `NARROW` | Owner. | Capture it. |\n",
                encoding="utf-8",
            )
            errors: list[str] = []

            DOC_CHECKER.check_support_coverage(root, errors)

            self.assertTrue(any("invalid coverage state" in e for e in errors))
            self.assertTrue(any("empty current owner field" in e for e in errors))
            self.assertTrue(any("coverage IDs are not ordered" in e for e in errors))

    def test_dchs_software_only_conflation_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "README.md").write_text(
                "# Test\n\nDCHS is the encoder's software-only equivalent.\n",
                encoding="utf-8",
            )
            errors: list[str] = []

            DOC_CHECKER.check_load_bearing_terminology(root, errors)

            self.assertTrue(any("DCHS is a hardware handshake" in e for e in errors))

    def test_project_brief_requires_orientation_fields_and_status_owner(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            readme = root / "project" / "README.md"
            readme.parent.mkdir()
            readme.write_text(
                "# Project\n\n"
                "| Field | Contents |\n"
                "|-------|----------|\n"
                "| Purpose | Explain it. |\n"
                "| Developer focus | Maintain it. |\n"
                "| Owns | Its docs. |\n"
                "| Current state | Works today. |\n",
                encoding="utf-8",
            )
            errors: list[str] = []

            DOC_CHECKER.check_project_briefs(
                root,
                errors,
                ("project/README.md",),
            )

            self.assertTrue(any("has no Depends on" in e for e in errors))
            self.assertTrue(any("does not link to status.md" in e for e in errors))

    def test_unindexed_operational_file_is_reported(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            scripts = root / "scripts"
            scripts.mkdir()
            (scripts / "README.md").write_text("# Scripts\n", encoding="utf-8")
            (scripts / "hidden.sh").write_text(
                "#!/usr/bin/env bash\n",
                encoding="utf-8",
            )
            errors: list[str] = []

            DOC_CHECKER.check_operational_indexes(root, errors)

            self.assertTrue(any("operational file not named" in e for e in errors))

    def test_kernel_package_helper_drift_is_reported(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for package, contents in (("one", "same\n"), ("two", "changed\n")):
                path = root / package / "helper.sh"
                path.parent.mkdir()
                path.write_text(contents, encoding="utf-8")
            errors: list[str] = []

            DOC_CHECKER.check_kernel_package_helpers(
                root,
                errors,
                ("one", "two"),
                ("helper.sh",),
            )

            self.assertTrue(any("differs from synchronized helper" in e for e in errors))


if __name__ == "__main__":
    unittest.main()
