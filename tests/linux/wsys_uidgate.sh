#!/usr/bin/env bash
# tests/linux/wsys_uidgate.sh — the uid gate on /dev/wsys, measured.
#
# WHAT IS UNDER TEST.  user/linux-wsys.c's port of devwsys.ad's
# current_task_is_hostowner() gate.  Before it, /dev/wsys's 0666 file mode was
# the whole access control, so the `live` uid that /etc/rc.de-user drops the
# session to could drive the SYSTEM CHROME verbs -- lock the screen, queue a
# spawn, post a notification, retitle another process's window -- by echoing a
# line into a file.  After it, those are refused and the ordinary client
# operations (map my own window, draw in it) still work, because an
# unprivileged session that cannot draw is worse than the hole.
#
# HOW THE TWO UIDS ARE GOT WITHOUT ROOT.  A user namespace with three uids
# mapped out of /etc/subuid: inner 0 (the compositor's identity on a real
# boot), inner 1001 (`live`), inner 1002 (a second unprivileged user).  Every
# process is really the same host user, so nothing here can touch the host's
# display, /dev/dri or /srv -- the segment is a file in a temp dir named by
# $HAMWSYS.
#
# TWO ARMS, because "host owner" on this line is the uid that OWNS THE
# SEGMENT, not a hardcoded 0:
#   A. real-boot shape   segment created by root; 1001 must be refused.
#   B. harness shape     segment created by unprivileged 1001 (this is what
#                        the offscreen bench and any single-uid run look
#                        like); 1001 must be ALLOWED and 1002 refused.
# Arm B is the one that proves the gate did not simply become "deny non-root",
# which would have broken every offscreen run of the compositor.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && cd .. && pwd)"
cd "$PROJ_ROOT"

fail=0
note() { printf '%s\n' "$*"; }
ok()   { printf '  ok   %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*"; fail=1; }

# ---- inner half: runs inside the namespace -------------------------------
if [ "${1:-}" = "--inner" ]; then
    W="$2"
    PROBE="$W/wsys_uidgate"
    # <tag> <uid> <probe args...> -> one line: "== <tag> <output> exit=<rc>"
    r() {
        local tag="$1" u="$2"; shift 2
        local o rc
        if [ "$u" = 0 ]; then o="$("$PROBE" "$@" 2>&1)"; rc=$?
        else o="$(setpriv --reuid="$u" --regid="$u" --clear-groups \
                          "$PROBE" "$@" 2>&1)"; rc=$?; fi
        echo "== $tag $o exit=$rc"
    }
    # The segment must be THE ONE WE NAMED.  shm_attach falls back to
    # /dev/shm and /tmp when $HAMWSYS cannot be opened, and a fallback here
    # would mean every uid quietly got its own private window system and
    # every assertion below passed for the wrong reason.
    seg_check() {
        [ -s "$1" ] && echo "== seg[$1] present" || echo "== seg[$1] MISSING"
    }

    # ---- arm A: the segment belongs to root (rc.5 starts wsysd first) ----
    export HAMWSYS="$W/segA"
    rm -f "$HAMWSYS" "$HAMWSYS".bb
    r armA.root.chrome 0 chrome /dev/wsys/ctl 'lock 1 0'
    seg_check "$HAMWSYS"
    # A window for the unprivileged side to be refused on: root opens one.
    r armA.root.client 0 client
    for v in 'lock 1 0' 'run 1 /bin/hamsh' 'notif 1 255 hi' 'appmenu x' \
             'setapp 2 /bin/x' 'ws 2' 'kbd 1' 'screen 1 1' 'free 2'; do
        r "armA.live.ctl[$v]" 1001 chrome /dev/wsys/ctl "$v"
    done
    for p in /dev/wsys/lock /dev/wsys/notif /dev/wsys/cycler/show \
             /dev/wsys/appmenu /dev/wsys/wsysd/state /dev/wsys/2/ctl \
             /dev/wsys/2/scene /dev/wsys/2/keys /dev/wsys/2/draw/ctl; do
        r "armA.live.sink[$p]" 1001 chrome "$p" 'x'
    done
    # The channels devwsys deliberately leaves open to any uid.
    for p in /dev/wsys/appmenu/launch /dev/wsys/run/launch /dev/wsys/post \
             /dev/wsys/lock/verify; do
        r "armA.live.open[$p]" 1001 chrome "$p" 'hunter2'
    done
    r armA.live.client 1001 client

    # ---- arm B: the segment belongs to an unprivileged user --------------
    export HAMWSYS="$W/segB"
    rm -f "$HAMWSYS" "$HAMWSYS".bb
    r armB.owner.chrome 1001 chrome /dev/wsys/ctl 'lock 1 0'
    seg_check "$HAMWSYS"
    r armB.owner.client 1001 client
    r armB.other.chrome 1002 chrome /dev/wsys/ctl 'lock 1 0'
    r armB.other.client 1002 client
    exit 0
fi

# ---- outer half ----------------------------------------------------------
BIN="${WSYS_UIDGATE_BIN:-}"
W="$(mktemp -d "${TMPDIR:-/tmp}/wsysgate.XXXXXX")"
trap 'rm -rf "$W"' EXIT
# 1777, not 755: three different uids each create their own segment in here,
# and a uid that cannot create $HAMWSYS falls back to /dev/shm -- which both
# leaks a file and makes the test measure a private window system instead of
# the shared one.
chmod 1777 "$W"
if [ -z "$BIN" ]; then
    ./scripts/hamlinux_build.sh tests/linux/wsys_uidgate.ad "$W/wsys_uidgate" \
        >"$W/build.log" 2>&1 || { cat "$W/build.log"; echo "BUILD FAILED"; exit 2; }
else
    cp "$BIN" "$W/wsys_uidgate"
fi
chmod 755 "$W/wsys_uidgate"
cp "$0" "$W/inner.sh"; chmod 755 "$W/inner.sh"

command -v unshare >/dev/null || { echo "SKIP: no unshare(1)"; exit 0; }
grep -q "^$(id -un):" /etc/subuid 2>/dev/null || {
    echo "SKIP: no /etc/subuid range for $(id -un); run this in the VM instead"
    exit 0; }
SUB="$(awk -F: -v u="$(id -un)" '$1==u{print $2; exit}' /etc/subuid)"
OUT="$W/out.txt"
unshare -U \
    --map-users=0:"$(id -u)":1     --map-groups=0:"$(id -g)":1 \
    --map-users=1001:"$SUB":1      --map-groups=1001:"$SUB":1 \
    --map-users=1002:"$((SUB+1))":1 --map-groups=1002:"$((SUB+1))":1 \
    -- "$W/inner.sh" --inner "$W" >"$OUT" 2>&1
rc=$?
cat "$OUT"
[ $rc -eq 0 ] || { echo "namespace setup failed (rc=$rc)"; exit 2; }

# A line "== <name> ... write=<rc> exit=<n>".  Refused means a negative rc
# from open or write AND a nonzero exit; allowed means neither.
refused() { grep -q "^== $1" "$OUT" && grep "^== $1" "$OUT" | grep -q -- "=-"; }
allowed() { grep "^== $1" "$OUT" | grep -q "exit=0"; }

note "chrome verbs, refused to a non-owner uid (the hole, closed):"
for v in 'lock 1 0' 'run 1 /bin/hamsh' 'notif 1 255 hi' 'appmenu x' \
         'setapp 2 /bin/x' 'ws 2' 'kbd 1' 'screen 1 1' 'free 2'; do
    if refused "armA.live.ctl\[$v\]"; then ok "ctl $v"; else bad "ctl $v NOT refused"; fi
done
for p in /dev/wsys/lock /dev/wsys/notif /dev/wsys/cycler/show \
         /dev/wsys/appmenu /dev/wsys/wsysd/state /dev/wsys/2/ctl \
         /dev/wsys/2/scene /dev/wsys/2/keys /dev/wsys/2/draw/ctl; do
    if refused "armA.live.sink\[$p\]"; then ok "write $p"; else bad "write $p NOT refused"; fi
done

note "client->compositor channels devwsys leaves open to any uid:"
for p in /dev/wsys/appmenu/launch /dev/wsys/run/launch /dev/wsys/post \
         /dev/wsys/lock/verify; do
    if allowed "armA.live.open\[$p\]"; then ok "write $p"; else bad "write $p refused"; fi
done

note "the segment under test is the named one, not a private fallback:"
if ! grep -q "MISSING" "$OUT"; then ok "both segments created at \$HAMWSYS"
else bad "shm_attach fell back -- the test measured a private segment"; fi
# Two uids on ONE segment allocate DIFFERENT wids.  Equal wids would mean each
# had quietly attached to a private segment of its own, which is how this
# whole test can pass while measuring nothing (fs.protected_regular refuses
# the O_CREAT of another uid's file in a sticky dir; see shm_attach).
widof() { grep "^== $1 " "$OUT" | sed -n 's/.* wid=\([0-9-]*\).*/\1/p' | head -1; }
for pair in "armA.root.client armA.live.client" "armB.owner.client armB.other.client"; do
    set -- $pair
    a="$(widof "$1")"; b="$(widof "$2")"
    if [ -n "$a" ] && [ -n "$b" ] && [ "$a" != "$b" ]; then
        ok "$1/$2 share one segment (wid $a vs $b)"
    else
        bad "$1/$2 got wid '$a' and '$b' -- separate segments, test is blind"
    fi
done

note "the DE must still work:"
if allowed armA.root.chrome; then ok "root drives chrome";     else bad "root refused chrome"; fi
if allowed armA.root.client; then ok "root maps+draws";        else bad "root client broke"; fi
if allowed armA.live.client; then ok "live maps+draws its own window";
                              else bad "live client broke -- BLIND SESSION"; fi
if allowed armB.owner.chrome; then ok "segment owner (non-root) drives chrome";
                              else bad "single-uid/offscreen run broke"; fi
if allowed armB.owner.client; then ok "segment owner maps+draws"; else bad "armB owner client broke"; fi
if refused armB.other.chrome; then ok "a third uid is refused chrome";
                              else bad "armB other NOT refused"; fi
if allowed armB.other.client; then ok "a third uid still maps+draws its own window";
                              else bad "armB other client broke"; fi

[ $fail -eq 0 ] && echo "PASS wsys_uidgate" || echo "FAIL wsys_uidgate"
exit $fail
