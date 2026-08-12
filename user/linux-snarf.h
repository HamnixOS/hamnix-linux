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
#define HAMSNARF_SERIAL   3     /* /dev/snarf.serial   — the generation counters */

/* /dev/snarf.serial reads as ONE fixed-width line and nothing else:
 *
 *     "%20llu %20llu\n"        clip_serial, then prim_serial
 *
 * 42 bytes, always, so a reader may size a buffer once.  Read-only: an open
 * for writing fails EPERM rather than accepting bytes nobody will ever read.
 */
#define HAMSNARF_SERIAL_LINE 42

/* The 64 KiB cap, the same number as lib/devsnarf.ad's SNARF_MAX.  It is the
 * property two ordinary files in a RAM-backed /dev cannot give. */
#define HAMSNARF_MAX      65536

/* Per-open state.  No pointers, so devtab_clone's `*slot = *src` is a correct
 * deep copy and dup(2)/dup2(2) need no special case here. */
struct hamsnarf_file {
    int      which;             /* HAMSNARF_CLIP, _PRIMARY or _SERIAL */
    int      write;             /* opened for writing */
    uint64_t off;               /* the offset-addressed cursor */
    /* HAMSNARF_SERIAL only.  `wfd` is a real inotify(7) descriptor watching
     * the segment file, so sys_waitfds can PARK on the clipboard instead of
     * looking at it on a clock; `line` is the snapshot a read at offset 0
     * takes, so a chunked reader cannot straddle two samples. */
    int      wfd;
    char     line[48];
    uint64_t linelen;
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

/* The real, pollable descriptor behind an open of /dev/snarf.serial, or -1 for
 * every other open.  devtab_open hands this back as the caller's fd so a
 * clipboard is a thing an event loop can WAIT on, and sys_waitfds polls it
 * instead of counting a synthetic device always-ready. */
int     hamsnarf_waitfd(const struct hamsnarf_file *f);

#endif /* HAMNIX_LINUX_SNARF_H */
