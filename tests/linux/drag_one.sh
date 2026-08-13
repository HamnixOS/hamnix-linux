#!/usr/bin/env bash
# One arm of drag_why.sh, with the dump interval and duration under control,
# so the slow placements (which cannot reach 60 full frames in 12 s) can be
# measured too. ARM=device|cached|sw
set -uo pipefail
# PRIVATE NAMESPACE FIRST, and sourced by ABSOLUTE PATH because this script's
# $ROOT is not the tree it lives in. It starts wsysd, hamdesktop and
# hampanelscene, whose names are compiled into them -- /srv/wsys,
# /dev/shm/hamnix-wsys, /tmp/hamnix-wsys, /tmp/hamdesktop-wp.status,
# /tmp/.hamdesktop.src, /tmp/hamnix-panel.health (the table is in
# tests/linux/private_ns.sh) -- and this machine's own live desktop holds them.
# One arm of drag_why.sh means one arm of a COMPARISON, so a segment left where
# another run can attach to it is load, and load is what this measures. It costs
# the GPU nothing: the namespace shadows /tmp, /dev/shm and /srv, not /dev/dri
# or the ICD, measured in tests/linux/pixcmp.sh.
PRIVNS_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$PRIVNS_HOME/private_ns.sh"
priv_ns_reexec "$@"
ROOT=/home/david/hamnix-linux/.claude/worktrees/agent-ad4474044a63d6c8a
cd "$ROOT"
BIN=/home/david/.hamnix-build/vk-present-readback/bin
ICD=/usr/share/vulkan/icd.d/nvidia_icd.json
SECS="${SECS:-30}"; EVERY="${EVERY:-10}"; ARM="${ARM:-cached}"
echo "   $(priv_ns_describe)"
W="$(mktemp -d -p /home/david/.hamnix-build/vk-present-readback d1.XXXXXX)"
mkdir -p "$W/noicd"
export HAMWSYS="$W/wsys.shm" HAMWSYS_BB="$W/wsys.bb" HAMWSYS_IMG="$W/wsys.img"
export HAMFB_FILE="$W/fb.raw" HAMFB_GEOM=1280x800
: >"$W/input.evdev"; export HAMWSYSD_INPUT="$W/input.evdev"
case "$ARM" in
  sw) ICDUSE="$W/noicd/none.json"; MEM= ;;
  *)  ICDUSE="$ICD"; MEM="HAMNIX_VK_FRAME_MEM=$ARM" ;;
esac
env VK_ICD_FILENAMES="$ICDUSE" HAMNIX_WSYSD_BENCH_LIVE="$EVERY" $MEM \
    "$BIN/wsysd" </dev/null >"$W/wsysd.log" 2>"$W/bench.log" &
WP=$!
for _ in $(seq 1 100); do [ -s "$HAMFB_FILE" ] && break; sleep 0.1; done
"$BIN/hamdesktop"    </dev/null >/dev/null 2>&1 & DP=$!
"$BIN/hampanelscene" </dev/null >/dev/null 2>&1 & PP=$!
sleep 4
"$BIN/de_dragload" 480 320 120 300 300 8 >/dev/null 2>&1 & GP=$!
sleep "$SECS"
grep -m1 "vk backend" "$W/wsysd.log" | sed 's/^/   /'
grep "^benchlive: seq" "$W/bench.log" | tail -5 | sed 's/^/   /'
kill "$GP" "$PP" "$DP" "$WP" 2>/dev/null; sleep 1
kill -9 "$GP" "$PP" "$DP" "$WP" 2>/dev/null; wait 2>/dev/null
echo "   kept: $W"
