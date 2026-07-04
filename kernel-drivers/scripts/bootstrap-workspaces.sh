#!/usr/bin/env bash
# =============================================================================
# bootstrap-workspaces.sh — reconstruct the external build + conformance
# workspaces from their pins, so a fresh machine can build kernels and run the
# conformance suites. The workspaces are deliberately NOT in git (they are ~99%
# vendored git checkouts + multi-GB build output); this repo is their source of
# truth for the authored scripts, and this script clones the rest.
#
# It sets up two sibling dirs under ~/Code (override via env):
#   WORKSPACE       (default ~/Code/kernel/rock5b-kernel-build) — Armbian build tree
#   CONFORMANCE_DIR (default ~/Code/rockchip-conformance)       — userspace test bundle
#
# Idempotent: existing checkouts are left alone (it never clobbers local work).
#
#   bash bootstrap-workspaces.sh              # clone anything missing, deploy skeleton
#   bash bootstrap-workspaces.sh --check      # report only, clone nothing
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"      # kernel-drivers/scripts
YSP="$(cd "$HERE/../.." && pwd)"                          # ysp repo root
CODE="$(cd "$YSP/.." && pwd)"                             # ~/Code
CONF_SKEL="$HERE/../tests/conformance"                   # tracked conformance skeleton

WORKSPACE="${WORKSPACE:-$CODE/kernel/rock5b-kernel-build}"
CONFORMANCE_DIR="${CONFORMANCE_DIR:-$CODE/rockchip-conformance}"
ARMBIAN_REMOTE="${ARMBIAN_REMOTE:-https://github.com/armbian/build.git}"
ARMBIAN_BRANCH="${ARMBIAN_BRANCH:-main}"
CHECK=0; [ "${1:-}" = "--check" ] && CHECK=1

say()  { printf '>>> %s\n' "$*"; }
have() { [ -e "$1" ]; }

clone_at() { # remote branch commit dest
	local remote="$1" branch="$2" commit="$3" dest="$4"
	if have "$dest/.git"; then say "  have   $dest"; return 0; fi
	if [ "$CHECK" = 1 ]; then say "  MISSING $dest  ($remote @ ${commit:-$branch})"; return 0; fi
	say "  clone  $dest  <- $remote"
	git clone --quiet "$remote" "$dest"
	if [ -n "$commit" ] && [ "$commit" != "-" ]; then
		git -C "$dest" checkout --quiet "$commit" 2>/dev/null \
			|| say "    WARN: pinned commit $commit not found — left on $branch tip"
	fi
}

say "WORKSPACE       = $WORKSPACE"
say "CONFORMANCE_DIR = $CONFORMANCE_DIR"
echo

say "1) Armbian build tree (the kernel build engine)"
mkdir -p "$WORKSPACE"
clone_at "$ARMBIAN_REMOTE" "$ARMBIAN_BRANCH" "" "$WORKSPACE/armbian-build"
# ccache hardening: key the cache on compiler CONTENT, not mtime. Armbian rebuilds
# its Docker image periodically (fresh `apt install gcc` => new gcc mtime); with the
# default compiler_check=mtime that invalidates the ENTIRE cache => a full ~90 min
# cold build on unchanged source. `content` hashes the compiler bytes so a
# reinstalled-but-identical gcc still hits. The in-container ccache reads this via
# CCACHE_DIR=/armbian/cache/ccache.
if [ "$CHECK" = 0 ]; then
	CC_DIR="$WORKSPACE/armbian-build/cache/ccache"; mkdir -p "$CC_DIR"
	if ! grep -qs '^compiler_check *= *content' "$CC_DIR/ccache.conf" 2>/dev/null; then
		printf 'compiler_check = content\nmax_size = 15.0G\n' >> "$CC_DIR/ccache.conf"
		say "  hardened ccache.conf (compiler_check=content, max_size=15G)"
	else say "  ccache.conf already hardened"; fi
fi

echo; say "2) Conformance userspace source checkouts (pinned in MANIFEST.tsv)"
mkdir -p "$CONFORMANCE_DIR"
# MANIFEST columns: name  path  remote  branch  commit  purpose
tail -n +2 "$CONF_SKEL/MANIFEST.tsv" | while IFS=$'\t' read -r name path remote branch commit _rest; do
	[ -n "${remote:-}" ] || continue
	clone_at "$remote" "$branch" "$commit" "$CONFORMANCE_DIR/$path"
done

echo; say "3) Deploy the tracked conformance skeleton into the working bundle"
if [ "$CHECK" = 1 ]; then
	say "  (check) would deploy scripts/ MANIFEST.tsv profiles/ README.md -> $CONFORMANCE_DIR"
else
	# scripts run in place (ROOT = the conformance dir); keep the authored skeleton in sync.
	mkdir -p "$CONFORMANCE_DIR/scripts" "$CONFORMANCE_DIR/profiles" "$CONFORMANCE_DIR/assets"
	cp -r "$CONF_SKEL/scripts/."  "$CONFORMANCE_DIR/scripts/"
	cp -r "$CONF_SKEL/profiles/." "$CONFORMANCE_DIR/profiles/"
	cp    "$CONF_SKEL/MANIFEST.tsv" "$CONF_SKEL/README.md" "$CONFORMANCE_DIR/"
	say "  deployed."
fi

echo; say "DONE. Next:"
say "  Build a kernel deb:   bash $HERE/build-armbian-deb.sh"
say "  Build MPP test bins:  bash $CONFORMANCE_DIR/scripts/build-mpp.sh"
say "  Run the suites:       PROFILE=forward-port bash $HERE/../tests/rewrite-conformance-run.sh"
