// =============================================================================
// rga-iommu-fuzz.cpp -- RGA3 scattered-userptr IOMMU correctness fuzzer.
//
// The stock librga demos only ever hand the driver userptr buffers that happen
// to be physically contiguous, so dma_map_sg() coalesces to one segment and the
// driver-owned IOMMU remap fallback is never exercised. This tool
// deterministically forces the scattered path and checks the result is correct.
//
// HOW IT FORCES SCATTER
//   A userptr needs a *contiguous virtual* range, but its backing physical pages
//   can be arbitrary. We mmap the buffer region A and an equal spacer region B,
//   MADV_NOHUGEPAGE both, then fault them PAGE-INTERLEAVED (A[0],B[0],A[1],B[1]..).
//   The buddy allocator hands A's consecutive virtual pages non-adjacent PFNs, so
//   dma_map_sg() cannot coalesce -> nents ~= npages -> the remap path must run.
//   B stays mapped so A stays fragmented. On the pre-remap kernel this exact
//   buffer fails closed / MMU-faults, so success+correct-output proves the
//   driver-owned IOMMU path ran.
//
// ORACLES (video/2D ops are deterministic, so results are bit-exact)
//   copy   : ABSOLUTE  -- output must equal the known input pattern.
//   all ops: DIFFERENTIAL -- op(scattered_src) must equal op(contiguous_src);
//            and for the write path, op()->scattered_dst == op()->contiguous_dst.
//   A scatter-induced bug (wrong base+offset, off-by-page, or non-coherent cache
//   staleness on this non-coherent device) shows up as a byte mismatch.
//
// Exit 0 iff every check passed. Non-zero + first-diff report on any mismatch.
// Build: see rga-iommu-fuzz.sh (g++ -I<librga>/include -L<librga>/libs ... -lrga)
// =============================================================================
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <cerrno>
#include <string>
#include <vector>
#include <sys/mman.h>
#include <unistd.h>

#include "im2d.h"
#include "rga.h"

static const size_t PAGE = 4096;
static const size_t CACHE_ALIGN = 64;
static const uint8_t GUARD_BYTE = 0xD3;
// RGA3 on RK3588 advertises a 68-pixel minimum width. Keep generated
// dimensions on 16-pixel boundaries, so 80 is the first valid width.
static const int RGA3_MIN_WIDTH = 80;
static const int RGA3_MIN_RESIZE_SRC_WIDTH = RGA3_MIN_WIDTH * 2;

struct Buf {
    uint8_t *map = nullptr;   size_t map_len = 0;   // the buffer region (VA-contiguous)
    uint8_t *spacer = nullptr; size_t spacer_len = 0; // fragmenting spacer, kept resident
    uint8_t *data = nullptr;                          // map + byte_offset (sub-page test)
    size_t size = 0; int w = 0, h = 0, fmt = 0;
    rga_buffer_handle_t handle = 0;
    uint8_t guard = GUARD_BYTE;
};

static size_t bpp_num(int fmt) { // bytes-per-pixel numerator (den in bpp_den)
    switch (fmt) {
        case RK_FORMAT_RGBA_8888: return 4;
        case RK_FORMAT_RGB_888:   return 3;
        case RK_FORMAT_RGB_565:   return 2;
        case RK_FORMAT_YCbCr_420_SP: return 3; // 3/2 bytes per pixel
        default: return 4;
    }
}
static size_t bpp_den(int fmt) { return fmt == RK_FORMAT_YCbCr_420_SP ? 2 : 1; }
static size_t img_bytes(int w, int h, int fmt) { return (size_t)w * h * bpp_num(fmt) / bpp_den(fmt); }

// Deterministic, layout-agnostic fill so identical content lands in scattered and
// contiguous sources, and so the copy absolute-check has a reference.
static void fill_pattern(uint8_t *p, size_t n, uint32_t seed) {
    uint32_t s = seed ? seed : 0x9e3779b9u;
    for (size_t i = 0; i < n; i++) {
        s ^= s << 13; s ^= s >> 17; s ^= s << 5;      // xorshift32
        p[i] = (uint8_t)(s ^ (i * 2654435761u));
        if ((i & (PAGE - 1)) == 0) p[i] = 0xA5;        // page-boundary marker
    }
}

static bool alloc_buf(Buf &b, int w, int h, int fmt, bool scattered, size_t byte_off) {
    b.w = w; b.h = h; b.fmt = fmt; b.size = img_bytes(w, h, fmt);
    size_t need = b.size + byte_off;
    size_t npages = (need + PAGE - 1) / PAGE;
    b.map_len = npages * PAGE;
    int mflags = MAP_PRIVATE | MAP_ANONYMOUS;
    b.map = (uint8_t *)mmap(nullptr, b.map_len, PROT_READ | PROT_WRITE, mflags, -1, 0);
    if (b.map == MAP_FAILED) { b.map = nullptr; perror("mmap A"); return false; }
    madvise(b.map, b.map_len, MADV_NOHUGEPAGE);

    if (scattered) {
        b.spacer_len = b.map_len;
        b.spacer = (uint8_t *)mmap(nullptr, b.spacer_len, PROT_READ | PROT_WRITE, mflags, -1, 0);
        if (b.spacer == MAP_FAILED) { b.spacer = nullptr; perror("mmap B"); return false; }
        madvise(b.spacer, b.spacer_len, MADV_NOHUGEPAGE);
        for (size_t i = 0; i < npages; i++) {         // interleaved faulting -> scatter
            b.map[i * PAGE] = 1;
            b.spacer[i * PAGE] = 1;
        }
    } else {
        for (size_t i = 0; i < npages; i++) b.map[i * PAGE] = 1; // sequential -> coalesces
    }

    // Bytes outside the imported image range must survive DMA cache maintenance.
    memset(b.map, b.guard, b.map_len);
    b.data = b.map + byte_off;
    b.handle = importbuffer_virtualaddr(b.data, w, h, fmt);
    if (b.handle == 0) { fprintf(stderr, "importbuffer_virtualaddr failed\n"); return false; }
    return true;
}

static void free_buf(Buf &b) {
    if (b.handle) releasebuffer_handle(b.handle);
    if (b.map) munmap(b.map, b.map_len);
    if (b.spacer) munmap(b.spacer, b.spacer_len);
    b = Buf{};
}

static rga_buffer_t wrap(Buf &b) { return wrapbuffer_handle(b.handle, b.w, b.h, b.fmt); }

static long first_diff(const uint8_t *a, const uint8_t *c, size_t n) {
    for (size_t i = 0; i < n; i++) if (a[i] != c[i]) return (long)i;
    return -1;
}

static bool guards_intact(const Buf &b, const char *name) {
    size_t prefix = (size_t)(b.data - b.map);
    size_t active_end = prefix + b.size;

    for (size_t i = 0; i < prefix; i++) {
        if (b.map[i] != b.guard) {
            fprintf(stderr, "  GUARD MISMATCH %s prefix byte=%zu got=%02x want=%02x\n",
                    name, i, b.map[i], b.guard);
            return false;
        }
    }
    for (size_t i = active_end; i < b.map_len; i++) {
        if (b.map[i] != b.guard) {
            fprintf(stderr, "  GUARD MISMATCH %s suffix byte=%zu got=%02x want=%02x\n",
                    name, i - active_end, b.map[i], b.guard);
            return false;
        }
    }

    return true;
}

// Run one op on src->dst; returns true on IM_STATUS_SUCCESS.
enum Op { OP_COPY, OP_RESIZE, OP_ROTATE, OP_CVT };
static bool run_op(Op op, Buf &src, Buf &dst) {
    rga_buffer_t s = wrap(src), d = wrap(dst);
    IM_STATUS st;
    switch (op) {
        case OP_COPY:   st = imcopy(s, d); break;
        case OP_RESIZE: st = imresize(s, d, 0, 0, IM_INTERP_DEFAULT); break;
        case OP_ROTATE: st = imrotate(s, d, IM_HAL_TRANSFORM_ROT_180); break; // 180 keeps dims
        case OP_CVT:    st = imcvtcolor(s, d, src.fmt, dst.fmt); break;
        default: return false;
    }
    if (st != IM_STATUS_SUCCESS) {
        fprintf(stderr, "  op %d IM_STATUS=%d (%s)\n", op, st, imStrError(st));
        return false;
    }
    return true;
}

struct Cfg { int iters = 32; unsigned seed = 1; std::string op = "all"; std::string scat = "both";
             int fixed_w = 0, fixed_h = 0; bool boundary_sweep = true; bool verbose = false; };

static int rnd_dim(uint32_t &s, int lo, int hi) { // multiple of 16 in [lo,hi]
    s = s * 1103515245u + 12345u;
    int span = (hi - lo) / 16 + 1;
    return lo + 16 * (int)((s >> 8) % span);
}

// One differential trial for a given op. Returns true on pass.
static bool trial(Op op, int w, int h, int sfmt, int dfmt, int dw, int dh,
                  const std::string &scat, unsigned seed, size_t src_off,
                  size_t dst_off, bool verbose) {
    bool ok = true;
    // Two identical sources: one scattered, one contiguous. Sub-page offsets vary.
    Buf src_s, src_c;
    if (!alloc_buf(src_s, w, h, sfmt, true, src_off) ||
        !alloc_buf(src_c, w, h, sfmt, false, 0)) { free_buf(src_s); free_buf(src_c); return false; }
    std::vector<uint8_t> pat(src_s.size);
    fill_pattern(pat.data(), pat.size(), seed * 2654435761u + op);
    memcpy(src_s.data, pat.data(), pat.size());
    memcpy(src_c.data, pat.data(), pat.size());

    // Destinations. Test the WRITE path by scattering dst when requested.
    bool scat_dst = (scat == "dst" || scat == "both");
    bool scat_src = (scat == "src" || scat == "both");
    if (!scat_src) {
        free_buf(src_s);
        if (!alloc_buf(src_s, w, h, sfmt, false, src_off)) {
            free_buf(src_s);
            free_buf(src_c);
            return false;
        }
        memcpy(src_s.data, pat.data(), pat.size());
    }

    Buf dst_a, dst_b;
    if (!alloc_buf(dst_a, dw, dh, dfmt, scat_dst, dst_off) ||
        !alloc_buf(dst_b, dw, dh, dfmt, false, 0)) { free_buf(src_s); free_buf(src_c); free_buf(dst_a); free_buf(dst_b); return false; }
    memset(dst_a.data, 0, dst_a.size); memset(dst_b.data, 0, dst_b.size);

    // A = op(scattered/forced src) -> (scattered dst); B = op(contiguous src)->(contiguous dst)
    if (!run_op(op, src_s, dst_a) || !run_op(op, src_c, dst_b)) ok = false;

    if (ok) {
        long d = first_diff(dst_a.data, dst_b.data, dst_a.size);
        if (d >= 0) {
            ok = false;
            fprintf(stderr, "  DIFFERENTIAL MISMATCH op=%d %dx%d->%dx%d src_off=%zu dst_off=%zu at byte %ld (a=%02x b=%02x)\n",
                    op, w, h, dw, dh, src_off, dst_off, d, dst_a.data[d], dst_b.data[d]);
        }
        if (op == OP_COPY) { // absolute check: copy must reproduce the pattern exactly
            long e = first_diff(dst_a.data, pat.data(), dst_a.size);
            if (e >= 0) { ok = false;
                fprintf(stderr, "  ABSOLUTE MISMATCH copy at byte %ld (got=%02x want=%02x)\n",
                        e, dst_a.data[e], pat[e]); }
        }
    }
    ok = guards_intact(src_s, "scattered-src") && ok;
    ok = guards_intact(src_c, "contiguous-src") && ok;
    ok = guards_intact(dst_a, "scattered-dst") && ok;
    ok = guards_intact(dst_b, "contiguous-dst") && ok;
    if (verbose && ok) fprintf(stderr, "  ok op=%d %dx%d->%dx%d src_off=%zu dst_off=%zu scat=%s\n",
                               op, w, h, dw, dh, src_off, dst_off, scat.c_str());
    free_buf(src_s); free_buf(src_c); free_buf(dst_a); free_buf(dst_b);
    return ok;
}

int main(int argc, char **argv) {
    Cfg c;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        auto next = [&]() { return (i + 1 < argc) ? argv[++i] : (char*)""; };
        if (a == "-n") c.iters = atoi(next());
        else if (a == "-s") c.seed = (unsigned)strtoul(next(), nullptr, 0);
        else if (a == "-o") c.op = next();
        else if (a == "-t") c.scat = next();
        else if (a == "-W") c.fixed_w = atoi(next());
        else if (a == "-H") c.fixed_h = atoi(next());
        else if (a == "--no-boundary-sweep") c.boundary_sweep = false;
        else if (a == "-v") c.verbose = true;
        else { fprintf(stderr, "usage: %s [-n iters] [-s seed] [-o copy|resize|rotate|cvt|all] "
                       "[-t src|dst|both] [-W w] [-H h] [--no-boundary-sweep] [-v]\n", argv[0]); return 2; }
    }
    printf("rga-iommu-fuzz: iters=%d seed=%u op=%s scatter=%s\n", c.iters, c.seed, c.op.c_str(), c.scat.c_str());

    if (c.scat != "src" && c.scat != "dst" && c.scat != "both") {
        fprintf(stderr, "bad -t\n");
        return 2;
    }

    std::vector<Op> ops;
    if (c.op == "all") ops = {OP_COPY, OP_RESIZE, OP_ROTATE, OP_CVT};
    else if (c.op == "copy") ops = {OP_COPY};
    else if (c.op == "resize") ops = {OP_RESIZE};
    else if (c.op == "rotate") ops = {OP_ROTATE};
    else if (c.op == "cvt") ops = {OP_CVT};
    else { fprintf(stderr, "bad -o\n"); return 2; }

    int min_w = RGA3_MIN_WIDTH;
    for (Op op : ops) {
        if (op == OP_RESIZE)
            min_w = RGA3_MIN_RESIZE_SRC_WIDTH;
    }
    if (c.fixed_w && c.fixed_w < min_w) {
        fprintf(stderr, "fixed width %d is below RGA3-safe minimum %d for op=%s\n",
                c.fixed_w, min_w, c.op.c_str());
        return 2;
    }

    uint32_t rs = c.seed;
    int pass = 0, fail = 0;
    if (c.boundary_sweep) {
        int w = c.fixed_w ? c.fixed_w : RGA3_MIN_WIDTH;
        int h = c.fixed_h ? c.fixed_h : 64;

        for (size_t off = 0; off < CACHE_ALIGN; off++) {
            bool ok = trial(OP_COPY, w, h, RK_FORMAT_RGBA_8888,
                            RK_FORMAT_RGBA_8888, w, h, "both",
                            c.seed + (unsigned)off, off,
                            CACHE_ALIGN - 1 - off, c.verbose);
            ok ? pass++ : fail++;
        }
    }
    for (int it = 0; it < c.iters; it++) {
        int w = c.fixed_w ? c.fixed_w : rnd_dim(rs, min_w, 1024);
        int h = c.fixed_h ? c.fixed_h : rnd_dim(rs, 64, 768);
        for (Op op : ops) {
            int sfmt = RK_FORMAT_RGBA_8888, dfmt = RK_FORMAT_RGBA_8888;
            int dw = w, dh = h;
            if (op == OP_RESIZE) { dw = w / 2 & ~15; dh = h / 2 & ~15; if (dw < 16 || dh < 16) continue; }
            if (op == OP_CVT)    { dfmt = RK_FORMAT_YCbCr_420_SP; if (w & 1 || h & 1) continue; }
            unsigned trial_seed = c.seed + it * 131 + op;
            size_t src_off = trial_seed % CACHE_ALIGN;
            size_t dst_off = (trial_seed * 17U + 11U) % CACHE_ALIGN;
            bool ok = trial(op, w, h, sfmt, dfmt, dw, dh, c.scat,
                            trial_seed, src_off, dst_off, c.verbose);
            ok ? pass++ : fail++;
        }
    }
    printf("rga-iommu-fuzz: PASS=%d FAIL=%d\n", pass, fail);
    return fail ? 1 : 0;
}
