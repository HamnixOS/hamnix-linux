#!/usr/bin/env bash
# wsys_srv_wopen.sh — STAGE 10b: THE WRITE OPEN IS THE OTHER HALF OF THE ORACLE.
#
# WHAT THIS GATE IS FOR
# =====================
# Stage 10 (7d24ef3c) made existence a server answer for the READ opens of nine
# per-window leaves, and wsys_srv_open.sh is its gate. It deliberately did not
# touch the WRITE open, and it said why, in the code and in the design doc:
#
#     "the rule two lines below the write open is owns_wid() -- the CONNECTION
#      question stage 5 introduced -- while the served answer is
#      owns_wid_ancestry(). They are not the same set, and a process HANDED a
#      descriptor for a window it does not descend from is exactly the case
#      stage 5 built."
#
# THAT REASON WAS WRONG, and one line of user/linux-wsys.c says so:
#
#     static int owns_wid(int wid)
#     {
#         if (srv_caller.active) return srv_caller_holds_wid(wid);
#         return owns_wid_ancestry(wid);
#     }
#
# srv_caller.active is set only by srv_as_caller()/srv_as_caller_full(), which
# are called only inside a server dispatching a request -- and hamwsys_open()
# never runs there (a routed write is serviced by hamwsys_write_inner, which
# opens nothing). So AT THE WRITE OPEN, IN THE CLIENT, owns_wid() IS
# owns_wid_ancestry(): the same function, not a similar rule. The local gate
# and the served predicate are the same set about the same process, so routing
# existence there moves no caller across the boundary -- only the errno.
#
# WHAT WAS LEAKING, and it is `cat`'s exit code one flag of open(2) over.
# Measured on the unrouted tree, uid 1002 owning nothing, OPENING FOR WRITING:
#
#     /dev/wsys/<live>/ctl   -> -1   (EPERM)
#     /dev/wsys/<dead>/ctl   -> -2   (ENOENT)
#
# and the same for scene, keys, pointer, event, text, cmd, wctl, draw/ctl and
# backbuffer. The errno enumerates the window table from a process that owns
# nothing and never wrote a byte.
#
# THE SHAPE OF EVERY ARM IS A PAIR, inherited from wsys_srv_open.sh and for its
# reason: a gate that only asked "is the snooper refused" would pass on the
# code this stage replaces, because every one of these leaves already refused.
# What leaked was WHICH refusal.
#
#   RED    (HAMWSYS_SERVER unset) live and dead DIFFER on every leaf. Must be
#          true, or the routed arm proves nothing about that leaf.
#   GREEN  (HAMWSYS_SERVER=1) identical process, identical uid: live and dead
#          are the SAME INTEGER.
#
# THE INSTRUMENT CAN TELL EPERM FROM ENOENT, WHICH IS NOT FREE. wsys_srv_open.sh
# had to RECORD rather than SCORE its owner-side pair because wsys_hold's
# `slurp` prints "OPENFAIL" for every failure and cannot report an errno -- so
# that pair read identical on the broken tree too. tests/linux/wsys_wopen.ad
# prints the RAW rc of sys_open_write, and sys_open_write returns
# `r < 0 ? -errno : r`, so EPERM is -1 and ENOENT is -2: different integers, on
# the same number line as a success.
#
# THE THREE THINGS THAT MUST BOTH HOLD, from the brief this was built against:
#   1. a stranger must not tell a live wid from a dead one ON THE WRITE PATH by
#      ANY means -- not errno (the pairs), not exit code (recorded), not TIMING
#      (the timing arm below, which exists because the other two are the easy
#      half);
#   2. the WINDOW'S OWNER must still be able to write its own window, or this
#      is a broken desktop rather than a policy (the owner arms, and
#      wsys_srv_deboot.sh);
#   3. THE TWO-STEP ORACLE MUST NOT BE REBUILT. "The server says it exists, the
#      local rule then says EPERM" is the same channel with one extra hop. It
#      is unreachable by the argument above and is ALSO closed in code by
#      open_deny(), which answers ENOENT whenever the server granted this wid.
#      The pairs below are what would catch it: a two-step oracle shows up as a
#      GREEN pair reading -1 against -2, exactly like the red one.
#
# THE TRAP THIS FILE WAS WRITTEN AGAINST, inherited from wsys_srv_open.sh: every
# arm runs the client's ORDINARY open path, so A BUILD THAT ROUTED NOTHING WOULD
# PASS THE LOT -- both arms take the in-process path and agree. So the server's
# trace names the leaf AND THE OPEN (`leaf=exists open=write`, which is what
# WSRV_F_FORWRITE is carried for and the only thing it is for), and crossings are
# counted SCOPED TO EACH CLIENT'S OWN PID. A write-open crossing is a different
# line from a read-open crossing, so "the write open was routed" cannot be
# satisfied by the read open next to it.
#
# THE NEGATIVE CONTROL, RUN AND WRITTEN DOWN, because a zero from an instrument
# nobody has shown can produce a non-zero is not a finding. Restore the two early
# exits in owns_wid_ancestry() -- `if (owner == 0) return 0;` and `return 1` on a
# match, which is exactly the code stage 10b replaces -- and this file goes from
# 69 passed / 0 failed to 67 / 2, with BOTH timing arms firing:
#
#   write open   live 82-84 us, dead 37-39 us   |delta| 112-121% over five reps
#   READ  open   live 84-89 us, dead 39-41 us   |delta| 112-115% over three reps
#
# The read arm matters most: it is the one measuring a channel this stage did not
# introduce. Nine READ opens have answered on this predicate since 7d24ef3c.
#
# WHY TWO UIDS: identical to wsys_srv_open.sh. The policy grants the host owner
# everything, so a single-uid gate's "stranger" IS the host owner.
#
# Offscreen, software, no ICD. /dev/dri is untouched.
set -uo pipefail
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

pass=0; fail=0
ok()   { printf 'wswopen: PASS %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf 'wswopen: FAIL %s\n' "$*"; fail=$((fail+1)); }
note() { printf 'wswopen: .... %s\n' "$*"; }

# Every per-window leaf hamwsys_open's for_write arm gates. draw/images and
# draw/image/<n> are NOT here and must not be: they refuse a write with EACCES
# BEFORE any existence question, live or dead, so they are a constant and never
# were an oracle on this path.
LEAVES="ctl wctl scene keys pointer event text cmd draw/ctl backbuffer"

# ======================================================================
# INNER HALF — runs inside the user namespace, as inner uid 0
# ======================================================================
if [ "${1:-}" = "--inner" ]; then
    W="$2"
    BIN="$W/bin"
    . "$W/reap.sh"
    reap_track "$W/reaped.inner"
    reap_on_exit

    # 0777 AND NOT STICKY: fs.protected_regular refuses a non-owner's O_RDWR
    # open of a file in a world-writable STICKY directory (wsys_srv_identity.sh
    # at length), so under 1777 every uid-1002 arm would fail to open the
    # segment and this gate would score the sysctl as the policy.
    mkdir -p "$W/ws" "$W/noicd"; chmod 0777 "$W/ws"
    export HAMWSYS="$W/ws/seg" HAMWSYS_BB="$W/ws/seg.bb" HAMWSYS_IMG="$W/ws/img"
    export HAMFB_FILE="$W/ws/fb.raw" HAMFB_GEOM=1280x800
    export VK_ICD_FILENAMES="$W/noicd/none.json" HAMLINUX_VNC=none
    : >"$W/in"; chmod 666 "$W/in"; export HAMWSYSD_INPUT="$W/in"
    rm -f "$HAMWSYS" "$HAMWSYS.chrome" "$HAMWSYS_BB" "$HAMFB_FILE"

    as() { local u="$1"; shift
        if [ "$u" = 0 ]; then "$@"
        else setpriv --reuid="$u" --regid="$u" --clear-groups "$@"; fi; }
    # The pid comes back in a global, never on stdout, and the backgrounded
    # thing is exec'd so $! names the program and not a shell -- both traps are
    # documented in wsys_srv_identity.sh and both were paid for once already.
    BGPID=0
    as_bg() { local u="$1" out="$2" err="$3"; shift 3
        local pre=()
        [ "$u" = 0 ] || pre=(setpriv --reuid="$u" --regid="$u" --clear-groups)
        if [ "$err" = "-" ]; then ( exec "${pre[@]}" "$@" >"$out" 2>&1 ) &
        else                      ( exec "${pre[@]}" "$@" >"$out" 2>"$err" ) & fi
        BGPID=$!; reap_add "$BGPID"; }

    # ONE PROBE = ONE WRITE-OPEN OF ONE LEAF, and what is recorded is the rc,
    # which IS the errno. The pid is written before exec so the number is the
    # one the kernel hands the read server in SO_PEERCRED.
    #   probe <uid> <routed:0|1> <pidfile> <tag> <path>
    probe() { local u="$1" r="$2" pf="$3" tag="$4" p="$5"
        local env=()
        [ "$r" = 1 ] && env=(env HAMWSYS_SERVER=1) || env=(env -u HAMWSYS_SERVER)
        as "$u" bash -c 'echo $$ >"$1"; shift; exec "$@"' _ "$pf" \
           "${env[@]}" "$BIN/wsys_wopen" "$p" >"$W/o.$tag" 2>"$W/e.$tag"
        local rc=$?
        # The rc of the OPEN, not of the program: wsys_wopen exits 0 whatever
        # happened and prints "WOPEN <rc> <path>". The path is NOT compared --
        # it contains the wid and would differ between live and dead by
        # construction, which would make every green arm fail for the wrong
        # reason (the trap wsys_srv_open.sh records at its own probe()).
        local v
        v="$(sed -n '1s/^WOPEN \(-\?[0-9]*\) .*/\1/p' "$W/o.$tag")"
        printf '== probe.%s exit=%s rc=<%s> err=<%s>\n' "$tag" "$rc" "${v:-NONE}" \
               "$(tr '\n' ' ' <"$W/e.$tag" | sed 's/  */ /g' | cut -c1-120)"
    }

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
    grep -m1 'read server pid' "$W/wsysd.log" \
        | sed 's/^/== readserver /' || echo "== readserver NONE"

    # ---- the victim: uid 1001, owns a window, STAYS ALIVE ---------------
    : >"$W/vscript"; chmod 666 "$W/vscript"
    as_bg 1001 "$W/victim.out" "$W/victim.log" \
          env HAMWSYS_SERVER=1 "$BIN/wsys_hold" "$W/vscript"
    VP=$BGPID
    for _ in $(seq 1 100); do [ -s "$W/victim.out" ] && break; sleep 0.1; done
    VWID="$(head -1 "$W/victim.out" | tr -d '\n' 2>/dev/null || true)"
    echo "== victimwid ${VWID:-none}"
    if [ -z "${VWID:-}" ] || [ "${VWID:-0}" -lt 2 ]; then
        echo "== FATAL the victim never mapped a window"
        sed 's/^/== victim: /' "$W/victim.log"
        exit 3
    fi
    printf 'ctl decorate 1\nctl title VICTIM-WOPEN\nctl geometry 137 241 353 179\n' \
        >>"$W/vscript"
    printf 'scene rect 10 10 40 40 255 0 0\n' >>"$W/vscript"
    sleep 1.2

    # A wid THAT DOES NOT EXIST, and must not come to exist during the run:
    # wids are allocated upward from 1, so +1000 is not a race.
    DWID=$((VWID + 1000))
    echo "== deadwid $DWID"

    # ---- THE OWNER'S OWN WRITE OPEN, ROUTED, FIRST ----------------------
    # Before any refusal is scored: the window's own owner must still be able
    # to open its window for writing over the routed path, or every refusal
    # below is a server that answers nobody rather than a policy. `wctl` is the
    # one verb wsys_hold reports the WRITE's return value for, and that return
    # value is reached only THROUGH the write open under test.
    printf 'wctl move 411 233\n' >>"$W/vscript"; sleep 0.8
    echo "== ownerwctl $(grep -o 'WCTL [-0-9]* move 411 233' "$W/victim.out" \
                          | sed -n '1p')"

    # ---- the pairs, one leaf at a time ----------------------------------
    n=0
    for L in ctl wctl scene keys pointer event text cmd draw/ctl backbuffer; do
        n=$((n+1))
        probe 1002 0 "$W/p.rl$n" "rl$n" "/dev/wsys/$VWID/$L"
        probe 1002 0 "$W/p.rd$n" "rd$n" "/dev/wsys/$DWID/$L"
        probe 1002 1 "$W/p.gl$n" "gl$n" "/dev/wsys/$VWID/$L"
        probe 1002 1 "$W/p.gd$n" "gd$n" "/dev/wsys/$DWID/$L"
        echo "== leaf$n $L"
    done

    # ---- A SECOND WINDOW OWNER AT THE SNOOPING uid ----------------------
    # uid 1002 owning a window of its OWN must still write its own leaves while
    # being refused the victim's. Without this arm a served predicate that
    # refused everybody would score identically to the policy.
    : >"$W/ascript"; chmod 666 "$W/ascript"
    as_bg 1002 "$W/owner.out" "$W/owner.log" \
          env HAMWSYS_SERVER=1 "$BIN/wsys_hold" "$W/ascript"
    AP=$BGPID
    for _ in $(seq 1 100); do [ -s "$W/owner.out" ] && break; sleep 0.1; done
    AWID="$(head -1 "$W/owner.out" | tr -d '\n' 2>/dev/null || true)"
    echo "== ownerwid ${AWID:-none}"
    printf 'ctl decorate 1\nctl title OWNER-1002-WOPEN\nctl geometry 611 97 222 144\n' \
        >>"$W/ascript"
    printf 'wctl move 620 110\n' >>"$W/ascript"; sleep 0.9
    echo "== owner1002wctl $(grep -o 'WCTL [-0-9]* move 620 110' "$W/owner.out" \
                              | sed -n '1p')"

    # A SECOND uid-1002 PROCESS, NOT DESCENDED FROM THE ONE THAT OWNS wid
    # $AWID, write-opens THREE wids in one invocation: the one its own uid owns,
    # the victim's, and a dead one. ALL THREE MUST READ ALIKE, and the first is
    # the interesting one: the rule is about the PROCESS, never the uid, so a
    # sibling at the owner's uid is as much a stranger to $AWID as it is to the
    # victim's window. Written the other way round first, scoring tri1 as a
    # grant, and it FAILED for that reason -- wsys_wopen is a child of the
    # inner shell, not of wsys_hold, so its ancestry reaches neither window.
    # The grant arms are the two WCTL lines above, made from inside the
    # processes that actually own the windows.
    as 1002 bash -c 'echo $$ >"$1"; shift; exec "$@"' _ "$W/p.tri" \
       env HAMWSYS_SERVER=1 "$BIN/wsys_wopen" \
       "/dev/wsys/$AWID/ctl" "/dev/wsys/$VWID/ctl" "/dev/wsys/$DWID/ctl" \
       >"$W/o.tri" 2>"$W/e.tri"
    for k in 1 2 3; do
        echo "== tri$k $(sed -n "${k}s/^WOPEN \(-\?[0-9]*\) .*/\1/p" "$W/o.tri")"
    done

    # ---- TIMING: THE THIRD CHANNEL, AND THE ONE NOBODY MEASURES ---------
    # errno and exit code are the easy half. A refusal that takes measurably
    # longer for a live window than a dead one is the same oracle in a stopwatch.
    # STRUCTURALLY it should not: the server's WSRV_LEAF_EXISTS arm asks the
    # PERMISSION question first and only calls win_find() if it passed, so a
    # refused caller's request never touches the table at all. This measures it
    # rather than asserting it. A NO is never cached, so all N are real round
    # trips in both arms.
    TN=200
    ARGS_L=(); ARGS_D=()
    for _ in $(seq 1 $TN); do
        ARGS_L+=("/dev/wsys/$VWID/ctl"); ARGS_D+=("/dev/wsys/$DWID/ctl")
    done
    # THE ORDER ALTERNATES, and rep 0 is a WARM-UP THAT IS PRINTED AND NOT
    # SCORED. Both because the first measured run in this section was 37%
    # slower than the five after it on a tree whose live and dead arms were
    # otherwise within 1% of each other -- cold page cache and a cold connection
    # in whichever arm happens to go first, not a property of the window. A
    # discarded warm-up that is not printed is a number nobody can check, so it
    # is printed.
    for rep in 0 1 2 3 4 5; do
        if [ $((rep % 2)) = 1 ]; then A=("${ARGS_D[@]}"); B=("${ARGS_L[@]}")
        else                         A=("${ARGS_L[@]}"); B=("${ARGS_D[@]}"); fi
        t0=$(date +%s%N)
        as 1002 env HAMWSYS_SERVER=1 "$BIN/wsys_wopen" "${A[@]}" \
            >"$W/t.a.$rep" 2>/dev/null
        t1=$(date +%s%N)
        as 1002 env HAMWSYS_SERVER=1 "$BIN/wsys_wopen" "${B[@]}" \
            >"$W/t.b.$rep" 2>/dev/null
        t2=$(date +%s%N)
        if [ $((rep % 2)) = 1 ]; then
            echo "== timing$rep n=$TN live_ns=$((t2-t1)) dead_ns=$((t1-t0)) order=dead-first"
        else
            echo "== timing$rep n=$TN live_ns=$((t1-t0)) dead_ns=$((t2-t1)) order=live-first"
        fi
    done
    cp "$W/t.a.1" "$W/t.dead.1"; cp "$W/t.b.1" "$W/t.live.1"

    # THE SAME MEASUREMENT ON THE READ OPEN, because the channel was never the
    # write open's. owns_wid_ancestry() is the predicate stage 10 put behind the
    # nine ROUTED READ opens, so the stopwatch worked on `cat` from the day
    # 7d24ef3c landed -- and "it is fixed for reads too" must be measured rather
    # than reasoned from the two paths sharing a function. `scene` and not `ctl`:
    # wid/ctl's READ is stage 9's srv_route_read and does not go through the
    # existence question at all.
    RARGS_L=(); RARGS_D=()
    for _ in $(seq 1 $TN); do
        RARGS_L+=("/dev/wsys/$VWID/scene"); RARGS_D+=("/dev/wsys/$DWID/scene")
    done
    as 1002 env HAMWSYS_SERVER=1 "$BIN/wsys_wopen" -r "${RARGS_L[@]}" \
        >"$W/tr.warm" 2>/dev/null            # warm-up, discarded
    for rep in 1 2 3; do
        if [ $((rep % 2)) = 1 ]; then A=("${RARGS_D[@]}"); B=("${RARGS_L[@]}")
        else                         A=("${RARGS_L[@]}"); B=("${RARGS_D[@]}"); fi
        t0=$(date +%s%N)
        as 1002 env HAMWSYS_SERVER=1 "$BIN/wsys_wopen" -r "${A[@]}" \
            >"$W/tr.a.$rep" 2>/dev/null
        t1=$(date +%s%N)
        as 1002 env HAMWSYS_SERVER=1 "$BIN/wsys_wopen" -r "${B[@]}" \
            >"$W/tr.b.$rep" 2>/dev/null
        t2=$(date +%s%N)
        if [ $((rep % 2)) = 1 ]; then
            echo "== rtiming$rep n=$TN live_ns=$((t2-t1)) dead_ns=$((t1-t0))"
        else
            echo "== rtiming$rep n=$TN live_ns=$((t1-t0)) dead_ns=$((t2-t1))"
        fi
    done
    echo "== rrc live=$(sed -n '1s/^WOPEN \(-\?[0-9]*\) .*/\1/p' "$W/tr.b.1") dead=$(sed -n '1s/^WOPEN \(-\?[0-9]*\) .*/\1/p' "$W/tr.a.1")"
    echo "== timingvals live=$(sort -u "$W/t.live.1" | sed 's/ .*//;s/WOPEN //' \
            | tr '\n' ',') dead=$(sort -u "$W/t.dead.1" | sed 's/ .*//;s/WOPEN //' \
            | tr '\n' ',')"

    sleep 0.4
    # ---- THE CROSSINGS, SCOPED TO EACH CLIENT'S OWN PID -----------------
    for n in 1 2 3 4 5 6 7 8 9 10; do
        for tag in gl$n gd$n rl$n rd$n; do
            p="$(cat "$W/p.$tag" 2>/dev/null || echo 0)"
            c=$(grep -c "wsrvtrace: read caller uid=1002 pid=$p .*leaf=exists open=write" \
                "$W/wsysd.log" 2>/dev/null || true)
            echo "== cross.$tag pid=$p n=${c:-0}"
        done
    done
    P="$(cat "$W/p.tri" 2>/dev/null || echo 0)"
    echo "== cross.tri pid=$P n=$(grep -c "wsrvtrace: read caller uid=1002 pid=$P .*leaf=exists open=write" "$W/wsysd.log" 2>/dev/null || true)"
    echo "== wcross $(grep -c 'leaf=exists open=write' "$W/wsysd.log")"
    echo "== rcross $(grep -c 'leaf=exists open=read' "$W/wsysd.log")"
    echo "== wfull $(grep -c 'leaf=exists open=write.* -> FULL' "$W/wsysd.log")"
    echo "== wempty $(grep -c 'leaf=exists open=write.* -> EMPTY' "$W/wsysd.log")"
    grep 'leaf=exists open=write' "$W/wsysd.log" | tail -20 | sed 's/^/== trace /'
    kill "$AP" "$VP" "$WP" 2>/dev/null
    exit 0
fi

# ======================================================================
# OUTER HALF
# ======================================================================
cd "$PROJ"
# PRIVATE NAMESPACE FIRST. wsysd's names are compiled into it -- /srv/wsys,
# /dev/shm/hamnix-wsys, /tmp/hamnix-wsys -- so a run of this gate beside a live
# desktop is a collision, not an untidiness (tests/linux/private_ns.sh).
. tests/linux/private_ns.sh
priv_ns_reexec "$@"

SCRATCH_BASE="${SRV_SCRATCH_BASE:-/home/david/.hamnix-build}"
if [ -n "${SRV_WORK:-}" ]; then
    OUT="$SRV_WORK"; OUT_EPHEMERAL=0
    mkdir -p "$OUT" || { echo "wswopen: FAIL cannot make $OUT"; exit 2; }
else
    mkdir -p "$SCRATCH_BASE" || { echo "wswopen: FAIL cannot make $SCRATCH_BASE"; exit 2; }
    OUT="$(mktemp -d "$SCRATCH_BASE/wsrv-wopen.XXXXXX")" || {
        echo "wswopen: FAIL cannot make a scratch dir under $SCRATCH_BASE"; exit 2; }
    OUT_EPHEMERAL=1
fi
BIN="$OUT/bin"; mkdir -p "$BIN"

for c in "${ADDER_HOST_AC:-}" "$PROJ/build/cutover/host_ac_llvm.elf" \
         "$PROJ/build/cutover/host_ac.elf" \
         "$(git -C "$PROJ" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/../build/cutover/host_ac.elf"; do
    [ -n "$c" ] && [ -x "$c" ] && { ADDER_HOST_AC="$c"; break; }
done
[ -n "${ADDER_HOST_AC:-}" ] || { echo "wswopen: FAIL no host_ac.elf"; exit 2; }
export ADDER_HOST_AC HAMLINUX_DISTRO_RO=1
for t in wsysd:user/wsysd.ad wsys_wopen:tests/linux/wsys_wopen.ad \
         wsys_hold:tests/linux/wsys_hold.ad; do
    n="${t%%:*}"
    [ "${SRV_REBUILD:-1}" = 0 ] && [ -x "$BIN/$n" ] && continue
    scripts/hamlinux_build.sh "${t#*:}" "$BIN/$n" >"$OUT/build.$n.log" 2>&1 || {
        echo "wswopen: FAIL could not build ${t#*:}"; tail -8 "$OUT/build.$n.log"
        exit 2; }
done

command -v unshare >/dev/null || { echo "wswopen: SKIP no unshare(1)"; exit 0; }
command -v setpriv >/dev/null || { echo "wswopen: SKIP no setpriv(1)"; exit 0; }

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
    IDSRC="ids 1001/1002 are already this namespace's own (mapped to themselves)"
else
    echo "wswopen: SKIP no /etc/subuid range for $(id -un), and this namespace"
    echo "wswopen: SKIP does not already own uids 1001 and 1002; run this in the VM"
    exit 0
fi

note "$(priv_ns_describe)"
note "the two extra uids: $IDSRC"

W="$(mktemp -d "${TMPDIR:-/tmp}/wswopen.XXXXXX")"
trap 'rm -rf "$W"; [ "${OUT_EPHEMERAL:-0}" = 1 ] && rm -rf "$OUT"' EXIT
trap 'exit 130' INT TERM HUP
chmod 1777 "$W"
mkdir -p "$W/bin"; cp "$BIN"/wsysd "$BIN"/wsys_wopen "$BIN"/wsys_hold "$W/bin/"
chmod 755 "$W/bin"/*
cp "$0" "$W/inner.sh"; chmod 755 "$W/inner.sh"
cp tests/linux/reap.sh "$W/reap.sh"

OUTF="$W/out.txt"
unshare -U \
    --map-users=0:"$(id -u)":1      --map-groups=0:"$(id -g)":1 \
    --map-users=1001:"$SUB":1       --map-groups=1001:"$SUB":1 \
    --map-users=1002:"$((SUB+1))":1 --map-groups=1002:"$((SUB+1))":1 \
    -- "$W/inner.sh" --inner "$W" >"$OUTF" 2>&1
rc=$?
sed 's/^/wswopen|  /' "$OUTF"
[ $rc -eq 0 ] || { echo "wswopen: FAIL namespace run rc=$rc"; exit 2; }

f() { grep -m1 "^== $1 " "$OUTF" | sed "s/^== $1 *//"; }
pr() { grep -m1 "^== probe.$1 " "$OUTF" \
       | sed -n 's/.*rc=<\(-\?[0-9]*\)>.*/\1/p'; }

SEGOWN="$(f segowner)"; VWID="$(f victimwid)"; DWID="$(f deadwid)"
note "segment owner uid $SEGOWN; victim window $VWID owned by uid 1001; window $DWID does not exist; the snooper is uid 1002 and owns nothing"
note "the rc IS the errno: 0 or more is a successful open, -1 is EPERM, -2 is ENOENT"
if [ "$SEGOWN" = 1001 ]; then
    ok "the host owner is uid 1001 and the snooper is a different uid -- the two identities every arm below turns on are genuinely different"
else
    bad "the segment is owned by uid '$SEGOWN', not 1001 -- the uid separation this gate rests on did not happen"
fi

if printf '%s' "$(f readserver)" | grep -q 'read server pid'; then
    ok "wsysd forked a read server OFF the frame loop: $(f readserver)"
else
    bad "no read server was started -- every routed arm below would be falling back to the unmediated in-process lookup, which is the state this gate exists to distinguish from a policy"
fi

# ---------- THE OWNER MUST STILL BE ABLE TO WRITE, FIRST ----------------
OW="$(f ownerwctl)"
OWRC="$(printf '%s' "$OW" | sed -n 's/^WCTL \(-\?[0-9]*\).*/\1/p')"
if [ -n "$OWRC" ] && [ "$OWRC" -ge 0 ] 2>/dev/null; then
    ok "THE INSTRUMENT: the window's OWNER still writes its own window over the routed path (\"$OW\") -- and that write's return value is reached only THROUGH the write open under test. Every refusal below is a decision about the caller, not a server that answers nobody."
else
    bad "the window's own owner could NOT write it over the routed path (\"$OW\") -- routing the write open has broken the desktop, and every refusal below is that rather than a policy"
    echo "wswopen: $pass passed, $fail failed"; exit 1
fi

# ---------- THE PAIRS ----------------------------------------------------
i=0
for L in ctl wctl scene keys pointer event text cmd draw/ctl backbuffer; do
    i=$((i+1))
    RL="$(pr "rl$i")"; RD="$(pr "rd$i")"
    GL="$(pr "gl$i")"; GD="$(pr "gd$i")"
    note "---- $L (write open) ----"
    note "  RED   live: ${RL:-NONE}   dead: ${RD:-NONE}"
    note "  GREEN live: ${GL:-NONE}   dead: ${GD:-NONE}"
    if [ -z "$RL" ] || [ -z "$RD" ] || [ -z "$GL" ] || [ -z "$GD" ]; then
        bad "$L: a probe produced no rc at all -- the instrument did not run, so this leaf is unmeasured"
        continue
    fi
    if [ "$RL" = "$RD" ]; then
        bad "UNROUTED $L: live and dead both read $RL, so this leaf leaks nothing to begin with and the routed arm proves nothing about it. The red arm has gone green on its own."
    else
        ok "UNROUTED $L: a window-less uid-1002 process TELLS A LIVE WINDOW FROM A DEAD ONE ON THE WRITE PATH -- live rc $RL (EPERM) against dead rc $RD (ENOENT). It wrote nothing and read nothing; the errno IS the enumeration."
    fi
    if [ "$GL" = "$GD" ]; then
        ok "ROUTED $L: live and dead are the SAME INTEGER ($GL). A stranger cannot ask this leaf's write open which windows are there."
    else
        bad "ROUTED $L: live rc $GL still differs from dead rc $GD -- the write open is not mediated for this leaf (or the local rule refused after the server granted, which is the same oracle in two steps)."
    fi
    if [ "$GL" = "-2" ]; then
        :
    else
        bad "ROUTED $L: the routed refusal is rc $GL and not -2 (ENOENT) -- a stranger's refusal must be the SAME errno a wid that never existed produces, or the two are separable however equal this pair happens to read"
    fi
done

# ---------- A SECOND WINDOW OWNER AT THE SNOOPING uid -------------------
AWID="$(f ownerwid)"
AW="$(f owner1002wctl)"
AWRC="$(printf '%s' "$AW" | sed -n 's/^WCTL \(-\?[0-9]*\).*/\1/p')"
T1="$(f tri1)"; T2="$(f tri2)"; T3="$(f tri3)"
note "uid 1002 now owns window ${AWID:-none}; from one process it write-opens its OWN ctl, the VICTIM's ctl, and a dead wid's ctl:"
if [ -z "${AWID:-}" ] || [ "${AWID:-0}" -lt 2 ]; then
    bad "the uid-1002 client never got a window of its own -- the arms that keep the refusals honest could not run"
else
    if [ -n "$AWRC" ] && [ "$AWRC" -ge 0 ] 2>/dev/null; then
        ok "THE GRANT AT THE SNOOPER'S OWN uid: a uid-1002 process writes ITS OWN window over the routed path (\"$AW\"). The refusals are about the WINDOW, not about the uid."
    else
        bad "a uid-1002 process could not write its OWN window (\"$AW\") -- the served predicate refuses the owner, which is a broken desktop and not a policy"
    fi
    if [ "${T1:-x}" = "${T2:-y}" ] && [ "${T2:-x}" = "${T3:-z}" ] \
       && [ "${T1:-x}" = "-2" ]; then
        ok "a SIBLING uid-1002 process -- same uid as the owner of window $AWID, descended from neither owner -- write-opens window $AWID (rc $T1), the victim's window (rc $T2) and a dead wid (rc $T3) and gets THREE IDENTICAL ENOENTs. Sharing a uid with a window's owner is not owning it, and the existence answer does not leak the difference."
    else
        bad "a sibling uid-1002 process separated window $AWID (rc ${T1:-NONE}), the victim's window (rc ${T2:-NONE}) and a dead wid (rc ${T3:-NONE}) on the write path -- at least two of the three are distinguishable"
    fi
fi

# ---------- TIMING ------------------------------------------------------
note "TIMING, the third channel. errno and exit code are the easy half; a refusal that takes measurably longer for a live window is the same oracle with a stopwatch. 200 refused write opens per arm, one discarded warm-up plus five scored repetitions, arm order alternating:"
note "  rep0 (WARM-UP, RECORDED AND NOT SCORED): $(f timing0)"
worst=0
for rep in 1 2 3 4 5; do
    line="$(f "timing$rep")"
    LN="$(printf '%s' "$line" | sed -n 's/.*live_ns=\([0-9]*\).*/\1/p')"
    DN="$(printf '%s' "$line" | sed -n 's/.*dead_ns=\([0-9]*\).*/\1/p')"
    if [ -z "$LN" ] || [ -z "$DN" ] || [ "$LN" = 0 ] || [ "$DN" = 0 ]; then
        bad "timing rep $rep produced no usable numbers ($line)"
        continue
    fi
    # per-open microseconds, and the |delta| as a percentage of the smaller
    LU=$((LN / 200000)); DU=$((DN / 200000))
    d=$((LN - DN)); [ "$d" -lt 0 ] && d=$((-d))
    small=$LN; [ "$DN" -lt "$small" ] && small=$DN
    pct=$((d * 100 / small))
    note "  rep$rep: live ${LU} us/open, dead ${DU} us/open, |delta| ${pct}%  ($(printf '%s' "$line" | sed -n 's/.*order=//p'))"
    [ "$pct" -gt "$worst" ] && worst=$pct
done
if [ "$worst" -le 25 ]; then
    ok "the routed refusal takes the same time for a live window as for a dead one (worst |delta| across five scored reps: ${worst}%, on 200 refused opens each). IT DID NOT BEFORE THIS STAGE, and the reason is worth keeping: owns_wid_ancestry() used to return the moment win_find() came back NULL, so a DEAD wid cost zero /proc/<pid>/stat reads and a LIVE one cost up to eight -- measured at 93 us against 46 us per refused open, a 2x separation on a path whose errno was already identical. That channel was NOT introduced by routing the write open; stage 10 put the same predicate behind the nine READ opens, so the stopwatch worked on \`cat\` from the day it landed. The walk is now unconditional and its length depends on the CALLER's own ancestry, which the caller already knows. WHAT THIS DOES NOT COVER: win_find() itself still scans the table and returns early on a hit, so a live wid's scan is shorter than a dead one's by some tens of nanoseconds of memory compare -- three orders below what this instrument or any of its round trips can see, and in the OPPOSITE direction to the channel just closed."
else
    bad "the routed refusal is ${worst}% slower for a live window than a dead one -- the errno is closed and the stopwatch is not. NOTE THE BOUND: this is a shell-timed wall clock over 200 opens and it cannot see a difference smaller than run-to-run noise; a FAIL here is real, a PASS bounds the channel rather than eliminating it."
fi

# ---------- THE SAME STOPWATCH ON THE READ OPEN --------------------------
RRC="$(f rrc)"
note "THE READ OPEN, MEASURED THE SAME WAY. The timing channel was in owns_wid_ancestry(), which stage 10 put behind nine ROUTED READ opens -- so it was never the write open's channel and 'it is closed for reads too' must be measured. 200 refused READ opens of <wid>/scene per arm, warm-up discarded, order alternating. Errnos on that path: $RRC"
rworst=0; rseen=0
for rep in 1 2 3; do
    line="$(f "rtiming$rep")"
    LN="$(printf '%s' "$line" | sed -n 's/.*live_ns=\([0-9]*\).*/\1/p')"
    DN="$(printf '%s' "$line" | sed -n 's/.*dead_ns=\([0-9]*\).*/\1/p')"
    if [ -z "$LN" ] || [ -z "$DN" ] || [ "$LN" = 0 ] || [ "$DN" = 0 ]; then
        bad "read-path timing rep $rep produced no usable numbers ($line)"
        continue
    fi
    rseen=1
    LU=$((LN / 200000)); DU=$((DN / 200000))
    d=$((LN - DN)); [ "$d" -lt 0 ] && d=$((-d))
    small=$LN; [ "$DN" -lt "$small" ] && small=$DN
    pct=$((d * 100 / small))
    note "  rep$rep: live ${LU} us/open, dead ${DU} us/open, |delta| ${pct}%"
    [ "$pct" -gt "$rworst" ] && rworst=$pct
done
if [ "$rseen" = 1 ] && [ "$rworst" -le 25 ]; then
    ok "the ROUTED READ open's refusal also takes the same time for a live window as for a dead one (worst |delta| ${rworst}% over three reps). The fix is in the shared predicate, and this is the arm that says so from outside rather than from the source."
elif [ "$rseen" = 1 ]; then
    bad "the routed READ open is ${rworst}% slower for a live window than a dead one -- stage 10's nine read leaves still answer the existence question with a stopwatch"
fi

# ---------- THE ARMS THAT MAKE "IT WAS ROUTED" VISIBLE FROM OUTSIDE ------
note "THE CROSSINGS. Every arm above runs the client's ORDINARY open path, so a build that routed NOTHING would pass all of them. These count the read server's own trace, scoped to each client's own pid AND to the WRITE open specifically -- 'leaf=exists open=write', which a read open of the same leaf does not produce:"
i=0
for L in ctl wctl scene keys pointer event text cmd draw/ctl backbuffer; do
    i=$((i+1))
    for tag in gl$i gd$i; do
        line="$(grep -m1 "^== cross.$tag " "$OUTF")"
        n="$(printf '%s' "$line" | sed -n 's/.* n=\([0-9]*\).*/\1/p')"
        p="$(printf '%s' "$line" | sed -n 's/.*pid=\([0-9]*\).*/\1/p')"
        if [ "${n:-0}" -ge 1 ]; then
            ok "ROUTED $L ($tag): the read server logged $n WRITE-open existence question(s) for pid $p -- the crossing is visible from outside the process and is attributably a write open"
        else
            bad "ROUTED $L ($tag): the read server logged NO write-open existence question for pid $p. The arm above passed on the in-process path, so it proves nothing about routing."
        fi
    done
    for tag in rl$i rd$i; do
        line="$(grep -m1 "^== cross.$tag " "$OUTF")"
        n="$(printf '%s' "$line" | sed -n 's/.* n=\([0-9]*\).*/\1/p')"
        p="$(printf '%s' "$line" | sed -n 's/.*pid=\([0-9]*\).*/\1/p')"
        if [ "${n:-0}" = 0 ]; then
            ok "UNROUTED $L ($tag): zero crossings for pid $p, as there must be -- the red arm really did read shared memory"
        else
            bad "UNROUTED $L ($tag): the read server logged $n question(s) for pid $p, so the 'unrouted' arm was routed and the red/green pair is not a pair"
        fi
    done
done

WF="$(f wfull)"; WE="$(f wempty)"
if [ "${WF:-0}" -ge 1 ] && [ "${WE:-0}" -ge 1 ]; then
    ok "the read server decided the WRITE open's existence question BOTH WAYS in this run ($WE refused, $WF granted) -- a policy that only ever reaches one branch is indistinguishable from a constant"
else
    bad "the read server reached only one branch on the write open's existence question (refused ${WE:-0}, granted ${WF:-0}); a constant answer would score the same as a policy"
fi

WC="$(f wcross)"; RC2="$(f rcross)"
note "for the record, whole-run crossings: $WC write opens and $RC2 read opens asked the read server for existence"
if [ "${WC:-0}" -ge 1 ]; then
    ok "WSRV_F_FORWRITE reaches the server and the trace attributes it: $WC write-open crossings are distinguishable from $RC2 read-open crossings in the same log"
else
    bad "not one trace line said 'open=write' -- the flag never crossed, so every crossing count above is unattributable"
fi

echo "wswopen: $pass passed, $fail failed"
[ "$fail" = 0 ]
