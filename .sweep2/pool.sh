#!/bin/bash
# pool.sh <listfile> <budget> <parallel> [logdir]
W=/home/david/hamnix-linux/.claude/worktrees/agent-af0dd6dc5d5f2a8ab
L="$1"; B="${2:-600}"; P="${3:-4}"; LD="${4:-$W/.sweep2/logs}"
n=0
while read -r g; do
  [ -z "$g" ] && continue
  case "$g" in \#*) continue;; esac
  bash "$W/.sweep2/run_one.sh" "$g" "$B" "$LD" </dev/null &
  n=$((n+1))
  while [ "$(jobs -r | wc -l)" -ge "$P" ]; do sleep 2; done
done < "$L"
wait
echo "POOL DONE attempted=$n"
