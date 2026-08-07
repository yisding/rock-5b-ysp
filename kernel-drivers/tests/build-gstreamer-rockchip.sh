#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: LGPL-2.1-or-later
# Build the staged JeffyCN GStreamer Rockchip MPP/RGA plugin.
set -euo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$TEST_DIR/../.." && pwd)
ROCK5B_WORKSPACE=${ROCK5B_WORKSPACE:-"$REPO_ROOT/../rock-5b"}
CONFORMANCE_ROOT=${CONFORMANCE_ROOT:-"$ROCK5B_WORKSPACE/build/rockchip-conformance"}
SRC_ROOT=${GST_ROCKCHIP_SRC:-"$CONFORMANCE_ROOT/sources/jeffycn-gstreamer-rockchip"}
GST_ROCKCHIP_PATCH_DIR=${GST_ROCKCHIP_PATCH_DIR-"$TEST_DIR/patches/gstreamer-rockchip"}
BUILD_DIR=${BUILD_DIR:-"$CONFORMANCE_ROOT/build/jeffycn-gstreamer-rockchip-mpp"}
PREFIX=${PREFIX:-"$CONFORMANCE_ROOT/out/gstreamer-rockchip"}
# Installed development packages are the default. Set MPP_PREFIX and/or
# PKG_SHIM only to build the plugin against an explicit staged stack.
MPP_PREFIX=${MPP_PREFIX:-}
PKG_SHIM=${PKG_SHIM:-}
EVENT_HARNESS_SRC=${EVENT_HARNESS_SRC:-"$TEST_DIR/gstreamer-event-harness.c"}
GST_EVENT_HARNESS_VALIDATE_BUILD=${GST_EVENT_HARNESS_VALIDATE_BUILD:-0}
ROCKCHIPMPP_FEATURE=${ROCKCHIPMPP_FEATURE:-enabled}
RGA_FEATURE=${RGA_FEATURE:-enabled}
RKXIMAGE_FEATURE=${RKXIMAGE_FEATURE:-disabled}
KMSSRC_FEATURE=${KMSSRC_FEATURE:-disabled}
VPXALPHADEC_FEATURE=${VPXALPHADEC_FEATURE:-auto}
JOBS=${JOBS:-$(nproc)}
CC=${CC:-cc}
PKG_CONFIG=${PKG_CONFIG:-pkg-config}

prepare_plugin_source()
{
	local patch patch_digest source_commit staged_src tmp_dir
	local -a patches=()

	if [ -z "$GST_ROCKCHIP_PATCH_DIR" ] ||
		[ ! -d "$GST_ROCKCHIP_PATCH_DIR" ]; then
		printf '%s\n' "$SRC_ROOT"
		return 0
	fi

	while IFS= read -r patch; do
		patches+=("$patch")
	done < <(find "$GST_ROCKCHIP_PATCH_DIR" -maxdepth 1 -type f \
		-name '*.patch' -print | sort)
	if [ "${#patches[@]}" -eq 0 ]; then
		printf '%s\n' "$SRC_ROOT"
		return 0
	fi

	if ! source_commit=$(git -C "$SRC_ROOT" rev-parse --verify 'HEAD^{commit}'); then
		echo "Cannot apply maintained patches: $SRC_ROOT is not a Git checkout" >&2
		return 2
	fi
	patch_digest=$(
		for patch in "${patches[@]}"; do
			sha256sum "$patch" | cut -d' ' -f1
		done | sha256sum | cut -d' ' -f1
	)
	staged_src="${BUILD_DIR}.source-${source_commit:0:12}-${patch_digest:0:12}"
	if [ -d "$staged_src" ]; then
		printf '%s\n' "$staged_src"
		return 0
	fi

	mkdir -p "$(dirname "$BUILD_DIR")"
	tmp_dir=$(mktemp -d \
		"$(dirname "$BUILD_DIR")/.gstreamer-rockchip-source.XXXXXX")
	if ! git -C "$SRC_ROOT" archive "$source_commit" | tar -x -C "$tmp_dir"; then
		rm -rf "$tmp_dir"
		echo "Failed to stage JeffyCN GStreamer source" >&2
		return 2
	fi
	for patch in "${patches[@]}"; do
		echo "Applying maintained GStreamer patch: $(basename "$patch")" >&2
		if ! git -C "$tmp_dir" apply "$patch"; then
			rm -rf "$tmp_dir"
			return 2
		fi
	done
	if ! mv "$tmp_dir" "$staged_src"; then
		rm -rf "$tmp_dir"
		return 2
	fi

	printf '%s\n' "$staged_src"
}

build_event_harness()
{
	local output=$1
	local -a harness_cflags
	local -a harness_libs

	IFS=' ' read -r -a harness_cflags <<< "$("$PKG_CONFIG" --cflags gstreamer-1.0 glib-2.0)"
	IFS=' ' read -r -a harness_libs <<< "$("$PKG_CONFIG" --libs gstreamer-1.0 glib-2.0)"
	"$CC" -Wall -Wextra -Werror -O2 -g \
		"${harness_cflags[@]}" \
		-o "$output" \
		"$EVENT_HARNESS_SRC" \
		"${harness_libs[@]}"
}

if [ "$GST_EVENT_HARNESS_VALIDATE_BUILD" = "1" ]; then
	tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/rkcompat-gst-event-harness.XXXXXX")"
	trap 'rm -rf "$tmp_dir"' EXIT
	if ! "$PKG_CONFIG" --exists gstreamer-1.0 glib-2.0; then
		echo "SKIP: missing GStreamer development pkg-config files for event harness build"
		exit 77
	fi
	build_event_harness "$tmp_dir/gstreamer-event-harness"
	echo "PASS: GStreamer event harness builds"
	exit 0
fi

if [ ! -d "$SRC_ROOT" ]; then
	echo "Missing GStreamer Rockchip source directory: $SRC_ROOT" >&2
	exit 2
fi

ACTIVE_SRC_ROOT=$(prepare_plugin_source)

dependency_pc_path=${PKG_CONFIG_PATH:-}
if [ -n "$PKG_SHIM" ]; then
	dependency_pc_path="$PKG_SHIM${dependency_pc_path:+:$dependency_pc_path}"
fi
if [ -n "$MPP_PREFIX" ]; then
	dependency_pc_path="$MPP_PREFIX/lib/pkgconfig${dependency_pc_path:+:$dependency_pc_path}"
fi
if [ -n "$dependency_pc_path" ]; then
	export PKG_CONFIG_PATH="$dependency_pc_path"
fi
# ccache is deliberately NOT disabled here. This used to default CCACHE_DISABLE=1
# to dodge permission failures from a root-owned ~/.cache/ccache; the shared store
# (rock-5b-ysp/scripts/centralize-ccache.sh) is group-writable, so that failure
# mode is gone. Meson auto-detects ccache and prepends it to the compiler, so the
# build wires itself in with no further plumbing. Export CCACHE_DISABLE=1 to opt
# out for a deliberately uncached comparison.

if [ -n "$PKG_SHIM" ] && [ ! -f "$PKG_SHIM/librga.pc" ] &&
	[ -x "$CONFORMANCE_ROOT/scripts/make-librga-pkgconfig.sh" ]; then
	PC_DIR="$PKG_SHIM" "$CONFORMANCE_ROOT/scripts/make-librga-pkgconfig.sh"
fi

required_pc=(
	gstreamer-1.0
	gstreamer-base-1.0
	gstreamer-allocators-1.0
	gstreamer-video-1.0
	gstreamer-pbutils-1.0
	glib-2.0
	rockchip_mpp
	librga
)

if [ "$RKXIMAGE_FEATURE" = "enabled" ]; then
	required_pc+=(x11 libdrm)
fi
if [ "$KMSSRC_FEATURE" = "enabled" ]; then
	required_pc+=(libdrm)
fi

missing=()
for pc in "${required_pc[@]}"; do
	if ! "$PKG_CONFIG" --exists "$pc"; then
		missing+=("$pc")
	fi
done

if [ "${#missing[@]}" -ne 0 ]; then
	echo "Missing pkg-config dependencies for JeffyCN GStreamer Rockchip:" >&2
	printf "  %s\n" "${missing[@]}" >&2
	echo >&2
	echo "On Debian/Ubuntu targets, install the GStreamer development packages:" >&2
	echo "  sudo apt install librockchip-mpp-dev librga-dev libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libglib2.0-dev" >&2
	echo "Then rerun this script from the ysp tree." >&2
	exit 2
fi

setup_args=()
if [ -d "$BUILD_DIR" ]; then
	setup_args+=(--wipe)
fi

meson setup "$BUILD_DIR" "$ACTIVE_SRC_ROOT" \
	--prefix "$PREFIX" \
	--libdir lib \
	-Drockchipmpp="$ROCKCHIPMPP_FEATURE" \
	-Drga="$RGA_FEATURE" \
	-Drkximage="$RKXIMAGE_FEATURE" \
	-Dkmssrc="$KMSSRC_FEATURE" \
	-Dvpxalphadec="$VPXALPHADEC_FEATURE" \
	"${setup_args[@]}"

ninja -C "$BUILD_DIR" -j"$JOBS"
ninja -C "$BUILD_DIR" install

plugin="$PREFIX/lib/gstreamer-1.0/libgstrockchipmpp.so"
if [ ! -f "$plugin" ]; then
	echo "Missing installed GStreamer Rockchip MPP plugin: $plugin" >&2
	exit 1
fi

if [ "$RKXIMAGE_FEATURE" = "enabled" ] &&
	[ ! -f "$PREFIX/lib/gstreamer-1.0/libgstrkximage.so" ]; then
	echo "Missing installed Rockchip display sink plugin: libgstrkximage.so" >&2
	exit 1
fi
if [ "$KMSSRC_FEATURE" = "enabled" ] &&
	[ ! -f "$PREFIX/lib/gstreamer-1.0/libgstkmssrc.so" ]; then
	echo "Missing installed Rockchip KMS source plugin: libgstkmssrc.so" >&2
	exit 1
fi

mkdir -p "$PREFIX/bin"
build_event_harness "$PREFIX/bin/gstreamer-event-harness"

echo "GStreamer Rockchip plugins installed to $PREFIX"
echo "Use: export GST_PLUGIN_PATH=$PREFIX/lib/gstreamer-1.0"
echo "Event harness installed to $PREFIX/bin/gstreamer-event-harness"
if [ "$RKXIMAGE_FEATURE" != "disabled" ]; then
	echo "Display sink feature requested: $RKXIMAGE_FEATURE"
fi
if [ "$KMSSRC_FEATURE" != "disabled" ]; then
	echo "KMS source feature requested: $KMSSRC_FEATURE"
fi
