#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: sudo bash enable-ramoops-capture.sh

Backs up /boot/armbianEnv.txt, installs a managed ramoops overlay/module/sysctl,
and enables panic capture for the next boot. Reverse the managed changes with
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

write_overlay() {
  mkdir -p "$OVERLAY_DIR"

  if [[ -e "$DTS_FILE" ]] && ! grep -q "$MARKER" "$DTS_FILE"; then
    echo "${DTS_FILE} already exists and is not managed by this script; refusing to overwrite it." >&2
    exit 1
  fi

  cat >"$DTS_FILE" <<EOF
/* ${MARKER} */
/dts-v1/;
/plugin/;

/ {
    fragment@0 {
        target-path = "/reserved-memory";
        __overlay__ {
            #address-cells = <0x02>;
            #size-cells = <0x02>;

            ramoops@4fe000000 {
                compatible = "ramoops";
                reg = <0x4 0xfe000000 0x0 0x00400000>;
                no-map;
                record-size = <0x00040000>;
                console-size = <0x00100000>;
                ftrace-size = <0x00100000>;
                pmsg-size = <0x00040000>;
                ecc-size = <16>;
            };
        };
    };
};
EOF

  dtc -@ -I dts -O dtb -o "$DTBO_FILE" "$DTS_FILE"
  echo "Wrote ${DTS_FILE}"
  echo "Compiled ${DTBO_FILE}"
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
kernel.panic_on_oops = 1
EOF

  sysctl -w kernel.panic_on_oops=1 >/dev/null
  echo "Wrote ${SYSCTL_FILE}"
}

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing ${ENV_FILE}; this does not look like the expected Armbian boot layout." >&2
  exit 1
fi

require_command dtc

backup_file "$ENV_FILE"
write_overlay
ensure_list_item "$ENV_FILE" "user_overlays" "ramoops"
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
echo "  lsmod | grep ramoops"
echo "  sysctl kernel.panic_on_oops"
echo "  sudo dmesg | grep -i 'ramoops\\|pstore'"
echo "  sudo ls -l /sys/fs/pstore"
