#!/bin/bash
L=/home/david/hamnix-linux/.claude/worktrees/agent-af0dd6dc5d5f2a8ab/.sweep2/logs
for f in "$@"; do
  echo "-- $f"
  grep -aiE '[0-9]+ (pass|passed|PASS)[, ]|PASS [0-9]+ +FAIL|passed, [0-9]+ failed|[0-9]+ PASS, [0-9]+ FAIL|---- [0-9]+ PASS' "$L/$f.log" 2>/dev/null | tail -2
done
