#!/usr/bin/env bash
# Apply a conservative, reversible passive-cooling profile to a Radxa ROCK 5B.

set -euo pipefail
export LC_ALL=C

NVME_CONTROLLER="${NVME_CONTROLLER:-/dev/nvme0}"
CPUFREQ_ROOT="${CPUFREQ_ROOT:-/sys/devices/system/cpu/cpufreq}"
THERMAL_ROOT="${THERMAL_ROOT:-/sys/class/thermal}"
STATE_DIR="${STATE_DIR:-/var/lib/rock5b-passive-cooling}"
STATE_FILE="$STATE_DIR/stock-state"
INSTALL_PATH="${INSTALL_PATH:-/usr/local/sbin/rock5b-passive-cooling}"
UNIT_PATH="${UNIT_PATH:-/etc/systemd/system/rock5b-passive-cooling.service}"

HCTM_TMT1_C=65
HCTM_TMT2_C=68
HCTM_VALUE=0x01520155
MONITOR_INTERVAL=5

PERSIST=1
MONITOR=0
DRY_RUN=0
FORCE_BOARD=0
LAST_LEVEL=-1

usage() {
    cat <<'EOF'
Usage:
  sudo bash scripts/rock5b-passive-cooling-apply.sh [options]

Apply the ROCK 5B passive-cooling profile and install a systemd monitor so it
survives reboots. The first run records the original CPU frequency limits and
saved NVMe HCTM value for rock5b-passive-cooling-revert.sh.

Profile:
  * NVMe HCTM light/strong thresholds: 65 C / 68 C (saved by the controller)
  * use the hottest recognized CPU thermal sensor on legacy and split layouts
  * stock CPU ceilings remain available below 65 C
  * progressively lower CPU ceilings at 65, 70, 75, 80, 85, 90, and 95 C
  * restore every cpufreq policy's minimum to its hardware minimum

Options:
  --once             Apply only until reboot; do not save HCTM or install the
                     systemd monitor. A stock-state snapshot is still made.
  --nvme DEVICE      NVMe controller character device. Default: /dev/nvme0
  --dry-run          Validate and print the intended settings without writes.
  --force-board      Skip the Radxa ROCK 5B model check.
  -h, --help         Show this help.

The internal --monitor mode is used by the installed systemd service.
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

note() {
    printf '%s\n' "$*"
}

need_value() {
    [[ $# -ge 2 && -n $2 ]] || die "$1 requires a value"
}

need_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

while (($# > 0)); do
    case "$1" in
        --once)
            PERSIST=0
            shift
            ;;
        --monitor)
            MONITOR=1
            PERSIST=0
            shift
            ;;
        --nvme)
            need_value "$@"
            NVME_CONTROLLER="$2"
            shift 2
            ;;
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

if ((MONITOR == 1 && DRY_RUN == 1)); then
    die "--monitor and --dry-run cannot be combined"
fi

if ((DRY_RUN == 0)) && [[ $(id -u) -ne 0 ]]; then
    die "run as root: sudo bash $0"
fi

need_command awk
need_command basename
need_command nvme
need_command sed
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

check_nvme_path() {
    [[ $NVME_CONTROLLER =~ ^/dev/nvme[0-9]+$ ]] || \
        die "NVMe controller must look like /dev/nvmeN: $NVME_CONTROLLER"
}

read_cpu_temperature() {
    local zone zone_type temperature
    local hottest=-1
    local found=0

    for zone in "$THERMAL_ROOT"/thermal_zone*; do
        [[ -r $zone/type && -r $zone/temp ]] || continue
        zone_type="$(<"$zone/type")"
        if [[ $zone_type != soc-thermal && $zone_type != package-thermal && \
              $zone_type != littlecore-thermal && \
              ! $zone_type =~ ^bigcore[0-9]+-thermal$ ]]; then
            continue
        fi

        temperature="$(<"$zone/temp")"
        [[ $temperature =~ ^[0-9]+$ ]] || \
            die "invalid CPU temperature in $zone ($zone_type): $temperature"
        ((found = 1))
        ((temperature > hottest)) && hottest="$temperature"
    done

    ((found == 1)) || \
        die "CPU thermal zone not found under $THERMAL_ROOT"
    printf '%s\n' "$hottest"
}

list_policies() {
    local policy

    for policy in "$CPUFREQ_ROOT"/policy*; do
        [[ -d $policy ]] || continue
        [[ -r $policy/cpuinfo_min_freq && -r $policy/cpuinfo_max_freq ]] || continue
        [[ -e $policy/scaling_min_freq && -e $policy/scaling_max_freq ]] || continue
        printf '%s\n' "$policy"
    done
}

validate_cpu_layout() {
    local policy_count=0
    local little_count=0
    local big_count=0
    local policy hardware_max

    while IFS= read -r policy; do
        ((policy_count += 1))
        hardware_max="$(<"$policy/cpuinfo_max_freq")"
        [[ $hardware_max =~ ^[0-9]+$ ]] || \
            die "invalid cpuinfo_max_freq in $policy"
        if ((hardware_max <= 1800000)); then
            ((little_count += 1))
        else
            ((big_count += 1))
        fi
        if ((DRY_RUN == 0)); then
            [[ -w $policy/scaling_min_freq && -w $policy/scaling_max_freq ]] || \
                die "cpufreq policy is not writable: $policy"
        fi
    done < <(list_policies)

    ((policy_count > 0)) || die "no cpufreq policies found under $CPUFREQ_ROOT"
    ((little_count > 0 && big_count > 0)) || \
        die "expected both RK3588 little and big CPU frequency policies"
}

normalize_feature_value() {
    local raw="$1"
    local hex="${raw#0x}"
    hex="${hex#0X}"
    [[ $hex =~ ^[0-9a-fA-F]{1,8}$ ]] || \
        die "could not parse NVMe feature value: $raw"
    printf '0x%08x\n' "$((16#$hex))"
}

get_hctm_value() {
    local selector="$1"
    local output raw

    output="$(nvme get-feature "$NVME_CONTROLLER" -f 0x10 -s "$selector")" || \
        die "could not read NVMe HCTM selector $selector"
    raw="$(sed -nE 's/.*[Vv]alue:[[:space:]]*(0[xX])?([0-9a-fA-F]{1,8}).*/\1\2/p' \
        <<<"$output" | sed -n '1p')"
    [[ -n $raw ]] || die "could not find an HCTM value in nvme output"
    normalize_feature_value "$raw"
}

validate_hctm() {
    local output hctma minimum maximum

    output="$(nvme id-ctrl "$NVME_CONTROLLER")" || \
        die "could not identify $NVME_CONTROLLER"
    hctma="$(awk '$1 == "hctma" { print $3; exit }' <<<"$output")"
    minimum="$(awk '$1 == "mntmt" { print $3; exit }' <<<"$output")"
    maximum="$(awk '$1 == "mxtmt" { print $3; exit }' <<<"$output")"

    [[ $hctma =~ ^0x[0-9a-fA-F]+$ ]] || die "controller did not report HCTM support"
    (((hctma & 1) == 1)) || die "controller does not support HCTM"
    [[ $minimum =~ ^[0-9]+$ && $maximum =~ ^[0-9]+$ ]] || \
        die "controller did not report its HCTM temperature range"
    ((minimum <= 338 && maximum >= 341)) || \
        die "controller HCTM range does not include 65-68 C"

    # A successful saved-value read also proves that Feature 0x10 is saveable.
    get_hctm_value 2 >/dev/null
}

capture_stock_state() {
    local temporary saved_value policy name original_min original_max
    local saved_controller

    if [[ -e $STATE_FILE ]]; then
        [[ -f $STATE_FILE && ! -L $STATE_FILE ]] || \
            die "existing stock-state path is not a regular file: $STATE_FILE"
        [[ $(stat -c %u "$STATE_FILE") -eq 0 ]] || \
            die "existing stock-state snapshot is not root-owned"
        saved_controller="$(awk -F'|' '$1 == "NVME" { print $2; exit }' "$STATE_FILE")"
        [[ $saved_controller == "$NVME_CONTROLLER" ]] || \
            die "stock state belongs to $saved_controller, not $NVME_CONTROLLER"
        note "Keeping existing stock-state snapshot: $STATE_FILE"
        return 0
    fi

    install -d -m 0700 "$STATE_DIR"
    temporary="$(mktemp "$STATE_DIR/.stock-state.XXXXXX")"
    chmod 0600 "$temporary"

    saved_value="$(get_hctm_value 2)"
    {
        printf 'VERSION|1\n'
        printf 'NVME|%s|%s\n' "$NVME_CONTROLLER" "$saved_value"
        while IFS= read -r policy; do
            name="$(basename "$policy")"
            original_min="$(<"$policy/scaling_min_freq")"
            original_max="$(<"$policy/scaling_max_freq")"
            [[ $original_min =~ ^[0-9]+$ && $original_max =~ ^[0-9]+$ ]] || \
                die "invalid original cpufreq limits in $policy"
            printf 'CPU|%s|%s|%s\n' \
                "$name" "$original_min" "$original_max"
        done < <(list_policies)
    } >"$temporary"
    mv -f -- "$temporary" "$STATE_FILE"
    note "Captured stock CPU/NVMe state: $STATE_FILE"
}

choose_frequency() {
    local policy="$1"
    local requested="$2"
    local hardware_min hardware_max available frequency best=0

    hardware_min="$(<"$policy/cpuinfo_min_freq")"
    hardware_max="$(<"$policy/cpuinfo_max_freq")"
    ((requested > hardware_max)) && requested="$hardware_max"
    ((requested < hardware_min)) && requested="$hardware_min"

    if [[ -r $policy/scaling_available_frequencies ]]; then
        available="$(<"$policy/scaling_available_frequencies")"
        for frequency in $available; do
            [[ $frequency =~ ^[0-9]+$ ]] || continue
            if ((frequency <= requested && frequency > best)); then
                best="$frequency"
            fi
        done
    fi

    ((best > 0)) || best="$requested"
    printf '%s\n' "$best"
}

temperature_level() {
    local temperature="$1"

    if ((temperature >= 95000)); then
        printf '7\n'
    elif ((temperature >= 90000)); then
        printf '6\n'
    elif ((temperature >= 85000)); then
        printf '5\n'
    elif ((temperature >= 80000)); then
        printf '4\n'
    elif ((temperature >= 75000)); then
        printf '3\n'
    elif ((temperature >= 70000)); then
        printf '2\n'
    elif ((temperature >= 65000)); then
        printf '1\n'
    else
        printf '0\n'
    fi
}

requested_cap() {
    local hardware_max="$1"
    local level="$2"
    local little=0

    ((hardware_max <= 1800000)) && little=1

    if ((little == 1)); then
        case "$level" in
            0) printf '%s\n' "$hardware_max" ;;
            1) printf '1608000\n' ;;
            2) printf '1416000\n' ;;
            3) printf '1200000\n' ;;
            4) printf '1008000\n' ;;
            5) printf '816000\n' ;;
            6) printf '600000\n' ;;
            7) printf '408000\n' ;;
            *) die "invalid thermal level: $level" ;;
        esac
    else
        case "$level" in
            0) printf '%s\n' "$hardware_max" ;;
            1) printf '2208000\n' ;;
            2) printf '2016000\n' ;;
            3) printf '1800000\n' ;;
            4) printf '1608000\n' ;;
            5) printf '1416000\n' ;;
            6) printf '1200000\n' ;;
            7) printf '816000\n' ;;
            *) die "invalid thermal level: $level" ;;
        esac
    fi
}

apply_cpu_level() {
    local level="$1"
    local policy hardware_min hardware_max requested selected

    while IFS= read -r policy; do
        hardware_min="$(<"$policy/cpuinfo_min_freq")"
        hardware_max="$(<"$policy/cpuinfo_max_freq")"
        requested="$(requested_cap "$hardware_max" "$level")"
        selected="$(choose_frequency "$policy" "$requested")"

        if ((DRY_RUN == 1)); then
            printf 'Would set %-8s min=%7s kHz max=%7s kHz\n' \
                "$(basename "$policy")" "$hardware_min" "$selected"
            continue
        fi

        # The stock configuration pins policy0 at 1.8 GHz on the audited box.
        # Lower its minimum before asking cpufreq to accept a lower ceiling.
        printf '%s\n' "$hardware_min" >"$policy/scaling_min_freq"
        printf '%s\n' "$selected" >"$policy/scaling_max_freq"
    done < <(list_policies)
}

apply_nvme() {
    local save_flag=()
    local suffix=""
    ((PERSIST == 1)) && {
        save_flag=(--save)
        suffix=" and save it"
    }

    if ((DRY_RUN == 1)); then
        printf 'Would set %s HCTM to %d/%d C (%s)%s\n' \
            "$NVME_CONTROLLER" "$HCTM_TMT1_C" "$HCTM_TMT2_C" \
            "$HCTM_VALUE" "$suffix"
        return 0
    fi

    nvme set-feature "$NVME_CONTROLLER" -f 0x10 -V "$HCTM_VALUE" \
        "${save_flag[@]}" >/dev/null
    [[ $(get_hctm_value 0) == "$HCTM_VALUE" ]] || \
        die "NVMe did not retain the requested current HCTM value"
    if ((PERSIST == 1)); then
        [[ $(get_hctm_value 2) == "$HCTM_VALUE" ]] || \
            die "NVMe did not retain the requested saved HCTM value"
    fi
}

install_monitor() {
    local self temporary device_unit
    self="$(readlink -f -- "$0")"
    temporary="$(mktemp)"
    device_unit="dev-$(basename "$NVME_CONTROLLER").device"

    install -m 0755 "$self" "$INSTALL_PATH"
    {
        printf '%s\n' '[Unit]'
        printf '%s\n' 'Description=ROCK 5B passive CPU and NVMe cooling profile'
        printf 'After=%s cpufrequtils.service armbian-hardware-optimization.service\n' \
            "$device_unit"
        printf 'Requires=%s\n' "$device_unit"
        printf '\n'
        printf '%s\n' '[Service]'
        printf '%s\n' 'Type=simple'
        printf 'ExecStart=%s --monitor --nvme %s\n' "$INSTALL_PATH" "$NVME_CONTROLLER"
        printf '%s\n' 'Restart=on-failure'
        printf '%s\n' 'RestartSec=5s'
        printf '\n'
        printf '%s\n' '[Install]'
        printf '%s\n' 'WantedBy=multi-user.target'
    } >"$temporary"
    install -m 0644 "$temporary" "$UNIT_PATH"
    rm -f -- "$temporary"

    systemctl daemon-reload
    systemctl enable --now rock5b-passive-cooling.service
    note "Installed and started rock5b-passive-cooling.service"
}

monitor_temperatures() {
    local temperature level

    trap 'exit 0' TERM INT
    while true; do
        temperature="$(read_cpu_temperature)"
        level="$(temperature_level "$temperature")"
        apply_cpu_level "$level"

        if ((level != LAST_LEVEL)); then
            note "CPU $((temperature / 1000)) C: applied passive-cooling level $level"
            LAST_LEVEL="$level"
        fi
        sleep "$MONITOR_INTERVAL"
    done
}

check_board
check_nvme_path
validate_cpu_layout

if ((DRY_RUN == 1)); then
    temperature="$(read_cpu_temperature)"
    level="$(temperature_level "$temperature")"
    note "Dry run: CPU temperature is $((temperature / 1000)) C (level $level)."
    apply_cpu_level "$level"
    apply_nvme
    ((PERSIST == 0)) || note "Would install and enable rock5b-passive-cooling.service"
    exit 0
fi

validate_hctm

if ((MONITOR == 1)); then
    apply_nvme
    monitor_temperatures
fi

need_command chmod
need_command install
need_command mktemp
need_command mv
need_command stat
capture_stock_state
temperature="$(read_cpu_temperature)"
level="$(temperature_level "$temperature")"
apply_cpu_level "$level"
apply_nvme

if ((PERSIST == 1)); then
    need_command readlink
    need_command systemctl
    install_monitor
else
    note "Applied until reboot; no service installed and HCTM was not saved."
fi

note "Passive-cooling profile active: CPU $((temperature / 1000)) C, level $level."
note "For kernel packages, continue to use DEB_BUILD_OPTIONS=parallel=2."
