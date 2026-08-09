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
MPP_RECOVERY_RESULT_ACCESS_OWNERS = {
    "rk_mpp_activation_claim_quarantine",
    "rk_mpp_activation_finish_terminal_locked",
    "rk_mpp_activation_finish_retry_locked",
    "rk_mpp_activation_storage_released",
    "rk_mpp_cluster_refresh_dma",
    "rk_mpp_hw_abort_job",
    "rk_mpp_hw_commit_active_retry",
    "rk_mpp_hw_finish_recovery",
    "rk_mpp_hw_recover_active",
    "rk_mpp_hw_recover_iommu_fault",
    "rk_mpp_hw_reset_active",
    "rk_mpp_hw_stop_active",
    "rk_mpp_recovery_result_terminal",
    "rk_mpp_rkvdec2_force_stop_ccu",
    "rk_mpp_rkvdec2_prepare_ccu_retry_job",
    "rk_mpp_rkvdec2_restart_ccu_unfinished_jobs",
    "rk_mpp_rkvdec2_reset_soft_ccu_job",
}
MPP_RECOVERY_RESULT_WRITE_OWNERS = {
    "rk_mpp_cluster_refresh_dma",
    "rk_mpp_hw_finish_recovery",
    "rk_mpp_hw_recover_iommu_fault",
    "rk_mpp_hw_reset_active",
    "rk_mpp_hw_stop_active",
    "rk_mpp_recovery_result_terminal",
    "rk_mpp_rkvdec2_force_stop_ccu",
}
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
ACTIVATION_FIELD_PUBLISHERS = rf"(?:{FIELD_PUBLISHERS}|memset|memcpy|memmove)"
MPP_ACTIVATION_OBJECT_TARGET = rf"{FIELD_TARGET}activation_storage"
MPP_ACTIVATION_FIELDS = (
    r"job|selected_hw|slot_state|transition_reason|generation|"
    r"watchdog_deadline|watchdog_deadline_valid|closure|quarantine_link|"
    r"quarantine_ref_count|quarantine_generation"
)
ACTIVATION_POINTER_QUALIFIERS = (
    r"(?:(?:const|volatile|restrict|__restrict|__restrict__)\b\s*)*"
)
ACTIVATION_CAST_OPERAND = r"(?:[^();]|\([^()]*\))+"


def activation_field_target(
    aliases: set[str],
    typedefs: set[str] | None = None,
    pointer_typedefs: set[str] | None = None,
) -> str:
    """Return field targets for embedded and typed activation pointers."""

    escaped = "|".join(sorted(re.escape(alias) for alias in aliases))
    type_names = [r"struct\s+rk_mpp_activation"]
    type_names.extend(sorted(re.escape(name) for name in (typedefs or set())))
    activation_type = rf"(?:{'|'.join(type_names)})"
    pointer_type_names = sorted(
        re.escape(name) for name in (pointer_typedefs or set())
    )
    pointer_cast_type = (
        rf"(?:(?:const\s+)?{activation_type}\s*\*\s*"
        rf"{ACTIVATION_POINTER_QUALIFIERS}"
        + (
            rf"|(?:const\s+)?(?:{'|'.join(pointer_type_names)})\s*"
            rf"{ACTIVATION_POINTER_QUALIFIERS}"
            if pointer_type_names
            else ""
        )
        + r")"
    )
    direct = (
        rf"(?:\b(?:{escaped})\s*->|"
        rf"\(\s*\*\s*(?:{escaped})\s*\)\s*\.|"
        rf"\b(?:{escaped})\s*\[[^\]]+\]\s*\.)"
        if escaped
        else r"(?!)"
    )
    slot_pointer = (
        rf"{FIELD_TARGET}(?:active_activation|timeout_activation|"
        r"current_activation)\b"
    )
    slot = (
        rf"(?:{slot_pointer}\s*->|"
        rf"\(\s*\*\s*{slot_pointer}\s*\)\s*\.|"
        rf"{slot_pointer}\s*\[[^\]]+\]\s*\.)"
    )
    cast = (
        rf"\(\s*\(\s*{pointer_cast_type}\)\s*"
        rf"{ACTIVATION_CAST_OPERAND}\)\s*->"
    )
    return rf"(?:{MPP_ACTIVATION_OBJECT_TARGET}\s*\.|{direct}|{slot}|{cast})"


MPP_ACTIVATION_FIELD_TARGET = activation_field_target({"activation"})
MPP_ACTIVATION_ENTRY_RE = re.compile(
    r"\b(?:rk_mpp_activation_(?:storage_init|init|job|generation|"
    r"install_locked|storage_released|closure_pristine|"
    r"observation_(?:pristine|matches)|alloc_successor|"
    r"free_unpublished|finish_retry(?:_locked)?|claim_(?:job|put|quarantine)|"
    r"finish_(?:terminal|observed_terminal)(?:_locked)?)|"
    r"rk_mpp_job_(?:activation_storage_released|"
    r"activation_hardware_released|release_activation_storage)|"
    r"rk_mpp_hw_(?:advance_active_generation_locked|install_active_locked|"
    r"claim_active_locked|restore_active_locked|restore_or_quarantine|"
    r"job_is_quarantined|active_retry_(?:ready|matches_locked)|"
    r"commit_active_retry)|rk_mpp_service_has_quarantined_activation)\s*\("
)
MPP_RETRY_TOKEN_ACCESS_RE = re.compile(
    r"\btoken\s*(?:->|\.)\s*(?:activation|generation)\b"
)
MPP_RETRY_TOKEN_WRITE_RE = field_write_re(
    r"activation|generation",
    publishers=ACTIVATION_FIELD_PUBLISHERS,
    target=r"\btoken\s*(?:->|\.)\s*",
)
MPP_QUARANTINE_LOCK_ACCESS_RE = re.compile(rf"{FIELD_TARGET}quarantine_lock\b")
MPP_QUARANTINE_LIST_ACCESS_RE = re.compile(
    rf"{FIELD_TARGET}quarantined_activations\b"
)
MPP_QUARANTINE_LIST_WRITE_RE = re.compile(
    rf"(?:{field_write_re('quarantined_activations', publishers=ACTIVATION_FIELD_PUBLISHERS).pattern}|"
    r"\b(?:INIT_LIST_HEAD|list_(?:add(?:_tail)?|del(?:_init)?|move(?:_tail)?|"
    r"replace(?:_init)?|splice(?:_init)?(?:_tail)?|swap))\s*\([^;]*"
    rf"{FIELD_TARGET}quarantined_activations\b)"
)
MPP_QUARANTINE_COUNT_ACCESS_RE = re.compile(rf"{FIELD_TARGET}quarantine_count\b")
MPP_QUARANTINE_COUNT_WRITE_RE = re.compile(
    rf"(?:{field_write_re('quarantine_count', publishers=ACTIVATION_FIELD_PUBLISHERS).pattern}|"
    r"\batomic_(?:set|inc|dec|add|sub|xchg|cmpxchg)\s*\([^;]*"
    rf"{FIELD_TARGET}quarantine_count\b)"
)
MPP_CLOSURE_DIRECT_TARGET = rf"{FIELD_TARGET}closure\s*\."
MPP_CLOSURE_TERMINAL_TARGET = rf"{MPP_CLOSURE_DIRECT_TARGET}terminal\s*\."
MPP_CLOSURE_TERMINAL_ACCESS_RE = re.compile(
    rf"{MPP_CLOSURE_DIRECT_TARGET}terminal\b"
)
MPP_CLOSURE_TERMINAL_WRITE_RE = re.compile(
    rf"(?:{field_write_re('terminal', publishers=ACTIVATION_FIELD_PUBLISHERS, target=MPP_CLOSURE_DIRECT_TARGET).pattern}|"
    rf"{field_write_re('result|status|valid', publishers=ACTIVATION_FIELD_PUBLISHERS, target=MPP_CLOSURE_TERMINAL_TARGET).pattern})"
)
MPP_CLOSURE_SCOPE_ACCESS_RE = re.compile(
    rf"{MPP_CLOSURE_DIRECT_TARGET}terminal_scope\b"
)
MPP_CLOSURE_SCOPE_WRITE_RE = field_write_re(
    r"terminal_scope",
    publishers=ACTIVATION_FIELD_PUBLISHERS,
    target=MPP_CLOSURE_DIRECT_TARGET,
)
MPP_CLOSURE_OBSERVATION_TARGET = rf"{MPP_CLOSURE_DIRECT_TARGET}observation\s*\."
MPP_CLOSURE_OBSERVATION_ACCESS_RE = re.compile(
    rf"{MPP_CLOSURE_DIRECT_TARGET}observation\b"
)
MPP_CLOSURE_OBSERVATION_WRITE_RE = re.compile(
    rf"(?:{field_write_re('observation', publishers=ACTIVATION_FIELD_PUBLISHERS, target=MPP_CLOSURE_DIRECT_TARGET).pattern}|"
    rf"{field_write_re('kind|hw_status|bus_idle_status|bus_idle_checked|valid', publishers=ACTIVATION_FIELD_PUBLISHERS, target=MPP_CLOSURE_OBSERVATION_TARGET).pattern})"
)
MPP_QUARANTINE_LINK_ACCESS_RE = re.compile(
    rf"{FIELD_TARGET}quarantine_link\b"
)
MPP_QUARANTINE_LINK_NODE_TARGET = rf"{FIELD_TARGET}quarantine_link\s*\."
MPP_QUARANTINE_LINK_WRITE_RE = re.compile(
    rf"(?:{field_write_re('quarantine_link', publishers=ACTIVATION_FIELD_PUBLISHERS).pattern}|"
    rf"{field_write_re('next|prev', publishers=ACTIVATION_FIELD_PUBLISHERS, target=MPP_QUARANTINE_LINK_NODE_TARGET).pattern}|"
    r"\b(?:INIT_LIST_HEAD|list_(?:add(?:_tail)?|del(?:_init)?|move(?:_tail)?|"
    r"replace(?:_init)?|splice(?:_init)?(?:_tail)?|swap))\s*\([^;]*"
    rf"{FIELD_TARGET}quarantine_link\b)"
)
MPP_QUARANTINE_REF_ACCESS_RE = re.compile(
    rf"{FIELD_TARGET}quarantine_ref_count\b"
)
MPP_QUARANTINE_REF_WRITE_RE = field_write_re(
    r"quarantine_ref_count", publishers=ACTIVATION_FIELD_PUBLISHERS
)
MPP_QUARANTINE_GENERATION_ACCESS_RE = re.compile(
    rf"{FIELD_TARGET}quarantine_generation\b"
)
MPP_QUARANTINE_GENERATION_WRITE_RE = field_write_re(
    r"quarantine_generation", publishers=ACTIVATION_FIELD_PUBLISHERS
)
MPP_ACTIVATION_ACCESS_RE = re.compile(
    rf"(?:{MPP_ACTIVATION_OBJECT_TARGET}\b|"
    rf"{MPP_ACTIVATION_FIELD_TARGET}(?:{MPP_ACTIVATION_FIELDS})\b|"
    rf"{FIELD_TARGET}activation_generation_seq\b)"
)
MPP_ACTIVATION_PARENT_WRITE_RE = field_write_re(
    r"job",
    publishers=ACTIVATION_FIELD_PUBLISHERS,
    target=MPP_ACTIVATION_FIELD_TARGET,
)
MPP_ACTIVATION_GENERATION_WRITE_RE = field_write_re(
    r"generation",
    publishers=ACTIVATION_FIELD_PUBLISHERS,
    target=MPP_ACTIVATION_FIELD_TARGET,
)
MPP_ACTIVATION_DEADLINE_WRITE_RE = field_write_re(
    r"watchdog_deadline|watchdog_deadline_valid",
    publishers=ACTIVATION_FIELD_PUBLISHERS,
    target=MPP_ACTIVATION_FIELD_TARGET,
)
MPP_ACTIVATION_SLOT_STATE_WRITE_RE = field_write_re(
    r"slot_state",
    publishers=ACTIVATION_FIELD_PUBLISHERS,
    target=MPP_ACTIVATION_FIELD_TARGET,
)
MPP_ACTIVATION_REASON_WRITE_RE = field_write_re(
    r"transition_reason",
    publishers=ACTIVATION_FIELD_PUBLISHERS,
    target=MPP_ACTIVATION_FIELD_TARGET,
)
MPP_SELECTED_HW_ACCESS_RE = re.compile(
    rf"{MPP_ACTIVATION_FIELD_TARGET}selected_hw\b"
)
MPP_SELECTED_HW_WRITE_RE = field_write_re(
    r"selected_hw",
    publishers=ACTIVATION_FIELD_PUBLISHERS,
    target=MPP_ACTIVATION_FIELD_TARGET,
)
MPP_CURRENT_ACTIVATION_ACCESS_RE = re.compile(
    rf"{FIELD_TARGET}current_activation\b"
)
MPP_CURRENT_ACTIVATION_WRITE_RE = re.compile(
    rf"(?:(?:\+\+|--)\s*{FIELD_TARGET}current_activation\b(?!\s*->)|"
    rf"{FIELD_TARGET}current_activation\b(?!\s*->)"
    rf"\s*(?:\+\+|--|{FIELD_ASSIGNMENT})|"
    rf"\b(?:{ACTIVATION_FIELD_PUBLISHERS})\s*\(\s*&?\s*"
    rf"{FIELD_TARGET}current_activation\b(?!\s*->))"
)
MPP_ACTIVATION_STORAGE_ACCESS_RE = re.compile(
    rf"{FIELD_TARGET}activation_storage\b"
)
MPP_ACTIVATION_LIST_ACCESS_RE = re.compile(rf"{FIELD_TARGET}activations\b")
MPP_ACTIVATION_LINK_ACCESS_RE = re.compile(
    rf"{MPP_ACTIVATION_FIELD_TARGET}job_link\b"
)
MPP_ACTIVATION_LIST_NODE_TARGET = rf"{FIELD_TARGET}activations\s*\."
MPP_ACTIVATION_LINK_NODE_TARGET = (
    rf"{MPP_ACTIVATION_FIELD_TARGET}job_link\s*\."
)
MPP_ACTIVATION_LIST_WRITE_RE = re.compile(
    rf"(?:{field_write_re('activations', publishers=ACTIVATION_FIELD_PUBLISHERS).pattern}|"
    rf"{field_write_re('next|prev', publishers=ACTIVATION_FIELD_PUBLISHERS, target=MPP_ACTIVATION_LIST_NODE_TARGET).pattern}|"
    r"\b(?:INIT_LIST_HEAD|list_(?:add(?:_tail)?|del(?:_init)?|"
    r"move(?:_tail)?|replace(?:_init)?|splice(?:_init)?(?:_tail)?|swap|"
    r"rotate_to_front|cut_position|bulk_move_tail))\s*\([^;]*"
    rf"{FIELD_TARGET}activations\b)"
)
MPP_ACTIVATION_LINK_WRITE_RE = re.compile(
    rf"(?:{field_write_re('job_link', publishers=ACTIVATION_FIELD_PUBLISHERS, target=MPP_ACTIVATION_FIELD_TARGET).pattern}|"
    rf"{field_write_re('next|prev', publishers=ACTIVATION_FIELD_PUBLISHERS, target=MPP_ACTIVATION_LINK_NODE_TARGET).pattern}|"
    r"\b(?:INIT_LIST_HEAD|list_(?:add(?:_tail)?|del(?:_init)?|"
    r"move(?:_tail)?|replace(?:_init)?|splice(?:_init)?(?:_tail)?|swap|"
    r"rotate_to_front|cut_position|bulk_move_tail))\s*\([^;]*"
    rf"{MPP_ACTIVATION_FIELD_TARGET}job_link\b)"
)
MPP_ACTIVATION_SEQUENCE_WRITE_RE = field_write_re(
    r"activation_generation_seq", publishers=ACTIVATION_FIELD_PUBLISHERS
)


def activation_object_write_re(
    aliases: set[str],
    typedefs: set[str] | None = None,
    pointer_typedefs: set[str] | None = None,
) -> re.Pattern[str]:
    """Match whole embedded activation writes through every typed alias."""

    escaped = "|".join(sorted(re.escape(alias) for alias in aliases))
    type_names = [r"struct\s+rk_mpp_activation"]
    type_names.extend(sorted(re.escape(name) for name in (typedefs or set())))
    activation_type = rf"(?:{'|'.join(type_names)})"
    pointer_type_names = sorted(
        re.escape(name) for name in (pointer_typedefs or set())
    )
    pointer_cast_type = (
        rf"(?:(?:const\s+)?{activation_type}\s*\*\s*"
        rf"{ACTIVATION_POINTER_QUALIFIERS}"
        + (
            rf"|(?:const\s+)?(?:{'|'.join(pointer_type_names)})\s*"
            rf"{ACTIVATION_POINTER_QUALIFIERS}"
            if pointer_type_names
            else ""
        )
        + r")"
    )
    alias_lvalue = (
        rf"(?:\*\s*(?:{escaped})\b|"
        rf"\(\s*\*\s*(?:{escaped})\s*\)|"
        rf"\b(?:{escaped})\s*\[[^\]]+\])"
        if escaped
        else r"(?!)"
    )
    slot_pointer = (
        rf"{FIELD_TARGET}(?:active_activation|timeout_activation|"
        r"current_activation)\b"
    )
    slot_lvalue = (
        rf"(?:\*\s*{slot_pointer}|"
        rf"\(\s*\*\s*{slot_pointer}\s*\)|"
        rf"{slot_pointer}\s*\[[^\]]+\])"
    )
    cast_pointer = (
        rf"\(\s*{pointer_cast_type}\)\s*{ACTIVATION_CAST_OPERAND}"
    )
    cast_lvalue = rf"\*\s*{cast_pointer}"
    object_lvalue = (
        rf"(?:{MPP_ACTIVATION_OBJECT_TARGET}\b(?!\s*\.)|"
        rf"{alias_lvalue}|{slot_lvalue}|{cast_lvalue})"
    )
    pointer_declaration = (
        rf"(?:const\s+)?{activation_type}\s*\*\s*"
        rf"{ACTIVATION_POINTER_QUALIFIERS}(?:{escaped})\s*="
        if escaped
        else r"(?!)"
    )
    memory_target = (
        rf"(?:&?\s*{MPP_ACTIVATION_OBJECT_TARGET}\b(?!\s*\.)|"
        rf"&?\s*\*?\s*\b(?:{escaped})\b(?:\s*\[[^\]]+\])?|"
        rf"&?\s*\*?\s*{slot_pointer}(?:\s*\[[^\]]+\])?|"
        rf"{cast_pointer})"
        if escaped
        else rf"(?:&?\s*{MPP_ACTIVATION_OBJECT_TARGET}\b(?!\s*\.)|"
        rf"&?\s*\*?\s*{slot_pointer}(?:\s*\[[^\]]+\])?|{cast_pointer})"
    )
    return re.compile(
        rf"(?:^(?![^;]*\b{pointer_declaration})"
        rf"(?!\s*(?:const\s+)?struct\s+rk_mpp_activation\b)[^;]*?"
        rf"(?:(?:\+\+|--)\s*{object_lvalue}|"
        rf"{object_lvalue}\s*(?:\+\+|--|{FIELD_ASSIGNMENT}))|"
        rf"\b(?:{FIELD_PUBLISHERS})\s*\(\s*&?\s*{object_lvalue}|"
        rf"\b(?:memset|memcpy|memmove)\s*\(\s*{memory_target}\s*,)"
    )


MPP_ACTIVATION_OBJECT_WRITE_RE = activation_object_write_re({"activation"})
MPP_ACTIVATION_WRITE_RE = re.compile(
    rf"(?:{MPP_ACTIVATION_PARENT_WRITE_RE.pattern}|"
    rf"{MPP_ACTIVATION_GENERATION_WRITE_RE.pattern}|"
    rf"{MPP_ACTIVATION_DEADLINE_WRITE_RE.pattern}|"
    rf"{MPP_ACTIVATION_SLOT_STATE_WRITE_RE.pattern}|"
    rf"{MPP_ACTIVATION_REASON_WRITE_RE.pattern}|"
    rf"{MPP_SELECTED_HW_WRITE_RE.pattern}|"
    rf"{MPP_ACTIVATION_SEQUENCE_WRITE_RE.pattern}|"
    rf"{MPP_ACTIVATION_OBJECT_WRITE_RE.pattern})"
)
MPP_ACTIVATION_PARENT_WRITE_OWNERS = {
    "rk_mpp_activation_storage_init",
}
MPP_ACTIVATION_GENERATION_WRITE_OWNERS = {
    "rk_mpp_activation_storage_init",
    "rk_mpp_activation_install_locked",
}
MPP_ACTIVATION_DEADLINE_WRITE_OWNERS = {
    "rk_mpp_activation_storage_init",
    "rk_mpp_activation_install_locked",
    "rk_mpp_hw_schedule_timeout",
}
MPP_ACTIVATION_SLOT_STATE_ACCESS_OWNERS = {
    "rk_mpp_activation_claim_quarantine",
    "rk_mpp_activation_claim_put",
    "rk_mpp_activation_finish_terminal_locked",
    "rk_mpp_activation_finish_observed_terminal_locked",
    "rk_mpp_activation_storage_init",
    "rk_mpp_activation_install_locked",
    "rk_mpp_activation_observation_matches",
    "rk_mpp_activation_storage_released",
    "rk_mpp_activation_free_unpublished",
    "rk_mpp_hw_claim_active_locked",
    "rk_mpp_hw_restore_active_locked",
    "rk_mpp_hw_active_retry_matches_locked",
    "rk_mpp_hw_commit_active_retry",
    "rk_mpp_hw_job_is_quarantined",
    "rk_mpp_activation_finish_retry_locked",
}
MPP_ACTIVATION_SLOT_STATE_WRITE_OWNERS = {
    "rk_mpp_activation_claim_quarantine",
    "rk_mpp_activation_finish_terminal_locked",
    "rk_mpp_activation_finish_observed_terminal_locked",
    "rk_mpp_activation_storage_init",
    "rk_mpp_activation_install_locked",
    "rk_mpp_hw_claim_active_locked",
    "rk_mpp_hw_restore_active_locked",
    "rk_mpp_hw_commit_active_retry",
}
MPP_ACTIVATION_REASON_ACCESS_OWNERS = MPP_ACTIVATION_SLOT_STATE_ACCESS_OWNERS
MPP_ACTIVATION_REASON_WRITE_OWNERS = MPP_ACTIVATION_SLOT_STATE_WRITE_OWNERS
MPP_ACTIVATION_CLOSURE_ACCESS_OWNERS = {
    "rk_mpp_activation_claim_quarantine",
    "rk_mpp_activation_closure_pristine",
    "rk_mpp_activation_finish_terminal_locked",
    "rk_mpp_activation_finish_observed_terminal_locked",
    "rk_mpp_activation_finish_retry_locked",
    "rk_mpp_activation_observation_matches",
    "rk_mpp_activation_observation_pristine",
    "rk_mpp_activation_storage_init",
    "rk_mpp_activation_storage_released",
    "rk_mpp_hw_commit_active_retry",
}
MPP_ACTIVATION_CLOSURE_WRITE_OWNERS = {
    "rk_mpp_activation_storage_init",
}
MPP_ACTIVATION_CLOSURE_STATE_WRITE_OWNERS = {
    "rk_mpp_activation_claim_quarantine",
    "rk_mpp_activation_finish_terminal_locked",
    "rk_mpp_activation_finish_observed_terminal_locked",
    "rk_mpp_activation_finish_retry_locked",
    "rk_mpp_hw_commit_active_retry",
}
MPP_ACTIVATION_CLOSURE_GROUP_WRITE_OWNERS = {
    "rk_mpp_activation_claim_quarantine",
    "rk_mpp_activation_finish_terminal_locked",
    "rk_mpp_hw_commit_active_retry",
}
MPP_ACTIVATION_CLOSURE_CORE_WRITE_OWNERS = {
    "rk_mpp_activation_claim_quarantine",
    "rk_mpp_activation_finish_terminal_locked",
    "rk_mpp_activation_finish_retry_locked",
}
MPP_RETRY_TOKEN_ACCESS_OWNERS = {
    "rk_mpp_activation_finish_retry",
    "rk_mpp_activation_finish_retry_locked",
    "rk_mpp_hw_commit_active_retry",
}
MPP_RETRY_TOKEN_WRITE_OWNERS = {
    "rk_mpp_activation_finish_retry_locked",
    "rk_mpp_hw_commit_active_retry",
}
MPP_ACTIVATION_CLOSURE_TERMINAL_ACCESS_OWNERS = {
    "rk_mpp_activation_claim_quarantine",
    "rk_mpp_activation_finish_terminal_locked",
    "rk_mpp_activation_storage_released",
}
MPP_ACTIVATION_CLOSURE_TERMINAL_WRITE_OWNERS = {
    "rk_mpp_activation_claim_quarantine",
    "rk_mpp_activation_finish_terminal_locked",
}
MPP_ACTIVATION_CLOSURE_SCOPE_ACCESS_OWNERS = (
    MPP_ACTIVATION_CLOSURE_TERMINAL_ACCESS_OWNERS
)
MPP_ACTIVATION_CLOSURE_SCOPE_WRITE_OWNERS = (
    MPP_ACTIVATION_CLOSURE_TERMINAL_WRITE_OWNERS
)
MPP_ACTIVATION_CLOSURE_OBSERVATION_ACCESS_OWNERS = {
    "rk_mpp_activation_finish_observed_terminal_locked",
    "rk_mpp_activation_observation_matches",
    "rk_mpp_activation_observation_pristine",
    "rk_mpp_activation_storage_released",
}
MPP_ACTIVATION_CLOSURE_OBSERVATION_WRITE_OWNERS = {
    "rk_mpp_activation_finish_observed_terminal_locked",
}
MPP_CLAIM_TOKEN_ACCESS_OWNERS = {
    "rk_mpp_activation_claim_job",
    "rk_mpp_activation_claim_put",
    "rk_mpp_activation_claim_quarantine",
    "rk_mpp_activation_finish_terminal_locked",
    "rk_mpp_activation_finish_observed_terminal",
    "rk_mpp_activation_finish_observed_terminal_locked",
    "rk_mpp_hw_claim_active_locked",
    "rk_mpp_hw_restore_active_locked",
}
MPP_CLAIM_TOKEN_WRITE_OWNERS = {
    "rk_mpp_activation_claim_put",
    "rk_mpp_activation_claim_quarantine",
    "rk_mpp_hw_claim_active_locked",
    "rk_mpp_hw_restore_active_locked",
}
MPP_ACTIVATION_QUARANTINE_ACCESS_OWNERS = {
    "rk_mpp_activation_claim_quarantine",
    "rk_mpp_activation_storage_init",
}
MPP_ACTIVATION_QUARANTINE_WRITE_OWNERS = (
    MPP_ACTIVATION_QUARANTINE_ACCESS_OWNERS
)
MPP_QUARANTINE_LOCK_ACCESS_OWNERS = {
    "rk_mpp_activation_claim_quarantine",
    "rk_mpp_service_has_quarantined_activation",
    "rk_mpp_service_state_init",
}
MPP_QUARANTINE_LIST_ACCESS_OWNERS = MPP_QUARANTINE_LOCK_ACCESS_OWNERS
MPP_QUARANTINE_LIST_WRITE_OWNERS = {
    "rk_mpp_activation_claim_quarantine",
    "rk_mpp_service_state_init",
}
MPP_QUARANTINE_COUNT_ACCESS_OWNERS = {
    "rk_mpp_activation_claim_quarantine",
    "rk_mpp_runtime_register",
    "rk_mpp_service_state_init",
}
MPP_QUARANTINE_COUNT_WRITE_OWNERS = {
    "rk_mpp_activation_claim_quarantine",
    "rk_mpp_service_state_init",
}
MPP_SELECTED_HW_ACCESS_OWNERS = {
    "rk_mpp_activation_claim_quarantine",
    "rk_mpp_activation_finish_terminal_locked",
    "rk_mpp_activation_finish_observed_terminal_locked",
    "rk_mpp_activation_finish_retry_locked",
    "rk_mpp_activation_storage_init",
    "rk_mpp_activation_free_unpublished",
    "rk_mpp_activation_install_locked",
    "rk_mpp_av1_submit",
    "rk_mpp_av1_validate",
    "rk_mpp_cluster_arm_soft_ccu",
    "rk_mpp_cluster_collect_stop_cores",
    "rk_mpp_cluster_power_lease_acquire",
    "rk_mpp_cluster_publish_ccu_job",
    "rk_mpp_cluster_publish_soft_ccu_job",
    "rk_mpp_cluster_relink_ccu_tables_locked",
    "rk_mpp_cluster_relink_unfinished_locked",
    "rk_mpp_cluster_remove_ccu_job",
    "rk_mpp_cluster_start_ccu_job",
    "rk_mpp_cluster_validate_job",
    "rk_mpp_count_dispatched_core",
    "rk_mpp_count_scheduled_core",
    "rk_mpp_count_started_core",
    "rk_mpp_debug_record_job",
    "rk_mpp_debug_state_show",
    "rk_mpp_hw_abort_queued_matching",
    "rk_mpp_hw_active_retry_matches_locked",
    "rk_mpp_hw_commit_active_retry",
    "rk_mpp_hw_job_is_quarantined",
    "rk_mpp_job_apply_rcb_info",
    "rk_mpp_job_apply_reg_offsets",
    "rk_mpp_job_activation_hardware_released",
    "rk_mpp_job_drop_hw",
    "rk_mpp_job_get_hw",
    "rk_mpp_job_hold_explicit_iova",
    "rk_mpp_job_hw_available_locked",
    "rk_mpp_job_note_hw_done",
    "rk_mpp_job_queue_current_locked",
    "rk_mpp_job_read_regs",
    "rk_mpp_job_reject_reg",
    "rk_mpp_job_rkvdec_rcb_enabled",
    "rk_mpp_job_select_hw",
    "rk_mpp_job_submit",
    "rk_mpp_job_translate_reg",
    "rk_mpp_job_unqueue_locked",
    "rk_mpp_job_validate_write_regs",
    "rk_mpp_job_write_regs",
    "rk_mpp_rkvdec2_acquire_soft_ccu",
    "rk_mpp_rkvdec2_prepare_ccu_descriptor",
    "rk_mpp_rkvdec2_prepare_ccu_regs",
    "rk_mpp_rkvdec2_publish_and_start_core",
    "rk_mpp_rkvdec2_read_perf_sel",
    "rk_mpp_rkvdec2_release_link_table",
    "rk_mpp_rkvdec2_reserve_link_table",
    "rk_mpp_rkvdec2_reset_soft_ccu_job",
    "rk_mpp_rkvdec2_stage_link_table",
    "rk_mpp_rkvdec2_submit",
    "rk_mpp_rkvdec2_validate",
    "rk_mpp_rkvenc2_dchs_lifecycle_lock",
    "rk_mpp_rkvenc2_dchs_patch",
    "rk_mpp_rkvenc2_publish_and_start",
    "rk_mpp_rkvenc2_submit",
    "rk_mpp_rkvenc2_validate",
    "rk_mpp_scheduler_take_job",
    "rk_mpp_scheduler_work",
}
MPP_SELECTED_HW_WRITE_OWNERS = {
    "rk_mpp_activation_storage_init",
    "rk_mpp_hw_commit_active_retry",
    "rk_mpp_job_select_hw",
    "rk_mpp_job_drop_hw",
}
MPP_CURRENT_ACTIVATION_ACCESS_OWNERS = {
    "__rk_mpp_hw_restore_active_job",
    "rk_mpp_activation_finish_observed_terminal_locked",
    "rk_mpp_activation_finish_retry_locked",
    "rk_mpp_activation_finish_terminal_locked",
    "rk_mpp_activation_init",
    "rk_mpp_av1_submit",
    "rk_mpp_av1_validate",
    "rk_mpp_cluster_arm_soft_ccu",
    "rk_mpp_cluster_collect_stop_cores",
    "rk_mpp_cluster_power_lease_acquire",
    "rk_mpp_cluster_publish_ccu_job",
    "rk_mpp_cluster_publish_soft_ccu_job",
    "rk_mpp_cluster_relink_ccu_tables_locked",
    "rk_mpp_cluster_relink_unfinished_locked",
    "rk_mpp_cluster_remove_ccu_job",
    "rk_mpp_cluster_start_ccu_job",
    "rk_mpp_cluster_validate_job",
    "rk_mpp_count_dispatched_core",
    "rk_mpp_count_scheduled_core",
    "rk_mpp_count_started_core",
    "rk_mpp_debug_record_job",
    "rk_mpp_debug_state_show",
    "rk_mpp_dispatch_lease_acquire_locked",
    "rk_mpp_dispatch_lease_owned_locked",
    "rk_mpp_hw_abort_queued_matching",
    "rk_mpp_hw_active_job_is",
    "rk_mpp_hw_active_retry_matches_locked",
    "rk_mpp_hw_claim_active_locked",
    "rk_mpp_hw_clear_active_job",
    "rk_mpp_hw_commit_active_retry",
    "rk_mpp_hw_job_is_quarantined",
    "rk_mpp_hw_install_active_locked",
    "rk_mpp_hw_restore_active_locked",
    "rk_mpp_hw_take_active_if",
    "rk_mpp_job_apply_rcb_info",
    "rk_mpp_job_apply_reg_offsets",
    "rk_mpp_job_get_hw",
    "rk_mpp_job_hold_explicit_iova",
    "rk_mpp_job_hw_available_locked",
    "rk_mpp_job_note_hw_done",
    "rk_mpp_job_queue_current_locked",
    "rk_mpp_job_read_regs",
    "rk_mpp_job_reject_reg",
    "rk_mpp_job_release_activation_storage",
    "rk_mpp_job_rkvdec_rcb_enabled",
    "rk_mpp_job_select_hw",
    "rk_mpp_job_submit",
    "rk_mpp_job_translate_reg",
    "rk_mpp_job_unqueue_locked",
    "rk_mpp_job_validate_write_regs",
    "rk_mpp_job_write_regs",
    "rk_mpp_rkvdec2_acquire_soft_ccu",
    "rk_mpp_rkvdec2_prepare_ccu_descriptor",
    "rk_mpp_rkvdec2_prepare_ccu_regs",
    "rk_mpp_rkvdec2_prepare_ccu_retry_job",
    "rk_mpp_rkvdec2_publish_and_start_core",
    "rk_mpp_rkvdec2_read_perf_sel",
    "rk_mpp_rkvdec2_release_link_table",
    "rk_mpp_rkvdec2_reserve_link_table",
    "rk_mpp_rkvdec2_reset_soft_ccu_job",
    "rk_mpp_rkvdec2_stage_link_table",
    "rk_mpp_rkvdec2_submit",
    "rk_mpp_rkvdec2_validate",
    "rk_mpp_rkvenc2_dchs_lifecycle_lock",
    "rk_mpp_rkvenc2_dchs_patch",
    "rk_mpp_rkvenc2_publish_and_start",
    "rk_mpp_rkvenc2_submit",
    "rk_mpp_rkvenc2_validate",
    "rk_mpp_scheduler_take_job",
    "rk_mpp_scheduler_work",
}
MPP_CURRENT_ACTIVATION_WRITE_OWNERS = {
    "rk_mpp_activation_init",
    "rk_mpp_hw_commit_active_retry",
    "rk_mpp_job_release_activation_storage",
}
MPP_ACTIVATION_STORAGE_ACCESS_OWNERS = {
    "rk_mpp_activation_init",
    "rk_mpp_job_release_activation_storage",
}
MPP_ACTIVATION_LIST_ACCESS_OWNERS = {
    "rk_mpp_activation_init",
    "rk_mpp_dispatch_lease_released",
    "rk_mpp_job_activation_storage_released",
    "rk_mpp_job_activation_hardware_released",
    "rk_mpp_job_drop_hw",
    "rk_mpp_job_release_activation_storage",
    "rk_mpp_hw_commit_active_retry",
}
MPP_ACTIVATION_LIST_WRITE_OWNERS = {
    "rk_mpp_activation_init",
    "rk_mpp_job_release_activation_storage",
    "rk_mpp_hw_commit_active_retry",
}
MPP_ACTIVATION_LINK_ACCESS_OWNERS = {
    "rk_mpp_activation_claim_quarantine",
    "rk_mpp_activation_finish_terminal_locked",
    "rk_mpp_activation_finish_observed_terminal_locked",
    "rk_mpp_activation_finish_retry_locked",
    "rk_mpp_activation_storage_init",
    "rk_mpp_activation_init",
    "rk_mpp_activation_free_unpublished",
    "rk_mpp_dispatch_lease_released",
    "rk_mpp_hw_restore_active_locked",
    "rk_mpp_job_release_activation_storage",
    "rk_mpp_hw_commit_active_retry",
    "rk_mpp_rkvdec2_restart_ccu_unfinished_jobs",
}
MPP_ACTIVATION_LINK_WRITE_OWNERS = {
    "rk_mpp_activation_storage_init",
    "rk_mpp_activation_init",
    "rk_mpp_job_release_activation_storage",
    "rk_mpp_hw_commit_active_retry",
}
MPP_ACTIVATION_ALLOCATION_OWNERS = {
    "rk_mpp_activation_alloc_successor",
}
MPP_ACTIVATION_FREE_OWNERS = {
    "rk_mpp_activation_free_unpublished",
    "rk_mpp_job_release_activation_storage",
}
MPP_RKVDEC_CCU_ACCESS_RE = re.compile(rf"{FIELD_TARGET}rkvdec_ccu\b")
MPP_RKVDEC_CCU_WRITE_RE = field_write_re(r"rkvdec_ccu")
MPP_RKVDEC_CCU_ACCESS_OWNERS = {
    "rk_mpp_activation_claim_quarantine",
    "rk_mpp_activation_finish_terminal_locked",
    "rk_mpp_activation_finish_observed_terminal_locked",
    "rk_mpp_cluster_add_ccu_job",
    "rk_mpp_cluster_arm_soft_ccu",
    "rk_mpp_cluster_power_lease_acquire",
    "rk_mpp_cluster_publish_ccu_job",
    "rk_mpp_cluster_publish_soft_ccu_job",
    "rk_mpp_cluster_start_ccu_job",
    "rk_mpp_cluster_validate_job",
    "rk_mpp_hw_abort_job",
    "rk_mpp_hw_get_active_ccu_if",
    "rk_mpp_hw_get_active_ccu_for_job",
    "rk_mpp_hw_recover_active",
    "rk_mpp_rkvdec2_acquire_soft_ccu",
    "rk_mpp_rkvdec2_fill_ccu_descriptor",
    "rk_mpp_rkvdec2_prepare_ccu_descriptor",
    "rk_mpp_rkvdec2_prepare_ccu_retry_job",
    "rk_mpp_rkvdec2_publish_and_start_core",
    "rk_mpp_rkvdec2_release_link_table",
    "rk_mpp_rkvdec2_reserve_link_table",
    "rk_mpp_rkvdec2_reset_soft_ccu_job",
    "rk_mpp_rkvdec2_restart_ccu_job",
    "rk_mpp_rkvdec2_submit",
}
MPP_RKVDEC_CCU_WRITE_OWNERS = {
    "rk_mpp_rkvdec2_release_link_table",
    "rk_mpp_rkvdec2_reserve_link_table",
    "rk_mpp_rkvdec2_acquire_soft_ccu",
    "rk_mpp_rkvdec2_submit",
}
RGA_ACTIVE_SLOT_WRITE_RE = field_write_re(
    r"active_job|active_generation|activation_generation_seq"
)
RGA_ACTIVE_SLOT_ACCESS_RE = re.compile(
    r"\b(?:active_job|active_generation|activation_generation_seq)\b"
)
MPP_ACTIVE_ACTIVATION_ACCESS_RE = re.compile(
    rf"{FIELD_TARGET}active_activation\b"
)
MPP_ACTIVE_ACTIVATION_WRITE_RE = field_write_re(
    r"active_activation", publishers=ACTIVATION_FIELD_PUBLISHERS
)
MPP_TIMEOUT_ACTIVATION_ACCESS_RE = re.compile(
    rf"{FIELD_TARGET}timeout_activation\b"
)
MPP_TIMEOUT_ACTIVATION_WRITE_RE = field_write_re(
    r"timeout_activation", publishers=ACTIVATION_FIELD_PUBLISHERS
)
MPP_ACTIVATION_SEQUENCE_ACCESS_RE = re.compile(
    rf"{FIELD_TARGET}activation_generation_seq\b"
)
MPP_TIMEOUT_GENERATION_ACCESS_RE = re.compile(
    rf"{FIELD_TARGET}timeout_generation\b"
)
MPP_TIMEOUT_GENERATION_WRITE_RE = field_write_re(
    r"timeout_generation", publishers=ACTIVATION_FIELD_PUBLISHERS
)
MPP_SLOT_LEGACY_RE = re.compile(rf"{FIELD_TARGET}(?:active_job|timeout_job)\b")
MPP_ACTIVE_ACTIVATION_ACCESS_OWNERS = {
    "rk_mpp_activation_finish_terminal_locked",
    "rk_mpp_activation_finish_observed_terminal_locked",
    "rk_mpp_hw_active_activation_locked",
    "rk_mpp_hw_install_active_locked",
    "rk_mpp_hw_claim_active_locked",
    "rk_mpp_hw_restore_active_locked",
    "rk_mpp_activation_install_locked",
    "rk_mpp_hw_active_retry_matches_locked",
    "rk_mpp_hw_commit_active_retry",
}
MPP_ACTIVE_ACTIVATION_WRITE_OWNERS = {
    "rk_mpp_hw_install_active_locked",
    "rk_mpp_hw_claim_active_locked",
    "rk_mpp_hw_restore_active_locked",
    "rk_mpp_hw_commit_active_retry",
}

MPP_ACTIVE_TRANSITION_ENTRY_RE = re.compile(
    r"\b(?P<callee>rk_mpp_activation_(?:storage_init|init|install_locked|"
    r"storage_released|alloc_successor|free_unpublished)|"
    r"rk_mpp_job_(?:activation_storage_released|"
    r"activation_hardware_released|release_activation_storage)|"
    r"rk_mpp_hw_(?:advance_active_generation_locked|"
    r"install_active_locked|claim_active_locked|restore_active_locked|"
    r"active_retry_(?:ready|matches_locked)|commit_active_retry))\s*\("
)
MPP_ACTIVE_TRANSITION_ENTRY_OWNERS = {
    "rk_mpp_activation_storage_init": {
        "rk_mpp_activation_init",
        "rk_mpp_activation_alloc_successor",
    },
    "rk_mpp_activation_init": {"rk_mpp_batch_get_job"},
    "rk_mpp_activation_alloc_successor": {
        "rk_mpp_rkvdec2_restart_ccu_unfinished_jobs"
    },
    "rk_mpp_activation_free_unpublished": {
        "rk_mpp_rkvdec2_restart_ccu_unfinished_jobs"
    },
    "rk_mpp_activation_install_locked": {
        "rk_mpp_hw_install_active_locked",
        "rk_mpp_hw_commit_active_retry",
    },
    "rk_mpp_activation_storage_released": {
        "rk_mpp_activation_claim_put",
        "rk_mpp_job_activation_storage_released",
    },
    "rk_mpp_job_activation_storage_released": {"rk_mpp_job_release"},
    "rk_mpp_job_activation_hardware_released": {"rk_mpp_job_release"},
    "rk_mpp_job_release_activation_storage": {"rk_mpp_job_release"},
    "rk_mpp_hw_advance_active_generation_locked": {
        "rk_mpp_activation_install_locked"
    },
    "rk_mpp_hw_install_active_locked": {"rk_mpp_hw_begin_active_job"},
    "rk_mpp_hw_claim_active_locked": {
        "rk_mpp_hw_clear_active_job",
        "rk_mpp_hw_take_active_job",
        "rk_mpp_hw_take_irq_job",
        "rk_mpp_hw_take_active_if",
        "rk_mpp_hw_take_active_if_generation",
        "rk_mpp_hw_take_iommu_fault_job",
    },
    "rk_mpp_hw_restore_active_locked": {
        "__rk_mpp_hw_restore_active_job",
        "rk_mpp_hw_restore_or_quarantine",
    },
    "rk_mpp_hw_active_retry_matches_locked": {
        "rk_mpp_hw_active_retry_ready",
        "rk_mpp_hw_commit_active_retry",
    },
    "rk_mpp_hw_active_retry_ready": {
        "rk_mpp_rkvdec2_prepare_ccu_retry_job"
    },
    "rk_mpp_hw_commit_active_retry": {
        "rk_mpp_rkvdec2_prepare_ccu_retry_job"
    },
}
MPP_CLAIM_REASON_BY_OWNER = {
    "rk_mpp_hw_clear_active_job": "reason",
    "rk_mpp_hw_take_active_job": "reason",
    "rk_mpp_hw_take_irq_job": "RK_MPP_TRANSITION_IRQ",
    "rk_mpp_hw_take_active_if": "RK_MPP_TRANSITION_CCU_DONE",
    "rk_mpp_hw_take_active_if_generation": "RK_MPP_TRANSITION_TIMEOUT",
    "rk_mpp_hw_take_iommu_fault_job": "RK_MPP_TRANSITION_IOMMU_FAULT",
}
MPP_SLOT_LEGACY_HELPER_RE = re.compile(r"\brk_mpp_hw_take_active_locked\s*\(")
MPP_TIMEOUT_ACTIVATION_OWNERS = {
    "rk_mpp_hw_take_timeout_activation",
    "rk_mpp_hw_schedule_timeout",
}
MPP_ACTIVATION_SEQUENCE_OWNERS = {
    "rk_mpp_hw_advance_active_generation_locked",
}
MPP_TIMEOUT_GENERATION_OWNERS = {
    "rk_mpp_hw_take_timeout_activation",
    "rk_mpp_hw_schedule_timeout",
}
DISPATCH_OWNER_ACCESS_RE = re.compile(
    rf"{FIELD_TARGET}rkvdec_dispatch_owner\b"
)
DISPATCH_OWNER_WRITE_RE = field_write_re(r"rkvdec_dispatch_owner")
DISPATCH_LEGACY_RE = re.compile(
    r"\b(?:rkvdec_session_dispatch|rkvdec_dispatch_active)\b"
)
DISPATCH_OWNER_ACCESS_OWNERS = {
    "rk_mpp_dispatch_lease_released",
    "rk_mpp_dispatch_lease_active_locked",
    "rk_mpp_dispatch_lease_owned_locked",
    "rk_mpp_dispatch_lease_acquire_locked",
    "rk_mpp_dispatch_lease_release_locked",
    "rk_mpp_dispatch_lease_transfer_locked",
    "rk_mpp_hw_active_retry_matches_locked",
}
DISPATCH_OWNER_WRITE_OWNERS = {
    "rk_mpp_dispatch_lease_acquire_locked",
    "rk_mpp_dispatch_lease_release_locked",
    "rk_mpp_dispatch_lease_transfer_locked",
}
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
    rf"(?:{field_write_re(r'timeout_activation|timeout_generation|timeout_deadline_generation|timeout_deadline').pattern}|"
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


@dataclasses.dataclass(frozen=True)
class ActivationFunctionPatterns:
    access: re.Pattern[str]
    write: re.Pattern[str]
    parent_write: re.Pattern[str]
    generation_write: re.Pattern[str]
    deadline_write: re.Pattern[str]
    slot_state_access: re.Pattern[str]
    slot_state_write: re.Pattern[str]
    reason_access: re.Pattern[str]
    reason_write: re.Pattern[str]
    selected_access: re.Pattern[str]
    selected_write: re.Pattern[str]
    closure_access: re.Pattern[str]
    closure_write: re.Pattern[str]
    closure_state_access: re.Pattern[str]
    closure_state_write: re.Pattern[str]
    closure_group_access: re.Pattern[str]
    closure_group_write: re.Pattern[str]
    closure_core_access: re.Pattern[str]
    closure_core_write: re.Pattern[str]
    closure_observation_access: re.Pattern[str]
    closure_observation_write: re.Pattern[str]
    retry_token_access: re.Pattern[str]
    retry_token_write: re.Pattern[str]
    claim_token_access: re.Pattern[str]
    claim_token_write: re.Pattern[str]
    link_access: re.Pattern[str]
    link_write: re.Pattern[str]
    allocation: re.Pattern[str]
    free: re.Pattern[str]
    object_write: re.Pattern[str]


ACTIVATION_POINTER_DECL_RE = re.compile(
    r"\b(?:const\s+)?struct\s+rk_mpp_activation\s*(?<!\*)\*\s*"
    rf"{ACTIVATION_POINTER_QUALIFIERS}([A-Za-z_]\w*)"
)
ACTIVATION_LOCAL_DECL_RE = re.compile(
    r"^\s*(?:const\s+)?struct\s+rk_mpp_activation\s+(.+);$"
)
ACTIVATION_TYPEDEF_RE = re.compile(
    r"\btypedef\s+struct\s+rk_mpp_activation\s+([A-Za-z_]\w*)\s*;"
)
ACTIVATION_POINTER_TYPEDEF_RE = re.compile(
    r"\btypedef\s+(?:const\s+)?struct\s+rk_mpp_activation\s*\*\s*"
    rf"{ACTIVATION_POINTER_QUALIFIERS}([A-Za-z_]\w*)\s*;"
)


def activation_pointer_aliases(
    function: FunctionBody,
    typedefs: set[str],
    pointer_typedefs: set[str],
) -> set[str]:
    """Find every locally typed pointer to an activation in one function."""

    aliases = {"activation"}
    aliases.update(ACTIVATION_POINTER_DECL_RE.findall(function.signature))
    if typedefs:
        typedef_type = "|".join(sorted(re.escape(name) for name in typedefs))
        typedef_pointer = re.compile(
            rf"\b(?:const\s+)?(?:{typedef_type})\s*\*\s*"
            rf"{ACTIVATION_POINTER_QUALIFIERS}([A-Za-z_]\w*)"
        )
        aliases.update(typedef_pointer.findall(function.signature))
    if pointer_typedefs:
        pointer_typedef_type = "|".join(
            sorted(re.escape(name) for name in pointer_typedefs)
        )
        pointer_typedef_declaration = re.compile(
            rf"\b(?:const\s+)?(?:{pointer_typedef_type})\s+"
            rf"{ACTIVATION_POINTER_QUALIFIERS}([A-Za-z_]\w*)"
        )
        aliases.update(pointer_typedef_declaration.findall(function.signature))
    for _line, statement in function.statements:
        aliases.update(ACTIVATION_POINTER_DECL_RE.findall(statement))
        if typedefs:
            aliases.update(typedef_pointer.findall(statement))
        if pointer_typedefs:
            aliases.update(pointer_typedef_declaration.findall(statement))
        declaration = ACTIVATION_LOCAL_DECL_RE.match(statement)
        if declaration:
            aliases.update(
                re.findall(
                    rf"(?<!\*)\*\s*{ACTIVATION_POINTER_QUALIFIERS}"
                    r"([A-Za-z_]\w*)",
                    declaration.group(1),
                )
            )
    return aliases


def typed_token_patterns(
    function: FunctionBody, structure: str, fields: str
) -> tuple[re.Pattern[str], re.Pattern[str]]:
    """Build access/write patterns for exactly typed stack tokens."""

    declaration = re.compile(
        rf"\bstruct\s+{re.escape(structure)}\s*(?:\*\s*"
        rf"{ACTIVATION_POINTER_QUALIFIERS})?([A-Za-z_]\w*)"
    )
    aliases = set(declaration.findall(function.signature))
    for _line, statement in function.statements:
        aliases.update(declaration.findall(statement))
    if not aliases:
        return re.compile(r"(?!)"), re.compile(r"(?!)")
    escaped = "|".join(sorted(re.escape(alias) for alias in aliases))
    target = rf"\b(?:{escaped})\s*(?:->|\.)\s*"
    object_memory_write = re.compile(
        rf"\b(?:memset|memcpy|memmove)\s*\(\s*&?\s*(?:{escaped})\b"
    )
    field_write = field_write_re(
        fields,
        publishers=ACTIVATION_FIELD_PUBLISHERS,
        target=target,
    )
    return (
        re.compile(rf"{target}(?:{fields})\b"),
        re.compile(rf"(?:{field_write.pattern}|{object_memory_write.pattern})"),
    )


def activation_function_patterns(
    function: FunctionBody,
    typedefs: set[str],
    pointer_typedefs: set[str],
) -> ActivationFunctionPatterns:
    """Build activation guards for the typed aliases in one function."""

    aliases = activation_pointer_aliases(function, typedefs, pointer_typedefs)
    escaped_aliases = "|".join(sorted(re.escape(alias) for alias in aliases))
    target = activation_field_target(aliases, typedefs, pointer_typedefs)
    parent_write = field_write_re(
        r"job", publishers=ACTIVATION_FIELD_PUBLISHERS, target=target
    )
    generation_write = field_write_re(
        r"generation", publishers=ACTIVATION_FIELD_PUBLISHERS, target=target
    )
    deadline_write = field_write_re(
        r"watchdog_deadline|watchdog_deadline_valid",
        publishers=ACTIVATION_FIELD_PUBLISHERS,
        target=target,
    )
    slot_state_access = re.compile(rf"{target}slot_state\b")
    slot_state_write = field_write_re(
        r"slot_state", publishers=ACTIVATION_FIELD_PUBLISHERS, target=target
    )
    reason_access = re.compile(rf"{target}transition_reason\b")
    reason_write = field_write_re(
        r"transition_reason",
        publishers=ACTIVATION_FIELD_PUBLISHERS,
        target=target,
    )
    selected_write = field_write_re(
        r"selected_hw", publishers=ACTIVATION_FIELD_PUBLISHERS, target=target
    )
    closure_target = rf"{target}closure\s*\."
    group_target = rf"{closure_target}group\s*\."
    core_target = rf"{closure_target}core\s*\."
    observation_target = rf"{closure_target}observation\s*\."
    closure_write = field_write_re(
        r"closure", publishers=ACTIVATION_FIELD_PUBLISHERS, target=target
    )
    closure_state_write = field_write_re(
        r"state",
        publishers=ACTIVATION_FIELD_PUBLISHERS,
        target=closure_target,
    )
    closure_group_write = re.compile(
        rf"(?:{field_write_re('group', publishers=ACTIVATION_FIELD_PUBLISHERS, target=closure_target).pattern}|"
        rf"{field_write_re('result|status|valid', publishers=ACTIVATION_FIELD_PUBLISHERS, target=group_target).pattern})"
    )
    closure_core_write = re.compile(
        rf"(?:{field_write_re('core', publishers=ACTIVATION_FIELD_PUBLISHERS, target=closure_target).pattern}|"
        rf"{field_write_re('result|status|valid', publishers=ACTIVATION_FIELD_PUBLISHERS, target=core_target).pattern})"
    )
    closure_observation_write = re.compile(
        rf"(?:{field_write_re('observation', publishers=ACTIVATION_FIELD_PUBLISHERS, target=closure_target).pattern}|"
        rf"{field_write_re('kind|hw_status|bus_idle_status|bus_idle_checked|valid', publishers=ACTIVATION_FIELD_PUBLISHERS, target=observation_target).pattern})"
    )
    retry_token_access, retry_token_write = typed_token_patterns(
        function,
        "rk_mpp_activation_retry_token",
        r"activation|generation",
    )
    claim_token_access, claim_token_write = typed_token_patterns(
        function,
        "rk_mpp_activation_claim_token",
        r"activation|generation|reason|owns_job_ref",
    )
    link_access = re.compile(rf"{target}job_link\b")
    link_node_target = rf"{target}job_link\s*\."
    link_write = re.compile(
        rf"(?:{field_write_re('job_link', publishers=ACTIVATION_FIELD_PUBLISHERS, target=target).pattern}|"
        rf"{field_write_re('next|prev', publishers=ACTIVATION_FIELD_PUBLISHERS, target=link_node_target).pattern}|"
        r"\b(?:INIT_LIST_HEAD|list_(?:add(?:_tail)?|del(?:_init)?|"
        r"move(?:_tail)?|replace(?:_init)?|splice(?:_init)?(?:_tail)?|swap|"
        r"rotate_to_front|cut_position|bulk_move_tail))\s*\([^;]*"
        rf"{target}job_link\b)"
    )
    object_write = activation_object_write_re(
        aliases, typedefs, pointer_typedefs
    )
    allocation = re.compile(
        rf"\bkzalloc_obj\s*\(\s*\*\s*(?:{escaped_aliases})\b"
    )
    free = re.compile(rf"\bkfree\s*\(\s*(?:{escaped_aliases})\b")
    write = re.compile(
        rf"(?:{parent_write.pattern}|{generation_write.pattern}|"
        rf"{deadline_write.pattern}|{slot_state_write.pattern}|"
        rf"{reason_write.pattern}|{selected_write.pattern}|"
        rf"{closure_write.pattern}|{closure_state_write.pattern}|"
        rf"{closure_group_write.pattern}|{closure_core_write.pattern}|"
        rf"{closure_observation_write.pattern}|"
        rf"{MPP_ACTIVATION_SEQUENCE_WRITE_RE.pattern}|{object_write.pattern})"
    )
    return ActivationFunctionPatterns(
        access=re.compile(
            rf"(?:{MPP_ACTIVATION_OBJECT_TARGET}\b|"
            rf"{target}(?:{MPP_ACTIVATION_FIELDS})\b|"
            rf"{FIELD_TARGET}activation_generation_seq\b)"
        ),
        write=write,
        parent_write=parent_write,
        generation_write=generation_write,
        deadline_write=deadline_write,
        slot_state_access=slot_state_access,
        slot_state_write=slot_state_write,
        reason_access=reason_access,
        reason_write=reason_write,
        selected_access=re.compile(rf"{target}selected_hw\b"),
        selected_write=selected_write,
        closure_access=re.compile(rf"{target}closure\b"),
        closure_write=closure_write,
        closure_state_access=re.compile(rf"{closure_target}state\b"),
        closure_state_write=closure_state_write,
        closure_group_access=re.compile(rf"{closure_target}group\b"),
        closure_group_write=closure_group_write,
        closure_core_access=re.compile(rf"{closure_target}core\b"),
        closure_core_write=closure_core_write,
        closure_observation_access=re.compile(
            rf"{closure_target}observation\b"
        ),
        closure_observation_write=closure_observation_write,
        retry_token_access=retry_token_access,
        retry_token_write=retry_token_write,
        claim_token_access=claim_token_access,
        claim_token_write=claim_token_write,
        link_access=link_access,
        link_write=link_write,
        allocation=allocation,
        free=free,
        object_write=object_write,
    )


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


def production_source_text(source: pathlib.Path, symbol: str) -> str:
    """Return normalized comment-free source with KUnit regions removed."""

    lines = strip_comments(source.read_text(encoding="utf-8").splitlines())
    ignored = kunit_lines(lines, symbol)
    return normalize(" ".join(
        line for index, line in enumerate(lines) if index not in ignored
    ))


def exact_declaration_block(
    source: pathlib.Path, declaration: str, expected: str
) -> tuple[int, str]:
    """Require one declaration block to equal the reviewed schema exactly."""

    stripped = "\n".join(
        strip_comments(source.read_text(encoding="utf-8").splitlines())
    )
    if len(re.findall(rf"\b{re.escape(declaration.split('{', 1)[0].strip())}\s*\{{", stripped)) != 1:
        raise ValueError(f"expected one {declaration} definition in {source}")
    line, text = declaration_block(source, declaration)
    if text != normalize(expected):
        raise ValueError(f"unexpected {declaration} definition in {source}: {text}")
    return line, text


def function_map(functions: list[FunctionBody]) -> dict[str, FunctionBody]:
    """Return production functions by name; callers guard reviewed names."""

    grouped: dict[str, list[FunctionBody]] = collections.defaultdict(list)
    for function in functions:
        grouped[function.name].append(function)
    return {name: entries[0] for name, entries in grouped.items()}


def require_ordered_fragments(
    functions: dict[str, FunctionBody], name: str, fragments: tuple[str, ...]
) -> None:
    """Require reviewed statements to remain in order in one function."""

    function = functions.get(name)
    if not function:
        raise ValueError(f"missing production function {name}")
    normalized_fragments = tuple(normalize(fragment) for fragment in fragments)
    for fragment, expected_count in collections.Counter(
        normalized_fragments
    ).items():
        if function.text.count(fragment) != expected_count:
            raise ValueError(
                f"{name}: expected {expected_count} occurrence(s) of: {fragment}"
            )
    cursor = 0
    for fragment in normalized_fragments:
        position = function.text.find(fragment, cursor)
        if position < 0:
            raise ValueError(
                f"{name}: missing ordered ownership fragment: {fragment}"
            )
        cursor = position + len(fragment)


def require_control_counts(
    functions: dict[str, FunctionBody], name: str, returns: int, branches: int
) -> None:
    """Freeze the small closure helpers' control-transfer surface."""

    text = functions[name].text
    counts = {
        "return": len(re.findall(r"\breturn\b", text)),
        "if": len(re.findall(r"\bif\s*\(", text)),
        "goto": len(re.findall(r"\bgoto\b", text)),
    }
    expected = {"return": returns, "if": branches, "goto": 0}
    if counts != expected or re.search(r"\b(?:switch|break|continue)\b", text):
        raise ValueError(f"{name}: unexpected control-transfer shape {counts}")


def validate_mpp_retry_retirement_contract(
    source: pathlib.Path, functions: list[FunctionBody]
) -> None:
    """Hard-guard the exact retry-proof handoff; baselines cannot bless drift."""

    production = production_source_text(source, KUNIT_MARKERS[MPP_SOURCE])
    token_type = r"\bstruct\s+rk_mpp_activation_retry_token\b"
    if len(re.findall(token_type, production)) != 5:
        raise ValueError(
            "retry token must have one schema, three pointer parameters, "
            "and one stack-local instance"
        )
    token_declarations = re.findall(
        token_type
        + rf"\s*(?:\*\s*{ACTIVATION_POINTER_QUALIFIERS})?"
        + r"([A-Za-z_]\w*)\s*(\[[^]]*\])?",
        production,
    )
    if token_declarations != [("token", "")] * 4:
        raise ValueError(
            "retry token aliases or non-stack token storage are forbidden: "
            f"{token_declarations}"
        )
    if re.search(rf"\btypedef\b[^;]*{token_type}", production):
        raise ValueError("retry token typedefs are forbidden")
    if production.count("&token") != 2:
        raise ValueError("retry token must escape only to commit and finish")
    retry_functions = [
        function
        for function in functions
        if re.search(token_type, function.signature + " " + function.text)
    ]
    retry_text = " ".join(
        function.signature + " " + function.text
        for function in retry_functions
    )
    if re.search(
        r"(?:\*\s*token\s*=|\b(?:memset|memcpy|memmove)\s*\(\s*token\b|"
        r"\b(?:WRITE_ONCE|xchg|cmpxchg)\w*\s*\(\s*&?\s*\*?\s*token\b)",
        retry_text,
    ):
        raise ValueError("whole retry token mutation is forbidden")
    token_activation_fields = re.findall(
        r"\btoken\s*(?:->|\.)\s*activation\s*->\s*([A-Za-z_]\w*)",
        retry_text,
    )
    if token_activation_fields != ["job", "job"]:
        raise ValueError(
            "retry token activation dereferences must be the finish wrapper's "
            f"two parent-job checks: {token_activation_fields}"
        )

    for guarded_type in (
        "rk_mpp_activation_closure",
        "rk_mpp_activation_recovery_record",
        "rk_mpp_activation_observation_record",
    ):
        if re.search(
            rf"\bstruct\s+{guarded_type}\s*\*", production
        ) or re.search(rf"\btypedef\b[^;]*\b{guarded_type}\b", production):
            raise ValueError(
                f"pointer aliases and typedefs for {guarded_type} are forbidden"
            )
    if len(re.findall(r"\bstruct\s+rk_mpp_activation_closure\b", production)) != 2:
        raise ValueError("activation closure type may exist only as its schema and member")
    if len(
        re.findall(r"\bstruct\s+rk_mpp_activation_recovery_record\b", production)
    ) != 4:
        raise ValueError(
            "activation recovery record may exist only as its schema and three members"
        )
    if len(
        re.findall(r"\bstruct\s+rk_mpp_activation_observation_record\b", production)
    ) != 2:
        raise ValueError(
            "activation observation record may exist only as its schema and member"
        )
    if re.search(
        r"\b(?:typeof|__typeof__|__auto_type)\b[^;]*(?:closure|observation|token)",
        production,
    ):
        raise ValueError("inferred closure and retry-token aliases are forbidden")
    closure_addresses = re.findall(
        r"(?<!&)&(?!&)[^,;()]*\bclosure\b", production
    )
    if closure_addresses != ["&activation->closure", "&activation->closure"]:
        raise ValueError(
            "closure address may escape only to initialization and pristine checks: "
            f"{closure_addresses}"
        )
    if re.search(r"\)\s*->\s*closure\b", production):
        raise ValueError("activation helper-result closure access is forbidden")

    by_name = function_map(functions)
    reviewed_functions = {
        "rk_mpp_activation_storage_released",
        "rk_mpp_hw_commit_active_retry",
        "rk_mpp_activation_finish_retry_locked",
        "rk_mpp_activation_finish_retry",
        "rk_mpp_rkvdec2_prepare_ccu_retry_job",
        "rk_mpp_rkvdec2_restart_ccu_unfinished_jobs",
        "rk_mpp_hw_abort_job",
        "rk_mpp_hw_recover_active",
    }
    for name in reviewed_functions:
        if sum(function.name == name for function in functions) != 1:
            raise ValueError(f"expected one production function {name}")
    token_users = {
        function.name
        for function in functions
        if re.search(token_type, function.signature + " " + function.text)
    }
    if token_users != {
        "rk_mpp_hw_commit_active_retry",
        "rk_mpp_activation_finish_retry_locked",
        "rk_mpp_activation_finish_retry",
        "rk_mpp_rkvdec2_prepare_ccu_retry_job",
    }:
        raise ValueError(f"unexpected retry token owner set: {sorted(token_users)}")

    call_owners = {
        "rk_mpp_activation_closure_pristine": {
            "rk_mpp_activation_claim_quarantine",
            "rk_mpp_activation_finish_terminal_locked",
            "rk_mpp_activation_finish_observed_terminal_locked",
            "rk_mpp_activation_storage_released",
            "rk_mpp_activation_install_locked",
            "rk_mpp_activation_free_unpublished",
            "rk_mpp_hw_commit_active_retry",
        },
        "rk_mpp_activation_finish_retry_locked": {
            "rk_mpp_activation_finish_retry",
        },
        "rk_mpp_activation_finish_retry": {
            "rk_mpp_rkvdec2_prepare_ccu_retry_job",
        },
        "rk_mpp_rkvdec2_prepare_ccu_retry_job": {
            "rk_mpp_rkvdec2_restart_ccu_unfinished_jobs",
        },
        "rk_mpp_rkvdec2_restart_ccu_unfinished_jobs": {
            "rk_mpp_hw_abort_job",
            "rk_mpp_hw_recover_active",
        },
    }
    for callee, expected_owners in call_owners.items():
        owners = {
            function.name
            for function in functions
            if re.search(rf"\b{re.escape(callee)}\s*\(", function.text)
        }
        if owners != expected_owners:
            raise ValueError(
                f"unexpected {callee} caller set: {sorted(owners)}"
            )
    allowed_bare_token_statements = {
        "rk_mpp_hw_commit_active_retry": {
            "if (!rk_mpp_hw_active_retry_matches_locked(hw, job, old) || "
            "!successor || successor->job != job || !group || !token || "
            "token->activation || token->generation || !group->quiesced || "
            "!group->reusable || successor->selected_hw || "
            "!list_empty(&successor->job_link) || successor->slot_state != "
            "RK_MPP_ACTIVATION_UNINSTALLED || successor->transition_reason != "
            "RK_MPP_TRANSITION_NONE || successor->generation || "
            "successor->watchdog_deadline || "
            "successor->watchdog_deadline_valid || "
            "!rk_mpp_activation_closure_pristine(old) || "
            "!rk_mpp_activation_closure_pristine(successor)) goto unlock;",
        },
        "rk_mpp_activation_finish_retry_locked": {
            "struct rk_mpp_activation *old = token ? "
            "token->activation : NULL;",
        },
        "rk_mpp_activation_finish_retry": {
            "if (!token || !token->activation || "
            "!token->activation->job) return false;",
            "finished = rk_mpp_activation_finish_retry_locked(hw, token, "
            "status, core);",
        },
        "rk_mpp_rkvdec2_prepare_ccu_retry_job": {
            "struct rk_mpp_activation_retry_token token = {};",
        },
    }
    for function in functions:
        if function.name not in token_users:
            continue
        for _line, statement in function.statements:
            if not re.search(
                r"(?<![&.>])\btoken\b(?!\s*(?:->|\.))", statement
            ):
                continue
            if statement in allowed_bare_token_statements.get(function.name, set()):
                continue
            raise ValueError(
                f"{function.name}: bare retry token escape is forbidden: {statement}"
            )

    expected_storage_release_statements = (
        "if (activation->slot_state == RK_MPP_ACTIVATION_UNINSTALLED) "
        "return activation->transition_reason == RK_MPP_TRANSITION_NONE && "
        "rk_mpp_activation_closure_pristine(activation);",
        "if (activation->slot_state == RK_MPP_ACTIVATION_SUPERSEDED) "
        "return activation->transition_reason == "
        "RK_MPP_TRANSITION_RETRY_REPLACED && activation->closure.state == "
        "RK_MPP_ACTIVATION_CLOSURE_RETIRED && "
        "rk_mpp_activation_observation_pristine(activation) && "
        "activation->closure.group.valid && "
        "!activation->closure.group.status && "
        "activation->closure.group.result.quiesced && "
        "activation->closure.core.valid;",
        "if (activation->slot_state != RK_MPP_ACTIVATION_RETIRED || "
        "activation->transition_reason <= RK_MPP_TRANSITION_NONE || "
        "activation->transition_reason >= RK_MPP_TRANSITION_RETRY_REPLACED || "
        "activation->closure.state != RK_MPP_ACTIVATION_CLOSURE_RETIRED) "
        "return false;",
        "if (activation->closure.observation.valid) return "
        "activation->closure.terminal_scope == "
        "RK_MPP_ACTIVATION_RETIREMENT_NONE && "
        "!activation->closure.group.valid && "
        "!activation->closure.core.valid && "
        "!activation->closure.terminal.valid && "
        "rk_mpp_activation_observation_matches(activation);",
        "return rk_mpp_activation_observation_pristine(activation) && "
        "((activation->closure.terminal_scope == "
        "RK_MPP_ACTIVATION_RETIREMENT_CORE && "
        "activation->closure.terminal.valid && "
        "!activation->closure.terminal.status && "
        "activation->closure.terminal.result.quiesced) || "
        "(activation->closure.terminal_scope == "
        "RK_MPP_ACTIVATION_RETIREMENT_CCU_GROUP && "
        "activation->closure.group.valid && "
        "!activation->closure.group.status && "
        "activation->closure.group.result.quiesced && "
        "activation->closure.core.valid));",
    )
    storage_release_statements = tuple(
        statement
        for _line, statement in by_name[
            "rk_mpp_activation_storage_released"
        ].statements
    )
    if storage_release_statements != expected_storage_release_statements:
        raise ValueError("activation storage release predicates drifted")

    expected_finish_retry_statements = (
        "struct rk_mpp_session *session;",
        "unsigned long flags;",
        "bool finished;",
        "if (!token || !token->activation || !token->activation->job) "
        "return false;",
        "session = token->activation->job->session;",
        "lockdep_assert_held(&hw->run_lock);",
        "mutex_lock(&session->lock);",
        "spin_lock_irqsave(&hw->lock, flags);",
        "finished = rk_mpp_activation_finish_retry_locked(hw, token, "
        "status, core);",
        "spin_unlock_irqrestore(&hw->lock, flags);",
        "mutex_unlock(&session->lock);",
        "return finished;",
    )
    finish_retry_statements = tuple(
        statement
        for _line, statement in by_name[
            "rk_mpp_activation_finish_retry"
        ].statements
    )
    if finish_retry_statements != expected_finish_retry_statements:
        raise ValueError("activation retry finisher wrapper drifted")

    require_control_counts(
        by_name, "rk_mpp_activation_storage_released", returns=5, branches=4
    )
    require_control_counts(
        by_name, "rk_mpp_activation_finish_retry_locked", returns=2, branches=1
    )
    require_control_counts(
        by_name, "rk_mpp_activation_finish_retry", returns=2, branches=1
    )
    prepare_text = by_name["rk_mpp_rkvdec2_prepare_ccu_retry_job"].text
    prepare_markers = (
        "rk_mpp_hw_commit_active_retry(hw, job, old, successor, group, &token)",
        "rk_mpp_hw_cancel_timeout(hw)",
        "rk_mpp_hw_stop_and_recover(hw, job, &recovery)",
        "rk_mpp_activation_finish_retry(hw, &token, ret, &recovery)",
    )
    positions = [prepare_text.find(marker) for marker in prepare_markers]
    if any(position < 0 for position in positions) or positions != sorted(positions):
        raise ValueError("retry prepare proof calls must remain unique and ordered")
    pre_cancel = prepare_text[
        positions[0] + len(prepare_markers[0]) : positions[1]
    ]
    if len(re.findall(r"\b(?:return|goto)\b", pre_cancel)) != 1:
        raise ValueError("retry commit failure must flow directly to cleanup")
    recovery_span = prepare_text[positions[1] : positions[3]]
    if (
        len(re.findall(r"\bif\s*\(", recovery_span)) != 1
        or re.search(r"\b(?:return|goto)\b", recovery_span)
    ):
        raise ValueError("retry commit must be followed directly by stop and finish")

    require_ordered_fragments(
        by_name,
        "rk_mpp_activation_storage_init",
        ("memset(&activation->closure, 0, sizeof(activation->closure))",),
    )
    if not by_name["rk_mpp_activation_storage_init"].text.endswith(
        "memset(&activation->closure, 0, sizeof(activation->closure));"
    ):
        raise ValueError("activation closure zeroing must finish storage initialization")
    expected_pristine = normalize(
        "return activation && !memchr_inv(&activation->closure, 0, "
        "sizeof(activation->closure));"
    )
    if by_name["rk_mpp_activation_closure_pristine"].text != expected_pristine:
        raise ValueError("activation closure pristine predicate drifted")
    require_ordered_fragments(
        by_name,
        "rk_mpp_activation_storage_released",
        (
            "RK_MPP_ACTIVATION_UNINSTALLED",
            "rk_mpp_activation_closure_pristine(activation)",
            "RK_MPP_ACTIVATION_SUPERSEDED",
            "RK_MPP_TRANSITION_RETRY_REPLACED",
            "RK_MPP_ACTIVATION_CLOSURE_RETIRED",
            "rk_mpp_activation_observation_pristine(activation)",
            "!activation->closure.group.status",
            "activation->closure.group.result.quiesced",
            "RK_MPP_ACTIVATION_RETIRED",
            "RK_MPP_TRANSITION_RETRY_REPLACED",
            "RK_MPP_ACTIVATION_CLOSURE_RETIRED",
            "activation->closure.observation.valid",
            "RK_MPP_ACTIVATION_RETIREMENT_NONE",
            "rk_mpp_activation_observation_matches(activation)",
            "rk_mpp_activation_observation_pristine(activation)",
            "RK_MPP_ACTIVATION_RETIREMENT_CORE",
            "activation->closure.terminal.result.quiesced",
            "RK_MPP_ACTIVATION_RETIREMENT_CCU_GROUP",
            "!activation->closure.group.status",
            "activation->closure.group.result.quiesced",
        ),
    )
    require_ordered_fragments(
        by_name,
        "rk_mpp_hw_commit_active_retry",
        (
            "token->activation || token->generation",
            "!group->quiesced",
            "!group->reusable",
            "!rk_mpp_activation_closure_pristine(old)",
            "!rk_mpp_activation_closure_pristine(successor)",
            "old->closure.group.result = *group",
            "old->closure.group.status = 0",
            "old->closure.group.valid = true",
            "old->closure.state = RK_MPP_ACTIVATION_CLOSURE_PENDING",
            "old->slot_state = RK_MPP_ACTIVATION_SUPERSEDED",
            "old->transition_reason = RK_MPP_TRANSITION_RETRY_REPLACED",
            "list_add_tail(&successor->job_link, &job->activations)",
            "WRITE_ONCE(job->current_activation, successor)",
            "hw->active_activation = successor",
            "token->activation = old",
            "token->generation = old->generation",
        ),
    )
    require_ordered_fragments(
        by_name,
        "rk_mpp_activation_finish_retry_locked",
        (
            "old->generation != token->generation",
            "old->selected_hw != hw",
            "list_empty(&old->job_link)",
            "old == READ_ONCE(job->current_activation)",
            "old == rk_mpp_hw_active_activation_locked(hw)",
            "old->slot_state != RK_MPP_ACTIVATION_SUPERSEDED",
            "old->transition_reason != RK_MPP_TRANSITION_RETRY_REPLACED",
            "old->closure.state != RK_MPP_ACTIVATION_CLOSURE_PENDING",
            "!old->closure.group.valid",
            "old->closure.group.status",
            "!old->closure.group.result.quiesced",
            "!old->closure.group.result.reusable",
            "old->closure.core.valid)",
            "old->closure.core.result = *core",
            "old->closure.core.status = status",
            "old->closure.core.valid = true",
            "old->closure.state = RK_MPP_ACTIVATION_CLOSURE_RETIRED",
            "token->activation = NULL",
            "token->generation = 0",
        ),
    )
    require_ordered_fragments(
        by_name,
        "rk_mpp_rkvdec2_prepare_ccu_retry_job",
        (
            "rk_mpp_hw_commit_active_retry(hw, job, old, successor, group, &token)",
            "rk_mpp_hw_cancel_timeout(hw)",
            "ret = rk_mpp_hw_stop_and_recover(hw, job, &recovery)",
            "rk_mpp_activation_finish_retry(hw, &token, ret, &recovery)",
            "if (ret)",
            "!recovery.quiesced || !recovery.reusable",
        ),
    )
    require_ordered_fragments(
        by_name,
        "rk_mpp_rkvdec2_restart_ccu_unfinished_jobs",
        (
            "!group || !group->quiesced || !group->reusable",
            "rk_mpp_rkvdec2_prepare_ccu_retry_job(jobs[i], successor, group)",
        ),
    )
    for caller in ("rk_mpp_hw_abort_job", "rk_mpp_hw_recover_active"):
        require_ordered_fragments(
            by_name,
            caller,
            ("rk_mpp_rkvdec2_restart_ccu_unfinished_jobs(ccu, &ccu_recovery)",),
        )


def validate_mpp_terminal_claim_contract(
    source: pathlib.Path, functions: list[FunctionBody]
) -> None:
    """Hard-guard recovered-terminal proof and fail-closed claim retention."""

    production = production_source_text(source, KUNIT_MARKERS[MPP_SOURCE])
    token_type = r"\bstruct\s+rk_mpp_activation_claim_token\b"
    declarations = re.findall(
        token_type
        + rf"\s*(?:\*\s*{ACTIVATION_POINTER_QUALIFIERS})?"
        + r"([A-Za-z_]\w*)\s*(\[[^]]*\])?",
        production,
    )
    if any(array for _name, array in declarations):
        raise ValueError(
            f"claim token aliases or non-stack storage are forbidden: {declarations}"
        )
    if re.search(rf"\btypedef\b[^;]*{token_type}", production) or re.search(
        rf"{token_type}\s*\*\s*\*", production
    ) or re.search(
        r"\b(?:typeof|__typeof__|__auto_type)\b[^;]*(?:claim|token)",
        production,
    ):
        raise ValueError("claim token typedef, indirect, or inferred aliases are forbidden")

    by_name = function_map(functions)
    token_users = {
        function.name
        for function in functions
        if re.search(token_type, function.signature + " " + function.text)
    }
    expected_token_users = {
        "rk_mpp_hw_claim_active_locked",
        "rk_mpp_hw_restore_active_locked",
        "rk_mpp_activation_claim_job",
        "rk_mpp_activation_claim_put",
        "rk_mpp_activation_finish_terminal_locked",
        "rk_mpp_activation_finish_terminal",
        "rk_mpp_activation_finish_observed_terminal_locked",
        "rk_mpp_activation_finish_observed_terminal",
        "rk_mpp_activation_claim_quarantine",
        "rk_mpp_hw_restore_or_quarantine",
        "rk_mpp_hw_clear_active_job",
        "rk_mpp_hw_take_active_job",
        "rk_mpp_hw_take_irq_job",
        "rk_mpp_hw_take_active_if",
        "rk_mpp_hw_take_active_if_generation",
        "rk_mpp_hw_take_iommu_fault_job",
        "rk_mpp_hw_abort_job",
        "rk_mpp_rkvdec2_drain_ccu_done_jobs",
        "rk_mpp_hw_recover_active",
        "rk_mpp_hw_abort_active",
        "rk_mpp_hw_abort_active_recovery_locked",
        "rk_mpp_rkvenc2_thread",
        "rk_mpp_rkvenc2_submit",
        "rk_mpp_rkvdec2_thread",
        "rk_mpp_rkvdec2_submit",
        "rk_mpp_av1_submit",
        "rk_mpp_av1_thread",
    }
    if token_users != expected_token_users:
        raise ValueError(f"unexpected claim token owner set: {sorted(token_users)}")
    function_type_count = sum(
        len(re.findall(token_type, function.signature + " " + function.text))
        for function in functions
    )
    file_scope_type_count = len(re.findall(token_type, production)) - function_type_count
    if file_scope_type_count not in {1, 7}:
        raise ValueError("claim token may exist only in its schema and reviewed functions")

    allowed_claim_token_consumers = {
        "memset",
        "rk_mpp_activation_claim_job",
        "rk_mpp_activation_claim_put",
        "rk_mpp_activation_claim_quarantine",
        "rk_mpp_activation_finish_terminal",
        "rk_mpp_activation_finish_terminal_locked",
        "rk_mpp_activation_finish_observed_terminal",
        "rk_mpp_activation_finish_observed_terminal_locked",
        "rk_mpp_hw_claim_active_locked",
        "rk_mpp_hw_clear_active_job",
        "rk_mpp_hw_restore_active_locked",
        "rk_mpp_hw_restore_or_quarantine",
        "rk_mpp_hw_take_active_if",
        "rk_mpp_hw_take_active_if_generation",
        "rk_mpp_hw_take_active_job",
        "rk_mpp_hw_take_iommu_fault_job",
        "rk_mpp_hw_take_irq_job",
    }

    def direct_token_consumers(statement: str, identifier: str) -> set[str]:
        """Return calls that receive one token identifier as a direct argument."""

        pairs: list[tuple[int, int]] = []
        stack: list[int] = []
        for index, character in enumerate(statement):
            if character == "(":
                stack.append(index)
            elif character == ")" and stack:
                pairs.append((stack.pop(), index))

        consumers: set[str] = set()
        for start, end in pairs:
            callee_match = re.search(r"([A-Za-z_]\w*)\s*$", statement[:start])
            if not callee_match or callee_match.group(1) in {
                "if",
                "for",
                "sizeof",
                "switch",
                "while",
            }:
                continue

            depth = 0
            cursor = start + 1
            while cursor < end:
                character = statement[cursor]
                if character == "(":
                    depth += 1
                    cursor += 1
                    continue
                if character == ")":
                    depth -= 1
                    cursor += 1
                    continue
                if depth or not statement.startswith(identifier, cursor):
                    cursor += 1
                    continue

                before = statement[cursor - 1] if cursor else ""
                after_index = cursor + len(identifier)
                after = statement[after_index] if after_index < len(statement) else ""
                if (before.isalnum() or before in "_.>") or (
                    after.isalnum() or after == "_"
                ):
                    cursor += 1
                    continue
                suffix = statement[after_index:].lstrip()
                if suffix.startswith("->") or suffix.startswith("."):
                    cursor += len(identifier)
                    continue
                consumers.add(callee_match.group(1))
                break
        return consumers

    token_declaration = re.compile(
        token_type
        + rf"\s*(?:\*\s*{ACTIVATION_POINTER_QUALIFIERS})?"
        + r"([A-Za-z_]\w*)"
    )
    for function in functions:
        if function.name not in expected_token_users:
            continue
        aliases = set(token_declaration.findall(function.signature))
        for _line, statement in function.statements:
            aliases.update(token_declaration.findall(statement))
        for _line, statement in function.statements:
            for alias in aliases:
                consumers = direct_token_consumers(statement, alias)
                unreviewed = consumers - allowed_claim_token_consumers
                if unreviewed:
                    raise ValueError(
                        f"{function.name}: claim token escapes to "
                        f"{sorted(unreviewed)}: {statement}"
                    )
                assignment = re.search(
                    rf"(?<![=!<>])=\s*(?:\([^;]*?\)\s*)?&?\s*"
                    rf"{re.escape(alias)}\b(?!\s*(?:->|\.))",
                    statement,
                )
                returned = re.search(
                    rf"\breturn\s+(?:\([^;]*?\)\s*)?&?\s*"
                    rf"{re.escape(alias)}\b(?!\s*(?:->|\.))",
                    statement,
                )
                if assignment or returned:
                    raise ValueError(
                        f"{function.name}: claim token pointer escape is "
                        f"forbidden: {statement}"
                    )

    expected_calls: dict[str, dict[str, int]] = {
        "rk_mpp_activation_claim_put": {
            "rk_mpp_hw_abort_job": 1,
            "rk_mpp_rkvdec2_drain_ccu_done_jobs": 1,
            "rk_mpp_hw_recover_active": 1,
            "rk_mpp_hw_abort_active": 1,
            "rk_mpp_hw_abort_active_recovery_locked": 1,
            "rk_mpp_rkvenc2_thread": 1,
            "rk_mpp_rkvenc2_submit": 2,
            "rk_mpp_rkvdec2_thread": 1,
            "rk_mpp_rkvdec2_submit": 1,
            "rk_mpp_av1_submit": 1,
            "rk_mpp_av1_thread": 1,
        },
        "rk_mpp_activation_finish_terminal_locked": {
            "rk_mpp_activation_finish_terminal": 1,
        },
        "rk_mpp_activation_finish_terminal": {
            "rk_mpp_hw_abort_job": 2,
            "rk_mpp_rkvdec2_drain_ccu_done_jobs": 1,
            "rk_mpp_hw_recover_active": 2,
            "rk_mpp_hw_abort_active": 1,
            "rk_mpp_hw_abort_active_recovery_locked": 1,
            "rk_mpp_rkvenc2_thread": 1,
            "rk_mpp_rkvdec2_thread": 1,
            "rk_mpp_av1_submit": 1,
            "rk_mpp_av1_thread": 1,
        },
        "rk_mpp_activation_claim_quarantine": {
            "rk_mpp_hw_restore_or_quarantine": 1,
            "rk_mpp_rkvdec2_drain_ccu_done_jobs": 1,
            "rk_mpp_rkvenc2_submit": 2,
            "rk_mpp_rkvenc2_thread": 1,
            "rk_mpp_rkvdec2_submit": 1,
            "rk_mpp_rkvdec2_thread": 1,
            "rk_mpp_av1_submit": 1,
            "rk_mpp_av1_thread": 1,
        },
        "rk_mpp_activation_finish_observed_terminal_locked": {
            "rk_mpp_activation_finish_observed_terminal": 1,
        },
        "rk_mpp_activation_finish_observed_terminal": {
            "rk_mpp_rkvdec2_drain_ccu_done_jobs": 1,
            "rk_mpp_rkvenc2_submit": 2,
            "rk_mpp_rkvenc2_thread": 1,
            "rk_mpp_rkvdec2_submit": 1,
            "rk_mpp_rkvdec2_thread": 1,
            "rk_mpp_av1_submit": 1,
            "rk_mpp_av1_thread": 1,
        },
        "rk_mpp_hw_clear_active_job": {
            "rk_mpp_hw_abort_job": 1,
            "rk_mpp_rkvenc2_submit": 2,
            "rk_mpp_rkvdec2_submit": 1,
            "rk_mpp_av1_submit": 1,
        },
        "rk_mpp_hw_restore_or_quarantine": {
            "rk_mpp_hw_abort_job": 3,
            "rk_mpp_rkvdec2_drain_ccu_done_jobs": 2,
            "rk_mpp_hw_recover_active": 4,
            "rk_mpp_hw_abort_active": 2,
            "rk_mpp_hw_abort_active_recovery_locked": 2,
            "rk_mpp_rkvenc2_thread": 2,
            "rk_mpp_rkvdec2_thread": 2,
            "rk_mpp_av1_submit": 1,
            "rk_mpp_av1_thread": 2,
        },
        "rk_mpp_service_has_quarantined_activation": {
            "rk_mpp_hw_remove": 1,
            "rk_mpp_hw_shutdown": 1,
        },
        "rk_mpp_hw_job_is_quarantined": {"rk_mpp_hw_abort_job": 1},
    }
    for callee, expected in expected_calls.items():
        actual = {
            function.name: count
            for function in functions
            if (
                count := len(
                    re.findall(rf"\b{re.escape(callee)}\s*\(", function.text)
                )
            )
        }
        if actual != expected:
            raise ValueError(f"unexpected {callee} call map: {actual}")

    exact_helpers = {
        "rk_mpp_activation_claim_put": (
            "struct rk_mpp_activation *activation;",
            "struct rk_mpp_job *job;",
            "if (!token || !token->owns_job_ref) return false;",
            "activation = token->activation;",
            "job = rk_mpp_activation_claim_job(token);",
            "if (!job || activation->generation != token->generation || "
            "activation->transition_reason != token->reason || "
            "!rk_mpp_activation_storage_released(activation)) return false;",
            "memset(token, 0, sizeof(*token));",
            "rk_mpp_job_put(job);",
            "return true;",
        ),
        "rk_mpp_activation_finish_terminal": (
            "unsigned long flags;",
            "bool finished;",
            "lockdep_assert_held(&hw->run_lock);",
            "spin_lock_irqsave(&hw->lock, flags);",
            "finished = rk_mpp_activation_finish_terminal_locked(hw, ccu, "
            "token, core_status, core, group_status, group);",
            "spin_unlock_irqrestore(&hw->lock, flags);",
            "return finished;",
        ),
        "rk_mpp_hw_restore_or_quarantine": (
            "unsigned long flags;",
            "bool restored;",
            "lockdep_assert_held(&hw->run_lock);",
            "spin_lock_irqsave(&hw->lock, flags);",
            "restored = rk_mpp_hw_restore_active_locked(hw, token);",
            "if (restored) { rk_mpp_hw_clear_irq_record_locked(hw);",
            "if (force_iommu_fault) hw->iommu_fault_pending = true;",
            "if (hw->iommu_fault_pending) hw->iommu_fault_generation = "
            "rk_mpp_hw_active_generation_locked(hw);",
            "} spin_unlock_irqrestore(&hw->lock, flags);",
            "if (restored) return true;",
            "WARN_ON_ONCE(!rk_mpp_activation_claim_quarantine(hw, ccu, token, "
            "quarantine_error, core_status, core, group_status, group));",
            "return false;",
        ),
        "rk_mpp_service_has_quarantined_activation": (
            "bool found;",
            "mutex_lock(&srv->quarantine_lock);",
            "found = !list_empty(&srv->quarantined_activations);",
            "mutex_unlock(&srv->quarantine_lock);",
            "return found;",
        ),
        "rk_mpp_hw_job_is_quarantined": (
            "struct rk_mpp_activation *activation;",
            "unsigned long flags;",
            "bool quarantined;",
            "spin_lock_irqsave(&hw->lock, flags);",
            "activation = READ_ONCE(job->current_activation);",
            "quarantined = activation && activation->selected_hw == hw && "
            "activation->slot_state == RK_MPP_ACTIVATION_QUARANTINED;",
            "spin_unlock_irqrestore(&hw->lock, flags);",
            "return quarantined;",
        ),
        "rk_mpp_hw_clear_active_job": (
            "struct rk_mpp_activation *activation;",
            "unsigned long flags;",
            "bool cleared = false;",
            "if (!token) return false;",
            "spin_lock_irqsave(&hw->lock, flags);",
            "activation = rk_mpp_hw_claim_active_locked(hw, "
            "job->current_activation, 0, reason, token);",
            "if (activation) { if (irq_status) *irq_status = hw->irq_status;",
            "rk_mpp_hw_clear_irq_record_locked(hw);",
            "cleared = true;",
            "} spin_unlock_irqrestore(&hw->lock, flags);",
            "if (cleared) rk_mpp_hw_cancel_timeout(hw);",
            "return cleared;",
        ),
    }
    for name, expected in exact_helpers.items():
        statements = tuple(statement for _line, statement in by_name[name].statements)
        if statements != expected:
            raise ValueError(f"{name}: exact claim/quarantine contract drifted")

    whole_token_writes = [
        (function.name, statement)
        for function in functions
        for _line, statement in function.statements
        if re.search(r"\b(?:memset|memcpy|memmove)\s*\(\s*token\b", statement)
    ]
    if whole_token_writes != [
        ("rk_mpp_hw_restore_active_locked", "memset(token, 0, sizeof(*token));"),
        ("rk_mpp_activation_claim_put", "memset(token, 0, sizeof(*token));"),
        (
            "rk_mpp_activation_claim_quarantine",
            "memset(token, 0, sizeof(*token));",
        ),
    ]:
        raise ValueError(f"whole claim token writes drifted: {whole_token_writes}")

    require_control_counts(
        by_name, "rk_mpp_activation_finish_terminal_locked", returns=5, branches=5
    )
    require_ordered_fragments(
        by_name,
        "rk_mpp_activation_finish_terminal_locked",
        (
            "!token->owns_job_ref",
            "activation->generation != token->generation",
            "activation->transition_reason != token->reason",
            "activation->slot_state != RK_MPP_ACTIVATION_CLAIMED",
            "hw->active_activation",
            "group_status || !group->quiesced",
            "job->rkvdec_ccu != ccu",
            "lockdep_assert_held(&ccu->ccu_recovery_lock)",
            "activation->closure.group.result = *group",
            "activation->closure.group.status = group_status",
            "activation->closure.group.valid = true",
            "activation->closure.core.result = *core",
            "activation->closure.core.status = core_status",
            "activation->closure.core.valid = true",
            "RK_MPP_ACTIVATION_RETIREMENT_CCU_GROUP",
            "core_status || !core->quiesced",
            "activation->closure.terminal.result = *core",
            "activation->closure.terminal.status = core_status",
            "activation->closure.terminal.valid = true",
            "RK_MPP_ACTIVATION_RETIREMENT_CORE",
            "RK_MPP_ACTIVATION_CLOSURE_RETIRED",
            "RK_MPP_ACTIVATION_RETIRED",
        ),
    )
    require_control_counts(
        by_name, "rk_mpp_activation_claim_quarantine", returns=3, branches=10
    )
    quarantine_statements = tuple(
        statement
        for _line, statement in by_name[
            "rk_mpp_activation_claim_quarantine"
        ].statements
    )
    required_quarantine_predicates = {
        "if (!token || !token->owns_job_ref || !token->activation || "
        "!token->generation || token->reason <= RK_MPP_TRANSITION_NONE || "
        "token->reason >= RK_MPP_TRANSITION_RETRY_REPLACED) return false;",
        "if (!job || list_empty(&activation->job_link)) return false;",
        "error = quarantine_error ?: core_status ?: group_status ?: -EUCLEAN;",
    }
    if not required_quarantine_predicates.issubset(quarantine_statements):
        raise ValueError("quarantine total-sink predicates drifted")
    require_ordered_fragments(
        by_name,
        "rk_mpp_activation_claim_quarantine",
        (
            "error = quarantine_error ?: core_status ?: group_status ?: -EUCLEAN",
            "mutex_lock(&srv->quarantine_lock)",
            "spin_lock_irqsave(&hw->lock, flags)",
            "activation->closure.group.result = *group",
            "activation->closure.group.status = group_status",
            "activation->closure.core.result = *core",
            "activation->closure.core.status = core_status",
            "activation->closure.terminal.result = *core",
            "activation->closure.terminal.status = core_status",
            "RK_MPP_ACTIVATION_CLOSURE_QUARANTINED",
            "RK_MPP_ACTIVATION_QUARANTINED",
            "activation->transition_reason = token->reason",
            "activation->quarantine_generation = token->generation",
            "list_add_tail(&activation->quarantine_link, "
            "&srv->quarantined_activations)",
            "atomic_inc(&srv->quarantine_count)",
            "activation->quarantine_ref_count++",
            "memset(token, 0, sizeof(*token))",
            "spin_unlock_irqrestore(&hw->lock, flags)",
            "mutex_unlock(&srv->quarantine_lock)",
            "rk_mpp_hw_handle_reset_failure(hw, error)",
            "rk_mpp_hw_handle_reset_failure(owned_ccu, error)",
        ),
    )
    normalized = normalize(production)
    for fragment, expected_count in {
        "-EUCLEAN, reset_ret, &recovery": 8,
        "-EUCLEAN, stop_ret, &recovery": 3,
        "false, reset_ret, reset_ret, &recovery": 4,
        "iommu_fault, reset_ret, reset_ret, &recovery": 1,
    }.items():
        if normalized.count(fragment) != expected_count:
            raise ValueError(f"quarantine error/proof status split drifted: {fragment}")
    require_ordered_fragments(
        by_name,
        "rk_mpp_hw_remove",
        (
            "if (rk_mpp_service_has_quarantined_activation(hw->srv)) { "
            "dma_unquiesced = true",
            "if (!stop_ret) stop_ret = -EUCLEAN",
        ),
    )
    require_ordered_fragments(
        by_name,
        "rk_mpp_hw_shutdown",
        (
            "if (rk_mpp_service_has_quarantined_activation(hw->srv)) { "
            "dev_crit(hw->dev, \"shutdown retaining quarantined DMA ownership "
            "until reboot\\n\")",
            "rk_mpp_hw_disable_irq(hw); return;",
        ),
    )


def validate_mpp_observed_terminal_contract(
    source: pathlib.Path, functions: list[FunctionBody]
) -> None:
    """Hard-guard immutable clean-terminal observation and refusal retention."""

    production = production_source_text(source, KUNIT_MARKERS[MPP_SOURCE])
    record_type = r"\bstruct\s+rk_mpp_activation_observation_record\b"
    if (
        re.search(rf"{record_type}\s*\*", production)
        or re.search(rf"\btypedef\b[^;]*{record_type}", production)
        or re.search(
            r"\b(?:typeof|__typeof__|__auto_type)\b[^;]*"
            r"(?:observation|closure)",
            production,
        )
    ):
        raise ValueError(
            "observation record pointer, typedef, or inferred aliases are forbidden"
        )
    if len(re.findall(record_type, production)) != 2:
        raise ValueError(
            "activation observation record may exist only as its schema and member"
        )
    if re.search(
        r"(?<!&)&(?!&)[^,;()]*\bclosure\s*\.\s*observation\b|"
        r"\b(?:memset|memcpy|memmove)\s*\([^;]*"
        r"\bclosure\s*\.\s*observation\b|"
        r"\)\s*->\s*closure\s*\.\s*observation\b",
        production,
    ):
        raise ValueError("observation record address, memory, or result escape is forbidden")

    by_name = function_map(functions)
    exact_helpers = {
        "rk_mpp_activation_observation_pristine": (
            "return activation->closure.observation.kind == "
            "RK_MPP_ACTIVATION_OBSERVATION_NONE && "
            "!activation->closure.observation.hw_status && "
            "!activation->closure.observation.bus_idle_status && "
            "!activation->closure.observation.bus_idle_checked && "
            "!activation->closure.observation.valid;",
        ),
        "rk_mpp_activation_observation_matches": (
            "struct rk_mpp_job *job = activation->job;",
            "if (!activation->closure.observation.valid) return false;",
            "switch (activation->closure.observation.kind) { case "
            "RK_MPP_ACTIVATION_OBSERVATION_NOT_PUBLISHED: return "
            "activation->transition_reason == RK_MPP_TRANSITION_START_FAILURE && "
            "!activation->closure.observation.hw_status && "
            "!activation->closure.observation.bus_idle_status && "
            "!activation->closure.observation.bus_idle_checked;",
            "case RK_MPP_ACTIVATION_OBSERVATION_IRQ_ACCEPTED: if "
            "(activation->transition_reason != RK_MPP_TRANSITION_IRQ || "
            "!activation->closure.observation.hw_status || !job) return false;",
            "if (job->client_type == RK_MPP_DEVICE_RKVDEC) return "
            "activation->closure.observation.bus_idle_checked || "
            "activation->closure.observation.bus_idle_status == -EOPNOTSUPP;",
            "return !activation->closure.observation.bus_idle_checked && "
            "!activation->closure.observation.bus_idle_status;",
            "case RK_MPP_ACTIVATION_OBSERVATION_CCU_DONE_ACCEPTED: return "
            "activation->transition_reason == RK_MPP_TRANSITION_CCU_DONE && "
            "activation->closure.observation.hw_status && job && "
            "job->client_type == RK_MPP_DEVICE_RKVDEC && "
            "(activation->closure.observation.bus_idle_checked || "
            "activation->closure.observation.bus_idle_status == -EOPNOTSUPP);",
            "default: return false;",
        ),
        "rk_mpp_activation_finish_observed_terminal_locked": (
            "struct rk_mpp_activation *activation;",
            "struct rk_mpp_job *job;",
            "lockdep_assert_held(&hw->run_lock);",
            "lockdep_assert_held(&hw->lock);",
            "if (!token || !token->owns_job_ref || !token->activation || "
            "observation <= RK_MPP_ACTIVATION_OBSERVATION_NONE || "
            "observation >= RK_MPP_ACTIVATION_OBSERVATION_COUNT) return false;",
            "activation = token->activation;",
            "job = activation->job;",
            "if (!job || activation != READ_ONCE(job->current_activation) || "
            "activation->selected_hw != hw || list_empty(&activation->job_link) || "
            "activation->generation != token->generation || "
            "activation->transition_reason != token->reason || "
            "activation->slot_state != RK_MPP_ACTIVATION_CLAIMED || "
            "!rk_mpp_activation_closure_pristine(activation) || "
            "hw->active_activation) return false;",
            "switch (observation) { case "
            "RK_MPP_ACTIVATION_OBSERVATION_NOT_PUBLISHED: if "
            "(token->reason != RK_MPP_TRANSITION_START_FAILURE || ccu || "
            "hw_status || bus_idle_checked || bus_idle_status) return false;",
            "break;",
            "case RK_MPP_ACTIVATION_OBSERVATION_IRQ_ACCEPTED: if "
            "(token->reason != RK_MPP_TRANSITION_IRQ || ccu || !hw_status) "
            "return false;",
            "if (job->client_type == RK_MPP_DEVICE_RKVDEC) { if "
            "(!bus_idle_checked && bus_idle_status != -EOPNOTSUPP) return false;",
            "} else if (bus_idle_checked || bus_idle_status) { return false;",
            "} break;",
            "case RK_MPP_ACTIVATION_OBSERVATION_CCU_DONE_ACCEPTED: if "
            "(token->reason != RK_MPP_TRANSITION_CCU_DONE || !hw_status || "
            "!ccu || job->rkvdec_ccu != ccu || READ_ONCE(hw->cluster) != "
            "READ_ONCE(ccu->cluster) || (!bus_idle_checked && "
            "bus_idle_status != -EOPNOTSUPP)) return false;",
            "lockdep_assert_held(&ccu->ccu_recovery_lock);",
            "break;",
            "default: return false;",
            "} activation->closure.observation.kind = observation;",
            "activation->closure.observation.hw_status = hw_status;",
            "activation->closure.observation.bus_idle_status = bus_idle_status;",
            "activation->closure.observation.bus_idle_checked = bus_idle_checked;",
            "activation->closure.observation.valid = true;",
            "activation->closure.state = RK_MPP_ACTIVATION_CLOSURE_RETIRED;",
            "activation->slot_state = RK_MPP_ACTIVATION_RETIRED;",
            "return true;",
        ),
        "rk_mpp_activation_finish_observed_terminal": (
            "unsigned long flags;",
            "bool finished;",
            "lockdep_assert_held(&hw->run_lock);",
            "spin_lock_irqsave(&hw->lock, flags);",
            "finished = rk_mpp_activation_finish_observed_terminal_locked(hw, "
            "ccu, token, observation, hw_status, bus_idle_checked, "
            "bus_idle_status);",
            "spin_unlock_irqrestore(&hw->lock, flags);",
            "return finished;",
        ),
        "rk_mpp_rkvdec2_wait_bus_idle": (
            "u32 value;",
            "int ret;",
            "if (checked) *checked = false;",
            "if (atomic_read(&hw->power_count) <= 0 || "
            "!rk_mpp_hw_reg_range_valid(hw, 0, RK_MPP_RKVDEC_DEBUG_INT_BASE, "
            "sizeof(u32))) return -EOPNOTSUPP;",
            "if (checked) *checked = true;",
            "ret = readl_poll_timeout(hw->regs[0] + "
            "RK_MPP_RKVDEC_DEBUG_INT_BASE, value, value & "
            "RK_MPP_RKVDEC_DEBUG_BUS_IDLE, 1, RK_MPP_CCU_STOP_TIMEOUT_US);",
            "if (ret) { atomic_inc(&hw->srv->rkvdec_bus_not_idle_count);",
            "if (hw->dev) dev_warn_ratelimited(hw->dev, \"completing job with "
            "bus not idle after %uus\\n\", RK_MPP_CCU_STOP_TIMEOUT_US);",
            "} return ret;",
        ),
    }
    for name, expected in exact_helpers.items():
        if sum(function.name == name for function in functions) != 1:
            raise ValueError(f"expected one production function {name}")
        actual = tuple(statement for _line, statement in by_name[name].statements)
        if actual != expected:
            raise ValueError(f"{name}: clean-terminal observation contract drifted")

    for name, expected in {
        "rk_mpp_activation_finish_observed_terminal_locked": {
            "return": 9,
            "if": 8,
            "switch": 1,
            "break": 3,
            "goto": 0,
        },
        "rk_mpp_activation_observation_matches": {
            "return": 7,
            "if": 3,
            "switch": 1,
            "break": 0,
            "goto": 0,
        },
    }.items():
        text = by_name[name].text
        actual = {
            word: len(re.findall(rf"\b{word}\b", text))
            for word in ("return", "if", "switch", "break", "goto")
        }
        if actual != expected or re.search(r"\bcontinue\b", text):
            raise ValueError(f"{name}: unexpected control-transfer shape {actual}")
    expected_calls = {
        "rk_mpp_activation_observation_pristine": {
            "rk_mpp_activation_storage_released": 2,
        },
        "rk_mpp_activation_observation_matches": {
            "rk_mpp_activation_storage_released": 1,
        },
        "rk_mpp_rkvdec2_wait_bus_idle": {
            "rk_mpp_rkvdec2_drain_ccu_done_jobs": 1,
            "rk_mpp_rkvdec2_thread": 1,
        },
    }
    for callee, expected in expected_calls.items():
        actual = {
            function.name: count
            for function in functions
            if (count := len(re.findall(rf"\b{re.escape(callee)}\s*\(", function.text)))
        }
        if actual != expected:
            raise ValueError(f"unexpected {callee} call map: {actual}")

    clean_callers = {
        "rk_mpp_rkvdec2_drain_ccu_done_jobs",
        "rk_mpp_rkvenc2_submit",
        "rk_mpp_rkvenc2_thread",
        "rk_mpp_rkvdec2_submit",
        "rk_mpp_rkvdec2_thread",
        "rk_mpp_av1_submit",
        "rk_mpp_av1_thread",
    }
    for name in clean_callers:
        statements = [statement for _line, statement in by_name[name].statements]
        observed = [
            index
            for index, statement in enumerate(statements)
            if "rk_mpp_activation_finish_observed_terminal(" in statement
        ]
        quarantines = [
            index
            for index, statement in enumerate(statements)
            if "rk_mpp_activation_claim_quarantine(" in statement
        ]
        if len(observed) != len(quarantines):
            raise ValueError(f"{name}: observed-terminal refusal sink drifted")
        for observed_index, quarantine_index in zip(observed, quarantines):
            if quarantine_index != observed_index + 1 or not statements[
                quarantine_index
            ].startswith(
                "if (WARN_ON_ONCE(!finished)) { quarantined = "
                "rk_mpp_activation_claim_quarantine("
            ):
                raise ValueError(f"{name}: observation refusal must directly quarantine")
            later_put = next(
                (
                    index
                    for index in range(quarantine_index + 1, len(statements))
                    if "rk_mpp_activation_claim_put(" in statements[index]
                ),
                None,
            )
            if later_put is not None:
                refusal_span = " ".join(
                    statements[quarantine_index : later_put + 1]
                )
                if not re.search(
                    r"\b(?:return|goto|continue|break)\b|\}\s*else\s*\{",
                    refusal_span,
                ):
                    raise ValueError(
                        f"{name}: observation refusal can fall through to claim put"
                    )

    require_ordered_fragments(
        by_name,
        "rk_mpp_rkvdec2_drain_ccu_done_jobs",
        (
            "ccu_error = !!(completed_status & link_info->err_mask)",
            "bus_idle_status = rk_mpp_rkvdec2_wait_bus_idle(hw, "
            "&bus_idle_checked)",
            "finished = ccu_error || "
            "rk_mpp_activation_finish_observed_terminal(hw, ccu, &claim, "
            "observation, completed_status, bus_idle_checked, bus_idle_status)",
        ),
    )
    for name, error_mask in (
        ("rk_mpp_rkvenc2_thread", "rk_mpp_rkvenc2_irq_needs_reset(irq_status)"),
        ("rk_mpp_rkvdec2_thread", "!!(irq_status & link_info->err_mask)"),
        ("rk_mpp_av1_thread", "!!(irq_status & RK_MPP_AV1_ERR_MASK)"),
    ):
        require_ordered_fragments(
            by_name,
            name,
            (
                f"finished = {error_mask} || "
                "rk_mpp_activation_finish_observed_terminal",
            ),
        )

    av1_statements = [statement for _line, statement in by_name["rk_mpp_av1_submit"].statements]
    retained = next(
        (
            index
            for index, statement in enumerate(av1_statements)
            if statement.startswith("if (start_failed_untrusted && active_owned) {")
        ),
        None,
    )
    expected_retained = (
        "if (start_failed_untrusted && active_owned) { stop_ret = "
        "rk_mpp_hw_stop_and_recover(hw, job, &recovery);",
        "if (stop_ret) { rk_mpp_hw_handle_reset_failure(hw, stop_ret);",
        "mutex_unlock(&hw->run_lock);",
        "return 0;",
    )
    if retained is None or tuple(av1_statements[retained : retained + 4]) != expected_retained:
        raise ValueError("AV1 failed-stop must retain the active SLOTTED owner for retry")
    forbidden_retirement = re.compile(
        r"\brk_mpp_(?:hw_clear_active_job|activation_(?:finish|claim_put|"
        r"claim_quarantine))\s*\("
    )
    if any(forbidden_retirement.search(statement) for statement in av1_statements[retained + 1 : retained + 4]):
        raise ValueError("AV1 failed-stop branch may not retire or tombstone the active slot")


def unique_struct_member_declaration(
    source: pathlib.Path, structure: str, member: str
) -> tuple[int, str]:
    """Return one exact member from one exact production struct definition."""

    lines = strip_comments(source.read_text(encoding="utf-8").splitlines())
    structure_starts = [
        index
        for index, line in enumerate(lines)
        if re.search(rf"\bstruct\s+{re.escape(structure)}\s*\{{", line)
    ]
    if len(structure_starts) != 1:
        raise ValueError(
            f"expected one struct {structure} definition in {source}, "
            f"found {len(structure_starts)}"
        )

    start = structure_starts[0]
    depth = 0
    end: int | None = None
    for index in range(start, len(lines)):
        depth += brace_delta(lines[index])
        if depth == 0 and ";" in lines[index]:
            end = index
            break
    if end is None:
        raise ValueError(f"unterminated struct {structure} definition in {source}")

    in_structure = [
        (index + 1, normalize(lines[index]))
        for index in range(start, end + 1)
        if member in lines[index]
    ]
    all_occurrences = sum(line.count(member) for line in lines)
    if len(in_structure) != 1 or all_occurrences != 1:
        raise ValueError(
            f"expected one {member} in struct {structure} in {source}, "
            f"found {len(in_structure)} there and {all_occurrences} overall"
        )
    return in_structure[0]


def struct_member_pattern_matches(
    source: pathlib.Path, structure: str, pattern: re.Pattern[str]
) -> tuple[list[tuple[int, str]], int]:
    """Return matches inside one exact struct plus the source-wide count."""

    lines = strip_comments(source.read_text(encoding="utf-8").splitlines())
    structure_starts = [
        index
        for index, line in enumerate(lines)
        if re.search(rf"\bstruct\s+{re.escape(structure)}\s*\{{", line)
    ]
    if len(structure_starts) != 1:
        raise ValueError(
            f"expected one struct {structure} definition in {source}, "
            f"found {len(structure_starts)}"
        )

    start = structure_starts[0]
    depth = 0
    end: int | None = None
    for index in range(start, len(lines)):
        depth += brace_delta(lines[index])
        if depth == 0 and ";" in lines[index]:
            end = index
            break
    if end is None:
        raise ValueError(f"unterminated struct {structure} definition in {source}")

    in_structure = [
        (index + 1, normalize(lines[index]))
        for index in range(start, end + 1)
        if pattern.search(lines[index])
    ]
    all_occurrences = sum(bool(pattern.search(line)) for line in lines)
    return in_structure, all_occurrences


def unique_struct_member_pattern(
    source: pathlib.Path,
    structure: str,
    pattern: re.Pattern[str],
    description: str,
) -> tuple[int, str]:
    """Return one regex-matched member scoped to one exact struct."""

    matches, all_occurrences = struct_member_pattern_matches(
        source, structure, pattern
    )
    if len(matches) != 1 or all_occurrences != 1:
        raise ValueError(
            f"expected one {description} in struct {structure} in {source}, "
            f"found {len(matches)} there and {all_occurrences} overall"
        )
    return matches[0]


def required_struct_member_pattern(
    source: pathlib.Path,
    structure: str,
    pattern: re.Pattern[str],
    description: str,
) -> tuple[int, str]:
    """Return one regex-matched member scoped to the named struct."""

    matches, _all_occurrences = struct_member_pattern_matches(
        source, structure, pattern
    )
    if len(matches) != 1:
        raise ValueError(
            f"expected one {description} in struct {structure} in {source}, "
            f"found {len(matches)}"
        )
    return matches[0]


def forbid_struct_member_pattern(
    source: pathlib.Path,
    structure: str,
    pattern: re.Pattern[str],
    description: str,
) -> None:
    """Fail if a removed ownership member returns to the named struct."""

    matches, _all_occurrences = struct_member_pattern_matches(
        source, structure, pattern
    )
    if matches:
        raise ValueError(
            f"forbidden {description} in struct {structure} in {source}: "
            f"found {len(matches)}"
        )


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
            for category, declaration, expected in (
                (
                    "mpp-activation-recovery-record-schema",
                    "struct rk_mpp_activation_recovery_record {",
                    "struct rk_mpp_activation_recovery_record { "
                    "struct rk_mpp_cluster_recovery_result result; "
                    "int status; bool valid; };",
                ),
                (
                    "mpp-activation-closure-schema",
                    "struct rk_mpp_activation_closure {",
                    "struct rk_mpp_activation_closure { "
                    "enum rk_mpp_activation_closure_state state; "
                    "struct rk_mpp_activation_recovery_record group; "
                    "struct rk_mpp_activation_recovery_record core; "
                    "struct rk_mpp_activation_recovery_record terminal; "
                    "enum rk_mpp_activation_retirement_scope terminal_scope; "
                    "struct rk_mpp_activation_observation_record observation; };",
                ),
                (
                    "mpp-activation-observation-record-schema",
                    "struct rk_mpp_activation_observation_record {",
                    "struct rk_mpp_activation_observation_record { "
                    "enum rk_mpp_activation_terminal_observation kind; "
                    "u32 hw_status; int bus_idle_status; "
                    "bool bus_idle_checked; bool valid; };",
                ),
                (
                    "mpp-activation-retry-token-schema",
                    "struct rk_mpp_activation_retry_token {",
                    "struct rk_mpp_activation_retry_token { "
                    "struct rk_mpp_activation *activation; u64 generation; };",
                ),
                (
                    "mpp-activation-claim-token-schema",
                    "struct rk_mpp_activation_claim_token {",
                    "struct rk_mpp_activation_claim_token { "
                    "struct rk_mpp_activation *activation; u64 generation; "
                    "enum rk_mpp_activation_transition_reason reason; "
                    "bool owns_job_ref; };",
                ),
            ):
                schema_line, schema_text = exact_declaration_block(
                    source, declaration, expected
                )
                found.append(
                    (
                        category,
                        relative,
                        "<file-scope>",
                        schema_text,
                        schema_line,
                    )
                )
            stripped_source = "\n".join(
                strip_comments(source.read_text(encoding="utf-8").splitlines())
            )
            for category, declaration, expected in (
                (
                    "mpp-activation-slot-state-enum-schema",
                    "enum rk_mpp_activation_slot_state {",
                    "enum rk_mpp_activation_slot_state { "
                    "RK_MPP_ACTIVATION_UNINSTALLED, "
                    "RK_MPP_ACTIVATION_SLOTTED, "
                    "RK_MPP_ACTIVATION_CLAIMED, "
                    "RK_MPP_ACTIVATION_SUPERSEDED, "
                    "RK_MPP_ACTIVATION_RETIRED, "
                    "RK_MPP_ACTIVATION_QUARANTINED, };",
                ),
                (
                    "mpp-activation-transition-reason-enum-schema",
                    "enum rk_mpp_activation_transition_reason {",
                    "enum rk_mpp_activation_transition_reason { "
                    "RK_MPP_TRANSITION_NONE, RK_MPP_TRANSITION_START_FAILURE, "
                    "RK_MPP_TRANSITION_IRQ, RK_MPP_TRANSITION_CCU_DONE, "
                    "RK_MPP_TRANSITION_TIMEOUT, RK_MPP_TRANSITION_IOMMU_FAULT, "
                    "RK_MPP_TRANSITION_SESSION_RESET, "
                    "RK_MPP_TRANSITION_SESSION_CLOSE, RK_MPP_TRANSITION_REMOVE, "
                    "RK_MPP_TRANSITION_SHUTDOWN, "
                    "RK_MPP_TRANSITION_CCU_DEPENDENT_ABORT, "
                    "RK_MPP_TRANSITION_RETRY_REPLACED, "
                    "RK_MPP_TRANSITION_COUNT, };",
                ),
                (
                    "mpp-activation-closure-state-enum-schema",
                    "enum rk_mpp_activation_closure_state {",
                    "enum rk_mpp_activation_closure_state { "
                    "RK_MPP_ACTIVATION_CLOSURE_NONE, "
                    "RK_MPP_ACTIVATION_CLOSURE_PENDING, "
                    "RK_MPP_ACTIVATION_CLOSURE_RETIRED, "
                    "RK_MPP_ACTIVATION_CLOSURE_QUARANTINED, };",
                ),
                (
                    "mpp-activation-retirement-scope-enum-schema",
                    "enum rk_mpp_activation_retirement_scope {",
                    "enum rk_mpp_activation_retirement_scope { "
                    "RK_MPP_ACTIVATION_RETIREMENT_NONE, "
                    "RK_MPP_ACTIVATION_RETIREMENT_CORE, "
                    "RK_MPP_ACTIVATION_RETIREMENT_CCU_GROUP, };",
                ),
                (
                    "mpp-activation-terminal-observation-enum-schema",
                    "enum rk_mpp_activation_terminal_observation {",
                    "enum rk_mpp_activation_terminal_observation { "
                    "RK_MPP_ACTIVATION_OBSERVATION_NONE, "
                    "RK_MPP_ACTIVATION_OBSERVATION_NOT_PUBLISHED, "
                    "RK_MPP_ACTIVATION_OBSERVATION_IRQ_ACCEPTED, "
                    "RK_MPP_ACTIVATION_OBSERVATION_CCU_DONE_ACCEPTED, "
                    "RK_MPP_ACTIVATION_OBSERVATION_COUNT, };",
                ),
            ):
                enum_name = declaration.split("{", 1)[0].strip()
                if len(re.findall(rf"\b{re.escape(enum_name)}\s*\{{", stripped_source)) != 1:
                    raise ValueError(f"expected one {enum_name} definition in {source}")
                enum_line, enum_text = declaration_block(source, declaration)
                if enum_text != normalize(expected):
                    raise ValueError(
                        f"unexpected {enum_name} definition in {source}: {enum_text}"
                    )
                found.append(
                    (category, relative, "<file-scope>", enum_text, enum_line)
                )
            for category, pattern, description in (
                (
                    "mpp-activation-link-schema",
                    re.compile(r"\bstruct\s+list_head\s+job_link\s*;"),
                    "struct list_head job_link member",
                ),
                (
                    "mpp-activation-quarantine-link-schema",
                    re.compile(r"\bstruct\s+list_head\s+quarantine_link\s*;"),
                    "struct list_head quarantine_link member",
                ),
                (
                    "mpp-activation-quarantine-ref-schema",
                    re.compile(r"\bu32\s+quarantine_ref_count\s*;"),
                    "u32 quarantine_ref_count member",
                ),
                (
                    "mpp-activation-quarantine-generation-schema",
                    re.compile(r"\bu64\s+quarantine_generation\s*;"),
                    "u64 quarantine_generation member",
                ),
                (
                    "mpp-activation-parent-schema",
                    re.compile(r"\bstruct\s+rk_mpp_job\s*\*\s*job\s*;"),
                    "struct rk_mpp_job *job member",
                ),
                (
                    "mpp-activation-generation-schema",
                    re.compile(r"\bu64\s+generation\s*;"),
                    "u64 generation member",
                ),
                (
                    "mpp-activation-deadline-schema",
                    re.compile(r"\bunsigned\s+long\s+watchdog_deadline\s*;"),
                    "unsigned long watchdog_deadline member",
                ),
                (
                    "mpp-activation-deadline-valid-schema",
                    re.compile(r"\bbool\s+watchdog_deadline_valid\s*;"),
                    "bool watchdog_deadline_valid member",
                ),
                (
                    "mpp-activation-slot-state-schema",
                    re.compile(
                        r"\benum\s+rk_mpp_activation_slot_state\s+"
                        r"slot_state\s*;"
                    ),
                    "enum rk_mpp_activation_slot_state slot_state member",
                ),
                (
                    "mpp-activation-transition-reason-schema",
                    re.compile(
                        r"\benum\s+rk_mpp_activation_transition_reason\s+"
                        r"transition_reason\s*;"
                    ),
                    "enum rk_mpp_activation_transition_reason transition_reason member",
                ),
                (
                    "mpp-activation-closure-member-schema",
                    re.compile(
                        r"\bstruct\s+rk_mpp_activation_closure\s+closure\s*;"
                    ),
                    "struct rk_mpp_activation_closure closure member",
                ),
            ):
                line, text = required_struct_member_pattern(
                    source, "rk_mpp_activation", pattern, description
                )
                found.append((category, relative, "<file-scope>", text, line))
            for structure, members in (
                (
                    "rk_mpp_activation_recovery_record",
                    (
                        (
                            "mpp-activation-recovery-result-member-schema",
                            re.compile(
                                r"\bstruct\s+rk_mpp_cluster_recovery_result\s+"
                                r"result\s*;"
                            ),
                            "struct rk_mpp_cluster_recovery_result result member",
                        ),
                        (
                            "mpp-activation-recovery-status-schema",
                            re.compile(r"\bint\s+status\s*;"),
                            "int status member",
                        ),
                        (
                            "mpp-activation-recovery-valid-schema",
                            re.compile(r"\bbool\s+valid\s*;"),
                            "bool valid member",
                        ),
                    ),
                ),
                (
                    "rk_mpp_activation_closure",
                    (
                        (
                            "mpp-activation-closure-state-schema",
                            re.compile(
                                r"\benum\s+rk_mpp_activation_closure_state\s+"
                                r"state\s*;"
                            ),
                            "enum rk_mpp_activation_closure_state state member",
                        ),
                        (
                            "mpp-activation-closure-group-schema",
                            re.compile(
                                r"\bstruct\s+rk_mpp_activation_recovery_record\s+"
                                r"group\s*;"
                            ),
                            "struct rk_mpp_activation_recovery_record group member",
                        ),
                        (
                            "mpp-activation-closure-core-schema",
                            re.compile(
                                r"\bstruct\s+rk_mpp_activation_recovery_record\s+"
                                r"core\s*;"
                            ),
                            "struct rk_mpp_activation_recovery_record core member",
                        ),
                        (
                            "mpp-activation-closure-terminal-schema",
                            re.compile(
                                r"\bstruct\s+rk_mpp_activation_recovery_record\s+"
                                r"terminal\s*;"
                            ),
                            "struct rk_mpp_activation_recovery_record terminal member",
                        ),
                        (
                            "mpp-activation-closure-scope-schema",
                            re.compile(
                                r"\benum\s+rk_mpp_activation_retirement_scope\s+"
                                r"terminal_scope\s*;"
                            ),
                            "enum rk_mpp_activation_retirement_scope terminal_scope member",
                        ),
                        (
                            "mpp-activation-closure-observation-schema",
                            re.compile(
                                r"\bstruct\s+rk_mpp_activation_observation_record\s+"
                                r"observation\s*;"
                            ),
                            "struct rk_mpp_activation_observation_record observation member",
                        ),
                    ),
                ),
                (
                    "rk_mpp_activation_observation_record",
                    (
                        (
                            "mpp-activation-observation-kind-schema",
                            re.compile(
                                r"\benum\s+rk_mpp_activation_terminal_observation\s+"
                                r"kind\s*;"
                            ),
                            "enum rk_mpp_activation_terminal_observation kind member",
                        ),
                        (
                            "mpp-activation-observation-hw-status-schema",
                            re.compile(r"\bu32\s+hw_status\s*;"),
                            "u32 hw_status member",
                        ),
                        (
                            "mpp-activation-observation-bus-status-schema",
                            re.compile(r"\bint\s+bus_idle_status\s*;"),
                            "int bus_idle_status member",
                        ),
                        (
                            "mpp-activation-observation-bus-checked-schema",
                            re.compile(r"\bbool\s+bus_idle_checked\s*;"),
                            "bool bus_idle_checked member",
                        ),
                        (
                            "mpp-activation-observation-valid-schema",
                            re.compile(r"\bbool\s+valid\s*;"),
                            "bool valid member",
                        ),
                    ),
                ),
                (
                    "rk_mpp_activation_retry_token",
                    (
                        (
                            "mpp-activation-retry-token-pointer-schema",
                            re.compile(
                                r"\bstruct\s+rk_mpp_activation\s*\*\s*"
                                r"activation\s*;"
                            ),
                            "struct rk_mpp_activation *activation member",
                        ),
                        (
                            "mpp-activation-retry-token-generation-schema",
                            re.compile(r"\bu64\s+generation\s*;"),
                            "u64 generation member",
                        ),
                    ),
                ),
                (
                    "rk_mpp_activation_claim_token",
                    (
                        (
                            "mpp-activation-claim-token-pointer-schema",
                            re.compile(
                                r"\bstruct\s+rk_mpp_activation\s*\*\s*"
                                r"activation\s*;"
                            ),
                            "struct rk_mpp_activation *activation member",
                        ),
                        (
                            "mpp-activation-claim-token-generation-schema",
                            re.compile(r"\bu64\s+generation\s*;"),
                            "u64 generation member",
                        ),
                        (
                            "mpp-activation-claim-token-reason-schema",
                            re.compile(
                                r"\benum\s+rk_mpp_activation_transition_reason\s+"
                                r"reason\s*;"
                            ),
                            "enum rk_mpp_activation_transition_reason reason member",
                        ),
                        (
                            "mpp-activation-claim-token-ref-schema",
                            re.compile(r"\bbool\s+owns_job_ref\s*;"),
                            "bool owns_job_ref member",
                        ),
                    ),
                ),
            ):
                for category, pattern, description in members:
                    member_line, member_text = required_struct_member_pattern(
                        source, structure, pattern, description
                    )
                    found.append(
                        (
                            category,
                            relative,
                            "<file-scope>",
                            member_text,
                            member_line,
                        )
                    )
            for category, pattern, description in (
                (
                    "mpp-active-activation-schema",
                    re.compile(
                        r"\bstruct\s+rk_mpp_activation\s*\*\s*"
                        r"active_activation\s*;"
                    ),
                    "struct rk_mpp_activation *active_activation member",
                ),
                (
                    "mpp-timeout-activation-schema",
                    re.compile(
                        r"\bstruct\s+rk_mpp_activation\s*\*\s*"
                        r"timeout_activation\s*;"
                    ),
                    "struct rk_mpp_activation *timeout_activation member",
                ),
                (
                    "mpp-activation-sequence-schema",
                    re.compile(r"\bu64\s+activation_generation_seq\s*;"),
                    "u64 activation_generation_seq member",
                ),
                (
                    "mpp-timeout-generation-schema",
                    re.compile(r"\bu64\s+timeout_generation\s*;"),
                    "u64 timeout_generation member",
                ),
            ):
                line, text = unique_struct_member_pattern(
                    source, "rk_mpp_hw", pattern, description
                )
                found.append((category, relative, "<file-scope>", text, line))
            for pattern, description in (
                (
                    re.compile(r"\bactive_job\b"),
                    "legacy active_job member",
                ),
                (
                    re.compile(r"\btimeout_job\b"),
                    "legacy timeout_job member",
                ),
            ):
                forbid_struct_member_pattern(
                    source, "rk_mpp_hw", pattern, description
                )
            line, text = unique_struct_member_pattern(
                source,
                "rk_mpp_activation",
                re.compile(r"\bstruct\s+rk_mpp_hw\s*\*\s*selected_hw\s*;"),
                "struct rk_mpp_hw *selected_hw member",
            )
            found.append(
                ("mpp-selected-hw-schema", relative, "<file-scope>", text, line)
            )
            for category, pattern, description in (
                (
                    "mpp-quarantine-lock-schema",
                    re.compile(r"\bstruct\s+mutex\s+quarantine_lock\s*;"),
                    "struct mutex quarantine_lock member",
                ),
                (
                    "mpp-quarantine-list-schema",
                    re.compile(
                        r"\bstruct\s+list_head\s+quarantined_activations\s*;"
                    ),
                    "struct list_head quarantined_activations member",
                ),
                (
                    "mpp-quarantine-count-schema",
                    re.compile(r"\batomic_t\s+quarantine_count\s*;"),
                    "atomic_t quarantine_count member",
                ),
            ):
                line, text = unique_struct_member_pattern(
                    source, "rk_mpp_service", pattern, description
                )
                found.append((category, relative, "<file-scope>", text, line))
            for category, pattern, description in (
                (
                    "mpp-activation-list-schema",
                    re.compile(r"\bstruct\s+list_head\s+activations\s*;"),
                    "struct list_head activations member",
                ),
                (
                    "mpp-activation-storage-schema",
                    re.compile(
                        r"\bstruct\s+rk_mpp_activation\s+"
                        r"activation_storage\s*;"
                    ),
                    "struct rk_mpp_activation activation_storage member",
                ),
                (
                    "mpp-current-activation-schema",
                    re.compile(
                        r"\bstruct\s+rk_mpp_activation\s*\*\s*"
                        r"current_activation\s*;"
                    ),
                    "struct rk_mpp_activation *current_activation member",
                ),
            ):
                line, text = unique_struct_member_pattern(
                    source, "rk_mpp_job", pattern, description
                )
                found.append((category, relative, "<file-scope>", text, line))
            forbid_struct_member_pattern(
                source,
                "rk_mpp_job",
                re.compile(
                    r"\bstruct\s+rk_mpp_activation\s+activation\b"
                ),
                "legacy activation member",
            )
            forbid_struct_member_pattern(
                source,
                "rk_mpp_job",
                re.compile(r"\bstruct\s+rk_mpp_hw\s*\*\s*hw\s*;"),
                "legacy struct rk_mpp_hw *hw member",
            )
            line, text = unique_struct_member_pattern(
                source,
                "rk_mpp_job",
                re.compile(r"\bstruct\s+rk_mpp_hw\s*\*\s*rkvdec_ccu\s*;"),
                "struct rk_mpp_hw *rkvdec_ccu member",
            )
            found.append(
                ("mpp-rkvdec-ccu-schema", relative, "<file-scope>", text, line)
            )
            line, text = unique_struct_member_declaration(
                source,
                "rk_mpp_session",
                "struct rk_mpp_activation *rkvdec_dispatch_owner;",
            )
            found.append(
                ("mpp-dispatch-owner-schema", relative, "<file-scope>", text, line)
            )
            for line, text in enumerate(
                strip_comments(source.read_text(encoding="utf-8").splitlines()),
                start=1,
            ):
                if DISPATCH_LEGACY_RE.search(text):
                    found.append(
                        (
                            "mpp-dispatch-legacy",
                            relative,
                            "<file-scope>",
                            normalize(text),
                            line,
                        )
                    )
        activation_typedefs = (
            set(
                ACTIVATION_TYPEDEF_RE.findall(
                    "\n".join(
                        strip_comments(
                            source.read_text(encoding="utf-8").splitlines()
                        )
                    )
                )
            )
            if relative == MPP_SOURCE
            else set()
        )
        activation_pointer_typedefs = (
            set(
                ACTIVATION_POINTER_TYPEDEF_RE.findall(
                    "\n".join(
                        strip_comments(
                            source.read_text(encoding="utf-8").splitlines()
                        )
                    )
                )
            )
            if relative == MPP_SOURCE
            else set()
        )
        functions = parse_functions(source, KUNIT_MARKERS[relative])
        if relative == MPP_SOURCE:
            validate_mpp_observed_terminal_contract(source, functions)
            validate_mpp_retry_retirement_contract(source, functions)
            validate_mpp_terminal_claim_contract(source, functions)
        if relative == MPP_SOURCE and sum(
            function.name == "rk_mpp_transition_yields_to_fault"
            for function in functions
        ) != 1:
            raise ValueError(
                "expected one rk_mpp_transition_yields_to_fault production function"
            )
        for function in functions:
            command_writer = False
            activation_patterns = (
                activation_function_patterns(
                    function,
                    activation_typedefs,
                    activation_pointer_typedefs,
                )
                if relative == MPP_SOURCE
                else None
            )
            if (
                relative == MPP_SOURCE
                and function.name == "rk_mpp_transition_yields_to_fault"
            ):
                reasons = re.findall(
                    r"RK_MPP_TRANSITION_[A-Z_]+", function.text
                )
                expected = [
                    "RK_MPP_TRANSITION_IRQ",
                    "RK_MPP_TRANSITION_CCU_DONE",
                    "RK_MPP_TRANSITION_TIMEOUT",
                ]
                if reasons != expected:
                    raise ValueError(
                        "fault-priority reasons must be exactly IRQ, "
                        "CCU_DONE, TIMEOUT"
                    )
                found.append(
                    (
                        "mpp-activation-fault-priority-schema",
                        relative,
                        function.name,
                        function.text,
                        function.first_line,
                    )
                )
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
                            (
                                "mpp-active-activation-access",
                                MPP_ACTIVE_ACTIVATION_ACCESS_RE,
                            ),
                            (
                                "mpp-active-activation-write",
                                MPP_ACTIVE_ACTIVATION_WRITE_RE,
                            ),
                            (
                                "mpp-timeout-activation-access",
                                MPP_TIMEOUT_ACTIVATION_ACCESS_RE,
                            ),
                            (
                                "mpp-timeout-activation-write",
                                MPP_TIMEOUT_ACTIVATION_WRITE_RE,
                            ),
                            (
                                "mpp-activation-sequence-access",
                                MPP_ACTIVATION_SEQUENCE_ACCESS_RE,
                            ),
                            (
                                "mpp-activation-sequence-write",
                                MPP_ACTIVATION_SEQUENCE_WRITE_RE,
                            ),
                            (
                                "mpp-timeout-generation-access",
                                MPP_TIMEOUT_GENERATION_ACCESS_RE,
                            ),
                            (
                                "mpp-timeout-generation-write",
                                MPP_TIMEOUT_GENERATION_WRITE_RE,
                            ),
                            ("mpp-slot-legacy", MPP_SLOT_LEGACY_RE),
                            (
                                "mpp-activation-entry",
                                MPP_ACTIVATION_ENTRY_RE,
                            ),
                            (
                                "mpp-current-activation-access",
                                MPP_CURRENT_ACTIVATION_ACCESS_RE,
                            ),
                            (
                                "mpp-current-activation-write",
                                MPP_CURRENT_ACTIVATION_WRITE_RE,
                            ),
                            (
                                "mpp-activation-storage-access",
                                MPP_ACTIVATION_STORAGE_ACCESS_RE,
                            ),
                            (
                                "mpp-activation-list-access",
                                MPP_ACTIVATION_LIST_ACCESS_RE,
                            ),
                            (
                                "mpp-activation-list-write",
                                MPP_ACTIVATION_LIST_WRITE_RE,
                            ),
                            (
                                "mpp-active-transition-entry",
                                MPP_ACTIVE_TRANSITION_ENTRY_RE,
                            ),
                            (
                                "mpp-slot-legacy-helper",
                                MPP_SLOT_LEGACY_HELPER_RE,
                            ),
                            (
                                "mpp-rkvdec-ccu-access",
                                MPP_RKVDEC_CCU_ACCESS_RE,
                            ),
                            (
                                "mpp-rkvdec-ccu-write",
                                MPP_RKVDEC_CCU_WRITE_RE,
                            ),
                            ("mpp-dispatch-lease-access", DISPATCH_OWNER_ACCESS_RE),
                            ("mpp-dispatch-lease-write", DISPATCH_OWNER_WRITE_RE),
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
                    activation_relevant = any(
                        marker in statement
                        for marker in (
                            "activation",
                            "selected_hw",
                            "slot_state",
                            "transition_reason",
                            "generation",
                            "watchdog_deadline",
                            "closure",
                            "job_link",
                            "kzalloc_obj",
                            "kfree",
                        )
                    ) or "struct rk_mpp_activation" in (
                        function.signature + function.text
                    )
                    if activation_relevant:
                        matches.extend(
                            (
                                ("mpp-activation-access", activation_patterns.access),
                                ("mpp-activation-write", activation_patterns.write),
                                (
                                    "mpp-activation-parent-write",
                                    activation_patterns.parent_write,
                                ),
                                (
                                    "mpp-activation-generation-write",
                                    activation_patterns.generation_write,
                                ),
                                (
                                    "mpp-activation-deadline-write",
                                    activation_patterns.deadline_write,
                                ),
                                (
                                    "mpp-activation-slot-state-access",
                                    activation_patterns.slot_state_access,
                                ),
                                (
                                    "mpp-activation-slot-state-write",
                                    activation_patterns.slot_state_write,
                                ),
                                (
                                    "mpp-activation-transition-reason-access",
                                    activation_patterns.reason_access,
                                ),
                                (
                                    "mpp-activation-transition-reason-write",
                                    activation_patterns.reason_write,
                                ),
                                (
                                    "mpp-activation-closure-access",
                                    activation_patterns.closure_access,
                                ),
                                (
                                    "mpp-activation-closure-write",
                                    activation_patterns.closure_write,
                                ),
                                (
                                    "mpp-activation-closure-state-access",
                                    activation_patterns.closure_state_access,
                                ),
                                (
                                    "mpp-activation-closure-state-write",
                                    activation_patterns.closure_state_write,
                                ),
                                (
                                    "mpp-activation-closure-group-access",
                                    activation_patterns.closure_group_access,
                                ),
                                (
                                    "mpp-activation-closure-group-write",
                                    activation_patterns.closure_group_write,
                                ),
                                (
                                    "mpp-activation-closure-core-access",
                                    activation_patterns.closure_core_access,
                                ),
                                (
                                    "mpp-activation-closure-core-write",
                                    activation_patterns.closure_core_write,
                                ),
                                (
                                    "mpp-activation-closure-observation-access",
                                    activation_patterns.closure_observation_access,
                                ),
                                (
                                    "mpp-activation-closure-observation-write",
                                    activation_patterns.closure_observation_write,
                                ),
                                (
                                    "mpp-activation-object-write",
                                    activation_patterns.object_write,
                                ),
                                (
                                    "mpp-activation-link-access",
                                    activation_patterns.link_access,
                                ),
                                (
                                    "mpp-activation-link-write",
                                    activation_patterns.link_write,
                                ),
                                (
                                    "mpp-activation-allocation",
                                    activation_patterns.allocation,
                                ),
                                ("mpp-activation-free", activation_patterns.free),
                                (
                                    "mpp-selected-hw-access",
                                    activation_patterns.selected_access,
                                ),
                                (
                                    "mpp-selected-hw-write",
                                    activation_patterns.selected_write,
                                ),
                            )
                        )
                    if "closure" in statement:
                        matches.extend(
                            (
                                (
                                    "mpp-activation-closure-terminal-access",
                                    MPP_CLOSURE_TERMINAL_ACCESS_RE,
                                ),
                                (
                                    "mpp-activation-closure-terminal-write",
                                    MPP_CLOSURE_TERMINAL_WRITE_RE,
                                ),
                                (
                                    "mpp-activation-closure-scope-access",
                                    MPP_CLOSURE_SCOPE_ACCESS_RE,
                                ),
                                (
                                    "mpp-activation-closure-scope-write",
                                    MPP_CLOSURE_SCOPE_WRITE_RE,
                                ),
                            )
                        )
                    if "quarantine" in statement:
                        matches.extend(
                            (
                                (
                                    "mpp-activation-quarantine-link-access",
                                    MPP_QUARANTINE_LINK_ACCESS_RE,
                                ),
                                (
                                    "mpp-activation-quarantine-link-write",
                                    MPP_QUARANTINE_LINK_WRITE_RE,
                                ),
                                (
                                    "mpp-activation-quarantine-ref-access",
                                    MPP_QUARANTINE_REF_ACCESS_RE,
                                ),
                                (
                                    "mpp-activation-quarantine-ref-write",
                                    MPP_QUARANTINE_REF_WRITE_RE,
                                ),
                                (
                                    "mpp-activation-quarantine-generation-access",
                                    MPP_QUARANTINE_GENERATION_ACCESS_RE,
                                ),
                                (
                                    "mpp-activation-quarantine-generation-write",
                                    MPP_QUARANTINE_GENERATION_WRITE_RE,
                                ),
                                (
                                    "mpp-quarantine-lock-access",
                                    MPP_QUARANTINE_LOCK_ACCESS_RE,
                                ),
                                (
                                    "mpp-quarantine-list-access",
                                    MPP_QUARANTINE_LIST_ACCESS_RE,
                                ),
                                (
                                    "mpp-quarantine-list-write",
                                    MPP_QUARANTINE_LIST_WRITE_RE,
                                ),
                                (
                                    "mpp-quarantine-count-access",
                                    MPP_QUARANTINE_COUNT_ACCESS_RE,
                                ),
                                (
                                    "mpp-quarantine-count-write",
                                    MPP_QUARANTINE_COUNT_WRITE_RE,
                                ),
                            )
                        )
                    if "rk_mpp_activation_retry_token" in (
                        function.signature + function.text
                    ):
                        matches.extend(
                            (
                                (
                                    "mpp-retry-token-access",
                                    activation_patterns.retry_token_access,
                                ),
                                (
                                    "mpp-retry-token-write",
                                    activation_patterns.retry_token_write,
                                ),
                            )
                        )
                    if "rk_mpp_activation_claim_token" in (
                        function.signature + function.text
                    ):
                        matches.extend(
                            (
                                (
                                    "mpp-claim-token-access",
                                    activation_patterns.claim_token_access,
                                ),
                                (
                                    "mpp-claim-token-write",
                                    activation_patterns.claim_token_write,
                                ),
                            )
                        )
                else:
                    matches.extend(
                        (
                            (
                                "rga-active-slot-access",
                                RGA_ACTIVE_SLOT_ACCESS_RE,
                            ),
                            (
                                "rga-active-slot-write",
                                RGA_ACTIVE_SLOT_WRITE_RE,
                            ),
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
    violations: list[Signal] = []
    for signal in signals:
        if signal.category in {
            "mpp-dispatch-legacy",
            "mpp-slot-legacy",
            "mpp-slot-legacy-helper",
        }:
            violations.append(signal)
        elif signal.category == "mpp-active-transition-entry":
            match = MPP_ACTIVE_TRANSITION_ENTRY_RE.search(signal.text)
            if not match:
                violations.append(signal)
                continue
            callee = match.group("callee")
            if signal.function not in MPP_ACTIVE_TRANSITION_ENTRY_OWNERS[callee]:
                violations.append(signal)
                continue
            if callee == "rk_mpp_hw_claim_active_locked":
                expected = MPP_CLAIM_REASON_BY_OWNER[signal.function]
                reasons = re.findall(r"RK_MPP_TRANSITION_[A-Z_]+", signal.text)
                if expected == "reason":
                    if reasons or not re.search(r"\breason\b", signal.text):
                        violations.append(signal)
                elif reasons != [expected]:
                    violations.append(signal)
        elif (
            signal.category == "mpp-active-activation-access"
            and signal.function not in MPP_ACTIVE_ACTIVATION_ACCESS_OWNERS
        ):
            violations.append(signal)
        elif (
            signal.category == "mpp-current-activation-access"
            and signal.function not in MPP_CURRENT_ACTIVATION_ACCESS_OWNERS
        ):
            violations.append(signal)
        elif (
            signal.category == "mpp-current-activation-write"
            and signal.function not in MPP_CURRENT_ACTIVATION_WRITE_OWNERS
        ):
            violations.append(signal)
        elif (
            signal.category == "mpp-activation-storage-access"
            and signal.function not in MPP_ACTIVATION_STORAGE_ACCESS_OWNERS
        ):
            violations.append(signal)
        elif (
            signal.category == "mpp-activation-list-access"
            and signal.function not in MPP_ACTIVATION_LIST_ACCESS_OWNERS
        ):
            violations.append(signal)
        elif (
            signal.category == "mpp-activation-list-write"
            and signal.function not in MPP_ACTIVATION_LIST_WRITE_OWNERS
        ):
            violations.append(signal)
        elif (
            signal.category == "mpp-activation-link-access"
            and signal.function not in MPP_ACTIVATION_LINK_ACCESS_OWNERS
        ):
            violations.append(signal)
        elif (
            signal.category == "mpp-activation-link-write"
            and signal.function not in MPP_ACTIVATION_LINK_WRITE_OWNERS
        ):
            violations.append(signal)
        elif (
            signal.category == "mpp-activation-allocation"
            and signal.function not in MPP_ACTIVATION_ALLOCATION_OWNERS
        ):
            violations.append(signal)
        elif (
            signal.category == "mpp-activation-free"
            and signal.function not in MPP_ACTIVATION_FREE_OWNERS
        ):
            violations.append(signal)
        elif (
            signal.category == "mpp-active-activation-write"
            and signal.function not in MPP_ACTIVE_ACTIVATION_WRITE_OWNERS
        ):
            violations.append(signal)
        elif (
            signal.category
            in {"mpp-timeout-activation-access", "mpp-timeout-activation-write"}
            and signal.function not in MPP_TIMEOUT_ACTIVATION_OWNERS
        ):
            violations.append(signal)
        elif (
            signal.category
            in {"mpp-activation-sequence-access", "mpp-activation-sequence-write"}
            and signal.function not in MPP_ACTIVATION_SEQUENCE_OWNERS
        ):
            violations.append(signal)
        elif (
            signal.category
            in {"mpp-timeout-generation-access", "mpp-timeout-generation-write"}
            and signal.function not in MPP_TIMEOUT_GENERATION_OWNERS
        ):
            violations.append(signal)
        elif (
            signal.category == "mpp-dispatch-lease-access"
            and signal.function not in DISPATCH_OWNER_ACCESS_OWNERS
        ):
            violations.append(signal)
        elif (
            signal.category == "mpp-dispatch-lease-write"
            and signal.function not in DISPATCH_OWNER_WRITE_OWNERS
        ):
            violations.append(signal)
        elif (
            signal.category == "mpp-selected-hw-access"
            and signal.function not in MPP_SELECTED_HW_ACCESS_OWNERS
        ):
            violations.append(signal)
        elif (
            signal.category == "mpp-selected-hw-write"
            and signal.function not in MPP_SELECTED_HW_WRITE_OWNERS
        ):
            violations.append(signal)
        elif (
            signal.category == "mpp-rkvdec-ccu-access"
            and signal.function not in MPP_RKVDEC_CCU_ACCESS_OWNERS
        ):
            violations.append(signal)
        elif (
            signal.category == "mpp-rkvdec-ccu-write"
            and signal.function not in MPP_RKVDEC_CCU_WRITE_OWNERS
        ):
            violations.append(signal)
        elif signal.category == "mpp-activation-object-write":
            violations.append(signal)
        elif (
            signal.category == "mpp-activation-parent-write"
            and signal.function not in MPP_ACTIVATION_PARENT_WRITE_OWNERS
        ):
            violations.append(signal)
        elif (
            signal.category == "mpp-activation-generation-write"
            and signal.function not in MPP_ACTIVATION_GENERATION_WRITE_OWNERS
        ):
            violations.append(signal)
        elif (
            signal.category == "mpp-activation-deadline-write"
            and signal.function not in MPP_ACTIVATION_DEADLINE_WRITE_OWNERS
        ):
            violations.append(signal)
        elif (
            signal.category == "mpp-activation-slot-state-access"
            and signal.function not in MPP_ACTIVATION_SLOT_STATE_ACCESS_OWNERS
        ):
            violations.append(signal)
        elif (
            signal.category == "mpp-activation-slot-state-write"
            and signal.function not in MPP_ACTIVATION_SLOT_STATE_WRITE_OWNERS
        ):
            violations.append(signal)
        elif (
            signal.category == "mpp-activation-transition-reason-access"
            and signal.function not in MPP_ACTIVATION_REASON_ACCESS_OWNERS
        ):
            violations.append(signal)
        elif (
            signal.category == "mpp-activation-transition-reason-write"
            and signal.function not in MPP_ACTIVATION_REASON_WRITE_OWNERS
        ):
            violations.append(signal)
        elif (
            signal.category == "mpp-recovery-result-access"
            and signal.function not in MPP_RECOVERY_RESULT_ACCESS_OWNERS
        ):
            violations.append(signal)
        elif (
            signal.category == "mpp-recovery-result-write"
            and signal.function not in MPP_RECOVERY_RESULT_WRITE_OWNERS
        ):
            violations.append(signal)
        elif (
            signal.category
            in {
                "mpp-activation-closure-access",
                "mpp-activation-closure-state-access",
                "mpp-activation-closure-group-access",
                "mpp-activation-closure-core-access",
            }
            and signal.function not in MPP_ACTIVATION_CLOSURE_ACCESS_OWNERS
        ):
            violations.append(signal)
        elif (
            signal.category == "mpp-activation-closure-write"
            and signal.function not in MPP_ACTIVATION_CLOSURE_WRITE_OWNERS
        ):
            violations.append(signal)
        elif (
            signal.category == "mpp-activation-closure-state-write"
            and signal.function not in MPP_ACTIVATION_CLOSURE_STATE_WRITE_OWNERS
        ):
            violations.append(signal)
        elif (
            signal.category == "mpp-activation-closure-group-write"
            and signal.function not in MPP_ACTIVATION_CLOSURE_GROUP_WRITE_OWNERS
        ):
            violations.append(signal)
        elif (
            signal.category == "mpp-activation-closure-core-write"
            and signal.function not in MPP_ACTIVATION_CLOSURE_CORE_WRITE_OWNERS
        ):
            violations.append(signal)
        elif (
            signal.category == "mpp-activation-closure-terminal-access"
            and signal.function
            not in MPP_ACTIVATION_CLOSURE_TERMINAL_ACCESS_OWNERS
        ):
            violations.append(signal)
        elif (
            signal.category == "mpp-activation-closure-terminal-write"
            and signal.function
            not in MPP_ACTIVATION_CLOSURE_TERMINAL_WRITE_OWNERS
        ):
            violations.append(signal)
        elif (
            signal.category == "mpp-activation-closure-scope-access"
            and signal.function not in MPP_ACTIVATION_CLOSURE_SCOPE_ACCESS_OWNERS
        ):
            violations.append(signal)
        elif (
            signal.category == "mpp-activation-closure-scope-write"
            and signal.function not in MPP_ACTIVATION_CLOSURE_SCOPE_WRITE_OWNERS
        ):
            violations.append(signal)
        elif (
            signal.category == "mpp-activation-closure-observation-access"
            and signal.function
            not in MPP_ACTIVATION_CLOSURE_OBSERVATION_ACCESS_OWNERS
        ):
            violations.append(signal)
        elif (
            signal.category == "mpp-activation-closure-observation-write"
            and signal.function
            not in MPP_ACTIVATION_CLOSURE_OBSERVATION_WRITE_OWNERS
        ):
            violations.append(signal)
        elif (
            signal.category
            in {
                "mpp-activation-quarantine-link-access",
                "mpp-activation-quarantine-ref-access",
                "mpp-activation-quarantine-generation-access",
            }
            and signal.function not in MPP_ACTIVATION_QUARANTINE_ACCESS_OWNERS
        ):
            violations.append(signal)
        elif (
            signal.category
            in {
                "mpp-activation-quarantine-link-write",
                "mpp-activation-quarantine-ref-write",
                "mpp-activation-quarantine-generation-write",
            }
            and signal.function not in MPP_ACTIVATION_QUARANTINE_WRITE_OWNERS
        ):
            violations.append(signal)
        elif (
            signal.category == "mpp-retry-token-access"
            and signal.function not in MPP_RETRY_TOKEN_ACCESS_OWNERS
        ):
            violations.append(signal)
        elif (
            signal.category == "mpp-retry-token-write"
            and signal.function not in MPP_RETRY_TOKEN_WRITE_OWNERS
        ):
            violations.append(signal)
        elif (
            signal.category == "mpp-claim-token-access"
            and signal.function not in MPP_CLAIM_TOKEN_ACCESS_OWNERS
        ):
            violations.append(signal)
        elif (
            signal.category == "mpp-claim-token-write"
            and signal.function not in MPP_CLAIM_TOKEN_WRITE_OWNERS
        ):
            violations.append(signal)
        elif (
            signal.category == "mpp-quarantine-lock-access"
            and signal.function not in MPP_QUARANTINE_LOCK_ACCESS_OWNERS
        ):
            violations.append(signal)
        elif (
            signal.category == "mpp-quarantine-list-access"
            and signal.function not in MPP_QUARANTINE_LIST_ACCESS_OWNERS
        ):
            violations.append(signal)
        elif (
            signal.category == "mpp-quarantine-list-write"
            and signal.function not in MPP_QUARANTINE_LIST_WRITE_OWNERS
        ):
            violations.append(signal)
        elif (
            signal.category == "mpp-quarantine-count-access"
            and signal.function not in MPP_QUARANTINE_COUNT_ACCESS_OWNERS
        ):
            violations.append(signal)
        elif (
            signal.category == "mpp-quarantine-count-write"
            and signal.function not in MPP_QUARANTINE_COUNT_WRITE_OWNERS
        ):
            violations.append(signal)
    return violations


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.emit_baseline and args.update_baseline:
        print("choose only one baseline-output mode", file=sys.stderr)
        return 2
    try:
        resolved = [tree.resolve() for tree in args.kernel_tree]
        trees: list[tuple[pathlib.Path, list[Signal]]] = []
        for tree in resolved:
            if trees and all(
                (tree / source).read_bytes() == (trees[0][0] / source).read_bytes()
                for source in SOURCES
            ):
                signals = trees[0][1]
            else:
                signals = audit_tree(tree)
            trees.append((tree, signals))
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
            raise ValueError("ownership state used outside its allowed owners")
        reference = {signal.key for signal in trees[0][1]}
        mismatched = [
            tree
            for tree, signals in trees[1:]
            if {signal.key for signal in signals} != reference
        ]
        if mismatched:
            for tree in mismatched:
                print(
                    f"{tree}: ownership signals differ from {trees[0][0]}",
                    file=sys.stderr,
                )
            print("rewrite ownership source audit failed", file=sys.stderr)
            return 1
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
    if failed:
        print("rewrite ownership source audit failed", file=sys.stderr)
        return 1
    print("rewrite ownership source audit passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
