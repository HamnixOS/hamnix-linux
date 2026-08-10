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

#endif
