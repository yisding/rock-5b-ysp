# shellcheck shell=bash disable=SC2034
# Debug rebuild for the ROCK 5B current Armbian kernel.
#
# This config intentionally starts from userpatches/linux-rockchip64-current.config,
# which is copied from /boot/config-$(uname -r) by the wrapper script.

BOARD="rock-5b"
BRANCH="current"
RELEASE="resolute"
BUILD_DESKTOP="no"
BUILD_MINIMAL="no"
INSTALL_HEADERS="yes"
SHARE_LOGS="no"

# Pin to the exact upstream stable tag/commit recorded by the installed
# linux-image-current-rockchip64 26.5.1 package.
KERNELBRANCH="tag:v6.18.35"

# Keep full DWARF/BTF debug data. Armbian may otherwise disable this when RAM
# looks tight, but this box has enough memory and debug symbols are useful.
KERNEL_BTF="yes"

function custom_kernel_config__rock5b_hard_reboot_debug() {
	# Persistent crash capture. Make ramoops built-in so pstore is available
	# before userspace loads modules, and include console/pmsg/ftrace records.
	opts_y+=(
		"PSTORE"
		"PSTORE_RAM"
		"PSTORE_CONSOLE"
		"PSTORE_PMSG"
		"PSTORE_FTRACE"
	)
	opts_val["PSTORE_DEFAULT_KMSG_BYTES"]="262144"

	# Turn latent faults and stalls into logged reports or panics that ramoops
	# has a chance to preserve across the reboot.
	opts_y+=(
		"PANIC_ON_OOPS"
		"SOFTLOCKUP_DETECTOR"
		"HARDLOCKUP_DETECTOR"
		"DETECT_HUNG_TASK"
		"WQ_WATCHDOG"
	)
	opts_val["DEFAULT_HUNG_TASK_TIMEOUT"]="60"
	opts_val["RCU_CPU_STALL_TIMEOUT"]="21"

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
	)
}
