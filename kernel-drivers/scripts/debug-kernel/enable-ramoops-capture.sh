#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: sudo bash enable-ramoops-capture.sh

Verifies the debug kernel's packaged ramoops reservation, backs up
/boot/armbianEnv.txt, removes the obsolete high-DRAM overlay, and enables panic
capture for the next boot. Reverse the managed policy changes with
disable-ramoops-capture.sh.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac

ENV_FILE="/boot/armbianEnv.txt"
OVERLAY_DIR="/boot/overlay-user"
DTS_FILE="${OVERLAY_DIR}/ramoops.dts"
DTBO_FILE="${OVERLAY_DIR}/ramoops.dtbo"
DTB_FILE="${DTB_FILE:-/boot/dtb/rockchip/rk3588-rock-5b.dtb}"
MODULES_FILE="/etc/modules-load.d/ramoops.conf"
SYSCTL_FILE="/etc/sysctl.d/99-ramoops-panic-on-oops.conf"
MARKER="Managed by enable-ramoops-capture.sh"

RAMOOPS_ARGS=(
  "pstore.backend=ramoops"
  "pstore.kmsg_bytes=262144"
  "printk.always_kmsg_dump=1"
  "panic=10"
)

OLD_RAMOOPS_ARGS=(
  "panic_on_oops=1"
)

if [[ "${EUID}" -ne 0 ]]; then
  exec sudo "$0" "$@"
fi

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    echo "Install device-tree-compiler, then rerun this script." >&2
    exit 1
  fi
}

backup_file() {
  local path="$1"
  local stamp
  stamp="$(date +%Y%m%d-%H%M%S)"
  cp -a "$path" "${path}.bak-ramoops-${stamp}"
  echo "Backed up ${path} to ${path}.bak-ramoops-${stamp}"
}

ensure_list_item() {
  local file="$1"
  local key="$2"
  local item="$3"
  local tmp
  tmp="$(mktemp)"

  awk -v key="$key" -v item="$item" '
    BEGIN { found = 0 }
    $0 ~ "^" key "=" {
      found = 1
      val = substr($0, length(key) + 2)
      n = split(val, parts, /[ \t]+/)
      have = 0
      for (i = 1; i <= n; i++) {
        if (parts[i] == item) {
          have = 1
        }
      }
      if (!have) {
        if (val == "") {
          val = item
        } else {
          val = val " " item
        }
      }
      print key "=" val
      next
    }
    { print }
    END {
      if (!found) {
        print key "=" item
      }
    }
  ' "$file" >"$tmp"

  chown --reference="$file" "$tmp"
  chmod --reference="$file" "$tmp"
  mv "$tmp" "$file"
}

remove_list_item() {
  local file="$1"
  local key="$2"
  local item="$3"
  local tmp
  tmp="$(mktemp)"

  awk -v key="$key" -v item="$item" '
    $0 ~ "^" key "=" {
      val = substr($0, length(key) + 2)
      n = split(val, parts, /[ \t]+/)
      out = ""
      for (i = 1; i <= n; i++) {
        if (parts[i] != "" && parts[i] != item) {
          out = out (out == "" ? "" : " ") parts[i]
        }
      }
      if (out != "") {
        print key "=" out
      }
      next
    }
    { print }
  ' "$file" >"$tmp"

  chown --reference="$file" "$tmp"
  chmod --reference="$file" "$tmp"
  mv "$tmp" "$file"
}

verify_packaged_ramoops() {
  local reg

  if [[ ! -r "$DTB_FILE" ]]; then
    echo "Missing selected ROCK 5B DTB: ${DTB_FILE}" >&2
    echo "Install the rebuilt linux-dtb-current-rockchip64 package first." >&2
    exit 1
  fi

  reg="$(fdtget -t x "$DTB_FILE" /reserved-memory/ramoops@118000 reg 2>/dev/null || true)"
  if [[ "$reg" != "0 118000 0 d0000" ]]; then
    echo "${DTB_FILE} does not contain the fixed ramoops reservation." >&2
    echo "Expected /reserved-memory/ramoops@118000 reg = <0 118000 0 d0000>." >&2
    echo "Install the rebuilt linux-dtb-current-rockchip64 package first." >&2
    exit 1
  fi
}

remove_legacy_overlay() {
  local removed_dts=0

  if [[ -e "$DTS_FILE" ]] && grep -q "$MARKER" "$DTS_FILE"; then
    rm -f "$DTS_FILE"
    removed_dts=1
    echo "Removed obsolete ${DTS_FILE}"
  fi
  if [[ -e "$DTBO_FILE" && "$removed_dts" -eq 1 ]]; then
    rm -f "$DTBO_FILE"
    echo "Removed obsolete ${DTBO_FILE}"
  fi
}

write_modules_load() {
  if [[ -e "$MODULES_FILE" ]] && ! grep -q "$MARKER" "$MODULES_FILE"; then
    echo "${MODULES_FILE} already exists and is not managed by this script; refusing to overwrite it." >&2
    exit 1
  fi

  cat >"$MODULES_FILE" <<EOF
# ${MARKER}
ramoops
EOF

  echo "Wrote ${MODULES_FILE}"
}

write_sysctl() {
  if [[ -e "$SYSCTL_FILE" ]] && ! grep -q "$MARKER" "$SYSCTL_FILE"; then
    echo "${SYSCTL_FILE} already exists and is not managed by this script; refusing to overwrite it." >&2
    exit 1
  fi

  cat >"$SYSCTL_FILE" <<EOF
# ${MARKER}
# Debug builds boot with panic_on_oops=0: keeping the board up on a
# process-context oops lets journald capture the full trace live and keeps
# the repro session alive. Ramoops records ARE recovered across warm reboots
# on the 6.18.40-era kernels (findings/2026-07-28-ramoops-retention-works-
# on-6-18-40-kernels.md) — the earlier "does not survive" result was scoped
# to the 6.18.38-era kernels — but the panic path is still being requalified.
# The distributable kernel keeps the fail-fast default (panic_on_oops=1).
kernel.panic_on_oops = 0
EOF

  sysctl -w kernel.panic_on_oops=0 >/dev/null
  echo "Wrote ${SYSCTL_FILE}"
}

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing ${ENV_FILE}; this does not look like the expected Armbian boot layout." >&2
  exit 1
fi

require_command fdtget
verify_packaged_ramoops

backup_file "$ENV_FILE"
remove_list_item "$ENV_FILE" "user_overlays" "ramoops"
remove_legacy_overlay
for arg in "${OLD_RAMOOPS_ARGS[@]}"; do
  remove_list_item "$ENV_FILE" "extraargs" "$arg"
done
for arg in "${RAMOOPS_ARGS[@]}"; do
  ensure_list_item "$ENV_FILE" "extraargs" "$arg"
done
write_modules_load
write_sysctl

echo
echo "Ramoops capture is configured. Reboot for it to take effect:"
echo "  sudo reboot"
echo
echo "After reboot, verify with:"
echo "  test -d /sys/module/ramoops && echo 'ramoops loaded'"
echo "  sysctl kernel.panic_on_oops"
echo "  sudo dmesg | grep -i 'ramoops\\|pstore'"
echo
echo "To look for recovered records from the previous boot:"
echo "  journalctl -b -u systemd-pstore   # 'PStore ... moved' = a recovery"
echo "  sudo ls -l /var/lib/systemd/pstore"
echo
echo "Do NOT read /sys/fs/pstore as evidence: systemd-pstore archives and"
echo "erases it within seconds of boot, so it is always empty by login."
