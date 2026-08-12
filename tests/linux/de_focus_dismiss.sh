#!/usr/bin/env bash
# tests/linux/de_focus_dismiss.sh — DOES CLICKING AWAY CLOSE THE MENU?
#
# THE DEFECT THIS GATES
# =====================
# `user/wsysd.ad` kept `focus_wid` as a private variable and NEVER TOLD ANY
# WINDOW ABOUT IT. Hamnix's devwsys pushes `f in\n` / `f out\n` onto the
# per-window /event ring on every focus change (`_wsys_set_focus` ->
# `_wsys_evt_emit_focus`, ~/Hamnix/sys/src/9/port/devwsys.ad:12399); this port
# emitted no `f` line at all, ever.
#
# `user/hampanelscene.ad` already parsed `f out` and closed its Applications
# dropdown on it — the whole client half of click-away-to-dismiss was written
# and had nothing to trigger it. So an open Applications menu could only be
# closed by hitting the same button a second time. Clicking the wallpaper left
# the card hanging over the desktop, which is wrong in a way a person notices
# within seconds of using the desktop.
#
# WHY NO EXISTING GATE CAUGHT IT
# ==============================
# tests/linux/de_mouse_chrome.sh gates the click that OPENS the menu and the
# second click on the same button that closes it. Both of those land on the
# panel's own window, where focus does not change — so a compositor that never
# emits a focus event at all passes it 13/13. tests/linux/de_appmenu_band.sh
# and tests/linux/distro_menu.sh drive the menu by writing the panel's event
# ring BY HAND as the host owner, so they cannot see an input path at all.
#
# THE RULE THIS FILE INHERITS FROM de_mouse_chrome.sh: it is not allowed to
# touch a ring. Every click below is SYNTHETIC EVDEV — 24-byte `struct
# input_event` records appended to the file named by HAMWSYSD_INPUT, byte for
# byte what /dev/input/eventN delivers, read by wsysd's own `pump_input`.
# `wsys_poke` is used for READS ONLY (the window ctl lines and wsysd's own
# published state file). The last assertion enforces that mechanically by
# grepping this file.
#
# WHAT IS MEASURED
# ================
#   1. the compositor, the desktop and the panel build.
#   2. wsysd takes its input from the test's evdev file and opens no real
#      device of this host's.
#   3. a full-width top bar exists (there is an Applications button to click)
#   4. and a full-screen backdrop exists (there is a WALLPAPER to click away
#      onto) — named, so the click below lands on a window we can identify
#      rather than on an unknown part of the screen.
#   5. CONTROL, before any click: the menu column is not the dropdown colour.
#   6. an EVDEV click on the Applications button opens the menu (the panel
#      window grows), 7. the card is PAINTED, and 8. wsysd reports focus on
#      the panel wid — the precondition for everything below.
#   9. THE FIX: an EVDEV click on the WALLPAPER, far from the panel, closes
#      the menu — the panel window shrinks back to the bar.
#  10. and the card is GONE from the framebuffer.
#  11. and wsysd's own state moved focus to the BACKDROP's wid — a
#      DISCRIMINATOR, not a claim about the fix. It passes with the fix
#      reverted and is meant to: the compositor always knew focus had moved,
#      it just told nobody, and that is the defect stated exactly. Its job is
#      to rule out the other way 9 could go green (the click was swallowed or
#      the panel died, and the short window means nothing).
#  12. the panel is still live and reachable afterwards: clicking the
#      Applications button again RE-OPENS the menu.
#  13. NO REGRESSION on the path that already worked: a click on the menu's
#      own parent — the Applications button, which is the panel's own,
#      already-focused window, where set_focus must emit NOTHING — still
#      closes the menu via the toggle.
#  14. this file never writes an event, pointer or keys ring.
#
# Entirely offscreen (HAMFB_FILE + a file of evdev records): no VM, no
# display, no GPU. The software Vulkan ICD is forced because wsysd has a real
# Vulkan backend and this host's GPU belongs to someone.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

WORK="${FOCUS_WORK:-$(mktemp -d -p "${TMPDIR:-/tmp}" focusdismiss.XXXXXX)}"
mkdir -p "$WORK"
KEEP="${FOCUS_KEEP:-0}"
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
ok()   { echo "focus: PASS $*"; pass=$((pass+1)); }
bad()  { echo "focus: FAIL $*"; fail=$((fail+1)); }
info() { echo "focus: INFO $*"; }

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
done_report() { echo "focus: $pass passed, $fail failed"; [ "$fail" = 0 ]; }

# ---- the pixel probe (same one de_mouse_chrome.sh uses) -------------------
FRAC_PY="$WORK/frac.py"
cat >"$FRAC_PY" <<'PY'
import sys
W, H = int(sys.argv[1]), int(sys.argv[2])
x, y, w, h = (int(v) for v in sys.argv[3:7])
d = open(sys.argv[7], 'rb').read()
c = sys.argv[8]
want = (int(c[0:2], 16), int(c[2:4], 16), int(c[4:6], 16))
tot = hit = 0
for j in range(y, min(y + h, H), 2):
    row = j * W * 4
    for i in range(x, min(x + w, W), 2):
        o = row + i * 4
        tot += 1
        if (d[o+2], d[o+1], d[o]) == want:
            hit += 1
print(0 if tot == 0 else hit * 100 // tot)
PY
colourpct() { python3 "$FRAC_PY" "$FBW" "$FBH" "$1" "$2" "$3" "$4" "$5" "$6"; }
snap()      { cp "$HAMFB_FILE" "$WORK/$1.raw"; }

# ---- build ---------------------------------------------------------------
for t in wsysd:user/wsysd.ad \
         hamdesktop:user/hamdesktop.ad \
         hampanelscene:user/hampanelscene.ad \
         wsys_poke:tests/linux/wsys_poke.ad; do
    name="${t%%:*}"; src="${t#*:}"
    scripts/hamlinux_build.sh "$src" "$WORK/$name.elf" \
        >"$WORK/$name.build.log" 2>&1 || {
        bad "could not build $src"; tail -20 "$WORK/$name.build.log" >&2
        done_report; exit 1; }
done
ok "the compositor, the desktop and the panel all build"

# READS ONLY. See assertion 14.
winctl()  { "$WORK/wsys_poke.elf" "/dev/wsys/$1/ctl" 2>/dev/null; }
wstate()  { "$WORK/wsys_poke.elf" "/dev/wsys/wsysd/state" 2>/dev/null; }
# `focus <wid> windows N inputs N ...` -> the wid.
focuswid() { set -- $(wstate); echo "${2:-none}"; }

# ---- THE MOUSE -----------------------------------------------------------
: >"$WORK/input.evdev"
export HAMWSYSD_INPUT="$WORK/input.evdev"

EVDEV_PY="$WORK/evdev.py"
cat >"$EVDEV_PY" <<'PY'
import struct, sys
path, W, H = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
recs = []
for tok in sys.argv[4:]:
    kind, *a = tok.split(':')
    if kind == 'move':
        x, y = int(a[0]), int(a[1])
        recs += [(3, 0, x * 32768 // W), (3, 1, y * 32768 // H), (0, 0, 0)]
    elif kind == 'down':
        recs += [(1, 272, 1), (0, 0, 0)]
    elif kind == 'up':
        recs += [(1, 272, 0), (0, 0, 0)]
with open(path, 'ab') as f:
    for t, c, v in recs:
        f.write(struct.pack('<qqHHi', 0, 0, t, c, v))
PY
ev() { python3 "$EVDEV_PY" "$WORK/input.evdev" "$FBW" "$FBH" "$@"; }

click() {   # click <x> <y> — move, settle, press, hold, release
    ev "move:$1:$2"; sleep 0.4
    ev "down"; sleep 0.4
    ev "up";  sleep 1.2
}

# ---- the compositor ------------------------------------------------------
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

# ---- the desktop and the panel -------------------------------------------
"$WORK/hamdesktop.elf" </dev/null >"$WORK/hamdesktop.log" 2>&1 &
PIDS="$PIDS $!"
sleep 3
"$WORK/hampanelscene.elf" </dev/null >"$WORK/hampanelscene.log" 2>&1 &
PIDS="$PIDS $!"
sleep 3

# The top panel and the backdrop, both FOUND rather than guessed.
PANEL=""; PANELH=""; BACKDROP=""; BACKY=""; BACKH=""
for wid in $(seq 2 40); do
    line="$(winctl "$wid")"; [ -n "$line" ] || continue
    set -- $line
    [ "${4:-}" = "$FBW" ] || continue           # full width
    if [ "${5:-0}" -lt 200 ] && [ "${3:-1}" = "0" ]; then
        PANEL="$wid"; PANELH="${5:-}"
    elif [ "${5:-0}" -ge 200 ]; then
        BACKDROP="$wid"; BACKY="${3:-0}"; BACKH="${5:-0}"
    fi
done
if [ -n "$PANEL" ]; then
    ok "hampanelscene mapped a full-width top bar (wid $PANEL, height $PANELH)"
else
    bad "no full-width top bar -- there is no Applications button to click"
    sed 's/^/focus:      /' "$WORK/hampanelscene.log"
    done_report; exit 1
fi
if [ -n "$BACKDROP" ]; then
    ok "hamdesktop mapped a full-screen backdrop (wid $BACKDROP, ${FBW}x${BACKH} at y=$BACKY) -- there is a WALLPAPER to click away onto"
else
    bad "no full-screen backdrop -- 'click the wallpaper' has no named target, so this run cannot say WHERE the click landed"
    sed 's/^/focus:      /' "$WORK/hamdesktop.log"
    done_report; exit 1
fi

# Geometry, from the two programs themselves (identical to de_mouse_chrome.sh).
APPBTN_X=40; APPBTN_Y=13
CARDW=136
BODYCOL=f7f8fa
CARD_Y=$((PANELH + 34))
CARD_H=140

# ---- 5. THE CONTROL ------------------------------------------------------
snap before
got="$(colourpct 4 "$CARD_Y" $((CARDW - 8)) "$CARD_H" "$WORK/before.raw" "$BODYCOL")"
if [ "$got" -le 5 ]; then
    ok "control: with no click yet, the menu card is not drawn ($got% of the card column is the dropdown body)"
else
    bad "control: the dropdown body colour is already $got% of the card column before any click -- this rectangle is not measuring the menu"
fi

# ---- 6+7+8. OPEN THE MENU WITH A MOUSE -----------------------------------
click "$APPBTN_X" "$APPBTN_Y"
snap open
set -- $(winctl "$PANEL")
GROWNH="${5:-0}"
if [ "$GROWNH" -gt "$PANELH" ]; then
    ok "an EVDEV CLICK on the Applications button opened the menu (the panel window grew ${PANELH} -> ${GROWNH} px tall)"
else
    bad "the menu never opened under an evdev click -- the panel window is ${GROWNH} px. Nothing below this line can be answered"
    sed 's/^/focus:      /' "$WORK/hampanelscene.log" | tail -20
    done_report; exit 1
fi
got="$(colourpct 4 "$CARD_Y" $((CARDW - 8)) "$CARD_H" "$WORK/open.raw" "$BODYCOL")"
if [ "$got" -ge 60 ]; then
    ok "and the menu is PAINTED in the framebuffer ($got% of the card column is the dropdown body)"
else
    bad "the card column is only $got% of the dropdown body colour -- nothing was drawn"
fi
FOCUS_OPEN="$(focuswid)"
if [ "$FOCUS_OPEN" = "$PANEL" ]; then
    ok "and wsysd reports focus on the panel (wid $FOCUS_OPEN) -- the menu is open on the FOCUSED window, which is the precondition for a focus-out to dismiss it"
else
    bad "wsysd reports focus on wid $FOCUS_OPEN, not the panel ($PANEL) -- 'clicking away moves focus off the panel' is not a question this run can answer"
fi

# ---- 9+10+11. THE FIX: CLICK THE WALLPAPER -------------------------------
# A point that is inside the BACKDROP window and BELOW the grown panel, so we
# know exactly which window the press lands on. Kept clear of the desktop icon
# column on the left, and of the bottom edge where a second panel may sit.
AWAY_X=$((FBW * 3 / 4))
AWAY_Y=$((GROWNH + (FBH - GROWNH) / 2))
info "clicking the wallpaper at ($AWAY_X, $AWAY_Y) -- inside backdrop wid $BACKDROP, ${AWAY_Y} px is below the grown panel's ${GROWNH}"
click "$AWAY_X" "$AWAY_Y"
snap away
set -- $(winctl "$PANEL")
AWAYH="${5:-0}"
if [ "$AWAYH" = "$PANELH" ]; then
    ok "THE FIX: an EVDEV CLICK ON THE WALLPAPER closed the menu (the panel window is back to ${AWAYH} px, the bare bar)"
else
    bad "THE DEFECT: after clicking the wallpaper the panel window is still ${AWAYH} px tall, not ${PANELH} -- the open menu is still hanging over the desktop. wsysd told nobody that focus moved"
fi
got="$(colourpct 4 "$CARD_Y" $((CARDW - 8)) "$CARD_H" "$WORK/away.raw" "$BODYCOL")"
if [ "$got" -le 5 ]; then
    ok "and the card is GONE from the framebuffer ($got% of the card column is the dropdown body)"
else
    bad "THE DEFECT: the card is still $got% painted after the click on the wallpaper"
fi
# NOT an assertion about the fix — a DISCRIMINATOR, and it is worth being
# explicit about why. wsysd moved its private `focus_wid` to the backdrop long
# before this change existed; that is exactly the shape of the defect (it
# knew, and told nobody), so this line PASSES WITH THE FIX REVERTED and is
# supposed to. Its job is to separate the two ways assertion 9 could have gone
# green: focus landed on the window that was actually clicked, or the panel
# died / the click was swallowed and the short window means nothing.
FOCUS_AWAY="$(focuswid)"
if [ "$FOCUS_AWAY" = "$BACKDROP" ]; then
    ok "wsysd's own state moved focus panel($PANEL) -> backdrop($BACKDROP): the click landed on the window we aimed at (this is true with or without the fix -- knowing and not saying was the whole defect)"
else
    bad "wsysd reports focus on wid $FOCUS_AWAY after the wallpaper click, not the backdrop ($BACKDROP) -- the click did not land where this run thinks it did, so assertion 9 is measuring something else"
fi

# ---- 12. THE PANEL IS STILL LIVE -----------------------------------------
# A dismissal that leaves the panel unreachable is not a dismissal, it is a
# dead panel that happens to be short. Only askable if the menu DID dismiss:
# with the fix reverted the menu is still open here, so this click is the
# ordinary toggle closing it and "did it re-open" is not a question.
click "$APPBTN_X" "$APPBTN_Y"
set -- $(winctl "$PANEL")
REOPENH="${5:-0}"
if [ "$AWAYH" != "$PANELH" ]; then
    info "the away-click did not dismiss the menu, so 'is the panel still live afterwards' is not a question this run can answer (the click above just toggled the still-open menu shut: ${REOPENH} px)"
elif [ "$REOPENH" -gt "$PANELH" ]; then
    ok "the panel is still live after the away-click: the Applications button RE-OPENS the menu (grew to ${REOPENH} px)"
else
    bad "after the away-click the Applications button no longer opens the menu (${REOPENH} px) -- the dismiss left the panel unreachable"
fi

# ---- 13. NO REGRESSION ON THE PATH THAT ALREADY WORKED -------------------
# The Applications button is the menu's OWN PARENT and lives on the panel's
# own, already-focused window. set_focus must emit nothing at all here: a
# spurious `f out`/`f in` pair would fight the toggle.
click "$APPBTN_X" "$APPBTN_Y"
snap toggled
set -- $(winctl "$PANEL")
TOGGLEDH="${5:-0}"
if [ "$AWAYH" != "$PANELH" ] || [ "$REOPENH" -le "$PANELH" ]; then
    info "the menu never re-opened, so 'the button still closes it' is not a question this run can answer (panel is ${TOGGLEDH} px)"
elif [ "$TOGGLEDH" = "$PANELH" ]; then
    ok "and clicking the menu's OWN PARENT -- the Applications button, on the already-focused panel -- still closes it (back to ${TOGGLEDH} px): no focus event is emitted when focus does not change"
else
    bad "REGRESSION: a second click on the Applications button left the panel ${TOGGLEDH} px tall, not ${PANELH}. The dismiss-by-clicking-the-button-again path is broken"
fi

# ---- 14. THE RULE THIS GATE INHERITS -------------------------------------
if grep -vE '^[[:space:]]*#' "${BASH_SOURCE[0]}" \
        | grep -nE 'wsys_poke[^|]*/(event|pointer|keys)' >/dev/null; then
    bad "THIS GATE WRITES AN INPUT RING BY HAND -- it no longer proves a mouse reaches the chrome"
    grep -vE '^[[:space:]]*#' "${BASH_SOURCE[0]}" \
        | grep -nE 'wsys_poke[^|]*/(event|pointer|keys)' | sed 's/^/focus:      /'
else
    ok "every click in this file came from the evdev end: nothing here writes an event, pointer or keys ring"
fi

info "evdev delivered: $(stat -c%s "$WORK/input.evdev") bytes"
done_report
