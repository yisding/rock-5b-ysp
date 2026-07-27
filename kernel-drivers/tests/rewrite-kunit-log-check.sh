#!/usr/bin/env bash
# Require the booted rewrite KUnit suites to be present and completely green.
set -euo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$TEST_DIR/../.." && pwd)
# shellcheck source=suite-common.sh disable=SC1091
source "$TEST_DIR/suite-common.sh"

KUNIT_DEBUGFS_ROOT=${KUNIT_DEBUGFS_ROOT:-/sys/kernel/debug/kunit}
KUNIT_REQUIRED_SUITES=${KUNIT_REQUIRED_SUITES:-"rk_mpp_rewrite:85 rockchip-rga-rewrite:148"}
KUNIT_REPORT=${KUNIT_REPORT:-}
KUNIT_DMESG_SOURCE=${KUNIT_DMESG_SOURCE:-}
KUNIT_DEBUG_LOCKS_FILE=${KUNIT_DEBUG_LOCKS_FILE:-/proc/sys/kernel/debug_locks}
KUNIT_REQUIRE_LOCKDEP=${KUNIT_REQUIRE_LOCKDEP:-1}
KUNIT_DMESG_REPORT=${KUNIT_DMESG_REPORT:-}
KUNIT_INTERVAL_REPORT=${KUNIT_INTERVAL_REPORT:-}
KUNIT_FATAL_REPORT=${KUNIT_FATAL_REPORT:-}

if [ -n "$KUNIT_REPORT" ]; then
	report_base=${KUNIT_REPORT%.tsv}
	KUNIT_DMESG_REPORT=${KUNIT_DMESG_REPORT:-"$report_base-dmesg-scan.tsv"}
	KUNIT_INTERVAL_REPORT=${KUNIT_INTERVAL_REPORT:-"$report_base-journal.txt"}
	KUNIT_FATAL_REPORT=${KUNIT_FATAL_REPORT:-"$report_base-fatal.txt"}
fi

write_result()
{
	local row=$1

	printf "%b\n" "$row"
	if [ -n "$KUNIT_REPORT" ]; then
		printf "%b\n" "$row" >> "$KUNIT_REPORT"
	fi
}

check_suite()
{
	local spec=$1
	local suite=${spec%%:*}
	local expected=${spec#*:}
	local results="$KUNIT_DEBUGFS_ROOT/$suite/results"
	local row
	local status=0

	case "$spec" in
	*:*)
		;;
	*)
		echo "invalid KUNIT_REQUIRED_SUITES entry (want suite:count): $spec" >&2
		return 2
		;;
	esac
	case "$expected" in
	''|*[!0-9]*|0)
		echo "invalid KUnit case count in spec: $spec" >&2
		return 2
		;;
	esac

	# debugfs files can report st_size == 0 while returning data when read.
	# Test access, then let the KTAP parser reject empty or malformed content.
	if [ ! -r "$results" ]; then
		echo "missing or unreadable KUnit results for $suite: $results" >&2
		write_result "$suite\t$expected\tmissing\tmissing\tmissing\tmissing\tmissing\tfail\t$(uname -r)"
		return 1
	fi

	if row=$(awk -v suite="$suite" -v expected="$expected" '
	BEGIN {
		plan = -1;
		cases = 0;
		failed = 0;
		skipped = 0;
		summary = "missing";
	}
	/^[[:space:]]+1\.\.[0-9]+[[:space:]]*$/ {
		value = $0;
		sub(/^[[:space:]]+1\.\./, "", value);
		sub(/[[:space:]]+$/, "", value);
		plan = value + 0;
	}
	/^[[:space:]]+(ok|not ok) [0-9]+ / {
		cases++;
		if ($0 ~ /^[[:space:]]+not ok /)
			failed++;
		if ($0 ~ /# SKIP([[:space:]]|$)/)
			skipped++;
	}
	$1 == "ok" && $2 == 1 && $3 == suite {
		summary = "ok";
	}
	$1 == "not" && $2 == "ok" && $3 == 1 && $4 == suite {
		summary = "not-ok";
	}
	END {
		verdict = (plan == expected && cases == expected && failed == 0 &&
		           skipped == 0 && summary == "ok") ? "pass" : "fail";
		printf "%s\t%d\t%d\t%d\t%d\t%d\t%s\t%s", suite, expected,
		       plan, cases, failed, skipped, summary, verdict;
		exit verdict == "pass" ? 0 : 1;
	}
	' "$results"); then
		status=0
	else
		status=$?
	fi
	write_result "$row\t$(uname -r)"
	return "$status"
}

check_boot_log()
{
	local tmp_root
	local boot_log
	local interval
	local fatal
	local report
	local status=clean
	local interval_lines=0
	local fatal_lines=0
	local lockdep_state=unavailable
	local interval_status=0

	tmp_root=$(mktemp -d "${TMPDIR:-$REPO_ROOT}/.rewrite-kunit-dmesg.XXXXXX")
	boot_log="$tmp_root/boot-kernel.txt"
	interval=${KUNIT_INTERVAL_REPORT:-"$tmp_root/kunit-journal.txt"}
	fatal=${KUNIT_FATAL_REPORT:-"$tmp_root/kunit-fatal.txt"}
	report=${KUNIT_DMESG_REPORT:-"$tmp_root/kunit-dmesg-scan.tsv"}
	mkdir -p "$(dirname "$interval")" "$(dirname "$fatal")" "$(dirname "$report")"

	if [ -n "$KUNIT_DMESG_SOURCE" ]; then
		if [ ! -r "$KUNIT_DMESG_SOURCE" ]; then
			status=unavailable
			: > "$boot_log"
		else
			awk '{ print }' "$KUNIT_DMESG_SOURCE" > "$boot_log"
		fi
	elif ! dmesg > "$boot_log" 2> "$tmp_root/dmesg-error.txt"; then
		status=unavailable
		: > "$boot_log"
	fi

	if awk '
		/# Subtest: rk_mpp_rewrite([[:space:]]|$)/ {
			capture = 1;
		}
		capture {
			print;
		}
		capture &&
		/(ok|not ok)[[:space:]]+2[[:space:]]+rockchip-rga-rewrite([[:space:]]|$)/ {
			complete = 1;
			exit;
		}
		END {
			exit capture && complete ? 0 : 2;
		}
	' "$boot_log" > "$interval"; then
		:
	else
		interval_status=$?
		status=unavailable
	fi

	grep -aiE "$SUITE_DMESG_FATAL_RE" "$interval" > "$fatal" || :
	if [ -s "$fatal" ]; then
		status=fatal
	fi

	if [ -r "$KUNIT_DEBUG_LOCKS_FILE" ]; then
		lockdep_state=$(tr -d '[:space:]' < "$KUNIT_DEBUG_LOCKS_FILE")
		[ -n "$lockdep_state" ] || lockdep_state=unavailable
	fi
	if [ "$KUNIT_REQUIRE_LOCKDEP" = "1" ] &&
		[ "$lockdep_state" != "1" ]; then
		status=lockdep-disabled
	fi

	interval_lines=$(wc -l < "$interval" | tr -d '[:space:]')
	fatal_lines=$(wc -l < "$fatal" | tr -d '[:space:]')
	{
		printf "field\tvalue\n"
		printf "status\t%s\n" "$status"
		printf "interval_status\t%s\n" "$interval_status"
		printf "interval_lines\t%s\n" "$interval_lines"
		printf "fatal_lines\t%s\n" "$fatal_lines"
		printf "lockdep_state\t%s\n" "$lockdep_state"
		printf "fatal_regex\t%s\n" "$SUITE_DMESG_FATAL_RE"
	} > "$report"

	rm -rf "$tmp_root"
	if [ "$status" != clean ]; then
		printf "rewrite KUnit boot-log check failed: status=%s interval=%s fatal=%s lockdep=%s report=%s\n" \
			"$status" "$interval_lines" "$fatal_lines" "$lockdep_state" \
			"$KUNIT_DMESG_REPORT" >&2
		return 1
	fi
	printf "rewrite KUnit boot-log check passed: interval=%s lockdep=%s\n" \
		"$interval_lines" "$lockdep_state"
}

selftest()
{
	local tmp_root
	local suite
	local count
	local i

	tmp_root=$(mktemp -d "${TMPDIR:-$REPO_ROOT}/.rewrite-kunit-check.XXXXXX")
	trap 'rm -rf "$tmp_root"' RETURN
	KUNIT_DMESG_SOURCE="$tmp_root/boot-kernel.txt"
	KUNIT_DEBUG_LOCKS_FILE="$tmp_root/debug_locks"
	export KUNIT_DMESG_SOURCE KUNIT_DEBUG_LOCKS_FILE
	printf "1\n" > "$KUNIT_DEBUG_LOCKS_FILE"

	for spec in $KUNIT_REQUIRED_SUITES; do
		suite=${spec%%:*}
		count=${spec#*:}
		mkdir -p "$tmp_root/$suite"
		{
			printf "KTAP version 1\n1..1\n"
			printf "    KTAP version 1\n"
			printf "    # Subtest: %s\n" "$suite"
			printf "    1..%s\n" "$count"
			for i in $(seq 1 "$count"); do
				printf "    ok %s - case_%s\n" "$i" "$i"
			done
			printf "ok 1 %s\n" "$suite"
		} > "$tmp_root/$suite/results"
	done
	{
		printf "KTAP version 1\n1..2\n"
		printf "    # Subtest: rk_mpp_rewrite\n"
		printf "ok 1 rk_mpp_rewrite\n"
		printf "    # Subtest: rockchip-rga-rewrite\n"
		printf "ok 2 rockchip-rga-rewrite\n"
	} > "$KUNIT_DMESG_SOURCE"

	KUNIT_DEBUGFS_ROOT="$tmp_root" KUNIT_REPORT="$tmp_root/result.tsv" \
		"$0" >/dev/null
	for artifact in result.tsv result-journal.txt result-fatal.txt \
		result-dmesg-scan.tsv; do
		if [ ! -e "$tmp_root/$artifact" ]; then
			printf "missing persisted KUnit artifact: %s\n" "$artifact" >&2
			return 1
		fi
	done
	if ! grep -q $'^status\tclean$' "$tmp_root/result-dmesg-scan.tsv"; then
		echo "persisted KUnit boot-log report was not clean" >&2
		return 1
	fi

	sed -i '/ok 1 rk_mpp_rewrite/i WARNING: fixture poisoned the boot' \
		"$KUNIT_DMESG_SOURCE"
	if KUNIT_DEBUGFS_ROOT="$tmp_root" "$0" >/dev/null 2>&1; then
		echo "fatal KUnit interval unexpectedly passed" >&2
		return 1
	fi
	sed -i '/WARNING: fixture poisoned the boot/d' "$KUNIT_DMESG_SOURCE"

	sed -i '/ok 1 rk_mpp_rewrite/i INFO: trying to register non-static key.' \
		"$KUNIT_DMESG_SOURCE"
	if KUNIT_DEBUGFS_ROOT="$tmp_root" "$0" >/dev/null 2>&1; then
		echo "non-static lock key unexpectedly passed" >&2
		return 1
	fi
	sed -i '/INFO: trying to register non-static key./d' \
		"$KUNIT_DMESG_SOURCE"

	sed -i '/ok 2 rockchip-rga-rewrite/d' "$KUNIT_DMESG_SOURCE"
	if KUNIT_DEBUGFS_ROOT="$tmp_root" "$0" >/dev/null 2>&1; then
		echo "incomplete KUnit interval unexpectedly passed" >&2
		return 1
	fi
	printf "ok 2 rockchip-rga-rewrite\n" >> "$KUNIT_DMESG_SOURCE"

	printf "0\n" > "$KUNIT_DEBUG_LOCKS_FILE"
	if KUNIT_DEBUGFS_ROOT="$tmp_root" "$0" >/dev/null 2>&1; then
		echo "disabled lockdep unexpectedly passed" >&2
		return 1
	fi
	printf "1\n" > "$KUNIT_DEBUG_LOCKS_FILE"

	sed -i '0,/    ok 1 - case_1/s//    not ok 1 - case_1/' \
		"$tmp_root/rk_mpp_rewrite/results"
	if KUNIT_DEBUGFS_ROOT="$tmp_root" "$0" >/dev/null 2>&1; then
		echo "failing KUnit case unexpectedly passed" >&2
		return 1
	fi
	sed -i '0,/    not ok 1 - case_1/s//    ok 1 - case_1/' \
		"$tmp_root/rk_mpp_rewrite/results"

	sed -i '/    ok 85 - case_85/d' "$tmp_root/rk_mpp_rewrite/results"
	if KUNIT_DEBUGFS_ROOT="$tmp_root" "$0" >/dev/null 2>&1; then
		echo "incomplete KUnit result set unexpectedly passed" >&2
		return 1
	fi

	# procfs, like debugfs, exposes readable generated files whose stat size is
	# zero. Ensure such a file reaches the parser instead of being called
	# missing. Its non-KTAP content must still fail the result check.
	mv "$tmp_root/rk_mpp_rewrite/results" \
		"$tmp_root/rk_mpp_rewrite/results.fixture"
	ln -s /proc/version "$tmp_root/rk_mpp_rewrite/results"
	if [ ! -r "$tmp_root/rk_mpp_rewrite/results" ] ||
		[ -s "$tmp_root/rk_mpp_rewrite/results" ]; then
		echo "zero-size readable pseudo-file fixture is unavailable" >&2
		return 1
	fi
	if KUNIT_DEBUGFS_ROOT="$tmp_root" "$0" \
		> "$tmp_root/zero-size-readable.out" 2>&1; then
		echo "malformed zero-size KUnit result unexpectedly passed" >&2
		return 1
	fi
	if grep -q "missing or unreadable KUnit results for rk_mpp_rewrite" \
		"$tmp_root/zero-size-readable.out"; then
		echo "readable zero-size KUnit result was incorrectly called missing" >&2
		return 1
	fi

	echo "rewrite KUnit log-check selftest passed"
}

case "${1:-}" in
--selftest)
	selftest
	exit 0
	;;
--help|-h)
	printf "Usage: %s [--selftest]\n" "${0##*/}"
	exit 0
	;;
"")
	;;
*)
	echo "unknown argument: $1" >&2
	exit 2
	;;
esac

failed=0
header="suite\texpected_cases\tplan_cases\tresult_cases\tfailed_cases\tskipped_cases\tsummary\tverdict\tkernel_release"
printf "%b\n" "$header"
if [ -n "$KUNIT_REPORT" ]; then
	mkdir -p "$(dirname "$KUNIT_REPORT")"
	printf "%b\n" "$header" > "$KUNIT_REPORT"
fi
for spec in $KUNIT_REQUIRED_SUITES; do
	check_suite "$spec" || failed=1
done
check_boot_log || failed=1

if [ "$failed" -ne 0 ]; then
	echo "rewrite KUnit compound result check failed" >&2
	exit 1
fi

echo "rewrite KUnit compound result check passed"
