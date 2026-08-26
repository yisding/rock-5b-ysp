// SPDX-FileCopyrightText: 2026 Yi Ding
// SPDX-License-Identifier: GPL-2.0-only
// Coccinelle rule: reset success must be followed by refresh/isolation proof
// before re-admission.
//
// Catches the defect class where a function calls reset_control_assert/
// deassert/reset and on success returns or proceeds to scheduling without
// first calling a DMA/IOMMU refresh or terminal-isolation helper.
// The writer-inventory gate already catches new writers of reset_control;
// this rule adds the ordering constraint: success -> refresh -> admission.
//
// Allowlist: functions whose name contains "reset_domain" or
// "cluster_refresh" are domain owners and may call reset_control directly.
// All other callers must go through the domain helpers.

@r@
identifier fn;
expression domain, hw;
@@

fn(...) {
  <...
  reset_control_assert@r1(hw->resets) == 0
  ... when != rk_mpp_cluster_refresh_dma(...)
        when != rk_mpp_hw_refresh_iommu(...)
        when != rk_mpp_hw_terminal_isolate(...)
        when != rk_mpp_refresh_hw_support_locked(...)
  return 0;
  ...>
}

@script:python depends on r@
fn << r.fn;
r1 << r.r1;
@@

if "reset_domain" not in fn and "cluster_refresh" not in fn:
    coccilib.report.print_report(r1[0], "reset success without following refresh/isolation proof before return -- must call cluster_refresh or hw_refresh_iommu")
