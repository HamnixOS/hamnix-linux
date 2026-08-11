/* tests/linux/fdns_pipe.c -- the pipe plumbing under user/linux-fdns.c,
 * measured directly on the host.
 *
 * WHY THIS EXISTS
 * ===============
 * `cat FILE | md5sum` never returned, and it killed a boot
 * (docs/linux_installed_update.md §3).  The digest was not the problem: the
 * same md5sum answered two FILE operands correctly one line above.  What did
 * not finish was the PIPE'S EOF -- and EOF on a fifo means "the last writer
 * closed", while the shell that created the slot was still holding the
 * O_RDWR keeper, which is a writer.
 *
 * This gate reproduces that at the layer it lives in, without a VM, so the
 * question "does a pipeline end" is answerable in a second rather than a
 * boot.  Every case runs in a child under an alarm: a hang is a FAIL with a
 * name, never a test that runs for ever.
 *
 * The two ends are named in every assertion, because "which end did not
 * finish" is the whole diagnosis:
 *   - the READER never saw the close  -> a writer is still open (the keeper)
 *   - the WRITER never saw the close  -> a reader is still open (the keeper)
 *
 * Build/run: tests/linux/fdns_pipe.sh
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#include "linux-fdns.h"

static int pass_n, fail_n;

static void ok(int cond, const char *what)
{
    if (cond) { pass_n++; printf("PASS %s\n", what); }
    else      { fail_n++; printf("FAIL %s\n", what); }
    fflush(stdout);
}

/* Every case runs in its own process with an alarm, so a pipeline that never
 * ends costs one SIGALRM instead of the gate. */
#define CASE_TIMEOUT 10

static int run_case(int (*fn)(void), const char *name)
{
    fflush(stdout);
    pid_t p = fork();
    if (p == 0) {
        alarm(CASE_TIMEOUT);
        int r = fn();
        fflush(stdout);      /* _exit does not flush, and the diagnosis is
                              * printed by the case, not by the reaper. */
        _exit(r == 0 ? 0 : 1);
    }
    int st = 0;
    waitpid(p, &st, 0);
    if (WIFSIGNALED(st) && WTERMSIG(st) == SIGALRM) {
        fail_n++;
        printf("FAIL %s -- HUNG (no progress in %d s)\n", name, CASE_TIMEOUT);
        fflush(stdout);
        return 1;
    }
    if (!WIFEXITED(st) || WEXITSTATUS(st) != 0) {
        fail_n++;
        printf("FAIL %s -- case exited abnormally (status %d)\n", name, st);
        fflush(stdout);
        return 1;
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* The shape of a hamsh pipeline stage: bind the end at our own /fd name,
 * open that name, use it.  lib/p9.ad does exactly this before exec. */
static int stage_open(int fdnum, int32_t slot, int kind)
{
    fdns_fdbind(0, fdnum, kind, slot);
    char name[32];
    snprintf(name, sizeof name, "/fd/%d", fdnum);
    return fdns_open(name, kind == FDNS_PIPE_W);
}

/* Did /fd/<n> actually resolve to the pipe, or did it fall back to the
 * INHERITED descriptor?  That fallback is silent by design -- an unbound /fd
 * name is the caller's own fd -- so a stage whose binding was lost writes its
 * output to the console and the next stage waits for a writer for ever.  The
 * only honest check is the inode: the slot's fifo is a file with a name.
 * (The creator is this process's parent, which is how the name is derived.) */
static int fd_is_slot(int fd, int32_t slot)
{
    const char *dir = getenv("HAMFDNS_DIR");
    if (!dir || !*dir) dir = "/srv";
    char path[256];
    snprintf(path, sizeof path, "%s/chan.%d.%d", dir, (int)getppid(), (int)slot);
    struct stat a, b;
    int fa = fstat(fd, &a), fb = stat(path, &b);
    if (fa == 0 && fb == 0 && a.st_dev == b.st_dev && a.st_ino == b.st_ino)
        return 1;
    fprintf(stderr, "     [fd_is_slot] pid=%d fd=%d slot=%d path=%s "
                    "fstat=%d stat=%d fdmode=%o bind_kind=%d\n",
            (int)getpid(), fd, (int)slot, path, fa, fb,
            fa == 0 ? (unsigned)(a.st_mode & S_IFMT) : 0,
            (int)fdns_slot_kind(0, fd == 1 ? 1 : 0));
    fflush(stderr);
    return 0;
}

static pid_t fork_writer(int32_t slot, size_t nbytes, int *epipe_out)
{
    fdns_before_fork();
    pid_t p = fork();
    if (p != 0) { fdns_after_fork_parent((int32_t)p); fdns_gate_release(); return p; }
    fdns_after_fork_child();
    signal(SIGPIPE, SIG_IGN);           /* report EPIPE rather than die on it */
    int fd = stage_open(1, slot, FDNS_PIPE_W);
    if (fd < 0) _exit(3);
    if (!fd_is_slot(fd, slot)) _exit(43);   /* 43 == the binding was lost */
    static char blk[4096];
    memset(blk, 'a', sizeof blk);
    size_t sent = 0;
    int hit_epipe = 0;
    while (sent < nbytes) {
        size_t want = nbytes - sent;
        if (want > sizeof blk) want = sizeof blk;
        ssize_t n = write(fd, blk, want);
        if (n < 0) {
            if (errno == EPIPE) { hit_epipe = 1; break; }
            _exit(4);
        }
        sent += (size_t)n;
    }
    close(fd);
    (void)epipe_out;
    _exit(hit_epipe ? 42 : 0);          /* 42 == "the writer saw the close" */
}

static pid_t fork_reader(int32_t slot, size_t expect, size_t read_only)
{
    fdns_before_fork();
    pid_t p = fork();
    if (p != 0) { fdns_after_fork_parent((int32_t)p); fdns_gate_release(); return p; }
    fdns_after_fork_child();
    int fd = stage_open(0, slot, FDNS_PIPE_R);
    if (fd < 0) _exit(3);
    if (!fd_is_slot(fd, slot)) _exit(43);
    static char buf[8192];
    size_t total = 0;
    for (;;) {
        if (read_only && total >= read_only) break;   /* leave early */
        ssize_t n = read(fd, buf, sizeof buf);
        if (n < 0) _exit(4);
        if (n == 0) break;                            /* EOF: the close */
        total += (size_t)n;
    }
    if (read_only) _exit(0);
    _exit(total == expect ? 0 : 5);
}

/* Name what a stage did, rather than reporting "the case returned 1". The
 * exit codes are the diagnosis: 43 is "this stage's /fd name did not resolve
 * to the pipe", 5 is "it read the wrong number of bytes", 42 is EPIPE. */
static const char *why(int st)
{
    static char s[64];
    if (WIFSIGNALED(st)) {
        snprintf(s, sizeof s, "killed by signal %d", WTERMSIG(st));
        return s;
    }
    if (!WIFEXITED(st)) return "did not exit";
    switch (WEXITSTATUS(st)) {
    case 0:  return "ok";
    case 3:  return "could not open its /fd name";
    case 4:  return "read/write error";
    case 5:  return "wrong byte count";
    case 42: return "took EPIPE";
    case 43: return "its /fd name did not resolve to the pipe";
    }
    snprintf(s, sizeof s, "exit %d", WEXITSTATUS(st));
    return s;
}

static int stages_ok(const char *what, int s1, int s2, int s3)
{
    int bad = 0;
    if (!WIFEXITED(s1) || WEXITSTATUS(s1) != 0) {
        printf("     %s: stage 1 %s\n", what, why(s1)); bad = 1;
    }
    if (!WIFEXITED(s2) || WEXITSTATUS(s2) != 0) {
        printf("     %s: stage 2 %s\n", what, why(s2)); bad = 1;
    }
    if (!WIFEXITED(s3) || WEXITSTATUS(s3) != 0) {
        printf("     %s: stage 3 %s\n", what, why(s3)); bad = 1;
    }
    return bad;
}

/* ------------------------------------------------------------------ */
/* 1. THE BUG. Writer writes and exits; reader must drain and see EOF. */
static int case_eof(void)
{
    int32_t slot = fdns_pipechan();
    if (slot < 0) return 1;
    pid_t w = fork_writer(slot, 15, NULL);
    pid_t r = fork_reader(slot, 15, 0);
    fdns_keeper_sweep(FDNS_KEEPER_WAIT_MS);      /* what sys_waitpid does */
    int sw = 0, sr = 0;
    waitpid(w, &sw, 0);
    waitpid(r, &sr, 0);
    return (WIFEXITED(sw) && WEXITSTATUS(sw) == 0
            && WIFEXITED(sr) && WEXITSTATUS(sr) == 0) ? 0 : 1;
}

/* 2. The bytes actually arrive. A pipeline that ends but delivers nothing is
 *    the OTHER failure -- dropping the keeper outright produces exactly it,
 *    because the fifo's buffer dies with its last open descriptor. */
static int case_payload(void)
{
    int32_t slot = fdns_pipechan();
    if (slot < 0) return 1;
    /* Writer first and given a head start, so it can finish and exit before
     * the reader has opened: the case where a naive fix loses the data. */
    pid_t w = fork_writer(slot, 4096, NULL);
    usleep(120 * 1000);
    pid_t r = fork_reader(slot, 4096, 0);
    fdns_keeper_sweep(FDNS_KEEPER_WAIT_MS);
    int sw = 0, sr = 0;
    waitpid(w, &sw, 0);
    waitpid(r, &sr, 0);
    return (WIFEXITED(sr) && WEXITSTATUS(sr) == 0) ? 0 : 1;
}

/* 3. More than one pipe buffer: the writer blocks and is unblocked by the
 *    reader, and the total still matches. */
static int case_big(void)
{
    int32_t slot = fdns_pipechan();
    if (slot < 0) return 1;
    size_t n = 1u << 20;
    pid_t w = fork_writer(slot, n, NULL);
    pid_t r = fork_reader(slot, n, 0);
    fdns_keeper_sweep(FDNS_KEEPER_WAIT_MS);
    int sw = 0, sr = 0;
    waitpid(w, &sw, 0);
    waitpid(r, &sr, 0);
    return (WIFEXITED(sw) && WEXITSTATUS(sw) == 0
            && WIFEXITED(sr) && WEXITSTATUS(sr) == 0) ? 0 : 1;
}

/* 4. THE OTHER END. The reader leaves early; the writer must see the close
 *    (EPIPE) rather than fill the pipe and block for ever. `cat big | head`. */
static int case_epipe(void)
{
    int32_t slot = fdns_pipechan();
    if (slot < 0) return 1;
    pid_t w = fork_writer(slot, 8u << 20, NULL);
    pid_t r = fork_reader(slot, 0, 4096);        /* reads a little, exits */
    fdns_keeper_sweep(FDNS_KEEPER_WAIT_MS);
    int sw = 0, sr = 0;
    waitpid(r, &sr, 0);
    waitpid(w, &sw, 0);
    return (WIFEXITED(sw) && WEXITSTATUS(sw) == 42) ? 0 : 1;
}

/* 5. `{ cmd }` -- the CREATOR is the reader. The keeper and the real read end
 *    are then held by the same process, which is the shape that made command
 *    substitution unable to end either. */
static int case_capture(void)
{
    int32_t slot = fdns_pipechan();
    if (slot < 0) return 1;
    int rfd = stage_open(9, slot, FDNS_PIPE_R);
    if (rfd < 0) return 1;
    pid_t w = fork_writer(slot, 4096, NULL);
    size_t total = 0;
    static char buf[8192];
    for (;;) {
        fdns_keeper_sweep(FDNS_KEEPER_WAIT_MS);   /* what sys_read does */
        ssize_t n = read(rfd, buf, sizeof buf);
        if (n <= 0) break;
        total += (size_t)n;
    }
    close(rfd);
    int sw = 0;
    waitpid(w, &sw, 0);
    return total == 4096 ? 0 : 1;
}

/* 6. Three stages. Each middle stage is both ends of two different slots. */
static int case_three_stage(void)
{
    int32_t a = fdns_pipechan();
    int32_t b = fdns_pipechan();
    if (a < 0 || b < 0) return 1;

    pid_t p1 = fork_writer(a, 4096, NULL);

    fdns_before_fork();
    pid_t p2 = fork();
    if (p2 == 0) {
        fdns_after_fork_child();
        int in  = stage_open(0, a, FDNS_PIPE_R);
        int out = stage_open(1, b, FDNS_PIPE_W);
        if (in < 0 || out < 0) _exit(3);
        if (!fd_is_slot(in, a) || !fd_is_slot(out, b)) _exit(43);
        static char buf[8192];
        for (;;) {
            ssize_t n = read(in, buf, sizeof buf);
            if (n < 0) _exit(4);
            if (n == 0) break;
            if (write(out, buf, (size_t)n) != n) _exit(5);
        }
        close(in);
        close(out);
        _exit(0);
    }
    fdns_after_fork_parent((int32_t)p2);
    fdns_gate_release();

    pid_t p3 = fork_reader(b, 4096, 0);
    fdns_keeper_sweep(FDNS_KEEPER_WAIT_MS);
    int s1 = 0, s2 = 0, s3 = 0;
    waitpid(p1, &s1, 0);
    waitpid(p2, &s2, 0);
    waitpid(p3, &s3, 0);
    return stages_ok("three-stage", s1, s2, s3);
}

/* 7. The slot table is 64 entries and nothing ever freed one, so a shell
 *    that is PID 1 got ENOSPC on its 65th pipe OR REDIRECT and never
 *    recovered. Run three tables' worth. */
static int case_slot_reuse(void)
{
    for (int i = 0; i < 200; i++) {
        int32_t slot = fdns_pipechan();
        if (slot < 0) {
            printf("     ran out of pipe slots after %d\n", i);
            return 1;
        }
        pid_t w = fork_writer(slot, 32, NULL);
        pid_t r = fork_reader(slot, 32, 0);
        fdns_keeper_sweep(FDNS_KEEPER_WAIT_MS);
        int sw = 0, sr = 0;
        waitpid(w, &sw, 0);
        waitpid(r, &sr, 0);
        if ((WIFEXITED(sw) && WEXITSTATUS(sw) == 43)
            || (WIFEXITED(sr) && WEXITSTATUS(sr) == 43)) {
            printf("     iteration %d: a stage's /fd name did not resolve to"
                   " the pipe (the parent's stale-bind clear raced it)\n", i);
            return 1;
        }
        if (!WIFEXITED(sr) || WEXITSTATUS(sr) != 0) {
            printf("     iteration %d lost its payload\n", i);
            return 1;
        }
    }
    return 0;
}

int main(void)
{
    struct { int (*fn)(void); const char *name; } cases[] = {
        { case_eof,        "pipe: the reader sees EOF when the writer closes" },
        { case_payload,    "pipe: a writer that finishes first still delivers its bytes" },
        { case_big,        "pipe: 1 MiB crosses and both ends finish" },
        { case_epipe,      "pipe: the writer sees EPIPE when the reader leaves early" },
        { case_capture,    "pipe: the creator can read its own pipe to EOF ({ cmd })" },
        { case_three_stage,"pipe: a three-stage pipeline ends" },
        { case_slot_reuse, "pipe: 200 pipes on a 64-slot table" },
    };
    int n = (int)(sizeof cases / sizeof cases[0]);
    for (int i = 0; i < n; i++)
        if (run_case(cases[i].fn, cases[i].name) == 0)
            ok(1, cases[i].name);

    printf("\n%d PASS, %d FAIL\n", pass_n, fail_n);
    return fail_n ? 1 : 0;
}
