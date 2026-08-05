#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: GPL-2.0-or-later
# Prepare a mounted Armbian ROCK 5B root filesystem for headless Wi-Fi + SSH.

set -euo pipefail
set +x
export LC_ALL=C

ROOT="/mnt/mmcblk1p1"
SSID=""
COUNTRY="US"
WIFI_MATCH="wl*"
AUTHORIZED_KEYS=""
WIFI_PASSWORD_FILE=""
WIFI_PASSWORD=""
DRY_RUN=0
REMOUNTED_RW=0
TEMP_FILES=()

usage() {
    cat <<'EOF'
Usage:
  sudo bash scripts/prepare-armbian-headless.sh --ssid NAME [options]

Prepare a mounted Armbian ROCK 5B root filesystem to join Wi-Fi and accept
root SSH logins using the invoking user's authorized_keys file.

Options:
  --root DIR                  Mounted Armbian root. Default: /mnt/mmcblk1p1
  --ssid NAME                 Wi-Fi network name (required).
  --country CC                Two-letter regulatory country. Default: US
  --interface-match GLOB      Netplan interface-name match. Default: wl*
  --authorized-keys FILE      Public authorized_keys source. Under sudo,
                              defaults to the invoking user's file.
  --wifi-password-file FILE   Read the Wi-Fi password from a protected file.
                              Otherwise prompt without echoing it.
  --dry-run                   Validate and print the plan without writing or
                              remounting the card. Does not prompt for a password.
  -h, --help                  Show this help.

The script intentionally has no --wifi-password option: command-line secrets
are exposed by process listings and shell history. The password is stored in a
root-only Netplan file on the image. Existing authorized keys are preserved;
source lines not already present are added.
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

need_value() {
    [[ $# -ge 2 && -n $2 ]] || die "$1 requires a value"
}

need_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

default_authorized_keys() {
    local invoking_user="${SUDO_USER:-${USER:-}}"
    local invoking_home=""

    if [[ -n $invoking_user && $invoking_user != root ]]; then
        invoking_home="$(getent passwd "$invoking_user" | awk -F: 'NR == 1 { print $6 }')"
    elif [[ -n ${HOME:-} ]]; then
        invoking_home="$HOME"
    fi

    [[ -n $invoking_home ]] || return 1
    printf '%s/.ssh/authorized_keys\n' "$invoking_home"
}

has_control_character() {
    [[ $1 =~ [[:cntrl:]] ]]
}

yaml_quote() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    REPLY="\"$value\""
}

register_temp() {
    local directory="$1"
    local basename="$2"

    TEMP_PATH="$(mktemp "$directory/.${basename}.tmp.XXXXXX")"
    TEMP_FILES+=("$TEMP_PATH")
}

remove_temps() {
    local path

    for path in "${TEMP_FILES[@]}"; do
        [[ ! -e $path ]] || rm -f -- "$path"
    done
}

sync_target() {
    sync -f "$ROOT" 2>/dev/null || sync
}

cleanup() {
    local rc=$?

    trap - EXIT INT TERM HUP
    WIFI_PASSWORD=""
    remove_temps
    if ((REMOUNTED_RW == 1)); then
        sync_target || true
        if ! mount -o remount,ro "$ROOT"; then
            warn "could not restore the original read-only mount: $ROOT"
            ((rc != 0)) || rc=1
        fi
    fi
    exit "$rc"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

while (($# > 0)); do
    case "$1" in
        --root)
            need_value "$@"
            ROOT="$2"
            shift 2
            ;;
        --ssid)
            need_value "$@"
            SSID="$2"
            shift 2
            ;;
        --country)
            need_value "$@"
            COUNTRY="${2^^}"
            shift 2
            ;;
        --interface-match)
            need_value "$@"
            WIFI_MATCH="$2"
            shift 2
            ;;
        --authorized-keys)
            need_value "$@"
            AUTHORIZED_KEYS="$2"
            shift 2
            ;;
        --wifi-password-file)
            need_value "$@"
            WIFI_PASSWORD_FILE="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
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

need_command awk
need_command findmnt
need_command getent
need_command grep
need_command mktemp
need_command mount
need_command mountpoint
need_command readlink
need_command ssh-keygen
need_command stat
need_command sync

[[ -n $SSID ]] || die "--ssid is required"
has_control_character "$SSID" && die "SSID contains a control character"
((${#SSID} <= 32)) || die "SSID must be at most 32 bytes"
[[ $COUNTRY =~ ^[A-Z]{2}$ ]] || die "--country must be a two-letter code"
[[ -n $WIFI_MATCH ]] || die "--interface-match cannot be empty"
has_control_character "$WIFI_MATCH" && die "interface match contains a control character"

[[ -d $ROOT ]] || die "root directory does not exist: $ROOT"
ROOT="$(readlink -f -- "$ROOT")"
[[ $ROOT != / ]] || die "refusing to modify the running root filesystem"
mountpoint -q -- "$ROOT" || die "not a mount point: $ROOT"

[[ -f $ROOT/etc/armbian-release ]] || die "not an Armbian root: $ROOT"
grep -q '^BOARD=rock-5b$' "$ROOT/etc/armbian-release" || \
    die "mounted image is not for BOARD=rock-5b"
[[ -s $ROOT/boot/armbianEnv.txt ]] || die "missing /boot/armbianEnv.txt"
[[ -e $ROOT/boot/Image ]] || die "missing boot kernel (/boot/Image)"
[[ -d $ROOT/etc/netplan ]] || die "image has no /etc/netplan directory"
[[ -x $ROOT/usr/sbin/sshd ]] || die "image has no OpenSSH server"
[[ -f $ROOT/usr/lib/systemd/system/ssh.service ]] || die "image has no ssh.service"
grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' \
    "$ROOT/etc/ssh/sshd_config" || die "sshd_config does not include its drop-in directory"

if [[ -z $AUTHORIZED_KEYS ]]; then
    AUTHORIZED_KEYS="$(default_authorized_keys)" || \
        die "cannot locate the invoking user's authorized_keys; pass --authorized-keys"
fi
[[ -f $AUTHORIZED_KEYS && -r $AUTHORIZED_KEYS ]] || \
    die "authorized_keys source is not a readable regular file: $AUTHORIZED_KEYS"
AUTHORIZED_KEYS="$(readlink -f -- "$AUTHORIZED_KEYS")"
[[ -s $AUTHORIZED_KEYS ]] || die "authorized_keys source is empty: $AUTHORIZED_KEYS"
ssh-keygen -l -f "$AUTHORIZED_KEYS" >/dev/null 2>&1 || \
    die "authorized_keys source contains no readable SSH public key"

if ((DRY_RUN == 0 && EUID != 0)); then
    die "run as root: sudo bash $0 ..."
fi

if [[ -n $WIFI_PASSWORD_FILE ]]; then
    [[ -f $WIFI_PASSWORD_FILE && -r $WIFI_PASSWORD_FILE ]] || \
        die "Wi-Fi password file is not a readable regular file: $WIFI_PASSWORD_FILE"
    password_mode="$(stat -Lc '%a' "$WIFI_PASSWORD_FILE")"
    if (((8#$password_mode & 077) != 0)); then
        warn "Wi-Fi password file permissions are $password_mode; prefer mode 600"
    fi
    WIFI_PASSWORD="$(<"$WIFI_PASSWORD_FILE")"
    [[ $WIFI_PASSWORD != *$'\n'* ]] || die "Wi-Fi password file must contain one line"
elif ((DRY_RUN == 0)); then
    [[ -t 0 ]] || die "no terminal for password prompt; use --wifi-password-file"
    IFS= read -r -s -p "Wi-Fi password for '$SSID': " WIFI_PASSWORD || die "could not read password"
    printf '\n' >&2
fi

if [[ -n $WIFI_PASSWORD ]]; then
    has_control_character "$WIFI_PASSWORD" && die "Wi-Fi password contains a control character"
    if [[ $WIFI_PASSWORD =~ ^[[:xdigit:]]{64}$ ]]; then
        : # A raw WPA PSK is valid.
    elif ((${#WIFI_PASSWORD} < 8 || ${#WIFI_PASSWORD} > 63)); then
        die "Wi-Fi password must be 8-63 bytes, or exactly 64 hexadecimal digits"
    fi
elif ((DRY_RUN == 0)); then
    die "Wi-Fi password cannot be empty"
fi

mount_options="$(findmnt -rn --mountpoint "$ROOT" -o OPTIONS)"
[[ -n $mount_options ]] || die "cannot determine mount options for $ROOT"

note "Armbian headless preparation plan:"
note "  target:          $ROOT"
note "  Wi-Fi SSID:      $SSID"
note "  country:         $COUNTRY"
note "  interface match: $WIFI_MATCH"
note "  SSH keys source: $AUTHORIZED_KEYS"
note "  SSH login:       root, public key only"
note "  Netplan file:    /etc/netplan/90-rock5b-headless-wifi.yaml"
note "  SSH drop-in:     /etc/ssh/sshd_config.d/10-rock5b-headless.conf"

if ((DRY_RUN == 1)); then
    if [[ ,$mount_options, == *,ro,* ]]; then
        note "  mount handling:  would temporarily remount read-write, then restore read-only"
    else
        note "  mount handling:  already read-write; would leave it read-write"
    fi
    [[ -n $WIFI_PASSWORD_FILE ]] || note "  Wi-Fi password:  would prompt during a real run"
    note "Dry run complete; no files or mount state changed."
    exit 0
fi

if [[ ,$mount_options, == *,ro,* ]]; then
    note "Temporarily remounting $ROOT read-write..."
    mount -o remount,rw "$ROOT"
    REMOUNTED_RW=1
    mount_options="$(findmnt -rn --mountpoint "$ROOT" -o OPTIONS)"
    [[ ,$mount_options, == *,rw,* ]] || die "remount did not make $ROOT writable"
fi

[[ ! -L $ROOT/root/.ssh ]] || die "refusing to use a symlinked /root/.ssh"
[[ ! -L $ROOT/root/.ssh/authorized_keys ]] || \
    die "refusing to replace a symlinked /root/.ssh/authorized_keys"
mkdir -p "$ROOT/etc/netplan" "$ROOT/etc/ssh/sshd_config.d" "$ROOT/root/.ssh"

yaml_quote "$SSID"
ssid_yaml="$REPLY"
yaml_quote "$COUNTRY"
country_yaml="$REPLY"
yaml_quote "$WIFI_MATCH"
match_yaml="$REPLY"
yaml_quote "$WIFI_PASSWORD"
password_yaml="$REPLY"

register_temp "$ROOT/etc/netplan" "90-rock5b-headless-wifi.yaml"
netplan_temp="$TEMP_PATH"
{
    printf '%s\n' \
        '# Managed by prepare-armbian-headless.sh' \
        'network:' \
        '  version: 2' \
        '  renderer: networkd' \
        '  wifis:' \
        '    headless-wifi:' \
        '      match:'
    printf '        name: %s\n' "$match_yaml"
    printf '%s\n' \
        '      dhcp4: true' \
        '      optional: true'
    printf '      regulatory-domain: %s\n' "$country_yaml"
    printf '%s\n' '      access-points:'
    printf '        %s:\n' "$ssid_yaml"
    printf '          password: %s\n' "$password_yaml"
} >"$netplan_temp"
chmod 0600 "$netplan_temp"
chown 0:0 "$netplan_temp"

register_temp "$ROOT/etc/ssh/sshd_config.d" "10-rock5b-headless.conf"
sshd_temp="$TEMP_PATH"
printf '%s\n' \
    '# Managed by prepare-armbian-headless.sh' \
    'PubkeyAuthentication yes' \
    'PasswordAuthentication no' \
    'KbdInteractiveAuthentication no' \
    'PermitRootLogin prohibit-password' >"$sshd_temp"
chmod 0644 "$sshd_temp"
chown 0:0 "$sshd_temp"

register_temp "$ROOT/root/.ssh" "authorized_keys"
keys_temp="$TEMP_PATH"
if [[ -f $ROOT/root/.ssh/authorized_keys ]]; then
    cat -- "$ROOT/root/.ssh/authorized_keys" >"$keys_temp"
else
    : >"$keys_temp"
fi

added_lines=0
while IFS= read -r key_line || [[ -n $key_line ]]; do
    [[ -n $key_line ]] || continue
    if ! grep -Fqx -- "$key_line" "$keys_temp"; then
        [[ ! -s $keys_temp ]] || printf '\n' >>"$keys_temp"
        printf '%s\n' "$key_line" >>"$keys_temp"
        ((added_lines += 1))
    fi
done <"$AUTHORIZED_KEYS"
chmod 0600 "$keys_temp"
chown 0:0 "$keys_temp"

chmod 0700 "$ROOT/root/.ssh"
chown 0:0 "$ROOT/root/.ssh"
mv -f -- "$netplan_temp" "$ROOT/etc/netplan/90-rock5b-headless-wifi.yaml"
mv -f -- "$sshd_temp" "$ROOT/etc/ssh/sshd_config.d/10-rock5b-headless.conf"
mv -f -- "$keys_temp" "$ROOT/root/.ssh/authorized_keys"

ssh_wants="$ROOT/etc/systemd/system/multi-user.target.wants"
mkdir -p "$ssh_wants"
if [[ -e $ssh_wants/ssh.service && ! -L $ssh_wants/ssh.service ]]; then
    die "refusing to replace non-symlink: /etc/systemd/system/multi-user.target.wants/ssh.service"
fi
ln -sfn /usr/lib/systemd/system/ssh.service "$ssh_wants/ssh.service"

WIFI_PASSWORD=""
sync_target
if ((REMOUNTED_RW == 1)); then
    note "Restoring $ROOT to its original read-only state..."
    mount -o remount,ro "$ROOT"
    REMOUNTED_RW=0
fi

remove_temps
trap - EXIT INT TERM HUP

note "Prepared the Armbian image for headless access."
note "  added authorized_keys lines: $added_lines"
note "  SSH after boot: ssh root@<board-ip>"
note "Armbian will regenerate its SSH host keys on first boot; use the final key fingerprint."
