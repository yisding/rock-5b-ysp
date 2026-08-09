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

        self.assertEqual(numbers, list(range(1, 97)))
        readme = (self.series / "README.md").read_text(encoding="utf-8")
        self.assertIn("contiguous `0001`–`0096`", readme)
        self.assertIn("7698e7018e3d5", readme)

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

    def test_standard_set_is_shared_by_bsp_and_rewrite(self) -> None:
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
            "abi",
            "mpp",
            "librga",
            "gstreamer",
            "ffmpeg",
        ):
            self.assertEqual(bsp_rows[test_id], "selected")
            self.assertEqual(rewrite_rows[test_id], "selected")
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
        mpp.write_text(
            "enum rk_mpp_debug_event_type { RK_MPP_DEBUG_DONE };\n"
            "struct rk_mpp_debug_event { u8 type; };\n"
            "static void mpp_paths(struct rk_mpp_hw *hw, struct rk_mpp_job *job)\n"
            "{\n"
            "\treset_control_assert(hw->resets);\n"
            "\thw->active_job = job;\n"
            "\tjob->rkvdec_session_dispatch = true;\n"
            "\tjob->rkvdec_ccu_powered_cores[0] = hw;\n"
            "\tjob->rkvdec_ccu_powered_core_count = 1;\n"
            "\tjob->rkvdec_ccu_powered = true;\n"
            "\trk_mpp_hw_power_on(hw);\n"
            "\tpm_runtime_resume_and_get(hw->dev);\n"
            "\tatomic_inc(&hw->power_count);\n"
            "\tatomic_read(&hw->power_count);\n"
            "\tatomic_cond_read_relaxed(&hw->power_count, true);\n"
            "\trk_mpp_hw_schedule_timeout(hw);\n"
            "\trk_mpp_hw_refresh_iommu(hw, job);\n"
            "\tvsi_iommu_refresh(hw->dev);\n"
            "\tjob->result = -EINPROGRESS;\n"
            "\thw->irq_status = 1;\n"
            "\thw->iommu_fault_pending = true;\n"
            "\thw->recovery_failed = true;\n"
            "\thw->timeout_job = job;\n"
            "\tjob->hw_start_ns = 1;\n"
            "\trk_mpp_job_publish_outcome(job, 0);\n"
            "\trk_mpp_job_complete(job, 0);\n"
            "\twritel(1, hw->regs[0] + RK_MPP_RKVENC_START_BASE);\n"
            "\twritel(job->rkvdec_ccu_cfg_done, "
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
            "\tjob->hw_elapsed_ns += 99;\n"
            "\trk_mpp_job_publish_outcome_locked(job, -EIO);\n"
            f"{extra_kunit}"
            "}\n"
            "#endif\n",
            encoding="utf-8",
        )
        rga.write_text(
            "enum rk_rga_debug_event_type { RK_RGA_DEBUG_JOB_FAIL };\n"
            "struct rk_rga_debug_event { u8 type; };\n"
            "static void rga_map_owner(struct rk_rga_job *job)\n"
            "{\n"
            "\tdma_buf_detach(NULL, NULL);\n"
            "\t__rk_rga_job_release_execution_mappings(job);\n"
            "}\n"
            "static void rk_rga2_emit_src(struct rk_rga_job *job,\n"
            "\t\t\t     const struct rga_req *task)\n"
            "{\n"
            "\trk_rga_cmd_write(job, RK_RGA2_SRC_INFO_OFFSET, task->render_mode);\n"
            "}\n"
            "static void rga_paths(struct rk_rga_hw *hw, struct rk_rga_job *job)\n"
            "{\n"
            "\thw->active_job = job;\n"
            "\tjob->current_task++;\n"
            "\trk_rga_job_release_execution_mappings_powered(job, hw);\n"
            "\trk_rga_job_free_cmd(job);\n"
            "\tjob->irq_result = 0;\n"
            "\thw->iommu_fault_generation = 1;\n"
            "\thw->recovery_failed = true;\n"
            "\thw->timeout_job = job;\n"
            "\trk_rga_hw_schedule_timeout(hw, job);\n"
            "\tjob->hw_start_ns = 1;\n"
            "\tWRITE_ONCE(job->result, 0);\n"
            "\tWRITE_ONCE(event.result, 0);\n"
            "\trk_rga_hw_recover_active(hw, false, NULL, 0);\n"
            "\trk_rga_write(hw, 1, RK_RGA3_CMD_CTRL);\n"
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

    def test_inventory_is_source_bound_and_catches_new_reset_writer(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            tree = root / "linux"
            baseline = root / "baseline.tsv"
            self.make_tree(tree)
            updated = self.run_audit(tree, baseline, "--update-baseline")
            self.assertEqual(updated.returncode, 0, updated.stderr)
            baseline_text = baseline.read_text(encoding="utf-8")
            self.assertIn("mpp-active-slot-access", baseline_text)
            self.assertIn("mpp-dispatch-lease-access", baseline_text)
            self.assertIn("rga-active-slot-access", baseline_text)
            self.assertIn("rga-raw-task-emitter", baseline_text)
            self.assertIn("rga-exec-map-owner", baseline_text)
            self.assertIn("rga-map-release-primitive", baseline_text)
            self.assertIn("rga-command-release", baseline_text)
            self.assertIn(
                "__rk_rga_job_release_execution_mappings", baseline_text
            )
            self.assertNotIn("rga_fixture", baseline_text)
            self.assertIn("rkvdec_ccu_powered_core_count", baseline_text)
            self.assertIn("rkvdec_ccu_powered = true", baseline_text)
            self.assertIn("mpp-power-transition-entry", baseline_text)
            self.assertIn("mpp-power-backend-op", baseline_text)
            self.assertIn("mpp-power-count-write", baseline_text)
            self.assertNotIn("atomic_read(&hw->power_count)", baseline_text)
            self.assertNotIn("atomic_cond_read_relaxed", baseline_text)
            self.assertIn("mpp-watchdog-arm-entry", baseline_text)
            self.assertIn("rga-watchdog-arm-entry", baseline_text)
            self.assertIn("mpp-irq-ack-write", baseline_text)
            self.assertIn("mpp-irq-snapshot-write", baseline_text)
            self.assertIn("mpp-fault-snapshot-write", baseline_text)
            self.assertIn("mpp-terminal-state-write", baseline_text)
            self.assertIn("mpp-watchdog-snapshot-write", baseline_text)
            self.assertIn("mpp-outcome-publish-entry", baseline_text)
            self.assertIn("mpp-activation-timing-write", baseline_text)
            self.assertIn("rga-irq-snapshot-write", baseline_text)
            self.assertIn("rga-fault-snapshot-write", baseline_text)
            self.assertIn("rga-terminal-state-write", baseline_text)
            self.assertIn("rga-job-outcome-write", baseline_text)
            self.assertNotIn("WRITE_ONCE(event.result, 0)", baseline_text)
            self.assertIn("rga-watchdog-snapshot-write", baseline_text)
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
                    "\tjob = hw->active_job;\n"
                    "\thw[0].active_job = job;\n"
                    "\tcmpxchg(&hws[0]->active_job, job, NULL);\n"
                    "\thws[0]->active_generation <<= 1;\n"
                    "\t++(*hw).active_generation;\n"
                    "\tif (job->rkvdec_session_dispatch) job = NULL;\n"
                    "\t(*job).rkvdec_dispatch_active ^= true;\n"
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
                    "\thws[0]->timeout_generation = 2;\n"
                    "\t(*job).hw_elapsed_ns += 2;\n"
                    "\trk_mpp_job_publish_outcome_locked(job, -EIO);\n"
                    "\treset_control_bulk_reset(1, NULL);\n"
                    "\treset_control_rearm(hw->resets);\n"
                ),
                extra_kunit=(
                    "\treset_control_deassert(NULL);\n"
                    "\tfake.active_job = NULL;\n"
                    "\tjob->rkvdec_session_dispatch = false;\n"
                    "\tfake.rkvdec_ccu_powered = false;\n"
                    "\tiommu_flush_iotlb_all(NULL);\n"
                    "\tfake.result = 0;\n"
                    "\thw->irq_status = 88;\n"
                    "\thw->iommu_fault_pending = false;\n"
                    "\thw->terminal_power_drained = true;\n"
                    "\tfake.online = true;\n"
                    "\thw->timeout_deadline_generation = 88;\n"
                    "\tjob->hw_start_ns = 88;\n"
                    "\trk_mpp_job_publish_outcome(job, -ECANCELED);\n"
                ),
                extra_rga=(
                    "\tdma_buf_unmap_attachment(NULL, NULL, 0);\n"
                    "\trk_rga_job_discard_execution_mappings(job);\n"
                    "\tdma_free_coherent(job->cmd_dev, job->cmd_size,\n"
                    "\t\t\t  job->cmd_vaddr, job->cmd_dma);\n"
                    "\tjobs[0]->irq_seen = true;\n"
                    "\thw[0].iommu_fault_generation = 2;\n"
                    "\t(*hw).removing = true;\n"
                    "\thws[0]->timeout_generation = 2;\n"
                    "\txchg(&hws[0]->timeout_generation, 3);\n"
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
            self.assertIn("NEW\tmpp-active-slot-access", changed.stderr)
            self.assertIn("NEW\tmpp-active-slot-write", changed.stderr)
            self.assertIn("NEW\tmpp-dispatch-lease-access", changed.stderr)
            self.assertIn("NEW\tmpp-power-field", changed.stderr)
            self.assertIn("NEW\tmpp-power-transition-entry", changed.stderr)
            self.assertIn("NEW\tmpp-power-backend-op", changed.stderr)
            self.assertIn("NEW\tmpp-power-count-write", changed.stderr)
            self.assertIn("NEW\tmpp-watchdog-arm-entry", changed.stderr)
            self.assertIn("NEW\tmpp-iommu-backend-op", changed.stderr)
            self.assertIn("NEW\tmpp-job-lifecycle-write", changed.stderr)
            self.assertIn("NEW\tmpp-irq-snapshot-write", changed.stderr)
            self.assertIn("NEW\tmpp-fault-snapshot-write", changed.stderr)
            self.assertIn("NEW\tmpp-terminal-state-write", changed.stderr)
            self.assertIn("NEW\tmpp-watchdog-snapshot-write", changed.stderr)
            self.assertIn("NEW\tmpp-outcome-publish-entry", changed.stderr)
            self.assertIn("NEW\tmpp-activation-timing-write", changed.stderr)
            self.assertIn("NEW\tmpp-reset-control", changed.stderr)
            self.assertIn("NEW\trga-exec-map-owner", changed.stderr)
            self.assertIn("NEW\trga-map-release-primitive", changed.stderr)
            self.assertIn("NEW\trga-command-release", changed.stderr)
            self.assertIn("NEW\trga-irq-snapshot-write", changed.stderr)
            self.assertIn("NEW\trga-fault-snapshot-write", changed.stderr)
            self.assertIn("NEW\trga-terminal-state-write", changed.stderr)
            self.assertIn("NEW\trga-job-outcome-write", changed.stderr)
            self.assertIn("NEW\trga-watchdog-snapshot-write", changed.stderr)
            self.assertIn("NEW\trga-watchdog-arm-entry", changed.stderr)
            self.assertIn("NEW\trga-activation-timing-write", changed.stderr)
            self.assertIn("NEW\trga-terminal-entry", changed.stderr)
            self.assertIn("reset_control_bulk_reset", changed.stderr)
            self.assertIn("reset_control_rearm", changed.stderr)
            new_lines = changed.stderr.splitlines()
            for category, signal in (
                ("mpp-active-slot-write", "cmpxchg(&hws[0]->active_job"),
                ("mpp-active-slot-write", "active_generation <<= 1"),
                ("mpp-active-slot-write", "++(*hw).active_generation"),
                (
                    "mpp-dispatch-lease-write",
                    "rkvdec_dispatch_active ^= true",
                ),
                ("mpp-power-count-write", "atomic_xchg(&hws[0]->power_count"),
                ("mpp-power-count-write", "atomic_add(1, &hws[0]->power_count"),
                ("mpp-power-backend-op", "clk_bulk_enable(1, hw->clks)"),
                ("mpp-power-backend-op", "pm_runtime_get_sync(hw->dev)"),
                ("mpp-power-backend-op", "pm_runtime_force_suspend(hw->dev)"),
                ("mpp-power-backend-op", "devm_clk_bulk_get_all(hw->dev"),
                ("mpp-job-lifecycle-write", "try_cmpxchg(&jobs[0]->result"),
                (
                    "rga-watchdog-snapshot-write",
                    "xchg(&hws[0]->timeout_generation",
                ),
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
            self.assertNotIn("rkvdec_session_dispatch = false", changed.stderr)
            self.assertNotIn("fake.rkvdec_ccu_powered", changed.stderr)
            self.assertNotIn("fake.online", changed.stderr)
            self.assertNotIn("iommu_flush_iotlb_all", changed.stderr)
            self.assertNotIn("fake.result", changed.stderr)
            self.assertNotIn("irq_status = 88", changed.stderr)
            self.assertNotIn("timeout_deadline_generation = 88", changed.stderr)
            self.assertNotIn("hw_start_ns = 88", changed.stderr)
            self.assertNotIn("job, -ECANCELED", changed.stderr)
            self.assertNotIn("iommu_fault_generation = 99", changed.stderr)
            self.assertNotIn("NULL, NULL, true", changed.stderr)
            self.assertEqual(
                changed.stderr.count("dma_buf_unmap_attachment(NULL"), 1
            )
            self.assertEqual(changed.stderr.count("job->cmd_vaddr"), 1)

            baseline.write_text(
                baseline_text.replace("# source-head\tunknown", "# source-head\tdeadbeef"),
                encoding="utf-8",
            )
            wrong_head = self.run_audit(tree, baseline)
            self.assertEqual(wrong_head.returncode, 1)
            self.assertIn("source HEAD unknown is not pinned", wrong_head.stderr)

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
