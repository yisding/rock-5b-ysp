#!/usr/bin/env bash
# Check that the Rockchip syzlang draft records the same ABI constants as
# abi-probe.sh builds from the current kernel/librga headers.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SYZ_FILE="${SYZ_FILE:-$SCRIPT_DIR/rockchip_mpp_rga.txt}"
PROBE="${PROBE:-$TEST_DIR/abi-probe.sh}"

tmp="$(mktemp "${TMPDIR:-/tmp}/rk-syz-abi.XXXXXX")"
probe_build_dir="$(mktemp -d "${TMPDIR:-/tmp}/rk-syz-abi-build.XXXXXX")"
trap 'rm -f "$tmp"; rm -rf "$probe_build_dir"' EXIT

set +e
ABI_PROBE_ABI_ONLY=1 BUILD_DIR="${BUILD_DIR:-$probe_build_dir}" \
	"$PROBE" >"$tmp"
probe_status=$?
set -e

case "$probe_status" in
0|77)
	;;
*)
	cat "$tmp" >&2
	echo "abi-probe.sh failed with status $probe_status" >&2
	exit "$probe_status"
	;;
esac

failures=0
checked=0

while IFS= read -r line; do
	case "$line" in
	"# ABI: "*)
		entry="${line#"# ABI: "}"
		label="${entry%%=*}"
		expected="${entry#*=}"
		actual="$(
			awk -v label="$label" '
			{
				line = $0
				sub(/^[[:space:]]+/, "", line)
				if (index(line, label) == 1) {
					print $NF
					exit
				}
			}
			' "$tmp"
		)"

		checked=$((checked + 1))
		if [ -z "$actual" ]; then
			echo "missing ABI probe label: $label" >&2
			failures=$((failures + 1))
		elif [ "$actual" != "$expected" ]; then
			echo "ABI mismatch: $label expected $expected got $actual" >&2
			failures=$((failures + 1))
		fi
		;;
	esac
done <"$SYZ_FILE"

if [ "$checked" -eq 0 ]; then
	echo "no '# ABI:' markers found in $SYZ_FILE" >&2
	exit 1
fi

if [ "$failures" -ne 0 ]; then
	exit 1
fi

echo "PASS: $checked Rockchip syzlang ABI markers match abi-probe.sh"
