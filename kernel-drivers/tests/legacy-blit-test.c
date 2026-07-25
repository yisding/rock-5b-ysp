/* Minimal legacy RGA_BLIT_SYNC probe: virtual-address BITBLT copy.
 * Mirrors librga's legacy virtual convention: yrgb_addr = 0,
 * uv_addr = user virtual base, mmu_info enabled.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include "rga.h"

int main(int argc, char **argv)
{
	int dim = argc > 1 ? atoi(argv[1]) : 256;
	size_t size = (size_t)dim * dim * 4;
	void *src, *dst;
	struct rga_req req;
	int fd, ret;

	if (posix_memalign(&src, 4096, size) || posix_memalign(&dst, 4096, size)) {
		perror("alloc");
		return 2;
	}
	memset(src, 0x5a, size);
	memset(dst, 0, size);

	fd = open("/dev/rga", O_RDWR | O_CLOEXEC);
	if (fd < 0) {
		perror("open /dev/rga");
		return 2;
	}

	memset(&req, 0, sizeof(req));
	req.render_mode = 0; /* bitblt */

	req.src.yrgb_addr = 0;
	req.src.uv_addr = (uintptr_t)src;
	req.src.vir_w = dim;
	req.src.vir_h = dim;
	req.src.act_w = dim;
	req.src.act_h = dim;
	req.src.format = 0x0; /* RGA_FORMAT_RGBA_8888 */
	req.src.rd_mode = 1 << 0; /* raster */

	req.dst.yrgb_addr = 0;
	req.dst.uv_addr = (uintptr_t)dst;
	req.dst.vir_w = dim;
	req.dst.vir_h = dim;
	req.dst.act_w = dim;
	req.dst.act_h = dim;
	req.dst.format = 0x0;
	req.dst.rd_mode = 1 << 0;

	req.mmu_info.mmu_en = 1;
	req.mmu_info.mmu_flag = ((2 & 0x3) << 4) | 1;
	req.mmu_info.mmu_flag |= (1 << 31) | (1 << 10) | (1 << 8);

	errno = 0;
	ret = ioctl(fd, RGA_BLIT_SYNC, &req);
	printf("RGA_BLIT_SYNC dim=%d ret=%d errno=%d (%s)\n",
	       dim, ret, errno, strerror(errno));
	int content_ok = 1;
	if (ret == 0) {
		content_ok = memcmp(src, dst, size) == 0;
		printf("copy content %s\n", content_ok ? "match" : "MISMATCH");
	}

	close(fd);
	/*
	 * README.md states "pass = successful blit WITH content match", but the
	 * memcmp result was only printed. A blit that completed and wrote garbage --
	 * the silent-corruption class this whole 10-bit campaign chases -- exited 0.
	 */
	if (ret != 0)
		return 1;
	return content_ok ? 0 : 1;
}
