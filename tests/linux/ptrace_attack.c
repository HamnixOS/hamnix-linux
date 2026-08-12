/* tests/linux/ptrace_attack.c — one same-uid process attaches to another that
 * is NOT its child, and says what the kernel answered.
 *
 * WHY THIS EXISTS.  user/linux-wsys.c moved a window's keystrokes out of the
 * shared segment and into a per-window socket, and prctl(PR_SET_DUMPABLE, 0)
 * in every window owner shuts /proc/<pid>/mem.  Both of those are userland
 * arrangements, and a same-uid PTRACE_ATTACH walks past the first and is
 * refused by the second only because the kernel's dumpable check happens to
 * cover ptrace too.  The DISTRIBUTION-level answer is Linux's Yama LSM:
 * kernel.yama.ptrace_scope=1, which user/linuxinit.ad sets as PID 1.
 *
 * A SIBLING, DELIBERATELY.  ptrace_scope=1 refuses an attach by anything that
 * is not an ANCESTOR of the target -- a debugger that LAUNCHED the program is
 * still a debugger, which is what makes 1 a livable setting rather than a
 * theoretical one.  So this program forks TWO children: a victim that sleeps,
 * and an attacker that attaches to it.  They are siblings; neither is the
 * other's ancestor; the parent of both is not the one doing the attaching.
 * That is exactly the shape of one uid-1001 desktop application reaching for
 * another, and it is the shape scope 1 exists to refuse.
 *
 * IT IS A MEASUREMENT ON BOTH SIDES.  tests/linux/ptrace_scope_boot.sh runs
 * this binary on the DEV HOST, where ptrace_scope is 0 and the attach must
 * SUCCEED, and inside a REAL BOOT of this tree, where linuxinit has set 1 and
 * the same binary must be refused.  A refusal measured without a matching
 * success proves only that the program is broken.
 *
 * Output, one line, everything a number the kernel returned:
 *
 *   == ptraceprobe uid=<u> scope=<n|unset> dumpable=<0|1> victim=<pid>
 *                  attach=<0|-1> errno=<e>
 *
 * `uid=` is never 0: started as root it drops to an unprivileged uid first, for
 * the reason in drop_privs below -- root has CAP_SYS_PTRACE and Yama does not
 * apply to it, so a root measurement would report a hole that is not there.
 *
 * Built static (no shared libraries exist inside the guest root), and it links
 * nothing from this tree: these are facts about Linux, and a probe that went
 * through our own runtime would be measuring the runtime.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/ptrace.h>
#include <sys/wait.h>
#include <unistd.h>

static void read_scope(char *out, size_t cap)
{
    snprintf(out, cap, "unset");
    int fd = open("/proc/sys/kernel/yama/ptrace_scope", O_RDONLY);
    if (fd < 0) return;
    char b[32];
    ssize_t n = read(fd, b, sizeof b - 1);
    close(fd);
    if (n <= 0) return;
    b[n] = '\0';
    for (char *p = b; *p; p++) if (*p == '\n') *p = '\0';
    snprintf(out, cap, "%s", b);
}

/* ROOT IS NOT A SAME-UID ATTACKER, and this cost the gate its first red run.
 *
 * ptrace_scope=1 restricts a process that has no CAP_SYS_PTRACE.  root has it,
 * so Yama never applies to root, and the first version of this probe -- run
 * from /etc/rc.boot, which hamsh executes as PID 1, as root -- printed
 *
 *     == ptraceprobe uid=0 scope=1 victim=148 attach=0 errno=0
 *
 * an attach that SUCCEEDED on a machine where the setting was correctly in
 * force.  That is the right kernel behaviour and the wrong measurement: the
 * threat model is /etc/rc.de-user's uid 1001, where the terminal, the browser
 * and a malicious download all live together, and root is not in it.
 *
 * So when this is started as root it drops to an ordinary uid FIRST, before
 * either child exists, and prints the uid it actually measured.  setuid(2) from
 * uid 0 to a non-zero uid sets real, effective and saved together, which clears
 * the permitted and effective capability sets -- so the children are genuinely
 * unprivileged and not root wearing a different number. */
static uid_t drop_privs(void)
{
    if (geteuid() != 0) return getuid();
    const char *e = getenv("PTRACEPROBE_UID");
    uid_t u = (uid_t)(e && *e ? atoi(e) : 1001);
    if (setgid((gid_t)u) != 0 || setuid(u) != 0) {
        fprintf(stderr, "ptraceprobe: cannot drop to uid %d: %s\n",
                (int)u, strerror(errno));
        return getuid();
    }
    if (geteuid() == 0) {              /* refuse to measure root by accident */
        fprintf(stderr, "ptraceprobe: still root after setuid; not measuring\n");
        _exit(2);
    }
    return getuid();
}

int main(void)
{
    char scope[32];
    read_scope(scope, sizeof scope);
    drop_privs();

    /* AND NOW UNDO WHAT THE setuid DID TO THE VICTIM, or this probe measures
     * the wrong mechanism and says the right thing.
     *
     * THIS WAS CAUGHT ON THE REVERTED RUN, which is the only run that could
     * have caught it.  With user/linuxinit.ad reverted -- ptrace_scope=0, the
     * setting absent, the hole wide open -- the guest still printed
     *
     *     == ptraceprobe uid=1001 scope=0 victim=144 attach=-1 errno=1
     *
     * a REFUSAL on a machine with nothing to refuse it.  Changing uid clears
     * the dumpable flag (commit_creds -> set_dumpable(suid_dumpable), and
     * /proc/sys/fs/suid_dumpable is 0 by default), so the victim was
     * non-dumpable and __ptrace_may_access said EPERM for a reason that had
     * nothing to do with Yama.  The gate would have passed its ptrace
     * assertion with the change removed: a witness that created the condition
     * it was testing for.
     *
     * PR_SET_DUMPABLE(1) puts it back, and `dumpable=` is printed so the
     * harness can refuse to believe a refusal measured on a non-dumpable
     * target.  What is being measured here is Yama and only Yama; the dumpable
     * mechanism is measured separately, against a real window owner, in
     * tests/linux/wsys_bypass.sh. */
    if (prctl(PR_SET_DUMPABLE, 1, 0, 0, 0) < 0)
        fprintf(stderr, "ptraceprobe: PR_SET_DUMPABLE(1): %s\n", strerror(errno));
    int dumpable = prctl(PR_GET_DUMPABLE);

    /* THE VICTIM.  It must be alive and stay alive for the whole attempt, and
     * it must not be the attacker's ancestor or descendant.  A pipe it never
     * writes to is what it blocks on: sleep(3) would race a slow boot. */
    int quit[2];
    if (pipe(quit) != 0) { perror("pipe"); return 2; }

    pid_t victim = fork();
    if (victim == 0) {
        close(quit[1]);
        char c;
        while (read(quit[0], &c, 1) < 0 && errno == EINTR) { }
        _exit(0);
    }
    if (victim < 0) { perror("fork"); return 2; }

    /* THE ATTACKER, a SIBLING of the victim.  Its result comes back through a
     * second pipe rather than through an exit status, so an errno survives. */
    int res[2];
    if (pipe(res) != 0) { perror("pipe"); return 2; }
    pid_t att = fork();
    if (att == 0) {
        close(res[0]);
        long r = ptrace(PTRACE_ATTACH, victim, NULL, NULL);
        int e = errno;
        if (r == 0) {
            int ws;
            waitpid(victim, &ws, 0);
            ptrace(PTRACE_DETACH, victim, NULL, NULL);
        }
        char line[64];
        int n = snprintf(line, sizeof line, "%d %d\n", r == 0 ? 0 : -1,
                         r == 0 ? 0 : e);
        ssize_t ign = write(res[1], line, (size_t)n);
        (void)ign;
        _exit(0);
    }
    if (att < 0) { perror("fork"); return 2; }
    close(res[1]);

    char buf[64];
    ssize_t n = read(res[0], buf, sizeof buf - 1);
    if (n <= 0) { snprintf(buf, sizeof buf, "-1 %d\n", ECHILD); }
    else buf[n] = '\0';
    int attach = -1, err = 0;
    sscanf(buf, "%d %d", &attach, &err);

    int ws;
    waitpid(att, &ws, 0);
    close(quit[1]);
    waitpid(victim, &ws, 0);

    printf("== ptraceprobe uid=%d scope=%s dumpable=%d victim=%d attach=%d "
           "errno=%d\n",
           (int)getuid(), scope, dumpable, (int)victim, attach, err);
    fflush(stdout);
    return 0;
}
