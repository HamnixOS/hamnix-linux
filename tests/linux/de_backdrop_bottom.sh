#!/usr/bin/env bash
# Its host runtime and its pass/fail were NOT measured when this line was
# written. If you make it cheap enough for the battery, add the manifest line
# and delete this block.
#
# tests/linux/de_backdrop_bottom.sh — THE BOTTOM ROWS OF THE DESKTOP BACKDROP,
# AT THE OWNER'S 1920x1200 PANEL.
#
# THE BUG, AS HE SAW IT ON 2026-08-16
# ===================================
#     "The background screen doesn't cover the entire desktop space. There's a
#      black bar at the bottom, just above the bottom panel."
#
# MEASURED OFFSCREEN AT HIS GEOMETRY, which is the only reason the cause is
# known rather than guessed. At 1920x1200 the backdrop's last painted row is
# 1079 and rows 1080..1173 -- 94 of them, ending exactly where the bottom panel
# begins -- reach the screen as the compositor's clear colour (#1c1c1c). At
# 1920x1300 the same band is rows 1080..1273 (194 of them). At 1280x800 there
# is no band at all. IT ALWAYS BEGINS AT EXACTLY 1080, whatever the screen
# height is, which is a CONSTANT and not arithmetic.
#
# WHERE IT IS NOT, because these were the suspects and each is refuted by a
# measurement rather than by reading:
#
#   * NOT hamdesktop's arithmetic. Its gradient bands come out 25 rows tall at
#     1920x1200, and 1200/48 == 25, so it computed the FULL height. The band
#     that straddles 1080 (rows 1075..1099) is painted for its first five rows
#     and then stops. A display list that had been TRUNCATED would have lost
#     that whole band; a fill that had been clipped loses part of one. This is
#     a clip.
#   * NOT the display-list byte cap. See above: a mid-fill cut, not a dropped
#     trailing op. WP_SCENE_BUDGET's arithmetic is not involved -- this run has
#     no wallpaper image at all and takes the procedural gradient path.
#   * NOT the icon layout's PANEL_BOT_H reservation. That moves ICONS. The
#     backdrop's own fill is emitted at 0,0,scr_w,scr_h and the band is a hole
#     in the BACKDROP.
#   * NOT the geometry the compositor grants. /dev/wsys/<wid>/ctl reports the
#     backdrop as 0 0 1920 1200 in the broken run -- it got exactly what it
#     asked for and then only 1080 rows of it were rendered.
#
# THE CAUSE: lib/hamui_host.ad, the scene rasterizer user/wsysd.ad renders
# every window through, carried HOST_MAX_W/HOST_MAX_H = 1920x1080 -- a THIRD
# copy of a ceiling whose other two copies (BB_W/BB_H in user/linux-wsys.c and
# COMP_W/COMP_H in user/wsysd.ad) had already been raised to 2560x1600 when his
# panel stopped the machine booting the day before. paint_window calls
# hamui_host_begin_into(composite, 1920, 1200); 1200 > HOST_MAX_H so it refuses
# (correctly -- vk2d has no pitch) and falls back to hamui_host_begin, which
# CLAMPED the height to 1080 and returned success.
#
# AND NOTHING SAID SO. report_uncovered() exists precisely to catch "a band of
# rows with no paint at all" -- and it measures coverage against
# hamui_host_height(), which is the CLAMPED height, so it saw a 1920x1080
# window perfectly covered. The instrument was blinded by the constant it was
# built to police. wsysd's log for the broken run contains no warning of any
# kind. That is why this gate asserts the NOISE as well as the pixels.
#
# WHAT IS MEASURED
# ================
#   1. RED, AND RED BY CONSTRUCTION. A wsysd linked against lib/hamui_host.ad
#      AS IT WAS at $RED_REV (HOST_MAX_H 1080), run at 1920x1200, must leave
#      the rows just above the bottom panel unpainted. If this arm ever goes
#      green this gate has stopped measuring his bug and arm 2 proves nothing.
#   2. GREEN. The current tree, same geometry: those same rows carry the
#      backdrop, asserted from PIXELS as a continuation of the gradient above
#      them -- not merely "not black", because the broken band is #1c1c1c and
#      #1c1c1c is not black either. That distinction is why the first probe
#      written for this bug reported the screen 100% painted.
#   3. THE BAND IS WHERE THE MEASUREMENT SAID IT IS. In the red run the first
#      unpainted row is exactly 1080 -- the constant -- and not "somewhere near
#      the bottom".
#   4. THE CEILINGS AGREE. HOST_MAX_W/HOST_MAX_H, COMP_W/COMP_H and BB_W/BB_H
#      are one rectangle in three files, checked in the SOURCE, and wsysd
#      reconciles the first two at runtime.
#   5. A RECURRENCE ANNOUNCES ITSELF. Against a rasterizer deliberately built
#      with a too-small ceiling, the CURRENT wsysd must print, at startup, that
#      the rasterizer's ceiling and its composite buffer have drifted, and, per
#      window, that the window asked for one size and got another -- naming
#      BOTH rectangles, the way the compositor's startup refusal already does.
#      This is the arm that would have turned this bug into a log line.
#   6. THE CONTROL: at 1280x800 -- under every ceiling discussed here -- there
#      is no band, before or after. A gate that could not tell the two
#      geometries apart would not be measuring a ceiling.
#
# Entirely offscreen: HAMFB_FILE, no VM, no display, no DRM master. The
# software Vulkan ICD is forced because this host's GPU belongs to someone.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

# The desktop stack writes FIXED, HOST-GLOBAL names (/dev/wsys, /srv/wsys,
# /tmp/hamnix-wsysd.fault) whatever this script does about $WORK. Inside the
# namespace this call establishes, /tmp, /dev/shm and /srv are this run's alone.
# It execs and does not return.
. tests/linux/private_ns.sh
priv_ns_reexec "$@"

WORK="${BACKDROP_WORK:-$(mktemp -d -p "${TMPDIR:-/tmp}" backdrop.XXXXXX)}"
mkdir -p "$WORK"
KEEP="${BACKDROP_KEEP:-0}"

# HIS PANEL, and it is the default rather than an override nobody passes.
GEOM="${HAMFB_GEOM:-1920x1200}"
FBW="${GEOM%x*}"; FBH="${GEOM#*x}"

# The control geometry: below every ceiling in this story.
SMALL_GEOM="${BACKDROP_SMALL_GEOM:-1280x800}"

# The commit the fix landed on top of: the red arm's lib/hamui_host.ad.
RED_REV="${BACKDROP_RED_REV:-25405a59}"

# The three copies of the one ceiling, read from the sources rather than
# retyped here -- a gate with its own fourth copy would be the defect it tests.
CEIL_W="$(sed -n 's/^#define BB_W  *\([0-9][0-9]*\).*/\1/p' user/linux-wsys.c | head -1)"
CEIL_H="$(sed -n 's/^#define BB_H  *\([0-9][0-9]*\).*/\1/p' user/linux-wsys.c | head -1)"
COMP_W="$(sed -n 's/^COMP_W: int32 = \([0-9][0-9]*\).*/\1/p' user/wsysd.ad | head -1)"
COMP_H="$(sed -n 's/^COMP_H: int32 = \([0-9][0-9]*\).*/\1/p' user/wsysd.ad | head -1)"
HOST_W_MAX="$(sed -n 's/^HOST_MAX_W: uint64 = \([0-9][0-9]*\).*/\1/p' lib/hamui_host.ad | head -1)"
HOST_H_MAX="$(sed -n 's/^HOST_MAX_H: uint64 = \([0-9][0-9]*\).*/\1/p' lib/hamui_host.ad | head -1)"

[ -r /usr/share/vulkan/icd.d/lvp_icd.json ] && \
    export VK_ICD_FILENAMES="${VK_ICD_FILENAMES:-/usr/share/vulkan/icd.d/lvp_icd.json}"

pass=0; fail=0
ok()   { echo "backdrop: PASS $*"; pass=$((pass+1)); }
bad()  { echo "backdrop: FAIL $*"; fail=$((fail+1)); }
info() { echo "backdrop: INFO $*"; }
done_report() { echo "backdrop: $pass passed, $fail failed"; [ "$fail" = 0 ]; }

. tests/linux/reap.sh
reap_track "$WORK/reaped"
cleanup() { reap_all; [ "$KEEP" = 1 ] || rm -rf "$WORK"; }
reap_on_exit cleanup

# ---- pixel arithmetic -----------------------------------------------------
# WHAT "PAINTED" HAS TO MEAN HERE, and the first version of this gate got it
# wrong in a way worth recording. The band the owner calls black is #1c1c1c
# (the compositor's clear colour) at 1920x1200 and #203348 at 1920x1300 --
# NEITHER IS (0,0,0). A "not black" test reported the broken screen 100%
# painted, twice, with the bar plainly visible in a screenshot beside it.
#
# So the assertion is that the band is the BACKDROP: hamdesktop's procedural
# wallpaper is a blue vertical gradient that gets LIGHTER downward, so its
# bottom rows are strongly blue-dominant and bright. Two independent
# properties, because either alone is weaker than it looks:
#   - HUE: B > G > R and B at least $BLUE_MIN. #1c1c1c has no dominant channel
#     at all; #203348 is blue-dominant but far too dark.
#   - CONTINUITY: the band's mean blue is at least as high as a reference band
#     200 rows above it. The gradient only brightens downward, so a band that
#     is the backdrop passes and a band that is the clear colour cannot.
BLUE_MIN="${BACKDROP_BLUE_MIN:-96}"
BAND_PY="$WORK/band.py"
cat >"$BAND_PY" <<'PY'
import sys
# band.py <W> <H> <y0> <rows> <bluemin> <fb>
#   prints: "<pct-backdrop-hue> <mean-blue-band> <mean-blue-reference>"
W, H, y0, rows, bmin = (int(v) for v in sys.argv[1:6])
path = sys.argv[6]
d = open(path, 'rb').read()
def scan(a, n):
    tot = hit = acc = 0
    for j in range(a, min(a + n, H)):
        o = j * W * 4
        # Skip the outer 40 columns: desktop icons live at the left edge and a
        # taskbar button could reach the right. The middle of the screen is
        # bare backdrop by construction.
        for i in range(40, W - 40, 4):
            p = o + i * 4
            if p + 3 > len(d):
                continue
            b, g, r = d[p], d[p+1], d[p+2]
            tot += 1
            acc += b
            if b > g and g > r and b >= bmin:
                hit += 1
    if tot == 0:
        return 0, 0
    return hit * 100 // tot, acc // tot
pct, mb = scan(y0, rows)
ref_y = y0 - 200
if ref_y < 0:
    ref_y = 0
_, rb = scan(ref_y, rows)
print(pct, mb, rb)
PY
# THE FIRST ROW THAT IS NOT THE BACKDROP, searched downward from `frm`. This is
# what turns "there is a bar" into "the bar starts at 1080".
#
# THE CRITERION IS MONOTONICITY, not a colour. hamdesktop's gradient brightens
# from top to bottom and never darkens, so a row that is DARKER than the first
# row of the scan is not part of it. That is what distinguishes the backdrop
# from the compositor's clear colour WITHOUT this file knowing what either one
# is -- and it has to, because the clear colour is #1c1c1c at 1920x1200 and
# #203348 at 1920x1300 and the second of those is blue-dominant. A fixed hue
# threshold caught one and not the other; a fixed brightness threshold called
# the DARK TOP of the gradient a bar. `bmin` here is a tolerance for dithering
# between adjacent bands, not a colour.
FIRSTBAD_PY="$WORK/firstbad.py"
cat >"$FIRSTBAD_PY" <<'PY'
import sys
W, H, frm, to, tol = (int(v) for v in sys.argv[1:6])
path = sys.argv[6]
d = open(path, 'rb').read()
def meanblue(j):
    o = j * W * 4
    acc = n = 0
    # The outer 40 columns hold desktop icons and taskbar buttons.
    for i in range(40, W - 40, 8):
        p = o + i * 4
        if p + 3 > len(d):
            continue
        acc += d[p]; n += 1
    return -1 if n == 0 else acc // n
base = meanblue(frm)
ans = -1
for j in range(frm + 1, min(to, H)):
    if meanblue(j) < base - tol:
        ans = j
        break
print(ans)
PY
bandinfo() { python3 "$BAND_PY" "$1" "$2" "$3" "$4" "$BLUE_MIN" "$5"; }
FIRSTBAD_TOL="${BACKDROP_FIRSTBAD_TOL:-6}"
firstbad() { python3 "$FIRSTBAD_PY" "$1" "$2" "$3" "$4" "$FIRSTBAD_TOL" "$5"; }

# ---- build ----------------------------------------------------------------
build() {   # build <src> <outname>
    scripts/hamlinux_build.sh "$1" "$WORK/$2.elf" >"$WORK/$2.build.log" 2>&1 || {
        bad "could not build $1"; tail -20 "$WORK/$2.build.log" >&2
        done_report; exit 1; }
}
for t in wsysd:user/wsysd.ad \
         hamdesktop:user/hamdesktop.ad \
         hampanelscene:user/hampanelscene.ad \
         wsys_poke:tests/linux/wsys_poke.ad; do
    build "${t#*:}" "${t%%:*}"
done
ok "the compositor, the desktop, the panel and the probe client all build"

# A wsysd LINKED AGAINST DIFFERENT SOURCES, WITHOUT TOUCHING THE REPOSITORY.
#
# `from lib.hamui_host import ...` resolves against the PROJECT ROOT, and
# scripts/hamlinux_build.sh derives that root from its OWN location -- so a
# tree of symlinks with a few real files in it builds a wsysd that differs from
# this tree's in exactly those files and nothing else. Only the DIRECTORIES
# that contain a replacement are materialised; everything else, build/ and its
# bootstrapped host_ac.elf included, is one symlink.
#
#   shadow_build <outname> <relpath> <srcfile> [<relpath> <srcfile> ...]
shadow_build() {
    local name="$1"; shift
    local sh="$WORK/shadow_$name"
    rm -rf "$sh"; mkdir -p "$sh"
    # Which top-level directories need to be real?
    local dirs="" rel src e d base
    local -a rels=() srcs=()
    while [ $# -ge 2 ]; do
        rels+=("$1"); srcs+=("$2")
        d="${1%%/*}"
        case " $dirs " in *" $d "*) ;; *) dirs="$dirs $d" ;; esac
        shift 2
    done
    for e in "$PROJ_ROOT"/*; do
        base="$(basename "$e")"
        case " $dirs " in *" $base "*) continue ;; esac
        ln -s "$e" "$sh/$base"
    done
    for d in $dirs; do
        mkdir -p "$sh/$d"
        for e in "$PROJ_ROOT/$d"/*; do
            ln -s "$e" "$sh/$d/$(basename "$e")"
        done
    done
    local i=0
    while [ "$i" -lt "${#rels[@]}" ]; do
        rm -f "$sh/${rels[$i]}"
        cp "${srcs[$i]}" "$sh/${rels[$i]}"
        i=$((i+1))
    done
    "$sh/scripts/hamlinux_build.sh" user/wsysd.ad "$WORK/$name.elf" \
        >"$WORK/$name.build.log" 2>&1 || {
        bad "could not build the $name compositor -- this arm cannot be a controlled measurement"
        tail -20 "$WORK/$name.build.log" >&2; return 1; }
    return 0
}

# THE RED ARM'S SOURCES: lib/hamui_host.ad AND user/wsysd.ad as they were
# before the fix. Both, because they are one commit: the rasterizer at $RED_REV
# does not export the accessors the current compositor calls, and a red arm
# assembled from halves of two trees would not be the tree he ran.
mkdir -p "$WORK/redsrc"
for f in lib/hamui_host.ad user/wsysd.ad; do
    if ! git show "$RED_REV:$f" >"$WORK/redsrc/$(basename "$f")" 2>"$WORK/redsrc/git.log"; then
        bad "could not retrieve $f at $RED_REV -- the red arm cannot be built, so nothing below is a controlled measurement"
        cat "$WORK/redsrc/git.log" >&2; done_report; exit 1
    fi
done
RED_H="$(sed -n 's/^HOST_MAX_H: uint64 = \([0-9][0-9]*\).*/\1/p' "$WORK/redsrc/hamui_host.ad" | head -1)"
if [ "$RED_H" = 1080 ]; then
    ok "arm 1: the red arm's rasterizer is the pre-fix one: HOST_MAX_H 1080, against a ${FBH}-row screen"
else
    bad "arm 1: lib/hamui_host.ad at $RED_REV has HOST_MAX_H '$RED_H', not 1080 -- $RED_REV is not the commit this bug lived on, so the red arm is not his bug"
    done_report; exit 1
fi
shadow_build wsysd_red lib/hamui_host.ad "$WORK/redsrc/hamui_host.ad" \
                       user/wsysd.ad     "$WORK/redsrc/wsysd.ad" \
    || { done_report; exit 1; }

# ---- how a desktop is started ---------------------------------------------
# One helper, so the red and green arms differ in exactly one thing: the ELF.
# "STARTED" is "the process is still alive after a settle": read_screen() reads
# /dev/fb to learn the geometry and THAT is what creates and sizes the
# offscreen framebuffer, so a compositor that refuses still leaves a
# perfectly-sized fb.raw behind. Its existence proves nothing.
run_desktop() {   # run_desktop <wsysd-elf> <dir> <geom>
    local elf="$1" d="$2" geom="$3"
    rm -rf "$d"; mkdir -p "$d"
    : >"$d/input.evdev"
    rm -f /tmp/hamnix-wsysd.fault
    export HAMWSYS="$d/wsys.shm" HAMWSYS_BB="$d/wsys.bb" HAMWSYS_IMG="$d/wsys.img" \
           HAMFB_FILE="$d/fb.raw" HAMFB_GEOM="$geom" HAMWSYSD_INPUT="$d/input.evdev"
    "$elf" </dev/null >"$d/wsysd.log" 2>&1 &
    local p=$!; reap_add "$p"
    local i=0
    while [ "$i" -lt 300 ]; do
        kill -0 "$p" 2>/dev/null || return 1
        [ -s "$d/fb.raw" ] && break
        sleep 0.1; i=$((i+1))
    done
    sleep 3
    kill -0 "$p" 2>/dev/null || return 1
    "$WORK/hamdesktop.elf" </dev/null >"$d/hamdesktop.log" 2>&1 &
    reap_add $!
    sleep 5
    "$WORK/hampanelscene.elf" </dev/null >"$d/hampanelscene.log" 2>&1 &
    reap_add $!
    sleep 6
    cp "$d/fb.raw" "$d/shot.raw"
    return 0
}
# The bottom panel's y, from the DEVICE rather than from a constant in this
# file: "just above the bottom panel" is where the owner pointed, and
# PANEL_BOT_H living in user/hamdesktop.ad is exactly the kind of number a gate
# must not keep its own copy of.
panel_top() {   # panel_top <dir> <w> <h>
    local d="$1" w="$2" h="$3" wid line best=""
    for wid in $(seq 2 40); do
        line="$( ( export HAMWSYS="$d/wsys.shm" HAMWSYS_BB="$d/wsys.bb" \
                          HAMWSYS_IMG="$d/wsys.img" HAMFB_FILE="$d/fb.raw"
                   "$WORK/wsys_poke.elf" "/dev/wsys/$wid/ctl" 2>/dev/null ) )"
        [ -n "$line" ] || continue
        set -- $line
        [ "${4:-}" = "$w" ] || continue                       # full width
        [ "${5:-0}" -ge $((h - 40)) ] && continue             # the backdrop
        [ "${3:-0}" = "0" ] && continue                       # the top bar
        best="${3:-0}"
    done
    echo "${best:-0}"
}

# ===========================================================================
# ARM 1 -- RED. HIS BAR, REPRODUCED, BEFORE ANYTHING ELSE IS BELIEVED.
# ===========================================================================
info "arm 1 (red): a wsysd whose rasterizer ceiling is 1920x1080, at ${FBW}x${FBH}"
if ! run_desktop "$WORK/wsysd_red.elf" "$WORK/red" "$GEOM"; then
    bad "arm 1: the pre-fix desktop did not come up at all -- this gate is not reproducing the reported bug"
    sed 's/^/backdrop:      /' "$WORK/red/wsysd.log"
    done_report; exit 1
fi
RPT="$(panel_top "$WORK/red" "$FBW" "$FBH")"
if [ "$RPT" -gt 0 ]; then
    ok "arm 1: the bottom panel is at y=$RPT, read from /dev/wsys -- 'just above the bottom panel' is rows $((RPT - 24))..$((RPT - 1))"
else
    bad "arm 1: no full-width bottom panel found; 'just above the bottom panel' cannot be located"
    done_report; exit 1
fi
read -r RPCT RMB RRB <<<"$(bandinfo "$FBW" "$FBH" $((RPT - 24)) 24 "$WORK/red/shot.raw")"
if [ "$RPCT" -lt 10 ]; then
    ok "arm 1: HIS BAR. Only $RPCT% of the 24 rows above the panel carry the backdrop (mean blue $RMB, against $RRB two hundred rows higher) -- the background does not reach the bottom of a ${FBH}-row screen"
else
    bad "arm 1: the pre-fix rasterizer painted the bottom of the screen anyway ($RPCT%) -- this gate is NOT reproducing his bug and arm 2 proves nothing"
    done_report; exit 1
fi
# ARM 3, TAKEN HERE BECAUSE THE BROKEN SCREEN IS THE ONLY PLACE IT EXISTS.
RFB="$(firstbad "$FBW" "$FBH" 200 "$RPT" "$WORK/red/shot.raw")"
if [ "$RFB" = "$RED_H" ]; then
    ok "arm 3: the band begins at EXACTLY y=$RFB, which is HOST_MAX_H and not a fraction of the screen -- the bar is a constant, not arithmetic"
else
    bad "arm 3: the band begins at y=$RFB, but the pre-fix ceiling is $RED_H; the bar this gate reproduces is not the one that was diagnosed"
fi
if grep -qi 'clamp\|drifted\|rasterizer' "$WORK/red/wsysd.log"; then
    info "arm 1: the pre-fix compositor said something about it (unexpected, but harmless): $(grep -im1 'clamp\|drifted\|rasterizer' "$WORK/red/wsysd.log")"
else
    ok "arm 1: and it was SILENT about it -- not one line in the compositor log for $((RPT - RFB)) unpainted rows, which is why arm 5 exists"
fi
reap_all; sleep 0.5

# ===========================================================================
# ARM 2 -- GREEN. THE CURRENT TREE, SAME GEOMETRY, SAME ASSERTION.
# ===========================================================================
info "arm 2 (green): the current tree at ${FBW}x${FBH}"
if ! run_desktop "$WORK/wsysd.elf" "$WORK/g" "$GEOM"; then
    bad "arm 2: the current desktop did not come up at ${FBW}x${FBH}"
    sed 's/^/backdrop:      /' "$WORK/g/wsysd.log"
    done_report; exit 1
fi
PT="$(panel_top "$WORK/g" "$FBW" "$FBH")"
if [ "$PT" -gt 0 ]; then
    ok "arm 2: the bottom panel is at y=$PT"
else
    bad "arm 2: no full-width bottom panel"; done_report; exit 1
fi
read -r GPCT GMB GRB <<<"$(bandinfo "$FBW" "$FBH" $((PT - 24)) 24 "$WORK/g/shot.raw")"
if [ "$GPCT" -ge 95 ]; then
    ok "arm 2: THE BACKDROP REACHES THE BOTTOM PANEL. $GPCT% of rows $((PT - 24))..$((PT - 1)) carry the backdrop's hue -- the rows the black bar occupied"
else
    bad "arm 2: only $GPCT% of the 24 rows above the panel carry the backdrop -- the black bar is still there"
fi
if [ "$GMB" -ge "$GRB" ]; then
    ok "arm 2: and it is a CONTINUATION of the gradient, not a patch: mean blue $GMB at the bottom against $GRB two hundred rows above, and this gradient only brightens downward"
else
    bad "arm 2: the band above the panel is DARKER (mean blue $GMB) than the backdrop 200 rows above it ($GRB) -- something other than the wallpaper is on those rows"
fi
# THE VERY LAST ROW, because a fix that covers 23 of 24 rows is the same class
# of bug as one that covers 1080 of 1200.
LFB="$(firstbad "$FBW" "$FBH" 200 "$PT" "$WORK/g/shot.raw")"
if [ "$LFB" = "-1" ]; then
    ok "arm 2: EVERY row from y=200 down to the panel at y=$PT is backdrop -- there is no band anywhere, not merely none where it used to be"
else
    bad "arm 2: the first non-backdrop row above the panel is y=$LFB"
fi
if grep -qi 'drifted apart\|asked to be rasterized' "$WORK/g/wsysd.log"; then
    bad "arm 2: the current compositor is REPORTING a clamp or a drift on his panel -- \"$(grep -im1 'drifted apart\|asked to be rasterized' "$WORK/g/wsysd.log")\""
else
    ok "arm 2: and the compositor reports no clamp and no ceiling drift at ${FBW}x${FBH}"
fi
reap_all; sleep 0.5

# ===========================================================================
# ARM 4 -- ONE RECTANGLE, THREE FILES.
# ===========================================================================
if [ "$CEIL_W" = "$COMP_W" ] && [ "$CEIL_H" = "$COMP_H" ]; then
    ok "arm 4: BB_W x BB_H (${CEIL_W}x${CEIL_H}, user/linux-wsys.c) and COMP_W x COMP_H (${COMP_W}x${COMP_H}, user/wsysd.ad) agree"
else
    bad "arm 4: the composite ceilings DISAGREE: ${CEIL_W}x${CEIL_H} vs ${COMP_W}x${COMP_H}"
fi
if [ "$HOST_W_MAX" -ge "$COMP_W" ] && [ "$HOST_H_MAX" -ge "$COMP_H" ]; then
    ok "arm 4: the rasterizer's ceiling (HOST_MAX ${HOST_W_MAX}x${HOST_H_MAX}, lib/hamui_host.ad) covers the composite buffer ${COMP_W}x${COMP_H} -- the drift that made the bar cannot be reintroduced silently"
else
    bad "arm 4: the rasterizer can only render ${HOST_W_MAX}x${HOST_H_MAX} but the composite buffer is ${COMP_W}x${COMP_H} -- this is EXACTLY the drift that put a black bar on his desktop"
fi

# ===========================================================================
# ARM 5 -- A RECURRENCE ANNOUNCES ITSELF.
# ===========================================================================
# The current wsysd, linked against a rasterizer whose ceiling has been shrunk
# back under the screen -- but which carries the CURRENT instrumentation. The
# pixels would be wrong again; the point of this arm is that the LOG would not
# be empty this time. Shrunk by rewriting the constants only, so everything
# else about the module is the tree's.
mkdir -p "$WORK/lowsrc"
sed -e 's/^HOST_MAX_W: uint64 = .*/HOST_MAX_W: uint64 = 1920/' \
    -e 's/^HOST_MAX_H: uint64 = .*/HOST_MAX_H: uint64 = 1080/' \
    lib/hamui_host.ad >"$WORK/lowsrc/hamui_host.ad"
LOW_OK=0
if grep -q '^HOST_MAX_H: uint64 = 1080' "$WORK/lowsrc/hamui_host.ad" \
   && grep -q 'host_req_h' "$WORK/lowsrc/hamui_host.ad"; then
    ok "arm 5: built a rasterizer with the OLD ceiling and the NEW instrumentation -- the pixels of the bug, with the reporting the fix added"
    LOW_OK=1
else
    # DOES NOT EXIT. On a tree without the fix there IS no instrumentation to
    # shrink, so this arm cannot be constructed -- and arm 6, the control that
    # proves the bar is height-dependent, still has something to say. An arm
    # that cannot be built is a FAIL, not a reason to stop measuring.
    bad "arm 5: could not construct the shrunk-but-instrumented rasterizer -- lib/hamui_host.ad does not record the pre-clamp size (host_req_h), so a clamp is still unobservable from outside it"
fi
if [ "$LOW_OK" = 1 ] && shadow_build wsysd_low lib/hamui_host.ad "$WORK/lowsrc/hamui_host.ad"; then
    if run_desktop "$WORK/wsysd_low.elf" "$WORK/low" "$GEOM"; then
        LOG="$WORK/low/wsysd.log"
        if grep -q 'drifted apart' "$LOG" && grep -q "1920x1080" "$LOG" \
           && grep -q "${COMP_W}x${COMP_H}" "$LOG"; then
            ok "arm 5: at STARTUP it names both rectangles -- \"$(grep -m1 'drifted apart' "$LOG" | cut -c1-160)...\""
        else
            bad "arm 5: startup said nothing about the rasterizer ceiling being under the composite buffer"
            grep -i 'wsysd:' "$LOG" | head -5 | sed 's/^/backdrop:      /'
        fi
        if grep -q 'asked to be rasterized at' "$LOG"; then
            ok "arm 5: and PER WINDOW it says what was asked for and what was produced -- \"$(grep -m1 'asked to be rasterized at' "$LOG" | cut -c1-160)...\""
        else
            bad "arm 5: no per-window clamp report; a rasterize that silently produced less than the screen is still silent"
            grep -i 'wsysd:' "$LOG" | head -5 | sed 's/^/backdrop:      /'
        fi
        if grep -q "${FBW}x${FBH}" "$LOG"; then
            ok "arm 5: and the report names the size the window ASKED for (${FBW}x${FBH}), which is the number nothing downstream of the clamp still knows"
        else
            bad "arm 5: the report does not name the requested ${FBW}x${FBH}"
        fi
    else
        bad "arm 5: the shrunk-ceiling compositor did not come up, so its reporting is unmeasured"
    fi
    reap_all; sleep 0.5
fi

# ===========================================================================
# ARM 6 -- THE CONTROL. A SCREEN UNDER EVERY CEILING HAS NO BAND EITHER WAY.
# ===========================================================================
SW="${SMALL_GEOM%x*}"; SH="${SMALL_GEOM#*x}"
info "arm 6 (control): the PRE-FIX rasterizer at $SMALL_GEOM, which fits under 1920x1080"
if run_desktop "$WORK/wsysd_red.elf" "$WORK/small" "$SMALL_GEOM"; then
    SPT="$(panel_top "$WORK/small" "$SW" "$SH")"
    if [ "$SPT" -gt 0 ]; then
        read -r SPCT SMB SRB <<<"$(bandinfo "$SW" "$SH" $((SPT - 24)) 24 "$WORK/small/shot.raw")"
        if [ "$SPCT" -ge 95 ]; then
            ok "arm 6: at $SMALL_GEOM the SAME pre-fix binary paints the bottom ($SPCT%) -- the bar is height-dependent, measured rather than assumed, and every wsys gate that runs at 1280x800 was green on the day his desktop had the bar"
        else
            bad "arm 6: the pre-fix rasterizer leaves a band at $SMALL_GEOM too ($SPCT%) -- then the cause is not the 1080 ceiling and the diagnosis above is wrong"
        fi
    else
        bad "arm 6: no bottom panel at $SMALL_GEOM"
    fi
else
    bad "arm 6: the desktop did not come up at $SMALL_GEOM"
fi
reap_all

# ---- what this cannot tell us ---------------------------------------------
info "NOT MEASURED HERE: real hardware. Every framebuffer above is HAMFB_FILE, so his fbdev driver, his panel's pitch and the DRM/scanout path are untested -- this gate never takes DRM master. Nor is the IMAGE-wallpaper path measured: these runs have no wallpaper set and take hamdesktop's procedural gradient, which is what makes the hue assertion possible. A wallpaper image goes through the compositor's scaled blit and would need its own colour model."

done_report
