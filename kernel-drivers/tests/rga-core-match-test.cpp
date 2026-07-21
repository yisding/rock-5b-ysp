// Minimal RGA core-match experiment: imcopy a WxH RGBA8888 dmabuf pair
// allocated from a specific dma-heap. Usage: rga-core-match-test <heap> <size>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cerrno>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <linux/dma-heap.h>
#include <linux/dma-buf.h>

#include <im2d.hpp>
#include <RgaUtils.h>

static void dmabuf_sync(int fd, __u64 flags)
{
	struct dma_buf_sync sync = {};
	sync.flags = flags;
	if (ioctl(fd, DMA_BUF_IOCTL_SYNC, &sync) < 0)
		fprintf(stderr, "DMA_BUF_IOCTL_SYNC fd=%d flags=%llx: %s\n",
			fd, (unsigned long long)flags, strerror(errno));
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

int main(int argc, char **argv)
{
	const char *heap = argc > 1 ? argv[1] : "/dev/dma_heap/system";
	int dim = argc > 2 ? atoi(argv[2]) : 64;
	size_t size = (size_t)dim * dim * 4;

	int src_fd = heap_alloc(heap, size);
	int dst_fd = heap_alloc(heap, size);
	if (src_fd < 0 || dst_fd < 0)
		return 2;

	void *src_map = mmap(nullptr, size, PROT_READ | PROT_WRITE, MAP_SHARED, src_fd, 0);
	void *dst_map = mmap(nullptr, size, PROT_READ | PROT_WRITE, MAP_SHARED, dst_fd, 0);
	if (src_map == MAP_FAILED || dst_map == MAP_FAILED) {
		perror("mmap");
		return 2;
	}
	dmabuf_sync(src_fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_RW);
	dmabuf_sync(dst_fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_RW);
	memset(src_map, 0xa5, size);
	memset(dst_map, 0, size);
	dmabuf_sync(src_fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_RW);
	dmabuf_sync(dst_fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_RW);

	rga_buffer_handle_t src_h = importbuffer_fd(src_fd, size);
	rga_buffer_handle_t dst_h = importbuffer_fd(dst_fd, size);
	if (!src_h || !dst_h) {
		fprintf(stderr, "importbuffer_fd failed: %s\n", imStrError());
		return 2;
	}

	rga_buffer_t src = wrapbuffer_handle(src_h, dim, dim, RK_FORMAT_RGBA_8888);
	rga_buffer_t dst = wrapbuffer_handle(dst_h, dim, dim, RK_FORMAT_RGBA_8888);

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
	dmabuf_sync(src_fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ);
	dmabuf_sync(dst_fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ);
	int match = ok && memcmp(src_map, dst_map, size) == 0;
	dmabuf_sync(src_fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ);
	dmabuf_sync(dst_fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ);
	printf("heap=%s dim=%d imcopy=%s content=%s (%s)\n", heap, dim,
	       ok ? "PASS" : "FAIL", match ? "match" : "MISMATCH",
	       imStrError((IM_STATUS)ret));

	releasebuffer_handle(src_h);
	releasebuffer_handle(dst_h);
	return ok && match ? 0 : 1;
}
