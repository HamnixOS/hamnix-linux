#!/bin/bash
# Serial VM gate chain. build/image is shared in-tree, so one at a time.
W=/home/david/hamnix-linux/.claude/worktrees/agent-af0dd6dc5d5f2a8ab
cd "$W" || exit 1
export HAMLINUX_DISTRO_RO=1
LD="$W/.sweep2/logs"
mkdir -p "$LD"
# prerequisite for channel_covers_image.sh
if [ ! -d build/repo/linux ]; then
  echo "=== prereq: hamlinux_packages.py ==="
  timeout 2400 python3 scripts/hamlinux_packages.py </dev/null > "$LD/_prereq_packages.log" 2>&1
  echo "prereq rc=$? repo=$(ls build/repo 2>/dev/null | tr '\n' ' ')"
fi
n=0
while read -r g; do
  [ -z "$g" ] && continue
  n=$((n+1))
  bash "$W/.sweep2/run_one.sh" "$g" 1800 "$LD" </dev/null
done < "$W/.sweep2/vmorder.txt"
echo "VMCHAIN DONE attempted=$n"
