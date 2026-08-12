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
#include <stddef.h>
#include <sys/inotify.h>
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
 * CLIPBOARD never clobbers a live highlight's PRIMARY and vice versa.
 *
 * ==================================================================
 * THE SERIALS, AND WHY THEY ARE AT THE BOTTOM AND NOT THE TOP
 * ==================================================================
 *
 * HANDOFF asked for this as "two lines: `uint64_t serial;` in the struct at
 * line 127" -- i.e. in the header, beside `version`.  That placement is wrong
 * and the reason is the only compatibility question this change has:
 *
 *   THE SEGMENT IS A RENDEZVOUS BETWEEN PROCESSES THAT WERE NOT BUILT
 *   TOGETHER.  /srv/snarf outlives every program that maps it.  A field in the
 *   header moves clip[] and prim[] by 8 bytes, so a binary compiled before the
 *   change and one compiled after it, both alive on the same boot -- which is
 *   exactly what a package channel makes possible -- would read each other's
 *   clipboard at the wrong offset and paste garbage, silently.  Appending
 *   instead FREEZES every v1 offset, and the _Static_asserts below make that
 *   freeze a compile error rather than a convention.
 *
 * With the fields appended, sizeof(struct snarfshm) grows 131096 -> 131120 and
 * the two directions are:
 *
 *   NEW CLIENT, OLD SEGMENT (131096 bytes, created before this change).
 *     shm_attach already ftruncates any short segment up to sizeof, and a
 *     ftruncate that GROWS a file leaves every existing mapping of it valid
 *     (only shrinking can SIGBUS a mapper).  The new tail reads as zeroes, so
 *     both serials start at 0, which is exactly where a fresh segment starts.
 *
 *   OLD CLIENT, NEW SEGMENT (131120 bytes).  It mmaps the first 131096 bytes,
 *     which is a legal prefix of a longer file, and every field it knows about
 *     is where it has always been.  Copy and paste work.  What it does NOT do
 *     is bump a serial -- it has never heard of one.
 *
 * That last sentence is the whole reason the readers below keep a fallback.
 * `version` is deliberately LEFT AT 1: a version stamp can only describe the
 * segment, and the hazard is a live WRITER that predates the serial.  Bumping
 * it on attach would let a reader conclude "this segment has serials, so I may
 * trust them", which is false the moment an old binary is still running with
 * it mapped.  A flag that can be wrong is worse than no flag, so there is
 * none, and every reader reconciles on a timer regardless.
 *
 * WRAP.  A uint64 counter incremented once per write wraps after 2^64 =
 * 1.8446744e19 writes.  hamsnarf_write cannot run faster than about 10 ns
 * (an atomic read-modify-write on a shared line, plus a memcpy, plus the
 * pwrite below), so a wrap needs upwards of 5 800 YEARS of a machine doing
 * nothing but copying to the clipboard, on a segment whose lifetime is one
 * boot of a tmpfs.  It does not wrap.  And if it somehow did: every reader
 * compares !=, never < or >, so a wrapped value still differs from the last
 * one seen unless EXACTLY a multiple of 2^64 bumps landed between two polls.
 * There is no ordering claim anywhere in this file that a wrap could break.
 *
 * WHAT THE BUMP IS ATOMIC WITH RESPECT TO, said plainly:
 *   - IT IS an atomic read-modify-write (__atomic_add_fetch, ACQ_REL), so two
 *     processes copying at the same instant get two DIFFERENT serials.  A
 *     plain `(*serialp)++` would not: both could load 5 and store 6, and the
 *     second copy would then be invisible to a reader that had already seen 6.
 *     That is a lost notification, which is the one failure a serial exists to
 *     prevent, so the RMW is load-bearing and not decoration.
 *   - IT IS ordered AFTER the bytes and the length: the release store cannot
 *     be hoisted above them, so a reader that has seen serial N has, on its
 *     matching acquire load, seen everything the writer of N wrote.
 *   - IT IS NOT a lock.  Two writers still interleave their bytes -- the
 *     pre-existing gap HANDOFF records -- and the serial does not fix it; it
 *     only guarantees the interleaving is NOTICED.
 *   - IT IS NOT a count of writes as far as any reader is concerned.  Readers
 *     may only ask "is this different from what I last saw".
 * ================================================================== */
struct snarfshm {
    uint32_t magic;
    uint32_t version;
    uint64_t clip_len;
    uint64_t prim_len;
    uint8_t  clip[HAMSNARF_MAX];
    uint8_t  prim[HAMSNARF_MAX];
    /* ---- everything above is v1; these offsets are FROZEN ---- */
    uint64_t clip_serial;
    uint64_t prim_serial;
    /* Written by pwrite(2) and read by nobody.  An mmap store generates no
     * inotify event -- the kernel never sees it -- so a one-byte write through
     * a real descriptor is what makes IN_MODIFY fire and lets a reader park on
     * the clipboard instead of polling it.  Its VALUE is meaningless, which is
     * the point: writing a constant cannot race another writer, whereas
     * pwriting the serial itself could put back a value another process had
     * already superseded and walk the counter BACKWARDS. */
    uint8_t  poke;
};

/* The freeze, checkable by the compiler.  If someone adds a field to the
 * header again, this is a build error and not a corrupted paste. */
_Static_assert(offsetof(struct snarfshm, clip) == 24, "v1 clip offset moved");
_Static_assert(offsetof(struct snarfshm, prim) == 24 + HAMSNARF_MAX,
               "v1 prim offset moved");
_Static_assert(offsetof(struct snarfshm, clip_serial) == 24 + 2 * HAMSNARF_MAX,
               "the v1 prefix is no longer 131096 bytes");

static struct snarfshm *shm;
static int  seg_fd = -1;               /* kept open for the inotify poke */
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
    if (m == MAP_FAILED) { int e = errno; close(fd); errno = e; return -1; }
    /* THE DESCRIPTOR IS KEPT, where it used to be closed: hamsnarf_write needs
     * it for the one-byte poke that makes inotify fire, and an inotify watch
     * needs a path that is still the same inode.  FD_CLOEXEC so it does not
     * ride into a foreign binary in a namespace -- the clipboard is reached by
     * NAME across that boundary, never by a descriptor (NORTH_STAR). */
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    seg_fd = fd;
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
    if (!strcmp(path, "/dev/snarf.serial"))  return HAMSNARF_SERIAL;
    return HAMSNARF_NONE;
}

int hamsnarf_open(const char *path, int for_write, struct hamsnarf_file *f)
{
    int k = hamsnarf_kind(path);
    if (k == HAMSNARF_NONE) { errno = ENODEV; return -1; }
    if (shm_attach() < 0)
        return -1;
    /* REFUSED BY NAME.  A serial is something the device tells you, not
     * something you tell it, and a write that was quietly swallowed here would
     * be a program believing it had announced a clipboard change it had not. */
    if (k == HAMSNARF_SERIAL && for_write) { errno = EPERM; return -1; }
    f->which = k;
    f->write = for_write;
    f->wfd = -1;
    f->linelen = 0;
    if (k == HAMSNARF_SERIAL) {
        /* The park.  IN_MODIFY on the segment file fires on the poke every
         * hamsnarf_write performs; IN_NONBLOCK so draining it can never stall
         * an event loop.  A failure here is NOT fatal -- the caller then has a
         * device it can read and not wait on, which is exactly the state every
         * caller must already tolerate (see the fallback note in the readers).
         * A clipboard that has to be looked at on a clock still works. */
        f->wfd = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
        if (f->wfd >= 0
            && inotify_add_watch(f->wfd, seg_path, IN_MODIFY) < 0) {
            close(f->wfd);
            f->wfd = -1;
        }
    }
    /* OPENING DOES NOT TRUNCATE.  The buffer is cleared by a REPLACE write at
     * offset 0, which is where devsnarf.ad puts that decision, so an open
     * that is never written to leaves the clipboard alone.  A reader and a
     * writer therefore see the same buffer whichever opened first. */
    f->off = 0;
    return 0;
}

void hamsnarf_close(struct hamsnarf_file *f)
{
    /* `wfd` is NOT closed here.  devtab_open handed it to the caller AS the
     * caller's descriptor, so the close(2) that reaches this device closes it
     * on the way past; closing it again would shut a descriptor some other
     * open has since been given the same number for.  That is the same
     * ownership rule the /dev/null-backed devices already follow. */
    f->which = HAMSNARF_NONE;
    f->off = 0;
    f->wfd = -1;
    f->linelen = 0;
}

int hamsnarf_waitfd(const struct hamsnarf_file *f)
{
    return f->which == HAMSNARF_SERIAL ? f->wfd : -1;
}

/* The two counters, sampled with acquire loads so that everything the writer
 * of this value published is visible to whoever acts on it. */
static void serial_line(struct hamsnarf_file *f)
{
    uint64_t c = __atomic_load_n(&shm->clip_serial, __ATOMIC_ACQUIRE);
    uint64_t p = __atomic_load_n(&shm->prim_serial, __ATOMIC_ACQUIRE);
    int n = snprintf(f->line, sizeof f->line, "%20llu %20llu\n",
                     (unsigned long long)c, (unsigned long long)p);
    f->linelen = n < 0 ? 0 : (uint64_t)n;
}

/* Swallow whatever inotify has queued.  A LEVEL-triggered descriptor that is
 * never drained is ready for ever, and an event loop parked on one would spin
 * at the speed of the machine -- the exact failure sys_waitfds' own header
 * records for /dev/null-backed devices.  Draining HERE, on the sample, is what
 * makes "wait on it, then read it" a complete protocol for the caller: the
 * read consumes the notification it woke for. */
static void serial_drain(int wfd)
{
    if (wfd < 0) return;
    char junk[512];
    for (;;) {
        ssize_t n = read(wfd, junk, sizeof junk);
        if (n <= 0) break;
    }
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

    /* THE SAMPLE IS TAKEN AT OFFSET 0, not at open, and that is what makes a
     * held descriptor usable as a poll point: a caller seeks back to 0 and
     * reads again to take a fresh sample, and `cat /dev/snarf.serial` still
     * hits EOF after one line instead of regenerating for ever.  Taking it
     * once, rather than per read, is what stops a chunked reader from
     * straddling two different samples and assembling a line that was never
     * true. */
    if (f->which == HAMSNARF_SERIAL) {
        if (f->off == 0) {
            serial_drain(f->wfd);
            serial_line(f);
        }
        if (f->off >= f->linelen)
            return 0;
        uint64_t avail = f->linelen - f->off;
        uint64_t take = count < avail ? count : avail;
        memcpy(buf, f->line + f->off, (size_t)take);
        f->off += take;
        return (int64_t)take;
    }

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

    /* THE SERIAL IS BUMPED LAST OF ALL, after the bytes and after the length,
     * with an atomic read-modify-write and release ordering.  See the long
     * note on `struct snarfshm`: the RMW is what stops two simultaneous
     * copies from landing on the same serial and making the second one
     * invisible, and the release is what makes "I have seen serial N" mean "I
     * can see the bytes of N".
     *
     * IT IS BUMPED EVEN WHEN THE BYTES ARE IDENTICAL, deliberately.  A write
     * IS an event: it is how a program says "this is the clipboard now", and
     * it is the one thing a content comparison structurally cannot see.  The
     * bridges still decide what to DO by comparing content -- that is their
     * anti-ping-pong invariant and it is not being retired here -- but the
     * device's job is to report what happened, not to guess what mattered.
     *
     * The truncated-past-the-cap path above returns early WITHOUT a bump,
     * which is right: nothing was stored, so nothing changed. */
    uint64_t *serialp = f->which == HAMSNARF_PRIMARY ? &shm->prim_serial
                                                     : &shm->clip_serial;
    __atomic_add_fetch(serialp, 1, __ATOMIC_ACQ_REL);

    /* ...and the poke, which is the ONLY part of this the kernel can see.  It
     * is what turns /dev/snarf.serial's inotify descriptor from a decoration
     * into a wakeup, and it is a whole syscall on a path that runs once per
     * human keystroke-pair, not once per frame.  Best effort: a segment
     * mapped from a descriptor that has since gone (it has not, it is held
     * open) leaves every reader on its reconcile timer, which still
     * converges. */
    if (seg_fd >= 0) {
        static const uint8_t one = 1;
        ssize_t pw = pwrite(seg_fd, &one, 1,
                            (off_t)offsetof(struct snarfshm, poke));
        (void)pw;
    }

    f->off = start + take;
    return (int64_t)count;
}

int64_t hamsnarf_seek(struct hamsnarf_file *f, int64_t off, int whence)
{
    if (!shm || f->which == HAMSNARF_NONE) { errno = EBADF; return -EBADF; }
    uint64_t len;
    if (f->which == HAMSNARF_SERIAL)
        len = HAMSNARF_SERIAL_LINE;    /* fixed width, so SEEK_END is exact */
    else {
        len = *len_of(f->which);
        if (len > HAMSNARF_MAX) len = HAMSNARF_MAX;
    }
    int64_t base = whence == 1 ? (int64_t)f->off
                 : whence == 2 ? (int64_t)len : 0;
    int64_t want = base + off;
    if (want < 0) { errno = EINVAL; return -EINVAL; }
    f->off = (uint64_t)want;
    return want;
}
