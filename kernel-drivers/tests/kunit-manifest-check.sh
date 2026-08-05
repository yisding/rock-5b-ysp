#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: GPL-2.0-only
# Verify a kernel tree's registered KUnit case arrays against the tracked
# rewrite-kunit-manifest.tsv, so KUnit case additions/removals cannot land in
# the kernel without the paired YSP manifest+gate bump.
#
# Retro item 5 (2026-07-30): the 07-30 false-red boot ran a stale 84-case
# manifest for days because kernel commit 1115e0c added five AV1 KUnit cases
# with no manifest update — the rationalization plan requires that pairing but
# nothing enforced it at kernel-commit time. Device-free; safe to run from a
# git pre-commit hook (see install-kernel-hooks.sh).
#
# The manifest names every registered case rather than asserting a count and an
# opaque ordered hash. Round 3 (2026-08-01) found three RGA2 MMU cases called
# from inside an unrelated case with the comment "Keep the established 148-case
# boot manifest while extending coverage" -- the count assertion was the thing
# creating that pressure, and it also made every drift report unactionable
# ("hash a != hash b"). A named set reports which cases appeared or vanished,
# and a count carries no information a name list does not.
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

manifest_suites()
{
	awk -F'\t' '$1 !~ /^#/ && NF >= 3 { if (!seen[$1]++) print $1 }' \
		"$MANIFEST"
}

# The registered KUNIT_CASE(name) tokens, in registration order. This is the
# single extraction shared by the pre-commit hook, rewrite-build-gate.sh, and
# the manifest regenerator.
kunit_case_names()
{
	sed -n 's/.*KUNIT_CASE(\([A-Za-z0-9_]*\)).*/\1/p' "$1"
}

manifest_case_names()
{
	awk -F'\t' -v suite="$1" '$1 == suite { print $3 }' "$MANIFEST"
}

# Report the difference between the manifest's cases and the tree's by name.
# Order matters too: the KTAP sequence check in rewrite-kunit-log-check.sh
# pairs case N of the plan with case N of the manifest.
report_diff()
{
	local suite="$1" expected="$2" actual="$3"
	local added removed

	added=$(comm -13 <(sort "$expected") <(sort "$actual"))
	removed=$(comm -23 <(sort "$expected") <(sort "$actual"))

	echo "kunit-manifest-check: $suite drifted from rewrite-kunit-manifest.tsv" >&2
	[ -n "$added" ] &&
		printf '  registered but not in the manifest:\n%s\n' \
			"$(printf '%s\n' "$added" | sed 's/^/    + /')" >&2
	[ -n "$removed" ] &&
		printf '  in the manifest but not registered:\n%s\n' \
			"$(printf '%s\n' "$removed" | sed 's/^/    - /')" >&2
	if [ -z "$added" ] && [ -z "$removed" ]; then
		echo "  same cases, different registration order" >&2
		diff -u "$expected" "$actual" | sed -n '4,$p' | sed 's/^/    /' >&2
	fi
	echo "  Fix: regenerate with '${0##*/} --regenerate <tree>' in the same change" >&2
	echo "  (kernel-drivers/docs/rewrite-kunit-rationalization-plan.md, Phase 6)." >&2
}

check_tree()
{
	local tree="$1"
	local suite source expected actual
	local rc=0

	if [ ! -d "$tree" ]; then
		echo "kunit-manifest-check: not a directory: $tree" >&2
		return 2
	fi
	# A manifest with no data rows would make every loop below a no-op and
	# report success. That is exactly how a gate silently stops gating --
	# and it is one truncating redirection away, since --regenerate reads
	# the manifest to learn which suites exist.
	if [ "$(manifest_suites | wc -l)" -eq 0 ]; then
		echo "kunit-manifest-check: no suites in $MANIFEST" >&2
		echo "  A truncated or empty manifest cannot verify anything." >&2
		return 2
	fi
	while read -r suite; do
		if ! source=$(manifest_source_for "$suite"); then
			echo "kunit-manifest-check: unknown suite in manifest: $suite" >&2
			return 2
		fi
		if [ ! -r "$tree/$source" ]; then
			# A tree that does not carry the rewrite sources (e.g. a
			# vendor branch) is out of scope, not a failure.
			continue
		fi
		expected=$(mktemp "${TMPDIR:-/tmp}/kunit-manifest.XXXXXX")
		actual=$(mktemp "${TMPDIR:-/tmp}/kunit-tree.XXXXXX")
		manifest_case_names "$suite" > "$expected"
		kunit_case_names "$tree/$source" > "$actual"
		if ! cmp -s "$expected" "$actual"; then
			report_diff "$suite" "$expected" "$actual"
			rc=1
		fi
		rm -f "$expected" "$actual"
	done < <(manifest_suites)
	return "$rc"
}

regenerate()
{
	local tree="$1"
	local suite source name ordinal

	if [ ! -d "$tree" ]; then
		echo "kunit-manifest-check: not a directory: $tree" >&2
		return 2
	fi
	printf "# suite\tordinal\tcase_name\n"
	printf "#\n"
	printf "# Every registered KUnit case, in registration order. Regenerate with\n"
	printf "#   kunit-manifest-check.sh --regenerate <kernel-tree>\n"
	printf "# in the same change that adds or removes a case.\n"
	while read -r suite; do
		source=$(manifest_source_for "$suite") || return 2
		if [ ! -r "$tree/$source" ]; then
			echo "kunit-manifest-check: missing source for $suite: $tree/$source" >&2
			return 2
		fi
		ordinal=0
		while read -r name; do
			ordinal=$((ordinal + 1))
			printf "%s\t%s\t%s\n" "$suite" "$ordinal" "$name"
		done < <(kunit_case_names "$tree/$source")
	done < <(manifest_suites)
}

selftest()
{
	local root pass suite src name fake_manifest rc

	root=$(mktemp -d "${TMPDIR:-/tmp}/kunit-manifest-check.XXXXXX")
	trap 'rm -rf "$root"' RETURN

	# Build a tree carrying exactly the manifest's cases, in order.
	pass="$root/pass"
	while read -r suite; do
		src=$(manifest_source_for "$suite") || return 1
		mkdir -p "$pass/$(dirname "$src")"
		: > "$pass/$src"
		while read -r name; do
			printf 'KUNIT_CASE(%s),\n' "$name" >> "$pass/$src"
		done < <(manifest_case_names "$suite")
	done < <(manifest_suites)

	if ! check_tree "$pass" >/dev/null 2>&1; then
		echo "selftest: matching tree unexpectedly failed" >&2
		return 1
	fi

	# --regenerate on that tree must reproduce the manifest's data rows.
	fake_manifest="$root/regen.tsv"
	regenerate "$pass" > "$fake_manifest"
	if ! diff -q \
		<(grep -v '^#' "$MANIFEST") \
		<(grep -v '^#' "$fake_manifest") >/dev/null; then
		echo "selftest: --regenerate did not reproduce the manifest" >&2
		return 1
	fi

	# An added case must fail, and the report must name it.
	src=$(manifest_source_for "$(manifest_suites | head -1)")
	printf 'KUNIT_CASE(sneaky_extra),\n' >> "$pass/$src"
	rc=0
	check_tree "$pass" > "$root/out" 2>&1 || rc=$?
	if [ "$rc" = 0 ]; then
		echo "selftest: drifted tree unexpectedly passed" >&2
		return 1
	fi
	if ! grep -q '+ sneaky_extra' "$root/out"; then
		echo "selftest: drift report did not name the added case" >&2
		return 1
	fi

	# A removed case must fail, and the report must name it.
	sed -i '1d' "$pass/$src"
	rc=0
	check_tree "$pass" > "$root/out" 2>&1 || rc=$?
	if [ "$rc" = 0 ]; then
		echo "selftest: tree with a removed case unexpectedly passed" >&2
		return 1
	fi
	if ! grep -q '^    - ' "$root/out"; then
		echo "selftest: drift report did not name the removed case" >&2
		return 1
	fi

	# An empty manifest must fail loudly rather than vacuously pass.
	: > "$root/empty.tsv"
	rc=0
	KUNIT_MANIFEST="$root/empty.tsv" MANIFEST="$root/empty.tsv" \
		check_tree "$pass" >/dev/null 2>&1 || rc=$?
	if [ "$rc" = 0 ]; then
		echo "selftest: empty manifest unexpectedly passed" >&2
		return 1
	fi

	echo "kunit-manifest-check selftest passed"
}

case "${1:-}" in
--selftest) selftest ;;
--regenerate)
	if [ -z "${2:-}" ]; then
		echo "usage: ${0##*/} --regenerate <kernel-tree>" >&2
		exit 2
	fi
	regenerate "$2"
	;;
--help|-h)
	echo "usage: ${0##*/} <kernel-tree> | --regenerate <kernel-tree> | --selftest" >&2
	;;
"")
	echo "usage: ${0##*/} <kernel-tree> | --regenerate <kernel-tree> | --selftest" >&2
	exit 2
	;;
*)
	check_tree "$1" ;;
esac
