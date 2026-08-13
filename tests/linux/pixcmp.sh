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
# PRIVATE NAMESPACE FIRST, and sourced by ABSOLUTE PATH because this script's
# $ROOT is not the tree it lives in. "Offscreen only: /dev/fb is a plain file.
# No DRM, no master, no modeset." above is true and is about the DISPLAY; the
# filesystem is a separate question. wsysd's names are compiled into it
# (/srv/wsys, /dev/shm/hamnix-wsys, /tmp/hamnix-wsys) and hamdesktop's are too
# (/tmp/hamdesktop-wp.status, /tmp/.hamdesktop.src) -- the table is in
# tests/linux/private_ns.sh -- and this machine's own live desktop holds them.
#
# DETERMINISM IS THIS GATE'S WHOLE ARGUMENT, which is why hampanelscene is not
# started: anything that changes a pixel between the two captures is a false
# difference. A concurrent process reaching a shared segment is exactly that,
# so a private tmpfs is part of the determinism and not merely tidiness.
# Nothing here asserts about a uid; $O and $BIN stay under $HOME/.hamnix-build,
# which the helper does not shadow, so the two captures still land where the
# comparer reads them.
PRIVNS_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$PRIVNS_HOME/private_ns.sh"
priv_ns_reexec "$@"
ROOT=/home/david/hamnix-linux/.claude/worktrees/agent-ad4474044a63d6c8a
cd "$ROOT"
BIN="${FPS_BIN_DIR:-/home/david/.hamnix-build/vk-present-readback/bin}"
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
    # A DECORATED WINDOW, held still. Without one the desktop is nothing but
    # the full-screen backdrop, which takes the `direct` path and never calls
    # blit_window_image_mode -- so the site most likely to be wrong (three
    # blit modes against one device source-over) would go untested and the
    # comparer would print PASS having exercised none of it. Speed 0 keeps it
    # deterministic.
    local GP=0
    if [ "${PIXCMP_WINDOW:-1}" = 1 ]; then
        "$BIN/de_dragload" 480 320 160 340 0 8 >/dev/null 2>&1 & GP=$!
    fi
    sleep "$SETTLE"
    cp "$HAMFB_FILE" "$out"
    grep -m1 "vk backend" "$W/wsysd.log" | sed "s/^/   [$label] /"
    grep -i "devcomp\|WARNING" "$W/wsysd.log" | head -3 | sed "s/^/   [$label] /"
    kill "$GP" "$DP" "$WP" 2>/dev/null; sleep 0.5
    kill -9 "$GP" "$DP" "$WP" 2>/dev/null; wait "$GP" "$DP" "$WP" 2>/dev/null
    rm -rf "$W"
}

echo "   [pixcmp] $(priv_ns_describe)"
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
tot=len(a)//4
diff=sum(1 for i in range(0,len(a),4) if a[i:i+4]!=b[i:i+4])
# THE X BYTE OF XRGB8888 IS UNDEFINED, AND THE SOFTWARE PATH DOES NOT AGREE
# WITH ITSELF ABOUT IT. Measured on the software capture: 1,023,883 pixels
# carry X=255 (window blits copy the source word, alpha included) and exactly
# 117 carry X=0 -- the cursor, because put_px is the one writer that forces
# it. So a byte-exact test on that byte is not a test of correctness, it is a
# test of which of two software behaviours got there last.
#
# Both numbers are therefore reported and the RGB one is the gate. This is
# deliberately NOT a silent mask: if the X byte were the ONLY difference the
# run still says so, with the count, so the weakening cannot hide a real bug.
rgbdiff=sum(1 for i in range(0,len(a),4) if a[i:i+3]!=b[i:i+3])
xonly=diff-rgbdiff
print(f"pixcmp: {diff} of {tot} pixels differ as whole words ({100.0*diff/tot:.3f}%)")
print(f"pixcmp: {rgbdiff} differ in R,G or B  <-- THIS is the gate")
print(f"pixcmp: {xonly} differ ONLY in the undefined X byte of XRGB8888")
if rgbdiff==0:
    print("pixcmp: PASS every displayed colour matches the software rasterizer")
    sys.exit(0)
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
