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
#include <poll.h>
#include <sys/epoll.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/un.h>
#include <sys/wait.h>          /* stage 5's gate driver waits for its children */
#include <linux/futex.h>
#include <time.h>
#include <unistd.h>

#include "linux-wsys.h"

/* user/linux-syscalls.c.  Declared here rather than in a header because the
 * runtime has no header for its process bookkeeping: see the orphan reaper
 * there for what registering a child buys. */
void hamnix_own_child_remember(int32_t p);

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
 * 16.  7 doubles it a third time, 256 -> 512, for MAXCONN 32 -- TWO BROWSERS.
 * struct wwin is BYTE-FOR-BYTE UNCHANGED at 6 and at 7, and so is every field
 * of struct wshm that precedes win[], so a v5, a v6 and a v7 build agree about
 * where window 0..127 are and disagree only about how many there are after
 * them.  The version still has to move, and this is what each direction does
 * -- checked by running it, in tests/linux/wsyswl_conn_ceiling.sh, not
 * reasoned about (the paragraphs below are written for 5-meets-6; 6-meets-7 is
 * the same arithmetic with 19,052,956 in place of 9,593,244):
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
 * that desktop's window table by design and always has.
 *
 * 7 MOVES THE KEYSTROKES OUT OF THE SEGMENT (THE KEYSTROKE CHANNEL, below).
 * struct wshm and struct wwin are BYTE-FOR-BYTE what 6 had -- the `keys` ring
 * is still there, at the same offset, and is now dead storage -- so this is the
 * first bump where the layouts agree completely and only the MEANING differs.
 * That is exactly why it has to move.  A v6 binary sharing a v7 session would
 * find a perfectly well-formed table, write a keystroke into the dead ring, and
 * deliver nothing to anybody; a v6 client would park on that ring for ever and
 * report no keyboard input.  A silent half-share of a table two builds disagree
 * about is what this counter exists to prevent, and "the layout matches" is not
 * "the protocol matches".
 *
 * "IT IS LOUD -- THE WINDOWS GO" WAS WRONG, AND IT WAS MEASURED WRONG.
 * This paragraph used to end by calling the re-initialise LOUD and therefore
 * acceptable, the alternative being "a desktop that looks right and ignores the
 * keyboard".  tests/linux/installed_update_wsysver.sh ran that sentence on a
 * real installed UEFI+ext4 machine and it is neither loud nor acceptable:
 *
 *   * `hpm update` exits 0 and says nothing about a window system or a session.
 *   * The next application opened flips the segment to v7 and the ENTIRE
 *     DESKTOP disappears -- wallpaper, icons, panel, taskbar and the person's
 *     own terminal.  What is left is a featureless slab and a mouse cursor;
 *     one run instead showed one window titled "Terminal" painting the dead
 *     BACKDROP's wallpaper, because the new client took the dead backdrop's row.
 *   * The compositor keeps running and repaints nothing.  It still counts
 *     keystrokes and routes them nowhere.  It still owns /dev/fb, so the text
 *     console is not behind it.
 *   * There is no panel, no Applications button and nothing to click.  On a
 *     physical machine the only remaining control is the power button.
 *
 * A compositor that is up and painting nothing is precisely the success-shaped
 * answer NORTH_STAR.md forbids.  So the remedy is no longer unconditional: see
 * A LIVE SESSION IS NOT A LEFTOVER, above shm_attach.  A build meeting a
 * foreign segment that some LIVE process still holds a window in REFUSES TO
 * ATTACH, says so by name on stderr, and changes nothing; the running session
 * survives whole and only the newly-started program fails.  A leftover segment
 * -- nobody holding a row -- is re-initialised exactly as before, which is what
 * keeps the first program after a boot working.
 *
 * VERSION 7 CARRIES TWO CHANGES, not one, and they landed from different
 * branches: the window table grew to 512 rows AND the keystrokes left the
 * segment.  They share a version because they ship together; a reader who
 * knows only one of them would draw the wrong conclusion about the other.
 *
 * WHAT AN OLD BINARY DOES AGAINST A NEW LAYOUT, stated as NORTH_STAR.md's
 * standing invariant requires: a v6 build meeting a v7 segment reads version 7
 * != 6 and re-inits.  This is the MAPPED-PREFIX direction, not the
 * complete-and-clean one -- v7 is 37,972,380 bytes to v6's 19,052,956, so a v6
 * build maps and re-inits only the prefix and cannot reach rows 256..511; the
 * next v7 attacher punches the whole segment before anything reads a row --
 * UNLESS that segment is a live session, in which case it now refuses.  A v6
 * build has no such refusal in it, because the refusal ships in v7: the FIRST
 * bump this protects is 7 -> 8, and what it does for 6 -> 7 is stop every v7
 * binary (which is every binary the update installs) from wiping the v6 session
 * it finds running.  No new binary
 * ships here and no package list changes: the channel is code inside
 * user/linux-wsys.c, which every wsys program already links.
 *
 * 8 MOVES THE v1 DISPLAY LIST OUT OF THE SEGMENT (THE PIXEL HAND-UP, below).
 * struct wshm and struct wwin are AGAIN byte-for-byte what 7 had -- scene,
 * stage, scene_len and stage_len are still there, at the same offsets, and are
 * now dead storage -- so this is the SECOND bump where the layouts agree
 * completely and only the MEANING differs, and it is the same argument as 7's:
 * a v7 binary sharing a v8 session would find a perfectly well-formed table,
 * write its display list into the dead buffer and commit it, and NOTHING would
 * ever be painted; a v7 compositor would read every window's scene out of the
 * dead buffer and composite a screen of empty windows.  A silent half-share.
 *
 * WHAT IT COSTS A RUNNING DESKTOP, since 7's own bump was measured to cost more
 * than its comment claimed.  Nothing, unless two builds meet: A LIVE SESSION IS
 * NOT A LEFTOVER (above shm_attach) ships in v7, so a v8 binary that finds a
 * LIVE v7 session REFUSES TO ATTACH and says so by name -- the newly-started
 * program fails, the running desktop is untouched.  That refusal is what makes
 * this bump affordable and it is why it could not have been made before 7.
 * The v7 direction is the one with no remedy in it: a v7 binary started into a
 * v8 session re-inits, exactly as `installed_update_wsysver.sh` measured.  The
 * SIZE is identical at 7 and 8 (37,972,380 bytes, 512 rows), so seg_rows_in()
 * still recovers the row count from the size in both directions and THE FROZEN
 * THREE are unchanged.
 *
 * No new binary ships here either, and no package list changes: like the
 * keystroke channel, the pixel hand-up is code inside user/linux-wsys.c, which
 * every wsys program already links. */
#define WSYS_VERSION      8
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
 * FIVE HUNDRED AND TWELVE, AND THE INTERESTING PART IS THAT IT IS CHEAPER
 * THAN 256 WAS.
 *
 * MAXCONN 16 did not fit TWO browsers -- Firefox's measured appetite is 8
 * connections, so 8 + 8 + a namespace's Xwayland or two is 18 or 19, and a
 * client past the ceiling loses a WHOLE PROGRAM.  MAXCONN is 32 now and the
 * no-starvation invariant makes this 32 * 16 = 512.
 *
 * The previous pass refused exactly this and named the reason: "512 rows and
 * 36.21 MiB resident on every boot of every machine".  That number was true
 * and its CAUSE was not the table.  It was one line in shm_attach:
 *
 *     memset(shm, 0, sizeof *shm);
 *
 * run on a segment that had just been ftruncate(2)d out of a fresh tmpfs file
 * -- i.e. on bytes the kernel had ALREADY promised read as zero and for which
 * it had allocated nothing.  The memset's entire effect was to fault in and
 * dirty all 4,650 pages of a window table with no windows in it.  Delete it
 * (see THE ZEROES WE DO NOT WRITE in shm_attach) and the table becomes what
 * the BB_SLOTS pool below already was: ADDRESS SPACE, with residency
 * proportional to the windows that exist.
 *
 * MEASURED WITH du(1), by the test, not computed here.  256 rows, 16
 * connections, no windows: 18,608 KiB before, 1,024 KiB after.  512 rows and
 * 32 connections: 36.32 MiB of address space and about 2 MiB resident -- HALF
 * of what half the table cost yesterday.  A window that is actually opened
 * still costs its 74,425 bytes, which is the honest price and the one that
 * scales with what a person is doing rather than with a constant.
 *
 * WHERE THE ~2 MiB FLOOR COMES FROM, since it is not zero: win_find and the
 * /dev/wsys/windows and pool readers scan the table linearly for `used`, and
 * `used` is the first word of a row, so every row's FIRST PAGE is faulted in
 * by a scan even when the row is empty.  512 rows * 4 KiB = 2,048 KiB.  That
 * is 4 KiB per row where it was 74 KiB, an 18x reduction, and it is a floor
 * that can be removed later by moving the used-bitmap out of the rows -- which
 * would move struct wshm's prefix and is therefore a separate version and a
 * separate pass, not something to do quietly here. */
#define WSYS_MAX_WINDOWS  512
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
    /* scene_len_dead / stage_len_dead / scene_dead / stage_dead ARE DEAD
     * STORAGE, kept for exactly the reason keys_dead below is kept.
     *
     * The v1 display list left this segment -- see THE PIXEL HAND-UP -- because
     * bytes in a world-READABLE mapping are readable by anything on the machine
     * and nothing in a mapping can be otherwise.  A window's committed scene is
     * what is drawn inside it, spelled as text: `glyphs` ops carry the actual
     * strings, so scraping a terminal's scene is reading its screen.  Nothing
     * reads or writes these 32 KiB and these two lengths any more.
     *
     * They stay because removing them would change sizeof(struct wwin), and
     * THE SPLIT records why that is not a version bump this file can survive.
     * struct wwin is byte-for-byte what versions 6 and 7 had.
     *
     * They are also what lets tests/linux/wsys_bypass.sh keep DRIVING attack 2
     * (SCRIBBLE) instead of deleting it: the bypasser still maps the table,
     * still finds the row and still writes these bytes, and the gate now
     * asserts that the committed scene is not among them and that the scribble
     * never reaches the protocol.
     *
     * scene_gen IS NOT DEAD.  It is the public CHANGE NOTIFICATION -- the
     * counter a compositor polls to learn that a window has a new frame -- and
     * it says nothing about what the frame contains.  It stays in the table for
     * the same reason the geometry does: /dev/wsys/wctl publishes it, and every
     * reader of that file wants it.  It is world-writable and therefore a HINT,
     * and what a liar can do with it is bounded and already on the residue
     * list: raising it causes a repaint of bytes it still cannot read, and
     * zeroing it makes the scene read empty (see the open path) so the window
     * paints blank.  That is CORRUPTION, which THE SPLIT says plainly is not
     * closed by any of this and needs tier 1 -- the same attacker could
     * already destroy the row outright. */
    uint32_t scene_len_dead;
    uint32_t scene_gen;                       /* ++ on every commit */
    /* WAS stage_len_dead, AND IT IS NOW wctl's FOCUS MODE -- 0 click (the
     * default), 1 sloppy.  Reusing a dead word rather than adding a field is
     * deliberate: struct wwin is byte-for-byte what versions 6, 7 and 8 had,
     * and a new field would move every field after it, change sizeof(struct
     * wwin) and sizeof(struct wshm), and cost a WSYS_VERSION bump -- which is
     * an update that refuses to attach to a running desktop.  A dead word
     * costs nothing and moves nothing.
     *
     * SAFE AGAINST THE BUILDS ALREADY IN THE FIELD: this word is dead in every
     * shipped v8 binary, so an old binary sharing the segment neither reads nor
     * writes it and simply does not know about focus mode.  Nothing degrades.
     * It is world-writable like the rest of the row, so like `scene_gen` it is
     * a HINT -- an attacker who flips it changes a focus policy on a window
     * whose title, geometry and existence it could already change.  That is the
     * CORRUPTION residue THE SPLIT names, not a new exposure. */
    uint32_t focus_mode;
    char     title[WSYS_TITLE_CAP];
    uint8_t  scene_dead[WSYS_SCENE_CAP];
    uint8_t  stage_dead[WSYS_SCENE_CAP];
    /* keys_dead IS DEAD STORAGE, and it is kept rather than removed.
     *
     * Keystrokes left this segment entirely -- see THE KEYSTROKE CHANNEL --
     * because bytes in a world-readable mapping are readable by a keylogger and
     * nothing in a mapping can be otherwise.  Nothing reads or writes these
     * WSYS_RING_CAP bytes any more.  They stay because removing them would move
     * every field after them and change sizeof(struct wwin), and THE SPLIT
     * records why that is not a version bump this file can survive: an old
     * binary meeting a new table memsets a running session.  struct wwin is
     * byte-for-byte what version 6 had.
     *
     * It is also what lets tests/linux/wsys_bypass.sh keep DRIVING attack 3
     * instead of deleting it: the bypasser still finds the row and still writes
     * this ring, and the gate now asserts that nothing ever comes out of it. */
    struct wring keys_dead;
    struct wring pointer, event, text, cmd;
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
 * WHAT THAT COSTS, exactly, because 512 screen-sized double-buffered surfaces
 * sounds like eight gigabytes and is not.  It is eight gigabytes of ADDRESS
 * SPACE in a sparse file that is never mapped whole -- BB_HDR_BYTES is the
 * only mapping any process makes up front, and it is 64 KiB -- and the
 * resident cost is the sum of the windows'
 * OWN areas: bb_fit and bb_blit touch w*h*4 bytes and never BB_BYTES, and
 * the segment's initialiser zeroes the headers and not the pixels.  Twelve
 * 186x110 xterms are 12 * 82 KiB of real memory, not 12 * 16 MiB.  Getting
 * that wrong is the difference between this being free and this being
 * impossible, so it is a property of the code below and not a hope. */
#define BB_SLOTS   WSYS_MAX_WINDOWS

/* THE LARGEST SURFACE THIS SYSTEM CAN SHOW, AND IT WAS PICKED FROM ONE PANEL.
 *
 * This was 1920x1080, and on 2026-08-15 the owner booted a ThinkPad whose panel
 * is 1920x1200 -- ordinary 16:10, not exotic -- and the desktop did not start.
 * user/wsysd.ad kept its own copy of this ceiling, found 1200 > 1080, refused to
 * composite, and therefore never published /dev/wsys/screen; every client then
 * died on "no screen geometry", which names the symptom and not the cause.
 *
 * WHY RAISING IT IS NEARLY FREE, and this is an argument from this file rather
 * than a hope.  BB_W x BB_H is a CEILING, not an allocation:
 *
 *   * The pixels live in a per-window memfd (THE BACKBUFFER MEMFD below) that is
 *     ftruncate'd to BBPIX_BYTES and is SPARSE.  bb_fit clears w*h*4 and bb_blit
 *     writes inside w*h*4; nothing in this file ever touches BB_BYTES of a page.
 *     A 186x110 xterm is 82 KiB resident whether this constant is 1080 or 1600.
 *   * struct bbshm holds slot HEADERS only -- the pixels left it in the
 *     pixel-out rewrite -- so BB_FILE_BYTES is BB_HDR_BYTES and does not move.
 *     sizeof(struct wshm), sizeof(struct wwin) and the /srv/wsys segment layout
 *     do not mention BB_W or BB_H at all, so this costs NO WSYS_VERSION bump.
 *     MEASURED rather than asserted, because that claim is worth 92 of 124
 *     packages: shm_attach ftruncates $HAMWSYS to sizeof(struct wshm), so the
 *     file size IS the number. A wsysd linked against this file at 1920x1080
 *     and one linked against it at 2560x1600, same geometry, same run:
 *     37,972,380 bytes BOTH TIMES.
 *   * bbpix_page's mmap length is BB_BYTES: address space in a sparse file,
 *     which is the same currency BB_SLOTS spends 512 slots of above.
 *
 * WHAT IT DOES COST REAL MEMORY, and it is the reason this is 2560x1600 and not
 * 3840x2160: WSYS_CARRY_CAP below is 18 + BB_BYTES, and carry_reserve() will
 * realloc a per-descriptor reassembly buffer up to it on behalf of a client that
 * streams a full-screen blit.  That is a genuine allocation ceiling a peer can
 * drive, so it should be the largest frame a REAL panel here will send and not
 * an arbitrary headroom.  1080 -> 1600 takes it from 8.29 MB to 16.4 MB; 2160
 * would take it to 33.2 MB for a panel this compositor has no scaling story for.
 *
 * SO: 2560x1600.  It is the smallest rectangle that covers every panel this
 * project is actually asked about -- 1920x1080, the owner's 1920x1200, and the
 * 2560x1440 and 2560x1600 that a laptop bought today has -- and it is a
 * RECTANGLE rather than a pixel count, because the clamps below are per-axis
 * and a ceiling that disagrees with its own clamps is how 1920x1200 got here.
 *
 * user/wsysd.ad's COMP_W/COMP_H MUST MATCH THESE.  It has its own copy because
 * it is Adder and cannot include this header; snap_pool publishes `maxsurface
 * <BB_W>x<BB_H>` on /dev/wsys/pool precisely so that copy can be CHECKED rather
 * than trusted, and wsysd checks it at startup and says so loudly if it drifts. */
#define BB_W       2560
#define BB_H       1600
#define BB_BYTES   ((size_t)BB_W * BB_H * 4)

/* THE LARGEST DRAW RECORD THIS DEVICE WILL EVER REASSEMBLE, and it is derived
 * rather than picked.
 *
 * draw/ctl's arm holds an incomplete record in a per-descriptor buffer until
 * the rest of it arrives (see THE REASSEMBLY BUFFER there).  That buffer used
 * to be a fixed 1 MiB array, and 1 MiB is not a bound that anything in this
 * file implies -- it was smaller than a single frame of the largest window the
 * same file defines, which is the whole of the defect the buffer has now been
 * caught in twice.  The bound that IS implied is this one:
 *
 *   'B' blit    18 + (x1-x0)*(y1-y0)*4, and a rect wider than BB_W or taller
 *               than BB_H cannot be shown at all -- bb_blit clips every pixel
 *               outside the window, and no window exceeds BB_W x BB_H.  So the
 *               largest USEFUL blit is 18 + BB_BYTES = 16,384,018 bytes.
 *   'I' image   2 + 31 + 9 + WSYS_IMG_MAX_W*WSYS_IMG_MAX_H*4 = 262,186.
 *   'C' cursor  18 + a sprite whose declared size this arm does NOT bound --
 *               it only skips the payload, never reads it, so the cap below
 *               is what bounds it, and a sprite past the cap is refused
 *               loudly.  Real ones are 32x32.
 *   'D' damage  17.
 *
 * The blit dominates, so the cap is the blit's, and it moves when BB_W/BB_H
 * move because it is written in terms of them.  Anything past it is refused
 * LOUDLY -- a frame that is dropped must never be answered success-shaped. */
#define WSYS_CARRY_CAP  ((uint64_t)(18 + BB_BYTES))

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
/* Bumped from 0x42425747 ("GWBB") when the pixels left this file: a build that
 * still put pixels here is re-initialised rather than trusted (see bb_attach). */
#define BBSHM_MAGIC 0x42425753u        /* "SWBB" */
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
 * mmap's offset must be a multiple of the page size.  BB_BYTES used to be
 * 1920*1080*4 = 8294400, which is 2025 * 4096 -- fine on a 4 KiB-page kernel
 * and NOT a multiple of 16 KiB or 64 KiB (8294400/65536 = 126.5625).  Rounding
 * only the header up would leave every odd-numbered page offset misaligned on
 * a 16 KiB- or 64 KiB-page kernel: mmap returns EINVAL, bb_page returns NULL,
 * and half the windows are blank with "a blit was thrown away" -- the exact
 * silent failure this rewrite exists to remove, waiting for the first arm64
 * build.  So the per-page STRIDE is rounded to 64 KiB as well.  It costs
 * address space in a sparse file and nothing else.
 *
 * At 2560x1600 the rounding happens to be a no-op -- 16384000 = 250 * 65536
 * exactly -- and that is LUCK, not a reason to remove it.  The next ceiling
 * will not be so obliging, and the failure it prevents is silent. */
#define BB_ALIGN      ((size_t)65536)
#define BB_HDR_BYTES  ((size_t)((sizeof(struct bbshm) + BB_ALIGN - 1) & ~(BB_ALIGN - 1)))
#define BB_PAGE_BYTES ((size_t)((BB_BYTES + BB_ALIGN - 1) & ~(BB_ALIGN - 1)))
/* THE METADATA FILE HOLDS NO PIXELS ANY MORE.  Its whole extent is the header
 * struct (rounded up), and the two pixel pages per slot that used to follow it
 * are GONE FROM THE SHARED MAPPING -- see THE BACKBUFFER MEMFD below.  This is
 * the byte count that changed the /srv/wsys.bb scrape from "the whole desktop's
 * pixels" to "a table of geometry a client already publishes". */
#define BB_FILE_BYTES ((off_t)BB_HDR_BYTES)

/* The pool can never be the first thing to run out.  If someone shrinks it
 * below the window table, this fails to compile rather than becoming a blank
 * window six months later. */
typedef char bb_pool_covers_the_window_table[
    (BB_SLOTS >= WSYS_MAX_WINDOWS) ? 1 : -1];

static struct bbshm *bb;
static int       bb_fd = -1;           /* the metadata file, kept open */

/* ------------------------------------------------------------------ *
 * THE BACKBUFFER MEMFD — the confidentiality fix, and why it is one.
 *
 * WHAT WAS OPEN.  /srv/wsys.bb was a third 0666 mapping holding every v2
 * window's PIXELS -- and a v2 window is what a browser, a video and a bridged X
 * client are.  Any same-uid process could open it O_RDONLY, map it and read
 * another window's backbuffer BY NAME (the slot carries its wid): a password
 * typed into a web page sat in a slab any process on the machine could scrape,
 * while the same password typed into a hamUI dialog did not.  tests/linux/
 * wsys_bypass.sh's `sameuid.bbreal` recovers exactly those bytes to prove it.
 *
 * THE FIX IS THE PIXEL HAND-UP'S, APPLIED TO PIXELS.  It is the SAME
 * construction the v1 display list already uses (THE PIXEL HAND-UP, far below):
 * the bytes live in a per-window MEMFD the window's OWNER creates -- which has
 * no name in the filesystem and, against a hardened owner (PR_SET_DUMPABLE 0 +
 * ptrace_scope=1), no /proc path either -- and the owner hands the descriptor
 * UP to the compositor over an abstract AF_UNIX rendezvous, checking
 * SO_PEERCRED so it hands it to nobody but the segment's owner.  A non-owner
 * has no descriptor for a window it does not own and no mapping to scrape.
 *
 * WHY A SECOND MEMFD AND NOT THE SCENE'S.  The scene memfd (struct wpix) is
 * 64 KiB; a backbuffer is two 8 MiB pages.  A v2 window (a browser) has no v1
 * scene and a v1 window (a terminal) has no backbuffer -- they are disjoint in
 * practice -- so folding the pixels into struct wpix would put 16 MiB of
 * address space behind every terminal's scene and a scene buffer behind every
 * browser, both dead.  The MECHANISM is reused (the abstract rendezvous, the
 * sender-side SO_PEERCRED check, the clock-driven re-announce, the seal check,
 * the inode dup-detect); only the payload and the address suffix differ.  A
 * dedicated channel also keeps this change out of the shipped-and-gated scene
 * hand-up, which another pass depends on.
 *
 * WHY IT IS A POOL REWRITE AND NOT A MOVE.  The old shared slabs were a central
 * pool of BB_SLOTS page-mapped surfaces; a non-owner mapped the pool and
 * indexed it.  Moving the pool to another offset in the same 0666 file would
 * change nothing.  The pool is DISMANTLED: each window's pixels become private
 * memory the owner alone maps and the compositor alone is handed, page-mapped
 * on demand exactly as before (a 32x6 window still dirties a few KiB of a 16 MiB
 * sparse memfd).  The shared file keeps ONLY the pool ACCOUNTING -- used slots,
 * exhaustion events -- which is geometry, already world-readable in the window
 * table, and no longer any pixels at all.
 * ------------------------------------------------------------------ */
#define BBPIX_MAGIC     0x32425747u    /* "GWB2" */
#define BBPIX_VERSION   1
#define BBPIX_HDR_BYTES BB_ALIGN
#define BBPIX_PX_OFF(pg) ((off_t)BBPIX_HDR_BYTES + (off_t)(pg) * (off_t)BB_PAGE_BYTES)
#define BBPIX_BYTES     ((off_t)BBPIX_HDR_BYTES + 2 * (off_t)BB_PAGE_BYTES)

/* The memfd's header.  The double-buffer state (front/started/gen) lives HERE,
 * shared between the one owner that writes the pixels and the one compositor it
 * hands them to -- not in the 0666 metadata file, whose front word an attacker
 * could otherwise steer at pixels it still cannot read. */
struct bbpix {
    uint32_t magic, version;
    int32_t  wid;
    int32_t  w, h;
    uint32_t gen;          /* ++ on every flip */
    uint32_t front;        /* which page the compositor reads */
    uint32_t started;      /* a frame is in progress on the back page */
};

/* One entry per window this process touches: the owner's own memfd (own=1,
 * created and handed up) or a foreign window's memfd this process was handed
 * (own=0, the compositor's copy).  Keyed by wid; the two never collide because
 * a process is never both a window's owner and its compositor. */
struct bbmap {
    int32_t       wid;
    int           fd;
    struct bbpix *hdr;      /* the 64 KiB header mapping */
    uint8_t      *px[2];    /* the two pixel pages, mapped on demand */
    int           own;      /* we created it (an owner) vs were handed it */
    uint64_t      due;      /* next hand-up attempt, ms (owner side) */
    int           handed;   /* a hand-up has succeeded */
    uint64_t      ino;      /* the memfd's, for dup detect */
};
static struct bbmap bbmap[WSYS_MAX_WINDOWS];
static int          bbmap_n;

static int bb_find(int32_t wid)
{
    for (int i = 0; i < bbmap_n; i++)
        if (bbmap[i].wid == wid) return i;
    return -1;
}

/* Entry i's page `pg`, mapped on demand from that window's memfd.  NULL means
 * the mapping failed, and every caller treats that as "this window has no
 * pixels this frame" rather than writing somewhere else. */
static uint8_t *bbpix_page(int i, unsigned pg)
{
    if (i < 0 || i >= bbmap_n || pg > 1) return NULL;
    if (bbmap[i].px[pg]) return bbmap[i].px[pg];
    if (bbmap[i].fd < 0) return NULL;
    void *m = mmap(NULL, BB_BYTES, PROT_READ | PROT_WRITE, MAP_SHARED,
                   bbmap[i].fd, BBPIX_PX_OFF(pg));
    if (m == MAP_FAILED) return NULL;
    bbmap[i].px[pg] = (uint8_t *)m;
    return bbmap[i].px[pg];
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
    /* THE MAGIC IS BUMPED FOR THE PIXEL-OUT REWRITE, and the bump is what makes
     * a stale segment from a pixel-carrying build safe to meet: an old file's
     * magic (0x42425747) fails this test, so it is re-initialised to the new,
     * pixel-free header AND ftruncated back down to it -- which DROPS the stale
     * pixel pages a scraper could otherwise still find in an oversized leftover.
     * A build that disagrees about BB_SLOTS is likewise re-initialised, so the
     * pool accounting is never half-believed. */
    if (bb->magic != BBSHM_MAGIC || bb->nslots != (uint32_t)BB_SLOTS) {
        if ((uint64_t)st.st_size > (uint64_t)BB_FILE_BYTES)
            (void)ftruncate(fd, BB_FILE_BYTES);   /* drop stale pixel pages */
        memset(bb, 0, sizeof *bb);
        bb->magic  = BBSHM_MAGIC;
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
/* Defined far below, but reached by bb_own here (a window owner hardens the
 * moment it creates private pixel memory, whether that is a scene or a
 * backbuffer) and by the backbuffer hand-up, which mirrors the pixel one. */
static void         owner_harden(void);
static void         bbup_tick(void);
static void         bbup_listen(void);
static void         bbup_drain(void);
/* THE KEYSTROKE CHANNEL, defined below -- the one ring that is not in the
 * shared segment.  Declared here because the park, the teardown and the
 * open/read/write paths all reach it and they are spread across this file. */
static void         keychan_unbind(int32_t wid);
static int          keychan_ready(int32_t wid);
static int          keychan_find(int32_t wid);
static int          keychan_bind(int32_t wid);
static uint64_t     keychan_recv(int32_t wid, uint8_t *b, uint64_t cap);
static int64_t      keychan_send(int32_t wid, const uint8_t *b, uint64_t n);
/* THE PIXEL HAND-UP, defined below -- the v1 display list is not in the shared
 * segment either.  Declared here for the same reason: a window's teardown is
 * in four places and every one of them must give the memory back. */
static void         pix_release(int32_t wid);
static void         pix_tick(void);

static void bb_once(int *flag, const char *msg, int a, int b, int c, int d)
{
    if (*flag) return;
    *flag = 1;
    fprintf(stderr, "wsys: BACKBUFFER %s (%d %d %d %d)\n", msg, a, b, c, d);
}

static int bb_warn_full, bb_warn_clamp, bb_warn_drop, bb_warn_refit;

/* THE POOL ACCOUNTING, and NOTHING ELSE, now lives in the shared file.  These
 * two calls keep /dev/wsys/pool's used-slot count and exhaustion events global
 * across processes -- geometry a client already publishes -- while the pixels
 * they used to sit beside have moved to the per-window memfd. */
static void bb_pool_claim(int32_t wid, int w, int h)
{
    if (bb_attach() < 0) return;
    for (int i = 0; i < BB_SLOTS; i++)
        if (bb->slot[i].used && bb->slot[i].wid == wid) {
            bb->slot[i].w = w; bb->slot[i].h = h; return;
        }
    for (int pass = 0; pass < 2; pass++)
        for (int i = 0; i < BB_SLOTS; i++) {
            /* Second pass: reclaim the accounting rows of windows that no
             * longer exist, exactly as the pixel pool used to. */
            if (bb->slot[i].used) {
                if (pass == 0 || win_find(bb->slot[i].wid)) continue;
                bb->slot[i].used = 0;
            }
            memset(&bb->slot[i], 0, sizeof bb->slot[i]);
            bb->slot[i].used = 1; bb->slot[i].wid = wid;
            bb->slot[i].w = w; bb->slot[i].h = h;
            return;
        }
    bb->full_evt++; bb->full_wid = wid; bb->full_w = w; bb->full_h = h;
    bb_once(&bb_warn_full, "no accounting row left for a window's backbuffer; "
            "read /dev/wsys/pool", wid, BB_SLOTS, w, h);
}

static void bb_pool_release(int32_t wid)
{
    if (!bb) return;
    for (int i = 0; i < BB_SLOTS; i++)
        if (bb->slot[i].used && bb->slot[i].wid == wid)
            bb->slot[i].used = 0;
}

/* THE SIZE A BACKBUFFER WILL ACTUALLY BE, given the size that was asked for.
 *
 * These exist because bb_for compared the size ASKED FOR against the size
 * STORED, and for any window wider than BB_W those two can never be equal:
 * bb_fit clamps on the way in, so a 2046-wide window stored 1920 and bb_for
 * saw 1920 != 2046 on EVERY BLIT.  Every blit therefore re-fit the memfd,
 * and bb_fit clears it -- so the window was wiped between one row and the
 * next and nothing was ever on the screen.  A comparison has to be made
 * between two numbers of the same kind. */
static int bb_clamp_w(int w) { return w > 0 && w <= BB_W ? w : BB_W; }
static int bb_clamp_h(int h) { return h > 0 && h <= BB_H ? h : BB_H; }

/* Fit a window's memfd to a size, clearing it.  A resize means the client is
 * about to redraw, and a stretched copy of the old frame in the meantime is a
 * worse answer than a blank one it immediately overwrites. */
static void bb_fit(int i, int w, int h)
{
    struct bbpix *hd = bbmap[i].hdr;
    if (!hd) return;
    /* THE OLD SIZE MATTERS, because the clear has to cover it. */
    size_t was = (size_t)hd->w * hd->h * 4;
    hd->w = bb_clamp_w(w);
    hd->h = bb_clamp_h(h);
    hd->started = 0;
    /* CLEAR THE PIXELS THIS WINDOW CAN ACTUALLY SHOW, not BB_BYTES.  Rows are
     * packed at the window's width (see bb_blit), so its pixels are w*h*4
     * contiguous bytes at the start of each page and everything past them is
     * unreachable -- reads are bounded by the same product.  A fresh memfd is
     * already zero, so this only costs anything on a genuine resize; the old
     * extent is cleared too where it was larger, so a shrink cannot leave a
     * previous frame's pixels inside the new one. */
    size_t now = (size_t)hd->w * hd->h * 4;
    size_t clr = was > now ? was : now;
    if (clr > BB_BYTES) clr = BB_BYTES;
    if (clr) {
        uint8_t *p0 = bbpix_page(i, 0), *p1 = bbpix_page(i, 1);
        if (p0) memset(p0, 0, clr);
        if (p1) memset(p1, 0, clr);
    }
    hd->gen++;
    if ((w > 0 && w > BB_W) || (h > 0 && h > BB_H))
        bb_once(&bb_warn_clamp, "window is bigger than the backbuffer -- "
                "its pixels will be cut to BB_W x BB_H", w, h, BB_W, BB_H);
}

/* THE OWNER'S SIDE: get, or create, this process's own backbuffer memfd for a
 * window.  It has no name in the filesystem, and creating it hardens the
 * process (owner_harden, exactly as pix_own does) so its /proc/<pid>/fd cannot
 * be walked for the descriptor either.  The double-buffer state lives in the
 * memfd's header; the shared file gets only an accounting row. */
static int bb_own(int32_t wid, int w, int h)
{
    if (bbmap_n >= WSYS_MAX_WINDOWS) { errno = ENOSPC; return -1; }
    int fd = (int)syscall(SYS_memfd_create, "hamnix-wsys-bb",
                          MFD_CLOEXEC | MFD_ALLOW_SEALING);
    if (fd < 0) {
        bb_once(&bb_warn_drop, "memfd_create for a backbuffer failed -- this "
                "window has nowhere private to keep its pixels", wid, errno, 0, 0);
        return -1;
    }
    /* SEALED like the scene memfd, and the SHRINK seal is the compositor's
     * life: a receiver that has mapped a file the sender can ftruncate smaller
     * takes SIGBUS on the next touch, and the receiver here paints the screen. */
    if (ftruncate(fd, (off_t)BBPIX_BYTES) < 0
        || fcntl(fd, F_ADD_SEALS,
                 F_SEAL_SHRINK | F_SEAL_GROW | F_SEAL_SEAL) < 0) {
        close(fd);
        return -1;
    }
    void *m = mmap(NULL, BBPIX_HDR_BYTES, PROT_READ | PROT_WRITE,
                   MAP_SHARED, fd, 0);
    if (m == MAP_FAILED) { close(fd); return -1; }
    int i = bbmap_n++;
    bbmap[i].wid = wid; bbmap[i].fd = fd; bbmap[i].hdr = (struct bbpix *)m;
    bbmap[i].px[0] = NULL; bbmap[i].px[1] = NULL;
    bbmap[i].own = 1; bbmap[i].due = 0; bbmap[i].handed = 0; bbmap[i].ino = 0;
    bbmap[i].hdr->magic   = BBPIX_MAGIC;
    bbmap[i].hdr->version = BBPIX_VERSION;
    bbmap[i].hdr->wid     = wid;
    bb_pool_claim(wid, w, h);
    owner_harden();
    bb_fit(i, w, h);
    return i;
}

/* THE WINDOW'S SIZE IS THE WINDOW'S SIZE, AND NOTHING ELSE MAY DECIDE IT.  The
 * caller writes pixels at the window's width; user/wsysd.ad reads them back and
 * re-rows them at the same width.  When they disagreed the compositor scanned
 * out a window drawn at 640 as though it were 1280 -- two half-height copies
 * side by side, no error in any log, three passes to localise.  So the owner
 * re-fits its memfd whenever a blit's w/h no longer matches; every blit passes
 * the window's current w/h, so the two are out of step for at most one frame. */
static int bb_for(int wid, int create, int w, int h)
{
    int i = bb_find(wid);
    if (i >= 0) {
        if (create && bbmap[i].own && w > 0 && h > 0
            && (bbmap[i].hdr->w != bb_clamp_w(w)
                || bbmap[i].hdr->h != bb_clamp_h(h))) {
            bb_once(&bb_warn_refit, "a backbuffer's size did not match its "
                    "window's -- re-fitting", wid, bbmap[i].hdr->w,
                    bbmap[i].hdr->h, w);
            bb_fit(i, w, h);
            bb_pool_claim(wid, w, h);
        }
        return i;
    }
    if (!create) return -1;
    return bb_own(wid, w, h);
}

/* Re-fit an owned window's memfd to its current geometry.  Called from the
 * `geometry` ctl verb, which wsyswl sends BEFORE its first blit on purpose --
 * so a window that has not blitted yet has no memfd and this is a no-op, and
 * the first blit then creates the memfd at the window's current w/h.  A window
 * that HAS blitted is re-fit here so a resized surface is not clipped to the
 * size it opened at.  The page is cleared rather than scaled: a resize means a
 * redraw is coming, and a stretched old frame is worse than a blank one. */
static void bb_resize(int wid, int w, int h)
{
    if (w <= 0 || h <= 0) return;
    int i = bb_find(wid);
    if (i < 0 || !bbmap[i].own) return;
    if (bbmap[i].hdr->w == bb_clamp_w(w) && bbmap[i].hdr->h == bb_clamp_h(h))
        return;
    bb_fit(i, w, h);
    bb_pool_claim(wid, w, h);
}

static void bb_release(int wid)
{
    int i = bb_find(wid);
    if (i >= 0) {
        if (bbmap[i].px[0]) munmap(bbmap[i].px[0], BB_BYTES);
        if (bbmap[i].px[1]) munmap(bbmap[i].px[1], BB_BYTES);
        if (bbmap[i].hdr)   munmap(bbmap[i].hdr, BBPIX_HDR_BYTES);
        if (bbmap[i].fd >= 0) close(bbmap[i].fd);
        bbmap[i] = bbmap[bbmap_n - 1];
        bbmap_n--;
    }
    bb_pool_release(wid);
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
                "backbuffer memfd", v->wid, v->w, v->h, (int)need);
        return 18 + need;
    }
    struct bbpix *h = bbmap[slot].hdr;
    uint32_t back = h->front ^ 1u;
    if (!h->started) {
        /* Carry the last published frame forward: a client that blits only
         * what changed must not find the rest of its window blank.  The
         * window's OWN extent, for the reason in bb_fit. */
        size_t live = (size_t)h->w * h->h * 4;
        if (live > BB_BYTES) live = BB_BYTES;
        uint8_t *bp = bbpix_page(slot, back), *fp = bbpix_page(slot, h->front);
        if (!bp || !fp) {
            bb_once(&bb_warn_drop, "a blit was thrown away: this window's "
                    "pixels could not be mapped", v->wid, slot, (int)live, 0);
            return 18 + need;
        }
        memcpy(bp, fp, live);
        h->started = 1;
    }
    uint8_t *backpx = bbpix_page(slot, back);
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

/* And its (dev, ino), which names this window system's keystroke channels.
 * See THE KEYSTROKE CHANNEL below. */
static dev_t seg_dev;
static ino_t seg_ino;
static int   seg_id_known = 0;

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
 *     KEYLOG     CLOSED.  The bytes between another window's `keys` ring r and
 *                w USED to be that window's keystrokes, and wsys_bypass.sh's
 *                `snoop` read a uid-1001 victim's typing out of a uid-1001
 *                attacker without moving r or w.  Keystrokes are not in this
 *                mapping any more — THE KEYSTROKE CHANNEL, below — and the ring
 *                is dead storage.  The snooper is unchanged and still runs; its
 *                assertion is INVERTED, not deleted, so the day anything puts
 *                keystrokes back in the segment the gate says so.
 *     SCRAPE     HALF CLOSED, AND WHICH HALF DECIDES WHICH WINDOWS.  The v1
 *                committed `scene` -- the TEXT of what is drawn inside a
 *                window -- left this mapping for a per-window memfd: THE PIXEL
 *                HAND-UP, below.  The v2 BACKBUFFER did not, and a v2 window
 *                is what a browser, a video and a bridged X client are.  So a
 *                hamUI application's screen contents are private on this
 *                machine and FIREFOX'S ARE NOT.  wsys_bypass.sh drives the
 *                backbuffer scrape as a POSITIVE control on every green run so
 *                that nobody reads this paragraph as "the pixels are safe".
 *     ENUMERATE  STILL OPEN, and unfixable while the taskbar reads this table:
 *                every row's wid, pid, geometry and title.
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
 *   TIER 2 — PER-WINDOW PRIVATE memory.  scene, stage, the rings, the v2
 *     backbuffer, the named images: bytes a non-owner must not be able to map.
 *     Nothing on this tier ever touches the RPC — the 34.6/s above, and the
 *     megabytes/s a browser adds, stay exactly as fast as they are today.
 *
 *     THE KEYS RING IS DONE, and NOT the way the next paragraph used to say.
 *     It is a per-window abstract AF_UNIX datagram address the owner binds, with
 *     delivery authorised by the kernel's SCM_CREDENTIALS stamp.  See THE
 *     KEYSTROKE CHANNEL further down this file for the construction, and
 *     tests/linux/wsys_keychan.sh for the measurement.
 *
 *     WHAT THIS PARAGRAPH USED TO SAY, AND WHY IT WAS WRONG, kept because the
 *     error is instructive and would otherwise be made again: "one memfd per
 *     window, created by wsysd at `newwindow` and passed to the creating client
 *     over SCM_RIGHTS.  A memfd has no name in the filesystem, so there is no
 *     path for a bypasser to open: this is the only construction that closes
 *     attack 4."  /proc/<pid>/fd/<n> IS a path.  It is openable by any process
 *     of the same uid, and same-uid is the entire threat model.  Measured:
 *     open=3, mmap PROT_READ, `1 PASSWORD31337` read straight back out of the
 *     victim's memfd.  Built as recorded, tier 2 would have moved the keylogger
 *     one directory deeper and called it closed.  It was an argument that had
 *     never been run, in a file whose own rule is that a measurement is worth
 *     more than one.
 *
 *     WHAT REMAINS OF TIER 2 IS NOW THE BACKBUFFER AND THE IMAGES.  The scene
 *     and the stage are done (THE PIXEL HAND-UP).  What is left is left for a
 *     reason that is about the POOL and not about the construction: /srv/wsys.bb
 *     is a shared slot table, page-mapped on demand and accounted centrally in
 *     one header every client reads (`/dev/wsys/pool`), and /srv/wsys.img is a
 *     shared name-keyed store.  Splitting either into per-window memfds is a
 *     rewrite of the allocator, not a change of where a pointer points.  The
 *     paragraph below is the original text and its reasoning still holds for
 *     those two.
 *
 *     [ORIGINAL] the scene, the stage, the backbuffer and the
 *     images.  Those are BYTES A COMPOSITOR MUST READ AT FRAME RATE, so they
 *     cannot be datagrams and a memfd really is the right shape for them.  The
 *     missing piece is therefore the /proc remedy, and it is measured and
 *     waiting in the same gate: prctl(PR_SET_DUMPABLE, 0) in every window
 *     owner turns that open into EACCES, makes /proc/<pid>/fd unlistable, and
 *     refuses ptrace as well.  It is a per-process property, so it belongs with
 *     whatever hands the memfd out, and it costs core dumps and same-uid
 *     debugging of DE clients — which is a decision, not a detail.
 *
 *     AND IT HAS SINCE BEEN BUILT, FOR THE SCENE AND THE STAGE, WITH NO
 *     AUTHORITY AT ALL -- THE PIXEL HAND-UP, below.  Everything the three
 *     blockers at the foot of this comment demand followed from having the
 *     authority CREATE the memfd and hand it DOWN to a client, which needs the
 *     recipient proved to be the window's owner, which needs an ownership
 *     record the attacker cannot write.  Handing UP needs none of it:
 *     memfd_create is unprivileged, the client makes its own, and the only
 *     question left is who else may have it -- answered by the kernel, on the
 *     SENDER's side, with SO_PEERCRED against the segment's owner.  So the
 *     paragraph below is right that the decision unblocked the construction,
 *     and wrong that the construction needed tier 1.  Read the two together.
 *
 *     THAT DECISION HAS SINCE BEEN TAKEN, AND IT UNBLOCKS THIS.  owner_harden()
 *     further down calls PR_SET_DUMPABLE(0) from keychan_bind, so every window
 *     owner already has the property — measured against a REAL owner in
 *     wsys_bypass.sh's attack 5: mem=-13, enumerable=0, ptrace=-1.  The single
 *     objection that DISPROVED the recorded memfd design — "/proc/<pid>/fd/<n>
 *     IS a path" — no longer holds against a hardened owner.  So the memfd
 *     construction for the scene, the stage, the backbuffer and the images is
 *     viable again, and what it still needs is the part that was never about
 *     /proc: an AUTHORITY to create the memfd and hand it to exactly one
 *     process.  That is tier 1, which is a daemon, a new binary, a
 *     package-channel change and a segment at a new path; blockers (1)-(3)
 *     below are unchanged.
 *     DO NOT READ THAT AS "THE PIXELS ARE SAFE NOW".  The v1 DISPLAY LIST is
 *     out of the 0666 mapping and the v2 PIXELS are not.  `sameuid.snoop` now
 *     asserts the display list is absent (an INVERTED control, not a deleted
 *     one -- it still reads scene_len and the scene bytes at the same offsets),
 *     and `sameuid.bb` scrapes the v2 backbuffer store as a POSITIVE control on
 *     every green run, precisely so that nobody can come to believe otherwise
 *     about the half that is still open.
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
 * WHY TIER 1 IS STILL NOT BUILT, and how the keys ring got past all three of
 * these blockers without it.  Not the hot path — that turned out to be
 * affordable, and this comment used to say otherwise on no evidence.
 *
 * WHAT THE KEYSTROKE CHANNEL DID INSTEAD OF WAITING FOR TIER 1, because the
 * three blockers below are real and it went around every one of them rather
 * than through: it needs NO daemon (the owner binds its own address and the
 * only sender is the compositor that already writes the ring), NO new binary
 * (it is code in this file, which every wsys program already links), and NO
 * field removed from struct wwin (the ring stays as dead storage, so the layout
 * is byte-for-byte frozen).  What it does need is a version bump, for the one
 * reason a version counter exists: the layouts agree and the MEANING does not.
 *
 * AND IT IS NOT THE "TITLE-ONLY RPC" THE LAST PARAGRAPH BELOW RULES OUT, which
 * is worth being precise about because the shape looks similar.  That is unsound
 * because it authenticates against win[W].pid, a field in this 0666 table that
 * the attacker can rewrite.  NOTHING in the keystroke channel reads win[].pid:
 * the receiver is established by who holds the kernel's bind, and the sender by
 * the kernel's credential stamp.  The spoofable ownership record is not in the
 * path, so the check is worth what it claims to be worth.
 *
 * THE THREE BLOCKERS BELOW WERE ABOUT A DAEMON, AND ALL THREE WENT AROUND THE
 * SAME WAY THE KEYSTROKE CHANNEL DID -- twice now, which is worth reading as a
 * pattern rather than as two lucky escapes.  Each of them follows from the
 * authority OWNING the per-window memory and handing it DOWN.  Reversed, they
 * evaporate: (1) there is no attach rewrite, because the client still mmaps the
 * one named file and additionally makes a memfd of its own, so a gate with no
 * compositor alive runs exactly as it always did -- wsys_uidgate.sh and
 * wsys_bypass.sh both still drive a client with nothing else running; (2) there
 * is no new binary and no package-channel change, because the code is in this
 * file, which every wsys program already links; (3) no field is removed, because
 * the vacated bytes stay as dead storage and struct wwin is byte-for-byte
 * frozen, so there is no new path and no old binary memsetting a live table.
 * What is left of them is what genuinely still needs an authority: TIER 1
 * itself, which is INTEGRITY -- who may write a row -- and which no hand-up can
 * reach, because the thing being protected is the shared record and not a
 * client's private bytes.  The text below is the original and is kept for
 * that.
 *
 * The blockers that remain, for TIER 1 and for the rest of tier 2:
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
 * WHAT THE PASS THAT BUILT THE KEYSTROKE CHANNEL LEFT OPEN, said plainly so it
 * is not mistaken for the whole of tier 2: a same-uid attacker can still scrape
 * another window's committed scene and its backbuffer, still enumerate every
 * row, and still corrupt any of it (attacks 1 and 2 are untouched and their
 * controls still pass).  What it can no longer do is read what is TYPED into
 * another window, or put a keystroke into one.  That is one ring of five, and it
 * is the one that carries passwords.
 *
 * So the earlier pass landed the measurement and this design and did NOT
 * half-build the access control.  What IS closed, and by the kernel rather than by an if,
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

/* ================================================================== *
 * A LIVE SESSION IS NOT A LEFTOVER
 * ==================================================================
 *
 * WHAT THIS ANSWERS.  shm_attach used to treat "the segment on disk says a
 * version I do not know" as one situation with one remedy: clear it and carry
 * on.  There are two situations and they need opposite answers.
 *
 *   A LEFTOVER.  Nothing is running against it.  /srv is tmpfs and made fresh
 *   every boot, so on a real machine this is the first program after a boot
 *   meeting a segment some earlier program in the same boot left behind, or a
 *   test harness re-using an $HAMWSYS file.  Re-initialising is correct and
 *   MUST keep working -- "a fresh boot re-initialises a stale segment
 *   normally" is a property this pass is not allowed to break.
 *
 *   A LIVE SESSION.  A compositor is compositing, a panel is drawing, a person
 *   is typing into a terminal.  Re-initialising takes every one of those
 *   windows away from processes that are still running and cannot be told.
 *   That is the measured slab.
 *
 * HOW THEY ARE TOLD APART, and it is deliberately not "is wsysd running".
 * Asking after a process by NAME means /proc, a name that can be spoofed and a
 * daemon that might legitimately be called something else in a namespace.  The
 * question that actually matters is narrower and is answered by the segment
 * itself: DOES ANY ROW OF THIS WINDOW TABLE BELONG TO A PROCESS THAT IS STILL
 * ALIVE?  If yes, wiping the table hurts somebody; if no, there is nobody to
 * hurt.  A compositor with no windows is not a session worth protecting -- and
 * a compositor that has one has, by construction, a row here.
 *
 * READING A FOREIGN TABLE WITHOUT SHARING IT.  The rows are read with pread(2)
 * on the fd -- twelve bytes per row -- and the segment is never mapped, so
 * this is not the "silent half-share of a table two builds disagree about"
 * that the version counter exists to prevent.  Three bytes of layout are
 * relied on and all three are FROZEN and asserted below:
 *
 *   * struct wshm's prefix (magic .. inputgen) is byte-for-byte the same at
 *     v5, v6 and v7, so win[] starts at the same offset in all three;
 *   * struct wwin is byte-for-byte the same, so row i is at a computable
 *     offset and `used`, `wid` and `pid` are its first three words;
 *   * struct wsink is unchanged, so the row COUNT of a foreign segment can be
 *     recovered from its size alone:
 *
 *         rows = (size - sizeof(prefix) - WSYS_SINKS * sizeof(struct wsink))
 *                / sizeof(struct wwin)
 *
 *     and the division must come out EXACT.  A size that does not decompose
 *     this way is a layout this build has no business guessing at, so it is
 *     treated as not-live and the old behaviour (re-initialise) stands: this
 *     check may never turn an unrecognisable segment into a refusal that no
 *     reboot clears.  19,052,956 is 256 rows; 37,972,380 is 512.
 *
 * WHY kill(pid, 0) AND NOT /proc.  It is the same question with fewer moving
 * parts and it works inside a pid namespace where /proc may not be mounted.
 * EPERM counts as alive -- a process owned by another uid is still a process
 * with a window on the screen.  A recycled pid is the one false positive
 * available, and its cost is a refusal on a segment that could have been
 * cleared: the person reboots, which they were going to do anyway.  The
 * opposite error costs a desktop. */
/* THE FROZEN THREE, asserted rather than described.  seg_rows_in() recovers a
 * foreign segment's row count from its SIZE, which is only possible while
 * these three numbers are the same in the build that wrote it and the build
 * reading it.  They have been the same at v5, v6 and v7 and the comments above
 * say so in prose; here they say so to the compiler.  A pass that changes one
 * of them must come here, and must then decide what a live-session refusal
 * means for a segment whose rows it can no longer find -- the answer is not
 * "adjust the number", it is "sizes stop identifying versions, so put the row
 * count in the frozen prefix".  19,052,956 and 37,972,380 are v6 and v7 and
 * are the numbers tests/linux/installed_update_wsysver.sh reads off /srv. */
_Static_assert(offsetof(struct wshm, win) == 28,      "wshm prefix is frozen");
_Static_assert(sizeof(struct wwin)        == 73904,   "struct wwin is frozen");
_Static_assert(sizeof(struct wsink)       == 4172,    "struct wsink is frozen");
_Static_assert(offsetof(struct wshm, win) + 256 * sizeof(struct wwin)
               + WSYS_SINKS * sizeof(struct wsink) == 19052956u,
               "a v6 segment is 19,052,956 bytes");
_Static_assert(sizeof(struct wshm) == 37972380u,
               "a v7 segment is 37,972,380 bytes");

static int seg_force_reinit(void)
{
    /* THE ESCAPE HATCH, and it is an escape hatch and not a policy.  A gate
     * that deliberately drives an old segment under a live client needs to be
     * able to say so, and an operator whose session is wedged needs a way
     * through that is not "edit the source".  It is OFF unless set, and
     * nothing in the rc scripts sets it. */
    const char *v = getenv("HAMWSYS_FORCE_REINIT");
    return v && *v && *v != '0';
}

static int seg_rows_in(off_t size)
{
    off_t fixed = (off_t)offsetof(struct wshm, win)
                + (off_t)(WSYS_SINKS * sizeof(struct wsink));
    if (size <= fixed) return -1;
    off_t body = size - fixed;
    if (body % (off_t)sizeof(struct wwin)) return -1;
    off_t rows = body / (off_t)sizeof(struct wwin);
    if (rows <= 0 || rows > 65536) return -1;
    return (int)rows;
}

/* Defined further down, next to win_reap_dead(), which asks the same question
 * about the same pids.  Declared here because THIS is the earlier caller and
 * because it was the LAST kill(2)-only liveness test in this file. */
static int pid_liveness(pid_t pid);
static int liveness_kill_only(void);

/* A CORPSE OWNING A ROW USED TO STRAND THE WHOLE SEGMENT, AND IT WAS MEASURED
 * BEFORE IT WAS CHANGED.
 * ---------------------------------------------------------------------------
 * This runs at ATTACH, before the mapping, and its answer decides whether a
 * binary whose WSYS_VERSION differs from the segment's REFUSES to attach.  It
 * used to ask `kill(pid, 0) == 0 || errno == EPERM`, which is the same wrong
 * question win_reap_dead() was fixed for on 2026-08-17: kill(2) SUCCEEDS ON A
 * ZOMBIE, because a corpse still has a process table entry.
 *
 * It fails toward KEEPING the segment, which is the safe direction, so the
 * question was whether it costs anything.  MEASURED 2026-08-18 on this host
 * with tests/linux/wsys_zombie_strand.sh, whose three arms are:
 *   * a segment whose ONLY used row is owned by a process in state Z, header
 *     forced to version 7 against this binary's 8 -> the attach was REFUSED,
 *     rc 1, with the "it is a LIVE window-system session" message.  A desktop
 *     with nothing running on it told the user to reboot;
 *   * POSITIVE CONTROL: a RUNNING owner is refused too, so the refusal path
 *     works and the arm above is not measuring a broken harness;
 *   * NEGATIVE CONTROL: the same version mismatch with NO used row attaches
 *     cleanly (rc 0), so the refusal is about the owner and not the version.
 * So it did cost something, and it is now the /proc state test.
 *
 * IT STILL FAILS CLOSED, and in the same direction: only a POSITIVE reading of
 * death (state Z/X/x, or no /proc entry at all) lets a row be ignored.  1 and
 * -1 -- live, or cannot tell -- both keep the segment.  HAMWSYS_LIVENESS=kill
 * restores the exact predicate that was here, which is how the gate's red arm
 * shows this green one is attributable. */
static int shm_seg_is_live(int fd, off_t size)
{
    int rows = seg_rows_in(size);
    if (rows < 0) return 0;                    /* a shape we cannot read */
    for (int i = 0; i < rows; i++) {
        int32_t row[3] = { 0, 0, 0 };          /* used, wid, pid */
        off_t at = (off_t)offsetof(struct wshm, win)
                 + (off_t)i * (off_t)sizeof(struct wwin);
        if (pread(fd, row, sizeof row, at) != (ssize_t)sizeof row) return 0;
        if (!row[0] || row[2] <= 0) continue;
        if (liveness_kill_only()) {
            errno = 0;
            if (kill((pid_t)row[2], 0) == 0 || errno == EPERM) return 1;
        } else if (pid_liveness((pid_t)row[2]) != 0) {
            return 1;                          /* live, or cannot tell */
        }
    }
    return 0;
}

/* THE REFUSAL MARKER — how a person at the SCREEN gets told.
 * ---------------------------------------------------------
 * stderr is the serial console.  A person sitting in front of the desktop
 * never sees it, and the measured consequence (installed_update_wsysver.sh,
 * 7 -> 8, STAGE C) is that they click Applications, the panel logs the click,
 * the spawned program refuses correctly and dies, and NOTHING ON SCREEN SAYS
 * WHY.  A correct, safe refusal is indistinguishable from a broken button.
 *
 * The program that was refused cannot draw -- that is what being refused
 * means.  So it leaves a mark, and a process that DID attach before the
 * update (the panel) reads the mark and draws.  This is the single writer:
 *
 *   * It is inside seg_refuse_message, past the once-per-process guard, so
 *     the mark and the words have EXACTLY one condition between them.  There
 *     is no second caller and no other code in the tree that opens this path;
 *     a mark exists if and only if a real version refusal happened.  A notice
 *     that appears when nothing was refused would be worse than no notice, so
 *     the marker is deliberately not a general-purpose "something failed"
 *     channel -- $HOME/.hamde/appmenu.fault already is one, and it cannot
 *     tell a version refusal from a crash.
 *   * The path is DERIVED from the segment that refused (seg_path +
 *     ".refused"), the same way chrome_path is derived, so a harness pointed
 *     at another segment by $HAMWSYS marks that one and cannot leak a notice
 *     into somebody else's desktop.
 *   * It APPENDS.  The reader's serial is the file's size, which only ever
 *     grows, so "has there been a refusal I have not shown" is one fstat and
 *     an acknowledged byte offset -- the same shape as the DE launch queues.
 *     One short line per refusing process (the guard above bounds it).
 *   * It lives in /srv, which linuxinit mounts as tmpfs and which is made
 *     fresh every boot.  The notice's advice is REBOOT, so the evidence for
 *     the notice must not survive the reboot that fixes it.
 *
 *     WHAT IF /srv IS NOT TMPFS.  That sentence was the whole liveness
 *     argument and it rests on something this code does not control, so it
 *     was checked instead of trusted -- and it is REACHABLE, three ways:
 *
 *       1. linuxinit's `bind '#s' /srv` goes through bind_or_warn, which
 *          WARNS AND CONTINUES.  scripts/hamlinux_disk.sh creates a real /srv
 *          directory on the ext4 root, so a boot where that bind fails runs
 *          with /srv on the disk and every marker in it persists.
 *       2. The same on any of the other eight rc scripts that bind it.
 *       3. A host run as root with no $HAMWSYS: shm_path() returns /srv/wsys
 *          and on an ordinary Linux box /srv is a directory on the root
 *          filesystem.  (Unprivileged host runs fall through to /dev/shm,
 *          which is tmpfs, and are fine.)
 *
 *     In any of those the marker outlives the reboot it asks for, and the
 *     desktop tells a person to restart a session they have already
 *     restarted -- the exact shape of the appmenu.fault defect fixed above,
 *     where a flag outlived the reboot it asked for.
 *
 *     So the marker no longer depends on the filesystem forgetting: it
 *     carries the KERNEL'S BOOT ID (seg_boot_id above), and a reader ignores
 *     a marker stamped with any boot but the one it is running in.  The file
 *     may survive; the notice cannot.
 *   * O_CREAT comes SECOND, for the fs.protected_regular reason written out
 *     at length in shm_attach: /srv is 1777 and the marker may already belong
 *     to another uid.  Opening the existing file first means a client that
 *     cannot create it still gets to append to it.
 *   * It is entirely best-effort and errno-neutral.  The refusal is the
 *     safety property; the notice is cosmetic on top of it, and nothing about
 *     failing to write this file may change what the caller does. */
/* THE BOOT THIS PROCESS IS RUNNING IN, or "?" when it cannot be read.
 *
 * See WHAT IF /srv IS NOT TMPFS in seg_refuse_mark below: the marker's whole
 * liveness argument used to be "the filesystem forgets", and there are three
 * ways for it not to. The kernel hands out a fresh UUID at every boot and
 * nothing else has to cooperate, so the marker carries it and the reader can
 * tell a refusal that happened in THIS boot from one that outlived a restart.
 *
 * "?" is deliberately fail-OPEN: a machine with no /proc gets the behaviour it
 * had before this existed rather than a notice that can never appear. That
 * leaves the stale-marker case unfixed on such a machine, which is a trade
 * made on purpose -- /proc is bound by linuxinit before anything else runs,
 * and a notice that is silently impossible is worse than one that is
 * occasionally early. */
static void seg_boot_id(char *out, size_t cap)
{
    snprintf(out, cap, "?");
    int fd = open("/proc/sys/kernel/random/boot_id", O_RDONLY);
    if (fd < 0) return;
    char buf[64];
    ssize_t n = read(fd, buf, sizeof buf - 1);
    close(fd);
    if (n <= 0) return;
    buf[n] = '\0';
    for (char *q = buf; *q; q++)
        if (*q == '\n' || *q == '\r' || *q == ' ') { *q = '\0'; break; }
    if (buf[0]) snprintf(out, cap, "%s", buf);
}

/* APPEND ONE LINE TO <seg>.refused.  Split out of seg_refuse_mark so that the
 * CONNECTION refusal can be recorded in the same file, by the same rules, for
 * the same reader -- see srv_conn_refuse_note.  Two files would mean two
 * places to look for "the window system turned this process away", and the
 * panel's notice path only knows about one of them.
 *
 * The three properties the caller depends on are all here and none of them is
 * incidental: O_CREAT comes SECOND (/srv is 1777 and the marker may already
 * belong to another uid, so a client that cannot CREATE it still gets to
 * APPEND to it); the line carries the boot id, so a reader can tell a refusal
 * that happened in THIS boot from one that outlived a restart; and the whole
 * thing is best-effort and errno-neutral, because the refusal is the safety
 * property and the notice is cosmetic on top of it. */
static void seg_refuse_append(const char *path, const char *line)
{
    int saved = errno;
    char mpath[600];
    if (!path || !*path || !line || !*line) goto out;
    if (snprintf(mpath, sizeof mpath, "%s.refused", path) >= (int)sizeof mpath)
        goto out;
    int fd = open(mpath, O_WRONLY | O_APPEND);
    if (fd < 0)
        fd = open(mpath, O_WRONLY | O_APPEND | O_CREAT, 0666);
    if (fd < 0) goto out;
    if (fchmod(fd, 0666) < 0) { /* not the creator; mode already correct */ }
    ssize_t w = write(fd, line, strlen(line));
    (void)w;
    close(fd);
out:
    errno = saved;
}

static void seg_refuse_mark(const char *path, uint32_t theirs)
{
    int saved = errno;
    char line[256];
    char boot[64];
    seg_boot_id(boot, sizeof boot);
    int n = snprintf(line, sizeof line,
                     "refused live=%u mine=%u pid=%ld boot=%s\n",
                     (unsigned)theirs, (unsigned)WSYS_VERSION, (long)getpid(),
                     boot);
    if (n > 0 && n < (int)sizeof line) seg_refuse_append(path, line);
    errno = saved;
}

/* SAY IT, ONCE, BY NAME, ON STDERR.  A program that silently fails to draw is
 * the failure shape this tree keeps paying for, so the refusal is never left
 * to the caller's errno handling -- EPROTO out of an open(2) of a file under
 * /dev/wsys is not a sentence anybody can act on.  Once per process: a client
 * that retries the attach in a loop must not turn the explanation into a
 * scroll.
 *
 * ...and once on the SCREEN, via seg_refuse_mark above, because stderr here is
 * the serial console and the person is not reading it. */
/* WAS THIS PROCESS REFUSED FOR THE VERSION? Set by seg_refuse_message below
 * and by nothing else, so it is this process's own experience and not a
 * conclusion drawn from a file another process wrote.  hamwsys_was_refused()
 * is how a CLIENT tells "the window system turned me away because the session
 * is older than I am" from "I am broken" -- see user/hamappmenu.ad, where
 * writing the wrong one of those two into $HOME/.hamde/appmenu.fault cost the
 * Applications button permanently, across reboots. */
static int seg_refused_here;

int hamwsys_was_refused(void) { return seg_refused_here; }

static void seg_refuse_message(const char *path, uint32_t theirs)
{
    static int said;
    seg_refused_here = 1;
    if (said) return;
    said = 1;
    fprintf(stderr,
        "wsys: REFUSING to attach to %s: it is a LIVE window-system session of\n"
        "wsys:   version %u and this program is version %u.  Attaching would erase\n"
        "wsys:   every window on that desktop, so nothing has been changed.\n"
        "wsys: The window system was updated underneath the running session.\n"
        "wsys:   REBOOT (or restart the session) and start this program again.\n",
        path && *path ? path : "the window system segment",
        (unsigned)theirs, (unsigned)WSYS_VERSION);
    seg_refuse_mark(path, theirs);
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
     * uid separately, and THE UID GATE section below is that gate, ported.
     *
     * IT HAPPENS AFTER THE REFUSAL BELOW, not before it -- see NOTHING IS DONE
     * TO THE FILE BEFORE THE DECISION. */

    struct stat st;
    if (fstat(fd, &st) < 0) { int e = errno; close(fd); errno = e; return -1; }
    /* WHO THE HOST OWNER IS, decided once, from the kernel, at attach.  See
     * the UID GATE block below for why it is the segment's owner and not a
     * hardcoded 0. */
    seg_owner = st.st_uid;
    seg_owner_known = 1;
    /* THE SIZE BEFORE WE TOUCHED IT.  This is the whole of THE ZEROES WE DO
     * NOT WRITE below: every byte at or past it is a byte ftruncate(2) has
     * just promised reads as zero and that no page has been allocated for. */
    off_t old_size = st.st_size;
    /* THE SEGMENT'S IDENTITY, which names the keystroke channels below.  It is
     * the kernel's (dev, ino) and not the path, so two processes that reached
     * one segment by different names agree, and two harnesses with different
     * segments cannot collide in the abstract namespace they share. */
    seg_dev = st.st_dev;
    seg_ino = st.st_ino;
    seg_id_known = 1;
    /* Read the header BEFORE mapping, because the decision "does this segment
     * need re-initialising" now changes what we do to the FILE and not only to
     * the mapping. */
    uint32_t hdr[2] = { 0, 0 };
    int need_init = 1;
    if (old_size >= (off_t)sizeof hdr && pread(fd, hdr, sizeof hdr, 0) == (ssize_t)sizeof hdr)
        need_init = (hdr[0] != WSYS_MAGIC || hdr[1] != WSYS_VERSION);

    /* REFUSE, RATHER THAN WIPE A DESKTOP SOMEBODY IS SITTING IN FRONT OF.
     * ------------------------------------------------------------------
     * See A LIVE SESSION IS NOT A LEFTOVER above shm_seg_is_live().  Every
     * paragraph above this one describes re-initialising a foreign segment as
     * the LOUD, acceptable answer.  It was measured on a real installed
     * machine and it is neither: the windows go, the compositor keeps running
     * and repainting nothing, it still owns /dev/fb so the text console is not
     * behind it, and the person is left with a featureless slab whose only
     * remaining control is the power button.  Nothing had told them, and
     * nothing asks for the reboot that fixes it.
     *
     * So the re-initialise is now conditional on the segment being DEAD.  If a
     * process is still holding a window in it, this program declines to attach,
     * says so by name on stderr, and changes NOTHING -- not the header, not a
     * hole punched in the file, not one byte.  The running session survives
     * whole; the new program is the only thing that fails, which is the right
     * thing to lose. */
    if (need_init && old_size > 0 && hdr[0] == WSYS_MAGIC
        && hdr[1] != WSYS_VERSION && !seg_force_reinit()
        && shm_seg_is_live(fd, old_size)) {
        seg_refuse_message(seg_path, hdr[1]);
        close(fd);
        seg_owner_known = 0;
        seg_id_known = 0;
        seg_path[0] = '\0';
        errno = EPROTO;
        return -1;
    }

    /* NOTHING IS DONE TO THE FILE BEFORE THE DECISION, and this ordering was
     * WRONG in the first version of this pass -- caught by the gate, in the one
     * number the gate exists to read.
     *
     * The chmod and this ftruncate used to sit above the header read, where
     * they had always been.  So a v7 binary meeting a live v6 session GREW THE
     * FILE from 19,052,956 to 37,972,380 bytes and only then refused.  The
     * desktop survived -- the header and every row were untouched, the screen
     * was pixel-identical, the four windows were still there -- and
     * installed_update_wsysver.sh still said FAIL, because the size of /srv/wsys
     * is how that gate knows WHICH WINDOW SYSTEM A SESSION IS, and a refusal
     * that resizes the segment has destroyed exactly that.  It also made the
     * refusal's own words false: "nothing has been changed" was not true of the
     * file.  Two costs, one cause, and the fix is an ordering. */
    if (fchmod(fd, 0666) < 0) { /* not the creator; mode already correct */ }
    if (old_size < (off_t)sizeof(struct wshm)) {
        if (ftruncate(fd, (off_t)sizeof(struct wshm)) < 0) {
            int e = errno; close(fd); errno = e; return -1;
        }
    }
    /* THE ZEROES WE DO NOT WRITE — see WSYS_MAX_WINDOWS above for the number
     * this buys.  A re-init used to be `memset(shm, 0, sizeof *shm)`, and on a
     * FRESH segment every one of those bytes was already zero: the memset's
     * only effect was to fault in and dirty all 4,650 (now 9,299) pages of a
     * table nobody had a window in yet.  Now:
     *   - a segment we just created (old_size 0) needs no clearing at all;
     *   - a segment that pre-existed and disagrees is cleared by PUNCHING A
     *     HOLE, which both zeroes it and gives the pages back — strictly more
     *     than memset did, since memset leaves them allocated;
     *   - and only if the kernel will not punch (not tmpfs) do we fall back to
     *     writing zeros, and then only over the bytes that actually existed
     *     before our ftruncate, because the rest are already zero by POSIX.
     * The mismatch case is rare by construction: /srv is tmpfs and made fresh
     * every boot, so meeting a foreign segment means two builds in one
     * session. */
    int cleared = 0;
    if (need_init && old_size > 0) {
        if (fallocate(fd, FALLOC_FL_PUNCH_HOLE | FALLOC_FL_KEEP_SIZE,
                      0, (off_t)sizeof(struct wshm)) == 0)
            cleared = 1;
    } else if (need_init) {
        cleared = 1;                           /* ftruncate already zeroed it */
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
        if (!cleared)
            memset(shm, 0, old_size > (off_t)sizeof(struct wshm)
                           ? sizeof(struct wshm) : (size_t)old_size);
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

/* A SUCCESSFUL SYSCALL IS A FACT ABOUT THE KERNEL'S BOOKKEEPING, NOT ABOUT
 * THE WORLD.  kill(pid, 0) SUCCEEDS ON A ZOMBIE.
 *
 * This is the correction to the long note below, which says "kill(pid, 0) is
 * the question" and was wrong about which question it is.  `kill(pid, 0)`
 * answers "is there a process table entry I am permitted to signal".  A
 * corpse -- a process that has exited and whose parent has not yet wait4'd it
 * -- still HAS that entry, so it answers alive, and the previous reaper could
 * not see a dead window's owner as dead.  Measured on this tree: a 900 s soak
 * ended with 3 live application processes, 86 zombies, and 92 windows still
 * listed.  The reaper was called every frame and reclaimed none of them.
 *
 * The state column of /proc/<pid>/stat is the fact about the world.  `Z` is a
 * corpse; `X`/`x` is a task in the middle of being torn down.  Everything else
 * (R, S, D, T, t, I, ...) is a program that exists.
 *
 * PARSING IT CORRECTLY MATTERS AND IS NOT OBVIOUS.  field 2 is the executable
 * name IN PARENTHESES and it may contain spaces AND parentheses -- `(a) b (c)`
 * is a legal comm.  Splitting on whitespace, or on the FIRST ')', misreads
 * such a process; the only safe scan is to the LAST ')' in the buffer, which
 * is what strrchr does here.  A program named ")" is enough to break the naive
 * version, and this reaper's failure mode is destroying a live application's
 * window.
 *
 * IT FAILS CLOSED, in the same direction the old test did and for the same
 * reason: the ONLY answer that reclaims a window is a positive reading of
 * death.  /proc not mounted, /proc not the host's, an unreadable stat, a
 * malformed line, a permission error -- every one of those returns UNKNOWN and
 * the window is KEPT.  A stale rectangle is cosmetic; tearing down a running
 * program's window is not.
 *
 * Returns 1 = live, 0 = a corpse or gone, -1 = cannot tell. */
static int pid_liveness(pid_t pid)
{
    if (pid <= 0) return -1;

    char path[64];
    snprintf(path, sizeof path, "/proc/%ld/stat", (long)pid);
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        /* ENOENT here is the strongest statement /proc can make: the kernel
         * has no such task at all, not even a corpse.  Anything else (ENOSYS,
         * EACCES, ENOTDIR when /proc is not mounted) is ignorance, and
         * ignorance falls through to the old kill(2) probe below rather than
         * to a verdict. */
        if (errno == ENOENT) return 0;
    } else {
        char buf[512];
        ssize_t n = read(fd, buf, sizeof buf - 1);
        int e = errno;
        close(fd);
        if (n > 0) {
            buf[n] = '\0';
            /* LAST ')' -- see the note above about comm. */
            char *rp = strrchr(buf, ')');
            if (rp && rp[1] == ' ' && rp[2]) {
                char st = rp[2];
                if (st == 'Z' || st == 'X' || st == 'x') return 0;
                return 1;
            }
            /* Malformed: say nothing. */
        } else if (n == 0) {
            /* An empty stat is not a corpse, it is a read that told us
             * nothing.  (void)e keeps the compiler quiet about the errno
             * capture, which is here for anyone adding a trace. */
            (void)e;
        }
        return -1;
    }

    /* /proc could not answer.  Fall back to the old probe, which is still
     * right about one thing: ESRCH means there is no such pid.  It cannot
     * distinguish a corpse from a program, so its "alive" is UNKNOWN, not
     * live -- and unknown keeps the window either way. */
    errno = 0;
    if (kill(pid, 0) < 0 && errno == ESRCH) return 0;
    return -1;
}

/* Set by HAMWSYS_LIVENESS=kill.  IT EXISTS FOR ONE REASON: the negative
 * control of tests/linux/wsys_zombie_owner.sh, which must be able to show the
 * gate going red against the exact code that was here before.  An assertion
 * that cannot fail is not an assertion, and the only honest way to show this
 * one can fail is to run the broken reaper under it.  Nothing in the tree sets
 * this variable; the default is the /proc test. */
static int liveness_kill_only(void)
{
    static int v = -1;
    if (v < 0) {
        const char *s = getenv("HAMWSYS_LIVENESS");
        v = (s && !strcmp(s, "kill")) ? 1 : 0;
    }
    return v;
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
 * the liveness has to be asked for.  It used to be asked with kill(pid, 0),
 * which is the WRONG QUESTION -- see pid_liveness() directly above, and the
 * 86 corpses that answered it "alive".
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

    /* THE SWEEP IS THROTTLED, AND THE OLD ONE DID NOT NEED TO BE.
     *
     * kill(pid, 0) was one syscall per window; reading /proc/<pid>/stat is an
     * open, a read and a close.  This function is called from EVERY read of
     * the /dev/wsys directory, which is what the compositor walks every frame,
     * so at 92 windows and 60 fps the difference is ~16k extra syscalls a
     * second inside the frame loop -- on a TCG guest that is not a rounding
     * error, and this tree has already shipped one desktop that looked frozen.
     *
     * A dead window reclaimed 200 ms late is invisible; the reclaim exists so
     * a rectangle does not stay on screen FOR EVER.  So the sweep runs at most
     * five times a second per process.
     *
     * The state is per-process and starts at zero, so the FIRST call in any
     * process always sweeps -- which is what makes a one-shot reader like
     * `cat` still correct, and it is why tests/linux/wsys_zombie_owner.sh
     * measures what it thinks it measures. */
    {
        static int64_t last_ms;
        struct timespec ts;
        if (clock_gettime(CLOCK_MONOTONIC, &ts) == 0) {
            int64_t now = (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
            if (last_ms != 0 && now - last_ms < 200) return;
            last_ms = now;
        }
    }

    for (int i = 0; i < WSYS_MAX_WINDOWS; i++) {
        struct wwin *v = &shm->win[i];
        if (!v->used || v->pid <= 0) continue;
        if (liveness_kill_only()) {
            errno = 0;
            if (kill((pid_t)v->pid, 0) == 0 || errno != ESRCH) continue;
        } else {
            /* Reclaim ONLY on a positive reading of death.  1 (live) and -1
             * (cannot tell) both keep the window. */
            if (pid_liveness((pid_t)v->pid) != 0) continue;
        }
        keychan_unbind(v->wid);
        pix_release(v->wid);
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

/* wctl's focus policy, 0 = click (the DE-wide default), 1 = sloppy.  Read
 * through a helper so the one place that knows which word carries it is the
 * declaration in struct wwin, not every caller. */
static int win_focus_sloppy(const struct wwin *v)
{
    return v && v->focus_mode == 1;
}

/* THE RACE THAT ROUTING RETIRES — AND WHY THE ATOMICS BELOW MUST STAY.
 *
 * From stage 2 of docs/wsys_server_design.md, `newwindow` is routed: the
 * client asks wsysd, wsysd calls this, and one process allocates every row.
 * A single allocator makes the race below STRUCTURALLY IMPOSSIBLE rather than
 * merely fixed -- there is no second claimant to lose to.
 *
 * IT DOES NOT MAKE THE COMPARE-EXCHANGE REDUNDANT, and the order of events is
 * the reason.  Do not remove it.
 *
 *   * The routing is behind HAMWSYS_SERVER=1.  With the flag unset -- which
 *     is every shipped binary today, and every binary until stage 4 lands --
 *     this is still called concurrently by every GUI program on the machine.
 *   * Even after stage 4, hamwsys_alloc() reaches this from hamUI when it
 *     stamps a wid against a spawned child's pid, in the DE's process and not
 *     in wsysd's.
 *   * A shipped 1.0.22 client mmaps this segment and allocates out of it with
 *     no idea a server exists.  That is precisely why the WSYS_VERSION bump
 *     is the enforcement and goes last; until it lands, an old client is a
 *     second allocator by definition.
 *
 * So routing removes the race for CLIENTS THAT ROUTE, and the interlock is
 * what covers everybody else.  Measured before it existed: 10 failures in 10
 * runs with two contending clients, 0 in 10 after.
 */
static struct wwin *win_alloc(int32_t pid)
{
    if (shm_attach() < 0) return NULL;
    for (int i = 0; i < WSYS_MAX_WINDOWS; i++) {
        struct wwin *v = &shm->win[i];
        /* CLAIM THE ROW ATOMICALLY, AND TAKE THE wid ATOMICALLY, because this
         * table is SHARED MEMORY and every GUI program on the machine allocates
         * out of it.  This loop used to read `used`, then memset the row, then
         * write `used = 1` and `wid = next_wid++` -- three separate steps with
         * no interlock at all.  Two clients calling `newwindow` at the same
         * moment both saw the same row free, both took it, and the one that
         * wrote first had its row overwritten by the one that wrote second.
         *
         * WHAT THAT LOOKED LIKE, and it cost two agents a day between them: the
         * losing client held a wid whose row now belonged to somebody else, so
         * win_find() failed and EVERY leaf of its window -- ctl, scene, keys,
         * draw/ctl, all of them -- answered ENOENT, with `ctl` reading empty.
         * It was first characterised as "a v2 window opened after another v2
         * window is sometimes never painted", because the paint is simply the
         * first thing anyone notices; the errno was the tell, and it pointed at
         * the row rather than at the pixels.  It also made an unrelated
         * experiment report -2 where the mechanism said -1, which is a defect
         * that makes OTHER measurements lie.
         *
         * MEASURED: with two clients and the compositor pinned to one core so
         * they genuinely contend, 10 failures in 10 runs before, 0 in 10 after.
         * Unpinned on an idle host it is roughly 1 in 4 -- which is exactly the
         * rate that gets a gate re-run instead of read.
         *
         * `used` is the first word of the row, so the compare-exchange that
         * wins it also fences the memset of everything after it: a scanner that
         * loses the race sees used == 1 and moves on rather than clearing a
         * row somebody else is filling in. */
        uint32_t free_row = 0;
        if (!__atomic_compare_exchange_n(&v->used, &free_row, 1u, 0,
                                         __ATOMIC_ACQ_REL, __ATOMIC_RELAXED))
            continue;                          /* somebody else won this row */
        memset((char *)v + sizeof v->used, 0, sizeof(*v) - sizeof v->used);
        v->wid      = __atomic_fetch_add(&shm->next_wid, 1, __ATOMIC_ACQ_REL);
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

/* ==================================================================
 * WHO IS ASKING — and it stops being "us" the moment there is a server
 * ==================================================================
 * hostowner() and owns_wid() below are devwsys's two permission questions,
 * and until stage 2 of docs/wsys_server_design.md they could only ever be
 * asked about THIS process, because the code asking them was linked into the
 * process being asked about.  That is the whole defect the file server exists
 * to fix: there was no mediator, so there was nowhere a policy could live.
 *
 * When wsysd executes a routed operation it is acting FOR SOMEBODY ELSE, and
 * geteuid()/getpid() would answer about wsysd.  wsysd runs as the host owner,
 * so every check would return "yes" and the mediator would be a rubber stamp
 * that grants more than the in-process path did -- a boundary that makes
 * things WORSE, silently, while every gate passes.
 *
 * So a routed operation runs with the CALLER installed here, taken from
 * SO_PEERCRED at accept: the one fact about a client that the client cannot
 * forge.  It is a plain global rather than a parameter because these two
 * predicates are reached from about thirty verb sites through ctl_global and
 * ctl_window, and threading an identity through all of them would be thirty
 * chances to miss one -- and a missed one is a check that silently answers
 * about the server.  srv_as_caller()/srv_as_self() bracket exactly one
 * dispatch, and the server is single-threaded, so the window it is set in is
 * one message long.
 */
/* STAGE 5 ADDS TWO FIELDS, AND THEY ARE WHAT MAKES THE CAPABILITY NARROWER
 * THAN DESCENT.  `cid` names the CONNECTION the operation arrived on -- the
 * thing a process can only obtain by dialling the server itself or by being
 * handed the descriptor -- and `adopted` records that this connection was
 * inherited rather than dialled, which costs it hostowner() (see
 * WHY AN ADOPTED CONNECTION IS NOT THE HOST OWNER, at srv_dispatch's HELLO). */
static struct {
    int      active;
    uid_t    uid;
    pid_t    pid;
    uint64_t cid;
    int      adopted;
} srv_caller;

static void srv_as_caller_full(uid_t uid, pid_t pid, uint64_t cid, int adopted)
{
    srv_caller.active = 1; srv_caller.uid = uid; srv_caller.pid = pid;
    srv_caller.cid = cid; srv_caller.adopted = adopted;
}
static void srv_as_caller(uid_t uid, pid_t pid)
{ srv_as_caller_full(uid, pid, 0, 0); }
static void srv_as_self(void)
{ srv_caller.active = 0; srv_caller.cid = 0; srv_caller.adopted = 0; }

static int hostowner(void)
{
    /* AN ADOPTED CONNECTION CANNOT BE THE HOST OWNER, and that is a deliberate
     * one-way loss.  SO_PEERCRED is fixed at connect(2), so a descriptor handed
     * down from a host-owner process carries the HOST OWNER's uid however far
     * it travels -- and without this line a toolkit that dialled before
     * dropping privilege would hand every spawned application the chrome verbs
     * the whole uid gate exists to withhold.  A client can only ever declare
     * itself adopted, never un-declare it, so the flag can lose privilege and
     * cannot gain any. */
    if (srv_caller.active && srv_caller.adopted) return 0;
    uid_t me = srv_caller.active ? srv_caller.uid : geteuid();
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

/* Does the connection this operation arrived on hold window `wid`?  Defined
 * with the server, below; declared here because owns_wid() is the one place
 * the question is asked.  Returns 0 for an unrouted caller. */
static int srv_caller_holds_wid(int wid);

/* devwsys's _wsys_caller_owns_wid: does the caller's parent-pid chain reach
 * the wid's stamped owner?  Depth-bounded exactly as devwsys bounds it.
 *
 * THIS IS THE UNROUTED RULE AND IT IS UNCHANGED.  It is also still the rule the
 * ENUMERATION policy asks (srd_enum_tier), because "do you own a window" is a
 * question about a process and not about a descriptor, and stage 4's 9/0 gate
 * is written against exactly that.  What stage 5 changes is the rule for a
 * routed MUTATION -- see owns_wid() immediately below. */
/* THE WALK DOES NOT STOP EARLY, AND STAGE 10b HAD TO MEASURE THAT TO BELIEVE
 * IT MATTERED.  This function used to `return 0` the instant win_find() came
 * back NULL, and `return 1` the instant the chain reached the owner.  Both
 * early exits are a TIMING CHANNEL the moment this predicate becomes a SERVED
 * answer, because then the caller can time it:
 *
 *   MEASURED, uid 1002 owning nothing, 200 routed write opens per arm, three
 *   repetitions, on the tree before this change --
 *       live wid:  93, 96, 118 us per refused open
 *       dead wid:  47, 46,  44 us per refused open
 *   -- a 2x separation, from a path whose errno and exit code are byte for
 *   byte identical.  THE EXISTENCE OF THE WINDOW WAS READABLE WITH A
 *   STOPWATCH.  The cost is proc_ppid(): a live wid makes the walk run and
 *   read up to eight /proc/<pid>/stat files, and a dead wid made it run zero
 *   times.
 *
 * THIS IS NOT NEW TO THE WRITE OPEN.  Stage 10 routed nine READ opens onto
 * exactly this predicate (WSRV_LEAF_EXISTS), so the same stopwatch worked on
 * `cat /dev/wsys/<wid>/scene` from the day that landed.  The comment at the
 * server's existence arm -- "a refused caller never reaches win_find()" -- is
 * true of that arm and MISLEADING, because the permission question it asks
 * first calls win_find() ITSELF, right here, and then decides whether to do
 * any work based on the answer.
 *
 * SO THE WALK IS UNCONDITIONAL AND ITS LENGTH DEPENDS ON THE CALLER ONLY.  It
 * runs to the bound or to the top of the caller's own process chain whichever
 * comes first, and records a hit rather than returning on one; a missing
 * window is simply an owner pid nothing can match.  What a caller can now time
 * is the depth of ITS OWN ancestry, which it already knows.
 *
 * THE PRICE, said plainly: a GRANT that used to stop at depth 0 or 1 now walks
 * the whole chain.  That is at most eight /proc/<pid>/stat reads, once per
 * (process, window) for the life of the process -- the existence answer is
 * cached by the client -- and it is paid to remove a channel that no errno
 * change can close. */
static int owns_wid_ancestry(int wid)
{
    struct wwin *v = win_find(wid);
    int32_t owner = (v && v->pid != 0) ? v->pid : 0;
    /* The ppid walk starts at the CALLER, not at us.  Started at wsysd it
     * would answer "does wsysd's ancestry reach this window's owner", which
     * for a DE-spawned client is often YES -- wsysd is frequently the
     * ancestor of the very programs it would be mediating.  That is not a
     * near miss; it is a check that grants everything. */
    pid_t p = srv_caller.active ? srv_caller.pid : getpid();
    int hit = 0;
    for (int depth = 0; depth < 8; depth++) {
        /* `owner` is 0 for a window that does not exist or was never stamped,
         * and a pid is never 0 here (p comes from getpid() or SO_PEERCRED and
         * the walk stops at q <= 0), so an absent window matches nothing
         * without the comparison having to know that. */
        if (owner != 0 && (int32_t)p == owner) hit = 1;
        pid_t q = proc_ppid(p);
        if (q <= 0 || q == p) break;
        p = q;
    }
    return hit;
}

/* ==================================================================
 * STAGE 5 — THE CONNECTION IS THE CAPABILITY
 * ==================================================================
 * WHAT WAS WRONG, MEASURED BY STAGE 3a AND PRICED BY STAGE 4: the walk above
 * compares pids and NEVER LOOKS AT A uid, so a uid-1002 child of a uid-0
 * window owner drove that window (owns_wid=1, write accepted).  Every
 * application the desktop spawns is a descendant of the desktop, so every
 * application could retitle, move, raise or destroy any window owned by the
 * compositor, the panel, or any of its own ancestors, regardless of uid.
 *
 * NARROWING THE WALK IS OFF THE TABLE and two stages said so: hamUI spawns a
 * task INTO a window and stamps the parent's pid, so an exact-pid match would
 * leave every toolkit-spawned task unable to drive the window it was spawned
 * into.  /etc/rc.de-user makes that concrete -- every DE window is
 * `/bin/hamsh /etc/rc.de-user <prog>`, the wid is stamped against hamsh, and
 * the program that draws is hamsh's CHILD.
 *
 * SO THE WALK IS NOT NARROWED; IT STOPS BEING THE ONLY QUESTION ASKED.  For a
 * ROUTED mutation the question becomes "did this arrive on the connection that
 * holds the row", and a descendant inherits the right to drive the window it
 * was spawned into only when the spawner HANDS IT THE DESCRIPTOR -- which is
 * exactly the moment the spawner means to.  A descriptor cannot be walked to;
 * it has to be given.
 *
 * A row is held by a connection in one of two ways, and both are facts the
 * kernel supplies rather than claims a client makes:
 *
 *   1. `newwindow` arrives on a connection and returns the wid: the allocating
 *      connection holds it from birth.
 *   2. The DE's on-behalf path (`alloc <pid>`, hamUId) stamps a row against a
 *      pid before that process has connected at all, so there is no connection
 *      to record.  That row is CLAIMED by the first connection whose
 *      SO_PEERCRED pid is exactly the stamped pid.  A handed-down descriptor
 *      still carries the pid of the process that dialled, so the toolkit
 *      claims and the child it handed to inherits the claim -- one connection,
 *      one holder, no walk.
 *
 * THE BINDING IS SERVER-PRIVATE AND NOT IN THE SEGMENT, which is what lets
 * this land with WSYS_VERSION still 8: struct wshm and struct wwin are
 * byte-for-byte unchanged, so no client's mapping moves.
 *
 * A ROW IS REUSED, so a binding names the row's identity as well as its
 * holder: a stale binding whose wid or stamped pid no longer matches the row
 * in front of it is not a holder, it is a dead entry, and the row is free to
 * be claimed again.  Without that, wid reuse would hand a new window to the
 * connection that held the old one.
 */
struct srv_own { int32_t wid; int32_t pid; uint64_t cid; };
static struct srv_own srv_own_tab[WSYS_MAX_WINDOWS];
static uint64_t srv_n_claim, srv_n_connrefuse;

/* CONNECTIONS TURNED AWAY AT WSRV_CONN_MAX, and it is NOT srv_n_connrefuse
 * above however alike the two names read.  srv_n_connrefuse is stage 5's
 * count of MUTATIONS that ancestry would have allowed and a descriptor did
 * not -- a decision about a message on a connection that exists.  This is the
 * count of clients that never got a connection at all, and until it existed
 * the server recorded NOTHING about the one condition it alone can see:
 * tests/linux/wsys_srv_ceiling.sh drove six refusals past the ceiling and
 * read `connrefused 0` out of the STAT block afterwards, because that field
 * was answering a different question.  Kept separate for both sockets,
 * because their ceilings are separate. */
static uint64_t srv_n_capref, srd_n_capref;

/* SAY IT ONCE PER SERVER, NOT ONCE PER REFUSAL.  A desktop that has run out
 * of connections has a client retrying, and a line per attempt would turn the
 * one diagnosis anybody needs into a scroll that hides it.  The COUNTER keeps
 * the full total; this is the sentence that tells a reader where to look. */
static void srv_cap_refused(const char *sockname, uint64_t n)
{
    if (n != 1) return;
    fprintf(stderr, "wsys: the connection limit is reached on '%s' "
                    "(WSRV_CONN_MAX=%d): refusing a client. Every further "
                    "client on this socket falls back to the UNMEDIATED "
                    "in-process path; the running total is `capref` in the "
                    "STAT block.\n",
            sockname, (int)WSRV_CONN_MAX);
}

/* The row's binding slot, or NULL.  Keyed by ROW INDEX and not by wid: a wid
 * is a monotonically increasing integer with no bound, a row index is one of
 * WSYS_MAX_WINDOWS. */
static struct srv_own *srv_own_of(struct wwin *v)
{
    if (!shm || !v) return NULL;
    size_t i = (size_t)(v - shm->win);
    if (i >= WSYS_MAX_WINDOWS) return NULL;
    return &srv_own_tab[i];
}

static int srv_own_live(const struct srv_own *o, const struct wwin *v)
{ return o->cid != 0 && o->wid == v->wid && o->pid == v->pid; }

/* Record `cid` as the holder of the row.  Called at a routed `newwindow` (the
 * allocating connection) and on a claim. */
static void srv_own_bind(struct wwin *v, uint64_t cid)
{
    struct srv_own *o = srv_own_of(v);
    if (!o) return;
    o->wid = v->wid; o->pid = v->pid; o->cid = cid;
}

static int srv_caller_holds_wid(int wid)
{
    if (!srv_caller.active || !srv_caller.cid) return 0;
    struct wwin *v = win_find(wid);
    if (!v) return 0;
    struct srv_own *o = srv_own_of(v);
    if (!o) return 0;
    if (srv_own_live(o, v)) return o->cid == srv_caller.cid;
    /* Unheld (or held by a dead entry from a previous tenant of this row).
     * THE CLAIM IS AN EXACT PID MATCH AND NOTHING ELSE -- no walk, no uid
     * comparison, no name.  This is the on-behalf path's only way in. */
    if (v->pid != 0 && (pid_t)v->pid == srv_caller.pid) {
        srv_own_bind(v, srv_caller.cid);
        srv_n_claim++;
        return 1;
    }
    return 0;
}

/* THE ONE QUESTION, ASKED IN TWO WORLDS.
 *
 * Unrouted -- the in-process path, every shipped binary today -- this is the
 * ppid walk, byte-for-byte the behaviour of every stage before this one.  The
 * mediator inherits the rule when the server is off, and that is what keeps
 * the red arm of every identity gate meaningful.
 *
 * Routed, it is the connection.  Note what is NOT here: a fallback to the walk
 * when the connection does not hold the row.  A capability that can be reached
 * by descent as well as by handoff is the old capability with extra steps. */
static int owns_wid(int wid)
{
    if (srv_caller.active) return srv_caller_holds_wid(wid);
    return owns_wid_ancestry(wid);
}

static int deny(void)
{
    errno = EPERM;
    return -1;
}

/* ==================================================================
 * THE FOUR RINGS THAT HAD NO OWNER CHECK AT ALL
 * ==================================================================
 * MEASURED, NOT SUSPECTED: with the mediator live and the read server forked,
 * an attacker at uid 1002 owning no window opened /dev/wsys/<victim>/event and
 * was handed the compositor's own `geometry 100 100 300 200` out of another
 * uid's queue.  ring_read() asked nothing of anybody on pointer / event / text
 * / cmd, and hamwsys_open's WIN_* arm fell through to `win_find` and a bare
 * `return 0`.  `keys` was the only ring with a check, and only because it is
 * no longer in the shared segment at all -- so the one ring that was moved got
 * a gate and the four that stayed behind did not.
 *
 * WHAT THESE RINGS CARRY, which is why this is confidentiality and not tidiness:
 * `event` is the compositor's narration of the window -- geometry, focus in/out,
 * close requests; `pointer` is every cursor position and button state over that
 * window; `text` is committed text input; `cmd` is the /dev/cons routing channel
 * (see user/hamUI.ad:19).  Reading another window's `pointer` is following the
 * user's mouse across somebody else's application, and reading its `text` is a
 * keylogger by the back door of the one channel the keystroke split did not move.
 *
 * THE PREDICATE IS `hostowner() || owns_wid(wid)`, AND IT IS DELIBERATELY THE
 * ONE ALREADY IN THIS FILE.  It is byte-for-byte the gate hamwsys_open applies
 * to WRITING these same four rings (the for_write arm above), the gate on
 * <wid>/wctl, and the gate quoted at <wid>/draw/ctl.  Two facts make it the
 * right one here rather than a new mechanism:
 *
 *   - IT ADMITS THE COMPOSITOR, which is not optional.  wsysd writes every one
 *     of these rings for windows it does not own -- route_pointer_event and
 *     route_focus_event in user/wsysd.ad open /dev/wsys/<wid>/event and
 *     /dev/wsys/<wid>/pointer for any focused wid -- and it passes the write
 *     gate today as the HOST OWNER, because /dev/wsys is the file /srv/wsys and
 *     wsysd created it.  A read gate built on the same predicate admits it by
 *     exactly the same fact, and no second notion of "privileged" is invented.
 *   - IT REFUSES AN UNRELATED uid, because hostowner() is `me == seg_owner` and
 *     owns_wid() bottoms out in a parent-pid walk that a process spawned outside
 *     the victim's descent cannot satisfy.
 *
 * AND `owns_wid()` STILL NEVER COMPARES A uid -- READ THIS BEFORE TRUSTING IT.
 * That is a real gap and it is NOT closed here.  A uid-1002 DESCENDANT of the
 * window's owner still passes, exactly as stage 5 records at THE CONNECTION IS
 * THE CAPABILITY, and on a real desktop every application is a descendant of
 * the compositor.  It is not closed here for a reason that is structural rather
 * than an omission: struct wwin records `int32_t pid` and NO uid at all, and
 * the struct is byte-for-byte what versions 6 and 7 had -- adding an owner uid
 * to it changes sizeof(struct wwin) and costs a WSYS_VERSION bump, which THE
 * SPLIT records as the thing this file cannot survive.  So the uid the window
 * belongs to is not a fact this code has; the only identity in the row is a pid.
 * Narrowing the walk instead is off the table for the reason stage 5 gives:
 * /etc/rc.de-user makes every DE window `/bin/hamsh /etc/rc.de-user <prog>` and
 * stamps the wid against hamsh, so an exact-pid match would leave every
 * toolkit-spawned task unable to read the rings of the window it draws into.
 *
 * AND THIS CHECK IS ADVISORY, WHICH IS THE HONEST WORD FOR IT.  Every client
 * maps the segment directly -- tests/linux/wsys_bypass.sh drives a program that
 * does exactly that and asserts it SUCCEEDS -- so an attacker that skips the
 * protocol reads these rings out of the mapping and no `if` written in this file
 * is in its way.  Nor are these four leaves routed: srv_route_read carries
 * SCREEN, POOL and WINDOWS and nothing else, so there is no server-side copy of
 * this question to ask.  What this binds is a client that goes through the file
 * protocol, which is every program in this tree -- the same scope, and the same
 * limit, that WHAT THIS GATE IS AND IS NOT states for the uid gate above. */
static int ring_leaf_is_owned(int leaf)
{
    return leaf == HAMWSYS_WIN_POINTER || leaf == HAMWSYS_WIN_EVENT
        || leaf == HAMWSYS_WIN_TEXT    || leaf == HAMWSYS_WIN_CMD;
}

static const char *ring_leaf_word(int leaf)
{
    return leaf == HAMWSYS_WIN_POINTER ? "pointer"
         : leaf == HAMWSYS_WIN_EVENT   ? "event"
         : leaf == HAMWSYS_WIN_TEXT    ? "text" : "cmd";
}

/* 1 to serve the read, 0 to refuse it with EPERM already set.  REFUSED BY NAME,
 * for the reason the keys refusal is: a read that succeeded and returned zero
 * bytes would say "nothing has happened in this window" to a caller with no way
 * to tell that apart from the truth, and that is this tree's own worst bug
 * shape -- a surface that lies rather than one that errors. */
static int ring_read_allowed(int wid, int leaf)
{
    if (!ring_leaf_is_owned(leaf)) return 1;
    if (hostowner() || owns_wid(wid)) return 1;
    fprintf(stderr,
            "wsys: /dev/wsys/%d/%s: this process does not own window %d, so it "
            "cannot read its %s ring.\n",
            wid, ring_leaf_word(leaf), wid, ring_leaf_word(leaf));
    errno = EPERM;
    return 0;
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

/* THE PIXEL HAND-UP'S HEARTBEAT.  See linux-wsys.h for why the PARK is where
 * this has to be called from, and pix_tick below for what it does. */
void hamwsys_tick(void) { pix_tick(); bbup_tick(); }

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
    /* The keystroke channel is a socket, not a ring: readiness is the kernel's
     * answer about a pending datagram.  The PARK itself is unchanged -- the
     * sender still bumps `inputgen` and FUTEX_WAKEs, so sys_waitfds sleeps and
     * wakes exactly as it did and needs to know nothing about this. */
    if (f->leaf == HAMWSYS_WIN_KEYS) return keychan_ready(f->wid);
    struct wwin *v = win_find(f->wid);
    if (!v) return 0;
    const struct wring *q = f->leaf == HAMWSYS_WIN_POINTER ? &v->pointer
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

/* ================================================================== *
 * THE KEYSTROKE CHANNEL — the one ring that is NOT in the segment
 * ==================================================================
 *
 * WHAT THIS CLOSES.  THE SPLIT's attack 4 of 4: a uid-1001 process opens
 * /srv/wsys O_RDONLY, maps it PROT_READ, and reads the bytes between another
 * uid-1001 window's `keys` r and w without moving either, so the victim
 * receives every keystroke normally and cannot tell.  That is a keylogger
 * between two of the user's own applications, it needs no write access at all,
 * and no file mode can stop it: the table must stay world-READABLE because
 * /dev/wsys/windows is the panel taskbar's input.  It is CONFIDENTIALITY, and
 * the only fix is that the bytes are not in a mapping the attacker can obtain.
 *
 * So they are not in a mapping at all any more.  A window's keystrokes travel
 * as DATAGRAMS to a socket the window's owner has bound, and the `keys` ring in
 * struct wwin is dead storage that nothing reads and nothing writes (kept, byte
 * for byte, so struct wwin is unchanged and so wsys_bypass.c's layout mirror
 * still finds the row it means to attack -- the gate must be able to write the
 * dead ring and prove nothing comes out of it).
 *
 * WHY A SOCKET AND NOT THE RECORDED memfd + SCM_RIGHTS.  THE SPLIT's tier 2
 * says "a memfd has no name in the filesystem, so there is no path for a
 * bypasser to open".  THAT IS FALSE, and it was measured before this was built
 * rather than after:
 *
 *   $ ./procfd 1                       # an ordinary process holding a memfd
 *     open(/proc/<victim>/fd/3) = 4 (OK)
 *     mmap PROT_READ = OK, contents: 1 PASSWORD31337
 *
 * /proc/<pid>/fd/<n> IS a path, it is openable by any process of the same uid,
 * and the whole premise of this attack is that attacker and victim share uid
 * 1001.  A memfd handed to the owner over SCM_RIGHTS would have re-opened the
 * exact hole it was chosen to close, one directory deeper.  (The remedy that
 * does work for a memfd is prctl(PR_SET_DUMPABLE, 0) in every window owner --
 * measured in the same run: open EACCES, opendir EACCES, ptrace EPERM.  It is
 * recorded here because tier 2's REMAINING half, the scene and the backbuffer,
 * cannot be a datagram and will need it.)
 *
 * A socket has the property the memfd was believed to have, and this too was
 * measured, not assumed (tests/linux/wsys_keychan.sh re-runs all of it):
 *
 *   open(/proc/self/fd/<sock>) = -1 (No such device or address)
 *
 * A socket inode cannot be opened through /proc at all.  The ONLY way to
 * receive what is sent to a bound datagram address is to be the process that
 * bound it.  That is a kernel object with no mapping and no path, which is what
 * the fix needed all along; it is also, unlike SCM_RIGHTS, what NORTH_STAR.md
 * asks for in as many words -- "what crosses a process boundary is a NAME or a
 * NUMBER, never a descriptor".
 *
 * THE NAME.  Abstract namespace (a leading NUL), so there is no filesystem
 * object for anybody to unlink -- which matters, because a socket FILE in /srv
 * would be owned by uid 1001 and any other uid-1001 process could unlink it and
 * bind its own in its place, becoming the recipient of the victim's keystrokes.
 * The abstract namespace has no unlink: a name is held by its socket until that
 * socket closes.  The name carries the segment's st_dev and st_ino, so two
 * offscreen harnesses (or a gate and a live session) that have different
 * /srv/wsys files cannot collide -- the abstract namespace is per network
 * namespace and this tree's gates unshare only the USER namespace.
 *
 * FIRST BINDER WINS, AND A LOSER FAILS LOUDLY.  bind(2) on a name already bound
 * is EADDRINUSE (measured), so the owner's claim on its own wid cannot be taken
 * from it afterwards.  What an attacker CAN do is get there first: next_wid is
 * readable, so it may pre-bind a run of future wids.  Then the victim's own
 * bind fails -- and a client whose keystrokes would silently go nowhere is
 * exactly the success-shaped failure this tree keeps paying for, so it does not
 * happen: `newwindow` FAILS, by name, on stderr, and no window is created.  A
 * silent keylogger becomes a loud denial of service, and a denial of service by
 * a same-uid process is already available for free (THE SPLIT's residue (c):
 * newwindow is open to every uid, so anyone can exhaust the table).
 *
 * WHO MAY DELIVER A KEYSTROKE, decided by the KERNEL and not by a field in a
 * world-writable table.  Anyone may sendto() an abstract address; abstract
 * sockets have no mode.  So the RECEIVER checks, with SO_PASSCRED/
 * SCM_CREDENTIALS -- credentials stamped by the kernel on each datagram, which
 * the sender cannot forge:
 *
 *     accept if  sender uid == the segment's owner   (the compositor: wsysd,
 *                                                     root on a real boot)
 *            or  sender pid == this process          (a client typing into its
 *                                                     own window)
 *     drop otherwise.
 *
 * That closes THE SPLIT's attack 3 (INJECT a key into another client's ring)
 * for the keys ring as well, and closes it against a SAME-UID attacker, which
 * no file mode could: on a real desktop the only legitimate sender is root.
 * Note what it does NOT rest on: win[wid].pid.  That field lives in the 0666
 * table and is spoofable, and THE SPLIT is right that any check resting on it
 * is worth nothing.  Nothing here rests on it -- the receiver is established by
 * who holds the bind, and the sender by the kernel's own stamp.
 *
 * WHAT THIS DOES NOT CLOSE, so it is not mistaken for more than it is:
 *   * THE SCENE AND THE BACKBUFFER are still in the shared mapping, so another
 *     window's PIXELS are still scrapable (THE SPLIT's SCRAPE).  This closes
 *     the ring that carries typed secrets, not the display.
 *   * THE POINTER, EVENT, TEXT AND CMD RINGS are unchanged.  Pointer motion is
 *     not a password; if that judgement ever stops holding, the mechanism here
 *     is one call per ring away.
 *   * ENUMERATION is unchanged and unfixable while the taskbar reads the table.
 *
 * AND THE ONE THAT WENT FROM "NOT THIS PASS" TO SET: ptrace.  A same-uid
 * attacker that can PTRACE_ATTACH reads the victim's memory directly, and
 * everything above it -- the socket, the credential stamp, the refusal on
 * another window's /keys -- is worth nothing against it.  It is closed from two
 * sides now, and neither side is sufficient alone:
 *
 *   THE BOOT POLICY.  user/linuxinit.ad sets kernel.yama.ptrace_scope=1 as PID
 *   1, the instant /proc exists, and READS IT BACK -- so a kernel with no Yama
 *   says so on the console instead of leaving the desktop to claim a boundary
 *   nothing enforces.  That is Debian's and Ubuntu's default setting: a
 *   non-ancestor same-uid attach is refused, and a debugger still debugs
 *   anything it launched itself.  tests/linux/ptrace_scope_boot.sh measures it
 *   in a real boot, with the same probe run on the dev host (scope 0, attach
 *   SUCCEEDS) as the matching positive control.
 *
 *   THE PROCESS PROPERTY, below: owner_harden(), prctl(PR_SET_DUMPABLE, 0) in
 *   every window owner.  Yama is a boot setting a person can turn off, an
 *   `lsm=` line can omit and another distribution's kernel may not carry;
 *   PR_SET_DUMPABLE is enforced by core kernel code that is always there.  It
 *   also does something Yama does not: it makes /proc/<pid>/mem, /proc/<pid>/fd
 *   and /proc/<pid>/maps unreadable to a same-uid process, which is a path to
 *   the victim's memory that needs no ptrace call at all.
 * ------------------------------------------------------------------ */

/* HARDEN THIS PROCESS AGAINST BEING READ BY ANOTHER OF THE SAME UID.
 *
 * WHY IT IS HERE AND NOT IN EVERY PROGRAM'S main().  A window owner is not a
 * list of binaries -- hamUI clients, the terminal, the browser bridge, a gate's
 * one-file probe and anything a person compiles tomorrow all become one by
 * claiming a window.  keychan_bind() is the single place a process becomes the
 * recipient of a window's keystrokes, on both paths (`newwindow` in ctl_global,
 * and the lazy bind when an owner first opens its own /keys), so it is the one
 * place that cannot be forgotten by a new program.
 *
 * WHAT IT BUYS, measured in tests/linux/wsys_keychan.sh against an ordinary
 * process and in tests/linux/wsys_bypass.sh against a real window owner:
 *   open("/proc/<victim>/mem")   -1 EACCES   (was: an fd, and the memory)
 *   opendir("/proc/<victim>/fd") -1 EACCES   (was: a listing)
 *   ptrace(PTRACE_ATTACH)        -1 EPERM    (was: attached)
 * The first of those is the one worth the most: reading another same-uid
 * process's /proc/<pid>/mem needs no attach and stops nothing, so it is a
 * keylogger that neither Yama's scope 1 nor SIGSTOP-noise would reveal.
 *
 * WHAT IT COSTS, because this is a decision and not a detail:
 *   * NO CORE DUMPS from any window owner.  A crashing DE client leaves a
 *     kernel log line and no core.  That is a real loss of post-mortem
 *     debugging on a distribution meant to be used.
 *   * NO SAME-UID ATTACH to a DE client, so `gdb -p`, `strace -p` and `perf
 *     top -p` against an already-running window stop working.  Launching the
 *     program UNDER the debugger still works (the debugger is then the parent,
 *     and PR_SET_DUMPABLE does not gate a tracer that is already attached).
 *   * /proc/<pid>/{mem,maps,fd,environ,io} of a window owner become
 *     unreadable to the user who owns it.  /proc/<pid>/stat and
 *     /proc/<pid>/cmdline are NOT ptrace-gated, so `ps`, the panel's process
 *     list and this file's own owns_wid() parent-pid walk are unaffected --
 *     that was checked before this landed rather than after.
 *
 * THE ESCAPE HATCH IS NAMED AND LOUD.  HAMWSYS_DUMPABLE=1 in the environment
 * skips it, for the session where somebody genuinely has to attach to a live
 * client -- and says on stderr that it did, because a security property turned
 * off silently by an environment variable is the same shape as one that was
 * never there.  It cannot help an attacker: the variable is read from the
 * VICTIM's own environment, which an attacker who could set it would already
 * have won.
 *
 * IT IS NOT UNDONE ON keychan_unbind.  A process that has held a window has
 * had the window's keystrokes in its address space, and closing the window does
 * not take them back out of the pages it already touched. */
static void owner_harden(void)
{
    static int done;
    if (done) return;
    done = 1;

    const char *e = getenv("HAMWSYS_DUMPABLE");
    if (e && e[0] == '1' && e[1] == '\0') {
        fprintf(stderr,
                "wsys: HAMWSYS_DUMPABLE=1: this window owner stays dumpable, so "
                "another process of the same uid can read its memory through "
                "/proc/%d/mem and ptrace it.\n", (int)getpid());
        return;
    }
    if (prctl(PR_SET_DUMPABLE, 0, 0, 0, 0) < 0)
        fprintf(stderr,
                "wsys: prctl(PR_SET_DUMPABLE, 0) failed (%s): this window "
                "owner's memory is readable by any process of the same uid.\n",
                strerror(errno));
}

/* ==================================================================
 * THE MEDIATOR'S TRANSPORT — STAGE 1 OF docs/wsys_server_design.md
 * ==================================================================
 * The design and the work order are in user/linux-wsys.h.  This is the code.
 * Nothing below runs unless HAMWSYS_SERVER=1 is in the environment, and NO
 * /dev/wsys operation is routed over it yet: stage 1 is a transport that
 * works and changes no behaviour.  Mutations are stage 2, reads and the
 * enumeration policy stage 3, the WSYS_VERSION bump stage 4 and last.
 *
 * ONE FLAG READ, CACHED.  getenv on every open would be a syscall-free string
 * search on every /dev/wsys operation on the system for the sake of a
 * development switch.
 */
static int srv_flag = -1;

static int srv_enabled(void)
{
    if (srv_flag < 0) {
        const char *e = getenv("HAMWSYS_SERVER");
        srv_flag = (e && e[0] == '1' && e[1] == '\0') ? 1 : 0;
    }
    return srv_flag;
}

/* HAMWSYS_SRV_TRACE=1 — one stderr line per routed mutation naming the caller
 * and both permission answers.  Cached for the same reason srv_enabled is. */
static int srv_trace_flag = -1;

static int srv_trace(void)
{
    if (srv_trace_flag < 0) {
        const char *e = getenv("HAMWSYS_SRV_TRACE");
        srv_trace_flag = (e && e[0] == '1' && e[1] == '\0') ? 1 : 0;
    }
    return srv_trace_flag;
}

/* The in-process write, which is what a routed mutation ultimately becomes --
 * with the CALLER installed as the identity its permission checks are asked
 * about.  Defined far below; reached from srv_dispatch. */
static int64_t hamwsys_write_inner(struct hamwsys_file *f, const uint8_t *buf,
                                   uint64_t n);
static struct wwin *win_alloc(int32_t pid);
/* The sink staging pair, defined beside carry_reserve whose shape they share:
 * a sink body is assembled in the writer's own memory and published whole. */
static int  sink_stage_reserve(struct hamwsys_file *f, uint64_t want);
static void sink_publish(struct wsink *s, const uint8_t *body, uint64_t n);

/* The three read-only leaves stage 4 routes.  Each one builds its answer into
 * f->snap; the read server sends that buffer and frees it.  Declared here for
 * the same reason hamwsys_write_inner is: the server is written above the
 * device, because it is the thing that decides who may reach the device. */
static int snap_windows(struct hamwsys_file *f);
static int snap_screen(struct hamwsys_file *f);
static int snap_pool(struct hamwsys_file *f);
/* Stage 9's three.  snap_win_ctl needs the row it is reporting on, so it takes
 * one; snap_dir reads f->wid to tell /dev/wsys from /dev/wsys/<wid>.  There is
 * no snap_wctl: the live-rect answer is built inline in hamwsys_open, so the
 * read server calls a small extractor (srd_wctl) that formats the same five
 * fields from the same row. */
static int snap_win_ctl(struct hamwsys_file *f, struct wwin *v);
static int snap_win_wctl(struct hamwsys_file *f, const struct wwin *v);
static int snap_dir_tier(struct hamwsys_file *f, int list_wids);
static int snap_dir(struct hamwsys_file *f);

/* Stage 4's read server, forked by hamwsys_srv_listen below it. */
static void srd_fork(void);

/* The wire.  Both ends are the same object file, so these structures are a
 * contract with the GATE rather than an ABI across a version boundary — but
 * the gate checks them, so they are written down in linux-wsys.h too. */
struct wsrv_hdr {
    uint32_t magic;
    uint16_t op;
    uint16_t flags;
    uint32_t tag;
    int32_t  wid;
    uint32_t len;
};
struct wsrv_rep {
    uint32_t magic;
    uint32_t tag;
    int32_t  rc;
    uint32_t len;
};

/* THE NAME IS DERIVED FROM THE SEGMENT, exactly as the client wake above is.
 * A window system is identified by the (dev, ino) of its shared segment, so
 * two window systems on one host — a gate's private one and the owner's real
 * desktop — cannot find each other's server.  Deriving it independently would
 * be a second way to answer "which window system is this", and two answers to
 * that question is how a gate ends up talking to the machine owner's desktop. */
static socklen_t srv_addr_named(struct sockaddr_un *a, const char *leafname)
{
    if (!seg_id_known) return 0;
    memset(a, 0, sizeof *a);
    a->sun_family = AF_UNIX;
    a->sun_path[0] = '\0';                     /* abstract */
    int n = snprintf(a->sun_path + 1, sizeof a->sun_path - 1,
                     "hamnix-wsys/%llu.%llu/%s",
                     (unsigned long long)seg_dev, (unsigned long long)seg_ino,
                     leafname);
    if (n <= 0 || (size_t)n >= sizeof a->sun_path - 1) return 0;
    return (socklen_t)(offsetof(struct sockaddr_un, sun_path) + 1 + n);
}

/* TWO NAMES, ONE SEGMENT, AND THE SPLIT IS THE WHOLE OF STAGE 4.
 *
 *   ".../srv"  the frame loop's socket.  Mutations.  Serviced once per wsysd
 *              iteration, which is what lets a burst of them coalesce into
 *              one scan -- measured, that made a routed drag 46.5% of a core
 *              CHEAPER than the unrouted one.
 *   ".../rd"   the read server's socket, in a forked child that never paints.
 *              Reads block by nature, and a blocking request on ".../srv"
 *              waits out whatever frame is in progress: p90 789 us, max 851.
 *
 * A single socket cannot have both properties.  Two names is the honest way
 * to say so, and it means a client that never reads never opens the second
 * one. */
static socklen_t srv_addr(struct sockaddr_un *a)
{
    return srv_addr_named(a, "srv");
}

static socklen_t srd_addr(struct sockaddr_un *a)
{
    return srv_addr_named(a, "rd");
}

/* ---------------------------------------------------------------- server -- */

struct wsrv_conn {
    int      fd;
    uid_t    uid;
    gid_t    gid;
    pid_t    pid;
    uint32_t version;      /* 0 until HELLO */
    uint64_t nreq;
    /* STAGE 5.  `cid` is this connection's identity for the lifetime of the
     * server -- a monotonic counter and NOT the array index, because
     * srv_conn_drop() compacts the array and an index would name a different
     * client the moment somebody exits.  `adopted` is set by a HELLO carrying
     * WSRV_F_ADOPT: this descriptor was inherited, not dialled. */
    uint64_t cid;
    int      adopted;
};

static uint64_t srv_next_cid = 1;

static int  srv_is_server = 0;   /* this process is wsysd; never dial yourself */
static int  srv_lfd = -1;        /* the listening SOCK_SEQPACKET              */
static int  srv_ep  = -1;        /* the epoll fd handed to wsysd's wait set   */
/* The leaf's name, for the trace.  Defined with the op census far below; it is
 * declared here because "which leaf did that mutation address" is a question
 * only the trace can answer and the answer is what tells a routed wctl write
 * from a routed ctl one from outside the process. */
static const char *opc_leafname(int l);

static struct wsrv_conn srv_conn[WSRV_CONN_MAX];
static int  srv_nconn = 0;

/* The counters a client can read back with WSRV_OP_STAT.  They exist for one
 * reason and it is not curiosity: a fire-and-forget message that is delivered
 * and one that is silently dropped are INDISTINGUISHABLE FROM THE SENDING
 * END.  Asking the far side how many it received is the only way to tell them
 * apart, and without it the stage-1 gate would report a transport that drops
 * everything as working. */
static uint64_t srv_n_accept, srv_n_msg, srv_n_nop, srv_n_ping, srv_n_stat;
static uint64_t srv_n_bad, srv_n_bytes;
/* Stage 2's counters.  `refused` is the one worth having: a mediator that
 * never refuses anything is indistinguishable from no mediator, and a gate
 * cannot tell those apart without a number to read. */
static uint64_t srv_n_write, srv_n_newwin, srv_n_refused;
/* Stage 6's two: `scene` counts routed display-list bytes accepted, `frame`
 * counts frame boundaries.  They are separate because the failure this leaf
 * can produce is a frame that never starts or never ends, and a byte count
 * alone cannot tell either of those from a client that simply drew less. */
static uint64_t srv_n_scene, srv_n_frame;

void hamwsys_srv_claim(void)
{
    /* CALLED BEFORE wsysd TOUCHES /dev/wsys AT ALL, and that ordering is the
     * whole reason this is a separate call from listen().  wsysd is a client
     * of its own device — it opens /dev/wsys/screen, /dev/wsys/windows and
     * every window's scene on every frame — so without this it would dial
     * itself on its first open and then block waiting for a reply from the
     * loop it has not entered yet.  listen() cannot do the job: it needs the
     * segment's identity, which means attaching the segment, which is not
     * something to force before wsysd has read the screen geometry. */
    srv_is_server = 1;
}

static void srv_conn_drop(int i)
{
    if (srv_ep >= 0) epoll_ctl(srv_ep, EPOLL_CTL_DEL, srv_conn[i].fd, NULL);
    close(srv_conn[i].fd);
    srv_conn[i] = srv_conn[--srv_nconn];
}

int hamwsys_srv_listen(void)
{
    if (!srv_enabled()) return -1;
    if (srv_ep >= 0) return srv_ep;
    if (shm_attach() < 0) return -1;

    struct sockaddr_un a;
    socklen_t alen = srv_addr(&a);
    if (!alen) return -1;

    int fd = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (fd < 0) {
        fprintf(stderr, "wsys: server socket: %s\n", strerror(errno));
        return -1;
    }
    if (bind(fd, (struct sockaddr *)&a, alen) < 0) {
        /* SAY IT BY NAME.  EADDRINUSE here means another wsysd already serves
         * this segment, which is a real and diagnosable condition; silently
         * running without a server would leave every client falling back to
         * the in-process path with nothing on stderr. */
        fprintf(stderr, "wsys: cannot bind the server name for segment "
                        "%llu.%llu: %s\n",
                (unsigned long long)seg_dev, (unsigned long long)seg_ino,
                strerror(errno));
        close(fd);
        return -1;
    }
    if (listen(fd, 32) < 0) {
        fprintf(stderr, "wsys: server listen: %s\n", strerror(errno));
        close(fd);
        return -1;
    }

    /* AN EPOLL FD, NOT THE LISTENING SOCKET, and that is what makes this fit
     * in wsysd's wait set at all.  build_waitset runs ONCE; the set of live
     * connections changes every time a client starts or exits.  One epoll fd
     * standing for the listener and every connection means the wait set never
     * has to be rebuilt, and the Adder side never learns how many clients
     * there are. */
    srv_ep = epoll_create1(EPOLL_CLOEXEC);
    if (srv_ep < 0) { close(fd); return -1; }
    struct epoll_event ev = { .events = EPOLLIN, .data.fd = fd };
    if (epoll_ctl(srv_ep, EPOLL_CTL_ADD, fd, &ev) < 0) {
        close(srv_ep); srv_ep = -1; close(fd); return -1;
    }
    srv_lfd = fd;
    fprintf(stderr, "wsys: serving /dev/wsys for segment %llu.%llu "
                    "(HAMWSYS_SERVER=1; mutations on this loop, reads in a "
                    "forked read server)\n",
            (unsigned long long)seg_dev, (unsigned long long)seg_ino);
    /* AFTER the frame loop's socket is bound and listening, and that order is
     * forced: srd_fork() closes every inherited descriptor in the child, so a
     * fork before this bind would be a child that races the parent for the
     * ".../srv" name it is not supposed to hold. */
    srd_fork();
    return srv_ep;
}

/* Send one reply.  MSG_DONTWAIT throughout: a client that has stopped reading
 * must not be able to wedge the compositor, and a compositor that blocks on a
 * client's socket buffer is a desktop that stops painting because one program
 * stopped listening. */
static void srv_reply(int fd, uint32_t tag, int32_t rc,
                      const void *pay, uint32_t len)
{
    struct wsrv_rep r = { WSRV_MAGIC_RP, tag, rc, len };
    struct iovec iov[2];
    iov[0].iov_base = &r;   iov[0].iov_len = sizeof r;
    iov[1].iov_base = (void *)pay; iov[1].iov_len = len;
    struct msghdr m;
    memset(&m, 0, sizeof m);
    m.msg_iov = iov;
    m.msg_iovlen = len ? 2 : 1;
    (void)sendmsg(fd, &m, MSG_DONTWAIT | MSG_NOSIGNAL);
}

/* THE OUT-OF-BAND ERROR, tag 0.  The design's first rule is that every
 * mutation returning no data is fire-and-forget, because strict request-reply
 * is the expensive pattern (6.30 us one at a time against 2.31 us at a burst
 * of 16).  A fire-and-forget mutation that is refused still has to tell
 * somebody, so it tells them here, on the connection the client is already
 * draining.  Stage 1's only user is an unknown fire-and-forget op — which is
 * exactly the shape stage 2 needs and means the mechanism is exercised rather
 * than merely written. */
static void srv_err(int fd, uint16_t op, int32_t rc)
{
    struct { uint16_t op; int32_t rc; } body = { op, rc };
    srv_reply(fd, 0, WSRV_OP_ERR, &body, (uint32_t)sizeof body);
}

/* Stage 6's scene handler.  DEFINED BELOW THE DEVICE, not here, because it
 * touches struct wpix -- the per-window memfd -- which is declared with the
 * pixel hand-up far below.  The server is written above the device because it
 * is the thing that decides who may reach the device; this is the one place
 * that ordering costs a forward declaration. */
static int64_t srv_scene_write(const struct wsrv_hdr *h, const uint8_t *pay);

static void srv_dispatch(struct wsrv_conn *c, const struct wsrv_hdr *h,
                         const uint8_t *pay)
{
    srv_n_msg++;
    srv_n_bytes += h->len;
    c->nreq++;
    int want_reply = (h->flags & WSRV_F_REPLY) != 0;

    switch (h->op) {
    case WSRV_OP_HELLO: {
        uint32_t theirs = (h->len >= 4) ? *(const uint32_t *)pay : 0;
        c->version = theirs;
        /* WHY AN ADOPTED CONNECTION IS NOT THE HOST OWNER.  A client that
         * inherited this descriptor says so here, and the flag is STICKY: once
         * set it is never cleared, so a second HELLO cannot wash it off.  It
         * can only ever cost the connection privilege (hostowner() answers 0
         * for it), never grant any, which is why taking the client's word for
         * it is safe -- lying gains nothing.  It exists because SO_PEERCRED is
         * fixed at connect(2): a descriptor dialled by a host-owner toolkit
         * carries the host owner's uid to every process it is handed to. */
        if (h->flags & WSRV_F_ADOPT) c->adopted = 1;
        if (theirs != WSYS_VERSION) {
            /* REFUSE, LOUDLY.  This is where the version bump of stage 4 will
             * do its work; today no shipped client speaks the protocol at all,
             * so this only ever fires for a probe built against another tree. */
            fprintf(stderr, "wsys: client pid %ld speaks wsys version %u, this "
                            "server speaks %u -- refused.\n",
                    (long)c->pid, (unsigned)theirs, (unsigned)WSYS_VERSION);
            uint32_t mine = WSYS_VERSION;
            srv_reply(c->fd, h->tag, -EPROTO, &mine, sizeof mine);
            return;
        }
        uint32_t mine = WSYS_VERSION;
        srv_reply(c->fd, h->tag, 0, &mine, sizeof mine);
        return;
    }
    case WSRV_OP_NOP:
        /* The stage-1 stand-in for a mutation: it returns no data, so it is
         * fire-and-forget and the client does not wait.  It travels the same
         * path a real ctl write will in stage 2. */
        srv_n_nop++;
        if (want_reply) srv_reply(c->fd, h->tag, 0, NULL, 0);
        return;
    case WSRV_OP_PING: {
        srv_n_ping++;
        uint32_t n = h->len > WSRV_MAXPAY ? WSRV_MAXPAY : h->len;
        srv_reply(c->fd, h->tag, (int32_t)n, pay, n);
        return;
    }
    case WSRV_OP_STAT: {
        srv_n_stat++;
        /* 512 and not 384: sixteen %llu at their full width plus the names is
         * 420 characters, and snprintf would have TRUNCATED -- silently
         * dropping the newest field, which is the one a reader added it to
         * see. */
        char b[512];
        int n = snprintf(b, sizeof b,
                         "conns %llu live %d msgs %llu nop %llu ping %llu "
                         "stat %llu bad %llu bytes %llu write %llu "
                         "newwin %llu refused %llu claim %llu "
                         /* capref IS APPENDED, NOT INSERTED.  Readers are
                          * srv_stat_field() by name, but the field order is
                          * what a person reading a gate's log compares
                          * between two runs, and a new field in the middle
                          * makes every stored line look different. */
                         "connrefused %llu scene %llu frame %llu "
                         "capref %llu\n",
                         (unsigned long long)srv_n_accept, srv_nconn,
                         (unsigned long long)srv_n_msg,
                         (unsigned long long)srv_n_nop,
                         (unsigned long long)srv_n_ping,
                         (unsigned long long)srv_n_stat,
                         (unsigned long long)srv_n_bad,
                         (unsigned long long)srv_n_bytes,
                         (unsigned long long)srv_n_write,
                         (unsigned long long)srv_n_newwin,
                         (unsigned long long)srv_n_refused,
                         (unsigned long long)srv_n_claim,
                         (unsigned long long)srv_n_connrefuse,
                         (unsigned long long)srv_n_scene,
                         (unsigned long long)srv_n_frame,
                         (unsigned long long)srv_n_capref);
        if (n < 0) n = 0;
        srv_reply(c->fd, h->tag, n, b, (uint32_t)n);
        return;
    }
    case WSRV_OP_WRITE: {
        /* THE MUTATION PATH, AND THE ONLY LINE IN IT THAT MATTERS IS
         * srv_as_caller().
         *
         * Everything else here is the ordinary in-process write -- the same
         * hamwsys_write_inner every client has always called.  What makes it
         * MEDIATION rather than a proxy is that the two permission questions
         * it asks inside (hostowner, owns_wid) are answered about the process
         * on the other end of this socket, from credentials the kernel
         * supplied, instead of about wsysd.  Without that line wsysd -- which
         * runs as the host owner -- would grant every write, and the boundary
         * would be strictly WORSE than no boundary while every gate passed.
         *
         * srv_as_self() runs on every exit path, including the refusals.  A
         * caller identity left installed would be inherited by the
         * compositor's own next write to /dev/wsys, which it makes every
         * frame. */
        int leaf = (h->flags >> WSRV_LEAF_SHIFT) & 0xff;
        int kind = (leaf == WSRV_LEAF_WIN_CTL)   ? HAMWSYS_WIN_CTL
                 : (leaf == WSRV_LEAF_CTL)       ? HAMWSYS_CTL
                 : (leaf == WSRV_LEAF_WIN_SCENE) ? HAMWSYS_WIN_SCENE
                 : (leaf == WSRV_LEAF_WIN_WCTL)  ? HAMWSYS_WIN_WCTL
                 : 0;
        /* THE TWO PER-WINDOW LEAVES TAKE THE SAME RULE, and they must: wctl's
         * `move`/`resize` and wid/ctl's `geometry` are the same act under two
         * names, so a check on one of them is not a check.
         *
         * AND THIS PRE-CHECK IS NOT WHAT REFUSES -- SAID PLAINLY, BECAUSE THE
         * OPPOSITE IS EASY TO BELIEVE.  Both leaves' arms in
         * hamwsys_write_inner open with the same two lines (`win_find` ->
         * ENOENT, `!hostowner() && !owns_wid` -> EPERM), and under
         * srv_as_caller they are already answered about the caller: deleting
         * this branch changes no refusal.  What it is actually for is the
         * counter below -- srv_n_connrefuse, stage 5's "the descriptor rule
         * refused something the walk would have granted" -- and making the
         * decision ONCE, before anything is touched, since a routed write is
         * the open and the write at the same moment.  THE MEDIATION IS
         * srv_as_caller_full() ABOVE AND NOTHING ELSE; that is as true of this
         * leaf as stage 2 said it was of the first one. */
        int perwin = (kind == HAMWSYS_WIN_CTL || kind == HAMWSYS_WIN_WCTL);
        if (!kind) {
            srv_n_bad++;
            srv_err(c->fd, h->op, -EINVAL);
            return;
        }
        srv_n_write++;
        srv_as_caller_full(c->uid, c->pid, c->cid, c->adopted);
        /* WHAT THE TWO PREDICATES ACTUALLY ANSWER, ON THE SERVER, ABOUT THE
         * CALLER.  Stage 2 flagged owns_wid()'s ppid walk as the sharp edge and
         * could not check it: a single-uid gate's "stranger" IS the host owner,
         * so hostowner() short-circuits and owns_wid() is never even reached.
         * Reading the answer off the outside of the boundary cannot separate
         * "owns_wid said no" from "hostowner said yes first", and those are
         * opposite findings.  So the server says which one decided, from
         * inside, where the caller identity is installed.  Off unless asked
         * for: this is one fprintf per routed mutation and a drag makes ~800 a
         * second. */
        /* BOTH ANSWERS, BECAUSE THE CONTRAST IS THE FINDING.  `owns_wid` is
         * now the connection question and `ancestry` is the walk that used to
         * be the whole of it; a line reading ancestry=1 owns_wid=0 is a
         * descendant that would have been granted before stage 5 and is
         * refused now, and there is no other way to see that from outside. */
        if (srv_trace()) {
            struct wwin *tv = perwin ? win_find(h->wid) : NULL;
            /* THE LEAF IS NAMED, and it was not before.  Four leaves now cross
             * this line and `wid/ctl geometry` and `wid/wctl move` are the same
             * act under two names -- so a trace that does not say which one it
             * carried cannot answer "did this client route its wctl writes, or
             * only its ctl ones", which is the question a gate has to ask from
             * outside the process. */
            fprintf(stderr, "wsrvtrace: caller uid=%u pid=%ld cid=%llu%s -> "
                            "leaf=%s wid=%d ownerpid=%d hostowner=%d "
                            "owns_wid=%d ancestry=%d\n",
                    (unsigned)c->uid, (long)c->pid,
                    (unsigned long long)c->cid, c->adopted ? " adopted" : "",
                    opc_leafname(kind),
                    (int)h->wid, tv ? (int)tv->pid : -1, hostowner(),
                    perwin ? owns_wid(h->wid) : -1,
                    perwin ? owns_wid_ancestry(h->wid) : -1);
        }
        int64_t rc = -EPERM;
        if (kind == HAMWSYS_WIN_SCENE) {
            rc = srv_scene_write(h, pay);
        } else if (perwin && !win_find(h->wid)) {
            rc = -ENOENT;
        } else if (perwin && !hostowner() && !owns_wid(h->wid)) {
            /* COUNTED SEPARATELY WHEN THE WALK WOULD HAVE SAID YES, because
             * that number is the whole of what stage 5 changed: it is the
             * mutations that descent used to carry and a descriptor no longer
             * does.  A gate cannot tell "the new rule refused something" from
             * "nothing was attempted" without it. */
            if (owns_wid_ancestry(h->wid)) srv_n_connrefuse++;
            /* THE GATE AT OPEN, kept.  hamwsys_open refuses this before any
             * mutation happens and hamwsys_write refuses it again, because a
             * descriptor can outlive the privilege that opened it.  A routed
             * write is one message and therefore both moments at once, so the
             * check is made once, here, before anything is touched. */
            rc = -EPERM;
        } else {
            struct hamwsys_file f;
            memset(&f, 0, sizeof f);
            f.leaf = kind;
            f.wid = h->wid;
            f.write = 1;
            errno = 0;
            uint32_t before = shm ? __atomic_load_n(&shm->gen, __ATOMIC_ACQUIRE)
                                  : 0;
            rc = hamwsys_write_inner(&f, pay, h->len);
            /* NO wake_poke() HERE, AND THAT IS THE ANSWER TO THE COST
             * QUESTION STAGE 1 LEFT OPEN.  wake_poke is suppressed inside the
             * compositor anyway (it re-reads the segment every iteration), so
             * a routed mutation costs ONE wake -- the epoll wake that
             * delivered this message -- where the in-process path also cost
             * one, the client's poke of the wake channel.  Mediation MOVES a
             * wake; it does not add one.  tests/linux/wsys_srv_mutate.sh
             * measures whether that is true rather than asserting it. */
            (void)before;
        }
        srv_as_self();
        if (rc < 0) {
            srv_n_refused++;
            if (want_reply) srv_reply(c->fd, h->tag, (int32_t)rc, NULL, 0);
            else            srv_err(c->fd, h->op, (int32_t)rc);
        } else if (want_reply) {
            srv_reply(c->fd, h->tag, (int32_t)rc, NULL, 0);
        }
        return;
    }
    case WSRV_OP_NEWWIN: {
        /* THE ROW IS ALLOCATED HERE AND THE KEYSTROKE CHANNEL IS NOT, and the
         * split is forced by what each thing IS.
         *
         * A row is shared state, so one allocator is what makes two clients
         * unable to collide (see THE RACE THAT ROUTING RETIRES at win_alloc).
         * A keystroke channel is an abstract socket BOUND BY THE PROCESS THAT
         * WILL READ IT; bound here it would be held by wsysd, and the window's
         * real owner would come up looking perfectly normal and be deaf to the
         * keyboard for ever -- the success-shaped failure this tree refuses.
         * So the client binds its own after this returns, which is what
         * hamwsys_alloc already does for a DE-spawned child. */
        srv_n_newwin++;
        srv_as_caller_full(c->uid, c->pid, c->cid, c->adopted);
        struct wwin *v = win_alloc((int32_t)c->pid);
        /* THE ROW IS BOUND TO THE CONNECTION THAT ASKED FOR IT, here, at the
         * one moment the server knows who allocated it.  This is stage 5's
         * first of the two ways a row acquires a holder; the other is the
         * exact-pid claim in srv_caller_holds_wid(), for rows the DE stamps
         * on a process's behalf before it has connected. */
        if (v) srv_own_bind(v, c->cid);
        /* A WINDOW ALLOCATED OVER AN ADOPTED CONNECTION IS STAMPED AGAINST THE
         * PROCESS THAT DIALLED, not the one that asked, because `c->pid` is
         * SO_PEERCRED and SO_PEERCRED does not follow a descriptor.  It is a
         * wart and it is not a hole: the row is held by the connection either
         * way, /dev/wsys/self answers "creator pid or ancestor" so the caller
         * still resolves it, and the alternative -- trusting a pid the client
         * sent -- is the one thing a mediator may never do. */
        srv_as_self();
        int32_t wid = v ? v->wid : -1;
        if (v) shm->gen++;
        srv_reply(c->fd, h->tag, wid >= 0 ? 0 : -ENOSPC, &wid, sizeof wid);
        return;
    }
    default:
        srv_n_bad++;
        if (want_reply) srv_reply(c->fd, h->tag, -ENOSYS, NULL, 0);
        else            srv_err(c->fd, h->op, -ENOSYS);
        return;
    }
}

int hamwsys_srv_service(void)
{
    if (srv_ep < 0) return 0;
    int handled = 0;
    struct epoll_event ev[WSRV_CONN_MAX + 1];
    for (;;) {
        int n = epoll_wait(srv_ep, ev, (int)(sizeof ev / sizeof ev[0]), 0);
        if (n <= 0) break;
        for (int i = 0; i < n; i++) {
            if (ev[i].data.fd == srv_lfd) {
                for (;;) {
                    int cfd = accept4(srv_lfd, NULL, NULL,
                                      SOCK_NONBLOCK | SOCK_CLOEXEC);
                    if (cfd < 0) break;
                    /* THE CEILING, AND IT IS NO LONGER A CLOSED DESCRIPTOR
                     * AND NOTHING ELSE.  close(cfd) alone left the one
                     * process that KNOWS the table is full saying nothing at
                     * all, while the client it turned away went quietly back
                     * to the unmediated path.  Counted always, said once. */
                    if (srv_nconn >= WSRV_CONN_MAX) {
                        srv_cap_refused("srv", ++srv_n_capref);
                        close(cfd); continue;
                    }
                    /* WHO IS CALLING, taken from the kernel and not from the
                     * message.  This is the entire point of having a mediator:
                     * SO_PEERCRED is the one fact about a client that the
                     * client cannot forge, and it is what stage 3's
                     * enumeration policy — "your own windows, unless you hold
                     * the taskbar capability" — will be decided on.  It is
                     * captured now because capturing it later would mean
                     * trusting a pid the client sent. */
                    struct ucred uc;
                    socklen_t ul = sizeof uc;
                    memset(&uc, 0, sizeof uc);
                    (void)getsockopt(cfd, SOL_SOCKET, SO_PEERCRED, &uc, &ul);
                    struct wsrv_conn *c = &srv_conn[srv_nconn++];
                    memset(c, 0, sizeof *c);
                    c->fd = cfd; c->uid = uc.uid; c->gid = uc.gid;
                    c->pid = uc.pid;
                    c->cid = srv_next_cid++;
                    struct epoll_event e = { .events = EPOLLIN,
                                             .data.fd = cfd };
                    if (epoll_ctl(srv_ep, EPOLL_CTL_ADD, cfd, &e) < 0) {
                        close(cfd); srv_nconn--; continue;
                    }
                    srv_n_accept++;
                }
                continue;
            }
            int k = -1;
            for (int j = 0; j < srv_nconn; j++)
                if (srv_conn[j].fd == ev[i].data.fd) { k = j; break; }
            if (k < 0) continue;
            for (;;) {
                uint8_t buf[sizeof(struct wsrv_hdr) + WSRV_MAXPAY];
                ssize_t r = recv(srv_conn[k].fd, buf, sizeof buf, MSG_DONTWAIT);
                if (r < 0) break;                      /* EAGAIN: drained */
                /* ZERO IS EOF, NOT AN EMPTY MESSAGE.  On SOCK_SEQPACKET the
                 * two are told apart only by knowing that no message this
                 * protocol sends is shorter than its header — which is why
                 * the header is mandatory and never elided. */
                if (r == 0) { srv_conn_drop(k); break; }
                if ((size_t)r < sizeof(struct wsrv_hdr)) { srv_n_bad++; continue; }
                struct wsrv_hdr h;
                memcpy(&h, buf, sizeof h);
                if (h.magic != WSRV_MAGIC_RQ
                    || h.len > WSRV_MAXPAY
                    || (size_t)r != sizeof h + h.len) {
                    srv_n_bad++;
                    continue;
                }
                srv_dispatch(&srv_conn[k], &h, buf + sizeof h);
                handled++;
            }
        }
        if (n < (int)(sizeof ev / sizeof ev[0])) break;
    }
    return handled;
}

/* ==================================================================
 * STAGE 4 — THE READ SERVER, AND THE ENUMERATION POLICY
 * ==================================================================
 * WHY THIS IS A SEPARATE PROCESS AND NOT ANOTHER CASE IN srv_dispatch.
 *
 * Stage 1 measured a blocking request against the frame-loop server under a
 * heavy drag: p50 32 us, p90 789 us, max 851 us.  The distribution is bimodal
 * and not noisy -- a request either catches an idle loop (~27 us) or waits out
 * a frame.  851 us is nearly three times the whole published 0.3 ms
 * input-to-pixel budget, for one operation.  Mutations do not care, because
 * they do not wait.  READS ARE NOTHING BUT WAITING: the caller wants the
 * bytes.  Putting /dev/wsys/windows on the frame-loop socket would charge the
 * taskbar up to a frame on every refresh, and the taskbar is the one client
 * the whole enumeration policy exists for.
 *
 * So wsysd forks a child at listen() whose entire job is to block in
 * epoll_wait and answer reads.  It has the segment mapped MAP_SHARED (it
 * inherited the mapping across the fork), so it answers from the same window
 * table the compositor is writing -- which is EXACTLY what every in-process
 * client does today, no more and no less.  It never rasterizes, so there is
 * no frame for a read to wait out, and its latency is the socket's.
 *
 * WHAT IT MAY NOT DO, and the list is short on purpose: it answers
 * WSRV_OP_READ, WSRV_OP_HELLO and WSRV_OP_STAT and nothing else.  A mutation
 * arriving here is -ENOSYS.  Two processes writing the window table would put
 * the ordering guarantee stage 2 bought -- a mutation is visible to the
 * scan_windows() of the SAME iteration -- back into doubt for no gain.
 *
 * IT DIES WITH ITS PARENT.  PR_SET_PDEATHSIG(SIGKILL) plus a recheck of
 * getppid() after setting it, because a parent that exits between the fork
 * and the prctl would otherwise leave a read server serving a segment nobody
 * composites -- a window system that answers questions and paints nothing,
 * which is the success-shaped failure this tree refuses everywhere else.
 */

/* THIS PROCESS IS THE READ SERVER, AND IT EXISTS BECAUSE STAGE 9 ROUTED THE
 * DIRECTORY.  This file's header for the read server says what it may not do,
 * and the list is short on purpose: it answers READ, HELLO and STAT, and "two
 * writers to the window table would put the ordering guarantee stage 2 bought
 * back into doubt for no gain."
 *
 * `snap_dir()` -- the in-process answer for /dev/wsys -- OPENS WITH
 * win_reap_dead(), which clears `used` on every row whose owner has exited,
 * bumps shm->gen, releases pixel/backbuffer/image slots and drops keystroke
 * binds.  In a client that is a self-serving tidy-up of the caller's own view.
 * In the READ SERVER it is a second writer to the window table, reached BY AN
 * ARBITRARY CLIENT'S READ -- so `cat /dev/wsys` from any process on the box
 * would destroy rows in a process that is explicitly forbidden to mutate, and
 * would do it from the one socket whose default arm is `-ENOSYS`.  Found while
 * routing the leaf rather than after; the reap stays with the compositor, which
 * does it every frame in scan_windows anyway, so nothing is lost but the
 * second writer. */
static int  srd_is_child = 0;
static int  srd_lfd = -1;
static int  srd_ep  = -1;
static struct wsrv_conn srd_conn[WSRV_CONN_MAX];
static int  srd_nconn = 0;
static pid_t srd_pid = -1;              /* in the PARENT: the child's pid    */

/* The read server's counters, readable with WSRV_OP_STAT on its own socket.
 * `full` and `empty` are the policy's two outcomes, and they are here for the
 * same reason `refused` is on the mutation side: a policy that never denies
 * anything and no policy at all are the same thing from outside, and a gate
 * cannot tell them apart without a number. */
static uint64_t srd_n_accept, srd_n_read, srd_n_full, srd_n_empty, srd_n_bad;
/* Stage 10's own, and it is separate from `reads` on purpose: an existence
 * question carries no payload, so a build that routed it and a build that did
 * not would produce the same byte counts and nearly the same read count.  The
 * gate needs a number that is zero if and only if nothing was routed. */
static uint64_t srd_n_exist;

/* ------------------------------------------------------------------ *
 * THE ENUMERATION POLICY.  This is the decision, not the mechanism.
 * ------------------------------------------------------------------ *
 * THE RULE, in one sentence: a caller gets the whole window list if it is the
 * host owner or if it already owns at least one window in this window system,
 * and otherwise it gets an EMPTY list.
 *
 * WHAT IT PERMITS.  The compositor, and anything running as the uid that owns
 * the segment.  The panel, every application, every toolkit task -- anything
 * that has called newwindow, or is descended from something that did.  Those
 * callers see every window's id and title, exactly as they do today.  The
 * taskbar therefore keeps working with no change to how it is spawned, no new
 * flag, and nothing granted to it that is not equally granted to every other
 * program with a window on the screen.
 *
 * WHAT IT DENIES.  Every process that has no window: a shell script, a
 * `cat`, a background daemon, a compromised non-graphical service, anything
 * that wandered into the namespace where /dev/wsys is reachable.  Those get
 * an empty list rather than an error, because "there is nothing here for you"
 * is the truthful answer and ENOENT/EPERM would tell a prober that a window
 * system exists and it is merely not allowed -- which is the fact worth
 * withholding.
 *
 * WHAT IT DOES NOT DO, SAID PLAINLY BECAUSE THE DESIGN DOC PROMISED MORE.
 * docs/wsys_server_design.md says enumeration "can return the caller's own
 * windows to an ordinary client and the full list only to a holder of the
 * taskbar capability".  THAT IS NOT WHAT THIS IS, and it cannot be built on
 * what SO_PEERCRED can see today.  The panel is spawned by the compositor
 * through `/bin/hamsh /etc/rc.de-user /bin/hampanelscene`, and so is every
 * DE application; that rc ends in `setuid 1001`, so the taskbar and a
 * text editor arrive at this socket with the SAME uid, the SAME gid and an
 * ancestry that meets at the same process.  There is no fact in
 * SO_PEERCRED that separates them.  A rule that claimed to would be reading
 * something the client chose -- an argv, an environment variable, a name --
 * and that is advice, not a boundary, which is the whole finding of stage 3a.
 *
 * So the line is drawn where an unforgeable fact actually falls: HAVING A
 * WINDOW.  A person may reasonably say that is too weak, and they would be
 * pointing at a real gap -- any app on the desktop still learns every
 * window's title.  The mechanism that would close it is a dedicated group on
 * the panel's spawn (peercred carries the gid, /etc/group records the grant,
 * and nothing has to be invented), and that is a change to how the distro
 * starts the panel, not a change to this server.  It is NOT made here, and
 * the taskbar is NOT quietly privileged in the meantime: it passes this rule
 * on exactly the same footing as every other window owner.
 */
enum { SRD_ENUM_EMPTY = 0, SRD_ENUM_FULL = 1 };

static int srd_enum_tier(uid_t uid, pid_t pid, int *by_hostowner)
{
    int tier = SRD_ENUM_EMPTY, host = 0;
    if (!shm) { if (by_hostowner) *by_hostowner = 0; return SRD_ENUM_EMPTY; }
    /* The caller is installed for the same reason a routed mutation installs
     * it: owns_wid() walks the CALLER's ancestry and hostowner() reads the
     * CALLER's uid, and asked without this they would both answer about the
     * read server -- which runs as the segment's owner and would therefore
     * grant everything to everybody. */
    srv_as_caller(uid, pid);
    host = hostowner();
    if (host) {
        tier = SRD_ENUM_FULL;
    } else {
        /* EVERY USED ROW, not only the enumerable ones.  A panel's own window
         * is visible but NOT decorated, and snap_windows() skips undecorated
         * windows -- so a policy that asked "do you own something that shows
         * up in the list" would deny the taskbar its own list.  The question
         * is "do you own a window", and the window table is where that is
         * answered. */
        /* owns_wid_ancestry() AND NOT owns_wid(), and the difference is stage
         * 5.  A routed MUTATION must arrive on the connection that holds the
         * row -- a descriptor, handed over deliberately.  ENUMERATION asks a
         * different question: "does this process own a window", which is what
         * stage 4's policy is stated in and what its 9/0 gate measures.  The
         * read server is a separate process and its connections are separate
         * connections, so it holds no bindings at all; asking the mutation
         * question here would deny the panel its own window list and answer
         * EMPTY to every client on the desktop. */
        for (int i = 0; i < WSYS_MAX_WINDOWS && tier == SRD_ENUM_EMPTY; i++)
            if (shm->win[i].used && owns_wid_ancestry(shm->win[i].wid))
                tier = SRD_ENUM_FULL;
    }
    srv_as_self();
    if (by_hostowner) *by_hostowner = host;
    return tier;
}

/* One read, answered.  Returns the negative errno, or 0 with the answer in
 * *f (which the caller frees).
 *
 * `wid` COMES OFF THE WIRE AND IS NOT OPTIONAL SINCE STAGE 9.  The three
 * leaves stage 4 routed are all singular files and ignored it; wid/ctl,
 * wid/wctl and the directory all address a particular row, and a server that
 * answered them out of a zeroed f->wid would report on window 0 -- which is no
 * window -- for every caller. */
static int srd_answer(struct wsrv_conn *c, int leaf, int32_t wid,
                      uint16_t flags, struct hamwsys_file *f)
{
    memset(f, 0, sizeof *f);
    f->wid = wid;
    errno = 0;
    switch (leaf) {
    case WSRV_LEAF_WINDOWS: {
        int host = 0;
        int tier = srd_enum_tier(c->uid, c->pid, &host);
        if (srv_trace())
            fprintf(stderr, "wsrvtrace: enum caller uid=%u pid=%ld -> "
                            "hostowner=%d tier=%s\n",
                    (unsigned)c->uid, (long)c->pid, host,
                    tier == SRD_ENUM_FULL ? "FULL" : "EMPTY");
        if (tier != SRD_ENUM_FULL) {
            srd_n_empty++;
            /* An empty answer, not a refusal.  See WHAT IT DENIES above. */
            f->snap = NULL; f->snaplen = 0;
            return 0;
        }
        srd_n_full++;
        return snap_windows(f) < 0 ? (errno ? -errno : -EIO) : 0;
    }
    /* screen and pool carry NO policy, and that is a decision rather than an
     * omission.  `screen` is the mode the compositor published and every
     * client must lay itself out against it; `pool` is the device reporting
     * how many backbuffer slots are left, which is what a program diagnosing
     * its own blank window reads.  Neither names another client or says
     * anything about one.  Withholding them would break layout and blind the
     * one diagnostic that exists for an exhausted pool, and buy nothing. */
    case WSRV_LEAF_SCREEN:
        return snap_screen(f) < 0 ? (errno ? -errno : -EIO) : 0;
    case WSRV_LEAF_POOL:
        return snap_pool(f) < 0 ? (errno ? -errno : -EIO) : 0;

    /* ==================================================================
     * STAGE 9 — THE ATTRIBUTE READS, AND THE RULE IS THE LEAF'S SHAPE
     * ==================================================================
     * `windows` was never the only way to learn which windows exist, and
     * §7.1 of docs/wsys_server_design.md measured the other three with the
     * policy live and working:
     *
     *     cat /dev/wsys        -> ctl self windows screen pool 2
     *     cat /dev/wsys/2/ctl  -> 2 100 100 300 200 5 1 1 1 0 0 0 0 0
     *     cat /dev/wsys/2/wctl -> 100 100 300 200 click
     *
     * from a uid-1002 process owning nothing, against a uid-1001 victim, on
     * the same run on which the routed `windows` read answered that same
     * process EMPTY.  WHAT STAGE 4 WITHHELD WAS THE TITLE AND ONLY THE TITLE.
     *
     * TWO RULES, AND THE SPLIT IS NOT A COMPROMISE -- IT IS THE SHAPE OF THE
     * QUESTION EACH LEAF ASKS.
     *
     *   /dev/wsys, /dev/wsys/<wid>   THE ENUMERATION TIER (srd_enum_tier).
     *       A directory is a question about the SET, and `windows` is the same
     *       question under another name -- so it takes the same answer, or the
     *       policy is a gate on one of two spellings, which this file has twice
     *       refused to build (the wallpaper sink; `wctl move` against `ctl
     *       geometry`).  There is no per-window rule to apply here: the caller
     *       has not named a window, it is asking which ones there are.
     *
     *   <wid>/ctl, <wid>/wctl        hostowner() || owns_wid_ancestry(wid).
     *       These name ONE window, and the rule is the one their own WRITE arms
     *       already apply -- hamwsys_open's for_write gate and
     *       hamwsys_write_inner's wctl arm are both `hostowner() ||
     *       owns_wid()` -- and the one the four rings took in
     *       THE FOUR RINGS THAT HAD NO OWNER CHECK AT ALL.  A leaf whose read
     *       and write answer to different rules is two policies wearing one
     *       path.
     *
     * owns_wid_ancestry() AND NOT owns_wid(), for srd_enum_tier's own reason:
     * since stage 5 owns_wid() is the CONNECTION question, and the read server
     * is a separate process holding no bindings, so it would answer 0 for every
     * caller on the desktop.  "Does this process own this window" is the
     * question a read can be gated on here, and the walk is what answers it.
     *
     * THE PER-WINDOW RULE IS THE TIGHTER ONE AND IT WAS MEASURED FREE, WHICH
     * CORRECTS THE OBVIOUS WORRY.  The fear is that it denies the panel and the
     * compositor attributes of windows they do not own -- which is their job.
     * Swept: the ONLY reader of a foreign <wid>/ctl in the tree is
     * user/wsysd.ad's load_window(), called from scan_windows() for every wid
     * in the directory, and wsysd is srv_is_server (it never routes) and is the
     * host owner besides, so it is admitted by the first clause exactly as it
     * is admitted by the write gate today.  hampanelscene's taskbar reads
     * /dev/wsys/windows and never a foreign <wid>/ctl; lib/hamui.ad, hamUId,
     * hamdesktop and hamappmenu open these two leaves WRITE-ONLY.  Nothing on
     * the desktop needs another window's geometry, so nothing pays for this.
     *
     * ENOENT AND NOT EPERM, restating stage 4's reason: "there is no such
     * window" withholds the existence of the window system and EPERM
     * advertises it.  It is also what an unrouted reader gets for a wid that
     * really is absent, so a prober cannot separate the two.
     *
     * WHAT THIS STILL DOES NOT BUY, said here because no gate can say it: the
     * TITLE is still handed to every window owner by `windows`, so an
     * application still learns that a window called "Bank" exists.  Closing
     * that is the dedicated group on the panel's spawn that stage 4 scoped and
     * did not build.  What this closes is the process that owns NOTHING -- the
     * `cat`, the script, the background daemon, the compromised non-graphical
     * service -- and, for the two per-window leaves, every application on the
     * desktop as well.
     */
    /* ==================================================================
     * STAGE 10 — EXISTENCE, AS A SERVER ANSWER
     * ==================================================================
     * The question hamwsys_open() asks before it reads anything, moved off the
     * mapped table.  See WSRV_LEAF_EXISTS in linux-wsys.h for why, and for the
     * measurement that says the exit code of `cat` is an enumeration channel
     * on every leaf stage 9 did not reach.
     *
     * THE SIDE-EFFECT AUDIT, DONE BEFORE THIS WAS ROUTED AND NOT AFTER,
     * because snap_dir() taught this file that lesson at a price: this arm
     * runs srv_as_caller(), hostowner(), owns_wid_ancestry() and win_find(),
     * and every one of them is a pure read.  owns_wid_ancestry() walks
     * /proc/<pid>/stat and win_find() scans the table; neither writes a row,
     * releases a slot or touches a ring.  There is no win_reap_dead() on this
     * path -- which is exactly what made the directory dangerous to route --
     * and there must never be one, for srd_is_child's reason.
     *
     * NO PAYLOAD, AND THAT IS THE WHOLE ANSWER.  rc 0 is yes; -ENOENT is no,
     * and it is the SAME -ENOENT a caller gets for a wid that never existed,
     * so the two cannot be told apart from outside.  EPERM here would say
     * "there is a window and you may not have it", which is the bit being
     * withheld. */
    case WSRV_LEAF_EXISTS: {
        int host, own, allow;
        srv_as_caller(c->uid, c->pid);
        host  = hostowner();
        own   = owns_wid_ancestry(f->wid);
        allow = host || own;
        srv_as_self();
        /* THE ORDER MATTERS AND IT IS THE CHEAP ONE FIRST BY ACCIDENT ONLY:
         * the permission question is asked before the existence question, so a
         * refused caller never reaches win_find() and the answer it gets does
         * not depend on the table at all.
         *
         * STAGE 10b CORRECTS THAT LAST CLAUSE, AND IT WAS MEASURED WRONG BY 2x.
         * `allow` above is not free of the table: owns_wid_ancestry() calls
         * win_find() ITSELF and then decided, on the answer, whether to walk
         * /proc at all.  So this line was true of the ENOENT and false of the
         * clock -- a refused caller's request took ~93 us for a live wid and
         * ~46 us for a dead one, which is the same existence bit read with a
         * stopwatch.  The fix is in owns_wid_ancestry(), where the early exits
         * were; see the measurement recorded there. */
        int there = allow && win_find(f->wid) != NULL;
        /* THE OPEN IS NAMED, and stage 10b needed it to be.  A read open and a
         * write open of the same leaf produced one identical line, so counting
         * crossings could not attribute them -- and a gate that cannot say
         * WHICH open crossed cannot tell a routed write open from the routed
         * read open sitting next to it in the same process.  The flag is
         * carried for this and decides nothing. */
        if (srv_trace())
            fprintf(stderr, "wsrvtrace: read caller uid=%u pid=%ld -> "
                            "leaf=exists open=%s wid=%d hostowner=%d "
                            "ancestry=%d tier=n/a -> %s\n",
                    (unsigned)c->uid, (long)c->pid,
                    (flags & WSRV_F_FORWRITE) ? "write" : "read",
                    (int)f->wid, host, own,
                    there ? "FULL" : "EMPTY");
        srd_n_exist++;
        if (!there) { srd_n_empty++; return -ENOENT; }
        srd_n_full++;
        f->snap = NULL; f->snaplen = 0;
        return 0;
    }
    case WSRV_LEAF_WIN_CTL:
    case WSRV_LEAF_WIN_WCTL:
    case WSRV_LEAF_DIR: {
        int kind = (leaf == WSRV_LEAF_WIN_CTL)  ? HAMWSYS_WIN_CTL
                 : (leaf == WSRV_LEAF_WIN_WCTL) ? HAMWSYS_WIN_WCTL
                 : HAMWSYS_DIR;
        int host = 0, allow, own = -1, tier = -1;
        if (kind == HAMWSYS_DIR) {
            tier  = srd_enum_tier(c->uid, c->pid, &host);
            allow = (tier == SRD_ENUM_FULL);
        } else {
            /* The caller is installed for the same reason srd_enum_tier
             * installs it: asked without this, hostowner() and the walk would
             * both answer about the READ SERVER -- which runs as the segment's
             * owner and is an ancestor of half the desktop, so every check
             * would say yes and the mediator would be a rubber stamp. */
            srv_as_caller(c->uid, c->pid);
            host  = hostowner();
            own   = owns_wid_ancestry(f->wid);
            allow = host || own;
            srv_as_self();
        }
        if (srv_trace())
            fprintf(stderr, "wsrvtrace: read caller uid=%u pid=%ld -> "
                            "leaf=%s wid=%d hostowner=%d ancestry=%d tier=%s "
                            "-> %s\n",
                    (unsigned)c->uid, (long)c->pid, opc_leafname(kind),
                    (int)f->wid, host, own,
                    tier < 0 ? "n/a" : (tier == SRD_ENUM_FULL ? "FULL" : "EMPTY"),
                    allow ? "FULL" : "EMPTY");
        if (!allow) {
            srd_n_empty++;
            /* THE ROOT DIRECTORY IS THE ONE THAT STILL ANSWERS, and it must:
             * /dev/wsys is a directory, and a reader that cannot list it at all
             * cannot reach `windows` -- the very file whose empty answer is how
             * this policy says no.  So the fixed names stay and the WIDS GO,
             * which is the shape `windows` already has: the caller learns a
             * window system is there (it opened the device) and learns nothing
             * about who is using it. */
            if (kind == HAMWSYS_DIR && f->wid == 0)
                return snap_dir_tier(f, 0) < 0 ? (errno ? -errno : -EIO) : 0;
            return -ENOENT;
        }
        srd_n_full++;
        if (kind == HAMWSYS_DIR)
            return snap_dir(f) < 0 ? (errno ? -errno : -EIO) : 0;
        struct wwin *v = win_find(f->wid);
        if (!v) return -ENOENT;
        if (kind == HAMWSYS_WIN_WCTL)
            return snap_win_wctl(f, v) < 0 ? (errno ? -errno : -EIO) : 0;
        return snap_win_ctl(f, v) < 0 ? (errno ? -errno : -EIO) : 0;
    }
    default:
        return -EINVAL;
    }
}

static void srd_conn_drop(int i)
{
    if (srd_ep >= 0) epoll_ctl(srd_ep, EPOLL_CTL_DEL, srd_conn[i].fd, NULL);
    close(srd_conn[i].fd);
    srd_conn[i] = srd_conn[--srd_nconn];
}

static void srd_dispatch(struct wsrv_conn *c, const struct wsrv_hdr *h,
                         const uint8_t *pay)
{
    c->nreq++;
    int want_reply = (h->flags & WSRV_F_REPLY) != 0;
    switch (h->op) {
    case WSRV_OP_HELLO: {
        uint32_t theirs = (h->len >= 4) ? *(const uint32_t *)pay : 0;
        uint32_t mine = WSYS_VERSION;
        c->version = theirs;
        srv_reply(c->fd, h->tag, theirs == WSYS_VERSION ? 0 : -EPROTO,
                  &mine, sizeof mine);
        return;
    }
    case WSRV_OP_STAT: {
        char b[256];
        int n = snprintf(b, sizeof b,
                         "rd conns %llu live %d reads %llu full %llu "
                         "empty %llu bad %llu exists %llu\n",
                         (unsigned long long)srd_n_accept, srd_nconn,
                         (unsigned long long)srd_n_read,
                         (unsigned long long)srd_n_full,
                         (unsigned long long)srd_n_empty,
                         (unsigned long long)srd_n_bad,
                         (unsigned long long)srd_n_exist);
        if (n < 0) n = 0;
        srv_reply(c->fd, h->tag, n, b, (uint32_t)n);
        return;
    }
    case WSRV_OP_READ: {
        srd_n_read++;
        int leaf = (h->flags >> WSRV_LEAF_SHIFT) & 0xff;
        struct hamwsys_file f;
        int rc = srd_answer(c, leaf, h->wid, h->flags, &f);
        if (rc < 0) {
            srd_n_bad++;
            free(f.snap);
            srv_reply(c->fd, h->tag, (int32_t)rc, NULL, 0);
            return;
        }
        uint32_t n = (uint32_t)f.snaplen;
        if (n > WSRV_MAXPAY) n = WSRV_MAXPAY;
        srv_reply(c->fd, h->tag, (int32_t)n, f.snap, n);
        free(f.snap);
        return;
    }
    default:
        /* A MUTATION SENT HERE IS REFUSED, NOT FORWARDED.  See WHAT IT MAY
         * NOT DO above: two writers to the window table would give up the
         * same-iteration ordering stage 2 measured, and a read server that
         * quietly grew a write path is how a boundary stops being one. */
        srd_n_bad++;
        if (want_reply) srv_reply(c->fd, h->tag, -ENOSYS, NULL, 0);
        return;
    }
}

/* The child's whole life.  Never returns. */
static void srd_serve(void) __attribute__((noreturn));
static void srd_serve(void)
{
    for (;;) {
        struct epoll_event ev[WSRV_CONN_MAX + 1];
        /* A REAL BLOCK, and it is the entire point of this process.  The
         * frame-loop server polls with a 0 ms timeout because it has a frame
         * to get back to; this one has nothing else to do, so a request wakes
         * it immediately instead of at the next frame boundary. */
        int n = epoll_wait(srd_ep, ev, (int)(sizeof ev / sizeof ev[0]), -1);
        if (n < 0) { if (errno == EINTR) continue; _exit(0); }
        for (int i = 0; i < n; i++) {
            if (ev[i].data.fd == srd_lfd) {
                for (;;) {
                    int cfd = accept4(srd_lfd, NULL, NULL,
                                      SOCK_NONBLOCK | SOCK_CLOEXEC);
                    if (cfd < 0) break;
                    /* The read server's ceiling is SEPARATE from the mutation
                     * socket's -- a desktop has two budgets, not one -- and
                     * refusing here is the more expensive of the two, because
                     * the client that falls back reads the window table out
                     * of shared memory and snap_windows() answers everybody
                     * IN FULL.  See srv_route_read. */
                    if (srd_nconn >= WSRV_CONN_MAX) {
                        srv_cap_refused("rd", ++srd_n_capref);
                        close(cfd); continue;
                    }
                    /* SO_PEERCRED, at accept, exactly as the mutation server
                     * takes it -- the one fact a client cannot forge, and the
                     * only thing the enumeration policy above is allowed to
                     * be decided on. */
                    struct ucred uc;
                    socklen_t ul = sizeof uc;
                    memset(&uc, 0, sizeof uc);
                    (void)getsockopt(cfd, SOL_SOCKET, SO_PEERCRED, &uc, &ul);
                    struct wsrv_conn *c = &srd_conn[srd_nconn++];
                    memset(c, 0, sizeof *c);
                    c->fd = cfd; c->uid = uc.uid; c->gid = uc.gid;
                    c->pid = uc.pid;
                    c->cid = srv_next_cid++;
                    struct epoll_event e = { .events = EPOLLIN,
                                             .data.fd = cfd };
                    if (epoll_ctl(srd_ep, EPOLL_CTL_ADD, cfd, &e) < 0) {
                        close(cfd); srd_nconn--; continue;
                    }
                    srd_n_accept++;
                }
                continue;
            }
            int k = -1;
            for (int j = 0; j < srd_nconn; j++)
                if (srd_conn[j].fd == ev[i].data.fd) { k = j; break; }
            if (k < 0) continue;
            for (;;) {
                uint8_t buf[sizeof(struct wsrv_hdr) + WSRV_MAXPAY];
                ssize_t r = recv(srd_conn[k].fd, buf, sizeof buf, MSG_DONTWAIT);
                if (r < 0) break;
                if (r == 0) { srd_conn_drop(k); break; }
                if ((size_t)r < sizeof(struct wsrv_hdr)) { srd_n_bad++; continue; }
                struct wsrv_hdr h;
                memcpy(&h, buf, sizeof h);
                if (h.magic != WSRV_MAGIC_RQ || h.len > WSRV_MAXPAY
                    || (size_t)r != sizeof h + h.len) { srd_n_bad++; continue; }
                srd_dispatch(&srd_conn[k], &h, buf + sizeof h);
            }
        }
    }
}

/* Fork the read server.  Called from hamwsys_srv_listen, in wsysd, once. */
static void srd_fork(void)
{
    if (srd_pid > 0 || !seg_id_known) return;

    struct sockaddr_un a;
    socklen_t alen = srd_addr(&a);
    if (!alen) return;
    /* THE SOCKET IS BOUND IN THE PARENT, BEFORE THE FORK, so that a bind
     * failure -- another wsysd already serving this segment -- is reported by
     * the process that can still say something useful, and so that a client
     * dialling immediately after listen() returns cannot find the name
     * missing.  A child that bound it after being scheduled would leave a
     * window in which the read name does not exist and every client silently
     * fell back to the unmediated in-process read. */
    int fd = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (fd < 0) return;
    if (bind(fd, (struct sockaddr *)&a, alen) < 0 || listen(fd, 32) < 0) {
        fprintf(stderr, "wsys: cannot serve READS for segment %llu.%llu (%s): "
                        "every client will read the segment directly, which is "
                        "NOT mediated.\n",
                (unsigned long long)seg_dev, (unsigned long long)seg_ino,
                strerror(errno));
        close(fd);
        return;
    }
    int ep = epoll_create1(EPOLL_CLOEXEC);
    if (ep < 0) { close(fd); return; }
    struct epoll_event e = { .events = EPOLLIN, .data.fd = fd };
    if (epoll_ctl(ep, EPOLL_CTL_ADD, fd, &e) < 0) { close(ep); close(fd); return; }

    fflush(NULL);                              /* no doubled stdio in the child */
    pid_t p = fork();
    if (p < 0) {
        fprintf(stderr, "wsys: cannot fork the read server (%s): reads stay "
                        "unmediated.\n", strerror(errno));
        close(ep); close(fd);
        return;
    }
    if (p > 0) {
        /* THIS CHILD IS OURS.  The orphan reaper in user/linux-syscalls.c
         * reaps corpses this process did not create; a read server that is
         * never registered would be one of those the moment a compositor ran
         * as PID 1 or as a subreaper.  Nothing does today, and the cost of
         * saying so is one call. */
        hamnix_own_child_remember((int32_t)p);
        /* The parent keeps NEITHER.  Holding the listening socket open in the
         * compositor would leave the read name bound after the child died,
         * with nothing behind it -- clients would connect and hang. */
        close(ep); close(fd);
        srd_pid = p;
        fprintf(stderr, "wsys: read server pid %ld serving /dev/wsys reads for "
                        "segment %llu.%llu, OFF the frame loop\n",
                (long)p, (unsigned long long)seg_dev,
                (unsigned long long)seg_ino);
        return;
    }

    /* ---- the child ---- */
    /* SET BEFORE ANYTHING ELSE, because it is what keeps this process a READER.
     * See srd_is_child's declaration: stage 9 routes the directory, and the
     * directory's in-process answer REAPS DEAD WINDOWS. */
    srd_is_child = 1;
    srd_lfd = fd;
    srd_ep  = ep;
    srv_lfd = -1;                    /* the frame loop's socket is not ours */
    srv_ep  = -1;
    srd_nconn = 0;
    /* DIE WITH THE COMPOSITOR.  Then re-check: if wsysd exited between the
     * fork and this prctl, the signal has already been missed and getppid()
     * is 1 -- a read server outliving the window system it answers about
     * would keep the name bound and answer questions about a segment nobody
     * paints. */
    prctl(PR_SET_PDEATHSIG, SIGKILL, 0, 0, 0);
    if (getppid() == 1) _exit(0);
    /* EVERY INHERITED DESCRIPTOR GOES.  wsysd holds /dev/fb, possibly a DRM
     * master fd, evdev nodes, client pipes and the frame-loop listener; this
     * process needs none of them and a stray reference to a DRM file
     * description would keep master alive past the compositor's own exit. */
    for (int i = 3; i < 4096; i++)
        if (i != srd_lfd && i != srd_ep) close(i);
    srd_serve();
}

/* ---------------------------------------------------------------- client -- */

static int      srv_fd     = -1;
static int      srv_tried  = 0;
static uint32_t srv_tag    = 0;
/* THE uid THE CONNECTION WAS DIALLED AS, and why it has to be remembered.
 *
 * SO_PEERCRED IS SAMPLED AT connect(2) AND NEVER AGAIN.  A process that dials
 * the server and THEN drops privilege keeps a connection the mediator still
 * answers for its OLD uid -- so a shell that spawned one external command
 * before /etc/rc.de-user reaches `setuid 1001` would go on acting as the host
 * owner for the life of the process, and everything it handed that connection
 * to would inherit that.  Capping it at the row (WSRV_F_ADOPT) is not the fix;
 * noticing is.  A connection that was INHERITED is exempt: it is the capability
 * this process was handed, and re-dialling would throw it away. */
static uid_t    srv_dial_uid;
static int      srv_fd_adopted;

/* THE SERVER WAS THERE AND TURNED THIS PROCESS AWAY, which is a different
 * fact from "nothing is serving" and used to be reported as a third thing
 * that is true of neither.
 *
 * WHY THE OLD MESSAGE WAS WRONG, because the mechanism is not obvious.  Both
 * listeners are `listen(fd, 32)`, so a client dialling a server whose table
 * is full CONNECTS SUCCESSFULLY -- the kernel queues it in the backlog and
 * connect(2) returns 0.  The accept-and-close happens afterwards, inside the
 * server's loop.  So the failure surfaces as a RESET DURING HELLO, and the
 * dial path treated an unanswered HELLO as a version disagreement: it printed
 * "the server ... speaks version 0, this client speaks 8" with `theirs` still
 * the zero it was initialised to.  There was no disagreement.  Both sides
 * spoke 8 and the table was full.
 *
 * That sent every reader at WSYS_VERSION -- the one number in this file that
 * costs 92 of 124 packages to change -- for a fault that is WSRV_CONN_MAX, a
 * process-static array in wsysd that is in no shared struct and costs a
 * recompile.  tests/linux/wsys_srv_ceiling.sh asserts on the TEXT for that
 * reason: a wrong explanation is not a smaller defect than no explanation.
 *
 * The two cases are cleanly separable and this is where they separate:
 *   connect(2) FAILED          -> nothing is serving this segment.  Fall back;
 *                                 many gates run HAMWSYS_SERVER=1 with no
 *                                 wsysd and must keep working.
 *   connect(2) SUCCEEDED, HELLO unanswered
 *                              -> a server is there and refused us.  Say so,
 *                                 record it, and on the READ socket REFUSE
 *                                 rather than fall back. */
static int      srv_rd_cap_refused;

static void srv_conn_refuse_note(const char *sockname, int *once)
{
    int saved = errno;
    if (!*once) {
        *once = 1;
        fprintf(stderr,
                "wsys: the server for segment %llu.%llu is at its connection "
                "limit (WSRV_CONN_MAX=%d) and refused this process on '%s'. "
                "This is NOT a version disagreement -- both sides speak %u. "
                "%s\n",
                (unsigned long long)seg_dev, (unsigned long long)seg_ino,
                (int)WSRV_CONN_MAX, sockname, (unsigned)WSYS_VERSION,
                sockname[0] == 'r'
                  ? "The window list is REFUSED rather than answered from "
                    "shared memory, because falling back there would hand a "
                    "caller the full table the mediator had just denied it."
                  : "This process is using the in-process path, which is NOT "
                    "mediated.");
    }
    /* ...AND ONCE WHERE THE SYSTEM CAN SEE IT.  stderr on a DE-spawned
     * program is a log nobody opens; <seg>.refused is the file the version
     * refusal already writes and the panel's notice path already reads, so
     * one reader finds both kinds of turning-away in one place. */
    char line[256], boot[64];
    seg_boot_id(boot, sizeof boot);
    int n = snprintf(line, sizeof line,
                     "connrefused sock=%s cap=%d pid=%ld boot=%s\n",
                     sockname, (int)WSRV_CONN_MAX, (long)getpid(), boot);
    if (n > 0 && n < (int)sizeof line) seg_refuse_append(seg_path, line);
    errno = saved;
}

/* Defined below srv_call, which it uses; declared here because srv_dial needs
 * it while the connection exists but is not yet blessed. */
static int srv_call_locked_hello(uint32_t *mine, uint32_t *theirs, int64_t *rc);
static int srv_call_on(int fd, uint16_t op, uint16_t xflags, int32_t wid,
                       const void *pay, uint32_t len, void *out, uint32_t outcap,
                       uint32_t *outlen, int64_t *rc);

/* Dial the server, once per process.  Returns the connection or -1.
 *
 * A FAILED DIAL IS SAID OUT LOUD AND THEN FALLEN BACK FROM.  During stage 1
 * both paths exist by design, so falling back to the in-process path is
 * correct — but doing it silently would mean a mis-set flag looks exactly
 * like a working boundary, which is the failure shape this project keeps
 * paying for.  When the in-process path is removed in stage 4 this becomes a
 * hard refusal, and the WSYS_VERSION bump is what makes an old client refuse
 * rather than mmap the segment and bypass the mediator entirely. */
/* THE INHERITED CONNECTION, AND WHY IT IS AN ENVIRONMENT VARIABLE.
 *
 * Stage 5's rule is that a routed mutation must arrive on the connection that
 * holds the window's row, so a process spawned INTO somebody else's window has
 * exactly one way in: be handed that connection.  A connected SOCK_SEQPACKET
 * descriptor survives fork(2) and execve(2) once FD_CLOEXEC is off, and its
 * SO_PEERCRED stays that of the process that dialled -- which is precisely the
 * property wanted, because that process is the one the row is stamped against.
 *
 * The number travels in HAMWSYS_SRV_FD because execve replaces everything else
 * about the child: argv belongs to the program, and a spawner that had to
 * rewrite its child's argv could not hand a connection to a program it did not
 * write.  The environment is the one channel every spawn path in this tree
 * already carries (/etc/rc.de-user hands HAMNIX_DE_PROG down the same way).
 *
 * THE ADOPTION IS ONE GENERATION, AND THAT IS THE POINT.  An adopting process
 * immediately sets FD_CLOEXEC and unsets the variable, so the capability stops
 * with it unless it deliberately hands it on again.  Inheritance that
 * propagated by itself would be the ancestry walk rebuilt out of descriptors.
 */
static int srv_adopt_inherited(void)
{
    const char *e = getenv("HAMWSYS_SRV_FD");
    if (!e || !e[0]) return -1;
    char *end = NULL;
    long v = strtol(e, &end, 10);
    unsetenv("HAMWSYS_SRV_FD");
    if (!end || *end || v < 0 || v > 1024 * 1024) return -1;
    int fd = (int)v;
    /* IT MUST BE A CONNECTED SEQPACKET SOCKET, checked and not assumed.  A
     * stale number names whatever descriptor the process happens to have at
     * that index -- a log file, the framebuffer -- and writing the protocol
     * into it would corrupt an unrelated file while looking like a dialled
     * connection. */
    int type = 0; socklen_t tl = sizeof type;
    if (getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &tl) < 0
        || type != SOCK_SEQPACKET) {
        fprintf(stderr, "wsys: HAMWSYS_SRV_FD=%d is not a connected server "
                        "socket (%s): dialling instead.\n",
                fd, strerror(errno));
        return -1;
    }
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    return fd;
}

static int srv_dial(void)
{
    if (srv_fd >= 0) return srv_fd;
    if (!srv_enabled() || srv_is_server || srv_tried) return -1;
    srv_tried = 1;

    /* BEFORE seg_id_known, deliberately: an inherited connection is already
     * connected to the right server, so it needs no segment identity to find
     * one.  A handed-down descriptor is also the only way a process that never
     * attaches the segment could speak to the server at all. */
    int inh = srv_adopt_inherited();
    if (inh >= 0) {
        srv_fd = inh;
        srv_fd_adopted = 1;
        srv_dial_uid = geteuid();
        uint32_t mine = WSYS_VERSION, theirs = 0;
        int64_t rc = 0;
        uint32_t got = 0;
        /* WSRV_F_ADOPT: tells the server this connection was inherited, which
         * costs it hostowner() for ever.  See hostowner(). */
        if (srv_call_on(srv_fd, WSRV_OP_HELLO, WSRV_F_ADOPT, 0,
                        &mine, sizeof mine, &theirs, sizeof theirs,
                        &got, &rc) < 0 || rc < 0) {
            fprintf(stderr, "wsys: the inherited server connection did not "
                            "answer HELLO (server speaks %u, this client %u) "
                            "-- using the in-process path.\n",
                    (unsigned)theirs, (unsigned)WSYS_VERSION);
            close(srv_fd);
            srv_fd = -1;
            return -1;
        }
        return srv_fd;
    }
    if (!seg_id_known) return -1;

    struct sockaddr_un a;
    socklen_t alen = srv_addr(&a);
    if (!alen) return -1;
    int fd = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
    if (fd < 0) return -1;
    if (connect(fd, (struct sockaddr *)&a, alen) < 0) {
        fprintf(stderr, "wsys: HAMWSYS_SERVER=1 but nothing is serving segment "
                        "%llu.%llu (%s): this process is using the in-process "
                        "path, which is NOT mediated.\n",
                (unsigned long long)seg_dev, (unsigned long long)seg_ino,
                strerror(errno));
        close(fd);
        return -1;
    }
    srv_fd = fd;
    srv_fd_adopted = 0;
    srv_dial_uid = geteuid();

    uint32_t mine = WSYS_VERSION, theirs = 0;
    int64_t rc = 0;
    /* TWO FAILURES, TWO SENTENCES.  `< 0` is "no reply came back at all",
     * which after a SUCCESSFUL connect(2) means the server accepted us and
     * closed -- the connection ceiling.  `rc < 0` is the server ANSWERING with
     * a refusal, which is the version case and the only one that may name a
     * version.  Collapsing them printed "speaks version 0" at a server that
     * speaks 8. */
    int hello = srv_call_locked_hello(&mine, &theirs, &rc);
    if (hello < 0) {
        static int said;
        srv_conn_refuse_note("srv", &said);
        close(srv_fd);
        srv_fd = -1;
        return -1;
    }
    if (rc < 0) {
        fprintf(stderr, "wsys: the server for segment %llu.%llu speaks version "
                        "%u, this client speaks %u -- refusing the connection "
                        "and using the in-process path.\n",
                (unsigned long long)seg_dev, (unsigned long long)seg_ino,
                (unsigned)theirs, (unsigned)WSYS_VERSION);
        close(srv_fd);
        srv_fd = -1;
        return -1;
    }
    return srv_fd;
}

/* A CONNECTION IS ONLY GOOD FOR THE uid THAT DIALLED IT.
 *
 * Called at the top of every routed operation.  If this process's effective
 * uid has changed since the dial, the cached connection is stale in the one
 * way that matters -- the server would keep answering for the identity we no
 * longer have -- so it is dropped and dialled again, and the new connection
 * carries the credentials we actually hold now.
 *
 * geteuid(2) per routed operation is the cost, and it is affordable at the
 * worst rate this system has ever produced: 2050 ops/s against a syscall that
 * does not leave the kernel's own task struct.  The alternative -- checking
 * only at the handoff -- would leave every ordinary write after a privilege
 * drop acting for the old uid, which is the same hole seen from one step back.
 *
 * AN ADOPTED CONNECTION IS NEVER RE-DIALLED: it is not ours to replace.  It is
 * the capability a spawner handed us, it already answers hostowner() = 0, and
 * dialling our own would silently lose the window we were spawned into. */
static void srv_redial_if_uid_changed(void)
{
    if (srv_fd < 0 || srv_fd_adopted) return;
    if (geteuid() == srv_dial_uid) return;
    fprintf(stderr, "wsys: this process dialled the window server as uid %ld "
                    "and is now uid %ld; re-dialling so the mediator answers "
                    "for the identity it actually has.\n",
            (long)srv_dial_uid, (long)geteuid());
    close(srv_fd);
    srv_fd = -1;
    srv_tried = 0;
    (void)srv_dial();
}

/* ==================================================================
 * THE HANDOFF — the toolkit's half of stage 5
 * ==================================================================
 * A spawner that owns a window and is about to run a program INTO it calls
 * this with `on` non-zero, spawns, and calls it again with zero.  Between the
 * two calls the server connection is inheritable and named in the
 * environment, so the child adopts it in srv_dial() and its mutations arrive
 * on the connection that holds the row.
 *
 * IT DIALS IF IT HAS TO, and that is what makes it usable from a process that
 * has never touched /dev/wsys -- /bin/hamsh, which is what every DE window is
 * stamped against, opens no window file at all.  A hand-off from a process
 * with no connection would otherwise silently hand nothing over and the child
 * would be refused, which is the success-shaped failure this tree refuses.
 *
 * CALL IT AFTER DROPPING PRIVILEGE, NOT BEFORE, and this is the sharp edge of
 * the whole mechanism: SO_PEERCRED is sampled at connect(2), so a connection
 * dialled while still the host owner carries the host owner's uid into every
 * process it is handed to.  The WSRV_F_ADOPT flag the child sends means the
 * server refuses hostowner() on an adopted connection, so the damage is capped
 * at the row itself rather than the whole chrome surface -- but the connection
 * still ACTS FOR the dialling process's window, so the ordering is a
 * requirement and not a preference.
 *
 * Returns 0 if the child will inherit a connection, -1 if there is nothing to
 * hand over (no server, flag unset, dial refused).  The caller may spawn
 * either way; -1 means the child gets what it gets today. */
int hamwsys_srv_handoff(int on)
{
    if (!on) {
        unsetenv("HAMWSYS_SRV_FD");
        if (srv_fd >= 0) fcntl(srv_fd, F_SETFD, FD_CLOEXEC);
        return 0;
    }
    if (!srv_enabled() || srv_is_server) return -1;
    if (srv_fd < 0 && shm_attach() < 0) return -1;
    if (srv_dial() < 0) return -1;
    srv_redial_if_uid_changed();
    if (srv_fd < 0) return -1;
    if (fcntl(srv_fd, F_SETFD, 0) < 0) return -1;
    char n[16];
    snprintf(n, sizeof n, "%d", srv_fd);
    if (setenv("HAMWSYS_SRV_FD", n, 1) < 0) return -1;
    return 0;
}

/* Send one message.  `flags` carries WSRV_F_REPLY when the caller will block.
 * Returns 0, or -1 with errno. */
static int srv_send_on(int fd, uint16_t op, uint16_t flags, int32_t wid,
                       uint32_t tag, const void *pay, uint32_t len)
{
    if (fd < 0 || len > WSRV_MAXPAY) { errno = EINVAL; return -1; }
    struct wsrv_hdr h = { WSRV_MAGIC_RQ, op, flags, tag, wid, len };
    struct iovec iov[2];
    iov[0].iov_base = &h; iov[0].iov_len = sizeof h;
    iov[1].iov_base = (void *)pay; iov[1].iov_len = len;
    struct msghdr m;
    memset(&m, 0, sizeof m);
    m.msg_iov = iov;
    m.msg_iovlen = len ? 2 : 1;
    ssize_t r = sendmsg(fd, &m, MSG_NOSIGNAL);
    return r < 0 ? -1 : 0;
}

/* THE FD IS A PARAMETER BECAUSE THERE ARE TWO SERVERS, not because anything
 * is configurable.  Stage 4 puts reads on a second connection to a process
 * that never paints; everything else still goes to the frame loop, and the
 * unadorned names below mean "the frame loop's connection" so that no
 * existing call site had to be re-read to be trusted. */
static void srv_redial_if_uid_changed(void);

static int srv_send(uint16_t op, uint16_t flags, int32_t wid, uint32_t tag,
                    const void *pay, uint32_t len)
{
    /* THE RE-DIAL BELONGS HERE AND NOWHERE HIGHER, and a gate is what moved
     * it.  It used to sit in srv_route_write() -- the client's ordinary write
     * path -- which a process that skips the local check simply does not call.
     * tests/linux/wsys_srv_identity.sh's arm D dialled as a host owner,
     * dropped to uid 1002, sent the message straight down the socket, AND THE
     * MEDIATOR ACCEPTED IT: the title changed to PWNED-BY-A-STRANGER.  A check
     * that only runs on the path an honest client takes is advice.  This is the
     * one funnel every routed message goes through, so the identity is
     * re-sampled for all of them.
     *
     * No recursion: srv_dial()'s own HELLO goes through srv_call_on ->
     * srv_send_on and never reaches this wrapper. */
    srv_redial_if_uid_changed();
    return srv_send_on(srv_fd, op, flags, wid, tag, pay, len);
}

/* FIRE AND FORGET, and this is the measurement talking rather than taste.
 * Per-op cost falls 6.30 us one-at-a-time -> 3.14 at 4 -> 2.31 at 16 ->
 * 2.37 at 64 (tests/linux/wsys_rtt_probe.c).  It is the WAITING that costs,
 * not the volume, so anything that returns no data does not wait.  A client
 * repaint is 3 ops; at 2.3 us that is 7 us of a 0.3 ms input-to-pixel budget
 * instead of 19 us. */
/* THE SEND BLOCKS IF THE SERVER FALLS BEHIND, and that is a choice, not an
 * oversight.  MSG_DONTWAIT here would turn a full socket buffer into a
 * SILENTLY DISCARDED MUTATION -- a window that does not move, with nothing on
 * anyone's stderr, which is the failure shape this device fights everywhere
 * else.  Blocking makes the pressure visible as a stalled client instead.
 * Measured, the pressure does not arise at any rate this system produces: 256
 * back-to-back sends drain in 509 us with none lost, and the sustained arm
 * runs 2050 ops/s -- the worst load ever measured here -- through a default
 * SO_RCVBUF that holds thousands of these messages.  Stage 2 owns the
 * question of what to do if that ever stops being true; today it would be a
 * mechanism guarding against a condition that has not been observed. */
static int srv_post(uint16_t op, int32_t wid, const void *pay, uint32_t len)
{
    if (srv_fd < 0) return -1;
    return srv_send(op, 0, wid, ++srv_tag, pay, len);
}

/* Block for one reply.  Discards anything that is not the reply being waited
 * for, which is what makes fire-and-forget safe to mix with blocking calls on
 * one connection: an out-of-band error (tag 0) arriving mid-wait is reported
 * and stepped over rather than mistaken for the answer. */
static int srv_wait_on(int fd, uint32_t tag, void *out, uint32_t outcap,
                       uint32_t *outlen, int64_t *rc, int timeout_ms)
{
    uint8_t buf[sizeof(struct wsrv_rep) + WSRV_MAXPAY];
    for (;;) {
        struct pollfd p = { fd, POLLIN, 0 };
        int pr = poll(&p, 1, timeout_ms);
        if (pr == 0) { errno = ETIMEDOUT; return -1; }
        if (pr < 0) { if (errno == EINTR) continue; return -1; }
        ssize_t r = recv(fd, buf, sizeof buf, 0);
        if (r <= 0) { errno = r == 0 ? ECONNRESET : errno; return -1; }
        if ((size_t)r < sizeof(struct wsrv_rep)) continue;
        struct wsrv_rep rep;
        memcpy(&rep, buf, sizeof rep);
        if (rep.magic != WSRV_MAGIC_RP) continue;
        if (rep.tag == 0) {
            /* An out-of-band error for a fire-and-forget message.  Stage 2
             * routes these to the client's own event ring, which it is
             * already draining; stage 1 has no event to attach them to, so
             * they are said on stderr rather than dropped. */
            struct { uint16_t op; int32_t rc; } b = { 0, 0 };
            if ((size_t)r >= sizeof rep + sizeof b)
                memcpy(&b, buf + sizeof rep, sizeof b);
            fprintf(stderr, "wsys: the server refused op %u: %s\n",
                    (unsigned)b.op, strerror(b.rc < 0 ? -b.rc : b.rc));
            continue;
        }
        if (rep.tag != tag) continue;          /* a stale reply; step over it */
        uint32_t n = rep.len;
        if (n > outcap) n = outcap;
        if (out && n) memcpy(out, buf + sizeof rep, n);
        if (outlen) *outlen = n;
        if (rc) *rc = rep.rc;
        return 0;
    }
}

static int srv_call_on(int fd, uint16_t op, uint16_t xflags, int32_t wid,
                       const void *pay, uint32_t len, void *out,
                       uint32_t outcap, uint32_t *outlen, int64_t *rc)
{
    if (fd < 0) { errno = ENOTCONN; return -1; }
    uint32_t tag = ++srv_tag;
    if (tag == 0) tag = ++srv_tag;             /* 0 is reserved for OOB errors */
    if (srv_send_on(fd, op, (uint16_t)(WSRV_F_REPLY | xflags), wid, tag,
                    pay, len) < 0) return -1;
    /* A BOUNDED WAIT, not an unbounded one.  A wedged compositor must produce
     * a diagnosable timeout rather than a client that hangs for ever with
     * nothing on stderr — the failure shape this device fights everywhere
     * else. */
    return srv_wait_on(fd, tag, out, outcap, outlen, rc, 5000);
}

static int srv_call(uint16_t op, int32_t wid, const void *pay, uint32_t len,
                    void *out, uint32_t outcap, uint32_t *outlen, int64_t *rc)
{
    return srv_call_on(srv_fd, op, 0, wid, pay, len, out, outcap, outlen, rc);
}

/* HELLO has to exist before srv_call is usable, because srv_dial calls it
 * while srv_fd is set but the connection is not yet blessed. */
static int srv_call_locked_hello(uint32_t *mine, uint32_t *theirs, int64_t *rc)
{
    uint32_t got = 0;
    if (srv_call(WSRV_OP_HELLO, 0, mine, sizeof *mine,
                 theirs, sizeof *theirs, &got, rc) < 0) {
        fprintf(stderr, "wsys: the server did not answer the version "
                        "handshake (%s).\n", strerror(errno));
        return -1;
    }
    return 0;
}

/* THE CLIENT'S DIAL POINT.  Called from hamwsys_open, after shm_attach: a
 * process that never touches the window system never opens a socket to it,
 * and a process that does gets exactly one connection for its lifetime. */
static void srv_client_tick(void)
{
    if (!srv_enabled() || srv_is_server || srv_fd >= 0 || srv_tried) return;
    (void)srv_dial();
}

/* ==================================================================
 * STAGE 2 — ROUTING THE MUTATIONS
 * ==================================================================
 * Returns 1 if this write was handed to the server, 0 if the caller should
 * take the in-process path.  Never returns a failure: a refused mutation
 * comes back OUT OF BAND, on the connection the client is already draining,
 * because waiting for a yes/no is the expensive pattern -- 6.30 us one at a
 * time against 2.31 us at a burst of 16 -- and a mutation that returns no
 * data has nothing to wait for.
 *
 * WHY THE CLIENT STILL CHECKS PERMISSION LOCALLY DURING STAGE 2, and why
 * that is not the mediator being decorative.  Both paths exist while the flag
 * is a development switch, so the in-process check is still real code with
 * the segment still mapped; leaving it in place means routing changes no
 * behaviour, which is the property every stage before the last one has to
 * hold.  The server's check is the AUTHORITATIVE one -- it is answered about
 * the caller's kernel-supplied credentials, and it is what survives stage 4
 * when the in-process path and the client's mapping both go.
 */
/* WHICH `wctl` VERB IS THIS, AND HOW MUST IT TRAVEL?
 *
 * Returns 1 if the write is routable and sets *blocking, 0 if it must be left
 * to the in-process path.  The leading-token parse is the SAME one
 * hamwsys_write_inner's HAMWSYS_WIN_WCTL arm makes -- skip blanks, take one
 * token -- because two parsers that disagree about what a write says are two
 * different files, and this one decides which path the write takes.
 *
 * wctl is one verb per write (unlike wid/ctl, which is line-oriented), so
 * there is exactly one answer per message and no line loop here.
 *
 * `version` BLOCKS.  Everything else in this device that returns no data is
 * fire-and-forget, and this is the one exception, for a reason recorded at
 * WSRV_LEAF_WIN_WCTL in linux-wsys.h: the client acts on the return value of
 * that write.  hamui_set_protocol_v2_dims sets h_v2_active on it, and an
 * application that believes it is v2 while the compositor paints it as v0 is
 * the failure this whole file exists to refuse.
 *
 * AN UNKNOWN VERB IS NOT ROUTED.  wctl is a closed set: `wibble` is -EINVAL
 * and changes nothing, and the in-process path already answers that without a
 * round trip.  Routed fire-and-forget it would answer SUCCESS to a typo, which
 * is the same defect as the version one wearing different clothes. */
static int srv_wctl_verb(const uint8_t *buf, uint64_t n, int *blocking)
{
    const char *s = (const char *)buf;
    size_t ln = (size_t)n;
    while (ln && (s[ln - 1] == '\n' || s[ln - 1] == '\r')) ln--;
    size_t p = 0;
    while (p < ln && (s[p] == ' ' || s[p] == '\t')) p++;
    size_t vs = p;
    while (p < ln && s[p] != ' ' && s[p] != '\t') p++;
    size_t vlen = p - vs;
    *blocking = 0;
    if (vlen == 7 && !strncmp(s + vs, "version", 7)) { *blocking = 1; return 1; }
    if (vlen == 5 && !strncmp(s + vs, "focus",  5)) return 1;
    if (vlen == 6 && !strncmp(s + vs, "resize", 6)) return 1;
    if (vlen == 4 && !strncmp(s + vs, "move",   4)) return 1;
    return 0;
}

static int srv_route_write(const struct hamwsys_file *f, const uint8_t *buf,
                           uint64_t n, int64_t *rcout)
{
    /* A ZERO-LENGTH MESSAGE IS MEANINGFUL FOR EXACTLY ONE LEAF.  Everywhere
     * else an empty write is nothing to route; on `scene` it is the OPEN --
     * the frame boundary with no display list behind it yet -- and dropping it
     * here would mean a client that opens, writes nothing and commits publishes
     * the PREVIOUS frame instead of an empty one.
     *
     * CHECKED FOR wctl RATHER THAN ASSUMED: an empty wctl write returns 0 from
     * the in-process arm after its own ENOENT/EPERM checks and touches
     * nothing, so leaving it here changes no outcome and costs no message.
     *
     * `*rcout` IS THE WRITE'S RETURN VALUE when this returns 1.  For every
     * fire-and-forget leaf that is the byte count, because the send is the
     * whole of what happened; for `wctl version` it is the SERVER'S answer.
     * See srv_wctl_verb below for why one verb is not like the others. */
    if (srv_fd < 0 || n > WSRV_MAXPAY) return 0;
    if (n == 0 && !(f->leaf == HAMWSYS_WIN_SCENE && f->srv_newframe)) return 0;
    int leaf;
    switch (f->leaf) {
    case HAMWSYS_CTL:       leaf = WSRV_LEAF_CTL;       break;
    case HAMWSYS_WIN_CTL:   leaf = WSRV_LEAF_WIN_CTL;   break;
    case HAMWSYS_WIN_SCENE: leaf = WSRV_LEAF_WIN_SCENE; break;
    case HAMWSYS_WIN_WCTL:  leaf = WSRV_LEAF_WIN_WCTL;  break;
    default: return 0;
    }
    /* NEWWINDOW IS NOT ROUTED HERE, and must not be: it returns data, and it
     * has to bind a keystroke channel IN THIS PROCESS.  It goes through
     * srv_newwindow below instead.  Checked on the leading token of the first
     * line, because a ctl write may carry several verbs. */
    if (leaf == WSRV_LEAF_CTL && n >= 9 && !memcmp(buf, "newwindow", 9))
        return 0;
    uint16_t flags = (uint16_t)(leaf << WSRV_LEAF_SHIFT);
    /* THE FRAME BOUNDARY RIDES ON THE FIRST WRITE AFTER THE OPEN, and it is
     * per-OPEN state, so it lives in the file handle rather than in a global:
     * a client with two scenes open at once (the compositor is one) would
     * otherwise start the wrong window's frame.  Cleared as it is spent, so
     * the second write of a frame appends, which is what `scene` means. */
    if (leaf == WSRV_LEAF_WIN_SCENE && f->srv_newframe) {
        flags |= WSRV_F_NEWFRAME;
        ((struct hamwsys_file *)f)->srv_newframe = 0;
    }
    if (leaf == WSRV_LEAF_WIN_WCTL) {
        int blocking = 0;
        if (!srv_wctl_verb(buf, n, &blocking)) return 0;
        if (blocking) {
            /* THE IDENTITY RE-SAMPLE HAS TO BE ASKED FOR HERE.  srv_send()
             * carries it for every fire-and-forget message, but srv_call_on()
             * reaches srv_send_on() directly (so that srv_dial's own HELLO
             * cannot recurse), and a blocking mutation that skipped it would
             * be exactly the hole stage 6's arm D found: a connection dialled
             * before a setuid still answering for the uid that dialled it.
             * srv_newwindow -- the only other blocking mutation -- does the
             * same thing for the same reason. */
            srv_redial_if_uid_changed();
            if (srv_fd < 0) return 0;
            uint32_t got = 0;
            int64_t rc = 0;
            if (srv_call_on(srv_fd, WSRV_OP_WRITE, flags, f->wid, buf,
                            (uint32_t)n, NULL, 0, &got, &rc) < 0) {
                fprintf(stderr, "wsys: the server did not answer a routed "
                                "`wctl version` for window %d (%s); falling "
                                "back to the in-process path.\n",
                        (int)f->wid, strerror(errno));
                return 0;
            }
            /* THE SERVER'S ANSWER IS THE WRITE'S ANSWER, and that is the
             * entire reason this verb blocks.  A refusal reaches the caller as
             * a short write with errno set, exactly as the unrouted path
             * returns it, so a client that checks its write still learns the
             * truth. */
            if (rc < 0) errno = (int)-rc;
            if (rcout) *rcout = rc;
            return 1;
        }
    }
    if (srv_send(WSRV_OP_WRITE, flags, f->wid, ++srv_tag, buf, (uint32_t)n) < 0)
        return 0;                     /* the socket broke; fall back, loudly */
    if (rcout) *rcout = (int64_t)n;
    return 1;
}

/* `newwindow`, and the only mutation that waits.  Returns the wid, or -1 with
 * errno set, or -2 meaning "not routed, do it in process". */
static int32_t srv_newwindow(void)
{
    if (srv_fd >= 0) srv_redial_if_uid_changed();
    if (srv_fd < 0) return -2;
    int32_t wid = -1;
    uint32_t got = 0;
    int64_t rc = 0;
    if (srv_call(WSRV_OP_NEWWIN, 0, NULL, 0, &wid, sizeof wid, &got, &rc) < 0) {
        fprintf(stderr, "wsys: the server did not answer newwindow (%s); "
                        "falling back to the in-process path.\n",
                strerror(errno));
        return -2;
    }
    if (rc < 0 || got != sizeof wid || wid < 0) { errno = -rc ? (int)-rc : ENOSPC; return -1; }
    return wid;
}

/* ==================================================================
 * STAGE 4 — ROUTING THE READS
 * ==================================================================
 * A SECOND CONNECTION, DIALLED LAZILY.  Most clients never read any of these
 * three files: a terminal creates a window, writes ctl and draws.  The panel
 * reads /dev/wsys/windows a few times a second and every v2 client reads
 * /dev/wsys/screen once at startup.  So the read connection is opened on the
 * first routed read and not at hamwsys_open, which keeps a process that only
 * ever writes at exactly one socket, as stage 1 measured it.
 */
static int      srv_rfd    = -1;
static int      srv_rtried = 0;
/* THE READ SOCKET HAD NO uid GUARD, AND IT NEEDED ONE BEFORE STAGE 10 TOUCHED
 * IT -- this is a defect of stage 4's transport, found while routing `open`.
 *
 * srv_redial_if_uid_changed() has protected the MUTATION socket since stage 3a
 * for a reason that applies here word for word: SO_PEERCRED is sampled at
 * connect(2), so a connection dialled before /etc/rc.de-user's `setuid 1001`
 * carries the DIALLING uid into every decision the server makes afterwards.
 * On the read socket that is not merely wrong, it is the wrong DIRECTION: the
 * process that dials early is the privileged one, so a stale connection grants
 * the enumeration tier and every per-window read to a process that has since
 * dropped to a uid the policy would refuse.
 *
 * It mattered less while nothing but `windows`, `screen` and `pool` was routed
 * and the dial happened at the first routed READ -- a program that only writes
 * never dialled at all.  Stage 10 asks this socket a question at every OPEN of
 * a per-window leaf, so the dial now happens far earlier in far more
 * processes, and the window between dialling and dropping privilege is real. */
static uid_t    srv_rdial_uid;

static void srv_exists_forget_all(void);

static int srv_rdial(void)
{
    if (srv_rfd >= 0) return srv_rfd;
    if (!srv_enabled() || srv_is_server || srv_rtried) return -1;
    srv_rtried = 1;
    /* CLEARED PER ATTEMPT, so it names what THIS dial found and not what an
     * earlier one did.  srv_route_read fails closed on it, and a stale 1 left
     * over from a full table would make a later dial that failed because the
     * server is GONE refuse the read instead of falling back -- which is the
     * one case that must still fall back. */
    srv_rd_cap_refused = 0;
    if (!seg_id_known) return -1;
    struct sockaddr_un a;
    socklen_t alen = srd_addr(&a);
    if (!alen) return -1;
    int fd = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
    if (fd < 0) return -1;
    if (connect(fd, (struct sockaddr *)&a, alen) < 0) {
        /* SAID OUT LOUD, then fallen back from, exactly as srv_dial does.
         * During development both paths exist; a silent fallback here would
         * mean an unmediated enumeration that looks identical to a mediated
         * one, which is the failure shape this whole boundary is about. */
        fprintf(stderr, "wsys: HAMWSYS_SERVER=1 but nothing is serving READS "
                        "for segment %llu.%llu (%s): this process is reading "
                        "the segment directly, which is NOT mediated.\n",
                (unsigned long long)seg_dev, (unsigned long long)seg_ino,
                strerror(errno));
        close(fd);
        return -1;
    }
    uint32_t mine = WSYS_VERSION, theirs = 0, got = 0;
    int64_t rc = 0;
    /* The same split as srv_dial, and it matters MORE here.  On the mutation
     * socket an unmediated client writes what hamwsys_write's local check
     * already lets it write; on this one, falling back runs snap_windows()
     * out of shared memory, and snap_windows() answers EVERYBODY IN FULL. */
    int hello = srv_call_on(fd, WSRV_OP_HELLO, 0, 0, &mine, sizeof mine,
                            &theirs, sizeof theirs, &got, &rc);
    if (hello < 0) {
        static int said;
        srv_rd_cap_refused = 1;
        srv_conn_refuse_note("rd", &said);
        close(fd);
        /* THE CEILING IS TRANSIENT AND A VERSION IS NOT, so this one case
         * gets to try again.  srv_rtried exists because a client gets exactly
         * one connection for its lifetime, and every other way of failing
         * this dial is permanent -- a version disagreement will not resolve
         * itself and retrying it per read would be a syscall storm for
         * nothing.  A full table empties when a program exits.
         *
         * IT MATTERS MORE NOW THAT THE REFUSAL IS HARD.  Before this commit a
         * refused reader silently read shared memory for ever; now it gets
         * ECONNREFUSED, so leaving srv_rtried set would make a taskbar that
         * happened to start during a connection storm BLIND FOR THE REST OF
         * ITS LIFE -- trading a boundary that lapses under load for a desktop
         * that never recovers from it, which is not a better failure. */
        srv_rtried = 0;
        return -1;
    }
    if (rc < 0) {
        fprintf(stderr, "wsys: the read server for segment %llu.%llu speaks "
                        "version %u, this client speaks %u -- refusing it and "
                        "reading the segment directly.\n",
                (unsigned long long)seg_dev, (unsigned long long)seg_ino,
                (unsigned)theirs, (unsigned)WSYS_VERSION);
        close(fd);
        return -1;
    }
    srv_rfd = fd;
    srv_rdial_uid = geteuid();
    return srv_rfd;
}

/* The read socket's half of srv_redial_if_uid_changed().  Every routed read
 * calls it before it uses srv_rfd.  The existence cache goes with the
 * connection: a grant was made to the identity that asked, and the process no
 * longer has that identity. */
static void srv_rdial_if_uid_changed(void)
{
    if (srv_rfd < 0) return;
    if (geteuid() == srv_rdial_uid) return;
    fprintf(stderr, "wsys: this process dialled the READ server as uid %ld and "
                    "is now uid %ld; re-dialling so the enumeration policy "
                    "answers for the identity it actually has.\n",
            (long)srv_rdial_uid, (long)geteuid());
    close(srv_rfd);
    srv_rfd = -1;
    srv_rtried = 0;
    srv_exists_forget_all();
    (void)srv_rdial();
}

/* Answer one read from the server, into f->snap.  Returns 1 if the server
 * answered and f is filled, -1 if the server REFUSED and the open must fail
 * with errno already set, and 0 if the caller should take the in-process path.
 *
 * AN EMPTY ANSWER IS AN ANSWER, and this is the line the enumeration policy
 * lives or dies on.  A window-less caller gets zero bytes back and this
 * returns 1, so hamwsys_open reports an empty /dev/wsys/windows.  Returning 0
 * here for an empty reply would fall through to snap_windows() and hand the
 * caller the full list from shared memory -- a policy that denies nothing
 * while every counter says it refused.  `rc` is the byte count the server
 * decided on, so 0 is distinguishable from "no reply at all" (-1). */
static int srv_route_read(struct hamwsys_file *f)
{
    int leaf;
    switch (f->leaf) {
    case HAMWSYS_WINDOWS: leaf = WSRV_LEAF_WINDOWS; break;
    case HAMWSYS_SCREEN:  leaf = WSRV_LEAF_SCREEN;  break;
    case HAMWSYS_POOL:    leaf = WSRV_LEAF_POOL;    break;
    /* STAGE 9.  The three leaves that answered "which windows exist, and what
     * are they" in process, with no check of any kind, while the routed
     * `windows` read next door was refusing the same caller. */
    case HAMWSYS_WIN_CTL:  leaf = WSRV_LEAF_WIN_CTL;  break;
    case HAMWSYS_WIN_WCTL: leaf = WSRV_LEAF_WIN_WCTL; break;
    case HAMWSYS_DIR:      leaf = WSRV_LEAF_DIR;      break;
    default: return 0;
    }
    if (!srv_enabled() || srv_is_server) return 0;
    srv_rdial_if_uid_changed();
    if (srv_rdial() < 0) {
        /* A CONNECTION REFUSED AT THE CEILING IS A SERVER-SIDE REFUSAL, and
         * this function already says what must happen to those -- twenty
         * lines below, about the other way of reaching the same place: "A
         * NEGATIVE rc IS THE SERVER'S REFUSAL AND MUST NOT FALL BACK ...
         * Falling back to the in-process read here would answer it from
         * shared memory and turn every server-side refusal into a bypass."
         *
         * MEASURED, that was not a lapse but a PRIVILEGE GAIN, and it needed
         * no attacker: srd_enum_tier() answers EMPTY to a process that owns
         * no window, snap_windows() answers everybody with the whole table,
         * and 64 connect(2) calls were the whole of the exploit.
         * tests/linux/wsys_srv_ceiling.sh drives it: uid 1002 owning nothing
         * read 0 bytes with room in the table and the victim's full row with
         * the table full.
         *
         * ONLY THIS CASE FAILS CLOSED, and the distinction is the point.  If
         * connect(2) itself failed there is no server, srv_rd_cap_refused is
         * 0, and the in-process read is the ONLY read -- gates run
         * HAMWSYS_SERVER=1 with no wsysd and tests/linux/wsys_enum_policy.sh's
         * unrouted arm depends on the full list still arriving there.  A
         * server that answered and refused is a decision; a server that is
         * absent is not. */
        if (srv_rd_cap_refused) { errno = ECONNREFUSED; f->snap = NULL;
                                  f->snaplen = 0; return -1; }
        return 0;
    }
    static uint8_t back[WSRV_MAXPAY];
    uint32_t got = 0;
    int64_t rc = 0;
    if (srv_call_on(srv_rfd, WSRV_OP_READ,
                    (uint16_t)(leaf << WSRV_LEAF_SHIFT), f->wid, NULL, 0,
                    back, sizeof back, &got, &rc) < 0) {
        fprintf(stderr, "wsys: the read server did not answer (%s); falling "
                        "back to the unmediated in-process read.\n",
                strerror(errno));
        close(srv_rfd); srv_rfd = -1;
        return 0;
    }
    /* A NEGATIVE rc IS THE SERVER'S REFUSAL AND MUST NOT FALL BACK.  ENXIO
     * from `screen` means the compositor has not published a geometry yet --
     * a real answer that the client end of hamscreen.ad waits on.  Falling
     * back to the in-process read here would answer it from shared memory and
     * turn every server-side refusal into a bypass. */
    if (rc < 0) { errno = (int)-rc; f->snap = NULL; f->snaplen = 0; return -1; }
    f->snap = NULL;
    f->snaplen = 0;
    if (got) {
        f->snap = (uint8_t *)malloc(got);
        if (!f->snap) { errno = ENOMEM; return -1; }
        memcpy(f->snap, back, got);
        f->snaplen = got;
    }
    return 1;
}

/* ==================================================================
 * STAGE 10 — ROUTING `open`: EXISTENCE AS A SERVER ANSWER
 * ==================================================================
 * WHAT THIS IS FOR, from docs/wsys_server_design.md §7.1(2): "Routing `open` is
 * the precondition for [removing the client's mapping], and no stage has
 * touched it.  Almost every arm of hamwsys_open() starts with win_find(f->wid),
 * which is a walk of the mapped table.  A client with no mapping cannot open a
 * leaf, so existence ... must become a server answer before the mapping can
 * go."
 *
 * WHAT WAS ACTUALLY LEAKING, measured rather than argued.  Stage 9 routed the
 * three leaves that REPORT attributes, and every one of them now answers a
 * caller that owns nothing with ENOENT.  One path component over, on the same
 * run, a uid-1002 process owning nothing could still tell a live window from a
 * dead one WITHOUT READING A BYTE, because the leaves that report no attributes
 * separate the two cases in their exit code:
 *
 *     cat /dev/wsys/<live>/draw/images   -> rc 0, no output
 *     cat /dev/wsys/<dead>/draw/images   -> rc 1, ENOENT
 *     cat /dev/wsys/<live>/scene         -> EPERM, and it NAMES THE WINDOW
 *     cat /dev/wsys/<dead>/scene         -> ENOENT
 *     cat /dev/wsys/<live>/pointer       -> EPERM (the ring's owner check)
 *     cat /dev/wsys/<dead>/pointer       -> ENOENT
 *
 * A refusal that distinguishes itself from an absence IS the enumeration
 * channel stage 4 set out to close; the ring commits and the keys refusal each
 * shut a door and left the doorway measurable.
 *
 * THE CACHE IS WHAT KEEPS THIS OFF THE PER-FRAME PATH, and its shape is
 * asymmetric on purpose.  A YES is remembered for the life of the process; a NO
 * is never remembered.  Every application in this tree reopens its own /keys
 * and /event on a loop -- hamui polls them non-blocking -- so a round trip per
 * open would be exactly the shape §7.1(3) says not to build, while a round trip
 * per (process, window) is one or two calls in the life of a program.  A
 * remembered NO would be worse than a cost: a window created after a probe
 * would stay invisible to that process for ever.
 *
 * THE CACHED YES IS NOT A BYPASS, and this is the line to check if this is ever
 * suspected.  It does not grant anything: win_find() still runs behind it, so a
 * window destroyed after the grant is ENOENT exactly as before, and the grant
 * is dropped whole when the process's uid changes (srv_rdial_if_uid_changed).
 * What it removes is a repeat of a question already answered for an unchanged
 * (identity, window) pair.
 *
 * AND IT IS NOT THE BOUNDARY YET, said plainly.  The client still maps the
 * segment read-write, so an attacker that does not call this function reads
 * everything anyway -- §7.1(1), and removing the mapping costs the
 * WSYS_VERSION bump this stage deliberately does not make.  What this buys is
 * the PRECONDITION: a client that asks honestly now learns existence from the
 * server, which is what a client with no mapping will have to do.
 */
enum { SRV_EXIST_CACHE = 16 };
static int32_t srv_exist_ok[SRV_EXIST_CACHE];
static int     srv_exist_n;

static void srv_exists_forget_all(void)
{
    srv_exist_n = 0;
}

static int srv_exists_cached(int32_t wid)
{
    for (int i = 0; i < srv_exist_n; i++)
        if (srv_exist_ok[i] == wid) return 1;
    return 0;
}

static void srv_exists_remember(int32_t wid)
{
    if (srv_exists_cached(wid)) return;
    /* A RING AND NOT A REFUSAL WHEN IT FILLS.  Sixteen windows in one process
     * is already far past anything on this desktop, and a full cache that
     * stopped remembering would silently put the busiest client back on a round
     * trip per open -- the one cost this whole mechanism exists to avoid.
     * Evicting the oldest costs one extra call for a window that has fallen out
     * and nothing else. */
    if (srv_exist_n < SRV_EXIST_CACHE) { srv_exist_ok[srv_exist_n++] = wid; return; }
    for (int i = 1; i < SRV_EXIST_CACHE; i++) srv_exist_ok[i - 1] = srv_exist_ok[i];
    srv_exist_ok[SRV_EXIST_CACHE - 1] = wid;
}

/* Ask the read server whether `wid` exists and this caller may have it.
 *
 *   1  the server said yes (or has already said yes for this wid)
 *  -1  the server said NO -- errno is set and the open must fail
 *   0  not routed: the caller takes the in-process win_find()
 *
 * THE FALLBACK RULES ARE srv_route_read's AND ARE NOT RE-DECIDED HERE.  A
 * server that is ABSENT falls back, because gates run HAMWSYS_SERVER=1 with no
 * wsysd at all and every unrouted arm in this tree depends on that.  A server
 * that ANSWERED AND REFUSED -- including the connection ceiling -- fails
 * closed, because turning a server-side refusal into a fallback is how a
 * mediator becomes a door beside itself. */
static int srv_route_exists(int32_t wid, int for_write)
{
    if (!srv_enabled() || srv_is_server) return 0;
    if (wid <= 0) return 0;                    /* not a per-window path */
    if (srv_exists_cached(wid)) return 1;
    /* BLOCKING, SO THE uid GUARD COMES FIRST.  This call's ANSWER is what the
     * open acts on, so it is the shape stage 8 had to give `version`: a
     * fire-and-forget existence question would report success for a refusal.
     * And a blocking call on a connection dialled under another identity is the
     * defect srv_redial_if_uid_changed was written for. */
    srv_rdial_if_uid_changed();
    if (srv_rdial() < 0) {
        if (srv_rd_cap_refused) { errno = ECONNREFUSED; return -1; }
        return 0;
    }
    uint8_t back[8];
    uint32_t got = 0;
    int64_t rc = 0;
    /* THE FLAG NAMES THE OPEN AND NOTHING ELSE.  The server's answer does not
     * depend on it -- see WSRV_F_FORWRITE -- and it must not, because the two
     * predicates being the same set is the entire argument for asking this
     * question on the write path.  It is carried so the trace can attribute a
     * crossing to a write open, which is the only way a gate outside the
     * process can tell that the write open was routed at all. */
    uint16_t fl = (uint16_t)(WSRV_LEAF_EXISTS << WSRV_LEAF_SHIFT);
    if (for_write) fl |= WSRV_F_FORWRITE;
    if (srv_call_on(srv_rfd, WSRV_OP_READ, fl, wid,
                    NULL, 0, back, sizeof back, &got, &rc) < 0) {
        fprintf(stderr, "wsys: the read server did not answer the existence of "
                        "window %d (%s); falling back to the unmediated "
                        "in-process lookup.\n", (int)wid, strerror(errno));
        close(srv_rfd); srv_rfd = -1;
        return 0;
    }
    if (rc < 0) { errno = (int)-rc; return -1; }
    srv_exists_remember(wid);
    return 1;
}

/* ------------------------------------------------------- the stage-1 gate -- */

static uint64_t srv_now_us(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000u + (uint64_t)(ts.tv_nsec / 1000);
}

/* Pull "nop <n>" out of a WSRV_OP_STAT reply. */
static uint64_t srv_stat_field(const char *s, const char *key)
{
    const char *p = strstr(s, key);
    if (!p) return 0;
    p += strlen(key);
    while (*p == ' ') p++;
    uint64_t v = 0;
    while (*p >= '0' && *p <= '9') v = v * 10 + (uint64_t)(*p++ - '0');
    return v;
}

int hamwsys_srv_selftest(void)
{
    int fails = 0;
    if (!srv_enabled()) {
        fprintf(stderr, "wsrv: HAMWSYS_SERVER is not 1, so this build's "
                        "/dev/wsys is implemented in-process and there is "
                        "nothing to dial.\n");
        return 1;
    }
    if (srv_fd < 0) {
        fprintf(stderr, "wsrv: no connection to a server.\n");
        return 1;
    }
    printf("wsrvst: connected, both ends speak wsys version %u\n",
           (unsigned)WSYS_VERSION);

    /* 1. THE BLOCKING SHAPE, AND IT IS THE NUMBER THAT MATTERS MOST.
     *
     * tests/linux/wsys_rtt_probe.c measured 6.30 us for a sequential round
     * trip against a DEDICATED server thread that does nothing but read the
     * socket.  This server is not that: it is serviced from the compositor's
     * frame loop, so a blocking request waits for wsysd to come round -- and
     * that is a cost the design's 6.30 us does not contain.  Three samples
     * would not show the shape of it, so this takes 33 and reports the
     * distribution: the tail is the part a 0.3 ms input-to-pixel budget has
     * to survive, and a median alone would hide it. */
    {
        const char payload[] = "wctl version 2";
        char back[64];
        enum { NS = 33 };
        uint64_t s[NS];
        int n = 0;
        for (int i = 0; i < NS; i++) {
            uint32_t got = 0; int64_t rc = 0;
            uint64_t t0 = srv_now_us();
            int r = srv_call(WSRV_OP_PING, 0, payload, sizeof payload - 1,
                             back, sizeof back, &got, &rc);
            s[n++] = srv_now_us() - t0;
            if (r < 0 || rc != (int64_t)(sizeof payload - 1)
                || got != sizeof payload - 1
                || memcmp(back, payload, got) != 0) {
                printf("wsrvst: FAIL the blocking round trip did not come back "
                       "intact (r=%d rc=%lld got=%u)\n",
                       r, (long long)rc, (unsigned)got);
                fails++;
                break;
            }
        }
        for (int i = 1; i < n; i++) {            /* insertion sort, n is 33 */
            uint64_t v = s[i]; int j = i - 1;
            while (j >= 0 && s[j] > v) { s[j + 1] = s[j]; j--; }
            s[j + 1] = v;
        }
        if (n > 0) {
            printf("wsrvst: blocking round trip, %d samples: min %llu  "
                   "p50 %llu  p90 %llu  max %llu us\n", n,
                   (unsigned long long)s[0],
                   (unsigned long long)s[n / 2],
                   (unsigned long long)s[(n * 9) / 10],
                   (unsigned long long)s[n - 1]);
            printf("wsrvst: every sample, us:");
            for (int i = 0; i < n; i++)
                printf(" %llu", (unsigned long long)s[i]);
            printf("\n");
        }
    }

    /* 2. THE FIRE-AND-FORGET SHAPE, AND THE ONLY HONEST WAY TO CHECK IT.
     *
     * A dropped fire-and-forget message and a delivered one look identical
     * from here.  So the server's own counter is read before and after, and
     * the difference is the assertion.  Without this the transport could
     * discard every message and this test would report the fastest possible
     * result. */
    {
        char st[512]; uint32_t got = 0; int64_t rc = 0;
        uint64_t before = 0, after = 0;
        if (srv_call(WSRV_OP_STAT, 0, NULL, 0, st, sizeof st - 1, &got, &rc) < 0) {
            printf("wsrvst: FAIL could not read the server's counters\n");
            return fails + 1;
        }
        st[got] = 0;
        before = srv_stat_field(st, "nop");

        const int BURST = 256;
        uint64_t t0 = srv_now_us();
        int sent = 0;
        for (int i = 0; i < BURST; i++)
            if (srv_post(WSRV_OP_NOP, 0, &i, sizeof i) == 0) sent++;
        uint64_t dt = srv_now_us() - t0;

        if (srv_call(WSRV_OP_STAT, 0, NULL, 0, st, sizeof st - 1, &got, &rc) < 0) {
            printf("wsrvst: FAIL could not read the server's counters back\n");
            return fails + 1;
        }
        st[got] = 0;
        after = srv_stat_field(st, "nop");
        printf("wsrvst: fire-and-forget: %d sent in %llu us (%.2f us/op, "
               "send side only)\n", sent, (unsigned long long)dt,
               sent ? (double)dt / sent : 0.0);
        printf("wsrvst: the server's own counter: nop %llu -> %llu "
               "(delta %llu, sent %d)\n", (unsigned long long)before,
               (unsigned long long)after,
               (unsigned long long)(after - before), sent);
        if (sent != BURST) {
            printf("wsrvst: FAIL only %d of %d fire-and-forget sends "
                   "succeeded\n", sent, BURST);
            fails++;
        }
        /* The STAT round trip is ordered after the burst on the same
         * SEQPACKET connection, so the server has necessarily seen every
         * message before it answers: this is an exact equality, not a
         * tolerance.  A tolerance here would quietly accept a transport that
         * loses some. */
        if ((uint64_t)sent != after - before) {
            printf("wsrvst: FAIL the server received %llu of %d fire-and-forget "
                   "messages. They are being dropped, and the sending end "
                   "cannot see that.\n",
                   (unsigned long long)(after - before), sent);
            fails++;
        }
        printf("wsrvst: server counters: %s", st);
    }

    /* 3. THE OUT-OF-BAND ERROR PATH.  An unknown fire-and-forget op must come
     * back as an unsolicited tag-0 frame rather than vanishing, because that
     * is how a refused mutation will reach a client that did not wait. */
    {
        char st[512]; uint32_t got = 0; int64_t rc = 0;
        uint64_t bad0, bad1;
        if (srv_call(WSRV_OP_STAT, 0, NULL, 0, st, sizeof st - 1, &got, &rc) >= 0) {
            st[got] = 0; bad0 = srv_stat_field(st, "bad");
            srv_post(9999, 0, NULL, 0);
            if (srv_call(WSRV_OP_STAT, 0, NULL, 0, st, sizeof st - 1,
                         &got, &rc) >= 0) {
                st[got] = 0; bad1 = srv_stat_field(st, "bad");
                if (bad1 == bad0 + 1)
                    printf("wsrvst: an unknown fire-and-forget op was refused "
                           "out of band (bad %llu -> %llu)\n",
                           (unsigned long long)bad0, (unsigned long long)bad1);
                else {
                    printf("wsrvst: FAIL an unknown op was not counted as "
                           "refused (bad %llu -> %llu)\n",
                           (unsigned long long)bad0, (unsigned long long)bad1);
                    fails++;
                }
            }
        }
    }
    return fails;
}

/* THE ASSERTION STAGE 2 EXISTS FOR: can a process that owns nothing mutate
 * somebody else's window?
 *
 * It has to be driven from HERE and not from an ordinary client, and that is
 * the interesting part.  An ordinary client's write to a foreign wid is
 * refused by the in-process check before it ever reaches a socket -- so a
 * gate driven that way would be green whether or not the server checks
 * anything at all, which is the same as having no gate.  This sends the
 * routed message DIRECTLY, past the local check, which is exactly what a
 * hostile client would do once it knew the protocol.  What is left to refuse
 * it is the mediator, and nothing else.
 *
 * Returns a failure count. */
int hamwsys_srv_mutate_selftest(int victim_wid)
{
    int fails = 0;
    if (!srv_enabled() || srv_fd < 0) {
        fprintf(stderr, "wsrv: no connection to a server.\n");
        return 1;
    }
    char st[512]; uint32_t got = 0; int64_t rc = 0;
    uint64_t r0, r1, w0, w1;
    if (srv_call(WSRV_OP_STAT, 0, NULL, 0, st, sizeof st - 1, &got, &rc) < 0) {
        printf("wsrvmu: FAIL could not read the server's counters\n");
        return 1;
    }
    st[got] = 0;
    r0 = srv_stat_field(st, "refused");
    w0 = srv_stat_field(st, "write");

    /* A ROUTED WRITE THIS PROCESS HAS NO RIGHT TO MAKE.  It owns no window at
     * all; `victim_wid` belongs to somebody else. */
    const char verb[] = "title PWNED-BY-A-STRANGER";
    uint16_t flags = (uint16_t)(WSRV_LEAF_WIN_CTL << WSRV_LEAF_SHIFT);
    srv_send(WSRV_OP_WRITE, flags, victim_wid, ++srv_tag,
             verb, (uint32_t)(sizeof verb - 1));

    /* Ordered after it on the same SEQPACKET connection, so the server has
     * necessarily processed the write before it answers this. */
    if (srv_call(WSRV_OP_STAT, 0, NULL, 0, st, sizeof st - 1, &got, &rc) < 0) {
        printf("wsrvmu: FAIL could not read the server's counters back\n");
        return 1;
    }
    st[got] = 0;
    r1 = srv_stat_field(st, "refused");
    w1 = srv_stat_field(st, "write");

    printf("wsrvmu: a window-less process sent a routed `title` for window %d\n",
           victim_wid);
    printf("wsrvmu: server counters: %s", st);
    if (w1 != w0 + 1) {
        printf("wsrvmu: FAIL the server did not see the routed write at all "
               "(write %llu -> %llu). A refusal count of zero would mean "
               "nothing if the message never arrived.\n",
               (unsigned long long)w0, (unsigned long long)w1);
        return fails + 1;
    }
    printf("wsrvmu: the server received it (write %llu -> %llu), so a refusal "
           "below is a decision and not a lost message\n",
           (unsigned long long)w0, (unsigned long long)w1);
    /* THE CALLER DECIDES WHAT THIS MEANS, NOT THIS FUNCTION.  Whether a
     * refusal is the right answer depends on the caller's uid against the
     * segment's owner -- devwsys's rule is that the host owner may write
     * anything -- and this process cannot know what the gate arranged.  So it
     * reports what happened, with the two identities that decide it, and
     * returns 0 for REFUSED and 1 for ACCEPTED.  A function that decided for
     * itself would have to guess, and a gate built on a guess is worse than
     * no gate. */
    printf("wsrvmu: caller uid %u pid %ld; segment owner uid %u\n",
           (unsigned)geteuid(), (long)getpid(),
           (unsigned)(seg_owner_known ? seg_owner : (uid_t)-1));
    if (r1 == r0 + 1) {
        printf("wsrvmu: the mediator REFUSED it (refused %llu -> %llu)\n",
               (unsigned long long)r0, (unsigned long long)r1);
        return fails;
    }
    printf("wsrvmu: the mediator ACCEPTED it (refused %llu -> %llu)\n",
           (unsigned long long)r0, (unsigned long long)r1);
    return fails + 1;
}

/* THE PRIVILEGE DROP, WHICH IS THE OTHER WAY A CONNECTION OUTLIVES ITS
 * IDENTITY.  Dial while privileged, drop to `to_uid`, then send a routed
 * mutation for a window this process does not own.
 *
 * WITHOUT srv_redial_if_uid_changed() THIS IS ACCEPTED, and that is the whole
 * point of the arm: SO_PEERCRED is sampled at connect(2), so the mediator
 * keeps answering for the uid that dialled however long ago it dropped.  It is
 * not a hypothetical -- /etc/rc.de-user reaches `setuid 1001` only after hamsh
 * has had the chance to spawn, and hamsh is what every DE window is stamped
 * against.  Returns hamwsys_srv_mutate_selftest's contract: 0 REFUSED,
 * 1 ACCEPTED. */
int hamwsys_srv_dropwrite(int victim_wid, int to_uid)
{
    if (!srv_enabled()) {
        printf("wsrvdr: FAIL HAMWSYS_SERVER is not set\n");
        return 1;
    }
    if (srv_dial() < 0) {
        printf("wsrvdr: FAIL could not dial the server while privileged\n");
        return 1;
    }
    printf("wsrvdr: dialled as uid %u\n", (unsigned)geteuid());
    if (setuid((uid_t)to_uid) < 0) {
        printf("wsrvdr: FAIL could not drop to uid %d: %s\n",
               to_uid, strerror(errno));
        return 1;
    }
    printf("wsrvdr: now uid %u, sending a routed write for window %d\n",
           (unsigned)geteuid(), victim_wid);
    return hamwsys_srv_mutate_selftest(victim_wid);
}

/* STAGE 6: THE SAME ATTACK, ON THE SCENE.  A routed display-list write for a
 * window this process does not hold, sent PAST the local check exactly as
 * hamwsys_srv_mutate_selftest sends a ctl write -- because an ordinary
 * client's scene write to a foreign wid is refused before it reaches a socket,
 * and a gate driven that way would be green whether or not the mediator checks
 * anything.  Returns 0 for REFUSED and 1 for ACCEPTED, the contract the ctl
 * probe already uses: whether a refusal is the RIGHT answer depends on what
 * the gate arranged, and this process cannot know that. */
int hamwsys_srv_scene_selftest(int victim_wid)
{
    if (!srv_enabled() || srv_fd < 0) {
        fprintf(stderr, "wsrv: no connection to a server.\n");
        return 1;
    }
    char st[512]; uint32_t got = 0; int64_t rc = 0;
    if (srv_call(WSRV_OP_STAT, 0, NULL, 0, st, sizeof st - 1, &got, &rc) < 0) {
        printf("wsrvsc: FAIL could not read the server's counters\n");
        return 1;
    }
    st[got] = 0;
    uint64_t r0 = srv_stat_field(st, "refused");
    uint64_t w0 = srv_stat_field(st, "write");
    const char line[] = "fill 0 0 400 400 #ff00ff\n";
    uint16_t flags = (uint16_t)((WSRV_LEAF_WIN_SCENE << WSRV_LEAF_SHIFT)
                                | WSRV_F_NEWFRAME);
    srv_send(WSRV_OP_WRITE, flags, victim_wid, ++srv_tag,
             line, (uint32_t)(sizeof line - 1));
    if (srv_call(WSRV_OP_STAT, 0, NULL, 0, st, sizeof st - 1, &got, &rc) < 0) {
        printf("wsrvsc: FAIL could not read the server's counters back\n");
        return 1;
    }
    st[got] = 0;
    uint64_t r1 = srv_stat_field(st, "refused");
    uint64_t w1 = srv_stat_field(st, "write");
    printf("wsrvsc: a window-less process sent a routed SCENE write for "
           "window %d\n", victim_wid);
    printf("wsrvsc: server counters: %s", st);
    if (w1 != w0 + 1) {
        printf("wsrvsc: FAIL the server did not see the routed scene write at "
               "all (write %llu -> %llu); a refusal count of zero would mean "
               "nothing if the message never arrived.\n",
               (unsigned long long)w0, (unsigned long long)w1);
        return 1;
    }
    printf("wsrvsc: the server received it (write %llu -> %llu)\n",
           (unsigned long long)w0, (unsigned long long)w1);
    printf("wsrvsc: caller uid %u pid %ld; segment owner uid %u\n",
           (unsigned)geteuid(), (long)getpid(),
           (unsigned)(seg_owner_known ? seg_owner : (uid_t)-1));
    if (r1 == r0 + 1) {
        printf("wsrvsc: the mediator REFUSED it (refused %llu -> %llu)\n",
               (unsigned long long)r0, (unsigned long long)r1);
        return 0;
    }
    printf("wsrvsc: the mediator ACCEPTED it (refused %llu -> %llu)\n",
           (unsigned long long)r0, (unsigned long long)r1);
    return 1;
}

/* STAGE 8: THE SAME ATTACK, ON wctl.  A routed `move` for a window this
 * process does not hold, sent PAST the local check exactly as the ctl and
 * scene probes send theirs.
 *
 * IT IS SENT AS A BLOCKING CALL, and that is not a stylistic difference: it is
 * the only way to score a refusal on one message without racing a dragging
 * client's own ~800 writes/s through the same counters.  The ctl probe reads
 * `write` and `refused` around a fire-and-forget send and asserts +1 on each,
 * which is the arm stage 4 recorded flaking for exactly that reason.  Here the
 * server's own rc for THIS message comes back on the wire, so the verdict does
 * not depend on the counters moving by one -- the counters are still printed,
 * because they are what proves the message ARRIVED.
 *
 * Returns 0 for REFUSED and 1 for ACCEPTED, the contract the other two probes
 * use: whether a refusal is the right answer depends on what the gate
 * arranged, and this process cannot know that. */
int hamwsys_srv_wctl_selftest(int victim_wid, int local)
{
    /* THE ARM THAT MUST SUCCEED, and it is the same act minus the boundary.
     * hamwsys_srv_attack_local makes this argument at length for `title` on
     * wid/ctl; it is repeated here on wctl's own verb because a refusal gate
     * that is green in every configuration is equally green against a server
     * that checks nothing.  One assignment to the identity the in-process
     * check reads, then hamwsys_write_inner in the attacker's own address
     * space.  Returns 0 if the write LANDED, 1 if it did not. */
    if (local) {
        if (shm_attach() < 0) {
            printf("wsrvwc: FAIL cannot attach the segment\n");
            return 1;
        }
        struct wwin *lv = win_find(victim_wid);
        if (!lv) {
            printf("wsrvwc: FAIL window %d does not exist -- an attack on "
                   "nothing is not a measurement\n", victim_wid);
            return 1;
        }
        printf("wsrvwc: attacker uid %u pid %ld; window %d owner pid %d; the "
               "in-process check says hostowner=%d owns_wid=%d -- i.e. "
               "REFUSE\n", (unsigned)geteuid(), (long)getpid(), victim_wid,
               (int)lv->pid, hostowner(), owns_wid(victim_wid));
        srv_as_caller(seg_owner_known ? seg_owner : (uid_t)0, getpid());
        printf("wsrvwc: after ONE assignment to that identity the SAME check "
               "says hostowner=%d owns_wid=%d -- i.e. ALLOW\n",
               hostowner(), owns_wid(victim_wid));
        const char lverb[] = "move 777 888";
        struct hamwsys_file lf;
        memset(&lf, 0, sizeof lf);
        lf.leaf = HAMWSYS_WIN_WCTL;
        lf.wid = victim_wid;
        lf.write = 1;
        errno = 0;
        int64_t lrc = hamwsys_write_inner(&lf, (const uint8_t *)lverb,
                                          (uint32_t)(sizeof lverb - 1));
        srv_as_self();
        if (lrc < 0) {
            printf("wsrvwc: the UNROUTED wctl move was refused (rc %lld) -- "
                   "which means something other than the permission gate "
                   "stopped it, because the gate was skipped\n",
                   (long long)lrc);
            return 1;
        }
        if (shm) shm->gen++;
        printf("wsrvwc: the UNROUTED wctl move LANDED (rc %lld) and window %d "
               "is now at 777,888. No mediator was present: the store was the "
               "attacker's own.\n", (long long)lrc, victim_wid);
        return 0;
    }
    if (!srv_enabled() || srv_fd < 0) {
        fprintf(stderr, "wsrv: no connection to a server.\n");
        return 1;
    }
    char st[512]; uint32_t got = 0; int64_t src = 0;
    if (srv_call(WSRV_OP_STAT, 0, NULL, 0, st, sizeof st - 1, &got, &src) < 0) {
        printf("wsrvwc: FAIL could not read the server's counters\n");
        return 1;
    }
    st[got] = 0;
    uint64_t w0 = srv_stat_field(st, "write");
    const char verb[] = "move 777 888";
    uint16_t flags = (uint16_t)(WSRV_LEAF_WIN_WCTL << WSRV_LEAF_SHIFT);
    uint32_t wgot = 0;
    int64_t wrc = 0;
    if (srv_call_on(srv_fd, WSRV_OP_WRITE, flags, victim_wid,
                    verb, (uint32_t)(sizeof verb - 1),
                    NULL, 0, &wgot, &wrc) < 0) {
        printf("wsrvwc: FAIL the server never answered the routed wctl write "
               "(%s) -- no verdict is scored on a message that may not have "
               "arrived\n", strerror(errno));
        return 1;
    }
    got = 0; src = 0;
    if (srv_call(WSRV_OP_STAT, 0, NULL, 0, st, sizeof st - 1, &got, &src) < 0) {
        printf("wsrvwc: FAIL could not read the server's counters back\n");
        return 1;
    }
    st[got] = 0;
    uint64_t w1 = srv_stat_field(st, "write");
    printf("wsrvwc: a window-less process sent a routed `move 777 888` for "
           "window %d\n", victim_wid);
    printf("wsrvwc: server counters: %s", st);
    if (w1 == w0) {
        printf("wsrvwc: FAIL the server did not count the routed wctl write "
               "at all (write %llu -> %llu); an rc below would be about "
               "nothing.\n", (unsigned long long)w0, (unsigned long long)w1);
        return 1;
    }
    printf("wsrvwc: the server received it (write %llu -> %llu)\n",
           (unsigned long long)w0, (unsigned long long)w1);
    printf("wsrvwc: caller uid %u pid %ld; segment owner uid %u\n",
           (unsigned)geteuid(), (long)getpid(),
           (unsigned)(seg_owner_known ? seg_owner : (uid_t)-1));
    if (wrc < 0) {
        printf("wsrvwc: the mediator REFUSED it (rc %d, %s)\n",
               (int)wrc, strerror((int)-wrc));
        return 0;
    }
    printf("wsrvwc: the mediator ACCEPTED it (rc %d)\n", (int)wrc);
    return 1;
}

/* THE OTHER HALF OF THE ARGUMENT, AND THE ONLY ARM THAT IS SUPPOSED TO
 * SUCCEED: the same attack with NO SERVER IN IT.
 *
 * hamwsys_srv_mutate_selftest above sends the routed message past the local
 * check, which is what a hostile client does once it knows the protocol.  On
 * its own that proves only that the mediator refuses — it does not prove the
 * mediator is NECESSARY, because a gate that is green in every configuration
 * says nothing about mediation.  The comparison is what says it, and this is
 * the arm it compares against.
 *
 * So this does the identical mutation the identical way MINUS the boundary: it
 * calls hamwsys_write_inner directly, in the attacker's own address space,
 * having first told the check it IS the host owner.
 *
 * AND THAT IS ONE ASSIGNMENT, WHICH IS THE WHOLE POINT.  It does not delete a
 * check, patch a binary, or reach for a debugger.  hostowner() reads
 * `srv_caller.active ? srv_caller.uid : geteuid()` — a plain global — because
 * a routed operation has to be able to install the caller it is acting for.
 * In wsysd that global is written from SO_PEERCRED, which the client cannot
 * forge.  In the CLIENT it is just a variable in the attacker's own address
 * space, and so is every other input the in-process check consults.  An
 * unmediated check does not become weak when it is attacked; it was never
 * anything but advice, because the identity it asks about is supplied by the
 * process being asked about.  Deleting the `if (!hostowner() && ...) return
 * deny();` line would do just as well and takes one more keystroke.
 *
 * Routed, the identical assignment buys nothing: srv_dispatch overwrites
 * srv_caller from the kernel's credentials on the far side of a socket, in a
 * process the attacker does not run.
 *
 * It must SUCCEED (return 0) unrouted, and the routed arm must refuse the same
 * mutation from the same uid.  Either result alone is unfalsifiable; the pair
 * is the case for the server's existence.
 *
 * Returns 0 if the write landed (attack succeeded), 1 if it did not — so the
 * gate can tell "the boundary held" from "the instrument was not looking",
 * which for an attack tool are opposite findings that both print nothing. */
int hamwsys_srv_attack_local(int victim_wid)
{
    if (shm_attach() < 0) {
        fprintf(stderr, "wsrvlo: FAIL cannot attach the segment.\n");
        return 1;
    }
    struct wwin *v = win_find(victim_wid);
    if (!v) {
        printf("wsrvlo: FAIL window %d does not exist -- an attack on nothing "
               "is not a measurement\n", victim_wid);
        return 1;
    }
    printf("wsrvlo: attacker uid %u pid %ld; window %d owner pid %d; segment "
           "owner uid %u\n",
           (unsigned)geteuid(), (long)getpid(), victim_wid, (int)v->pid,
           (unsigned)(seg_owner_known ? seg_owner : (uid_t)-1));
    /* The two answers the IN-PROCESS path would have got, printed before they
     * are ignored.  They are what the routed arm re-asks about the caller, so
     * seeing them both 0 here is what makes "the local check said no and the
     * write happened anyway" a statement about enforcement rather than about
     * a policy difference between the two paths. */
    printf("wsrvlo: the in-process check says hostowner=%d owns_wid=%d -- i.e. "
           "REFUSE\n", hostowner(), owns_wid(victim_wid));

    /* ONE ASSIGNMENT.  See the comment above: this is the identity the
     * in-process check reads, and in a client it is the attacker's own
     * memory. */
    srv_as_caller(seg_owner_known ? seg_owner : (uid_t)0, getpid());
    printf("wsrvlo: after one assignment to the identity the check reads, the "
           "SAME check says hostowner=%d owns_wid=%d -- i.e. ALLOW\n",
           hostowner(), owns_wid(victim_wid));

    const char verb[] = "title PWNED-BY-A-STRANGER";
    struct hamwsys_file f;
    memset(&f, 0, sizeof f);
    f.leaf  = HAMWSYS_WIN_CTL;
    f.wid   = victim_wid;
    f.write = 1;
    errno = 0;
    int64_t rc = hamwsys_write_inner(&f, (const uint8_t *)verb,
                                     (uint32_t)(sizeof verb - 1));
    srv_as_self();
    if (rc < 0) {
        printf("wsrvlo: the unrouted write was refused (rc %lld) -- which means "
               "something OTHER than the permission gate stopped it, because the "
               "gate was skipped\n", (long long)rc);
        return 1;
    }
    if (shm) shm->gen++;
    printf("wsrvlo: the unrouted write LANDED (rc %lld). No mediator was "
           "present: the store was the attacker's own.\n", (long long)rc);
    return 0;
}

/* ==================================================================
 * STAGE 5'S GATE DRIVER — BOTH ARMS, ONE PROCESS, ONE WINDOW
 * ==================================================================
 * The property is a PAIR and neither half means anything alone: a descendant
 * that was NOT handed the connection must be refused, and one that WAS must
 * succeed.  A gate with only the refusal is equally green against a server
 * that refuses everything (which would break every desktop); a gate with only
 * the acceptance is green against a server that checks nothing, which is what
 * stage 3a measured and what this exists to change.
 *
 * This runs in the process the window is stamped against -- the toolkit's
 * position -- and spawns the SAME program twice with the SAME argument.  The
 * only difference between the two children is the handoff, so nothing else can
 * explain a difference in the answer.
 *
 * The child reports 0 for REFUSED and 1 for ACCEPTED (hamwsys_srv_mutate_
 * selftest's contract), so the expected pair is 0 then 1.
 *
 * ONE CONNECTION, TWO PROCESSES, AND THEY DO NOT OVERLAP: the parent waits for
 * each child before doing anything else on the socket.  Replies are matched by
 * tag and tags are per-process counters, so a parent and an adopted child
 * issuing blocking calls AT THE SAME TIME could each consume the other's
 * reply.  A toolkit that hands its connection to a child it does not wait for
 * has to keep that in mind; the handoff is a capability transfer, not a
 * multiplexer. */
static int conngate_spawn(const char *self, int wid, int hand, const char *tag)
{
    char widbuf[16];
    snprintf(widbuf, sizeof widbuf, "%d", wid);
    if (hand) {
        if (hamwsys_srv_handoff(1) < 0) {
            printf("wsrvcg: FAIL nothing to hand over for %s -- the holder has "
                   "no server connection, so the arm would measure a missing "
                   "connection rather than a refused one\n", tag);
            return -2;
        }
    }
    fflush(stdout);
    pid_t p = fork();
    if (p == 0) {
        execl(self, self, "mutate", widbuf, (char *)NULL);
        _exit(127);
    }
    int st = 0;
    if (p < 0 || waitpid(p, &st, 0) < 0) { if (hand) hamwsys_srv_handoff(0);
                                           return -1; }
    if (hand) hamwsys_srv_handoff(0);
    if (!WIFEXITED(st)) return -1;
    return WEXITSTATUS(st);
}

/* Spawn `prog` as an ORDINARY UNROUTED CLIENT of this window: a plain child,
 * no handoff, HAMWSYS_SERVER removed from its environment.  This is the red
 * arm and it must SUCCEED -- it is the ancestry rule the mediator inherits
 * when the server is off, and if it ever stops working the refusal in the
 * routed arm stops being attributable to the mediator. */
static int conngate_unrouted(const char *prog, int wid)
{
    char path[64];
    snprintf(path, sizeof path, "/dev/wsys/%d/ctl", wid);
    fflush(stdout);
    pid_t p = fork();
    if (p == 0) {
        unsetenv("HAMWSYS_SERVER");
        unsetenv("HAMWSYS_SRV_FD");
        execl(prog, prog, "chrome", path, "title DESC-UNROUTED",
              (char *)NULL);
        _exit(127);
    }
    int st = 0;
    if (p < 0 || waitpid(p, &st, 0) < 0 || !WIFEXITED(st)) return -1;
    return WEXITSTATUS(st);
}

/* THE WINDOW THIS PROCESS WAS SPAWNED INTO, waited for rather than assumed.
 * hamUId spawns the child FIRST and stamps the row a moment later, so an empty
 * answer on the first look is a race and not a verdict -- lib/hamwid.ad waits
 * two seconds for exactly this reason and this is the same handshake.  EXACT
 * PID, no walk: this is asking "which row names me", not "which row may I
 * reach". */
static int conngate_wait_for_wid(void)
{
    /* AND FOR THE ROW TO BE SET UP, not merely to exist.  The spawner stamps
     * the row and then decorates and titles it, and a holder that started its
     * arms in between would race the gate's own baseline read -- which showed
     * up as a baseline that already carried the LAST arm's title.  Waiting for
     * the title is waiting for the same fact lib/hamwid.ad waits for: the
     * window is ready, not merely allocated. */
    for (int t = 0; t < 60; t++) {
        if (shm) {
            for (int i = 0; i < WSYS_MAX_WINDOWS; i++)
                if (shm->win[i].used && shm->win[i].pid == (int32_t)getpid()
                    && shm->win[i].title[0])
                    return shm->win[i].wid;
        }
        struct timespec ts = { 0, 100 * 1000 * 1000 };
        nanosleep(&ts, NULL);
    }
    return -1;
}

int hamwsys_srv_conngate(int wid, const char *self, const char *uidgate)
{
    int fails = 0;
    if (!srv_enabled()) {
        printf("wsrvcg: FAIL HAMWSYS_SERVER is not set in the holder\n");
        return 1;
    }
    if (shm_attach() < 0) {
        printf("wsrvcg: FAIL the holder cannot attach the segment\n");
        return 1;
    }
    if (wid <= 0) {
        wid = conngate_wait_for_wid();
        printf("wsrvcg: the row stamped against pid %ld is wid %d\n",
               (long)getpid(), wid);
        if (wid < 2) {
            printf("wsrvcg: FAIL no window was ever stamped against this "
                   "process -- refusing to measure a gate against a window "
                   "that does not exist\n");
            return 1;
        }
    }
    /* THE RED ARM FIRST, and the order is deliberate: it runs before this
     * process has any connection at all, so nothing about the routed arms can
     * have set it up. */
    if (uidgate && uidgate[0]) {
        int u = conngate_unrouted(uidgate, wid);
        printf("wsrvcg: UNROUTED descendant (a plain child, no server in its "
               "environment): exit %d -- %s\n", u,
               u == 0 ? "the write LANDED, which is the rule this mediator "
                        "inherits and MUST still hold"
                      : "REFUSED, and that makes every routed arm below "
                        "unattributable");
        if (u != 0) fails++;
    }
    if (srv_dial() < 0) {
        printf("wsrvcg: FAIL the holder could not dial the server\n");
        return 1;
    }
    /* THE HOLDER DRIVES ITS OWN WINDOW FIRST, and it is not a formality: it is
     * what makes the connection the row's holder on the DE's on-behalf path,
     * where the row was stamped against this pid before this process existed
     * as a client.  It is also the arm that would catch a server that refuses
     * everything. */
    const char own[] = "title HOLDER-OWN-TITLE";
    uint16_t flags = (uint16_t)(WSRV_LEAF_WIN_CTL << WSRV_LEAF_SHIFT);
    srv_send(WSRV_OP_WRITE, flags, wid, ++srv_tag, own,
             (uint32_t)(sizeof own - 1));
    char st[512]; uint32_t got = 0; int64_t rc = 0;
    if (srv_call(WSRV_OP_STAT, 0, NULL, 0, st, sizeof st - 1, &got, &rc) >= 0) {
        st[got] = 0;
        printf("wsrvcg: holder pid %ld wid %d; server after the holder's own "
               "write: %s", (long)getpid(), wid, st);
    }

    int plain = conngate_spawn(self, wid, 0, "the un-handed child");
    printf("wsrvcg: child WITHOUT the connection: %s (exit %d)\n",
           plain == 0 ? "REFUSED" : plain == 1 ? "ACCEPTED" : "INDETERMINATE",
           plain);
    int handed = conngate_spawn(self, wid, 1, "the handed child");
    printf("wsrvcg: child WITH the connection: %s (exit %d)\n",
           handed == 0 ? "REFUSED" : handed == 1 ? "ACCEPTED" : "INDETERMINATE",
           handed);
    if (plain != 0) fails++;
    if (handed != 1) fails++;
    if (srv_call(WSRV_OP_STAT, 0, NULL, 0, st, sizeof st - 1, &got, &rc) >= 0) {
        st[got] = 0;
        printf("wsrvcg: server counters at the end: %s", st);
    }
    printf("wsrvcg: %d failures\n", fails);
    return fails;
}

/* STAGE 4'S INSTRUMENT: WHAT A ROUTED READ COSTS, AGAINST 851 us.
 *
 * Stage 1 measured the frame-loop server's blocking round trip under a heavy
 * drag and got p50 32 us / p90 789 us / max 851 us -- bimodal, because a
 * request either catches an idle loop or waits out a frame.  This is the same
 * measurement of the same shape of operation (blocking, returns data) against
 * the READ server, which is a separate process that never paints.  It must be
 * run under the SAME drag load or it is measuring a different question.
 *
 * EVERY SAMPLE IS PRINTED.  The number to beat is a MAX, and a median-only
 * report is precisely what would have hidden the thing stage 1 found.
 *
 * IT ALSO ASSERTS THE READ IS REAL.  A read server that answered zero bytes to
 * everything would be the fastest possible one, and this would report a
 * triumph.  So the caller is a window owner (the gate arranges that) and a
 * zero-length answer is counted and reported as a failure rather than timed. */
int hamwsys_srv_readlat(int nsamples)
{
    if (!srv_enabled()) {
        fprintf(stderr, "wsrvrl: HAMWSYS_SERVER is not 1; nothing is routed.\n");
        return 1;
    }
    if (nsamples <= 0 || nsamples > 512) nsamples = 33;
    if (srv_rdial() < 0) {
        fprintf(stderr, "wsrvrl: no connection to a READ server.\n");
        return 1;
    }
    uint64_t *s = (uint64_t *)malloc((size_t)nsamples * sizeof *s);
    if (!s) return 1;
    int n = 0, empty = 0, fails = 0;
    uint64_t bytes = 0, first = 0;
    for (int i = 0; i < nsamples; i++) {
        struct hamwsys_file f;
        memset(&f, 0, sizeof f);
        f.leaf = HAMWSYS_WINDOWS;
        uint64_t t0 = srv_now_us();
        int r = srv_route_read(&f);
        uint64_t dt = srv_now_us() - t0;
        if (r <= 0) { fails++; free(f.snap); continue; }
        if (f.snaplen == 0) empty++;
        bytes += f.snaplen;
        free(f.snap);
        printf("wsrvrl: sample %d %llu us %llu bytes%s\n",
               i, (unsigned long long)dt, (unsigned long long)f.snaplen,
               n == 0 && i == 0 ? "  (INCLUDES THE ONE-TIME DIAL)" : "");
        /* THE FIRST SAMPLE IS NOT LIKE THE OTHERS AND IS REPORTED APART.
         * srv_route_read dials the read server on the first call -- connect,
         * a version handshake, and a reply -- so sample 0 is that whole
         * conversation and every later one is a round trip on an open
         * connection.  Measured, it is the difference between ~14 us and up to
         * a millisecond.  Folding it into the distribution would put a
         * once-per-process cost into a per-read percentile, which flatters or
         * damns the wrong thing depending on the sample count.  It is a real
         * cost and it is printed; it is just not a read. */
        if (i == 0) { first = dt; continue; }
        s[n++] = dt;
    }
    printf("wsrvrl: first read %llu us -- ONCE PER PROCESS, and it is the "
           "dial (connect + version handshake), not the read\n",
           (unsigned long long)first);
    if (n == 0) {
        printf("wsrvrl: FAIL not one routed read completed\n");
        free(s);
        return 1;
    }
    for (int i = 1; i < n; i++) {
        uint64_t v = s[i]; int j = i - 1;
        while (j >= 0 && s[j] > v) { s[j + 1] = s[j]; j--; }
        s[j + 1] = v;
    }
    printf("wsrvrl: routed /dev/wsys/windows read, %d samples (the dial "
           "excluded): min %llu  p50 %llu  p90 %llu  max %llu us\n", n,
           (unsigned long long)s[0], (unsigned long long)s[n / 2],
           (unsigned long long)s[(n * 9) / 10],
           (unsigned long long)s[n - 1]);
    printf("wsrvrl: bytes %llu across %d reads, %d empty, %d failed\n",
           (unsigned long long)bytes, n + 1, empty, fails);
    if (empty >= n) {
        printf("wsrvrl: FAIL every routed read came back EMPTY -- a server "
               "that answers nothing is the fastest possible one, and these "
               "times would be of nothing\n");
        fails++;
    }
    free(s);
    return fails;
}

int hamwsys_srv_sustain(int ops_per_sec, int secs)
{
    if (!srv_enabled() || srv_fd < 0) {
        fprintf(stderr, "wsrv: no connection to a server.\n");
        return 1;
    }
    if (ops_per_sec <= 0 || secs <= 0) return 1;
    /* Paced in 10 ms slices, which is the window the op census measures bursts
     * in: ops clumped inside 10 ms are the ones that would serialise against
     * each other rather than spreading across a 16 ms frame.
     *
     * THE QUOTA IS CARRIED, NOT ROUNDED, and the first cut got that wrong.
     * `ops_per_sec / 100` is integer division: 192 ops/s asked became 1 per
     * slice and 100 ops/s DELIVERED, and the CPU cost of a rate 48% below the
     * one named was then compared against that rate's budget. The rates in
     * this design (192, 618, 2050) are none of them multiples of 100, so the
     * error was present in every arm and largest in the tightest one. */
    uint64_t t0 = srv_now_us(), sent = 0;
    uint64_t end = t0 + (uint64_t)secs * 1000000u;
    uint64_t slice = 0, owed = 0;
    for (;;) {
        uint64_t now = srv_now_us();
        if (now >= end) break;
        uint64_t due = t0 + slice * 10000u;
        if (now < due) { usleep((useconds_t)(due - now)); continue; }
        slice++;
        owed += (uint64_t)ops_per_sec;         /* per second... */
        uint64_t n = owed / 100;               /* ...spent 100 slices a second */
        owed -= n * 100;
        for (uint64_t i = 0; i < n; i++)
            if (srv_post(WSRV_OP_NOP, 0, &i, sizeof i) == 0) sent++;
    }
    uint64_t dt = srv_now_us() - t0;
    printf("wsrvsu: %llu ops in %llu us (%.0f ops/s asked, %.0f delivered)\n",
           (unsigned long long)sent, (unsigned long long)dt,
           (double)ops_per_sec, dt ? (double)sent * 1000000.0 / dt : 0.0);
    return 0;
}

#define KEYCHAN_MAX  WSYS_MAX_WINDOWS

/* ==================================================================
 * THE CLIENT WAKE, and why it is a socket and not a futex
 * ==================================================================
 * A window MOVING is a client-initiated change: de_dragload writes
 * "geometry x y w h" to <wid>/ctl, ctl_window mutates shared memory and bumps
 * shm->gen, and NOTHING in the kernel changes. The compositor therefore could
 * not be woken by it and re-read the segment on its fallback tick instead --
 * measured, that tick was 85% of a drag frame's period, and dropping it from
 * 16 ms to 2 ms took the same scanout desktop from 52 to 211 fps. The frame
 * was never the constraint; the pacing was.
 *
 * THE OBVIOUS FIX IS ALREADY REFUTED. Putting a /dev/wsys ring in the
 * compositor's wait set makes sys_waitfds sleep in FUTEX_WAIT on `inputgen`,
 * and an evdev fd is a character device that cannot futex-wake anything -- so
 * the mixed case degrades to poll-with-a-20 ms-cap, strictly worse than the
 * 16 ms tick it would replace. See user/linux-syscalls.c's ring branch.
 *
 * So the wake has to be an ORDINARY POLLABLE OBJECT, which keeps sys_waitfds
 * on its single uncapped poll(2) arm and composes with evdev by construction.
 * It is an abstract AF_UNIX SOCK_DGRAM, exactly as keychan below already does
 * for keystrokes: the compositor binds a name derived from the segment's
 * identity, and any process that publishes a change sends one byte to it.
 *
 * AND IT GENERALISES, which is the point. The compositor now has ONE wait set
 * with three reasons to wake: input fds, this socket for client changes, and
 * -- when double buffering lands -- the DRM fd for flip completion. Three
 * mechanisms would have been three ways to get the pacing wrong.
 *
 * IDLE IS THE RISK, not correctness. A wake per ctl WRITE would fire on writes
 * that publish nothing. This fires only when shm->gen actually moved, which is
 * the segment's own definition of "a published change", and the compositor's
 * frame_signature() gate still decides whether that change is worth a repaint.
 */
static int  wake_rx = -1;             /* bound; only in the compositor */
static int  wake_tx = -1;             /* send side, one per process */

static socklen_t wake_addr(struct sockaddr_un *a)
{
    if (!seg_id_known) return 0;
    memset(a, 0, sizeof *a);
    a->sun_family = AF_UNIX;
    a->sun_path[0] = '\0';                     /* abstract */
    int n = snprintf(a->sun_path + 1, sizeof a->sun_path - 1,
                     "hamnix-wsys/%llu.%llu/wake",
                     (unsigned long long)seg_dev, (unsigned long long)seg_ino);
    if (n <= 0 || (size_t)n >= sizeof a->sun_path - 1) return 0;
    return (socklen_t)(offsetof(struct sockaddr_un, sun_path) + 1 + n);
}

/* Bind the wake channel and return a pollable fd, or -1. The compositor calls
 * this once and appends the fd to its wait set. Idempotent. */
int hamwsys_wake_listen(void)
{
    if (wake_rx >= 0) return wake_rx;
    struct sockaddr_un a;
    socklen_t alen = wake_addr(&a);
    if (!alen) return -1;
    int fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (fd < 0) return -1;
    if (bind(fd, (struct sockaddr *)&a, alen) < 0) { close(fd); return -1; }
    wake_rx = fd;
    return wake_rx;
}

/* Throw away everything queued. One byte and a thousand mean the same thing --
 * "re-read the segment" -- and a datagram socket left unread stays readable,
 * which would turn the compositor's park into a spin. */
void hamwsys_wake_drain(void)
{
    if (wake_rx < 0) return;
    uint8_t b[256];
    while (recv(wake_rx, b, sizeof b, MSG_DONTWAIT) > 0) { }
}

/* Tell the compositor that something published. Never blocks, never fails
 * loudly: if nobody has bound the name there is no compositor to wake, which
 * is not an error. */
static void wake_poke(void)
{
    /* DO NOT WAKE YOURSELF, and this is not an optimisation.
     *
     * wake_rx >= 0 means THIS process is the one that bound the wake channel,
     * i.e. it is the compositor. The compositor writes /dev/wsys itself every
     * single iteration -- publish_state() -- and that write bumps shm->gen.
     * Poking on it made wsysd wake itself the instant it parked, for ever: the
     * idle gate measured 100.06% of a core on an otherwise idle desktop, which
     * is precisely the regression the gate exists to catch and precisely the
     * one this mechanism was most likely to cause.
     *
     * A compositor never needs telling about its own publish: it re-reads the
     * segment at the top of every iteration regardless. */
    if (wake_rx >= 0) return;
    struct sockaddr_un a;
    socklen_t alen = wake_addr(&a);
    if (!alen) return;
    if (wake_tx < 0) {
        wake_tx = socket(AF_UNIX, SOCK_DGRAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
        if (wake_tx < 0) return;
    }
    uint8_t one = 1;
    (void)sendto(wake_tx, &one, 1, MSG_DONTWAIT, (struct sockaddr *)&a, alen);
}

static struct { int32_t wid; int fd; } keychan[KEYCHAN_MAX];
static int  keychan_n;
static int  keychan_out = -1;                 /* the send side, one per proc */

/* The abstract address for one window's keystrokes.  Returns the length the
 * kernel wants, or 0 when the segment identity is not established -- in which
 * case there is no channel and the caller must fail rather than invent one. */
static socklen_t keychan_addr(struct sockaddr_un *a, int32_t wid)
{
    if (!seg_id_known) return 0;
    memset(a, 0, sizeof *a);
    a->sun_family = AF_UNIX;
    a->sun_path[0] = '\0';                     /* abstract */
    int n = snprintf(a->sun_path + 1, sizeof a->sun_path - 1,
                     "hamnix-wsys/%llu.%llu/%d/keys",
                     (unsigned long long)seg_dev, (unsigned long long)seg_ino,
                     (int)wid);
    if (n <= 0 || (size_t)n >= sizeof a->sun_path - 1) return 0;
    return (socklen_t)(offsetof(struct sockaddr_un, sun_path) + 1 + n);
}

static int keychan_find(int32_t wid)
{
    for (int i = 0; i < keychan_n; i++)
        if (keychan[i].wid == wid) return keychan[i].fd;
    return -1;
}

/* Claim this window's keystrokes for THIS process.  0 on success, -1 with a
 * named message on stderr when the name is already taken.  Idempotent. */
static int keychan_bind(int32_t wid)
{
    if (keychan_find(wid) >= 0) return 0;
    if (keychan_n >= KEYCHAN_MAX) { errno = ENOSPC; return -1; }

    struct sockaddr_un a;
    socklen_t alen = keychan_addr(&a, wid);
    if (!alen) { errno = EIO; return -1; }

    int s = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    if (s < 0) return -1;
    int on = 1;
    /* Without this the datagrams arrive with no credentials and every one of
     * them would have to be dropped -- fail closed, but silently deaf.  It is
     * checked rather than assumed for that reason. */
    if (setsockopt(s, SOL_SOCKET, SO_PASSCRED, &on, sizeof on) < 0) {
        int e = errno; close(s); errno = e; return -1;
    }
    if (bind(s, (struct sockaddr *)&a, alen) < 0) {
        int e = errno;
        close(s);
        fprintf(stderr,
                "wsys: window %d: cannot claim keystroke delivery (%s).\n"
                "wsys: another process holds it; this window would receive no "
                "keyboard input.\n", (int)wid, strerror(e));
        errno = e;
        return -1;
    }
    keychan[keychan_n].wid = wid;
    keychan[keychan_n].fd  = s;
    keychan_n++;
    /* This process is now the recipient of a window's keystrokes.  AFTER the
     * bind, not before: a process that failed to claim the channel is not a
     * window owner and has no reason to give up its core dumps. */
    owner_harden();
    return 0;
}

static void keychan_unbind(int32_t wid)
{
    for (int i = 0; i < keychan_n; i++)
        if (keychan[i].wid == wid) {
            close(keychan[i].fd);
            keychan[i] = keychan[keychan_n - 1];
            keychan_n--;
            return;
        }
}

/* Send.  Nobody bound is not an error the compositor can act on -- it is the
 * old "wrote into a ring nobody drains", and it happens legitimately between
 * `newwindow` and the owner's first open of its own /keys.  The bytes are
 * reported as accepted, exactly as the ring reported them. */
static int64_t keychan_send(int32_t wid, const uint8_t *b, uint64_t n)
{
    struct sockaddr_un a;
    socklen_t alen = keychan_addr(&a, wid);
    if (!alen) { errno = EIO; return -1; }
    if (keychan_out < 0) {
        keychan_out = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
        if (keychan_out < 0) return -1;
    }
    ssize_t w = sendto(keychan_out, b, (size_t)n, 0, (struct sockaddr *)&a, alen);
    if (w < 0 && errno != ECONNREFUSED && errno != ENOENT && errno != EAGAIN)
        return -1;
    /* The wake is unchanged: a parked client sleeps on `inputgen` in the shared
     * segment and re-checks its own rings, so the futex still carries the
     * wakeup and sys_waitfds needs no new mechanism. */
    if (n) input_posted();
    return (int64_t)n;
}

/* Receive, dropping every datagram the kernel did not stamp with an acceptable
 * sender.  Only whole datagrams are returned, and a short buffer TRUNCATES one
 * rather than splitting it across two reads: a key event is one line and the
 * callers read with kilobyte buffers. */
static uint64_t keychan_recv(int32_t wid, uint8_t *b, uint64_t cap)
{
    int s = keychan_find(wid);
    if (s < 0 || cap == 0) return 0;
    uint64_t got = 0;
    for (;;) {
        char cbuf[CMSG_SPACE(sizeof(struct ucred))];
        struct iovec io;
        struct msghdr m;
        io.iov_base = b + got;
        io.iov_len  = (size_t)(cap - got);
        memset(&m, 0, sizeof m);
        m.msg_iov = &io;
        m.msg_iovlen = 1;
        m.msg_control = cbuf;
        m.msg_controllen = sizeof cbuf;
        ssize_t n = recvmsg(s, &m, MSG_DONTWAIT);
        if (n <= 0) break;

        int ok = 0;
        for (struct cmsghdr *c = CMSG_FIRSTHDR(&m); c; c = CMSG_NXTHDR(&m, c))
            if (c->cmsg_level == SOL_SOCKET && c->cmsg_type == SCM_CREDENTIALS) {
                struct ucred u;
                memcpy(&u, CMSG_DATA(c), sizeof u);
                if ((seg_owner_known && u.uid == seg_owner) ||
                    u.pid == getpid())
                    ok = 1;
            }
        if (!ok) continue;                     /* not the compositor: dropped */
        got += (uint64_t)n;
        if (got >= cap) break;
    }
    return got;
}

static int keychan_ready(int32_t wid)
{
    int s = keychan_find(wid);
    if (s < 0) return 0;
    struct pollfd p;
    p.fd = s; p.events = POLLIN; p.revents = 0;
    int r;
    do { r = poll(&p, 1, 0); } while (r < 0 && errno == EINTR);
    return r > 0 && (p.revents & POLLIN) != 0;
}

/* ================================================================== *
 * THE PIXEL HAND-UP — the v1 display list is not in the segment either
 * ==================================================================
 *
 * WHAT THIS CLOSES.  THE SPLIT's SCRAPE, for the v1 scene: a uid-1001 process
 * opens /srv/wsys O_RDONLY, maps it PROT_READ, walks win[] and reads another
 * window's COMMITTED DISPLAY LIST.  That is not a picture, it is TEXT -- the
 * scene grammar's `glyphs` op carries the actual string it draws -- so scraping
 * a terminal's scene is reading what is on its screen, letter for letter,
 * without a single write and without the victim being able to tell.  It needs
 * nothing but O_RDONLY, and the table has to stay world-READABLE because
 * /dev/wsys/windows is the panel taskbar's input.  No file mode can reach it,
 * for the same reason none could reach the keylogger.
 *
 * So the display list is not in a shared mapping any more.  Each window's
 * scene and stage live in a per-window MEMFD that the window's OWNER creates,
 * and win[].scene_dead/stage_dead are dead storage nothing reads or writes.
 *
 * WHY A MEMFD IS ALLOWED TO BE THE ANSWER HERE WHEN IT WAS NOT FOR THE KEYS.
 * THE SPLIT's original tier 2 said a memfd has no name in the filesystem and
 * therefore no path for a bypasser to open; that was DISPROVED by measurement
 * -- /proc/<pid>/fd/<n> IS a path, openable by any process of the same uid, and
 * `1 PASSWORD31337` was read straight back out of a victim's memfd.  The
 * keystroke channel went to a socket instead.  What changed since is not the
 * argument, it is the machine: every window owner now calls
 * prctl(PR_SET_DUMPABLE, 0) (owner_harden, above, from keychan_bind -- and
 * from pix_own below, so a window that never binds a keyboard is covered too)
 * and PID 1 sets kernel.yama.ptrace_scope=1.  Against a hardened owner the same
 * probe measures open(/proc/<victim>/fd/N) = -13 and ptrace = -1.  So the /proc
 * path is shut and the memfd construction is viable -- for THESE bytes, which
 * unlike a keystroke must be read by a compositor at frame rate and therefore
 * cannot be datagrams.  tests/linux/wsys_keychan.sh drives both halves of that
 * sentence and tests/linux/wsys_bypass.sh drives it against a real owner.
 *
 * A MEMFD NEEDS NO AUTHORITY TO CREATE IT, which is the whole reason this could
 * be built without tier 1.  THE SPLIT records the memfd design as blocked on "a
 * daemon, a new binary, a package-channel change and a segment at a new path",
 * and every one of those blockers came from the assumption that the AUTHORITY
 * creates the memfd and HANDS IT DOWN to one client.  It does not have to.
 * memfd_create(2) is unprivileged; the client creates its own and hands it UP.
 * The direction is what makes the difference:
 *
 *   HANDING DOWN needs an authority, because the recipient must be proved to be
 *   the window's owner, and the only ownership record available is win[].pid in
 *   the 0666 table -- which is spoofable, which is exactly why THE SPLIT rules
 *   the "title-only RPC" unsound.
 *
 *   HANDING UP needs no ownership record at all.  The bytes start in the one
 *   process that is definitionally entitled to them (it made them), and the
 *   only question is who ELSE may have them.  That question is answered by the
 *   kernel: the sender checks SO_PEERCRED on the connection before it passes
 *   the descriptor, and passes it only to the SEGMENT OWNER -- root on a real
 *   boot, which is wsysd.  Nothing reads win[].pid.  It is the keystroke
 *   channel's rule, run in the opposite direction.
 *
 * THE MECHANISM, in full.
 *
 *   THE MEMFD.  memfd_create(MFD_CLOEXEC|MFD_ALLOW_SEALING), ftruncate to
 *   sizeof(struct wpix), then sealed F_SEAL_SHRINK|F_SEAL_GROW|F_SEAL_SEAL.
 *   THE SHRINK SEAL IS NOT HYGIENE, IT IS THE COMPOSITOR'S LIFE: a receiver
 *   that has mapped a file another process can ftruncate smaller takes SIGBUS
 *   on the next touch, and the receiver here is the process that paints the
 *   whole screen.  The seal is applied by the creator, before the descriptor
 *   is ever passed, and F_SEAL_SEAL makes it permanent.  The RECEIVER checks
 *   the seals anyway (pix_install) rather than trusting a sender it has just
 *   finished refusing to trust about everything else.
 *
 *   THE RENDEZVOUS.  An abstract AF_UNIX SOCK_SEQPACKET listener at
 *   "hamnix-wsys/<st_dev>.<st_ino>/pixels" -- the same naming as the keystroke
 *   channel, derived from the segment's identity so two harnesses cannot
 *   collide.  The COMPOSITOR listens; the OWNER connects, checks, sends and
 *   closes.
 *
 *   WHO MAY LISTEN, and the trap that decided this.  The obvious construction
 *   is the keystroke channel's exactly: the receiver binds and checks
 *   SCM_CREDENTIALS on what arrives.  IT INVERTS THE BOUNDARY HERE.  An
 *   abstract name has no mode, so a uid-1001 attacker can bind the listener
 *   first, and then every client on the desktop would hand IT their display
 *   lists -- a strictly worse hole than the one being closed, arrived at by
 *   copying a construction that is correct for the other direction.  What makes
 *   the two differ is which end holds the secret: for keystrokes the RECEIVER
 *   is the one to protect, so the receiver checks; for pixels the SENDER holds
 *   them, so THE SENDER CHECKS.  connect(2) on an AF_UNIX socket gives the
 *   client SO_PEERCRED for the listener it reached, stamped by the kernel, so
 *   the check is available before a single byte is sent.  A client that finds
 *   the listener is not owned by the segment's owner sends nothing and says so
 *   on stderr.  tests/linux/wsys_bypass.sh drives that attacker.
 *
 *   WHO MAY LISTEN, second half: only a process that IS the segment owner ever
 *   calls bind here (pix_listen refuses otherwise), so the ordinary
 *   scene-reading path cannot be tricked into taking the name on an attacker's
 *   behalf.  An attacker with its own socket code can still take it -- see the
 *   residue below.
 *
 *   ONLY A LONG-LIVED LISTENER EVER RECEIVES ANYTHING, and that is a property
 *   of the design rather than an accident of it.  The hand-up is the CLIENT's
 *   action, taken on its own clock; a process that binds the address, drains an
 *   empty queue and exits has given nobody a chance to hand it anything.  So a
 *   compositor is a process that STAYS -- which wsysd is -- and there is no
 *   one-shot "read another window's scene" tool, by construction.  Nothing in
 *   this tree wanted one: every other reader of <wid>/scene in the tree reads
 *   its OWN window.  It is also, incidentally, what stops a hit-and-run
 *   attacker: taking the name for a moment yields an empty queue.
 *
 *   THE HAND-UP IS ON A CLOCK, NOT ON A COMMIT COUNT -- see pix_tick below for
 *   the hole that distinction closes and why it is not a detail.  Every window
 *   this process owns is offered every PIX_RETRY_MS while nobody holds it and
 *   re-announced every PIX_REANN_MS after that, driven from every wsys
 *   operation, so a compositor that starts late or restarts gets every window's
 *   descriptor within a few seconds whether or not the window ever draws again.
 *   The receiver recognises a duplicate by the memfd's st_ino and drops it, so
 *   a re-announce costs a connect and a close.
 *
 *   COST, against the census in THE SPLIT.  A commit is a LIFECYCLE-rate event
 *   for a still window and a per-frame event for a moving one; the hand-up adds
 *   one socket, one connect, one getsockopt, one sendmsg and one close per
 *   window per PIX_REANNOUNCE commits.  On the measured desktop (34.6 per-frame
 *   writes a second under a moving mouse) that is under one hand-up a second
 *   across the whole session.  The bytes themselves cost NOTHING: the client
 *   writes its display list into its own mapping and the compositor reads it
 *   out of the same pages.  The scene memcpy at commit is the memcpy that was
 *   already there.
 *
 * WHAT AN ATTACKER CAN STILL DO, named here rather than left to be found:
 *
 *   THE v2 BACKBUFFER IS UNTOUCHED, and it is the important one to say out loud
 *   because it decides which windows this protects.  /srv/wsys.bb is a third
 *   0666 mapping holding every v2 window's pixels, and a v2 window is what a
 *   browser, a video and a bridged X client are.  So: a hamUI application's
 *   screen contents are out of the shared mapping and FIREFOX'S ARE NOT.  A
 *   person cannot tell those apart by looking, which is why wsys_bypass.sh
 *   drives a backbuffer scrape as a POSITIVE control on every green run.  The
 *   construction here is the one the backbuffer needs -- per-window memfd,
 *   sender-checked hand-up -- and applying it there is a pool rewrite (the
 *   slots are shared, page-mapped on demand and accounted centrally), which is
 *   a pass and not a paragraph.
 *
 *   THE NAMED IMAGES ARE UNTOUCHED (/srv/wsys.img, THE NAMED-IMAGE STORE below)
 *   for the same reason and by the same measure.
 *
 *   ENUMERATION IS UNTOUCHED and stays unfixable while /dev/wsys/windows is the
 *   taskbar's input: every row's wid, pid, geometry and TITLE is still readable
 *   by anything on the machine.  What a scraper loses is the CONTENT of the
 *   window, not its existence or its name.
 *
 *   CORRUPTION IS NOT CLOSED AND IS NOT MADE WORSE.  An attacker can no longer
 *   write another window's display list (it has no descriptor for it), but it
 *   can still take the listener's name or race a hand-up, and it can still
 *   retitle, move, hide and destroy any row.  A window whose contents cannot be
 *   read can still be lied about.  Integrity needs tier 1 and always did.
 *
 *   DENIAL OF SERVICE BY NAME-SQUATTING.  A same-uid attacker that binds
 *   "…/pixels" before wsysd does makes wsysd's own bind EADDRINUSE, and the
 *   desktop then paints no v1 window at all.  That is loud (wsysd says so by
 *   name on stderr, and the screen is visibly empty) where the alternative
 *   would have been silent, and it is the same trade the keystroke channel made
 *   for the same reason -- denial of service by a same-uid process was already
 *   free, since `newwindow` is open to every uid and anyone may exhaust the
 *   table.  It is worth being exact that the blast radius is bigger here: the
 *   keystroke squat cost one window, this costs every v1 window.
 * ------------------------------------------------------------------ */

#define WPIX_MAGIC        0x58495057u        /* "WPIX" */
#define WPIX_VERSION      1
#define PIXCHAN_MAX       WSYS_MAX_WINDOWS

/* THE MEMFD'S CONTENTS.  The two LENGTHS live in here and not in the 0666
 * table, and that is deliberate: a length in the world-writable segment is a
 * number an attacker chooses for a buffer it cannot see, which is how a
 * confidentiality fix turns into an over-read.  Here the only writer is the
 * window's owner and the compositor, and both are clamped again on use. */
struct wpix {
    uint32_t magic, version;
    int32_t  wid;
    uint32_t scene_len;                       /* published */
    uint32_t stage_len;                       /* being written */
    uint32_t gen;                             /* ++ on every commit */
    uint8_t  scene[WSYS_SCENE_CAP];
    uint8_t  stage[WSYS_SCENE_CAP];
};

static struct {
    int32_t      wid;
    int          fd;
    struct wpix *m;
    int          own;                         /* we created it */
    uint64_t     due;                         /* next hand-up attempt, ms */
    int          handed;                      /* a hand-up has succeeded */
    uint64_t     ino;                         /* the memfd's, for dup detect */
} pixmap[PIXCHAN_MAX];
static int pixmap_n;
static int pix_listen_fd = -1;
static int pix_listen_tried;
static uint64_t pix_next_tick;                /* monotonic ms */

static int pix_slot(int32_t wid)
{
    for (int i = 0; i < pixmap_n; i++)
        if (pixmap[i].wid == wid) return i;
    return -1;
}

static void pix_release(int32_t wid)
{
    int i = pix_slot(wid);
    if (i < 0) return;
    if (pixmap[i].m) munmap(pixmap[i].m, sizeof(struct wpix));
    if (pixmap[i].fd >= 0) close(pixmap[i].fd);
    pixmap[i] = pixmap[pixmap_n - 1];
    pixmap_n--;
}

/* The abstract address the compositor listens on.  0 when the segment identity
 * is not established -- in which case there is no channel and every caller
 * fails rather than inventing one, exactly as keychan_addr does. */
static socklen_t pix_addr(struct sockaddr_un *a)
{
    if (!seg_id_known) return 0;
    memset(a, 0, sizeof *a);
    a->sun_family = AF_UNIX;
    a->sun_path[0] = '\0';                     /* abstract */
    int n = snprintf(a->sun_path + 1, sizeof a->sun_path - 1,
                     "hamnix-wsys/%llu.%llu/pixels",
                     (unsigned long long)seg_dev, (unsigned long long)seg_ino);
    if (n <= 0 || (size_t)n >= sizeof a->sun_path - 1) return 0;
    return (socklen_t)(offsetof(struct sockaddr_un, sun_path) + 1 + n);
}

/* Map a descriptor we hold, whether we made it or were handed it.  Refuses
 * anything that is not the right size or does not carry the right seals: a
 * receiver that maps a sender's fd on the sender's word takes SIGBUS the first
 * time that sender shrinks it. */
static int pix_map(int i, int rw)
{
    struct stat st;
    if (fstat(pixmap[i].fd, &st) < 0) return -1;
    if ((uint64_t)st.st_size != (uint64_t)sizeof(struct wpix)) {
        errno = EINVAL; return -1;
    }
    int seals = fcntl(pixmap[i].fd, F_GET_SEALS);
    if (seals < 0 || !(seals & F_SEAL_SHRINK)) { errno = EINVAL; return -1; }
    void *m = mmap(NULL, sizeof(struct wpix),
                   rw ? (PROT_READ | PROT_WRITE) : PROT_READ,
                   MAP_SHARED, pixmap[i].fd, 0);
    if (m == MAP_FAILED) return -1;
    pixmap[i].m   = (struct wpix *)m;
    pixmap[i].ino = (uint64_t)st.st_ino;
    return 0;
}

/* THE OWNER'S SIDE: get, or create, this process's own pixel memory for a
 * window.  Creating one makes this process a window owner in the sense
 * owner_harden means, so it hardens -- keychan_bind is the usual place a
 * process becomes one, but a window that never reads a key still has pixels. */
static struct wpix *pix_own(int32_t wid)
{
    int i = pix_slot(wid);
    if (i >= 0) return pixmap[i].m;
    if (pixmap_n >= PIXCHAN_MAX) { errno = ENOSPC; return NULL; }

    int fd = (int)syscall(SYS_memfd_create, "hamnix-wsys-scene",
                          MFD_CLOEXEC | MFD_ALLOW_SEALING);
    if (fd < 0) {
        fprintf(stderr, "wsys: window %d: memfd_create failed (%s): this "
                "window has nowhere private to keep its display list.\n",
                (int)wid, strerror(errno));
        return NULL;
    }
    if (ftruncate(fd, (off_t)sizeof(struct wpix)) < 0
        || fcntl(fd, F_ADD_SEALS,
                 F_SEAL_SHRINK | F_SEAL_GROW | F_SEAL_SEAL) < 0) {
        fprintf(stderr, "wsys: window %d: cannot seal its display list (%s).\n",
                (int)wid, strerror(errno));
        close(fd);
        return NULL;
    }
    i = pixmap_n;
    pixmap[i].wid = wid; pixmap[i].fd = fd; pixmap[i].m = NULL;
    pixmap[i].own = 1;  pixmap[i].due = 0;
    pixmap[i].handed = 0; pixmap[i].ino = 0;
    if (pix_map(i, 1) < 0) {
        fprintf(stderr, "wsys: window %d: cannot map its display list (%s).\n",
                (int)wid, strerror(errno));
        close(fd);
        return NULL;
    }
    pixmap_n++;
    pixmap[i].m->magic   = WPIX_MAGIC;
    pixmap[i].m->version = WPIX_VERSION;
    pixmap[i].m->wid     = wid;
    owner_harden();
    return pixmap[i].m;
}

/* THE COMPOSITOR'S SIDE: take the name.  ONLY the segment owner ever binds it.
 * A client that merely wants to read a foreign scene must not be able to make
 * this call happen on an attacker's behalf, and a non-owner has no business
 * receiving anyone's pixels in the first place. */
static void pix_listen(void)
{
    if (pix_listen_fd >= 0 || pix_listen_tried) return;
    pix_listen_tried = 1;
    if (!hostowner()) return;

    struct sockaddr_un a;
    socklen_t alen = pix_addr(&a);
    if (!alen) return;
    int s = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    if (s < 0) return;
    if (bind(s, (struct sockaddr *)&a, alen) < 0) {
        fprintf(stderr,
                "wsys: cannot claim the pixel hand-up address (%s).\n"
                "wsys: another process holds it, so no window can hand this "
                "one its display list and NOTHING WILL BE PAINTED.\n",
                strerror(errno));
        close(s);
        return;
    }
    /* Deep enough that a burst of clients coming up together is queued rather
     * than refused: a refused hand-up costs a frame, but only until the
     * client's next commit retries. */
    if (listen(s, 64) < 0) { close(s); return; }
    pix_listen_fd = s;
}

/* Install a descriptor that arrived on the listener.  A duplicate (the same
 * memfd inode, from a re-announce) is closed and forgotten. */
static void pix_install(int32_t wid, int fd)
{
    int i = pix_slot(wid);
    if (i >= 0) {
        struct stat st;
        if (fstat(fd, &st) == 0 && (uint64_t)st.st_ino == pixmap[i].ino) {
            close(fd);                         /* the one we already hold */
            return;
        }
        pix_release(wid);
    }
    if (pixmap_n >= PIXCHAN_MAX) { close(fd); return; }
    i = pixmap_n;
    pixmap[i].wid = wid; pixmap[i].fd = fd; pixmap[i].m = NULL;
    pixmap[i].own = 0;  pixmap[i].due = 0;
    pixmap[i].handed = 0; pixmap[i].ino = 0;
    /* READ-WRITE, deliberately.  The compositor is the host owner and the uid
     * gate has always let it write any window's scene (wsysd does not, but
     * hamctl and the gates do); refusing it here would be a behaviour change
     * smuggled in under a confidentiality fix. */
    if (pix_map(i, 1) < 0) {
        close(fd);
        return;
    }
    if (pixmap[i].m->magic != WPIX_MAGIC
        || pixmap[i].m->version != WPIX_VERSION
        || pixmap[i].m->wid != wid) {
        munmap(pixmap[i].m, sizeof(struct wpix));
        close(fd);
        return;
    }
    pixmap_n++;
    /* TELL THE COMPOSITOR THERE IS SOMETHING NEW TO PAINT, and this line is
     * the whole difference between a window and a blank rectangle.
     *
     * wsysd repaints when shm->gen moves and not otherwise -- that is what
     * makes an idle desktop cost nothing (tests/linux/de_idle_cpu.sh).  A
     * hand-up that arrives AFTER the frame in which the window was refused
     * therefore changes nothing anybody looks at: the descriptor is held, the
     * display list is readable, and no frame is ever drawn again.  Measured:
     * hamimgscene came up, uploaded its photograph, parked, handed its
     * descriptor over -- and the screen stayed empty, with ONE line on wsysd's
     * stderr and three seconds of nothing after it.
     *
     * Receiving a window's pixels for the first time IS a change to what this
     * process renders, so it belongs on the same counters as every other one.
     *
     * AND IT IS THE ROW'S scene_gen THAT HAS TO MOVE, not just shm->gen, which
     * cost a second run to find out: user/wsysd.ad's frame_signature() is an
     * FNV hash over the WINDOWS -- geometry, z, title, scene_gen, bbgen, imggen
     * -- and shm->gen is not in it at all.  Bumping only the segment counter
     * moved a number nothing was watching.  scene_gen is the right one on its
     * meaning as well as its effect: this row was advertising a frame that
     * could not be fetched and now advertises one that can, which from every
     * reader's side is a new frame. */
    if (shm) {
        struct wwin *v = win_find(wid);
        if (v) v->scene_gen++;
        shm->gen++;
    }
}

/* Drain the accept queue.  Called before any read of a foreign window's scene,
 * which on a real desktop is once per window per frame -- an accept(2) on an
 * empty non-blocking queue is one failed syscall and that is the whole cost. */
static void pix_drain(void)
{
    if (pix_listen_fd < 0) return;
    for (;;) {
        int c = accept4(pix_listen_fd, NULL, NULL, SOCK_CLOEXEC | SOCK_NONBLOCK);
        if (c < 0) break;
        /* One message, one descriptor, and the wid is in the payload rather
         * than taken from anything shared: a hand-up says which window it is
         * for and the receiver believes only the descriptor, which it then
         * checks against the header the creator stamped. */
        int32_t wid = 0;
        char cbuf[CMSG_SPACE(sizeof(int))];
        struct iovec io;
        struct msghdr m;
        io.iov_base = &wid; io.iov_len = sizeof wid;
        memset(&m, 0, sizeof m);
        m.msg_iov = &io; m.msg_iovlen = 1;
        m.msg_control = cbuf; m.msg_controllen = sizeof cbuf;
        /* One blocking-free read; the sender writes before it closes, and a
         * sender that does not is simply retried on its next commit. */
        struct pollfd p; p.fd = c; p.events = POLLIN; p.revents = 0;
        int pr; do { pr = poll(&p, 1, 50); } while (pr < 0 && errno == EINTR);
        ssize_t n = (pr > 0) ? recvmsg(c, &m, MSG_DONTWAIT) : -1;
        int got = -1;
        if (n == (ssize_t)sizeof wid)
            for (struct cmsghdr *cm = CMSG_FIRSTHDR(&m); cm;
                 cm = CMSG_NXTHDR(&m, cm))
                if (cm->cmsg_level == SOL_SOCKET && cm->cmsg_type == SCM_RIGHTS)
                    memcpy(&got, CMSG_DATA(cm), sizeof got);
        close(c);
        if (got >= 0) {
            if (wid > 0) pix_install(wid, got);
            else         close(got);
        }
    }
}

/* THE HAND-UP.  Connect, ASK THE KERNEL WHO IS LISTENING, and pass the
 * descriptor only if the answer is the segment's owner.  This is the check the
 * whole construction rests on: everything else here is plumbing. */
static void pix_handup_one(int i)
{
    int32_t wid = pixmap[i].wid;
    struct sockaddr_un a;
    socklen_t alen = pix_addr(&a);
    if (!alen) return;
    int s = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
    if (s < 0) return;
    if (connect(s, (struct sockaddr *)&a, alen) < 0) {
        /* Nobody is listening: no compositor yet, or none any more.  Not an
         * error the client can act on, and the next tick tries again. */
        close(s);
        pixmap[i].handed = 0;
        return;
    }
    struct ucred pc;
    socklen_t pl = sizeof pc;
    if (getsockopt(s, SOL_SOCKET, SO_PEERCRED, &pc, &pl) < 0
        || pl != sizeof pc
        || !seg_owner_known || pc.uid != seg_owner) {
        /* THE REFUSAL THAT IS THE POINT.  Somebody who is not the window
         * system's owner is holding the hand-up address.  Say so, loudly and
         * once per window, and hand over nothing. */
        static int said;
        if (!said) {
            said = 1;
            fprintf(stderr,
                    "wsys: the pixel hand-up address is held by uid %ld, not by "
                    "this window system's owner (uid %ld).\n"
                    "wsys: no window's display list will be handed to it; "
                    "windows will not be painted until that is fixed.\n",
                    (long)(pl == sizeof pc ? (long)pc.uid : -1L),
                    (long)(seg_owner_known ? (long)seg_owner : -1L));
        }
        close(s);
        pixmap[i].handed = 0;
        return;
    }

    char cbuf[CMSG_SPACE(sizeof(int))];
    struct iovec io;
    struct msghdr m;
    int32_t w = wid;
    io.iov_base = &w; io.iov_len = sizeof w;
    memset(&m, 0, sizeof m);
    memset(cbuf, 0, sizeof cbuf);
    m.msg_iov = &io; m.msg_iovlen = 1;
    m.msg_control = cbuf; m.msg_controllen = sizeof cbuf;
    struct cmsghdr *cm = CMSG_FIRSTHDR(&m);
    cm->cmsg_level = SOL_SOCKET;
    cm->cmsg_type  = SCM_RIGHTS;
    cm->cmsg_len   = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(cm), &pixmap[i].fd, sizeof(int));
    pixmap[i].handed = (sendmsg(s, &m, MSG_NOSIGNAL) >= 0);
    close(s);
}

static uint64_t pix_now_ms(void)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) < 0) return 0;
    return (uint64_t)ts.tv_sec * 1000u + (uint64_t)(ts.tv_nsec / 1000000);
}

/* HAND UP WHAT NEEDS HANDING UP, ON A CLOCK AND NOT ON A COMMIT COUNT.
 *
 * The first draft counted commits, and it had a hole a person would meet on an
 * ordinary day: a compositor that starts (or RESTARTS) after a window has
 * already drawn itself gets that window's descriptor only when the window
 * commits again -- and a window that is merely SITTING THERE never commits
 * again.  The desktop would come back with the wallpaper and the panel painted
 * and the person's terminal a blank rectangle, for ever, with nothing on
 * stderr.  That is precisely the success-shaped answer this file exists to
 * refuse.
 *
 * A clock has no such state.  Every window this process owns is offered
 * PIX_RETRY_MS after its last attempt while it is unheld, and PIX_REANN_MS
 * after a successful one, and the tick is driven from every wsys operation --
 * a client that is doing nothing at all still drains its event ring on its
 * 250 ms park, which is a library call.  The global gate means the cost is one
 * clock_gettime (vDSO, no syscall) per operation and nothing else.
 *
 * WHAT IT COSTS ON AN IDLE DESKTOP, since de_idle_cpu.sh is the gate that
 * would catch a park turned into a spin: one connect/getsockopt/sendmsg/close
 * per owned window per PIX_REANN_MS.  Three windows at 3 s is one hand-up a
 * second across the whole session. */
#define PIX_RETRY_MS   500                    /* while nobody holds it */
#define PIX_REANN_MS   3000                   /* re-announce, for a restart */

static void pix_tick(void)
{
    if (!pixmap_n && pix_listen_fd < 0) return;
    uint64_t now = pix_now_ms();
    if (now < pix_next_tick) return;
    pix_next_tick = now + PIX_RETRY_MS;
    for (int i = 0; i < pixmap_n; i++) {
        if (!pixmap[i].own || now < pixmap[i].due) continue;
        pix_handup_one(i);
        pixmap[i].due = now + (pixmap[i].handed ? PIX_REANN_MS : PIX_RETRY_MS);
    }
    /* AND THE RECEIVING SIDE, ON THE SAME SEAM, BECAUSE THE TWO DEADLOCKED.
     *
     * Draining only from the scene-read path looks sufficient and is not, and
     * the failure is a cycle rather than an omission: wsysd repaints when
     * shm->gen moves, reads a scene only when it repaints, and drained only
     * when it read a scene -- so a descriptor that arrives after the frame in
     * which the window was refused is never accepted, nothing bumps gen,
     * nothing repaints, and nothing drains.  The window is blank for ever with
     * ONE line on stderr.  Measured, with hamimgscene: the client's second
     * hand-up connected and succeeded, and the compositor never accepted it.
     *
     * The park breaks it because the park is the one thing both sides do while
     * idle.  An accept4 on an empty non-blocking queue is a single failed
     * syscall twice a second. */
    pix_drain();
}

/* ================================================================== *
 * THE BACKBUFFER HAND-UP — the pixel hand-up, run for the v2 pixels
 * ==================================================================
 *
 * This is THE PIXEL HAND-UP's construction (above), applied to the v2
 * backbuffer memfds bb_own creates.  Every argument there holds here unchanged:
 * the rendezvous is an abstract AF_UNIX SOCK_SEQPACKET name derived from the
 * segment's identity, so it collides with nothing and needs no file mode; the
 * SENDER checks SO_PEERCRED, because the sender holds the pixels and the
 * question is who else may have them; only the segment owner ever binds; the
 * hand-up is on a clock, so a compositor that starts late or restarts is caught
 * up within a few seconds; and a duplicate is recognised by the memfd's inode.
 *
 * The ONLY differences from pix_* are the address suffix ("backbuffer" not
 * "pixels") and the payload it maps (a bbpix header, not a wpix).  It is a
 * separate channel rather than the same one because the payloads differ in size
 * by three orders of magnitude and a v1 and a v2 window do not overlap -- see
 * THE BACKBUFFER MEMFD.  tests/linux/wsys_bypass.sh's `bbgrab` drives both the
 * owner (which must be handed the descriptor) and a same-uid attacker (which
 * must not), exactly as `pixgrab` does for the scene. */
static int bbup_listen_fd = -1;
/* Set the first time this process reads a window it does not own -- see THE
 * COMPOSITOR IS THE PROCESS THAT READS SOMEBODY ELSE'S WINDOW. Sticky, because
 * the act identifies the process for good: a client never performs it once. */
static int bbup_is_compositor;
static int bbup_listen_tried;
static uint64_t bbup_next_tick;

static socklen_t bbup_addr(struct sockaddr_un *a)
{
    if (!seg_id_known) return 0;
    memset(a, 0, sizeof *a);
    a->sun_family = AF_UNIX;
    a->sun_path[0] = '\0';                     /* abstract */
    int n = snprintf(a->sun_path + 1, sizeof a->sun_path - 1,
                     "hamnix-wsys/%llu.%llu/backbuffer",
                     (unsigned long long)seg_dev, (unsigned long long)seg_ino);
    if (n <= 0 || (size_t)n >= sizeof a->sun_path - 1) return 0;
    return (socklen_t)(offsetof(struct sockaddr_un, sun_path) + 1 + n);
}

/* Map a received backbuffer memfd's header, refusing anything that is not the
 * right size or missing the shrink seal -- a receiver that trusts a sender's
 * word about either takes SIGBUS when the sender lies. */
static int bbup_map(int i)
{
    struct stat st;
    if (fstat(bbmap[i].fd, &st) < 0) return -1;
    if ((uint64_t)st.st_size != (uint64_t)BBPIX_BYTES) { errno = EINVAL; return -1; }
    int seals = fcntl(bbmap[i].fd, F_GET_SEALS);
    if (seals < 0 || !(seals & F_SEAL_SHRINK)) { errno = EINVAL; return -1; }
    void *m = mmap(NULL, BBPIX_HDR_BYTES, PROT_READ | PROT_WRITE,
                   MAP_SHARED, bbmap[i].fd, 0);
    if (m == MAP_FAILED) return -1;
    bbmap[i].hdr = (struct bbpix *)m;
    bbmap[i].ino = (uint64_t)st.st_ino;
    return 0;
}

/* THE COMPOSITOR'S SIDE: take the name.  ONLY the segment owner ever binds it,
 * for the reason pix_listen gives -- a non-owner has no business receiving
 * anyone's pixels and must not be able to make this call happen on its behalf. */
static void bbup_listen(void)
{
    /* IT RETRIES, AND THE LATCH IT REPLACES IS WHY BROWSERS WENT BLANK.
     *
     * This used to set `tried` on the first call and never attempt again.  A
     * first call that arrives before the segment's identity or owner is known
     * -- and one does, because sys_waitfds drives hamwsys_tick and a process
     * parks before it has touched /dev/wsys -- returned early with the latch
     * already set, so the compositor NEVER bound for the rest of its life.
     * Every client's hand-up was then refused (ECONNREFUSED, measured eleven
     * times in one run) and every v2 window stayed blank with nothing on any
     * log.  A transient reason not to bind must not be permanent: the address
     * may also be held by a process that is about to exit.
     *
     * The DIAGNOSTIC is still once per process, because a compositor that
     * cannot bind would otherwise print a line per park for ever. */
    if (bbup_listen_fd >= 0) return;
    if (!hostowner()) return;
    struct sockaddr_un a;
    socklen_t alen = bbup_addr(&a);
    if (!alen) return;
    int s = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    if (s < 0) return;
    if (bind(s, (struct sockaddr *)&a, alen) < 0) {
        if (!bbup_listen_tried) {
            bbup_listen_tried = 1;
            fprintf(stderr,
                    "wsys: cannot claim the backbuffer hand-up address (%s).\n"
                    "wsys: another process holds it, so no v2 window can hand "
                    "this one its pixels and BROWSERS WILL NOT BE PAINTED.\n",
                    strerror(errno));
        }
        close(s);
        return;
    }
    if (listen(s, 64) < 0) { close(s); return; }
    bbup_listen_fd = s;
}

/* Install a received descriptor.  A duplicate (the same inode, from a
 * re-announce) is dropped; a first arrival bumps the window's scene_gen and
 * shm->gen so the compositor repaints -- the same wake pix_install needs, for
 * the same reason (wsysd only repaints when the frame signature moves). */
static void bbup_install(int32_t wid, int fd)
{
    int i = bb_find(wid);
    if (i >= 0) {
        struct stat st;
        if (fstat(fd, &st) == 0 && (uint64_t)st.st_ino == bbmap[i].ino) {
            close(fd);                         /* the one we already hold */
            return;
        }
        bb_release(wid);
    }
    if (bbmap_n >= WSYS_MAX_WINDOWS) { close(fd); return; }
    i = bbmap_n;
    bbmap[i].wid = wid; bbmap[i].fd = fd; bbmap[i].hdr = NULL;
    bbmap[i].px[0] = NULL; bbmap[i].px[1] = NULL;
    bbmap[i].own = 0; bbmap[i].due = 0; bbmap[i].handed = 0; bbmap[i].ino = 0;
    if (bbup_map(i) < 0) { close(fd); return; }
    if (bbmap[i].hdr->magic != BBPIX_MAGIC
        || bbmap[i].hdr->version != BBPIX_VERSION
        || bbmap[i].hdr->wid != wid) {
        munmap(bbmap[i].hdr, BBPIX_HDR_BYTES);
        close(fd);
        return;
    }
    bbmap_n++;
    /* DO NOT TOUCH scene_gen HERE, AND THIS IS THE WHOLE PAINT PATH OF EVERY
     * BROWSER.  pix_install bumps it because a v1 window's new display list is
     * only visible through that counter.  Doing the same for a v2 window is a
     * SILENT KILL: the scene open path (HAMWSYS_WIN_SCENE, above) serves a v2
     * window's scene as a 0-byte SUCCESS only while `scene_gen == 0` -- that is
     * the line whose comment says, in as many words, that without it "A BROWSER,
     * A VIDEO AND EVERY ROOTLESS X CLIENT WOULD STOP BEING PAINTED", because
     * user/wsysd.ad's paint_window slurps <wid>/scene for every window and
     * `if n < 0: return 0` bails before it ever reaches paint_backbuffer.  A v2
     * client never commits a scene, so its scene_gen is 0 for ever; bumping it
     * here turned that 0-byte success into an EPERM refusal and the window was
     * never painted again.  Measured: a fill client that commits no scene
     * painted 0 pixels with the bump and its full blit without it.
     *
     * NOTHING IS LOST BY LEAVING IT ALONE.  The repaint this needs to trigger
     * comes from the BACKBUFFER GEN, which is already in wsysd's frame
     * signature (field 11 of the window ctl, snap_win_ctl above): it reads 0
     * while no memfd is held and the client's real gen the moment one is
     * installed, so accepting a hand-up moves the signature by itself. */
    if (shm) shm->gen++;
}

static void bbup_drain(void)
{
    if (bbup_listen_fd < 0) return;
    for (;;) {
        int c = accept4(bbup_listen_fd, NULL, NULL, SOCK_CLOEXEC | SOCK_NONBLOCK);
        if (c < 0) break;
        int32_t wid = 0;
        char cbuf[CMSG_SPACE(sizeof(int))];
        struct iovec io;
        struct msghdr m;
        io.iov_base = &wid; io.iov_len = sizeof wid;
        memset(&m, 0, sizeof m);
        m.msg_iov = &io; m.msg_iovlen = 1;
        m.msg_control = cbuf; m.msg_controllen = sizeof cbuf;
        struct pollfd p; p.fd = c; p.events = POLLIN; p.revents = 0;
        int pr; do { pr = poll(&p, 1, 50); } while (pr < 0 && errno == EINTR);
        ssize_t n = (pr > 0) ? recvmsg(c, &m, MSG_DONTWAIT) : -1;
        int got = -1;
        if (n == (ssize_t)sizeof wid)
            for (struct cmsghdr *cm = CMSG_FIRSTHDR(&m); cm;
                 cm = CMSG_NXTHDR(&m, cm))
                if (cm->cmsg_level == SOL_SOCKET && cm->cmsg_type == SCM_RIGHTS)
                    memcpy(&got, CMSG_DATA(cm), sizeof got);
        close(c);
        if (got >= 0) {
            if (wid > 0) bbup_install(wid, got);
            else         close(got);
        }
    }
}

/* THE HAND-UP.  Connect, ASK THE KERNEL WHO IS LISTENING, and pass the
 * descriptor only if the answer is the segment's owner. */
static void bbup_handup_one(int i)
{
    int32_t wid = bbmap[i].wid;
    struct sockaddr_un a;
    socklen_t alen = bbup_addr(&a);
    if (!alen) return;
    int s = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
    if (s < 0) return;
    if (connect(s, (struct sockaddr *)&a, alen) < 0) {
        close(s);
        bbmap[i].handed = 0;
        return;
    }
    struct ucred pc;
    socklen_t pl = sizeof pc;
    if (getsockopt(s, SOL_SOCKET, SO_PEERCRED, &pc, &pl) < 0
        || pl != sizeof pc
        || !seg_owner_known || pc.uid != seg_owner) {
        /* THE REFUSAL THAT IS THE POINT: the address is held by someone who is
         * not the window system's owner.  Say so once, and hand over nothing. */
        static int said;
        if (!said) {
            said = 1;
            fprintf(stderr,
                    "wsys: the backbuffer hand-up address is held by uid %ld, not "
                    "by this window system's owner (uid %ld).\n"
                    "wsys: no window's pixels will be handed to it.\n",
                    (long)(pl == sizeof pc ? (long)pc.uid : -1L),
                    (long)(seg_owner_known ? (long)seg_owner : -1L));
        }
        close(s);
        bbmap[i].handed = 0;
        return;
    }
    char cbuf[CMSG_SPACE(sizeof(int))];
    struct iovec io;
    struct msghdr m;
    int32_t w = wid;
    io.iov_base = &w; io.iov_len = sizeof w;
    memset(&m, 0, sizeof m);
    memset(cbuf, 0, sizeof cbuf);
    m.msg_iov = &io; m.msg_iovlen = 1;
    m.msg_control = cbuf; m.msg_controllen = sizeof cbuf;
    struct cmsghdr *cm = CMSG_FIRSTHDR(&m);
    cm->cmsg_level = SOL_SOCKET;
    cm->cmsg_type  = SCM_RIGHTS;
    cm->cmsg_len   = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(cm), &bbmap[i].fd, sizeof(int));
    bbmap[i].handed = (sendmsg(s, &m, MSG_NOSIGNAL) >= 0);
    close(s);
}

/* Owner side hands up, compositor side drains -- on the same clock as the
 * pixel hand-up, and driven from the same seams (see pix_tick). */
static void bbup_tick(void)
{
    /* A COMPOSITOR BINDS ON ITS PARK, NOT ONLY WHEN IT REPAINTS, and the
     * difference is the whole defect.  Which process is a compositor is decided
     * in pix_get, on the one act only a compositor performs (see THE COMPOSITOR
     * IS THE PROCESS THAT READS SOMEBODY ELSE'S WINDOW) -- but that act happens
     * inside the REPAINT path, and repaint is gated on the frame signature
     * moving.  A compositor that has settled repaints nothing, so it read no
     * foreign scene, so it never bound, so the client's hand-up was refused for
     * ever and the window never painted.  MEASURED, pinned to one core:
     * binding only from the backbuffer read was 10 failures in 10; adding the
     * foreign-scene read took it to 3 in 10; binding here, on the park that
     * happens whether or not anything is repainted, takes it to 0 in 10.
     * The flag is what keeps a client out: it never reads a foreign window. */
    if (bbup_is_compositor) bbup_listen();
    if (!bbmap_n && bbup_listen_fd < 0) return;
    uint64_t now = pix_now_ms();
    if (now < bbup_next_tick) return;
    bbup_next_tick = now + PIX_RETRY_MS;
    for (int i = 0; i < bbmap_n; i++) {
        if (!bbmap[i].own || now < bbmap[i].due) continue;
        bbup_handup_one(i);
        bbmap[i].due = now + (bbmap[i].handed ? PIX_REANN_MS : PIX_RETRY_MS);
    }
    bbup_drain();
}

/* THE ONE LOOKUP EVERY SCENE OPERATION GOES THROUGH.  `mine` asks for a window
 * this process owns (create on demand); otherwise this is a reader, and a
 * reader that is the segment owner listens and drains first.
 *
 * A NULL here is a REFUSAL AND MUST BE REPORTED AS ONE.  The caller says which
 * window and why on stderr; a zero-length scene served silently would be this
 * tree's own worst bug shape -- a window that paints nothing and an exit 0. */
static struct wpix *pix_get(int32_t wid, int mine)
{
    if (mine) {
        int i = pix_slot(wid);
        if (i >= 0) return pixmap[i].m;
        return pix_own(wid);
    }
    int i = pix_slot(wid);
    if (i >= 0) return pixmap[i].m;
    /* THE COMPOSITOR IS THE PROCESS THAT READS SOMEBODY ELSE'S WINDOW.
     *
     * Reaching here means this process wants the display list of a window it
     * does not own, which is the one thing a client never does -- every client
     * in this tree reads its OWN window and nothing else -- and the one thing a
     * compositor does constantly, for every window, every frame.  So it is the
     * signal both hand-up listeners are bound on, and the backbuffer's is bound
     * here rather than on the BACKBUFFER read path.
     *
     * WHY IT MOVED.  Binding it from the backbuffer read meant binding only if
     * the compositor happened to repaint a v2 window -- and if it lost that
     * race once, nothing made it try again and the client's connect was refused
     * for ever.  MEASURED with wsysd and the client pinned to one core: 10
     * failures in 10 runs, the client logging ECONNREFUSED and the compositor
     * never binding at all.  Bound here it is 0 in 10, because a compositor
     * reads a foreign scene on its very first frame and on every frame after.
     *
     * AND IT IS WHY A CLIENT CANNOT SQUAT IT on a single-uid host, where every
     * process passes hostowner(): a client never takes this path at all.  The
     * alternative tried first -- bind for any host owner that owns no
     * backbuffer -- let a plain SCENE client bind and never give it back, and
     * tests/linux/wsys_bypass.sh caught it as EADDRINUSE for both ends. */
    bbup_is_compositor = 1;
    pix_listen();
    bbup_listen();
    pix_drain();
    bbup_drain();
    i = pix_slot(wid);
    return i >= 0 ? pixmap[i].m : NULL;
}

/* ==================================================================
 * STAGE 6 — THE SCENE, AND THE FRAME BOUNDARY IS THE WHOLE PROBLEM
 * ==================================================================
 * `/dev/wsys/<wid>/scene` is the last mutation a routed client still performed
 * in process, and it was deferred through four stages for a good reason: 1
 * write per 12 s of a drag against 9790 for `wid/ctl`, so neither the cost nor
 * the privilege question turned on it.  What makes it different is PER-OPEN
 * STATE.  Opening the scene for writing STARTS A NEW FRAME -- `p->stage_len =
 * 0` -- and every write after that APPENDS.  Getting that wrong does not
 * produce an error: it produces a window that paints last frame's display list
 * for ever, or one that accumulates every frame ever drawn until it overflows.
 * That is the defect that made an empty window look full for the life of a
 * test file, and it is why the boundary is carried in the message
 * (WSRV_F_NEWFRAME) instead of being inferred from anything.
 *
 * WHERE THE BYTES LAND: the window's HANDED-UP memfd (struct wpix), not the
 * shared segment -- the same place the in-process path puts them, which is
 * what makes routing a change of WHO WRITES and not of WHAT IS WRITTEN.  The
 * compositor maps every handed-up memfd read-WRITE already (see pix_install),
 * so nothing new is granted here.
 *
 * pix_get(wid, 0) AND NOT pix_get(wid, owns_wid(wid)), and the difference
 * would be a bug that hands the client a different window.  `mine` means
 * "create one if this process has none" -- in wsysd, for a window whose pixels
 * have not been handed up yet, that would MAKE A SECOND memfd inside the
 * compositor and announce it, so the client would keep drawing into its own
 * and the compositor would paint the empty one it invented.  A window with no
 * handed-up pixels is EAGAIN, said by name, and the client retries next frame
 * exactly as the compositor's own read path already does.
 */
static int64_t srv_scene_write(const struct wsrv_hdr *h, const uint8_t *pay)
{
    struct wwin *v = win_find(h->wid);
    if (!v) return -ENOENT;
    /* THE SAME TWO PREDICATES THE IN-PROCESS PATH ASKS, answered about the
     * caller: since stage 5 owns_wid() is the connection that holds the row,
     * so a scene write must arrive on that connection just as a ctl write
     * must.  This is the whole reason the leaf is routed at all. */
    if (!hostowner() && !owns_wid(h->wid)) return -EPERM;
    struct wpix *p = pix_get(h->wid, 0);
    if (!p) return -EAGAIN;
    if (p->stage_len > WSYS_SCENE_CAP) p->stage_len = WSYS_SCENE_CAP;
    if (h->flags & WSRV_F_NEWFRAME) {
        p->stage_len = 0;
        srv_n_frame++;
    }
    if (!h->len) return 0;                     /* the open, and nothing more */
    uint64_t room = WSYS_SCENE_CAP - p->stage_len;
    uint64_t k = h->len < room ? h->len : room;
    if (k == 0) return -ENOSPC;
    memcpy(p->stage + p->stage_len, pay, (size_t)k);
    p->stage_len += (uint32_t)k;
    srv_n_scene++;
    return (int64_t)k;
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

/* SAY WHICH LEAF, AND SAY IT ONCE PER NAME.
 *
 * An unknown per-window file is now ENOENT (see classify).  That is the right
 * answer, but an errno alone is how the last one hid for months: the caller
 * that meets it is a library like lib/hamui.ad, which checks for failure,
 * takes its documented fallback and says nothing.  So the DEVICE says it, by
 * name, on stderr -- the next leaf somebody forgets to wire up is then found
 * by reading the console instead of by measuring a desktop that is subtly
 * wrong.  Once per distinct name per process, so a client retrying in a loop
 * cannot turn the explanation into a scroll. */
static void unknown_win_leaf(int wid, const char *leaf)
{
    static char seen[8][32];
    static int  nseen;
    if (!leaf || !*leaf) return;
    for (int i = 0; i < nseen; i++)
        if (!strcmp(seen[i], leaf)) return;
    if (nseen < (int)(sizeof seen / sizeof seen[0])) {
        snprintf(seen[nseen], sizeof seen[0], "%s", leaf);
        nseen++;
    }
    fprintf(stderr,
            "wsys: /dev/wsys/%d/%s: no such per-window file.\n"
            "wsys:   A window's files are a fixed set (ctl, wctl, scene, keys, "
            "pointer, event,\n"
            "wsys:   text, cmd, draw/ctl, draw/images, draw/image/<name>, "
            "backbuffer).\n"
            "wsys:   This used to be accepted as a named buffer and silently "
            "reach nothing.\n",
            wid, leaf);
}

/* The /dev/wsys operation counter; see its definition below. Counting only,
 * and inert unless HAMWSYS_OPCOUNT is set. kind: 0=open 1=read 2=write. */
static void opc_note(int leaf, int kind);

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
            else if (!strcmp(l, "wctl"))    leaf = HAMWSYS_WIN_WCTL;
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
            /* A WINDOW'S FILES ARE A CLOSED SET, AND AN UNKNOWN ONE IS AN
             * ERROR -- NOT A BUFFER.  This `else` used to read
             *
             *     else  leaf = HAMWSYS_SINK;   // wctl, …
             *
             * and the comment named the very leaf it was swallowing.  A write
             * to /dev/wsys/<wid>/wctl -- which is how EVERY hamui application
             * negotiates the v2 blit protocol -- opened a generic named
             * buffer, took the bytes, returned success, and reached nothing.
             * The client set h_v2_active = 1 and believed it was a v2 client
             * for the rest of its life; the window stayed protocol 1 and no
             * backbuffer was ever allocated.  A surface that lies is worse
             * than one that errors, and devwsys.ad learned that lesson in this
             * very file (its wctl once parked resize/move in a private store
             * "the compositor never read and never wrote").
             *
             * THE ORIGINAL AGREES: Hamnix's namec.ad matches the per-window
             * leaves by name and returns DEV_NONE -- ENOENT -- for anything
             * else.  A window's namespace is a closed set there, so it is one
             * here.  MEASURED before changing it: across every .ad file under
             * user and lib, the only window-relative leaves any client opens are
             * ctl, wctl, scene, keys, pointer, event, text, cmd, draw/ctl,
             * draw/images, draw/image/<name> and backbuffer -- every one of
             * which is named above.  Nothing in this tree used the fallback
             * for anything but the bug.
             *
             * The TOP-LEVEL fallback below is deliberately kept: /dev/wsys/
             * <name> IS an open namespace (wallpaper, lock, run/launch,
             * appmenu/launch, and whatever a client invents), and a sink is
             * what those are.  The difference is that one is open by design
             * and this one is a fixed per-window file set. */
            else {
                unknown_win_leaf(wid, l);
                return HAMWSYS_NONE;
            }
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
    /* THE DEVICE STATES ITS OWN CEILING, because until it did, everybody who
     * needed the number had their own copy of it and one of them was wrong.
     *
     * BB_W x BB_H is the largest surface anything in this system can put on a
     * screen: bb_fit cuts a window to it, bb_blit clips every pixel outside
     * it, and the draw/ctl arm REFUSES a blit rect wider or taller than it.
     * user/wsyswl.ad used to cap a blit row at a hardcoded 8192 bytes -- 2048
     * columns, a number derived from nothing -- so a window between 1921 and
     * 2048 columns wide sent rects this device refuses, and since that write's
     * return value was ignored the window painted NOTHING, for ever, silently.
     * A server cannot draw inside a limit it has to guess, so the limit is
     * published here and read rather than assumed. */
    k = " maxsurface ";
    while (*k) b[n++] = (uint8_t)*k++;
    n = put_int(b, n, BB_W);
    b[n++] = 'x';
    n = put_int(b, n, BB_H);
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
    /* THE BACKBUFFER GEN IS THE MEMFD'S NOW, not a shared slot's.  Report it
     * from whatever this process holds for the window -- its own memfd if it is
     * the owner, the handed-up one if it is the compositor.  The compositor
     * drains on the BACKBUFFER read path and on its tick, so by the time it
     * composites this window the gen is current; a first-frame lag converges on
     * the frame clock exactly as a late scene hand-up does.  It does NOT listen
     * here: a client reading its OWN ctl must never try to become the
     * compositor (which on a single-uid host it otherwise could). */
    /* STAGE 9 ROUTES THIS READ, AND FIELD 11 IS THE ONE FIELD THAT IS NOT THE
     * SAME ANSWER FROM THE SERVER.  bbmap is PER PROCESS, so the read server
     * -- which never holds a window's memfd -- reports 0 here where the owner
     * or the compositor would report its own gen.  Written down rather than
     * hidden, and it costs nothing measurable today for a reason that is a
     * sweep and not a hope: the only reader of this field in the tree is
     * user/wsysd.ad's load_window(), and wsysd is srv_is_server so its read is
     * never routed.  No shipped client reads its own <wid>/ctl at all -- every
     * other site in user/*.ad and lib/*.ad opens this leaf write-only.  If one
     * ever does, this is the field that will be stale and the fix is for the
     * client to keep the in-process answer for its OWN window rather than for
     * the server to invent a memfd it does not hold (see the pix_get(wid, 0)
     * trap stage 6 recorded). */
    int bslot = bb_find(v->wid);
    int32_t bgen = (bslot >= 0 && bbmap[bslot].hdr) ? (int32_t)bbmap[bslot].hdr->gen : 0;
    int32_t igen = 0;
    if (img || img_attach() >= 0)
        for (int i = 0; i < WSYS_IMG_SLOTS; i++)
            if (img->slot[i].used && img->slot[i].wid == v->wid)
                igen += (int32_t)img->slot[i].serial;
    int32_t fields[14] = { v->wid, v->x, v->y, v->w, v->h, v->z,
                           v->decorate, v->visible, v->proto,
                           (int32_t)v->scene_gen,
                           bgen,
                           igen, v->keyed, v->blend };
    for (int i = 0; i < 14; i++) {
        if (i) b[n++] = ' ';
        n = put_int(b, n, fields[i]);
    }
    b[n++] = '\n';
    return snap_set(f, b, n);
}

/* /dev/wsys/<wid>/wctl's READ answer: the window AS IT IS COMPOSITED RIGHT
 * NOW, "<x> <y> <w> <h> <focus>\n".  A function rather than four lines inline
 * in hamwsys_open because stage 9 routes this read, so the read server has to
 * produce the identical bytes -- and this device has already paid, twice, for
 * gating or formatting one spelling of a thing and not the other. */
static int snap_win_wctl(struct hamwsys_file *f, const struct wwin *v)
{
    uint8_t b[96];
    uint64_t n = put_int(b, 0, v->x);
    b[n++] = ' '; n = put_int(b, n, v->y);
    b[n++] = ' '; n = put_int(b, n, v->w);
    b[n++] = ' '; n = put_int(b, n, v->h);
    b[n++] = ' ';
    const char *fm = win_focus_sloppy(v) ? "sloppy" : "click";
    while (*fm) b[n++] = (uint8_t)*fm++;
    b[n++] = '\n';
    return snap_set(f, b, n);
}

/* `list_wids` IS STAGE 9'S ENUMERATION TIER, REACHING THE DIRECTORY.  The
 * routed `windows` read has answered a window-less caller EMPTY since stage 4
 * -- and `cat /dev/wsys` handed the same caller every used row's wid one path
 * component up, out of shared memory, on the same run (docs 7.1).  A caller in
 * the EMPTY tier gets the FIXED NAMES ONLY: it can still open `windows` (and
 * be told nothing), still read `screen` and `pool` (which name no client), and
 * learns not one wid.  Every in-process caller passes 1, exactly as before. */
static int snap_dir_tier(struct hamwsys_file *f, int list_wids)
{
    /* The runtime's directory reads are a packed "NAME\n" stream — the same
     * shape sys_open on a real directory produces (see linux-syscalls.c's
     * dirtab).  Neither "." nor ".." appears, for the reason recorded there:
     * the tree's recursive walkers have no self/parent guard. */
    uint8_t buf[WSYS_MAX_WINDOWS * 8 + 256];
    uint64_t n = 0;
    if (f->wid == 0) {
        /* NOT IN THE READ SERVER -- see srd_is_child, which carries the whole
         * argument.  win_reap_dead() WRITES the window table, and this function
         * is now reachable from an arbitrary client's routed read. */
        if (!srd_is_child)
            win_reap_dead();       /* the compositor must not paint a dead one */
        const char *fixed[] = { "ctl", "self", "windows", "screen", "pool" };
        for (unsigned i = 0; i < sizeof fixed / sizeof fixed[0]; i++) {
            for (const char *c = fixed[i]; *c; c++) buf[n++] = (uint8_t)*c;
            buf[n++] = '\n';
        }
        for (int i = 0; list_wids && i < WSYS_MAX_WINDOWS; i++) {
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

static int snap_dir(struct hamwsys_file *f) { return snap_dir_tier(f, 1); }

/* THE OPEN'S EXISTENCE CHECK — stage 10, and it replaces `win_find(f->wid)` at
 * every arm of hamwsys_open that was asking the mapped table whether a window
 * is there.  See srv_route_exists() for what is routed, what is cached and what
 * this does NOT buy while the mapping is still there.
 *
 * Returns the row, or NULL with errno set.  The row is still needed: this pass
 * routes the QUESTION, not the data, and pix_get, bb_find, snap_win_ctl and the
 * rings all read the mapping afterwards exactly as they did.
 *
 * STAGE 10b — ROUTED FOR A WRITE TOO, AND STAGE 10'S REASON FOR NOT DOING SO
 * WAS WRONG.  What stood here said: "A write open is already refused to a
 * non-owner by `hostowner() || owns_wid()`, and owns_wid() is since stage 5 the
 * CONNECTION question while this routes the ANCESTRY one -- so routing
 * existence on the write path could refuse a process that was legitimately
 * HANDED a descriptor for a window it does not descend from."
 *
 * THE TWO SETS ARE THE SAME SET AT THIS SITE, and it is not an argument, it is
 * a definition three hundred lines up:
 *
 *     static int owns_wid(int wid)
 *     {
 *         if (srv_caller.active) return srv_caller_holds_wid(wid);
 *         return owns_wid_ancestry(wid);
 *     }
 *
 * `srv_caller.active` is set by srv_as_caller()/srv_as_caller_full() and by
 * nothing else, and both are called only from a server dispatching a request.
 * hamwsys_open() is never on that path: the mutation server services a routed
 * write with hamwsys_write_inner(), which opens nothing.  So in the client --
 * which is the only place a write open happens -- `owns_wid()` evaluates
 * `owns_wid_ancestry()`, the identical function this routes.  The connection
 * question is asked at WSRV_OP_WRITE, in the server, and stays there.
 *
 * SO THE STAGE-5 CASE CANNOT BE BROKEN BY THIS, because it was never admitted
 * here: a process handed a descriptor for a window it does not descend from
 * has ancestry 0, so the local gate ALREADY refuses its write open with EPERM,
 * routed or not.  Its capability is a routed MUTATION, which does not open.
 * What changes is the errno on a refusal, which is the whole oracle.
 *
 * AND THE TWO-STEP ORACLE IS CLOSED BY open_deny() BELOW: if the server ever
 * granted this wid and the local rule then refused, "EPERM" would say the
 * window is there just as surely as the old code did.  That case is
 * unreachable by the paragraph above; it is answered ENOENT anyway, because a
 * boundary that depends on two predicates staying equal should not also
 * announce it when they do not. */
static struct wwin *open_win(struct hamwsys_file *f)
{
    int r = srv_route_exists(f->wid, f->write);
    if (r < 0) return NULL;                    /* the server's refusal, errno set */
    struct wwin *v = win_find(f->wid);
    if (!v) errno = ENOENT;
    return v;
}

/* The write open's refusal, AFTER open_win() has already been through the
 * server.  See the paragraph above: a served YES followed by a local EPERM is
 * the enumeration channel with one extra hop in it, so when the server granted
 * this wid to this process the refusal is the same ENOENT an absent window
 * gets.  Unrouted -- no server, which is every shipped binary today and every
 * red arm of every gate -- nothing was granted, srv_exists_cached() is 0, and
 * this is deny() exactly as before. */
static int open_deny(int32_t wid)
{
    if (srv_enabled() && !srv_is_server && srv_exists_cached(wid)) {
        errno = ENOENT;
        return -1;
    }
    return deny();
}

/* ------------------------------------------------------------------ *
 * open / read / write / close
 * ------------------------------------------------------------------ */
int hamwsys_open(const char *path, int for_write, struct hamwsys_file *f)
{
    memset(f, 0, sizeof *f);
    if (classify(path, f) == HAMWSYS_NONE) { errno = ENODEV; return -1; }
    opc_note(f->leaf, 0);
    if (shm_attach() < 0) return -1;
    /* THE CLIENT'S DIAL, and nothing more than the dial.  Stage 1 routes no
     * operation over the server (see THE MEDIATOR'S TRANSPORT in
     * linux-wsys.h), so this establishes the connection and the version
     * handshake and then gets out of the way.  It is here rather than in
     * shm_attach because attaching is what wsysd does to SERVE, and opening
     * is what a client does to USE -- and only the second should dial.  Inert
     * unless HAMWSYS_SERVER=1; the first call in a process is the only one
     * that does any work. */
    srv_client_tick();
    f->write = for_write;
    f->off = 0;
    pix_tick();                                /* see hamwsys_read */
    bbup_tick();                               /* and the backbuffer's hand-up */

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
        /* wctl takes the SAME rule, and devwsys.ad says why in as many words:
         * "this is a PER-WINDOW surface, so the WINDOW'S OWNER may write it
         * regardless of hostowner/uid/namespace -- that is what lets a
         * DE-spawned client (panels/menu/terminal/apps, all running as uid
         * NOBODY) write `version 2` and opt into the blit path".  Non-owner
         * and non-hostowner is denied: a process may control its OWN window,
         * not another's.  The system-wide /dev/wsys/ctl stays hostowner-only. */
        case HAMWSYS_WIN_WCTL:
            /* STAGE 10b: SERVED, and stage 10's note that it could not be is
             * corrected in full at open_win().  The short of it: `owns_wid()`
             * on this line is `owns_wid_ancestry()`, because srv_caller.active
             * is only ever set inside a server dispatching a request and
             * hamwsys_open() never runs there.  The local gate and the served
             * predicate are the same set about the same process, so this
             * routes without moving the boundary a single caller -- it moves
             * only the errno, which is what was leaking.
             *
             * MEASURED BEFORE, uid 1002 owning nothing, opening for WRITE:
             *     /dev/wsys/<live>/ctl  -> EPERM   ("Operation not permitted")
             *     /dev/wsys/<dead>/ctl  -> ENOENT
             * -- the same enumeration channel stage 10 closed on the read
             * half, one flag of open(2) away. */
            if (!open_win(f)) return -1;
            if (!hostowner() && !owns_wid(f->wid)) return open_deny(f->wid);
            break;
        case HAMWSYS_SINK:
            if (!sink_write_allowed(f->name)) return deny();
            break;
        default:
            break;                             /* ctl is gated per verb */
        }
    }

    /* THE ONE FILE UNDER /dev/wsys A READ CAN BE REFUSED ON, and it is a
     * deliberate departure from devwsys, where "reads are never refused".
     *
     * Refusing this read IS the confidentiality boundary.  A window's
     * keystrokes are delivered to whoever holds its channel, and only its owner
     * can hold that -- so a process reading somebody else's /keys can only ever
     * get nothing, and returning zero bytes for ever would say "the user is not
     * typing" to a caller that has no way to tell that apart from the truth.
     * It says which of the two it is instead.
     *
     * The lazy bind is here for the hamwsys_alloc path: hamUI stamps a wid
     * against a child's pid, and that child claims its own channel the first
     * time it opens its own keys. */
    if (f->leaf == HAMWSYS_WIN_KEYS && !for_write) {
        /* STAGE 10, AND THIS LEAF IS WHY THE ORACLE IS WORTH CLOSING.  keys is
         * the ONE read this device refuses by name, and the refusal below says
         * "this process does not own window N" -- which tells a stranger the
         * window is there.  The absence has to be answered first, or the
         * confidentiality boundary announces what it is protecting. */
        if (!open_win(f)) return -1;
        if (keychan_find(f->wid) < 0) {
            if (!owns_wid(f->wid) || keychan_bind(f->wid) < 0) {
                fprintf(stderr,
                        "wsys: /dev/wsys/%d/keys: this process does not own "
                        "window %d, so it cannot read its keystrokes.\n",
                        (int)f->wid, (int)f->wid);
                errno = EPERM;
                return -1;
            }
        }
        return 0;
    }

    switch (f->leaf) {
    case HAMWSYS_BACKBUF: {
        struct wwin *v = open_win(f);          /* stage 10: existence is served */
        if (!v) return -1;
        /* A READER MAY OPEN A v2 BACKBUFFER BEFORE ITS MEMFD ARRIVES.  The
         * pixels are in a per-window memfd now, handed up on a clock, so
         * "not received yet" must not read as "no such backbuffer" -- that
         * would refuse the compositor's very first open of every browser and
         * leave it blank for ever, the exact silent failure this device fights.
         * Drain any pending hand-up first, then accept if this is a v2 window
         * at all or we already hold its memfd; the read returns 0 until the
         * descriptor lands and the frame clock retries.  A non-owner opening a
         * victim's backbuffer still gets 0 bytes: only the process HANDED the
         * memfd can read pixels, and a stranger is handed nothing. */
        if (!for_write) {
            int slot = bb_find(v->wid);
            if (slot < 0 || !bbmap[slot].own) { bbup_listen(); bbup_drain(); }
            if (bb_find(v->wid) < 0 && v->proto != 2) { errno = ENOENT; return -1; }
        }
        return 0;
    }
    case HAMWSYS_IMAGES: {
        /* READ-ONLY, and deliberately.  The way to put an image in the store is
         * the 'I' verb on draw/ctl; a second writable spelling of the same
         * state is how two sources of truth start (the same argument
         * /dev/wsys/screen makes just below). */
        if (for_write) { errno = EACCES; return -1; }
        /* STAGE 10, AND THIS IS THE LEAF THE MEASUREMENT CAME OFF.  This arm
         * has NO owner check at all: it lists a window's image names and sizes
         * to anybody, and even with an empty store it separates a live window
         * (rc 0, no output) from an absent one (rc 1, ENOENT) in the EXIT CODE
         * of `cat`.  That is the whole window table, enumerable by a process
         * the routed `windows` read was answering EMPTY on the same run. */
        struct wwin *v = open_win(f);
        if (!v) return -1;
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
        if (!open_win(f)) return -1;           /* stage 10 */
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
        struct wwin *v = open_win(f);          /* stage 10 */
        if (!v) return -1;
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
    /* /dev/wsys/<wid>/wctl — READ: the window AS IT IS COMPOSITED RIGHT NOW.
     *
     *     "<x> <y> <w> <h> <focus>\n"      focus is "click" or "sloppy"
     *
     * devwsys.ad's shape exactly, and its warning is the reason this reads the
     * LIVE rect out of the row rather than anything the verbs parked: that file
     * once kept a private request store the compositor never read, so every
     * window reported "0 0 0 0 click" whatever its real geometry and readers
     * had to route around wctl to the per-window ctl.  "A SURFACE THAT LIES IS
     * WORSE THAN ONE THAT ERRORS."  Reads are unrestricted, as they are there,
     * so a compositor can poll the line whoever spawned the client. */
    case HAMWSYS_WIN_WCTL: {
        /* ROUTED BEFORE win_find, AND THE ORDER IS THE POINT.  win_find is a
         * walk of the mapped table, so answering ENOENT from it first would
         * tell a caller in the EMPTY tier whether the window exists -- which
         * is the one bit this leaf is being routed to withhold. */
        if (!for_write) { int r = srv_route_read(f); if (r) return r > 0 ? 0 : -1; }
        struct wwin *v = win_find(f->wid);
        if (!v) { errno = ENOENT; return -1; }
        if (for_write) return 0;               /* verbs handled in the write */
        return snap_win_wctl(f, v);
    }
    case HAMWSYS_WIN_CTL: case HAMWSYS_WIN_SCENE: case HAMWSYS_WIN_KEYS:
    case HAMWSYS_WIN_POINTER: case HAMWSYS_WIN_EVENT: case HAMWSYS_WIN_TEXT:
    case HAMWSYS_WIN_CMD: {
        /* STAGE 9, AND ONLY wid/ctl OF THESE SEVEN.  The four rings are
         * closed by ring_read_allowed() below and keys is closed by name
         * above; scene reads out of a per-window memfd the server does not
         * hold.  wid/ctl was the one with no check at all, and it is routed
         * BEFORE win_find for the reason spelled out at wctl: the ENOENT is
         * itself the fact being withheld. */
        if (f->leaf == HAMWSYS_WIN_CTL && !for_write) {
            int r = srv_route_read(f); if (r) return r > 0 ? 0 : -1;
        }
        /* STAGE 10 REACHES THE OTHER SIX.  wid/ctl returned above with a served
         * answer; scene and the four rings arrive here, and BOTH of their
         * refusals below name the window they are refusing -- the ring check
         * and the scene's EPERM.  Existence is asked first so the refusal
         * cannot be told from an absence. */
        struct wwin *v = open_win(f);
        if (!v) return -1;
        /* THE OWNER CHECK THE FOUR RINGS NEVER HAD -- see THE FOUR RINGS THAT
         * HAD NO OWNER CHECK AT ALL.  At the open, beside the keys refusal
         * above and mirroring the for_write arm at the top of this function,
         * so that a refused reader never gets a descriptor at all. */
        if (!for_write && !ring_read_allowed(f->wid, f->leaf)) return -1;
        /* Opening the scene for writing starts a fresh frame — the client
         * writes the whole display list, then publishes it with `commit`.
         * IN THE MEMFD, NOT IN THE SEGMENT: see THE PIXEL HAND-UP.  The
         * lengths moved with the bytes, because a length in the world-writable
         * table is a number an attacker picks for a buffer it cannot see. */
        if (f->leaf == HAMWSYS_WIN_SCENE) {
            struct wpix *p = pix_get(f->wid, owns_wid(f->wid));
            /* A WINDOW THAT HAS NEVER COMMITTED READS EMPTY, AND THAT IS THE
             * TRUTH RATHER THAN A SOFTENED REFUSAL.  scene_gen is 0 until the
             * first commit; a v2 window never commits at all, because it
             * renders its own surface and submits blits.  So without this a
             * BROWSER, A VIDEO AND EVERY ROOTLESS X CLIENT WOULD STOP BEING
             * PAINTED -- user/wsysd.ad's paint_window slurps <wid>/scene for
             * every window before it looks at the protocol, and `if (n < 0)
             * return 0` bails before it ever reaches paint_backbuffer.  A v2
             * window's scene read has always been a 0-byte success and it
             * still is.  A refusal is reserved for the case that really is
             * one: a window that HAS published a frame this process cannot
             * fetch. */
            if (!p && !for_write && v->scene_gen == 0)
                return snap_set(f, NULL, 0);
            if (!p) {
                /* A REFUSAL, SAID BY NAME.  Serving an empty scene here would
                 * be a window that paints nothing and a read that succeeds --
                 * the shape NORTH_STAR.md forbids.  The compositor reaches
                 * this only for a window that has not handed its descriptor up
                 * yet, and retries next frame. */
                fprintf(stderr,
                        "wsys: /dev/wsys/%d/scene: this process neither owns "
                        "window %d nor holds its display list, so it cannot "
                        "%s it.\n", (int)f->wid, (int)f->wid,
                        for_write ? "draw into" : "read");
                errno = EPERM;
                return -1;
            }
            if (for_write) {
                /* ROUTED, THE OPEN IS A MESSAGE AND NOT A STORE.  The reset is
                 * the frame boundary; performing it here as well as sending it
                 * would be two frame starts for one open, and a client that
                 * opened and never wrote would clear a display list the server
                 * never heard about -- the two halves of the state disagreeing,
                 * which for this leaf means a window painting the wrong frame.
                 * srv_route_write() carries WSRV_F_NEWFRAME on the first write;
                 * a zero-length message is sent HERE so an open with no write
                 * still starts the frame, exactly as the in-process path does. */
                if (srv_fd >= 0 && srv_enabled() && !srv_is_server) {
                    f->srv_newframe = 1;
                    (void)srv_route_write(f, NULL, 0, NULL);
                } else {
                    p->stage_len = 0;
                }
            }
            else           return snap_set(f, p->scene,
                                           p->scene_len > WSYS_SCENE_CAP
                                           ? WSYS_SCENE_CAP : p->scene_len);
        }
        if (f->leaf == HAMWSYS_WIN_CTL && !for_write)
            return snap_win_ctl(f, v);
        return 0;
    }
    case HAMWSYS_SCREEN:
        /* Read-only.  The way to SET the screen size is `screen W H` on the
         * global ctl, which is the compositor's to write; a second writable
         * spelling of the same state is how two sources of truth start. */
        if (for_write) { errno = EACCES; return -1; }
        { int r = srv_route_read(f); if (r) return r > 0 ? 0 : -1; }
        return snap_screen(f);
    case HAMWSYS_POOL:
        /* Read-only for the same reason `screen` is: this is the device
         * reporting its own storage, and a writable spelling of it would be a
         * second source of truth for how many windows can be painted. */
        if (for_write) { errno = EACCES; return -1; }
        { int r = srv_route_read(f); if (r) return r > 0 ? 0 : -1; }
        return snap_pool(f);
    case HAMWSYS_WINDOWS:
        /* STAGE 4'S POINT OF THE WHOLE EXERCISE.  Served, "which windows
         * exist" is a question somebody ANSWERS, so it can be answered
         * differently for different callers -- see THE ENUMERATION POLICY at
         * srd_enum_tier.  Unrouted (HAMWSYS_SERVER unset, or no read server)
         * it is snap_windows() out of shared memory, exactly as before, and
         * tests/linux/wsys_enum_policy.sh asserts that this arm still hands a
         * window-less `cat` the full list -- because a gate whose red arm has
         * quietly gone green proves nothing about the green one. */
        if (!for_write) { int r = srv_route_read(f); if (r) return r > 0 ? 0 : -1; }
        return for_write ? 0 : snap_windows(f);
    case HAMWSYS_SELF:    return for_write ? 0 : snap_self(f);
    case HAMWSYS_CTL:     return for_write ? 0 : snap_ctl(f);
    case HAMWSYS_DIR:
        /* STAGE 9 -- AND THIS IS THE LEAF THAT BYPASSED STAGE 4's POLICY.
         * `cat /dev/wsys` lists every used row's wid, one path component above
         * the `windows` file whose routed read was already answering the same
         * caller EMPTY.  Routed, the EMPTY tier gets the fixed names and no
         * wids; /dev/wsys/<wid> gets ENOENT. */
        if (!for_write) { int r = srv_route_read(f); if (r) return r > 0 ? 0 : -1; }
        return snap_dir(f);
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
            /* THE TRUNCATE THAT USED TO BE HERE IS THE TORN READ.
             * `s->len = 0;` published an EMPTY sink to every reader for the
             * whole gap between this open(2) and the write(2) that follows
             * it -- microseconds, but wsysd republishes its state file every
             * frame, and a reader hammering it caught the gap 25 times in
             * 100000 (tests/linux/de_state_atomic.sh).  Truncation is now
             * STAGED: the descriptor starts a fresh body, and the shared sink
             * keeps its previous contents until a whole new one replaces it.
             *
             * `staged` is what preserves `> /dev/wsys/foo` with no write at
             * all still emptying the sink -- see hamwsys_close, where that
             * lands as a single store rather than as a window. */
            f->stagelen = 0;
            f->staged = 1;
            return 0;
        }
        if (!s) return snap_set(f, NULL, 0);   /* never written: empty, not ENOENT */
        /* THE READER'S HALF OF THE ATOMIC PUBLISH.  sink_publish stores the
         * body, then the length, then bumps `serial` with a release.  Sample
         * serial on either side of the copy: if it moved, a writer published
         * underneath us and the bytes in hand may be half of each version, so
         * take them again.  Identical in shape to the shm->gen sampling that
         * brackets hamwsys_write.
         *
         * BOUNDED, and the bound is not a formality: a writer that republishes
         * faster than this loop can copy must not hang a reader forever.  On
         * giving up we fall through with the last copy taken, which is what
         * this code did unconditionally before -- so the worst case is exactly
         * today's behaviour, never worse. */
        uint8_t t[WSYS_SINK_CAP + 16];
        uint64_t n = 0;
        int lq = sink_is_launch_queue(f->name);
        for (int try = 0; try < 64; try++) {
            uint32_t s0 = __atomic_load_n(&s->serial, __ATOMIC_ACQUIRE);
            n = 0;
            if (lq) {
                n = put_int(t, 0, (int32_t)s0);
                t[n++] = ' ';
            }
            uint32_t k = __atomic_load_n(&s->len, __ATOMIC_ACQUIRE);
            if (k > WSYS_SINK_CAP) k = WSYS_SINK_CAP;
            memcpy(t + n, s->b, k);
            n += k;
            if (__atomic_load_n(&s->serial, __ATOMIC_ACQUIRE) == s0) break;
        }
        return snap_set(f, t, n);
    }
    default: errno = ENODEV; return -1;
    }
}

int64_t hamwsys_read(struct hamwsys_file *f, uint8_t *buf, uint64_t cap)
{
    opc_note(f ? f->leaf : 0, 1);
    if (!shm) { errno = EIO; return -EIO; }

    /* THE HAND-UP'S HEARTBEAT.  A client that is doing nothing at all still
     * drains its event ring on every park, so this is the call that reaches a
     * window which has stopped drawing -- see pix_tick.  It is gated on a
     * monotonic clock read and returns immediately the rest of the time. */
    pix_tick();
    bbup_tick();

    /* The event rings are live, not snapshots: a read DRAINS whatever has
     * arrived and returns 0 when there is nothing.  hamui polls them
     * non-blocking, so 0 must mean "nothing yet", never EOF-forever. */
    struct wwin *v = NULL;
    struct wring *q = NULL;
    switch (f->leaf) {
    case HAMWSYS_WIN_KEYS:
        /* NOT the segment: see THE KEYSTROKE CHANNEL.  hamwsys_open has already
         * refused this descriptor to anyone who does not hold the channel. */
        return (int64_t)keychan_recv(f->wid, buf, cap);
    case HAMWSYS_WIN_POINTER: v = win_find(f->wid); if (v) q = &v->pointer; break;
    case HAMWSYS_WIN_EVENT:   v = win_find(f->wid); if (v) q = &v->event;   break;
    case HAMWSYS_WIN_TEXT:    v = win_find(f->wid); if (v) q = &v->text;    break;
    case HAMWSYS_WIN_CMD:     v = win_find(f->wid); if (v) q = &v->cmd;     break;
    default: break;
    }
    /* AND AGAIN AT THE READ, for the reason hamwsys_write states for the write
     * side: a descriptor can outlive the privilege that opened it -- an fd
     * inherited across /etc/rc.de-user's setuid is the case in the tree.  The
     * open-time check is what refuses the stranger; this one is what stops a
     * descriptor opened before a privilege drop from draining the ring after
     * it.  ring_read() DESTROYS what it returns (it moves r past the bytes), so
     * a late check that merely discarded the buffer would still have eaten the
     * owner's events -- the refusal has to come before the drain. */
    if (q && !ring_read_allowed(f->wid, f->leaf)) return -1;
    if (q)
        return (int64_t)ring_read(q, buf, cap);

    if (f->leaf == HAMWSYS_BACKBUF) {
        /* The v2 pixels, out of the window's PER-WINDOW MEMFD -- not a shared
         * surface any more (THE BACKBUFFER MEMFD).  The reader here is the
         * compositor, which was handed the descriptor over the backbuffer
         * hand-up: it listens and drains first, exactly as pix_get does for a
         * foreign scene, so a descriptor that has arrived is installed before
         * this read looks for it.  A window whose memfd has not been handed up
         * reads as empty, which the frame clock retries -- never somebody
         * else's pixels, because there is no shared slab to stray into.
         *
         * ONLY A FOREIGN WINDOW MAKES US LISTEN.  Reading our OWN backbuffer
         * (an owner glancing at its own pixels) must not try to bind the
         * compositor's address -- on a single-uid host every process is the
         * "owner" of the segment, so an unguarded listen would let a client
         * seize the hand-up address ahead of the real compositor. */
        int slot = bb_find(f->wid);
        if (slot < 0 || !bbmap[slot].own) {
            bbup_listen();
            bbup_drain();
            slot = bb_find(f->wid);
        }
        if (slot < 0) return 0;
        struct bbpix *h = bbmap[slot].hdr;
        if (!h) return 0;
        uint64_t size = (uint64_t)h->w * h->h * 4;
        if (f->off >= size) return 0;
        uint64_t k = size - f->off;
        if (k > cap) k = cap;
        const uint8_t *fp = bbpix_page(slot, h->front);
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
        /* ROUTED, WHEN THERE IS A SERVER.  The row comes back from the one
         * allocator; the keystroke channel is bound below, in THIS process,
         * because whoever binds it is whoever reads it.  See THE RACE THAT
         * ROUTING RETIRES at win_alloc for why one allocator is worth more
         * than the compare-exchange it makes redundant. */
        struct wwin *v;
        int32_t rwid = srv_newwindow();
        if (rwid == -2) {
            v = win_alloc((int32_t)getpid());
        } else if (rwid < 0) {
            last_new = -1;
            return -1;
        } else {
            v = win_find(rwid);
            if (!v) { last_new = -1; errno = EIO; return -1; }
        }
        /* CLAIM THE KEYSTROKES BEFORE THE WINDOW EXISTS TO ANYONE ELSE.
         * `newwindow` stamps the CALLER as the owner, so the process running
         * this line is the one that will read this window's keys -- bind here
         * rather than at its first open of /keys, so a keystroke routed in the
         * gap is delivered instead of dropped.  (hamwsys_alloc, which stamps
         * SOMEBODY ELSE's pid, deliberately does not bind: the owner does it
         * lazily on its own first read, because binding on its behalf here
         * would take the name the owner needs.)
         *
         * A FAILURE HERE FAILS THE WINDOW.  If the name is already held, this
         * window can never receive a keystroke, and a program that comes up
         * looking normal and is deaf to the keyboard is the success-shaped
         * failure this tree exists to refuse.  keychan_bind has already said
         * so by name on stderr. */
        if (v && keychan_bind(v->wid) < 0) {
            int e = errno;
            v->used = 0;
            shm->gen++;
            last_new = -1;
            errno = e;
            return -1;
        }
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
        keychan_unbind(wid);
        pix_release(wid);
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
            keychan_unbind(wid);
            pix_release(wid);
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
    /* Through sink_publish like every other publisher, for two reasons.  It
     * shrinks-then-copies-then-stores so the reader's retry loop can see that
     * this happened; and it bumps `serial`, which this path did NOT do while
     * claiming the field means "++ per write".  That omission was already
     * visible where it matters: two identical `launch` verbs written to
     * /dev/wsys/ctl changed the body to the same bytes and left the serial
     * alone, so the launch-queue reader -- whose whole job is to notice a NEW
     * request -- had nothing to notice.  The direct-sink spelling of the same
     * act always did bump it. */
    sink_publish(sk, (const uint8_t *)s, cp);
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
        /* PUBLISH, INSIDE THE MEMFD.  This is the only place scene_len moves,
         * and it moves after the bytes are already in place, so a compositor
         * that sees the new scene_gen is guaranteed a whole frame.
         *
         * scene_gen STAYS IN THE TABLE.  It is the change notification every
         * reader of /dev/wsys/wctl polls; it says a frame happened and nothing
         * about what is in it.  A commit with no pixel memory bumps NOTHING --
         * announcing a frame that cannot be fetched is the success-shaped half
         * of this operation, and it is refused rather than half-done.
         *
         * THE WRITE CENSUS STILL COUNTS IT.  wr(WR_COMMIT) is unchanged: a
         * commit is still a mutation of the segment (scene_gen and gen both
         * move), and tests/linux/wsys_write_census.sh's per-frame:lifecycle
         * ratio is measuring the same event it always was. */
        struct wpix *p = pix_get(v->wid, owns_wid(v->wid));
        if (!p) {
            fprintf(stderr, "wsys: window %d: commit with no display list of "
                    "its own -- nothing published.\n", (int)v->wid);
            return;
        }
        wr(WR_COMMIT, p->stage_len);
        if (p->stage_len > WSYS_SCENE_CAP) p->stage_len = WSYS_SCENE_CAP;
        memcpy(p->scene, p->stage, p->stage_len);
        p->scene_len = p->stage_len;
        p->gen++;
        v->scene_gen++;
        shm->gen++;
        pix_tick();
        return;
    }
    /* "hide [0|1]" / "show [0|1]" -- AND THE ARGUMENT IS NOT OPTIONAL TO READ.
     *
     * MEASURED, on the published desktop, and it is why `hpm update` left a
     * machine with no panel and no taskbar.  `hide` used to ignore everything
     * after the verb and set visible = 0 unconditionally.  But
     * user/hampanelscene.ad's _set_window_hidden -- the ONLY writer of this
     * verb in the tree -- spells BOTH directions through it, "hide 1" to
     * withdraw a pooled window and "hide 0" to put it back on screen, and its
     * config-reload path (_reload_panels) writes "hide 0" to EVERY panel
     * window it is about to redraw.  So every reload of /etc/panel.conf --
     * which is what an `hpm update` that ships a new panel config performs,
     * underneath a running panel -- read as "hide" and withdrew the top panel
     * and the taskbar.  The panel process stayed alive, kept looping, kept
     * logging "config reload applied: 2 panel(s)", and owned two invisible
     * windows: alive to anything counting processes, and a desktop with no
     * panel to the person in front of it.  Offscreen repro:
     * tests/linux/de_panel_reload_windows.sh.
     *
     * A bare "hide" (no argument) still means hide, and a bare "show" still
     * means show, so a client that has never passed an argument is unaffected:
     * take_int answers -1 when there is no number, which is the "no argument"
     * case, not 0. */
    if (n >= 4 && !strncmp(s, "hide", 4)) {
        wr(WR_ATTR, n);
        p = 4; int32_t hv = take_int(s, &p, n);
        v->visible = (hv == 0) ? 1 : 0;
        shm->gen++; return;
    }
    if (n >= 4 && !strncmp(s, "show", 4)) {
        wr(WR_ATTR, n);
        p = 4; int32_t sv = take_int(s, &p, n);
        v->visible = (sv == 0) ? 0 : 1;
        shm->gen++; return;
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

/* ---- THE OPERATION COUNTER ---------------------------------------------
 *
 * COUNTING ONLY. It exists to answer one question with a number instead of an
 * argument: if /dev/wsys became a userland FILE SERVER -- clients talking to
 * wsysd rather than sharing memory with it -- how many round trips a second
 * would that be? Cost per op is worthless without the denominator, and the
 * denominator may settle the question on its own in either direction.
 *
 * Every op here is one that WOULD become a round trip: in a file server an
 * open, a read and a write are each a message. The in-process path makes them
 * function calls, which is where the 0.3 ms input-to-pixel comes from and also
 * why there is no privilege boundary inside the object.
 *
 * A PER-SECOND TIME SERIES, NOT A TOTAL, because bursts are what would hurt
 * and a mean hides them: 250 ops/s spread evenly and 250 ops arriving in one
 * 4 ms clump are the same mean and completely different designs. Printed as it
 * goes rather than accumulated and dumped at exit, so a client that is
 * SIGKILLed -- which most of these harnesses do -- still leaves its record.
 *
 * Inert unless HAMWSYS_OPCOUNT is set: one branch on a cached int. */
static int      opc_on = -1;            /* -1 = not yet looked up */
static uint64_t opc_leaf[64][3];        /* [leaf][0=open 1=read 2=write] */
static uint64_t opc_sec_ops;            /* ops in the current second      */
static uint64_t opc_sec_t0;             /* start of the current second, us */
static uint64_t opc_max_10ms, opc_cur_10ms, opc_10ms_t0;

static const char *opc_leafname(int l)
{
    switch (l) {
    case HAMWSYS_CTL: return "ctl";            case HAMWSYS_SELF: return "self";
    case HAMWSYS_WINDOWS: return "windows";    case HAMWSYS_SCREEN: return "screen";
    case HAMWSYS_POOL: return "pool";          case HAMWSYS_DIR: return "dir";
    case HAMWSYS_WIN_CTL: return "wid/ctl";    case HAMWSYS_WIN_WCTL: return "wid/wctl";
    case HAMWSYS_WIN_SCENE: return "wid/scene";case HAMWSYS_WIN_KEYS: return "wid/keys";
    case HAMWSYS_WIN_POINTER: return "wid/pointer";
    case HAMWSYS_WIN_EVENT: return "wid/event";case HAMWSYS_WIN_TEXT: return "wid/text";
    case HAMWSYS_WIN_CMD: return "wid/cmd";    case HAMWSYS_DRAWCTL: return "wid/draw/ctl";
    case HAMWSYS_BACKBUF: return "wid/backbuffer";
    case HAMWSYS_IMAGES: return "wid/draw/images";
    case HAMWSYS_IMAGE: return "wid/draw/image";
    case HAMWSYS_SINK: return "sink";          default: return "other";
    }
}

static uint64_t opc_now_us(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000u + (uint64_t)(ts.tv_nsec / 1000);
}

static void opc_note(int leaf, int kind)
{
    if (opc_on < 0) {
        const char *e = getenv("HAMWSYS_OPCOUNT");
        opc_on = (e && *e && *e != '0') ? 1 : 0;
    }
    if (!opc_on) return;
    if (leaf < 0 || leaf >= 64) leaf = 0;
    opc_leaf[leaf][kind]++;
    uint64_t now = opc_now_us();
    if (!opc_sec_t0) { opc_sec_t0 = now; opc_10ms_t0 = now; }
    /* THE BURST WINDOW. 10 ms because that is the scale a round trip would be
     * paid on -- a frame is 16 ms, so ops clumped inside one 10 ms window are
     * the ones that would serialise against each other rather than spreading. */
    if (now - opc_10ms_t0 >= 10000) {
        if (opc_cur_10ms > opc_max_10ms) opc_max_10ms = opc_cur_10ms;
        opc_cur_10ms = 0;
        opc_10ms_t0 = now;
    }
    opc_cur_10ms++;
    opc_sec_ops++;
    if (now - opc_sec_t0 >= 1000000) {
        fprintf(stderr, "opcount: %llu ops/s  peak %llu per 10ms (=%llu/s)\n",
                (unsigned long long)opc_sec_ops,
                (unsigned long long)opc_max_10ms,
                (unsigned long long)opc_max_10ms * 100u);
        for (int i = 0; i < 64; i++) {
            if (!opc_leaf[i][0] && !opc_leaf[i][1] && !opc_leaf[i][2]) continue;
            fprintf(stderr, "opcount:    %-18s open %llu read %llu write %llu\n",
                    opc_leafname(i), (unsigned long long)opc_leaf[i][0],
                    (unsigned long long)opc_leaf[i][1],
                    (unsigned long long)opc_leaf[i][2]);
        }
        opc_sec_ops = 0; opc_sec_t0 = now; opc_max_10ms = 0;
    }
}

/* The real body; hamwsys_write wraps it to notice a published change. */
static int64_t hamwsys_write_inner(struct hamwsys_file *f, const uint8_t *buf,
                                   uint64_t n);

/* GROW THE DRAW/CTL REASSEMBLY BUFFER to hold at least `want` bytes.  0 on
 * success, -1 if the allocation failed -- and a failure here is REPORTED by
 * every caller, never absorbed.  See THE REASSEMBLY BUFFER in the DRAWCTL arm
 * of hamwsys_write_inner for what this replaced and why.
 *
 * The caller checks `want` against WSYS_CARRY_CAP first; this one asserts it
 * again rather than trusting that, because the two callers are far apart and
 * an unchecked one would be an unbounded allocation driven by a number the
 * client chose.
 *
 * Doubling from 64 KiB: a client that streams a full 1920x1080 frame in 4 KiB
 * pieces reaches 8 MiB in eight reallocs rather than two thousand, and a
 * client that only ever sends small records never allocates more than 64 KiB.
 * The buffer is freed with the descriptor in hamwsys_close. */
static int carry_reserve(struct hamwsys_file *f, uint64_t want)
{
    if (want > WSYS_CARRY_CAP) return -1;
    if (want <= f->carrycap) return 0;
    uint64_t cap = f->carrycap ? f->carrycap : (uint64_t)65536;
    while (cap < want) cap *= 2;
    if (cap > WSYS_CARRY_CAP) cap = WSYS_CARRY_CAP;
    uint8_t *p = realloc(f->carry, (size_t)cap);
    if (!p) return -1;
    f->carry = p;
    f->carrycap = cap;
    return 0;
}

/* The staging buffer a sink's body is assembled in, same shape as carry_reserve
 * above.  Capped at WSYS_SINK_CAP because that is the sink's own capacity: a
 * body this refuses could not have been published by any route, so the cap is
 * DERIVED rather than picked, and there is nothing here for a peer to outgrow.
 * Freed with the descriptor in hamwsys_close. */
static int sink_stage_reserve(struct hamwsys_file *f, uint64_t want)
{
    if (want > WSYS_SINK_CAP) return -1;
    if (want <= f->stagecap) return 0;
    uint64_t cap = f->stagecap ? f->stagecap : (uint64_t)256;
    while (cap < want) cap *= 2;
    if (cap > WSYS_SINK_CAP) cap = WSYS_SINK_CAP;
    uint8_t *p = realloc(f->stage, (size_t)cap);
    if (!p) return -1;
    f->stage = p;
    f->stagecap = cap;
    return 0;
}

/* PUBLISH A WHOLE BODY, so a reader sees all of it or none of the change.
 *
 * The store order is the contract, and it is the reader's half in snap_set's
 * retry loop (see HAMWSYS_SINK in hamwsys_open) that closes it:
 *
 *   1. shrink `len` FIRST if the new body is shorter, so no reader is ever
 *      pointed at bytes past the end of what is about to be there;
 *   2. copy the body;
 *   3. store the final `len`;
 *   4. bump `serial` LAST, with a release, so a reader that sampled serial
 *      before its copy and again after can tell that steps 1-3 happened
 *      underneath it and read again.
 *
 * `serial` keeps its existing meaning exactly -- one increment per write(2),
 * 0 still means "nothing yet" -- so the launch-queue readers that print it as
 * a token are unaffected.  It simply also serves as the sequence number,
 * which is the same trick shm->gen already plays for window-table writers in
 * hamwsys_write. */
static void sink_publish(struct wsink *s, const uint8_t *body, uint64_t n)
{
    if (n > WSYS_SINK_CAP) n = WSYS_SINK_CAP;
    if (n < s->len) __atomic_store_n(&s->len, (uint32_t)n, __ATOMIC_RELEASE);
    if (n && body) memcpy(s->b, body, (size_t)n);
    __atomic_store_n(&s->len, (uint32_t)n, __ATOMIC_RELEASE);
    __atomic_add_fetch(&s->serial, 1, __ATOMIC_RELEASE);
}

/* ONE CHOKE POINT, not thirty call sites.
 *
 * shm->gen++ appears in about thirty places -- ctl_window, commit, the image
 * and backbuffer publishes, focus changes. Poking the wake at each would be
 * thirty chances to miss one, and a missed one is a window that moves and does
 * not repaint until the fallback tick, which is exactly the bug being fixed
 * and would look like an intermittent stutter.
 *
 * Every one of them is reached through a write to a /dev/wsys leaf, so the
 * generation counter is sampled here, once, on either side of the write. If it
 * moved, something published and the compositor is told. If it did not, the
 * write changed nothing observable and no wake is sent -- which is what keeps
 * an idle desktop idle. */
int64_t hamwsys_write(struct hamwsys_file *f, const uint8_t *buf, uint64_t n)
{
    opc_note(f ? f->leaf : 0, 2);
    /* STAGE 2: hand the mutation to the mediator if there is one.  Inert with
     * HAMWSYS_SERVER unset (srv_fd stays -1), and it returns 0 for every leaf
     * it does not carry, so the in-process path below is untouched for
     * everything else.  It is HERE rather than inside hamwsys_write_inner so
     * that a routed write does not also poke the wake channel: the message
     * itself is what wakes the compositor, and doing both would be the added
     * wake that stage 1's cost measurement was unable to rule out. */
    /* THE ROUTED WRITE'S OWN RETURN VALUE, not an assumed success.  It is the
     * byte count for every fire-and-forget leaf -- the send IS the operation --
     * and the server's rc for `wctl version`, the one routed verb whose caller
     * acts on the answer. */
    if (f) {
        int64_t rr = (int64_t)n;
        if (srv_route_write(f, buf, n, &rr)) return rr;
    }
    uint32_t before = shm ? __atomic_load_n(&shm->gen, __ATOMIC_ACQUIRE) : 0;
    int64_t r = hamwsys_write_inner(f, buf, n);
    if (shm && __atomic_load_n(&shm->gen, __ATOMIC_ACQUIRE) != before)
        wake_poke();
    return r;
}

static int64_t hamwsys_write_inner(struct hamwsys_file *f, const uint8_t *buf,
                                   uint64_t n)
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
    /* /dev/wsys/<wid>/wctl — WRITE: devwsys.ad's per-window verb sink.
     *
     *   version <n>       0/1 legacy scene, 2 the blit protocol.  ANYTHING
     *                     ELSE IS REJECTED so the parser stays a closed set --
     *                     devwsys's words, and the reason a future protocol
     *                     increment has to add a verb here rather than being
     *                     quietly accepted and ignored.
     *   focus click|sloppy
     *   resize <w> <h>    APPLIED, not parked (see below)
     *   move   <x> <y>
     *
     * EVERY VERB EITHER CHANGES THE WINDOW OR RETURNS AN ERROR.  devwsys's own
     * wctl once parked resize/move in a private store nothing read, so the
     * writes "changed nothing on screen" and the read handed the request back
     * as though it were the truth.  resize/move here go through exactly the
     * state the ctl `geometry` verb sets -- one rect, one authority -- and
     * bb_resize follows it so a v2 client's backbuffer is not left cut to the
     * size it opened at.
     *
     * AND THAT bb_resize IS A NO-OP WHEN THIS RUNS IN THE SERVER, which is a
     * property of the leaf and not a defect introduced by routing it.  `bbmap`
     * is per-PROCESS and bb_resize returns early unless this process OWNS the
     * memfd (`!bbmap[i].own`), so a routed `resize` re-fits nothing in the
     * client that asked for it.  The identical thing is already true of the
     * `geometry` verb stage 2 routed -- ctl_window calls the same bb_resize --
     * so this is INHERITED from the other spelling rather than new here, and
     * the self-heal is the same one: bb_for(create=1, v->w, v->h) on the next
     * blit re-fits the memfd, so the two are out of step for at most one
     * frame.  Written down because "the routed path skipped a call" is exactly
     * the kind of difference a pixel gate can see and a byte count cannot. */
    case HAMWSYS_WIN_WCTL: {
        struct wwin *v = win_find(f->wid);
        if (!v) { errno = ENOENT; return -ENOENT; }
        if (!hostowner() && !owns_wid(f->wid)) { errno = EPERM; return -EPERM; }
        if (n == 0) return 0;
        const char *s = (const char *)buf;
        size_t ln = n;
        while (ln && (s[ln - 1] == '\n' || s[ln - 1] == '\r')) ln--;
        size_t p = 0;
        while (p < ln && (s[p] == ' ' || s[p] == '\t')) p++;
        size_t vs = p;
        while (p < ln && s[p] != ' ' && s[p] != '\t') p++;
        size_t vlen = p - vs;
        if (!vlen) { errno = EINVAL; return -EINVAL; }
        int arg_p = (int)p;

        if (vlen == 7 && !strncmp(s + vs, "version", 7)) {
            size_t cur = (size_t)arg_p;
            int32_t k = take_int(s, &cur, ln);
            if (k < 0 || k > 2) { errno = EINVAL; return -EINVAL; }
            if (v->proto != k) {
                v->proto = k;
                /* A protocol switch is a damage event for the whole window --
                 * the compositor must repaint to pick up the new path.  THE
                 * DAMAGE IS shm->gen AND NOT scene_gen, and that distinction
                 * is load-bearing: the scene open path serves a v2 window's
                 * scene as a 0-byte SUCCESS only while scene_gen == 0, and
                 * turns it into an EPERM refusal once it moves.  A v2 client
                 * never commits a scene, so bumping scene_gen here made the
                 * compositor's very next scene read of the window it had just
                 * been told about a refusal -- paint_window then bails at
                 * `if n < 0` before it ever reaches paint_backbuffer, and the
                 * window is never painted.  MEASURED: wsysd logging
                 * "/dev/wsys/2/scene: this process neither owns window 2 nor
                 * holds its display list" for a window whose only sin was
                 * negotiating v2.  This is the same trap bbup_install carries a
                 * comment about; it was reintroduced here and is now fixed in
                 * both places. */
                shm->gen++;
            }
            return (int64_t)n;
        }
        if (vlen == 5 && !strncmp(s + vs, "focus", 5)) {
            size_t cur = (size_t)arg_p;
            while (cur < ln && (s[cur] == ' ' || s[cur] == '\t')) cur++;
            size_t as = (size_t)cur;
            while (cur < ln && s[cur] != ' ' && s[cur] != '\t') cur++;
            size_t alen = (size_t)cur - as;
            if (alen == 5 && !strncmp(s + as, "click", 5))       v->focus_mode = 0;
            else if (alen == 6 && !strncmp(s + as, "sloppy", 6)) v->focus_mode = 1;
            else { errno = EINVAL; return -EINVAL; }
            shm->gen++;
            return (int64_t)n;
        }
        if ((vlen == 6 && !strncmp(s + vs, "resize", 6))
            || (vlen == 4 && !strncmp(s + vs, "move", 4))) {
            size_t cur = (size_t)arg_p;
            int32_t a1 = take_int(s, &cur, ln);
            int32_t a2 = take_int(s, &cur, ln);
            if (a1 == -1 && a2 == -1 && cur >= ln) { errno = EINVAL; return -EINVAL; }
            if (vlen == 6) {
                if (a1 <= 0 || a2 <= 0) { errno = EINVAL; return -EINVAL; }
                v->w = a1; v->h = a2;
                bb_resize(v->wid, a1, a2);
            } else {
                v->x = a1; v->y = a2;
            }
            shm->gen++;
            return (int64_t)n;
        }
        /* A CLOSED SET: an unknown verb is refused, not swallowed.  This whole
         * file exists because a write that succeeds and reaches nothing is the
         * worst answer a device can give. */
        errno = EINVAL;
        return -EINVAL;
    }
    case HAMWSYS_WIN_SCENE: {
        struct wwin *v = win_find(f->wid);
        if (!v) { errno = ENOENT; return -ENOENT; }
        if (!hostowner() && !owns_wid(f->wid)) { errno = EPERM; return -EPERM; }
        struct wpix *p = pix_get(f->wid, owns_wid(f->wid));
        if (!p) { errno = EPERM; return -EPERM; }
        if (p->stage_len > WSYS_SCENE_CAP) p->stage_len = WSYS_SCENE_CAP;
        uint64_t room = WSYS_SCENE_CAP - p->stage_len;
        uint64_t k = n < room ? n : room;
        if (k == 0 && n > 0) { errno = ENOSPC; return -ENOSPC; }
        wr(WR_SCENE, k);
        memcpy(p->stage + p->stage_len, buf, (size_t)k);
        p->stage_len += (uint32_t)k;
        return (int64_t)k;
    }
    case HAMWSYS_WIN_KEYS: case HAMWSYS_WIN_POINTER: case HAMWSYS_WIN_EVENT:
    case HAMWSYS_WIN_TEXT: case HAMWSYS_WIN_CMD: {
        struct wwin *v = win_find(f->wid);
        if (!v) { errno = ENOENT; return -ENOENT; }
        if (!hostowner() && !owns_wid(f->wid)) { errno = EPERM; return -EPERM; }
        if (f->leaf == HAMWSYS_WIN_KEYS) {
            /* The library gate above still refuses a non-owner, and the KERNEL
             * refuses one again at the far end: the receiver drops every
             * datagram the kernel did not stamp with the host owner's uid.
             * This is the one that binds a program which skips this file. */
            wr(WR_KEYS, n);
            return keychan_send(f->wid, buf, n);
        }
        struct wring *q = f->leaf == HAMWSYS_WIN_POINTER ? &v->pointer
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
        /* THE REASSEMBLY BUFFER.
         *
         * A client may split a record across write(2) calls, so an incomplete
         * one is CARRIED rather than dropped -- a torn blit would be a band of
         * garbage across the window, which is exactly the kind of failure that
         * looks like a driver bug and is not.
         *
         * A WHOLE RECORD IS READ STRAIGHT OUT OF THE CALLER'S BUFFER, and that
         * is not an optimisation -- it is what makes a real window blittable.
         *
         * This used to copy every write into the buffer first and refuse
         * anything that did not fit it: `if (carried + n > sizeof carry)
         * return -EMSGSIZE`, against a fixed `static uint8_t carry[1 << 20]`.
         * lib/hamui.ad's hamui_v2_commit_rect composes the whole 'B' header
         * plus the full RGBA payload into one scratch buffer and issues ONE
         * write of it.  For an 880x600 browser window that is 2,112,018 bytes,
         * so EVERY blit from EVERY v2 window bigger than about 512x512 was
         * refused outright -- MEASURED: the write returned -90 (EMSGSIZE), the
         * backbuffer stayed empty, the window painted nothing, and the client's
         * own return check is the only place it was ever mentioned.  A browser
         * is exactly such a window, which is why the v2 path had never carried
         * a real one.
         *
         * THAT FIX ROUTED COMPLETE RECORDS AROUND THE BUFFER AND LEFT THE
         * BUFFER AT 1 MiB, which left the identical defect standing in the
         * SPLIT case -- the case the buffer exists for.  MEASURED, with
         * tests/linux/wsys_chunkblit.sh: a 1024x768 blit written as an 18-byte
         * header plus 768 row writes of 4096 bytes was accepted up to
         * 1,044,498 bytes and then refused with -90 at row 255, where
         * 18 + 256*4096 crosses 1048576.  513 of the 768 writes were refused
         * and the window painted BLACK -- not a partial picture, nothing at
         * all, because a record that never completes is never applied.
         *
         * So the buffer is no longer a fixed array.  It is grown on demand up
         * to WSYS_CARRY_CAP, which is DERIVED from the largest record this
         * device can act on (18 + BB_BYTES; see its definition) rather than
         * picked, and it is per-descriptor rather than a file-scope static --
         * see struct hamwsys_file in linux-wsys.h for why that half matters.
         * Past the cap the refusal is still loud, because the cap is now a
         * bound the rest of the file implies and crossing it means the client
         * is describing something that could not be drawn anyway. */
        const uint8_t *rec;
        uint64_t reclen;
        if (f->carried == 0) {
            rec = buf;                         /* nothing pending: parse in place */
            reclen = n;
        } else {
            uint64_t want = f->carried + n;
            if (want > WSYS_CARRY_CAP) {
                /* A SPLIT record larger than anything this device could draw.
                 * Loud: the silent version of this is what hid the defect
                 * above, twice. */
                static int said;
                if (!said) {
                    said = 1;
                    fprintf(stderr,
                            "wsys: /dev/wsys/%d/draw/ctl: a draw record split "
                            "across writes exceeds the %llu-byte reassembly "
                            "cap (%llu pending + %llu now).\n"
                            "wsys:   The frame is dropped.  The cap is one "
                            "full %dx%d frame; a record bigger than that "
                            "describes pixels no window can show.\n",
                            (int)f->wid, (unsigned long long)WSYS_CARRY_CAP,
                            (unsigned long long)f->carried,
                            (unsigned long long)n, BB_W, BB_H);
                }
                f->carried = 0;
                errno = EMSGSIZE;
                return -EMSGSIZE;
            }
            if (carry_reserve(f, want) < 0) {
                /* Out of memory is a REFUSAL and says so.  Reporting the
                 * write as accepted here would drop the frame silently, which
                 * is the one answer this file exists to never give. */
                fprintf(stderr,
                        "wsys: /dev/wsys/%d/draw/ctl: cannot grow the "
                        "reassembly buffer to %llu bytes -- out of memory. "
                        "The frame is dropped.\n",
                        (int)f->wid, (unsigned long long)want);
                f->carried = 0;
                errno = ENOMEM;
                return -ENOMEM;
            }
            memcpy(f->carry + f->carried, buf, (size_t)n);
            f->carried = want;
            rec = f->carry;
            reclen = f->carried;
        }

        uint64_t i = 0;
        while (i < reclen) {
            uint8_t verb = rec[i];
            uint64_t used = 0;
            if (verb == 'B') {
                /* THE v2 OPT-IN, here rather than at open -- see the DRAWCTL
                 * arm of hamwsys_open.  A blit is the client saying it renders
                 * its own surface; opening the file is not. */
                if (v->proto != 2) { v->proto = 2; shm->gen++; }
                /* THE DECLARED RECT IS CHECKED BEFORE THE PAYLOAD IS WAITED
                 * FOR, which is the same thing the 'I' arm below does and for
                 * the same reason: an oversized record would otherwise sit in
                 * the reassembly buffer accumulating megabytes and be told
                 * EMSGSIZE about the wrong thing much later.
                 *
                 * It is also what makes WSYS_CARRY_CAP a real bound rather
                 * than a hope.  bb_fit clamps every window to BB_W x BB_H and
                 * bb_blit clips every pixel outside it, so a rect larger than
                 * that cannot put a single pixel on the screen -- and
                 * bb_blit's `need` is (x1-x0)*(y1-y0)*bpp with nothing
                 * bounding it, a product that WRAPS uint64 for a large enough
                 * rect and would then pass its own `n < 18 + need` length
                 * check on a short buffer.  Refusing the rect here is what
                 * stops a client's arithmetic from choosing how far bb_blit
                 * reads. */
                if (reclen - i >= 18) {
                    int64_t bx0 = le32(rec + i + 1),  by0 = le32(rec + i + 5);
                    int64_t bx1 = le32(rec + i + 9),  by1 = le32(rec + i + 13);
                    if (bx1 - bx0 > BB_W || by1 - by0 > BB_H) {
                        static int said_rect;
                        if (!said_rect) {
                            said_rect = 1;
                            fprintf(stderr,
                                    "wsys: /dev/wsys/%d/draw/ctl: a blit rect "
                                    "of %lldx%lld is larger than the %dx%d "
                                    "maximum surface -- refused, not "
                                    "buffered.\n",
                                    (int)f->wid, (long long)(bx1 - bx0),
                                    (long long)(by1 - by0), BB_W, BB_H);
                        }
                        f->carried = 0;
                        errno = EMSGSIZE;
                        return -EMSGSIZE;
                    }
                }
                used = bb_blit(v, rec + i, reclen - i);
                if (used) wr(WR_BLIT, used);
            } else if (verb == 'D') {
                if (v->proto != 2) { v->proto = 2; shm->gen++; }
                if (reclen - i < 17) break;
                int slot = bb_for(v->wid, 1, v->w, v->h);
                if (slot >= 0) {
                    /* PUBLISH. Flip only if something was actually drawn --
                     * a bare 'D' on an untouched surface is a no-op, not a
                     * flip back to a stale page. */
                    struct bbpix *h = bbmap[slot].hdr;
                    if (h && h->started) {
                        h->front ^= 1u;
                        h->started = 0;
                    }
                    if (h) h->gen++;
                }
                shm->gen++;
                wr(WR_DAMAGE, 17);
                used = 17;
            } else if (verb == 'C') {
                if (reclen - i < 18) break;
                int32_t cw = le32(rec + i + 9), ch = le32(rec + i + 13);
                uint8_t fmt = rec[i + 17];
                int bpp = (fmt == 3) ? 1 : 4;
                uint64_t need = (uint64_t)cw * ch * bpp;
                if (reclen - i < 18 + need) break;
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
                if (reclen - i < 2) break;
                uint64_t nlen = rec[i + 1];
                if (nlen == 0 || nlen >= WSYS_IMG_NAME_CAP) {
                    f->carried = 0; errno = EINVAL; return -EINVAL;
                }
                uint64_t hdr = 2 + nlen + 9;
                if (reclen - i < hdr) break;
                int32_t iw = le32(rec + i + 2 + nlen);
                int32_t ih = le32(rec + i + 2 + nlen + 4);
                uint8_t ifmt = rec[i + 2 + nlen + 8];
                int ibpp = (ifmt == 3) ? 1 : (ifmt == 1 || ifmt == 2) ? 4 : 0;
                if (iw <= 0 || ih <= 0 || !ibpp) {
                    f->carried = 0; errno = EINVAL; return -EINVAL;
                }
                if (iw > WSYS_IMG_MAX_W || ih > WSYS_IMG_MAX_H) {
                    /* Refused BEFORE the payload is waited for: an oversized
                     * image would otherwise sit in the carry buffer until it
                     * overflowed, and the client would be told EMSGSIZE about
                     * the wrong thing several megabytes later. */
                    f->carried = 0; errno = EMSGSIZE; return -EMSGSIZE;
                }
                uint64_t ipix = (uint64_t)iw * (uint64_t)ih * (uint64_t)ibpp;
                if (reclen - i < hdr + ipix) break;
                int rc = img_store(v->wid, (const char *)rec + i + 2, nlen,
                                   iw, ih, ifmt, rec + i + hdr);
                if (rc < 0) { f->carried = 0; errno = -rc; return rc; }
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
                f->carried = 0;
                errno = EINVAL;
                return -EINVAL;
            }
            if (used == 0) break;      /* incomplete: wait for more */
            i += used;
        }
        /* Whatever is left is a PARTIAL record: keep it for the next write. */
        uint64_t left = reclen - i;
        if (left > WSYS_CARRY_CAP) {
            /* One write carrying a partial record bigger than any drawable
             * frame.  This used to be a bare `return -EMSGSIZE` with nothing
             * said, which is the quiet half of the same defect. */
            static int said_left;
            if (!said_left) {
                said_left = 1;
                fprintf(stderr,
                        "wsys: /dev/wsys/%d/draw/ctl: a partial draw record of "
                        "%llu bytes exceeds the %llu-byte reassembly cap. "
                        "The frame is dropped.\n",
                        (int)f->wid, (unsigned long long)left,
                        (unsigned long long)WSYS_CARRY_CAP);
            }
            f->carried = 0;
            errno = EMSGSIZE;
            return -EMSGSIZE;
        }
        if (left) {
            if (rec == f->carry) {
                /* It came out of this buffer, so it already fits it.  No
                 * carry_reserve call here on purpose: a realloc would move
                 * `rec` out from under the memmove. */
                memmove(f->carry, f->carry + i, (size_t)left);
            } else if (carry_reserve(f, left) < 0) {
                fprintf(stderr,
                        "wsys: /dev/wsys/%d/draw/ctl: cannot hold a %llu-byte "
                        "partial record -- out of memory. The frame is "
                        "dropped.\n",
                        (int)f->wid, (unsigned long long)left);
                f->carried = 0;
                errno = ENOMEM;
                return -ENOMEM;
            } else {
                memcpy(f->carry, rec + i, (size_t)left);
            }
        }
        f->carried = left;
        return (int64_t)n;
    }
    case HAMWSYS_SINK: {
        if (!sink_write_allowed(f->name)) { errno = EPERM; return -EPERM; }
        errno = 0;
        wr(sink_is_public(f->name) ? WR_SINK : WR_CHROME, n);
        struct wsink *s = sink_find(f->name, 1);
        if (!s) { int e = errno ? errno : ENOSPC; errno = e; return -e; }
        /* ASSEMBLE, THEN PUBLISH.  The append is into this descriptor's own
         * staging buffer, so a sink written across several write(2) calls is
         * still only ever visible to a reader as a COMPLETE body -- the one
         * before this open, or the one built so far.  It is never visible as
         * the empty string, which is what the truncate-on-open produced. */
        uint64_t room = WSYS_SINK_CAP - f->stagelen;
        uint64_t k = n < room ? n : room;
        if (k && sink_stage_reserve(f, f->stagelen + k) < 0) {
            errno = ENOMEM; return -ENOMEM;
        }
        if (k) memcpy(f->stage + f->stagelen, buf, (size_t)k);
        f->stagelen += k;
        f->staged = 1;
        sink_publish(s, f->stage, f->stagelen);
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
    /* The reassembly buffer dies with the descriptor.  Anything still in it
     * is half a draw record whose other half is never coming. */
    free(f->carry);
    f->carry = NULL;
    f->carrycap = 0;
    f->carried = 0;
    /* TRUNCATE-WITH-NO-WRITE, kept working and made atomic.
     * `> /dev/wsys/foo` (or any open-for-write closed without a write) still
     * empties the sink -- but as ONE store at close, not as a window that
     * opens at open(2) and stays open until somebody gets around to writing.
     * A reader either sees the old body or sees it gone. */
    if (f->staged && f->stagelen == 0 && f->leaf == HAMWSYS_SINK && shm) {
        struct wsink *s = sink_find(f->name, 0);
        if (s && s->len) { sink_publish(s, NULL, 0); shm->gen++; }
    }
    f->staged = 0;
    free(f->stage);
    f->stage = NULL;
    f->stagecap = 0;
    f->stagelen = 0;
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
    /* Release the name with the window, so a later wid reuse can bind it.  A
     * process that is not the holder has nothing to release and this is a
     * no-op there. */
    keychan_unbind(wid);
    pix_release(wid);
    bb_release(wid);
    img_release_wid(wid);              /* devwsys's _wsys_img_release_wid */
    v->used = 0;
    if (shm->focus_wid == wid) shm->focus_wid = 0;
    shm->gen++;
    return 0;
}
