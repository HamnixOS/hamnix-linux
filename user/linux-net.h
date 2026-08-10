/* user/linux-net.h — the /net file tree. See user/linux-net.c. */
#ifndef HAMNIX_LINUX_NET_H
#define HAMNIX_LINUX_NET_H

#include <stdint.h>

enum {
    HAMNET_NONE = 0,
    HAMNET_CLONE,     /* /net/<proto>/clone   — read gives a conn number */
    HAMNET_CTL,       /* /net/<proto>/<n>/ctl                            */
    HAMNET_DATA,      /* /net/<proto>/<n>/data                           */
    HAMNET_STATUS,    /* /net/<proto>/<n>/status                         */
    HAMNET_LOCAL,     /* /net/<proto>/<n>/local                          */
    HAMNET_REMOTE,    /* /net/<proto>/<n>/remote                         */
    HAMNET_LISTEN,    /* /net/<proto>/<n>/listen                         */
    HAMNET_DIR,       /* /net, /net/<proto>, /net/<proto>/<n>            */
    HAMNET_IFACE,     /* /net/ipifc/... and the other read-only reports  */
};

struct hamnet_file {
    int      leaf;
    int      proto;      /* 0 tcp, 1 udp, 2 icmp */
    int      conn;
    int      write;
    uint64_t off;
    uint8_t *snap;
    uint64_t snaplen;
};

int     hamnet_kind(const char *path);
int     hamnet_open(const char *path, int for_write, struct hamnet_file *f);
int64_t hamnet_read(struct hamnet_file *f, uint8_t *buf, uint64_t cap);
int64_t hamnet_write(struct hamnet_file *f, const uint8_t *buf, uint64_t n);
void    hamnet_close(struct hamnet_file *f);

int64_t hamnet_cfg(uint64_t op, uint64_t a1, uint64_t a2);

#endif
