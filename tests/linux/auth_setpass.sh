#!/usr/bin/env bash
# Its host runtime and its pass/fail were NOT measured when this line was
# written. If you make it cheap enough for the battery, add the manifest line
# and delete this block.
#
# tests/linux/auth_setpass.sh — /dev/auth's `setpass` verb, and its GATE.
#
# `passwd` could not change a password on this port at all: user/linux-auth.c
# served `user` and `pass` only, so user/passwd.ad's `setpass <new>` was
# refused and the run sweep scored it EXIT_NONZERO with the program naming the
# missing verb. The verb is served now, and a password-setting device is worth
# exactly what its authorisation check is worth -- so this asserts the check,
# not just the feature.
#
# FOUR ARMS, and the last two are the security ones:
#
#   1. root sets `live`'s password          -> the shadow line is a fresh $6$
#                                              hash, EVERY OTHER LINE is
#                                              byte-identical, mode stays 0600
#   2. the NEW secret authenticates and the OLD one does not (through `su`,
#      which drives `user` + `pass` on the same device)
#   3. uid 1001 (`live`) sets `dave`'s password  -> REFUSED, dave unchanged
#   4. uid 1001 (`live`) sets its OWN password   -> allowed
#
# Arms 3 and 4 need a namespace in which BOTH uid 0 and uid 1001 exist: root
# to build the chroot, 1001 to be the caller the gate judges. That needs a
# subuid range (/etc/subuid) and util-linux's --map-users; without one the two
# arms SKIP by name rather than passing quietly.
#
# Host-only, seconds, no VM. Run from the repository root.
set -uo pipefail
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ"

WORK="${HAMLINUX_WORK:-${TMPDIR:-/tmp}}/auth_setpass.$$"
B="$WORK/root"
mkdir -p "$WORK"
cleanup() { chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
# A bare EXIT trap does not run when the shell is killed by a signal, so a
# gate stopped by `timeout` (TERM) or ^C (INT) skipped its cleanup entirely.
# Re-exit on those, which makes the EXIT trap above run on every path out.
trap 'exit 130' INT TERM HUP

PASS=0; FAIL=0; SKIP=0
ok()   { echo "PASS: $*"; PASS=$((PASS+1)); }
bad()  { echo "FAIL: $*"; FAIL=$((FAIL+1)); }
skip() { echo "SKIP: $*"; SKIP=$((SKIP+1)); }

echo "[auth_setpass] building passwd and su"
for p in passwd su; do
    scripts/hamlinux_build.sh "user/$p.ad" "$WORK/$p.elf" >"$WORK/$p.log" 2>&1 \
        || { echo "FATAL: could not build user/$p.ad -- see $WORK/$p.log"; exit 2; }
done

stage() {
    rm -rf "$B"; mkdir -p "$B"/{bin,etc,dev,proc,tmp,work,home/live}
    install -m755 "$WORK/passwd.elf" "$B/bin/passwd"
    install -m755 "$WORK/su.elf"     "$B/bin/su"
    [ -x /usr/bin/setpriv ] && install -m755 /usr/bin/setpriv "$B/bin/setpriv"
    install -m644 etc/passwd "$B/etc/passwd"
    install -m600 etc/shadow "$B/etc/shadow"
    for p in "$B"/bin/*; do ldd "$p" 2>/dev/null | awk '/=> \//{print $3}'; done \
        | sort -u | while read -r l; do
            mkdir -p "$B$(dirname "$l")"; cp -Ln "$l" "$B$l" 2>/dev/null
          done
    local I
    I="$(readelf -l "$B/bin/passwd" | awk -F': *' '/interpreter/{sub(/\]$/,"",$2);print $2}')"
    mkdir -p "$B$(dirname "$I")"; cp -L "$I" "$B$I"
    cp -L /etc/ld.so.cache   "$B/etc/ld.so.cache"   2>/dev/null
    cp -L /etc/nsswitch.conf "$B/etc/nsswitch.conf" 2>/dev/null
    cp -L /lib/x86_64-linux-gnu/libnss_files.so.2 \
          "$B/lib/x86_64-linux-gnu/libnss_files.so.2" 2>/dev/null
    : > "$B/dev/null"; : > "$B/dev/urandom"
}

# As root-in-a-user-namespace.
as_root() {  # as_root <stdin> <argv...>
    local sin="$1"; shift
    printf '%b' "$sin" | unshare -rm --fork --pid bash -c \
      "mount --bind /dev/null '$B/dev/null'; mount --bind /dev/urandom '$B/dev/urandom'; unshare --root='$B' --wd=/work -- $*" 2>&1
}

# As uid 1001 inside the same root. /etc is made writable for these arms
# deliberately: the gate under test is the DEVICE's, and on this port the
# device runs with the caller's own credentials, so a directory-permission
# denial from the filesystem would mask whichever way the gate went (that
# asymmetry is documented at the head of user/linux-auth.c).
as_live() {  # as_live <stdin> <argv...>
    local sin="$1"; shift
    chmod 777 "$B/etc"; chmod 666 "$B/etc/shadow"
    printf '%b' "$sin" | unshare --user --mount --fork --pid \
        --map-users="0:$(id -u):1" --map-users=1001:100000:1 \
        --map-groups="0:$(id -g):1" --map-groups=1001:100000:1 \
        -- bash -c "mount --bind /dev/null '$B/dev/null'; mount --bind /dev/urandom '$B/dev/urandom'; unshare --root='$B' --wd=/work -- /bin/setpriv --reuid=1001 --regid=1001 --clear-groups $*" 2>&1
    # A file this arm rewrote is now owned by uid 1001, i.e. by a subuid this
    # user cannot read from outside the namespace. Take it back, inside one,
    # so the assertions below can still read what happened.
    unshare --user --mount --fork \
        --map-users="0:$(id -u):1" --map-users=1001:100000:1 \
        --map-groups="0:$(id -g):1" --map-groups=1001:100000:1 \
        -- chown -R 0:0 "$B/etc" 2>/dev/null
}

hash_of() { grep "^$2:" "$1" | cut -d: -f2; }

# --- 1. root sets live's password -----------------------------------------
stage
BEFORE_LIVE="$(hash_of "$B/etc/shadow" live)"
BEFORE_REST="$(grep -v '^live:' "$B/etc/shadow" | md5sum)"
out="$(as_root 'newpass123\nnewpass123\n' /bin/passwd live)"; rc=$?
AFTER_LIVE="$(hash_of "$B/etc/shadow" live)"
AFTER_REST="$(grep -v '^live:' "$B/etc/shadow" | md5sum)"
if [ "$rc" = 0 ] && [ "$AFTER_LIVE" != "$BEFORE_LIVE" ] \
   && [ "${AFTER_LIVE:0:3}" = '$6$' ]; then
    ok "root set live's password; the hash is a fresh \$6\$ and it changed"
else
    bad "root could not set live's password (rc=$rc): $out"
fi
[ "$AFTER_REST" = "$BEFORE_REST" ] \
    && ok "every other /etc/shadow line is byte-identical" \
    || bad "other /etc/shadow lines changed -- setpass rewrote more than its own"
[ "$(stat -c%a "$B/etc/shadow")" = 600 ] \
    && ok "/etc/shadow is still mode 0600" \
    || bad "/etc/shadow mode is now $(stat -c%a "$B/etc/shadow"), not 0600"
# The aging field is somebody's data and setpass does not own it.
[ "$(grep '^live:' "$B/etc/shadow" | cut -d: -f3)" = 19900 ] \
    && ok "the aging field is untouched" \
    || bad "the aging field was rewritten"

# --- 2. the new secret authenticates, the old one does not ----------------
# `su` prints "Authentication failure" when /dev/auth says no, and gets past it
# (to the identity change, which a user namespace with only uid 0 mapped
# cannot complete) when it says yes. It is the AUTHENTICATION line that is
# under test here, so that is the line asserted.
newout="$(as_live 'newpass123\n' /bin/su live /bin/passwd)"
oldout="$(as_live 'hamnix\n'     /bin/su live /bin/passwd)"
if [ "${newout#*Authentication failure}" = "$newout" ]; then
    ok "the NEW password authenticates through /dev/auth"
else
    bad "the new password did NOT authenticate: $newout"
fi
if [ "${oldout#*Authentication failure}" != "$oldout" ]; then
    ok "the OLD password no longer authenticates"
else
    bad "the OLD password still authenticates -- the hash was not really replaced: $oldout"
fi

# --- 3 & 4. the gate ------------------------------------------------------
if ! grep -q "^$(id -un):" /etc/subuid 2>/dev/null; then
    skip "no /etc/subuid range for $(id -un) -- cannot run as uid 1001, so the setpass GATE is untested here"
else
    stage
    DAVE_BEFORE="$(hash_of "$B/etc/shadow" dave)"
    out3="$(as_live 'zzz11111\nzzz11111\n' /bin/passwd dave)"
    if [ "$(hash_of "$B/etc/shadow" dave)" = "$DAVE_BEFORE" ]; then
        ok "uid 1001 could NOT set dave's password (the gate held)"
    else
        bad "uid 1001 CHANGED dave's password -- the setpass gate does not hold"
    fi
    LIVE_BEFORE="$(hash_of "$B/etc/shadow" live)"
    out4="$(as_live 'selfpass99\nselfpass99\n' /bin/passwd live)"
    if [ "$(hash_of "$B/etc/shadow" live)" != "$LIVE_BEFORE" ]; then
        ok "uid 1001 set its OWN password (the self case is allowed)"
    else
        bad "uid 1001 could not set its own password: $out4"
    fi
fi

echo
echo "[auth_setpass] $PASS PASS, $FAIL FAIL, $SKIP SKIP"
[ "$FAIL" = 0 ]
