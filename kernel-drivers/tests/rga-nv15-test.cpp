// Direct im2d compact-NV15 probes on CMA dmabufs (the `0048` compact
// 10-bits/px raster-stride leg; RGA3-eligible sizes, below-4G so the RGA2
// over-4G path never interferes):
//   case 1: NV15 src -> NV12 dst   (compact READ, checked semantically)
//   case 2: P010 src -> NV15 dst   (compact WRITE, CPU-unpacked and checked)
//   case 3: NV15 src -> NV15 dst   (copy round-trip, bit-exact)
// Pattern: Y10[y][x] = (x + y) & 0x3ff; chroma neutral 0x200. NV15 packs 4
// pixels into 5 bytes LSB-first; P010 stores the 10 bits MSB-aligned (<<6).
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
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
#define FMT_NV15 RK_FORMAT_YCbCr_420_SP_10B

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

/* value of 10-bit element @i in an LSB-first packed stream */
static uint16_t pack10_get(const uint8_t *p, size_t i)
{
	size_t bit = i * 10;
	uint32_t v = p[bit / 8] | (p[bit / 8 + 1] << 8);
	return (v >> (bit % 8)) & 0x3ff;
}

static void pack10_set(uint8_t *p, size_t i, uint16_t val)
{
	size_t bit = i * 10;
	uint32_t v = p[bit / 8] | (p[bit / 8 + 1] << 8);
	v &= ~(0x3ffu << (bit % 8));
	v |= (uint32_t)(val & 0x3ff) << (bit % 8);
	p[bit / 8] = v & 0xff;
	p[bit / 8 + 1] = (v >> 8) & 0xff;
}

static uint16_t y10(int r, int c) { return (uint16_t)((r + c) & 0x3ff); }

static void fill_nv15(uint8_t *mem, int w, int h)
{
	for (int r = 0; r < h; r++)
		for (int c = 0; c < w; c++)
			pack10_set(mem + (size_t)r * w * 10 / 8, c, y10(r, c));
	uint8_t *uv = mem + (size_t)w * h * 10 / 8;
	for (int i = 0; i < w * h / 2; i++)
		pack10_set(uv, i, 0x200);
}

static void fill_p010(uint8_t *mem, int w, int h)
{
	uint16_t *y = (uint16_t *)mem;
	for (int r = 0; r < h; r++)
		for (int c = 0; c < w; c++)
			y[r * w + c] = (uint16_t)(y10(r, c) << 6);
	uint16_t *uv = (uint16_t *)(mem + (size_t)w * h * 2);
	for (int i = 0; i < w * h / 2; i++)
		uv[i] = (uint16_t)(0x200 << 6);
}

int main(int argc, char **argv)
{
	int w = argc > 1 ? atoi(argv[1]) : 256;
	int h = w;
	size_t nv15_size = (size_t)w * h * 15 / 8;
	size_t p010_size = (size_t)w * h * 3;
	size_t nv12_size = (size_t)w * h * 3 / 2;
	int failures = 0;
	struct buf s15 = {}, s10 = {}, d12 = {}, d15 = {}, dcp = {};

	if (mkbuf(&s15, nv15_size) || mkbuf(&s10, p010_size) ||
	    mkbuf(&d12, nv12_size) || mkbuf(&d15, nv15_size) ||
	    mkbuf(&dcp, nv15_size))
		return 2;

	buf_sync(&s15, DMA_BUF_SYNC_START | DMA_BUF_SYNC_RW);
	buf_sync(&s10, DMA_BUF_SYNC_START | DMA_BUF_SYNC_RW);
	buf_sync(&d12, DMA_BUF_SYNC_START | DMA_BUF_SYNC_RW);
	buf_sync(&d15, DMA_BUF_SYNC_START | DMA_BUF_SYNC_RW);
	buf_sync(&dcp, DMA_BUF_SYNC_START | DMA_BUF_SYNC_RW);
	fill_nv15(s15.mem, w, h);
	fill_p010(s10.mem, w, h);
	memset(d12.mem, 0x11, d12.size);
	memset(d15.mem, 0x22, d15.size);
	memset(dcp.mem, 0x33, dcp.size);
	buf_sync(&s15, DMA_BUF_SYNC_END | DMA_BUF_SYNC_RW);
	buf_sync(&s10, DMA_BUF_SYNC_END | DMA_BUF_SYNC_RW);
	buf_sync(&d12, DMA_BUF_SYNC_END | DMA_BUF_SYNC_RW);
	buf_sync(&d15, DMA_BUF_SYNC_END | DMA_BUF_SYNC_RW);
	buf_sync(&dcp, DMA_BUF_SYNC_END | DMA_BUF_SYNC_RW);

	rga_buffer_handle_t h15 = importbuffer_fd(s15.fd, nv15_size);
	rga_buffer_handle_t h10 = importbuffer_fd(s10.fd, p010_size);
	rga_buffer_handle_t hd12 = importbuffer_fd(d12.fd, nv12_size);
	rga_buffer_handle_t hd15 = importbuffer_fd(d15.fd, nv15_size);
	rga_buffer_handle_t hdcp = importbuffer_fd(dcp.fd, nv15_size);
	if (!h15 || !h10 || !hd12 || !hd15 || !hdcp) {
		fprintf(stderr, "import failed: %s\n", imStrError());
		return 2;
	}

	rga_buffer_t src15 = wrapbuffer_handle(h15, w, h, FMT_NV15);
	rga_buffer_t src10 = wrapbuffer_handle(h10, w, h, FMT_P010);
	rga_buffer_t dst12 = wrapbuffer_handle(hd12, w, h, RK_FORMAT_YCbCr_420_SP);
	rga_buffer_t dst15 = wrapbuffer_handle(hd15, w, h, FMT_NV15);
	rga_buffer_t dstcp = wrapbuffer_handle(hdcp, w, h, FMT_NV15);

	/* case 1: NV15 -> NV12 (compact read, semantic check) */
	int ret = imcvtcolor(src15, dst12, FMT_NV15, RK_FORMAT_YCbCr_420_SP);
	if (ret != IM_STATUS_SUCCESS) {
		printf("NV15->NV12 submit FAILED: %s\n", imStrError((IM_STATUS)ret));
		failures++;
	} else {
		int bad = 0, uvbad = 0;
		buf_sync(&d12, DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ);
		for (int r = 0; r < h; r++)
			for (int c = 0; c < w; c++) {
				uint8_t want = (uint8_t)(y10(r, c) >> 2);
				uint8_t got = d12.mem[(size_t)r * w + c];
				if (want != got) {
					if (!bad)
						printf("NV15->NV12 first Y mismatch @(%d,%d): want %02x got %02x\n",
						       c, r, want, got);
					bad++;
				}
			}
		uint8_t *uv8 = d12.mem + (size_t)w * h;
		for (int i = 0; i < w * h / 2; i++)
			if (uv8[i] != 0x80)
				uvbad++;
		buf_sync(&d12, DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ);
		printf("NV15->NV12 %s (Y bad %d/%d, UV off-neutral %d/%d)\n",
		       (bad || uvbad) ? "CORRUPT" : "OK", bad, w * h, uvbad, w * h / 2);
		failures += (bad || uvbad) ? 1 : 0;
	}

	/* case 2: P010 -> NV15 (compact write, CPU-unpacked check) */
	ret = imcvtcolor(src10, dst15, FMT_P010, FMT_NV15);
	if (ret != IM_STATUS_SUCCESS) {
		printf("P010->NV15 submit FAILED: %s\n", imStrError((IM_STATUS)ret));
		failures++;
	} else {
		int bad = 0, uvbad = 0;
		buf_sync(&d15, DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ);
		for (int r = 0; r < h; r++)
			for (int c = 0; c < w; c++) {
				uint16_t want = y10(r, c);
				uint16_t got = pack10_get(d15.mem + (size_t)r * w * 10 / 8, c);
				if (want != got) {
					if (!bad)
						printf("P010->NV15 first Y mismatch @(%d,%d): want %03x got %03x\n",
						       c, r, want, got);
					bad++;
				}
			}
		uint8_t *uv = d15.mem + (size_t)w * h * 10 / 8;
		for (int i = 0; i < w * h / 2; i++)
			if (pack10_get(uv, i) != 0x200)
				uvbad++;
		buf_sync(&d15, DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ);
		printf("P010->NV15 %s (Y bad %d/%d, UV off-neutral %d/%d)\n",
		       (bad || uvbad) ? "CORRUPT" : "OK", bad, w * h, uvbad, w * h / 2);
		failures += (bad || uvbad) ? 1 : 0;
	}

	/* case 3: NV15 -> NV15 copy */
	ret = imcopy(src15, dstcp);
	if (ret != IM_STATUS_SUCCESS) {
		printf("NV15->NV15 submit FAILED: %s\n", imStrError((IM_STATUS)ret));
		failures++;
	} else {
		buf_sync(&dcp, DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ);
		int cmpres = memcmp(s15.mem, dcp.mem, nv15_size);
		buf_sync(&dcp, DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ);
		printf("NV15->NV15 copy %s\n", cmpres ? "CORRUPT" : "BIT-EXACT");
		failures += cmpres ? 1 : 0;
	}

	printf("nv15-test: %s (%d failing case%s)\n",
	       failures ? "FAIL" : "PASS", failures, failures == 1 ? "" : "s");
	return failures ? 1 : 0;
}
