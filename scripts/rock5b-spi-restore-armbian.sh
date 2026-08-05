#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: GPL-2.0-or-later
# Restore the ROCK 5B SPI NOR with the installed Armbian SPI loader image.
#
# By default the image comes from:
#   /usr/lib/linux-u-boot-current-rock-5b/rkspi_loader.img
#
# Pass --image to restore a saved 16 MiB SPI dump instead.
set -euo pipefail

DEFAULT_IMAGE="/usr/lib/linux-u-boot-current-rock-5b/rkspi_loader.img"
IMAGE="${IMAGE:-}"
YES=0
DRY_RUN=0
FORCE_BOARD=0
MTD_DEV="${MTD_DEV:-}"

usage() {
  cat <<'EOF'
Usage:
  sudo bash scripts/rock5b-spi-restore-armbian.sh [options]

Options:
  --image FILE       SPI image to write. Default:
                     /usr/lib/linux-u-boot-current-rock-5b/rkspi_loader.img
  --mtd DEV          MTD character device to write, e.g. /dev/mtd0.
                     Default: auto-detect the ROCK 5B 16 MiB SPI NOR.
  --yes              Do not prompt for RESTORE-SPI.
  --dry-run          Print what would happen without writing.
  --force-board      Skip ROCK 5B board-model check.
  -h, --help         Show this help.

Environment overrides:
  IMAGE=/path/img    Same as --image.
  MTD_DEV=/dev/mtd0  Same as --mtd.
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --image)
      [ "$#" -ge 2 ] || die "--image requires a value"
      IMAGE="$2"
      shift 2
      ;;
    --mtd)
      [ "$#" -ge 2 ] || die "--mtd requires a value"
      MTD_DEV="$2"
      shift 2
      ;;
    --yes)
      YES=1
      shift
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

if [ "$(id -u)" -ne 0 ]; then
  [ "$DRY_RUN" -eq 1 ] || die "run as root: sudo bash $0"
  echo "Dry-run mode: continuing without root because no flash writes will be attempted."
fi
need_cmd flashcp
need_cmd cmp
need_cmd grep
need_cmd mktemp
need_cmd sha256sum
need_cmd stat
need_cmd tr

check_board() {
  [ "$FORCE_BOARD" -eq 1 ] && return 0

  local model=""
  local compatible=""
  [ -r /proc/device-tree/model ] && model="$(tr -d '\0' </proc/device-tree/model)"
  [ -r /proc/device-tree/compatible ] && compatible="$(tr '\0' ' ' </proc/device-tree/compatible)"

  [ "$model" = "Radxa ROCK 5B" ] && return 0
  case " $compatible " in
    *" radxa,rock-5b "*) return 0 ;;
  esac

  die "this does not look like a Radxa ROCK 5B; use --force-board only if you are certain"
}

sysfs_for_mtd() {
  local dev="$1"
  local base=""
  base="$(basename "$dev")"
  base="${base%%ro}"
  [ -e "/sys/class/mtd/$base" ] || die "no sysfs entry for $dev"
  printf '/sys/class/mtd/%s\n' "$base"
}

read_attr() {
  local dir="$1"
  local attr="$2"
  [ -r "$dir/$attr" ] || die "missing MTD attribute: $dir/$attr"
  cat "$dir/$attr"
}

detect_mtd() {
  if [ -n "$MTD_DEV" ]; then
    [ -c "$MTD_DEV" ] || die "$MTD_DEV is not an MTD character device"
    return 0
  fi

  local dir name type size dev
  local matches=()
  for dir in /sys/class/mtd/mtd[0-9]*; do
    [ -e "$dir" ] || continue
    name="$(cat "$dir/name" 2>/dev/null || true)"
    type="$(cat "$dir/type" 2>/dev/null || true)"
    size="$(cat "$dir/size" 2>/dev/null || true)"

    if [ "$type" = "nor" ] && [ "$size" = "16777216" ]; then
      dev="/dev/$(basename "$dir")"
      [ -c "$dev" ] && matches+=("$dev:$name")
    fi
  done

  [ "${#matches[@]}" -eq 1 ] || {
    printf 'Detected candidates:\n' >&2
    printf '  %s\n' "${matches[@]:-none}" >&2
    die "expected exactly one 16 MiB NOR MTD device; pass --mtd /dev/mtdN"
  }

  MTD_DEV="${matches[0]%%:*}"
}

read_device_for_mtd() {
  local dev="$1"
  local base n
  base="$(basename "$dev")"
  base="${base%%ro}"
  n="${base#mtd}"

  if [ -c "/dev/${base}ro" ]; then
    printf '/dev/%sro\n' "$base"
  elif [ -b "/dev/mtdblock$n" ]; then
    printf '/dev/mtdblock%s\n' "$n"
  else
    printf '%s\n' "$dev"
  fi
}

check_mtd_shape() {
  local dir="$1"
  local name type size erasesize
  name="$(read_attr "$dir" name)"
  type="$(read_attr "$dir" type)"
  size="$(read_attr "$dir" size)"
  erasesize="$(read_attr "$dir" erasesize)"

  [ "$type" = "nor" ] || die "$MTD_DEV type is $type, expected nor"
  [ "$size" = "16777216" ] || die "$MTD_DEV size is $size, expected 16777216"
  [ "$erasesize" = "4096" ] || die "$MTD_DEV erasesize is $erasesize, expected 4096"

  echo "MTD device : $MTD_DEV"
  echo "MTD name   : $name"
  echo "MTD type   : $type"
  echo "MTD size   : $size bytes"
  echo "Erase size : $erasesize bytes"
}

select_image() {
  if [ -z "$IMAGE" ]; then
    IMAGE="$DEFAULT_IMAGE"
  fi
  [ -f "$IMAGE" ] || die "SPI image not found: $IMAGE"
}

check_image() {
  local image="$1"
  local expected_size="$2"
  local actual_size

  actual_size="$(stat -c '%s' "$image")"
  [ "$actual_size" = "$expected_size" ] || die "$image is $actual_size bytes, expected $expected_size"

  grep -aq 'U-Boot' "$image" || die "$image does not look like a U-Boot SPI image"
  grep -aiq 'rock-5b' "$image" || die "$image does not contain a rock-5b marker"

  echo "Image     : $image"
  echo "Image size: $actual_size bytes"
  sha256sum "$image"
}

confirm_or_die() {
  [ "$YES" -eq 1 ] && return 0
  [ -t 0 ] || die "refusing to write SPI without a TTY; pass --yes if this is intentional"

  echo
  echo "This will overwrite the SPI bootloader with the selected image."
  printf 'Type RESTORE-SPI to continue: '

  local answer
  read -r answer
  [ "$answer" = "RESTORE-SPI" ] || die "confirmation did not match"
}

check_board
detect_mtd
select_image

MTD_SYSFS="$(sysfs_for_mtd "$MTD_DEV")"
READ_DEV="$(read_device_for_mtd "$MTD_DEV")"
MTD_SIZE="$(read_attr "$MTD_SYSFS" size)"

echo "ROCK 5B SPI restore"
check_mtd_shape "$MTD_SYSFS"
echo "Read device: $READ_DEV"
check_image "$IMAGE" "$MTD_SIZE"
confirm_or_die

if [ "$DRY_RUN" -eq 1 ]; then
  echo "Would run: flashcp $IMAGE $MTD_DEV"
  echo "Would verify: cmp -n $MTD_SIZE $IMAGE $READ_DEV"
  exit 0
fi

echo "Writing SPI image..."
FLASHCP_LOG="$(mktemp)"
if ! flashcp "$IMAGE" "$MTD_DEV" >"$FLASHCP_LOG" 2>&1; then
  cat "$FLASHCP_LOG" >&2
  rm -f "$FLASHCP_LOG"
  die "flashcp failed"
fi
rm -f "$FLASHCP_LOG"
echo "Write complete."
echo "Verifying readback..."
cmp -n "$MTD_SIZE" "$IMAGE" "$READ_DEV"

echo
echo "SPI restored and verified. Reboot or power-cycle to use the Armbian SPI bootloader."
