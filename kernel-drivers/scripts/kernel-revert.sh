#!/usr/bin/env bash
# =============================================================================
# kernel-revert.sh  —  get a Rock 5B booting again after a bad kernel install
#
# Armbian on the Rock 5B boots via U-Boot + boot.scr, which loads whatever these
# symlinks point at (there is NO boot menu):
#     /boot/Image     -> vmlinuz-<ver>
#     /boot/uInitrd   -> uInitrd-<ver>
#     /boot/dtb       -> dtb-<ver>/        (+ fdtfile= in armbianEnv.txt)
# So reverting a kernel = repoint those symlinks to a known-good <ver>, OR
# reinstall a good kernel .deb (needed when the bad build shares the version
# string and overwrote the good files -- see THE CLOBBER GOTCHA below).
#
# Meant to be run from an SD-card rescue boot, operating on the INTERNAL disk;
# also works live (sudo, on '/') to flip back to another installed kernel.
#
# THE CLOBBER GOTCHA
#   Our AV1 build (kernel-drivers/scripts/build-armbian-deb.sh) keeps the exact kernel
#   version "6.18.37-current-rockchip64", so `dpkg -i` OVERWRITES the shipping
#   kernel's vmlinuz/dtb/modules. After that, `switch` can only reach a *different*
#   version (e.g. 7.1.0-edge, 6.1.115-vendor). To get the shipping 6.18.37 back you
#   must `reinstall` its .deb (kept in armbian-build/output/debs, e.g. the
#   Pb6ab-Cb831 set). Keep the last-known-good deb around for exactly this.
#
# USAGE
#   sudo bash kernel-revert.sh [TARGET] <command>
#
#   TARGET (default: the live root '/'):
#     --auto            auto-detect the internal Armbian root (ext4 with
#                       /boot/armbianEnv.txt), excluding the device you booted from
#     --device PART     mount PART rw and operate on it (e.g. /dev/nvme0n1p1)
#     --root DIR        operate on an already-mounted target root at DIR
#
#   commands:
#     list                       show kernels in the target /boot + the active one
#     switch [VERSION]           repoint the boot symlinks to VERSION
#                                (interactive picker if VERSION omitted)
#     reinstall DEB [DEB...]     dpkg -i the given kernel deb(s) into the target
#                                (chroots when the target isn't '/'); regenerates
#                                initramfs + symlinks properly. Fixes the clobber.
#
#   --yes    don't prompt for confirmation
#
# EXAMPLES
#   # From an SD rescue: see what's on the internal disk, then boot edge instead:
#   sudo bash kernel-revert.sh --auto list
#   sudo bash kernel-revert.sh --auto switch 7.1.0-edge-rockchip64
#   # Put the known-good shipping 6.18.37 back (clobber case):
#   sudo bash kernel-revert.sh --device /dev/nvme0n1p1 reinstall \
#        /mnt/build/output/debs/linux-image-current-rockchip64_*Pb6ab-Cb831*.deb \
#        /mnt/build/output/debs/linux-dtb-current-rockchip64_*Pb6ab-Cb831*.deb
# =============================================================================
set -uo pipefail

say()  { printf '>>> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ---- parse args ------------------------------------------------------------
TGT_MODE="live"; DEVICE=""; ROOT_DIR="/"; ASSUME_YES=0
CMD=""; CMDARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --auto)    TGT_MODE="auto"; shift ;;
    --device)  TGT_MODE="device"; DEVICE="${2:?--device needs a partition}"; shift 2 ;;
    --root)    TGT_MODE="root"; ROOT_DIR="${2:?--root needs a dir}"; shift 2 ;;
    --yes|-y)  ASSUME_YES=1; shift ;;
    -h|--help) sed -n '2,52p' "$0"; exit 0 ;;
    list|switch|reinstall) CMD="$1"; shift; CMDARGS=("$@"); break ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done
[ -n "$CMD" ] || die "no command given (list | switch | reinstall). See --help."
[ "$(id -u)" = 0 ] || die "run as root:  sudo bash $0 ..."

# ---- resolve + mount the target root --------------------------------------
UMOUNT_ROOT=""; BIND_MOUNTS=()
cleanup() {
  for m in "${BIND_MOUNTS[@]}"; do umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || true; done
  [ -n "$UMOUNT_ROOT" ] && { sync; umount "$UMOUNT_ROOT" 2>/dev/null || umount -l "$UMOUNT_ROOT" 2>/dev/null || true; rmdir "$UMOUNT_ROOT" 2>/dev/null || true; }
}
trap cleanup EXIT

mount_dev() {  # $1 = partition -> sets ROOT_DIR, UMOUNT_ROOT
  local part="$1" mnt
  [ -b "$part" ] || die "not a block device: $part"
  mnt="$(mktemp -d /tmp/krevert.XXXXXX)"
  mount "$part" "$mnt" || die "could not mount $part"
  ROOT_DIR="$mnt"; UMOUNT_ROOT="$mnt"
  say "mounted $part at $mnt"
}

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
      m="$(mktemp -d /tmp/kprobe.XXXXXX)"
      if mount -o ro "$p" "$m" 2>/dev/null; then
        [ -f "$m/boot/armbianEnv.txt" ] && found="$p"
        umount "$m" 2>/dev/null || true
      fi
      rmdir "$m" 2>/dev/null || true
      [ -n "$found" ] && break
    done
    [ -n "$found" ] || die "auto-detect found no internal Armbian root (ext4 with /boot/armbianEnv.txt). Use --device."
    say "auto-detected internal root: $found"
    mount_dev "$found"
    ;;
esac

BOOT="$ROOT_DIR/boot"
[ -d "$BOOT" ] || die "no /boot under target ($BOOT)"
[ -f "$BOOT/armbianEnv.txt" ] || warn "no armbianEnv.txt in $BOOT — is this an Armbian root?"

active_ver() { readlink "$BOOT/Image" 2>/dev/null | sed 's/^vmlinuz-//'; }
list_versions() { ls "$BOOT"/vmlinuz-* 2>/dev/null | sed 's#.*/vmlinuz-##' | sort; }

confirm() {  # $1 = prompt
  [ "$ASSUME_YES" = 1 ] && return 0
  local a; printf '%s [y/N] ' "$1" > /dev/tty
  read -r a < /dev/tty; [ "$a" = y ] || [ "$a" = Y ]
}

# ---- commands --------------------------------------------------------------
cmd_list() {
  local act; act="$(active_ver)"
  say "target root: $ROOT_DIR   (active kernel: ${act:-<none>})"
  printf '  %-40s %-8s %-8s %-8s %s\n' KERNEL vmlinuz uInitrd dtb-dir active
  local v
  for v in $(list_versions); do
    printf '  %-40s %-8s %-8s %-8s %s\n' "$v" \
      "$([ -e "$BOOT/vmlinuz-$v" ] && echo yes || echo NO)" \
      "$([ -e "$BOOT/uInitrd-$v" ] && echo yes || echo no)" \
      "$([ -d "$BOOT/dtb-$v" ] && echo yes || echo no)" \
      "$([ "$v" = "$act" ] && echo '  <== active' || echo '')"
  done
  local fdt; fdt="$(grep -E '^fdtfile=' "$BOOT/armbianEnv.txt" 2>/dev/null | cut -d= -f2)"
  [ -n "$fdt" ] && say "armbianEnv fdtfile: $fdt"
}

cmd_switch() {
  local v="${1:-}"
  if [ -z "$v" ]; then
    say "kernels available in $BOOT:"; local i=0; local -a opts=()
    while read -r k; do i=$((i+1)); opts+=("$k"); printf '   %d) %s%s\n' "$i" "$k" \
      "$([ "$k" = "$(active_ver)" ] && echo '  (active)')"; done < <(list_versions)
    [ "$i" -gt 0 ] || die "no vmlinuz-* kernels found in $BOOT"
    printf 'pick a kernel to boot [1-%d]: ' "$i" > /dev/tty; local n; read -r n < /dev/tty
    [ "$n" -ge 1 ] 2>/dev/null && [ "$n" -le "$i" ] || die "invalid choice"
    v="${opts[$((n-1))]}"
  fi
  [ -e "$BOOT/vmlinuz-$v" ] || die "no vmlinuz-$v in $BOOT (see 'list')"
  [ -e "$BOOT/uInitrd-$v" ] || warn "no uInitrd-$v — boot may fail without an initrd"
  [ -d "$BOOT/dtb-$v" ]     || warn "no dtb-$v/ directory — DT load may fail"
  # fdtfile sanity: the board dtb must exist under the new dtb dir
  local fdt; fdt="$(grep -E '^fdtfile=' "$BOOT/armbianEnv.txt" 2>/dev/null | cut -d= -f2)"
  if [ -n "$fdt" ] && [ ! -e "$BOOT/dtb-$v/$fdt" ]; then
    warn "armbianEnv fdtfile '$fdt' not found under dtb-$v/ — the target kernel may use a different DT layout"
  fi
  say "will switch active kernel: $(active_ver) -> $v   (target $ROOT_DIR)"
  confirm "repoint /boot symlinks?" || die "aborted"
  ln -sfn "vmlinuz-$v" "$BOOT/Image"
  ln -sfn "vmlinuz-$v" "$BOOT/vmlinuz"
  [ -e "$BOOT/uInitrd-$v" ]    && ln -sfn "uInitrd-$v"    "$BOOT/uInitrd"
  [ -e "$BOOT/initrd.img-$v" ] && ln -sfn "initrd.img-$v" "$BOOT/initrd.img"
  [ -d "$BOOT/dtb-$v" ]        && ln -sfn "dtb-$v"        "$BOOT/dtb"
  sync
  say "done. Active kernel is now: $(active_ver). Remove the SD and boot the internal disk."
}

cmd_reinstall() {
  [ "$#" -ge 1 ] || die "reinstall needs at least one .deb"
  local d; for d in "$@"; do [ -f "$d" ] || die "not a file: $d"; done
  say "will dpkg -i into $ROOT_DIR:"; printf '   %s\n' "$@"
  confirm "reinstall these kernel deb(s)?" || die "aborted"
  if [ "$ROOT_DIR" = "/" ]; then
    dpkg -i "$@" || die "dpkg failed"
  else
    # chroot install: needs /proc /sys /dev bind-mounted (native arm64-on-arm64)
    local stage="$ROOT_DIR/var/tmp/kernel-revert"; mkdir -p "$stage"
    cp -v "$@" "$stage/"
    local mp; for mp in proc sys dev dev/pts; do
      mkdir -p "$ROOT_DIR/$mp"; mount --bind "/$mp" "$ROOT_DIR/$mp" && BIND_MOUNTS=("$ROOT_DIR/$mp" "${BIND_MOUNTS[@]}")
    done
    chroot "$ROOT_DIR" /bin/bash -c 'dpkg -i /var/tmp/kernel-revert/*.deb' || die "chroot dpkg failed"
    rm -rf "$stage"
    sync
  fi
  say "done. Active kernel is now: $(active_ver)."
}

case "$CMD" in
  list)      cmd_list ;;
  switch)    cmd_switch "${CMDARGS[@]}" ;;
  reinstall) cmd_reinstall "${CMDARGS[@]}" ;;
  *)         die "unknown command: $CMD" ;;
esac
