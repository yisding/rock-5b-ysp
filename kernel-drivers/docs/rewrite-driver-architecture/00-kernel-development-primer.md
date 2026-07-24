# Chapter 0: kernel development primer

[Guide home](README.md) ·
[Next: ownership and Linux driver foundations →](01-foundations.md)

This chapter is for developers who are comfortable reading C but have not
worked inside the Linux kernel. It introduces the assumptions the later
chapters make without trying to teach the entire kernel.

You do not need to understand video codecs, RK3588 register layouts, or every
kernel subsystem before continuing. You do need a working model of:

- where driver code runs;
- how userspace reaches it;
- why execution context controls which APIs are legal;
- why memory has several kinds of address;
- how work continues after a syscall returns;
- how ownership and cleanup replace process isolation and automatic resource
  management;
- how to distinguish “compiled” from “worked on hardware.”

## 0.1 Kernel code is not a privileged userspace program

A userspace process has its own virtual address space. If it dereferences an
invalid pointer, the usual result is that one process crashes. The kernel is
shared infrastructure for the whole machine. A driver bug can:

- corrupt another process or kernel object;
- deadlock unrelated work;
- wedge a hardware engine that continues performing DMA;
- lose storage or networking;
- panic or hard-lock the system;
- appear much later than the operation that caused it.

That changes the standard for accepting input and managing lifetimes. “The
normal library never does that” is not a safety argument at a syscall boundary.
The driver must remain safe when a process is buggy, malicious, killed, or
racing itself.

Kernel code also does not use the normal userspace runtime:

| Userspace habit | Kernel equivalent or constraint |
|-----------------|---------------------------------|
| C library allocation | `kmalloc`, `kzalloc`, page allocators, or subsystem-specific allocators |
| `printf` | `pr_*`, `dev_*`, tracepoints, debugfs, or structured test output |
| Directly dereference caller memory | `copy_from_user`, `copy_to_user`, or carefully scoped user-page pinning |
| Block whenever convenient | Only sleep in a sleep-capable execution context |
| Large stack objects or recursion | Keep kernel-stack use small and bounded; allocate large state explicitly |
| Floating-point arithmetic | Avoid floating point in ordinary kernel code; use integer/fixed-point hardware representations |
| Process exit cleans up everything | Every accepted asynchronous owner needs an explicit release path |
| Crash affects one process | A bad access may crash or corrupt the kernel |

The kernel does provide rich frameworks—device management, clocks, resets,
DMA, IOMMUs, power management, interrupts, reference counts, workqueues, and
tests—but a driver must use each framework according to its lifetime and
context rules.

Linux also does not promise a stable internal API between kernel versions.
Userspace ABI compatibility is a long-term contract; internal driver APIs can
change. That is why this project maintains separate 6.18 and current-mainline
rewrite branches even though their MPP/RGA source is presently identical.

## 0.2 There is no single “driver thread”

A driver is a collection of entry points called by different parts of the
kernel. The MPP and RGA rewrites can execute through:

```text
module/built-in initialization
  -> platform probe for each hardware node
  -> open / ioctl / close from a process
  -> scheduler or recovery workqueue
  -> hard interrupt
  -> threaded interrupt
  -> IOMMU fault callback
  -> timeout callback
  -> platform remove or system shutdown
```

These paths may overlap on different CPUs. The process that submitted a job
does not become the thread that later handles its interrupt. The process may
have returned from `ioctl()`, closed the file, or exited before hardware
finishes.

This is the first major mental shift from ordinary application code:

> A call stack gives temporary control flow. Published objects and callbacks
> create long-lived control flow.

When reading a callback, ask who scheduled or registered it, what data it will
dereference, what keeps that data alive, and what synchronizes cancellation
with a callback already running.

## 0.3 Execution context determines what code may do

The most important distinction is whether the current context may sleep.
Sleeping means yielding the CPU while waiting for a lock, memory, hardware, or
another event.

| Context | May sleep? | Common driver responsibilities |
|---------|------------|--------------------------------|
| Process/syscall context | Yes | Copy and validate ioctls, allocate, map, submit, wait, close |
| Workqueue | Yes | Scheduling, timeout recovery, deferred cleanup |
| Threaded IRQ | Yes | Slow completion, reset, runtime PM, DMA teardown |
| Hard IRQ | No | Read/acknowledge status and publish small state changes |
| Spinlock/atomic region | No | Protect short state transitions shared with IRQ context |
| IOMMU fault callback | Treat as constrained | Identify the source and defer recovery |

Consequences:

- A mutex may sleep, so hard IRQ code cannot acquire one.
- `GFP_KERNEL` allocation may sleep; atomic context needs a different plan,
  usually preallocation or deferral rather than routine emergency allocation.
- Runtime power management, many DMA operations, and synchronous work
  cancellation can sleep.
- A spinlock must cover only short, non-sleeping state changes.
- Slow interrupt work belongs in a threaded IRQ or workqueue.

Kernel builds with `CONFIG_DEBUG_ATOMIC_SLEEP`, lockdep, and related debugging
can catch some violations. They cannot infer the intended ownership model for
you.

## 0.4 Locks, references, and completion signals solve different problems

These mechanisms are related but not interchangeable:

| Mechanism | Question answered |
|-----------|-------------------|
| Mutex or spinlock | Who may inspect or change this state right now? |
| Reference count | May this object be freed yet? |
| Generation number | Does this delayed event belong to the current use of this slot? |
| Work cancellation/drain | Can this callback still start or already be running? |
| Waitqueue/completion/fence | When may another participant continue? |

Holding a lock does not automatically give long-term ownership after the lock
is released. Holding a reference does not make concurrent field mutation safe.
Canceling pending work does not necessarily wait for a callback already
executing. Waking a waiter does not prove DMA copyback was completed first.

Later chapters repeatedly combine these tools because asynchronous drivers
usually need all of their guarantees.

## 0.5 Learn the address spaces before reading DMA code

“Address” does not identify one universal number:

| Address or object | Meaning |
|-------------------|---------|
| Userspace virtual address | Valid in one process's CPU page tables |
| Kernel virtual address | CPU address usable by kernel code under its mapping rules |
| Physical address | Location in system memory |
| DMA address / IOVA | Address a particular device emits for a mapped buffer |
| DMA-BUF fd | Userspace handle for a refcounted shared-buffer object, not an address |

An IOMMU translates a device-visible IOVA to physical pages. It is similar in
purpose to the CPU's MMU, but it serves devices doing DMA.

Two rules prevent many driver bugs:

1. A userspace pointer must not be treated as a kernel pointer.
2. An IOVA is meaningful only for the device and DMA/IOMMU context that
   produced it.

The same DMA-BUF can map at different IOVAs for two cores. Scattered physical
pages can appear as one contiguous IOVA range. Conversely, a numerically
plausible address supplied by userspace proves neither ownership nor that the
device can safely access it.

### CPU access and device access are separate

DMA also introduces memory-visibility rules. The CPU, caches, an exporter, and
the device may not observe writes at the same instant. The DMA API defines when
ownership or visibility transfers. A safe completion order is conceptually:

```text
prove hardware stopped using memory
  -> synchronize/unmap for CPU access
  -> finish any bounce-buffer copyback
  -> publish the result
  -> signal a fence or wake a waiter
```

Signaling first is a correctness bug even if the pixels happen to look right
on a cache-coherent test run.

## 0.6 How userspace reaches a driver

For this guide, the important boundary is a character device:

```text
fd = open("/dev/rga", ...)
ioctl(fd, command, pointer_to_request)
close(fd)
```

The corresponding kernel file operations create and use a per-open session.
An ioctl command and its data layout form a **uAPI** or **ABI** contract. That
contract includes more than C field names:

- numeric command values;
- structure sizes, alignment, and field offsets;
- 32-bit compatibility behavior;
- flag and count meanings;
- when data is copied in or out;
- synchronous versus asynchronous completion;
- returned errno values;
- lifetime rules for handles and fence fds.

The expected library normally builds these requests, but any process with
device access can invoke the syscall directly. The kernel therefore copies,
bounds, resolves, retains, and validates a complete request before publishing
it to asynchronous code.

## 0.7 How the driver reaches hardware

`Kconfig` decides whether a driver feature is selectable and which other
features it depends on. `Makefile` entries decide which objects are compiled
when that configuration symbol is enabled. A driver may be built into the
kernel image or built as a loadable module; either form still uses the same
probe, runtime, and teardown rules.

Embedded platform devices are usually described by **device tree**. A node
identifies resources and relationships such as:

- MMIO register windows;
- interrupt lines;
- clocks and reset controls;
- power domains;
- IOMMU connections;
- core aliases and coordinator relationships.

A platform driver's `probe()` callback matches a compatible node, validates
its resources, and creates the kernel object representing that hardware
instance.

Typical hardware use then looks like:

```text
acquire runtime-PM reference
  -> enable/apply clocks and release reset
  -> map buffers for this device
  -> write configuration with writel()
  -> issue required ordering barrier
  -> write start/doorbell register last
  -> hardware performs DMA
  -> interrupt reports progress/completion
  -> stop/reset if required
  -> unmap/synchronize buffers
  -> power down and release runtime-PM reference
```

MMIO accessors such as `readl()` and `writel()` are not ordinary pointer
dereferences. They express device-register access and its ordering rules.
Memory barriers are part of the hardware protocol: software must make the
descriptor or register state visible before ringing a doorbell.

## 0.8 Kernel C patterns that may look unfamiliar

The source uses common kernel conventions:

| Pattern | Meaning |
|---------|---------|
| `u32`, `u64`, `size_t` | Types chosen for ABI, hardware width, or memory-size semantics |
| `__user` | Annotation marking a userspace pointer that needs user-access helpers |
| `__iomem` | Annotation marking an MMIO pointer that needs I/O accessors |
| `ERR_PTR`, `IS_ERR`, `PTR_ERR` | Encode a negative errno in a pointer-shaped return value |
| `container_of` | Recover the containing structure from one embedded member |
| `list_head` | Intrusive linked list embedded in the owned object |
| `refcount_t`, `kref` | Checked lifetime reference counting |
| `READ_ONCE`, `WRITE_ONCE` | Prevent unsafe compiler merging/reloading of shared scalar accesses; not a lock by themselves |
| `goto` cleanup labels | Structured reverse-order unwind after partial acquisition |
| `devm_*` | Device-managed resource released after device removal |

### Why `goto` is normal in kernel error paths

A probe or submit function may acquire resources in stages:

```text
allocate object
  -> get buffer
  -> attach buffer
  -> map attachment
  -> allocate command memory
```

If the last step fails, cleanup must run in exact reverse order. Shared
`goto` labels keep one cleanup implementation per ownership stage:

```c
ret = map_buffer(obj);
if (ret)
        goto err_put_buffer;

ret = alloc_command(obj);
if (ret)
        goto err_unmap_buffer;
```

This is not exception handling. Each label documents which resources are live
at that point. Reviewers should verify that every success has one matching
release and that no path releases a resource it never acquired.

## 0.9 Errors are part of the interface

Kernel functions commonly return zero for success and a negative errno for
failure. Preserve useful distinctions:

| Error | Typical meaning in these drivers |
|-------|----------------------------------|
| `-EINVAL` | Malformed or inconsistent request |
| `-EFAULT` | Userspace copy/access failed |
| `-ENOMEM` | Allocation failed |
| `-ENODEV` | Required hardware is absent or no longer available |
| `-EOPNOTSUPP` | Request is valid in concept but this safe implementation does not support it |
| `-EAGAIN` | Nonblocking operation has no result yet |
| `-ETIMEDOUT` | Hardware did not complete within its deadline |
| `-EIO` | Hardware or recovery failed |

Do not silently accept a request whose hardware meaning is unknown. A clean
`-EOPNOTSUPP` is safer and easier to diagnose than programming a guessed
register combination.

## 0.10 The driver lifecycle is larger than probe and normal completion

New driver code often handles the happy path first:

```text
probe -> submit -> interrupt -> complete
```

Production design must also cover:

- probe failing after partial initialization;
- userspace closing during queued or active work;
- a process exiting while an acquire-fence callback is armed;
- timeout racing the real interrupt;
- an IOMMU fault arriving on a shared domain;
- reset failing to prove that DMA stopped;
- a core being removed while jobs still reference it;
- module unload or shutdown with work pending.

The dangerous moment is usually not the initial failure. It is cleanup running
concurrently with a late callback that still believes the old object or DMA
mapping exists.

This is why the next chapter describes a driver as an **ownership machine**
rather than a register-programming function.

## 0.11 How to read a large driver without reading every line

Do not start at line 1 and attempt to retain every helper. Follow one lifecycle:

1. Find the principal service, session, job, import/mapping, and hardware
   structures.
2. Find module initialization and platform `probe()`.
3. Find `open()`, the main `ioctl()` dispatcher, and `release()`.
4. Follow one simple request from copy-in to validation and queue publication.
5. Follow dispatch through power-on, mapping, register writes, and start.
6. Follow hard IRQ to threaded completion and userspace notification.
7. Read timeout, fault, close, and remove paths for the same objects.
8. Only then study special formats, codec modes, and recovery optimizations.

Use symbol search rather than scrolling:

```bash
rg -n 'struct rk_mpp_(service|session|job|hw|import)' \
  drivers/video/rockchip/mpp-rewrite/mpp_rewrite.c

rg -n 'rk_rga_(open|ioctl|job_submit|hw_dispatch|release)' \
  drivers/video/rockchip/rga-rewrite/rga_rewrite.c
```

At each function, write down:

- caller and execution context;
- locks required on entry;
- references acquired or transferred;
- state published to another context;
- possible asynchronous callbacks;
- cleanup owner on every exit.

## 0.12 How to make a first change safely

A practical learning sequence is:

1. **Classify the change.** Is it ABI parsing, pure validation, scheduling,
   command emission, lifetime, or recovery?
2. **Identify context and ownership.** List callers, locks, object references,
   and callbacks before editing.
3. **Add the smallest hardware-independent test.** Parser, arithmetic, routing,
   and state-transition changes often fit KUnit.
4. **Build the relevant configurations.** A normal build alone may hide
   sanitizer, lock, stack, or conditional-compilation problems.
5. **Boot an instrumented image.** Confirm the exact kernel fingerprint and
   that the rewrite owns the expected device nodes.
6. **Run a narrow hardware gate.** Prove the intended counter changed and scan
   new kernel logs.
7. **Run regression and differential gates.** Compare behavior and output with
   the validated forward port.
8. **Exercise cleanup.** Close, timeout, reset, fault, and removal paths deserve
   tests proportional to the change.

For this repository, use the [debug-kernel guide](../debug-kernel.md), the
[kernel validation runbook](../kernel-validation-runbook.md), and the
[rewrite validation plan](../rewrite-validation-plan.md). A successful compile
is evidence about source compatibility. A successful boot is evidence about
initialization. Correct output with clean counters and logs is hardware
evidence. These are separate claims.

## 0.13 What you can postpone

You can read the next chapters without first mastering:

- H.264/H.265 bitstream syntax;
- every RGA pixel format;
- the complete RK3588 technical reference manual;
- all Linux memory allocators;
- every locking primitive;
- kernel upstream submission procedure.

The guide explains the MPP and RGA details when they become relevant. For now,
keep four questions in mind:

1. What data crossed from userspace, and when was it validated?
2. Which object owns each resource after the current function returns?
3. Which contexts can race to inspect, complete, cancel, or free it?
4. Has hardware definitely stopped using memory before software releases or
   exposes it?

Those questions are enough to begin
[Chapter 1: ownership and Linux driver foundations](01-foundations.md).

---

[← Guide overview](README.md) ·
[Next: ownership and Linux driver foundations →](01-foundations.md)
