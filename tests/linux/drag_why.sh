#!/usr/bin/env bash
# drag_why.sh — WHY IS DRAG 39.5 fps ON THE GPU PATH AND 53.2 ON THE CPU?
#
# A drag repaints the FULL frame every frame, which is the one workload
# `wsysd -bench` cannot represent: -bench composites with no windows, so
# paint_window() never runs and the vk router is never armed. This runs the
# REAL desktop with a real dragged window and reads wsysd's own per-phase
# counters out of the live loop (HAMNIX_WSYSD_BENCH_LIVE).
#
# Offscreen only: /dev/fb is a plain file, input is a file of evdev records.
set -uo pipefail
ROOT=/home/david/hamnix-linux/.claude/worktrees/agent-ad4474044a63d6c8a
cd "$ROOT"
BIN="${BIN:-/home/david/.hamnix-build/vk-present-readback/bin}"
ICD=/usr/share/vulkan/icd.d/nvidia_icd.json
SECS="${SECS:-12}"

run() {  # label  icd
    local label="$1" icd="$2"
    local W; W="$(mktemp -d -p /home/david/.hamnix-build/vk-present-readback dw.XXXXXX)"
    mkdir -p "$W/noicd"
    export HAMWSYS="$W/wsys.shm" HAMWSYS_BB="$W/wsys.bb" HAMWSYS_IMG="$W/wsys.img"
    export HAMFB_FILE="$W/fb.raw" HAMFB_GEOM=1280x800
    : >"$W/input.evdev"; export HAMWSYSD_INPUT="$W/input.evdev"

    echo "=== $label"
    VK_ICD_FILENAMES="$icd" HAMNIX_WSYSD_BENCH_LIVE=60 ${EXTRA_ENV:-} \
        "$BIN/wsysd" </dev/null >"$W/wsysd.log" 2>"$W/bench.log" &
    local WP=$!
    for _ in $(seq 1 100); do [ -s "$HAMFB_FILE" ] && break; sleep 0.1; done
    "$BIN/hamdesktop"    </dev/null >/dev/null 2>&1 & local DP=$!
    "$BIN/hampanelscene" </dev/null >/dev/null 2>&1 & local PP=$!
    sleep 4
    "$BIN/de_dragload" 480 320 120 300 300 8 >/dev/null 2>&1 & local GP=$!
    sleep "$SECS"

    grep -m1 "vk backend" "$W/wsysd.log" | sed 's/^/   /'
    echo "   --- last 4 live dumps (us per FULL frame) ---"
    grep "^benchlive: seq" "$W/bench.log" | tail -4 | sed 's/^/   /'

    kill "$GP" "$PP" "$DP" "$WP" 2>/dev/null
    sleep 1
    kill -9 "$GP" "$PP" "$DP" "$WP" 2>/dev/null
    wait "$GP" "$PP" "$DP" "$WP" 2>/dev/null
    echo "   (workdir kept: $W)"
}

W0="$(mktemp -d -p /home/david/.hamnix-build/vk-present-readback noicd.XXXXXX)"
mkdir -p "$W0/noicd"
run "SOFTWARE" "$W0/noicd/none.json"
run "GPU (host-cached frame)" "$ICD"
EXTRA_ENV="HAMNIX_VK_FRAME_MEM=device" run "GPU (device-local frame -- the OLD placement)" "$ICD"
rm -rf "$W0"
