#!/usr/bin/env bash
# =============================================================================
# centralize-ccache.sh — one shared compiler cache for every build in ~/Code.
#
# ccache keys are content-addressed over compiler identity, the full command
# line, and the preprocessed source, so an aarch64 kernel cross-compile and a
# native Mesa build cannot collide in one store. Splitting the cache buys no
# correctness; it only costs config drift. This wires every known build to a
# single store with a single config file.
#
# THE CONFIG-RESOLUTION GOTCHA that makes the symlinks load-bearing: ccache
# reads exactly ONE config file, and which one depends on whether CCACHE_DIR is
# set.
#
#   CCACHE_DIR set (Armbian's container, the Mesa script)
#       -> config is $CCACHE_DIR/ccache.conf
#   CCACHE_DIR unset (a bare `ccache gcc ...` on the host)
#       -> cache dir is ~/.cache/ccache, but the config is
#          ~/.config/ccache/ccache.conf
#
# ~/.cache/ccache/ccache.conf is NEVER read. Pointing only the cache directory
# at the shared store therefore leaves host builds silently on the 5 GiB /
# compiler_check=mtime defaults. So this script links BOTH:
#
#   ~/.cache/ccache          -> $CENTRAL_DIR          (directory symlink)
#   ~/.config/ccache/ccache.conf -> $CENTRAL_DIR/ccache.conf  (file symlink)
#
# and keeps the settings in exactly one file, the store's own ccache.conf.
# Setting cache_dir inside that file is deliberately avoided: an explicit
# CCACHE_DIR always wins over it, so it would be dead weight that reads as if
# it were authoritative.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CODE_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
CENTRAL_DIR="$CODE_ROOT/.ccache"
MAX_SIZE="${CCACHE_MAX_SIZE:-30.0G}"

MODE=setup
REPLACE=0

say() { printf '>>> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

usage() {
	cat <<EOF
Usage:
  bash scripts/centralize-ccache.sh --status
  bash scripts/centralize-ccache.sh [--replace]

Point every known build at one shared ccache store:
  $CENTRAL_DIR   (max_size $MAX_SIZE, compiler_check content)

The expected per-project cache paths become symlinks to that store, and the
host config is linked to the store's ccache.conf so a bare 'ccache' on the host
uses the same store and the same settings.

  --status   Report the current layout. No root, no writes.
  --replace  Delete any real cache directory still sitting at a wired path.
             Without it, an existing store is left alone and reported.

Setup is idempotent. Root is needed only when a path to be replaced is not
writable by the invoking user. Empty the shared store later with 'ccache -C';
that is rarely the right response to a build failure.
EOF
}

while (($#)); do
	case "$1" in
		--status) MODE=status ;;
		--replace) REPLACE=1 ;;
		-h | --help)
			usage
			exit 0
			;;
		*) die "unknown argument: $1" ;;
	esac
	shift
done

if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]]; then
	OWNER_USER="$SUDO_USER"
else
	OWNER_USER="$(stat -c %U "$REPO_ROOT")"
fi
[[ -n "$OWNER_USER" && "$OWNER_USER" != root ]] || die "could not identify the non-root repository owner"

OWNER_HOME="$(getent passwd "$OWNER_USER" | cut -d: -f6)"
[[ -n "$OWNER_HOME" && -d "$OWNER_HOME" ]] || die "could not identify the home directory for $OWNER_USER"
OWNER_GROUP="$(id -gn "$OWNER_USER")"

CENTRAL_CONF="$CENTRAL_DIR/ccache.conf"
USER_CONF="$OWNER_HOME/.config/ccache/ccache.conf"

# Directory symlinks. Armbian bind-mounts its path into the container, and
# Docker resolves a symlinked bind source on the host, so the container sees the
# real store at /armbian/cache/ccache.
declare -a CACHE_DIRS=(
	"$CODE_ROOT/kernel/rock5b-kernel-build/armbian-build/cache/ccache"
	"$CODE_ROOT/armbian/armbian-build/cache/ccache"
	"$CODE_ROOT/fdo/mesa/.codex-ccache"
	"$OWNER_HOME/.cache/ccache"
)

canonical() { realpath -e -- "$1" 2>/dev/null || true; }

links_to() { # path target
	[[ -L "$1" && "$(canonical "$1")" == "$2" ]]
}

# ---------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------
show_status() {
	local path target
	printf 'Shared store: %s\n' "$CENTRAL_DIR"
	if [[ -d "$CENTRAL_DIR" && ! -L "$CENTRAL_DIR" ]]; then
		printf '  size on disk  %s\n' "$(du -sh -- "$CENTRAL_DIR" 2>/dev/null | cut -f1)"
		CCACHE_DIR="$CENTRAL_DIR" ccache --show-config 2>/dev/null \
			| awk '/ (compiler_check|max_size|umask) =/ { print "  " $0 }'
	else
		printf '  not created\n'
	fi

	printf '\nWired cache directories:\n'
	for path in "${CACHE_DIRS[@]}"; do
		if links_to "$path" "$CENTRAL_DIR"; then
			printf '  shared     %s\n' "$path"
		elif [[ -L "$path" ]]; then
			target="$(readlink -- "$path")"
			printf '  OTHER LINK %s -> %s\n' "$path" "$target"
		elif [[ -d "$path" ]]; then
			printf '  SEPARATE   %s  (%s)\n' "$path" \
				"$(du -sh -- "$path" 2>/dev/null | cut -f1)"
		elif [[ -e "$path" ]]; then
			printf '  NOT A DIR  %s\n' "$path"
		else
			printf '  absent     %s\n' "$path"
		fi
	done

	printf '\nHost config (used when CCACHE_DIR is unset):\n'
	if links_to "$USER_CONF" "$CENTRAL_CONF"; then
		printf '  shared     %s\n' "$USER_CONF"
	elif [[ -e "$USER_CONF" || -L "$USER_CONF" ]]; then
		printf '  UNMANAGED  %s\n' "$USER_CONF"
	else
		printf '  absent     %s  (host builds would use ccache defaults)\n' "$USER_CONF"
	fi
}

# ---------------------------------------------------------------------------
# setup
# ---------------------------------------------------------------------------
ensure_no_ccache_processes() {
	if command -v pgrep >/dev/null 2>&1 && pgrep -x ccache >/dev/null; then
		pgrep -a -x ccache >&2 || true
		die "ccache is active; stop all builds and retry"
	fi
}

own_path() { # path... — best effort; only meaningful when running as root
	((EUID == 0)) || return 0
	chown -h "$OWNER_USER:$OWNER_GROUP" "$@"
}

ensure_central() {
	if [[ -L "$CENTRAL_DIR" ]]; then
		die "$CENTRAL_DIR is a symlink; expected a real directory"
	fi
	if [[ ! -d "$CENTRAL_DIR" ]]; then
		say "Creating $CENTRAL_DIR"
		# setgid so directories the Armbian container creates keep the group.
		install -d -m 2775 "$CENTRAL_DIR"
		own_path "$CENTRAL_DIR"
	fi

	local desired
	desired="$(
		cat <<EOF
# Shared compiler cache for every build under $(basename "$CODE_ROOT")/.
# Managed by rock-5b-ysp/scripts/centralize-ccache.sh — edit it there.
#
# compiler_check=content is the load-bearing setting: Armbian periodically
# rebuilds its Docker image with a fresh 'apt install gcc', and the default
# mtime check would treat byte-identical gcc as a new compiler and miss the
# entire cache.
max_size = $MAX_SIZE
compiler_check = content
umask = 002
EOF
	)"
	if [[ ! -f "$CENTRAL_CONF" ]] || [[ "$(cat "$CENTRAL_CONF")" != "$desired" ]]; then
		say "Writing $CENTRAL_CONF"
		printf '%s\n' "$desired" >"$CENTRAL_CONF"
		chmod 0664 "$CENTRAL_CONF"
		own_path "$CENTRAL_CONF"
	fi
}

clear_wired_path() { # path kind
	local path="$1" kind="$2"
	# Only ever remove a path this script is responsible for, and never cross a
	# filesystem boundary while doing it.
	case "$path" in
		*/ccache | */ccache.conf | */.codex-ccache) ;;
		*) die "refusing to remove an unexpected path: $path" ;;
	esac
	if ((REPLACE == 0)); then
		die "$path is an existing $kind; re-run with --replace to delete it"
	fi
	# Unlinking needs write on the parent; clearing a populated tree needs write
	# on EVERY directory in it. Testing only the top level is not enough: the
	# Armbian container runs as root, so a store whose top directory is
	# user-owned can still be entirely root-owned one level down. Probing the
	# whole tree is what keeps a half-finished rm -rf from happening.
	[[ -w "$(dirname "$path")" ]] || die "need root to unlink $path; re-run with sudo"
	local blocked
	blocked="$(find "$path" -type d ! -writable -printf '%u:%g %p\n' -quit 2>/dev/null || true)"
	if [[ -n "$blocked" ]]; then
		die "need root to clear $path; not writable: $blocked; re-run with sudo"
	fi
	say "Removing $kind $path"
	rm -rf --one-file-system -- "$path"
}

wire_dir() { # path
	local path="$1"
	if links_to "$path" "$CENTRAL_DIR"; then
		return 0
	fi
	if [[ -L "$path" ]]; then
		clear_wired_path "$path" "symlink to $(readlink -- "$path")"
	elif [[ -d "$path" ]]; then
		clear_wired_path "$path" "cache directory"
	elif [[ -e "$path" ]]; then
		die "expected a directory or symlink: $path"
	fi
	mkdir -p -- "$(dirname "$path")"
	ln -s -- "$CENTRAL_DIR" "$path"
	own_path "$path"
	links_to "$path" "$CENTRAL_DIR" || die "symlink validation failed: $path"
	say "Wired $path"
}

wire_conf() {
	if links_to "$USER_CONF" "$CENTRAL_CONF"; then
		return 0
	fi
	if [[ -e "$USER_CONF" || -L "$USER_CONF" ]]; then
		clear_wired_path "$USER_CONF" "host ccache config"
	fi
	mkdir -p -- "$(dirname "$USER_CONF")"
	# Under sudo, mkdir -p may have created ~/.config as well as ~/.config/ccache.
	own_path "$(dirname "$USER_CONF")" "$OWNER_HOME/.config"
	ln -s -- "$CENTRAL_CONF" "$USER_CONF"
	own_path "$USER_CONF"
	links_to "$USER_CONF" "$CENTRAL_CONF" || die "symlink validation failed: $USER_CONF"
	say "Wired $USER_CONF"
}

# Prove both resolution paths land in the shared store with the shared settings,
# rather than trusting that the symlinks imply it.
verify() {
	local out resolved
	# env stops parsing options at the first NAME=VALUE argument, so every -u has
	# to precede every assignment. Keep only the flags here and let each call
	# append its own -u and assignments in that order.
	local -a env_base=(env -u XDG_CONFIG_HOME -u XDG_CACHE_HOME)
	# Under sudo, read the store back AS the owner. --show-stats can create files,
	# and the first process to touch a fresh store must not be root: that is
	# exactly how the previous per-project caches ended up unmanageable.
	if ((EUID == 0)); then
		command -v runuser >/dev/null || die "runuser is required when running as root"
		env_base=(runuser -u "$OWNER_USER" -- "${env_base[@]}")
	fi

	out="$("${env_base[@]}" -u CCACHE_DIR "HOME=$OWNER_HOME" ccache --show-config)" \
		|| die "ccache could not read the host configuration"
	resolved="$(canonical "$(awk -F' = ' '/ cache_dir =/ { print $2 }' <<<"$out")")"
	[[ "$resolved" == "$CENTRAL_DIR" ]] \
		|| die "host cache_dir resolves to '$resolved', not $CENTRAL_DIR"
	grep -Fq " compiler_check = content" <<<"$out" \
		|| die "host config does not apply compiler_check = content"
	grep -Fq "$USER_CONF) max_size" <<<"$out" \
		|| die "host max_size does not come from $USER_CONF"

	out="$("${env_base[@]}" "HOME=$OWNER_HOME" "CCACHE_DIR=$CENTRAL_DIR" ccache --show-config)" \
		|| die "ccache could not read the shared store"
	grep -Fq " compiler_check = content" <<<"$out" \
		|| die "shared store does not apply compiler_check = content"

	"${env_base[@]}" "HOME=$OWNER_HOME" "CCACHE_DIR=$CENTRAL_DIR" ccache --show-stats >/dev/null \
		|| die "ccache could not read stats from the shared store"
	say "Verified: host and CCACHE_DIR paths both resolve to $CENTRAL_DIR"
}

setup() {
	local path
	command -v ccache >/dev/null || die "ccache is required"
	ensure_no_ccache_processes
	ensure_central
	for path in "${CACHE_DIRS[@]}"; do
		wire_dir "$path"
	done
	wire_conf
	verify
	printf '\n'
	show_status
}

case "$MODE" in
	status) show_status ;;
	setup) setup ;;
	*) die "internal mode error: $MODE" ;;
esac
