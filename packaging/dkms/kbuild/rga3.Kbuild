# rga3.ko — RK3588 RGA3 x2 + RGA2 2D accelerator.
ccflags-y += -I$(src)/include
ccflags-y += -DCONFIG_ROCKCHIP_MULTI_RGA -DCONFIG_ROCKCHIP_RGA_ASYNC \
             -DCONFIG_ROCKCHIP_RGA_DEBUGGER -DCONFIG_ROCKCHIP_RGA_PROC_FS \
             -DCONFIG_ROCKCHIP_RGA_DEBUG_FS

obj-m += rga3.o
rga3-y := rga_drv.o rga_common.o rga3_reg_info.o rga_iommu.o rga_dma_buf.o \
          rga_job.o rga_hw_config.o rga2_reg_info.o rga_policy.o rga_mm.o \
          rga_fence.o rga_debugger.o
