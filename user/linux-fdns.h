/* user/linux-fdns.h — the /fd name space: Plan 9's file descriptors as NAMES.
 * See user/linux-fdns.c. */
#ifndef HAMNIX_LINUX_FDNS_H
#define HAMNIX_LINUX_FDNS_H

#include <stdint.h>

/* lib/p9.ad's P9_DEVFD_* — the kind of thing a /fd/N name is bound to. */
enum {
    FDNS_NONE   = 0,
    FDNS_CONS   = 1,   /* the console */
    FDNS_PIPE_R = 2,   /* the READ end of a pipe slot */
    FDNS_PIPE_W = 3,   /* the WRITE end of a pipe slot */
    FDNS_FILE   = 4,   /* an already-open file; `slot` IS the descriptor */
    FDNS_DUP    = 5,   /* whatever is bound at /fd/<slot> */
    FDNS_APPEND = 6,   /* an open file, every write at the end */
    FDNS_CHAN   = 7,   /* a device file — same representation as FILE here */
};

int     fdns_is_path(const char *path);      /* 1 for /fd or /fd/<n> */
int     fdns_open(const char *path, int for_write);   /* -> a real fd, or -1 */
int32_t fdns_pipechan(void);
int32_t fdns_openchan(const char *path, int32_t mode);
int32_t fdns_fdbind(int32_t pid, int32_t fdnum, int32_t kind, int32_t slot);
int32_t fdns_slot_kind(int32_t pid, int32_t fdnum);
void    fdns_after_fork_child(void);

/* Drop the pipe keepers this process still holds, for every slot whose two
 * REAL ends are now open.  Until it runs, the creator of a pipe is itself a
 * writer AND a reader on it, so the reader can never see EOF and the writer
 * can never see EPIPE -- that is the `cat FILE | md5sum` hang.  Call it from
 * anywhere a process is about to stop making progress on its own;
 * `wait_ms > 0` additionally bounds how long an unopened end may pin the
 * pipe before the keeper is dropped regardless.  Costs one predictable
 * branch when this process holds no keepers, which is almost all of them. */
void    fdns_keeper_sweep(int wait_ms);

/* The bound a blocking runtime call passes. Not a schedule: hamsh and
 * lib/p9.ad open the child's /fd/0,1,2 before exec, so both ends of a real
 * pipeline are open in well under a millisecond and this is never reached. */
#define FDNS_KEEPER_WAIT_MS 250

/* The spawn gate — see the long note in user/linux-fdns.c.
 * `parent` is called with the new child's pid right after fork; `release` is
 * called from every other runtime entry point and means "the parent has moved
 * on, so no more binds are coming". */
void    fdns_before_fork(void);
void    fdns_after_fork_parent(int32_t child);
void    fdns_gate_release(void);

#endif
