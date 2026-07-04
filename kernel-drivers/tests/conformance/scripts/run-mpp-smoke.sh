#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PROFILE=${PROFILE:-${1:-rewrite}}
MPP_BIN_DIR=${MPP_BIN_DIR:-"$ROOT/out/mpp/bin"}
OUT="$ROOT/logs/$PROFILE/$(date +%Y%m%d-%H%M%S)-mpp"

mkdir -p "$OUT"

if [ ! -x "$MPP_BIN_DIR/mpp_info_test" ]; then
    echo "Missing $MPP_BIN_DIR/mpp_info_test. Run ./scripts/build-mpp.sh first." >&2
    exit 1
fi

export LD_LIBRARY_PATH="$ROOT/out/mpp/lib:${LD_LIBRARY_PATH:-}"

set +e
"$MPP_BIN_DIR/mpp_info_test" > "$OUT/mpp_info_test.log" 2>&1
status=$?
set -e
echo "$status" > "$OUT/mpp_info_test.status"

if [ -n "${MPP_DEC_INPUT:-}" ]; then
    : "${MPP_DEC_TYPE:?Set MPP_DEC_TYPE when MPP_DEC_INPUT is set}"
    dec_cmd=("$MPP_BIN_DIR/mpi_dec_test" -i "$MPP_DEC_INPUT" -t "$MPP_DEC_TYPE" -n "${MPP_DEC_FRAMES:-120}")
    if [ -n "${MPP_DEC_OUTPUT:-}" ]; then
        dec_cmd+=(-o "$MPP_DEC_OUTPUT")
    fi
    "${dec_cmd[@]}" > "$OUT/mpi_dec_test.log" 2>&1
fi

if [ -n "${MPP_ENC_INPUT:-}" ]; then
    : "${MPP_ENC_WIDTH:?Set MPP_ENC_WIDTH when MPP_ENC_INPUT is set}"
    : "${MPP_ENC_HEIGHT:?Set MPP_ENC_HEIGHT when MPP_ENC_INPUT is set}"
    : "${MPP_ENC_FORMAT:?Set MPP_ENC_FORMAT when MPP_ENC_INPUT is set}"
    : "${MPP_ENC_TYPE:?Set MPP_ENC_TYPE when MPP_ENC_INPUT is set}"
    enc_cmd=(
        "$MPP_BIN_DIR/mpi_enc_test"
        -i "$MPP_ENC_INPUT"
        -w "$MPP_ENC_WIDTH"
        -h "$MPP_ENC_HEIGHT"
        -f "$MPP_ENC_FORMAT"
        -t "$MPP_ENC_TYPE"
        -n "${MPP_ENC_FRAMES:-120}"
    )
    if [ -n "${MPP_ENC_OUTPUT:-}" ]; then
        enc_cmd+=(-o "$MPP_ENC_OUTPUT")
    fi
    "${enc_cmd[@]}" > "$OUT/mpi_enc_test.log" 2>&1
fi

dmesg | tail -n 300 > "$OUT/dmesg-tail.txt" 2>/dev/null || true
echo "$OUT"
