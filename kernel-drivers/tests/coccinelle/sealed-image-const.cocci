// SPDX-FileCopyrightText: 2026 Yi Ding
// SPDX-License-Identifier: GPL-2.0-only
// Coccinelle rule: no writes through sealed MPP register images.
//
// The Phase 5 seal publishes the image via smp_store_release and consumers
// must take `const struct rk_mpp_reg_image *` via rk_mpp_job_sealed_image().
// Any store through a sealed pointer (const image) is a bug, as is any
// helper that takes a sealed image and writes through it.
//
// This rule flags direct field stores and common helper calls that imply a
// post-seal write. The owning builder may write through
// `job->reg_builder.image` (non-const) before seal -- that path is allowlisted.

@r@
identifier img;
expression f, v;
position p;
@@

(
  img@p->f = v
|
  *img@p = v
|
  memcpy(img@p, ..., ...)
|
  memset(img@p, ..., ...)
)

@script:python depends on r@
img << r.img;
p << r.p;
@@

# Only flag when the base was obtained as a sealed image.
# A precise type-flow check would need full type info; this heuristic flags
# any store where the surrounding function took a const sealed image.
# Allowlist: builder functions that own `reg_builder`.
fn = p[0].current_element
if "reg_builder" not in coccilib.org_file:
    coccilib.report.print_report(p[0], "possible write through sealed MPP image -- sealed images are const after rk_mpp_reg_builder_seal; write through builder before seal")

// Narrower: direct check for const sealed image dereference in same function
@sealed@
const struct rk_mpp_reg_image *img;
position p;
@@

img@p->... = ...

@script:python depends on sealed@
p << sealed.p;
@@
coccilib.report.print_report(p[0], "write through const sealed MPP image pointer -- use builder before seal")
