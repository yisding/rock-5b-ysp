#!/usr/bin/env bash
# Record and compare normalized MPP/RGA ABI probe logs across kernel profiles.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/../.." && pwd)"

PROFILE="${PROFILE:-$(uname -r)}"
LOG_DIR="${LOG_DIR:-$ROOT_DIR/kernel-drivers/tests/logs/abi-replay}"
BASELINE="${BASELINE:-}"

mkdir -p "$LOG_DIR"

raw_log="$LOG_DIR/$PROFILE.raw.log"
norm_log="$LOG_DIR/$PROFILE.norm.log"

normalize_log() {
  sed -E \
    -e 's/(\/dev\/[^ ]+[[:space:]]+)fd=[0-9]+/\1fd=<fd>/g' \
    -e 's/((virtual_import_handle|config_request_id|config_src_handle|config_dst_handle)[[:space:]]+)[0-9]+/\1<id>/g'
}

set +e
"$TEST_DIR/abi-probe.sh" "$@" | tee "$raw_log"
probe_status=${PIPESTATUS[0]}
set -e

normalize_log < "$raw_log" > "$norm_log"

echo "Wrote raw ABI log:        $raw_log"
echo "Wrote normalized ABI log: $norm_log"

if [ "$probe_status" -ne 0 ]; then
  exit "$probe_status"
fi

if [ -n "$BASELINE" ]; then
  baseline_log="$LOG_DIR/$BASELINE.norm.log"
  if [ ! -e "$baseline_log" ]; then
    echo "Missing baseline normalized log: $baseline_log" >&2
    exit 2
  fi

  diff -u "$baseline_log" "$norm_log"
fi
