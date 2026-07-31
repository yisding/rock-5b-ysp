#!/usr/bin/env bash
# Verify a kernel tree's registered KUnit case arrays against the tracked
# rewrite-kunit-manifest.tsv, so KUnit case additions/removals cannot land in
# the kernel without the paired YSP manifest+gate bump.
#
# Retro item 5 (2026-07-30): the 07-30 false-red boot ran a stale 84-case
# manifest for days because kernel commit 1115e0c added five AV1 KUnit cases
# with no manifest update — the rationalization plan requires that pairing but
# nothing enforced it at kernel-commit time. This is the same count+hash check
# rewrite-build-gate.sh runs, factored out so a git pre-commit hook can call it
# (see install-kernel-hooks.sh). Device-free; safe to run from a hook.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST=${KUNIT_MANIFEST:-"$TEST_DIR/rewrite-kunit-manifest.tsv"}

manifest_source_for()
{
	case "$1" in
	rk_mpp_rewrite)
		printf "drivers/video/rockchip/mpp-rewrite/mpp_rewrite.c" ;;
	rockchip-rga-rewrite)
		printf "drivers/video/rockchip/rga-rewrite/rga_rewrite.c" ;;
	*)
		return 1 ;;
	esac
}

# Same extraction as rewrite-build-gate.sh check_kunit_manifest: the registered
# KUNIT_CASE(name) tokens in registration order, counted and hashed.
kunit_case_count()
{
	sed -n 's/.*KUNIT_CASE(\([A-Za-z0-9_]*\)).*/\1/p' "$1" | wc -l | tr -d '[:space:]'
}
kunit_case_hash()
{
	sed -n 's/.*KUNIT_CASE(\([A-Za-z0-9_]*\)).*/\1/p' "$1" |
		sha256sum | awk '{ print $1 }'
}

check_tree()
{
	local tree="$1"
	local manifest="${KUNIT_MANIFEST:-$MANIFEST}"
	local suite expected_count expected_hash source actual_count actual_hash
	local rc=0

	if [ ! -d "$tree" ]; then
		echo "kunit-manifest-check: not a directory: $tree" >&2
		return 2
	fi
	while IFS=$'\t' read -r suite expected_count expected_hash; do
		case "$suite" in ""|\#*) continue ;; esac
		if ! source=$(manifest_source_for "$suite"); then
			echo "kunit-manifest-check: unknown suite in manifest: $suite" >&2
			return 2
		fi
		if [ ! -r "$tree/$source" ]; then
			# A tree that does not carry the rewrite sources (e.g. a
			# vendor branch) is out of scope, not a failure.
			continue
		fi
		actual_count=$(kunit_case_count "$tree/$source")
		actual_hash=$(kunit_case_hash "$tree/$source")
		if [ "$actual_count" != "$expected_count" ] ||
			[ "$actual_hash" != "$expected_hash" ]; then
			cat >&2 <<EOF
kunit-manifest-check: $suite drifted from rewrite-kunit-manifest.tsv
  source:   $source
  expected: count=$expected_count hash=$expected_hash
  observed: count=$actual_count hash=$actual_hash
  Fix: regenerate the manifest and the gate counts in the same change
  (kernel-drivers/docs/rewrite-kunit-rationalization-plan.md, Phase 6).
EOF
			rc=1
		fi
	done < "$manifest"
	return "$rc"
}

selftest()
{
	local root pass fail
	root=$(mktemp -d "${TMPDIR:-/tmp}/kunit-manifest-check.XXXXXX")
	trap 'rm -rf "$root"' RETURN

	# A tree whose sources match the tracked manifest passes; a one-case
	# edit fails. Build a fake source with exactly the manifest's cases.
	local suite count src _hash
	pass="$root/pass"
	while IFS=$'\t' read -r suite count _hash; do
		case "$suite" in ""|\#*) continue ;; esac
		src=$(manifest_source_for "$suite") || return 1
		mkdir -p "$pass/$(dirname "$src")"
		: > "$pass/$src"
		local i=0
		while [ "$i" -lt "$count" ]; do
			printf 'KUNIT_CASE(case_%s),\n' "$i" >> "$pass/$src"
			i=$((i + 1))
		done
	done < "$MANIFEST"

	# The fake tree has correct counts but not the real hashes, so build a
	# per-suite manifest from the fake tree and check against THAT.
	local fake_manifest="$root/manifest.tsv"
	printf "# suite\texpected_cases\tordered_case_names_sha256\n" > "$fake_manifest"
	while IFS=$'\t' read -r suite count _hash; do
		case "$suite" in ""|\#*) continue ;; esac
		src=$(manifest_source_for "$suite") || return 1
		printf "%s\t%s\t%s\n" "$suite" \
			"$(kunit_case_count "$pass/$src")" \
			"$(kunit_case_hash "$pass/$src")" >> "$fake_manifest"
	done < "$MANIFEST"

	if ! KUNIT_MANIFEST="$fake_manifest" check_tree "$pass" >/dev/null 2>&1; then
		echo "selftest: matching tree unexpectedly failed" >&2
		return 1
	fi
	# Append one case to the first source -> drift -> must fail.
	fail="$pass"
	local first_src
	first_src=$(manifest_source_for "$(awk -F'\t' '$1 !~ /^#/ && NF {print $1; exit}' "$fake_manifest")")
	printf 'KUNIT_CASE(sneaky_extra),\n' >> "$fail/$first_src"
	if KUNIT_MANIFEST="$fake_manifest" check_tree "$fail" >/dev/null 2>&1; then
		echo "selftest: drifted tree unexpectedly passed" >&2
		return 1
	fi
	echo "kunit-manifest-check selftest passed"
}

case "${1:-}" in
--selftest) selftest ;;
--help|-h)
	echo "usage: ${0##*/} <kernel-tree> | --selftest" >&2
	;;
"")
	echo "usage: ${0##*/} <kernel-tree> | --selftest" >&2
	exit 2
	;;
*)
	check_tree "$1" ;;
esac
