/* user/linux-auth.h — /dev/auth, the credential device. See linux-auth.c. */
#ifndef HAMNIX_LINUX_AUTH_H
#define HAMNIX_LINUX_AUTH_H

#include <stdint.h>

/* Per-open state. The FD is the capability: once `ok` is set, the holder may
 * become that user exactly once. */
struct hamauth_file {
    char     user[64];
    uint32_t uid;
    uint32_t gid;
    int      ok;         /* the credential checked out */
    int      drained;    /* the answer has been read */
};

int     hamauth_is_path(const char *path);
void    hamauth_open(struct hamauth_file *a);
int64_t hamauth_write(struct hamauth_file *a, const uint8_t *buf, uint64_t n);
int64_t hamauth_read(struct hamauth_file *a, uint8_t *buf, uint64_t cap);
int32_t hamauth_become(struct hamauth_file *a);

#endif
