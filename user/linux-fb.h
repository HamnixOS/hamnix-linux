/* user/linux-fb.h — the seam between the syscall runtime and the DRM/KMS
 * framebuffer. See user/linux-fb.c for what these mean. */
#ifndef HAMNIX_LINUX_FB_H
#define HAMNIX_LINUX_FB_H

#include <stdint.h>

enum {
    HAMFB_NONE = 0,
    HAMFB_FB,       /* /dev/fb    — geometry on read, pixels on write */
    HAMFB_FBCTL,    /* /dev/fbctl — console-ownership verbs, dirty rects */
    HAMFB_FBPIX,    /* /dev/fbpix — screen read-back, for screenshots */
};

int      hamfb_kind(const char *path);
int      hamfb_open(int kind, int for_write);
int64_t  hamfb_geometry(uint8_t *buf, uint64_t cap);
int64_t  hamfb_write(uint64_t offset, const uint8_t *buf, uint64_t count);
int64_t  hamfb_read_pixels(uint64_t offset, uint8_t *buf, uint64_t count);
int64_t  hamfb_ctl(const uint8_t *buf, uint64_t count);
uint64_t hamfb_size(void);

/* SCANOUT. Import a GPU dmabuf, make a framebuffer of it and set a mode, so
 * the display reads the memory the GPU rasterizes into and nothing is ever
 * copied. After this succeeds hamfb_write() FAILS with EOPNOTSUPP -- there is
 * no mapping to write into, by construction.
 *
 * The caller MUST be supervised by something that can kill it: on nvidia-drm,
 * measured, both the CRTC restore and DROP_MASTER hang after a modeset, and
 * the console only comes back when the process dies and the kernel drops
 * master with the fd. See user/linux-fb.c and tests/linux/kms_watchdog.sh. */
int      hamfb_attach_scanout(int dmabuf_fd, uint32_t w, uint32_t h,
                              uint32_t pitch);
int      hamfb_is_scanout(void);
/* Microseconds per displayed frame, from the mode actually set, or 0 meaning
 * "do not pace" -- offscreen (HAMFB_FILE), fbdev, or no usable timing. */
int32_t  hamfb_frame_us(void);
/* The geometry a scanout buffer must have. Takes no master, sets no mode. */
int      hamfb_probe_mode(uint32_t *w, uint32_t *h);

#endif
