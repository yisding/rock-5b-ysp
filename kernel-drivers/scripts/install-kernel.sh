#!/usr/bin/env bash
# =============================================================================
# install-kernel.sh -- install a locally built RK3588 (Radxa ROCK 5B) kernel.
#
# One installer for every local flavor. There is no per-flavor logic below,
# because every safety step here turned out to apply to all of them.
#
# You do not normally pick the kernel: PHASH already identifies one exact build,
# and the deb filename carries its slot, so the slot is INFERRED. SLOT= is only
# needed to disambiguate if one PHASH somehow matches more than one slot.
#
#   video-port          production forward-port
#   video-port-kasan    forward-port KASAN/lockdep
#   video-rewrite       production clean-room rewrite
#   video-rewrite-kasan clean-room rewrite KASAN/lockdep
#
# Each slot is a distinct package name AND kernel release string, so installing
# one never disturbs another (see docs/kernel-builds.md "Package slots").
# `current-rockchip64` belongs to Armbian's own kernel and `ysp-rockchip64` to
# the PPA lineage -- this script writes neither.
#
# Kernel package installation replaces that slot's files, and this board has no
# U-Boot kernel-selection menu, so the script captures the current boot
# artifacts and requires an explicit acknowledgement that rescue media and
# known-good debs are ready.
#
# Usage:
#   sudo RECOVERY_READY=1 PHASH='P####-C####' bash install-kernel.sh
#
# Knobs: SLOT= (only to disambiguate), DEBS= (deb directory),
#        HASH= (extra kernel-version filter),
#        BOOT_CMD=, BACKUP_ROOT=, ENV=, ALLOW_OVERSIZE_IMAGE=1.
# =============================================================================
set -uo pipefail
[ "${1:-}" != "-h" ] && [ "${1:-}" != "--help" ] || { sed -n '2,29p' "$0"; exit 0; }
[ "$(id -u)" -eq 0 ] || {
	echo "Run as root:  sudo RECOVERY_READY=1 PHASH='P####-C####' bash $0"
	exit 1
}

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODE="$(cd "$HERE/../../.." && pwd)"                        # ~/Code
WORKSPACE="${WORKSPACE:-$CODE/kernel/rock5b-kernel-build}"
DEBS="${DEBS:-${ARMBIAN_BUILD:-$WORKSPACE/armbian-build}/output/debs}"
BACKUP_ROOT="${BACKUP_ROOT:-$WORKSPACE/boot-backups}"
ENV_FILE="${ENV:-/boot/armbianEnv.txt}"
BOOT_CMD="${BOOT_CMD:-/boot/boot.cmd}"
SLOT="${SLOT:-}"          # usually unnecessary: inferred from PHASH below
PHASH="${PHASH:-}"        # required; pins the exact build (printed by build-kernel.sh)
HASH="${HASH:-}"          # optional kernel-version filter, e.g. 6.18.38
RECOVERY_READY="${RECOVERY_READY:-0}"

OUR_SLOTS=(video-port video-port-kasan video-rewrite video-rewrite-kasan)

validate_slot() {
	local s="$1" known
	for known in "${OUR_SLOTS[@]}"; do
		[ "$s" = "$known" ] && return 0
	done
	case "$s" in
	current | current-rockchip64 | ysp | ysp-rockchip64)
		echo "REFUSING: '$s' is not ours. current-rockchip64 is Armbian's stock" >&2
		echo "  kernel and ysp-rockchip64 is the PPA lineage (install that with apt)." >&2
		;;
	*)
		echo "Unknown SLOT '$s'. Valid: ${OUR_SLOTS[*]}." >&2
		;;
	esac
	return 1
}

[ -z "$SLOT" ] || validate_slot "$SLOT" || exit 2

[ -d "$DEBS" ] || {
	echo "No deb dir: $DEBS -- run build-kernel.sh first (or set DEBS=)"
	exit 1
}

print_recent_images() {
	echo "  recent image debs in this slot:"
	find "$DEBS" -maxdepth 1 -type f -name "linux-image-${PKG_SUFFIX}_*.deb" \
		-printf '      %f\n' | sort -V | tail -8
}

describe_filter() {
	printf 'SLOT=%s, PHASH=%s' "$SLOT" "$PHASH"
	[ -n "$HASH" ] && printf ', HASH=%s' "$HASH"
}

find_deb() {
	local package="$1" f base
	local matches=()
	while IFS= read -r -d '' f; do
		base="$(basename "$f")"
		[[ "$base" == *"$PHASH"* ]] || continue
		if [ -n "$HASH" ] && [[ "$base" != *"$HASH"* ]]; then continue; fi
		matches+=("$f")
	done < <(find "$DEBS" -maxdepth 1 -type f -name "${package}_*.deb" -print0)
	[ "${#matches[@]}" -gt 0 ] || return 1
	printf '%s\n' "${matches[@]}" | sort -V | tail -1
}

if [ -z "$PHASH" ]; then
	echo "Set PHASH to the build hash printed by build-kernel.sh, e.g.:"
	echo "  sudo RECOVERY_READY=1 PHASH='Pd745-Cb831' bash $0"
	echo "  recent image debs across all slots:"
	find "$DEBS" -maxdepth 1 -type f -name 'linux-image-video-*-rockchip64_*.deb' \
		-printf '      %f\n' 2>/dev/null | sort -V | tail -8
	exit 1
fi

# The deb filename carries both the slot (package name) and the PHASH, so the
# slot is derivable -- asking for it again is just a chance to get it wrong.
# SLOT stays available to disambiguate, and is required only if one PHASH
# somehow matches builds in more than one slot.
infer_slot() {
	local s found=()
	for s in "${OUR_SLOTS[@]}"; do
		if compgen -G "$DEBS/linux-image-${s}-rockchip64_*${PHASH}*.deb" >/dev/null; then
			found+=("$s")
		fi
	done
	case "${#found[@]}" in
	1) printf '%s\n' "${found[0]}" ;;
	0) return 1 ;;
	*)
		echo "AMBIGUOUS: PHASH=$PHASH matches builds in ${#found[@]} slots:" >&2
		printf '    %s\n' "${found[@]}" >&2
		echo "  Re-run with SLOT=<one of the above>." >&2
		return 2
		;;
	esac
}

echo "================= STEP 1: locate the built debs ================="
if [ -z "$SLOT" ]; then
	SLOT="$(infer_slot)" || {
		rc=$?
		[ "$rc" = 2 ] && exit 2
		echo "  no image deb in any of our slots matches PHASH=$PHASH" >&2
		# Builds predating the slot split landed in Armbian's own
		# current-rockchip64. Say so rather than claiming the deb is missing.
		if compgen -G "$DEBS/linux-image-current-rockchip64_*${PHASH}*.deb" >/dev/null; then
			echo "  BUT a matching deb exists in current-rockchip64 -- that is a" >&2
			echo "  pre-slot-split build sitting in Armbian's slot. Rebuild it with" >&2
			echo "  build-kernel.sh so it lands in its own slot; this script will not" >&2
			echo "  install into current-rockchip64." >&2
			exit 1
		fi
		echo "  recent image debs across our slots:" >&2
		find "$DEBS" -maxdepth 1 -type f -name 'linux-image-video-*-rockchip64_*.deb' \
			-printf '      %f\n' 2>/dev/null | sort -V | tail -8 >&2
		exit 1
	}
	echo "  slot inferred from PHASH: $SLOT"
fi
PKG_SUFFIX="${SLOT}-rockchip64"
echo "  filter: $(describe_filter)"
IMG=$(find_deb "linux-image-${PKG_SUFFIX}" || true)
DTB=$(find_deb "linux-dtb-${PKG_SUFFIX}" || true)
HDR=$(find_deb "linux-headers-${PKG_SUFFIX}" || true)
for f in "$IMG" "$DTB"; do
	[ -f "$f" ] || {
		echo "  MISSING a deb matching $(describe_filter) -- aborting"
		print_recent_images
		exit 1
	}
	echo "  $(basename "$f")"
done
[ -f "$HDR" ] && echo "  $(basename "$HDR")"
echo

# -----------------------------------------------------------------------------
# STEP 2: load-address preflight.
#
# An arm64 Image reserves image_size bytes -- text *plus* BSS -- at
# kernel_addr_r. A kernel bigger than the gap to fdt_addr_r zeroes the loaded
# device tree while clearing BSS and dies before console init: no HDMI, no
# serial, no ramoops, no journal. That is exactly how the 2026-07-24
# P4052-C40aa-H7883 build failed.
#
# This was a debug-installer-only check, but nothing about it is debug-specific
# -- KASAN builds just hit the ceiling first. It runs for every slot.
# -----------------------------------------------------------------------------
echo "================= STEP 2: U-Boot load-address preflight ================="
uboot_addr() { # name stock-default -- last setenv in boot.cmd wins, as in U-Boot
	local value=""
	if [[ -r "$BOOT_CMD" ]]; then
		value="$(sed -n "s/^[[:space:]]*setenv[[:space:]]\+$1[[:space:]]\+\"\?\([0-9a-fA-Fx]\+\)\"\?[[:space:]]*$/\1/p" "$BOOT_CMD" | tail -1)"
	fi
	printf '%s\n' "${value:-$2}"
}

image_size_from_deb() {
	( set +o pipefail
	  dpkg-deb --fsys-tarfile "$1" 2>/dev/null \
	    | tar -xO --wildcards './boot/vmlinuz-*' 2>/dev/null \
	    | head -c 64 \
	    | python3 -c 'import struct, sys
head = sys.stdin.buffer.read(64)
if len(head) == 64 and head[56:60] == b"ARM\x64":
    print(struct.unpack_from("<Q", head, 16)[0])' 2>/dev/null ) || true
}

kernel_addr="$(uboot_addr kernel_addr_r 0x00400000)"
fdt_addr="$(uboot_addr fdt_addr_r 0x08300000)"
gap=$(( fdt_addr - kernel_addr ))
image_size="$(image_size_from_deb "$IMG")"
if [ -z "$image_size" ]; then
	echo "  WARN: no arm64 Image header found in $(basename "$IMG"); skipping preflight." >&2
elif [ "$image_size" -gt "$gap" ]; then
	cat >&2 <<EOF
ABORT: this kernel does not fit the current U-Boot load map.
  kernel_addr_r  $kernel_addr
  fdt_addr_r     $fdt_addr
  headroom       $(( gap / 1048576 )) MiB
  Image          $(( image_size / 1048576 )) MiB (text+BSS, overruns by $(( (image_size - gap + 1048575) / 1048576 )) MiB)
  The kernel would clear its BSS over the device tree and die before console
  init -- no HDMI, no serial, no ramoops, no journal to debug it with.
  Fix with:  sudo bash "$HERE/debug-kernel/set-boot-load-addresses.sh"
  Then rerun. Override with ALLOW_OVERSIZE_IMAGE=1 only if you have confirmed
  U-Boot relocates the FDT clear of the kernel.
EOF
	[ "${ALLOW_OVERSIZE_IMAGE:-0}" = 1 ] || exit 1
	echo "  ALLOW_OVERSIZE_IMAGE=1 set; continuing over the size check." >&2
else
	printf '  Image %s MiB fits the %s MiB headroom (%s MiB spare).\n' \
		"$(( image_size / 1048576 ))" "$(( gap / 1048576 ))" \
		"$(( (gap - image_size) / 1048576 ))"
fi
echo

if [ "$RECOVERY_READY" != 1 ]; then
	cat >&2 <<EOF
ABORT: kernel recovery has not been acknowledged.
  This install replaces the $PKG_SUFFIX package files, and ROCK 5B has no
  kernel-selection boot menu. Before retrying:
    sudo bash $HERE/kernel-revert.sh list
    keep known-good image + DTB debs on rescue-accessible storage
    verify an SD rescue boot can reach the internal root
  Then rerun with RECOVERY_READY=1. See install.md section 3.
EOF
	exit 1
fi

echo "================= STEP 3: capture current boot state ================="
bash "$HERE/kernel-revert.sh" list || true
stamp="$(date +%Y%m%d-%H%M%S)"
backup_dir="$BACKUP_ROOT/$stamp"
mkdir -p "$backup_dir"
running_release="$(uname -r)"
{
	printf 'captured=%s\n' "$(date -Is)"
	printf 'installing_slot=%s\n' "$SLOT"
	printf 'installing_phash=%s\n' "$PHASH"
	printf 'running_release=%s\n' "$running_release"
	printf 'boot_image=%s\n' "$(readlink -f /boot/Image 2>/dev/null || true)"
	printf 'boot_dtb=%s\n' "$(readlink -f /boot/dtb 2>/dev/null || true)"
	dpkg-query -W -f='${binary:Package}\t${Version}\t${db:Status-Abbrev}\n' \
		'linux-image*rockchip*' 'linux-dtb*rockchip*' 'linux-headers*rockchip*' \
		2>/dev/null || true
} >"$backup_dir/manifest.txt"
for path in \
	/boot/armbianEnv.txt /boot/Image /boot/vmlinuz /boot/uInitrd /boot/dtb \
	"/boot/vmlinuz-${running_release}" "/boot/initrd.img-${running_release}" \
	"/boot/uInitrd-${running_release}" "/boot/System.map-${running_release}" \
	"/boot/config-${running_release}" "/boot/dtb-${running_release}"; do
	[ -e "$path" ] || [ -L "$path" ] && cp -a "$path" "$backup_dir/" 2>/dev/null
done
echo "  captured to $backup_dir"
echo

# The rkvdec2 boot overlay is obsolete for every kernel this script installs:
# they all carry the decoder in the in-tree DT, and the overlay would collide
# (duplicate nodes, a second mpp-srv, and the alias bug that oopsed earlier).
# Idempotent, so it runs unconditionally.
echo "================= STEP 4: remove the obsolete rkvdec2 overlay ================="
if grep -qE '^user_overlays=' "$ENV_FILE" 2>/dev/null; then
	cp -v "$ENV_FILE" "$ENV_FILE.bak-preinstall-$(date +%s)"
	sed -i -E 's/^(user_overlays=.*)\brkvdec2\b ?/\1/; /^user_overlays=[[:space:]]*$/d' "$ENV_FILE"
	echo "  user_overlays now: $(grep -E '^user_overlays=' "$ENV_FILE" || echo '(removed -- good)')"
else
	echo "  no user_overlays line -- nothing to remove"
fi
rm -fv /boot/overlay-user/rkvdec2.dtbo 2>/dev/null || true
echo

echo "================= STEP 5: install image + dtb + headers ================="
if [ -f "$HDR" ]; then
	dpkg -i "$IMG" "$DTB" "$HDR" || { echo "  dpkg failed -- inspect above"; exit 1; }
else
	dpkg -i "$IMG" "$DTB" || { echo "  dpkg failed -- inspect above"; exit 1; }
fi
echo
echo "  holding $PKG_SUFFIX so apt cannot overwrite this build"
apt-mark hold "linux-image-${PKG_SUFFIX}" "linux-dtb-${PKG_SUFFIX}" \
	"linux-headers-${PKG_SUFFIX}" >/dev/null 2>&1 || true
echo

echo "================= STEP 6: verify ================="
echo "  /boot/Image -> $(readlink -f /boot/Image 2>/dev/null || echo /boot/Image)"
NEWDTB=$(find /boot -path '*rockchip/rk3588-rock-5b.dtb' -newermt '-3 minutes' 2>/dev/null | head -1)
if [ -n "$NEWDTB" ]; then
	echo "  installed dtb: $NEWDTB"
	echo "  vendor nodes in it: $(dtc -I dtb -O dts "$NEWDTB" 2>/dev/null | grep -cE 'rkv-encoder-v2-core|rkv-decoder-v2"|rga3_core0')"
fi
echo
echo "DONE. Reboot when ready:  sudo reboot"
echo "After reboot, fingerprint the boot before trusting any result:"
echo "    uname -a                      # release AND the real build timestamp"
echo "    md5sum /boot/vmlinuz-\$(uname -r)"
echo "    sha256sum /sys/kernel/notes"
case "$SLOT" in
*-kasan)
	echo "  then the debug-specific checks:"
	echo "    zgrep -E 'KASAN|PROVE_LOCKING|PSTORE_CONSOLE|DMA_API_DEBUG' /proc/config.gz"
	echo "    sudo dmesg | grep -Ei 'kasan|lockdep|pstore|ramoops'"
	;;
*)
	echo "    sudo bash $HERE/validate-combined.sh"
	;;
esac
echo
echo "ROLLBACK: there is no kernel-selection boot menu. From the prepared rescue"
echo "  boot, use $HERE/kernel-revert.sh --auto switch <version>, or --auto"
echo "  reinstall <known-good-image.deb> <known-good-dtb.deb>."
echo "  Boot state captured this run: $backup_dir"
echo "  Restore $ENV_FILE.bak-preinstall-* as needed. See install.md section 3."
