/* Legacy RGA_BLIT 10-bit stride-convention gate probe.
 *
 * The legacy contract (JeffyCN GStreamer / librga c_RkRgaBlit) passes
 * rga_req.img.vir_w as a BYTE stride for 10-bit formats (448 for a
 * 320-wide compact NV12_10 surface).  On the 0048-regressed kernel the
 * RGA3 register writer treats vir_w as pixels and programs
 * ALIGN(vir_w*10/8,16)-byte rows, over-reading 25% -> IOMMU read fault +
 * EACCES; RGA2 honors the byte-stride contract and succeeds.  See
 * findings/2026-07-24-rga3-legacy-blit-10bit-stride-convention-fault.md.
 *
 * Buffers are dma-heap fds (default_cma_region, below 4G) so the RGA2
 * control leg is not perturbed by the RGA2 over-4G userptr limitation.
 * fd convention: yrgb_addr = fd.
 *
 * Usage: rga-10bit-legacy-stride-test <core-mask> [heap-path]
 *   core-mask: 1=RGA3 core0, 2=RGA3 core1, 4=RGA2, 0=scheduler default
 * Pass criterion (fixed kernel): exit 0 on ALL of core-mask 1, 4, and 0
 * with no new RGA/IOMMU fault lines in the kernel log.
 * Build like legacy-blit-test.c: shim empty linux/mutex.h +
 * linux/scatterlist.h and -Du8=uint8_t -Du16=uint16_t -Du32=uint32_t
 * -Du64=uint64_t against the forward-port tree's rga3/include/rga.h.
 * Add -include stdbool.h on any compiler defaulting to pre-C23: rga.h uses
 * `bool`, which the shims do not provide. gcc 15 (C23 default) needs nothing;
 * gcc 13 as shipped on the Noble builder defaults to gnu17 and fails without it.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <linux/types.h>

#include "rga.h"

struct dma_heap_allocation_data {
	__u64 len;
	__u32 fd;
	__u32 fd_flags;
	__u64 heap_flags;
};
#define DMA_HEAP_IOCTL_ALLOC _IOWR('H', 0x0, struct dma_heap_allocation_data)

#define SRC_W 320
#define SRC_H 240
#define SRC_STRIDE_BYTES 448

static int heap_alloc(const char *path, size_t len)
{
	struct dma_heap_allocation_data d = { .len = len, .fd_flags = O_RDWR | O_CLOEXEC };
	int hf = open(path, O_RDONLY | O_CLOEXEC);
	if (hf < 0) { perror(path); return -1; }
	if (ioctl(hf, DMA_HEAP_IOCTL_ALLOC, &d) < 0) { perror("heap alloc"); close(hf); return -1; }
	close(hf);
	return d.fd;
}

int main(int argc, char **argv)
{
	int core = argc > 1 ? atoi(argv[1]) : 0;
	const char *heap = argc > 2 ? argv[2] : "/dev/dma_heap/default_cma_region";
	size_t src_size = (size_t)SRC_STRIDE_BYTES * SRC_H * 3 / 2; /* 161280 */
	size_t dst_size = (size_t)SRC_W * SRC_H * 3 / 2;
	struct rga_req req;
	int fd, ret, sfd, dfd;

	sfd = heap_alloc(heap, src_size);
	dfd = heap_alloc(heap, dst_size);
	if (sfd < 0 || dfd < 0)
		return 2;

	fd = open("/dev/rga", O_RDWR | O_CLOEXEC);
	if (fd < 0) { perror("open /dev/rga"); return 2; }

	memset(&req, 0, sizeof(req));
	req.render_mode = 0;

	req.src.yrgb_addr = sfd; /* modern legacy-blit convention: fd here */
	req.src.vir_w = SRC_STRIDE_BYTES; /* legacy: BYTE stride for 10-bit */
	req.src.vir_h = SRC_H;
	req.src.act_w = SRC_W;
	req.src.act_h = SRC_H;
	req.src.format = RGA_FORMAT_YCbCr_420_SP_10B;
	req.src.rd_mode = RGA_RASTER_MODE;

	req.dst.yrgb_addr = dfd;
	req.dst.vir_w = SRC_W;
	req.dst.vir_h = SRC_H;
	req.dst.act_w = SRC_W;
	req.dst.act_h = SRC_H;
	req.dst.format = RGA_FORMAT_YCbCr_420_SP;
	req.dst.rd_mode = RGA_RASTER_MODE;

	req.mmu_info.mmu_en = 1;
	req.mmu_info.mmu_flag = ((2 & 0x3) << 4) | 1;
	req.mmu_info.mmu_flag |= (1u << 31) | (1 << 10) | (1 << 8);
	req.core = core;

	ret = ioctl(fd, RGA_BLIT_SYNC, &req);
	printf("fd-mode core=0x%x src=%zub(vir_w=%u byte-stride) 10B->NV12 ret=%d errno=%d (%s)\n",
	       core, src_size, SRC_STRIDE_BYTES, ret, errno, ret ? strerror(errno) : "ok");
	close(fd);
	return ret ? 1 : 0;
}
