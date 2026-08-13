/* wsys_rtt_probe.c — WHAT WOULD A ROUND TRIP COST?
 *
 * The other half of the file-server question. wsys_op_census.sh supplies the
 * denominator (how many ops a second); this supplies the price of one.
 *
 * WHAT IT MEASURES, and why it is not a synthetic ping. The payloads are the
 * REAL control writes a client makes -- `version 2`, a geometry change, a
 * commit, a title set -- and the server side does what a mediator would have
 * to do rather than echoing: parse the verb, bounds-check the numbers, look
 * the window up in a table, and refuse anything that is not the caller's.
 * A server that only echoed would flatter the design by leaving out the entire
 * reason for having one.
 *
 * THREE ARMS:
 *   rtt-seq    one request, wait for the reply, then the next. The honest
 *              cost of a mediated operation, and the worst case.
 *   rtt-burst  N requests written back-to-back, then N replies collected --
 *              a client issuing many small control writes without waiting.
 *              This is the case a round-trip-per-op design is worst at, and
 *              it is what hamui does when it commits a scene line by line.
 *   inproc     the same parse-and-validate work called as a function, with no
 *              socket at all. The floor: what the current design pays.
 *
 * SELFTEST. --selftest checks the probe can report a LARGE number: it inserts
 * a known 200 us delay on the server side and requires the measured round trip
 * to grow by at least 150 us. A probe that cannot see a slow server would
 * report any design as fast enough, which is the flattering answer to exactly
 * the question this exists to settle.
 *
 * Standalone: links nothing from the tree, touches no display, opens no
 * /dev/wsys. Build: cc -O2 -o wsys_rtt_probe wsys_rtt_probe.c
 */
#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>

static uint64_t now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

/* A window table, so the server has something real to check against. */
#define NWIN 64
static struct { int wid; int owner; int x, y, w, h; char title[64]; } wtab[NWIN];

/* THE MEDIATION. This is the work a file server must do that the in-process
 * design does not do at all: decide whether this caller may touch this window.
 * It is the entire point of the boundary, so it is inside the timed path. */
static int serve_one(const char *req, int reqlen, int caller, char *rep)
{
    int wid = 0, a, b, c, d;
    char verb[24];
    if (reqlen <= 0) return snprintf(rep, 64, "!short\n");
    if (sscanf(req, "%d %23s", &wid, verb) < 2)
        return snprintf(rep, 64, "!parse\n");
    if (wid < 0 || wid >= NWIN)  return snprintf(rep, 64, "!range\n");
    if (wtab[wid].owner != caller) return snprintf(rep, 64, "!perm\n");
    if (!strcmp(verb, "version")) return snprintf(rep, 64, "ok 2\n");
    if (!strcmp(verb, "commit"))  return snprintf(rep, 64, "ok\n");
    if (!strcmp(verb, "geometry")) {
        if (sscanf(req, "%*d %*s %d %d %d %d", &a, &b, &c, &d) != 4)
            return snprintf(rep, 64, "!parse\n");
        if (c <= 0 || d <= 0 || c > 8192 || d > 8192)
            return snprintf(rep, 64, "!range\n");
        wtab[wid].x = a; wtab[wid].y = b; wtab[wid].w = c; wtab[wid].h = d;
        return snprintf(rep, 64, "ok\n");
    }
    if (!strcmp(verb, "title")) {
        const char *t = strchr(req, ' ');
        t = t ? strchr(t + 1, ' ') : NULL;
        snprintf(wtab[wid].title, sizeof wtab[0].title, "%s", t ? t + 1 : "");
        return snprintf(rep, 64, "ok\n");
    }
    return snprintf(rep, 64, "!verb\n");
}

static const char *REQ[] = {
    "3 version 2",
    "3 geometry 160 340 480 320",
    "3 commit",
    "3 title a terminal window",
};
#define NREQ 4

static int cmp_u64(const void *a, const void *b)
{
    uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
    return x < y ? -1 : x > y ? 1 : 0;
}

static void report(const char *tag, uint64_t *v, int n)
{
    qsort(v, n, sizeof v[0], cmp_u64);
    printf("rtt: %-12s n=%d  p50 %6.2f  p90 %6.2f  p99 %6.2f  max %8.2f us\n",
           tag, n, v[n / 2] / 1000.0, v[(int)(n * 0.90)] / 1000.0,
           v[(int)(n * 0.99)] / 1000.0, v[n - 1] / 1000.0);
}

int main(int argc, char **argv)
{
    int iters = 20000, burst = 16, selftest = 0, delay_us = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--selftest")) selftest = 1;
        else if (!strcmp(argv[i], "--iters") && i + 1 < argc) iters = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--burst") && i + 1 < argc) burst = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--delay-us") && i + 1 < argc) delay_us = atoi(argv[++i]);
    }
    for (int i = 0; i < NWIN; i++) { wtab[i].wid = i; wtab[i].owner = 1; }

    if (selftest) {
        printf("rtt: selftest -- a server delayed by a KNOWN 200 us must show up\n");
        char cmd[512];
        snprintf(cmd, sizeof cmd, "%s --iters 2000 --burst 1 > /tmp/.rtt_a.txt", argv[0]);
        if (system(cmd)) { printf("rtt: FAIL selftest could not run the fast arm\n"); return 1; }
        snprintf(cmd, sizeof cmd, "%s --iters 2000 --burst 1 --delay-us 200 > /tmp/.rtt_b.txt", argv[0]);
        if (system(cmd)) { printf("rtt: FAIL selftest could not run the slow arm\n"); return 1; }
        double a = 0, b = 0; char line[256]; FILE *f;
        f = fopen("/tmp/.rtt_a.txt", "r");
        while (f && fgets(line, sizeof line, f)) if (strstr(line, "rtt-seq")) sscanf(strstr(line, "p50") + 3, "%lf", &a);
        if (f) fclose(f);
        f = fopen("/tmp/.rtt_b.txt", "r");
        while (f && fgets(line, sizeof line, f)) if (strstr(line, "rtt-seq")) sscanf(strstr(line, "p50") + 3, "%lf", &b);
        if (f) fclose(f);
        printf("rtt: fast p50 %.2f us, delayed p50 %.2f us, difference %.2f us\n", a, b, b - a);
        if (b - a >= 150.0) { printf("rtt: PASS the probe sees a 200 us server delay as %.0f us\n", b - a); return 0; }
        printf("rtt: FAIL a 200 us server delay measured as %.2f us -- this probe cannot report a slow server\n", b - a);
        return 1;
    }

    int sv[2];
    if (socketpair(AF_UNIX, SOCK_SEQPACKET, 0, sv) < 0) { perror("socketpair"); return 1; }
    pid_t pid = fork();
    if (pid < 0) { perror("fork"); return 1; }
    if (pid == 0) {                     /* ---- the server ---- */
        close(sv[0]);
        char req[256], rep[64];
        for (;;) {
            ssize_t n = recv(sv[1], req, sizeof req - 1, 0);
            if (n <= 0) break;
            req[n] = '\0';
            if (delay_us) { struct timespec t = {0, delay_us * 1000L}; nanosleep(&t, NULL); }
            int rn = serve_one(req, (int)n, 1, rep);
            if (send(sv[1], rep, (size_t)rn, 0) < 0) break;
        }
        close(sv[1]);
        _exit(0);
    }
    close(sv[1]);

    uint64_t *v = calloc((size_t)iters, sizeof *v);
    char rep[64];

    /* ---- arm 1: sequential round trip ---- */
    for (int i = 0; i < iters; i++) {
        const char *r = REQ[i % NREQ];
        uint64_t t0 = now_ns();
        if (send(sv[0], r, strlen(r), 0) < 0) break;
        if (recv(sv[0], rep, sizeof rep, 0) <= 0) break;
        v[i] = now_ns() - t0;
    }
    report("rtt-seq", v, iters);

    /* ---- arm 2: a burst of small control writes, replies collected after ---- */
    int nb = iters / burst;
    for (int i = 0; i < nb; i++) {
        uint64_t t0 = now_ns();
        for (int k = 0; k < burst; k++)
            if (send(sv[0], REQ[k % NREQ], strlen(REQ[k % NREQ]), 0) < 0) goto done;
        for (int k = 0; k < burst; k++)
            if (recv(sv[0], rep, sizeof rep, 0) <= 0) goto done;
        v[i] = (now_ns() - t0) / (uint64_t)burst;   /* per operation */
    }
done:
    { char tag[32]; snprintf(tag, sizeof tag, "rtt-burst%d", burst); report(tag, v, nb); }

    /* ---- arm 3: the same work in-process, no socket ---- */
    for (int i = 0; i < iters; i++) {
        const char *r = REQ[i % NREQ];
        uint64_t t0 = now_ns();
        serve_one(r, (int)strlen(r), 1, rep);
        v[i] = now_ns() - t0;
    }
    report("inproc", v, iters);

    close(sv[0]);
    waitpid(pid, NULL, 0);
    return 0;
}
