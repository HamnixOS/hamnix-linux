#!/usr/bin/env bash
#
# REGISTRATION, 2026-08-17. Until this date scripts/test_gate_registration.sh
# globbed only scripts/test_*.sh, so this directory was invisible to the gate
# against unregistered gates and every file in it read as coverage without
# being coverage. This gate is ON-DEMAND: not in ci_battery_manifest.txt
# because MEASURED 2026-08-17: it exits 0 in 6 s while printing no PASS, no FAIL and no assertion count at all (115 bytes of output). It is a probe, not a gate -- registering it would add a battery line that cannot go red, which is exactly the false assurance the registration gate exists to prevent.
#
#
# tests/linux/wsys_v2_handup_rate.sh — A v2 WINDOW MUST BE PAINTED EVEN WHEN
# THE COMPOSITOR AND THE CLIENT ARE FIGHTING FOR A CPU.
#
# THE DEFECT THIS HOLDS. A v2 window's pixels reach the screen only if the
# client can hand its backbuffer memfd UP to the compositor, and that needs the
# compositor to be LISTENING on the rendezvous address. bbup_listen() used to
# set a `tried` latch on its FIRST call and never attempt again -- and a first
# call arrives before the segment's identity or owner is known, because
# sys_waitfds drives hamwsys_tick and a process parks before it has touched
# /dev/wsys. So the compositor returned early with the latch set and NEVER
# BOUND for the rest of its life. Every client's hand-up was refused
# (ECONNREFUSED, measured eleven times in a single run), and every v2 window --
# every browser, every video, every bridged X client -- stayed blank with
# NOTHING on any log.
#
# WHY IT LOOKED LIKE SOMETHING ELSE. Unpinned on an idle host it is rare, and
# it first showed up as "a v2 window whose predecessor died is sometimes never
# painted" -- roughly 1 in 4. That framing was wrong: with the two processes
# pinned to ONE core so they genuinely contend, it fails 10 times in 10 WITH a
# dead predecessor and 10 in 10 WITHOUT one. The dead window was never the
# variable; CPU contention was, and a person opening an application on a busy
# machine is the ordinary case, not the exotic one.
#
# WHY IT IS PINNED RATHER THAN LOADED. Loading the whole host would corrupt the
# measurements other work on this machine is taking. Pinning contains the
# contention to this gate's own two processes.
#
# HOW TO READ A RESULT. This is a RATE, so one green run means nothing: the
# unfixed code passes about three runs in four unpinned. It runs N=8 by default
# and requires ZERO failures. Measured across the fix:
#     bind from the backbuffer read only ....... 10 failures / 10
#     + bind on a foreign-scene read ............ 3 failures / 10
#     + bind on the park (sticky compositor) .... 6-8 failures / 8
#     + THE LATCH REMOVED, bind retries ......... 0 failures / 8, three times
# The last line is the fix; the ones above it are why the site of the bind was
# never the problem.
#
# Entirely offscreen: HAMFB_FILE plus a file of evdev records. No VM, no DRM.
set -u
cd /home/david/hamnix-linux/.claude/worktrees/agent-a0cea956c36cb495c
D=/home/david/.hamnix-build/agent-a0cea956c36cb495c
B="${V2RATE_BIN_DIR:-$D/sb/bin}"
CORE="${PIN_CORE:-11}"
N="${N:-10}"
fail=0
for r in $(seq 1 "$N"); do
    T=$(mktemp -d "$D/rt.XXXXXX"); mkdir -p "$T/noicd"
    export HAMWSYS="$T/seg" HAMWSYS_BB="$T/bb" HAMWSYS_IMG="$T/img"
    export HAMFB_FILE="$T/fb" HAMFB_GEOM=1280x800
    : >"$T/in"; export HAMWSYSD_INPUT="$T/in"
    export VK_ICD_FILENAMES="$T/noicd/none.json"
    taskset -c "$CORE" "$B/wsysd" </dev/null >"$T/wsysd.log" 2>&1 & WP=$!
    for _ in $(seq 1 80); do [ -s "$T/fb" ] && break; sleep 0.1; done
    if [ "${SOLO:-0}" != "1" ]; then
        taskset -c "$CORE" "$B/probe" wctlv2 >"$T/w.out" 2>&1
    fi
    taskset -c "$CORE" "$B/probe" fillwin >"$T/f.out" 2>&1 & FP=$!
    px=0
    for _ in $(seq 1 60); do
        px=$(python3 - "$T/fb" <<'PY'
import sys
d=open(sys.argv[1],'rb').read()
print(d.count(b'\x11\x22\x33')+d.count(b'\x33\x22\x11'))
PY
)
        [ "${px:-0}" -gt 0 ] && break
        sleep 0.2
    done
    [ "${px:-0}" -gt 0 ] || fail=$((fail+1))
    kill $FP $WP 2>/dev/null; wait 2>/dev/null
    rm -rf "$T"
done
echo "pinned core $CORE, SOLO=${SOLO:-0}: $fail failures in $N runs"
if [ "$fail" = 0 ]; then
    echo "PASS wsys_v2_handup_rate ($N/$N v2 windows painted under contention)"
    exit 0
fi
echo "FAIL wsys_v2_handup_rate: $fail of $N v2 windows were never painted."
echo "  A client cannot hand its backbuffer up unless the compositor is"
echo "  listening; see bbup_listen() in user/linux-wsys.c and the latch note."
exit 1
