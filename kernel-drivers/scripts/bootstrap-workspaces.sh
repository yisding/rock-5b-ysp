#!/usr/bin/env bash
# =============================================================================
# bootstrap-workspaces.sh — reconstruct the external build + conformance
# workspaces, so a fresh machine can build kernels and run the
# conformance suites. The workspaces are deliberately NOT in git (they are ~99%
# vendored git checkouts + multi-GB build output); this repo is their source of
# truth for the authored scripts. Armbian follows the configured branch (main by
# default); conformance sources use the commits in MANIFEST.tsv.
#
# It sets up two directories under ~/Code/rock-5b (override via env):
#   WORKSPACE       (default ~/Code/rock-5b/build/kernel/rock5b-kernel-build)
#                   — Armbian build tree
#   CONFORMANCE_DIR (default ~/Code/rock-5b/build/rockchip-conformance)
#                   — userspace test bundle
#
# Idempotent: existing checkouts are left alone (it never clobbers local work).
#
#   bash bootstrap-workspaces.sh              # clone anything missing, deploy skeleton
#   bash bootstrap-workspaces.sh --check      # report only, clone nothing
#   ARMBIAN_BRANCH=v26.05 bash bootstrap-workspaces.sh  # branch for a new clone
# Existing checkouts are reported with branch@commit and never moved.
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"      # kernel-drivers/scripts
YSP="$(cd "$HERE/../.." && pwd)"                          # ysp repo root
CODE="$(cd "$YSP/.." && pwd)"                             # ~/Code
ROCK5B_WORKSPACE="${ROCK5B_WORKSPACE:-$CODE/rock-5b}"
CONF_SKEL="$HERE/../tests/conformance"                   # tracked conformance skeleton

WORKSPACE="${WORKSPACE:-$ROCK5B_WORKSPACE/build/kernel/rock5b-kernel-build}"
CONFORMANCE_DIR="${CONFORMANCE_DIR:-$ROCK5B_WORKSPACE/build/rockchip-conformance}"
ARMBIAN_REMOTE="${ARMBIAN_REMOTE:-https://github.com/armbian/build.git}"
ARMBIAN_BRANCH="${ARMBIAN_BRANCH:-main}"
CHECK=0; [ "${1:-}" = "--check" ] && CHECK=1

say()  { printf '>>> %s\n' "$*"; }
have() { [ -e "$1" ]; }

clone_at() { # remote branch commit dest
	local remote="$1" branch="$2" commit="$3" dest="$4"
	local head current_branch
	local -a clone_args
	if have "$dest/.git"; then
		head="$(git -C "$dest" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
		current_branch="$(git -C "$dest" symbolic-ref --quiet --short HEAD 2>/dev/null || echo detached)"
		say "  have   $dest  ($current_branch@$head)"
		return 0
	fi
	if [ "$CHECK" = 1 ]; then say "  MISSING $dest  ($remote @ ${commit:-$branch})"; return 0; fi
	say "  clone  $dest  <- $remote"
	clone_args=(--quiet)
	[ -n "$branch" ] && [ "$branch" != "-" ] && clone_args+=(--branch "$branch")
	git clone "${clone_args[@]}" "$remote" "$dest"
	if [ -n "$commit" ] && [ "$commit" != "-" ]; then
		git -C "$dest" checkout --quiet "$commit" 2>/dev/null \
			|| say "    WARN: pinned commit $commit not found — left on $branch tip"
	fi
	head="$(git -C "$dest" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
	say "    ready $branch@$head"
}

say "WORKSPACE       = $WORKSPACE"
say "CONFORMANCE_DIR = $CONFORMANCE_DIR"
echo

say "1) Armbian build tree (the kernel build engine)"
mkdir -p "$WORKSPACE"
clone_at "$ARMBIAN_REMOTE" "$ARMBIAN_BRANCH" "" "$WORKSPACE/armbian-build"
# ccache: every build under ~/Code shares ONE store, wired by the tracked helper
# below. The load-bearing setting it applies is compiler_check=content. Armbian
# rebuilds its Docker image periodically (fresh `apt install gcc` => new gcc
# mtime); with the default compiler_check=mtime that invalidates the ENTIRE cache
# => a full ~90 min cold build on unchanged source. `content` hashes the compiler
# bytes so a reinstalled-but-identical gcc still hits. The in-container ccache
# reads the store via CCACHE_DIR=/armbian/cache/ccache, which Docker bind-mounts
# from the symlink the helper creates (Docker resolves a symlinked bind source on
# the host, so the container sees the real store).
if [ "$CHECK" = 0 ]; then
	if bash "$YSP/scripts/centralize-ccache.sh" >/dev/null 2>&1; then
		say "  ccache wired to the shared store at $CODE/.ccache"
	else
		say "  WARNING: ccache not wired; inspect with"
		say "    bash $YSP/scripts/centralize-ccache.sh --status"
	fi
fi

echo; say "2) Conformance userspace source checkouts (pinned in MANIFEST.tsv)"
mkdir -p "$CONFORMANCE_DIR"
# MANIFEST columns: name  path  remote  branch  commit  purpose
tail -n +2 "$CONF_SKEL/MANIFEST.tsv" | while IFS=$'\t' read -r name path remote branch commit _rest; do
	[ -n "${remote:-}" ] || continue
	clone_at "$remote" "$branch" "$commit" "$CONFORMANCE_DIR/$path"
done

echo; say "2b) Apply local source patches (patches/<name>/*.patch)"
# We keep small, reviewed deltas to the vendored sources as patches under the
# tracked skeleton so a fresh clone reproduces them (e.g. redirect the librga
# sample fixtures off the hardcoded Android /data path via $RGA_SAMPLE_DATA_DIR).
# Idempotent: a reverse-apply --check that succeeds means it's already in place.
if [ -d "$CONF_SKEL/patches" ]; then
	for pdir in "$CONF_SKEL/patches"/*/; do
		[ -d "$pdir" ] || continue
		name="$(basename "$pdir")"; dest="$CONFORMANCE_DIR/sources/$name"
		have "$dest/.git" || { say "  skip $name (not cloned)"; continue; }
		for patch in "$pdir"*.patch; do
			[ -e "$patch" ] || continue
			if git -C "$dest" apply --reverse --check "$patch" >/dev/null 2>&1; then
				say "  already applied: $name/$(basename "$patch")"
			elif [ "$CHECK" = 1 ]; then
				say "  WOULD apply: $name/$(basename "$patch")"
			elif git -C "$dest" apply "$patch" >/dev/null 2>&1; then
				say "  applied: $name/$(basename "$patch")"
			else
				say "  WARN: could not apply $name/$(basename "$patch") (locally modified?)"
			fi
		done
	done
else
	say "  (no patches/ dir — nothing to apply)"
fi

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
say "  Build a kernel deb:   bash $HERE/build-kernel.sh forward-port"
say "  Build MPP test bins:  bash $CONFORMANCE_DIR/scripts/build-mpp.sh"
say "  Run the suites:       PROFILE=forward-port bash $HERE/../tests/rewrite-conformance-run.sh"
