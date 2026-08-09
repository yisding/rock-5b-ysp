#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: GPL-2.0-only
"""Inventory and guard failure-prone rewrite-driver ownership seams."""

from __future__ import annotations

import argparse
import collections
import dataclasses
import pathlib
import re
import subprocess
import sys
from collections.abc import Iterable


MPP_SOURCE = "drivers/video/rockchip/mpp-rewrite/mpp_rewrite.c"
RGA_SOURCE = "drivers/video/rockchip/rga-rewrite/rga_rewrite.c"
SOURCES = (MPP_SOURCE, RGA_SOURCE)

KUNIT_MARKERS = {
    MPP_SOURCE: "CONFIG_ROCKCHIP_MPP_REWRITE_KUNIT_TEST",
    RGA_SOURCE: "CONFIG_ROCKCHIP_RGA_REWRITE_KUNIT_TEST",
}

FUNCTION_RE = re.compile(
    r"\b([A-Za-z_]\w*)\s*\([^;{}]*\)\s*(?:__\w+(?:\([^)]*\))?\s*)*\{\s*$",
    re.DOTALL,
)
CONTROL_WORDS = {"if", "for", "while", "switch"}

POINTER_FIELD_TARGET = (
    r"(?:\b[A-Za-z_]\w*(?:\s*\[[^\]]+\])?\s*->|"
    r"\(\s*\*\s*[A-Za-z_]\w*\s*\)\s*\.)"
)
FIELD_TARGET = (
    rf"(?:{POINTER_FIELD_TARGET}|"
    r"\b[A-Za-z_]\w*(?:\s*\[[^\]]+\])?\s*\.)"
)
FIELD_ASSIGNMENT = r"(?:(?:(?:<<|>>)|[+\-*/%|&^])?=(?!=))"
FIELD_PUBLISHERS = (
    r"WRITE_ONCE(?:_NOCHECK)?|smp_store_(?:release|mb)|"
    r"(?:try_)?cmpxchg(?:64)?(?:_relaxed|_acquire|_release)?|"
    r"xchg(?:_relaxed|_acquire|_release|_local)?"
)


def field_write_re(
    fields: str,
    publishers: str = FIELD_PUBLISHERS,
    target: str = FIELD_TARGET,
) -> re.Pattern[str]:
    """Match direct and first-argument publisher writes to named fields."""

    return re.compile(
        rf"(?:(?:\+\+|--)\s*{target}(?:{fields})\b|"
        rf"{target}(?:{fields})\s*(?:\+\+|--|{FIELD_ASSIGNMENT})|"
        rf"\b(?:{publishers})\s*\(\s*&?\s*{target}(?:{fields})\b)"
    )

RESET_CALL_RE = re.compile(
    r"\breset_control_(?:(?:bulk_)?(?:assert|deassert|reset)|rearm)\s*\("
)
MPP_RESET_DOMAIN_OPERATION_RE = re.compile(
    r"\brk_mpp_reset_domain_(?:begin|finish|assert|deassert|"
    r"power_deassert|recovery_pulse)\s*\("
)
MPP_RESET_DOMAIN_MEMBER_RE = re.compile(
    r"\b(?:rk_mpp_reset_domain_(?:init|get_locked|register_member|"
    r"unregister_member|unregister_action)|rk_mpp_hw_init_reset_domain|"
    r"rk_mpp_reset_domains_destroy)\b"
)
MPP_RESET_DOMAIN_BINDING_RE = re.compile(
    r"\b(?:reset_domain|reset_domains|reset_domain_count|"
    r"reset_domain_link)\b"
)
MPP_RESET_DOMAIN_REGISTRY_ACCESS_RE = re.compile(r"\bdomain->(?:node|members)\b")
MPP_RESET_DOMAIN_STATE_DIRECT_WRITE_RE = field_write_re(
    r"reset_domain_(?:operation_pending|state|epoch|responsible|pulse_count|"
    r"deassert_count|refusal_count|overlap_count|member_count|"
    r"last_core_id|last_error)",
    publishers=rf"(?:{FIELD_PUBLISHERS}|atomic_(?!(?:read(?:_[A-Za-z0-9_]+)?|"
    rf"cond_read_(?:relaxed|acquire))\s*\()[A-Za-z0-9_]+)",
)
MPP_RESET_DOMAIN_STATE_WRITE_RE = re.compile(
    rf"(?:{MPP_RESET_DOMAIN_STATE_DIRECT_WRITE_RE.pattern}|"
    rf"\batomic_(?!(?:read(?:_[A-Za-z0-9_]+)?|"
    rf"cond_read_(?:relaxed|acquire))\s*\()[A-Za-z0-9_]+\s*\(\s*"
    rf"[^,]+,\s*&?\s*{FIELD_TARGET}reset_domain_operation_pending\b)"
)
MPP_RESET_DOMAIN_PENDING_ACCESS_RE = re.compile(
    r"\breset_domain_operation_pending\b"
)
MPP_RESET_BACKEND_ACCESS_RE = re.compile(r"\b(?:backend_ops|backend_data)\b")
MPP_CLUSTER_LIFECYCLE_RE = re.compile(
    r"\b(?:rk_mpp_cluster_(?:init|get_locked|register_member_locked|"
    r"unregister_member_locked)|rk_mpp_hw_init_cluster_locked|"
    r"rk_mpp_clusters_destroy)\s*\("
)
MPP_CLUSTER_TOPOLOGY_ENTRY_RE = re.compile(
    r"\brk_mpp_cluster_(?:rebuild_locked|"
    r"contains_published_view_locked|dma_group_count_locked)\s*\("
)
MPP_CLUSTER_RESET_ENTRY_RE = re.compile(
    r"\b(?:rk_mpp_cluster_(?:reset_group|reset_valid_locked)|"
    r"rk_mpp_rkvdec2_poll_reset_bus_idle)\s*\("
)
MPP_CLUSTER_POWER_LEASE_ENTRY_RE = re.compile(
    r"\b(?:rk_mpp_cluster_power_lease_(?:core_count|core|put|release|"
    r"move|acquire)|rk_mpp_rkvdec2_transfer_cluster_power_lease)\s*\("
)
MPP_CLUSTER_POWER_LEASE_ACCESS_RE = re.compile(
    r"\b(?:rkvdec_ccu_power_lease|power_lease_(?:refs|cluster|core_count|"
    r"cores))\b"
)
MPP_CLUSTER_RUNTIME_ENTRY_RE = re.compile(
    r"\brk_mpp_cluster_(?:validate_ccu|validate_job|"
    r"relink_ccu_tables_locked|ccu_has_jobs|relink_unfinished_locked|"
    r"prepare_resend_chain|collect_unfinished_jobs|add_ccu_job|"
    r"remove_ccu_job|transfer_power_lease|first_done_job|publish_ccu_job|"
    r"arm_soft_ccu|publish_soft_ccu_job|start_ccu_job|"
    r"collect_stop_cores)\s*\("
)
MPP_RECOVERY_ENTRY_RE = re.compile(
    r"\b(?:rk_mpp_recovery_result_(?:init|terminal)|"
    r"rk_mpp_cluster_(?:dma_set_add|collect_dma|refresh_dma|"
    r"isolated_dma_count|reset_usable)|"
    r"rk_mpp_hw_(?:reset_active|stop_active|finish_recovery|"
    r"stop_and_recover|recover_iommu_fault)|"
    r"rk_mpp_rkvdec2_(?:reset_soft_ccu_job|force_stop_ccu))\s*\("
)
MPP_RECOVERY_RESULT_FIELDS = (
    r"reset_effect|reset_epoch|reset_error|refresh_error|isolation_error|"
    r"dma_group_count|dma_group_refresh_count|dma_group_isolation_count|"
    r"quiesced|reusable"
)
MPP_RECOVERY_RESULT_ACCESS_RE = re.compile(
    rf"{FIELD_TARGET}(?:{MPP_RECOVERY_RESULT_FIELDS})\b"
)
MPP_RECOVERY_RESULT_WRITE_RE = field_write_re(MPP_RECOVERY_RESULT_FIELDS)
MPP_CLUSTER_PUBLICATION_ENTRY_RE = re.compile(
    r"\b(?:rk_mpp_cluster_(?:arm_soft_ccu|publish_soft_ccu_job|"
    r"publish_ccu_job|start_ccu_job)|"
    r"rk_mpp_rkvdec2_write_ccu_doorbell)\s*\("
)
MPP_CLUSTER_RUNNING_LIST_ACCESS_RE = re.compile(
    r"\b(?:rkvdec_ccu_jobs|rkvdec_ccu_node|rkvdec_ccu_listed)\b"
)
MPP_CCU_CHAIN_LINK_WRITE_RE = re.compile(
    r"\b[A-Za-z_]\w*\s*\[\s*info->next_word\s*\]\s*=(?!=)"
)
MPP_CCU_CONTROL_WRITE_RE = re.compile(
    r"\bwritel(?:_relaxed)?\s*\([^;]*RK_MPP_RKVDEC_CCU_(?:CTRL|"
    r"CFG_ADDR|LINK_MODE|CFG_DONE|WORK|WORK_MODE|CORE_WORK|CORE_STA|"
    r"CORE_IDLE|CORE_ERR)_BASE"
)
MPP_CLUSTER_BINDING_RE = re.compile(
    rf"(?:\b(?:cluster_link|cluster_count|clusters)\b|"
    rf"{POINTER_FIELD_TARGET}cluster\b)"
)
MPP_CLUSTER_OBJECT_TARGET = (
    rf"(?:\bcluster\s*->|\bclusters\s*\[[^\]]+\]\s*\.|"
    rf"{POINTER_FIELD_TARGET}clusters\s*\[[^\]]+\]\s*\.)"
)
MPP_CLUSTER_REGISTRY_ACCESS_RE = re.compile(
    rf"{MPP_CLUSTER_OBJECT_TARGET}(?:node|members|coordinator|reset_domain|"
    r"member_type|member_count|core_count)\b"
)
MPP_CLUSTER_POINTER_WRITE_RE = field_write_re(
    r"cluster|cluster_link", target=POINTER_FIELD_TARGET
)
MPP_CLUSTER_COUNT_WRITE_RE = field_write_re(r"cluster_count")
MPP_CLUSTER_REGISTRY_WRITE_RE = field_write_re(
    r"node|coordinator|reset_domain|member_type|member_count|core_count",
    target=MPP_CLUSTER_OBJECT_TARGET,
)
MPP_CLUSTER_STATE_WRITE_RE = re.compile(
    rf"(?:{MPP_CLUSTER_POINTER_WRITE_RE.pattern}|"
    rf"{MPP_CLUSTER_COUNT_WRITE_RE.pattern}|"
    rf"{MPP_CLUSTER_REGISTRY_WRITE_RE.pattern}|"
    r"\b(?:INIT_LIST_HEAD|list_add(?:_tail)?|list_del_init)\s*\([^;]*"
    r"(?:cluster->members|cluster_link)\b)"
)
MPP_CLUSTER_TOPOLOGY_INPUT_RE = re.compile(
    rf"{FIELD_TARGET}(?:hw_list|ccu_node|core_mask|rkvdec_ccu_mode|"
    r"rkvdec_ccu_jobs|rkvdec_ccu_node|dma_group|dma_domain|isolated|"
    r"iommu_domain)\b"
)
MPP_REGISTER_LEASE_ENTRY_RE = re.compile(
    r"\b(?:rk_mpp_cluster_publish_register_leases|"
    r"rk_mpp_hw_(?:invalidate_register_lease(?:_locked)?|"
    r"publish_register_lease(?:_locked)?|"
    r"irq_register_lease_snapshot_locked|clear_irq_record_locked|"
    r"irq_record_current_locked|record_irq_status|take_irq_status))\s*\("
)
MPP_REGISTER_LEASE_FIELDS = (
    r"regs_live_count|register_lease_live|register_reset_epoch|"
    r"register_lease_epoch|register_lease_generation|register_epoch|"
    r"register_generation|irq_status|irq_lease_recorded|irq_reset_epoch|"
    r"irq_generation|aux_irqs_active"
)
MPP_REGISTER_LEASE_ACCESS_RE = re.compile(
    rf"(?!\bevent\s*(?:->|\.)){FIELD_TARGET}"
    rf"(?:{MPP_REGISTER_LEASE_FIELDS})\b"
)
MPP_REGISTER_LEASE_WRITE_RE = field_write_re(MPP_REGISTER_LEASE_FIELDS)
MPP_ACTIVATION_OBJECT_TARGET = rf"{FIELD_TARGET}activation"
MPP_ACTIVATION_FIELD_TARGET = rf"{MPP_ACTIVATION_OBJECT_TARGET}\s*\."
MPP_ACTIVATION_ENTRY_RE = re.compile(
    r"\b(?:rk_mpp_activation_(?:init|generation|install_locked)|"
    r"rk_mpp_hw_(?:advance_active_generation_locked|install_active_locked|"
    r"prepare_active_retry))\s*\("
)
MPP_ACTIVATION_ACCESS_RE = re.compile(
    rf"(?:{MPP_ACTIVATION_OBJECT_TARGET}\b|"
    rf"{FIELD_TARGET}activation_generation_seq\b)"
)
MPP_ACTIVATION_PARENT_WRITE_RE = field_write_re(
    r"job", target=MPP_ACTIVATION_FIELD_TARGET
)
MPP_ACTIVATION_GENERATION_WRITE_RE = field_write_re(
    r"generation", target=MPP_ACTIVATION_FIELD_TARGET
)
MPP_ACTIVATION_DEADLINE_WRITE_RE = field_write_re(
    r"watchdog_deadline|watchdog_deadline_valid",
    target=MPP_ACTIVATION_FIELD_TARGET,
)
MPP_ACTIVATION_SEQUENCE_WRITE_RE = field_write_re(r"activation_generation_seq")
MPP_ACTIVATION_OBJECT_WRITE_RE = re.compile(
    rf"(?:{field_write_re(r'activation').pattern}|"
    rf"\b(?:memset|memcpy|memmove)\s*\(\s*&?\s*"
    rf"{MPP_ACTIVATION_OBJECT_TARGET}\b)"
)
MPP_ACTIVATION_WRITE_RE = re.compile(
    rf"(?:{MPP_ACTIVATION_PARENT_WRITE_RE.pattern}|"
    rf"{MPP_ACTIVATION_GENERATION_WRITE_RE.pattern}|"
    rf"{MPP_ACTIVATION_DEADLINE_WRITE_RE.pattern}|"
    rf"{MPP_ACTIVATION_SEQUENCE_WRITE_RE.pattern}|"
    rf"{MPP_ACTIVATION_OBJECT_WRITE_RE.pattern})"
)
MPP_ACTIVATION_WRITE_OWNER_RULES = (
    (MPP_ACTIVATION_OBJECT_WRITE_RE, set()),
    (
        MPP_ACTIVATION_PARENT_WRITE_RE,
        {"rk_mpp_activation_init", "rk_mpp_activation_install_locked"},
    ),
    (
        MPP_ACTIVATION_GENERATION_WRITE_RE,
        {"rk_mpp_activation_install_locked"},
    ),
    (
        MPP_ACTIVATION_DEADLINE_WRITE_RE,
        {"rk_mpp_activation_install_locked", "rk_mpp_hw_schedule_timeout"},
    ),
    (
        MPP_ACTIVATION_SEQUENCE_WRITE_RE,
        {"rk_mpp_hw_advance_active_generation_locked"},
    ),
)
ACTIVE_SLOT_WRITE_RE = field_write_re(
    r"active_job|active_generation|activation_generation_seq"
)
ACTIVE_SLOT_ACCESS_RE = re.compile(
    r"\b(?:active_job|active_generation|activation_generation_seq)\b"
)
DISPATCH_LEASE_WRITE_RE = field_write_re(
    r"rkvdec_session_dispatch|rkvdec_dispatch_active"
)
DISPATCH_LEASE_ACCESS_RE = re.compile(
    r"\b(?:rkvdec_session_dispatch|rkvdec_dispatch_active)\b"
)
POWER_FIELD_RE = re.compile(
    r"\b(?:rkvdec_ccu_power_lease|power_lease_(?:refs|cluster|core_count|"
    r"cores)|rkvdec_ccu_powered)\b"
)
MPP_POWER_TRANSITION_RE = re.compile(r"\brk_mpp_hw_power_(?:on|off)\s*\(")
MPP_POWER_BACKEND_RE = re.compile(
    r"\b(?:pm_runtime_[A-Za-z0-9_]+|(?:devm_)?clk_bulk_[A-Za-z0-9_]+)\s*\("
)
MPP_POWER_COUNT_WRITE_RE = re.compile(
    rf"\batomic_(?!(?:read(?:_[A-Za-z0-9_]+)?|"
    rf"cond_read_(?:relaxed|acquire))\s*\()[A-Za-z0-9_]+\s*\(\s*"
    rf"(?:&?\s*{FIELD_TARGET}power_count\b|"
    rf"[^,]+,\s*&?\s*{FIELD_TARGET}power_count\b)"
)
MPP_WATCHDOG_ARM_RE = re.compile(r"\brk_mpp_hw_schedule_timeout\s*\(")
RGA_WATCHDOG_ARM_RE = re.compile(r"\brk_rga_hw_schedule_timeout\s*\(")
MPP_IOMMU_RE = re.compile(
    r"\b(?:__rk_mpp_hw_refresh_iommu|rk_mpp_hw_refresh_iommu|"
    r"rk_mpp_cluster_refresh_dma|rk_mpp_dma_group_isolate)\s*\("
)
MPP_IOMMU_BACKEND_RE = re.compile(
    r"\b(?:vsi_iommu_refresh|iommu_flush_iotlb_all|iommu_attach_group)\s*\("
)
MPP_JOB_LIFECYCLE_WRITE_RE = field_write_re(r"result|state")
MPP_IRQ_SNAPSHOT_WRITE_RE = field_write_re(
    r"irq_status|av1_afbc_armed_generation|av1_afbc_status_generation|"
    r"av1_start_ns|av1_afbc_status_ns|av1_vcd_irq_ns|rkvenc_slice_done|"
    r"rkvenc_slice_overflow"
)
MPP_FAULT_SNAPSHOT_WRITE_RE = field_write_re(
    r"iommu_fault_pending|iommu_fault_generation"
)
MPP_TERMINAL_STATE_WRITE_RE = field_write_re(
    r"canceled|online|recovery_failed|terminally_stopped|"
    r"terminal_power_drained"
)
MPP_WATCHDOG_SNAPSHOT_WRITE_RE = re.compile(
    rf"(?:{field_write_re(r'timeout_job|timeout_generation|timeout_deadline_generation|timeout_deadline').pattern}|"
    rf"{field_write_re(r'watchdog_deadline|watchdog_deadline_valid', target=MPP_ACTIVATION_FIELD_TARGET).pattern})"
)
MPP_ACTIVATION_TIMING_WRITE_RE = field_write_re(r"hw_start_ns|hw_elapsed_ns")
MPP_OUTCOME_PUBLISH_RE = re.compile(
    r"\brk_mpp_job_publish_outcome(?:_locked)?\s*\("
)
MPP_TERMINAL_RE = re.compile(
    r"\b(?:rk_mpp_job_complete|rk_mpp_hw_(?:stop_active|finish_recovery|"
    r"stop_and_recover|recover_iommu_fault|recover_active|"
    r"abort_active(?:_recovery_locked)?)|"
    r"rk_mpp_rkvdec2_(?:reset_soft_ccu_job|force_stop_ccu))\s*\("
)
RGA_TASK_ADVANCE_RE = field_write_re(r"current_task")
RGA_EXEC_MAP_OWNER_RE = re.compile(
    r"\b(?:__rk_rga_job_release_execution_mappings|"
    r"rk_rga_job_(?:release_execution_mappings_powered|"
    r"discard_execution_mappings))\s*\("
)
RGA_MAP_RELEASE_PRIMITIVE_RE = re.compile(
    r"\b(?:rk_rga_unmap_userptr_sgt|dma_buf_unmap_attachment(?:_unlocked)?|"
    r"dma_buf_detach|rk_rga_job_(?:clear|release)_rga2_mmu)\s*\("
)
RGA_COMMAND_RELEASE_RE = re.compile(
    r"\brk_rga_job_free_cmd\s*\(|"
    r"\bdma_free_coherent\s*\([^;]*\bcmd_(?:dev|size|vaddr|dma)\b"
)
RGA_IRQ_SNAPSHOT_WRITE_RE = field_write_re(
    r"intr_status|hw_status|cmd_status|work_cycle|parse_status|irq_result|"
    r"irq_seen"
)
RGA_FAULT_SNAPSHOT_WRITE_RE = field_write_re(r"iommu_fault_generation")
RGA_TERMINAL_STATE_WRITE_RE = field_write_re(r"recovery_failed|removing")
RGA_JOB_OUTCOME_WRITE_RE = field_write_re(
    r"result|done",
    target=POINTER_FIELD_TARGET,
)
RGA_WATCHDOG_SNAPSHOT_WRITE_RE = field_write_re(
    r"timeout_job|timeout_generation"
)
RGA_ACTIVATION_TIMING_WRITE_RE = field_write_re(r"hw_start_ns|hw_elapsed_ns")
RGA_TERMINAL_RE = re.compile(
    r"\b(?:rk_rga_job_complete(?:_queued)?|rk_rga_hw_finish_job_locked|"
    r"rk_rga_hw_(?:recover_active|restore_active_after_reset_failure|"
    r"abort_(?:queued_jobs|jobs|session_jobs)|reset_for_recovery)|"
    r"rk_rga_job_abort_pending_acquire|"
    r"rk_rga_session_abort_pending_acquire_jobs|"
    r"rk_rga_session_abort_incompatible_pending_acquire_jobs(?:_slow)?|"
    r"rk_rga_abort_incompatible_pending_acquire_jobs|"
    r"rk_rga_session_abort_hw_jobs)\s*\("
)
RGA_COMMAND_WRITE_RE = re.compile(
    r"\brk_rga_cmd_write\s*\(|"
    r"\b(?:memset|memcpy)\s*\(\s*[A-Za-z_]\w*->cmd_vaddr\b"
)
MPP_START_WRITE_RE = re.compile(
    r"\bwritel(?:_relaxed)?\s*\([^;]*(?:RK_MPP_RKVENC_START_BASE|"
    r"RK_MPP_RKVDEC_START_BASE|RK_MPP_RKVDEC_CCU_CFG_DONE_BASE)|"
    r"\bwritel(?:_relaxed)?\s*\(\s*(?!0(?:[uUlL]*)?\s*,)[^;]*"
    r"RK_MPP_AV1_IRQ_BASE"
)
MPP_IRQ_ACK_WRITE_RE = re.compile(
    r"\bwritel(?:_relaxed)?\s*\(\s*0(?:[uUlL]*)?\s*,[^;]*"
    r"RK_MPP_AV1_IRQ_BASE"
)
RGA_START_WRITE_RE = re.compile(
    r"\brk_rga_write\s*\([^;]*(?:RK_RGA2_CMD_CTRL|RK_RGA3_CMD_CTRL)"
)
RAW_TASK_RE = re.compile(r"\bstruct\s+rga_req\s*\*|\bjob->tasks\b")
DEBUG_INTERFACE_RE = re.compile(
    r"\bdebugfs_create_(?:atomic_t|u32|bool|file)\s*\(|"
    r"\brk_(?:mpp|rga)_debugfs_create_(?:atomic64|core_counts|core_times|route_b)\s*\("
)
DEBUG_EVENT_DECLARATIONS = {
    MPP_SOURCE: ("enum rk_mpp_debug_event_type", "struct rk_mpp_debug_event"),
    RGA_SOURCE: ("enum rk_rga_debug_event_type", "struct rk_rga_debug_event"),
}


@dataclasses.dataclass(frozen=True, order=True)
class Signal:
    category: str
    source: str
    function: str
    text: str
    ordinal: int
    line: int = dataclasses.field(compare=False)

    @property
    def key(self) -> tuple[str, str, str, str, int]:
        return (self.category, self.source, self.function, self.text, self.ordinal)


@dataclasses.dataclass
class FunctionBody:
    name: str
    signature: str
    first_line: int
    statements: list[tuple[int, str]] = dataclasses.field(default_factory=list)

    @property
    def text(self) -> str:
        return " ".join(statement for _line, statement in self.statements)


def normalize(text: str) -> str:
    return " ".join(text.strip().split())


def strip_comments(lines: list[str]) -> list[str]:
    """Remove comments while preserving line count and string contents."""

    stripped: list[str] = []
    in_block = False
    for line in lines:
        output: list[str] = []
        index = 0
        quote: str | None = None
        while index < len(line):
            char = line[index]
            pair = line[index : index + 2]
            if in_block:
                if pair == "*/":
                    in_block = False
                    index += 2
                else:
                    index += 1
                continue
            if quote:
                output.append(char)
                if char == "\\" and index + 1 < len(line):
                    output.append(line[index + 1])
                    index += 2
                    continue
                if char == quote:
                    quote = None
                index += 1
                continue
            if pair == "/*":
                in_block = True
                index += 2
                continue
            if pair == "//":
                break
            if char in {'"', "'"}:
                quote = char
            output.append(char)
            index += 1
        stripped.append("".join(output))
    return stripped


def kunit_lines(lines: list[str], symbol: str) -> set[int]:
    marker = f"#if IS_ENABLED({symbol})"
    ignored: set[int] = set()
    for start, line in enumerate(lines):
        if line.strip() != marker:
            continue
        depth = 0
        for index in range(start, len(lines)):
            directive = lines[index].lstrip()
            ignored.add(index)
            if re.match(r"#\s*(?:if|ifdef|ifndef)\b", directive):
                depth += 1
            elif re.match(r"#\s*endif\b", directive):
                depth -= 1
                if depth == 0:
                    break
        else:
            raise ValueError(f"unterminated KUnit region at line {start + 1}")
    if not ignored:
        raise ValueError(f"missing KUnit region marker {marker}")
    return ignored


def brace_delta(text: str) -> int:
    """Count braces outside strings after comments have been removed."""

    delta = 0
    quote: str | None = None
    index = 0
    while index < len(text):
        char = text[index]
        if quote:
            if char == "\\":
                index += 2
                continue
            if char == quote:
                quote = None
        elif char in {'"', "'"}:
            quote = char
        elif char == "{":
            delta += 1
        elif char == "}":
            delta -= 1
        index += 1
    return delta


def parse_functions(source: pathlib.Path, symbol: str) -> list[FunctionBody]:
    raw_lines = source.read_text(encoding="utf-8").splitlines()
    lines = strip_comments(raw_lines)
    ignored = kunit_lines(lines, symbol)
    functions: list[FunctionBody] = []
    current: FunctionBody | None = None
    signature: list[str] = []
    statement: list[str] = []
    statement_line = 0
    depth = 0

    for index, line in enumerate(lines):
        if index in ignored:
            continue
        stripped = line.strip()
        if current is None:
            if not stripped or stripped.startswith("#"):
                signature.clear()
                continue
            signature.append(stripped)
            candidate = " ".join(signature)
            if "{" in stripped:
                match = FUNCTION_RE.search(candidate)
                if match and match.group(1) not in CONTROL_WORDS:
                    current = FunctionBody(
                        name=match.group(1),
                        signature=normalize(candidate),
                        first_line=index + 1,
                    )
                    functions.append(current)
                    depth = brace_delta(candidate)
                    signature.clear()
                    remainder = stripped.split("{", 1)[1]
                    if remainder:
                        statement = [remainder]
                        statement_line = index + 1
                    if depth <= 0:
                        current = None
                else:
                    signature.clear()
            elif ";" in stripped or len(signature) > 12:
                signature.clear()
            continue

        if stripped and not statement:
            statement_line = index + 1
        if stripped:
            statement.append(stripped)
        depth += brace_delta(line)
        joined = " ".join(statement)
        while ";" in joined:
            complete, joined = joined.split(";", 1)
            complete = normalize(complete + ";")
            if complete:
                current.statements.append((statement_line, complete))
            statement_line = index + 1
        statement = [joined] if joined.strip() else []
        if depth <= 0:
            current = None
            statement = []
            depth = 0

    return functions


def declaration_block(source: pathlib.Path, declaration: str) -> tuple[int, str]:
    lines = strip_comments(source.read_text(encoding="utf-8").splitlines())
    collecting = False
    depth = 0
    first_line = 0
    block: list[str] = []
    for index, line in enumerate(lines, start=1):
        if not collecting:
            if declaration not in line:
                continue
            collecting = True
            first_line = index
        block.append(line.strip())
        depth += brace_delta(line)
        if depth == 0 and ";" in line:
            return first_line, normalize(" ".join(block))
    raise ValueError(f"missing or unterminated declaration {declaration} in {source}")


def raw_signals(kernel_tree: pathlib.Path) -> list[tuple[str, str, str, str, int]]:
    found: list[tuple[str, str, str, str, int]] = []
    for relative in SOURCES:
        source = kernel_tree / relative
        if not source.is_file():
            raise ValueError(f"missing rewrite source: {source}")
        for declaration in DEBUG_EVENT_DECLARATIONS[relative]:
            line, text = declaration_block(source, declaration)
            found.append(
                ("debug-event-schema", relative, "<file-scope>", text, line)
            )
        if relative == MPP_SOURCE:
            line, text = declaration_block(source, "struct rk_mpp_activation {")
            found.append(
                ("mpp-activation-schema", relative, "<file-scope>", text, line)
            )
        functions = parse_functions(source, KUNIT_MARKERS[relative])
        for function in functions:
            command_writer = False
            for line, statement in function.statements:
                matches: list[tuple[str, re.Pattern[str]]] = []
                if relative == MPP_SOURCE:
                    matches.extend(
                        (
                            ("mpp-reset-control", RESET_CALL_RE),
                            (
                                "mpp-reset-domain-operation-entry",
                                MPP_RESET_DOMAIN_OPERATION_RE,
                            ),
                            (
                                "mpp-reset-domain-member-entry",
                                MPP_RESET_DOMAIN_MEMBER_RE,
                            ),
                            (
                                "mpp-reset-domain-binding-access",
                                MPP_RESET_DOMAIN_BINDING_RE,
                            ),
                            (
                                "mpp-reset-domain-registry-access",
                                MPP_RESET_DOMAIN_REGISTRY_ACCESS_RE,
                            ),
                            (
                                "mpp-reset-domain-state-write",
                                MPP_RESET_DOMAIN_STATE_WRITE_RE,
                            ),
                            (
                                "mpp-reset-domain-pending-access",
                                MPP_RESET_DOMAIN_PENDING_ACCESS_RE,
                            ),
                            (
                                "mpp-reset-backend-access",
                                MPP_RESET_BACKEND_ACCESS_RE,
                            ),
                            (
                                "mpp-cluster-lifecycle-entry",
                                MPP_CLUSTER_LIFECYCLE_RE,
                            ),
                            (
                                "mpp-cluster-topology-entry",
                                MPP_CLUSTER_TOPOLOGY_ENTRY_RE,
                            ),
                            (
                                "mpp-cluster-reset-entry",
                                MPP_CLUSTER_RESET_ENTRY_RE,
                            ),
                            (
                                "mpp-cluster-power-lease-entry",
                                MPP_CLUSTER_POWER_LEASE_ENTRY_RE,
                            ),
                            (
                                "mpp-cluster-power-lease-access",
                                MPP_CLUSTER_POWER_LEASE_ACCESS_RE,
                            ),
                            (
                                "mpp-cluster-runtime-entry",
                                MPP_CLUSTER_RUNTIME_ENTRY_RE,
                            ),
                            (
                                "mpp-recovery-entry",
                                MPP_RECOVERY_ENTRY_RE,
                            ),
                            (
                                "mpp-recovery-result-access",
                                MPP_RECOVERY_RESULT_ACCESS_RE,
                            ),
                            (
                                "mpp-recovery-result-write",
                                MPP_RECOVERY_RESULT_WRITE_RE,
                            ),
                            (
                                "mpp-cluster-publication-entry",
                                MPP_CLUSTER_PUBLICATION_ENTRY_RE,
                            ),
                            (
                                "mpp-cluster-running-list-access",
                                MPP_CLUSTER_RUNNING_LIST_ACCESS_RE,
                            ),
                            (
                                "mpp-ccu-chain-link-write",
                                MPP_CCU_CHAIN_LINK_WRITE_RE,
                            ),
                            (
                                "mpp-ccu-control-write",
                                MPP_CCU_CONTROL_WRITE_RE,
                            ),
                            (
                                "mpp-cluster-binding-access",
                                MPP_CLUSTER_BINDING_RE,
                            ),
                            (
                                "mpp-cluster-registry-access",
                                MPP_CLUSTER_REGISTRY_ACCESS_RE,
                            ),
                            (
                                "mpp-cluster-state-write",
                                MPP_CLUSTER_STATE_WRITE_RE,
                            ),
                            (
                                "mpp-cluster-topology-input-access",
                                MPP_CLUSTER_TOPOLOGY_INPUT_RE,
                            ),
                            (
                                "mpp-register-lease-entry",
                                MPP_REGISTER_LEASE_ENTRY_RE,
                            ),
                            (
                                "mpp-register-lease-access",
                                MPP_REGISTER_LEASE_ACCESS_RE,
                            ),
                            (
                                "mpp-register-lease-write",
                                MPP_REGISTER_LEASE_WRITE_RE,
                            ),
                            ("mpp-active-slot-access", ACTIVE_SLOT_ACCESS_RE),
                            ("mpp-active-slot-write", ACTIVE_SLOT_WRITE_RE),
                            (
                                "mpp-activation-entry",
                                MPP_ACTIVATION_ENTRY_RE,
                            ),
                            (
                                "mpp-activation-access",
                                MPP_ACTIVATION_ACCESS_RE,
                            ),
                            (
                                "mpp-activation-write",
                                MPP_ACTIVATION_WRITE_RE,
                            ),
                            ("mpp-dispatch-lease-access", DISPATCH_LEASE_ACCESS_RE),
                            ("mpp-dispatch-lease-write", DISPATCH_LEASE_WRITE_RE),
                            ("mpp-power-field", POWER_FIELD_RE),
                            (
                                "mpp-power-transition-entry",
                                MPP_POWER_TRANSITION_RE,
                            ),
                            ("mpp-power-backend-op", MPP_POWER_BACKEND_RE),
                            (
                                "mpp-power-count-write",
                                MPP_POWER_COUNT_WRITE_RE,
                            ),
                            ("mpp-watchdog-arm-entry", MPP_WATCHDOG_ARM_RE),
                            ("mpp-iommu-transition", MPP_IOMMU_RE),
                            ("mpp-iommu-backend-op", MPP_IOMMU_BACKEND_RE),
                            (
                                "mpp-job-lifecycle-write",
                                MPP_JOB_LIFECYCLE_WRITE_RE,
                            ),
                            (
                                "mpp-irq-snapshot-write",
                                MPP_IRQ_SNAPSHOT_WRITE_RE,
                            ),
                            (
                                "mpp-fault-snapshot-write",
                                MPP_FAULT_SNAPSHOT_WRITE_RE,
                            ),
                            (
                                "mpp-terminal-state-write",
                                MPP_TERMINAL_STATE_WRITE_RE,
                            ),
                            (
                                "mpp-watchdog-snapshot-write",
                                MPP_WATCHDOG_SNAPSHOT_WRITE_RE,
                            ),
                            (
                                "mpp-outcome-publish-entry",
                                MPP_OUTCOME_PUBLISH_RE,
                            ),
                            (
                                "mpp-activation-timing-write",
                                MPP_ACTIVATION_TIMING_WRITE_RE,
                            ),
                            ("mpp-terminal-entry", MPP_TERMINAL_RE),
                            ("mpp-irq-ack-write", MPP_IRQ_ACK_WRITE_RE),
                            ("start-doorbell-write", MPP_START_WRITE_RE),
                        )
                    )
                else:
                    matches.extend(
                        (
                            ("rga-active-slot-access", ACTIVE_SLOT_ACCESS_RE),
                            ("rga-active-slot-write", ACTIVE_SLOT_WRITE_RE),
                            ("rga-exec-map-owner", RGA_EXEC_MAP_OWNER_RE),
                            (
                                "rga-map-release-primitive",
                                RGA_MAP_RELEASE_PRIMITIVE_RE,
                            ),
                            ("rga-command-release", RGA_COMMAND_RELEASE_RE),
                            (
                                "rga-irq-snapshot-write",
                                RGA_IRQ_SNAPSHOT_WRITE_RE,
                            ),
                            (
                                "rga-fault-snapshot-write",
                                RGA_FAULT_SNAPSHOT_WRITE_RE,
                            ),
                            (
                                "rga-terminal-state-write",
                                RGA_TERMINAL_STATE_WRITE_RE,
                            ),
                            (
                                "rga-job-outcome-write",
                                RGA_JOB_OUTCOME_WRITE_RE,
                            ),
                            (
                                "rga-watchdog-snapshot-write",
                                RGA_WATCHDOG_SNAPSHOT_WRITE_RE,
                            ),
                            ("rga-watchdog-arm-entry", RGA_WATCHDOG_ARM_RE),
                            (
                                "rga-activation-timing-write",
                                RGA_ACTIVATION_TIMING_WRITE_RE,
                            ),
                            ("rga-terminal-entry", RGA_TERMINAL_RE),
                            ("rga-task-advance", RGA_TASK_ADVANCE_RE),
                            ("start-doorbell-write", RGA_START_WRITE_RE),
                        )
                    )
                    if RGA_COMMAND_WRITE_RE.search(statement):
                        command_writer = True
                for category, pattern in matches:
                    if pattern.search(statement):
                        found.append(
                            (category, relative, function.name, statement, line)
                        )
                if DEBUG_INTERFACE_RE.search(statement):
                    found.append(
                        (
                            "debug-interface-registration",
                            relative,
                            function.name,
                            statement,
                            line,
                        )
                    )
            if relative == RGA_SOURCE:
                if command_writer:
                    found.append(
                        (
                            "rga-command-writer",
                            relative,
                            function.name,
                            function.signature,
                            function.first_line,
                        )
                    )
                if "emit" in function.name and RAW_TASK_RE.search(
                    f"{function.signature} {function.text}"
                ):
                    found.append(
                        (
                            "rga-raw-task-emitter",
                            relative,
                            function.name,
                            function.signature,
                            function.first_line,
                        )
                    )
    return found


def audit_tree(kernel_tree: pathlib.Path) -> list[Signal]:
    occurrences: collections.Counter[tuple[str, str, str, str]] = (
        collections.Counter()
    )
    signals: list[Signal] = []
    for category, source, function, text, line in raw_signals(kernel_tree):
        identity = (category, source, function, text)
        occurrences[identity] += 1
        signals.append(
            Signal(
                category=category,
                source=source,
                function=function,
                text=normalize(text),
                ordinal=occurrences[identity],
                line=line,
            )
        )
    return sorted(signals)


def encode(signal: Signal) -> str:
    return "\t".join(
        (
            signal.category,
            signal.source,
            signal.function,
            str(signal.ordinal),
            signal.text,
        )
    )


def read_baseline(
    path: pathlib.Path,
) -> tuple[
    set[tuple[str, str, str, str, int]],
    set[str],
    set[str],
]:
    baseline: set[tuple[str, str, str, str, int]] = set()
    source_heads: set[str] = set()
    categories: set[str] = set()
    for line_number, raw in enumerate(
        path.read_text(encoding="utf-8").splitlines(), start=1
    ):
        if raw.startswith("# source-head\t"):
            source_heads.add(raw.split("\t", 1)[1])
            continue
        if not raw or raw.startswith("#"):
            continue
        fields = raw.split("\t", 4)
        if len(fields) != 5:
            raise ValueError(f"{path}:{line_number}: expected five TSV fields")
        category, source, function, ordinal_text, text = fields
        try:
            ordinal = int(ordinal_text)
        except ValueError as error:
            raise ValueError(
                f"{path}:{line_number}: invalid ordinal {ordinal_text!r}"
            ) from error
        baseline.add((category, source, function, text, ordinal))
        categories.add(category)
    return baseline, source_heads, categories


def git_head(tree: pathlib.Path) -> str:
    result = subprocess.run(
        ["git", "-C", str(tree), "rev-parse", "HEAD"],
        capture_output=True,
        text=True,
        check=False,
    )
    return result.stdout.strip() if result.returncode == 0 else "unknown"


def baseline_lines(
    trees: Iterable[pathlib.Path], signals: Iterable[Signal]
) -> Iterable[str]:
    yield "# Rewrite ownership inventory; new signals fail, resolved signals are allowed."
    for head in sorted({git_head(tree) for tree in trees}):
        yield f"# source-head\t{head}"
    yield "# category\tsource\tfunction\tordinal\tnormalized source signal"
    yield from (encode(signal) for signal in signals)


def parse_args(argv: list[str]) -> argparse.Namespace:
    default_baseline = pathlib.Path(__file__).with_name(
        "rewrite-ownership-source-audit-baseline.tsv"
    )
    parser = argparse.ArgumentParser(
        description="Audit rewrite ownership seams against a checked inventory"
    )
    parser.add_argument("kernel_tree", nargs="+", type=pathlib.Path)
    parser.add_argument("--baseline", type=pathlib.Path, default=default_baseline)
    parser.add_argument("--emit-baseline", action="store_true")
    parser.add_argument("--update-baseline", action="store_true")
    return parser.parse_args(argv)


def category_counts(signals: Iterable[Signal]) -> str:
    counts = collections.Counter(signal.category for signal in signals)
    return ", ".join(f"{category}={counts[category]}" for category in sorted(counts))


def ownership_violations(signals: Iterable[Signal]) -> list[Signal]:
    return [
        signal
        for signal in signals
        if signal.category == "mpp-activation-write"
        and any(
            pattern.search(signal.text) and signal.function not in owners
            for pattern, owners in MPP_ACTIVATION_WRITE_OWNER_RULES
        )
    ]


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.emit_baseline and args.update_baseline:
        print("choose only one baseline-output mode", file=sys.stderr)
        return 2
    try:
        trees = [(tree.resolve(), audit_tree(tree.resolve())) for tree in args.kernel_tree]
        violations = [
            (tree, signal)
            for tree, signals in trees
            for signal in ownership_violations(signals)
        ]
        if violations:
            for tree, signal in violations:
                print(
                    f"OWNER\t{signal.category}\t{tree / signal.source}:"
                    f"{signal.line}\t{signal.function}\t{signal.text}",
                    file=sys.stderr,
                )
            raise ValueError("activation fields written outside their owners")
        output = (
            "\n".join(
                baseline_lines((tree for tree, _signals in trees), trees[0][1])
            )
            + "\n"
        )
        if args.emit_baseline:
            print(output, end="")
            return 0
        if args.update_baseline:
            args.baseline.write_text(output, encoding="utf-8")
            print(f"updated {args.baseline} with {len(trees[0][1])} signals")
            return 0
        baseline, baseline_heads, baseline_categories = read_baseline(args.baseline)
        if not baseline_heads:
            raise ValueError(f"{args.baseline}: missing source-head pin")
    except (OSError, ValueError) as error:
        print(f"rewrite ownership source audit: {error}", file=sys.stderr)
        return 2

    failed = False
    reference = {signal.key for signal in trees[0][1]}
    for tree, signals in trees:
        keys = {signal.key for signal in signals}
        head = git_head(tree)
        new = [signal for signal in signals if signal.key not in baseline]
        resolved = baseline - keys
        current_categories = {signal.category for signal in signals}
        print(
            f"{tree}: {len(signals)} ownership signals, {len(new)} new, "
            f"{len(resolved)} baseline entries absent"
        )
        print(f"  {category_counts(signals)}")
        for signal in new:
            failed = True
            print(
                f"NEW\t{signal.category}\t{signal.source}:{signal.line}\t"
                f"{signal.function}\t{signal.text}",
                file=sys.stderr,
            )
        if baseline_heads and head not in baseline_heads:
            failed = True
            print(
                f"{tree}: source HEAD {head} is not pinned by {args.baseline}",
                file=sys.stderr,
            )
        missing_categories = baseline_categories - current_categories
        if missing_categories:
            failed = True
            print(
                f"{tree}: baseline categories disappeared: "
                f"{', '.join(sorted(missing_categories))}",
                file=sys.stderr,
            )
        if keys != reference:
            failed = True
            print(
                f"{tree}: ownership signals differ from {trees[0][0]}",
                file=sys.stderr,
            )
    if failed:
        print("rewrite ownership source audit failed", file=sys.stderr)
        return 1
    print("rewrite ownership source audit passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
