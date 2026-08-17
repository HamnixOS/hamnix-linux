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
# cap_power_ab.sh — THE PRESENT CAP'S POWER NUMBER, BOTH ARMS, ONE SESSION.
#
# WHY THIS EXISTS
# ===============
# wsysd caps its present rate at the display's real refresh: 917 fps uncapped,
# 58 fps capped. The cap's ENTIRE justification is power -- it exists to stop
# the compositor painting ~900 frames a second at a display that shows 60. The
# capped figure was measured (13.5% of a core during a drag, at 60.0 fps).
#
# ITS PARTNER WAS NEVER MEASURED VALIDLY, twice, and both times for the same
# reason: THE TWO ARMS WERE NOT SERIALISED. The second arm started while the
# first arm's wsysd still held DRM master, so it spent its watchdog budget
# inside the "waiting to arm" poll, and the watchdog then fired THROUGH the
# cpuprobe -- the log shows `cpuprobe[drag]: pid ... verified as ...` followed
# by `Killed`, i.e. the probe named the right process and was then killed
# before it could produce a number. So this script does two things the old one
# did not:
#
#   1. It PROVES MASTER IS FREE before each arm, by taking it -- hangmaster
#      must print "HOLDING DRM MASTER", not "Permission denied". It POLLS for
#      that rather than sleeping a guessed interval, because a fixed sleep is
#      exactly what raced it before.
#   2. It ends each arm by KILLING wsysd BY THE PID THE WATCHDOG WROTE DOWN,
#      rather than waiting for the watchdog to fire. The watchdog stays armed
#      as the backstop it is; it is not the normal way out.
#
# BOTH ARMS MUST ACTUALLY ARM SCANOUT, and this script checks. Note the
# discriminator carefully, because it is NOT the cap line: with
# HAMNIX_WSYSD_NOCAP=1 the compositor prints
#
#     wsysd: present cap OFF -- offscreen, fbdev, or no usable mode timing
#
# BY DESIGN -- NOCAP sets frame_us=0 and that is the message for frame_us==0.
# The line that says the display is real is "SCANOUT armed". An arm that logs
# the cap-OFF line WITHOUT "SCANOUT armed" fell back to fbdev, measured a
# different path, and must be discarded.
#
# SAFETY. wsysd is the watchdog's direct child, so the SIGKILL lands on the
# process that holds DRM master -- the only recovery that works on this driver,
# where legacy SETCRTC restore and DROP_MASTER both hang after a modeset.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="${CAPAB_BIN:-/home/david/.hamnix-build/cap-power-ab/bin}"
HANG="${CAPAB_HANG:-/home/david/.hamnix-build/cap-power-ab/hangmaster}"
WORKROOT="${CAPAB_WORK:-/home/david/.hamnix-build/cap-power-ab}"
ICD="${CAPAB_ICD:-/usr/share/vulkan/icd.d/nvidia_icd.json}"
WD="${WD:-100}"          # watchdog budget: the BACKSTOP, not the way out
EVERY="${EVERY:-200}"    # full frames per benchlive dump
PSECS="${PSECS:-10}"     # cpuprobe seconds per sample
PREPS="${PREPS:-3}"      # cpuprobe samples

. "$ROOT/tests/linux/reap.sh"
reap_track "$WORKROOT/reaped.$$"
reap_on_exit
for f in "$BIN/wsysd" "$BIN/hamdesktop" "$BIN/de_dragload" "$HANG"; do
    [ -x "$f" ] || { echo "cap_ab: FAIL missing $f"; exit 1; }
done

# ---- IS DRM MASTER FREE? Answered by TAKING it, not by guessing. -----------
# kms_watchdog.sh 2 hangmaster: hangmaster opens card0, SET_MASTERs, and hangs;
# the watchdog kills it 2 s later, the fd closes, the kernel drops master. It
# does NO modeset, so the console keeps its picture throughout.
master_free() {
    local out
    out="$("$ROOT/tests/linux/kms_watchdog.sh" 2 "$HANG" 2>&1)"
    case "$out" in
        *"HOLDING DRM MASTER"*) return 0 ;;
        *) LAST_MASTER_MSG="$(printf '%s' "$out" | tr '\n' ' ')"; return 1 ;;
    esac
}
wait_master_free() {   # POLL. A fixed sleep is what raced the last two runs.
    local i
    for i in $(seq 1 "${MASTER_TRIES:-45}"); do
        if master_free; then
            echo "cap_ab: master is FREE (proved by taking it, try $i)"
            return 0
        fi
        echo "cap_ab:   master still held (try $i): ${LAST_MASTER_MSG:-?}"
        sleep 1
    done
    echo "cap_ab: FAIL master never became free"
    return 1
}

# ---- ONE ARM --------------------------------------------------------------
# $1 tag, $2 extra env for wsysd ("" or HAMNIX_WSYSD_NOCAP=1)
run_arm() {
    local tag="$1" extra="${2:-}" NODRAG="${3:-0}"
    local W="$WORKROOT/arm-$tag.$$"
    rm -rf "$W"; mkdir -p "$W"
    echo
    echo "################ ARM $tag  (extra env: ${extra:-<none>})"
    wait_master_free || return 1

    export HAMWSYS="$W/s" HAMWSYS_BB="$W/b" HAMWSYS_IMG="$W/i"
    : >"$W/in"; export HAMWSYSD_INPUT="$W/in"
    export VK_ICD_FILENAMES="$ICD"
    export HAMNIX_WSYSD_SCANOUT=1 HAMNIX_WSYSD_SCANOUT_SUPERVISED=1
    export HAMNIX_WSYSD_BENCH_LIVE="$EVERY"
    unset HAMFB_FILE          # a real display, not a file

    echo "cap_ab: arming watchdog (${WD}s backstop) and starting wsysd on DP-1"
    WATCHDOG_PIDFILE="$W/wsysd.pid" \
        env ${extra} "$ROOT/tests/linux/kms_watchdog.sh" "$WD" "$BIN/wsysd" \
        >"$W/wsysd.log" 2>&1 &
    local WDPID=$!; reap_add "$WDPID"

    local armed=0 i
    for i in $(seq 1 80); do
        grep -q "SCANOUT armed" "$W/wsysd.log" 2>/dev/null && { armed=1; break; }
        kill -0 "$WDPID" 2>/dev/null || break
        sleep 0.5
    done
    local WPID; WPID="$(cat "$W/wsysd.pid" 2>/dev/null || true)"
    [ -n "$WPID" ] && reap_add "$WPID"

    if [ "$armed" != 1 ]; then
        echo "cap_ab: FAIL arm $tag did NOT arm scanout -- DISCARDING IT."
        sed 's/^/cap_ab:   /' "$W/wsysd.log" | head -20
        [ -n "$WPID" ] && kill -9 "$WPID" 2>/dev/null
        ARM_OK=0; return 1
    fi
    grep -E "SCANOUT armed|present cap" "$W/wsysd.log" | sed 's/^/cap_ab:   /'
    # THE DISCRIMINATOR, stated in the output so the reader does not have to
    # infer it: scanout armed => this is the display path. The cap line only
    # says whether the cap is on.
    echo "cap_ab:   => scanout ARMED: this arm is on the display path."
    if grep -q "present cap [0-9]* Hz" "$W/wsysd.log"; then
        echo "cap_ab:   => cap is ON"
    else
        echo "cap_ab:   => cap is OFF"
    fi

    "$BIN/hamdesktop" </dev/null >"$W/d.log" 2>&1 & local DP=$!; reap_add "$DP"
    sleep 3
    # LOAD is the drag, unless this arm is the IDLE gate. Idle was previously
    # argued to be structurally unaffected by the cap rather than measured on
    # this path, and an argument is not a measurement.
    local GP=""
    if [ "$NODRAG" != 1 ]; then
        "$BIN/de_dragload" 480 320 160 340 300 8 >"$W/g.log" 2>&1 & GP=$!
        reap_add "$GP"
    fi
    sleep 3
    # Mark where the drag begins, so the frame/wake rates below are taken from
    # dumps produced UNDER THE DRAG and not from the quiet start-up.
    local MARK; MARK="$(grep -c '^benchlive: seq' "$W/wsysd.log" || true)"

    local LOADNAME="drag"; [ "$NODRAG" = 1 ] && LOADNAME="IDLE (no drag load)"
    echo "cap_ab: wsysd CPU across the $LOADNAME, pid from the watchdog's pidfile"
    SECS="$PSECS" REPS="$PREPS" CPUPROBE_OUT="$W/cpu.txt" \
        "$ROOT/tests/linux/cpuprobe.sh" "$WPID" --verify "$BIN/wsysd" \
        --label "$tag" 2>&1 | sed 's/^/cap_ab:   /'

    kill $GP "$DP" 2>/dev/null; sleep 0.5; kill -9 $GP "$DP" 2>/dev/null
    # END THE ARM BY KILLING wsysd, so master is released NOW. The watchdog is
    # the backstop; letting it fire is not the normal way out and is what put
    # the next arm's start-up inside the previous arm's master hold.
    kill -9 "$WPID" 2>/dev/null
    wait "$WDPID" 2>/dev/null

    # On an IDLE arm there are usually NO dumps at all, because a dump needs
    # $EVERY full frames and an idle desktop paints none. That absence is the
    # confirmation, not a hole in the instrument.
    echo "cap_ab: benchlive dumps under the $LOADNAME (${EVERY} full frames each):"
    grep '^benchlive: seq' "$W/wsysd.log" | tail -n "+$((MARK+1))" \
        | tail -6 | sed 's/^/cap_ab:   /'
    # fps AND WAKE RATE, both derived from the dump's OWN dt_us, so neither
    # depends on this harness's timing. The wake rate is the question under the
    # power question: `iters` is loop iterations, i.e. how often the compositor
    # woke to drain and rescan, PAINTED OR NOT.
    grep '^benchlive: seq' "$W/wsysd.log" | tail -n "+$((MARK+1))" \
        | awk -v e="$EVERY" -v tag="$tag" '
        {
          for (i=1;i<=NF;i++) {
            if ($i=="dt_us") dt=$(i+1);
            if ($i=="iters") it=$(i+1);
            if ($i=="capped") cp=$(i+1);
          }
          if (dt>0) { n++; f+=e/(dt/1e6); w+=it/(dt/1e6); lastcap=cp }
        }
        END { if (n>0) printf "cap_ab: RATES[%s] %.1f fps, %.0f wakes/s (mean of %d dumps), capped-total %s\n", tag, f/n, w/n, n, lastcap }'
    echo "cap_ab: CPU[$tag] = $(cat "$W/cpu.txt" 2>/dev/null || echo '?')% of a core"
    ARM_LOG="$W/wsysd.log"; ARM_OK=1
    return 0
}

echo "cap_ab: THE PROBE FIRST -- it is not trusted on the real load until it"
echo "cap_ab: reports a KNOWN one correctly."
SECS=5 REPS=3 "$ROOT/tests/linux/cpuprobe.sh" --selftest 2>&1 | sed 's/^/cap_ab:   /'

ARM_OK=0
# The third arm, cap30, is not decoration. If the compositor's cost were the
# PAINT, halving the paint again (60 Hz -> 30 Hz) would roughly halve what is
# left. If the cost is the WAKE -- which runs at ~860/s regardless of the cap
# -- then cap30 costs almost exactly what cap60 costs, and that is the whole
# finding stated as a prediction that can fail.
ARMS="${ARMS:-capON capOFF cap30}"
A=0; B=0; C=0; C_RAN=0
for a in $ARMS; do
    case "$a" in
        capON)  run_arm capON  ""                              ; A=$ARM_OK ;;
        capOFF) run_arm capOFF "HAMNIX_WSYSD_NOCAP=1"          ; B=$ARM_OK ;;
        cap30)  run_arm cap30  "HAMNIX_WSYSD_CAP_US=33333"     ; C=$ARM_OK; C_RAN=1 ;;
        idleON)  run_arm idleON  ""                     1 ;;
        idleOFF) run_arm idleOFF "HAMNIX_WSYSD_NOCAP=1" 1 ;;
    esac
done
echo
echo "cap_ab: arms that genuinely armed scanout: capON=$A capOFF=$B$([ "$C_RAN" = 1 ] && echo " cap30=$C")"
# Demand that every arm ACTUALLY ASKED FOR armed scanout -- not a fixed pair.
# ARMS=cap30 alone is a legitimate single-arm run, and reporting "the
# comparison is still owed" for it would be a false alarm of exactly the kind
# this file exists to avoid.
bad=0
for a in $ARMS; do
    case "$a" in
        capON)  [ "$A" = 1 ] || bad=1 ;;
        capOFF) [ "$B" = 1 ] || bad=1 ;;
        cap30)  [ "$C" = 1 ] || bad=1 ;;
    esac
done
if [ "$bad" = 1 ]; then
    echo "cap_ab: the comparison is STILL OWED -- a requested arm did not run on the display path."
    exit 1
fi
wait_master_free >/dev/null 2>&1 || true
echo "cap_ab: done; master released."
