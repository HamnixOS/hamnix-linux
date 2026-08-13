#!/bin/bash
W=/home/david/hamnix-linux/.claude/worktrees/agent-af0dd6dc5d5f2a8ab
C="$W/.sweep2/control"
cd "$W" || exit 1
if [ -f "$C/.ready" ]; then echo "control already ready"; exit 0; fi
rm -rf "$C"; mkdir -p "$C"
git archive b87174c344bbc542374323d7d996affff480c511 | tar -x -C "$C" || exit 1
# adder submodule content: copy from this worktree's checked-out submodule at the control sha
sha=$(git ls-tree b87174c344bbc542374323d7d996affff480c511 adder | awk '{print $3}')
echo "control adder submodule sha=$sha"
rm -rf "$C/adder"
git -C "$W/adder" archive "$sha" --prefix=adder/ 2>/dev/null | tar -x -C "$C" || {
  echo "WARN: could not archive adder at $sha; copying working submodule"
  cp -a "$W/adder" "$C/adder"
}
cd "$C" || exit 1
. scripts/_adder_cc.sh
adder_cc_bootstrap > "$W/.sweep2/logs/_control_bootstrap.log" 2>&1
rc=$?
echo "control bootstrap rc=$rc"
ls -l "$C/build/cutover/host_ac.elf" && touch "$C/.ready"
