#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

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
run_stage() {
	local name="$1"
	shift
	printf '%s\n' "$name"
	if ! "$@"; then
		failed_stages+=("$name")
	fi
}

run_stage 'Checking Markdown links and anchors...' \
	python3 scripts/check-markdown-links.py "$ROOT"

run_stage 'Running repository-check regression tests...' \
	python3 -m unittest discover -s scripts/tests -p 'test_*.py'

run_stage 'Checking maintained shell scripts...' check_shell_scripts

run_stage 'Checking version pins, portable defaults, and index completeness...' \
	python3 scripts/check-doc-consistency.py "$ROOT"

run_stage 'Checking unstaged, staged, and untracked whitespace...' check_whitespace

if ((${#failed_stages[@]} > 0)); then
	printf '\n%s of 5 repository check stages FAILED:\n' "${#failed_stages[@]}" >&2
	printf '  - %s\n' "${failed_stages[@]%%...}" >&2
	exit 1
fi

printf 'Repository checks passed.\n'
