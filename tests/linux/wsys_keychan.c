/* tests/linux/wsys_keychan.c — the four kernel facts THE KEYSTROKE CHANNEL
 * rests on, measured rather than believed.
 *
 * THE SPLIT's recorded tier 2 said the fix for the keylogger was a per-window
 * memfd handed to the owner over SCM_RIGHTS, because "a memfd has no name in
 * the filesystem, so there is no path for a bypasser to open".  That sentence
 * is the whole design, and it is FALSE -- which is what this program was
 * written to find out before anything was built on it.  /proc/<pid>/fd/<n> is a
 * path, and the entire premise of the attack is that the attacker and the
 * victim share uid 1001.
 *
 * Four measurements, each printed as a fact with the kernel's own return value:
 *
 *   memfd_samuid   a same-uid process opens another's memfd through /proc and
 *                  reads the plaintext out of it.  THE RECORDED DESIGN'S HOLE.
 *   memfd_nodump   the same thing against a process that has called
 *                  prctl(PR_SET_DUMPABLE, 0): refused.  This is what tier 2's
 *                  REMAINING half -- the scene and the backbuffer, which cannot
 *                  be datagrams -- will have to do, so it is measured now.
 *   sock_noproc    a socket cannot be opened through /proc/<pid>/fd at all.
 *                  This is the property the memfd was believed to have and is
 *                  why the keys ring is a socket.
 *   sock_bind      first-binder-wins in the abstract namespace (EADDRINUSE),
 *                  and SCM_CREDENTIALS carries the kernel's own answer for the
 *                  sender's uid and pid.  Those two together are the whole
 *                  access control on the channel.
 *
 * It links nothing from this tree deliberately: these are facts about Linux,
 * not about hamnix, and a gate that measured them through our own library would
 * be measuring the library.
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/ptrace.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <signal.h>
#include <unistd.h>

#define SECRET "1 PASSWORD31337"

/* A child that holds a memfd containing SECRET and tells us its pid and fd. */
static pid_t memfd_victim(int dumpable, int *out_fd)
{
    int pfd[2];
    if (pipe(pfd) != 0) return -1;
    pid_t k = fork();
    if (k == 0) {
        close(pfd[0]);
        if (!dumpable) prctl(PR_SET_DUMPABLE, 0, 0, 0, 0);
        int fd = syscall(SYS_memfd_create, "wsys.keys", 0);
        if (fd < 0 || ftruncate(fd, 4096) != 0) _exit(2);
        char *p = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        if (p == MAP_FAILED) _exit(2);
        strcpy(p, SECRET);
        char m[32];
        int n = snprintf(m, sizeof m, "%d\n", fd);
        if (write(pfd[1], m, (size_t)n) < 0) _exit(2);
        for (;;) pause();
    }
    close(pfd[1]);
    char b[32] = { 0 };
    if (read(pfd[0], b, sizeof b - 1) <= 0) { close(pfd[0]); return -1; }
    close(pfd[0]);
    *out_fd = atoi(b);
    return k;
}

static void measure_memfd(const char *tag, int dumpable)
{
    int vfd = -1;
    pid_t v = memfd_victim(dumpable, &vfd);
    printf("== %s uid=%d victim=%d fd=%d", tag, (int)getuid(), (int)v, vfd);
    if (v < 0) { printf(" setup=FAIL\n"); return; }

    char path[64];
    snprintf(path, sizeof path, "/proc/%d/fd/%d", (int)v, vfd);
    int a = open(path, O_RDONLY);
    printf(" open=%d", a >= 0 ? a : -errno);
    int leaked = 0;
    if (a >= 0) {
        char *q = mmap(NULL, 4096, PROT_READ, MAP_SHARED, a, 0);
        if (q != MAP_FAILED && memcmp(q, SECRET, strlen(SECRET)) == 0) leaked = 1;
        printf(" mmap=%s", q == MAP_FAILED ? "FAIL" : "0");
        close(a);
    }
    snprintf(path, sizeof path, "/proc/%d/fd", (int)v);
    DIR *d = opendir(path);
    printf(" enumerable=%d", d ? 1 : 0);
    if (d) closedir(d);
    long r = ptrace(PTRACE_ATTACH, v, 0, 0);
    printf(" ptrace=%ld", r == 0 ? 0L : (long)-errno);
    if (r == 0) { waitpid(v, NULL, 0); ptrace(PTRACE_DETACH, v, 0, 0); }
    printf(" secret=%d\n", leaked);

    kill(v, SIGKILL);
    waitpid(v, NULL, 0);
}

static socklen_t abs_addr(struct sockaddr_un *a, const char *name)
{
    memset(a, 0, sizeof *a);
    a->sun_family = AF_UNIX;
    a->sun_path[0] = '\0';
    size_t n = strlen(name);
    memcpy(a->sun_path + 1, name, n);
    return (socklen_t)(offsetof(struct sockaddr_un, sun_path) + 1 + n);
}

static void measure_socket(void)
{
    char name[96];
    snprintf(name, sizeof name, "hamnix-wsys/keychan-probe/%d/keys", (int)getpid());
    struct sockaddr_un a;
    socklen_t alen = abs_addr(&a, name);

    int s = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    int on = 1;
    int pc = setsockopt(s, SOL_SOCKET, SO_PASSCRED, &on, sizeof on);
    int b1 = bind(s, (struct sockaddr *)&a, alen);

    int s2 = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    errno = 0;
    int b2 = bind(s2, (struct sockaddr *)&a, alen);
    int b2err = b2 < 0 ? errno : 0;
    close(s2);

    /* A socket held by THIS process, reached the way a memfd was reachable. */
    char path[64];
    snprintf(path, sizeof path, "/proc/%d/fd/%d", (int)getpid(), s);
    errno = 0;
    int o = open(path, O_RDONLY);
    int oerr = o < 0 ? errno : 0;
    if (o >= 0) close(o);

    printf("== sock_noproc passcred=%d bind1=%d bind2=%d bind2_eaddrinuse=%d"
           " procopen=%d procopen_enxio=%d\n",
           pc, b1, b2, b2err == EADDRINUSE, o >= 0 ? o : -oerr,
           oerr == ENXIO);

    /* And the credentials, from a child so the pid differs. */
    pid_t k = fork();
    if (k == 0) {
        int t = socket(AF_UNIX, SOCK_DGRAM, 0);
        sendto(t, SECRET "\n", strlen(SECRET) + 1, 0, (struct sockaddr *)&a, alen);
        _exit(0);
    }
    waitpid(k, NULL, 0);

    char buf[128];
    char cbuf[CMSG_SPACE(sizeof(struct ucred))];
    struct iovec io = { buf, sizeof buf - 1 };
    struct msghdr m;
    memset(&m, 0, sizeof m);
    m.msg_iov = &io;
    m.msg_iovlen = 1;
    m.msg_control = cbuf;
    m.msg_controllen = sizeof cbuf;
    ssize_t n = recvmsg(s, &m, MSG_DONTWAIT);
    int cred = 0, cpid = -1, cuid = -1;
    for (struct cmsghdr *c = CMSG_FIRSTHDR(&m); c; c = CMSG_NXTHDR(&m, c))
        if (c->cmsg_level == SOL_SOCKET && c->cmsg_type == SCM_CREDENTIALS) {
            struct ucred u;
            memcpy(&u, CMSG_DATA(c), sizeof u);
            cred = 1; cpid = u.pid; cuid = u.uid;
        }
    printf("== sock_cred recv=%zd cred=%d sender_pid=%d sender_uid=%d"
           " sender_is_child=%d my_uid=%d\n",
           n, cred, cpid, cuid, cpid == (int)k, (int)getuid());
    close(s);
}

int main(void)
{
    measure_memfd("memfd_samuid", 1);
    measure_memfd("memfd_nodump", 0);
    measure_socket();
    return 0;
}
