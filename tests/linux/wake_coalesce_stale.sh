#!/usr/bin/env bash
# wake_coalesce_stale.sh — A COALESCED FRAME IS LATE, NEVER LOST.
#
# wsysd now drops the client-wake fd from its park set while a frame is owed,
# so a dragging client's ~850 pokes a second stop waking a loop that has
# already scheduled the repaint. The two ways that can go wrong are the two
# things this gate checks, and neither is visible in a frame-rate number:
#
#   1. THE LAST FRAME IS LOST. The client publishes, the frame is deferred,
#      the client then goes silent. If nothing wakes the loop, the screen sits
#      one frame stale for ever. (wait_ms_now() is supposed to cover this: with
#      paint_defer set it parks only until the frame boundary.)
#
#   2. THE FLAG LATCHES AND THE CLIENT WAKE NEVER COMES BACK. paint_defer now
#      decides whether the wake fd is in the park set at all, so a paint_defer
#      that is never cleared would silently disconnect client-driven repaint
#      for the life of the process -- and the desktop would still look alive,
#      because input and the fallback tick both still work. That is a
#      success-shaped failure, which is why it is gated rather than argued.
#
# Offscreen, software rasterizer, no ICD: this cannot touch the display. The
# cap is FORCED, because offscreen frame_us is 0 and without the force this
# gate would exercise none of the code it exists to test.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"
. tests/linux/reap.sh

BIN="${FPS_BIN_DIR:-/home/david/.hamnix-build/cap-power-ab/bin}"
W="$(mktemp -d -p "${TMPDIR:-/tmp}" wcs.XXXXXX)"
reap_track "$W/reaped"
pass=0; fail=0
ok()  { echo "stale: PASS $*"; pass=$((pass+1)); }
bad() { echo "stale: FAIL $*"; fail=$((fail+1)); }
cleanup() { rm -rf "$W"; }
reap_on_exit cleanup

mkdir -p "$W/noicd"
export HAMWSYS="$W/s" HAMWSYS_BB="$W/b" HAMWSYS_IMG="$W/i"
export HAMFB_FILE="$W/fb.raw" HAMFB_GEOM=1280x800
: >"$W/in"; export HAMWSYSD_INPUT="$W/in"
export VK_ICD_FILENAMES="$W/noicd/none.json"
export HAMNIX_WSYSD_CAP_US="${CAP_US:-16666}"

"$BIN/wsysd" </dev/null >"$W/wsysd.log" 2>&1 &
WP=$!; reap_add "$WP"
for _ in $(seq 1 100); do [ -s "$HAMFB_FILE" ] && break; sleep 0.1; done
[ -s "$HAMFB_FILE" ] || { bad "wsysd produced no framebuffer"; exit 1; }
grep -m1 "present cap" "$W/wsysd.log" | sed 's/^/stale:   /'
grep -q "present cap FORCED" "$W/wsysd.log" || {
    bad "the cap did not arm -- this gate would test nothing"; exit 1; }
"$BIN/hamdesktop" </dev/null >/dev/null 2>&1 & reap_add $!
sleep 4

snap() { cp "$HAMFB_FILE" "$W/$1"; }

# SAMPLE DURING THE DRAG, NOT AFTER IT. The first version of this gate
# compared before-the-drag against after-the-drag and declared the load dead
# because the two were identical. They were identical because they SHOULD be:
# killing de_dragload destroys its window, so the compositor correctly returns
# the screen to exactly the desktop it was showing before. That is the
# compositor being right and the gate being wrong, and it is the reason every
# check below is anchored on a snapshot taken while the client is still alive.
drag_start() {
    "$BIN/de_dragload" 480 320 160 340 300 8 >"$W/drag.log" 2>&1 &
    DRAG_PID=$!; reap_add "$DRAG_PID"
}
drag_stop() { kill -9 "$DRAG_PID" 2>/dev/null; wait "$DRAG_PID" 2>/dev/null; }

snap A
drag_start
sleep 2; snap M1
sleep 2; snap M2
drag_stop
sleep 2; snap B        # settled after the client died
sleep 2; snap C        # and still settled 2 s later

# The drag must actually have moved something, or the rest proves nothing.
if cmp -s "$W/A" "$W/M1"; then
    bad "the drag changed no pixels (A == M1) -- the load is not running, so this gate is vacuous"
else
    ok "the drag moved the screen (A != M1), so the load is real"
fi

# 1. LIVE DURING THE DRAG. Two snapshots 2 s apart WHILE the client is still
#    publishing must differ. If the deferral ever swallowed the wake without
#    rearming it, the screen would freeze here while the client kept moving --
#    and every frame-rate counter would go on looking healthy, because the
#    counters live in the compositor that stopped listening.
if cmp -s "$W/M1" "$W/M2"; then
    bad "the screen FROZE during the drag (M1 == M2) while the client was still publishing -- the client wake is not rearming after a deferral"
else
    ok "the screen stayed LIVE through the drag (M1 != M2) -- deferred frames are still being painted"
fi

# 2. CONVERGED. Two snapshots 2 s apart, long after the last client publish,
#    must be identical: nothing is still churning and nothing is still owed.
if cmp -s "$W/B" "$W/C"; then
    ok "the screen CONVERGED after the client went silent (B == C) -- a coalesced frame is late, not lost, and the loop is not still repainting"
else
    bad "the screen was STILL CHANGING 2 s after the last client publish (B != C) -- a deferred frame is being repainted for ever, or the loop is spinning"
fi

# 3. THE CLIENT WAKE STILL WORKS AFTER A DEFERRAL EPISODE. The latch test: if
#    paint_defer stayed set, the wake fd would be gone from the park set for
#    good. Checked by PIXELS rather than by rate, because the 16 ms fallback
#    tick would still eventually paint and so would hide a disconnected wake
#    behind a plausible-looking frame rate.
drag_start
sleep 2; snap D
drag_stop
if cmp -s "$W/C" "$W/D"; then
    bad "a SECOND drag after a deferral episode changed nothing (C == D) -- paint_defer has latched and the client wake is disconnected"
else
    ok "client-driven repaint still works after a deferral episode (C != D) -- paint_defer is not latching"
fi
sleep 3; snap E
if cmp -s "$W/B" "$W/E"; then
    ok "and the screen returned to the same settled desktop again (B == E)"
else
    bad "the screen did not return to the settled desktop after the second burst (B != E)"
fi

echo "stale: $pass passed, $fail failed"
[ "$fail" = 0 ]
