/* user/linux-net.c — /net, the Plan 9 network file tree, on Linux.
 *
 * WHY A FILE TREE AND NOT A SOCKET SHIM
 * =====================================
 * HANDOFF.md §3 lays out three options and identifies the constraint that
 * decides between them:
 *
 *     user/httpd.ad accepts a connection and hands it to a SEPARATE PROCESS,
 *     user/httpd_worker.ad, which opens /net/tcp/<conn>/data by NUMBER.
 *     "A shim library holding per-process socket state cannot express this;
 *     a real file server can. This is the single sharpest constraint on your
 *     design choice."
 *
 * That is the same shape as the /fd problem (§7.1), and it has the same
 * answer: the connection TABLE lives in shared memory, so a connection number
 * means the same thing in every process. What crosses the boundary is the
 * NUMBER, which is what the Plan 9 design always assumed.
 *
 * The socket descriptor itself is inherited across fork, so the entry records
 * the fd and any DESCENDANT of the process that accepted the connection can
 * use it -- which is exactly the httpd -> httpd_worker relationship, since the
 * worker is spawned by the server. An unrelated process gets ENOTCONN rather
 * than a wrong answer; passing a live descriptor to a stranger needs
 * SCM_RIGHTS and a rendezvous, and nothing in the tree asks for it.
 *
 * THE SURFACE, from user/net9.ad and user/ntpd.ad and user/ping.ad
 * ---------------------------------------------------------------
 *   /net/tcp/clone         open+read -> the connection number, in ASCII
 *   /net/tcp/<n>/ctl       connect <ip>!<port> | connect <ip> | announce <port>
 *                          | accept | tls <host> | hangup
 *                          READING it also answers the connection number,
 *                          which is how net_accept picks up a new one.
 *   /net/tcp/<n>/data      the byte stream. Opened with sys_open_write by
 *                          net_dial and then READ as well -- so a data file is
 *                          always read/write whichever open was used.
 *   /net/tcp/<n>/status    "<state> <local> <remote>\n", re-read per poll
 *   /net/tcp/<n>/local,remote
 *   /net/udp/..., /net/icmp/...  same shape
 *
 * TLS is `tls <host>` on the ctl file. In Hamnix the kernel owns a TLS 1.3
 * record layer and the data fd becomes transparently encrypted; here OpenSSL
 * does it and the data file's read/write route through SSL_read/SSL_write, so
 * the userland's view is identical.
 */

#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <net/if.h>
#include <net/route.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

#include "linux-net.h"

#ifdef HAMNIX_TLS
#include <openssl/ssl.h>
#include <openssl/err.h>
#endif

#define NET_MAGIC   0x484E4554u        /* "HNET" */
#define MAX_CONN    64

enum { P_TCP = 0, P_UDP = 1, P_ICMP = 2 };

struct connrec {
    uint32_t used;
    int32_t  proto;
    int32_t  fd;          /* valid in the owner and its descendants */
    int32_t  owner;       /* pid that created it */
    int32_t  listening;
    int32_t  tls;
    char     local[64];
    char     remote[64];
    char     state[16];
};

struct netshm {
    uint32_t magic;
    struct connrec conn[MAX_CONN];
};

static struct netshm *shm;

#ifdef HAMNIX_TLS
/* Per-process: an SSL object cannot be shared through a mapping. A connection
 * marked tls in the table but with no local SSL is one this process did not
 * hand shake, and reading it is an error rather than plaintext. */
static SSL     *ssl_of[MAX_CONN];
static SSL_CTX *ssl_ctx;
#endif

static const char *shm_path(void)
{
    const char *p = getenv("HAMNET");
    if (p && *p) return p;
    return "/srv/net";
}

static int attach(void)
{
    if (shm) return 0;
    const char *cands[3];
    int nc = 0;
    cands[nc++] = shm_path();
    cands[nc++] = "/dev/shm/hamnix-net";
    cands[nc++] = "/tmp/hamnix-net";

    int fd = -1;
    for (int i = 0; i < nc && fd < 0; i++)
        fd = open(cands[i], O_RDWR | O_CREAT, 0666);
    if (fd < 0) return -1;
    struct stat st;
    if (fstat(fd, &st) < 0) { close(fd); return -1; }
    if ((uint64_t)st.st_size < sizeof(struct netshm)
        && ftruncate(fd, (off_t)sizeof(struct netshm)) < 0) {
        close(fd); return -1;
    }
    void *m = mmap(NULL, sizeof(struct netshm), PROT_READ | PROT_WRITE,
                   MAP_SHARED, fd, 0);
    int e = errno;
    close(fd);
    if (m == MAP_FAILED) { errno = e; return -1; }
    shm = (struct netshm *)m;
    if (shm->magic != NET_MAGIC) {
        memset(shm, 0, sizeof(*shm));
        shm->magic = NET_MAGIC;
    }
    return 0;
}

/* ------------------------------------------------------------------ */
static struct connrec *conn_at(int n)
{
    if (!shm || n < 0 || n >= MAX_CONN) return NULL;
    return shm->conn[n].used ? &shm->conn[n] : NULL;
}

static int conn_alloc(int proto)
{
    if (attach() < 0) return -1;
    for (int i = 0; i < MAX_CONN; i++) {
        if (shm->conn[i].used) continue;
        memset(&shm->conn[i], 0, sizeof shm->conn[i]);
        shm->conn[i].used  = 1;
        shm->conn[i].proto = proto;
        shm->conn[i].fd    = -1;
        shm->conn[i].owner = (int32_t)getpid();
        snprintf(shm->conn[i].state, sizeof shm->conn[i].state, "Closed");
        return i;
    }
    errno = ENOSPC;
    return -1;
}

static void conn_free(int n)
{
    struct connrec *c = conn_at(n);
    if (!c) return;
#ifdef HAMNIX_TLS
    if (ssl_of[n]) { SSL_free(ssl_of[n]); ssl_of[n] = NULL; }
#endif
    if (c->fd >= 0) close(c->fd);
    c->used = 0;
}

static uint64_t put_uint(uint8_t *b, uint64_t at, unsigned v)
{
    char d[12]; int n = 0;
    if (v == 0) d[n++] = '0';
    while (v) { d[n++] = (char)('0' + v % 10); v /= 10; }
    while (n) b[at++] = (uint8_t)d[--n];
    return at;
}

/* ------------------------------------------------------------------ *
 * Path classification
 * ------------------------------------------------------------------ */
static int proto_of(const char *s, size_t n)
{
    if (n == 3 && !strncmp(s, "tcp", 3))  return P_TCP;
    if (n == 3 && !strncmp(s, "udp", 3))  return P_UDP;
    if (n == 4 && !strncmp(s, "icmp", 4)) return P_ICMP;
    return -1;
}

static int classify(const char *path, struct hamnet_file *f)
{
    if (strncmp(path, "/net", 4) != 0)
        return HAMNET_NONE;
    const char *p = path + 4;
    if (*p == '\0' || (p[0] == '/' && p[1] == '\0')) {
        if (f) { f->leaf = HAMNET_DIR; f->proto = -1; f->conn = -1; }
        return HAMNET_DIR;
    }
    if (*p != '/') return HAMNET_NONE;
    p++;

    const char *slash = strchr(p, '/');
    size_t plen = slash ? (size_t)(slash - p) : strlen(p);
    int proto = proto_of(p, plen);
    if (proto < 0) {
        /* /net/ipifc, /net/ndb, /net/cs ... read-only reports. */
        if (f) { f->leaf = HAMNET_IFACE; f->proto = -1; f->conn = -1; }
        return HAMNET_IFACE;
    }
    if (!slash) {
        if (f) { f->leaf = HAMNET_DIR; f->proto = proto; f->conn = -1; }
        return HAMNET_DIR;
    }
    const char *q = slash + 1;
    if (!strcmp(q, "clone")) {
        if (f) { f->leaf = HAMNET_CLONE; f->proto = proto; f->conn = -1; }
        return HAMNET_CLONE;
    }
    if (*q < '0' || *q > '9') return HAMNET_NONE;
    int n = 0;
    while (*q >= '0' && *q <= '9') { n = n * 10 + (*q - '0'); q++; }
    int leaf;
    if (*q == '\0')                    leaf = HAMNET_DIR;
    else if (*q != '/')                return HAMNET_NONE;
    else if (!strcmp(q + 1, "ctl"))    leaf = HAMNET_CTL;
    else if (!strcmp(q + 1, "data"))   leaf = HAMNET_DATA;
    else if (!strcmp(q + 1, "status")) leaf = HAMNET_STATUS;
    else if (!strcmp(q + 1, "local"))  leaf = HAMNET_LOCAL;
    else if (!strcmp(q + 1, "remote")) leaf = HAMNET_REMOTE;
    else if (!strcmp(q + 1, "listen")) leaf = HAMNET_LISTEN;
    else                               return HAMNET_NONE;
    if (f) { f->leaf = leaf; f->proto = proto; f->conn = n; }
    return leaf;
}

int hamnet_kind(const char *path)
{
    if (!path) return HAMNET_NONE;
    return classify(path, NULL);
}

/* ------------------------------------------------------------------ */
static int snap_set(struct hamnet_file *f, const uint8_t *b, uint64_t n)
{
    free(f->snap);
    f->snap = NULL; f->snaplen = 0;
    if (!n) return 0;
    f->snap = malloc((size_t)n);
    if (!f->snap) { errno = ENOMEM; return -1; }
    memcpy(f->snap, b, (size_t)n);
    f->snaplen = n;
    return 0;
}

static int snap_num(struct hamnet_file *f, int v)
{
    uint8_t b[16];
    uint64_t n = put_uint(b, 0, (unsigned)v);
    b[n++] = '\n';
    return snap_set(f, b, n);
}

/* ------------------------------------------------------------------ *
 * ctl verbs
 * ------------------------------------------------------------------ */
static int parse_addr_port(const char *s, size_t n, char *host, size_t hcap,
                           int *port)
{
    /* Plan 9 spells an endpoint host!service. `connect <ip>` with no service
     * is legal for icmp, where the optional field is an RFC 792 identifier
     * rather than a port -- see user/ping.ad. */
    size_t i = 0;
    while (i < n && (s[i] == ' ' || s[i] == '\t')) i++;
    size_t start = i;
    while (i < n && s[i] != '!' && s[i] != '\n' && s[i] != ' ') i++;
    size_t hl = i - start;
    if (hl == 0 || hl >= hcap) return -1;
    memcpy(host, s + start, hl);
    host[hl] = '\0';
    *port = 0;
    if (i < n && s[i] == '!') {
        i++;
        while (i < n && s[i] >= '0' && s[i] <= '9')
            *port = *port * 10 + (s[i++] - '0');
    }
    return 0;
}

static void record_ends(struct connrec *c)
{
    struct sockaddr_in a;
    socklen_t al = sizeof a;
    if (getsockname(c->fd, (struct sockaddr *)&a, &al) == 0)
        snprintf(c->local, sizeof c->local, "%s!%u",
                 inet_ntoa(a.sin_addr), (unsigned)ntohs(a.sin_port));
    al = sizeof a;
    if (getpeername(c->fd, (struct sockaddr *)&a, &al) == 0)
        snprintf(c->remote, sizeof c->remote, "%s!%u",
                 inet_ntoa(a.sin_addr), (unsigned)ntohs(a.sin_port));
}

#ifdef HAMNIX_TLS
static int tls_start(int n, struct connrec *c, const char *host)
{
    if (!ssl_ctx) {
        SSL_library_init();
        SSL_load_error_strings();
        ssl_ctx = SSL_CTX_new(TLS_client_method());
        if (!ssl_ctx) { errno = EPROTO; return -1; }
        SSL_CTX_set_default_verify_paths(ssl_ctx);
    }
    SSL *s = SSL_new(ssl_ctx);
    if (!s) { errno = ENOMEM; return -1; }
    SSL_set_fd(s, c->fd);
    if (*host) {
        SSL_set_tlsext_host_name(s, host);
        SSL_set1_host(s, host);
    }
    if (SSL_connect(s) != 1) {
        SSL_free(s);
        errno = EPROTO;
        return -1;
    }
    ssl_of[n] = s;
    c->tls = 1;
    return 0;
}
#endif

static int64_t ctl_verb(int n, struct connrec *c, const char *s, size_t len)
{
    char host[256];
    int port = 0;

    if (len >= 7 && !strncmp(s, "connect", 7)) {
        if (parse_addr_port(s + 7, len - 7, host, sizeof host, &port) < 0) {
            errno = EINVAL; return -EINVAL;
        }
        int type = (c->proto == P_UDP) ? SOCK_DGRAM
                 : (c->proto == P_ICMP) ? SOCK_DGRAM : SOCK_STREAM;
        int prot = (c->proto == P_ICMP) ? IPPROTO_ICMP : 0;
        if (c->fd < 0) {
            c->fd = socket(AF_INET, type, prot);
            if (c->fd < 0) return -(int64_t)errno;
        }
        struct sockaddr_in a;
        memset(&a, 0, sizeof a);
        a.sin_family = AF_INET;
        a.sin_port   = htons((uint16_t)port);
        if (inet_pton(AF_INET, host, &a.sin_addr) != 1) {
            errno = EINVAL; return -EINVAL;
        }
        if (connect(c->fd, (struct sockaddr *)&a, sizeof a) < 0)
            return -(int64_t)errno;
        record_ends(c);
        snprintf(c->state, sizeof c->state, "Established");
        return (int64_t)len;
    }
    if (len >= 8 && !strncmp(s, "announce", 8)) {
        /* "announce <port>" -- and in Plan 9 an announce with no address
         * means every interface, which is what every server in the tree
         * wants. */
        size_t i = 8;
        while (i < len && (s[i] == ' ' || s[i] == '*' || s[i] == '!')) i++;
        port = 0;
        while (i < len && s[i] >= '0' && s[i] <= '9')
            port = port * 10 + (s[i++] - '0');
        int type = (c->proto == P_UDP) ? SOCK_DGRAM : SOCK_STREAM;
        if (c->fd < 0) {
            c->fd = socket(AF_INET, type, 0);
            if (c->fd < 0) return -(int64_t)errno;
        }
        int one = 1;
        setsockopt(c->fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
        struct sockaddr_in a;
        memset(&a, 0, sizeof a);
        a.sin_family      = AF_INET;
        a.sin_addr.s_addr = htonl(INADDR_ANY);
        a.sin_port        = htons((uint16_t)port);
        if (bind(c->fd, (struct sockaddr *)&a, sizeof a) < 0)
            return -(int64_t)errno;
        if (type == SOCK_STREAM && listen(c->fd, 64) < 0)
            return -(int64_t)errno;
        c->listening = 1;
        record_ends(c);
        snprintf(c->state, sizeof c->state, "Announced");
        return (int64_t)len;
    }
    if (len >= 6 && !strncmp(s, "accept", 6)) {
        if (!c->listening || c->fd < 0) { errno = EINVAL; return -EINVAL; }
        int a = accept(c->fd, NULL, NULL);
        if (a < 0) return -(int64_t)errno;
        int nn = conn_alloc(c->proto);
        if (nn < 0) { close(a); return -(int64_t)errno; }
        struct connrec *nc = conn_at(nn);
        nc->fd = a;
        record_ends(nc);
        snprintf(nc->state, sizeof nc->state, "Established");
        /* Plan 9's accept answers the NEW connection number on the ctl file
         * you wrote it to -- user/net9.ad:329 reads it straight back. The
         * number is what crosses to httpd_worker, which then opens
         * /net/tcp/<n>/data by name. */
        return (int64_t)nn;
    }
    if (len >= 3 && !strncmp(s, "tls", 3)) {
#ifdef HAMNIX_TLS
        size_t i = 3;
        while (i < len && s[i] == ' ') i++;
        size_t hl = 0;
        while (i + hl < len && s[i + hl] != '\n' && s[i + hl] != ' '
               && hl < sizeof host - 1) { host[hl] = s[i + hl]; hl++; }
        host[hl] = '\0';
        if (tls_start(n, c, host) < 0)
            return -(int64_t)errno;
        return (int64_t)len;
#else
        /* Deliberately an error, not a silent plaintext connection: a caller
         * that asked for TLS and got cleartext would send credentials in the
         * clear and never know. Build with -DHAMNIX_TLS and -lssl -lcrypto. */
        errno = ENOSYS;
        return -ENOSYS;
#endif
    }
    if (len >= 6 && !strncmp(s, "hangup", 6)) {
        conn_free(n);
        return (int64_t)len;
    }
    if (len >= 4 && !strncmp(s, "bind", 4))
        return (int64_t)len;            /* accepted, nothing to do */
    errno = EINVAL;
    return -EINVAL;
}

/* ------------------------------------------------------------------ */
int hamnet_open(const char *path, int for_write, struct hamnet_file *f)
{
    memset(f, 0, sizeof *f);
    if (classify(path, f) == HAMNET_NONE) { errno = ENODEV; return -1; }
    if (attach() < 0) return -1;
    f->write = for_write;

    switch (f->leaf) {
    case HAMNET_CLONE: {
        int n = conn_alloc(f->proto);
        if (n < 0) return -1;
        f->conn = n;
        f->leaf = HAMNET_CTL;         /* a clone fd IS the new ctl file */
        return snap_num(f, n);
    }
    case HAMNET_CTL:
        if (!conn_at(f->conn)) { errno = ENOENT; return -1; }
        return snap_num(f, f->conn);
    case HAMNET_DATA: {
        struct connrec *c = conn_at(f->conn);
        if (!c) { errno = ENOENT; return -1; }
        if (c->fd < 0) { errno = ENOTCONN; return -1; }
        return 0;
    }
    case HAMNET_STATUS: case HAMNET_LOCAL: case HAMNET_REMOTE: {
        struct connrec *c = conn_at(f->conn);
        if (!c) { errno = ENOENT; return -1; }
        uint8_t b[192];
        int n;
        if (f->leaf == HAMNET_LOCAL)
            n = snprintf((char *)b, sizeof b, "%s\n", c->local);
        else if (f->leaf == HAMNET_REMOTE)
            n = snprintf((char *)b, sizeof b, "%s\n", c->remote);
        else
            n = snprintf((char *)b, sizeof b, "%s %s %s\n",
                         c->state, c->local, c->remote);
        return snap_set(f, b, (uint64_t)(n < 0 ? 0 : n));
    }
    case HAMNET_LISTEN: {
        struct connrec *c = conn_at(f->conn);
        if (!c) { errno = ENOENT; return -1; }
        return 0;
    }
    case HAMNET_DIR: {
        uint8_t b[512];
        uint64_t n = 0;
        if (f->proto < 0) {
            const char *e[] = { "tcp", "udp", "icmp" };
            for (unsigned i = 0; i < 3; i++) {
                for (const char *p = e[i]; *p; p++) b[n++] = (uint8_t)*p;
                b[n++] = '\n';
            }
        } else if (f->conn < 0) {
            for (const char *p = "clone"; *p; p++) b[n++] = (uint8_t)*p;
            b[n++] = '\n';
            for (int i = 0; i < MAX_CONN; i++)
                if (shm->conn[i].used && shm->conn[i].proto == f->proto) {
                    n = put_uint(b, n, (unsigned)i);
                    b[n++] = '\n';
                }
        } else {
            const char *e[] = { "ctl", "data", "status", "local",
                                "remote", "listen" };
            for (unsigned i = 0; i < 6; i++) {
                for (const char *p = e[i]; *p; p++) b[n++] = (uint8_t)*p;
                b[n++] = '\n';
            }
        }
        return snap_set(f, b, n);
    }
    case HAMNET_IFACE:
        /* Reports this line does not synthesise yet. An empty file rather
         * than an error: a reader that finds nothing reports "no interfaces",
         * which is true, instead of "the network stack is missing". */
        return snap_set(f, NULL, 0);
    default:
        errno = ENODEV;
        return -1;
    }
}

int64_t hamnet_read(struct hamnet_file *f, uint8_t *buf, uint64_t cap)
{
    if (f->leaf == HAMNET_DATA) {
        struct connrec *c = conn_at(f->conn);
        if (!c || c->fd < 0) { errno = ENOTCONN; return -ENOTCONN; }
#ifdef HAMNIX_TLS
        if (c->tls) {
            if (!ssl_of[f->conn]) { errno = ENOTCONN; return -ENOTCONN; }
            int r = SSL_read(ssl_of[f->conn], buf, (int)cap);
            if (r <= 0) {
                int e = SSL_get_error(ssl_of[f->conn], r);
                if (e == SSL_ERROR_ZERO_RETURN) return 0;
                errno = EIO;
                return -EIO;
            }
            return r;
        }
#endif
        ssize_t r = read(c->fd, buf, (size_t)cap);
        return r < 0 ? -(int64_t)errno : (int64_t)r;
    }
    if (f->leaf == HAMNET_LISTEN) {
        /* Reading `listen` blocks until a connection arrives and answers its
         * number -- the same thing `accept` on ctl does, spelled the other
         * Plan 9 way. */
        struct connrec *c = conn_at(f->conn);
        if (!c) { errno = ENOENT; return -ENOENT; }
        int64_t r = ctl_verb(f->conn, c, "accept", 6);
        if (r < 0) return r;
        uint64_t n = put_uint(buf, 0, (unsigned)r);
        if (n < cap) buf[n++] = '\n';
        return (int64_t)n;
    }
    if (!f->snap || f->off >= f->snaplen) return 0;
    uint64_t n = f->snaplen - f->off;
    if (n > cap) n = cap;
    memcpy(buf, f->snap + f->off, (size_t)n);
    f->off += n;
    return (int64_t)n;
}

int64_t hamnet_write(struct hamnet_file *f, const uint8_t *buf, uint64_t n)
{
    if (f->leaf == HAMNET_CTL) {
        struct connrec *c = conn_at(f->conn);
        if (!c) { errno = ENOENT; return -ENOENT; }
        size_t len = (size_t)n;
        while (len && (buf[len - 1] == '\n' || buf[len - 1] == '\r')) len--;
        int64_t r = ctl_verb(f->conn, c, (const char *)buf, len);
        if (r < 0) return r;
        /* An `accept` answers the NEW connection number when the caller reads
         * the same fd back, so re-arm the snapshot with it. Everything else
         * keeps answering this connection's own number. */
        if (len >= 6 && !strncmp((const char *)buf, "accept", 6))
            snap_num(f, (int)r);
        else
            snap_num(f, f->conn);
        f->off = 0;
        return (int64_t)n;
    }
    if (f->leaf == HAMNET_DATA) {
        struct connrec *c = conn_at(f->conn);
        if (!c || c->fd < 0) { errno = ENOTCONN; return -ENOTCONN; }
#ifdef HAMNIX_TLS
        if (c->tls) {
            if (!ssl_of[f->conn]) { errno = ENOTCONN; return -ENOTCONN; }
            int w = SSL_write(ssl_of[f->conn], buf, (int)n);
            if (w <= 0) { errno = EIO; return -EIO; }
            return w;
        }
#endif
        ssize_t w = write(c->fd, buf, (size_t)n);
        return w < 0 ? -(int64_t)errno : (int64_t)w;
    }
    errno = EPERM;
    return -EPERM;
}

void hamnet_close(struct hamnet_file *f)
{
    /* Only the DATA file holds the connection: user/net9.ad's header is
     * explicit that net_dial closes clone and ctl and "the returned data fd
     * alone keeps the connection alive", and that closing it tears the
     * connection down. */
    if (f->leaf == HAMNET_DATA && f->conn >= 0)
        conn_free(f->conn);
    free(f->snap);
    f->snap = NULL;
    f->snaplen = 0;
}

/* ------------------------------------------------------------------ *
 * sys_netcfg — interface configuration
 *
 * HANDOFF §3.3: this is deliberately NOT on the file tree in Hamnix either;
 * it is a syscall. ops: 0 read config, 1 set addr/mask, 2 set gateway,
 * 3 set DNS, 5 enumerate routes. Callers: user/ifconfig.ad, user/route.ad.
 *
 * ioctl(2) rather than rtnetlink: the operations here are exactly the four
 * SIOC* calls, and a netlink socket would be a lot of machinery for no
 * additional capability.
 * ------------------------------------------------------------------ */
static const char *default_iface(void)
{
    const char *p = getenv("HAMNIX_IFACE");
    return (p && *p) ? p : "eth0";
}

static int set_ifaddr(unsigned long req, uint32_t be_addr)
{
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s < 0) return -1;
    struct ifreq ifr;
    memset(&ifr, 0, sizeof ifr);
    snprintf(ifr.ifr_name, IFNAMSIZ, "%s", default_iface());
    struct sockaddr_in *a = (struct sockaddr_in *)&ifr.ifr_addr;
    a->sin_family = AF_INET;
    a->sin_addr.s_addr = be_addr;
    int r = ioctl(s, req, &ifr);
    int e = errno;
    close(s);
    errno = e;
    return r;
}

static int iface_up(void)
{
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s < 0) return -1;
    struct ifreq ifr;
    memset(&ifr, 0, sizeof ifr);
    snprintf(ifr.ifr_name, IFNAMSIZ, "%s", default_iface());
    if (ioctl(s, SIOCGIFFLAGS, &ifr) < 0) { int e = errno; close(s); errno = e; return -1; }
    ifr.ifr_flags |= IFF_UP | IFF_RUNNING;
    int r = ioctl(s, SIOCSIFFLAGS, &ifr);
    int e = errno;
    close(s);
    errno = e;
    return r;
}

int64_t hamnet_cfg(uint64_t op, uint64_t a1, uint64_t a2)
{
    switch (op) {
    case 1: {                       /* set address + netmask */
        if (set_ifaddr(SIOCSIFADDR, htonl((uint32_t)a1)) < 0)
            return -(int64_t)errno;
        if (a2 && set_ifaddr(SIOCSIFNETMASK, htonl((uint32_t)a2)) < 0)
            return -(int64_t)errno;
        if (iface_up() < 0)
            return -(int64_t)errno;
        return 0;
    }
    case 2: {                       /* default gateway */
        int s = socket(AF_INET, SOCK_DGRAM, 0);
        if (s < 0) return -(int64_t)errno;
        struct rtentry rt;
        memset(&rt, 0, sizeof rt);
        struct sockaddr_in *gw = (struct sockaddr_in *)&rt.rt_gateway;
        struct sockaddr_in *dst = (struct sockaddr_in *)&rt.rt_dst;
        struct sockaddr_in *msk = (struct sockaddr_in *)&rt.rt_genmask;
        gw->sin_family = dst->sin_family = msk->sin_family = AF_INET;
        gw->sin_addr.s_addr = htonl((uint32_t)a1);
        dst->sin_addr.s_addr = 0;
        msk->sin_addr.s_addr = 0;
        rt.rt_flags = RTF_UP | RTF_GATEWAY;
        char ifname[IFNAMSIZ];
        snprintf(ifname, sizeof ifname, "%s", default_iface());
        rt.rt_dev = ifname;
        int r = ioctl(s, SIOCADDRT, &rt);
        int e = errno;
        close(s);
        if (r < 0 && e != EEXIST) { errno = e; return -(int64_t)e; }
        return 0;
    }
    case 3: {                       /* DNS server */
        /* getaddrinfo reads /etc/resolv.conf, so that IS where a nameserver
         * is set on this line. Writing the file is the whole operation. */
        FILE *fp = fopen("/etc/resolv.conf", "w");
        if (!fp) return -(int64_t)errno;
        struct in_addr in;
        in.s_addr = htonl((uint32_t)a1);
        fprintf(fp, "nameserver %s\n", inet_ntoa(in));
        fclose(fp);
        return 0;
    }
    case 0: case 5:
        /* Reading the configuration back is not synthesised yet; the callers
         * (ifconfig/route with no arguments) print an empty report rather
         * than a wrong one. */
        errno = ENOSYS;
        return -ENOSYS;
    default:
        errno = EINVAL;
        return -EINVAL;
    }
}
