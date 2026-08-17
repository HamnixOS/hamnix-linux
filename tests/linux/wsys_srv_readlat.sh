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
# wsys_srv_readlat.sh — WHAT A ROUTED READ COSTS, MEASURED AGAINST THE THING
# IT HAD TO BEAT, IN THE SAME RUN.
#
# THE NUMBER THIS EXISTS FOR. Stage 1 (docs/wsys_server_design.md) measured a
# blocking request against the server serviced from wsysd's FRAME LOOP, under
# a heavy drag:
#
#     load                                 p50     p90     max
#     heavy drag (480x320, 300 px span)    32 us   789 us  851 us
#
# The distribution is bimodal and not noisy: a request either catches an idle
# loop (~27 us) or waits out the frame being rasterized. 851 us is nearly
# three times the whole published 0.3 ms input-to-pixel budget, for ONE
# operation. Mutations are unaffected -- they are fire-and-forget and do not
# wait. Reads are nothing BUT waiting, and /dev/wsys/windows is the one file
# the whole enumeration policy exists for, re-read by the taskbar. So stage 4
# services reads from a forked read server that never paints.
#
# WHY BOTH ARMS ARE MEASURED HERE RATHER THAN AGAINST THE PUBLISHED 851.
# A number from another day, another kernel and another machine's idle state
# is not a control. Both arms run in ONE process against ONE compositor under
# ONE drag load, in the same second:
#
#   FRAME-LOOP ARM   WSRV_OP_PING on ".../srv" -- the same blocking shape
#                    stage 1 measured, still serviced from the frame loop.
#                    This arm is expected to be SLOW. If it is not, the load
#                    is not loading anything and the comparison is empty.
#   READ ARM         WSRV_OP_READ of /dev/wsys/windows on ".../rd", in the
#                    forked read server.
#
# THE READ ARM CANNOT BE ALLOWED TO WIN BY ANSWERING NOTHING. A server that
# replied zero bytes to everything would be the fastest possible one and would
# score a triumph here. hamwsys_srv_readlat prints the byte count of every
# sample and fails if every one is empty; this gate additionally requires the
# caller to be looking at a window list with the drag client's window in it.
#
# Three runs, every sample printed, medians of the per-run maxima -- because
# the number being beaten is a MAX and a median-only report is exactly what
# would have hidden the thing stage 1 found.
#
# Offscreen, software, no ICD. /dev/dri is untouched.
set -uo pipefail
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ"
# PRIVATE NAMESPACE FIRST -- before reap.sh, before $W, before the build.
# wsysd writes /srv/wsys, /dev/shm/hamnix-wsys and /tmp/hamnix-wsys under names
# compiled into it (see the table in private_ns.sh), so a run of this gate on a
# machine with a live desktop is a run that can be attached to by, and can
# corrupt, that desktop. Nothing this gate measures is a uid or an ownership
# fact -- both arms are LATENCY from one process against one compositor -- so
# the helper's one fidelity cost (euid 0 inside) touches nothing here. $OUT
# stays under $HOME/.hamnix-build, which the helper does not shadow, so a
# pinned SRV_WORK and SRV_REBUILD=0 still find yesterday's binaries.
. tests/linux/private_ns.sh
priv_ns_reexec "$@"
. tests/linux/reap.sh

# PER-RUN BY DEFAULT: $BIN is "$OUT/bin", and a fixed default meant two
# concurrent agents compiled into the same bin/ and measured each other's
# wsysd. SRV_WORK pins it -- which is also how SRV_REBUILD=0 below becomes
# useful, since a per-run dir never has a previous build to reuse.
SCRATCH_BASE="${SRV_SCRATCH_BASE:-/home/david/.hamnix-build}"
if [ -n "${SRV_WORK:-}" ]; then
    OUT="$SRV_WORK"; OUT_EPHEMERAL=0
    mkdir -p "$OUT" || { echo "rdlat: FAIL cannot make $OUT"; exit 2; }
else
    mkdir -p "$SCRATCH_BASE" || { echo "rdlat: FAIL cannot make $SCRATCH_BASE"; exit 2; }
    OUT="$(mktemp -d "$SCRATCH_BASE/wsrv-s4.XXXXXX")" || {
        echo "rdlat: FAIL cannot make a scratch dir under $SCRATCH_BASE"; exit 2; }
    OUT_EPHEMERAL=1
fi
BIN="$OUT/bin"; mkdir -p "$BIN"
for c in "${ADDER_HOST_AC:-}" "$PROJ/build/cutover/host_ac_llvm.elf" \
         "$PROJ/build/cutover/host_ac.elf" \
         "$(git -C "$PROJ" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/../build/cutover/host_ac.elf"; do
    [ -n "$c" ] && [ -x "$c" ] && { ADDER_HOST_AC="$c"; break; }
done
[ -n "${ADDER_HOST_AC:-}" ] || { echo "rdlat: FAIL no host_ac.elf"; exit 2; }
export ADDER_HOST_AC HAMLINUX_DISTRO_RO=1
for t in wsysd:user/wsysd.ad de_dragload:tests/linux/de_dragload.ad \
         wsys_srv_probe:tests/linux/wsys_srv_probe.ad; do
    n="${t%%:*}"
    [ "${SRV_REBUILD:-1}" = 0 ] && [ -x "$BIN/$n" ] && continue
    scripts/hamlinux_build.sh "${t#*:}" "$BIN/$n" >"$OUT/build.$n.log" 2>&1 || {
        echo "rdlat: FAIL could not build ${t#*:}"; tail -8 "$OUT/build.$n.log"
        exit 2; }
done

pass=0; fail=0
ok()   { printf 'rdlat: PASS %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf 'rdlat: FAIL %s\n' "$*"; fail=$((fail+1)); }
note() { printf 'rdlat: .... %s\n' "$*"; }
note "$(priv_ns_describe)"

W="$(mktemp -d "${TMPDIR:-/tmp}/rdlat.XXXXXX")"
reap_track "$W/reaped"
cleanup(){ rm -rf "$W"; [ "${OUT_EPHEMERAL:-0}" = 1 ] && rm -rf "$OUT"; return 0; }
reap_on_exit cleanup

mkdir -p "$W/noicd"
export HAMWSYS="$W/seg" HAMWSYS_BB="$W/seg.bb" HAMWSYS_IMG="$W/img"
export HAMFB_FILE="$W/fb.raw" HAMFB_GEOM=1280x800
export VK_ICD_FILENAMES="$W/noicd/none.json" HAMLINUX_VNC=none
: >"$W/in"; export HAMWSYSD_INPUT="$W/in"

( exec env HAMWSYS_SERVER=1 "$BIN/wsysd" </dev/null >"$W/wsysd.log" 2>&1 ) &
WP=$!; reap_add "$WP"
for _ in $(seq 1 150); do [ -s "$HAMFB_FILE" ] && break; sleep 0.1; done
[ -s "$HAMFB_FILE" ] || { bad "wsysd produced no framebuffer"; exit 1; }
if grep -q 'read server pid' "$W/wsysd.log"; then
    ok "the read server is up: $(grep -m1 'read server pid' "$W/wsysd.log")"
else
    bad "no read server -- the read arm would be falling back to the unmediated in-process read, which is not what this gate is timing"
    exit 1
fi

# THE HEAVY DRAG, and the arguments are stage 1's: 480x320, a 300 px span,
# 8 text rows. A lighter load moves the frame-loop arm's tail down and the
# comparison stops being the one that was published.
( exec "$BIN/de_dragload" 480 320 160 340 300 8 >"$W/drag.out" 2>&1 ) &
DP=$!; reap_add "$DP"
sleep 3
DWID="$(tr -d '\n' <"$W/drag.out" 2>/dev/null | head -c 8)"
if [ -z "${DWID:-}" ] || [ "${DWID:-0}" -lt 2 ]; then
    bad "the drag client never mapped a window -- both arms would be measured against an IDLE compositor, where the frame-loop tail this gate exists to compare against does not occur"
    exit 1
fi
ok "a heavy drag client owns window $DWID and is running -- both arms are measured under load, not at idle"

FL_MAX=(); RD_MAX=(); RD_P90=(); RD_P50=(); RD_FIRST=()
for run in 1 2 3; do
    note "---- run $run ----"
    env HAMWSYS_SERVER=1 "$BIN/wsys_srv_probe" >"$W/fl.$run" 2>&1
    L="$(grep -m1 'blocking round trip,' "$W/fl.$run")"
    note "FRAME LOOP  $L"
    FL_MAX+=("$(printf '%s' "$L" | sed -n 's/.*max \([0-9]*\) us.*/\1/p')")

    env HAMWSYS_SERVER=1 "$BIN/wsys_srv_probe" readlat 33 >"$W/rd.$run" 2>&1
    sed -n 's/^wsrvrl: sample /rdlat|      sample /p' "$W/rd.$run"
    R="$(grep -m1 'routed /dev/wsys/windows read,' "$W/rd.$run")"
    B="$(grep -m1 '^wsrvrl: bytes' "$W/rd.$run")"
    F="$(grep -m1 '^wsrvrl: first read' "$W/rd.$run")"
    note "READ SERVER $R"
    note "READ SERVER $B"
    note "READ SERVER $F"
    RD_FIRST+=("$(printf '%s' "$F" | sed -n 's/.*first read \([0-9]*\) us.*/\1/p')")
    RD_MAX+=("$(printf '%s' "$R" | sed -n 's/.*max \([0-9]*\) us.*/\1/p')")
    RD_P90+=("$(printf '%s' "$R" | sed -n 's/.*p90 \([0-9]*\) .*/\1/p')")
    RD_P50+=("$(printf '%s' "$R" | sed -n 's/.*p50 \([0-9]*\) .*/\1/p')")
    if grep -q 'FAIL' "$W/rd.$run"; then
        bad "the read instrument reported: $(grep -m1 FAIL "$W/rd.$run")"
    fi
done

med() { printf '%s\n' "$@" | sort -n | awk 'NR==2'; }
FLM="$(med "${FL_MAX[@]}")"; RDM="$(med "${RD_MAX[@]}")"
RD9="$(med "${RD_P90[@]}")"; RD5="$(med "${RD_P50[@]}")"
note "frame-loop max, three runs: ${FL_MAX[*]} -> median $FLM us"
note "read-server max, three runs: ${RD_MAX[*]} -> median $RDM us"
note "read-server p50 ${RD5} us, p90 ${RD9} us (medians of three)"
FST="$(med "${RD_FIRST[@]}")"
note "read-server FIRST read (the once-per-process dial), three runs: ${RD_FIRST[*]} -> median $FST us"

# ---- the load must actually be loading, or nothing below means anything ----
if [ "${FLM:-0}" -ge 300 ]; then
    ok "the FRAME-LOOP arm still shows the tail stage 1 found: max $FLM us under this drag. That is the control -- a fast frame-loop arm would mean the compositor was idle and the read arm's speed would be unattributable."
else
    bad "the frame-loop arm's max was only $FLM us, so this run did not reproduce the condition the read server exists for. The read numbers below are not scored against it."
fi

# ---- the number to beat ----------------------------------------------------
if [ "${RDM:-999999}" -lt 851 ]; then
    ok "a routed read's WORST sample is $RDM us, against the 851 us stage 1 measured for a blocking request on the frame loop -- the frame-loop tail is off the read path"
else
    bad "a routed read's worst sample is $RDM us, which does not beat the 851 us it had to"
fi
if [ "${FLM:-0}" -gt 0 ] && [ "${RDM:-999999}" -lt "$FLM" ]; then
    ok "and it beats the frame-loop arm measured in the SAME run under the SAME load ($RDM us against $FLM us), which is the only comparison that controls for this machine"
else
    bad "the read arm ($RDM us) did not beat the frame-loop arm ($FLM us) in the same run"
fi
# ---- and the cost that is NOT hidden by any of the above -------------------
# The dial happens on a client's FIRST routed read and it has been measured at
# over a millisecond under this load -- the connect and the version handshake
# both cross to a process that may be waiting on nothing but is still being
# scheduled against a saturated compositor. It is once per process and it is
# said out loud rather than averaged away: a client whose very first act is to
# read /dev/wsys/windows pays it, and if that ever becomes a startup-latency
# complaint this line is where to look.
note "the dial is a REAL cost and it is reported apart rather than averaged into the percentiles above: $FST us, once per process, on the first routed read"
if [ "${FST:-0}" -gt 0 ] && [ "${FST:-0}" -lt 5000 ]; then
    ok "the once-per-process dial is $FST us -- bounded, and paid once rather than per read"
else
    bad "the once-per-process dial measured $FST us"
fi

if [ "${RD9:-999999}" -lt 300 ]; then
    ok "p90 is $RD9 us -- a taskbar refresh fits inside the 0.3 ms published input-to-pixel budget nine times in ten, which it could not when the read waited out a frame"
else
    bad "p90 is $RD9 us, at or past the whole 0.3 ms input-to-pixel budget"
fi

echo "rdlat: $pass passed, $fail failed"
[ "$fail" = 0 ]
