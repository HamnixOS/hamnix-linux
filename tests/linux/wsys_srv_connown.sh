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
# tests/linux/wsys_srv_connown.sh — STAGE 5: THE CONNECTION IS THE CAPABILITY.
#
# WHAT THIS GATE IS ABOUT, AND WHY IT IS NOT A NARROWING OF THE WALK
# =================================================================
# tests/linux/wsys_srv_identity.sh measured owns_wid() from inside the server
# and found that it compares pids and NEVER LOOKS AT A uid:
#
#     a uid-1002 caller not descended from the owner   -> refused
#     a uid-1002 caller that is a CHILD of the owner   -> ACCEPTED
#
# and it is accepted on the unrouted path too, so the rule is inherited rather
# than introduced by routing. Priced: every application the desktop spawns is a
# descendant of the desktop, so every application may retitle, move, raise or
# destroy any window owned by the compositor, the panel, or any of its own
# ancestors, regardless of uid.
#
# TIGHTENING THE WALK TO AN EXACT PID IS OFF THE TABLE and two stages said so.
# /etc/rc.de-user is why, in one line: every DE window is spawned as
# `/bin/hamsh /etc/rc.de-user <prog>`, hamUId stamps the wid against HAMSH, and
# the rc then runs the real program as hamsh's CHILD ("the program runs as a
# child of this hamsh"). An exact-pid rule would leave every DE application
# unable to drive the window it was spawned into.
#
# So the walk is not narrowed. It stops being the only question asked: a routed
# mutation must arrive ON THE CONNECTION THAT HOLDS THE ROW. A descendant then
# inherits the right to drive the window it was spawned into only when the
# spawner HANDS IT THE DESCRIPTOR -- which is exactly the moment the spawner
# means to. A descriptor cannot be walked to; it has to be given.
#
# BOTH ARMS, OR IT PROVES NOTHING
# ===============================
# The two children below are the SAME BINARY, spawned by the SAME process,
# against the SAME window, differing in ONE respect: whether the handoff
# happened. So:
#
#   un-handed child   MUST BE REFUSED. If it is accepted, descent is still
#                     enough and nothing has changed.
#   handed child      MUST SUCCEED. If it is refused, the mediator is simply
#                     stricter than the desktop can live with -- which would
#                     score the first arm for the wrong reason and break every
#                     toolkit-spawned task the moment the flag went on.
#
# THE UID IS THE OTHER HALF OF THE TRAP. The holder and both children run as
# uid 1002 while the segment is owned by 1001, so hostowner() answers 0 for all
# of them and cannot short-circuit anything. A gate run as one uid would have
# every arm accepted by the host-owner rule and would be measuring nothing --
# the trap stage 2's first identity attempt fell into.
#
# AND THE RED ARM: the same un-handed child, with HAMWSYS_SERVER out of its
# environment, writing through the ordinary file protocol, MUST STILL LAND. It
# is the ancestry rule the mediator inherits when the server is off; if it ever
# stopped working, the refusal in the routed arm would be unattributable.
#
# THE NEGATIVE CONTROL, RUN AND WRITTEN DOWN: replace the routed question with
# the walk -- make owns_wid() call owns_wid_ancestry() unconditionally in
# user/linux-wsys.c, which is the one line stage 5 consists of -- and this file
# goes from 10 passed / 0 failed to 6 passed / 4 failed:
#
#   FAIL the un-handed child was ACCEPTED: descent still carries the capability
#   FAIL connrefused is 0: the server never refused anything the walk allowed
#   FAIL no row was ever claimed (claim=0)
#   FAIL no trace line shows ancestry=1 with owns_wid=0
#
# The RED arm and the HANDED arm stay green throughout, correctly: neither one
# is about the narrowing, which is why neither is evidence on its own.
#
# Offscreen, software, no ICD. /dev/dri is untouched. WSYS_VERSION stays 8.
set -uo pipefail
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail=0; pass=0
ok()   { printf 'srvco: PASS %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf 'srvco: FAIL %s\n' "$*"; fail=$((fail+1)); }
note() { printf 'srvco: .... %s\n' "$*"; }

# ======================================================================
# INNER HALF — runs inside the user namespace, as inner uid 0
# ======================================================================
if [ "${1:-}" = "--inner" ]; then
    W="$2"
    BIN="$W/bin"
    . "$W/reap.sh"
    reap_track "$W/reaped.inner"
    reap_on_exit

    # 0777 and NOT sticky, for the reason wsys_srv_identity.sh gives at length:
    # fs.protected_regular would otherwise refuse uid 1002 the O_RDWR open of a
    # segment uid 1001 created, and the gate would report a boundary holding
    # when what held was a sysctl.
    mkdir -p "$W/ws" "$W/noicd"; chmod 0777 "$W/ws"
    export HAMWSYS="$W/ws/seg" HAMWSYS_BB="$W/ws/seg.bb" HAMWSYS_IMG="$W/ws/img"
    export HAMFB_FILE="$W/ws/fb.raw" HAMFB_GEOM=1280x800
    export VK_ICD_FILENAMES="$W/noicd/none.json" HAMLINUX_VNC=none
    : >"$W/in"; chmod 666 "$W/in"; export HAMWSYSD_INPUT="$W/in"
    rm -f "$HAMWSYS" "$HAMWSYS.chrome" "$HAMWSYS_BB" "$HAMFB_FILE"

    as() { local u="$1"; shift
        if [ "$u" = 0 ]; then "$@"
        else setpriv --reuid="$u" --regid="$u" --clear-groups "$@"; fi; }
    BGPID=0
    as_bg() { local u="$1" out="$2" err="$3"; shift 3
        local pre=()
        [ "$u" = 0 ] || pre=(setpriv --reuid="$u" --regid="$u" --clear-groups)
        if [ "$err" = "-" ]; then ( exec "${pre[@]}" "$@" >"$out" 2>&1 ) &
        else                      ( exec "${pre[@]}" "$@" >"$out" 2>"$err" ) & fi
        BGPID=$!; reap_add "$BGPID"; }

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

    # ---- THE HOLDER: uid 1002, the toolkit's position -------------------
    # It is started BEFORE the window exists and waits for the row to be
    # stamped against its pid -- which is the real order: hamUId spawns the
    # child first and calls sys_wsys_alloc(pid) a moment later, and
    # lib/hamwid.ad waits out exactly that gap.
    as_bg 1002 "$W/holder.out" "$W/holder.err" \
          env HAMWSYS_SERVER=1 "$BIN/wsys_srv_probe" conngate 0 \
              "$BIN/wsys_uidgate"
    HP=$BGPID
    echo "== holderpid $HP"

    # ---- the on-behalf stamp, by the host owner -------------------------
    # `alloc <pid>` and not `newwindow`: this is hamUId's path, the one every
    # DE window is created through, and it is the path that has NO connection
    # to record because the process it names has not connected yet.
    PWID="$(as 0 "$BIN/wsys_srv_probe" alloc "$HP" 2>/dev/null | head -1)"
    echo "== wid ${PWID:-none}"
    if [ -n "${PWID:-}" ] && [ "${PWID:-0}" -ge 2 ]; then
        # decorate, or /dev/wsys/windows is EMPTY and every title comparison
        # below is "" against "" -- snap_windows() needs visible AND decorate.
        as 0 "$BIN/wsys_uidgate" chrome "/dev/wsys/$PWID/ctl" "decorate 1" \
            >/dev/null 2>&1
        # THE TITLE IS THE HOLDER'S STARTING GUN as well as the instrument:
        # conngate waits for a row that is stamped against it AND titled, so
        # the baseline below cannot be read after the arms have run.
        as 0 "$BIN/wsys_uidgate" chrome "/dev/wsys/$PWID/ctl" \
            "title STAMPED-NOT-YET-TOUCHED" >/dev/null 2>&1
        echo "== baseline $(as 1001 "$BIN/cat" /dev/wsys/windows 2>/dev/null \
                 | grep "^${PWID} " | head -1)"
    fi

    # The holder runs its three arms and exits with the failure count.
    for _ in $(seq 1 200); do kill -0 "$HP" 2>/dev/null || break; sleep 0.1; done
    wait "$HP" 2>/dev/null; HRC=$?
    echo "== holder.exit $HRC"
    sed 's/^/== holder: /' "$W/holder.out"
    sed 's/^/== holdererr: /' "$W/holder.err"
    echo "== final $(as 1001 "$BIN/cat" /dev/wsys/windows 2>/dev/null \
             | grep "^${PWID} " | head -1)"

    kill "$WP" 2>/dev/null; wait "$WP" 2>/dev/null

    # ==================================================================
    # THE FLAG UNSET, END TO END. A whole second compositor with
    # HAMWSYS_SERVER nowhere in its environment: an ordinary client must
    # still create, title and own a window, and a non-owner must still be
    # refused. Verified by measurement, not by reading the flag.
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
        as 1002 "$BIN/wsys_uidgate" chrome "/dev/wsys/$VWID2/ctl" \
            "title OFF-PWNED" >/dev/null 2>&1
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
# PRIVATE NAMESPACE FIRST -- before $W, before the build, before anything under
# /tmp exists. wsysd's names are compiled into it (/srv/wsys, /dev/shm/hamnix-wsys,
# /tmp/hamnix-wsys; see the table in tests/linux/private_ns.sh), so a run of this
# gate beside a live desktop is a collision and not an untidiness.
#
# THE HELPER'S ONE FIDELITY COST DOES NOT REACH THIS GATE. priv_ns_reexec makes
# geteuid() 0 in the OUTER shell, and this gate's outer half asserts nothing about
# a uid: every arm runs in the INNER namespace it builds for itself, where wsysd
# and the segment owner are 1001 and the holder and its children are 1002 exactly
# as before. What did need fixing is where those two ids come from -- see the
# two-case selection below.
. tests/linux/private_ns.sh
priv_ns_reexec "$@"
OUT="${SRV_WORK:-/home/david/.hamnix-build/wsrv-s5}"
BIN="$OUT/bin"; mkdir -p "$BIN"

for c in "${ADDER_HOST_AC:-}" "$PROJ/build/cutover/host_ac_llvm.elf" \
         "$PROJ/build/cutover/host_ac.elf" \
         "$(git -C "$PROJ" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/../build/cutover/host_ac.elf"; do
    [ -n "$c" ] && [ -x "$c" ] && { ADDER_HOST_AC="$c"; break; }
done
[ -n "${ADDER_HOST_AC:-}" ] || { echo "srvco: FAIL no host_ac.elf"; exit 2; }
export ADDER_HOST_AC
for t in wsysd:user/wsysd.ad cat:user/cat.ad \
         wsys_hold:tests/linux/wsys_hold.ad \
         wsys_uidgate:tests/linux/wsys_uidgate.ad \
         wsys_srv_probe:tests/linux/wsys_srv_probe.ad; do
    n="${t%%:*}"
    [ "${SRV_REBUILD:-1}" = 0 ] && [ -x "$BIN/$n" ] && continue
    scripts/hamlinux_build.sh "${t#*:}" "$BIN/$n" >"$OUT/build.$n.log" 2>&1 || {
        echo "srvco: FAIL could not build ${t#*:}"; tail -8 "$OUT/build.$n.log"
        exit 2; }
done

command -v unshare >/dev/null || { echo "srvco: SKIP no unshare(1)"; exit 0; }
command -v setpriv >/dev/null || { echo "srvco: SKIP no setpriv(1)"; exit 0; }

# WHERE THE SECOND AND THIRD UID COME FROM -- TWO CASES, AND THE SECOND ONE IS
# WHAT LETS THIS GATE BE ISOLATED AT ALL. Written up at length in
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
# into "FAIL namespace run rc=1" -- a gate reporting a defect it did not find.
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
    echo "srvco: SKIP no /etc/subuid range for $(id -un), and this namespace does"
    echo "srvco: SKIP not already own uids 1001 and 1002; run this in the VM"
    exit 0
fi
note "$(priv_ns_describe)"
note "the two extra uids: $IDSRC"

W="$(mktemp -d "${TMPDIR:-/tmp}/wsrvco.XXXXXX")"
trap 'rm -rf "$W"' EXIT
trap 'exit 130' INT TERM HUP
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
sed 's/^/srvco|  /' "$OUTF"
[ $rc -eq 0 ] || { echo "srvco: FAIL namespace run rc=$rc"; exit 2; }

f() { grep -m1 "^== $1" "$OUTF" | sed "s/^== $1 *//"; }
# A SUBSTRING MATCH, not an anchored one: every holder line is prefixed with
# its own "wsrvcg: " tag, and an anchored pattern silently matched nothing --
# which scored three arms "indeterminate" while the run underneath had produced
# exactly the answers they were looking for.
h() { grep -m1 "^== holder: .*$1" "$OUTF" | sed 's/^== holder: //'; }

SEGOWN="$(f segowner)"; PWID="$(f wid)"; HPID="$(f holderpid)"
note "segment owner uid $SEGOWN; the holder and both children are uid 1002, so hostowner() cannot short-circuit any arm below"
if [ "$SEGOWN" = 1001 ]; then
    ok "the host owner is uid 1001 and every process under test is uid 1002 -- the two identities that would otherwise decide these arms are genuinely different"
else
    bad "the segment is owned by uid '$SEGOWN', not 1001 -- a uid-1002 holder may be the host owner and every arm would be granted for the wrong reason"
fi

# ---- the instrument must be able to produce a non-empty answer ----------
# WHICH TITLE IT CARRIES IS A RACE AND IS NOT THE POINT. The holder starts the
# moment the row is titled, so the baseline read can land after the holder's own
# routed write -- both were observed. What must hold is that the window ENUMERATES
# WITH A TITLE THIS RUN SET: /dev/wsys/windows skips any window that is not both
# visible and decorate, and an empty file would make every title read below "" and
# every comparison vacuous.
BASE="$(f baseline)"
if printf '%s' "$BASE" | grep -qE 'STAMPED-NOT-YET-TOUCHED|DESC-UNROUTED|HOLDER-OWN-TITLE|PWNED-BY-A-STRANGER'; then
    ok "the stamped window enumerates with a title this run set (\"$BASE\") -- the instrument can produce a non-empty answer, so a title read below is a reading and not a blank"
else
    bad "the stamped window does not enumerate with any title this run set (got \"$BASE\") -- it is undecorated or absent, and every title read below would be vacuous"
fi

if [ -z "$PWID" ] || [ "$PWID" = none ] || [ "${PWID:-0}" -lt 2 ]; then
    bad "no window was stamped against the holder (alloc said \"$PWID\") -- the property is UNMEASURED, which is not the same as sound"
else
    note "window $PWID is stamped against pid $HPID (the holder) by the HOST OWNER's on-behalf path -- hamUId's path, the one every DE window is created through, and the one with no connection to record"
fi

# ---- THE RED ARM: unrouted descent still works -------------------------
note "RED ARM -- the un-handed child with HAMWSYS_SERVER out of its environment, writing through the ordinary file protocol:"
UN="$(h 'UNROUTED descendant')"
note "${UN:-<no line>}"
if printf '%s' "$UN" | grep -q 'exit 0'; then
    ok "UNROUTED: a plain child of the window's owner still drives the window. The rule is INHERITED, not introduced -- and it is what makes the routed refusal below attributable to the mediator rather than to nothing having been attempted."
else
    bad "the unrouted descendant was refused (\"$UN\") -- the in-process path has changed, and every routed arm below is unattributable"
fi

# ---- ARM 1: the un-handed child, routed --------------------------------
note "the pair. Same binary, same spawner, same window, same uid; ONE difference:"
NOH="$(h 'child WITHOUT the connection')"
HAND="$(h 'child WITH the connection')"
note "${NOH:-<no line>}"
note "${HAND:-<no line>}"
if printf '%s' "$NOH" | grep -q 'REFUSED'; then
    ok "a child of the window's owner that was NOT handed the connection is REFUSED -- descent is no longer sufficient, which is the whole of what stage 5 changes"
elif printf '%s' "$NOH" | grep -q 'ACCEPTED'; then
    bad "the un-handed child was ACCEPTED: descent still carries the capability and nothing has changed"
else
    bad "the un-handed arm is indeterminate (\"$NOH\") -- refusing to score it either way"
fi
if printf '%s' "$HAND" | grep -q 'ACCEPTED'; then
    ok "the SAME child, handed the connection, SUCCEEDS -- so the refusal above is the connection question and not a mediator that refuses everything, and a toolkit can still put a task into the window it spawned it for"
elif printf '%s' "$HAND" | grep -q 'REFUSED'; then
    bad "the handed child was REFUSED: the mediator is stricter than the desktop can live with, and the arm above scored for the wrong reason. Every toolkit-spawned task would be unable to drive its own window."
else
    bad "the handed arm is indeterminate (\"$HAND\")"
fi

# ---- the server's own count of what the new rule refused ---------------
note "the server's counters, because a rule that never refuses anything and no rule at all are the same thing from outside:"
CNT="$(grep -m1 '^== holder: wsrvcg: server counters at the end' "$OUTF" \
       | sed 's/^== holder: wsrvcg: server counters at the end: //')"
note "${CNT:-<none>}"
CR="$(printf '%s' "$CNT" | sed -n 's/.*connrefused \([0-9]*\).*/\1/p')"
CL="$(printf '%s' "$CNT" | sed -n 's/.*claim \([0-9]*\).*/\1/p')"
if [ "${CR:-0}" -ge 1 ]; then
    ok "the server counted $CR mutation(s) that THE WALK WOULD HAVE GRANTED and the connection rule refused -- the change is a number and not a claim"
else
    bad "connrefused is ${CR:-<absent>}: the server never refused anything the walk would have allowed, so either the child was not a descendant or the new rule never fired"
fi
if [ "${CL:-0}" -ge 1 ]; then
    ok "the on-behalf row was CLAIMED by an exact-pid match ($CL claim(s)) -- the DE's path, which has no connection at allocation time, still acquires a holder"
else
    bad "no row was ever claimed (claim=${CL:-<absent>}), so the handed arm cannot have passed for the reason this gate says it did"
fi

# ---- what the two questions answered, from inside ----------------------
note "the two answers, printed by the server from inside srv_as_caller(). A line reading ancestry=1 owns_wid=0 IS the narrowing:"
grep '^== trace wsrvtrace: caller uid=1002' "$OUTF" | sed 's/^== trace /srvco|      /' | sort -u | head -8
if grep -q '^== trace wsrvtrace: caller uid=1002.*owns_wid=0 ancestry=1' "$OUTF"; then
    ok "MEASURED FROM INSIDE: a caller the parent-pid walk would have granted (ancestry=1) was refused by the connection question (owns_wid=0). The walk was not narrowed; it stopped being the only question asked."
else
    bad "no trace line shows ancestry=1 with owns_wid=0 -- what the two questions answered is UNMEASURED, and an empty result is not a finding"
fi

# ---- the flag unset, verified by measurement ---------------------------
note "HAMWSYS_SERVER unset everywhere -- a second compositor, verified rather than assumed:"
OFFT="$(f off.title)"; OFFA="$(f off.after)"
if printf '%s' "$OFFT" | grep -q 'OFF-PATH-TITLE'; then
    ok "with the flag unset a client still maps and titles its own window (\"$OFFT\")"
else
    bad "with the flag unset the client could not map/title a window (\"$OFFT\") -- stage 5 broke the unrouted path"
fi
if printf '%s' "$OFFA" | grep -q 'OFF-PWNED'; then
    bad "with the flag unset an ordinary non-owner renamed the window -- the in-process check regressed"
elif [ -n "$OFFA" ]; then
    ok "with the flag unset an ordinary non-owner is still refused (\"$OFFA\")"
else
    bad "the flag-unset arm produced no title at all -- refusing to read an empty result as a pass"
fi

note "NOT COVERED HERE, and it is the next piece of work: the DE's own spawn path does not call the handoff yet. /etc/rc.de-user runs the real program as a CHILD of the hamsh the wid is stamped against, so with HAMWSYS_SERVER=1 a DE application would be refused its own window until user/hamUId.ad or hamsh calls sys_wsys_srv_handoff around that spawn. The flag is off by default and nothing ships with it on."

echo "srvco: $pass passed, $fail failed"
[ "$fail" = 0 ]
