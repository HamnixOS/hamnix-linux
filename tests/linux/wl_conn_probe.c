/* tests/linux/wl_conn_probe.c — a Wayland client small enough to be evidence.
 *
 * WHY NOT weston-simple-shm, WHICH IS ALREADY IN THE OTHER GATES
 * =============================================================
 * Because it cannot tell the difference between the two things this test is
 * about.  When wsyswl's connection table was full it closed the socket, and
 * weston-simple-shm's ninth instance died saying
 *
 *     No wl_shm global
 *
 * -- measured, not supposed.  wl_shm IS advertised; the client simply looks
 * at its globals before it looks at whether the connection survived, so a
 * REFUSED CLIENT BLAMES A MISSING PROTOCOL GLOBAL.  A test that asserted on
 * that string would be asserting on a lie, and a person debugging a real
 * desktop would go looking for the wrong bug.  That is the gap-answering-
 * something-success-shaped failure NORTH_STAR names, arriving from the
 * client's side.
 *
 * libwayland would report it properly, and this host has libwayland-client.so
 * but no wayland-client.h, so linking against it is not available here.  It
 * is also not wanted: this speaks the wire itself, so what the test asserts
 * is THE BYTES THE SERVER SENT and not one library's rendering of them.
 *
 * WHAT IT DOES
 *   connect(2) to the socket, send wl_display.get_registry, then read.
 *     * a wl_display.error event on object 1  -> REFUSED, and it prints the
 *       code and the server's message verbatim.
 *     * a wl_registry.global event            -> ACCEPTED.
 *     * EOF with neither                      -> DROPPED, which is what a
 *       refusal with nothing said on the wire looks like, and is a FAIL.
 *
 *   -hold N   stay connected N seconds after reporting, so a caller can fill
 *             the connection table with these and keep it full.
 *
 * Exit: 0 accepted, 3 refused-and-named, 4 dropped in silence, 1 usage/errno.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#define WL_DISPLAY_ID 1u

int main(int argc, char **argv)
{
    const char *path = NULL;
    int hold = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-hold") && i + 1 < argc) hold = atoi(argv[++i]);
        else path = argv[i];
    }
    if (!path) { fprintf(stderr, "usage: wl_conn_probe [-hold N] <socket>\n"); return 1; }
    /* UNBUFFERED, because -hold means this process is still alive and holding
     * its slot when the caller reads the file, and a verdict sitting in a
     * stdio buffer reads exactly like a client that never got one. */
    setvbuf(stdout, NULL, _IONBF, 0);

    struct sockaddr_un sa;
    if (strlen(path) >= sizeof sa.sun_path) { fprintf(stderr, "path too long\n"); return 1; }
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) { perror("socket"); return 1; }
    memset(&sa, 0, sizeof sa);
    sa.sun_family = AF_UNIX;
    strcpy(sa.sun_path, path);
    if (connect(fd, (struct sockaddr *)&sa, sizeof sa) < 0) {
        /* The connect itself failing is a THIRD outcome and must not be
         * confused with a refusal: it means the socket is gone, not full. */
        printf("PROBE connect-failed %s\n", strerror(errno));
        return 1;
    }

    /* wl_display.get_registry(new_id 2): obj=1, (size<<16)|opcode, new_id. */
    uint32_t req[3] = { WL_DISPLAY_ID, (12u << 16) | 1u, 2u };
    if (write(fd, req, sizeof req) != (ssize_t)sizeof req) {
        printf("PROBE write-failed %s\n", strerror(errno));
        return 1;
    }

    uint8_t buf[8192];
    size_t have = 0;
    int verdict = 4;                            /* dropped in silence */
    const char *phrase = "DROPPED";
    /* Two seconds is far longer than a local socket needs and is only ever
     * waited out in the failing case. */
    for (int spins = 0; spins < 20 && verdict == 4; spins++) {
        struct pollfd p = { .fd = fd, .events = POLLIN };
        int r = poll(&p, 1, 100);
        if (r < 0) { if (errno == EINTR) continue; break; }
        if (r == 0) continue;
        ssize_t n = read(fd, buf + have, sizeof buf - have);
        if (n <= 0) break;                      /* EOF: nothing was said */
        have += (size_t)n;

        size_t pos = 0;
        while (have - pos >= 8) {
            uint32_t obj, w2;
            memcpy(&obj, buf + pos, 4);
            memcpy(&w2, buf + pos + 4, 4);
            uint32_t size = w2 >> 16, opcode = w2 & 0xffff;
            if (size < 8 || have - pos < size) break;
            if (obj == WL_DISPLAY_ID && opcode == 0 && size >= 20) {
                /* wl_display.error(object_id, code, message) */
                uint32_t bad, code, slen;
                memcpy(&bad,  buf + pos + 8,  4);
                memcpy(&code, buf + pos + 12, 4);
                memcpy(&slen, buf + pos + 16, 4);
                const char *msg = (const char *)(buf + pos + 20);
                if (slen > size - 20) slen = size - 20;
                printf("PROBE REFUSED object=%u code=%u message=%.*s\n",
                       bad, code, (int)(slen ? slen - 1 : 0), msg);
                verdict = 3;
                phrase = "REFUSED";
                break;
            }
            if (obj == 2u) {                    /* wl_registry.global */
                printf("PROBE ACCEPTED registry-event opcode=%u\n", opcode);
                verdict = 0;
                phrase = "ACCEPTED";
                break;
            }
            pos += size;
        }
    }
    if (verdict == 4)
        printf("PROBE DROPPED the server said nothing and closed\n");
    else
        (void)phrase;

    if (verdict == 0 && hold > 0)
        sleep((unsigned)hold);
    close(fd);
    return verdict;
}
