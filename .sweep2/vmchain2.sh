#!/bin/bash
W=/home/david/hamnix-linux/.claude/worktrees/agent-af0dd6dc5d5f2a8ab
cd "$W" || exit 1
export HAMLINUX_DISTRO_RO=1
LD="$W/.sweep2/logs"
n=0
while read -r g; do
  [ -z "$g" ] && continue
  n=$((n+1))
  bash "$W/.sweep2/run_one.sh" "$g" 1800 "$LD" </dev/null
done < "$W/.sweep2/vmorder4.txt"
echo "VMCHAIN4 DONE attempted=$n"
