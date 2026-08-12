/* tests/linux/de_evdev_probe.c -- INPUT-TO-PIXEL LATENCY OVER A CHARACTER DEVICE.
 *
 * WHY THIS EXISTS
 * ===============
 * Every latency number on this branch came from wsysd reading a PLAIN FILE of
 * evdev records (HAMWSYSD_INPUT) -- and a plain file is precisely the fd class
 * sys_waitfds had to grow an inotify watch for, because poll(2) calls a
 * regular file readable always. Real hardware is a CHARACTER DEVICE, which
 * takes the ordinary poll(2) branch instead. That is a different arm of the
 * very function this branch changed, and measuring only the file arm would be
 * measuring the scaffolding.
 *
 * WHAT I COULD NOT DO, AND WHY -- READ THIS BEFORE BELIEVING THE NUMBER
 * ====================================================================
 * A REAL evdev NODE IS OUT OF REACH FOR THIS USER, in both directions, and
 * both were tried rather than assumed:
 *
 *   * /dev/input/event* on this host are root:input 0640 and this user is not
 *     in group `input`. Checked every node for a udev uaccess ACL: none has
 *     one for this user. So the owner's real devices cannot be READ at all --
 *     which is also the right answer, because the owner is sitting at tty1 and
 *     their keyboard is not something a measurement may read.
 *   * /dev/uinput DOES carry an ACL for this user, so a virtual pointer can be
 *     CREATED -- and it was, as /dev/input/event13, `hamnix-latency-probe`,
 *     ABS_X/ABS_Y/BTN_LEFT, never a keyboard. But udev does not put a uaccess
 *     ACL on a virtual device (it is not assigned to the seat), so the node
 *     came up root:input 0640 and NOTHING in userland could open it -- not the
 *     probe, and not wsysd either. `--uinput-check` reruns exactly that and
 *     prints the result, so the blocker is reproducible rather than asserted.
 *     Nothing is left behind: the device is destroyed on every exit path.
 *
 * SO THE STAND-IN IS A PTY, and what it is worth is stated precisely. A pty
 * slave is a genuine character device with a real driver, opened by path,
 * whose readiness poll(2) answers properly and which returns EAGAIN when
 * empty. To `sys_waitfds` it is INDISTINGUISHABLE from /dev/input/eventN:
 * devtab_find misses it, fstat says S_ISCHR so it is not the regular-file
 * class, and it lands in the same pfd[] slot and the same poll(2) call. The
 * line discipline is put in raw mode so the 24-byte records pass through byte
 * for byte -- verified by the compositor's own decode, not by hope.
 *
 * WHAT IT IS NOT: the USB/HID transport, the evdev driver's own buffering, and
 * a real mouse's report rate. All three are upstream of every line this branch
 * touched, but they are absent from this number and no claim is made about
 * them. The one place real evdev runs end to end is the VM in
 * tests/linux/de_idle_cpu.sh, and that gate measures CPU, not latency.
 *
 * THE MEASUREMENT is the contract tests/linux/de_fps_driver.py uses: the clock
 * starts at the last instruction before the write(2) that makes the record
 * visible and stops when the framebuffer bytes where the pointer is going have
 * changed. The settle is JITTERED, because a constant settle that happens to
 * be a whole number of ticks phase-locks the probe -- that mistake reported a
 * median 8x too good the last time this was measured, and it is kept as a
 * control here too (--nojitter).
 *
 * THE INSTRUMENT ANSWERS FOR ITSELF FIRST:
 *   --noinput   the watcher must NOT fire in 1.5 s with nothing injected.
 *   --stop N    with --pid, SIGSTOP the compositor for N ms mid-trial; the
 *               measurement MUST come back >= N. A probe that cannot report a
 *               latency worse than the truth cannot be trusted with a good one.
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

static int ui = -1;                     /* uinput, only for --uinput-check */
static int mfd = -1;                    /* the pty master we write records to */

static long long now_ns(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (long long)t.tv_sec * 1000000000LL + t.tv_nsec;
}

static void cleanup(void)
{
    if (ui >= 0) { ioctl(ui, UI_DEV_DESTROY); close(ui); ui = -1; }
    if (mfd >= 0) { close(mfd); mfd = -1; }
}

static void on_signal(int s) { (void)s; cleanup(); _exit(1); }

/* ------------------------------------------------------------ uinput ---
 * Not the measurement path: this exists so the reason the measurement is not
 * on a real evdev node is REPRODUCIBLE. Creates the device, reports whether
 * this user can open the node udev made, destroys it. */
static int uinput_check(void)
{
    ui = open("/dev/uinput", O_WRONLY | O_NONBLOCK | O_CLOEXEC);
    if (ui < 0) {
        printf("uinput-check: /dev/uinput cannot be opened: %s\n",
               strerror(errno));
        return 1;
    }
    ioctl(ui, UI_SET_EVBIT, EV_KEY);
    ioctl(ui, UI_SET_KEYBIT, BTN_LEFT);     /* a POINTER, never a keyboard */
    ioctl(ui, UI_SET_EVBIT, EV_ABS);
    ioctl(ui, UI_SET_ABSBIT, ABS_X);
    ioctl(ui, UI_SET_ABSBIT, ABS_Y);
    struct uinput_abs_setup as;
    memset(&as, 0, sizeof as);
    as.absinfo.maximum = 32767;
    as.code = ABS_X; ioctl(ui, UI_ABS_SETUP, &as);
    as.code = ABS_Y; ioctl(ui, UI_ABS_SETUP, &as);
    struct uinput_setup us;
    memset(&us, 0, sizeof us);
    us.id.bustype = BUS_VIRTUAL;
    snprintf(us.name, sizeof us.name, "hamnix-latency-probe");
    if (ioctl(ui, UI_DEV_SETUP, &us) < 0 || ioctl(ui, UI_DEV_CREATE) < 0) {
        printf("uinput-check: the device could not be created: %s\n",
               strerror(errno));
        cleanup();
        return 1;
    }
    char sysname[64] = {0};
    if (ioctl(ui, UI_GET_SYSNAME(sizeof sysname), sysname) < 0) {
        printf("uinput-check: UI_GET_SYSNAME failed: %s\n", strerror(errno));
        cleanup();
        return 1;
    }
    char dir[192];
    snprintf(dir, sizeof dir, "/sys/devices/virtual/input/%s", sysname);
    char node[160] = {0};
    for (int t = 0; t < 250 && !node[0]; t++) {
        DIR *d = opendir(dir);
        if (d) {
            struct dirent *e;
            while ((e = readdir(d)))
                if (!strncmp(e->d_name, "event", 5)) {
                    snprintf(node, sizeof node, "/dev/input/%.100s", e->d_name);
                    break;
                }
            closedir(d);
        }
        if (!node[0]) usleep(20000);
    }
    if (!node[0]) {
        printf("uinput-check: the device never appeared under %s\n", dir);
        cleanup();
        return 1;
    }
    int ok = 0;
    for (int t = 0; t < 100; t++) {           /* give udev its two seconds */
        if (access(node, R_OK) == 0) { ok = 1; break; }
        usleep(20000);
    }
    struct stat st;
    stat(node, &st);
    printf("uinput-check: created %s (mode %04o uid %u gid %u) -- %s\n",
           node, st.st_mode & 07777, st.st_uid, st.st_gid,
           ok ? "READABLE by this user"
              : "NOT readable by this user: udev puts no uaccess ACL on a "
                "virtual device, so wsysd could not open it either");
    cleanup();
    return ok ? 0 : 1;
}

/* --------------------------------------------------------------- pty ---
 * A character device this user owns. Raw line discipline, so 24-byte evdev
 * records cross it byte for byte. */
static int pty_create(char *node, size_t n)
{
    mfd = posix_openpt(O_RDWR | O_NOCTTY);
    if (mfd < 0) { perror("posix_openpt"); return -1; }
    if (grantpt(mfd) || unlockpt(mfd)) { perror("grantpt/unlockpt"); return -1; }
    const char *s = ptsname(mfd);
    if (!s) { perror("ptsname"); return -1; }
    snprintf(node, n, "%s", s);

    /* RAW, on the slave's termios, set through the master: no NL/CR
     * translation, no echo, no signal characters -- an evdev record contains
     * every byte value and a cooked line discipline would rewrite some of
     * them. */
    int sfd = open(node, O_RDWR | O_NOCTTY);
    if (sfd < 0) { perror("open pts"); return -1; }
    struct termios tio;
    if (tcgetattr(sfd, &tio) == 0) {
        cfmakeraw(&tio);
        tio.c_cc[VMIN] = 0;
        tio.c_cc[VTIME] = 0;
        tcsetattr(sfd, TCSANOW, &tio);
    }
    close(sfd);                      /* the master keeps the pty alive */
    return 0;
}

static int W = 1280, H = 800;

static void emit(int type, int code, int val)
{
    struct input_event ev;
    memset(&ev, 0, sizeof ev);
    ev.type = (unsigned short)type;
    ev.code = (unsigned short)code;
    ev.value = val;
    if (write(mfd, &ev, sizeof ev) != (ssize_t)sizeof ev)
        perror("probe: write");
}

/* Returns the instant of the last instruction before the write that makes the
 * record visible -- the SYN that completes the report. */
static long long move_to(int x, int y)
{
    emit(EV_ABS, ABS_X, (int)((long long)x * 32768 / W));
    emit(EV_ABS, ABS_Y, (int)((long long)y * 32768 / H));
    long long t0 = now_ns();
    emit(EV_SYN, SYN_REPORT, 0);
    return t0;
}

static unsigned char band_a[64 * 4096 * 4], band_b[64 * 4096 * 4];

static size_t read_band(int fb, int y0, int y1, unsigned char *into)
{
    size_t n = (size_t)(y1 - y0) * (size_t)W * 4;
    ssize_t got = pread(fb, into, n, (off_t)y0 * W * 4);
    return got > 0 ? (size_t)got : 0;
}

static int cmp_d(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y ? 1 : 0;
}

int main(int argc, char **argv)
{
    const char *fbpath = NULL;
    int trials = 60, stop_ms = 0, quiet_test = 0, jitter = 1, uicheck = 0;
    int hold = 0;
    pid_t stop_pid = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--fb") && i + 1 < argc) fbpath = argv[++i];
        else if (!strcmp(argv[i], "--geom") && i + 1 < argc)
            sscanf(argv[++i], "%dx%d", &W, &H);
        else if (!strcmp(argv[i], "--trials") && i + 1 < argc)
            trials = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--stop") && i + 1 < argc)
            stop_ms = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--pid") && i + 1 < argc)
            stop_pid = (pid_t)atoi(argv[++i]);
        else if (!strcmp(argv[i], "--noinput")) quiet_test = 1;
        else if (!strcmp(argv[i], "--nojitter")) jitter = 0;
        else if (!strcmp(argv[i], "--uinput-check")) uicheck = 1;
        else if (!strcmp(argv[i], "--hold")) hold = 1;
    }
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    signal(SIGHUP, on_signal);

    if (uicheck) return uinput_check();

    char node[128];
    if (pty_create(node, sizeof node) < 0) { cleanup(); return 2; }
    printf("probe: device %s (pty slave, raw, S_ISCHR)\n", node);
    fflush(stdout);
    if (hold) { for (;;) pause(); }

    /* The harness starts wsysd against that node and then writes "go <pid>"
     * here. The pid arrives this way and not on the command line because the
     * compositor cannot be started until the device exists, and the device is
     * made by this process. */
    char line[64];
    if (!fgets(line, sizeof line, stdin)) { cleanup(); return 2; }
    {
        long p2 = 0;
        if (sscanf(line, "go %ld", &p2) == 1 && p2 > 0 && stop_pid == 0)
            stop_pid = (pid_t)p2;
    }

    if (!fbpath) { cleanup(); return 2; }
    int fb = open(fbpath, O_RDONLY);
    if (fb < 0) { perror("open fb"); cleanup(); return 2; }

    int ax = W / 4, ay = H / 4, bx = 3 * W / 4, by = 3 * H / 4;
    int y0 = by - 24, y1 = by + 24;

    if (quiet_test) {
        move_to(ax, ay);
        usleep(300000);
        size_t n = read_band(fb, y0, y1, band_a);
        long long deadline = now_ns() + 1500000000LL;
        int fired = 0;
        while (now_ns() < deadline) {
            read_band(fb, y0, y1, band_b);
            if (memcmp(band_a, band_b, n)) { fired = 1; break; }
        }
        printf("probe: no-input  %s\n",
               fired ? "FAIL the watcher fired with nothing injected"
                     : "PASS the watcher did not fire in 1.5 s");
        cleanup();
        return fired;
    }

    double *out = calloc((size_t)trials, sizeof *out);
    int n_ok = 0, lost = 0, skipped = 0;
    unsigned seed = 20260812;
    for (int i = 0; i < trials; i++) {
        move_to(ax, ay);
        useconds_t settle = 60000
            + (jitter ? (useconds_t)(rand_r(&seed) % 17000) : 20000);
        usleep(settle);
        size_t n = read_band(fb, y0, y1, band_a);
        usleep(20000);
        read_band(fb, y0, y1, band_b);
        if (memcmp(band_a, band_b, n)) { skipped++; continue; }

        long long t0 = move_to(bx, by);
        if (stop_ms > 0 && stop_pid > 0) {
            kill(stop_pid, SIGSTOP);
            usleep((useconds_t)stop_ms * 1000);
            kill(stop_pid, SIGCONT);
        }
        long long deadline = t0 + (long long)(stop_ms + 400) * 1000000LL;
        long long t1 = 0;
        while (now_ns() < deadline) {
            read_band(fb, y0, y1, band_b);
            if (memcmp(band_a, band_b, n)) { t1 = now_ns(); break; }
        }
        if (!t1) { lost++; continue; }
        out[n_ok++] = (double)(t1 - t0) / 1e6;
    }
    cleanup();

    if (!n_ok) {
        printf("probe: NO SAMPLE (lost %d, skipped %d)\n", lost, skipped);
        return 1;
    }
    qsort(out, (size_t)n_ok, sizeof *out, cmp_d);
    double sum = 0;
    for (int i = 0; i < n_ok; i++) sum += out[i];
    printf("probe: n=%d lost=%d skipped=%d min %.2f p50 %.2f mean %.2f "
           "p95 %.2f max %.2f ms\n", n_ok, lost, skipped, out[0],
           out[n_ok / 2], sum / n_ok, out[(int)(0.95 * (n_ok - 1))],
           out[n_ok - 1]);
    return 0;
}
