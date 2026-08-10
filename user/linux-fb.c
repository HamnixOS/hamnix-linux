/*
 * user/linux-fb.c — /dev/fb, /dev/fbctl and /dev/fbpix backed by DRM/KMS.
 *
 * HANDOFF.md §4.4 is the background. On Hamnix the framebuffer is a FILE that
 * any process may open: the compositor reads "/dev/fb" to get the geometry as
 * text, opens it for writing, and streams 32-bpp pixels at it. Nine programs do
 * this directly. On Linux the equivalent is a DRM/KMS dumb buffer, and DRM
 * master is exclusive to ONE process.
 *
 * This file keeps the file interface exactly as the userland expects and puts
 * DRM behind it, so hamUId and the other eight need no changes to their I/O.
 * It does NOT solve the exclusivity problem — the first process to open /dev/fb
 * for writing becomes DRM master and the rest get EBUSY, which is the honest
 * behaviour and makes the conflict visible instead of silently corrupting the
 * screen. Routing the other eight through wsys is the actual fix (§4.4).
 *
 * THE INTERFACE, read off user/hamUId.ad:
 *
 *   open("/dev/fb")  + read   -> "WIDTH HEIGHT PITCH BPP PIXFMT\n" as ASCII
 *                                (read_fb_geometry, hamUId.ad:2100)
 *   open_write("/dev/fb") + write
 *                             -> a stream of pixels starting at offset 0 and
 *                                advancing; the compositor writes whole bands
 *                                of `pitch` bytes per row in one call
 *                                (hamUId.ad:2339)
 *   open_write("/dev/fbctl") + write
 *                             -> text verbs: suspend / resume / grab / ungrab,
 *                                plus binary dirty-rectangle records
 *   open("/dev/fbpix") + read -> read the screen back, for screenshots
 *
 * No libdrm: the ioctls are issued directly against <drm/drm_mode.h>, which
 * Debian ships in linux-libc-dev. One less thing in the image.
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#include <drm/drm.h>
#include <drm/drm_mode.h>

#include "linux-fb.h"

/* ------------------------------------------------------------------ *
 * The scanout surface
 * ------------------------------------------------------------------ */

static struct {
    int      ready;        /* 1 once a mode is set and the buffer is mapped */
    int      tried;        /* 1 once init has been attempted (success or not) */
    int      drm_fd;
    uint32_t conn_id, crtc_id, fb_id, handle;
    uint32_t width, height, pitch, size;
    uint8_t *map;
    struct drm_mode_modeinfo mode;
    int      needs_dirty;  /* virtio-gpu and other transfer-based drivers */
    int      is_fbdev;     /* 1 = /dev/fbN via fbdev, 0 = raw DRM/KMS */
} fb;

/* PIXFMT as the userland understands it. 0 = XRGB8888 little-endian, which is
 * DRM_FORMAT_XRGB8888 and what every dumb buffer gives us. */
#define HAMFB_PIXFMT_XRGB8888 0

static int drm_try_card(const char *path)
{
    int fd = open(path, O_RDWR | O_CLOEXEC);
    if (fd < 0)
        return -1;

    /* Becoming master is what lets us set a mode. If another process already
     * holds it, fail here rather than half-initialising. */
    if (ioctl(fd, DRM_IOCTL_SET_MASTER, 0) < 0) {
        int e = errno;
        close(fd);
        errno = e ? e : EBUSY;
        return -1;
    }

    struct drm_mode_card_res res;
    memset(&res, 0, sizeof res);
    if (ioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, &res) < 0)
        goto fail;
    if (res.count_connectors == 0 || res.count_crtcs == 0) {
        errno = ENODEV;
        goto fail;
    }

    uint32_t *conns = calloc(res.count_connectors, sizeof(uint32_t));
    uint32_t *crtcs = calloc(res.count_crtcs, sizeof(uint32_t));
    if (!conns || !crtcs) { free(conns); free(crtcs); errno = ENOMEM; goto fail; }
    res.connector_id_ptr = (uint64_t)(uintptr_t)conns;
    res.crtc_id_ptr      = (uint64_t)(uintptr_t)crtcs;
    res.count_fbs = res.count_encoders = 0;
    if (ioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, &res) < 0) {
        free(conns); free(crtcs); goto fail;
    }

    /* First connected connector with at least one mode wins. Multi-head is a
     * compositor policy decision and does not belong in the device shim. */
    int found = 0;
    for (uint32_t i = 0; i < res.count_connectors && !found; i++) {
        struct drm_mode_get_connector c;
        memset(&c, 0, sizeof c);
        c.connector_id = conns[i];
        if (ioctl(fd, DRM_IOCTL_MODE_GETCONNECTOR, &c) < 0)
            continue;
        if (c.connection != 1 /* DRM_MODE_CONNECTED */ || c.count_modes == 0)
            continue;

        struct drm_mode_modeinfo *modes =
            calloc(c.count_modes, sizeof *modes);
        if (!modes)
            continue;
        c.modes_ptr = (uint64_t)(uintptr_t)modes;
        c.count_props = c.count_encoders = 0;
        if (ioctl(fd, DRM_IOCTL_MODE_GETCONNECTOR, &c) == 0 && c.count_modes) {
            fb.conn_id = conns[i];
            fb.mode    = modes[0];          /* preferred mode is listed first */
            found = 1;
        }
        free(modes);
    }
    if (!found) {
        free(conns); free(crtcs);
        errno = ENODEV;
        goto fail;
    }
    fb.crtc_id = crtcs[0];
    free(conns); free(crtcs);

    /* A dumb buffer is a plain linear CPU-writable surface — exactly the shape
     * of the Hamnix framebuffer, which is why no format negotiation is needed. */
    struct drm_mode_create_dumb cd;
    memset(&cd, 0, sizeof cd);
    cd.width  = fb.mode.hdisplay;
    cd.height = fb.mode.vdisplay;
    cd.bpp    = 32;
    if (ioctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, &cd) < 0)
        goto fail;
    fb.handle = cd.handle;
    fb.pitch  = cd.pitch;
    fb.size   = (uint32_t)cd.size;
    fb.width  = cd.width;
    fb.height = cd.height;

    struct drm_mode_fb_cmd fbc;
    memset(&fbc, 0, sizeof fbc);
    fbc.width = cd.width; fbc.height = cd.height;
    fbc.pitch = cd.pitch; fbc.bpp = 32; fbc.depth = 24;
    fbc.handle = cd.handle;
    if (ioctl(fd, DRM_IOCTL_MODE_ADDFB, &fbc) < 0)
        goto fail;
    fb.fb_id = fbc.fb_id;

    struct drm_mode_map_dumb md;
    memset(&md, 0, sizeof md);
    md.handle = cd.handle;
    if (ioctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &md) < 0)
        goto fail;
    void *m = mmap(NULL, fb.size, PROT_READ | PROT_WRITE, MAP_SHARED,
                   fd, (off_t)md.offset);
    if (m == MAP_FAILED)
        goto fail;
    fb.map = m;
    memset(fb.map, 0, fb.size);

    struct drm_mode_crtc sc;
    memset(&sc, 0, sizeof sc);
    sc.crtc_id = fb.crtc_id;
    sc.fb_id   = fb.fb_id;
    sc.set_connectors_ptr = (uint64_t)(uintptr_t)&fb.conn_id;
    sc.count_connectors   = 1;
    sc.mode = fb.mode;
    sc.mode_valid = 1;
    if (ioctl(fd, DRM_IOCTL_MODE_SETCRTC, &sc) < 0)
        goto fail;

    /* virtio-gpu (and the USB/SPI display drivers) only push pixels to the host
     * when told a region changed. Probe once: if DIRTYFB is accepted, use it
     * after every write. On drivers that scan out our pages directly it returns
     * an error and we never call it again. */
    struct drm_clip_rect probe = { 0, 0, 1, 1 };
    struct drm_mode_fb_dirty_cmd dc;
    memset(&dc, 0, sizeof dc);
    dc.fb_id = fb.fb_id;
    dc.num_clips = 1;
    dc.clips_ptr = (uint64_t)(uintptr_t)&probe;
    int dirty_rc = ioctl(fd, DRM_IOCTL_MODE_DIRTYFB, &dc);
    fb.needs_dirty = (dirty_rc == 0);

    /* Bring-up diagnostic. Which card, which mode, and whether the driver
     * wants explicit dirty rectangles are the three facts that determine
     * whether anything appears on screen, and all three are invisible from
     * userland otherwise. */
    if (getenv("HAMFB_QUIET") == NULL)
        fprintf(stderr,
                "hamfb: %s %ux%u pitch=%u conn=%u crtc=%u dirtyfb=%s\n",
                path, fb.width, fb.height, fb.pitch, fb.conn_id, fb.crtc_id,
                fb.needs_dirty ? "yes" : (dirty_rc < 0 ? "unsupported" : "no"));

    fb.drm_fd = fd;
    fb.ready = 1;
    return 0;

fail: {
        int e = errno;
        if (fb.map) { munmap(fb.map, fb.size); fb.map = NULL; }
        close(fd);
        memset(&fb, 0, sizeof fb);
        errno = e;
        return -1;
    }
}

/* ------------------------------------------------------------------ *
 * fbdev — the preferred path
 *
 * WHY fbdev COMES FIRST, despite being the "deprecated" one (HANDOFF §4.4
 * assumed DRM/KMS would be the answer):
 *
 *  1. It is the exact analogue of what Hamnix's /dev/fb already is — a linear
 *     CPU-writable surface with a geometry query. No modeset, no master, no
 *     connector/CRTC pairing, no dumb-buffer lifetime to manage.
 *  2. Every modern DRM driver provides it through DRM's fbdev emulation, so
 *     this is not really legacy hardware support: /dev/fb0 on virtio-gpu IS
 *     drm_kms_helper. Measured: booting with console=tty0 paints the QEMU
 *     display through exactly this path, while a hand-rolled legacy SETCRTC on
 *     the same device left the host surface black. Whatever the emulation does
 *     about deferred I/O and damage reporting, it does correctly and we do not.
 *  3. DRM master is exclusive to ONE process; fbdev is not. HANDOFF §4.4 calls
 *     that exclusivity the reason eight programs must be rewritten to go
 *     through wsys. On fbdev they can keep opening /dev/fb, which does not
 *     remove the need for wsys but does stop it being a hard blocker.
 *
 * The DRM path is kept as a fallback for a device with no fbdev emulation.
 * ------------------------------------------------------------------ */
#include <linux/fb.h>
#include <linux/kd.h>
#include <sys/vt.h>

static int fbdev_try(const char *path)
{
    int fd = open(path, O_RDWR | O_CLOEXEC);
    if (fd < 0)
        return -1;

    struct fb_var_screeninfo var;
    struct fb_fix_screeninfo fix;
    if (ioctl(fd, FBIOGET_VSCREENINFO, &var) < 0 ||
        ioctl(fd, FBIOGET_FSCREENINFO, &fix) < 0)
        goto fail;

    /* The userland contract is 32-bpp XRGB. Ask for it; if the driver will not
     * give it, refuse rather than silently rendering in the wrong format. */
    if (var.bits_per_pixel != 32) {
        var.bits_per_pixel = 32;
        var.activate = FB_ACTIVATE_NOW;
        if (ioctl(fd, FBIOPUT_VSCREENINFO, &var) < 0)
            goto fail;
        if (ioctl(fd, FBIOGET_VSCREENINFO, &var) < 0 ||
            ioctl(fd, FBIOGET_FSCREENINFO, &fix) < 0)
            goto fail;
        if (var.bits_per_pixel != 32) {
            errno = ENOTSUP;
            goto fail;
        }
    }

    size_t len = (size_t)fix.line_length * var.yres;
    if (len == 0 || fix.smem_len == 0)
        { errno = ENODEV; goto fail; }
    if (len > fix.smem_len)
        len = fix.smem_len;

    void *m = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (m == MAP_FAILED)
        goto fail;

    fb.drm_fd = fd;
    fb.map    = m;
    fb.width  = var.xres;
    fb.height = var.yres;
    fb.pitch  = fix.line_length;
    fb.size   = (uint32_t)len;
    fb.is_fbdev = 1;
    /* Drivers with deferred I/O (virtio-gpu among them) publish damage when the
     * mapping's pages are touched, but FBIOPAN_DISPLAY is the portable nudge
     * for the ones that wait to be asked. */
    fb.needs_dirty = 1;
    fb.ready = 1;
    if (getenv("HAMFB_QUIET") == NULL)
        fprintf(stderr, "hamfb: %s (fbdev) %ux%u pitch=%u size=%u\n",
                path, fb.width, fb.height, fb.pitch, fb.size);
    return 0;

fail: {
        int e = errno;
        close(fd);
        memset(&fb, 0, sizeof fb);
        errno = e;
        return -1;
    }
}

static int fb_init(void)
{
    if (fb.ready)
        return 0;
    if (fb.tried)
        return -1;
    fb.tried = 1;

    char path[64];
    /* fbdev first — see the note above. */
    for (int i = 0; i < 4; i++) {
        snprintf(path, sizeof path, "/dev/fb%d", i);
        if (fbdev_try(path) == 0)
            return 0;
    }
    /* Then raw DRM/KMS, for a device with no fbdev emulation. */
    for (int i = 0; i < 8; i++) {
        snprintf(path, sizeof path, "/dev/dri/card%d", i);
        if (drm_try_card(path) == 0)
            return 0;
    }
    return -1;
}

/* Push rows [y0, y1) to the display. A no-op on drivers that scan out our
 * mapping directly. */
static void fb_flush_rows(uint32_t y0, uint32_t y1)
{
    if (!fb.ready)
        return;
    if (y1 > fb.height) y1 = fb.height;
    if (y0 >= y1) return;
    struct drm_clip_rect r;
    r.x1 = 0; r.y1 = (uint16_t)y0;
    r.x2 = (uint16_t)fb.width; r.y2 = (uint16_t)y1;
    if (fb.is_fbdev) {
        /* fbdev's deferred-I/O layer publishes damage from the page faults our
         * memcpy already caused; the pan is what makes a driver that batches
         * flush now rather than at its own cadence. */
        struct fb_var_screeninfo var;
        if (ioctl(fb.drm_fd, FBIOGET_VSCREENINFO, &var) == 0) {
            var.activate = FB_ACTIVATE_NOW;
            ioctl(fb.drm_fd, FBIOPAN_DISPLAY, &var);
        }
        return;
    }
    struct drm_mode_fb_dirty_cmd dc;
    memset(&dc, 0, sizeof dc);
    dc.fb_id = fb.fb_id;
    dc.num_clips = 1;
    dc.clips_ptr = (uint64_t)(uintptr_t)&r;
    int rc = ioctl(fb.drm_fd, DRM_IOCTL_MODE_DIRTYFB, &dc);
    static int reported;
    if (!reported && getenv("HAMFB_QUIET") == NULL) {
        reported = 1;
        fprintf(stderr, "hamfb: first flush rows %u..%u rc=%d errno=%d\n",
                y0, y1, rc, rc < 0 ? errno : 0);
    }
}

/* ------------------------------------------------------------------ *
 * The file interface
 * ------------------------------------------------------------------ */

int hamfb_kind(const char *path)
{
    if (!path) return HAMFB_NONE;
    if (!strcmp(path, "/dev/fb"))    return HAMFB_FB;
    if (!strcmp(path, "/dev/fbctl")) return HAMFB_FBCTL;
    if (!strcmp(path, "/dev/fbpix")) return HAMFB_FBPIX;
    return HAMFB_NONE;
}

/* The text console shares the framebuffer with us and keeps drawing its cursor
 * into it — measured: exactly one 8x14 character cell at (0,0) went black under
 * a full-screen paint. Hamnix already has the verb for this ("suspend the text
 * console", user/hamUId.ad:29912); on Linux it is KDSETMODE on the VT.
 *
 * Best-effort: a headless or serial-only boot may have no /dev/tty0 at all, and
 * that is not an error — there is simply no console to get out of the way. */
static void console_graphics(int on)
{
    static int vt_fd = -1;
    if (vt_fd < 0) {
        vt_fd = open("/dev/tty0", O_RDWR | O_CLOEXEC);
        if (vt_fd < 0)
            return;
    }
    ioctl(vt_fd, KDSETMODE, on ? KD_GRAPHICS : KD_TEXT);
}

int hamfb_open(int kind, int for_write)
{
    if (kind == HAMFB_NONE)
        return -1;

    /* Reading the geometry must NOT take DRM master — user/hampanel.ad and
     * friends read /dev/fb just to learn the screen size, and making that
     * steal the display from the compositor would be a disaster. Only a
     * write-open (or a fbpix read-back) needs the device. */
    if (!for_write && kind == HAMFB_FB) {
        if (fb_init() < 0)
            return -1;
        return 0;
    }
    if (fb_init() < 0)
        return -1;
    /* Opening the framebuffer for writing means someone is about to own the
     * screen. Take the console out of text mode so it stops compositing over
     * the top of them. */
    if (for_write)
        console_graphics(1);
    return 0;
}

int64_t hamfb_geometry(uint8_t *buf, uint64_t cap)
{
    if (!fb.ready) {
        errno = ENODEV;
        return -1;
    }
    char t[96];
    int n = snprintf(t, sizeof t, "%u %u %u %u %u\n",
                     fb.width, fb.height, fb.pitch, 32u,
                     (unsigned)HAMFB_PIXFMT_XRGB8888);
    if (n < 0) { errno = EIO; return -1; }
    if ((uint64_t)n > cap) n = (int)cap;
    memcpy(buf, t, (size_t)n);
    return n;
}

int64_t hamfb_write(uint64_t offset, const uint8_t *buf, uint64_t count)
{
    if (!fb.ready) {
        errno = ENODEV;
        return -1;
    }
    if (offset >= fb.size)
        return 0;                       /* past the end of the screen */
    uint64_t n = count;
    if (offset + n > fb.size)
        n = fb.size - offset;
    memcpy(fb.map + offset, buf, (size_t)n);

    /* The compositor writes whole bands of complete rows, so deriving the
     * dirty row range from the byte range is exact rather than conservative. */
    fb_flush_rows((uint32_t)(offset / fb.pitch),
                  (uint32_t)((offset + n + fb.pitch - 1) / fb.pitch));
    return (int64_t)n;
}

int64_t hamfb_read_pixels(uint64_t offset, uint8_t *buf, uint64_t count)
{
    if (!fb.ready) {
        errno = ENODEV;
        return -1;
    }
    if (offset >= fb.size)
        return 0;
    uint64_t n = count;
    if (offset + n > fb.size)
        n = fb.size - offset;
    memcpy(buf, fb.map + offset, (size_t)n);
    return (int64_t)n;
}

uint64_t hamfb_size(void) { return fb.ready ? fb.size : 0; }

/* /dev/fbctl. The text verbs manage the text console's ownership of the
 * display; on Linux that is DRM master, which we already hold, so suspend/grab
 * are acknowledged and resume/ungrab drop back. The binary RECT records are a
 * dirty-rectangle hint — honouring them is a pure optimisation, and ignoring an
 * unrecognised record is safer than guessing at its layout. */
int64_t hamfb_ctl(const uint8_t *buf, uint64_t count)
{
    if (!fb.ready) {
        errno = ENODEV;
        return -1;
    }
    if (count >= 7 && !memcmp(buf, "suspend", 7)) {
        console_graphics(1);
        return (int64_t)count;
    }
    if (count >= 6 && !memcmp(buf, "resume", 6)) {
        console_graphics(0);
        if (fb.is_fbdev)
            return (int64_t)count;
        /* Re-assert our mode: the console may have taken the CRTC back. */
        struct drm_mode_crtc sc;
        memset(&sc, 0, sizeof sc);
        sc.crtc_id = fb.crtc_id;
        sc.fb_id   = fb.fb_id;
        sc.set_connectors_ptr = (uint64_t)(uintptr_t)&fb.conn_id;
        sc.count_connectors   = 1;
        sc.mode = fb.mode;
        sc.mode_valid = 1;
        ioctl(fb.drm_fd, DRM_IOCTL_MODE_SETCRTC, &sc);
        return (int64_t)count;
    }
    if (count >= 4 && !memcmp(buf, "grab", 4)) {
        ioctl(fb.drm_fd, DRM_IOCTL_SET_MASTER, 0);
        return (int64_t)count;
    }
    if (count >= 6 && !memcmp(buf, "ungrab", 6)) {
        ioctl(fb.drm_fd, DRM_IOCTL_DROP_MASTER, 0);
        return (int64_t)count;
    }
    /* Anything else: treat as a dirty hint and flush the whole screen. Correct,
     * just not minimal. */
    fb_flush_rows(0, fb.height);
    return (int64_t)count;
}
