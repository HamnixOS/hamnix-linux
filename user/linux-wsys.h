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
    HAMWSYS_WIN_WCTL,     /* /dev/wsys/<wid>/wctl — Plan 9 rio's per-window  */
                          /*   control file: version/focus/resize/move, and  */
                          /*   a read of the LIVE rect. devwsys.ad's "DE      */
                          /*   primitive". lib/hamui.ad negotiates v2 here.  */
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

/* ==================================================================
 * THE MEDIATOR'S TRANSPORT — STAGE 1 OF docs/wsys_server_design.md
 * ==================================================================
 * Everything below is INERT unless HAMWSYS_SERVER=1 is in the environment.
 * With the flag unset hamwsys_srv_listen() returns -1 before it touches a
 * socket or the segment, no client ever connects, and every /dev/wsys
 * operation takes exactly the in-process path it takes today. That is the
 * whole acceptance criterion for this stage: a transport that works and
 * changes nothing.
 *
 * WHY A TRANSPORT AT ALL. /dev/wsys is implemented IN-PROCESS: the window
 * system is linked into every client, so a client's write is its own code
 * touching shared memory. There is no mediator inside the object, which is
 * why a same-uid process can read another window's pixels, why win_alloc can
 * race two clients onto one row, and why enumeration is open by design --
 * the reader's own linked-in code answers from shared memory, so there is
 * nowhere a policy could live. tests/linux/wsys_enum_policy.sh states that as
 * a red gate. A server process is the mediator Plan 9 gets from its kernel.
 *
 * THE SHAPE, WHICH CAME FROM MEASUREMENT AND NOT FROM TASTE
 * (tests/linux/wsys_rtt_probe.c, docs/wsys_server_cost.md):
 *
 *   Strict request-reply is the expensive pattern, not volume. Per-op cost
 *   falls 6.30 us one-at-a-time -> 3.14 at 4 -> 2.31 at 16 -> 2.37 at 64.
 *   So EVERY MUTATION THAT RETURNS NO DATA IS FIRE-AND-FORGET: the client
 *   writes and does not wait, and errors come back out of band on the event
 *   ring it is already draining (WSRV_OP_ERR below, tag 0). Only genuinely
 *   interrogative operations block -- newwindow, wctl version negotiation,
 *   and reads.
 *
 * PIXELS DO NOT CROSS. Per-window memfds are handed up from the owner
 * (THE PIXEL HAND-UP in linux-wsys.c) and stay there. That property is what
 * makes the boundary cost 0.12% of a core instead of megabytes a frame, and
 * it is verified rather than assumed: tests/linux/wsys_srv_transport.sh
 * re-runs the write census and requires zero backbuffer bytes.
 *
 * SOCK_SEQPACKET on an abstract name derived from the segment's (dev, ino) --
 * the same naming the client wake above already uses, so there is exactly one
 * way to find this window system. One message is one packet; there is no
 * framing to get wrong and no partial read to resynchronise from.
 *
 * WHAT STAGE 1 DOES NOT DO. No /dev/wsys operation is routed over this yet.
 * Mutations are stage 2, reads and the enumeration policy stage 3, and the
 * WSYS_VERSION bump is stage 4 and LAST -- the bump is what makes a
 * pre-server client refuse rather than silently mmap the segment and bypass
 * the mediator, so bumping before the in-process path is gone would refuse
 * clients on behalf of a boundary that is not yet enforced.
 */

/* Wire constants. Both sides are the same object file, so this is
 * documentation and a probe's contract rather than an ABI -- but the probe
 * checks it, so it is written down. */
enum {
    WSRV_MAGIC_RQ = 0x51525357u,   /* "WSRQ" */
    WSRV_MAGIC_RP = 0x50525357u,   /* "WSRP" */
    WSRV_MAXPAY   = 65536,         /* a scene is <=16 KiB; this is headroom  */
    WSRV_CONN_MAX = 64,            /* concurrent clients the server holds    */

    WSRV_F_REPLY  = 1,             /* set: the caller is blocked on a reply  */
    /* STAGE 5.  Set on the HELLO of a connection that was INHERITED rather
     * than dialled (HAMWSYS_SRV_FD).  It costs the connection hostowner() for
     * ever, because SO_PEERCRED still names the process that dialled: a
     * descriptor handed down from a host-owner toolkit would otherwise carry
     * host-owner power to whatever it was handed to.  A client can only ever
     * declare itself adopted, so the flag can lose privilege, never gain it. */
    WSRV_F_ADOPT  = 2,

    WSRV_OP_HELLO = 1,             /* blocks: version handshake              */
    WSRV_OP_NOP   = 2,             /* fire-and-forget: the mutation shape    */
    WSRV_OP_PING  = 3,             /* blocks: the interrogative shape        */
    WSRV_OP_STAT  = 4,             /* blocks: the server's own counters      */
    WSRV_OP_ERR   = 5,             /* server -> client, tag 0, unsolicited   */

    /* STAGE 2 — THE MUTATIONS, which is where the privilege questions live.
     *
     * WRITE is one message for one write to /dev/wsys/ctl or
     * /dev/wsys/<wid>/ctl: open, write, close, all of it, because NEITHER OF
     * THOSE LEAVES HAS PER-OPEN STATE.  The census says open and write come
     * in pairs there (9791 opens, 9790 writes in 12 s of a drag), so the
     * one-shot form is not a shortcut -- it is the shape the traffic already
     * has, and it keeps a mutation at one message instead of three.
     *
     * `wid` names the window; `flags`' low bits carry the leaf, because a
     * message that did not say which file it was writing would be a mediator
     * that has to guess.
     *
     * NEWWIN BLOCKS, and it is the only mutation that does.  It returns data
     * -- the wid -- so there is nothing to be gained by not waiting.  Routing
     * it is also what makes win_alloc's race STRUCTURALLY impossible rather
     * than merely fixed; see THE RACE THAT ROUTING RETIRES at win_alloc.
     */
    WSRV_OP_WRITE  = 6,            /* fire-and-forget: one ctl/wid-ctl write */
    WSRV_OP_NEWWIN = 7,            /* blocks: allocate a row, return the wid */

    /* STAGE 4 — THE READS, AND THE ONE OPERATION THAT CANNOT BE SERVICED
     * FROM THE FRAME LOOP.
     *
     * READ blocks by nature: it returns the bytes.  Stage 1 measured what
     * blocking costs against a server serviced from wsysd's frame loop --
     * p50 32 us, but a p90 of 789 us and a max of 851, because a request that
     * arrives while the compositor is rasterizing waits out the frame.  851
     * us is nearly three times the whole published 0.3 ms input-to-pixel
     * budget, for one operation, and a taskbar re-reading /dev/wsys/windows
     * would pay it on every refresh.
     *
     * So READ IS NOT SERVED BY THE FRAME LOOP AT ALL.  wsysd forks a read
     * server at listen(), on its own abstract name (".../rd"), which does
     * nothing but block in epoll_wait and answer interrogative requests out
     * of the same MAP_SHARED segment.  It never rasterizes, so there is no
     * frame for a read to wait out.  Mutations stay on the frame-loop socket,
     * where stage 2 measured routing making the compositor CHEAPER precisely
     * because the loop coalesces them.
     */
    WSRV_OP_READ   = 8,            /* blocks: one snapshot of a read-only leaf */

    /* Which leaf a WSRV_OP_WRITE or WSRV_OP_READ addresses.  Carried in
     * `flags` above WSRV_F_REPLY. */
    WSRV_LEAF_SHIFT = 8,
    WSRV_LEAF_CTL     = 1,         /* /dev/wsys/ctl                          */
    WSRV_LEAF_WIN_CTL = 2,         /* /dev/wsys/<wid>/ctl                    */
    WSRV_LEAF_WINDOWS = 3,         /* /dev/wsys/windows  — AND A POLICY      */
    WSRV_LEAF_SCREEN  = 4,         /* /dev/wsys/screen                       */
    WSRV_LEAF_POOL    = 5,         /* /dev/wsys/pool                         */
};

/* THE SERVER SIDE. wsysd calls claim() before it touches /dev/wsys at all --
 * it is a client of its own device and must never dial itself -- then
 * listen() once from build_waitset, and service() once per loop iteration.
 *
 * listen() returns an EPOLL fd, not the listening socket. The set of live
 * connections changes as clients come and go; wsysd's wait set is built once.
 * One epoll fd standing for all of them means the wait set never has to be
 * rebuilt and the Adder side never learns how many clients there are.
 *
 * service() is non-blocking and must be called on EVERY wake, including wakes
 * it did not cause: an unread packet stays readable, and an unserviced epoll
 * fd would turn the compositor's park into a spin -- the same trap
 * hamwsys_wake_drain exists for. */
void     hamwsys_srv_claim(void);
int      hamwsys_srv_listen(void);
int      hamwsys_srv_service(void);

/* THE READ SERVER IS FORKED BY listen() AND HAS NO ENTRY POINT HERE, on
 * purpose.  A hamwsys_srv_read_service() the Adder side had to call would put
 * reads back on the frame loop -- the exact 851 us tail the split exists to
 * remove.  The only thing wsysd does about it is exist. */

/* THE CLIENT SIDE, for the stage-1 gate. Returns the number of failures, so
 * zero is the only pass and a stub cannot pass by resolving. Exported to
 * Adder as
 *   extern def sys_wsys_srv_selftest() -> int32
 *   extern def sys_wsys_srv_sustain(ops_per_sec: int32, secs: int32) -> int32 */
int      hamwsys_srv_selftest(void);
int      hamwsys_srv_mutate_selftest(int victim_wid);
int      hamwsys_srv_sustain(int ops_per_sec, int secs);
int      hamwsys_srv_attack_local(int victim_wid);
/* Stage 4's instrument: N routed reads of /dev/wsys/windows, every sample
 * printed, against the 851 us frame-loop tail stage 1 measured.  Exported as
 *   extern def sys_wsys_srv_readlat(n: int32) -> int32 */
int      hamwsys_srv_readlat(int nsamples);

/* STAGE 5 — HANDING THE CONNECTION TO A SPAWNED TASK.
 *
 * A routed mutation must now arrive on the connection that holds the window's
 * row, so a program spawned INTO somebody else's window is refused unless the
 * spawner hands it that connection.  Call with 1 immediately before the spawn
 * and 0 immediately after: in between, this process's server connection is
 * inheritable and named in HAMWSYS_SRV_FD.  Returns 0 if there is a connection
 * to inherit, -1 if there is not (flag unset, no server, dial refused) -- in
 * which case the child behaves exactly as it does today.
 *
 * AFTER any privilege drop, never before: SO_PEERCRED is sampled at connect(2)
 * and the connection carries the dialling process's uid wherever it goes.
 * Exported to Adder as
 *   extern def sys_wsys_srv_handoff(on: int32) -> int32 */
int      hamwsys_srv_handoff(int on);

/* Stage 5's gate driver: hold a window's connection and spawn `self` twice --
 * once WITHOUT the handoff and once WITH it -- so both arms of the property
 * are measured in one process.  Returns a failure count.  Exported as
 *   extern def sys_wsys_srv_conngate(wid: int32, selfpath: Ptr[char],
 *                                   uidgate: Ptr[char]) -> int32 */
int      hamwsys_srv_conngate(int wid, const char *self,
                              const char *uidgate);

/* Did THIS process get turned away by the version refusal in shm_attach?
 * Its own experience, not a file another process wrote -- see
 * seg_refused_here in linux-wsys.c. Exported to Adder as
 *   extern def sys_wsys_was_refused() -> int32 */
int      hamwsys_was_refused(void);
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
