// Direct im2d P010 probes on CMA dmabufs:
//   case 1: P010 src -> NV12 dst (tests incompact READ)
//   case 2: P010 src -> P010 dst copy (tests incompact READ+WRITE)
// Pattern: Y10[y][x] = (x + y) & 0x3ff stored MSB-aligned (<<6); expected
// NV12 Y = Y10 >> 2. Chroma neutral (0x200 << 6 / 0x80).
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

#define FMT_P010 (0x40 << 8)

static int heap_alloc(size_t size)
{
	int heap = open("/dev/dma_heap/default_cma_region", O_RDWR | O_CLOEXEC);
	if (heap < 0) { perror("open heap"); return -1; }
	struct dma_heap_allocation_data data = {};
	data.len = size;
	data.fd_flags = O_RDWR | O_CLOEXEC;
	int ret = ioctl(heap, DMA_HEAP_IOCTL_ALLOC, &data);
	close(heap);
	if (ret < 0) { perror("heap alloc"); return -1; }
	return data.fd;
}

struct buf { int fd; uint8_t *mem; size_t size; };

static void buf_sync(struct buf *b, uint64_t flags)
{
	struct dma_buf_sync s = { flags };
	ioctl(b->fd, DMA_BUF_IOCTL_SYNC, &s);
}

static int mkbuf(struct buf *b, size_t size)
{
	b->fd = heap_alloc(size);
	if (b->fd < 0) return -1;
	b->mem = (uint8_t *)mmap(nullptr, size, PROT_READ | PROT_WRITE,
				 MAP_SHARED, b->fd, 0);
	if (b->mem == MAP_FAILED) { perror("mmap"); return -1; }
	b->size = size;
	return 0;
}

static void fill_p010(uint8_t *mem, int w, int h)
{
	uint16_t *y = (uint16_t *)mem;
	for (int r = 0; r < h; r++)
		for (int c = 0; c < w; c++)
			y[r * w + c] = (uint16_t)(((r + c) & 0x3ff) << 6);
	uint16_t *uv = (uint16_t *)(mem + (size_t)w * h * 2);
	for (int i = 0; i < w * h / 2; i++)
		uv[i] = (uint16_t)(0x200 << 6);
}

int main(int argc, char **argv)
{
	int w = argc > 1 ? atoi(argv[1]) : 128;
	int h = w;
	size_t p010_size = (size_t)w * h * 3;      /* 2 B/px Y + 1 B/px UV */
	size_t nv12_size = (size_t)w * h * 3 / 2;
	struct buf src = {}, dst12 = {}, dst10 = {};

	if (mkbuf(&src, p010_size) || mkbuf(&dst12, p010_size) ||
	    mkbuf(&dst10, p010_size))
		return 2;
	buf_sync(&src, DMA_BUF_SYNC_START | DMA_BUF_SYNC_RW);
	buf_sync(&dst12, DMA_BUF_SYNC_START | DMA_BUF_SYNC_RW);
	buf_sync(&dst10, DMA_BUF_SYNC_START | DMA_BUF_SYNC_RW);
	fill_p010(src.mem, w, h);
	memset(dst12.mem, 0x11, dst12.size);
	memset(dst10.mem, 0x22, dst10.size);
	buf_sync(&src, DMA_BUF_SYNC_END | DMA_BUF_SYNC_RW);
	buf_sync(&dst12, DMA_BUF_SYNC_END | DMA_BUF_SYNC_RW);
	buf_sync(&dst10, DMA_BUF_SYNC_END | DMA_BUF_SYNC_RW);

	rga_buffer_handle_t hs = importbuffer_fd(src.fd, p010_size);
	rga_buffer_handle_t h12 = importbuffer_fd(dst12.fd, p010_size);
	rga_buffer_handle_t h10 = importbuffer_fd(dst10.fd, p010_size);
	if (!hs || !h12 || !h10) {
		fprintf(stderr, "import failed: %s\n", imStrError());
		return 2;
	}

	rga_buffer_t s = wrapbuffer_handle(hs, w, h, FMT_P010);
	rga_buffer_t d12 = wrapbuffer_handle(h12, w, h, RK_FORMAT_YCbCr_420_SP);
	rga_buffer_t d10 = wrapbuffer_handle(h10, w, h, FMT_P010);

	/* case 1: P010 -> NV12 */
	int ret = imcvtcolor(s, d12, FMT_P010, RK_FORMAT_YCbCr_420_SP);
	if (ret != IM_STATUS_SUCCESS) {
		printf("P010->NV12 submit FAILED: %s\n", imStrError((IM_STATUS)ret));
	} else {
		int bad = 0;
		buf_sync(&dst12, DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ);
		for (int r = 0; r < h && bad < 4; r++)
			for (int c = 0; c < w && bad < 4; c++) {
				uint8_t want = (uint8_t)(((r + c) & 0x3ff) >> 2);
				uint8_t got = dst12.mem[r * w + c];
				if (want != got) {
					if (!bad)
						printf("P010->NV12 first mismatch @(%d,%d): want %02x got %02x\n",
						       c, r, want, got);
					bad++;
				}
			}
		printf("P010->NV12 %s\n", bad ? "CORRUPT" : "OK");
		{
			uint8_t *uv8 = dst12.mem + (size_t)w * h;
			int uvbad8 = 0;
			for (int i = 0; i < w * h / 2; i++)
				if (uv8[i] != 0x80)
					uvbad8++;
			printf("P010->NV12 chroma: %d/%d bytes differ from neutral 0x80; first 8: "
			       "%02x %02x %02x %02x %02x %02x %02x %02x\n",
			       uvbad8, w * h / 2, uv8[0], uv8[1], uv8[2], uv8[3],
			       uv8[4], uv8[5], uv8[6], uv8[7]);
		}
	}

	/* case 2: P010 -> P010 copy */
	ret = imcopy(s, d10);
	if (ret != IM_STATUS_SUCCESS) {
		printf("P010->P010 submit FAILED: %s\n", imStrError((IM_STATUS)ret));
	} else {
		buf_sync(&dst10, DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ);
		int cmpres = memcmp(src.mem, dst10.mem, p010_size);
		printf("P010->P010 copy %s\n", cmpres ? "CORRUPT" : "BIT-EXACT");
		if (cmpres) {
			uint16_t *sy = (uint16_t *)src.mem;
			uint16_t *dy = (uint16_t *)dst10.mem;
			int ybad = 0;
			for (int i = 0; i < w * h; i++)
				if (sy[i] != dy[i]) {
					if (!ybad)
						printf("  first Y mismatch @%d (x=%d,y=%d): want %04x got %04x\n",
						       i, i % w, i / w, sy[i], dy[i]);
					ybad++;
				}
			printf("  Y mismatches: %d/%d\n", ybad, w * h);
			size_t uv_off = (size_t)w * h * 2;
			uint16_t *suv = (uint16_t *)(src.mem + uv_off);
			uint16_t *duv = (uint16_t *)(dst10.mem + uv_off);
			int uvbad = 0;
			for (int i = 0; i < w * h / 2; i++)
				if (suv[i] != duv[i]) {
					if (!uvbad)
						printf("  first UV mismatch @%d: want %04x got %04x\n",
						       i, suv[i], duv[i]);
					uvbad++;
				}
			printf("  UV mismatches: %d/%d\n", uvbad, w * h / 2);
			/* where does the expected UV pattern (0x8000) actually live? */
			size_t first = 0, last = 0; int found = 0;
			uint16_t *all = (uint16_t *)dst10.mem;
			for (size_t i = 0; i < p010_size / 2; i++)
				if (all[i] == 0x8000) {
					if (!found) { first = i; found = 1; }
					last = i;
				}
			if (found)
				printf("  0x8000 spans halfword [%zu..%zu] (uv plane starts at %zu)\n",
				       first, last, uv_off / 2);
			else
				printf("  no 0x8000 anywhere in dst\n");
		}
	}
	return 0;
}
