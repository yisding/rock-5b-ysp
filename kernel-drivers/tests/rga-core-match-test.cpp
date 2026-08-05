// SPDX-FileCopyrightText: 2026 Yi Ding
// SPDX-License-Identifier: Apache-2.0
// Minimal RGA core-match experiment: imcopy a WxH RGBA8888 buffer pair with
// independently chosen backing, to isolate the RGA2 over-4G bounce legs.
//
// Usage: rga-core-match-test [src_spec] [dst_spec] [dim] [alloc_mb]
//   spec     a dma-heap path (/dev/dma_heap/...) or "malloc" (userptr import)
//   dim      image is dim x dim RGBA8888; dim < 68 forces RGA2 (RGA3 width floor)
//   alloc_mb over-allocate each buffer to this many MiB (image stays dim x dim);
//            larger than the swiotlb pool forces the bounce-mapping failure path
// One arg + numeric second arg keeps the old "<heap> <dim>" form.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cerrno>
#include <cctype>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <linux/dma-heap.h>
#include <linux/dma-buf.h>

#include <im2d.hpp>
#include <RgaUtils.h>

struct buf {
	const char *spec;
	int fd = -1;
	void *map = nullptr;
	size_t size = 0;
	rga_buffer_handle_t handle = 0;
	bool is_malloc = false;
};

static void dmabuf_sync(const buf &b, __u64 flags)
{
	if (b.is_malloc)
		return;
	struct dma_buf_sync sync = {};
	sync.flags = flags;
	if (ioctl(b.fd, DMA_BUF_IOCTL_SYNC, &sync) < 0)
		fprintf(stderr, "DMA_BUF_IOCTL_SYNC fd=%d flags=%llx: %s\n",
			b.fd, (unsigned long long)flags, strerror(errno));
}

static int heap_alloc(const char *path, size_t size)
{
	int heap = open(path, O_RDWR | O_CLOEXEC);
	if (heap < 0) {
		fprintf(stderr, "open %s: %s\n", path, strerror(errno));
		return -1;
	}
	struct dma_heap_allocation_data data = {};
	data.len = size;
	data.fd_flags = O_RDWR | O_CLOEXEC;
	int ret = ioctl(heap, DMA_HEAP_IOCTL_ALLOC, &data);
	close(heap);
	if (ret < 0) {
		fprintf(stderr, "alloc %s: %s\n", path, strerror(errno));
		return -1;
	}
	return data.fd;
}

static bool buf_setup(buf &b, const char *spec, size_t size)
{
	b.spec = spec;
	b.size = size;
	if (strcmp(spec, "malloc") == 0) {
		b.is_malloc = true;
		if (posix_memalign(&b.map, 4096, size) != 0) {
			perror("posix_memalign");
			return false;
		}
		return true;
	}
	b.fd = heap_alloc(spec, size);
	if (b.fd < 0)
		return false;
	b.map = mmap(nullptr, size, PROT_READ | PROT_WRITE, MAP_SHARED, b.fd, 0);
	if (b.map == MAP_FAILED) {
		perror("mmap");
		return false;
	}
	return true;
}

static bool buf_import(buf &b)
{
	b.handle = b.is_malloc ? importbuffer_virtualaddr(b.map, b.size)
			       : importbuffer_fd(b.fd, b.size);
	if (!b.handle)
		fprintf(stderr, "import %s failed: %s\n", b.spec, imStrError());
	return b.handle != 0;
}

int main(int argc, char **argv)
{
	const char *src_spec = argc > 1 ? argv[1] : "/dev/dma_heap/system";
	const char *dst_spec;
	int dim, dim_arg;

	// Old form: <heap> <dim> (second arg numeric).
	if (argc == 3 && isdigit((unsigned char)argv[2][0])) {
		dst_spec = src_spec;
		dim_arg = 2;
	} else {
		dst_spec = argc > 2 ? argv[2] : src_spec;
		dim_arg = 3;
	}
	dim = argc > dim_arg ? atoi(argv[dim_arg]) : 64;
	size_t img_size = (size_t)dim * dim * 4;
	size_t alloc_size = img_size;
	if (argc > dim_arg + 1)
		alloc_size = (size_t)atoi(argv[dim_arg + 1]) << 20;
	if (alloc_size < img_size)
		alloc_size = img_size;

	buf src_b, dst_b;
	if (!buf_setup(src_b, src_spec, alloc_size) ||
	    !buf_setup(dst_b, dst_spec, alloc_size))
		return 2;

	dmabuf_sync(src_b, DMA_BUF_SYNC_START | DMA_BUF_SYNC_RW);
	dmabuf_sync(dst_b, DMA_BUF_SYNC_START | DMA_BUF_SYNC_RW);
	memset(src_b.map, 0xa5, alloc_size);
	memset(dst_b.map, 0, alloc_size);
	dmabuf_sync(src_b, DMA_BUF_SYNC_END | DMA_BUF_SYNC_RW);
	dmabuf_sync(dst_b, DMA_BUF_SYNC_END | DMA_BUF_SYNC_RW);

	if (!buf_import(src_b) || !buf_import(dst_b))
		return 2;

	rga_buffer_t src = wrapbuffer_handle(src_b.handle, dim, dim, RK_FORMAT_RGBA_8888);
	rga_buffer_t dst = wrapbuffer_handle(dst_b.handle, dim, dim, RK_FORMAT_RGBA_8888);

	int ret = imcheck(src, dst, {}, {});
	if (ret != IM_STATUS_NOERROR) {
		fprintf(stderr, "imcheck: %s\n", imStrError((IM_STATUS)ret));
		return 2;
	}
	errno = 0;
	ret = imcopy(src, dst);
	int saved_errno = errno;
	int ok = (ret == IM_STATUS_SUCCESS);
	if (!ok)
		fprintf(stderr, "imcopy errno=%d (%s)\n", saved_errno, strerror(saved_errno));
	dmabuf_sync(src_b, DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ);
	dmabuf_sync(dst_b, DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ);
	int match = ok && memcmp(src_b.map, dst_b.map, img_size) == 0;
	dmabuf_sync(src_b, DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ);
	dmabuf_sync(dst_b, DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ);
	printf("src=%s dst=%s dim=%d alloc=%zuKiB imcopy=%s content=%s (%s)\n",
	       src_spec, dst_spec, dim, alloc_size >> 10,
	       ok ? "PASS" : "FAIL", match ? "match" : "MISMATCH",
	       imStrError((IM_STATUS)ret));

	releasebuffer_handle(src_b.handle);
	releasebuffer_handle(dst_b.handle);
	return ok && match ? 0 : 1;
}
