#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODE="$(cd "${ROOT_DIR}/../../../.." && pwd)"                # ~/Code (this lives in the ysp)
WORKSPACE="${WORKSPACE:-${CODE}/kernel/rock5b-kernel-build}" # external build scratch (armbian-build lives here)
BUILD_DIR="${WORKSPACE}/armbian-build"
CONFIG_NAME="rock5b-debug-kernel"
CONFIG_SOURCE="${ROOT_DIR}/config-${CONFIG_NAME}.conf.sh"
CONFIG_DEST="${BUILD_DIR}/userpatches/config-${CONFIG_NAME}.conf.sh"
KERNEL_CONFIG="${BUILD_DIR}/userpatches/linux-rockchip64-current.config"

usage() {
	printf 'Usage: %s [--install-deps]\n' "$(basename "$0")"
	printf '\n'
	printf 'Builds an Armbian ROCK 5B current kernel with heavy crash/debug instrumentation.\n'
	printf 'Use --install-deps to install missing host packages with sudo first.\n'
}

install_deps=no
for arg in "$@"; do
	case "$arg" in
		--install-deps) install_deps=yes ;;
		-h|--help) usage; exit 0 ;;
		*) printf 'Unknown argument: %s\n' "$arg" >&2; usage >&2; exit 2 ;;
	esac
done

if [[ ! -x "${BUILD_DIR}/compile.sh" ]]; then
	printf 'Missing Armbian build tree: %s\n' "${BUILD_DIR}" >&2
	exit 1
fi

install -D -m 0644 "${CONFIG_SOURCE}" "${CONFIG_DEST}"

running_config="/boot/config-$(uname -r)"
if [[ -r "${running_config}" ]]; then
	mkdir -p "$(dirname "${KERNEL_CONFIG}")"
	cp -v "${running_config}" "${KERNEL_CONFIG}"
else
	printf 'Cannot read %s; keeping existing %s\n' "${running_config}" "${KERNEL_CONFIG}" >&2
fi

missing=()
check_pkg() {
	local pkg="$1"
	if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q '^install ok installed$'; then
		missing+=("$pkg")
	fi
}

for pkg in \
	build-essential bc bison flex libssl-dev libelf-dev fakeroot rsync git pahole \
	device-tree-compiler python3 python3-pip python3-setuptools swig libncurses-dev; do
	check_pkg "$pkg"
done

if ((${#missing[@]})); then
	printf 'Missing build packages: %s\n' "${missing[*]}" >&2
	if [[ "${install_deps}" == yes ]]; then
		sudo apt-get update
		sudo apt-get install -y "${missing[@]}"
	else
		printf 'Install them with:\n' >&2
		printf '  sudo apt-get update\n' >&2
		printf '  sudo apt-get install -y %s\n' "${missing[*]}" >&2
		printf '\nThen rerun this script, or rerun with --install-deps.\n' >&2
		exit 2
	fi
fi

cd "${BUILD_DIR}"
printf 'Building debug kernel with Armbian config: %s\n' "${CONFIG_NAME}"
printf 'This is a heavy KASAN/lockdep build and can take a while on the board.\n'

PREFER_DOCKER="${PREFER_DOCKER:-no}" ./compile.sh "${CONFIG_NAME}" kernel

printf '\nBuild output:\n'
find "${BUILD_DIR}/output/debs" -maxdepth 1 -type f \
	\( -name 'linux-image-current-rockchip64_*.deb' \
	-o -name 'linux-dtb-current-rockchip64_*.deb' \
	-o -name 'linux-headers-current-rockchip64_*.deb' \
	-o -name 'linux-libc-dev-current-rockchip64_*.deb' \) \
	-print | sort

new_image="$(find "${BUILD_DIR}/output/debs" -maxdepth 1 -type f \
	-name 'linux-image-current-rockchip64_*.deb' -printf '%T@ %p\n' \
	| sort -nr | awk 'NR == 1 {sub(/^[^ ]+ /, ""); print}')"
phash="$(basename "$new_image" 2>/dev/null \
	| grep -oE 'P[0-9a-f]{4,}-C[0-9a-f]{4,}' || true)"
if [[ -n "$phash" ]]; then
	printf '\nExact install hash: %s\n' "$phash"
	printf 'After install.md recovery prep:\n'
	printf '  RECOVERY_READY=1 PHASH=%q bash %q\n' \
		"$phash" "$ROOT_DIR/install-debug-kernel.sh"
fi
