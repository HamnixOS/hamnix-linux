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
 * TWO SEGMENTS, AND WHY — the kernel boundary
 * -------------------------------------------
 * There is a SECOND mapping, /srv/wsys.chrome, mode 0644 and owned by the host
 * owner.  Read THE SPLIT below (just above chrome_attach) for exactly which
 * state lives in which, and why the line falls where it does.  In one
 * sentence: everything an ordinary client legitimately writes stays in the
 * 0666 segment, and the system chrome moves to the 0644 one, so that a program
 * which bypasses this file entirely and mmaps the raw files cannot write the
 * chrome — the FILE MODE is the gate and the Linux kernel enforces it.
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
#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <linux/futex.h>
#include <time.h>
#include <unistd.h>

#include "linux-wsys.h"

/* ------------------------------------------------------------------ *
 * The shared segment
 * ------------------------------------------------------------------ */
#define WSYS_MAGIC        0x53595357u        /* "WSYS" */
/* 2, not 1: the chrome state left this segment (see THE SPLIT below), so a
 * segment written by a version-1 build has a different meaning for the same
 * bytes.  3 adds the pinned-background flag to struct wwin, which moves every
 * field after it.  A mismatch re-initialises rather than being ignored — /srv is tmpfs
 * and recreated every boot, so the only way to meet an old one is to mix two
 * builds, and silently sharing a table whose layout you disagree about is the
 * success-shaped failure this tree keeps paying for.  4 adds `inputgen`, the
 * futex word a parked client sleeps on, which moves every window after it.
 * 5 doubles WSYS_MAX_WINDOWS and adds `wmdelete` to struct wwin, which moves
 * every field after it and every window after the first.
 * 6 doubles WSYS_MAX_WINDOWS again, 128 -> 256, for user/wsyswl.ad's MAXCONN
 * 16.  struct wwin is BYTE-FOR-BYTE UNCHANGED and so is every field of struct
 * wshm that precedes win[], so a v5 and a v6 build agree about where window
 * 0..127 are and disagree only about how many there are after them.  The
 * version still has to move, and this is what each direction does -- checked
 * by running it, in tests/linux/wsyswl_conn_ceiling.sh, not reasoned about:
 *
 *   A v6 BUILD MEETING A v5 SEGMENT.  st_size (9,593,244) is smaller than its
 *   own sizeof (19,052,956), so it ftruncates the file up, maps the whole
 *   thing, reads version 5 != 6 and memsets all 18.17 MiB.  Complete, clean,
 *   and it costs the previous session's windows -- which is what a version
 *   mismatch has always meant here.
 *
 *   A v5 BUILD MEETING A v6 SEGMENT.  This is the direction that is new,
 *   because it is the first time the two builds disagree about the SIZE of
 *   the mapping.  It maps only the first 9,593,244 bytes of an 19,052,956
 *   byte file -- mmap is happy to map a prefix -- reads version 6 != 5, and
 *   memsets what it mapped.  Rows 128..255 are left holding a dead session's
 *   bytes.  It cannot read them: a v5 binary indexes win[0..127] and the
 *   array bound is compiled in.  And the next v6 attacher sees version 5,
 *   fails its own check, and memsets the full 18.17 MiB before anything
 *   reads a row.  So the stale tail is unreachable in both builds and is
 *   gone before it could be reached in either.  NOT a silent half-share of a
 *   table two builds disagree about -- that is the failure this counter
 *   exists to prevent, and it is prevented in this direction too.
 *
 * /srv is tmpfs and recreated every boot, so meeting an old segment at all
 * means two builds in one session; the ONLY other way is a live `hpm update`
 * of the window system underneath a running desktop, which re-initialises
 * that desktop's window table by design and always has. */
#define WSYS_VERSION      6
/* SIXTY-FOUR, NOT THIRTY-TWO, and the reason is rootless Xwayland.
 *
 * A ROOTFUL X session is one wl_surface and therefore ONE row in this table
 * however many X clients are behind it -- an entire Steam session, its window
 * manager, its frames and all, is a single window.  Rootless spends one row
 * per X TOPLEVEL.  Thirty-two for the whole machine is the desktop's
 * backdrop, its panel, its chrome, Firefox and its menus, and then whatever
 * is left for a namespace, which is how "the ninth X window did not appear"
 * gets to be an answer.
 *
 * The cost is memory in ONE segment -- about 74 KiB per row, two scene
 * buffers and five rings -- so this is 9.5 MiB of shared memory where it was
 * 2.4, mapped once and shared by every client.  See BB_SLOTS below, which is
 * now tied to this number by an assertion rather than by a comment, and
 * user/wsyswl.ad's MAXCONN * WINPERCONN, which is 16 * 16 and fits here.
 *
 * TWO HUNDRED AND FIFTY-SIX, NOT ONE HUNDRED AND TWENTY-EIGHT, and the reason
 * is MAXCONN and not windows.
 *
 * Nobody has 256 windows open.  This number is not a window budget, it is the
 * no-starvation invariant MAXWIN >= MAXCONN * WINPERCONN made true: every
 * connection is guaranteed its whole budget of 16 windows no matter what any
 * other client has done, and wsyswl.ad's MAXCONN had to go to 16 because
 * FIREFOX ALONE OPENS EIGHT CONNECTIONS.  Keeping the table at 128 was
 * available and the price was halving WINPERCONN back to 8, which would have
 * turned tests/linux/wsyswl_ceiling.sh red -- twelve X clients on one
 * Xwayland are twelve windows on ONE connection.
 *
 * WHAT IT COSTS, and it is RESIDENT and not address space, which is the
 * opposite of the BB_SLOTS story below and must not be confused with it:
 * shm_attach memsets the whole of struct wshm on first attach, so every page
 * is touched and stays touched.  sizeof(struct wshm) is 19,052,956 bytes --
 * 18.17 MiB, where 128 rows was 9,593,244 (9.15 MiB).  Measured with
 * du(1) on the segment file, not computed: the test prints both.  That is
 * the whole price of the ceiling, it is paid once for the machine and shared
 * by every client, and it is why MAXCONN is 16 and not 32 -- 32 would need
 * 512 rows and 36.21 MiB resident on every boot of every machine. */
#define WSYS_MAX_WINDOWS  256
#define WSYS_SCENE_CAP    16384              /* = lib/hamscene.ad HAMSCENE_CAP */
#define WSYS_RING_CAP     8192
#define WSYS_TITLE_CAP    64
#define WSYS_SINKS        32
#define WSYS_SINK_NAME    64
#define WSYS_SINK_CAP     4096
/* devwsys's WSYS_PINNED_Z: a reserved floor BELOW the lowest z an ordinary
 * window can ask for (`z` refuses a negative), so nothing can land on it by
 * accident. */
#define WSYS_PINNED_Z     (-1)

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
    int32_t  pinned;                          /* devwsys's wsys_win_pinned   */
    /* THE CLIENT ASKED TO BE TOLD BEFORE IT IS CLOSED.  A window whose owner
     * sets this is not destroyed by `delete <wid>`: the request is delivered
     * on its `event` ring and the owner decides.  Without it a title-bar
     * close destroys the window record and leaves the program running with
     * nothing on screen -- which for a bridged X client means an invisible
     * xterm holding a shell, and for Firefox means a browser you cannot see
     * and cannot quit.  This is X's WM_DELETE_WINDOW, spelled as a file. */
    int32_t  wmdelete;
    /* ALPHA-KEYED and TRANSLUCENT present, devwsys.ad:8085's `keyed` and
     * `blend`.  Both were missing here and an unknown ctl verb is ignored, so
     * a fix that exists upstream and that the CLIENT ALREADY ASKS FOR
     * regressed silently in the port -- the same shape, in the same function,
     * as `background`/`pin`.
     *
     * `keyed 1` is for a decorate-0 window whose rect is LARGER than the
     * pixels it paints: hampanelscene GROWS the panel to the full width of
     * the display to host the Applications dropdown, then paints the bar and
     * the menu card and leaves the rest of the band untouched.  Presented
     * opaquely, that band is a black rectangle over the wallpaper and the
     * desktop icons -- which is exactly what the machine's owner reported.
     * A keyed present skips alpha-0 source pixels, like the cursor sprite.
     *
     * `blend 1` honours the whole 0..255 ramp instead of all-or-nothing, and
     * is what makes hamshotui's "select area" scrim DIM the desktop rather
     * than blit an opaque black rectangle over the thing it is dimming. */
    int32_t  keyed, blend;
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

/* SEGMENT A — /srv/wsys, mode 0666.  The window table.  Every field in here
 * is one an ordinary unprivileged client must be able to write; see THE SPLIT.
 * The screen geometry USED TO live here and does not any more: it is chrome. */
struct wshm {
    uint32_t magic, version;
    int32_t  focus_wid;                       /* raise/focus, owner-or-host   */
    int32_t  next_wid;                        /* newwindow, any uid           */
    int32_t  desktop;                         /* the rl5 flip: compositor owns fb */
    uint32_t gen;                             /* ++ on any published change */
    /* THE INPUT GENERATION, and the futex a parked client sleeps on.
     *
     * In Hamnix a client parks in sys_waitfds on /dev/wsys/<wid>/keys and the
     * KERNEL wakes it (wsys_route_key_byte -> waitfds_notify).  Here the rings
     * are shared memory with no kernel behind them, so the wake has to be
     * carried by something the writing PROCESS can poke and the parked one can
     * sleep on: a futex word in the shared segment.  Every ring_write bumps it
     * and FUTEX_WAKEs; user/linux-syscalls.c's sys_waitfds FUTEX_WAITs on it.
     *
     * ONE counter for every ring in the segment, deliberately.  A woken client
     * re-checks its OWN rings and parks again if they are empty, so a spurious
     * wake costs a few microseconds -- and when the desktop is idle there is
     * no input at all, which is the case that has to cost nothing. */
    uint32_t inputgen;
    struct wwin  win[WSYS_MAX_WINDOWS];
    struct wsink sink[WSYS_SINKS];            /* the PUBLIC sinks only        */
};

/* SEGMENT B — /srv/wsys.chrome, mode 0644, owned by the host owner.  The
 * system chrome.  Non-owners map this PROT_READ and the kernel refuses them
 * PROT_WRITE|MAP_SHARED, which is what makes the gate a real boundary rather
 * than a check inside a library. */
#define WCHROME_MAGIC     0x4d524843u        /* "CHRM" */
#define WCHROME_VERSION   1

struct wchrome {
    uint32_t magic, version;
    int32_t  screen_w, screen_h;              /* the `screen W H` ctl verb    */
    uint32_t gen;
    struct wsink sink[WSYS_SINKS];            /* the CHROME sinks             */
};

static struct wshm   *shm;
static struct wchrome *chrome;
static int            chrome_rw;              /* the kernel let us map it W   */

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
 *   'I' namelen name w h fmt <px>  named image upload, keyed by (wid, name);
 *                                  read back at <wid>/draw/images and
 *                                  <wid>/draw/image/<name>.  See THE
 *                                  NAMED-IMAGE STORE below.
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
/* ONE SLOT PER WINDOW THIS DEVICE CAN HOLD, and that is the whole design.
 *
 * The history is two identical failures.  Three slots was chosen when the only
 * v2 client was the X bridge and one window was a whole X session; a Wayland
 * compositor makes every toplevel a v2 window, so three became "your fourth
 * window is blank" -- SILENTLY, because bb_for returned -1, the window still
 * existed with a taskbar entry and correct geometry, and nothing composited
 * into it.  It was raised to eight.  Rootless Xwayland then spends one slot
 * per X TOPLEVEL where rootful spent one per SESSION, and eight became "your
 * ninth window is blank" with exactly the same silence available.
 *
 * A number that has been wrong twice for the same reason should not be picked
 * a third time.  So it is not picked: the pool is the size of the window
 * table, asserted at compile time, and the paint pool can therefore NEVER be
 * the thing that runs out first.  The ceiling a user meets is the window
 * table, which is a number the device can state.
 *
 * WHAT THAT COSTS, exactly, because 64 screen-sized double-buffered surfaces
 * sounds like a gigabyte and is not.  It is a gigabyte of ADDRESS SPACE in a
 * mapping of a sparse file, and the resident cost is the sum of the windows'
 * OWN areas: bb_fit and bb_blit touch w*h*4 bytes and never BB_BYTES, and
 * the segment's initialiser zeroes the headers and not the pixels.  Twelve
 * 186x110 xterms are 12 * 82 KiB of real memory, not 12 * 16 MiB.  Getting
 * that wrong is the difference between this being free and this being
 * impossible, so it is a property of the code below and not a hope. */
#define BB_SLOTS   WSYS_MAX_WINDOWS
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

/* THE HEADERS ARE ONE SMALL MAPPING; THE PIXELS ARE ONE MAPPING PER PAGE IN
 * USE, and that separation is what makes a pool this size free.
 *
 * `px` used to be a member of this struct: BB_SLOTS * 2 * 8 MiB of address
 * space mapped by every process that so much as read a window's ctl file.  At
 * eight slots that was 132 MiB and nobody noticed.  At one slot per window it
 * would be two gigabytes of VSZ in every GUI program on the machine, which is
 * a number somebody would eventually have to explain.
 *
 * So the segment is laid out by hand: this struct first, then slot i's two
 * pages at BB_PX_OFF(i, page).  A process maps a page the first time it
 * touches that slot and never maps the ones it does not use -- a client maps
 * its own window's two pages, and the compositor maps the pages of the
 * windows it is actually painting. */
struct bbshm {
    uint32_t magic;
    uint32_t nslots;       /* what the build that made it believed BB_SLOTS was */
    /* AN EXHAUSTED PAINT POOL MUST BE READABLE.  Twice now the symptom of a
     * full pool has been a window that is never painted and says nothing; a
     * line on stderr is only visible to whoever is watching the console at
     * the time.  These are what /dev/wsys/pool reports, so the condition is
     * answerable from a file after the fact, by a test or by a person. */
    uint32_t full_evt;     /* times a window was refused a slot              */
    int32_t  full_wid;     /* the last window refused one                    */
    int32_t  full_w, full_h;
    struct bbhdr slot[BB_SLOTS];
};

/* PAGE-ALIGNED, AND THE STRIDE IS WHAT HAD TO BE ROUNDED, not just the header.
 *
 * mmap's offset must be a multiple of the page size.  BB_BYTES is
 * 1920*1080*4 = 8294400, which is 2025 * 4096 -- fine on a 4 KiB-page kernel
 * and NOT a multiple of 16 KiB or 64 KiB (8294400/65536 = 126.5625).  Rounding
 * only the header up would leave every odd-numbered page offset misaligned on
 * a 16 KiB- or 64 KiB-page kernel: mmap returns EINVAL, bb_page returns NULL,
 * and half the windows are blank with "a blit was thrown away" -- the exact
 * silent failure this rewrite exists to remove, waiting for the first arm64
 * build.  So the per-page STRIDE is rounded to 64 KiB as well.  It costs
 * address space in a sparse file and nothing else. */
#define BB_ALIGN      ((size_t)65536)
#define BB_HDR_BYTES  ((size_t)((sizeof(struct bbshm) + BB_ALIGN - 1) & ~(BB_ALIGN - 1)))
#define BB_PAGE_BYTES ((size_t)((BB_BYTES + BB_ALIGN - 1) & ~(BB_ALIGN - 1)))
#define BB_PX_OFF(i, pg) \
    ((off_t)BB_HDR_BYTES + (off_t)(((size_t)(i) * 2 + (size_t)(pg)) * BB_PAGE_BYTES))
#define BB_FILE_BYTES ((off_t)BB_HDR_BYTES + (off_t)BB_SLOTS * 2 * (off_t)BB_PAGE_BYTES)

/* The pool can never be the first thing to run out.  If someone shrinks it
 * below the window table, this fails to compile rather than becoming a blank
 * window six months later. */
typedef char bb_pool_covers_the_window_table[
    (BB_SLOTS >= WSYS_MAX_WINDOWS) ? 1 : -1];

static struct bbshm *bb;
static int       bb_fd = -1;           /* kept open: pages are mapped lazily */
static uint8_t  *bb_px[BB_SLOTS][2];   /* per-process, NULL until first touch */

/* Slot i's page `pg`, mapped on demand.  NULL means the mapping failed, and
 * every caller treats that as "this window has no pixels this frame" rather
 * than writing somewhere else. */
static uint8_t *bb_page(int i, unsigned pg)
{
    if (i < 0 || i >= BB_SLOTS || pg > 1) return NULL;
    if (bb_px[i][pg]) return bb_px[i][pg];
    if (bb_fd < 0) return NULL;
    void *m = mmap(NULL, BB_BYTES, PROT_READ | PROT_WRITE, MAP_SHARED,
                   bb_fd, BB_PX_OFF(i, pg));
    if (m == MAP_FAILED) return NULL;
    bb_px[i][pg] = (uint8_t *)m;
    return bb_px[i][pg];
}

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
    /* SPARSE, and it has to be: this is a two-gigabyte file that holds a few
     * hundred kilobytes.  ftruncate on tmpfs sets the size and allocates
     * nothing; blocks arrive when a page is written, which is exactly the
     * window area bb_fit and bb_blit touch. */
    if ((uint64_t)st.st_size < (uint64_t)BB_FILE_BYTES
        && ftruncate(fd, BB_FILE_BYTES) < 0) {
        close(fd); return -1;
    }
    void *m = mmap(NULL, BB_HDR_BYTES, PROT_READ | PROT_WRITE,
                   MAP_SHARED, fd, 0);
    int e = errno;
    if (m == MAP_FAILED) { close(fd); errno = e; return -1; }
    bb = (struct bbshm *)m;
    /* KEPT OPEN, and close-on-exec.  bb_page maps a slot's pages on demand
     * and needs the descriptor for the life of the process; it used to be
     * closed here because one mmap covered everything.  CLOEXEC because a
     * program this one spawns has no business inheriting it -- every client
     * of this device opens the segment for itself, by name. */
    bb_fd = fd;
    fcntl(bb_fd, F_SETFD, FD_CLOEXEC);
    /* The magic carries the slot count, so a segment laid out by a build with
     * a different BB_SLOTS is re-initialised rather than half-believed: the
     * pixel pages are addressed by slot index, and two builds that disagree
     * about that stride would quietly read each other's windows.
     *
     * The pixels are not touched here.  A fresh file is already zero, and a
     * stale one's pixels are unreachable: every slot is cleared to its
     * window's size by bb_fit when it is claimed, and reads are bounded by
     * the same size. */
    if (bb->magic != 0x42425747u || bb->nslots != (uint32_t)BB_SLOTS) {
        memset(bb, 0, sizeof *bb);
        bb->magic  = 0x42425747u;
        bb->nslots = (uint32_t)BB_SLOTS;
    }
    return 0;
}

/* Say it once, on stderr, and never again.  A backbuffer that is not being
 * scanned out is invisible by construction, so the ONLY way it can announce
 * itself is a line on the console -- and one line, because the thing that made
 * the last attempt at diagnosing this useless was volume: a message per frame
 * filled the initramfs tmpfs and silenced the guest console inside two
 * minutes. */
struct wwin;
static struct wwin *win_find(int wid);

static void bb_once(int *flag, const char *msg, int a, int b, int c, int d)
{
    if (*flag) return;
    *flag = 1;
    fprintf(stderr, "wsys: BACKBUFFER %s (%d %d %d %d)\n", msg, a, b, c, d);
}

static int bb_warn_full, bb_warn_clamp, bb_warn_drop, bb_warn_refit;

/* Fit a slot to a size, clearing it.  A resize means the client is about to
 * redraw, and a stretched copy of the old frame in the meantime is a worse
 * answer than a blank one it immediately overwrites. */
static void bb_fit(int i, int w, int h)
{
    /* THE OLD SIZE MATTERS, because the clear has to cover it. */
    size_t was = (size_t)bb->slot[i].w * bb->slot[i].h * 4;
    bb->slot[i].w = w > 0 && w <= BB_W ? w : BB_W;
    bb->slot[i].h = h > 0 && h <= BB_H ? h : BB_H;
    bb->slot[i].started = 0;
    /* CLEAR THE PIXELS THIS SLOT CAN ACTUALLY SHOW, not BB_BYTES.  Rows are
     * packed at the SLOT's width (see bb_blit), so a window's pixels are
     * w*h*4 contiguous bytes at the start of each page and everything past
     * them is unreachable -- reads are bounded by the same product.  Zeroing
     * 8 MiB for a 186x110 xterm is what made a large pool unaffordable; this
     * is 82 KiB.  The old extent is cleared too where it was larger, so a
     * shrink cannot leave a previous tenant's pixels inside the new one. */
    size_t now = (size_t)bb->slot[i].w * bb->slot[i].h * 4;
    size_t clr = was > now ? was : now;
    if (clr > BB_BYTES) clr = BB_BYTES;
    uint8_t *p0 = bb_page(i, 0), *p1 = bb_page(i, 1);
    if (p0) memset(p0, 0, clr);
    if (p1) memset(p1, 0, clr);
    bb->slot[i].gen++;
    if ((w > 0 && w > BB_W) || (h > 0 && h > BB_H))
        bb_once(&bb_warn_clamp, "window is bigger than the backbuffer -- "
                "its pixels will be cut to BB_W x BB_H", w, h, BB_W, BB_H);
}

/* THE SLOT'S SIZE IS THE WINDOW'S SIZE, AND NOTHING ELSE MAY DECIDE IT.
 *
 * This function's caller writes pixels at the SLOT's width; user/wsysd.ad
 * reads them back and re-rows them at the WINDOW's width (paint_backbuffer,
 * win_w[i]).  Two authorities for one stride, and when they disagreed nothing
 * anywhere said so: the compositor scanned out a window drawn at 640 as though
 * it were 1280, which is two half-height copies of the client side by side and
 * everything below row h/2 dropped.  A rootful Xwayland is ONE surface, so
 * what that looked like was a whole X session -- xterm, Steam's login window,
 * the lot -- that painted once and then never followed a move again, with no
 * error in any log.  It cost three passes to localise.
 *
 * Two ways they came apart, both fixed here:
 *
 *   * a STALE SLOT.  The segment is a file (/srv/wsys.bb, or /dev/shm/... on a
 *     host run) that outlives the process, and a client that is killed never
 *     releases its slot.  The next run's window takes the same low wid, finds
 *     the corpse, and inherits its size.
 *   * bb_resize() was a no-op whenever `bb` was NULL -- i.e. before this
 *     process's first blit, which is EXACTLY when wsyswl sends the geometry it
 *     deliberately sends first (see win_open's comment in user/wsyswl.ad).
 *
 * So: attach before resizing, and re-fit an existing slot whose size does not
 * match what the caller asked for.  Every blit passes the window's current
 * w/h, so after this the two can be out of step for at most one frame. */
static int bb_for(int wid, int create, int w, int h)
{
    if (bb_attach() < 0) return -1;
    for (int i = 0; i < BB_SLOTS; i++)
        if (bb->slot[i].used && bb->slot[i].wid == wid) {
            if (create && w > 0 && h > 0
                && (bb->slot[i].w != w || bb->slot[i].h != h)) {
                bb_once(&bb_warn_refit, "a slot's size did not match its "
                        "window's -- re-fitting", wid, bb->slot[i].w,
                        bb->slot[i].h, w);
                bb_fit(i, w, h);
            }
            return i;
        }
    if (!create) return -1;
    for (int pass = 0; pass < 2; pass++) {
        for (int i = 0; i < BB_SLOTS; i++) {
            /* Second pass: reclaim the slots of windows that no longer exist.
             * A client killed with SIGKILL never closes its window, and eight
             * such corpses used to mean the ninth window was blank for ever. */
            if (bb->slot[i].used) {
                if (pass == 0 || win_find(bb->slot[i].wid)) continue;
                bb->slot[i].used = 0;
            }
            memset(&bb->slot[i], 0, sizeof bb->slot[i]);
            bb->slot[i].used = 1;
            bb->slot[i].wid  = wid;
            bb_fit(i, w, h);
            return i;
        }
    }
    /* UNREACHABLE UNLESS SOMEONE BREAKS THE INVARIANT above -- BB_SLOTS is
     * WSYS_MAX_WINDOWS, and a window that does not exist cannot ask for a
     * slot -- but it is recorded rather than only printed, because the two
     * times this pool has been too small the symptom was a window that is
     * never painted and NOTHING that says why.  /dev/wsys/pool reads these. */
    bb->full_evt++;
    bb->full_wid = wid;
    bb->full_w = w;
    bb->full_h = h;
    bb_once(&bb_warn_full, "all slots are in use by live windows -- this "
            "window will never be painted; read /dev/wsys/pool", wid,
            BB_SLOTS, w, h);
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
    if (w <= 0 || h <= 0) return;
    /* ATTACH FIRST.  This used to be `if (!bb) return;`, which made the call
     * a silent no-op in any process that had not blitted yet -- and the one
     * caller is the `geometry` ctl verb, which wsyswl sends BEFORE its first
     * blit on purpose.  So the correction never ran in the one process that
     * needed it.  See bb_for. */
    if (bb_attach() < 0) return;
    for (int i = 0; i < BB_SLOTS; i++) {
        struct bbhdr *hh = &bb->slot[i];
        if (!hh->used || hh->wid != wid) continue;
        if (hh->w == w && hh->h == h) return;
        bb_fit(i, w, h);
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
    if (slot < 0) {
        bb_once(&bb_warn_drop, "a blit was thrown away: this window has no "
                "backbuffer slot", v->wid, v->w, v->h, (int)need);
        return 18 + need;
    }
    struct bbhdr *h = &bb->slot[slot];
    uint32_t back = h->front ^ 1u;
    if (!h->started) {
        /* Carry the last published frame forward: a client that blits only
         * what changed must not find the rest of its window blank.  The
         * window's OWN extent, for the reason in bb_fit -- this used to copy
         * 8 MiB per frame per window whatever the window's size was, which is
         * both the pool's cost and a memcpy on the frame path. */
        size_t live = (size_t)h->w * h->h * 4;
        if (live > BB_BYTES) live = BB_BYTES;
        uint8_t *bp = bb_page(slot, back), *fp = bb_page(slot, h->front);
        if (!bp || !fp) {
            bb_once(&bb_warn_drop, "a blit was thrown away: this window's "
                    "pixels could not be mapped", v->wid, slot, (int)live, 0);
            return 18 + need;
        }
        memcpy(bp, fp, live);
        h->started = 1;
    }
    uint8_t *backpx = bb_page(slot, back);
    if (!backpx) {
        bb_once(&bb_warn_drop, "a blit was thrown away: this window's back "
                "page could not be mapped", v->wid, slot, 0, 0);
        return 18 + need;
    }
    const uint8_t *src = b + 18;
    for (int32_t y = y0; y < y1; y++) {
        if (y < 0 || y >= h->h) continue;
        for (int32_t x = x0; x < x1; x++) {
            if (x < 0 || x >= h->w) continue;
            const uint8_t *s = src + ((uint64_t)(y - y0) * (x1 - x0)
                                      + (x - x0)) * bpp;
            uint8_t *d = &backpx[((uint64_t)y * h->w + x) * 4];
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

/* Which candidate shm_attach actually joined.  The chrome segment's name is
 * DERIVED from it rather than resolved independently, so the two can never end
 * up in different directories — see chrome_attach. */
static char seg_path[512];
static char chrome_path[576];

/* ================================================================== *
 * THE SPLIT — what lives in the 0666 segment, what lives in the 0644 one
 * ==================================================================
 *
 * THE PROBLEM THIS EXISTS FOR.  The uid gate below is a check inside a
 * LIBRARY.  It binds every caller of the /dev/wsys file protocol — which is
 * every program in this tree — and NOTHING ELSE.  /dev/wsys is the file
 * /srv/wsys, mode 0666, MAP_SHARED into every client, so a hostile or merely
 * buggy program that skips the protocol and mmaps that file itself could write
 * any byte of it, and no `if` in this file could stop it.  devwsys.ad has no
 * such problem because there the state is KERNEL memory and the file protocol
 * is the only way in.  This is the asymmetry being compensated for.
 *
 * The 0666 mode itself is LOAD-BEARING and stays.  /etc/rc.de-user drops the
 * session to uid 1001; if a client of that uid cannot attach and map its own
 * window, the desktop is unprivileged and BLIND — it silently draws into a
 * screen nobody composites, which is the worse failure of the two.  So the fix
 * cannot be "make the segment 0644".  It has to be a SECOND segment, at 0644
 * and owned by the host owner, holding only what a non-owner has no business
 * writing.  Then the file mode IS the gate and the kernel enforces it.
 *
 * WHERE THE LINE FALLS, and the rule that puts it there.  A field belongs in
 * the 0666 segment IF AND ONLY IF the ported devwsys gate would let a
 * non-hostowner write it through the protocol.  That equivalence is the whole
 * design: after this split, "writable by anyone" and "lives in the
 * world-writable file" are the same set, so the kernel's answer and the
 * library's answer cannot drift apart.  Getting it wrong in the permissive
 * direction leaves the hole open; getting it wrong in the restrictive
 * direction blinds the session.
 *
 *   SEGMENT A, /srv/wsys, 0666 — an ordinary client genuinely writes all of:
 *     win[] entirely      geometry, z, title, decorate, visible, proto, the
 *                         scene staging + published buffers, and the five
 *                         event rings.  A client draws its own window; the
 *                         compositor writes input INTO a client's rings.  Both
 *                         are ordinary, both happen constantly, and devwsys's
 *                         rule for them is owner-OR-hostowner, not
 *                         hostowner-only.
 *     next_wid            `newwindow` is devwsys's explicit exception, parsed
 *                         before its gate "so a NOBODY-uid app can self-serve
 *                         a window".  Allocating bumps this.
 *     focus_wid           set by `raise`/`focus`, whose rule is owner-or-host:
 *                         a client raising its OWN window writes it.
 *     desktop             the rl5 flip; devwsys parses `desktop` before its
 *                         gate — "the DE claiming its own screen".
 *     gen                 bumped by every published change, including a
 *                         client's own commit.
 *     the PUBLIC sinks    the per-window `<wid>/…` sinks (owner-or-host); the
 *                         launch queues, `post` and `lock/verify`, which
 *                         devwsys deliberately leaves open to any uid; and the
 *                         sinks behind the ctl verbs devwsys parses BEFORE its
 *                         gate — `wallpaper` ("choosing your own desktop
 *                         picture is not a host-owner privilege") and the
 *                         instruments perf/ptrlat/sysirq/wklat/m2p/ptrsvc ("a
 *                         diagnostic you cannot turn on from the session you
 *                         are diagnosing is not a diagnostic").
 *
 *   SEGMENT B, /srv/wsys.chrome, 0644 owned by the host owner — chrome only:
 *     screen_w/screen_h   the `screen W H` verb, which is BEHIND devwsys's
 *                         gate.  Only the process that set the mode may
 *                         publish it, and a lie here is not cosmetic: the
 *                         whole desktop lays itself out from this number, and
 *                         a lock screen that believes the display is 1024x768
 *                         covers 53% of it.  Every client READS it, which the
 *                         0644 mode allows and reads were never gated anyway.
 *     every other sink    lock, run, notif, appmenu, setapp, cycler, calpop,
 *                         rband, sessui, sysmon, ctxmenu, snap, resize, osd,
 *                         tray, ws, kbd, frame, session, workspace, damage,
 *                         idle_ms, cursor/scene, wsysd/state — and, because
 *                         the rule is a DENY-list of public names and not an
 *                         allow-list of chrome ones, every future name too.
 *                         A name nobody has classified lands on the protected
 *                         side, so a chrome file added later cannot arrive
 *                         world-writable by omission.
 *
 * ONE DELIBERATE BEHAVIOUR CHANGE falls out of the equivalence.  Before this,
 * `echo "wallpaper /x" > /dev/wsys/ctl` was allowed to any uid (devwsys parses
 * it before the gate) while `echo /x > /dev/wsys/wallpaper` was refused to a
 * non-owner — a gate on one of two spellings of the same act.  This file
 * already argues, for the chrome verbs, that "a gate on only one of the two
 * spellings is not a gate"; the same argument run the other way says the
 * UNGATED verbs must be ungated in both spellings.  They now are.  The
 * alternative was to keep the wallpaper sink protected and have the ungated
 * ctl verb fail on write, which would have re-introduced by hand the exact bug
 * devwsys names in its own comment: the Control Center reporting "wallpaper
 * applied" while the backdrop never changes.
 *
 * WHAT IS STILL NOT CLOSED, stated where it can be measured.  A bypasser can
 * still write SEGMENT A, so it can still corrupt or spy on the window table —
 * retitle another client's window, scribble its scene, inject into its key
 * ring — and the same is true of the THIRD mapping, /srv/wsys.bb, which holds
 * the v2 backbuffers and is 0666 for exactly the same reason: a client of any
 * uid has to blit its own pixels into it.  tests/linux/wsys_bypass.sh now
 * drives ALL FOUR of those attacks as measurements, each read back through
 * the protocol, not just the retitle.
 *
 * AND THE FOURTH IS READ-ONLY, which is the finding that decides the shape of
 * any fix.  The first three are INTEGRITY and every one of them needs
 * PROT_WRITE — which is why the 0644 chrome segment stops them dead.  The
 * fourth is CONFIDENTIALITY and needs nothing but O_RDONLY:
 *
 *     KEYLOG     the bytes between another window's `keys` ring r and w are
 *                that window's keystrokes.  wsys_bypass.sh's `snoop` reads a
 *                uid-1001 victim's typing out of a uid-1001 attacker, WITHOUT
 *                moving r or w, so the victim receives every keystroke normally
 *                and has no way to notice.  Measured, not argued.
 *     SCRAPE     another window's committed `scene` is what is drawn inside it.
 *     ENUMERATE  every row's wid, pid, geometry and title.
 *
 * And the table HAS to stay world-readable: /dev/wsys/windows is the panel
 * taskbar's input (user/hampanelscene.ad:_refresh_windows), and a uid-1001
 * client reads the geometry root published.  So the cheapest fix that survives
 * a first reading of this comment — keep ONE table, drop it to 0644, put every
 * write behind an authenticated RPC — closes attacks 1-3 and NOT ONE of these.
 * A keylogger between two of the user's own applications is untouched by it.
 * That is the difference between a boundary and a gate that looks shut.
 *
 * AND WHICH OF THE TWO RECORDED FIXES ACTUALLY CLOSES IT — the measurement
 * that decides it, because the answer was NOT the neutral "either would do"
 * this comment used to carry.  The two candidates were "a mapping per
 * owner-uid" and "the table behind an RPC to wsysd":
 *
 *   A MAPPING PER OWNER-UID DOES NOT CLOSE THE ATTACK THAT MATTERS.
 *   /etc/rc.de-user drops the WHOLE session to uid 1001 — the terminal, the
 *   browser, and a malicious download are all uid 1001 (only wsysd and the
 *   system chrome stay root).  Unix file permissions are uid-granular: the
 *   kernel cannot tell two processes of one uid apart, so no file mode and no
 *   per-uid segment can stop one uid-1001 program from rewriting another
 *   uid-1001 program's row.  wsys_bypass.sh's same-uid case proves it — a
 *   uid-1001 attacker injects a key into a uid-1001 victim's ring, find-by-wid,
 *   separate pid.  All a per-uid split would buy is the root-vs-live boundary
 *   the 0644 chrome segment ALREADY draws, at the cost of every cross-uid
 *   reader (the panel taskbar reads every window's title) needing an
 *   aggregation step.  It is not the fix.
 *
 *   ONLY AN RPC AUTHORITY CAN.  The one thing that distinguishes two same-uid
 *   processes is a server that reads each request's peer credentials
 *   (SO_PEERCRED gives the sender's pid) and checks them against the window's
 *   owner — which is exactly what devwsys gets for free, because there the
 *   table is KERNEL memory and the protocol is the only way in.  Ported, that
 *   means wsysd owning the window table in private memory and every mutation
 *   arriving as an authenticated message.
 *
 * THE HOT PATH, MEASURED, because the hybrid's whole premise is that the split
 * is lopsided and that was an argument until tests/linux/wsys_write_census.sh
 * turned it into a number.  Every mutation of either segment is counted at the
 * one choke point all of them pass through (THE WRITE CENSUS, further down this
 * file), off a real offscreen desktop — wsysd + hamdesktop + hampanelscene:
 *
 *     whole session, bring-up included:  15 LIFECYCLE WRITES, TOTAL.
 *                                        3 newwindow, 6 geometry, 5 attr,
 *                                        1 focus.  Not per second.  Total.
 *     idle, 10 s                         0 lifecycle    130 per-frame (13.0/s)
 *     under a mouse, 12.6 s              1 lifecycle    435 per-frame (34.6/s)
 *
 * 435:1 on this desktop, and that is the FLOOR: the census sees no v2 blits at
 * all here, and a browser or a Steam session pushes megabytes of them a second
 * down the same path.  So an RPC on the lifecycle half is affordable by two
 * orders of magnitude, and an idle desktop would leave the authority asleep —
 * which on a laptop is the number that decides whether this ships at all (see
 * tests/linux/de_idle_cpu.sh for why that sentence is not decorative here).
 *
 * THE BOUNDARY, field by field, so the next pass does not have to re-derive it.
 * THREE tiers, not two, and the third is the one attack 4 forces:
 *
 *   TIER 1 — the public INDEX.  /srv/wsys, dropped to 0644 owned by the host
 *     owner.  wid, owner pid, x/y/w/h, z, title, decorate/visible/pinned/
 *     keyed/blend/wmdelete/proto, focus_wid, next_wid, desktop, gen, inputgen.
 *     Everybody reads it — the taskbar, the compositor, /dev/wsys/self.  NOBODY
 *     writes it but wsysd, and wsysd writes it only after SO_PEERCRED says the
 *     sender's pid is the row's owner.  That is the answer to the unsoundness
 *     below: the ownership record itself is in the tier the attacker cannot
 *     write, so the check is worth something.  15 writes a session.
 *
 *   TIER 2 — PER-WINDOW PRIVATE memory, one memfd per window, created by wsysd
 *     at `newwindow` and passed to the creating client over SCM_RIGHTS.  scene,
 *     stage, the five rings, the v2 backbuffer, the named images.  A memfd has
 *     no name in the filesystem, so there is no path for a bypasser to open:
 *     this is the only construction that closes attack 4, because it is the
 *     only one where a non-owner cannot MAP the bytes at all.  wsysd keeps
 *     every fd (it composites, and it writes routed input into the rings); the
 *     owner keeps its own.  Nothing on this tier ever touches the RPC — the
 *     34.6/s above, and the megabytes/s a browser adds, stay exactly as fast as
 *     they are today.
 *
 *   TIER 3 — /srv/wsys.chrome, 0644, unchanged.  Already correct.
 *
 * WHAT AN ATTACKER CAN STILL DO AFTERWARDS, named rather than left for someone
 * to discover, because a fix whose residue is undocumented is the same failure
 * as a hole that is:
 *   a. ENUMERATE.  Tier 1 stays world-readable, so every window's wid, pid,
 *      geometry and TITLE is still readable by any process on the machine.
 *      This is not fixable while /dev/wsys/windows is the taskbar's input, and
 *      a title is on screen anyway.  Only the keystrokes and the pixels move.
 *   b. SPOOF ITS OWN WINDOW.  A client may set its own title to "Firefox — Sign
 *      in" and draw a convincing login form, and it is the legitimate owner of
 *      every byte it needs to do so.  No ownership check can reach this; only
 *      trusted chrome the compositor draws and a client cannot (devwsys's
 *      `decorate` is where that would live) can, and this design does not
 *      attempt it.
 *   c. EXHAUST.  `newwindow` is open to every uid by devwsys's own rule, so any
 *      process can take all WSYS_MAX_WINDOWS rows and starve the desktop.  An
 *      authority makes a per-peer quota POSSIBLE for the first time; it does
 *      not impose one, and this design does not add it.
 *   d. WATCH THE COMPOSITOR'S OWN SURFACES.  Anything the compositor publishes
 *      for everyone (the wallpaper sink, a screenshot path) is still public by
 *      construction.  "No screen scraping" is NOT what tier 2 buys; "no reading
 *      another client's window" is.
 *
 * WHY IT IS STILL NOT BUILT IN THIS PASS.  Not the hot path — that turned out
 * to be affordable, and this comment used to say otherwise on no evidence.  The
 * blockers are the ones the measurement exposed rather than removed:
 *   (1) TIER 2 IS AN ATTACH REWRITE, NOT A MOVE.  Today every process mmaps one
 *       named file and is done; afterwards it must connect to a daemon and be
 *       HANDED its window before it can draw a pixel.  Twenty test scripts in
 *       tests/linux set $HAMWSYS and TWO of them never run a compositor at
 *       all — and the two are wsys_uidgate.sh and wsys_bypass.sh, the gates on
 *       this very boundary, which prove what they prove precisely by driving a
 *       client with nothing else alive.  They need an answer that is not "start
 *       a daemon first", and so does every single-program `hamlinux_build.sh`
 *       run a person does by hand.
 *   (2) A NEW ROOT DAEMON is a new binary, and NORTH_STAR.md's standing
 *       invariant makes that a package-channel change (scripts/hamlinux_packages.py
 *       plus tests/linux/channel_covers_image.sh), not a file.
 *   (3) THE SEGMENT LAYOUT CHANGE CANNOT USE THE APPEND-AND-FREEZE RULE this
 *       file has used for every previous version bump.  Tier 2 REMOVES scene,
 *       stage and the rings from struct wwin, so the prefix is not frozen and
 *       static assertions cannot save it.  And the version counter's own
 *       remedy — re-initialise — is actively dangerous here: an OLD binary
 *       arriving in a NEW session (which a package channel makes ordinary, and
 *       which is exactly what `hpm update` of half the desktop looks like)
 *       would map the new table, read a version it does not know, and MEMSET
 *       THE RUNNING SESSION'S WINDOW TABLE.  So tier 1 has to live at a NEW
 *       PATH — /srv/wsys2 — and an old binary must find /srv/wsys absent and
 *       fail loudly by name.  That is a decision about the whole distribution,
 *       not about this file.
 *
 *   And the one that has not changed: A TITLE-ONLY RPC IS UNSOUND, which rules
 *   out the tempting small start.  wsysd would authenticate "set window W's
 *   title" by comparing the sender pid to win[W].pid — but win[W].pid lives in
 *   this same 0666 table and is itself spoofable, so the check is only as
 *   trustworthy as the ownership record.  Moving THAT into the authority is
 *   moving tier 1, and tier 1 without tier 2 leaves the keylogger.  It is all
 *   of it or none, and half of it is a gate that looks shut and is not.
 *
 * So this pass lands the measurement and this design and does NOT half-build
 * the access control.  What IS closed, and by the kernel rather than by an if,
 * is the system chrome: a bypasser cannot lock the screen, queue a spawn, post
 * a notification, drive the app menu, or lie about the display geometry,
 * because the kernel refuses it PROT_WRITE on the 0644 file those live in.
 * tests/linux/wsys_bypass.sh measures both halves of that sentence.
 * ================================================================== */
static int chrome_attach(void)
{
    if (chrome) return 0;
    if (!seg_path[0]) return -1;

    const char *ov = getenv("HAMWSYS_CHROME");
    if (ov && *ov) snprintf(chrome_path, sizeof chrome_path, "%s", ov);
    else           snprintf(chrome_path, sizeof chrome_path, "%s.chrome",
                            seg_path);

    /* THREE OPENS, IN THIS ORDER, AND NO CANDIDATE LIST.
     *
     * O_RDWR first: the host owner (and root) get read/write.  Then O_RDONLY,
     * which 0644 grants everybody — that is how a uid-1001 client reads the
     * screen geometry and the chrome model it renders.  O_CREAT last and only
     * for the host owner.
     *
     * Two traps are being avoided here and both have already cost this file a
     * silent failure.
     *
     * (1) NO FALLBACK PATHS.  shm_attach tries /dev/shm and /tmp after
     *     $HAMWSYS, and that is exactly how a client once ended up with its
     *     own private window system, allocating wids nobody composited.  The
     *     chrome segment is named FROM the segment that was actually joined,
     *     so it is either beside it or absent; there is no second place for it
     *     to be, and therefore no way to invent one.
     *
     * (2) ONLY THE HOST OWNER MAY CREATE IT.  fs.protected_regular (=2 here)
     *     refuses O_CREAT on a file you do NOT own in a sticky world-writable
     *     directory — which /srv is, at 1777 — but it does NOT refuse creating
     *     a name that does not exist yet.  So without this check an
     *     unprivileged client that got there first would CREATE the chrome
     *     segment, own it, and be handed write access to the very state this
     *     split exists to protect: the boundary inverted by a race.  On a real
     *     boot rc.5 starts wsysd, as root, before anything drops, and
     *     shm_attach creates both segments together — so the owner always wins
     *     that race by construction.  A non-owner that finds no chrome segment
     *     maps nothing, reads chrome sinks as empty (which is what an unwritten
     *     sink has always read as) and is refused chrome writes by the uid gate
     *     anyway.  Fail closed, with no inversion available. */
    int fd = open(chrome_path, O_RDWR);
    int rw = fd >= 0;
    if (fd < 0) fd = open(chrome_path, O_RDONLY);
    if (fd < 0 && (geteuid() == 0
                   || (seg_owner_known && geteuid() == seg_owner))) {
        fd = open(chrome_path, O_RDWR | O_CREAT, 0644);
        rw = fd >= 0;
    }
    if (fd < 0) return -1;

    /* 0644, restated rather than assumed.  open(2)'s mode is masked by the
     * umask, and PID 1's is 022 — which happens to leave 0644 alone, but the
     * mode here is a SECURITY property and must not depend on inheriting the
     * right umask.  It is also the repair path for a segment left at the wrong
     * mode by an older build; only the owner can perform it, and a non-owner's
     * failure is expected and ignored. */
    if (rw && fchmod(fd, 0644) < 0) { /* not ours; mode is already what it is */ }

    struct stat st;
    if (fstat(fd, &st) < 0) { int e = errno; close(fd); errno = e; return -1; }
    if ((uint64_t)st.st_size < sizeof(struct wchrome)) {
        /* Only the creator can size it.  A short file mapped anyway would
         * SIGBUS on first touch, so a non-owner that loses this race treats
         * the segment as absent rather than as something to map. */
        if (!rw || ftruncate(fd, (off_t)sizeof(struct wchrome)) < 0) {
            close(fd);
            errno = EAGAIN;
            return -1;
        }
    }
    void *m = mmap(NULL, sizeof(struct wchrome),
                   rw ? (PROT_READ | PROT_WRITE) : PROT_READ,
                   MAP_SHARED, fd, 0);
    int e = errno;
    close(fd);
    if (m == MAP_FAILED) { errno = e; return -1; }

    chrome = (struct wchrome *)m;
    chrome_rw = rw;
    if (rw && (chrome->magic != WCHROME_MAGIC
               || chrome->version != WCHROME_VERSION)) {
        memset(chrome, 0, sizeof *chrome);
        chrome->magic   = WCHROME_MAGIC;
        chrome->version = WCHROME_VERSION;
        /* ZERO MEANS "NOBODY HAS SAID YET", and it has to.  This used to be
         * 1280x800 — the development VM's mode, written in as a default — and
         * a default here is indistinguishable from an answer: /dev/wsys/screen
         * would confidently report a geometry that no compositor had ever
         * measured, on a machine that might be 1920x1080.  The only process
         * entitled to fill these in is the one that set the mode, via the
         * `screen W H` ctl verb (wsysd's announce_screen).  Until it does,
         * reads of /dev/wsys/screen fail with ENXIO and the caller knows it
         * does not know. */
        chrome->screen_w = 0;
        chrome->screen_h = 0;
    }
    if (chrome->magic != WCHROME_MAGIC) {
        /* Read-only and uninitialised: the owner has not brought it up yet.
         * Say so by unmapping rather than serving zeroes as answers. */
        munmap(m, sizeof(struct wchrome));
        chrome = NULL;
        chrome_rw = 0;
        errno = EAGAIN;
        return -1;
    }
    return 0;
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
        if (fd >= 0)
            snprintf(seg_path, sizeof seg_path, "%s", cands[i]);
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
    if (shm->magic != WSYS_MAGIC || shm->version != WSYS_VERSION) {
        /* First attacher initialises.  A fresh tmpfs file is all zeroes, so
         * this is the only place the defaults are set. */
        memset(shm, 0, sizeof(*shm));
        shm->magic    = WSYS_MAGIC;
        shm->version  = WSYS_VERSION;
        shm->next_wid = 2;                     /* 0 invalid, 1 = foreground */
        shm->focus_wid = 0;
    }
    /* Best effort, and errno-neutral.  The host owner creates the chrome
     * segment here, which is what wins the create race by construction on a
     * real boot (rc.5 runs wsysd as root before anything drops).  A non-owner
     * that finds it absent simply has no chrome yet and retries on the next
     * chrome access -- and must not have this attempt's errno mistaken for a
     * failure of the attach it just completed. */
    {
        int e = errno;
        chrome_attach();
        errno = e;
    }
    return 0;
}

/* ================================================================== *
 * THE NAMED-IMAGE STORE — devwsys.ad's #128 scene image tier, ported
 * ==================================================================
 *
 * WHAT IT IS.  A scene client that wants a REAL raster image — a decoded PNG,
 * a photo, a video frame, an icon that is not expressible as fill/line
 * primitives — cannot say it in the v1 display list, which is text capped at
 * 16 KiB.  devwsys.ad's answer is FILE-REF + format tag and it is ported here
 * unchanged:
 *
 *   1. the client DECODES in userland and UPLOADS raw pixels to its window
 *      with the binary 'I' verb on /dev/wsys/<wid>/draw/ctl:
 *          'I' <namelen:u8> <name...> <w:i32le> <h:i32le> <fmt:u8> <pixels>
 *      fmt is one of the WSYS_BLIT_FMT_* the 'B' verb already takes; the store
 *      normalizes everything to RGBA8888.  Re-uploading a name REPLACES it.
 *   2. the client references it from the display list with `image x y w h NAME`
 *      (lib/hamscene.ad's hamscene_image), and the compositor looks the name up
 *      in THAT WINDOW's store and blits it, nearest-neighbour scaled.
 *
 * The store is keyed by (owning wid, name), exactly as devwsys keys it, so two
 * windows may both own an image called "frame" and neither can read or replace
 * the other's.
 *
 * WHY A THIRD PARTY HAS TO READ IT, and why that is the whole difference from
 * Hamnix.  In devwsys the compositor IS the kernel: it walks the display list
 * with the store in the same address space.  Here the compositor is
 * user/wsysd.ad, an ordinary program, so the store must be READABLE by it —
 * through files, like everything else, never through a new syscall:
 *
 *   /dev/wsys/<wid>/draw/images        "<name> <w> <h> <serial>\n" per image
 *   /dev/wsys/<wid>/draw/image/<name>  the raw RGBA8888 pixels, w*h*4 bytes
 *
 * The SERIAL is what makes that affordable.  A 256x256 image is 256 KiB and a
 * video client re-uploads one every tick; a compositor that re-read every
 * image every frame would spend the whole frame in memcpy.  The serial is
 * bumped on every store, so wsysd re-reads pixels only when they changed, and
 * the per-frame cost of a static image is one small text read.
 *
 * WHICH SEGMENT — measured against THE SPLIT's rule, not assumed.
 * ---------------------------------------------------------------
 * The rule is: a field belongs in the 0666 segment IFF the ported devwsys gate
 * would let a non-hostowner write it.  Run it: the 'I' verb arrives on
 * <wid>/draw/ctl, whose gate in this file is `hostowner() || owns_wid(wid)` —
 * the same owner-or-host rule as the scene buffer and the event rings.  A
 * uid-1001 client uploading an image to ITS OWN window is an ordinary,
 * constant, unprivileged act; refusing it would blind exactly the session
 * hamimgscene, hamvideocore and hamsdl run in.  So: the world-writable side.
 *
 * The case AGAINST, stated rather than skipped, because it is not frivolous.
 * Image pixels are the largest single thing a client can put into shared
 * memory here, and a bypasser that mmaps the file (the hole THE SPLIT names
 * and does not close) can overwrite another window's image — so a program
 * could make another program's window display a picture of its choosing.  That
 * is a real capability and it is worse than retitling a window.  It is
 * nonetheless the SAME hole, not a new one: the same bypasser can already
 * rewrite that window's scene text and its v2 backbuffer, which is a strictly
 * larger power over the same pixels (the backbuffer IS the whole window).
 * Putting the image store in the 0644 chrome segment would not close it and
 * WOULD break the ordinary case, because a uid-1001 client cannot write the
 * chrome segment at all — the desktop would render holes for every image, in
 * silence, which is the exact defect this work exists to fix.  So the store
 * goes where its writers are, and the residual is the one already recorded
 * against SEGMENT A and /srv/wsys.bb, not a new entry.
 *
 * A SEGMENT OF ITS OWN, /srv/wsys.img, for the reason the backbuffers have
 * one: 16 slots of 256 KiB is 4 MiB, and every client of /dev/wsys maps the
 * window table.  It is DERIVED from the segment shm_attach actually joined
 * (`<seg>.img`) with no candidate list, exactly as chrome_path is, so it can
 * never end up beside a different window system — that is the hazard
 * docs/steam_namespace.md §11 records against HAMWSYS_BB, which is one per
 * HOST and bit once already.  The file is created sparse and tmpfs allocates
 * on first touch, so a slot nobody uploads to costs nothing.
 *
 * THE CAP, AND WHAT HAPPENS AT IT.  devwsys's numbers, ported rather than
 * re-chosen: 16 slots, 256x256 maximum, 31-byte names.  The behaviour at the
 * ceiling is REFUSAL, NOT EVICTION, and that is devwsys's rule too
 * (_wsys_img_store returns 0 and the verb fails).  Eviction would be the
 * success-shaped answer: the upload reports success and some other window's
 * image silently becomes a hole one frame later, with nothing anywhere saying
 * which.  A refusal is a number the client can print.
 *
 * The three refusals answer three DIFFERENT errnos, because they are three
 * different facts and a client that cannot tell them apart cannot say anything
 * useful:  EMSGSIZE — the image is bigger than 256x256;  ENOSPC — all 16 slots
 * are taken by live windows;  EINVAL — the bytes are malformed.  devwsys folds
 * all three into one EINVAL, which is the one place this port deliberately
 * says MORE than its reference; the ENOSYS-vs-EINVAL distinction that this
 * whole defect was found through is the argument for it.
 *
 * Slots are freed when the owning window is torn down (hamwsys_free), which is
 * devwsys's _wsys_img_release_wid, and reclaimed when a wid is REUSED by
 * win_alloc — a fresh window must never inherit the dead one's pictures.
 * ================================================================== */
#define WSYS_IMG_MAGIC     0x474d4957u        /* "WIMG" */
#define WSYS_IMG_VERSION   1
#define WSYS_IMG_SLOTS     16
#define WSYS_IMG_MAX_W     256
#define WSYS_IMG_MAX_H     256
#define WSYS_IMG_NAME_CAP  32                 /* incl. NUL; max 31 name bytes */
#define WSYS_IMG_BYTES     ((size_t)WSYS_IMG_MAX_W * WSYS_IMG_MAX_H * 4)

struct wimg {
    uint32_t used;
    int32_t  wid;                              /* owning window */
    int32_t  w, h;
    uint32_t serial;                           /* ++ on every store           */
    char     name[WSYS_IMG_NAME_CAP];
    uint8_t  px[WSYS_IMG_BYTES];               /* RGBA8888, w*h*4 significant */
};

struct wimgshm {
    uint32_t magic, version;
    struct wimg slot[WSYS_IMG_SLOTS];
};

static struct wimgshm *img;
static char img_path[576];

static int img_attach(void)
{
    if (img) return 0;
    if (!seg_path[0]) return -1;               /* shm_attach has not run */

    const char *ov = getenv("HAMWSYS_IMG");
    if (ov && *ov) snprintf(img_path, sizeof img_path, "%s", ov);
    else           snprintf(img_path, sizeof img_path, "%s.img", seg_path);

    /* Attach before create, then fchmod 0666 — both for the reasons spelled
     * out at length in shm_attach above, and both already the fix for a
     * measured silent failure: O_CREAT on a file another uid owns in a sticky
     * 1777 directory is refused by fs.protected_regular, and open(2)'s mode is
     * masked by PID 1's umask to 0644, which locks the uid-1001 session out of
     * the store its own windows upload to. */
    int fd = open(img_path, O_RDWR);
    if (fd < 0) fd = open(img_path, O_RDWR | O_CREAT, 0666);
    if (fd < 0) return -1;
    if (fchmod(fd, 0666) < 0) { /* not the creator; mode already correct */ }

    struct stat st;
    if (fstat(fd, &st) < 0) { int e = errno; close(fd); errno = e; return -1; }
    if ((uint64_t)st.st_size < sizeof(struct wimgshm)
        && ftruncate(fd, (off_t)sizeof(struct wimgshm)) < 0) {
        int e = errno; close(fd); errno = e; return -1;
    }
    void *m = mmap(NULL, sizeof(struct wimgshm), PROT_READ | PROT_WRITE,
                   MAP_SHARED, fd, 0);
    int e = errno;
    close(fd);
    if (m == MAP_FAILED) { errno = e; return -1; }
    img = (struct wimgshm *)m;
    if (img->magic != WSYS_IMG_MAGIC || img->version != WSYS_IMG_VERSION) {
        memset(img, 0, sizeof *img);
        img->magic   = WSYS_IMG_MAGIC;
        img->version = WSYS_IMG_VERSION;
    }
    return 0;
}

/* devwsys's _wsys_img_release_wid: free every slot owned by wid.  Called on
 * window teardown AND on wid reuse — a recycled window id must not inherit a
 * dead window's images, which would be a picture appearing in a program that
 * never uploaded one. */
static void img_release_wid(int32_t wid)
{
    if (wid <= 0 || (!img && img_attach() < 0)) return;
    for (int i = 0; i < WSYS_IMG_SLOTS; i++)
        if (img->slot[i].used && img->slot[i].wid == wid) {
            img->slot[i].used = 0;
            img->slot[i].wid  = 0;
            img->slot[i].w = img->slot[i].h = 0;
            img->slot[i].name[0] = '\0';
        }
}

/* A WINDOW WHOSE OWNER IS GONE IS NOT A WINDOW.
 *
 * MEASURED, by tests/linux/wsys_desktop_z.sh, which is the gate that found it:
 * kill an application and 100% of its pixels are still on the screen, an
 * opaque rectangle no click can reach, with the taskbar still listing it.  It
 * never goes away, because nothing in this port ever frees a window that its
 * owner did not free by hand — and nothing in lib/hamui.ad frees one, so a
 * NORMAL exit leaks it too.  Every return code 0, and the screen is wrong,
 * which is this tree's most expensive failure shape.
 *
 * devwsys does not have this bug and does not need this function: there a
 * window belongs to a FID, and the kernel closes every fid a dying process
 * held, crash or not.  /dev/wsys here is shared memory with no fid table, so
 * the liveness has to be asked for.  kill(pid, 0) is the question.
 *
 * It FAILS CLOSED in both directions that matter.  A pid whose number has been
 * recycled answers "alive", so the window is KEPT — a stale window is a
 * cosmetic fault and tearing down a live application's window is not.  EPERM
 * (a live process this uid may not signal) is likewise "alive".  A window with
 * no owner stamped (pid 0) is never touched: nothing is known about it.
 *
 * Called from the two reads that enumerate windows — the directory (which is
 * what the compositor walks every frame) and /dev/wsys/windows (which is what
 * the taskbar walks) — so the screen and the taskbar agree, and so the sweep
 * costs one kill(2) per window per frame rather than one per file operation. */
static void win_reap_dead(void)
{
    if (!shm) return;
    for (int i = 0; i < WSYS_MAX_WINDOWS; i++) {
        struct wwin *v = &shm->win[i];
        if (!v->used || v->pid <= 0) continue;
        errno = 0;
        if (kill((pid_t)v->pid, 0) == 0 || errno != ESRCH) continue;
        bb_release(v->wid);
        img_release_wid(v->wid);
        if (shm->focus_wid == v->wid) shm->focus_wid = 0;
        v->used = 0;
        shm->gen++;
    }
}

/* devwsys's _wsys_img_find, over the shared table.  Empty name never matches;
 * the name is compared over its FULL length, so "log" never finds "logo". */
static struct wimg *img_find(int32_t wid, const char *name, size_t nlen)
{
    if (!img || wid <= 0 || nlen == 0 || nlen >= WSYS_IMG_NAME_CAP) return NULL;
    for (int i = 0; i < WSYS_IMG_SLOTS; i++) {
        struct wimg *s = &img->slot[i];
        if (!s->used || s->wid != wid) continue;
        if (strlen(s->name) == nlen && !memcmp(s->name, name, nlen))
            return s;
    }
    return NULL;
}

/* devwsys's _wsys_img_store: (wid,name) -> w x h RGBA8888, converting from
 * `fmt`.  Reuses the existing (wid,name) slot or the first free one.  0 on
 * success, -errno on refusal — see THE CAP above for which errno means what. */
static int img_store(int32_t wid, const char *name, size_t nlen,
                     int32_t w, int32_t h, uint8_t fmt, const uint8_t *px)
{
    if (img_attach() < 0) return -EIO;
    if (nlen == 0 || nlen >= WSYS_IMG_NAME_CAP) return -EINVAL;
    if (w <= 0 || h <= 0) return -EINVAL;
    if (w > WSYS_IMG_MAX_W || h > WSYS_IMG_MAX_H) return -EMSGSIZE;
    int bpp = (fmt == 3) ? 1 : (fmt == 1 || fmt == 2) ? 4 : 0;
    if (!bpp) return -EINVAL;

    struct wimg *s = img_find(wid, name, nlen);
    if (!s) {
        for (int i = 0; i < WSYS_IMG_SLOTS && !s; i++)
            if (!img->slot[i].used) s = &img->slot[i];
    }
    if (!s) return -ENOSPC;                    /* refusal, never eviction */

    memcpy(s->name, name, nlen);
    s->name[nlen] = '\0';
    s->wid  = wid;
    s->w    = w;
    s->h    = h;
    s->used = 1;
    uint64_t npx = (uint64_t)w * (uint64_t)h;
    for (uint64_t i = 0; i < npx; i++) {
        const uint8_t *q = px + i * bpp;
        uint8_t *d = s->px + i * 4;
        if (fmt == 2) {                        /* FMT_BGRA8888 */
            d[0] = q[2]; d[1] = q[1]; d[2] = q[0]; d[3] = q[3];
        } else if (fmt == 3) {                 /* FMT_A8 -> white * alpha */
            d[0] = d[1] = d[2] = d[3] = q[0];
        } else {                               /* FMT_RGBA8888 */
            d[0] = q[0]; d[1] = q[1]; d[2] = q[2]; d[3] = q[3];
        }
    }
    /* PUBLISHED LAST, like the snarf segment's length: a compositor that
     * samples the serial before this store re-reads next frame, and one that
     * samples it after finds pixels that are already in place.  Not a lock,
     * and not pretending to be one. */
    s->serial++;
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
        /* A wid is a small integer and next_wid wraps around a reboot only in
         * principle -- but the image segment OUTLIVES the process that made it
         * (it is a file in /srv), so a fresh window can be handed an id whose
         * pictures are still in the store from a previous run.  Clear them:
         * inheriting a dead window's images would put a picture in a program
         * that never uploaded one. */
        img_release_wid(v->wid);
        v->pid      = pid;
        /* 320x240, which is devwsys's default and not this port's guess.  It
         * was 640x480 here, which is only ever seen by a client that opens a
         * window and draws before it sets a geometry -- but for that window
         * the difference is a rectangle twice the size of the one upstream
         * would have shown, and "the port's defaults drifted" is how a whole
         * class of small wrongness accumulates unnoticed. */
        v->x = 120; v->y = 90; v->w = 320; v->h = 240;
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
 * WHAT THIS GATE IS AND IS NOT, said plainly.  On its own it is a check
 * inside a LIBRARY: it binds every caller of the /dev/wsys file protocol --
 * every program in this tree and every program the DE will spawn -- and
 * nothing else.  A program that DOES NOT GO THROUGH THIS FILE, one that opens
 * the segment and mmaps it itself, is not bound by any `if` written here.
 *
 * That is why THE SPLIT above exists, and the two are meant to be read
 * together.  The split moves the system chrome into a second segment at 0644
 * owned by the host owner, so for chrome the FILE MODE is the gate and the
 * kernel enforces it against everybody, protocol or not; the checks below are
 * then the thing that turns a would-be SIGSEGV on a read-only page into an
 * EPERM the caller can print.  For the WINDOW TABLE, which has to stay
 * world-writable or an unprivileged session is blind, these checks are still
 * the only gate there is: a bypasser can retitle another client's window,
 * scribble its scene or inject into its key ring, and — as THE SPLIT's "WHAT
 * IS STILL NOT CLOSED" now records from measurement — closing that needs the
 * table behind an RPC to wsysd, NOT a mapping per owner-uid (the whole session
 * is one uid, so a per-uid mapping separates nothing that matters).  Named
 * here so it is not mistaken for solved -- the same reason the limit it
 * replaces was named in etc/rc.de-user.
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
    static const char *win_verbs[] = { "raise", "focus", "close", "delete" };
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

/* The names of the ctl verbs devwsys parses BEFORE its hostowner gate that
 * this port routes into a sink.  `newwindow`, `desktop`, `raise`, `focus`,
 * `close` and `screen` are handled by ctl_global directly and never reach a
 * sink, so they are not here. */
static int name_is_ungated_verb(const char *name)
{
    static const char *v[] = {
        "wallpaper", "perf", "ptrlat", "sysirq", "wklat", "m2p", "ptrsvc",
    };
    for (size_t i = 0; i < sizeof v / sizeof *v; i++)
        if (!strcmp(name, v[i])) return 1;
    return 0;
}

/* THE SPLIT, as a predicate.  1 = this sink lives in segment A (0666); 0 = it
 * is chrome and lives in segment B (0644).  Exactly the set a non-hostowner
 * may write through the protocol, which is the invariant the whole design
 * rests on — see THE SPLIT above.  Everything unrecognised is chrome. */
static int sink_is_public(const char *name)
{
    if (name[0] >= '0' && name[0] <= '9') {    /* "<wid>/<leaf>" */
        const char *p = name;
        while (*p >= '0' && *p <= '9') p++;
        if (*p == '/') return 1;
    }
    if (sink_is_launch_queue(name)) return 1;
    if (!strcmp(name, "post")) return 1;
    if (!strcmp(name, "lock/verify")) return 1;
    return name_is_ungated_verb(name);
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
    /* The verbs devwsys parses before its gate, in their FILE spelling.  See
     * ONE DELIBERATE BEHAVIOUR CHANGE in THE SPLIT for why both spellings of
     * an ungated verb have to be ungated. */
    if (name_is_ungated_verb(name)) return 1;
    /* Chrome.  Two answers must agree, and the more restrictive one wins: the
     * ported devwsys gate (this uid is the host owner) and the kernel's (it
     * gave us a writable mapping of the 0644 segment).  chrome_rw is not
     * belt-and-braces — it is what stops a write reaching a PROT_READ page and
     * turning a permission refusal into a SIGSEGV. */
    return hostowner() && chrome_rw;
}

/* ------------------------------------------------------------------ *
 * THE PARK, and why it is a futex
 *
 * A scene client's idle loop is: drain my rings, redraw if anything changed,
 * then PARK until input arrives or a timeout lapses.  In Hamnix the park is
 * sys_waitfds and the kernel's devwsys wakes it.  On this line /dev/wsys is
 * shared memory and the "kernel" is the writing process, so the wake has to
 * be an IPC primitive over that same memory.
 *
 * THIS IS THE FIX FOR THE 175% IDLE DESKTOP.  sys_waitfds used to hand its
 * fds straight to poll(2) -- and a /dev/wsys descriptor is a real descriptor
 * on /dev/null, which poll reports READABLE instantly and always.  So
 * hamdesktop's `sys_waitfds(event_fd, 250)` and hampanelscene's
 * `sys_waitfds(event_fds, 16)` -- both written specifically to avoid a spin,
 * both commented as parking off the runqueue -- returned immediately on every
 * iteration, forever.  The two programs the user looks at each pegged a core
 * on an empty desktop, in state R, and every functional gate passed.
 * ------------------------------------------------------------------ */
static long futex_op(uint32_t *addr, int op, uint32_t val,
                     const struct timespec *ts)
{
    return syscall(SYS_futex, addr, op, val, ts, NULL, 0);
}

/* Publish that a ring got bytes and wake every parked client. */
static void input_posted(void)
{
    if (!shm) return;
    __atomic_add_fetch(&shm->inputgen, 1, __ATOMIC_RELEASE);
    /* FUTEX_WAKE, not FUTEX_WAKE_PRIVATE: the waiters are OTHER PROCESSES
     * sharing this mapping, which is the whole point of the segment. */
    futex_op(&shm->inputgen, FUTEX_WAKE, (uint32_t)INT32_MAX, NULL);
}

/* The generation a caller should quote back to hamwsys_input_wait().  Read it
 * BEFORE checking the rings, or a write landing between the check and the wait
 * is slept through -- the classic lost wakeup. */
uint32_t hamwsys_input_gen(void)
{
    if (shm_attach() < 0 || !shm) return 0;
    return __atomic_load_n(&shm->inputgen, __ATOMIC_ACQUIRE);
}

/* Sleep until the input generation moves off `seen`, or `timeout_ms` elapses
 * (negative = forever).  Returns 0 always; the caller re-checks its rings. */
int hamwsys_input_wait(uint32_t seen, int64_t timeout_ms)
{
    if (!shm) return 0;
    struct timespec ts;
    struct timespec *tp = NULL;
    if (timeout_ms >= 0) {
        ts.tv_sec  = (time_t)(timeout_ms / 1000);
        ts.tv_nsec = (long)((timeout_ms % 1000) * 1000000L);
        tp = &ts;
    }
    futex_op(&shm->inputgen, FUTEX_WAIT, seen, tp);
    return 0;
}

/* 1 when this open is a per-window event ring -- the only /dev/wsys files a
 * readability wait means anything for.  Everything else under /dev/wsys is a
 * snapshot read: it is ready by definition, which is what poll on /dev/null
 * accidentally reported and the only reason that bug was survivable. */
int hamwsys_is_ring(const struct hamwsys_file *f)
{
    switch (f->leaf) {
    case HAMWSYS_WIN_KEYS:
    case HAMWSYS_WIN_POINTER:
    case HAMWSYS_WIN_EVENT:
    case HAMWSYS_WIN_TEXT:
    case HAMWSYS_WIN_CMD:
        return 1;
    default:
        return 0;
    }
}

/* 1 when that ring has bytes waiting to be read. */
int hamwsys_ring_ready(const struct hamwsys_file *f)
{
    if (!hamwsys_is_ring(f)) return 1;
    if (shm_attach() < 0 || !shm) return 0;
    struct wwin *v = win_find(f->wid);
    if (!v) return 0;
    const struct wring *q = f->leaf == HAMWSYS_WIN_KEYS    ? &v->keys
                          : f->leaf == HAMWSYS_WIN_POINTER ? &v->pointer
                          : f->leaf == HAMWSYS_WIN_EVENT   ? &v->event
                          : f->leaf == HAMWSYS_WIN_TEXT    ? &v->text
                                                           : &v->cmd;
    return q->r != q->w;
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
    if (n) input_posted();
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

/* Find (or claim) a sink, IN THE SEGMENT THE SPLIT PUTS IT IN.
 *
 * The routing is by name and nothing else, so a name can never exist in both
 * tables and a reader and a writer can never disagree about which one they
 * mean.  A chrome sink with no writable chrome mapping answers NULL on
 * create — a non-owner reading one it has never seen written gets the same
 * "empty, not an error" it always got, and a non-owner WRITING one was already
 * refused by sink_write_allowed before it got here. */
static struct wsink *sink_find(const char *name, int create)
{
    if (shm_attach() < 0) return NULL;
    struct wsink *table;
    if (sink_is_public(name)) {
        table = shm->sink;
    } else {
        if (!chrome && chrome_attach() < 0) return NULL;
        if (create && !chrome_rw) { errno = EPERM; return NULL; }
        table = chrome->sink;
    }
    struct wsink *free_slot = NULL;
    for (int i = 0; i < WSYS_SINKS; i++) {
        struct wsink *s = &table[i];
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
    name[0] = '\0';

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
            else if (!strcmp(l, "draw/images")) leaf = HAMWSYS_IMAGES;
            else if (!strncmp(l, "draw/image/", 11) && l[11]) {
                /* The named-image read leaf.  The name is the REST of the
                 * path, taken whole: a prefix match would let "draw/image/lo"
                 * answer with "logo"'s pixels, which is the same class of
                 * mistake as a device path with no server behind it. */
                leaf = HAMWSYS_IMAGE;
                snprintf(name, sizeof name, "%s", l + 11);
            }
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
    } else if (!strcmp(p, "pool")) {
        leaf = HAMWSYS_POOL;
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
        } else if (leaf == HAMWSYS_IMAGE) {
            /* Already the bare image name, taken above. */
            snprintf(f->name, sizeof f->name, "%s", name);
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
    win_reap_dead();               /* the taskbar must not list a dead window */
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
/* /dev/wsys/pool — THE PAINT POOL, STATED.
 *
 *   "slots <used>/<total> exhausted <n> last_refused <wid> <w>x<h>\n"
 *
 * Every v2 window (which is every Wayland toplevel, every X toplevel on a
 * rootless display, and the browser) needs one backbuffer slot, and a window
 * that cannot get one EXISTS, has geometry, has a taskbar entry, and is never
 * painted.  That failure has been shipped twice, and both times what made it
 * expensive was that no file anywhere said the pool was full.  This is that
 * file.  It is read-only and needs no window: a program diagnosing a blank
 * window is not necessarily the program that owns it. */
static int snap_pool(struct hamwsys_file *f)
{
    if (bb_attach() < 0) { errno = ENXIO; return -1; }
    int used = 0;
    for (int i = 0; i < BB_SLOTS; i++)
        if (bb->slot[i].used) used++;
    uint8_t b[128];
    uint64_t n = 0;
    const char *k = "slots ";
    while (*k) b[n++] = (uint8_t)*k++;
    n = put_int(b, n, used);
    b[n++] = '/';
    n = put_int(b, n, BB_SLOTS);
    k = " exhausted ";
    while (*k) b[n++] = (uint8_t)*k++;
    n = put_int(b, n, (int32_t)bb->full_evt);
    k = " last_refused ";
    while (*k) b[n++] = (uint8_t)*k++;
    n = put_int(b, n, bb->full_wid);
    b[n++] = ' ';
    n = put_int(b, n, bb->full_w);
    b[n++] = 'x';
    n = put_int(b, n, bb->full_h);
    b[n++] = '\n';
    return snap_set(f, b, n);
}

static int snap_screen(struct hamwsys_file *f)
{
    /* In the CHROME segment since the split: `screen W H` is behind devwsys's
     * gate, so only the compositor may publish it — and every client may read
     * it, which 0644 grants.  No chrome segment at all reads the same as an
     * unannounced geometry, because that is what it means. */
    if (!chrome && chrome_attach() < 0) { errno = ENXIO; return -1; }
    if (chrome->screen_w <= 0 || chrome->screen_h <= 0) { errno = ENXIO; return -1; }
    uint8_t b[32];
    uint64_t n = put_int(b, 0, chrome->screen_w);
    b[n++] = ' ';
    n = put_int(b, n, chrome->screen_h);
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
     *    <backbuffer_gen> <image_gen>\n"
     *
     * The three generation counters are the frame counters: scene_gen changes
     * only on `commit`, backbuffer_gen only on a v2 dirty-rect, so a
     * compositor that remembers them repaints exactly the windows that
     * changed and rasterizes nothing else.
     *
     * IMAGE_GEN IS THE THIRD, AND IT HAD TO BE.  A client that re-uploads a
     * named image sends the SAME scene text afterwards -- lib/hamvideocore.ad
     * writes `image ... frame` on every tick and the bytes are identical -- so
     * a compositor watching scene_gen alone would call a new video frame
     * "nothing to paint" and the picture would freeze on frame one while every
     * return code stayed 0.  devwsys bumps a per-window content serial in
     * _wsys_img_store for exactly this reason; this field is that serial, made
     * readable.  It is APPENDED, so a reader that parses eleven fields is
     * unaffected.
     *
     * KEYED AND BLEND ARE FIELDS 13 AND 14, appended for the same reason and
     * with the same promise: the compositor has no private channel to this
     * device, so a per-window presentation flag it must honour has to be
     * readable in the file every client already reads. */
    uint8_t b[192];
    uint64_t n = 0;
    int bslot = bb_for(v->wid, 0, 0, 0);
    int32_t igen = 0;
    if (img || img_attach() >= 0)
        for (int i = 0; i < WSYS_IMG_SLOTS; i++)
            if (img->slot[i].used && img->slot[i].wid == v->wid)
                igen += (int32_t)img->slot[i].serial;
    int32_t fields[14] = { v->wid, v->x, v->y, v->w, v->h, v->z,
                           v->decorate, v->visible, v->proto,
                           (int32_t)v->scene_gen,
                           bslot >= 0 ? (int32_t)bb->slot[bslot].gen : 0,
                           igen, v->keyed, v->blend };
    for (int i = 0; i < 14; i++) {
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
    uint8_t buf[WSYS_MAX_WINDOWS * 8 + 256];
    uint64_t n = 0;
    if (f->wid == 0) {
        win_reap_dead();           /* the compositor must not paint a dead one */
        const char *fixed[] = { "ctl", "self", "windows", "screen", "pool" };
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
                                 "event", "text", "cmd", "draw/images" };
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
    case HAMWSYS_IMAGES: {
        /* READ-ONLY, and deliberately.  The way to put an image in the store is
         * the 'I' verb on draw/ctl; a second writable spelling of the same
         * state is how two sources of truth start (the same argument
         * /dev/wsys/screen makes just below). */
        if (for_write) { errno = EACCES; return -1; }
        struct wwin *v = win_find(f->wid);
        if (!v) { errno = ENOENT; return -1; }
        if (img_attach() < 0) return snap_set(f, NULL, 0);
        uint8_t b[WSYS_IMG_SLOTS * (WSYS_IMG_NAME_CAP + 48)];
        uint64_t n = 0;
        for (int i = 0; i < WSYS_IMG_SLOTS; i++) {
            struct wimg *s = &img->slot[i];
            if (!s->used || s->wid != f->wid) continue;
            for (const char *c = s->name; *c; c++) b[n++] = (uint8_t)*c;
            b[n++] = ' '; n = put_int(b, n, s->w);
            b[n++] = ' '; n = put_int(b, n, s->h);
            b[n++] = ' '; n = put_int(b, n, (int32_t)s->serial);
            b[n++] = '\n';
        }
        return snap_set(f, b, n);
    }
    case HAMWSYS_IMAGE: {
        if (for_write) { errno = EACCES; return -1; }
        if (!win_find(f->wid)) { errno = ENOENT; return -1; }
        if (img_attach() < 0) { errno = ENOENT; return -1; }
        /* ENOENT, not an empty read.  "this window has no image by that name"
         * is a fact the caller must be able to act on; zero bytes would be
         * indistinguishable from a 0x0 picture, which is the shape of failure
         * this whole defect was. */
        if (!img_find(f->wid, f->name, strlen(f->name))) {
            errno = ENOENT; return -1;
        }
        return 0;
    }
    case HAMWSYS_DRAWCTL: {
        struct wwin *v = win_find(f->wid);
        if (!v) { errno = ENOENT; return -1; }
        /* OPENING THIS FILE IS NOT THE v2 OPT-IN, and it used to be.
         *
         * The flip lived here -- "a client that blits pixels is not going to
         * send a scene" -- and that reasoning is sound for 'B'/'D' and WRONG
         * for 'I'.  devwsys.ad says so in as many words at its own 'I' arm:
         * the verb "is accepted at ANY protocol version so a legacy scene
         * client can drop in a named image without converting its whole window
         * to the v2 blit backbuffer".  That is the entire point of the image
         * tier -- a scene app that wants ONE photograph, not a surface.
         *
         * With the flip here, MEASURED: hamimgscene opened draw/ctl to upload
         * its image, the window became protocol 2, wsysd took the backbuffer
         * path, found a backbuffer nobody had ever blitted into, and painted
         * 640x480 of black over a scene that was sitting there committed and
         * correct.  Every return code was 0.
         *
         * So the opt-in is now the first verb that actually means "I render my
         * own surface" -- 'B' or 'D', both of which allocate the slot they
         * need where they are handled.  A real v2 client sends one of those
         * before it has anything to show, so nothing it does changes. */
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
    case HAMWSYS_POOL:
        /* Read-only for the same reason `screen` is: this is the device
         * reporting its own storage, and a writable spelling of it would be a
         * second source of truth for how many windows can be painted. */
        if (for_write) { errno = EACCES; return -1; }
        return snap_pool(f);
    case HAMWSYS_WINDOWS: return for_write ? 0 : snap_windows(f);
    case HAMWSYS_SELF:    return for_write ? 0 : snap_self(f);
    case HAMWSYS_CTL:     return for_write ? 0 : snap_ctl(f);
    case HAMWSYS_DIR:     return snap_dir(f);
    case HAMWSYS_SINK: {
        errno = 0;
        struct wsink *s = sink_find(f->name, for_write);
        if (for_write) {
            /* sink_find answers EPERM when the sink is chrome and this process
             * has no writable chrome mapping.  Do not overwrite that with
             * ENOSPC: "the kernel will not let you write this" and "there is
             * no slot left" are different facts and the caller must be able to
             * tell them apart. */
            if (!s) { if (!errno) errno = ENOSPC; return -1; }
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
        const uint8_t *fp = bb_page(slot, bb->slot[slot].front);
        if (!fp) return 0;
        memcpy(buf, fp + f->off, (size_t)k);
        f->off += k;
        return (int64_t)k;
    }
    if (f->leaf == HAMWSYS_IMAGE) {
        /* The stored pixels, RGBA8888, row-major at the image's own width —
         * offset-addressed exactly like the backbuffer, so wsysd reads it with
         * the same loop and no new mechanism.  The slot is re-resolved on every
         * read because it may have been freed by a teardown between reads; that
         * reads as EOF, not as somebody else's pixels. */
        struct wimg *s = img ? img_find(f->wid, f->name, strlen(f->name)) : NULL;
        if (!s) return 0;
        uint64_t size = (uint64_t)s->w * (uint64_t)s->h * 4;
        if (size > WSYS_IMG_BYTES) size = WSYS_IMG_BYTES;
        if (f->off >= size) return 0;
        uint64_t k = size - f->off;
        if (k > cap) k = cap;
        memcpy(buf, s->px + f->off, (size_t)k);
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

/* ================================================================== *
 * THE WRITE CENSUS — the measurement THE SPLIT's recorded fix is sized on
 * ==================================================================
 *
 * WHY THIS EXISTS.  THE SPLIT above says the only mechanism that can tell two
 * same-uid processes apart is an RPC to wsysd that authenticates the peer, and
 * then says the reason it was not built is that a round trip on the per-frame
 * and per-keystroke path would put the compositor on every client's hot path.
 * That is an ARGUMENT, and this tree's rule is that a measurement is worth more
 * than one — including one made by the person who wrote the file.  So the
 * argument is now a number: every mutation of either segment is counted, at the
 * one choke point every one of them passes through, and classified LIFECYCLE
 * (identity, ownership, title, geometry, z — the things an authority would have
 * to arbitrate) or PER-FRAME (scene bytes, commits, blits, routed input — the
 * things it must never see).  tests/linux/wsys_write_census.sh drives a real
 * desktop under a synthetic mouse and reads these files back.
 *
 * IT IS OFF UNLESS ASKED FOR.  No counter is touched, and no file is created,
 * unless $HAMWSYS_WRSTAT names a directory.  The cost on the hot path when it
 * is unset is one load of a null pointer and a predicted-not-taken branch.
 *
 * THE FILE IS A MAPPING, NOT A FLUSH AT EXIT, and that is deliberate: wsysd,
 * hamdesktop and hampanelscene are all killed with a signal at the end of every
 * gate in this tree, so an atexit(3) dump would measure exactly the processes
 * that do not matter and lose the three that do.  Counters are incremented in
 * place in a MAP_SHARED file, so the numbers survive SIGKILL.
 *
 * The category NAMES live in the file, so the reader does not carry a copy of
 * this enum that can drift away from it.
 * ================================================================== */
enum {
    WR_NEWWIN = 0, WR_DESTROY, WR_OWNER, WR_FOCUS, WR_TITLE, WR_GEOM, WR_ATTR,
    WR_SCENE, WR_COMMIT, WR_BLIT, WR_DAMAGE, WR_CURSOR, WR_IMAGE,
    WR_KEYS, WR_POINTER, WR_EVENT, WR_TEXT, WR_CMD,
    WR_SINK, WR_CHROME, WR_GLOBAL, WR_N
};
#define WR_NAMELEN 16
static const char wr_names[WR_N][WR_NAMELEN] = {
    "newwindow", "destroy", "setowner", "focus", "title", "geometry", "attr",
    "scene", "commit", "blit", "damage", "cursor", "image",
    "keys", "pointer", "event", "text", "cmd",
    "sink", "chrome", "globalctl",
};
struct wrstat {
    char     magic[8];                  /* "HAMWRST1" */
    uint32_t ncat, namelen;
    uint64_t t_first_ns, t_last_ns;
    int32_t  pid, _pad;
    char     name[WR_N][WR_NAMELEN];
    uint64_t count[WR_N];
    uint64_t bytes[WR_N];
};
static struct wrstat *wrs;
static int            wr_tried;

static uint64_t wr_now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static void wr_init(void)
{
    wr_tried = 1;
    const char *d = getenv("HAMWSYS_WRSTAT");
    if (!d || !*d) return;
    char path[640];
    /* The command name is in the file NAME and not only in its bytes, so that
     * a census of nine processes can be read with ls(1) and attributed without
     * opening anything.  A pid alone is unattributable after the run. */
    char comm[32] = "";
    int cf = open("/proc/self/comm", O_RDONLY);
    if (cf >= 0) {
        ssize_t k = read(cf, comm, sizeof comm - 1);
        close(cf);
        if (k > 0) {
            comm[k] = '\0';
            for (char *q = comm; *q; q++)
                if (*q == '\n' || *q == '/' || *q == ' ') { *q = '\0'; break; }
        }
    }
    snprintf(path, sizeof path, "%s/wr.%s.%d", d, comm[0] ? comm : "proc",
             (int)getpid());
    int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0666);
    if (fd < 0) return;
    if (ftruncate(fd, (off_t)sizeof(struct wrstat)) < 0) { close(fd); return; }
    void *m = mmap(NULL, sizeof(struct wrstat), PROT_READ | PROT_WRITE,
                   MAP_SHARED, fd, 0);
    close(fd);
    if (m == MAP_FAILED) return;
    wrs = (struct wrstat *)m;
    memcpy(wrs->magic, "HAMWRST1", 8);
    wrs->ncat = WR_N;
    wrs->namelen = WR_NAMELEN;
    wrs->pid = (int32_t)getpid();
    memcpy(wrs->name, wr_names, sizeof wr_names);
    wrs->t_first_ns = wrs->t_last_ns = wr_now_ns();
}

static void wr(int cat, uint64_t bytes)
{
    if (!wrs) {
        if (wr_tried) return;
        wr_init();
        if (!wrs) return;
    }
    wrs->count[cat]++;
    wrs->bytes[cat] += bytes;
    wrs->t_last_ns = wr_now_ns();
}

/* One global-ctl verb line.  0 on success, -1 with errno set.
 *
 * It USED to be void, and the one caller that could fail — the sink catch-all
 * — just returned.  Since the split a chrome verb can also fail because the
 * chrome segment is absent or read-only, and a chrome verb that is quietly
 * dropped is precisely the success-shaped answer this tree keeps paying for:
 * `hamctl` would print "wallpaper applied" over a write that went nowhere. */
static int ctl_global(const char *s, size_t n)
{
    size_t p = 0;
    if (n >= 9 && !strncmp(s, "newwindow", 9)) {
        wr(WR_NEWWIN, n);
        struct wwin *v = win_alloc((int32_t)getpid());
        last_new = v ? v->wid : -1;
        return v ? 0 : -1;
    }
    if (n >= 5 && !strncmp(s, "raise", 5)) {
        wr(WR_FOCUS, n);
        p = 5;
        int32_t wid = take_int(s, &p, n);
        struct wwin *v = win_find(wid);
        if (v && v->pinned) return 0;          /* a pinned background never
                                                  raises -- see ctl_window */
        if (v) {
            int32_t top = 0;
            for (int i = 0; i < WSYS_MAX_WINDOWS; i++)
                if (shm->win[i].used && shm->win[i].z > top) top = shm->win[i].z;
            if (v->z < 100) v->z = top + 1;    /* z>=100 is panel/overlay band */
            shm->focus_wid = wid;
            shm->gen++;
        }
        return 0;
    }
    if (n >= 5 && !strncmp(s, "focus", 5)) {
        wr(WR_FOCUS, n);
        p = 5;
        int32_t wid = take_int(s, &p, n);
        if (win_find(wid)) { shm->focus_wid = wid; shm->gen++; }
        return 0;
    }
    if (n >= 6 && !strncmp(s, "screen", 6)) {
        wr(WR_CHROME, n);
        p = 6;
        int32_t w = take_int(s, &p, n), h = take_int(s, &p, n);
        if (w <= 0 || h <= 0) return 0;        /* no geometry named: no-op */
        /* CHROME.  The published display geometry is the one number the whole
         * desktop lays itself out from, so it lives in the 0644 segment and
         * only the host owner can write it -- kernel-enforced, not by this
         * `if`.  A refusal must be LOUD: a compositor whose announce_screen
         * silently did nothing would leave every client reading ENXIO and
         * blaming itself. */
        if (!chrome && chrome_attach() < 0) return -1;
        if (!chrome_rw) { errno = EPERM; return -1; }
        chrome->screen_w = w;
        chrome->screen_h = h;
        chrome->gen++;
        shm->gen++;
        return 0;
    }
    if (n >= 7 && !strncmp(s, "desktop", 7)) {
        wr(WR_GLOBAL, n);
        shm->desktop = 1;                      /* the rl5 flip */
        shm->gen++;
        return 0;
    }
    /* "delete <wid>" -- CLOSE THE WINDOW THE WAY ITS OWNER WANTS.
     *
     * `close` below destroys the window record.  For a program that draws its
     * own pixels that is not closing an application, it is taking its screen
     * away: the process keeps running, keeps its files open, and has no
     * window.  A title-bar close button that did that would be worse than no
     * close button, which is why there was none.
     *
     * So the desktop writes `delete` and the DEVICE decides which it means:
     * a window whose owner set `wmdelete` gets the request on its own event
     * ring and closes itself (wsyswl turns it into WM_DELETE_WINDOW for an X
     * client, xdg_toplevel.close for a native one); anything else is
     * destroyed exactly as before, so a scene client that has never heard of
     * the verb behaves the way it always did.
     *
     * It is a WINDOW-targeted verb, so ctl_verb_window_target gates it: only
     * the window's owner or the host owner may ask.  A stranger closing your
     * windows is not a courtesy. */
    if (n >= 6 && !strncmp(s, "delete", 6)) {
        wr(WR_DESTROY, n);
        p = 6;
        int32_t wid = take_int(s, &p, n);
        struct wwin *v = win_find(wid);
        if (!v) return 0;
        if (v->wmdelete) {
            static const uint8_t req[] = "close\n";
            ring_write(&v->event, req, sizeof req - 1);
            return 0;
        }
        bb_release(wid);
        v->used = 0;
        shm->gen++;
        return 0;
    }
    if (n >= 5 && !strncmp(s, "close", 5)) {
        wr(WR_DESTROY, n);
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
        return 0;
    }
    /* Everything else (ws, wallpaper, rband, lock, run, sessui, …) is a
     * message to a DE component, not to the window table.  Keep the last one
     * of each verb in a sink named for the verb so the component that owns it
     * can read it back — the same shape as the singleton /dev/wsys/<name>
     * files, which is where those components already look. */
    wr(WR_GLOBAL, n);
    size_t vn = 0;
    while (vn < n && s[vn] != ' ' && s[vn] != '\n' && vn < WSYS_SINK_NAME - 1)
        vn++;
    if (vn == 0) return 0;
    char nm[WSYS_SINK_NAME];
    memcpy(nm, s, vn);
    nm[vn] = '\0';
    struct wsink *sk = sink_find(nm, 1);
    if (!sk) { if (!errno) errno = ENOSPC; return -1; }
    uint32_t cp = (uint32_t)(n > WSYS_SINK_CAP ? WSYS_SINK_CAP : n);
    memcpy(sk->b, s, cp);
    sk->len = cp;
    shm->gen++;
    return 0;
}

/* One per-window ctl verb line. */
static void ctl_window(struct wwin *v, const char *s, size_t n)
{
    size_t p;
    if (n >= 8 && !strncmp(s, "geometry", 8)) {
        wr(WR_GEOM, n);
        p = 8;
        int32_t x = take_int(s, &p, n), y = take_int(s, &p, n);
        int32_t w = take_int(s, &p, n), h = take_int(s, &p, n);
        if (w > 0 && h > 0) {
            int moved = (v->x != x || v->y != y || v->w != w || v->h != h);
            v->x = x; v->y = y; v->w = w; v->h = h;
            /* A v2 window's backbuffer has to follow its geometry, or the
             * client draws at the new size into a surface still cut to the
             * old one. */
            bb_resize(v->wid, w, h);
            shm->gen++;
            /* THE WINDOW WAS MOVED BY SOMEBODY ELSE, so its owner is told.
             *
             * This is the file-server half of X's ConfigureNotify, and it
             * exists because the compositor moving a window used to be
             * invisible to the program inside it: an X client that asked
             * where it was got the position it opened at for ever, and an
             * override-redirect menu placed at its parent's X coordinates
             * landed wherever the parent USED to be.  The device posts the
             * new geometry on the window's own event ring -- a ring a parked
             * client is already asleep on (see THE PARK) -- so it costs a
             * wakeup when a window moves and nothing at all when none does.
             *
             * ONLY when the writer is not the owner.  wsyswl sends `geometry`
             * itself on every resize; echoing that back is a loop between two
             * authorities over one rectangle, which would look like jitter
             * and read like a rendering bug. */
            if (moved && v->pid && (int32_t)getpid() != v->pid) {
                uint8_t e[80];
                uint64_t k = 0;
                const char *w0 = "geometry ";
                while (*w0) e[k++] = (uint8_t)*w0++;
                k = put_int(e, k, x); e[k++] = ' ';
                k = put_int(e, k, y); e[k++] = ' ';
                k = put_int(e, k, w); e[k++] = ' ';
                k = put_int(e, k, h); e[k++] = '\n';
                ring_write(&v->event, e, k);
            }
        }
        return;
    }
    if (n >= 8 && !strncmp(s, "decorate", 8)) {
        wr(WR_ATTR, n);
        p = 8; v->decorate = take_int(s, &p, n) > 0; shm->gen++; return;
    }
    /* devwsys's `keyed` and `blend`.  No argument means 1, as with `pin`:
     * hampanelscene writes `keyed 1`, but a client that writes bare `keyed`
     * has said the same thing and must not be silently ignored. */
    if (n >= 5 && !strncmp(s, "keyed", 5)) {
        wr(WR_ATTR, n);
        p = 5; int32_t k = take_int(s, &p, n);
        v->keyed = (k < 0 || k > 0) ? 1 : 0; shm->gen++; return;
    }
    if (n >= 5 && !strncmp(s, "blend", 5)) {
        wr(WR_ATTR, n);
        p = 5; int32_t b = take_int(s, &p, n);
        v->blend = (b < 0 || b > 0) ? 1 : 0; shm->gen++; return;
    }
    if (n >= 7 && !strncmp(s, "version", 7)) {
        wr(WR_ATTR, n);
        p = 7; v->proto = take_int(s, &p, n); return;
    }
    /* "wmdelete [0|1]" -- ASK ME BEFORE YOU CLOSE ME.  The owner opts in; the
     * default is the old behaviour, so a client that has never heard of this
     * verb is closed exactly as it always was.  No argument means 1. */
    if (n >= 8 && !strncmp(s, "wmdelete", 8)) {
        wr(WR_ATTR, n);
        p = 8; int32_t d = take_int(s, &p, n);
        v->wmdelete = (d < 0 || d > 0) ? 1 : 0;
        return;
    }
    if (n >= 7 && !strncmp(s, "visible", 7)) {
        wr(WR_ATTR, n);
        p = 7; v->visible = take_int(s, &p, n) > 0; shm->gen++; return;
    }
    if (n >= 5 && !strncmp(s, "title", 5)) {
        wr(WR_TITLE, n);
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
        wr(WR_COMMIT, v->stage_len);
        /* PUBLISH.  This is the only place scene_len moves, and it moves
         * after the bytes are already in place, so a compositor that sees the
         * new scene_gen is guaranteed a whole frame. */
        memcpy(v->scene, v->stage, v->stage_len);
        v->scene_len = v->stage_len;
        v->scene_gen++;
        shm->gen++;
        return;
    }
    if (n >= 4 && !strncmp(s, "hide", 4)) {
        wr(WR_ATTR, n); v->visible = 0; shm->gen++; return;
    }
    if (n >= 4 && !strncmp(s, "show", 4)) {
        wr(WR_ATTR, n); v->visible = 1; shm->gen++; return;
    }
    if (n >= 1 && s[0] == 'z') {
        wr(WR_GEOM, n);
        p = 1; int32_t z = take_int(s, &p, n);
        if (z >= 0) { v->z = z; shm->gen++; }
        return;
    }
    /* background [0|1] / pin — devwsys's PINNED BACKGROUND.
     *
     * MEASURED, and it is why the desktop had no windows on it.  hamdesktop
     * writes `background 1` for its full-screen backdrop (its own comment says
     * "`background 1` subsumes the old `z 0`"), this port had no such verb, and
     * an unknown verb is ignored -- so the backdrop kept lib/hamui.ad's default
     * `z 6` and the compositor, which paints z ascending, painted a
     * full-screen opaque backdrop OVER every ordinary client window.  On a VM
     * boot the result is a desktop with wallpaper, icons and a panel (z 9,
     * above it) and NOT ONE application window, with every return code 0 and
     * the taskbar still listing the windows it was covering.  The terminal was
     * running the whole time.
     *
     * devwsys forces a pinned window to a reserved lowest z (WSYS_PINNED_Z,
     * which is -1 -- BELOW the 0 an ordinary window can ask for, so the floor
     * cannot be reached by accident) and never raises it, which is the other
     * half: without that, one click on the desktop raises the backdrop over
     * everything again ("all windows vanish on desktop click", the bug
     * devwsys's comment names).  Both halves are ported.  `pin` takes no
     * argument and means 1. */
    if ((n >= 10 && !strncmp(s, "background", 10))
        || (n >= 3 && !strncmp(s, "pin", 3))) {
        wr(WR_GEOM, n);
        p = (s[0] == 'p') ? 3 : 10;
        int32_t bv = take_int(s, &p, n);
        if (bv < 0) bv = 1;                    /* `pin`, or no argument */
        v->pinned = bv ? 1 : 0;
        v->z = bv ? WSYS_PINNED_Z : 0;
        shm->gen++;
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
                errno = 0;
                if (ctl_global(s, ln) < 0) {
                    int e = errno ? errno : EIO;
                    errno = e;
                    return -e;
                }
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
        wr(WR_SCENE, k);
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
        wr(f->leaf == HAMWSYS_WIN_KEYS    ? WR_KEYS
         : f->leaf == HAMWSYS_WIN_POINTER ? WR_POINTER
         : f->leaf == HAMWSYS_WIN_EVENT   ? WR_EVENT
         : f->leaf == HAMWSYS_WIN_TEXT    ? WR_TEXT : WR_CMD, n);
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
                /* THE v2 OPT-IN, here rather than at open -- see the DRAWCTL
                 * arm of hamwsys_open.  A blit is the client saying it renders
                 * its own surface; opening the file is not. */
                if (v->proto != 2) { v->proto = 2; shm->gen++; }
                used = bb_blit(v, carry + i, carried - i);
                if (used) wr(WR_BLIT, used);
            } else if (verb == 'D') {
                if (v->proto != 2) { v->proto = 2; shm->gen++; }
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
                wr(WR_DAMAGE, 17);
                used = 17;
            } else if (verb == 'C') {
                if (carried - i < 18) break;
                int32_t cw = le32(carry + i + 9), ch = le32(carry + i + 13);
                uint8_t fmt = carry[i + 17];
                int bpp = (fmt == 3) ? 1 : 4;
                uint64_t need = (uint64_t)cw * ch * bpp;
                if (carried - i < 18 + need) break;
                wr(WR_CURSOR, 18 + need);
                used = 18 + need;      /* accepted; the compositor draws its
                                          own cursor for now */
            } else if (verb == 'I') {
                /* 'I' <namelen:u8> <name...> <w:i32le> <h:i32le> <fmt:u8>
                 * <pixels> — the NAMED IMAGE UPLOAD, devwsys.ad's #128.  See
                 * THE NAMED-IMAGE STORE above for the store this fills and for
                 * why each refusal answers the errno it does.
                 *
                 * A verb that is not all here yet BREAKS rather than failing:
                 * the carry buffer above exists precisely because a client may
                 * split a record across write(2) calls, and a 256x256 image is
                 * 262 KiB — sixty-four of the 4 KiB chunks the syscall bounce
                 * delivers.  devwsys needs a whole staging allocator for this
                 * (_wsys_img_stg_begin/_body); here the carry buffer already
                 * IS that staging, so the streaming case is the same code as
                 * the small one. */
                if (carried - i < 2) break;
                uint64_t nlen = carry[i + 1];
                if (nlen == 0 || nlen >= WSYS_IMG_NAME_CAP) {
                    carried = 0; errno = EINVAL; return -EINVAL;
                }
                uint64_t hdr = 2 + nlen + 9;
                if (carried - i < hdr) break;
                int32_t iw = le32(carry + i + 2 + nlen);
                int32_t ih = le32(carry + i + 2 + nlen + 4);
                uint8_t ifmt = carry[i + 2 + nlen + 8];
                int ibpp = (ifmt == 3) ? 1 : (ifmt == 1 || ifmt == 2) ? 4 : 0;
                if (iw <= 0 || ih <= 0 || !ibpp) {
                    carried = 0; errno = EINVAL; return -EINVAL;
                }
                if (iw > WSYS_IMG_MAX_W || ih > WSYS_IMG_MAX_H) {
                    /* Refused BEFORE the payload is waited for: an oversized
                     * image would otherwise sit in the carry buffer until it
                     * overflowed, and the client would be told EMSGSIZE about
                     * the wrong thing several megabytes later. */
                    carried = 0; errno = EMSGSIZE; return -EMSGSIZE;
                }
                uint64_t ipix = (uint64_t)iw * (uint64_t)ih * (uint64_t)ibpp;
                if (carried - i < hdr + ipix) break;
                int rc = img_store(v->wid, (const char *)carry + i + 2, nlen,
                                   iw, ih, ifmt, carry + i + hdr);
                if (rc < 0) { carried = 0; errno = -rc; return rc; }
                /* The scene display list naming this image is byte-identical
                 * frame to frame, so a damage diff over the scene text alone
                 * would call a re-uploaded video frame "nothing to paint".
                 * devwsys bumps a per-window content serial here for exactly
                 * that; the analogue on this line is the segment generation
                 * the compositor already watches. */
                shm->gen++;
                wr(WR_IMAGE, hdr + ipix);
                used = hdr + ipix;
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
        errno = 0;
        wr(sink_is_public(f->name) ? WR_SINK : WR_CHROME, n);
        struct wsink *s = sink_find(f->name, 1);
        if (!s) { int e = errno ? errno : ENOSPC; errno = e; return -e; }
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
    case HAMWSYS_POOL:
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
    wr(WR_OWNER, 0);
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
    wr(WR_DESTROY, 0);
    bb_release(wid);
    img_release_wid(wid);              /* devwsys's _wsys_img_release_wid */
    v->used = 0;
    if (shm->focus_wid == wid) shm->focus_wid = 0;
    shm->gen++;
    return 0;
}
