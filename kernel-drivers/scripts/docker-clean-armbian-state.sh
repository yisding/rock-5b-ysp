#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: GPL-2.0-only
#
# Remove Docker-owned Armbian state with the same local Armbian build image.
# Host mode is dry-run by default and exposes only three allowlisted actions.
# Container mode is an internal implementation detail invoked with narrow bind
# mounts; it repeats every path check before deleting anything.
set -euo pipefail

DEFAULT_IMAGE="ghcr.io/armbian/docker-armbian-build:armbian-ubuntu-noble-latest"

say() { printf '>>> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }

valid_lane() {
	# Armbian LINUXSOURCEDIR: major.minor__family__arch[__KERNEL_EXTRA_DIR].
	# Accept a lane name, never a free-form relative path or cache directory.
	[[ "$1" =~ ^[0-9]+\.[0-9]+(__[A-Za-z0-9][A-Za-z0-9._-]*){2,3}$ ]]
}

valid_artifact_relative() {
	local relative="$1"
	case "$relative" in
		output/debs/*|output/packages-hashed/*) ;;
		*) return 1 ;;
	esac
	[[ "$relative" != /* && "/$relative/" != *"/../"* && "/$relative/" != *"/./"* && "$relative" != *$'\n'* && "$relative" != *$'\r'* ]]
}

container_artifacts() {
	local relative target resolved
	local -a targets=()
	[ "$#" -gt 0 ] || die "container artifacts mode requires at least one path"

	# Validate the complete set before the first unlink.
	for relative in "$@"; do
		valid_artifact_relative "$relative" || die "artifact path is outside the allowlist: $relative"
		target="/armbian/$relative"
		[ ! -L "$target" ] || die "refusing symbolic-link artifact: $relative"
		[ -f "$target" ] || die "artifact is not a regular file: $relative"
		resolved="$(realpath -e -- "$target")"
		case "$resolved" in
			/armbian/output/debs/*|/armbian/output/packages-hashed/*) ;;
			*) die "resolved artifact escaped the output mount: $relative -> $resolved" ;;
		esac
		targets+=("$target")
	done

	rm -f -- "${targets[@]}"
	find /armbian/output/debs /armbian/output/packages-hashed \
		-mindepth 1 -depth -type d -empty -delete 2>/dev/null || true
}

container_foreign_rewrite() {
	local lane="$1"
	local base lane_root resolved_base
	valid_lane "$lane" || die "invalid kernel worktree lane: $lane"
	lane_root="/armbian/cache/sources/linux-kernel-worktree/$lane"
	base="$lane_root/drivers/video/rockchip"
	[ -d "$base" ] || die "kernel worktree driver directory not found: $base"
	resolved_base="$(realpath -e -- "$base")"
	[ "$resolved_base" = "$base" ] || die "worktree driver path contains a symbolic-link escape: $base -> $resolved_base"
	rm -rf -- "$base/mpp-rewrite" "$base/rga-rewrite"
}

container_worktree() {
	local lane="$1"
	local bare="/armbian/cache/git-bare/kernel"
	local target
	valid_lane "$lane" || die "invalid kernel worktree lane: $lane"
	target="/armbian/cache/sources/linux-kernel-worktree/$lane"
	[ -d "$bare/.git" ] || die "Armbian kernel repository not found: $bare"
	[ -d "$target" ] || die "kernel worktree not found: $target"
	[ ! -L "$target" ] || die "refusing symbolic-link worktree: $target"

	# Armbian records /armbian paths because it creates the worktrees inside this
	# same container mount. Ask Git to remove both the dirty tree and its record;
	# the fixed-path fallback handles an interrupted/incomplete worktree record.
	if ! git \
		-c safe.directory="$bare" \
		-c core.hooksPath=/dev/null \
		-c core.fsmonitor=false \
		-C "$bare" worktree remove --force --force "$target"; then
		rm -rf -- "$target"
	fi
	git \
		-c safe.directory="$bare" \
		-c core.hooksPath=/dev/null \
		-c core.fsmonitor=false \
		-C "$bare" worktree prune
	[ ! -e "$target" ] || die "worktree still exists after removal: $target"
}

container_main() {
	[ "${YSP_ARMBIAN_DOCKER_CLEAN_INTERNAL:-}" = 1 ] ||
		die "internal container mode requires its invocation marker"
	local action="${1:-}"
	shift || true
	case "$action" in
		artifacts) container_artifacts "$@" ;;
		foreign-rewrite)
			[ "$#" -eq 1 ] || die "container foreign-rewrite mode requires one lane"
			container_foreign_rewrite "$1"
			;;
		worktree)
			[ "$#" -eq 1 ] || die "container worktree mode requires one lane"
			container_worktree "$1"
			;;
		*) die "invalid internal container action: ${action:-<empty>}" ;;
	esac
}

if [ "${1:-}" = "__container__" ]; then
	shift
	container_main "$@"
	exit 0
fi

usage() {
	cat <<'USAGE'
Usage:
  docker-clean-armbian-state.sh [options] artifacts RELATIVE_PATH...
  docker-clean-armbian-state.sh [options] foreign-rewrite WORKTREE_LANE
  docker-clean-armbian-state.sh [options] worktree WORKTREE_LANE

Safely remove Docker-owned state from an Armbian build checkout. The default is
a dry run. Paths for `artifacts` must be relative to the checkout and below only
output/debs/ or output/packages-hashed/. `foreign-rewrite` removes only the
mpp-rewrite and rga-rewrite directories from one named kernel worktree.
`worktree` removes the complete named kernel worktree and its Git registration;
the next Armbian build recreates it from the shared bare kernel repository.

Options:
  --armbian-build PATH  Armbian checkout (default: grouped external workspace)
  --image IMAGE         Existing local Armbian build image tag or ID
  --apply               Perform the displayed permanent deletion
  -h, --help            Show this help
USAGE
}

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CODE="$(cd "$ROOT/.." && pwd)"
ROCK5B_WORKSPACE="${ROCK5B_WORKSPACE:-$CODE/rock-5b}"
WORKSPACE="${WORKSPACE:-$ROCK5B_WORKSPACE/build/kernel/rock5b-kernel-build}"
ARMBIAN_BUILD="${ARMBIAN_BUILD:-$WORKSPACE/armbian-build}"
IMAGE="${ARMBIAN_DOCKER_IMAGE:-$DEFAULT_IMAGE}"
APPLY=0

while [ "$#" -gt 0 ]; do
	case "$1" in
		--armbian-build)
			[ "$#" -ge 2 ] || die "--armbian-build requires a path"
			ARMBIAN_BUILD="$2"
			shift 2
			;;
		--image)
			[ "$#" -ge 2 ] || die "--image requires a tag or ID"
			IMAGE="$2"
			shift 2
			;;
		--apply) APPLY=1; shift ;;
		-h|--help) usage; exit 0 ;;
		--) shift; break ;;
		-*) die "unknown option: $1" ;;
		*) break ;;
	esac
done

ACTION="${1:-}"
[ -n "$ACTION" ] || { usage >&2; exit 2; }
shift
case "$ACTION" in
	artifacts) [ "$#" -gt 0 ] || die "artifacts requires at least one relative path" ;;
	foreign-rewrite|worktree) [ "$#" -eq 1 ] || die "$ACTION requires exactly one worktree lane" ;;
	*) die "unknown action: $ACTION" ;;
esac

[ -d "$ARMBIAN_BUILD" ] || die "Armbian build directory not found: $ARMBIAN_BUILD"
ARMBIAN_BUILD="$(realpath -e -- "$ARMBIAN_BUILD")"
WORKSPACE="$(dirname "$ARMBIAN_BUILD")"

LANE=""
if [ "$ACTION" != artifacts ]; then
	LANE="$1"
	valid_lane "$LANE" || die "invalid kernel worktree lane: $LANE"
fi

# Match build-kernel.sh's lock order. A PPA lane removal must not race either
# stage/export or another Armbian patch/build operation.
if [ "$ACTION" != artifacts ] && [[ "$LANE" == *__ppa-forward-port ]]; then
	if [ -n "${YSP_PPA_LOCK_FD:-}" ]; then
		[[ "$YSP_PPA_LOCK_FD" =~ ^[0-9]+$ ]] || die "invalid inherited PPA lock descriptor"
		[ -e "/proc/$$/fd/$YSP_PPA_LOCK_FD" ] || die "inherited PPA lock descriptor is not open"
		flock -n "$YSP_PPA_LOCK_FD" || die "inherited PPA sequence lock is not held"
	else
		exec 8>"$WORKSPACE/.ysp-ppa-forward-port.lock"
		flock -n 8 || die "another ppa-forward-port stage/export is already running"
	fi
fi
if [ -n "${YSP_ARMBIAN_LOCK_FD:-}" ]; then
	[[ "$YSP_ARMBIAN_LOCK_FD" =~ ^[0-9]+$ ]] || die "invalid inherited Armbian lock descriptor"
	[ -e "/proc/$$/fd/$YSP_ARMBIAN_LOCK_FD" ] || die "inherited Armbian lock descriptor is not open"
	flock -n "$YSP_ARMBIAN_LOCK_FD" || die "inherited Armbian state lock is not held"
else
	exec 9>"$WORKSPACE/.ysp-armbian-build.lock"
	flock -n 9 || die "another ysp Armbian kernel stage/build/cleanup is already running"
fi

TARGETS=()
case "$ACTION" in
	artifacts)
		for relative in "$@"; do
			valid_artifact_relative "$relative" || die "artifact path is outside the allowlist: $relative"
			target="$ARMBIAN_BUILD/$relative"
			[ ! -L "$target" ] || die "refusing symbolic-link artifact: $relative"
			[ -f "$target" ] || die "artifact is not a regular file: $relative"
			resolved="$(realpath -e -- "$target")"
			case "$resolved" in
				"$ARMBIAN_BUILD/output/debs/"*|"$ARMBIAN_BUILD/output/packages-hashed/"*) ;;
				*) die "resolved artifact escaped the output allowlist: $relative -> $resolved" ;;
			esac
			TARGETS+=("$target")
		done
		printf 'DELETE artifact %s\n' "${TARGETS[@]}"
		;;
	foreign-rewrite)
		lane_root="$ARMBIAN_BUILD/cache/sources/linux-kernel-worktree/$LANE"
		base="$lane_root/drivers/video/rockchip"
		[ -d "$base" ] || die "kernel worktree driver directory not found: $base"
		resolved_base="$(realpath -e -- "$base")"
		[ "$resolved_base" = "$base" ] || die "worktree driver path contains a symbolic-link escape: $base -> $resolved_base"
		for target in "$base/mpp-rewrite" "$base/rga-rewrite"; do
			[ ! -e "$target" ] || TARGETS+=("$target")
		done
		if [ "${#TARGETS[@]}" -eq 0 ]; then
			say "no foreign rewrite directories exist in lane $LANE"
			exit 0
		fi
		printf 'DELETE foreign rewrite directory %s\n' "${TARGETS[@]}"
		;;
	worktree)
		target="$ARMBIAN_BUILD/cache/sources/linux-kernel-worktree/$LANE"
		[ -d "$target" ] || die "kernel worktree not found: $target"
		[ ! -L "$target" ] || die "refusing symbolic-link worktree: $target"
		say "DELETE complete kernel worktree: $target ($(du -sh "$target" | cut -f1))"
		TARGETS+=("$target")
		;;
esac

if [ "$APPLY" != 1 ]; then
	say "dry run only; re-run with --apply to perform this permanent deletion"
	exit 0
fi

command -v docker >/dev/null || die "docker is required for --apply"
IMAGE_ID="$(docker image inspect --format '{{.Id}}' "$IMAGE" 2>/dev/null)" ||
	die "local Armbian Docker image not found: $IMAGE (run an Armbian build or set --image)"
[[ "$IMAGE_ID" == sha256:* ]] || die "Docker returned an invalid image ID for $IMAGE: $IMAGE_ID"

SELF="$(realpath -e -- "${BASH_SOURCE[0]}")"
DOCKER_COMMON=(
	--rm
	--network none
	--read-only
	--cap-drop ALL
	--cap-add DAC_OVERRIDE
	--security-opt no-new-privileges
	--pids-limit 64
	--user 0:0
	--tmpfs "/tmp:rw,nosuid,nodev,noexec,size=4m"
	--env YSP_ARMBIAN_DOCKER_CLEAN_INTERNAL=1
	--mount "type=bind,src=$SELF,dst=/usr/local/bin/ysp-docker-clean,readonly"
)

case "$ACTION" in
	artifacts)
		docker run "${DOCKER_COMMON[@]}" \
			--mount "type=bind,src=$ARMBIAN_BUILD/output,dst=/armbian/output" \
			"$IMAGE_ID" bash /usr/local/bin/ysp-docker-clean \
			__container__ artifacts "$@"
		;;
	foreign-rewrite|worktree)
		docker run "${DOCKER_COMMON[@]}" \
			--mount "type=bind,src=$ARMBIAN_BUILD/cache,dst=/armbian/cache" \
			"$IMAGE_ID" bash /usr/local/bin/ysp-docker-clean \
			__container__ "$ACTION" "$LANE"
		;;
esac

for target in "${TARGETS[@]}"; do
	[ ! -e "$target" ] || die "Docker cleanup returned success but target remains: $target"
done
say "removed ${#TARGETS[@]} target(s) with local image $IMAGE_ID"
