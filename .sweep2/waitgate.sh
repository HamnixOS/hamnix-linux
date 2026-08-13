#!/bin/bash
# wait until a named gate appears in _verdicts.txt
G="$1"
V=/home/david/hamnix-linux/.claude/worktrees/agent-af0dd6dc5d5f2a8ab/.sweep2/logs/_verdicts.txt
while ! grep -q "^$G " "$V" 2>/dev/null; do sleep 15; done
grep "^$G " "$V"
