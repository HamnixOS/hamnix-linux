/* atomiccap.c — is atomic modesetting available on this driver?
 *
 * Capability probe only. Sets DRM client caps and reports what the driver
 * accepts. Takes NO master and performs NO commit, so it cannot disturb the
 * console. It answers "is atomic on the table", NOT "does atomic avoid the
 * DROP_MASTER hang" -- that needs a real atomic modeset to determine.
 */
#include <stdint.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include <drm/drm.h>

#define CAP_STEREO_3D        1
#define CAP_UNIVERSAL_PLANES 2
#define CAP_ATOMIC           3
#define CAP_ASPECT_RATIO     4
#define CAP_WRITEBACK_CONN   5

static void try_cap(int fd, const char* name, uint64_t cap, uint64_t val)
{
    struct drm_set_client_cap c = { cap, val };
    int rc = ioctl(fd, DRM_IOCTL_SET_CLIENT_CAP, &c);
    printf("  %-22s -> %s\n", name, rc == 0 ? "ACCEPTED" : strerror(errno));
}

int main(void)
{
    int fd = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
    if (fd < 0) { printf("open card0: %s\n", strerror(errno)); return 1; }
    printf("client caps on /dev/dri/card0 (no master taken, no commit):\n");
    try_cap(fd, "UNIVERSAL_PLANES", CAP_UNIVERSAL_PLANES, 1);
    try_cap(fd, "ATOMIC",           CAP_ATOMIC,           1);
    try_cap(fd, "ASPECT_RATIO",     CAP_ASPECT_RATIO,     1);
    try_cap(fd, "WRITEBACK_CONN",   CAP_WRITEBACK_CONN,   1);

    /* DRM_CAP_PRIME tells us import/export support independently. */
    struct drm_get_cap g;
    memset(&g, 0, sizeof g);
    g.capability = 0x4; /* DRM_CAP_PRIME */
    if (ioctl(fd, DRM_IOCTL_GET_CAP, &g) == 0)
        printf("  %-22s -> 0x%llx (1=import 2=export)\n", "DRM_CAP_PRIME",
               (unsigned long long)g.value);
    memset(&g, 0, sizeof g);
    g.capability = 0x8; /* DRM_CAP_ASYNC_PAGE_FLIP */
    if (ioctl(fd, DRM_IOCTL_GET_CAP, &g) == 0)
        printf("  %-22s -> %llu\n", "ASYNC_PAGE_FLIP",
               (unsigned long long)g.value);
    close(fd);
    return 0;
}
