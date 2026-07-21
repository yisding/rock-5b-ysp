#!/usr/bin/env bash
# Record and compare normalized MPP/RGA ABI probe logs across kernel profiles.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/../.." && pwd)"

PROFILE="${PROFILE:-$(uname -r)}"
LOG_DIR="${LOG_DIR:-$ROOT_DIR/kernel-drivers/tests/logs/abi-replay}"
BASELINE="${BASELINE:-}"

case "$PROFILE" in
  *rewrite*)
    : "${ABI_PROBE_ENABLE_RGA_PHYSICAL:=1}"
    : "${ABI_PROBE_EXPECT_RGA_PHYSICAL_REJECT:=1}"
    export ABI_PROBE_ENABLE_RGA_PHYSICAL
    export ABI_PROBE_EXPECT_RGA_PHYSICAL_REJECT
    ;;
esac

mkdir -p "$LOG_DIR"

raw_log="$LOG_DIR/$PROFILE.raw.log"
norm_log="$LOG_DIR/$PROFILE.norm.log"
compare_log="$LOG_DIR/$PROFILE.compare.log"
contract_log="$LOG_DIR/$PROFILE.contract.log"

normalize_log() {
  sed -E \
    -e 's/(\/dev\/[^ ]+[[:space:]]+)fd=[0-9]+/\1fd=<fd>/g' \
    -e 's/(dmabuf_heap[[:space:]]+).*/\1<heap>/g' \
    -e 's/(dmabuf_iova[[:space:]]+)0x[0-9a-fA-F]+/\1<iova>/g' \
    -e 's/((virtual_import_handle|dmabuf_import_handle|physical_import_handle|config_request_id|config_src_handle|config_dst_handle)[[:space:]]+)[0-9]+/\1<id>/g'
}

extract_compare_log() {
  awk '!/^[[:space:]]+(RGA_IOC_IMPORT_BUFFER physical|RGA_IOC_RELEASE_BUFFER physical|physical_import_handle|physical_import_probe|physical_import_reject)/'
}

extract_contract_log() {
  grep -E \
    -e '^rkcompat abi probe$' \
    -e '^mpp:$' \
    -e '^rga:$' \
    -e '^[[:space:]]+(MPP_IOC_CFG_V[12]|sizeof mpp_|MPP_FLAGS_|QUERY_HW_SUPPORT|hw_support|QUERY_CMD_SUPPORT|cmd_butt|INIT_CLIENT_TYPE|QUERY_HW_ID|hw_id|INIT_DRIVER_DATA zero|SEND_CODEC_INFO width|SET_ERR_REF_HACK|RESET_SESSION|MULTI init\+driver|SET_SESSION_FD|bad_fd_bat_ret|done_bat_ret|TRANS_FD_TO_IOVA dmabuf|dmabuf_iova|RELEASE_FD dmabuf)' \
    -e '^[[:space:]]+(RGA_(BLIT|FLUSH|GET|CACHE|IOC)|RGA2_GET|sizeof rga_|legacy_|driver_version_|hw_version_count|hw\[[0-9]+]|dmabuf_import_handle)' |
    extract_compare_log
}

fail_selftest()
{
  printf "abi replay selftest failed: %s\n" "$1" >&2
  return 1
}

selftest()
{
  local tmp_root

  tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/rk-abi-replay.XXXXXX")"
  trap 'rm -rf "$tmp_root"' RETURN

  cat > "$tmp_root/raw.log" <<EOF
rkcompat abi probe
mpp:
  /dev/mpp_service               fd=12
  MPP_IOC_CFG_V1                 0x40047601
  TRANS_FD_TO_IOVA dmabuf        ret=0
  dmabuf_iova                    0xff001000
rga:
  /dev/rga                       fd=7
  RGA_IOC_IMPORT_BUFFER physical ret=-1 errno=95 (Operation not supported)
  physical_import_reject         expected errno=95 (Operation not supported)
  physical_import_probe          disabled
  RGA_IOC_GET_HW_VERSION         ret=1
  RGA_IOC_REQUEST_CONFIG missing pat ret=-1 errno=14 (Bad address)
  RGA_IOC_REQUEST_CONFIG unsupported ret=-1 errno=14 (Bad address)
  config_request_id              42
  config_src_handle              43
  config_dst_handle              44
  dmabuf_import_handle           45
EOF

  normalize_log < "$tmp_root/raw.log" > "$tmp_root/norm.log"
  extract_compare_log < "$tmp_root/norm.log" > "$tmp_root/compare.log"
  extract_contract_log < "$tmp_root/norm.log" > "$tmp_root/contract.log"

  grep -Eq '/dev/mpp_service[[:space:]]+fd=<fd>' "$tmp_root/norm.log" ||
    fail_selftest "fd normalization missing"
  grep -Eq 'config_request_id[[:space:]]+<id>' "$tmp_root/norm.log" ||
    fail_selftest "request id normalization missing"
  grep -Eq 'dmabuf_iova[[:space:]]+<iova>' "$tmp_root/norm.log" ||
    fail_selftest "iova normalization missing"
  if grep -Eq 'physical(_import| ret=)' "$tmp_root/compare.log"; then
    fail_selftest "physical import lines leaked into compare log"
  fi
  grep -Eq 'RGA_IOC_REQUEST_CONFIG unsupported[[:space:]]+ret=-1 errno=14' \
    "$tmp_root/contract.log" ||
    fail_selftest "unsupported request errno missing from contract log"
  grep -Eq 'RGA_IOC_REQUEST_CONFIG missing pat[[:space:]]+ret=-1 errno=14' \
    "$tmp_root/contract.log" ||
    fail_selftest "missing-pattern request errno missing from contract log"
  if grep -Eq 'physical(_import| ret=)' "$tmp_root/contract.log"; then
    fail_selftest "physical import lines leaked into contract log"
  fi

  printf "PASS: abi replay selftest\n"
}

case "${1:-}" in
--selftest)
  selftest
  exit 0
  ;;
esac

set +e
"$TEST_DIR/abi-probe.sh" "$@" | tee "$raw_log"
probe_status=${PIPESTATUS[0]}
set -e

normalize_log < "$raw_log" > "$norm_log"
extract_compare_log < "$norm_log" > "$compare_log"
extract_contract_log < "$norm_log" > "$contract_log"

echo "Wrote raw ABI log:        $raw_log"
echo "Wrote normalized ABI log: $norm_log"
echo "Wrote comparable ABI log: $compare_log"
echo "Wrote contract ABI log:   $contract_log"

if [ "$probe_status" -ne 0 ]; then
  exit "$probe_status"
fi

if [ -n "$BASELINE" ]; then
  baseline_log="$LOG_DIR/$BASELINE.norm.log"
  baseline_compare="$LOG_DIR/$BASELINE.compare.log"
  if [ ! -e "$baseline_log" ]; then
    echo "Missing baseline normalized log: $baseline_log" >&2
    exit 2
  fi
  if [ ! -e "$baseline_compare" ]; then
    extract_compare_log < "$baseline_log" > "$baseline_compare"
  fi

  diff -u "$baseline_compare" "$compare_log"

  baseline_contract="$LOG_DIR/$BASELINE.contract.log"
  if [ ! -e "$baseline_contract" ]; then
    echo "Missing baseline contract log: $baseline_contract" >&2
    exit 2
  fi

  diff -u "$baseline_contract" "$contract_log"
fi
