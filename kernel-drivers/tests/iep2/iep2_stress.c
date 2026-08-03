/*
 * IEP2 teardown and import-churn stress.
 *
 * Three phases, all in I1O1T so the reserved auxiliary IOVA path is exercised:
 *
 *   churn  - fresh dma-bufs per task, to show the auxiliary reservation
 *            neither collides nor leaks across sequential imports
 *   abort  - submit a task then close the session immediately without polling,
 *            racing teardown against work the hardware may still be running
 *   mixed  - several processes doing both at once, against one device
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>
#include <linux/dma-heap.h>

#include "rk_type.h"
#include "mpp_service.h"
#include "iep2_api.h"
#include "iep2.h"

#define W               720
#define H               480

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

static void baseline(struct iep2_params *p, int fd_y, int fd_mv, int fd_md)
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

    p->src[0].y = fd_y;
    p->src[0].cbcr = fd_y;
    p->src[0].cr = fd_y;
    p->src[1] = p->src[0];
    p->src[2] = p->src[0];
    p->dst[0] = p->src[0];
    p->dst[1] = p->src[0];
    p->mv_addr = fd_mv;
    p->md_addr = fd_md;
}

static int post(int fd, struct iep2_params *p, struct iep2_output *o)
{
    MppReqV1 req[2];

    memset(req, 0, sizeof(req));
    req[0].cmd = MPP_CMD_SET_REG_WRITE;
    req[0].flag = MPP_FLAGS_MULTI_MSG;
    req[0].size = sizeof(*p);
    req[0].data_ptr = REQ_DATA_PTR(p);

    req[1].cmd = MPP_CMD_SET_REG_READ;
    req[1].flag = MPP_FLAGS_MULTI_MSG | MPP_FLAGS_LAST_MSG;
    req[1].size = sizeof(*o);
    req[1].data_ptr = REQ_DATA_PTR(o);

    return ioctl(fd, MPP_IOC_CFG_V1, &req[0]) ? -errno : 0;
}

static int wait_done(int fd)
{
    MppReqV1 poll;

    memset(&poll, 0, sizeof(poll));
    poll.cmd = MPP_CMD_POLL_HW_FINISH;
    poll.flag = MPP_FLAGS_LAST_MSG;

    return ioctl(fd, MPP_IOC_CFG_V1, &poll) ? -errno : 0;
}

/* Fresh buffers every iteration: new imports, new IOVA mappings. */
static int phase_churn(int iters)
{
    struct iep2_params p;
    struct iep2_output o;
    size_t frame = (size_t)W * H * 3 / 2;
    int i, bad = 0;

    for (i = 0; i < iters; i++) {
        int fd_y = heap_alloc(frame * 2);
        int fd_mv = heap_alloc(120 * 480);
        int fd_md = heap_alloc(1920 * 1088);
        int fd = iep2_open();

        if (fd_y < 0 || fd_mv < 0 || fd_md < 0 || fd < 0) {
            printf("churn %d: setup failed\n", i);
            bad++;
        } else {
            memset(&o, 0, sizeof(o));
            baseline(&p, fd_y, fd_mv, fd_md);
            if (post(fd, &p, &o) || wait_done(fd)) {
                printf("churn %d: task failed (%s)\n", i, strerror(errno));
                bad++;
            }
        }

        if (fd >= 0)
            close(fd);
        if (fd_y >= 0)
            close(fd_y);
        if (fd_mv >= 0)
            close(fd_mv);
        if (fd_md >= 0)
            close(fd_md);
    }

    return bad;
}

/* Submit, then tear the session down without ever polling for completion. */
static int phase_abort(int iters)
{
    struct iep2_params p;
    struct iep2_output o;
    size_t frame = (size_t)W * H * 3 / 2;
    int i;

    for (i = 0; i < iters; i++) {
        int fd_y = heap_alloc(frame * 2);
        int fd_mv = heap_alloc(120 * 480);
        int fd_md = heap_alloc(1920 * 1088);
        int fd = iep2_open();

        if (fd_y >= 0 && fd_mv >= 0 && fd_md >= 0 && fd >= 0) {
            memset(&o, 0, sizeof(o));
            baseline(&p, fd_y, fd_mv, fd_md);
            post(fd, &p, &o);
            /* deliberately no wait_done() - close races the running task */
        }

        if (fd >= 0)
            close(fd);
        if (fd_y >= 0)
            close(fd_y);
        if (fd_mv >= 0)
            close(fd_mv);
        if (fd_md >= 0)
            close(fd_md);
    }

    return 0;
}

int main(int argc, char **argv)
{
    int iters = (argc > 1) ? atoi(argv[1]) : 100;
    int procs = (argc > 2) ? atoi(argv[2]) : 4;
    int i, bad = 0, status;

    printf("phase churn: %d sequential imports\n", iters);
    bad += phase_churn(iters);

    printf("phase abort: %d close-vs-completion races\n", iters);
    phase_abort(iters);

    printf("phase mixed: %d processes x %d iterations\n", procs, iters);
    for (i = 0; i < procs; i++) {
        pid_t pid = fork();

        if (pid == 0) {
            int rc = phase_churn(iters / 2);

            phase_abort(iters / 2);
            _exit(rc ? 1 : 0);
        }
    }
    while (wait(&status) > 0) {
        if (!WIFEXITED(status) || WEXITSTATUS(status))
            bad++;
    }

    printf("\n%s (%d problems)\n", bad ? "FAILURES" : "all phases clean", bad);

    return bad ? 1 : 0;
}
