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
