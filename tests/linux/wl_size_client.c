/* tests/linux/wl_size_client.c — A NATIVE WAYLAND CLIENT THAT CHOOSES ITS OWN
 * SIZE, because nothing else on this host can construct the case.
 *
 * WHY THIS EXISTS
 * ===============
 * user/wsyswl.ad clips a surface to the device's maximum (BB_W x BB_H, 1920 x
 * 1080).  That clip was measured through XWAYLAND -- an X client whose size
 * comes from an X geometry -- and the claim that a NATIVE Wayland client hits
 * the same path was reasoned from "they share commit_buffer", not measured.
 *
 * The native clients this host has cannot construct it:
 *
 *   * weston-terminal sizes itself from a font cell, and its only size options
 *     are --maximized and --fullscreen.  BOTH ARE ANSWERED WITH MAX_W/MAX_H,
 *     and user/wsyswl.ad:clamp_maximised has already cut those to the device's
 *     ceiling -- so a well-behaved native client that asks for the whole screen
 *     is TOLD 1920x1080 and never oversteps.  The over-size case is only
 *     reachable by a client that picks its own size, which is exactly what
 *     Xwayland does on behalf of an X window.
 *   * weston-simple-shm is a fixed 250x250.
 *
 * So this one takes the size on the command line, fills it with ONE COLOUR the
 * framebuffer can be asked about, and speaks THE WIRE ITSELF -- the host has
 * libwayland-client.so but no wayland-client.h and no wayland-scanner, the
 * same finding tests/linux/wl_conn_probe.c records.  Speaking the wire is also
 * what makes this evidence: what is asserted is the bytes the client sent and
 * the pixels that came out, not one library's rendering of them.
 *
 * WHAT IT DOES
 *   connect, get_registry, bind wl_compositor + wl_shm + xdg_wm_base,
 *   create_surface, get_xdg_surface, get_toplevel, set_title, bufferless
 *   commit, wait for xdg_surface.configure, ack it, memfd + create_pool (fd by
 *   SCM_RIGHTS) + create_buffer at THE REQUESTED SIZE, attach, damage, commit.
 *   Then it re-commits the same buffer every 500 ms until -hold expires, so a
 *   caller can screenshot at leisure.
 *
 * Every rung prints "[wlsz] <name>" on stderr, so a gate can tell "the client
 * never got that far" from "the compositor drew nothing" -- the distinction
 * this suite keeps losing.
 *
 * Usage: wl_size_client -w W -h H [-c RRGGBB] [-t title] [-hold SEC] [-s sock]
 *   -s defaults to $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY.
 * Exit: 0 drew and held; 2 protocol error from the server (printed verbatim);
 *       3 never got a configure; 1 usage/errno.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

/* Object ids.  Fixed rather than allocated: a client this small has no use for
 * a free list, and a fixed map makes an event's object id readable in a log. */
#define O_DISPLAY   1u
#define O_REGISTRY  2u
#define O_SYNC      3u
#define O_COMP      4u
#define O_SHM       5u
#define O_WM        6u
#define O_SURFACE   7u
#define O_XDGSURF   8u
#define O_TOPLEVEL  9u
#define O_POOL      10u
#define O_BUFFER    11u

static int sock = -1;

static void say(const char *s) { fprintf(stderr, "[wlsz] %s\n", s); }

/* --- the wire ---------------------------------------------------------- */

static uint8_t obuf[4096];
static size_t  olen;

static void o_u32(uint32_t v) { memcpy(obuf + olen, &v, 4); olen += 4; }

static void o_str(const char *s)
{
    uint32_t n = (uint32_t)strlen(s) + 1;      /* the NUL is in the length */
    o_u32(n);
    memcpy(obuf + olen, s, n);
    olen += n;
    while (olen & 3u) obuf[olen++] = 0;        /* padded to 32 bits */
}

static size_t msg_begin(uint32_t obj)
{
    size_t at = olen;
    o_u32(obj);
    o_u32(0);                                  /* size<<16 | opcode, patched */
    return at;
}

static void msg_end(size_t at, uint32_t opcode)
{
    uint32_t hdr = (uint32_t)((olen - at) << 16) | opcode;
    memcpy(obuf + at + 4, &hdr, 4);
}

static int flush_msgs(int passfd)
{
    struct iovec io = { obuf, olen };
    struct msghdr mh;
    union { struct cmsghdr a; char b[CMSG_SPACE(sizeof(int))]; } cm;
    memset(&mh, 0, sizeof mh);
    mh.msg_iov = &io;
    mh.msg_iovlen = 1;
    if (passfd >= 0) {
        memset(&cm, 0, sizeof cm);
        mh.msg_control = cm.b;
        mh.msg_controllen = sizeof cm.b;
        struct cmsghdr *c = CMSG_FIRSTHDR(&mh);
        c->cmsg_level = SOL_SOCKET;
        c->cmsg_type = SCM_RIGHTS;
        c->cmsg_len = CMSG_LEN(sizeof(int));
        memcpy(CMSG_DATA(c), &passfd, sizeof(int));
    }
    ssize_t n = sendmsg(sock, &mh, 0);
    if (n != (ssize_t)olen) {
        fprintf(stderr, "[wlsz] sendmsg %zd of %zu: %s\n", n, olen,
                strerror(errno));
        return -1;
    }
    olen = 0;
    return 0;
}

/* --- events ------------------------------------------------------------ */

static uint8_t ibuf[65536];
static size_t  ilen;

static uint32_t r_u32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return v; }

/* Globals we are looking for; 0 means "not advertised". */
static uint32_t g_comp, g_shm, g_wm;
static int      sync_done, configured, closed;
static uint32_t cfg_serial;
static int      trace;          /* -v: every event, object and opcode */

/* Returns 0 normally, -1 on EOF/error, -2 on a wl_display.error (printed). */
static int pump(int timeout_ms)
{
    struct pollfd pf = { sock, POLLIN, 0 };
    int r = poll(&pf, 1, timeout_ms);
    if (r <= 0) return r == 0 ? 0 : -1;
    ssize_t n = recv(sock, ibuf + ilen, sizeof ibuf - ilen, 0);
    if (n <= 0) return -1;
    ilen += (size_t)n;

    size_t i = 0;
    while (ilen - i >= 8) {
        uint32_t obj = r_u32(ibuf + i);
        uint32_t h   = r_u32(ibuf + i + 4);
        uint32_t sz  = h >> 16, op = h & 0xffffu;
        if (sz < 8 || ilen - i < sz) break;
        const uint8_t *a = ibuf + i + 8;
        uint32_t alen = sz - 8;
        if (trace) fprintf(stderr, "[wlsz] event obj %u op %u (%u bytes)\n",
                           obj, op, sz);
        if (obj == O_DISPLAY && op == 0 && alen >= 12) {
            uint32_t code = r_u32(a + 4), slen = r_u32(a + 8);
            fprintf(stderr, "[wlsz] SERVER ERROR object %u code %u: %.*s\n",
                    r_u32(a), code, (int)(slen ? slen - 1 : 0),
                    (const char *)(a + 12));
            return -2;
        } else if (obj == O_REGISTRY && op == 0 && alen >= 12) {
            uint32_t name = r_u32(a), slen = r_u32(a + 4);
            const char *iface = (const char *)(a + 8);
            if (slen && slen <= alen - 8) {
                if (!strcmp(iface, "wl_compositor")) g_comp = name;
                else if (!strcmp(iface, "wl_shm"))   g_shm = name;
                else if (!strcmp(iface, "xdg_wm_base")) g_wm = name;
            }
        } else if (obj == O_SYNC && op == 0) {
            sync_done = 1;
        } else if (obj == O_WM && op == 0 && alen >= 4) {
            /* ping -> pong, or a compositor that checks would kill us. */
            size_t at = msg_begin(O_WM);
            o_u32(r_u32(a));
            msg_end(at, 3);
            if (flush_msgs(-1) < 0) return -1;
        } else if (obj == O_XDGSURF && op == 0 && alen >= 4) {
            cfg_serial = r_u32(a);
            configured = 1;
        } else if (obj == O_TOPLEVEL && op == 1) {
            closed = 1;
        }
        i += sz;
    }
    if (i) { memmove(ibuf, ibuf + i, ilen - i); ilen -= i; }
    return 1;                       /* 1 = read something, 0 = poll timed out */
}

/* Pump until `flag` goes true or the deadline passes.  A client that waits
 * forever for an event the compositor never sends is the failure this whole
 * area keeps producing, so waiting always has an end and a name. */
static int wait_for(volatile int *flag, int ms, const char *what)
{
    for (int spent = 0; spent < ms && !*flag; spent += 50) {
        int r = pump(50);
        if (r == -2) exit(2);
        if (r < 0) { fprintf(stderr, "[wlsz] connection lost waiting for %s\n", what); return -1; }
    }
    if (!*flag) { fprintf(stderr, "[wlsz] TIMEOUT waiting for %s\n", what); return -1; }
    return 0;
}

int main(int argc, char **argv)
{
    int W = 0, H = 0, hold = 30;
    uint32_t colour = 0x00ff88u;
    const char *title = "wlsize";
    const char *spath = NULL;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-w") && i + 1 < argc) W = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-h") && i + 1 < argc) H = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-c") && i + 1 < argc) colour = (uint32_t)strtoul(argv[++i], NULL, 16);
        else if (!strcmp(argv[i], "-t") && i + 1 < argc) title = argv[++i];
        else if (!strcmp(argv[i], "-hold") && i + 1 < argc) hold = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-s") && i + 1 < argc) spath = argv[++i];
        else if (!strcmp(argv[i], "-v")) trace = 1;
        else { fprintf(stderr, "usage: %s -w W -h H [-c RRGGBB] [-t title] [-hold SEC] [-s sock]\n", argv[0]); return 1; }
    }
    if (W < 1 || H < 1) { fprintf(stderr, "need -w and -h\n"); return 1; }

    char sbuf[256];
    if (!spath) {
        const char *dir = getenv("XDG_RUNTIME_DIR");
        const char *disp = getenv("WAYLAND_DISPLAY");
        if (!dir || !disp) { fprintf(stderr, "no -s and no XDG_RUNTIME_DIR/WAYLAND_DISPLAY\n"); return 1; }
        snprintf(sbuf, sizeof sbuf, "%s/%s", dir, disp);
        spath = sbuf;
    }

    struct sockaddr_un sa;
    memset(&sa, 0, sizeof sa);
    sa.sun_family = AF_UNIX;
    /* SAY IT RATHER THAN TRUNCATE IT.  A silently shortened socket path
     * connects to nothing and reads as "the compositor is not running". */
    if (strlen(spath) >= sizeof sa.sun_path) {
        fprintf(stderr, "socket path is %zu bytes, the limit is %zu: %s\n",
                strlen(spath), sizeof sa.sun_path - 1, spath);
        return 1;
    }
    memcpy(sa.sun_path, spath, strlen(spath));
    sock = socket(AF_UNIX, SOCK_STREAM, 0);
    if (sock < 0) { perror("socket"); return 1; }
    if (connect(sock, (struct sockaddr *)&sa, sizeof sa) < 0) {
        fprintf(stderr, "connect %s: %s\n", spath, strerror(errno));
        return 1;
    }
    say("connected");

    /* registry + a sync to know when the globals have all arrived */
    size_t at = msg_begin(O_DISPLAY); o_u32(O_REGISTRY); msg_end(at, 1);
    at = msg_begin(O_DISPLAY); o_u32(O_SYNC); msg_end(at, 0);
    if (flush_msgs(-1) < 0) return 1;
    if (wait_for(&sync_done, 5000, "the registry to finish") < 0) return 1;
    if (!g_comp || !g_shm || !g_wm) {
        fprintf(stderr, "[wlsz] missing globals: compositor=%u shm=%u xdg_wm_base=%u\n",
                g_comp, g_shm, g_wm);
        return 1;
    }
    say("registry: wl_compositor, wl_shm and xdg_wm_base all advertised");

    /* bind(name, interface, version, new_id) */
    at = msg_begin(O_REGISTRY); o_u32(g_comp); o_str("wl_compositor"); o_u32(1); o_u32(O_COMP); msg_end(at, 0);
    at = msg_begin(O_REGISTRY); o_u32(g_shm);  o_str("wl_shm");        o_u32(1); o_u32(O_SHM);  msg_end(at, 0);
    at = msg_begin(O_REGISTRY); o_u32(g_wm);   o_str("xdg_wm_base");   o_u32(1); o_u32(O_WM);   msg_end(at, 0);
    /* wl_compositor.create_surface(id) */
    at = msg_begin(O_COMP); o_u32(O_SURFACE); msg_end(at, 0);
    /* xdg_wm_base.get_xdg_surface(id, surface) */
    at = msg_begin(O_WM); o_u32(O_XDGSURF); o_u32(O_SURFACE); msg_end(at, 2);
    /* xdg_surface.get_toplevel(id) */
    at = msg_begin(O_XDGSURF); o_u32(O_TOPLEVEL); msg_end(at, 1);
    /* xdg_toplevel.set_title(title) */
    at = msg_begin(O_TOPLEVEL); o_str(title); msg_end(at, 2);
    /* THE BUFFERLESS COMMIT.  xdg-shell says the compositor answers THIS with
     * the first configure, and user/wsyswl.ad implements exactly that rule --
     * a buffer attached before the ack is dropped with "never acked a
     * configure". */
    at = msg_begin(O_SURFACE); msg_end(at, 6);
    if (flush_msgs(-1) < 0) return 1;
    say("surface + xdg_surface + toplevel created, bufferless commit sent");

    if (wait_for(&configured, 5000, "xdg_surface.configure") < 0) return 3;
    at = msg_begin(O_XDGSURF); o_u32(cfg_serial); msg_end(at, 4);
    if (flush_msgs(-1) < 0) return 1;
    say("configure acked");

    /* THE BUFFER, AT THE SIZE WE WERE ASKED FOR AND NOT THE ONE WE WERE
     * OFFERED.  This is the whole point of the client: a toolkit would take
     * the compositor's configure as its size, and the compositor has already
     * clamped that.  An X client under Xwayland does not, which is why the
     * defect was only ever reachable from the X side until now. */
    size_t stride = (size_t)W * 4, bytes = stride * (size_t)H;
    int mfd = (int)syscall(SYS_memfd_create, "wlsz", 0);
    if (mfd < 0) { perror("memfd_create"); return 1; }
    if (ftruncate(mfd, (off_t)bytes) < 0) { perror("ftruncate"); return 1; }
    uint8_t *px = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_SHARED, mfd, 0);
    if (px == MAP_FAILED) { perror("mmap"); return 1; }
    /* XRGB8888 is little-endian 0xXXRRGGBB, so byte 0 is blue. */
    for (size_t p = 0; p < bytes; p += 4) {
        px[p]     = (uint8_t)(colour & 0xff);
        px[p + 1] = (uint8_t)((colour >> 8) & 0xff);
        px[p + 2] = (uint8_t)((colour >> 16) & 0xff);
        px[p + 3] = 0xff;
    }
    fprintf(stderr, "[wlsz] %dx%d buffer filled with %06x (%zu bytes)\n",
            W, H, colour, bytes);

    /* wl_shm.create_pool(id, fd, size) — the fd rides as ancillary data */
    at = msg_begin(O_SHM); o_u32(O_POOL); o_u32((uint32_t)bytes); msg_end(at, 0);
    if (flush_msgs(mfd) < 0) return 1;
    /* wl_shm_pool.create_buffer(id, offset, w, h, stride, format=XRGB8888) */
    at = msg_begin(O_POOL);
    o_u32(O_BUFFER); o_u32(0); o_u32((uint32_t)W); o_u32((uint32_t)H);
    o_u32((uint32_t)stride); o_u32(1);
    msg_end(at, 0);
    /* attach(buffer, 0, 0); damage(0,0,W,H); commit */
    at = msg_begin(O_SURFACE); o_u32(O_BUFFER); o_u32(0); o_u32(0); msg_end(at, 1);
    at = msg_begin(O_SURFACE); o_u32(0); o_u32(0); o_u32((uint32_t)W); o_u32((uint32_t)H); msg_end(at, 2);
    at = msg_begin(O_SURFACE); msg_end(at, 6);
    if (flush_msgs(-1) < 0) return 1;
    say("attached and committed -- the compositor has the pixels now");

    /* HOLD, RE-COMMITTING.  Not decoration: a gate moves the window with the
     * compositor's `geometry` verb and the window has to be redrawn at its new
     * place, exactly as a live client would.  Every 500 ms is slow enough to
     * cost nothing and fast enough that a screenshot is never of a stale
     * frame.
     *
     * THE DEADLINE IS WALL CLOCK, AND THAT IS THE WHOLE POINT.  This was
     * `for (t = 0; t < hold * 2; t++) { ...; pump(500); }` -- counting polls
     * and calling them half-seconds.  poll(2) returns THE INSTANT there is
     * anything to read, and the server sends a wl_buffer.release for every
     * commit, so the loop spun 240 times in a few milliseconds and the client
     * exited about eight seconds in.  The gate then found no window and
     * blamed the compositor.  A timeout is not a delay. */
    struct timespec t0;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (;;) {
        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        if (now.tv_sec - t0.tv_sec >= hold || closed) break;
        at = msg_begin(O_SURFACE); o_u32(O_BUFFER); o_u32(0); o_u32(0); msg_end(at, 1);
        at = msg_begin(O_SURFACE); o_u32(0); o_u32(0); o_u32((uint32_t)W); o_u32((uint32_t)H); msg_end(at, 2);
        at = msg_begin(O_SURFACE); msg_end(at, 6);
        if (flush_msgs(-1) < 0) return 1;
        int r;
        do {                            /* drain what the commit produced */
            r = pump(0);
            if (r == -2) return 2;
            if (r < 0) { say("connection closed by the server"); return 0; }
        } while (r == 1);
        struct timespec half = { 0, 500000000L };
        nanosleep(&half, NULL);
    }
    /* WHY IT STOPPED, not just that it did.  A client that quits early takes
     * its window with it, and a gate that then finds no window would blame the
     * compositor.  That happened on the first run of this file. */
    if (closed) say("the compositor sent xdg_toplevel.close -- stopping");
    else fprintf(stderr, "[wlsz] held for %d s, stopping\n", hold);
    return 0;
}
