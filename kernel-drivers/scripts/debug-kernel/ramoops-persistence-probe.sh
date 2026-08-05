#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: sudo bash ramoops-persistence-probe.sh <write|read|dump> [offset...]

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
  INTACT     The sampled pages retained this marker. This makes a Linux-side
             ramoops/layout test worthwhile; it does not prove pstore works.
  CORRUPTED  The sampled pages changed but retained substantial marker data.
             Preserve the full dump before proposing decay or ECC changes.
  ZEROED     The sampled pages became deterministic zeros. Exact TPL/SPL/
             BL31/U-Boot audits found no direct writer into this interval, so
             this class does not identify the actor or operation.
  GARBAGE    The sampled pages changed substantially. This does not by itself
             prove scrambling, DRAM-wide loss, or that no other range works.

Current evidence and the next temporal witness:
  boot-firmware/docs/ramoops-retention.md

By default probes touch only the no-map reserved region the debug-kernel DT
patch declares (0x118000 + 0xd0000). Extra offsets given after the mode
REPLACE the default list — used with the ramoops-probe-nomap.dts overlay
(sudo armbian-add-overlay ramoops-probe-nomap.dts, then reboot) to test
no-map islands elsewhere in DRAM, e.g.:

  sudo bash ramoops-persistence-probe.sh write 0x40000000 0x80000000 0x180000000

The default offsets are inside the dedicated no-map reservation. Extra offsets
are advanced use: confirm that every page is reserved/no-map in the live DT
before writing it. STRICT_DEVMEM is an additional guard on this kernel, not a
portable safety guarantee.
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

# Default offsets lie inside the kernel's no-map reservation 0x118000-0x1e8000
# (spread across the record, console and pmsg zones plus the tail page).
# Any offsets given after the mode replace this list (see --help).
if [[ $# -gt 1 ]]; then
  PROBE_OFFSETS=("${@:2}")
else
  PROBE_OFFSETS=(0x118000 0x138000 0x158000 0x198000 0x1d8000 0x1e7000)
fi
BLOCK=4096
STATE_DIR="/var/tmp/ramoops-probe"

# /sys/module/ramoops exists whenever the driver is built-in (it only holds
# module parameters), so it says nothing about whether the driver ran. The
# driver actually being active means its platform driver registered (which
# initcall_blacklist=ramoops_init prevents) or /dev/pmsg0 was created.
if [[ -d /sys/bus/platform/drivers/ramoops || -e /dev/pmsg0 ]]; then
  echo "WARNING: ramoops driver appears active this boot." >&2
  echo "Its console zone overwrites probes continuously and its init zaps" >&2
  echo "invalid zones. Boot with initcall_blacklist=ramoops_init for a" >&2
  echo "clean test (see --help). Continuing anyway..." >&2
fi

# /dev/mem must be accessed via mmap here, not read()/write(): on arm64,
# read_mem/write_mem go through valid_phys_addr_range(), which rejects any
# MEMBLOCK_NOMAP range (arch/arm64/mm/mmap.c) -- exactly what our no-map
# ramoops reservation is, so dd fails with EFAULT ("Bad address"). The mmap
# path checks devmem_is_allowed(), and arm64 maps no-map pfns noncached. Keep
# writes inside a live, verified reservation; do not infer universal safety
# from this kernel's STRICT_DEVMEM behavior.
PYMEM='
import mmap, os, sys
mode, off = sys.argv[1], int(sys.argv[2], 0)
BLOCK = 4096
if mode == "write":
    data = open(sys.argv[3], "rb").read(BLOCK)
    fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
    mm = mmap.mmap(fd, BLOCK, mmap.MAP_SHARED,
                   mmap.PROT_READ | mmap.PROT_WRITE, offset=off)
    mm[:len(data)] = data
else:
    fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
    mm = mmap.mmap(fd, BLOCK, mmap.MAP_SHARED, mmap.PROT_READ, offset=off)
    sys.stdout.buffer.write(mm[:])
mm.close(); os.close(fd)
'

read_block() { # offset -> stdout
  /usr/bin/python3 -c "${PYMEM}" read "$1"
}

write_block() { # offset, file
  /usr/bin/python3 -c "${PYMEM}" write "$1" "$2"
}

case "${MODE}" in
  write)
    mkdir -p "${STATE_DIR}"
    stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ) boot=$(cat /proc/sys/kernel/random/boot_id)"
    for off in "${PROBE_OFFSETS[@]}"; do
      ref="${STATE_DIR}/probe-${off}.bin"
      line="RAMOOPS-PROBE off=${off} ${stamp} "
      # Fill exactly BLOCK bytes with the repeating text line. Built in a
      # variable, not `yes | head -c` -- under `set -o pipefail` head's
      # early exit SIGPIPEs yes (141) and silently kills the script.
      buf=""
      while (( ${#buf} < BLOCK )); do buf+="${line}"; done
      printf '%s' "${buf:0:BLOCK}" > "${ref}"
      write_block "${off}" "${ref}"
      # Immediate read-back sanity check (the mapping is noncached, so
      # this verifies the pattern landed in DRAM).
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
      elif [[ -z "$(tr -d '\0' < "${cur}")" ]]; then
        verdict="ZEROED"
      else
        # Count differing bytes to separate bit-decay from total loss.
        # (cmp exits 1 on difference; keep that from tripping set -e.)
        diff_bytes=$( (cmp -l "${ref}" "${cur}" 2>/dev/null || true) | wc -l)
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
