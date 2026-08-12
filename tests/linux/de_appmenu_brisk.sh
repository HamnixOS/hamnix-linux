#!/usr/bin/env bash
# tests/linux/de_appmenu_brisk.sh — THE APPLICATIONS MENU, AS A PERSON USES IT.
#
# WHAT WAS ASKED FOR, AND WHAT WAS THERE
# ======================================
# The machine's owner asked for the MATE Brisk menu: a category SUBMENU like
# the panel's existing "Debian apps >", a SEARCH BOX that filters as you type,
# and a FAVOURITES section at the top showing what you have launched recently.
#
# Almost all of that was already written, in `user/hamappmenu.ad` and the pure
# model behind it, `lib/appmenucore.ad` — search row, recency section, one
# hover fly-out per category. It reached NOBODY. hamappmenu was in neither
# `scripts/hamlinux_image.sh`'s APPS nor `DESKTOP_CMDS` in
# `scripts/hamlinux_packages.py`, so `/bin/hamappmenu` did not exist on any
# machine, `hampanelscene._appmenu_available()` returned 0 on every boot, and
# the Applications button fell back to the panel's own flat dropdown. That is
# NORTH_STAR.md's worst bug shape said twice over: a program in the tree and in
# no ship vehicle, and a feature that was drawn correctly and could not run.
#
# AND ONE THING GENUINELY DID NOT WORK. The menu is a SEPARATE PROCESS spawned
# per click and killed on dismiss (`_am_close`). `amc_mark_launch` recorded the
# launch in module state microseconds before `sys_exit`, so the Favourites
# section was structurally incapable of ever holding anything: it laid out
# correctly, rendered correctly, and was empty on every open, forever. It is
# now persisted to `$HOME/.hamde/favourites` — the user's own home, resolved
# through `lib/homedir.ad`, NOT a fixed /tmp name (see private_ns.sh for what
# one of those cost two agents).
#
# WHAT THIS GATE MEASURES, AND HOW IT IS NOT ALLOWED TO CHEAT
# ===========================================================
# Every input below is SYNTHETIC EVDEV: 24-byte `struct input_event` records
# appended to the file named by HAMWSYSD_INPUT, byte for byte what
# /dev/input/eventN delivers, decoded by wsysd's own `pump_input`. The pointer
# is EV_ABS + BTN_LEFT; THE SEARCH BOX IS DRIVEN BY EV_KEY SCANCODES — KEY_C,
# KEY_A, KEY_L, KEY_BACKSPACE — which wsysd translates through its own keymap
# and routes to the FOCUSED window's keys ring. Nothing here writes a ring by
# hand; assertion 15 enforces that mechanically, exactly as
# tests/linux/de_mouse_chrome.sh does, and for the same reason: every gate
# that drove this chrome by poking a ring is why a completely missing input
# path went unnoticed for the life of the port.
#
# And every assertion is about PIXELS. "The list filtered" is not a log line
# here: it is the menu card no longer covering the wallpaper where its lower
# category buttons used to be, measured against a photograph of that same
# rectangle taken before the menu existed.
#
#   1. wsysd, hamdesktop, hampanelscene, hamappmenu and the ctl probe build.
#   2. wsysd took its input from this test's evdev file and opened no real
#      device on this host.
#   3. hampanelscene mapped a full-width top bar (the session is a desktop).
#   4. hamappmenu mapped ITS OWN window — not the panel's — 407 px wide, which
#      is the 208 px box plus the 200 px category fly-out band.
#   5. the menu card is PAINTED.
#   6. and it is painted as CATEGORY BUTTONS: the catbtn strip colour fills
#      the rows below the search box. This is the "submenu for categories".
#   7. CONTROL: with no launch history, row 1 is a category button and NOT a
#      Favourites header — so assertion 13 cannot be satisfied by a header
#      that was always there.
#   8. HOVERING a category with a real mouse opens its FLY-OUT to the right of
#      the box, and the parent button lights up. That is the `Debian apps >`
#      interaction the owner pointed at, one per category.
#   9. THE SEARCH BOX, TYPED INTO WITH REAL KEY SCANCODES: after "cal" the
#      card no longer covers the wallpaper where its 6th row was. The list
#      really shrank; nothing was merely recoloured.
#  10. and row 1 has become a section HEADER while the category BUTTONS are
#      gone — the filtered result is grouped, which is what MATE does.
#  11. BACKSPACE (KEY_BACKSPACE x3, real evdev) puts the whole list back.
#  12. a real click on the filtered app row LAUNCHES it and closes the menu.
#  13. FAVOURITES SURVIVE THE PROCESS: $HOME/.hamde/favourites names the
#      program that was launched, and a FRESHLY SPAWNED menu paints a
#      Favourites header in row 1 where assertion 7 measured a category
#      button. This is the assertion the feature did not have and could not
#      have passed before.
#  14. a menu that cannot open a window leaves $HOME/.hamde/appmenu.fault, the
#      signal hampanelscene reads to fall back to its own dropdown rather than
#      answer a click with nothing.
#  15. nothing in this file names an event, pointer or keys ring.
#
# THE ONE MOUNT THIS GATE ADDS, AND WHY
# =====================================
# `lib/homedir.ad` resolves $HOME through /env/HOME (a Hamnix-kernel file that
# does not exist on this line) and then /etc/passwd BY UID. Inside
# private_ns.sh's user namespace the euid is 0, so the resolved home is /root
# — which is owned by the real root outside the namespace and is therefore not
# writable, and a persistence test whose write silently fails would be exactly
# the success-shaped answer this file exists to avoid. So the gate mounts a
# FRESH TMPFS ON /root inside its own namespace: the account under test gets a
# real, writable, private home, the resolver is the shipped one, and nothing
# on the host is touched (the mount dies with the namespace, including on
# SIGKILL).
#
# Entirely offscreen (HAMFB_FILE + a file of evdev records): no VM, no
# display, no GPU. The software Vulkan ICD is forced because wsysd has a real
# Vulkan backend and this host's GPU belongs to someone.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

. tests/linux/private_ns.sh
priv_ns_reexec "$@"
. tests/linux/reap.sh

WORK="${BRISK_WORK:-$(mktemp -d -p "${TMPDIR:-/tmp}" briskmenu.XXXXXX)}"
mkdir -p "$WORK"
reap_track "$WORK/reaped"
KEEP="${BRISK_KEEP:-0}"
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
ok()   { echo "brisk: PASS $*"; pass=$((pass+1)); }
bad()  { echo "brisk: FAIL $*"; fail=$((fail+1)); }
info() { echo "brisk: INFO $*"; }
cleanup() { [ "$KEEP" = 1 ] || rm -rf "$WORK"; }
reap_on_exit cleanup
done_report() { echo "brisk: $pass passed, $fail failed"; [ "$fail" = 0 ]; }

# ---- a private, WRITABLE home for the account under test ------------------
# See THE ONE MOUNT THIS GATE ADDS above. mount(8) refuses for a non-root euid
# even holding CAP_SYS_ADMIN; mount(2) does not, so this goes through libc the
# same way private_ns.sh's own mounts do.
HOMEDIR="$(python3 - <<'PY'
import ctypes, os, sys
libc = ctypes.CDLL("libc.so.6", use_errno=True)
tgt = "/root"
if libc.mount(b"tmpfs", tgt.encode(), b"tmpfs", 0, None) != 0:
    e = ctypes.get_errno()
    sys.stderr.write("mount tmpfs on %s failed: %s\n" % (tgt, os.strerror(e)))
    print("")
else:
    os.chmod(tgt, 0o755)
    print(tgt)
PY
)"
if [ -n "$HOMEDIR" ] && [ -w "$HOMEDIR" ]; then
    info "the account under test has a private writable home at $HOMEDIR"
else
    bad "could not give the account under test a writable home -- the favourites assertions below could only ever measure a failed write, so they are not questions this run can answer"
    done_report; exit 1
fi
FAVFILE="$HOMEDIR/.hamde/favourites"
FAULTFILE="$HOMEDIR/.hamde/appmenu.fault"

# ---- the pixel probes -----------------------------------------------------
# One question each: what fraction of this rectangle is exactly this colour,
# and what fraction of it CHANGED between two frames.
FRAC_PY="$WORK/frac.py"
cat >"$FRAC_PY" <<'PY'
import sys
W, H = int(sys.argv[1]), int(sys.argv[2])
x, y, w, h = (int(v) for v in sys.argv[3:7])
d = open(sys.argv[7], 'rb').read()
c = sys.argv[8]
want = (int(c[0:2], 16), int(c[2:4], 16), int(c[4:6], 16))
tot = hit = 0
for j in range(y, min(y + h, H)):
    row = j * W * 4
    for i in range(x, min(x + w, W)):
        o = row + i * 4
        tot += 1
        if (d[o+2], d[o+1], d[o]) == want:
            hit += 1
print(0 if tot == 0 else hit * 100 // tot)
PY
colourpct() { python3 "$FRAC_PY" "$FBW" "$FBH" "$1" "$2" "$3" "$4" "$5" "$6"; }

DIFF_PY="$WORK/diff.py"
cat >"$DIFF_PY" <<'PY'
import sys
W, H = int(sys.argv[1]), int(sys.argv[2])
x, y, w, h = (int(v) for v in sys.argv[3:7])
a = open(sys.argv[7], 'rb').read()
b = open(sys.argv[8], 'rb').read()
tot = diff = 0
for j in range(y, min(y + h, H)):
    row = j * W * 4
    for i in range(x, min(x + w, W)):
        o = row + i * 4
        tot += 1
        if a[o:o+3] != b[o:o+3]:
            diff += 1
print(0 if tot == 0 else diff * 100 // tot)
PY
diffpct() { python3 "$DIFF_PY" "$FBW" "$FBH" "$1" "$2" "$3" "$4" "$5" "$6"; }
snap()    { cp "$HAMFB_FILE" "$WORK/$1.raw"; }

# ---- build ----------------------------------------------------------------
for t in wsysd:user/wsysd.ad \
         hamdesktop:user/hamdesktop.ad \
         hampanelscene:user/hampanelscene.ad \
         hamappmenu:user/hamappmenu.ad \
         cat:user/cat.ad; do
    name="${t%%:*}"; src="${t#*:}"
    scripts/hamlinux_build.sh "$src" "$WORK/$name.elf" \
        >"$WORK/$name.build.log" 2>&1 || {
        bad "could not build $src"; tail -25 "$WORK/$name.build.log" >&2
        done_report; exit 1; }
done
ok "the compositor, the desktop, the panel, the Applications menu and the ctl probe all build"

# READS ONLY -- the window table is a file and `cat` is how it is read (the
# idiom tests/linux/de_mouse_chrome.sh settled on, for the reasons its header
# gives about instruments that break what they measure).
winctl() { "$WORK/cat.elf" "/dev/wsys/$1/ctl" 2>/dev/null; }

# ---- THE INPUT DEVICE -----------------------------------------------------
# struct input_event { struct timeval (16 bytes), __u16 type, __u16 code,
# __s32 value } -- 24 bytes on x86-64. Absolute axes use the 0..32767 range
# QEMU advertises for virtio/usb-tablet, which is the branch wsysd takes for
# EV_ABS. `key` emits EV_KEY press+release for a Linux KEY_* scancode: that is
# the whole of what a keyboard is, and it is how the search box is typed into
# below.
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
    elif kind == 'key':                       # key:<KEY_* scancode>
        recs += [(1, int(a[0]), 1), (0, 0, 0), (1, int(a[0]), 0), (0, 0, 0)]
with open(path, 'ab') as f:
    for t, c, v in recs:
        f.write(struct.pack('<qqHHi', 0, 0, t, c, v))
PY
ev() { python3 "$EVDEV_PY" "$WORK/input.evdev" "$FBW" "$FBH" "$@"; }

hover() { ev "move:$1:$2"; sleep 0.9; }
click() { ev "move:$1:$2"; sleep 0.4; ev "down"; sleep 0.4; ev "up"; sleep 1.0; }
# One keystroke at a time, with a settle: the menu re-runs the filter and
# repaints per key, and the point is to watch it do that.
key()   { ev "key:$1"; sleep 0.5; }

KEY_C=46; KEY_A=30; KEY_L=38; KEY_BACKSPACE=14

# ---- the session ----------------------------------------------------------
"$WORK/wsysd.elf" </dev/null >"$WORK/wsysd.log" 2>&1 &
reap_add $!
for _ in $(seq 1 60); do [ -s "$HAMFB_FILE" ] && break; sleep 0.1; done
[ -s "$HAMFB_FILE" ] || { bad "wsysd never produced a framebuffer"
                          cat "$WORK/wsysd.log"; done_report; exit 1; }
if grep -q "input from $WORK/input.evdev only" "$WORK/wsysd.log"; then
    ok "wsysd took its input from this test's evdev file and opened no real device on this host"
else
    bad "wsysd did not honour HAMWSYSD_INPUT -- it may be reading this host's keyboard"
fi

"$WORK/hamdesktop.elf" </dev/null >"$WORK/hamdesktop.log" 2>&1 &
reap_add $!
sleep 3
"$WORK/hampanelscene.elf" </dev/null >"$WORK/hampanelscene.log" 2>&1 &
reap_add $!
sleep 3

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
    ok "hampanelscene mapped a full-width top bar (wid $PANEL, height $PANELH) -- this is a desktop session, not a bare compositor"
else
    bad "no full-width top bar -- the session is not a desktop and nothing below is a question this run can answer"
    sed 's/^/brisk:      /' "$WORK/hampanelscene.log"
    done_report; exit 1
fi

# THE WALLPAPER, PHOTOGRAPHED BEFORE THE MENU EXISTS. Assertion 9 is measured
# against this: "the card stopped covering row 6" is only meaningful against
# what row 6 looks like with no card over it at all.
sleep 1
snap desktop

# ---- the menu ------------------------------------------------------------
# Spawned exactly as hampanelscene's _launch_appmenu spawns it, argv and all:
# `/bin/hamappmenu -self`, which forces self-allocation of an owned window
# instead of consulting /dev/wsys/self (whose ancestor walk-up would hand back
# the PANEL's wid -- the "Applications menu doesn't open" bug the flag exists
# for). The panel's own click-to-spawn path needs /bin/hamappmenu to EXIST,
# which is what this change puts there and what
# tests/linux/channel_covers_image.sh now enforces; the panel's fallback when
# it does not is what tests/linux/de_mouse_chrome.sh has always measured.
start_menu() {
    "$WORK/hamappmenu.elf" -self </dev/null >"$WORK/menu.$1.log" 2>&1 &
    MENU_PID=$!
    reap_add "$MENU_PID"
    sleep 3
}
start_menu 1

# hamappmenu places itself at (8,28): the box is AMC_BOX_W = 208 wide and the
# window is grown to 208-1+AMC_CHILD_W = 407 so the category fly-out is
# contained. Rows are AMC_ROW_H = 20 tall, row 0 is the search box.
MX=8; MY=28; BOXW=208; ROWH=20; CHILDW=200
row_y() { echo $((MY + $1 * ROWH + 2)); }
ROWX=$((MX + 4)); ROWW=$((BOXW - 20))
BODY=f7f8fa; CATBTN=eef0f3; HDR=eceef2; SEL=3584e4

MENUWID=""; MENUW=""; MENUH=""
for wid in $(seq 2 40); do
    [ "$wid" = "$PANEL" ] && continue
    line="$(winctl "$wid")"; [ -n "$line" ] || continue
    set -- $line
    [ "${2:-}" = "$MX" ] && [ "${3:-}" = "$MY" ] || continue
    MENUWID="$wid"; MENUW="${4:-}"; MENUH="${5:-}"
done
if [ "${MENUW:-0}" = $((BOXW - 1 + CHILDW)) ]; then
    ok "hamappmenu mapped its OWN window at ($MX,$MY), ${MENUW}x${MENUH} -- the 208 px menu box plus the 200 px category fly-out band, not the panel's window"
else
    bad "hamappmenu did not map its own window: found '${MENUWID:-none}' ${MENUW:-?}x${MENUH:-?} at ($MX,$MY), wanted $((BOXW - 1 + CHILDW)) wide"
    sed 's/^/brisk:      /' "$WORK/menu.1.log" | tail -20
    done_report; exit 1
fi

snap open
got="$(colourpct $((MX + 2)) $((MY + 2)) $((BOXW - 4)) $((ROWH - 4)) "$WORK/open.raw" ffffff)"
if [ "$got" -ge 50 ]; then
    ok "the menu card is PAINTED and row 0 is the white SEARCH FIELD ($got% of it is the field colour)"
else
    bad "row 0 is only $got% search-field colour -- either nothing was drawn or there is no search box"
fi

R1Y="$(row_y 1)"
cat1="$(colourpct "$ROWX" "$R1Y" "$ROWW" $((ROWH - 4)) "$WORK/open.raw" "$CATBTN")"
hdr1="$(colourpct "$ROWX" "$R1Y" "$ROWW" $((ROWH - 4)) "$WORK/open.raw" "$HDR")"
if [ "$cat1" -ge 40 ]; then
    ok "the rows under the search box are CATEGORY BUTTONS ($cat1% of row 1 is the category-button strip) -- one submenu per category, the shape the panel's 'Debian apps >' has"
else
    bad "row 1 is only $cat1% category-button strip -- the menu is not drawing category submenus"
fi
if [ "$hdr1" -le 5 ]; then
    ok "CONTROL: with no launch history there is NO Favourites header in row 1 ($hdr1% header strip) -- assertion 13 cannot be satisfied by a header that was always there"
else
    bad "CONTROL: row 1 is already $hdr1% header strip before anything has ever been launched"
fi

# ---- 8. THE CATEGORY FLY-OUT, OPENED BY A REAL MOUSE ---------------------
hover $((MX + 90)) $((MY + ROWH + 10))
snap flyout
FLYX=$((MX + BOXW - 1))
fly="$(colourpct $((FLYX + 6)) $((MY + ROWH + 4)) $((CHILDW - 12)) 12 "$WORK/flyout.raw" "$BODY")"
lit="$(colourpct "$ROWX" "$R1Y" 40 $((ROWH - 6)) "$WORK/flyout.raw" "$SEL")"
if [ "$fly" -ge 40 ] && [ "$lit" -ge 40 ]; then
    ok "HOVERING a category with a real mouse opened its FLY-OUT to the right of the box ($fly% of the fly-out band is menu card) and lit the parent button ($lit% accent)"
else
    bad "no category fly-out: the band right of the box is $fly% card and the parent button is $lit% lit"
fi

# ---- 9+10. THE SEARCH BOX, TYPED INTO WITH REAL KEY SCANCODES ------------
# Focus first, with a press on the search row itself: the compositor gates the
# keyboard on focus (wsysd's route_key), and a press on row 0 is the one click
# in this menu that neither launches anything nor dismisses it. It also closes
# the fly-out opened above, which is the correct MATE behaviour on moving off
# a category.
click $((MX + 120)) $((MY + 10))
sleep 0.5
snap focused
# The 6th row: the last category button in the unfiltered list. This is the
# rectangle assertion 9 is about.
R6Y="$(row_y 6)"
covered="$(diffpct "$ROWX" "$R6Y" "$ROWW" $((ROWH - 4)) "$WORK/desktop.raw" "$WORK/focused.raw")"
if [ "$covered" -ge 80 ]; then
    ok "before typing, the menu card covers the wallpaper down to row 6 ($covered% of that rectangle differs from the bare desktop)"
else
    bad "the card does not reach row 6 ($covered% differs from the bare desktop) -- assertion 9 would have nothing to measure"
fi

key $KEY_C; key $KEY_A; key $KEY_L
snap filtered
still="$(diffpct "$ROWX" "$R6Y" "$ROWW" $((ROWH - 4)) "$WORK/desktop.raw" "$WORK/filtered.raw")"
if [ "$covered" -lt 80 ]; then
    bad "the card never reached row 6, so 'typing shrank it' is not a question this run can answer"
elif [ "$still" -le 2 ]; then
    ok "TYPING 'cal' AS REAL EVDEV KEYSTROKES FILTERED THE LIST: row 6 is back to the bare wallpaper, pixel for pixel ($covered% different before, $still% after) -- the menu card actually shrank"
else
    bad "THE DEFECT: after three real KEY events the card still covers row 6 ($still% of it differs from the bare desktop) -- the search box did not filter"
    sed 's/^/brisk:      /' "$WORK/menu.1.log" | tail -20
fi

fcat1="$(colourpct "$ROWX" "$R1Y" "$ROWW" $((ROWH - 4)) "$WORK/filtered.raw" "$CATBTN")"
fhdr1="$(colourpct "$ROWX" "$R1Y" "$ROWW" $((ROWH - 4)) "$WORK/filtered.raw" "$HDR")"
if [ "$fhdr1" -ge 40 ] && [ "$fcat1" -le 5 ]; then
    ok "and the filtered result is GROUPED, MATE-style: row 1 is now a section header ($fhdr1%) and the category buttons are gone ($fcat1%, was $cat1%)"
else
    bad "the filtered list is not grouped: row 1 is $fhdr1% header and $fcat1% category button"
fi

# ---- 11. AND BACKSPACE PUTS IT BACK --------------------------------------
key $KEY_BACKSPACE; key $KEY_BACKSPACE; key $KEY_BACKSPACE
snap unfiltered
back="$(diffpct "$ROWX" "$R6Y" "$ROWW" $((ROWH - 4)) "$WORK/desktop.raw" "$WORK/unfiltered.raw")"
bcat="$(colourpct "$ROWX" "$R1Y" "$ROWW" $((ROWH - 4)) "$WORK/unfiltered.raw" "$CATBTN")"
if [ "$back" -ge 80 ] && [ "$bcat" -ge 40 ]; then
    ok "three real BACKSPACE keystrokes restored the whole list (row 6 covered again at $back%, row 1 back to a category button at $bcat%) -- a filter that cannot be undone would be a stuck menu"
else
    bad "backspace did not restore the list: row 6 is $back% covered and row 1 is $bcat% category button"
fi

# ---- 12. A CLICK THAT LAUNCHES -------------------------------------------
# Filter down to one app again and click its row. Filtered layout is
# search(0) / section header(1) / the app(2).
key $KEY_C; key $KEY_A; key $KEY_L
sleep 0.5
click $((MX + 110)) $((MY + 2 * ROWH + 10))
sleep 2
snap launched
gone="$(diffpct "$ROWX" "$(row_y 1)" "$ROWW" $((ROWH - 4)) "$WORK/desktop.raw" "$WORK/launched.raw")"
if [ "$gone" -le 2 ]; then
    ok "a real click on the app row LAUNCHED it and the menu closed -- its card is gone from the framebuffer, the wallpaper is back pixel for pixel"
else
    bad "after clicking the app row the menu is still on screen ($gone% of row 1 still differs from the bare desktop)"
    sed 's/^/brisk:      /' "$WORK/menu.1.log" | tail -20
fi

# ---- 13. FAVOURITES SURVIVE THE PROCESS ----------------------------------
if [ -s "$FAVFILE" ] && grep -q '^/bin/calculator$' "$FAVFILE"; then
    ok "the launch was written to the user's OWN home ($FAVFILE names $(head -1 "$FAVFILE")) -- not to a fixed /tmp name every account and every concurrent session would share"
else
    bad "nothing was persisted: $FAVFILE is $( [ -e "$FAVFILE" ] && echo "'$(cat "$FAVFILE" 2>/dev/null | tr '\n' ' ')'" || echo absent )"
fi

start_menu 2
snap reopened
rhdr="$(colourpct "$ROWX" "$R1Y" "$ROWW" $((ROWH - 4)) "$WORK/reopened.raw" "$HDR")"
rcat="$(colourpct "$ROWX" "$R1Y" "$ROWW" $((ROWH - 4)) "$WORK/reopened.raw" "$CATBTN")"
if [ "$hdr1" -gt 5 ]; then
    bad "row 1 was already a header before anything was launched, so 'the Favourites section appeared' is not a question this run can answer"
elif [ "$rhdr" -ge 40 ] && [ "$rcat" -le 5 ]; then
    ok "A FRESHLY SPAWNED MENU SHOWS THE FAVOURITES SECTION AT THE TOP: row 1 is a header ($rhdr%, was $hdr1% before the launch) where assertion 7 measured a category button ($rcat%, was $cat1%). The recency list outlived the process that recorded it."
else
    bad "THE DEFECT: a new menu shows no Favourites section -- row 1 is $rhdr% header and $rcat% category button, unchanged from the run with no history. The recency list died with the process that recorded it."
    sed 's/^/brisk:      /' "$WORK/menu.2.log" | tail -20
fi
kill "$MENU_PID" 2>/dev/null
sleep 1

# ---- 14. AND WHEN THE MENU CANNOT OPEN A WINDOW --------------------------
# The panel points its Applications button at /bin/hamappmenu whenever that
# file exists -- which, now that it ships, is every machine. The remaining way
# for the button to answer a click with nothing is a menu that starts and
# cannot get a window. Here that is forced by pointing it at a wsys segment
# under a directory that does not exist, so /dev/wsys is unreachable. It must
# leave the fault marker the panel reads.
rm -f "$FAULTFILE"
( export HAMWSYS="$WORK/nodir/wsys.shm"
  export HAMWSYS_BB="$WORK/nodir/wsys.bb"
  export HAMWSYS_IMG="$WORK/nodir/wsys.img"
  "$WORK/hamappmenu.elf" -self </dev/null >"$WORK/menu.fault.log" 2>&1 )
rc=$?
if [ -f "$FAULTFILE" ] && [ "$rc" != 0 ]; then
    ok "a menu that cannot open a window exits $rc and leaves $FAULTFILE -- the signal hampanelscene's _appmenu_available reads to fall back to the dropdown it draws itself, instead of a button that answers a click with nothing"
else
    bad "a menu that could not open a window exited $rc and left no fault marker at $FAULTFILE -- the panel has no way to know its Applications button is dead"
    sed 's/^/brisk:      /' "$WORK/menu.fault.log" | tail -10
fi

# ---- 15. THE RULE THIS GATE KEEPS ---------------------------------------
# Same rule, and for the same reason, as tests/linux/de_mouse_chrome.sh
# assertion 12: a gate that drives the chrome by writing an event/pointer/keys
# ring as the host owner is not measuring input delivery at all, and that
# shortcut is why a completely missing pointer path survived the whole port.
# Reading one is as disqualifying as writing one. The regex is built in a
# variable so its own uses cannot match it.
RING_RE='/dev/wsys/[^ ]*/(event|pointer|keys)'
if grep -vE '^[[:space:]]*#' "${BASH_SOURCE[0]}" \
        | grep -nE "$RING_RE" >/dev/null; then
    bad "THIS GATE TOUCHES AN INPUT RING BY HAND -- its clicks and keystrokes no longer prove a real device reaches the menu"
    grep -vE '^[[:space:]]*#' "${BASH_SOURCE[0]}" \
        | grep -nE "$RING_RE" | sed 's/^/brisk:      /'
else
    ok "every click and every keystroke in this file came from the evdev end: nothing here names an event, pointer or keys ring"
fi

if [ "${BRISK_SHOT:-}" != "" ]; then
    python3 - "$WORK" "$FBW" "$FBH" "$BRISK_SHOT" <<'PY'
import sys, zlib, struct
work, W, H, out = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
d = open(work + "/reopened.raw", "rb").read()
rows = b"".join(b"\x00" + bytes(
    bb for i in range(W) for bb in (d[(j*W+i)*4+2], d[(j*W+i)*4+1], d[(j*W+i)*4]))
    for j in range(H))
def chunk(t, b):
    c = t + b
    return struct.pack(">I", len(b)) + c + struct.pack(">I", zlib.crc32(c))
png = (b"\x89PNG\r\n\x1a\n"
       + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(rows, 6)) + chunk(b"IEND", b""))
open(out, "wb").write(png)
print("wrote " + out)
PY
    info "screenshot of the finished menu written to $BRISK_SHOT"
fi

info "input delivered: $(stat -c%s "$WORK/input.evdev") bytes of evdev records"
done_report
