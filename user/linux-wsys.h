/* user/linux-wsys.h — the seam between the syscall runtime and the window
 * system device.  See user/linux-wsys.c for what these mean.
 *
 * This is the Linux port of sys/src/9/port/devwsys.ad.  In Hamnix that is
 * KERNEL code: the window table, the per-window scene buffers and the event
 * rings live in kernel memory, and both the clients and the compositor poke
 * the same storage through /dev/wsys.  The faithful port of shared kernel
 * memory is shared memory — not an RPC server — so that is what this is.
 *
 * PERMISSION.  devwsys's uid gate is ported too; see THE UID GATE in
 * user/linux-wsys.c.  Reads are never refused.  A write is refused with
 * EPERM — from hamwsys_open when opening for writing already mutates, and
 * again from hamwsys_write — when the caller is neither the host owner (the
 * uid that owns the segment, root on a real boot) nor the owner of the
 * window being addressed.  Ordinary client operations, `newwindow` and
 * everything under the caller's own wid, are open to every uid: that is what
 * the segment's 0666 mode is for.
 *
 * TWO SEGMENTS, which is what makes that gate real for the system chrome.
 * /srv/wsys stays 0666 and holds the window table — a client of any uid must
 * be able to map and draw its own window or the DE session is blind.
 * /srv/wsys.chrome is 0644 and owned by the host owner, and holds the screen
 * geometry and the chrome sinks; non-owners map it PROT_READ, so the kernel
 * refuses a chrome write even to a program that skips this file entirely.  The
 * rule for which state goes where, and what is still NOT covered, is THE SPLIT
 * in user/linux-wsys.c.
 */
#ifndef HAMNIX_LINUX_WSYS_H
#define HAMNIX_LINUX_WSYS_H

#include <stdint.h>

/* Leaf kinds.  HAMWSYS_NONE means "this path is not part of /dev/wsys". */
enum {
    HAMWSYS_NONE = 0,
    HAMWSYS_CTL,          /* /dev/wsys/ctl        — global verbs + newwindow */
    HAMWSYS_SELF,         /* /dev/wsys/self       — this task's wid, if any  */
    HAMWSYS_WINDOWS,      /* /dev/wsys/windows    — "<wid> <title>\n" each   */
    HAMWSYS_SCREEN,       /* /dev/wsys/screen     — "<w> <h>\n", read-only   */
    HAMWSYS_POOL,         /* /dev/wsys/pool       — the v2 paint pool, read- */
                          /*   only: how many backbuffer slots exist, how    */
                          /*   many are in use, and how many times one was   */
                          /*   REFUSED.  A window with no slot is never      */
                          /*   painted and cannot say so itself; this is how */
                          /*   that condition is read back.                  */
    HAMWSYS_DIR,          /* /dev/wsys, /dev/wsys/<wid> — directory listing  */
    HAMWSYS_WIN_CTL,      /* /dev/wsys/<wid>/ctl                             */
    HAMWSYS_WIN_SCENE,    /* /dev/wsys/<wid>/scene                           */
    HAMWSYS_WIN_KEYS,     /* /dev/wsys/<wid>/keys                            */
    HAMWSYS_WIN_POINTER,  /* /dev/wsys/<wid>/pointer                         */
    HAMWSYS_WIN_EVENT,    /* /dev/wsys/<wid>/event                           */
    HAMWSYS_WIN_TEXT,     /* /dev/wsys/<wid>/text                            */
    HAMWSYS_WIN_CMD,      /* /dev/wsys/<wid>/cmd                             */
    HAMWSYS_DRAWCTL,      /* /dev/wsys/<wid>/draw/ctl — the v2 blit protocol */
    HAMWSYS_BACKBUF,      /* /dev/wsys/<wid>/backbuffer — the v2 pixels       */
    HAMWSYS_IMAGES,       /* /dev/wsys/<wid>/draw/images — the named-image    */
                          /*   directory: "<name> <w> <h> <serial>\n" each    */
    HAMWSYS_IMAGE,        /* /dev/wsys/<wid>/draw/image/<name> — raw RGBA8888 */
    HAMWSYS_SINK,         /* every other /dev/wsys/... path — a named buffer */
};

/* Per-open state.  Lives inside the runtime's devtab entry. */
struct hamwsys_file {
    int      leaf;
    int      wid;
    int      write;
    uint64_t off;        /* read cursor into `snap`, or write cursor       */
    uint8_t *snap;       /* snapshot-once read image (malloc'd), or NULL   */
    uint64_t snaplen;
    char     name[64];   /* HAMWSYS_SINK: the path below /dev/wsys/        */
};

int     hamwsys_kind(const char *path);
int     hamwsys_open(const char *path, int for_write, struct hamwsys_file *f);
int64_t hamwsys_read(struct hamwsys_file *f, uint8_t *buf, uint64_t cap);
int64_t hamwsys_write(struct hamwsys_file *f, const uint8_t *buf, uint64_t n);
void    hamwsys_close(struct hamwsys_file *f);

/* THE IDLE PARK.  sys_waitfds (user/linux-syscalls.c) uses these to sleep a
 * scene client off the runqueue until input lands in one of its rings.  A
 * /dev/wsys descriptor is a descriptor on /dev/null, so poll(2) calls it
 * readable instantly and always; without this seam every parking event loop
 * on the system is a busy spin.  See THE PARK in user/linux-wsys.c. */
/* THE CLIENT WAKE. hamwsys_wake_listen() binds an abstract AF_UNIX datagram
 * name derived from the segment and returns a POLLABLE fd; any process that
 * publishes a change (shm->gen moves) sends a byte to it. The compositor
 * appends the fd to its ordinary wait set, which keeps sys_waitfds on its
 * single uncapped poll(2) arm -- a /dev/wsys ring in that set would instead
 * force a FUTEX_WAIT that an evdev fd can never wake. Drain it on every wake:
 * an unread datagram stays readable and would turn the park into a spin. */
int      hamwsys_wake_listen(void);
void     hamwsys_wake_drain(void);

int      hamwsys_is_ring(const struct hamwsys_file *f);
int      hamwsys_ring_ready(const struct hamwsys_file *f);
uint32_t hamwsys_input_gen(void);
int      hamwsys_input_wait(uint32_t seen, int64_t timeout_ms);

/* THE PIXEL HAND-UP'S HEARTBEAT, and it belongs on the PARK.
 *
 * A window's display list lives in a memfd its owner hands to the compositor
 * (THE PIXEL HAND-UP in user/linux-wsys.c), and the hand-up is the client's
 * own action.  Driving it from the wsys calls a client makes covers a client
 * that is drawing and MISSES THE ONE THAT HAS STOPPED -- an application that
 * paints its window once and then parks makes no wsys call ever again, so a
 * compositor that binds after it (or restarts) would never be handed that
 * window and would paint a blank rectangle for ever with nothing on stderr.
 * Measured: hamimgscene draws one photograph and parks, and it was blank.
 *
 * sys_waitfds is where every such program is.  That is the property being
 * used -- not "somewhere convenient", but the one call a client that is doing
 * nothing at all still makes.  It is gated on a monotonic clock read inside,
 * and returns immediately in a process that owns no window. */
void     hamwsys_tick(void);

/* The two syscalls hamUI uses to bind a spawned task to a window. */
int32_t hamwsys_alloc(uint64_t pid);
int32_t hamwsys_free(int32_t wid);

#endif
