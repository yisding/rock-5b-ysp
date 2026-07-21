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
#include <limits.h>
#include <ctype.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <linux/dma-buf.h>
#include <linux/dma-heap.h>

#if __has_include(<rga/im2d.h>)
#include <rga/im2d.h>
#include <rga/im2d_task.h>
#include <rga/RgaApi.h>
#else
#include <im2d.h>
#include <im2d_task.h>
#include <RgaApi.h>
#endif

#ifndef IM_JOB_FLAGS_EXEC_SEQUENTIAL
#define IM_JOB_FLAGS_EXEC_SEQUENTIAL ((uint32_t)(1 << 6))
#endif

/*
 * RGA3's raster input and output ranges start at 68 pixels wide. Anything
 * smaller is RGA2-only, and RGA2 only accepts below-4G memory — so a
 * sub-68-wide case with malloc-backed virtual imports on a large-memory
 * board fails core assignment ("no core match") whenever the pages land
 * above 4G. Keep both surfaces at/above the RGA3 minimum so every case has
 * an IOMMU-backed core available regardless of physical placement.
 */
#define TEST_SRC_W 128
#define TEST_SRC_H 128
#define TEST_DST_W 96
#define TEST_DST_H 96
#define TEST_BPP 4
#define RGA_TEST_FORMAT_P010 (0x40 << 8)
#define RGA_TEST_FORMAT_P210 (0x41 << 8)

static const char *artifact_dir;

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

static int check_rgba_crop(const uint8_t *dst, int crop_x, int crop_y,
			   int crop_w, int crop_h)
{
	for (int y = 0; y < crop_h; y++) {
		for (int x = 0; x < crop_w; x++) {
			const uint8_t *dst_px =
				dst + ((y * crop_w + x) * TEST_BPP);
			uint8_t expected[TEST_BPP] = {
				(uint8_t)(crop_x + x),
				(uint8_t)(crop_y + y),
				(uint8_t)((crop_x + x) ^ (crop_y + y)),
				0xff,
			};

			if (memcmp(expected, dst_px, TEST_BPP)) {
				fprintf(stderr,
					"crop pixel %d,%d differs: got %02x:%02x:%02x:%02x expected %02x:%02x:%02x:%02x\n",
					x, y, dst_px[0], dst_px[1],
					dst_px[2], dst_px[3], expected[0],
					expected[1], expected[2],
					expected[3]);
				return 1;
			}
		}
	}

	return 0;
}

static int check_rgba_flip(const uint8_t *dst, int width, int height,
			   bool flip_h, bool flip_v)
{
	for (int y = 0; y < height; y++) {
		for (int x = 0; x < width; x++) {
			int src_x = flip_h ? width - 1 - x : x;
			int src_y = flip_v ? height - 1 - y : y;
			const uint8_t *dst_px =
				dst + ((y * width + x) * TEST_BPP);
			uint8_t expected[TEST_BPP] = {
				(uint8_t)src_x,
				(uint8_t)src_y,
				(uint8_t)(src_x ^ src_y),
				0xff,
			};

			if (memcmp(expected, dst_px, TEST_BPP)) {
				fprintf(stderr,
					"flip pixel %d,%d differs: got %02x:%02x:%02x:%02x expected %02x:%02x:%02x:%02x\n",
					x, y, dst_px[0], dst_px[1],
					dst_px[2], dst_px[3], expected[0],
					expected[1], expected[2],
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

static int ensure_artifact_dir(void)
{
	if (!artifact_dir || !artifact_dir[0])
		return 0;

	if (mkdir(artifact_dir, 0755) && errno != EEXIST) {
		fprintf(stderr, "failed to create artifact dir %s: %s\n",
			artifact_dir, strerror(errno));
		return 1;
	}

	return 0;
}

static int write_artifact(const char *name, const void *buf, size_t size)
{
	char safe[128];
	char path[PATH_MAX];
	FILE *file;
	size_t i;

	if (!artifact_dir || !artifact_dir[0])
		return 0;

	for (i = 0; name[i] && i < sizeof(safe) - 1; i++) {
		unsigned char ch = (unsigned char)name[i];

		safe[i] = (isalnum(ch) || ch == '_' || ch == '.' || ch == '-') ?
			  (char)ch : '_';
	}
	safe[i] = '\0';

	if (snprintf(path, sizeof(path), "%s/%s.bin", artifact_dir, safe) >=
	    (int)sizeof(path)) {
		fprintf(stderr, "artifact path too long for %s\n", name);
		return 1;
	}

	file = fopen(path, "wb");
	if (!file) {
		fprintf(stderr, "failed to open artifact %s: %s\n",
			path, strerror(errno));
		return 1;
	}

	if (fwrite(buf, 1, size, file) != size) {
		fprintf(stderr, "failed to write artifact %s: %s\n",
			path, ferror(file) ? strerror(errno) : "short write");
		fclose(file);
		return 1;
	}

	if (fclose(file)) {
		fprintf(stderr, "failed to close artifact %s: %s\n",
			path, strerror(errno));
		return 1;
	}

	printf("%-24s artifact=%s bytes=%zu\n", name, path, size);
	return 0;
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
		/*
		 * Upstream-style kernels expose no dma32 heaps. Prefer the
		 * upstream CMA heap over the system heap: RGA2-only jobs
		 * (below RGA3's 68-pixel minimum input width) need below-4G
		 * memory, and a system-heap allocation only lands there by
		 * luck on a large-memory board.
		 */
		"/dev/dma_heap/default_cma_region",
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
	if (write_artifact("dmabuf_imcopy_rgba", dma_dst.mem, src_size)) {
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

static void fill_rgb565_pattern(uint8_t *buf, int width, int height)
{
	for (int y = 0; y < height; y++) {
		for (int x = 0; x < width; x++) {
			uint8_t r = (uint8_t)((x * 3) & 0x1f);
			uint8_t g = (uint8_t)((y * 5) & 0x3f);
			uint8_t b = (uint8_t)((x ^ y) & 0x1f);
			uint16_t pixel = (uint16_t)((r << 11) | (g << 5) | b);
			uint8_t *px = buf + (((size_t)y * width + x) * 2);

			px[0] = (uint8_t)(pixel & 0xff);
			px[1] = (uint8_t)(pixel >> 8);
		}
	}
}

static void fill_bgra_alpha_pattern(uint8_t *buf, int width, int height)
{
	for (int y = 0; y < height; y++) {
		for (int x = 0; x < width; x++) {
			uint8_t *px = buf + ((y * width + x) * TEST_BPP);

			px[0] = (uint8_t)(0x10 + (x & 0x3f));
			px[1] = (uint8_t)(0x20 + (y & 0x3f));
			px[2] = (uint8_t)(0x30 + ((x ^ y) & 0x3f));
			px[3] = 0x80;
		}
	}
}

static void fill_rgb_pattern(uint8_t *buf, int width, int height)
{
	for (int y = 0; y < height; y++) {
		for (int x = 0; x < width; x++) {
			uint8_t *px = buf + ((size_t)y * width + x) * 3;

			px[0] = (uint8_t)(0x40 + x);
			px[1] = (uint8_t)(0x20 + y);
			px[2] = (uint8_t)(0x80 + (x ^ y));
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

static int check_partial_rect_update(const uint8_t *buf, int width, int height,
				     const im_rect *rect, uint8_t sentinel,
				     const char *name)
{
	bool changed_inside = false;

	for (int y = 0; y < height; y++) {
		for (int x = 0; x < width; x++) {
			const uint8_t *px = buf + ((y * width + x) * TEST_BPP);
			bool in_rect = x >= rect->x &&
				       x < rect->x + rect->width &&
				       y >= rect->y &&
				       y < rect->y + rect->height;
			bool pixel_changed = false;

			for (int i = 0; i < TEST_BPP; i++) {
				if (px[i] != sentinel) {
					pixel_changed = true;
					break;
				}
			}

			if (in_rect) {
				changed_inside |= pixel_changed;
			} else if (pixel_changed) {
				fprintf(stderr,
					"%s changed outside target rect at %d,%d: %02x:%02x:%02x:%02x\n",
					name, x, y, px[0], px[1], px[2],
					px[3]);
				return 1;
			}
		}
	}

	if (!changed_inside) {
		fprintf(stderr, "%s target rect unchanged\n", name);
		return 1;
	}

	return 0;
}

static int check_rectangle_border_update(const uint8_t *buf, int width,
					 int height, const im_rect *rect,
					 int thickness, uint8_t sentinel)
{
	for (int y = 0; y < height; y++) {
		for (int x = 0; x < width; x++) {
			const uint8_t *px = buf + ((y * width + x) * TEST_BPP);
			bool in_rect = x >= rect->x &&
				       x < rect->x + rect->width &&
				       y >= rect->y &&
				       y < rect->y + rect->height;
			bool in_border = in_rect &&
					 (x < rect->x + thickness ||
					  x >= rect->x + rect->width - thickness ||
					  y < rect->y + thickness ||
					  y >= rect->y + rect->height - thickness);
			bool changed = false;

			for (int i = 0; i < TEST_BPP; i++)
				changed |= px[i] != sentinel;

			if (in_border) {
				if (!changed) {
					fprintf(stderr,
						"rectangle border pixel %d,%d unchanged\n",
						x, y);
					return 1;
				}
			} else if (changed) {
				fprintf(stderr,
					"rectangle non-border pixel %d,%d changed: %02x:%02x:%02x:%02x\n",
					x, y, px[0], px[1], px[2], px[3]);
				return 1;
			}
		}
	}

	return 0;
}

static bool rect_border_contains(const im_rect *rect, int x, int y,
				 int thickness)
{
	return x >= rect->x && x < rect->x + rect->width &&
	       y >= rect->y && y < rect->y + rect->height &&
	       (x < rect->x + thickness ||
		x >= rect->x + rect->width - thickness ||
		y < rect->y + thickness ||
		y >= rect->y + rect->height - thickness);
}

static int check_rectangle_array_border_update(const uint8_t *buf, int width,
					       int height,
					       const im_rect *rects,
					       size_t rect_count,
					       int thickness,
					       uint8_t sentinel)
{
	for (int y = 0; y < height; y++) {
		for (int x = 0; x < width; x++) {
			const uint8_t *px = buf + ((y * width + x) * TEST_BPP);
			bool expected = false;
			bool changed = false;

			for (size_t i = 0; i < rect_count; i++)
				expected |= rect_border_contains(&rects[i], x, y,
								thickness);
			for (int i = 0; i < TEST_BPP; i++)
				changed |= px[i] != sentinel;

			if (expected) {
				if (!changed) {
					fprintf(stderr,
						"rectangle-array border pixel %d,%d unchanged\n",
						x, y);
					return 1;
				}
			} else if (changed) {
				fprintf(stderr,
					"rectangle-array non-border pixel %d,%d changed: %02x:%02x:%02x:%02x\n",
					x, y, px[0], px[1], px[2], px[3]);
				return 1;
			}
		}
	}

	return 0;
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

static void fill_nv21_pattern(uint8_t *buf, int width, int height)
{
	uint8_t *y_plane = buf;
	uint8_t *vu_plane = buf + ((size_t)width * height);

	for (int y = 0; y < height; y++) {
		for (int x = 0; x < width; x++)
			y_plane[(size_t)y * width + x] =
				(uint8_t)(0x28 + ((x * 5 + y * 3) & 0x7f));
	}

	for (int y = 0; y < height / 2; y++) {
		for (int x = 0; x < width; x += 2) {
			vu_plane[(size_t)y * width + x] =
				(uint8_t)(0xa0 + ((x + y * 2) & 0x1f));
			vu_plane[(size_t)y * width + x + 1] =
				(uint8_t)(0x50 + ((x * 3 + y) & 0x1f));
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
	const int width = 256;
	const int height = 256;
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
		ret = write_artifact(name, dma_dst.mem, dma_dst.size);
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
	const int width = 256;
	const int height = 256;
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

static int run_rknn_virtual_rgb_resize(void)
{
	const int src_w = 256;
	const int src_h = 256;
	const int dst_w = 128;
	const int dst_h = 128;
	const size_t src_size = (size_t)src_w * src_h * 3;
	const size_t dst_size = (size_t)dst_w * dst_h * 3;
	rga_buffer_handle_t src_handle = 0;
	rga_buffer_handle_t dst_handle = 0;
	rga_buffer_t src;
	rga_buffer_t dst;
	uint8_t *src_mem = NULL;
	uint8_t *dst_mem = NULL;
	int ret;

	if (alloc_aligned((void **)&src_mem, src_size) ||
	    alloc_aligned((void **)&dst_mem, dst_size)) {
		perror("posix_memalign rknn virtual RGB");
		ret = 1;
		goto out;
	}

	fill_rgb_pattern(src_mem, src_w, src_h);
	memset(dst_mem, 0x80, dst_size);

	src_handle = importbuffer_virtualaddr(src_mem, src_size);
	dst_handle = importbuffer_virtualaddr(dst_mem, dst_size);
	if (!src_handle || !dst_handle) {
		fprintf(stderr, "RKNN virtual RGB import failed: %s\n",
			imStrError());
		ret = 1;
		goto out;
	}

	src = wrapbuffer_handle(src_handle, src_w, src_h, RK_FORMAT_RGB_888);
	dst = wrapbuffer_handle(dst_handle, dst_w, dst_h, RK_FORMAT_RGB_888);

	ret = imcheck(src, dst, {}, {});
	if (ret != IM_STATUS_NOERROR) {
		ret = fail_status("rknn rgb imcheck", ret);
		goto out;
	}

	ret = imresize(src, dst);
	if (ret != IM_STATUS_SUCCESS) {
		ret = fail_status("rknn rgb resize", ret);
		goto out;
	}

	if (!buffer_changed_from_sentinel(dst_mem, dst_size, 0x80)) {
		fprintf(stderr, "RKNN virtual RGB resize output unchanged\n");
		ret = 1;
		goto out;
	}

	ret = write_artifact("rknn_virtual_rgb_imresize", dst_mem, dst_size);
	if (!ret)
		printf("%-24s ok\n", "RKNN rgb imresize");

out:
	if (src_handle)
		releasebuffer_handle(src_handle);
	if (dst_handle)
		releasebuffer_handle(dst_handle);
	free(src_mem);
	free(dst_mem);

	return ret;
}

static int run_rknn_fd_improcess(const char *name, const char *artifact,
				 int src_format, int dst_format,
				 size_t src_size, size_t dst_size,
				 void (*fill_src)(uint8_t *, int, int))
{
	const int src_w = 256;
	const int src_h = 256;
	const int dst_w = 128;
	const int dst_h = 128;
	struct dmabuf_test_buffer dma_src = {};
	struct dmabuf_test_buffer dma_dst = {};
	rga_buffer_handle_t src_handle = 0;
	rga_buffer_handle_t dst_handle = 0;
	im_handle_param_t src_param = {
		(uint32_t)src_w,
		(uint32_t)src_h,
		(uint32_t)src_format,
	};
	im_handle_param_t dst_param = {
		(uint32_t)dst_w,
		(uint32_t)dst_h,
		(uint32_t)dst_format,
	};
	im_rect src_rect = {0, 0, src_w, src_h};
	im_rect dst_rect = {0, 0, dst_w, dst_h};
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
			  "RKNN fd source start");
	if (ret) {
		ret = 1;
		goto out;
	}
	fill_src(dma_src.mem, src_w, src_h);
	ret = dmabuf_sync(dma_src.fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_RW,
			  "RKNN fd source end");
	if (ret) {
		ret = 1;
		goto out;
	}

	ret = dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_RW,
			  "RKNN fd dest start");
	if (ret) {
		ret = 1;
		goto out;
	}
	memset(dma_dst.mem, 0x80, dma_dst.size);
	ret = dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_RW,
			  "RKNN fd dest end");
	if (ret) {
		ret = 1;
		goto out;
	}

	src_handle = importbuffer_fd(dma_src.fd, &src_param);
	dst_handle = importbuffer_fd(dma_dst.fd, &dst_param);
	if (!src_handle || !dst_handle) {
		fprintf(stderr, "%s importbuffer_fd failed: %s\n",
			name, imStrError());
		ret = 1;
		goto out;
	}

	src = wrapbuffer_handle(src_handle, src_w, src_h, src_format);
	dst = wrapbuffer_handle(dst_handle, dst_w, dst_h, dst_format);

	ret = imcheck(src, dst, src_rect, dst_rect);
	if (ret != IM_STATUS_NOERROR) {
		ret = fail_status(name, ret);
		goto out;
	}

	ret = improcess(src, dst, {}, src_rect, dst_rect, {}, IM_SYNC);
	if (ret != IM_STATUS_SUCCESS) {
		ret = fail_status(name, ret);
		goto out;
	}

	ret = dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ,
			  "RKNN fd dest read start");
	if (ret) {
		ret = 1;
		goto out;
	}
	if (!buffer_changed_from_sentinel(dma_dst.mem, dma_dst.size, 0x80)) {
		fprintf(stderr, "%s output unchanged\n", name);
		ret = 1;
	} else {
		ret = write_artifact(artifact, dma_dst.mem, dma_dst.size);
	}
	if (dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ,
			"RKNN fd dest read end"))
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

static int run_rknn_fd_improcess_cases(void)
{
	int ret;

	ret = run_rknn_fd_improcess("RKNN RGB->NV12",
				    "rknn_fd_rgb_to_nv12_improcess",
				    RK_FORMAT_RGB_888,
				    RK_FORMAT_YCbCr_420_SP,
				    (size_t)256 * 256 * 3,
				    (size_t)128 * 128 * 3 / 2,
				    fill_rgb_pattern);
	if (ret)
		return ret;

	ret = run_rknn_fd_improcess("RKNN NV12->RGB",
				    "rknn_fd_nv12_to_rgb_improcess",
				    RK_FORMAT_YCbCr_420_SP,
				    RK_FORMAT_RGB_888,
				    (size_t)256 * 256 * 3 / 2,
				    (size_t)128 * 128 * 3,
				    fill_nv12_pattern);
	if (ret)
		return ret;

	return run_rknn_fd_improcess("RKNN NV21->RGB",
				     "rknn_fd_nv21_to_rgb_improcess",
				     RK_FORMAT_YCrCb_420_SP,
				     RK_FORMAT_RGB_888,
				     (size_t)256 * 256 * 3 / 2,
				     (size_t)128 * 128 * 3,
				     fill_nv21_pattern);
}

static int run_dmabuf_imcvtcolor_rgb_to_nv12(void)
{
	const int width = 256;
	const int height = 256;
	const int src_format = RK_FORMAT_RGB_888;
	const int dst_format = RK_FORMAT_YCbCr_420_SP;
	const size_t src_size = (size_t)width * height * 3;
	const size_t dst_size = (size_t)width * height * 3 / 2;
	struct dmabuf_test_buffer dma_src = {};
	struct dmabuf_test_buffer dma_dst = {};
	rga_buffer_handle_t src_handle = 0;
	rga_buffer_handle_t dst_handle = 0;
	im_handle_param_t src_param = {
		(uint32_t)width,
		(uint32_t)height,
		(uint32_t)src_format,
	};
	im_handle_param_t dst_param = {
		(uint32_t)width,
		(uint32_t)height,
		(uint32_t)dst_format,
	};
	rga_buffer_t src;
	rga_buffer_t dst;
	int ret;

	ret = dmabuf_alloc_any(src_size, &dma_src);
	if (ret) {
		fprintf(stderr, "imcvtcolor source allocation failed: %s\n",
			strerror(-ret));
		return 1;
	}

	ret = dmabuf_alloc_any(dst_size, &dma_dst);
	if (ret) {
		fprintf(stderr, "imcvtcolor dest allocation failed: %s\n",
			strerror(-ret));
		ret = 1;
		goto out;
	}

	ret = dmabuf_sync(dma_src.fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_RW,
			  "imcvtcolor source start");
	if (ret) {
		ret = 1;
		goto out;
	}
	fill_rgb_pattern(dma_src.mem, width, height);
	ret = dmabuf_sync(dma_src.fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_RW,
			  "imcvtcolor source end");
	if (ret) {
		ret = 1;
		goto out;
	}

	ret = dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_RW,
			  "imcvtcolor dest start");
	if (ret) {
		ret = 1;
		goto out;
	}
	memset(dma_dst.mem, 0x80, dma_dst.size);
	ret = dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_RW,
			  "imcvtcolor dest end");
	if (ret) {
		ret = 1;
		goto out;
	}

	src_handle = importbuffer_fd(dma_src.fd, &src_param);
	dst_handle = importbuffer_fd(dma_dst.fd, &dst_param);
	if (!src_handle || !dst_handle) {
		fprintf(stderr, "imcvtcolor importbuffer_fd failed: %s\n",
			imStrError());
		ret = 1;
		goto out;
	}

	src = wrapbuffer_handle(src_handle, width, height, src_format);
	dst = wrapbuffer_handle(dst_handle, width, height, dst_format);

	ret = imcheck(src, dst, {}, {});
	if (ret != IM_STATUS_NOERROR) {
		ret = fail_status("imcheck imcvtcolor", ret);
		goto out;
	}

	ret = imcvtcolor(src, dst, src_format, dst_format);
	if (ret != IM_STATUS_SUCCESS) {
		ret = fail_status("imcvtcolor", ret);
		goto out;
	}

	ret = dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ,
			  "imcvtcolor dest read start");
	if (ret) {
		ret = 1;
		goto out;
	}
	if (!nv12_changed_from_sentinel(dma_dst.mem, dma_dst.size)) {
		fprintf(stderr, "imcvtcolor RGB->NV12 output unchanged\n");
		ret = 1;
	} else {
		ret = write_artifact("dmabuf_imcvtcolor_rgb_to_nv12",
				     dma_dst.mem, dma_dst.size);
	}
	if (dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ,
			"imcvtcolor dest read end"))
		ret = 1;
	if (!ret)
		printf("%-24s ok heap=%s\n", "dmabuf imcvtcolor",
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

static int run_dmabuf_imresize_async_rgba(void)
{
	const int src_w = 256;
	const int src_h = 256;
	const int dst_w = 128;
	const int dst_h = 128;
	const size_t src_size = (size_t)src_w * src_h * TEST_BPP;
	const size_t dst_size = (size_t)dst_w * dst_h * TEST_BPP;
	struct dmabuf_test_buffer dma_src = {};
	struct dmabuf_test_buffer dma_dst = {};
	rga_buffer_handle_t src_handle = 0;
	rga_buffer_handle_t dst_handle = 0;
	im_handle_param_t src_param = {
		(uint32_t)src_w,
		(uint32_t)src_h,
		(uint32_t)RK_FORMAT_RGBA_8888,
	};
	im_handle_param_t dst_param = {
		(uint32_t)dst_w,
		(uint32_t)dst_h,
		(uint32_t)RK_FORMAT_RGBA_8888,
	};
	rga_buffer_t src;
	rga_buffer_t dst;
	int release_fence = -1;
	int ret;

	ret = dmabuf_alloc_any(src_size, &dma_src);
	if (ret) {
		fprintf(stderr, "imresize source allocation failed: %s\n",
			strerror(-ret));
		return 1;
	}

	ret = dmabuf_alloc_any(dst_size, &dma_dst);
	if (ret) {
		fprintf(stderr, "imresize dest allocation failed: %s\n",
			strerror(-ret));
		ret = 1;
		goto out;
	}

	ret = dmabuf_sync(dma_src.fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_RW,
			  "imresize source start");
	if (ret) {
		ret = 1;
		goto out;
	}
	fill_pattern(dma_src.mem, src_w, src_h);
	ret = dmabuf_sync(dma_src.fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_RW,
			  "imresize source end");
	if (ret) {
		ret = 1;
		goto out;
	}

	ret = dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_RW,
			  "imresize dest start");
	if (ret) {
		ret = 1;
		goto out;
	}
	memset(dma_dst.mem, 0x80, dma_dst.size);
	ret = dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_RW,
			  "imresize dest end");
	if (ret) {
		ret = 1;
		goto out;
	}

	src_handle = importbuffer_fd(dma_src.fd, &src_param);
	dst_handle = importbuffer_fd(dma_dst.fd, &dst_param);
	if (!src_handle || !dst_handle) {
		fprintf(stderr, "imresize importbuffer_fd failed: %s\n",
			imStrError());
		ret = 1;
		goto out;
	}

	src = wrapbuffer_handle(src_handle, src_w, src_h, RK_FORMAT_RGBA_8888);
	dst = wrapbuffer_handle(dst_handle, dst_w, dst_h, RK_FORMAT_RGBA_8888);

	ret = imcheck(src, dst, {}, {});
	if (ret != IM_STATUS_NOERROR) {
		ret = fail_status("imcheck imresize", ret);
		goto out;
	}

	ret = (imresize)(src, dst, 0.0, 0.0, IM_INTERP_DEFAULT, 0,
			 &release_fence);
	if (ret != IM_STATUS_SUCCESS) {
		ret = fail_status("imresize async", ret);
		goto out;
	}
	if (release_fence < 0) {
		fprintf(stderr, "imresize async did not return a release fence\n");
		ret = 1;
		goto out;
	}

	ret = imsync(release_fence);
	release_fence = -1;
	if (ret != IM_STATUS_SUCCESS) {
		ret = fail_status("imsync imresize", ret);
		goto out;
	}

	ret = dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ,
			  "imresize dest read start");
	if (ret) {
		ret = 1;
		goto out;
	}
	if (!buffer_changed_from_sentinel(dma_dst.mem, dma_dst.size, 0x80)) {
		fprintf(stderr, "imresize async output unchanged\n");
		ret = 1;
	} else {
		ret = write_artifact("dmabuf_imresize_async_rgba",
				     dma_dst.mem, dma_dst.size);
	}
	if (dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ,
			"imresize dest read end"))
		ret = 1;
	if (!ret)
		printf("%-24s ok heap=%s\n", "dmabuf imresize async",
		       dma_src.heap_path);

out:
	if (release_fence >= 0)
		close(release_fence);
	if (src_handle)
		releasebuffer_handle(src_handle);
	if (dst_handle)
		releasebuffer_handle(dst_handle);
	dmabuf_free(&dma_src);
	dmabuf_free(&dma_dst);

	return ret;
}

static int run_dmabuf_imcrop_rgba(void)
{
	const int src_w = 256;
	const int src_h = 256;
	const int crop_x = 40;
	const int crop_y = 48;
	const int crop_w = 128;
	const int crop_h = 96;
	const size_t src_size = (size_t)src_w * src_h * TEST_BPP;
	const size_t dst_size = (size_t)crop_w * crop_h * TEST_BPP;
	struct dmabuf_test_buffer dma_src = {};
	struct dmabuf_test_buffer dma_dst = {};
	rga_buffer_handle_t src_handle = 0;
	rga_buffer_handle_t dst_handle = 0;
	im_handle_param_t src_param = {
		(uint32_t)src_w,
		(uint32_t)src_h,
		(uint32_t)RK_FORMAT_RGBA_8888,
	};
	im_handle_param_t dst_param = {
		(uint32_t)crop_w,
		(uint32_t)crop_h,
		(uint32_t)RK_FORMAT_RGBA_8888,
	};
	im_rect src_rect = {crop_x, crop_y, crop_w, crop_h};
	im_rect dst_rect = {0, 0, crop_w, crop_h};
	rga_buffer_t src;
	rga_buffer_t dst;
	int ret;

	ret = dmabuf_alloc_any(src_size, &dma_src);
	if (ret) {
		fprintf(stderr, "imcrop source allocation failed: %s\n",
			strerror(-ret));
		return 1;
	}

	ret = dmabuf_alloc_any(dst_size, &dma_dst);
	if (ret) {
		fprintf(stderr, "imcrop dest allocation failed: %s\n",
			strerror(-ret));
		ret = 1;
		goto out;
	}

	ret = dmabuf_sync(dma_src.fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_RW,
			  "imcrop source start");
	if (ret) {
		ret = 1;
		goto out;
	}
	fill_pattern(dma_src.mem, src_w, src_h);
	ret = dmabuf_sync(dma_src.fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_RW,
			  "imcrop source end");
	if (ret) {
		ret = 1;
		goto out;
	}

	ret = dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_RW,
			  "imcrop dest start");
	if (ret) {
		ret = 1;
		goto out;
	}
	memset(dma_dst.mem, 0x80, dma_dst.size);
	ret = dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_RW,
			  "imcrop dest end");
	if (ret) {
		ret = 1;
		goto out;
	}

	src_handle = importbuffer_fd(dma_src.fd, &src_param);
	dst_handle = importbuffer_fd(dma_dst.fd, &dst_param);
	if (!src_handle || !dst_handle) {
		fprintf(stderr, "imcrop importbuffer_fd failed: %s\n",
			imStrError());
		ret = 1;
		goto out;
	}

	src = wrapbuffer_handle(src_handle, src_w, src_h, RK_FORMAT_RGBA_8888);
	dst = wrapbuffer_handle(dst_handle, crop_w, crop_h, RK_FORMAT_RGBA_8888);

	ret = imcheck(src, dst, src_rect, dst_rect, IM_CROP);
	if (ret != IM_STATUS_NOERROR) {
		ret = fail_status("imcheck imcrop", ret);
		goto out;
	}

	ret = imcrop(src, dst, src_rect);
	if (ret != IM_STATUS_SUCCESS) {
		ret = fail_status("imcrop", ret);
		goto out;
	}

	ret = dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ,
			  "imcrop dest read start");
	if (ret) {
		ret = 1;
		goto out;
	}
	if (check_rgba_crop(dma_dst.mem, crop_x, crop_y, crop_w, crop_h)) {
		ret = 1;
	} else {
		ret = write_artifact("dmabuf_imcrop_rgba",
				     dma_dst.mem, dma_dst.size);
	}
	if (dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ,
			"imcrop dest read end"))
		ret = 1;
	if (!ret)
		printf("%-24s ok heap=%s\n", "dmabuf imcrop",
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

static int run_dmabuf_imflip_rgba(void)
{
	const int width = 256;
	const int height = 192;
	const size_t size = (size_t)width * height * TEST_BPP;
	struct dmabuf_test_buffer dma_src = {};
	struct dmabuf_test_buffer dma_dst = {};
	rga_buffer_handle_t src_handle = 0;
	rga_buffer_handle_t dst_handle = 0;
	im_handle_param_t param = {
		(uint32_t)width,
		(uint32_t)height,
		(uint32_t)RK_FORMAT_RGBA_8888,
	};
	rga_buffer_t src;
	rga_buffer_t dst;
	int ret;

	ret = dmabuf_alloc_any(size, &dma_src);
	if (ret) {
		fprintf(stderr, "imflip source allocation failed: %s\n",
			strerror(-ret));
		return 1;
	}

	ret = dmabuf_alloc_any(size, &dma_dst);
	if (ret) {
		fprintf(stderr, "imflip dest allocation failed: %s\n",
			strerror(-ret));
		ret = 1;
		goto out;
	}

	ret = dmabuf_sync(dma_src.fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_RW,
			  "imflip source start");
	if (ret) {
		ret = 1;
		goto out;
	}
	fill_pattern(dma_src.mem, width, height);
	ret = dmabuf_sync(dma_src.fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_RW,
			  "imflip source end");
	if (ret) {
		ret = 1;
		goto out;
	}

	ret = dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_RW,
			  "imflip dest start");
	if (ret) {
		ret = 1;
		goto out;
	}
	memset(dma_dst.mem, 0x80, dma_dst.size);
	ret = dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_RW,
			  "imflip dest end");
	if (ret) {
		ret = 1;
		goto out;
	}

	src_handle = importbuffer_fd(dma_src.fd, &param);
	dst_handle = importbuffer_fd(dma_dst.fd, &param);
	if (!src_handle || !dst_handle) {
		fprintf(stderr, "imflip importbuffer_fd failed: %s\n",
			imStrError());
		ret = 1;
		goto out;
	}

	src = wrapbuffer_handle(src_handle, width, height, RK_FORMAT_RGBA_8888);
	dst = wrapbuffer_handle(dst_handle, width, height, RK_FORMAT_RGBA_8888);

	ret = imcheck(src, dst, {}, {});
	if (ret != IM_STATUS_NOERROR) {
		ret = fail_status("imcheck imflip", ret);
		goto out;
	}

	ret = imflip(src, dst, IM_HAL_TRANSFORM_FLIP_H);
	if (ret != IM_STATUS_SUCCESS) {
		ret = fail_status("imflip", ret);
		goto out;
	}

	ret = dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ,
			  "imflip dest read start");
	if (ret) {
		ret = 1;
		goto out;
	}
	if (check_rgba_flip(dma_dst.mem, width, height, true, false)) {
		ret = 1;
	} else {
		ret = write_artifact("dmabuf_imflip_h_rgba",
				     dma_dst.mem, dma_dst.size);
	}
	if (dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ,
			"imflip dest read end"))
		ret = 1;
	if (!ret)
		printf("%-24s ok heap=%s\n", "dmabuf imflip H",
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

static int run_rknn_fd_rgba_letterbox(void)
{
	const int src_w = 256;
	const int src_h = 256;
	const int dst_w = 256;
	const int dst_h = 192;
	const size_t src_size = (size_t)src_w * src_h * 4;
	const size_t dst_size = (size_t)dst_w * dst_h * 3;
	struct dmabuf_test_buffer dma_src = {};
	struct dmabuf_test_buffer dma_dst = {};
	rga_buffer_handle_t src_handle = 0;
	rga_buffer_handle_t dst_handle = 0;
	im_handle_param_t src_param = {
		(uint32_t)src_w,
		(uint32_t)src_h,
		(uint32_t)RK_FORMAT_RGBA_8888,
	};
	im_handle_param_t dst_param = {
		(uint32_t)dst_w,
		(uint32_t)dst_h,
		(uint32_t)RK_FORMAT_RGB_888,
	};
	im_rect src_rect = {8, 6, 40, 32};
	im_rect dst_rect = {12, 8, 40, 32};
	rga_buffer_t src;
	rga_buffer_t dst;
	int ret;

	ret = dmabuf_alloc_any(src_size, &dma_src);
	if (ret) {
		fprintf(stderr, "RKNN RGBA letterbox source allocation failed: %s\n",
			strerror(-ret));
		return 1;
	}

	ret = dmabuf_alloc_any(dst_size, &dma_dst);
	if (ret) {
		fprintf(stderr, "RKNN RGBA letterbox dest allocation failed: %s\n",
			strerror(-ret));
		ret = 1;
		goto out;
	}

	ret = dmabuf_sync(dma_src.fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_RW,
			  "RKNN RGBA source start");
	if (ret) {
		ret = 1;
		goto out;
	}
	fill_pattern(dma_src.mem, src_w, src_h);
	ret = dmabuf_sync(dma_src.fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_RW,
			  "RKNN RGBA source end");
	if (ret) {
		ret = 1;
		goto out;
	}

	ret = dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_RW,
			  "RKNN RGB letterbox dest start");
	if (ret) {
		ret = 1;
		goto out;
	}
	memset(dma_dst.mem, 0x80, dma_dst.size);
	ret = dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_RW,
			  "RKNN RGB letterbox dest end");
	if (ret) {
		ret = 1;
		goto out;
	}

	src_handle = importbuffer_fd(dma_src.fd, &src_param);
	dst_handle = importbuffer_fd(dma_dst.fd, &dst_param);
	if (!src_handle || !dst_handle) {
		fprintf(stderr, "RKNN RGBA letterbox importbuffer_fd failed: %s\n",
			imStrError());
		ret = 1;
		goto out;
	}

	src = wrapbuffer_handle(src_handle, src_w, src_h, RK_FORMAT_RGBA_8888);
	dst = wrapbuffer_handle(dst_handle, dst_w, dst_h, RK_FORMAT_RGB_888);

	ret = imcheck(src, dst, src_rect, dst_rect);
	if (ret != IM_STATUS_NOERROR) {
		ret = fail_status("RKNN RGBA letterbox", ret);
		goto out;
	}

	ret = improcess(src, dst, {}, src_rect, dst_rect, {}, IM_SYNC);
	if (ret != IM_STATUS_SUCCESS) {
		ret = fail_status("RKNN RGBA letterbox", ret);
		goto out;
	}

	ret = dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ,
			  "RKNN RGB letterbox read start");
	if (ret) {
		ret = 1;
		goto out;
	}
	if (!buffer_changed_from_sentinel(dma_dst.mem, dma_dst.size, 0x80)) {
		fprintf(stderr, "RKNN RGBA letterbox output unchanged\n");
		ret = 1;
	} else {
		ret = write_artifact("rknn_fd_rgba_to_rgb_letterbox",
				     dma_dst.mem, dma_dst.size);
	}
	if (dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ,
			"RKNN RGB letterbox read end"))
		ret = 1;
	if (!ret)
		printf("%-24s ok heap=%s\n", "RKNN RGBA letterbox",
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

static int run_rkmppenc_fd_filter_chain(void)
{
	const int src_w = 256;
	const int src_h = 256;
	const int crop_x = 32;
	const int crop_y = 24;
	const int crop_w = 192;
	const int crop_h = 160;
	const int dst_w = 128;
	const int dst_h = 96;
	const size_t src_size = (size_t)src_w * src_h * 3;
	const size_t tmp_size = (size_t)crop_w * crop_h * 3 / 2;
	const size_t dst_size = (size_t)dst_w * dst_h * 3 / 2;
	struct dmabuf_test_buffer dma_src = {};
	struct dmabuf_test_buffer dma_tmp = {};
	struct dmabuf_test_buffer dma_dst = {};
	rga_buffer_handle_t src_handle = 0;
	rga_buffer_handle_t tmp_handle = 0;
	rga_buffer_handle_t dst_handle = 0;
	im_handle_param_t src_param = {
		(uint32_t)src_w,
		(uint32_t)src_h,
		(uint32_t)RK_FORMAT_RGB_888,
	};
	im_handle_param_t tmp_param = {
		(uint32_t)crop_w,
		(uint32_t)crop_h,
		(uint32_t)RK_FORMAT_YCbCr_420_SP,
	};
	im_handle_param_t dst_param = {
		(uint32_t)dst_w,
		(uint32_t)dst_h,
		(uint32_t)RK_FORMAT_YCbCr_420_SP,
	};
	im_rect src_rect = {crop_x, crop_y, crop_w, crop_h};
	im_rect tmp_rect = {0, 0, crop_w, crop_h};
	im_rect dst_rect = {0, 0, dst_w, dst_h};
	rga_buffer_t src;
	rga_buffer_t tmp;
	rga_buffer_t dst;
	int first_fence = -1;
	int second_fence = -1;
	int ret;

	ret = dmabuf_alloc_any(src_size, &dma_src);
	if (ret) {
		fprintf(stderr, "rkmppenc chain source allocation failed: %s\n",
			strerror(-ret));
		return 1;
	}

	ret = dmabuf_alloc_any(tmp_size, &dma_tmp);
	if (ret) {
		fprintf(stderr, "rkmppenc chain temp allocation failed: %s\n",
			strerror(-ret));
		ret = 1;
		goto out;
	}

	ret = dmabuf_alloc_any(dst_size, &dma_dst);
	if (ret) {
		fprintf(stderr, "rkmppenc chain dest allocation failed: %s\n",
			strerror(-ret));
		ret = 1;
		goto out;
	}

	ret = dmabuf_sync(dma_src.fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_RW,
			  "rkmppenc chain source start");
	if (ret) {
		ret = 1;
		goto out;
	}
	fill_rgb_pattern(dma_src.mem, src_w, src_h);
	ret = dmabuf_sync(dma_src.fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_RW,
			  "rkmppenc chain source end");
	if (ret) {
		ret = 1;
		goto out;
	}

	ret = dmabuf_sync(dma_tmp.fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_RW,
			  "rkmppenc chain temp start");
	if (ret) {
		ret = 1;
		goto out;
	}
	memset(dma_tmp.mem, 0x80, dma_tmp.size);
	ret = dmabuf_sync(dma_tmp.fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_RW,
			  "rkmppenc chain temp end");
	if (ret) {
		ret = 1;
		goto out;
	}

	ret = dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_RW,
			  "rkmppenc chain dest start");
	if (ret) {
		ret = 1;
		goto out;
	}
	memset(dma_dst.mem, 0x80, dma_dst.size);
	ret = dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_RW,
			  "rkmppenc chain dest end");
	if (ret) {
		ret = 1;
		goto out;
	}

	src_handle = importbuffer_fd(dma_src.fd, &src_param);
	tmp_handle = importbuffer_fd(dma_tmp.fd, &tmp_param);
	dst_handle = importbuffer_fd(dma_dst.fd, &dst_param);
	if (!src_handle || !tmp_handle || !dst_handle) {
		fprintf(stderr, "rkmppenc chain importbuffer_fd failed: %s\n",
			imStrError());
		ret = 1;
		goto out;
	}

	src = wrapbuffer_handle(src_handle, src_w, src_h, RK_FORMAT_RGB_888);
	tmp = wrapbuffer_handle(tmp_handle, crop_w, crop_h,
				RK_FORMAT_YCbCr_420_SP);
	dst = wrapbuffer_handle(dst_handle, dst_w, dst_h,
				RK_FORMAT_YCbCr_420_SP);

	ret = imcheck(src, tmp, src_rect, tmp_rect);
	if (ret != IM_STATUS_NOERROR) {
		ret = fail_status("rkmppenc crop/csc", ret);
		goto out;
	}

	ret = improcess(src, tmp, {}, src_rect, tmp_rect, {}, -1,
			&first_fence, NULL, IM_ASYNC);
	if (ret != IM_STATUS_SUCCESS) {
		ret = fail_status("rkmppenc crop/csc", ret);
		goto out;
	}
	if (first_fence < 0) {
		fprintf(stderr, "rkmppenc crop/csc did not return a fence\n");
		ret = 1;
		goto out;
	}

	ret = imcheck(tmp, dst, tmp_rect, dst_rect);
	if (ret != IM_STATUS_NOERROR) {
		ret = fail_status("rkmppenc resize", ret);
		goto out;
	}

	ret = improcess(tmp, dst, {}, tmp_rect, dst_rect, {}, first_fence,
			&second_fence, NULL, IM_ASYNC);
	first_fence = -1;
	if (ret != IM_STATUS_SUCCESS) {
		ret = fail_status("rkmppenc resize", ret);
		goto out;
	}
	if (second_fence < 0) {
		fprintf(stderr, "rkmppenc resize did not return a fence\n");
		ret = 1;
		goto out;
	}

	ret = imsync(second_fence);
	second_fence = -1;
	if (ret != IM_STATUS_SUCCESS) {
		ret = fail_status("imsync rkmppenc", ret);
		goto out;
	}

	ret = dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ,
			  "rkmppenc chain dest read start");
	if (ret) {
		ret = 1;
		goto out;
	}
	if (!nv12_changed_from_sentinel(dma_dst.mem, dma_dst.size)) {
		fprintf(stderr, "rkmppenc fd filter-chain output unchanged\n");
		ret = 1;
	} else {
		ret = write_artifact("rkmppenc_fd_crop_csc_resize_chain",
				     dma_dst.mem, dma_dst.size);
	}
	if (dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ,
			"rkmppenc chain dest read end"))
		ret = 1;
	if (!ret)
		printf("%-24s ok heap=%s\n", "rkmppenc fd chain",
		       dma_src.heap_path);

out:
	if (first_fence >= 0)
		close(first_fence);
	if (second_fence >= 0)
		close(second_fence);
	if (src_handle)
		releasebuffer_handle(src_handle);
	if (tmp_handle)
		releasebuffer_handle(tmp_handle);
	if (dst_handle)
		releasebuffer_handle(dst_handle);
	dmabuf_free(&dma_src);
	dmabuf_free(&dma_tmp);
	dmabuf_free(&dma_dst);

	return ret;
}

static int run_rknn_legacy_rgb_resize(void)
{
	const int src_w = 256;
	const int src_h = 256;
	const int dst_w = 128;
	const int dst_h = 128;
	const size_t src_size = (size_t)src_w * src_h * 3;
	const size_t dst_size = (size_t)dst_w * dst_h * 3;
	rga_info_t src = {};
	rga_info_t dst = {};
	uint8_t *src_mem = NULL;
	uint8_t *dst_mem = NULL;
	int ret;

	if (alloc_aligned((void **)&src_mem, src_size) ||
	    alloc_aligned((void **)&dst_mem, dst_size)) {
		perror("posix_memalign rknn legacy RGB");
		ret = 1;
		goto out;
	}

	fill_rgb_pattern(src_mem, src_w, src_h);
	memset(dst_mem, 0x80, dst_size);

	src.virAddr = src_mem;
	src.format = RK_FORMAT_RGB_888;
	src.mmuFlag = 1;
	rga_set_rect(&src.rect, 0, 0, src_w, src_h, src_w, src_h,
		     RK_FORMAT_RGB_888);

	dst.virAddr = dst_mem;
	dst.format = RK_FORMAT_RGB_888;
	dst.mmuFlag = 1;
	rga_set_rect(&dst.rect, 0, 0, dst_w, dst_h, dst_w, dst_h,
		     RK_FORMAT_RGB_888);

	if (c_RkRgaInit()) {
		fprintf(stderr, "RKNN legacy RGA init failed\n");
		ret = 1;
		goto out;
	}

	if (c_RkRgaBlit(&src, &dst, NULL)) {
		fprintf(stderr, "RKNN legacy RGB resize failed\n");
		c_RkRgaDeInit();
		ret = 1;
		goto out;
	}
	c_RkRgaDeInit();

	if (!buffer_changed_from_sentinel(dst_mem, dst_size, 0x80)) {
		fprintf(stderr, "RKNN legacy RGB resize output unchanged\n");
		ret = 1;
		goto out;
	}

	ret = write_artifact("rknn_legacy_rgb_resize", dst_mem, dst_size);
	if (!ret)
		printf("%-24s ok\n", "RKNN legacy RGB");

out:
	free(src_mem);
	free(dst_mem);

	return ret;
}

static int run_legacy_color_fill(void)
{
	const int width = TEST_DST_W;
	const int height = TEST_DST_H;
	const int format = RK_FORMAT_RGBA_8888;
	const size_t size = (size_t)width * height * TEST_BPP;
	struct dmabuf_test_buffer dma_dst = {};
	rga_info_t dst = {};
	int ret;

	ret = dmabuf_alloc_any(size, &dma_dst);
	if (ret) {
		fprintf(stderr, "legacy color-fill dest allocation failed: %s\n",
			strerror(-ret));
		return 1;
	}

	ret = dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_RW,
			  "legacy color-fill dest start");
	if (ret) {
		ret = 1;
		goto out;
	}
	memset(dma_dst.mem, 0x33, dma_dst.size);
	ret = dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_RW,
			  "legacy color-fill dest end");
	if (ret) {
		ret = 1;
		goto out;
	}

	dst.fd = dma_dst.fd;
	dst.format = format;
	dst.mmuFlag = 1;
	dst.color = 0xff00ff00;
	rga_set_rect(&dst.rect, 0, 0, width, height, width, height, format);

	if (c_RkRgaInit()) {
		fprintf(stderr, "legacy color-fill RGA init failed\n");
		ret = 1;
		goto out;
	}

	if (c_RkRgaColorFill(&dst)) {
		fprintf(stderr, "legacy color-fill failed\n");
		c_RkRgaDeInit();
		ret = 1;
		goto out;
	}
	c_RkRgaDeInit();

	ret = dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ,
			  "legacy color-fill read start");
	if (ret) {
		ret = 1;
		goto out;
	}
	if (!buffer_changed_from_sentinel(dma_dst.mem, dma_dst.size, 0x33)) {
		fprintf(stderr, "legacy color-fill output unchanged\n");
		ret = 1;
	} else {
		ret = write_artifact("legacy_color_fill_rgba",
				     dma_dst.mem, dma_dst.size);
	}
	if (dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ,
			"legacy color-fill read end"))
		ret = 1;
	if (!ret)
		printf("%-24s ok heap=%s\n", "legacy color fill",
		       dma_dst.heap_path);

out:
	dmabuf_free(&dma_dst);

	return ret;
}

static int run_dmabuf_imrectangle_rgba(void)
{
	const int width = TEST_DST_W;
	const int height = TEST_DST_H;
	const int thickness = 2;
	const size_t size = (size_t)width * height * TEST_BPP;
	const uint8_t sentinel = 0x22;
	struct dmabuf_test_buffer dma_dst = {};
	rga_buffer_handle_t dst_handle = 0;
	rga_buffer_t dst;
	im_rect rect = {4, 5, 20, 18};
	int ret;

	ret = dmabuf_alloc_any(size, &dma_dst);
	if (ret) {
		fprintf(stderr, "imrectangle dest allocation failed: %s\n",
			strerror(-ret));
		return 1;
	}

	ret = dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_RW,
			  "imrectangle dest start");
	if (ret) {
		ret = 1;
		goto out;
	}
	memset(dma_dst.mem, sentinel, dma_dst.size);
	ret = dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_RW,
			  "imrectangle dest end");
	if (ret) {
		ret = 1;
		goto out;
	}

	dst_handle = importbuffer_fd(dma_dst.fd, size);
	if (!dst_handle) {
		fprintf(stderr, "imrectangle importbuffer_fd failed: %s\n",
			strerror(errno));
		ret = 1;
		goto out;
	}

	dst = wrapbuffer_handle(dst_handle, width, height, RK_FORMAT_RGBA_8888);
	ret = imcheck({}, dst, {}, rect, IM_COLOR_FILL);
	if (ret != IM_STATUS_NOERROR) {
		ret = fail_status("imcheck imrectangle", ret);
		goto out;
	}

	ret = imrectangle(dst, rect, 0xff00ff00, thickness);
	if (ret != IM_STATUS_SUCCESS) {
		ret = fail_status("imrectangle", ret);
		goto out;
	}

	ret = dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ,
			  "imrectangle read start");
	if (ret) {
		ret = 1;
		goto out;
	}
	if (check_rectangle_border_update(dma_dst.mem, width, height, &rect,
					  thickness, sentinel)) {
		ret = 1;
	} else {
		ret = write_artifact("imrectangle_rgba_border",
				     dma_dst.mem, dma_dst.size);
	}
	if (dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ,
			"imrectangle read end"))
		ret = 1;
	if (!ret)
		printf("%-24s ok heap=%s\n", "imrectangle",
		       dma_dst.heap_path);

out:
	if (dst_handle)
		releasebuffer_handle(dst_handle);
	dmabuf_free(&dma_dst);

	return ret;
}

static int run_dmabuf_imrectangle_task_array_rgba(void)
{
	const int width = TEST_DST_W;
	const int height = TEST_DST_H;
	const int thickness = 2;
	const size_t size = (size_t)width * height * TEST_BPP;
	const uint8_t sentinel = 0x44;
	im_rect rects[] = {
		{2, 2, 10, 8},
		{18, 7, 10, 12},
		{6, 22, 16, 6},
	};
	struct dmabuf_test_buffer dma_dst = {};
	rga_buffer_handle_t dst_handle = 0;
	im_job_handle_t job = 0;
	rga_buffer_t dst;
	int ret;

	ret = dmabuf_alloc_any(size, &dma_dst);
	if (ret) {
		fprintf(stderr,
			"imrectangleTaskArray dest allocation failed: %s\n",
			strerror(-ret));
		return 1;
	}

	ret = dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_RW,
			  "imrectangleTaskArray dest start");
	if (ret) {
		ret = 1;
		goto out;
	}
	memset(dma_dst.mem, sentinel, dma_dst.size);
	ret = dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_RW,
			  "imrectangleTaskArray dest end");
	if (ret) {
		ret = 1;
		goto out;
	}

	dst_handle = importbuffer_fd(dma_dst.fd, size);
	if (!dst_handle) {
		fprintf(stderr,
			"imrectangleTaskArray importbuffer_fd failed: %s\n",
			strerror(errno));
		ret = 1;
		goto out;
	}

	dst = wrapbuffer_handle(dst_handle, width, height, RK_FORMAT_RGBA_8888);
	for (size_t i = 0; i < sizeof(rects) / sizeof(rects[0]); i++) {
		ret = imcheck({}, dst, {}, rects[i], IM_COLOR_FILL);
		if (ret != IM_STATUS_NOERROR) {
			ret = fail_status("imcheck imrectangleTaskArray", ret);
			goto out;
		}
	}

	job = imbeginJob(IM_JOB_FLAGS_EXEC_SEQUENTIAL);
	if (!job) {
		fprintf(stderr, "imrectangleTaskArray begin failed: %s\n",
			imStrError());
		ret = 1;
		goto out;
	}

	ret = imrectangleTaskArray(job, dst, rects,
				   (int)(sizeof(rects) / sizeof(rects[0])),
				   0xffff0000, thickness);
	if (ret != IM_STATUS_SUCCESS) {
		fail_status("imrectangleTaskArray", ret);
		imcancelJob(job);
		job = 0;
		ret = 1;
		goto out;
	}

	ret = imendJob(job);
	job = 0;
	if (ret != IM_STATUS_SUCCESS) {
		ret = fail_status("imendJob rectangle", ret);
		goto out;
	}

	ret = dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ,
			  "imrectangleTaskArray read start");
	if (ret) {
		ret = 1;
		goto out;
	}
	if (check_rectangle_array_border_update(dma_dst.mem, width, height,
						rects,
						sizeof(rects) / sizeof(rects[0]),
						thickness, sentinel)) {
		ret = 1;
	} else {
		ret = write_artifact("imrectangle_task_array_rgba_border",
				     dma_dst.mem, dma_dst.size);
	}
	if (dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ,
			"imrectangleTaskArray read end"))
		ret = 1;
	if (!ret)
		printf("%-24s ok heap=%s\n", "imrectangle tasks",
		       dma_dst.heap_path);

out:
	if (job)
		imcancelJob(job);
	if (dst_handle)
		releasebuffer_handle(dst_handle);
	dmabuf_free(&dma_dst);

	return ret;
}

static int run_physical_import_probe(void)
{
	const size_t phys_size = (size_t)64 * 64 * TEST_BPP;
	const bool expect_reject =
		env_enabled("LIBRGA_SMOKE_EXPECT_PHYSICAL_REJECT");
	rga_buffer_handle_t handle;

	if (!env_enabled("LIBRGA_SMOKE_ENABLE_PHYSICAL_PROBE") &&
	    !expect_reject) {
		printf("%-24s disabled\n", "physical import");
		return 0;
	}

	handle = importbuffer_physicaladdr(0x1000, (int)phys_size);
	if (handle) {
		releasebuffer_handle(handle);
		if (expect_reject) {
			fprintf(stderr,
				"physical-address import was accepted; rewrite profile expects rejection\n");
			return 1;
		}

		printf("%-24s accepted; no-submit outside required profile\n",
		       "physical import");
		return 0;
	}

	printf("%-24s rejected/unsupported\n", "physical import");
	return 0;
}

static int run_fbc_tail_reject_probe_one(const char *name, int rd_mode)
{
	const int width = 256;
	const int height = 256;
	const int format = RK_FORMAT_YCbCr_420_SP;
	const size_t raster_size = (size_t)width * height * 3 / 2;
	const size_t fbc_size = raster_size * 4;
	const bool expect_reject =
		env_enabled("LIBRGA_SMOKE_EXPECT_FBC_TAIL_REJECT");
	rga_buffer_handle_t raster_handle = 0;
	rga_buffer_handle_t fbc_handle = 0;
	rga_buffer_t raster;
	rga_buffer_t fbc;
	uint8_t *raster_mem = NULL;
	uint8_t *fbc_mem = NULL;
	int ret;

	if (alloc_aligned((void **)&raster_mem, raster_size) ||
	    alloc_aligned((void **)&fbc_mem, fbc_size)) {
		perror("posix_memalign fbc tail");
		ret = 1;
		goto out;
	}

	fill_nv12_pattern(raster_mem, width, height);
	memset(fbc_mem, 0x80, fbc_size);

	raster_handle = importbuffer_virtualaddr(raster_mem, raster_size);
	fbc_handle = importbuffer_virtualaddr(fbc_mem, fbc_size);
	if (!raster_handle || !fbc_handle) {
		fprintf(stderr, "%s importbuffer_virtualaddr failed: %s\n",
			name, imStrError());
		ret = 1;
		goto out;
	}

	raster = wrapbuffer_handle(raster_handle, width, height, format);
	fbc = wrapbuffer_handle(fbc_handle, width, height, format);
	raster.rd_mode = IM_RASTER_MODE;
	fbc.rd_mode = rd_mode;

	ret = imcopy(raster, fbc);
	if (ret == IM_STATUS_SUCCESS) {
		if (expect_reject) {
			fprintf(stderr,
				"%s was accepted; rewrite profile expects rejection\n",
				name);
			ret = 1;
			goto out;
		}

		printf("%-24s accepted; outside required rewrite profile\n",
		       name);
		ret = 0;
		goto out;
	}

	printf("%-24s rejected/unsupported (%s)\n",
	       name, imStrError((IM_STATUS)ret));
	ret = 0;

out:
	if (raster_handle)
		releasebuffer_handle(raster_handle);
	if (fbc_handle)
		releasebuffer_handle(fbc_handle);
	free(raster_mem);
	free(fbc_mem);

	return ret;
}

static int run_fbc_tail_reject_probes(void)
{
	int ret;

	ret = run_fbc_tail_reject_probe_one("AFBC32x8 dst",
					    IM_AFBC32x8_MODE);
	if (ret)
		return ret;

	return run_fbc_tail_reject_probe_one("RFBC64x4 dst",
					     IM_RKFBC64x4_MODE);
}

static int run_afbc16x16_roundtrip(void)
{
	const int width = 256;
	const int height = 256;
	const int format = RK_FORMAT_YCbCr_420_SP;
	const size_t raster_size = (size_t)width * height * 3 / 2;
	const size_t fbc_size = raster_size * 3 / 2;
	rga_buffer_handle_t src_handle = 0;
	rga_buffer_handle_t fbc_handle = 0;
	rga_buffer_handle_t dst_handle = 0;
	rga_buffer_t src;
	rga_buffer_t fbc;
	rga_buffer_t dst;
	uint8_t *src_mem = NULL;
	uint8_t *fbc_mem = NULL;
	uint8_t *dst_mem = NULL;
	int ret;

	if (alloc_aligned((void **)&src_mem, raster_size) ||
	    alloc_aligned((void **)&fbc_mem, fbc_size) ||
	    alloc_aligned((void **)&dst_mem, raster_size)) {
		perror("posix_memalign afbc16x16");
		ret = 1;
		goto out;
	}

	fill_nv12_pattern(src_mem, width, height);
	memset(fbc_mem, 0x80, fbc_size);
	memset(dst_mem, 0x40, raster_size);

	src_handle = importbuffer_virtualaddr(src_mem, raster_size);
	fbc_handle = importbuffer_virtualaddr(fbc_mem, fbc_size);
	dst_handle = importbuffer_virtualaddr(dst_mem, raster_size);
	if (!src_handle || !fbc_handle || !dst_handle) {
		fprintf(stderr, "afbc16x16 importbuffer_virtualaddr failed: %s\n",
			imStrError());
		ret = 1;
		goto out;
	}

	src = wrapbuffer_handle(src_handle, width, height, format);
	fbc = wrapbuffer_handle(fbc_handle, width, height, format);
	dst = wrapbuffer_handle(dst_handle, width, height, format);

	src.rd_mode = IM_RASTER_MODE;
	fbc.rd_mode = IM_AFBC16x16_MODE;
	dst.rd_mode = IM_RASTER_MODE;

	ret = imcopy(src, fbc);
	if (ret != IM_STATUS_SUCCESS) {
		ret = fail_status("afbc raster->fbc", ret);
		goto out;
	}

	ret = imcopy(fbc, dst);
	if (ret != IM_STATUS_SUCCESS) {
		ret = fail_status("afbc fbc->raster", ret);
		goto out;
	}

	if (memcmp(src_mem, dst_mem, raster_size)) {
		fprintf(stderr, "afbc16x16 round-trip output differs from source\n");
		ret = 1;
		goto out;
	}

	ret = write_artifact("afbc16x16_nv12_roundtrip", dst_mem,
			     raster_size);
	if (!ret)
		printf("%-24s ok\n", "afbc16x16 roundtrip");

out:
	if (src_handle)
		releasebuffer_handle(src_handle);
	if (fbc_handle)
		releasebuffer_handle(fbc_handle);
	if (dst_handle)
		releasebuffer_handle(dst_handle);
	free(src_mem);
	free(fbc_mem);
	free(dst_mem);

	return ret;
}

static int run_tile8x8_roundtrip(void)
{
	const int width = 256;
	const int height = 256;
	const int format = RK_FORMAT_YCbCr_420_SP;
	const size_t size = (size_t)width * height * 3 / 2;
	rga_buffer_handle_t src_handle = 0;
	rga_buffer_handle_t tile_handle = 0;
	rga_buffer_handle_t dst_handle = 0;
	rga_buffer_t src;
	rga_buffer_t tile;
	rga_buffer_t dst;
	uint8_t *src_mem = NULL;
	uint8_t *tile_mem = NULL;
	uint8_t *dst_mem = NULL;
	int ret;

	if (alloc_aligned((void **)&src_mem, size) ||
	    alloc_aligned((void **)&tile_mem, size) ||
	    alloc_aligned((void **)&dst_mem, size)) {
		perror("posix_memalign tile8x8");
		ret = 1;
		goto out;
	}

	fill_nv12_pattern(src_mem, width, height);
	memset(tile_mem, 0x80, size);
	memset(dst_mem, 0x40, size);

	src_handle = importbuffer_virtualaddr(src_mem, size);
	tile_handle = importbuffer_virtualaddr(tile_mem, size);
	dst_handle = importbuffer_virtualaddr(dst_mem, size);
	if (!src_handle || !tile_handle || !dst_handle) {
		fprintf(stderr, "tile8x8 importbuffer_virtualaddr failed: %s\n",
			imStrError());
		ret = 1;
		goto out;
	}

	src = wrapbuffer_handle(src_handle, width, height, format);
	tile = wrapbuffer_handle(tile_handle, width, height, format);
	dst = wrapbuffer_handle(dst_handle, width, height, format);

	src.rd_mode = IM_RASTER_MODE;
	tile.rd_mode = IM_TILE8x8_MODE;
	dst.rd_mode = IM_RASTER_MODE;

	ret = imcopy(src, tile);
	if (ret != IM_STATUS_SUCCESS) {
		ret = fail_status("tile raster->tile", ret);
		goto out;
	}

	ret = imcopy(tile, dst);
	if (ret != IM_STATUS_SUCCESS) {
		ret = fail_status("tile tile->raster", ret);
		goto out;
	}

	if (memcmp(src_mem, dst_mem, size)) {
		fprintf(stderr, "tile8x8 round-trip output differs from source\n");
		ret = 1;
		goto out;
	}

	ret = write_artifact("tile8x8_nv12_roundtrip", dst_mem, size);
	if (!ret)
		printf("%-24s ok\n", "tile8x8 roundtrip");

out:
	if (src_handle)
		releasebuffer_handle(src_handle);
	if (tile_handle)
		releasebuffer_handle(tile_handle);
	if (dst_handle)
		releasebuffer_handle(dst_handle);
	free(src_mem);
	free(tile_mem);
	free(dst_mem);

	return ret;
}

static int run_legacy_virtual_to_dmabuf_convert(void)
{
	const int src_w = 256;
	const int src_h = 256;
	const int dst_w = 128;
	const int dst_h = 128;
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
		ret = write_artifact("legacy_bgrx_to_nv12",
				     dma_dst.mem, dma_dst.size);
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
	const int src_w = 256;
	const int src_h = 128;
	const int dst_w = 128;
	const int dst_h = 256;
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
		ret = write_artifact("legacy_nv12_to_bgrx_rot90",
				     dma_dst.mem, dma_dst.size);
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

static int run_legacy_display_rgb_rotate_one(const char *label,
					     const char *artifact,
					     int format, int rotation,
					     size_t bytes_per_pixel,
					     void (*fill)(uint8_t *buf,
							  int width,
							  int height))
{
	const int src_w = 256;
	const int src_h = 128;
	const bool swaps_axes = rotation == HAL_TRANSFORM_ROT_90 ||
				rotation == HAL_TRANSFORM_ROT_270;
	const int dst_w = swaps_axes ? src_h : src_w;
	const int dst_h = swaps_axes ? src_w : src_h;
	const size_t src_size = (size_t)src_w * src_h * bytes_per_pixel;
	const size_t dst_size = (size_t)dst_w * dst_h * bytes_per_pixel;
	struct dmabuf_test_buffer dma_src = {};
	struct dmabuf_test_buffer dma_dst = {};
	rga_info_t src = {};
	rga_info_t dst = {};
	int ret;

	ret = dmabuf_alloc_any(src_size, &dma_src);
	if (ret) {
		fprintf(stderr, "%s source allocation failed: %s\n", label,
			strerror(-ret));
		return 1;
	}

	ret = dmabuf_alloc_any(dst_size, &dma_dst);
	if (ret) {
		fprintf(stderr, "%s dest allocation failed: %s\n", label,
			strerror(-ret));
		ret = 1;
		goto out;
	}

	ret = dmabuf_sync(dma_src.fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_RW,
			  "legacy display source start");
	if (ret) {
		ret = 1;
		goto out;
	}
	fill(dma_src.mem, src_w, src_h);
	ret = dmabuf_sync(dma_src.fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_RW,
			  "legacy display source end");
	if (ret) {
		ret = 1;
		goto out;
	}

	ret = dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_RW,
			  "legacy display dest start");
	if (ret) {
		ret = 1;
		goto out;
	}
	memset(dma_dst.mem, 0x80, dma_dst.size);
	ret = dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_RW,
			  "legacy display dest end");
	if (ret) {
		ret = 1;
		goto out;
	}

	src.fd = dma_src.fd;
	src.format = format;
	src.rotation = rotation;
	src.mmuFlag = 1;
	rga_set_rect(&src.rect, 0, 0, src_w, src_h, src_w, src_h, format);

	dst.fd = dma_dst.fd;
	dst.format = format;
	dst.mmuFlag = 1;
	rga_set_rect(&dst.rect, 0, 0, dst_w, dst_h, dst_w, dst_h, format);

	if (c_RkRgaInit()) {
		fprintf(stderr, "%s RGA init failed\n", label);
		ret = 1;
		goto out;
	}

	if (c_RkRgaBlit(&src, &dst, NULL)) {
		fprintf(stderr, "%s rotate blit failed\n", label);
		c_RkRgaDeInit();
		ret = 1;
		goto out;
	}
	c_RkRgaDeInit();

	ret = dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ,
			  "legacy display read start");
	if (ret) {
		ret = 1;
		goto out;
	}
	if (!buffer_changed_from_sentinel(dma_dst.mem, dma_dst.size, 0x80)) {
		fprintf(stderr, "%s rotate output unchanged\n", label);
		ret = 1;
	} else {
		ret = write_artifact(artifact, dma_dst.mem, dma_dst.size);
	}
	if (dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ,
			"legacy display read end"))
		ret = 1;
	if (!ret)
		printf("%-24s ok heap=%s\n", label, dma_dst.heap_path);

out:
	dmabuf_free(&dma_src);
	dmabuf_free(&dma_dst);

	return ret;
}

static int run_legacy_display_rgb_rotate(void)
{
	return run_legacy_display_rgb_rotate_one("legacy display BGRx",
						 "legacy_bgrx_display_rot90",
						 RK_FORMAT_BGRX_8888,
						 HAL_TRANSFORM_ROT_90,
						 TEST_BPP,
						 fill_bgrx_pattern);
}

static int run_display_tail_bgra_partial_blend(void)
{
	const int src_w = 256;
	const int src_h = 192;
	const int dst_w = 320;
	const int dst_h = 256;
	const uint8_t sentinel = 0x11;
	const int blend_usage = IM_ALPHA_BLEND_SRC_OVER |
				IM_ALPHA_BLEND_PRE_MUL;
	const size_t src_size = (size_t)src_w * src_h * TEST_BPP;
	const size_t dst_size = (size_t)dst_w * dst_h * TEST_BPP;
	struct dmabuf_test_buffer dma_src = {};
	struct dmabuf_test_buffer dma_dst = {};
	rga_buffer_handle_t src_handle = 0;
	rga_buffer_handle_t dst_handle = 0;
	rga_buffer_t src;
	rga_buffer_t dst;
	im_rect src_rect = {8, 6, 28, 20};
	im_rect dst_rect = {24, 18, 28, 20};
	int ret;

	ret = dmabuf_alloc_any(src_size, &dma_src);
	if (ret) {
		fprintf(stderr, "display blend source allocation failed: %s\n",
			strerror(-ret));
		return 1;
	}

	ret = dmabuf_alloc_any(dst_size, &dma_dst);
	if (ret) {
		fprintf(stderr, "display blend dest allocation failed: %s\n",
			strerror(-ret));
		ret = 1;
		goto out;
	}

	ret = dmabuf_sync(dma_src.fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_RW,
			  "display blend source start");
	if (ret) {
		ret = 1;
		goto out;
	}
	fill_bgra_alpha_pattern(dma_src.mem, src_w, src_h);
	ret = dmabuf_sync(dma_src.fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_RW,
			  "display blend source end");
	if (ret) {
		ret = 1;
		goto out;
	}

	ret = dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_RW,
			  "display blend dest start");
	if (ret) {
		ret = 1;
		goto out;
	}
	memset(dma_dst.mem, sentinel, dma_dst.size);
	ret = dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_RW,
			  "display blend dest end");
	if (ret) {
		ret = 1;
		goto out;
	}

	src_handle = importbuffer_fd(dma_src.fd, src_size);
	dst_handle = importbuffer_fd(dma_dst.fd, dst_size);
	if (!src_handle || !dst_handle) {
		fprintf(stderr, "display blend importbuffer_fd failed: %s\n",
			imStrError());
		ret = 1;
		goto out;
	}

	src = wrapbuffer_handle(src_handle, src_w, src_h, RK_FORMAT_BGRA_8888);
	dst = wrapbuffer_handle(dst_handle, dst_w, dst_h, RK_FORMAT_BGRA_8888);

	ret = imcheck(src, dst, src_rect, dst_rect, blend_usage);
	if (ret != IM_STATUS_NOERROR) {
		ret = fail_status("imcheck display blend", ret);
		goto out;
	}

	ret = improcess(src, dst, {}, src_rect, dst_rect, {}, -1, NULL, NULL,
			IM_SYNC | blend_usage);
	if (ret != IM_STATUS_SUCCESS) {
		ret = fail_status("improcess display blend", ret);
		goto out;
	}

	ret = dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ,
			  "display blend read start");
	if (ret) {
		ret = 1;
		goto out;
	}
	if (check_partial_rect_update(dma_dst.mem, dst_w, dst_h, &dst_rect,
				      sentinel, "display blend")) {
		ret = 1;
	} else {
		ret = write_artifact("display_bgra_partial_blend",
				     dma_dst.mem, dma_dst.size);
	}
	if (dmabuf_sync(dma_dst.fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ,
			"display blend read end"))
		ret = 1;
	if (!ret)
		printf("%-24s ok heap=%s\n", "display BGRA blend",
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

static int run_legacy_display_tail_rotate(void)
{
	int ret;

	ret = run_legacy_display_rgb_rotate_one("legacy display BGRA",
						"legacy_bgra_display_rot90",
						RK_FORMAT_BGRA_8888,
						HAL_TRANSFORM_ROT_90,
						TEST_BPP,
						fill_bgrx_pattern);
	if (ret)
		return ret;

	ret = run_legacy_display_rgb_rotate_one("legacy display XRGB",
						"legacy_xrgb_display_rot270",
						RK_FORMAT_XRGB_8888,
						HAL_TRANSFORM_ROT_270,
						TEST_BPP,
						fill_bgrx_pattern);
	if (ret)
		return ret;

	ret = run_legacy_display_rgb_rotate_one("legacy display RGB565",
						"legacy_rgb565_display_rot180",
						RK_FORMAT_RGB_565,
						HAL_TRANSFORM_ROT_180,
						2,
						fill_rgb565_pattern);
	if (ret)
		return ret;

	return run_display_tail_bgra_partial_blend();
}

static int run_legacy_virtual_rgba_flip(void)
{
	const int width = 256;
	const int height = 192;
	const size_t size = (size_t)width * height * TEST_BPP;
	rga_info_t src = {};
	rga_info_t dst = {};
	uint8_t *src_mem = NULL;
	uint8_t *dst_mem = NULL;
	int ret;

	if (alloc_aligned((void **)&src_mem, size) ||
	    alloc_aligned((void **)&dst_mem, size)) {
		perror("posix_memalign legacy flip");
		ret = 1;
		goto out;
	}

	fill_pattern(src_mem, width, height);
	memset(dst_mem, 0x80, size);

	src.virAddr = src_mem;
	src.format = RK_FORMAT_RGBA_8888;
	src.rotation = HAL_TRANSFORM_FLIP_V;
	src.mmuFlag = 1;
	rga_set_rect(&src.rect, 0, 0, width, height, width, height,
		     RK_FORMAT_RGBA_8888);

	dst.virAddr = dst_mem;
	dst.format = RK_FORMAT_RGBA_8888;
	dst.mmuFlag = 1;
	rga_set_rect(&dst.rect, 0, 0, width, height, width, height,
		     RK_FORMAT_RGBA_8888);

	if (c_RkRgaInit()) {
		fprintf(stderr, "legacy flip RGA init failed\n");
		ret = 1;
		goto out;
	}

	if (c_RkRgaBlit(&src, &dst, NULL)) {
		fprintf(stderr, "legacy RGBA flip blit failed\n");
		c_RkRgaDeInit();
		ret = 1;
		goto out;
	}
	c_RkRgaDeInit();

	if (check_rgba_flip(dst_mem, width, height, false, true)) {
		ret = 1;
		goto out;
	}

	ret = write_artifact("legacy_rgba_flip_v", dst_mem, size);
	if (!ret)
		printf("%-24s ok\n", "legacy RGBA flip V");

out:
	free(src_mem);
	free(dst_mem);

	return ret;
}

static int run_legacy_planar_to_semiplanar_convert(void)
{
	const int width = 256;
	const int height = 256;
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
		ret = write_artifact("legacy_i420_to_nv12",
				     dma_dst.mem, dma_dst.size);
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
	const int width = 256;
	const int height = 256;
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
	if (ret == IM_STATUS_NOT_SUPPORTED) {
		/* Gauss is an RGA2-Pro feature; absent on RK3588. */
		printf("%-24s skip unsupported on this platform\n",
		       "improcess gauss");
		ret = 0;
		goto out;
	}
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
		ret = write_artifact("improcess_gauss_matrix",
				     dma_dst.mem, dma_dst.size);
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

static int run_imconfig_thread_defaults_copy(rga_buffer_t src,
					     rga_buffer_t dst,
					     const uint8_t *src_mem,
					     uint8_t *dst_mem,
					     size_t size)
{
	int ret;
	int reset_core_ret = IM_STATUS_SUCCESS;
	int reset_priority_ret = IM_STATUS_SUCCESS;
	bool core_set = false;
	bool priority_set = false;

	memset(dst_mem, 0x80, size);
	ret = imconfig(IM_CONFIG_SCHEDULER_CORE,
		       IM_SCHEDULER_RGA3_CORE0 | IM_SCHEDULER_RGA3_CORE1);
	if (ret != IM_STATUS_SUCCESS) {
		fail_status("imconfig core", ret);
		goto out;
	}
	core_set = true;

	ret = imconfig(IM_CONFIG_PRIORITY, 3);
	if (ret != IM_STATUS_SUCCESS) {
		fail_status("imconfig priority", ret);
		goto out;
	}
	priority_set = true;

	ret = imcopy(src, dst);
	if (ret != IM_STATUS_SUCCESS)
		fail_status("imconfig copy", ret);

out:
	if (priority_set) {
		reset_priority_ret = imconfig(IM_CONFIG_PRIORITY, 0);
		if (reset_priority_ret != IM_STATUS_SUCCESS)
			fprintf(stderr,
				"imconfig priority reset failed: %s (%d)\n",
				imStrError((IM_STATUS)reset_priority_ret),
				reset_priority_ret);
	}
	if (core_set) {
		/*
		 * librga rejects IM_SCHEDULER_DEFAULT (0) in imconfig, so the
		 * closest expressible reset is the full core mask, which gives
		 * the kernel scheduler the same free choice as the default.
		 */
		reset_core_ret = imconfig(IM_CONFIG_SCHEDULER_CORE,
					  IM_SCHEDULER_RGA3_CORE0 |
					  IM_SCHEDULER_RGA3_CORE1 |
					  IM_SCHEDULER_RGA2_CORE0);
		if (reset_core_ret != IM_STATUS_SUCCESS)
			fprintf(stderr,
				"imconfig scheduler reset failed: %s (%d)\n",
				imStrError((IM_STATUS)reset_core_ret),
				reset_core_ret);
	}

	if (ret != IM_STATUS_SUCCESS)
		return 1;
	if (reset_priority_ret != IM_STATUS_SUCCESS)
		return fail_status("imconfig priority reset", reset_priority_ret);
	if (reset_core_ret != IM_STATUS_SUCCESS)
		return fail_status("imconfig core reset", reset_core_ret);

	if (memcmp(src_mem, dst_mem, size)) {
		fprintf(stderr, "imconfig scheduler output differs from source\n");
		return 1;
	}
	if (write_artifact("imconfig_thread_defaults_copy", dst_mem, size))
		return 1;

	printf("%-24s ok\n", "imconfig defaults");
	return 0;
}

static int run_im2d_job_copy_chain(rga_buffer_t src, rga_buffer_t tmp,
				   rga_buffer_t dst, const uint8_t *src_mem,
				   uint8_t *tmp_mem, uint8_t *dst_mem,
				   size_t size)
{
	im_job_handle_t job;
	int ret;

	memset(tmp_mem, 0x40, size);
	memset(dst_mem, 0x80, size);

	job = imbeginJob(IM_JOB_FLAGS_EXEC_SEQUENTIAL);
	if (!job) {
		fprintf(stderr, "im2d job begin failed: %s\n", imStrError());
		return 1;
	}

	ret = imcopyTask(job, src, tmp);
	if (ret != IM_STATUS_SUCCESS) {
		fail_status("imcopyTask src", ret);
		imcancelJob(job);
		return 1;
	}

	ret = imcopyTask(job, tmp, dst);
	if (ret != IM_STATUS_SUCCESS) {
		fail_status("imcopyTask tmp", ret);
		imcancelJob(job);
		return 1;
	}

	ret = imendJob(job, IM_SYNC);
	if (ret != IM_STATUS_SUCCESS)
		return fail_status("imendJob copy", ret);

	if (memcmp(src_mem, dst_mem, size)) {
		fprintf(stderr, "im2d job copy-chain output differs from source\n");
		return 1;
	}
	if (write_artifact("im2d_job_copy_chain", dst_mem, size))
		return 1;

	printf("%-24s ok\n", "im2d job copy");
	return 0;
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

	artifact_dir = getenv("LIBRGA_SMOKE_ARTIFACT_DIR");
	if (ensure_artifact_dir())
		return 1;

	ret = imcheckHeader();
	/* Current librga returns IM_STATUS_SUCCESS here; older releases used
	 * IM_STATUS_NOERROR. Both are successful status values. */
	if (ret != IM_STATUS_SUCCESS && ret != IM_STATUS_NOERROR)
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
	if (write_artifact("imcopy_virtual_rgba", dst_mem, src_size)) {
		ret = 1;
		goto out;
	}
	printf("%-24s ok\n", "imcopy");

	ret = run_dmabuf_copy(src_size);
	if (ret)
		goto out;

	ret = run_rknn_virtual_rgb_resize();
	if (ret)
		goto out;

	ret = run_rknn_fd_improcess_cases();
	if (ret)
		goto out;

	ret = run_dmabuf_imcvtcolor_rgb_to_nv12();
	if (ret)
		goto out;

	ret = run_dmabuf_imresize_async_rgba();
	if (ret)
		goto out;

	ret = run_dmabuf_imcrop_rgba();
	if (ret)
		goto out;

	ret = run_dmabuf_imflip_rgba();
	if (ret)
		goto out;

	ret = run_rknn_fd_rgba_letterbox();
	if (ret)
		goto out;

	ret = run_rkmppenc_fd_filter_chain();
	if (ret)
		goto out;

	ret = run_rknn_legacy_rgb_resize();
	if (ret)
		goto out;

	ret = run_legacy_color_fill();
	if (ret)
		goto out;

	ret = run_dmabuf_imrectangle_rgba();
	if (ret)
		goto out;

	ret = run_dmabuf_imrectangle_task_array_rgba();
	if (ret)
		goto out;

	ret = run_physical_import_probe();
	if (ret)
		goto out;

	ret = run_fbc_tail_reject_probes();
	if (ret)
		goto out;

	ret = run_afbc16x16_roundtrip();
	if (ret)
		goto out;

	ret = run_tile8x8_roundtrip();
	if (ret)
		goto out;

	ret = run_legacy_virtual_to_dmabuf_convert();
	if (ret)
		goto out;

	ret = run_legacy_dmabuf_to_dmabuf_rotate_convert();
	if (ret)
		goto out;

	ret = run_legacy_display_rgb_rotate();
	if (ret)
		goto out;

	if (env_enabled("LIBRGA_SMOKE_DISPLAY_TAIL")) {
		ret = run_legacy_display_tail_rotate();
		if (ret)
			goto out;
	} else {
		printf("%-24s skip set LIBRGA_SMOKE_DISPLAY_TAIL=1\n",
		       "display BGRA/XRGB");
	}

	ret = run_legacy_virtual_rgba_flip();
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

	ret = run_imconfig_thread_defaults_copy(src, dst, src_mem, dst_mem,
						src_size);
	if (ret)
		goto out;

	ret = run_im2d_job_copy_chain(src, tmp, dst, src_mem, tmp_mem, dst_mem,
				      src_size);
	if (ret)
		goto out;

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
	if (write_artifact("forced_rga3_copy", dst_mem, src_size)) {
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
	if (ret == IM_STATUS_NOT_SUPPORTED) {
		/* pre_intr is absent from the RK3588 RGA feature list. */
		printf("%-24s skip unsupported on this platform\n",
		       "improcess pre-intr");
		ret = 0;
		goto out;
	}
	if (ret != IM_STATUS_SUCCESS) {
		ret = fail_status("improcess pre-intr", ret);
		goto out;
	}
	if (memcmp(src_mem, dst_mem, src_size)) {
		fprintf(stderr, "pre-intr output differs from source\n");
		ret = 1;
		goto out;
	}
	if (write_artifact("rga2_pre_intr_copy", dst_mem, src_size)) {
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
	if (write_artifact("async_fence_chain", dst_mem, src_size)) {
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
	if (write_artifact("imresize_rgba", dst_mem, dst_size)) {
		ret = 1;
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
	if (write_artifact("imfill_rgba", fill_mem, dst_size)) {
		ret = 1;
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
