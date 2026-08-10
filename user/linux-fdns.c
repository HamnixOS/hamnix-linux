/* user/linux-fdns.c — /fd, the Plan 9 file-descriptor name space.
 *
 * THE PROBLEM THIS SOLVES
 * =======================
 * HANDOFF.md §7.1 names it as the sharpest constraint on this whole port: in
 * Plan 9 a file descriptor is reachable BY NAME from another process.  A
 * terminal creates two pipes and then says
 *
 *     sys_fdbind(child_pid, 0, DEVFD_PIPE_R, in_slot)
 *
 * -- "process `child_pid`'s /fd/0 is the read end of pipe slot `in_slot`" --
 * and the child, without cooperating in any way, finds its stdin there.  On
 * Linux an fd is a per-process integer.  There is no name.  That single gap is
 * why every DE terminal came up saying "(shell failed to start)".
 *
 * THE ANSWER: A PIPE SLOT IS A FIFO
 * ---------------------------------
 * mkfifo(3) is the one Linux object that IS a pipe reachable by name, which
 * makes it the honest port rather than a workaround.  `sys_pipechan()` mints a
 * slot and creates /srv/fd/chan.<slot>; a bind records "(pid, fdnum) -> this
 * slot, this direction" in shared memory; and opening the NAME /fd/<n> looks
 * up the CALLER's own pid in that table and opens the fifo with the direction
 * the binder chose.
 *
 * THE BLOCKING TRAP, AND WHY THE KEEPER FD IS NOT OPTIONAL
 * --------------------------------------------------------
 * Opening a fifo O_RDONLY blocks until a writer arrives, and O_WRONLY blocks
 * until a reader does.  The sequence the terminal actually performs -- create
 * both pipes, bind and open BOTH of its own ends, and only then spawn the
 * shell -- would deadlock on the very first open, before the other end could
 * possibly exist.
 *
 * So `sys_pipechan` also opens the fifo O_RDWR and keeps that descriptor.
 * O_RDWR on a fifo never blocks, and holding it means neither direction is
 * ever without a peer, so every later open returns immediately.  The keeper
 * lives in the CREATING process only, which also gives the right lifetime: when
 * the terminal exits, its keeper closes, and the shell's stdin finally sees
 * EOF -- "the terminal goes away, its shell reads EOF and exits", which is the
 * behaviour user/hamtermscene.ad's own comment says it was always supposed to
 * get and did not.
 *
 * UNBOUND /fd/N
 * -------------
 * If nothing bound it, /fd/<n> is simply the caller's own fd <n> -- a dup(2),
 * not a path open.  That matters: /proc/self/fd/1 opened O_RDONLY fails when
 * fd 1 is a pipe write end, and lib/p9.ad opens /fd/1 for exactly that case.
 * dup preserves the access mode, so it is both simpler and more correct.
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include "linux-fdns.h"

#define FDNS_MAGIC   0x534E4446u          /* "FDNS" */
#define MAX_SLOTS    64
#define MAX_BINDS    512
#define PATH_CAP     256

struct slotrec {
    uint32_t used;
    int32_t  owner;                   /* the pid that called pipechan */
    char     path[PATH_CAP];
};

struct bindrec {
    uint32_t used;
    int32_t  pid;
    int32_t  fdnum;
    int32_t  kind;
    int32_t  slot;
};

struct fdshm {
    uint32_t magic;
    int32_t  next_slot;
    struct slotrec slot[MAX_SLOTS];
    struct bindrec bind[MAX_BINDS];
};

static struct fdshm *shm;

/* Keeper descriptors are PER PROCESS, deliberately: see the header comment.
 * Indexed by slot id modulo MAX_SLOTS. */
static int keeper[MAX_SLOTS];
static int keeper_init;

static const char *shm_path(void)
{
    const char *p = getenv("HAMFDNS");
    if (p && *p) return p;
    return "/srv/fdns";
}

static const char *chan_dir(void)
{
    const char *p = getenv("HAMFDNS_DIR");
    if (p && *p) return p;
    return "/srv";
}

static int attach(void)
{
    if (!keeper_init) {
        for (int i = 0; i < MAX_SLOTS; i++) keeper[i] = -1;
        keeper_init = 1;
    }
    if (shm) return 0;

    const char *cands[3];
    int nc = 0;
    cands[nc++] = shm_path();
    cands[nc++] = "/dev/shm/hamnix-fdns";
    cands[nc++] = "/tmp/hamnix-fdns";

    int fd = -1;
    for (int i = 0; i < nc && fd < 0; i++)
        fd = open(cands[i], O_RDWR | O_CREAT, 0666);
    if (fd < 0) return -1;

    struct stat st;
    if (fstat(fd, &st) < 0) { close(fd); return -1; }
    if ((uint64_t)st.st_size < sizeof(struct fdshm)
        && ftruncate(fd, (off_t)sizeof(struct fdshm)) < 0) {
        close(fd); return -1;
    }
    void *m = mmap(NULL, sizeof(struct fdshm), PROT_READ | PROT_WRITE,
                   MAP_SHARED, fd, 0);
    int e = errno;
    close(fd);
    if (m == MAP_FAILED) { errno = e; return -1; }
    shm = (struct fdshm *)m;
    if (shm->magic != FDNS_MAGIC) {
        memset(shm, 0, sizeof(*shm));
        shm->magic = FDNS_MAGIC;
        shm->next_slot = 1;               /* slot 0 is "no slot" */
    }
    return 0;
}

/* ------------------------------------------------------------------ */
int fdns_is_path(const char *path)
{
    if (!path) return 0;
    if (!strcmp(path, "/fd") || !strcmp(path, "/fd/")) return 1;
    if (strncmp(path, "/fd/", 4) != 0) return 0;
    const char *p = path + 4;
    if (!*p) return 0;
    while (*p) {
        if (*p < '0' || *p > '9') return 0;
        p++;
    }
    return 1;
}

static struct bindrec *bind_find(int32_t pid, int32_t fdnum)
{
    for (int i = 0; i < MAX_BINDS; i++)
        if (shm->bind[i].used && shm->bind[i].pid == pid
            && shm->bind[i].fdnum == fdnum)
            return &shm->bind[i];
    return NULL;
}

static struct slotrec *slot_find(int32_t slot)
{
    if (slot <= 0) return NULL;
    for (int i = 0; i < MAX_SLOTS; i++)
        if (shm->slot[i].used && (int32_t)(i + 1) == slot)
            return &shm->slot[i];
    return NULL;
}

/* THE RACE THE COOPERATIVE SCHEDULER USED TO HIDE.
 *
 * The Plan 9 contract is: parent forks, parent binds the child's /fd names,
 * child runs.  It holds because Hamnix's scheduler keeps the child STATE_READY
 * until the parent yields -- lib/p9.ad's _spawn_flags says so in as many
 * words, and lib/p9.ad:spawn_stdio_pipes exists because even Hamnix loses that
 * guarantee under -smp 2.  On Linux the child is runnable the instant fork(2)
 * returns and there is no guarantee at all, so the child reached
 * open("/fd/0") before the parent's bind landed, found nothing, fell back to
 * its inherited stdin, and the terminal's shell read from the console for ever.
 *
 * So an unbound name waits -- but ONLY when a bind is actually plausible: when
 * the caller's PARENT owns pipe slots, i.e. it called sys_pipechan and is
 * therefore mid-spawn.  A child of a launcher that never made a pipe (the
 * panel's spawn_detached, which is every menu launch) sees no wait at all.
 */
#define BIND_WAIT_MS 400

static int parent_owns_slots(void)
{
    int32_t par = (int32_t)getppid();
    for (int i = 0; i < MAX_SLOTS; i++)
        if (shm->slot[i].used && shm->slot[i].owner == par)
            return 1;
    return 0;
}

static struct bindrec *await_bind(int32_t pid, int32_t fdnum)
{
    if (!parent_owns_slots())
        return NULL;
    for (int ms = 0; ms < BIND_WAIT_MS; ms++) {
        struct bindrec *b = bind_find(pid, fdnum);
        if (b && b->kind != FDNS_NONE)
            return b;
        usleep(1000);
    }
    return NULL;
}

int fdns_open(const char *path, int for_write)
{
    if (attach() < 0) return -1;

    if (!strcmp(path, "/fd") || !strcmp(path, "/fd/")) {
        errno = EISDIR;
        return -1;
    }
    int fdnum = atoi(path + 4);
    int32_t me = (int32_t)getpid();

    struct bindrec *b = bind_find(me, fdnum);
    if (!b || b->kind == FDNS_NONE)
        b = await_bind(me, fdnum);
    if (!b || b->kind == FDNS_NONE) {
        /* Unbound: /fd/<n> IS this process's fd <n>. dup, not a path open --
         * it preserves the access mode, which /proc/self/fd cannot. */
        int r = dup(fdnum);
        if (r < 0) errno = EBADF;
        return r;
    }
    if (b->kind == FDNS_CONS) {
        int r = open("/dev/console", for_write ? O_WRONLY : O_RDONLY);
        if (r < 0)
            r = dup(for_write ? 1 : 0);
        return r;
    }
    struct slotrec *s = slot_find(b->slot);
    if (!s) { errno = ENOENT; return -1; }
    /* The direction comes from the BIND, not from how the caller opened it:
     * the binder is the one that decided which end of the pipe this name is. */
    int flags = (b->kind == FDNS_PIPE_W) ? O_WRONLY : O_RDONLY;
    return open(s->path, flags);
}

int32_t fdns_pipechan(void)
{
    if (attach() < 0) return -1;
    for (int i = 0; i < MAX_SLOTS; i++) {
        if (shm->slot[i].used) continue;
        int32_t slot = (int32_t)(i + 1);
        int pn = snprintf(shm->slot[i].path, PATH_CAP, "%s/chan.%d.%d",
                          chan_dir(), (int)getpid(), (int)slot);
        if (pn < 0 || pn >= PATH_CAP) {
            /* A truncated path is a DIRECTORY name, and mkfifo on it returns
             * EEXIST -- i.e. it looks like it worked. Refuse instead. */
            shm->slot[i].path[0] = '\0';
            errno = ENAMETOOLONG;
            return -1;
        }
        shm->slot[i].owner = (int32_t)getpid();
        unlink(shm->slot[i].path);
        if (mkfifo(shm->slot[i].path, 0666) < 0 && errno != EEXIST)
            return -1;
        /* The keeper. Without it the first open of either end deadlocks --
         * see the header comment; this is not a convenience. */
        int k = open(shm->slot[i].path, O_RDWR | O_CLOEXEC);
        if (k < 0) {
            shm->slot[i].owner = (int32_t)getpid();
        unlink(shm->slot[i].path);
            return -1;
        }
        keeper[i] = k;
        shm->slot[i].used = 1;
        return slot;
    }
    errno = ENOSPC;
    return -1;
}

int32_t fdns_fdbind(int32_t pid, int32_t fdnum, int32_t kind, int32_t slot)
{
    if (attach() < 0) return -1;
    if (pid == 0) pid = (int32_t)getpid();      /* 0 means "me" */

    struct bindrec *b = bind_find(pid, fdnum);
    if (!b) {
        for (int i = 0; i < MAX_BINDS; i++)
            if (!shm->bind[i].used) { b = &shm->bind[i]; break; }
        if (!b) { errno = ENOSPC; return -1; }
        b->used  = 1;
        b->pid   = pid;
        b->fdnum = fdnum;
    }
    b->kind = kind;
    b->slot = slot;
    return 0;
}

/* extern def sys_fdslot_kind(pid, fdnum) -> int32 */
int32_t fdns_slot_kind(int32_t pid, int32_t fdnum)
{
    if (attach() < 0) return FDNS_NONE;
    if (pid == 0) pid = (int32_t)getpid();
    struct bindrec *b = bind_find(pid, fdnum);
    return b ? b->kind : FDNS_NONE;
}

/* After a fork, the child inherits the parent's keeper descriptors. That is
 * correct for the pipe's lifetime (the child is part of the same session) but
 * a child that outlives the parent would keep every fifo alive for ever, so a
 * child which is about to become an independent process drops them. */
void fdns_after_fork_child(void)
{
    if (!keeper_init) return;
    for (int i = 0; i < MAX_SLOTS; i++)
        if (keeper[i] >= 0) { close(keeper[i]); keeper[i] = -1; }
}
