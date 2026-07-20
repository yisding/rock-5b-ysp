#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CODE_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
CENTRAL_DIR="$CODE_ROOT/.ccache"

MODE=migrate
YES=0

say() { printf '>>> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
	cat <<EOF
Usage:
  bash scripts/centralize-ccache.sh --status
  sudo bash scripts/centralize-ccache.sh
  sudo bash scripts/centralize-ccache.sh --cleanup-backups [--yes]

Merge the known host, Mesa, and Armbian ccache stores into:
  $CENTRAL_DIR

Migration is reversible. Each original directory is renamed with a
.pre-centralize-TIMESTAMP suffix and replaced by an absolute symlink. Backups
are only removed by the separate --cleanup-backups --yes operation.
EOF
}

while (($#)); do
	case "$1" in
		--status)
			MODE=status
			;;
		--cleanup-backups)
			MODE=cleanup
			;;
		--yes)
			YES=1
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			die "unknown argument: $1"
			;;
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

declare -a CACHE_PATHS=(
	"$CODE_ROOT/kernel/rock5b-kernel-build/armbian-build/cache/ccache"
	"$CODE_ROOT/armbian/armbian-build/cache/ccache"
	"$CODE_ROOT/fdo/mesa/.codex-ccache"
	"$OWNER_HOME/.cache/ccache"
)

canonical_existing() {
	realpath -e -- "$1" 2>/dev/null || true
}

points_to_central() {
	local path="$1"
	[[ -L "$path" && "$(canonical_existing "$path")" == "$CENTRAL_DIR" ]]
}

find_backups() {
	local live parent base
	for live in "${CACHE_PATHS[@]}"; do
		parent="$(dirname "$live")"
		base="$(basename "$live")"
		[[ -d "$parent" ]] || continue
		find "$parent" -mindepth 1 -maxdepth 1 -type d \
			-name "$base.pre-centralize-*" -print0
	done
}

show_status() {
	local path target
	printf 'Central store: %s\n' "$CENTRAL_DIR"
	if [[ -d "$CENTRAL_DIR" && ! -L "$CENTRAL_DIR" ]]; then
		du -sh -- "$CENTRAL_DIR" 2>/dev/null || true
		CCACHE_DIR="$CENTRAL_DIR" ccache --show-config 2>/dev/null \
			| awk '/compiler_check|max_size|umask/ { print "  " $0 }'
	else
		printf '  not created\n'
	fi

	printf '\nExpected cache paths:\n'
	for path in "${CACHE_PATHS[@]}"; do
		if [[ -L "$path" ]]; then
			target="$(readlink -- "$path")"
			if points_to_central "$path"; then
				printf '  centralized  %s -> %s\n' "$path" "$target"
			else
				printf '  OTHER LINK   %s -> %s\n' "$path" "$target"
			fi
		elif [[ -d "$path" ]]; then
			printf '  separate     '
			du -sh -- "$path" 2>/dev/null | awk '{ print $1 "  " $2 }'
		elif [[ -e "$path" ]]; then
			printf '  NOT A DIR    %s\n' "$path"
		else
			printf '  missing      %s\n' "$path"
		fi
	done

	printf '\nPreserved migration backups:\n'
	local found=0 backup
	while IFS= read -r -d '' backup; do
		found=1
		du -sh -- "$backup" 2>/dev/null || printf '  %s\n' "$backup"
	done < <(find_backups)
	((found)) || printf '  none\n'
}

require_root() {
	((EUID == 0)) || die "this operation needs root; rerun with: sudo bash scripts/centralize-ccache.sh${1:-}"
}

ensure_no_ccache_processes() {
	if command -v pgrep >/dev/null 2>&1 && pgrep -x ccache >/dev/null; then
		pgrep -a -x ccache >&2 || true
		die "ccache is active; stop all builds and retry"
	fi
}

all_paths_centralized() {
	local path
	[[ -d "$CENTRAL_DIR" && ! -L "$CENTRAL_DIR" ]] || return 1
	for path in "${CACHE_PATHS[@]}"; do
		points_to_central "$path" || return 1
	done
}

detect_shared_group() {
	local active_cache="${CACHE_PATHS[0]}" candidate candidate_gid gid
	candidate="$(find "$active_cache" -mindepth 1 -maxdepth 1 -type d -printf '%g\n' -quit 2>/dev/null || true)"
	[[ -n "$candidate" ]] || candidate="$OWNER_GROUP"
	getent group "$candidate" >/dev/null || candidate="$OWNER_GROUP"
	candidate_gid="$(getent group "$candidate" | cut -d: -f3)"
	for gid in $(id -G "$OWNER_USER"); do
		if [[ "$gid" == "$candidate_gid" ]]; then
			printf '%s\n' "$candidate"
			return 0
		fi
	done
	warn "$OWNER_USER is not a member of the container-created cache group '$candidate'; using $OWNER_GROUP"
	printf '%s\n' "$OWNER_GROUP"
}

cleanup_backups() {
	local path backup
	require_root " --cleanup-backups"
	ensure_no_ccache_processes
	all_paths_centralized || die "all four live paths must point to $CENTRAL_DIR before backups can be removed"

	declare -a backups=()
	mapfile -d '' -t backups < <(find_backups)
	if ((${#backups[@]} == 0)); then
		say "No migration backups remain."
		return 0
	fi

	say "Migration backups eligible for removal:"
	for backup in "${backups[@]}"; do
		[[ -d "$backup" && ! -L "$backup" ]] || die "refusing unexpected backup type: $backup"
		du -sh -- "$backup"
	done

	if ((YES == 0)); then
		say "Nothing removed. Test Mesa and an Armbian Docker build, then run:"
		say "  sudo bash scripts/centralize-ccache.sh --cleanup-backups --yes"
		return 0
	fi

	for backup in "${backups[@]}"; do
		say "Removing $backup"
		rm -rf --one-file-system -- "$backup"
	done
	say "Backup cleanup complete."
}

migrate() {
	local timestamp staging validation_report source backup shared_group bytes
	local available_bytes source_bytes=0
	require_root ""
	ensure_no_ccache_processes
	command -v ccache >/dev/null || die "ccache is required"
	command -v rsync >/dev/null || die "rsync is required"

	if all_paths_centralized; then
		say "All cache paths already point to $CENTRAL_DIR."
		show_status
		return 0
	fi
	[[ ! -e "$CENTRAL_DIR" && ! -L "$CENTRAL_DIR" ]] \
		|| die "$CENTRAL_DIR already exists but the migration is incomplete; inspect it before retrying"

	for source in "${CACHE_PATHS[@]}"; do
		if [[ -L "$source" ]]; then
			die "refusing existing symlink that does not point to the central store: $source"
		fi
		[[ ! -e "$source" || -d "$source" ]] || die "expected a directory: $source"
	done

	timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
	staging="$CODE_ROOT/.ccache.migrating-$timestamp"
	[[ ! -e "$staging" ]] || die "staging path already exists: $staging"
	shared_group="$(detect_shared_group)"

	for source in "${CACHE_PATHS[@]}"; do
		[[ -d "$source" ]] || continue
		bytes="$(du -s --block-size=1 -- "$source" | awk '{ print $1 + 0 }')"
		source_bytes=$((source_bytes + bytes))
	done
	available_bytes="$(df --output=avail --block-size=1 "$CODE_ROOT" | awk 'END { print $1 + 0 }')"
	((available_bytes > source_bytes + 1073741824)) \
		|| die "not enough temporary space to copy and validate the caches"

	declare -a swapped_live=() swapped_backup=()
	local migration_complete=0 central_created=0
	on_exit() {
		local rc=$? i live saved rollback_failed=0
		trap - EXIT
		if ((rc != 0 && migration_complete == 0)); then
			set +e
			warn "Migration failed; restoring original cache paths."
			for ((i = ${#swapped_live[@]} - 1; i >= 0; i--)); do
				live="${swapped_live[i]}"
				saved="${swapped_backup[i]}"
				if [[ -L "$live" ]] && ! rm -f -- "$live"; then
					warn "Could not remove migration symlink: $live"
					rollback_failed=1
				fi
				if [[ -n "$saved" && -e "$saved" ]]; then
					if ! mv -- "$saved" "$live"; then
						warn "Could not restore backup: $saved"
						rollback_failed=1
					fi
				fi
			done
			if [[ -n "$staging" && -d "$staging" ]] \
				&& ! rm -rf --one-file-system -- "$staging"; then
				warn "Could not remove incomplete staging directory: $staging"
			fi
			if ((central_created && rollback_failed == 0)) \
				&& [[ -d "$CENTRAL_DIR" && ! -L "$CENTRAL_DIR" ]]; then
				rm -rf --one-file-system -- "$CENTRAL_DIR" \
					|| warn "Could not remove the incomplete central store: $CENTRAL_DIR"
			elif ((central_created && rollback_failed != 0)); then
				warn "Retaining $CENTRAL_DIR because rollback was incomplete."
			fi
		fi
		exit "$rc"
	}
	trap on_exit EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM

	say "Creating staged shared store at $staging"
	install -d -m 2775 -o "$OWNER_USER" -g "$shared_group" "$staging"
	for source in "${CACHE_PATHS[@]}"; do
		[[ -d "$source" ]] || continue
		say "Merging $source"
		rsync -rlt --ignore-existing \
			--exclude='/ccache.conf' --exclude='stats' --exclude='tmp' \
			-- "$source/" "$staging/"
	done

	validation_report="$staging/.merge-validation"
	for source in "${CACHE_PATHS[@]}"; do
		[[ -d "$source" ]] || continue
		: >"$validation_report"
		rsync -rnc --itemize-changes \
			--exclude='/ccache.conf' --exclude='stats' --exclude='tmp' \
			-- "$source/" "$staging/" >"$validation_report"
		if [[ -s "$validation_report" ]]; then
			sed -n '1,40p' "$validation_report" >&2
			die "byte validation failed while merging $source"
		fi
	done
	rm -f -- "$validation_report"

	cat >"$staging/ccache.conf" <<'EOF'
compiler_check = content
max_size = 15.0G
umask = 002
EOF

	chown -R "$OWNER_USER:$shared_group" "$staging"
	find "$staging" -type d -exec chmod 2775 {} +
	find "$staging" -type f -exec chmod 0664 {} +

	CCACHE_DIR="$staging" ccache --show-config \
		| grep -Eq '^\(([^)]*)\) compiler_check = content$' \
		|| die "central compiler_check validation failed"
	CCACHE_DIR="$staging" ccache --show-config \
		| grep -Eq '^\(([^)]*)\) max_size = 15(\.0)? G(i)?B$' \
		|| die "central max_size validation failed"
	CCACHE_DIR="$staging" ccache --show-stats >/dev/null \
		|| die "ccache could not read the merged store"

	say "Activating $CENTRAL_DIR"
	mv -- "$staging" "$CENTRAL_DIR"
	staging=""
	central_created=1

	for source in "${CACHE_PATHS[@]}"; do
		mkdir -p -- "$(dirname "$source")"
		backup=""
		if [[ -d "$source" ]]; then
			backup="$source.pre-centralize-$timestamp"
			[[ ! -e "$backup" ]] || die "backup path already exists: $backup"
			mv -- "$source" "$backup"
		fi
		swapped_live+=("$source")
		swapped_backup+=("$backup")
		ln -s -- "$CENTRAL_DIR" "$source"
		chown -h "$OWNER_USER:$OWNER_GROUP" "$source"
		points_to_central "$source" || die "symlink validation failed: $source"
	done

	migration_complete=1
	trap - EXIT INT TERM
	say "Centralization complete; original caches remain as timestamped backups."
	show_status
	printf '\n'
	say "Test one Mesa compile and one Armbian Docker build before cleanup."
	say "Preview backup cleanup with:"
	say "  sudo bash scripts/centralize-ccache.sh --cleanup-backups"
}

case "$MODE" in
	status)
		show_status
		;;
	cleanup)
		cleanup_backups
		;;
	migrate)
		migrate
		;;
	*)
		die "internal mode error: $MODE"
		;;
esac
