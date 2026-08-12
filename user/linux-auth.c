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

/* --- setpass: the hostowner-or-self password SET --------------------------
 *
 * docs/security.md: the device is the SOLE WRITER of the shadow secret,
 * mirroring how it is the sole reader. `passwd` (user/passwd.ad) drives it as
 *
 *     write(fd, "user <name>\n")
 *     write(fd, "setpass <plaintext>\n")
 *     read(fd)              -> "ok" / "no"
 *
 * and never sees a hash. This is the faithful port of Hamnix's own
 * `_au_setpass` (sys/src/9/port/devauth.ad): a fresh $6$<16-char-salt>$ hash
 * replaces the target's field in the LIVE /etc/shadow, every other line kept
 * verbatim, and the `!` of a locked account is what it replaces.
 *
 * WHY IT WAS MISSING AND WHAT THAT COST. This device served `user` and `pass`
 * only, so `passwd` could not change a password on this port AT ALL -- it is
 * the one row in the run sweep whose failure was the port's own core command
 * being absent rather than a device Linux does not have. Worse, before the
 * unknown-verb refusal landed the write was ACCEPTED and the status read then
 * said "no", so passwd reported "not authorised, or no such user": an
 * authorisation decision that was never taken, for a verb that did not exist.
 *
 * THE GATE, and it is the whole of the security of this:
 *
 *   * uid 0 or uid 1 may set anyone's password. On Hamnix uid 1 is the
 *     hostowner and uid 0 does not exist (etc/passwd says so); on Linux root
 *     is 0. Both are accounts that can already open /etc/shadow for writing
 *     with their own hands, so this grants them nothing they did not have.
 *   * anyone else may set THEIR OWN password and no one else's, decided by
 *     resolving the named account through getpwnam(3) and comparing uids.
 *   * everything else is refused, and the refusal is "no", not a crash.
 *
 * AND ONE THING THE GATE CANNOT DECIDE ON ITS OWN, because on this port the
 * device is not a kernel: linux-auth.c is linked INTO each program, so the
 * rewrite below happens with the CALLING PROCESS's credentials. /etc is
 * root-owned 0755 on a real machine, so an ordinary user who is authorised
 * here still cannot create the temporary file -- measured: uid 1001 setting
 * its own password is allowed by the gate and then fails at mkstemp(3), and
 * succeeds the moment /etc is writable. On Hamnix the kernel does the write
 * and the question does not arise. Closing it on this line means either a
 * setuid /bin/passwd or serving /dev/auth from a privileged process, and
 * both are decisions bigger than this file. Until one is made, `passwd`
 * works for root/hostowner and refuses -- loudly, with the message it always
 * printed -- for a user changing their own password on a stock /etc.
 *
 * WHAT THIS DOES NOT DO, said out loud because the difference is real:
 * passwd(1) asks a non-root user for their CURRENT password first, and this
 * does not -- it matches Hamnix's contract, where possession of the session
 * is the proof. So on both kernels an unattended logged-in shell can change
 * that user's own password. Fixing it is a change to this device plus a
 * prompt in user/passwd.ad, and the shape is already here: require `pass
 * <old>` to have set a->ok for the same name before honouring the self case.
 * It is not done here rather than being quietly implied.
 */

/* The crypt-base64 salt alphabet: '.', '/', '0'-'9', 'A'-'Z', 'a'-'z' --
 * exactly the 64 characters glibc's $6$ salt is drawn from. */
static void salt_alphabet(char out[64])
{
    int i, k = 0;
    out[k++] = '.';
    out[k++] = '/';
    for (i = 0; i < 10; i++) out[k++] = (char)('0' + i);
    for (i = 0; i < 26; i++) out[k++] = (char)('A' + i);
    for (i = 0; i < 26; i++) out[k++] = (char)('a' + i);
}

/* "$6$<16 random chars>" into `out` (>= 20 bytes). Returns 0, or -1 if the
 * kernel would not give us randomness -- in which case NO password is set. A
 * predictable salt is a weaker hash, so this fails closed rather than falling
 * back to the clock. */
static int gen_salt(char *out, size_t cap)
{
    if (cap < 20) return -1;
    unsigned char rnd[16];
    int fd = open("/dev/urandom", O_RDONLY);
    if (fd < 0) return -1;
    size_t got = 0;
    while (got < sizeof rnd) {
        ssize_t r = read(fd, rnd + got, sizeof rnd - got);
        if (r <= 0) { close(fd); return -1; }
        got += (size_t)r;
    }
    close(fd);
    char alpha[64];
    salt_alphabet(alpha);
    out[0] = '$'; out[1] = '6'; out[2] = '$';
    for (int i = 0; i < 16; i++)
        out[3 + i] = alpha[rnd[i] & 63];
    out[19] = '\0';
    explicit_bzero(rnd, sizeof rnd);
    return 0;
}

/* May `caller` set `name`'s password? See THE GATE above. */
static int setpass_allowed(const char *name, uid_t caller)
{
    if (caller == 0 || caller == 1)
        return 1;
    struct passwd *pw = getpwnam(name);
    return pw && (uid_t)pw->pw_uid == caller;
}

/* Rewrite /etc/shadow with `name`'s hash field replaced by `hash`. Every other
 * line, and every other field of this line, is copied byte for byte -- the
 * aging fields are somebody's data and this is not the program that owns them.
 *
 * Through a temporary in the SAME DIRECTORY and rename(2), so a crash or a
 * full disk leaves the old file intact: a half-written /etc/shadow is an
 * unbootable machine. Mode 0600 is set on the temp BEFORE any secret is in it.
 *
 * Returns 1 on success, 0 on any failure -- including "no line for that user",
 * which is deliberate: useradd creates the locked stub, and setting a password
 * for an account that was never added would create a shadow entry with no
 * passwd entry behind it. */
static int shadow_setpass(const char *name, const char *hash)
{
    FILE *f = fopen("/etc/shadow", "r");
    if (!f) return 0;

    char tmp[] = "/etc/.shadow.hamauth.XXXXXX";
    int tfd = mkstemp(tmp);
    if (tfd < 0) { fclose(f); return 0; }
    if (fchmod(tfd, 0600) < 0) { close(tfd); unlink(tmp); fclose(f); return 0; }
    FILE *t = fdopen(tfd, "w");
    if (!t) { close(tfd); unlink(tmp); fclose(f); return 0; }

    char line[4096];
    size_t nl = strlen(name);
    int replaced = 0, werr = 0;
    while (fgets(line, sizeof line, f)) {
        if (!replaced && !strncmp(line, name, nl) && line[nl] == ':') {
            /* name:HASH:rest... -- rewrite only the middle field. */
            char *h = line + nl + 1;
            char *rest = strchr(h, ':');
            if (fprintf(t, "%s:%s:%s", name, hash, rest ? rest + 1 : "\n") < 0)
                werr = 1;
            replaced = 1;
        } else if (fputs(line, t) == EOF) {
            werr = 1;
        }
    }
    fclose(f);
    /* fflush + fsync before the rename: a rename that lands before the bytes
     * do is how a power cut produces an empty /etc/shadow. */
    if (fflush(t) != 0 || fsync(fileno(t)) != 0) werr = 1;
    if (fclose(t) != 0) werr = 1;

    if (!replaced || werr) { unlink(tmp); return 0; }
    if (rename(tmp, "/etc/shadow") < 0) { unlink(tmp); return 0; }
    return 1;
}

int64_t hamauth_write(struct hamauth_file *a, const uint8_t *buf, uint64_t n)
{
    /* One verb per line: `user <name>` then `pass <secret>`.
     *
     * AN UNRECOGNISED VERB IS REFUSED, and it used to be swallowed: any line
     * that matched neither prefix fell out of the loop and the write returned
     * `n` -- "all your bytes were accepted" -- for a verb this device does not
     * implement. That is the ignored-ctl-verb defect that cost this port its
     * desktop backdrop (`background`/`pin` was never ported, an unknown verb
     * was IGNORED, and hamdesktop painted an opaque full-screen window over
     * every application with every return code 0; HANDOFF §0).
     *
     * What it hid here, measured: `user/passwd.ad` writes `setpass <new>`,
     * which this device did not serve. The write said it worked, the status
     * read then said "no", and passwd reported "password change denied (not
     * authorised, or no such user)" -- naming an authorisation failure for a
     * verb that did not exist. EINVAL says the true thing. `setpass` IS
     * served now (see below), so the only lines that reach EINVAL are ones
     * this device really does not implement. */
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
            a->spok = 0;
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
        } else if (len > 8 && !memcmp(buf + i, "setpass ", 8)) {
            /* Requires the `user <name>` line first: there is no default
             * target, because guessing one would be a password change on an
             * account nobody named. */
            char newpw[512];
            size_t k = len - 8;
            if (k >= sizeof newpw) k = sizeof newpw - 1;
            memcpy(newpw, buf + i + 8, k);
            newpw[k] = '\0';
            a->spok = 0;
            if (a->user[0] && setpass_allowed(a->user, getuid())) {
                char salt[24], *got = NULL;
                struct crypt_data cd;
                memset(&cd, 0, sizeof cd);
                if (gen_salt(salt, sizeof salt) == 0)
                    got = crypt_r(newpw, salt, &cd);
                if (got && got[0] == '$')
                    a->spok = shadow_setpass(a->user, got);
                explicit_bzero(&cd, sizeof cd);
                explicit_bzero(salt, sizeof salt);
            }
            /* The plaintext does not outlive the call, whatever happened. */
            explicit_bzero(newpw, sizeof newpw);
            /* NOT `a->ok`. See the note on `spok` in linux-auth.h: changing an
             * account's password must never be a way to become it. */
        } else if (e < n && len > 0) {
            /* A COMPLETE line -- newline seen -- that names no verb we serve.
             * A trailing fragment is NOT judged: a client may split a verb
             * across write(2) calls, and refusing half a line would break a
             * caller that is doing nothing wrong. */
            errno = EINVAL;
            return -1;
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
    /* `ok` OR `spok`: a verified credential and a completed password change
     * both answer "ok" to the reader, and only the first of the two is a
     * capability -- hamauth_become() consults `ok` alone. */
    const char *ans = (a->ok || a->spok) ? "ok\n" : "no\n";
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
