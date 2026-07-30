# Forward-port RGA userptr-IOMMU debug patch bundle

These patches archive the debug-only commits removed from the clean
`rkvenc-fwport-6.18` forward-port branch on 2026-07-06.

Apply base:

```sh
cd /home/yi/Code/rock-5b/kernel/linux-6.18-rkvenc-av1-fwport
git switch -c rkvenc-fwport-6.18-debug-work rkvenc-fwport-6.18
git am /home/yi/Code/rock-5b-ysp/kernel-drivers/patches/iommu-debug/forward-port-rga-userptr-iommu/*.patch
```

Kernel repo preservation branch:

```sh
rkvenc-fwport-6.18-iommu-debug-20260706
```

Patch contents:

1. Temporary `DIAG` logging for RGA3 `dma_map_sg` non-coalescing.
2. DIAG fixup.
3. DIAG fixup.
4. Rockchip/VSI IOMMU per-device debugfs fault counters.
5. RGA3 userptr-IOMMU debugfs counters and force-remap knob.

Do not apply these for a clean .deb. They are for attribution/debug kernels.
