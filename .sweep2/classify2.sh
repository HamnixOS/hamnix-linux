#!/bin/bash
W=/home/david/hamnix-linux/.claude/worktrees/agent-af0dd6dc5d5f2a8ab
cd "$W" || exit 1
: > .sweep2/vm.txt; : > .sweep2/disp.txt; : > .sweep2/host.txt
for f in tests/linux/*.sh; do
  b=$(basename "$f")
  case "$b" in reap.sh) continue;; esac
  if grep -qE '/dev/dri/card|/dev/fb0|DISPLAY=:0|xdotool' "$f"; then echo "$b" >> .sweep2/disp.txt; continue; fi
  if grep -qE 'hamlinux_image\.sh|hamlinux_vm\.sh|qemu-system|build/image' "$f"; then echo "$b" >> .sweep2/vm.txt; continue; fi
  echo "$b" >> .sweep2/host.txt
done
wc -l .sweep2/vm.txt .sweep2/disp.txt .sweep2/host.txt
echo "=== VM ==="; cat .sweep2/vm.txt
echo "=== DISP ==="; cat .sweep2/disp.txt
echo "=== HOST ==="; cat .sweep2/host.txt
