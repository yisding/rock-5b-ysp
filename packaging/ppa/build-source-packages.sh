#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROCK5B_WORKSPACE="${ROCK5B_WORKSPACE:-$ROOT/../rock-5b}"
WORKSPACE_ROOT="$(cd "${WORKSPACE_ROOT:-$ROCK5B_WORKSPACE}" && pwd)"
OUT="${OUT:-$ROOT/packaging/ppa/out}"
WORK="$OUT/work"
ARTIFACTS="$OUT/artifacts"

MPP_REPO="${MPP_REPO:-$WORKSPACE_ROOT/rockchip-userspace/mpp-rockchip}"
# Fork-branch model: MPP_COMMIT is the tip of branch ysp/main on yisding/mpp,
# NOT a pristine upstream commit. debian/patches/ is gone; the delta is the
# commits between upstream tag 1.0.12 (1375813c) and this tip. The working tree
# above is the HermanChen/mpp vendor mirror with a `yisding` remote added --
# push ysp work to `yisding`, never to `origin`.
MPP_COMMIT="${MPP_COMMIT:-3381fd2c}"
MPP_UPSTREAM_VERSION="${MPP_UPSTREAM_VERSION:-1.5.0+git20260729.3381fd2c+ds}"

LIBRGA_REPO="${LIBRGA_REPO:-$WORKSPACE_ROOT/rockchip-userspace/librga-fork}"
# Must track the tip that matches the shipped kernel's 10-bit stride convention.
# This defaulted to a632217 long after c80eea7/b8def3e/4c26ddf moved 10-bit vir_w
# to a byte stride to match kernel 0072/0074, so the documented build command
# produced the exact mismatched pair this tree warns about -- silent wrong chroma
# on the 10-bit path, not an error. Kernel and librga ship together for 10-bit.
LIBRGA_COMMIT="${LIBRGA_COMMIT:-26a50ef}"
LIBRGA_UPSTREAM_VERSION="${LIBRGA_UPSTREAM_VERSION:-2.2.0+git20260725.26a50ef}"

FFMPEG_REPO="${FFMPEG_REPO:-$WORKSPACE_ROOT/ffmpeg/ffmpeg-rockchip-81}"
FFMPEG_COMMIT="${FFMPEG_COMMIT:-33a651a55ba62d29d9474d236ceb9240043da518}"
FFMPEG_UPSTREAM_VERSION="${FFMPEG_UPSTREAM_VERSION:-8.0.3+rockchip+git20260729.33a651a55b}"

FFMPEG_ROCKCHIP_REPO="${FFMPEG_ROCKCHIP_REPO:-$WORKSPACE_ROOT/ffmpeg/ffmpeg-rockchip}"
FFMPEG_ROCKCHIP_COMMIT="${FFMPEG_ROCKCHIP_COMMIT:-40c412daccf08164493da0de990eb99a8948116b}"
FFMPEG_ROCKCHIP_UPSTREAM_VERSION="${FFMPEG_ROCKCHIP_UPSTREAM_VERSION:-6.1+git20260423.40c412dacc}"

GRD_REPO="${GRD_REPO:-$WORKSPACE_ROOT/gnome/grd/gnome-remote-desktop}"
GRD_COMMIT="${GRD_COMMIT:-24f4392bb0daa40b9c411de1b1bcb9d0078e506a}"
GRD_UPSTREAM_VERSION="${GRD_UPSTREAM_VERSION:-50.2+rkmpp+git20260729.14.24f4392}"
GRD_DELTA="${GRD_DELTA:-}"

KERNEL_PPA_SOURCE="${KERNEL_PPA_SOURCE:-linux-rockchip64-ysp}"
KERNEL_PPA_REPO="${KERNEL_PPA_REPO:-$WORKSPACE_ROOT/kernel/rock5b-kernel-build/armbian-build/cache/sources/linux-kernel-worktree/6.18__rockchip64__arm64}"
KERNEL_PPA_CONFIG="${KERNEL_PPA_CONFIG:-$ROOT/packaging/ppa/kernel-forward-port/debian/config/arm64-rockchip64.config}"
KERNEL_PPA_UPSTREAM_VERSION="${KERNEL_PPA_UPSTREAM_VERSION:-6.18.40+rk3588av1fwport20260729}"

KERNEL_SGGUARD_SOURCE="${KERNEL_SGGUARD_SOURCE:-linux-rockchip64-ysp-sgguard}"
# Diagnostic variant of the forward-port kernel: same worktree, same production
# config, plus the temporary system-heap page_link guard commit. Built through
# the PPA so Launchpad's gcc 15.2 compiles it, matching the production kernel's
# toolchain -- local Armbian builds use gcc 13.3. Drop once the writer is found.
KERNEL_SGGUARD_CONFIG="${KERNEL_SGGUARD_CONFIG:-$ROOT/packaging/ppa/kernel-forward-port/debian/config/arm64-rockchip64.config}"
KERNEL_SGGUARD_UPSTREAM_VERSION="${KERNEL_SGGUARD_UPSTREAM_VERSION:-6.18.40+rk3588av1fwport20260725sgguard1}"

KERNEL_ALPHA_618_SOURCE="${KERNEL_ALPHA_618_SOURCE:-linux-rockchip64-ysp-alpha-6.18}"
KERNEL_ALPHA_618_REPO="${KERNEL_ALPHA_618_REPO:-$WORKSPACE_ROOT/kernel/linux-6.18-rkvenc}"
KERNEL_ALPHA_618_COMMIT="${KERNEL_ALPHA_618_COMMIT:-8daf5e9513b8aa9de018dad7754b6efacfd0fd49}"
KERNEL_ALPHA_618_UPSTREAM_VERSION="${KERNEL_ALPHA_618_UPSTREAM_VERSION:-6.18.38+rk3588rewritealpha20260715}"

KERNEL_ALPHA_72RC3_SOURCE="${KERNEL_ALPHA_72RC3_SOURCE:-linux-rockchip64-ysp-alpha-7.2-rc3}"
KERNEL_ALPHA_72RC3_REPO="${KERNEL_ALPHA_72RC3_REPO:-$WORKSPACE_ROOT/kernel/linux}"
KERNEL_ALPHA_72RC3_COMMIT="${KERNEL_ALPHA_72RC3_COMMIT:-24f7424fb9589ea2118127084a5f2748aa762b63}"
KERNEL_ALPHA_72RC3_UPSTREAM_VERSION="${KERNEL_ALPHA_72RC3_UPSTREAM_VERSION:-7.2.0~rc3+rk3588rewritealpha20260715}"

KERNEL_ALPHA_72RC5_SOURCE="${KERNEL_ALPHA_72RC5_SOURCE:-linux-rockchip64-ysp-alpha-7.2-rc5}"
KERNEL_ALPHA_72RC5_REPO="${KERNEL_ALPHA_72RC5_REPO:-$WORKSPACE_ROOT/kernel/linux}"
KERNEL_ALPHA_72RC5_COMMIT="${KERNEL_ALPHA_72RC5_COMMIT:-876f5583d65754b28beff1b364e305746c107a6e}"
KERNEL_ALPHA_72RC5_UPSTREAM_VERSION="${KERNEL_ALPHA_72RC5_UPSTREAM_VERSION:-7.2.0~rc5+rk3588rewritealpha20260729}"

GDM_HWENC_SOURCE="${GDM_HWENC_SOURCE:-gnome-remote-desktop-gdm-hwenc}"
GDM_HWENC_VERSION="${GDM_HWENC_VERSION:-1.0}"
GDM_HWENC_RULE="${GDM_HWENC_RULE:-$ROOT/packaging/gdm-hwenc/root/usr/lib/udev/rules.d/70-gnome-remote-desktop-gdm-hwenc.rules}"

CODEC_UDEV_SOURCE="${CODEC_UDEV_SOURCE:-rk3588-codec-udev}"
CODEC_UDEV_VERSION="${CODEC_UDEV_VERSION:-1.1}"
CODEC_UDEV_RULE="${CODEC_UDEV_RULE:-$ROOT/kernel-drivers/scripts/99-rockchip-codec.rules}"

usage() {
    cat <<'USAGE'
Usage: build-source-packages.sh [mpp] [librga] [ffmpeg] [ffmpeg-rockchip] [gnome-remote-desktop|grd] [plymouth] [codec-udev] [gdm-hwenc] [kernel] [kernel-sgguard] [kernel-alpha-6.18] [kernel-alpha-7.2-rc3] [kernel-alpha-7.2-rc5]

Build unsigned source packages for the Rock 5B PPAs.
Artifacts are written under packaging/ppa/out/artifacts by default.
Set OUT=/path/to/output to use a different output root.

Existing orig tarballs in the artifacts directory are reused by default, which
is required when uploading a new Debian revision for an upstream version that
Launchpad has already accepted. Set FORCE_ORIG=1 to regenerate an orig tarball.

Source tree defaults are resolved below WORKSPACE_ROOT, which defaults to
ROCK5B_WORKSPACE; ROCK5B_WORKSPACE defaults to the sibling rock-5b directory.
Override the grouped root, the packaging-only root, or use MPP_REPO,
LIBRGA_REPO, FFMPEG_REPO, FFMPEG_ROCKCHIP_REPO, GRD_REPO, and the matching
*_COMMIT / *_UPSTREAM_VERSION variables. The default GRD snapshot is the cleaned release
branch: RKMPP backend, reconnect fixes, cached readback, bounded encode recovery,
and progress-gated frame-ack recovery. It contains no investigation diagnostics
and applies no source delta. GRD_DELTA remains available for reconstructing a
historical package; multiple patch paths are colon-separated and applied in
order.

The forward-port kernel target exports the already-patched Armbian kernel
worktree named by KERNEL_PPA_REPO, excluding build products and .git, then
overlays packaging/ppa/kernel-forward-port/debian. By default it uses the
tracked production config in that packaging directory, not the transient
worktree .config, which may belong to the last debug build. It is intentionally
not part of the no-argument default set because the orig tarball is large.

The alpha rewrite kernel targets archive the pinned Armbian-plus-rewrite kernel
commits from KERNEL_ALPHA_618_REPO and KERNEL_ALPHA_72RC3_REPO, then
overlay packaging/ppa/kernel-rewrite-alpha-6.18/debian and
packaging/ppa/kernel-rewrite-alpha-7.2-rc3/debian respectively. They are also
large and intentionally excluded from the no-argument default set.

The codec-udev and gdm-hwenc targets create small native source packages and
copy their canonical rules into the generated source trees at export time.

The plymouth target delegates to its package-specific helper, which downloads
and verifies Ubuntu Resolute's exact source package before applying the tracked
one-patch backport. It is not part of the default set.
USAGE
}

assert_orig_matches_source() {
    local orig="$1"
    local source_tree="$2"
    local compare_dir
    local unpacked
    compare_dir="$WORK/orig-compare-$(basename "$source_tree")"
    unpacked="$compare_dir/$(basename "$source_tree")"

    rm -rf "$compare_dir"
    mkdir -p "$compare_dir"
    tar -C "$compare_dir" -xzf "$orig"

    if [[ ! -d "$unpacked" ]]; then
        echo "unexpected orig tarball layout: $orig" >&2
        rm -rf "$compare_dir"
        return 1
    fi

    if ! diff -qr "$source_tree" "$unpacked" >/dev/null; then
        echo "existing orig tarball does not match exported source: $orig" >&2
        diff -qr "$source_tree" "$unpacked" >&2 || true
        rm -rf "$compare_dir"
        return 1
    fi

    rm -rf "$compare_dir"
}

prepare_source() {
    local source="$1"
    local repo="$2"
    local commit="$3"
    local upstream_version="$4"
    local packaging_dir="$5"
    shift 5
    local -a patch_files=()
    while [[ "${1:-}" == "--patch" ]]; do
        patch_files+=("$2")
        shift 2
    done
    local excludes=("$@")
    local source_dir="$WORK/${source}-${upstream_version}"
    local upstream_tmp="$WORK/upstream-${source}"
    local orig_name="${source}_${upstream_version}.orig.tar.gz"
    local orig="$WORK/$orig_name"
    local artifact_orig="$ARTIFACTS/$orig_name"
    local force_orig="${FORCE_ORIG:-0}"

    rm -rf "$source_dir" "$upstream_tmp"
    mkdir -p "$upstream_tmp"

    git -C "$repo" archive --format=tar --prefix="${source}-${upstream_version}/" "$commit" \
        | tar -C "$upstream_tmp" -xf -

    rm -rf "$upstream_tmp/${source}-${upstream_version}/debian"
    local exclude
    for exclude in "${excludes[@]}"; do
        rm -rf "$upstream_tmp/${source}-${upstream_version}/$exclude"
    done
    local patch_file
    for patch_file in "${patch_files[@]}"; do
        if [[ "$patch_file" != /* ]]; then
            patch_file="$ROOT/$patch_file"
        fi
        (
            cd "$upstream_tmp/${source}-${upstream_version}"
            # OUT normally lives under this repository. Prevent git apply from
            # discovering the parent worktree, where source-relative paths are
            # outside the current prefix and would otherwise be skipped.
            GIT_CEILING_DIRECTORIES="$upstream_tmp" git apply "$patch_file"
        )
    done

    if [[ -f "$artifact_orig" && "$force_orig" != "1" ]]; then
        assert_orig_matches_source "$artifact_orig" "$upstream_tmp/${source}-${upstream_version}"
        cp -f "$artifact_orig" "$orig"
    else
        local source_date_epoch
        source_date_epoch="$(git -C "$repo" show -s --format=%ct "$commit")"
        tar -C "$upstream_tmp" \
            --sort=name \
            --mtime="@$source_date_epoch" \
            --owner=0 \
            --group=0 \
            --numeric-owner \
            -cf - "${source}-${upstream_version}" \
            | gzip -n > "$orig"
    fi

    cp -a "$upstream_tmp/${source}-${upstream_version}" "$source_dir"
    cp -a "$ROOT/$packaging_dir/debian" "$source_dir/debian"

    (
        cd "$source_dir"
        dpkg-buildpackage -S -sa -us -uc -d
    )

    if [[ -f "$artifact_orig" && "$force_orig" != "1" ]]; then
        cmp -s "$orig" "$artifact_orig"
    else
        cp -f "$orig" "$ARTIFACTS/"
    fi
    find "$WORK" -maxdepth 1 -type f \
        \( -name "${source}_${upstream_version}*.dsc" \
        -o -name "${source}_${upstream_version}*.debian.tar.*" \
        -o -name "${source}_${upstream_version}*_source.changes" \
        -o -name "${source}_${upstream_version}*_source.buildinfo" \) \
        -exec mv -f {} "$ARTIFACTS/" \;
}

prepare_worktree_source() {
    local source="$1"
    local repo="$2"
    local upstream_version="$3"
    local packaging_dir="$4"
    local config_file="$5"
    local source_dir="$WORK/${source}-${upstream_version}"
    local upstream_tmp="$WORK/upstream-${source}"
    local export_list="$WORK/${source}-${upstream_version}.files"
    local orig_name="${source}_${upstream_version}.orig.tar.gz"
    local orig="$WORK/$orig_name"
    local artifact_orig="$ARTIFACTS/$orig_name"
    local force_orig="${FORCE_ORIG:-0}"
    local source_date_epoch

    git -c safe.directory="$repo" -C "$repo" rev-parse --is-inside-work-tree >/dev/null
    [[ -f "$config_file" ]] || {
        echo "kernel config not found: $config_file" >&2
        return 1
    }

    rm -rf "$source_dir" "$upstream_tmp" "$export_list"
    mkdir -p "$source_dir" "$upstream_tmp"

    # The shared Armbian worktree is also used for rewrite-composite builds,
    # which leave untracked drivers/video/rockchip/*-rewrite/ directories and
    # rewrite-modified tracked state behind. The 20260725 production orig
    # shipped that state (findings/2026-07-29-production-6-18-40-orig-is-
    # rewrite-composite-snapshot.md), so the export must never include
    # rewrite driver paths.
    git -c safe.directory="$repo" -C "$repo" ls-files --cached --others --exclude-standard |
        grep -Ev '(^|/)debian(/|$)|(^|/).*\.orig$|(^|/).*\.rej$|(^|/)\.config(\.old)?$|(^|/).*\.cmd$|(^|/).*\.o$|(^|/).*\.ko$|(^|/).*\.dtb(o)?$|(^|/)\.tmp_.*|(^|/)Module\.symvers$|(^|/)System\.map$|(^|/)modules\.(builtin|builtin\.modinfo|order)$|(^|/)built-in\.a$|^drivers/video/rockchip/(mpp|rga)-rewrite/' \
        > "$export_list"

    tar -C "$repo" -cf - -T "$export_list" | tar -C "$source_dir" -xf -

    if [[ -f "$artifact_orig" && "$force_orig" != "1" ]]; then
        assert_orig_matches_source "$artifact_orig" "$source_dir"
        cp -f "$artifact_orig" "$orig"
    else
        source_date_epoch="$(git -c safe.directory="$repo" -C "$repo" show -s --format=%ct HEAD)"
        cp -a "$source_dir" "$upstream_tmp/${source}-${upstream_version}"
        tar -C "$upstream_tmp" \
            --sort=name \
            --mtime="@$source_date_epoch" \
            --owner=0 \
            --group=0 \
            --numeric-owner \
            -cf - "${source}-${upstream_version}" \
            | gzip -n > "$orig"
        rm -rf "$upstream_tmp/${source}-${upstream_version}"
    fi

    cp -a "$ROOT/$packaging_dir/debian" "$source_dir/debian"
    # A packaging dir may deliberately ship no config of its own, so that it
    # cannot drift from the tracked config it borrows (see kernel-sgguard).
    mkdir -p "$source_dir/debian/config"
    cp -f "$config_file" "$source_dir/debian/config/arm64-rockchip64.config"

    (
        cd "$source_dir"
        dpkg-buildpackage -S -sa -us -uc -d
    )

    if [[ -f "$artifact_orig" && "$force_orig" != "1" ]]; then
        cmp -s "$orig" "$artifact_orig"
    else
        cp -f "$orig" "$ARTIFACTS/"
    fi
    find "$WORK" -maxdepth 1 -type f \
        \( -name "${source}_${upstream_version}*.dsc" \
        -o -name "${source}_${upstream_version}*.debian.tar.*" \
        -o -name "${source}_${upstream_version}*_source.changes" \
        -o -name "${source}_${upstream_version}*_source.buildinfo" \) \
        -exec mv -f {} "$ARTIFACTS/" \;
}

prepare_native_source() {
    local source="$1"
    local version="$2"
    local packaging_dir="$3"
    local payload_source="$4"
    local payload_name="$5"
    local source_dir="$WORK/${source}-${version}"

    rm -rf "$source_dir"
    mkdir -p "$source_dir"
    cp -a "$ROOT/$packaging_dir/debian" "$source_dir/debian"
    cp -f "$payload_source" "$source_dir/$payload_name"

    (
        cd "$source_dir"
        dpkg-buildpackage -S -us -uc -d
    )

    find "$WORK" -maxdepth 1 -type f \
        \( -name "${source}_${version}.dsc" \
        -o -name "${source}_${version}.tar.*" \
        -o -name "${source}_${version}_source.changes" \
        -o -name "${source}_${version}_source.buildinfo" \) \
        -exec mv -f {} "$ARTIFACTS/" \;
}

build_mpp() {
    prepare_source \
        "mpp" \
        "$MPP_REPO" \
        "$MPP_COMMIT" \
        "$MPP_UPSTREAM_VERSION" \
        "packaging/ppa/mpp" \
        "tools/AStyle.exe" \
        "tools/TextEncoding.exe"
}

build_librga() {
    prepare_source \
        "librga" \
        "$LIBRGA_REPO" \
        "$LIBRGA_COMMIT" \
        "$LIBRGA_UPSTREAM_VERSION" \
        "packaging/ppa/librga"
}

build_ffmpeg() {
    prepare_source \
        "ffmpeg" \
        "$FFMPEG_REPO" \
        "$FFMPEG_COMMIT" \
        "$FFMPEG_UPSTREAM_VERSION" \
        "packaging/ppa/ffmpeg"
}

build_ffmpeg_rockchip() {
    prepare_source \
        "ffmpeg-rockchip" \
        "$FFMPEG_ROCKCHIP_REPO" \
        "$FFMPEG_ROCKCHIP_COMMIT" \
        "$FFMPEG_ROCKCHIP_UPSTREAM_VERSION" \
        "packaging/ppa/ffmpeg-rockchip"
}

build_grd() {
    local -a delta_args=()
    local -a delta_patches=()
    local delta_patch
    if [[ -n "$GRD_DELTA" ]]; then
        IFS=: read -r -a delta_patches <<< "$GRD_DELTA"
        for delta_patch in "${delta_patches[@]}"; do
            delta_args+=(--patch "$delta_patch")
        done
    fi

    prepare_source \
        "gnome-remote-desktop" \
        "$GRD_REPO" \
        "$GRD_COMMIT" \
        "$GRD_UPSTREAM_VERSION" \
        "packaging/ppa/gnome-remote-desktop" \
        "${delta_args[@]}" \
        "_run/" \
        "build/" \
        "_build/" \
        "builddir/" \
        "*.spv"
}

build_kernel_forward_port() {
    prepare_worktree_source \
        "$KERNEL_PPA_SOURCE" \
        "$KERNEL_PPA_REPO" \
        "$KERNEL_PPA_UPSTREAM_VERSION" \
        "packaging/ppa/kernel-forward-port" \
        "$KERNEL_PPA_CONFIG"
}

build_kernel_sgguard() {
    prepare_worktree_source \
        "$KERNEL_SGGUARD_SOURCE" \
        "$KERNEL_PPA_REPO" \
        "$KERNEL_SGGUARD_UPSTREAM_VERSION" \
        "packaging/ppa/kernel-sgguard" \
        "$KERNEL_SGGUARD_CONFIG"
}

build_kernel_alpha_618() {
    prepare_source \
        "$KERNEL_ALPHA_618_SOURCE" \
        "$KERNEL_ALPHA_618_REPO" \
        "$KERNEL_ALPHA_618_COMMIT" \
        "$KERNEL_ALPHA_618_UPSTREAM_VERSION" \
        "packaging/ppa/kernel-rewrite-alpha-6.18"
}

build_kernel_alpha_72rc3() {
    prepare_source \
        "$KERNEL_ALPHA_72RC3_SOURCE" \
        "$KERNEL_ALPHA_72RC3_REPO" \
        "$KERNEL_ALPHA_72RC3_COMMIT" \
        "$KERNEL_ALPHA_72RC3_UPSTREAM_VERSION" \
        "packaging/ppa/kernel-rewrite-alpha-7.2-rc3"
}

build_kernel_alpha_72rc5() {
    prepare_source \
        "$KERNEL_ALPHA_72RC5_SOURCE" \
        "$KERNEL_ALPHA_72RC5_REPO" \
        "$KERNEL_ALPHA_72RC5_COMMIT" \
        "$KERNEL_ALPHA_72RC5_UPSTREAM_VERSION" \
        "packaging/ppa/kernel-rewrite-alpha-7.2-rc5"
}

build_gdm_hwenc() {
    prepare_native_source \
        "$GDM_HWENC_SOURCE" \
        "$GDM_HWENC_VERSION" \
        "packaging/ppa/gdm-hwenc" \
        "$GDM_HWENC_RULE" \
        "70-gnome-remote-desktop-gdm-hwenc.rules"
}

build_codec_udev() {
    prepare_native_source \
        "$CODEC_UDEV_SOURCE" \
        "$CODEC_UDEV_VERSION" \
        "packaging/ppa/codec-udev" \
        "$CODEC_UDEV_RULE" \
        "99-rockchip-codec.rules"
}

build_plymouth() {
    OUT="$OUT" "$ROOT/packaging/ppa/plymouth/build-source-package.sh"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

mkdir -p "$WORK" "$ARTIFACTS"

if [[ "$#" -eq 0 ]]; then
    set -- codec-udev mpp librga ffmpeg gnome-remote-desktop
fi

for package in "$@"; do
    case "$package" in
        mpp) build_mpp ;;
        librga) build_librga ;;
        ffmpeg) build_ffmpeg ;;
        ffmpeg-rockchip|nyanmisaka-ffmpeg-rockchip) build_ffmpeg_rockchip ;;
        gnome-remote-desktop|grd) build_grd ;;
        plymouth) build_plymouth ;;
        codec-udev|rk3588-codec-udev) build_codec_udev ;;
        gdm-hwenc|gnome-remote-desktop-gdm-hwenc) build_gdm_hwenc ;;
        kernel|forward-port-kernel|linux-rockchip64-ysp) build_kernel_forward_port ;;
        kernel-sgguard|sgguard|linux-rockchip64-ysp-sgguard) build_kernel_sgguard ;;
        kernel-alpha-6.18|rewrite-alpha-6.18|linux-rockchip64-ysp-alpha-6.18) build_kernel_alpha_618 ;;
        kernel-alpha-7.2-rc3|rewrite-alpha-7.2-rc3|linux-rockchip64-ysp-alpha-7.2-rc3) build_kernel_alpha_72rc3 ;;
        kernel-alpha-7.2-rc|kernel-alpha-7.2-rc5|rewrite-alpha-7.2-rc|rewrite-alpha-7.2-rc5|linux-rockchip64-ysp-alpha-7.2-rc5) build_kernel_alpha_72rc5 ;;
        *) echo "unknown package: $package" >&2; usage >&2; exit 2 ;;
    esac
done
