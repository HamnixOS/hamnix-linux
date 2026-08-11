#!/usr/bin/env bash
# tests/linux/wsys_cover.sh — does a committed scene COVER the window it is in?
#
# THE DEFECT THIS IS THE GATE FOR. user/wsysd.ad clears a window's colour image
# to opaque black before rasterizing it and then blits the WHOLE w*h rect to
# the screen, so every pixel of a window that the display list does not paint
# reaches the framebuffer as black. Two windows in this tree were doing that:
#
#   * user/hamimgscene.ad painted 320x260 and never wrote a `geometry` verb, so
#     win_alloc in user/linux-wsys.c gave it the 640x480 default and the bottom
#     and right of the window were black
#     (docs/screenshots/linux/wsys-image-on-desktop.png);
#   * the panel's Applications dropdown paints a 136 px menu column into a
#     window that GROWS to the full width of the display, so the wallpaper and
#     the desktop icons to the right of the menu are covered by a black
#     rectangle (docs/screenshots/linux/distro-menu-debian.png).
#
# Both were found by the machine owner LOOKING AT A SCREENSHOT. Every gate in
# the tree passed: the display lists were right, every op drew, every layer
# returned success. A human's eye is not a detection mechanism, and this is the
# one that replaces it.
#
# HOW. lib/hamui_host.ad -- the rasterizer user/wsysd.ad composites every
# window with -- now unions each painting op's destination rect into a per-row
# interval, and answers hamui_host_uncovered_rows() / _covered_w() /
# _covered_h() afterwards. user/scene_raster_host.ad prints that verdict for a
# display list at a stated window size. This script feeds it the two real
# shapes plus a positive control and asserts what each must say.
#
# The measure is a per-row UNION, so it is CONSERVATIVE: it never accuses a
# scene that is fine, and an interior hole with paint on both sides of it on
# the same row is not reported. That is stated here rather than left for a
# reader to discover, because a gate that over-claims is the thing this tree
# keeps being bitten by.
#
# Host-only: no VM, no compositor, no framebuffer, no display. Seconds.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

WORK="${WSYSCOV_WORK:-$(mktemp -d -p "${TMPDIR:-/tmp}" wsyscov.XXXXXX)}"
mkdir -p "$WORK"
KEEP="${WSYSCOV_KEEP:-0}"
cleanup() { [ "$KEEP" = 1 ] || rm -rf "$WORK"; }
trap cleanup EXIT

pass=0; fail=0
ok()  { echo "wsyscov: PASS $*"; pass=$((pass+1)); }
bad() { echo "wsyscov: FAIL $*"; fail=$((fail+1)); }

SRH="$WORK/scene_raster_host"
if ! scripts/hamlinux_build.sh user/scene_raster_host.ad "$SRH" \
        >"$WORK/build.log" 2>&1; then
    bad "could not build user/scene_raster_host.ad"
    tail -20 "$WORK/build.log" >&2
    echo "wsyscov: $pass passed, $fail failed"; exit 1
fi
ok "scene_raster_host builds"

# `x | grep -q` under `set -o pipefail` reports FAILURE on a successful match,
# so every match below is a here-string.
verdict() {   # verdict <dl> <w> <h>  -> the tool's coverage line on stdout
    "$SRH" "$1" "$WORK/out.ppm" "$2" "$3" 2>&1 | grep -E 'COVERS|UNCOVERED'
}
expect() {    # expect <label> <dl> <w> <h> <regex>
    local got; got="$(verdict "$2" "$3" "$4")"
    if grep -Eq "$5" <<<"$got"; then ok "$1 -- $got"
    else bad "$1 -- wanted /$5/, got: $got"; fi
}

# 1. POSITIVE CONTROL. A scene that fills its whole window must NOT be accused.
#    This is the half that matters most: a gate that cries wolf gets ignored.
printf 'fill 0 0 320 260 #202830\nglyphs 12 20 "Image demo" #e8e8e8\n' \
    > "$WORK/covers.dl"
expect "a scene that fills its window is not accused" \
    "$WORK/covers.dl" 320 260 'COVERS 320x260'

# 2. A rounded card filling the window counts as covering it -- the AA corners
#    nibble a few pixels and a gate that reported those would be noise.
printf 'roundrect 0 0 400 300 8 #2b2b2b\n' > "$WORK/round.dl"
expect "a full-window roundrect covers its window" \
    "$WORK/round.dl" 400 300 'COVERS 400x300'

# 3. THE hamimgscene SHAPE, as it was: 320x260 of paint in a 640x480 window.
printf 'fill 0 0 320 260 #202830\n' > "$WORK/imgscene.dl"
expect "hamimgscene's old 320x260-in-640x480 is caught, with both sizes named" \
    "$WORK/imgscene.dl" 640 480 \
    'UNCOVERED 480 of 480 rows.*covers 320x260 of a 640x480 window'

# 4. THE PANEL DROPDOWN SHAPE: a full-width bar plus a 136 px menu column in a
#    window grown to the full width of the display. The bar rows are covered;
#    the 224 rows of the grown band are not.
printf 'fill 0 0 1280 26 #eceef2\nfill 0 26 136 224 #303030\n' \
    > "$WORK/panel.dl"
expect "the panel dropdown's full-width grown band is caught" \
    "$WORK/panel.dl" 1280 250 'UNCOVERED 224 of 250 rows'

# 5. GLYPHS AND LINES DO NOT COUNT AS COVER. Text is sparse antialiased marks
#    on a background; a window with nothing but text in it is unpainted, and
#    that is the honest reading.
printf 'glyphs 10 20 "nothing but text" #ffffff\n' > "$WORK/text.dl"
expect "a window with only text in it is reported uncovered" \
    "$WORK/text.dl" 200 100 'UNCOVERED 100 of 100 rows'

# 6. The REAL panel in its resting state -- from the program itself via
#    --scene-dump, not a hand-written list. The dump hook has no compositor to
#    ask for a screen size and builds at 800x26 (its first line is
#    `fill 0 0 800 26 #eceef2`), which is the resting window: the bar only.
#    It must cover that. This is the regression half: if the panel ever stops
#    painting its own bar edge to edge, this says so.
PANEL="$WORK/hampanelscene"
if scripts/hamlinux_build.sh user/hampanelscene.ad "$PANEL" \
        >"$WORK/panel.build.log" 2>&1; then
    if "$PANEL" --scene-dump "$WORK/real-panel.dl" >"$WORK/panel.run.log" 2>&1 \
            && [ -s "$WORK/real-panel.dl" ]; then
        expect "the real panel bar covers its resting 800x26 window" \
            "$WORK/real-panel.dl" 800 26 'COVERS 800x26'
    else
        bad "hampanelscene --scene-dump produced no display list"
        tail -5 "$WORK/panel.run.log" >&2
    fi
else
    bad "could not build user/hampanelscene.ad"
    tail -20 "$WORK/panel.build.log" >&2
fi

echo "wsyscov: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
