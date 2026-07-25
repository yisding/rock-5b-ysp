/* Deterministic reproducer for the mpp_process_request list_add double-add WARN.
 * Root cause: MPP_CMD_INIT_CLIENT_TYPE calls mpp_session_attach_workqueue()
 * (list_add_tail on session->session_link) with no re-init guard, so issuing it
 * twice on the same /dev/mpp_service session double-adds the already-linked node.
 * Unprivileged. WARN-level (DEBUG_LIST); also leaks the first session->dma.
 */
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <linux/rk-mpp.h>

/* MPP_DEVICE type: pick a supported one at runtime via QUERY_HW_SUPPORT bitmap. */
int main(void)
{
	int fd = open("/dev/mpp_service", O_RDWR | O_CLOEXEC);
	if (fd < 0) { perror("open /dev/mpp_service"); return 2; }

	unsigned int support = 0;
	struct mpp_request q = {
		.cmd = MPP_CMD_QUERY_HW_SUPPORT,
		.size = sizeof(support),
		.data = &support,
	};
	if (ioctl(fd, MPP_IOC_CFG_V1, &q) != 0) {
		fprintf(stderr, "QUERY_HW_SUPPORT failed (errno=%d) - cannot pick a client\n",
			errno);
		close(fd);
		return 2;
	}
	printf("hw_support bitmap = %#x\n", support);

	unsigned int client_type = 0;
	int found = 0;
	for (unsigned int i = 0; i < 30; i++)
		if (support & (1u << i)) { client_type = i; found = 1; break; }
	/*
	 * The return value of QUERY_HW_SUPPORT was unchecked and client_type simply
	 * stayed 0 on failure. MPP_DEVICE_VDPU1 == 0 does not exist on RK3588, so
	 * srv->sub_devices[0] is NULL and BOTH inits get -EINVAL: no double-add, no
	 * WARN, nothing exercised -- and the program exited 0 either way.
	 */
	if (!found) {
		fprintf(stderr, "no supported client in bitmap %#x - nothing to exercise\n",
			support);
		close(fd);
		return 2;
	}
	printf("using client_type = %u\n", client_type);

	struct mpp_request init = {
		.cmd = MPP_CMD_INIT_CLIENT_TYPE,
		.size = sizeof(client_type),
		.data = &client_type,
	};

	int r1 = ioctl(fd, MPP_IOC_CFG_V1, &init);
	printf("INIT_CLIENT_TYPE #1 -> %d (errno=%d)\n", r1, r1 ? errno : 0);

	/* second INIT on the same session: double-add of session->session_link */
	int r2 = ioctl(fd, MPP_IOC_CFG_V1, &init);
	int e2 = r2 ? errno : 0;
	printf("INIT_CLIENT_TYPE #2 -> %d (errno=%d)\n", r2, e2);

	close(fd);

	/*
	 * Neither result used to be tested. Assert both halves so this distinguishes
	 * "the fix holds" from "I never reached the vulnerable path":
	 *   - INIT #1 must succeed, or there is no bound session to re-init.
	 *   - INIT #2 must return -EBUSY on a kernel carrying the 0069 re-init guard.
	 * README.md and findings/2026-07-22-mpp-process-request-list-add-double-add-warn.md
	 * both name -EBUSY as the gate. That matters most on a production build, where
	 * the double-add is silent (no CONFIG_DEBUG_LIST WARN to scan for), so the
	 * exit code is the only available signal.
	 */
	if (r1 != 0) {
		fprintf(stderr, "FAIL: INIT_CLIENT_TYPE #1 failed (errno=%d); the double-init "
			"path was never reached\n", r1 ? errno : 0);
		return 2;
	}
	if (r2 == 0) {
		fprintf(stderr, "FAIL: second INIT_CLIENT_TYPE succeeded - the re-init guard "
			"is absent, session_attach is now corrupted for the rest of this boot, "
			"and a later INIT can read a freed mpp_session. REBOOT before further "
			"MPP testing.\n");
		return 1;
	}
	if (e2 != EBUSY) {
		fprintf(stderr, "FAIL: second INIT_CLIENT_TYPE rejected with errno=%d, expected "
			"EBUSY (%d) from the 0069 guard\n", e2, EBUSY);
		return 1;
	}
	printf("PASS: re-init rejected with -EBUSY; the 0069 guard holds\n");
	return 0;
}
