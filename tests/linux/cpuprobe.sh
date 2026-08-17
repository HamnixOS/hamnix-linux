#!/usr/bin/env bash
#
# REGISTRATION, 2026-08-17. Until this date scripts/test_gate_registration.sh
# globbed only scripts/test_*.sh, so this directory was invisible to the gate
# against unregistered gates and every file in it read as coverage without
# being coverage. This gate is ON-DEMAND: not in ci_battery_manifest.txt
# because it is a HELPER, not a standalone gate: run with no arguments on 2026-08-17 it printed its usage line and exited 1 in 0 s. Other gates invoke it with arguments.
#
#
# cpuprobe.sh — CPU of ONE KNOWN PID, and a probe that proves itself first.
#
# WHY THIS EXISTS. `pgrep -f "bin/wsysd"` matched the WATCHDOG SHELL, whose
# argv contains "./bin/wsysd", and measured a sleeping bash: it reported a
# compositor that was rendering 58 frames a second as "0.0% of a core" --
# the most flattering possible answer to exactly the question the measurement
# existed to settle. pgrep matching its own or a wrapper's command line has
# cost this project four separate measurements.
#
# So: the pid is passed in, taken from the process the caller STARTED. If it
# was found by search instead, --verify checks it resolves to the expected
# binary before any number is produced.
#
#   cpuprobe.sh <pid> [--verify /path/to/expected/exe] [--label X]
#   cpuprobe.sh --selftest        run the probe against a KNOWN duty cycle
#
# Three samples over a fixed wall interval, median reported, every sample
# printed -- the same discipline the idle gate uses, for the same reason.
set -uo pipefail
SECS="${SECS:-5}"
REPS="${REPS:-3}"
HZ=$(getconf CLK_TCK)

sample_pct() {   # pid secs -> percent of one core over that interval
    local pid="$1" secs="$2"
    local j0 t0 j1 t1
    j0=$(awk '{print $14+$15}' "/proc/$pid/stat" 2>/dev/null) || return 1
    t0=$(date +%s.%N)
    sleep "$secs"
    j1=$(awk '{print $14+$15}' "/proc/$pid/stat" 2>/dev/null) || return 1
    t1=$(date +%s.%N)
    [ -z "$j0" ] || [ -z "$j1" ] && return 1
    python3 -c "print(f'{100.0*($j1-$j0)/$HZ/($t1-$t0):.1f}')"
}

measure() {      # pid label -> prints median + all samples
    local pid="$1" label="$2" s all=""
    for _ in $(seq 1 "$REPS"); do
        s=$(sample_pct "$pid" "$SECS") || { echo "cpuprobe[$label]: FAIL pid $pid vanished"; return 1; }
        all="$all $s"
    done
    local med
    med=$(printf '%s\n' $all | sort -n | awk '{a[NR]=$1} END{printf "%.1f", a[int((NR+1)/2)]}')
    echo "cpuprobe[$label]: ${med}% of a core (median of $REPS x ${SECS}s; samples:$all) pid $pid"
    printf '%s' "$med" > "${CPUPROBE_OUT:-/dev/null}"
    return 0
}

if [ "${1:-}" = "--selftest" ]; then
    # A child with a KNOWN duty cycle: busy 100 ms, idle 100 ms => ~50%.
    python3 -c "
import time
while True:
    e=time.time()+0.1
    while time.time()<e: pass
    time.sleep(0.1)
" &
    KID=$!
    trap 'kill -9 $KID 2>/dev/null' EXIT
    sleep 1
    echo "cpuprobe: selftest against a child with a 50% duty cycle (100ms busy / 100ms idle)"
    measure "$KID" selftest-50pct
    V=$(printf '%s' "$(measure "$KID" selftest-50pct-recheck | sed 's/.*: \([0-9.]*\)%.*/\1/')")
    ok=$(python3 -c "v=float('$V'); print(1 if 35.0 <= v <= 65.0 else 0)")
    if [ "$ok" = 1 ]; then
        echo "cpuprobe: PASS the probe reports a known 50% load as ${V}%"
    else
        echo "cpuprobe: FAIL a known 50% load measured as ${V}% -- the probe is wrong"
        exit 1
    fi
    exit 0
fi

PID="${1:?usage: cpuprobe.sh <pid> [--verify exe] [--label X]}"; shift
VERIFY=""; LABEL="cpu"
while [ $# -gt 0 ]; do
    case "$1" in
        --verify) VERIFY="$2"; shift 2 ;;
        --label)  LABEL="$2";  shift 2 ;;
        *) shift ;;
    esac
done
if ! kill -0 "$PID" 2>/dev/null; then echo "cpuprobe[$LABEL]: FAIL no such pid $PID"; exit 1; fi
if [ -n "$VERIFY" ]; then
    EXE=$(readlink -f "/proc/$PID/exe" 2>/dev/null || true)
    case "$EXE" in
        "$VERIFY"*) : ;;
        *) echo "cpuprobe[$LABEL]: FAIL pid $PID is $EXE, not $VERIFY -- refusing to measure the wrong process"
           exit 1 ;;
    esac
    echo "cpuprobe[$LABEL]: pid $PID verified as $EXE"
fi
measure "$PID" "$LABEL"
