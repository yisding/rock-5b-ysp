#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: GPL-2.0-only
#
# Create the dedicated Armbian checkout used by PPA source staging. The linked
# Git worktree owns its patch/, userpatches/, config, logs, output, and tmp
# state. Its cache is deliberately a link to the primary checkout: Armbian's
# KERNEL_EXTRA_DIR gives the PPA a distinct kernel source worktree inside that
# cache, while the large kernel Git mirror and central ccache stay single-copy.
set -euo pipefail

say() { printf '>>> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YSP="$(cd "$HERE/../.." && pwd)"
CODE="$(cd "$YSP/.." && pwd)"
ROCK5B_WORKSPACE="${ROCK5B_WORKSPACE:-$CODE/rock-5b}"
WORKSPACE="${WORKSPACE:-$ROCK5B_WORKSPACE/build/kernel/rock5b-kernel-build}"
PRIMARY_ARMBIAN_BUILD="${PRIMARY_ARMBIAN_BUILD:-$WORKSPACE/armbian-build}"
PPA_ARMBIAN_BUILD="${PPA_ARMBIAN_BUILD:-$WORKSPACE/armbian-build-ppa}"
CHECK=0

usage() {
	cat <<'EOF'
Usage: setup-ppa-armbian-worktree.sh [--check]

Create or verify the dedicated PPA Armbian Git worktree. Override the standard
layout with WORKSPACE=, PRIMARY_ARMBIAN_BUILD=, or PPA_ARMBIAN_BUILD=.

The operation never resets a dirty PPA worktree. If the primary Armbian HEAD
moves, a clean PPA worktree is advanced to that exact commit in detached-HEAD
mode. --check performs no writes and exits nonzero when setup or sync is needed.
EOF
}

case "${1:-}" in
	"") ;;
	--check) CHECK=1 ;;
	-h|--help) usage; exit 0 ;;
	*) usage >&2; die "unknown argument: $1" ;;
esac
[ "$#" -le 1 ] || { usage >&2; die "too many arguments"; }

command -v git >/dev/null || die "git is required"
command -v flock >/dev/null || die "flock is required"
[ -d "$PRIMARY_ARMBIAN_BUILD" ] || die "primary Armbian checkout not found: $PRIMARY_ARMBIAN_BUILD"
PRIMARY_ARMBIAN_BUILD="$(realpath -e -- "$PRIMARY_ARMBIAN_BUILD")"
git -C "$PRIMARY_ARMBIAN_BUILD" rev-parse --git-dir >/dev/null 2>&1 ||
	die "primary Armbian path is not a Git checkout: $PRIMARY_ARMBIAN_BUILD"

WORKSPACE="$(realpath -m -- "$WORKSPACE")"
PPA_ARMBIAN_BUILD="$(realpath -m -- "$PPA_ARMBIAN_BUILD")"
case "$PPA_ARMBIAN_BUILD" in
	"$WORKSPACE"/*) ;;
	*) die "PPA Armbian worktree must stay under $WORKSPACE: $PPA_ARMBIAN_BUILD" ;;
esac
[ "$PPA_ARMBIAN_BUILD" != "$PRIMARY_ARMBIAN_BUILD" ] ||
	die "primary and PPA Armbian paths must differ"

primary_head="$(git -C "$PRIMARY_ARMBIAN_BUILD" rev-parse HEAD)"
setup_lock="$WORKSPACE/.ysp-armbian-worktree-setup.lock"
if [ "$CHECK" != 1 ]; then
	mkdir -p "$WORKSPACE"
	exec 7>"$setup_lock"
	flock -n 7 || die "another Armbian worktree setup is running"
fi

if [ ! -e "$PPA_ARMBIAN_BUILD" ]; then
	if [ "$CHECK" = 1 ]; then
		say "MISSING PPA Armbian worktree: $PPA_ARMBIAN_BUILD"
		exit 1
	fi
	say "creating PPA Armbian Git worktree at $PPA_ARMBIAN_BUILD"
	git -C "$PRIMARY_ARMBIAN_BUILD" worktree add --detach "$PPA_ARMBIAN_BUILD" "$primary_head"
elif ! git -C "$PPA_ARMBIAN_BUILD" rev-parse --git-dir >/dev/null 2>&1; then
	die "existing PPA path is not an Armbian Git worktree: $PPA_ARMBIAN_BUILD"
fi

primary_common="$(git -C "$PRIMARY_ARMBIAN_BUILD" rev-parse --path-format=absolute --git-common-dir)"
ppa_common="$(git -C "$PPA_ARMBIAN_BUILD" rev-parse --path-format=absolute --git-common-dir)"
[ "$(realpath -e -- "$primary_common")" = "$(realpath -e -- "$ppa_common")" ] ||
	die "PPA checkout does not share the primary Armbian Git repository"

ppa_dirty="$(GIT_OPTIONAL_LOCKS=0 git -C "$PPA_ARMBIAN_BUILD" status --porcelain --untracked-files=no)"
ppa_head="$(git -C "$PPA_ARMBIAN_BUILD" rev-parse HEAD)"
if [ "$ppa_head" != "$primary_head" ]; then
	[ -z "$ppa_dirty" ] || die "PPA Armbian worktree has tracked modifications; restore it before syncing to $primary_head"
	if [ "$CHECK" = 1 ]; then
		say "STALE PPA Armbian HEAD: $ppa_head (primary is $primary_head)"
		exit 1
	fi
	say "syncing PPA Armbian worktree to primary HEAD $primary_head"
	git -C "$PPA_ARMBIAN_BUILD" checkout --quiet --detach "$primary_head"
elif [ -n "$ppa_dirty" ]; then
	die "PPA Armbian worktree has tracked modifications; run build-kernel.sh --restore against that track"
fi

primary_cache="$PRIMARY_ARMBIAN_BUILD/cache"
ppa_cache="$PPA_ARMBIAN_BUILD/cache"
if [ ! -d "$primary_cache" ]; then
	if [ "$CHECK" = 1 ]; then
		say "MISSING primary Armbian cache: $primary_cache"
		exit 1
	fi
	mkdir -p "$primary_cache"
fi

if [ -L "$ppa_cache" ]; then
	[ "$(realpath -e -- "$ppa_cache")" = "$(realpath -e -- "$primary_cache")" ] ||
		die "PPA cache link does not target the primary cache: $ppa_cache"
elif [ -e "$ppa_cache" ]; then
	die "PPA cache path exists but is not the managed shared-cache link: $ppa_cache"
elif [ "$CHECK" = 1 ]; then
	say "MISSING PPA shared-cache link: $ppa_cache"
	exit 1
else
	ln -s "$primary_cache" "$ppa_cache"
	say "linked PPA cache to $primary_cache"
fi

if [ -L "$PPA_ARMBIAN_BUILD/output" ]; then
	die "PPA output must be track-local, not a symbolic link: $PPA_ARMBIAN_BUILD/output"
elif [ ! -d "$PPA_ARMBIAN_BUILD/output" ]; then
	if [ "$CHECK" = 1 ]; then
		say "MISSING track-local PPA output: $PPA_ARMBIAN_BUILD/output"
		exit 1
	fi
	mkdir -p "$PPA_ARMBIAN_BUILD/output"
fi

say "PPA Armbian track ready: $PPA_ARMBIAN_BUILD"
say "  commit: $primary_head"
say "  shared cache: $primary_cache"
say "  independent state: patch/ userpatches/ config/ output/ .tmp/ logs"
