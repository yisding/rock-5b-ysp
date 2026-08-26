// SPDX-FileCopyrightText: 2026 Yi Ding
// SPDX-License-Identifier: GPL-2.0-only
// Coccinelle rule: START/doorbell MMIO only inside publish_and_start owners.
//
// All MPP and RGA doorbell/START writes must go through the typed
// publish_and_start helpers which arm the watchdog, publish the lease, and
// issue the doorbell in one linearized operation. Any writel/write to a
// START or doorbell register outside those helpers is a bypass that breaks
// generation and barrier ordering.
//
// Allowlist: functions whose name contains "publish_and_start" are the
// designated owners. KUnit test helpers that synthesize register images are
// excluded via IS_ENABLED(CONFIG_ROCKCHIP_*_REWRITE_KUNIT_TEST) -- the
// ownership audit's production-text stripping already handles that, but
// coccinelle runs on raw files so we keep the check explicit here.

@r@
identifier fn;
expression base, val;
position p;
@@

fn(...) {
  <...
(
  writel@p(val, base)
|
  writel_relaxed@p(val, base)
|
  rk_mpp_rkvdec2_write_ccu_doorbell@p(...)
|
  rk_rga_write@p(...)
)
  ...>
}

@script:python depends on r@
fn << r.fn;
p << r.p;
@@

if "publish_and_start" not in fn and "kunit" not in fn.lower():
    # Heuristic: only flag writes that target known START/doorbell offsets
    # A full check would match the register base; this flags all writel
    # outside owners for triage (allowlist covers the intended owners).
    coccilib.report.print_report(p[0], "doorbell/START MMIO outside publish_and_start owner -- route through rk_mpp_*_publish_and_start or rk_rga*_execution_publish_and_start")
