#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail

root="${1:?root}"
release="${2:?release}"
image_pkg="${3:?image package}"
dtb_pkg="${4:?dtb package}"
headers_pkg="${5:?headers package}"
arch="${6:?arch}"
localversion="${7:?localversion}"
build_root="${8:-$root}"
kernel_source="${9:-$root}"

image_dir="$root/debian/$image_pkg"
dtb_dir="$root/debian/$dtb_pkg"
headers_dir="$root/debian/$headers_pkg"
headers_target="$headers_dir/usr/src/linux-headers-$release"
modules_target="$headers_dir/lib/modules/$release"

src_arch="$arch"
case "$src_arch" in
	amd64) src_arch="x86" ;;
	armhf) src_arch="arm" ;;
	riscv64) src_arch="riscv" ;;
	loong64) src_arch="loongarch" ;;
esac

kernel_make() {
	if [[ "$build_root" == "$kernel_source" ]]; then
		make -C "$kernel_source" ARCH="$arch" LOCALVERSION="$localversion" "$@"
	else
		make -C "$kernel_source" O="$build_root" ARCH="$arch" \
			LOCALVERSION="$localversion" "$@"
	fi
}

install_image_package() {
	local module_dir="$image_dir/lib/modules/$release"

	install -d "$image_dir/boot" "$image_dir/usr/lib" \
		"$image_dir/etc/kernel/postinst.d" "$image_dir/etc/kernel/postrm.d" \
		"$image_dir/etc/kernel/preinst.d" "$image_dir/etc/kernel/prerm.d"

	install -m 0644 "$build_root/arch/arm64/boot/Image" "$image_dir/boot/vmlinuz-$release"
	install -m 0644 "$build_root/System.map" "$image_dir/boot/System.map-$release"
	install -m 0644 "$build_root/.config" "$image_dir/boot/config-$release"

	kernel_make modules_install INSTALL_MOD_PATH="$image_dir" INSTALL_MOD_STRIP=1 DEPMOD=true
	rm -f "$module_dir/build" "$module_dir/source"
	if command -v depmod >/dev/null 2>&1; then
		depmod -b "$image_dir" "$release" || true
	fi

	kernel_make dtbs_install INSTALL_DTBS_PATH="$image_dir/usr/lib/linux-image-$release"
}

install_dtb_package() {
	install -d "$dtb_dir/boot"
	cp -a "$image_dir/usr/lib/linux-image-$release" "$dtb_dir/boot/dtb-$release"
}

copy_headers_file_list() {
	local list="$1"

	: > "$list"
	find . \( -name 'Makefile*' -o -name 'Kconfig*' -o -name '*.pl' \) -print >> "$list"
	find arch/*/include include scripts \( -type f -o -type l \) -print >> "$list"
	[ ! -d security ] || find security/*/include -type f -print >> "$list" 2>/dev/null || true
	if [ -d "arch/$src_arch" ]; then
		find "arch/$src_arch" \( -name module.lds -o -name Kbuild.platforms -o -name Platform \) -print >> "$list"
		find "arch/$src_arch" \( -name include -o -name scripts \) -type d -print |
			while IFS= read -r dir; do
				find "$dir" -type f -print
			done >> "$list"
	fi
	[ ! -f Module.symvers ] || printf '%s\n' Module.symvers >> "$list"
	find include scripts \( -type f -o -type l \) -print >> "$list"
	find . -name bitsperlong.h -type f -print >> "$list"
	[ ! -d tools ] || find tools -type f -print >> "$list"
	[ ! -f arch/x86/lib/insn.c ] || printf '%s\n' arch/x86/lib/insn.c >> "$list"

	sort -u "$list" -o "$list"
}

install_headers_package() {
	local file_list
	file_list="$(mktemp)"
	trap 'rm -f "$file_list"' RETURN

	install -d "$headers_target" "$modules_target"
	ln -s "/usr/src/linux-headers-$release" "$modules_target/build"
	install -m 0644 "$build_root/.config" "$headers_target/.config"

	(
		cd "$root"
		copy_headers_file_list "$file_list"
		tar -c -f - -T "$file_list"
	) | tar -x -f - -C "$headers_target"

	[[ ! -f "$build_root/Module.symvers" ]] || \
		install -m 0644 "$build_root/Module.symvers" "$headers_target/Module.symvers"

	if [ ! -f "$headers_target/tools/vm/Makefile" ]; then
		install -d "$headers_target/tools/vm"
		printf 'clean:\n\t@echo fake clean for tools/vm\n' > "$headers_target/tools/vm/Makefile"
	fi
	install -d "$headers_target/tools/counter/include/linux"

	make -C "$headers_target" ARCH="$src_arch" M=scripts clean >/dev/null 2>&1 ||
		make -C "$headers_target" ARCH="$src_arch" M=scripts clean
	if [ -d "$headers_target/tools" ]; then
		make -C "$headers_target/tools" ARCH="$src_arch" VMLINUX_BTF="$build_root/vmlinux" clean >/dev/null 2>&1 ||
			make -C "$headers_target/tools" ARCH="$src_arch" VMLINUX_BTF="$build_root/vmlinux" clean || true
	fi

	rm -rf "$headers_target/tools/perf" "$headers_target/tools/testing"

	# Header cleanup can remove architecture-selected static headers along with
	# generated files. Restore the immutable source headers, then overlay the
	# generated headers from the exact object tree used to build this release.
	cp -a "$root/include/." "$headers_target/include/"
	cp -a "$root/arch/$src_arch/include/." \
		"$headers_target/arch/$src_arch/include/"
	for generated_path in include/config include/generated "arch/$src_arch/include/generated"; do
		if [[ -e "$build_root/$generated_path" ]]; then
			install -d "$headers_target/$(dirname "$generated_path")"
			cp -a "$build_root/$generated_path" \
				"$headers_target/$(dirname "$generated_path")/"
		fi
	done
	[ ! -f "$build_root/scripts/module.lds" ] || \
		install -m 0644 "$build_root/scripts/module.lds" "$headers_target/scripts/module.lds"

	if [ -f "$build_root/include/config/auto.conf" ]; then
		install -d "$headers_target/include/generated"
		sidecar_paths=(include/config)
		[ ! -f "$build_root/include/generated/autoconf.h" ] || sidecar_paths+=(include/generated/autoconf.h)
		[ ! -f "$build_root/include/generated/rustc_cfg" ] || sidecar_paths+=(include/generated/rustc_cfg)
		tar -C "$build_root" -czf "$headers_target/include/generated/.armbian-build.tar.gz" \
			"${sidecar_paths[@]}"
	fi
}

install_image_package
install_dtb_package
install_headers_package
