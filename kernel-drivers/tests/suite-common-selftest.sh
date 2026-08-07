#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: GPL-2.0-only
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

# Validator-health postflight (retro item 4). A clean dmesg with lockdep
# reported dead must still fail, and the scan records the observed state.
lockdead="$TMP_ROOT/lockdep-dead"
write_clean_snapshots "$lockdead"
printf " lock-classes:  1000 [max: 8192]\n debug_locks:      0\n" \
	> "$lockdead/lockdep_stats"
if SUITE_DMESG_SCAN=1 SUITE_REQUIRE_DMESG=1 \
	SUITE_LOCKDEP_FILE="$lockdead/lockdep_stats" \
	suite_dmesg_scan_snapshots "$lockdead"; then
	echo "disabled lockdep with a clean dmesg unexpectedly passed" >&2
	exit 1
fi
grep -q $'^status\tlockdep-disabled$' "$lockdead/dmesg-scan.tsv"
grep -q $'^lockdep_state\t0$' "$lockdead/dmesg-scan.tsv"

# A live validator (both file formats) passes and is recorded.
lockalive="$TMP_ROOT/lockdep-alive"
write_clean_snapshots "$lockalive"
printf " debug_locks:      1\n" > "$lockalive/lockdep_stats"
SUITE_DMESG_SCAN=1 SUITE_REQUIRE_DMESG=1 \
	SUITE_LOCKDEP_FILE="$lockalive/lockdep_stats" \
	suite_dmesg_scan_snapshots "$lockalive"
grep -q $'^status\tclean$' "$lockalive/dmesg-scan.tsv"
grep -q $'^lockdep_state\t1$' "$lockalive/dmesg-scan.tsv"

lockbare="$TMP_ROOT/lockdep-bare"
write_clean_snapshots "$lockbare"
printf "1\n" > "$lockbare/lockdep_stats"
SUITE_DMESG_SCAN=1 SUITE_REQUIRE_DMESG=1 \
	SUITE_LOCKDEP_FILE="$lockbare/lockdep_stats" \
	suite_dmesg_scan_snapshots "$lockbare"
grep -q $'^lockdep_state\t1$' "$lockbare/dmesg-scan.tsv"

# A kernel without lockdep (file absent) passes, recorded as "absent" — not
# every board runs the debug kernel, and a plain scan must not fail there.
locknone="$TMP_ROOT/lockdep-absent"
write_clean_snapshots "$locknone"
SUITE_DMESG_SCAN=1 SUITE_REQUIRE_DMESG=1 \
	SUITE_LOCKDEP_FILE="$locknone/does-not-exist" \
	suite_dmesg_scan_snapshots "$locknone"
grep -q $'^status\tclean$' "$locknone/dmesg-scan.tsv"
grep -q $'^lockdep_state\tabsent$' "$locknone/dmesg-scan.tsv"

# A fatal dmesg keeps its fatal verdict even when lockdep also died — the
# more actionable signature wins the status field.
bothbad="$TMP_ROOT/fatal-and-lockdead"
write_clean_snapshots "$bothbad"
printf "[3.000000] BUG: KASAN: use-after-free in rewrite\n" \
	>> "$bothbad/dmesg-after.txt"
printf " debug_locks:      0\n" > "$bothbad/lockdep_stats"
if SUITE_DMESG_SCAN=1 SUITE_REQUIRE_DMESG=1 \
	SUITE_LOCKDEP_FILE="$bothbad/lockdep_stats" \
	suite_dmesg_scan_snapshots "$bothbad"; then
	echo "fatal+lockdead unexpectedly passed" >&2
	exit 1
fi
grep -q $'^status\tfatal$' "$bothbad/dmesg-scan.tsv"

# Ownership handback. The gates run unprivileged, so what is checkable here
# is that the helper stays a silent no-op off the sudo path and never fails
# its caller: it runs late in every suite, and an error there would turn a
# green run red after the evidence was already written.
reown="$TMP_ROOT/reown"
mkdir -p "$reown"
printf "artifact\n" > "$reown/artifact.txt"
reown_before=$(stat -c '%u:%g' "$reown/artifact.txt")

suite_reown_to_invoking_user "$reown"
if [ "$(stat -c '%u:%g' "$reown/artifact.txt")" != "$reown_before" ]; then
	echo "reown changed ownership when it should have been a no-op" >&2
	exit 1
fi

# A path that does not exist, and no paths at all, are both tolerated.
suite_reown_to_invoking_user "$reown/absent" "$reown"
suite_reown_to_invoking_user

# Under sudo the helper must still succeed rather than abort the suite when
# the chown cannot be performed; simulate the sudo path as an unprivileged
# user, where every chown is refused.
if [ "$(id -u)" != "0" ]; then
	if ! SUDO_UID=0 SUDO_GID=0 \
		suite_reown_to_invoking_user "$reown" 2>/dev/null; then
		echo "reown failed its caller when chown was refused" >&2
		exit 1
	fi
fi

# Multi-step payloads must preserve the first unhandled failure even though the
# caller has disabled errexit to collect the status.
strict_log="$TMP_ROOT/strict.log"
strict_after="$TMP_ROOT/strict-after"
strict_payload()
{
	printf 'before failure\n'
	false
	printf 'after failure\n' > "$strict_after"
}
set +e
suite_run_strict "$strict_log" strict_payload
strict_status=$?
set -e
if [ "$strict_status" -eq 0 ] || [ -e "$strict_after" ]; then
	echo "strict payload boundary masked an intermediate failure" >&2
	exit 1
fi
grep -q 'before failure' "$strict_log"

# Artifact metadata is emitted only for nonempty regular files.
artifact_good="$TMP_ROOT/artifact.good"
artifact_empty="$TMP_ROOT/artifact.empty"
printf 'data' > "$artifact_good"
: > "$artifact_empty"
artifact_metadata=$(suite_artifact_metadata "$artifact_good")
case "$artifact_metadata" in
4$'\t'[0-9a-f][0-9a-f]*) ;;
*)
	printf 'unexpected artifact metadata: %s\n' "$artifact_metadata" >&2
	exit 1
	;;
esac
if suite_artifact_metadata "$artifact_empty" >/dev/null 2>&1; then
	echo "empty artifact unexpectedly produced metadata" >&2
	exit 1
fi
if suite_artifact_metadata "$TMP_ROOT/artifact.missing" >/dev/null 2>&1; then
	echo "missing artifact unexpectedly produced metadata" >&2
	exit 1
fi

echo "suite common selftest passed"
