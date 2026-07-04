// SPDX-License-Identifier: MIT
/*
 * Small librga/im2d smoke test for whichever driver owns /dev/rga.
 *
 * This intentionally uses public librga APIs instead of raw ioctls: the point
 * is to validate the userspace contract consumed by ffmpeg-rockchip and normal
 * im2d clients.
 */

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#include <linux/dma-buf.h>
#include <linux/dma-heap.h>

#include <rga/im2d.h>
#include <rga/RgaApi.h>

#define TEST_SRC_W 64
#define TEST_SRC_H 64
#define TEST_DST_W 32
#define TEST_DST_H 32
#define TEST_BPP 4
#define RGA_TEST_FORMAT_P010 (0x40 << 8)
#define RGA_TEST_FORMAT_P210 (0x41 << 8)

struct dmabuf_test_buffer {
	int fd;
	uint8_t *mem;
	size_t size;
	const char *heap_path;
};

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

static int check_pattern(const uint8_t *buf, int width, int height)
{
	for (int y = 0; y < height; y++) {
		for (int x = 0; x < width; x++) {
			const uint8_t *px = buf + ((y * width + x) * TEST_BPP);
			uint8_t expected[TEST_BPP] = {
				(uint8_t)x,
				(uint8_t)y,
				(uint8_t)(x ^ y),
				0xff,
			};

			if (memcmp(px, expected, sizeof(expected))) {
				fprintf(stderr,
					"pixel %d,%d differs: got %02x:%02x:%02x:%02x expected %02x:%02x:%02x:%02x\n",
					x, y, px[0], px[1], px[2], px[3],
					expected[0], expected[1], expected[2],
					expected[3]);
				return 1;
			}
		}
	}

	return 0;
}

static bool env_enabled(const char *name)
{
	const char *value = getenv(name);

	return value && strcmp(value, "0") && strcmp(value, "false") &&
	       strcmp(value, "FALSE") && strcmp(value, "no") &&
	       strcmp(value, "NO");
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

static int dmabuf_sync(int fd, uint64_t flags, const char *name)
{
	struct dma_buf_sync sync = {};

	sync.flags = flags;
	if (ioctl(fd, DMA_BUF_IOCTL_SYNC, &sync)) {
		int err = errno;

		fprintf(stderr, "%s DMA_BUF_IOCTL_SYNC failed: %s\n",
			name, strerror(err));
		return -err;
	}

	return 0;
}

static int dmabuf_alloc_from_heap(const char *heap_path, size_t size,
				  struct dmabuf_test_buffer *buf)
{
	struct dma_heap_allocation_data data = {};
	int heap_fd;
	int ret;

	heap_fd = open(heap_path, O_RDWR | O_CLOEXEC);
	if (heap_fd < 0)
		return -errno;

	data.len = size;
	data.fd_flags = O_RDWR | O_CLOEXEC;
	ret = ioctl(heap_fd, DMA_HEAP_IOCTL_ALLOC, &data);
	if (ret)
		ret = -errno;
	close(heap_fd);
	if (ret)
		return ret;

	buf->mem = (uint8_t *)mmap(NULL, size, PROT_READ | PROT_WRITE,
				  MAP_SHARED, data.fd, 0);
	if (buf->mem == MAP_FAILED) {
		ret = -errno;
		close(data.fd);
		buf->mem = NULL;
		return ret;
	}

	buf->fd = data.fd;
	buf->size = size;
	buf->heap_path = heap_path;

	return 0;
}

static int dmabuf_alloc_any(size_t size, struct dmabuf_test_buffer *buf)
{
	static const char * const heap_paths[] = {
		"/dev/dma_heap/system-uncached-dma32",
		"/dev/dma_heap/system-dma32",
		"/dev/dma_heap/system-uncached",
		"/dev/dma_heap/system",
		"/dev/dma_heap/cma-uncached",
		"/dev/dma_heap/cma",
		"/dev/rk_dma_heap/rk-dma-heap-cma",
	};
	int first_err = 0;

	buf->fd = -1;
	buf->mem = NULL;
	buf->size = 0;
	buf->heap_path = NULL;

	for (size_t i = 0; i < sizeof(heap_paths) / sizeof(heap_paths[0]); i++) {
		int ret = dmabuf_alloc_from_heap(heap_paths[i], size, buf);

		if (!ret)
			return 0;
		if (!first_err || first_err == -ENOENT)
			first_err = ret;
	}

	return first_err ? first_err : -ENOENT;
}

static void dmabuf_free(struct dmabuf_test_buffer *buf)
{
	if (buf->mem)
		munmap(buf->mem, buf->size);
	if (buf->fd >= 0)
		close(buf->fd);

	buf->fd = -1;
	buf->mem = NULL;
	buf->size = 0;
	buf->heap_path = NULL;
}

static int dmabuf_fill_for_rga(struct dmabuf_test_buffer *src,
			       struct dmabuf_test_buffer *dst)
{
	int ret;

	ret = dmabuf_sync(src->fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_RW,
			  "dmabuf source start");
	if (ret)
		return ret;
	fill_pattern(src->mem, TEST_SRC_W, TEST_SRC_H);
	ret = dmabuf_sync(src->fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_RW,
			  "dmabuf source end");
	if (ret)
		return ret;

	ret = dmabuf_sync(dst->fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_RW,
			  "dmabuf dest start");
	if (ret)
		return ret;
	memset(dst->mem, 0xa5, dst->size);
	ret = dmabuf_sync(dst->fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_RW,
			  "dmabuf dest end");

	return ret;
}

static int run_dmabuf_copy(size_t src_size)
{
	struct dmabuf_test_buffer dma_src = {};
	struct dmabuf_test_buffer dma_dst = {};
	rga_buffer_handle_t src_handle = 0;
	rga_buffer_handle_t dst_handle = 0;
	rga_buffer_t src;
	rga_buffer_t dst;
	int ret;

	ret = dmabuf_alloc_any(src_size, &dma_src);
	if (ret) {
		fprintf(stderr, "dma-heap source allocation failed: %s\n",
			strerror(-ret));
		return 1;
	}

	ret = dmabuf_alloc_any(src_size, &dma_dst);
	if (ret) {
		fprintf(stderr, "dma-heap dest allocation failed: %s\n",
			strerror(-ret));
		ret = 1;
		goto out;
	}

	ret = dmabuf_fill_for_rga(&dma_src, &dma_dst);
	if (ret) {
		ret = 1;
		goto out;
	}

	src_handle = importbuffer_fd(dma_src.fd, src_size);
	dst_handle = importbuffer_fd(dma_dst.fd, src_size);
	if (!src_handle || !dst_handle) {
		fprintf(stderr, "importbuffer_fd failed: %s\n", imStrError());
		ret = 1;
		goto out;
	}

	src = wrapbuffer_handle(src_handle, TEST_SRC_W, TEST_SRC_H,
				RK_FORMAT_RGBA_8888);
	dst = wrapbuffer_handle(dst_handle, TEST_SRC_W, TEST_SRC_H,
				RK_FORMAT_RGBA_8888);

	ret = imcheck(src, dst, {}, {});
	if (ret != IM_STATUS_NOERROR) {
		ret = fail_status("imcheck dmabuf", ret);
		goto out;
	}

	ret = imcopy(src, dst);
	if (ret != IM_STATUS_SUCCESS) {
		ret = fail_status("imcopy dmabuf", ret);
		goto out;
	}

	ret = dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ,
			  "dmabuf dest read start");
	if (ret) {
		ret = 1;
		goto out;
	}
	if (check_pattern(dma_dst.mem, TEST_SRC_W, TEST_SRC_H)) {
		ret = 1;
		goto out_end_read;
	}

	ret = 0;

out_end_read:
	if (dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ,
			"dmabuf dest read end"))
		ret = 1;
	if (!ret)
		printf("%-24s ok heap=%s\n", "dmabuf imcopy",
		       dma_src.heap_path);

out:
	if (src_handle)
		releasebuffer_handle(src_handle);
	if (dst_handle)
		releasebuffer_handle(dst_handle);
	dmabuf_free(&dma_src);
	dmabuf_free(&dma_dst);

	return ret;
}

static void fill_bgrx_pattern(uint8_t *buf, int width, int height)
{
	for (int y = 0; y < height; y++) {
		for (int x = 0; x < width; x++) {
			uint8_t *px = buf + ((y * width + x) * TEST_BPP);

			px[0] = (uint8_t)(0x20 + x);
			px[1] = (uint8_t)(0x40 + y);
			px[2] = (uint8_t)(0x80 + (x ^ y));
			px[3] = 0xff;
		}
	}
}

static int buffer_changed_from_sentinel(const uint8_t *buf, size_t size,
					uint8_t sentinel)
{
	for (size_t i = 0; i < size; i++) {
		if (buf[i] != sentinel)
			return 1;
	}

	return 0;
}

static int nv12_changed_from_sentinel(const uint8_t *buf, size_t size)
{
	return buffer_changed_from_sentinel(buf, size, 0x80);
}

static void fill_nv12_pattern(uint8_t *buf, int width, int height)
{
	uint8_t *y_plane = buf;
	uint8_t *uv_plane = buf + ((size_t)width * height);

	for (int y = 0; y < height; y++) {
		for (int x = 0; x < width; x++)
			y_plane[(size_t)y * width + x] =
				(uint8_t)(0x20 + ((x * 3 + y * 5) & 0x7f));
	}

	for (int y = 0; y < height / 2; y++) {
		for (int x = 0; x < width; x += 2) {
			uv_plane[(size_t)y * width + x] =
				(uint8_t)(0x50 + ((x + y) & 0x1f));
			uv_plane[(size_t)y * width + x + 1] =
				(uint8_t)(0x90 + ((x * 2 + y) & 0x1f));
		}
	}
}

static void fill_i420_pattern(uint8_t *buf, int width, int height)
{
	size_t y_size = (size_t)width * height;
	size_t uv_size = y_size / 4;
	uint8_t *y_plane = buf;
	uint8_t *u_plane = y_plane + y_size;
	uint8_t *v_plane = u_plane + uv_size;

	for (int y = 0; y < height; y++) {
		for (int x = 0; x < width; x++)
			y_plane[(size_t)y * width + x] =
				(uint8_t)(0x10 + ((x + y * 2) & 0xbf));
	}

	for (int y = 0; y < height / 2; y++) {
		for (int x = 0; x < width / 2; x++) {
			u_plane[(size_t)y * (width / 2) + x] =
				(uint8_t)(0x60 + ((x * 3 + y) & 0x1f));
			v_plane[(size_t)y * (width / 2) + x] =
				(uint8_t)(0xa0 + ((x + y * 3) & 0x1f));
		}
	}
}

static void fill_p010_pattern(uint8_t *buf, int width, int height)
{
	uint16_t *y_plane = (uint16_t *)buf;
	uint16_t *uv_plane = y_plane + ((size_t)width * height);

	for (int y = 0; y < height; y++) {
		for (int x = 0; x < width; x++) {
			uint16_t sample =
				(uint16_t)((64 + x * 5 + y * 3) & 0x3ff);

			y_plane[(size_t)y * width + x] = sample << 6;
		}
	}

	for (int y = 0; y < height / 2; y++) {
		for (int x = 0; x < width; x += 2) {
			uv_plane[(size_t)y * width + x] =
				(uint16_t)((256 + x + y) & 0x3ff) << 6;
			uv_plane[(size_t)y * width + x + 1] =
				(uint16_t)((512 + x * 2 + y) & 0x3ff) << 6;
		}
	}
}

static void fill_p210_pattern(uint8_t *buf, int width, int height)
{
	uint16_t *y_plane = (uint16_t *)buf;
	uint16_t *uv_plane = y_plane + ((size_t)width * height);

	for (int y = 0; y < height; y++) {
		for (int x = 0; x < width; x++) {
			uint16_t sample =
				(uint16_t)((96 + x * 7 + y * 5) & 0x3ff);

			y_plane[(size_t)y * width + x] = sample << 6;
		}
	}

	for (int y = 0; y < height; y++) {
		for (int x = 0; x < width; x += 2) {
			uv_plane[(size_t)y * width + x] =
				(uint16_t)((320 + x + y * 2) & 0x3ff) << 6;
			uv_plane[(size_t)y * width + x + 1] =
				(uint16_t)((640 + x * 3 + y) & 0x3ff) << 6;
		}
	}
}

static int run_10bit_im2d_convert(const char *name, int src_format,
				  int dst_format, size_t src_size,
				  size_t dst_size,
				  void (*fill_src)(uint8_t *, int, int))
{
	const int width = 64;
	const int height = 64;
	struct dmabuf_test_buffer dma_src = {};
	struct dmabuf_test_buffer dma_dst = {};
	rga_buffer_handle_t src_handle = 0;
	rga_buffer_handle_t dst_handle = 0;
	rga_buffer_t src;
	rga_buffer_t dst;
	int ret;

	ret = dmabuf_alloc_any(src_size, &dma_src);
	if (ret) {
		fprintf(stderr, "%s source allocation failed: %s\n",
			name, strerror(-ret));
		return 1;
	}

	ret = dmabuf_alloc_any(dst_size, &dma_dst);
	if (ret) {
		fprintf(stderr, "%s dest allocation failed: %s\n",
			name, strerror(-ret));
		ret = 1;
		goto out;
	}

	ret = dmabuf_sync(dma_src.fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_RW,
			  "10-bit source start");
	if (ret) {
		ret = 1;
		goto out;
	}
	fill_src(dma_src.mem, width, height);
	ret = dmabuf_sync(dma_src.fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_RW,
			  "10-bit source end");
	if (ret) {
		ret = 1;
		goto out;
	}

	ret = dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_RW,
			  "10-bit dest start");
	if (ret) {
		ret = 1;
		goto out;
	}
	memset(dma_dst.mem, 0x80, dma_dst.size);
	ret = dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_RW,
			  "10-bit dest end");
	if (ret) {
		ret = 1;
		goto out;
	}

	src_handle = importbuffer_fd(dma_src.fd, src_size);
	dst_handle = importbuffer_fd(dma_dst.fd, dst_size);
	if (!src_handle || !dst_handle) {
		fprintf(stderr, "%s importbuffer_fd failed: %s\n",
			name, imStrError());
		ret = 1;
		goto out;
	}

	src = wrapbuffer_handle(src_handle, width, height, src_format);
	dst = wrapbuffer_handle(dst_handle, width, height, dst_format);

	ret = imcheck(src, dst, {}, {});
	if (ret != IM_STATUS_NOERROR) {
		ret = fail_status(name, ret);
		goto out;
	}

	ret = imcvtcolor(src, dst, src_format, dst_format);
	if (ret != IM_STATUS_SUCCESS) {
		ret = fail_status(name, ret);
		goto out;
	}

	ret = dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ,
			  "10-bit dest read start");
	if (ret) {
		ret = 1;
		goto out;
	}
	if (!buffer_changed_from_sentinel(dma_dst.mem, dma_dst.size, 0x80)) {
		fprintf(stderr, "%s output unchanged\n", name);
		ret = 1;
	} else {
		ret = 0;
	}
	if (dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ,
			"10-bit dest read end"))
		ret = 1;
	if (!ret)
		printf("%-24s ok heap=%s\n", name, dma_src.heap_path);

out:
	if (src_handle)
		releasebuffer_handle(src_handle);
	if (dst_handle)
		releasebuffer_handle(dst_handle);
	dmabuf_free(&dma_src);
	dmabuf_free(&dma_dst);

	return ret;
}

static int run_10bit_im2d_conversions(void)
{
	const int width = 64;
	const int height = 64;
	int ret;

	ret = run_10bit_im2d_convert("im2d P010->NV12",
				     RGA_TEST_FORMAT_P010,
				     RK_FORMAT_YCbCr_420_SP,
				     (size_t)width * height * 3,
				     (size_t)width * height * 3 / 2,
				     fill_p010_pattern);
	if (ret)
		return ret;

	return run_10bit_im2d_convert("im2d P210->NV16",
				      RGA_TEST_FORMAT_P210,
				      RK_FORMAT_YCbCr_422_SP,
				      (size_t)width * height * 4,
				      (size_t)width * height * 2,
				      fill_p210_pattern);
}

static int run_legacy_virtual_to_dmabuf_convert(void)
{
	const int src_w = 64;
	const int src_h = 64;
	const int dst_w = 32;
	const int dst_h = 32;
	const size_t src_size = (size_t)src_w * src_h * TEST_BPP;
	const size_t dst_size = (size_t)dst_w * dst_h * 3 / 2;
	struct dmabuf_test_buffer dma_dst = {};
	rga_info_t src = {};
	rga_info_t dst = {};
	uint8_t *src_mem = NULL;
	int ret;

	if (alloc_aligned((void **)&src_mem, src_size)) {
		perror("posix_memalign legacy source");
		return 1;
	}

	ret = dmabuf_alloc_any(dst_size, &dma_dst);
	if (ret) {
		fprintf(stderr, "legacy RGA dma-heap dest allocation failed: %s\n",
			strerror(-ret));
		ret = 1;
		goto out;
	}

	fill_bgrx_pattern(src_mem, src_w, src_h);

	ret = dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_RW,
			  "legacy RGA dest start");
	if (ret) {
		ret = 1;
		goto out;
	}
	memset(dma_dst.mem, 0x80, dma_dst.size);
	ret = dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_RW,
			  "legacy RGA dest end");
	if (ret) {
		ret = 1;
		goto out;
	}

	src.virAddr = src_mem;
	src.format = RK_FORMAT_BGRX_8888;
	src.mmuFlag = 1;
	rga_set_rect(&src.rect, 0, 0, src_w, src_h, src_w, src_h,
		     RK_FORMAT_BGRX_8888);

	dst.fd = dma_dst.fd;
	dst.format = RK_FORMAT_YCbCr_420_SP;
	dst.mmuFlag = 1;
	rga_set_rect(&dst.rect, 0, 0, dst_w, dst_h, dst_w, dst_h,
		     RK_FORMAT_YCbCr_420_SP);

	if (c_RkRgaInit()) {
		fprintf(stderr, "legacy RGA init failed\n");
		ret = 1;
		goto out;
	}

	if (c_RkRgaBlit(&src, &dst, NULL)) {
		fprintf(stderr, "legacy RGA virtual->dmabuf blit failed\n");
		c_RkRgaDeInit();
		ret = 1;
		goto out;
	}
	c_RkRgaDeInit();

	ret = dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ,
			  "legacy RGA dest read start");
	if (ret) {
		ret = 1;
		goto out;
	}
	if (!nv12_changed_from_sentinel(dma_dst.mem, dma_dst.size)) {
		fprintf(stderr, "legacy RGA virtual->dmabuf output unchanged\n");
		ret = 1;
	} else {
		ret = 0;
	}
	if (dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ,
			"legacy RGA dest read end"))
		ret = 1;
	if (!ret)
		printf("%-24s ok heap=%s\n", "legacy RGA BGRx->NV12",
		       dma_dst.heap_path);

out:
	dmabuf_free(&dma_dst);
	free(src_mem);

	return ret;
}

static int run_legacy_dmabuf_to_dmabuf_rotate_convert(void)
{
	const int src_w = 64;
	const int src_h = 32;
	const int dst_w = 32;
	const int dst_h = 64;
	const size_t src_size = (size_t)src_w * src_h * 3 / 2;
	const size_t dst_size = (size_t)dst_w * dst_h * TEST_BPP;
	struct dmabuf_test_buffer dma_src = {};
	struct dmabuf_test_buffer dma_dst = {};
	rga_info_t src = {};
	rga_info_t dst = {};
	int ret;

	ret = dmabuf_alloc_any(src_size, &dma_src);
	if (ret) {
		fprintf(stderr, "legacy RGA NV12 source allocation failed: %s\n",
			strerror(-ret));
		return 1;
	}

	ret = dmabuf_alloc_any(dst_size, &dma_dst);
	if (ret) {
		fprintf(stderr, "legacy RGA BGRx dest allocation failed: %s\n",
			strerror(-ret));
		ret = 1;
		goto out;
	}

	ret = dmabuf_sync(dma_src.fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_RW,
			  "legacy RGA NV12 source start");
	if (ret) {
		ret = 1;
		goto out;
	}
	fill_nv12_pattern(dma_src.mem, src_w, src_h);
	ret = dmabuf_sync(dma_src.fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_RW,
			  "legacy RGA NV12 source end");
	if (ret) {
		ret = 1;
		goto out;
	}

	ret = dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_RW,
			  "legacy RGA BGRx dest start");
	if (ret) {
		ret = 1;
		goto out;
	}
	memset(dma_dst.mem, 0x80, dma_dst.size);
	ret = dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_RW,
			  "legacy RGA BGRx dest end");
	if (ret) {
		ret = 1;
		goto out;
	}

	src.fd = dma_src.fd;
	src.format = RK_FORMAT_YCbCr_420_SP;
	src.rotation = HAL_TRANSFORM_ROT_90;
	src.mmuFlag = 1;
	rga_set_rect(&src.rect, 0, 0, src_w, src_h, src_w, src_h,
		     RK_FORMAT_YCbCr_420_SP);

	dst.fd = dma_dst.fd;
	dst.format = RK_FORMAT_BGRX_8888;
	dst.mmuFlag = 1;
	rga_set_rect(&dst.rect, 0, 0, dst_w, dst_h, dst_w, dst_h,
		     RK_FORMAT_BGRX_8888);

	if (c_RkRgaInit()) {
		fprintf(stderr, "legacy RGA init failed\n");
		ret = 1;
		goto out;
	}

	if (c_RkRgaBlit(&src, &dst, NULL)) {
		fprintf(stderr, "legacy RGA dmabuf rotate blit failed\n");
		c_RkRgaDeInit();
		ret = 1;
		goto out;
	}
	c_RkRgaDeInit();

	ret = dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ,
			  "legacy RGA BGRx dest read start");
	if (ret) {
		ret = 1;
		goto out;
	}
	if (!nv12_changed_from_sentinel(dma_dst.mem, dma_dst.size)) {
		fprintf(stderr, "legacy RGA dmabuf rotate output unchanged\n");
		ret = 1;
	} else {
		ret = 0;
	}
	if (dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ,
			"legacy RGA BGRx dest read end"))
		ret = 1;
	if (!ret)
		printf("%-24s ok heap=%s\n", "legacy RGA NV12->BGRx",
		       dma_dst.heap_path);

out:
	dmabuf_free(&dma_src);
	dmabuf_free(&dma_dst);

	return ret;
}

static int run_legacy_planar_to_semiplanar_convert(void)
{
	const int width = 64;
	const int height = 64;
	const size_t image_size = (size_t)width * height * 3 / 2;
	struct dmabuf_test_buffer dma_src = {};
	struct dmabuf_test_buffer dma_dst = {};
	rga_info_t src = {};
	rga_info_t dst = {};
	int ret;

	ret = dmabuf_alloc_any(image_size, &dma_src);
	if (ret) {
		fprintf(stderr, "legacy RGA I420 source allocation failed: %s\n",
			strerror(-ret));
		return 1;
	}

	ret = dmabuf_alloc_any(image_size, &dma_dst);
	if (ret) {
		fprintf(stderr, "legacy RGA NV12 dest allocation failed: %s\n",
			strerror(-ret));
		ret = 1;
		goto out;
	}

	ret = dmabuf_sync(dma_src.fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_RW,
			  "legacy RGA I420 source start");
	if (ret) {
		ret = 1;
		goto out;
	}
	fill_i420_pattern(dma_src.mem, width, height);
	ret = dmabuf_sync(dma_src.fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_RW,
			  "legacy RGA I420 source end");
	if (ret) {
		ret = 1;
		goto out;
	}

	ret = dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_RW,
			  "legacy RGA NV12 dest start");
	if (ret) {
		ret = 1;
		goto out;
	}
	memset(dma_dst.mem, 0x80, dma_dst.size);
	ret = dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_RW,
			  "legacy RGA NV12 dest end");
	if (ret) {
		ret = 1;
		goto out;
	}

	src.fd = dma_src.fd;
	src.format = RK_FORMAT_YCbCr_420_P;
	src.mmuFlag = 1;
	rga_set_rect(&src.rect, 0, 0, width, height, width, height,
		     RK_FORMAT_YCbCr_420_P);

	dst.fd = dma_dst.fd;
	dst.format = RK_FORMAT_YCbCr_420_SP;
	dst.mmuFlag = 1;
	rga_set_rect(&dst.rect, 0, 0, width, height, width, height,
		     RK_FORMAT_YCbCr_420_SP);

	if (c_RkRgaInit()) {
		fprintf(stderr, "legacy RGA init failed\n");
		ret = 1;
		goto out;
	}

	if (c_RkRgaBlit(&src, &dst, NULL)) {
		fprintf(stderr, "legacy RGA planar blit failed\n");
		c_RkRgaDeInit();
		ret = 1;
		goto out;
	}
	c_RkRgaDeInit();

	ret = dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ,
			  "legacy RGA NV12 dest read start");
	if (ret) {
		ret = 1;
		goto out;
	}
	if (!nv12_changed_from_sentinel(dma_dst.mem, dma_dst.size)) {
		fprintf(stderr, "legacy RGA planar output unchanged\n");
		ret = 1;
	} else {
		ret = 0;
	}
	if (dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ,
			"legacy RGA NV12 dest read end"))
		ret = 1;
	if (!ret)
		printf("%-24s ok heap=%s\n", "legacy RGA I420->NV12",
		       dma_dst.heap_path);

out:
	dmabuf_free(&dma_src);
	dmabuf_free(&dma_dst);

	return ret;
}

static int run_gauss_matrix_improcess(void)
{
	const int width = 64;
	const int height = 64;
	const int format = RK_FORMAT_RGBA_8888;
	const size_t image_size = (size_t)width * height * TEST_BPP;
	struct dmabuf_test_buffer dma_src = {};
	struct dmabuf_test_buffer dma_dst = {};
	rga_buffer_handle_t src_handle = 0;
	rga_buffer_handle_t dst_handle = 0;
	rga_buffer_t src;
	rga_buffer_t dst;
	im_handle_param_t src_param = {
		(uint32_t)width,
		(uint32_t)height,
		(uint32_t)format,
	};
	im_handle_param_t dst_param = {
		(uint32_t)width,
		(uint32_t)height,
		(uint32_t)format,
	};
	im_opt_t opt = {};
	double gauss_matrix[9] = {
		0.075114, 0.123841, 0.075114,
		0.123841, 0.204180, 0.123841,
		0.075114, 0.123841, 0.075114,
	};
	int ret;

	ret = dmabuf_alloc_any(image_size, &dma_src);
	if (ret) {
		fprintf(stderr, "gauss source allocation failed: %s\n",
			strerror(-ret));
		return 1;
	}

	ret = dmabuf_alloc_any(image_size, &dma_dst);
	if (ret) {
		fprintf(stderr, "gauss dest allocation failed: %s\n",
			strerror(-ret));
		ret = 1;
		goto out;
	}

	ret = dmabuf_sync(dma_src.fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_RW,
			  "gauss source start");
	if (ret) {
		ret = 1;
		goto out;
	}
	fill_pattern(dma_src.mem, width, height);
	ret = dmabuf_sync(dma_src.fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_RW,
			  "gauss source end");
	if (ret) {
		ret = 1;
		goto out;
	}

	ret = dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_RW,
			  "gauss dest start");
	if (ret) {
		ret = 1;
		goto out;
	}
	memset(dma_dst.mem, 0x80, dma_dst.size);
	ret = dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_RW,
			  "gauss dest end");
	if (ret) {
		ret = 1;
		goto out;
	}

	src_handle = importbuffer_fd(dma_src.fd, &src_param);
	dst_handle = importbuffer_fd(dma_dst.fd, &dst_param);
	if (!src_handle || !dst_handle) {
		fprintf(stderr, "gauss importbuffer_fd failed: %s\n",
			imStrError());
		ret = 1;
		goto out;
	}

	src = wrapbuffer_handle(src_handle, width, height, format);
	dst = wrapbuffer_handle(dst_handle, width, height, format);

	ret = imcheck(src, dst, {}, {});
	if (ret != IM_STATUS_NOERROR) {
		ret = fail_status("imcheck gauss", ret);
		goto out;
	}

	imsetOptGaussianBlurMatrix(&opt, 3, 3, gauss_matrix);
	imsetOpacity(&src, 0xfe);

	ret = improcess(src, dst, {}, {}, {}, {}, -1, NULL, &opt,
			IM_SYNC | IM_GAUSS);
	if (ret != IM_STATUS_SUCCESS) {
		ret = fail_status("improcess gauss", ret);
		goto out;
	}

	ret = dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ,
			  "gauss dest read start");
	if (ret) {
		ret = 1;
		goto out;
	}
	if (!buffer_changed_from_sentinel(dma_dst.mem, dma_dst.size, 0x80)) {
		fprintf(stderr, "gauss output unchanged\n");
		ret = 1;
	} else {
		ret = 0;
	}
	if (dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ,
			"gauss dest read end"))
		ret = 1;
	if (!ret)
		printf("%-24s ok heap=%s\n", "improcess gauss",
		       dma_src.heap_path);

out:
	if (src_handle)
		releasebuffer_handle(src_handle);
	if (dst_handle)
		releasebuffer_handle(dst_handle);
	dmabuf_free(&dma_src);
	dmabuf_free(&dma_dst);

	return ret;
}

int main(void)
{
	const size_t src_size = TEST_SRC_W * TEST_SRC_H * TEST_BPP;
	const size_t dst_size = TEST_DST_W * TEST_DST_H * TEST_BPP;
	rga_buffer_handle_t src_handle = 0;
	rga_buffer_handle_t dst_handle = 0;
	rga_buffer_handle_t tmp_handle = 0;
	rga_buffer_handle_t fill_handle = 0;
	uint8_t *src_mem = NULL;
	uint8_t *dst_mem = NULL;
	uint8_t *tmp_mem = NULL;
	uint8_t *fill_mem = NULL;
	rga_buffer_t src;
	rga_buffer_t dst;
	rga_buffer_t tmp;
	rga_buffer_t fill;
	im_rect fill_rect = {};
	im_opt_t opt = {};
	int first_fence = -1;
	int second_fence = -1;
	int ret;

	ret = imcheckHeader();
	if (ret != IM_STATUS_NOERROR)
		return fail_status("imcheckHeader", ret);

	printf("%-24s %s\n", "querystring(RGA_VERSION)",
	       querystring(RGA_VERSION));

	if (alloc_aligned((void **)&src_mem, src_size) ||
	    alloc_aligned((void **)&dst_mem, src_size) ||
	    alloc_aligned((void **)&tmp_mem, src_size) ||
	    alloc_aligned((void **)&fill_mem, dst_size)) {
		perror("posix_memalign");
		ret = 1;
		goto out;
	}
	fill_pattern(src_mem, TEST_SRC_W, TEST_SRC_H);
	memset(dst_mem, 0x80, src_size);
	memset(tmp_mem, 0x40, src_size);
	memset(fill_mem, 0x33, dst_size);

	src_handle = importbuffer_virtualaddr(src_mem, src_size);
	dst_handle = importbuffer_virtualaddr(dst_mem, src_size);
	tmp_handle = importbuffer_virtualaddr(tmp_mem, src_size);
	fill_handle = importbuffer_virtualaddr(fill_mem, dst_size);
	if (!src_handle || !dst_handle || !tmp_handle || !fill_handle) {
		fprintf(stderr, "importbuffer_virtualaddr failed\n");
		ret = 1;
		goto out;
	}

	src = wrapbuffer_handle(src_handle, TEST_SRC_W, TEST_SRC_H,
				RK_FORMAT_RGBA_8888);
	dst = wrapbuffer_handle(dst_handle, TEST_SRC_W, TEST_SRC_H,
				RK_FORMAT_RGBA_8888);
	tmp = wrapbuffer_handle(tmp_handle, TEST_SRC_W, TEST_SRC_H,
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

	ret = run_dmabuf_copy(src_size);
	if (ret)
		goto out;

	ret = run_legacy_virtual_to_dmabuf_convert();
	if (ret)
		goto out;

	ret = run_legacy_dmabuf_to_dmabuf_rotate_convert();
	if (ret)
		goto out;

	ret = run_legacy_planar_to_semiplanar_convert();
	if (ret)
		goto out;

	ret = run_gauss_matrix_improcess();
	if (ret)
		goto out;

	if (env_enabled("LIBRGA_SMOKE_10BIT")) {
		ret = run_10bit_im2d_conversions();
		if (ret)
			goto out;
	} else {
		printf("%-24s skip set LIBRGA_SMOKE_10BIT=1\n",
		       "im2d P010/P210");
	}

	memset(dst_mem, 0x80, src_size);
	opt.core = IM_SCHEDULER_RGA3_CORE0 | IM_SCHEDULER_RGA3_CORE1;
	opt.priority = 3;
	ret = improcess(src, dst, {}, {}, {}, {}, -1, NULL, &opt, IM_SYNC);
	if (ret != IM_STATUS_SUCCESS) {
		ret = fail_status("improcess forced-core", ret);
		goto out;
	}
	if (memcmp(src_mem, dst_mem, src_size)) {
		fprintf(stderr, "forced-core output differs from source\n");
		ret = 1;
		goto out;
	}
	printf("%-24s ok\n", "forced RGA3 copy");

	opt = {};
	memset(dst_mem, 0x80, src_size);
	opt.core = IM_SCHEDULER_RGA2_CORE0;
	opt.intr_config.flags = IM_INTR_READ_INTR | IM_INTR_WRITE_INTR;
	opt.intr_config.read_threshold = TEST_SRC_H / 2;
	opt.intr_config.write_start = 1;
	opt.intr_config.write_step = 1;
	ret = improcess(src, dst, {}, {}, {}, {}, -1, NULL, &opt,
			IM_SYNC | IM_PRE_INTR);
	if (ret != IM_STATUS_SUCCESS) {
		ret = fail_status("improcess pre-intr", ret);
		goto out;
	}
	if (memcmp(src_mem, dst_mem, src_size)) {
		fprintf(stderr, "pre-intr output differs from source\n");
		ret = 1;
		goto out;
	}
	printf("%-24s ok\n", "RGA2 pre-intr copy");

	memset(tmp_mem, 0x40, src_size);
	memset(dst_mem, 0x80, src_size);
	ret = imcopy(src, tmp, 0, &first_fence);
	if (ret != IM_STATUS_SUCCESS) {
		ret = fail_status("imcopy async", ret);
		goto out;
	}
	if (first_fence < 0) {
		fprintf(stderr, "imcopy async did not return a release fence\n");
		ret = 1;
		goto out;
	}
	ret = improcess(tmp, dst, {}, {}, {}, {}, first_fence, &second_fence,
			NULL, IM_ASYNC);
	first_fence = -1;
	if (ret != IM_STATUS_SUCCESS) {
		ret = fail_status("improcess async", ret);
		goto out;
	}
	if (second_fence < 0) {
		fprintf(stderr, "improcess async did not return a release fence\n");
		ret = 1;
		goto out;
	}
	ret = imsync(second_fence);
	second_fence = -1;
	if (ret != IM_STATUS_SUCCESS) {
		ret = fail_status("imsync", ret);
		goto out;
	}
	if (memcmp(src_mem, dst_mem, src_size)) {
		fprintf(stderr, "async fence-chain output differs from source\n");
		ret = 1;
		goto out;
	}
	printf("%-24s ok\n", "async fence chain");

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
	if (first_fence >= 0)
		close(first_fence);
	if (second_fence >= 0)
		close(second_fence);
	if (src_handle)
		releasebuffer_handle(src_handle);
	if (dst_handle)
		releasebuffer_handle(dst_handle);
	if (tmp_handle)
		releasebuffer_handle(tmp_handle);
	if (fill_handle)
		releasebuffer_handle(fill_handle);
	free(src_mem);
	free(dst_mem);
	free(tmp_mem);
	free(fill_mem);

	return ret;
}
