# rk_vcodec.ko — RK3588 vendor MPP service framework (rkvenc2 + rkvdec2).
#
# Out-of-tree build note: the vendor CONFIG_ROCKCHIP_MPP_* symbols are not in a
# host kernel's config, so the in-tree `obj-$(CONFIG_…)` selection can't work.
# We list the objects explicitly and -D the symbols the C code #ifdef's on.
# This set = encoder + decoder + procfs; devfreq is intentionally OFF (so the
# private drivers/devfreq/governor.h is never pulled — see the forward-port).
ccflags-y += -I$(src)/compat
ccflags-y += -DMPP_VERSION=\"6.18-7.2-dkms\"
ccflags-y += -include $(src)/compat/rockchip_qos_compat.h
ccflags-y += -DCONFIG_ROCKCHIP_MPP_SERVICE -DCONFIG_ROCKCHIP_MPP_RKVENC2 \
             -DCONFIG_ROCKCHIP_MPP_RKVDEC2 -DCONFIG_ROCKCHIP_MPP_PROC_FS

obj-m += rk_vcodec.o
rk_vcodec-y := mpp_service.o mpp_common.o mpp_iommu.o \
               mpp_rkvenc2.o mpp_rkvdec2.o mpp_rkvdec2_link.o
