#!/bin/bash
W=/home/david/hamnix-linux/.claude/worktrees/agent-af0dd6dc5d5f2a8ab
cd "$W/.sweep2" || exit 1
awk '{print $1}' logs/_verdicts.txt | sort -u > /tmp/claude-1000/done.$$ 2>/dev/null || true
sed 's/\.sh$//' "$1" | sort -u > /tmp/claude-1000/want.$$
comm -23 /tmp/claude-1000/want.$$ /tmp/claude-1000/done.$$
rm -f /tmp/claude-1000/done.$$ /tmp/claude-1000/want.$$
