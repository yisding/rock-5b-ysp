#!/usr/bin/env bash
# =============================================================================
# make-fallback-kernel-deb.sh  —  repackage an Armbian kernel deb so it
# CO-INSTALLS alongside the primary linux-image-current-rockchip64.
#
# WHY: Armbian ships every `current` kernel as the SAME package name
# (linux-image-current-rockchip64) + SAME version (26.08.0-trunk), so a plain
# `dpkg -i` of another current build REPLACES the installed one and removes its
# vmlinuz/dtb/modules — you can't keep two `current` kernels. But the files are
# namespaced by kernel version (vmlinuz-<kver>, /lib/modules/<kver>, dtb-<kver>/)
# and the maintainer scripts are keyed on the hardcoded <kver>, not the package
# name, and there are no Conflicts/Replaces. So: rename the Package (and drop the
# Provides), and the deb becomes a distinct, co-installable package whose files
# never collide with the primary kernel. Result: a permanent, always-present
# recovery kernel that kernel-revert.sh can `switch` to instantly (and that apt
# never autoremoves, since it's a different package).
#
# Use it to keep a known-good 6.18.35 fallback next to the 6.18.37 AV1 build.
#
# USAGE
#   bash make-fallback-kernel-deb.sh [IMAGE_DEB] [DTB_DEB]
#     defaults: the stock 6.18.35 P068c image+dtb debs in armbian-build/output/debs
#   PKG_SUFFIX=fallback OUT=./fallback bash make-fallback-kernel-deb.sh IMG DTB
#
# Then, on the board:
#   sudo dpkg -i fallback/linux-image-fallback-rockchip64_*.deb \
#                fallback/linux-dtb-fallback-rockchip64_*.deb
#   # its postinst makes 6.18.35 active; put your daily kernel back:
#   sudo bash kernel-revert.sh switch 6.18.37-current-rockchip64
#   # from now on, recovery is just:
#   sudo bash kernel-revert.sh --auto switch 6.18.35-current-rockchip64
# =============================================================================
set -euo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
	sed -n '2,32p' "$0"
	exit 0
fi

say() { printf '>>> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Lives in the ysp; writes into the external build workspace. Override WORKSPACE
# / DEBS_DIR / OUT / OFFICIAL for another layout.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"       # kernel-drivers/scripts
CODE="$(cd "$HERE/../../.." && pwd)"                        # ~/Code
WORKSPACE="${WORKSPACE:-$CODE/kernel/rock5b-kernel-build}"
DEBS_DIR="${DEBS_DIR:-$WORKSPACE/armbian-build/output/debs}"
PKG_SUFFIX="${PKG_SUFFIX:-fallback}"
OUT="${OUT:-$WORKSPACE/forward-port/fallback}"

# Default source pair: prefer the OFFICIAL Armbian 6.18.35 (release 26.5.1) staged
# in official-src/, else fall back to a local stock 6.18.35 build in output/debs.
# Fetch the official pair with:
#   mkdir -p official-src && ( cd official-src && apt-get download \
#       linux-image-current-rockchip64=26.5.1 linux-dtb-current-rockchip64=26.5.1 )
OFFICIAL="$WORKSPACE/forward-port/official-src"
first_match() {
	local pattern file newest
	for pattern in "$@"; do
		newest=""
		while IFS= read -r file; do
			[ -f "$file" ] || continue
			if [ -z "$newest" ] || [ "$file" -nt "$newest" ]; then
				newest="$file"
			fi
		done < <(compgen -G "$pattern" || true)
		if [ -n "$newest" ]; then
			printf '%s\n' "$newest"
			return 0
		fi
	done
	return 1
}
IMG="${1:-$(first_match "$OFFICIAL/linux-image-current-rockchip64_26.5.1_arm64*.deb" "$DEBS_DIR/linux-image-current-rockchip64_*6.18.35*P068c*.deb")}"
DTB="${2:-$(first_match "$OFFICIAL/linux-dtb-current-rockchip64_26.5.1_arm64*.deb"   "$DEBS_DIR/linux-dtb-current-rockchip64_*6.18.35*P068c*.deb")}"
[ -f "${IMG:-}" ] || die "image deb not found (pass it as arg 1). Looked in $DEBS_DIR"
[ -f "${DTB:-}" ] || die "dtb deb not found (pass it as arg 2). Looked in $DEBS_DIR"

command -v dpkg-deb >/dev/null || die "dpkg-deb not found"
mkdir -p "$OUT"

# repack_one <in.deb> <old-pkg> <new-pkg>  -> echoes the built deb path
repack_one() {
	local in="$1" oldpkg="$2" newpkg="$3" tmp kver ctrl out contents
	tmp="$(mktemp -d)"
	dpkg-deb -R "$in" "$tmp"
	ctrl="$tmp/DEBIAN/control"
	# derive <kver> from the shipped vmlinuz-/dtb- entry (no head-on-pipe -> no SIGPIPE)
	contents="$(dpkg-deb -c "$in")"
	kver="$(printf '%s\n' "$contents" | grep -oE '(vmlinuz|dtb)-[0-9][^ /]+' | sed -E 's/^(vmlinuz|dtb)-//' | sort -u)"
	kver="${kver%%$'\n'*}"
	# 1) Rename the package + drop Provides so it doesn't masquerade as the primary
	#    linux-image (which would confuse apt's kernel handling). Files/maintainer
	#    scripts keep their hardcoded <kver>, so behavior is unchanged.
	sed -i -E "s/^Package: .*/Package: $newpkg/" "$ctrl"
	sed -i -E "/^Provides:/d" "$ctrl"
	sed -i -E "s/^Description: .*/Description: Co-installable recovery kernel ($kver) — repackaged so it never clobbers the primary current kernel. Managed via kernel-revert.sh./" "$ctrl"
	# 2) Move the doc dir to the new package name, else its changelog/copyright FILES
	#    collide with the primary package on co-install (dpkg overwrite error).
	if [ -d "$tmp/usr/share/doc/$oldpkg" ]; then
		mv "$tmp/usr/share/doc/$oldpkg" "$tmp/usr/share/doc/$newpkg"
	fi
	# 3) Regenerate md5sums so it matches the renamed paths (keeps dpkg --verify clean).
	( cd "$tmp" && find . -type f -not -path './DEBIAN/*' -printf '%P\0' | LC_ALL=C sort -z \
		| xargs -0 md5sum > DEBIAN/md5sums )
	out="$OUT/${newpkg}_${kver}.deb"
	dpkg-deb --build --root-owner-group "$tmp" "$out" >/dev/null
	rm -rf "$tmp"
	echo "$out"
}

say "source image deb: $(basename "$IMG")"
say "source dtb   deb: $(basename "$DTB")"
IMG_OUT="$(repack_one "$IMG" linux-image-current-rockchip64 "linux-image-$PKG_SUFFIX-rockchip64")"
DTB_OUT="$(repack_one "$DTB" linux-dtb-current-rockchip64   "linux-dtb-$PKG_SUFFIX-rockchip64")"

say "built co-installable fallback debs:"
for f in "$IMG_OUT" "$DTB_OUT"; do
	printf '    %s\n' "$f"
	dpkg-deb -f "$f" Package Version | sed 's/^/        /'
done
echo
say "install on the board (co-installs; does NOT remove the current kernel):"
echo "    sudo dpkg -i '$IMG_OUT' '$DTB_OUT'"
echo "    sudo bash $(dirname "${BASH_SOURCE[0]}")/kernel-revert.sh switch 6.18.37-current-rockchip64   # keep your daily kernel active"
echo
say "then recovery from an SD rescue is just:"
echo "    sudo bash kernel-revert.sh --auto switch <the 6.18.35 kver>"
