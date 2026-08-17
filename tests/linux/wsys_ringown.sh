#!/usr/bin/env bash
#
# REGISTRATION, 2026-08-17. Until this date scripts/test_gate_registration.sh
# globbed only scripts/test_*.sh, so this directory was invisible to the gate
# against unregistered gates and every file in it read as coverage without
# being coverage. This gate is ON-DEMAND: not in ci_battery_manifest.txt
# because nobody has measured its host runtime yet, and the battery is 12-way
# sharded under a 50-minute cap -- registering an unmeasured gate is how a
# shard goes from green to timed-out. Measure it, then move it into the
# manifest.
#
# Its host runtime and its pass/fail were NOT measured when this line was
# written. If you make it cheap enough for the battery, add the manifest line
# and delete this block.
#
# tests/linux/wsys_ringown.sh — the four rings that had no owner check at all.
#
# WHAT WAS MEASURED, AND IT IS THE REASON THIS FILE EXISTS.  With the mediator
# live and the read server forked, an attacker at uid 1002 owning no window
# opened /dev/wsys/<victim>/event and was handed the compositor's own
# `geometry 100 100 300 200` out of another uid's queue.  user/linux-wsys.c's
# ring_read() asked nothing of anybody on pointer / event / text / cmd, and
# hamwsys_open's WIN_* arm fell through `win_find` to a bare `return 0`.
# `keys` was the only ring with a check -- and only because it is no longer in
# the shared segment at all, so the one ring that MOVED got a gate and the four
# that stayed behind did not.
#
# WHAT THE RINGS CARRY, which is why this is confidentiality and not tidiness.
# `event` is the compositor's narration of the window (geometry, focus in/out,
# close requests); `pointer` is every cursor position and button state over it;
# `text` is committed text input; `cmd` is the /dev/cons routing channel
# (user/hamUI.ad:19).  Reading another window's `pointer` is following the
# user's mouse across somebody else's application, and reading its `text` is a
# keylogger through the one channel THE KEYSTROKE CHANNEL did not move.
#
# THE PREDICATE UNDER TEST is `hostowner() || owns_wid(wid)` -- deliberately the
# one already in this file rather than a second mechanism.  It is byte-for-byte
# the gate hamwsys_open already applies to WRITING these same four rings, and
# the gate on <wid>/wctl and <wid>/draw/ctl.  This gate drives the two halves
# that make it the right one:
#
#   REFUSES  a uid-1002 process that owns no window and is not in the victim's
#            descent -- the measured attacker, reproduced.
#   ADMITS   the compositor, which legitimately touches rings for windows it
#            does not own (user/wsysd.ad's route_pointer_event and
#            route_focus_event open /dev/wsys/<wid>/event and .../pointer for
#            any focused wid).  It is admitted as the HOST OWNER: /dev/wsys is
#            the file /srv/wsys and wsysd created it.  Here the segment is
#            created by inner uid 0, which is what wsysd is on a real boot.
#   ADMITS   the window's own owner -- and the owner arm runs AT uid 1002, the
#            same uid the red arm refuses.  That pairing is the point: it shows
#            the refusal is about OWNERSHIP and not about uid 1002 being marked.
#
# WHAT THIS GATE DOES NOT CLAIM, said before anybody reads a PASS as more than
# it is.  The check is INSIDE A LIBRARY that every client links, so it binds a
# process that goes through the /dev/wsys file protocol and nothing else.
# tests/linux/wsys_bypass.sh drives a program that skips the protocol, maps
# /srv/wsys itself and asserts that it SUCCEEDS -- that attacker reads these
# four rings straight out of the mapping and no `if` in user/linux-wsys.c is in
# its way.  Nor are these leaves routed: srv_route_read carries SCREEN, POOL and
# WINDOWS and nothing else, so there is no server-side copy of the question.
# THE HOLE IS NARROWED, NOT CLOSED, and docs/wsys_server_design.md's stage 4
# names the mapping as the precondition for closing it.
#
# AND ONE MORE THING IT DOES NOT CLOSE: owns_wid() NEVER COMPARES A uid.  A
# uid-1002 DESCENDANT of the window's owner still passes, exactly as stage 5
# records -- and on a real desktop every application is a descendant of the
# compositor.  It is not closed here because struct wwin records `int32_t pid`
# and no uid at all, and the struct is byte-for-byte what versions 6 and 7 had:
# an owner-uid field changes sizeof(struct wwin) and costs a WSYS_VERSION bump.
#
# THAT RESIDUAL IS NOT MEASURED BY THIS GATE, and the run prints so rather than
# letting a PASS imply otherwise.  It cannot be: a wid is stamped against the
# process that called `newwindow`, and the probe never forks, so every uid-1002
# process this harness can build is a SIBLING of the victim and not a
# descendant of it.  Driving it needs the DE's on-behalf path (`alloc <pid>` on
# ctl, which stamps a row against a shell that CAN spawn), and that is a
# separate gate.  Claiming it here would be describing a hole and calling it a
# measurement.
#
# HOW THE UIDS ARE GOT WITHOUT ROOT.  The three-id `unshare -U` shape that
# tests/linux/wsys_uidgate.sh and wsys_enum_policy.sh already use: inner 0 (the
# compositor's identity on a real boot), inner 1001 (the victim) and inner 1002
# (the attacker, and later the owner of its own window), mapped out of
# /etc/subuid.  Every process is really the same host user, so nothing here can
# reach the host's /srv, its display or /dev/dri -- the segment is a file in a
# temp directory named by $HAMWSYS.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

fail=0
note() { printf '%s\n' "$*"; }
ok()   { printf '  ok   %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*"; fail=1; }

# The needles.  EVENT's is the exact string the measurement recovered from
# another uid's queue, so a hit on it here is that finding reproduced verbatim.
EVN='geometry 100 100 300 200'
PTN='m 640 400 1 0'
TXN='TEXTSECRET31337'
CMN='CMDSECRET31337'

# ---- inner half: runs inside the namespace -------------------------------
if [ "${1:-}" = "--inner" ]; then
    W="$2"
    PROBE="$W/wsys_uidgate"
    export HAMWSYS="$W/seg"
    # HAMWSYS_BB explicitly, for the reason wsys_bypass.sh gives: bb_attach has
    # its own candidate list and with this unset it falls through /srv to the
    # HOST's /dev/shm/hamnix-wsys-bb -- a shared segment outside this gate's own
    # temp directory.
    export HAMWSYS_BB="$HAMWSYS.bb"
    rm -f "$HAMWSYS" "$HAMWSYS".bb "$HAMWSYS".chrome

    # FROM $W, NOT FROM THE TREE.  The inner half is a COPY of this file at
    # $W/inner.sh, so its own $PROJ_ROOT is `/`; a relative source of the
    # reaper here would silently find nothing and install no traps.
    . "$W/reap.sh"
    reap_track "$W/reaped.inner"
    reap_on_exit

    as() { local u="$1"; shift
        if [ "$u" = 0 ]; then "$@" 2>&1
        else setpriv --reuid="$u" --regid="$u" --clear-groups "$@" 2>&1; fi; }

    # `exec` INSIDE THE SUBSHELL, or $! names the wrapper and not the probe.
    # wsys_bypass.sh learned this the hard way: backgrounding a shell function
    # forks twice, so the kill hits the wrapper and ORPHANS the probe.
    as_bg() { local u="$1"; shift
        if [ "$u" = 0 ]; then ( exec "$@" ) &
        else ( exec setpriv --reuid="$u" --regid="$u" --clear-groups "$@" ) & fi
        reap_add $!; }

    # 1. THE HOST OWNER BRINGS THE WINDOW SYSTEM UP, exactly as rc.5 does: inner
    #    uid 0, before anything drops.  This is the write that CREATES the
    #    segment, so uid 0 is the segment owner -- which is what makes uid 0
    #    hostowner() for the rest of the run, i.e. the compositor's identity.
    echo "-- setup, as the host owner (inner uid 0)"
    as 0 "$PROBE" chrome /dev/wsys/ctl 'screen 1280 800' | sed 's/^/== setup./'
    ls -l "$HAMWSYS" 2>&1 | sed 's/^/== ls /'

    # 2. THE VICTIM: a uid-1001 client that owns a window and HOLDS it.  A
    #    window whose owner has exited is not a window (user/linux-wsys.c reaps
    #    a row whose pid is gone), and every step below is a separate process,
    #    so something has to keep holding it.
    #    NO DRAIN FLAG IS EVER CREATED IN THIS GATE, and that is deliberate: the
    #    holder's drain is destructive, and a witness that drained while the
    #    attacker was reading would eat the evidence -- the same mistake that
    #    once made wsys_bypass.sh go GREEN ON THE REVERTED RUN.  Here the holder
    #    must never touch its rings, so the needles stay put.
    echo "-- the victim, a uid-1001 window owner"
    as_bg 1001 "$PROBE" client hold "$W/never.flag" >"$W/victim.out" 2>&1
    VHOLDER=$!
    for _ in $(seq 1 60); do
        grep -q 'commit=' "$W/victim.out" 2>/dev/null && break
        sleep 0.1
    done
    sed 's/^/== victim./' "$W/victim.out"
    VWID="$(sed -n 's/.*wid=\([0-9][0-9]*\).*/\1/p' "$W/victim.out" | head -1)"
    echo "== vwid $VWID"

    # 3. THE COMPOSITOR FILLS THE VICTIM'S RINGS.  This is literally what wsysd
    #    does on every pointer motion and every focus change: it opens
    #    /dev/wsys/<wid>/event and .../pointer for a window it does not own and
    #    writes.  It is allowed through as the host owner, and if THAT ever
    #    stops working the desktop stops receiving input -- so these four writes
    #    are themselves an assertion, checked below.
    fill_rings() {
        as 0 "$PROBE" chrome "/dev/wsys/$VWID/event"   "$EVN" | sed "s|^|== $1.wev.|"
        as 0 "$PROBE" chrome "/dev/wsys/$VWID/pointer" "$PTN" | sed "s|^|== $1.wpt.|"
        as 0 "$PROBE" chrome "/dev/wsys/$VWID/text"    "$TXN" | sed "s|^|== $1.wtx.|"
        as 0 "$PROBE" chrome "/dev/wsys/$VWID/cmd"     "$CMN" | sed "s|^|== $1.wcm.|"
    }
    echo "-- the compositor writes into the victim's four rings"
    fill_rings pre

    # 4. THE RED ARM.  A uid-1002 process that owns NO window, is not in the
    #    victim's descent, and is not the segment owner, reads all four.
    #    UNFIXED this prints the needles -- that is the bug, on the record.
    echo "-- RED: a uid-1002 stranger reads the victim's rings"
    as 1002 "$PROBE" read "/dev/wsys/$VWID/event"   | sed 's/^/== att.event./'
    as 1002 "$PROBE" read "/dev/wsys/$VWID/pointer" | sed 's/^/== att.pointer./'
    as 1002 "$PROBE" read "/dev/wsys/$VWID/text"    | sed 's/^/== att.text./'
    as 1002 "$PROBE" read "/dev/wsys/$VWID/cmd"     | sed 's/^/== att.cmd./'

    # 5. REFILLED BEFORE THE GREEN ARM, and this is the destructive-witness rule
    #    applied forward.  On the UNFIXED tree the red arm above SUCCEEDS, and a
    #    successful ring read DRAINS -- it moves r past the bytes.  Without this
    #    refill the compositor's read below would come back empty on exactly the
    #    run where the attacker succeeded, and the green arm would fail for a
    #    reason that has nothing to do with the compositor's privilege.  Each
    #    arm gets its own needles.
    echo "-- the compositor refills them (the red arm may have drained)"
    fill_rings mid

    # 6. GREEN, HALF ONE: THE COMPOSITOR.  Same four files, same four needles,
    #    a window it does not own -- and it must still be served, or the fix has
    #    broken the desktop rather than protected it.
    echo "-- GREEN: the compositor reads the same rings"
    as 0 "$PROBE" read "/dev/wsys/$VWID/event"   | sed 's/^/== comp.event./'
    as 0 "$PROBE" read "/dev/wsys/$VWID/pointer" | sed 's/^/== comp.pointer./'
    as 0 "$PROBE" read "/dev/wsys/$VWID/text"    | sed 's/^/== comp.text./'
    as 0 "$PROBE" read "/dev/wsys/$VWID/cmd"     | sed 's/^/== comp.cmd./'

    # 7. GREEN, HALF TWO: THE OWNER, AT THE ATTACKER'S OWN uid.  uid 1002 now
    #    allocates a window of its own and reads ITS OWN four rings.  It runs
    #    AFTER the red arm on purpose: during the red arm the attacker had to
    #    own nothing at all, and a window allocated earlier would have made it a
    #    window owner while it was supposed to be a stranger.
    echo "-- GREEN: the owner reads its own rings (at uid 1002, the same uid)"
    OWNFLAG="$W/own.flag"
    rm -f "$OWNFLAG"
    as_bg 1002 "$PROBE" ownring "$OWNFLAG" >"$W/own.out" 2>&1
    OHOLDER=$!
    for _ in $(seq 1 60); do
        grep -q 'wid=' "$W/own.out" 2>/dev/null && break
        sleep 0.1
    done
    OWID="$(sed -n 's/.*wid=\([0-9][0-9]*\).*/\1/p' "$W/own.out" | head -1)"
    echo "== owid $OWID"
    as 0 "$PROBE" chrome "/dev/wsys/$OWID/event"   "$EVN" | sed 's/^/== own.wev./'
    as 0 "$PROBE" chrome "/dev/wsys/$OWID/pointer" "$PTN" | sed 's/^/== own.wpt./'
    as 0 "$PROBE" chrome "/dev/wsys/$OWID/text"    "$TXN" | sed 's/^/== own.wtx./'
    as 0 "$PROBE" chrome "/dev/wsys/$OWID/cmd"     "$CMN" | sed 's/^/== own.wcm./'
    : >"$OWNFLAG"; chmod 666 "$OWNFLAG"
    for _ in $(seq 1 60); do
        grep -q 'ownring.cmd' "$W/own.out" 2>/dev/null && break
        sleep 0.1
    done
    sed 's/^/== own./' "$W/own.out"

    # 8. AND THE SESSION IS NOT BLIND, which is the failure worse than the hole.
    #    The stranger must still read the things that name nobody -- the screen
    #    geometry every client lays itself out against.  A "fix" that refused
    #    this would pass every assertion above and ship a desktop that cannot
    #    lay out a window.
    echo "-- and the stranger is not blinded"
    as 1002 "$PROBE" read /dev/wsys/screen | sed 's/^/== att.screen./'

    kill "$VHOLDER" 2>/dev/null
    kill "$OHOLDER" 2>/dev/null
    exit 0
fi

# ---- outer half ----------------------------------------------------------
# PRIVATE NAMESPACE FIRST -- before $W, before reap.sh, before the build.
# It goes HERE and not beside the `cd` at the head of the file because the inner
# half above is a COPY of this script run as `inner.sh --inner $W` from inside
# the uid namespace: a priv_ns_reexec before that branch would run in the copy
# too, where PRIV_NS_ACTIVE=1 is already exported and the assertion would then
# refuse a /tmp that legitimately contains this run's own $W.
#
# The isolation matters even though this gate is careful with $HAMWSYS: bb_attach
# has its own candidate list, the inner half sets HAMWSYS_BB precisely because
# without it the fallback reaches the HOST's /dev/shm/hamnix-wsys-bb, and /srv is
# on that list too. A tmpfs over /tmp, /dev/shm and /srv removes the fallback
# rather than relying on every future edit to keep remembering it.
#
# THE HELPER'S ONE FIDELITY COST DOES NOT REACH THIS GATE: priv_ns_reexec makes
# geteuid() 0 in the OUTER shell, and every arm here runs in the INNER namespace
# this file builds for itself, where the compositor is 0, the victim is 1001 and
# the attacker is 1002 exactly as before.
. tests/linux/private_ns.sh
priv_ns_reexec "$@"
W="$(mktemp -d "${TMPDIR:-/tmp}/wsysringown.XXXXXX")"
. tests/linux/reap.sh
reap_on_exit_cleanup() { rm -rf "$W"; }
reap_on_exit reap_on_exit_cleanup
# 1777 for the reason wsys_uidgate.sh needs it: three uids create files in here,
# and /srv on a real boot is 1777 too.
chmod 1777 "$W"

# WSYS_UIDGATE_BIN is how the RED arm is driven against the UNFIXED tree: build
# the probe from a tree without the check and point this at it.  Same hook
# wsys_bypass.sh offers, and for the same reason.
if [ -n "${WSYS_UIDGATE_BIN:-}" ]; then cp "$WSYS_UIDGATE_BIN" "$W/wsys_uidgate"
else
    ./scripts/hamlinux_build.sh tests/linux/wsys_uidgate.ad "$W/wsys_uidgate" \
        >"$W/build.log" 2>&1 || { cat "$W/build.log"; echo "BUILD FAILED"; exit 2; }
fi
chmod 755 "$W/wsys_uidgate"
cp "$0" "$W/inner.sh"; chmod 755 "$W/inner.sh"
# The inner half runs as a copy in $W with $PROJ_ROOT resolving to `/`, so it
# cannot reach the tree to source the reaper.  It gets its own copy here.
cp tests/linux/reap.sh "$W/reap.sh"

command -v unshare >/dev/null || { echo "SKIP: no unshare(1)"; exit 0; }
command -v setpriv >/dev/null || { echo "SKIP: no setpriv(1)"; exit 0; }

# WHERE THE VICTIM'S AND THE ATTACKER'S UID COME FROM -- TWO CASES, AND THE
# SECOND ONE IS WHAT LETS THIS GATE BE ISOLATED AT ALL. Written up at length in
# tests/linux/wsys_enum_policy.sh; the short form:
#
# On a bare host they are subordinate ids out of /etc/subuid for the invoking
# user, as they always were. Inside private_ns.sh's namespace `id -un` is root,
# /etc/subuid HAS NO root LINE, and reading only that file would make this gate
# SKIP -- scoring 0 arms while exiting green, which is the wsys_bypass.sh
# failure mode and would have been an exemption in disguise.
#
# But a process that is root in a user namespace holding a mapped RANGE already
# owns ids 1001 and 1002 and may map them to themselves in a child, needing no
# /etc/subuid and no setuid helper. THE TEST IS THE MAPPING ITSELF, not a read
# of /proc/self/uid_map: on a bare host that file is the initial
# `0 0 4294967295`, which "contains" 1001 and 1002 while an unprivileged process
# may map neither, so a range read would turn a clean SKIP on a subuid-less host
# into a hard failure -- a gate reporting a defect it did not find.
#
# Either way the INNER ids are 0, 1001 and 1002 and every assertion below is
# about those, so which outer ids back them changes nothing this gate claims.
SUB=""
if grep -q "^$(id -un):" /etc/subuid 2>/dev/null \
   && grep -q "^$(id -un):" /etc/subgid 2>/dev/null; then
    SUB="$(awk -F: -v u="$(id -un)" '$1==u{print $2; exit}' /etc/subuid)"
    IDSRC="/etc/subuid range $SUB for $(id -un)"
elif unshare -U \
        --map-users=0:"$(id -u)":1      --map-groups=0:"$(id -g)":1 \
        --map-users=1001:1001:1         --map-groups=1001:1001:1 \
        --map-users=1002:1002:1         --map-groups=1002:1002:1 \
        true 2>/dev/null; then
    SUB=1001
    IDSRC="ids 1001/1002 are already this namespace's own (mapped to themselves; no /etc/subuid needed)"
else
    echo "SKIP: no /etc/subuid range for $(id -un), and this namespace does not"
    echo "SKIP: already own uids 1001 and 1002; run this in the VM instead"
    exit 0
fi
note "$(priv_ns_describe)"
note "the victim's and the attacker's uid: $IDSRC"
OUT="$W/out.txt"
unshare -U \
    --map-users=0:"$(id -u)":1      --map-groups=0:"$(id -g)":1 \
    --map-users=1001:"$SUB":1       --map-groups=1001:"$SUB":1 \
    --map-users=1002:"$((SUB+1))":1 --map-groups=1002:"$((SUB+1))":1 \
    -- "$W/inner.sh" --inner "$W" >"$OUT" 2>&1
rc=$?
cat "$OUT"
[ $rc -eq 0 ] || { echo "namespace setup failed (rc=$rc)"; exit 2; }

line() { grep -m1 "^== $1" "$OUT"; }
has()  { line "$1" | grep -q -- "$2"; }

note ""
note "the instrument first, because every assertion below is worthless if the"
note "victim never came up or the compositor could not fill its rings:"
VWID="$(sed -n 's/^== vwid \([0-9][0-9]*\)/\1/p' "$OUT" | head -1)"
if [ -n "$VWID" ] && [ "$VWID" -ge 2 ] 2>/dev/null; then
    ok "a uid-1001 victim owns and holds window $VWID"
else bad "the victim never came up, so nothing below is measuring anything:"\
        "$(line victim.client)"; fi
# THE COMPOSITOR'S WRITES.  These are wsysd's own path -- route_pointer_event
# and route_focus_event write a window they do not own -- so a failure here is
# the desktop losing input, not a test detail.
for r in wev wpt wtx wcm; do
    if line "pre.$r" | grep -q -- "write=-"; then
        bad "the compositor could NOT write the victim's ring ($r):"\
            "$(line "pre.$r")"
    else ok "the compositor writes the victim's ring ($r) as host owner"; fi
done

note ""
note "THE RED ARM -- a uid-1002 stranger, owning no window, reading another"
note "uid's rings.  On the UNFIXED tree every one of these SUCCEEDS and prints"
note "the needle; that is the bug this gate exists to hold down."
# THE REFUSAL IS ON TWO LINES, and wsys_bypass.sh documents why: the probe's own
# stdout and the library's named diagnostic on stderr are merged by `as`, so the
# `read` token and the ` open=-1` land on separate prefixed lines.  Both of these
# greps therefore scan the whole run rather than the first matching line.
for r in event pointer text cmd; do
    if grep -q "^== att\.$r\..*open=-1" "$OUT"; then
        ok "REFUSED at the open: /dev/wsys/$VWID/$r"
    else bad "OPEN: a uid-1002 stranger opened /dev/wsys/$VWID/$r:"\
            "$(line "att.$r")"; fi
done
# THE CONTENTS, ASSERTED SEPARATELY FROM THE RETURN CODE.  A refusal that still
# leaked the bytes would satisfy the four assertions above; these four are what
# say the needle did not come back.
if grep -q "^== att\.event\..*geometry 100 100 300 200" "$OUT"; then
    bad "THE MEASURED LEAK IS STILL OPEN: the stranger read the compositor's"\
        "own geometry line out of another uid's event queue: $(line att.event)"
else ok "and the measured needle 'geometry 100 100 300 200' does NOT come back"; fi
if grep -q "^== att\.pointer\..*m 640 400" "$OUT"; then
    bad "the stranger followed the user's cursor over another window:"\
        "$(line att.pointer)"
else ok "nor the pointer trail"; fi
if grep -q "^== att\.text\..*TEXTSECRET31337" "$OUT"; then
    bad "the stranger read another window's committed text: $(line att.text)"
else ok "nor the committed text"; fi
if grep -q "^== att\.cmd\..*CMDSECRET31337" "$OUT"; then
    bad "the stranger read another window's cmd channel: $(line att.cmd)"
else ok "nor the cmd channel"; fi
# REFUSED BY NAME, the standard the keys refusal is already held to: a read that
# succeeded and returned nothing would say "this window is idle" to a caller
# with no way to tell that apart from the truth.
if grep -q "so it cannot read its event ring" "$OUT"; then
    ok "and the refusal NAMES the window and the ring, on stderr"
else bad "the refusal was silent -- no named diagnostic in the run"; fi

note ""
note "THE GREEN ARM, HALF ONE -- THE COMPOSITOR.  It reads rings for windows it"
note "does not own because that is its job, and it is admitted as the HOST"
note "OWNER, the same fact that already admits its WRITES."
for r in event pointer text cmd; do
    if grep -q "^== comp\.$r\..*open=-1" "$OUT"; then
        bad "THE FIX BROKE THE COMPOSITOR: it was refused /dev/wsys/$VWID/$r --"\
            "a desktop that cannot read its clients' rings: $(line "comp.$r")"
    else ok "the compositor still opens /dev/wsys/$VWID/$r"; fi
done
if has comp.event "geometry 100 100 300 200"; then
    ok "and reads the real bytes back out of the event ring"
else bad "the compositor opened the ring but got nothing -- a read that"\
        "succeeds and returns nothing is the shape this device forbids:"\
        "$(line comp.event)"; fi
if has comp.pointer "m 640 400"; then ok "and out of the pointer ring"
else bad "the compositor read no pointer bytes: $(line comp.pointer)"; fi
if has comp.text "TEXTSECRET31337"; then ok "and out of the text ring"
else bad "the compositor read no text bytes: $(line comp.text)"; fi
if has comp.cmd "CMDSECRET31337"; then ok "and out of the cmd ring"
else bad "the compositor read no cmd bytes: $(line comp.cmd)"; fi

note ""
note "THE GREEN ARM, HALF TWO -- THE OWNER, AT uid 1002.  The same uid the red"
note "arm refuses, reading the rings of a window it allocated itself.  This is"
note "what says the refusal is about OWNERSHIP and not about that uid."
OWID="$(sed -n 's/^== owid \([0-9][0-9]*\)/\1/p' "$OUT" | head -1)"
if [ -n "$OWID" ] && [ "$OWID" -ge 2 ] 2>/dev/null; then
    ok "the uid-1002 process allocated its own window $OWID"
else bad "the owner arm never got a window, so its reads prove nothing:"\
        "$(line own.ownring)"; fi
for r in event pointer text cmd; do
    if grep -q "^== own\.ownring\.$r .*open=-1" "$OUT"; then
        bad "THE FIX BROKE THE OWNER: refused its OWN window's $r ring:"\
            "$(line "own.ownring.$r")"
    else ok "the owner opens its own $r ring"; fi
done
if grep -q "^== own.ownring.event .*geometry 100 100 300 200" "$OUT"; then
    ok "and reads its own event bytes back"
else bad "the owner got no event bytes: $(line own.ownring.event)"; fi
if grep -q "^== own.ownring.pointer .*m 640 400" "$OUT"; then
    ok "and its own pointer bytes"
else bad "the owner got no pointer bytes: $(line own.ownring.pointer)"; fi
if grep -q "^== own.ownring.text .*TEXTSECRET31337" "$OUT"; then
    ok "and its own text bytes"
else bad "the owner got no text bytes: $(line own.ownring.text)"; fi
if grep -q "^== own.ownring.cmd .*CMDSECRET31337" "$OUT"; then
    ok "and its own cmd bytes"
else bad "the owner got no cmd bytes: $(line own.ownring.cmd)"; fi

note ""
note "and the session is NOT blind, which is the failure worse than the hole:"
if has att.screen "1280 800"; then
    ok "the refused stranger still reads /dev/wsys/screen: 1280 800"
else bad "the stranger cannot read the screen geometry -- it can no longer lay"\
        "itself out: $(line att.screen)"; fi

note ""
note "WHAT THIS GATE DOES NOT MEASURE, stated so a PASS is not read as more"
note "than it is.  Both are REASONED FROM THE SOURCE, not measured here:"
note ""
note "1. THE BYPASS.  The check is inside a library every client links, so it"
note "   binds a process that goes through the /dev/wsys file protocol and"
note "   nothing else.  A process that maps /srv/wsys itself reads all four"
note "   rings with no if in its way -- tests/linux/wsys_bypass.sh drives"
note "   exactly that program and asserts it SUCCEEDS.  These four leaves are"
note "   also NOT routed (srv_route_read carries SCREEN, POOL and WINDOWS and"
note "   nothing else), so there is no server-side copy of the question to ask."
note "   THE HOLE IS NARROWED, NOT CLOSED."
note ""
note "2. THE DESCENDANT.  owns_wid() walks the caller's parent-pid chain and"
note "   NEVER COMPARES A uid, so a DESCENDANT of the window's owner passes"
note "   however far its uid has moved -- and on a real desktop every"
note "   application is a descendant of the compositor.  This harness CANNOT"
note "   construct that case honestly: a wid is stamped against the process"
note "   that called newwindow, the probe never forks, so every uid-1002"
note "   process here is a SIBLING of the victim and not a descendant of it."
note "   Driving it needs the DE's on-behalf path (\`alloc <pid>\` on ctl,"
note "   which stamps a row against a shell that CAN spawn), and that is a"
note "   separate gate.  Closing it needs an owner uid in struct wwin, which"
note "   changes sizeof(struct wwin) and costs a WSYS_VERSION bump -- see"
note "   stage 5 of docs/wsys_server_design.md.  NOT MEASURED, NOT CLOSED."

note ""
[ $fail -eq 0 ] && echo "PASS wsys_ringown" || echo "FAIL wsys_ringown"
exit $fail
