#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: GPL-2.0-only
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
# one never disturbs another's FILES (see docs/kernel-builds.md "Package slots").
# Verified: the three debs' 32,692 paths share nothing with the 70,841 paths of
# the installed kernel packages beyond plain directories.
#
# It DOES take over the next boot, and that distinction is the whole reason for
# the recovery gate below. /boot/Image, /boot/dtb, /boot/uInitrd, /boot/vmlinuz
# and /boot/initrd.img belong to no package -- maintainer scripts and initramfs
# hooks repoint them at whatever was installed last. So the previous kernel
# survives on disk and can be selected again with kernel-revert.sh, but you do
# not get there without booting something first.
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
#        BOOT_CMD=, BOOT_SCR=, BACKUP_ROOT=, ENV=, ALLOW_OVERSIZE_IMAGE=1.
# =============================================================================
set -uo pipefail
# Print between the header's opening and closing rules rather than from a
# hardcoded line number. SPDX metadata now precedes the opening rule, and a
# fixed range silently truncates whenever the header gains a paragraph.
[ "${1:-}" != "-h" ] && [ "${1:-}" != "--help" ] || {
	sed -n '0,/^# =\{20,\}$/d; /^# =\{20,\}$/q; p' "$0"
	exit 0
}
[ "$(id -u)" -eq 0 ] || {
	echo "Run as root:  sudo RECOVERY_READY=1 PHASH='P####-C####' bash $0"
	exit 1
}

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODE="$(cd "$HERE/../../.." && pwd)"                        # ~/Code
ROCK5B_WORKSPACE="${ROCK5B_WORKSPACE:-$CODE/rock-5b}"
WORKSPACE="${WORKSPACE:-$ROCK5B_WORKSPACE/build/kernel/rock5b-kernel-build}"
DEBS="${DEBS:-${ARMBIAN_BUILD:-$WORKSPACE/armbian-build}/output/debs}"
BACKUP_ROOT="${BACKUP_ROOT:-$WORKSPACE/boot-backups}"
ENV_FILE="${ENV:-/boot/armbianEnv.txt}"
BOOT_CMD="${BOOT_CMD:-/boot/boot.cmd}"
BOOT_SCR="${BOOT_SCR:-/boot/boot.scr}" # what U-Boot actually executes
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
	# Family-agnostic: Armbian renamed rock-5b's family rockchip64 ->
	# rockchip-rk3588, so matching the old suffixes alone would stop recognising
	# Armbian's own slots.
	current | current-* | ysp | ysp-*)
		echo "REFUSING: '$s' is not ours. current-* is Armbian's stock kernel and" >&2
		echo "  ysp-* is the PPA lineage (install that one with apt)." >&2
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
	# Refuse rather than guess. PHASH is an unanchored substring, so a partial
	# value like "Cc271" matches several builds; the old `sort -V | tail -1`
	# then picked one by version-sorting a HASH, which is meaningless ordering --
	# with P9999 (new) against P0001 (old) it silently chose the old build.
	if [ "${#matches[@]}" -gt 1 ]; then
		echo "AMBIGUOUS: PHASH=$PHASH matches ${#matches[@]} ${package} debs:" >&2
		printf '    %s\n' "${matches[@]##*/}" >&2
		echo "  Give the full P####-C#### pair printed by build-kernel.sh." >&2
		return 2
	fi
	printf '%s\n' "${matches[0]}"
}

if [ -z "$PHASH" ]; then
	echo "Set PHASH to the build hash printed by build-kernel.sh, e.g.:"
	echo "  sudo RECOVERY_READY=1 PHASH='Pd745-Cb831' bash $0"
	echo "  recent image debs across all slots:"
	find "$DEBS" -maxdepth 1 -type f -name 'linux-image-video-*_*.deb' \
		-printf '      %f\n' 2>/dev/null | sort -V | tail -8
	exit 1
fi

# The deb filename carries the slot, the LINUXFAMILY and the PHASH, so all of it
# is derivable -- asking again is just a chance to get it wrong. SLOT stays
# available to disambiguate, and is required only if one PHASH somehow matches
# builds in more than one slot.
#
# THE FAMILY IS DISCOVERED, NOT ASSUMED. This used to hardcode "-rockchip64" and
# broke completely when Armbian renamed rock-5b's BOARDFAMILY to rockchip-rk3588:
# the built deb is linux-image-video-port-kasan-rockchip-rk3588_..., every glob
# missed it, and a perfectly good kernel could not be installed by its own
# installer. The artifacts are the authority here -- they are the thing about to
# be installed, and they carry whatever name Armbian actually used.
#
# LONGEST SLOT WINS. OUR_SLOTS holds both video-port and video-port-kasan, and
# "video-port" is a prefix of the kasan deb's name. Matching shortest-first would
# install a KASAN kernel while reporting it as the production one -- a silent
# wrong-kernel install, which is worse than failing.
#
# Emits "<slot> <family>" on stdout.
infer_slot_and_family() {
	local f base rest s slot family pairs=() uniq=()
	while IFS= read -r -d '' f; do
		base="$(basename "$f")"
		rest="${base#linux-image-}"
		rest="${rest%%_*}" # -> e.g. video-port-kasan-rockchip-rk3588
		slot=""
		family=""
		for s in "${OUR_SLOTS[@]}"; do
			case "$rest" in
			"$s"-*)
				if [ "${#s}" -gt "${#slot}" ]; then
					slot="$s"
					family="${rest#"$s"-}"
				fi
				;;
			esac
		done
		[ -n "$slot" ] && [ -n "$family" ] || continue
		pairs+=("$slot $family")
	done < <(find "$DEBS" -maxdepth 1 -type f -name "linux-image-*_*${PHASH}*.deb" -print0)

	# Guard the empty case BEFORE printf: `printf '%s\n'` with no arguments still
	# emits one blank line, so mapfile would produce a single empty element and
	# the case below would report success with an empty slot and family --
	# yielding PKG_SUFFIX="-" and a nonsense install. Caught by testing the
	# no-match path rather than only the happy one.
	[ "${#pairs[@]}" -gt 0 ] || return 1
	# Honour an explicit SLOT=. Without this filter the ambiguity path returns 2
	# regardless of SLOT, so the very instruction this function prints
	# ("Re-run with SLOT=<one of the above>") could never work.
	if [ -n "${SLOT_REQUESTED:-}" ]; then
		local kept=()
		for s in "${pairs[@]}"; do
			[ "${s%% *}" = "$SLOT_REQUESTED" ] && kept+=("$s")
		done
		pairs=(${kept[@]+"${kept[@]}"})
		[ "${#pairs[@]}" -gt 0 ] || return 1
	fi
	mapfile -t uniq < <(printf '%s\n' "${pairs[@]}" | sort -u)
	case "${#uniq[@]}" in
	1) printf '%s\n' "${uniq[0]}" ;;
	0) return 1 ;;
	*)
		echo "AMBIGUOUS: PHASH=$PHASH matches ${#uniq[@]} slot/family combinations:" >&2
		printf '    %s\n' "${uniq[@]}" >&2
		echo "  Re-run with SLOT=<one of the slots above>." >&2
		return 2
		;;
	esac
}

echo "================= STEP 1: locate the built debs ================="
SLOT_FAMILY=""
SLOT_REQUESTED="$SLOT"
# Capture the function's OWN status. `if ! cmd; then rc=$?` always yields 0 --
# the `!` inverts the status before $? is read -- so the AMBIGUOUS return of 2
# was dead code and that path printed two contradictory diagnoses in one run.
INFER_OUT="$(infer_slot_and_family)" || rc=$?
rc="${rc:-0}"
if [ "$rc" -ne 0 ]; then
	[ "$rc" = 2 ] && exit 2
	echo "  no image deb in any of our slots matches PHASH=$PHASH" >&2
	# Builds predating the slot split landed in Armbian's own current-* slot. Say
	# so rather than claiming the deb is missing.
	if compgen -G "$DEBS/linux-image-current-*_*${PHASH}*.deb" >/dev/null; then
		echo "  BUT a matching deb exists in an Armbian current-* slot -- that is a" >&2
		echo "  pre-slot-split build sitting in Armbian's slot. Rebuild it with" >&2
		echo "  build-kernel.sh so it lands in its own slot; this script will not" >&2
		echo "  install into Armbian's slot." >&2
		exit 1
	fi
	echo "  recent image debs across our slots:" >&2
	find "$DEBS" -maxdepth 1 -type f -name 'linux-image-video-*_*.deb' \
		-printf '      %f\n' 2>/dev/null | sort -V | tail -8 >&2
	exit 1
fi
read -r INFERRED_SLOT SLOT_FAMILY <<<"$INFER_OUT"
if [ -n "$SLOT_REQUESTED" ] && [ "$SLOT_REQUESTED" != "$INFERRED_SLOT" ]; then
	echo "SLOT=$SLOT_REQUESTED was given, but PHASH=$PHASH belongs to $INFERRED_SLOT." >&2
	echo "  Refusing rather than installing a kernel into a slot it was not built for." >&2
	exit 2
fi
SLOT="$INFERRED_SLOT"
validate_slot "$SLOT" || exit 2
echo "  slot inferred from PHASH:   $SLOT"
echo "  family read from deb name:  $SLOT_FAMILY"
PKG_SUFFIX="${SLOT}-${SLOT_FAMILY}"
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

# The three debs are located by three INDEPENDENT searches, so nothing so far
# guarantees they came from the same build. An image paired with a DTB from a
# different build is the exact combination that boots to a dead device tree.
# Armbian stamps the full source/config/patch identity into each package.
orig_hash() { dpkg -f "$1" Armbian-Original-Hash 2>/dev/null; }
IMG_HASH="$(orig_hash "$IMG")"
[ -n "$IMG_HASH" ] || {
	echo "  ABORT: $(basename "$IMG") has no Armbian-Original-Hash to verify against" >&2
	exit 1
}
for f in "$DTB" ${HDR:+"$HDR"}; do
	[ -f "$f" ] || continue
	h="$(orig_hash "$f")"
	[ "$h" = "$IMG_HASH" ] || {
		echo "  ABORT: $(basename "$f") is from a different build than the image." >&2
		echo "    image: $IMG_HASH" >&2
		echo "    this : ${h:-<none>}" >&2
		echo "  Installing a mismatched image/DTB pair boots to a dead device tree." >&2
		exit 1
	}
done
echo "  all packages agree: $IMG_HASH"
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
# U-Boot executes boot.scr, NOT boot.cmd. boot.cmd is source text; boot.scr is
# the mkimage-wrapped copy, and nothing enforces that they agree. Reading only
# boot.cmd made this preflight fail OPEN in the one case that matters:
# set-boot-load-addresses.sh writes boot.cmd first and regenerates boot.scr
# second, so an mkimage failure between those steps leaves boot.cmd raised and
# boot.scr stock. The preflight would then read the raised value, report "fits
# with 60 MiB spare", install -- and U-Boot would boot with the stock map,
# clearing BSS over the FDT. No console, no serial, no ramoops.
#
# So read BOTH and refuse to guess when they disagree.
addr_from_file() { # name file [strings]
	local name="$1" file="$2" mode="${3:-text}" reader
	[[ -r "$file" ]] || return 1
	if [ "$mode" = strings ]; then reader=(strings -a "$file"); else reader=(cat "$file"); fi
	"${reader[@]}" 2>/dev/null |
		sed -n "s/^[[:space:]]*setenv[[:space:]]\+${name}[[:space:]]\+\"\?\([0-9a-fA-Fx]\+\)\"\?[[:space:]]*\$/\1/p" |
		tail -1
}

uboot_addr() { # name stock-default -- last setenv wins, as in U-Boot
	local name="$1" fallback="$2" v_cmd v_scr
	v_cmd="$(addr_from_file "$name" "$BOOT_CMD" text || true)"
	v_scr="$(addr_from_file "$name" "$BOOT_SCR" strings || true)"
	v_cmd="${v_cmd:-$fallback}"
	v_scr="${v_scr:-$fallback}"
	if [ "$v_cmd" != "$v_scr" ]; then
		cat >&2 <<EOF
ABORT: $(basename "$BOOT_CMD") and $(basename "$BOOT_SCR") disagree on $name.
  $BOOT_CMD  $v_cmd
  $BOOT_SCR  $v_scr
  U-Boot executes $(basename "$BOOT_SCR"); the other file is only its source.
  A half-applied load-address change looks exactly like this, and installing on
  top of it produces a kernel that cannot boot or print why.
  Regenerate with:  sudo bash "$HERE/debug-kernel/set-boot-load-addresses.sh"
EOF
		exit 1
	fi
	printf '%s\n' "$v_scr"
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
	# Deliberately FATAL. This used to warn and continue, which meant the single
	# gate protecting the board from an unbootable kernel silently disabled itself
	# whenever anything in the extraction pipeline changed -- a missing python3, a
	# tar path-prefix change, or an EFI-zboot/compressed Image with no raw arm64
	# magic at offset 56. A check that cannot run is not a passing check.
	cat >&2 <<EOF
ABORT: could not read the arm64 Image header from $(basename "$IMG").
  The load-address preflight cannot run, and it is the only thing standing
  between an oversized kernel and a board that boots to nothing.
  Check that python3, dpkg-deb and tar are present and that the deb contains
  ./boot/vmlinuz-*. Override with ALLOW_OVERSIZE_IMAGE=1 only if you have
  confirmed by other means that the kernel fits.
EOF
	[ "${ALLOW_OVERSIZE_IMAGE:-0}" = 1 ] || exit 1
	echo "  ALLOW_OVERSIZE_IMAGE=1 set; continuing without a size check." >&2
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
# boot.cmd and boot.scr are in this list because they decide whether the kernel
# below can boot at all -- see the preflight's boot.scr cross-check. Backing up
# the kernel without them leaves the half that chooses load addresses unrecovered.
for path in \
	/boot/armbianEnv.txt /boot/Image /boot/vmlinuz /boot/uInitrd /boot/dtb \
	/boot/initrd.img "$BOOT_CMD" "$BOOT_SCR" \
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
# The DTB package's preinst does `rm -rf /boot/dtb` at UNPACK time and only
# recreates the symlink in postinst at CONFIGURE time. Anything that kills dpkg
# in between -- interrupt, ENOSPC, a failing /etc/kernel/postinst.d hook --
# leaves /boot/dtb absent, and boot.cmd loads the FDT with no error check, so the
# board will not boot. Passing all three debs to one dpkg -i maximised that
# window: ~27,600 header files unpacked while the symlink was already gone.
# Install the DTB last and by itself to make the window as small as possible.
if [ -f "$HDR" ]; then
	dpkg -i "$IMG" "$HDR" || { echo "  dpkg failed -- inspect above"; exit 1; }
else
	dpkg -i "$IMG" || { echo "  dpkg failed -- inspect above"; exit 1; }
fi
dpkg -i "$DTB" || { echo "  dpkg failed on the DTB package -- inspect above"; exit 1; }
[ -e /boot/dtb ] || {
	echo "  ABORT: /boot/dtb is missing after installing the DTB package." >&2
	echo "  The board will NOT boot in this state. Restore from $backup_dir" >&2
	echo "  before rebooting: cp -a $backup_dir/dtb* /boot/" >&2
	exit 1
}
echo
echo "  holding $PKG_SUFFIX so apt cannot overwrite this build"
# Report failure: a silently-failed hold lets a later `apt upgrade` re-point the
# boot symlinks away from this build.
apt-mark hold "linux-image-${PKG_SUFFIX}" "linux-dtb-${PKG_SUFFIX}" \
	${HDR:+"linux-headers-${PKG_SUFFIX}"} >/dev/null ||
	echo "  WARNING: apt-mark hold failed; apt may overwrite this build later" >&2
echo

echo "================= STEP 6: verify ================="
# ASSERT, do not narrate. This step used to print /boot/Image and an arbitrary
# recently-modified DTB without ever checking that either pointed at the build
# just installed -- so a boot pointer left on the OLD kernel looked identical to
# success. The release string comes from the package itself.
INSTALLED_RELEASE="$(dpkg -f "$IMG" Armbian-Kernel-Version-Family 2>/dev/null)"
[ -n "$INSTALLED_RELEASE" ] || INSTALLED_RELEASE="${IMG##*linux-image-}"
verify_link() { # label path expected-substring
	local label="$1" path="$2" want="$3" got
	got="$(readlink -f "$path" 2>/dev/null || true)"
	if [ -z "$got" ]; then
		echo "  FAIL $label -> (missing)" >&2
		return 1
	fi
	case "$got" in
	*"$want"*) echo "  ok   $label -> $got" ;;
	*)
		echo "  FAIL $label -> $got" >&2
		echo "       expected it to point at $want" >&2
		return 1
		;;
	esac
}
verify_rc=0
verify_link "/boot/Image" /boot/Image "$INSTALLED_RELEASE" || verify_rc=1
verify_link "/boot/dtb" /boot/dtb "$INSTALLED_RELEASE" || verify_rc=1
[ -e "/boot/uInitrd-$INSTALLED_RELEASE" ] &&
	echo "  ok   initrd built for $INSTALLED_RELEASE" ||
	echo "  WARN no /boot/uInitrd-$INSTALLED_RELEASE (initramfs hook may not have run)" >&2
if [ "$verify_rc" -ne 0 ]; then
	echo >&2
	echo "  The boot pointers do NOT reference the kernel just installed." >&2
	echo "  DO NOT REBOOT. Restore from $backup_dir first." >&2
	exit 1
fi
NEWDTB="/boot/dtb-$INSTALLED_RELEASE/rockchip/rk3588-rock-5b.dtb"
if [ -f "$NEWDTB" ]; then
	echo "  vendor nodes in its dtb: $(dtc -I dtb -O dts "$NEWDTB" 2>/dev/null | grep -cE 'rkv-encoder-v2-core|rkv-decoder-v2"|rga3_core0')"
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
