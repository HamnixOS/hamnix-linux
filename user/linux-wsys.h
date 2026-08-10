/* user/linux-wsys.h — the seam between the syscall runtime and the window
 * system device.  See user/linux-wsys.c for what these mean.
 *
 * This is the Linux port of sys/src/9/port/devwsys.ad.  In Hamnix that is
 * KERNEL code: the window table, the per-window scene buffers and the event
 * rings live in kernel memory, and both the clients and the compositor poke
 * the same storage through /dev/wsys.  The faithful port of shared kernel
 * memory is shared memory — not an RPC server — so that is what this is.
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
    HAMWSYS_DIR,          /* /dev/wsys, /dev/wsys/<wid> — directory listing  */
    HAMWSYS_WIN_CTL,      /* /dev/wsys/<wid>/ctl                             */
    HAMWSYS_WIN_SCENE,    /* /dev/wsys/<wid>/scene                           */
    HAMWSYS_WIN_KEYS,     /* /dev/wsys/<wid>/keys                            */
    HAMWSYS_WIN_POINTER,  /* /dev/wsys/<wid>/pointer                         */
    HAMWSYS_WIN_EVENT,    /* /dev/wsys/<wid>/event                           */
    HAMWSYS_WIN_TEXT,     /* /dev/wsys/<wid>/text                            */
    HAMWSYS_WIN_CMD,      /* /dev/wsys/<wid>/cmd                             */
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

/* The two syscalls hamUI uses to bind a spawned task to a window. */
int32_t hamwsys_alloc(uint64_t pid);
int32_t hamwsys_free(int32_t wid);

#endif
