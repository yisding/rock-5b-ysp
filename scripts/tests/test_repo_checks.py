from __future__ import annotations

import importlib.util
import os
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

        self.assertEqual(numbers, list(range(1, 74)))
        readme = (self.series / "README.md").read_text(encoding="utf-8")
        self.assertIn("contiguous `0001`–`0073`", readme)
        self.assertIn("79fc616390e5", readme)

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
                "ffmpeg (7:8.0.3+new-0ubuntu1) resolute; urgency=medium\n",
                encoding="utf-8",
            )
            installer = root / "packaging/ppa/clean-install-system-stack.sh"
            installer.parent.mkdir(parents=True, exist_ok=True)
            installer.write_text(
                '#!/usr/bin/env bash\nFFMPEG_VERSION="7:8.0.3+old-0ubuntu1"\n',
                encoding="utf-8",
            )
            errors: list[str] = []

            DOC_CHECKER.check_ppa_ffmpeg_install_pin(root, errors)

            self.assertEqual(len(errors), 1)
            self.assertIn("does not match latest changelog", errors[0])

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
            errors: list[str] = []

            DOC_CHECKER.check_ppa_grd_source_pin(root, errors)

            self.assertEqual(len(errors), 1)
            self.assertIn("default GRD commit", errors[0])
            self.assertIn("does not match latest changelog", errors[0])


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

    def test_findings_index_reports_orphan_and_dangling_only(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            findings = root / "findings"
            findings.mkdir()
            (findings / "2026-01-01-linked.md").write_text("# Linked\n", encoding="utf-8")
            (findings / "2026-01-02-orphan.md").write_text("# Orphan\n", encoding="utf-8")
            (findings / "README.md").write_text(
                "## Index\n\n"
                "- `` `2026-01-02-orphan-typo.md` `` — dangling link.\n"
                "- `` `2026-01-01-linked.md` `` — present.\n",
                encoding="utf-8",
            )
            errors: list[str] = []

            DOC_CHECKER.check_findings_index(root, errors)

            self.assertTrue(
                any("2026-01-02-orphan.md is not linked" in e for e in errors)
            )
            self.assertTrue(
                any("2026-01-02-orphan-typo.md but no such file" in e for e in errors)
            )
            # Ordering is intentionally not enforced: the linked pair is silent.
            self.assertFalse(any("newest first" in e for e in errors))

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
                "- **State then:** ok\n\n"
                "### W03 — Orphan detail\n\n"
                "- **State then:** ok\n",
                encoding="utf-8",
            )
            errors: list[str] = []

            DOC_CHECKER.check_watchlist_pairing(root, errors)

            self.assertTrue(any("W02: index row has no detail" in e for e in errors))
            self.assertTrue(any("W03: detail block has no index" in e for e in errors))
            # The correctly paired W01 (and any date/name skew) is not flagged.
            self.assertFalse(any("W01" in e for e in errors))


if __name__ == "__main__":
    unittest.main()
