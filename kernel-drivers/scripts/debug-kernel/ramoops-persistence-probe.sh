#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: sudo bash ramoops-persistence-probe.sh <write|read|dump>

Decisive test for whether the ramoops window (0x118000-0x1e8000) survives a
warm reset on this board, independent of the kernel's ramoops driver.

  write  Stamp a recognizable 4 KiB pattern at several offsets inside the
         window via /dev/mem and save reference copies under
         /var/tmp/ramoops-probe/.
  read   After a reboot, re-read those offsets and classify each as
         INTACT / CORRUPTED / ZEROED / GARBAGE against the saved copies.
  dump   Hexdump the first 64 bytes of each probe offset (no comparison).

Test procedure (two reboots total):
  1. Add "initcall_blacklist=ramoops_init" to extraargs in
     /boot/armbianEnv.txt and reboot, so the kernel's ramoops driver cannot
     zap or overwrite the window while we test. (The driver zeroes zones
     whose header/ECC fails validation, which destroys the evidence.)
  2. sudo bash ramoops-persistence-probe.sh write
  3. reboot   (warm reset -- do NOT power-cycle)
  4. sudo bash ramoops-persistence-probe.sh read
  5. Remove the extraargs entry again.

Interpretation:
  INTACT     Firmware preserves the window. ramoops failure is kernel-side
             (most likely ecc-size validation zapping decayed content, or
             zone layout). Fix in the DT patch and retest.
  CORRUPTED  DRAM mostly survives but with bit decay across the reset.
             Drop ecc-size=16 (ECC rejects whole blocks); plain ramoops
             tolerates scattered bit errors in console text.
  ZEROED     Something in TPL/SPL/BL31/U-Boot actively clears the window on
             the way up; needs firmware-side hunting (try a different rkbin
             DDR blob, or ddrbin_tool pstore_base_addr configuration).
  GARBAGE    DRAM content is lost or scrambled across the reset; no ramoops
             address can work. Use netconsole or serial console instead.

Probes only touch the no-map reserved region the debug-kernel DT patch
declares (0x118000 + 0xd0000). Nothing outside it is written.
EOF
}

MODE="${1:-}"
case "${MODE}" in
  -h|--help|"") usage; [[ -z "${MODE}" ]] && exit 2; exit 0 ;;
  write|read|dump) ;;
  *) echo "Unknown argument: ${MODE}" >&2; usage >&2; exit 2 ;;
esac

if [[ "${EUID}" -ne 0 ]]; then
  exec sudo "$0" "$@"
fi

# All offsets lie inside the kernel's no-map reservation 0x118000-0x1e8000
# (spread across the record, console and pmsg zones plus the tail page).
PROBE_OFFSETS=(0x118000 0x138000 0x158000 0x198000 0x1d8000 0x1e7000)
BLOCK=4096
STATE_DIR="/var/tmp/ramoops-probe"

if [[ -d /sys/module/ramoops || -e /dev/pmsg0 ]]; then
  echo "WARNING: ramoops driver appears active this boot." >&2
  echo "Its console zone overwrites probes continuously and its init zaps" >&2
  echo "invalid zones. Boot with initcall_blacklist=ramoops_init for a" >&2
  echo "clean test (see --help). Continuing anyway..." >&2
fi

read_block() { # offset -> stdout
  dd if=/dev/mem bs="${BLOCK}" skip=$(( $1 / BLOCK )) count=1 status=none
}

write_block() { # offset, file
  dd if="$2" of=/dev/mem bs="${BLOCK}" seek=$(( $1 / BLOCK )) count=1 \
     conv=notrunc status=none
}

case "${MODE}" in
  write)
    mkdir -p "${STATE_DIR}"
    stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ) boot=$(cat /proc/sys/kernel/random/boot_id)"
    for off in "${PROBE_OFFSETS[@]}"; do
      ref="${STATE_DIR}/probe-${off}.bin"
      line="RAMOOPS-PROBE off=${off} ${stamp} "
      # Fill exactly BLOCK bytes with the repeating text line.
      yes "${line}" | tr -d '\n' | head -c "${BLOCK}" > "${ref}"
      write_block "${off}" "${ref}"
      # Immediate read-back sanity check (writes go through an uncached
      # kernel mapping, so this verifies the pattern landed in DRAM).
      if cmp -s "${ref}" <(read_block "${off}"); then
        echo "wrote ${off}: OK (read-back verified)"
      else
        echo "wrote ${off}: READ-BACK MISMATCH (write did not land?)" >&2
      fi
    done
    echo
    echo "Now reboot (warm reset, no power-cycle) and run: $0 read"
    ;;

  read)
    fail=0
    for off in "${PROBE_OFFSETS[@]}"; do
      ref="${STATE_DIR}/probe-${off}.bin"
      if [[ ! -f "${ref}" ]]; then
        echo "${off}: no reference copy (run 'write' first)" >&2
        fail=1
        continue
      fi
      cur="$(mktemp)"
      read_block "${off}" > "${cur}"
      if cmp -s "${ref}" "${cur}"; then
        verdict="INTACT"
      elif ! tr -d '\0' < "${cur}" | head -c1 | grep -q .; then
        verdict="ZEROED"
      else
        # Count differing bytes to separate bit-decay from total loss.
        diff_bytes=$(cmp -l "${ref}" "${cur}" 2>/dev/null | wc -l)
        if (( diff_bytes < BLOCK / 4 )); then
          verdict="CORRUPTED (${diff_bytes}/${BLOCK} bytes differ)"
        else
          verdict="GARBAGE (${diff_bytes}/${BLOCK} bytes differ)"
        fi
      fi
      echo "${off}: ${verdict}"
      rm -f "${cur}"
    done
    exit "${fail}"
    ;;

  dump)
    for off in "${PROBE_OFFSETS[@]}"; do
      echo "--- ${off} ---"
      read_block "${off}" | head -c 64 | od -A x -t x1z
    done
    ;;
esac
