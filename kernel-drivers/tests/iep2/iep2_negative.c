/*
 * IEP2 negative-case harness.
 *
 * Establishes a baseline task the kernel accepts, then submits mutated
 * variants that must each be rejected synchronously, before any MMIO. Every
 * mutation is applied to a fresh copy of the accepted baseline, so a rejection
 * is attributable to that mutation and nothing else.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <linux/dma-heap.h>

#include "rk_type.h"
#include "mpp_service.h"
#include "iep2_api.h"
#include "iep2.h"

#define W               720
#define H               480
#define TILE_COLS       (W / 16)
#define TILE_ROWS       (H / 4)

static int pass_cnt, fail_cnt;

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

    if (fd < 0) {
        printf("open /dev/mpp_service: %s\n", strerror(errno));
        return -1;
    }

    memset(&req, 0, sizeof(req));
    req.cmd = MPP_CMD_INIT_CLIENT_TYPE;
    req.flag = 0;
    req.size = sizeof(client);
    req.data_ptr = REQ_DATA_PTR(&client);

    if (ioctl(fd, MPP_IOC_CFG_V1, &req)) {
        printf("init client 28: %s\n", strerror(errno));
        close(fd);
        return -1;
    }

    return fd;
}

/*
 * Submit one task and wait for it, the way a real client does.
 *
 * The submitting ioctl only queues the message batch, so a task the driver
 * refuses still returns 0 here; the refusal surfaces when the client polls for
 * completion. Both steps therefore have to be checked, or every negative case
 * looks like it was accepted.
 */
static int submit(int fd, struct iep2_params *p, struct iep2_output *o,
                  size_t psize, size_t osize, RK_U32 extra_flag)
{
    MppReqV1 req[2];
    MppReqV1 poll;

    memset(req, 0, sizeof(req));
    req[0].cmd = MPP_CMD_SET_REG_WRITE;
    req[0].flag = MPP_FLAGS_MULTI_MSG | extra_flag;
    req[0].size = psize;
    req[0].offset = 0;
    req[0].data_ptr = REQ_DATA_PTR(p);

    req[1].cmd = MPP_CMD_SET_REG_READ;
    req[1].flag = MPP_FLAGS_MULTI_MSG | MPP_FLAGS_LAST_MSG;
    req[1].size = osize;
    req[1].offset = 0;
    req[1].data_ptr = REQ_DATA_PTR(o);

    if (ioctl(fd, MPP_IOC_CFG_V1, &req[0]))
        return -errno;

    memset(&poll, 0, sizeof(poll));
    poll.cmd = MPP_CMD_POLL_HW_FINISH;
    poll.flag = MPP_FLAGS_LAST_MSG;

    if (ioctl(fd, MPP_IOC_CFG_V1, &poll))
        return -errno;

    return 0;
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
    p->tile_cols = TILE_COLS;
    p->tile_rows = TILE_ROWS;
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

static void check(const char *name, int rc, int want_reject)
{
    int ok = want_reject ? (rc != 0) : (rc == 0);

    printf("%-46s %-8s rc=%-4d %s\n", name,
           want_reject ? "reject" : "accept", rc,
           ok ? "PASS" : "*** FAIL ***");
    if (ok)
        pass_cnt++;
    else
        fail_cnt++;
}

int main(void)
{
    struct iep2_params p;
    struct iep2_output o;
    size_t frame = (size_t)W * H * 3 / 2;
    int fd, fd_y, fd_mv, fd_md, rc;

    printf("sizeof(params)=%zu sizeof(output)=%zu\n",
           sizeof(struct iep2_params), sizeof(struct iep2_output));

    fd_y = heap_alloc(frame * 2);
    fd_mv = heap_alloc(120 * 480);
    fd_md = heap_alloc(1920 * 1088);
    if (fd_y < 0 || fd_mv < 0 || fd_md < 0) {
        printf("dma-heap alloc failed\n");
        return 2;
    }

    fd = iep2_open();
    if (fd < 0)
        return 2;

    memset(&o, 0, sizeof(o));

    /* Positive control: without this the rejections below prove nothing. */
    baseline(&p, fd_y, fd_mv, fd_md);
    rc = submit(fd, &p, &o, sizeof(p), sizeof(o), 0);
    check("baseline valid task", rc, 0);
    if (rc) {
        printf("\nbaseline was rejected; negative results are not meaningful\n");
        close(fd);
        return 2;
    }

    /* 1. exact request-size validation on params */
    baseline(&p, fd_y, fd_mv, fd_md);
    check("param size too small", submit(fd, &p, &o, sizeof(p) - 4, sizeof(o), 0), 1);
    baseline(&p, fd_y, fd_mv, fd_md);
    check("param size too large", submit(fd, &p, &o, sizeof(p) + 4, sizeof(o), 0), 1);

    /* 2. exact request-size validation on result */
    baseline(&p, fd_y, fd_mv, fd_md);
    check("result size too small", submit(fd, &p, &o, sizeof(p), sizeof(o) - 4, 0), 1);
    baseline(&p, fd_y, fd_mv, fd_md);
    check("result size too large", submit(fd, &p, &o, sizeof(p), sizeof(o) + 4, 0), 1);

    /* 3. untranslated DMA addresses must be refused outright */
    baseline(&p, fd_y, fd_mv, fd_md);
    check("MPP_FLAGS_REG_FD_NO_TRANS (raw IOVA)",
          submit(fd, &p, &o, sizeof(p), sizeof(o), MPP_FLAGS_REG_FD_NO_TRANS), 1);

    /* 4. packed nonzero address word carrying fd 0 */
    baseline(&p, fd_y, fd_mv, fd_md);
    p.src[0].y = 0x00010000;
    check("packed nonzero address with fd 0", submit(fd, &p, &o, sizeof(p), sizeof(o), 0), 1);

    /* 5. missing fd */
    baseline(&p, fd_y, fd_mv, fd_md);
    p.md_addr = 0;
    check("md_addr fd 0 (missing fd)", submit(fd, &p, &o, sizeof(p), sizeof(o), 0), 1);
    baseline(&p, fd_y, fd_mv, fd_md);
    p.src[0].y = 4095;
    check("src fd that was never opened", submit(fd, &p, &o, sizeof(p), sizeof(o), 0), 1);

    /* 6. span overruns the md buffer (the >1080p case userspace refuses) */
    baseline(&p, fd_y, fd_mv, fd_md);
    p.tile_cols = 1920 / 16;
    p.tile_rows = 1104 / 4;
    p.src_y_stride = 1920 / 4;
    p.src_uv_stride = 1920 / 4;
    p.dst_y_stride = 1920 / 4;
    check("md span 1920x1104 over md_buf", submit(fd, &p, &o, sizeof(p), sizeof(o), 0), 1);

    /* 7. undersized source buffer for the declared geometry */
    baseline(&p, fd_y, fd_mv, fd_md);
    p.tile_cols = 1920 / 16;
    p.tile_rows = 1088 / 4;
    p.src_y_stride = 1920 / 4;
    p.src_uv_stride = 1920 / 4;
    p.dst_y_stride = 1920 / 4;
    check("1080p geometry on a 720x480 buffer", submit(fd, &p, &o, sizeof(p), sizeof(o), 0), 1);

    /* 8. stride smaller than a row */
    baseline(&p, fd_y, fd_mv, fd_md);
    p.src_y_stride = 1;
    check("src_y_stride below row width", submit(fd, &p, &o, sizeof(p), sizeof(o), 0), 1);
    baseline(&p, fd_y, fd_mv, fd_md);
    p.dst_y_stride = 1;
    check("dst_y_stride below row width", submit(fd, &p, &o, sizeof(p), sizeof(o), 0), 1);

    /* 9. degenerate geometry */
    baseline(&p, fd_y, fd_mv, fd_md);
    p.tile_cols = 0;
    check("tile_cols 0", submit(fd, &p, &o, sizeof(p), sizeof(o), 0), 1);
    baseline(&p, fd_y, fd_mv, fd_md);
    p.tile_rows = 0xffffffff;
    check("tile_rows 0xffffffff (overflow probe)", submit(fd, &p, &o, sizeof(p), sizeof(o), 0), 1);

    /* 10. invalid enum values */
    baseline(&p, fd_y, fd_mv, fd_md);
    p.dil_mode = 0xdead;
    check("dil_mode 0xdead", submit(fd, &p, &o, sizeof(p), sizeof(o), 0), 1);
    baseline(&p, fd_y, fd_mv, fd_md);
    p.src_fmt = 0xbeef;
    check("src_fmt 0xbeef", submit(fd, &p, &o, sizeof(p), sizeof(o), 0), 1);

    /* Baseline must still be accepted after all the rejections. */
    baseline(&p, fd_y, fd_mv, fd_md);
    check("baseline still valid after mutations",
          submit(fd, &p, &o, sizeof(p), sizeof(o), 0), 0);

    close(fd);
    close(fd_y);
    close(fd_mv);
    close(fd_md);

    printf("\n%d passed, %d failed\n", pass_cnt, fail_cnt);

    return fail_cnt ? 1 : 0;
}
