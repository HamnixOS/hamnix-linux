#!/bin/bash
# run_control.sh <gate.sh> <budget>
W=/home/david/hamnix-linux/.claude/worktrees/agent-af0dd6dc5d5f2a8ab
C="$W/.sweep2/control"
cd "$C" || exit 99
G="$1"; B="${2:-900}"
base="$(basename "$G" .sh)"
LD="$W/.sweep2/ctrl_logs"; mkdir -p "$LD"
export HAMLINUX_DISTRO_RO=1
export SRV_WORK="$W/.sweep2/srvwork_ctrl/$base"
export CHANRUN_TMP="$W/.sweep2/chanrun_ctrl"
export TMPDIR="/tmp/claude-1000/sw2c"
mkdir -p "$SRV_WORK" "$CHANRUN_TMP" "$TMPDIR"
s=$(date +%s)
timeout -k 15 "$B" bash "$C/tests/linux/$G" </dev/null >"$LD/$base.log" 2>&1
rc=$?
e=$(date +%s)
echo "CONTROL $base rc=$rc secs=$((e-s))" | tee -a "$LD/_verdicts.txt"
