# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: GPL-2.0-or-later
from __future__ import annotations

import importlib.util
import os
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path


SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

from repo_files import (  # noqa: E402
    repository_files,
    repository_markdown_files,
    repository_operational_files,
)


# The rewrite source-audit cases each drive the real audit over a synthetic
# C tree, which costs seconds per invocation and minutes across the class --
# far more than every other test here combined.  They guard driver-source
# contracts, so nothing below them changes when only documentation moves.
# check-repo.sh sets this when the audit, its baseline, or the rewrite driver
# sources are among the changed files; pass --all to force it.
SLOW_SOURCE_AUDIT = os.environ.get("REPO_CHECK_SOURCE_AUDIT") == "1"

source_audit_test = unittest.skipUnless(
    SLOW_SOURCE_AUDIT,
    "source-audit case is opt-in: set REPO_CHECK_SOURCE_AUDIT=1, or run "
    "scripts/check-repo.sh --all",
)


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


def load_duplication_reporter():
    spec = importlib.util.spec_from_file_location(
        "report_doc_duplication",
        SCRIPTS / "report-doc-duplication.py",
    )
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load report-doc-duplication.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


DUPLICATION_REPORTER = load_duplication_reporter()


def load_findings_indexer():
    spec = importlib.util.spec_from_file_location(
        "update_findings_index",
        SCRIPTS / "update-findings-index.py",
    )
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load update-findings-index.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


FINDINGS_INDEXER = load_findings_indexer()
REPO_ROOT = SCRIPTS.parent
KERNEL_ARTIFACT_PRUNER = (
    REPO_ROOT / "kernel-drivers/scripts/prune-kernel-artifacts.py"
)
ARMBIAN_DOCKER_CLEANER = (
    REPO_ROOT / "kernel-drivers/scripts/docker-clean-armbian-state.sh"
)
PPA_ARMBIAN_SETUP = (
    REPO_ROOT / "kernel-drivers/scripts/setup-ppa-armbian-worktree.sh"
)


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

    def test_all_file_inventory_excludes_ignored_material(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            subprocess.run(["git", "init", "--quiet", str(root)], check=True)
            self.write(root, ".gitignore", "private/\n")
            self.write(root, "public/result.txt", "public\n")
            self.write(root, "private/result.txt", "private\n")

            self.assertEqual(
                [path.relative_to(root).as_posix() for path in repository_files(root)],
                [".gitignore", "public/result.txt"],
            )


class DocumentationDuplicationReportTests(unittest.TestCase):
    def test_report_finds_all_four_informational_signal_types(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            first = root / "one.md"
            second = root / "two.md"
            shared = (
                "This deliberately long sentence contains enough distinct words to "
                "exercise the exact duplicate detector across two maintained project "
                "documents without depending on a short generic phrase."
            )
            paragraph = (
                "Alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu "
                "nu xi omicron pi rho sigma tau upsilon phi chi psi omega one two "
                "three four five six seven eight nine ten eleven twelve thirteen."
            )
            first.write_text(
                f"# One\n\n{shared}\n\n{paragraph}\n\n"
                "The current pin is 1.2.3 at abcdef0123456789.\n",
                encoding="utf-8",
            )
            second.write_text(
                f"# Two\n\n{shared}\n\n{paragraph.replace('thirteen', 'fourteen')}\n\n"
                "As of review, use 1.2.3 at abcdef0123456789.\n",
                encoding="utf-8",
            )

            report = DUPLICATION_REPORTER.build_report(root)

            self.assertEqual(report["summary"]["identical_long_sentence_groups"], 1)
            self.assertEqual(report["summary"]["similar_paragraph_pairs"], 1)
            self.assertEqual(report["summary"]["repeated_version_or_sha_literals"], 2)
            self.assertEqual(report["summary"]["time_language_occurrences"], 2)

    def test_status_and_dated_findings_own_time_bounded_language(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            findings = root / "findings"
            findings.mkdir()
            (root / "status.md").write_text("Currently measured.\n", encoding="utf-8")
            (findings / "2026-01-01-result.md").write_text(
                "# Result\n\nAs of the run, this passed.\n", encoding="utf-8"
            )

            report = DUPLICATION_REPORTER.build_report(root)

            self.assertEqual(report["summary"]["time_language_occurrences"], 0)

    def test_owner_review_signals_remain_informational(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle = root / "findings" / "evidence" / "orphan"
            bundle.mkdir(parents=True)
            (bundle / "README.md").write_text(
                "# Orphan\n\n[Promoted owner](../../../project.md)\n",
                encoding="utf-8",
            )
            (root / "project.md").write_text("# Project\n", encoding="utf-8")
            (root / "status.md").write_text(
                "## Dashboard\n\n"
                "| # | Track | State |\n"
                "|---|-------|-------|\n"
                "| 1 | Wide row | [A](a.md) [B](b.md) [C](c.md) [D](d.md) |\n"
                "\n## Next gates\n",
                encoding="utf-8",
            )

            report = DUPLICATION_REPORTER.build_report(root)

            self.assertEqual(
                report["summary"]["unowned_finding_evidence_bundles"], 1
            )
            self.assertEqual(report["summary"]["dashboard_rows_with_many_routes"], 1)
            self.assertGreater(
                report["summary"]["project_front_doors_with_brief_gaps"], 0
            )

    def test_owner_report_does_not_scan_ignored_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            subprocess.run(["git", "init", "--quiet", str(root)], check=True)
            (root / ".gitignore").write_text(
                "findings/evidence/private/\n", encoding="utf-8"
            )
            bundle = root / "findings" / "evidence" / "private"
            bundle.mkdir(parents=True)
            (bundle / "README.md").write_text("# Private\n", encoding="utf-8")

            report = DUPLICATION_REPORTER.build_report(root)

            self.assertEqual(
                report["summary"]["unowned_finding_evidence_bundles"], 0
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

    def test_link_climbing_out_of_the_repository_is_reported(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "repo"
            (root / "nested").mkdir(parents=True)
            # The escaping target is made to exist outside the repository so the
            # check cannot pass merely because the path is missing on this box.
            (Path(temporary) / "outside.md").write_text("# Outside\n", encoding="utf-8")
            (root / "nested" / "page.md").write_text(
                "# Page\n\n[climbs out](../../outside.md)\n",
                encoding="utf-8",
            )

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

            self.assertEqual(result.returncode, 1, result.stdout)
            self.assertIn("link escapes repository", result.stderr)
            self.assertIn("checked 1 markdown files, 0 local links", result.stdout)


class OperationalHelpTests(unittest.TestCase):
    def test_board_mutating_entry_points_have_safe_help(self) -> None:
        scripts = (
            "kernel-drivers/scripts/install-kernel.sh",
            "kernel-drivers/scripts/install-combined-kernel.sh",
            "kernel-drivers/scripts/kernel-revert.sh",
            "kernel-drivers/scripts/make-fallback-kernel-deb.sh",
            "kernel-drivers/scripts/debug-kernel/enable-ramoops-capture.sh",
            "kernel-drivers/scripts/debug-kernel/disable-ramoops-capture.sh",
            "kernel-drivers/scripts/debug-kernel/enable-persistent-journal.sh",
            "scripts/rock5b-oom-protection-apply.sh",
            "scripts/rock5b-passive-cooling-apply.sh",
            "scripts/rock5b-passive-cooling-revert.sh",
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

    def test_system_collector_help_and_redaction_selftest(self) -> None:
        collector = (
            REPO_ROOT
            / "kernel-drivers/tests/conformance/scripts/collect-system-info.sh"
        )
        for argument, expected in (
            ("--help", "usage"),
            ("--selftest", "self-test passed"),
        ):
            with self.subTest(argument=argument):
                result = subprocess.run(
                    ["bash", str(collector), argument],
                    cwd=REPO_ROOT,
                    check=False,
                    capture_output=True,
                    text=True,
                )
                output = result.stdout + result.stderr
                self.assertEqual(result.returncode, 0, output)
                self.assertIn(expected, output.casefold())

        traversal = subprocess.run(
            ["bash", str(collector), "../outside"],
            cwd=REPO_ROOT,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(traversal.returncode, 2)
        self.assertIn("invalid profile", traversal.stderr.casefold())

    def test_packaging_entry_points_explain_portable_source_defaults(self) -> None:
        scripts = (
            "packaging/dkms/build-deb.sh",
            "packaging/ffmpeg-rockchip81/build-deb.sh",
            "packaging/ppa/build-source-packages.sh",
        )
        with tempfile.TemporaryDirectory() as workspace:
            environment = os.environ.copy()
            environment["WORKSPACE_ROOT"] = workspace
            for relative in scripts:
                with self.subTest(script=relative):
                    result = subprocess.run(
                        ["bash", str(REPO_ROOT / relative), "--help"],
                        cwd=REPO_ROOT,
                        env=environment,
                        check=False,
                        capture_output=True,
                        text=True,
                    )
                    output = result.stdout + result.stderr
                    self.assertEqual(result.returncode, 0, output)
                    self.assertIn("usage", output.casefold())
                    self.assertIn("workspace_root", output.casefold())
                    self.assertNotIn("/home/yi/", output)


class KernelArtifactRetentionTests(unittest.TestCase):
    def run_pruner(
        self, armbian_build: Path, *arguments: str
    ) -> subprocess.CompletedProcess:
        return subprocess.run(
            [
                sys.executable,
                str(KERNEL_ARTIFACT_PRUNER),
                "--armbian-build",
                str(armbian_build),
                "--min-age-hours",
                "0",
                *arguments,
            ],
            cwd=REPO_ROOT,
            check=False,
            capture_output=True,
            text=True,
        )

    def artifact(self, armbian_build: Path, build: str) -> Path:
        path = (
            armbian_build
            / "output/debs"
            / (
                "linux-image-test-slot-rockchip64_26.08.0-trunk_arm64__"
                f"{build}.deb"
            )
        )
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"fixture")
        return path

    def test_apply_keeps_newest_group_and_removes_older_group(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            armbian_build = Path(temporary) / "armbian-build"
            old = self.artifact(armbian_build, "6.18.41-Sold-P1111-C1111")
            new = self.artifact(armbian_build, "6.18.42-Snew-P2222-C2222")
            os.utime(old, (100, 100))
            os.utime(new, (200, 200))

            dry_run = self.run_pruner(armbian_build, "--keep", "1")
            self.assertEqual(dry_run.returncode, 0, dry_run.stderr)
            self.assertIn("DELETE test-slot-rockchip64", dry_run.stdout)
            self.assertIn("Dry run only", dry_run.stdout)
            self.assertTrue(old.exists())
            self.assertTrue(new.exists())

            applied = self.run_pruner(armbian_build, "--keep", "1", "--apply")
            self.assertEqual(applied.returncode, 0, applied.stderr)
            self.assertFalse(old.exists())
            self.assertTrue(new.exists())

    def test_explicit_protection_preserves_old_group(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            armbian_build = Path(temporary) / "armbian-build"
            old = self.artifact(armbian_build, "6.18.41-Sold-P1111-C1111")
            new = self.artifact(armbian_build, "6.18.42-Snew-P2222-C2222")
            os.utime(old, (100, 100))
            os.utime(new, (200, 200))

            result = self.run_pruner(
                armbian_build,
                "--keep",
                "1",
                "--protect",
                "P1111-C1111",
                "--apply",
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(old.exists())
            self.assertTrue(new.exists())

    def test_empty_hashed_tar_is_an_orphan_not_a_recoverable_group(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            armbian_build = Path(temporary) / "armbian-build"
            tar_path = (
                armbian_build
                / "output/packages-hashed"
                / (
                    "kernel-rockchip64-test-slot_"
                    "6.18.42-Sempty-P0000-C0000_arm64.tar"
                )
            )
            tar_path.parent.mkdir(parents=True, exist_ok=True)
            with tarfile.open(tar_path, mode="w"):
                pass

            result = self.run_pruner(armbian_build, "--keep", "2")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("orphaned partial group", result.stdout)
            self.assertIn("delete 1 groups", result.stdout)

    def test_retired_slot_does_not_keep_its_newest_group(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            armbian_build = Path(temporary) / "armbian-build"
            artifact = self.artifact(
                armbian_build, "6.18.42-Sretired-P3333-C3333"
            )

            result = self.run_pruner(
                armbian_build,
                "--drop-slot",
                "test-slot-rockchip64",
                "--apply",
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("retired slot", result.stdout)
            self.assertFalse(artifact.exists())

    def test_docker_apply_uses_the_same_retention_plan(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            armbian_build = root / "armbian-build"
            old = self.artifact(armbian_build, "6.18.41-Sold-P1111-C1111")
            new = self.artifact(armbian_build, "6.18.42-Snew-P2222-C2222")
            os.utime(old, (100, 100))
            os.utime(new, (200, 200))
            cleaner = root / "fake-docker-cleaner.sh"
            cleaner.write_text(
                "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                "armbian=\n"
                "while [ $# -gt 0 ]; do\n"
                "  case $1 in\n"
                "    --armbian-build) armbian=$2; shift 2 ;;\n"
                "    --apply) shift ;;\n"
                "    artifacts) shift; break ;;\n"
                "    *) exit 2 ;;\n"
                "  esac\n"
                "done\n"
                "for relative in \"$@\"; do rm -f -- \"$armbian/$relative\"; done\n",
                encoding="utf-8",
            )
            cleaner.chmod(0o755)

            result = self.run_pruner(
                armbian_build,
                "--keep",
                "1",
                "--docker-apply",
                "--docker-cleaner",
                str(cleaner),
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(old.exists())
            self.assertTrue(new.exists())
            self.assertIn("via the Armbian Docker image", result.stdout)


class ArmbianDockerCleanerTests(unittest.TestCase):
    def run_cleaner(
        self, armbian_build: Path, *arguments: str
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                "bash",
                str(ARMBIAN_DOCKER_CLEANER),
                "--armbian-build",
                str(armbian_build),
                *arguments,
            ],
            cwd=REPO_ROOT,
            check=False,
            capture_output=True,
            text=True,
        )

    def test_artifact_cleanup_is_dry_run_by_default(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            armbian_build = Path(temporary) / "armbian-build"
            artifact = armbian_build / "output/debs/root-owned.deb"
            artifact.parent.mkdir(parents=True)
            artifact.write_bytes(b"fixture")

            result = self.run_cleaner(
                armbian_build,
                "artifacts",
                "output/debs/root-owned.deb",
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(artifact.exists())
            self.assertIn("dry run only", result.stdout)

    def test_artifact_cleanup_rejects_traversal(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            armbian_build = Path(temporary) / "armbian-build"
            (armbian_build / "output/debs").mkdir(parents=True)

            result = self.run_cleaner(
                armbian_build,
                "artifacts",
                "output/debs/../outside",
            )

            self.assertEqual(result.returncode, 2)
            self.assertIn("outside the allowlist", result.stderr)

    def test_worktree_cleanup_rejects_non_armbian_lane_names(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            armbian_build = Path(temporary) / "armbian-build"
            armbian_build.mkdir(parents=True)

            result = self.run_cleaner(
                armbian_build,
                "worktree",
                "scratch-or-parent-directory",
            )

            self.assertEqual(result.returncode, 2)
            self.assertIn("invalid kernel worktree lane", result.stderr)

    def test_container_has_a_narrow_runtime_and_mount_surface(self) -> None:
        cleaner = ARMBIAN_DOCKER_CLEANER.read_text(encoding="utf-8")

        self.assertIn("--network none", cleaner)
        self.assertIn("--read-only", cleaner)
        self.assertIn("--cap-drop ALL", cleaner)
        self.assertIn("--cap-add DAC_OVERRIDE", cleaner)
        self.assertIn("src=$ARMBIAN_BUILD/output,dst=/armbian/output", cleaner)
        self.assertIn("src=$ARMBIAN_BUILD/cache,dst=/armbian/cache", cleaner)
        self.assertIn('"armbian-build-ppa"', cleaner)
        self.assertIn(".ysp-armbian-build-ppa.lock", cleaner)


class PpaArmbianWorktreeTests(unittest.TestCase):
    def run_setup(
        self, workspace: Path, *arguments: str
    ) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment["WORKSPACE"] = str(workspace)
        return subprocess.run(
            ["bash", str(PPA_ARMBIAN_SETUP), *arguments],
            cwd=REPO_ROOT,
            env=environment,
            check=False,
            capture_output=True,
            text=True,
        )

    def make_primary(self, workspace: Path) -> Path:
        primary = workspace / "armbian-build"
        primary.mkdir(parents=True)
        subprocess.run(["git", "init", "--quiet", str(primary)], check=True)
        subprocess.run(
            ["git", "-C", str(primary), "config", "user.email", "test@example.com"],
            check=True,
        )
        subprocess.run(
            ["git", "-C", str(primary), "config", "user.name", "Test"],
            check=True,
        )
        (primary / "tracked").write_text("one\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(primary), "add", "tracked"], check=True)
        subprocess.run(
            ["git", "-C", str(primary), "commit", "--quiet", "-m", "initial"],
            check=True,
        )
        return primary

    def test_setup_creates_synced_worktree_with_shared_cache_only(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary) / "kernel-build"
            primary = self.make_primary(workspace)

            result = self.run_setup(workspace)
            self.assertEqual(result.returncode, 0, result.stderr)

            ppa = workspace / "armbian-build-ppa"
            self.assertEqual(
                subprocess.run(
                    ["git", "-C", str(ppa), "rev-parse", "HEAD"],
                    check=True,
                    capture_output=True,
                    text=True,
                ).stdout,
                subprocess.run(
                    ["git", "-C", str(primary), "rev-parse", "HEAD"],
                    check=True,
                    capture_output=True,
                    text=True,
                ).stdout,
            )
            self.assertTrue((ppa / "cache").is_symlink())
            self.assertEqual((ppa / "cache").resolve(), (primary / "cache").resolve())
            self.assertTrue((ppa / "output").is_dir())
            self.assertFalse((ppa / "output").is_symlink())

            checked = self.run_setup(workspace, "--check")
            self.assertEqual(checked.returncode, 0, checked.stderr)

    def test_check_reports_missing_track_without_creating_state(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary) / "kernel-build"
            self.make_primary(workspace)

            result = self.run_setup(workspace, "--check")
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn("MISSING PPA Armbian worktree", result.stdout)
            self.assertFalse((workspace / "armbian-build-ppa").exists())
            self.assertFalse(
                (workspace / ".ysp-armbian-worktree-setup.lock").exists()
            )

    def test_setup_refuses_to_advance_a_dirty_ppa_worktree(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary) / "kernel-build"
            primary = self.make_primary(workspace)
            self.assertEqual(self.run_setup(workspace).returncode, 0)
            ppa = workspace / "armbian-build-ppa"

            (ppa / "tracked").write_text("dirty\n", encoding="utf-8")
            (primary / "tracked").write_text("two\n", encoding="utf-8")
            subprocess.run(["git", "-C", str(primary), "add", "tracked"], check=True)
            subprocess.run(
                ["git", "-C", str(primary), "commit", "--quiet", "-m", "next"],
                check=True,
            )

            result = self.run_setup(workspace)
            self.assertEqual(result.returncode, 2)
            self.assertIn("tracked modifications", result.stderr)


class WorkspaceDefaultTests(unittest.TestCase):
    def shell_text(self, relative: str) -> str:
        return (REPO_ROOT / relative).read_text(encoding="utf-8")

    def test_operational_defaults_do_not_use_pre_grouping_paths(self) -> None:
        stale_fragments = (
            "$REPO_ROOT/../" + "rockchip-conformance",
            "$CODE/" + "kernel/",
            "$CODE_ROOT/" + "kernel/",
            "$CODE_ROOT/" + "armbian/",
            "$CODE_ROOT/" + "fdo/",
            "$HOME/Code/" + "fdo/",
            "$ROOT_DIR/../" + "kernel/",
            "$ROOT_DIR/../" + "rockchip-userspace/",
            "/home/yi/Code/" + "fdo/",
        )

        for path in repository_operational_files(REPO_ROOT):
            if path.suffix != ".sh":
                continue
            text = path.read_text(encoding="utf-8")
            relative = path.relative_to(REPO_ROOT)
            for fragment in stale_fragments:
                with self.subTest(script=str(relative), fragment=fragment):
                    self.assertNotIn(fragment, text)

    def test_external_defaults_share_one_grouped_workspace_root(self) -> None:
        expected_defaults = {
            "kernel-drivers/tests/mpp-suite.sh": (
                'CONFORMANCE_ROOT=${CONFORMANCE_ROOT:-'
                '"$ROCK5B_WORKSPACE/build/rockchip-conformance"}'
            ),
            "kernel-drivers/scripts/build-kernel.sh": (
                'WORKSPACE="${WORKSPACE:-'
                '$ROCK5B_WORKSPACE/build/kernel/rock5b-kernel-build}"'
            ),
            "packaging/ppa/build-source-packages.sh": (
                'WORKSPACE_ROOT="$(cd "${WORKSPACE_ROOT:-'
                '$ROCK5B_WORKSPACE}" && pwd)"'
            ),
            "video-libraries/mesa/scripts/mesa-panfrost-env.sh": (
                ': "${MESA_BUILD:='
                '$ROCK5B_WORKSPACE/build/mesa/build-codex-main}"'
            ),
            "apps/gnome-remote-desktop/bench/"
            "rkmpp_lifecycle_experiment.sh": (
                'OUT_ROOT=${RKMPP_LIFECYCLE_OUT_ROOT:-'
                '"$ROCK5B_WORKSPACE/build/mpp/rkmpp-lifecycle-runs"}'
            ),
        }

        for relative, expected in expected_defaults.items():
            with self.subTest(script=relative):
                text = self.shell_text(relative)
                self.assertIn("ROCK5B_WORKSPACE", text)
                self.assertIn(expected, text)

        mesa_env = self.shell_text(
            "video-libraries/mesa/scripts/mesa-panfrost-env.sh"
        )
        self.assertIn(
            ': "${ROCK5B_WORKSPACE:=$__MESA_YSP_ROOT/../rock-5b}"',
            mesa_env,
        )

    def test_forward_port_ppa_uses_a_dedicated_armbian_lane(self) -> None:
        wrapper = self.shell_text("kernel-drivers/scripts/build-kernel.sh")
        exporter = self.shell_text("packaging/ppa/build-source-packages.sh")

        self.assertIn('PPA_ARMBIAN_BUILD="${PPA_ARMBIAN_BUILD:-', wrapper)
        self.assertIn("setup-ppa-armbian-worktree.sh", wrapper)
        self.assertIn(".ysp-armbian-build-ppa.lock", wrapper)
        self.assertIn("unmanaged $LEGACY_LIBCONFIG", wrapper)
        self.assertIn('PPA_WORKTREE_LANE="ppa-forward-port"', wrapper)
        self.assertIn('KERNEL_EXTRA_DIR="$PPA_WORKTREE_LANE"', wrapper)
        self.assertIn('KERNEL_PPA_REPO="$ppa_worktree"', wrapper)
        self.assertIn('"ARTIFACT_IGNORE_CACHE=yes"', wrapper)
        self.assertIn('"ARTIFACT_WILL_NOT_BUILD=yes"', wrapper)
        self.assertIn("acquire_armbian_state_lock", wrapper)
        self.assertIn("restore_ppa_shared_state", wrapper)
        self.assertIn("docker-clean-armbian-state.sh", wrapper)
        self.assertIn("YSP_PPA_LOCK_FD=8", wrapper)
        self.assertIn(
            "6.18__rockchip64__arm64__ppa-forward-port",
            exporter,
        )
        self.assertIn("make --no-print-directory -s -C", exporter)
        self.assertIn("kernel source/version mismatch", exporter)

    def test_rewrite_debug_build_verifies_its_test_instrumentation(self) -> None:
        wrapper = self.shell_text("kernel-drivers/scripts/build-kernel.sh")
        rewrite_debug = wrapper.split("\trewrite-debug)", 1)[1].split(
            "\t\t;;", 1
        )[0]
        for symbol in (
            "CONFIG_KUNIT",
            "CONFIG_KUNIT_DEBUGFS",
            "CONFIG_KUNIT_DEFAULT_ENABLED",
            "CONFIG_KUNIT_AUTORUN_ENABLED",
            "CONFIG_KASAN",
            "CONFIG_PROVE_LOCKING",
            "CONFIG_DEBUG_LOCK_ALLOC",
            "CONFIG_ROCKCHIP_MPP_REWRITE",
            "CONFIG_ROCKCHIP_MPP_REWRITE_KUNIT_TEST",
            "CONFIG_ROCKCHIP_RGA_REWRITE",
            "CONFIG_ROCKCHIP_RGA_REWRITE_KUNIT_TEST",
        ):
            with self.subTest(symbol=symbol):
                self.assertIn(symbol, rewrite_debug)

        stamp = self.shell_text(
            "kernel-drivers/scripts/debug-kernel/ysp-build-stamp.sh"
        )
        self.assertIn('stamp="${stamp} (g${YSP_SOURCE_GSHA})"', stamp)

        gate = self.shell_text("kernel-drivers/tests/rewrite-build-gate.sh")
        memory_profile = gate.split("\n  memory)", 1)[1].split("\n    ;;", 1)[0]
        self.assertIn("--set-val FRAME_WARN 2048", memory_profile)

    def test_conformance_defaults_use_installed_mpp_and_librga(self) -> None:
        expected_defaults = {
            "kernel-drivers/tests/mpp-suite.sh": (
                "MPP_BIN_DIR=${MPP_BIN_DIR:-/usr/bin}",
                "MPP_LIBDIR=${MPP_LIBDIR:-}",
            ),
            "kernel-drivers/tests/librga-suite.sh": (
                "LIBRGA_LIBDIR=${LIBRGA_LIBDIR:-}",
            ),
            "kernel-drivers/tests/gstreamer-suite.sh": (
                "MPP_LIBDIR=${MPP_LIBDIR:-}",
                "LIBRGA_LIBDIR=${LIBRGA_LIBDIR:-}",
            ),
            "kernel-drivers/tests/rewrite-smoke.sh": (
                'MPP_BUILD="${MPP_BUILD:-/usr}"',
            ),
            "kernel-drivers/tests/decode-differential.sh": (
                'MPP_BUILD="${MPP_BUILD:-/usr}"',
            ),
            "kernel-drivers/tests/test-decode.sh": (
                'MPP_BUILD="${MPP_BUILD:-/usr}"',
            ),
            "kernel-drivers/tests/encode-test-tiny.sh": (
                'MPP_BUILD="${MPP_BUILD:-/usr}"',
            ),
            "kernel-drivers/tests/rga-mmu-debug.sh": (
                "LIBRGA_LIBDIR=${LIBRGA_LIBDIR:-}",
            ),
            "kernel-drivers/tests/iommu-machinery-fuzz.sh": (
                'MPP_BUILD="${MPP_BUILD:-/usr}"',
                'LIBRGA_LIBDIR="${LIBRGA_LIBDIR:-}"',
            ),
            "kernel-drivers/tests/ffmpeg-suite.sh": (
                "FFMPEG_RUNTIME_MODES=${FFMPEG_RUNTIME_MODES:-system}",
            ),
        }

        for relative, expected_fragments in expected_defaults.items():
            text = self.shell_text(relative)
            for expected in expected_fragments:
                with self.subTest(script=relative, expected=expected):
                    self.assertIn(expected, text)

    def test_librga_suite_log_parser(self) -> None:
        env = os.environ.copy()
        env["LIBRGA_SUITE_VALIDATE_LOG_PARSER"] = "1"
        result = subprocess.run(
            ["bash", str(REPO_ROOT / "kernel-drivers/tests/librga-suite.sh")],
            cwd=REPO_ROOT,
            env=env,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("PASS: librga sample log parser", result.stdout)

    def test_librga_suite_default_cases_exclude_vendor_heaps(self) -> None:
        for enabled in ("0", "1"):
            with self.subTest(vendor_heaps=enabled):
                env = os.environ.copy()
                env["LIBRGA_ENABLE_VENDOR_HEAP_CASES"] = enabled
                env["LIBRGA_SUITE_VALIDATE_CASES"] = "1"
                result = subprocess.run(
                    ["bash", str(REPO_ROOT / "kernel-drivers/tests/librga-suite.sh")],
                    cwd=REPO_ROOT,
                    env=env,
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(
                    f"PASS: librga default cases (vendor heaps {enabled})",
                    result.stdout,
                )

        legacy_smoke = self.shell_text(
            "kernel-drivers/tests/conformance/scripts/run-librga-smoke.sh"
        )
        default_line = next(
            line for line in legacy_smoke.splitlines() if line.startswith("cases=")
        )
        self.assertNotIn("rga_fill_demo", default_line)

    def test_shared_tmp_and_ccache_stay_outside_grouped_workspace(self) -> None:
        build_gate = self.shell_text(
            "kernel-drivers/tests/rewrite-build-gate.sh"
        )
        ccache = self.shell_text("scripts/centralize-ccache.sh")
        agents = self.shell_text("AGENTS.md")
        ccache_docs = [
            self.shell_text("README.md"),
            self.shell_text("scripts/README.md"),
            self.shell_text("kernel-drivers/docs/kernel-build-ccache.md"),
        ]

        self.assertIn(
            'REWRITE_BUILD_TMP_ROOT="${REWRITE_BUILD_TMP_ROOT:-'
            '$ROOT_DIR/../tmp}"',
            build_gate,
        )
        self.assertIn('CENTRAL_DIR="$CODE_ROOT/.ccache"', ccache)
        self.assertNotIn(
            'REWRITE_BUILD_TMP_ROOT="${REWRITE_BUILD_TMP_ROOT:-'
            '$ROCK5B_WORKSPACE}"',
            build_gate,
        )
        self.assertNotIn(
            'CENTRAL_DIR="$ROCK5B_WORKSPACE/.ccache"',
            ccache,
        )
        self.assertIn("`~/Code/.ccache`", agents)
        self.assertNotIn("../rock-5b/build/ccache", agents)
        for doc in ccache_docs:
            self.assertIn("~/Code/.ccache", doc)
            self.assertNotIn("rock-5b/build/ccache", doc)


class DebugRamoopsTests(unittest.TestCase):
    patch = (
        REPO_ROOT
        / "kernel-drivers/patches/debug-kernel/"
        "0001-arm64-dts-rockchip-add-persistent-ramoops-to-rock-5b.patch"
    )

    def test_debug_dtb_uses_rk3588_persistent_low_memory(self) -> None:
        text = self.patch.read_text(encoding="utf-8")

        self.assertIn("0x110000-0x1f0000", text)
        self.assertIn("minidump", text)
        self.assertIn("ramoops@118000", text)
        self.assertIn("reg = <0x0 0x00118000 0x0 0x000d0000>;", text)
        self.assertIn("record-size = <0x00040000>;", text)
        self.assertIn("console-size = <0x00080000>;", text)
        self.assertIn("pmsg-size = <0x00010000>;", text)
        self.assertNotIn("ramoops@4fe000000", text)

    def test_debug_dtb_patch_is_well_formed(self) -> None:
        result = subprocess.run(
            ["git", "apply", "--numstat", str(self.patch)],
            cwd=REPO_ROOT,
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("arch/arm64/boot/dts/rockchip/rk3588-rock-5b.dts", result.stdout)

    def test_enable_script_rejects_a_dtb_without_the_fixed_node(self) -> None:
        script = (
            REPO_ROOT
            / "kernel-drivers/scripts/debug-kernel/enable-ramoops-capture.sh"
        ).read_text(encoding="utf-8")

        self.assertIn("verify_packaged_ramoops", script)
        self.assertIn("/reserved-memory/ramoops@118000", script)
        self.assertIn(
            'remove_list_item "$ENV_FILE" "user_overlays" "ramoops"',
            script,
        )
        self.assertNotIn("ramoops@4fe000000", script)


class ForwardPortPatchSeriesTests(unittest.TestCase):
    series = REPO_ROOT / "kernel-drivers/patches/forward-port-rk3588"

    def test_series_contains_the_current_contiguous_patch_tail(self) -> None:
        patches = sorted(self.series.glob("rk3588-fwport-*.patch"))
        numbers = [int(path.name.split("-")[2]) for path in patches]

        self.assertEqual(numbers, list(range(1, 98)))
        readme = (self.series / "README.md").read_text(encoding="utf-8")
        self.assertIn("contiguous `0001`–`0097`", readme)
        self.assertIn("e7ff978398825", readme)

    def test_series_mailboxes_are_well_formed(self) -> None:
        for patch in sorted(self.series.glob("rk3588-fwport-*.patch")):
            with self.subTest(patch=patch.name):
                result = subprocess.run(
                    ["git", "apply", "--numstat", str(patch)],
                    cwd=REPO_ROOT,
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(result.stdout.strip())


class PpaVersionConsistencyTests(unittest.TestCase):
    def test_clean_installer_ffmpeg_drift_is_reported(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            changelog = root / "packaging/ppa/ffmpeg/debian/changelog"
            changelog.parent.mkdir(parents=True)
            changelog.write_text(
                "ffmpeg (7:8.0.3+new+git.1111111111-0ubuntu1) resolute; urgency=medium\n",
                encoding="utf-8",
            )
            installer = root / "packaging/ppa/clean-install-system-stack.sh"
            installer.parent.mkdir(parents=True, exist_ok=True)
            installer.write_text(
                '#!/usr/bin/env bash\nFFMPEG_VERSION="7:8.0.3+old-0ubuntu1"\n',
                encoding="utf-8",
            )
            exporter = root / "packaging/ppa/build-source-packages.sh"
            exporter.write_text(
                '#!/usr/bin/env bash\n'
                'FFMPEG_COMMIT="${FFMPEG_COMMIT:-1111111111aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"\n'
                'FFMPEG_UPSTREAM_VERSION="${FFMPEG_UPSTREAM_VERSION:-8.0.3+new+git.1111111111}"\n',
                encoding="utf-8",
            )
            status = root / "status.md"
            status.write_text(
                "<!-- ppa-live-ffmpeg: 7:8.0.3+new+git.1111111111-0ubuntu1 -->\n",
                encoding="utf-8",
            )
            errors: list[str] = []

            DOC_CHECKER.check_ppa_ffmpeg_install_pin(root, errors)

            self.assertEqual(len(errors), 1)
            self.assertIn("does not match W05's published version", errors[0])

    def test_clean_installer_may_pin_documented_live_ffmpeg(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            changelog = root / "packaging/ppa/ffmpeg/debian/changelog"
            changelog.parent.mkdir(parents=True)
            changelog.write_text(
                "ffmpeg (7:8.0.3+candidate+git.2222222222-0ubuntu1) resolute; urgency=medium\n",
                encoding="utf-8",
            )
            installer = root / "packaging/ppa/clean-install-system-stack.sh"
            installer.parent.mkdir(parents=True, exist_ok=True)
            installer.write_text(
                '#!/usr/bin/env bash\nFFMPEG_VERSION="7:8.0.3+published-0ubuntu1"\n',
                encoding="utf-8",
            )
            exporter = root / "packaging/ppa/build-source-packages.sh"
            exporter.write_text(
                '#!/usr/bin/env bash\n'
                'FFMPEG_COMMIT="${FFMPEG_COMMIT:-2222222222aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"\n'
                'FFMPEG_UPSTREAM_VERSION="${FFMPEG_UPSTREAM_VERSION:-8.0.3+candidate+git.2222222222}"\n',
                encoding="utf-8",
            )
            status = root / "status.md"
            status.write_text(
                "<!-- ppa-live-ffmpeg: 7:8.0.3+published-0ubuntu1 -->\n",
                encoding="utf-8",
            )
            errors: list[str] = []

            DOC_CHECKER.check_ppa_ffmpeg_install_pin(root, errors)

            self.assertEqual(errors, [])

    def test_ffmpeg_build_owner_commit_must_match_its_source_version(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            changelog = root / "packaging/ppa/ffmpeg/debian/changelog"
            changelog.parent.mkdir(parents=True)
            changelog.write_text(
                "ffmpeg (7:8.0.3+git.2222222222-0ubuntu1) resolute; urgency=medium\n",
                encoding="utf-8",
            )
            packaging = root / "packaging/ppa"
            (packaging / "clean-install-system-stack.sh").write_text(
                '#!/usr/bin/env bash\nFFMPEG_VERSION="7:8.0.3+git.2222222222-0ubuntu1"\n',
                encoding="utf-8",
            )
            (packaging / "build-source-packages.sh").write_text(
                '#!/usr/bin/env bash\n'
                'FFMPEG_COMMIT="${FFMPEG_COMMIT:-1111111111aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"\n'
                'FFMPEG_UPSTREAM_VERSION="${FFMPEG_UPSTREAM_VERSION:-8.0.3+git.2222222222}"\n',
                encoding="utf-8",
            )
            (root / "status.md").write_text(
                "<!-- ppa-live-ffmpeg: 7:8.0.3+git.2222222222-0ubuntu1 -->\n",
                encoding="utf-8",
            )
            errors: list[str] = []

            DOC_CHECKER.check_ppa_ffmpeg_install_pin(root, errors)

            self.assertTrue(any("is not identified" in error for error in errors))

    def test_grd_exporter_commit_drift_is_reported(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            exporter = root / "packaging/ppa/build-source-packages.sh"
            exporter.parent.mkdir(parents=True)
            exporter.write_text(
                '#!/usr/bin/env bash\n'
                'GRD_COMMIT="${GRD_COMMIT:-1111111aaaaaaaaaaaaaaaaaaaaaaaaa}"\n'
                'GRD_UPSTREAM_VERSION="${GRD_UPSTREAM_VERSION:-50.1+git.new2222}"\n',
                encoding="utf-8",
            )
            changelog = (
                root / "packaging/ppa/gnome-remote-desktop/debian/changelog"
            )
            changelog.parent.mkdir(parents=True)
            changelog.write_text(
                "gnome-remote-desktop "
                "(50.1+git.new2222-0ubuntu1) resolute; urgency=medium\n",
                encoding="utf-8",
            )
            (root / "packaging/ppa/clean-install-system-stack.sh").write_text(
                '#!/usr/bin/env bash\nGRD_VERSION="50.1+git.new2222-0ubuntu1"\n',
                encoding="utf-8",
            )
            (root / "status.md").write_text(
                "<!-- ppa-live-grd: 50.1+git.new2222-0ubuntu1 -->\n",
                encoding="utf-8",
            )
            errors: list[str] = []

            DOC_CHECKER.check_ppa_grd_source_pin(root, errors)

            self.assertEqual(len(errors), 1)
            self.assertIn("default GRD commit", errors[0])
            self.assertIn("does not match latest changelog", errors[0])

    def test_grd_installer_must_match_w05_published_version(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            packaging = root / "packaging/ppa"
            packaging.mkdir(parents=True)
            (packaging / "build-source-packages.sh").write_text(
                '#!/usr/bin/env bash\n'
                'GRD_COMMIT="${GRD_COMMIT:-1111111aaaaaaaaaaaaaaaaaaaaaaaaa}"\n'
                'GRD_UPSTREAM_VERSION="${GRD_UPSTREAM_VERSION:-50.1+git.1111111}"\n',
                encoding="utf-8",
            )
            changelog = packaging / "gnome-remote-desktop/debian/changelog"
            changelog.parent.mkdir(parents=True)
            changelog.write_text(
                "gnome-remote-desktop (50.1+git.1111111-0ubuntu1) "
                "resolute; urgency=medium\n",
                encoding="utf-8",
            )
            (packaging / "clean-install-system-stack.sh").write_text(
                '#!/usr/bin/env bash\nGRD_VERSION="50.1+git.old0000-0ubuntu1"\n',
                encoding="utf-8",
            )
            (root / "status.md").write_text(
                "<!-- ppa-live-grd: 50.1+git.1111111-0ubuntu1 -->\n",
                encoding="utf-8",
            )
            errors: list[str] = []

            DOC_CHECKER.check_ppa_grd_source_pin(root, errors)

            self.assertEqual(len(errors), 1)
            self.assertIn("does not match W05's published version", errors[0])


class PassiveCoolingScriptTests(unittest.TestCase):
    script = SCRIPTS / "rock5b-passive-cooling-apply.sh"

    def write_value(self, path: Path, value: str) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f"{value}\n", encoding="utf-8")

    def add_policy(self, root: Path, name: str, hardware_max: int) -> None:
        policy = root / name
        self.write_value(policy / "cpuinfo_min_freq", "408000")
        self.write_value(policy / "cpuinfo_max_freq", str(hardware_max))
        self.write_value(policy / "scaling_min_freq", "408000")
        self.write_value(policy / "scaling_max_freq", str(hardware_max))
        self.write_value(
            policy / "scaling_available_frequencies",
            "408000 600000 816000 1008000 1200000 1416000 "
            "1608000 1800000 2016000 2208000 2400000",
        )

    def add_zone(self, root: Path, number: int, zone_type: str, temp: int) -> None:
        zone = root / f"thermal_zone{number}"
        self.write_value(zone / "type", zone_type)
        self.write_value(zone / "temp", str(temp))

    def run_dry_run(
        self,
        root: Path,
        nvme_temperature: int | None = 40_000,
        previous_level: int | None = None,
    ) -> subprocess.CompletedProcess[str]:
        thermal_root = root / "thermal"
        cpufreq_root = root / "cpufreq"
        nvme_root = root / "nvme"
        self.add_policy(cpufreq_root, "policy0", 1_800_000)
        self.add_policy(cpufreq_root, "policy4", 2_400_000)
        if nvme_temperature is not None:
            self.write_value(
                nvme_root / "nvme0/hwmon0/temp1_input",
                str(nvme_temperature),
            )

        tools = root / "bin"
        nvme = tools / "nvme"
        self.write_value(nvme, "#!/usr/bin/env bash\nexit 0")
        nvme.chmod(0o755)

        environment = os.environ.copy()
        environment.update(
            {
                "CPUFREQ_ROOT": str(cpufreq_root),
                "NVME_CONTROLLER": "/dev/nvme0",
                "NVME_SYSFS_ROOT": str(nvme_root),
                "PATH": f"{tools}:{environment['PATH']}",
                "THERMAL_ROOT": str(thermal_root),
            }
        )
        if previous_level is not None:
            environment["LAST_LEVEL"] = str(previous_level)
        return subprocess.run(
            ["bash", str(self.script), "--force-board", "--dry-run"],
            cwd=REPO_ROOT,
            env=environment,
            check=False,
            capture_output=True,
            text=True,
        )

    def test_split_layout_uses_hottest_cpu_zone(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            thermal_root = root / "thermal"
            self.add_zone(thermal_root, 0, "package-thermal", 82_230)
            self.add_zone(thermal_root, 1, "bigcore0-thermal", 84_076)
            self.add_zone(thermal_root, 2, "bigcore2-thermal", 83_153)
            self.add_zone(thermal_root, 3, "littlecore-thermal", 82_230)
            self.add_zone(thermal_root, 4, "gpu-thermal", 99_000)

            result = self.run_dry_run(root)
            output = result.stdout + result.stderr

            self.assertEqual(result.returncode, 0, output)
            self.assertIn("effective 84 C (level 4)", output)
            self.assertIn("policy0  min= 408000 kHz max=1008000 kHz", output)
            self.assertIn("policy4  min= 408000 kHz max=1608000 kHz", output)

    def test_legacy_layout_uses_soc_thermal_zone(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            thermal_root = root / "thermal"
            self.add_zone(thermal_root, 0, "soc-thermal", 70_123)
            self.add_zone(thermal_root, 1, "npu-thermal", 99_000)

            result = self.run_dry_run(root)
            output = result.stdout + result.stderr

            self.assertEqual(result.returncode, 0, output)
            self.assertIn("effective 70 C (level 2)", output)

    def test_nvme_plus_three_degrees_can_select_cpu_level(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.add_zone(root / "thermal", 0, "soc-thermal", 70_000)

            result = self.run_dry_run(root, nvme_temperature=72_000)
            output = result.stdout + result.stderr

            self.assertEqual(result.returncode, 0, output)
            self.assertIn("CPU 70 C, NVMe 72 C (+3 C), effective 75 C", output)
            self.assertIn("effective 75 C (level 3)", output)
            self.assertIn("policy4  min= 408000 kHz max=1800000 kHz", output)

    def test_two_degree_hysteresis_holds_then_releases_level(self) -> None:
        cases = ((74_000, 3), (73_000, 2))
        for temperature, expected_level in cases:
            with self.subTest(temperature=temperature):
                with tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    self.add_zone(root / "thermal", 0, "soc-thermal", temperature)

                    result = self.run_dry_run(root, previous_level=3)
                    output = result.stdout + result.stderr

                    self.assertEqual(result.returncode, 0, output)
                    self.assertIn(
                        f"effective {temperature // 1000} C (level {expected_level})",
                        output,
                    )

    def test_accelerator_zones_are_not_cpu_temperature_fallbacks(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            thermal_root = root / "thermal"
            self.add_zone(thermal_root, 0, "gpu-thermal", 84_000)
            self.add_zone(thermal_root, 1, "npu-thermal", 85_000)

            result = self.run_dry_run(root)
            output = result.stdout + result.stderr

            self.assertNotEqual(result.returncode, 0, output)
            self.assertIn("CPU thermal zone not found", output)

    def test_missing_nvme_composite_temperature_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.add_zone(root / "thermal", 0, "soc-thermal", 70_000)

            result = self.run_dry_run(root, nvme_temperature=None)
            output = result.stdout + result.stderr

            self.assertNotEqual(result.returncode, 0, output)
            self.assertIn("NVMe composite temperature not found", output)

    def test_monitor_does_not_require_nvme_character_device_unit(self) -> None:
        source = self.script.read_text(encoding="utf-8")

        self.assertNotIn('device_unit="dev-', source)
        self.assertNotIn("Requires=%s", source)
        self.assertIn("'Restart=on-failure'", source)
        self.assertIn("'StartLimitIntervalSec=0'", source)


class SubstantiveDriftTests(unittest.TestCase):
    def test_personal_home_default_in_operational_file_is_reported(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            script = root / "build.sh"
            script.write_text(
                '#!/usr/bin/env bash\nSRC="${SRC:-/' + 'home/alice/src}"\n',
                encoding="utf-8",
            )
            errors: list[str] = []

            DOC_CHECKER.check_portable_operational_defaults(root, errors)

            self.assertTrue(any("personal home path" in e for e in errors))

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

    def test_findings_index_reports_orphan_and_dangling(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            findings = root / "findings"
            findings.mkdir()
            (findings / "2026-01-01-linked.md").write_text("# Linked\n", encoding="utf-8")
            (findings / "2026-01-02-orphan.md").write_text("# Orphan\n", encoding="utf-8")
            (findings / "README.md").write_text(
                "## Index\n\n"
                "<!-- findings-index:start -->\n"
                "- [`2026-01-03-dangling.md`](2026-01-03-dangling.md) — Dangling\n"
                "- [`2026-01-01-linked.md`](2026-01-01-linked.md) — Linked\n"
                "<!-- findings-index:end -->\n",
                encoding="utf-8",
            )
            errors: list[str] = []

            DOC_CHECKER.check_findings_index(root, errors)

            self.assertTrue(
                any("2026-01-02-orphan.md is not linked" in e for e in errors)
            )
            self.assertTrue(
                any("2026-01-03-dangling.md but no such file" in e for e in errors)
            )

    def test_findings_index_title_and_generator_are_exact(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            findings = root / "findings"
            findings.mkdir()
            older = findings / "2026-01-01-older.md"
            newer = findings / "2026-01-02-newer.md"
            older.write_text("# Older title\n", encoding="utf-8")
            newer.write_text("# Newer title\n", encoding="utf-8")
            readme = findings / "README.md"
            readme.write_text(
                "## Index (newest first)\n\n"
                "<!-- findings-index:start -->\n"
                "- [`2026-01-02-newer.md`](2026-01-02-newer.md) — Wrong title\n"
                "- [`2026-01-01-older.md`](2026-01-01-older.md) — Older title\n"
                "<!-- findings-index:end -->\n",
                encoding="utf-8",
            )
            errors: list[str] = []

            DOC_CHECKER.check_findings_index(root, errors)

            self.assertTrue(any("differs from its H1" in error for error in errors))

            rows = FINDINGS_INDEXER.generated_rows(findings)
            updated = FINDINGS_INDEXER.replace_index(readme, rows)
            readme.write_text(updated, encoding="utf-8")
            errors = []
            DOC_CHECKER.check_findings_index(root, errors)
            self.assertEqual(errors, [])

    def test_findings_topic_coverage_reports_gaps_and_duplicates(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            findings = root / "findings"
            findings.mkdir()
            (findings / "2026-01-01-grouped.md").write_text("# Grouped\n", encoding="utf-8")
            (findings / "2026-01-02-ungrouped.md").write_text("# Ungrouped\n", encoding="utf-8")
            (findings / "2026-01-03-doubled.md").write_text("# Doubled\n", encoding="utf-8")
            (findings / "2026-01-04-tomb.md").write_text(
                "# Tomb\n\npromoted → somewhere (2026-01-04)\n", encoding="utf-8"
            )
            (findings / "README.md").write_text(
                "<!-- findings-topics:start -->\n"
                "### Alpha (3)\n\n"
                "- [`2026-01-01`](2026-01-01-grouped.md) — Grouped\n"
                "- [`2026-01-03`](2026-01-03-doubled.md) — Doubled\n"
                "- [`2026-01-09`](2026-01-09-missing.md) — Missing\n\n"
                "### Beta (2)\n\n"
                "- [`2026-01-03`](2026-01-03-doubled.md) — Doubled\n"
                "- [`2026-01-04`](2026-01-04-tomb.md) — Tomb\n"
                "<!-- findings-topics:end -->\n",
                encoding="utf-8",
            )
            errors: list[str] = []

            DOC_CHECKER.check_findings_topic_coverage(root, errors)

            self.assertTrue(
                any("2026-01-02-ungrouped.md is in no topic group" in e for e in errors)
            )
            self.assertTrue(
                any("2026-01-03-doubled.md is in two topic groups" in e for e in errors)
            )
            self.assertTrue(
                any("links 2026-01-09-missing.md" in e for e in errors)
            )
            self.assertTrue(
                any("2026-01-04-tomb.md" in e and "tombstone" in e for e in errors)
            )

    def test_findings_topic_coverage_accepts_a_complete_index(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            findings = root / "findings"
            findings.mkdir()
            (findings / "2026-01-01-one.md").write_text("# One\n", encoding="utf-8")
            (findings / "2026-01-02-two.md").write_text("# Two\n", encoding="utf-8")
            (findings / "2026-01-03-tomb.md").write_text(
                "# Tomb\n\npromoted → elsewhere (2026-01-03)\n", encoding="utf-8"
            )
            (findings / "README.md").write_text(
                "<!-- findings-topics:start -->\n"
                "### Only group (2)\n\n"
                "- [`2026-01-02`](2026-01-02-two.md) — Two\n"
                "- [`2026-01-01`](2026-01-01-one.md) — One\n"
                "<!-- findings-topics:end -->\n",
                encoding="utf-8",
            )
            errors: list[str] = []

            DOC_CHECKER.check_findings_topic_coverage(root, errors)

            self.assertEqual(errors, [])

    def test_findings_lifecycle_reports_tombstones_and_orphaned_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            findings = root / "findings"
            evidence = findings / "evidence"
            orphan = evidence / "orphan"
            owned = evidence / "owned"
            orphan.mkdir(parents=True)
            owned.mkdir(parents=True)
            (orphan / "README.md").write_text(
                "# Orphan\n\n[Project](../../../project.md)\n", encoding="utf-8"
            )
            (owned / "README.md").write_text("# Owned\n", encoding="utf-8")
            (owned / "result.txt").write_text("signal\n", encoding="utf-8")
            (root / "project.md").write_text("# Project\n", encoding="utf-8")
            (findings / "2026-01-01-live.md").write_text(
                "# Live\n\n[Evidence](evidence/owned/result.txt)\n",
                encoding="utf-8",
            )
            tombstone = findings / "2026-01-02-promoted.md"
            tombstone.write_text(
                "# Promoted\n\npromoted → project.md (2026-01-02)\n",
                encoding="utf-8",
            )
            errors: list[str] = []

            DOC_CHECKER.check_findings_lifecycle(root, errors)

            self.assertTrue(any("promotion tombstone" in error for error in errors))
            self.assertTrue(
                any(
                    "evidence/orphan" in error and "no active owning" in error
                    for error in errors
                )
            )
            self.assertFalse(any("evidence/owned" in error for error in errors))

    def test_findings_lifecycle_accepts_bundle_backlink_to_live_finding(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            findings = root / "findings"
            bundle = findings / "evidence" / "owned"
            bundle.mkdir(parents=True)
            finding = findings / "2026-01-01-live.md"
            finding.write_text("# Live\n", encoding="utf-8")
            (bundle / "README.md").write_text(
                "# Owned\n\n[Finding](../../2026-01-01-live.md)\n",
                encoding="utf-8",
            )
            errors: list[str] = []

            DOC_CHECKER.check_findings_lifecycle(root, errors)

            self.assertEqual(errors, [])

    def test_readme_ownership_reports_files_no_readme_names(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "tools").mkdir()
            (root / "tools" / "debian").mkdir()
            (root / "deep" / "nested").mkdir(parents=True)
            (root / "README.md").write_text(
                "# Root\n\nHolds [`deep/nested/inherited.md`](deep/nested/inherited.md).\n",
                encoding="utf-8",
            )
            (root / "tools" / "README.md").write_text(
                "# Tools\n\n- [`named.sh`](named.sh)\n", encoding="utf-8"
            )
            (root / "tools" / "named.sh").write_text("#!/bin/sh\n", encoding="utf-8")
            (root / "tools" / "orphan.sh").write_text("#!/bin/sh\n", encoding="utf-8")
            # dpkg dictates this layout, so it is exempt from the naming rule.
            (root / "tools" / "debian" / "rules.sh").write_text("#!/bin/sh\n", encoding="utf-8")
            # No README in deep/nested/, so ownership falls back to the root one.
            (root / "deep" / "nested" / "inherited.md").write_text("x\n", encoding="utf-8")
            errors: list[str] = []

            DOC_CHECKER.check_readme_ownership(root, errors)

            self.assertEqual(len(errors), 1, errors)
            self.assertIn("tools/orphan.sh", errors[0])
            self.assertIn("tools/README.md", errors[0])

    def test_root_patch_placement_rejects_only_root_patches(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "scratch.patch").write_text("patch\n", encoding="utf-8")
            (root / ".review.diff").write_text("diff\n", encoding="utf-8")
            owned = root / "kernel-drivers/patches/owned.patch"
            owned.parent.mkdir(parents=True)
            owned.write_text("patch\n", encoding="utf-8")
            errors: list[str] = []

            DOC_CHECKER.check_root_patch_placement(root, errors)

            self.assertEqual(len(errors), 2, errors)
            self.assertTrue(any("scratch.patch" in error for error in errors))
            self.assertTrue(any(".review.diff" in error for error in errors))
            self.assertFalse(any("owned.patch" in error for error in errors))

    def test_nested_readme_must_be_linked_from_nearest_ancestor(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            tools = root / "tools"
            nested = tools / "nested"
            nested.mkdir(parents=True)
            (root / "README.md").write_text(
                "# Root\n\n- [`tools/`](tools/)\n", encoding="utf-8"
            )
            owner = tools / "README.md"
            owner.write_text("# Tools\n", encoding="utf-8")
            (nested / "README.md").write_text("# Nested\n", encoding="utf-8")
            errors: list[str] = []

            DOC_CHECKER.check_readme_navigation(root, errors)

            self.assertEqual(len(errors), 1, errors)
            self.assertIn("tools/nested/README.md", errors[0])
            self.assertIn("tools/README.md", errors[0])

            owner.write_text(
                "# Tools\n\n- [`nested/`](nested/README.md)\n",
                encoding="utf-8",
            )
            errors = []
            DOC_CHECKER.check_readme_navigation(root, errors)
            self.assertEqual(errors, [])

    def test_checks_report_instead_of_silently_covering_nothing(self) -> None:
        """A missing input must fail the stage, not disable the check.

        Each of these guards used to `return` quietly, so a reworded heading or a
        moved file left the stage reporting success with the drift intact.
        """
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "docs").mkdir()

            # Watchlist heading reworded by one character.
            (root / "status.md").write_text(
                "# Status\n\n| 1 | Track one |\n\n"
                "## Watchlist: facts that go stale silently\n\n"
                "| W01 | [Thing](#watch-w01) | 2026-07-25 |\n",
                encoding="utf-8",
            )
            (root / "docs" / "status-ledger.md").write_text(
                "# Ledger\n\nprose only, no numbered rows\n", encoding="utf-8"
            )

            errors: list[str] = []
            DOC_CHECKER.check_watchlist_pairing(root, errors)
            self.assertEqual(len(errors), 1, errors)
            self.assertIn("silently covered nothing", errors[0])

            errors = []
            DOC_CHECKER.check_status_ledger_tracks(root, errors)
            self.assertTrue(
                any("no numbered track rows parsed" in error for error in errors),
                errors,
            )

            for check in (
                DOC_CHECKER.check_ppa_ffmpeg_install_pin,
                DOC_CHECKER.check_ppa_grd_source_pin,
            ):
                errors = []
                check(root, errors)
                with self.subTest(check=check.__name__):
                    self.assertTrue(errors, "missing pin inputs reported nothing")
                    self.assertTrue(
                        all("cannot run" in error for error in errors), errors
                    )

    def test_shell_contract_reports_bad_shebang_and_stray_exec_bit(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            subprocess.run(["git", "init", "--quiet", str(root)], check=True)
            (root / "debian").mkdir()

            files = {
                "good-exec.sh": "#!/usr/bin/env bash\nset -euo pipefail\n",
                "good-sourced.sh": "# shellcheck shell=bash\nhelper() { :; }\n",
                "bad-shebang.sh": "#!/bin/bash\nset -euo pipefail\n",
                # A source-only helper that kept the executable bit it cannot use.
                "stray-exec.sh": "# shellcheck shell=bash\nhelper() { :; }\n",
                # An executable script whose mode was lost, so a clone cannot run it.
                "lost-exec.sh": "#!/usr/bin/env bash\nset -euo pipefail\n",
                # dpkg dictates this layout, so it is exempt.
                "debian/rules.sh": "#!/bin/sh\n",
            }
            for relative, text in files.items():
                (root / relative).write_text(text, encoding="utf-8")
            subprocess.run(
                ["git", "-C", str(root), "add", *files],
                check=True,
            )
            for relative, flag in (
                ("good-exec.sh", "+x"),
                ("bad-shebang.sh", "+x"),
                ("stray-exec.sh", "+x"),
                ("good-sourced.sh", "-x"),
                ("lost-exec.sh", "-x"),
            ):
                subprocess.run(
                    ["git", "-C", str(root), "update-index", f"--chmod={flag}", relative],
                    check=True,
                )
            errors: list[str] = []

            DOC_CHECKER.check_shell_file_contract(root, errors)

            self.assertEqual(len(errors), 3, errors)
            reported = "\n".join(errors)
            self.assertIn("bad-shebang.sh:1", reported)
            self.assertIn("stray-exec.sh: is source-only", reported)
            self.assertIn("lost-exec.sh: has a shebang", reported)
            self.assertNotIn("debian/rules.sh", reported)

    def test_watchlist_pairing_reports_unpaired_halves_only(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "status.md").write_text(
                "## Watchlist — facts that go stale silently\n\n"
                "| ID | Watch item | Last checked | Summary |\n"
                "|----|------------|--------------|---------|\n"
                "| W01 | [Paired](#watch-w01) | 2026-07-11 | Fine. |\n"
                "| W02 | [No detail](#watch-w02) | 2026-07-11 | Missing detail. |\n\n"
                "### W01 — Paired\n\n"
                "- **Authority:** remote — example.invalid repository.\n"
                "- **Recheck:** Fetch its advertised head.\n"
                "- **Freshness:** Unknown after that head changes.\n"
                "- **Last checked:** 2026-07-11\n"
                "- **State 2026-07-11:** ok\n\n"
                "### W03 — Orphan detail\n\n"
                "- **Last checked:** 2026-07-11\n"
                "- **State 2026-07-11:** ok\n",
                encoding="utf-8",
            )
            errors: list[str] = []

            DOC_CHECKER.check_watchlist_pairing(root, errors)

            self.assertTrue(any("W02: index row has no detail" in e for e in errors))
            self.assertTrue(any("W03: detail block has no index" in e for e in errors))
            # The fully consistent W01 is silent.
            self.assertFalse(any("W01" in e for e in errors))

    def test_retired_watchlist_id_keeps_a_dated_stub_outside_live_index(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "status.md").write_text(
                "## Watchlist — facts that go stale silently\n\n"
                "| ID | Watch item | Last checked | Summary |\n"
                "|----|------------|--------------|---------|\n"
                "| W01 | [Live](#watch-w01) | 2026-07-11 | Fine. |\n\n"
                "### W01 — Live\n\n"
                "- **Authority:** service — example.invalid API.\n"
                "- **Recheck:** Query the API.\n"
                "- **Freshness:** Unknown after a failed query.\n"
                "- **Last checked:** 2026-07-11\n"
                "- **State 2026-07-11:** ok\n\n"
                '<a id="watch-w02"></a>\n'
                "### W02 — Resolved item\n\n"
                "- **Disposition:** Retired 2026-08-05 — resolved knowledge "
                "moved to its project owner.\n",
                encoding="utf-8",
            )
            errors: list[str] = []

            DOC_CHECKER.check_watchlist_pairing(root, errors)

            self.assertEqual(errors, [])

            text = (root / "status.md").read_text(encoding="utf-8")
            (root / "status.md").write_text(
                text.replace(
                    "| W01 | [Live](#watch-w01) | 2026-07-11 | Fine. |",
                    "| W01 | [Live](#watch-w01) | 2026-07-11 | Fine. |\n"
                    "| W02 | [Resolved item](#watch-w02) | 2026-08-05 | old |",
                ),
                encoding="utf-8",
            )
            errors = []
            DOC_CHECKER.check_watchlist_pairing(root, errors)
            self.assertTrue(
                any("retired detail still has a live index" in e for e in errors)
            )

    def test_live_watchlist_requires_authority_recheck_and_freshness(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "status.md").write_text(
                "## Watchlist — facts that go stale silently\n\n"
                "| ID | Watch item | Last checked | Summary |\n"
                "|----|------------|--------------|---------|\n"
                "| W01 | [Live](#watch-w01) | 2026-07-11 | Fine. |\n\n"
                "### W01 — Live\n\n"
                "- **Last checked:** 2026-07-11\n"
                "- **State 2026-07-11:** ok\n",
                encoding="utf-8",
            )
            errors: list[str] = []

            DOC_CHECKER.check_watchlist_pairing(root, errors)

            reported = "\n".join(errors)
            self.assertIn("'**Authority:**'", reported)
            self.assertIn("'**Recheck:**'", reported)
            self.assertIn("'**Freshness:**'", reported)

    def test_status_ledger_tracks_must_match_the_dashboard(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "docs").mkdir()
            (root / "status.md").write_text(
                "| # | Track | State |\n|---|-------|-------|\n"
                "| 1 | Kernel forward-port | ok |\n"
                "| 2 | Renamed here | ok |\n"
                "| 3 | Dashboard only | ok |\n",
                encoding="utf-8",
            )
            (root / "docs" / "status-ledger.md").write_text(
                "| # | Track | Note |\n|---|-------|------|\n"
                "| 1 | Kernel forward-port | ok |\n"
                "| 2 | Renamed there | ok |\n"
                "| 4 | Ledger only | ok |\n",
                encoding="utf-8",
            )
            errors: list[str] = []

            DOC_CHECKER.check_status_ledger_tracks(root, errors)

            self.assertTrue(any("no dashboard row for ledger track 4" in e for e in errors))
            self.assertTrue(
                any("track 2: name differs from its ledger row" in e for e in errors)
            )
            # The matching track 1 is silent.
            self.assertFalse(any("track 1" in e for e in errors))
            # Dashboard-only track 3 is valid: ledger rows are optional.
            self.assertFalse(any("track 3" in e for e in errors))

    def test_status_table_rows_must_stay_contiguous(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "docs").mkdir()
            (root / "status.md").write_text(
                "## Dashboard\n\n"
                "| # | Track | State |\n|---|-------|-------|\n"
                "| 1 | First | ok |\n\n"
                "| 2 | Split dashboard | ok |\n\n"
                "## Next gates\n\n"
                "| # | Track | Gate |\n|---|-------|------|\n"
                "| 1 | First | next |\n"
                "| 2 | Second | next |\n",
                encoding="utf-8",
            )
            (root / "docs" / "status-ledger.md").write_text(
                "# Ledger\n\n"
                "| # | Track | Note |\n|---|-------|------|\n"
                "| 1 | First | ok |\n"
                "intervening prose\n"
                "| 2 | Split ledger | ok |\n",
                encoding="utf-8",
            )
            errors: list[str] = []

            DOC_CHECKER.check_status_table_layout(root, errors)

            self.assertEqual(len(errors), 2, errors)
            self.assertTrue(
                any("status.md ## Dashboard" in error for error in errors), errors
            )
            self.assertTrue(
                any("docs/status-ledger.md" in error for error in errors), errors
            )
            self.assertFalse(any("Next gates" in error for error in errors), errors)

    def test_watchlist_halves_must_agree_on_name_and_date(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "status.md").write_text(
                "## Watchlist — facts that go stale silently\n\n"
                "| ID | Watch item | Last checked | Summary |\n"
                "|----|------------|--------------|---------|\n"
                "| W01 | [Renamed here](#watch-w01) | 2026-07-11 | Name skew. |\n"
                "| W02 | [Stable name](#watch-w02) | 2026-07-24 | Date skew. |\n"
                "| W03 | [Stable name](#watch-w03) | 2026-07-11 | No date. |\n\n"
                "### W01 — Renamed there\n\n"
                "- **Last checked:** 2026-07-11\n\n"
                "### W02 — Stable name\n\n"
                "- **Last checked:** 2026-07-23\n\n"
                "### W03 — Stable name\n\n"
                "- **State 2026-07-11:** no last-checked line\n",
                encoding="utf-8",
            )
            errors: list[str] = []

            DOC_CHECKER.check_watchlist_pairing(root, errors)

            self.assertTrue(any("W01: name differs between halves" in e for e in errors))
            self.assertTrue(
                any("W02: last-checked date differs between halves" in e for e in errors)
            )
            self.assertTrue(
                any("W03: detail block has no '**Last checked:**' date" in e for e in errors)
            )
            # Name skew alone must not also be reported as a date problem.
            self.assertFalse(any("W01: last-checked" in e for e in errors))


# Kernel-log lines the fatal-signature scans MUST flag.  Every one was captured
# from this board; the IOMMU set is the class that a 2026-07-24 root-gates run
# reported kernel_flags=0 through, because the scans' `iommu` alternative could
# not match either real spelling.
FATAL_SCAN_MUST_MATCH = (
    "rk_iommu fdb60f00.iommu: Page fault at 0x00000000dffe8080 of type read",
    "rk_iommu fdb70f00.iommu: Page fault at 0x00000000dfd1e000 of type write",
    "rga: 1994   1994  : RGA IOMMU: read fault! Please check the memory size.",
    "rga: 1994   1994  : RGA IOMMU: write fault! Please check the memory size.",
    "rga: 1994   1994  : IOMMU intr fault, IOVA[0xdffe8080], STATUS[0x0]",
    "rga: 0      0     : RGA current status: bus error",
    "BUG: KASAN: slab-use-after-free in rga_mm_session_show+0x1c/0x2f0",
    "Unable to handle kernel paging request at virtual address dfff800000000363",
    "INFO: trying to register non-static key.",
    "turning off the locking correctness validator.",
    "DEBUG_LOCKS_WARN_ON(lock->magic != lock)",
)

# Lines the scans MUST NOT flag.  These are why the word boundaries and the
# rga/mpp alternatives are spelled the way they are -- each one produced a false
# positive at some point, and a fail-closed reject is a PASS, not a fault.
FATAL_SCAN_MUST_NOT_MATCH = (
    # bare `BUG:` matches the harness's own marker: rga-mmu-de(bug:)
    "rock-5b-ysp rga-mmu-debug: BEGIN rga_copy_demo",
    "rock-5b-ysp rga-mmu-debug: END rga_copy_demo status=1 elapsed_s=0.040",
    # bare `Oops` matches pstore.backend=ram(oops) on the kernel cmdline
    "Kernel command line: root=UUID=x splash=verbose pstore.backend=ramoops panic=10",
    # an `rga...iommu` alternative matches the benign probe line
    "rga: IOMMU binding successfully, default mapping core[0x1]",
    "iommu: Default domain type: Translated",
    # fail-closed rejects and ordinary job errors are expected gate output
    "rga: 12561  12561 : rga2 page table reject: -95",
    "rga: 10170  10170 : ID[1]: submit failed!",
    "rga: 1994   1994  : RGA3_core0[0x1] soft reset complete.",
)


class FatalSignatureScanTests(unittest.TestCase):
    """The kernel-log fatal scans are duplicated; pin their BEHAVIOUR.

    `suite-common.sh` (sourced by the conformance suites and `sanitizer-scan.sh`)
    and `run-root-gates.sh` (deliberately standalone, so it can run as root
    without sourcing the suite helpers) carry separate copies of the signature
    set.  They are not byte-identical by design and never can be, so this tests
    what they must *do* rather than how they are spelled: a reword that keeps
    the behaviour passes, while a reintroduced blind spot or false positive
    fails.
    """

    tests_dir = REPO_ROOT / "kernel-drivers/tests"

    def suite_common_regex(self) -> str:
        result = subprocess.run(
            ["bash", "-c", 'source ./suite-common.sh >/dev/null 2>&1; printf "%s" "$SUITE_DMESG_FATAL_RE"'],
            cwd=self.tests_dir,
            capture_output=True,
            text=True,
            check=True,
        )
        return result.stdout

    def root_gates_regex(self) -> str:
        # Sourcing run-root-gates.sh would execute it (it exits unless root),
        # so lift the assignment out textually.
        for line in (self.tests_dir / "run-root-gates.sh").read_text(
            encoding="utf-8"
        ).splitlines():
            if line.startswith("FATAL_RE='") and line.endswith("'"):
                return line[len("FATAL_RE='") : -1]
        self.fail("no FATAL_RE assignment found in run-root-gates.sh")

    def assert_scan_behaviour(self, name: str, regex: str) -> None:
        self.assertTrue(regex, f"{name}: empty fatal regex")
        for line in FATAL_SCAN_MUST_MATCH:
            with self.subTest(scan=name, line=line, expect="match"):
                matched = subprocess.run(
                    ["grep", "-aiqE", "--", regex],
                    input=line + "\n",
                    text=True,
                ).returncode
                self.assertEqual(
                    matched, 0, f"{name} fails to flag a real fault line: {line!r}"
                )
        for line in FATAL_SCAN_MUST_NOT_MATCH:
            with self.subTest(scan=name, line=line, expect="no match"):
                matched = subprocess.run(
                    ["grep", "-aiqE", "--", regex],
                    input=line + "\n",
                    text=True,
                ).returncode
                self.assertEqual(
                    matched, 1, f"{name} false-positives on a benign line: {line!r}"
                )

    def test_suite_common_scan_flags_faults_and_ignores_benign_lines(self) -> None:
        self.assert_scan_behaviour("suite-common.sh", self.suite_common_regex())

    def test_root_gates_scan_flags_faults_and_ignores_benign_lines(self) -> None:
        self.assert_scan_behaviour("run-root-gates.sh", self.root_gates_regex())

    def resolved_regex(self, script: str, variable: str) -> str:
        """Resolve a scan's effective regex the way the script itself would.

        Both scripts below source `suite-common.sh`, so the default expands to
        `SUITE_DMESG_FATAL_RE`; resolving it through bash rather than textually
        keeps this honest if either one goes back to a private copy.
        """
        result = subprocess.run(
            [
                "bash",
                "-c",
                f'source ./suite-common.sh >/dev/null 2>&1; '
                f'source ./{script} >/dev/null 2>&1; printf "%s" "${variable}"',
            ],
            cwd=self.tests_dir,
            capture_output=True,
            text=True,
        )
        return result.stdout

    def expanded_assignment(self, script: str, variable: str) -> str:
        """Expand one assignment from a script that cannot simply be sourced.

        Runnable gates exit early on their own argument/root checks, so lift the
        assignment out textually and expand it with `suite-common.sh` in scope —
        these patterns interpolate `$SUITE_DMESG_FATAL_RE`.
        """
        for line in (self.tests_dir / script).read_text(encoding="utf-8").splitlines():
            if line.startswith(f"{variable}="):
                result = subprocess.run(
                    [
                        "bash",
                        "-c",
                        f'source ./suite-common.sh >/dev/null 2>&1; {line}; '
                        f'printf "%s" "${variable}"',
                    ],
                    cwd=self.tests_dir,
                    capture_output=True,
                    text=True,
                )
                return result.stdout
        self.fail(f"no {variable} assignment found in {script}")

    def test_ioctl_fuzz_scan_flags_faults_and_ignores_benign_lines(self) -> None:
        # This scan carried its own pre-2026-07 copy of the signature set: it
        # missed all six RK3588 IOMMU/RGA fault lines and fired on the harness's
        # own `rga-mmu-debug:` markers and on `pstore.backend=ramoops`.
        self.assert_scan_behaviour(
            "ioctl-fuzz-smoke.sh",
            self.expanded_assignment("ioctl-fuzz-smoke.sh", "IOCTL_FUZZ_DMESG_FATAL_RE"),
        )

    def test_recovery_stress_scan_flags_faults_and_ignores_benign_lines(self) -> None:
        # Same drifted copy, in a script that already sourced suite-common.sh
        # and simply left SUITE_DMESG_FATAL_RE unused.
        source = (self.tests_dir / "rewrite-recovery-stress.sh").read_text(encoding="utf-8")
        self.assertIn("RECOVERY_DMESG_FATAL_RE:-$SUITE_DMESG_FATAL_RE", source)
        self.assert_scan_behaviour(
            "rewrite-recovery-stress.sh",
            self.resolved_regex("suite-common.sh", "SUITE_DMESG_FATAL_RE"),
        )

    def test_root_gates_regex_is_byte_identical_to_suite_common(self) -> None:
        # run-root-gates.sh keeps a standalone copy so it can run as root
        # without the suite helpers. The copies drifted apart once, so the
        # duplication is allowed but the divergence is not.
        self.assertEqual(
            self.root_gates_regex(),
            self.suite_common_regex(),
            "run-root-gates.sh FATAL_RE has drifted from SUITE_DMESG_FATAL_RE",
        )

    def test_vp9_repro_scan_flags_faults_and_ignores_benign_lines(self) -> None:
        self.assert_scan_behaviour(
            "mpp-vp9-show-existing-repro.sh",
            self.resolved_regex("suite-common.sh", "SUITE_DMESG_FATAL_RE"),
        )
        source = (self.tests_dir / "mpp-vp9-show-existing-repro.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn('grep -aiqE "$SUITE_DMESG_FATAL_RE"', source)

    def test_iommu_fuzz_and_encode_scans_extend_the_canonical_set(self) -> None:
        # Both harnesses add their own alternatives, so they are supersets of the
        # canonical set rather than copies of it; assert the canonical set is
        # actually in scope and that the union still behaves.
        for script in ("iommu-machinery-fuzz.sh", "encode-test-tiny.sh"):
            source = (self.tests_dir / script).read_text(encoding="utf-8")
            with self.subTest(script=script):
                self.assertIn("suite-common.sh", source)
                self.assertIn("$SUITE_DMESG_FATAL_RE", source)
        self.assert_scan_behaviour(
            "iommu-machinery-fuzz.sh",
            self.expanded_assignment("iommu-machinery-fuzz.sh", "FAULT_RE"),
        )

    def test_kasan_scan_matches_suite_common_case_insensitivity(self) -> None:
        # sanitizer-scan.sh reuses SUITE_DMESG_FATAL_RE, whose set contains
        # case-varying signatures ("IOMMU"/"iommu"); a case-SENSITIVE grep here
        # silently dropped them.
        source = (self.tests_dir / "sanitizer-scan.sh").read_text(encoding="utf-8")
        self.assertIn('grep -aiE "$SUITE_DMESG_FATAL_RE"', source)


class ConformanceHarnessPlanTests(unittest.TestCase):
    """Pin target/configuration selection without touching board hardware."""

    runner = REPO_ROOT / "kernel-drivers/tests/run-conformance.sh"
    catalog = REPO_ROOT / "kernel-drivers/tests/conformance/TESTS.tsv"

    def run_plan(self, *arguments: str, env: dict[str, str] | None = None):
        command_env = os.environ.copy()
        for variable in (
            "PROFILE",
            "VALIDATE_ONLY",
            "RUN_COMPARE",
            "COMPARE_BASELINE",
            "CONFORMANCE_TARGET",
            "CONFORMANCE_CONFIGURATION",
            "CONFORMANCE_CATALOG",
            "CONFORMANCE_ONLY_TESTS",
            "CONFORMANCE_INCLUDE_TESTS",
            "CONFORMANCE_SKIP_TESTS",
            "CONFORMANCE_KERNEL_CONFIG",
            "CONFORMANCE_KERNEL_RELEASE",
        ):
            command_env.pop(variable, None)
        if env:
            command_env.update(env)
        return subprocess.run(
            ["bash", str(self.runner), *arguments, "--plan"],
            cwd=REPO_ROOT,
            env=command_env,
            capture_output=True,
            text=True,
        )

    def run_auto_plan(self, release: str, *config: str):
        with tempfile.TemporaryDirectory() as temporary:
            config_file = Path(temporary) / "kernel.config"
            config_file.write_text("\n".join(config) + "\n", encoding="utf-8")
            return self.run_plan(
                env={
                    "CONFORMANCE_KERNEL_CONFIG": str(config_file),
                    "CONFORMANCE_KERNEL_RELEASE": release,
                }
            )

    @staticmethod
    def selections(output: str) -> dict[str, str]:
        rows: dict[str, str] = {}
        for line in output.splitlines():
            if line == "kind\tname\tgroup\tdefault\tselection\tdescription":
                continue
            fields = line.split("\t")
            if fields[0] == "test":
                rows[fields[1]] = fields[4]
        return rows

    def test_plan_is_one_rectangular_tsv_schema(self) -> None:
        result = self.run_plan(
            "--target", "rewrite", "--configuration", "production"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = [line.split("\t") for line in result.stdout.splitlines()]
        self.assertGreater(len(rows), 1)
        self.assertEqual(
            rows[0],
            ["kind", "name", "group", "default", "selection", "description"],
        )
        self.assertTrue(all(len(row) == len(rows[0]) for row in rows))

    def test_abi_replay_is_excluded_from_bsp(self) -> None:
        bsp = self.run_plan("--target", "bsp", "--configuration", "production")
        rewrite = self.run_plan(
            "--target", "rewrite", "--configuration", "production"
        )
        self.assertEqual(bsp.returncode, 0, bsp.stderr)
        self.assertEqual(rewrite.returncode, 0, rewrite.stderr)
        bsp_rows = self.selections(bsp.stdout)
        rewrite_rows = self.selections(rewrite.stdout)
        for test_id in (
            "system-info",
            "matrix-identity",
            "mpp",
            "librga",
            "gstreamer",
            "ffmpeg",
        ):
            self.assertEqual(bsp_rows[test_id], "selected")
            self.assertEqual(rewrite_rows[test_id], "selected")
        self.assertEqual(bsp_rows["abi"], "incompatible")
        self.assertEqual(rewrite_rows["abi"], "selected")
        self.assertEqual(bsp_rows["kunit"], "incompatible")
        self.assertEqual(rewrite_rows["kunit"], "selected")

    def test_configuration_specific_tests_are_selected_explicitly(self) -> None:
        result = self.run_plan(
            "--target",
            "forward-port",
            "--configuration",
            "kasan",
            "--include",
            "reset-session-kasan,ioctl-fuzz-kasan",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = self.selections(result.stdout)
        self.assertEqual(rows["reset-session-kasan"], "selected")
        self.assertEqual(rows["ioctl-fuzz-kasan"], "selected")
        self.assertEqual(rows["reset-contention"], "incompatible")

    def test_incompatible_explicit_test_fails_closed(self) -> None:
        result = self.run_plan(
            "--target",
            "bsp",
            "--configuration",
            "production",
            "--only",
            "reset-session-kasan",
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("is incompatible", result.stderr)

    def test_bsp_rejects_explicit_abi_replay(self) -> None:
        result = self.run_plan(
            "--target",
            "bsp",
            "--configuration",
            "production",
            "--only",
            "abi",
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("test abi is incompatible", result.stderr)

    def test_legacy_profile_resolves_both_axes(self) -> None:
        result = self.run_plan(env={"PROFILE": "rewrite-kcsan"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("matrix\tprofile\tidentity\t-\trewrite-kcsan\t", result.stdout)
        self.assertIn("matrix\tconfiguration\tidentity\t-\tkcsan\t", result.stdout)

    def test_empty_selection_fails_closed(self) -> None:
        result = self.run_plan(
            "--target",
            "bsp",
            "--configuration",
            "production",
            "--skip",
            "system-info,matrix-identity,abi,mpp,librga,gstreamer,ffmpeg",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no conformance tests are selected", result.stderr)

    def test_compare_requires_a_comparable_selected_test(self) -> None:
        result = self.run_plan(
            "--target",
            "bsp",
            "--configuration",
            "production",
            "--only",
            "system-info",
            "--compare-to",
            "forward-port",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("selected set has no comparable tests", result.stderr)

    def test_catalog_rejects_missing_standard_coverage(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            catalog = Path(temporary) / "TESTS.tsv"
            rows = self.catalog.read_text(encoding="utf-8").splitlines()
            catalog.write_text(
                "\n".join(row for row in rows if not row.startswith("mpp\t"))
                + "\n",
                encoding="utf-8",
            )
            result = self.run_plan(
                "--target",
                "rewrite",
                "--configuration",
                "production",
                env={"CONFORMANCE_CATALOG": str(catalog)},
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("standard conformance catalog is missing mpp", result.stderr)

    def test_catalog_rejects_non_rectangular_rows(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            catalog = Path(temporary) / "TESTS.tsv"
            rows = self.catalog.read_text(encoding="utf-8").splitlines()
            rows[1] += "\textra"
            catalog.write_text("\n".join(rows) + "\n", encoding="utf-8")
            result = self.run_plan(
                "--target",
                "rewrite",
                "--configuration",
                "production",
                env={"CONFORMANCE_CATALOG": str(catalog)},
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("expected 9 tab-separated fields, found 10", result.stderr)

    def test_catalog_rejects_builtin_semantic_substitution(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            catalog = Path(temporary) / "TESTS.tsv"
            rows = self.catalog.read_text(encoding="utf-8").splitlines()
            rows = [
                row.replace("kunit\tboot\trewrite\tall\tyes\tbuiltin\tkunit\t", "kunit\tboot\trewrite\tall\tyes\tbuiltin\tsystem-info\t")
                for row in rows
            ]
            catalog.write_text("\n".join(rows) + "\n", encoding="utf-8")
            result = self.run_plan(
                "--target",
                "rewrite",
                "--configuration",
                "production",
                env={"CONFORMANCE_CATALOG": str(catalog)},
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "builtin catalog id kunit must match its argument system-info",
            result.stderr,
        )

    @source_audit_test
    def test_validate_continue_cannot_finalize_failed_stage_as_pass(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            command_env = os.environ.copy()
            command_env.update(
                {
                    "CONFORMANCE_ROOT": temporary,
                    "REQUIRE_FORBIDDEN_COUNTERS": "0",
                }
            )
            result = subprocess.run(
                [
                    "bash",
                    str(self.runner),
                    "--target",
                    "rewrite",
                    "--configuration",
                    "production",
                    "--validate",
                    "--continue",
                ],
                cwd=REPO_ROOT,
                env=command_env,
                capture_output=True,
                text=True,
            )
            ledgers = list(Path(temporary).glob("logs/**/*.tsv"))
            result_ledgers = [
                path for path in ledgers if path.name.endswith("-results.tsv")
            ]
            self.assertEqual(len(result_ledgers), 1, ledgers)
            ledger = result_ledgers[0].read_text(encoding="utf-8")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("validate.counter-defaults\trequired\tfail", ledger)
        self.assertIn("overall\trun\tfail\t1", ledger)
        self.assertNotIn("overall\trun\tpass", ledger)

    def test_vendor_bsp_series_are_autodetected(self) -> None:
        for release in ("5.10.221-vendor", "6.1.99-vendor", "6.6.80-vendor"):
            with self.subTest(release=release):
                result = self.run_auto_plan(
                    release,
                    "CONFIG_ROCKCHIP_MPP_SERVICE=y",
                    "CONFIG_ROCKCHIP_MULTI_RGA=y",
                    "CONFIG_VIDEO_ROCKCHIP_RGA=m",
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("matrix\ttarget\tidentity\t-\tbsp\t", result.stdout)
                self.assertIn(
                    "matrix\tconfiguration\tidentity\t-\tproduction\t",
                    result.stdout,
                )
                self.assertIn(
                    "matrix\ttarget-selection\tidentity\t-\tautodetected\t",
                    result.stdout,
                )

    def test_other_vendor_series_are_forward_ports(self) -> None:
        for release in ("6.7.12-ysp", "6.18.38-ysp", "7.2.0-rc5-ysp"):
            with self.subTest(release=release):
                result = self.run_auto_plan(
                    release,
                    "CONFIG_ROCKCHIP_MPP_SERVICE=y",
                    "CONFIG_ROCKCHIP_MULTI_RGA=y",
                    "CONFIG_VIDEO_ROCKCHIP_RGA=m",
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(
                    "matrix\ttarget\tidentity\t-\tforward-port\t", result.stdout
                )
                self.assertIn(
                    "matrix\tconfiguration\tidentity\t-\tproduction\t",
                    result.stdout,
                )

    def test_rewrite_and_sanitizers_are_autodetected_from_kconfig(self) -> None:
        rewrite = self.run_auto_plan(
            "6.6.80-rewrite",
            "CONFIG_ROCKCHIP_MPP_REWRITE=y",
            "CONFIG_ROCKCHIP_RGA_REWRITE=y",
            "CONFIG_KASAN=y",
        )
        self.assertEqual(rewrite.returncode, 0, rewrite.stderr)
        self.assertIn("matrix\ttarget\tidentity\t-\trewrite\t", rewrite.stdout)
        self.assertIn(
            "matrix\tconfiguration\tidentity\t-\tkasan\t", rewrite.stdout
        )

        kcsan = self.run_auto_plan(
            "6.18.38-ysp",
            "CONFIG_ROCKCHIP_MPP_SERVICE=y",
            "CONFIG_ROCKCHIP_MULTI_RGA=y",
            "CONFIG_VIDEO_ROCKCHIP_RGA=m",
            "CONFIG_KCSAN=y",
        )
        self.assertEqual(kcsan.returncode, 0, kcsan.stderr)
        self.assertIn(
            "matrix\ttarget\tidentity\t-\tforward-port\t", kcsan.stdout
        )
        self.assertIn(
            "matrix\tconfiguration\tidentity\t-\tkcsan\t", kcsan.stdout
        )

    def test_contradictory_sanitizer_config_fails_closed(self) -> None:
        result = self.run_auto_plan(
            "6.18.38-ysp",
            "CONFIG_ROCKCHIP_MPP_SERVICE=y",
            "CONFIG_ROCKCHIP_MULTI_RGA=y",
            "CONFIG_VIDEO_ROCKCHIP_RGA=m",
            "CONFIG_KASAN=y",
            "CONFIG_KCSAN=y",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cannot uniquely autodetect conformance configuration", result.stderr)


class RewriteKunitSourceAuditTests(unittest.TestCase):
    audit = (
        REPO_ROOT
        / "kernel-drivers"
        / "tests"
        / "rewrite-kunit-source-audit.py"
    )

    def write_source(
        self, root: Path, relative: str, config: str, body: str
    ) -> None:
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            f"#if IS_ENABLED({config})\n"
            "static void fixture_kunit(struct kunit *test)\n"
            "{\n"
            f"{body}"
            "}\n"
            "static struct kunit_suite fixture_suite = {};\n"
            "kunit_test_suite(fixture_suite);\n"
            "#endif\n",
            encoding="utf-8",
        )

    def make_tree(self, root: Path, body: str) -> None:
        self.write_source(
            root,
            "drivers/video/rockchip/mpp-rewrite/mpp_rewrite.c",
            "CONFIG_ROCKCHIP_MPP_REWRITE_KUNIT_TEST",
            body,
        )
        self.write_source(
            root,
            "drivers/video/rockchip/rga-rewrite/rga_rewrite.c",
            "CONFIG_ROCKCHIP_RGA_REWRITE_KUNIT_TEST",
            body,
        )

    def run_audit(
        self, tree: Path, baseline: Path, *options: str
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                str(self.audit),
                "--baseline",
                str(baseline),
                *options,
                str(tree),
            ],
            capture_output=True,
            text=True,
        )

    def test_known_fixture_debt_passes_but_new_signal_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            tree = root / "linux"
            baseline = root / "baseline.tsv"
            original = (
                "\tvoid *item;\n"
                "\titem = kzalloc(16, GFP_KERNEL);\n"
                "\tKUNIT_ASSERT_NOT_NULL(test, item);\n"
            )
            self.make_tree(tree, original)
            updated = self.run_audit(tree, baseline, "--update-baseline")
            self.assertEqual(updated.returncode, 0, updated.stderr)

            known = self.run_audit(tree, baseline)
            self.assertEqual(known.returncode, 0, known.stderr)

            self.make_tree(
                tree,
                original + "\tlist_add_tail(&item->link, &rk_mpp_srv.hw_list);\n",
            )
            changed = self.run_audit(tree, baseline)
            self.assertEqual(changed.returncode, 1)
            self.assertIn("NEW\tmanual-list-link", changed.stderr)
            self.assertIn("NEW\tproduction-singleton-access", changed.stderr)

    def test_resolved_fixture_debt_does_not_require_rebaselining(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            tree = root / "linux"
            baseline = root / "baseline.tsv"
            self.make_tree(
                tree,
                "\tvoid *item;\n"
                "\titem = kzalloc(16, GFP_KERNEL);\n"
                "\tKUNIT_ASSERT_NOT_NULL(test, item);\n",
            )
            updated = self.run_audit(tree, baseline, "--update-baseline")
            self.assertEqual(updated.returncode, 0, updated.stderr)

            self.make_tree(tree, "\tKUNIT_EXPECT_EQ(test, 1, 1);\n")
            resolved = self.run_audit(tree, baseline)
            self.assertEqual(resolved.returncode, 0, resolved.stderr)
            self.assertIn("baseline entries absent", resolved.stdout)

    def test_all_kunit_regions_and_project_wrappers_are_audited(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            tree = root / "linux"
            baseline = root / "baseline.tsv"
            self.make_tree(tree, "\tKUNIT_EXPECT_EQ(test, 1, 1);\n")
            baseline.write_text(
                "# category\tsource\tfunction\tordinal\tnormalized source signal\n",
                encoding="utf-8",
            )

            source = (
                tree
                / "drivers/video/rockchip/mpp-rewrite/mpp_rewrite.c"
            )
            existing = source.read_text(encoding="utf-8")
            source.write_text(
                "#if IS_ENABLED(CONFIG_ROCKCHIP_MPP_REWRITE_KUNIT_TEST)\n"
                "static void early_fixture_kunit(struct kunit *test)\n"
                "{\n"
                "\tvoid *item = kzalloc_obj(*item);\n"
                "\tint fd = rk_rga_fence_create_fd(test);\n"
                "\tKUNIT_ASSERT_NOT_NULL(test, item);\n"
                "\tKUNIT_ASSERT_GE(test, fd, 0);\n"
                "\tKUNIT_EXPECT_PTR_EQ(test, &rk_mpp_srv, &rk_mpp_srv);\n"
                "}\n"
                "#endif\n"
                f"{existing}",
                encoding="utf-8",
            )

            audited = self.run_audit(tree, baseline)
            self.assertEqual(audited.returncode, 1)
            self.assertIn("NEW\traw-allocation", audited.stderr)
            self.assertIn("NEW\tfd-acquisition", audited.stderr)
            self.assertIn("NEW\tfatal-before-cleanup-action", audited.stderr)
            self.assertIn("NEW\tproduction-singleton-access", audited.stderr)


@source_audit_test
class RewriteOwnershipSourceAuditTests(unittest.TestCase):
    audit = (
        REPO_ROOT
        / "kernel-drivers"
        / "tests"
        / "rewrite-ownership-source-audit.py"
    )

    def make_tree(
        self,
        root: Path,
        extra_mpp: str = "",
        extra_kunit: str = "",
        extra_rga: str = "",
    ) -> None:
        mpp = root / "drivers/video/rockchip/mpp-rewrite/mpp_rewrite.c"
        rga = root / "drivers/video/rockchip/rga-rewrite/rga_rewrite.c"
        mpp.parent.mkdir(parents=True, exist_ok=True)
        rga.parent.mkdir(parents=True, exist_ok=True)
        phase3h_core = """static bool
rk_mpp_activation_ref_empty(const struct rk_mpp_activation_ref *ref)
{
	return ref && !ref->activation && !ref->generation;
}
static bool
rk_mpp_activation_ref_valid(const struct rk_mpp_activation_ref *ref)
{
	return ref && ref->activation && ref->generation &&
	       ref->activation->job;
}
static bool rk_mpp_activation_ref_get(struct rk_mpp_activation_ref *ref,
		struct rk_mpp_activation *activation)
{
	struct rk_mpp_job *job;
	if (!rk_mpp_activation_ref_empty(ref) || !activation ||
	    !activation->generation)
		return false;
	job = activation->job;
	if (!job || !refcount_inc_not_zero(&activation->refs))
		return false;
	rk_mpp_job_get(job);
	ref->activation = activation;
	ref->generation = activation->generation;
	return true;
}
static bool rk_mpp_activation_ref_clone(struct rk_mpp_activation_ref *dst,
		const struct rk_mpp_activation_ref *src)
{
	struct rk_mpp_activation *activation;
	struct rk_mpp_job *job;
	if (!rk_mpp_activation_ref_empty(dst) ||
	    !rk_mpp_activation_ref_valid(src))
		return false;
	activation = src->activation;
	job = activation->job;
	if (src->generation != activation->generation ||
	    !refcount_inc_not_zero(&activation->refs))
		return false;
	rk_mpp_job_get(job);
	*dst = *src;
	return true;
}
static bool rk_mpp_activation_ref_move(struct rk_mpp_activation_ref *dst,
		struct rk_mpp_activation_ref *src)
{
	if (!rk_mpp_activation_ref_empty(dst) ||
	    !rk_mpp_activation_ref_valid(src))
		return false;
	*dst = *src;
	memset(src, 0, sizeof(*src));
	return true;
}
static bool rk_mpp_activation_ref_put(struct rk_mpp_activation_ref *ref)
{
	struct rk_mpp_activation *activation;
	struct rk_mpp_job *job;
	if (!rk_mpp_activation_ref_valid(ref))
		return false;
	activation = ref->activation;
	job = activation->job;
	WARN_ON_ONCE(ref->generation != activation->generation);
	if (refcount_read(&activation->refs) <= 1)
		return false;
	if (WARN_ON_ONCE(!refcount_dec_not_one(&activation->refs)))
		return false;
	memset(ref, 0, sizeof(*ref));
	rk_mpp_activation_try_reclaim(activation);
	rk_mpp_job_put(job);
	return true;
}
static bool rk_mpp_activation_refs_released(
		const struct rk_mpp_activation *activation)
{
	return activation && refcount_read(&activation->refs) == 1;
}
static bool rk_mpp_transition_yields_to_fault(
		enum rk_mpp_activation_transition_reason reason)
{
	return reason == RK_MPP_TRANSITION_IRQ ||
	       reason == RK_MPP_TRANSITION_CCU_DONE ||
	       reason == RK_MPP_TRANSITION_TIMEOUT;
}
static struct rk_mpp_activation *rk_mpp_hw_claim_active_locked(
		struct rk_mpp_hw *hw, struct rk_mpp_activation *match,
		u64 generation,
		enum rk_mpp_activation_transition_reason reason,
		struct rk_mpp_activation_claim_token *token)
{
	struct rk_mpp_activation *activation;
	lockdep_assert_held(&hw->lock);
	if (!token || !rk_mpp_activation_ref_empty(&token->ref) || token->reason)
		return NULL;
	if (reason <= RK_MPP_TRANSITION_NONE ||
	    reason >= RK_MPP_TRANSITION_COUNT ||
	    reason == RK_MPP_TRANSITION_RETRY_REPLACED)
		return NULL;
	activation = hw->active_ref.activation;
	if (!activation || !activation->job ||
	    activation->job->current_activation != activation ||
	    hw->active_ref.generation != activation->generation ||
	    (match && activation != match) ||
	    (generation && hw->active_ref.generation != generation) ||
	    (hw->iommu_fault_pending &&
	     rk_mpp_transition_yields_to_fault(reason)))
		return NULL;
	if (WARN_ON_ONCE(activation->slot_state != RK_MPP_ACTIVATION_SLOTTED ||
			 activation->transition_reason != RK_MPP_TRANSITION_NONE))
		return NULL;
	if (!rk_mpp_activation_ref_move(&token->ref, &hw->active_ref))
		return NULL;
	activation->slot_state = RK_MPP_ACTIVATION_CLAIMED;
	activation->transition_reason = reason;
	if (WARN_ON_ONCE(!rk_mpp_activation_note_reason(activation, reason,
						false, 0))) {
		activation->slot_state = RK_MPP_ACTIVATION_SLOTTED;
		activation->transition_reason = RK_MPP_TRANSITION_NONE;
		WARN_ON_ONCE(!rk_mpp_activation_ref_move(&hw->active_ref,
							 &token->ref));
		return NULL;
	}
	token->reason = reason;
	return activation;
}
static bool rk_mpp_hw_restore_active_locked(
		struct rk_mpp_hw *hw,
		struct rk_mpp_activation_claim_token *token)
{
	struct rk_mpp_activation *activation;
	lockdep_assert_held(&hw->lock);
	if (!token || !rk_mpp_activation_ref_valid(&token->ref))
		return false;
	activation = token->ref.activation;
	if (WARN_ON_ONCE(activation &&
			 (!activation->job ||
			  activation->job->current_activation != activation ||
			  list_empty(&activation->job_link))))
		return false;
	if (!rk_mpp_activation_ref_empty(&hw->active_ref))
		return false;
	if (WARN_ON_ONCE(!activation || activation->slot_state !=
			 RK_MPP_ACTIVATION_CLAIMED ||
			 activation->transition_reason != token->reason ||
			 activation->generation != token->ref.generation ||
			 token->reason == RK_MPP_TRANSITION_NONE))
		return false;
	activation->slot_state = RK_MPP_ACTIVATION_SLOTTED;
	activation->transition_reason = RK_MPP_TRANSITION_NONE;
	if (!rk_mpp_activation_ref_move(&hw->active_ref, &token->ref))
		return false;
	token->reason = RK_MPP_TRANSITION_NONE;
	return true;
}
static void rk_mpp_batch_get_job(struct rk_mpp_job *job)
{
	rk_mpp_activation_init(job);
}
static void rk_mpp_hw_begin_active_job(
		struct rk_mpp_hw *hw, struct rk_mpp_job *job)
{
	rk_mpp_hw_install_active_locked(hw, job);
}
static struct rk_mpp_job *
rk_mpp_activation_claim_job(const struct rk_mpp_activation_claim_token *token)
{
	if (!token || !rk_mpp_activation_ref_valid(&token->ref))
		return NULL;
	return token->ref.activation->job;
}
static bool
rk_mpp_activation_claim_put(struct rk_mpp_activation_claim_token *token)
{
	struct rk_mpp_activation *activation;
	struct rk_mpp_job *job;
	if (!token || !rk_mpp_activation_ref_valid(&token->ref))
		return false;
	activation = token->ref.activation;
	job = rk_mpp_activation_claim_job(token);
	if (!job || activation->generation != token->ref.generation ||
	    activation->transition_reason != token->reason ||
	    !rk_mpp_activation_retirement_released(activation))
		return false;
	if (!rk_mpp_activation_ref_put(&token->ref))
		return false;
	token->reason = RK_MPP_TRANSITION_NONE;
	return true;
}
static bool rk_mpp_activation_complete_claim(
		struct rk_mpp_job *job,
		struct rk_mpp_activation_claim_token *token, int result)
{
	if (!job || job != rk_mpp_activation_claim_job(token) ||
	    !rk_mpp_activation_retirement_released(token->ref.activation))
		return false;
	if (!rk_mpp_job_complete(job, result))
		return false;
	return rk_mpp_activation_claim_put(token);
}
static bool rk_mpp_activation_finish_terminal_locked(
		struct rk_mpp_hw *hw, struct rk_mpp_hw *ccu,
		struct rk_mpp_activation_claim_token *token, int core_status,
		const struct rk_mpp_cluster_recovery_result *core,
		int group_status,
		const struct rk_mpp_cluster_recovery_result *group)
{
	struct rk_mpp_activation *activation;
	struct rk_mpp_job *job;
	bool group_scope = !!group;
	lockdep_assert_held(&hw->run_lock);
	lockdep_assert_held(&hw->lock);
	if (!token || !rk_mpp_activation_ref_valid(&token->ref) || !core)
		return false;
	activation = token->ref.activation;
	job = activation->job;
	if (!job || activation != READ_ONCE(job->current_activation) ||
	    activation->selected_hw != hw || list_empty(&activation->job_link) ||
	    activation->generation != token->ref.generation ||
	    activation->transition_reason != token->reason ||
	    activation->slot_state != RK_MPP_ACTIVATION_CLAIMED ||
	    !rk_mpp_activation_closure_pristine(activation) ||
	    !rk_mpp_activation_ref_empty(&hw->active_ref))
		return false;
	if (group_scope) {
		if (!ccu || group_status || !group->quiesced ||
		    rk_mpp_job_resources(job)->rkvdec_ccu != ccu ||
		    READ_ONCE(hw->cluster) !=
						 READ_ONCE(ccu->cluster))
			return false;
		lockdep_assert_held(&ccu->ccu_recovery_lock);
		activation->closure.group.result = *group;
		activation->closure.group.status = group_status;
		activation->closure.group.valid = true;
		activation->closure.core.result = *core;
		activation->closure.core.status = core_status;
		activation->closure.core.valid = true;
		activation->closure.terminal_scope =
			RK_MPP_ACTIVATION_RETIREMENT_CCU_GROUP;
	} else {
		if (core_status || !core->quiesced)
			return false;
		activation->closure.terminal.result = *core;
		activation->closure.terminal.status = core_status;
		activation->closure.terminal.valid = true;
		activation->closure.terminal_scope =
			RK_MPP_ACTIVATION_RETIREMENT_CORE;
	}
	activation->closure.state = RK_MPP_ACTIVATION_CLOSURE_RETIRED;
	activation->slot_state = RK_MPP_ACTIVATION_RETIRED;
	return true;
}
static bool rk_mpp_activation_finish_terminal(
		struct rk_mpp_hw *hw, struct rk_mpp_hw *ccu,
		struct rk_mpp_activation_claim_token *token, int core_status,
		const struct rk_mpp_cluster_recovery_result *core,
		int group_status,
		const struct rk_mpp_cluster_recovery_result *group)
{
	unsigned long flags;
	bool finished;
	lockdep_assert_held(&hw->run_lock);
	spin_lock_irqsave(&hw->lock, flags);
	finished = rk_mpp_activation_finish_terminal_locked(hw, ccu, token,
							    core_status, core,
							    group_status, group);
	spin_unlock_irqrestore(&hw->lock, flags);
	return finished;
}
static bool rk_mpp_activation_finish_observed_terminal_locked(
		struct rk_mpp_hw *hw, struct rk_mpp_hw *ccu,
		struct rk_mpp_activation_claim_token *token,
		enum rk_mpp_activation_terminal_observation observation,
		u32 hw_status, bool bus_idle_checked, int bus_idle_status)
{
	struct rk_mpp_activation *activation;
	struct rk_mpp_job *job;
	lockdep_assert_held(&hw->run_lock);
	lockdep_assert_held(&hw->lock);
	if (!token || !rk_mpp_activation_ref_valid(&token->ref) ||
	    observation <= RK_MPP_ACTIVATION_OBSERVATION_NONE ||
	    observation >= RK_MPP_ACTIVATION_OBSERVATION_COUNT)
		return false;
	activation = token->ref.activation;
	job = activation->job;
	if (!job || activation != READ_ONCE(job->current_activation) ||
	    activation->selected_hw != hw || list_empty(&activation->job_link) ||
	    activation->generation != token->ref.generation ||
	    activation->transition_reason != token->reason ||
	    activation->slot_state != RK_MPP_ACTIVATION_CLAIMED ||
	    !rk_mpp_activation_closure_pristine(activation) ||
	    !rk_mpp_activation_ref_empty(&hw->active_ref))
		return false;
	switch (observation) {
	case RK_MPP_ACTIVATION_OBSERVATION_NOT_PUBLISHED:
		if (token->reason != RK_MPP_TRANSITION_START_FAILURE || ccu ||
		    hw_status || bus_idle_checked || bus_idle_status)
			return false;
		break;
	case RK_MPP_ACTIVATION_OBSERVATION_IRQ_ACCEPTED:
		if (token->reason != RK_MPP_TRANSITION_IRQ || ccu || !hw_status)
			return false;
		if (job->client_type == RK_MPP_DEVICE_RKVDEC) {
			if (!bus_idle_checked && bus_idle_status != -EOPNOTSUPP)
				return false;
		} else if (bus_idle_checked || bus_idle_status) {
			return false;
		}
		break;
	case RK_MPP_ACTIVATION_OBSERVATION_CCU_DONE_ACCEPTED:
		if (token->reason != RK_MPP_TRANSITION_CCU_DONE || !hw_status ||
		    !ccu || rk_mpp_job_resources(job)->rkvdec_ccu != ccu ||
		    READ_ONCE(hw->cluster) != READ_ONCE(ccu->cluster) ||
		    (!bus_idle_checked && bus_idle_status != -EOPNOTSUPP))
			return false;
		lockdep_assert_held(&ccu->ccu_recovery_lock);
		break;
	default:
		return false;
	}
	activation->closure.observation.kind = observation;
	activation->closure.observation.hw_status = hw_status;
	activation->closure.observation.bus_idle_status = bus_idle_status;
	activation->closure.observation.bus_idle_checked = bus_idle_checked;
	activation->closure.observation.valid = true;
	activation->closure.state = RK_MPP_ACTIVATION_CLOSURE_RETIRED;
	activation->slot_state = RK_MPP_ACTIVATION_RETIRED;
	return true;
}
static bool rk_mpp_activation_finish_observed_terminal(
		struct rk_mpp_hw *hw, struct rk_mpp_hw *ccu,
		struct rk_mpp_activation_claim_token *token,
		enum rk_mpp_activation_terminal_observation observation,
		u32 hw_status, bool bus_idle_checked, int bus_idle_status)
{
	unsigned long flags;
	bool finished;
	lockdep_assert_held(&hw->run_lock);
	spin_lock_irqsave(&hw->lock, flags);
	finished = rk_mpp_activation_finish_observed_terminal_locked(hw, ccu,
							    token, observation,
							    hw_status,
							    bus_idle_checked,
							    bus_idle_status);
	spin_unlock_irqrestore(&hw->lock, flags);
	return finished;
}
static bool rk_mpp_activation_claim_quarantine(
		struct rk_mpp_hw *hw, struct rk_mpp_hw *ccu,
		struct rk_mpp_activation_claim_token *token,
		int quarantine_error, int core_status,
		const struct rk_mpp_cluster_recovery_result *core,
		int group_status,
		const struct rk_mpp_cluster_recovery_result *group)
{
	struct rk_mpp_activation *activation;
	struct rk_mpp_job *job;
	struct rk_mpp_hw *owned_ccu;
	struct rk_mpp_service *srv = hw->srv;
	unsigned long flags;
	bool group_scope;
	int error;
	lockdep_assert_held(&hw->run_lock);
	if (!token || !rk_mpp_activation_ref_valid(&token->ref) ||
	    token->reason <= RK_MPP_TRANSITION_NONE ||
	    token->reason >= RK_MPP_TRANSITION_RETRY_REPLACED)
		return false;
	activation = token->ref.activation;
	job = activation->job;
	if (!job || list_empty(&activation->job_link))
		return false;
	owned_ccu = rk_mpp_job_resources(job)->rkvdec_ccu;
	group_scope = ccu && ccu == owned_ccu &&
		READ_ONCE(hw->cluster) == READ_ONCE(ccu->cluster);
	if (group_scope)
		lockdep_assert_held(&ccu->ccu_recovery_lock);
	error = quarantine_error ?: core_status ?: group_status ?: -EUCLEAN;
	mutex_lock(&srv->quarantine_lock);
	spin_lock_irqsave(&hw->lock, flags);
	if (rk_mpp_activation_closure_pristine(activation)) {
		if (group_scope) {
			if (group) {
				activation->closure.group.result = *group;
				activation->closure.group.status = group_status;
				activation->closure.group.valid = true;
			}
			if (core) {
				activation->closure.core.result = *core;
				activation->closure.core.status = core_status;
				activation->closure.core.valid = true;
			}
			activation->closure.terminal_scope =
				RK_MPP_ACTIVATION_RETIREMENT_CCU_GROUP;
		} else if (core) {
			activation->closure.terminal.result = *core;
			activation->closure.terminal.status = core_status;
			activation->closure.terminal.valid = true;
			activation->closure.terminal_scope =
				RK_MPP_ACTIVATION_RETIREMENT_CORE;
		}
	}
	activation->closure.state = RK_MPP_ACTIVATION_CLOSURE_QUARANTINED;
	activation->slot_state = RK_MPP_ACTIVATION_QUARANTINED;
	activation->transition_reason = token->reason;
	activation->quarantine_generation = token->ref.generation;
	if (list_empty(&activation->quarantine_link)) {
		list_add_tail(&activation->quarantine_link,
			      &srv->quarantined_activations);
		atomic_inc(&srv->quarantine_count);
	}
	activation->quarantine_ref_count++;
	memset(&token->ref, 0, sizeof(token->ref));
	token->reason = RK_MPP_TRANSITION_NONE;
	spin_unlock_irqrestore(&hw->lock, flags);
	mutex_unlock(&srv->quarantine_lock);
	rk_mpp_hw_handle_reset_failure(hw, error);
	if (owned_ccu && owned_ccu != hw)
		rk_mpp_hw_handle_reset_failure(owned_ccu, error);
	return true;
}
static bool rk_mpp_hw_restore_or_quarantine(
		struct rk_mpp_hw *hw, struct rk_mpp_hw *ccu,
		struct rk_mpp_activation_claim_token *token,
		bool force_iommu_fault, int quarantine_error, int core_status,
		const struct rk_mpp_cluster_recovery_result *core,
		int group_status,
		const struct rk_mpp_cluster_recovery_result *group)
{
	unsigned long flags;
	bool restored;
	lockdep_assert_held(&hw->run_lock);
	spin_lock_irqsave(&hw->lock, flags);
	restored = rk_mpp_hw_restore_active_locked(hw, token);
	if (restored) {
		rk_mpp_hw_clear_irq_record_locked(hw);
		if (force_iommu_fault)
			hw->iommu_fault_pending = true;
		if (hw->iommu_fault_pending)
			hw->iommu_fault_generation =
				rk_mpp_hw_active_generation_locked(hw);
	}
	spin_unlock_irqrestore(&hw->lock, flags);
	if (restored)
		return true;
	WARN_ON_ONCE(!rk_mpp_activation_claim_quarantine(hw, ccu, token,
							 quarantine_error,
							 core_status, core,
							 group_status, group));
	return false;
}
static bool
rk_mpp_service_has_quarantined_activation(struct rk_mpp_service *srv)
{
	bool found;
	mutex_lock(&srv->quarantine_lock);
	found = !list_empty(&srv->quarantined_activations);
	mutex_unlock(&srv->quarantine_lock);
	return found;
}
static bool rk_mpp_hw_clear_active_job(
		struct rk_mpp_hw *hw, struct rk_mpp_job *job,
		enum rk_mpp_activation_transition_reason reason,
		u32 *irq_status,
		struct rk_mpp_activation_claim_token *token)
{
	struct rk_mpp_activation *activation;
	unsigned long flags;
	bool cleared = false;
	if (!token)
		return false;
	spin_lock_irqsave(&hw->lock, flags);
	activation = rk_mpp_hw_claim_active_locked(hw, job->current_activation, 0,
						   reason, token);
	if (activation) {
		if (irq_status)
			*irq_status = hw->irq_status;
		rk_mpp_hw_clear_irq_record_locked(hw);
		cleared = true;
	}
	spin_unlock_irqrestore(&hw->lock, flags);
	if (cleared)
		rk_mpp_hw_cancel_timeout(hw);
	return cleared;
}
static struct rk_mpp_job *rk_mpp_hw_take_active_job(
		struct rk_mpp_hw *hw,
		enum rk_mpp_activation_transition_reason reason,
		struct rk_mpp_activation_claim_token *token)
{
	return rk_mpp_activation_job(rk_mpp_hw_claim_active_locked(
		hw, NULL, 0, reason, token));
}
static struct rk_mpp_job *rk_mpp_hw_take_irq_job(
		struct rk_mpp_hw *hw,
		struct rk_mpp_activation_claim_token *token)
{
	return rk_mpp_activation_job(rk_mpp_hw_claim_active_locked(
		hw, NULL, 0, RK_MPP_TRANSITION_IRQ, token));
}
static bool rk_mpp_hw_take_active_if(
		struct rk_mpp_hw *hw, struct rk_mpp_job *match,
		struct rk_mpp_activation_claim_token *token)
{
	return !!rk_mpp_hw_claim_active_locked(
		hw, match->current_activation, 0,
		RK_MPP_TRANSITION_CCU_DONE, token);
}
static bool rk_mpp_hw_take_active_if_generation(
		struct rk_mpp_hw *hw,
		const struct rk_mpp_activation_ref *match,
		struct rk_mpp_activation_claim_token *token)
{
	return rk_mpp_activation_ref_valid(match) &&
	       !!rk_mpp_hw_claim_active_locked(hw, match->activation,
					      match->generation,
					      RK_MPP_TRANSITION_TIMEOUT, token);
}
static struct rk_mpp_job *rk_mpp_hw_take_iommu_fault_job(
		struct rk_mpp_hw *hw,
		struct rk_mpp_activation_claim_token *token)
{
	return rk_mpp_activation_job(rk_mpp_hw_claim_active_locked(
		hw, NULL, hw->iommu_fault_generation,
		RK_MPP_TRANSITION_IOMMU_FAULT, token));
}
static bool rk_mpp_hw_job_is_quarantined(
		struct rk_mpp_hw *hw, const struct rk_mpp_job *job)
{
	struct rk_mpp_activation *activation;
	unsigned long flags;
	bool quarantined;
	spin_lock_irqsave(&hw->lock, flags);
	activation = READ_ONCE(job->current_activation);
	quarantined = activation && activation->selected_hw == hw &&
		activation->slot_state == RK_MPP_ACTIVATION_QUARANTINED;
	spin_unlock_irqrestore(&hw->lock, flags);
	return quarantined;
}
static int rk_mpp_rkvdec2_wait_bus_idle(struct rk_mpp_hw *hw, bool *checked)
{
	u32 value;
	int ret;
	if (checked)
		*checked = false;
	if (atomic_read(&hw->power_count) <= 0 ||
	    !rk_mpp_hw_reg_range_valid(hw, 0, RK_MPP_RKVDEC_DEBUG_INT_BASE,
				       sizeof(u32)))
		return -EOPNOTSUPP;
	if (checked)
		*checked = true;
	ret = readl_poll_timeout(hw->regs[0] + RK_MPP_RKVDEC_DEBUG_INT_BASE,
				 value, value & RK_MPP_RKVDEC_DEBUG_BUS_IDLE, 1,
				 RK_MPP_CCU_STOP_TIMEOUT_US);
	if (ret) {
		atomic_inc(&hw->srv->rkvdec_bus_not_idle_count);
		if (hw->dev)
			dev_warn_ratelimited(hw->dev,
				"completing job with bus not idle after %uus\\n",
				RK_MPP_CCU_STOP_TIMEOUT_US);
	}
	return ret;
}
static bool rk_mpp_job_activation_storage_released(
		struct rk_mpp_job *job, struct rk_mpp_activation *activation)
{
	return rk_mpp_activation_storage_released(activation);
}
static bool rk_mpp_job_activation_hardware_released(struct rk_mpp_job *job)
{
	return true;
}
static void rk_mpp_job_release_activation_storage(struct rk_mpp_job *job)
{
	struct rk_mpp_activation *activation = job->current_activation;
	if (WARN_ON_ONCE(!rk_mpp_activation_refs_released(activation)))
		return;
	WRITE_ONCE(job->current_activation, NULL);
	WARN_ON_ONCE(!refcount_dec_and_test(&activation->refs));
}
static void rk_mpp_job_release(struct rk_mpp_job *job)
{
	rk_mpp_job_activation_storage_released(job, NULL);
	rk_mpp_job_activation_hardware_released(job);
	rk_mpp_job_release_activation_storage(job);
}
"""
        phase3h_callers = """static void rk_mpp_hw_abort_job(
		struct rk_mpp_hw *hw, struct rk_mpp_hw *ccu,
		struct rk_mpp_job *job)
{
	struct rk_mpp_activation_claim_token claim = {};
	struct rk_mpp_cluster_recovery_result recovery = {};
	struct rk_mpp_cluster_recovery_result ccu_recovery = {};
	struct rk_mpp_activation_claim_token clear_claim = {};
	if (rk_mpp_hw_job_is_quarantined(hw, job))
		return;
	rk_mpp_hw_clear_active_job(hw, job, RK_MPP_TRANSITION_SESSION_RESET,
				   NULL, &clear_claim);
	rk_mpp_activation_complete_claim(job, &claim, 0);
	rk_mpp_activation_finish_terminal(hw, ccu, &claim, 0, &recovery,
					  0, &ccu_recovery);
	rk_mpp_activation_finish_terminal(hw, NULL, &claim, 0, &recovery,
					  0, NULL);
	rk_mpp_hw_restore_or_quarantine(hw, ccu, &claim, false, 0, 0,
					&recovery, 0, &ccu_recovery);
	rk_mpp_hw_restore_or_quarantine(hw, ccu, &claim, false, 0, 0,
					&recovery, 0, &ccu_recovery);
	rk_mpp_hw_restore_or_quarantine(hw, NULL, &claim, false, 0, 0,
					&recovery, 0, NULL);
	rk_mpp_rkvdec2_restart_ccu_unfinished_jobs(ccu, &ccu_recovery);
}
static u32 rk_mpp_rkvdec2_drain_ccu_done_jobs(
		struct rk_mpp_hw *hw, struct rk_mpp_hw *ccu)
{
	struct rk_mpp_activation_claim_token claim = {};
	struct rk_mpp_cluster_recovery_result recovery = {};
	enum rk_mpp_activation_terminal_observation observation =
		RK_MPP_ACTIVATION_OBSERVATION_CCU_DONE_ACCEPTED;
	bool bus_idle_checked = false;
	bool ccu_error;
	bool finished;
	bool quarantined;
	u32 completed_status = 1;
	int bus_idle_status;
	rk_mpp_activation_complete_claim(job, &claim, 0);
	rk_mpp_activation_finish_terminal(hw, ccu, &claim, 0, &recovery,
					  0, &recovery);
	rk_mpp_hw_restore_or_quarantine(hw, ccu, &claim, false, 0, 0,
					&recovery, 0, &recovery);
	rk_mpp_hw_restore_or_quarantine(hw, ccu, &claim, false, 0, 0,
					&recovery, 0, &recovery);
	ccu_error = !!(completed_status & link_info->err_mask);
	bus_idle_status = rk_mpp_rkvdec2_wait_bus_idle(hw, &bus_idle_checked);
	finished = ccu_error || rk_mpp_activation_finish_observed_terminal(hw, ccu,
		&claim, observation, completed_status,
		bus_idle_checked, bus_idle_status);
	if (WARN_ON_ONCE(!finished)) {
		quarantined = rk_mpp_activation_claim_quarantine(
			hw, ccu, &claim, -EUCLEAN, 0, NULL, 0, NULL);
		break;
	}
	return 0;
}
static void rk_mpp_hw_recover_active(
		struct rk_mpp_hw *hw, struct rk_mpp_hw *ccu,
		const struct rk_mpp_activation_ref *timeout_ref)
{
	struct rk_mpp_activation_claim_token claim = {};
	struct rk_mpp_cluster_recovery_result recovery = {};
	struct rk_mpp_cluster_recovery_result ccu_recovery = {};
	rk_mpp_activation_complete_claim(job, &claim, 0);
	rk_mpp_activation_finish_terminal(hw, ccu, &claim, 0, &recovery,
					  0, &ccu_recovery);
	rk_mpp_activation_finish_terminal(hw, NULL, &claim, 0, &recovery,
					  0, NULL);
	rk_mpp_hw_restore_or_quarantine(hw, ccu, &claim, false, 0, 0,
					&recovery, 0, &ccu_recovery);
	rk_mpp_hw_restore_or_quarantine(hw, ccu, &claim, false, 0, 0,
					&recovery, 0, &ccu_recovery);
	rk_mpp_hw_restore_or_quarantine(hw, NULL, &claim, false, 0, 0,
					&recovery, 0, NULL);
	rk_mpp_hw_restore_or_quarantine(hw, NULL, &claim, false, 0, 0,
					&recovery, 0, NULL);
	rk_mpp_rkvdec2_restart_ccu_unfinished_jobs(ccu, &ccu_recovery);
}
static int rk_mpp_hw_abort_active(struct rk_mpp_hw *hw)
{
	struct rk_mpp_activation_claim_token claim = {};
	struct rk_mpp_cluster_recovery_result recovery = {};
	rk_mpp_activation_complete_claim(job, &claim, 0);
	rk_mpp_activation_finish_terminal(hw, NULL, &claim, 0, &recovery,
					  0, NULL);
	rk_mpp_hw_restore_or_quarantine(hw, NULL, &claim, false, 0, 0,
					&recovery, 0, NULL);
	rk_mpp_hw_restore_or_quarantine(hw, NULL, &claim, false, 0, 0,
					&recovery, 0, NULL);
	return 0;
}
static int rk_mpp_hw_abort_active_recovery_locked(
		struct rk_mpp_hw *hw, struct rk_mpp_hw *ccu)
{
	struct rk_mpp_activation_claim_token claim = {};
	struct rk_mpp_cluster_recovery_result recovery = {};
	rk_mpp_activation_complete_claim(job, &claim, 0);
	rk_mpp_activation_finish_terminal(hw, ccu, &claim, 0, &recovery,
					  0, &recovery);
	rk_mpp_hw_restore_or_quarantine(hw, ccu, &claim, false, 0, 0,
					&recovery, 0, &recovery);
	rk_mpp_hw_restore_or_quarantine(hw, ccu, &claim, false, 0, 0,
					&recovery, 0, &recovery);
	return 0;
}
static int rk_mpp_rkvenc2_submit(struct rk_mpp_job *job)
{
	struct rk_mpp_hw *hw = NULL;
	struct rk_mpp_activation_claim_token claim = {};
	bool cleared;
	bool finished;
	bool quarantined;
	cleared = rk_mpp_hw_clear_active_job(hw, job,
					     RK_MPP_TRANSITION_START_FAILURE,
					     NULL, &claim);
	finished = rk_mpp_activation_finish_observed_terminal(
		hw, NULL, &claim, RK_MPP_ACTIVATION_OBSERVATION_NOT_PUBLISHED,
		0, false, 0);
	if (WARN_ON_ONCE(!finished)) {
		quarantined = rk_mpp_activation_claim_quarantine(
			hw, NULL, &claim, -EUCLEAN, 0, NULL, 0, NULL);
		return 0;
	}
	WARN_ON_ONCE(!rk_mpp_activation_claim_put(&claim));
	cleared = rk_mpp_hw_clear_active_job(hw, job,
					     RK_MPP_TRANSITION_START_FAILURE,
					     NULL, &claim);
	finished = rk_mpp_activation_finish_observed_terminal(
		hw, NULL, &claim, RK_MPP_ACTIVATION_OBSERVATION_NOT_PUBLISHED,
		0, false, 0);
	if (WARN_ON_ONCE(!finished)) {
		quarantined = rk_mpp_activation_claim_quarantine(
			hw, NULL, &claim, -EUCLEAN, 0, NULL, 0, NULL);
		return 0;
	}
	WARN_ON_ONCE(!rk_mpp_activation_claim_put(&claim));
	return cleared;
}
static int rk_mpp_rkvenc2_thread(struct rk_mpp_hw *hw)
{
	struct rk_mpp_activation_claim_token claim = {};
	struct rk_mpp_cluster_recovery_result recovery = {};
	enum rk_mpp_activation_terminal_observation observation =
		RK_MPP_ACTIVATION_OBSERVATION_IRQ_ACCEPTED;
	bool finished;
	bool quarantined;
	u32 irq_status = 1;
	rk_mpp_activation_complete_claim(job, &claim, 0);
	rk_mpp_activation_finish_terminal(hw, NULL, &claim, 0, &recovery,
					  0, NULL);
	rk_mpp_hw_restore_or_quarantine(hw, NULL, &claim, false, 0, 0,
					&recovery, 0, NULL);
	rk_mpp_hw_restore_or_quarantine(hw, NULL, &claim, false, 0, 0,
					&recovery, 0, NULL);
	finished = rk_mpp_rkvenc2_irq_needs_reset(irq_status) ||
		rk_mpp_activation_finish_observed_terminal(
			hw, NULL, &claim, observation, irq_status, false, 0);
	if (WARN_ON_ONCE(!finished)) {
		quarantined = rk_mpp_activation_claim_quarantine(
			hw, NULL, &claim, -EUCLEAN, 0, NULL, 0, NULL);
		return 0;
	}
	return 0;
}
static int rk_mpp_rkvdec2_submit(struct rk_mpp_job *job)
{
	struct rk_mpp_hw *hw = NULL;
	struct rk_mpp_hw *ccu = NULL;
	struct rk_mpp_activation_claim_token claim = {};
	enum rk_mpp_activation_terminal_observation observation =
		RK_MPP_ACTIVATION_OBSERVATION_NOT_PUBLISHED;
	bool cleared;
	bool finished;
	bool quarantined;
	cleared = rk_mpp_hw_clear_active_job(hw, job,
					     RK_MPP_TRANSITION_START_FAILURE,
					     NULL, &claim);
	finished = rk_mpp_activation_finish_observed_terminal(
		hw, NULL, &claim, observation, 0, false, 0);
	if (WARN_ON_ONCE(!finished)) {
		quarantined = rk_mpp_activation_claim_quarantine(
			hw, ccu, &claim, -EUCLEAN, 0, NULL, 0, NULL);
		goto out;
	}
	WARN_ON_ONCE(!rk_mpp_activation_claim_put(&claim));
out:
	return cleared;
}
static int rk_mpp_rkvdec2_thread(struct rk_mpp_hw *hw)
{
	struct rk_mpp_activation_claim_token claim = {};
	struct rk_mpp_cluster_recovery_result recovery = {};
	enum rk_mpp_activation_terminal_observation observation =
		RK_MPP_ACTIVATION_OBSERVATION_IRQ_ACCEPTED;
	bool bus_idle_checked = false;
	bool finished;
	bool quarantined;
	u32 irq_status = 1;
	int bus_idle_status;
	rk_mpp_activation_complete_claim(job, &claim, 0);
	rk_mpp_activation_finish_terminal(hw, NULL, &claim, 0, &recovery,
					  0, NULL);
	rk_mpp_hw_restore_or_quarantine(hw, NULL, &claim, false, 0, 0,
					&recovery, 0, NULL);
	rk_mpp_hw_restore_or_quarantine(hw, NULL, &claim, false, 0, 0,
					&recovery, 0, NULL);
	bus_idle_status = rk_mpp_rkvdec2_wait_bus_idle(hw, &bus_idle_checked);
	finished = !!(irq_status & link_info->err_mask) ||
		rk_mpp_activation_finish_observed_terminal(
			hw, NULL, &claim, observation, irq_status,
			bus_idle_checked, bus_idle_status);
	if (WARN_ON_ONCE(!finished)) {
		quarantined = rk_mpp_activation_claim_quarantine(
			hw, NULL, &claim, -EUCLEAN, 0, NULL, 0, NULL);
		return 0;
	}
	return 0;
}
static int rk_mpp_av1_submit(struct rk_mpp_job *job)
{
	struct rk_mpp_hw *hw = NULL;
	struct rk_mpp_activation_claim_token claim = {};
	struct rk_mpp_cluster_recovery_result recovery = {};
	bool active_owned = true;
	bool cleared;
	bool finished;
	bool quarantined;
	bool start_failed_untrusted = true;
	int stop_ret;
	if (start_failed_untrusted && active_owned) {
		stop_ret = rk_mpp_hw_stop_and_recover(hw, job, &recovery);
		if (stop_ret) {
			rk_mpp_hw_handle_reset_failure(hw, stop_ret);
			mutex_unlock(&hw->run_lock);
			rk_mpp_hw_put(hw);
			return 0;
		}
	}
	cleared = rk_mpp_hw_clear_active_job(hw, job,
					     RK_MPP_TRANSITION_START_FAILURE,
					     NULL, &claim);
	rk_mpp_activation_claim_put(&claim);
	rk_mpp_activation_finish_terminal(hw, NULL, &claim, 0, &recovery,
					  0, NULL);
	rk_mpp_hw_restore_or_quarantine(hw, NULL, &claim, false, 0, 0,
					&recovery, 0, NULL);
	finished = rk_mpp_activation_finish_observed_terminal(
		hw, NULL, &claim, RK_MPP_ACTIVATION_OBSERVATION_NOT_PUBLISHED,
		0, false, 0);
	if (WARN_ON_ONCE(!finished)) {
		quarantined = rk_mpp_activation_claim_quarantine(
			hw, NULL, &claim, -EUCLEAN, 0, NULL, 0, NULL);
		return 0;
	}
	return 0;
}
static int rk_mpp_av1_thread(struct rk_mpp_hw *hw)
{
	struct rk_mpp_activation_claim_token claim = {};
	struct rk_mpp_cluster_recovery_result recovery = {};
	enum rk_mpp_activation_terminal_observation observation =
		RK_MPP_ACTIVATION_OBSERVATION_IRQ_ACCEPTED;
	bool finished;
	bool quarantined;
	u32 irq_status = 1;
	rk_mpp_activation_complete_claim(job, &claim, 0);
	rk_mpp_activation_finish_terminal(hw, NULL, &claim, 0, &recovery,
					  0, NULL);
	rk_mpp_hw_restore_or_quarantine(hw, NULL, &claim, false, 0, 0,
					&recovery, 0, NULL);
	rk_mpp_hw_restore_or_quarantine(hw, NULL, &claim, false, 0, 0,
					&recovery, 0, NULL);
	finished = !!(irq_status & RK_MPP_AV1_ERR_MASK) ||
		rk_mpp_activation_finish_observed_terminal(
			hw, NULL, &claim, observation, irq_status, false, 0);
	if (WARN_ON_ONCE(!finished)) {
		quarantined = rk_mpp_activation_claim_quarantine(
			hw, NULL, &claim, -EUCLEAN, 0, NULL, 0, NULL);
		return 0;
	}
	return 0;
}
static void rk_mpp_hw_remove(struct rk_mpp_hw *hw)
{
	bool dma_unquiesced = false;
	int stop_ret = 0;
	if (rk_mpp_service_has_quarantined_activation(hw->srv)) {
		dma_unquiesced = true;
		if (!stop_ret)
			stop_ret = -EUCLEAN;
	}
}
static void rk_mpp_hw_shutdown(struct rk_mpp_hw *hw)
{
	if (rk_mpp_service_has_quarantined_activation(hw->srv)) {
		dev_crit(hw->dev,
			 "shutdown retaining quarantined DMA ownership until reboot\\n");
		rk_mpp_hw_disable_irq(hw);
		return;
	}
}
"""
        mpp.write_text(
            "/* rewrite-ownership-audit legacy test fixture */\n"
            "enum rk_mpp_debug_event_type { RK_MPP_DEBUG_DONE };\n"
            "struct rk_mpp_debug_event { u8 type; };\n"
            "enum rk_mpp_activation_slot_state {\n"
            "\tRK_MPP_ACTIVATION_UNINSTALLED,\n"
            "\tRK_MPP_ACTIVATION_SLOTTED,\n"
            "\tRK_MPP_ACTIVATION_CLAIMED,\n"
            "\tRK_MPP_ACTIVATION_SUPERSEDED,\n"
            "\tRK_MPP_ACTIVATION_RETIRED,\n"
            "\tRK_MPP_ACTIVATION_RECLAIMABLE,\n"
            "\tRK_MPP_ACTIVATION_QUARANTINED,\n"
            "};\n"
            "enum rk_mpp_activation_resource_state {\n"
            "\tRK_MPP_ACTIVATION_RESOURCES_PRISTINE,\n"
            "\tRK_MPP_ACTIVATION_RESOURCES_OWNED,\n"
            "\tRK_MPP_ACTIVATION_RESOURCES_HANDED_OFF,\n"
            "\tRK_MPP_ACTIVATION_RESOURCES_DRAINED,\n"
            "\tRK_MPP_ACTIVATION_RESOURCES_QUARANTINED,\n"
            "};\n"
            "enum rk_mpp_activation_closure_state {\n"
            "\tRK_MPP_ACTIVATION_CLOSURE_NONE,\n"
            "\tRK_MPP_ACTIVATION_CLOSURE_PENDING,\n"
            "\tRK_MPP_ACTIVATION_CLOSURE_RETIRED,\n"
            "\tRK_MPP_ACTIVATION_CLOSURE_QUARANTINED,\n"
            "};\n"
            "enum rk_mpp_activation_retirement_scope {\n"
            "\tRK_MPP_ACTIVATION_RETIREMENT_NONE,\n"
            "\tRK_MPP_ACTIVATION_RETIREMENT_CORE,\n"
            "\tRK_MPP_ACTIVATION_RETIREMENT_CCU_GROUP,\n"
            "};\n"
            "enum rk_mpp_activation_terminal_observation {\n"
            "\tRK_MPP_ACTIVATION_OBSERVATION_NONE,\n"
            "\tRK_MPP_ACTIVATION_OBSERVATION_NOT_PUBLISHED,\n"
            "\tRK_MPP_ACTIVATION_OBSERVATION_IRQ_ACCEPTED,\n"
            "\tRK_MPP_ACTIVATION_OBSERVATION_CCU_DONE_ACCEPTED,\n"
            "\tRK_MPP_ACTIVATION_OBSERVATION_COUNT,\n"
            "};\n"
            "enum rk_mpp_activation_transition_reason {\n"
            "\tRK_MPP_TRANSITION_NONE,\n"
            "\tRK_MPP_TRANSITION_START_FAILURE,\n"
            "\tRK_MPP_TRANSITION_IRQ,\n"
            "\tRK_MPP_TRANSITION_CCU_DONE,\n"
            "\tRK_MPP_TRANSITION_TIMEOUT,\n"
            "\tRK_MPP_TRANSITION_IOMMU_FAULT,\n"
            "\tRK_MPP_TRANSITION_SESSION_RESET,\n"
            "\tRK_MPP_TRANSITION_SESSION_CLOSE,\n"
            "\tRK_MPP_TRANSITION_REMOVE,\n"
            "\tRK_MPP_TRANSITION_SHUTDOWN,\n"
            "\tRK_MPP_TRANSITION_CCU_DEPENDENT_ABORT,\n"
            "\tRK_MPP_TRANSITION_RETRY_REPLACED,\n"
            "\tRK_MPP_TRANSITION_COUNT,\n"
            "};\n"
            "struct rk_mpp_cluster_recovery_result {\n"
            "\tenum rk_mpp_reset_effect reset_effect;\n"
            "\tu64 reset_epoch;\n"
            "\tint reset_error;\n"
            "\tint refresh_error;\n"
            "\tint isolation_error;\n"
            "\tu32 dma_group_count;\n"
            "\tu32 dma_group_refresh_count;\n"
            "\tu32 dma_group_isolation_count;\n"
            "\tbool quiesced;\n"
            "\tbool reusable;\n"
            "};\n"
            "struct rk_mpp_activation_recovery_record {\n"
            "\tstruct rk_mpp_cluster_recovery_result result;\n"
            "\tint status;\n"
            "\tbool valid;\n"
            "};\n"
            "struct rk_mpp_activation_observation_record {\n"
            "\tenum rk_mpp_activation_terminal_observation kind;\n"
            "\tu32 hw_status;\n"
            "\tint bus_idle_status;\n"
            "\tbool bus_idle_checked;\n"
            "\tbool valid;\n"
            "};\n"
            "struct rk_mpp_activation_closure {\n"
            "\tenum rk_mpp_activation_closure_state state;\n"
            "\tstruct rk_mpp_activation_recovery_record group;\n"
            "\tstruct rk_mpp_activation_recovery_record core;\n"
            "\tstruct rk_mpp_activation_recovery_record terminal;\n"
            "\tenum rk_mpp_activation_retirement_scope terminal_scope;\n"
            "\tstruct rk_mpp_activation_observation_record observation;\n"
            "};\n"
            "struct rk_mpp_activation_ref {\n"
            "\tstruct rk_mpp_activation *activation;\n"
            "\tu64 generation;\n"
            "};\n"
            "struct rk_mpp_activation_retry_token {\n"
            "\tstruct rk_mpp_activation_ref ref;\n"
            "};\n"
            "struct rk_mpp_activation_claim_token {\n"
            "\tstruct rk_mpp_activation_ref ref;\n"
            "\tenum rk_mpp_activation_transition_reason reason;\n"
            "};\n"
            "struct rk_mpp_activation_resources {\n"
            "\tstruct rk_mpp_hw *rkvdec_ccu;\n"
            "\tu32 rkvdec_stream_addr;\n"
            "\tvoid *rkvdec_link_vaddr;\n"
            "\tdma_addr_t rkvdec_link_iova;\n"
            "\tu32 rkvdec_link_index;\n"
            "\tu32 rkvdec_ccu_core_work;\n"
            "\tu32 rkvdec_ccu_cfg_addr;\n"
            "\tu32 rkvdec_ccu_link_mode;\n"
            "\tu32 rkvdec_ccu_ctrl;\n"
            "\tu32 rkvdec_ccu_work;\n"
            "\tu32 rkvdec_ccu_cfg_done;\n"
            "\tu32 rkvenc_dchs_core_id;\n"
            "\tstruct rk_mpp_cluster_power_lease *rkvdec_ccu_power_lease;\n"
            "\tbool rkvdec_link_active;\n"
            "\tbool rkvdec_ccu_listed;\n"
            "\tbool rkvdec_ccu_desc_valid;\n"
            "\tbool rkvdec_ccu_powered;\n"
            "\tbool rkvdec_ccu_started;\n"
            "\tbool rkvenc_dchs_active;\n"
            "\tu64 hw_start_ns;\n"
            "\tu64 hw_elapsed_ns;\n"
            "};\n"
            "struct rk_mpp_activation {\n"
            "\trefcount_t refs;\n"
            "\tstruct list_head job_link;\n"
            "\tstruct list_head quarantine_link;\n"
            "\tu32 quarantine_ref_count;\n"
            "\tu64 quarantine_generation;\n"
            "\tstruct rk_mpp_job *job;\n"
            "\tstruct rk_mpp_hw *selected_hw;\n"
            "\tenum rk_mpp_activation_slot_state slot_state;\n"
            "\tenum rk_mpp_activation_resource_state resource_state;\n"
            "\tenum rk_mpp_activation_transition_reason transition_reason;\n"
            "\tu64 generation;\n"
            "\tunsigned long watchdog_deadline;\n"
            "\tbool watchdog_deadline_valid;\n"
            "\tstruct rk_mpp_activation_closure closure;\n"
            "\tstruct rk_mpp_activation_resources resources;\n"
            "};\n"
            "struct rk_mpp_hw {\n"
            "\tstruct rk_mpp_activation_ref active_ref;\n"
            "\tstruct rk_mpp_activation_ref timeout_ref;\n"
            "\tu64 activation_generation_seq;\n"
            "};\n"
            "struct rk_mpp_service {\n"
            "\tstruct mutex quarantine_lock;\n"
            "\tstruct list_head quarantined_activations;\n"
            "\tatomic_t quarantine_count;\n"
            "};\n"
            "struct rk_mpp_session {\n"
            "\tstruct rk_mpp_activation *rkvdec_dispatch_owner;\n"
            "};\n"
            "struct rk_mpp_job {\n"
            "\tstruct list_head activations;\n"
            "\tstruct rk_mpp_session *session;\n"
            "\tstruct rk_mpp_activation activation_storage;\n"
            "\tstruct rk_mpp_activation *current_activation;\n"
            "};\n"
            "static void rk_mpp_activation_storage_init(\n"
            "\t\tstruct rk_mpp_activation *activation,\n"
            "\t\tstruct rk_mpp_job *job)\n"
            "{\n"
            "\trefcount_set(&activation->refs, 1);\n"
            "\tINIT_LIST_HEAD(&activation->job_link);\n"
            "\tINIT_LIST_HEAD(&activation->quarantine_link);\n"
            "\tactivation->quarantine_ref_count = 0;\n"
            "\tactivation->quarantine_generation = 0;\n"
            "\tactivation->job = job;\n"
            "\tactivation->selected_hw = NULL;\n"
            "\tactivation->slot_state = RK_MPP_ACTIVATION_UNINSTALLED;\n"
            "\tactivation->transition_reason = RK_MPP_TRANSITION_NONE;\n"
            "\tactivation->generation = 0;\n"
            "\tactivation->watchdog_deadline = 0;\n"
            "\tactivation->watchdog_deadline_valid = false;\n"
            "\tmemset(&activation->closure, 0, sizeof(activation->closure));\n"
            "}\n"
            "static bool rk_mpp_activation_closure_pristine(\n"
            "\t\tconst struct rk_mpp_activation *activation)\n"
            "{\n"
            "\treturn activation &&\n"
            "\t       !memchr_inv(&activation->closure, 0,\n"
            "\t\t\t  sizeof(activation->closure));\n"
            "}\n"
            "static bool rk_mpp_activation_observation_pristine(\n"
            "\t\tconst struct rk_mpp_activation *activation)\n"
            "{\n"
            "\treturn activation->closure.observation.kind ==\n"
            "\t\t       RK_MPP_ACTIVATION_OBSERVATION_NONE &&\n"
            "\t       !activation->closure.observation.hw_status &&\n"
            "\t       !activation->closure.observation.bus_idle_status &&\n"
            "\t       !activation->closure.observation.bus_idle_checked &&\n"
            "\t       !activation->closure.observation.valid;\n"
            "}\n"
            "static bool rk_mpp_activation_observation_matches(\n"
            "\t\tconst struct rk_mpp_activation *activation)\n"
            "{\n"
            "\tstruct rk_mpp_job *job = activation->job;\n"
            "\tif (!activation->closure.observation.valid)\n"
            "\t\treturn false;\n"
            "\tswitch (activation->closure.observation.kind) {\n"
            "\tcase RK_MPP_ACTIVATION_OBSERVATION_NOT_PUBLISHED:\n"
            "\t\treturn activation->transition_reason ==\n"
            "\t\t       RK_MPP_TRANSITION_START_FAILURE &&\n"
            "\t\t       !activation->closure.observation.hw_status &&\n"
            "\t\t       !activation->closure.observation.bus_idle_status &&\n"
            "\t\t       !activation->closure.observation.bus_idle_checked;\n"
            "\tcase RK_MPP_ACTIVATION_OBSERVATION_IRQ_ACCEPTED:\n"
            "\t\tif (activation->transition_reason != RK_MPP_TRANSITION_IRQ ||\n"
            "\t\t    !activation->closure.observation.hw_status || !job)\n"
            "\t\t\treturn false;\n"
            "\t\tif (job->client_type == RK_MPP_DEVICE_RKVDEC)\n"
            "\t\t\treturn activation->closure.observation.bus_idle_checked ||\n"
            "\t\t\t       activation->closure.observation.bus_idle_status ==\n"
            "\t\t\t\t       -EOPNOTSUPP;\n"
            "\t\treturn !activation->closure.observation.bus_idle_checked &&\n"
            "\t\t       !activation->closure.observation.bus_idle_status;\n"
            "\tcase RK_MPP_ACTIVATION_OBSERVATION_CCU_DONE_ACCEPTED:\n"
            "\t\treturn activation->transition_reason ==\n"
            "\t\t       RK_MPP_TRANSITION_CCU_DONE &&\n"
            "\t\t       activation->closure.observation.hw_status && job &&\n"
            "\t\t       job->client_type == RK_MPP_DEVICE_RKVDEC &&\n"
            "\t\t       (activation->closure.observation.bus_idle_checked ||\n"
            "\t\t\tactivation->closure.observation.bus_idle_status ==\n"
            "\t\t\t\t-EOPNOTSUPP);\n"
            "\tdefault:\n"
            "\t\treturn false;\n"
            "\t}\n"
            "}\n"
            "static void rk_mpp_activation_init(struct rk_mpp_job *job)\n"
            "{\n"
            "\tINIT_LIST_HEAD(&job->activations);\n"
            "\trk_mpp_activation_storage_init(&job->activation_storage, job);\n"
            "\tlist_add_tail(&job->activation_storage.job_link,\n"
            "\t\t      &job->activations);\n"
            "\tWRITE_ONCE(job->current_activation, &job->activation_storage);\n"
            "}\n"
            "static struct rk_mpp_activation *\n"
            "rk_mpp_activation_alloc_successor(struct rk_mpp_job *job)\n"
            "{\n"
            "\tstruct rk_mpp_activation *activation;\n"
            "\tactivation = kzalloc_obj(*activation, GFP_KERNEL);\n"
            "\tif (activation)\n"
            "\t\trk_mpp_activation_storage_init(activation, job);\n"
            "\treturn activation;\n"
            "}\n"
            "static void rk_mpp_activation_free_unpublished(\n"
            "\t\tstruct rk_mpp_activation *activation)\n"
            "{\n"
            "\tif (!activation)\n"
            "\t\treturn;\n"
            "\tif (WARN_ON_ONCE(!list_empty(&activation->job_link) ||\n"
            "\t\t\t activation->selected_hw ||\n"
            "\t\t\t activation->slot_state !=\n"
            "\t\t\t\t RK_MPP_ACTIVATION_UNINSTALLED ||\n"
            "\t\t\t activation->transition_reason !=\n"
            "\t\t\t\t RK_MPP_TRANSITION_NONE ||\n"
            "\t\t\t !rk_mpp_activation_closure_pristine(activation) ||\n"
            "\t\t\t !rk_mpp_activation_refs_released(activation)))\n"
            "\t\treturn;\n"
            "\tif (WARN_ON_ONCE(!refcount_dec_and_test(&activation->refs)))\n"
            "\t\treturn;\n"
            "\tkfree(activation);\n"
            "}\n"
            "static bool rk_mpp_activation_retirement_released(\n"
            "\t\tconst struct rk_mpp_activation *activation)\n"
            "{\n"
            "\tif (activation->slot_state == RK_MPP_ACTIVATION_UNINSTALLED)\n"
            "\t\treturn activation->transition_reason ==\n"
            "\t\t       RK_MPP_TRANSITION_NONE &&\n"
            "\t\t       rk_mpp_activation_closure_pristine(activation);\n"
            "\tif (activation->slot_state == RK_MPP_ACTIVATION_SUPERSEDED)\n"
            "\t\treturn activation->transition_reason ==\n"
            "\t\t       RK_MPP_TRANSITION_RETRY_REPLACED &&\n"
            "\t\t       activation->closure.state ==\n"
            "\t\t       RK_MPP_ACTIVATION_CLOSURE_RETIRED &&\n"
            "\t\t       rk_mpp_activation_observation_pristine(activation) &&\n"
            "\t\t       activation->closure.group.valid &&\n"
            "\t\t       !activation->closure.group.status &&\n"
            "\t\t       activation->closure.group.result.quiesced &&\n"
            "\t\t       activation->closure.core.valid;\n"
            "\tif (activation->slot_state != RK_MPP_ACTIVATION_RETIRED ||\n"
            "\t    activation->transition_reason <= RK_MPP_TRANSITION_NONE ||\n"
            "\t    activation->transition_reason >=\n"
            "\t\t    RK_MPP_TRANSITION_RETRY_REPLACED ||\n"
            "\t    activation->closure.state !=\n"
            "\t\t    RK_MPP_ACTIVATION_CLOSURE_RETIRED)\n"
            "\t\treturn false;\n"
            "\tif (activation->closure.observation.valid)\n"
            "\t\treturn activation->closure.terminal_scope ==\n"
            "\t\t       RK_MPP_ACTIVATION_RETIREMENT_NONE &&\n"
            "\t\t       !activation->closure.group.valid &&\n"
            "\t\t       !activation->closure.core.valid &&\n"
            "\t\t       !activation->closure.terminal.valid &&\n"
            "\t\t       rk_mpp_activation_observation_matches(activation);\n"
            "\treturn rk_mpp_activation_observation_pristine(activation) &&\n"
            "\t       ((activation->closure.terminal_scope ==\n"
            "\t\t RK_MPP_ACTIVATION_RETIREMENT_CORE &&\n"
            "\t\t activation->closure.terminal.valid &&\n"
            "\t\t !activation->closure.terminal.status &&\n"
            "\t\t activation->closure.terminal.result.quiesced) ||\n"
            "\t\t(activation->closure.terminal_scope ==\n"
            "\t\t RK_MPP_ACTIVATION_RETIREMENT_CCU_GROUP &&\n"
            "\t\t activation->closure.group.valid &&\n"
            "\t\t !activation->closure.group.status &&\n"
            "\t\t activation->closure.group.result.quiesced &&\n"
            "\t\t activation->closure.core.valid));\n"
            "}\n"
            "static bool rk_mpp_activation_storage_released(\n"
            "\t\tconst struct rk_mpp_activation *activation)\n"
            "{\n"
            "\tif (activation && activation->slot_state ==\n"
            "\t\t\t  RK_MPP_ACTIVATION_RECLAIMABLE)\n"
            "\t\treturn rk_mpp_activation_refs_released(activation) &&\n"
            "\t\t       !activation->selected_hw &&\n"
            "\t\t       (activation->resource_state ==\n"
            "\t\t\t\tRK_MPP_ACTIVATION_RESOURCES_PRISTINE ||\n"
            "\t\t\tactivation->resource_state ==\n"
            "\t\t\t\tRK_MPP_ACTIVATION_RESOURCES_HANDED_OFF ||\n"
            "\t\t\tactivation->resource_state ==\n"
            "\t\t\t\tRK_MPP_ACTIVATION_RESOURCES_DRAINED) &&\n"
            "\t\t       !memchr_inv(&activation->resources, 0,\n"
            "\t\t\t\t    sizeof(activation->resources));\n"
            "\treturn rk_mpp_activation_refs_released(activation) &&\n"
            "\t       !activation->selected_hw &&\n"
            "\t       rk_mpp_activation_retirement_released(activation) &&\n"
            "\t       (activation->resource_state ==\n"
            "\t\t\tRK_MPP_ACTIVATION_RESOURCES_PRISTINE ||\n"
            "\t\tactivation->resource_state ==\n"
            "\t\t\tRK_MPP_ACTIVATION_RESOURCES_HANDED_OFF ||\n"
            "\t\tactivation->resource_state ==\n"
            "\t\t\tRK_MPP_ACTIVATION_RESOURCES_DRAINED) &&\n"
            "\t       !memchr_inv(&activation->resources, 0,\n"
            "\t\t\t    sizeof(activation->resources));\n"
            "}\n"
            "static struct rk_mpp_job *rk_mpp_activation_job(\n"
            "\t\tconst struct rk_mpp_activation *activation)\n"
            "{\n"
            "\treturn activation ? activation->job : NULL;\n"
            "}\n"
            "static u64 rk_mpp_activation_install_locked(\n"
            "\t\tstruct rk_mpp_hw *hw,\n"
            "\t\tstruct rk_mpp_activation *activation)\n"
            "{\n"
            "\tu64 generation = rk_mpp_hw_advance_active_generation_locked(hw);\n"
            "\tif (activation->selected_hw != hw ||\n"
            "\t    !rk_mpp_activation_closure_pristine(activation))\n"
            "\t\treturn 0;\n"
            "\tactivation->slot_state = RK_MPP_ACTIVATION_SLOTTED;\n"
            "\tactivation->transition_reason = RK_MPP_TRANSITION_NONE;\n"
            "\tactivation->generation = generation;\n"
            "\tactivation->watchdog_deadline = 0;\n"
            "\tactivation->watchdog_deadline_valid = false;\n"
            "\treturn generation;\n"
            "}\n"
            "static int rk_mpp_job_select_hw(struct rk_mpp_job *job)\n"
            "{\n"
            "\tjob->current_activation->selected_hw = hw;\n"
            "\treturn 0;\n"
            "}\n"
            "static void rk_mpp_job_drop_hw(struct rk_mpp_job *job)\n"
            "{\n"
            "\tstruct rk_mpp_activation *activation;\n"
            "\tlist_for_each_entry(activation, &job->activations, job_link)\n"
            "\t\txchg(&activation->selected_hw, NULL);\n"
            "}\n"
            "static void rk_mpp_rkvdec2_release_link_table(\n"
            "\t\tstruct rk_mpp_job *job)\n"
            "{\n"
            "\trk_mpp_job_resources(job)->rkvdec_ccu = NULL;\n"
            "}\n"
            "static u64 rk_mpp_hw_advance_active_generation_locked(\n"
            "\t\tstruct rk_mpp_hw *hw)\n"
            "{\n"
            "\thw->activation_generation_seq++;\n"
            "\treturn hw->activation_generation_seq;\n"
            "}\n"
            "static struct rk_mpp_activation *\n"
            "rk_mpp_hw_active_activation_locked(const struct rk_mpp_hw *hw)\n"
            "{\n"
            "\treturn hw->active_ref.activation;\n"
            "}\n"
            "static u64 rk_mpp_hw_install_active_locked(\n"
            "\t\tstruct rk_mpp_hw *hw, struct rk_mpp_job *job)\n"
            "{\n"
            "\tstruct rk_mpp_activation *activation = job->current_activation;\n"
            "\tu64 generation;\n"
            "\tlockdep_assert_held(&hw->lock);\n"
            "\tif (!rk_mpp_activation_ref_empty(&hw->active_ref))\n"
            "\t\treturn 0;\n"
            "\tif (!activation || activation->job != job)\n"
            "\t\treturn 0;\n"
            "\tgeneration = rk_mpp_activation_install_locked(hw, activation);\n"
            "\tif (!generation)\n"
            "\t\treturn 0;\n"
            "\tif (!rk_mpp_activation_ref_get(&hw->active_ref, activation)) {\n"
            "\t\tactivation->slot_state = RK_MPP_ACTIVATION_UNINSTALLED;\n"
            "\t\tactivation->transition_reason = RK_MPP_TRANSITION_NONE;\n"
            "\t\tactivation->generation = 0;\n"
            "\t\tactivation->watchdog_deadline = 0;\n"
            "\t\tactivation->watchdog_deadline_valid = false;\n"
            "\t\treturn 0;\n"
            "\t}\n"
            "\treturn generation;\n"
            "}\n"
            + phase3h_core
            +
            "static bool rk_mpp_hw_active_retry_matches_locked(\n"
            "\t\tstruct rk_mpp_hw *hw, struct rk_mpp_job *job,\n"
            "\t\tstruct rk_mpp_activation *old)\n"
            "{\n"
            "\treturn job->current_activation == old &&\n"
            "\t       rk_mpp_activation_ref_valid(&hw->active_ref) &&\n"
            "\t       hw->active_ref.activation == old &&\n"
            "\t       hw->active_ref.generation == old->generation;\n"
            "}\n"
            "static bool rk_mpp_hw_active_retry_ready(\n"
            "\t\tstruct rk_mpp_hw *hw, struct rk_mpp_job *job,\n"
            "\t\tstruct rk_mpp_activation *old)\n"
            "{\n"
            "\treturn rk_mpp_hw_active_retry_matches_locked(hw, job, old);\n"
            "}\n"
            "static bool rk_mpp_hw_commit_active_retry(\n"
            "\t\tstruct rk_mpp_hw *hw, struct rk_mpp_job *job,\n"
            "\t\tstruct rk_mpp_activation *old,\n"
            "\t\tstruct rk_mpp_activation *successor,\n"
            "\t\tconst struct rk_mpp_cluster_recovery_result *group,\n"
            "\t\tstruct rk_mpp_activation_retry_token *token)\n"
            "{\n"
            "\tstruct rk_mpp_activation_ref successor_ref = {};\n"
            "\tif (!rk_mpp_hw_active_retry_matches_locked(hw, job, old) ||\n"
            "\t    !rk_mpp_activation_ref_empty(&token->ref) ||\n"
            "\t    !group->quiesced || !group->reusable ||\n"
            "\t    !rk_mpp_activation_closure_pristine(old) ||\n"
            "\t    !rk_mpp_activation_closure_pristine(successor))\n"
            "\t\treturn false;\n"
            "\tif (!rk_mpp_activation_install_locked(hw, successor))\n"
            "\t\treturn false;\n"
            "\tif (!rk_mpp_activation_ref_get(&successor_ref, successor))\n"
            "\t\treturn false;\n"
            "\tif (!rk_mpp_activation_ref_move(&token->ref, &hw->active_ref))\n"
            "\t\treturn false;\n"
            "\tif (!rk_mpp_activation_ref_move(&hw->active_ref, &successor_ref)) {\n"
            "\t\tWARN_ON_ONCE(!rk_mpp_activation_ref_move(&hw->active_ref,\n"
            "\t\t\t\t\t\t &token->ref));\n"
            "\t\treturn false;\n"
            "\t}\n"
            "\told->closure.group.result = *group;\n"
            "\told->closure.group.status = 0;\n"
            "\told->closure.group.valid = true;\n"
            "\told->closure.state = RK_MPP_ACTIVATION_CLOSURE_PENDING;\n"
            "\told->slot_state = RK_MPP_ACTIVATION_SUPERSEDED;\n"
            "\told->transition_reason = RK_MPP_TRANSITION_RETRY_REPLACED;\n"
            "\tlist_add_tail(&successor->job_link, &job->activations);\n"
            "\tWRITE_ONCE(job->current_activation, successor);\n"
            "\tsuccessor->generation = 0;\n"
            "\tif (!rk_mpp_activation_ref_empty(&successor_ref))\n"
            "\t\tWARN_ON_ONCE(!rk_mpp_activation_ref_put(&successor_ref));\n"
            "\treturn true;\n"
            "}\n"
            "static bool rk_mpp_activation_finish_retry_locked(\n"
            "\t\tstruct rk_mpp_hw *hw,\n"
            "\t\tstruct rk_mpp_activation_retry_token *token, int status,\n"
            "\t\tconst struct rk_mpp_cluster_recovery_result *core)\n"
            "{\n"
            "\tstruct rk_mpp_activation *old = token ? token->ref.activation : NULL;\n"
            "\tstruct rk_mpp_job *job = old ? old->job : NULL;\n"
            "\tlockdep_assert_held(&hw->lock);\n"
            "\tif (!job || !core || !rk_mpp_activation_ref_valid(&token->ref) ||\n"
            "\t    old->generation != token->ref.generation ||\n"
            "\t    old->selected_hw != hw ||\n"
            "\t    list_empty(&old->job_link) ||\n"
            "\t    old == READ_ONCE(job->current_activation) ||\n"
            "\t    old == rk_mpp_hw_active_activation_locked(hw) ||\n"
            "\t    old->slot_state != RK_MPP_ACTIVATION_SUPERSEDED ||\n"
            "\t    old->transition_reason !=\n"
            "\t\t    RK_MPP_TRANSITION_RETRY_REPLACED ||\n"
            "\t    old->closure.state !=\n"
            "\t\t    RK_MPP_ACTIVATION_CLOSURE_PENDING ||\n"
            "\t    !old->closure.group.valid ||\n"
            "\t    old->closure.group.status ||\n"
            "\t    !old->closure.group.result.quiesced ||\n"
            "\t    !old->closure.group.result.reusable ||\n"
            "\t    old->closure.core.valid)\n"
            "\t\treturn false;\n"
            "\told->closure.core.result = *core;\n"
            "\told->closure.core.status = status;\n"
            "\told->closure.core.valid = true;\n"
            "\told->closure.state = RK_MPP_ACTIVATION_CLOSURE_RETIRED;\n"
            "\treturn true;\n"
            "}\n"
            "static bool rk_mpp_activation_retry_quarantine(\n"
            "\t\tstruct rk_mpp_hw *hw,\n"
            "\t\tstruct rk_mpp_activation_retry_token *token, int status,\n"
            "\t\tconst struct rk_mpp_cluster_recovery_result *core)\n"
            "{\n"
            "\tstruct rk_mpp_activation *activation;\n"
            "\tstruct rk_mpp_job *job;\n"
            "\tstruct rk_mpp_hw *ccu;\n"
            "\tstruct rk_mpp_service *srv = hw->srv;\n"
            "\tunsigned long flags;\n"
            "\tu64 generation;\n"
            "\tint error = status ?: -EUCLEAN;\n"
            "\tlockdep_assert_held(&hw->run_lock);\n"
            "\tif (!token || !rk_mpp_activation_ref_valid(&token->ref))\n"
            "\t\treturn false;\n"
            "\tactivation = token->ref.activation;\n"
            "\tjob = activation->job;\n"
            "\tccu = rk_mpp_job_resources(job)->rkvdec_ccu;\n"
            "\tif (ccu)\n"
            "\t\tlockdep_assert_held(&ccu->ccu_recovery_lock);\n"
            "\tgeneration = token->ref.generation;\n"
            "\tmutex_lock(&srv->quarantine_lock);\n"
            "\tspin_lock_irqsave(&hw->lock, flags);\n"
            "\tif (core && !activation->closure.core.valid) {\n"
            "\t\tactivation->closure.core.result = *core;\n"
            "\t\tactivation->closure.core.status = status;\n"
            "\t\tactivation->closure.core.valid = true;\n"
            "\t}\n"
            "\tactivation->closure.state = RK_MPP_ACTIVATION_CLOSURE_QUARANTINED;\n"
            "\tactivation->slot_state = RK_MPP_ACTIVATION_QUARANTINED;\n"
            "\tactivation->resource_state =\n"
            "\t\tRK_MPP_ACTIVATION_RESOURCES_QUARANTINED;\n"
            "\tactivation->transition_reason = RK_MPP_TRANSITION_RETRY_REPLACED;\n"
            "\tactivation->quarantine_generation = generation;\n"
            "\tif (list_empty(&activation->quarantine_link)) {\n"
            "\t\tlist_add_tail(&activation->quarantine_link,\n"
            "\t\t\t      &srv->quarantined_activations);\n"
            "\t\tatomic_inc(&srv->quarantine_count);\n"
            "\t}\n"
            "\tactivation->quarantine_ref_count++;\n"
            "\tmemset(&token->ref, 0, sizeof(token->ref));\n"
            "\tspin_unlock_irqrestore(&hw->lock, flags);\n"
            "\tmutex_unlock(&srv->quarantine_lock);\n"
            "\trk_mpp_hw_handle_reset_failure(hw, error);\n"
            "\tif (ccu && ccu != hw)\n"
            "\t\trk_mpp_hw_handle_reset_failure(ccu, error);\n"
            "\treturn true;\n"
            "}\n"
            "static bool rk_mpp_activation_finish_retry(\n"
            "\t\tstruct rk_mpp_hw *hw,\n"
            "\t\tstruct rk_mpp_activation_retry_token *token, int status,\n"
            "\t\tconst struct rk_mpp_cluster_recovery_result *core)\n"
            "{\n"
            "\tstruct rk_mpp_activation *activation;\n"
            "\tstruct rk_mpp_session *session;\n"
            "\tstruct rk_mpp_hw *selected_hw = NULL;\n"
            "\tunsigned long flags;\n"
            "\tbool finished;\n"
            "\tif (!token || !rk_mpp_activation_ref_valid(&token->ref))\n"
            "\t\treturn false;\n"
            "\tactivation = token->ref.activation;\n"
            "\tsession = activation->job->session;\n"
            "\tlockdep_assert_held(&hw->run_lock);\n"
            "\tmutex_lock(&session->lock);\n"
            "\tspin_lock_irqsave(&hw->lock, flags);\n"
            "\tfinished = rk_mpp_activation_finish_retry_locked(hw, token,\n"
            "\t\t\t\t\t\t      status, core);\n"
            "\tspin_unlock_irqrestore(&hw->lock, flags);\n"
            "\tif (finished)\n"
            "\t\tfinished = rk_mpp_activation_take_selected_hw_locked(activation,\n"
            "\t\t\t\t\t\t\t     hw, &selected_hw);\n"
            "\tmutex_unlock(&session->lock);\n"
            "\tif (finished) {\n"
            "\t\trk_mpp_hw_put(selected_hw);\n"
            "\t\tWARN_ON_ONCE(!rk_mpp_activation_ref_put(&token->ref));\n"
            "\t\treturn true;\n"
            "\t}\n"
            "\tWARN_ON_ONCE(!rk_mpp_activation_retry_quarantine(hw, token,\n"
            "\t\t\t\t\t\t status, core));\n"
            "\treturn false;\n"
            "}\n"
            "static int rk_mpp_rkvdec2_prepare_ccu_retry_job(\n"
            "\t\tstruct rk_mpp_job *job,\n"
            "\t\tstruct rk_mpp_activation *successor,\n"
            "\t\tconst struct rk_mpp_cluster_recovery_result *group)\n"
            "{\n"
            "\tstruct rk_mpp_hw *hw = NULL;\n"
            "\tstruct rk_mpp_activation *old = job->current_activation;\n"
            "\tstruct rk_mpp_activation_retry_token token = {};\n"
            "\tstruct rk_mpp_cluster_recovery_result recovery = {};\n"
            "\tint ret;\n"
            "\tif (!rk_mpp_hw_active_retry_ready(hw, job, old))\n"
            "\t\treturn -ENOENT;\n"
            "\tif (!rk_mpp_hw_commit_active_retry(hw, job, old, successor,\n"
            "\t\t\t\t       group, &token))\n"
            "\t\treturn -EAGAIN;\n"
            "\trk_mpp_hw_cancel_timeout(hw);\n"
            "\tret = rk_mpp_hw_stop_and_recover(hw, job, &recovery);\n"
            "\tif (!rk_mpp_activation_finish_retry(hw, &token, ret, &recovery))\n"
            "\t\treturn -EUCLEAN;\n"
            "\tif (ret)\n"
            "\t\treturn ret;\n"
            "\tif (!recovery.quiesced || !recovery.reusable)\n"
            "\t\treturn -EIO;\n"
            "\treturn 0;\n"
            "}\n"
            "static int rk_mpp_rkvdec2_restart_ccu_unfinished_jobs(\n"
            "\t\tstruct rk_mpp_hw *ccu,\n"
            "\t\tconst struct rk_mpp_cluster_recovery_result *group)\n"
            "{\n"
            "\tstruct rk_mpp_job *jobs[1] = {};\n"
            "\tstruct rk_mpp_activation *successor;\n"
            "\tint i = 0;\n"
            "\tint ret;\n"
            "\tif (!group || !group->quiesced || !group->reusable)\n"
            "\t\treturn -EINVAL;\n"
            "\tsuccessor = rk_mpp_activation_alloc_successor(jobs[i]);\n"
            "\tret = rk_mpp_rkvdec2_prepare_ccu_retry_job(jobs[i], successor,\n"
            "\t\t\t\t\t       group);\n"
            "\trk_mpp_activation_free_unpublished(successor);\n"
            "\treturn ret;\n"
            "}\n"
            + phase3h_callers
            +
            "static bool rk_mpp_hw_take_timeout_ref(struct rk_mpp_hw *hw,\n"
            "\t\tstruct rk_mpp_activation_ref *ref)\n"
            "{\n"
            "\tunsigned long flags;\n"
            "\tbool taken;\n"
            "\tif (!rk_mpp_activation_ref_empty(ref))\n"
            "\t\treturn false;\n"
            "\tspin_lock_irqsave(&hw->lock, flags);\n"
            "\ttaken = rk_mpp_activation_ref_empty(&hw->timeout_ref) ? false :\n"
            "\t\trk_mpp_activation_ref_move(ref, &hw->timeout_ref);\n"
            "\tspin_unlock_irqrestore(&hw->lock, flags);\n"
            "\treturn taken;\n"
            "}\n"
            "static void rk_mpp_hw_cancel_timeout(struct rk_mpp_hw *hw)\n"
            "{\n"
            "\tstruct rk_mpp_activation_ref ref = {};\n"
            "\tif (rk_mpp_hw_take_timeout_ref(hw, &ref))\n"
            "\t\tWARN_ON_ONCE(!rk_mpp_activation_ref_put(&ref));\n"
            "}\n"
            "static void rk_mpp_hw_cancel_timeout_sync(struct rk_mpp_hw *hw)\n"
            "{\n"
            "\tstruct rk_mpp_activation_ref ref = {};\n"
            "\tif (rk_mpp_hw_take_timeout_ref(hw, &ref))\n"
            "\t\tWARN_ON_ONCE(!rk_mpp_activation_ref_put(&ref));\n"
            "}\n"
            "static void rk_mpp_hw_schedule_timeout(struct rk_mpp_hw *hw)\n"
            "{\n"
            "\tstruct rk_mpp_activation_ref replacement = {};\n"
            "\tstruct rk_mpp_activation_ref old = {};\n"
            "\tstruct rk_mpp_activation *activation =\n"
            "\t\trk_mpp_hw_active_activation_locked(hw);\n"
            "\tif (hw->active_ref.activation != hw->timeout_ref.activation ||\n"
            "\t    hw->active_ref.generation != hw->timeout_ref.generation) {\n"
            "\t\trk_mpp_activation_ref_clone(&replacement, &hw->active_ref);\n"
            "\t\trk_mpp_activation_ref_move(&old, &hw->timeout_ref);\n"
            "\t\trk_mpp_activation_ref_move(&hw->timeout_ref, &replacement);\n"
            "\t}\n"
            "\tactivation->watchdog_deadline = 1;\n"
            "\tactivation->watchdog_deadline_valid = true;\n"
            "\trk_mpp_activation_ref_put(&replacement);\n"
            "\trk_mpp_activation_ref_put(&old);\n"
            "}\n"
            "static void rk_mpp_hw_timeout_work(struct work_struct *work)\n"
            "{\n"
            "\tstruct rk_mpp_activation_ref ref = {};\n"
            "\trk_mpp_hw_take_timeout_ref(hw, &ref);\n"
            "\trk_mpp_hw_recover_active(hw, false, &ref);\n"
            "\trk_mpp_activation_ref_put(&ref);\n"
            "}\n"
            "static bool rk_mpp_dispatch_lease_released(\n"
            "\t\tconst struct rk_mpp_job *job)\n"
            "{\n"
            "\tstruct rk_mpp_activation *activation;\n"
            "\tlist_for_each_entry(activation, &job->activations, job_link)\n"
            "\t\tif (job->session->rkvdec_dispatch_owner == activation)\n"
            "\t\t\treturn false;\n"
            "\treturn true;\n"
            "}\n"
            "static bool rk_mpp_dispatch_lease_active_locked(\n"
            "\t\tconst struct rk_mpp_session *session)\n"
            "{\n"
            "\treturn !!session->rkvdec_dispatch_owner;\n"
            "}\n"
            "static bool rk_mpp_dispatch_lease_owned_locked(\n"
            "\t\tconst struct rk_mpp_job *job)\n"
            "{\n"
            "\treturn job->session->rkvdec_dispatch_owner == "
            "job->current_activation;\n"
            "}\n"
            "static void rk_mpp_dispatch_lease_acquire_locked(\n"
            "\t\tstruct rk_mpp_job *job)\n"
            "{\n"
            "\tjob->session->rkvdec_dispatch_owner = job->current_activation;\n"
            "}\n"
            "static void rk_mpp_dispatch_lease_release_locked(\n"
            "\t\tstruct rk_mpp_job *job)\n"
            "{\n"
            "\tjob->session->rkvdec_dispatch_owner = NULL;\n"
            "}\n"
            "static void rk_mpp_hw_stop_active(\n"
            "\t\tstruct rk_mpp_cluster_recovery_result *result)\n"
            "{\n"
            "\tresult->reset_effect = RK_MPP_RESET_TRANSLATIONS_LOST;\n"
            "\tresult->dma_group_count = 1;\n"
            "\tif (result->reusable) return;\n"
            "}\n"
            "static void mpp_paths(struct rk_mpp_hw *hw, struct rk_mpp_job *job,\n"
            "\t\t      struct rk_mpp_activation *activation)\n"
            "{\n"
            "\treset_control_assert(hw->resets);\n"
            "\trk_mpp_reset_domain_power_deassert(hw);\n"
            "\trk_mpp_reset_domain_register_member(domain, hw);\n"
            "\trk_mpp_hw_init_reset_domain(hw);\n"
            "\thw->reset_domain = domain;\n"
            "\tdomain->node = node;\n"
            "\tdomain->reset_domain_state = RK_MPP_RESET_DOMAIN_IDLE;\n"
            "\tatomic_read(&domain->reset_domain_operation_pending);\n"
            "\tdomain->backend_ops->assert(domain, hw);\n"
            "\trk_mpp_cluster_register_member_locked(cluster, hw);\n"
            "\trk_mpp_hw_init_cluster_locked(hw);\n"
            "\trk_mpp_cluster_rebuild_locked(cluster);\n"
            "\trk_mpp_cluster_reset_group(&request, &result);\n"
            "\trk_mpp_cluster_add_ccu_job(cluster, job);\n"
            "\trk_mpp_cluster_publish_ccu_job(cluster, job, regs);\n"
            "\tINIT_LIST_HEAD(&hw->rkvdec_ccu_jobs);\n"
            "\ttable[info->next_word] = 0;\n"
            "\thw->cluster = cluster;\n"
            "\tcluster->node = node;\n"
            "\tINIT_LIST_HEAD(&cluster->members);\n"
            "\thw->ccu_node = node;\n"
            "\trk_mpp_hw_publish_register_lease(hw, 1);\n"
            "\thw->register_lease_live = true;\n"
            "\trk_mpp_activation_job(activation);\n"
            "\tif (activation->generation) job = NULL;\n"
            "\trk_mpp_dispatch_lease_acquire_locked(job);\n"
            "\trk_mpp_dispatch_lease_release_locked(job);\n"
            "\trk_mpp_job_resources(job)->rkvdec_ccu_power_lease = lease;\n"
            "\tlease->power_lease_core_count = 1;\n"
            "\tlease->power_lease_cores[0] = hw;\n"
            "\trk_mpp_cluster_power_lease_acquire(job, 1);\n"
            "\trk_mpp_job_resources(job)->rkvdec_ccu_powered = true;\n"
            "\trk_mpp_hw_power_on(hw);\n"
            "\tpm_runtime_resume_and_get(hw->dev);\n"
            "\tatomic_inc(&hw->power_count);\n"
            "\tatomic_read(&hw->power_count);\n"
            "\tatomic_cond_read_relaxed(&hw->power_count, true);\n"
            "\trk_mpp_hw_schedule_timeout(hw);\n"
            "\trk_mpp_hw_stop_and_recover(hw, job, &recovery);\n"
            "\trk_mpp_cluster_refresh_dma(&request, &set, &recovery, "
            "&failed_hw);\n"
            "\trk_mpp_fixture_evidence(-EUCLEAN, reset_ret, &recovery);\n"
            "\trk_mpp_fixture_evidence(-EUCLEAN, reset_ret, &recovery);\n"
            "\trk_mpp_fixture_evidence(-EUCLEAN, reset_ret, &recovery);\n"
            "\trk_mpp_fixture_evidence(-EUCLEAN, reset_ret, &recovery);\n"
            "\trk_mpp_fixture_evidence(-EUCLEAN, reset_ret, &recovery);\n"
            "\trk_mpp_fixture_evidence(-EUCLEAN, reset_ret, &recovery);\n"
            "\trk_mpp_fixture_evidence(-EUCLEAN, reset_ret, &recovery);\n"
            "\trk_mpp_fixture_evidence(-EUCLEAN, reset_ret, &recovery);\n"
            "\trk_mpp_fixture_evidence(-EUCLEAN, stop_ret, &recovery);\n"
            "\trk_mpp_fixture_evidence(-EUCLEAN, stop_ret, &recovery);\n"
            "\trk_mpp_fixture_evidence(-EUCLEAN, stop_ret, &recovery);\n"
            "\trk_mpp_fixture_evidence(false, reset_ret, reset_ret, &recovery);\n"
            "\trk_mpp_fixture_evidence(false, reset_ret, reset_ret, &recovery);\n"
            "\trk_mpp_fixture_evidence(false, reset_ret, reset_ret, &recovery);\n"
            "\trk_mpp_fixture_evidence(false, reset_ret, reset_ret, &recovery);\n"
            "\trk_mpp_fixture_evidence(iommu_fault, reset_ret, reset_ret, &recovery);\n"
            "\trk_mpp_hw_refresh_iommu(hw, job);\n"
            "\tvsi_iommu_refresh(hw->dev);\n"
            "\tjob->result = -EINPROGRESS;\n"
            "\thw->irq_status = 1;\n"
            "\thw->iommu_fault_pending = true;\n"
            "\thw->recovery_failed = true;\n"
            "\trk_mpp_job_resources(job)->hw_start_ns = 1;\n"
            "\trk_mpp_job_publish_outcome(job, 0);\n"
            "\trk_mpp_job_complete(job, 0);\n"
            "\twritel(1, hw->regs[0] + RK_MPP_RKVENC_START_BASE);\n"
            "\twritel(rk_mpp_job_resources(job)->rkvdec_ccu_cfg_done, "
            "hw->regs[0] + RK_MPP_RKVDEC_CCU_CFG_DONE_BASE);\n"
            "\twritel(0, hw->regs[0] + RK_MPP_AV1_IRQ_BASE);\n"
            f"{extra_mpp}"
            "}\n"
            "#if IS_ENABLED(CONFIG_ROCKCHIP_MPP_REWRITE_KUNIT_TEST)\n"
            "static void mpp_fixture(struct kunit *test)\n"
            "{\n"
            "\thw->av1_start_ns = 99;\n"
            "\thw->iommu_fault_generation = 99;\n"
            "\thw->terminally_stopped = true;\n"
            "\thw->timeout_generation = 99;\n"
            "\tjob->current_activation->generation = 99;\n"
            "\tjob->current_activation->watchdog_deadline_valid = true;\n"
            "\trk_mpp_job_resources(job)->hw_elapsed_ns += 99;\n"
            "\trk_mpp_job_publish_outcome_locked(job, -EIO);\n"
            f"{extra_kunit}"
            "}\n"
            "#endif\n",
            encoding="utf-8",
        )
        rga.write_text(
            "enum rk_rga_debug_event_type { RK_RGA_DEBUG_JOB_FAIL };\n"
            "struct rk_rga_debug_event { u8 type; };\n"
            "static void rk_rga_job_map_import(struct rk_rga_job *job)\n"
            "{\n"
            "\tdma_buf_detach(NULL, NULL);\n"
            "\t__rk_rga_job_release_execution_mappings(job);\n"
            "}\n"
            "static void __rk_rga_task_exec_release_mappings(\n"
            "\t\tstruct rk_rga_task_exec *exec)\n"
            "{\n"
            "}\n"
            "static void rk_rga_task_exec_free_cmd(\n"
            "\t\tstruct rk_rga_task_exec *exec)\n"
            "{\n"
            "}\n"
            "static void rk_rga_task_exec_release_mappings_powered(\n"
            "\t\tstruct rk_rga_task_exec *exec)\n"
            "{\n"
            "\t__rk_rga_task_exec_release_mappings(exec);\n"
            "}\n"
            "static void rk_rga_task_exec_retire_engine(\n"
            "\t\tstruct rk_rga_task_exec *exec)\n"
            "{\n"
            "\trk_rga_task_exec_free_cmd(exec);\n"
            "}\n"
            "static struct rk_rga_task_exec *\n"
            "rk_rga_hw_active_exec_locked(struct rk_rga_hw *hw)\n"
            "{\n"
            "\treturn hw->active_ref.exec;\n"
            "}\n"
            "static void rk_rga2_emit_src(struct rk_rga_job *job,\n"
            "\t\t\t     const struct rga_req *task)\n"
            "{\n"
            "\trk_rga_cmd_write(job, RK_RGA2_SRC_INFO_OFFSET, task->render_mode);\n"
            "}\n"
            "static void rk_rga_job_advance_task(struct rk_rga_job *job)\n"
            "{\n"
            "\tjob->current_task++;\n"
            "}\n"
            "static void rk_rga_hw_schedule_timeout(\n"
            "\t\tstruct rk_rga_hw *hw, struct rk_rga_job *job)\n"
            "{\n"
            "\thw->timeout_ref.exec = job->current_exec;\n"
            "}\n"
            "static void rk_rga_hw_take_irq_ref(struct rk_rga_hw *hw)\n"
            "{\n"
            "\thw->irq_ref.exec = NULL;\n"
            "}\n"
            "static void rk_rga3_execution_publish_and_start(\n"
            "\t\tstruct rk_rga_hw *hw, struct rk_rga_job *job)\n"
            "{\n"
            "\trk_rga_hw_schedule_timeout(hw, job);\n"
            "\trk_rga_write(hw, 1, RK_RGA3_CMD_CTRL);\n"
            "}\n"
            "static void rga_paths(struct rk_rga_hw *hw, struct rk_rga_job *job)\n"
            "{\n"
            "\thw->active_job = job;\n"
            "\trk_rga_job_release_execution_mappings_powered(job, hw);\n"
            "\trk_rga_job_free_cmd(job);\n"
            "\tjob->irq_result = 0;\n"
            "\thw->iommu_fault_generation = 1;\n"
            "\thw->recovery_failed = true;\n"
            "\thw->timeout_job = job;\n"
            "\tjob->hw_start_ns = 1;\n"
            "\tWRITE_ONCE(job->result, 0);\n"
            "\tWRITE_ONCE(event.result, 0);\n"
            "\trk_rga_hw_recover_active(hw, false, NULL, 0);\n"
            f"{extra_rga}"
            "}\n"
            "#if IS_ENABLED(CONFIG_ROCKCHIP_RGA_REWRITE_KUNIT_TEST)\n"
            "static void rga_fixture(struct kunit *test)\n"
            "{\n"
            "\tdma_buf_unmap_attachment(NULL, NULL, 0);\n"
            "\trk_rga_job_discard_execution_mappings(NULL);\n"
            "\tdma_free_coherent(job->cmd_dev, job->cmd_size,\n"
            "\t\t\t  job->cmd_vaddr, job->cmd_dma);\n"
            "\tjob->irq_seen = true;\n"
            "\thw->iommu_fault_generation = 99;\n"
            "\thw->removing = true;\n"
            "\thw->timeout_generation = 99;\n"
            "\tjob->hw_elapsed_ns += 99;\n"
            "\tsmp_store_release(&job->done, true);\n"
            "\trk_rga_hw_abort_jobs(hw, -EIO);\n"
            "\trk_rga_hw_restore_active_after_reset_failure(NULL, NULL, true);\n"
            "\trk_rga_job_abort_pending_acquire(NULL, -EFAULT);\n"
            "}\n"
            "#endif\n",
            encoding="utf-8",
        )

    def run_audit(
        self, tree: Path, baseline: Path, *options: str
    ) -> subprocess.CompletedProcess[str]:
        return self.run_audit_trees((tree,), baseline, *options)

    def run_audit_trees(
        self, trees: tuple[Path, ...], baseline: Path, *options: str
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                str(self.audit),
                "--baseline",
                str(baseline),
                "--legacy-test-fixture",
                *options,
                *(str(tree) for tree in trees),
            ],
            capture_output=True,
            text=True,
        )

    def test_legacy_fixture_bypass_requires_marker(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            tree = root / "linux"
            baseline = root / "baseline.tsv"
            self.make_tree(tree)
            source = tree / "drivers/video/rockchip/mpp-rewrite/mpp_rewrite.c"
            source.write_text(
                source.read_text(encoding="utf-8").replace(
                    "/* rewrite-ownership-audit legacy test fixture */\n", "", 1
                ),
                encoding="utf-8",
            )

            rejected = self.run_audit(tree, baseline, "--update-baseline")
            self.assertEqual(rejected.returncode, 2)
            self.assertIn(
                "--legacy-test-fixture requires the synthetic fixture marker",
                rejected.stderr,
            )

    def test_inventory_is_source_bound_and_catches_new_reset_writer(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            tree = root / "linux"
            baseline = root / "baseline.tsv"
            self.make_tree(tree)
            updated = self.run_audit(tree, baseline, "--update-baseline")
            self.assertEqual(updated.returncode, 0, updated.stderr)
            baseline_text = baseline.read_text(encoding="utf-8")
            self.assertNotIn("mpp-active-slot-access", baseline_text)
            for category in (
                "mpp-activation-parent-schema",
                "mpp-activation-link-schema",
                "mpp-activation-list-schema",
                "mpp-activation-storage-schema",
                "mpp-current-activation-schema",
                "mpp-current-activation-access",
                "mpp-current-activation-write",
                "mpp-activation-storage-access",
                "mpp-activation-list-access",
                "mpp-activation-list-write",
                "mpp-activation-link-access",
                "mpp-activation-link-write",
                "mpp-activation-allocation",
                "mpp-activation-free",
                "mpp-activation-generation-schema",
                "mpp-activation-deadline-schema",
                "mpp-activation-deadline-valid-schema",
                "mpp-activation-slot-state-enum-schema",
                "mpp-activation-transition-reason-enum-schema",
                "mpp-activation-slot-state-schema",
                "mpp-activation-transition-reason-schema",
                "mpp-activation-ref-schema",
                "mpp-activation-ref-pointer-schema",
                "mpp-activation-ref-generation-schema",
                "mpp-activation-refcount-schema",
                "mpp-active-ref-schema",
                "mpp-active-ref-access",
                "mpp-timeout-ref-schema",
                "mpp-timeout-ref-access",
                "mpp-activation-sequence-schema",
                "mpp-activation-sequence-access",
                "mpp-activation-sequence-write",
                "mpp-activation-parent-write",
                "mpp-activation-generation-write",
                "mpp-activation-deadline-write",
                "mpp-activation-slot-state-access",
                "mpp-activation-slot-state-write",
                "mpp-activation-transition-reason-access",
                "mpp-activation-transition-reason-write",
                "mpp-active-transition-entry",
                "mpp-activation-fault-priority-schema",
            ):
                self.assertIn(category, baseline_text)
            self.assertIn("mpp-activation-schema", baseline_text)
            self.assertIn("mpp-activation-entry", baseline_text)
            self.assertIn("mpp-activation-access", baseline_text)
            self.assertIn("mpp-activation-write", baseline_text)
            self.assertIn("mpp-selected-hw-schema", baseline_text)
            self.assertIn("mpp-selected-hw-access", baseline_text)
            self.assertIn("mpp-selected-hw-write", baseline_text)
            self.assertIn("mpp-rkvdec-ccu-schema", baseline_text)
            self.assertIn("mpp-activation-resource-state-enum-schema", baseline_text)
            self.assertIn("mpp-activation-resource-state-schema", baseline_text)
            self.assertIn("mpp-activation-resources-member-schema", baseline_text)
            self.assertIn("mpp-activation-resource-schema", baseline_text)
            self.assertIn("mpp-dispatch-owner-schema", baseline_text)
            self.assertIn("mpp-dispatch-lease-access", baseline_text)
            self.assertIn("mpp-dispatch-lease-write", baseline_text)
            self.assertNotIn("rkvdec_session_dispatch", baseline_text)
            self.assertNotIn("rkvdec_dispatch_active", baseline_text)
            self.assertNotIn("job->current_activation->generation = 99", baseline_text)
            self.assertIn("mpp-reset-domain-operation-entry", baseline_text)
            self.assertIn("mpp-reset-domain-member-entry", baseline_text)
            self.assertIn("mpp-reset-domain-binding-access", baseline_text)
            self.assertIn("mpp-reset-domain-registry-access", baseline_text)
            self.assertIn("mpp-reset-domain-state-write", baseline_text)
            self.assertIn("mpp-reset-domain-pending-access", baseline_text)
            self.assertIn("mpp-reset-backend-access", baseline_text)
            self.assertIn("mpp-cluster-lifecycle-entry", baseline_text)
            self.assertIn("mpp-cluster-topology-entry", baseline_text)
            self.assertIn("mpp-cluster-reset-entry", baseline_text)
            self.assertIn("mpp-cluster-power-lease-entry", baseline_text)
            self.assertIn("mpp-cluster-power-lease-access", baseline_text)
            self.assertIn("mpp-cluster-runtime-entry", baseline_text)
            self.assertIn("mpp-recovery-entry", baseline_text)
            self.assertIn("mpp-recovery-result-access", baseline_text)
            self.assertIn("mpp-recovery-result-write", baseline_text)
            self.assertIn("mpp-cluster-publication-entry", baseline_text)
            self.assertIn("mpp-cluster-running-list-access", baseline_text)
            self.assertIn("mpp-ccu-chain-link-write", baseline_text)
            self.assertIn("mpp-ccu-control-write", baseline_text)
            self.assertIn("mpp-cluster-binding-access", baseline_text)
            self.assertIn("mpp-cluster-registry-access", baseline_text)
            self.assertIn("mpp-cluster-state-write", baseline_text)
            self.assertIn(
                "mpp-cluster-topology-input-access", baseline_text
            )
            self.assertIn("mpp-register-lease-entry", baseline_text)
            self.assertIn("mpp-register-lease-access", baseline_text)
            self.assertIn("mpp-register-lease-write", baseline_text)
            self.assertIn("mpp-dispatch-lease-access", baseline_text)
            self.assertIn("rga-active-slot-access", baseline_text)
            self.assertIn("rga-raw-task-emitter", baseline_text)
            self.assertIn("rga-exec-map-owner", baseline_text)
            self.assertIn("rga-map-release-primitive", baseline_text)
            self.assertIn("rga-command-release", baseline_text)
            self.assertIn(
                "__rk_rga_task_exec_release_mappings", baseline_text
            )
            self.assertNotIn("rga_fixture", baseline_text)
            self.assertIn("rkvdec_ccu_power_lease", baseline_text)
            self.assertIn("power_lease_core_count", baseline_text)
            self.assertIn("rkvdec_ccu_powered = true", baseline_text)
            self.assertIn("mpp-power-transition-entry", baseline_text)
            self.assertIn("mpp-power-backend-op", baseline_text)
            self.assertIn("mpp-power-count-write", baseline_text)
            self.assertNotIn("atomic_read(&hw->power_count)", baseline_text)
            self.assertNotIn("atomic_cond_read_relaxed", baseline_text)
            self.assertIn("mpp-watchdog-arm-entry", baseline_text)
            self.assertIn("rga-watchdog-arm-entry", baseline_text)
            self.assertIn("mpp-iommu-transition", baseline_text)
            self.assertIn("mpp-irq-ack-write", baseline_text)
            self.assertIn("mpp-irq-snapshot-write", baseline_text)
            self.assertIn("mpp-fault-snapshot-write", baseline_text)
            self.assertIn("mpp-terminal-state-write", baseline_text)
            self.assertIn("mpp-watchdog-snapshot-write", baseline_text)
            self.assertIn("mpp-outcome-publish-entry", baseline_text)
            self.assertIn("rga-irq-snapshot-write", baseline_text)
            self.assertIn("rga-timeout-ref-access", baseline_text)
            self.assertIn("rga-irq-ref-access", baseline_text)
            self.assertIn("rga-terminal-state-write", baseline_text)
            self.assertIn("rga-job-outcome-write", baseline_text)
            self.assertNotIn("WRITE_ONCE(event.result, 0)", baseline_text)
            self.assertIn("rga-activation-timing-write", baseline_text)
            self.assertIn("rga-terminal-entry", baseline_text)
            self.assertIn("start-doorbell-write", baseline_text)
            self.assertIn("RK_MPP_RKVDEC_CCU_CFG_DONE_BASE", baseline_text)
            self.assertFalse(
                any(
                    line.startswith("start-doorbell-write\t")
                    and "writel(0, hw->regs[0] + RK_MPP_AV1_IRQ_BASE);" in line
                    for line in baseline_text.splitlines()
                ),
                baseline_text,
            )

            known = self.run_audit(tree, baseline)
            self.assertEqual(known.returncode, 0, known.stderr)

            self.make_tree(
                tree,
                extra_mpp=(
                    "\tjob->rkvdec_ccu_powered = false;\n"
                    "\trk_mpp_hw_power_off(hw);\n"
                    "\tclk_bulk_prepare_enable(1, hw->clks);\n"
                    "\tclk_bulk_enable(1, hw->clks);\n"
                    "\tpm_runtime_get_sync(hw->dev);\n"
                    "\tpm_runtime_force_suspend(hw->dev);\n"
                    "\tdevm_clk_bulk_get_all(hw->dev, &clks);\n"
                    "\tatomic_dec_if_positive(&hw->power_count);\n"
                    "\tatomic_xchg(&hws[0]->power_count, 0);\n"
                    "\tatomic_add(1, &hws[0]->power_count);\n"
                    "\trk_mpp_hw_schedule_timeout(hws[0]);\n"
                    "\tiommu_attach_group(NULL, NULL);\n"
                    "\tjob->state = RK_MPP_JOB_DONE;\n"
                    "\ttry_cmpxchg(&jobs[0]->result, &old_result, -EIO);\n"
                    "\thws[0]->av1_start_ns = 2;\n"
                    "\thw[0].iommu_fault_generation = 2;\n"
                    "\t(*hw).terminally_stopped = true;\n"
                    "\thw->online = false;\n"
                    "\t(*job).hw_elapsed_ns += 2;\n"
                    "\trk_mpp_job_publish_outcome_locked(job, -EIO);\n"
                    "\trk_mpp_reset_domain_recovery_pulse(hw);\n"
                    "\trk_mpp_reset_domain_begin(\n"
                    "\t\thw, RK_MPP_RESET_DOMAIN_RESETTING);\n"
                    "\trk_mpp_reset_domain_finish(hw, 0);\n"
                    "\trk_mpp_reset_domain_unregister_member(hw);\n"
                    "\trk_mpp_reset_domain_get_locked(srv, node, &added);\n"
                    "\trk_mpp_reset_domain_unregister_action;\n"
                    "\trk_mpp_reset_domains_destroy(srv);\n"
                    "\thws[0]->reset_domain = domain;\n"
                    "\tdomain->members.next = &domain->members;\n"
                    "\tdomains[0]->reset_domain_epoch++;\n"
                    "\tatomic_set(\n"
                    "\t\t&domains[0]->reset_domain_operation_pending, 0);\n"
                    "\tatomic_inc_return(\n"
                    "\t\t&domains[0]->reset_domain_operation_pending);\n"
                    "\tatomic_dec(\n"
                    "\t\t&domains[0]->reset_domain_operation_pending);\n"
                    "\tatomic_add(1,\n"
                    "\t\t&domains[0]->reset_domain_operation_pending);\n"
                    "\trk_mpp_cluster_unregister_member_locked(hw);\n"
                    "\trk_mpp_cluster_get_locked(srv, node, &added);\n"
                    "\trk_mpp_cluster_dma_group_count_locked(cluster);\n"
                    "\trk_mpp_cluster_reset_valid_locked(domain, &request);\n"
                    "\trk_mpp_cluster_power_lease_release(jobs[0]);\n"
                    "\trk_mpp_cluster_remove_ccu_job(cluster, job, ccu);\n"
                    "\trk_mpp_cluster_arm_soft_ccu(job);\n"
                    "\trk_mpp_cluster_collect_dma(&requests[0], &sets[0]);\n"
                    "\trk_mpp_rkvdec2_force_stop_ccu(hw, &recoveries[0]);\n"
                    "\trk_mpp_hw_finish_recovery(hw, job, &recoveries[0]);\n"
                    "\tjob->rkvdec_ccu_listed = false;\n"
                    "\tnext_table[info->next_word] = 1;\n"
                    "\twritel_relaxed(1, hw->regs[0] + "
                    "RK_MPP_RKVDEC_CCU_CORE_STA_BASE);\n"
                    "\txchg(&jobs[0]->rkvdec_ccu_power_lease, NULL);\n"
                    "\tleases[0]->power_lease_core_count += 2;\n"
                    "\tdomain->backend_ops->deassert(domain, hw);\n"
                    "\thws[0]->cluster = cluster;\n"
                    "\trequest.cluster = cluster;\n"
                    "\tclusters[0].member_count++;\n"
                    "\tlist_add_tail(&hw->cluster_link,\n"
                    "\t\t      &clusters[0].members);\n"
                    "\thws[0]->iommu_domain = domain;\n"
                    "\tgroups[0]->isolated = true;\n"
                    "\trk_mpp_hw_invalidate_register_lease(hws[0], 2);\n"
                    "\thws[0]->register_lease_generation = 2;\n"
                    "\t__rk_mpp_hw_refresh_iommu(hw, srv);\n"
                    "\treset_control_bulk_reset(1, NULL);\n"
                    "\treset_control_rearm(hw->resets);\n"
                ),
                extra_kunit=(
                    "\treset_control_deassert(NULL);\n"
                    "\tfake.active_job = NULL;\n"
                    "\tjob->session->rkvdec_dispatch_owner = "
                    "job->current_activation;\n"
                    "\tfake.rkvdec_ccu_powered = false;\n"
                    "\tiommu_flush_iotlb_all(NULL);\n"
                    "\tfake.result = 0;\n"
                    "\thw->irq_status = 88;\n"
                    "\thw->iommu_fault_pending = false;\n"
                    "\thw->terminal_power_drained = true;\n"
                    "\tfake.online = true;\n"
                    "\tjob->current_activation->watchdog_deadline = 88;\n"
                    "\tjob->hw_start_ns = 88;\n"
                    "\trk_mpp_job_publish_outcome(job, -ECANCELED);\n"
                ),
                extra_rga=(
                    "\tdma_buf_unmap_attachment(NULL, NULL, 0);\n"
                    "\trk_rga_task_exec_release_mappings_powered(\n"
                    "\t\tjob->current_exec);\n"
                    "\trk_rga_task_exec_free_cmd(job->current_exec);\n"
                    "\tjobs[0]->irq_seen = true;\n"
                    "\thws[0]->irq_ref.exec = job->current_exec;\n"
                    "\t(*hw).removing = true;\n"
                    "\thws[0]->timeout_ref.exec = job->current_exec;\n"
                    "\trk_rga_hw_schedule_timeout(hw, &replacement);\n"
                    "\tjobs[0]->current_task >>= 1;\n"
                    "\t--jobs[0]->current_task;\n"
                    "\t(*job).hw_elapsed_ns += 2;\n"
                    "\t(*job).result = -EIO;\n"
                    "\tsmp_store_release(&job->done, true);\n"
                    "\trk_rga_hw_abort_jobs(hw, -EIO);\n"
                    "\trk_rga_hw_restore_active_after_reset_failure(\n"
                    "\t\thw, job, false);\n"
                    "\trk_rga_job_abort_pending_acquire(job, -EIO);\n"
                    "\trk_rga_session_abort_hw_jobs(NULL, -EIO);\n"
                ),
            )
            changed = self.run_audit(tree, baseline)
            self.assertEqual(changed.returncode, 1)
            self.assertIn("NEW\tmpp-power-field", changed.stderr)
            self.assertIn("NEW\tmpp-power-transition-entry", changed.stderr)
            self.assertIn("NEW\tmpp-power-backend-op", changed.stderr)
            self.assertIn("NEW\tmpp-power-count-write", changed.stderr)
            self.assertIn("NEW\tmpp-watchdog-arm-entry", changed.stderr)
            self.assertIn("NEW\tmpp-iommu-transition", changed.stderr)
            self.assertIn("NEW\tmpp-iommu-backend-op", changed.stderr)
            self.assertIn("NEW\tmpp-job-lifecycle-write", changed.stderr)
            self.assertIn("NEW\tmpp-irq-snapshot-write", changed.stderr)
            self.assertIn("NEW\tmpp-fault-snapshot-write", changed.stderr)
            self.assertIn("NEW\tmpp-terminal-state-write", changed.stderr)
            self.assertIn("NEW\tmpp-outcome-publish-entry", changed.stderr)
            self.assertIn("NEW\tmpp-activation-timing-write", changed.stderr)
            self.assertIn("NEW\tmpp-reset-control", changed.stderr)
            self.assertIn(
                "NEW\tmpp-reset-domain-operation-entry", changed.stderr
            )
            self.assertIn("NEW\tmpp-reset-domain-member-entry", changed.stderr)
            self.assertIn(
                "NEW\tmpp-reset-domain-binding-access", changed.stderr
            )
            self.assertIn(
                "NEW\tmpp-reset-domain-registry-access", changed.stderr
            )
            self.assertIn("NEW\tmpp-reset-domain-state-write", changed.stderr)
            self.assertIn(
                "NEW\tmpp-reset-domain-pending-access", changed.stderr
            )
            self.assertIn("NEW\tmpp-reset-backend-access", changed.stderr)
            self.assertIn("NEW\tmpp-cluster-lifecycle-entry", changed.stderr)
            self.assertIn("NEW\tmpp-cluster-topology-entry", changed.stderr)
            self.assertIn("NEW\tmpp-cluster-reset-entry", changed.stderr)
            self.assertIn(
                "NEW\tmpp-cluster-power-lease-entry", changed.stderr
            )
            self.assertIn(
                "NEW\tmpp-cluster-power-lease-access", changed.stderr
            )
            self.assertIn("NEW\tmpp-cluster-runtime-entry", changed.stderr)
            self.assertIn("NEW\tmpp-recovery-entry", changed.stderr)
            self.assertIn(
                "NEW\tmpp-cluster-publication-entry", changed.stderr
            )
            self.assertIn(
                "NEW\tmpp-cluster-running-list-access", changed.stderr
            )
            self.assertIn("NEW\tmpp-ccu-chain-link-write", changed.stderr)
            self.assertIn("NEW\tmpp-ccu-control-write", changed.stderr)
            self.assertIn("NEW\tmpp-cluster-binding-access", changed.stderr)
            self.assertIn("NEW\tmpp-cluster-registry-access", changed.stderr)
            self.assertIn("NEW\tmpp-cluster-state-write", changed.stderr)
            self.assertIn(
                "NEW\tmpp-cluster-topology-input-access", changed.stderr
            )
            self.assertIn("NEW\tmpp-register-lease-entry", changed.stderr)
            self.assertIn("NEW\tmpp-register-lease-access", changed.stderr)
            self.assertIn("NEW\tmpp-register-lease-write", changed.stderr)
            self.assertIn("NEW\trga-exec-map-owner", changed.stderr)
            self.assertIn("NEW\trga-map-release-primitive", changed.stderr)
            self.assertIn("NEW\trga-command-release", changed.stderr)
            self.assertIn("NEW\trga-irq-snapshot-write", changed.stderr)
            self.assertIn("NEW\trga-timeout-ref-access", changed.stderr)
            self.assertIn("NEW\trga-irq-ref-access", changed.stderr)
            self.assertIn("NEW\trga-terminal-state-write", changed.stderr)
            self.assertIn("NEW\trga-job-outcome-write", changed.stderr)
            self.assertIn("NEW\trga-watchdog-arm-entry", changed.stderr)
            self.assertIn("NEW\trga-activation-timing-write", changed.stderr)
            self.assertIn("NEW\trga-terminal-entry", changed.stderr)
            self.assertIn("reset_control_bulk_reset", changed.stderr)
            self.assertIn("reset_control_rearm", changed.stderr)
            new_lines = changed.stderr.splitlines()
            for category, signal in (
                ("mpp-power-count-write", "atomic_xchg(&hws[0]->power_count"),
                ("mpp-power-count-write", "atomic_add(1, &hws[0]->power_count"),
                ("mpp-power-backend-op", "clk_bulk_enable(1, hw->clks)"),
                ("mpp-power-backend-op", "pm_runtime_get_sync(hw->dev)"),
                ("mpp-power-backend-op", "pm_runtime_force_suspend(hw->dev)"),
                ("mpp-power-backend-op", "devm_clk_bulk_get_all(hw->dev"),
                ("mpp-job-lifecycle-write", "try_cmpxchg(&jobs[0]->result"),
                (
                    "mpp-reset-domain-operation-entry",
                    "rk_mpp_reset_domain_begin",
                ),
                (
                    "mpp-reset-domain-operation-entry",
                    "rk_mpp_reset_domain_finish",
                ),
                (
                    "mpp-reset-domain-state-write",
                    "atomic_set( &domains[0]->reset_domain_operation_pending",
                ),
                (
                    "mpp-reset-domain-state-write",
                    "atomic_inc_return( &domains[0]->reset_domain_operation_pending",
                ),
                (
                    "mpp-reset-domain-state-write",
                    "atomic_dec( &domains[0]->reset_domain_operation_pending",
                ),
                (
                    "mpp-reset-domain-state-write",
                    "atomic_add(1, &domains[0]->reset_domain_operation_pending",
                ),
                (
                    "mpp-reset-domain-member-entry",
                    "rk_mpp_reset_domain_get_locked",
                ),
                (
                    "mpp-reset-domain-member-entry",
                    "rk_mpp_reset_domain_unregister_action",
                ),
                (
                    "mpp-cluster-lifecycle-entry",
                    "rk_mpp_cluster_unregister_member_locked",
                ),
                (
                    "mpp-cluster-topology-entry",
                    "rk_mpp_cluster_dma_group_count_locked",
                ),
                (
                    "mpp-cluster-reset-entry",
                    "rk_mpp_cluster_reset_valid_locked",
                ),
                (
                    "mpp-reset-backend-access",
                    "backend_ops->deassert",
                ),
                ("mpp-cluster-state-write", "hws[0]->cluster = cluster"),
                (
                    "mpp-cluster-state-write",
                    "clusters[0].member_count++",
                ),
                (
                    "mpp-cluster-topology-input-access",
                    "hws[0]->iommu_domain = domain",
                ),
                ("rga-timeout-ref-access", "hws[0]->timeout_ref.exec"),
                ("rga-irq-ref-access", "hws[0]->irq_ref.exec"),
                ("rga-task-advance", "current_task >>= 1"),
                ("rga-task-advance", "--jobs[0]->current_task"),
            ):
                self.assertTrue(
                    any(
                        line.startswith(f"NEW\t{category}\t") and signal in line
                        for line in new_lines
                    ),
                    f"missing {category} signal {signal!r}:\n{changed.stderr}",
                )
            self.assertIn("hw->online = false", changed.stderr)
            self.assertIn(
                "rk_rga_hw_restore_active_after_reset_failure", changed.stderr
            )
            self.assertIn("rk_rga_job_abort_pending_acquire", changed.stderr)
            self.assertIn("rk_rga_session_abort_hw_jobs", changed.stderr)
            self.assertIn("(*job).result = -EIO", changed.stderr)
            self.assertNotIn("reset_control_deassert", changed.stderr)
            self.assertNotIn("fake.active_job", changed.stderr)
            self.assertNotIn("rkvdec_dispatch_owner", changed.stderr)
            self.assertNotIn("fake.rkvdec_ccu_powered", changed.stderr)
            self.assertNotIn("fake.online", changed.stderr)
            self.assertNotIn("iommu_flush_iotlb_all", changed.stderr)
            self.assertNotIn("fake.result", changed.stderr)
            self.assertNotIn("irq_status = 88", changed.stderr)
            self.assertNotIn("activation.watchdog_deadline = 88", changed.stderr)
            self.assertNotIn("hw_start_ns = 88", changed.stderr)
            self.assertNotIn("job, -ECANCELED", changed.stderr)
            self.assertNotIn("iommu_fault_generation = 99", changed.stderr)
            self.assertNotIn("NULL, NULL, true", changed.stderr)
            self.assertEqual(
                changed.stderr.count("dma_buf_unmap_attachment(NULL"), 1
            )
            self.assertEqual(
                changed.stderr.count(
                    "rk_rga_task_exec_free_cmd(job->current_exec)"
                ),
                1,
            )

            baseline.write_text(
                baseline_text.replace("# source-head\tunknown", "# source-head\tdeadbeef"),
                encoding="utf-8",
            )
            wrong_head = self.run_audit(tree, baseline)
            self.assertEqual(wrong_head.returncode, 1)
            self.assertIn("source HEAD unknown is not pinned", wrong_head.stderr)

    def test_dispatch_owner_identity_is_hard_guarded(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            tree = root / "linux"
            baseline = root / "baseline.tsv"
            self.make_tree(tree)
            updated = self.run_audit(tree, baseline, "--update-baseline")
            self.assertEqual(updated.returncode, 0, updated.stderr)

            self.make_tree(
                tree,
                extra_mpp=(
                    "\tif (session->rkvdec_dispatch_owner) job = NULL;\n"
                    "\tWRITE_ONCE(session->rkvdec_dispatch_owner, "
                    "job->current_activation);\n"
                    "\txchg(&session->rkvdec_dispatch_owner, NULL);\n"
                ),
            )
            rejected = self.run_audit(tree, baseline)
            self.assertEqual(rejected.returncode, 2)
            self.assertIn("OWNER\tmpp-dispatch-lease-access", rejected.stderr)
            self.assertIn("OWNER\tmpp-dispatch-lease-write", rejected.stderr)
            self.assertIn("rkvdec_dispatch_owner", rejected.stderr)

            rebased = self.run_audit(tree, baseline, "--update-baseline")
            self.assertEqual(rebased.returncode, 2)
            self.assertIn("used outside its allowed owners", rebased.stderr)

            self.make_tree(tree)
            source = tree / "drivers/video/rockchip/mpp-rewrite/mpp_rewrite.c"
            source.write_text(
                source.read_text(encoding="utf-8")
                + "static bool rk_mpp_dispatch_lease_active_locked("
                "struct rk_mpp_session *session)\n"
                "{\n"
                "\tsession->rkvdec_dispatch_owner = NULL;\n"
                "\treturn false;\n"
                "}\n",
                encoding="utf-8",
            )
            wrong_owner = self.run_audit(tree, baseline)
            self.assertEqual(wrong_owner.returncode, 2)
            self.assertIn("OWNER\tmpp-dispatch-lease-write", wrong_owner.stderr)
            self.assertIn("rk_mpp_dispatch_lease_active_locked", wrong_owner.stderr)

            self.make_tree(
                tree,
                extra_mpp="\tjob->rkvdec_session_dispatch = true;\n",
            )
            legacy = self.run_audit(tree, baseline)
            self.assertEqual(legacy.returncode, 2)
            self.assertIn("OWNER\tmpp-dispatch-legacy", legacy.stderr)
            self.assertIn("rkvdec_session_dispatch", legacy.stderr)
            legacy_rebased = self.run_audit(
                tree, baseline, "--update-baseline"
            )
            self.assertEqual(legacy_rebased.returncode, 2)
            self.assertIn("OWNER\tmpp-dispatch-legacy", legacy_rebased.stderr)

            self.make_tree(
                tree,
                extra_kunit=(
                    "\tsession->rkvdec_dispatch_owner = "
                    "job->current_activation;\n"
                ),
            )
            kunit_only = self.run_audit(tree, baseline)
            self.assertEqual(kunit_only.returncode, 0, kunit_only.stderr)

            self.make_tree(
                tree,
                extra_kunit="\tjob->rkvdec_session_dispatch = true;\n",
            )
            legacy_kunit = self.run_audit(tree, baseline)
            self.assertEqual(legacy_kunit.returncode, 2)
            self.assertIn("OWNER\tmpp-dispatch-legacy", legacy_kunit.stderr)

            self.make_tree(tree)
            source.write_text(
                source.read_text(encoding="utf-8").replace(
                    "struct rk_mpp_activation *rkvdec_dispatch_owner;",
                    "struct rk_mpp_job *rkvdec_dispatch_owner;",
                ),
                encoding="utf-8",
            )
            schema_changed = self.run_audit(tree, baseline)
            self.assertEqual(schema_changed.returncode, 2)
            self.assertIn("found 0 there and 0 overall", schema_changed.stderr)

            self.make_tree(tree)
            source.write_text(
                source.read_text(encoding="utf-8")
                + "struct rk_mpp_job_duplicate {\n"
                "\tstruct rk_mpp_activation *rkvdec_dispatch_owner;\n"
                "};\n",
                encoding="utf-8",
            )
            schema_duplicated = self.run_audit(tree, baseline)
            self.assertEqual(schema_duplicated.returncode, 2)
            self.assertIn("found 1 there and 2 overall", schema_duplicated.stderr)

            self.make_tree(tree)
            source.write_text(
                source.read_text(encoding="utf-8").replace(
                    "struct rk_mpp_session {\n"
                    "\tstruct rk_mpp_activation *rkvdec_dispatch_owner;\n"
                    "};\n",
                    "struct rk_mpp_session { int unused; };\n"
                    "struct rk_mpp_job_duplicate {\n"
                    "\tstruct rk_mpp_activation *rkvdec_dispatch_owner;\n"
                    "};\n",
                ),
                encoding="utf-8",
            )
            schema_moved = self.run_audit(tree, baseline)
            self.assertEqual(schema_moved.returncode, 2)
            self.assertIn("found 0 there and 1 overall", schema_moved.stderr)

    def test_baseline_output_rejects_cross_tree_drift(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            first = root / "linux-first"
            second = root / "linux-second"
            baseline = root / "baseline.tsv"
            self.make_tree(first)
            self.make_tree(second)
            updated = self.run_audit_trees(
                (first, second), baseline, "--update-baseline"
            )
            self.assertEqual(updated.returncode, 0, updated.stderr)
            original = baseline.read_text(encoding="utf-8")

            self.make_tree(second, extra_mpp="\trk_mpp_hw_power_off(hw);\n")
            for options in (
                (),
                ("--emit-baseline",),
                ("--update-baseline",),
            ):
                rejected = self.run_audit_trees(
                    (first, second), baseline, *options
                )
                self.assertEqual(rejected.returncode, 2, rejected.stderr)
                self.assertIn("tracked source bytes differ", rejected.stderr)
            self.assertEqual(baseline.read_text(encoding="utf-8"), original)

    def test_activation_slot_surfaces_are_hard_guarded(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            tree = root / "linux"
            baseline = root / "baseline.tsv"
            self.make_tree(tree)
            updated = self.run_audit(tree, baseline, "--update-baseline")
            self.assertEqual(updated.returncode, 0, updated.stderr)
            source = tree / "drivers/video/rockchip/mpp-rewrite/mpp_rewrite.c"
            pristine = source.read_text(encoding="utf-8")
            cases = (
                (
                    pristine.replace(
                        "#if IS_ENABLED(CONFIG_ROCKCHIP_MPP_REWRITE_KUNIT_TEST)",
                        "static void hostile(struct rk_mpp_hw *hw)\n"
                        "{\n"
                        "\tmemset(&hw->active_ref, 0, "
                        "sizeof(hw->active_ref));\n"
                        "}\n"
                        "#if IS_ENABLED("
                        "CONFIG_ROCKCHIP_MPP_REWRITE_KUNIT_TEST)",
                        1,
                    ),
                    "activation reference address escapes",
                ),
                (
                    pristine.replace(
                        "\tstruct rk_mpp_activation_ref active_ref;\n",
                        "\tstruct rk_mpp_activation *active_activation;\n",
                        1,
                    ),
                    "struct rk_mpp_activation_ref active_ref member",
                ),
                (
                    pristine.replace(
                        "\tstruct rk_mpp_activation_ref timeout_ref;\n",
                        "\tu64 timeout_generation;\n",
                        1,
                    ),
                    "struct rk_mpp_activation_ref timeout_ref member",
                ),
                (
                    pristine.replace(
                        "\tu64 activation_generation_seq;\n",
                        "\tu32 activation_generation_seq;\n",
                        1,
                    ),
                    "activation_generation_seq member",
                ),
            )
            for mutated, expected in cases:
                source.write_text(mutated, encoding="utf-8")
                for options in ((), ("--update-baseline",)):
                    rejected = self.run_audit(tree, baseline, *options)
                    self.assertEqual(rejected.returncode, 2, rejected.stderr)
                    self.assertIn(expected, rejected.stderr)

            self.make_tree(
                tree,
                extra_kunit=(
                    "\tmemset(&hw->active_ref, 0, sizeof(hw->active_ref));\n"
                    "\tmemset(&hw->timeout_ref, 0, sizeof(hw->timeout_ref));\n"
                ),
            )
            self.assertEqual(self.run_audit(tree, baseline).returncode, 0)

    def test_selected_hw_and_ccu_surfaces_are_hard_guarded(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            tree = root / "linux"
            baseline = root / "baseline.tsv"
            self.make_tree(tree)
            updated = self.run_audit(tree, baseline, "--update-baseline")
            self.assertEqual(updated.returncode, 0, updated.stderr)

            self.make_tree(
                tree,
                extra_mpp=(
                    "\tif (job->current_activation->selected_hw) job = NULL;\n"
                    "\tjob->current_activation->selected_hw = hw;\n"
                    "\tWRITE_ONCE(job->current_activation->selected_hw, hw);\n"
                    "\txchg(&job->current_activation->selected_hw, hw);\n"
                    "\tcmpxchg(&job->current_activation->selected_hw, old, hw);\n"
                    "\tif (job->rkvdec_ccu) job = NULL;\n"
                    "\tjob->rkvdec_ccu = hw;\n"
                    "\tWRITE_ONCE(job->rkvdec_ccu, hw);\n"
                ),
            )
            rejected = self.run_audit(tree, baseline)
            self.assertEqual(rejected.returncode, 2)
            self.assertIn("OWNER\tmpp-selected-hw-access", rejected.stderr)
            self.assertIn("OWNER\tmpp-selected-hw-write", rejected.stderr)
            self.assertIn("OWNER\tmpp-rkvdec-ccu-access", rejected.stderr)
            self.assertIn("OWNER\tmpp-rkvdec-ccu-write", rejected.stderr)
            self.assertIn("WRITE_ONCE(job->current_activation->selected_hw", rejected.stderr)
            self.assertIn("cmpxchg(&job->current_activation->selected_hw", rejected.stderr)

            rebased = self.run_audit(tree, baseline, "--update-baseline")
            self.assertEqual(rebased.returncode, 2)
            self.assertIn("used outside its allowed owners", rebased.stderr)

            self.make_tree(tree)
            source = tree / "drivers/video/rockchip/mpp-rewrite/mpp_rewrite.c"
            source.write_text(
                source.read_text(encoding="utf-8")
                + "static void rk_mpp_job_get_hw(struct rk_mpp_job *job)\n"
                "{\n"
                "\tjob->current_activation->selected_hw = hw;\n"
                "}\n"
                "static void rk_mpp_cluster_add_ccu_job("
                "struct rk_mpp_job *job)\n"
                "{\n"
                "\tjob->rkvdec_ccu = hw;\n"
                "}\n",
                encoding="utf-8",
            )
            read_owner_writes = self.run_audit(tree, baseline)
            self.assertEqual(read_owner_writes.returncode, 2)
            self.assertIn("OWNER\tmpp-selected-hw-write", read_owner_writes.stderr)
            self.assertIn("OWNER\tmpp-rkvdec-ccu-write", read_owner_writes.stderr)

            self.make_tree(
                tree,
                extra_kunit=(
                    "\tjob->current_activation->selected_hw = hw;\n"
                    "\tjob->rkvdec_ccu = hw;\n"
                ),
            )
            kunit_only = self.run_audit(tree, baseline)
            self.assertEqual(kunit_only.returncode, 0, kunit_only.stderr)

            self.make_tree(tree)
            source.write_text(
                source.read_text(encoding="utf-8").replace(
                    "\tstruct rk_mpp_session *session;\n",
                    "\tstruct rk_mpp_session *session;\n"
                    "\tstruct rk_mpp_hw *hw;\n",
                    1,
                ),
                encoding="utf-8",
            )
            legacy_schema = self.run_audit(tree, baseline)
            self.assertEqual(legacy_schema.returncode, 2)
            self.assertIn(
                "legacy struct rk_mpp_hw *hw member", legacy_schema.stderr
            )

            self.make_tree(tree)
            source.write_text(
                source.read_text(encoding="utf-8").replace(
                    "\tstruct rk_mpp_hw *selected_hw;\n",
                    "\tvoid *selected_hw;\n",
                ),
                encoding="utf-8",
            )
            selected_type_drift = self.run_audit(tree, baseline)
            self.assertEqual(selected_type_drift.returncode, 2)
            self.assertIn("selected_hw member", selected_type_drift.stderr)

            self.make_tree(tree)
            source.write_text(
                source.read_text(encoding="utf-8")
                + "struct rk_mpp_duplicate {\n"
                "\tstruct rk_mpp_hw *selected_hw;\n"
                "};\n",
                encoding="utf-8",
            )
            selected_duplicate = self.run_audit(tree, baseline)
            self.assertEqual(selected_duplicate.returncode, 2)
            self.assertIn("found 1 there and 2 overall", selected_duplicate.stderr)

            self.make_tree(tree)
            source.write_text(
                source.read_text(encoding="utf-8").replace(
                    "\tstruct rk_mpp_hw *rkvdec_ccu;\n",
                    "\tvoid *rkvdec_ccu;\n",
                ),
                encoding="utf-8",
            )
            ccu_type_drift = self.run_audit(tree, baseline)
            self.assertEqual(ccu_type_drift.returncode, 2)
            self.assertIn("rkvdec_ccu member", ccu_type_drift.stderr)

    def test_activation_claim_state_and_reason_are_hard_guarded(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            tree = root / "linux"
            baseline = root / "baseline.tsv"
            self.make_tree(tree)
            updated = self.run_audit(tree, baseline, "--update-baseline")
            self.assertEqual(updated.returncode, 0, updated.stderr)

            self.make_tree(
                tree,
                extra_mpp=(
                    "\tjob->current_activation->slot_state = "
                    "RK_MPP_ACTIVATION_CLAIMED;\n"
                    "\tWRITE_ONCE(job->current_activation->transition_reason, "
                    "RK_MPP_TRANSITION_IRQ);\n"
                    "\tmemset(job->current_activation->slot_state, 0, "
                    "sizeof(job->current_activation->slot_state));\n"
                    "\trk_mpp_hw_claim_active_locked(hw, job->current_activation, "
                    "1, RK_MPP_TRANSITION_IRQ);\n"
                    "\trk_mpp_hw_take_active_locked(hw);\n"
                ),
            )
            rejected = self.run_audit(tree, baseline)
            self.assertEqual(rejected.returncode, 2)
            for category in (
                "mpp-activation-slot-state-access",
                "mpp-activation-slot-state-write",
                "mpp-activation-transition-reason-access",
                "mpp-activation-transition-reason-write",
                "mpp-active-transition-entry",
                "mpp-slot-legacy-helper",
            ):
                self.assertIn(f"OWNER\t{category}", rejected.stderr)
            rebased = self.run_audit(tree, baseline, "--update-baseline")
            self.assertEqual(rebased.returncode, 2)

            source = tree / "drivers/video/rockchip/mpp-rewrite/mpp_rewrite.c"
            self.make_tree(tree)
            source.write_text(
                source.read_text(encoding="utf-8").replace(
                    "hw, NULL, 0, RK_MPP_TRANSITION_IRQ, token));",
                    "hw, NULL, 0, RK_MPP_TRANSITION_TIMEOUT, token));",
                ),
                encoding="utf-8",
            )
            wrong_reason = self.run_audit(tree, baseline)
            self.assertEqual(wrong_reason.returncode, 2)
            self.assertIn("OWNER\tmpp-active-transition-entry", wrong_reason.stderr)
            wrong_reason_rebased = self.run_audit(
                tree, baseline, "--update-baseline"
            )
            self.assertEqual(wrong_reason_rebased.returncode, 2)

            self.make_tree(tree)
            source.write_text(
                source.read_text(encoding="utf-8").replace(
                    "\tenum rk_mpp_activation_slot_state slot_state;\n",
                    "\tu8 slot_state;\n",
                ),
                encoding="utf-8",
            )
            member_drift = self.run_audit(tree, baseline)
            self.assertEqual(member_drift.returncode, 2)
            self.assertIn("slot_state member", member_drift.stderr)

            self.make_tree(tree)
            source.write_text(
                source.read_text(encoding="utf-8").replace(
                    "\tRK_MPP_ACTIVATION_SLOTTED,\n"
                    "\tRK_MPP_ACTIVATION_CLAIMED,\n",
                    "\tRK_MPP_ACTIVATION_CLAIMED,\n"
                    "\tRK_MPP_ACTIVATION_SLOTTED,\n",
                ),
                encoding="utf-8",
            )
            enum_drift = self.run_audit(tree, baseline)
            self.assertEqual(enum_drift.returncode, 2)
            self.assertIn("unexpected enum rk_mpp_activation_slot_state", enum_drift.stderr)

            self.make_tree(tree)
            source.write_text(
                source.read_text(encoding="utf-8").replace(
                    "reason == RK_MPP_TRANSITION_CCU_DONE ||\n"
                    "\t       reason == RK_MPP_TRANSITION_TIMEOUT",
                    "reason == RK_MPP_TRANSITION_TIMEOUT",
                ),
                encoding="utf-8",
            )
            priority_drift = self.run_audit(tree, baseline)
            self.assertEqual(priority_drift.returncode, 2)
            self.assertIn("fault-priority reasons must be exactly", priority_drift.stderr)

            self.make_tree(
                tree,
                extra_kunit=(
                    "\tjob->current_activation->slot_state = "
                    "RK_MPP_ACTIVATION_CLAIMED;\n"
                    "\tjob->current_activation->transition_reason = "
                    "RK_MPP_TRANSITION_IRQ;\n"
                ),
            )
            kunit_only = self.run_audit(tree, baseline)
            self.assertEqual(kunit_only.returncode, 0, kunit_only.stderr)

    def test_fresh_activation_storage_is_hard_guarded(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            tree = root / "linux"
            baseline = root / "baseline.tsv"
            self.make_tree(tree)
            updated = self.run_audit(tree, baseline, "--update-baseline")
            self.assertEqual(updated.returncode, 0, updated.stderr)
            source = tree / "drivers/video/rockchip/mpp-rewrite/mpp_rewrite.c"

            hostile_cases = (
                (
                    "hostile_current",
                    "\tif (job->current_activation) job = NULL;\n"
                    "\tWRITE_ONCE(job->current_activation, successor);\n"
                    "\txchg(&job->current_activation, successor);\n"
                    "\tmemset(&job->current_activation, 0, "
                    "sizeof(job->current_activation));\n",
                    "mpp-current-activation-write",
                ),
                (
                    "rk_mpp_job_get_hw",
                    "\tjob->current_activation = successor;\n",
                    "mpp-current-activation-write",
                ),
                (
                    "hostile_attempt_list",
                    "\tINIT_LIST_HEAD(&job->activations);\n"
                    "\tlist_move(&attempt->job_link, &job->activations);\n"
                    "\tattempt->job_link.next = &attempt->job_link;\n",
                    "mpp-activation-link-write",
                ),
                (
                    "hostile_attempt_alloc",
                    "\tattempt = kzalloc_obj(*attempt, GFP_KERNEL);\n"
                    "\tkfree(attempt);\n",
                    "mpp-activation-allocation",
                ),
                (
                    "hostile_storage",
                    "\tjob->activation_storage.generation = 9;\n"
                    "\tmemset(&job->activation_storage, 0, "
                    "sizeof(job->activation_storage));\n",
                    "mpp-activation-object-write",
                ),
            )
            for function, body, category in hostile_cases:
                self.make_tree(tree)
                source.write_text(
                    source.read_text(encoding="utf-8")
                    + f"static void {function}(struct rk_mpp_job *job,\n"
                    "\t\tstruct rk_mpp_activation *attempt,\n"
                    "\t\tstruct rk_mpp_activation *successor)\n"
                    "{\n"
                    f"{body}"
                    "}\n",
                    encoding="utf-8",
                )
                for option in ((), ("--update-baseline",)):
                    rejected = self.run_audit(tree, baseline, *option)
                    self.assertEqual(rejected.returncode, 2, rejected.stderr)
                    self.assertIn(f"OWNER\t{category}", rejected.stderr)

            schema_cases = (
                (
                    "\tstruct list_head job_link;\n",
                    "\tvoid *job_link;\n",
                    "job_link member",
                ),
                (
                    "\tstruct list_head activations;\n",
                    "\tvoid *activations;\n",
                    "activations member",
                ),
                (
                    "\tstruct rk_mpp_activation activation_storage;\n",
                    "\tvoid *activation_storage;\n",
                    "activation_storage member",
                ),
                (
                    "\tstruct rk_mpp_activation *current_activation;\n",
                    "\tvoid *current_activation;\n",
                    "current_activation member",
                ),
            )
            for original, replacement, expected in schema_cases:
                self.make_tree(tree)
                source.write_text(
                    source.read_text(encoding="utf-8").replace(
                        original, replacement
                    ),
                    encoding="utf-8",
                )
                rejected = self.run_audit(tree, baseline, "--update-baseline")
                self.assertEqual(rejected.returncode, 2, rejected.stderr)
                self.assertIn(expected, rejected.stderr)

            self.make_tree(tree)
            source.write_text(
                source.read_text(encoding="utf-8").replace(
                    "\tstruct rk_mpp_activation activation_storage;\n",
                    "\tstruct rk_mpp_activation activation;\n"
                    "\tstruct rk_mpp_activation activation_storage;\n",
                ),
                encoding="utf-8",
            )
            legacy = self.run_audit(tree, baseline, "--update-baseline")
            self.assertEqual(legacy.returncode, 2, legacy.stderr)
            self.assertIn("legacy activation member", legacy.stderr)

            self.make_tree(
                tree,
                extra_kunit=(
                    "\tjob->current_activation = successor;\n"
                    "\tlist_move(&job->current_activation->job_link, "
                    "&job->activations);\n"
                ),
            )
            kunit_only = self.run_audit(tree, baseline)
            self.assertEqual(kunit_only.returncode, 0, kunit_only.stderr)

    def test_activation_alias_spellings_cannot_be_rebaselined(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            tree = root / "linux"
            baseline = root / "baseline.tsv"
            self.make_tree(tree)
            updated = self.run_audit(tree, baseline, "--update-baseline")
            self.assertEqual(updated.returncode, 0, updated.stderr)
            source = tree / "drivers/video/rockchip/mpp-rewrite/mpp_rewrite.c"

            function_cases = (
                (
                    "rk_mpp_hw_install_active_locked",
                    "\thw->active_activation[0].generation = 9;\n",
                    "active_activation[0].generation",
                ),
                (
                    "rk_mpp_hw_install_active_locked",
                    "\t(*hw->active_activation).generation = 9;\n",
                    "(*hw->active_activation).generation",
                ),
                (
                    "rk_mpp_hw_install_active_locked",
                    "\t(*hw->active_activation) = replacement_activation;\n",
                    "(*hw->active_activation) =",
                ),
                (
                    "hostile_pointer_const",
                    "\tstruct rk_mpp_activation * const attempt = NULL;\n"
                    "\tattempt->generation = 9;\n",
                    "attempt->generation",
                ),
                (
                    "hostile_pointer_restrict",
                    "\tstruct rk_mpp_activation *restrict attempt = NULL;\n"
                    "\tattempt->generation = 9;\n",
                    "attempt->generation",
                ),
                (
                    "hostile_alias_array_memory",
                    "\tstruct rk_mpp_activation *attempt = NULL;\n"
                    "\tmemset(&attempt[0], 0, sizeof(attempt[0]));\n",
                    "memset(&attempt[0]",
                ),
                (
                    "hostile_alias_deref_memory",
                    "\tstruct rk_mpp_activation *attempt = NULL;\n"
                    "\tmemset(&*attempt, 0, sizeof(*attempt));\n",
                    "memset(&*attempt",
                ),
                (
                    "rk_mpp_hw_install_active_locked",
                    "\tmemset(&hw->active_activation[0], 0,\n"
                    "\t       sizeof(hw->active_activation[0]));\n",
                    "memset(&hw->active_activation[0]",
                ),
                (
                    "rk_mpp_job_get_hw",
                    "\tmemset(job->current_activation->selected_hw, 0,\n"
                    "\t       sizeof(job->current_activation->selected_hw));\n",
                    "memset(job->current_activation->selected_hw",
                ),
            )
            for function, body, needle in function_cases:
                self.make_tree(tree)
                source.write_text(
                    source.read_text(encoding="utf-8")
                    + f"static void {function}(struct rk_mpp_hw *hw, "
                    "struct rk_mpp_job *job)\n"
                    "{\n"
                    f"{body}"
                    "}\n",
                    encoding="utf-8",
                )
                for option in ((), ("--update-baseline",)):
                    rejected = self.run_audit(tree, baseline, *option)
                    self.assertEqual(rejected.returncode, 2, rejected.stderr)
                    self.assertIn(
                        "legacy split activation ownership field returned"
                        if "active_activation" in body
                        else needle,
                        rejected.stderr,
                    )

            self.make_tree(tree)
            text = source.read_text(encoding="utf-8")
            source.write_text(
                "typedef struct rk_mpp_activation activation_alias;\n"
                + text
                + "static void hostile_typedef(activation_alias *attempt)\n"
                "{\n"
                "\tattempt->generation = 9;\n"
                "}\n",
                encoding="utf-8",
            )
            for option in ((), ("--update-baseline",)):
                rejected = self.run_audit(tree, baseline, *option)
                self.assertEqual(rejected.returncode, 2, rejected.stderr)
                self.assertIn("attempt->generation", rejected.stderr)

            self.make_tree(tree)
            text = source.read_text(encoding="utf-8")
            source.write_text(
                "typedef struct rk_mpp_activation *activation_ptr;\n"
                + text
                + "static void hostile_pointer_typedef(activation_ptr attempt)\n"
                "{\n"
                "\tattempt->generation = 9;\n"
                "}\n",
                encoding="utf-8",
            )
            for option in ((), ("--update-baseline",)):
                rejected = self.run_audit(tree, baseline, *option)
                self.assertEqual(rejected.returncode, 2, rejected.stderr)
                self.assertIn("attempt->generation", rejected.stderr)

            self.make_tree(tree)
            source.write_text(
                source.read_text(encoding="utf-8")
                + "static void hostile_cast(void *opaque)\n"
                "{\n"
                "\t((struct rk_mpp_activation *)opaque)->generation = 9;\n"
                "}\n",
                encoding="utf-8",
            )
            for option in ((), ("--update-baseline",)):
                rejected = self.run_audit(tree, baseline, *option)
                self.assertEqual(rejected.returncode, 2, rejected.stderr)
                self.assertIn("opaque)->generation", rejected.stderr)

            for cast in (
                "((struct rk_mpp_activation *)get_opaque())->generation = 9;",
                "((struct rk_mpp_activation * const)opaque)->generation = 9;",
            ):
                self.make_tree(tree)
                source.write_text(
                    source.read_text(encoding="utf-8")
                    + "static void hostile_complex_cast(void *opaque)\n"
                    "{\n"
                    f"\t{cast}\n"
                    "}\n",
                    encoding="utf-8",
                )
                for option in ((), ("--update-baseline",)):
                    rejected = self.run_audit(tree, baseline, *option)
                    self.assertEqual(rejected.returncode, 2, rejected.stderr)
                    self.assertIn("generation = 9", rejected.stderr)

            for member in ("active_job", "timeout_job"):
                self.make_tree(tree)
                source.write_text(
                    source.read_text(encoding="utf-8").replace(
                        "\tstruct rk_mpp_activation_ref timeout_ref;\n",
                        "\tstruct rk_mpp_activation_ref timeout_ref;\n"
                        f"\tvoid *{member} __aligned(8);\n",
                        1,
                    ),
                    encoding="utf-8",
                )
                for option in ((), ("--update-baseline",)):
                    rejected = self.run_audit(tree, baseline, *option)
                    self.assertEqual(rejected.returncode, 2, rejected.stderr)
                    self.assertIn(f"legacy {member} member", rejected.stderr)

                self.make_tree(tree)
                source.write_text(
                    source.read_text(encoding="utf-8").replace(
                        "\tstruct rk_mpp_activation_ref timeout_ref;\n",
                        "\tstruct rk_mpp_activation_ref timeout_ref;\n"
                        f"\tvoid *{member}\n"
                        "\t\t__aligned(8);\n",
                        1,
                    ),
                    encoding="utf-8",
                )
                for option in ((), ("--update-baseline",)):
                    rejected = self.run_audit(tree, baseline, *option)
                    self.assertEqual(rejected.returncode, 2, rejected.stderr)
                    self.assertIn(f"legacy {member} member", rejected.stderr)

    def test_retry_retirement_proof_cannot_be_rebaselined(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            tree = root / "linux"
            baseline = root / "baseline.tsv"
            self.make_tree(tree)
            updated = self.run_audit(tree, baseline, "--update-baseline")
            self.assertEqual(updated.returncode, 0, updated.stderr)
            source = tree / "drivers/video/rockchip/mpp-rewrite/mpp_rewrite.c"
            pristine = source.read_text(encoding="utf-8")
            mutations = (
                (
                    "activation-ref schema drift",
                    "struct rk_mpp_activation_ref {\n"
                    "\tstruct rk_mpp_activation *activation;\n"
                    "\tu64 generation;\n"
                    "};",
                    "struct rk_mpp_activation_ref {\n"
                    "\tstruct rk_mpp_activation *activation;\n"
                    "\tu32 generation;\n"
                    "};",
                    "unexpected struct rk_mpp_activation_ref { definition",
                ),
                (
                    "activation refcount schema drift",
                    "\trefcount_t refs;\n",
                    "\tatomic_t refs;\n",
                    "refcount_t refs member",
                ),
                (
                    "retry-token schema drift",
                    "struct rk_mpp_activation_retry_token {\n"
                    "\tstruct rk_mpp_activation_ref ref;\n"
                    "};",
                    "struct rk_mpp_activation_retry_token {\n"
                    "\tstruct rk_mpp_activation *activation;\n"
                    "\tu64 generation;\n"
                    "};",
                    "unexpected struct rk_mpp_activation_retry_token { definition",
                ),
                (
                    "legacy split timeout generation",
                    "\tstruct rk_mpp_activation_ref timeout_ref;\n",
                    "\tstruct rk_mpp_activation_ref timeout_ref;\n"
                    "\tu64 timeout_generation;\n",
                    "forbidden legacy timeout_generation member",
                ),
                (
                    "reference get loses the refcount acquisition",
                    "if (!job || !refcount_inc_not_zero(&activation->refs))",
                    "if (!job || activation->refs.refs.counter)",
                    "exact activation reference contract drifted",
                ),
                (
                    "reference clone stops copying the generation pair",
                    "\t*dst = *src;\n"
                    "\treturn true;\n"
                    "}\n"
                    "static bool rk_mpp_activation_ref_move",
                    "\tdst->activation = src->activation;\n"
                    "\treturn true;\n"
                    "}\n"
                    "static bool rk_mpp_activation_ref_move",
                    "exact activation reference contract drifted",
                ),
                (
                    "reference move leaves a duplicate owner",
                    "\tmemset(src, 0, sizeof(*src));\n"
                    "\treturn true;\n"
                    "}\n"
                    "static bool rk_mpp_activation_ref_put",
                    "\treturn true;\n"
                    "}\n"
                    "static bool rk_mpp_activation_ref_put",
                    "exact activation reference contract drifted",
                ),
                (
                    "reference put stops releasing the paired job reference",
                    "\trk_mpp_job_put(job);\n"
                    "\treturn true;\n"
                    "}\n"
                    "static bool rk_mpp_activation_refs_released",
                    "\treturn true;\n"
                    "}\n"
                    "static bool rk_mpp_activation_refs_released",
                    "exact activation reference contract drifted",
                ),
                (
                    "active ownership is copied instead of moved",
                    "rk_mpp_activation_ref_move(&token->ref, &hw->active_ref)",
                    "rk_mpp_activation_ref_clone(&token->ref, &hw->active_ref)",
                    "unexpected rk_mpp_activation_ref_clone call map",
                ),
                (
                    "active-ref address escapes an allowed owner",
                    "\tstruct rk_mpp_activation_ref successor_ref = {};\n",
                    "\tstruct rk_mpp_activation_ref successor_ref = {};\n"
                    "\trk_mpp_hostile_sink(&hw->active_ref);\n",
                    "activation reference address escapes",
                ),
                (
                    "stack activation-ref address is retained",
                    "\tstruct rk_mpp_activation_ref successor_ref = {};\n",
                    "\tstruct rk_mpp_activation_ref successor_ref = {};\n"
                    "\tvoid *escaped = &successor_ref;\n",
                    "activation reference address escape is forbidden",
                ),
                (
                    "active-ref pair receives a raw whole write",
                    "\tif (!rk_mpp_activation_ref_move(&hw->active_ref, "
                    "&successor_ref)) {\n",
                    "\thw->active_ref = successor_ref;\n"
                    "\tif (!rk_mpp_activation_ref_move(&hw->active_ref, "
                    "&successor_ref)) {\n",
                    "whole activation reference write is forbidden",
                ),
                (
                    "retry token escapes an allowed owner",
                    "\tif (!rk_mpp_activation_ref_get(&successor_ref, successor))\n"
                    "\t\treturn false;\n"
                    "\tif (!rk_mpp_activation_ref_move(&token->ref, "
                    "&hw->active_ref))\n",
                    "\tif (!rk_mpp_activation_ref_get(&successor_ref, successor))\n"
                    "\t\treturn false;\n"
                    "\trk_mpp_hostile_sink(token);\n"
                    "\tif (!rk_mpp_activation_ref_move(&token->ref, "
                    "&hw->active_ref))\n",
                    "bare retry token escape",
                ),
                (
                    "retry success leaks the predecessor reference",
                    "WARN_ON_ONCE(!rk_mpp_activation_ref_put(&token->ref));",
                    "WARN_ON_ONCE(rk_mpp_activation_ref_valid(&token->ref));",
                    "unexpected rk_mpp_activation_ref_put call map",
                ),
                (
                    "retry failure skips quarantine",
                    "WARN_ON_ONCE(!rk_mpp_activation_retry_quarantine(hw, token,\n"
                    "\t\t\t\t\t\t status, core));",
                    "WARN_ON_ONCE(false);",
                    "rk_mpp_activation_retry_quarantine(hw, token, status, core)",
                ),
                (
                    "storage release ignores outstanding owners",
                    "\t\treturn rk_mpp_activation_refs_released(activation) &&\n"
                    "\t\t       !activation->selected_hw &&\n",
                    "\t\treturn true &&\n"
                    "\t\t       !activation->selected_hw &&\n",
                    "exact activation reference contract drifted",
                ),
            )
            for _description, original, replacement, expected in mutations:
                self.make_tree(tree)
                text = source.read_text(encoding="utf-8")
                self.assertIn(original, text)
                source.write_text(
                    text.replace(original, replacement, 1), encoding="utf-8"
                )
                for option in ((), ("--update-baseline",)):
                    rejected = self.run_audit(tree, baseline, *option)
                    self.assertEqual(rejected.returncode, 2, rejected.stderr)
                    self.assertIn(expected, rejected.stderr)

            self.make_tree(tree)
            source.write_text(
                pristine
                + "static void hostile_activation_ref_owner(\n"
                "\t\tstruct rk_mpp_activation_ref *ref)\n"
                "{\n"
                "\tref->generation = 0;\n"
                "\trk_mpp_hostile_sink(ref);\n"
                "}\n",
                encoding="utf-8",
            )
            for option in ((), ("--update-baseline",)):
                rejected = self.run_audit(tree, baseline, *option)
                self.assertEqual(rejected.returncode, 2, rejected.stderr)
                self.assertIn("unexpected activation reference owner set", rejected.stderr)

    def test_activation_schema_and_nested_writes_are_guarded(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            tree = root / "linux"
            baseline = root / "baseline.tsv"
            self.make_tree(tree)
            updated = self.run_audit(tree, baseline, "--update-baseline")
            self.assertEqual(updated.returncode, 0, updated.stderr)

            source = tree / "drivers/video/rockchip/mpp-rewrite/mpp_rewrite.c"
            source.write_text(
                source.read_text(encoding="utf-8").replace(
                    "\thw->activation_generation_seq++;\n",
                    "\thw->activation_generation_seq++;\n"
                    "\thw->activation_generation_seq ^= 1;\n",
                ),
                encoding="utf-8",
            )
            owner_delta = self.run_audit(tree, baseline)
            self.assertEqual(owner_delta.returncode, 1)
            self.assertIn("NEW\tmpp-activation-write", owner_delta.stderr)
            self.assertIn(
                "NEW\tmpp-activation-sequence-write", owner_delta.stderr
            )
            self.assertIn("activation_generation_seq ^= 1", owner_delta.stderr)

            self.make_tree(
                tree,
                extra_mpp=(
                    "\tjobs[0]->current_activation->watchdog_deadline = 1;\n"
                    "\txchg(&jobs[0]->current_activation->generation, 2);\n"
                    "\tWRITE_ONCE((*job).current_activation->"
                    "watchdog_deadline_valid, true);\n"
                    "\thws[0]->activation_generation_seq++;\n"
                    "\tmemset(job->current_activation, 0, "
                    "sizeof(job->activation_storage));\n"
                    "\tjob->activation_storage = replacement_activation;\n"
                    "\tactivation->generation = 3;\n"
                    "\tactivation->watchdog_deadline_valid = false;\n"
                    "\t(*activation).generation = 4;\n"
                    "\tWRITE_ONCE((*activation).watchdog_deadline_valid, "
                    "false);\n"
                    "\tactivation[0].job = job;\n"
                    "\tmemset(activation, 0, sizeof(*activation));\n"
                    "\t(*activation) = replacement_activation;\n"
                ),
            )
            rejected = self.run_audit(tree, baseline)
            self.assertEqual(rejected.returncode, 2)
            self.assertIn("OWNER\tmpp-activation-generation-write", rejected.stderr)
            self.assertIn("OWNER\tmpp-activation-deadline-write", rejected.stderr)
            self.assertIn("OWNER\tmpp-activation-object-write", rejected.stderr)
            self.assertIn("OWNER\tmpp-activation-parent-write", rejected.stderr)
            self.assertIn("watchdog_deadline = 1", rejected.stderr)
            self.assertIn(
                "xchg(&jobs[0]->current_activation->generation",
                rejected.stderr,
            )
            self.assertIn("watchdog_deadline_valid", rejected.stderr)
            self.assertIn("activation_generation_seq++", rejected.stderr)
            self.assertIn("memset(job->current_activation", rejected.stderr)
            self.assertIn(
                "job->activation_storage = replacement_activation",
                rejected.stderr,
            )
            self.assertIn("activation->generation = 3", rejected.stderr)
            self.assertIn("(*activation).generation = 4", rejected.stderr)
            self.assertIn("activation[0].job = job", rejected.stderr)
            self.assertIn("memset(activation", rejected.stderr)
            self.assertIn("(*activation) = replacement_activation", rejected.stderr)

            rebased = self.run_audit(tree, baseline, "--update-baseline")
            self.assertEqual(rebased.returncode, 2)
            self.assertIn("used outside its allowed owners", rebased.stderr)

            self.make_tree(tree)
            source.write_text(
                source.read_text(encoding="utf-8")
                + "static void rk_mpp_hw_schedule_timeout("
                "struct rk_mpp_job *job)\n"
                "{\n"
                "\tjob->current_activation->generation = 3;\n"
                "}\n",
                encoding="utf-8",
            )
            wrong_owner = self.run_audit(tree, baseline)
            self.assertEqual(wrong_owner.returncode, 2)
            self.assertIn(
                "OWNER\tmpp-activation-generation-write", wrong_owner.stderr
            )
            self.assertIn("rk_mpp_hw_schedule_timeout", wrong_owner.stderr)
            self.assertIn(
                "current_activation->generation = 3", wrong_owner.stderr
            )

            self.make_tree(tree)
            source.write_text(
                source.read_text(encoding="utf-8")
                + "static void hostile_alias(\n"
                "\t\tstruct rk_mpp_activation *attempt)\n"
                "{\n"
                "\tattempt->generation = 9;\n"
                "\tWRITE_ONCE(attempt->watchdog_deadline_valid, false);\n"
                "\tmemset(&attempt->selected_hw, 0,\n"
                "\t       sizeof(attempt->selected_hw));\n"
                "\tmemset(attempt, 0, sizeof(*attempt));\n"
                "}\n"
                "static void rk_mpp_job_get_hw(struct rk_mpp_job *job)\n"
                "{\n"
                "\tmemcpy(job->current_activation->selected_hw, &replacement,\n"
                "\t       sizeof(job->current_activation->selected_hw));\n"
                "}\n",
                encoding="utf-8",
            )
            alias_and_pointee = self.run_audit(tree, baseline)
            self.assertEqual(alias_and_pointee.returncode, 2)
            for category in (
                "mpp-activation-generation-write",
                "mpp-activation-deadline-write",
                "mpp-activation-object-write",
                "mpp-selected-hw-write",
            ):
                self.assertIn(f"OWNER\t{category}", alias_and_pointee.stderr)
            self.assertIn("attempt->generation = 9", alias_and_pointee.stderr)
            self.assertEqual(
                self.run_audit(tree, baseline, "--update-baseline").returncode,
                2,
            )

            for original, replacement, description in (
                (
                    "\tstruct rk_mpp_job *job;\n",
                    "\tvoid *job;\n",
                    "struct rk_mpp_job *job member",
                ),
                (
                    "\tenum rk_mpp_activation_transition_reason "
                    "transition_reason;\n"
                    "\tu64 generation;\n",
                    "\tenum rk_mpp_activation_transition_reason "
                    "transition_reason;\n"
                    "\tu32 generation;\n",
                    "u64 generation member",
                ),
                (
                    "\tunsigned long watchdog_deadline;\n",
                    "\tu64 watchdog_deadline;\n",
                    "unsigned long watchdog_deadline member",
                ),
                (
                    "\tbool watchdog_deadline_valid;\n",
                    "\tu8 watchdog_deadline_valid;\n",
                    "bool watchdog_deadline_valid member",
                ),
            ):
                self.make_tree(tree)
                source.write_text(
                    source.read_text(encoding="utf-8").replace(
                        original, replacement, 1
                    ),
                    encoding="utf-8",
                )
                schema_changed = self.run_audit(tree, baseline)
                self.assertEqual(schema_changed.returncode, 2)
                self.assertIn(description, schema_changed.stderr)

    def test_phase3h_claim_and_quarantine_contracts_are_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            tree = root / "linux"
            baseline = root / "baseline.tsv"
            self.make_tree(tree)
            updated = self.run_audit(tree, baseline, "--update-baseline")
            self.assertEqual(updated.returncode, 0, updated.stderr)

            source = tree / "drivers/video/rockchip/mpp-rewrite/mpp_rewrite.c"
            pristine = source.read_text(encoding="utf-8")
            cases = (
                (
                    "claim schema drift",
                    pristine.replace(
                        "\tstruct rk_mpp_activation_ref ref;\n"
                        "\tenum rk_mpp_activation_transition_reason reason;\n",
                        "\tvoid *ref;\n"
                        "\tenum rk_mpp_activation_transition_reason reason;\n",
                        1,
                    ),
                    "unexpected struct rk_mpp_activation_claim_token { definition",
                ),
                (
                    "hostile claim-token read, write, and escape",
                    pristine
                    + "static void hostile_claim_token_owner(\n"
                    "\t\tstruct rk_mpp_activation_claim_token *token)\n"
                    "{\n"
                    "\tif (token->ref.generation)\n"
                    "\t\ttoken->reason = RK_MPP_TRANSITION_REMOVE;\n"
                    "\trk_mpp_hostile_sink(token);\n"
                    "}\n",
                    "unexpected claim token owner set",
                ),
                (
                    "whole claim-token memset",
                    pristine.replace(
                        "\ttoken->reason = reason;\n"
                        "\treturn activation;",
                        "\ttoken->reason = reason;\n"
                        "\tmemset(token, 0, sizeof(*token));\n"
                        "\treturn activation;",
                        1,
                    ),
                    "claim token escapes to ['memset']",
                ),
                (
                    "allowed-owner claim-token escape",
                    pristine.replace(
                        "\ttoken->reason = reason;\n"
                        "\treturn activation;",
                        "\ttoken->reason = reason;\n"
                        "\trk_mpp_hostile_sink(token);\n"
                        "\treturn activation;",
                        1,
                    ),
                    None,
                ),
                (
                    "weakened retired proof",
                    pristine.replace(
                        "!activation->closure.terminal.status &&",
                        "true &&",
                        1,
                    ),
                    "activation storage release predicates drifted",
                ),
                (
                    "weakened quarantine total sink",
                    pristine.replace(
                        "error = quarantine_error ?: core_status ?: "
                        "group_status ?: -EUCLEAN;",
                        "error = quarantine_error ?: core_status ?: "
                        "group_status ?: 0;",
                        1,
                    ),
                    "error = quarantine_error ?: core_status ?: "
                    "group_status ?: -EUCLEAN",
                ),
                (
                    "removed remove and shutdown quarantine gates",
                    pristine.replace(
                        "rk_mpp_service_has_quarantined_activation(hw->srv)",
                        "false",
                    ),
                    "unexpected rk_mpp_service_has_quarantined_activation "
                    "call map",
                ),
            )

            for description, mutated, expected_error in cases:
                with self.subTest(description=description):
                    source.write_text(mutated, encoding="utf-8")
                    for options in ((), ("--update-baseline",)):
                        rejected = self.run_audit(tree, baseline, *options)
                        self.assertEqual(
                            rejected.returncode,
                            2,
                            f"{description} {options}: {rejected.stderr}",
                        )
                        if expected_error:
                            self.assertIn(expected_error, rejected.stderr)

    def test_phase3i_observation_contracts_are_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            tree = root / "linux"
            baseline = root / "baseline.tsv"
            self.make_tree(tree)
            updated = self.run_audit(tree, baseline, "--update-baseline")
            self.assertEqual(updated.returncode, 0, updated.stderr)

            source = tree / "drivers/video/rockchip/mpp-rewrite/mpp_rewrite.c"
            pristine = source.read_text(encoding="utf-8")
            cases = (
                (
                    "observation schema drift",
                    pristine.replace("\tu32 hw_status;\n", "\tu64 hw_status;\n", 1),
                    "unexpected struct rk_mpp_activation_observation_record",
                ),
                (
                    "observation pointer typedef escape",
                    pristine
                    + "typedef struct rk_mpp_activation_observation_record "
                    "*hostile_observation_ptr;\n",
                    "observation record pointer, typedef, or inferred aliases",
                ),
                (
                    "observation address and whole-memory escape",
                    pristine.replace(
                        "\tactivation->closure.observation.kind = observation;\n",
                        "\tmemset(&activation->closure.observation, 0,\n"
                        "\t       sizeof(activation->closure.observation));\n"
                        "\tactivation->closure.observation.kind = observation;\n",
                        1,
                    ),
                    "observation record address, memory, or result escape",
                ),
                (
                    "weakened observation range",
                    pristine.replace(
                        "\t    observation >= RK_MPP_ACTIVATION_OBSERVATION_COUNT)\n",
                        "\t    false)\n",
                        1,
                    ),
                    "clean-terminal observation contract drifted",
                ),
                (
                    "weakened observation validity proof",
                    pristine.replace(
                        "\tif (!activation->closure.observation.valid)\n"
                        "\t\treturn false;\n",
                        "\tif (false)\n\t\treturn false;\n",
                        1,
                    ),
                    "clean-terminal observation contract drifted",
                ),
                (
                    "valid published before observation payload",
                    pristine.replace(
                        "\tactivation->closure.observation.kind = observation;\n"
                        "\tactivation->closure.observation.hw_status = hw_status;\n"
                        "\tactivation->closure.observation.bus_idle_status = "
                        "bus_idle_status;\n"
                        "\tactivation->closure.observation.bus_idle_checked = "
                        "bus_idle_checked;\n"
                        "\tactivation->closure.observation.valid = true;\n",
                        "\tactivation->closure.observation.valid = true;\n"
                        "\tactivation->closure.observation.kind = observation;\n"
                        "\tactivation->closure.observation.hw_status = hw_status;\n"
                        "\tactivation->closure.observation.bus_idle_status = "
                        "bus_idle_status;\n"
                        "\tactivation->closure.observation.bus_idle_checked = "
                        "bus_idle_checked;\n",
                        1,
                    ),
                    "clean-terminal observation contract drifted",
                ),
                (
                    "observation and recovery proofs no longer exclusive",
                    pristine.replace(
                        "\t\t       !activation->closure.group.valid &&\n",
                        "\t\t       true &&\n",
                        1,
                    ),
                    "activation storage release predicates drifted",
                ),
                (
                    "CCU clean mask weakened",
                    pristine.replace(
                        "\tccu_error = !!(completed_status & link_info->err_mask);\n",
                        "\tccu_error = false;\n",
                        1,
                    ),
                    "expected 1 occurrence(s) of: ccu_error",
                ),
                (
                    "BUS_IDLE result no longer observed",
                    pristine.replace(
                        "\tbus_idle_status = rk_mpp_rkvdec2_wait_bus_idle(hw, "
                        "&bus_idle_checked);\n",
                        "\tbus_idle_status = 0;\n",
                        1,
                    ),
                    "unexpected rk_mpp_rkvdec2_wait_bus_idle call map",
                ),
                (
                    "finish refusal no longer quarantines",
                    pristine.replace(
                        "\tif (WARN_ON_ONCE(!finished)) {\n"
                        "\t\tquarantined = rk_mpp_activation_claim_quarantine(\n"
                        "\t\t\thw, ccu, &claim, -EUCLEAN, 0, NULL, 0, NULL);\n",
                        "\tif (WARN_ON_ONCE(!finished)) {\n"
                        "\t\tquarantined = false;\n",
                        1,
                    ),
                    "observed-terminal refusal sink drifted",
                ),
                (
                    "AV1 failed stop clears retained SLOTTED owner",
                    pristine.replace(
                        "\t\t\tmutex_unlock(&hw->run_lock);\n"
                        "\t\t\trk_mpp_hw_put(hw);\n"
                        "\t\t\treturn 0;\n",
                        "\t\t\tmutex_unlock(&hw->run_lock);\n"
                        "\t\t\trk_mpp_hw_clear_active_job(hw, job,\n"
                        "\t\t\t\tRK_MPP_TRANSITION_START_FAILURE, NULL, "
                        "&claim);\n"
                        "\t\t\trk_mpp_hw_put(hw);\n"
                        "\t\t\treturn 0;\n",
                        1,
                    ),
                    "AV1 failed-stop must retain the active SLOTTED owner",
                ),
            )

            for description, mutated, expected_error in cases:
                with self.subTest(description=description):
                    self.assertNotEqual(mutated, pristine, description)
                    source.write_text(mutated, encoding="utf-8")
                    for options in ((), ("--update-baseline",)):
                        rejected = self.run_audit(tree, baseline, *options)
                        self.assertEqual(
                            rejected.returncode,
                            2,
                            f"{description} {options}: {rejected.stderr}",
                        )
                        self.assertIn(expected_error, rejected.stderr)

    def test_whole_category_disappearance_fails_until_rebaselined(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            tree = root / "linux"
            baseline = root / "baseline.tsv"
            self.make_tree(tree)
            updated = self.run_audit(tree, baseline, "--update-baseline")
            self.assertEqual(updated.returncode, 0, updated.stderr)

            source = tree / "drivers/video/rockchip/mpp-rewrite/mpp_rewrite.c"
            source.write_text(
                source.read_text(encoding="utf-8").replace(
                    "\treset_control_assert(hw->resets);\n", ""
                ),
                encoding="utf-8",
            )
            missing = self.run_audit(tree, baseline)
            self.assertEqual(missing.returncode, 1)
            self.assertIn(
                "baseline categories disappeared: mpp-reset-control",
                missing.stderr,
            )


if __name__ == "__main__":
    unittest.main()
