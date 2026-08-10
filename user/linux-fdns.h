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
};

int     fdns_is_path(const char *path);      /* 1 for /fd or /fd/<n> */
int     fdns_open(const char *path, int for_write);   /* -> a real fd, or -1 */
int32_t fdns_pipechan(void);
int32_t fdns_fdbind(int32_t pid, int32_t fdnum, int32_t kind, int32_t slot);
int32_t fdns_slot_kind(int32_t pid, int32_t fdnum);
void    fdns_after_fork_child(void);

#endif
