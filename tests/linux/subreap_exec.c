/* tests/linux/subreap_exec.c — run a program as a CHILD SUBREAPER.
 *
 *     subreap_exec <prog> [args...]
 *
 * WHY THIS EXISTS.  user/linux-syscalls.c's reap_orphans() only runs in a
 * process that actually adopts orphans, which in production means PID 1.  A
 * gate could get PID 1 by running under `unshare --pid --fork`, and then it
 * would be measuring the reaper against a /proc holding a handful of
 * processes.  That is precisely the shape of test that has already called a
 * broken reader green in this tree: a 4096-byte directory read looked complete
 * on a guest with 40 processes and truncated three quarters of a real one.
 *
 * PR_SET_CHILD_SUBREAPER gives the same adoption semantics -- orphaned
 * descendants reparent HERE instead of to init -- on the host, with the host's
 * whole process table visible.  It survives execve and is inherited by
 * children, so setting it and then exec'ing the driver is enough.
 *
 * It is deliberately NOT the same mechanism as production.  The gate says so.
 * What it shares with production is the code under test: adopts_orphans()
 * returns 1 for both, and everything after that line is identical.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <sys/prctl.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    if (argc < 2) { fprintf(stderr, "usage: subreap_exec <prog> [args]\n"); return 2; }
    if (prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) != 0) {
        perror("prctl(PR_SET_CHILD_SUBREAPER)");
        return 3;                       /* never silently run un-adopted */
    }
    execv(argv[1], &argv[1]);
    perror("execv");
    return 127;
}
