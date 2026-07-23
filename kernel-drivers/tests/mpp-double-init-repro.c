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
	if (ioctl(fd, MPP_IOC_CFG_V1, &q) == 0)
		printf("hw_support bitmap = %#x\n", support);

	unsigned int client_type = 0;           /* first set bit */
	for (unsigned int i = 0; i < 30; i++)
		if (support & (1u << i)) { client_type = i; break; }
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
	printf("INIT_CLIENT_TYPE #2 -> %d (errno=%d)  <-- expected to trip the WARN\n",
	       r2, r2 ? errno : 0);

	close(fd);
	return 0;
}
