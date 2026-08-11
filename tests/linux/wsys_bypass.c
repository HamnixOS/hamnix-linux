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
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

int main(int argc, char **argv)
{
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
