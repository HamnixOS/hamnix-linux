/* user/linux-auth.c — /dev/auth, the credential device.
 *
 * WHAT IT IS FOR
 * ==============
 * user/login.ad, user/su.ad and hamsh's `newshell hostowner` all change
 * identity the same way, and none of them ever sees a password hash:
 *
 *     fd = open("/dev/auth")
 *     write(fd, "user <name>\n")
 *     write(fd, "pass <secret>\n")
 *     read(fd)              -> "ok" if the credential checked out
 *     sys_setuid_auth(fd)   -> become that user
 *
 * The FD is the capability. A process that holds a verified one may become
 * that user exactly once; a process that does not, cannot. The shape is
 * Plan 9's, and it is why the password checker lives behind a device rather
 * than in each program: `login`, `su` and the shell share one implementation
 * and none of them has to be trusted with /etc/shadow.
 *
 * On this line the device is served here, in the runtime, out of the real
 * /etc/shadow with glibc's crypt_r. Until it existed these programs BUILT and
 * could not work -- sys_setuid_auth was a flat `return -1` -- so `login`
 * could only ever answer "Login incorrect" and `su` could only ever refuse.
 * They were deliberately kept out of the image rather than shipped as
 * something that looks like a login and is not.
 *
 * WHAT IT DOES NOT DO. There is no attempt limit, no delay on failure and no
 * audit record. A console password prompt with none of those is weak against
 * an attacker who can retry quickly, and this device is the right place to
 * fix that when it matters -- the callers need no changes for it.
 */

#define _GNU_SOURCE
#include <crypt.h>
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <pwd.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include "linux-auth.h"

int hamauth_is_path(const char *path)
{
    return path && !strcmp(path, "/dev/auth");
}

void hamauth_open(struct hamauth_file *a)
{
    memset(a, 0, sizeof *a);
    a->uid = (uint32_t)-1;
}

/* The stored hash for `name`, or NULL. /etc/shadow is mode 0600 and owned by
 * root, which is the whole access control: a process that cannot read it
 * cannot authenticate anyone, which is the correct failure. */
static const char *shadow_hash(const char *name, char *out, size_t cap)
{
    FILE *f = fopen("/etc/shadow", "r");
    if (!f) return NULL;
    char line[1024];
    const char *found = NULL;
    size_t nl = strlen(name);
    while (fgets(line, sizeof line, f)) {
        if (line[0] == '#') continue;
        if (strncmp(line, name, nl) != 0 || line[nl] != ':') continue;
        char *h = line + nl + 1;
        char *end = strchr(h, ':');
        if (end) *end = '\0';
        char *nlc = strchr(h, '\n');
        if (nlc) *nlc = '\0';
        if (strlen(h) < cap) {
            memcpy(out, h, strlen(h) + 1);
            found = out;
        }
        break;
    }
    fclose(f);
    return found;
}

/* One verification. Returns 1 only for a real match. */
static int verify(const char *name, const char *pass)
{
    char stored[256];
    const char *h = shadow_hash(name, stored, sizeof stored);
    if (!h || !*h)
        return 0;
    /* A locked account is spelled `*` or `!`... and is not a hash. crypt()
     * would happily compare against it and a password of the right shape
     * could match, so refuse before getting there. */
    if (h[0] == '*' || h[0] == '!')
        return 0;

    struct crypt_data cd;
    memset(&cd, 0, sizeof cd);
    char *got = crypt_r(pass, h, &cd);
    if (!got)
        return 0;
    /* Constant-time compare: a length-dependent or early-exit compare on a
     * hash leaks how much of it matched. */
    size_t a = strlen(got), b = strlen(h);
    unsigned diff = (unsigned)(a ^ b);
    for (size_t i = 0; i < a && i < b; i++)
        diff |= (unsigned)(got[i] ^ h[i]);
    return diff == 0;
}

int64_t hamauth_write(struct hamauth_file *a, const uint8_t *buf, uint64_t n)
{
    /* One verb per line: `user <name>` then `pass <secret>`. */
    uint64_t i = 0;
    while (i < n) {
        uint64_t e = i;
        while (e < n && buf[e] != '\n') e++;
        size_t len = (size_t)(e - i);

        if (len > 5 && !memcmp(buf + i, "user ", 5)) {
            size_t k = len - 5;
            if (k >= sizeof a->user) k = sizeof a->user - 1;
            memcpy(a->user, buf + i + 5, k);
            a->user[k] = '\0';
            a->ok = 0;
            a->uid = (uint32_t)-1;
        } else if (len > 5 && !memcmp(buf + i, "pass ", 5)) {
            char pass[512];
            size_t k = len - 5;
            if (k >= sizeof pass) k = sizeof pass - 1;
            memcpy(pass, buf + i + 5, k);
            pass[k] = '\0';
            if (a->user[0] && verify(a->user, pass)) {
                struct passwd *pw = getpwnam(a->user);
                if (pw) {
                    a->ok  = 1;
                    a->uid = (uint32_t)pw->pw_uid;
                    a->gid = (uint32_t)pw->pw_gid;
                }
            }
            /* The secret does not outlive the check, even on the stack. */
            explicit_bzero(pass, sizeof pass);
        }
        i = (e < n) ? e + 1 : e;
    }
    return (int64_t)n;
}

int64_t hamauth_read(struct hamauth_file *a, uint8_t *buf, uint64_t cap)
{
    /* Snapshot-once, like every other status file here: the answer is read
     * after the credential is written, and a second read is EOF. */
    if (a->drained) return 0;
    const char *ans = a->ok ? "ok\n" : "no\n";
    size_t n = strlen(ans);
    if (n > cap) n = cap;
    memcpy(buf, ans, n);
    a->drained = 1;
    return (int64_t)n;
}

int32_t hamauth_become(struct hamauth_file *a)
{
    if (!a->ok) {
        errno = EPERM;
        return -1;
    }
    /* The whole identity, in the only order that works: supplementary groups
     * and the gid while there is still privilege to change them, the uid
     * last. See the note at sys_setuid -- a drop that moves the uid and
     * leaves the group behind reads as success and is not one. */
    if (geteuid() == 0) {
        if (setgroups(0, NULL) < 0 && errno != EPERM) return -1;
        if (initgroups(a->user, (gid_t)a->gid) < 0 && errno != EPERM) {
            /* Not fatal: the account simply gets no supplementary groups,
             * which is the safe direction to fail in. */
        }
        if (setgid((gid_t)a->gid) < 0 && errno != EPERM) return -1;
    }
    if (setuid((uid_t)a->uid) < 0)
        return -1;
    /* Spend the capability. Holding a verified fd must not let a process
     * change identity twice -- `su` to one account and then to another
     * without a second password. */
    a->ok = 0;
    return 0;
}
