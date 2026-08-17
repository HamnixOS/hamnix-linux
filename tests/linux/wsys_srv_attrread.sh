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
# wsys_srv_attrread.sh — STAGE 9: WHO MAY READ A WINDOW'S ATTRIBUTES.
#
# WHAT THIS GATE IS FOR
# =====================
# Stage 4 landed an enumeration policy on /dev/wsys/windows and stage 8 routed
# wid/wctl's WRITE arm. docs/wsys_server_design.md §7.1 then measured the
# policy WITH THE MEDIATOR LIVE and found it withholding the title and only the
# title: a uid-1002 process owning nothing, against a uid-1001 victim, still
# read
#
#     cat /dev/wsys        -> ctl self windows screen pool 2
#     cat /dev/wsys/2/ctl  -> 2 100 100 300 200 5 1 1 1 0 0 0 0 0
#     cat /dev/wsys/2/wctl -> 100 100 300 200 click
#
# on the same run on which the routed `windows` read answered that same process
# EMPTY. srv_route_read() carried WINDOWS, SCREEN and POOL and ended
# `default: return 0`. This gate is the pair for the three leaves stage 9 adds
# to it.
#
#   RED    (HAMWSYS_SERVER unset) a window-less uid-1002 process reads the
#          victim's geometry and the wid set out of shared memory. MUST SUCCEED
#          -- it is the state of the tree until WSYS_VERSION is bumped, and a
#          red arm that has quietly gone green makes the green arm
#          unattributable.
#   GREEN  (HAMWSYS_SERVER=1) the identical process, identical uid, identical
#          files: ctl and wctl are ENOENT, and /dev/wsys lists the fixed names
#          with NOT ONE WID.
#
# THERE ARE TWO RULES AND THE SPLIT IS THE SHAPE OF THE QUESTION, not a
# compromise. A DIRECTORY asks which windows there are -- a question about the
# SET, and `windows` is the same question under another name, so it takes
# stage 4's enumeration tier (the host owner, or any caller that owns a
# window). <wid>/ctl and <wid>/wctl name ONE window, so they take the rule
# their own WRITE arms already apply, `hostowner() || owns_wid_ancestry(wid)`
# -- the same one the four event rings took in commit 0f80d3e5. A leaf whose
# read and write answer to different rules is two policies wearing one path.
#
# THE PER-WINDOW RULE IS THE TIGHTER OF THE TWO AND IT WAS MEASURED FREE. The
# worry it has to answer is that the panel and the compositor legitimately read
# attributes of windows they do not own. Swept over the tree: the ONLY reader
# of a foreign <wid>/ctl anywhere is user/wsysd.ad's load_window(), called from
# scan_windows() for every wid in the directory -- and wsysd is srv_is_server
# (it never routes) and is the host owner besides. hampanelscene's taskbar
# reads /dev/wsys/windows and never a foreign <wid>/ctl. lib/hamui.ad, hamUId,
# hamdesktop and hamappmenu open both leaves WRITE-ONLY. So nothing on the
# desktop pays for it, and wsys_srv_deboot.sh is run to say so out loud.
#
# The middle group of arms is where the two rules are separated, BY ONE
# PROCESS: a uid-1002 client that owns its own window is refused the VICTIM's
# ctl and wctl, is granted its OWN, and gets the FULL directory. A blanket
# allow and a blanket deny each go red on half of that group.
#
# THE TRAP THIS FILE WAS WRITTEN AGAINST, AND IT CAUGHT THE LAST STAGE'S GATE:
# every arm here runs through the client's ORDINARY read path, so A BUILD THAT
# ROUTED NOTHING WOULD PASS THE LOT -- both arms would take the in-process path
# and agree perfectly, and "routing changes nothing a person can see" and
# "nothing was routed" produce the same green. So the server's own trace NAMES
# THE LEAF (`wsrvtrace: read caller uid=.. pid=.. -> leaf=wid/ctl ..`) and the
# crossings are COUNTED SCOPED TO THE CLIENT'S OWN PID, which the client
# reports itself before exec'ing. Routed must be non-zero, unrouted must be
# exactly zero, per leaf.
#
# WHY TWO UIDS: identical to wsys_enum_policy.sh. The policy grants the host
# owner everything, so a single-uid gate's "stranger" IS the host owner and the
# gate would report the policy absent when it was present. `unshare -U
# --map-users` with three ids; wsysd as 1001, victim 1001, snooper 1002.
#
# Offscreen, software, no ICD. /dev/dri is untouched.
set -uo pipefail
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

pass=0; fail=0
ok()   { printf 'attrrd: PASS %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf 'attrrd: FAIL %s\n' "$*"; fail=$((fail+1)); }
note() { printf 'attrrd: .... %s\n' "$*"; }

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
    # open of a file in a world-writable STICKY directory, so under 1777 the
    # uid-1002 arms would fail to open the segment at all and this gate would
    # score the sysctl as the policy. (wsys_srv_identity.sh, at length.)
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

    # A READ BY A NAMED CLIENT WHOSE PID IS ON THE RECORD.  The whole point of
    # the counting arms is that "it was actually routed" must be visible from
    # OUTSIDE the process, and the server's trace keys on the peer pid.  `exec`
    # keeps the pid the shell just printed, so the number in $3 is the pid the
    # kernel hands the server in SO_PEERCRED.
    #   catpid <uid> <pidfile> <routed:0|1> <path>
    catpid() { local u="$1" pf="$2" r="$3" p="$4"; shift 4
        local env=()
        [ "$r" = 1 ] && env=(env HAMWSYS_SERVER=1) || env=(env -u HAMWSYS_SERVER)
        as "$u" bash -c 'echo $$ >"$1"; shift; exec "$@"' _ "$pf" \
           "${env[@]}" "$BIN/cat" "$p"; }

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
    # wsys_hold and not a one-shot: win_reap_dead() destroys a window whose
    # owner has exited, so a creator that exits leaves nothing to read and
    # every arm below would be comparing "" against "".
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
    # A DISTINCTIVE GEOMETRY, because "0 0 0 0" is what an unread instrument
    # also says.  `decorate 1` additionally puts the window in snap_windows()'s
    # list, which is what makes the enumeration regression arm mean anything.
    printf 'ctl decorate 1\nctl title VICTIM-ATTR-TITLE\nctl geometry 137 241 353 179\n' \
        >>"$W/vscript"
    sleep 1.2

    one() { tr '\n' ' ' | sed 's/  */ /g'; }
    VC="/dev/wsys/$VWID/ctl"; VW="/dev/wsys/$VWID/wctl"

    # ---- the instrument, first: a permitted caller must see something -----
    echo "== hostctl  $(as 1001 env HAMWSYS_SERVER=1 "$BIN/cat" "$VC" 2>&1 | one)"
    echo "== hostwctl $(as 1001 env HAMWSYS_SERVER=1 "$BIN/cat" "$VW" 2>&1 | one)"
    echo "== hostdir  $(as 1001 env HAMWSYS_SERVER=1 "$BIN/cat" /dev/wsys 2>&1 | one)"

    # ---- EQUALITY: the same permitted caller, unrouted ---------------------
    # Routing must change WHO may read, not WHAT is read.
    echo "== hostctlu  $(as 1001 env -u HAMWSYS_SERVER "$BIN/cat" "$VC" 2>&1 | one)"
    echo "== hostwctlu $(as 1001 env -u HAMWSYS_SERVER "$BIN/cat" "$VW" 2>&1 | one)"
    echo "== hostdiru  $(as 1001 env -u HAMWSYS_SERVER "$BIN/cat" /dev/wsys 2>&1 | one)"

    # ---- RED: unrouted, uid 1002, owns nothing ---------------------------
    echo "== redctl  $(catpid 1002 "$W/p.rc" 0 "$VC"        2>/dev/null | one)"
    echo "== redwctl $(catpid 1002 "$W/p.rw" 0 "$VW"        2>/dev/null | one)"
    echo "== reddir  $(catpid 1002 "$W/p.rd" 0 /dev/wsys    2>/dev/null | one)"

    # ---- GREEN: routed, same uid, same files -----------------------------
    echo "== grnctl  $(catpid 1002 "$W/p.gc" 1 "$VC"     2>>"$W/err.gc" | one)"
    echo "== grnctlrc $?"
    echo "== grnwctl $(catpid 1002 "$W/p.gw" 1 "$VW"     2>>"$W/err.gw" | one)"
    echo "== grnwctlrc $?"
    echo "== grndir  $(catpid 1002 "$W/p.gd" 1 /dev/wsys 2>>"$W/err.gd" | one)"
    echo "== grndirrc $?"
    echo "== grnwindows $(as 1002 env HAMWSYS_SERVER=1 "$BIN/cat" \
                          /dev/wsys/windows 2>/dev/null | one)"
    # And the sub-directory: /dev/wsys/<wid> is the third spelling of existence.
    echo "== grnsubdir $(as 1002 env HAMWSYS_SERVER=1 "$BIN/cat" \
                         "/dev/wsys/$VWID" 2>/dev/null | one)"
    echo "== redsubdir $(as 1002 env -u HAMWSYS_SERVER "$BIN/cat" \
                         "/dev/wsys/$VWID" 2>/dev/null | one)"

    # ---- THE PANEL-SHAPED READER: uid 1002 that OWNS a window ------------
    : >"$W/ascript"; chmod 666 "$W/ascript"
    as_bg 1002 "$W/owner.out" "$W/owner.log" \
          env HAMWSYS_SERVER=1 "$BIN/wsys_hold" "$W/ascript"
    AP=$BGPID
    for _ in $(seq 1 100); do [ -s "$W/owner.out" ] && break; sleep 0.1; done
    AWID="$(head -1 "$W/owner.out" | tr -d '\n' 2>/dev/null || true)"
    echo "== ownerwid ${AWID:-none}"
    echo "== ownerpid $AP"
    printf 'ctl decorate 1\nctl title OWNER-1002-WINDOW\nctl geometry 611 97 222 144\n' \
        >>"$W/ascript"
    sleep 1.0
    printf 'slurp %s\n' "$VC" >>"$W/ascript"; sleep 0.8
    printf 'slurp %s\n' "$VW" >>"$W/ascript"; sleep 0.8
    printf 'slurp /dev/wsys\n'                        >>"$W/ascript"; sleep 0.8
    printf 'slurp /dev/wsys/%s/ctl\n'  "$AWID"        >>"$W/ascript"; sleep 0.8
    printf 'slurp /dev/wsys/%s/wctl\n' "$AWID"        >>"$W/ascript"; sleep 0.8
    # FIVE slurps in order, so each is cut out by ordinal rather than by
    # content -- matching on content would make an arm that reads the wrong
    # file pass whenever the right one happened to be printed earlier.
    # THE NEWLINES COME OUT FIRST, and that is not tidiness: a slurped ctl body
    # ENDS in a newline, so `grep -o` over the raw file cannot match a record
    # that spans lines and every arm below would read empty -- which is exactly
    # what a refusal looks like. Flatten, then cut by ordinal.
    tr '\n' ' ' <"$W/owner.out" >"$W/owner.flat"
    for k in 1 2 3 4 5; do
        echo "== owner$k $(grep -o 'SLURP<[^>]*>SLURP' "$W/owner.flat" \
                           | sed -n "${k}p" | sed 's/^SLURP<//; s/>SLURP$//' \
                           | sed 's/  */ /g')"
    done

    # ---- and a window-LESS uid 1002 STILL sees nothing -------------------
    echo "== grnctl2 $(as 1002 env HAMWSYS_SERVER=1 "$BIN/cat" "$VC" 2>/dev/null | one)"

    sleep 0.4
    # ---- THE CROSSINGS, SCOPED TO EACH CLIENT'S OWN PID ------------------
    for t in gc:wid/ctl gw:wid/wctl gd:dir rc:wid/ctl rw:wid/wctl rd:dir; do
        tag="${t%%:*}"; lf="${t#*:}"
        p="$(cat "$W/p.$tag" 2>/dev/null || echo 0)"
        c=$(grep -c "wsrvtrace: read caller uid=1002 pid=$p .*leaf=$lf" \
            "$W/wsysd.log" 2>/dev/null || true)
        echo "== cross.$tag pid=$p leaf=$lf n=${c:-0}"
    done
    echo "== tracefull $(grep -c 'wsrvtrace: read .*tier=FULL' "$W/wsysd.log")"
    echo "== traceempty $(grep -c 'wsrvtrace: read .*tier=EMPTY' "$W/wsysd.log")"
    grep 'wsrvtrace: read' "$W/wsysd.log" | tail -30 | sed 's/^/== trace /'
    for e in gc gw gd; do
        [ -s "$W/err.$e" ] && sed "s/^/== err.$e /" "$W/err.$e"
    done
    kill "$AP" "$VP" "$WP" 2>/dev/null
    exit 0
fi

# ======================================================================
# OUTER HALF
# ======================================================================
cd "$PROJ"
# PRIVATE NAMESPACE FIRST. wsysd's names are compiled into it -- /srv/wsys,
# /dev/shm/hamnix-wsys, /tmp/hamnix-wsys -- so a run of this gate beside a live
# desktop is a collision, not an untidiness (tests/linux/private_ns.sh). Every
# assertion below is about the INNER namespace's uids, so the helper's fidelity
# cost does not reach this gate -- the same reasoning wsys_enum_policy.sh gives.
. tests/linux/private_ns.sh
priv_ns_reexec "$@"

SCRATCH_BASE="${SRV_SCRATCH_BASE:-/home/david/.hamnix-build}"
if [ -n "${SRV_WORK:-}" ]; then
    OUT="$SRV_WORK"; OUT_EPHEMERAL=0
    mkdir -p "$OUT" || { echo "attrrd: FAIL cannot make $OUT"; exit 2; }
else
    mkdir -p "$SCRATCH_BASE" || { echo "attrrd: FAIL cannot make $SCRATCH_BASE"; exit 2; }
    OUT="$(mktemp -d "$SCRATCH_BASE/wsrv-attrrd.XXXXXX")" || {
        echo "attrrd: FAIL cannot make a scratch dir under $SCRATCH_BASE"; exit 2; }
    OUT_EPHEMERAL=1
fi
BIN="$OUT/bin"; mkdir -p "$BIN"

for c in "${ADDER_HOST_AC:-}" "$PROJ/build/cutover/host_ac_llvm.elf" \
         "$PROJ/build/cutover/host_ac.elf" \
         "$(git -C "$PROJ" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/../build/cutover/host_ac.elf"; do
    [ -n "$c" ] && [ -x "$c" ] && { ADDER_HOST_AC="$c"; break; }
done
[ -n "${ADDER_HOST_AC:-}" ] || { echo "attrrd: FAIL no host_ac.elf"; exit 2; }
export ADDER_HOST_AC HAMLINUX_DISTRO_RO=1
for t in wsysd:user/wsysd.ad cat:user/cat.ad \
         wsys_hold:tests/linux/wsys_hold.ad; do
    n="${t%%:*}"
    [ "${SRV_REBUILD:-1}" = 0 ] && [ -x "$BIN/$n" ] && continue
    scripts/hamlinux_build.sh "${t#*:}" "$BIN/$n" >"$OUT/build.$n.log" 2>&1 || {
        echo "attrrd: FAIL could not build ${t#*:}"; tail -8 "$OUT/build.$n.log"
        exit 2; }
done

command -v unshare >/dev/null || { echo "attrrd: SKIP no unshare(1)"; exit 0; }
command -v setpriv >/dev/null || { echo "attrrd: SKIP no setpriv(1)"; exit 0; }

# WHERE THE SECOND AND THIRD UID COME FROM -- two cases, and the second is what
# lets this gate be isolated at all. Verbatim from wsys_enum_policy.sh, whose
# comment explains why the test is the MAPPING ATTEMPT and not a read of
# /proc/self/uid_map.
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
    echo "attrrd: SKIP no /etc/subuid range for $(id -un), and this namespace"
    echo "attrrd: SKIP does not already own uids 1001 and 1002; run this in the VM"
    exit 0
fi

note "$(priv_ns_describe)"
note "the two extra uids: $IDSRC"

W="$(mktemp -d "${TMPDIR:-/tmp}/attrrd.XXXXXX")"
trap 'rm -rf "$W"; [ "${OUT_EPHEMERAL:-0}" = 1 ] && rm -rf "$OUT"' EXIT
trap 'exit 130' INT TERM HUP
chmod 1777 "$W"
mkdir -p "$W/bin"; cp "$BIN"/wsysd "$BIN"/cat "$BIN"/wsys_hold "$W/bin/"
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
sed 's/^/attrrd|  /' "$OUTF"
[ $rc -eq 0 ] || { echo "attrrd: FAIL namespace run rc=$rc"; exit 2; }

f() { grep -m1 "^== $1 " "$OUTF" | sed "s/^== $1 *//"; }

SEGOWN="$(f segowner)"; VWID="$(f victimwid)"
note "segment owner uid $SEGOWN; victim window $VWID owned by uid 1001 at geometry 137 241 353 179; the snooper is uid 1002 and owns nothing"
if [ "$SEGOWN" = 1001 ]; then
    ok "the host owner is uid 1001 and the snooper is a different uid -- the two identities every arm below turns on are genuinely different"
else
    bad "the segment is owned by uid '$SEGOWN', not 1001 -- the uid separation this gate rests on did not happen"
fi

if printf '%s' "$(f readserver)" | grep -q 'read server pid'; then
    ok "wsysd forked a read server OFF the frame loop: $(f readserver)"
else
    bad "no read server was started -- every routed arm below would be falling back to the unmediated in-process read, which is the state this gate exists to distinguish from a policy"
fi

# ---------- the instrument must be able to produce a real answer ----------
HC="$(f hostctl)"; HW="$(f hostwctl)"; HD="$(f hostdir)"
INSTR=1
if printf '%s' "$HC" | grep -q '137 241 353 179'; then
    ok "the wid/ctl instrument reads back the victim's real geometry through the server (\"$HC\") -- a refusal below is a comparison and not a broken read"
else
    bad "the routed wid/ctl read never showed the victim's geometry (got \"$HC\"); every refusal below would be vacuous"; INSTR=0
fi
if printf '%s' "$HW" | grep -q '137 241 353 179'; then
    ok "the wid/wctl instrument reads back the victim's live rect through the server (\"$HW\")"
else
    bad "the routed wid/wctl read never showed the victim's rect (got \"$HW\")"; INSTR=0
fi
if printf '%s' "$HD" | grep -qw "$VWID"; then
    ok "the directory instrument lists window $VWID through the server (\"$HD\")"
else
    bad "the routed directory read never listed window $VWID (got \"$HD\")"; INSTR=0
fi
if [ "$INSTR" = 0 ]; then
    echo "attrrd: $pass passed, $fail failed"; exit 1
fi

# ---------- ROUTING MUST CHANGE WHO, NOT WHAT ----------------------------
note "EQUALITY -- the same permitted caller, routed against unrouted, on all three leaves:"
eq() { local n="$1" a="$2" b="$3"
    if [ "$a" = "$b" ]; then
        ok "$n reads BYTE-IDENTICAL routed and unrouted (\"$a\")"
    else
        bad "$n differs: routed \"$a\" unrouted \"$b\". Routing is supposed to change who may read, not what is read."
    fi; }
eq "wid/ctl"  "$HC" "$(f hostctlu)"
eq "wid/wctl" "$HW" "$(f hostwctlu)"
eq "dir"      "$HD" "$(f hostdiru)"

# ---------- RED: it must still fail open ---------------------------------
note "RED ARM -- uid 1002, owns no window, HAMWSYS_SERVER unset, reading the same three files:"
RC="$(f redctl)"; RW="$(f redwctl)"; RD="$(f reddir)"; RS="$(f redsubdir)"
if printf '%s' "$RC" | grep -q '137 241 353 179'; then
    ok "UNROUTED: a window-less uid-1002 process read uid 1001's window geometry -> \"$RC\". IT WORKS AND IT IS SUPPOSED TO: that was the snooper's own linked-in code answering from a MAP_SHARED segment with a live mediator standing next to it, unable to see it. It is the hole WSYS_VERSION 8 -> 9 exists to close."
else
    bad "the unrouted wid/ctl read did NOT see the geometry (\"$RC\"). The instrument is not looking, so the routed refusal below is unattributable."
fi
if printf '%s' "$RW" | grep -q '137 241 353 179'; then
    ok "UNROUTED: the same process read the victim's LIVE RECT -> \"$RW\""
else
    bad "the unrouted wid/wctl read did NOT see the rect (\"$RW\")"
fi
if printf '%s' "$RD" | grep -qw "$VWID"; then
    ok "UNROUTED: the same process listed the victim's window id from the DIRECTORY -> \"$RD\". This is the leaf that walked past stage 4's enumeration policy one path component up."
else
    bad "the unrouted directory read did NOT list window $VWID (\"$RD\")"
fi
if printf '%s' "$RS" | grep -q 'scene'; then
    ok "UNROUTED: /dev/wsys/$VWID listed the victim's own leaves -> \"$RS\""
else
    bad "the unrouted /dev/wsys/$VWID read showed nothing (\"$RS\")"
fi

# ---------- GREEN: the same reads, routed --------------------------------
note "GREEN ARM -- the identical uid, the identical files, routed:"
GC="$(f grnctl)"; GW="$(f grnwctl)"; GD="$(f grndir)"; GS="$(f grnsubdir)"
if printf '%s' "$GC" | grep -q '137'; then
    bad "ROUTED: a window-less uid-1002 process STILL read the victim's geometry -> \"$GC\". wid/ctl is not mediated."
elif [ -z "$GC" ]; then
    ok "ROUTED: the read server REFUSED a window-less uid-1002 caller's wid/ctl read. $(grep -m1 "err.gc" "$OUTF" | sed 's/^== err.gc //')"
else
    bad "ROUTED: the wid/ctl answer was neither empty nor the geometry -> \"$GC\""
fi
if printf '%s' "$GW" | grep -q '137'; then
    bad "ROUTED: a window-less uid-1002 process STILL read the victim's live rect -> \"$GW\""
elif [ -z "$GW" ]; then
    ok "ROUTED: the read server REFUSED the same caller's wid/wctl read"
else
    bad "ROUTED: the wid/wctl answer was neither empty nor the rect -> \"$GW\""
fi
if printf '%s' "$GD" | grep -qw "$VWID"; then
    bad "ROUTED: /dev/wsys STILL listed window $VWID to a caller that owns nothing -> \"$GD\". The directory is the third spelling of enumeration and it is not mediated."
elif printf '%s' "$GD" | grep -q 'windows'; then
    ok "ROUTED: /dev/wsys listed the fixed names and NOT ONE WID -> \"$GD\". The caller can still reach /dev/wsys/windows -- and be told nothing by it -- which is why this leaf answers rather than refuses."
else
    bad "ROUTED: /dev/wsys came back \"$GD\" -- neither the fixed names nor the full listing. A caller that cannot list the device at all cannot open /dev/wsys/windows, which is where the policy is supposed to say no."
fi
if printf '%s' "$GS" | grep -q 'scene'; then
    bad "ROUTED: /dev/wsys/$VWID still listed the victim's leaves to a caller that owns nothing -> \"$GS\""
else
    ok "ROUTED: /dev/wsys/$VWID answered nothing to the same caller (\"$GS\") -- existence itself is withheld"
fi
GWIN="$(f grnwindows)"
if [ -z "$GWIN" ]; then
    ok "and stage 4's own arm is unregressed: the routed /dev/wsys/windows read is still EMPTY for this caller"
else
    bad "the routed /dev/wsys/windows read returned \"$GWIN\" -- stage 4's policy has regressed"
fi

# ---------- THE TWO RULES, SEPARATED BY ONE PROCESS ----------------------
# The reader here is uid 1002 and OWNS A WINDOW. It is therefore in the
# enumeration tier (so the DIRECTORY answers it in full, exactly as `windows`
# does) and it does NOT own the victim's window (so the two PER-WINDOW leaves
# refuse it). One process, five reads, and the pair of outcomes IS the claim
# that these two leaves take different rules on purpose. A blanket-allow and a
# blanket-deny each go red on half of it.
AWID="$(f ownerwid)"
O1="$(f owner1)"; O2="$(f owner2)"; O3="$(f owner3)"
O4="$(f owner4)"; O5="$(f owner5)"
note "uid 1002 now owns window ${AWID:-none} at 611 97 222 144, and from inside that process reads the VICTIM's ctl and wctl, the directory, and its OWN ctl and wctl:"
if [ -z "${AWID:-}" ] || [ "${AWID:-0}" -lt 2 ]; then
    bad "the uid-1002 client never got a window of its own -- the arms that separate the two rules could not run"
else
    if printf '%s' "$O1" | grep -q '137'; then
        bad "a uid-1002 process that owns a DIFFERENT window read the victim's wid/ctl -> \"$O1\". The per-window rule has collapsed to the enumeration tier: every application on the desktop reads every other application's geometry."
    else
        ok "PER-WINDOW: a uid-1002 process that owns window $AWID was REFUSED the victim's wid/ctl (\"$O1\"). It neither owns window $VWID nor descends from its owner, and that is the whole of the check -- \`hostowner() || owns_wid_ancestry(wid)\`, the same rule this leaf's WRITE arm already applies."
    fi
    if printf '%s' "$O2" | grep -q '137'; then
        bad "the same process read the victim's wid/wctl -> \"$O2\" -- wid/wctl's read takes a weaker rule than its write"
    else
        ok "PER-WINDOW: the same process was REFUSED the victim's wid/wctl (\"$O2\")"
    fi
    # THE ARM THAT KEEPS THE TWO ABOVE HONEST. A server that refused everything
    # would score both of them, and would break the desktop.
    if printf '%s' "$O4" | grep -q '611 97 222 144'; then
        ok "and the SAME process reads its OWN window's ctl in full -> \"$O4\". The two refusals above are a decision about the window, not a server that answers nobody."
    else
        bad "a uid-1002 process could not read its OWN window's ctl (\"$O4\") -- the per-window rule refuses the owner, which is a broken desktop and not a policy"
    fi
    if printf '%s' "$O5" | grep -q '611 97 222 144'; then
        ok "and its OWN window's wctl -> \"$O5\""
    else
        bad "a uid-1002 process could not read its OWN window's wctl (\"$O5\")"
    fi
    if printf '%s' "$O3" | grep -qw "$VWID"; then
        ok "THE TIER: the same process, which the two per-window leaves just refused, gets the FULL directory including window $VWID -> \"$O3\". The rule for a set-shaped question is ownership of ANY window and not of THIS one -- it is stage 4's rule, and it is what keeps the taskbar working. A uid-only policy would be red here; so would one rule for all four leaves."
    else
        bad "a uid-1002 WINDOW OWNER got no wids from the directory (\"$O3\"). The directory has taken the per-window rule, which no directory can answer -- the caller has not named a window."
    fi
fi

G2="$(f grnctl2)"
if [ -z "$G2" ]; then
    ok "and the window-LESS uid-1002 process is STILL refused while a uid-1002 window exists -- the grant is per-caller, not per-uid"
else
    bad "a window-less uid-1002 process read \"$G2\" once ANY uid-1002 window existed -- the check is answering about the uid, not about the caller"
fi

# ---------- THE ARMS THAT MAKE "IT WAS ROUTED" VISIBLE FROM OUTSIDE ------
note "THE CROSSINGS. Every arm above runs through the client's ORDINARY read path, so a build that routed NOTHING would pass all of them -- both arms would take the in-process path and agree perfectly. These count the server's own trace, scoped to each client's own pid, per leaf:"
for t in gc:wid/ctl:routed gw:wid/wctl:routed gd:dir:routed \
         rc:wid/ctl:unrouted rw:wid/wctl:unrouted rd:dir:unrouted; do
    tag="${t%%:*}"; rest="${t#*:}"; lf="${rest%%:*}"; arm="${rest#*:}"
    line="$(grep -m1 "^== cross.$tag " "$OUTF")"
    n="$(printf '%s' "$line" | sed -n 's/.* n=\([0-9]*\).*/\1/p')"
    p="$(printf '%s' "$line" | sed -n 's/.*pid=\([0-9]*\).*/\1/p')"
    if [ "$arm" = routed ]; then
        if [ "${n:-0}" -ge 1 ]; then
            ok "ROUTED $lf: the server logged $n read(s) for pid $p naming that leaf -- the crossing is visible from outside the process"
        else
            bad "ROUTED $lf: the server logged NO read for pid $p. The arm above passed on the in-process path, so it proves nothing about routing."
        fi
    else
        if [ "${n:-0}" = 0 ]; then
            ok "UNROUTED $lf: zero crossings for pid $p, as there must be -- the red arm really did read shared memory"
        else
            bad "UNROUTED $lf: the server logged $n read(s) for pid $p, so the 'unrouted' arm was routed and the red/green pair is not a pair"
        fi
    fi
done

TF="$(f tracefull)"; TE="$(f traceempty)"
if [ "${TF:-0}" -ge 1 ] && [ "${TE:-0}" -ge 1 ]; then
    ok "the read server decided both ways on the attribute leaves in this run ($TE EMPTY, $TF FULL) -- a policy that only ever reaches one branch is indistinguishable from a constant"
else
    bad "the read server reached only one branch on the attribute leaves (EMPTY $TE, FULL $TF); a constant answer would score the same as a policy"
fi

echo "attrrd: $pass passed, $fail failed"
[ "$fail" = 0 ]
