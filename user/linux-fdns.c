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
 * ever without a peer, so every later open returns immediately.
 *
 * THE KEEPER IS ALSO A WRITER, AND THAT IS WHY A PIPELINE NEVER RETURNED
 * ---------------------------------------------------------------------
 * `cat FILE | md5sum` hung for ever, and it was not md5sum: the same md5sum
 * hashed two FILE operands correctly one line above.  Measured at this layer
 * with a two-stage harness, the reader RECEIVED ITS BYTES and then blocked in
 * read(2) for ever.  EOF on a fifo is "the last WRITER closed", and the shell
 * that created the slot still held the O_RDWR keeper -- a writer.  So the end
 * that never finished is the WRITER end, and it was the shell's own keeper,
 * not the `cat`.  Every pipeline in the system had it; only the ones whose
 * reader drains to EOF (md5sum, wc, cksum, sort) could show it.
 *
 * Simply not keeping a keeper is worse, and the same harness says so: with the
 * keeper dropped before the stages ran, `cat` opened, wrote, closed and exited
 * before the reader opened, the fifo's open count hit zero, the kernel threw
 * the buffered bytes away and the reader read "EOF after 0 bytes" -- a SILENT
 * EMPTY ANSWER, which is worse than a hang.
 *
 * So the keeper has a LIFETIME rather than a presence: it is created with the
 * slot, and it is closed as soon as BOTH real ends have been opened by the
 * processes that own them (`rever` / `wever` on the slot, set by fdns_open).
 * From that moment the fifo is held up by the real ends alone, so
 *
 *   - EOF fires exactly when the last real writer closes, and
 *   - EPIPE fires exactly when the last real reader closes,
 *
 * which is what a pipe is.  `fdns_keeper_sweep()` performs the close, and the
 * runtime calls it from the two places a process is about to stop making
 * progress on its own -- sys_read and sys_waitpid -- with a bounded wait, so a
 * stage that never opens its end costs a timeout and an EPIPE rather than a
 * hang.  A pipeline that hangs for ever is the worst failure a shell has.
 *
 * The keeper still lives in the CREATING process only, which keeps the other
 * lifetime it was written for: when the terminal exits, everything it held
 * closes, and the shell's stdin finally sees EOF -- "the terminal goes away,
 * its shell reads EOF and exits", which is the behaviour
 * user/hamtermscene.ad's own comment says it was always supposed to get.
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
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include "linux-fdns.h"

/* Bumped when struct fdshm's layout changed (the slot grew rever/wever/done/
 * bound, the bind grew seq, and the segment grew next_seq).  A segment left
 * behind by an older binary is re-initialised rather than misread. */
#define FDNS_MAGIC   0x32534E46u          /* "FNS2" */
#define MAX_SLOTS    64
#define MAX_BINDS    512
#define PATH_CAP     256

/* A slot is either a PIPE (a fifo) or a REDIRECT TARGET (an ordinary file).
 * Both are addressed the same way -- by number -- because that is what crosses
 * a process boundary. */
enum { SLOT_FIFO = 0, SLOT_FILE = 1 };

struct slotrec {
    uint32_t used;
    int32_t  kind;                    /* SLOT_FIFO | SLOT_FILE */
    int32_t  mode;                    /* SLOT_FILE: OPENCHAN_* */
    int32_t  owner;                   /* the pid that called pipechan */
    /* SLOT_FIFO only, and the whole of the EOF story: has a real read end /
     * a real write end ever been opened by the process that owns it?  When
     * both are set the creator's keeper has done its job and is closed. */
    uint32_t rever;
    uint32_t wever;
    uint32_t done;                    /* the keeper has been dropped */
    uint32_t bound;                   /* some /fd name has pointed here */
    char     path[PATH_CAP];
};

/* bindrec.used: 0 free, BIND_RESERVED claimed but not yet filled in,
 * BIND_LIVE a complete record. The middle state exists because two processes
 * allocate from this table at once -- a shell binding a child's names and
 * that child binding its own -- and "scan for a zero, then fill it in" let
 * both pick the SAME record and the second overwrite the first. The loser's
 * /fd name then resolved to its inherited descriptor: the stage wrote to the
 * console and the next stage waited for a writer for ever. Claiming with a
 * compare-and-swap and publishing afterwards is what makes the claim
 * exclusive. */
#define BIND_RESERVED 2u
#define BIND_LIVE     1u

struct bindrec {
    uint32_t used;
    int32_t  pid;
    int32_t  fdnum;
    int32_t  kind;
    int32_t  slot;
    /* WHEN this record was written, on the segment's own clock.  It tells
     * "a record the last occupant of this pid left behind" from "a record
     * written since the fork" -- which is what fdns_after_fork_parent now
     * ASSERTS about rather than acts on, the clearing itself having moved to
     * fdns_before_fork where it cannot race the child. */
    uint64_t seq;
};

struct fdshm {
    uint32_t magic;
    int32_t  next_slot;
    uint64_t next_seq;
    struct slotrec slot[MAX_SLOTS];
    struct bindrec bind[MAX_BINDS];
};

static struct fdshm *shm;

/* Keeper descriptors are PER PROCESS, deliberately: see the header comment.
 * Indexed by slot id modulo MAX_SLOTS. */
static int keeper[MAX_SLOTS];
static int keeper_init;
/* How many of them are still open here.  Zero is the overwhelmingly common
 * case (every process that never made a pipe), and it is what makes the
 * sweep free to call from a hot syscall path. */
static int keeper_live;

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
    /* Same umask story as the fifos below, with a worse failure mode. The
     * segment is created by whoever attaches FIRST -- PID 1, uid 0 -- so it
     * lands 0644; a process running as the logged-in user then fails the
     * O_RDWR open and FALLS THROUGH to the /tmp candidate, quietly getting a
     * PRIVATE, EMPTY /fd registry instead of the system one. Not an error
     * anywhere: just a task whose pipes nobody else can see. fchmod is
     * unconditional and its failure ignored -- a non-creator is not the owner
     * and does not need to succeed. */
    if (fchmod(fd, 0666) < 0) { /* not the creator; the mode is already set */ }

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
        if (shm->bind[i].used == BIND_LIVE && shm->bind[i].pid == pid
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

/* HAMFDNS_DEBUG=1 traces /fd resolution and keeper lifetime to stderr. */
static int fdns_dbg_on(void)
{
    static int on = -1;
    if (on < 0) { const char *e = getenv("HAMFDNS_DEBUG"); on = (e && *e) ? 1 : 0; }
    return on;
}

static void fdns_note(const char *msg)
{
    char m[192];
    int n = snprintf(m, sizeof m, "[fdns] pid=%d %s\n", (int)getpid(), msg);
    ssize_t ignored = write(2, m, (size_t)(n < 0 ? 0 : n));
    (void)ignored;
}

/* ------------------------------------------------------------------ *
 * THE KEEPER'S LIFETIME -- see the long note at the top of this file.
 *
 * A keeper is an O_RDWR descriptor, so while it is open the fifo has a
 * writer AND a reader and NEITHER end can ever finish: no EOF for the
 * reader, no EPIPE for the writer.  It exists only to carry the slot across
 * the window between "the pipe was created" and "both real ends are open",
 * and it is closed the moment that window shuts.
 * ------------------------------------------------------------------ */
static void keeper_close(int i)
{
    if (keeper[i] < 0) return;
    close(keeper[i]);
    keeper[i] = -1;
    if (keeper_live > 0) keeper_live--;
    if (shm && shm->slot[i].used) shm->slot[i].done = 1;
    if (fdns_dbg_on()) {
        char m[128];
        snprintf(m, sizeof m, "keeper closed slot=%d", i + 1);
        fdns_note(m);
    }
}

void fdns_keeper_sweep(int wait_ms)
{
    if (!keeper_init || keeper_live <= 0) return;
    if (!shm && attach() < 0) return;

    int waited = 0;
    for (;;) {
        int pending = 0;
        for (int i = 0; i < MAX_SLOTS; i++) {
            if (keeper[i] < 0) continue;
            struct slotrec *s = &shm->slot[i];
            if (!s->used || s->kind != SLOT_FIFO) { keeper_close(i); continue; }
            if (s->rever && s->wever) { keeper_close(i); continue; }
            pending = 1;
        }
        if (!pending || keeper_live <= 0) return;
        if (waited >= wait_ms) break;
        usleep(1000);
        waited++;
    }

    /* The bound expired with one end still unopened.  Drop the keeper anyway:
     * a pipeline that hangs for ever is a worse answer than one that ends.
     * The two ways to get here are worth telling apart in a trace --
     *
     *   wever && !rever : bytes were written that nobody ever opened to read.
     *                     Closing here is what delivers EPIPE to the writer.
     *   !wever          : nothing was ever written, so nothing is lost.
     */
    for (int i = 0; i < MAX_SLOTS; i++) {
        if (keeper[i] < 0) continue;
        if (fdns_dbg_on()) {
            char m[160];
            snprintf(m, sizeof m,
                     "keeper timeout slot=%d rever=%u wever=%u -- dropping",
                     i + 1, shm->slot[i].rever, shm->slot[i].wever);
            fdns_note(m);
        }
        keeper_close(i);
    }
}

/* Reclaim slots.  Nothing ever freed one, so the table was a 64-entry budget
 * for the LIFETIME OF THE SEGMENT -- shared by every pipe AND every shell
 * redirect, both of which allocate here.  hamsh is PID 1, so "the owner
 * exited" never reclaimed anything either: the 65th redirect of a boot got
 * ENOSPC for ever.  Called only when allocation is about to fail, so the
 * normal path pays nothing for it. */
static int pid_alive(int32_t pid)
{
    if (pid <= 0) return 0;
    return kill((pid_t)pid, 0) == 0 || errno != ESRCH;
}

static int slot_referenced(int32_t slot)
{
    for (int i = 0; i < MAX_BINDS; i++) {
        struct bindrec *b = &shm->bind[i];
        if (b->used != BIND_LIVE || b->slot != slot) continue;
        if (b->kind == FDNS_NONE) continue;
        if (pid_alive(b->pid)) return 1;
    }
    return 0;
}

/* Reclaim the /fd NAMES of processes that no longer exist.
 *
 * This table leaked as badly as the slot table and hurt sooner.  A record is
 * keyed by pid, and the only thing that ever cleared one was a new child
 * LANDING ON THE SAME PID -- but pids climb, so a boot's binds accumulated
 * about eight per spawned command until all 512 were used.  From then on
 * fdns_fdbind returned ENOSPC, hamsh ignored it, and a pipeline stage's
 * /fd/1 simply never got bound: the writer wrote to its inherited console
 * and the reader waited for a writer that was never going to open the pipe.
 * Measured as a boot that ran 36 pipelines in under a second and then hung
 * for ever on the 37th, which is a far worse shape than an error.
 *
 * Returns the number of records reclaimed. */
static int bind_gc(void)
{
    int freed = 0;
    for (int i = 0; i < MAX_BINDS; i++)
        /* Only complete records. A RESERVED one belongs to a process that is
         * mid-bind right now and is nobody's to take. */
        if (shm->bind[i].used == BIND_LIVE && !pid_alive(shm->bind[i].pid)) {
            shm->bind[i].used = 0;
            freed++;
        }
    return freed;
}

static void slot_gc(void)
{
    /* Dead pids first: their bindings are what keep slots referenced. */
    bind_gc();

    for (int i = 0; i < MAX_SLOTS; i++) {
        struct slotrec *s = &shm->slot[i];
        if (!s->used) continue;
        if (keeper[i] >= 0) continue;            /* still ours and still live */
        /* Never take a slot that has been minted but not yet bound: hamsh
         * calls sys_openchan/sys_pipechan and sys_fdbind as two steps, and
         * collecting in between would hand the same number to two things. */
        if (!s->bound) continue;
        int owner_gone = !pid_alive(s->owner);
        int spent = (s->kind == SLOT_FIFO) ? (s->done != 0) : 1;
        if (!owner_gone && !spent) continue;
        if (slot_referenced((int32_t)(i + 1))) continue;
        if (s->kind == SLOT_FIFO && s->path[0]) unlink(s->path);
        memset(s, 0, sizeof *s);
    }
}

/* A free slot index, or -1.  Runs the collector once before giving up: an
 * ENOSPC here is a shell that can no longer pipe or redirect at all. */
static int slot_alloc(void)
{
    for (int pass = 0; pass < 2; pass++) {
        for (int i = 0; i < MAX_SLOTS; i++)
            if (!shm->slot[i].used) {
                memset(&shm->slot[i], 0, sizeof shm->slot[i]);
                return i;
            }
        if (pass == 0) slot_gc();
    }
    return -1;
}

/* THE SPAWN GATE.
 *
 * The Plan 9 contract is: parent forks, parent binds the child's /fd names,
 * child runs.  On Linux the child is runnable the instant fork(2) returns, so
 * it can reach open("/fd/1") before the bind lands -- and then it silently
 * uses its inherited stdout.  That is not a corner case: it is EVERY shell
 * redirect.  `ls > file` created the file, ran, exited 0, and printed to the
 * console, with no diagnostic anywhere.
 *
 * Waiting a fixed time in the child would tax every spawn that has no
 * redirect, so instead the fork itself opens a GATE, and the child waits on
 * it.  The parent closes the gate when it forks and opens it at its next
 * runtime call that is NOT a bind -- because that is precisely the moment it
 * has finished binding.  No timer, no guess: the ordering the cooperative
 * scheduler used to provide is reconstructed from what the parent does.
 *
 * The timeout is a backstop for a parent that never calls anything again.
 */
#define GATE_FD (-1)          /* a bindrec with this fdnum is a gate */

static int32_t pending_child;
static uint64_t fork_cut;

/* Called in the parent immediately BEFORE fork(2).
 *
 * THIS IS WHERE THE STALE NAMES GO, and the timing is the whole point. The
 * table is keyed by pid and Linux reuses pids, so a fresh process could
 * inherit a /fd/1 bound to a file some long-dead command was redirected
 * into. Measured: after `hpm update` spawned a few dozen children, the next
 * `uname` ran, exited 0 and printed nothing -- its stdout was a stale
 * binding pointing into a package's extraction path.
 *
 * That used to be cleaned up AFTER the fork, by pid, and it was a race the
 * whole time: a pipeline stage binds its OWN /fd/0 and /fd/1 the instant
 * rfork returns (hamsh and lib/p9.ad both do, deliberately, to close a
 * different race), and the child is runnable before the parent's next
 * instruction. So the clear sometimes deleted the binding the child had just
 * made, the stage ran with an unbound name, its output went to the inherited
 * console, and the next stage waited for a writer that never opened the
 * pipe. One run in thirty of tests/linux/fdns_pipe.sh, and no amount of
 * ordering or re-checking inside the clear can fix it: two processes were
 * writing one record with opposite intentions.
 *
 * Here there is no child to race. A pid can only be reused after its holder
 * has been reaped, so every record that a child-to-be could inherit belongs,
 * at this instant, to a pid that no longer exists -- which is exactly what
 * bind_gc reclaims. The cost is one pass with a kill(pid, 0) per live record
 * per fork, against a fork+exec that costs far more. */
void fdns_before_fork(void)
{
    if (attach() < 0) return;
    bind_gc();
    fork_cut = (uint64_t)shm->next_seq;
}

void fdns_after_fork_parent(int32_t child)
{
    if (attach() < 0) return;

    /* The child's stale names were already reclaimed, BEFORE the fork, by
     * fdns_before_fork -- see the long note there for why doing it here
     * raced the child's own binds and could not be made not to. Nothing to
     * clear; only the gate to close.
     *
     * A record for `child` that predates the fork can only exist if
     * before_fork was skipped (a fork that does not go through sys_rfork),
     * so say so rather than silently running with someone else's stdout. */
    for (int i = 0; i < MAX_BINDS; i++) {
        struct bindrec *b = &shm->bind[i];
        if (b->used == BIND_LIVE && b->pid == child && b->fdnum != GATE_FD
            && b->seq <= fork_cut) {
            fdns_note("stale /fd record survived a fork -- "
                      "was fdns_before_fork skipped?");
            break;
        }
    }

    fdns_fdbind(child, GATE_FD, FDNS_NONE, 0);   /* closed */
    pending_child = child;
}

void fdns_gate_release(void)
{
    if (!pending_child || !shm) return;
    struct bindrec *g = bind_find(pending_child, GATE_FD);
    if (g) g->kind = FDNS_CONS;                  /* any non-NONE = open */
    pending_child = 0;
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
#define BIND_WAIT_MS 150

static int parent_owns_slots(void)
{
    int32_t par = (int32_t)getppid();
    for (int i = 0; i < MAX_SLOTS; i++)
        if (shm->slot[i].used && shm->slot[i].owner == par)
            return 1;
    return 0;
}

/* Is this process one that was SPAWNED by a namespace-aware parent?
 *
 * Decided once, on the first /fd resolution, by waiting briefly for a gate to
 * appear.  It matters because the two cases want opposite things:
 *
 *   a spawned child  -- must wait, and must NOT trust a record it finds
 *                       before the gate exists, because the parent has not
 *                       cleared this pid's stale bindings yet;
 *   everyone else    -- binds its OWN names and expects them back
 *                       immediately (a terminal naming its end of a pipe).
 */
static int spawned_known, spawned;

static int is_spawned(int32_t pid)
{
    if (spawned_known) return spawned;
    for (int ms = 0; ms < 25; ms++) {
        if (bind_find(pid, GATE_FD)) { spawned = 1; break; }
        usleep(1000);
    }
    spawned_known = 1;
    return spawned;
}

static struct bindrec *await_bind(int32_t pid, int32_t fdnum)
{
    struct bindrec *gate = is_spawned(pid) ? bind_find(pid, GATE_FD) : NULL;
    int watch = (gate != NULL) || parent_owns_slots();
    if (!watch)
        return NULL;
    for (int ms = 0; ms < BIND_WAIT_MS; ms++) {
        struct bindrec *b = bind_find(pid, fdnum);
        if (b && b->kind != FDNS_NONE)
            return b;
        /* The parent has moved past its binds: whatever is here now is all
         * there is ever going to be. */
        if (gate && gate->kind != FDNS_NONE)
            return bind_find(pid, fdnum);
        usleep(1000);
    }
    return bind_find(pid, fdnum);
}

/* HAMFDNS_DEBUG=1 traces every /fd resolution to stderr. The failure mode
 * this exists for is silence: an unbound name falls back to the inherited
 * descriptor and the program works, just not where the caller meant. */
static void fdns_trace(const char *path, struct bindrec *b, int r)
{
    if (!fdns_dbg_on()) return;
    char m[192];
    int n = snprintf(m, sizeof m, "[fdns] pid=%d %s -> kind=%d slot=%d fd=%d\n",
                     (int)getpid(), path, b ? b->kind : -1,
                     b ? b->slot : -1, r);
    ssize_t ignored = write(2, m, (size_t)(n < 0 ? 0 : n));
    (void)ignored;
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

    /* A record found immediately is trustworthy ONLY if this process is not a
     * freshly spawned child -- for one of those, the parent may not have
     * cleared the previous occupant of this pid yet. */
    struct bindrec *b = NULL;
    if (!is_spawned(me))
        b = bind_find(me, fdnum);
    if (!b || b->kind == FDNS_NONE)
        b = await_bind(me, fdnum);
    if (!b || b->kind == FDNS_NONE) {
        /* Unbound: /fd/<n> IS this process's fd <n>. dup, not a path open --
         * it preserves the access mode, which /proc/self/fd cannot. */
        int r = dup(fdnum);
        if (r < 0) errno = EBADF;
        fdns_trace(path, b, r);
        return r;
    }
    if (b->kind == FDNS_DUP) {
        /* `2>&1`: bind whatever is at /fd/<slot>. Resolved by NAME, once,
         * rather than copied -- which is what makes it follow a later rebind
         * of the target the way the Plan 9 model says it should. */
        char alias[32];
        snprintf(alias, sizeof alias, "/fd/%d", (int)b->slot);
        return fdns_open(alias, for_write);
    }
    if (b->kind == FDNS_FILE || b->kind == FDNS_CHAN
        || b->kind == FDNS_APPEND) {
        /* A REDIRECT. The slot names a FILE, and the child opens it itself.
         *
         * It has to be a name. The first version passed the shell's own
         * descriptor number and let the child inherit it -- which is wrong in
         * a way that took a trace to see: hamsh opens the redirect target
         * AFTER the fork, so the number is valid only in the parent. The
         * child's dup() returned EBADF, the routing helper gave up quietly,
         * and every `cmd > file` ran with its inherited stdout. The file was
         * created and left empty; the output went to the console. Silent, and
         * success-shaped, which is this port's recurring failure.
         *
         * O_TRUNC is deliberately NOT repeated here: the shell already
         * truncated when it opened the target, and truncating again would
         * discard what an earlier stage of the same pipeline wrote. */
        struct slotrec *fs = slot_find(b->slot);
        if (!fs || fs->kind != SLOT_FILE) { errno = EBADF; fdns_trace(path, b, -1); return -1; }
        int flags = (fs->mode == 1) ? O_WRONLY | O_CREAT
                  : (fs->mode == 2) ? O_WRONLY | O_CREAT | O_APPEND
                                    : O_RDONLY;
        int r = open(fs->path, flags, 0666);
        fdns_trace(path, b, r);
        if (r < 0) { errno = EBADF; return -1; }
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
    int r = open(s->path, flags);
    /* A REAL end is now open, and the creator's keeper is one step closer to
     * being unnecessary.  Recorded on the SLOT, in shared memory, because the
     * process that must act on it (the creator, in fdns_keeper_sweep) is not
     * this one.  Monotonic on purpose: it answers "has this end ever been
     * opened", which is the only question the keeper's lifetime turns on. */
    if (r >= 0) {
        if (b->kind == FDNS_PIPE_W) s->wever = 1;
        else                        s->rever = 1;
    }
    fdns_trace(path, b, r);
    return r;
}

/* Record a redirect target as a SLOT. The path, not a descriptor: see the
 * note in fdns_open. The shell also opens it itself, so a target it cannot
 * create is an error at the redirect rather than a mystery in the child. */
int32_t fdns_openchan(const char *path, int32_t mode)
{
    if (attach() < 0) return -1;
    int flags = (mode == 1) ? O_WRONLY | O_CREAT | O_TRUNC
              : (mode == 2) ? O_WRONLY | O_CREAT | O_APPEND
                            : O_RDONLY;
    int probe = open(path, flags, 0666);
    if (probe < 0) return -1;
    close(probe);

    int i = slot_alloc();
    if (i < 0) { errno = ENOSPC; return -1; }
    int pn = snprintf(shm->slot[i].path, PATH_CAP, "%s", path);
    if (pn < 0 || pn >= PATH_CAP) {
        memset(&shm->slot[i], 0, sizeof shm->slot[i]);
        errno = ENAMETOOLONG;
        return -1;
    }
    shm->slot[i].used  = 1;
    shm->slot[i].kind  = SLOT_FILE;
    shm->slot[i].mode  = mode;
    shm->slot[i].owner = (int32_t)getpid();
    return (int32_t)(i + 1);
}

int32_t fdns_pipechan(void)
{
    if (attach() < 0) return -1;
    {
        int i = slot_alloc();
        if (i < 0) { errno = ENOSPC; return -1; }
        int32_t slot = (int32_t)(i + 1);
        int pn = snprintf(shm->slot[i].path, PATH_CAP, "%s/chan.%d.%d",
                          chan_dir(), (int)getpid(), (int)slot);
        if (pn < 0 || pn >= PATH_CAP) {
            /* A truncated path is a DIRECTORY name, and mkfifo on it returns
             * EEXIST -- i.e. it looks like it worked. Refuse instead. */
            memset(&shm->slot[i], 0, sizeof shm->slot[i]);
            errno = ENAMETOOLONG;
            return -1;
        }
        shm->slot[i].owner = (int32_t)getpid();
        shm->slot[i].kind  = SLOT_FIFO;
        unlink(shm->slot[i].path);
        if (mkfifo(shm->slot[i].path, 0666) < 0 && errno != EEXIST) {
            memset(&shm->slot[i], 0, sizeof shm->slot[i]);
            return -1;
        }
        /* mkfifo's mode argument is masked by the process umask, which the
         * kernel hands PID 1 as 022 -- so the fifo lands 0644 no matter what
         * is written above. That was invisible while EVERYTHING ran as one
         * uid. It stops being invisible the moment a session drops privilege
         * (etc/rc.de-user's `setuid 1001`): hamtermscene runs as the DE's uid
         * and creates the pipe pair, its inner shell runs as the LOGGED-IN
         * user and opens the write end of stdout -- 0644 denies that, and the
         * terminal comes up with a live shell whose every byte of output is
         * thrown away. An explicit chmod is the only way to get the mode the
         * call already asks for. These fifos are ephemeral per-pipe objects in
         * a 1777 tmpfs, exactly like /tmp: 0666 is their correct mode, not a
         * relaxation. */
        chmod(shm->slot[i].path, 0666);
        /* The keeper. Without it the first open of either end deadlocks --
         * see the header comment; this is not a convenience.  It is closed
         * again by fdns_keeper_sweep as soon as both real ends exist, which
         * is what gives the reader an EOF and the writer an EPIPE. */
        int k = open(shm->slot[i].path, O_RDWR | O_CLOEXEC);
        if (k < 0) {
            int e = errno;
            unlink(shm->slot[i].path);
            memset(&shm->slot[i], 0, sizeof shm->slot[i]);
            errno = e;
            return -1;
        }
        keeper[i] = k;
        keeper_live++;
        shm->slot[i].used = 1;
        return slot;
    }
}

int32_t fdns_fdbind(int32_t pid, int32_t fdnum, int32_t kind, int32_t slot)
{
    if (attach() < 0) return -1;
    if (pid == 0) pid = (int32_t)getpid();      /* 0 means "me" */

    uint64_t stamp = (uint64_t)__sync_add_and_fetch(&shm->next_seq, 1);

    struct bindrec *b = bind_find(pid, fdnum);
    if (!b) {
        /* CLAIM, then fill in, then publish. Two processes allocate here at
         * once -- a shell binding a child's names and that child binding its
         * own -- and a plain "find a zero and write into it" let both take
         * the same record, the second silently overwriting the first. */
        for (int pass = 0; pass < 2 && !b; pass++) {
            for (int i = 0; i < MAX_BINDS; i++)
                if (__sync_bool_compare_and_swap(&shm->bind[i].used,
                                                 0u, BIND_RESERVED)) {
                    b = &shm->bind[i];
                    break;
                }
            if (!b && pass == 0) bind_gc();
        }
        /* Still full, with every record belonging to a LIVE process. Say so:
         * the caller's next move is to run with an unbound /fd name, and
         * every one of those is a silent wrong destination. hamsh does not
         * check this return, so stderr is the only place it can be said. */
        if (!b) {
            fdns_note("/fd bind table full -- a name will go unbound");
            errno = ENOSPC;
            return -1;
        }
        b->pid   = pid;
        b->fdnum = fdnum;
        b->kind  = kind;
        b->slot  = slot;
        b->seq   = stamp;
        __sync_synchronize();
        b->used  = BIND_LIVE;         /* last: publishes a complete record */
        if (kind != FDNS_NONE) {
            struct slotrec *s = slot_find(slot);
            if (s) s->bound = 1;
        }
        return 0;
    }
    /* An existing record for this (pid, fdnum) is ours to rewrite: only the
     * process it names, or its parent between fork and exec, ever touches
     * it. */
    b->seq  = stamp;
    __sync_synchronize();
    b->kind = kind;
    b->slot = slot;
    if (kind != FDNS_NONE) {
        struct slotrec *s = slot_find(slot);
        if (s) s->bound = 1;
    }
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
    keeper_live = 0;
}
