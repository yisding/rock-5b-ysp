#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: GPL-2.0-only
# =============================================================================
# set-boot-load-addresses.sh — raise the U-Boot DT/initrd/scratch load addresses
#
# Stock RK3588 U-Boot leaves 127.0 MiB between kernel_addr_r (0x00400000) and
# fdt_addr_r (0x08300000). An arm64 Image reserves image_size bytes at its load
# address -- text *plus BSS*, much larger than the file -- so a debug kernel
# past that gap zeroes the loaded device tree while clearing BSS and dies before
# console init: no HDMI, no serial, no ramoops, no journal boot entry. The
# 2026-07-24 P4052-C40aa-H7883 rewrite debug build (image_size 132.4 MiB) failed
# exactly this way; the 2026-07-23 P3695 build (113.4 MiB) booted.
#
# This rewrites ONLY /boot/boot.cmd (a marked setenv block) and /boot/boot.scr.
# No kernel, initrd or DTB needs regenerating: uInitrd carries load/entry 0, the
# arm64 Image header sets the 2 MiB-anywhere placement flag, and DTBs hold no
# load address. boot.scr resolves the /boot/{Image,uInitrd,dtb} symlinks, so one
# run covers every kernel installed afterwards.
#
# Like kernel-revert.sh, this is meant to also run from an SD-card rescue boot
# against the INTERNAL disk -- that is the whole point of --revert. It needs
# only coreutils + awk to revert; mkimage is used when present and falls back to
# restoring the pre-apply boot.scr backup when it is not.
#
# USAGE
#   sudo bash set-boot-load-addresses.sh [TARGET] [--check|--apply|--revert] [--yes]
#
#   TARGET (default: the live root '/'):
#     --auto            auto-detect the internal Armbian root (ext4 with
#                       /boot/armbianEnv.txt), excluding the device you booted
#                       from, and mount it
#     --device PART     mount PART rw and operate on it (e.g. /dev/nvme0n1p1)
#     --root DIR        operate on an already-mounted target root at DIR
#
#   modes:
#     --check           report the map, image_size and headroom; changes nothing
#                       and needs no root (default when the target is read-only)
#     --apply           insert the managed block + regenerate boot.scr (default)
#     --revert          drop the managed block, restoring stock addresses
#
#   --yes    don't prompt for confirmation
#
# EXAMPLES
#   # Live, before installing a big debug kernel:
#   ./set-boot-load-addresses.sh --check
#   sudo ./set-boot-load-addresses.sh
#
#   # From an SD rescue boot after a kernel that never came up:
#   sudo bash set-boot-load-addresses.sh --auto --revert
#   # ...or against a root you mounted yourself:
#   sudo mount /dev/nvme0n1p1 /mnt/nvme
#   sudo bash /mnt/nvme/boot/set-boot-load-addresses.sh --root /mnt/nvme --revert
#
# A copy of this script is installed to <target>/boot/ on --apply, so a rescue
# boot always finds it next to the boot.cmd it edits.
# =============================================================================
set -uo pipefail

say()  { printf '>>> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

MARKER="Managed by set-boot-load-addresses.sh"

# Stock rk3588 U-Boot environment (read out of the tracked SPI image), plus
# boot.cmd's own default for load_addr. Fallbacks when no managed block exists.
STOCK_KERNEL_ADDR="0x00400000"  #   4 MiB
STOCK_FDT_ADDR="0x08300000"     # 131 MiB
STOCK_RAMDISK_ADDR="0x0a200000" # 163 MiB
STOCK_LOAD_ADDR="0x9000000"     # 144 MiB -- boot.cmd line 6

# Raised map. Everything stays inside the first 256 MiB of DRAM (bank 0 is
# 0x00200000..0xefffffff and the device tree reserves nothing in this window
# except shmem@10f000), and clear of a kernel expanding from 4 MiB:
#   kernel  0x00400000              -> 188 MiB of headroom
#   fdt     0x0c000000 (192 MiB)    -> 8 MiB before the scratch buffer
#   scratch 0x0c800000 (200 MiB)    -> armbianEnv.txt, DT overlays, fixup.scr
#   initrd  0x0d000000 (208 MiB)    -> 48 MiB before the 256 MiB mark
NEW_FDT_ADDR="0x0c000000"
NEW_LOAD_ADDR="0x0c800000"
NEW_RAMDISK_ADDR="0x0d000000"

# ---- parse args ------------------------------------------------------------
MODE="apply"; TGT_MODE="live"; DEVICE=""; ROOT_DIR="/"; ASSUME_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --check)   MODE="check"; shift ;;
    --apply)   MODE="apply"; shift ;;
    --revert)  MODE="revert"; shift ;;
    --auto)    TGT_MODE="auto"; shift ;;
    --device)  TGT_MODE="device"; DEVICE="${2:?--device needs a partition}"; shift 2 ;;
    --root)    TGT_MODE="root"; ROOT_DIR="${2:?--root needs a dir}"; shift 2 ;;
    --yes|-y)  ASSUME_YES=1; shift ;;
    -h|--help) sed -n '2,52p' "$0"; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

# ---- resolve + mount the target root ---------------------------------------
UMOUNT_ROOT=""
cleanup() {
  [ -n "$UMOUNT_ROOT" ] && { sync; umount "$UMOUNT_ROOT" 2>/dev/null || umount -l "$UMOUNT_ROOT" 2>/dev/null || true; rmdir "$UMOUNT_ROOT" 2>/dev/null || true; }
}
trap cleanup EXIT

mount_dev() { # $1 = partition -> sets ROOT_DIR, UMOUNT_ROOT
  local part="$1" mnt
  [ -b "$part" ] || die "not a block device: $part"
  mnt="$(mktemp -d /tmp/setloadaddr.XXXXXX)"
  mount "$part" "$mnt" || die "could not mount $part"
  ROOT_DIR="$mnt"; UMOUNT_ROOT="$mnt"
  say "mounted $part at $mnt"
}

# Only the modes that mount something need root up front; --root operates on an
# already-mounted tree and escalates later, and only if the tree is unwritable.
if { [ "$TGT_MODE" = "auto" ] || [ "$TGT_MODE" = "device" ]; } && [ "$(id -u)" != 0 ]; then
  die "--auto/--device mount the target, so they need root: sudo bash $0 ..."
fi

case "$TGT_MODE" in
  live)   ROOT_DIR="/" ;;
  root)   [ -d "$ROOT_DIR" ] || die "--root dir not found: $ROOT_DIR" ;;
  device) mount_dev "$DEVICE" ;;
  auto)
    booted="$(findmnt -no SOURCE / 2>/dev/null | sed 's/\[.*//')"
    booted_disk="$(lsblk -no pkname "$booted" 2>/dev/null | head -1)"
    say "booted from: ${booted:-?} (disk ${booted_disk:-?}) — excluding it"
    cand=()
    while read -r name fstype; do
      [ "$fstype" = "ext4" ] || continue
      local_disk="$(lsblk -no pkname "/dev/$name" 2>/dev/null | head -1)"
      [ "$local_disk" = "$booted_disk" ] && continue
      cand+=("/dev/$name")
    done < <(lsblk -rno NAME,FSTYPE,TYPE | awk '$3=="part"{print $1, $2}')
    found=""
    for p in "${cand[@]}"; do
      m="$(mktemp -d /tmp/slaprobe.XXXXXX)"
      if mount -o ro "$p" "$m" 2>/dev/null; then
        [ -f "$m/boot/boot.cmd" ] && found="$p"
        umount "$m" 2>/dev/null || true
      fi
      rmdir "$m" 2>/dev/null || true
      [ -n "$found" ] && break
    done
    [ -n "$found" ] || die "auto-detect found no internal Armbian root (ext4 with /boot/boot.cmd). Use --device."
    say "auto-detected internal root: $found"
    mount_dev "$found"
    ;;
esac

# BOOT_DIR stays honoured for direct use; target flags win when given.
if [ "$TGT_MODE" = "live" ]; then
  BOOT_DIR="${BOOT_DIR:-/boot}"
else
  BOOT_DIR="${ROOT_DIR%/}/boot"
fi
BOOT_CMD="${BOOT_DIR}/boot.cmd"
BOOT_SCR="${BOOT_DIR}/boot.scr"

[ -d "$BOOT_DIR" ] || die "no boot directory at $BOOT_DIR"
[ -r "$BOOT_CMD" ] || die "no readable $BOOT_CMD — is this an Armbian root?"

# ---- helpers ---------------------------------------------------------------
# type -P, not command -v: this box exports shell wrappers for grep/find, and a
# wrapper is not what we want to detect or depend on here.
have() { type -P "$1" >/dev/null 2>&1; }

# A missing helper must not degrade into a wrong answer. current_addr falling
# back to the stock defaults because `tail` was absent would report a patched
# boot.cmd as stock -- exactly the misread that strands you in a rescue shell.
require_tools() {
  local tool missing=()
  for tool in "$@"; do have "$tool" || missing+=("$tool"); done
  [ ${#missing[@]} -eq 0 ] && return 0
  die "missing required tools: ${missing[*]}
  This script must not guess at the boot map with a broken toolset.
  On a bare rescue image: apt install coreutils gawk sed  (and u-boot-tools for --apply)."
}
require_tools awk sed od tr cat cp ls mktemp date basename readlink head tail

# One-decimal MiB, rounded, without python.
mib() {
  local bytes="$1" tenths
  tenths=$(( (bytes * 10 + 524288) / 1048576 ))
  printf '%d.%d MiB' $(( tenths / 10 )) $(( tenths % 10 ))
}

# Bytes an arm64 Image reserves at its load address (header image_size = text +
# BSS). Prints nothing unless the file really is an arm64 Image. coreutils only.
image_size_of() {
  local file="$1" magic
  [ -r "$file" ] || return 0
  magic="$(od -An -tx4 -j56 -N4 --endian=little "$file" 2>/dev/null | tr -d ' ')"
  [ "$magic" = "644d5241" ] || return 0
  od -An -tu8 -j16 -N8 --endian=little "$file" 2>/dev/null | tr -d ' '
}

is_uimage() { # a boot.scr backup worth restoring starts with the uImage magic
  [ "$(od -An -tx4 -j0 -N4 --endian=big "$1" 2>/dev/null | tr -d ' ')" = "27051956" ]
}

# awk, not grep -- see the have() note above about inherited grep wrappers.
has_managed_block() {
  awk -v m="$MARKER" 'index($0, m) { found = 1; exit } END { exit !found }' "$BOOT_CMD"
}

# Effective value of a boot.cmd variable: the managed block wins, because it is
# inserted after boot.cmd's own defaults and before the load/booti lines.
current_addr() {
  local value
  value="$(sed -n "s/^[[:space:]]*setenv[[:space:]]\+$1[[:space:]]\+\"\?\([0-9a-fA-Fx]\+\)\"\?[[:space:]]*$/\1/p" "$BOOT_CMD" | tail -1)"
  printf '%s\n' "${value:-$2}"
}

target_source() { findmnt -no SOURCE --target "$BOOT_DIR" 2>/dev/null || echo '?'; }

confirm() { # $1 = prompt
  [ "$ASSUME_YES" = 1 ] && return 0
  [ -e /dev/tty ] || die "no terminal to confirm on; rerun with --yes"
  local a; printf '%s [y/N] ' "$1" > /dev/tty
  read -r a < /dev/tty; [ "$a" = y ] || [ "$a" = Y ]
}

report() {
  local kernel fdt ramdisk load gap image size headroom
  kernel="$(current_addr kernel_addr_r "$STOCK_KERNEL_ADDR")"
  fdt="$(current_addr fdt_addr_r "$STOCK_FDT_ADDR")"
  ramdisk="$(current_addr ramdisk_addr_r "$STOCK_RAMDISK_ADDR")"
  load="$(current_addr load_addr "$STOCK_LOAD_ADDR")"
  gap=$(( fdt - kernel ))

  printf '\n  %-14s %-12s %s\n' VARIABLE ADDRESS ''
  printf '  %-14s %-12s %s\n' kernel_addr_r "$kernel" "$(mib "$kernel")"
  printf '  %-14s %-12s %s\n' fdt_addr_r "$fdt" "$(mib "$fdt")"
  printf '  %-14s %-12s %s\n' load_addr "$load" "$(mib "$load")"
  printf '  %-14s %-12s %s\n' ramdisk_addr_r "$ramdisk" "$(mib "$ramdisk")"
  printf '\n  kernel headroom (fdt_addr_r - kernel_addr_r): %s\n' "$(mib "$gap")"

  image="$(readlink -f "${BOOT_DIR}/Image" 2>/dev/null)"
  if [ -n "$image" ] && [ -r "$image" ]; then
    size="$(image_size_of "$image")"
    if [ -n "$size" ]; then
      headroom=$(( gap - size ))
      printf '  installed kernel: %s\n' "$(basename "$image")"
      printf '    image_size (text+BSS): %s\n' "$(mib "$size")"
      if [ "$headroom" -lt 0 ]; then
        printf '    VERDICT: OVERRUNS the device tree by %s -- this kernel will not boot\n' \
          "$(mib $(( -headroom )))"
      else
        printf '    VERDICT: fits, %s spare\n' "$(mib "$headroom")"
      fi
    else
      warn "could not read an arm64 Image header from $image"
    fi
  else
    warn "no readable ${BOOT_DIR}/Image to size-check"
  fi
  printf '\n'
}

backup_file() {
  local path="$1"
  [ -e "$path" ] || return 0
  cp -a "$path" "${path}.bak-loadaddr-${STAMP}" || die "could not back up $path"
  say "backed up $path to ${path}.bak-loadaddr-${STAMP}"
}

# Timestamped backups accumulate per run, so "newest" is not a safe revert
# source (a --revert backs up the *patched* files first, and a second --apply
# would back up an already-patched pair). The stock snapshot is written once,
# only from known-stock files, and never overwritten -- that is what a
# mkimage-less rescue revert restores from.
PRISTINE_SUFFIX=".stock-loadaddr"

save_pristine() {
  has_managed_block && return 0   # not stock; never overwrite a real snapshot
  # Belt and braces: a hand-stripped boot.cmd could carry raised addresses with
  # no marker, and snapshotting that as "stock" would poison every later revert.
  [ "$(current_addr fdt_addr_r "$STOCK_FDT_ADDR")" = "$STOCK_FDT_ADDR" ] || {
    warn "boot.cmd has no managed block but non-stock fdt_addr_r; not taking a stock snapshot"
    return 0
  }
  [ -e "${BOOT_CMD}${PRISTINE_SUFFIX}" ] || {
    cp -a "$BOOT_CMD" "${BOOT_CMD}${PRISTINE_SUFFIX}" \
      && say "saved stock snapshot ${BOOT_CMD}${PRISTINE_SUFFIX}"
  }
  [ -e "${BOOT_SCR}${PRISTINE_SUFFIX}" ] || [ ! -e "$BOOT_SCR" ] || {
    cp -a "$BOOT_SCR" "${BOOT_SCR}${PRISTINE_SUFFIX}" \
      && say "saved stock snapshot ${BOOT_SCR}${PRISTINE_SUFFIX}"
  }
}

strip_managed_block() {
  local file="$1" tmp
  tmp="$(mktemp)" || die "mktemp failed"
  # Also consumes the single blank line the block is padded with, so that
  # apply -> revert restores boot.cmd byte for byte.
  awk -v marker="$MARKER" '
    index($0, marker) && index($0, ">>>") { skip = 1; next }
    index($0, marker) && index($0, "<<<") { skip = 0; eat_blank = 1; next }
    skip { next }
    eat_blank { eat_blank = 0; if ($0 == "") next }
    { print }
  ' "$file" >"$tmp" || { rm -f "$tmp"; die "awk failed rewriting $file"; }
  cat "$tmp" >"$file" || die "could not write $file"
  rm -f "$tmp"
}

insert_managed_block() {
  local file="$1" tmp
  tmp="$(mktemp)" || die "mktemp failed"
  awk -v marker="$MARKER" \
      -v fdt="$NEW_FDT_ADDR" -v loadaddr="$NEW_LOAD_ADDR" -v ramdisk="$NEW_RAMDISK_ADDR" '
    !done && /^load .*uInitrd$/ {
      print "# >>> " marker
      print "# Raise the DT/initrd/scratch addresses out of the way of a large"
      print "# instrumented kernel expanding from kernel_addr_r. Revert with"
      print "# set-boot-load-addresses.sh --revert."
      print "setenv fdt_addr_r \"" fdt "\""
      print "setenv load_addr \"" loadaddr "\""
      print "setenv ramdisk_addr_r \"" ramdisk "\""
      print "# <<< " marker
      print ""
      done = 1
    }
    { print }
    END { if (!done) exit 3 }
  ' "$file" >"$tmp" || { rm -f "$tmp"; die "no 'load ... uInitrd' line in $file; refusing to guess an insertion point"; }
  cat "$tmp" >"$file" || die "could not write $file"
  rm -f "$tmp"
}

regenerate_scr() {
  # Same invocation boot.cmd documents at its own tail, so the generated header
  # matches the stock one (ARM Linux Script, empty image name).
  mkimage -C none -A arm -T script -d "$BOOT_CMD" "$BOOT_SCR" >/dev/null \
    || die "mkimage failed; $BOOT_SCR left as the backup copy"
  mkimage -l "$BOOT_SCR" | sed -n 's/^/    /p'
  say "regenerated $BOOT_SCR"
}

# Without mkimage (a bare rescue image), the stock snapshot taken at --apply is
# an exact pre-change copy -- restoring it is a complete revert on its own.
restore_scr_from_pristine() {
  local scr="${BOOT_SCR}${PRISTINE_SUFFIX}"
  [ -e "$scr" ] || die "mkimage not found and no stock snapshot at $scr.
  Boot.cmd has been reverted, but boot.scr is what U-Boot actually reads.
  Either install u-boot-tools on the rescue system and rerun --revert, or copy a
  known-good boot.scr into $BOOT_DIR."
  is_uimage "$scr" || die "$scr is not a U-Boot image; refusing to install it as boot.scr"
  warn "mkimage not found — restoring the stock snapshot instead of regenerating."
  cp -a "$scr" "$BOOT_SCR" || die "could not restore $BOOT_SCR"
  say "restored $BOOT_SCR from $(basename "$scr")"
  warn "boot.scr now reflects the stock boot.cmd; any *other* edits made to"
  warn "boot.cmd since then take effect only once you rerun with mkimage present."
}

install_self_to_boot() {
  local self="$1" dest
  dest="${BOOT_DIR}/$(basename "$0")"
  [ -r "$self" ] || return 0
  [ "$(readlink -f "$self")" = "$(readlink -f "$dest")" ] && return 0
  cp -a "$self" "$dest" 2>/dev/null \
    && say "installed a copy at $dest for rescue-boot reverts" \
    || warn "could not copy this script to $dest (revert from the repo path instead)"
}

# ---- run -------------------------------------------------------------------
say "target: $BOOT_DIR (on $(target_source))"
has_managed_block && say "managed block: present" || say "managed block: absent (stock addresses)"
if [ -e "${BOOT_SCR}${PRISTINE_SUFFIX}" ]; then
  say "stock snapshot: present — a rescue --revert works even without mkimage"
else
  say "stock snapshot: absent — a rescue --revert would need mkimage (u-boot-tools)"
fi

if [ "$MODE" = "check" ]; then
  report
  exit 0
fi

if [ ! -w "$BOOT_CMD" ] || [ ! -w "$BOOT_DIR" ]; then
  [ "$(id -u)" = 0 ] && die "$BOOT_DIR is not writable (read-only mount?)"
  exec sudo BOOT_DIR="$BOOT_DIR" bash "$0" "$@"
fi

say "before:"
report

confirm "$MODE the raised load-address map on $BOOT_DIR ($(target_source))?" \
  || die "aborted; nothing changed"

STAMP="$(date +%Y%m%d-%H%M%S)"
backup_file "$BOOT_CMD"
backup_file "$BOOT_SCR"

case "$MODE" in
  apply)
    have mkimage || die "mkimage not found — apply needs it (apt install u-boot-tools)"
    # Only --apply may take the snapshot: it is the one moment the files are
    # known-stock. Letting --revert take one would let it invent a "stock"
    # snapshot out of the patched files it is supposed to be undoing.
    save_pristine
    strip_managed_block "$BOOT_CMD"
    insert_managed_block "$BOOT_CMD"
    regenerate_scr
    install_self_to_boot "$0"
    ;;
  revert)
    has_managed_block || warn "no managed block found; reverting to stock boot.scr anyway"
    strip_managed_block "$BOOT_CMD"
    if have mkimage; then
      regenerate_scr
    else
      restore_scr_from_pristine
    fi
    ;;
esac

say "after:"
report

if [ "$MODE" = "apply" ]; then
  cat <<EOF
Takes effect at the next boot only. Before rebooting into a debug kernel:
  - keep rescue media reachable; from an SD rescue boot, recover with
      sudo bash set-boot-load-addresses.sh --auto --revert
    or against a root you mounted yourself:
      sudo bash /mnt/nvme/boot/set-boot-load-addresses.sh --root /mnt/nvme --revert
  - a serial console on UART2 (console=ttyS2,1500000 is already in the boot
    args) is the only thing that shows early-boot failures here -- ramoops
    cannot help, RK3588 discards the region on reset.
EOF
fi
