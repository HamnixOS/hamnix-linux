#!/bin/bash
N="${1:-20}"
V=/home/david/hamnix-linux/.claude/worktrees/agent-af0dd6dc5d5f2a8ab/.sweep2/logs/_verdicts.txt
while true; do
  c=0
  if [ -f "$V" ]; then c=$(wc -l < "$V"); fi
  if [ "$c" -ge "$N" ]; then break; fi
  sleep 20
done
echo "verdicts=$c"
