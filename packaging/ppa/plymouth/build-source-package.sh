#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
OUT="${OUT:-$ROOT/packaging/ppa/out}"
WORK="$OUT/work"
ARTIFACTS="$OUT/artifacts"
DOWNLOADS="$OUT/downloads/plymouth"

UBUNTU_VERSION="24.004.60+git20250831.4a3c171d-0ubuntu8"
PPA_VERSION="24.004.60+git20250831.4a3c171d-0ubuntu8.1~rk1"
UPSTREAM_VERSION="24.004.60+git20250831.4a3c171d"
SOURCE="plymouth"
BASE_URL="https://launchpad.net/ubuntu/+archive/primary/+sourcefiles/$SOURCE/$UBUNTU_VERSION"
SOURCE_DIR="$WORK/$SOURCE-$UPSTREAM_VERSION"
PATCH_NAME="ply-keyboard-fix-hang-on-incomplete-csi.patch"

ORIG="$DOWNLOADS/${SOURCE}_${UPSTREAM_VERSION}.orig.tar.xz"
DEBIAN_TAR="$DOWNLOADS/${SOURCE}_${UBUNTU_VERSION}.debian.tar.xz"
DSC="$DOWNLOADS/${SOURCE}_${UBUNTU_VERSION}.dsc"

download() {
    local name="$1"
    local destination="$2"

    if [[ -f "$destination" ]]; then
        return
    fi

    curl --fail --location --retry 3 \
        --output "$destination" \
        "$BASE_URL/$name"
}

mkdir -p "$WORK" "$ARTIFACTS" "$DOWNLOADS"

download "$(basename "$ORIG")" "$ORIG"
download "$(basename "$DEBIAN_TAR")" "$DEBIAN_TAR"
download "$(basename "$DSC")" "$DSC"

(
    cd "$DOWNLOADS"
    sha256sum --check <<'CHECKSUMS'
1ebcbc43814c21e6a9a5f2e6508b7cb7d8fe5a85c422040e87d5c426184d6a42  plymouth_24.004.60+git20250831.4a3c171d.orig.tar.xz
1fd72f180df41b008b114fd4b156e892bef09de0acb4a139be5a680465df209b  plymouth_24.004.60+git20250831.4a3c171d-0ubuntu8.debian.tar.xz
5f3f5e9b84f838427e924ce01e49399c6e30a545f7ceded2b430b92b451d0b43  plymouth_24.004.60+git20250831.4a3c171d-0ubuntu8.dsc
CHECKSUMS
)

rm -rf "$SOURCE_DIR"
dpkg-source --extract "$DSC" "$SOURCE_DIR"

cp "$ROOT/packaging/ppa/plymouth/debian/patches/$PATCH_NAME" \
    "$SOURCE_DIR/debian/patches/$PATCH_NAME"
printf '%s\n' "$PATCH_NAME" >> "$SOURCE_DIR/debian/patches/series"

changelog_tmp="$SOURCE_DIR/debian/changelog.ysp"
{
    cat "$ROOT/packaging/ppa/plymouth/debian/changelog.entry"
    printf '\n'
    cat "$SOURCE_DIR/debian/changelog"
} > "$changelog_tmp"
mv "$changelog_tmp" "$SOURCE_DIR/debian/changelog"

dpkg-source --before-build "$SOURCE_DIR"

grep -Fq "plymouth ($PPA_VERSION) resolute" "$SOURCE_DIR/debian/changelog"
if sed -n '/if (csi_seq_size == 0)/,+1p' \
        "$SOURCE_DIR/src/libply-splash-core/ply-keyboard.c" |
        grep -Fq 'continue;'; then
    echo "incomplete-CSI fix was not applied" >&2
    exit 1
fi

(
    cd "$SOURCE_DIR"
    PATH=/usr/sbin:/usr/bin:/sbin:/bin \
        dpkg-buildpackage -S -sa -us -uc -d
)

cp -f "$ORIG" "$ARTIFACTS/"
find "$WORK" -maxdepth 1 -type f \
    \( -name "${SOURCE}_${PPA_VERSION}.dsc" \
    -o -name "${SOURCE}_${PPA_VERSION}.debian.tar.*" \
    -o -name "${SOURCE}_${PPA_VERSION}_source.changes" \
    -o -name "${SOURCE}_${PPA_VERSION}_source.buildinfo" \) \
    -exec mv -f {} "$ARTIFACTS/" \;

echo "Plymouth source package:"
ls -1 "$ARTIFACTS/${SOURCE}_${PPA_VERSION}"*
