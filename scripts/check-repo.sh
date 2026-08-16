#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

usage() {
	cat <<'EOF'
Usage: check-repo.sh [--all]

Runs the repository handoff gate.  The documentation checks always run over the
whole repository -- they take seconds.  The two expensive stages are scoped by
default to what this branch actually changed:

  ShellCheck            runs only on changed shell files
  Source-audit tests    run only when the audit scripts, their baselines, the
                        conformance harness, or the test module changed

"Changed" means uncommitted work plus anything on this branch that origin/main
does not have, so a documentation-only edit skips both.

  --all   Check every file and run every test, ignoring what changed.  Use this
          for a release handoff, or after touching something global.

  CHECK_REPO_ALL=1 in the environment is equivalent to --all.
EOF
}

check_all=${CHECK_REPO_ALL:-0}
while (($#)); do
	case "$1" in
	--all)
		check_all=1
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		printf 'unknown option: %s\n\n' "$1" >&2
		usage >&2
		exit 2
		;;
	esac
	shift
done

# Uncommitted work plus this branch's commits that origin/main does not have.
# A gate that only diffed against HEAD would check nothing once the work is
# committed, which is exactly when a handoff gate matters most.
changed_paths() {
	local upstream base
	{
		git diff --name-only HEAD --
		git diff --cached --name-only --
		git ls-files --others --exclude-standard
		if upstream=$(git rev-parse --verify --quiet origin/main); then
			if base=$(git merge-base HEAD "$upstream" 2>/dev/null); then
				git diff --name-only "$base"..HEAD --
			fi
		fi
	} 2>/dev/null | sort -u
}

changed=''
if ((check_all == 0)); then
	changed=$(changed_paths)
fi

# Paths whose change can alter a source-audit or conformance-harness verdict.
SOURCE_AUDIT_TRIGGER='^(kernel-drivers/tests/rewrite-(ownership|kunit)-source-audit|kernel-drivers/tests/conformance/|scripts/tests/test_repo_checks\.py)'

if ((check_all == 1)) || grep -Eq "$SOURCE_AUDIT_TRIGGER" <<<"$changed"; then
	export REPO_CHECK_SOURCE_AUDIT=1
fi

check_untracked_whitespace() {
	local file output rc failed=0
	while IFS= read -r -d '' file; do
		rc=0
		output="$(git diff --no-index --check -- /dev/null "$file" 2>&1)" || rc=$?
		if ((rc > 1)); then
			printf '%s\n' "$output" >&2
			return "$rc"
		fi
		if [[ -n "$output" ]]; then
			printf '%s\n' "$output" >&2
			failed=1
		fi
	done < <(git ls-files --others --exclude-standard -z)
	return "$failed"
}

check_shell_scripts() {
	local -a files
	if ! command -v shellcheck >/dev/null 2>&1; then
		printf '%s\n' \
			'ShellCheck is required; install the shellcheck package and retry.' >&2
		return 127
	fi

	mapfile -d '' -t files < <(
		git ls-files --cached --others --exclude-standard -z -- '*.sh'
	)

	if ((check_all == 0)); then
		local -a scoped=()
		local file
		for file in "${files[@]}"; do
			if grep -Fxq -- "$file" <<<"$changed"; then
				scoped+=("$file")
			fi
		done
		if ((${#scoped[@]} == 0)); then
			printf '  no changed shell files; skipping (--all checks all %s)\n' \
				"${#files[@]}"
			return 0
		fi
		printf '  scoped to %s of %s shell files\n' \
			"${#scoped[@]}" "${#files[@]}"
		files=("${scoped[@]}")
	fi

	((${#files[@]} == 0)) || shellcheck --external-sources --severity=warning "${files[@]}"
}

check_whitespace() {
	git diff --check &&
		git diff --cached --check &&
		check_untracked_whitespace
}

# Every stage runs even when an earlier one fails. `set -e` would abort at the
# first failure and silently skip the rest, which reports one problem per run
# and hides the others -- the opposite of what a handoff gate is for.
failed_stages=()
stage_count=0
run_stage() {
	local name="$1"
	shift
	stage_count=$((stage_count + 1))
	printf '%s\n' "$name"
	if ! "$@"; then
		failed_stages+=("$name")
	fi
}

run_stage 'Checking Markdown links and anchors...' \
	python3 scripts/check-markdown-links.py "$ROOT"

if [[ ${REPO_CHECK_SOURCE_AUDIT:-0} == 1 ]]; then
	printf 'Source-audit tests: enabled\n'
else
	printf 'Source-audit tests: skipped (nothing they guard changed; --all forces them)\n'
fi

run_stage 'Running repository-check regression tests...' \
	python3 -m unittest discover -s scripts/tests -p 'test_*.py'

run_stage 'Reporting documentation ownership candidates (informational)...' \
	python3 scripts/report-doc-duplication.py --summary "$ROOT"

run_stage 'Checking maintained shell scripts...' check_shell_scripts

run_stage 'Checking version pins, portable defaults, and index completeness...' \
	python3 scripts/check-doc-consistency.py "$ROOT"

run_stage 'Checking unstaged, staged, and untracked whitespace...' check_whitespace

if ((${#failed_stages[@]} > 0)); then
	printf '\n%s of %s repository check stages FAILED:\n' \
		"${#failed_stages[@]}" "$stage_count" >&2
	printf '  - %s\n' "${failed_stages[@]%%...}" >&2
	exit 1
fi

printf 'Repository checks passed.\n'
