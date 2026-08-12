#!/usr/bin/env bash
# pixcmp.sh — DOES DEVICE COMPOSITING PRODUCE THE SAME PIXELS AS THE CPU?
#
# The compositor rewrite replaces five CPU writes into the composite with
# device ops. "Mechanical" is not "safe": a wrong colour order, a wrong blit
# mode or a missed clip produces a frame that LOOKS like a desktop and is
# wrong. So every site is checked the only way that means anything -- byte
# comparison of the whole framebuffer against the software path on the same
# desktop.
#
# Determinism: hampanelscene is NOT started (its clock and sysmon resample
# change the pixels every 320 ms). hamdesktop's wallpaper and icons are
# static, the pointer never moves, and both runs settle before the capture.
#
# Offscreen only: /dev/fb is a plain file. No DRM, no master, no modeset.
set -uo pipefail
ROOT=/home/david/hamnix-linux/.claude/worktrees/agent-ad4474044a63d6c8a
cd "$ROOT"
BIN=/home/david/.hamnix-build/vk-present-readback/bin
ICD=/usr/share/vulkan/icd.d/nvidia_icd.json
GEOM="${GEOM:-1280x800}"
SETTLE="${SETTLE:-6}"

cap() {  # label  icd  extra-env...   -> writes $OUT
    local label="$1" icd="$2" out="$3"; shift 3
    local W; W="$(mktemp -d -p /home/david/.hamnix-build/vk-present-readback pc.XXXXXX)"
    mkdir -p "$W/noicd"
    export HAMWSYS="$W/wsys.shm" HAMWSYS_BB="$W/wsys.bb" HAMWSYS_IMG="$W/wsys.img"
    export HAMFB_FILE="$W/fb.raw" HAMFB_GEOM="$GEOM"
    : >"$W/input.evdev"; export HAMWSYSD_INPUT="$W/input.evdev"
    env VK_ICD_FILENAMES="$icd" "$@" "$BIN/wsysd" </dev/null \
        >"$W/wsysd.log" 2>&1 &
    local WP=$!
    for _ in $(seq 1 100); do [ -s "$HAMFB_FILE" ] && break; sleep 0.1; done
    "$BIN/hamdesktop" </dev/null >/dev/null 2>&1 & local DP=$!
    sleep "$SETTLE"
    cp "$HAMFB_FILE" "$out"
    grep -m1 "vk backend" "$W/wsysd.log" | sed "s/^/   [$label] /"
    grep -i "devcomp\|WARNING" "$W/wsysd.log" | head -3 | sed "s/^/   [$label] /"
    kill "$DP" "$WP" 2>/dev/null; sleep 0.5
    kill -9 "$DP" "$WP" 2>/dev/null; wait "$DP" "$WP" 2>/dev/null
    rm -rf "$W"
}

O=/home/david/.hamnix-build/vk-present-readback
NOICD="$(mktemp -d -p "$O" ni.XXXXXX)"; mkdir -p "$NOICD/noicd"
cap "software" "$NOICD/noicd/none.json" "$O/fb_sw.raw"
cap "gpu-devcomp" "$ICD" "$O/fb_gpu.raw" ${DEVCOMP_ENV:-HAMNIX_WSYSD_VKCOMP=1}
rm -rf "$NOICD"

python3 - "$O/fb_sw.raw" "$O/fb_gpu.raw" <<'PY'
import sys
a=open(sys.argv[1],'rb').read(); b=open(sys.argv[2],'rb').read()
if len(a)!=len(b):
    print(f"pixcmp: FAIL different sizes {len(a)} vs {len(b)}"); sys.exit(1)
if not a:
    print("pixcmp: FAIL empty framebuffer -- the instrument captured nothing"); sys.exit(1)
diff=sum(1 for i in range(0,len(a),4) if a[i:i+4]!=b[i:i+4])
tot=len(a)//4
print(f"pixcmp: {diff} of {tot} pixels differ ({100.0*diff/tot:.3f}%)")
if diff==0:
    print("pixcmp: PASS byte-identical to the software rasterizer"); sys.exit(0)
# Where, and how badly -- a colour-order bug and a clipping bug look different.
first=None; import collections
c=collections.Counter()
for i in range(0,len(a),4):
    if a[i:i+4]!=b[i:i+4]:
        if first is None: first=i//4
        c[(a[i:i+4].hex(), b[i:i+4].hex())]+=1
w=int(__import__('os').environ.get('W','1280'))
print(f"pixcmp: first differing pixel #{first} at x={first%w} y={first//w}")
for (sw,gpu),n in c.most_common(6):
    print(f"pixcmp:   sw {sw} -> gpu {gpu}   x{n}")
print("pixcmp: FAIL"); sys.exit(1)
PY
