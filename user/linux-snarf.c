/* user/linux-snarf.c — /dev/snarf and /dev/snarf.primary.
 *
 * ==================================================================
 * WHY THIS IS A DEVICE AND NOT TWO ORDINARY FILES
 * ==================================================================
 *
 * The cheap answer existed and was measured (docs/linux_build_count.md §4):
 * two ordinary files at those paths give the toolkit the semantics it asks
 * for.  `sys_open_write` is O_WRONLY|O_TRUNC so a write replaces including
 * shrinking, `sys_read` is offset-addressed and hits EOF, the two are
 * independent, and copy/paste starts working with one line in an rc script
 * and no new code anywhere.  That answer is not wrong.  It is smaller than
 * the problem, in four specific ways, and each of them is a thing this tree
 * has already been bitten by once.
 *
 * 1. /dev/snarf WOULD NOT BE A DEVICE, and the guard in sys_open_write says
 *    it must be.  That guard drops O_CREAT under /dev/ so "a client writing
 *    to a device this line does not serve fails instead of silently creating
 *    an ordinary file" -- the fix that stopped user/playtone.ad reporting
 *    "played 1000 Hz square wave, 24000 frames" into a regular file called
 *    /dev/audio.  Its premise is that dev_path() claims exactly the paths
 *    that have a server behind them.  Planting two ordinary files under /dev
 *    does not violate the letter of that guard, but it retires its premise by
 *    hand: /dev would then contain a path that behaves like a device, is
 *    documented as a device, is called a device by lib/devsnarf.ad and by
 *    both toolkit selectors, and is in fact a regular file that any program
 *    can rename, chmod, hardlink or fill.  NORTH_STAR's "everything is a file
 *    server" is not decoration here; it is the invariant that makes the
 *    playtone guard checkable.
 *
 * 2. THE 64 KiB CAP.  /dev on a hamnix-linux boot is devtmpfs and /srv is
 *    tmpfs: both are RAM, the owner's RAM.  An ordinary file has no cap, so
 *    `cat bigfile > /dev/snarf` -- which is a completely ordinary thing to
 *    type at a shell that has a clipboard -- puts an unbounded amount of the
 *    machine's memory beyond reach with no error.  lib/devsnarf.ad has always
 *    said SNARF_MAX = 65536; this is where that number becomes true.  A write
 *    past the cap is TRUNCATED and still reports `count` consumed, so a
 *    userland write loop terminates rather than spinning -- devsnarf.ad's own
 *    rule, ported rather than re-decided.
 *
 * 3. THE OFFSET PROTOCOL IS THE DEVICE'S, NOT THE FILESYSTEM'S.  off == 0
 *    REPLACES (and a 0-byte write CLEARS, which is Plan 9's semantics);
 *    off > 0 writes there and EXTENDS.  An ordinary file gets the first half
 *    of that from O_TRUNC at open, which is a different mechanism that
 *    happens to agree today -- and the case where it stops agreeing is
 *    already written down as Defect 2 in docs/text_selection_clipboard.md:
 *    `echo text > /dev/snarf` emits the payload and its trailing newline as
 *    SEPARATE write() calls at offsets 0 and len.  With the device those are
 *    replace-then-extend by rule.  With a file they work only for as long as
 *    both writes share one descriptor and the cursor happens to line up.
 *    Porting the protocol keeps the rule; the file re-derives it by accident.
 *
 * 4. LIFETIME AND OWNERSHIP ARE STATED, NOT INHERITED.  Whoever first opens
 *    an ordinary /dev/snarf owns it, at whatever the umask of that moment
 *    says -- and on this line the first opener is not predictable: the
 *    compositor and the system chrome run as root and the session runs as uid
 *    1001 (etc/rc.de-user ends with `setuid 1001`).  That is the exact shape
 *    of the bug recorded in linux-wsys.c's shm_attach: a 0666 create masked
 *    to 0644 by PID 1's umask, and every non-root client silently locked out.
 *    Here the segment is fchmod'd 0666 after attach for the same reason and
 *    with the same justification, and the mode is load-bearing rather than
 *    accidental.
 *
 * WHAT A DEVICE DOES NOT BUY, said plainly so it is not mistaken for solved.
 * The segment is 0666 and MAP_SHARED, so a program that skips this file and
 * mmaps /srv/snarf itself can read and write the clipboard whatever any `if`
 * here says -- the same asymmetry linux-wsys.c names for SEGMENT A.  Unlike
 * wsys there is no split to make: a clipboard has no privileged half.  Its
 * entire purpose is to carry bytes ACROSS the root-chrome / uid-1001-session
 * boundary -- Ctrl+C in a root-started terminal must paste into a uid-1001
 * editor and back -- so "writable by every uid that can see these windows" is
 * the correct policy, not a compromise.  Reads are ungated, as they are
 * everywhere in this tree.
 *
 * WHOSE CLIPBOARD IS IT?  One per WINDOW SYSTEM, deliberately.  The scope of
 * a clipboard should be exactly the set of programs that can see each other's
 * windows, and on this line that set is named by /srv/wsys.  So when $HAMWSYS
 * is set -- which is how an offscreen or per-run window system is pinned --
 * the segment is DERIVED from it and the two can never end up in different
 * sessions.  That derivation is the fix for a hazard this tree has already
 * paid for: docs/steam_namespace.md §11 records HAMWSYS_BB as "the third
 * shared file, and it bit", one per HOST, where one offscreen run inherited
 * another run's state.  A clipboard is the fourth such file, and it is pinned
 * by construction here rather than by remembering to.
 *
 * So: two users sharing one window system share one clipboard, which is what
 * they mean by pasting between their programs; two window systems get two
 * clipboards without anyone configuring it.
 *
 * THE X CLIPBOARD IS A DIFFERENT CLIPBOARD, and this pass does not bridge it.
 * A Debian or Alpine program inside a namespace uses X selections, owned by
 * the Xwayland inside that namespace; jwm and the Wayland path have their
 * own.  Bridging them is not a line in a device server -- it needs a process
 * that OWNS an X selection and mirrors it in both directions, which is a
 * program (and one that belongs beside the Wayland/X path, not here).  Doing
 * half of it -- mirroring X into Hamnix but not back, or mirroring on copy
 * but not on ownership change -- would be precisely the success-shaped
 * failure NORTH_STAR exists to beat.  The Plan 9 answer is that a NAME is
 * what crosses a boundary, and the name is ready: /dev/snarf is served here,
 * inside the process, by a path interception, so it is reachable from any
 * namespace that runs Hamnix binaries without binding anything.  What is not
 * done is the bridge for FOREIGN binaries, and it is named in HANDOFF as not
 * done rather than quietly approximated.
 * ==================================================================
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include "linux-snarf.h"

/* ------------------------------------------------------------------ *
 * The shared segment
 * ------------------------------------------------------------------ */
#define SNARF_MAGIC 0x534e5246u        /* "SNRF" */

/* The two buffers of sys/src/9/port/devsnarf.ad, and of lib/devsnarf.ad after
 * it: independent backing arrays with their own lengths, so a Ctrl+C into the
 * CLIPBOARD never clobbers a live highlight's PRIMARY and vice versa. */
struct snarfshm {
    uint32_t magic;
    uint32_t version;
    uint64_t clip_len;
    uint64_t prim_len;
    uint8_t  clip[HAMSNARF_MAX];
    uint8_t  prim[HAMSNARF_MAX];
};

static struct snarfshm *shm;
static char seg_path[512];

const char *hamsnarf_segment(void)
{
    return seg_path[0] ? seg_path : NULL;
}

static int shm_attach(void)
{
    if (shm) return 0;

    const char *cands[5];
    char derived[512];
    int nc = 0;

    const char *p = getenv("HAMSNARF");
    if (p && *p) cands[nc++] = p;
    else {
        /* DERIVED FROM THE WINDOW SYSTEM when one is pinned -- see "WHOSE
         * CLIPBOARD IS IT?" above.  Only when $HAMWSYS is explicitly set: an
         * unpinned boot uses the posted-server name below. */
        const char *w = getenv("HAMWSYS");
        if (w && *w) {
            snprintf(derived, sizeof derived, "%s.snarf", w);
            cands[nc++] = derived;
        }
    }
    /* /srv is the Plan 9 place for a posted server and linuxinit mounts it as
     * tmpfs.  /dev/shm and /tmp are the fallbacks for a host run, where there
     * is no Hamnix namespace at all. */
    cands[nc++] = "/srv/snarf";
    cands[nc++] = "/dev/shm/hamnix-snarf";
    cands[nc++] = "/tmp/hamnix-snarf";

    /* ATTACH BEFORE CREATE, on every candidate, for the reason spelled out at
     * length in linux-wsys.c's shm_attach: fs.protected_regular refuses
     * O_CREAT on a file you do not own inside a sticky world-writable
     * directory -- which /srv is, at 1777 -- so a single open(O_RDWR|O_CREAT)
     * per candidate makes a uid-1001 client fall through and create its OWN
     * private clipboard, which nothing else can see.  A private clipboard is
     * the silent-success shape of this whole bug: copy reports 1, paste
     * returns nothing, and no error is printed anywhere. */
    int fd = -1;
    for (int i = 0; i < nc && fd < 0; i++) {
        fd = open(cands[i], O_RDWR);
        if (fd < 0)
            fd = open(cands[i], O_RDWR | O_CREAT, 0666);
        if (fd >= 0)
            snprintf(seg_path, sizeof seg_path, "%s", cands[i]);
    }
    if (fd < 0)
        return -1;

    /* open(2)'s mode is masked by the umask -- 022 for PID 1 -- so a segment
     * created by root lands 0644 and every client of the uid-1001 session
     * fails the O_RDWR open above and falls through to a private one.  That is
     * a measured failure of exactly this shape in linux-wsys.c.  0666 is the
     * correct mode for a shared IPC rendezvous in a 1777 tmpfs. */
    if (fchmod(fd, 0666) < 0) { /* not the creator; mode already correct */ }

    struct stat st;
    if (fstat(fd, &st) < 0) { int e = errno; close(fd); errno = e; return -1; }
    if ((uint64_t)st.st_size < sizeof(struct snarfshm)
        && ftruncate(fd, (off_t)sizeof(struct snarfshm)) < 0) {
        int e = errno; close(fd); errno = e; return -1;
    }
    void *m = mmap(NULL, sizeof(struct snarfshm), PROT_READ | PROT_WRITE,
                   MAP_SHARED, fd, 0);
    int e = errno;
    close(fd);
    if (m == MAP_FAILED) { errno = e; return -1; }
    shm = (struct snarfshm *)m;
    if (shm->magic != SNARF_MAGIC) {
        memset(shm, 0, sizeof *shm);
        shm->magic = SNARF_MAGIC;
        shm->version = 1;
    }
    return 0;
}

/* ------------------------------------------------------------------ *
 * Path routing
 *
 * Exact matches only.  These are two names, not a subtree, and a prefix match
 * would quietly claim /dev/snarfoo for the clipboard -- the same class of
 * mistake as a device path with no server answering success.
 * ------------------------------------------------------------------ */
int hamsnarf_kind(const char *path)
{
    if (!path) return HAMSNARF_NONE;
    if (!strcmp(path, "/dev/snarf"))         return HAMSNARF_CLIP;
    if (!strcmp(path, "/dev/snarf.primary")) return HAMSNARF_PRIMARY;
    return HAMSNARF_NONE;
}

int hamsnarf_open(const char *path, int for_write, struct hamsnarf_file *f)
{
    int k = hamsnarf_kind(path);
    if (k == HAMSNARF_NONE) { errno = ENODEV; return -1; }
    if (shm_attach() < 0)
        return -1;
    f->which = k;
    f->write = for_write;
    /* OPENING DOES NOT TRUNCATE.  The buffer is cleared by a REPLACE write at
     * offset 0, which is where devsnarf.ad puts that decision, so an open
     * that is never written to leaves the clipboard alone.  A reader and a
     * writer therefore see the same buffer whichever opened first. */
    f->off = 0;
    return 0;
}

void hamsnarf_close(struct hamsnarf_file *f)
{
    f->which = HAMSNARF_NONE;
    f->off = 0;
}

/* Which backing array and length this open addresses. */
static uint8_t *buf_of(int which)
{
    return which == HAMSNARF_PRIMARY ? shm->prim : shm->clip;
}
static uint64_t *len_of(int which)
{
    return which == HAMSNARF_PRIMARY ? &shm->prim_len : &shm->clip_len;
}

/* devsnarf.ad's devsnarf_read, byte for byte: returns 0 (EOF) once
 * off >= len, so a chunked reader terminates instead of regenerating the
 * buffer for ever. */
int64_t hamsnarf_read(struct hamsnarf_file *f, uint8_t *buf, uint64_t count)
{
    if (!shm || f->which == HAMSNARF_NONE) { errno = EBADF; return -EBADF; }
    /* The length is read ONCE and clamped to the cap.  A torn read against a
     * concurrent writer can then hand back stale bytes, but never bytes from
     * outside the buffer, and never a length the segment cannot hold. */
    uint64_t len = *len_of(f->which);
    if (len > HAMSNARF_MAX) len = HAMSNARF_MAX;
    if (f->off >= len)
        return 0;
    uint64_t avail = len - f->off;
    uint64_t take = count < avail ? count : avail;
    memcpy(buf, buf_of(f->which) + f->off, (size_t)take);
    f->off += take;
    return (int64_t)take;
}

/* devsnarf.ad's _sn_store, byte for byte:
 *     off == 0  -> REPLACE   (a 0-byte write CLEARS)
 *     off  > 0  -> write there and extend
 * Writes past the cap are truncated; `count` is still reported consumed so a
 * userland write loop terminates. */
int64_t hamsnarf_write(struct hamsnarf_file *f, const uint8_t *buf,
                       uint64_t count)
{
    if (!shm || f->which == HAMSNARF_NONE) { errno = EBADF; return -EBADF; }
    if (!f->write) { errno = EBADF; return -EBADF; }

    uint64_t *lenp = len_of(f->which);
    uint64_t cur = *lenp;
    if (cur > HAMSNARF_MAX) cur = HAMSNARF_MAX;
    uint64_t start = f->off;

    if (start > HAMSNARF_MAX) {              /* write starts past the cap */
        f->off += count;
        return (int64_t)count;
    }
    uint64_t take = count;
    if (start + take > HAMSNARF_MAX)
        take = HAMSNARF_MAX - start;         /* truncate at the cap */
    if (take)
        memcpy(buf_of(f->which) + start, buf, (size_t)take);

    /* THE LENGTH IS PUBLISHED LAST.  A concurrent reader that samples the
     * length before this store sees the OLD buffer, and one that samples it
     * after sees bytes that are already in place -- so a reader never walks
     * off the end of what has actually been written.  It is not a lock and
     * does not pretend to be one: two writers racing still interleave, which
     * is what two programs copying at the same instant means anywhere. */
    uint64_t newlen;
    if (start == 0)
        newlen = take;                       /* REPLACE */
    else if (start + take > cur)
        newlen = start + take;               /* extended */
    else
        newlen = cur;
    *lenp = newlen;

    f->off = start + take;
    return (int64_t)count;
}

int64_t hamsnarf_seek(struct hamsnarf_file *f, int64_t off, int whence)
{
    if (!shm || f->which == HAMSNARF_NONE) { errno = EBADF; return -EBADF; }
    uint64_t len = *len_of(f->which);
    if (len > HAMSNARF_MAX) len = HAMSNARF_MAX;
    int64_t base = whence == 1 ? (int64_t)f->off
                 : whence == 2 ? (int64_t)len : 0;
    int64_t want = base + off;
    if (want < 0) { errno = EINVAL; return -EINVAL; }
    f->off = (uint64_t)want;
    return want;
}
