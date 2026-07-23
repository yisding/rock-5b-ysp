# shellcheck shell=bash disable=SC2034
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

	# KASAN is the main memory sanitizer for this build; do not also enable
	# lighter-weight or race-oriented sanitizers that can conflict or add noise.
	opts_n+=(
		"KFENCE"
		"KCSAN"
		"DEBUG_INFO_NONE"
		"DEBUG_INFO_REDUCED"
		# Boot with panic_on_oops=0 (default when unset): capture the live oops
		# trace via journald instead of panicking into a ramoops region that
		# RK3588's DRAM re-init discards on reset. Debug builds only — the
		# distributable kernel keeps the fail-fast default.
		"PANIC_ON_OOPS"
	)
}
