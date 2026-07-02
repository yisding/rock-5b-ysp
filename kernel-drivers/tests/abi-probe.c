// SPDX-License-Identifier: MIT
/*
 * Minimal userspace ABI probe for the RK3588 MPP/RGA compatibility drivers.
 *
 * This intentionally exercises only query/no-op/control ioctls and safe buffer
 * import/release paths that do not submit hardware work.  Save its output on
 * the BSP-derived forward port and on the rewrite boot and diff the two logs
 * when chasing ABI regressions.
 */

#include <errno.h>
#include <fcntl.h>
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
#define RGA_TEST_WIDTH 16U
#define RGA_TEST_HEIGHT 16U
#define RGA_TEST_BYTES_PER_PIXEL 4U
#define RGA_TEST_FORMAT_RGBA8888 0U
#define RGA_TEST_RASTER_MODE 1U
#define MPP_CLIENT_RKVDEC 9U
#define MPP_CLIENT_RKVENC 16U
#define MPP_CLIENT_LIMIT 32U
#define MPP_CODEC_INFO_WIDTH 1U
#define MPP_CODEC_INFO_FLAG_NUMBER 1U
#define BIT32(n) (1U << (n))

struct mpp_probe_codec_info {
	uint32_t type;
	uint32_t flag;
	uint64_t data;
};

static unsigned int failures;
static unsigned int probed_devices;

static void print_status(const char *name, int ret)
{
	if (ret < 0)
		printf("  %-30s ret=-1 errno=%d (%s)\n",
		       name, errno, strerror(errno));
	else
		printf("  %-30s ret=%d\n", name, ret);
}

static void require_ok(const char *name, int ret)
{
	print_status(name, ret);
	if (ret < 0)
		failures++;
}

static int open_optional(const char *path)
{
	int fd = open(path, O_RDWR | O_CLOEXEC);

	if (fd < 0)
		printf("  %-30s ret=-1 errno=%d (%s)\n",
		       path, errno, strerror(errno));
	else
		printf("  %-30s fd=%d\n", path, fd);

	return fd;
}

static void print_escaped_string(const char *label, const unsigned char *buf,
				 size_t size)
{
	size_t i;

	printf("  %-30s \"", label);
	for (i = 0; i < size && buf[i]; i++) {
		unsigned char c = buf[i];

		if (c >= 0x20 && c <= 0x7e && c != '\\' && c != '"')
			putchar(c);
		else
			printf("\\x%02x", c);
	}
	printf("\"\n");
}

static int mpp_cfg(int fd, const char *name, struct mpp_request *req)
{
	int ret;

	errno = 0;
	ret = ioctl(fd, MPP_IOC_CFG_V1, req);
	require_ok(name, ret);

	return ret;
}

static const char *mpp_client_name(uint32_t client_type)
{
	switch (client_type) {
	case MPP_CLIENT_RKVDEC:
		return "RKVDEC";
	case MPP_CLIENT_RKVENC:
		return "RKVENC";
	default:
		return "client";
	}
}

static bool mpp_has_client(uint32_t hw_support, uint32_t client_type)
{
	return client_type < MPP_CLIENT_LIMIT &&
	       (hw_support & BIT32(client_type));
}

static void probe_mpp_client_hw_ids(uint32_t hw_support)
{
	uint32_t client_type;

	for (client_type = 0; client_type < MPP_CLIENT_LIMIT; client_type++) {
		char label[64];
		uint32_t value;
		int fd;

		if (!mpp_has_client(hw_support, client_type))
			continue;

		fd = open_optional("/dev/mpp_service");
		if (fd < 0) {
			failures++;
			return;
		}

		value = client_type;
		snprintf(label, sizeof(label), "INIT_CLIENT_TYPE %s%u",
			 mpp_client_name(client_type), client_type);
		if (!mpp_cfg(fd, label, &(struct mpp_request) {
			.cmd = MPP_CMD_INIT_CLIENT_TYPE,
			.size = sizeof(value),
			.data = &value,
		})) {
			value = client_type;
			snprintf(label, sizeof(label), "QUERY_HW_ID %s%u",
				 mpp_client_name(client_type), client_type);
			if (!mpp_cfg(fd, label, &(struct mpp_request) {
				.cmd = MPP_CMD_QUERY_HW_ID,
				.size = sizeof(value),
				.data = &value,
			}))
				printf("  %-30s %#x\n", "hw_id", value);
		}

		close(fd);
	}
}

static void probe_mpp_session_controls_for_client(uint32_t client_type,
						  uint32_t control_butt)
{
	struct mpp_probe_codec_info info = {
		.type = MPP_CODEC_INFO_WIDTH,
		.flag = MPP_CODEC_INFO_FLAG_NUMBER,
		.data = 1920,
	};
	char label[64];
	uint32_t value;
	int fd;

	fd = open_optional("/dev/mpp_service");
	if (fd < 0) {
		failures++;
		return;
	}

	value = client_type;
	snprintf(label, sizeof(label), "INIT_CLIENT_TYPE %s controls",
		 mpp_client_name(client_type));
	if (mpp_cfg(fd, label, &(struct mpp_request) {
		.cmd = MPP_CMD_INIT_CLIENT_TYPE,
		.size = sizeof(value),
		.data = &value,
	}))
		goto out;

	value = 0;
	mpp_cfg(fd, "INIT_DRIVER_DATA zero", &(struct mpp_request) {
		.cmd = MPP_CMD_INIT_DRIVER_DATA,
		.size = sizeof(value),
		.data = &value,
	});

	mpp_cfg(fd, "SEND_CODEC_INFO width", &(struct mpp_request) {
		.cmd = MPP_CMD_SEND_CODEC_INFO,
		.size = sizeof(info),
		.data = &info,
	});

	if (client_type == MPP_CLIENT_RKVDEC) {
		if (control_butt > MPP_CMD_SET_ERR_REF_HACK) {
			value = 1;
			mpp_cfg(fd, "SET_ERR_REF_HACK", &(struct mpp_request) {
				.cmd = MPP_CMD_SET_ERR_REF_HACK,
				.size = sizeof(value),
				.data = &value,
			});
		} else {
			printf("  %-30s skipped cmd_butt=%#x\n",
			       "SET_ERR_REF_HACK", control_butt);
		}
	}

	mpp_cfg(fd, "RESET_SESSION", &(struct mpp_request) {
		.cmd = MPP_CMD_RESET_SESSION,
	});

out:
	close(fd);
}

static void probe_mpp_session_controls(uint32_t hw_support,
				       uint32_t control_butt)
{
	if (mpp_has_client(hw_support, MPP_CLIENT_RKVDEC))
		probe_mpp_session_controls_for_client(MPP_CLIENT_RKVDEC,
						      control_butt);
	else
		printf("  %-30s skipped hw_support=%#x\n",
		       "RKVDEC controls", hw_support);

	if (mpp_has_client(hw_support, MPP_CLIENT_RKVENC))
		probe_mpp_session_controls_for_client(MPP_CLIENT_RKVENC,
						      control_butt);
	else
		printf("  %-30s skipped hw_support=%#x\n",
		       "RKVENC controls", hw_support);
}

static void probe_mpp_multi_message_init(uint32_t hw_support)
{
	uint32_t client_type;
	uint32_t driver_data = 0;
	struct mpp_request batch[2];
	int fd;

	if (mpp_has_client(hw_support, MPP_CLIENT_RKVDEC))
		client_type = MPP_CLIENT_RKVDEC;
	else if (mpp_has_client(hw_support, MPP_CLIENT_RKVENC))
		client_type = MPP_CLIENT_RKVENC;
	else {
		printf("  %-30s skipped hw_support=%#x\n",
		       "MULTI init+driver", hw_support);
		return;
	}

	memset(batch, 0, sizeof(batch));
	batch[0].cmd = MPP_CMD_INIT_CLIENT_TYPE;
	batch[0].flags = MPP_FLAGS_MULTI_MSG;
	batch[0].size = sizeof(client_type);
	batch[0].data = &client_type;
	batch[1].cmd = MPP_CMD_INIT_DRIVER_DATA;
	batch[1].flags = MPP_FLAGS_MULTI_MSG | MPP_FLAGS_LAST_MSG;
	batch[1].size = sizeof(driver_data);
	batch[1].data = &driver_data;

	fd = open_optional("/dev/mpp_service");
	if (fd < 0) {
		failures++;
		return;
	}

	mpp_cfg(fd, "MULTI init+driver", batch);
	close(fd);
}

static void probe_mpp(void)
{
	static const uint32_t cmd_groups[] = {
		MPP_CMD_QUERY_BASE,
		MPP_CMD_INIT_BASE,
		MPP_CMD_SEND_BASE,
		MPP_CMD_POLL_BASE,
		MPP_CMD_CONTROL_BASE,
	};
	int fd;
	uint32_t value;
	uint32_t hw_support = 0;
	uint32_t control_butt = 0;
	size_t i;

	puts("mpp:");
	printf("  %-30s %#lx\n", "MPP_IOC_CFG_V1", (unsigned long)MPP_IOC_CFG_V1);
	printf("  %-30s %#lx\n", "MPP_IOC_CFG_V2", (unsigned long)MPP_IOC_CFG_V2);
	printf("  %-30s %zu\n", "sizeof mpp_request", sizeof(struct mpp_request));
	printf("  %-30s %zu\n", "sizeof mpp_bat_msg", sizeof(struct mpp_bat_msg));
	printf("  %-30s %#x\n", "MPP_FLAGS_MULTI_MSG", MPP_FLAGS_MULTI_MSG);
	printf("  %-30s %#x\n", "MPP_FLAGS_LAST_MSG", MPP_FLAGS_LAST_MSG);
	printf("  %-30s %#x\n", "MPP_FLAGS_REG_FD_NO_TRANS",
	       MPP_FLAGS_REG_FD_NO_TRANS);
	printf("  %-30s %#x\n", "MPP_FLAGS_REG_OFFSET_ALONE",
	       MPP_FLAGS_REG_OFFSET_ALONE);
	printf("  %-30s %#x\n", "MPP_FLAGS_POLL_NON_BLOCK",
	       MPP_FLAGS_POLL_NON_BLOCK);

	fd = open_optional("/dev/mpp_service");
	if (fd < 0)
		return;
	probed_devices++;

	value = 0;
	mpp_cfg(fd, "QUERY_HW_SUPPORT", &(struct mpp_request) {
		.cmd = MPP_CMD_QUERY_HW_SUPPORT,
		.size = sizeof(value),
		.data = &value,
	});
	printf("  %-30s %#x\n", "hw_support", value);
	hw_support = value;

	for (i = 0; i < ARRAY_SIZE(cmd_groups); i++) {
		char label[64];

		value = cmd_groups[i];
		snprintf(label, sizeof(label), "QUERY_CMD_SUPPORT %#x", value);
		if (!mpp_cfg(fd, label, &(struct mpp_request) {
			.cmd = MPP_CMD_QUERY_CMD_SUPPORT,
			.size = sizeof(value),
			.data = &value,
		})) {
			printf("  %-30s %#x\n", "cmd_butt", value);
			if (cmd_groups[i] == MPP_CMD_CONTROL_BASE)
				control_butt = value;
		}
	}

	probe_mpp_client_hw_ids(hw_support);
	probe_mpp_session_controls(hw_support, control_butt);
	probe_mpp_multi_message_init(hw_support);

	errno = 0;
	value = 0;
	print_status("MPP_IOC_CFG_V2 rejected",
		     ioctl(fd, MPP_IOC_CFG_V2, &(struct mpp_request) {
			     .cmd = MPP_CMD_QUERY_HW_SUPPORT,
			     .size = sizeof(value),
			     .data = &value,
		     }));

	close(fd);
}

static void print_rga_hw_versions(const struct rga_hw_versions_t *versions)
{
	uint32_t i;

	printf("  %-30s %u\n", "hw_version_count", versions->size);
	for (i = 0; i < versions->size && i < RGA_HW_SIZE; i++) {
		char label[64];

		snprintf(label, sizeof(label), "hw[%u]", i);
		printf("  %-30s %u.%u.%05x ", label,
		       versions->version[i].major,
		       versions->version[i].minor,
		       versions->version[i].revision);
		print_escaped_string("str", versions->version[i].str,
				     sizeof(versions->version[i].str));
	}
}

static int rga_import_va_handle(int fd, void *memory, uint32_t size,
				const char *ioctl_label,
				const char *handle_label, uint32_t *handle)
{
	struct rga_external_buffer buffers[1] = {};
	struct rga_buffer_pool pool;
	int ret;

	memset(&pool, 0, sizeof(pool));
	buffers[0].memory = (uint64_t)(uintptr_t)memory;
	buffers[0].type = RGA_VIRTUAL_ADDRESS;
	buffers[0].memory_info.size = size;
	pool.buffers = (uint64_t)(uintptr_t)buffers;
	pool.size = ARRAY_SIZE(buffers);

	errno = 0;
	ret = ioctl(fd, RGA_IOC_IMPORT_BUFFER, &pool);
	require_ok(ioctl_label, ret);
	printf("  %-30s %u\n", handle_label, buffers[0].handle);

	if (ret < 0)
		return ret;
	if (!buffers[0].handle) {
		printf("  %-30s zero handle\n", "RGA import result");
		failures++;
		return -EINVAL;
	}

	*handle = buffers[0].handle;
	return 0;
}

static void rga_release_handle(int fd, uint32_t handle, const char *label)
{
	struct rga_external_buffer buffers[1] = {};
	struct rga_buffer_pool pool;

	if (!handle)
		return;

	memset(&pool, 0, sizeof(pool));
	buffers[0].handle = handle;
	pool.buffers = (uint64_t)(uintptr_t)buffers;
	pool.size = ARRAY_SIZE(buffers);

	errno = 0;
	require_ok(label, ioctl(fd, RGA_IOC_RELEASE_BUFFER, &pool));
}

static void *rga_alloc_test_page(size_t *size)
{
	long page_size;
	void *memory = NULL;
	int ret;

	page_size = sysconf(_SC_PAGESIZE);
	if (page_size <= 0 || page_size > UINT32_MAX) {
		printf("  %-30s page_size=%ld\n", "invalid page size", page_size);
		failures++;
		return NULL;
	}

	ret = posix_memalign(&memory, (size_t)page_size, (size_t)page_size);
	if (ret) {
		printf("  %-30s ret=%d (%s)\n",
		       "posix_memalign", ret, strerror(ret));
		failures++;
		return NULL;
	}
	memset(memory, 0xa5, (size_t)page_size);
	*size = (size_t)page_size;

	return memory;
}

static void probe_rga_virtual_import_release(int fd)
{
	uint32_t handle = 0;
	size_t size;
	void *memory;

	memory = rga_alloc_test_page(&size);
	if (!memory)
		return;

	if (!rga_import_va_handle(fd, memory, (uint32_t)size,
				  "RGA_IOC_IMPORT_BUFFER va",
				  "virtual_import_handle", &handle))
		rga_release_handle(fd, handle, "RGA_IOC_RELEASE_BUFFER va");

	free(memory);
}

static void rga_fill_test_img(rga_img_info_t *img, uint32_t handle)
{
	img->yrgb_addr = handle;
	img->format = RGA_TEST_FORMAT_RGBA8888;
	img->act_w = RGA_TEST_WIDTH;
	img->act_h = RGA_TEST_HEIGHT;
	img->vir_w = RGA_TEST_WIDTH;
	img->vir_h = RGA_TEST_HEIGHT;
	img->rd_mode = RGA_TEST_RASTER_MODE;
}

static void probe_rga_request_config(int fd)
{
	struct rga_user_request request;
	struct rga_req task;
	uint32_t src_handle = 0;
	uint32_t dst_handle = 0;
	uint32_t request_id = 0;
	size_t src_size;
	size_t dst_size;
	void *src_memory;
	void *dst_memory;
	int ret;

	src_memory = rga_alloc_test_page(&src_size);
	if (!src_memory)
		return;
	dst_memory = rga_alloc_test_page(&dst_size);
	if (!dst_memory)
		goto out_free_src;

	errno = 0;
	ret = ioctl(fd, RGA_IOC_REQUEST_CREATE, &request_id);
	require_ok("RGA_IOC_REQUEST_CREATE cfg", ret);
	printf("  %-30s %u\n", "config_request_id", request_id);
	if (ret < 0)
		goto out_free_dst;
	if (!request_id) {
		printf("  %-30s zero id\n", "RGA request create");
		failures++;
		goto out_free_dst;
	}

	ret = rga_import_va_handle(fd, src_memory, (uint32_t)src_size,
				   "RGA_IOC_IMPORT_BUFFER src",
				   "config_src_handle", &src_handle);
	if (ret)
		goto out_cancel;
	ret = rga_import_va_handle(fd, dst_memory, (uint32_t)dst_size,
				   "RGA_IOC_IMPORT_BUFFER dst",
				   "config_dst_handle", &dst_handle);
	if (ret)
		goto out_cancel;

	memset(&task, 0, sizeof(task));
	task.render_mode = bitblt_mode;
	task.handle_flag = 1;
	task.cosa = 65536;
	task.clip.xmin = 0;
	task.clip.ymin = 0;
	task.clip.xmax = RGA_TEST_WIDTH - 1;
	task.clip.ymax = RGA_TEST_HEIGHT - 1;
	rga_fill_test_img(&task.src, src_handle);
	rga_fill_test_img(&task.dst, dst_handle);

	memset(&request, 0, sizeof(request));
	request.task_ptr = (uint64_t)(uintptr_t)&task;
	request.task_num = 1;
	request.id = request_id;
	request.sync_mode = RGA_BLIT_SYNC;

	errno = 0;
	require_ok("RGA_IOC_REQUEST_CONFIG copy",
		   ioctl(fd, RGA_IOC_REQUEST_CONFIG, &request));

out_cancel:
	errno = 0;
	require_ok("RGA_IOC_REQUEST_CANCEL cfg",
		   ioctl(fd, RGA_IOC_REQUEST_CANCEL, &request_id));
	rga_release_handle(fd, src_handle, "RGA_IOC_RELEASE_BUFFER src");
	rga_release_handle(fd, dst_handle, "RGA_IOC_RELEASE_BUFFER dst");
out_free_dst:
	free(dst_memory);
out_free_src:
	free(src_memory);
}

static void probe_rga(void)
{
	struct rga_hw_versions_t hw_versions;
	struct rga_version_t driver_version;
	unsigned char legacy[RGA_VERSION_SIZE];
	int fd;

	puts("rga:");
	printf("  %-30s %#x\n", "RGA_BLIT_SYNC", RGA_BLIT_SYNC);
	printf("  %-30s %#x\n", "RGA_BLIT_ASYNC", RGA_BLIT_ASYNC);
	printf("  %-30s %#x\n", "RGA_FLUSH", RGA_FLUSH);
	printf("  %-30s %#x\n", "RGA_GET_RESULT", RGA_GET_RESULT);
	printf("  %-30s %#x\n", "RGA_GET_VERSION", RGA_GET_VERSION);
	printf("  %-30s %#x\n", "RGA_CACHE_FLUSH", RGA_CACHE_FLUSH);
	printf("  %-30s %#x\n", "RGA2_GET_RESULT", RGA2_GET_RESULT);
	printf("  %-30s %#x\n", "RGA2_GET_VERSION", RGA2_GET_VERSION);
	printf("  %-30s %#lx\n", "RGA_IOC_GET_DRVIER_VERSION",
	       (unsigned long)RGA_IOC_GET_DRVIER_VERSION);
	printf("  %-30s %#lx\n", "RGA_IOC_GET_HW_VERSION",
	       (unsigned long)RGA_IOC_GET_HW_VERSION);
	printf("  %-30s %#lx\n", "RGA_IOC_IMPORT_BUFFER",
	       (unsigned long)RGA_IOC_IMPORT_BUFFER);
	printf("  %-30s %#lx\n", "RGA_IOC_RELEASE_BUFFER",
	       (unsigned long)RGA_IOC_RELEASE_BUFFER);
	printf("  %-30s %#lx\n", "RGA_IOC_REQUEST_CREATE",
	       (unsigned long)RGA_IOC_REQUEST_CREATE);
	printf("  %-30s %#lx\n", "RGA_IOC_REQUEST_CONFIG",
	       (unsigned long)RGA_IOC_REQUEST_CONFIG);
	printf("  %-30s %#lx\n", "RGA_IOC_REQUEST_CANCEL",
	       (unsigned long)RGA_IOC_REQUEST_CANCEL);
	printf("  %-30s %zu\n", "sizeof rga_version_t",
	       sizeof(struct rga_version_t));
	printf("  %-30s %zu\n", "sizeof rga_hw_versions_t",
	       sizeof(struct rga_hw_versions_t));
	printf("  %-30s %zu\n", "sizeof rga_buffer_pool",
	       sizeof(struct rga_buffer_pool));
	printf("  %-30s %zu\n", "sizeof rga_req", sizeof(struct rga_req));
	printf("  %-30s %zu\n", "sizeof rga_user_request",
	       sizeof(struct rga_user_request));

	fd = open_optional("/dev/rga");
	if (fd < 0)
		return;
	probed_devices++;

	memset(legacy, 0, sizeof(legacy));
	errno = 0;
	require_ok("RGA_GET_VERSION",
		   ioctl(fd, RGA_GET_VERSION, legacy));
	print_escaped_string("legacy_version", legacy, sizeof(legacy));

	memset(legacy, 0, sizeof(legacy));
	errno = 0;
	require_ok("RGA2_GET_VERSION",
		   ioctl(fd, RGA2_GET_VERSION, legacy));
	print_escaped_string("legacy_rga2_version", legacy, sizeof(legacy));

	memset(&driver_version, 0, sizeof(driver_version));
	errno = 0;
	require_ok("RGA_IOC_GET_DRVIER_VERSION",
		   ioctl(fd, RGA_IOC_GET_DRVIER_VERSION, &driver_version));
	printf("  %-30s %u.%u.%05x\n", "driver_version_tuple",
	       driver_version.major, driver_version.minor,
	       driver_version.revision);
	print_escaped_string("driver_version_str", driver_version.str,
			     sizeof(driver_version.str));

	memset(&hw_versions, 0, sizeof(hw_versions));
	errno = 0;
	require_ok("RGA_IOC_GET_HW_VERSION",
		   ioctl(fd, RGA_IOC_GET_HW_VERSION, &hw_versions));
	print_rga_hw_versions(&hw_versions);

	errno = 0;
	require_ok("RGA_CACHE_FLUSH", ioctl(fd, RGA_CACHE_FLUSH, 0));
	errno = 0;
	require_ok("RGA_FLUSH", ioctl(fd, RGA_FLUSH, 0));
	errno = 0;
	require_ok("RGA_GET_RESULT", ioctl(fd, RGA_GET_RESULT, 0));
	errno = 0;
	require_ok("RGA2_GET_RESULT", ioctl(fd, RGA2_GET_RESULT, 0));

	probe_rga_virtual_import_release(fd);
	probe_rga_request_config(fd);

	close(fd);
}

int main(void)
{
	puts("rkcompat abi probe");

	probe_mpp();
	probe_rga();

	if (!probed_devices) {
		puts("SKIP: neither /dev/mpp_service nor /dev/rga is present");
		return 77;
	}

	if (failures) {
		printf("FAIL: %u required ABI probe(s) failed\n", failures);
		return 1;
	}

	puts("PASS: required ABI probes succeeded on present devices");
	return 0;
}
