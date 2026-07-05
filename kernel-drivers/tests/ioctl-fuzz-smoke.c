// SPDX-License-Identifier: MIT
/*
 * Bounded non-submit ioctl fuzzer for the RK3588 MPP/RGA compatibility ABI.
 *
 * This is not a replacement for syzkaller. It is a cheap first pass that can be
 * run on the forward-port or rewrite kernels to shake parser, copy_from_user,
 * import/release, and request-lifetime edges without deliberately submitting
 * hardware jobs.
 */

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#ifndef __user
#define __user
#endif
#include <linux/rk-mpp.h>

#include "rga_ioctl.h"

#ifndef RGA_CACHE_FLUSH
#define RGA_CACHE_FLUSH 0x501c
#endif

#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))
#define DEFAULT_ITERS 256U
#define DEFAULT_TIMEOUT_S 30U
#define MPP_FUZZ_DRIVER_LIMIT (128U * 1024U)
#define MPP_FUZZ_PAYLOAD_SIZE (MPP_FUZZ_DRIVER_LIMIT + 512U)
#define RGA_FUZZ_BUFFER_SIZE 4096U
#define MPP_CLIENT_RKVDEC 9U
#define MPP_CLIENT_RKVENC 16U
#define MPP_CODEC_INFO_WIDTH 1U
#define MPP_CODEC_INFO_FLAG_NUMBER 1U

struct fuzz_rng {
	uint64_t state;
};

struct fuzz_stats {
	unsigned int calls;
	unsigned int ok;
	unsigned int errors;
};

struct mpp_fuzz_codec_info {
	uint32_t type;
	uint32_t flag;
	uint64_t data;
};

static uint8_t mpp_payload[MPP_FUZZ_PAYLOAD_SIZE];
static uint8_t rga_buffer[RGA_FUZZ_BUFFER_SIZE] __attribute__((aligned(4096)));

static uint64_t rng_next(struct fuzz_rng *rng)
{
	uint64_t x = rng->state;

	if (!x)
		x = 0x9e3779b97f4a7c15ULL;

	x ^= x << 7;
	x ^= x >> 9;
	x *= 0x9e3779b97f4a7c15ULL;
	rng->state = x;

	return x;
}

static uint32_t rng_u32(struct fuzz_rng *rng)
{
	return (uint32_t)rng_next(rng);
}

static unsigned int rng_mod(struct fuzz_rng *rng, unsigned int mod)
{
	return mod ? (unsigned int)(rng_next(rng) % mod) : 0;
}

static bool env_enabled(const char *name)
{
	const char *value = getenv(name);

	return value && strcmp(value, "0") && strcmp(value, "false") &&
	       strcmp(value, "FALSE") && strcmp(value, "no") &&
	       strcmp(value, "NO");
}

static uint64_t env_u64(const char *name, uint64_t fallback)
{
	const char *value = getenv(name);
	char *end = NULL;
	uint64_t parsed;

	if (!value || !*value)
		return fallback;

	errno = 0;
	parsed = strtoull(value, &end, 0);
	if (errno || !end || *end)
		return fallback;

	return parsed;
}

static void fill_random(struct fuzz_rng *rng, void *data, size_t size)
{
	uint8_t *bytes = data;
	size_t i;

	for (i = 0; i < size; i++)
		bytes[i] = (uint8_t)rng_u32(rng);
}

static void timeout_handler(int sig)
{
	(void)sig;
	_exit(124);
}

static int open_optional(const char *path)
{
	int fd = open(path, O_RDWR | O_CLOEXEC);

	if (fd < 0)
		printf("%-18s absent errno=%d (%s)\n",
		       path, errno, strerror(errno));
	else
		printf("%-18s fd=%d\n", path, fd);

	return fd;
}

static int fuzz_ioctl(int fd, unsigned long cmd, void *arg,
		      struct fuzz_stats *stats, bool verbose,
		      const char *label)
{
	int saved_errno;
	int ret;

	errno = 0;
	ret = ioctl(fd, cmd, arg);
	saved_errno = errno;

	stats->calls++;
	if (ret < 0)
		stats->errors++;
	else
		stats->ok++;

	if (verbose) {
		if (ret < 0)
			printf("  %-28s ret=-1 errno=%d (%s)\n",
			       label, saved_errno, strerror(saved_errno));
		else
			printf("  %-28s ret=%d\n", label, ret);
	}

	return ret;
}

static void *maybe_bad_user_ptr(struct fuzz_rng *rng, void *good)
{
	switch (rng_mod(rng, 16)) {
	case 0:
		return NULL;
	case 1:
		return (void *)(uintptr_t)1;
	default:
		return good;
	}
}

static uint32_t mpp_fuzz_size(struct fuzz_rng *rng, uint32_t natural)
{
	switch (rng_mod(rng, 8)) {
	case 0:
		return 0;
	case 1:
		return natural ? natural - 1 : 0;
	case 2:
		return natural + 1;
	case 3:
		return MPP_FUZZ_DRIVER_LIMIT + rng_mod(rng, 512);
	default:
		return natural;
	}
}

static uint32_t mpp_fuzz_flags(struct fuzz_rng *rng, uint32_t base)
{
	static const uint32_t noisy_bits[] = {
		0,
		MPP_FLAGS_REG_FD_NO_TRANS,
		MPP_FLAGS_REG_OFFSET_ALONE,
		MPP_FLAGS_POLL_NON_BLOCK,
		MPP_FLAGS_SECURE_MODE,
		0x80000000U,
	};

	return base | noisy_bits[rng_mod(rng, ARRAY_SIZE(noisy_bits))];
}

static void *mpp_fuzz_data_ptr(struct fuzz_rng *rng, void *good,
			       size_t good_size, uint32_t requested_size)
{
	if (requested_size > good_size)
		good = mpp_payload;

	return maybe_bad_user_ptr(rng, good);
}

static void fuzz_mpp_one(int fd, struct fuzz_rng *rng,
			 struct fuzz_stats *stats, bool verbose)
{
	struct mpp_fuzz_codec_info codec[4];
	struct mpp_request batch[2];
	struct mpp_request req;
	struct mpp_bat_msg bat;
	uint32_t value;
	uint16_t trans[256];
	uint32_t poll_data[64];
	unsigned int i;

	memset(&req, 0, sizeof(req));
	fill_random(rng, mpp_payload, sizeof(mpp_payload));
	fill_random(rng, trans, sizeof(trans));
	fill_random(rng, poll_data, sizeof(poll_data));
	fill_random(rng, codec, sizeof(codec));
	fill_random(rng, &bat, sizeof(bat));

	switch (rng_mod(rng, 13)) {
	case 0:
		value = rng_u32(rng);
		req.cmd = MPP_CMD_QUERY_HW_SUPPORT;
		req.flags = mpp_fuzz_flags(rng, 0);
		req.size = mpp_fuzz_size(rng, sizeof(value));
		req.data = mpp_fuzz_data_ptr(rng, &value, sizeof(value),
					     req.size);
		fuzz_ioctl(fd, MPP_IOC_CFG_V1, &req, stats, verbose,
			   "mpp QUERY_HW_SUPPORT");
		break;
	case 1:
		value = rng_u32(rng);
		if (rng_mod(rng, 2)) {
			static const uint32_t groups[] = {
				MPP_CMD_QUERY_BASE,
				MPP_CMD_INIT_BASE,
				MPP_CMD_SEND_BASE,
				MPP_CMD_POLL_BASE,
				MPP_CMD_CONTROL_BASE,
			};

			value = groups[rng_mod(rng, ARRAY_SIZE(groups))];
		}
		req.cmd = MPP_CMD_QUERY_CMD_SUPPORT;
		req.flags = mpp_fuzz_flags(rng, 0);
		req.size = mpp_fuzz_size(rng, sizeof(value));
		req.data = mpp_fuzz_data_ptr(rng, &value, sizeof(value),
					     req.size);
		fuzz_ioctl(fd, MPP_IOC_CFG_V1, &req, stats, verbose,
			   "mpp QUERY_CMD_SUPPORT");
		break;
	case 2:
		value = rng_mod(rng, 3) == 0 ? MPP_CLIENT_RKVDEC :
			rng_mod(rng, 2) == 0 ? MPP_CLIENT_RKVENC : rng_u32(rng);
		req.cmd = MPP_CMD_INIT_CLIENT_TYPE;
		req.flags = mpp_fuzz_flags(rng, 0);
		req.size = mpp_fuzz_size(rng, sizeof(value));
		req.data = mpp_fuzz_data_ptr(rng, &value, sizeof(value),
					     req.size);
		fuzz_ioctl(fd, MPP_IOC_CFG_V1, &req, stats, verbose,
			   "mpp INIT_CLIENT_TYPE");
		break;
	case 3:
		value = rng_u32(rng);
		req.cmd = MPP_CMD_INIT_DRIVER_DATA;
		req.flags = mpp_fuzz_flags(rng, 0);
		req.size = mpp_fuzz_size(rng, sizeof(value));
		req.data = mpp_fuzz_data_ptr(rng, &value, sizeof(value),
					     req.size);
		fuzz_ioctl(fd, MPP_IOC_CFG_V1, &req, stats, verbose,
			   "mpp INIT_DRIVER_DATA");
		break;
	case 4:
		req.cmd = MPP_CMD_INIT_TRANS_TABLE;
		req.flags = mpp_fuzz_flags(rng, 0);
		req.size = mpp_fuzz_size(rng, sizeof(trans));
		req.data = mpp_fuzz_data_ptr(rng, trans, sizeof(trans),
					     req.size);
		fuzz_ioctl(fd, MPP_IOC_CFG_V1, &req, stats, verbose,
			   "mpp INIT_TRANS_TABLE");
		break;
	case 5:
		codec[0].type = MPP_CODEC_INFO_WIDTH;
		codec[0].flag = MPP_CODEC_INFO_FLAG_NUMBER;
		codec[0].data = 1920 + rng_mod(rng, 4096);
		req.cmd = MPP_CMD_SEND_CODEC_INFO;
		req.flags = mpp_fuzz_flags(rng, 0);
		req.size = mpp_fuzz_size(rng, sizeof(codec));
		req.data = mpp_fuzz_data_ptr(rng, codec, sizeof(codec),
					     req.size);
		fuzz_ioctl(fd, MPP_IOC_CFG_V1, &req, stats, verbose,
			   "mpp SEND_CODEC_INFO");
		break;
	case 6:
		req.cmd = MPP_CMD_SET_ERR_REF_HACK;
		req.flags = mpp_fuzz_flags(rng, 0);
		req.size = rng_mod(rng, 8192);
		req.data = maybe_bad_user_ptr(rng, mpp_payload);
		fuzz_ioctl(fd, MPP_IOC_CFG_V1, &req, stats, verbose,
			   "mpp SET_ERR_REF_HACK");
		break;
	case 7:
		req.cmd = MPP_CMD_RESET_SESSION;
		req.flags = mpp_fuzz_flags(rng, 0);
		req.size = rng_mod(rng, 2) ? 0 : sizeof(value);
		req.data = rng_mod(rng, 2) ? NULL : &value;
		fuzz_ioctl(fd, MPP_IOC_CFG_V1, &req, stats, verbose,
			   "mpp RESET_SESSION");
		break;
	case 8:
		value = rng_u32(rng);
		req.cmd = MPP_CMD_RELEASE_FD;
		req.flags = mpp_fuzz_flags(rng, 0);
		req.size = mpp_fuzz_size(rng, sizeof(value));
		req.data = mpp_fuzz_data_ptr(rng, &value, sizeof(value),
					     req.size);
		fuzz_ioctl(fd, MPP_IOC_CFG_V1, &req, stats, verbose,
			   "mpp RELEASE_FD");
		break;
	case 9:
		bat.fd = UINT32_MAX;
		if (rng_mod(rng, 3) == 0)
			bat.flag = MPP_BAT_MSG_DONE;
		req.cmd = MPP_CMD_SET_SESSION_FD;
		req.flags = mpp_fuzz_flags(rng, 0);
		req.size = mpp_fuzz_size(rng, sizeof(bat));
		req.data = mpp_fuzz_data_ptr(rng, &bat, sizeof(bat),
					     req.size);
		fuzz_ioctl(fd, MPP_IOC_CFG_V1, &req, stats, verbose,
			   "mpp SET_SESSION_FD");
		break;
	case 10:
		req.cmd = rng_mod(rng, 2) ? MPP_CMD_POLL_HW_FINISH :
			MPP_CMD_POLL_HW_IRQ;
		req.flags = mpp_fuzz_flags(rng, MPP_FLAGS_POLL_NON_BLOCK);
		req.size = mpp_fuzz_size(rng, sizeof(poll_data));
		req.data = mpp_fuzz_data_ptr(rng, poll_data,
					     sizeof(poll_data), req.size);
		fuzz_ioctl(fd, MPP_IOC_CFG_V1, &req, stats, verbose,
			   "mpp POLL");
		break;
	case 11:
		memset(batch, 0, sizeof(batch));
		value = rng_mod(rng, 2) ? MPP_CLIENT_RKVDEC : MPP_CLIENT_RKVENC;
		batch[0].cmd = MPP_CMD_INIT_CLIENT_TYPE;
		batch[0].flags = MPP_FLAGS_MULTI_MSG;
		batch[0].size = sizeof(value);
		batch[0].data = &value;
		batch[1].cmd = MPP_CMD_INIT_DRIVER_DATA;
		batch[1].flags = MPP_FLAGS_MULTI_MSG | MPP_FLAGS_LAST_MSG;
		batch[1].size = sizeof(value);
		batch[1].data = &value;
		for (i = 0; i < ARRAY_SIZE(batch); i++) {
			if (rng_mod(rng, 8) == 0)
				batch[i].size = rng_mod(rng, 8192);
		}
		fuzz_ioctl(fd, MPP_IOC_CFG_V1, batch, stats, verbose,
			   "mpp MULTI init");
		break;
	default:
		req.cmd = MPP_CMD_QUERY_HW_SUPPORT;
		req.size = sizeof(value);
		req.data = &value;
		fuzz_ioctl(fd, MPP_IOC_CFG_V2, &req, stats, verbose,
			   "mpp CFG_V2");
		break;
	}
}

static void fuzz_mpp(int fd, struct fuzz_rng *rng, unsigned int iters,
		     bool verbose)
{
	struct fuzz_stats stats = {};
	unsigned int i;

	for (i = 0; i < iters; i++)
		fuzz_mpp_one(fd, rng, &stats, verbose);

	printf("mpp fuzz: calls=%u ok=%u errors=%u\n",
	       stats.calls, stats.ok, stats.errors);
}

static void rga_release_handle(int fd, uint32_t handle, struct fuzz_stats *stats,
			       bool verbose)
{
	struct rga_external_buffer buffer = {};
	struct rga_buffer_pool pool = {};

	if (!handle)
		return;

	buffer.handle = handle;
	pool.buffers = (uint64_t)(uintptr_t)&buffer;
	pool.size = 1;
	fuzz_ioctl(fd, RGA_IOC_RELEASE_BUFFER, &pool, stats, verbose,
		   "rga RELEASE_BUFFER handle");
}

static void fuzz_rga_import(int fd, struct fuzz_rng *rng,
			    struct fuzz_stats *stats, bool verbose)
{
	struct rga_external_buffer buffers[6];
	struct rga_buffer_pool pool;
	unsigned int i;

	memset(buffers, 0, sizeof(buffers));
	memset(&pool, 0, sizeof(pool));

	pool.buffers = (uint64_t)(uintptr_t)maybe_bad_user_ptr(rng, buffers);
	pool.size = rng_mod(rng, ARRAY_SIZE(buffers) + 1);

	for (i = 0; i < ARRAY_SIZE(buffers); i++) {
		unsigned int type = rng_mod(rng, 4);

		buffers[i].type = type;
		buffers[i].memory_info.width = rng_mod(rng, 8193);
		buffers[i].memory_info.height = rng_mod(rng, 8193);
		buffers[i].memory_info.format = rng_u32(rng);
		buffers[i].memory_info.size = rng_mod(rng, RGA_FUZZ_BUFFER_SIZE * 2);

		switch (type) {
		case RGA_VIRTUAL_ADDRESS:
			buffers[i].memory = (uint64_t)(uintptr_t)
				maybe_bad_user_ptr(rng, rga_buffer);
			if (!buffers[i].memory_info.size)
				buffers[i].memory_info.size = RGA_FUZZ_BUFFER_SIZE;
			break;
		case RGA_PHYSICAL_ADDRESS:
			buffers[i].memory = rng_u32(rng) & ~0xfffU;
			if (!buffers[i].memory_info.size)
				buffers[i].memory_info.size = 4096;
			break;
		case RGA_DMA_BUFFER:
			buffers[i].memory = (uint64_t)(int32_t)rng_u32(rng);
			if (!buffers[i].memory_info.size)
				buffers[i].memory_info.size = 4096;
			break;
		default:
			buffers[i].type = rng_u32(rng);
			buffers[i].memory = rng_next(rng);
			break;
		}
	}

	if (!fuzz_ioctl(fd, RGA_IOC_IMPORT_BUFFER, &pool, stats, verbose,
			"rga IMPORT_BUFFER")) {
		for (i = 0; i < ARRAY_SIZE(buffers); i++)
			rga_release_handle(fd, buffers[i].handle, stats, verbose);
	}
}

static void fuzz_rga_one(int fd, struct fuzz_rng *rng,
			 struct fuzz_stats *stats, bool verbose)
{
	struct rga_hw_versions_t hw_versions;
	struct rga_version_t version;
	uint8_t legacy[16];
	uint32_t id;
	uint32_t random_handle;

	switch (rng_mod(rng, 10)) {
	case 0:
		memset(legacy, 0, sizeof(legacy));
		fuzz_ioctl(fd, RGA_GET_VERSION, legacy, stats, verbose,
			   "rga GET_VERSION");
		break;
	case 1:
		memset(legacy, 0, sizeof(legacy));
		fuzz_ioctl(fd, RGA2_GET_VERSION, legacy, stats, verbose,
			   "rga2 GET_VERSION");
		break;
	case 2:
		memset(&version, 0, sizeof(version));
		fuzz_ioctl(fd, RGA_IOC_GET_DRVIER_VERSION, &version,
			   stats, verbose, "rga GET_DRIVER_VERSION");
		break;
	case 3:
		memset(&hw_versions, 0, sizeof(hw_versions));
		fuzz_ioctl(fd, RGA_IOC_GET_HW_VERSION, &hw_versions,
			   stats, verbose, "rga GET_HW_VERSION");
		break;
	case 4:
		fuzz_ioctl(fd, RGA_CACHE_FLUSH, NULL, stats, verbose,
			   "rga CACHE_FLUSH");
		break;
	case 5:
		fuzz_ioctl(fd, RGA_FLUSH, NULL, stats, verbose,
			   "rga FLUSH");
		break;
	case 6:
		fuzz_ioctl(fd, rng_mod(rng, 2) ? RGA_GET_RESULT : RGA2_GET_RESULT,
			   NULL, stats, verbose, "rga GET_RESULT");
		break;
	case 7:
		fuzz_rga_import(fd, rng, stats, verbose);
		break;
	case 8:
		random_handle = rng_u32(rng);
		rga_release_handle(fd, random_handle, stats, verbose);
		break;
	default:
		id = rng_u32(rng);
		if (!fuzz_ioctl(fd, RGA_IOC_REQUEST_CREATE, &id, stats, verbose,
				"rga REQUEST_CREATE"))
			fuzz_ioctl(fd, RGA_IOC_REQUEST_CANCEL, &id, stats,
				   verbose, "rga REQUEST_CANCEL created");
		id = rng_u32(rng);
		fuzz_ioctl(fd, RGA_IOC_REQUEST_CANCEL, &id, stats, verbose,
			   "rga REQUEST_CANCEL random");
		break;
	}
}

static void fuzz_rga(int fd, struct fuzz_rng *rng, unsigned int iters,
		     bool verbose)
{
	struct fuzz_stats stats = {};
	unsigned int i;

	for (i = 0; i < iters; i++)
		fuzz_rga_one(fd, rng, &stats, verbose);

	printf("rga fuzz: calls=%u ok=%u errors=%u\n",
	       stats.calls, stats.ok, stats.errors);
}

int main(void)
{
	struct fuzz_rng rng = {
		.state = env_u64("IOCTL_FUZZ_SEED", 0x726b333538385953ULL),
	};
	unsigned int iters = (unsigned int)env_u64("IOCTL_FUZZ_ITERS",
						  DEFAULT_ITERS);
	unsigned int timeout = (unsigned int)env_u64("IOCTL_FUZZ_TIMEOUT",
						    DEFAULT_TIMEOUT_S);
	bool verbose = env_enabled("IOCTL_FUZZ_VERBOSE");
	int mpp_fd;
	int rga_fd;

	if (!iters)
		iters = DEFAULT_ITERS;
	if (!timeout)
		timeout = DEFAULT_TIMEOUT_S;

	signal(SIGALRM, timeout_handler);
	alarm(timeout);

	printf("rkcompat ioctl fuzz smoke: seed=%#llx iterations=%u timeout=%us\n",
	       (unsigned long long)rng.state, iters, timeout);

	mpp_fd = open_optional("/dev/mpp_service");
	rga_fd = open_optional("/dev/rga");

	if (mpp_fd < 0 && rga_fd < 0) {
		puts("SKIP: neither /dev/mpp_service nor /dev/rga is present");
		return 77;
	}

	if (mpp_fd >= 0) {
		fuzz_mpp(mpp_fd, &rng, iters, verbose);
		close(mpp_fd);
	}

	if (rga_fd >= 0) {
		fuzz_rga(rga_fd, &rng, iters, verbose);
		close(rga_fd);
	}

	puts("PASS: non-submit ioctl fuzz smoke completed");
	return 0;
}
