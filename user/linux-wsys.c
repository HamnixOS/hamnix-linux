/* user/linux-wsys.c — /dev/wsys, the window system device, on Linux.
 *
 * WHAT THIS IS A PORT OF
 * ======================
 * sys/src/9/port/devwsys.ad.  In Hamnix that file is a KERNEL device: the
 * window table, the per-window scene buffers and the event rings are kernel
 * memory, and clients and the compositor both reach them by opening files
 * under /dev/wsys.  Nothing is copied across an RPC; the storage IS the
 * protocol.
 *
 * So the faithful Linux port of a kernel device is SHARED MEMORY, not a file
 * server.  One mapping (default /srv/wsys, which linuxinit mounts as tmpfs)
 * is MAP_SHARED into every process in the namespace; this file intercepts the
 * /dev/wsys/... paths in the syscall runtime and serves them out of it.  The
 * userland is unchanged and unaware: it opens, reads and writes text files.
 *
 * THE SURFACE, and where each part is used from
 * ---------------------------------------------
 *   /dev/wsys/ctl        write "newwindow\n" then READ IT BACK for the new
 *                        wid in ASCII decimal.  lib/hamui.ad:2298 does
 *                        exactly this, in two separate opens, so the answer
 *                        is remembered PER PROCESS (see last_new below) and
 *                        not in the shared table.
 *                        Other global verbs: raise/focus/desktop/ws/screen.
 *   /dev/wsys/self       the wid this task was spawned into, or empty.
 *                        hamui only accepts a value >= 2: wid 1 is the
 *                        foreground console window, which an app must not
 *                        take over.
 *   /dev/wsys/windows    "<wid> <title>\n" per mapped, decorated window —
 *                        the panel taskbar parses exactly this
 *                        (user/hampanelscene.ad:_refresh_windows).
 *   /dev/wsys/<wid>/ctl      geometry/decorate/z/title/commit/version/…
 *   /dev/wsys/<wid>/scene    the display list (lib/hamscene.ad grammar).
 *                            Written whole, then published by `commit` on
 *                            the window's ctl — the compositor only ever
 *                            reads a WHOLE frame, never a torn one.
 *   /dev/wsys/<wid>/keys     "<type> <code>\n"           routed key events
 *   /dev/wsys/<wid>/pointer  "<t> <x> <y> <btn> <dz>\n"  routed pointer
 *   /dev/wsys/<wid>/{event,text,cmd}   the other per-window rings
 *   everything else under /dev/wsys/   a named byte buffer (a "sink").
 *
 * WHY THE RINGS ARE READ/WRITE BOTH WAYS
 * --------------------------------------
 * In Hamnix the kernel routes input into the focused window's ring.  Here the
 * compositor is a user process, so it needs a way to do that — and the way is
 * the file it already has: it OPENS /dev/wsys/<wid>/keys FOR WRITING and
 * writes the event line.  The client reads it.  No new syscall is invented for
 * the compositor; it drives the same surface everything else does.  That is
 * what lets user/wsysd.ad be an ordinary Adder program.
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
#include <unistd.h>

#include "linux-wsys.h"

/* ------------------------------------------------------------------ *
 * The shared segment
 * ------------------------------------------------------------------ */
#define WSYS_MAGIC        0x53595357u        /* "WSYS" */
#define WSYS_VERSION      1
#define WSYS_MAX_WINDOWS  32
#define WSYS_SCENE_CAP    16384              /* = lib/hamscene.ad HAMSCENE_CAP */
#define WSYS_RING_CAP     8192
#define WSYS_TITLE_CAP    64
#define WSYS_SINKS        32
#define WSYS_SINK_NAME    64
#define WSYS_SINK_CAP     4096

struct wring {
    uint32_t r, w;                            /* byte counters, monotone */
    uint8_t  b[WSYS_RING_CAP];
};

struct wwin {
    uint32_t used;
    int32_t  wid;
    int32_t  pid;                             /* owner, 0 = unowned */
    int32_t  x, y, w, h, z;
    int32_t  decorate, visible, proto;
    uint32_t scene_len;                       /* published */
    uint32_t scene_gen;                       /* ++ on every commit */
    uint32_t stage_len;                       /* being written */
    char     title[WSYS_TITLE_CAP];
    uint8_t  scene[WSYS_SCENE_CAP];
    uint8_t  stage[WSYS_SCENE_CAP];
    struct wring keys, pointer, event, text, cmd;
};

struct wsink {
    uint32_t used;
    uint32_t len;
    uint32_t serial;      /* ++ per write; see the launch-queue note below */
    char     name[WSYS_SINK_NAME];
    uint8_t  b[WSYS_SINK_CAP];
};

struct wshm {
    uint32_t magic, version;
    int32_t  screen_w, screen_h;
    int32_t  focus_wid;
    int32_t  next_wid;
    int32_t  desktop;                         /* the rl5 flip: compositor owns fb */
    uint32_t gen;                             /* ++ on any published change */
    struct wwin  win[WSYS_MAX_WINDOWS];
    struct wsink sink[WSYS_SINKS];
};

static struct wshm *shm;

/* ------------------------------------------------------------------ *
 * WINDOW BACKBUFFERS — the v2 blit protocol
 *
 * devwsys.ad's #442 reshape: "kill the whole-window text/markup draw path and
 * move rasterization client-side. devwsys becomes a BLITTER: clients render
 * into a private backbuffer and submit (rect, src_image) blits + dirty-rect
 * invalidations. The compositor never sees a widget tree."  The wire format,
 * written to /dev/wsys/<wid>/draw/ctl, is quoted there and implemented here:
 *
 *   'B' x0 y0 x1 y1 fmt <pixels>   opaque blit into the backbuffer
 *   'D' x0 y0 x1 y1                dirty-rect invalidation
 *   'C' hot_x hot_y w h fmt <px>   cursor sprite (not yet composited)
 *
 * Integers are little-endian int32. A client opts in with `version 2` on its
 * window ctl; the compositor walks the v1 scene path or this one per window.
 *
 * THIS IS WHAT LETS A FOREIGN TOOLKIT ONTO THE SCREEN. The v1 scene is a text
 * display list capped at 16 KiB -- it can express a widget tree and cannot
 * express a photograph, so a browser or anything else that renders its own
 * pixels has no way in without this.
 *
 * The buffers live in their OWN mapping, not in the window table: a
 * screen-sized surface is 8 MiB and thirty-two of them would be a quarter of
 * a gigabyte of shared memory for windows that mostly do not use it. Four
 * slots are claimed on demand.
 * ------------------------------------------------------------------ */
/* Eight, not three.  Three was chosen when the only v2 client was the X
 * bridge and one window was the whole session; with a Wayland compositor
 * every toplevel is a v2 window, so three is "your fourth window is blank".
 * And it was blank SILENTLY: bb_for returned -1, the window still existed
 * with a taskbar entry and correct geometry, and nothing composited into it.
 *
 * The buffers are allocated lazily -- a slot costs nothing until something
 * blits -- so the cost of eight is address space in a mapping, not memory. */
#define BB_SLOTS   8
#define BB_W       1920
#define BB_H       1080
#define BB_BYTES   ((size_t)BB_W * BB_H * 4)

/* DOUBLE BUFFERED, and it has to be.
 *
 * With one page the compositor reads the surface while the client is writing
 * it, and a screendump of Firefox caught exactly that: the top of the window
 * from one frame and the rest from the next, offset, looking for all the world
 * like a driver bug.  'D' is the publish signal -- the blit protocol's
 * equivalent of the scene path's `commit` -- so it is what flips the page.
 * The compositor only ever reads a WHOLE frame, which is the same promise
 * scene clients already get.
 *
 * A client may blit only a dirty rect and expect the rest to persist, so the
 * new back page starts as a copy of the front -- taken lazily, on the first
 * blit after a flip, so a window that is not being drawn costs nothing. */
struct bbhdr {
    uint32_t used;
    int32_t  wid;
    int32_t  w, h;
    uint32_t gen;          /* ++ on every flip */
    uint32_t front;        /* which page the compositor reads */
    uint32_t started;      /* a frame is in progress on the back page */
};

struct bbshm {
    uint32_t magic;
    struct bbhdr slot[BB_SLOTS];
    uint8_t  px[BB_SLOTS][2][BB_W * BB_H * 4];
};

static struct bbshm *bb;

static int bb_attach(void)
{
    if (bb) return 0;
    const char *p = getenv("HAMWSYS_BB");
    const char *cands[4];
    int nc = 0;
    if (p && *p) cands[nc++] = p;
    cands[nc++] = "/srv/wsys.bb";
    cands[nc++] = "/dev/shm/hamnix-wsys-bb";
    cands[nc++] = "/tmp/hamnix-wsys-bb";
    /* Attach before create, per candidate -- see the long note in
     * shm_attach() below.  O_CREAT on a file another uid owns inside a
     * sticky world-writable directory is refused by fs.protected_regular,
     * and a v2 client that fell through to its own private backbuffer
     * segment would blit into pixels no compositor ever scans out. */
    int fd = -1;
    for (int i = 0; i < nc && fd < 0; i++) {
        fd = open(cands[i], O_RDWR);
        if (fd < 0)
            fd = open(cands[i], O_RDWR | O_CREAT, 0666);
    }
    if (fd < 0) return -1;
    /* See shm_attach() below: the 0666 above is masked to 0644 by the umask
     * the kernel gives PID 1, which locks every non-root client out of the
     * backing store once the DE session drops to the logged-in user. */
    if (fchmod(fd, 0666) < 0) { /* not the creator; mode already correct */ }
    struct stat st;
    if (fstat(fd, &st) < 0) { close(fd); return -1; }
    if ((uint64_t)st.st_size < sizeof(struct bbshm)
        && ftruncate(fd, (off_t)sizeof(struct bbshm)) < 0) {
        close(fd); return -1;
    }
    void *m = mmap(NULL, sizeof(struct bbshm), PROT_READ | PROT_WRITE,
                   MAP_SHARED, fd, 0);
    int e = errno;
    close(fd);
    if (m == MAP_FAILED) { errno = e; return -1; }
    bb = (struct bbshm *)m;
    if (bb->magic != 0x42425746u) {
        memset(bb, 0, sizeof *bb);
        bb->magic = 0x42425746u;
    }
    return 0;
}

static int bb_for(int wid, int create, int w, int h)
{
    if (bb_attach() < 0) return -1;
    for (int i = 0; i < BB_SLOTS; i++)
        if (bb->slot[i].used && bb->slot[i].wid == wid)
            return i;
    if (!create) return -1;
    for (int i = 0; i < BB_SLOTS; i++) {
        if (bb->slot[i].used) continue;
        memset(&bb->slot[i], 0, sizeof bb->slot[i]);
        memset(bb->px[i], 0, BB_BYTES * 2);
        bb->slot[i].used = 1;
        bb->slot[i].wid  = wid;
        bb->slot[i].w    = w > 0 && w <= BB_W ? w : BB_W;
        bb->slot[i].h    = h > 0 && h <= BB_H ? h : BB_H;
        return i;
    }
    errno = ENOSPC;
    return -1;
}

/* Re-fit a slot to a window's current size.
 *
 * bb_for fixes w/h at the FIRST blit and nothing could change them, so a
 * client that resized its surface stayed clipped to whatever size it opened
 * at -- which for a Wayland client is its initial configure, i.e. every
 * window that was ever resized was wrong.  The published page is cleared
 * rather than scaled: a resize means the client is about to redraw, and a
 * stretched copy of the old frame in the meantime is a worse answer than a
 * blank one it immediately overwrites. */
static void bb_resize(int wid, int w, int h)
{
    if (!bb || w <= 0 || h <= 0 || w > BB_W || h > BB_H) return;
    for (int i = 0; i < BB_SLOTS; i++) {
        struct bbhdr *hh = &bb->slot[i];
        if (!hh->used || hh->wid != wid) continue;
        if (hh->w == w && hh->h == h) return;
        hh->w = w;
        hh->h = h;
        hh->started = 0;
        memset(bb->px[i][0], 0, BB_BYTES);
        memset(bb->px[i][1], 0, BB_BYTES);
        hh->gen++;
        return;
    }
}

static void bb_release(int wid)
{
    if (!bb) return;
    for (int i = 0; i < BB_SLOTS; i++)
        if (bb->slot[i].used && bb->slot[i].wid == wid)
            bb->slot[i].used = 0;
}

static int32_t le32(const uint8_t *p)
{
    return (int32_t)((uint32_t)p[0] | ((uint32_t)p[1] << 8)
                   | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24));
}

/* One 'B' blit. `n` is what is available; returns the bytes consumed, or 0 if
 * the record is incomplete (the caller carries the remainder to the next
 * write -- a client is free to split a blit across write(2) calls). */
static uint64_t bb_blit(struct wwin *v, const uint8_t *b, uint64_t n)
{
    if (n < 18) return 0;
    int32_t x0 = le32(b + 1), y0 = le32(b + 5);
    int32_t x1 = le32(b + 9), y1 = le32(b + 13);
    uint8_t fmt = b[17];
    if (x1 <= x0 || y1 <= y0) return 18;
    int bpp = (fmt == 3) ? 1 : 4;                /* FMT_A8 is one byte */
    uint64_t need = (uint64_t)(x1 - x0) * (y1 - y0) * bpp;
    if (n < 18 + need) return 0;

    int slot = bb_for(v->wid, 1, v->w, v->h);
    if (slot < 0) return 18 + need;
    struct bbhdr *h = &bb->slot[slot];
    uint32_t back = h->front ^ 1u;
    if (!h->started) {
        /* Carry the last published frame forward: a client that blits only
         * what changed must not find the rest of its window blank. */
        memcpy(bb->px[slot][back], bb->px[slot][h->front], BB_BYTES);
        h->started = 1;
    }
    const uint8_t *src = b + 18;
    for (int32_t y = y0; y < y1; y++) {
        if (y < 0 || y >= h->h) continue;
        for (int32_t x = x0; x < x1; x++) {
            if (x < 0 || x >= h->w) continue;
            const uint8_t *s = src + ((uint64_t)(y - y0) * (x1 - x0)
                                      + (x - x0)) * bpp;
            uint8_t *d = &bb->px[slot][back][((uint64_t)y * h->w + x) * 4];
            if (fmt == 2) {                       /* FMT_BGRA8888 */
                d[0] = s[2]; d[1] = s[1]; d[2] = s[0]; d[3] = s[3];
            } else if (fmt == 3) {                /* FMT_A8 */
                d[0] = d[1] = d[2] = s[0]; d[3] = 255;
            } else {                              /* FMT_RGBA8888 */
                d[0] = s[0]; d[1] = s[1]; d[2] = s[2]; d[3] = s[3];
            }
        }
    }
    return 18 + need;
}

/* The wid this process got from its last `newwindow`.  Deliberately NOT in
 * the shared segment: two processes allocating at once would each read the
 * other's answer back.  lib/hamui.ad writes and reads in two separate opens,
 * so it must survive a close — but only within this process. */
static int32_t last_new = -1;

/* Set from fstat(2) on the segment at attach; see THE UID GATE below. */
static uid_t seg_owner = (uid_t)-1;
static int   seg_owner_known = 0;

static const char *shm_path(void)
{
    const char *p = getenv("HAMWSYS");
    if (p && *p) return p;
    /* /srv is the Plan 9 place for a posted server and linuxinit mounts it as
     * tmpfs.  /dev/shm and /tmp are the fallbacks for a host run, where there
     * is no Hamnix namespace at all. */
    return "/srv/wsys";
}

static int shm_attach(void)
{
    if (shm) return 0;

    const char *cands[3];
    int nc = 0;
    cands[nc++] = shm_path();
    cands[nc++] = "/dev/shm/hamnix-wsys";
    cands[nc++] = "/tmp/hamnix-wsys";

    /* ATTACH BEFORE CREATE, on every candidate.
     *
     * This used to be one open(O_RDWR|O_CREAT) per candidate, and O_CREAT on
     * an EXISTING file is the trap: fs.protected_regular (=2 on Debian and on
     * most current distributions) refuses O_CREAT opens of a file you do not
     * own inside a world-writable STICKY directory -- which is exactly what
     * /srv is (linuxinit mounts it 1777) and exactly the shape of a live
     * session: the segment belongs to root because wsysd made it, and the
     * client is `live`.  The open returned EACCES, and because a failure here
     * just moves to the next candidate, the client CREATED ITS OWN segment in
     * /dev/shm, initialised it, allocated window ids nobody composites and
     * drew into a screen that does not exist -- with no error anywhere.  That
     * is the same blind-session failure the 0666 chmod above was written to
     * prevent, arriving through a different door, and it is what this loop's
     * measured behaviour was when the uid gate's test first ran two uids
     * against one segment.  Opening without O_CREAT first means a segment
     * that is ALREADY THERE is joined, never re-created.
     *
     * Candidate ORDER is unchanged -- each candidate is tried both ways
     * before the next is considered -- so a stale /dev/shm segment still
     * cannot pre-empt the one this process was told to use. */
    int fd = -1;
    for (int i = 0; i < nc && fd < 0; i++) {
        fd = open(cands[i], O_RDWR);
        if (fd < 0)
            fd = open(cands[i], O_RDWR | O_CREAT, 0666);
    }
    if (fd < 0)
        return -1;
    /* THE WINDOW SYSTEM IS THIS FILE.  Every client -- compositor, panel,
     * terminal, app -- talks to /dev/wsys by mmap'ing it MAP_SHARED, so read
     * AND write access to it is the whole capability.  wsysd creates it first,
     * as uid 0, and open(2)'s mode argument is masked by the umask (022), so
     * it lands 0644.  A client running as the logged-in user (etc/rc.de-user
     * now ends with `setuid 1001`) then fails the O_RDWR open and falls
     * through to the /dev/shm and /tmp candidates -- where it happily creates
     * its OWN empty segment, initialises it with the default 1280x800
     * geometry, allocates window ids nobody is compositing, and draws into a
     * screen that does not exist.  No error is printed anywhere; the app just
     * never appears.  That is why this chmod is here rather than a note in the
     * rc: an unprivileged session that cannot draw is worse than a privileged
     * one that can.  The segment is a shared IPC rendezvous in a 1777 tmpfs --
     * 0666 is its correct mode, the same as /dev/shm.  Per-window authority is
     * NOT a file-mode question: devwsys gates the system-chrome ctl verbs on
     * uid separately, and THE UID GATE section below is that gate, ported. */
    if (fchmod(fd, 0666) < 0) { /* not the creator; mode already correct */ }

    struct stat st;
    if (fstat(fd, &st) < 0) { int e = errno; close(fd); errno = e; return -1; }
    /* WHO THE HOST OWNER IS, decided once, from the kernel, at attach.  See
     * the UID GATE block below for why it is the segment's owner and not a
     * hardcoded 0. */
    seg_owner = st.st_uid;
    seg_owner_known = 1;
    if ((uint64_t)st.st_size < sizeof(struct wshm)) {
        if (ftruncate(fd, (off_t)sizeof(struct wshm)) < 0) {
            int e = errno; close(fd); errno = e; return -1;
        }
    }
    void *m = mmap(NULL, sizeof(struct wshm), PROT_READ | PROT_WRITE,
                   MAP_SHARED, fd, 0);
    int e = errno;
    close(fd);                                 /* the mapping keeps it alive */
    if (m == MAP_FAILED) { errno = e; return -1; }

    shm = (struct wshm *)m;
    if (shm->magic != WSYS_MAGIC) {
        /* First attacher initialises.  A fresh tmpfs file is all zeroes, so
         * this is the only place the defaults are set. */
        memset(shm, 0, sizeof(*shm));
        shm->magic    = WSYS_MAGIC;
        shm->version  = WSYS_VERSION;
        shm->next_wid = 2;                     /* 0 invalid, 1 = foreground */
        /* ZERO MEANS "NOBODY HAS SAID YET", and it has to.  This used to be
         * 1280x800 — the development VM's mode, written in as a default — and
         * a default here is indistinguishable from an answer: /dev/wsys/screen
         * would confidently report a geometry that no compositor had ever
         * measured, on a machine that might be 1920x1080.  The only process
         * entitled to fill these in is the one that set the mode, via the
         * `screen W H` ctl verb (wsysd's announce_screen).  Until it does,
         * reads of /dev/wsys/screen fail with ENXIO and the caller knows it
         * does not know.  Nothing else in this file reads these fields. */
        shm->screen_w = 0;
        shm->screen_h = 0;
        shm->focus_wid = 0;
    }
    return 0;
}

/* ------------------------------------------------------------------ *
 * Small helpers
 * ------------------------------------------------------------------ */
static struct wwin *win_find(int wid)
{
    if (!shm || wid <= 0) return NULL;
    for (int i = 0; i < WSYS_MAX_WINDOWS; i++)
        if (shm->win[i].used && shm->win[i].wid == wid)
            return &shm->win[i];
    return NULL;
}

static struct wwin *win_alloc(int32_t pid)
{
    if (shm_attach() < 0) return NULL;
    for (int i = 0; i < WSYS_MAX_WINDOWS; i++) {
        struct wwin *v = &shm->win[i];
        if (v->used) continue;
        memset(v, 0, sizeof(*v));
        v->used     = 1;
        v->wid      = shm->next_wid++;
        v->pid      = pid;
        v->x = 120; v->y = 90; v->w = 640; v->h = 480;
        v->z        = 5;
        v->visible  = 1;
        v->decorate = 0;
        v->proto    = 1;
        /* Until the client sends `title`, the taskbar shows "winN" — the same
         * placeholder Hamnix uses, which hampanelscene.ad's comment names. */
        v->title[0] = 'w'; v->title[1] = 'i'; v->title[2] = 'n';
        {
            char d[12]; int n = 0, x = v->wid;
            if (x == 0) d[n++] = '0';
            while (x > 0) { d[n++] = (char)('0' + x % 10); x /= 10; }
            for (int k = 0; k < n && 3 + k < WSYS_TITLE_CAP - 1; k++)
                v->title[3 + k] = d[n - 1 - k];
        }
        shm->gen++;
        return v;
    }
    errno = ENOSPC;
    return NULL;
}

/* ================================================================== *
 * THE UID GATE — the port of devwsys.ad's current_task_is_hostowner()
 * ==================================================================
 *
 * WHAT IS BEING PORTED.  devwsys.ad has exactly three permission shapes and
 * this block reproduces all three:
 *
 *   1. devwsys_ctl_write (devwsys.ad:3625)
 *          if current_task_is_hostowner() == 0:
 *              set_current_errstr("/dev/wsys/ctl: permission denied ...")
 *      i.e. the system-wide ctl is HOSTOWNER-ONLY -- but only AFTER a
 *      deliberate list of verbs parsed BEFORE the gate, which any uid may
 *      write.  Those verbs, and devwsys's stated reason for each, are:
 *        newwindow  a client must be able to create its OWN window; the DE
 *                   runs as a non-owner uid ("so a NOBODY-uid app can
 *                   self-serve a window")
 *        desktop    the rl5 flip is "the DE claiming its own screen"
 *        wallpaper  "Choosing your own desktop picture is not a host-owner
 *                   privilege; it changes no other process's view of
 *                   anything."
 *        perf ptrlat sysirq wklat m2p ptrsvc
 *                   instruments -- "a diagnostic you cannot turn on from the
 *                   session you are diagnosing is not a diagnostic"
 *      EVERY other ctl verb (appmenu, setapp, run, lock, notif, cycler,
 *      calpop, rband, sessui, sysmon, ctxmenu, snap, resize, osd, tray, ws,
 *      kbd, alloc, free, frame) is behind the gate.  That list is not
 *      invented here; it is the set of verbs devwsys parses after line 3625.
 *
 *   2. hostowner OR THE WINDOW'S OWNER, for everything addressed to one
 *      window: /dev/wsys/wctl (6617), <wid>/scene (8255), <wid>/event
 *      (8337), <wid>/ctl (8445), the draw path (2334).  devwsys decides
 *      "owner" with _wsys_caller_owns_wid, which walks the caller's
 *      parent-pid chain looking for the wid's stamped owner pid.
 *
 *   3. NO GATE AT ALL, deliberately, on the client->compositor request
 *      channels: devwsys_appmenu_launch_write ("Anybody (not just
 *      hostowner) may queue a launch: hamappmenu runs as a regular
 *      DE-spawned client, NOT uid 1"), devwsys_post_write and
 *      devwsys_lock_verify_write.  Reads are ungated everywhere.
 *
 * WHO THE HOST OWNER IS ON THIS LINE.  Hamnix's hostowner is the uid that
 * owns the machine.  Translating that to "uid 0" alone would be wrong twice:
 * it is false in the offscreen harness (where wsysd and its clients are one
 * ordinary user and there is no root anywhere), and it hardcodes a policy the
 * kernel already records.  The honest answer is THE UID THAT OWNS THE
 * SEGMENT: /dev/wsys IS the file /srv/wsys, and whoever created it is whoever
 * brought this window system up.  On a real boot that is wsysd, started by
 * /etc/rc.d/rc.5 before anything drops privilege, so it is root; in the
 * offscreen harness it is the invoking user, and every process there is that
 * user, so nothing is refused.  root is always the host owner as well, since
 * root can chmod/chown the segment at will and pretending otherwise would be
 * theatre.  st_uid comes from fstat(2) on the mapping's own fd -- the kernel's
 * answer, not a claim by any caller.
 *
 * HOW THE CALLER'S UID IS ESTABLISHED, and why it is honest.  Unlike devwsys
 * this is not a kernel device with a per-open process context: /dev/wsys is a
 * shared segment and this code RUNS INSIDE THE CALLING PROCESS, reached
 * through the syscall runtime's devtab.  So the uid asking is geteuid() --
 * the writer's own credentials, which it cannot lie about to itself, and
 * which the `setuid 1001` at the end of /etc/rc.de-user has really moved
 * (sys_setuid is a real setuid(2); see user/linux-syscalls.c).  There is no
 * spoofable "which uid is asking" field anywhere in this path.
 *
 * WHAT THIS GATE IS NOT, said plainly.  Because the segment is 0666 and
 * mapped MAP_SHARED into every client, a program that DOES NOT GO THROUGH
 * THIS FILE -- one that opens /srv/wsys and mmaps it itself -- can still
 * write any byte of the window table, and no check here can stop it.  This
 * gate binds every caller of the /dev/wsys file protocol, which is every
 * program in the tree and every program the DE will spawn; it is not a
 * kernel privilege boundary the way devwsys's check is.  Making it one means
 * the chrome state stops living in a world-writable mapping: either a second
 * segment, mode 0644 and owned by the host owner, that non-owners map
 * PROT_READ (the file mode then IS the gate, enforced by the kernel), or
 * moving the chrome verbs to an RPC to wsysd.  Both are larger changes than
 * a permission check and the second needs user/wsysd.ad, which this task does
 * not own.  Named here so it is not mistaken for solved -- the same reason
 * the limit it replaces was named in etc/rc.de-user.
 *
 * FAIL CLOSED.  If the segment owner could not be established (no fstat, no
 * attach) hostowner() answers 0, which refuses chrome verbs rather than
 * waving them through.  Likewise owns_wid(): an unstamped window (pid 0) and
 * a parent chain that cannot be walked both answer "not the owner".
 */
static int32_t take_int(const char *s, size_t *p, size_t n);      /* below */
static int     sink_is_launch_queue(const char *name);            /* below */

static int hostowner(void)
{
    uid_t me = geteuid();
    if (me == 0) return 1;                     /* root owns the box */
    if (!seg_owner_known) return 0;            /* FAIL CLOSED */
    return me == seg_owner;
}

/* ppid of `pid`, or -1.  getppid(2) for ourselves; /proc otherwise.  A
 * /proc that is not Linux's (the DE namespace binds '#p' over /proc) simply
 * fails to parse, which ends the walk -- it can only ever REFUSE, never
 * grant. */
static pid_t proc_ppid(pid_t pid)
{
    if (pid == getpid()) return getppid();
    char path[64], buf[512];
    snprintf(path, sizeof path, "/proc/%d/stat", (int)pid);
    int fd = open(path, O_RDONLY);
    if (fd < 0) return -1;
    ssize_t n = read(fd, buf, sizeof buf - 1);
    close(fd);
    if (n <= 0) return -1;
    buf[n] = '\0';
    /* "<pid> (<comm>) <state> <ppid> ..." -- comm can contain spaces and
     * parens, so scan to the LAST ')'. */
    char *p = strrchr(buf, ')');
    if (!p) return -1;
    p++;
    while (*p == ' ') p++;
    while (*p && *p != ' ') p++;               /* the state letter */
    while (*p == ' ') p++;
    if (*p < '0' || *p > '9') return -1;
    return (pid_t)strtol(p, NULL, 10);
}

/* devwsys's _wsys_caller_owns_wid: does the caller's parent-pid chain reach
 * the wid's stamped owner?  Depth-bounded exactly as devwsys bounds it. */
static int owns_wid(int wid)
{
    struct wwin *v = win_find(wid);
    if (!v || v->pid == 0) return 0;
    pid_t p = getpid();
    for (int depth = 0; depth < 8; depth++) {
        if ((int32_t)p == v->pid) return 1;
        pid_t q = proc_ppid(p);
        if (q <= 0 || q == p) break;
        p = q;
    }
    return 0;
}

static int deny(void)
{
    errno = EPERM;
    return -1;
}

/* The verbs devwsys parses BEFORE its hostowner gate.  `s`/`n` is one ctl
 * line; only the leading token is compared. */
static int ctl_verb_is_ungated(const char *s, size_t n)
{
    static const char *open_verbs[] = {
        "newwindow", "desktop", "wallpaper",
        "perf", "ptrlat", "sysirq", "wklat", "m2p", "ptrsvc",
    };
    size_t vn = 0;
    while (vn < n && s[vn] != ' ' && s[vn] != '\t' && s[vn] != '\n') vn++;
    for (size_t i = 0; i < sizeof open_verbs / sizeof *open_verbs; i++)
        if (strlen(open_verbs[i]) == vn && !strncmp(s, open_verbs[i], vn))
            return 1;
    return 0;
}

/* raise/focus/close name ONE window, so they take shape 2 (owner-or-host)
 * rather than shape 1.  devwsys has no global raise/focus -- they are this
 * line's spelling of what devwsys does through <wid>/ctl and wctl, whose
 * rule is exactly owner-or-hostowner, so that is the rule applied.  Returns
 * the target wid, or 0 if this is not one of those verbs. */
static int ctl_verb_window_target(const char *s, size_t n)
{
    static const char *win_verbs[] = { "raise", "focus", "close" };
    size_t vn = 0;
    while (vn < n && s[vn] != ' ' && s[vn] != '\t' && s[vn] != '\n') vn++;
    for (size_t i = 0; i < sizeof win_verbs / sizeof *win_verbs; i++) {
        if (strlen(win_verbs[i]) != vn || strncmp(s, win_verbs[i], vn))
            continue;
        size_t p = vn;
        int32_t wid = take_int(s, &p, n);
        return wid > 0 ? wid : -1;             /* -1: named verb, no wid */
    }
    return 0;
}

/* May this uid write the sink called `name`?
 *
 * A sink is this line's catch-all: ctl_global() routes every verb it does not
 * implement into a sink NAMED FOR THE VERB, and the DE components read them
 * back there.  That makes `echo "1 0" > /dev/wsys/lock` and `echo "lock 1 0" >
 * /dev/wsys/ctl` the same act, so they must carry the same permission -- a
 * gate on only one of the two spellings is not a gate.  Hence: sinks are
 * host-owner-only to write, except the three request channels devwsys
 * deliberately leaves open to any uid, and except the per-window sinks
 * (`<wid>/wctl` and friends), which take the window-owner rule.
 *
 * Reads are never gated, here or in devwsys: a client must be able to read
 * the model it renders (hamcycler, hamnotif, hamlock, hamrun all do exactly
 * that, as uid 1001).
 *
 * Unknown names fail closed.  devwsys enumerates every file it serves and a
 * path it does not name does not exist; the catch-all is a convenience of
 * this port, and a convenience must not become the way a future chrome file
 * arrives world-writable. */
static int sink_write_allowed(const char *name)
{
    if (name[0] >= '0' && name[0] <= '9') {    /* "<wid>/<leaf>" */
        int wid = 0;
        const char *p = name;
        while (*p >= '0' && *p <= '9') { wid = wid * 10 + (*p - '0'); p++; }
        if (*p == '/')
            return hostowner() || owns_wid(wid);
    }
    if (sink_is_launch_queue(name)) return 1;  /* devwsys_appmenu_launch_write */
    if (!strcmp(name, "post")) return 1;       /* devwsys_post_write          */
    if (!strcmp(name, "lock/verify")) return 1;/* devwsys_lock_verify_write   */
    return hostowner();
}

static void ring_write(struct wring *q, const uint8_t *b, uint64_t n)
{
    for (uint64_t i = 0; i < n; i++) {
        q->b[q->w % WSYS_RING_CAP] = b[i];
        q->w++;
        /* Overwrite the oldest byte rather than block.  An event ring nobody
         * is draining must never wedge the compositor. */
        if (q->w - q->r > WSYS_RING_CAP)
            q->r = q->w - WSYS_RING_CAP;
    }
}

static uint64_t ring_read(struct wring *q, uint8_t *b, uint64_t cap)
{
    uint64_t n = 0;
    while (n < cap && q->r != q->w) {
        b[n++] = q->b[q->r % WSYS_RING_CAP];
        q->r++;
    }
    return n;
}

static struct wsink *sink_find(const char *name, int create)
{
    if (shm_attach() < 0) return NULL;
    struct wsink *free_slot = NULL;
    for (int i = 0; i < WSYS_SINKS; i++) {
        struct wsink *s = &shm->sink[i];
        if (s->used) {
            if (strncmp(s->name, name, WSYS_SINK_NAME - 1) == 0)
                return s;
        } else if (!free_slot) {
            free_slot = s;
        }
    }
    if (!create || !free_slot) return NULL;
    memset(free_slot, 0, sizeof(*free_slot));
    free_slot->used = 1;
    strncpy(free_slot->name, name, WSYS_SINK_NAME - 1);
    return free_slot;
}

/* Decimal parse; advances *p past the digits.  Returns -1 if there are none. */
static int32_t take_int(const char *s, size_t *p, size_t n)
{
    while (*p < n && (s[*p] == ' ' || s[*p] == '\t')) (*p)++;
    int neg = 0;
    if (*p < n && s[*p] == '-') { neg = 1; (*p)++; }
    if (*p >= n || s[*p] < '0' || s[*p] > '9') return -1;
    int32_t v = 0;
    while (*p < n && s[*p] >= '0' && s[*p] <= '9') {
        v = v * 10 + (s[*p] - '0');
        (*p)++;
    }
    return neg ? -v : v;
}

static uint64_t put_int(uint8_t *out, uint64_t at, int32_t v)
{
    char d[12];
    int n = 0;
    uint32_t x;
    if (v < 0) { out[at++] = '-'; x = (uint32_t)(-v); } else x = (uint32_t)v;
    if (x == 0) d[n++] = '0';
    while (x) { d[n++] = (char)('0' + x % 10); x /= 10; }
    while (n) out[at++] = (uint8_t)d[--n];
    return at;
}

/* ------------------------------------------------------------------ *
 * Path classification
 * ------------------------------------------------------------------ */
static const char *WSYS_ROOT = "/dev/wsys";

/* Fills f->leaf/f->wid/f->name.  Returns the leaf kind. */
static int classify(const char *path, struct hamwsys_file *f)
{
    size_t rl = strlen(WSYS_ROOT);
    if (strncmp(path, WSYS_ROOT, rl) != 0)
        return HAMWSYS_NONE;
    const char *p = path + rl;
    if (*p == '\0' || (p[0] == '/' && p[1] == '\0')) {
        if (f) { f->leaf = HAMWSYS_DIR; f->wid = 0; }
        return HAMWSYS_DIR;
    }
    if (*p != '/')
        return HAMWSYS_NONE;                   /* /dev/wsysfoo is not ours */
    p++;

    int leaf = HAMWSYS_NONE, wid = 0;
    char name[64];

    if (p[0] >= '0' && p[0] <= '9') {
        /* /dev/wsys/<wid>/<leaf> */
        size_t i = 0;
        while (p[i] >= '0' && p[i] <= '9') { wid = wid * 10 + (p[i] - '0'); i++; }
        if (p[i] == '\0') {
            leaf = HAMWSYS_DIR;
        } else if (p[i] == '/') {
            const char *l = p + i + 1;
            if      (!strcmp(l, "ctl"))     leaf = HAMWSYS_WIN_CTL;
            else if (!strcmp(l, "scene"))   leaf = HAMWSYS_WIN_SCENE;
            else if (!strcmp(l, "keys"))    leaf = HAMWSYS_WIN_KEYS;
            else if (!strcmp(l, "pointer")) leaf = HAMWSYS_WIN_POINTER;
            else if (!strcmp(l, "event"))   leaf = HAMWSYS_WIN_EVENT;
            else if (!strcmp(l, "text"))    leaf = HAMWSYS_WIN_TEXT;
            else if (!strcmp(l, "cmd"))     leaf = HAMWSYS_WIN_CMD;
            else if (!strcmp(l, "draw/ctl")) leaf = HAMWSYS_DRAWCTL;
            else if (!strcmp(l, "backbuffer")) leaf = HAMWSYS_BACKBUF;
            else                            leaf = HAMWSYS_SINK;  /* wctl, … */
        } else {
            return HAMWSYS_NONE;
        }
    } else if (!strcmp(p, "ctl")) {
        leaf = HAMWSYS_CTL;
    } else if (!strcmp(p, "self")) {
        leaf = HAMWSYS_SELF;
    } else if (!strcmp(p, "windows")) {
        leaf = HAMWSYS_WINDOWS;
    } else if (!strcmp(p, "screen")) {
        leaf = HAMWSYS_SCREEN;
    } else {
        leaf = HAMWSYS_SINK;
    }

    if (f) {
        f->leaf = leaf;
        f->wid  = wid;
        if (leaf == HAMWSYS_SINK) {
            /* The sink name is the whole path below /dev/wsys/, so
             * "5/wctl" and "wallpaper" are distinct buffers. */
            snprintf(name, sizeof name, "%s", p);
            memcpy(f->name, name, sizeof f->name < sizeof name
                                  ? sizeof f->name : sizeof name);
            f->name[sizeof f->name - 1] = '\0';
        } else {
            f->name[0] = '\0';
        }
    }
    return leaf;
}

/* A LAUNCH QUEUE: /dev/wsys/run/launch, /dev/wsys/appmenu/launch.
 *
 * These are not plain buffers.  A client writes a bare "<prog>\n" and the
 * DEVICE stamps a monotone serial, so a reader sees "<serial> <prog>\n" and
 * can tell a NEW request from the one it already ran.  user/hamappmenu.ad
 * writes only the path (it never renders a serial) and both readers --
 * hampanelscene's _drain_one_launch_queue and hamUId's run_drain_launch --
 * parse a leading decimal first.  Without the stamp every reader sees serial
 * 0, treats it as "empty", and nothing ever launches.
 *
 * Serial 0 means "nothing yet", which is why the counter starts at 1. */
static int sink_is_launch_queue(const char *name)
{
    size_t n = strlen(name);
    return n >= 6 && !strcmp(name + n - 6, "launch");
}

int hamwsys_kind(const char *path)
{
    if (!path) return HAMWSYS_NONE;
    return classify(path, NULL);
}

/* ------------------------------------------------------------------ *
 * Snapshot renderers (the read side of the finite-content files)
 *
 * Plan 9's "snapshot once" read semantics: the content is rendered at open
 * and the fd walks it, so `cat` terminates and a reader never sees a listing
 * change under it.  devwsys.ad's BOUNDARY LAW block says this in as many
 * words.
 * ------------------------------------------------------------------ */
static int snap_set(struct hamwsys_file *f, const uint8_t *b, uint64_t n)
{
    free(f->snap);
    f->snap = NULL;
    f->snaplen = 0;
    if (n == 0) return 0;
    f->snap = (uint8_t *)malloc((size_t)n);
    if (!f->snap) { errno = ENOMEM; return -1; }
    memcpy(f->snap, b, (size_t)n);
    f->snaplen = n;
    return 0;
}

static int snap_windows(struct hamwsys_file *f)
{
    uint8_t buf[WSYS_MAX_WINDOWS * (WSYS_TITLE_CAP + 16)];
    uint64_t n = 0;
    /* Lowest wid first: the taskbar shows windows in the order they opened. */
    for (int pass = 2; pass < shm->next_wid; pass++) {
        struct wwin *v = win_find(pass);
        if (!v || !v->visible || !v->decorate) continue;
        n = put_int(buf, n, v->wid);
        buf[n++] = ' ';
        for (int k = 0; k < WSYS_TITLE_CAP && v->title[k]; k++)
            buf[n++] = (uint8_t)v->title[k];
        buf[n++] = '\n';
    }
    return snap_set(f, buf, n);
}

static int snap_self(struct hamwsys_file *f)
{
    uint8_t buf[16];
    int32_t me = (int32_t)getpid(), par = (int32_t)getppid();
    struct wwin *mine = NULL;
    for (int i = 0; i < WSYS_MAX_WINDOWS && !mine; i++)
        if (shm->win[i].used && shm->win[i].pid == me)
            mine = &shm->win[i];
    /* "creator pid OR ANCESTOR" — a task spawned into a window by hamUI is
     * the child of the process whose pid was stamped. */
    for (int i = 0; i < WSYS_MAX_WINDOWS && !mine; i++)
        if (shm->win[i].used && shm->win[i].pid == par)
            mine = &shm->win[i];
    if (!mine)
        return snap_set(f, NULL, 0);           /* empty: caller self-allocates */
    uint64_t n = put_int(buf, 0, mine->wid);
    buf[n++] = '\n';
    return snap_set(f, buf, n);
}

/* /dev/wsys/screen — "<w> <h>\n", the READ side of the `screen W H` ctl verb.
 *
 * The write side has existed since this file did: wsysd learns the mode from
 * /dev/fb (it is the process that legitimately owns the device) and announces
 * it here before it serves a frame.  Nothing could READ it back, so every DE
 * client that needed the screen size went to /dev/fb itself — which works on
 * fbdev and CANNOT work on raw DRM/KMS, where master is exclusive and the
 * compositor holds it.  Those clients each had a literal 800x600 in the
 * failure branch, so the whole desktop laid itself out for a screen that did
 * not exist and exited 0.  lib/hamscreen.ad is the client end of this file.
 *
 * ENXIO WHEN UNANNOUNCED, and that is the point.  A zero here means the
 * compositor has not published a geometry yet; answering "0 0", or an empty
 * read, or a plausible default, would hand the caller something it could
 * mistake for an answer.  The open fails instead, loudly, and the client
 * waits for the compositor or says why it is stopping. */
static int snap_screen(struct hamwsys_file *f)
{
    if (shm->screen_w <= 0 || shm->screen_h <= 0) { errno = ENXIO; return -1; }
    uint8_t b[32];
    uint64_t n = put_int(b, 0, shm->screen_w);
    b[n++] = ' ';
    n = put_int(b, n, shm->screen_h);
    b[n++] = '\n';
    return snap_set(f, b, n);
}

static int snap_ctl(struct hamwsys_file *f)
{
    /* Reading the global ctl answers the wid this process most recently
     * created — the second half of the `newwindow` handshake. */
    if (last_new < 0)
        return snap_set(f, NULL, 0);
    uint8_t buf[16];
    uint64_t n = put_int(buf, 0, last_new);
    buf[n++] = '\n';
    return snap_set(f, buf, n);
}

static int snap_win_ctl(struct hamwsys_file *f, struct wwin *v)
{
    /* Plan 9's rule: reading a ctl file answers the state the verbs set.
     * This is how the compositor learns a window's geometry and z — it has no
     * private syscall, only the files every client has.
     *
     *   "<wid> <x> <y> <w> <h> <z> <decorate> <visible> <proto> <scene_gen>
     *    <backbuffer_gen>\n"
     *
     * The two generation counters are the frame counters: scene_gen changes
     * only on `commit`, backbuffer_gen only on a v2 dirty-rect, so a
     * compositor that remembers them repaints exactly the windows that
     * changed and rasterizes nothing else. */
    uint8_t b[128];
    uint64_t n = 0;
    int bslot = bb_for(v->wid, 0, 0, 0);
    int32_t fields[11] = { v->wid, v->x, v->y, v->w, v->h, v->z,
                           v->decorate, v->visible, v->proto,
                           (int32_t)v->scene_gen,
                           bslot >= 0 ? (int32_t)bb->slot[bslot].gen : 0 };
    for (int i = 0; i < 11; i++) {
        if (i) b[n++] = ' ';
        n = put_int(b, n, fields[i]);
    }
    b[n++] = '\n';
    return snap_set(f, b, n);
}

static int snap_dir(struct hamwsys_file *f)
{
    /* The runtime's directory reads are a packed "NAME\n" stream — the same
     * shape sys_open on a real directory produces (see linux-syscalls.c's
     * dirtab).  Neither "." nor ".." appears, for the reason recorded there:
     * the tree's recursive walkers have no self/parent guard. */
    uint8_t buf[1024];
    uint64_t n = 0;
    if (f->wid == 0) {
        const char *fixed[] = { "ctl", "self", "windows", "screen" };
        for (unsigned i = 0; i < sizeof fixed / sizeof fixed[0]; i++) {
            for (const char *c = fixed[i]; *c; c++) buf[n++] = (uint8_t)*c;
            buf[n++] = '\n';
        }
        for (int i = 0; i < WSYS_MAX_WINDOWS; i++) {
            if (!shm->win[i].used) continue;
            n = put_int(buf, n, shm->win[i].wid);
            buf[n++] = '\n';
        }
    } else {
        if (!win_find(f->wid)) { errno = ENOENT; return -1; }
        const char *leaves[] = { "ctl", "scene", "keys", "pointer",
                                 "event", "text", "cmd" };
        for (unsigned i = 0; i < sizeof leaves / sizeof leaves[0]; i++) {
            for (const char *c = leaves[i]; *c; c++) buf[n++] = (uint8_t)*c;
            buf[n++] = '\n';
        }
    }
    return snap_set(f, buf, n);
}

/* ------------------------------------------------------------------ *
 * open / read / write / close
 * ------------------------------------------------------------------ */
int hamwsys_open(const char *path, int for_write, struct hamwsys_file *f)
{
    memset(f, 0, sizeof *f);
    if (classify(path, f) == HAMWSYS_NONE) { errno = ENODEV; return -1; }
    if (shm_attach() < 0) return -1;
    f->write = for_write;
    f->off = 0;

    /* THE GATE, AT OPEN.  It has to be here and not only in hamwsys_write
     * because opening for writing already MUTATES: a sink is truncated, a
     * scene's staging buffer is reset, and the draw ctl flips the window to
     * protocol 2 and allocates a backbuffer.  A refusal that still let those
     * happen would be the success-shaped kind of wrong -- the caller gets
     * EPERM and the window it was not allowed to touch is blank anyway.
     * hamwsys_write checks again: a descriptor can outlive the privilege
     * that opened it (an fd inherited across /etc/rc.de-user's setuid). */
    if (for_write) {
        switch (f->leaf) {
        case HAMWSYS_WIN_CTL: case HAMWSYS_WIN_SCENE: case HAMWSYS_WIN_KEYS:
        case HAMWSYS_WIN_POINTER: case HAMWSYS_WIN_EVENT: case HAMWSYS_WIN_TEXT:
        case HAMWSYS_WIN_CMD: case HAMWSYS_DRAWCTL: case HAMWSYS_BACKBUF:
            if (!win_find(f->wid)) { errno = ENOENT; return -1; }
            if (!hostowner() && !owns_wid(f->wid)) return deny();
            break;
        case HAMWSYS_SINK:
            if (!sink_write_allowed(f->name)) return deny();
            break;
        default:
            break;                             /* ctl is gated per verb */
        }
    }

    switch (f->leaf) {
    case HAMWSYS_BACKBUF: {
        struct wwin *v = win_find(f->wid);
        if (!v) { errno = ENOENT; return -1; }
        if (bb_for(v->wid, 0, 0, 0) < 0 && !for_write) { errno = ENOENT; return -1; }
        return 0;
    }
    case HAMWSYS_DRAWCTL: {
        struct wwin *v = win_find(f->wid);
        if (!v) { errno = ENOENT; return -1; }
        if (for_write) {
            /* Opening the draw sink IS the v2 opt-in as far as the compositor
             * is concerned: a client that blits pixels is not going to send a
             * scene, and treating it as v1 would show an empty window. */
            v->proto = 2;
            bb_for(v->wid, 1, v->w, v->h);
            shm->gen++;
        }
        return 0;
    }
    case HAMWSYS_WIN_CTL: case HAMWSYS_WIN_SCENE: case HAMWSYS_WIN_KEYS:
    case HAMWSYS_WIN_POINTER: case HAMWSYS_WIN_EVENT: case HAMWSYS_WIN_TEXT:
    case HAMWSYS_WIN_CMD: {
        struct wwin *v = win_find(f->wid);
        if (!v) { errno = ENOENT; return -1; }
        /* Opening the scene for writing starts a fresh frame — the client
         * writes the whole display list, then publishes it with `commit`. */
        if (f->leaf == HAMWSYS_WIN_SCENE && for_write)
            v->stage_len = 0;
        if (f->leaf == HAMWSYS_WIN_SCENE && !for_write)
            return snap_set(f, v->scene, v->scene_len);
        if (f->leaf == HAMWSYS_WIN_CTL && !for_write)
            return snap_win_ctl(f, v);
        return 0;
    }
    case HAMWSYS_SCREEN:
        /* Read-only.  The way to SET the screen size is `screen W H` on the
         * global ctl, which is the compositor's to write; a second writable
         * spelling of the same state is how two sources of truth start. */
        if (for_write) { errno = EACCES; return -1; }
        return snap_screen(f);
    case HAMWSYS_WINDOWS: return for_write ? 0 : snap_windows(f);
    case HAMWSYS_SELF:    return for_write ? 0 : snap_self(f);
    case HAMWSYS_CTL:     return for_write ? 0 : snap_ctl(f);
    case HAMWSYS_DIR:     return snap_dir(f);
    case HAMWSYS_SINK: {
        struct wsink *s = sink_find(f->name, for_write);
        if (for_write) {
            if (!s) { errno = ENOSPC; return -1; }
            s->len = 0;                        /* open-for-write truncates */
            return 0;
        }
        if (!s) return snap_set(f, NULL, 0);   /* never written: empty, not ENOENT */
        if (sink_is_launch_queue(f->name)) {
            uint8_t t[WSYS_SINK_CAP + 16];
            uint64_t n = put_int(t, 0, (int32_t)s->serial);
            t[n++] = ' ';
            uint32_t k = s->len;
            if (k > WSYS_SINK_CAP) k = WSYS_SINK_CAP;
            memcpy(t + n, s->b, k);
            n += k;
            return snap_set(f, t, n);
        }
        return snap_set(f, s->b, s->len);
    }
    default: errno = ENODEV; return -1;
    }
}

int64_t hamwsys_read(struct hamwsys_file *f, uint8_t *buf, uint64_t cap)
{
    if (!shm) { errno = EIO; return -EIO; }

    /* The event rings are live, not snapshots: a read DRAINS whatever has
     * arrived and returns 0 when there is nothing.  hamui polls them
     * non-blocking, so 0 must mean "nothing yet", never EOF-forever. */
    struct wwin *v = NULL;
    struct wring *q = NULL;
    switch (f->leaf) {
    case HAMWSYS_WIN_KEYS:    v = win_find(f->wid); if (v) q = &v->keys;    break;
    case HAMWSYS_WIN_POINTER: v = win_find(f->wid); if (v) q = &v->pointer; break;
    case HAMWSYS_WIN_EVENT:   v = win_find(f->wid); if (v) q = &v->event;   break;
    case HAMWSYS_WIN_TEXT:    v = win_find(f->wid); if (v) q = &v->text;    break;
    case HAMWSYS_WIN_CMD:     v = win_find(f->wid); if (v) q = &v->cmd;     break;
    default: break;
    }
    if (q)
        return (int64_t)ring_read(q, buf, cap);

    if (f->leaf == HAMWSYS_BACKBUF) {
        /* The v2 pixels, straight out of the shared surface. RGBA8888, row
         * major, the window's own width -- the compositor seeks and reads it
         * exactly like any other file. */
        int slot = bb_for(f->wid, 0, 0, 0);
        if (slot < 0) return 0;
        uint64_t size = (uint64_t)bb->slot[slot].w * bb->slot[slot].h * 4;
        if (f->off >= size) return 0;
        uint64_t k = size - f->off;
        if (k > cap) k = cap;
        memcpy(buf, bb->px[slot][bb->slot[slot].front] + f->off, (size_t)k);
        f->off += k;
        return (int64_t)k;
    }
    if (!f->snap || f->off >= f->snaplen)
        return 0;
    uint64_t n = f->snaplen - f->off;
    if (n > cap) n = cap;
    memcpy(buf, f->snap + f->off, (size_t)n);
    f->off += n;
    return (int64_t)n;
}

/* One global-ctl verb line. */
static void ctl_global(const char *s, size_t n)
{
    size_t p = 0;
    if (n >= 9 && !strncmp(s, "newwindow", 9)) {
        struct wwin *v = win_alloc((int32_t)getpid());
        last_new = v ? v->wid : -1;
        return;
    }
    if (n >= 5 && !strncmp(s, "raise", 5)) {
        p = 5;
        int32_t wid = take_int(s, &p, n);
        struct wwin *v = win_find(wid);
        if (v) {
            int32_t top = 0;
            for (int i = 0; i < WSYS_MAX_WINDOWS; i++)
                if (shm->win[i].used && shm->win[i].z > top) top = shm->win[i].z;
            if (v->z < 100) v->z = top + 1;    /* z>=100 is panel/overlay band */
            shm->focus_wid = wid;
            shm->gen++;
        }
        return;
    }
    if (n >= 5 && !strncmp(s, "focus", 5)) {
        p = 5;
        int32_t wid = take_int(s, &p, n);
        if (win_find(wid)) { shm->focus_wid = wid; shm->gen++; }
        return;
    }
    if (n >= 6 && !strncmp(s, "screen", 6)) {
        p = 6;
        int32_t w = take_int(s, &p, n), h = take_int(s, &p, n);
        if (w > 0 && h > 0) { shm->screen_w = w; shm->screen_h = h; shm->gen++; }
        return;
    }
    if (n >= 7 && !strncmp(s, "desktop", 7)) {
        shm->desktop = 1;                      /* the rl5 flip */
        shm->gen++;
        return;
    }
    if (n >= 5 && !strncmp(s, "close", 5)) {
        p = 5;
        int32_t wid = take_int(s, &p, n);
        struct wwin *v = win_find(wid);
        if (v) {
            /* Release the backbuffer too.  sys_wsys_free does; this verb did
             * not, so closing a window through ctl leaked a v2 slot for the
             * rest of the session -- and with slots scarce that showed up
             * later as some unrelated window compositing blank. */
            bb_release(wid);
            v->used = 0;
            shm->gen++;
        }
        return;
    }
    /* Everything else (ws, wallpaper, rband, lock, run, sessui, …) is a
     * message to a DE component, not to the window table.  Keep the last one
     * of each verb in a sink named for the verb so the component that owns it
     * can read it back — the same shape as the singleton /dev/wsys/<name>
     * files, which is where those components already look. */
    size_t vn = 0;
    while (vn < n && s[vn] != ' ' && s[vn] != '\n' && vn < WSYS_SINK_NAME - 1)
        vn++;
    if (vn == 0) return;
    char nm[WSYS_SINK_NAME];
    memcpy(nm, s, vn);
    nm[vn] = '\0';
    struct wsink *sk = sink_find(nm, 1);
    if (!sk) return;
    uint32_t cp = (uint32_t)(n > WSYS_SINK_CAP ? WSYS_SINK_CAP : n);
    memcpy(sk->b, s, cp);
    sk->len = cp;
    shm->gen++;
}

/* One per-window ctl verb line. */
static void ctl_window(struct wwin *v, const char *s, size_t n)
{
    size_t p;
    if (n >= 8 && !strncmp(s, "geometry", 8)) {
        p = 8;
        int32_t x = take_int(s, &p, n), y = take_int(s, &p, n);
        int32_t w = take_int(s, &p, n), h = take_int(s, &p, n);
        if (w > 0 && h > 0) {
            v->x = x; v->y = y; v->w = w; v->h = h;
            /* A v2 window's backbuffer has to follow its geometry, or the
             * client draws at the new size into a surface still cut to the
             * old one. */
            bb_resize(v->wid, w, h);
            shm->gen++;
        }
        return;
    }
    if (n >= 8 && !strncmp(s, "decorate", 8)) {
        p = 8; v->decorate = take_int(s, &p, n) > 0; shm->gen++; return;
    }
    if (n >= 7 && !strncmp(s, "version", 7)) {
        p = 7; v->proto = take_int(s, &p, n); return;
    }
    if (n >= 7 && !strncmp(s, "visible", 7)) {
        p = 7; v->visible = take_int(s, &p, n) > 0; shm->gen++; return;
    }
    if (n >= 5 && !strncmp(s, "title", 5)) {
        size_t i = 5;
        while (i < n && s[i] == ' ') i++;
        size_t k = 0;
        while (i < n && s[i] != '\n' && k < WSYS_TITLE_CAP - 1)
            v->title[k++] = s[i++];
        v->title[k] = '\0';
        shm->gen++;
        return;
    }
    if (n >= 6 && !strncmp(s, "commit", 6)) {
        /* PUBLISH.  This is the only place scene_len moves, and it moves
         * after the bytes are already in place, so a compositor that sees the
         * new scene_gen is guaranteed a whole frame. */
        memcpy(v->scene, v->stage, v->stage_len);
        v->scene_len = v->stage_len;
        v->scene_gen++;
        shm->gen++;
        return;
    }
    if (n >= 4 && !strncmp(s, "hide", 4)) { v->visible = 0; shm->gen++; return; }
    if (n >= 4 && !strncmp(s, "show", 4)) { v->visible = 1; shm->gen++; return; }
    if (n >= 1 && s[0] == 'z') {
        p = 1; int32_t z = take_int(s, &p, n);
        if (z >= 0) { v->z = z; shm->gen++; }
        return;
    }
    /* Unknown verb: ignore, as devwsys does.  A window must not die because a
     * newer client sent a verb this kernel does not know. */
}

int64_t hamwsys_write(struct hamwsys_file *f, const uint8_t *buf, uint64_t n)
{
    if (!shm) { errno = EIO; return -EIO; }

    switch (f->leaf) {
    case HAMWSYS_CTL: {
        /* A write may carry several newline-separated verbs. */
        uint64_t i = 0;
        while (i < n) {
            uint64_t e = i;
            while (e < n && buf[e] != '\n') e++;
            if (e > i) {
                const char *s = (const char *)buf + i;
                size_t ln = (size_t)(e - i);
                /* devwsys_ctl_write's gate, verb by verb.  A refused verb
                 * stops the write there and reports EPERM rather than being
                 * skipped silently -- devwsys returns -1 with an errstr and
                 * the caller must be able to tell "refused" from "done". */
                if (!ctl_verb_is_ungated(s, ln)) {
                    int tw = ctl_verb_window_target(s, ln);
                    int ok = tw > 0 ? (hostowner() || owns_wid(tw))
                                    : hostowner();
                    if (!ok) { errno = EPERM; return -EPERM; }
                }
                ctl_global(s, ln);
            }
            i = (e < n) ? e + 1 : e;
        }
        return (int64_t)n;
    }
    case HAMWSYS_WIN_CTL: {
        struct wwin *v = win_find(f->wid);
        if (!v) { errno = ENOENT; return -ENOENT; }
        if (!hostowner() && !owns_wid(f->wid)) { errno = EPERM; return -EPERM; }
        uint64_t i = 0;
        while (i < n) {
            uint64_t e = i;
            while (e < n && buf[e] != '\n') e++;
            if (e > i) ctl_window(v, (const char *)buf + i, (size_t)(e - i));
            i = (e < n) ? e + 1 : e;
        }
        return (int64_t)n;
    }
    case HAMWSYS_WIN_SCENE: {
        struct wwin *v = win_find(f->wid);
        if (!v) { errno = ENOENT; return -ENOENT; }
        if (!hostowner() && !owns_wid(f->wid)) { errno = EPERM; return -EPERM; }
        uint64_t room = WSYS_SCENE_CAP - v->stage_len;
        uint64_t k = n < room ? n : room;
        if (k == 0 && n > 0) { errno = ENOSPC; return -ENOSPC; }
        memcpy(v->stage + v->stage_len, buf, (size_t)k);
        v->stage_len += (uint32_t)k;
        return (int64_t)k;
    }
    case HAMWSYS_WIN_KEYS: case HAMWSYS_WIN_POINTER: case HAMWSYS_WIN_EVENT:
    case HAMWSYS_WIN_TEXT: case HAMWSYS_WIN_CMD: {
        struct wwin *v = win_find(f->wid);
        if (!v) { errno = ENOENT; return -ENOENT; }
        if (!hostowner() && !owns_wid(f->wid)) { errno = EPERM; return -EPERM; }
        struct wring *q = f->leaf == HAMWSYS_WIN_KEYS    ? &v->keys
                        : f->leaf == HAMWSYS_WIN_POINTER ? &v->pointer
                        : f->leaf == HAMWSYS_WIN_EVENT   ? &v->event
                        : f->leaf == HAMWSYS_WIN_TEXT    ? &v->text
                                                         : &v->cmd;
        ring_write(q, buf, n);
        return (int64_t)n;
    }
    case HAMWSYS_DRAWCTL: {
        struct wwin *v = win_find(f->wid);
        if (!v) { errno = ENOENT; return -ENOENT; }
        if (!hostowner() && !owns_wid(f->wid)) { errno = EPERM; return -EPERM; }
        /* A client may split a record across write(2) calls, so an incomplete
         * one is CARRIED rather than dropped -- a torn blit would be a band of
         * garbage across the window, which is exactly the kind of failure that
         * looks like a driver bug and is not. */
        static uint8_t carry[1 << 20];
        static uint64_t carried;
        uint64_t total = carried + n;
        if (total > sizeof carry) {
            carried = 0;
            errno = EMSGSIZE;
            return -EMSGSIZE;
        }
        memcpy(carry + carried, buf, (size_t)n);
        carried = total;

        uint64_t i = 0;
        while (i < carried) {
            uint8_t verb = carry[i];
            uint64_t used = 0;
            if (verb == 'B') {
                used = bb_blit(v, carry + i, carried - i);
            } else if (verb == 'D') {
                if (carried - i < 17) break;
                int slot = bb_for(v->wid, 1, v->w, v->h);
                if (slot >= 0) {
                    /* PUBLISH. Flip only if something was actually drawn --
                     * a bare 'D' on an untouched surface is a no-op, not a
                     * flip back to a stale page. */
                    struct bbhdr *h = &bb->slot[slot];
                    if (h->started) {
                        h->front ^= 1u;
                        h->started = 0;
                    }
                    h->gen++;
                }
                shm->gen++;
                used = 17;
            } else if (verb == 'C') {
                if (carried - i < 18) break;
                int32_t cw = le32(carry + i + 9), ch = le32(carry + i + 13);
                uint8_t fmt = carry[i + 17];
                int bpp = (fmt == 3) ? 1 : 4;
                uint64_t need = (uint64_t)cw * ch * bpp;
                if (carried - i < 18 + need) break;
                used = 18 + need;      /* accepted; the compositor draws its
                                          own cursor for now */
            } else {
                /* Not a verb we know. Resynchronising by scanning would invent
                 * a frame out of noise, so drop what is buffered and say so. */
                carried = 0;
                errno = EINVAL;
                return -EINVAL;
            }
            if (used == 0) break;      /* incomplete: wait for more */
            i += used;
        }
        if (i > 0) {
            memmove(carry, carry + i, (size_t)(carried - i));
            carried -= i;
        }
        return (int64_t)n;
    }
    case HAMWSYS_SINK: {
        if (!sink_write_allowed(f->name)) { errno = EPERM; return -EPERM; }
        struct wsink *s = sink_find(f->name, 1);
        if (!s) { errno = ENOSPC; return -ENOSPC; }
        uint64_t room = WSYS_SINK_CAP - s->len;
        uint64_t k = n < room ? n : room;
        memcpy(s->b + s->len, buf, (size_t)k);
        s->len += (uint32_t)k;
        s->serial++;                           /* 0 means "nothing yet" */
        shm->gen++;
        return (int64_t)n;                     /* short writes are not the
                                                  caller's problem here */
    }
    case HAMWSYS_SELF: case HAMWSYS_WINDOWS: case HAMWSYS_DIR:
    default:
        errno = EPERM;
        return -EPERM;
    }
}

void hamwsys_close(struct hamwsys_file *f)
{
    free(f->snap);
    f->snap = NULL;
    f->snaplen = 0;
}

/* ------------------------------------------------------------------ *
 * The two syscalls
 *
 *   extern def sys_wsys_alloc(pid: uint64) -> int32
 *   extern def sys_wsys_free(wid: int32) -> int32
 *
 * user/hamUI.ad spawns a detached child, then stamps the child's pid against
 * a fresh wid.  That mapping is what /dev/wsys/self answers.
 * ------------------------------------------------------------------ */
int32_t hamwsys_alloc(uint64_t pid)
{
    if (shm_attach() < 0) return -1;
    /* This is devwsys's `alloc <pid>` -- "the legacy hostowner-on-behalf
     * path, read by the trusted DE" -- and it sits BEHIND devwsys's gate,
     * unlike `newwindow`.  The difference is the argument: newwindow stamps
     * the CALLER, this stamps whoever the caller names, which is the
     * privileged act of handing a window to another process.  A client that
     * wants its own window writes `newwindow`, which no uid is refused. */
    if (!hostowner()) { errno = EPERM; return -1; }
    struct wwin *v = win_alloc((int32_t)pid);
    if (!v) return -1;
    return v->wid;
}

int32_t hamwsys_free(int32_t wid)
{
    if (shm_attach() < 0) return -1;
    struct wwin *v = win_find(wid);
    if (!v) { errno = ENOENT; return -1; }
    /* devwsys's `free <wid>` is hostowner-only, but <wid>/ctl also carries an
     * owner-initiated teardown of the caller's OWN window, so owner-or-host
     * is the union of the two and refuses exactly what both refuse: tearing
     * down somebody else's window. */
    if (!hostowner() && !owns_wid(wid)) { errno = EPERM; return -1; }
    bb_release(wid);
    v->used = 0;
    if (shm->focus_wid == wid) shm->focus_wid = 0;
    shm->gen++;
    return 0;
}
