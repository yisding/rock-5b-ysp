#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: GPL-2.0-or-later
# Discriminate the ROCK 5B 26.2.1 raw-SD U-Boot failure hypotheses.

set -euo pipefail

readonly SCRIPT_NAME="${0##*/}"
readonly SECTOR_SIZE=512
readonly GAP_START_SECTOR=64
readonly GAP_END_SECTOR=32768
readonly GAP_SECTORS=$((GAP_END_SECTOR - GAP_START_SECTOR))
readonly GAP_BYTES=$((GAP_SECTORS * SECTOR_SIZE))
readonly IDB_SECTOR=64
readonly FIT_SECTOR=16384
readonly FIT_RELATIVE_SECTORS=$((FIT_SECTOR - GAP_START_SECTOR))
readonly FIT_RELATIVE_BYTES=$((FIT_RELATIVE_SECTORS * SECTOR_SIZE))
readonly FIT_TAIL_SECTORS=$((GAP_END_SECTOR - FIT_SECTOR))
readonly FIT_TAIL_BYTES=$((FIT_TAIL_SECTORS * SECTOR_SIZE))

readonly EXPECTED_IDB_SHA256="f9dbc3b5fa6178bd68b756ac8203f05dbd78c2086d794d4d9bbbf805dcad4f72"
readonly EXPECTED_FIT_SHA256="98e2c8af220907929221c1677c4c09dc9be3bdec5fa43ded738a124763988779"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ACTION=""
DEVICE=""
BASELINE=""
OUTPUT=""
VARIANT=""
ARTIFACT_DIR="${ARTIFACT_DIR:-/usr/lib/linux-u-boot-current-rock-5b}"
YES=0
DRY_RUN=0
FORCE_DEVICE=0
ALLOW_UNPINNED=0

usage() {
    cat <<'EOF'
Usage:
  rock5b-sd-uboot-hypothesis-test.sh capture --device /dev/DEVICE [--output FILE]
  rock5b-sd-uboot-hypothesis-test.sh inspect --device /dev/DEVICE [--baseline FILE]
  rock5b-sd-uboot-hypothesis-test.sh apply --device /dev/DEVICE --baseline FILE \
      --variant fit-only|loader-only|both [options]
  rock5b-sd-uboot-hypothesis-test.sh restore --device /dev/DEVICE --baseline FILE [options]

Actions:
  capture      Save sectors 64..32767, their SHA-256, and an identity report.
  inspect      Read device/artifact identity without writing anything.
  apply        Require the pristine baseline on-device, then apply one variant.
  restore      Restore the complete captured raw loader gap and verify it.

Variants:
  fit-only     Keep the 26.2.1 idbloader (DDR/SPL); replace only u-boot.itb.
  loader-only  Replace idbloader (DDR/SPL); keep the 26.2.1 u-boot.itb.
  both         Replace idbloader and u-boot.itb (positive-control candidate).

Options:
  --device PATH          Whole SD device, never a partition (required).
  --baseline FILE        Exact capture made by this script.
  --output FILE          Capture destination. Default: downloads/sd-bootarea-backups/...
  --artifact-dir DIR     Candidate artifact directory. Default:
                         /usr/lib/linux-u-boot-current-rock-5b
  --variant NAME         apply variant: fit-only, loader-only, or both.
  --dry-run              Validate and print the plan without reading/writing raw data.
  --yes                  Skip the typed write confirmation.
  --force-device         Permit a device whose removable flag is not 1.
  --allow-unpinned-artifacts
                         Permit candidate hashes other than the audited 26.5.1 current set.
  -h, --help             Show this help.

The script writes only the raw SD loader area. It never reads or changes SPI.
Keep SPI state and all other hardware constant across every boot test.
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

warn() {
    printf 'WARNING: %s\n' "$*" >&2
}

note() {
    printf '%s\n' "$*"
}

run() {
    printf '+'
    printf ' %q' "$@"
    printf '\n'
    if ((DRY_RUN == 0)); then
        "$@"
    fi
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

sha256_file() {
    sha256sum "$1" | awk '{print $1}'
}

parse_args() {
    (($# > 0)) || {
        usage >&2
        exit 2
    }

    case "$1" in
        capture|inspect|apply|restore)
            ACTION="$1"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown action: $1"
            ;;
    esac

    while (($# > 0)); do
        case "$1" in
            --device)
                (($# >= 2)) || die "--device requires a value"
                DEVICE="$2"
                shift 2
                ;;
            --baseline)
                (($# >= 2)) || die "--baseline requires a value"
                BASELINE="$2"
                shift 2
                ;;
            --output)
                (($# >= 2)) || die "--output requires a value"
                OUTPUT="$2"
                shift 2
                ;;
            --variant)
                (($# >= 2)) || die "--variant requires a value"
                VARIANT="$2"
                shift 2
                ;;
            --artifact-dir)
                (($# >= 2)) || die "--artifact-dir requires a value"
                ARTIFACT_DIR="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --yes)
                YES=1
                shift
                ;;
            --force-device)
                FORCE_DEVICE=1
                shift
                ;;
            --allow-unpinned-artifacts)
                ALLOW_UNPINNED=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "unknown option: $1"
                ;;
        esac
    done

    [[ -n "$DEVICE" ]] || die "--device is required"
    [[ "$DEVICE" == /dev/* ]] || die "--device must be an absolute /dev path"

    case "$ACTION" in
        capture)
            [[ -z "$BASELINE" ]] || die "capture uses --output, not --baseline"
            [[ -z "$VARIANT" ]] || die "capture does not accept --variant"
            ;;
        inspect)
            [[ -z "$OUTPUT" ]] || die "inspect does not accept --output"
            [[ -z "$VARIANT" ]] || die "inspect does not accept --variant"
            ;;
        apply)
            [[ -n "$BASELINE" ]] || die "apply requires --baseline"
            [[ -z "$OUTPUT" ]] || die "apply does not accept --output"
            case "$VARIANT" in
                fit-only|loader-only|both) ;;
                '') die "apply requires --variant fit-only|loader-only|both" ;;
                *) die "unknown variant: $VARIANT" ;;
            esac
            ;;
        restore)
            [[ -n "$BASELINE" ]] || die "restore requires --baseline"
            [[ -z "$OUTPUT" ]] || die "restore does not accept --output"
            [[ -z "$VARIANT" ]] || die "restore does not accept --variant"
            ;;
    esac
}

validate_device() {
    local device_type logical_size device_size removable root_source root_chain
    local first_partition first_partition_start

    DEVICE="$(readlink -f "$DEVICE")"
    [[ -b "$DEVICE" ]] || die "not a block device: $DEVICE"

    device_type="$(lsblk -dnro TYPE "$DEVICE")"
    [[ "$device_type" == disk ]] || die "target must be a whole disk, not a $device_type: $DEVICE"

    logical_size="$(blockdev --getss "$DEVICE")"
    [[ "$logical_size" == "$SECTOR_SIZE" ]] ||
        die "unsupported logical sector size $logical_size; this layout requires 512-byte sectors"

    device_size="$(blockdev --getsize64 "$DEVICE")"
    ((device_size >= GAP_END_SECTOR * SECTOR_SIZE)) || die "device is too small"

    root_source="$(findmnt -nro SOURCE / 2>/dev/null || true)"
    if [[ -n "$root_source" && -b "$root_source" ]]; then
        root_chain="$(lsblk -srno NAME "$root_source" 2>/dev/null || true)"
        if grep -Fqx "$(basename "$DEVICE")" <<<"$root_chain"; then
            die "refusing to target a disk that backs the running root filesystem: $DEVICE"
        fi
    fi

    removable="$(lsblk -dnro RM "$DEVICE")"
    if [[ "$removable" != 1 && "$FORCE_DEVICE" == 0 ]]; then
        die "$DEVICE is not marked removable; re-check it and pass --force-device if intentional"
    fi

    first_partition="$(lsblk -nrpo NAME,TYPE "$DEVICE" | awk '$2 == "part" {print $1; exit}')"
    [[ -n "$first_partition" ]] || die "no partition found on $DEVICE; expected a fresh Armbian SD card"
    first_partition_start="$(cat "/sys/class/block/$(basename "$first_partition")/start")"
    ((first_partition_start >= GAP_END_SECTOR)) ||
        die "first partition begins at sector $first_partition_start; raw loader gap ends at $GAP_END_SECTOR"

    note "Target device: $DEVICE"
    lsblk -dno NAME,SIZE,MODEL,SERIAL,RM,TYPE "$DEVICE"
    note "Raw loader gap: sectors $GAP_START_SECTOR..$((GAP_END_SECTOR - 1)) ($GAP_BYTES bytes)"
    note "First partition: $first_partition at sector $first_partition_start"
}

require_unmounted_for_write() {
    local node

    while read -r node; do
        [[ -n "$node" ]] || continue
        if findmnt -rn -S "$node" >/dev/null 2>&1; then
            findmnt -rn -S "$node" -o SOURCE,TARGET >&2 || true
            die "target or child partition is mounted: $node"
        fi
    done < <(lsblk -nrpo NAME "$DEVICE")
}

require_root_for_raw_action() {
    if ((DRY_RUN == 0 && EUID != 0)); then
        die "$ACTION requires root; rerun with sudo (or use --dry-run)"
    fi
}

validate_baseline() {
    local size checksum_file recorded actual

    [[ -f "$BASELINE" ]] || die "baseline not found: $BASELINE"
    size="$(stat -c %s "$BASELINE")"
    [[ "$size" == "$GAP_BYTES" ]] ||
        die "baseline size is $size bytes; expected exactly $GAP_BYTES"

    checksum_file="$BASELINE.sha256"
    if [[ -f "$checksum_file" ]]; then
        recorded="$(awk 'NR == 1 {print $1}' "$checksum_file")"
        actual="$(sha256_file "$BASELINE")"
        [[ "$recorded" == "$actual" ]] || die "baseline checksum does not match $checksum_file"
    else
        warn "no checksum sidecar found: $checksum_file"
    fi

    note "Baseline: $BASELINE"
    note "Baseline SHA-256: $(sha256_file "$BASELINE")"
}

validate_candidate_artifacts() {
    local idb="$ARTIFACT_DIR/idbloader.img"
    local fit="$ARTIFACT_DIR/u-boot.itb"
    local idb_size fit_size idb_hash fit_hash fdt_size

    [[ -f "$idb" ]] || die "candidate idbloader not found: $idb"
    [[ -f "$fit" ]] || die "candidate FIT not found: $fit"

    idb_size="$(stat -c %s "$idb")"
    fit_size="$(stat -c %s "$fit")"
    ((idb_size > 0)) || die "candidate idbloader is empty"
    ((fit_size > 0)) || die "candidate FIT is empty"
    ((IDB_SECTOR * SECTOR_SIZE + idb_size <= FIT_SECTOR * SECTOR_SIZE)) ||
        die "candidate idbloader overlaps the FIT offset"
    ((FIT_SECTOR * SECTOR_SIZE + fit_size <= GAP_END_SECTOR * SECTOR_SIZE)) ||
        die "candidate FIT exceeds the reserved raw loader gap"

    idb_hash="$(sha256_file "$idb")"
    fit_hash="$(sha256_file "$fit")"
    note "Candidate idbloader: $idb ($idb_size bytes)"
    note "  SHA-256: $idb_hash"
    note "Candidate FIT: $fit ($fit_size bytes)"
    note "  SHA-256: $fit_hash"

    if [[ "$idb_hash" != "$EXPECTED_IDB_SHA256" || "$fit_hash" != "$EXPECTED_FIT_SHA256" ]]; then
        if ((ALLOW_UNPINNED == 0)); then
            die "candidate hashes are not the audited 26.5.1 current artifacts; use --allow-unpinned-artifacts only after reviewing them"
        fi
        warn "continuing with unpinned candidate artifacts"
    fi

    dumpimage -l "$fit"
    fdt_size="$(dumpimage -l "$fit" 2>&1 | awk '
        /^ Image [0-9]+ \(fdt\)/ {in_fdt=1; next}
        in_fdt && /Data Size:/ {gsub(/[^0-9]/, "", $3); print $3; exit}
    ')"
    [[ "$fdt_size" =~ ^[0-9]+$ ]] || die "could not identify the candidate FIT control-DTB size"
    ((fdt_size > 0)) || die "candidate FIT still contains a zero-byte control DTB"
    note "Candidate control DTB: $fdt_size bytes (nonzero)"
}

read_gap_hash() {
    dd if="$DEVICE" bs="$SECTOR_SIZE" skip="$GAP_START_SECTOR" count="$GAP_SECTORS" \
        iflag=fullblock status=none | sha256sum | awk '{print $1}'
}

verify_pristine_device() {
    local baseline_hash device_hash

    baseline_hash="$(sha256_file "$BASELINE")"
    device_hash="$(read_gap_hash)"
    note "On-device raw-gap SHA-256: $device_hash"
    [[ "$device_hash" == "$baseline_hash" ]] ||
        die "device is not at the captured pristine baseline; restore before applying another variant"
    note "Pristine baseline confirmed on-device."
}

verify_artifact_region() {
    local artifact="$1"
    local sector="$2"
    local size sectors

    size="$(stat -c %s "$artifact")"
    sectors=$(((size + SECTOR_SIZE - 1) / SECTOR_SIZE))
    cmp -n "$size" "$artifact" \
        <(dd if="$DEVICE" bs="$SECTOR_SIZE" skip="$sector" count="$sectors" iflag=fullblock status=none) \
        >/dev/null || die "readback mismatch for $artifact at sector $sector"
}

verify_unchanged_prefix() {
    cmp -n "$FIT_RELATIVE_BYTES" "$BASELINE" \
        <(dd if="$DEVICE" bs="$SECTOR_SIZE" skip="$GAP_START_SECTOR" \
            count="$FIT_RELATIVE_SECTORS" iflag=fullblock status=none) \
        >/dev/null || die "fit-only changed bytes before the FIT offset"
}

verify_unchanged_fit_tail() {
    cmp -n "$FIT_TAIL_BYTES" \
        <(dd if="$BASELINE" bs="$SECTOR_SIZE" skip="$FIT_RELATIVE_SECTORS" \
            count="$FIT_TAIL_SECTORS" iflag=fullblock status=none) \
        <(dd if="$DEVICE" bs="$SECTOR_SIZE" skip="$FIT_SECTOR" \
            count="$FIT_TAIL_SECTORS" iflag=fullblock status=none) \
        >/dev/null || die "loader-only changed the baseline FIT/tail region"
}

confirm_write() {
    local phrase="$1" answer

    ((YES == 0)) || return 0
    [[ -t 0 ]] || die "interactive confirmation unavailable; rerun from a terminal or pass --yes"
    printf 'Type %s to continue: ' "$phrase" >&2
    read -r answer
    [[ "$answer" == "$phrase" ]] || die "confirmation did not match; nothing written"
}

default_capture_output() {
    local backup_dir device_name stamp

    backup_dir="$REPO_ROOT/downloads/sd-bootarea-backups"
    device_name="$(basename "$DEVICE")"
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    OUTPUT="$backup_dir/${device_name}-armbian-26.2.1-pristine-$stamp.bin"
}

capture_baseline() {
    local output_dir report hash

    [[ -n "$OUTPUT" ]] || default_capture_output
    OUTPUT="$(readlink -m "$OUTPUT")"
    output_dir="$(dirname "$OUTPUT")"
    [[ ! -e "$OUTPUT" ]] || die "capture destination already exists: $OUTPUT"

    note "Capture destination: $OUTPUT"
    if ((DRY_RUN)); then
        note "DRY RUN: would capture and verify the complete raw loader gap."
        return 0
    fi

    mkdir -p "$output_dir"
    run dd if="$DEVICE" of="$OUTPUT" bs="$SECTOR_SIZE" skip="$GAP_START_SECTOR" \
        count="$GAP_SECTORS" iflag=fullblock conv=fsync status=progress
    [[ "$(stat -c %s "$OUTPUT")" == "$GAP_BYTES" ]] || die "capture has the wrong size"

    hash="$(sha256_file "$OUTPUT")"
    printf '%s  %s\n' "$hash" "$(basename "$OUTPUT")" >"$OUTPUT.sha256"
    report="$OUTPUT.report.txt"
    {
        printf 'Captured UTC: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'Command: %s capture\n' "$SCRIPT_NAME"
        printf 'Device: %s\n' "$DEVICE"
        lsblk -dno NAME,SIZE,MODEL,SERIAL,RM,TYPE "$DEVICE"
        printf 'Sector size: %s\n' "$SECTOR_SIZE"
        printf 'Captured sectors: %s..%s\n' "$GAP_START_SECTOR" "$((GAP_END_SECTOR - 1))"
        printf 'Captured bytes: %s\n' "$GAP_BYTES"
        printf 'SHA-256: %s\n' "$hash"
        printf '\nIdentity strings from captured raw gap:\n'
        strings "$OUTPUT" | grep -E 'ddr-v|DDR .*fwver|U-Boot SPL|U-Boot 20' | head -n 40 || true
    } >"$report"

    [[ "$(read_gap_hash)" == "$hash" ]] || die "capture does not match the device readback"
    note "Captured and verified pristine baseline: $OUTPUT"
    note "Checksum: $OUTPUT.sha256"
    note "Identity report: $report"
    note "Protect these three files; every apply action requires the baseline image."
}

inspect_state() {
    local device_hash baseline_hash

    validate_candidate_artifacts
    if ((DRY_RUN)); then
        note "DRY RUN: raw-gap reads skipped."
        return 0
    fi

    device_hash="$(read_gap_hash)"
    note "On-device raw-gap SHA-256: $device_hash"
    if [[ -n "$BASELINE" ]]; then
        validate_baseline
        baseline_hash="$(sha256_file "$BASELINE")"
        if [[ "$device_hash" == "$baseline_hash" ]]; then
            note "State: pristine baseline"
        else
            note "State: differs from supplied baseline"
        fi
    fi
    note "Identity strings from on-device raw gap:"
    dd if="$DEVICE" bs="$SECTOR_SIZE" skip="$GAP_START_SECTOR" count="$GAP_SECTORS" \
        iflag=fullblock status=none |
        strings | grep -E 'ddr-v|DDR .*fwver|U-Boot SPL|U-Boot 20' | head -n 40 || true
}

apply_variant() {
    local idb="$ARTIFACT_DIR/idbloader.img"
    local fit="$ARTIFACT_DIR/u-boot.itb"
    local phrase

    validate_baseline
    validate_candidate_artifacts
    if ((DRY_RUN)); then
        note "DRY RUN: would require the on-device pristine baseline, apply '$VARIANT', and verify readback."
        return 0
    fi

    verify_pristine_device
    phrase="WRITE-${VARIANT^^}-SD"
    confirm_write "$phrase"

    case "$VARIANT" in
        fit-only)
            run dd if="$fit" of="$DEVICE" bs="$SECTOR_SIZE" seek="$FIT_SECTOR" \
                conv=notrunc,fsync status=progress
            verify_artifact_region "$fit" "$FIT_SECTOR"
            verify_unchanged_prefix
            ;;
        loader-only)
            run dd if="$idb" of="$DEVICE" bs="$SECTOR_SIZE" seek="$IDB_SECTOR" \
                conv=notrunc,fsync status=progress
            verify_artifact_region "$idb" "$IDB_SECTOR"
            verify_unchanged_fit_tail
            ;;
        both)
            run dd if="$idb" of="$DEVICE" bs="$SECTOR_SIZE" seek="$IDB_SECTOR" \
                conv=notrunc,fsync status=progress
            run dd if="$fit" of="$DEVICE" bs="$SECTOR_SIZE" seek="$FIT_SECTOR" \
                conv=notrunc,fsync status=progress
            verify_artifact_region "$idb" "$IDB_SECTOR"
            verify_artifact_region "$fit" "$FIT_SECTOR"
            ;;
    esac

    sync
    note "Applied and verified variant: $VARIANT"
    note "Resulting raw-gap SHA-256: $(read_gap_hash)"
    note "Next: boot once with SPI and all hardware held constant; capture UART and HDMI."
    note "Then restore the baseline before applying a different variant."
}

restore_baseline() {
    local baseline_hash device_hash

    validate_baseline
    if ((DRY_RUN)); then
        note "DRY RUN: would restore all $GAP_BYTES bytes and verify the raw-gap checksum."
        return 0
    fi

    confirm_write "RESTORE-26.2-SD"
    run dd if="$BASELINE" of="$DEVICE" bs="$SECTOR_SIZE" seek="$GAP_START_SECTOR" \
        count="$GAP_SECTORS" iflag=fullblock conv=notrunc,fsync status=progress
    sync
    baseline_hash="$(sha256_file "$BASELINE")"
    device_hash="$(read_gap_hash)"
    [[ "$device_hash" == "$baseline_hash" ]] || die "restored raw gap failed checksum verification"
    note "Restored and verified pristine baseline: $device_hash"
}

main() {
    parse_args "$@"

    require_command awk
    require_command blockdev
    require_command cmp
    require_command dd
    require_command findmnt
    require_command grep
    require_command lsblk
    require_command readlink
    require_command sha256sum
    require_command stat
    require_command strings

    validate_device
    require_root_for_raw_action

    case "$ACTION" in
        capture)
            capture_baseline
            ;;
        inspect)
            require_command dumpimage
            inspect_state
            ;;
        apply)
            require_command dumpimage
            require_unmounted_for_write
            apply_variant
            ;;
        restore)
            require_unmounted_for_write
            restore_baseline
            ;;
    esac
}

main "$@"
