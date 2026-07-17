# kernel-drivers/rknpu — keywords

RKNPU and RKNN terms. The complete walkthrough is
[`docs/how-rknpu-works.md`](docs/how-rknpu-works.md); cross-cutting vocabulary is
in [`../../glossary.md`](../../glossary.md).

- **RKNPU** — Rockchip's neural-processing hardware family and the BSP kernel
  driver under `drivers/rknpu`. On RK3588 the driver manages three NPU cores.
- **RKNN** — Rockchip's target-specific compiled neural-network model format.
  It contains more than a framework graph: the official guide says it includes
  weights, graph structure, and NPU register-configuration information.
- **RKNN-Toolkit2** — host/ARM64 Python toolchain for importing a framework
  model, configuring preprocessing/target/quantization, optimizing and building
  it, evaluating it, and exporting `.rknn`.
- **RKNN Toolkit-Lite2 / `RKNNLite`** — board-side Python wrapper used to load
  an existing RKNN model and invoke the native runtime.
- **RKNN Runtime / `librknnrt.so`** — proprietary native C/C++ implementation
  for RK356x/RK3576/RK3588/RV1126B. It parses RKNN models, manages contexts and
  tensors, prepares low-level NPU work, and calls the RKNPU kernel ABI.
- **`librknnmrt.so`** — smaller runtime variant for RV1103/RV1106-class 32-bit
  uClibc systems; not the RK3588 runtime.
- **RKLLM** — Rockchip's separate stack for large language models
  (`airockchip/rknn-llm`), over the same `drivers/rknpu` kernel driver. It has
  its own toolkit, `.rkllm` model format, and `librkllmrt.so` runtime — not part
  of RKNN-Toolkit2/`librknnrt`. Full survey:
  [`docs/rkllm-large-language-models.md`](docs/rkllm-large-language-models.md).
- **RKLLM-Toolkit** — host Python toolchain that converts a Hugging Face (or
  GGUF) transformer to `.rkllm`, quantizing to `w8a8` or `w4a16` and baking in
  `max_context` and the target platform.
- **RKLLM Runtime / `librkllmrt.so`** — board-side native runtime that tokenizes,
  manages the KV-cache, submits per-token NPU work, and streams tokens through a
  callback. Supports prompt/embedding/token/multimodal inputs, LoRA, and prompt
  cache.
- **`.rkllm`** — target-specific compiled LLM artifact (quantized weights, graph,
  chat template). Analogous to `.rknn` but for the RKLLM runtime, not
  interchangeable with it.
- **w8a8 / w4a16** — RKLLM quantization modes: 8-bit weight/8-bit activation and
  4-bit weight/16-bit activation. w4a16 roughly halves model RAM at some quality
  cost.
- **`rknn_server`** — board-side proxy used by x86 RKNN-Toolkit2 for connected
  debugging. It receives model/data/API requests over the ADB/USB transport,
  invokes the board runtime, and returns results. Native board applications do
  not need it.
- **general API** — `rknn_inputs_set()` / `rknn_outputs_get()` path. The runtime
  owns internal IO buffers and normally copies/preprocesses/postprocesses on the
  CPU around NPU inference.
- **zero-copy API** — persistent `rknn_tensor_mem` bindings made with
  `rknn_create_mem*()` plus `rknn_set_io_mem()`. It can import dma-buf fds or
  physical buffers and avoids the general path's per-frame copy.
- **native tensor layout** — the hardware-efficient layout reported by
  `RKNN_QUERY_NATIVE_*_ATTR`, commonly NHWC, NCHW, or the blocked
  `NC1HWC2` layout. `size_with_stride` includes hardware padding.
- **internal tensor memory** — reusable intermediate-feature storage for layer
  outputs. It is separate from weights and input/output buffers and is the
  model memory most directly eligible for optional NPU SRAM placement.
- **register-command buffer** — runtime/model-generated configuration stream
  consumed by the NPU program-controller path. A kernel `rknpu_task` points to
  it with `regcmd_addr` and records its configuration count.
- **task buffer** — GEM/dma-heap buffer containing `struct rknpu_task` entries.
  The kernel indexes this buffer, launches its register-command addresses, and
  writes completion status into the final task.
- **PC mode** — NPU program-controller submission mode. The BSP driver writes
  `PC_DATA_ADDR`, `PC_DATA_AMOUNT`, `PC_TASK_CONTROL`, `PC_DMA_BASE_ADDR`, and
  toggles `PC_OP_EN`; non-PC submission is effectively rejected.
- **core mask** — runtime choice of automatic, core 0/1/2, cores 0+1, or all
  three. The runtime supplies per-subcore task ranges; the kernel coordinates
  their simultaneous start and completion.
- **IOMMU domain id** — caller-visible selector for one of up to 16 RKNPU-
  managed address spaces. The current driver switches the device globally
  between them; it is not the same as a per-process DRM VM.
- **SRAM / NBUF** — optional on-chip fast memory used as the leading portion of
  an NPU-visible IOVA, with DDR backing the remainder. RK3588 documentation
  describes up to 956 KiB of its 1 MiB system SRAM as assignable to clients;
  actual RKNPU reservation is determined by DT and competing IP blocks.
