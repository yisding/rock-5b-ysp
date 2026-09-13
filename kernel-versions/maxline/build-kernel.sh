#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail

usage() {
	cat >&2 <<'USAGE'
usage: build-kernel.sh public|wip

Reconstruct a pinned maxline profile and build it with the separate Debian
packaging overlay. By default this builds binary packages locally.

Set MAXLINE_SOURCE_PACKAGE=1 to build an unsigned *source* package instead --
an orig tarball, a Debian tarball, a .dsc, and a source .changes, written to
packaging/ppa/out/artifacts (override with MAXLINE_ARTIFACTS). That is the
only form Launchpad accepts; sign and upload it with the publication runbook.
USAGE
	exit 2
}

profile="${1:-}"
case "$profile" in
	public)
		upstream_version="7.3.0~rc2+git20260913+rk3588maxlinepublic"
		integration_commit="1e66ae0b4633f6a3de00b7bd705b10c45f44ff8a"
		;;
	wip)
		upstream_version="7.3.0~rc2+git20260913+rk3588maxlinewip"
		integration_commit="7306d4ede54c9a78cebd3ed31156bdeecc57dc2d"
		;;
	*)
		usage
		;;
esac
package_version="$upstream_version-0ubuntu1"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(git -C "$script_dir" rev-parse --show-toplevel)"
packaging_dir="$repo_root/packaging/ppa/kernel-maxline"
# Kernel checkouts moved under <code>/rock-5b/kernel/ in 2026-07; the old
# <code>/kernel/linux default silently pointed at nothing. Resolve through
# ROCK5B_WORKSPACE like the other build entry points do.
rock5b_workspace="${ROCK5B_WORKSPACE:-$(dirname "$repo_root")/rock-5b}"
kernel_git="${MAXLINE_KERNEL_GIT:-$rock5b_workspace/kernel/linux}"
output_dir="${MAXLINE_OUTPUT_DIR:-$repo_root/packaging/ppa/out/maxline/package-$profile}"
jobs="${MAXLINE_JOBS:-$(nproc)}"
source_package="linux-rockchip64-ysp-maxline-$profile"
source_only="${MAXLINE_SOURCE_PACKAGE:-0}"
artifacts_dir="${MAXLINE_ARTIFACTS:-$repo_root/packaging/ppa/out/artifacts}"
source_dir="$output_dir/${source_package}-${upstream_version}"
base_commit="df2908090cda368b01ff43709f51890076c56157"
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

if [[ "$source_only" == 1 ]]; then
	# 3.0 (quilt) wants the upstream tree as an orig tarball with no debian/
	# in it. Build it from the reconstructed source before the overlay lands,
	# with a fixed mtime/owner so the tarball is reproducible for a given pin.
	# dpkg-source looks for the orig tarball next to the source directory,
	# so build it in $output_dir; it is moved to $artifacts_dir at the end.
	mkdir -p "$artifacts_dir"
	orig_tar="$output_dir/${source_package}_${upstream_version}.orig.tar.gz"
	tar --sort=name --owner=0 --group=0 --numeric-owner \
		--mtime="@$(git -C "$kernel_git" show -s --format=%ct "$base_commit")" \
		-C "$output_dir" -czf "$orig_tar" "$(basename "$source_dir")"
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
	if [[ "$source_only" == 1 ]]; then
		dpkg-buildpackage -S -us -uc -sa
	elif [[ -n "$reuse_build_dir" ]]; then
		MAXLINE_BUILD_DIR="$reuse_build_dir" \
			MAXLINE_SOURCE_DIR="$reuse_source_dir" \
			DEB_BUILD_OPTIONS="parallel=$jobs" \
			dpkg-buildpackage -b -us -uc -nc
	else
		DEB_BUILD_OPTIONS="parallel=$jobs" dpkg-buildpackage -b -us -uc
	fi
)

if [[ "$source_only" == 1 ]]; then
	for artifact in "$output_dir/${source_package}_${upstream_version}.orig.tar.gz" \
			"$output_dir/${source_package}_${package_version}"*; do
		[[ -e "$artifact" ]] || continue
		mv -f "$artifact" "$artifacts_dir/"
	done
	echo "source package written to $artifacts_dir:"
	ls -1 "$artifacts_dir/${source_package}_"* 2>/dev/null
fi

sha256sum "$output_dir"/*.deb
