#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: sudo bash disable-ramoops-capture.sh

Backs up /boot/armbianEnv.txt, removes only files marked as managed by the
ramoops enable script, and removes its boot arguments/obsolete overlay
selection. The debug DTB's fixed persistent-memory reservation remains until
the stock DTB package is restored.
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
  "panic_on_oops=1"
)

if [[ "${EUID}" -ne 0 ]]; then
  exec sudo "$0" "$@"
fi

backup_file() {
  local path="$1"
  local stamp
  stamp="$(date +%Y%m%d-%H%M%S)"
  cp -a "$path" "${path}.bak-disable-ramoops-${stamp}"
  echo "Backed up ${path} to ${path}.bak-disable-ramoops-${stamp}"
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

remove_managed_file() {
  local path="$1"
  if [[ ! -e "$path" ]]; then
    return 1
  fi

  if grep -q "$MARKER" "$path" 2>/dev/null; then
    rm -f "$path"
    echo "Removed ${path}"
    return 0
  else
    echo "Left ${path} in place because it is not marked as managed by this script." >&2
    return 1
  fi
}

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing ${ENV_FILE}; this does not look like the expected Armbian boot layout." >&2
  exit 1
fi

backup_file "$ENV_FILE"
remove_list_item "$ENV_FILE" "user_overlays" "ramoops"
for arg in "${RAMOOPS_ARGS[@]}"; do
  remove_list_item "$ENV_FILE" "extraargs" "$arg"
done

remove_managed_file "$MODULES_FILE" || true
remove_managed_file "$SYSCTL_FILE" || true
removed_dts=0
if remove_managed_file "$DTS_FILE"; then
  removed_dts=1
fi
if [[ -e "$DTBO_FILE" ]]; then
  if [[ "$removed_dts" -eq 1 ]]; then
    rm -f "$DTBO_FILE"
    echo "Removed ${DTBO_FILE}"
  else
    echo "Left ${DTBO_FILE} in place because ${DTS_FILE} was not removed as a managed file." >&2
  fi
fi

if [[ -d "$OVERLAY_DIR" ]] && ! find "$OVERLAY_DIR" -mindepth 1 -print -quit | grep -q .; then
  rmdir "$OVERLAY_DIR"
  echo "Removed empty ${OVERLAY_DIR}"
fi

echo
echo "Ramoops panic policy changes are removed. The debug DTB still contains ramoops."
echo "Restore the stock DTB package to remove its reservation, then reboot:"
echo "  sudo reboot"
