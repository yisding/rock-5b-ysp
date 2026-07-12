#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${OUT:-$ROOT/packaging/ppa/out}"
WORK="$OUT/work"
ARTIFACTS="$OUT/artifacts"

MPP_REPO="${MPP_REPO:-/home/yi/Code/rockchip-userspace/mpp-rockchip}"
MPP_COMMIT="${MPP_COMMIT:-1375813c}"
MPP_UPSTREAM_VERSION="${MPP_UPSTREAM_VERSION:-1.5.0+git20260529.1375813c+ds}"

LIBRGA_REPO="${LIBRGA_REPO:-/home/yi/Code/rockchip-userspace/librga-fork}"
LIBRGA_COMMIT="${LIBRGA_COMMIT:-a632217}"
LIBRGA_UPSTREAM_VERSION="${LIBRGA_UPSTREAM_VERSION:-2.2.0+git20260703.a632217}"

FFMPEG_REPO="${FFMPEG_REPO:-/home/yi/Code/ffmpeg/ffmpeg-rockchip-81}"
FFMPEG_COMMIT="${FFMPEG_COMMIT:-be367abfe67045b9c68812ecee3b6162c92f9776}"
FFMPEG_UPSTREAM_VERSION="${FFMPEG_UPSTREAM_VERSION:-8.1.2+rockchip81+git20260711.be367abfe6}"

FFMPEG_ROCKCHIP_REPO="${FFMPEG_ROCKCHIP_REPO:-/home/yi/Code/ffmpeg/ffmpeg-rockchip}"
FFMPEG_ROCKCHIP_COMMIT="${FFMPEG_ROCKCHIP_COMMIT:-40c412daccf08164493da0de990eb99a8948116b}"
FFMPEG_ROCKCHIP_UPSTREAM_VERSION="${FFMPEG_ROCKCHIP_UPSTREAM_VERSION:-6.1+git20260423.40c412dacc}"

GRD_REPO="${GRD_REPO:-/home/yi/Code/gnome/grd/grd-ffmpeg}"
GRD_COMMIT="${GRD_COMMIT:-a59c904c99088235eb4de31ca340747d334494f3}"
GRD_UPSTREAM_VERSION="${GRD_UPSTREAM_VERSION:-50.1+rkmpp+git20260630.a59c904+dirty20260706}"
GRD_DELTA="${GRD_DELTA:-$ROOT/packaging/ppa/gnome-remote-desktop/source-deltas/dirty20260706-worktree.patch}"

KERNEL_PPA_SOURCE="${KERNEL_PPA_SOURCE:-linux-rockchip64-ysp}"
KERNEL_PPA_REPO="${KERNEL_PPA_REPO:-/home/yi/Code/kernel/rock5b-kernel-build/armbian-build/cache/sources/linux-kernel-worktree/6.18__rockchip64__arm64}"
KERNEL_PPA_CONFIG="${KERNEL_PPA_CONFIG:-$KERNEL_PPA_REPO/.config}"
KERNEL_PPA_UPSTREAM_VERSION="${KERNEL_PPA_UPSTREAM_VERSION:-6.18.38+rk3588av1fwport20260709}"

KERNEL_ALPHA_618_SOURCE="${KERNEL_ALPHA_618_SOURCE:-linux-rockchip64-ysp-alpha-6.18}"
KERNEL_ALPHA_618_REPO="${KERNEL_ALPHA_618_REPO:-/home/yi/Code/kernel/linux-6.18-rkvenc}"
KERNEL_ALPHA_618_CONFIG="${KERNEL_ALPHA_618_CONFIG:-$ROOT/packaging/ppa/kernel-rewrite-alpha-6.18/debian/config/arm64-rockchip64.config}"
KERNEL_ALPHA_618_UPSTREAM_VERSION="${KERNEL_ALPHA_618_UPSTREAM_VERSION:-6.18.0+rk3588rewritealpha20260710}"

KERNEL_ALPHA_72RC2_SOURCE="${KERNEL_ALPHA_72RC2_SOURCE:-linux-rockchip64-ysp-alpha-7.2-rc2}"
KERNEL_ALPHA_72RC2_REPO="${KERNEL_ALPHA_72RC2_REPO:-/home/yi/Code/kernel/linux}"
KERNEL_ALPHA_72RC2_CONFIG="${KERNEL_ALPHA_72RC2_CONFIG:-$ROOT/packaging/ppa/kernel-rewrite-alpha-7.2-rc2/debian/config/arm64-rockchip64.config}"
KERNEL_ALPHA_72RC2_UPSTREAM_VERSION="${KERNEL_ALPHA_72RC2_UPSTREAM_VERSION:-7.2.0~rc2+rk3588rewritealpha20260710}"

GDM_HWENC_SOURCE="${GDM_HWENC_SOURCE:-gnome-remote-desktop-gdm-hwenc}"
GDM_HWENC_VERSION="${GDM_HWENC_VERSION:-1.0}"
GDM_HWENC_RULE="${GDM_HWENC_RULE:-$ROOT/packaging/gdm-hwenc/root/usr/lib/udev/rules.d/70-gnome-remote-desktop-gdm-hwenc.rules}"

usage() {
    cat <<'USAGE'
Usage: build-source-packages.sh [mpp] [librga] [ffmpeg] [ffmpeg-rockchip] [gnome-remote-desktop|grd] [gdm-hwenc] [kernel] [kernel-alpha-6.18] [kernel-alpha-7.2-rc2]

Build unsigned source packages for ppa:yi-ding/ubuntu-rock-5b.
Artifacts are written under packaging/ppa/out/artifacts by default.
Set OUT=/path/to/output to use a different output root.

Existing orig tarballs in the artifacts directory are reused by default, which
is required when uploading a new Debian revision for an upstream version that
Launchpad has already accepted. Set FORCE_ORIG=1 to regenerate an orig tarball.

Source tree defaults can be overridden with MPP_REPO, LIBRGA_REPO, FFMPEG_REPO,
FFMPEG_ROCKCHIP_REPO, GRD_REPO, and the matching *_COMMIT /
*_UPSTREAM_VERSION variables. The GRD snapshot applies GRD_DELTA on top of
GRD_COMMIT by default so the dirty20260706 source package is reconstructible
from a clean checkout.

The forward-port kernel target exports the already-patched Armbian kernel
worktree named by KERNEL_PPA_REPO, excluding build products and .git, then
overlays packaging/ppa/kernel-forward-port/debian. It is intentionally not part
of the no-argument default set because the orig tarball is large.

The alpha rewrite kernel targets export the local clean-room rewrite kernel
worktrees named by KERNEL_ALPHA_618_REPO and KERNEL_ALPHA_72RC2_REPO, then
overlay packaging/ppa/kernel-rewrite-alpha-6.18/debian and
packaging/ppa/kernel-rewrite-alpha-7.2-rc2/debian respectively. They are also
large and intentionally excluded from the no-argument default set.

The gdm-hwenc target creates a small native source package and copies the
canonical rule from packaging/gdm-hwenc at export time.
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
    local patch_file=""
    if [[ "${1:-}" == "--patch" ]]; then
        patch_file="$2"
        shift 2
    fi
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
    if [[ -n "$patch_file" ]]; then
        if [[ "$patch_file" != /* ]]; then
            patch_file="$ROOT/$patch_file"
        fi
        (
            cd "$upstream_tmp/${source}-${upstream_version}"
            git apply "$patch_file"
        )
    fi

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

    git -c safe.directory="$repo" -C "$repo" ls-files --cached --others --exclude-standard |
        grep -Ev '(^|/)debian(/|$)|(^|/).*\.orig$|(^|/).*\.rej$|(^|/)\.config(\.old)?$|(^|/).*\.cmd$|(^|/).*\.o$|(^|/).*\.ko$|(^|/).*\.dtb(o)?$|(^|/)\.tmp_.*|(^|/)Module\.symvers$|(^|/)System\.map$|(^|/)modules\.(builtin|builtin\.modinfo|order)$|(^|/)built-in\.a$' \
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
    local source_dir="$WORK/${source}-${version}"

    rm -rf "$source_dir"
    mkdir -p "$source_dir"
    cp -a "$ROOT/$packaging_dir/debian" "$source_dir/debian"
    cp -f "$GDM_HWENC_RULE" "$source_dir/70-gnome-remote-desktop-gdm-hwenc.rules"

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
    prepare_source \
        "gnome-remote-desktop" \
        "$GRD_REPO" \
        "$GRD_COMMIT" \
        "$GRD_UPSTREAM_VERSION" \
        "packaging/ppa/gnome-remote-desktop" \
        --patch "$GRD_DELTA" \
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

build_kernel_alpha_618() {
    prepare_worktree_source \
        "$KERNEL_ALPHA_618_SOURCE" \
        "$KERNEL_ALPHA_618_REPO" \
        "$KERNEL_ALPHA_618_UPSTREAM_VERSION" \
        "packaging/ppa/kernel-rewrite-alpha-6.18" \
        "$KERNEL_ALPHA_618_CONFIG"
}

build_kernel_alpha_72rc2() {
    prepare_worktree_source \
        "$KERNEL_ALPHA_72RC2_SOURCE" \
        "$KERNEL_ALPHA_72RC2_REPO" \
        "$KERNEL_ALPHA_72RC2_UPSTREAM_VERSION" \
        "packaging/ppa/kernel-rewrite-alpha-7.2-rc2" \
        "$KERNEL_ALPHA_72RC2_CONFIG"
}

build_gdm_hwenc() {
    prepare_native_source \
        "$GDM_HWENC_SOURCE" \
        "$GDM_HWENC_VERSION" \
        "packaging/ppa/gdm-hwenc"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

mkdir -p "$WORK" "$ARTIFACTS"

if [[ "$#" -eq 0 ]]; then
    set -- mpp librga ffmpeg gnome-remote-desktop
fi

for package in "$@"; do
    case "$package" in
        mpp) build_mpp ;;
        librga) build_librga ;;
        ffmpeg) build_ffmpeg ;;
        ffmpeg-rockchip|nyanmisaka-ffmpeg-rockchip) build_ffmpeg_rockchip ;;
        gnome-remote-desktop|grd) build_grd ;;
        gdm-hwenc|gnome-remote-desktop-gdm-hwenc) build_gdm_hwenc ;;
        kernel|forward-port-kernel|linux-rockchip64-ysp) build_kernel_forward_port ;;
        kernel-alpha-6.18|rewrite-alpha-6.18|linux-rockchip64-ysp-alpha-6.18) build_kernel_alpha_618 ;;
        kernel-alpha-7.2-rc|kernel-alpha-7.2-rc2|rewrite-alpha-7.2-rc|rewrite-alpha-7.2-rc2|linux-rockchip64-ysp-alpha-7.2-rc2) build_kernel_alpha_72rc2 ;;
        *) echo "unknown package: $package" >&2; usage >&2; exit 2 ;;
    esac
done
