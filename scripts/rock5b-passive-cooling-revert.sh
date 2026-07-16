#!/usr/bin/env bash
# Remove the ROCK 5B passive-cooling profile and restore its stock snapshot.

set -euo pipefail
export LC_ALL=C

CPUFREQ_ROOT="${CPUFREQ_ROOT:-/sys/devices/system/cpu/cpufreq}"
STATE_DIR="${STATE_DIR:-/var/lib/rock5b-passive-cooling}"
STATE_FILE="$STATE_DIR/stock-state"
INSTALL_PATH="${INSTALL_PATH:-/usr/local/sbin/rock5b-passive-cooling}"
UNIT_PATH="${UNIT_PATH:-/etc/systemd/system/rock5b-passive-cooling.service}"

DRY_RUN=0
FORCE_BOARD=0

usage() {
    cat <<'EOF'
Usage:
  sudo bash scripts/rock5b-passive-cooling-revert.sh [options]

Stop and remove the persistent passive-cooling monitor, restore every captured
CPU policy minimum/maximum, restore the NVMe controller's original saved HCTM
value, and remove the stock-state snapshot after successful verification.

Options:
  --dry-run          Show the captured values and intended changes.
  --force-board      Skip the Radxa ROCK 5B model check.
  -h, --help         Show this help.
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

need_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

while (($# > 0)); do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --force-board)
            FORCE_BOARD=1
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

[[ $(id -u) -eq 0 ]] || die "run as root: sudo bash $0"

need_command nvme
need_command sed
need_command stat
need_command systemctl
need_command tr

check_board() {
    ((FORCE_BOARD == 1)) && return 0

    local model=""
    local compatible=""
    [[ -r /proc/device-tree/model ]] && \
        model="$(tr -d '\0' </proc/device-tree/model)"
    [[ -r /proc/device-tree/compatible ]] && \
        compatible="$(tr '\0' ' ' </proc/device-tree/compatible)"

    [[ $model == "Radxa ROCK 5B" ]] && return 0
    [[ " $compatible " == *" radxa,rock-5b "* ]] && return 0
    die "this does not look like a Radxa ROCK 5B; use --force-board only if certain"
}

normalize_feature_value() {
    local raw="$1"
    local hex="${raw#0x}"
    hex="${hex#0X}"
    [[ $hex =~ ^[0-9a-fA-F]{1,8}$ ]] || die "invalid NVMe feature value: $raw"
    printf '0x%08x\n' "$((16#$hex))"
}

get_hctm_value() {
    local controller="$1"
    local selector="$2"
    local output raw

    output="$(nvme get-feature "$controller" -f 0x10 -s "$selector")" || \
        die "could not read NVMe HCTM selector $selector"
    raw="$(sed -nE 's/.*[Vv]alue:[[:space:]]*(0[xX])?([0-9a-fA-F]{1,8}).*/\1\2/p' \
        <<<"$output" | sed -n '1p')"
    [[ -n $raw ]] || die "could not find an HCTM value in nvme output"
    normalize_feature_value "$raw"
}

check_board
[[ -f $STATE_FILE && ! -L $STATE_FILE ]] || \
    die "stock-state snapshot not found: $STATE_FILE"
[[ $(stat -c %u "$STATE_FILE") -eq 0 ]] || die "stock-state snapshot is not root-owned"

version=""
nvme_controller=""
nvme_saved=""
cpu_entries=()

while IFS='|' read -r kind field1 field2 field3 extra; do
    [[ -z ${extra:-} ]] || die "malformed stock-state line"
    case "$kind" in
        VERSION)
            [[ -z $field2 && -z $field3 ]] || die "malformed VERSION record"
            version="$field1"
            ;;
        NVME)
            [[ -n $field1 && -n $field2 && -z $field3 ]] || die "malformed NVME record"
            nvme_controller="$field1"
            nvme_saved="$(normalize_feature_value "$field2")"
            ;;
        CPU)
            [[ $field1 =~ ^policy[0-9]+$ ]] || die "invalid CPU policy in stock state"
            [[ $field2 =~ ^[0-9]+$ && $field3 =~ ^[0-9]+$ ]] || \
                die "invalid CPU frequency in stock state"
            cpu_entries+=("$field1|$field2|$field3")
            ;;
        '') ;;
        *) die "unknown stock-state record: $kind" ;;
    esac
done <"$STATE_FILE"

[[ $version == 1 ]] || die "unsupported stock-state version: ${version:-missing}"
[[ $nvme_controller =~ ^/dev/nvme[0-9]+$ ]] || die "invalid saved NVMe controller"
((${#cpu_entries[@]} > 0)) || die "stock state contains no CPU policies"

if ((DRY_RUN == 1)); then
    note "Would disable and remove rock5b-passive-cooling.service"
else
    if [[ -e $UNIT_PATH || -e $INSTALL_PATH ]]; then
        if ! systemctl disable --now rock5b-passive-cooling.service 2>/dev/null; then
            if systemctl is-active --quiet rock5b-passive-cooling.service; then
                die "could not stop rock5b-passive-cooling.service; no settings restored"
            fi
        fi
    fi
fi

restore_failures=0
for entry in "${cpu_entries[@]}"; do
    IFS='|' read -r policy_name original_min original_max <<<"$entry"
    policy="$CPUFREQ_ROOT/$policy_name"

    if [[ ! -d $policy ]]; then
        warn "saved CPU policy is unavailable: $policy"
        restore_failures=1
        continue
    fi
    [[ -w $policy/scaling_min_freq && -w $policy/scaling_max_freq ]] || \
        die "CPU policy is not writable: $policy"

    if ((DRY_RUN == 1)); then
        printf 'Would restore %-8s min=%7s kHz max=%7s kHz\n' \
            "$policy_name" "$original_min" "$original_max"
        continue
    fi

    # Open the ceiling first so either ordering of the saved values is valid.
    hardware_max="$(<"$policy/cpuinfo_max_freq")"
    printf '%s\n' "$hardware_max" >"$policy/scaling_max_freq"
    printf '%s\n' "$original_min" >"$policy/scaling_min_freq"
    printf '%s\n' "$original_max" >"$policy/scaling_max_freq"

    [[ $(<"$policy/scaling_min_freq") == "$original_min" && \
       $(<"$policy/scaling_max_freq") == "$original_max" ]] || {
        warn "CPU policy did not retain its stock limits: $policy_name"
        restore_failures=1
    }
done

if ((DRY_RUN == 1)); then
    printf 'Would restore %s HCTM current/saved value to %s\n' \
        "$nvme_controller" "$nvme_saved"
    note "Would remove $UNIT_PATH, $INSTALL_PATH, and $STATE_FILE"
    exit 0
fi

nvme set-feature "$nvme_controller" -f 0x10 -V "$nvme_saved" --save >/dev/null
[[ $(get_hctm_value "$nvme_controller" 0) == "$nvme_saved" && \
   $(get_hctm_value "$nvme_controller" 2) == "$nvme_saved" ]] || \
    die "NVMe did not retain the restored HCTM value"

((restore_failures == 0)) || \
    die "one or more CPU policies could not be restored; keeping service files and stock state"

rm -f -- "$UNIT_PATH" "$INSTALL_PATH"
systemctl daemon-reload
systemctl reset-failed rock5b-passive-cooling.service 2>/dev/null || true
rm -f -- "$STATE_FILE"
rmdir "$STATE_DIR" 2>/dev/null || true

note "Restored captured stock CPU limits and NVMe HCTM value."
note "Removed rock5b-passive-cooling.service and its saved state."
