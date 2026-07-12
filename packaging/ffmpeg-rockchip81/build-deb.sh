#!/usr/bin/env bash
# Build a local ffmpeg-rockchip-81 runtime .deb from a clean clone of the
# forward-port tree. The package is intentionally installed under /opt so it
# does not replace Ubuntu's ffmpeg/libav* packages.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$DIR/../.." && pwd)"
WORKSPACE_ROOT="$(cd "${WORKSPACE_ROOT:-$REPO_ROOT/..}" && pwd)"
NAME=ffmpeg-rockchip81
FFSRC="${FFSRC:-$WORKSPACE_ROOT/ffmpeg/ffmpeg-rockchip-81}"
PREFIX=/opt/ffmpeg-rockchip-81
OUT="$DIR/build"
BUILD_SRC="$OUT/src"
PKGROOT="$OUT/debian/$NAME"
JOBS="${JOBS:-$(nproc)}"

usage() {
	cat <<EOF
Usage: build-deb.sh [clean]

Build the co-installable ffmpeg-rockchip81 runtime package, or remove its
disposable build directory.

Environment:
  WORKSPACE_ROOT  Parent workspace for the default FFmpeg checkout
  FFSRC           FFmpeg source directory (default: $FFSRC)
  JOBS            Parallel build jobs (default: $JOBS)
  VERSION         Override the generated Debian version
EOF
}

case ${1:-} in
	-h|--help)
		usage
		exit 0
		;;
	''|clean)
		;;
	*)
		echo "unknown argument: $1" >&2
		usage >&2
		exit 2
		;;
esac

if [ "${1:-}" = "clean" ]; then
	rm -rf "$OUT"
	echo "cleaned: $OUT"
	exit 0
fi

for tool in dpkg dpkg-deb dpkg-shlibdeps git install make sed strip; do
	command -v "$tool" >/dev/null 2>&1 || {
		echo "ERROR: required tool not found: $tool" >&2
		exit 1
	}
done

[ -x "$FFSRC/configure" ] || {
	echo "ERROR: FFSRC does not look like an FFmpeg tree: $FFSRC" >&2
	exit 1
}

if ! git -C "$FFSRC" diff --quiet -- .; then
	echo "ERROR: $FFSRC has tracked working-tree changes." >&2
	echo "       Commit them first, or build from a clean clone." >&2
	exit 1
fi

ARCH="$(dpkg --print-architecture)"
COMMIT="$(git -C "$FFSRC" rev-parse --short=12 HEAD)"
COMMIT_DATE="$(git -C "$FFSRC" show -s --format=%cd --date=format:%Y%m%d HEAD)"
VERSION="${VERSION:-8.0.git+rockchip81+git${COMMIT_DATE}.${COMMIT}-1}"
DEB="$OUT/${NAME}_${VERSION}_${ARCH}.deb"

rm -rf "$OUT"
mkdir -p "$OUT/debian"

echo "== clone source =="
echo "   source: $FFSRC"
echo "   commit: $COMMIT"
git clone --shared "$FFSRC" "$BUILD_SRC" >/dev/null

echo "== configure =="
(
	cd "$BUILD_SRC"
	./configure \
		--enable-rkmpp \
		--enable-rkrga \
		--enable-version3 \
		--enable-libdrm
)

echo "== build ffmpeg/ffprobe/ffplay =="
make -C "$BUILD_SRC" -j"$JOBS" ffmpeg ffprobe ffplay

echo "== stage package root =="
install -d \
	"$PKGROOT/DEBIAN" \
	"$PKGROOT$PREFIX/bin" \
	"$PKGROOT/usr/local/bin" \
	"$PKGROOT/usr/share/doc/$NAME"

install -m 0755 "$BUILD_SRC/ffmpeg"  "$PKGROOT$PREFIX/bin/ffmpeg"
install -m 0755 "$BUILD_SRC/ffprobe" "$PKGROOT$PREFIX/bin/ffprobe"
install -m 0755 "$BUILD_SRC/ffplay"  "$PKGROOT$PREFIX/bin/ffplay"
strip --strip-unneeded "$PKGROOT$PREFIX/bin/ffmpeg" \
	"$PKGROOT$PREFIX/bin/ffprobe" \
	"$PKGROOT$PREFIX/bin/ffplay"

ln -s "$PREFIX/bin/ffmpeg"  "$PKGROOT/usr/local/bin/ffmpeg-rockchip81"
ln -s "$PREFIX/bin/ffprobe" "$PKGROOT/usr/local/bin/ffprobe-rockchip81"
ln -s "$PREFIX/bin/ffplay"  "$PKGROOT/usr/local/bin/ffplay-rockchip81"

cat > "$PKGROOT/usr/share/doc/$NAME/build-info.txt" <<EOF
source: $FFSRC
commit: $COMMIT
commit-date: $COMMIT_DATE
version: $VERSION
configure: --enable-rkmpp --enable-rkrga --enable-version3 --enable-libdrm
prefix: $PREFIX
EOF

cat > "$OUT/debian/control" <<EOF
Source: $NAME
Section: video
Priority: optional
Maintainer: Local Build <root@localhost>
Standards-Version: 4.7.0

Package: $NAME
Architecture: $ARCH
Depends: \${shlibs:Depends}
Description: ffmpeg-rockchip-81 forward-port runtime
 Runtime commands built from the local ffmpeg-rockchip-81 forward-port tree.
 This package installs under /opt and provides ffmpeg-rockchip81,
 ffprobe-rockchip81, and ffplay-rockchip81 links so it can coexist with the
 distro FFmpeg packages.
EOF

echo "== compute shared-library dependencies =="
SHLIBS_DEPENDS="$(
	cd "$OUT"
	dpkg-shlibdeps -O \
		"debian/$NAME$PREFIX/bin/ffmpeg" \
		"debian/$NAME$PREFIX/bin/ffprobe" \
		"debian/$NAME$PREFIX/bin/ffplay" |
		sed -n 's/^shlibs:Depends=//p'
)"
INSTALLED_SIZE="$(du -ks "$PKGROOT" | awk '{ print $1 }')"

cat > "$PKGROOT/DEBIAN/control" <<EOF
Package: $NAME
Version: $VERSION
Section: video
Priority: optional
Architecture: $ARCH
Maintainer: Local Build <root@localhost>
Installed-Size: $INSTALLED_SIZE
Depends: $SHLIBS_DEPENDS
Description: ffmpeg-rockchip-81 forward-port runtime
 Runtime commands built from the local ffmpeg-rockchip-81 forward-port tree.
 This package installs under /opt and provides ffmpeg-rockchip81,
 ffprobe-rockchip81, and ffplay-rockchip81 links so it can coexist with the
 distro FFmpeg packages.
EOF

chmod -R u=rwX,go=rX "$PKGROOT"

echo "== assemble .deb =="
dpkg-deb --build --root-owner-group "$PKGROOT" "$DEB" >/dev/null
sha256sum "$DEB" > "$DEB.sha256"

echo
echo "built: $DEB"
echo "sha256: $(cut -d' ' -f1 "$DEB.sha256")"
dpkg-deb --info "$DEB" | sed -n '1,3p;/^ Depends:/p;/^ Description:/,$p' | sed 's/^/  /'
