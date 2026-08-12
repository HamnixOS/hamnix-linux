/* tests/linux/xi2_scroll_probe.c — WHAT AN XINPUT2 CLIENT SEES OF THE WHEEL.
 *
 * WHY THIS EXISTS AND `xev` IS NOT ENOUGH. `xev` reports CORE X events, and a
 * core X wheel is ButtonPress on button 4/5. Chromium — which is Steam's whole
 * user interface, and Firefox's fallback — does not read core pointer events at
 * all: it calls XISelectEvents and reads the wheel off an XInput2 SCROLL
 * VALUATOR. Those are two different paths through the same X server, fed from
 * the same wl_pointer.axis, and one of them can be dead while the other works.
 * A gate that only ever asks `xev` cannot tell the difference, and "the gate is
 * green and Steam still does not scroll" is exactly what that blind spot looks
 * like from outside.
 *
 * WHAT IT PRINTS, one line per event, so a shell can count them:
 *
 *   XI2 button <n>              an XI_ButtonPress (4 = wheel up, 5 = down)
 *   XI2 scroll <axis> <delta>   a scroll VALUATOR moved, in the valuator's
 *                               own units, sign as the server reported it
 *   XI2 motion                  a plain pointer motion with no scroll in it
 *
 * It selects on the ROOT window, so it needs no window of its own and sees
 * everything the pointer does anywhere on the screen. stdout is line-buffered
 * on purpose: this is read live out of a file by a test.
 *
 * cc -o xi2_scroll_probe xi2_scroll_probe.c -lX11 -lXi
 */
#include <X11/Xlib.h>
#include <X11/extensions/XInput2.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Per-(device,valuator) last value. XI2 reports scroll valuators as a running
 * total, not a delta, so the first report of a valuator establishes a baseline
 * and is not a scroll -- printing it as one would turn "the wheel is dead" into
 * a passing test the first time a client happened to see a valuator at all. */
#define MAXDEV 64
#define MAXVAL 16
static int   have[MAXDEV][MAXVAL];
static double last[MAXDEV][MAXVAL];

/* Which valuators on this device are SCROLL valuators, learned from
 * XIScrollClass in the device description. A pointer's x and y are valuators
 * too and they move on every motion; counting those as scroll would make the
 * control pass the wheel's assertion. */
static int is_scroll[MAXDEV][MAXVAL];

static void learn_devices(Display *dpy)
{
    int ndev = 0;
    XIDeviceInfo *info = XIQueryDevice(dpy, XIAllDevices, &ndev);
    if (!info) return;
    for (int i = 0; i < ndev; i++) {
        int id = info[i].deviceid;
        if (id < 0 || id >= MAXDEV) continue;
        for (int c = 0; c < info[i].num_classes; c++) {
            if (info[i].classes[c]->type != XIScrollClass) continue;
            XIScrollClassInfo *s = (XIScrollClassInfo *)info[i].classes[c];
            if (s->number >= 0 && s->number < MAXVAL) {
                is_scroll[id][s->number] = 1;
                printf("XI2 have-scroll-valuator dev %d valuator %d type %s\n",
                       id, s->number,
                       s->scroll_type == XIScrollTypeVertical ? "vertical"
                                                              : "horizontal");
            }
        }
    }
    XIFreeDeviceInfo(info);
}

/* argv: x y w h -- where to put this probe's own window. */
int main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IOLBF, 0);
    int wx = argc > 1 ? atoi(argv[1]) : 100;
    int wy = argc > 2 ? atoi(argv[2]) : 100;
    int ww = argc > 3 ? atoi(argv[3]) : 500;
    int wh = argc > 4 ? atoi(argv[4]) : 400;
    Display *dpy = XOpenDisplay(NULL);
    if (!dpy) { fprintf(stderr, "xi2probe: cannot open display\n"); return 1; }

    int xi_op, ev, err;
    if (!XQueryExtension(dpy, "XInputExtension", &xi_op, &ev, &err)) {
        fprintf(stderr, "xi2probe: no XInputExtension on this server\n");
        return 1;
    }
    int major = 2, minor = 2;
    if (XIQueryVersion(dpy, &major, &minor) != Success) {
        fprintf(stderr, "xi2probe: server does not speak XI2\n");
        return 1;
    }
    printf("XI2 version %d.%d\n", major, minor);
    learn_devices(dpy);

    /* ITS OWN WINDOW, and the XI2 selection is on THAT -- not on the root.
     * This is the shape Chromium uses, and it is not interchangeable with a
     * root selection: an XI2 event is delivered along the window stack under
     * the pointer, so a root-only selection answers differently from a client
     * that actually owns the rectangle being pointed at. The probe must be the
     * same shape as the program whose scrolling is in question. */
    Window w = XCreateSimpleWindow(dpy, DefaultRootWindow(dpy), wx, wy, ww, wh,
                                   0, 0, 0x303030);
    /* CORE events on the SAME window, so the two paths are compared at the
     * same pixel in the same run. "the wheel works" measured on one window and
     * "the wheel is dead" measured on another is not a comparison. */
    XSelectInput(dpy, w, ButtonPressMask | ButtonReleaseMask |
                         PointerMotionMask | ExposureMask);
    XMapWindow(dpy, w);

    unsigned char mask[XIMaskLen(XI_LASTEVENT)];
    memset(mask, 0, sizeof mask);
    XISetMask(mask, XI_Motion);
    XISetMask(mask, XI_ButtonPress);
    XISetMask(mask, XI_ButtonRelease);
    XISetMask(mask, XI_Enter);
    XIEventMask em = { .deviceid = XIAllMasterDevices,
                       .mask_len = sizeof mask, .mask = mask };
    XISelectEvents(dpy, w, &em, 1);
    XSync(dpy, False);
    printf("XI2 screen %dx%d\n", DisplayWidth(dpy, DefaultScreen(dpy)),
           DisplayHeight(dpy, DefaultScreen(dpy)));
    printf("XI2 selected on window %lu at %d,%d %dx%d\n",
           (unsigned long)w, wx, wy, ww, wh);

    for (;;) {
        XEvent xev;
        XNextEvent(dpy, &xev);
        if (xev.type == ButtonPress) {
            printf("CORE button %d\n", xev.xbutton.button);
            continue;
        }
        if (xev.type == MotionNotify) { printf("CORE motion\n"); continue; }
        XGenericEventCookie *ck = &xev.xcookie;
        if (ck->type != GenericEvent || ck->extension != xi_op) continue;
        if (!XGetEventData(dpy, ck)) continue;

        if (ck->evtype == XI_Enter) {
            printf("XI2 enter\n");
        } else if (ck->evtype == XI_ButtonPress) {
            XIDeviceEvent *de = ck->data;
            printf("XI2 button %d\n", de->detail);
        } else if (ck->evtype == XI_Motion) {
            XIDeviceEvent *de = ck->data;
            /* sourceid, NOT deviceid. An XI2 event selected on
             * XIAllMasterDevices carries the MASTER's id in `deviceid`, and
             * the scroll classes are declared by the SLAVE that generated it
             * -- so a table keyed by deviceid is empty for every event that
             * ever arrives, and every scroll reads as a plain motion. That is
             * a probe that reports "the wheel is dead" no matter what the
             * server does, which is the one answer a gate must never give. */
            int id = de->sourceid;
            int scrolled = 0;
            if (id >= 0 && id < MAXDEV) {
                double *v = de->valuators.values;
                for (int i = 0; i < de->valuators.mask_len * 8 && i < MAXVAL; i++) {
                    if (!XIMaskIsSet(de->valuators.mask, i)) continue;
                    double val = *v++;
                    if (!is_scroll[id][i]) continue;
                    if (have[id][i]) {
                        double d = val - last[id][i];
                        if (d != 0.0) {
                            printf("XI2 scroll %d %.3f\n", i, d);
                            scrolled = 1;
                        }
                    }
                    have[id][i] = 1;
                    last[id][i] = val;
                }
            }
            if (!scrolled) printf("XI2 motion\n");
        }
        XFreeEventData(dpy, ck);
    }
    return 0;
}
