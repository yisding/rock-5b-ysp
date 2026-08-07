#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: GPL-2.0-only
"""Prune old Armbian kernel artifacts as complete, recoverable build groups."""

from __future__ import annotations

import argparse
import io
import os
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import time
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path


PRIMARY_DEB_RE = re.compile(
    r"^linux-(?P<kind>image|dtb|headers|libc-dev)-(?P<slot>[^_]+)_"
    r"[^_]+_[^_]+__(?P<build>.+)\.deb$"
)
HASHED_DEB_RE = re.compile(
    r"^linux-(?P<kind>image|dtb|headers|libc-dev)-(?P<slot>[^_]+)_"
    r"(?P<build>[0-9].+)_arm64\.deb$"
)
HASHED_TAR_RE = re.compile(
    r"^kernel-(?P<family>rockchip64|rockchip-rk3588)-(?P<branch>[^_]+)_"
    r"(?P<build>[0-9].+)_arm64\.tar$"
)


@dataclass(frozen=True)
class Artifact:
    path: Path
    slot: str
    build: str
    kind: str
    size: int
    mtime_ns: int
    device: int
    inode: int


@dataclass
class BuildGroup:
    slot: str
    build: str
    artifacts: list[Artifact]

    @property
    def newest_mtime_ns(self) -> int:
        return max(artifact.mtime_ns for artifact in self.artifacts)

    @property
    def size(self) -> int:
        return sum(artifact.size for artifact in self.artifacts)

    @property
    def recoverable(self) -> bool:
        return any(
            artifact.kind in {"image", "tar-image"} for artifact in self.artifacts
        )


def default_armbian_build() -> Path:
    repo_root = Path(__file__).resolve().parents[2]
    rock5b_workspace = Path(
        os.environ.get("ROCK5B_WORKSPACE", repo_root.parent / "rock-5b")
    )
    workspace = Path(
        os.environ.get(
            "WORKSPACE",
            rock5b_workspace / "build/kernel/rock5b-kernel-build",
        )
    )
    return Path(os.environ.get("ARMBIAN_BUILD", workspace / "armbian-build"))


def parse_artifact(path: Path) -> tuple[str, str, str] | None:
    for pattern in (PRIMARY_DEB_RE, HASHED_DEB_RE):
        match = pattern.match(path.name)
        if match:
            return match.group("slot"), match.group("build"), match.group("kind")

    match = HASHED_TAR_RE.match(path.name)
    if match:
        slot = f"{match.group('branch')}-{match.group('family')}"
        return slot, match.group("build"), "tar"
    return None


def tar_contains_kernel_image(path: Path) -> bool:
    try:
        with tarfile.open(path, mode="r:*") as archive:
            return any(
                Path(member.name).name.startswith("linux-image-")
                and member.name.endswith(".deb")
                for member in archive.getmembers()
            )
    except (OSError, tarfile.TarError):
        return False


def scan_artifacts(
    debs_dir: Path, hashed_dir: Path
) -> tuple[dict[tuple[str, str], BuildGroup], list[Path]]:
    grouped: dict[tuple[str, str], list[Artifact]] = defaultdict(list)
    unknown: list[Path] = []

    for root in (debs_dir, hashed_dir):
        if not root.is_dir():
            continue
        for path in root.rglob("*"):
            try:
                metadata = path.lstat()
            except FileNotFoundError:
                continue
            if not stat.S_ISREG(metadata.st_mode):
                continue
            parsed = parse_artifact(path)
            if parsed is None:
                unknown.append(path)
                continue
            slot, build, kind = parsed
            if kind == "tar":
                kind = "tar-image" if tar_contains_kernel_image(path) else "partial-tar"
            grouped[(slot, build)].append(
                Artifact(
                    path=path,
                    slot=slot,
                    build=build,
                    kind=kind,
                    size=metadata.st_size,
                    mtime_ns=metadata.st_mtime_ns,
                    device=metadata.st_dev,
                    inode=metadata.st_ino,
                )
            )

    groups = {
        key: BuildGroup(slot=key[0], build=key[1], artifacts=artifacts)
        for key, artifacts in grouped.items()
    }
    return groups, sorted(unknown)


def kernel_md5sums(text: str) -> set[tuple[str, str]]:
    entries: set[tuple[str, str]] = set()
    for line in text.splitlines():
        fields = line.split(maxsplit=1)
        if len(fields) != 2:
            continue
        digest, relative = fields
        relative = relative.removeprefix("./")
        if relative.startswith("boot/vmlinuz-"):
            entries.add((digest, relative))
    return entries


def deb_kernel_md5sums(path: Path) -> set[tuple[str, str]]:
    result = subprocess.run(
        ["dpkg-deb", "--ctrl-tarfile", str(path)],
        check=True,
        capture_output=True,
    )
    with tarfile.open(fileobj=io.BytesIO(result.stdout), mode="r:*") as archive:
        member = next(
            (
                candidate
                for candidate in archive.getmembers()
                if candidate.name.removeprefix("./") == "md5sums"
            ),
            None,
        )
        if member is None:
            return set()
        extracted = archive.extractfile(member)
        if extracted is None:
            return set()
        return kernel_md5sums(extracted.read().decode("utf-8", errors="replace"))


def installed_image_packages() -> list[str]:
    if shutil.which("dpkg-query") is None:
        return []
    result = subprocess.run(
        [
            "dpkg-query",
            "-W",
            "-f=${binary:Package}\t${db:Status-Status}\\n",
            "linux-image-*",
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    packages: list[str] = []
    for line in result.stdout.splitlines():
        fields = line.split("\t")
        if len(fields) != 2 or fields[1] != "installed":
            continue
        packages.append(fields[0].removesuffix(":arm64"))
    return packages


def installed_protected_groups(
    groups: dict[tuple[str, str], BuildGroup], warnings: list[str]
) -> dict[tuple[str, str], str]:
    protected: dict[tuple[str, str], str] = {}
    installed = set(installed_image_packages())
    if not installed or shutil.which("dpkg-deb") is None:
        return protected

    installed_sums: dict[str, set[tuple[str, str]]] = {}
    for package in installed:
        sums_path = Path("/var/lib/dpkg/info") / f"{package}.md5sums"
        try:
            installed_sums[package] = kernel_md5sums(
                sums_path.read_text(encoding="utf-8", errors="replace")
            )
        except OSError:
            continue

    for key, group in groups.items():
        package = f"linux-image-{group.slot}"
        expected = installed_sums.get(package)
        if not expected:
            continue
        image_debs = [
            artifact
            for artifact in group.artifacts
            if artifact.kind == "image" and artifact.path.suffix == ".deb"
        ]
        for artifact in image_debs:
            try:
                candidate = deb_kernel_md5sums(artifact.path)
            except (OSError, subprocess.CalledProcessError, tarfile.TarError) as error:
                warnings.append(f"could not inspect {artifact.path}: {error}")
                continue
            if expected & candidate:
                protected[key] = f"installed package {package}"
                break
    return protected


def build_retention_plan(
    groups: dict[tuple[str, str], BuildGroup],
    keep_per_slot: int,
    min_age_hours: float,
    protect_tokens: list[str],
    drop_slots: set[str],
    now_ns: int,
    installed: dict[tuple[str, str], str],
) -> tuple[dict[tuple[str, str], list[str]], set[tuple[str, str]]]:
    reasons: dict[tuple[str, str], list[str]] = defaultdict(list)

    by_slot: dict[str, list[tuple[tuple[str, str], BuildGroup]]] = defaultdict(list)
    for key, group in groups.items():
        if group.recoverable:
            by_slot[group.slot].append((key, group))

    for entries in by_slot.values():
        if entries[0][1].slot in drop_slots:
            continue
        entries.sort(
            key=lambda item: (item[1].newest_mtime_ns, item[1].build),
            reverse=True,
        )
        for position, (key, _group) in enumerate(entries[:keep_per_slot], start=1):
            reasons[key].append(f"newest {position}/{keep_per_slot} for slot")

    recent_ns = int(min_age_hours * 60 * 60 * 1_000_000_000)
    for key, group in groups.items():
        if now_ns - group.newest_mtime_ns < recent_ns:
            reasons[key].append(f"newer than {min_age_hours:g} hours")
        for token in protect_tokens:
            if token in group.build or token in f"{group.slot}/{group.build}":
                reasons[key].append(f"explicit --protect {token}")
        if key in installed:
            reasons[key].append(installed[key])

    keep = set(reasons)
    delete = set(groups) - keep
    return reasons, delete


def human_size(value: int) -> str:
    size = float(value)
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if size < 1024 or unit == "TiB":
            return f"{size:.1f} {unit}"
        size /= 1024
    raise AssertionError("unreachable")


def remove_empty_children(root: Path) -> None:
    directories = sorted(
        (path for path in root.rglob("*") if path.is_dir()),
        key=lambda path: len(path.parts),
        reverse=True,
    )
    for directory in directories:
        try:
            directory.rmdir()
        except OSError:
            pass


def apply_deletions(groups: list[BuildGroup], roots: tuple[Path, Path]) -> None:
    artifacts = sorted(
        (artifact for group in groups for artifact in group.artifacts),
        key=lambda artifact: str(artifact.path),
    )

    for artifact in artifacts:
        metadata = artifact.path.lstat()
        identity = (
            metadata.st_dev,
            metadata.st_ino,
            metadata.st_size,
            metadata.st_mtime_ns,
        )
        planned = (
            artifact.device,
            artifact.inode,
            artifact.size,
            artifact.mtime_ns,
        )
        if not stat.S_ISREG(metadata.st_mode) or identity != planned:
            raise RuntimeError(f"artifact changed after planning: {artifact.path}")
        if not os.access(artifact.path.parent, os.W_OK | os.X_OK):
            raise PermissionError(f"artifact directory is not writable: {artifact.path.parent}")

    for artifact in artifacts:
        artifact.path.unlink()

    for root in roots:
        remove_empty_children(root)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Keep recent/recoverable Armbian kernel build groups and prune older "
            "recognized .deb and packages-hashed artifacts. The default is a dry run."
        )
    )
    parser.add_argument(
        "--armbian-build",
        type=Path,
        default=default_armbian_build(),
        help="Armbian build checkout (default: grouped external workspace)",
    )
    parser.add_argument(
        "--keep",
        type=int,
        default=2,
        metavar="N",
        help="keep the N newest recoverable build groups per slot (default: 2)",
    )
    parser.add_argument(
        "--min-age-hours",
        type=float,
        default=24,
        metavar="HOURS",
        help="never delete a build group newer than this (default: 24)",
    )
    parser.add_argument(
        "--protect",
        action="append",
        default=[],
        metavar="TOKEN",
        help="preserve groups whose slot/build identity contains TOKEN; repeatable",
    )
    parser.add_argument(
        "--drop-slot",
        action="append",
        default=[],
        metavar="SLOT",
        help=(
            "retire SLOT instead of retaining its newest groups; installed, recent, "
            "and explicitly protected groups still win; repeatable"
        ),
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="permanently remove the artifacts selected by the displayed plan",
    )
    args = parser.parse_args(argv)
    if args.keep < 0:
        parser.error("--keep must be zero or greater")
    if args.min_age_hours < 0:
        parser.error("--min-age-hours must be zero or greater")
    return args


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    armbian_build = args.armbian_build.expanduser().resolve()
    output = armbian_build / "output"
    debs_dir = output / "debs"
    hashed_dir = output / "packages-hashed"
    roots = (debs_dir, hashed_dir)

    if not armbian_build.is_dir():
        print(f"error: Armbian build directory not found: {armbian_build}", file=sys.stderr)
        return 2
    if not any(root.is_dir() for root in roots):
        print(f"error: no kernel artifact directories under: {output}", file=sys.stderr)
        return 2

    markers = sorted(armbian_build.parent.glob(".ysp-build-marker.*"))
    if markers:
        print("error: an active or interrupted ysp kernel build marker exists:", file=sys.stderr)
        for marker in markers:
            print(f"  {marker}", file=sys.stderr)
        print("verify the build state before pruning", file=sys.stderr)
        return 2

    groups, unknown = scan_artifacts(debs_dir, hashed_dir)
    warnings: list[str] = []
    installed = installed_protected_groups(groups, warnings)
    reasons, delete_keys = build_retention_plan(
        groups=groups,
        keep_per_slot=args.keep,
        min_age_hours=args.min_age_hours,
        protect_tokens=args.protect,
        drop_slots=set(args.drop_slot),
        now_ns=time.time_ns(),
        installed=installed,
    )

    kept_groups = [groups[key] for key in sorted(reasons)]
    deleted_groups = [groups[key] for key in sorted(delete_keys)]
    for group in sorted(groups.values(), key=lambda item: (item.slot, item.build)):
        key = (group.slot, group.build)
        if key in reasons:
            disposition = "KEEP"
            detail = "; ".join(reasons[key])
        else:
            disposition = "DELETE"
            if group.slot in args.drop_slot:
                detail = "retired slot"
            elif group.recoverable:
                detail = "old build group"
            else:
                detail = "orphaned partial group"
        print(
            f"{disposition:6} {group.slot:40} {group.build} "
            f"({len(group.artifacts)} files, {human_size(group.size)}; {detail})"
        )

    if unknown:
        print(f"UNKNOWN {len(unknown)} regular files left untouched:")
        for path in unknown:
            print(f"  {path}")
    for warning in warnings:
        print(f"warning: {warning}", file=sys.stderr)

    keep_files = sum(len(group.artifacts) for group in kept_groups)
    delete_files = sum(len(group.artifacts) for group in deleted_groups)
    keep_bytes = sum(group.size for group in kept_groups)
    delete_bytes = sum(group.size for group in deleted_groups)
    print(
        "Summary: "
        f"keep {len(kept_groups)} groups/{keep_files} files/{human_size(keep_bytes)}; "
        f"delete {len(deleted_groups)} groups/{delete_files} files/"
        f"{human_size(delete_bytes)}."
    )

    if not args.apply:
        print("Dry run only; re-run with --apply to permanently remove DELETE entries.")
        return 0

    try:
        apply_deletions(deleted_groups, roots)
    except (FileNotFoundError, PermissionError, RuntimeError) as error:
        print(f"error: retention plan was not applied: {error}", file=sys.stderr)
        return 1
    print(f"Removed {delete_files} files ({human_size(delete_bytes)} logical size).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
