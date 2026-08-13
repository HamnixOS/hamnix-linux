#!/usr/bin/env bash
# tests/linux/wsys_srv_identity.sh — STAGE 3a: THE CALLER-IDENTITY PROPERTY,
# WITH A SECOND UID, RED UNROUTED AND GREEN ROUTED.
#
# WHAT STAGE 2 COULD NOT SAY, AND WHY THIS FILE EXISTS
# ====================================================
# tests/linux/wsys_srv_mutate.sh routed the mutations and asserted that the
# mediator refuses a routed write for a window that does not exist. That holds
# at any uid and it is the WEAK half: it proves the server looks at the
# message, not that it looks at the CALLER. Its first run printed
#
#     srvmu: FAIL a stranger renamed window 2
#
# and that FAIL was wrong. devwsys's rule, ported faithfully, is that the host
# owner -- the uid that owns the segment -- may write any window. An offscreen
# gate runs as one uid, so its "stranger" IS the host owner and the acceptance
# was correct. The mediator was reproducing the in-process rule exactly, which
# is what stage 2 was required to do. That gate refused to score a PASS for the
# property and said the next piece of work was a second uid. This is it.
#
# THE PAIR IS THE ARGUMENT, NOT THE REFUSAL
# =========================================
# A refusal gate that is green in every configuration proves nothing about
# mediation: it is equally green against a server that checks nothing, so long
# as something else happens to refuse. So this gate runs the SAME attack, from
# the SAME non-owner uid, against the SAME window, twice:
#
#   UNROUTED   the attacker's own linked-in code performs the write. The
#              `hostowner() || owns_wid()` gate is skipped -- which for an
#              attacker costs one deleted line, because in the in-process
#              design that gate is the attacker's own code and code you own is
#              not a check. THIS ARM MUST SUCCEED. If it is refused, the
#              instrument is not looking and nothing below means anything.
#   ROUTED     the identical mutation sent as a protocol message, also past the
#              local check -- exactly what a hostile client does once it knows
#              the protocol. THIS ARM MUST BE REFUSED, by the mediator, whose
#              two predicates are answered about the caller from SO_PEERCRED.
#
# Red unrouted and green routed is the entire case for the server's existence.
# Either arm alone is unfalsifiable.
#
# AND THE UNROUTED ARM IS RUN AGAINST A LIVE SERVER ON PURPOSE. wsysd is up
# with HAMWSYS_SERVER=1 for both; only the ATTACKER's flag differs. So the red
# arm is not a historical re-enactment, it is the state of the tree today: a
# client that does not speak the protocol maps the segment and writes through
# the mediator standing right next to it. That is precisely the hole
# WSYS_VERSION 8 -> 9 exists to close, and it is why the bump is the
# enforcement rather than a consequence of it. The bump is NOT made here.
#
# WHAT owns_wid() ACTUALLY ANSWERS, MEASURED FROM INSIDE
# ======================================================
# Stage 2 flagged owns_wid()'s ppid walk as the sharp edge and could not check
# it, because from outside the boundary "owns_wid said no" and "hostowner said
# yes first" are indistinguishable and are opposite findings. HAMWSYS_SRV_TRACE=1
# makes the server print both answers per routed mutation, with the caller's
# uid/pid and the window's owner pid, from inside srv_as_caller(). The arms
# below assert on those lines rather than inferring them.
#
# HOW THE UIDS ARE GOT WITHOUT ROOT, and why this gate is exempt from
# private_ns.sh: the same reasoning as tests/linux/wsys_uidgate.sh and
# tests/linux/wsys_bypass.sh, written up at length in the first of those. The
# namespace is only obtainable via `unshare --map-root-user`, inside which
# geteuid() is 0 -- and user/linux-wsys.c's hostowner() returns 1 for uid 0
# unconditionally. A gate whose whole question is WHICH UID may write WHICH
# window cannot be run by a process pretending to be root: every arm would pass
# and every one would be about the wrong uid. So: `unshare -U --map-users` with
# three ids out of /etc/subuid, and every path under the gate's own temp dir.
#
# THE NEGATIVE CONTROL, RUN ONCE BY HAND AND WRITTEN DOWN HERE
# ============================================================
# A gate is worth what it can fail. Deleting the single line
#
#     srv_as_caller(c->uid, c->pid);
#
# from srv_dispatch's WRITE case in user/linux-wsys.c -- the whole of the
# mediation, by stage 2's own account -- and rebuilding wsysd turns this file
# from 15 passed / 0 failed into 10 passed / 4 failed:
#
#   FAIL ROUTED: uid 1002 renamed uid 1001's window THROUGH THE SERVER
#   FAIL hostowner() answered 1 for uid 1002 against a segment owned by 1001
#   FAIL a uid-1002 caller not descended from the owner was ACCEPTED
#   FAIL descendant arm INCONSISTENT: owns_wid=0, exit=1 (accepted)
#
# The RED arm stays green throughout, which is correct -- it does not involve
# the server -- and is why it is not evidence on its own.
#
# Offscreen, software, no ICD. /dev/dri is untouched.
set -uo pipefail
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail=0; pass=0
ok()   { printf 'srvid: PASS %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf 'srvid: FAIL %s\n' "$*"; fail=$((fail+1)); }
note() { printf 'srvid: .... %s\n' "$*"; }

# ======================================================================
# INNER HALF — runs inside the user namespace, as inner uid 0
# ======================================================================
if [ "${1:-}" = "--inner" ]; then
    W="$2"
    BIN="$W/bin"
    . "$W/reap.sh"
    reap_track "$W/reaped.inner"
    reap_on_exit

    # $W/ws IS 0777 AND DELIBERATELY NOT STICKY, and this is load-bearing.
    # fs.protected_regular is 2 on this host: in a world- or group-writable
    # STICKY directory the kernel refuses to open a file you do not own for
    # writing. The segment is created by uid 1001 and the whole red arm is uid
    # 1002 opening it O_RDWR -- under 1777 that open fails with EACCES, the
    # attack "fails", and the gate would report the boundary holding when what
    # actually held was a sysctl on the enclosing directory. wsys_uidgate.sh
    # needs 1777 because three uids each CREATE a segment there; nothing here
    # does, so the sticky bit buys nothing and costs the measurement.
    mkdir -p "$W/ws" "$W/noicd"; chmod 0777 "$W/ws"
    export HAMWSYS="$W/ws/seg" HAMWSYS_BB="$W/ws/seg.bb" HAMWSYS_IMG="$W/ws/img"
    export HAMFB_FILE="$W/ws/fb.raw" HAMFB_GEOM=1280x800
    export VK_ICD_FILENAMES="$W/noicd/none.json" HAMLINUX_VNC=none
    : >"$W/in"; chmod 666 "$W/in"; export HAMWSYSD_INPUT="$W/in"
    rm -f "$HAMWSYS" "$HAMWSYS.chrome" "$HAMWSYS_BB" "$HAMFB_FILE"

    # setpriv, never `su`: no PAM, no password, and it drops supplementary
    # groups explicitly. `as 0` must NOT go through setpriv -- reuid 0 from 0
    # is a no-op that still costs a fork and an exec.
    as() { local u="$1"; shift
        if [ "$u" = 0 ]; then "$@"
        else setpriv --reuid="$u" --regid="$u" --clear-groups "$@"; fi; }
    # BACKGROUNDING A SHELL FUNCTION LOSES THE PROCESS YOU WANTED, and this
    # namespace has no pid namespace, so nothing collects the orphan. `exec`
    # inside the subshell makes the backgrounded process the program itself,
    # so $! names what we mean to kill -- BY EXACT PID, never by pattern.
    # (wsys_bypass.sh learned this by leaving two processes behind per run.)
    #
    # THE PID COMES BACK IN A GLOBAL, NOT ON STDOUT, and that is not a style
    # choice. Every caller here needs to redirect the CHILD's stdout to a log,
    # and `P="$(as_bg ... >log)"` applies the redirect to the whole command
    # substitution -- so the pid goes into the log and $P is empty, and every
    # later `kill "$P"` is a no-op that leaves a compositor running.
    #
    # `err` of "-" means "onto stdout". Opening ONE file twice, once as stdout
    # and once as stderr, gives two descriptions with independent offsets that
    # overwrite each other's bytes -- a log that is missing whichever stream
    # wrote second, which is how a gate ends up reporting nothing wrong.
    BGPID=0
    as_bg() { local u="$1" out="$2" err="$3"; shift 3
        local pre=()
        [ "$u" = 0 ] || pre=(setpriv --reuid="$u" --regid="$u" --clear-groups)
        if [ "$err" = "-" ]; then ( exec "${pre[@]}" "$@" >"$out" 2>&1 ) &
        else                      ( exec "${pre[@]}" "$@" >"$out" 2>"$err" ) & fi
        BGPID=$!; reap_add "$BGPID"; }

    # ---- the compositor, owned by 1001 --------------------------------
    # THE SEGMENT'S OWNER IS THE HOST OWNER, not a hardcoded 0 -- that is what
    # hostowner() reads, and it is why 1001 below is granted and 1002 refused.
    # Starting wsysd as 1001 is what makes 1001 the host owner.
    echo "== starting wsysd as uid 1001, HAMWSYS_SERVER=1, TRACE=1"
    as_bg 1001 "$W/wsysd.log" - \
          env HAMWSYS_SERVER=1 HAMWSYS_SRV_TRACE=1 "$BIN/wsysd"
    WP=$BGPID
    for _ in $(seq 1 150); do [ -s "$HAMFB_FILE" ] && break; sleep 0.1; done
    if ! [ -s "$HAMFB_FILE" ]; then
        echo "== FATAL wsysd produced no framebuffer"
        tail -20 "$W/wsysd.log" | sed 's/^/== wsysd: /'
        exit 3
    fi
    echo "== segowner $(stat -c %u "$HAMWSYS")"

    # ---- the victim: uid 1001, owns the window, stays alive ------------
    # wsys_hold and not wsys_poke: win_reap_dead() destroys a window whose
    # owner has exited, so a one-shot creator leaves a window that is already
    # gone by the time the attacker runs, and the attack would then be
    # measuring -ENOENT while printing a refusal.
    : >"$W/script"
    as_bg 1001 "$W/wid" "$W/victim.log" \
          env HAMWSYS_SERVER=1 "$BIN/wsys_hold" "$W/script"
    VP=$BGPID
    for _ in $(seq 1 100); do [ -s "$W/wid" ] && break; sleep 0.1; done
    VWID="$(tr -d '\n' <"$W/wid" 2>/dev/null || true)"
    echo "== victimwid ${VWID:-none}"
    if [ -z "${VWID:-}" ] || [ "${VWID:-0}" -lt 2 ]; then
        echo "== FATAL the victim never mapped a window"
        cat "$W/victim.log" | sed 's/^/== victim: /'
        exit 3
    fi
    # <tag> <uid> <cmd...> -> "== <tag> <one-line output> exit=<rc>".
    # The output and the exit status are captured in separate statements on
    # purpose: `echo "$(cmd) exit=$?"` reads $? of the command SUBSTITUTION,
    # which is a subshell, and the two are only the same by accident.
    run() { local tag="$1" u="$2"; shift 2
        local o rc
        o="$(as "$u" "$@" 2>&1)"; rc=$?
        printf '== %s %s exit=%s\n' "$tag" "$(printf '%s' "$o" | tr '\n' ' ')" "$rc"; }
    settitle() { echo "ctl title $1" >>"$W/script"; sleep 0.6; }
    titleof()  { as 1001 "$BIN/cat" /dev/wsys/windows 2>/dev/null \
                     | grep "^${VWID} " | head -1; }

    # `decorate 1` IS NOT DECORATION HERE, IT IS THE INSTRUMENT.  snap_windows()
    # skips any window that is not both `visible` and `decorate` -- the taskbar
    # must not list an undecorated popup -- and a fresh window is visible but
    # NOT decorated.  Without this line /dev/wsys/windows is EMPTY, every
    # "title unchanged" assertion below compares "" against "" and passes, and
    # the gate reports a boundary holding while measuring nothing at all.
    # (It cost one debugging round to find; the guard assertion in the outer
    # half is there so it can never cost a second one silently.)
    echo "ctl decorate 1" >>"$W/script"; sleep 0.4
    settitle VICTIM-OWN-TITLE
    echo "== baseline $(titleof)"

    # ---- ARM 1: THE CONTROL. An ORDINARY non-owner client, using the file
    # protocol as written, must be refused on BOTH paths. This is the check
    # that exists today; the point of arm 2 is that owning it is optional.
    run armC.unrouted 1002 "$BIN/wsys_uidgate" chrome \
        "/dev/wsys/$VWID/ctl" "title CONTROL-UNROUTED"
    echo "== armC.after $(titleof)"
    run armC.routed 1002 env HAMWSYS_SERVER=1 "$BIN/wsys_uidgate" \
        chrome "/dev/wsys/$VWID/ctl" "title CONTROL-ROUTED"
    echo "== armC.routed.after $(titleof)"

    # ---- ARM 2 (RED): the same attack with the local check skipped and NO
    # server in the write path. HAMWSYS_SERVER is unset for the attacker only;
    # wsysd is still running and still serving. This MUST land.
    as 1002 "$BIN/wsys_srv_probe" local "$VWID" >"$W/armR.out" 2>&1
    echo "== armR.exit $?"
    sed 's/^/== armR: /' "$W/armR.out"
    sleep 0.5
    echo "== armR.after $(titleof)"

    settitle VICTIM-OWN-TITLE
    echo "== reset $(titleof)"

    # ---- ARM 3 (GREEN): the identical mutation, routed, also past the local
    # check. The mediator is the only thing left that can refuse it.
    as 1002 env HAMWSYS_SERVER=1 "$BIN/wsys_srv_probe" mutate "$VWID" \
        >"$W/armG.out" 2>&1
    echo "== armG.exit $?"
    sed 's/^/== armG: /' "$W/armG.out"
    sleep 0.5
    echo "== armG.after $(titleof)"

    # ---- ARM 4: THE MEDIATOR MUST NOT SIMPLY REFUSE EVERYTHING. The window's
    # own owner renames it through the routed path. Without this arm, a server
    # that returned -EPERM unconditionally would score every PASS above.
    settitle OWNER-RENAMED-IT
    echo "== armO.after $(titleof)"

    # ---- ARM 5: the host owner's rule is UNCHANGED. 1001 is the segment's
    # owner, so devwsys's rule permits it to write a window it does not own.
    # If this were refused the mediator would be STRICTER than the path it
    # replaces, which is a regression and not a security improvement.
    as 1001 env HAMWSYS_SERVER=1 "$BIN/wsys_srv_probe" mutate "$VWID" \
        >"$W/armH.out" 2>&1
    echo "== armH.exit $?"
    sed 's/^/== armH: /' "$W/armH.out"

    # ==================================================================
    # ARM P: WHAT owns_wid() ACTUALLY ANSWERS -- THE PPID WALK, ISOLATED.
    # ==================================================================
    # Every arm above had hostowner() in front of owns_wid(), which is how the
    # sharp edge stayed unmeasured through stage 2. This one puts a window in
    # the hands of a process that can still FORK, and asks the same question
    # from two uid-1002 callers that differ in ONE respect: descent.
    #
    # The holder is uid 0 and the callers are uid 1002, deliberately. owns_wid()
    # compares pids and never looks at a uid, so if descent is what decides,
    # the crossing is a uid boundary as well as a process one.
    #
    # `alloc <pid>` and not `newwindow`: newwindow stamps the CALLER, and every
    # process that could be made to call it here exits immediately afterwards,
    # at which point win_reap_dead() destroys the window and the arm measures
    # -ENOENT while printing a refusal.
    : >"$W/pfire"; : >"$W/pfire2"
    as_bg 0 "$W/holder.log" - bash -c '
        W="$1"; BIN="$2"
        drop() { setpriv --reuid=1002 --regid=1002 --clear-groups "$@"; }
        while [ ! -s "$W/pfire" ]; do sleep 0.2; done
        wid="$(cat "$W/pfire")"
        # A CHILD, NOT AN exec. `exec setpriv ...` would replace this shell, so
        # the caller pid WOULD BE the window owner pid and owns_wid() would
        # match at depth 0 -- which is "the owner wrote its own window", not
        # "a descendant did", and is a different claim entirely.
        #
        # UNROUTED FIRST, so that "the routed answer equals the unrouted one"
        # is a measurement and not a remark. Same descent, same uid, ordinary
        # file protocol, no server.
        drop "$BIN/wsys_uidgate" chrome "/dev/wsys/$wid/ctl" \
             "title DESC-UNROUTED" >"$W/armP.desc.un.out" 2>&1
        echo $? >"$W/armP.desc.un.rc"
        while [ ! -s "$W/pfire2" ]; do sleep 0.2; done
        drop env HAMWSYS_SERVER=1 "$BIN/wsys_srv_probe" mutate "$wid" \
            >"$W/armP.desc.out" 2>&1
        echo $? >"$W/armP.desc.rc"
        while :; do sleep 1; done' -- "$W" "$BIN"
    HP=$BGPID
    echo "== armP.holderpid $HP"
    PWID="$(as 0 "$BIN/wsys_srv_probe" alloc "$HP" 2>/dev/null | head -1)"
    echo "== armP.wid ${PWID:-none}"
    if [ -n "${PWID:-}" ] && [ "${PWID:-0}" -ge 2 ]; then
        run armP.decorate 0 "$BIN/wsys_uidgate" chrome "/dev/wsys/$PWID/ctl" \
            "title HOLDER-OWN-TITLE"
        run armP.decorate2 0 "$BIN/wsys_uidgate" chrome "/dev/wsys/$PWID/ctl" \
            "decorate 1"
        ptitle() { as 1001 "$BIN/cat" /dev/wsys/windows 2>/dev/null \
                       | grep "^${PWID} " | head -1; }
        echo "== armP.baseline $(ptitle)"
        # (a) a uid-1002 process that is NOT descended from the holder
        as 1002 env HAMWSYS_SERVER=1 "$BIN/wsys_srv_probe" mutate "$PWID" \
            >"$W/armP.sib.out" 2>&1
        echo "== armP.sib.exit $?"
        sed 's/^/== armP.sib: /' "$W/armP.sib.out"
        echo "== armP.sib.after $(ptitle)"
        as 0 "$BIN/wsys_uidgate" chrome "/dev/wsys/$PWID/ctl" \
            "title HOLDER-OWN-TITLE" >/dev/null 2>&1
        # (b) a uid-1002 process that IS a child of the holder -- unrouted...
        echo "$PWID" >"$W/pfire"
        for _ in $(seq 1 100); do [ -s "$W/armP.desc.un.rc" ] && break; sleep 0.2; done
        echo "== armP.desc.un.exit $(cat "$W/armP.desc.un.rc" 2>/dev/null || echo none)"
        sed 's/^/== armP.desc.un: /' "$W/armP.desc.un.out" 2>/dev/null
        echo "== armP.desc.un.after $(ptitle)"
        as 0 "$BIN/wsys_uidgate" chrome "/dev/wsys/$PWID/ctl" \
            "title HOLDER-OWN-TITLE" >/dev/null 2>&1
        sleep 0.3
        # ...and routed, same descent, same uid.
        echo go >"$W/pfire2"
        for _ in $(seq 1 100); do [ -s "$W/armP.desc.rc" ] && break; sleep 0.2; done
        echo "== armP.desc.exit $(cat "$W/armP.desc.rc" 2>/dev/null || echo none)"
        sed 's/^/== armP.desc: /' "$W/armP.desc.out" 2>/dev/null
        echo "== armP.desc.after $(ptitle)"
    fi
    kill "$HP" 2>/dev/null; wait "$HP" 2>/dev/null

    kill "$VP" 2>/dev/null; wait "$VP" 2>/dev/null
    kill "$WP" 2>/dev/null; wait "$WP" 2>/dev/null

    # ==================================================================
    # ARM 6: BEHAVIOUR UNCHANGED WITH HAMWSYS_SERVER UNSET, VERIFIED.
    # A whole second compositor with the flag nowhere in its environment:
    # the victim must still map and title a window, and the non-owner must
    # still be refused by the in-process check.
    # ==================================================================
    rm -f "$HAMWSYS" "$HAMWSYS.chrome" "$HAMWSYS_BB" "$HAMFB_FILE"
    echo "== off.begin"
    as_bg 1001 "$W/wsysd.off.log" - "$BIN/wsysd"; WP2=$BGPID
    for _ in $(seq 1 150); do [ -s "$HAMFB_FILE" ] && break; sleep 0.1; done
    : >"$W/script2"
    as_bg 1001 "$W/wid2" "$W/victim2.log" "$BIN/wsys_hold" "$W/script2"
    VP2=$BGPID
    for _ in $(seq 1 100); do [ -s "$W/wid2" ] && break; sleep 0.1; done
    VWID2="$(tr -d '\n' <"$W/wid2" 2>/dev/null || true)"
    echo "== off.wid ${VWID2:-none}"
    if [ -n "${VWID2:-}" ] && [ "${VWID2:-0}" -ge 2 ]; then
        echo "ctl decorate 1" >>"$W/script2"; sleep 0.4
        echo "ctl title OFF-PATH-TITLE" >>"$W/script2"; sleep 0.6
        echo "== off.title $(as 1001 "$BIN/cat" /dev/wsys/windows 2>/dev/null \
                 | grep "^${VWID2} " | head -1)"
        run off.stranger 1002 "$BIN/wsys_uidgate" chrome \
            "/dev/wsys/$VWID2/ctl" "title OFF-PWNED"
        echo "== off.after $(as 1001 "$BIN/cat" /dev/wsys/windows 2>/dev/null \
                 | grep "^${VWID2} " | head -1)"
    fi
    kill "$VP2" 2>/dev/null; wait "$VP2" 2>/dev/null
    kill "$WP2" 2>/dev/null; wait "$WP2" 2>/dev/null

    grep '^wsrvtrace:' "$W/wsysd.log" 2>/dev/null | sed 's/^/== trace /' || true
    echo "== done"
    exit 0
fi

# ======================================================================
# OUTER HALF
# ======================================================================
cd "$PROJ"
# PER-RUN BY DEFAULT: $BIN is "$OUT/bin", and a fixed default meant two
# concurrent agents compiled into the same bin/ and copied each other's
# half-written binaries into their namespaces. SRV_WORK pins it to reuse a
# build.
SCRATCH_BASE="${SRV_SCRATCH_BASE:-/home/david/.hamnix-build}"
if [ -n "${SRV_WORK:-}" ]; then
    OUT="$SRV_WORK"; OUT_EPHEMERAL=0
    mkdir -p "$OUT" || { echo "srvid: FAIL cannot make $OUT"; exit 1; }
else
    mkdir -p "$SCRATCH_BASE" || { echo "srvid: FAIL cannot make $SCRATCH_BASE"; exit 1; }
    OUT="$(mktemp -d "$SCRATCH_BASE/wsrv-s3.XXXXXX")" || {
        echo "srvid: FAIL cannot make a scratch dir under $SCRATCH_BASE"; exit 1; }
    OUT_EPHEMERAL=1
fi
BIN="$OUT/bin"; mkdir -p "$BIN"

for c in "${ADDER_HOST_AC:-}" "$PROJ/build/cutover/host_ac_llvm.elf" \
         "$PROJ/build/cutover/host_ac.elf" \
         "$(git -C "$PROJ" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/../build/cutover/host_ac.elf"; do
    [ -n "$c" ] && [ -x "$c" ] && { ADDER_HOST_AC="$c"; break; }
done
[ -n "${ADDER_HOST_AC:-}" ] || { echo "srvid: FAIL no host_ac.elf"; exit 2; }
export ADDER_HOST_AC
for t in wsysd:user/wsysd.ad cat:user/cat.ad \
         wsys_hold:tests/linux/wsys_hold.ad \
         wsys_uidgate:tests/linux/wsys_uidgate.ad \
         wsys_srv_probe:tests/linux/wsys_srv_probe.ad; do
    n="${t%%:*}"
    [ "${SRV_REBUILD:-1}" = 0 ] && [ -x "$BIN/$n" ] && continue
    scripts/hamlinux_build.sh "${t#*:}" "$BIN/$n" >"$OUT/build.$n.log" 2>&1 || {
        echo "srvid: FAIL could not build ${t#*:}"; tail -8 "$OUT/build.$n.log"
        exit 2; }
done

command -v unshare >/dev/null || { echo "srvid: SKIP no unshare(1)"; exit 0; }
command -v setpriv >/dev/null || { echo "srvid: SKIP no setpriv(1)"; exit 0; }
grep -q "^$(id -un):" /etc/subuid 2>/dev/null || {
    echo "srvid: SKIP no /etc/subuid range for $(id -un); run this in the VM"
    exit 0; }
SUB="$(awk -F: -v u="$(id -un)" '$1==u{print $2; exit}' /etc/subuid)"

W="$(mktemp -d "${TMPDIR:-/tmp}/wsrvid.XXXXXX")"
trap 'rm -rf "$W"; [ "${OUT_EPHEMERAL:-0}" = 1 ] && rm -rf "$OUT"' EXIT
trap 'exit 130' INT TERM HUP
# 1777: three uids each create files in here. A uid that cannot create
# $HAMWSYS falls back to /dev/shm, which both leaks a file and makes every arm
# below measure a PRIVATE window system instead of the shared one -- the
# success-shaped failure this whole gate is about.
chmod 1777 "$W"
mkdir -p "$W/bin"; cp "$BIN"/* "$W/bin/"; chmod 755 "$W/bin"/*
cp "$0" "$W/inner.sh"; chmod 755 "$W/inner.sh"
cp tests/linux/reap.sh "$W/reap.sh"

OUTF="$W/out.txt"
unshare -U \
    --map-users=0:"$(id -u)":1      --map-groups=0:"$(id -g)":1 \
    --map-users=1001:"$SUB":1       --map-groups=1001:"$SUB":1 \
    --map-users=1002:"$((SUB+1))":1 --map-groups=1002:"$((SUB+1))":1 \
    -- "$W/inner.sh" --inner "$W" >"$OUTF" 2>&1
rc=$?
sed 's/^/srvid|  /' "$OUTF"
[ $rc -eq 0 ] || { echo "srvid: FAIL namespace run rc=$rc"; exit 2; }

f() { grep -m1 "^== $1" "$OUTF" | sed "s/^== $1 *//"; }

VWID="$(f victimwid)"; SEGOWN="$(f segowner)"
note "segment owner uid $SEGOWN (this is what hostowner() reads); victim window $VWID owned by uid 1001; attacker is uid 1002"
if [ "$SEGOWN" = 1001 ]; then
    ok "the host owner is uid 1001 and the attacker is a different uid -- the two identities that decide every arm below are genuinely different"
else
    bad "the segment is owned by uid '$SEGOWN', not 1001 -- the uid separation this gate rests on did not happen"
fi

# ---------- the instrument must be able to produce a non-empty answer -----
BASE="$(f baseline)"
if printf '%s' "$BASE" | grep -q 'VICTIM-OWN-TITLE'; then
    ok "the title instrument reads back a title the victim set (\"$BASE\") -- an 'unchanged' below is a comparison and not two blanks"
else
    bad "the title instrument never saw the victim's own title (got \"$BASE\"). Every 'unchanged' below would be vacuous; refusing to score them."
fi

# ---------- ARM C: the ordinary in-process check still refuses ------------
note "control -- an ORDINARY non-owner client, using the protocol as written:"
if printf '%s' "$(f armC.after)" | grep -q 'CONTROL-UNROUTED'; then
    bad "an ordinary non-owner client renamed the window unrouted -- the in-process check is not even present"
else
    ok "an ordinary non-owner client is refused on the unrouted path (title still \"$(f armC.after)\")"
fi
if printf '%s' "$(f armC.routed.after)" | grep -q 'CONTROL-ROUTED'; then
    bad "an ordinary non-owner client renamed the window through the server"
else
    ok "an ordinary non-owner client is refused on the routed path too"
fi
note "BOTH of those are green, and that is exactly why they prove nothing on their own: the refusal came from code inside the ATTACKER. Arms R and G are the ones that separate a check from an enforced check."

# ---------- ARM R: RED, and it must be red -------------------------------
note "RED ARM -- the same uid, the same window, the local check skipped, no server in the write path:"
grep '^== armR:' "$OUTF" | sed 's/^== armR: /srvid|      /'
AFTER_R="$(f armR.after)"
if printf '%s' "$AFTER_R" | grep -q 'PWNED-BY-A-STRANGER'; then
    ok "UNROUTED: uid 1002 renamed uid 1001's window -> \"$AFTER_R\". THE ATTACK WORKS. This is the arm that must succeed, and it did: the write was the attacker's own store into a MAP_SHARED segment, with a live mediator standing next to it and unable to see it. That is the hole WSYS_VERSION 8 -> 9 exists to close."
else
    bad "the unrouted attack did NOT land (title \"$AFTER_R\"). The instrument is not looking, so a refusal in the routed arm below would be unattributable -- it could be the mediator or it could be that nothing was ever attempted."
fi

# ---------- ARM G: GREEN, by the mediator and nothing else ---------------
note "GREEN ARM -- the identical mutation, routed, from the same uid 1002:"
grep '^== armG:' "$OUTF" | sed 's/^== armG: /srvid|      /'
AFTER_G="$(f armG.after)"
GEXIT="$(f armG.exit)"
if grep -q 'did not see the routed write' "$OUTF"; then
    bad "the server never received the routed write -- a refusal count of zero means nothing if the message never arrived"
elif [ "$GEXIT" = 0 ] && printf '%s' "$AFTER_G" | grep -q 'VICTIM-OWN-TITLE'; then
    REF="$(grep -m1 '^== armG: wsrvmu: the mediator REFUSED' "$OUTF" \
           | sed 's/^== armG: //')"
    ok "ROUTED: the mediator REFUSED the identical write from the identical uid, and the title is unchanged (\"$AFTER_G\"). The refusal, in the server's own words: ${REF:-<none>}"
elif printf '%s' "$AFTER_G" | grep -q 'PWNED-BY-A-STRANGER'; then
    bad "ROUTED: uid 1002 renamed uid 1001's window THROUGH THE SERVER -> \"$AFTER_G\". The mediator does not use the caller's identity."
else
    bad "ROUTED: probe exit=$GEXIT, title \"$AFTER_G\" -- neither a clean refusal nor a clean bypass"
fi

# ---------- ARM O / H: the mediator is not a blanket -EPERM --------------
note "the mediator must not simply refuse everything -- two arms that must be ALLOWED:"
if printf '%s' "$(f armO.after)" | grep -q 'OWNER-RENAMED-IT'; then
    ok "the window's own owner (uid 1001) renamed it through the routed path"
else
    bad "the window's OWNER was refused a routed rename of its own window (title \"$(f armO.after)\") -- the mediator is refusing indiscriminately, which would have scored every PASS above for the wrong reason"
fi
if [ "$(f armH.exit)" = 1 ]; then
    ok "the HOST OWNER (uid 1001) is still permitted to write a window it does not own -- devwsys's own rule, unchanged. A refusal here would be the mediator being STRICTER than the path it replaces."
else
    bad "the host owner was refused a write devwsys permits (armH.exit=$(f armH.exit)) -- routing changed the rule instead of enforcing it"
fi

# ---------- what owns_wid() actually answers, from inside ----------------
note "what the two predicates ANSWER, printed by the server from inside srv_as_caller():"
grep '^== trace' "$OUTF" | sed 's/^== trace /srvid|      /' | sort -u | head -12
T1002="$(grep '^== trace wsrvtrace: caller uid=1002' "$OUTF" | head -1)"
if [ -z "$T1002" ]; then
    bad "the server printed no trace line for the uid-1002 caller -- what owns_wid() answered is UNMEASURED, not zero"
else
    HO="$(printf '%s' "$T1002" | sed -n 's/.*hostowner=\([0-9-]*\).*/\1/p')"
    OW="$(printf '%s' "$T1002" | sed -n 's/.*owns_wid=\([0-9-]*\).*/\1/p')"
    note "for the attacker (uid 1002): hostowner=$HO owns_wid=$OW"
    if [ "$HO" = 0 ] && [ "$OW" = 0 ]; then
        ok "BOTH predicates answered 0 for the attacker, so the refusal was decided by owns_wid() and not short-circuited by hostowner() -- the ppid walk stage 2 flagged was actually reached and actually said no"
    elif [ "$HO" != 0 ]; then
        bad "hostowner() answered $HO for uid 1002 against a segment owned by $SEGOWN -- owns_wid() was never reached and the sharp edge is still unmeasured"
    else
        bad "owns_wid() answered $OW for a caller that owns nothing -- the ppid walk grants what it should refuse"
    fi
fi
# ---------- ARM P: the ppid walk, with hostowner() out of the way ---------
note "the sharp edge -- owns_wid() is a PARENT-PID WALK, and this is what it answers for two uid-1002 callers that differ only in descent:"
PWID="$(f armP.wid)"; HP="$(f armP.holderpid)"
PBASE="$(f armP.baseline)"
if [ -z "$PWID" ] || [ "$PWID" = none ] || [ "${PWID:-0}" -lt 2 ]; then
    bad "could not stamp a window against the forking holder (alloc said \"$PWID\") -- the ppid walk is UNMEASURED, which is not the same as sound"
elif ! printf '%s' "$PBASE" | grep -q 'HOLDER-OWN-TITLE'; then
    bad "the holder's window $PWID does not read back a title (\"$PBASE\") -- refusing to score descent arms against a blank"
else
    note "window $PWID is owned by pid $HP, a uid-0 process; both callers below are uid 1002"
    if [ "$(f armP.sib.exit)" = 0 ] \
       && printf '%s' "$(f armP.sib.after)" | grep -q 'HOLDER-OWN-TITLE'; then
        ok "a uid-1002 caller NOT descended from the window's owner is refused (owns_wid answered no)"
    else
        bad "a uid-1002 caller not descended from the owner was ACCEPTED (exit $(f armP.sib.exit), title \"$(f armP.sib.after)\")"
    fi
    DA="$(f armP.desc.after)"; DE="$(f armP.desc.exit)"
    # BY THE DESCENDANT'S OWN PID, NOT BY `head -1`. Both callers are uid 1002
    # and both address wid $PWID, so a uid+wid match selects whichever ran
    # first -- the SIBLING -- and reports its owns_wid=0 as the descendant's
    # answer. That scored a PASS reading "stricter than the handoff expected"
    # in the same run whose title had already been overwritten by the
    # descendant. The probe prints its own pid; use it.
    DPID="$(sed -n 's/^== armP.desc: wsrvmu: caller uid [0-9]* pid \([0-9]*\).*/\1/p' \
            "$OUTF" | head -1)"
    TD="$(grep "^== trace wsrvtrace: caller uid=1002 pid=${DPID:-x} " "$OUTF" \
          | grep "wid=$PWID" | head -1)"
    DOW="$(printf '%s' "$TD" | sed -n 's/.*owns_wid=\([0-9-]*\).*/\1/p')"
    if [ -z "$DPID" ]; then
        bad "the descendant probe did not print its pid -- its trace line cannot be told from the sibling's, and picking the wrong one is how this arm reports the opposite of what happened"
    elif [ -z "$TD" ]; then
        bad "the server printed no trace line for descendant pid $DPID on wid $PWID -- what owns_wid() answered is UNMEASURED"
    elif [ "$DOW" = 1 ] && [ "$DE" = 1 ] \
         && printf '%s' "$DA" | grep -q 'PWNED-BY-A-STRANGER'; then
        note "$(printf '%s' "$TD" | sed 's/^== trace //')"
        ok "MEASURED, AND IT IS THE ANSWER THE HANDOFF EXPECTED: a uid-1002 process that is merely a CHILD of the window's owner is GRANTED -- owns_wid=1, the write was accepted, and the title became \"$DA\". The walk compares pids and never looks at a uid, so it crossed a uid boundary (owner is uid 0) as well as a process one."
        if printf '%s' "$(f armP.desc.un.after)" | grep -q 'DESC-UNROUTED'; then
            ok "and the UNROUTED path grants the same descendant the same window (title became \"$(f armP.desc.un.after)\") -- so this is the rule the mediator INHERITED, measured on both paths, not one it introduced"
        else
            bad "the unrouted path did NOT grant the descendant (title \"$(f armP.desc.un.after)\") while the routed path did -- routing has WIDENED the rule, which is the one outcome stage 2 was required to avoid"
        fi
        note "THIS IS NOT A ROUTING REGRESSION AND MUST NOT BE 'FIXED' HERE. It is devwsys's own rule, ported: hamUI spawns a task INTO a window and stamps the parent's pid, and snap_self() answers 'creator pid OR ANCESTOR' for exactly that reason. Tightening it to an exact pid match would make every hamUI-spawned task unable to drive the window it was spawned into. What the mediator changes is WHERE the walk runs, not what it decides -- and the routed answer is now identical to the unrouted one, which is what stage 2 was required to deliver."
        note "WHAT IT COSTS, STATED PLAINLY, because it is a policy the enumeration work in stage 3 has to price: any process the desktop spawns is a descendant of the desktop, so every application can retitle, move, raise or destroy any window owned by the compositor, the panel, or any of its own ancestors -- regardless of uid, and now with the mediator's blessing rather than merely without its knowledge. A capability handed out at newwindow, which the design already proposes for enumeration, is the shape that replaces it. It is NOT in this stage."
    elif [ "$DOW" = 0 ] && [ "$DE" = 0 ] \
         && printf '%s' "$DA" | grep -q 'HOLDER-OWN-TITLE'; then
        ok "a uid-1002 CHILD of the window's owner is refused (owns_wid=0, write refused, title unchanged) -- the walk is stricter than the handoff expected, and all three signals agree"
    else
        bad "descendant arm INCONSISTENT: owns_wid=$DOW, probe exit=$DE (0=refused, 1=accepted), title \"$DA\". These must agree; refusing to pick one."
    fi
fi

T1001="$(grep '^== trace wsrvtrace: caller uid=1001' "$OUTF" | head -1)"
if [ -n "$T1001" ]; then
    note "for the owner (uid 1001): $(printf '%s' "$T1001" | sed 's/^== trace //')"
    ok "the server also traced the legitimate caller, so the two answers above are a contrast and not the only line it can print"
else
    bad "no trace line for uid 1001 -- the trace may only fire on refusals, which would make the attacker's line unfalsifiable"
fi

# ---------- ARM 6: flag unset, behaviour unchanged -----------------------
note "HAMWSYS_SERVER unset everywhere -- verified, not assumed:"
OFFT="$(f off.title)"; OFFA="$(f off.after)"
if printf '%s' "$OFFT" | grep -q 'OFF-PATH-TITLE'; then
    ok "with the flag unset a client still maps and titles a window (\"$OFFT\")"
else
    bad "with the flag unset the client could not map/title a window (\"$OFFT\") -- stage 3's changes broke the unrouted path"
fi
if printf '%s' "$OFFA" | grep -q 'OFF-PWNED'; then
    bad "with the flag unset an ordinary non-owner renamed the window -- the in-process check regressed"
elif [ -n "$OFFA" ]; then
    ok "with the flag unset an ordinary non-owner is still refused (\"$OFFA\")"
else
    bad "the flag-unset arm produced no title at all -- refusing to read an empty result as a pass"
fi

echo "srvid: $pass passed, $fail failed"
[ "$fail" = 0 ]
