// SPDX-License-Identifier: MIT
/*
 * rkmpp_lifecycle_bench - isolate RKMPP encoder-context lifecycle stalls.
 *
 * This is a focused reproduction of gnome-remote-desktop's FFmpeg/RKMPP
 * zero-copy smoke encode.  It allocates one linear NV12 dma-buf from the same
 * system dma-heap, wraps it in an AVDRMFrameDescriptor, and drives
 * h264_rkmpp with the same low-delay codec settings.
 *
 * The primary A/B modes deliberately differ in one variable only:
 *
 *   reuse  - open one AVCodecContext and encode every frame through it
 *   churn  - open, encode one frame, and close on every iteration
 *
 * The optional exp2 mode adds the otherwise-idle second open/close performed
 * by GRD's old post-smoke-test IDR workaround.
 *
 * A parent watchdog observes phase events from the worker child.  If one
 * operation stops making progress, the parent emits a watchdog_timeout event,
 * leaves the child blocked for a short capture window, and then kills only the
 * reproducer.  This bounds old FFmpeg builds whose LOW_DELAY receive path uses
 * MPP_TIMEOUT_BLOCK while preserving time for an external state sampler.
 */

#define _GNU_SOURCE

#include <drm_fourcc.h>
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <inttypes.h>
#include <linux/dma-buf.h>
#include <linux/dma-heap.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include <libavcodec/avcodec.h>
#include <libavutil/buffer.h>
#include <libavutil/dict.h>
#include <libavutil/error.h>
#include <libavutil/frame.h>
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_drm.h>
#include <libavutil/pixfmt.h>

#ifndef AV_PROFILE_H264_HIGH
#define AV_PROFILE_H264_HIGH FF_PROFILE_H264_HIGH
#endif

#define RKMPP_ENCODER_NAME "h264_rkmpp"
#define DEFAULT_WIDTH 1920U
#define DEFAULT_HEIGHT 1080U
#define DEFAULT_FPS 60U
#define DEFAULT_ITERATIONS 1000U
#define DEFAULT_STALL_MS 500U
#define DEFAULT_CAPTURE_HOLD_MS 2000U
#define DEFAULT_STARTUP_DELAY_MS 250U
#define WATCHDOG_REAP_MS 250U
#define FIXED_QP 22
#define FALLBACK_BPP_DIVISOR 4
#define PEAK_RATE_FACTOR 3
#define MIN_RATE_DIVISOR 8
#define FALLBACK_BITRATE_CAP_BPS 100000000

enum run_mode {
	MODE_REUSE,
	MODE_CHURN,
	MODE_EXP2,
};

struct options {
	enum run_mode mode;
	uint32_t width;
	uint32_t height;
	uint32_t fps;
	uint32_t iterations;
	uint32_t stall_ms;
	uint32_t capture_hold_ms;
	uint32_t startup_delay_ms;
	const char *render_node;
	bool force_idr;
	bool self_test_stall;
};

struct nv12_surface {
	int fd;
	void *map;
	size_t size;
	uint32_t width;
	uint32_t height;
	uint32_t stride;
	AVDRMFrameDescriptor drm_desc;
};

struct encoder {
	AVCodecContext *avctx;
	AVBufferRef *hw_device_ctx;
	AVBufferRef *hw_frames_ctx;
	bool has_hw_frames;
};

static volatile sig_atomic_t watched_child = -1;
static volatile sig_atomic_t forwarded_signal;

static uint64_t now_ns(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

static double elapsed_ms(uint64_t start_ns)
{
	return (double)(now_ns() - start_ns) / 1000000.0;
}

static void sleep_ms(uint32_t delay_ms)
{
	struct timespec requested = {
		.tv_sec = delay_ms / 1000,
		.tv_nsec = (long)(delay_ms % 1000) * 1000000L,
	};

	while (nanosleep(&requested, &requested) && errno == EINTR)
		;
}

static const char *mode_name(enum run_mode mode)
{
	switch (mode) {
	case MODE_REUSE:
		return "reuse";
	case MODE_CHURN:
		return "churn";
	case MODE_EXP2:
		return "exp2";
	}
	return "unknown";
}

static void event(const struct options *opts, const char *name,
		  uint32_t iteration)
{
	printf("{\"ts_ns\":%" PRIu64 ",\"event\":\"%s\","
	       "\"pid\":%ld,\"mode\":\"%s\",\"iteration\":%u}\n",
	       now_ns(), name, (long)getpid(), mode_name(opts->mode), iteration);
}

static void event_timed(const struct options *opts, const char *name,
			uint32_t iteration, uint64_t start_ns, int result)
{
	printf("{\"ts_ns\":%" PRIu64 ",\"event\":\"%s\","
	       "\"pid\":%ld,\"mode\":\"%s\",\"iteration\":%u,"
	       "\"elapsed_ms\":%.3f,\"result\":%d}\n",
	       now_ns(), name, (long)getpid(), mode_name(opts->mode), iteration,
	       elapsed_ms(start_ns), result);
}

static void print_av_error(const char *operation, int ret)
{
	char text[AV_ERROR_MAX_STRING_SIZE] = { 0 };

	av_strerror(ret, text, sizeof(text));
	fprintf(stderr, "%s: %s (%d)\n", operation, text, ret);
}

static uint32_t align_u32(uint32_t value, uint32_t alignment)
{
	return (value + alignment - 1) / alignment * alignment;
}

static int dma_buf_sync(int fd, uint64_t flags)
{
	struct dma_buf_sync sync = { .flags = flags };

	if (ioctl(fd, DMA_BUF_IOCTL_SYNC, &sync) < 0)
		return -errno;
	return 0;
}

static int surface_alloc(struct nv12_surface *surface,
			 uint32_t source_width, uint32_t source_height)
{
	struct dma_heap_allocation_data allocation = { 0 };
	int heap_fd;
	int ret;

	memset(surface, 0, sizeof(*surface));
	surface->fd = -1;
	surface->map = MAP_FAILED;
	surface->width = align_u32(source_width, 16);
	surface->height = align_u32(source_height, 16);
	surface->stride = align_u32(surface->width, 64);
	surface->size = (size_t)surface->stride * surface->height * 3 / 2;

	heap_fd = open("/dev/dma_heap/system", O_RDWR | O_CLOEXEC);
	if (heap_fd < 0) {
		fprintf(stderr, "open /dev/dma_heap/system: %s\n", strerror(errno));
		return -errno;
	}

	allocation.len = surface->size;
	allocation.fd_flags = O_RDWR | O_CLOEXEC;
	if (ioctl(heap_fd, DMA_HEAP_IOCTL_ALLOC, &allocation) < 0) {
		ret = -errno;
		fprintf(stderr, "DMA_HEAP_IOCTL_ALLOC: %s\n", strerror(errno));
		close(heap_fd);
		return ret;
	}
	close(heap_fd);
	surface->fd = allocation.fd;

	surface->map = mmap(NULL, surface->size, PROT_READ | PROT_WRITE,
			    MAP_SHARED, surface->fd, 0);
	if (surface->map == MAP_FAILED) {
		ret = -errno;
		fprintf(stderr, "mmap dma-buf: %s\n", strerror(errno));
		close(surface->fd);
		surface->fd = -1;
		return ret;
	}

	surface->drm_desc.nb_objects = 1;
	surface->drm_desc.objects[0].fd = surface->fd;
	surface->drm_desc.objects[0].size = surface->size;
	surface->drm_desc.objects[0].format_modifier = DRM_FORMAT_MOD_LINEAR;
	surface->drm_desc.nb_layers = 1;
	surface->drm_desc.layers[0].format = DRM_FORMAT_NV12;
	surface->drm_desc.layers[0].nb_planes = 2;
	surface->drm_desc.layers[0].planes[0].object_index = 0;
	surface->drm_desc.layers[0].planes[0].offset = 0;
	surface->drm_desc.layers[0].planes[0].pitch = surface->stride;
	surface->drm_desc.layers[0].planes[1].object_index = 0;
	surface->drm_desc.layers[0].planes[1].offset =
		(uint64_t)surface->stride * surface->height;
	surface->drm_desc.layers[0].planes[1].pitch = surface->stride;

	return 0;
}

static void surface_free(struct nv12_surface *surface)
{
	if (surface->map != MAP_FAILED)
		munmap(surface->map, surface->size);
	if (surface->fd >= 0)
		close(surface->fd);
	surface->map = MAP_FAILED;
	surface->fd = -1;
}

static int surface_fill(struct nv12_surface *surface, uint32_t iteration)
{
	uint8_t *pixels = surface->map;
	uint8_t *uv = pixels + (size_t)surface->stride * surface->height;
	uint8_t luma = (uint8_t)(32 + iteration % 192);
	int ret;

	ret = dma_buf_sync(surface->fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_WRITE);
	if (ret < 0)
		return ret;

	memset(pixels, luma, (size_t)surface->stride * surface->height);
	memset(uv, 128, (size_t)surface->stride * surface->height / 2);

	ret = dma_buf_sync(surface->fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_WRITE);
	return ret;
}

static void drm_desc_noop_free(void *opaque, uint8_t *data)
{
	(void)opaque;
	(void)data;
}

static AVFrame *build_frame(const struct nv12_surface *surface,
			    const struct encoder *encoder, int64_t pts,
			    bool force_idr)
{
	AVFrame *frame = av_frame_alloc();

	if (!frame)
		return NULL;

	frame->format = AV_PIX_FMT_DRM_PRIME;
	frame->width = surface->width;
	frame->height = surface->height;
	frame->pts = pts;
	frame->buf[0] = av_buffer_create((uint8_t *)&surface->drm_desc,
					 sizeof(surface->drm_desc),
					 drm_desc_noop_free, NULL,
					 AV_BUFFER_FLAG_READONLY);
	if (!frame->buf[0]) {
		av_frame_free(&frame);
		return NULL;
	}
	frame->data[0] = frame->buf[0]->data;

	if (encoder->hw_frames_ctx)
		frame->hw_frames_ctx = av_buffer_ref(encoder->hw_frames_ctx);

	if (force_idr) {
		frame->pict_type = AV_PICTURE_TYPE_I;
#ifdef AV_FRAME_FLAG_KEY
		frame->flags |= AV_FRAME_FLAG_KEY;
#else
		frame->key_frame = 1;
#endif
	}

	return frame;
}

static void encoder_destroy(struct encoder *encoder)
{
	av_buffer_unref(&encoder->hw_frames_ctx);
	av_buffer_unref(&encoder->hw_device_ctx);
	avcodec_free_context(&encoder->avctx);
	encoder->has_hw_frames = false;
}

static int encoder_create(struct encoder *encoder,
			  const struct options *opts,
			  const struct nv12_surface *surface)
{
	const AVCodec *codec;
	AVDictionary *codec_opts = NULL;
	const AVDictionaryEntry *entry = NULL;
	int64_t target_rate;
	int ret;

	memset(encoder, 0, sizeof(*encoder));
	codec = avcodec_find_encoder_by_name(RKMPP_ENCODER_NAME);
	if (!codec) {
		fprintf(stderr, "FFmpeg encoder %s is unavailable\n",
			RKMPP_ENCODER_NAME);
		return AVERROR_ENCODER_NOT_FOUND;
	}

	encoder->avctx = avcodec_alloc_context3(codec);
	if (!encoder->avctx)
		return AVERROR(ENOMEM);

	encoder->avctx->width = surface->width;
	encoder->avctx->height = surface->height;
	encoder->avctx->pix_fmt = AV_PIX_FMT_DRM_PRIME;
	encoder->avctx->sw_pix_fmt = AV_PIX_FMT_NV12;
	encoder->avctx->time_base = (AVRational){ 1, (int)opts->fps };
	encoder->avctx->framerate = (AVRational){ (int)opts->fps, 1 };
	encoder->avctx->gop_size = (int)(opts->fps * 3600U);
	encoder->avctx->max_b_frames = 0;
	encoder->avctx->refs = 1;
	encoder->avctx->profile = AV_PROFILE_H264_HIGH;
	encoder->avctx->color_range = AVCOL_RANGE_MPEG;
	encoder->avctx->thread_count = 1;
	encoder->avctx->flags |= AV_CODEC_FLAG_LOW_DELAY;

	target_rate = (int64_t)surface->width * surface->height * opts->fps /
		FALLBACK_BPP_DIVISOR;
	if (target_rate > FALLBACK_BITRATE_CAP_BPS)
		target_rate = FALLBACK_BITRATE_CAP_BPS;
	encoder->avctx->bit_rate = target_rate;
	encoder->avctx->rc_max_rate = target_rate * PEAK_RATE_FACTOR;
	if (encoder->avctx->rc_max_rate > FALLBACK_BITRATE_CAP_BPS)
		encoder->avctx->rc_max_rate = FALLBACK_BITRATE_CAP_BPS;
	encoder->avctx->rc_min_rate = target_rate / MIN_RATE_DIVISOR;

	if (opts->render_node && strcmp(opts->render_node, "none") != 0 &&
	    av_hwdevice_ctx_create(&encoder->hw_device_ctx,
				   AV_HWDEVICE_TYPE_DRM,
				   opts->render_node, NULL, 0) >= 0) {
		encoder->hw_frames_ctx =
			av_hwframe_ctx_alloc(encoder->hw_device_ctx);
		if (encoder->hw_frames_ctx) {
			AVHWFramesContext *frames =
				(AVHWFramesContext *)encoder->hw_frames_ctx->data;

			frames->format = AV_PIX_FMT_DRM_PRIME;
			frames->sw_format = AV_PIX_FMT_NV12;
			frames->width = surface->width;
			frames->height = surface->height;
			frames->initial_pool_size = 0;
			if (av_hwframe_ctx_init(encoder->hw_frames_ctx) < 0)
				av_buffer_unref(&encoder->hw_frames_ctx);
		}

		encoder->avctx->hw_device_ctx =
			av_buffer_ref(encoder->hw_device_ctx);
		if (encoder->hw_frames_ctx) {
			encoder->avctx->hw_frames_ctx =
				av_buffer_ref(encoder->hw_frames_ctx);
			encoder->has_hw_frames = true;
		}
	}

	av_dict_set_int(&codec_opts, "qp_init", FIXED_QP, 0);
	ret = avcodec_open2(encoder->avctx, codec, &codec_opts);
	if (ret < 0) {
		print_av_error("avcodec_open2(h264_rkmpp)", ret);
		av_dict_free(&codec_opts);
		encoder_destroy(encoder);
		return ret;
	}

	while ((entry = av_dict_get(codec_opts, "", entry,
				    AV_DICT_IGNORE_SUFFIX)))
		fprintf(stderr, "encoder ignored option %s=%s\n",
			entry->key, entry->value);
	av_dict_free(&codec_opts);

	if (encoder->avctx->max_b_frames != 0) {
		fprintf(stderr, "encoder retained max_b_frames=%d\n",
			encoder->avctx->max_b_frames);
		encoder_destroy(encoder);
		return AVERROR(EINVAL);
	}

	return 0;
}

static int encode_one(struct encoder *encoder,
		      struct nv12_surface *surface,
		      const struct options *opts,
		      uint32_t iteration, int64_t pts,
		      bool force_idr)
{
	AVFrame *frame = NULL;
	AVPacket *packet = NULL;
	uint64_t start_ns;
	int ret;

	event(opts, "surface_write_begin", iteration);
	start_ns = now_ns();
	ret = surface_fill(surface, iteration);
	event_timed(opts, "surface_write_end", iteration, start_ns, ret);
	if (ret < 0) {
		fprintf(stderr, "dma-buf sync/fill: %s\n", strerror(-ret));
		return ret;
	}

	frame = build_frame(surface, encoder, pts, force_idr);
	if (!frame) {
		fprintf(stderr, "failed to allocate DRM-PRIME AVFrame\n");
		return AVERROR(ENOMEM);
	}

	event(opts, "send_begin", iteration);
	start_ns = now_ns();
	ret = avcodec_send_frame(encoder->avctx, frame);
	event_timed(opts, "send_end", iteration, start_ns, ret);
	av_frame_free(&frame);
	if (ret < 0) {
		print_av_error("avcodec_send_frame", ret);
		return ret;
	}

	packet = av_packet_alloc();
	if (!packet)
		return AVERROR(ENOMEM);

	event(opts, "receive_begin", iteration);
	start_ns = now_ns();
	ret = avcodec_receive_packet(encoder->avctx, packet);
	event_timed(opts, "receive_end", iteration, start_ns, ret);
	if (ret < 0) {
		print_av_error("avcodec_receive_packet", ret);
		av_packet_free(&packet);
		return ret;
	}

	printf("{\"ts_ns\":%" PRIu64 ",\"event\":\"packet\","
	       "\"pid\":%ld,\"mode\":\"%s\",\"iteration\":%u,"
	       "\"bytes\":%zu,\"key\":%s}\n",
	       now_ns(), (long)getpid(), mode_name(opts->mode), iteration,
	       (size_t)packet->size,
	       packet->flags & AV_PKT_FLAG_KEY ? "true" : "false");
	av_packet_free(&packet);
	return 0;
}

static int open_encoder_instrumented(struct encoder *encoder,
				     const struct options *opts,
				     const struct nv12_surface *surface,
				     uint32_t iteration,
				     const char *begin_event,
				     const char *end_event)
{
	uint64_t start_ns;
	int ret;

	event(opts, begin_event, iteration);
	start_ns = now_ns();
	ret = encoder_create(encoder, opts, surface);
	event_timed(opts, end_event, iteration, start_ns, ret);
	return ret;
}

static void close_encoder_instrumented(struct encoder *encoder,
				       const struct options *opts,
				       uint32_t iteration,
				       const char *begin_event,
				       const char *end_event)
{
	uint64_t start_ns;

	event(opts, begin_event, iteration);
	start_ns = now_ns();
	encoder_destroy(encoder);
	event_timed(opts, end_event, iteration, start_ns, 0);
}

static int run_reuse(const struct options *opts,
		     struct nv12_surface *surface)
{
	struct encoder encoder = { 0 };
	uint32_t i;
	int ret;

	ret = open_encoder_instrumented(&encoder, opts, surface, 0,
					"encoder_open_begin", "encoder_open_end");
	if (ret < 0)
		return ret;

	for (i = 0; i < opts->iterations; i++) {
		uint64_t iteration_ns = now_ns();

		event(opts, "iteration_begin", i);
		ret = encode_one(&encoder, surface, opts, i, i,
				 opts->force_idr && i == 0);
		event_timed(opts, "iteration_end", i, iteration_ns, ret);
		if (ret < 0)
			break;
	}

	close_encoder_instrumented(&encoder, opts, i,
				   "encoder_close_begin", "encoder_close_end");
	return ret;
}

static int run_churn(const struct options *opts,
		     struct nv12_surface *surface, bool exp2_pair)
{
	uint32_t i;

	for (i = 0; i < opts->iterations; i++) {
		struct encoder encoder = { 0 };
		uint64_t iteration_ns = now_ns();
		int ret;

		event(opts, "iteration_begin", i);
		ret = open_encoder_instrumented(&encoder, opts, surface, i,
						"encoder_open_begin",
						"encoder_open_end");
		if (ret < 0)
			return ret;

		ret = encode_one(&encoder, surface, opts, i, i, opts->force_idr);
		close_encoder_instrumented(&encoder, opts, i,
					   "encoder_close_begin",
					   "encoder_close_end");
		if (ret < 0)
			return ret;

		if (exp2_pair) {
			ret = open_encoder_instrumented(&encoder, opts, surface, i,
							"post_smoke_open_begin",
							"post_smoke_open_end");
			if (ret < 0)
				return ret;
			close_encoder_instrumented(&encoder, opts, i,
						   "post_smoke_close_begin",
						   "post_smoke_close_end");
		}

		event_timed(opts, "iteration_end", i, iteration_ns, 0);
	}

	return 0;
}

static int run_worker(const struct options *opts)
{
	struct nv12_surface surface;
	int ret;

	setvbuf(stdout, NULL, _IONBF, 0);
	printf("{\"ts_ns\":%" PRIu64 ",\"event\":\"worker_start\","
	       "\"pid\":%ld,\"mode\":\"%s\",\"iterations\":%u,"
	       "\"source_width\":%u,\"source_height\":%u,\"fps\":%u,"
	       "\"force_idr\":%s,"
	       "\"libavcodec_version\":%u}\n",
	       now_ns(), (long)getpid(), mode_name(opts->mode), opts->iterations,
	       opts->width, opts->height, opts->fps,
	       opts->force_idr ? "true" : "false", avcodec_version());

	if (opts->self_test_stall) {
		event(opts, "self_test_stall_begin", 0);
		for (;;)
			pause();
	}

	if (opts->startup_delay_ms) {
		event(opts, "startup_delay_begin", 0);
		sleep_ms(opts->startup_delay_ms);
		event(opts, "startup_delay_end", 0);
	}

	event(opts, "surface_alloc_begin", 0);
	ret = surface_alloc(&surface, opts->width, opts->height);
	if (ret < 0) {
		event_timed(opts, "surface_alloc_end", 0, now_ns(), ret);
		return 1;
	}
	printf("{\"ts_ns\":%" PRIu64 ",\"event\":\"surface_alloc_end\","
	       "\"pid\":%ld,\"mode\":\"%s\",\"iteration\":0,"
	       "\"width\":%u,\"height\":%u,\"stride\":%u,"
	       "\"bytes\":%zu}\n",
	       now_ns(), (long)getpid(), mode_name(opts->mode), surface.width,
	       surface.height, surface.stride, surface.size);

	switch (opts->mode) {
	case MODE_REUSE:
		ret = run_reuse(opts, &surface);
		break;
	case MODE_CHURN:
		ret = run_churn(opts, &surface, false);
		break;
	case MODE_EXP2:
		ret = run_churn(opts, &surface, true);
		break;
	default:
		ret = AVERROR(EINVAL);
		break;
	}

	surface_free(&surface);
	event(opts, ret < 0 ? "worker_error" : "worker_done",
	      opts->iterations);
	return ret < 0 ? 1 : 0;
}

static void forward_signal(int signo)
{
	forwarded_signal = signo;
	if (watched_child > 0)
		kill(-watched_child, signo);
}

static int write_all(int fd, const void *data, size_t size)
{
	const uint8_t *cursor = data;

	while (size) {
		ssize_t written = write(fd, cursor, size);

		if (written < 0) {
			if (errno == EINTR)
				continue;
			return -errno;
		}
		cursor += written;
		size -= (size_t)written;
	}
	return 0;
}

static bool reap_child_bounded(pid_t pid, int *status, uint32_t timeout_ms)
{
	uint64_t deadline_ns = now_ns() + (uint64_t)timeout_ms * 1000000ULL;

	for (;;) {
		pid_t ret = waitpid(pid, status, WNOHANG);

		if (ret == pid)
			return true;
		if (ret < 0) {
			if (errno == EINTR)
				continue;
			return false;
		}
		if (now_ns() >= deadline_ns)
			return false;
		sleep_ms(10);
	}
}

static int watchdog_run(const struct options *opts)
{
	struct sigaction action = { .sa_handler = forward_signal };
	struct pollfd pfd = { .events = POLLIN | POLLHUP };
	uint64_t last_progress_ns;
	char buffer[4096];
	int pipe_fds[2];
	int status;
	pid_t pid;

	if (pipe2(pipe_fds, O_CLOEXEC) < 0) {
		perror("pipe2");
		return 1;
	}

	pid = fork();
	if (pid < 0) {
		perror("fork");
		close(pipe_fds[0]);
		close(pipe_fds[1]);
		return 1;
	}
	if (pid == 0) {
		close(pipe_fds[0]);
		setpgid(0, 0);
		if (dup2(pipe_fds[1], STDOUT_FILENO) < 0)
			_exit(126);
		close(pipe_fds[1]);
		_exit(run_worker(opts));
	}

	close(pipe_fds[1]);
	setpgid(pid, pid);
	pfd.fd = pipe_fds[0];
	watched_child = pid;
	sigemptyset(&action.sa_mask);
	sigaction(SIGINT, &action, NULL);
	sigaction(SIGTERM, &action, NULL);
	setvbuf(stdout, NULL, _IONBF, 0);
	last_progress_ns = now_ns();

	for (;;) {
		uint64_t current_ns = now_ns();
		uint64_t deadline_ns = last_progress_ns +
			(uint64_t)opts->stall_ms * 1000000ULL;
		int timeout_ms = current_ns >= deadline_ns ? 0 :
			(int)((deadline_ns - current_ns + 999999ULL) / 1000000ULL);
		int poll_ret = poll(&pfd, 1, timeout_ms);

		if (forwarded_signal) {
			reap_child_bounded(pid, &status, WATCHDOG_REAP_MS);
			watched_child = -1;
			close(pipe_fds[0]);
			return 128 + forwarded_signal;
		}
		if (poll_ret < 0) {
			if (errno == EINTR)
				continue;
			perror("poll");
			kill(-pid, SIGKILL);
			reap_child_bounded(pid, &status, WATCHDOG_REAP_MS);
			watched_child = -1;
			close(pipe_fds[0]);
			return 1;
		}
		if (poll_ret == 0) {
			printf("{\"ts_ns\":%" PRIu64 ","
			       "\"event\":\"watchdog_timeout\",\"pid\":%ld,"
			       "\"mode\":\"%s\",\"iteration\":null,"
			       "\"stall_ms\":%u,\"capture_hold_ms\":%u}\n",
			       now_ns(), (long)pid, mode_name(opts->mode),
			       opts->stall_ms, opts->capture_hold_ms);
			sleep_ms(opts->capture_hold_ms);
			kill(-pid, SIGKILL);
			printf("{\"ts_ns\":%" PRIu64 ","
			       "\"event\":\"watchdog_kill_sent\","
			       "\"pid\":%ld,\"mode\":\"%s\","
			       "\"iteration\":null}\n",
			       now_ns(), (long)pid, mode_name(opts->mode));
			if (reap_child_bounded(pid, &status, WATCHDOG_REAP_MS)) {
				printf("{\"ts_ns\":%" PRIu64 ","
				       "\"event\":\"watchdog_worker_reaped\","
				       "\"pid\":%ld,\"mode\":\"%s\","
				       "\"iteration\":null}\n",
				       now_ns(), (long)pid, mode_name(opts->mode));
			} else {
				printf("{\"ts_ns\":%" PRIu64 ","
				       "\"event\":\"watchdog_worker_unreaped\","
				       "\"pid\":%ld,\"mode\":\"%s\","
				       "\"iteration\":null,\"reap_ms\":%u}\n",
				       now_ns(), (long)pid, mode_name(opts->mode),
				       WATCHDOG_REAP_MS);
			}
			watched_child = -1;
			close(pipe_fds[0]);
			return 124;
		}

		if (pfd.revents & (POLLIN | POLLHUP)) {
			ssize_t got = read(pipe_fds[0], buffer, sizeof(buffer));

			if (got > 0) {
				write_all(STDOUT_FILENO, buffer, (size_t)got);
				last_progress_ns = now_ns();
				continue;
			}
			if (got == 0)
				break;
			if (errno == EINTR)
				continue;
			perror("read worker events");
			break;
		}
	}

	close(pipe_fds[0]);
	waitpid(pid, &status, 0);
	watched_child = -1;
	if (WIFEXITED(status))
		return WEXITSTATUS(status);
	if (WIFSIGNALED(status))
		return 128 + WTERMSIG(status);
	return 1;
}

static void usage(FILE *stream, const char *program)
{
	fprintf(stream,
		"Usage: %s [options]\n"
		"\n"
		"Isolate FFmpeg/RKMPP lifecycle stalls using GRD-compatible "
		"DRM-PRIME input.\n"
		"\n"
		"Options:\n"
		"  -m, --mode reuse|churn|exp2  encoder lifecycle (default: reuse)\n"
		"  -n, --iterations N           frames/lifecycle iterations "
		"(default: %u)\n"
		"  -W, --width N                source width (default: %u)\n"
		"  -H, --height N               source height (default: %u)\n"
		"  -r, --fps N                  encoder frame rate (default: %u)\n"
		"      --render-node PATH       DRM render node or 'none' "
		"(default: /dev/dri/renderD128)\n"
		"      --stall-ms N             no-progress deadline "
		"(default: %u)\n"
		"      --capture-hold-ms N      sample window before kill "
		"(default: %u)\n"
		"      --startup-delay-ms N     sampler attachment delay "
		"(default: %u)\n"
		"      --no-force-idr           omit per-frame IDR control "
		"(causal control)\n"
		"      --self-test-stall        validate watchdog without hardware\n"
		"  -h, --help                   show this help\n",
		program, DEFAULT_ITERATIONS, DEFAULT_WIDTH, DEFAULT_HEIGHT,
		DEFAULT_FPS, DEFAULT_STALL_MS, DEFAULT_CAPTURE_HOLD_MS,
		DEFAULT_STARTUP_DELAY_MS);
}

static int parse_u32(const char *name, const char *text, uint32_t *value)
{
	char *end = NULL;
	unsigned long parsed;

	errno = 0;
	parsed = strtoul(text, &end, 10);
	if (errno || !end || *end || parsed > UINT32_MAX || parsed == 0) {
		fprintf(stderr, "invalid %s: %s\n", name, text);
		return -1;
	}
	*value = (uint32_t)parsed;
	return 0;
}

static int parse_options(int argc, char **argv, struct options *opts)
{
	enum {
		OPT_RENDER_NODE = 1000,
		OPT_STALL_MS,
		OPT_CAPTURE_HOLD_MS,
		OPT_STARTUP_DELAY_MS,
		OPT_NO_FORCE_IDR,
		OPT_SELF_TEST_STALL,
	};
	static const struct option long_options[] = {
		{ "mode", required_argument, NULL, 'm' },
		{ "iterations", required_argument, NULL, 'n' },
		{ "width", required_argument, NULL, 'W' },
		{ "height", required_argument, NULL, 'H' },
		{ "fps", required_argument, NULL, 'r' },
		{ "render-node", required_argument, NULL, OPT_RENDER_NODE },
		{ "stall-ms", required_argument, NULL, OPT_STALL_MS },
		{ "capture-hold-ms", required_argument, NULL,
		  OPT_CAPTURE_HOLD_MS },
		{ "startup-delay-ms", required_argument, NULL,
		  OPT_STARTUP_DELAY_MS },
		{ "no-force-idr", no_argument, NULL, OPT_NO_FORCE_IDR },
		{ "self-test-stall", no_argument, NULL, OPT_SELF_TEST_STALL },
		{ "help", no_argument, NULL, 'h' },
		{ NULL, 0, NULL, 0 },
	};
	int option;

	*opts = (struct options) {
		.mode = MODE_REUSE,
		.width = DEFAULT_WIDTH,
		.height = DEFAULT_HEIGHT,
		.fps = DEFAULT_FPS,
		.iterations = DEFAULT_ITERATIONS,
		.stall_ms = DEFAULT_STALL_MS,
		.capture_hold_ms = DEFAULT_CAPTURE_HOLD_MS,
		.startup_delay_ms = DEFAULT_STARTUP_DELAY_MS,
		.render_node = "/dev/dri/renderD128",
		.force_idr = true,
	};

	while ((option = getopt_long(argc, argv, "m:n:W:H:r:h",
				     long_options, NULL)) != -1) {
		switch (option) {
		case 'm':
			if (strcmp(optarg, "reuse") == 0)
				opts->mode = MODE_REUSE;
			else if (strcmp(optarg, "churn") == 0)
				opts->mode = MODE_CHURN;
			else if (strcmp(optarg, "exp2") == 0)
				opts->mode = MODE_EXP2;
			else {
				fprintf(stderr, "invalid mode: %s\n", optarg);
				return -1;
			}
			break;
		case 'n':
			if (parse_u32("iterations", optarg,
				      &opts->iterations) < 0)
				return -1;
			break;
		case 'W':
			if (parse_u32("width", optarg, &opts->width) < 0)
				return -1;
			break;
		case 'H':
			if (parse_u32("height", optarg, &opts->height) < 0)
				return -1;
			break;
		case 'r':
			if (parse_u32("fps", optarg, &opts->fps) < 0)
				return -1;
			break;
		case OPT_RENDER_NODE:
			opts->render_node = optarg;
			break;
		case OPT_STALL_MS:
			if (parse_u32("stall-ms", optarg, &opts->stall_ms) < 0)
				return -1;
			break;
		case OPT_CAPTURE_HOLD_MS:
			if (parse_u32("capture-hold-ms", optarg,
				      &opts->capture_hold_ms) < 0)
				return -1;
			break;
		case OPT_STARTUP_DELAY_MS:
			if (strcmp(optarg, "0") == 0)
				opts->startup_delay_ms = 0;
			else if (parse_u32("startup-delay-ms", optarg,
					   &opts->startup_delay_ms) < 0)
				return -1;
			break;
		case OPT_NO_FORCE_IDR:
			opts->force_idr = false;
			break;
		case OPT_SELF_TEST_STALL:
			opts->self_test_stall = true;
			opts->startup_delay_ms = 0;
			break;
		case 'h':
			usage(stdout, argv[0]);
			exit(0);
		default:
			return -1;
		}
	}

	if (optind != argc) {
		fprintf(stderr, "unexpected positional argument: %s\n", argv[optind]);
		return -1;
	}
	if (opts->width < 16 || opts->height < 16 ||
	    opts->width > 16384 || opts->height > 16384 || opts->fps > 1000) {
		fprintf(stderr, "dimensions/fps are outside the supported range\n");
		return -1;
	}
	if (opts->startup_delay_ms >= opts->stall_ms) {
		fprintf(stderr, "startup-delay-ms must be less than stall-ms\n");
		return -1;
	}
	return 0;
}

int main(int argc, char **argv)
{
	struct options opts;

	if (parse_options(argc, argv, &opts) < 0) {
		usage(stderr, argv[0]);
		return 2;
	}

	return watchdog_run(&opts);
}
