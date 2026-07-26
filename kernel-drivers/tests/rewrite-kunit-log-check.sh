#!/usr/bin/env bash
# Require the booted rewrite KUnit suites to be present and completely green.
set -euo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$TEST_DIR/../.." && pwd)

KUNIT_DEBUGFS_ROOT=${KUNIT_DEBUGFS_ROOT:-/sys/kernel/debug/kunit}
KUNIT_REQUIRED_SUITES=${KUNIT_REQUIRED_SUITES:-"rk_mpp_rewrite:90 rockchip-rga-rewrite:147"}
KUNIT_REPORT=${KUNIT_REPORT:-}

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

	if [ ! -s "$results" ]; then
		echo "missing KUnit results for $suite: $results" >&2
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

selftest()
{
	local tmp_root
	local suite
	local count
	local i

	tmp_root=$(mktemp -d "${TMPDIR:-$REPO_ROOT}/.rewrite-kunit-check.XXXXXX")
	trap 'rm -rf "$tmp_root"' RETURN

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

	KUNIT_DEBUGFS_ROOT="$tmp_root" "$0" >/dev/null

	sed -i '0,/    ok 1 - case_1/s//    not ok 1 - case_1/' \
		"$tmp_root/rk_mpp_rewrite/results"
	if KUNIT_DEBUGFS_ROOT="$tmp_root" "$0" >/dev/null 2>&1; then
		echo "failing KUnit case unexpectedly passed" >&2
		return 1
	fi
	sed -i '0,/    not ok 1 - case_1/s//    ok 1 - case_1/' \
		"$tmp_root/rk_mpp_rewrite/results"

	sed -i '/    ok 90 - case_90/d' "$tmp_root/rk_mpp_rewrite/results"
	if KUNIT_DEBUGFS_ROOT="$tmp_root" "$0" >/dev/null 2>&1; then
		echo "incomplete KUnit result set unexpectedly passed" >&2
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

if [ "$failed" -ne 0 ]; then
	echo "rewrite KUnit result check failed" >&2
	exit 1
fi

echo "rewrite KUnit result check passed"
