#!/bin/bash
# Every log with a line that asserts a failure, independent of its own summary.
L=/home/david/hamnix-linux/.claude/worktrees/agent-af0dd6dc5d5f2a8ab/.sweep2/logs
for f in "$L"/*.log; do
  b=$(basename "$f" .log)
  case "$b" in _*) continue;; esac
  # a FAIL that is not "0 FAIL", "FAIL 0", "N failed" with N=0, or prose
  hits=$(grep -aE '(^|[^A-Za-z0-9_])(FAIL|FAILED)([^A-Za-z0-9_]|$)' "$f" \
         | grep -avE '0 FAIL|FAIL 0|FAIL=0|0 failed|every FAIL|FAIL below|could not build' \
         | grep -avE 'mprotect_w=FAIL')
  if [ -n "$hits" ]; then
    echo "### $b"
    echo "$hits" | head -4 | sed 's/^/    /'
  fi
done
