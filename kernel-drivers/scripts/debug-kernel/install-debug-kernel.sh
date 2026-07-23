#!/usr/bin/env bash
set -euo pipefail

usage() {
	cat <<'EOF'
Usage:
  RECOVERY_READY=1 PHASH=P####-C#### bash install-debug-kernel.sh

Selects the exact debug image/DTB/header debs by PHASH, captures diagnostic
boot metadata, installs them, and holds the current-kernel package names.

Environment:
  PHASH=...           Required patch/config hash printed by the build.
  HASH=...            Optional additional kernel-version filename filter.
  RECOVERY_READY=1    Required acknowledgement that rescue media and known-good
                      image/DTB debs are ready (see install.md section 3).
  WORKSPACE=...       External build workspace.
  DEB_DIR=...         Override the Armbian output/debs directory.
  BACKUP_ROOT=...     Override the diagnostic boot-metadata backup directory.
EOF
}

case "${1:-}" in
	-h|--help) usage; exit 0 ;;
	"") ;;
	*) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
esac

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODE="$(cd "${ROOT_DIR}/../../../.." && pwd)"                # ~/Code (this lives in the ysp)
WORKSPACE="${WORKSPACE:-${CODE}/kernel/rock5b-kernel-build}" # external build scratch (armbian-build + boot-backups here)
DEB_DIR="${DEB_DIR:-${WORKSPACE}/armbian-build/output/debs}"
BACKUP_ROOT="${BACKUP_ROOT:-${WORKSPACE}/boot-backups}"
PHASH="${PHASH:-}"
HASH="${HASH:-}"
RECOVERY_READY="${RECOVERY_READY:-0}"

find_deb() {
	local package="$1" file base
	local matches=()
	while IFS= read -r -d '' file; do
		base="$(basename "$file")"
		[[ "$base" == *"$PHASH"* ]] || continue
		if [[ -n "$HASH" && "$base" != *"$HASH"* ]]; then
			continue
		fi
		matches+=("$file")
	done < <(find "$DEB_DIR" -maxdepth 1 -type f -name "${package}_*.deb" -print0)
	((${#matches[@]})) || return 1
	printf '%s\n' "${matches[@]}" | sort -V | tail -1
}

if [[ ! "$PHASH" =~ ^P[0-9a-f]{4,}-C[0-9a-f]{4,}$ ]]; then
	printf 'Set PHASH to the exact P####-C#### printed by build-kernel.sh.\n' >&2
	usage >&2
	exit 2
fi
[ -d "$DEB_DIR" ] || { printf 'Missing deb directory: %s\n' "$DEB_DIR" >&2; exit 1; }

image_deb="$(find_deb linux-image-current-rockchip64 || true)"
dtb_deb="$(find_deb linux-dtb-current-rockchip64 || true)"
headers_deb="$(find_deb linux-headers-current-rockchip64 || true)"

if [[ -z "${image_deb}" || -z "${dtb_deb}" ]]; then
	printf 'Could not find debug image + DTB debs matching PHASH=%s HASH=%s in %s\n' \
		"$PHASH" "${HASH:-<any>}" "$DEB_DIR" >&2
	printf 'Run build-kernel.sh forward-port-debug (or rewrite-debug) first.\n' >&2
	exit 1
fi

if [[ "$RECOVERY_READY" != 1 ]]; then
	cat >&2 <<EOF
ABORT: kernel recovery has not been acknowledged.
  This install can replace the current kernel package files, and ROCK 5B has no
  kernel-selection boot menu. Complete install.md section 3, keep known-good
  image + DTB debs on rescue-accessible storage, then rerun with
  RECOVERY_READY=1.
EOF
	exit 1
fi

sudo bash "$ROOT_DIR/../kernel-revert.sh" list

stamp="$(date +%Y%m%d-%H%M%S)"
backup_dir="${BACKUP_ROOT}/${stamp}"
mkdir -p "${backup_dir}"

running_release="$(uname -r)"
{
	printf 'captured=%s\n' "$(date -Is)"
	printf 'running_release=%s\n' "$running_release"
	printf 'boot_image=%s\n' "$(readlink -f /boot/Image 2>/dev/null || true)"
	printf 'boot_dtb=%s\n' "$(readlink -f /boot/dtb 2>/dev/null || true)"
	dpkg-query -W -f='${binary:Package}\t${Version}\t${db:Status-Abbrev}\n' \
		'linux-image*rockchip*' 'linux-dtb*rockchip*' 'linux-headers*rockchip*' \
		2>/dev/null || true
} >"$backup_dir/manifest.txt"

printf 'Capturing diagnostic boot artifacts to %s\n' "${backup_dir}"
for path in \
	/boot/armbianEnv.txt \
	/boot/Image \
	/boot/vmlinuz \
	/boot/uInitrd \
	/boot/dtb \
	"/boot/vmlinuz-${running_release}" \
	"/boot/initrd.img-${running_release}" \
	"/boot/uInitrd-${running_release}" \
	"/boot/System.map-${running_release}" \
	"/boot/config-${running_release}" \
	"/boot/dtb-${running_release}"; do
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
printf '\nDiagnostic boot capture: %s\n' "${backup_dir}"
printf 'This capture does not replace the known-good debs and rescue path prepared earlier.\n'
printf 'If the board does not boot, use ../kernel-revert.sh from the rescue system.\n'
