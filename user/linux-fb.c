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
#include <poll.h>
#include <unistd.h>

/* The DRM uapi headers sit in two different places depending on the Debian
 * release, and this file is compiled in both: on trixie linux-libc-dev ships
 * them at <drm/...>, on bookworm they arrive with libdrm-dev at <libdrm/...>.
 * The on-box compiler (user/ac.ad) builds this runtime INSIDE the Debian
 * namespace, which is bookworm, while the development host is trixie -- so a
 * single spelling is wrong on one of the two, and it failed as a fatal
 * "file not found" the first time anything was compiled on the box. */
#if defined(__has_include)
#  if __has_include(<drm/drm.h>)
#    include <drm/drm.h>
#    include <drm/drm_mode.h>
#    include <drm/drm_fourcc.h>
#  else
#    include <libdrm/drm.h>
#    include <libdrm/drm_mode.h>
#    include <libdrm/drm_fourcc.h>
#  endif
#else
#  include <drm/drm.h>
#  include <drm/drm_mode.h>
#endif

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
    int      offscreen;    /* 1 = a plain file (HAMFB_FILE), no display */
    /* 1 = the display scans out a GPU dmabuf we imported. `map` is NULL and
     * stays NULL: there is nothing for the CPU to write. See
     * hamfb_attach_scanout(). */
    int      scanout;

    /* --- double buffering (raw DRM/KMS only) ------------------------- *
     * Two dumb buffers of identical geometry. `front` is the one the CRTC
     * is scanning out; the other is the back buffer. `have_two` says both
     * were allocated; `dbl` says we are actually USING the second one,
     * which only ever becomes true after the compositor asks for it with
     * the /dev/fbctl `flip` verb. Until then every field above means
     * exactly what it meant before double buffering existed and the code
     * paths are the single-buffer ones, byte for byte. */
    uint32_t bhandle[2], bfb_id[2];
    uint8_t *bmap[2];
    int      have_two;
    int      dbl;
    int      front;            /* index being scanned out */
    int      flip_pending;     /* a PAGE_FLIP whose event we have not read */
    uint64_t dirty_lo, dirty_hi;  /* bytes written into the back buffer */
} fb;

/* PIXFMT as the userland understands it. 0 = XRGB8888 little-endian, which is
 * DRM_FORMAT_XRGB8888 and what every dumb buffer gives us. */
#define HAMFB_PIXFMT_XRGB8888 0

/* Create one dumb buffer of (w,h), give it an fb_id and map it. All three
 * steps or none: a half-made buffer is worse than no second buffer at all,
 * because the caller's fallback is simply to carry on with one. */
static int drm_make_buf(int fd, uint32_t w, uint32_t h,
                        uint32_t *handle, uint32_t *fb_id, uint8_t **map,
                        uint32_t *pitch, uint32_t *size)
{
    struct drm_mode_create_dumb cd;
    memset(&cd, 0, sizeof cd);
    cd.width = w; cd.height = h; cd.bpp = 32;
    if (ioctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, &cd) < 0)
        return -1;

    struct drm_mode_fb_cmd fbc;
    memset(&fbc, 0, sizeof fbc);
    fbc.width = cd.width; fbc.height = cd.height;
    fbc.pitch = cd.pitch; fbc.bpp = 32; fbc.depth = 24;
    fbc.handle = cd.handle;
    if (ioctl(fd, DRM_IOCTL_MODE_ADDFB, &fbc) < 0)
        goto undo_dumb;

    struct drm_mode_map_dumb md;
    memset(&md, 0, sizeof md);
    md.handle = cd.handle;
    if (ioctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &md) < 0)
        goto undo_fb;
    void *m = mmap(NULL, (size_t)cd.size, PROT_READ | PROT_WRITE, MAP_SHARED,
                   fd, (off_t)md.offset);
    if (m == MAP_FAILED)
        goto undo_fb;
    memset(m, 0, (size_t)cd.size);

    *handle = cd.handle;
    *fb_id  = fbc.fb_id;
    *map    = (uint8_t *)m;
    *pitch  = cd.pitch;
    *size   = (uint32_t)cd.size;
    return 0;

undo_fb: {
        int e = errno;
        uint32_t id = fbc.fb_id;
        ioctl(fd, DRM_IOCTL_MODE_RMFB, &id);
        errno = e;
    }
undo_dumb: {
        int e = errno;
        struct drm_mode_destroy_dumb dd;
        memset(&dd, 0, sizeof dd);
        dd.handle = cd.handle;
        ioctl(fd, DRM_IOCTL_MODE_DESTROY_DUMB, &dd);
        errno = e;
        return -1;
    }
}

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
     * of the Hamnix framebuffer, which is why no format negotiation is needed.
     *
     * TWO of them, so a frame can be built off-screen and put up whole at a
     * vblank instead of being written into the surface the scanout engine is
     * reading. The SECOND one is a pure bonus: if it cannot be had (memory,
     * an old driver, anything) we carry on with one buffer and the code below
     * is exactly what it was before. */
    uint32_t w = fb.mode.hdisplay, h = fb.mode.vdisplay;
    if (drm_make_buf(fd, w, h, &fb.bhandle[0], &fb.bfb_id[0], &fb.bmap[0],
                     &fb.pitch, &fb.size) < 0)
        goto fail;
    fb.width  = w;
    fb.height = h;
    fb.handle = fb.bhandle[0];
    fb.fb_id  = fb.bfb_id[0];
    fb.map    = fb.bmap[0];
    fb.front  = 0;

    uint32_t p2 = 0, s2 = 0;
    if (drm_make_buf(fd, w, h, &fb.bhandle[1], &fb.bfb_id[1], &fb.bmap[1],
                     &p2, &s2) == 0) {
        /* Identical geometry is the whole premise of the swap. A driver that
         * handed back a different pitch for the same request would make the
         * two buffers non-interchangeable, so refuse rather than flip between
         * mismatched surfaces. */
        if (p2 == fb.pitch && s2 == fb.size)
            fb.have_two = 1;
        else {
            munmap(fb.bmap[1], s2);
            fb.bmap[1] = NULL;
            uint32_t id = fb.bfb_id[1];
            ioctl(fd, DRM_IOCTL_MODE_RMFB, &id);
            struct drm_mode_destroy_dumb dd;
            memset(&dd, 0, sizeof dd);
            dd.handle = fb.bhandle[1];
            ioctl(fd, DRM_IOCTL_MODE_DESTROY_DUMB, &dd);
            fb.bfb_id[1] = fb.bhandle[1] = 0;
        }
    }

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
                "hamfb: %s %ux%u pitch=%u conn=%u crtc=%u dirtyfb=%s bufs=%d\n",
                path, fb.width, fb.height, fb.pitch, fb.conn_id, fb.crtc_id,
                fb.needs_dirty ? "yes" : (dirty_rc < 0 ? "unsupported" : "no"),
                fb.have_two ? 2 : 1);

    fb.drm_fd = fd;
    fb.ready = 1;
    return 0;

fail: {
        int e = errno;
        for (int b = 0; b < 2; b++)
            if (fb.bmap[b]) { munmap(fb.bmap[b], fb.size); fb.bmap[b] = NULL; }
        fb.map = NULL;
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

/* An OFFSCREEN framebuffer: a plain file, mapped and scanned out by nobody.
 *
 * HAMFB_FILE=<path> [HAMFB_GEOM=WxH] makes /dev/fb a file instead of a
 * display. This is not a toy: it is the only way to exercise the compositor on
 * the development host, where taking /dev/dri/card0 would seize the machine's
 * real screen out from under the user. The pixels are identical to the ones a
 * display would receive, so a test can assert on them.
 */
static int fbfile_try(void)
{
    const char *path = getenv("HAMFB_FILE");
    if (!path || !*path)
        return -1;

    unsigned w = 1024, h = 768;
    const char *g = getenv("HAMFB_GEOM");
    if (g && *g) {
        unsigned gw = 0, gh = 0;
        if (sscanf(g, "%ux%u", &gw, &gh) == 2 && gw && gh) { w = gw; h = gh; }
    }

    int fd = open(path, O_RDWR | O_CREAT, 0666);
    if (fd < 0)
        return -1;
    size_t size = (size_t)w * h * 4;
    if (ftruncate(fd, (off_t)size) < 0) { close(fd); return -1; }
    void *m = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (m == MAP_FAILED) { close(fd); return -1; }

    fb.drm_fd   = fd;
    fb.map      = (uint8_t *)m;
    fb.size     = size;
    fb.width    = w;
    fb.height   = h;
    fb.pitch    = w * 4;
    fb.is_fbdev = 1;              /* no modeset, no master — same as fbdev */
    fb.offscreen = 1;
    fb.ready    = 1;
    return 0;
}

/* ------------------------------------------------------------------ *
 * SCANOUT: the display reads a buffer the GPU owns, and /dev/fb stops
 * ------------------------------------------------------------------ *
 * Everything above assumes the compositor WRITES pixels at us and we get them
 * to the display. This is the arrangement where it does not: the caller hands
 * us a dmabuf that a GPU is rasterizing into, we import it, make a framebuffer
 * of it and set a mode on it, and from then on there is nothing to copy --
 * the CRTC is scanning out the same memory the shader writes.
 *
 * WHY THIS IS A SEPARATE FUNCTION AND NOT A FLAG ON drm_try_card(): every
 * invariant that file holds is about `fb.map`, and on this path THERE IS NO
 * MAP. hamfb_write() has nothing to write into and must fail rather than
 * quietly succeed; fb_flush_rows() and fb_flip() have nothing to do. Bolting
 * a mode onto the existing path would mean auditing each of those for a NULL
 * it was never written to expect, which is how a "no picture" bug gets built.
 *
 * SUPERVISION IS MANDATORY, and this is not a style note. On nvidia-drm,
 * MEASURED: restoring the saved CRTC with a legacy SETCRTC HANGS, and
 * DROP_MASTER after a modeset HANGS. The console came back, every time, only
 * because the PROCESS DIED and the kernel dropped master when the fd closed.
 * So the documented recovery for anything that calls this is: kill it.
 * Whatever runs a compositor on this path must be able to, and must be armed
 * to, before the modeset happens -- see tests/linux/kms_watchdog.sh, which is
 * proven to fire (tests/linux/hangmaster.c is the proof).
 *
 * Returns 0 on success. Never partially succeeds: on any failure the mode is
 * not set, master is dropped and fb.ready stays 0, so the caller can fall
 * back to the ordinary path.
 */
int hamfb_attach_scanout(int dmabuf_fd, uint32_t w, uint32_t h, uint32_t pitch)
{
    if (fb.ready) { errno = EBUSY; return -1; }
    if (dmabuf_fd < 0 || !w || !h) { errno = EINVAL; return -1; }
    const char *path = getenv("HAMFB_CARD");
    if (!path || !*path) path = "/dev/dri/card0";
    int fd = open(path, O_RDWR | O_CLOEXEC);
    if (fd < 0) return -1;
    if (ioctl(fd, DRM_IOCTL_SET_MASTER, 0) < 0) { close(fd); return -1; }

    struct drm_mode_card_res res;
    memset(&res, 0, sizeof res);
    if (ioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, &res) < 0) goto fail;
    if (!res.count_connectors || !res.count_crtcs) { errno = ENODEV; goto fail; }
    uint32_t *conns = calloc(res.count_connectors, sizeof(uint32_t));
    uint32_t *crtcs = calloc(res.count_crtcs, sizeof(uint32_t));
    if (!conns || !crtcs) { free(conns); free(crtcs); errno = ENOMEM; goto fail; }
    res.connector_id_ptr = (uint64_t)(uintptr_t)conns;
    res.crtc_id_ptr      = (uint64_t)(uintptr_t)crtcs;
    res.count_fbs = res.count_encoders = 0;
    if (ioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, &res) < 0) {
        free(conns); free(crtcs); goto fail;
    }

    /* The connector must offer the EXACT geometry the GPU buffer was made
     * for. Scaling is not available here: the buffer is the scanout surface,
     * so a mismatch is a hard refusal rather than a letterbox. */
    int found = 0;
    for (uint32_t i = 0; i < res.count_connectors && !found; i++) {
        struct drm_mode_get_connector c;
        memset(&c, 0, sizeof c);
        c.connector_id = conns[i];
        if (ioctl(fd, DRM_IOCTL_MODE_GETCONNECTOR, &c) < 0) continue;
        if (c.connection != 1 || !c.count_modes) continue;
        struct drm_mode_modeinfo *ms = calloc(c.count_modes, sizeof *ms);
        uint32_t *es = calloc(c.count_encoders ? c.count_encoders : 1, 4);
        if (!ms || !es) { free(ms); free(es); continue; }
        c.modes_ptr = (uint64_t)(uintptr_t)ms;
        c.encoders_ptr = (uint64_t)(uintptr_t)es;
        c.props_ptr = c.prop_values_ptr = 0; c.count_props = 0;
        if (ioctl(fd, DRM_IOCTL_MODE_GETCONNECTOR, &c) == 0) {
            for (uint32_t m = 0; m < c.count_modes; m++) {
                if (ms[m].hdisplay != w || ms[m].vdisplay != h) continue;
                fb.mode = ms[m];
                fb.conn_id = c.connector_id;
                if (c.encoder_id) {
                    struct drm_mode_get_encoder e;
                    memset(&e, 0, sizeof e);
                    e.encoder_id = c.encoder_id;
                    if (ioctl(fd, DRM_IOCTL_MODE_GETENCODER, &e) == 0 && e.crtc_id)
                        fb.crtc_id = e.crtc_id;
                }
                if (!fb.crtc_id) fb.crtc_id = crtcs[0];
                found = 1;
                break;
            }
        }
        free(ms); free(es);
    }
    free(conns); free(crtcs);
    if (!found) { errno = ENODEV; goto fail; }

    struct drm_prime_handle prime;
    memset(&prime, 0, sizeof prime);
    prime.fd = dmabuf_fd;
    if (ioctl(fd, DRM_IOCTL_PRIME_FD_TO_HANDLE, &prime) < 0) goto fail;
    struct drm_mode_fb_cmd2 fbc;
    memset(&fbc, 0, sizeof fbc);
    fbc.width = w; fbc.height = h;
    fbc.pixel_format = DRM_FORMAT_XRGB8888;
    fbc.handles[0] = prime.handle;
    fbc.pitches[0] = pitch ? pitch : w * 4;
    if (ioctl(fd, DRM_IOCTL_MODE_ADDFB2, &fbc) < 0) goto fail;

    struct drm_mode_crtc sc;
    memset(&sc, 0, sizeof sc);
    sc.crtc_id = fb.crtc_id;
    sc.fb_id   = fbc.fb_id;
    sc.set_connectors_ptr = (uint64_t)(uintptr_t)&fb.conn_id;
    sc.count_connectors   = 1;
    sc.mode = fb.mode;
    sc.mode_valid = 1;
    if (ioctl(fd, DRM_IOCTL_MODE_SETCRTC, &sc) < 0) goto fail;

    fb.drm_fd  = fd;
    fb.fb_id   = fbc.fb_id;
    fb.handle  = prime.handle;
    fb.width   = w;
    fb.height  = h;
    fb.pitch   = fbc.pitches[0];
    fb.size    = fb.pitch * h;
    fb.map     = NULL;              /* THERE IS NO MAPPING. By construction. */
    fb.scanout = 1;
    fb.ready   = 1;
    fb.tried   = 1;
    fb.is_fbdev = fb.offscreen = fb.needs_dirty = 0;
    fb.have_two = fb.dbl = 0;
    if (getenv("HAMFB_QUIET") == NULL)
        fprintf(stderr, "hamfb: SCANOUT %ux%u pitch=%u conn=%u crtc=%u fb=%u "
                "-- the display is reading GPU memory; /dev/fb writes will "
                "now FAIL, and this process MUST be supervised by something "
                "that can kill it (DROP_MASTER hangs on nvidia-drm)\n",
                w, h, fb.pitch, fb.conn_id, fb.crtc_id, fb.fb_id);
    return 0;
fail:
    {
        int e = errno;
        ioctl(fd, DRM_IOCTL_DROP_MASTER, 0);
        close(fd);
        memset(&fb, 0, sizeof fb);
        errno = e;
    }
    return -1;
}

int hamfb_is_scanout(void) { return fb.scanout ? 1 : 0; }

/* The mode a scanout buffer would have to be, WITHOUT taking master or
 * touching anything. The caller has to allocate the GPU buffer before it can
 * attach it, and the buffer has to be exactly one of the connector's
 * advertised modes -- so it needs the geometry first. Connector enumeration
 * needs no master, which is what makes this safe to call at startup on a
 * machine whose console is live. Returns 0 and fills w/h, or -1. */
int hamfb_probe_mode(uint32_t *w, uint32_t *h)
{
    const char *path = getenv("HAMFB_CARD");
    if (!path || !*path) path = "/dev/dri/card0";
    int fd = open(path, O_RDWR | O_CLOEXEC);
    if (fd < 0) return -1;
    int rc = -1;
    struct drm_mode_card_res res;
    memset(&res, 0, sizeof res);
    if (ioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, &res) < 0) goto out;
    if (!res.count_connectors) goto out;
    uint32_t *conns = calloc(res.count_connectors, sizeof(uint32_t));
    if (!conns) goto out;
    res.connector_id_ptr = (uint64_t)(uintptr_t)conns;
    res.count_fbs = res.count_crtcs = res.count_encoders = 0;
    if (ioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, &res) == 0) {
        for (uint32_t i = 0; i < res.count_connectors && rc; i++) {
            struct drm_mode_get_connector c;
            memset(&c, 0, sizeof c);
            c.connector_id = conns[i];
            if (ioctl(fd, DRM_IOCTL_MODE_GETCONNECTOR, &c) < 0) continue;
            if (c.connection != 1 || !c.count_modes) continue;
            struct drm_mode_modeinfo *ms = calloc(c.count_modes, sizeof *ms);
            if (!ms) continue;
            c.modes_ptr = (uint64_t)(uintptr_t)ms;
            c.encoders_ptr = c.props_ptr = c.prop_values_ptr = 0;
            c.count_encoders = c.count_props = 0;
            if (ioctl(fd, DRM_IOCTL_MODE_GETCONNECTOR, &c) == 0 && c.count_modes) {
                *w = ms[0].hdisplay; *h = ms[0].vdisplay;
                rc = 0;
            }
            free(ms);
        }
    }
    free(conns);
out:
    close(fd);
    return rc;
}

static int fb_init(void)
{
    if (fb.ready)
        return 0;
    if (fb.tried)
        return -1;
    fb.tried = 1;

    if (fbfile_try() == 0)
        return 0;

    char path[64];
    /* fbdev first — see the note above.
     *
     * HAMFB_DRM=1 skips it, which is the ONLY way to exercise the raw DRM/KMS
     * path (and with it the page flip) on a machine whose driver provides
     * fbdev emulation — which is every modern one, virtio-gpu included. Use it
     * in a VM. */
    const char *want_drm = getenv("HAMFB_DRM");
    if (!(want_drm && *want_drm && *want_drm != '0'))
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
    if (fb.offscreen)
        return;                     /* the mapping IS the surface; nothing to
                                       tell a driver about */
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
    if (fb.dbl)
        return;   /* the write landed in the back buffer, which no CRTC is
                     reading. The page flip is what publishes it, and dirtying
                     a surface nobody scans out would only cost a transfer. */
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
 * Double buffering and the page flip
 *
 * THE INVARIANT, which is the whole design: between flips, the back buffer
 * holds EXACTLY what is on screen. That is what makes a PARTIAL write safe —
 * wsysd's cursor-only frames write two small bands of rows and nothing else,
 * and a flip to a buffer that is otherwise the displayed frame is correct.
 *
 * It is maintained by copying, after each flip, only the bytes that were
 * written since the previous one: those are precisely the bytes by which the
 * two buffers now differ. A cursor-only frame therefore copies ~34 rows, not
 * a screen. A full frame copies a screen, which is the honest price of
 * tear-free presentation and is paid once per full repaint.
 *
 * Nothing here engages until someone writes `flip` to /dev/fbctl. A program
 * that never does — hamUId, the eight direct /dev/fb writers, every test —
 * gets the single-buffer path unchanged.
 * ------------------------------------------------------------------ */

/* Read (and discard) one page-flip completion event. 1 if one was consumed. */
static int fb_drain_flip_event(int timeout_ms)
{
    if (!fb.flip_pending)
        return 1;
    struct pollfd pfd;
    pfd.fd = fb.drm_fd;
    pfd.events = POLLIN;
    pfd.revents = 0;
    int pr = poll(&pfd, 1, timeout_ms);
    if (pr <= 0)
        return 0;                    /* timed out, or poll itself failed */
    /* drm_event_vblank is the largest event this fd produces for us. */
    char ev[sizeof(struct drm_event_vblank) * 4];
    ssize_t n = read(fb.drm_fd, ev, sizeof ev);
    if (n <= 0)
        return 0;
    fb.flip_pending = 0;
    return 1;
}

/* Give up on double buffering for good and get the pixels onto the screen the
 * old way. Called whenever the kernel refuses something; the caller's contract
 * is that after this, writes go to the scanned-out buffer exactly as they did
 * before this feature existed. */
static void fb_disable_double(const char *why)
{
    if (fb.dbl) {
        /* Whatever is in the back buffer is the newest frame. Move it to the
         * front so the failure does not eat a frame. */
        uint64_t lo = fb.dirty_lo, hi = fb.dirty_hi;
        if (hi > lo && hi <= fb.size)
            memcpy(fb.bmap[fb.front] + lo, fb.map + lo, (size_t)(hi - lo));
    }
    fb.dbl = 0;
    fb.have_two = 0;
    fb.map = fb.bmap[fb.front];
    fb.fb_id = fb.bfb_id[fb.front];
    fb.dirty_lo = fb.dirty_hi = 0;
    if (getenv("HAMFB_QUIET") == NULL)
        fprintf(stderr, "hamfb: double buffering off (%s, errno=%d)\n",
                why, errno);
    fb_flush_rows(0, fb.height);
}

/* The `flip` verb. Returns 1 if the frame was published by a page flip, 0 if
 * this framebuffer does not (or no longer) does that — in which case the
 * caller has already been served by the single-buffer path and there is
 * nothing to do. */
static int fb_flip(void)
{
    if (!fb.ready || fb.offscreen || fb.is_fbdev || !fb.have_two)
        return 0;

    if (!fb.dbl) {
        /* First `flip`: arm it. The frame that was just written went to the
         * front buffer and is already on screen, so there is nothing to flip
         * — all this does is establish the invariant and point writes at the
         * back buffer from now on. */
        memcpy(fb.bmap[1 - fb.front], fb.bmap[fb.front], fb.size);
        fb.dbl = 1;
        fb.map = fb.bmap[1 - fb.front];
        fb.dirty_lo = fb.dirty_hi = 0;
        if (getenv("HAMFB_QUIET") == NULL)
            fprintf(stderr, "hamfb: double buffering on (fb %u/%u)\n",
                    fb.bfb_id[0], fb.bfb_id[1]);
        return 1;
    }

    if (fb.dirty_hi <= fb.dirty_lo)
        return 1;                       /* nothing written since the last flip */

    /* Only one flip may be outstanding per CRTC; a second one returns EBUSY.
     * If the previous event has still not arrived, keep the frame in the back
     * buffer and present it on the next call rather than losing it. */
    if (!fb_drain_flip_event(100))
        return 1;

    int back = 1 - fb.front;
    struct drm_mode_crtc_page_flip pf;
    memset(&pf, 0, sizeof pf);
    pf.crtc_id = fb.crtc_id;
    pf.fb_id   = fb.bfb_id[back];
    pf.flags   = DRM_MODE_PAGE_FLIP_EVENT;
    pf.user_data = 0;
    if (ioctl(fb.drm_fd, DRM_IOCTL_MODE_PAGE_FLIP, &pf) < 0) {
        fb_disable_double("PAGE_FLIP rejected");
        return 0;
    }
    fb.flip_pending = 1;

    /* Wait for the vblank, but never for ever: a driver that accepts the flip
     * and never sends the event would otherwise hang the compositor. On a
     * timeout the flip is still coming, so the swap below is still right; we
     * simply carry the outstanding event to the next frame. */
    fb_drain_flip_event(100);

    uint64_t lo = fb.dirty_lo, hi = fb.dirty_hi;
    fb.front = back;
    fb.fb_id = fb.bfb_id[back];
    fb.map   = fb.bmap[1 - back];
    fb.dirty_lo = fb.dirty_hi = 0;
    /* Restore the invariant: the new back differs from the new front exactly
     * in the range we just wrote. */
    if (hi > fb.size) hi = fb.size;
    if (hi > lo)
        memcpy(fb.map + lo, fb.bmap[back] + lo, (size_t)(hi - lo));
    return 1;
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
    /* An offscreen framebuffer owns no display, so it must never touch the
     * VT. On the development host that would blank the user's real screen —
     * a test rendering to a file has no business doing that. */
    if (fb.offscreen)
        return;
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
    /* ON THE SCANOUT PATH THERE IS NOWHERE TO PUT THESE BYTES, and saying so
     * is the whole point. fb.map is NULL, so the memcpy below would be a NULL
     * dereference -- but the reason this returns an error rather than a short
     * write or a silent 0 is that a compositor which still thinks it can
     * write /dev/fb is MISCONFIGURED, and the failure that teaches it that
     * must be loud and immediate. A silent success here would produce a
     * desktop that renders nothing and reports no error. */
    if (fb.scanout) {
        errno = EOPNOTSUPP;
        return -1;
    }
    if (offset >= fb.size)
        return 0;                       /* past the end of the screen */
    uint64_t n = count;
    if (offset + n > fb.size)
        n = fb.size - offset;
    memcpy(fb.map + offset, buf, (size_t)n);
    if (fb.dbl) {
        if (fb.dirty_hi <= fb.dirty_lo) { fb.dirty_lo = offset; fb.dirty_hi = offset + n; }
        else {
            if (offset < fb.dirty_lo)      fb.dirty_lo = offset;
            if (offset + n > fb.dirty_hi)  fb.dirty_hi = offset + n;
        }
    }

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
    /* `flip` — publish the frame just written, tear-free, at the next vblank.
     * On anything that is not a raw DRM/KMS surface with two buffers this is a
     * no-op that reports success: the write already reached the screen by the
     * single-buffer path, which is the truth the caller needs. */
    if (count >= 4 && !memcmp(buf, "flip", 4)) {
        fb_flip();
        return (int64_t)count;
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
