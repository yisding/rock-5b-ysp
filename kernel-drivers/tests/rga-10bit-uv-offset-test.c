/* Legacy RGA_BLIT 10-bit UV plane-offset gate probe (chroma CORRECTNESS).
 *
 * Sibling of rga-10bit-legacy-stride-test.c.  That probe asks "does the blit
 * survive a tightly sized surface?" -- a SIZE question.  This one asks "did
 * the chroma come from the right place?" -- a CONTENT question -- and the two
 * fail independently:
 *
 *   - Kernel 0072 made the RGA3 *stride* byte-literal but left 0049's sibling
 *     site, rga_convert_addr(), scaling vir_w by the pixel depth (x10/8
 *     compact, x2 incompact) to derive the UV plane offset.  On a tightly
 *     sized surface that over-reads and faults; on an over-sized surface it
 *     SUCCEEDS and silently returns chroma read from the wrong offset.
 *   - The silent case is why the GStreamer NV12_10 cases reported pass on the
 *     0072 kernel: their buffers were merely large enough to absorb the
 *     over-read.  A size-only gate cannot see that.  Hence this probe.
 *
 * Method.  The source is deliberately OVER-allocated so that neither the
 * correct nor the scaled offset can fault -- isolating correctness from the
 * size fault.  Rather than modelling the 10-bit -> NV12 colour conversion
 * (whose exact output bytes we would have to predict), the probe runs the
 * SAME blit three times and compares destination chroma between runs:
 *
 *      region        | run A | run B | run C     read by
 *      --------------+-------+-------+-------    -----------------
 *      true-only     |   P   |  P'   |   P       the correct offset only
 *      overlap       |   C   |   C   |   C       both offsets (held constant)
 *      buggy-only    |   Q   |   Q   |  Q'       the scaled offset only
 *
 *   fixed kernel  => B differs from A (it read true-only), C equals A
 *   buggy kernel  => B equals A, C differs from A (it read buggy-only)
 *
 * That is a self-referential discriminator: it needs no model of the colour
 * pipeline, and it cannot be satisfied by a blit that merely fails to fault.
 *
 * Buffers are dma-heap fds (default_cma_region, below 4G) so the RGA2 control
 * leg is not perturbed by the RGA2 over-4G userptr limitation.
 * fd convention: yrgb_addr = fd.
 *
 * RASTER and TILE8x8 are both covered.  10-bit vir_w is a BYTE stride in every
 * uncompressed mode -- the `* 8` in the kernel's TILE stride expression is the
 * eight-lines-per-tile-block factor, not a pixel-depth scale, and
 * rga_convert_addr() has no rd_mode distinction at all.  TILE 10-bit previously
 * had no coverage anywhere in this project, and it is the mode where the
 * pixel-convention misreading survived longest (librga fork b8def3e gated its
 * pixel->byte conversion on raster; fixed in 4c26ddf).  See
 * findings/2026-07-24-rga-10bit-tile-byte-stride-and-fbc-exception.md.
 *
 * Each mode is gated twice: the chroma discriminator above (over-allocated, so
 * it isolates CONTENT), and a tightly sized blit (so a scaled plane offset has
 * nowhere to read and must fail).
 *
 * Usage: rga-10bit-uv-offset-test [core-mask] [heap-path]
 *   core-mask: 1=RGA3 core0, 2=RGA3 core1, 4=RGA2, 0=scheduler default
 *              (default: 0).  TILE8x8 is an RGA3 feature; RGA2 has no
 *              rd_mode TILE support and will reject those cases.
 * Pass criterion: in every mode, chroma tracks the byte-literal offset,
 * ignores the scaled one, AND a tightly sized surface blits clean.
 * Exit 0 = pass.
 * Build like legacy-blit-test.c: shim empty linux/mutex.h +
 * linux/scatterlist.h and -Du8=uint8_t -Du16=uint16_t -Du32=uint32_t
 * -Du64=uint64_t against the forward-port tree's rga3/include/rga.h.
 * See findings/2026-07-24-rga-10bit-uv-plane-offset-still-pixel-scaled.md.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
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
#define SRC_STRIDE_BYTES 448		/* legacy BYTE stride for 10-bit */

#define Y_TRUE   ((size_t)SRC_STRIDE_BYTES * SRC_H)		/* 107520 */
#define UV_BYTES ((size_t)SRC_STRIDE_BYTES * SRC_H / 2)		/* 53760  */

#define MARK_C 0x55	/* overlap: constant across all three runs */
#define MARK_P 0x20
#define MARK_P2 0xE0
#define MARK_Q 0x90
#define MARK_Q2 0x11

static int heap_alloc(const char *path, size_t len)
{
	struct dma_heap_allocation_data d = { .len = len, .fd_flags = O_RDWR | O_CLOEXEC };
	int hf = open(path, O_RDONLY | O_CLOEXEC);

	if (hf < 0) { perror(path); return -1; }
	if (ioctl(hf, DMA_HEAP_IOCTL_ALLOC, &d) < 0) {
		perror("heap alloc");
		close(hf);
		return -1;
	}
	close(hf);
	return d.fd;
}

static void fill_range(uint8_t *base, size_t lo, size_t hi, uint8_t v)
{
	if (hi > lo)
		memset(base + lo, v, hi - lo);
}

/*
 * One blit with the given source fill; copies the destination chroma plane
 * into `chroma_out`.  Returns 0 on success, -1 if the blit failed.
 */
static int run_once(int fd, int sfd, int dfd, uint8_t *s, uint8_t *d,
		    size_t alloc, int compact_mode, size_t y_buggy,
		    uint8_t p, uint8_t q, int core, int rd_mode,
		    int quiet, uint8_t *chroma_out)
{
	struct rga_req req;
	size_t true_lo = Y_TRUE, true_hi = Y_TRUE + UV_BYTES;
	size_t buggy_lo = y_buggy, buggy_hi = y_buggy + UV_BYTES;
	size_t ov_lo, ov_hi;
	int ret;

	/*
	 * Clamp every marker window to the mapping before writing into it.
	 * check_tight deliberately sizes the surface so the scaled window runs
	 * off the end -- the kernel reading past it is exactly what the gate
	 * tests -- but the harness must not walk off it first. `alloc` was
	 * accepted here and then thrown away with `(void)alloc`, so check_tight
	 * memset 26880 bytes past a 161280-byte mapping and died of SIGSEGV
	 * before reaching its own ioctl. That killed the process at the first
	 * tight check, so the two later checks never ran, the verdict line never
	 * printed, and the exit status was 139: the gate could not pass on any
	 * kernel, correct or broken.
	 */
	if (true_lo > alloc)
		true_lo = alloc;
	if (true_hi > alloc)
		true_hi = alloc;
	if (buggy_lo > alloc)
		buggy_lo = alloc;
	if (buggy_hi > alloc)
		buggy_hi = alloc;
	ov_lo = true_lo > buggy_lo ? true_lo : buggy_lo;
	ov_hi = true_hi < buggy_hi ? true_hi : buggy_hi;

	/* Y plane, then the three marker regions. */
	fill_range(s, 0, Y_TRUE < alloc ? Y_TRUE : alloc, 0x00);
	fill_range(s, true_lo, true_hi, p);		/* true UV window   */
	fill_range(s, buggy_lo, buggy_hi, q);		/* scaled UV window */
	if (ov_hi > ov_lo)				/* shared part      */
		fill_range(s, ov_lo, ov_hi, MARK_C);
	/* anything past both windows stays whatever it was; never read */
	memset(d, 0x5a, (size_t)SRC_W * SRC_H * 3 / 2);

	memset(&req, 0, sizeof(req));
	req.render_mode = 0;
	req.src.yrgb_addr = sfd;
	req.src.vir_w = SRC_STRIDE_BYTES;
	req.src.vir_h = SRC_H;
	req.src.act_w = SRC_W;
	req.src.act_h = SRC_H;
	req.src.format = RGA_FORMAT_YCbCr_420_SP_10B;
	req.src.rd_mode = rd_mode;
	req.src.compact_mode = compact_mode;

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
	if (ret) {
		if (!quiet)
			printf("    blit FAILED ret=%d errno=%d (%s)\n",
			       ret, errno, strerror(errno));
		return -1;
	}
	if (chroma_out)
		memcpy(chroma_out, d + (size_t)SRC_W * SRC_H,
		       (size_t)SRC_W * SRC_H / 2);
	return 0;
}

static int check_mode(int fd, int sfd, int dfd, uint8_t *s, uint8_t *d,
		      size_t alloc, int compact_mode, int core,
		      int rd_mode, const char *mode_name)
{
	const char *name = compact_mode == RGA_10BIT_INCOMPACT ? "incompact" : "compact";
	size_t y_buggy = compact_mode == RGA_10BIT_INCOMPACT
			 ? Y_TRUE * 2 : Y_TRUE * 10 / 8;
	size_t clen = (size_t)SRC_W * SRC_H / 2;
	uint8_t *ca = malloc(clen), *cb = malloc(clen), *cc = malloc(clen);
	int reads_true, reads_buggy, rc = 1;

	if (!ca || !cb || !cc) { perror("malloc"); goto out; }

	printf("  [%s/%s] true UV offset %zu, scaled UV offset %zu\n",
	       mode_name, name, Y_TRUE, y_buggy);

	if (run_once(fd, sfd, dfd, s, d, alloc, compact_mode, y_buggy,
		     MARK_P, MARK_Q, core, rd_mode, 0, ca))
		goto out;
	if (run_once(fd, sfd, dfd, s, d, alloc, compact_mode, y_buggy,
		     MARK_P2, MARK_Q, core, rd_mode, 0, cb))	/* vary true-only */
		goto out;
	if (run_once(fd, sfd, dfd, s, d, alloc, compact_mode, y_buggy,
		     MARK_P, MARK_Q2, core, rd_mode, 0, cc))	/* vary buggy-only */
		goto out;

	reads_true = memcmp(ca, cb, clen) != 0;
	reads_buggy = memcmp(ca, cc, clen) != 0;

	printf("    chroma tracks true-offset bytes: %s\n", reads_true ? "yes" : "NO");
	printf("    chroma tracks scaled-offset bytes: %s\n", reads_buggy ? "YES" : "no");

	if (reads_true && !reads_buggy) {
		printf("    [%s/%s] PASS: UV read from the byte-literal offset\n",
		       mode_name, name);
		rc = 0;
	} else if (!reads_true && reads_buggy) {
		printf("    [%s/%s] FAIL: UV read from the pixel-scaled offset "
		       "(rga_convert_addr still scaling vir_w)\n", mode_name, name);
	} else if (reads_true && reads_buggy) {
		printf("    [%s/%s] FAIL: chroma depends on BOTH windows "
		       "(partial/overlapping read)\n", mode_name, name);
	} else {
		printf("    [%s/%s] FAIL: chroma ignored both windows "
		       "(no source dependence -- check the fixture)\n", mode_name, name);
	}
out:
	free(ca); free(cb); free(cc);
	return rc;
}

/*
 * The size half of the gate: a surface sized to exactly what the byte-literal
 * convention needs.  A scaled plane offset has nowhere to read and must fail;
 * a correct kernel completes the blit.
 */
static int check_tight(int fd, const char *heap, int core, int rd_mode,
		       const char *mode_name)
{
	size_t tight = Y_TRUE + UV_BYTES;
	size_t dst_size = (size_t)SRC_W * SRC_H * 3 / 2;
	int sfd = heap_alloc(heap, tight), dfd = heap_alloc(heap, dst_size);
	uint8_t *s, *d;
	int ret;

	if (sfd < 0 || dfd < 0)
		return 1;
	s = mmap(NULL, tight, PROT_READ | PROT_WRITE, MAP_SHARED, sfd, 0);
	d = mmap(NULL, dst_size, PROT_READ | PROT_WRITE, MAP_SHARED, dfd, 0);
	if (s == MAP_FAILED || d == MAP_FAILED) { perror("mmap"); return 1; }
	memset(s, 0x40, tight);

	ret = run_once(fd, sfd, dfd, s, d, tight, 0, Y_TRUE * 10 / 8,
		       MARK_P, MARK_Q, core, rd_mode, 1, NULL);
	printf("  [%s] tightly sized %zu B (Y %zu + UV %zu): %s\n",
	       mode_name, tight, Y_TRUE, UV_BYTES,
	       ret ? "FAIL — blit rejected/faulted" : "PASS");

	munmap(s, tight); munmap(d, dst_size);
	close(sfd); close(dfd);
	return ret ? 1 : 0;
}

int main(int argc, char **argv)
{
	int core = argc > 1 ? atoi(argv[1]) : 0;
	const char *heap = argc > 2 ? argv[2] : "/dev/dma_heap/default_cma_region";
	/* over-allocate past the widest (incompact) scaled window */
	size_t alloc = Y_TRUE * 2 + UV_BYTES + 4096;
	size_t dst_size = (size_t)SRC_W * SRC_H * 3 / 2;
	int sfd, dfd, fd, failures = 0;
	uint8_t *s, *d;

	sfd = heap_alloc(heap, alloc);
	dfd = heap_alloc(heap, dst_size);
	if (sfd < 0 || dfd < 0)
		return 2;

	s = mmap(NULL, alloc, PROT_READ | PROT_WRITE, MAP_SHARED, sfd, 0);
	d = mmap(NULL, dst_size, PROT_READ | PROT_WRITE, MAP_SHARED, dfd, 0);
	if (s == MAP_FAILED || d == MAP_FAILED) { perror("mmap"); return 2; }

	fd = open("/dev/rga", O_RDWR | O_CLOEXEC);
	if (fd < 0) { perror("open /dev/rga"); return 2; }

	printf("uv-offset gate: core=0x%x src alloc=%zu B (over-allocated so "
	       "neither offset can fault)\n", core, alloc);

	/* RASTER: both compact and incompact. */
	failures += check_mode(fd, sfd, dfd, s, d, alloc, 0, core,
			       RGA_RASTER_MODE, "raster");
	failures += check_mode(fd, sfd, dfd, s, d, alloc, RGA_10BIT_INCOMPACT,
			       core, RGA_RASTER_MODE, "raster");
	failures += check_tight(fd, heap, core, RGA_RASTER_MODE, "raster");

	/*
	 * TILE8x8: compact NV15 only -- that is the format the tile path is
	 * specified for and the one the convention bug survived in.
	 */
	failures += check_mode(fd, sfd, dfd, s, d, alloc, 0, core,
			       RGA_TILE_MODE, "tile8x8");
	failures += check_tight(fd, heap, core, RGA_TILE_MODE, "tile8x8");

	close(fd);
	printf("uv-offset-test: %s (%d failing check%s)\n",
	       failures ? "FAIL" : "PASS", failures, failures == 1 ? "" : "s");
	return failures ? 1 : 0;
}
