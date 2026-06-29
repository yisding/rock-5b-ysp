# BSP audit — findings & draft cleanup patches

A multi-agent ("ultracode") audit of the forward-ported Rockchip MPP + RGA driver code, and a **draft** cleanup patch series derived from it. This is *separate* from the conservative forward-port — none of it is applied to the shipped kernel.

## How it was produced

- **15** shipped driver files (`mpp/` + `rga3/`) reviewed through **3 lenses** (correctness, resource-safety, concurrency/security/cleanup) — 45 reviewers.
- Every finding **adversarially verified** by an independent agent that re-read the actual code and defaulted to *reject* unless it could trace the concrete bug (false-positive filter).
- Per-file agents then designed **minimal, behaviour-preserving** fix edits.
- **180 agents, ~3.7M tokens, 37 min.** 89 findings survived verification.

## ⚠️ Status — read before using the patches

These patches are **machine-generated, adversarially-LLM-verified, and compile-tested on arm64 — but NOT human-merge-reviewed.** They are a *starting point*, not merge-ready.

> **Concrete proof review is required:** while assembling the series, one ambiguous text-match doubled a `kref_put` in `mpp_dma_release()` (a function that takes a buffer directly), introducing a **use-after-free** — the fix was meant for `mpp_dma_release_fd()`. It compiled fine. It was caught by hand and reverted. **Treat every refcount/bounds/security edit as needing review.** One arm32-only edit (`CONFIG_ARM_DMA_USE_IOMMU`) was left unapplied (untestable on arm64).

## Summary

| Severity | Count | | File | Findings |
|----------|-------|-|------|----------|
| high | 16 | | mpp/mpp_rkvdec2_link.c | 11 |
| medium | 30 | | mpp/mpp_common.c | 10 |
| low | 30 | | mpp/mpp_service.c | 10 |
| cleanup | 13 | | mpp/mpp_rkvenc2.c | 9 |
|  |  | | rga3/rga_mm.c | 8 |
|  |  | | mpp/mpp_rkvdec2.c | 7 |
|  |  | | rga3/rga_drv.c | 7 |
|  |  | | rga3/rga_debugger.c | 6 |
|  |  | | rga3/rga_job.c | 4 |
|  |  | | rga3/rga_policy.c | 4 |
|  |  | | mpp/mpp_iommu.c | 3 |
|  |  | | rga3/rga_iommu.c | 3 |
|  |  | | rga3/rga_common.c | 3 |
|  |  | | rga3/rga_dma_buf.c | 2 |
|  |  | | rga3/rga_fence.c | 2 |

**Total: 89 verified findings** (16 high, 30 medium, 30 low, 13 cleanup) across 15 files.

These are **latent in the upstream Rockchip BSP** too — the forward-port kept the code ~98% as-is.

---
## Findings by file

### `mpp/mpp_common.c` — 10 findings

| line | sev | category | finding |
|------|-----|----------|---------|
| 250 | high | null-deref | Unchecked kzalloc result dereferenced in task_msgs_init |
| 1582 | high | security | MPP_CMD_SET_SESSION_FD trusts arbitrary fd as mpp_session (type confusion) via a tautological c |
| 303 | medium | fd/file refcount leak | clear_task_msgs() frees msgs without fdput'ing a held ext_fd reference |
| 1592 | medium | fd/file refcount leak | MPP_CMD_SET_SESSION_FD as the last message leaks the fdget() reference |
| 1943 | medium | logic-bug | Wrong arithmetic when clamping over-sized request size |
| 1960 | medium | security | copy_from_user length (req->size) not consistent with the element-count bounds check (struct ov |
| 250 | low | null-deref / unchecked allocation | kzalloc result used without NULL check |
| 250 | low | concurrency-security-cleanup | kzalloc result used without NULL check; caller's later NULL check is dead |
| 1592 | low | resource-leak | fdget reference leaked when SET_SESSION_FD is the last message |
| 1943 | low | concurrency-security-cleanup | Size clamp computes the overflow amount instead of the remaining space |

<details><summary><b>HIGH</b> · L250 · Unchecked kzalloc result dereferenced in task_msgs_init</summary>

**Problem.** When the idle-list lookup misses, the code does `msgs = kzalloc(sizeof(*msgs), GFP_KERNEL);` immediately followed by `task_msgs_init(msgs, session);` (lines 250-251). task_msgs_init() unconditionally dereferences msgs (`INIT_LIST_HEAD(&msgs->list); msgs->session = session; ...`). If kzalloc fails under memory pressure, this is a NULL pointer dereference / oops. Note the caller at mpp_collect_msgs() lines 1598-1605 explicitly checks `if (!msgs)` and returns -EINVAL, i.e. the contract expects get_task_msgs() to be able to return NULL safely, but it crashes before it can.


**Fix.** Insert a NULL guard immediately after the allocation in get_task_msgs():  	msgs = kzalloc(sizeof(*msgs), GFP_KERNEL); 	if (!msgs) 		return NULL; 	task_msgs_init(msgs, session); 	INIT_LIST_HEAD(&msgs->list_session);  The existing `if (!msgs)` check in mpp_collect_msgs() (lines 1598-1605) already handles the NULL return cleanly with -EINVAL.


*verify confidence: high*

</details>

<details><summary><b>HIGH</b> · L1582 · MPP_CMD_SET_SESSION_FD trusts arbitrary fd as mpp_session (type confusion) via a tautologi</summary>

**Problem.** In the session-switch path: f = fdget(bat_msg.fd); the only validation is `if (!fd_file(f))`. Then `session = fd_file(f)->private_data;` (line 1579) and `if (fd_file(f)->private_data == session) msgs->ext_fd = bat_msg.fd;` (line 1582). The condition compares the value just assigned to itself, so it is ALWAYS true and validates nothing. Crucially there is no check that the fd actually refers to an mpp device file (e.g. `fd_file(f)->f_op == &rockchip_mpp_fops`). An unprivileged caller can pass any fd (socket, pipe, regular file); its `private_data` is then reinterpreted as a `struct mpp_session *` and immediately dereferenced by get_task_msgs() (session->lock_msgs, session->list_msgs_idle, ses


**Fix.** Replace lines 1578-1585 (the "switch session" block) with a real device-type check before any session dereference, and drop the tautological guard:  		/* validate the fd actually refers to an mpp device file */ 		if (fd_file(f)->f_op != &rockchip_mpp_fops) { 			int ret = -EBADF;  			mpp_err("fd %d is not an mpp session\n", bat_msg.fd); 			fdput(f); 			if (copy_to_user(&usr_cmd->ret, &ret, sizeof(usr_cmd->ret))) 				mpp_err("copy_to_user failed.\n"); 			goto session_switch_done; 		}  		/* switch 


*verify confidence: high*

</details>

### `mpp/mpp_iommu.c` — 3 findings

| line | sev | category | finding |
|------|-----|----------|---------|
| 78 | medium | refcount-race-uaf | find_buffer_fd returns buffer without taking a ref after dropping list_mutex |
| 553 | low | null-deref | WARN_ON(!mapping) does not stop the NULL deref of mapping->domain |
| 269 | cleanup | dead-code | Dead CONFIG_DMABUF_CACHE guards (config does not exist on 6.18) |

### `mpp/mpp_rkvdec2.c` — 7 findings

| line | sev | category | finding |
|------|-----|----------|---------|
| 359 | high | security/out-of-bounds-write | Unbounded user-controlled rcb index used as array index into task->reg[] |
| 350 | high | security | Out-of-bounds kernel write via unvalidated user-controlled RCB register index |
| 1778 | medium | error-handling/null-vs-err_ptr | devm_clk_get/devm_reset_control_get failures checked with NULL test, leaving ERR_PTR stored |
| 1944 | medium | resource-leak | Raw ioremap(mmu_base) leaks on every probe error return, including the normal -EPROBE_DEFER ret |
| 1961 | medium | resource-leak | rcb buffer (alloc_pages + iommu_map) leaks when a later probe step fails |
| 319 | low | cleanup | Return value of mpp_extract_rcb_info() ignored |
| 2119 | low | dispatch-asymmetry | remove / shutdown / runtime PM dispatch by strstr(dev_name,"ccu") while probe dispatches by com |

<details><summary><b>HIGH</b> · L359 · Unbounded user-controlled rcb index used as array index into task->reg[]</summary>

**Problem.** In mpp_set_rcbbuf the loop does `reg_idx = rcb_inf->elem[i].index;` then `task->reg[reg_idx] = dec->rcb_iova + rcb_offset;`. The `index` field originates entirely from userspace: MPP_CMD_SET_RCB_INFO -> rkvdec2_extract_task_msg -> mpp_extract_rcb_info() does `copy_from_user(rcb_inf->elem, req->data, req->size)` and only bounds the element *count* (cnt <= ARRAY_SIZE(elem)=16). The per-element `index` (struct rcb_info_elem.index, u32) is never validated. `task->reg` is a fixed `u32 reg[RKVDEC_REG_NUM]` with RKVDEC_REG_NUM=360. A malicious/buggy client can set index to any value up to 2^32-1, producing an out-of-bounds write of an iova-sized value past the kzalloc'd rkvdec2_task. Only `rcb_offs


**Fix.** Bound-check the user-supplied register index before the write. Insert before line 359 (just after rcb_size is read / before task->reg[reg_idx] = ...):  			if (reg_idx >= RKVDEC_REG_NUM) { 				mpp_err("invalid rcb reg index %u\n", reg_idx); 				continue; 			}  so the write becomes:  			task->reg[reg_idx] = dec->rcb_iova + rcb_offset;  Use RKVDEC_REG_NUM (the array's compile-time size), NOT ARRAY_SIZE(task->reg) — task->reg is a u32* pointer in this function. Optionally apply array_index_nospec(re


*verify confidence: high*

</details>

<details><summary><b>HIGH</b> · L350 · Out-of-bounds kernel write via unvalidated user-controlled RCB register index</summary>

**Problem.** reg_idx is taken directly from user input: 'reg_idx = rcb_inf->elem[i].index;' (line 350) and then used to index the fixed 360-entry register array: 'task->reg[reg_idx] = dec->rcb_iova + rcb_offset;' (line 359). The index originates from MPP_CMD_SET_RCB_INFO -> mpp_extract_rcb_info(), which does copy_from_user() into rcb_inf->elem[] (line 255) and performs NO bounds check on the per-element 'index' field (struct rcb_info_elem.index is a raw u32). task->reg is 'u32 reg[RKVDEC_REG_NUM]' with RKVDEC_REG_NUM=360 inside the kzalloc'd struct rkvdec2_task. A malicious userspace can therefore set index to any u32 and force a 32-bit write of a kernel IOVA value at reg+index*4, far past the allocation


**Fix.** Add a bounds check on the user-controlled register index in mpp_set_rcbbuf() before it is used to index task->reg[]. Insert immediately after reg_idx/rcb_size are read (after current line 351, before the offset check at line 352):  			if (reg_idx >= task->hw_info->reg_num) 				continue;  (task is the struct mpp_task * arg; task->hw_info->reg_num is set in rkvdec2_task_init and equals the valid HW register count, <= RKVDEC_REG_NUM=360, so this is OOB-safe and behaviour-preserving for all legitima


*verify confidence: high*

</details>

### `mpp/mpp_rkvdec2_link.c` — 11 findings

| line | sev | category | finding |
|------|-----|----------|---------|
| 2587 | high | logic-bug | Per-core disable check tests the wrong device (outer mpp instead of core) |
| 853 | medium | dma-buffer-leak | DMA link table leaked when table-pointer-array allocation fails |
| 853 | medium | resource-leak | DMA link table leaked on table_array alloc failure |
| 1558 | medium | device-refcount-leak | platform_device reference from of_find_device_by_node leaked on non-defer return paths |
| 1555 | medium | resource-leak | of_find_device_by_node() pdev reference leaked on success and property-error paths |
| 853 | low | error-path/leak | DMA link table leaked when table-pointer-array allocation fails |
| 1535 | low | of_node-refcount-leak | of_node reference leaked when CCU node is present but unavailable |
| 1557 | low | error-path/leak | platform_device reference leaked on core-mask read failure |
| 1589 | low | cleanup | mpp_debug_enter() called again at function exit instead of mpp_debug_leave() |
| 430 | cleanup | cleanup | Duplicate 'reg 6' label in link register dump |
| 2406 | cleanup | cleanup | Dead commented-out cru-reset code and shadowed `val` variable |

<details><summary><b>HIGH</b> · L2587 · Per-core disable check tests the wrong device (outer mpp instead of core)</summary>

**Problem.** Inside the loop that builds the CCU work-mode mask the code iterates the cores: 'struct mpp_dev *core = queue->cores[i];' ... but then gates each core with 'if (mpp->disable) continue;' using the function's fixed parameter 'mpp' (the worker's own device), not the loop variable 'core'. Consequences: if the worker's mpp happens to be disabled, ALL cores are skipped and work_mode stays 0; if it is enabled, a disabled core is still OR'd into work_mode (work_mode \|= dec->core_mask) and has its RKVDEC_LINK_BIT_CCU_WORK_MODE set. Every other per-core loop in the file (rkvdec2_soft_ccu_reset, rkvdec2_hard_ccu_reset, rkvdec2_core_working, rkvdec2_get_idle_core) correctly tests the per-iteration core


**Fix.** Change line 2587 from `if (mpp->disable)` to `if (core->disable)` so the disable test applies to the core being added to the work-mode mask rather than the worker's own device.


*verify confidence: high*

</details>

### `mpp/mpp_rkvenc2.c` — 9 findings

| line | sev | category | finding |
|------|-----|----------|---------|
| 958 | high | buffer overflow | w_req_cnt / r_req_cnt can overflow the fixed-size w_reqs[]/r_reqs[] arrays |
| 3141 | high | refcount-imbalance | Missing mpp_dev_remove on probe error paths leaks pm_runtime/wakeup/iommu and unbalances pm_run |
| 1250 | medium | memory-leak | free_task error path leaks allocated per-class register buffers |
| 3152 | medium | error-path bug | Probe error paths return without unwinding mpp_dev_probe() |
| 2042 | low | info-leak | %s over-read of non-NUL-terminated codec_info value in procfs dump |
| 2969 | low | refcount-imbalance | CCU platform_device reference from of_find_device_by_node never released on success/remove |
| 1009 | cleanup | debug-trace imbalance | mpp_debug_enter() used where mpp_debug_leave() was intended |
| 1009 | cleanup | wrong-debug-trace | Exit paths call mpp_debug_enter() instead of mpp_debug_leave() |
| 2769 | cleanup | dead-code | vepu540c_irq is a pure pass-through wrapper around rkvenc_irq |

<details><summary><b>HIGH</b> · L958 · w_req_cnt / r_req_cnt can overflow the fixed-size w_reqs[]/r_reqs[] arrays</summary>

**Problem.** task->w_reqs and task->r_reqs are sized MPP_MAX_MSG_NUM (16). For each input message the code fans out one entry per overlapping register class: the inner `for (j = 0; j < hw->reg_class; j++)` loop does `task->w_req_cnt++;` (line 972) / `task->r_req_cnt++;` (line 990) for every class the request overlaps, with no check against MPP_MAX_MSG_NUM. reg_class is RKVENC_CLASS_BUTT (9), and msgs->req_cnt can be up to 16, so a single submit whose requests straddle multiple class ranges (e.g. just 2 classes/message over ~9 messages) drives the counter past 16. The writes `wreq = &task->w_reqs[task->w_req_cnt];` (line 958) / `rreq = &task->r_reqs[task->r_req_cnt];` (line 987) then scribble past the arr


**Fix.** Bound-check the counter before indexing the array in both cases. WRITE case, insert immediately before line 958 (`wreq = &task->w_reqs[task->w_req_cnt];`):  				if (task->w_req_cnt >= MPP_MAX_MSG_NUM) { 					mpp_err("w_req_cnt %d overflow\n", task->w_req_cnt); 					ret = -EINVAL; 					goto fail; 				} 				wreq = &task->w_reqs[task->w_req_cnt];  READ case, insert immediately before line 987 (`rreq = &task->r_reqs[task->r_req_cnt];`):  				if (task->r_req_cnt >= MPP_MAX_MSG_NUM) { 					mpp_err("r_


*verify confidence: high*

</details>

<details><summary><b>HIGH</b> · L3141 · Missing mpp_dev_remove on probe error paths leaks pm_runtime/wakeup/iommu and unbalances p</summary>

**Problem.** After a successful mpp_dev_probe(mpp, pdev) (which performs non-devm setup: pm_runtime_enable(), device_init_wakeup(dev,true), mpp_iommu_probe(), mpp_attach_service(), kthread work, and hw_ops->init), rkvenc_core_probe returns on two error paths without unwinding it:   - attach_ccu failure: `ret = rkvenc_attach_ccu(dev, enc); if (ret) { dev_err(...); return ret; }` (lines 3140-3144)   - irq failure: `if (ret) { dev_err(...); return -EINVAL; }` (lines 3152-3155) rkvenc_attach_ccu can legitimately return -EPROBE_DEFER (line 2931) when the CCU has not probed yet -- a normal, repeated boot path. Each deferred retry re-runs mpp_dev_probe without a matching mpp_dev_remove, so pm_runtime_enable() i


**Fix.** Route both post-mpp_dev_probe error paths through an unwind label that calls mpp_dev_remove(mpp), mirroring rkvenc_probe_default. Replace the two bare returns:  	/* attach core to ccu */ 	ret = rkvenc_attach_ccu(dev, enc); 	if (ret) { 		if (ret != -EPROBE_DEFER) 			dev_err(dev, "attach ccu failed\n"); 		goto failed; 	} 	rkvenc2_alloc_rcbbuf(pdev, enc);  	ret = devm_request_threaded_irq(dev, mpp->irq, mpp_dev_irq, NULL, 					IRQF_ONESHOT, dev_name(dev), mpp); 	if (ret) { 		dev_err(dev, "register 


*verify confidence: high*

</details>

### `mpp/mpp_service.c` — 10 findings

| line | sev | category | finding |
|------|-----|----------|---------|
| 426 | medium | resource leak | class leaked on taskqueue-count validation failure |
| 426 | medium | leak | class leaked on taskqueue-count bounds-check failure |
| 435 | medium | missing error check / use-after-free | kthread_run() return value unchecked; ERR_PTR stored as kworker_task and later passed to kthrea |
| 445 | medium | resource leak | class and running kthread workers leaked on resetgroup-count validation failure |
| 445 | medium | leak | class and running kthread workers leaked on resetgroup-count failure |
| 494 | medium | error-path leak | kthread workers started before mpp_register_service() are not stopped on the fail_register erro |
| 494 | medium | resource leak | fail_register path leaks spawned kthread workers |
| 150 | low | ignored return value | device_create() return value not checked; function returns 0 even on failure |
| 150 | low | robustness | device_create() return value not checked for error |
| 435 | low | error handling | kthread_run return value unchecked; ERR_PTR stored and later passed to kthread_stop |

### `rga3/rga_common.c` — 3 findings

| line | sev | category | finding |
|------|-----|----------|---------|
| 307 | low | logic-bug | Swapped name strings for the two 10-bit 420 semi-planar formats |
| 307 | low | cleanup | Swapped Cb/Cr name strings for 420-SP-10B formats |
| 770 | low | security | Signed int overflow in size math from w/h |

### `rga3/rga_debugger.c` — 6 findings

| line | sev | category | finding |
|------|-----|----------|---------|
| 82 | medium | integer-underflow / out-of-bounds write | buf[len - 1] underflows to buf[-1] when len == 0 |
| 82 | medium | security | Zero-length write causes out-of-bounds stack write buf[-1] in all four write handlers |
| 936 | medium | resource leak (dma-buf/vmap mapping) | size<=0 early return leaks dma_buf_vmap()/vmap() mapping |
| 378 | low | race / out-of-bounds read | loop bound uses live request->task_count instead of the value captured under request->lock |
| 285 | cleanup | format-string typo | missing separator runs iova value into 'sgt' in the dma_buffer dump |
| 285 | cleanup | cleanup | Malformed format string: missing separator between iova and sgt fields |

### `rga3/rga_dma_buf.c` — 2 findings

| line | sev | category | finding |
|------|-----|----------|---------|
| 14 | medium | cleanup-dead-code | rga_virtual_memory_check and rga_dma_memory_check are dead in-tree and carry an unchecked user- |
| 27 | low | wrong/ignored return value | kzalloc failure returns 0 (success) instead of an error |

### `rga3/rga_drv.c` — 7 findings

| line | sev | category | finding |
|------|-----|----------|---------|
| 804 | high | resource leak | Early returns skip rga_request_put(), leaking a request reference on submit/copy failure |
| 804 | high | refcount-leak | rga_request reference leaked on submit/copy_to_user error paths |
| 751 | medium | ignored return value | Negative rga_request_alloc() errno stored in uint32_t and reported to user as success |
| 945 | medium | security | RGA_IOC_GET_HW_VERSION leaks uninitialized kernel stack to userspace |
| 670 | low | resource-leak | Partially-imported buffer handles orphaned on mid-loop import failure |
| 1427 | low | refcount-imbalance | pm_runtime usage count not dropped on probe error path |
| 1321 | cleanup | cleanup | Wrong error string in RGA3 device branch |

<details><summary><b>HIGH</b> · L804 · Early returns skip rga_request_put(), leaking a request reference on submit/copy failure</summary>

**Problem.** rga_request_config() returns the request with an extra reference taken via rga_request_get() (rga_job.c:1111); the caller is responsible for releasing it, which the success path does at the tail: `mutex_lock(&request_manager->lock); rga_request_put(request); mutex_unlock(...)` (lines 817-819). However the two error paths inside `if (run_enbale)` return early without that put:   line 802-805: `ret = rga_request_submit(request); if (ret < 0) { rga_err(...); return -EFAULT; }`   line 809-813: `if (copy_to_user(...)) { rga_err("copy_to_user failed\n"); return -EFAULT; }` Both `return -EFAULT;` bypass rga_request_put(), so the reference obtained from rga_request_config() is leaked. Since the elev


**Fix.** Convert the two early returns inside `if (run_enbale)` into gotos that reach the existing put, so the reference taken by rga_request_config() is always released. Rewrite rga_drv.c lines 800-821 as:  	if (run_enbale) { 		ret = rga_request_submit(request); 		if (ret < 0) { 			rga_err("request[%d] submit failed!\n", user_request.id); 			ret = -EFAULT; 			goto err_put_request; 		}  		if (request->sync_mode == RGA_BLIT_ASYNC) { 			user_request.release_fence_fd = request->release_fence_fd; 			if (copy


*verify confidence: high*

</details>

<details><summary><b>HIGH</b> · L804 · rga_request reference leaked on submit/copy_to_user error paths</summary>

**Problem.** rga_request_config() returns the request with an extra reference (rga_job.c:1111 `rga_request_get(request)`), which the caller must release. The normal path drops it at line 818 (`rga_request_put(request)` under request_manager->lock). But two error paths return early and skip that put: after submit failure `if (ret < 0) { rga_err(...); return -EFAULT; }` (lines 802-804) and after the async copy_to_user failure `if (copy_to_user(...)) { rga_err(...); return -EFAULT; }` (lines 809-812). Each leaks one reference, so the rga_request (and its task_list/job resources) is never freed. The sibling rga_ioctl_blit handles the identical situation correctly via `goto err_put_request`.


**Fix.** Mirror rga_ioctl_blit. Replace the two bare `return -EFAULT;` statements with `ret = -EFAULT; goto err_put_request;` and convert the existing epilogue into the labeled cleanup.  At lines 802-805: 		ret = rga_request_submit(request); 		if (ret < 0) { 			rga_err("request[%d] submit failed!\n", user_request.id); 			ret = -EFAULT; 			goto err_put_request; 		}  At lines 809-813: 			if (copy_to_user((struct rga_req *)arg, 					 &user_request, sizeof(user_request))) { 				rga_err("copy_to_user failed\n


*verify confidence: high*

</details>

### `rga3/rga_fence.c` — 2 findings

| line | sev | category | finding |
|------|-----|----------|---------|
| 68 | medium | race | Unlocked ++fence_ctx->seqno races across concurrent fence allocations |
| 68 | low | concurrency-race | Non-atomic increment of shared fence seqno outside its spinlock |

### `rga3/rga_iommu.c` — 3 findings

| line | sev | category | finding |
|------|-----|----------|---------|
| 378 | low | logic-bug | Fallback 'another_index' compared against core bitmask RGA_NONE_CORE instead of its -1 sentinel |
| 378 | low | correctness/cleanup | Default-core selection compares a scheduler index against a core-type constant |
| 15 | cleanup | dead-code | rga_user_memory_check is dead debug code with latent OOB/overflow/sleep bugs |

### `rga3/rga_job.c` — 4 findings

| line | sev | category | finding |
|------|-----|----------|---------|
| 991 | high | refcount-leak | acquire_fence dma_fence reference leaked on every path (get with no matching put) |
| 682 | high | concurrency | Sleep-in-atomic: mutex_lock and sleeping unmap called under spin_lock_irqsave in shutdown todo- |
| 603 | medium | error-path bug / race | Acquire-fence signaled in race window is treated as fatal error (request wrongly aborted) |
| 316 | low | integer/units bug | Millisecond elapsed time compared against RGA_JOB_TIMEOUT_DELAY (== HZ), a jiffies count |

<details><summary><b>HIGH</b> · L991 · acquire_fence dma_fence reference leaked on every path (get with no matching put)</summary>

**Problem.** Line 555 obtains the acquire fence via `acquire_fence = rga_get_dma_fence_from_fd(acquire_fence_fd);`. In this tree rga_get_dma_fence_from_fd() -> sync_file_get_fence() returns the fence with a fresh dma_fence_get() reference that the caller owns. This reference is never released on ANY subsequent path:   - line 578-581: `if (ret < 0) { ...; return ret; }` returns without putting acquire_fence.   - line 582-585: `} else if (ret > 0) { /* has been signaled */ return ret; }` returns without putting acquire_fence.   - line 595-604: when rga_dma_fence_add_callback() fails, the function does `rga_request_put(request); return ret;` but never puts acquire_fence.   - line 595/606 success path: rga_d


**Fix.** Balance the reference obtained at rga_job.c:555. Four edits:  1) Before the status<0 return (line ~581), change `return ret;` to: `rga_dma_fence_put(acquire_fence); return ret;`  2) Before the already-signaled status>0 return (line ~584), change `return ret;` to: `rga_dma_fence_put(acquire_fence); return ret;`  3) In the add_callback-failure block, before the `return ret;` at line ~603 (after the rga_request_put(request) block), add: `rga_dma_fence_put(acquire_fence);`  4) In rga_request_acquire


*verify confidence: high*

</details>

<details><summary><b>HIGH</b> · L682 · Sleep-in-atomic: mutex_lock and sleeping unmap called under spin_lock_irqsave in shutdown </summary>

**Problem.** In the `else` (no running_job) branch, the todo-list is cleaned up while still holding `scheduler->irq_lock` (taken with spin_lock_irqsave at line 653, only released at line 689):          list_for_each_entry_safe(job, job_q, &scheduler->todo_list, head) {                 rga_mm_unmap_job_info(job);                 job->ret = -EBUSY;                 rga_request_release_signal(scheduler, job);         }         spin_unlock_irqrestore(&scheduler->irq_lock, flags);  Both callees sleep while the lock is held with IRQs disabled: `rga_request_release_signal()` calls `mutex_lock(&request_manager->lock)` (line 1010), and `rga_mm_unmap_job_info()` performs DMA/IOMMU teardown that can sleep. This is a


**Fix.** Declare a local list at the top of rga_request_scheduler_shutdown (e.g. add `LIST_HEAD(list_to_free);` next to the existing locals), then replace the else-branch body (lines 681-689) with:  	} else { 		/* Move the todo jobs that need to be freed to a local list. */ 		list_for_each_entry_safe(job, job_q, &scheduler->todo_list, head) { 			list_move(&job->head, &list_to_free); 			scheduler->job_count--; 		}  		spin_unlock_irqrestore(&scheduler->irq_lock, flags);  		/* Clean up outside the lock sinc


*verify confidence: high*

</details>

### `rga3/rga_mm.c` — 8 findings

| line | sev | category | finding |
|------|-----|----------|---------|
| 1256 | high | NULL deref | NULL deref on job_buf->v_addr / uv_addr in third-address path when a plane handle is 0 |
| 1555 | high | use-after-free / refcount leak | kref leaked when rga_mm_get_buffer_info() fails |
| 1555 | high | refcount-imbalance | rga_mm_get_buffer error paths are inconsistent: one leaks the kref, others drop it, all leave * |
| 1776 | high | resource-leak | Partial channel acquisition is not released when a later channel fails (handle path leaks buffe |
| 2433 | medium | missing error check / leak | Mapped buffer leaked when idr_alloc_cyclic() fails |
| 1272 | low | memory | page_table allocated with wrong element size (sizeof(uint32_t *) for a uint32_t array) |
| 502 | cleanup | simplification | Redundant ternary `phys_addr ? phys_addr : 0` |
| 2304 | cleanup | dead-code | Redundant no-op re-set of RGA_JOB_DEBUG_FAKE_BUFFER flag |

<details><summary><b>HIGH</b> · L1256 · NULL deref on job_buf->v_addr / uv_addr in third-address path when a plane handle is 0</summary>

**Problem.** In the "using third-address" branch (entered via `if (job_buf->uv_addr)`), the code unconditionally dereferences all three plane buffer pointers:   `if (job_buf->y_addr->virt_addr != NULL)` (1252),   `if (job_buf->uv_addr->virt_addr != NULL)` (1254),   `if (job_buf->v_addr->virt_addr != NULL)` (1256). It then calls `rga_mm_lookup_sgt(job_buf->v_addr)` (1307) which dereferences `buffer->dma_buffer`. But rga_mm_get_channel_handle_info() only populates each of y_addr/uv_addr/v_addr when the corresponding handle is > 0 (`if (handle > 0)`), leaving the others NULL (job_buffer is zero-initialized). For a 2-plane format (e.g. NV12) driven through the separate-plane handle interface, img->v_addr is 


**Fix.** Guard each plane pointer (not just its ->virt_addr) before dereferencing, and skip the sgt lookup/page-table fill for any NULL plane (its plane count is 0). Minimal behaviour-preserving change in rga_mm_set_mmu_base:  Offset section (lines 1252-1257):   if (job_buf->y_addr && job_buf->y_addr->virt_addr != NULL)       yrgb_offset = job_buf->y_addr->virt_addr->offset;   if (job_buf->uv_addr && job_buf->uv_addr->virt_addr != NULL)       uv_offset = job_buf->uv_addr->virt_addr->offset;   if (job_buf


*verify confidence: high*

</details>

<details><summary><b>HIGH</b> · L1555 · kref leaked when rga_mm_get_buffer_info() fails</summary>

**Problem.** After `kref_get(&internal_buffer->refcount)` (line 1542) and unlocking, the error path for get_buffer_info returns directly without dropping the reference:   `ret = rga_mm_get_buffer_info(job, internal_buffer, channel_addr);`   `if (ret < 0) { rga_job_err(...); return ret; }` (1551-1556). Every other error path in this function (`internal_buffer->size < require_size` and the sync-for-device failure) correctly uses `goto put_internal_buffer;` which performs `kref_put(...rga_mm_kref_release_buffer)`. rga_mm_get_buffer_info() can fail (returns -EINVAL for an invalid dma-buffer under IOMMU, -EFAULT for an illegal type), so this is a reachable refcount leak: the imported buffer's refcount never r


**Fix.** In /home/yi/Code/linux-6.18-rkvenc/drivers/video/rockchip/rga3/rga_mm.c, function rga_mm_get_buffer, replace the direct `return ret;` at line 1555 with `goto put_internal_buffer;`.  Before (1552-1556): 	ret = rga_mm_get_buffer_info(job, internal_buffer, channel_addr); 	if (ret < 0) { 		rga_job_err(job, "handle[%ld] failed to get internal buffer info!\n", 			(unsigned long)handle); 		return ret; 	}  After: 	ret = rga_mm_get_buffer_info(job, internal_buffer, channel_addr); 	if (ret < 0) { 		rga_jo


*verify confidence: high*

</details>

<details><summary><b>HIGH</b> · L1555 · rga_mm_get_buffer error paths are inconsistent: one leaks the kref, others drop it, all le</summary>

**Problem.** rga_mm_get_buffer does `kref_get(&internal_buffer->refcount)` at line 1542, then has two classes of error exit with OPPOSITE refcount behavior, and both leave the caller's out-pointer assigned (`*buf` was set at line 1533 before any failure can occur):    (a) rga_mm_get_buffer_info() failure (lines 1551-1556) does `return ret;` WITHOUT releasing the ref it just took -> net +1 leak.   (b) size-check failure (1558-1563) and sync-for-device failure (1566-1576) `goto put_internal_buffer` which DOES kref_put (1583) -> net 0, but `*buf` (e.g. job_buf->uv_addr) still points at the buffer whose ref was just dropped.  So on error the caller cannot know whether it owns a reference, and the out-param i


**Fix.** Make all post-kref_get error exits symmetric (drop the ref + clear *buf).\n\n1) Route the get_buffer_info failure through the put label instead of returning directly. Replace lines 1551-1556:\n\n\tret = rga_mm_get_buffer_info(job, internal_buffer, channel_addr);\n\tif (ret < 0) {\n\t\trga_job_err(job, \"handle[%ld] failed to get internal buffer info!\\n\",\n\t\t\t(unsigned long)handle);\n\t\tgoto put_internal_buffer;   /* was: return ret; */\n\t}\n\n2) Clear the dangling out-param in the shared 


*verify confidence: high*

</details>

<details><summary><b>HIGH</b> · L1776 · Partial channel acquisition is not released when a later channel fails (handle path leaks </summary>

**Problem.** rga_mm_get_handle_info acquires channels sequentially via rga_mm_get_channel_handle_info: src (1762), dst (1772), pat (1789/1793). On any failure it simply `return ret;` (e.g. lines 1776-1778 for dst, 1797-1800 for pat) WITHOUT releasing channels already acquired by earlier calls. Each successful rga_mm_get_buffer did kref_get on an IDR-resident internal_buffer, so those refs are now leaked. The same gap exists one level down inside rga_mm_get_channel_handle_info itself: in the three-plane branch, if y_addr is acquired (1647) but uv_addr (1658) or v_addr (1668) fails, it returns without putting the already-acquired y_addr/uv_addr.  This is not recovered by the caller: rga_mm_map_job_info ret


**Fix.** Make the handle path self-unwinding like the non-handle path, and make releases idempotent so already-cleaned channels are not double-put. Three coordinated edits:  1) rga_mm_get_buffer (rga_mm.c:1516): guarantee that on EVERY error after kref_get, the ref is balanced and *buf is NULLed. Route the get_buffer_info failure through the cleanup label (it currently `return ret` at 1555 WITHOUT kref_put — a latent leak), and NULL *buf in the label:    - line 1552-1556: change `return ret;` to `goto pu


*verify confidence: high*

</details>

### `rga3/rga_policy.c` — 4 findings

| line | sev | category | finding |
|------|-----|----------|---------|
| 351 | high | logic bug | Feature compatibility check accepts cores that support only a subset of requested features |
| 201 | low | misleading diagnostics | Resolution-failure log always prints input_range even for the dst (output) channel |
| 199 | low | cleanup | Resolution-fail debug log hardcodes input_range even for the dst (output) channel |
| 330 | cleanup | cleanup | Loop-invariant need_swap computed inside the per-scheduler loop |

<details><summary><b>HIGH</b> · L351 · Feature compatibility check accepts cores that support only a subset of requested features</summary>

**Problem.** The feature gate uses `if (!(feature & data->feature))` to reject a core. `feature` is the bitwise-OR of ALL features a job needs (rga_set_feature can set RGA_COLOR_KEY\|RGA_ROP_CALCULATE\|RGA_NN_QUANTIZE\|... simultaneously, e.g. color_key_max>0 together with the ROP bit of alpha_rop_flag). `!(feature & data->feature)` is true only when the core supports NONE of the requested features; it does NOT require the core to support ALL of them. So if a job needs both COLOR_KEY (0x4) and ROP_CALCULATE (0x8) -> feature=0xC, and a core advertises only `.feature = RGA_COLOR_KEY` (0x4), then `feature & data->feature = 0x4` is non-zero and the core is wrongly kept as optional. That core is then eligible


**Fix.** In rga_job_assign() in drivers/video/rockchip/rga3/rga_policy.c, require the core to support ALL requested feature bits. Inside the existing `if (feature > 0)` guard, replace line 351:      if (!(feature & data->feature)) {  with:      if ((feature & data->feature) != feature) {  Leave the surrounding `if (feature > 0)` guard and the continue/log body unchanged. This rejects any core missing one or more requested feature bits (e.g. a COLOR_KEY-only rga3 core for a COLOR_KEY\|ROP_CALCULATE job) w


*verify confidence: high*

</details>

---
## Draft patch series

Per-file diffs are in [`cleanup-draft/`](cleanup-draft/). They apply on top of the forward-port (`patches/`). All compile clean on arm64 (`make drivers/video/rockchip/`). Review each before merging; start with the HIGH-severity items above.
