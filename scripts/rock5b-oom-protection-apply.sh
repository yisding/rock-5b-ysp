#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: GPL-2.0-or-later
# Install and configure earlyoom so memory exhaustion kills one process instead
# of livelocking the board. Sized from the 2026-07-25 thrash-livelock wedge.

set -euo pipefail
export LC_ALL=C

CONF_PATH="${CONF_PATH:-/etc/default/earlyoom}"
SERVICE_NAME="${SERVICE_NAME:-earlyoom.service}"

# Kill when available memory AND free swap are both below their gates. earlyoom
# ANDs the two conditions; that is the whole reason this tool fits this board,
# where swap sits at 90-97% for hours while the system is completely healthy.
# SIGTERM at the first number, SIGKILL at the second.
MEM_TERM_PERCENT="${MEM_TERM_PERCENT:-12}"
MEM_KILL_PERCENT="${MEM_KILL_PERCENT:-6}"
SWAP_TERM_PERCENT="${SWAP_TERM_PERCENT:-10}"
SWAP_KILL_PERCENT="${SWAP_KILL_PERCENT:-5}"

# Periodic memory report. Kept deliberately short: sar samples every 10 minutes
# and dropped samples entirely during the wedge, which is what made the
# post-mortem hard. This is the finer-grained record for the next one.
REPORT_INTERVAL="${REPORT_INTERVAL:-900}"

# Processes earlyoom must not select, so the board stays reachable after a kill.
# Space-free on purpose: systemd word-splits $EARLYOOM_ARGS without shell quote
# processing, so a regex containing a space would be split into two arguments.
AVOID_REGEX="${AVOID_REGEX:-^(sshd|systemd|systemd-journald|dbus-daemon|NetworkManager|tailscaled|init|login)\$}"

MODE=apply
DRY_RUN=0

usage() {
    cat <<'EOF'
Usage:
  sudo bash scripts/rock5b-oom-protection-apply.sh [options]
  bash scripts/rock5b-oom-protection-apply.sh --status

Install earlyoom and configure it to break a memory-pressure death spiral
before the board stops making forward progress. Without an OOM daemon a
zram-backed board can livelock indefinitely: reclaim keeps "succeeding" by
evicting page cache, so the kernel OOM killer never fires and the box simply
stops responding until it is power-cycled.

Default policy:
  * SIGTERM when available memory < 12% AND free swap < 10%
  * SIGKILL when available memory <  6% AND free swap <  5%
  * largest-RSS victim selection (no --prefer; see below)
  * sshd/systemd/journald/NetworkManager/tailscaled/dbus never selected
  * memory report to the journal every 900 s

The AND gate is the point. This board legitimately runs at 90-97% swap for
hours while healthy, so a swap-only trigger would fire constantly; requiring
both conditions separates the benign state from the fatal one.

No --prefer is configured on purpose. earlyoom multiplies a preferred process's
badness by 10, so preferring compilers lets a ~1G cc1 outrank a multi-gigabyte
leak -- killing something make respawns in seconds while the real hog survives.
Default largest-RSS selection picks the actual outlier.

Options:
  --status           Show current memory, swap, and earlyoom state. No root,
                     no writes.
  --dry-run          Print the intended configuration without installing or
                     writing anything.
  --revert           Disable earlyoom and restore the previous configuration.
  -h, --help         Show this help.

Environment overrides: CONF_PATH, SERVICE_NAME, MEM_TERM_PERCENT,
MEM_KILL_PERCENT, SWAP_TERM_PERCENT, SWAP_KILL_PERCENT, REPORT_INTERVAL,
AVOID_REGEX.
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

note() {
    printf '%s\n' "$*"
}

earlyoom_args() {
    printf -- '-m %s,%s -s %s,%s -r %s --avoid %s' \
        "$MEM_TERM_PERCENT" "$MEM_KILL_PERCENT" \
        "$SWAP_TERM_PERCENT" "$SWAP_KILL_PERCENT" \
        "$REPORT_INTERVAL" "$AVOID_REGEX"
}

require_root() {
    [ "$(id -u)" -eq 0 ] || die "must run as root (use sudo)"
}

show_status() {
    note "== memory =="
    free -m | sed -n '1,3p'
    note ""
    note "== swap backing =="
    if [ -r /proc/swaps ]; then
        cat /proc/swaps
    else
        note "  (/proc/swaps unreadable)"
    fi
    note ""
    note "== earlyoom =="
    if command -v earlyoom >/dev/null 2>&1; then
        note "  binary:  $(command -v earlyoom)"
    else
        note "  binary:  not installed"
    fi
    if [ -r "$CONF_PATH" ]; then
        note "  config:  $CONF_PATH"
        sed -n 's/^/    /p' "$CONF_PATH"
    else
        note "  config:  $CONF_PATH (absent)"
    fi
    note "  service: $(systemctl is-active "$SERVICE_NAME" 2>/dev/null || echo inactive)"
    note "  enabled: $(systemctl is-enabled "$SERVICE_NAME" 2>/dev/null || echo disabled)"
    note ""
    note "== conflicting OOM daemons =="
    local other found=0
    for other in systemd-oomd.service nohang.service nohang-desktop.service; do
        if [ "$(systemctl is-active "$other" 2>/dev/null || true)" = "active" ]; then
            note "  WARNING: $other is active -- two OOM daemons will double-kill"
            found=1
        fi
    done
    [ "$found" -eq 0 ] && note "  none active (correct)"
    return 0
}

do_revert() {
    require_root
    note "==> disabling $SERVICE_NAME"
    systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true

    local newest
    newest="$(ls -1t "$CONF_PATH".bak.* 2>/dev/null | head -1 || true)"
    if [ -n "$newest" ]; then
        note "==> restoring $newest -> $CONF_PATH"
        cp -a "$newest" "$CONF_PATH"
    else
        note "==> no saved backup; leaving $CONF_PATH in place"
    fi
    note "Reverted. earlyoom is no longer running; the board has no OOM backstop."
}

do_apply() {
    local args
    args="$(earlyoom_args)"

    if [ "$DRY_RUN" -eq 1 ]; then
        note "== dry run: nothing installed, nothing written =="
        note "  package:  earlyoom"
        note "  config:   $CONF_PATH"
        note "  contents: EARLYOOM_ARGS=\"$args\""
        note "  service:  systemctl enable --now $SERVICE_NAME"
        return 0
    fi

    require_root

    note "==> installing earlyoom"
    DEBIAN_FRONTEND=noninteractive apt-get install -y earlyoom

    if [ -f "$CONF_PATH" ]; then
        local backup
        backup="$CONF_PATH.bak.$(date +%Y%m%d-%H%M%S)"
        note "==> backing up $CONF_PATH -> $backup"
        cp -a "$CONF_PATH" "$backup"
    fi

    note "==> writing $CONF_PATH"
    # No inner quotes around the regex: systemd splits $EARLYOOM_ARGS on
    # whitespace without shell quote processing, so quotes would be passed
    # through literally and the regex would never match.
    cat > "$CONF_PATH" <<EOF
# Managed by scripts/rock5b-oom-protection-apply.sh
# Rationale and threshold derivation:
#   findings/2026-07-25-rock5b-zram-thrash-livelock-wedge.md
EARLYOOM_ARGS="$args"
EOF

    note "==> enabling $SERVICE_NAME"
    systemctl enable --now "$SERVICE_NAME"
    systemctl restart "$SERVICE_NAME"

    note ""
    note "==> parsed configuration (verifies the quoting survived systemd)"
    journalctl -u "$SERVICE_NAME" -b --no-pager 2>/dev/null | tail -12 || true
    note ""
    show_status
}

while [ $# -gt 0 ]; do
    case "$1" in
        --status)
            MODE=status
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --revert)
            MODE=revert
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "unknown argument: $1"
            ;;
    esac
done

case "$MODE" in
    status) show_status ;;
    revert) do_revert ;;
    apply)  do_apply ;;
esac
