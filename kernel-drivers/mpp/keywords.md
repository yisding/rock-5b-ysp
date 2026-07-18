# kernel-drivers/mpp — keywords

MPP service + codec-core terms. Cross-cutting vocabulary is in
[`../../glossary.md`](../../glossary.md).

- **MPP** — Rockchip Media Process Platform; the vendor hardware-codec framework
  reached via `/dev/mpp_service` (not V4L2).
- **mpp_srv / mpp_service** — the shared service DT node and the char device every
  core attaches to (`rockchip,srv`).
- **VEPU580 / `rkvenc2`** — the H.264/H.265 hardware encoder and its driver; two
  cores `fdbd0000`/`fdbe0000`.
- **VDPU381 / `rkvdec2`** — the H.264/H.265/VP9/AVS2 hardware decoder and its driver;
  two cores plus a real CCU block.
- **DCHS** — dual-core hand-shake: hardware TX/RX channels in the VEPU580 core
  registers. Software assigns and links the channel IDs; the encoder has no
  separate CCU register block.
- **link mode** — the decoder's descriptor-table job chaining (hardware walks a
  linked table of task configs); distinct from RCB.
- **soft / hard CCU** — the decoder CCU's two dispatch modes (`rockchip,ccu-mode`):
  soft = driver picks the core (shipped default); hard = CCU hardware dispatches.
- **taskqueue / core-mask** — a cluster's work queue and the DT bitmask naming its
  cores.
- **DPB** — Decoded Picture Buffer; the per-stream reference dependency that
  forbids splitting one decode stream across cores. See
  [`docs/multicore-scheduling.md`](docs/multicore-scheduling.md).
- **collector / `mpp_collect_msgs`** — the kernel loop that walks one
  `MPP_IOC_CFG_V1` syscall's packed message array into per-session task containers.
  See [`docs/ioctl-collector.md`](docs/ioctl-collector.md).
- **`MULTI_MSG` / `LAST_MSG`** — the two flag bits that drive the collector loop:
  "keep walking" and "final message of the whole syscall — stop." `LAST_MSG` is
  **one per ioctl**, not per batch.
- **`SET_SESSION_FD`** — the real per-batch delimiter inside a multi-session ioctl:
  flushes the previous container as its own task and switches to the next session
  (`struct mpp_bat_msg`). Not a task-start, never the last message.
- **`mpp_task_msgs`** — the per-session, pool-recycled container the collector fills
  (`reqs[16]`, `set_cnt`/`poll_cnt`); `set_cnt` ⇒ submit a task, `poll_cnt` ⇒ wait.
