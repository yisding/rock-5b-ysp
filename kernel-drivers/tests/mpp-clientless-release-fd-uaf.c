// Minimal deterministic reproducer for the MPP client-less RELEASE_FD NULL deref.
//
// A session that opens /dev/mpp_service but never issues MPP_CMD_INIT_CLIENT_TYPE
// has session->dma == NULL (session->dma is allocated only at client bind,
// mpp_common.c:1425). The MPP_CMD_RELEASE_FD arm of mpp_process_request()
// calls mpp_dma_release_fd(session->dma, fd) with no NULL guard, and
// mpp_dma_release_fd() dereferences dma->dev as its first statement
// (mpp_iommu.c:182) -> NULL->dev at offset 6936 (0x1b18), matching the
// observed fault address dfff800000000363 (KASAN shadow of 0x1b18).
//
// Expected on a vulnerable kernel: an oops at mpp_dma_release_fd. Run only on a
// disposable KASAN debug board with kernel.panic_on_oops=0 so the full call
// trace prints and the machine survives.
//
// See findings/2026-07-21-mpp-collect-msgs-clientless-session-null-deref-crash.md
#include <fcntl.h>
#include <stdint.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define MPP_IOC_MAGIC 'v'
#define MPP_IOC_CFG_V1 _IOW(MPP_IOC_MAGIC, 1, unsigned int)

#define MPP_CMD_RELEASE_FD 0x402
#define MPP_FLAGS_LAST_MSG 0x00000002

struct mpp_msg_v1 {
	uint32_t cmd;
	uint32_t flags;
	uint32_t size;
	uint32_t offset;
	uint64_t data_ptr;
};

int main(void)
{
	int fd = open("/dev/mpp_service", O_RDWR | O_CLOEXEC);

	if (fd < 0) {
		perror("open /dev/mpp_service");
		return 2;
	}

	/* Deliberately DO NOT send MPP_CMD_INIT_CLIENT_TYPE: session->dma stays NULL. */

	uint32_t fds[1] = { 0 };
	struct mpp_msg_v1 msg = {
		.cmd = MPP_CMD_RELEASE_FD,
		.flags = MPP_FLAGS_LAST_MSG,
		.size = sizeof(fds),
		.offset = 0,
		.data_ptr = (uint64_t)(uintptr_t)fds,
	};

	fprintf(stderr, "sending clientless RELEASE_FD (session->dma is NULL) ...\n");
	errno = 0;
	int ret = ioctl(fd, MPP_IOC_CFG_V1, &msg);
	int err = ret ? errno : 0;
	fprintf(stderr, "ioctl returned %d (errno=%d)\n", ret, err);

	close(fd);

	/*
	 * Surviving the ioctl is necessary but not sufficient, and the old message
	 * claimed "kernel is NOT vulnerable" for ANY return -- including 0. Patch
	 * 0057 makes this path return -EINVAL:
	 *     if (!session->dma) ... return -EINVAL;
	 * A kernel that silently accepted a clientless RELEASE_FD, or one that
	 * rejected the message earlier for an unrelated reason without ever reaching
	 * the guard, was indistinguishable from the fix.
	 */
	if (ret == 0) {
		fprintf(stderr, "FAIL: clientless RELEASE_FD was ACCEPTED - the 0057 guard is "
			"absent and this kernel dereferenced a NULL session->dma or skipped the "
			"check entirely\n");
		return 1;
	}
	if (err != EINVAL) {
		fprintf(stderr, "FAIL: rejected with errno=%d, expected EINVAL (%d) from the "
			"0057 guard; the message may have been refused before reaching it\n",
			err, EINVAL);
		return 1;
	}
	fprintf(stderr, "PASS: clientless RELEASE_FD rejected with -EINVAL; the 0057 guard "
		"holds and the board is up\n");
	return 0;
}
