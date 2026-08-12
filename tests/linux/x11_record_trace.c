/* tests/linux/x11_record_trace.c — WHAT DOES **ANOTHER** CLIENT ASK THE X
 * SERVER FOR? A protocol tracer with no proxy, using the RECORD extension.
 *
 * WHY THIS EXISTS. docs/steam_namespace.md §12.2c narrowed the "Steam does not
 * scroll" bug to somewhere above the X server: in ONE X session, an xterm
 * scrolled 471 px while Steam's store page changed 0 of 564400. The next
 * question that pass named was "does CEF's XISelectEvents mask on that window
 * actually select the scroll valuator?" -- the valuator is proven live at the
 * server (tests/linux/xi2_scroll_probe.c, 30 PASS on both Xwayland versions),
 * so the only thing left is whether Steam ASKED for it.
 *
 * AND THE OBVIOUS TOOL CANNOT ANSWER IT. `XIGetSelectedEvents` looks like the
 * right call and is not: the server's ProcXIGetSelectedEvents filters the
 * window's input-client list with SameClient(), so it returns only the
 * masks THE CALLING CLIENT selected. Pointed at Steam's window it returns an
 * empty list whether Steam selected everything or nothing -- a probe that
 * answers "Steam selected nothing" no matter what the truth is, which is
 * exactly the success-shaped answer NORTH_STAR.md forbids. This file exists
 * because that trap was walked into on paper before it was walked into in a
 * measurement.
 *
 * WHAT IT DOES INSTEAD. RECORD intercepts the byte stream of OTHER clients'
 * requests at the server. We ask for:
 *
 *   * every request of the XInputExtension (learned by XQueryExtension --
 *     extension major opcodes are assigned per SERVER, not per client, so the
 *     number this process is told is the number Steam is using), decoded for
 *     XISelectEvents: which window, which device, which event bits;
 *   * core CreateWindow / ChangeWindowAttributes, decoded for the core
 *     event-mask, because a client that wants the wheel the OLD way selects
 *     ButtonPressMask and reads button 4/5;
 *   * core GrabPointer / GrabButton, because a grab redirects the wheel
 *     somewhere other than the window under the pointer.
 *
 * Every line carries the requesting client's RESOURCE ID BASE (`cl=`), which
 * is how one X session's several clients -- Steam, steamwebhelper, jwm, and
 * this probe -- are told apart, and the window id, which is how the answer is
 * matched against `xwininfo -tree`.
 *
 * IT SAYS SO WHEN IT CANNOT WORK. If the server has no RECORD extension this
 * exits non-zero with a named message rather than printing nothing and
 * exiting 0, because "no XISelectEvents seen" and "no tracer running" are the
 * same empty log and only one of them means anything.
 *
 * A RECORD tracer only sees requests made AFTER it attaches. Start it before
 * the window whose selection is in question is created.
 *
 * cc -O2 -o x11_record_trace x11_record_trace.c -lX11 -lXtst
 */
#include <X11/Xlib.h>
#include <X11/Xproto.h>
#include <X11/extensions/record.h>
#include <X11/extensions/XInput2.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static int xi_opcode;
static struct timespec t0;

static double now(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (t.tv_sec - t0.tv_sec) + (t.tv_nsec - t0.tv_nsec) / 1e9;
}

/* XI2 event type -> name, for the bits of an XISelectEvents mask. The three
 * that matter to this bug are Motion (smooth scroll arrives as valuators on a
 * motion event), ButtonPress (the core-style 4/5 wheel, which XI2 also
 * reports) and RawMotion. */
static const char *xi_evname(int b)
{
    switch (b) {
    case XI_DeviceChanged:      return "DeviceChanged";
    case XI_KeyPress:           return "KeyPress";
    case XI_KeyRelease:         return "KeyRelease";
    case XI_ButtonPress:        return "ButtonPress";
    case XI_ButtonRelease:      return "ButtonRelease";
    case XI_Motion:             return "Motion";
    case XI_Enter:              return "Enter";
    case XI_Leave:              return "Leave";
    case XI_FocusIn:            return "FocusIn";
    case XI_FocusOut:           return "FocusOut";
    case XI_HierarchyChanged:   return "HierarchyChanged";
    case XI_PropertyEvent:      return "PropertyEvent";
    case XI_RawKeyPress:        return "RawKeyPress";
    case XI_RawKeyRelease:      return "RawKeyRelease";
    case XI_RawButtonPress:     return "RawButtonPress";
    case XI_RawButtonRelease:   return "RawButtonRelease";
    case XI_RawMotion:          return "RawMotion";
    case XI_TouchBegin:         return "TouchBegin";
    case XI_TouchUpdate:        return "TouchUpdate";
    case XI_TouchEnd:           return "TouchEnd";
    case XI_TouchOwnership:     return "TouchOwnership";
    case XI_RawTouchBegin:      return "RawTouchBegin";
    case XI_RawTouchUpdate:     return "RawTouchUpdate";
    case XI_RawTouchEnd:        return "RawTouchEnd";
    default:                    return NULL;
    }
}

static const char *xi_reqname(int minor)
{
    switch (minor) {
    case 40: return "XIQueryPointer";
    case 41: return "XIWarpPointer";
    case 42: return "XIChangeCursor";
    case 43: return "XIChangeHierarchy";
    case 44: return "XISetClientPointer";
    case 45: return "XIGetClientPointer";
    case 46: return "XISelectEvents";
    case 47: return "XIQueryVersion";
    case 48: return "XIQueryDevice";
    case 49: return "XISetFocus";
    case 50: return "XIGetFocus";
    case 51: return "XIGrabDevice";
    case 52: return "XIUngrabDevice";
    case 53: return "XIAllowEvents";
    case 54: return "XIPassiveGrabDevice";
    case 55: return "XIPassiveUngrabDevice";
    case 56: return "XIListProperties";
    case 57: return "XIChangeProperty";
    case 58: return "XIDeleteProperty";
    case 59: return "XIGetProperty";
    case 60: return "XIGetSelectedEvents";
    case 61: return "XIBarrierReleasePointer";
    default: return "XI?";
    }
}

static unsigned u16(const unsigned char *p) { return p[0] | (p[1] << 8); }
static unsigned u32(const unsigned char *p)
{
    return (unsigned)p[0] | ((unsigned)p[1] << 8) | ((unsigned)p[2] << 16) |
           ((unsigned)p[3] << 24);
}

/* Core event-mask bits that a wheel could arrive on. */
static void print_core_mask(unsigned m)
{
    if (m & ButtonPressMask)   printf(" ButtonPress");
    if (m & ButtonReleaseMask) printf(" ButtonRelease");
    if (m & PointerMotionMask) printf(" PointerMotion");
    if (m & Button1MotionMask) printf(" Button1Motion");
    if (m & EnterWindowMask)   printf(" Enter");
    if (m & LeaveWindowMask)   printf(" Leave");
    if (m & KeyPressMask)      printf(" KeyPress");
    if (m == 0)                printf(" (none)");
}

/* Pull the CWEventMask value out of a CreateWindow/ChangeWindowAttributes
 * value list: the values are in bit order, so the index is the population
 * count of the mask bits below CWEventMask. */
static int event_mask_value(unsigned vmask, const unsigned char *vals,
                            int nvals, unsigned *out)
{
    if (!(vmask & CWEventMask)) return 0;
    int idx = 0;
    for (unsigned b = 1; b < CWEventMask; b <<= 1)
        if (vmask & b) idx++;
    if (idx >= nvals) return 0;
    *out = u32(vals + 4 * idx);
    return 1;
}

/* ---- what the server DELIVERED, and to whom -------------------------------
 *
 * The request half above answers "what did Steam ask for". This half answers
 * the question that actually decides the bug: WHEN A WHEEL NOTCH HAPPENS,
 * WHAT DOES THE SERVER PUT ON STEAM'S CONNECTION? A client can select for an
 * event and still not act on it, and it can act on one it never selected via
 * a grab -- only the delivered stream separates "Steam was not told" from
 * "Steam was told and did nothing".
 *
 * RECORD hands events over as 32 bytes. That is the whole of a core event and
 * only the header of an XI2 GenericEvent, so the valuators of an XI_Motion
 * are NOT visible here. They do not need to be: the measurement holds the
 * pointer COMPLETELY STILL and then wheels, so every XI_Motion delivered
 * during that burst is a scroll and nothing else -- the same reasoning
 * tests/linux/vm_wheel_reaches.sh uses on wsysd's pointer counter.
 */
static const char *core_evname(int t)
{
    switch (t) {
    case ButtonPress:   return "ButtonPress";
    case ButtonRelease: return "ButtonRelease";
    case MotionNotify:  return "MotionNotify";
    case EnterNotify:   return "EnterNotify";
    case LeaveNotify:   return "LeaveNotify";
    default:            return "core?";
    }
}

static void on_event(XRecordInterceptData *d)
{
    const unsigned char *p = (const unsigned char *)d->data;
    if (d->data_len * 4 < 32) return;
    int type = p[0] & 0x7f;
    int sent = (p[0] & 0x80) ? 1 : 0;
    /* Two kinds arrive on this path and confusing them would answer the wrong
     * question. A DEVICE event is the raw one, before delivery: it has no
     * recipient and no window, and `id_base` is 0. A DELIVERED event is the
     * one a particular client actually got, with that client's id_base and
     * the window it was delivered on. "the wheel reached the server" is the
     * first; "Steam was told about the wheel" is only ever the second. */
    int devlevel = (d->id_base == 0);
    const char *tag = devlevel ? "DEV" : "GOT";

    if (type == GenericEvent) {
        int ext = p[1];
        unsigned evtype = u16(p + 8), dev = u16(p + 10);
        unsigned detail = u32(p + 16), win = u32(p + 24);
        if (ext != xi_opcode) return;
        const char *n = xi_evname((int)evtype);
        printf("%8.3f cl=0x%08lx %s XI2 %s dev=%u detail=%u win=0x%x%s\n",
               now(), (unsigned long)d->id_base, tag, n ? n : "?", dev, detail,
               win, sent ? " (SendEvent)" : "");
        return;
    }
    if (type == ButtonPress || type == ButtonRelease || type == MotionNotify ||
        type == EnterNotify || type == LeaveNotify) {
        printf("%8.3f cl=0x%08lx %s %s detail=%u win=0x%x%s\n", now(),
               (unsigned long)d->id_base, tag, core_evname(type), p[1],
               u32(p + 12), sent ? " (SendEvent)" : "");
    }
}

static void on_data(XPointer closure, XRecordInterceptData *d)
{
    (void)closure;
    /* RECTRACE_RAW=1 prints the category and first bytes of everything that
     * arrives. It exists because the delivered-event half of this file was
     * silent for a run in which the client it was watching DID receive the
     * events -- and a silent tracer and a client that got nothing are the
     * same log. */
    if (getenv("RECTRACE_RAW")) {
        const unsigned char *q = (const unsigned char *)d->data;
        printf("%8.3f RAW cat=%d len=%u bytes=%02x %02x %02x %02x\n", now(),
               d->category, (unsigned)d->data_len,
               d->data_len ? q[0] : 0, d->data_len ? q[1] : 0,
               d->data_len ? q[2] : 0, d->data_len ? q[3] : 0);
    }
    if (d->category == XRecordFromServer) { on_event(d); goto out; }
    if (d->category != XRecordFromClient) goto out;
    if (d->client_swapped) {
        /* Every client in this session is the same endianness as the server;
         * a byte-swapped one would decode as garbage, so say so rather than
         * print numbers nobody can trust. */
        printf("%8.3f cl=0x%08lx SWAPPED CLIENT -- not decoded\n",
               now(), (unsigned long)d->id_base);
        goto out;
    }
    const unsigned char *p = (const unsigned char *)d->data;
    if (d->data_len < 1) goto out;
    unsigned nbytes = (unsigned)d->data_len * 4;
    int opcode = p[0];

    if (opcode == xi_opcode) {
        int minor = p[1];
        if (minor == 46 && nbytes >= 12) {          /* XISelectEvents */
            unsigned win = u32(p + 4);
            unsigned nmasks = u16(p + 8);
            printf("%8.3f cl=0x%08lx XISelectEvents win=0x%x nmasks=%u\n",
                   now(), (unsigned long)d->id_base, win, nmasks);
            const unsigned char *m = p + 12;
            for (unsigned i = 0; i < nmasks; i++) {
                if ((unsigned)(m - p) + 4 > nbytes) break;
                unsigned dev = u16(m);
                unsigned mlen = u16(m + 2);         /* in 4-byte units */
                const unsigned char *bits = m + 4;
                if ((unsigned)(bits - p) + mlen * 4 > nbytes) break;
                printf("%8.3f cl=0x%08lx     dev=%u mask:", now(),
                       (unsigned long)d->id_base, dev);
                int any = 0;
                for (unsigned b = 0; b < mlen * 32; b++) {
                    if (!(bits[b / 8] & (1u << (b % 8)))) continue;
                    const char *n = xi_evname((int)b);
                    if (n) printf(" %s", n);
                    else   printf(" bit%u", b);
                    any = 1;
                }
                if (!any) printf(" (empty -- DESELECTING)");
                printf("\n");
                m = bits + mlen * 4;
            }
        } else if (minor == 47 && nbytes >= 8) {    /* XIQueryVersion */
            printf("%8.3f cl=0x%08lx XIQueryVersion wants %u.%u\n", now(),
                   (unsigned long)d->id_base, u16(p + 4), u16(p + 6));
        } else if (minor == 48 && nbytes >= 6) {    /* XIQueryDevice */
            printf("%8.3f cl=0x%08lx XIQueryDevice dev=%u\n", now(),
                   (unsigned long)d->id_base, u16(p + 4));
        } else if (minor == 51 || minor == 54) {    /* grabs */
            unsigned win = nbytes >= 8 ? u32(p + 4) : 0;
            printf("%8.3f cl=0x%08lx %s win=0x%x\n", now(),
                   (unsigned long)d->id_base, xi_reqname(minor), win);
        } else if (minor == 60) {                   /* XIGetSelectedEvents */
            printf("%8.3f cl=0x%08lx XIGetSelectedEvents win=0x%x\n", now(),
                   (unsigned long)d->id_base, nbytes >= 8 ? u32(p + 4) : 0);
        }
        goto out;
    }

    if (opcode == X_CreateWindow && nbytes >= 32) {
        unsigned wid = u32(p + 4), parent = u32(p + 8);
        unsigned vmask = u32(p + 28), ev = 0;
        int nvals = (int)((nbytes - 32) / 4);
        printf("%8.3f cl=0x%08lx CreateWindow 0x%x parent=0x%x %ux%u+%d+%d",
               now(), (unsigned long)d->id_base, wid, parent,
               u16(p + 16), u16(p + 18), (short)u16(p + 12), (short)u16(p + 14));
        if (event_mask_value(vmask, p + 32, nvals, &ev)) {
            printf(" coremask:");
            print_core_mask(ev);
        }
        printf("\n");
    } else if (opcode == X_ChangeWindowAttributes && nbytes >= 12) {
        unsigned win = u32(p + 4), vmask = u32(p + 8), ev = 0;
        int nvals = (int)((nbytes - 12) / 4);
        if (event_mask_value(vmask, p + 12, nvals, &ev)) {
            printf("%8.3f cl=0x%08lx ChangeWindowAttributes 0x%x coremask:",
                   now(), (unsigned long)d->id_base, win);
            print_core_mask(ev);
            printf("\n");
        }
    } else if (opcode == X_GrabPointer && nbytes >= 12) {
        printf("%8.3f cl=0x%08lx GrabPointer win=0x%x mask=0x%x\n", now(),
               (unsigned long)d->id_base, u32(p + 4), u16(p + 8));
    } else if (opcode == X_GrabButton && nbytes >= 24) {
        /* The button is at offset 20, after confine-to and cursor. Reading it
         * from 18 (the end of the fixed header as counted without those two
         * RESOURCEs) prints `button=0` for every grab, which reads exactly
         * like "this client grabbed every button" and is not a decode at all
         * -- caught by the self-test against Xvfb, where xterm's 24 modifier
         * variants of button 1..5 all printed 0. */
        printf("%8.3f cl=0x%08lx GrabButton win=0x%x mask=0x%x button=%u "
               "modifiers=0x%x\n",
               now(), (unsigned long)d->id_base, u32(p + 4), u16(p + 8),
               p[20], u16(p + 22));
    }
out:
    if (d) XRecordFreeData(d);
    fflush(stdout);
}

int main(int argc, char **argv)
{
    (void)argc; (void)argv;
    setvbuf(stdout, NULL, _IOLBF, 0);
    clock_gettime(CLOCK_MONOTONIC, &t0);

    Display *ctl = XOpenDisplay(NULL);
    if (!ctl) { fprintf(stderr, "rectrace: cannot open display\n"); return 2; }
    Display *dat = XOpenDisplay(NULL);
    if (!dat) { fprintf(stderr, "rectrace: cannot open 2nd display\n"); return 2; }

    int ev, err;
    if (!XQueryExtension(ctl, "XInputExtension", &xi_opcode, &ev, &err)) {
        fprintf(stderr, "rectrace: NO XInputExtension on this server\n");
        return 3;
    }
    printf("rectrace: XInputExtension major opcode %d\n", xi_opcode);

    int rmaj = 0, rmin = 0;
    if (!XRecordQueryVersion(ctl, &rmaj, &rmin)) {
        fprintf(stderr, "rectrace: NO RECORD extension on this server -- "
                        "this probe cannot answer anything here\n");
        return 4;
    }
    printf("rectrace: RECORD %d.%d\n", rmaj, rmin);

    /* Three ranges rather than one wide one: RECORD copies every byte of
     * every matching request through this process, and the XI extension plus
     * four core opcodes is a few hundred bytes a second, where "all core
     * requests" in a session with a live CEF is a firehose that changes the
     * timing of the thing being measured. */
#define NRANGE 5
    XRecordRange *rr[NRANGE];
    for (int i = 0; i < NRANGE; i++) {
        rr[i] = XRecordAllocRange();
        if (!rr[i]) { fprintf(stderr, "rectrace: out of memory\n"); return 2; }
    }
    rr[0]->core_requests.first = X_CreateWindow;
    rr[0]->core_requests.last  = X_ChangeWindowAttributes;
    rr[1]->core_requests.first = X_GrabPointer;
    rr[1]->core_requests.last  = X_GrabButton;
    rr[2]->ext_requests.ext_major.first = (unsigned char)xi_opcode;
    rr[2]->ext_requests.ext_major.last  = (unsigned char)xi_opcode;
    rr[2]->ext_requests.ext_minor.first = 0;
    rr[2]->ext_requests.ext_minor.last  = 255;
    /* Delivered events: the pointer ones and GenericEvent, which is how every
     * XI2 event arrives. Not Expose, not PropertyNotify -- a CEF session
     * repaints constantly and a firehose through this process would change the
     * timing of the thing being measured.
     *
     * ONE CONTIGUOUS RANGE, 4..35, AND NOT TWO. This was written first as
     * `delivered_events 4..6` in one XRecordRange and `35..35` in another --
     * the tight selection, since 7..34 is Enter/Leave/Expose/Property noise.
     * Against Xvfb that recorded NOTHING AT ALL while the client being watched
     * was demonstrably receiving XI_Motion and buttons 4 and 5 (its own log
     * said so in the same run). Merged into one range it works. A tracer that
     * is silent and a client that got nothing are the same log, so the
     * control that caught this -- the watched client printing what it
     * received -- is part of tests/linux/x11_record_trace_selftest.sh and not
     * an anecdote. */
    rr[3]->delivered_events.first = ButtonPress;      /* 4 */
    rr[3]->delivered_events.last  = GenericEvent;     /* 35 */
    if (!getenv("RECTRACE_NODEV")) {
        rr[4]->device_events.first = ButtonPress;
        rr[4]->device_events.last  = GenericEvent;
    }

    XRecordClientSpec cs = XRecordAllClients;
    XRecordContext rc = XRecordCreateContext(ctl, 0, &cs, 1, rr, NRANGE);
    if (!rc) {
        fprintf(stderr, "rectrace: XRecordCreateContext failed\n");
        return 5;
    }
    XSync(ctl, False);
    printf("rectrace: attached to all clients; tracing\n");
    fflush(stdout);

    if (!XRecordEnableContext(dat, rc, on_data, NULL)) {
        fprintf(stderr, "rectrace: XRecordEnableContext failed\n");
        return 6;
    }
    return 0;
}
