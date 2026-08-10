/*
 * user/linux-syscalls.c — the hosted (glibc) half of the Linux link runtime.
 *
 * user/linux-runtime.S is freestanding: raw `syscall`, no libc, no errno. That
 * is the right shape for the entry points that ARE a single Linux syscall, and
 * it stays the definition site for all of those. This file is its counterpart
 * for the entry points that are not:
 *
 *   - the 23 symbols userland declares that the .S never defined at all
 *     (HANDOFF.md §4.1c) — these were hard link errors, not stubs;
 *   - the subset of the 18 fail-closed stubs (§4.1b) that DO have a real
 *     POSIX answer — wait4, tcsetpgrp, kill, setuid, pipe, poll;
 *   - sys_errstr, which needs errno to say anything useful.
 *
 * It is compiled only into the hosted lane (scripts/hamlinux_build.sh, which
 * assembles the .S with -DADDER_HOSTED so the overlapping definitions there are
 * guarded out). The freestanding lane is unchanged and still fail-closed.
 *
 * Why C rather than more assembly: this lane links glibc — confirmed, see the
 * note in HANDOFF.md §7.4 — so errno, strerror_r, getaddrinfo and the pthread
 * primitives are simply available. Several of these entry points are a few
 * lines of C and a page of hand-rolled assembly.
 *
 * CONVENTION. Adder's `extern def` declarations are the ABI contract; each
 * function below repeats its Adder signature in a comment. Return values follow
 * the Hamnix convention of a negative int on failure, NOT errno-in-a-global —
 * callers test `< 0` and then call sys_errstr for the reason.
 */

#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <netdb.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

/* ------------------------------------------------------------------ *
 * Return convention
 *
 * The freestanding wrappers in linux-runtime.S issue a raw `syscall` and hand
 * back whatever the kernel put in %rax — which on failure is -errno, not -1.
 * Measured, not assumed: sys_open("/no/such") returns -2 and
 * sys_open("/etc/shadow") returns -13. Adder callers only ever test `< 0`, but
 * something in 180k lines may well decode the value, so these hosted
 * definitions reproduce it EXACTLY: on failure return -errno, and additionally
 * set errno so sys_errstr can name the reason.
 * ------------------------------------------------------------------ */

/* Map a glibc -1/errno result onto the raw-syscall -errno convention. */
static inline int64_t rc64(int64_t r)
{
    return r < 0 ? -(int64_t)errno : r;
}
static inline int32_t rc32(int r)
{
    return r < 0 ? -(int32_t)errno : (int32_t)r;
}

/* ------------------------------------------------------------------ *
 * Error reporting
 * ------------------------------------------------------------------ */

/* extern def sys_errstr(buf: Ptr[uint8], nbuf: uint64) -> int32
 *
 * Plan 9's errstr: the reason for the most recent failure, as text. The
 * freestanding runtime has no errno and always reported the empty string,
 * which is why a failed open in the hosted lane printed "cannot open X: "
 * with nothing after the colon. Back it with strerror_r.
 *
 * Returns the number of bytes written, excluding the NUL. */
int32_t sys_errstr(uint8_t *buf, uint64_t nbuf)
{
    if (!buf || nbuf == 0)
        return 0;
    /* GNU strerror_r may return a pointer to a static string rather than
     * filling the buffer; honour whichever it did. */
    char tmp[256];
    const char *msg = strerror_r(errno, tmp, sizeof tmp);
    size_t n = strlen(msg);
    if (n > nbuf - 1)
        n = nbuf - 1;
    memcpy(buf, msg, n);
    buf[n] = '\0';
    return (int32_t)n;
}

/* ------------------------------------------------------------------ *
 * The POSIX file / fd surface
 *
 * These were already "genuinely implemented" per HANDOFF.md §4.1a and in the
 * freestanding lane they are. They are redefined here for the two reasons
 * given at the top of linux-runtime.S's guarded region: errno, and directories.
 *
 * DIRECTORIES. lib/p9.ad's p9_listdir (user-visible as `ls`, and as the
 * directory walk under hamfmcore) opens a path and read(2)s it, expecting the
 * "NAME\n"-packed stream that Hamnix's DEV_DIR_FILE backing emits. Linux
 * read(2) on a directory fd returns EISDIR, so `ls` builds, links, runs, and
 * prints "listdir failed". Rather than change 180k lines of userland that
 * assume the Plan 9 shape, sys_open notices a directory and sys_read
 * synthesises the same stream from readdir(3). This is the single change that
 * moves the directory-reading half of Tier 1 from "links" to "works".
 * ------------------------------------------------------------------ */

/* Directory fds opened through sys_open, and the rendered "NAME\n" stream we
 * hand back a piece at a time. The table is small and linear because a process
 * in this userland has a handful of directory fds open at once, not hundreds.
 *
 * NOT thread-safe. Nothing in the hosted lane is threaded today — sys_rfork is
 * fork(2), and sys_rfork_thread is still fail-closed — so this is adequate and
 * has to be revisited with HANDOFF §7.5. */
#define DIRTAB_MAX 32
struct dirstream {
    int    used;    /* 0 when the slot is free. NOT keyed on fd == -1: the
                     * table lives in BSS and starts zeroed, so an fd field of
                     * 0 would make every free slot look like it owned fd 0. */
    int    fd;
    char  *text;    /* the whole "NAME\n" listing, malloc'd */
    size_t len;
    size_t off;     /* bytes already handed to sys_read */
};
static struct dirstream dirtab[DIRTAB_MAX];

static struct dirstream *dirtab_find(int fd)
{
    if (fd < 0)
        return NULL;
    for (int i = 0; i < DIRTAB_MAX; i++)
        if (dirtab[i].used && dirtab[i].fd == fd)
            return &dirtab[i];
    return NULL;
}

static struct dirstream *dirtab_alloc(void)
{
    for (int i = 0; i < DIRTAB_MAX; i++)
        if (!dirtab[i].used)
            return &dirtab[i];
    return NULL;
}

static void dirtab_release(struct dirstream *d)
{
    free(d->text);
    d->text = NULL;
    d->len = d->off = 0;
    d->fd = -1;
    d->used = 0;
}

/* Render every entry of an already-open directory fd as "NAME\n", in readdir
 * order.
 *
 * "." and ".." are OMITTED. Plan 9 directory reads do not carry them, and this
 * tree depends on that: user/du.ad, user/find.ad, user/cp.ad and the other
 * p9_listdir recursors walk subdirectories with no self/parent guard anywhere,
 * so a stream containing "." would recurse until the stack or the path buffer
 * gives out. Dotfiles proper are kept — user/ls.ad does no filtering of its own
 * and is documented as dumping the stream verbatim.
 *
 * Takes ownership of `fd` on success via fdopendir; the caller must not close
 * it directly. Returns 0, or -1 with errno set. */
static int dirtab_fill(int fd)
{
    struct dirstream *slot = dirtab_alloc();
    if (!slot) {
        errno = EMFILE;
        return -1;
    }

    /* fdopendir takes the fd over, and closedir would close it — but the
     * caller still owns the fd number and will close it via sys_close. Use a
     * dup so the two lifetimes stay independent. */
    int dfd = dup(fd);
    if (dfd < 0)
        return -1;
    DIR *dp = fdopendir(dfd);
    if (!dp) {
        int e = errno;
        close(dfd);
        errno = e;
        return -1;
    }

    size_t cap = 4096, len = 0;
    char *buf = malloc(cap);
    if (!buf) {
        closedir(dp);
        errno = ENOMEM;
        return -1;
    }

    struct dirent *de;
    errno = 0;
    while ((de = readdir(dp)) != NULL) {
        if (de->d_name[0] == '.' &&
            (de->d_name[1] == '\0' ||
             (de->d_name[1] == '.' && de->d_name[2] == '\0')))
            continue;                       /* see the note above */
        size_t n = strlen(de->d_name);
        if (len + n + 1 > cap) {
            size_t ncap = cap * 2;
            while (len + n + 1 > ncap)
                ncap *= 2;
            char *nb = realloc(buf, ncap);
            if (!nb) {
                free(buf);
                closedir(dp);
                errno = ENOMEM;
                return -1;
            }
            buf = nb;
            cap = ncap;
        }
        memcpy(buf + len, de->d_name, n);
        len += n;
        buf[len++] = '\n';
    }
    int read_err = errno;
    closedir(dp);
    if (read_err != 0) {
        free(buf);
        errno = read_err;
        return -1;
    }

    slot->used = 1;
    slot->fd = fd;
    slot->text = buf;
    slot->len = len;
    slot->off = 0;
    return 0;
}

/* If `fd` names a directory, register its rendered listing. A failure to
 * render is reported to the caller; a plain file is left alone. */
static int adopt_if_directory(int fd)
{
    struct stat st;
    if (fstat(fd, &st) < 0)
        return -1;
    if (!S_ISDIR(st.st_mode))
        return 0;
    return dirtab_fill(fd);
}

/* extern def sys_open(path: Ptr[char]) -> int32
 * ONE argument, opened for reading — see the long note at the .S definition. */
int32_t sys_open(const char *path)
{
    int fd = open(path, O_RDONLY);
    if (fd < 0)
        return rc32(fd);
    if (adopt_if_directory(fd) < 0) {
        int e = errno;
        close(fd);
        errno = e;
        return -(int32_t)e;
    }
    return (int32_t)fd;
}

/* extern def sys_open3(path, flags, mode) -> int32 — raw open(2). Not declared
 * by any userland module today, but host-side harnesses use it. */
int32_t sys_open3(const char *path, int32_t flags, uint32_t mode)
{
    return rc32(open(path, (int)flags, (mode_t)mode));
}

/* extern def sys_open_write(path: Ptr[char]) -> int32
 * Open-or-create for writing, truncating an existing file. */
int32_t sys_open_write(const char *path)
{
    return rc32(open(path, O_WRONLY | O_CREAT | O_TRUNC, 0666));
}

/* extern def sys_read(fd: int32, buf: Ptr[uint8], count: uint64) -> int64
 * On a directory fd, serve the synthesised "NAME\n" stream. */
int64_t sys_read(int32_t fd, uint8_t *buf, uint64_t count)
{
    struct dirstream *d = dirtab_find((int)fd);
    if (d) {
        size_t avail = d->len - d->off;
        if (avail == 0)
            return 0;                       /* EOF, as read(2) would report */
        size_t n = count < avail ? (size_t)count : avail;
        memcpy(buf, d->text + d->off, n);
        d->off += n;
        return (int64_t)n;
    }
    return rc64(read((int)fd, buf, (size_t)count));
}

/* extern def sys_write(fd: int32, buf: Ptr[uint8], count: uint64) -> int64 */
int64_t sys_write(int32_t fd, const uint8_t *buf, uint64_t count)
{
    return rc64(write((int)fd, buf, (size_t)count));
}

/* extern def sys_close(fd: int32) -> int32 */
int32_t sys_close(int32_t fd)
{
    struct dirstream *d = dirtab_find((int)fd);
    if (d)
        dirtab_release(d);
    return rc32(close((int)fd));
}

/* extern def sys_lseek(fd: int32, off: int64, whence: int32) -> int64
 * Seeking a directory fd rewinds our rendered stream, which is what a
 * caller that seeks to 0 to re-read a listing means. */
int64_t sys_lseek(int32_t fd, int64_t off, int32_t whence)
{
    struct dirstream *d = dirtab_find((int)fd);
    if (d) {
        int64_t base = (whence == SEEK_CUR) ? (int64_t)d->off
                     : (whence == SEEK_END) ? (int64_t)d->len
                                            : 0;
        int64_t want = base + off;
        if (want < 0 || (uint64_t)want > d->len) {
            errno = EINVAL;
            return -EINVAL;
        }
        d->off = (size_t)want;
        return want;
    }
    return rc64(lseek((int)fd, (off_t)off, (int)whence));
}

/* extern def sys_mkdir(path: Ptr[char], mode: uint32) -> int32 */
int32_t sys_mkdir(const char *path, uint32_t mode)
{
    return rc32(mkdir(path, (mode_t)mode));
}

/* extern def sys_unlink(path: Ptr[char]) -> int32
 * Removes a file OR an empty directory: the Hamnix call covers both, and
 * `rm -r` in this tree relies on it. */
int32_t sys_unlink(const char *path)
{
    if (unlink(path) == 0)
        return 0;
    if (errno == EISDIR || errno == EPERM)
        return rc32(rmdir(path));
    return -(int32_t)errno;
}

/* extern def sys_dup(fd: int32) -> int32 */
int32_t sys_dup(int32_t fd) { return rc32(dup((int)fd)); }

/* extern def sys_dup2(old: int32, new_: int32) -> int32 */
int32_t sys_dup2(int32_t oldfd, int32_t newfd)
{
    return rc32(dup2((int)oldfd, (int)newfd));
}

/* extern def sys_getcwd(buf: Ptr[uint8], count: uint64) -> int64
 * Returns the LENGTH including the NUL, matching the raw getcwd(2) syscall
 * (not the glibc wrapper, which returns the pointer). */
int64_t sys_getcwd(uint8_t *buf, uint64_t count)
{
    if (getcwd((char *)buf, (size_t)count) == NULL)
        return -(int64_t)errno;
    return (int64_t)strlen((char *)buf) + 1;
}

/* extern def sys_chdir(path: Ptr[char]) -> int32 */
int32_t sys_chdir(const char *path) { return rc32(chdir(path)); }

/* ------------------------------------------------------------------ *
 * Process identity and creation  (§4.1c — were link errors)
 * ------------------------------------------------------------------ */

/* extern def sys_getpid() -> int32 */
int32_t sys_getpid(void) { return (int32_t)getpid(); }

/* extern def sys_getgid() -> uint32 */
uint32_t sys_getgid(void) { return (uint32_t)getgid(); }

/* extern def sys_execve(path: Ptr[char], argv: Ptr[uint64]) -> int32
 *
 * Two args, not three: the Hamnix form inherits the environment rather than
 * taking an envp. sys_execve_env (in the .S) is the three-arg form. On success
 * this does not return. */
int32_t sys_execve(const char *path, char *const argv[])
{
    execv(path, argv);
    return -1;
}

/* extern def sys_pipe(fds: Ptr[int32]) -> int32
 *
 * fds[0] = read end, fds[1] = write end, as pipe(2). O_CLOEXEC is NOT set:
 * hamsh's pipeline wiring depends on the ends surviving into the child. */
int32_t sys_pipe(int32_t *fds)
{
    int p[2];
    if (pipe(p) < 0)
        return -1;
    fds[0] = p[0];
    fds[1] = p[1];
    return 0;
}

/* extern def sys_socketpair(domain: int32, type: int32, protocol: int32,
 *                           sv: Ptr[int32]) -> int32 */
int32_t sys_socketpair(int32_t domain, int32_t type, int32_t protocol,
                       int32_t *sv)
{
    int s[2];
    if (socketpair(domain, type, protocol, s) < 0)
        return -1;
    sv[0] = s[0];
    sv[1] = s[1];
    return 0;
}

/* extern def sys_rfork(flags: int32) -> int32
 *
 * HANDOFF.md §4.1a lists this as genuinely implemented. It was not — it is a
 * `return -1` in linux-runtime.S, which matters because HANDOFF §8 step 2
 * ("add sys_waitpid and sys_tcsetpgrp, get hamsh running") cannot work while
 * the call that CREATES the child fails. Reaping is useless without spawning.
 *
 * Plan 9 rfork takes a flag word choosing which parts of the parent to share
 * (RFPROC, RFFDG, RFNAMEG, RFMEM...). Whether those semantics survive the move
 * to clone(2) is HANDOFF §7.5 and is genuinely open. What is NOT open is the
 * common case: every spawn site in this userland wants a plain child process
 * with copied fds, which is exactly fork(2). Implement that, and refuse the
 * flag combinations that would mean something else rather than silently
 * pretending. Returns 0 in the child and the pid in the parent, as fork does.
 *
 * RFMEM (share the address space) is the one flag fork cannot express; it
 * belongs with sys_rfork_thread, which stays fail-closed. */
#define RFPROC  0x0001   /* create a process */
#define RFMEM   0x0002   /* share the address space */
int32_t sys_rfork(int32_t flags)
{
    if (flags & RFMEM) {
        errno = ENOSYS;     /* that is sys_rfork_thread's job — HANDOFF §7.5 */
        return -ENOSYS;
    }
    if (flags != 0 && !(flags & RFPROC)) {
        /* A namespace-only rfork (RFNAMEG without RFPROC) asks for a private
         * namespace in THIS process — unshare(CLONE_NEWNS) territory, and part
         * of the §4.2 work that is deliberately out of scope. */
        errno = ENOSYS;
        return -ENOSYS;
    }
    return rc32(fork());
}

/* extern def sys_execve_env(path: Ptr[char], argv: Ptr[uint64],
 *                           envp: Ptr[uint64]) -> int32
 * Also listed as implemented by HANDOFF §4.1a, also a `return -1`. */
int32_t sys_execve_env(const char *path, char *const argv[],
                       char *const envp[])
{
    execve(path, argv, envp);
    return -(int32_t)errno;
}

/* extern def sys_resolve(hostname: Ptr[uint8], hlen: uint64) -> int64
 *
 * Forward DNS, returning a packed big-endian IPv4 as an integer — the same
 * contract scripts/net9_host_shim.c implements over getaddrinfo (HANDOFF
 * §3.4). HANDOFF §4.1a lists it as implemented in this runtime; it is a
 * `return -1` there. The shim's precedent is the right one, so do the same.
 *
 * `hostname` is length-counted, not NUL-terminated, so copy it out first.
 * Resolving is not socket I/O: this does not prejudge HANDOFF §7.1. */
int64_t sys_resolve(const uint8_t *hostname, uint64_t hlen)
{
    char host[256];
    if (hlen == 0 || hlen >= sizeof host) {
        errno = EINVAL;
        return -1;
    }
    memcpy(host, hostname, (size_t)hlen);
    host[hlen] = '\0';

    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_INET;              /* the contract is IPv4-only */
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host, NULL, &hints, &res) != 0 || !res)
        return -1;

    uint32_t ip = ntohl(((struct sockaddr_in *)res->ai_addr)->sin_addr.s_addr);
    freeaddrinfo(res);
    return (int64_t)ip;
}

/* ------------------------------------------------------------------ *
 * Remaining Plan 9 chan/stat primitives
 *
 * These were also in HANDOFF §4.1a's "implemented" list and are also stubs.
 * Unlike rfork/execve_env/resolve they have no one-line POSIX answer: they
 * describe Hamnix's own Dir wire format and fd-slot model (lib/p9.ad documents
 * the record layout). They stay fail-closed, now with a stated reason.
 * ------------------------------------------------------------------ */

/* extern def sys_stat_p9(path: Ptr[char], buf: Ptr[uint8],
 *                        nbuf: uint64) -> int64
 *
 * Stat one path as a 9P2000 stat wire record. Returns the bytes written, or
 * -1. This is the ONLY reliable file-vs-directory test in the tree, and a
 * surprising amount of Tier 1 rests on it: lib/p9.ad's p9_is_dir is built on
 * it, and user/find.ad's header explains why (bug #146) a p9_listdir success
 * cannot be used instead — reading a regular file also succeeds, so the walker
 * would descend into a file and enumerate garbage.
 *
 * LAYOUT. Careful: this is the FULL 9P2000 stat record, NOT the compact Dir
 * record that lib/p9.ad's own header documents and p9_dir_decode_at parses.
 * lib/p9.ad:1095 flags the difference explicitly, and the two disagree about
 * where qid.type lives. The consumers pin the offsets: p9_is_dir reads
 * qid.type at byte 8, user/find.ad:236 reads length as a u64 LE at byte 33.
 *
 *   off  size  field
 *     0    2   size      record length NOT counting these two bytes
 *     2    2   type      (server type; 0 here)
 *     4    4   dev       (server subdevice; 0 here)
 *     8    1   qid.type  QTDIR 0x80 for a directory
 *     9    4   qid.version
 *    13    8   qid.path  unique per file — st_ino
 *    21    4   mode      Plan 9 perm bits, DMDIR 0x80000000 for a directory
 *    25    4   atime     u32 seconds
 *    29    4   mtime     u32 seconds
 *    33    8   length    u64 file size
 *    41    2+n name      u16 length prefix, no NUL
 *   ...    2+n uid
 *   ...    2+n gid
 *   ...    2+n muid
 */
#define P9_QTDIR  0x80u
#define P9_DMDIR  0x80000000u
#define P9_STAT_FIXED 41

static void p9_put16(uint8_t *p, uint16_t v)
{ p[0] = (uint8_t)(v & 0xFF); p[1] = (uint8_t)(v >> 8); }
static void p9_put32(uint8_t *p, uint32_t v)
{ for (int i = 0; i < 4; i++) p[i] = (uint8_t)(v >> (8 * i)); }
static void p9_put64(uint8_t *p, uint64_t v)
{ for (int i = 0; i < 8; i++) p[i] = (uint8_t)(v >> (8 * i)); }

/* Append a u16-length-prefixed string, or return 0 if it will not fit. */
static size_t p9_put_str(uint8_t *buf, size_t off, size_t cap, const char *s)
{
    size_t n = strlen(s);
    if (n > 0xFFFF || off + 2 + n > cap)
        return 0;
    p9_put16(buf + off, (uint16_t)n);
    memcpy(buf + off + 2, s, n);
    return off + 2 + n;
}

int64_t sys_stat_p9(const char *path, uint8_t *buf, uint64_t nbuf)
{
    struct stat st;
    if (!path || !buf) {
        errno = EFAULT;
        return -1;
    }
    /* lstat, not stat: `find -type l` and the walkers must see a symlink as
     * itself rather than as whatever it points at — and a symlink loop would
     * otherwise make the recursors hang. */
    if (lstat(path, &st) < 0)
        return -1;
    if (nbuf < P9_STAT_FIXED) {
        errno = ERANGE;
        return -1;
    }

    /* The basename is the record's `name`. 9P records name the leaf, not the
     * path the caller passed. */
    const char *base = strrchr(path, '/');
    base = base ? base + 1 : path;
    if (*base == '\0')                     /* a trailing-slash path, or "/" */
        base = "/";

    int isdir = S_ISDIR(st.st_mode);
    memset(buf, 0, P9_STAT_FIXED);
    /* buf[2..3] type and buf[4..7] dev stay 0: Hamnix's namespace has no
     * per-mount type/dev doublet (see lib/p9.ad's header). */
    buf[8] = isdir ? (uint8_t)P9_QTDIR : 0u;
    p9_put32(buf + 9,  (uint32_t)st.st_mtime);            /* qid.version */
    p9_put64(buf + 13, (uint64_t)st.st_ino);              /* qid.path */
    p9_put32(buf + 21, (uint32_t)(st.st_mode & 0777u)
                       | (isdir ? P9_DMDIR : 0u));
    p9_put32(buf + 25, (uint32_t)st.st_atime);
    p9_put32(buf + 29, (uint32_t)st.st_mtime);
    p9_put64(buf + 33, (uint64_t)st.st_size);

    /* uid/gid/muid are names in 9P, not numbers. Rendering them numerically
     * keeps this free of a passwd lookup on every stat; nothing in Tier 1
     * displays them, and `ls -l` prints the uid field verbatim anyway. */
    char uidbuf[24], gidbuf[24];
    snprintf(uidbuf, sizeof uidbuf, "%u", (unsigned)st.st_uid);
    snprintf(gidbuf, sizeof gidbuf, "%u", (unsigned)st.st_gid);

    size_t off = P9_STAT_FIXED;
    size_t cap = (size_t)nbuf;
    if (!(off = p9_put_str(buf, off, cap, base)))   goto too_small;
    if (!(off = p9_put_str(buf, off, cap, uidbuf))) goto too_small;
    if (!(off = p9_put_str(buf, off, cap, gidbuf))) goto too_small;
    if (!(off = p9_put_str(buf, off, cap, uidbuf))) goto too_small;  /* muid */

    p9_put16(buf, (uint16_t)(off - 2));             /* size[2] excludes itself */
    return (int64_t)off;

too_small:
    errno = ERANGE;
    return -1;
}

/* extern def sys_listdir_records(path, buf, count) -> int64
 *
 * The COMPACT Dir-record stream (the 43-byte-minimum layout lib/p9.ad's header
 * documents) — a different format from sys_stat_p9 above. Left fail-closed:
 * nothing in Tier 1 reaches it, because p9_listdir — the function `ls` and
 * every walker actually call — goes through sys_open/sys_read, which the
 * directory support above serves. It is what `ls -l` needs, via
 * sys_chan_dir_mode, and belongs with that work. */
int64_t sys_listdir_records(const char *path, uint8_t *buf, uint64_t count)
{ (void)path; (void)buf; (void)count; errno = ENOSYS; return -1; }

/* extern def sys_fdbind(pid, fdnum, kind, slot) -> int32
 * extern def sys_chan_dir_mode(fd, mode, path) -> int32
 *
 * The fd-slot model: rewriting a CHILD's fd table from the parent, by name,
 * before the child runs. It is how hamsh wires pipes and redirects
 * (docs/native-api.md), and it has no Linux equivalent — on Linux the child
 * does its own dup2 after fork. Reworking hamsh's spawn path to that shape is
 * real work and is part of HANDOFF §7.5. */
int32_t sys_fdbind(int32_t pid, int32_t fdnum, int32_t kind, int32_t slot)
{ (void)pid; (void)fdnum; (void)kind; (void)slot; errno = ENOSYS; return -1; }
int32_t sys_chan_dir_mode(int32_t fd, int32_t mode, const char *path)
{ (void)fd; (void)mode; (void)path; errno = ENOSYS; return -1; }

/* ------------------------------------------------------------------ *
 * Filesystem  (§4.1c — were link errors)
 * ------------------------------------------------------------------ */

/* extern def sys_link(oldpath: Ptr[char], newpath: Ptr[char]) -> int32 */
int32_t sys_link(const char *oldpath, const char *newpath)
{
    return link(oldpath, newpath) < 0 ? -1 : 0;
}

/* extern def sys_symlink(target: Ptr[char], linkpath: Ptr[char]) -> int32 */
int32_t sys_symlink(const char *target, const char *linkpath)
{
    return symlink(target, linkpath) < 0 ? -1 : 0;
}

/* ------------------------------------------------------------------ *
 * Time  (§4.1c — was a link error)
 * ------------------------------------------------------------------ */

/* extern def sys_clock_gettime(clockid: int32, tp: Ptr[uint64]) -> int64
 *
 * tp is a two-element uint64 array, NOT a struct timespec: Adder has no
 * timespec and every caller in the tree indexes tp[0]=seconds, tp[1]=nanos.
 * On 64-bit Linux struct timespec has exactly that layout, but copy through a
 * real timespec rather than aliasing, so this stays correct if it is ever
 * built for a 32-bit target. */
int64_t sys_clock_gettime(int32_t clockid, uint64_t *tp)
{
    struct timespec ts;
    if (clock_gettime((clockid_t)clockid, &ts) < 0)
        return -1;
    tp[0] = (uint64_t)ts.tv_sec;
    tp[1] = (uint64_t)ts.tv_nsec;
    return 0;
}

/* extern def sys_set_realtime(epoch: uint64) -> int32
 *
 * Set the wall clock from a Unix epoch second count. Requires CAP_SYS_TIME;
 * without it this fails with EPERM, which is the correct outcome rather than
 * something to paper over. */
int32_t sys_set_realtime(uint64_t epoch)
{
    struct timespec ts = { .tv_sec = (time_t)epoch, .tv_nsec = 0 };
    return clock_settime(CLOCK_REALTIME, &ts) < 0 ? -1 : 0;
}

/* ------------------------------------------------------------------ *
 * Wait / job control  (§4.1b — were fail-closed stubs)
 *
 * HANDOFF.md §4.1 singles these out: "hamsh cannot reap a child or run job
 * control on Linux today". These are that gap.
 * ------------------------------------------------------------------ */

/* extern def sys_waitpid(pid: int32) -> int64
 *
 * Blocking reap. Returns the child's EXIT CODE, not a raw wait status —
 * hamsh assigns the result straight to $? (user/hamsh.ad:11343,11226). A
 * child killed by a signal reports 128+signo, the shell convention.
 * EINTR is retried: a SIGCHLD or window-resize must not look like an exit. */
int64_t sys_waitpid(int32_t pid)
{
    int status;
    pid_t r;
    do {
        r = waitpid((pid_t)pid, &status, 0);
    } while (r < 0 && errno == EINTR);
    if (r < 0)
        return -1;
    if (WIFEXITED(status))
        return (int64_t)WEXITSTATUS(status);
    if (WIFSIGNALED(status))
        return (int64_t)(128 + WTERMSIG(status));
    return 0;
}

/* Status-word kinds, mirroring user/hamsh.ad:11477. The word is
 * (data << 8) | kind. */
#define WAITJC_RUNNING   0
#define WAITJC_EXITED    1
#define WAITJC_STOPPED   2
#define WAITJC_CONTINUED 3

/* extern def sys_waitpid_jc(pid: int32, status: Ptr[int64]) -> int64
 *
 * The job-control poll. NON-BLOCKING by contract: hamsh calls it once per
 * prompt for every live job (jobs_reap_and_report) and in a spin loop for the
 * foreground job. Returns > 0 when there is an event to report, 0 when the
 * child is alive with nothing new, -1 on error.
 *
 * WUNTRACED and WCONTINUED are what make Ctrl-Z and `fg` observable; without
 * them a stopped child is indistinguishable from a running one and the shell
 * hangs. */
int64_t sys_waitpid_jc(int32_t pid, int64_t *status)
{
    int st;
    pid_t r;
    do {
        r = waitpid((pid_t)pid, &st, WNOHANG | WUNTRACED | WCONTINUED);
    } while (r < 0 && errno == EINTR);

    if (r < 0)
        return -1;
    if (r == 0) {                       /* alive, nothing new */
        if (status) *status = WAITJC_RUNNING;
        return 0;
    }
    if (WIFEXITED(st)) {
        if (status) *status = ((int64_t)WEXITSTATUS(st) << 8) | WAITJC_EXITED;
        return 1;
    }
    if (WIFSIGNALED(st)) {
        if (status)
            *status = ((int64_t)(128 + WTERMSIG(st)) << 8) | WAITJC_EXITED;
        return 1;
    }
    if (WIFSTOPPED(st)) {
        if (status) *status = ((int64_t)WSTOPSIG(st) << 8) | WAITJC_STOPPED;
        return 1;
    }
    if (WIFCONTINUED(st)) {
        if (status) *status = WAITJC_CONTINUED;
        return 1;
    }
    if (status) *status = WAITJC_RUNNING;
    return 0;
}

/* extern def sys_waitpid_nb_raw(pid: int32, flags: int64) -> int64
 *
 * The raw form: `flags` is the Hamnix flag word whose only defined bit is
 * WNOHANG = 1 (user/hamsh.ad's comment at the decl). Returns the reaped pid,
 * 0 if nothing is ready, -1 on error. Deliberately does NOT decode the status:
 * that is what the _jc form is for. */
int64_t sys_waitpid_nb_raw(int32_t pid, int64_t flags)
{
    int st;
    int wflags = (flags & 1) ? WNOHANG : 0;
    pid_t r;
    do {
        r = waitpid((pid_t)pid, &st, wflags);
    } while (r < 0 && errno == EINTR);
    return r < 0 ? -1 : (int64_t)r;
}

/* extern def sys_tcsetpgrp(pgid: int32) -> int32
 *
 * Hand the controlling terminal to a process group. One arg, not two: the
 * terminal is always the shell's own, so the fd is implicit.
 *
 * The shell is by definition in the background while its child owns the
 * terminal, so this call would raise SIGTTOU and stop the shell itself.
 * Blocking SIGTTOU across the call is the standard idiom and is not optional. */
int32_t sys_tcsetpgrp(int32_t pgid)
{
    sigset_t block, prev;
    sigemptyset(&block);
    sigaddset(&block, SIGTTOU);
    sigprocmask(SIG_BLOCK, &block, &prev);

    int fd = STDIN_FILENO;
    if (!isatty(fd)) {
        fd = STDERR_FILENO;
        if (!isatty(fd)) {
            sigprocmask(SIG_SETMASK, &prev, NULL);
            errno = ENOTTY;
            return -1;
        }
    }
    int rc = tcsetpgrp(fd, (pid_t)pgid);
    sigprocmask(SIG_SETMASK, &prev, NULL);
    return rc < 0 ? -1 : 0;
}

/* extern def sys_pgrp_kill(pgid: uint32, sig: int32) -> int32
 *
 * Signal an entire process group. kill(2) spells that as a negative pid. */
int32_t sys_pgrp_kill(uint32_t pgid, int32_t sig)
{
    return kill(-(pid_t)pgid, sig) < 0 ? -1 : 0;
}

/* extern def sys_setuid(uid: uint32) -> int32 */
int32_t sys_setuid(uint32_t uid)
{
    return setuid((uid_t)uid) < 0 ? -1 : 0;
}

/* extern def sys_waitfds(fds: Ptr[int32], nfds: uint64,
 *                        timeout_ms: int64) -> int64
 *
 * Multi-fd readiness wait — the GUI event loop's idle wait. Returns the
 * number of ready fds, 0 on timeout, -1 on error. poll(2) is the direct
 * equivalent; the caller only ever asks about readability. */
#define WAITFDS_MAX 64
int64_t sys_waitfds(const int32_t *fds, uint64_t nfds, int64_t timeout_ms)
{
    struct pollfd pfd[WAITFDS_MAX];
    if (nfds > WAITFDS_MAX) {
        errno = EINVAL;
        return -1;
    }
    for (uint64_t i = 0; i < nfds; i++) {
        pfd[i].fd = fds[i];
        pfd[i].events = POLLIN;
        pfd[i].revents = 0;
    }
    int r;
    do {
        r = poll(pfd, (nfds_t)nfds, (int)timeout_ms);
    } while (r < 0 && errno == EINTR);
    return r < 0 ? -1 : (int64_t)r;
}

/* extern def sys_pipechan() -> int32
 *
 * Plan 9 pipe-as-a-channel: one fd naming a bidirectional pipe, rather than
 * the two unidirectional ends sys_pipe hands back. A Unix-domain socketpair
 * is the closest Linux object, but a single fd cannot name both ends, so this
 * cannot be expressed without the #d / fd-slot machinery that is still
 * fail-closed. Left unimplemented deliberately — see HANDOFF.md §4.1b. */
int32_t sys_pipechan(void)
{
    errno = ENOSYS;
    return -1;
}

/* ------------------------------------------------------------------ *
 * Namespace  (§4.2)
 * ------------------------------------------------------------------ */

/* extern def sys_bind(new_: Ptr[char], old: Ptr[char], flag: int32) -> int32
 *
 * Argument order is (DST, SRC, flag) — the destination first. See the comment
 * at user/hamsh.ad's decl; it is the reverse of what the name suggests.
 *
 * HANDOFF.md §4.2 measured the call sites: of 52 in the tree, 45 are the
 * identical `sys_bind("/dev", "#c", 0)` console incantation and 3 are
 * `sys_bind("/fd", "#d", ...)`. Both are startup boilerplate asking for
 * something Linux already provides at exactly those paths — /dev is the device
 * tree, and /proc/self/fd is reachable as /dev/fd. So the honest
 * implementation is to accept those two and do nothing.
 *
 * Everything else fails. The remaining 4 genuine call sites (distrofs, nsrun,
 * and the extbind probe) want real per-process namespaces — unshare(2) plus
 * bind mounts — and are out of scope here. Failing loudly is better than
 * silently returning 0 and letting them believe a mount happened. */
int32_t sys_bind(const char *dst, const char *src, int32_t flag)
{
    (void)flag;
    if (!dst || !src) {
        errno = EFAULT;
        return -1;
    }
    if (!strcmp(src, "#c") && !strcmp(dst, "/dev"))
        return 0;
    if (!strcmp(src, "#d") && !strcmp(dst, "/fd"))
        return 0;
    errno = ENOSYS;
    return -1;
}

/* ------------------------------------------------------------------ *
 * Name resolution  (§4.1c — was a link error)
 * ------------------------------------------------------------------ */

/* extern def sys_resolve_ptr(ip: uint64, buf: Ptr[uint8],
 *                            cap: uint64) -> int64
 *
 * Reverse DNS. `ip` is a packed big-endian IPv4 in the low 32 bits, matching
 * what sys_resolve returns. Writes the hostname NUL-terminated and returns its
 * length, or -1 if there is no PTR record.
 *
 * This is the only /net-adjacent entry point here, and it is safe to add
 * because it is a resolver call, not a socket: it does not prejudge HANDOFF
 * §7.1's shim-vs-file-server question. sys_resolve, its forward twin, is
 * already implemented in the .S on the same reasoning. */
int64_t sys_resolve_ptr(uint64_t ip, uint8_t *buf, uint64_t cap)
{
    if (!buf || cap == 0) {
        errno = EINVAL;
        return -1;
    }
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof sa);
    sa.sin_family = AF_INET;
    sa.sin_addr.s_addr = htonl((uint32_t)ip);

    char host[NI_MAXHOST];
    if (getnameinfo((struct sockaddr *)&sa, sizeof sa, host, sizeof host,
                    NULL, 0, NI_NAMEREQD) != 0)
        return -1;

    size_t n = strlen(host);
    if (n > cap - 1)
        n = cap - 1;
    memcpy(buf, host, n);
    buf[n] = '\0';
    return (int64_t)n;
}

/* ------------------------------------------------------------------ *
 * Deliberately not implemented
 *
 * These are declared by userland, so they must RESOLVE or nothing that
 * references them links at all — that is what made them link errors rather
 * than stubs. They resolve here and fail closed, each for a stated reason.
 * ------------------------------------------------------------------ */

/* Userspace-driver MMIO / IRQ / DMA. HANDOFF.md §4.1c is right that these
 * should be deleted on this line — Linux owns the hardware and an Adder
 * process has no business mapping physical addresses. They are kept as
 * failing stubs only so the tree links while the call sites are removed;
 * deleting the call sites is the actual fix.
 *   extern def sys_umdf_mmio_map(phys: uint64, len: uint64) -> int64
 *   extern def sys_umdf_irq_open(vector: uint64) -> int32
 *   extern def sys_umdf_dma_alloc(len: uint64, out_phys: Ptr[uint64]) -> int64 */
int64_t sys_umdf_mmio_map(uint64_t phys, uint64_t len)
{ (void)phys; (void)len; errno = ENOSYS; return -1; }
int32_t sys_umdf_irq_open(uint64_t vector)
{ (void)vector; errno = ENOSYS; return -1; }
int64_t sys_umdf_dma_alloc(uint64_t len, uint64_t *out_phys)
{ (void)len; (void)out_phys; errno = ENOSYS; return -1; }

/* Window system and Vulkan presentation — HANDOFF.md §4.4. Blocked on the
 * compositor design decision (§6), which is explicitly not this change's to
 * make.
 *   extern def sys_wsys_alloc(pid: uint64) -> int32
 *   extern def sys_wsys_free(wid: int32) -> int32
 *   extern def sys_vk_window_frame(wid: int32, reserved: int32,
 *                                  frame: int64) -> int64 */
int32_t sys_wsys_alloc(uint64_t pid) { (void)pid; errno = ENOSYS; return -1; }
int32_t sys_wsys_free(int32_t wid)   { (void)wid; errno = ENOSYS; return -1; }
int64_t sys_vk_window_frame(int32_t wid, int32_t reserved, int64_t frame)
{ (void)wid; (void)reserved; (void)frame; errno = ENOSYS; return -1; }

/* Interface configuration — HANDOFF.md §3.3. The real answer is rtnetlink,
 * and it is independent of the /net file-tree decision, but it is a subsystem
 * rather than an entry point and belongs with Tier 3.
 *   extern def sys_netcfg(op: uint64, a1: uint64, a2: uint64) -> int64 */
int64_t sys_netcfg(uint64_t op, uint64_t a1, uint64_t a2)
{ (void)op; (void)a1; (void)a2; errno = ENOSYS; return -1; }

/* The #s service registry: post an open fd under a name other processes can
 * open. This is the same cross-process fd-addressing problem HANDOFF §7.1
 * identifies as the sharpest constraint on the /net design, so implementing it
 * here would be prejudging that decision.
 *   extern def sys_srv_post(name: Ptr[char], srvfd: int32) -> int32 */
int32_t sys_srv_post(const char *name, int32_t srvfd)
{ (void)name; (void)srvfd; errno = ENOSYS; return -1; }

/* User administration: writes the Hamnix user database. On Linux the account
 * database is /etc/passwd and shadow, owned by the host distribution; a
 * userland program silently editing it would be wrong.
 *   extern def sys_useradd_root(name: Ptr[char]) -> int32 */
int32_t sys_useradd_root(const char *name)
{ (void)name; errno = ENOSYS; return -1; }

/* Plan 9 rendezvous semaphores and the rfork thread primitive. These are the
 * threading model, and mapping them onto futex(2) and clone(2) is HANDOFF
 * §7.5's open question about whether rfork semantics survive the move at all.
 * Not something to guess at.
 *   extern def sys_semacquire(addr: uint64, block: int32) -> int32
 *   extern def sys_semrelease(addr: uint64, count: int64) -> int64
 *   extern def sys_setexitsem(addr: uint64) -> int32
 *   extern def sys_rfork_thread(flags: int32, child_stack: uint64,
 *                               tls: uint64) -> int32 */
int32_t sys_semacquire(uint64_t addr, int32_t block)
{ (void)addr; (void)block; errno = ENOSYS; return -1; }
int64_t sys_semrelease(uint64_t addr, int64_t count)
{ (void)addr; (void)count; errno = ENOSYS; return -1; }
int32_t sys_setexitsem(uint64_t addr)
{ (void)addr; errno = ENOSYS; return -1; }
int32_t sys_rfork_thread(int32_t flags, uint64_t child_stack, uint64_t tls)
{ (void)flags; (void)child_stack; (void)tls; errno = ENOSYS; return -1; }
