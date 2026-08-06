#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail

usage() {
	echo "usage: $0 public|wip" >&2
	exit 2
}

profile="${1:-}"
case "$profile" in
	public)
		package_version="7.2.0~rc6+git20260802+rk3588maxlinepublic-0ubuntu1"
		integration_commit="e6951bc3f935427a24140421f780113a64b8a54c"
		;;
	wip)
		package_version="7.2.0~rc6+git20260802+rk3588maxlinewip-0ubuntu1"
		integration_commit="73d29539f7bba7d5865680d35a291ed48bb19cd5"
		;;
	*)
		usage
		;;
esac

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(git -C "$script_dir" rev-parse --show-toplevel)"
packaging_dir="$repo_root/packaging/ppa/kernel-maxline"
kernel_git="${MAXLINE_KERNEL_GIT:-$(dirname "$repo_root")/kernel/linux}"
output_dir="${MAXLINE_OUTPUT_DIR:-$repo_root/packaging/ppa/out/maxline/package-$profile}"
jobs="${MAXLINE_JOBS:-$(nproc)}"
source_dir="$output_dir/linux-rockchip64-ysp-maxline-$profile"
base_commit="075b74841bd0065a3bda3440873c747938e69b68"
reuse_build_dir="${MAXLINE_BUILD_DIR:-}"
reuse_source_dir="${MAXLINE_SOURCE_DIR:-}"

if [[ ! -d "$kernel_git/.git" && ! -f "$kernel_git/.git" ]]; then
	echo "kernel Git repository not found: $kernel_git" >&2
	exit 1
fi

resolved_base="$(git -C "$kernel_git" rev-parse "$base_commit^{commit}")"
if [[ "$resolved_base" != "$base_commit" ]]; then
	echo "base commit resolved to $resolved_base, expected $base_commit" >&2
	exit 1
fi

if [[ -e "$output_dir" ]]; then
	echo "refusing to overwrite existing output directory: $output_dir" >&2
	exit 1
fi

if [[ -n "$reuse_build_dir" || -n "$reuse_source_dir" ]]; then
	if [[ -z "$reuse_build_dir" || -z "$reuse_source_dir" ]]; then
		echo "MAXLINE_BUILD_DIR and MAXLINE_SOURCE_DIR must be set together" >&2
		exit 1
	fi
	if [[ ! -d "$reuse_build_dir" ]]; then
		echo "checkpoint build directory not found: $reuse_build_dir" >&2
		exit 1
	fi
	if [[ ! -d "$reuse_source_dir" ]]; then
		echo "checkpoint source directory not found: $reuse_source_dir" >&2
		exit 1
	fi
	reuse_build_dir="$(cd "$reuse_build_dir" && pwd)"
	reuse_source_dir="$(cd "$reuse_source_dir" && pwd)"
	resolved_integration="$(git -C "$reuse_source_dir" rev-parse HEAD)"
	if [[ "$resolved_integration" != "$integration_commit" ]]; then
		echo "checkpoint source is at $resolved_integration, expected $integration_commit" >&2
		exit 1
	fi
	if ! git -C "$reuse_source_dir" diff-index --quiet HEAD --; then
		echo "checkpoint source has tracked changes: $reuse_source_dir" >&2
		exit 1
	fi
fi

mkdir -p "$source_dir"
git -C "$kernel_git" archive "$base_commit" | tar -x -C "$source_dir"
git -C "$source_dir" init -q
git -C "$source_dir" apply "$script_dir/patches/maxline-public.patch"
if [[ "$profile" == "wip" ]]; then
	git -C "$source_dir" apply "$script_dir/patches/maxline-wip.patch"
fi

cp -a "$packaging_dir/debian" "$source_dir/debian"
mv "$source_dir/debian/rules.in" "$source_dir/debian/rules"
mv "$source_dir/debian/control.in" "$source_dir/debian/control"
mv "$source_dir/debian/changelog.in" "$source_dir/debian/changelog"
sed -i "s/@PROFILE@/$profile/g; s/@VERSION@/$package_version/g" \
	"$source_dir/debian/rules" \
	"$source_dir/debian/control" \
	"$source_dir/debian/changelog"
mkdir -p "$source_dir/debian/config"
cp "$script_dir/config/arm64-rockchip64.config" \
	"$source_dir/debian/config/arm64-rockchip64.config"
chmod 0755 "$source_dir/debian/rules" "$source_dir/debian/scripts/"*.sh

(
	cd "$source_dir"
	if [[ -n "$reuse_build_dir" ]]; then
		MAXLINE_BUILD_DIR="$reuse_build_dir" \
			MAXLINE_SOURCE_DIR="$reuse_source_dir" \
			DEB_BUILD_OPTIONS="parallel=$jobs" \
			dpkg-buildpackage -b -us -uc -nc
	else
		DEB_BUILD_OPTIONS="parallel=$jobs" dpkg-buildpackage -b -us -uc
	fi
)

sha256sum "$output_dir"/*.deb
