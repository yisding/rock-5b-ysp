#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: GPL-2.0-only
# Install a pre-commit hook into the rewrite kernel repo that blocks a commit
# touching the rewrite KUnit sources unless their registered case arrays still
# match the tracked rewrite-kunit-manifest.tsv.
#
# Retro item 5 (2026-07-30): kernel commit 1115e0c added five AV1 KUnit cases
# with no paired manifest bump, and the stale 84-case gate produced a false-red
# boot days later. The manifest check already existed in the build gate; this
# moves it to kernel-commit time, where the drift is introduced. The kernel
# trees are linked worktrees of one repo, so the hook installs once into the
# shared common hooks dir and covers every worktree.
#
# Idempotent. Re-run after moving the repos to refresh the baked paths.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFIER="$(cd "$HERE/../tests" && pwd)/kunit-manifest-check.sh"
MANIFEST="$(cd "$HERE/../tests" && pwd)/rewrite-kunit-manifest.tsv"

KERNEL_TREE=${KERNEL_TREE:-"$HERE/../../../rock-5b/kernel/linux-6.18-rkvenc"}
if [ ! -d "$KERNEL_TREE/.git" ] && [ ! -f "$KERNEL_TREE/.git" ]; then
	echo "install-kernel-hooks: not a kernel worktree: $KERNEL_TREE" >&2
	echo "  set KERNEL_TREE=/path/to/a/rewrite/worktree" >&2
	exit 1
fi
[ -r "$VERIFIER" ] || { echo "missing verifier: $VERIFIER" >&2; exit 1; }

COMMON_DIR=$(git -C "$KERNEL_TREE" rev-parse --git-common-dir)
case "$COMMON_DIR" in
	/*) ;;
	*) COMMON_DIR="$KERNEL_TREE/$COMMON_DIR" ;;
esac
HOOK_DIR="$COMMON_DIR/hooks"
HOOK="$HOOK_DIR/pre-commit"
mkdir -p "$HOOK_DIR"

if [ -e "$HOOK" ] && ! grep -q 'rewrite-kunit-manifest guard' "$HOOK" 2>/dev/null; then
	echo "install-kernel-hooks: a foreign pre-commit hook already exists:" >&2
	echo "  $HOOK" >&2
	echo "  Refusing to overwrite. Merge the guard below by hand." >&2
	exit 1
fi

cat > "$HOOK" <<EOF
#!/usr/bin/env bash
# rewrite-kunit-manifest guard — installed by rock-5b-ysp install-kernel-hooks.sh.
# Blocks a commit whose staged rewrite KUnit sources drift from the tracked
# manifest. Regenerate with install-kernel-hooks.sh after moving the repos.
set -euo pipefail

VERIFIER="$VERIFIER"
MANIFEST="$MANIFEST"

SOURCES="drivers/video/rockchip/mpp-rewrite/mpp_rewrite.c drivers/video/rockchip/rga-rewrite/rga_rewrite.c"

# Fast path: only act when a rewrite KUnit source is actually staged.
staged=\$(git diff --cached --name-only)
touched=0
for s in \$SOURCES; do
	case " \$staged " in *" \$s "*) touched=1 ;; esac
done
[ "\$touched" = 1 ] || exit 0

if [ ! -r "\$VERIFIER" ] || [ ! -r "\$MANIFEST" ]; then
	echo "pre-commit: KUnit manifest guard cannot find its ysp files:" >&2
	echo "  verifier=\$VERIFIER" >&2
	echo "  manifest=\$MANIFEST" >&2
	echo "  Re-run install-kernel-hooks.sh, or commit with --no-verify to bypass." >&2
	exit 1
fi

# Check STAGED content (not the working tree): materialize each staged source
# into a temp tree and verify it against the ysp manifest.
tmp=\$(mktemp -d "\${TMPDIR:-/tmp}/kunit-precommit.XXXXXX")
trap 'rm -rf "\$tmp"' EXIT
for s in \$SOURCES; do
	case " \$staged " in *" \$s "*) ;; *) continue ;; esac
	mkdir -p "\$tmp/\$(dirname "\$s")"
	git show ":\$s" > "\$tmp/\$s"
done

if ! KUNIT_MANIFEST="\$MANIFEST" bash "\$VERIFIER" "\$tmp"; then
	echo "" >&2
	echo "pre-commit: rewrite KUnit case arrays drifted from the manifest." >&2
	echo "  Bump rewrite-kunit-manifest.tsv and the gate counts in ysp in the" >&2
	echo "  same logical change, then re-commit. Bypass with --no-verify only" >&2
	echo "  if you are intentionally splitting the pair (and land the ysp side" >&2
	echo "  immediately)." >&2
	exit 1
fi
EOF
chmod +x "$HOOK"
echo "installed rewrite-kunit-manifest pre-commit guard:"
echo "  hook:     $HOOK"
echo "  verifier: $VERIFIER"
echo "  covers every worktree sharing $COMMON_DIR"
