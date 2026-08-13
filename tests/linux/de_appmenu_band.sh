#!/usr/bin/env bash
# tests/linux/de_appmenu_band.sh — THE APPLICATIONS MENU, ON THE REAL DESKTOP,
# WITH A REAL APPLICATION UNDER THE BAND IT GROWS INTO.
#
# THE BUG, as the machine's owner reported it, twice
# ==================================================
#   "the right of the Applications menu is blank instead of showing the DE
#    background, or the other apps. It's like the menu is the full width of
#    the display and the right part is blank."
#
# It is literally that. `user/hampanelscene.ad` owns ONE window per panel, and
# when the Applications dropdown opens that window GROWS to the full width of
# the display and down to hold the menu card -- 1280x26 becomes 1280x206 here.
# The panel then paints only the bar strip and the 136 px menu column and
# leaves the rest of the grown band UNPAINTED, which is correct and is what
# devwsys's `keyed` ctl verb exists for: the compositor must skip the alpha-0
# pixels so the wallpaper and the windows below composite through.
# `docs/screenshots/linux/distro-menu-debian.png` is the defect -- a black
# rectangle from the menu's right edge to the right edge of the screen,
# swallowing the wallpaper and the desktop icons.
#
# WHY THIS FILE EXISTS WHEN tests/linux/wsys_keyed.sh ALREADY PASSES
# ==================================================================
# wsys_keyed proves the MECHANISM: it builds a synthetic full-width window out
# of tests/linux/wsys_hold.ad, paints its left 200 px, and asserts the rest is
# the backdrop. Nothing in the tree asserted anything about the APPLICATIONS
# MENU. Between the mechanism and the reported artefact sit three things a
# synthetic window does not have: hampanelscene deciding to write `keyed 1` at
# all (it writes it at window creation, and a window pooled or re-created by a
# config reload is a second, separate call site), the panel's own display list
# not filling the grown rect, and the geometry actually growing. Any one of
# those can regress with `wsys_keyed` still green, and the symptom is the
# screenshot above.
#
# tests/linux/wsys_cover.sh is the third neighbour and is also not this: it
# feeds display lists to the rasterizer offline and asks whether they cover
# their window. It never runs a compositor and never looks at a framebuffer.
#
# AND THE SECOND HALF OF THE REPORT -- "or the other apps" -- WAS UNTESTED
# ANYWHERE. A keyed present that let the wallpaper through but not a window
# below it would satisfy every existing assertion in the tree. So this gate
# puts a real client window UNDER the grown band and asserts it survives.
#
# WHAT IS MEASURED
# ================
#   1. the real desktop, composed: wsysd + hamdesktop + hampanelscene, plus
#      tests/linux/wsys_zclient.ad as an ordinary flat-coloured application at
#      z 6, inside the rectangle the menu is about to grow over.
#   2. the menu is opened THE WAY A PERSON OPENS IT -- a pointer event on the
#      Applications button, written into the panel window's own event ring
#      (`/dev/wsys/<wid>/event`, which the host owner may write; this is the
#      same driver tests/linux/distro_menu.sh uses). A real mouse now reaches
#      the panel too -- `wsysd` routes the pointer onto the event ring since
#      the fix gated by tests/linux/de_mouse_chrome.sh -- but this file keeps
#      the ring write on purpose: what it measures is the menu's GEOMETRY and
#      the keyed present under it, and a poke is the shortest path to an open
#      menu. de_mouse_chrome.sh is the file that owns the input question, and
#      it is forbidden from taking this shortcut.
#   3. the panel window GREW to the full width of the display -- the shape of
#      the report, asserted rather than assumed.
#   4. the wallpaper to the right of the menu card is BYTE-IDENTICAL to the
#      frame before the menu opened.
#   5. the application window under the band is still its own colour.
#   6. the menu card itself is opaque and painted, so 4 and 5 cannot be
#      satisfied by a panel that drew nothing.
#   7. THE NEGATIVE CONTROL, IN THE SAME RUN. `keyed 0` is written to the
#      panel's ctl and the band must go BLACK -- the application vanishes and
#      the wallpaper strip stops matching. Then `keyed 1` and both come back.
#      Without this, "the wallpaper is still there" only proves the menu is
#      somewhere else on the screen.
#
# Entirely offscreen (HAMFB_FILE + a file of evdev records): no VM, no display,
# no GPU. The software Vulkan ICD is forced because wsysd has a real Vulkan
# backend and this host's GPU belongs to someone.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

# The desktop stack writes FIXED, HOST-GLOBAL names whatever this script does
# about its own $WORK: hampanelscene writes /tmp/hamnix-panel.{health,fault},
# /tmp/hamnix-panel-drop and /tmp/hamnix-notif.log; hamdesktop writes
# /tmp/hamdesktop-wp.status and /tmp/.hamdesktop.src. Those names are compiled
# into the programs under test, so no care taken here can move them, and a
# concurrent run -- another agent's, or a person's live desktop on this
# machine -- reads exactly those files. tests/linux/private_ns.sh records what
# that cost the day a gate was found writing /tmp/hamnix-panel.conf. This call
# puts everything below inside a mount namespace where /tmp, /dev/shm and /srv
# are this run's alone; it execs, and does not return.
#
# NOTE for a KEEP=1 post-mortem: $WORK is inside that private /tmp and goes
# with it. Use priv_ns_keep to copy anything you want to outlive the run.
. tests/linux/private_ns.sh
priv_ns_reexec "$@"

WORK="${BAND_WORK:-$(mktemp -d -p "${TMPDIR:-/tmp}" appband.XXXXXX)}"
mkdir -p "$WORK"
KEEP="${BAND_KEEP:-0}"
GEOM="${HAMFB_GEOM:-1280x800}"
FBW="${GEOM%x*}"; FBH="${GEOM#*x}"

export HAMWSYS="$WORK/wsys.shm"
export HAMWSYS_BB="$WORK/wsys.bb"
export HAMWSYS_IMG="$WORK/wsys.img"
export HAMFB_FILE="$WORK/fb.raw"
export HAMFB_GEOM="$GEOM"
[ -r /usr/share/vulkan/icd.d/lvp_icd.json ] && \
    export VK_ICD_FILENAMES="${VK_ICD_FILENAMES:-/usr/share/vulkan/icd.d/lvp_icd.json}"

pass=0; fail=0
# An empty read is not a measurement. See tests/linux/gate_read.sh: the ctl
# read below took ${5:-0} as the panel's height, so a ctl line that could not
# be read at all printed "the menu never opened" and killed the run.
. tests/linux/gate_read.sh

ok()   { echo "appband: PASS $*"; pass=$((pass+1)); }
bad()  { echo "appband: FAIL $*"; fail=$((fail+1)); }
info() { echo "appband: INFO $*"; }

PIDS=""
cleanup() {
    for p in $PIDS; do [ -n "${p:-}" ] && kill "$p" 2>/dev/null; done
    sleep 0.3
    for p in $PIDS; do [ -n "${p:-}" ] && kill -9 "$p" 2>/dev/null; done
    [ "$KEEP" = 1 ] || rm -rf "$WORK"
}
trap cleanup EXIT
# A bare EXIT trap does not run when the shell is killed by a signal, so a
# gate stopped by `timeout` (TERM) or ^C (INT) skipped its cleanup entirely.
# Re-exit on those, which makes the EXIT trap above run on every path out.
trap 'exit 130' INT TERM HUP
done_report() { echo "appband: $pass passed, $fail failed"; [ "$fail" = 0 ]; }

# ---- the pixel arithmetic -------------------------------------------------
# Two questions only, both arithmetic: "what fraction of this rectangle is
# exactly this colour" and "what fraction of it is unchanged since that frame".
# The probe client paints ONE FLAT FILL for the first; the second needs no
# colour at all, which is what makes it usable against a wallpaper gradient.
FRAC_PY="$WORK/frac.py"
cat >"$FRAC_PY" <<'PY'
import sys
mode = sys.argv[1]
W, H = int(sys.argv[2]), int(sys.argv[3])
x, y, w, h = (int(v) for v in sys.argv[4:8])
d = open(sys.argv[8], 'rb').read()
tot = hit = 0
if mode == 'colour':
    c = sys.argv[9]
    want = (int(c[0:2], 16), int(c[2:4], 16), int(c[4:6], 16))
    for j in range(y, min(y + h, H), 2):
        row = j * W * 4
        for i in range(x, min(x + w, W), 2):
            o = row + i * 4
            tot += 1
            if (d[o+2], d[o+1], d[o]) == want:
                hit += 1
else:                                     # 'same' as another frame
    e = open(sys.argv[9], 'rb').read()
    for j in range(y, min(y + h, H), 2):
        row = j * W * 4
        for i in range(x, min(x + w, W), 2):
            o = row + i * 4
            tot += 1
            if d[o:o+3] == e[o:o+3]:
                hit += 1
print(0 if tot == 0 else hit * 100 // tot)
PY
colourpct() { python3 "$FRAC_PY" colour "$FBW" "$FBH" "$1" "$2" "$3" "$4" "$5" "$6"; }
samepct()   { python3 "$FRAC_PY" same   "$FBW" "$FBH" "$1" "$2" "$3" "$4" "$5" "$6"; }
snap()      { cp "$HAMFB_FILE" "$WORK/$1.raw"; }

# ---- build ----------------------------------------------------------------
for t in wsysd:user/wsysd.ad \
         hamdesktop:user/hamdesktop.ad \
         hampanelscene:user/hampanelscene.ad \
         wsys_zclient:tests/linux/wsys_zclient.ad \
         wsys_poke:tests/linux/wsys_poke.ad; do
    name="${t%%:*}"; src="${t#*:}"
    scripts/hamlinux_build.sh "$src" "$WORK/$name.elf" \
        >"$WORK/$name.build.log" 2>&1 || {
        bad "could not build $src"; tail -20 "$WORK/$name.build.log" >&2
        done_report; exit 1; }
done
ok "the compositor, the desktop, the panel and the probe client all build"

poke()     { "$WORK/wsys_poke.elf" "$@" 2>/dev/null; }
winctl()   { poke "/dev/wsys/$1/ctl"; }

# An offscreen wsysd must not open this host's real keyboard and mouse.
: >"$WORK/input.evdev"
export HAMWSYSD_INPUT="$WORK/input.evdev"

# ---- the compositor -------------------------------------------------------
"$WORK/wsysd.elf" </dev/null >"$WORK/wsysd.log" 2>&1 &
PIDS="$PIDS $!"
for _ in $(seq 1 60); do [ -s "$HAMFB_FILE" ] && break; sleep 0.1; done
[ -s "$HAMFB_FILE" ] || { bad "wsysd never produced a framebuffer"
                          cat "$WORK/wsysd.log"; done_report; exit 1; }
if grep -q "input from $WORK/input.evdev only" "$WORK/wsysd.log"; then
    ok "wsysd took its input from the test's evdev file and opened no real device"
else
    bad "wsysd did not honour HAMWSYSD_INPUT -- it may be reading this host's keyboard"
fi

# THE CURSOR IS PARKED OFF THE MEASURED RECTANGLES. wsysd draws its sprite at
# the centre of the screen at startup, and a pixel probe on a compositor that
# does not say where the cursor is is measuring the cursor -- wsys_keyed.sh was
# caught by exactly that (it read CUR_DARK 0x202020 and called the backdrop
# missing). Park it in the bottom-right corner, clear of the panel band, the
# menu card and the probe window.
python3 - "$WORK/input.evdev" <<'PY'
import struct, sys
with open(sys.argv[1], 'ab') as f:
    for t, c, v in ((3, 0, 32000), (3, 1, 30000), (0, 0, 0)):
        f.write(struct.pack('<qqHHi', 0, 0, t, c, v))
PY

# ---- the desktop and the panel -------------------------------------------
"$WORK/hamdesktop.elf" </dev/null >"$WORK/hamdesktop.log" 2>&1 &
PIDS="$PIDS $!"
sleep 3
"$WORK/hampanelscene.elf" </dev/null >"$WORK/hampanelscene.log" 2>&1 &
PIDS="$PIDS $!"
sleep 3

# The top panel, found rather than guessed: the full-width bar nearest the top
# of the screen that is not the full-screen backdrop.
PANEL=""; PANELH=""
for wid in $(seq 2 40); do
    line="$(winctl "$wid")"; [ -n "$line" ] || continue
    set -- $line
    [ "${4:-}" = "$FBW" ] || continue           # full width
    [ "${5:-0}" -lt 200 ] || continue           # a bar, not the backdrop
    [ "${3:-0}" = "0" ] || continue             # at the top of the screen
    PANEL="$wid"; PANELH="${5:-}"
done
if [ -n "$PANEL" ]; then
    ok "hampanelscene mapped a full-width top bar (wid $PANEL, height $PANELH)"
else
    bad "no full-width top bar -- there is no Applications menu to open"
    sed 's/^/appband:      /' "$WORK/hampanelscene.log"
    done_report; exit 1
fi

# ---- the application that must survive the band --------------------------
# Placed INSIDE the rectangle the grown panel will own, and to the right of the
# 136 px menu card, at the z an ordinary hamui window gets.
APPX=400; APPY=60; APPW=320; APPH=120; APPCOL=7A1FA2
"$WORK/wsys_zclient.elf" "$APPX" "$APPY" "$APPW" "$APPH" 6 "$APPCOL" zprobe 600 \
    >"$WORK/zclient.log" 2>&1 &
PIDS="$PIDS $!"
sleep 3
snap closed

got="$(colourpct "$APPX" "$APPY" "$APPW" "$APPH" "$WORK/closed.raw" "$APPCOL")"
if [ "$got" -ge 95 ]; then
    ok "the probe application is on screen before the menu opens ($got% of its rect)"
else
    bad "the probe application is not on screen ($got% of its rect) -- nothing below can be asked"
    sed 's/^/appband:      /' "$WORK/zclient.log"
    done_report; exit 1
fi

# ---- open the Applications menu ------------------------------------------
# A pointer event on the Applications button, on the panel window's own event
# ring. Both panel windows get it: which wid is the top bar is start order, and
# the bottom taskbar ignores a press in the top bar's band.
menuclick() {   # menuclick <buttons>
    # `btn` is taken BEFORE the loop because `set -- $line` below rewrites the
    # function's own positional parameters -- the first version of this file
    # sent the window id as the button bitmap and the menu never opened.
    local btn="$1" wid line
    for wid in $(seq 2 40); do
        line="$(winctl "$wid")"; [ -n "$line" ] || continue
        set -- $line
        [ "${4:-}" = "$FBW" ] && [ "${5:-0}" -lt 200 ] && \
            poke "/dev/wsys/$wid/event" "m 40 13 $btn"
    done
}
menuclick 1
sleep 1.5
menuclick 0
sleep 2
snap open

CTL="$(winctl "$PANEL")"
if ! gate_fields "the panel window's ctl line (/dev/wsys/$PANEL/ctl) after the menu click" 5 "$CTL"; then
    info "the panel's size could not be read, so 'did the menu open' is not a question this run can answer, and nothing below it is either"
    sed 's/^/appband:      /' "$WORK/hampanelscene.log"
    done_report; exit 1
fi
set -- $CTL
GROWNW="$4"; GROWNH="$5"
if [ "$GROWNW" = "$FBW" ] && [ "$GROWNH" -gt "$PANELH" ]; then
    ok "the Applications menu opened and the panel window GREW to ${GROWNW}x${GROWNH} -- the full width of the display, the shape of the report"
else
    bad "the panel window is still ${GROWNW}x${GROWNH} -- the menu never opened, so nothing below is being measured"
    sed 's/^/appband:      /' "$WORK/hampanelscene.log"
    done_report; exit 1
fi

# The menu card is the left MENU_W (136) px of the grown band. Everything the
# assertions below look at is to the RIGHT of it and inside the band.
CARDW=136
BANDY=$((PANELH))
BANDH=$((GROWNH - PANELH))

# 6 FIRST, because 4 and 5 are worthless without it: the menu must actually be
# painted. #f7f8fa is the dropdown's body colour (hampanelscene's roundrect).
got="$(colourpct 4 $((BANDY + 4)) $((CARDW - 8)) $((BANDH - 8)) "$WORK/open.raw" f7f8fa)"
if [ "$got" -ge 60 ]; then
    ok "the menu card is painted and opaque ($got% of its column is the dropdown body)"
else
    bad "the menu card is only $got% of the dropdown body colour -- the menu is not drawn, so 'the desktop shows through' proves nothing"
fi

# 4. THE WALLPAPER, to the right of the menu card and clear of the probe
#    window, byte-identical to the frame before the menu opened.
WALLX=$((APPX + APPW + 40))
WALLW=$((FBW - WALLX - 20))
got="$(samepct "$WALLX" "$BANDY" "$WALLW" "$BANDH" "$WORK/open.raw" "$WORK/closed.raw")"
if [ "$got" -ge 98 ]; then
    ok "the desktop shows through the grown band: $got% of the wallpaper right of the menu is unchanged"
else
    bad "THE REPORTED BUG: only $got% of the wallpaper right of the menu survived the menu opening -- the grown band is painting over the desktop"
fi

# 5. AND THE OTHER APPS -- the half of the report nothing in the tree tested.
got="$(colourpct "$APPX" "$APPY" "$APPW" "$APPH" "$WORK/open.raw" "$APPCOL")"
if [ "$got" -ge 95 ]; then
    ok "the application under the grown band is still on screen ($got% of its rect)"
else
    bad "THE REPORTED BUG: the application under the grown band is $got% of its own colour -- the menu covered a window it does not paint"
fi

# ---- 7. THE NEGATIVE CONTROL ---------------------------------------------
# `keyed 0` on the very same window, the very same scene, the very same frame:
# the band MUST go black. Without this arm, every assertion above is also
# satisfied by a menu that opened somewhere else entirely.
poke "/dev/wsys/$PANEL/ctl" "keyed 0"
sleep 2
snap unkeyed
got="$(colourpct "$APPX" "$APPY" "$APPW" "$APPH" "$WORK/unkeyed.raw" "$APPCOL")"
if [ "$got" -le 5 ]; then
    ok "control: with keyed 0 the same band buries the application ($got% of its rect left) -- the assertions above have teeth"
else
    bad "control: keyed 0 left the application $got% visible -- the panel window is not covering this rectangle at all, so the assertions above were never about the band"
fi
got="$(samepct "$WALLX" "$BANDY" "$WALLW" "$BANDH" "$WORK/unkeyed.raw" "$WORK/closed.raw")"
if [ "$got" -le 10 ]; then
    ok "control: with keyed 0 the wallpaper right of the menu is gone ($got% unchanged)"
else
    bad "control: keyed 0 left $got% of the wallpaper -- this rectangle is not inside the grown band"
fi

# And back, in the same run, so a stuck compositor cannot pass the control.
poke "/dev/wsys/$PANEL/ctl" "keyed 1"
sleep 2
snap rekeyed
got="$(colourpct "$APPX" "$APPY" "$APPW" "$APPH" "$WORK/rekeyed.raw" "$APPCOL")"
if [ "$got" -ge 95 ]; then
    ok "keyed 1 brings the application back through the band ($got% of its rect)"
else
    bad "keyed 1 did not restore the application ($got% of its rect)"
fi

# ---- THE INPUT GAP, named rather than hidden, and now CLOSED -------------
# This gate drives the menu by writing the panel's event ring. When it was
# written that was not only a convenience: user/wsysd.ad routed real pointer
# input to `/dev/wsys/<wid>/pointer` alone, `user/hampanelscene.ad` and
# `user/hamdesktop.ad` read `/dev/wsys/<wid>/event`, and NOTHING in this port
# ever wrote a pointer line to an event ring -- measured, with a window whose
# owner drained neither: after a full evdev click the `pointer` ring held its
# lines and the `event` ring was EMPTY. The DE chrome could not be clicked with
# a mouse at all, and no gate said so, because every gate that drives the
# chrome pokes the ring exactly like this one.
#
# `wsysd`'s `route_pointer_event` closes it: the routed line goes on the EVENT
# ring in devwsys's shape (`m <x> <y> <buttons> <dz>`), and `pointer` is still
# written for lib/hamui.ad. tests/linux/de_mouse_chrome.sh is the gate, and it
# is the one file here that may not poke a ring -- every click in it is
# synthetic evdev into the compositor.
info "the menu is opened by writing the panel's event ring; a real mouse also reaches it now -- see tests/linux/de_mouse_chrome.sh"

done_report
