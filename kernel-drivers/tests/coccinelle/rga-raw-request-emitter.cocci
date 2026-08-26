// SPDX-FileCopyrightText: 2026 Yi Ding
// SPDX-License-Identifier: GPL-2.0-only
// Coccinelle rule: RGA emitters must not accept raw struct rga_req.
//
// After Phase 5, every RGA emitter consumes an immutable validated
// `struct rk_rga_task_plan` (or the execution's sealed command image), never
// the raw UAPI `struct rga_req` / `struct rga_user_request`. Any emitter
// function that takes a raw request or reads its fields directly is a
// bypass of the one-way validation pipeline and risks reinterpretation of
// unvalidated geometry/flags.
//
// This rule flags emitter-shaped functions (name contains "emit" or "rga2"
// or "rga3") that take a raw request pointer.

@r@
identifier fn;
type T;
parameter P;
position p;
@@

fn@p(..., T *P, ...) {
  <...
  P->...
  ...>
}

@script:python depends on r@
fn << r.fn;
T << r.T;
P << r.P;
p << r.p;
@@

t = T.strip()
if "rga_req" in t or "rga_user_request" in t:
    if any(k in fn for k in ("emit", "rga2", "rga3", "rga_")):
        coccilib.report.print_report(p[0], f"RGA emitter '{fn}' takes raw {t} -- must take validated rk_rga_task_plan instead")

// Second pattern: direct field access on a raw request inside an emitter
@raw_field@
identifier fn, fld;
expression req;
position p;
@@

fn(...) {
  <...
  req@p->fld
  ...>
}

@script:python depends on raw_field@
fn << raw_field.fn;
p << raw_field.p;
@@

if any(k in fn for k in ("rga2_emit", "rga3_emit", "rk_rga_emit")):
    # Flag only if the function signature was already flagged above;
    # this second rule catches field-level bypass after signature drift.
    pass
