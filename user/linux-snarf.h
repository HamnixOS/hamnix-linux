/* user/linux-snarf.h — /dev/snarf and /dev/snarf.primary, the clipboard
 * device.  The port of Hamnix's sys/src/9/port/devsnarf.ad onto a shared
 * memory segment, in the shape every other device on this line already has
 * (linux-fb.h, linux-wsys.h, linux-auth.h, linux-audio.h).
 *
 * See the long design note at the top of user/linux-snarf.c for WHY this is a
 * served device and not two ordinary files, which was the cheaper answer.
 */
#ifndef HAMNIX_LINUX_SNARF_H
#define HAMNIX_LINUX_SNARF_H

#include <stdint.h>

#define HAMSNARF_NONE     0
#define HAMSNARF_CLIP     1     /* /dev/snarf          — the CLIPBOARD */
#define HAMSNARF_PRIMARY  2     /* /dev/snarf.primary  — the PRIMARY selection */

/* The 64 KiB cap, the same number as lib/devsnarf.ad's SNARF_MAX.  It is the
 * property two ordinary files in a RAM-backed /dev cannot give. */
#define HAMSNARF_MAX      65536

/* Per-open state.  No pointers, so devtab_clone's `*slot = *src` is a correct
 * deep copy and dup(2)/dup2(2) need no special case here. */
struct hamsnarf_file {
    int      which;             /* HAMSNARF_CLIP or HAMSNARF_PRIMARY */
    int      write;             /* opened for writing */
    uint64_t off;               /* the offset-addressed cursor */
};

/* HAMSNARF_* for a path this device serves, HAMSNARF_NONE otherwise. */
int     hamsnarf_kind(const char *path);

/* Attach the segment and fill `f`.  0 on success, -1 with errno set. */
int     hamsnarf_open(const char *path, int for_write, struct hamsnarf_file *f);

int64_t hamsnarf_read(struct hamsnarf_file *f, uint8_t *buf, uint64_t count);
int64_t hamsnarf_write(struct hamsnarf_file *f, const uint8_t *buf,
                       uint64_t count);
/* whence: 0 = SET, 1 = CUR, 2 = END.  Returns the new offset, or -EINVAL. */
int64_t hamsnarf_seek(struct hamsnarf_file *f, int64_t off, int whence);
void    hamsnarf_close(struct hamsnarf_file *f);

/* The segment this process joined, for tests and diagnostics.  NULL before
 * the first successful open. */
const char *hamsnarf_segment(void);

#endif /* HAMNIX_LINUX_SNARF_H */
