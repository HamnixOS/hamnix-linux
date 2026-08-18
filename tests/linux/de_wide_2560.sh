#!/usr/bin/env bash
#
# REGISTRATION, 2026-08-17. This gate is ON-DEMAND, and the runtime below is
# MEASURED rather than estimated, in both of the states it can be run in.
#
# Not in ci_battery_manifest.txt because its cost is dominated by compiling
# three compositors, and the two figures are far apart: 77 s end to end
# (17:29:58 -> 17:31:15, 22 PASS / 0 FAIL, while a QEMU soak was also running
# on this host) with build/obj already warm, against several minutes on the
# first run of the day when user/wsysd.ad and its two shadow variants had to be
# compiled from cold. The battery is 12-way sharded under a 50-minute cap and
# has no warm-cache guarantee, so the number that would apply there is the
# second one. tests/linux/de_backdrop_bottom.sh -- the same shape of gate, the
# same shadow-build machinery -- is on-demand for the same reason.
#
# It takes no display and no DRM master.
#
# tests/linux/de_wide_2560.sh -- DOES THE WHOLE DESKTOP PAINT THE WHOLE WIDTH
# OF THE OWNER'S 2560x1600 PANEL? BACKDROP, PANELS, AND A WINDOW THAT STRADDLES
# BOTH OF THE OLD CEILINGS.
#
# WHY THIS FILE EXISTS
# ====================
# Six ceilings in this stack have now been found by the same accident: a
# constant that was right for the panel it was picked for, that CLAMPED rather
# than refused when the panel changed, and that therefore reported success while
# painting less than the screen.
#
#     1920x1080  BB_W/BB_H            user/linux-wsys.c    (refused to start)
#     1920x1080  COMP_W/COMP_H        user/wsysd.ad
#     1920x1080  HOST_MAX_W/H         lib/hamui_host.ad    (the black bar)
#     1280x800   HAMUI_V2_BB_MAX_W/H  lib/hamui.ad
#     8192 B     ROWBUF_CAP           user/wsyswl.ad       (2048 columns)
#     7680 B     BBROW_CAP            user/wsysd.ad        (1920 columns)
#
# THE SIXTH WAS FOUND ONLY BECAUSE FIXING THE FIFTH MADE THE CASE
# CONSTRUCTIBLE. One ceiling was hiding the next, and that is the reason for
# this file: the assumption here is that a SEVENTH exists until the full width
# has been looked at end to end, on a screen that size, through the components
# a person actually sees.
#
# WHAT NO EXISTING GATE COVERED, and it is why this is a new file rather than a
# geometry argument to an old one:
#
#   * tests/linux/de_backdrop_bottom.sh drives the real desktop -- backdrop and
#     both panels -- but at 1920x1200, and it asks about the HEIGHT axis. Its
#     control geometry is 1280x800. Nothing in it is over 1920 columns wide.
#   * tests/linux/wsyswl_wide_window.sh and wsyswl_wide_native.sh do go past
#     1920 columns, but their client is Xwayland / a native Wayland client
#     through user/wsyswl.ad. Neither runs hamdesktop or hampanelscene, so
#     neither says anything about the backdrop or the panels.
#   * tests/linux/hamui_v2_ceiling.sh drives the v2 blit path through the
#     toolkit, but on a 1280x800 framebuffer with the window at the ORIGIN.
#
# So "the compositor, the desktop, the panel and a toolkit application all at
# 2560x1600 at once" had never been run.
#
# WHY A WINDOW AT THE ORIGIN CANNOT ANSWER THIS, and it is the reason
# tests/linux/hamui_v2_ceiling.ad grew an optional origin for this file. A
# window at 0,0 that is truncated at column 1920 looks identical whether the cut
# is at 1920 COLUMNS OF THAT WINDOW or at COLUMN 1920 OF THE SCREEN. A window
# placed at x=400 and 2100 columns wide separates them: it is past 1920 in its
# own right AND it crosses screen columns 1920 and 2048, so a per-window cut
# lands at column 2319 and a per-screen cut lands at column 1919. Those are
# different numbers and this gate asserts on which one it gets.
#
# THAT DISTINCTION IS NOT DECORATIVE -- IT IS WHAT THE FIRST RUN OF THIS FILE
# MEASURED. The straddler was 800 columns wide at x=1700 to begin with, and the
# BBROW_CAP mutant painted all 800 of them: 800*4 is 3200 bytes, nowhere near
# 7680, so that ceiling never came near it. The negative control came up GREEN
# and said so, which is the only reason the gate is not shipping an assertion
# about the screen that is really an assertion about nothing. THE SIXTH CEILING
# CUTS BY THE WINDOW'S WIDTH, NOT BY THE SCREEN'S COLUMN, and no window narrower
# than 1921 columns can ever meet it wherever it sits.
#
# WHAT IS ASSERTED, AND EVERY ONE OF THEM IS PIXELS
# =================================================
# Geometry granted is NOT geometry painted. That distinction is the entire
# lesson of the black bar: /dev/wsys reported the backdrop as 0 0 1920 1200 in
# the broken run, "it got exactly what it asked for and then only 1080 rows of
# it were rendered". So each of these reads the framebuffer, and the geometry
# readings are context printed beside them rather than the assertion.
#
#   1. THE BACKDROP reaches the right edge: the rightmost columns of the screen
#      carry hamdesktop's gradient, and the FIRST column that does not is
#      located rather than merely counted.
#   2. THE PANELS are full width in the window table AND THE WALLPAPER DOES NOT
#      SHOW THROUGH THEM at column 2500 -- compared pixel for pixel against the
#      bare wallpaper on a reference row just above the panel, because the
#      taskbar carries a 22-pixel blue widget near its right end that a hue test
#      cannot tell from the blue gradient, and the first version of this arm
#      duly called the panel truncated because of it.
#   3. A WINDOW AS WIDE AS THE SCREEN -- the maximised case -- paints out to
#      the last column, 2559, and is measured on rows no other probe occupies.
#   4. A WINDOW STRADDLING COLUMN 1920 AND COLUMN 2048 paints continuously
#      across both, and its right edge is where it asked for it. Sampled ON the
#      boundary columns, not near them.
#
# THE NEGATIVE CONTROLS ARE RUN, AND THERE ARE TWO, BECAUSE THERE ARE TWO
# MECHANISMS
# ==========================================================================
# A single mutant would make every assertion above go red together, which
# proves only that the gate can see A failure -- not that assertion 1 is
# pointed at the backdrop and assertion 4 at the blit path. Each mutant must
# turn its own assertions red AND LEAVE THE OTHERS GREEN.
#
#   MUTANT A -- the sixth ceiling put back. user/wsysd.ad's paint_backbuffer
#     with `rowbytes` clamped to BBROW_CAP = 7680 again, which is the code that
#     shipped before baacdc64. The full-width window must truncate at column
#     1919 and the straddler at column 2319 -- 400 + 1920, i.e. 1920 columns of
#     ITS OWN width -- and the two numbers being different is what identifies
#     the ceiling as per-window rather than per-screen. Backdrop and panels must
#     be UNAFFECTED, because they are scene windows and paint_backbuffer is not
#     on their path; a mutant that broke everything would prove only that this
#     gate can see a failure, not that each arm sees its own.
#   MUTANT B -- the third ceiling put back, on the WIDTH axis this time.
#     lib/hamui_host.ad with HOST_MAX_W = 1920. The scene rasterizer every
#     window is drawn through can then only produce 1920 columns, so the
#     backdrop must stop; this is de_backdrop_bottom.sh's bug rotated ninety
#     degrees, and nothing in the tree had asked it on this axis.
#
# A mutant that comes up green is reported as a FAILURE OF THIS GATE, not as
# good news: it means the assertion it was built to break cannot be broken.
#
# WHAT THIS CANNOT TELL YOU, said here rather than discovered later:
#   * REAL HARDWARE. Every framebuffer here is HAMFB_FILE. The owner's fbdev
#     driver, his panel's pitch and the DRM scanout path are untested, and this
#     gate never takes DRM master.
#   * FRAME TIMING. Nothing here is a rate. See tests/linux/de_fps_*.sh.
#   * THE WAYLAND/X PATH at this width -- that is wsyswl_wide_native.sh.
#
# Env: HAMFB_GEOM (default 2560x1600), WIDE2560_WORK, WIDE2560_KEEP=1
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

# The desktop stack writes FIXED, HOST-GLOBAL names (/dev/wsys, /srv/wsys,
# /tmp/hamnix-wsysd.fault) whatever this script does about $WORK. Inside the
# namespace this call establishes, /tmp, /dev/shm and /srv are this run's alone.
# It execs and does not return.
. tests/linux/private_ns.sh
priv_ns_reexec "$@"

WORK="${WIDE2560_WORK:-$(mktemp -d -p "${TMPDIR:-/tmp}" wide2560.XXXXXX)}"
mkdir -p "$WORK"
KEEP="${WIDE2560_KEEP:-0}"

GEOM="${HAMFB_GEOM:-2560x1600}"
FBW="${GEOM%x*}"; FBH="${GEOM#*x}"

# THE TWO OLD CEILINGS, AS COLUMNS. Named once, used as sample points, and
# printed in every message so a failure says which one it landed on.
CEIL_A=1920           # user/wsysd.ad's BBROW_CAP / 4, and HOST_MAX_W before it
CEIL_B=2048           # user/wsyswl.ad's ROWBUF_CAP / 4

# THE FULL-WIDTH WINDOW -- the maximised case. A BAND rather than a full-height
# window, because the straddling window has to be somewhere too and two windows
# of the same colour overlapping made the first run of this gate read the
# straddler's right edge off the wrong window.
MAX_Y=40
MAX_H=160             # rows 40..199; sampled at row 100

# THE STRADDLING WINDOW, and its width is chosen as carefully as its position.
#
# 2100 COLUMNS, NOT 800. The first version of this gate placed an 800-wide
# window at x=1700 -- across both boundaries, which is what the header argues
# for -- and its negative control then came up GREEN: with BBROW_CAP clamping
# again, that window painted its whole 800 columns.
#
# THAT IS A FINDING ABOUT THE CEILING AND NOT A DEFECT IN THE CONTROL.
# BBROW_CAP bounds `rowbytes`, which is the WINDOW's width times four -- so it
# is a per-window-width ceiling, not a per-screen-column one. An 800-wide
# window is 3200 bytes a row whether it sits at column 0 or column 1700, and
# nothing cuts it. Only a window WIDER than 1920 meets that ceiling at all.
#
# So the straddler is 2100 wide at x=400: past 1920 columns in its own right,
# and crossing screen columns 1920 and 2048. That makes its cut column under
# the mutant 400 + 1920 - 1 = 2319 -- which is NOT screen column 1920, and the
# difference between those two numbers is the whole discrimination this window
# exists to make.
STRAD_X=400
STRAD_Y=300
STRAD_W=2100          # 400..2499
STRAD_H=500

[ -r /usr/share/vulkan/icd.d/lvp_icd.json ] && \
    export VK_ICD_FILENAMES="${VK_ICD_FILENAMES:-/usr/share/vulkan/icd.d/lvp_icd.json}"

pass=0; fail=0
ok()   { echo "wide2560: PASS $*"; pass=$((pass+1)); }
bad()  { echo "wide2560: FAIL $*"; fail=$((fail+1)); }
info() { echo "wide2560: INFO $*"; }
say()  { echo; echo "wide2560: == $*"; }
done_report() { echo; echo "wide2560: $pass passed, $fail failed"; [ "$fail" = 0 ]; }

. tests/linux/reap.sh
reap_track "$WORK/reaped"
cleanup() { reap_all; [ "$KEEP" = 1 ] || rm -rf "$WORK"; }
reap_on_exit cleanup

# ---- pixel arithmetic ------------------------------------------------------
# ONE helper, three questions, so the three arms cannot drift apart in what
# they mean by "painted".
#
#   px.py backdrop  <W> <H> <y0> <rows> <x0> <x1> <fb>
#       -> "<pct> <meanblue>"  the share of sampled pixels in that rectangle
#          that carry hamdesktop's gradient: blue-dominant, B > G > R, B >= 96.
#          The compositor's clear colour (#1c1c1c) has no dominant channel and
#          fails it -- which is the distinction the FIRST probe written for the
#          black bar got wrong, reporting a broken screen 100% painted.
#
#   px.py mark      <W> <H> <y0> <rows> <x0> <x1> <fb>
#       -> "<pct>"  the share that are the probe client's colour: ONE channel
#          near 220 and the other two near 40. Orientation-agnostic on purpose
#          -- /dev/fb is BGRX here and this file is not the place to relitigate
#          which end a channel is at; a colour with one saturated and two dark
#          channels cannot be confused with the backdrop or the clear.
#
#   px.py lastmark  <W> <H> <y> <x0> <x1> <fb>
#       -> "<x>"  the LAST column in [x0,x1) on row <y> that is the probe's
#          colour, or -1 if none is. This is what turns "the window is cut" into
#          "the window is cut at exactly 1920", which is the difference between
#          a symptom and a constant.
PX="$WORK/px.py"
cat >"$PX" <<'PY'
import sys
mode = sys.argv[1]
W, H = int(sys.argv[2]), int(sys.argv[3])
d = open(sys.argv[-1], 'rb').read()


def rgb(x, y):
    o = (y * W + x) * 4
    if o + 3 > len(d):
        return None
    return d[o + 2], d[o + 1], d[o]          # BGRX on disk -> (r, g, b)


def is_backdrop(p):
    # hamdesktop's procedural wallpaper is a BLUE VERTICAL gradient. Two
    # properties, and the second one had to be added after the first run of this
    # gate reported 0% for a screen whose backdrop was perfect:
    #
    #   * ORDER: b > g > r. Necessary and NOWHERE NEAR SUFFICIENT -- the bottom
    #     panel's chrome measured (242, 238, 236) here, which satisfies it, and
    #     the first version of arm 1d duly announced the panel row was 100%
    #     backdrop.
    #   * CHROMA: b - r >= 25. The gradient measured b-r from 42 at the top of a
    #     1600-row screen to 103 at the bottom; the panel's is 6 and the
    #     compositor's clear (#1c1c1c) is 0.
    #
    # AND THERE IS NO ABSOLUTE BRIGHTNESS FLOOR, deliberately. The first version
    # carried `b >= 96`, lifted from tests/linux/de_backdrop_bottom.sh, which
    # samples near the BOTTOM of a 1200-row screen. The same gradient spread
    # over 1600 rows is only b=81 at row 300 -- so that floor called a correctly
    # painted 2560x1600 backdrop 0% BACKDROP AT EVERY COLUMN, including the
    # reference band, which is what stopped it being read as a finding.
    r, g, b = p
    return b > g and g > r and (b - r) >= 25


def is_panel(p):
    # The panel chrome: light, and nearly neutral. Measured (242, 238, 236) and
    # (230, 225, 223) at the two ends of the bottom panel here.
    r, g, b = p
    return b >= 150 and (b - r) < 20


def is_mark(p):
    hi = [c for c in p if abs(c - 220) < 30]
    lo = [c for c in p if abs(c - 40) < 30]
    return len(hi) == 1 and len(lo) == 2


if mode in ('backdrop', 'mark', 'panel'):
    y0, rows, x0, x1 = (int(v) for v in sys.argv[4:8])
    test = {'backdrop': is_backdrop, 'mark': is_mark, 'panel': is_panel}[mode]
    tot = hit = acc = 0
    for y in range(y0, min(y0 + rows, H)):
        for x in range(x0, min(x1, W), 4):
            p = rgb(x, y)
            if p is None:
                continue
            tot += 1
            acc += p[2]
            if test(p):
                hit += 1
    print(0 if tot == 0 else hit * 100 // tot, 0 if tot == 0 else acc // tot)
elif mode == 'showthrough':
    # IS THE WALLPAPER SHOWING THROUGH HERE? Every pixel in the target band is
    # compared with the pixel at the SAME COLUMN on a reference row that is
    # known to be bare wallpaper, and counted if it is within <tol> of it.
    #
    # THIS EXISTS BECAUSE A HUE TEST COULD NOT ANSWER IT. The bottom panel
    # carries a 22-pixel-wide widget at (53, 132, 228) near its right end -- a
    # bright blue that satisfies b > g > r and b - r >= 25 exactly as the
    # wallpaper does -- and a hue test duly reported the panel 12% "backdrop"
    # and this gate called the panel truncated. The wallpaper under it at the
    # same columns is (51, 95, 154). They are both blue and they are not the
    # same colour, and "the same colour as the wallpaper directly above" is the
    # question that was actually being asked.
    #
    # The gradient is vertical and slow -- measured at about 0.06 units of blue
    # per row over a 1600-row screen -- so a reference row a few tens of rows
    # above the target is the same colour to within one or two units.
    refy, y0, rows, x0, x1, tol = (int(v) for v in sys.argv[4:10])
    tot = hit = 0
    for y in range(y0, min(y0 + rows, H)):
        for x in range(x0, min(x1, W)):
            a, b = rgb(x, refy), rgb(x, y)
            if a is None or b is None:
                continue
            tot += 1
            if max(abs(a[i] - b[i]) for i in range(3)) <= tol:
                hit += 1
    print(0 if tot == 0 else hit * 100 // tot, tot)
elif mode == 'lastmark':
    y, x0, x1 = (int(v) for v in sys.argv[4:7])
    ans = -1
    for x in range(x0, min(x1, W)):
        p = rgb(x, y)
        if p is not None and is_mark(p):
            ans = x
    print(ans)
else:
    raise SystemExit('px.py: unknown mode ' + mode)
PY
backdrop_pct() { python3 "$PX" backdrop "$FBW" "$FBH" "$1" "$2" "$3" "$4" "$5"; }
mark_pct()     { python3 "$PX" mark     "$FBW" "$FBH" "$1" "$2" "$3" "$4" "$5"; }
panel_pct()    { python3 "$PX" panel    "$FBW" "$FBH" "$1" "$2" "$3" "$4" "$5"; }
showthrough()  { python3 "$PX" showthrough "$FBW" "$FBH" "$1" "$2" "$3" "$4" "$5" "$6" "$7"; }
lastmark()     { python3 "$PX" lastmark "$FBW" "$FBH" "$1" "$2" "$3" "$4"; }

# ---- build -----------------------------------------------------------------
build() {   # build <src> <outname>
    scripts/hamlinux_build.sh "$1" "$WORK/$2.elf" >"$WORK/$2.build.log" 2>&1 || {
        bad "could not build $1"; tail -20 "$WORK/$2.build.log" >&2
        done_report; exit 1; }
}
say "building the compositor, the desktop, the panel and the probe"
for t in wsysd:user/wsysd.ad \
         hamdesktop:user/hamdesktop.ad \
         hampanelscene:user/hampanelscene.ad \
         wsys_poke:tests/linux/wsys_poke.ad \
         v2probe:tests/linux/hamui_v2_ceiling.ad; do
    build "${t#*:}" "${t%%:*}"
done
ok "the compositor, the desktop, the panel and the v2 probe all build"

# A wsysd LINKED AGAINST DIFFERENT SOURCES, WITHOUT TOUCHING THE REPOSITORY.
# Lifted from tests/linux/de_backdrop_bottom.sh, which is where it was proved:
# `from lib.hamui_host import ...` resolves against the PROJECT ROOT, and
# scripts/hamlinux_build.sh derives that root from its OWN location -- so a
# tree of symlinks with a few real files in it builds a wsysd that differs from
# this tree's in exactly those files and nothing else.
shadow_build() {   # shadow_build <outname> <relpath> <srcfile> [...]
    local name="$1"; shift
    local sh="$WORK/shadow_$name"
    rm -rf "$sh"; mkdir -p "$sh"
    local dirs="" e d base
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
        bad "could not build the $name compositor -- that negative control cannot be a controlled measurement"
        tail -20 "$WORK/$name.build.log" >&2; return 1; }
    return 0
}

# ---- how a desktop is started ----------------------------------------------
# One helper, so every arm differs in exactly one thing: the compositor ELF.
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
    # THE DESKTOP-ONLY FRAME: backdrop and panels, with no application window
    # over them. start_probes takes a SECOND one (shot2.raw) after the probe
    # clients are up, so the backdrop arms and the window arms are never
    # reading the same picture and cannot be confused for each other.
    cp "$d/fb.raw" "$d/shot.raw"
    return 0
}

# The window table, read through the device rather than guessed. Prints one
# "<wid> <x> <y> <w> <h>" line per window that answers.
win_table() {   # win_table <dir>
    local d="$1" wid line
    for wid in $(seq 2 48); do
        line="$( ( export HAMWSYS="$d/wsys.shm" HAMWSYS_BB="$d/wsys.bb" \
                          HAMWSYS_IMG="$d/wsys.img" HAMFB_FILE="$d/fb.raw"
                   "$WORK/wsys_poke.elf" "/dev/wsys/$wid/ctl" 2>/dev/null ) )"
        [ -n "$line" ] || continue
        set -- $line
        echo "$wid ${2:-?} ${3:-?} ${4:-?} ${5:-?}"
    done
}

# THE TWO PROBE WINDOWS, started against a running desktop and HELD OPEN while
# the framebuffer is sampled. A v2 window's content lives in the CLIENT's
# backbuffer, so a client that has exited has no pixels for the compositor to
# composite; measuring after it returns reads an empty screen and blames the
# blit for it.
start_probes() {   # start_probes <dir>
    local d="$1"
    export HAMWSYS="$d/wsys.shm" HAMWSYS_BB="$d/wsys.bb" HAMWSYS_IMG="$d/wsys.img" \
           HAMFB_FILE="$d/fb.raw"
    "$WORK/v2probe.elf" "$FBW" "$MAX_H" hold 0 "$MAX_Y" \
        >"$d/max.out" 2>"$d/max.err" &
    MAXPID=$!; reap_add "$MAXPID"
    "$WORK/v2probe.elf" "$STRAD_W" "$STRAD_H" hold "$STRAD_X" "$STRAD_Y" \
        >"$d/strad.out" 2>"$d/strad.err" &
    STRADPID=$!; reap_add "$STRADPID"
    local i=0
    while [ "$i" -lt 80 ]; do
        grep -q '^blit ' "$d/max.out" 2>/dev/null && \
        grep -q '^blit ' "$d/strad.out" 2>/dev/null && break
        sleep 0.1; i=$((i+1))
    done
    sleep 2
    cp "$d/fb.raw" "$d/shot2.raw"
    # THE INSTRUMENT'S OWN LIVENESS, asked at the moment the sample was taken.
    local alive=0
    kill -0 "$MAXPID" 2>/dev/null && alive=$((alive+1))
    kill -0 "$STRADPID" 2>/dev/null && alive=$((alive+1))
    echo "$alive"
}

# ===========================================================================
say "ARM 1 -- THE CURRENT TREE AT ${FBW}x${FBH}"
# ===========================================================================
if ! run_desktop "$WORK/wsysd.elf" "$WORK/g" "$GEOM"; then
    bad "the desktop did not come up at ${FBW}x${FBH} at all"
    sed 's/^/wide2560:      /' "$WORK/g/wsysd.log"
    done_report; exit 1
fi
ok "the desktop came up at ${FBW}x${FBH}"
if grep -qi 'drifted apart\|asked to be rasterized' "$WORK/g/wsysd.log"; then
    bad "the compositor REPORTS a clamp or a ceiling drift at ${FBW}x${FBH}: \"$(grep -im1 'drifted apart\|asked to be rasterized' "$WORK/g/wsysd.log")\""
else
    ok "and the compositor reports no clamp and no ceiling drift at ${FBW}x${FBH}"
fi

# -- the window table, for context beside the pixels -------------------------
win_table "$WORK/g" >"$WORK/g/wins.txt"
info "the window table at ${FBW}x${FBH}:"
sed 's/^/wide2560:        wid x y w h = /' "$WORK/g/wins.txt"
FULLW_N=$(awk -v w="$FBW" '$4 == w { n++ } END { print n+0 }' "$WORK/g/wins.txt")
if [ "$FULLW_N" -ge 2 ]; then
    ok "arm 1a: $FULLW_N windows are ${FBW} columns wide in the table -- the backdrop and the panels were GRANTED the full width (this is geometry, not paint; the pixels are below)"
else
    bad "arm 1a: only $FULLW_N window(s) in the table are ${FBW} wide -- the backdrop and both panels should be. Something refused the width before a single pixel was drawn"
fi

# -- 1b. THE BACKDROP AT THE RIGHT EDGE --------------------------------------
# Rows 300..500, columns 2300..2555: bare backdrop by construction (desktop
# icons are at the left edge, the taskbar buttons at the bottom).
# THE BAND IS ROWS 600..800 AND THE REFERENCE IS THE SAME ROWS AT THE LEFT.
# The gradient runs VERTICALLY, so any single row of a correct backdrop is
# horizontally uniform -- which makes "the right end matches the left end on the
# same rows" a stronger statement than any absolute colour, and one that needs
# no constant from hamdesktop in this file.
read -r BPCT BMB <<<"$(backdrop_pct 600 200 2300 $((FBW - 4)) "$WORK/g/shot.raw")"
read -r RPCT RMB <<<"$(backdrop_pct 600 200 200 656 "$WORK/g/shot.raw")"
info "arm 1b: over rows 600..799 the backdrop hue is $RPCT% at columns 200..655 (mean blue $RMB) and $BPCT% at columns 2300..$((FBW - 4)) (mean blue $BMB)"
if [ "$RPCT" -lt 95 ]; then
    bad "arm 1b: the REFERENCE band at columns 200..655 is only $RPCT% backdrop -- this probe is not on the wallpaper and nothing it says about the right edge means anything"
elif [ "$BPCT" -ge 95 ] && [ "$BMB" -ge $((RMB - 4)) ] && [ "$BMB" -le $((RMB + 4)) ]; then
    ok "arm 1b: THE BACKDROP REACHES THE RIGHT EDGE -- $BPCT% of columns 2300..$((FBW - 4)) carry the gradient, at mean blue $BMB against $RMB at columns 200..655 on the same rows"
elif [ "$BPCT" -ge 95 ]; then
    bad "arm 1b: columns 2300..$((FBW - 4)) are backdrop-hued ($BPCT%) but at mean blue $BMB against $RMB on the SAME rows at the left -- the gradient runs vertically, so the two ends of a row must agree and these do not"
else
    bad "arm 1b: only $BPCT% of columns 2300..$((FBW - 4)) carry the backdrop (against $RPCT% at columns 200..655 on the same rows) -- the desktop background stops short of the right edge of a ${FBW}-column screen"
fi

# -- 1c. AND IT IS CONTINUOUS ACROSS BOTH OLD CEILINGS -----------------------
for C in "$CEIL_A" "$CEIL_B"; do
    read -r CPCT _ <<<"$(backdrop_pct 600 200 $((C - 8)) $((C + 8)) "$WORK/g/shot.raw")"
    if [ "$CPCT" -ge 95 ]; then
        ok "arm 1c: the backdrop is continuous ACROSS column $C ($CPCT% over columns $((C - 8))..$((C + 8)), rows 600..799)"
    else
        bad "arm 1c: the backdrop breaks at column $C ($CPCT% over columns $((C - 8))..$((C + 8))) -- that is one of the two ceilings this stack has already been cut at"
    fi
done

# -- 1d. THE PANELS, IN PIXELS AT COLUMN 2500 --------------------------------
# The panel's own y is read from the DEVICE, not from a constant in this file:
# PANEL_BOT_H lives in user/hamdesktop.ad and a gate must not keep a copy.
# "The panel is painted here" is asserted as NOT-BACKDROP and NOT-clear: the
# panel is a light chrome grey, the backdrop is blue-dominant, the clear is
# #1c1c1c. A single sample cannot tell the last two apart, so the assertion is
# that the far-right end of the panel row matches the far-LEFT end of the same
# row -- which is the panel, because the taskbar's left end always is.
PANEL_Y=$(awk -v w="$FBW" '$4 == w && $3 != 0 && $5 < 60 { print $3 }' "$WORK/g/wins.txt" | sort -n | tail -1)
if [ -n "${PANEL_Y:-}" ]; then
    PY_SAMPLE=$((PANEL_Y + 6))
    PY_REF=$((PANEL_Y - 24))
    # THE INSTRUMENT PROVES ITSELF FIRST, IN THIS RUN, ON THIS FRAME. The
    # show-through test is run on a band of BARE WALLPAPER before it is run on
    # the panel; it must answer ~100% there. Without that, a 0% on the panel is
    # a comparison that could not have produced a non-zero.
    read -r WPROOF _ <<<"$(showthrough $((PY_REF - 40)) $((PY_REF - 20)) 4 2300 $((FBW - 4)) 6 "$WORK/g/shot.raw")"
    if [ "$WPROOF" -ge 95 ]; then
        ok "arm 1d: the show-through probe answers $WPROOF% on a band of bare wallpaper, so a low reading on the panel below is a reading and not a floor"
    else
        bad "arm 1d: the show-through probe answers only $WPROOF% on bare wallpaper -- it cannot recognise the wallpaper it is looking for, so its verdict on the panel means nothing"
    fi
    read -r PL _ <<<"$(panel_pct "$PY_SAMPLE" 4 100 400 "$WORK/g/shot.raw")"
    read -r PSL _ <<<"$(showthrough "$PY_REF" "$PY_SAMPLE" 4 100 400 6 "$WORK/g/shot.raw")"
    read -r PSR _ <<<"$(showthrough "$PY_REF" "$PY_SAMPLE" 4 2300 $((FBW - 4)) 6 "$WORK/g/shot.raw")"
    info "arm 1d: the bottom panel is at y=$PANEL_Y; on its row the wallpaper shows through in $PSL% of columns 100..400 and $PSR% of columns 2300..$((FBW - 4)) (panel chrome at the left end: $PL%)"
    # THE LEFT END IS THE INSTRUMENT CHECK AND IT COMES FIRST. If the probe is
    # not on the panel at all, the right end says nothing.
    if [ "$PL" -lt 90 ]; then
        bad "arm 1d: the panel row at y=$PY_SAMPLE is only $PL% panel chrome at its LEFT end, where the taskbar always is -- this probe is not on the panel and arm 1d measured nothing"
    elif [ "$PSR" -lt 5 ] && [ "$PSL" -lt 5 ]; then
        ok "arm 1d: THE BOTTOM PANEL COVERS THE FULL ${FBW} COLUMNS -- the wallpaper shows through in $PSR% of columns 2300..$((FBW - 4)), against $PSL% at its left end"
    else
        bad "arm 1d: the wallpaper shows through the bottom panel in $PSR% of columns 2300..$((FBW - 4)) (and $PSL% at its left end) -- the panel is granted ${FBW} columns in the table and covers fewer"
    fi
else
    bad "arm 1d: no full-width bottom panel in the window table, so the panel cannot be located and its width is unmeasured"
fi

# -- 1e / 1f. THE TWO PROBE WINDOWS ------------------------------------------
ALIVE="$(start_probes "$WORK/g")"
sed 's/^/wide2560:        maximised probe: /' "$WORK/g/max.out"
sed 's/^/wide2560:        straddle probe:  /' "$WORK/g/strad.out"
if [ "$ALIVE" = 2 ]; then
    ok "arm 1e: both probe clients were still holding their windows open when the framebuffer was sampled"
else
    bad "arm 1e: only $ALIVE of 2 probe clients were alive at the sample -- a v2 window has no pixels once its client exits, so the window arms below are measuring an empty screen and are not about the blit"
    tail -5 "$WORK/g/max.err" "$WORK/g/strad.err" 2>/dev/null | sed 's/^/wide2560:      /'
fi
win_table "$WORK/g" >"$WORK/g/wins2.txt"
info "the window table with both probes up:"
sed 's/^/wide2560:        wid x y w h = /' "$WORK/g/wins2.txt"

# THE MAXIMISED CASE: a window as wide as the screen.
# ROWS INSIDE THE BAND AND NOWHERE ELSE. The first version of this gate put a
# 2560x1000 window at y=200 and the straddler INSIDE it, both painted the same
# colour, and then read the straddler's right edge off whichever of the two the
# scan happened to reach -- reporting a truncation at 2559 for a window that
# ends at 2499. The two probes do not overlap now, and each is measured on rows
# only it occupies.
MROW=$((MAX_Y + MAX_H / 2))
read -r MPCT _ <<<"$(mark_pct "$MROW" 40 2400 $((FBW - 4)) "$WORK/g/shot2.raw")"
read -r MLEFT _ <<<"$(mark_pct "$MROW" 40 100 500 "$WORK/g/shot2.raw")"
MLAST="$(lastmark "$MROW" 0 "$FBW" "$WORK/g/shot2.raw")"
info "arm 1e: the ${FBW}-wide window is $MLEFT% its own colour at columns 100..500 and $MPCT% at columns 2400..$((FBW - 4)); its last painted column on row $MROW is $MLAST"
if [ "$MLEFT" -lt 90 ]; then
    bad "arm 1e: the ${FBW}-wide window is only $MLEFT% its own colour at columns 100..500 -- it is not painting at ALL, so nothing about its right edge is measurable"
elif [ "$MPCT" -ge 90 ]; then
    ok "arm 1e: A WINDOW AS WIDE AS THE SCREEN PAINTS TO THE RIGHT EDGE -- $MPCT% of columns 2400..$((FBW - 4)) are its colour, and its last painted column is $MLAST"
else
    bad "arm 1e: the ${FBW}-wide window paints $MLEFT% at its left and only $MPCT% at columns 2400..$((FBW - 4)); its last painted column is $MLAST. A maximised window is being truncated"
fi

# THE STRADDLING CASE: 1700..2499, across BOTH old ceilings.
SROW=$((STRAD_Y + STRAD_H / 2))
SLAST="$(lastmark "$SROW" "$STRAD_X" "$FBW" "$WORK/g/shot2.raw")"
SEXP=$((STRAD_X + STRAD_W - 1))
info "arm 1f: the straddling window is $STRAD_X..$SEXP (${STRAD_W} columns wide, which is past the ${CEIL_A}-column ceiling in its own right); its last painted column on row $SROW is $SLAST"
for C in "$CEIL_A" "$CEIL_B"; do
    read -r SPCT _ <<<"$(mark_pct $((STRAD_Y + 50)) 100 $((C - 8)) $((C + 8)) "$WORK/g/shot2.raw")"
    if [ "$SPCT" -ge 90 ]; then
        ok "arm 1f: the straddling window paints CONTINUOUSLY ACROSS COLUMN $C ($SPCT% over columns $((C - 8))..$((C + 8)))"
    else
        bad "arm 1f: the straddling window breaks at column $C ($SPCT% over columns $((C - 8))..$((C + 8)))"
    fi
done
if [ "$SLAST" = "$SEXP" ]; then
    ok "arm 1f: and its right edge is EXACTLY where it asked to be, column $SLAST -- not at $CEIL_A and not at $CEIL_B"
else
    bad "arm 1f: the straddling window's last painted column is $SLAST, not $SEXP. $( [ "$SLAST" = $((STRAD_X + CEIL_A - 1)) ] && echo "That is $STRAD_X + $CEIL_A -- the sixth ceiling, which cuts by the WINDOW's width, is back." || { [ "$SLAST" = $((STRAD_X + CEIL_B - 1)) ] && echo "That is $STRAD_X + $CEIL_B -- the fifth ceiling is back." || { [ "$SLAST" = $((CEIL_A - 1)) ] || [ "$SLAST" = $((CEIL_B - 1)) ] && echo "That is a SCREEN column, not a window one, which is a ceiling in the composite rather than in the row." || echo "It is none of the known ceilings, which makes it a SEVENTH constant that has not been identified."; }; } )"
fi
reap_all; sleep 0.5

# ===========================================================================
say "ARM 2 -- NEGATIVE CONTROL A: the sixth ceiling put back (BBROW_CAP)"
# ===========================================================================
# THE MUTATION IS THE PRE-baacdc64 CODE, NOT MERELY THE OLD CONSTANT. Setting
# BBROW_CAP back to 7680 on its own changes NOTHING: the loop covers the row in
# RUNS of that buffer now, so a 7680-byte buffer would simply take two reads.
# What made it a ceiling was `rowbytes` being clamped to it, and that is what
# is put back here. A control that only moved the constant would come up green
# and this file would have shipped an assertion that cannot fail.
mkdir -p "$WORK/mutA"
sed -e 's/^BBROW_CAP: uint64 = 16384.*/BBROW_CAP: uint64 = 7680/' \
    -e 's/^    if rowbytes > devw \* 4:$/    if rowbytes > BBROW_CAP:/' \
    -e 's/^        rowbytes = devw \* 4$/        rowbytes = BBROW_CAP/' \
    user/wsysd.ad >"$WORK/mutA/wsysd.ad"
MUTA_OK=1
grep -q '^BBROW_CAP: uint64 = 7680' "$WORK/mutA/wsysd.ad" || MUTA_OK=0
grep -q '^        rowbytes = BBROW_CAP$' "$WORK/mutA/wsysd.ad" || MUTA_OK=0
if [ "$MUTA_OK" = 1 ]; then
    ok "arm 2: the mutant source carries BBROW_CAP = 7680 AND the clamp that made it a ceiling"
else
    bad "arm 2: could not construct mutant A -- paint_backbuffer no longer has the shape this sed matches, so THE NEGATIVE CONTROL FOR THE WINDOW ARMS DID NOT RUN and arm 1e/1f are unproven assertions"
fi
if [ "$MUTA_OK" = 1 ] && shadow_build wsysd_mutA user/wsysd.ad "$WORK/mutA/wsysd.ad"; then
    if run_desktop "$WORK/wsysd_mutA.elf" "$WORK/a" "$GEOM"; then
        AALIVE="$(start_probes "$WORK/a")"
        [ "$AALIVE" = 2 ] || info "arm 2: only $AALIVE of 2 probes alive at the sample"
        ALAST="$(lastmark "$SROW" "$STRAD_X" "$FBW" "$WORK/a/shot2.raw")"
        AMLAST="$(lastmark "$MROW" 0 "$FBW" "$WORK/a/shot2.raw")"
        # THE TWO EXPECTED CUTS ARE DIFFERENT NUMBERS, AND THAT IS THE POINT.
        # BBROW_CAP bounds the WINDOW's row, so the full-width window at x=0 is
        # cut at screen column 1919 and the straddler at x=400 is cut at
        # 400 + 1919. A ceiling in the COMPOSITE would cut both at 1919. A gate
        # that asserted the same number twice could not tell those apart.
        A_WANT_S=$((STRAD_X + CEIL_A - 1))
        A_WANT_M=$((CEIL_A - 1))
        info "arm 2: with the ceiling back, the straddling window's last painted column is $ALAST (expected $A_WANT_S) and the full-width window's is $AMLAST (expected $A_WANT_M)"
        if [ "$ALAST" = "$A_WANT_S" ]; then
            ok "arm 2: THE STRADDLE ASSERTION CAN FAIL. With BBROW_CAP clamping again the straddling window ends at column $ALAST -- $STRAD_X + $CEIL_A, i.e. 7680/4 columns of ITS OWN width -- and not at the $SEXP it asked for"
        else
            bad "arm 2: the mutant's straddling window ends at column $ALAST, not $A_WANT_S. Either the mutation did not reach the pixels or the truncation is not where the constant says -- either way arm 1f is not proven able to fail"
        fi
        if [ "$AMLAST" = "$A_WANT_M" ]; then
            ok "arm 2: and so can the full-width assertion -- that window ends at column $AMLAST, and the two cuts being $((A_WANT_S - A_WANT_M)) apart is what says this ceiling is per-WINDOW-width and not a column of the screen"
        else
            bad "arm 2: the mutant's ${FBW}-wide window ends at column $AMLAST, not $A_WANT_M -- arm 1e is not proven able to fail"
        fi
        # AND THE OTHER HALF OF A CONTROL: the assertions this mutant should
        # NOT touch must stay green, or the two mechanisms are not separated.
        read -r ABP _ <<<"$(backdrop_pct 600 200 2300 $((FBW - 4)) "$WORK/a/shot.raw")"
        if [ "$ABP" -ge 95 ]; then
            ok "arm 2: and the BACKDROP is unaffected by it ($ABP% at columns 2300..$((FBW - 4))) -- paint_backbuffer is not on the scene path, so arm 1b is measuring a different mechanism from arm 1f and not one shared symptom"
        else
            bad "arm 2: the BBROW mutant also broke the backdrop ($ABP%) -- then arms 1b and 1f are not independent and this gate cannot say which ceiling a future red is"
        fi
    else
        bad "arm 2: the mutant compositor did not come up, so the window assertions have NO negative control"
    fi
    reap_all; sleep 0.5
fi

# ===========================================================================
say "ARM 3 -- NEGATIVE CONTROL B: the third ceiling put back, on the WIDTH axis"
# ===========================================================================
# lib/hamui_host.ad with HOST_MAX_W = 1920. This is de_backdrop_bottom.sh's bug
# rotated ninety degrees: that gate shrank HOST_MAX_H and found a black BAR at
# the bottom; nothing in the tree had ever shrunk HOST_MAX_W and looked at the
# right edge. If the backdrop still reaches column 2555 with the rasterizer
# capped at 1920 columns, arm 1b is not measuring the rasterizer's width.
mkdir -p "$WORK/mutB"
sed -e 's/^HOST_MAX_W: uint64 = .*/HOST_MAX_W: uint64 = 1920/' \
    lib/hamui_host.ad >"$WORK/mutB/hamui_host.ad"
if grep -q '^HOST_MAX_W: uint64 = 1920' "$WORK/mutB/hamui_host.ad"; then
    ok "arm 3: the mutant rasterizer carries HOST_MAX_W = 1920 against a ${FBW}-column screen"
    if shadow_build wsysd_mutB lib/hamui_host.ad "$WORK/mutB/hamui_host.ad"; then
        if run_desktop "$WORK/wsysd_mutB.elf" "$WORK/b" "$GEOM"; then
            win_table "$WORK/b" >"$WORK/b/wins.txt"
            read -r BBP _ <<<"$(backdrop_pct 600 200 2300 $((FBW - 4)) "$WORK/b/shot.raw")"
            read -r BLP _ <<<"$(backdrop_pct 600 200 200 656 "$WORK/b/shot.raw")"
            info "arm 3: with the rasterizer capped at 1920 columns the backdrop hue is $BLP% at columns 200..655 and $BBP% at columns 2300..$((FBW - 4))"
            if [ "$BLP" -ge 90 ] && [ "$BBP" -lt 20 ]; then
                ok "arm 3: THE BACKDROP ASSERTION CAN FAIL. A rasterizer capped at 1920 columns paints the left of the screen ($BLP%) and not the right ($BBP%) -- arm 1b is measuring the rasterizer's width and not merely 'something blue is on the screen'"
            elif [ "$BLP" -lt 90 ]; then
                bad "arm 3: the mutant painted only $BLP% even at columns 200..655, so it broke something other than the width and this control does not isolate arm 1b"
            else
                bad "arm 3: a rasterizer capped at 1920 columns STILL painted $BBP% of columns 2300..$((FBW - 4)) -- arm 1b cannot be made to fail by shrinking the rasterizer's width, so it is not asserting what it says it asserts"
            fi
            # AND THE PANEL, WHICH IS ALSO A SCENE WINDOW. arm 1d has to be
            # shown able to fail too, and this is the mutant that can do it:
            # hampanelscene's bar is rasterized through the same module, so a
            # 1920-column rasterizer leaves the right end of the taskbar
            # unpainted. Asserted on the PANEL CHROME rather than on
            # show-through, because under this mutant the reference row above
            # the panel is unpainted as well and "the two rows match" would then
            # be true for a reason that has nothing to do with the panel.
            BPANEL_Y=$(awk -v w="$FBW" '$4 == w && $3 != 0 && $5 < 60 { print $3 }' "$WORK/b/wins.txt" 2>/dev/null | sort -n | tail -1)
            if [ -n "${BPANEL_Y:-}" ]; then
                read -r BPL _ <<<"$(panel_pct $((BPANEL_Y + 6)) 4 100 400 "$WORK/b/shot.raw")"
                read -r BPR _ <<<"$(panel_pct $((BPANEL_Y + 6)) 4 2300 $((FBW - 4)) "$WORK/b/shot.raw")"
                info "arm 3: the mutant's bottom panel is $BPL% chrome at columns 100..400 and $BPR% at columns 2300..$((FBW - 4))"
                if [ "$BPL" -ge 90 ] && [ "$BPR" -lt 10 ]; then
                    ok "arm 3: THE PANEL ASSERTION CAN FAIL TOO -- the same mutant leaves the taskbar painted at its left end ($BPL%) and bare at columns 2300..$((FBW - 4)) ($BPR%)"
                else
                    bad "arm 3: the mutant's panel reads $BPL% chrome at the left and $BPR% at the right; a 1920-column rasterizer should paint the first and not the second, so arm 1d is not proven able to fail"
                fi
            else
                bad "arm 3: no full-width bottom panel in the mutant's window table, so arm 1d has no negative control"
            fi
            # AND ITS OWN NOISE: a recurrence must announce itself, which is
            # the arm that would have turned the black bar into a log line.
            if grep -qi 'drifted apart' "$WORK/b/wsysd.log"; then
                ok "arm 3: and the compositor SAYS SO at startup -- \"$(grep -im1 'drifted apart' "$WORK/b/wsysd.log" | cut -c1-140)...\""
            else
                bad "arm 3: the compositor said nothing about a rasterizer ceiling under its composite buffer on the WIDTH axis -- the drift check names the rectangle, so a width-only shrink should trip it"
            fi
        else
            bad "arm 3: the mutant-rasterizer compositor did not come up, so the backdrop assertion has NO negative control"
        fi
        reap_all
    fi
else
    bad "arm 3: could not construct mutant B -- lib/hamui_host.ad no longer declares HOST_MAX_W the way this sed matches, so THE NEGATIVE CONTROL FOR THE BACKDROP DID NOT RUN"
fi

info "NOT MEASURED HERE: real hardware (every framebuffer above is HAMFB_FILE), frame timing of any kind, and the Xwayland/native-Wayland path at this width -- that is tests/linux/wsyswl_wide_native.sh."
done_report
