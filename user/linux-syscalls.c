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
#include <ctype.h>
#include <dirent.h>
#include <stdarg.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <sched.h>
#include <sys/inotify.h>
#include <sys/klog.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <netdb.h>
#include <poll.h>
#include <signal.h>
#include <sys/utsname.h>
#include <sys/un.h>
#include <pwd.h>
#include <grp.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/reboot.h>
#include <sys/statfs.h>
#include <sys/sysmacros.h>
#include <stdint.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "linux-fb.h"
#include "linux-wsys.h"
#include "linux-fdns.h"
#include "linux-net.h"
#include "linux-auth.h"
#include "linux-audio.h"
#include "linux-snarf.h"

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
/* THE REASON MUST REACH THE PERSON WHO ASKED, NOT THE CONSOLE.
 *
 * Ten refusals in this file compose a careful, specific diagnosis and hand it
 * to cons_write(). On a machine booted to a shell that is the right place. On
 * a DESKTOP it is not: the owner typed `enter debian {sh}` into a terminal
 * window, and all he saw was the shell's generic line plus strerror_r's "No
 * such file or directory", because sys_errstr was nothing BUT strerror_r. The
 * four-reason message naming /etc/distros, $HAMNIX_DISTRO_<NAME>, filesystem
 * labels and /n/<name> went to a console nobody was looking at.
 *
 * That is this project's oldest failure wearing a new coat -- "a console
 * reported everything, to nobody". A diagnosis delivered where it cannot be
 * read is not better than no diagnosis; it is worse, because it makes the
 * code look like it explained itself.
 *
 * So: one buffer holding the reason for the most recent failure, as text.
 *
 * IT IS ONE-SHOT, AND THAT IS DELIBERATE. errstr means "the reason for the
 * MOST RECENT failure". A buffer that persists would eventually be read
 * against some LATER, unrelated error -- two ENOENTs in a row and the second
 * one inherits the first one's story, which is a confident wrong answer and
 * strictly worse than the generic string. Reading it clears it; a second read
 * falls through to strerror_r. It is also keyed to the errno that was live
 * when it was set, so a mismatch discards it rather than reporting it. */
static char errstr_buf[512];
static int  errstr_errno;

static void errstr_setf(int err, const char *fmt, ...)
{
    /* SAVE AND RESTORE ERRNO ACROSS OUR OWN WORK.
     *
     * vsnprintf is permitted to set errno, and several callers here pass
     * strerror(errno) as an argument. If errno moved between the failure and
     * the caller's return, sys_errstr's `errstr_errno == errno` key would no
     * longer match and the message would be DISCARDED IN SILENCE -- the
     * specific reason thrown away by the very mechanism built to deliver it,
     * leaving the generic string and no sign anything was lost. A recording
     * function must not disturb the thing it is recording. */
    int saved = errno;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(errstr_buf, sizeof errstr_buf, fmt, ap);
    va_end(ap);
    errstr_errno = err;
    errno = saved;
}

int32_t sys_errstr(uint8_t *buf, uint64_t nbuf)
{
    if (!buf || nbuf == 0)
        return 0;
    /* The specific reason, if one was recorded for THIS errno. Consumed on
     * read -- see errstr_buf. */
    if (errstr_buf[0] && errstr_errno == errno) {
        size_t sn = strlen(errstr_buf);
        if (sn > nbuf - 1)
            sn = nbuf - 1;
        memcpy(buf, errstr_buf, sn);
        buf[sn] = '\0';
        errstr_buf[0] = '\0';
        return (int32_t)sn;
    }
    errstr_buf[0] = '\0';

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

/* ------------------------------------------------------------------ *
 * Synthetic device files
 *
 * Some Hamnix devices are files with behaviour that no Linux file has —
 * /dev/fb answers a geometry STRING to a read and takes pixels on a write.
 * Rather than teach the userland about DRM, those paths are intercepted here
 * and served from user/linux-fb.c.
 *
 * The fd handed back is a real one (a descriptor on /dev/null), so it occupies
 * a genuine slot, survives fork, and cannot collide with an ordinary open.
 * Only read/write/lseek/close consult the table.
 * ------------------------------------------------------------------ */
/* SIXTY-FOUR WAS THE REAL WINDOW CEILING OF THE WHOLE SYSTEM, and nothing
 * anywhere said so.
 *
 * This table is per PROCESS and it was sized for a program that opens a
 * handful of devices.  user/wsyswl.ad is not that program: it holds FOUR
 * synthetic files open for every window it manages -- <wid>/draw/ctl,
 * <wid>/keys, <wid>/pointer and <wid>/event -- so 64 entries is SIXTEEN
 * WINDOWS, whatever user/linux-wsys.c's WSYS_MAX_WINDOWS says and whatever
 * MAXCONN * WINPERCONN promises.  Measured, not deduced: 32 weston-simple-shm
 * clients against a MAXCONN-32 build gave `conns 32` and
 * `windows_high_water 16`, with every window after the sixteenth failing in
 * `newwindow` and being counted as `drop_no_window`.
 *
 * That is the FIFTH link in the chain HANDOFF documents -- a ceiling written
 * down twice, in a file nobody looks at when raising the other one -- and it
 * is the worst-behaved of the five, because it does not merely fail: it fails
 * as somebody ELSE's limit.  The compositor reports "no wsys window could be
 * opened for this surface", which sends the reader to the window table (256
 * rows, 240 of them free) rather than to the file table that actually ran out.
 * The window budget invariant MAXWIN >= MAXCONN * WINPERCONN was arithmetic
 * over a number that could not be reached.
 *
 * SO IT IS DERIVED NOW, not chosen: 4 files per window * the device's window
 * table (user/linux-wsys.c, WSYS_MAX_WINDOWS 512) + 64 for everything else a
 * process has open -- /dev/fb, /net, /dev/auth, /dev/snarf, the audio devices.
 * tests/linux/wsyswl_conn_ceiling.sh re-derives it from both files, so the two
 * cannot drift apart again in silence.
 *
 * WHAT IT COSTS.  sizeof(struct devfile) is about 390 bytes, so this is ~824
 * KiB of BSS -- pages the kernel never faults in, because allocation takes the
 * FIRST free slot and stops, and lookup no longer scans at all (see
 * devtab_byfd below).  A program that opens three devices touches three
 * slots.  The old 64-entry table was scanned end to end on every read and
 * write of an ORDINARY file; the map below removes that too, so this is
 * cheaper on the hot path than what it replaces as well as 32x larger. */
#define DEVTAB_MAX 2112
/* /dev/reboot is served inline further down, next to /proc/<pid>/note, which
 * is the same shape (a NAME written to a file is a kernel action). It is
 * claimed here, so only the predicate needs to be visible this early. */
static int reboot_is_path(const char *path);
struct devfile {
    int      used;
    int      fd;
    int      kind;      /* HAMFB_*, or HAMFB_NONE when this is a wsys file */
    int      write;
    uint64_t cursor;    /* byte offset into the surface */
    int      isw;       /* 1 => a /dev/wsys file; `w` is live */
    struct hamwsys_file w;
    int      note_pid;  /* >0 => this is /proc/<pid>/note */
    int      isnet;     /* 1 => a /net file; `nf` is live */
    struct hamnet_file nf;
    int      isauth;    /* 1 => /dev/auth; `af` is live */
    struct hamauth_file af;
    int      isau;      /* 1 => /dev/audio, /dev/audioctl or /dev/audioin;
                         * `au` is live */
    struct hamaudio_file au;
    int      issn;      /* 1 => /dev/snarf or /dev/snarf.primary; `sn` is
                         * live.  No pointers inside, so devtab_clone's
                         * struct copy is already a correct deep copy. */
    struct hamsnarf_file sn;
    int      isreboot;  /* 1 => /dev/reboot.  Carries NO per-open state at
                         * all: the device is one write of one verb, so
                         * devtab_clone's struct copy is trivially correct. */
};
static struct devfile devtab[DEVTAB_MAX];

/* fd -> slot+1, 0 meaning "not a synthetic device".  A HINT and never an
 * authority: every hit is re-validated against the slot's own `used` and `fd`
 * before it is returned, which is what makes it safe to leave stale entries
 * behind on close.  A closed fd's slot either no longer matches (rejected) or
 * has been handed the same fd again (in which case it IS that fd's entry).
 *
 * Why at all: devtab_find is called on EVERY read, write, lseek, close and
 * dup of every fd, and on a miss -- which is the common case, since most fds
 * are ordinary files -- it scanned the whole table.  That was 64 iterations
 * over 390-byte structs per ordinary read before this, and would have been
 * 2112 after.  Now it is one array index.
 *
 * Above DEVTAB_FDMAP the scan is still there and still correct; the kernel
 * hands out the lowest free fd, so a process reaches 4096 open descriptors
 * before it is used at all. */
#define DEVTAB_FDMAP 4096
static int16_t devtab_byfd[DEVTAB_FDMAP];

static void devtab_index(struct devfile *slot)
{
    if (slot->fd >= 0 && slot->fd < DEVTAB_FDMAP)
        devtab_byfd[slot->fd] = (int16_t)((slot - devtab) + 1);
}

static struct devfile *devtab_find(int fd)
{
    if (fd < 0) return NULL;
    if (fd < DEVTAB_FDMAP) {
        int s = devtab_byfd[fd];
        if (s <= 0 || s > DEVTAB_MAX) return NULL;
        struct devfile *v = &devtab[s - 1];
        return (v->used && v->fd == fd) ? v : NULL;
    }
    for (int i = 0; i < DEVTAB_MAX; i++)
        if (devtab[i].used && devtab[i].fd == fd)
            return &devtab[i];
    return NULL;
}

/* Returns the new fd, or -1 with errno if `path` is not a synthetic device or
 * the device could not be opened. */
/* THE FILE TABLE RUNNING OUT MUST NOT LOOK LIKE THE WINDOW SYSTEM RUNNING OUT.
 * Before this, exhaustion was `errno = EMFILE` and nothing else, and what the
 * person actually saw was user/wsyswl.ad's "no wsys window could be opened for
 * this surface" -- a message that points at a window table with hundreds of
 * free rows.  Once, on stderr, with the NAME OF THE NUMBER TO RAISE in it, so
 * a reader is sent to this file instead of to the wrong one.  Once, because
 * this fires per open attempt and a compositor retries every frame: the
 * failure this diagnostic exists to make visible must not be the thing that
 * fills the console and hides everything else. */
static void devtab_full(void)
{
    static int said;
    if (said) return;
    said = 1;
    fprintf(stderr, "hamnix: the synthetic-device file table is full "
                    "(DEVTAB_MAX=%d) -- this open was refused by the RUNTIME, "
                    "not by the device; see DEVTAB_MAX in user/linux-syscalls.c\n",
            DEVTAB_MAX);
}

static int devtab_open(const char *path, int for_write)
{
    int kind  = hamfb_kind(path);
    int wkind = (kind == HAMFB_NONE) ? hamwsys_kind(path) : HAMWSYS_NONE;
    int nkind = (kind == HAMFB_NONE && wkind == HAMWSYS_NONE)
                ? hamnet_kind(path) : HAMNET_NONE;
    int akind = hamauth_is_path(path);
    int aukind = hamaudio_kind(path);
    int snkind = hamsnarf_kind(path);
    int rbkind = reboot_is_path(path);
    if (kind == HAMFB_NONE && wkind == HAMWSYS_NONE && nkind == HAMNET_NONE
        && !akind && aukind == HAMAUDIO_NONE && snkind == HAMSNARF_NONE
        && !rbkind) {
        errno = ENODEV;
        return -1;
    }
    struct devfile *slot = NULL;
    for (int i = 0; i < DEVTAB_MAX; i++)
        if (!devtab[i].used) { slot = &devtab[i]; break; }
    if (!slot) { devtab_full(); errno = EMFILE; return -1; }

    memset(slot, 0, sizeof *slot);
    if (rbkind) {
        /* Nothing to open. The device is stateless and the verb is the whole
         * protocol; an open that allocated anything would have to be undone
         * on the path that never returns. */
        slot->isreboot = 1;
    } else if (kind != HAMFB_NONE) {
        if (hamfb_open(kind, for_write) < 0)
            return -1;
    } else if (akind) {
        hamauth_open(&slot->af);
        slot->isauth = 1;
    } else if (snkind != HAMSNARF_NONE) {
        if (hamsnarf_open(path, for_write, &slot->sn) < 0)
            return -1;
        slot->issn = 1;
    } else if (aukind != HAMAUDIO_NONE) {
        if (hamaudio_open(path, for_write, &slot->au) < 0)
            return -1;
        slot->isau = 1;
    } else if (wkind != HAMWSYS_NONE) {
        if (hamwsys_open(path, for_write, &slot->w) < 0)
            return -1;
        slot->isw = 1;
    } else {
        if (hamnet_open(path, for_write, &slot->nf) < 0)
            return -1;
        slot->isnet = 1;
    }

    /* A /net data file is opened for WRITING by net_dial and then READ from
     * as well (user/net9.ad), so the standing descriptor must be read/write
     * whichever way the caller asked. */
    /* /dev/audio is opened for WRITING by every player and then READ for its
     * status line, so the standing descriptor must be read/write either way. */
    /* /dev/snarf.serial BRINGS ITS OWN DESCRIPTOR, and it is the only device
     * here that does: an inotify watch on the clipboard segment, so an event
     * loop can PARK on the clipboard rather than look at it on a clock (see
     * user/linux-snarf.c).  Everything else gets the /dev/null slot whose
     * always-readable-ness sys_waitfds has to sort out by hand below. */
    int fd = slot->issn ? hamsnarf_waitfd(&slot->sn) : -1;
    if (fd < 0)
        fd = open("/dev/null",
                  (slot->isnet || slot->isauth || slot->isau || !for_write)
                      ? O_RDWR : O_WRONLY);
    if (fd < 0) {
        int e = errno;
        if (slot->isw)   hamwsys_close(&slot->w);
        if (slot->isnet) hamnet_close(&slot->nf);
        if (slot->isau)  hamaudio_close(&slot->au);
        slot->isw = 0; slot->isnet = 0; slot->isau = 0;
        errno = e;
        return -1;
    }
    slot->used = 1; slot->fd = fd; slot->kind = kind;
    slot->write = for_write; slot->cursor = 0;
    devtab_index(slot);
    return fd;
}

/* 1 if `path` is served from the synthetic-device table rather than the
 * filesystem.  Both device families answer here. */
static int dev_path(const char *path)
{
    return hamfb_kind(path) != HAMFB_NONE
        || hamwsys_kind(path) != HAMWSYS_NONE
        || hamnet_kind(path) != HAMNET_NONE
        || hamauth_is_path(path)
        || hamaudio_kind(path) != HAMAUDIO_NONE
        || hamsnarf_kind(path) != HAMSNARF_NONE
        || reboot_is_path(path);
}

/* /proc/<pid>/note — Plan 9 delivers a SIGNAL by writing a NAME to a file, and
 * lib/p9.ad's p9_note is how the whole tree does it: closing a window posts
 * "terminate" to the window's owner, a shell posts "interrupt" on ^C.  Linux
 * /proc has no such file, so the path is intercepted here and the note is
 * translated to kill(2).  Without this, closing a DE window did nothing at all
 * and every terminal leaked its shell.
 *
 * Returns the pid, or 0 if the path is not a note file. */
static int note_path_pid(const char *path)
{
    if (strncmp(path, "/proc/", 6) != 0)
        return 0;
    const char *p = path + 6;
    int pid = 0;
    if (*p < '1' || *p > '9')
        return 0;
    while (*p >= '0' && *p <= '9') { pid = pid * 10 + (*p - '0'); p++; }
    if (strcmp(p, "/note") != 0)
        return 0;
    return pid;
}

static int note_open(int pid)
{
    struct devfile *slot = NULL;
    for (int i = 0; i < DEVTAB_MAX; i++)
        if (!devtab[i].used) { slot = &devtab[i]; break; }
    if (!slot) { devtab_full(); errno = EMFILE; return -1; }
    /* Fail here rather than at the write, so a note to a dead process is an
     * open error the caller already checks for. */
    if (kill((pid_t)pid, 0) < 0)
        return -1;
    int fd = open("/dev/null", O_WRONLY);
    if (fd < 0) return -1;
    memset(slot, 0, sizeof *slot);
    slot->used = 1; slot->fd = fd; slot->kind = HAMFB_NONE;
    slot->write = 1; slot->note_pid = pid;
    devtab_index(slot);
    return fd;
}

static int64_t note_write(int pid, const uint8_t *buf, uint64_t count)
{
    /* The note NAME, matched on its prefix so a trailing newline or argument
     * does not change the meaning. */
    int sig = SIGTERM;
    if      (count >= 9 && !memcmp(buf, "interrupt", 9)) sig = SIGINT;
    else if (count >= 6 && !memcmp(buf, "hangup",    6)) sig = SIGHUP;
    else if (count >= 4 && !memcmp(buf, "kill",      4)) sig = SIGKILL;
    else if (count >= 5 && !memcmp(buf, "alarm",     5)) sig = SIGALRM;
    if (kill((pid_t)pid, sig) < 0)
        return rc64(-1);
    return (int64_t)count;
}

/* ------------------------------------------------------------------ *
 * /dev/reboot — turning the machine off.
 *
 * This is the port of Hamnix's DEV_REBOOT cdev (sys/src/9/port/namec.ad:
 * _devreboot_write, backed by arch/x86/kernel/power.ad:power_action). Until
 * it existed here, NOTHING on this line served the name, so `reboot`,
 * `poweroff`, `halt` and hamsh's `init 0` / `init 6` all died on the open --
 * "reboot: cannot open /dev/reboot" -- and an installed machine had no
 * supported way to stop. Worse than the inconvenience: nothing flushed the
 * filesystems, so every restart of an installed hamnix-linux to date was the
 * equivalent of pulling the plug, and survived only because ext4 has a
 * journal. docs/linux_installed_update.md §2c is the measurement.
 *
 * WHY IT LIVES HERE AND NOT IN user/linux-reboot.c. The other served devices
 * (linux-fb.c, linux-wsys.c, linux-snarf.c, ...) get their own file because
 * they carry real state -- a shared segment, a window table, a DRM master,
 * a cursor addressed by lseek. This device carries NONE: no per-open state,
 * no seek, reads are EOF, and the whole implementation is one token matcher
 * and one write. /proc/<pid>/note directly above is the same shape (a name
 * written to a file becomes a kernel action) and is served inline for the
 * same reason. Doing it inline also means scripts/hamlinux_build.sh needs no
 * new object, no new header in the staleness list, and no new name on the
 * link line -- a whole class of "it builds here but not on that path" that
 * this tree has already paid for once.
 *
 * THE PROTOCOL IS PORTED, NOT INVENTED. Hamnix matches the FIRST TOKEN of
 * the buffer, delimited by NUL, '\n', ' ' or the end of `count`, so
 * "reboot", "reboot\n" and "reboot now" all mean the same thing; the match
 * is case-sensitive; and the three verbs are exactly `poweroff`, `reboot`,
 * `halt`. Every client in this tree already writes one of those with a
 * trailing newline (user/reboot.ad, user/halt.ad, user/poweroff.ad,
 * hamsh's svc_runlevel_halt/_reboot, hamsessui's power menu, hamctl's).
 *
 * SYNC IS THE POINT. Hamnix's power_action() flushes every filesystem and
 * every block device before it touches the hardware. Linux's reboot(2) does
 * NOT sync -- the caller must -- so the port is sync(2) and then reboot(2).
 * sync(2) on Linux waits for the writeback it started, which is what makes
 * "the file I wrote before the reboot is there afterwards" true without
 * relying on the journal to replay it.
 *
 * IT DOES NOT STOP SERVICES OR THE DESKTOP, deliberately. That policy
 * already lives one layer up and in the right place: hamsh's
 * svc_runlevel_halt() / svc_runlevel_reboot() SIGTERM every supervised
 * service and source /etc/rc.d/rc.0 / rc.6 BEFORE they write here, exactly
 * as Hamnix does. Putting it in the device instead would mean a machine that
 * cannot power off because one service will not die -- and a shutdown that
 * hangs forever is worse than a fast one. So the device is the primitive:
 * flush, and go.
 *
 * WHO MAY DO IT. reboot(2) needs CAP_SYS_BOOT, and this file is linked into
 * every Adder program, so the call happens as whoever wrote to the device.
 * That is a REAL difference from Hamnix, where the cdev is ungated (the
 * devcons permission hook admits every uid) and only the Linux-ABI reboot(2)
 * requires the hostowner. Here the unprivileged session gets EPERM back from
 * the write and every client in the tree already reports that by name and
 * exits non-zero. It is NOT silently swallowed.
 * ------------------------------------------------------------------ */
static int reboot_is_path(const char *path)
{
    return path && !strcmp(path, "/dev/reboot");
}

/* 1 iff the first token of `buf` equals `word`. The port of
 * namec.ad:_verb_matches, delimiters and all. */
static int reboot_verb(const uint8_t *buf, uint64_t count, const char *word)
{
    uint64_t n = (uint64_t)strlen(word);
    if (count < n || memcmp(buf, word, (size_t)n) != 0)
        return 0;
    if (count == n)
        return 1;
    uint8_t c = buf[n];
    return c == 0 || c == '\n' || c == ' ';
}

static int64_t reboot_write(const uint8_t *buf, uint64_t count)
{
    int cmd;
    const char *name;
    if      (reboot_verb(buf, count, "poweroff")) { cmd = RB_POWER_OFF;   name = "poweroff"; }
    else if (reboot_verb(buf, count, "reboot"))   { cmd = RB_AUTOBOOT;    name = "reboot"; }
    else if (reboot_verb(buf, count, "halt"))     { cmd = RB_HALT_SYSTEM; name = "halt"; }
    else {
        /* Hamnix answers `count` and does nothing for a verb it does not
         * know, so a stray writer cannot wedge on the device. Ported as-is:
         * an rc script must not behave differently on the two kernels. */
        return (int64_t)count;
    }

    /* THE INHIBIT. This object is linked into every Adder binary, and some of
     * them are HOST-side harnesses that run on a developer's own machine. A
     * test that exercised this path there would power off a workstation. The
     * escape hatch is opt-in, so a real system with no such variable set is
     * untouched, and it FAILS BY NAME rather than pretending to have worked --
     * the caller gets EPERM and a line saying why. */
    if (getenv("HAMNIX_REBOOT_INHIBIT")) {
        fprintf(stderr,
                "/dev/reboot: %s INHIBITED by HAMNIX_REBOOT_INHIBIT"
                " -- the machine is still running\n", name);
        fflush(stderr);
        errno = EPERM;
        return -EPERM;
    }

    /* Flush first, and only then ask for the power action. reboot(2) does not
     * do this for us. */
    sync();

    if (reboot(cmd) < 0)
        return rc64(-1);
    /* Unreachable on success: the machine is gone. */
    return (int64_t)count;
}

/* Hamnix console/kernel files that Linux already publishes, or can.
 *
 * The DE reads the wall clock as `btime` from /dev/stat plus the uptime in
 * NANOSECONDS from /dev/time (user/hampanelscene.ad:_read_btime,
 * _read_uptime_ns). Neither existed here, both reads failed, and the panel
 * clock sat at "Thu Jan 01 00:00" -- a date, confidently rendered, computed
 * from two zeroes.
 *
 * /dev/stat needs no synthesis at all: lib/cpustat.ad's header says outright
 * that it is "the Linux /proc/stat shape", and /proc/stat carries both the
 * `cpu` aggregate row and the `btime` line. So it is the same file under the
 * name this tree uses for it.
 *
 * /dev/time does need synthesis, and gets a memfd holding the value at OPEN
 * time. That is the right semantics rather than a shortcut: these files are
 * snapshots in Plan 9, the panel re-opens on every poll, and a reader that
 * seeks back gets a consistent number rather than a moving one.
 *
 * Returns a real fd, or -1 with errno untouched if this is not one of them. */
static int devfile_open(const char *path)
{
    if (!strcmp(path, "/dev/stat")) {
        /* /proc/stat, REORDERED so the two lines the DE needs come first.
         *
         * The panel reads this file into a 2048-byte buffer and scans it for
         * `btime` (user/hampanelscene.ad:_read_btime); lib/cpustat.ad scans
         * the same window for the `cpu ` aggregate.  Linux puts btime AFTER
         * one cpuN line per core -- on this build host that is byte 5246, far
         * outside the window, so on any machine with a lot of cores the panel
         * would silently read btime = 0 and render 1970 with total
         * confidence.  It works in a 2-CPU VM and fails on a workstation,
         * which is the worst shape a bug can have.
         *
         * Emitting the aggregate and btime first is a reordering, not an
         * invention: every line is /proc/stat's own, and a reader that wants
         * the per-core rows still finds them. */
        FILE *in = fopen("/proc/stat", "r");
        if (!in) return -1;
        char line[512], first[1024], rest[16384];
        size_t fl = 0, rl = 0;
        while (fgets(line, sizeof line, in)) {
            size_t n = strlen(line);
            int head = (!strncmp(line, "cpu ", 4) || !strncmp(line, "btime ", 6));
            if (head && fl + n < sizeof first) { memcpy(first + fl, line, n); fl += n; }
            else if (rl + n < sizeof rest)     { memcpy(rest + rl, line, n);  rl += n; }
        }
        fclose(in);
        int fd = memfd_create("hamnix-stat", 0);
        if (fd < 0) return -1;
        if ((fl && write(fd, first, fl) != (ssize_t)fl)
            || (rl && write(fd, rest, rl) != (ssize_t)rl)
            || lseek(fd, 0, SEEK_SET) < 0) {
            int e = errno; close(fd); errno = e; return -1;
        }
        return fd;
    }

    if (!strcmp(path, "/proc/realtime")) {
        /* Hamnix's procfs renders the wall clock here and user/date.ad reads
         * exactly this line; Linux's procfs has no such file, so `date`
         * reported "/proc/realtime unavailable" on a machine that knows the
         * time perfectly well.
         *
         * The layout is byte-exact and date.ad asserts on it -- ISO-8601 UTC,
         * then a space, then the epoch:
         *
         *     YYYY-MM-DDTHH:MM:SSZ <epoch>\n
         *
         * so it is reproduced rather than approximated. date.ad checks for
         * 'T' at offset 10 on purpose, "so a future format change surfaces as
         * a test failure instead of a silent garbled print" -- worth keeping
         * true. */
        time_t now = time(NULL);
        struct tm tmv;
        if (!gmtime_r(&now, &tmv)) return -1;
        char buf[96];
        int n = snprintf(buf, sizeof buf,
                         "%04d-%02d-%02dT%02d:%02d:%02dZ %lld\n",
                         tmv.tm_year + 1900, tmv.tm_mon + 1, tmv.tm_mday,
                         tmv.tm_hour, tmv.tm_min, tmv.tm_sec,
                         (long long)now);
        int fd = memfd_create("hamnix-realtime", 0);
        if (fd < 0) return -1;
        if (write(fd, buf, (size_t)n) != n || lseek(fd, 0, SEEK_SET) < 0) {
            int e = errno; close(fd); errno = e; return -1;
        }
        return fd;
    }

    if (!strcmp(path, "/dev/time")) {
        struct timespec ts;
        if (clock_gettime(CLOCK_MONOTONIC, &ts) < 0)
            return -1;
        char buf[32];
        int n = snprintf(buf, sizeof buf, "%llu",
                         (unsigned long long)ts.tv_sec * 1000000000ull
                         + (unsigned long long)ts.tv_nsec);
        int fd = memfd_create("hamnix-time", 0);
        if (fd < 0) return -1;
        if (write(fd, buf, (size_t)n) != n || lseek(fd, 0, SEEK_SET) < 0) {
            int e = errno;
            close(fd);
            errno = e;
            return -1;
        }
        return fd;
    }
    return -1;
}

/* extern def sys_open(path: Ptr[char]) -> int32
 * ONE argument, opened for reading — see the long note at the .S definition. */
int32_t sys_open(const char *path)
{
    if (path && path[0] == '/'
        && (path[1] == 'd' || path[1] == 'p')) {
        int d = devfile_open(path);
        if (d >= 0) return (int32_t)d;
    }
    fdns_gate_release();
    /* /fd/<n> is a NAME for a descriptor, possibly one another process bound
     * for us. It resolves to a real fd, so it never enters the device table. */
    if (fdns_is_path(path))
        return rc32(fdns_open(path, 0));
    if (dev_path(path))
        return rc32(devtab_open(path, 0));
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

/* extern def sys_open_sync(path: Ptr[char]) -> int32
 *
 * Open an EXISTING file for writing with O_SYNC, and create nothing.
 *
 * THE TWO WORDS THAT MATTER ARE `EXISTING` AND `O_SYNC`, and they are the
 * whole durability argument of the boot log (user/bootlogd.ad):
 *
 *   NO O_CREAT AND NO O_TRUNC. The log file is preallocated to its full size
 *   at image build time (scripts/hamlinux_disk.sh) and is only ever OVERWRITTEN
 *   IN PLACE. Nothing at runtime ever creates it, extends it or changes its
 *   length, so no cluster is ever allocated, the FAT chain is never mutated,
 *   and the directory entry's size and starting cluster never change. That is
 *   what makes FAT's lack of a journal a non-issue for this file, and it is
 *   also what makes the log incapable of filling the filesystem: there is no
 *   code path that can make it bigger than it was built.
 *
 *   O_SYNC, because the failure this exists to survive is the power button.
 *   tests/linux/install_from_usb.sh measured the alternative on ext4: SIGKILL
 *   to QEMU before the journal's 5 s commit, and the write was still in the
 *   guest's page cache and simply gone. A journal keeps a filesystem
 *   CONSISTENT; it does not keep YOUR DATA. O_SYNC means write(2) does not
 *   return until the bytes are on the medium, which is the only property that
 *   makes a log worth trusting -- and a log that is lost precisely when the
 *   boot fails is worse than none, because it will be believed.
 *
 * The cost is paid by ONE process on a background loop, never by the boot. */
int32_t sys_open_sync(const char *path)
{
    return rc32(open(path, O_WRONLY | O_SYNC | O_CLOEXEC));
}

/* extern def sys_klogread(buf: Ptr[uint8], n: uint64) -> int64
 *
 * The kernel's log ring, read WITHOUT consuming it: klogctl(2) command 3,
 * SYSLOG_ACTION_READ_ALL, which is what `dmesg` does.
 *
 * READ_ALL rather than a read of /dev/kmsg, for two reasons that are both
 * about being an instrument rather than a participant:
 *
 *   * It is NON-DESTRUCTIVE. /proc/kmsg drains the ring, so a logger reading
 *     it would take the messages away from every other reader, `dmesg`
 *     included. Something that makes the evidence disappear as it records it
 *     is not something to put in a boot.
 *
 *   * It is BOUNDED, AND BOUNDED AT THE INTERESTING END. When the ring holds
 *     more than `n` bytes the kernel returns the LAST `n` -- the tail, which
 *     is the part a person cares about after a boot went wrong. So the caller's
 *     buffer size is the whole size policy and there is nothing to truncate by
 *     hand.
 *
 * Negative return is -errno; EPERM when dmesg_restrict is set and the caller
 * is not root, which the caller reports rather than mistaking for an empty
 * ring. */
int64_t sys_klogread(uint8_t *buf, uint64_t n)
{
    if (n > 0x7fffffff) n = 0x7fffffff;
    return rc64(klogctl(3 /* SYSLOG_ACTION_READ_ALL */, (char *)buf, (int)n));
}

/* extern def sys_open_write(path: Ptr[char]) -> int32
 * Open-or-create for writing, truncating an existing file. */
int32_t sys_open_write(const char *path)
{
    fdns_gate_release();
    if (fdns_is_path(path))
        return rc32(fdns_open(path, 1));
    int npid = note_path_pid(path);
    if (npid > 0)
        return rc32(note_open(npid));
    if (dev_path(path))
        return rc32(devtab_open(path, 1));

    /* A DEVICE PATH WITH NO SERVER MUST FAIL, NOT BE CREATED.
     *
     * This call is open(O_WRONLY|O_CREAT|O_TRUNC), and dev_path() only claims
     * the device paths that actually have a server behind them.  So a client
     * writing to a device this line does not serve got a brand-new ORDINARY
     * FILE at that path and no indication of anything wrong: user/playtone.ad
     * wrote 24000 frames into a regular file called /dev/audio, reported
     * "played 1000 Hz square wave, 24000 frames", and exited 0.  Six audio
     * programs did the same thing, and every write-first client of any device
     * added later would have inherited it.
     *
     * Device nodes are made by the kernel or by a server, never by a client
     * opening one for writing -- so under /dev the create flag is simply
     * wrong, and its absence turns a silent success into ENOENT. */
    if (!strncmp(path, "/dev/", 5))
        return rc32(open(path, O_WRONLY | O_TRUNC));
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0666);
    if (fd < 0 && errno == ETXTBSY) {
        /* The file is a RUNNING executable. Linux refuses to truncate one,
         * which is right -- rewriting the pages under a live process would be
         * a disaster -- but it also means a package manager cannot replace a
         * binary that is in use, and the first such binary is /bin/hamsh,
         * which is PID 1. `hpm install hamnix-base` got exactly this far and
         * stopped: "cannot create /bin/hamsh".
         *
         * unlink-then-create is the standard answer and the one dpkg uses:
         * the running process keeps the inode it already has open, the name
         * is rebound to a NEW inode, and the old one goes away when the last
         * user exits. So a self-update works and nothing running is disturbed
         * -- which is the property "update without breaking the system"
         * actually rests on. */
        if (unlink(path) == 0)
            fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0666);
        else
            errno = ETXTBSY;
    }
    return rc32(fd);
}

/* extern def sys_read(fd: int32, buf: Ptr[uint8], count: uint64) -> int64
 * On a directory fd, serve the synthesised "NAME\n" stream. */
int64_t sys_read(int32_t fd, uint8_t *buf, uint64_t count)
{
    fdns_gate_release();
    /* The OTHER place a process stops making progress on its own: a blocking
     * read of a pipe this process created. `{ cmd }` command substitution is
     * exactly that -- the shell holds the keeper and reads the pipe -- so
     * without this the substitution never ends either. */
    fdns_keeper_sweep(FDNS_KEEPER_WAIT_MS);
    struct devfile *v = devtab_find((int)fd);
    if (v) {
        int64_t n;
        /* /dev/reboot is write-only; a read is EOF so a stray `cat` gets an
         * answer instead of wedging. Hamnix's _devtab_read does the same. */
        if (v->isreboot)
            return 0;
        if (v->isauth)
            return hamauth_read(&v->af, buf, count);
        if (v->isau)
            return hamaudio_read(&v->au, buf, count);
        if (v->issn)
            return hamsnarf_read(&v->sn, buf, count);
        if (v->isnet)
            return hamnet_read(&v->nf, buf, count);
        if (v->isw)
            return hamwsys_read(&v->w, buf, count);
        if (v->kind == HAMFB_FB) {
            /* Reading /dev/fb answers the geometry line, once. */
            if (v->cursor) return 0;
            n = hamfb_geometry(buf, count);
            if (n > 0) v->cursor += (uint64_t)n;
            return n;
        }
        if (v->kind == HAMFB_FBPIX) {
            n = hamfb_read_pixels(v->cursor, buf, count);
            if (n > 0) v->cursor += (uint64_t)n;
            return n;
        }
        return 0;                       /* fbctl is write-only */
    }
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

/* extern def sys_read_nb(fd: int32, buf: Ptr[uint8], count: uint64) -> int64
 *
 * Non-blocking read. 0 means "nothing ready yet", never EOF-forever — that is
 * the contract hamui's input poll depends on (lib/hamui.ad:_h_poll_pointer).
 *
 * This MUST go through the device table. hamui polls /dev/wsys/<wid>/keys and
 * /dev/wsys/<wid>/pointer with exactly this call; the freestanding version in
 * linux-runtime.S is a raw read(2) on the /dev/null descriptor standing in for
 * the device, so it would return 0 for ever and no GUI app would see input. */
int64_t sys_read_nb(int32_t fd, uint8_t *buf, uint64_t count)
{
    /* Zero wait: this call must not block, ever. But a poller still needs the
     * keeper gone or it can never reach true end-of-input -- a terminal
     * polling its shell's output would never learn that the shell had
     * exited. Sweeping only the slots whose two real ends are already open
     * costs nothing and cannot wait. */
    fdns_keeper_sweep(0);
    struct devfile *v = devtab_find((int)fd);
    if (v) {
        if (v->isw)
            return hamwsys_read(&v->w, buf, count);
        /* /dev/audioin is already non-blocking: an empty capture ring
         * answers 0, which is what this call means by "nothing yet". */
        if (v->isau)
            return hamaudio_read(&v->au, buf, count);
        /* The clipboard is memory: a read never blocks, so "nothing ready
         * yet" and "end of the buffer" are the same 0 here and the blocking
         * path is already the non-blocking one. */
        if (v->issn)
            return hamsnarf_read(&v->sn, buf, count);
        if (v->isnet) {
            /* A /net data file is a real socket, and reading it blocks. This
             * used to fall through to sys_read, so a caller that asked for a
             * non-blocking read got a blocking one -- user/dhcpc.ad polling
             * for an OFFER simply stopped, and the boot stopped with it. The
             * flag is restored afterwards for the same reason it is on a
             * plain fd: leaving it set would turn every later blocking read
             * into an EAGAIN a caller reads as end-of-input. */
            int sfd = hamnet_sockfd(&v->nf);
            if (sfd < 0)
                return hamnet_read(&v->nf, buf, count);
            int fl = fcntl(sfd, F_GETFL, 0);
            int flipped = 0;
            if (fl >= 0 && !(fl & O_NONBLOCK)) {
                if (fcntl(sfd, F_SETFL, fl | O_NONBLOCK) == 0)
                    flipped = 1;
            }
            int64_t r = hamnet_read(&v->nf, buf, count);
            int e = errno;
            if (flipped)
                fcntl(sfd, F_SETFL, fl);
            errno = e;
            if (r < 0 && (e == EAGAIN || e == EWOULDBLOCK))
                return 0;
            return r;
        }
        return sys_read(fd, buf, count);
    }
    if (dirtab_find((int)fd))
        return sys_read(fd, buf, count);
    /* Non-blocking for THIS read only. Leaving O_NONBLOCK set -- which the
     * freestanding version in linux-runtime.S does -- makes the mode STICKY:
     * every later blocking sys_read on the same descriptor returns -EAGAIN
     * instead of waiting, and a caller that reads that as end-of-input just
     * stops. That is what killed the DE terminal's shell: hamsh polls its
     * stdin with read_nb, then blocks on it, got -EAGAIN, concluded EOF and
     * exited -- and hamtermscene dutifully closed the window. On Hamnix
     * read_nb is a separate kernel path that leaves the channel alone, so
     * restoring the flags is what makes this the same call. */
    int fl = fcntl((int)fd, F_GETFL, 0);
    int flipped = 0;
    if (fl >= 0 && !(fl & O_NONBLOCK)) {
        if (fcntl((int)fd, F_SETFL, fl | O_NONBLOCK) == 0)
            flipped = 1;
    }
    ssize_t n = read((int)fd, buf, (size_t)count);
    int e = errno;
    if (flipped)
        fcntl((int)fd, F_SETFL, fl);
    errno = e;
    if (n < 0 && (e == EAGAIN || e == EWOULDBLOCK))
        return 0;
    if (n == 0) {
        /* TRUE END OF INPUT, and it must not be reported as 0.
         *
         * The contract this call has -- stated at the freestanding definition
         * in linux-runtime.S -- is "0 == no byte ready yet, a negative ==
         * true EOF/error".  read(2) uses 0 for EOF, so returning it verbatim
         * collided the two states, and every caller that polls read the end
         * of its input as "nothing yet, try again".
         *
         * hamsh's ed_readline is the one that matters: `if n < 0: return -1`
         * / `if n == 0: continue`.  So `hamsh < script` ran the script and
         * then polled for ever instead of exiting -- measured, along with vi,
         * hamfm, hdu, hlog and keydemo hanging the same way.  A shell that
         * never returns from a script is not a small bug. */
        errno = 0;
        return -1;
    }
    return rc64(n);
}

/* THE CONSOLE MIRROR, and why a shipped medium cannot work without it.
 *
 * /dev/console is ONE tty: the kernel points it at the LAST `console=` on the
 * command line and writes to it go there and nowhere else. printk is the only
 * thing that fans out to every registered console, which is why linuxinit
 * echoes its own lines to /dev/kmsg (see the long note in user/linuxinit.ad).
 *
 * That trick stops at the exec. hamsh, /etc/rc.boot, and every program the rc
 * runs write to the descriptor they inherited -- /dev/console -- and nothing
 * copies those bytes anywhere. On the owner's laptop, 2026-08-15, that was the
 * whole failure: PID 1's lines reached the framebuffer through kmsg, it printed
 * "namespace ready -- exec /bin/hamsh /etc/rc.boot", and then the screen stopped
 * changing because /dev/console was ttyS0 and the machine has no serial port.
 * The boot was fine. It was TALKING INTO A WIRE THAT WAS NOT THERE.
 *
 * So the shipped command line now ends `console=ttyS0,115200 console=tty0`:
 * /dev/console is the SCREEN, which is the only channel a laptop has and the
 * only one a person can type back into. That alone would have blinded every
 * gate in this tree, all of which read the serial port -- so this is the other
 * half. When the console is split like that, a write to fd 1 or 2 that is
 * really going to /dev/console is copied to the serial port as well.
 *
 * WHY THIS AND NOT THE ALTERNATIVES:
 *   * A gate-only HAMLINUX_CMDLINE override was rejected because the command
 *     line is baked into a PE section of the UKI, and user/hlinstall.ad copies
 *     THAT VERY UKI onto the target's ESP. An override would mean no gate ever
 *     boots the console arrangement that ships, on the medium or on the machine
 *     installed from it -- the exact class of gap that let this bug reach metal.
 *   * Mirroring to /dev/kmsg instead of the serial port would reach the gate
 *     (printk goes to ttyS0) but ALSO to tty0, so every line would be drawn on
 *     the screen twice. The serial port is the one console the screen is not.
 *   * Teaching hamsh to mirror was rejected because hamsh is not the writer:
 *     `cat /proc/partitions`, `ls`, and `install --auto` all write for
 *     themselves. This is the one choke point every Adder program passes.
 *
 * WHAT IT DELIBERATELY DOES NOT TOUCH. The rdev test is the whole discipline:
 * only fd 5:1, the console device itself, is mirrored. `cmd > file`, a pipe, a
 * terminal window's pty and a socket all have other rdevs and are left alone,
 * so a redirect still puts its bytes in exactly one place. And when the last
 * `console=` IS the serial port -- every `-kernel` developer boot in
 * tests/linux -- the mirror stays off and nothing changes at all.
 *
 * COST when it is on: one fstat per write to fd 1/2. It cannot be cached per
 * descriptor because hamsh redirects a CHILD's fd 1 after the fork, and a
 * cached "this is the console" would then copy a redirected file's bytes onto
 * the serial port. */
static int consmirror_fd = -2;          /* -2 undecided, -1 off, else the port */

/* RETRIED, NOT LATCHED, WHILE THE ANSWER IS STILL UNKNOWABLE. linuxinit prints
 * its first lines before it has bound /proc or /dev, so the very first console
 * write cannot read /proc/cmdline and cannot open a tty. Deciding "off" there
 * would turn the mirror off for the rest of that process -- and in PID 1 that
 * is the whole boot. So a missing /proc or a missing device node leaves the
 * decision open and the next write asks again; only a command line that has
 * been READ and says no is final. The retry is bounded so a machine with a
 * serial console named on the command line but no device node for it does not
 * pay an open(2) on every console write for ever. */
static int consmirror_tries = 0;

static void consmirror_setup(void)
{
    char cmd[4096];
    if (++consmirror_tries > 32) { consmirror_fd = -1; return; }
    int f = open("/proc/cmdline", O_RDONLY | O_CLOEXEC);
    if (f < 0) return;                          /* no /proc yet: ask again */
    ssize_t n = read(f, cmd, sizeof cmd - 1);
    close(f);
    if (n <= 0) return;
    cmd[n] = '\0';
    consmirror_fd = -1;                         /* from here the answer is real */

    /* The LAST console= is what /dev/console follows; the last serial one is
     * where the gates listen. Both are read in one pass. */
    char last[64] = "", ser[64] = "";
    for (char *p = strtok(cmd, " \t\r\n"); p; p = strtok(NULL, " \t\r\n")) {
        if (strncmp(p, "console=", 8) != 0) continue;
        snprintf(last, sizeof last, "%s", p + 8);
        if (strncmp(p + 8, "ttyS", 4) == 0)
            snprintf(ser, sizeof ser, "%s", p + 8);
    }
    if (ser[0] == '\0') return;                 /* no serial console to mirror to */
    if (strncmp(last, "ttyS", 4) == 0) return;  /* /dev/console already IS it */

    char *comma = strchr(ser, ',');
    if (comma) *comma = '\0';
    char path[80];
    snprintf(path, sizeof path, "/dev/%s", ser);
    int r = open(path, O_WRONLY | O_NOCTTY | O_CLOEXEC);
    if (r < 0) {
        /* EACCES IS A FINAL ANSWER, AND IT USED TO BE A SILENT ONE.
         *
         * MEASURED on a real installed machine, 2026-08-19: as uid 1001 this
         * open returns EACCES (the node is mode 0600 root), the mirror never
         * comes up, and every console write from that process goes to
         * /dev/console -- which on the shipped command line is the SCREEN,
         * behind the compositor -- and to nowhere else.  write(2) went on
         * returning the full byte count throughout.  A whole release
         * conclusion was drawn from that silence: commit 416248df reverted the
         * chrome's privilege drop because "the application never opens a
         * window as uid 1001", and it does -- it just could not be heard.
         *
         * user/linuxinit.ad now chmods this node 0622 at boot so the case does
         * not arise on a Hamnix boot.  This branch is for every other way of
         * arriving here: a machine booted by something else, a node whose mode
         * was changed, a container.  It says so ONCE, on the console this
         * process CAN still reach, and latches off -- a permission is not
         * going to appear on the next write, so retrying 32 times would only
         * cost opens.  Written with write(2) and not cons_write, because
         * cons_write comes back through here. */
        if (errno == EACCES) {
            static int said;
            consmirror_fd = -1;                 /* before writing: no recursion */
            if (!said) {
                said = 1;
                char m[320];
                int n = snprintf(m, sizeof m,
                    "cons: this process (uid %ld) may not open %s, so nothing "
                    "it prints will reach the serial console -- only the "
                    "screen, which the compositor covers. Its writes will "
                    "still report success.\n", (long)geteuid(), path);
                ssize_t ignored = write(2, m, (size_t)(n < 0 ? 0 : n));
                (void)ignored;
            }
            return;
        }
        consmirror_fd = -2; return;             /* no node yet: ask again */
    }
    consmirror_fd = r;
}

/* ------------------------------------------------------------------ *
 * THE SECOND SINK: THE CONSOLE INTO THE KERNEL LOG, SO IT CAN BE PERSISTED.
 *
 * consmirror above copies the console onto a serial port so the GATES can read
 * it. This copies the same bytes into /dev/kmsg so that something can WRITE
 * THEM TO THE STICK -- see user/bootlogd.ad, which snapshots the kernel ring
 * onto the boot medium's FAT partition. The owner has no serial cable; the
 * serial mirror does nothing for him at all.
 *
 * WHY <7> AND WHY THIS DOES NOT PUT EVERY LINE ON THE SCREEN TWICE. This is
 * the objection recorded in the header of consmirror -- "mirroring to
 * /dev/kmsg would reach the gate but ALSO tty0, so every line would be drawn
 * on the screen twice" -- and it is answered by the PRIORITY, which that note
 * did not consider. printk prints a record only when its level is strictly
 * LESS THAN console_loglevel, and the shipped command line says `loglevel=7`.
 * A record emitted at <7> (KERN_DEBUG) is therefore RECORDED IN THE RING AND
 * NOT PRINTED ON ANY CONSOLE. user/linuxinit.ad:say() already turns on exactly
 * this fact and says so, and tests/linux/console_screen.sh already asserts the
 * consequence ("PID 1's lines appear on the screen once, not once bare and
 * once with a printk timestamp") -- so if this is wrong, that gate goes red
 * rather than the owner finding out on his laptop.
 *
 * ONE RECORD PER LINE, WHICH IS WHY THERE IS A BUFFER. /dev/kmsg is
 * record-oriented: one write(2) is one log record. The console writes that
 * pass through here are not lines -- user/linuxinit.ad:write_cstr emits
 * "linuxinit: ", the message, and "\n" as THREE separate writes -- so writing
 * each one straight through would produce three timestamped fragments where a
 * person expects one line. Bytes are accumulated here and a record is emitted
 * on the newline (or when the buffer is full, so a program that never emits
 * one cannot lose its output).
 *
 * "cons: " ON THE FRONT, so the log distinguishes what a PROGRAM printed from
 * what the KERNEL printed. It also means linuxinit's lines, which are already
 * in the ring because say() puts them there, are visibly the same line twice
 * rather than a mystery: once as `linuxinit: ...` and once as
 * `cons: linuxinit: ...`.
 *
 * WHAT IT CANNOT CAPTURE, stated here rather than discovered later: /dev/kmsg
 * is writable by root only, so a session that has dropped privilege (the LIVE
 * image's `setuid 1001`, etc/rc.de-user's desktop users) opens it and fails,
 * the sink latches off for that process, and its output is on the screen and
 * the serial port but not in the log. The INSTALLED boot -- the one the owner
 * runs, etc/rc.boot.installed -- never drops privilege, so its rc, its
 * services and its desktop are all captured. */
/* THE DESCRIPTOR IS NOT KEPT, AND THAT IS A CORRECTNESS DECISION RATHER THAN A
 * STYLE ONE. MEASURED, this tree, the shipped medium booted as usb-storage:
 * with a cached fd, PID 1's console lines were mirrored up to
 * `rc.boot: hamnix-linux (installed)` and then STOPPED DEAD, while every line
 * from every CHILD process (dhcpc, wsyswl, hampanelscene) and every bootmsg
 * kept arriving for the rest of the boot. PID 1 is hamsh, and a shell OWNS its
 * descriptor table: it dups, it dup2s, and lib/p9.ad's p9_closefrom shuts
 * everything from 3 to 63 as a matter of contract. A long-lived descriptor
 * held behind the shell's back does not survive that, and -- far worse than
 * being closed -- the NUMBER can be handed to something else, at which point
 * this would be writing kernel log records into whatever file the shell put
 * there. There is no way to tell those two apart from in here.
 *
 * So it is opened, written and closed per record, which is exactly what
 * bootmsg above does and is the pattern that demonstrably kept working through
 * the whole of that same boot. Two extra syscalls per LINE of console output
 * (not per write) is not a cost worth a corruption risk. */
static char kmsglog_line[768];
static size_t kmsglog_n = 0;
/* Bounded, so a machine with no /dev/kmsg at all does not pay an open(2) on
 * every console line for ever. Any success resets it, so the early-boot window
 * before `bind '#c' /dev` -- when there is legitimately nothing to open --
 * cannot latch the sink off for the rest of the boot. */
static int kmsglog_fails = 0;
#define KMSGLOG_MAX_FAILS 64

static void kmsglog_flush(void)
{
    if (kmsglog_n == 0) return;
    size_t len = kmsglog_n;
    kmsglog_n = 0;                       /* drop the line whatever happens */
    if (kmsglog_fails >= KMSGLOG_MAX_FAILS) return;
    int fd = open("/dev/kmsg", O_WRONLY | O_CLOEXEC);
    if (fd < 0) { kmsglog_fails++; return; }
    kmsglog_fails = 0;
    char rec[832];
    int n = snprintf(rec, sizeof rec, "<7>cons: %.*s", (int)len, kmsglog_line);
    if (n > 0) {
        ssize_t ignored = write(fd, rec, (size_t)n);
        (void)ignored;
    }
    close(fd);
}

static void kmsglog_emit(const uint8_t *buf, uint64_t count)
{
    for (uint64_t i = 0; i < count; i++) {
        uint8_t c = buf[i];
        if (c == '\n') { kmsglog_flush(); continue; }
        /* A NUL or a control byte in a log record is what turns a text file
         * into something an editor refuses to show; the log is read by a
         * person on another computer. Tabs survive, everything else below
         * space becomes a space. */
        if (c < 0x20 && c != '\t') c = ' ';
        kmsglog_line[kmsglog_n++] = (char)c;
        if (kmsglog_n >= sizeof kmsglog_line - 1) kmsglog_flush();
    }
}

/* THE ONE PLACE A CONSOLE WRITE IS FANNED OUT, and it is one place on purpose.
 * The rdev test is the whole discipline and it is now performed ONCE for both
 * sinks: only fd 5:1, the console device itself, is copied anywhere. A
 * redirect to a file, a pipe, a terminal window's pty and a socket all have
 * other rdevs and are left alone, so `cmd > file` still puts its bytes in
 * exactly one place -- and, just as importantly, does not pour a multi-megabyte
 * `cat` into the kernel ring. */
static void consmirror(int fd, const uint8_t *buf, uint64_t count)
{
    if (count == 0) return;
    if (consmirror_fd == -2) consmirror_setup();
    if (consmirror_fd < 0 && kmsglog_fails >= KMSGLOG_MAX_FAILS) return;
    struct stat st;
    if (fstat(fd, &st) != 0) return;
    if (!S_ISCHR(st.st_mode) || st.st_rdev != makedev(5, 1)) return;
    if (consmirror_fd >= 0) {
        ssize_t ignored = write(consmirror_fd, buf, (size_t)count);
        (void)ignored;
    }
    kmsglog_emit(buf, count);
}

/* EVERY DIRECT CONSOLE WRITE IN THIS FILE GOES THROUGH HERE, AND A RED GATE IS
 * WHY. This file's own diagnostics -- the root scan, the bind failures, the
 * user-namespace refusals -- call write(2, ...) directly rather than sys_write,
 * so they never passed the mirror above. That was invisible while /dev/console
 * WAS the serial port. The moment /dev/console became the screen, every one of
 * them became screen-only, and tests/linux/install_from_usb.sh went 52/1 on
 * exactly the assertion that reads one of them off the serial port:
 * "boot 2: the root was not resolved to the NVMe", which greps for
 * `is /dev/nvme0n1p2` -- a line the guest had printed, to a place the gate
 * cannot see. One helper, so the next diagnostic added here cannot repeat it. */
static void cons_write(const void *buf, size_t n)
{
    if (n == 0) return;
    ssize_t w = write(2, buf, n);
    if (w > 0)
        consmirror(2, (const uint8_t *)buf, (uint64_t)w);
}

/* extern def sys_write(fd: int32, buf: Ptr[uint8], count: uint64) -> int64 */
int64_t sys_write(int32_t fd, const uint8_t *buf, uint64_t count)
{
    fdns_gate_release();
    struct devfile *v = devtab_find((int)fd);
    if (v) {
        if (v->note_pid > 0)
            return note_write(v->note_pid, buf, count);
        if (v->isreboot)
            return reboot_write(buf, count);
        if (v->isauth)
            return hamauth_write(&v->af, buf, count);
        if (v->isau)
            return hamaudio_write(&v->au, buf, count);
        if (v->issn)
            return hamsnarf_write(&v->sn, buf, count);
        if (v->isnet)
            return hamnet_write(&v->nf, buf, count);
        if (v->isw)
            return hamwsys_write(&v->w, buf, count);
        if (v->kind == HAMFB_FBCTL)
            return hamfb_ctl(buf, count);
        int64_t n = hamfb_write(v->cursor, buf, count);
        if (n > 0) v->cursor += (uint64_t)n;
        return n;
    }
    ssize_t w = write((int)fd, buf, (size_t)count);
    /* AFTER the real write, and only the bytes that really went out. The screen
     * is the channel a person is looking at; it must never wait on a serial
     * port that may have nothing at the other end of it. */
    if (w > 0 && (fd == 1 || fd == 2))
        consmirror((int)fd, buf, (uint64_t)w);
    return rc64(w);
}

/* extern def sys_close(fd: int32) -> int32 */
int32_t sys_close(int32_t fd)
{
    fdns_gate_release();
    struct devfile *v = devtab_find((int)fd);
    if (v) {
        if (v->isw)   hamwsys_close(&v->w);
        if (v->isnet) hamnet_close(&v->nf);
        if (v->isau)  hamaudio_close(&v->au);
        if (v->issn)  hamsnarf_close(&v->sn);
        if (v->isauth) explicit_bzero(&v->af, sizeof v->af);
        v->used = 0; v->isw = 0; v->isnet = 0; v->isauth = 0; v->isau = 0;
        v->issn = 0; v->isreboot = 0;
        return rc32(close((int)fd));
    }
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
    struct devfile *v = devtab_find((int)fd);
    if (v) {
        /* Seeking /dev/audio moves the CLIP cursor: a seek to 0 starts a new
         * staged sound, which is what lib/hamsdl_audio_dev.ad means by it. */
        if (v->isau)
            return hamaudio_seek(&v->au, off,
                                 whence == SEEK_CUR ? 1 :
                                 whence == SEEK_END ? 2 : 0);
        /* Seeking the clipboard moves the offset the device protocol is
         * addressed by -- a seek to 0 followed by a write is a REPLACE. */
        if (v->issn)
            return hamsnarf_seek(&v->sn, off,
                                 whence == SEEK_CUR ? 1 :
                                 whence == SEEK_END ? 2 : 0);
        if (v->isnet) {
            int64_t base = (whence == SEEK_CUR) ? (int64_t)v->nf.off
                         : (whence == SEEK_END) ? (int64_t)v->nf.snaplen : 0;
            int64_t want = base + off;
            if (want < 0) { errno = EINVAL; return -EINVAL; }
            v->nf.off = (uint64_t)want;
            return want;
        }
        if (v->isw) {
            /* A wsys read is a snapshot; seeking to 0 re-reads it. */
            int64_t base = (whence == SEEK_CUR) ? (int64_t)v->w.off
                         : (whence == SEEK_END) ? (int64_t)v->w.snaplen : 0;
            int64_t want = base + off;
            if (want < 0) { errno = EINVAL; return -EINVAL; }
            v->w.off = (uint64_t)want;
            return want;
        }
        /* Seeking the framebuffer moves the pixel cursor -- hamUId seeks to
         * place a band rather than always streaming from 0. */
        int64_t base = (whence == SEEK_CUR) ? (int64_t)v->cursor
                     : (whence == SEEK_END) ? (int64_t)hamfb_size() : 0;
        int64_t want = base + off;
        if (want < 0) { errno = EINVAL; return -EINVAL; }
        v->cursor = (uint64_t)want;
        return want;
    }
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

/* extern def sys_mkdir(path: Ptr[char]) -> int32
 *
 * ONE argument. The native primitive fixes the mode on-device, so the host
 * thunk supplies 0755 itself — exactly as the .S version does. Taking a `mode`
 * parameter here instead would read whatever the caller happened to leave in
 * %rsi: it produced directories with mode 0440, and `cp -r` then could not
 * write into the tree it had just created. */
int32_t sys_mkdir(const char *path)
{
    return rc32(mkdir(path, 0755));
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
/* Make `newfd` a second view of the synthetic device `oldfd` names.
 *
 * WHY THIS EXISTS.  A synthetic device is a devtab entry keyed by an fd, with
 * a real descriptor on /dev/null standing in so the slot is genuine.  dup2(2)
 * duplicates the /dev/null descriptor and NOTHING ELSE -- so after
 *
 *     fd = open("/dev/wsys/appmenu/launch"); dup2(fd, 1); write(1, ...)
 *
 * the write went to /dev/null and vanished.  That is exactly what a shell
 * redirection does, and it is how `echo /bin/x > /dev/wsys/appmenu/launch`
 * came to report success while the launch queue stayed empty.  Silent, and
 * success-shaped -- the same failure class as every other stub on this line.
 *
 * The snapshot is deep-copied so the two fds can be closed independently. */
static void devtab_clone(struct devfile *src, int newfd)
{
    struct devfile *slot = NULL;
    for (int i = 0; i < DEVTAB_MAX; i++)
        if (!devtab[i].used) { slot = &devtab[i]; break; }
    if (!slot) {
        devtab_full();
        return;                     /* table full: newfd stays a plain fd */
    }
    *slot = *src;
    slot->fd = newfd;
    devtab_index(slot);
    if (slot->isw && slot->w.snap) {
        slot->w.snap = malloc((size_t)slot->w.snaplen);
        if (slot->w.snap)
            memcpy(slot->w.snap, src->w.snap, (size_t)slot->w.snaplen);
        else
            slot->w.snaplen = 0;
    }
}

/* extern def sys_dup(fd: int32) -> int32 */
int32_t sys_dup(int32_t fd)
{
    int r = dup((int)fd);
    if (r < 0) return rc32(r);
    struct devfile *v = devtab_find((int)fd);
    if (v) devtab_clone(v, r);
    return (int32_t)r;
}

/* extern def sys_dup2(old: int32, new_: int32) -> int32 */
int32_t sys_dup2(int32_t oldfd, int32_t newfd)
{
    /* If newfd was itself a device view, it is about to be replaced. */
    struct devfile *old_view = devtab_find((int)newfd);
    if (old_view) {
        if (old_view->isw) hamwsys_close(&old_view->w);
        if (old_view->isau) hamaudio_close(&old_view->au);
        if (old_view->issn) hamsnarf_close(&old_view->sn);
        old_view->used = 0;
        old_view->isw = 0;
        old_view->isau = 0;
        old_view->issn = 0;
        old_view->isreboot = 0;
    }
    int r = dup2((int)oldfd, (int)newfd);
    if (r < 0) return rc32(r);
    struct devfile *v = devtab_find((int)oldfd);
    if (v) devtab_clone(v, (int)newfd);
    return (int32_t)r;
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

/* extern def sys_uname(buf: Ptr[uint8], cap: uint64) -> int64
 *
 * "<sysname> <machine> <release>\n" into `buf`, returning the length.
 *
 * user/uname.ad used to write a fixed "Hamnix x86_64 1.0" because, as its
 * header says, "the kernel doesn't expose a utsname-like struct, so there's
 * nothing variable to query".  On this line the kernel does, and the fixed
 * string is a false answer: it names a kernel that is not running.  Reporting
 * "Hamnix x86_64 6.12.85+deb13-amd64" is the truth about this machine -- the
 * userland IS Hamnix and the kernel underneath is that Linux. */
int64_t sys_uname(uint8_t *buf, uint64_t cap)
{
    struct utsname u;
    if (uname(&u) < 0)
        return rc64(-1);
    int n = snprintf((char *)buf, (size_t)cap, "Hamnix %s %s\n",
                     u.machine, u.release);
    if (n < 0) { errno = EIO; return -EIO; }
    if ((uint64_t)n >= cap) n = (int)cap - 1;
    return (int64_t)n;
}

/* extern def sys_stat_mode(path: Ptr[char]) -> int32
 *
 * The file's mode bits, or -errno. The counterpart to sys_chmod, and needed
 * for the same reason: a copy that does not carry the mode across produces a
 * file that is not what it copied. */
int32_t sys_stat_mode(const char *path)
{
    struct stat st;
    if (stat(path, &st) < 0)
        return rc32(-1);
    return (int32_t)(st.st_mode & 07777);
}

/* extern def sys_chmod(path: Ptr[char], mode: uint32) -> int32
 *
 * Needed because a package's files carry MODES and Linux enforces them.  On
 * Hamnix the omission never showed; here a freshly installed binary came out
 * 0644, execve refused it, the child exited 127 without a word, and the
 * command silently did nothing.  It was invisible for a while because a
 * package that OVERWRITES an existing binary inherits the old file's mode --
 * so upgrading `ls` worked and installing anything new did not. */
int32_t sys_chmod(const char *path, uint32_t mode)
{
    return rc32(chmod(path, (mode_t)mode));
}

/* extern def sys_chown(path: Ptr[char], uid: uint32, gid: uint32) -> int32
 *
 * The counterpart to sys_chmod, and it exists for the same reason: a copy
 * that does not carry the OWNER across is not a copy of a home directory.
 * MEASURED with debugfs on a freshly installed disk, before this existed:
 * every file under /home -- including /home/live, which IS the desktop of an
 * installed machine -- was uid 0 gid 0, because user/hlinstall.ad copies the
 * live root onto the target with the tree's own `cp` while running as root.
 * The session user (uid 1001) could read its home and could not write it. */
int32_t sys_chown(const char *path, uint32_t uid, uint32_t gid)
{
    return rc32(chown(path, (uid_t)uid, (gid_t)gid));
}

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
#define RFPROC   0x0001   /* create a process */
#define RFMEM    0x0002   /* share the address space */
#define RFFDG    0x0004   /* copy the fd group */
#define RFNAMEG  0x0008   /* copy (privatise) the namespace */
#define RFCNAMEG 0x0080   /* start with an EMPTY namespace */
#define RFNOWAIT 0x0100   /* detach: the parent never reaps this child */

/* Defined with the namespace verbs below: acquire CAP_SYS_ADMIN over our own
 * mounts by creating a user namespace we own. */
static int ns_privilege(void);

/* ------------------------------------------------------------------ *
 * RFNOWAIT, and the zombies it left
 *
 * lib/p9.ad's spawn_detached is the tree's fire-and-forget launcher -- the DE
 * chime, the panel's menu launches, the file manager's editor. Its contract
 * (lib/p9.ad:428) is that "RFNOWAIT severs the parent link at creation, so the
 * child is published as a DETACHED zombie on exit and the kernel's
 * reap_orphan_zombies() (run at every fork) reclaims it -- no wait4 needed."
 *
 * This port ignored the flag outright, so there was no reaper and no severed
 * link: every detached spawn left a permanent zombie under a parent that would
 * never wait for it. The idle census found `aplay` -- hamdesktop's boot chime,
 * exited in a second, still on the process table a minute later.
 *
 * The faithful port is the reaper, not a double fork. A double fork would sever
 * the link but reparent the grandchild onto PID 1, moving the same zombie onto
 * hamsh and losing the pid the caller is handed back. Instead the runtime
 * REMEMBERS which children were detached and waits on THOSE, and only those --
 * so no other child's exit status can ever be stolen from the code that is
 * waiting for it, which is the failure a blanket waitpid(-1) drain would risk.
 *
 * "Run at every fork" is ported literally, plus every idle park: a program like
 * hamdesktop fires one chime and may never spawn again, but it parks in
 * sys_waitfds constantly, so that is where its detached child is reclaimed.
 * ------------------------------------------------------------------ */
#define DETACHED_MAX 64                 /* the table's INITIAL size, now */
#define DETACHED_CEILING 65536          /* refuse to be a memory bug instead */
static pid_t  detached_fixed[DETACHED_MAX];
static pid_t *detached_pid = detached_fixed;
static int    detached_cap = DETACHED_MAX;
static int    detached_n;

/* Defined with the orphan reaper below; the detached table and the
 * own-children table describe the same children from two directions and each
 * has to tell the other when a status has been consumed. */
static void own_child_remember(pid_t p);
static void own_child_forget(pid_t p);
static void own_child_reset(void);
void reap_detached(void);

/* THIS FUNCTION'S COMMENT DISAGREED WITH ITS CODE, AND THEN I MEASURED BOTH
 * AND NEITHER WAS RIGHT.
 *
 * The comment said "Reap what we can and drop the oldest rather than growing
 * without bound"; the code said `detached_n = 0`, which reaps nothing and
 * drops all 64.  Every pid in the table at that moment became a permanent
 * zombie: the runtime had taken on the obligation to wait for them (that is
 * what RFNOWAIT means here) and then forgot the obligation existed.
 *
 * WHAT WAS ACTUALLY MEASURED, by tests/linux/init_orphan_reap.sh's arm D, one
 * process, 100 detached children, host, 2026-08-17:
 *
 *   100 children that exit IMMEDIATELY   0 stranded, old code AND new.
 *                                        The reap_detached() at the top of
 *                                        every sys_rfork drains the table
 *                                        faster than the loop fills it, so
 *                                        the overflow path is never taken.
 *   100 children ALIVE AT ONCE           old code: 64 stranded corpses.
 *                                        "reap, then drop the oldest": 36.
 *                                        growing the table: 0.
 *
 * So the inference in HANDOFF -- that this stranded the soak's zombie wrapper
 * shells -- is CONDITIONAL, and the condition is concurrency, not volume.  A
 * program that fires and forgets one chime never touches this path however
 * many times it does it.  A desktop holding 65+ detached children at once
 * does, on the 65th.
 *
 * And the comment's own policy is not good enough either.  "Drop the oldest"
 * still breaks the promise the runtime made when it accepted RFNOWAIT; it just
 * breaks it 36 times instead of 64.  The fear the comment encodes -- "growing
 * without bound" -- is misplaced, because the bound on this table is not the
 * number of detached spawns ever made, it is the number ALIVE AT ONCE:
 * reap_detached compacts it every time a child exits and at every fork and
 * every idle park.  A table that grows to peak concurrency is bounded by the
 * process's own behaviour.
 *
 * So it grows, to a CEILING that exists only so a runaway cannot turn a zombie
 * leak into a memory leak, and only past that ceiling (or on a failed
 * allocation) does it evict.  Eviction is counted, and the count is reported
 * by sys_detached_dropped(), because a silent broken promise is how this one
 * survived so long.
 *
 * "Oldest" is best-effort and worth saying: reap_detached() fills holes by
 * swapping the last entry down, so the array is not strictly FIFO.  Slot 0 is
 * the oldest surviving entry far more often than not. */
static unsigned long detached_dropped;

/* HAMNIX_DETACHED_FULL=clear restores the OLD overflow behaviour verbatim.
 * It exists for one arm of tests/linux/init_orphan_reap.sh and nothing else:
 * "the table used to strand its contents" was an inference read off the source
 * until that arm ran it and counted the corpses. Nothing in the tree sets it. */
static int detached_full_clears(void)
{
    static int v = -1;
    if (v < 0) {
        const char *s = getenv("HAMNIX_DETACHED_FULL");
        v = (s && !strcmp(s, "clear")) ? 1 : 0;
    }
    return v;
}

/* Double the table.  0 on success.  The first growth moves off the static
 * array, which is why the copy is unconditional. */
static int detached_grow(void)
{
    if (detached_cap >= DETACHED_CEILING) return -1;
    int ncap = detached_cap * 2;
    if (ncap > DETACHED_CEILING) ncap = DETACHED_CEILING;
    pid_t *n = (pid_t *)malloc((size_t)ncap * sizeof *n);
    if (!n) return -1;
    memcpy(n, detached_pid, (size_t)detached_n * sizeof *n);
    if (detached_pid != detached_fixed) free(detached_pid);
    detached_pid = n;
    detached_cap = ncap;
    return 0;
}

static void detached_remember(pid_t p)
{
    if (detached_n >= detached_cap && detached_full_clears()) {
        detached_n = 0;                         /* the old code, on demand */
        detached_pid[detached_n++] = p;
        return;
    }
    if (detached_n >= detached_cap)
        reap_detached();                        /* most of them have exited */
    if (detached_n >= detached_cap)
        detached_grow();                        /* they really are all alive */
    if (detached_n >= detached_cap) {
        /* Ceiling, or out of memory.  Only here is a promise broken, and it
         * is counted. */
        detached_dropped++;
        memmove(&detached_pid[0], &detached_pid[1],
                (size_t)(detached_cap - 1) * sizeof detached_pid[0]);
        detached_n = detached_cap - 1;
    }
    detached_pid[detached_n++] = p;
}

/* extern def sys_detached_dropped() -> int64 -- instrumentation only. */
int64_t sys_detached_dropped(void) { return (int64_t)detached_dropped; }

void reap_detached(void)
{
    for (int i = 0; i < detached_n; ) {
        int st;
        pid_t r;
        do {
            r = waitpid(detached_pid[i], &st, WNOHANG);
        } while (r < 0 && errno == EINTR);
        if (r == 0) { i++; continue; }          /* still running */
        own_child_forget(detached_pid[i]);
        detached_pid[i] = detached_pid[--detached_n];   /* gone, or not ours */
    }
}

/* ------------------------------------------------------------------ *
 * PID 1 IS hamsh, AND A SHELL IS NOT AN INIT.
 *
 * An init adopts every orphan on the machine.  If it never wait4s them their
 * corpses stay on the process table for ever: MEASURED here, 86 zombies after
 * fifteen minutes of a desktop soak, all of them scene applications whose
 * wrapper shell had been killed in the same sweep that killed them, so the
 * parent that would have waited died first and the child reparented to PID 1.
 *
 * THE DANGEROUS FIX IS THE OBVIOUS ONE.  `while (waitpid(-1, &st, WNOHANG) >
 * 0);` reaps orphans, and it also reaps THIS process's own children, throwing
 * away the exit status that hamsh's job control, sys_waitpid_jc and the
 * detached-handle path are each waiting to read.  A shell that reports "job 3
 * done" with no status, or a `detached` handle that can never learn whether
 * its program failed, is a worse bug than the zombies -- and it is silent.
 *
 * So this reaper never waits for a child it created.  The runtime remembers
 * every pid it forks (own_child_remember, below) and forgets it the instant
 * some wait path consumes its status.  An ADOPTED child is by construction one
 * this process never forked, so the set difference is exact.  Only pids in
 * that difference are waited for, and each by number -- never -1.
 *
 * WHEN IT RUNS.  Only in a process that actually adopts: PID 1, or a process
 * that has asked to be a child subreaper.  Everywhere else it returns on the
 * first line, so the ~40 ordinary programs on a running machine pay a
 * getpid(2).
 *
 * The subreaper case is not decoration.  It is what lets the gate run this
 * code AT HOST SCALE, against a /proc holding hundreds of processes, without a
 * pid namespace and without pretending to be init.  A gate that only ever runs
 * where the process table is tiny is a gate that will call a broken scan
 * green.
 *
 * THE COST.  The scan is not free, so it is not paid until waitid(2) says
 * there is at least one waitable child -- one syscall, WNOWAIT, which peeks
 * WITHOUT consuming, so the peek itself can never steal a status.  On an idle
 * machine that is the whole cost.
 *
 * FAIL-SAFE, NOT FAIL-OPEN.  If the own-children table ever overflows the
 * runtime can no longer tell its own children from adopted ones, so it stops
 * reaping entirely rather than risk eating a status.  Zombies are a leak; a
 * stolen status is a wrong answer.
 * ------------------------------------------------------------------ */
#define OWNCH_MAX 4096
static pid_t ownch[OWNCH_MAX];
static int   ownch_n;
static int   ownch_overflow;
static unsigned long orphans_reaped;

static void own_child_remember(pid_t p)
{
    if (p <= 0) return;
    if (ownch_n >= OWNCH_MAX) { ownch_overflow = 1; return; }
    ownch[ownch_n++] = p;
}

static void own_child_forget(pid_t p)
{
    for (int i = 0; i < ownch_n; i++)
        if (ownch[i] == p) { ownch[i] = ownch[--ownch_n]; return; }
}

static int own_child_known(pid_t p)
{
    for (int i = 0; i < ownch_n; i++)
        if (ownch[i] == p) return 1;
    return 0;
}

/* A fork's child inherits the parent's table, and none of those pids are ITS
 * children -- they are its siblings and its own ancestors' business.  Leaving
 * them in place would make a child that later becomes init refuse to reap
 * exactly the orphans it must. */
static void own_child_reset(void) { ownch_n = 0; ownch_overflow = 0; }

/* sys_rfork is not the only fork in this runtime -- user/linux-wsys.c forks a
 * read server and user/linux-audio.c forks an audio pump.  Those callers wait
 * for their own children, so they must be able to say so. */
void hamnix_own_child_remember(int32_t p) { own_child_remember((pid_t)p); }

/* extern def sys_orphans_reaped() -> int64 -- instrumentation only. */
int64_t sys_orphans_reaped(void) { return (int64_t)orphans_reaped; }

/* HAMNIX_ORPHAN_REAP EXISTS FOR THE NEGATIVE CONTROLS OF
 * tests/linux/init_orphan_reap.sh AND NOTHING ELSE.  Nothing in the tree sets
 * it; the default is the behaviour described above.
 *
 *   off      do not reap at all -- the arm that shows the corpse persisting
 *            without this code, i.e. that the gate's green is attributable.
 *   greedy   reap adopted AND own children alike -- the arm that shows the
 *            "must not steal a status somebody is waiting for" assertion is a
 *            real assertion, by making it fail on demand.
 *
 * The second one matters more than the first.  "It did not break job control"
 * is the kind of claim that is trivially true of a function that does nothing,
 * and there is no way to tell those apart except to run the version that does
 * break it and watch the gate go red. */
#define ORPHAN_MODE_ON     0
#define ORPHAN_MODE_OFF    1
#define ORPHAN_MODE_GREEDY 2
static int orphan_mode(void)
{
    static int m = -1;
    if (m < 0) {
        const char *s = getenv("HAMNIX_ORPHAN_REAP");
        m = ORPHAN_MODE_ON;
        if (s && !strcmp(s, "off"))    m = ORPHAN_MODE_OFF;
        if (s && !strcmp(s, "greedy")) m = ORPHAN_MODE_GREEDY;
    }
    return m;
}

/* 1 if this process adopts orphans: init, or a declared subreaper. */
static int adopts_orphans(void)
{
    if (getpid() == 1) return 1;
#ifdef PR_GET_CHILD_SUBREAPER
    int v = 0;
    if (prctl(PR_GET_CHILD_SUBREAPER, &v, 0, 0, 0) == 0 && v) return 1;
#endif
    return 0;
}

/* The state character of /proc/<pid>/stat, or 0 if it cannot be read.
 *
 * field 2 is comm IN PARENTHESES and may itself contain spaces and
 * parentheses, so the scan goes to the LAST ')' in the buffer.  Splitting on
 * whitespace misreads a process named ") (" -- and here that would mean
 * waiting on a process that is still running, which BLOCKS PID 1 for ever if
 * WNOHANG were ever dropped.  It is not dropped, but the parse is still the
 * part that has to be right. */
static char proc_state(pid_t pid, pid_t *ppid_out)
{
    char path[64];
    snprintf(path, sizeof path, "/proc/%ld/stat", (long)pid);
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return 0;
    char buf[512];
    ssize_t n = read(fd, buf, sizeof buf - 1);
    close(fd);
    if (n <= 0) return 0;
    buf[n] = '\0';
    char *rp = strrchr(buf, ')');
    if (!rp || rp[1] != ' ' || !rp[2]) return 0;
    char st = rp[2];
    if (ppid_out) {
        /* rp+2 is state; the next field is ppid. */
        char *p = rp + 3;
        while (*p == ' ') p++;
        *ppid_out = (pid_t)strtol(p, NULL, 10);
    }
    return st;
}

void reap_orphans(void)
{
    if (!adopts_orphans()) return;
    int mode = orphan_mode();
    if (mode == ORPHAN_MODE_OFF) return;
    if (ownch_overflow) return;                 /* cannot tell mine from theirs */

    /* WNOWAIT: peek without consuming.  Nothing waitable, nothing to do. */
    siginfo_t info;
    memset(&info, 0, sizeof info);
    if (waitid(P_ALL, 0, &info, WEXITED | WNOHANG | WNOWAIT) < 0) return;
    if (info.si_pid == 0) return;

    /* Something is waitable.  It may well be one of ours -- and if it is, it
     * sits at the head of the queue and would hide every orphan behind it, so
     * the peek is a TRIGGER and not the answer.  The answer comes from the
     * process table. */
    DIR *d = opendir("/proc");
    if (!d) return;
    pid_t self = getpid();
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (e->d_name[0] < '0' || e->d_name[0] > '9') continue;
        char *end = NULL;
        long v = strtol(e->d_name, &end, 10);
        if (!end || *end || v <= 0) continue;
        pid_t pid = (pid_t)v;
        if (pid == self) continue;
        pid_t ppid = 0;
        char st = proc_state(pid, &ppid);
        if (st != 'Z') continue;                /* only corpses are reaped */
        if (ppid != self) continue;             /* not mine to wait for */
        if (mode != ORPHAN_MODE_GREEDY && own_child_known(pid))
            continue;                           /* MINE -- somebody wants it */
        int status;
        pid_t r;
        do {
            r = waitpid(pid, &status, WNOHANG);
        } while (r < 0 && errno == EINTR);
        if (r > 0) { orphans_reaped++; own_child_forget(pid); }
    }
    closedir(d);
}

int32_t sys_rfork(int32_t flags)
{
    reap_detached();                            /* "run at every fork" */
    reap_orphans();                             /* and so is an init's */
    if (flags & RFMEM) {
        errno = ENOSYS;     /* that is sys_rfork_thread's job — HANDOFF §7.5 */
        return -ENOSYS;
    }

    /* RFNAMEG WITHOUT RFPROC privatises THIS task's namespace and does not
     * fork. user/nsrun.ad:72 calls it the Plan 9 invariant — "rfork BEFORE
     * mount" — and every namespace user in the tree follows it, so this is the
     * shape the port has to support rather than a corner case.
     *
     * unshare(CLONE_NEWNS) is the exact equivalent: subsequent mounts are
     * visible only to this process and its children. It needs CAP_SYS_ADMIN,
     * which PID 1 and its descendants have inside the VM. */
    if (!(flags & RFPROC)) {
        if (flags & (RFNAMEG | RFCNAMEG)) {
            if (unshare(CLONE_NEWNS) == 0)
                return 0;
            /* An rfork WITHOUT RFPROC is a program saying "privatise my
             * namespace, I am about to mount" -- user/nsrun.ad and
             * user/distrofs.ad both do exactly that. So take the capability
             * now rather than waiting for the mount: there is no ambiguity
             * about whether this caller wants it. (The RFPROC arm below stays
             * lazy, because that flag combination is on EVERY spawn in the
             * tree and most spawns never mount anything.) */
            if (errno == EPERM && ns_privilege())
                return 0;
            return rc32(-1);
        }
        return 0;                       /* nothing asked for */
    }

    /* Read the /fd table's clock while this process is still the only one
     * that could be writing to it on behalf of the child-to-be. See
     * fdns_after_fork_parent: it is what makes clearing the child's stale
     * names exact instead of a race with the child's own first binds. */
    fdns_before_fork();
    pid_t pid = fork();
    if (pid < 0)
        return rc32(-1);
    if (pid == 0 && (flags & (RFNAMEG | RFCNAMEG))) {
        /* The CHILD gets the private namespace. Doing it here rather than
         * before the fork is what makes the parent's namespace survive. */
        if (unshare(CLONE_NEWNS) == 0) {
            /* Plan 9's namespace copy is private by construction; Linux mount
             * propagation defaults to shared, which would leak our mounts back
             * to the parent and defeat the point. */
            mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL);
        } else if (errno == EPERM || errno == EINVAL) {
            /* No CAP_SYS_ADMIN. This used to _exit(127), which killed the
             * child outright -- so on an unprivileged account EVERY spawn
             * died, and the caller saw an exit status indistinguishable from
             * "command not found". Since RFNAMEG accompanies RFPROC|RFFDG on
             * essentially every spawn in this tree (lib/p9.ad's _spawn_flags
             * always sets all three), that made the whole userland
             * unrunnable outside root.
             *
             * Carry on, and say so once. The child is still a real child with
             * a private fd table; what it loses for now is mount isolation,
             * which only matters to a program that goes on to bind something
             * -- and a program that DOES bind gets the namespace at that
             * point, because sys_bind's ns_mount() acquires a user namespace
             * on the first EPERM. Deferring rather than escalating here is
             * deliberate: RFPROC|RFFDG|RFNAMEG is on every spawn in this tree
             * (lib/p9.ad's _spawn_flags), and `ls` has no use for a user
             * namespace. */
            static int said;
            if (!said) {
                said = 1;
                const char *m = "rfork: no private namespace yet "
                                "(needs CAP_SYS_ADMIN); one is created on the "
                                "first bind\n";
                cons_write(m, strlen(m));
            }
        } else {
            _exit(127);
        }
    }
    if (pid > 0) {
        /* REMEMBERED BEFORE ANYTHING ELSE CAN RUN. A pid this process created
         * is a pid whose status belongs to somebody here; the orphan reaper
         * reads this table to know what it must not touch. */
        own_child_remember(pid);
        /* Close the spawn gate: until the parent finishes binding, a child
         * that opens /fd/N must wait rather than fall back to what it
         * inherited. See user/linux-fdns.c. */
        fdns_after_fork_parent((int32_t)pid);
        /* RFNOWAIT: the caller has promised never to wait for this one, so
         * the runtime takes on the obligation. See RFNOWAIT above. */
        if (flags & RFNOWAIT)
            detached_remember(pid);
    }
    if (pid == 0) {
        /* The parent's children are not this process's children. */
        own_child_reset();
        detached_n = 0;
        /* The child inherits the parent's fifo KEEPER descriptors (see
         * user/linux-fdns.c). Holding them would keep every pipe slot alive
         * for as long as the child lives, so a child that is about to become
         * an independent process drops them. Its own opens are unaffected:
         * the PARENT's keeper is what stops them blocking. */
        fdns_after_fork_child();
    }
    return (int32_t)pid;
}

/* extern def sys_execve_env(path: Ptr[char], argv: Ptr[uint64],
 *                           envp: Ptr[uint64]) -> int32
 * Also listed as implemented by HANDOFF §4.1a, also a `return -1`. */
int32_t sys_execve_env(const char *path, char *const argv[],
                       char *const envp[])
{
    /* A NULL envp means INHERIT, and it used to mean EMPTY.
     *
     * sys_execve one screen up states the model in as many words -- "the
     * Hamnix form inherits the environment rather than taking an envp" -- and
     * lib/p9.ad's spawn() hands this function whatever its caller passed,
     * which for most callers is 0 because they have nothing to change. Passing
     * that 0 to execve(2) verbatim gave the child an EMPTY environment, so a
     * spawned program lost every HAM* variable that tells this line's runtime
     * where its shared state lives.
     *
     * MEASURED, and it is why user/httpd.ad could not serve one request here:
     * the master accepted a connection, spawned /bin/httpd_worker with
     * `execve(..., NULL)`, and the worker -- with no HAMNET in its
     * environment -- fell down user/linux-net.c's candidate list to a
     * DIFFERENT /net segment from its master's. It then looked up the
     * connection number it had been handed in a table that did not contain it
     * and answered the client nothing. Neither process said a word: the master
     * had accepted, the worker had started, and the two were simply in
     * different worlds.
     *
     * On the bare-metal lane the environment is not how anything finds /net,
     * so this could only ever have shown up here -- the same structural blind
     * spot that hid the accept defect. */
    extern char **environ;
    execve(path, argv, envp ? envp : environ);
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
 *
 * The fd-slot model: naming a CHILD's fd from the parent, before the child
 * runs. HANDOFF §7.1 called this the sharpest constraint on the whole port,
 * and it is — but it is not unanswerable. A pipe slot is a FIFO, which is the
 * one Linux object that IS a pipe reachable by name, and the binding itself
 * lives in shared memory. See user/linux-fdns.c for why the keeper descriptor
 * is not optional. */
int32_t sys_fdbind(int32_t pid, int32_t fdnum, int32_t kind, int32_t slot)
{ return rc32(fdns_fdbind(pid, fdnum, kind, slot)); }

/* extern def sys_fdslot_kind(pid: int32, fdnum: int32) -> int32
 * What is bound at that name, if anything. hamsh probes fd 0 with this to
 * decide whether to run its console getty-flush. */
int32_t sys_fdslot_kind(int32_t pid, int32_t fdnum)
{ return fdns_slot_kind(pid, fdnum); }

/* extern def sys_chan_dir_mode(fd: int32, mode: int32,
 *                              path: Ptr[char]) -> int32
 *
 * Flip an already-open directory fd into Dir-record mode: subsequent reads
 * return the COMPACT Dir-record stream rather than "NAME\n" lines. Returns 0
 * on success and -1 for any non-directory backing.
 *
 * WHY THIS IS NOT OPTIONAL, and why leaving it fail-closed was actively
 * dangerous. That 0/-1 answer is the tree's idiomatic "is this a directory?"
 * test — user/cp.ad:163 and user/tar.ad's path_is_dir are literally
 * `open(p); p9_chan_dir_mode(fd,1,p) == 0`. While this returned -1, every
 * directory looked like a regular file, and `cp -r src dst` did not fail: it
 * created `dst` as a PLAIN FILE containing the bytes of src's listing, and
 * exited 0. Measured, not hypothesised. Silent data loss with a success exit
 * status is the worst failure mode available, and it was made reachable by
 * the directory-read synthesis above — before that, cp failed loudly at the
 * read instead.
 *
 * So this both answers the predicate AND actually re-renders the stream, since
 * returning 0 without switching formats would just move the silent-wrong-answer
 * to `ls -l`, which reads Dir records straight after the flip.
 *
 * WIRE FORMAT — the compact Dir record documented at the top of lib/p9.ad.
 * This is a DIFFERENT layout from sys_stat_p9's 9P2000 record (lib/p9.ad:1095
 * warns about exactly this); here qid.type is at offset 2, not 8.
 *
 *   off  size  field                     off  size  field
 *     0    2   reclen (incl. prefix)      19    4   atime
 *     2    1   qid_type                   23    4   mtime
 *     3    4   qid_version                27    8   length
 *     7    8   qid_path                   35   2+n  name
 *    15    4   mode                      ...   2+n  uid, gid, muid
 */
#define P9_DIR_FIXED_HDR 35
#define P9_DIR_MIN_REC   43

/* Encode one entry into buf[cap]; returns bytes written, or 0 if it will not
 * fit (the caller then stops emitting, as the Hamnix encoder does). */
static size_t p9_dir_encode(uint8_t *buf, size_t cap, const char *name,
                            const struct stat *st)
{
    char uidbuf[24], gidbuf[24];
    snprintf(uidbuf, sizeof uidbuf, "%u", (unsigned)st->st_uid);
    snprintf(gidbuf, sizeof gidbuf, "%u", (unsigned)st->st_gid);

    size_t nlen = strlen(name), ulen = strlen(uidbuf), glen = strlen(gidbuf);
    size_t need = P9_DIR_FIXED_HDR + 2 + nlen + 2 + ulen + 2 + glen + 2 + ulen;
    if (need > cap || need > 0xFFFF)
        return 0;

    int isdir = S_ISDIR(st->st_mode);
    memset(buf, 0, P9_DIR_FIXED_HDR);
    p9_put16(buf, (uint16_t)need);
    buf[2] = isdir ? (uint8_t)P9_QTDIR : 0u;
    p9_put32(buf + 3,  (uint32_t)st->st_mtime);           /* qid_version */
    p9_put64(buf + 7,  (uint64_t)st->st_ino);             /* qid_path */
    p9_put32(buf + 15, (uint32_t)(st->st_mode & 0777u)
                       | (isdir ? P9_DMDIR : 0u));
    p9_put32(buf + 19, (uint32_t)st->st_atime);
    p9_put32(buf + 23, (uint32_t)st->st_mtime);
    p9_put64(buf + 27, (uint64_t)st->st_size);

    size_t off = P9_DIR_FIXED_HDR;
    off = p9_put_str(buf, off, cap, name);
    off = p9_put_str(buf, off, cap, uidbuf);
    off = p9_put_str(buf, off, cap, gidbuf);
    off = p9_put_str(buf, off, cap, uidbuf);              /* muid */
    return off;
}

int32_t sys_chan_dir_mode(int32_t fd, int32_t mode, const char *path)
{
    struct stat st;
    if (fstat((int)fd, &st) < 0)
        return -1;
    if (!S_ISDIR(st.st_mode)) {
        errno = ENOTDIR;
        return -1;                      /* the "not a directory" answer */
    }
    if (mode == 0)
        return 0;                       /* already the default "NAME\n" mode */

    struct dirstream *d = dirtab_find((int)fd);
    if (!d) {                           /* opened by some path other than
                                         * sys_open; adopt it now */
        if (dirtab_fill((int)fd) < 0)
            return -1;
        d = dirtab_find((int)fd);
        if (!d)
            return -1;
    }

    /* Re-render the already-captured names as Dir records. Each entry is
     * stat'd relative to `path`, which is what the caller passes precisely so
     * the per-entry stat can be done (see p9_chan_dir_mode's comment). */
    size_t cap = 4096, len = 0;
    uint8_t *rec = malloc(cap);
    if (!rec) {
        errno = ENOMEM;
        return -1;
    }

    const char *base = (path && *path) ? path : ".";
    for (size_t i = 0; i < d->len; ) {
        size_t j = i;
        while (j < d->len && d->text[j] != '\n')
            j++;
        size_t nlen = j - i;
        if (nlen == 0 || nlen > 255) { i = j + 1; continue; }

        char name[256];
        memcpy(name, d->text + i, nlen);
        name[nlen] = '\0';

        char full[4096];
        if ((size_t)snprintf(full, sizeof full, "%s/%s", base, name) >= sizeof full) {
            i = j + 1;
            continue;
        }
        struct stat es;
        if (lstat(full, &es) < 0) { i = j + 1; continue; }

        if (len + P9_DIR_MIN_REC + 512 > cap) {
            uint8_t *nb = realloc(rec, cap * 2);
            if (!nb) { free(rec); errno = ENOMEM; return -1; }
            rec = nb;
            cap *= 2;
        }
        size_t n = p9_dir_encode(rec + len, cap - len, name, &es);
        if (n == 0)
            break;                      /* would not fit; stop emitting */
        len += n;
        i = j + 1;
    }

    free(d->text);
    d->text = (char *)rec;
    d->len = len;
    d->off = 0;
    return 0;
}

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

/* extern def sys_get_jiffies() -> uint64
 *
 * The 100 Hz scheduler tick. The freestanding runtime reports a frozen 0
 * ("no kernel tick"), which links and appears to succeed — and is why every
 * jiffies-deadline loop in the tree spins forever. user/sleep.ad is the clearest
 * case: `while sys_get_jiffies() - start < target` can never advance, so
 * `sleep 1` hangs until it is killed. The same shape hangs watch, memhog,
 * nice_hi/nice_lo, wakelat and hamscreensaver.
 *
 * CLOCK_MONOTONIC in centiseconds reproduces the contract: monotonic, 100 per
 * second, unaffected by wall-clock changes. Callers compare deltas (sleep.ad's
 * comment says so explicitly, for overflow robustness), so the epoch is
 * irrelevant — only the rate matters. */
int64_t sys_get_jiffies(void)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) < 0)
        return 0;
    return (int64_t)ts.tv_sec * 100 + ts.tv_nsec / 10000000;
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
    fdns_gate_release();
    /* A shell that has forked every stage of a pipeline and is now going to
     * block until they finish must not still be holding their pipes open --
     * a keeper is a WRITER, so the last stage would never see EOF and the
     * wait would never return. See fdns_keeper_sweep(). */
    fdns_keeper_sweep(FDNS_KEEPER_WAIT_MS);
    int status;
    pid_t r;
    do {
        r = waitpid((pid_t)pid, &status, 0);
    } while (r < 0 && errno == EINTR);
    if (r < 0)
        return -1;
    own_child_forget(r);                /* status consumed; nobody else's now */
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
    /* EXITED and SIGNALLED are the two that CONSUME the status. STOPPED and
     * CONTINUED do not -- the child is still a child and still somebody's to
     * wait for -- so the table must not be cleared on those. */
    if (WIFEXITED(st)) {
        own_child_forget(r);
        if (status) *status = ((int64_t)WEXITSTATUS(st) << 8) | WAITJC_EXITED;
        return 1;
    }
    if (WIFSIGNALED(st)) {
        own_child_forget(r);
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
 * `flags` is the Hamnix flag word whose only defined bit is WNOHANG = 1.
 *
 * "STILL RUNNING" IS -EAGAIN, NOT 0. user/hamsh.ad:14349 states the contract
 * outright -- "the kernel returns -EAGAIN (-11) instead of yielding" -- and
 * every caller tests for exactly -11: hamtermscene's _reap_shell says
 * `if wr != -11: sh_alive = 0`. waitpid(2) reports a live child as 0, so
 * returning that verbatim told the terminal its shell had died the instant it
 * started. It closed the window, stopped pumping, and the keys the compositor
 * was correctly delivering went into a ring nobody read -- which looked for
 * all the world like broken input.
 *
 * Returns the reaped pid, -EAGAIN if the child is alive, -errno on error. */
int64_t sys_waitpid_nb_raw(int32_t pid, int64_t flags)
{
    fdns_gate_release();
    int st;
    int wflags = (flags & 1) ? WNOHANG : 0;
    pid_t r;
    do {
        r = waitpid((pid_t)pid, &st, wflags);
    } while (r < 0 && errno == EINTR);
    if (r < 0)
        return -(int64_t)errno;
    if (r == 0)
        return -EAGAIN;                 /* alive, nothing to reap */
    own_child_forget(r);
    return (int64_t)r;
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
    /* BECOME that user, not merely take their uid.
     *
     * setuid(2) alone leaves the group and the supplementary groups where
     * they were, so `setuid 1001` in an rc produced a session that reported
     * uid=1001(live) gid=0 -- root's group, and every root-group file still
     * writable. Measured, and it reads as a successful drop.
     *
     * In an rc script "setuid <n>" means "run as that person", so the whole
     * identity moves. Order is not optional: supplementary groups first, then
     * the gid, then the uid, because after the uid goes there is no privilege
     * left to change either of the others.
     *
     * The gid comes from the account database rather than being assumed equal
     * to the uid: they usually match on this system and a system where they
     * did not would silently put the session in the wrong group. */
    gid_t gid = (gid_t)uid;
    struct passwd *pw = getpwuid((uid_t)uid);
    if (pw) gid = pw->pw_gid;

    if (geteuid() == 0) {
        /* Drop what a privileged process can drop. A failure here is not
         * fatal on its own -- an unprivileged caller cannot do any of it and
         * setuid(2) below will refuse for the same reason -- but a partial
         * drop must never be reported as a whole one. */
        if (setgroups(0, NULL) < 0 && errno != EPERM)
            return rc32(-1);
        if (setgid(gid) < 0 && errno != EPERM)
            return rc32(-1);
    }
    return setuid((uid_t)uid) < 0 ? rc32(-1) : 0;
}

/* ------------------------------------------------------------------ *
 * The Wayland surface: AF_UNIX listen/accept, SCM_RIGHTS, and mmap of a
 * received descriptor.
 *
 * A Wayland compositor needs three things nothing else here needed: a
 * LISTENING AF_UNIX socket (sys_pipe and sys_socketpair are already-connected
 * pairs), fd passing in an ancillary message -- a client hands over its pixel
 * memory as a DESCRIPTOR and there is no other way to receive a wl_shm pool --
 * and mmap of what arrives.
 *
 * docs/wayland_passthrough_design.md calls exactly this trio the gating risk
 * for the whole Wayland plan, because on the NATIVE line sendmsg/recvmsg are
 * not even dispatched and there is no SCM_RIGHTS path anywhere: "Phase 1 is
 * blocked until we add SCM_RIGHTS fd passing".  On this line all three are
 * ordinary libc.  The thing that gates the native kernel is, here, forty
 * lines -- which is the single clearest case for the port paying its way.
 * ------------------------------------------------------------------ */

/* extern def sys_unix_listen(path: Ptr[char], backlog: int32) -> int32
 *
 * A bound, listening AF_UNIX stream socket at `path`. A stale socket file from
 * a compositor that did not exit cleanly is UNLINKED first: bind(2) fails with
 * EADDRINUSE on a leftover inode even when nothing is listening on it, and a
 * display server that refuses to start after a crash is worse than one that
 * takes the name back.
 *
 * SIGPIPE is disarmed here because this is the first call the server makes: a
 * Wayland client that exits while the server is mid-write is NORMAL (it is how
 * every client quits), and the default disposition kills the compositor. */
int32_t sys_unix_listen(const char *path, int32_t backlog)
{
    struct sockaddr_un sa;
    if (!path || strlen(path) >= sizeof sa.sun_path) {
        errno = EINVAL;
        return -1;
    }
    signal(SIGPIPE, SIG_IGN);
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    if (fd < 0)
        return -1;
    memset(&sa, 0, sizeof sa);
    sa.sun_family = AF_UNIX;
    strcpy(sa.sun_path, path);
    unlink(path);
    if (bind(fd, (struct sockaddr *)&sa, sizeof sa) < 0) {
        int e = errno; close(fd); errno = e; return -1;
    }
    if (listen(fd, backlog > 0 ? backlog : 8) < 0) {
        int e = errno; close(fd); errno = e; return -1;
    }
    return (int32_t)fd;
}

/* extern def sys_unix_accept(lfd: int32) -> int32
 *
 * Non-blocking accept: -1 when nobody is waiting, which the caller treats as
 * "no new client this tick" rather than an error. */
int32_t sys_unix_accept(int32_t lfd)
{
    int fd = accept4((int)lfd, NULL, NULL, SOCK_CLOEXEC);
    return fd < 0 ? -1 : (int32_t)fd;
}

/* extern def sys_unix_connect(path: Ptr[char]) -> int32
 *
 * The other end of sys_unix_listen: a CONNECTED AF_UNIX stream socket, for a
 * Hamnix program that has to speak somebody else's protocol to a server it did
 * not start.  user/xsnarfd.ad is the first: it connects to the Xwayland inside
 * a distribution namespace at /n/<name>/tmp/.X11-unix/X0 and speaks the X11
 * wire protocol, because there is no libX11 on this side of the boundary and
 * an X selection is owned by a client, not read out of a file.
 *
 * IT IS BLOCKING, unlike sys_unix_accept.  A connect(2) that has to be retried
 * is a server that is not up yet, and the caller's answer to that is to try
 * again in a second -- not to spin.  Once connected, the descriptor is an
 * ordinary fd: sys_read/sys_write pass it straight through, sys_read_nb polls
 * it (0 = nothing yet, -1 = the server went away) and sys_waitfds parks on it.
 *
 * SIGPIPE IS DISARMED for the same reason sys_unix_listen does it, with the
 * roles reversed: here it is the SERVER that can vanish mid-write -- an
 * Xwayland exits every time its distribution's X session ends -- and the
 * default disposition would kill the bridge instead of letting it notice and
 * reconnect. */
int32_t sys_unix_connect(const char *path)
{
    struct sockaddr_un sa;
    if (!path || strlen(path) >= sizeof sa.sun_path) {
        errno = EINVAL;
        return -1;
    }
    signal(SIGPIPE, SIG_IGN);
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0)
        return -1;
    memset(&sa, 0, sizeof sa);
    sa.sun_family = AF_UNIX;
    strcpy(sa.sun_path, path);
    while (connect(fd, (struct sockaddr *)&sa, sizeof sa) < 0) {
        if (errno == EINTR)
            continue;
        int e = errno;
        close(fd);
        errno = e;
        return -1;
    }
    return (int32_t)fd;
}

/* extern def sys_scm_recv(fd: int32, buf: Ptr[uint8], cap: uint64,
 *                         fds: Ptr[int32], maxfds: int32,
 *                         nfds: Ptr[int32]) -> int64
 *
 * One non-blocking recvmsg. Returns the byte count, 0 for "nothing right now",
 * or -1 when the peer has hung up (which is how the caller learns a client
 * exited). Any SCM_RIGHTS descriptors in the ancillary buffer are handed back
 * through `fds`, with the count in nfds[0].
 *
 * THE FDS AND THE BYTES MUST BE TAKEN TOGETHER. A Wayland client sends
 * wl_shm.create_pool and the pool's memfd in ONE sendmsg, and the kernel
 * delivers ancillary data with the first byte of the message it accompanied.
 * A reader that took bytes with read(2) and then went looking for the fd would
 * find it already discarded — so every read on a client socket goes through
 * here, whether or not an fd is expected. */
int64_t sys_scm_recv(int32_t fd, uint8_t *buf, uint64_t cap,
                     int32_t *fds, int32_t maxfds, int32_t *nfds)
{
    char cbuf[CMSG_SPACE(sizeof(int) * 16)];
    struct iovec iov;
    struct msghdr msg;

    if (nfds) *nfds = 0;
    if (maxfds > 16) maxfds = 16;

    iov.iov_base = buf;
    iov.iov_len  = (size_t)cap;
    memset(&msg, 0, sizeof msg);
    msg.msg_iov        = &iov;
    msg.msg_iovlen     = 1;
    msg.msg_control    = cbuf;
    msg.msg_controllen = sizeof cbuf;

    ssize_t n;
    do {
        n = recvmsg((int)fd, &msg, MSG_DONTWAIT | MSG_CMSG_CLOEXEC);
    } while (n < 0 && errno == EINTR);
    if (n < 0)
        return (errno == EAGAIN || errno == EWOULDBLOCK) ? 0 : -1;
    if (n == 0)
        return -1;                            /* orderly shutdown by the peer */

    int got = 0;
    for (struct cmsghdr *c = CMSG_FIRSTHDR(&msg); c; c = CMSG_NXTHDR(&msg, c)) {
        if (c->cmsg_level != SOL_SOCKET || c->cmsg_type != SCM_RIGHTS)
            continue;
        int k = (int)((c->cmsg_len - CMSG_LEN(0)) / sizeof(int));
        for (int i = 0; i < k; i++) {
            int rfd;
            memcpy(&rfd, CMSG_DATA(c) + i * sizeof(int), sizeof rfd);
            if (fds && got < maxfds)
                fds[got++] = (int32_t)rfd;
            else
                close(rfd);                   /* never leak an unclaimed fd */
        }
    }
    if (nfds) *nfds = (int32_t)got;
    return (int64_t)n;
}

/* extern def sys_scm_send(fd: int32, buf: Ptr[uint8], n: uint64,
 *                         passfd: int32) -> int64
 *
 * Blocking sendmsg, optionally carrying one descriptor (passfd < 0 sends
 * none). Blocking is deliberate: the alternative is a short write that
 * truncates an event mid-message, and half a Wayland event on the wire
 * desynchronises the client's parser permanently. */
int64_t sys_scm_send(int32_t fd, const uint8_t *buf, uint64_t n, int32_t passfd)
{
    char cbuf[CMSG_SPACE(sizeof(int))];
    struct iovec iov;
    struct msghdr msg;
    uint64_t done = 0;

    while (done < n) {
        iov.iov_base = (void *)(buf + done);
        iov.iov_len  = (size_t)(n - done);
        memset(&msg, 0, sizeof msg);
        msg.msg_iov    = &iov;
        msg.msg_iovlen = 1;
        if (passfd >= 0 && done == 0) {
            memset(cbuf, 0, sizeof cbuf);
            msg.msg_control    = cbuf;
            msg.msg_controllen = sizeof cbuf;
            struct cmsghdr *c = CMSG_FIRSTHDR(&msg);
            c->cmsg_level = SOL_SOCKET;
            c->cmsg_type  = SCM_RIGHTS;
            c->cmsg_len   = CMSG_LEN(sizeof(int));
            int v = (int)passfd;
            memcpy(CMSG_DATA(c), &v, sizeof v);
        }
        ssize_t k = sendmsg((int)fd, &msg, MSG_NOSIGNAL);
        if (k < 0) {
            if (errno == EINTR)
                continue;
            return -1;
        }
        done += (uint64_t)k;
    }
    return (int64_t)done;
}

/* extern def sys_mmap_shared(fd: int32, len: uint64) -> uint64
 *
 * MAP_SHARED read-only mapping of a client's shm pool, as an integer address
 * the Adder side casts to Ptr[uint8]. 0 on failure.
 *
 * READ-ONLY on purpose. A compositor never writes a client's buffer, and a
 * client is entitled to seal its pool against writes — asking for PROT_WRITE
 * on a sealed memfd fails the mmap outright and would lose the pixels for a
 * hardening measure that is none of our business. */
uint64_t sys_mmap_shared(int32_t fd, uint64_t len)
{
    if (len == 0)
        return 0;
    void *p = mmap(NULL, (size_t)len, PROT_READ, MAP_SHARED, (int)fd, 0);
    return p == MAP_FAILED ? 0 : (uint64_t)(uintptr_t)p;
}

/* extern def sys_munmap_at(addr: uint64, len: uint64) -> int32 */
int32_t sys_munmap_at(uint64_t addr, uint64_t len)
{
    if (!addr || !len)
        return 0;
    return munmap((void *)(uintptr_t)addr, (size_t)len) < 0 ? -1 : 0;
}

/* extern def sys_fd_size(fd: int32) -> int64
 *
 * The size of a passed shm pool. A client's create_pool carries a size, but a
 * later wl_shm_pool.resize does not re-send the fd, so the descriptor itself
 * is the authority on how much is safe to map. */
int64_t sys_fd_size(int32_t fd)
{
    struct stat st;
    if (fstat((int)fd, &st) < 0)
        return -1;
    return (int64_t)st.st_size;
}

/* extern def sys_memfd(name: Ptr[char], len: uint64) -> int32
 *
 * An anonymous shared file of `len` bytes, for the one thing the compositor
 * has to hand a client as a descriptor: the XKB keymap behind
 * wl_keyboard.keymap. */
int32_t sys_memfd(const char *name, uint64_t len)
{
    int fd = memfd_create(name ? name : "hamnix", MFD_CLOEXEC);
    if (fd < 0)
        return -1;
    if (len && ftruncate(fd, (off_t)len) < 0) {
        int e = errno; close(fd); errno = e; return -1;
    }
    return (int32_t)fd;
}

/* extern def sys_getenv(name: Ptr[char], buf: Ptr[uint8], cap: uint64) -> int64
 *
 * The length written, or -1 when the variable is unset — which the caller
 * must be able to tell apart from a variable set to the empty string. */
int64_t sys_getenv(const char *name, uint8_t *buf, uint64_t cap)
{
    const char *v = getenv(name);
    if (!v)
        return -1;
    uint64_t n = (uint64_t)strlen(v);
    if (cap == 0)
        return (int64_t)n;
    if (n > cap - 1)
        n = cap - 1;
    memcpy(buf, v, (size_t)n);
    buf[n] = 0;
    return (int64_t)n;
}

/* extern def sys_setuid_auth(authfd: int32) -> int32
 *
 * Become the user a VERIFIED /dev/auth fd names. The fd is the capability --
 * user/login.ad, user/su.ad and hamsh's `newshell hostowner` all write a
 * credential to it, read "ok", and then hand it here. None of them ever sees
 * a password hash, which is the point of putting the checker behind a device.
 *
 * This was a flat `return -1`, so all three programs built and could not
 * work: login could only ever answer "Login incorrect". */
int32_t sys_setuid_auth(int32_t authfd)
{
    struct devfile *v = devtab_find((int)authfd);
    if (!v || !v->isauth) {
        errno = EBADF;
        return -1;
    }
    return rc32(hamauth_become(&v->af));
}

/* extern def sys_waitfds(fds: Ptr[int32], nfds: uint64,
 *                        timeout_ms: int64) -> int64
 *
 * Multi-fd readiness wait — the GUI event loop's idle wait. Returns the
 * number of ready fds, 0 on timeout, -1 on error. poll(2) is the direct
 * equivalent; the caller only ever asks about readability.
 *
 * BUT A SYNTHETIC-DEVICE FD IS NOT A POLLABLE THING, and handing one to
 * poll(2) is why an idle desktop burned both CPUs.
 *
 * devtab_open backs every /dev/wsys, /net, /dev/fb, /dev/audio and /dev/snarf
 * open with a real descriptor on /dev/null -- a genuine fd table slot that
 * survives fork and cannot collide, with the actual state in the table beside
 * it. That is right for read/write/close and catastrophic for poll: /dev/null
 * is ALWAYS readable, so `poll` returned "ready" the instant it was called,
 * every time, for every caller.
 *
 * Every parking event loop on this system is therefore a busy spin, including
 * the two written specifically not to be: hamdesktop parks on its /event fd
 * with a 250 ms timeout, hampanelscene on up to four with 16 ms, both with
 * comments explaining that this is what keeps an idle desktop near 0% CPU.
 * Measured, they each held a core at 100% in state R with nothing on screen,
 * and the panel's own CPU widget reported it faithfully.
 *
 * So the fds are SORTED by what they actually are:
 *
 *   a /dev/wsys event ring — readiness is "the ring has bytes", and the sleep
 *     is a futex on an input generation counter in the shared segment, poked
 *     by whichever process writes a ring (THE PARK in user/linux-wsys.c). This
 *     is the faithful stand-in for devwsys's waitfds_notify: a keystroke wakes
 *     the park immediately, and an idle desktop performs no wakeups at all.
 *   a /net file — poll the REAL socket underneath it (hamnet_sockfd), which is
 *     what the caller meant. dhcpc waited on one of these and spun.
 *   an ordinary fd — poll(2), unchanged.
 *   any other synthetic device — a snapshot read, ready by definition. Counted
 *     ready without sleeping, which is what the old code did by accident and
 *     is the only reason that bug was survivable.
 *
 * nfds == 0 is a plain sleep, and stays one.
 *
 * A REGULAR FILE IS THE SAME TRAP AS /dev/null, ONE LAYER OUT, and it is why
 * this function grew a fourth class. poll(2) reports a regular file readable
 * ALWAYS -- POSIX says so, because a disk read cannot block -- whatever the
 * file offset is. Every offscreen gate in tests/linux runs the compositor with
 * HAMWSYSD_INPUT naming a plain file of evdev records that the driver appends
 * to, so the moment user/wsysd.ad started WAITING on its input fds instead of
 * ticking, poll would have answered "ready" on an exhausted file forever and
 * the compositor would have spun a core in every one of them -- and reported a
 * flattering latency while doing it, which is this project's signature bug.
 *
 * So a regular file is classified: READINESS is "the offset is behind the end
 * of the file" (the only thing the caller can mean -- there are unread bytes),
 * and the SLEEP is inotify IN_MODIFY on the file, which is a genuine wake and
 * not a cap-and-repoll. The watch is registered BEFORE the size is sampled, so
 * a write landing between the two is a pending inotify event and not a lost
 * wakeup. inotify already backs the clipboard park above; this is that
 * mechanism, applied to the other unpollable thing in the tree. */
#define WAITFDS_MAX 64

/* How many of these regular files have bytes the caller has not read yet. */
static int waitfds_reg_ready(const int *rfd, int nreg)
{
    int n = 0;
    for (int i = 0; i < nreg; i++) {
        struct stat st;
        if (fstat(rfd[i], &st) != 0) continue;
        off_t at = lseek(rfd[i], 0, SEEK_CUR);
        if (at >= 0 && at < st.st_size) n++;
    }
    return n;
}

/* THE WATCH IS KEPT ACROSS CALLS, AND THAT IS NOT AN OPTIMISATION.
 *
 * The first version of this created an inotify instance, added the watches,
 * polled, and closed it again on every single park. It was correct and it made
 * the compositor SLOWER than the fixed tick it was replacing: measured with a
 * clock_gettime either side of the poll, one sys_waitfds call took 16 ms of
 * poll and then 4 to 32 ms MORE, so wsysd's 16 ms loop ran at 20-48 ms and
 * input-to-pixel latency went from p50 8.9 ms to p50 9.9 / p95 21.4. The cost
 * is the TEARDOWN: destroying an fsnotify mark waits on an SRCU grace period,
 * and doing that 60 times a second pays it 60 times a second.
 *
 * So the instance and its watches live in the process and are rebuilt only
 * when the set of regular files being waited on actually changes. Identity is
 * (fd, st_dev, st_ino) and not the fd alone, because an fd number that has
 * been closed and reopened onto a different file must not keep the old file's
 * watch. The queue is drained BEFORE readiness is sampled: a write updates the
 * file's size before its IN_MODIFY event is queued, so anything the drain
 * throws away is either already visible to the size check below or still
 * pending afterwards -- there is no order in which a wakeup is lost. */
struct waitfds_reg { int fd; dev_t dev; ino_t ino; };
static int waitfds_ino = -1;
static struct waitfds_reg waitfds_watch[WAITFDS_MAX];
static int waitfds_nwatch = 0;

static void waitfds_ino_drain(void)
{
    char buf[512];
    while (read(waitfds_ino, buf, sizeof buf) > 0) { }
}

/* Point the cached inotify instance at exactly this set of files. Returns the
 * instance, or -1 when there is nothing to watch or inotify is unavailable. */
static int waitfds_ino_arm(const struct waitfds_reg *want, int n)
{
    if (n <= 0) return -1;
    int same = (waitfds_ino >= 0 && waitfds_nwatch == n);
    for (int i = 0; same && i < n; i++)
        if (waitfds_watch[i].fd != want[i].fd
            || waitfds_watch[i].dev != want[i].dev
            || waitfds_watch[i].ino != want[i].ino)
            same = 0;
    if (!same) {
        if (waitfds_ino >= 0) close(waitfds_ino);
        waitfds_nwatch = 0;
        waitfds_ino = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
        if (waitfds_ino < 0) return -1;
        for (int i = 0; i < n; i++) {
            char p[64];
            snprintf(p, sizeof p, "/proc/self/fd/%d", want[i].fd);
            if (inotify_add_watch(waitfds_ino, p, IN_MODIFY) < 0) continue;
            waitfds_watch[waitfds_nwatch++] = want[i];
        }
        if (waitfds_nwatch == 0) {
            close(waitfds_ino);
            waitfds_ino = -1;
            return -1;
        }
    }
    waitfds_ino_drain();
    return waitfds_ino;
}
int64_t sys_waitfds(const int32_t *fds, uint64_t nfds, int64_t timeout_ms)
{
    fdns_gate_release();
    /* The idle park is also where a detached child is reclaimed. hamdesktop
     * fires the boot chime once and may never spawn again, so "reap at every
     * fork" alone would leave that zombie forever. See RFNOWAIT above. */
    reap_detached();
    /* PID 1's rc parks here between heartbeats and does not fork for seconds
     * at a time, so "reap at every fork" alone would let an init's adopted
     * corpses pile up between launches. reap_orphans() costs one waitid(2)
     * when there is nothing to do. */
    reap_orphans();
    /* AND IT IS WHERE A WINDOW THAT HAS STOPPED DRAWING OFFERS ITS PIXELS.
     * Same argument, one layer up: an application that paints once and parks
     * makes no wsys call again, so the pixel hand-up driven from those calls
     * would never reach it and its window would be blank for ever under a
     * compositor that started or restarted afterwards.  hamimgscene is exactly
     * that program and it WAS blank.  See hamwsys_tick in user/linux-wsys.h. */
    hamwsys_tick();
    if (nfds > WAITFDS_MAX) {
        errno = EINVAL;
        return -1;
    }

    struct pollfd pfd[WAITFDS_MAX + 1];   /* + the inotify descriptor */
    nfds_t npoll = 0;
    struct devfile *ring[WAITFDS_MAX];
    int nring = 0;
    int always_ready = 0;
    int rfd[WAITFDS_MAX];                 /* ordinary fds that are plain files */
    struct waitfds_reg rid[WAITFDS_MAX];  /* ... and what file each one IS */
    int nreg = 0;
    int ino = -1, ino_slot = -1;

    for (uint64_t i = 0; i < nfds; i++) {
        struct devfile *v = devtab_find((int)fds[i]);
        if (v && v->isw && hamwsys_is_ring(&v->w)) {
            ring[nring++] = v;
        } else if (v && v->issn && hamsnarf_waitfd(&v->sn) >= 0) {
            /* A REAL PARK ON THE CLIPBOARD.  /dev/snarf.serial is backed by an
             * inotify descriptor that fires when somebody writes the segment,
             * so this is a genuine sleep and not the always-ready count below
             * -- the difference between user/xsnarfd.ad waking five times a
             * second for ever and waking when a human presses Ctrl+C.  The fd
             * IS the caller's fd here; there is no second descriptor. */
            pfd[npoll].fd = hamsnarf_waitfd(&v->sn);
            pfd[npoll].events = POLLIN;
            pfd[npoll].revents = 0;
            npoll++;
        } else if (v && v->isnet) {
            int s = hamnet_sockfd(&v->nf);
            if (s < 0) { always_ready++; continue; }
            pfd[npoll].fd = s;
            pfd[npoll].events = POLLIN;
            pfd[npoll].revents = 0;
            npoll++;
        } else if (v) {
            always_ready++;                    /* a snapshot device */
        } else {
            struct stat st;
            if (fstat((int)fds[i], &st) == 0 && S_ISREG(st.st_mode)) {
                rid[nreg].fd = (int)fds[i];    /* see the note above */
                rid[nreg].dev = st.st_dev;
                rid[nreg].ino = st.st_ino;
                rfd[nreg] = (int)fds[i];
                nreg++;
            } else {
                pfd[npoll].fd = fds[i];
                pfd[npoll].events = POLLIN;
                pfd[npoll].revents = 0;
                npoll++;
            }
        }
    }

    /* The watch is armed and its queue drained BEFORE any size is sampled: a
     * write that lands between the two must be a pending event, not a lost
     * wakeup. */
    if (nreg) {
        ino = waitfds_ino_arm(rid, nreg);
        if (ino >= 0) {
            ino_slot = (int)npoll;
            pfd[npoll].fd = ino;
            pfd[npoll].events = POLLIN;
            pfd[npoll].revents = 0;
            npoll++;
        }
    }

    /* ONE deadline loop for every case. Readiness is recomputed on every pass;
     * the SLEEP is a futex when a ring is in the set and a poll(2) when it is
     * not -- and poll over an empty set is exactly the plain timed sleep that
     * nfds == 0 asks for. Deadline arithmetic is done in milliseconds against
     * CLOCK_MONOTONIC so a wake that finds nothing ready does not restart the
     * caller's timeout — which would turn a 16 ms park into an unbounded one.
     * always_ready still short-circuits the sleep exactly as the old code did:
     * the first pass counts it and returns without waiting. */
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    int64_t start = (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
    int64_t rv;

    for (;;) {
        /* Read the generation BEFORE checking readiness: a ring written
         * between the check and the futex wait must bump it and be seen as a
         * mismatch, not slept through. */
        uint32_t seen = nring ? hamwsys_input_gen() : 0;

        int ready = always_ready + waitfds_reg_ready(rfd, nreg);
        for (int i = 0; i < nring; i++)
            if (hamwsys_ring_ready(&ring[i]->w)) ready++;

        int64_t left = -1;
        if (timeout_ms >= 0) {
            clock_gettime(CLOCK_MONOTONIC, &now);
            int64_t elapsed = (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000
                              - start;
            left = timeout_ms - elapsed;
            if (left < 0) left = 0;
        }

        if (nring == 0) {
            /* No ring: everything left is pollable (ordinary fds, sockets, the
             * clipboard's inotify, and now a regular file's inotify), so ONE
             * poll(2) does the whole wait -- no cap, and no separate probe
             * poll before it. THE COUNT OF POLLS IS THE IDLE COST: a park
             * costs about 136 us of CPU here and a syscall is a measurable
             * part of that, so the version of this loop that did a 0-timeout
             * poll, then the sleeping poll, then another 0-timeout poll on the
             * way out cost +0.36% of one core at idle against the plain
             * timed sleep it replaced (four interleaved 30 s rounds,
             * /proc/<pid>/stat). */
            int r = 0;
            int ms = ready ? 0 : (timeout_ms < 0 ? -1 : (int)left);
            if (npoll) {
                do { r = poll(pfd, npoll, ms); } while (r < 0 && errno == EINTR);
                if (r < 0) { rv = -1; goto out; }
                if (r > 0) {
                    /* The inotify descriptor is OURS and not one of the
                     * caller's fds: drain it and do not count it. What it
                     * means -- a watched file grew -- is answered by
                     * waitfds_reg_ready() against the offset, which is the
                     * question the caller actually asked. */
                    if (ino_slot >= 0 && pfd[ino_slot].revents) {
                        waitfds_ino_drain();
                        r--;
                    }
                    ready += r;
                }
            } else if (!ready && ms != 0) {
                /* Nothing to watch at all: poll over an empty set is the
                 * plain timed sleep nfds == 0 asks for, and stays one. */
                do { r = poll(pfd, 0, ms); } while (r < 0 && errno == EINTR);
                r = 0;
            }
            if (ready) { rv = (int64_t)ready; goto out; }
            if (timeout_ms >= 0 && (ms == 0 || left <= 0)) { rv = 0; goto out; }
            /* The sleep ran its course. A regular file is not in the poll set,
             * so ask it once more before calling the park empty -- and then
             * return rather than going round again: an fd that becomes ready
             * after poll(2) timed out is indistinguishable from one that
             * becomes ready just after this call returns. */
            if (timeout_ms >= 0) {
                rv = always_ready + waitfds_reg_ready(rfd, nreg);
                goto out;
            }
            continue;
        }

        if (npoll) {
            int r;
            do { r = poll(pfd, npoll, 0); } while (r < 0 && errno == EINTR);
            if (r > 0) {
                if (ino_slot >= 0 && pfd[ino_slot].revents) {
                    waitfds_ino_drain();
                    r--;
                }
                ready += r;
            }
        }
        if (ready) { rv = (int64_t)ready; goto out; }
        if (timeout_ms >= 0 && left <= 0) { rv = 0; goto out; }
        /* An ordinary fd mixed in with a ring cannot be futex-woken, so cap
         * the sleep and re-poll it. The cap keeps it correct rather than fast.
         *
         * "Mixing is rare (nothing in the tree does it today)" is what this
         * comment used to say, and that was wrong when it was written:
         * user/hamterm.ad line 498 calls lib/hamui.ad's hamui_wait with its
         * shell-stdout pipe as an `extra` fd, so an open DE terminal is
         * exactly this path -- two /dev/wsys rings plus one ordinary fd, a
         * 50 ms park. The cap turns that park into three (20 + 20 + 10), so
         * an idle terminal wakes ~60 times a second where it needs to wake
         * ~20.
         *
         * WHAT THAT COSTS, measured rather than argued, on this host:
         *
         *   the two arms of this loop, 20 s each, from /proc/self/stat
         *     cap at 20 ms   59.7 wakes/s   0.010 s cpu   0.050% of one core
         *     one poll       20.0 wakes/s   0.000 s cpu   0.000% of one core
         *   one wake (a futex_wait that times out + a 0 ms poll), 200000 of
         *   them back to back: 3.9 us, so the 40 extra wakes/s are
         *     0.016% of one core, for one program, while it is open.
         *
         * (`ps pcpu` cannot see any of this: it is a LIFETIME average, and it
         * has misreported this tree twice. /proc/<pid>/stat sampled either
         * side of a fixed wall interval is the measurement.)
         *
         * THE RECORDED FIX IS AN EVENTFD MIRRORING `inputgen`, so the rings
         * and the ordinary fds go into ONE poll(2) and the cap disappears.
         * It is the right fix and it is NOT done here, because the write side
         * of it belongs to the WAKER -- hamwsys_input_notify() in
         * user/linux-wsys.c, which bumps inputgen and FUTEX_WAKEs it -- and
         * that file is not this pass's to change.
         *
         * The substitute that fits entirely in this file is a reader-side
         * helper THREAD per process that futex-waits on inputgen and writes
         * an eventfd. Deliberately not done: it buys 0.016% of a core and
         * pays a permanent extra thread plus a hand-rolled wake protocol on
         * the KEYSTROKE path -- the path whose latency was the ~0.5 s echo
         * lag lib/hamui.ad's header is about, and the one
         * tests/linux/de_probe.sh types real keys through QEMU to guard. A
         * fifty-thousandth of a core is not worth putting a new race there. */
        if (npoll && (left < 0 || left > 20)) left = 20;
        hamwsys_input_wait(seen, left);
    }
out:
    /* The inotify instance is NOT closed here -- see waitfds_ino_arm: closing
     * it on every park is what made this whole path slower than the tick. */
    return rv;
}

/* extern def sys_openchan(path: Ptr[char], write: int32) -> int32
 *
 * Open a redirect target and return a HANDLE the shell can bind at a child's
 * /fd/N.  On Linux the handle is simply the descriptor: RFFDG copies the fd
 * table across the fork, so the number means the same thing in the child.
 *
 * THIS IS WHY EVERY REDIRECT SILENTLY DID NOTHING.  hamsh's _wire_redirects
 * calls sys_openchan and then `if fslot >= 0:` before binding -- so a
 * fail-closed -1 skipped the bind with no diagnostic anywhere, and
 * `ls > file` ran, exited 0, created nothing and printed to the console.  The
 * DE session's `wsysd > /var/log/wsysd.log &` was the visible symptom: a debug
 * beacon burying every other message on the serial line while the log file it
 * was supposedly going to sat empty.
 *
 * Modes are OPENCHAN_READ 0 / OPENCHAN_TRUNC 1 / OPENCHAN_APPEND 2.  The
 * CHAN_INLINE_TAG bit is deliberately NOT set: it distinguishes a device chan
 * from a tmpfs slot in the Hamnix kernel, and here both are just descriptors,
 * so the plain DEVFD_FILE bind is the right one for either. */
int32_t sys_openchan(const char *path, int32_t mode)
{
    /* Everything goes through the slot table, devices included: a device
     * target (`cmd > /dev/wsys/<wid>/keys`) is served by the synthetic-device
     * table and those descriptors are per-process, so the NAME is the only
     * thing that can cross to the child either way. */
    return rc32(fdns_openchan(path, mode));
}

/* extern def sys_pipechan() -> int32
 *
 * A pipe addressed by a SLOT id rather than by two fds, so the ends can be
 * handed to another process by name. mkfifo(3) is exactly that object, which
 * is why this stopped being unanswerable — see user/linux-fdns.c. The slot,
 * not an fd, is what crosses the process boundary. */
int32_t sys_pipechan(void)
{
    return rc32(fdns_pipechan());
}

/* ------------------------------------------------------------------ *
 * Kernel modules
 *
 * NEW ON THIS LINE, and unavoidable for the north star: on real hardware the
 * whole point of running on Linux is that drivers exist, and on a Debian kernel
 * essentially every driver is a module. Even in QEMU, /dev/dri/card0 does not
 * appear until virtio-gpu and its four dependencies are loaded — so nothing can
 * scan out until something can insmod.
 *
 * user/insmod.ad exists but cannot be used: it issues SYS_INIT_MODULE through a
 * hand-written asm_volatile block that encodes the OLD backend's %rbp frame
 * layout, and miscompiles under LLVM (one of the three such apps the Tier-1
 * sweep found). Rather than fix inline asm that should not be inline asm, this
 * is a normal entry point.
 * ------------------------------------------------------------------ */

/* extern def sys_delete_module(name: Ptr[char], flags: int32) -> int32
 *
 * Unload a module BY NAME.  user/rmmod.ad had kept the native backend's inline
 * assembly -- reloading arguments from -8(%rbp) and issuing a raw syscall --
 * which under the LLVM lane reads a frame that does not exist, so `rmmod`
 * segfaulted on every valid argument.  insmod and modprobe had the same
 * assembly removed; rmmod was missed. */
int32_t sys_delete_module(const char *name, int32_t flags)
{
    return rc32((int)syscall(SYS_delete_module, name, (int)flags));
}

/* extern def sys_init_module(path: Ptr[char], params: Ptr[char]) -> int32
 *
 * Load one already-decompressed .ko by path. finit_module reads the module
 * from the fd itself, so nothing has to be slurped into userland memory.
 * Returns 0, or -errno. EEXIST is reported as success: a module that is
 * already loaded is the state the caller wanted. */
int32_t sys_init_module(const char *path, const char *params)
{
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return -(int32_t)errno;
    long r = syscall(SYS_finit_module, fd, params ? params : "", 0);
    int e = errno;
    close(fd);
    if (r == 0)
        return 0;
    if (e == EEXIST)
        return 0;
    errno = e;
    return -(int32_t)e;
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
/* The `#X` device-server letters, from etc/rc.boot and the rc.d scripts. On
 * Hamnix the kernel posts each of these as a file server and `bind` splices it
 * into the process namespace. On Linux the ones that name a real kernel
 * filesystem become an actual mount(2); the ones that name a Hamnix file
 * server we have not written yet fail, loudly, by name.
 *
 * Keeping this mapping — rather than making bind a no-op — is what preserves
 * the Plan 9 shape of the boot: /etc/rc.boot still says `bind '#p' /proc` and
 * still means it.
 *
 * `#distro` is the Debian namespace. It is a bind mount of the Debian tree,
 * which is why Debian packages never touch the Hamnix filesystem. */
struct devsrv {
    const char *letter;   /* the #X name, matched exactly or as a prefix */
    const char *fstype;   /* kernel filesystem to mount, or NULL for a bind */
    const char *source;   /* bind source root, when fstype is NULL */
    int         prefixed; /* 1 if the form is #X/subpath */
    const char *unimpl;   /* non-NULL: not yet written; the reason */
};

/* HAMNIX_ROOT / HAMNIX_DISTRO let the subtree servers be relocated without a
 * rebuild; they default to the conventional install layout. */
static const char *envdef(const char *k, const char *d)
{
    const char *v = getenv(k);
    return (v && *v) ? v : d;
}

/* ------------------------------------------------------------------ *
 * NAMED DISTRIBUTION NAMESPACES  —  `#distro/<name>`
 *
 * `#distro` used to mean "the one distro disk", spelled /dev/vda. That is a
 * special case that happens to work, not a mechanism, and NORTH_STAR.md asks
 * for the mechanism: `enter debian { }` and `enter alpine { }` at once, and
 * `enter fedora { }` later with no code edit.
 *
 * THE SHAPE, and why this one.
 *
 *   * ONE device letter, PARAMETERISED, not one letter per distribution.
 *     `#distro/alpine` is a name with a component, exactly like `#r/home` and
 *     `#t/foo` already are. Adding `#alpine` to the table instead would mean a
 *     recompile per distribution, which is the opposite of what a namespace
 *     being DESCRIBED rather than compiled is for.
 *
 *   * THE MAP FROM NAME TO MEDIUM IS A FILE, `/etc/distros`. That is the Plan 9
 *     grain and it is also Hamnix's own precedent: the Hamnix kernel parses the
 *     rootfs partition's `.hamnix-roots` sentinel at boot and posts each NAMED
 *     subtree as a file server. There is no kernel doing that here, so bind
 *     reads the description itself — same idea, one less layer. Format:
 *
 *         # name    source
 *         default   LABEL=hamnix-debian
 *         debian    LABEL=hamnix-debian
 *         alpine    LABEL=hamnix-alpine
 *
 *     A source is a block-device path, a directory, or `LABEL=<fslabel>`.
 *
 *   * THE MEDIUM IS ADDRESSED BY LABEL, not by /dev/vdN. With two distro disks
 *     attached, which one is vda is a property of the ORDER QEMU was handed its
 *     -drive arguments, and getting it wrong does not fail — it mounts Alpine
 *     where Debian was asked for and everything downstream is confidently
 *     wrong. A label is a NAME, it travels with the filesystem, and it is what
 *     crosses the boundary here. `HAMNIX_DISTRO_<NAME>` overrides one entry and
 *     `HAMNIX_DISTRO` overrides the default, both without touching the file.
 *
 * `/n/<name>` is the mount-point convention: /n/debian, /n/alpine. /n/distro
 * stays bound as well, because user/xbridge.ad, the panel and a pile of tests
 * spell it that way and a name that worked should keep working.
 * ------------------------------------------------------------------ */

/* The ext4/ext3/ext2 volume label, read straight out of the superblock: magic
 * 0xEF53 at byte 1024+56, s_volume_name (16 bytes, NUL-padded) at 1024+120.
 * No libblkid, no udev, no /dev/disk/by-label — none of which exist on an
 * initramfs boot that has only what the Adder PID 1 bound. */
static int fs_label(const char *dev, char *out, size_t outn)
{
    unsigned char sb[1024];
    int fd = open(dev, O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return 0;
    ssize_t n = pread(fd, sb, sizeof sb, 1024);
    close(fd);
    if (n != (ssize_t)sizeof sb)
        return 0;
    if (!(sb[56] == 0x53 && sb[57] == 0xEF))
        return 0;
    size_t k = 0;
    while (k < 16 && sb[120 + k])
        k++;
    if (k == 0 || k >= outn)
        return 0;
    memcpy(out, sb + 120, k);
    out[k] = '\0';
    return 1;
}

/* Which block device carries the filesystem labelled `label`.
 *
 * /proc/partitions is the enumerator: it is already mounted (rc.boot binds
 * '#p' /proc before anything asks for a distro) and it lists exactly the
 * whole-disk and partition names the kernel knows. Partitions are checked too,
 * so a distro living on a partition of the installed disk resolves the same
 * way as one living on a whole virtio-blk volume. */
static const char *dev_by_label(const char *label, char *out, size_t outn)
{
    FILE *f = fopen("/proc/partitions", "r");
    if (!f)
        return NULL;
    char line[512], name[128], path[160], got[64];
    const char *hit = NULL;
    while (!hit && fgets(line, sizeof line, f)) {
        if (sscanf(line, " %*u %*u %*s %127s", name) != 1)
            continue;
        if (!strcmp(name, "name"))              /* the header row */
            continue;
        snprintf(path, sizeof path, "/dev/%s", name);
        if (fs_label(path, got, sizeof got) && !strcmp(got, label)) {
            snprintf(out, outn, "%s", path);
            hit = out;
        }
    }
    fclose(f);
    return hit;
}

/* A source spec -> a path bind can act on. `LABEL=x` is resolved here; anything
 * else is already a path. Returns NULL when a label names no attached
 * filesystem, which is a real answer and not a reason to guess. */
static const char *distro_source_spec(const char *spec, char *out, size_t outn)
{
    if (strncmp(spec, "LABEL=", 6) != 0) {
        snprintf(out, outn, "%s", spec);
        return out;
    }
    return dev_by_label(spec + 6, out, outn);
}

/* Is `path` the mount point of something? */
static int path_is_mountpoint(const char *path)
{
    FILE *f = fopen("/proc/self/mountinfo", "r");
    if (!f)
        return 0;
    char line[4096], mp[1024];
    int hit = 0;
    while (!hit && fgets(line, sizeof line, f)) {
        if (sscanf(line, "%*d %*d %*s %*s %1023s", mp) != 1)
            continue;
        if (!strcmp(mp, path))
            hit = 1;
    }
    fclose(f);
    return hit;
}

/* THE SERVER IS ALREADY POSTED AT ITS NAME.
 *
 * Reading a volume label means opening the block device, and a block device is
 * root:disk 0660 -- so an unprivileged process CANNOT resolve `LABEL=` at all.
 * That is not a bug to work around with permissions; it is the ordinary Plan 9
 * situation. The subtree server was posted at boot, by the boot, at a NAME:
 * etc/rc.boot.linux runs `bind '#distro/alpine' /n/alpine` while it is still
 * root. A session that later says `bind '#distro/alpine' /` is not asking to
 * find a disk, it is asking for the server at that name -- and the name is the
 * one thing that crosses the privilege boundary intact.
 *
 * Measured, tests/linux/two_namespaces.sh: without this, uid 0 entered both
 * namespaces and uid 1001 entered neither, with `no distribution namespace
 * named alpine' -- from a machine that had it mounted at /n/alpine.
 *
 * `/n/<name>` for a named distro, and `/n/distro` for the default, which is
 * where Debian has always been bound. Only a real mount point counts: an empty
 * directory called /n/alpine would otherwise be entered as a namespace whose
 * root has nothing in it, and `sh: not found` is a much worse answer than
 * "there is no such namespace". */
static const char *distro_mountpoint(const char *name, char *out, size_t outn)
{
    if (!strcmp(name, "default")) {
        snprintf(out, outn, "/n/distro");
        if (path_is_mountpoint(out))
            return out;
        return NULL;
    }
    snprintf(out, outn, "/n/%s", name);
    return path_is_mountpoint(out) ? out : NULL;
}

/* The `name source` table. Blank lines and `#` comments ignored. */
static int distro_table_lookup(const char *name, char *out, size_t outn)
{
    const char *tf = envdef("HAMNIX_DISTROS", "/etc/distros");
    FILE *f = fopen(tf, "r");
    if (!f)
        return 0;
    char line[512], n[128], s[256];
    int hit = 0;
    while (!hit && fgets(line, sizeof line, f)) {
        char *h = strchr(line, '#');
        if (h) *h = '\0';
        if (sscanf(line, "%127s %255s", n, s) != 2)
            continue;
        if (!strcmp(n, name)) {
            snprintf(out, outn, "%s", s);
            hit = 1;
        }
    }
    fclose(f);
    return hit;
}

/* Resolve `#distro/<name>` (or bare `#distro`) to the medium behind it.
 *
 * Order, most specific first: the per-name environment override, the
 * description file, and then — for the DEFAULT name only — /dev/vda, which is
 * what `#distro` meant before this file existed. An explicitly named distro
 * that resolves to nothing FAILS BY NAME; it does not fall back to the
 * default, because entering Debian when Alpine was asked for is precisely the
 * success-shaped wrong answer this tree keeps being bitten by. */
static const char *distro_resolve(const char *name, char *out, size_t outn)
{
    int is_default = (name == NULL || *name == '\0');
    char envkey[160], spec[256];
    const char *r;

    if (is_default) {
        const char *e = getenv("HAMNIX_DISTRO");
        if (e && *e && (r = distro_source_spec(e, out, outn)))
            return r;
        name = "default";
    } else {
        size_t k = 0;
        memcpy(envkey, "HAMNIX_DISTRO_", 14);
        k = 14;
        for (size_t i = 0; name[i] && k < sizeof envkey - 1; i++, k++)
            envkey[k] = (char)toupper((unsigned char)name[i]);
        envkey[k] = '\0';
        const char *e = getenv(envkey);
        if (e && *e && (r = distro_source_spec(e, out, outn)))
            return r;
    }

    if (distro_table_lookup(name, spec, sizeof spec)
        && (r = distro_source_spec(spec, out, outn)))
        return r;

    /* The medium could not be addressed -- which for anyone but root is the
     * NORMAL case, because reading a volume label means opening a block
     * device. Ask for the server by the name it was posted under. */
    if ((r = distro_mountpoint(name, out, outn)))
        return r;

    if (is_default) {
        /* The pre-/etc/distros world. Kept so an image built before this
         * change, or a test that stages its own rc and no table, still finds
         * the one disk it has always found -- and said out loud, once, because
         * a fallback nobody can see is how the next wrong mount happens. */
        static int said;
        if (!said) {
            said = 1;
            /* SAY WHICH OF THE THREE WAYS IT FAILED, because they are not the
             * same problem and the old text named the one that is almost never
             * true. It read "no `default` in /etc/distros", and on the live USB
             * medium there IS a `default` -- LABEL=hamnix-debian, right there
             * in the file. What actually happened is that no ATTACHED
             * FILESYSTEM CARRIES THAT LABEL, because the Debian medium is a
             * separate disk that a development host attaches and a USB stick
             * does not have. An operator reading the old line goes and looks at
             * a file that is correct. */
            const char *m =
                "bind: `#distro` did not resolve, so /dev/vda is being tried:\n"
                "      $HAMNIX_DISTRO is unset, /etc/distros' `default` names a\n"
                "      filesystem LABEL that no attached disk carries, and\n"
                "      nothing is mounted at /n/distro.\n";
            cons_write(m, strlen(m));
        }
        snprintf(out, outn, "/dev/vda");
        return out;
    }
    return NULL;
}

static const struct devsrv *devsrv_lookup(const char *src, const char **subpath)
{
    static struct devsrv tab[] = {
        { "#c",       "devtmpfs", NULL, 0, NULL },
        { "#p",       "proc",     NULL, 0, NULL },
        { "#t",       "tmpfs",    NULL, 1, NULL },
        { "#s",       "tmpfs",    NULL, 0, NULL },   /* the #s srv registry dir */
        /* NEW ON THIS LINE. Hamnix has no /sys — its kernel exposes hardware
         * through #b and friends. The Linux line needs sysfs for DRM/KMS, block
         * device enumeration and the input layer, so it gets a letter of its
         * own rather than being smuggled in behind #c. */
        { "#sys",     "sysfs",    NULL, 0, NULL },
        { "#pts",     "devpts",   NULL, 0, NULL },
        { "#/",       NULL,       "/",  0, NULL },   /* conventional /n parent */
        /* #d -> /fd needs no mount: user/linux-fdns.c serves the names. */
        { "#d",       NULL,       NULL, 0, NULL },
        { "#r",       NULL,       NULL, 1, NULL },   /* root partition subtree */
        { "#sysroot", NULL,       NULL, 0, NULL },
        /* `#esp` — the FAT32 EFI System Partition of the medium this machine
         * booted from, resolved by esp_device(). `bind '#esp' /boot` mounts
         * it; that is where the boot log goes, because FAT32 is the one
         * filesystem that opens on any computer he might carry the stick to. */
        { "#esp",     NULL,       NULL, 0, NULL },
        /* `#distro/<name>` — the distribution namespaces. PREFIXED, because
         * the component after the letter is WHICH ONE: `#distro/debian`,
         * `#distro/alpine`. Bare `#distro` is the default, which is what
         * every rc script and test wrote before there was more than one. */
        { "#distro",  NULL,       NULL, 1, NULL },
        /* #I -> /net needs no mount: user/linux-net.c serves the tree. */
        { "#I",       NULL,       NULL, 0, NULL },
        { "#b",       NULL, NULL, 0, "the /dev/blk file server is not written yet" },
        { "#w",       NULL, NULL, 0, "the /dev/win server is part of wsys (HANDOFF §4.4)" },
    };
    for (size_t i = 0; i < sizeof tab / sizeof tab[0]; i++) {
        size_t n = strlen(tab[i].letter);
        if (tab[i].prefixed) {
            if (!strncmp(src, tab[i].letter, n) &&
                (src[n] == '\0' || src[n] == '/')) {
                *subpath = src[n] == '/' ? src + n : "";
                return &tab[i];
            }
        } else if (!strcmp(src, tab[i].letter)) {
            *subpath = "";
            return &tab[i];
        }
    }
    return NULL;
}

/* ------------------------------------------------------------------ *
 * WHICH DEVICE HOLDS THE REAL ROOT, on a machine this image has never seen.
 *
 * `root=/dev/vda2` is a sentence about ONE machine. The virtio disk exists in
 * QEMU and nowhere else: the same install is /dev/sda2 off a USB stick and
 * /dev/nvme0n1p2 on a laptop, and which of those a given kernel picks depends
 * on probe order it does not promise to keep. A distribution image cannot name
 * a device node and be telling the truth on the next machine.
 *
 * So the root is named by something the INSTALLER WROTE ONTO THE DISK and that
 * travels with the partition: its GPT partition GUID (`root=PARTUUID=...`) or
 * the filesystem UUID inside its superblock (`root=UUID=...`).
 * scripts/hamlinux_disk.sh chooses the PARTUUID, passes it to sgdisk when it
 * creates partition 2, and bakes the SAME string into the unified kernel
 * image's command line; user/hlinstall.ad reads it off the install media and
 * gives the partition it creates that identity. Nothing here has to be told
 * what the disk is called.
 *
 * RESOLVING IT IS THIS FILE'S JOB, because on this line userspace mounts the
 * root -- the kernel's own name_to_dev_t never runs, since the initramfs never
 * hands the root over to it. The old comment here said LABEL=/UUID= "need a
 * device enumerator this line does not have". It has one now, and it is 80
 * lines: /sys/block lists the disks, each disk's subdirectories with a
 * `partition` file are its partitions, the GPT at LBA 1 of the disk carries
 * every partition's GUID, and an ext4 superblock at byte 1024 of the partition
 * carries the filesystem UUID. No udev, no blkid, no libblkid.
 *
 * AND WHEN IT FINDS NOTHING IT SAYS WHAT IT LOOKED AT. A boot that cannot find
 * its root prints the identifier it wanted and then every partition it did
 * see, with both identifiers of each -- on the console AND on /dev/kmsg, so
 * the message reaches a physical screen (see bootmsg). The alternative, and
 * what this used to do, was to fall back to "/" and mount the initramfs onto
 * itself, which reports "root filesystem online" and boots a system with none.
 */

/* Boot-time diagnostics that must survive having no serial port.
 *
 * PID 1's stderr goes to /dev/console, and /dev/console is the LAST console=
 * on the command line -- ttyS0 on this image, which a laptop does not display.
 * /dev/kmsg goes to printk, and printk goes to EVERY registered console:
 * the serial port, the framebuffer console, and the `earlycon=efifb` boot
 * console that is the only thing printing before fbcon exists. `level` is the
 * kmsg priority; 3 (KERN_ERR) is used for faults so they appear even at the
 * default loglevel=4, which suppresses anything less urgent.
 *
 * THE FIRST PARAGRAPH IS NOW HISTORY, AND THE LEVELS FOLLOW. The shipped
 * command line ends `console=tty0`, so the write to fd 2 reaches the
 * framebuffer by itself and the kmsg copy is no longer what rescues the
 * message -- it is a SECOND copy of it, on the same screen. Anything that
 * merely reports success is therefore emitted at <7>: kept in the kernel log
 * for a post-mortem, not printed at console_loglevel=7, and still on the
 * serial port every gate reads because linux-syscalls.c:consmirror copies
 * console writes there. Faults and warnings keep their printed levels. */
__attribute__((format(printf, 2, 3)))
static void bootmsg(int level, const char *fmt, ...)
{
    char buf[640];
    int pre = snprintf(buf, sizeof buf, "<%d>", level & 7);
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf + pre, sizeof buf - pre, fmt, ap);
    va_end(ap);
    if (n < 0) return;
    if (n > (int)(sizeof buf - pre) - 1) n = (int)(sizeof buf - pre) - 1;
    cons_write(buf + pre, (size_t)n);               /* no <N> on the console */
    int fd = open("/dev/kmsg", O_WRONLY | O_CLOEXEC);
    if (fd >= 0) {
        ssize_t kw = write(fd, buf, (size_t)(pre + n));
        (void)kw;
        close(fd);
    }
}

static uint16_t rd16(const unsigned char *p) { return (uint16_t)(p[0] | p[1] << 8); }
static uint32_t rd32(const unsigned char *p)
{
    return (uint32_t)p[0] | (uint32_t)p[1] << 8
         | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}
static uint64_t rd64(const unsigned char *p)
{
    return (uint64_t)rd32(p) | (uint64_t)rd32(p + 4) << 32;
}

static int read_at(const char *path, off_t off, void *buf, size_t n)
{
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    ssize_t r = pread(fd, buf, n, off);
    close(fd);
    return r == (ssize_t)n ? 0 : -1;
}

/* A GPT partition GUID is stored MIXED-ENDIAN -- the first three fields
 * little-endian, the last two as written -- and every tool that prints one
 * (sgdisk, blkid, the kernel's PARTUUID=) prints the byte-swapped form. Get
 * this wrong and the comparison never matches anything. */
static void guid_str(const unsigned char *g, char *out)
{
    sprintf(out, "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-"
                 "%02x%02x%02x%02x%02x%02x",
            g[3], g[2], g[1], g[0], g[5], g[4], g[7], g[6], g[8], g[9],
            g[10], g[11], g[12], g[13], g[14], g[15]);
}

/* A filesystem UUID is stored in printing order, unlike the above. */
static void fsuuid_str(const unsigned char *u, char *out)
{
    sprintf(out, "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-"
                 "%02x%02x%02x%02x%02x%02x",
            u[0], u[1], u[2], u[3], u[4], u[5], u[6], u[7], u[8], u[9],
            u[10], u[11], u[12], u[13], u[14], u[15]);
}

/* The ext4/ext3/ext2 superblock lives at byte 1024 of the partition; s_magic
 * (0xEF53) is at +0x38 and s_uuid at +0x68. Reading it needs no mount. */
static int part_fs_uuid(const char *dev, char *out)
{
    unsigned char sb[256];
    if (read_at(dev, 1024, sb, sizeof sb) < 0) return -1;
    if (rd16(sb + 0x38) != 0xEF53) return -1;
    fsuuid_str(sb + 0x68, out);
    return 0;
}

static unsigned disk_block_size(const char *disk)
{
    char path[256];
    snprintf(path, sizeof path, "/sys/block/%s/queue/logical_block_size", disk);
    FILE *f = fopen(path, "r");
    if (!f) return 512;
    unsigned v = 0;
    int got = fscanf(f, "%u", &v);
    fclose(f);
    /* 4Kn disks exist, and the GPT's LBA numbers are in the disk's own units;
     * assuming 512 there would read the partition array from the wrong offset. */
    return (got == 1 && v >= 512 && v <= 65536) ? v : 512;
}

/* One GPT partition entry of `disk` (e.g. "sda", 2), decoded into its two
 * GUIDs. `type_out` is the PARTITION TYPE GUID (bytes 0..15 of the entry --
 * what kind of partition this is: ESP, Linux filesystem, swap); `uniq_out` is
 * the PARTITION UNIQUE GUID (bytes 16..31 -- the identity of this one
 * partition, which is what `root=PARTUUID=` names). Either may be NULL.
 *
 * The two were never distinguished here because only the unique GUID was ever
 * wanted. Finding the EFI System Partition wants the other one: the ESP is not
 * identified by a name anybody chose, it is identified by carrying the type
 * GUID the UEFI specification reserves for it, which is the same on every disk
 * ever partitioned by anything. See esp_device(). */
static int part_gpt_entry(const char *disk, unsigned partn,
                          char *type_out, char *uniq_out)
{
    char dev[128];
    snprintf(dev, sizeof dev, "/dev/%s", disk);
    unsigned lbs = disk_block_size(disk);
    unsigned char hdr[96];
    if (read_at(dev, (off_t)lbs, hdr, sizeof hdr) < 0) return -1;
    if (memcmp(hdr, "EFI PART", 8) != 0) return -1;       /* MBR, or no table */
    uint64_t ents = rd64(hdr + 72);
    uint32_t nents = rd32(hdr + 80), esz = rd32(hdr + 84);
    if (partn < 1 || partn > nents || esz < 128 || esz > 4096) return -1;
    unsigned char e[128];
    if (read_at(dev, (off_t)ents * lbs + (off_t)(partn - 1) * esz, e, sizeof e) < 0)
        return -1;
    static const unsigned char zero[16] = { 0 };
    if (memcmp(e, zero, 16) == 0) return -1;              /* unused entry */
    if (type_out) guid_str(e, type_out);
    if (uniq_out) guid_str(e + 16, uniq_out);
    return 0;
}

/* The GPT partition GUID of partition `partn` of `disk` (e.g. "sda", 2). */
static int part_gpt_uuid(const char *disk, unsigned partn, char *out)
{
    return part_gpt_entry(disk, partn, NULL, out);
}

/* Walk every partition of every disk. `want` is "PARTUUID=x" or "UUID=x"; with
 * `report` set, each partition is also printed, which is what a failed boot
 * shows. Returns the number of partitions matched (searching) or seen
 * (reporting) -- the caller distinguishes "nothing matched" from "there are no
 * disks at all", which are different faults with different fixes. */
static int scan_partitions(const char *want_partuuid, const char *want_uuid,
                           char *out, size_t outn, int report)
{
    DIR *d = opendir("/sys/block");
    if (!d) {
        if (report)
            bootmsg(3, "sysroot: /sys/block is not readable (%s) -- is `bind "
                       "'#sys' /sys` done?\n", strerror(errno));
        return 0;
    }
    /* EVERY disk is walked even after a match, and that is deliberate. An
     * installed machine and the USB stick it was installed from carry the SAME
     * partition GUID -- user/hlinstall.ad gives the target the identity the
     * boot image it copies already names, because it cannot rewrite a PE
     * section -- so "two partitions answer to this name" is a real, reachable
     * state, and picking the first one silently is how a machine boots off the
     * stick still in its side and nobody can tell. */
    int hit = 0, seen = 0;
    struct dirent *de;
    while ((de = readdir(d))) {
        if (de->d_name[0] == '.') continue;
        char pdir[512];
        snprintf(pdir, sizeof pdir, "/sys/block/%s", de->d_name);
        DIR *pd = opendir(pdir);
        if (!pd) continue;
        struct dirent *pe;
        while ((pe = readdir(pd))) {
            if (pe->d_name[0] == '.') continue;
            char pnfile[1024];
            snprintf(pnfile, sizeof pnfile, "%s/%s/partition", pdir, pe->d_name);
            FILE *f = fopen(pnfile, "r");
            if (!f) continue;                    /* not a partition of this disk */
            unsigned pn = 0;
            int got = fscanf(f, "%u", &pn);
            fclose(f);
            if (got != 1) continue;
            char dev[128];
            snprintf(dev, sizeof dev, "/dev/%s", pe->d_name);
            char pu[40] = "", fu[40] = "";
            int have_pu = part_gpt_uuid(de->d_name, pn, pu) == 0;
            int have_fu = part_fs_uuid(dev, fu) == 0;
            seen++;
            if (report)
                bootmsg(3, "sysroot:   %-16s PARTUUID=%s UUID=%s\n", dev,
                        have_pu ? pu : "(no GPT entry)",
                        have_fu ? fu : "(no ext4 superblock)");
            int match = (want_partuuid && have_pu
                         && !strcasecmp(pu, want_partuuid))
                     || (want_uuid && have_fu && !strcasecmp(fu, want_uuid));
            if (match) {
                if (!hit)
                    snprintf(out, outn, "%s", dev);
                else
                    bootmsg(3, "sysroot: WARNING: %s answers to the same "
                               "identifier as %s. The FIRST one is being "
                               "mounted; if the wrong system comes up, that is "
                               "why -- unplug the other disk.\n", dev, out);
                hit++;
            }
        }
        closedir(pd);
    }
    closedir(d);
    return report ? seen : hit;
}

/* HAMNIX_ROOT if the operator set it; otherwise whatever the kernel command
 * line says, resolved. NULL means "the command line asked for a root and it
 * is not on this machine" -- a fault, and never mounted over with a guess. */
static const char *sysroot_device(void)
{
    static char dev[128];
    static int failed;
    const char *e = getenv("HAMNIX_ROOT");
    if (e && *e) return e;
    if (dev[0]) return dev;
    if (failed) return NULL;

    char spec[128] = "";
    int fd = open("/proc/cmdline", O_RDONLY);
    if (fd >= 0) {
        char line[1024];
        ssize_t n = read(fd, line, sizeof line - 1);
        close(fd);
        if (n > 0) {
            line[n] = '\0';
            char *p = strstr(line, "root=");
            if (p && (p == line || p[-1] == ' ')) {
                p += 5;
                size_t k = 0;
                while (p[k] && p[k] != ' ' && p[k] != '\n'
                       && k < sizeof spec - 1) {
                    spec[k] = p[k];
                    k++;
                }
                spec[k] = '\0';
            }
        }
    }

    /* No root= at all is an initramfs-only boot -- every developer boot -- and
     * "/" is the right answer for `#r`, which asks the same question. */
    if (!spec[0]) {
        snprintf(dev, sizeof dev, "/");
        return dev;
    }
    if (!strncmp(spec, "/dev/", 5)) {
        snprintf(dev, sizeof dev, "%s", spec);
        return dev;
    }

    const char *pu = NULL, *fu = NULL;
    if (!strncasecmp(spec, "PARTUUID=", 9)) pu = spec + 9;
    else if (!strncasecmp(spec, "UUID=", 5)) fu = spec + 5;
    if (pu || fu) {
        /* NOT THERE YET IS NOT THE SAME AS NOT THERE, and telling them apart
         * is the difference between booting the owner's USB stick and booting
         * a copy of it that lives in RAM.
         *
         * MEASURED, 2026-08-14, this image under OVMF with the disk attached
         * as `-device usb-storage` behind a qemu-xhci -- the configuration a
         * person is in when they boot a laptop off a stick:
         *
         *   1.336s  usbcore: registered new interface driver usb-storage
         *   1.567s  the root switch runs, /sys/block is EMPTY, and this
         *           function said "NO PARTITION ON THIS MACHINE MATCHES"
         *   1.900s  usb-storage 2-3:1.0: USB Mass Storage device detected
         *   2.931s  scsi 0:0:0:0: Direct-Access QEMU QEMU HARDDISK
         *   2.964s  sda: sda1 sda2      <- the root, 1.4s after we gave up
         *
         * init_module(2) RETURNS as soon as the driver has registered itself.
         * Everything after that -- the USB bus reset, the device descriptor
         * exchange, SCSI INQUIRY, READ CAPACITY, and only then the partition
         * scan -- happens on the kernel's workqueues, and on real hardware it
         * is SLOWER than QEMU, not faster: a USB 2 stick behind a hub, or a
         * disk that has to spin up, takes seconds. So a scan performed the
         * instant the modules are loaded asks the question before the machine
         * can possibly answer it, and gets "no disks at all" on a machine
         * whose disk is sitting right there.
         *
         * NVMe and AHCI enumerate the same way and merely happen to be fast;
         * they are not synchronous either, and this covers them too.
         *
         * So: poll. This is `rootwait`, which every Linux initramfs has had
         * for twenty years, and it is not a sleep -- a disk that is ready
         * immediately (virtio, NVMe: measured at the FIRST scan, 0ms waited)
         * costs nothing at all. Only the boot that would otherwise have failed
         * pays, and it pays with a message on the screen every two seconds
         * rather than with a blinking cursor. HAMNIX_ROOTWAIT=<seconds>
         * overrides the ceiling; 0 restores the old
         * one-look-and-give-up behaviour. */
        int deadline_ms = 20000;
        const char *rw = getenv("HAMNIX_ROOTWAIT");
        if (rw && *rw) {
            int v = atoi(rw);
            if (v >= 0) deadline_ms = v * 1000;
        }
        int waited_ms = 0;
        for (;;) {
            if (scan_partitions(pu, fu, dev, sizeof dev, 0)) {
                /* <7>, for the reason given on bootmsg: these two say the boot
                 * WENT RIGHT, the console they need to reach is now the one
                 * fd 2 already writes to, and at <6> each of them appeared on
                 * the screen twice. The <4> and <3> lines below stay printed:
                 * they are the ones a person must see on a boot that is going
                 * wrong, and one duplicate is cheaper than a missed warning. */
                if (waited_ms)
                    bootmsg(7, "sysroot: root=%s appeared after %d.%01ds\n",
                            spec, waited_ms / 1000, (waited_ms % 1000) / 100);
                bootmsg(7, "sysroot: root=%s is %s\n", spec, dev);
                return dev;
            }
            if (waited_ms >= deadline_ms) break;
            if (waited_ms == 0)
                bootmsg(4, "sysroot: root=%s is not here yet -- waiting up to "
                           "%ds. USB and SD media enumerate ASYNCHRONOUSLY, "
                           "seconds after their driver loads.\n",
                        spec, deadline_ms / 1000);
            else if (waited_ms % 2000 == 0)
                bootmsg(4, "sysroot: still waiting for the root disk (%ds of "
                           "%ds)\n", waited_ms / 1000, deadline_ms / 1000);
            struct timespec ts = { 0, 100 * 1000 * 1000 };   /* 100 ms */
            nanosleep(&ts, NULL);
            waited_ms += 100;
        }
        bootmsg(3, "sysroot: NO PARTITION ON THIS MACHINE MATCHES root=%s, "
                   "after waiting %ds.\n", spec, deadline_ms / 1000);
        bootmsg(3, "sysroot: every partition this kernel can see:\n");
        char ignored[128];
        if (!scan_partitions(NULL, NULL, ignored, sizeof ignored, 1))
            bootmsg(3, "sysroot:   (none at all -- no disk driver for this "
                       "machine's controller is loaded, or nothing is "
                       "attached)\n");
        /* What this DOES, not what it would be nice to claim: the bind fails.
         * PID 1 decides what to do about it, and says so in its own words. */
        bootmsg(3, "sysroot: the root switch fails rather than mounting a "
                   "guess.\n");
        failed = 1;
        return NULL;
    }
    bootmsg(3, "sysroot: root=%s names neither a /dev path, a PARTUUID= nor a "
               "UUID=; nothing here can resolve it.\n", spec);
    failed = 1;
    return NULL;
}

/* ------------------------------------------------------------------ *
 * `#esp` -- THE FAT PARTITION OF THE MEDIUM THIS MACHINE BOOTED FROM.
 *
 * WHY THERE IS A LETTER FOR THIS AT ALL. The owner boots a Lenovo off a USB
 * stick with no serial cable, no shell and no second machine attached. When a
 * boot goes wrong the only evidence that survives is a photograph of the last
 * forty lines of the screen. `#esp` is the other half of the answer: a place
 * on the stick ITSELF that the boot can write a log into, so that after a bad
 * boot he can power the machine off, plug the stick into any other computer,
 * and hand over a file instead of a photograph. user/bootlogd.ad is the writer
 * and its header is where the whole arrangement is argued.
 *
 * WHY FAT AND NOT THE ext4 ROOT. The ESP is FAT32, and FAT32 is the one
 * filesystem that mounts on Windows, on macOS and on Linux without installing
 * anything. The root partition is ext4, which his Debian host reads perfectly
 * well and which the machine he happens to be standing next to may not. A log
 * he cannot open is not evidence.
 *
 * IT IS FOUND BY TYPE GUID, ON THE DISK THAT HOLDS THE ROOT, and both halves
 * of that matter:
 *
 *   * BY TYPE GUID, because an ESP is not identified by a name anybody chose.
 *     C12A7328-F81F-11D2-BA4B-00A0C93EC93B is the partition type GUID the UEFI
 *     specification reserves for the EFI System Partition, and it is the same
 *     on every disk ever partitioned by anything. `/dev/sda1` is a sentence
 *     about one machine, in exactly the way the long note above sysroot_device
 *     says `root=/dev/vda2` was.
 *
 *   * ON THE DISK THAT HOLDS THE ROOT, and this is a SAFETY property, not a
 *     convenience. The machine may have other disks with other ESPs on them --
 *     the laptop's internal drive, with its own operating system's bootloader
 *     on it. Writing a log into THAT would be writing to somebody's else's
 *     disk, uninvited. The one device this boot is entitled to write to is the
 *     medium it was booted from, because booting it is what asked for the log;
 *     so the search is confined to the disk carrying the root partition the
 *     command line named, and a machine whose root was not resolved gets no
 *     ESP at all.
 *
 * A FAILURE HERE IS NOT A BOOT FAILURE. Every caller treats NULL as "no log on
 * this machine", says so on the console, and carries on. A logging facility
 * that can stop a boot is worse than no logging facility. */
#define ESP_TYPE_GUID "c12a7328-f81f-11d2-ba4b-00a0c93ec93b"

/* Which disk in /sys/block carries the partition node `part` (e.g.
 * "/dev/sda2" -> "sda"). Answered from sysfs rather than by chopping digits
 * off the name, because "nvme0n1p2" -> "nvme0n1" and "sda2" -> "sda" do not
 * obey the same rule and "mmcblk0p1" obeys a third. */
static int disk_holding(const char *part, char *out, size_t outn)
{
    const char *leaf = strrchr(part, '/');
    leaf = leaf ? leaf + 1 : part;
    DIR *d = opendir("/sys/block");
    if (!d) return -1;
    struct dirent *de;
    int found = -1;
    while (found < 0 && (de = readdir(d))) {
        if (de->d_name[0] == '.') continue;
        char pdir[512];
        snprintf(pdir, sizeof pdir, "/sys/block/%s/%s/partition",
                 de->d_name, leaf);
        if (access(pdir, R_OK) == 0) {
            snprintf(out, outn, "%s", de->d_name);
            found = 0;
        }
    }
    closedir(d);
    return found;
}

static const char *esp_device(void)
{
    static char dev[128];
    static int failed;
    if (dev[0]) return dev;
    if (failed) return NULL;

    /* HAMNIX_ESP overrides, for the same reason HAMNIX_ROOT does: a harness
     * that has already decided which device it means. */
    const char *e = getenv("HAMNIX_ESP");
    if (e && *e) { snprintf(dev, sizeof dev, "%s", e); return dev; }

    const char *root = sysroot_device();
    if (!root || !strcmp(root, "/")) {
        /* An initramfs-only boot (no root=) has no medium of its own that it
         * is entitled to write to. Say which of the two it is. */
        bootmsg(4, "esp: this boot has no resolved root partition, so there is "
                   "no medium it may write a boot log to.\n");
        failed = 1;
        return NULL;
    }

    char disk[64];
    if (disk_holding(root, disk, sizeof disk) < 0) {
        bootmsg(4, "esp: %s is not a partition of any disk /sys/block lists, "
                   "so the disk it lives on cannot be searched for an ESP.\n",
                root);
        failed = 1;
        return NULL;
    }

    char pdir[256];
    snprintf(pdir, sizeof pdir, "/sys/block/%s", disk);
    DIR *pd = opendir(pdir);
    if (!pd) {
        failed = 1;
        return NULL;
    }
    struct dirent *pe;
    int seen = 0;
    while ((pe = readdir(pd))) {
        if (pe->d_name[0] == '.') continue;
        char pnfile[1024];
        snprintf(pnfile, sizeof pnfile, "%s/%s/partition", pdir, pe->d_name);
        FILE *f = fopen(pnfile, "r");
        if (!f) continue;
        unsigned pn = 0;
        int got = fscanf(f, "%u", &pn);
        fclose(f);
        if (got != 1) continue;
        seen++;
        char type[40] = "";
        if (part_gpt_entry(disk, pn, type, NULL) != 0) continue;
        if (strcasecmp(type, ESP_TYPE_GUID) != 0) continue;
        snprintf(dev, sizeof dev, "/dev/%s", pe->d_name);
        closedir(pd);
        bootmsg(7, "esp: the boot medium's EFI System Partition is %s (on %s, "
                   "the disk carrying %s)\n", dev, disk, root);
        return dev;
    }
    closedir(pd);
    /* WHAT WAS LOOKED AT, not just that it failed -- the same discipline
     * scan_partitions applies when no root matches. */
    bootmsg(4, "esp: no EFI System Partition (type %s) among the %d partition(s) "
               "of %s, the disk carrying the root %s. This machine gets no "
               "on-medium boot log; everything else is unaffected.\n",
            ESP_TYPE_GUID, seen, disk, root);
    failed = 1;
    return NULL;
}

/* ------------------------------------------------------------------ *
 * Privilege for the namespace verbs, and the shape of the root switch
 *
 * MEASURED IN THE VM, 2026-08-10, because every line below turns on a number
 * the kernel would not tell you from the outside. `tests/linux/ns_probe.c` is
 * the probe; these are its answers on the live initramfs boot:
 *
 *   1. The root mount is `rootfs`, and it is UNATTACHED --
 *      `38 38 0:2 / / rw - rootfs rootfs rw` (mount id == parent id).
 *      pivot_root(2) refuses that: EINVAL, for root and unprivileged alike.
 *      So docs/steam_namespace.md §5's "the fix is pivot_root" is the right
 *      DIAGNOSIS and the wrong PRESCRIPTION -- it cannot be used here.
 *
 *   2. `mount(new, "/", MS_MOVE)` + `chroot(".")` -- which is what
 *      switch_root(8) does, and what every Linux initramfs has always done --
 *      works, and is EQUIVALENT for the purpose. The kernel's
 *      current_chrooted() walks down from the mount namespace's root dentry
 *      through whatever is mounted there and compares that with the process's
 *      root; moving the new root ONTO "/" makes those the same path, so the
 *      process is not chrooted even though it called chroot(2).
 *      Measured directly: after this sequence a child's unshare(CLONE_NEWUSER)
 *      returns OK; after a plain chroot(2) it returns EPERM.
 *      That is the whole of symptom 2 -- bubblewrap, pressure-vessel, Steam.
 *
 *   3. An unprivileged process CAN have CAP_SYS_ADMIN over its own mounts:
 *      unshare(CLONE_NEWUSER|CLONE_NEWNS) grants a full capability set in the
 *      new user namespace. Two traps, both measured:
 *        - /proc/self/uid_map opens EACCES after a setuid(2) drop, because
 *          commit_creds() clears the mm's dumpable flag and that reowns the
 *          process's own /proc files to root. prctl(PR_SET_DUMPABLE, 1) undoes
 *          it, and is a self-operation that always succeeds.
 *        - with NO map written the process is uid 65534 and NOTHING is mapped,
 *          so the nested CLONE_NEWUSER that bubblewrap needs fails EPERM
 *          anyway. The map is not optional.
 *      The mapping is the IDENTITY (`1001 1001 1`), not `1001 0 1`.
 *
 * WHY THE MAP IS THE IDENTITY, which is a security property and not a
 * preference. user/linux-wsys.c's uid gate (commit c9d010e6, the port of
 * devwsys.ad's current_task_is_hostowner) decides whether a caller may drive
 * the system chrome by comparing geteuid() with the OWNER OF THE /srv/wsys
 * SEGMENT. A user namespace changes both sides of that comparison, so the
 * mapping is what decides whether the gate keeps meaning anything:
 *
 *   1001 -> 0   would make geteuid() return 0 AND make the root-owned segment
 *               read back as owner 0. The gate would then conclude that the
 *               session IS the host owner and hand it the lock screen, the
 *               spawn queue and every other window's title. A confident wrong
 *               answer from a number that stopped meaning what it meant.
 *   1001 -> 1001 (this) leaves geteuid() at 1001, and the root-owned segment
 *               reads back as 65534 (uid 0 is not in the map), so the gate
 *               concludes "not the host owner" -- the same answer it gave
 *               before, and it fails CLOSED rather than open. Measured in the
 *               VM: `before-userns: geteuid=1001 st_uid=0` and
 *               `in-userns: geteuid=1001 st_uid=65534`; both refuse.
 *               It also keeps the harness arm working, where the segment
 *               belongs to 1001 itself: 1001 maps to 1001, so the owner is
 *               still recognised as the owner.
 *
 * There is NO conflict between that and what bubblewrap needs. bwrap does not
 * need to be uid 0 inside; it needs its own uid to BE MAPPED, so that the
 * nested CLONE_NEWUSER it performs has an owner the kernel can resolve.
 * Measured with the identity map, as uid 1001, inside the namespace:
 * `bwrap --unshare-user` builds a container.
 *
 * And the Hamnix /srv is not carried into a subtree namespace at all -- see
 * enter_root's `always[]` (/dev /proc /sys /n) versus `sysroot_only[]`
 * (/srv /tmp). Measured: `enter debian { ls -l /srv }` prints `total 0`, the
 * empty tmpfs the template's `bind '#s' /srv` just mounted. So inside
 * `enter debian` the gate's object does not exist; the case that matters is a
 * process that acquires a namespace WITHOUT entering a root, and that is the
 * one the paragraph above measures.
 * ------------------------------------------------------------------ */

/* Read /proc/self/mountinfo, calling `want` for each line's (major:minor,
 * mount root, mount point, filesystem type). Returns 1 as soon as `want`
 * accepts, having copied that line's mount point into `mp`.
 *
 * The paths are relative to the CALLER's root, which is what makes this usable
 * after the root switch: a /dev carried across shows up as /dev. */
static int mountinfo_scan(int (*want)(const char *dev, const char *root,
                                      const char *mp, const char *type,
                                      void *ctx),
                          void *ctx, char *mp_out, size_t mp_n)
{
    FILE *f = fopen("/proc/self/mountinfo", "r");
    if (!f)
        return 0;
    char line[4096];
    int hit = 0;
    while (!hit && fgets(line, sizeof line, f)) {
        char dev[64], root[1024], mp[1024], type[128];
        /* fields: id parent major:minor root mountpoint opts... - type src */
        if (sscanf(line, "%*d %*d %63s %1023s %1023s", dev, root, mp) != 3)
            continue;
        const char *sep = strstr(line, " - ");
        if (!sep || sscanf(sep + 3, "%127s", type) != 1)
            continue;
        if (want(dev, root, mp, type, ctx)) {
            snprintf(mp_out, mp_n, "%s", mp);
            hit = 1;
        }
    }
    fclose(f);
    return hit;
}

struct devmatch { unsigned maj, min; };

static int want_dev(const char *dev, const char *root, const char *mp,
                    const char *type, void *ctx)
{
    (void)mp; (void)type;
    struct devmatch *m = ctx;
    unsigned a, b;
    /* root must be "/": a bind of a SUBTREE of the filesystem is not the
     * filesystem, and handing one back would silently enter the wrong tree. */
    return strcmp(root, "/") == 0 && sscanf(dev, "%u:%u", &a, &b) == 2
           && a == m->maj && b == m->min;
}

/* Where, if anywhere, this block device is already mounted whole.
 *
 * `bind '#distro' /` used to mount /dev/vda a SECOND time, on top of the one
 * etc/rc.boot already made at /n/distro. Two mounts of one ext4 is a bad idea
 * on its own, and it is impossible for the session user: mounting a real
 * filesystem needs CAP_SYS_ADMIN in the INITIAL user namespace, which nothing
 * short of real root has. Binding the mount that already exists needs only
 * CAP_SYS_ADMIN over our own mounts, which is exactly what a user namespace
 * gives us -- and it is the same filesystem, not a substitute for it. */
static const char *blk_already_mounted(const char *devpath, char *out,
                                       size_t outn)
{
    struct stat sb;
    if (stat(devpath, &sb) != 0 || !S_ISBLK(sb.st_mode))
        return NULL;
    struct devmatch m = { major(sb.st_rdev), minor(sb.st_rdev) };
    return mountinfo_scan(want_dev, &m, out, outn) ? out : NULL;
}

struct typematch { const char *mp; const char *type; };

static int want_type(const char *dev, const char *root, const char *mp,
                     const char *type, void *ctx)
{
    (void)dev; (void)root;
    struct typematch *t = ctx;
    return strcmp(mp, t->mp) == 0 && strcmp(type, t->type) == 0;
}

/* Is `dst` ALREADY a mount of `fstype`? EBUSY is the kernel saying so and
 * sys_bind has always treated it as success; inside a user namespace the
 * kernel says EPERM instead -- devtmpfs and (sometimes) proc cannot be mounted
 * there at all -- and the question "is the server already at that name?" has
 * the same answer and deserves the same one. This checks rather than assumes:
 * if the name is NOT already that filesystem, the bind still fails. */
static int already_mounted_type(const char *dst, const char *fstype)
{
    struct typematch t = { dst, fstype };
    char mp[1024];
    return mountinfo_scan(want_type, &t, mp, sizeof mp);
}

/* Acquire CAP_SYS_ADMIN over our own mounts by creating a user namespace we
 * own. Once per process; returns 1 if we have it, 0 if we could not get it.
 *
 * This is deliberately LAZY -- called only when a mount has already failed
 * EPERM -- so that an ordinary spawn from an unprivileged shell does not get a
 * user namespace it has no use for. The processes that pay for one are exactly
 * the processes that bind. */
static int ns_privilege(void)
{
    static int state;                   /* 0 unknown, 1 have it, -1 refused */
    if (state)
        return state > 0;
    state = -1;

    if (getenv("HAMNIX_NO_USERNS"))     /* an operator's bisect handle */
        return 0;

    /* NEVER for root, even if a mount somehow returned EPERM. Two reasons and
     * both matter. Real root does not need this -- its mounts succeed -- so
     * reaching here at all would mean something else was wrong. And
     * user/linux-wsys.c's uid gate decides "is this caller the host owner?" by
     * comparing geteuid() with the owner of the /srv/wsys segment; a root
     * process that entered a user namespace would still compare 0 against 0
     * and pass the gate while having lost its real capabilities. Refusing
     * keeps the gate's two inputs meaning what they meant. */
    if (geteuid() == 0)
        return 0;

    /* See trap (a) above: without this the map files are root's, not ours. */
    prctl(PR_SET_DUMPABLE, 1, 0, 0, 0);

    uid_t u = getuid();
    gid_t g = getgid();
    if (unshare(CLONE_NEWUSER | CLONE_NEWNS) < 0)
        return 0;

    char buf[64];
    int fd = open("/proc/self/setgroups", O_WRONLY);
    if (fd >= 0) {
        ssize_t w = write(fd, "deny", 4);   /* required before gid_map */
        (void)w;
        close(fd);
    }
    int mapped = 0;
    snprintf(buf, sizeof buf, "%u %u 1\n", (unsigned)u, (unsigned)u);
    if ((fd = open("/proc/self/uid_map", O_WRONLY)) >= 0) {
        mapped = write(fd, buf, strlen(buf)) > 0;
        close(fd);
    }
    snprintf(buf, sizeof buf, "%u %u 1\n", (unsigned)g, (unsigned)g);
    if ((fd = open("/proc/self/gid_map", O_WRONLY)) >= 0) {
        ssize_t w = write(fd, buf, strlen(buf));
        (void)w;
        close(fd);
    }
    if (!mapped) {
        /* An unmapped process is uid 65534 and can create no further user
         * namespaces, so bubblewrap inside would fail with the message that
         * sent docs/steam_namespace.md §5 after the wrong sysctl. Say so by
         * name rather than carrying on in a namespace that half-works. */
        const char *m = "bind: user namespace created but uid_map could not be "
                        "written; the namespace would be unusable\n";
        cons_write(m, strlen(m));
        return 0;
    }
    /* Plan 9's namespace copy is private by construction. */
    mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL);
    state = 1;
    return 1;
}

/* mount(2), with one retry after acquiring privilege. Every mount sys_bind
 * performs goes through here, so "the session user cannot mount" is answered
 * in one place instead of at five call sites. */
static int ns_mount(const char *src, const char *dst, const char *type,
                    unsigned long flags, const void *data)
{
    if (mount(src, dst, type, flags, data) == 0)
        return 0;
    if (errno != EPERM)
        return -1;
    int saved = errno;
    if (!ns_privilege()) {
        errno = saved;
        return -1;
    }
    return mount(src, dst, type, flags, data);
}

/* Where to assemble a new root before switching onto it.
 *
 * /n/.root is the tree's own name for it and stays the answer for root. The
 * session user cannot create it -- /n is the system's, mode 0755 -- and a
 * user namespace does not help, because CAP_DAC_OVERRIDE only applies to
 * files whose owner is mapped into it, and uid 0 is not. So fall back to a
 * private directory in /tmp, which is the 1777 tmpfs `bind '#t' /tmp` put
 * there. The directory is left behind in a mount namespace that dies with the
 * process, so there is nothing to clean up. */
static const char *root_stage_dir(char *out, size_t outn)
{
    mkdir("/n", 0755);
    if (mkdir("/n/.root", 0755) == 0 || errno == EEXIST) {
        snprintf(out, outn, "/n/.root");
        return out;
    }
    const char *tmp = envdef("TMPDIR", "/tmp");
    snprintf(out, outn, "%s/.hamns-%d", tmp, (int)getpid());
    if (mkdir(out, 0700) == 0 || errno == EEXIST)
        return out;
    return NULL;
}

/* Make `mnt` the process's root. chroot alone leaves the old root reachable
 * through the cwd, so chdir first — that is the difference between confinement
 * and a suggestion. */
/* `is_sysroot` distinguishes the two things that both spell `bind X /`.
 *
 * THE ROOT SWITCH (#sysroot).  Everything before it ran out of the initramfs,
 * where /proc, /dev, /sys, /srv and /tmp were bound by the Adder PID 1;
 * chrooting without them would leave the new root with no console, no
 * /dev/fb and no shared segments -- the desktop would come up mute and blind.
 * MS_MOVE relocates the existing mounts rather than mounting them again, so
 * there is exactly one devtmpfs and the /srv segments are the SAME objects the
 * running processes already have mapped.
 *
 * ENTERING A SUBTREE (#distro).  A Debian program still needs /dev and /proc,
 * but /tmp must be the SUBTREE's own.  Carrying the Hamnix tmpfs across cost
 * an evening: Xvfb inside the Debian namespace wrote its framebuffer to
 * /tmp/xfb, that landed in a tmpfs that only the child could see, and
 * user/xbridge.ad on the Hamnix side found nothing at /n/distro/tmp/xfb.  The
 * X server was running perfectly and its output was in a private universe.
 * And BIND, not MOVE: a child must not take the parent's mounts away. */
/* HOW THE SWITCH IS PERFORMED, and why it is not chroot(2) and not
 * pivot_root(2). The measurements are in the block above enter_root's helpers;
 * this is what they decided.
 *
 *   mount(mnt, "/", MS_MOVE)  then  chroot(".")
 *
 * The MS_MOVE is the whole change. chroot(2) alone leaves the process's root
 * DIFFERENT from its mount namespace's root, and the kernel calls that being
 * chrooted -- create_user_ns() refuses outright
 * (kernel/user_namespace.c: current_chrooted() -> EPERM). That is why
 * bubblewrap could not build a container for a non-root user inside
 * `enter debian`, and why its own error message blamed a sysctl that was
 * fine. Moving the new root onto "/" first makes the two the same path, so
 * the chroot(2) that follows is a no-op as far as current_chrooted() is
 * concerned and the containers work.
 *
 * pivot_root(2) is the textbook answer and it does not work here: on the live
 * initramfs boot the root mount is `rootfs`, which has no parent mount, and
 * pivot_root rejects that with EINVAL. Measured, both as root and in a user
 * namespace. MS_MOVE has no such restriction -- it is what switch_root(8)
 * does, on exactly this filesystem, on every Linux boot there has ever been.
 *
 * If the MS_MOVE fails we fall back to a plain chroot(2) and SAY SO, naming
 * what is lost. That fallback is a real confinement -- the body runs in the
 * right root -- it is only the user-namespace property that is missing, so
 * degrading to it is honest where refusing outright would take away a working
 * `enter` to protect a feature the caller may not want. */
/* THE MOUNT POINTS INSIDE A DISTRIBUTION'S OWN ROOT, MADE AT THE ONE MOMENT
 * ROOT HOLDS THE MEDIUM.
 *
 * `enter alpine { … }` assembles a new root and binds /dev, /proc, /srv and
 * /n INTO it (enter_root's `always[]`, and the four bind lines every
 * `ns clean { }` template carries). A bind whose TARGET DIRECTORY does not
 * exist fails ENOENT — and the session user cannot create one: the
 * distribution's `/` is uid 0, and uid 0 is NOT mapped into the user namespace
 * ns_privilege() acquires, so CAP_DAC_OVERRIDE does not reach it. enter_root
 * calls mkdir() for exactly this reason and its return value is ignored,
 * because at uid 0 it always worked.
 *
 * AND THAT IS THE WHOLE OF docs/linux_distro_namespaces.md §8.4. Those
 * directories were only ever created as a SIDE EFFECT of somebody running
 * `enter <name>` AS ROOT earlier in the same boot on a WRITABLE medium, where
 * enter_root's mkdir succeeded and left them behind on the disk. Measured:
 * `debugfs -R 'ls -l /'` shows `n` in build/image/distro.ext4 and NOT in
 * build/image/alpine.ext4 — Debian had been entered by root at some point in
 * its life and Alpine had not. So the console worked, the desktop terminal
 * worked (both run a root `enter` first, or run on the medium that already
 * had the directory), and the DE application menu — the ONE launcher that
 * reaches `enter` before any root `enter` has run — did not. The failure was
 * read as "the first bind, the root switch, fails ENOENT"; it is in fact the
 * LAST bind, `#/` onto /n, with the root switch having succeeded.
 *
 * Doing it here makes the boot's `bind '#distro/<name>' /n/<name>` post a
 * server that is COMPLETE at its name, which is what the rest of this file
 * already assumes. Root only: for anyone else this is a no-op, and the bind
 * they are about to attempt will name its own failure.
 */
static void distro_stage_runtime(const char *dst);

static void distro_stage_mountpoints(const char *dst)
{
    if (geteuid() != 0)
        return;
    static const char *pts[] = { "/n", "/dev", "/proc", "/sys", "/srv" };
    char p[1024];
    for (size_t i = 0; i < sizeof pts / sizeof pts[0]; i++) {
        if ((size_t)snprintf(p, sizeof p, "%s%s", dst, pts[i]) >= sizeof p)
            continue;
        if (mkdir(p, 0755) == 0 || errno == EEXIST)
            continue;
        /* A read-only medium is the honest case here, and it PREDICTS the
         * ENOENT an unprivileged `enter` will hit later. Say it now, once per
         * point, rather than letting it surface as a launcher that does
         * nothing. */
        char m[320];
        int n = snprintf(m, sizeof m,
            "bind: could not create the mount point `%s' (%s); "
            "`enter' as the session user will fail there\n", p,
            strerror(errno));
        cons_write(m, n > 0 ? (size_t)n : 0);
    }
    /* The same moment, the same argument, the fourth member of the same
     * family: see distro_stage_runtime just below. */
    distro_stage_runtime(dst);
}

/* THE SESSION'S RUNTIME DIRECTORY, AND IT IS THE FOURTH FAULT OF THE FAMILY
 * THE FUNCTION ABOVE OPENED.
 *
 * §8.4 and §8.5 of docs/linux_distro_namespaces.md name three faults, and all
 * three are the same mistake: a thing ROOT made when root was its only user,
 * invisible to the unprivileged session that came later. A mount point in the
 * medium (`/n` — the function above). A stale X lock in its `/tmp` (cleared by
 * the generated /etc/rc.distros). The Wayland socket in its `/run`, `srwxr-xr-x`
 * when connect(2) needs write (wsyswl chmods it 0666 at creation).
 *
 * The fourth is the DIRECTORY the third lives in. Measured with debugfs on both
 * media: `/run` 40755 uid 0, `/run/dbus` 40755 uid 0, `/run/dconf` 40700 uid 0.
 * `$XDG_RUNTIME_DIR` WAS that `/run`. So the session could READ everything
 * wsyswl publishes there — the socket at 0666 and the `hamnix-screen` geometry
 * file at 0644 — and CREATE NOTHING. Fixing the socket mode fixed CONNECTING;
 * it never touched CREATING, and a runtime directory a session cannot write is
 * not a runtime directory.
 *
 * WHAT IS MADE HERE, AND WHY IT IS NARROWER THAN WHAT IT REPLACES. `/run/user/
 * <uid>` at 0700 owned by that uid is the ordinary Linux shape, and against
 * today's `/run` it is a TIGHTENING, not a widening: the session gets a
 * directory of its own instead of read-and-traverse over the whole of a
 * distribution's runtime state. The alternative — making a distribution's
 * `/run` world-writable — is the one this project already rejected, and
 * rightly: it hands every principal in the namespace write access to the
 * display socket's directory to solve one uid's problem.
 *
 * NOTHING MOVES. The socket stays at `/run/wayland-0`, because four separate
 * files name that path (`hamnix-x11session` in both distributions,
 * tests/linux/alpine_gui_run.sh, tests/linux/steam_gui_run.sh and
 * tests/linux/x11_geom_probe.sh) and a fix that silently relocates a display
 * socket is a fix that breaks four measurements to close one gap. What goes
 * into the new directory instead is a SYMLINK per published name, pointing back
 * up at the real one. `connect(2)`, `[ -S ]`, `[ -r ]` and `read` all follow
 * symlinks, so `$XDG_RUNTIME_DIR/wayland-0` and `$XDG_RUNTIME_DIR/hamnix-screen`
 * resolve for a client that has never heard of `/run/wayland-0` — which is
 * exactly what libwayland's `wl_display_connect(NULL)` builds. The links are
 * dangling between here (rc.boot) and rc.5, when the per-distribution wsyswl
 * actually posts its socket; a dangling symlink is the correct state for a
 * name whose server has not started yet, and it is the same "post the server at
 * its name" order the rest of this file is built on.
 *
 * `/run/dbus` AND `/run/dconf` ARE CHOWNED, NOT WIDENED, and this is the part
 * worth arguing rather than assuming. Their MODES are left exactly as they are
 * (0755 and 0700); only the owner changes, from uid 0 to the session uid. On a
 * real Linux the system bus is started by init as root and the session never
 * writes `/run/dbus` — but nothing here starts it as root: `hamnix-x11session`
 * runs `dbus-daemon --system` itself, as uid 1001, and `/run/dbus/system_bus_
 * socket` is a COMPILE-TIME path in dbus that no environment variable moves. So
 * `/run/user/<uid>` alone does not bring the system bus up; it fixes the SESSION
 * bus and dconf and leaves `system_bus_socket': Permission denied` exactly where
 * it was. There are two ways to close it and only one of them is small: root
 * starts a bus per distribution at boot (new machinery, a daemon supervised by
 * nobody), or the one principal that actually runs the bus owns the directory it
 * must write. Inside a distribution namespace there IS one session user, so the
 * second transfers a directory rather than sharing it, and no other uid gains
 * anything. That is the choice taken here; if a distribution ever grows a real
 * root-run bus, this is the line to delete.
 *
 * Root only, EEXIST is success, and a read-only medium says so once per path —
 * the same three rules as the function above, for the same reason: this runs on
 * every `bind '#distro/<name>' /n/<name>`, which the boot does per distribution
 * and a session user may attempt at any time.
 */
#define HAMNIX_SESSION_UID 1001
#define HAMNIX_SESSION_GID 1001

static void distro_stage_note(const char *what, const char *p)
{
    char m[512];
    int n = snprintf(m, sizeof m,
        "bind: could not %s `%s' (%s); the session user's runtime directory "
        "will not be complete\n", what, p, strerror(errno));
    cons_write(m, n > 0 ? (size_t)n : 0);
}

static void distro_stage_runtime(const char *dst)
{
    if (geteuid() != 0)
        return;
    char p[1024];

    /* /run itself, then /run/user: both 0755 root, which is what they are on a
     * distribution today and what every other Linux has. Only the leaf is the
     * session's. */
    if ((size_t)snprintf(p, sizeof p, "%s/run", dst) >= sizeof p)
        return;
    if (mkdir(p, 0755) < 0 && errno != EEXIST) {
        /* A read-only medium. Nothing below can work, and the launcher shim
         * will say the same thing again from inside; once is enough here. */
        distro_stage_note("create", p);
        return;
    }
    if ((size_t)snprintf(p, sizeof p, "%s/run/user", dst) >= sizeof p)
        return;
    if (mkdir(p, 0755) < 0 && errno != EEXIST) {
        distro_stage_note("create", p);
        return;
    }

    /* The leaf. mkdir's mode is masked by the umask (022 in every boot here),
     * so 0700 survives it -- but chmod anyway, because a directory left by an
     * earlier boot with a different umask is the case EEXIST hides. */
    char rt[1024];
    if ((size_t)snprintf(rt, sizeof rt, "%s/run/user/%d", dst,
                         HAMNIX_SESSION_UID) >= sizeof rt)
        return;
    if (mkdir(rt, 0700) < 0 && errno != EEXIST) {
        distro_stage_note("create", rt);
        return;
    }
    if (chown(rt, HAMNIX_SESSION_UID, HAMNIX_SESSION_GID) < 0)
        distro_stage_note("chown", rt);
    if (chmod(rt, 0700) < 0)
        distro_stage_note("chmod 0700", rt);

    /* The names wsyswl publishes in `/run`, linked into the new directory so
     * that moving $XDG_RUNTIME_DIR moves NOTHING on disk. Relative targets:
     * from /run/user/<uid>/ the string `../../wayland-0' is /run/wayland-0,
     * which stays correct however the tree is bound or entered. */
    static const char *pub[] = { "wayland-0", "hamnix-screen", "wsyswl-state" };
    for (size_t i = 0; i < sizeof pub / sizeof pub[0]; i++) {
        char link[1152], tgt[64];
        if ((size_t)snprintf(link, sizeof link, "%s/%s", rt, pub[i]) >= sizeof link)
            continue;
        snprintf(tgt, sizeof tgt, "../../%s", pub[i]);
        /* A LINK LEFT BY AN EARLIER BOOT IS NOT EVIDENCE THAT IT POINTS
         * ANYWHERE USEFUL. /run is on the medium and survives the reboot, so
         * replace rather than trust: unlink then symlink, and EEXIST from a
         * plain symlink(2) would otherwise be read as success for ever. */
        if (unlink(link) < 0 && errno != ENOENT) {
            distro_stage_note("replace", link);
            continue;
        }
        if (symlink(tgt, link) < 0)
            distro_stage_note("link", link);
    }

    /* The two runtime directories a desktop session must write and could not.
     * Owner only -- the modes are untouched. See the argument above. */
    static const char *own[] = { "/run/dbus", "/run/dconf" };
    static const mode_t ownmode[] = { 0755, 0700 };
    for (size_t i = 0; i < sizeof own / sizeof own[0]; i++) {
        if ((size_t)snprintf(p, sizeof p, "%s%s", dst, own[i]) >= sizeof p)
            continue;
        if (mkdir(p, ownmode[i]) < 0 && errno != EEXIST) {
            distro_stage_note("create", p);
            continue;
        }
        if (chown(p, HAMNIX_SESSION_UID, HAMNIX_SESSION_GID) < 0)
            distro_stage_note("chown", p);
    }
}

/* The bind that stages the tree, named by the paths the RESOLVER produced
 * rather than by the `#letter` the caller typed. `bind '#distro/alpine' /`
 * failing ENOENT is unactionable; "/n/alpine -> /tmp/.hamns-412: No such file
 * or directory" says which of the two names does not exist. */
static void bind_stage_failed(const char *src, const char *dst)
{
    char m[512];
    int n = snprintf(m, sizeof m,
        "bind: could not graft `%s' onto `%s': %s\n", src, dst,
        strerror(errno));
    cons_write(m, n > 0 ? (size_t)n : 0);
    /* AND to whoever asked -- see errstr_buf. errno is still the one this
     * failure set, which is what errstr_setf keys on. */
    errstr_setf(errno, "could not graft `%s' onto `%s': %s", src, dst,
                strerror(errno));
}

/* Say which STEP of the root switch failed, and on which path. Not rate-
 * limited by a `static int said`: an `enter` that does not enter happens once
 * per launch and the caller needs the line for THAT launch, not for the first
 * one the process ever attempted. */
static void enter_root_failed(const char *step, const char *path)
{
    char m[512];
    int n = snprintf(m, sizeof m,
        "bind: the root switch failed at %s(\"%s\"): %s -- the staged root is "
        "assembled under /n/.root (root) or $TMPDIR/.hamns-<pid> (a session "
        "user), and the body will NOT be run.\n",
        step, path, strerror(errno));
    cons_write(m, n > 0 ? (size_t)n : 0);
    errstr_setf(errno,
        "the root switch failed at %s(\"%s\"): %s -- the staged root is "
        "assembled under /n/.root (root) or $TMPDIR/.hamns-<pid> (a session "
        "user), and the body was NOT run", step, path, strerror(errno));
}

static int32_t enter_root(const char *mnt, int is_sysroot)
{
    /* /n comes across too: it is the conventional mount-point parent, and a
     * tool running inside a subtree still needs to see what is mounted there. */
    static const char *always[] = { "/dev", "/proc", "/sys", "/n" };
    static const char *sysroot_only[] = { "/srv", "/tmp" };
    char dest[256];
    for (size_t i = 0; i < sizeof always / sizeof always[0]; i++) {
        snprintf(dest, sizeof dest, "%s%s", mnt, always[i]);
        mkdir(dest, 0755);
        if (is_sysroot) {
            if (mount(always[i], dest, NULL, MS_MOVE, NULL) == 0)
                continue;
        }
        ns_mount(always[i], dest, NULL, MS_BIND | MS_REC, NULL);
    }
    if (is_sysroot) {
        for (size_t i = 0; i < sizeof sysroot_only / sizeof sysroot_only[0]; i++) {
            snprintf(dest, sizeof dest, "%s%s", mnt, sysroot_only[i]);
            mkdir(dest, 0755);
            if (mount(sysroot_only[i], dest, NULL, MS_MOVE, NULL) < 0)
                ns_mount(sysroot_only[i], dest, NULL, MS_BIND | MS_REC, NULL);
        }
    }
    /* THE ROOT SWITCH HAS FOUR STEPS AND ONLY ONE ERRNO. A caller that sees
     * ENOENT out of `bind '#distro/alpine' /` cannot tell whether the medium
     * failed to resolve, the staging directory vanished, or the chroot did --
     * and docs/linux_distro_namespaces.md §8.4 spent three measured passes on
     * that ambiguity. Each step now names itself and the path it was given. */
    if (chdir(mnt) < 0) {
        enter_root_failed("chdir", mnt);
        return -(int32_t)errno;
    }
    /* "." rather than mnt: the cwd is already INSIDE the new mount, so the
     * move cannot be confused by the name it used to have. */
    if (mount(".", "/", NULL, MS_MOVE, NULL) < 0) {
        static int said;
        if (!said) {
            said = 1;
            char m[256];
            int n = snprintf(m, sizeof m,
                "enter: could not move the new root onto / (%s); "
                "falling back to chroot(2) -- the body runs in the right root, "
                "but nothing inside it can create a user namespace, so "
                "bubblewrap/pressure-vessel containers will not start.\n",
                strerror(errno));
            cons_write(m, n > 0 ? (size_t)n : 0);
        }
    }
    if (chroot(".") < 0) {
        enter_root_failed("chroot", mnt);
        return -(int32_t)errno;
    }
    if (chdir("/") < 0) {
        enter_root_failed("chdir-after-chroot", "/");
        return -(int32_t)errno;
    }
    return 0;
}

int32_t sys_bind(const char *dst, const char *src, int32_t flag)
{
    (void)flag;                 /* MREPL/MBEFORE/MAFTER ordering: Linux mounts
                                 * already stack last-wins, which is MREPL. */
    if (!dst || !src) {
        errno = EFAULT;
        return -1;
    }

    /* A plain path source is an ordinary bind mount — this is the general
     * namespace algebra, and it is what user/nsrun.ad and user/distrofs.ad
     * actually want. */
    if (src[0] != '#') {
        mkdir(dst, 0755);
        /* A BLOCK DEVICE source means "mount this filesystem here", not "bind
         * this directory here".  `bind /dev/vdb2 /n/target` in the installer
         * has to make the new root's filesystem visible, and a bind mount of
         * a device NODE would make the node visible instead -- succeeding,
         * and putting a character-special file where a filesystem should be.
         *
         * The device-server branch below already reasons this way for
         * `#distro` and `#sysroot`; a plain path deserves the same answer,
         * because the verb means the same thing. */
        struct stat sb;
        if (stat(src, &sb) == 0 && S_ISBLK(sb.st_mode)) {
            static const char *fstypes[] = { "ext4", "ext3", "ext2", "vfat",
                                             "squashfs", "btrfs", "xfs" };
            int last = ENODEV;
            for (size_t i = 0; i < sizeof fstypes / sizeof fstypes[0]; i++) {
                if (mount(src, dst, fstypes[i], 0, NULL) == 0)
                    return 0;
                last = errno;
                if (last == EBUSY)
                    break;
            }
            errno = last;
            return -(int32_t)last;
        }
        return rc32(ns_mount(src, dst, NULL, MS_BIND | MS_REC, NULL));
    }

    const char *sub = "";
    const struct devsrv *d = devsrv_lookup(src, &sub);
    if (!d) {
        errno = ENOSYS;
        return -1;
    }
    if (d->unimpl) {
        errno = ENOSYS;
        return -1;
    }

    /* `bind '#d' /fd` — succeed, and do NOTHING.
     *
     * NOT because /fd is unimplemented: user/linux-fdns.c serves it, and
     * sys_open intercepts the path before the filesystem is ever consulted.
     * There is simply nothing to mount. The history below is kept because the
     * WRONG answer here was expensive and is easy to reach for again.
     *
     * Hamnix passes a child's standard streams as NAMES rather than inherited
     * integer fds (SPAWN_STDIO_NS, user/hamsh.ad:185): the shell sys_fdbind's
     * channels at the child's /fd/0,1,2, and the child opens those names and
     * dup2s them onto 0,1,2. Traced from inside the VM, a spawned child does
     * exactly:
     *
     *     openat("/fd/1", O_RDONLY) = 3
     *     dup2(3, 1) = 1
     *     execve("/bin/echo", ...)
     *     write(1, "TRACED-CHILD", 12) = -1 EBADF
     *
     * Note O_RDONLY: sys_open takes no flags and always opens for reading, so
     * a materialised /fd/1 can only ever produce a READ-ONLY stdout. The child
     * then runs perfectly and exits 0 with every byte it wrote thrown away —
     * a success-shaped wrong answer of exactly the kind §4.1d warns about.
     *
     * Making this a real bind mount of /proc/self/fd is doubly wrong: it also
     * captures the BINDING process's fd table rather than resolving per-process,
     * so the child would inherit the shell's fds even if the flags were right.
     *
     * /fd is now served in the runtime instead, per-process and with the
     * access mode the BINDER chose — which is what the fd-slot model always
     * meant. A mount could never have expressed that. */
    if (!strcmp(d->letter, "#d") || !strcmp(d->letter, "#I"))
        return 0;

    mkdir(dst, 0755);

    if (d->fstype) {
        if (ns_mount(d->fstype, dst, d->fstype, 0, NULL) == 0)
            return 0;
        /* EPERM with the server ALREADY at that name. Inside a user namespace
         * devtmpfs cannot be mounted at all and proc sometimes cannot, so the
         * kernel answers EPERM where it would otherwise have answered EBUSY --
         * and EBUSY has always meant "it is already there", which for a Plan 9
         * re-bind of the same server over the same point is success. Checked
         * against /proc/self/mountinfo, not assumed: if the name is not
         * already that filesystem this still fails. */
        if (errno == EPERM && already_mounted_type(dst, d->fstype))
            return 0;
        /* EBUSY means it is ALREADY mounted there, and that is a success, not
         * a failure. The rc scripts bind these repeatedly on purpose --
         * etc/rc.de-user's header says "idempotent on top of the COW-inherited
         * ones" -- because in Plan 9 a namespace copy carries the parent's
         * binds and re-binding the same server over the same point is a no-op.
         * Returning an error made every DE-spawned shell print
         * "bind: Device or resource busy" for a namespace it already had. */
        if (errno == EBUSY)
            return 0;
        return rc32(-1);
    }

    /* Bind-mount forms. Resolve the source root. */
    char srcpath[4096];
    char distropath[512];
    const char *root;
    if (!strcmp(d->letter, "#distro")) {
        /* `sub` after `#distro` is the NAME of the distribution, not a
         * subpath: `#distro/alpine`, `#distro/alpine/usr`. Split the first
         * component off and let what is left be the subpath, so both forms
         * mean what they look like. */
        char name[128];
        const char *rest = "";
        if (sub[0] == '/') {
            const char *p = sub + 1;
            const char *slash = strchr(p, '/');
            size_t n = slash ? (size_t)(slash - p) : strlen(p);
            if (n >= sizeof name) {
                errno = ENAMETOOLONG;
                return -1;
            }
            memcpy(name, p, n);
            name[n] = '\0';
            rest = slash ? slash : "";
        } else {
            name[0] = '\0';
        }
        sub = rest;
        root = distro_resolve(name, distropath, sizeof distropath);
        if (!root) {
            /* By name, with what would fix it. The alternative answer to this
             * is mounting SOME other distribution and reporting success. */
            char m[320];
            int n = snprintf(m, sizeof m,
                "bind: no distribution namespace named `%s': not in "
                "/etc/distros, $HAMNIX_DISTRO_<NAME> unset, no attached "
                "filesystem carries the label it names, and nothing is mounted "
                "at /n/%s\n", name, name);
            cons_write(m, n > 0 ? (size_t)n : 0);
            /* AND to whoever asked. This is the refusal the owner hit by
             * typing `enter debian {sh}` into a desktop terminal, where the
             * console above is invisible; without this line hamsh could only
             * print strerror_r's "No such file or directory" after its own
             * "first failing bind:" preamble, naming the bind but not one of
             * the four things that would fix it. */
            errno = ENOENT;
            errstr_setf(ENOENT,
                "no distribution namespace named `%s': not in /etc/distros, "
                "$HAMNIX_DISTRO_%s unset, no attached filesystem carries that "
                "label, and nothing is mounted at /n/%s", name, name, name);
            return -ENOENT;
        }
    } else if (!strcmp(d->letter, "#esp")) {
        /* esp_device() has already said, by name, which disk it searched and
         * what it found there. Failing is right: the alternative is mounting
         * some OTHER disk's ESP -- on a laptop, the one with the owner's real
         * operating system on it -- and reporting success. */
        root = esp_device();
        if (!root) {
            errno = ENODEV;
            return -ENODEV;
        }
    } else if (!strcmp(d->letter, "#sysroot") || !strcmp(d->letter, "#r")) {
        root = sysroot_device();
        /* sysroot_device has already said which identifier it wanted and what
         * it saw instead. Failing here is the point: the alternative is
         * mounting the initramfs onto itself and reporting a root. */
        if (!root) {
            errno = ENODEV;
            return -ENODEV;
        }
    } else
        root = d->source;

    if ((size_t)snprintf(srcpath, sizeof srcpath, "%s%s", root, sub)
            >= sizeof srcpath) {
        errno = ENAMETOOLONG;
        return -1;
    }

    /* A subtree server may be backed by a BLOCK DEVICE rather than a directory,
     * and that is the normal case for `#distro` and `#sysroot`.
     *
     * This mirrors Hamnix exactly rather than inventing something. There, the
     * kernel parses the rootfs partition's `.hamnix-roots` sentinel at boot and
     * posts each named subtree as a file server, so `bind '#distro' /n/distro`
     * splices in a subtree that lives on a partition. Here there is no kernel
     * doing that, so bind performs the mount itself — same verb, same meaning,
     * one less layer.
     *
     * The Debian namespace is this: HAMNIX_DISTRO names a filesystem holding a
     * Debian tree, bound at /n/distro, and nothing Debian installs is ever
     * written into the Hamnix filesystem. */
    /* `bind '#distro' /` — the idiom the rc.de-* scripts use to ENTER a
     * subtree, as opposed to merely making it visible. On Hamnix that rebinds
     * the process's root to the subtree server; on Linux it is a chroot, and it
     * is only safe because the caller has already done rfork(RFNAMEG) per the
     * Plan 9 invariant, so the mount cannot escape into anyone else's view.
     *
     * This is how a Debian application is run: privatise the namespace, bind
     * '#distro' at /, exec. The Hamnix filesystem is then not even reachable,
     * which is a stronger guarantee than "we agreed not to write to it". */
    int to_root = (dst[0] == '/' && dst[1] == '\0');
    int is_sysroot = !strcmp(d->letter, "#sysroot") || !strcmp(d->letter, "#r");
    /* Posting a distribution AT ITS NAME (`bind '#distro/alpine' /n/alpine`)
     * rather than entering it: that is the moment the mount points inside it
     * get made. See distro_stage_mountpoints. */
    int posting_distro = !to_root && !strcmp(d->letter, "#distro");
    char stage[256];
    const char *mnt = dst;
    if (to_root) {
        mnt = root_stage_dir(stage, sizeof stage);
        if (!mnt) {
            /* No writable place to assemble the new root. Naming it matters:
             * the alternative answer to this is entering NOTHING and running
             * the body in the native root. */
            const char *m = "bind: no writable staging directory for the new "
                            "root (tried /n/.root and $TMPDIR)\n";
            cons_write(m, strlen(m));
            errno = EACCES;
            errstr_setf(EACCES, "no writable staging directory for the new "
                                "root (tried /n/.root and $TMPDIR)");
            return -EACCES;
        }
    }

    /* A filesystem this device already carries is the one to use. See
     * blk_already_mounted: mounting it a second time is both wrong and
     * impossible for anyone but real root, and `bind '#distro' /` from a
     * desktop session is exactly that case -- etc/rc.boot mounted the tree at
     * /n/distro when it was root, and this binds THAT. */
    char existing[1024];
    if (blk_already_mounted(srcpath, existing, sizeof existing)) {
        if (ns_mount(existing, mnt, NULL, MS_BIND | MS_REC, NULL) < 0) {
            bind_stage_failed(existing, mnt);
            return -(int32_t)errno;
        }
        if (posting_distro)
            distro_stage_mountpoints(mnt);
        return to_root ? enter_root(mnt, is_sysroot) : 0;
    }

    struct stat sb;
    if (stat(srcpath, &sb) == 0 && S_ISBLK(sb.st_mode)) {
        static const char *fstypes[] = { "ext4", "ext3", "ext2", "squashfs",
                                         "vfat", "btrfs", "xfs" };
        int last = ENODEV;
        for (size_t i = 0; i < sizeof fstypes / sizeof fstypes[0]; i++) {
            if (mount(srcpath, mnt, fstypes[i], 0, NULL) == 0) {
                if (posting_distro)
                    distro_stage_mountpoints(mnt);
                return to_root ? enter_root(mnt, is_sysroot) : 0;
            }
            last = errno;
            /* EBUSY means something is already mounted there; trying more
             * filesystem types will not help. EPERM means we are not root and
             * mounting a real filesystem is not something a user namespace can
             * grant -- the same is true of every other type in the list. */
            if (last == EBUSY || last == EPERM)
                break;
        }
        errno = last;
        return -(int32_t)last;
    }

    if (ns_mount(srcpath, mnt, NULL, MS_BIND | MS_REC, NULL) < 0) {
        bind_stage_failed(srcpath, mnt);
        return -(int32_t)errno;
    }
    if (posting_distro)
        distro_stage_mountpoints(mnt);
    return to_root ? enter_root(mnt, is_sysroot) : 0;
}

/* extern def sys_unmount(new: Ptr[char], old: Ptr[char]) -> int32
 *
 * Plan 9 unmount takes the thing being removed and the name it sits under;
 * with `new` NULL it removes everything bound at `old`. Linux only names the
 * mountpoint, so `old` is what matters. */
int32_t sys_unmount(const char *new_, const char *old)
{
    (void)new_;
    if (!old) {
        errno = EFAULT;
        return -1;
    }
    return rc32(umount2(old, 0));
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
 * compositor design (§6) is now made: the window table is shared memory, the
 * same way devwsys.ad's is kernel memory, and user/linux-wsys.c serves
 * /dev/wsys out of it.  These two stamp a spawned task's pid against a wid,
 * which is what /dev/wsys/self answers.
 *   extern def sys_wsys_alloc(pid: uint64) -> int32
 *   extern def sys_wsys_free(wid: int32) -> int32 */
int32_t sys_wsys_alloc(uint64_t pid) { return rc32(hamwsys_alloc(pid)); }

/*   extern def sys_wsys_was_refused() -> int32
 *
 * 1 when THIS process was turned away by the window system's version refusal.
 * A client that could not get a window needs to tell "the running session is
 * older than I am, and a restart fixes it" from "I am broken", because those
 * two want opposite things written down: the first is about the machine and
 * clears itself at the reboot it asks for, the second is about the program and
 * should persist. user/hamappmenu.ad wrote the second for the first and cost
 * the Applications button permanently, across reboots -- measured by
 * tests/linux/installed_update_wsysver.sh at STAGE D. */
int32_t sys_wsys_was_refused(void) { return (int32_t)hamwsys_was_refused(); }
int32_t sys_wsys_free(int32_t wid)   { return rc32(hamwsys_free(wid)); }

/* THE MEDIATOR'S TRANSPORT, driven from a test program rather than from an
 * environment variable inside the client path.  See THE MEDIATOR'S TRANSPORT
 * in user/linux-wsys.h.  Both return a FAILURE COUNT, so zero is the only
 * pass; tests/linux/wsys_srv_probe.ad is the only caller.
 *   extern def sys_wsys_srv_selftest() -> int32
 *   extern def sys_wsys_srv_sustain(ops_per_sec: int32, secs: int32) -> int32 */
int32_t sys_wsys_srv_selftest(void) { return (int32_t)hamwsys_srv_selftest(); }
int32_t sys_wsys_srv_mutate(int32_t victim_wid)
{ return (int32_t)hamwsys_srv_mutate_selftest((int)victim_wid); }
int32_t sys_wsys_srv_sustain(int32_t ops_per_sec, int32_t secs)
{ return (int32_t)hamwsys_srv_sustain((int)ops_per_sec, (int)secs); }
/* The unrouted half of the identity attack: the same mutation with no server
 * in it, which is the arm that MUST succeed.  See hamwsys_srv_attack_local. */
int32_t sys_wsys_srv_attack_local(int32_t victim_wid)
{ return (int32_t)hamwsys_srv_attack_local((int)victim_wid); }
/* Stage 4's read latency instrument.  Every sample printed, because the number
 * it exists to beat -- 851 us -- was a MAX and a median-only measurement is
 * exactly what would have hidden it.
 *   extern def sys_wsys_srv_readlat(n: int32) -> int32 */
int32_t sys_wsys_srv_readlat(int32_t n)
{ return (int32_t)hamwsys_srv_readlat((int)n); }
/* STAGE 5.  The handoff is a real API a toolkit calls around a spawn (see
 * hamwsys_srv_handoff in user/linux-wsys.h); conngate is the gate driver that
 * measures both arms of the property from the holder's own process.
 *   extern def sys_wsys_srv_handoff(on: int32) -> int32
 *   extern def sys_wsys_srv_conngate(wid: int32, selfpath: Ptr[char],
 *                                   uidgate: Ptr[char]) -> int32 */
int32_t sys_wsys_srv_dropwrite(int32_t wid, int32_t to_uid)
{ return (int32_t)hamwsys_srv_dropwrite((int)wid, (int)to_uid); }
int32_t sys_wsys_srv_scene(int32_t victim_wid)
{ return (int32_t)hamwsys_srv_scene_selftest((int)victim_wid); }
/* STAGE 8's wctl probe.  Same shape as the scene one, scored on the server's
 * rc for one blocking message rather than on a counter delta -- a drag makes
 * ~800 writes a second through the same counters.
 *   extern def sys_wsys_srv_wctl(victim_wid: int32, local: int32) -> int32 */
int32_t sys_wsys_srv_wctl(int32_t victim_wid, int32_t local)
{ return (int32_t)hamwsys_srv_wctl_selftest((int)victim_wid, (int)local); }
int32_t sys_wsys_srv_handoff(int32_t on)
{ return (int32_t)hamwsys_srv_handoff((int)on); }
int32_t sys_wsys_srv_conngate(int32_t wid, const char *selfpath,
                              const char *uidgate)
{ return (int32_t)hamwsys_srv_conngate((int)wid, selfpath, uidgate); }

/* GPU presentation of a window frame. Unimplemented on purpose: the scene
 * compositor rasterizes in software (lib/hamui_host.ad's vk2d raster ops), so
 * nothing on this line needs a device-side frame yet.
 *   extern def sys_vk_window_frame(wid: int32, reserved: int32,
 *                                  frame: int64) -> int64 */
int64_t sys_vk_window_frame(int32_t wid, int32_t reserved, int64_t frame)
{ (void)wid; (void)reserved; (void)frame; errno = ENOSYS; return -1; }

/* Interface configuration — HANDOFF.md §3.3. The real answer is rtnetlink,
 * and it is independent of the /net file-tree decision, but it is a subsystem
 * rather than an entry point and belongs with Tier 3.
 *   extern def sys_netcfg(op: uint64, a1: uint64, a2: uint64) -> int64 */
int64_t sys_netcfg(uint64_t op, uint64_t a1, uint64_t a2)
{ return hamnet_cfg(op, a1, a2); }

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

/* ====================================================================
 * evdev ABSOLUTE AXES — the device's own range, read from the device.
 * ====================================================================
 *
 * An absolute axis carries a number in the DEVICE'S OWN UNITS, and the range
 * of those units is a property of the device that is only discoverable by
 * asking it. wsysd used to assume every EV_ABS value was 0..32767 -- the
 * range QEMU's virtio-tablet advertises -- and multiply by the screen size.
 * That is right for a VM and wrong for every real i2c-hid digitizer, whose
 * logical maximum is a few thousand: a touch at the far edge landed a few
 * hundred pixels in, and a touchpad (max ~1300 x ~750) mapped its ENTIRE
 * surface onto a 76x27 pixel box in the top-left corner of a 1920x1200 panel.
 *
 * EVIOCGABS is the answer the kernel already has. So is the device's own
 * statement of what KIND of pointing device it is: INPUT_PROP_DIRECT means the
 * user touches the thing the coordinates are in (a touchscreen -- absolute,
 * jump to the point), INPUT_PROP_POINTER means the surface is somewhere else
 * (a touchpad -- the motion is relative to wherever the cursor already is).
 * That property bit exists precisely to tell those two apart, and guessing
 * from the axis range instead would misclassify the first large touchpad.
 *
 * out[] is filled with 8 int32s and MUST have room for them:
 *   0 = 1 if the node has usable absolute X and Y axes, else 0
 *   1,2 = ABS_X minimum, maximum
 *   3,4 = ABS_Y minimum, maximum
 *   5 = 1 if INPUT_PROP_DIRECT   (touchscreen: absolute)
 *   6 = 1 if INPUT_PROP_POINTER  (touchpad: relative)
 *   7 = 1 if the node advertises multitouch (ABS_MT_POSITION_X)
 *
 * Returns 0 if the fd is an evdev node that answered, -1 otherwise. -1 is the
 * ordinary case for a REGULAR FILE, which is what every offscreen gate feeds
 * the compositor: a file of evdev records is byte-identical to the device's
 * output but has no ioctl interface, so the caller falls back to a declared
 * range (HAMWSYSD_ABS). That fallback is the only way an offscreen test can
 * exercise this arithmetic at all, and it is not a second code path -- it
 * fills in exactly the same fields this probe does. */
#include <sys/ioctl.h>
#include <linux/input.h>

int32_t hamin_abs_probe(int32_t fd, int32_t *out)
{
    if (!out) { errno = EINVAL; return -1; }
    for (int i = 0; i < 8; i++) out[i] = 0;
    if (fd < 0) { errno = EBADF; return -1; }

    /* EVIOCGBIT(EV_ABS) first: a keyboard has no absolute axes at all and
     * must not be probed as though it did. */
    unsigned long absbits[(ABS_CNT + 8 * sizeof(long) - 1) /
                          (8 * sizeof(long))];
    memset(absbits, 0, sizeof absbits);
    if (ioctl(fd, EVIOCGBIT(EV_ABS, sizeof absbits), absbits) < 0)
        return -1;                      /* not an evdev node (a plain file) */
#define HAMIN_HAS(b) ((absbits[(b) / (8 * sizeof(long))] >> \
                       ((b) % (8 * sizeof(long)))) & 1ul)
    if (!HAMIN_HAS(ABS_X) || !HAMIN_HAS(ABS_Y))
        return 0;                       /* an evdev node, but relative-only */
    out[7] = HAMIN_HAS(ABS_MT_POSITION_X) ? 1 : 0;
#undef HAMIN_HAS

    struct input_absinfo ax, ay;
    memset(&ax, 0, sizeof ax);
    memset(&ay, 0, sizeof ay);
    if (ioctl(fd, EVIOCGABS(ABS_X), &ax) < 0) return -1;
    if (ioctl(fd, EVIOCGABS(ABS_Y), &ay) < 0) return -1;
    /* A degenerate range would make the scaling a division by zero. Report it
     * as "no usable absolute axes" rather than inventing a range. */
    if (ax.maximum > ax.minimum && ay.maximum > ay.minimum) {
        out[0] = 1;
        out[1] = ax.minimum; out[2] = ax.maximum;
        out[3] = ay.minimum; out[4] = ay.maximum;
    }

    unsigned long props[(INPUT_PROP_CNT + 8 * sizeof(long) - 1) /
                        (8 * sizeof(long))];
    memset(props, 0, sizeof props);
    if (ioctl(fd, EVIOCGPROP(sizeof props), props) >= 0) {
#define HAMIN_PROP(b) ((props[(b) / (8 * sizeof(long))] >> \
                        ((b) % (8 * sizeof(long)))) & 1ul)
        out[5] = HAMIN_PROP(INPUT_PROP_DIRECT)  ? 1 : 0;
        out[6] = HAMIN_PROP(INPUT_PROP_POINTER) ? 1 : 0;
#undef HAMIN_PROP
    }
    return 0;
}
