#!/bin/bash
# Independent failure-assertion scan across every log, ignoring each gate's own summary.
LD="${1:-/home/david/hamnix-linux/.claude/worktrees/agent-af0dd6dc5d5f2a8ab/.sweep2/logs}"
for f in "$LD"/*.log; do
  b=$(basename "$f" .log)
  case "$b" in _*) continue;; esac
  hits=$(grep -inE '(^|[^A-Za-z])(FAIL|FAILED|ERROR|Traceback|Assertion|assert failed|not ok|BROKEN|MISSING|refused to|core dumped|Segmentation fault)' "$f" | grep -viE '0 FAIL|FAIL=0|fails=0|no fail|failure-|# |allowed to fail|expected fail' | head -6)
  npass=$(grep -coE '(^|[^A-Za-z])PASS' "$f")
  nfail=$(grep -coE '(^|[^A-Za-z])FAIL' "$f")
  printf '%-32s PASSlines=%-4s FAILlines=%-4s\n' "$b" "$npass" "$nfail"
  if [ -n "$hits" ]; then echo "$hits" | sed 's/^/      /'; fi
done
