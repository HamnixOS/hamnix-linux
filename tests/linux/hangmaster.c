/* hangmaster.c — A PROCESS THAT TAKES DRM MASTER AND THEN HANGS ON PURPOSE.
 *
 * This is the watchdog's test subject. A watchdog that has never fired is not
 * a watchdog, and a watchdog tested only against a process that exits on its
 * own has not been tested at all. This one takes master, announces it, and
 * then blocks forever in pause(2) with SIGTERM ignored -- so only SIGKILL, the
 * thing the watchdog actually sends, can end it.
 *
 * It does NO modeset. Holding master is not a modeset: the console keeps its
 * picture. So this is safe to run even though its whole purpose is to be
 * killed.
 */
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define DRM_IOCTL_SET_MASTER  0x641e
#define DRM_IOCTL_DROP_MASTER 0x641f

int main(void)
{
    int fd = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
    if (fd < 0) { printf("hangmaster: open card0: %s\n", strerror(errno)); return 1; }
    if (ioctl(fd, DRM_IOCTL_SET_MASTER, 0) < 0) {
        printf("hangmaster: SET_MASTER: %s\n", strerror(errno));
        return 1;
    }
    printf("hangmaster: HOLDING DRM MASTER, pid %d -- now hanging forever\n", (int)getpid());
    fflush(stdout);
    signal(SIGTERM, SIG_IGN);
    signal(SIGINT,  SIG_IGN);
    for (;;) pause();
    return 0;
}
