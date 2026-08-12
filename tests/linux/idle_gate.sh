#!/usr/bin/env bash
# idle_gate.sh — AN IDLE DESKTOP MUST STAY IDLE.
#
# The risk in waking the compositor on client activity is that the mechanism
# fires on things that are not visible changes, and an idle desktop becomes a
# spinning one. That is a worse defect than the frame rate it buys, and it is
# invisible unless measured, because an idle spin looks fine on screen.
#
# CPU is utime+stime deltas out of /proc/<pid>/stat over a fixed interval --
# never `ps pcpu`, which is an average over the process's whole lifetime and
# would hide a spin that started recently.
#
# PASS/FAIL, not informational: this is a gate.
set -uo pipefail
ROOT=/home/david/hamnix-linux/.claude/worktrees/agent-ad4474044a63d6c8a
cd "$ROOT"
BIN="${BIN:-/home/david/.hamnix-build/vk-present-readback/bin}"
SECS="${SECS:-10}"
LIMIT_PCT="${LIMIT_PCT:-5}"          # idle budget for wsysd, per cent of a core
LABEL="${LABEL:-idle}"

W="$(mktemp -d -p /home/david/.hamnix-build/vk-present-readback ig.XXXXXX)"
mkdir -p "$W/noicd"
export HAMWSYS="$W/s" HAMWSYS_BB="$W/b" HAMWSYS_IMG="$W/i"
export HAMFB_FILE="$W/fb.raw" HAMFB_GEOM=1280x800
: >"$W/in"; export HAMWSYSD_INPUT="$W/in"
ICD="${ICD:-$W/noicd/none.json}"

env VK_ICD_FILENAMES="$ICD" ${EXTRA:-} "$BIN/wsysd" </dev/null \
    >"$W/wsysd.log" 2>&1 &
WP=$!
for _ in $(seq 1 100); do [ -s "$HAMFB_FILE" ] && break; sleep 0.1; done
"$BIN/hamdesktop"    </dev/null >/dev/null 2>&1 & DP=$!
"$BIN/hampanelscene" </dev/null >/dev/null 2>&1 & PP=$!
sleep 5      # let the desktop settle; the panel resamples every 320 ms

read_jiffies() { awk '{print $14+$15}' "/proc/$1/stat" 2>/dev/null; }
HZ=$(getconf CLK_TCK)
J0=$(read_jiffies "$WP"); T0=$(date +%s.%N)
sleep "$SECS"
J1=$(read_jiffies "$WP"); T1=$(date +%s.%N)

if [ -z "${J0:-}" ] || [ -z "${J1:-}" ]; then
    echo "idle_gate: FAIL wsysd died during the measurement"
    sed 's/^/   /' "$W/wsysd.log" | tail -5
    kill -9 "$PP" "$DP" "$WP" 2>/dev/null; rm -rf "$W"; exit 1
fi

PCT=$(python3 -c "print(f'{100.0*($J1-$J0)/$HZ/($T1-$T0):.2f}')")
echo "idle_gate[$LABEL]: wsysd used ${PCT}% of a core over ${SECS}s at rest (utime+stime from /proc/$WP/stat, not ps pcpu)"
grep -m1 "wait set" "$W/wsysd.log" | sed 's/^/   /'
RC=0
if python3 -c "import sys; sys.exit(0 if $PCT <= $LIMIT_PCT else 1)"; then
    echo "idle_gate[$LABEL]: PASS (budget ${LIMIT_PCT}%)"
else
    echo "idle_gate[$LABEL]: FAIL an idle desktop is spinning (budget ${LIMIT_PCT}%)"
    RC=1
fi
kill "$PP" "$DP" "$WP" 2>/dev/null; sleep 0.5
kill -9 "$PP" "$DP" "$WP" 2>/dev/null; wait 2>/dev/null
rm -rf "$W"
exit "$RC"
