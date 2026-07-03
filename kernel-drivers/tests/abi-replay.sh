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
contract_log="$LOG_DIR/$PROFILE.contract.log"

normalize_log() {
  sed -E \
    -e 's/(\/dev\/[^ ]+[[:space:]]+)fd=[0-9]+/\1fd=<fd>/g' \
    -e 's/((virtual_import_handle|config_request_id|config_src_handle|config_dst_handle)[[:space:]]+)[0-9]+/\1<id>/g'
}

extract_contract_log() {
  grep -E \
    -e '^rkcompat abi probe$' \
    -e '^mpp:$' \
    -e '^rga:$' \
    -e '^[[:space:]]+(MPP_IOC_CFG_V[12]|sizeof mpp_|MPP_FLAGS_|QUERY_HW_SUPPORT|hw_support|QUERY_CMD_SUPPORT|cmd_butt|INIT_CLIENT_TYPE|QUERY_HW_ID|hw_id|INIT_DRIVER_DATA zero|SEND_CODEC_INFO width|SET_ERR_REF_HACK|RESET_SESSION|MULTI init\+driver|SET_SESSION_FD|bad_fd_bat_ret|done_bat_ret)' \
    -e '^[[:space:]]+(RGA_(BLIT|FLUSH|GET|CACHE|IOC)|RGA2_GET|sizeof rga_|legacy_|driver_version_|hw_version_count|hw\[[0-9]+])'
}

set +e
"$TEST_DIR/abi-probe.sh" "$@" | tee "$raw_log"
probe_status=${PIPESTATUS[0]}
set -e

normalize_log < "$raw_log" > "$norm_log"
extract_contract_log < "$norm_log" > "$contract_log"

echo "Wrote raw ABI log:        $raw_log"
echo "Wrote normalized ABI log: $norm_log"
echo "Wrote contract ABI log:   $contract_log"

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

  baseline_contract="$LOG_DIR/$BASELINE.contract.log"
  if [ ! -e "$baseline_contract" ]; then
    echo "Missing baseline contract log: $baseline_contract" >&2
    exit 2
  fi

  diff -u "$baseline_contract" "$contract_log"
fi
