// SPDX-FileCopyrightText: 2026 Yi Ding
// SPDX-License-Identifier: Apache-2.0
/*
 * IEP2 address-encoding race.
 *
 * The driver reads addresses two ways depending on a per-message flag: packed
 * (fd in the low 10 bits, byte offset above) or MPP_FLAGS_REG_OFFSET_ALONE (the
 * whole word is the fd, offset comes from the separate offset table).
 *
 * The same address word therefore has to mean different things in consecutive
 * tasks on one session. A word carrying a nonzero packed offset is a valid
 * address packed, and a nonsense fd unpacked, so alternating it between the two
 * encodings must alternate accept/reject exactly. If the driver ever latched
 * the flag per session instead of per task, the pattern would break.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <linux/dma-heap.h>

#include "rk_type.h"
#include "mpp_service.h"
#include "iep2_api.h"
#include "iep2.h"

#define W       720
#define H       480

static int heap_alloc(size_t len)
{
    struct dma_heap_allocation_data d;
    int hfd = open("/dev/dma_heap/system", O_RDWR | O_CLOEXEC);

    if (hfd < 0)
        return -1;

    memset(&d, 0, sizeof(d));
    d.len = len;
    d.fd_flags = O_CLOEXEC | O_RDWR;
    if (ioctl(hfd, DMA_HEAP_IOCTL_ALLOC, &d) < 0) {
        close(hfd);
        return -1;
    }
    close(hfd);

    return d.fd;
}

static int iep2_open(void)
{
    MppReqV1 req;
    RK_U32 client = 28;
    int fd = open("/dev/mpp_service", O_RDWR | O_CLOEXEC);

    if (fd < 0)
        return -1;

    memset(&req, 0, sizeof(req));
    req.cmd = MPP_CMD_INIT_CLIENT_TYPE;
    req.size = sizeof(client);
    req.data_ptr = REQ_DATA_PTR(&client);

    if (ioctl(fd, MPP_IOC_CFG_V1, &req)) {
        close(fd);
        return -1;
    }

    return fd;
}

static void baseline(struct iep2_params *p, RK_U32 addr_y, int fd_mv, int fd_md)
{
    memset(p, 0, sizeof(*p));

    p->src_fmt = IEP2_FMT_YUV420;
    p->src_yuv_swap = IEP2_YUV_SWAP_SP_UV;
    p->dst_fmt = IEP2_FMT_YUV420;
    p->dst_yuv_swap = IEP2_YUV_SWAP_SP_UV;
    p->src_y_stride = W / 4;
    p->src_uv_stride = W / 4;
    p->dst_y_stride = W / 4;
    p->tile_cols = W / 16;
    p->tile_rows = H / 4;
    p->dil_mode = IEP2_DIL_MODE_I1O1T;
    p->dil_out_mode = IEP2_OUT_MODE_LINE;
    p->dil_field_order = IEP2_FIELD_ORDER_TFF;
    p->md_theta = 1;
    p->md_r = 6;
    p->md_lambda = 4;
    p->dect_resi_thr = 30;
    p->osd_gradh_thr = 60;
    p->osd_gradv_thr = 60;
    p->osd_pec_thr = 20;
    p->osd_line_num = 2;
    p->me_pena = 5;
    p->mv_similar_thr = 4;
    p->mv_similar_num_thr0 = 4;
    p->mv_bonus = 10;
    p->me_thr_offset = 20;
    p->mv_left_limit = 28;
    p->mv_right_limit = 27;
    p->eedi_thr0 = 12;
    memset(p->comb_osd_vld, 1, sizeof(p->comb_osd_vld));
    p->comb_t_thr = 4;
    p->comb_feature_thr = 16;
    p->comb_cnt_thr = 0;
    p->ble_backtoma_num = 1;
    p->mtn_en = 1;

    p->src[0].y = addr_y;
    p->src[0].cbcr = addr_y;
    p->src[0].cr = addr_y;
    p->src[1] = p->src[0];
    p->src[2] = p->src[0];
    p->dst[0] = p->src[0];
    p->dst[1] = p->src[0];
    p->mv_addr = fd_mv;
    p->md_addr = fd_md;
}

static int run(int fd, struct iep2_params *p, struct iep2_output *o, RK_U32 flag)
{
    MppReqV1 req[2], poll;

    memset(req, 0, sizeof(req));
    req[0].cmd = MPP_CMD_SET_REG_WRITE;
    req[0].flag = MPP_FLAGS_MULTI_MSG | flag;
    req[0].size = sizeof(*p);
    req[0].data_ptr = REQ_DATA_PTR(p);

    req[1].cmd = MPP_CMD_SET_REG_READ;
    req[1].flag = MPP_FLAGS_MULTI_MSG | MPP_FLAGS_LAST_MSG;
    req[1].size = sizeof(*o);
    req[1].data_ptr = REQ_DATA_PTR(o);

    if (ioctl(fd, MPP_IOC_CFG_V1, &req[0]))
        return -errno;

    memset(&poll, 0, sizeof(poll));
    poll.cmd = MPP_CMD_POLL_HW_FINISH;
    poll.flag = MPP_FLAGS_LAST_MSG;

    return ioctl(fd, MPP_IOC_CFG_V1, &poll) ? -errno : 0;
}

int main(int argc, char **argv)
{
    int rounds = (argc > 1) ? atoi(argv[1]) : 50;
    struct iep2_params p;
    struct iep2_output o;
    size_t frame = (size_t)W * H * 3 / 2;
    int fd, fd_y, fd_mv, fd_md, i, bad = 0;
    RK_U32 packed;

    fd_y = heap_alloc(frame * 4);
    fd_mv = heap_alloc(120 * 480);
    fd_md = heap_alloc(1920 * 1088);
    fd = iep2_open();

    if (fd < 0 || fd_y < 0 || fd_mv < 0 || fd_md < 0) {
        printf("setup failed\n");
        return 2;
    }

    /* fd in the low 10 bits, a 4096-byte offset above it */
    packed = (RK_U32)fd_y | (4096u << 10);
    printf("fd_y=%d packed word=0x%08x (unpacked that word is fd %u)\n",
           fd_y, packed, packed);

    memset(&o, 0, sizeof(o));

    for (i = 0; i < rounds; i++) {
        int rc_packed, rc_raw;

        baseline(&p, packed, fd_mv, fd_md);
        rc_packed = run(fd, &p, &o, 0);

        baseline(&p, packed, fd_mv, fd_md);
        rc_raw = run(fd, &p, &o, MPP_FLAGS_REG_OFFSET_ALONE);

        if (rc_packed != 0) {
            printf("round %d: packed encoding rejected (rc=%d)\n", i, rc_packed);
            bad++;
        }
        if (rc_raw == 0) {
            printf("round %d: NO_OFFSET accepted a bogus fd\n", i);
            bad++;
        }
    }

    /* interleave the other way round, in case ordering matters */
    for (i = 0; i < rounds; i++) {
        int rc_raw, rc_packed;

        baseline(&p, packed, fd_mv, fd_md);
        rc_raw = run(fd, &p, &o, MPP_FLAGS_REG_OFFSET_ALONE);

        baseline(&p, packed, fd_mv, fd_md);
        rc_packed = run(fd, &p, &o, 0);

        if (rc_raw == 0) {
            printf("reverse round %d: NO_OFFSET accepted a bogus fd\n", i);
            bad++;
        }
        if (rc_packed != 0) {
            printf("reverse round %d: packed rejected after NO_OFFSET (rc=%d)\n",
                   i, rc_packed);
            bad++;
        }
    }

    close(fd);
    close(fd_y);
    close(fd_mv);
    close(fd_md);

    printf("%s: %d rounds each way, %d deviations\n",
           bad ? "FAIL" : "PASS", rounds, bad);

    return bad ? 1 : 0;
}
