#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODE="$(cd "${ROOT_DIR}/../../../.." && pwd)"                # ~/Code (this lives in the ysp)
WORKSPACE="${WORKSPACE:-${CODE}/kernel/rock5b-kernel-build}" # external build scratch (armbian-build + boot-backups here)
DEB_DIR="${WORKSPACE}/armbian-build/output/debs"
BACKUP_ROOT="${WORKSPACE}/boot-backups"

newest_deb() {
	local pattern="$1"
	find "${DEB_DIR}" -maxdepth 1 -type f -name "${pattern}" -printf '%T@ %p\n' \
		| sort -nr \
		| awk 'NR == 1 {print $2}'
}

image_deb="$(newest_deb 'linux-image-current-rockchip64_*.deb')"
dtb_deb="$(newest_deb 'linux-dtb-current-rockchip64_*.deb')"
headers_deb="$(newest_deb 'linux-headers-current-rockchip64_*.deb')"

if [[ -z "${image_deb}" || -z "${dtb_deb}" ]]; then
	printf 'Could not find debug kernel .debs in %s\n' "${DEB_DIR}" >&2
	printf 'Run ./build-rock5b-debug-kernel.sh first.\n' >&2
	exit 1
fi

stamp="$(date +%Y%m%d-%H%M%S)"
backup_dir="${BACKUP_ROOT}/${stamp}"
mkdir -p "${backup_dir}"

printf 'Backing up current boot artifacts to %s\n' "${backup_dir}"
for path in \
	/boot/Image \
	/boot/vmlinuz-6.18.35-current-rockchip64 \
	/boot/initrd.img-6.18.35-current-rockchip64 \
	/boot/uInitrd-6.18.35-current-rockchip64 \
	/boot/System.map-6.18.35-current-rockchip64 \
	/boot/config-6.18.35-current-rockchip64 \
	/boot/dtb-6.18.35-current-rockchip64; do
	if [[ -e "${path}" || -L "${path}" ]]; then
		sudo cp -a "${path}" "${backup_dir}/"
	fi
done

printf 'Installing:\n  %s\n  %s\n' "${image_deb}" "${dtb_deb}"
if [[ -n "${headers_deb}" ]]; then
	printf '  %s\n' "${headers_deb}"
	sudo dpkg -i "${image_deb}" "${dtb_deb}" "${headers_deb}"
else
	sudo dpkg -i "${image_deb}" "${dtb_deb}"
fi

printf 'Holding current kernel packages so apt does not overwrite this debug build.\n'
sudo apt-mark hold linux-image-current-rockchip64 linux-dtb-current-rockchip64 linux-headers-current-rockchip64 || true

printf '\nInstalled debug kernel. Reboot, then verify with:\n'
printf '  uname -a\n'
printf '  zgrep -E \"PSTORE_CONSOLE|KASAN|PROVE_LOCKING|DRM_DEBUG_MM|DMA_API_DEBUG\" /proc/config.gz\n'
printf '  sudo dmesg | grep -Ei \"kasan|lockdep|pstore|ramoops|drm|panthor\"\n'
printf '\nBoot backup: %s\n' "${backup_dir}"
