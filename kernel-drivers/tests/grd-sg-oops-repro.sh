#!/bin/bash
# Reproduce the GRD/RKMPP system-heap scatterlist corruption oops without RDP.
#
# Rationale: the finding's trigger is a *fresh* RKMPP H.264 encoder at
# 2064x1296 whose first (force-IDR) frame ends CPU access on a 24-entry
# system-heap output packet buffer. GRD reaches that via a full RDP login;
# mpi_enc_test reaches the same libmpp path in ~40ms. So churn process
# starts (fresh buffer + fresh sg_table each time) rather than long runs.
#
# GRD configured stride 2112x1344 then 2112x1296, so mirror that stride and
# alternate vstride to also exercise the reconfigure.
#
# Context and interpretation:
#   findings/2026-07-27-grd-sg-corruption-kasan-non-reproduction.md
#   kernel-drivers/docs/grd-sg-corruption-repro-plan.md
#
# Usage: [ITERS=400] [INSTANCES=4] [WORKDIR=<dir>] bash grd-sg-oops-repro.sh
# Exit:  0 clean, 10 kernel taint moved, 11 kernel debug report seen.

set -u

ITERS=${ITERS:-400}
INSTANCES=${INSTANCES:-4}
# Logs are machine captures: keep them out of the repo (CONTRIBUTING.md).
WORKDIR=${WORKDIR:-$HOME/Code/tmp/sg-oops-repro}
mkdir -p "$WORKDIR"
cd "$WORKDIR" || { echo "cannot enter WORKDIR $WORKDIR" >&2; exit 2; }

if ! command -v mpi_enc_test >/dev/null; then
    echo "mpi_enc_test not found — install rockchip-mpp-demos" >&2
    exit 2
fi

BASE_TAINT=$(cat /proc/sys/kernel/tainted)
echo "start: $(date -Is) kernel=$(uname -r) base_taint=$BASE_TAINT iters=$ITERS inst=$INSTANCES"
echo "logs:  $WORKDIR"

for i in $(seq 1 "$ITERS"); do
    # alternate vstride to mirror GRD's 1344 -> 1296 reconfigure
    if (( i % 2 )); then VS=1344; else VS=1296; fi

    timeout 60 mpi_enc_test -w 2064 -h 1296 -hstride 2112 -vstride "$VS" \
        -t 7 -n 3 -s "$INSTANCES" -o /dev/null >"iter-$i.log" 2>&1
    rc=$?

    taint=$(cat /proc/sys/kernel/tainted)
    if [[ "$taint" != "$BASE_TAINT" ]]; then
        echo "TAINT CHANGED at iter $i: $BASE_TAINT -> $taint (rc=$rc)"
        exit 10
    fi

    # any kernel debug report is a hit
    if dmesg 2>/dev/null | grep -qiE "KASAN|BUG:|Oops|Unable to handle|DMA-API:.*(free|sync)|page_owner"; then
        echo "KERNEL REPORT at iter $i (rc=$rc)"
        exit 11
    fi

    if (( rc != 0 )); then
        echo "iter $i: mpi_enc_test rc=$rc (see iter-$i.log)"
    else
        rm -f "iter-$i.log"
    fi

    (( i % 50 == 0 )) && echo "  ...iter $i clean, taint=$taint $(date -Is)"
done

echo "done: $ITERS iterations, no oops, taint=$(cat /proc/sys/kernel/tainted)"
