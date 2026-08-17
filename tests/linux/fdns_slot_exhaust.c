/* tests/linux/fdns_slot_exhaust.c -- WHEN DOES A REDIRECT STOP APPLYING?
 *
 * WHAT THIS IS FOR
 * ================
 * tests/linux/soak_desktop.sh drove a desktop for half an hour and found that
 * after 16m48s -- 118 launch cycles -- `ls /etc > /dev/null` started printing
 * /etc TO THE CONSOLE while the loop kept perfect 1/s rhythm.  The redirect
 * silently stopped applying, system-wide, with no diagnostic anywhere.  That
 * took seventeen minutes and a VM to reach.  This reaches it in a second, at
 * the layer the resource actually lives in.
 *
 * THE MODEL, AND WHY IT IS THE DESKTOP'S SHAPE AND NOT AN ARBITRARY LOOP
 * ---------------------------------------------------------------------
 * The soak launched four applications in rotation --
 *   hamcalcscene, hamnotesscene, hammonscene, HAMTERMSCENE
 * -- one every 8 s, and CLOSED THE WINDOW rather than the program (`close
 * <wid>` on /dev/wsys/ctl clears the window record only), so every launched
 * program stayed alive for the rest of the run.
 *
 * Of those four, exactly one allocates from the /fd slot table:
 * user/hamtermscene.ad::_start_shell calls sys_pipechan() TWICE (:865, :868),
 * binds both ends at its own /fd names (:871-872) and spawns an inner hamsh
 * that also holds them.  Two slots per terminal, pinned by TWO live processes
 * for as long as the terminal lives -- and user/linux-fdns.c's slot_gc() will
 * not reclaim a slot that slot_referenced() finds bound to a LIVE pid.
 *
 * So this harness launches long-lived "apps" in the same 1-in-4 rotation, has
 * the terminal ones take two pipe slots and keep them, and after every launch
 * runs ONE REDIRECT END TO END, exactly as hamsh's _wire_redirects does:
 *
 *     fslot = fdns_openchan(target, TRUNC)
 *     if (fslot >= 0) fdns_fdbind(child, 1, FDNS_FILE, fslot)
 *     child: fd = fdns_open("/fd/1", 1); write(fd, MARK)
 *
 * and then asks the only question that matters: DID THE BYTES LAND IN THE
 * FILE, OR ON THE INHERITED DESCRIPTOR?  The child's inherited fd 1 is a pipe
 * this process holds, which is this harness's "console".  A marker arriving
 * there is the soak's `/etc` on the console, reproduced.
 *
 * WHAT IT PRINTS
 * --------------
 * One line per launch: the occupancy of BOTH shared tables (slots and binds,
 * with their ceilings) and where the marker went.  That is the curve, and the
 * first line whose verdict is CONSOLE is the exact point of failure.  Two
 * tables are printed because two of them could explain the symptom and the
 * brief asked which one it actually is: a full BIND table produces the same
 * silence by a different route (fdns_fdbind returns -1 and hamsh ignores it).
 *
 * Build/run: tests/linux/fdns_slot_exhaust.sh
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

#define OPENCHAN_TRUNC 1

/* hamtermscene's own scratch /fd names for the two ends it holds. */
#define TERM_IN_FD  10
#define TERM_OUT_FD 11

#define MAX_APPS 512

static pid_t app[MAX_APPS];
static int   napps;

static char workdir[512];

static int pass_n, fail_n;

static void ok(int cond, const char *what)
{
    if (cond) { pass_n++; printf("  PASS  %s\n", what); }
    else      { fail_n++; printf("  FAIL  %s\n", what); }
    fflush(stdout);
}

static void reap_apps(void)
{
    for (int i = 0; i < napps; i++)
        if (app[i] > 0) kill(app[i], SIGKILL);
    for (int i = 0; i < napps; i++)
        if (app[i] > 0) waitpid(app[i], NULL, 0);
    napps = 0;
}

/* A launched application that never exits.  `is_term` reproduces
 * hamtermscene::_start_shell: two pipe slots, both bound at its own names,
 * plus a live inner shell that also holds them. */
static void launch_app(int is_term)
{
    fdns_before_fork();
    pid_t p = fork();
    if (p < 0) { perror("fork"); exit(2); }
    if (p == 0) {
        fdns_after_fork_child();
        if (is_term) {
            int32_t in_slot  = fdns_pipechan();
            int32_t out_slot = fdns_pipechan();
            if (in_slot > 0)  fdns_fdbind(0, TERM_IN_FD,  FDNS_PIPE_W, in_slot);
            if (out_slot > 0) fdns_fdbind(0, TERM_OUT_FD, FDNS_PIPE_R, out_slot);
            /* The inner hamsh: a second live process holding the same two
             * slots at its /fd/0 and /fd/1.  It is what makes the pin
             * outlive even this process. */
            fdns_before_fork();
            pid_t sh = fork();
            if (sh == 0) {
                fdns_after_fork_child();
                if (in_slot > 0)  fdns_fdbind(0, 0, FDNS_PIPE_R, in_slot);
                if (out_slot > 0) fdns_fdbind(0, 1, FDNS_PIPE_W, out_slot);
                for (;;) pause();
            }
            fdns_after_fork_parent((int32_t)sh);
            fdns_gate_release();
        }
        for (;;) pause();
    }
    fdns_after_fork_parent((int32_t)p);
    fdns_gate_release();
    if (napps < MAX_APPS) app[napps++] = p;
}

/* One `cmd > file`, run the way hamsh's _wire_redirects runs it.
 *
 * Returns 0 if the marker landed in the FILE, 1 if it landed on the child's
 * inherited descriptor (the console), 2 if it landed nowhere.
 * `*saw_fslot` / `*saw_bind` report which of the two calls failed, so the
 * verdict can be attributed to a table rather than guessed at. */
static int redirect_once(int n, int *saw_fslot, int *saw_bind, int *child_st)
{
    char target[600];
    snprintf(target, sizeof target, "%s/out.%d", workdir, n);
    char mark[64];
    int marklen = snprintf(mark, sizeof mark, "MARK%d\n", n);

    int cons[2];
    if (pipe(cons) < 0) { perror("pipe"); exit(2); }
    /* THE EXECVE WINDOW, modelled.  hamsh opens its redirect targets AFTER
     * the fork, and its own comment says why that is survivable: "the child
     * must execve before it can write, which is a far wider window than a
     * pipe stage's".  There is no execve here, so the child would otherwise
     * win every race and this gate would measure scheduling rather than the
     * table.  `go` is that window: the child does not touch /fd/1 until the
     * parent has finished deciding.  A CLOSED go pipe means "the redirect was
     * refused, do not run" -- which is what killing the child amounts to on
     * the far side of an execve. */
    int go[2];
    if (pipe(go) < 0) { perror("pipe"); exit(2); }

    fdns_before_fork();
    pid_t p = fork();
    if (p < 0) { perror("fork"); exit(2); }
    if (p == 0) {
        /* The child of a spawn: its inherited fd 1 is the console. */
        fdns_after_fork_child();
        close(cons[0]);
        dup2(cons[1], 1);
        close(cons[1]);
        close(go[1]);
        char g;
        if (read(go[0], &g, 1) != 1) _exit(5);   /* refused: never ran */
        close(go[0]);
        /* hamsh's children reach their stdout BY NAME.  An unbound /fd/1 is
         * a dup of the inherited descriptor -- which is the whole silence. */
        int fd = fdns_open("/fd/1", 1);
        if (fd < 0) _exit(3);           /* the NAME did not resolve at all */
        ssize_t w = write(fd, mark, (size_t)marklen);
        _exit(w == marklen ? 0 : 4);    /* the name resolved and the write failed */
    }
    close(cons[1]);
    close(go[0]);
    fdns_after_fork_parent((int32_t)p);      /* closes the spawn gate */

    /* THE PARENT SIDE -- user/hamsh.ad::_wire_redirects.
     *
     * MODEL_HEAD_HAMSH is the shell as it stood at 6d183262: `if fslot >= 0:`
     * with no else, and sys_fdbind's return unchecked.  A failure there is a
     * skipped bind and NOTHING SAID, and the child runs anyway.  Without it,
     * this is the shell as it stands now: a redirect that cannot be applied
     * kills the command instead of running it somewhere else. */
    int32_t fslot = fdns_openchan(target, OPENCHAN_TRUNC);
    int bindrc = -1;
    if (fslot >= 0)
        bindrc = (int)fdns_fdbind((int32_t)p, 1, FDNS_FILE, fslot);
    fdns_gate_release();                     /* the binds are done */

    *saw_fslot = (fslot >= 0);
    *saw_bind  = (bindrc == 0);

    int refused = 0;
#ifndef MODEL_HEAD_HAMSH
    if (fslot < 0 || bindrc != 0) refused = 1;
#endif
    if (refused) { close(go[1]); kill(p, SIGKILL); }
    else         { ssize_t gw = write(go[1], "g", 1); (void)gw; close(go[1]); }

    int st = 0;
    waitpid(p, &st, 0);
    if (refused) {
        close(cons[0]);
        *child_st = 0;
        return 3;
    }
    *child_st = WIFEXITED(st) ? WEXITSTATUS(st) : -1;

    char buf[256];
    ssize_t got = read(cons[0], buf, sizeof buf);
    close(cons[0]);

    struct stat sb;
    int in_file = (stat(target, &sb) == 0 && sb.st_size >= marklen);

    if (in_file) return 0;
    if (got > 0)  return 1;
    return 2;
}

/* ------------------------------------------------------------------ */
int main(void)
{
    const char *w = getenv("FDNS_EXHAUST_DIR");
    snprintf(workdir, sizeof workdir, "%s", w && *w ? w : "/tmp");

    int launches = 400;
    const char *lv = getenv("FDNS_EXHAUST_LAUNCHES");
    if (lv && *lv) launches = atoi(lv);

    int32_t cap_slots = 0, cap_binds = 0;
    fdns_occupancy(NULL, &cap_slots, NULL, &cap_binds);
    printf("== the /fd tables: %d slots, %d binds, both process-shared\n",
           (int)cap_slots, (int)cap_binds);
    printf("== one launch per line; every 4th is a terminal (2 pipe slots, kept)\n");
    printf("%6s %6s %12s %12s  %s\n",
           "launch", "terms", "slots", "binds", "where the redirect's bytes went");

    int first_fail = -1, first_fail_slots = -1, first_fail_binds = -1;
    int first_fail_openchan = -1, first_fail_bind = -1;
    int terms = 0;
    int console_hits = 0;

    for (int n = 1; n <= launches; n++) {
        int is_term = (n % 4 == 0);
        if (is_term) terms++;
        launch_app(is_term);

        int saw_fslot = 0, saw_bind = 0, child_st = 0;
        int verdict = redirect_once(n, &saw_fslot, &saw_bind, &child_st);

        int32_t su = 0, bu = 0;
        fdns_occupancy(&su, &cap_slots, &bu, &cap_binds);

        const char *vs = verdict == 0 ? "file (correct)"
                       : verdict == 1 ? "THE CONSOLE -- the redirect did not apply"
                       : child_st == 3 ? "NOWHERE -- /fd/1 did not resolve (open failed)"
                       : child_st == 4 ? "NOWHERE -- /fd/1 resolved and the write failed"
                       : verdict == 3 ? "nowhere -- REFUSED, and said so"
                       : child_st == 0 ? "NOWHERE -- the child wrote and the bytes "
                                         "are in neither place"
                                       : "nowhere (child died)";
        /* Print the head of the curve, every terminal launch, and every
         * failure: a 400-line dump is not a curve anyone reads. */
        if (n <= 8 || is_term || verdict != 0 || first_fail > 0)
            printf("%6d %6d %6d/%-5d %6d/%-5d  %s%s%s\n", n, terms,
                   (int)su, (int)cap_slots, (int)bu, (int)cap_binds, vs,
                   saw_fslot ? "" : "  [openchan returned -1]",
                   (saw_fslot && !saw_bind) ? "  [fdbind returned -1]" : "");
        fflush(stdout);

        if (verdict == 1) console_hits++;
        if (verdict != 0 && first_fail < 0) {
            first_fail = n;
            first_fail_slots = (int)su;
            first_fail_binds = (int)bu;
            first_fail_openchan = saw_fslot;
            first_fail_bind = saw_bind;
        }
        /* Ten failures is a curve past its knee; the rest is repetition. */
        if (first_fail > 0 && n - first_fail > 10) break;
    }

    printf("\n== VERDICT\n");
    if (first_fail < 0) {
        printf("  the redirect applied on all %d launches; slots and binds "
               "never ran out\n", launches);
    } else {
        printf("  first failure at launch %d, with %d/%d slots and %d/%d "
               "binds in use\n", first_fail, first_fail_slots, (int)cap_slots,
               first_fail_binds, (int)cap_binds);
        printf("  openchan %s, fdbind %s -- so the table that ran out is %s\n",
               first_fail_openchan ? "SUCCEEDED" : "returned -1",
               first_fail_bind ? "succeeded" : "returned -1 / not reached",
               first_fail_openchan ? "the BIND table" : "the SLOT table");
        printf("  redirects that went to the console instead: %d\n", console_hits);
    }

    /* ---- the assertions ---- */
    printf("\n== ASSERTIONS\n");
    ok(console_hits == 0,
       "a `cmd > file` NEVER writes to the inherited descriptor instead of "
       "the file");
    ok(first_fail < 0,
       "every one of the redirects applied, however many applications are open");

    reap_apps();
    printf("\n%d PASSED / %d FAILED\n", pass_n, fail_n);
    return fail_n ? 1 : 0;
}
