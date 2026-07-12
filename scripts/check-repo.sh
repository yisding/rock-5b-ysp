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

printf 'Checking Markdown links and anchors...\n'
python3 scripts/check-markdown-links.py "$ROOT"

printf 'Running repository-check regression tests...\n'
python3 -m unittest discover -s scripts/tests -p 'test_*.py'

printf 'Checking maintained shell scripts...\n'
check_shell_scripts

printf 'Checking repository documentation contracts...\n'
python3 scripts/check-doc-consistency.py "$ROOT"

printf 'Checking unstaged, staged, and untracked whitespace...\n'
git diff --check
git diff --cached --check
check_untracked_whitespace

printf 'Repository checks passed.\n'
