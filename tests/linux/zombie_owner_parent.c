/* tests/linux/zombie_owner_parent.c — MAKE A ZOMBIE THAT OWNS A WINDOW, and
 * keep it a zombie for as long as the gate needs it.
 *
 * WHY A SEPARATE PROGRAM.  A window's owner pid is stamped at `newwindow`, and
 * user/linux-wsys.c's win_reap_dead() is supposed to reclaim a window whose
 * owner has died.  The case that broke it is not "the owner is gone" but "the
 * owner is a CORPSE": exited, and still on the process table because nobody
 * has wait4'd it.  Producing that state needs a parent that deliberately does
 * NOT wait, and neither bash nor the hamnix shell will oblige — both reap
 * their children as a matter of course, at times they choose, so a gate built
 * on either would be measuring the shell's timing and not the reaper.
 *
 * So: fork, exec the window holder, kill it, and then sit still and wait for
 * nothing, for ever, until the gate is done and kills this process too.
 *
 *     zombie_owner_parent <wsys_hold> <script>
 *
 * Prints two lines and keeps stdout unbuffered so a shell can read them as
 * they happen:
 *
 *     OWNER <pid>          the holder's pid, before it is killed
 *     ZOMBIE <pid>         after SIGKILL and after /proc says state Z
 *
 * The second line is MEASURED, not assumed.  "I sent SIGKILL" is a fact about
 * this process; "the target is a corpse" is a fact about the world, and the
 * difference between those two is the entire subject of this gate.  If the
 * state never becomes Z the program says so and exits non-zero rather than let
 * the gate go green against a process that was never in the state under test.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* The state character of /proc/<pid>/stat, or 0.  Scans to the LAST ')'
 * because comm may contain spaces and parentheses. */
static char pstate(pid_t pid)
{
    char path[64], buf[512];
    snprintf(path, sizeof path, "/proc/%ld/stat", (long)pid);
    int fd = open(path, O_RDONLY);
    if (fd < 0) return 0;
    ssize_t n = read(fd, buf, sizeof buf - 1);
    close(fd);
    if (n <= 0) return 0;
    buf[n] = '\0';
    char *rp = strrchr(buf, ')');
    if (!rp || rp[1] != ' ') return 0;
    return rp[2];
}

int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr, "usage: zombie_owner_parent <wsys_hold> <script>\n");
        return 2;
    }
    setvbuf(stdout, NULL, _IONBF, 0);

    pid_t p = fork();
    if (p < 0) { perror("fork"); return 1; }
    if (p == 0) {
        /* The holder's own stdout carries the wid; the gate reads it from the
         * file this redirects to, not from ours, so the two streams cannot
         * interleave into an unparseable line. */
        int fd = open(getenv("ZOP_HOLDLOG") ? getenv("ZOP_HOLDLOG")
                                            : "/dev/null",
                      O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd >= 0) { dup2(fd, 1); dup2(fd, 2); if (fd > 2) close(fd); }
        execl(argv[1], argv[1], argv[2], (char *)NULL);
        _exit(127);
    }
    printf("OWNER %ld\n", (long)p);

    /* Give the holder time to create its window and print the wid. */
    const char *ms = getenv("ZOP_SETTLE_MS");
    int settle = ms ? atoi(ms) : 1500;
    usleep((useconds_t)settle * 1000);

    if (pstate(p) != 'S' && pstate(p) != 'R' && pstate(p) != 'D') {
        fprintf(stderr, "zombie_owner_parent: the holder is not running "
                        "(state '%c') before it was killed; it never got to "
                        "make a window\n", pstate(p) ? pstate(p) : '?');
        return 3;
    }
    printf("ALIVE %ld\n", (long)p);

    /* WAIT TO BE TOLD.  The first version of this program printed ALIVE and
     * killed the holder on the next line, and the gate's "while the owner is
     * running" reading raced with the SIGKILL -- it read an ALREADY DEAD owner
     * and reported the window correctly absent, which looks exactly like the
     * reaper working and is not evidence of anything.  The window must be
     * OBSERVED present first, and only the observer knows when it has been.
     * So the kill happens when a line arrives on stdin, and not before. */
    {
        int c;
        while ((c = getchar()) != '\n' && c != EOF)
            ;
    }

    kill(p, SIGKILL);

    /* MEASURE the corpse.  Do not infer it from kill(2) returning 0 — that is
     * the exact mistake this gate exists to catch. */
    for (int i = 0; i < 500; i++) {
        if (pstate(p) == 'Z') { printf("ZOMBIE %ld\n", (long)p); goto held; }
        usleep(10000);
    }
    fprintf(stderr, "zombie_owner_parent: %ld never became a zombie "
                    "(state '%c')\n", (long)p, pstate(p) ? pstate(p) : '?');
    return 4;

held:
    /* NEVER wait.  Sit here until somebody kills us. */
    for (;;) pause();
}
