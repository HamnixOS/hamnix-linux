#!/bin/bash
# Reproduce the pixcmp flake under load, tip vs control.
W=/home/david/hamnix-linux/.claude/worktrees/agent-af0dd6dc5d5f2a8ab
N="${N:-5}"
LOADN="${LOADN:-8}"
pids=()
for i in $(seq 1 "$LOADN"); do
  bash -c 'end=$((SECONDS+900)); while [ $SECONDS -lt $end ]; do :; done' &
  pids+=($!)
done
echo "load pids: ${pids[*]}"
echo "=== TIP ==="
for i in $(seq 1 "$N"); do
  bash "$W/.sweep2/run_one.sh" pixcmp.sh 900 "$W/.sweep2/flake_tip_$i" </dev/null
  grep -E 'differ in R,G or B|pixcmp: (PASS|FAIL)' "$W/.sweep2/flake_tip_$i/pixcmp.log"
done
echo "=== CONTROL ==="
for i in $(seq 1 "$N"); do
  bash "$W/.sweep2/run_control.sh" pixcmp.sh 900 </dev/null
  grep -E 'differ in R,G or B|pixcmp: (PASS|FAIL)' "$W/.sweep2/ctrl_logs/pixcmp.log"
done
for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
echo "load killed"
