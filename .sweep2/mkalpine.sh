#!/bin/bash
W=/home/david/hamnix-linux/.claude/worktrees/agent-af0dd6dc5d5f2a8ab
cd "$W" || exit 1
export HAMLINUX_DISTRO_RO=1
timeout 2400 bash scripts/hamlinux_alpine.sh </dev/null > "$W/.sweep2/logs/_alpine_build.log" 2>&1
echo "alpine build rc=$?"
ls -la --block-size=M "$W/build/image/alpine.ext4" 2>&1
