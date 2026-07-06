#!/usr/bin/env bash
# Compile the Rockchip MPP/RGA syzlang draft with upstream syzkaller when a
# syzkaller checkout is available.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYZ_FILE="${SYZ_FILE:-$SCRIPT_DIR/rockchip_mpp_rga.txt}"
SYZKALLER_DIR="${SYZKALLER_DIR:-}"
REQUIRE_COMPILE="${SYZKALLER_REQUIRE_COMPILE:-0}"

skip_or_fail()
{
	local msg=$1

	if [ "$REQUIRE_COMPILE" = "1" ]; then
		printf "%s\n" "$msg" >&2
		exit 1
	fi

	printf "SKIP: %s\n" "$msg"
	exit 77
}

if [ -z "$SYZKALLER_DIR" ]; then
	skip_or_fail "SYZKALLER_DIR is not set"
fi

if [ ! -f "$SYZ_FILE" ]; then
	printf "missing syzlang file: %s\n" "$SYZ_FILE" >&2
	exit 1
fi

if [ ! -d "$SYZKALLER_DIR/sys/linux" ] ||
	[ ! -d "$SYZKALLER_DIR/sys/syz-sysgen" ] ||
	[ ! -f "$SYZKALLER_DIR/Makefile" ]; then
	skip_or_fail "SYZKALLER_DIR does not look like an upstream syzkaller checkout: $SYZKALLER_DIR"
fi

if ! command -v go >/dev/null 2>&1; then
	skip_or_fail "Go toolchain is not installed; syzkaller make descriptions cannot run"
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/rk-syz-compile.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

work="$tmp/syzkaller"
mkdir -p "$work"

if git -C "$SYZKALLER_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	git -C "$SYZKALLER_DIR" archive HEAD | tar -x -C "$work"
else
	cp -a "$SYZKALLER_DIR"/. "$work"/
fi

install -m 0644 "$SYZ_FILE" "$work/sys/linux/dev_rockchip_mpp_rga.txt"

make -C "$work" descriptions

printf "PASS: Rockchip syzlang compiles with syzkaller at %s\n" "$SYZKALLER_DIR"
