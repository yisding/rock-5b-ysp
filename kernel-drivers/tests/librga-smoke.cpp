// SPDX-License-Identifier: MIT
/*
 * Small librga/im2d smoke test for whichever driver owns /dev/rga.
 *
 * This intentionally uses public librga APIs instead of raw ioctls: the point
 * is to validate the userspace contract consumed by ffmpeg-rockchip and normal
 * im2d clients.
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <rga/im2d.h>

#define TEST_SRC_W 64
#define TEST_SRC_H 64
#define TEST_DST_W 32
#define TEST_DST_H 32
#define TEST_BPP 4

static int fail_status(const char *name, int ret)
{
	printf("%-24s failed: %s (%d)\n", name, imStrError((IM_STATUS)ret), ret);
	return 1;
}

static void fill_pattern(uint8_t *buf, int width, int height)
{
	for (int y = 0; y < height; y++) {
		for (int x = 0; x < width; x++) {
			uint8_t *px = buf + ((y * width + x) * TEST_BPP);

			px[0] = (uint8_t)x;
			px[1] = (uint8_t)y;
			px[2] = (uint8_t)(x ^ y);
			px[3] = 0xff;
		}
	}
}

static int alloc_aligned(void **ptr, size_t size)
{
	int ret;

	ret = posix_memalign(ptr, 4096, size);
	if (ret)
		return -ret;
	memset(*ptr, 0, size);

	return 0;
}

int main(void)
{
	const size_t src_size = TEST_SRC_W * TEST_SRC_H * TEST_BPP;
	const size_t dst_size = TEST_DST_W * TEST_DST_H * TEST_BPP;
	rga_buffer_handle_t src_handle = 0;
	rga_buffer_handle_t dst_handle = 0;
	rga_buffer_handle_t fill_handle = 0;
	uint8_t *src_mem = NULL;
	uint8_t *dst_mem = NULL;
	uint8_t *fill_mem = NULL;
	rga_buffer_t src;
	rga_buffer_t dst;
	rga_buffer_t fill;
	im_rect fill_rect = {};
	int ret;

	ret = imcheckHeader();
	if (ret != IM_STATUS_NOERROR)
		return fail_status("imcheckHeader", ret);

	printf("%-24s %s\n", "querystring(RGA_VERSION)",
	       querystring(RGA_VERSION));

	if (alloc_aligned((void **)&src_mem, src_size) ||
	    alloc_aligned((void **)&dst_mem, src_size) ||
	    alloc_aligned((void **)&fill_mem, dst_size)) {
		perror("posix_memalign");
		ret = 1;
		goto out;
	}
	fill_pattern(src_mem, TEST_SRC_W, TEST_SRC_H);
	memset(dst_mem, 0x80, src_size);
	memset(fill_mem, 0x33, dst_size);

	src_handle = importbuffer_virtualaddr(src_mem, src_size);
	dst_handle = importbuffer_virtualaddr(dst_mem, src_size);
	fill_handle = importbuffer_virtualaddr(fill_mem, dst_size);
	if (!src_handle || !dst_handle || !fill_handle) {
		fprintf(stderr, "importbuffer_virtualaddr failed\n");
		ret = 1;
		goto out;
	}

	src = wrapbuffer_handle(src_handle, TEST_SRC_W, TEST_SRC_H,
				RK_FORMAT_RGBA_8888);
	dst = wrapbuffer_handle(dst_handle, TEST_SRC_W, TEST_SRC_H,
				RK_FORMAT_RGBA_8888);
	fill = wrapbuffer_handle(fill_handle, TEST_DST_W, TEST_DST_H,
				 RK_FORMAT_RGBA_8888);

	ret = imcheck(src, dst, {}, {});
	if (ret != IM_STATUS_NOERROR) {
		ret = fail_status("imcheck copy", ret);
		goto out;
	}
	ret = imcopy(src, dst);
	if (ret != IM_STATUS_SUCCESS) {
		ret = fail_status("imcopy", ret);
		goto out;
	}
	if (memcmp(src_mem, dst_mem, src_size)) {
		fprintf(stderr, "imcopy output differs from source\n");
		ret = 1;
		goto out;
	}
	printf("%-24s ok\n", "imcopy");

	dst = wrapbuffer_handle(dst_handle, TEST_DST_W, TEST_DST_H,
				RK_FORMAT_RGBA_8888);
	ret = imcheck(src, dst, {}, {});
	if (ret != IM_STATUS_NOERROR) {
		ret = fail_status("imcheck resize", ret);
		goto out;
	}
	ret = imresize(src, dst);
	if (ret != IM_STATUS_SUCCESS) {
		ret = fail_status("imresize", ret);
		goto out;
	}
	printf("%-24s ok first=%02x:%02x:%02x:%02x\n", "imresize",
	       dst_mem[0], dst_mem[1], dst_mem[2], dst_mem[3]);

	fill_rect.x = 0;
	fill_rect.y = 0;
	fill_rect.width = TEST_DST_W;
	fill_rect.height = TEST_DST_H;
	ret = imcheck({}, fill, {}, fill_rect, IM_COLOR_FILL);
	if (ret != IM_STATUS_NOERROR) {
		ret = fail_status("imcheck fill", ret);
		goto out;
	}
	ret = imfill(fill, fill_rect, 0xff00ff00);
	if (ret != IM_STATUS_SUCCESS) {
		ret = fail_status("imfill", ret);
		goto out;
	}
	printf("%-24s ok first=%02x:%02x:%02x:%02x\n", "imfill",
	       fill_mem[0], fill_mem[1], fill_mem[2], fill_mem[3]);

	ret = 0;

out:
	if (src_handle)
		releasebuffer_handle(src_handle);
	if (dst_handle)
		releasebuffer_handle(dst_handle);
	if (fill_handle)
		releasebuffer_handle(fill_handle);
	free(src_mem);
	free(dst_mem);
	free(fill_mem);

	return ret;
}
