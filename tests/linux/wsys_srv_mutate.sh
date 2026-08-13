#!/usr/bin/env bash
# wsys_srv_mutate.sh — STAGE 2: THE MUTATIONS ARE MEDIATED, AND THE MEDIATOR
# ANSWERS ABOUT THE CALLER RATHER THAN ABOUT ITSELF.
#
# Stage 1 (tests/linux/wsys_srv_transport.sh) built a transport that routed
# nothing. This is the stage that routes /dev/wsys/ctl and /dev/wsys/<wid>/ctl
# writes over it -- the leaves where the privilege questions live, and 99.99%
# of a session's write traffic (9790 wid/ctl writes against 1 scene write in
# 12 s of a drag).
#
# THE ASSERTION THAT MATTERS, AND WHY IT IS HARD TO WRITE HONESTLY
# ================================================================
# wsysd runs as the host owner. If a routed write's permission check were
# asked about wsysd -- geteuid(), getpid() -- it would return "yes" every
# time, and the mediator would grant strictly MORE than the in-process path
# did, silently, while every existing gate stayed green. So the check must be
# asked about the CALLER, from SO_PEERCRED, and this gate has to be able to
# tell a mediator that refuses from one that never looks.
#
# An ordinary client cannot test it. Its write to a foreign window is refused
# by the in-process check before it ever reaches a socket, so a gate driven
# that way is green whether or not the server checks anything at all. The
# probe therefore sends the routed message DIRECTLY, past the local check --
# which is exactly what a hostile client would do once it knew the protocol --
# and then asks the server's own counters what happened. It refuses to report
# a refusal at all unless the message is first shown to have ARRIVED: "refused
# 0" and "never received" are opposite findings that look identical.
#
# AND THE COST QUESTION STAGE 1 LEFT OPEN. Stage 1 measured 0.27% of a core at
# 192 synthetic ops/s against a 0.12% budget, and said the number
# over-attributes: a synthetic NOP ADDS a wake to a compositor that had no
# other reason to wake, whereas a real routed mutation REPLACES a shared-memory
# write that already poked the wake channel. Add-a-wake or move-a-wake is the
# whole difference. It could not be settled without a real routed operation.
# There is one now, so this settles it: the same real dragging client, flag off
# against flag on, wsysd's CPU either side.
#
# Offscreen, software, no ICD, private namespace.
set -uo pipefail
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ"
. tests/linux/private_ns.sh
priv_ns_reexec "$@"
. tests/linux/reap.sh

# PER-RUN BY DEFAULT: $BIN below is "$OUT/bin", so a fixed default meant two
# concurrent agents compiled into the same bin/ and measured each other's
# binaries. SRV_WORK pins it to reuse a build.
SCRATCH_BASE="${SRV_SCRATCH_BASE:-/home/david/.hamnix-build}"
if [ -n "${SRV_WORK:-}" ]; then
    OUT="$SRV_WORK"; OUT_EPHEMERAL=0
    mkdir -p "$OUT" || { echo "srvmu: FAIL cannot make $OUT"; exit 1; }
else
    mkdir -p "$SCRATCH_BASE" || { echo "srvmu: FAIL cannot make $SCRATCH_BASE"; exit 1; }
    OUT="$(mktemp -d "$SCRATCH_BASE/wsrv-s2.XXXXXX")" || {
        echo "srvmu: FAIL cannot make a scratch dir under $SCRATCH_BASE"; exit 1; }
    OUT_EPHEMERAL=1
fi
W="$OUT/run.$$"
mkdir -p "$W" || { echo "srvmu: FAIL cannot make $W"; exit 1; }
reap_track "$W/reaped"
cleanup(){
    [ "${SRV_KEEP:-0}" = 1 ] && return 0
    rm -rf "$W"
    [ "$OUT_EPHEMERAL" = 1 ] && rm -rf "$OUT"
    return 0
}
reap_on_exit cleanup

pass=0; fail=0
ok(){  echo "srvmu: PASS $*"; pass=$((pass+1)); }
bad(){ echo "srvmu: FAIL $*"; fail=$((fail+1)); }
note(){ echo "srvmu: .... $*"; }

BIN="$OUT/bin"; mkdir -p "$BIN"
for c in "${ADDER_HOST_AC:-}" "$PROJ/build/cutover/host_ac_llvm.elf" \
         "$PROJ/build/cutover/host_ac.elf" \
         "$(git -C "$PROJ" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/../build/cutover/host_ac.elf"; do
    [ -n "$c" ] && [ -x "$c" ] && { ADDER_HOST_AC="$c"; break; }
done
[ -n "${ADDER_HOST_AC:-}" ] || { echo "srvmu: FAIL no host_ac.elf"; exit 1; }
export ADDER_HOST_AC
for t in wsysd:user/wsysd.ad wsys_srv_probe:tests/linux/wsys_srv_probe.ad \
         cat:user/cat.ad de_dragload:tests/linux/de_dragload.ad; do
    scripts/hamlinux_build.sh "${t#*:}" "$BIN/${t%%:*}" \
        >"$W/build.${t%%:*}.log" 2>&1 || {
        echo "srvmu: FAIL could not build ${t#*:}"; tail -5 "$W/build.${t%%:*}.log"
        exit 1; }
done

mkdir -p "$W/noicd"
export HAMWSYS="$W/seg" HAMWSYS_BB="$W/bb" HAMWSYS_IMG="$W/img"
export HAMFB_FILE="$W/fb.raw" HAMFB_GEOM=1280x800
: >"$W/in"; export HAMWSYSD_INPUT="$W/in"
export VK_ICD_FILENAMES="$W/noicd/none.json" HAMLINUX_VNC=none

start_wsysd(){ local tag="$1"; shift
    rm -f "$HAMWSYS" "$HAMWSYS.chrome" "$HAMWSYS_BB" "$HAMFB_FILE"
    env "$@" "$BIN/wsysd" </dev/null >"$W/wsysd.$tag.log" 2>&1 &
    local p=$!; reap_add "$p"
    for _ in $(seq 1 100); do [ -s "$HAMFB_FILE" ] && break; sleep 0.1; done
    echo "$p"; }
stop_wsysd(){ kill "$1" 2>/dev/null; wait "$1" 2>/dev/null; }   # BY EXACT PID

HZ="$(getconf CLK_TCK 2>/dev/null || echo 100)"
WIN="${SRV_WIN:-40}"
QUANT="$(awk -v hz="$HZ" -v s="$WIN" 'BEGIN{printf "%.3f", 100.0/(hz*s)}')"
cpu_pct(){ local p="$1" s="$2" a b
    a="$(awk '{print $14+$15}' "/proc/$p/stat" 2>/dev/null)" || return 1
    sleep "$s"
    b="$(awk '{print $14+$15}' "/proc/$p/stat" 2>/dev/null)" || return 1
    awk -v a="$a" -v b="$b" -v s="$s" -v hz="$HZ" \
        'BEGIN{printf "%.2f", (b-a)*100.0/(hz*s)}'; }
median3(){ printf '%s\n' "$1" "$2" "$3" | sort -g | sed -n 2p; }
note "CPU instrument: /proc/<pid>/stat, CLK_TCK=$HZ, ${WIN}s windows -> one tick = $QUANT% of a core"

# ==================================================================
# 1. THE MUTATIONS ACTUALLY ROUTE.
# ==================================================================
WP="$(start_wsysd on HAMWSYS_SERVER=1)"
[ -s "$HAMFB_FILE" ] || { bad "wsysd produced no framebuffer with HAMWSYS_SERVER=1"
    echo "srvmu: $pass passed, $fail failed"; exit 1; }

HAMWSYS_SERVER=1 "$BIN/de_dragload" 480 320 160 340 300 8 \
    >"$W/wid.on" 2>"$W/drag.on.log" & DP=$!; reap_add "$DP"
sleep 4
VWID="$(tr -d '\n' <"$W/wid.on" 2>/dev/null)"
if [ -z "${VWID:-}" ] || [ "${VWID:-0}" -lt 2 ]; then
    bad "the client never mapped a window through the server -- routing newwindow broke it"
    cat "$W/drag.on.log" | head -5 | sed 's/^/srvmu:      /'
    kill "$DP" 2>/dev/null; stop_wsysd "$WP"
    echo "srvmu: $pass passed, $fail failed"; exit 1
fi
ok "a client mapped window $VWID with newwindow routed through the server"

HAMWSYS_SERVER=1 "$BIN/wsys_srv_probe" >"$W/stat1.out" 2>&1
SW="$(sed -n 's/.*server counters:.*[^a-z]write \([0-9]*\).*/\1/p' "$W/stat1.out" | tail -1)"
NW="$(sed -n 's/.*server counters:.* newwin \([0-9]*\).*/\1/p' "$W/stat1.out" | tail -1)"
grep 'server counters' "$W/stat1.out" | sed 's/^/srvmu:      /'
if [ -z "${SW:-}" ]; then
    bad "could not read the server's write counter -- the instrument did not report"
elif [ "$SW" -gt 100 ] && [ "${NW:-0}" -gt 0 ]; then
    ok "the server executed $SW routed ctl writes and $NW routed newwindows for a real dragging client -- the mutations are mediated, not merely reachable"
else
    bad "the server saw only $SW routed writes and $NW newwindows from a client that drags ~800 times a second. The mutations are not being routed."
fi

# ==================================================================
# 2. THE MEDIATOR EVALUATES, AND EVALUATES ABOUT THE CALLER.
# ==================================================================
# 2a. A ROUTED WRITE FOR A WINDOW THAT DOES NOT EXIST MUST BE REFUSED.
#
# This is the weak half and it is here because it is the half that holds at
# ANY uid. It proves the server looks at the message rather than executing it
# on trust -- which is not the same as proving it looks at the CALLER, and 2b
# is where that is faced honestly.
HAMWSYS_SERVER=1 "$BIN/wsys_srv_probe" mutate 9999 >"$W/attack.ghost" 2>&1
GRC=$?
sed 's/^/srvmu:      /' "$W/attack.ghost"
if grep -q 'did not see the routed write' "$W/attack.ghost"; then
    bad "the server never received the routed write for a nonexistent window -- a refusal count of zero would have meant nothing"
elif [ "$GRC" = 0 ]; then
    ok "a routed write for a window that does not exist is refused, and the probe proved the message ARRIVED first"
else
    bad "the server accepted a routed write for window 9999, which does not exist"
fi

# 2b. THE ASSERTION THIS GATE WAS WRITTEN FOR, AND THE REASON IT CANNOT BE
#     MADE HERE. Read this before believing anything about the boundary.
#
# The first run of this gate reported:
#
#   wsrvmu: the mediator ACCEPTED a stranger's write to window 2
#   srvmu:  FAIL a stranger renamed window 2: "2 win2" -> "2 PWNED-BY-A-STRANGER"
#
# and that FAIL was WRONG -- mine, not the code's. devwsys's rule, ported
# faithfully in linux-wsys.c, is that the HOST OWNER (the uid that owns the
# segment) may write any window. Everything in this offscreen gate runs as one
# uid, so the "stranger" IS the host owner and the write is permitted. The
# mediator reproduced the in-process rule exactly, which is what stage 2 is
# required to do.
#
# So this assertion needs UID SEPARATION to mean anything, exactly as
# tests/linux/wsys_uidgate.sh and tests/linux/wsys_bypass.sh do -- both of
# which build their own user namespace with `unshare -U --map-users` and are
# EXEMPT from private_ns.sh for that reason. That is a gate of its own and it
# is the next piece of work, not a line to bolt on here.
#
# THAT GATE NOW EXISTS: tests/linux/wsys_srv_identity.sh, 15 passed 0 failed.
# It runs the same attack from uid 1002 against uid 1001's window twice --
# unrouted, where it SUCCEEDS, and routed, where the mediator refuses it -- and
# reads both permission answers out of the server from inside srv_as_caller().
# The skip below is still correct and still prints, because THIS file cannot
# make that assertion; it is no longer the whole story.
#
# What is asserted instead is the identity the server would decide on, read
# back from the server itself. If the caller is the host owner, an acceptance
# is CORRECT and this says so rather than scoring a false PASS; the real
# attack is only run when the uids genuinely differ.
SEGUID="$(stat -c %u "$HAMWSYS" 2>/dev/null || echo -1)"
MYUID="$(id -u)"
note "the segment is owned by uid $SEGUID; this gate runs as uid $MYUID"
if [ "$SEGUID" = "$MYUID" ] || [ "$MYUID" = 0 ]; then
    note "SKIPPED, AND NOT SILENTLY: the caller IS the host owner, so devwsys's own rule permits it to write any window and a refusal here would be the mediator being STRICTER than the path it replaces. Proving the caller identity is used needs a second uid. NO PASS IN THIS FILE COVERS IT -- tests/linux/wsys_srv_identity.sh does, with unshare -U --map-users, and is the file to run and to quote for that property."
else
    TITLE_BEFORE="$("$BIN/cat" /dev/wsys/windows 2>/dev/null | grep "^${VWID} " | head -1)"
    HAMWSYS_SERVER=1 "$BIN/wsys_srv_probe" mutate "$VWID" >"$W/attack.out" 2>&1
    ARC=$?
    sed 's/^/srvmu:      /' "$W/attack.out"
    TITLE_AFTER="$("$BIN/cat" /dev/wsys/windows 2>/dev/null | grep "^${VWID} " | head -1)"
    if [ "$ARC" = 0 ] && [ "$TITLE_AFTER" = "$TITLE_BEFORE" ]; then
        ok "a non-owner's routed write to window $VWID was refused and the title is unchanged"
    else
        bad "a non-owner renamed window $VWID: \"$TITLE_BEFORE\" -> \"$TITLE_AFTER\""
    fi
fi
# READ THE ENUMERATION WHILE THE CLIENT IS STILL ALIVE. The first cut killed
# the client first and compared an EMPTY listing against a populated one --
# win_reap_dead() correctly drops a window whose owner is gone, so the arm was
# measuring its own teardown order and reporting it as a routing difference.
"$BIN/cat" /dev/wsys/windows >"$W/windows.on" 2>/dev/null || true
kill "$DP" 2>/dev/null; wait "$DP" 2>/dev/null
stop_wsysd "$WP"

# ==================================================================
# 3. BEHAVIOUR UNCHANGED WITH THE FLAG UNSET.
# ==================================================================
WP="$(start_wsysd off)"
"$BIN/de_dragload" 480 320 160 340 300 8 >"$W/wid.off" 2>"$W/drag.off.log" &
DP=$!; reap_add "$DP"
sleep 4
"$BIN/cat" /dev/wsys/windows >"$W/windows.off" 2>/dev/null || true
kill "$DP" 2>/dev/null; wait "$DP" 2>/dev/null
stop_wsysd "$WP"
if ! [ -s "$W/windows.off" ]; then
    bad "the flag-unset enumeration was EMPTY -- refusing to call an empty-to-empty comparison a match"
elif diff -q "$W/windows.off" "$W/windows.on" >/dev/null 2>&1; then
    ok "/dev/wsys/windows is byte-identical routed and unrouted ($(wc -c <"$W/windows.off") bytes, non-empty)"
else
    bad "routing changed what /dev/wsys/windows says"
    diff "$W/windows.off" "$W/windows.on" | sed 's/^/srvmu:      /' | head -6
fi

# ==================================================================
# 4. ADD-A-WAKE OR MOVE-A-WAKE -- THE QUESTION STAGE 1 LEFT OPEN.
# ==================================================================
# The same real dragging client either side. With the flag unset its ctl write
# mutates shared memory and pokes the wake channel: one wake. With the flag set
# the write becomes a message, and the message itself is the wake: still one.
# If mediation MOVES the wake these two numbers are the same and the 0.27% that
# stage 1 could not attribute was an artefact of a synthetic NOP. If it ADDS
# one, the flag-on arm is measurably dearer and the budget was wrong rather
# than the attribution -- which is worth as much, and is the finding either way.
drag_cpu(){ # drag_cpu <tag> [env...] -> "s1 s2 s3 median"
    local tag="$1"; shift
    local p dp s1 s2 s3
    p="$(start_wsysd "$tag" HAMNIX_WSYSD_BENCH_LIVE=200 "$@")"
    env "$@" "$BIN/de_dragload" 480 320 160 340 300 8 \
        >"$W/wid.$tag" 2>"$W/drag.$tag.log" & dp=$!; reap_add "$dp"
    sleep 3
    s1="$(cpu_pct "$p" "$WIN")"; s2="$(cpu_pct "$p" "$WIN")"; s3="$(cpu_pct "$p" "$WIN")"
    kill "$dp" 2>/dev/null; wait "$dp" 2>/dev/null
    stop_wsysd "$p"
    echo "$s1 $s2 $s3 $(median3 "$s1" "$s2" "$s3")"
}
read -r F1 F2 F3 FMED <<<"$(drag_cpu dragoff)"
note "wsysd CPU, real drag, flag UNSET: samples $F1% $F2% $F3% -> median $FMED%"
read -r G1 G2 G3 GMED <<<"$(drag_cpu dragon HAMWSYS_SERVER=1)"
note "wsysd CPU, real drag, ROUTED:     samples $G1% $G2% $G3% -> median $GMED%"
DELTA="$(awk -v a="$FMED" -v b="$GMED" 'BEGIN{printf "%.2f", b-a}')"
note "cost of mediating a real drag: $DELTA% of a core (budget for a mouse-paced drag: 0.38%)"

if awk -v x="$FMED" 'BEGIN{exit !(x > 0)}'; then
    ok "the unrouted baseline is non-zero ($FMED%), so the difference below is a comparison and not a division by nothing"
else
    bad "the unrouted baseline measured 0% -- the instrument is not looking"
fi
if awk -v d="$DELTA" 'BEGIN{exit !(d < 0)}'; then
    # A NEGATIVE DELTA IS NOT "WITHIN BUDGET", AND MUST NOT BE PRINTED AS IF
    # IT WERE. It says routing made the compositor CHEAPER, which is a
    # different claim from "the cost fits" and a much bigger one -- it needs
    # its own explanation before it is believed, not a tick in a budget
    # column.
    ok "mediating a real drag is CHEAPER than not mediating it, by $(awk -v d="$DELTA" 'BEGIN{printf "%.2f", -d}')% of a core. That is a claim in its own right and not merely 'within the 0.38% budget' -- see the verdict below."
elif awk -v d="$DELTA" 'BEGIN{exit !(d <= 0.38)}'; then
    ok "mediating a real drag costs $DELTA% of a core, within the 0.38% mouse-paced budget"
else
    bad "mediating a real drag costs $DELTA% of a core, over the 0.38% mouse-paced budget"
fi
awk -v d="$DELTA" -v q="$QUANT" 'BEGIN{
  if (d < 0 && -d > q)
    print "srvmu: .... VERDICT: MOVE-A-WAKE, AND MORE. Routing a real drag made the compositor " (-d) "%% of a core CHEAPER, well outside the " q "%% the instrument can resolve. Stage 1'\''s 0.27%% at 192 synthetic ops/s was the synthetic NOP ADDING a wake that a real routed mutation replaces -- and routing also lets the server drain many mutations per wake and apply them BEFORE scan_windows in the same iteration, where the unrouted path woke the loop per publish. This wants its own gate before it is quoted.";
  else if (d < q)
    print "srvmu: .... VERDICT: MOVE-A-WAKE. The added cost is below the instrument'\''s resolution (" q "% of a core) on real traffic. Stage 1'\''s 0.27% at 192 synthetic ops/s was the synthetic NOP adding a wake that a real routed mutation replaces.";
  else
    print "srvmu: .... VERDICT: ADD-A-WAKE, or something else. Real routed traffic costs " d "% of a core more than unrouted, which is above the " q "% the instrument can resolve. The attribution was right and the budget is what needs revisiting.";
}'

# ==================================================================
# 5. CHEAPER MUST NOT MEAN DOING LESS. This is the assertion that keeps arm 4
# honest, and without it a 17% CPU saving and a compositor that quietly
# stopped painting are the same number. wsysd dumps a line per 200 full
# frames with HAMNIX_WSYSD_BENCH_LIVE set, so the count of those lines is a
# frame count in units of 200 -- comparable between the two arms, which is
# all that is needed.
FOFF=$(grep -c '^benchlive: seq' "$W/wsysd.dragoff.log" 2>/dev/null || echo 0)
FON=$(grep -c '^benchlive: seq' "$W/wsysd.dragon.log" 2>/dev/null || echo 0)
note "full frames painted during the drag (units of 200): unrouted $FOFF, routed $FON"
if [ "$FOFF" -le 0 ]; then
    bad "the unrouted arm painted no countable frames -- the frame instrument is not looking, so 'routing paints as many' would be unprovable"
elif [ "$FON" -ge "$FOFF" ]; then
    ok "the routed arm painted at least as many full frames as the unrouted one ($FON vs $FOFF x200) -- the CPU saving is not the compositor doing less"
else
    bad "the routed arm painted FEWER full frames ($FON vs $FOFF x200). The CPU saving is a frame rate drop wearing a saving's clothes."
fi

echo "srvmu: $pass passed, $fail failed"
[ "$fail" = 0 ]
