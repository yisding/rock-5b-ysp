#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${OUT:-/tmp/ubuntu-rock-5b-ppa}"
WORK="$OUT/work"
ARTIFACTS="$OUT/artifacts"

MPP_REPO="${MPP_REPO:-/home/yi/Code/rockchip-userspace/mpp-rockchip}"
MPP_COMMIT="${MPP_COMMIT:-1375813c}"
MPP_UPSTREAM_VERSION="${MPP_UPSTREAM_VERSION:-1.5.0+git20260529.1375813c+ds}"

LIBRGA_REPO="${LIBRGA_REPO:-/home/yi/Code/rockchip-userspace/librga-fork}"
LIBRGA_COMMIT="${LIBRGA_COMMIT:-a632217}"
LIBRGA_UPSTREAM_VERSION="${LIBRGA_UPSTREAM_VERSION:-2.2.0+git20260703.a632217}"

FFMPEG_REPO="${FFMPEG_REPO:-/home/yi/Code/ffmpeg/ffmpeg-rockchip-81}"
FFMPEG_COMMIT="${FFMPEG_COMMIT:-75638e7f0b1775193381af0c3187838f6c51dbd1}"
FFMPEG_UPSTREAM_VERSION="${FFMPEG_UPSTREAM_VERSION:-8.1.2+rockchip81+git20260703.75638e7f0b}"

GRD_REPO="${GRD_REPO:-/home/yi/Code/gnome/grd/grd-ffmpeg}"
GRD_COMMIT="${GRD_COMMIT:-a59c904c99088235eb4de31ca340747d334494f3}"
GRD_UPSTREAM_VERSION="${GRD_UPSTREAM_VERSION:-50.1+rkmpp+git20260630.a59c904+dirty20260706}"
GRD_DELTA="${GRD_DELTA:-$ROOT/packaging/ppa/gnome-remote-desktop/source-deltas/dirty20260706-worktree.patch}"

mkdir -p "$WORK" "$ARTIFACTS"

usage() {
    cat <<'USAGE'
Usage: build-source-packages.sh [mpp] [librga] [ffmpeg] [gnome-remote-desktop|grd]

Build unsigned source packages for ppa:yi-ding/ubuntu-rock-5b.
Artifacts are written under ${OUT:-/tmp/ubuntu-rock-5b-ppa}/artifacts.

Existing orig tarballs in the artifacts directory are reused by default, which
is required when uploading a new Debian revision for an upstream version that
Launchpad has already accepted. Set FORCE_ORIG=1 to regenerate an orig tarball.

Source tree defaults can be overridden with MPP_REPO, LIBRGA_REPO, FFMPEG_REPO,
GRD_REPO, and the matching *_COMMIT / *_UPSTREAM_VERSION variables. The GRD
snapshot applies GRD_DELTA on top of GRD_COMMIT by default so the dirty20260706
source package is reconstructible from a clean checkout.
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

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if [[ "$#" -eq 0 ]]; then
    set -- mpp librga ffmpeg gnome-remote-desktop
fi

for package in "$@"; do
    case "$package" in
        mpp) build_mpp ;;
        librga) build_librga ;;
        ffmpeg) build_ffmpeg ;;
        gnome-remote-desktop|grd) build_grd ;;
        *) echo "unknown package: $package" >&2; usage >&2; exit 2 ;;
    esac
done
