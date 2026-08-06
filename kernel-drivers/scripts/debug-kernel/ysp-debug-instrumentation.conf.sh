# shellcheck shell=bash disable=SC2034
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: GPL-2.0-only
# Shared heavy-debug instrumentation for the ROCK 5B *-debug kernel flavors
# ("Kernel A" of kernel-drivers/docs/rewrite-validation-plan.md §1).
#
# Sourced by every config-rock5b-*-debug-kernel.conf.sh so the forward-port and
# rewrite debug kernels carry byte-identical instrumentation (one C#### config
# class). build-kernel.sh stages this file into userpatches/ alongside the
# flavor config; it is not an Armbian config by itself.

function custom_kernel_config__rock5b_hard_reboot_debug() {
	# Persistent crash capture. Make ramoops built-in so pstore is available
	# before userspace loads modules. Keep the ftrace frontend built in to match
	# the established debug config, although this DT has no ftrace RAM zone.
	opts_y+=(
		"PSTORE"
		"PSTORE_RAM"
		"PSTORE_CONSOLE"
		"PSTORE_PMSG"
		"PSTORE_FTRACE"
	)
	opts_val["PSTORE_DEFAULT_KMSG_BYTES"]="262144"

	# Turn latent faults and stalls into logged reports. NOTE: PANIC_ON_OOPS is
	# deliberately NOT enabled here (see opts_n below) — on RK3588 the firmware
	# re-inits DRAM on reset, so ramoops does not survive a panic reboot
	# (measured; see findings/2026-07-21-ramoops-not-preserved-across-warm-reset-rk3588.md).
	# With panic_on_oops=0 a process-context oops instead prints its full trace
	# and the board stays up long enough for journald to capture it live — how
	# the 0058 RELEASE_FD crash was finally root-caused.
	opts_y+=(
		"SOFTLOCKUP_DETECTOR"
		"HARDLOCKUP_DETECTOR"
		"DETECT_HUNG_TASK"
		"WQ_WATCHDOG"
	)
	opts_val["DEFAULT_HUNG_TASK_TIMEOUT"]="60"
	opts_val["RCU_CPU_STALL_TIMEOUT"]="21"

	# Stalls DO panic, unlike the oops policy above, and the difference is
	# deliberate. "Let the board stay up and capture it live" only works if
	# userspace exists: kunit_run_all_tests() runs in kernel_init_freeable()
	# *before* wait_for_initramfs(), and CONFIG_DRM_ROCKCHIP=m, so a stall in a
	# boot-time KUnit case has no journald and no HDMI to report through, and a
	# hang raises no kmsg_dump either. That is a board that is simply dead with
	# zero trace -- measured 2026-08-05 on the rewrite RGA fd-zero wedge, and
	# again on the 2026-07-29 conformance run. Panicking at least puts the stuck
	# task and its stack on ttyS2 and lets panic=10 reboot into something
	# debuggable. Override per boot with sysctl.kernel.hung_task_panic=0 /
	# sysctl.kernel.softlockup_panic=0 on the kernel command line if a long
	# KASAN-slowed D-state wait turns out to trip the 60 s threshold.
	# HARDLOCKUP is left reporting-only: it fires with interrupts disabled,
	# where a KASAN debug kernel is most likely to be merely slow.
	opts_y+=(
		"BOOTPARAM_HUNG_TASK_PANIC"
		"BOOTPARAM_SOFTLOCKUP_PANIC"
	)

	# Exercise allocation and usercopy recovery paths deterministically from the
	# bounded ioctl-fuzz harness. Keep these built in with the other detectors.
	opts_y+=(
		"FAULT_INJECTION"
		"FAULT_INJECTION_DEBUG_FS"
		"FAILSLAB"
		"FAIL_PAGE_ALLOC"
		"FAULT_INJECTION_USERCOPY"
		"FUNCTION_ERROR_INJECTION"
	)

	# Better stack traces and symbols in crash output.
	opts_y+=(
		"KALLSYMS"
		"KALLSYMS_ALL"
		"STACKTRACE"
		"FRAME_POINTER"
		"GDB_SCRIPTS"
	)

	# Graphics/DRM debugging that is directly relevant to Panthor/Rockchip GPU
	# crashes triggered by accelerated Firefox/RDP rendering.
	opts_y+=(
		"DRM_DEBUG_MM"
		"DRM_DEBUG_MODESET_LOCK"
		"DRM_PANIC"
	)

	# Heavy runtime bug detectors. This kernel is for reproducing the crash,
	# not for normal daily use.
	opts_y+=(
		"KASAN"
		"KASAN_GENERIC"
		"KASAN_INLINE"
		"KASAN_VMALLOC"
		"PAGE_OWNER"
		"PAGE_POISONING"
		"DEBUG_PAGEALLOC"
		"PAGE_TABLE_CHECK"
		"DMA_API_DEBUG"
		"DMA_API_DEBUG_SG"
		"DEBUG_SG"
		"DEBUG_LIST"
		"DEBUG_PLIST"
		"DEBUG_NOTIFIERS"
	)

	# UBSAN — complements KASAN for the stride/offset arithmetic class that is
	# in-bounds of the allocation (so KASAN is silent) but wrong: array-index
	# OOB, out-of-range shifts (the RGA/MPP stride math is full of >> 2 /
	# << PAGE_SHIFT), and divide-by-zero. Kept in REPORT mode (UBSAN_TRAP off,
	# below) so a violation logs a full trace instead of panicking. Signed/
	# integer-wrap and alignment sub-checks are left off: the kernel wraps
	# intentionally in many places and those add noise without catching this
	# driver's bug class.
	opts_y+=(
		"UBSAN"
		"UBSAN_BOUNDS"
		"UBSAN_SHIFT"
		"UBSAN_DIV_ZERO"
	)

	# DEBUG_OBJECTS — validates object lifecycle (init/activate/free) for the
	# exact structures this driver's memory-safety fixes were about: the async
	# MPP worker task and workqueue items, timers, and RCU callbacks. Catches
	# free-while-active and double-init that KASAN only sees once the freed
	# memory is reused.
	opts_y+=(
		"DEBUG_OBJECTS"
		"DEBUG_OBJECTS_FREE"
		"DEBUG_OBJECTS_TIMERS"
		"DEBUG_OBJECTS_WORK"
		"DEBUG_OBJECTS_RCU_HEAD"
	)

	# DEBUG_SHIRQ spuriously invokes the IRQ handler at request_irq/free_irq to
	# catch handlers that touch torn-down state — the RGA/MPP IRQ-completion-
	# vs-session-close UAF class. DEBUG_KMEMLEAK catches leaked requests/buffers/
	# imports that KASAN (UAF/OOB only) never reports; scan on demand after a
	# conformance run via /sys/kernel/debug/kmemleak. IOMMU_DEBUGFS exposes the
	# rockchip-iommu domains/page tables for inspecting exactly what an RGA
	# IOMMU fault mapped. SCHED_STACK_END_CHECK is a near-free stack-overrun
	# canary; DEBUG_VM(_PGFLAGS) checks mm invariants on the userptr/
	# scatterlist/shadow_page path.
	opts_y+=(
		"DEBUG_SHIRQ"
		"DEBUG_KMEMLEAK"
		"IOMMU_DEBUGFS"
		"SCHED_STACK_END_CHECK"
		"DEBUG_VM"
		"DEBUG_VM_PGFLAGS"
	)

	# Locking/sleeping diagnostics. Useful if the GPU path is corrupting state
	# or wedging in a scheduler/lock path before the hard reset.
	opts_y+=(
		"PROVE_LOCKING"
		"LOCK_STAT"
		"DEBUG_ATOMIC_SLEEP"
		"DEBUG_PREEMPT"
		"DEBUG_RT_MUTEXES"
		"DEBUG_SPINLOCK"
		"DEBUG_MUTEXES"
		"DEBUG_WW_MUTEX_SLOWPATH"
		"DEBUG_RWSEMS"
		"DEBUG_IRQFLAGS"
	)

	# arm64 selects ARCH_SUPPORTS_RT, which forces PROVE_RAW_LOCK_NESTING
	# on (and hides its prompt) whenever PROVE_LOCKING is set; the paired
	# zz-rock5b-debug-locknest-prompt.patch restores the prompt so this
	# disable can take effect. The checker models PREEMPT_RT wait-type
	# nesting, which the rewrite drivers deliberately do not satisfy yet
	# (hardirq slice reads and poll wakeups in rkvenc2, the shared-line
	# RGA hard handler), and its first report disables lockdep for the
	# rest of the boot — costing the deadlock coverage this build exists
	# for. Earlier 6.18.40 boots never showed it only because the soft-CCU
	# submit recursion report always killed lockdep first. Keep it off
	# until the RT-nesting cleanup is its own qualified change
	# (2026-07-30 finding).
	opts_n+=(
		"PROVE_RAW_LOCK_NESTING"
	)

	# KASAN is the main memory sanitizer for this build; do not also enable
	# lighter-weight or race-oriented sanitizers that can conflict or add noise.
	opts_n+=(
		"KFENCE"
		"KCSAN"
		# UBSAN must REPORT, not trap: a trap turns every violation into a
		# BUG()/panic (and on RK3588 the ramoops region is lost on reset), so
		# keep it off to get a logged trace with the board still up.
		"UBSAN_TRAP"
		"DEBUG_INFO_NONE"
		"DEBUG_INFO_REDUCED"
		# Boot with panic_on_oops=0 (default when unset): capture the live oops
		# trace via journald instead of panicking into a ramoops region that
		# RK3588's DRAM re-init discards on reset. Debug builds only — the
		# distributable kernel keeps the fail-fast default.
		"PANIC_ON_OOPS"
	)
}
