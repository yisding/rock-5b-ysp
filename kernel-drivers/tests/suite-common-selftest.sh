#!/usr/bin/env bash
# Device-free checks for the shared suite dmesg delta/fatal-signature gate.
set -euo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$TEST_DIR/../.." && pwd)
# shellcheck source=suite-common.sh disable=SC1091
source "$TEST_DIR/suite-common.sh"

TMP_ROOT=$(mktemp -d "${TMPDIR:-$REPO_ROOT}/.suite-common-selftest.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

write_clean_snapshots()
{
	local out=$1

	mkdir -p "$out"
	printf "[0.000000] boot\n[1.000000] rewrite ready\n" > "$out/dmesg-before.txt"
	printf "[0.000000] boot\n[1.000000] rewrite ready\n[2.000000] harmless job complete\n" > "$out/dmesg-after.txt"
}

good="$TMP_ROOT/good"
write_clean_snapshots "$good"
SUITE_DMESG_SCAN=1 SUITE_REQUIRE_DMESG=1 \
	suite_dmesg_scan_snapshots "$good"
grep -q $'^status\tclean$' "$good/dmesg-scan.tsv"
grep -q 'harmless job complete' "$good/dmesg-new.txt"

repeated="$TMP_ROOT/repeated-boundary"
mkdir -p "$repeated"
printf "[0.000000] repeated line\n[1.000000] old WARNING: harmless fixture text\n[0.000000] repeated line\n" \
	> "$repeated/dmesg-before.txt"
printf "[0.000000] repeated line\n[1.000000] old WARNING: harmless fixture text\n[0.000000] repeated line\n[2.000000] new harmless line\n" \
	> "$repeated/dmesg-after.txt"
SUITE_DMESG_SCAN=1 SUITE_REQUIRE_DMESG=1 \
	suite_dmesg_scan_snapshots "$repeated"
grep -q $'^status\tclean$' "$repeated/dmesg-scan.tsv"
if grep -q 'old WARNING' "$repeated/dmesg-new.txt"; then
	echo "repeated boundary line pulled old dmesg into the delta" >&2
	exit 1
fi

fatal="$TMP_ROOT/fatal"
write_clean_snapshots "$fatal"
printf "[3.000000] BUG: KASAN: use-after-free in rewrite\n" \
	>> "$fatal/dmesg-after.txt"
if SUITE_DMESG_SCAN=1 SUITE_REQUIRE_DMESG=1 \
	suite_dmesg_scan_snapshots "$fatal"; then
	echo "fatal dmesg signature unexpectedly passed" >&2
	exit 1
fi
grep -q $'^status\tfatal$' "$fatal/dmesg-scan.tsv"
grep -q 'use-after-free' "$fatal/dmesg-fatal.txt"

wrapped="$TMP_ROOT/wrapped"
mkdir -p "$wrapped"
printf "[0.000000] evicted boot line\n" > "$wrapped/dmesg-before.txt"
printf "[9.000000] post-wrap harmless line\n" > "$wrapped/dmesg-after.txt"
SUITE_DMESG_SCAN=1 SUITE_REQUIRE_DMESG=1 \
	suite_dmesg_scan_snapshots "$wrapped"
grep -q 'ring wrapped' "$wrapped/dmesg-new.txt"
grep -q $'^status\tclean$' "$wrapped/dmesg-scan.tsv"

missing="$TMP_ROOT/missing"
mkdir -p "$missing"
: > "$missing/dmesg-before.txt"
: > "$missing/dmesg-after.txt"
if SUITE_DMESG_SCAN=1 SUITE_REQUIRE_DMESG=1 \
	suite_dmesg_scan_snapshots "$missing"; then
	echo "required missing dmesg snapshots unexpectedly passed" >&2
	exit 1
fi
grep -q $'^status\tunavailable$' "$missing/dmesg-scan.tsv"

echo "suite common selftest passed"
