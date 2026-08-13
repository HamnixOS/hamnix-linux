#!/bin/bash
L=/home/david/hamnix-linux/.claude/worktrees/agent-af0dd6dc5d5f2a8ab/.sweep2/logs
N="${SHOW_LINES:-25}"
for f in "$@"; do
  echo "######## $f"
  tail -n "$N" "$L/$f.log" 2>&1
done
