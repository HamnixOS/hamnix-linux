#!/bin/bash
# run_one.sh <gate.sh> <budget_seconds> [logdir]
W=/home/david/hamnix-linux/.claude/worktrees/agent-af0dd6dc5d5f2a8ab
cd "$W" || exit 99
G="$1"; B="${2:-600}"; LD="${3:-$W/.sweep2/logs}"
mkdir -p "$LD"
base="$(basename "$G" .sh)"
export HAMLINUX_DISTRO_RO=1
export SRV_WORK="$W/.sweep2/srvwork/$base"
export CHANRUN_TMP="$W/.sweep2/chanrun"
unset TMPDIR
mkdir -p "$SRV_WORK" "$CHANRUN_TMP"
s=$(date +%s)
timeout -k 15 "$B" bash "$W/tests/linux/$G" </dev/null >"$LD/$base.log" 2>&1
rc=$?
e=$(date +%s)
echo "$base rc=$rc secs=$((e-s))" >> "$LD/_verdicts.txt"
echo "$base rc=$rc secs=$((e-s))"
