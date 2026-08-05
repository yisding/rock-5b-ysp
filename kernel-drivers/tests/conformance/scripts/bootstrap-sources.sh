#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MANIFEST=${MANIFEST:-"$ROOT/MANIFEST.tsv"}
MODE=${1:-bootstrap}

usage() {
    cat >&2 <<'EOF'
Usage: scripts/bootstrap-sources.sh [bootstrap|verify]

bootstrap  Clone missing third-party source trees from MANIFEST.tsv, check out
           the pinned commits, and apply repo-owned conformance patches.
verify     Check that every source tree exists, is clean, and contains the
           manifest commit in its local history.
EOF
}

case "$MODE" in
    bootstrap|verify) ;;
    -h|--help|help) usage; exit 0 ;;
    *) usage; exit 2 ;;
esac

have_commit() {
    local dir=$1 commit=$2
    git -C "$dir" cat-file -e "$commit^{commit}" 2>/dev/null
}

fetch_commit() {
    local dir=$1 remote=$2 branch=$3 commit=$4
    if have_commit "$dir" "$commit"; then
        return 0
    fi
    git -C "$dir" fetch --depth 1 origin "$commit" 2>/dev/null ||
        git -C "$dir" fetch --depth 1000 origin "$branch"
    have_commit "$dir" "$commit"
}

require_clean() {
    local dir=$1
    git -C "$dir" diff --quiet
    git -C "$dir" diff --cached --quiet
}

apply_patch_set() {
    local name=$1 dir=$2
    local patch_dir="$ROOT/patches/$name"
    [ -d "$patch_dir" ] || return 0

    local patch
    for patch in "$patch_dir"/*.patch; do
        [ -e "$patch" ] || continue
        if git -C "$dir" apply --reverse --check "$patch" 2>/dev/null; then
            continue
        fi
        git -C "$dir" apply --check "$patch"
        git -C "$dir" apply "$patch"
    done

    if ! git -C "$dir" diff --quiet; then
        git -C "$dir" add -A
        git -C "$dir" \
            -c user.name="YSP conformance bootstrap" \
            -c user.email="ysp@example.invalid" \
            commit -m "Apply YSP conformance patches for $name" >/dev/null
    fi
}

verify_patch_set() {
    local name=$1 dir=$2
    local patch_dir="$ROOT/patches/$name"
    [ -d "$patch_dir" ] || return 0

    local patch
    for patch in "$patch_dir"/*.patch; do
        [ -e "$patch" ] || continue
        if ! git -C "$dir" apply --reverse --check "$patch" 2>/dev/null; then
            echo "patch not applied for $name: $patch" >&2
            return 1
        fi
    done
}

bootstrap_one() {
    local name=$1 path=$2 remote=$3 branch=$4 commit=$5
    local dir="$ROOT/$path"

    if [ -e "$dir" ] && [ ! -d "$dir/.git" ]; then
        echo "error: $path exists but is not a git checkout" >&2
        return 1
    fi

    if [ ! -d "$dir/.git" ]; then
        mkdir -p "$(dirname "$dir")"
        git init "$dir" >/dev/null
        git -C "$dir" remote add origin "$remote"
        fetch_commit "$dir" "$remote" "$branch" "$commit"
        git -C "$dir" checkout --detach "$commit" >/dev/null
        apply_patch_set "$name" "$dir"
        echo "bootstrapped $name at $path"
        return 0
    fi

    require_clean "$dir"
    fetch_commit "$dir" "$remote" "$branch" "$commit"
    if ! git -C "$dir" merge-base --is-ancestor "$commit" HEAD; then
        echo "error: $path does not contain manifest commit $commit in HEAD history" >&2
        echo "       move it aside or reset it before bootstrapping again" >&2
        return 1
    fi
    apply_patch_set "$name" "$dir"
    require_clean "$dir"
    echo "verified existing $name at $path"
}

verify_one() {
    local name=$1 path=$2 remote=$3 branch=$4 commit=$5
    local dir="$ROOT/$path"

    if [ ! -d "$dir/.git" ]; then
        echo "missing $name at $path" >&2
        return 1
    fi
    require_clean "$dir"
    if ! have_commit "$dir" "$commit"; then
        echo "missing commit $commit in $path" >&2
        return 1
    fi
    if ! git -C "$dir" merge-base --is-ancestor "$commit" HEAD; then
        echo "manifest commit $commit is not in HEAD history for $path" >&2
        return 1
    fi
    verify_patch_set "$name" "$dir"
    echo "ok $name $path"
}

while IFS=$'\t' read -r name path remote branch commit _purpose; do
    [ "$name" != "name" ] || continue
    [ -n "${name:-}" ] || continue
    case "$MODE" in
        bootstrap) bootstrap_one "$name" "$path" "$remote" "$branch" "$commit" ;;
        verify) verify_one "$name" "$path" "$remote" "$branch" "$commit" ;;
    esac
done < "$MANIFEST"
