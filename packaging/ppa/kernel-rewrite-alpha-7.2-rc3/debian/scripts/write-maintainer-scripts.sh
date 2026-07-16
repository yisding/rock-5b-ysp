#!/usr/bin/env bash
set -euo pipefail

release="${1:?release}"
image_pkg="${2:?image package}"
dtb_pkg="${3:?dtb package}"
headers_pkg="${4:?headers package}"
arch="${5:?arch}"

write_common_header() {
	local package="$1"
	local script="$2"
	cat <<EOF
#!/bin/bash
echo "YSP '${package}' for '${release}': '${script}' starting."
set -e

is_boot_dev_vfat() {
	if [[ "\${ARMBIAN_IMAGE_BUILD_BOOTFS_TYPE:-unknown}" == "fat" ]]; then
		echo "YSP: ARMBIAN_IMAGE_BUILD_BOOTFS_TYPE: '\${ARMBIAN_IMAGE_BUILD_BOOTFS_TYPE:-not set}'"
		return 0
	fi
	if ! mountpoint -q /boot; then
		return 1
	fi
	local boot_partition bootfstype
	boot_partition=\$(findmnt --nofsroot -n -o SOURCE /boot)
	bootfstype=\$(blkid -s TYPE -o value "\$boot_partition")
	[[ "\$bootfstype" == "vfat" ]]
}

EOF
}

finish_script() {
	local package="$1"
	local script="$2"
	cat <<EOF

echo "YSP '${package}' for '${release}': '${script}' finishing."
true
EOF
}

write_image_script() {
	local script="$1"
	local path="debian/${image_pkg}.${script}"
	write_common_header "$image_pkg" "$script" > "$path"
	cat >> "$path" <<EOF
export DEB_MAINT_PARAMS="\$*"
export INITRD=Yes
test -d /etc/kernel/${script}.d && run-parts --arg="${release}" --arg="/boot/vmlinuz-${release}" /etc/kernel/${script}.d
EOF
	if [[ "$script" == "preinst" ]]; then
		cat >> "$path" <<'EOF'
if is_boot_dev_vfat; then
	rm -f /boot/System.map* /boot/config* /boot/vmlinuz* /boot/Image /boot/uImage
fi
EOF
	fi
	if [[ "$script" == "postinst" ]]; then
		cat >> "$path" <<EOF
touch /boot/.next
if is_boot_dev_vfat; then
	echo "YSP: FAT32 /boot: move last-installed kernel to 'Image'..."
	mv -v /boot/vmlinuz-${release} /boot/Image
else
	echo "YSP: update last-installed kernel symlink to 'Image'..."
	ln -sfv vmlinuz-${release} /boot/Image
fi
if ! is_boot_dev_vfat; then
	echo "YSP: Debian compat: linux-update-symlinks install ${release} boot/vmlinuz-${release}"
	linux-update-symlinks install "${release}" "boot/vmlinuz-${release}" || true
fi
EOF
	fi
	finish_script "$image_pkg" "$script" >> "$path"
	chmod 0755 "$path"
}

write_dtb_script() {
	local script="$1"
	local path="debian/${dtb_pkg}.${script}"
	write_common_header "$dtb_pkg" "$script" > "$path"
	if [[ "$script" == "preinst" ]]; then
		cat >> "$path" <<EOF
rm -rf /boot/dtb
rm -rf /boot/dtb-${release}
EOF
	elif [[ "$script" == "postinst" ]]; then
		cat >> "$path" <<EOF
cd /boot
if ! is_boot_dev_vfat; then
	echo "YSP: DTB: symlinking /boot/dtb to /boot/dtb-${release}..."
	ln -sfTv "dtb-${release}" dtb
else
	echo "YSP: DTB: FAT32: moving /boot/dtb-${release} to /boot/dtb ..."
	mv -v "dtb-${release}" dtb
fi
EOF
	fi
	finish_script "$dtb_pkg" "$script" >> "$path"
	chmod 0755 "$path"
}

write_headers_script() {
	local script="$1"
	local path="debian/${headers_pkg}.${script}"
	write_common_header "$headers_pkg" "$script" > "$path"
	if [[ "$script" == "preinst" || "$script" == "prerm" ]]; then
		cat >> "$path" <<EOF
if [[ -d "/usr/src/linux-headers-${release}" ]]; then
	echo "Cleaning directory /usr/src/linux-headers-${release} ..."
	rm -rf "/usr/src/linux-headers-${release}"
fi
EOF
	elif [[ "$script" == "postinst" ]]; then
		local src_arch="$arch"
		case "$src_arch" in
			amd64) src_arch="x86" ;;
			armhf) src_arch="arm" ;;
			riscv64) src_arch="riscv" ;;
			loong64) src_arch="loongarch" ;;
		esac
		cat >> "$path" <<EOF
cd "/usr/src/linux-headers-${release}"
NCPU=\$(grep -c 'processor' /proc/cpuinfo 2>/dev/null || echo 1)
echo "Configuring kernel headers (${release}) ..."
make ARCH="${src_arch}" olddefconfig
echo "Compiling kernel header scripts (${release}) ..."
make ARCH="${src_arch}" -j"\$NCPU" scripts
make ARCH="${src_arch}" -j"\$NCPU" M=scripts/mod
make ARCH="${src_arch}" -j"\$NCPU" tools/bpf/resolve_btfids || true
if [[ -f include/generated/.armbian-build.tar.gz ]]; then
	tar -C . -xzf include/generated/.armbian-build.tar.gz
	rm -f include/generated/.armbian-build.tar.gz
fi
EOF
	fi
	finish_script "$headers_pkg" "$script" >> "$path"
	chmod 0755 "$path"
}

for script in postinst postrm preinst prerm; do
	write_image_script "$script"
done
for script in preinst postinst; do
	write_dtb_script "$script"
done
for script in preinst postinst prerm; do
	write_headers_script "$script"
done
