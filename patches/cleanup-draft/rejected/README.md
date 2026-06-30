# Rejected cleanup-draft patches

Patches here **failed** adversarial verification (`../VERIFICATION.md`) — they
compile but introduce a new bug. Do **not** apply them as written.

- **`mpp_iommu.patch`** — adds `kref_get_unless_zero` to `mpp_dma_find_buffer_fd()`,
  changing its contract to return +1 ref, but only updates 1 of its 3 callers.
  `mpp_dma_release_fd()` (the `RELEASE_FD` ioctl) and `rkvenc2_task_init()` (the
  per-frame encode path) then **leak** the extra ref — `RELEASE_FD` never frees
  the IOMMU mapping, and the encoder leaks one buffer ref per frame. Same root
  failure mode as the audit's known double-`kref_put` UAF, in the leak direction.
  The underlying race (find returns a buffer without a ref, taken/released under
  the same mutex) is real and still worth fixing — but with all three callers
  updated, or via a separate `find_and_get` variant.
