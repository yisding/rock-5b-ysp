# shellcheck shell=bash
# Armbian extension: put the REAL build time in `uname -v`.
#
# Why this exists. Armbian pins the kernel build stamp for reproducibility:
#
#   KBUILD_BUILD_TIMESTAMP=${kernel_base_revision_date}
#
# where that date is the *checked-out kernel git revision's* date, not wall
# clock (lib/functions/compilation/kernel-make.sh). Every rebuild of the same
# base therefore reports an identical `uname -v`, which is exactly the situation
# the validation runbook warns about — `uname -r` cannot distinguish a debug
# rebuild from stock, and `uname -v` could not either, so identifying a booted
# build meant comparing the vmlinuz md5 against the deb.
#
# With per-slot BRANCHes the release string already separates the four flavors;
# this makes successive builds *within* a slot self-identifying too.
#
# The trade-off, stated plainly: this deliberately breaks byte-level build
# reproducibility. SOURCE_DATE_EPOCH stays pinned (so most of the build is
# unaffected), but two builds of identical source no longer produce an identical
# vmlinux, because the timestamp string is compiled in. The md5-vs-deb identity
# check is unaffected — a given build still matches its own deb — you just lose
# "same source implies same bytes". That is the point: we want builds to be
# telling apart, and the P####-C#### pair remains the source/config identity.
#
# Appended parameters win: make applies the last assignment of a variable on the
# command line, so this overrides Armbian's earlier KBUILD_BUILD_TIMESTAMP
# without patching the Armbian tree.

function custom_kernel_make_params__ysp_real_build_stamp() {
	declare stamp
	stamp="$(LC_ALL=C date -R)"
	display_alert "ysp-build-stamp" "real build timestamp: ${stamp}" "info"
	common_make_params_quoted+=("KBUILD_BUILD_TIMESTAMP=${stamp}")
}

# Make the compiler cache independent of the kernel worktree PATH.
#
# Armbian names the worktree
# cache/sources/linux-kernel-worktree/${KERNEL_MAJOR_MINOR}__${LINUXFAMILY}__${ARCH},
# the kernel compiles -g -gdwarf-5 with no -fdebug-prefix-map, and ccache's
# hash_dir defaults to true -- so the working directory is part of every object's
# cache key. Anything that moves that path (a LINUXFAMILY rename, a kernel series
# bump) silently invalidates the ENTIRE kernel half of the shared store.
# CCACHE_BASEDIR does NOT cover this: measured with -gdwarf-5, the same source
# built in two directories gets 0 hits with CCACHE_BASEDIR set, and 1 hit with
# CCACHE_NOHASHDIR=1.
#
# This is the ONLY available mitigation, not a belt-and-braces one. Pinning
# LINUXFAMILY was tried and measured not to work -- config-prepare.sh:141 resets
# it unconditionally from BOARDFAMILY after any config or command-line value, and
# LINUXSOURCEDIR at :284 is likewise an unconditional declare -g. So the worktree
# path genuinely can move out from under the cache, and nothing upstream of ccache
# can stop it.
#
# Trade-off, measured rather than asserted: with NOHASHDIR a reused object keeps
# the DW_AT_comp_dir of whichever build first cached it. Same source built in two
# directories, -g -gdwarf-5, CCACHE_BASEDIR set in both:
#
#   default              hits=0 misses=2   b/t.o comp_dir = .../b   (correct)
#   CCACHE_NOHASHDIR=1   hits=1 misses=1   b/t.o comp_dir = .../a   (stale)
#
# So debug info can name the directory of the build that first cached the object,
# until it is rebuilt. Accepted deliberately: throwing away several GB of KASAN
# objects on every path change is the worse trade for a cache this expensive to
# refill, and the path only moves when Armbian renames something.
#
# kernel_make_config is the documented hook for this: kernel-make.sh:79-83 lists
# common_make_envs[@] as available to it, and it runs before the make command is
# assembled at :99. Envs matter because the build runs under `env -i`.
function kernel_make_config__ysp_ccache_nohashdir() {
	display_alert "ysp-build-stamp" "CCACHE_NOHASHDIR=1 (worktree-path-independent cache)" "info"
	common_make_envs+=("CCACHE_NOHASHDIR=1")
}
