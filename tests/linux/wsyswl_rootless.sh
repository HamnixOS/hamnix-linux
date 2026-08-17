#!/usr/bin/env bash
#
# REGISTRATION, 2026-08-17. Until this date scripts/test_gate_registration.sh
# globbed only scripts/test_*.sh, so this directory was invisible to the gate
# against unregistered gates and every file in it read as coverage without
# being coverage. This gate is ON-DEMAND: not in ci_battery_manifest.txt
# because it was MEASURED on 2026-08-17 and exited 1 in 27 s on a host with the channel and the image built, so it does not pass unattended here yet.
#
#
# tests/linux/wsyswl_rootless.sh — IS AN X WINDOW A WINDOW ON THIS DESKTOP?
#
#   X11 clients -> Xwayland -rootless -> wsyswl + its XWM -> /dev/wsys
#                                     -> wsysd -> /dev/fb
#
# THE QUESTION, and it is not the one the last two passes asked.
# ==============================================================
# `wsyswl_shared_fate.sh` next door asks "when one client runs out of
# something, who else stops?" and answered it: nobody who should not, and
# rootless would not have changed that anyway, because every limit in
# `user/wsyswl.ad` is per CONNECTION and Xwayland opens exactly one either way.
# That is settled and it is not re-litigated here.
#
# This asks the question that survived, which is the project's own:
#
#     Can the Hamnix desktop MOVE ONE X WINDOW?
#
# Under rootful Xwayland it cannot, and the reason is not a bug: the entire X
# session -- every client, the window manager, its frames, Steam and all -- is
# ONE wl_surface and therefore ONE wsys window. `windows_high_water 1` for a
# whole Steam session, measured. wsysd can move that rectangle. It cannot move
# a window inside it, because there is no window inside it to move, and that
# is why a namespace needs `jwm` running inside it while Firefox -- a native
# Wayland client -- gets one wsys window per xdg_toplevel and needs nothing.
#
# So the property under test is stated as pixels and as files, not as a count:
#
#   1. TWO X CLIENTS ARE TWO WSYS WINDOWS. Two wids under /dev/wsys, each with
#      its own geometry, from ONE X display -- and `windows_high_water` above
#      one, which the rootful arm below cannot reach however many clients it
#      carries.
#
#   2. AND THEY MOVE INDEPENDENTLY. Move one with the compositor's own verb,
#      the same one the desktop uses, and require that the OTHER one does not
#      move -- in the window table AND in the framebuffer. A pair of window
#      records that both point at the same pixels would pass part 1 and is
#      exactly the success-shaped answer NORTH_STAR.md is about.
#
#   3. THE ROOTFUL ARM IS THE CONTROL, in the same script and on the same
#      compositor: the same two clients on a rootful Xwayland are ONE window.
#      That is the difference this whole piece of work buys, measured rather
#      than asserted.
#
#   4. NOTHING IS ADVERTISED THAT IS NOT BACKED. With WSYSWL_XWM unset the
#      compositor must NOT offer `xwayland_shell_v1`: a client that binds it
#      hands over surfaces that can never be paired with an X window, which is
#      a rootless display that comes up managed and empty with no error
#      anywhere. The negative is the load-bearing half.
#
#   5. AND ALL OF IT ON THE ACTUAL DESKTOP. This used to compose `wsysd` plus
#      the two clients and nothing else, so it proved the windows EXIST on a
#      bare compositor and said nothing about whether they WORK on the desktop.
#      The machine owner spotted that from the screenshot it produced --
#      docs/screenshots/linux/rootless-two-x-windows.png had two X windows on
#      a black screen: no wallpaper, no icons, no panel. A window that is
#      first-class on an empty compositor and buried by the backdrop on a real
#      one is exactly the success-shaped answer NORTH_STAR.md is about, and
#      that was not a hypothetical: ea23c834 fixed a bug where hamdesktop's
#      backdrop painted over EVERY ordinary client window for the whole port.
#      So the real DE is composed here -- the same composition
#      tests/linux/wsys_desktop_z.sh uses, `wsysd` + `hamdesktop` +
#      `hampanelscene` -- and an X window out of a namespace is required to be
#      a first-class window ON it: over the wallpaper, under the panel, and in
#      the taskbar list BY ITS X NAME.
#
# Offscreen throughout: HAMFB_FILE for the framebuffer and the HOST's Xwayland,
# so it touches no display, needs no VM, and takes about a minute.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

# THE MACHINE THIS RUNS ON IS NOT SCRATCH. This gate starts hamdesktop and
# hampanelscene, and those write /tmp/hamdesktop-wp.status, /tmp/.hamdesktop.src,
# /tmp/hamnix-panel.health and /tmp/hamnix-panel-drop under names compiled into
# the binaries -- the same fixed names this machine's own desktop reads. It also
# runs a Wayland compositor, whose socket lands in $XDG_RUNTIME_DIR. So it goes
# in a namespace where all of those are a fresh tmpfs; see private_ns.sh for the
# incident that bought this. It must come before anything that makes a file
# under /tmp, $WORK included.
. tests/linux/private_ns.sh
priv_ns_reexec "$@"

WORK="${RLESS_WORK:-$(mktemp -d -p "${TMPDIR:-/tmp}" rless.XXXXXX)}"
mkdir -p "$WORK"
GEOM="${HAMFB_GEOM:-1280x800}"
KEEP="${RLESS_KEEP:-0}"
SHOT="${RLESS_SHOT:-}"
# PRIVATE, all three. The wsys segment, the v2 backbuffer and the named-image
# segment each default to ONE FILE PER HOST with slots keyed by wid and no
# owner, so two runs hand each other stale slots -- an hour was once spent on
# a compositor bug that was a previous run's backbuffer.
export HAMWSYS="$WORK/wsys.shm"
export HAMWSYS_BB="$WORK/wsys.bb"
export HAMWSYS_IMG="$WORK/wsys.img"
export HAMFB_FILE="$WORK/fb.raw"
export HAMFB_GEOM="$GEOM"
# wsysd arms a real Vulkan backend on real silicon and this host's GPU belongs
# to someone. Software ICD, always, for anything offscreen.
[ -r /usr/share/vulkan/icd.d/lvp_icd.json ] && \
    export VK_ICD_FILENAMES="${VK_ICD_FILENAMES:-/usr/share/vulkan/icd.d/lvp_icd.json}"
# ... and the same rule for Xwayland, which probes GBM on the host's real
# card before it falls back to shm.
export XWAYLAND_NO_GLAMOR=1
FBW="${GEOM%x*}"; FBH="${GEOM#*x}"

pass=0; fail=0
ok()   { echo "rless: PASS $*"; pass=$((pass+1)); }
bad()  { echo "rless: FAIL $*"; fail=$((fail+1)); }
info() { echo "rless: INFO $*"; }

# Reported, not checked: priv_ns_reexec has already REFUSED to get this far if
# the namespace was not in place. Deliberately unscored, so the gate's count
# stays about rootless X and does not move for an unrelated reason.
info "$(priv_ns_describe)"

KIDS=""; XWPID=""; XWPID2=""; WLPID=""; WSYSDPID=""
cleanup() {
    for p in $KIDS $XWPID $XWPID2 $WLPID $WSYSDPID; do
        [ -n "${p:-}" ] && kill "$p" 2>/dev/null
    done
    sleep 0.4
    for p in $KIDS $XWPID $XWPID2 $WLPID $WSYSDPID; do
        [ -n "${p:-}" ] && kill -9 "$p" 2>/dev/null
    done
    [ "$KEEP" = 1 ] || rm -rf "$WORK"
}
trap cleanup EXIT
# A bare EXIT trap does not run when the shell is killed by a signal, so a
# gate stopped by `timeout` (TERM) or ^C (INT) skipped its cleanup entirely.
# Re-exit on those, which makes the EXIT trap above run on every path out.
trap 'exit 130' INT TERM HUP

for t in Xwayland xterm xwininfo python3; do
    command -v "$t" >/dev/null || { echo "need $t on the host" >&2; exit 1; }
done

for t in wsysd:user/wsysd.ad wsyswl:user/wsyswl.ad \
         hamdesktop:user/hamdesktop.ad hampanelscene:user/hampanelscene.ad \
         wsys_poke:tests/linux/wsys_poke.ad; do
    name="${t%%:*}"; src="${t#*:}"
    scripts/hamlinux_build.sh "$src" "$WORK/$name.elf" >"$WORK/$name.build.log" 2>&1 || {
        echo "FAIL could not build $src" >&2; tail -20 "$WORK/$name.build.log" >&2; exit 1; }
done
ok "the compositor, the Wayland server, the desktop, the panel and the window probe all build"

# The window table, straight out of the device every client reads:
#   "<wid> <x> <y> <w> <h> <z> <decorate> <visible> <proto> ..."
poke()     { "$WORK/wsys_poke.elf" "$@" 2>/dev/null; }
winctl()   { poke "/dev/wsys/$1/ctl"; }
st()   { sleep 1; sed -n "s/^$1 \([0-9-]*\)\$/\1/p" "$STATE" 2>/dev/null | tail -1; }

# What fraction of a rectangle is exactly one colour. Sampled every other
# pixel in both directions, which is plenty for "is this window here".
FRAC_PY="$WORK/frac.py"
cat >"$FRAC_PY" <<'PY'
import sys
W, H = int(sys.argv[1]), int(sys.argv[2])
x, y, w, h = (int(v) for v in sys.argv[3:7])
d = open(sys.argv[7], 'rb').read()
c = sys.argv[8]
want = (int(c[0:2], 16), int(c[2:4], 16), int(c[4:6], 16))
tot = hit = 0
for j in range(max(y, 0), min(y + h, H), 2):
    row = j * W * 4
    for i in range(max(x, 0), min(x + w, W), 2):
        o = row + i * 4
        if o + 3 > len(d):
            continue
        tot += 1
        if (d[o+2], d[o+1], d[o]) == want:
            hit += 1
print(0 if tot == 0 else hit * 100 // tot)
PY
colourpct() { python3 "$FRAC_PY" "$FBW" "$FBH" "$1" "$2" "$3" "$4" "$5" "$6"; }

# ... and "how much of this rectangle is UNCHANGED between two frames", which
# is how "the wallpaper is still there" is asked without knowing what the
# wallpaper looks like.
SAME_PY="$WORK/same.py"
cat >"$SAME_PY" <<'PY'
import sys
W, H = int(sys.argv[1]), int(sys.argv[2])
x, y, w, h = (int(v) for v in sys.argv[3:7])
a = open(sys.argv[7], 'rb').read()
b = open(sys.argv[8], 'rb').read()
tot = hit = 0
for j in range(max(y, 0), min(y + h, H), 2):
    row = j * W * 4
    for i in range(max(x, 0), min(x + w, W), 2):
        o = row + i * 4
        if o + 3 > len(a) or o + 3 > len(b):
            continue
        tot += 1
        if a[o:o+3] == b[o:o+3]:
            hit += 1
print(0 if tot == 0 else hit * 100 // tot)
PY
samepct() { python3 "$SAME_PY" "$FBW" "$FBH" "$1" "$2" "$3" "$4" "$5" "$6"; }

"$WORK/wsysd.elf" </dev/null >"$WORK/wsysd.log" 2>&1 &
WSYSDPID=$!
for _ in $(seq 1 60); do [ -s "$HAMFB_FILE" ] && break; sleep 0.1; done
[ -s "$HAMFB_FILE" ] || { bad "wsysd never produced a framebuffer"; cat "$WORK/wsysd.log"; exit 1; }

# ---------------------------------------------------------------------------
# THE DESKTOP, BEFORE ANY X EXISTS. Everything below happens ON this, not on a
# bare compositor, because "an X window is a window" and "an X window is a
# window on the Hamnix desktop" are different claims and only the second one
# is the project's. The composition is the one wsys_desktop_z.sh uses.
# ---------------------------------------------------------------------------
"$WORK/hamdesktop.elf" </dev/null >"$WORK/hamdesktop.log" 2>&1 &
DEPIDS="$!"
sleep 3
"$WORK/hampanelscene.elf" </dev/null >"$WORK/hampanelscene.log" 2>&1 &
DEPIDS="$DEPIDS $!"
KIDS="$KIDS $DEPIDS"
sleep 3
cp "$HAMFB_FILE" "$WORK/desktop.raw"          # the desktop with nothing on it

# Find the backdrop and the bar the way anything else would -- no wid is
# hardcoded. The backdrop is the full-screen undecorated visible window; the
# bar is the full-width window nearest the top that is not it.
BACKDROP=""; PANELZ=""; PANELY=""; PANELH=""
for wid in $(seq 2 40); do
    line="$(winctl "$wid")"
    [ -n "$line" ] || continue
    set -- $line
    [ "${8:-0}" = 1 ] || continue                       # visible
    [ "${4:-}" = "$FBW" ] || continue                   # full width
    if [ "${5:-}" = "$FBH" ] && [ "${7:-}" = "0" ]; then
        BACKDROP="$1"; continue
    fi
    if [ "${5:-0}" -lt 200 ]; then                      # a bar, not a window
        if [ -z "$PANELY" ] || [ "${3:-0}" -lt "$PANELY" ]; then
            PANELZ="${6:-}"; PANELY="${3:-}"; PANELH="${5:-}"
        fi
    fi
done
[ -n "$BACKDROP" ] \
    && ok "hamdesktop mapped its full-screen backdrop (wid $BACKDROP) -- there is a desktop here" \
    || bad "hamdesktop never mapped a backdrop; the desktop assertions below cannot be asked"
if [ -n "$PANELZ" ]; then
    ok "hampanelscene mapped its bar at y $PANELY, height $PANELH, z $PANELZ"
else
    bad "hampanelscene mapped no bar"
    PANELZ=100; PANELY=0; PANELH=26
fi

DISPNUM="${RLESS_DISPLAY:-:84}"
XSOCK="/tmp/.X11-unix/X${DISPNUM#:}"
[ -e "$XSOCK" ] && { echo "display $DISPNUM is already in use; set RLESS_DISPLAY" >&2; exit 1; }

WSYSWL_XWM="$XSOCK" "$WORK/wsyswl.elf" "$WORK/wayland-0" </dev/null \
    >"$WORK/wsyswl.log" 2>&1 &
WLPID=$!
for _ in $(seq 1 40); do [ -S "$WORK/wayland-0" ] && break; sleep 0.1; done
[ -S "$WORK/wayland-0" ] || { bad "wsyswl never created its socket"; cat "$WORK/wsyswl.log"; exit 1; }
STATE="$WORK/wsyswl-state"
export XDG_RUNTIME_DIR="$WORK"
export WAYLAND_DISPLAY=wayland-0
ok "wsyswl is listening, and was told to manage the X display at $XSOCK"

# ---------------------------------------------------------------------------
# 0. THE NEGATIVE FIRST. wsyswl was started WITH an XWM, so it may advertise
#    xwayland_shell_v1 -- and the rootful compositor beside it may not. Both
#    halves are asserted, because "the global is there" is only evidence if
#    "the global is absent when it would be a lie" is also true.
# ---------------------------------------------------------------------------
echo "rless: === 0. is xwayland_shell_v1 advertised, and only when it is backed?"
ADV="$WORK/adv"
mkdir -p "$ADV"
# HAMWSYS is SHARED with the running wsysd on purpose: wsyswl reads the screen
# size out of /dev/wsys/screen before it will listen at all, and refuses to
# serve without one. Only the backbuffer and image segments are private, and
# this server never opens a window anyway -- it exists for one get_registry.
HAMWSYS_BB="$ADV/wsys.bb" HAMWSYS_IMG="$ADV/wsys.img" \
    "$WORK/wsyswl.elf" "$ADV/wayland-0"</dev/null >"$ADV/wsyswl.log" 2>&1 &
BAREPID=$!
for _ in $(seq 1 40); do [ -S "$ADV/wayland-0" ] && break; sleep 0.1; done
globals_of() {
    # One Wayland client, one get_registry, print every global's name. libwayland
    # is not available here, so this is 40 lines of wire protocol and no more.
    python3 - "$1" <<'PY'
import socket, struct, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(3)
s.connect(sys.argv[1])
# A Wayland message is object id (4), then size<<16 | opcode (4), then args.
# wl_display@1.get_registry(new id 2)  -- opcode 1, one new_id argument
s.send(struct.pack('<III', 1, (12 << 16) | 1, 2))
# wl_display@1.sync(new id 3) -- opcode 0; its callback.done is the fence that
# says "every global has been sent", so this needs no timeout to be correct.
s.send(struct.pack('<III', 1, (12 << 16) | 0, 3))
buf = b''
names = []
try:
    while True:
        b = s.recv(65536)
        if not b:
            break
        buf += b
        done = False
        while len(buf) >= 8:
            obj, sz_op = struct.unpack('<II', buf[:8])
            size, op = sz_op >> 16, sz_op & 0xffff
            if size < 8 or len(buf) < size:
                break
            body = buf[8:size]
            buf = buf[size:]
            if obj == 2 and op == 0 and len(body) >= 8:
                ln = struct.unpack('<I', body[4:8])[0]
                names.append(body[8:8 + ln - 1].decode('ascii', 'replace'))
            if obj == 3:
                done = True
        if done:
            break
except Exception:
    pass
print('\n'.join(names))
PY
}
XWM_GLOBALS="$(globals_of "$WORK/wayland-0")"
BARE_GLOBALS="$(globals_of "$ADV/wayland-0")"
kill "$BAREPID" 2>/dev/null
if grep -qx 'xwayland_shell_v1' <<<"$XWM_GLOBALS"; then
    ok "with an XWM, xwayland_shell_v1 IS advertised"
else
    bad "with an XWM, xwayland_shell_v1 is NOT advertised -- nothing can hand over an X surface"
    info "globals were: $(tr '\n' ' ' <<<"$XWM_GLOBALS")"
fi
if grep -qx 'xwayland_shell_v1' <<<"$BARE_GLOBALS"; then
    bad "WITHOUT an XWM, xwayland_shell_v1 is still advertised -- a promise with nothing behind it"
else
    ok "without an XWM, xwayland_shell_v1 is NOT advertised (the rootful path is untouched)"
fi
if grep -qx 'xdg_wm_base' <<<"$BARE_GLOBALS"; then
    ok "the rootful compositor still advertises xdg_wm_base, wl_shm and the rest"
else
    bad "the rootful compositor lost a global it always had"
    info "globals were: $(tr '\n' ' ' <<<"$BARE_GLOBALS")"
fi

# ---------------------------------------------------------------------------
# 1. TWO X CLIENTS, ONE ROOTLESS DISPLAY, HOW MANY WSYS WINDOWS?
# ---------------------------------------------------------------------------
echo "rless: === 1. two X clients on ONE rootless Xwayland"
Xwayland -rootless -shm -noreset "$DISPNUM" >"$WORK/xw.log" 2>&1 &
XWPID=$!
for _ in $(seq 1 150); do [ -S "$XSOCK" ] && break; sleep 0.1; done
[ -S "$XSOCK" ] || { bad "Xwayland never created $XSOCK"; tail -20 "$WORK/xw.log"; exit 1; }
export DISPLAY="$DISPNUM"
# The compositor dials the display about twice a second; give it a few tries.
for _ in $(seq 1 40); do
    [ "$(sed -n 's/^xwm_connected \([0-9]*\)$/\1/p' "$STATE" 2>/dev/null | tail -1)" = 1 ] && break
    sleep 0.25
done
if [ "$(sed -n 's/^xwm_connected \([0-9]*\)$/\1/p' "$STATE" 2>/dev/null | tail -1)" = 1 ]; then
    ok "the compositor's window manager has the X display"
else
    bad "the compositor never got an X connection -- nothing below can be asked"
    sed 's/^/rless:      /' "$WORK/wsyswl.log"
    echo "rless: $pass passed, $fail failed"; exit 1
fi

# Two clients in two colours nothing else on this screen is, so "which window
# is this" is answerable from the framebuffer and not only from a table.
COL_A=ff00ff
COL_B=00ffff
xterm -geometry 30x8+60+80  -bg "#$COL_A" -fg "#$COL_A" -T alpha -e "sleep 900" \
      >/dev/null 2>&1 &
KIDS="$KIDS $!"
sleep 3
xterm -geometry 30x8+600+400 -bg "#$COL_B" -fg "#$COL_B" -T beta -e "sleep 900" \
      >/dev/null 2>&1 &
KIDS="$KIDS $!"
sleep 4

XCHILDREN="$(xwininfo -root -children 2>/dev/null | sed -n 's/^ *\(0x[0-9a-f]*\) "[^"]*".*/\1/p' | wc -l)"
if [ "$XCHILDREN" -ge 2 ]; then
    ok "the X root has $XCHILDREN mapped children -- the window manager maps what it redirects"
else
    bad "the X root has $XCHILDREN children; a WM that redirects and never maps is matchbox's bug"
fi

MANAGED="$(st xwl_managed)"
PAIRED="$(st xwl_paired)"
WHI="$(st windows_high_water)"
UNPAIRED="$(st drop_xwl_unpaired)"
REFUSED="$(st xwm_refused)"
COMMITS="$(st commits)"
CONNS="$(st conns)"
info "xwl_managed $MANAGED  xwl_paired $PAIRED  windows_high_water $WHI  conns $CONNS"
info "commits $COMMITS  drop_xwl_unpaired $UNPAIRED  xwm_refused $REFUSED"

[ "${MANAGED:-0}" -ge 2 ] \
    && ok "the XWM has both X windows on its books" \
    || bad "the XWM manages ${MANAGED:-0} X windows, expected at least 2"
[ "${PAIRED:-0}" -ge 2 ] \
    && ok "both X windows were associated with a wl_surface" \
    || bad "only ${PAIRED:-0} associations were made -- an X window with no surface is invisible"
[ "${WHI:-0}" -ge 2 ] \
    && ok "windows_high_water is $WHI: an X toplevel is its own wsys window" \
    || bad "windows_high_water is ${WHI:-0} -- the whole X session is still one rectangle"
[ "${UNPAIRED:-1}" = 0 ] \
    && ok "no frame was thrown away for want of an association" \
    || bad "$UNPAIRED commits were dropped unpaired"
[ "${REFUSED:-1}" = 0 ] \
    && ok "the XWM refused nothing" \
    || bad "the XWM refused $REFUSED things -- see wsyswl's stderr, it names them"
# ONE Wayland connection carrying both windows, which is the fact
# docs/linux_window_manager.md 8a turns on: rootless buys addressability, NOT
# independence. Asserting it here keeps the two claims from being confused
# again by whoever reads this next.
[ "${CONNS:-0}" = 1 ] \
    && ok "and it is still ONE Wayland connection -- rootless buys addressability, not fate" \
    || info "conns is ${CONNS:-0}"

# ---------------------------------------------------------------------------
# 2. THE WINDOW TABLE, and then MOVING ONE OF THEM
# ---------------------------------------------------------------------------
echo "rless: === 2. two wids under /dev/wsys, and can wsysd move one of them?"
WIDS=""
for wid in $(seq 2 40); do
    line="$(winctl "$wid")"
    [ -n "$line" ] || continue
    set -- $line
    [ "${8:-0}" = 1 ] || continue                  # visible
    [ "${4:-0}" = "$FBW" ] && continue             # not the backdrop, if any
    WIDS="$WIDS $wid"
done
set -- $WIDS
NW=$#
if [ "$NW" -ge 2 ]; then
    ok "/dev/wsys lists $NW application windows for one X display: wids$WIDS"
else
    bad "/dev/wsys lists $NW application windows -- expected two, one per X client"
    sed 's/^/rless:      /' "$WORK/wsyswl.log" | tail -30
    echo "rless: $pass passed, $fail failed"; exit 1
fi
WA=$1; WB=$2
read -r _ AX AY AW AH _ <<<"$(winctl "$WA")"
read -r _ BX BY BW BH _ <<<"$(winctl "$WB")"
info "wid $WA at ${AX},${AY} ${AW}x${AH}   wid $WB at ${BX},${BY} ${BW}x${BH}"
if [ "$AX" != "$BX" ] || [ "$AY" != "$BY" ]; then
    ok "the two windows have different geometry -- they are two windows, not two names for one"
else
    bad "both wids report the same position; these are not independent windows"
fi

cp "$HAMFB_FILE" "$WORK/before.raw"
# Which of the two is which colour? Ask the framebuffer rather than assuming
# the wid order matches the launch order.
PA_A="$(colourpct "$AX" "$AY" "$AW" "$AH" "$WORK/before.raw" "$COL_A")"
PA_B="$(colourpct "$AX" "$AY" "$AW" "$AH" "$WORK/before.raw" "$COL_B")"
PB_A="$(colourpct "$BX" "$BY" "$BW" "$BH" "$WORK/before.raw" "$COL_A")"
PB_B="$(colourpct "$BX" "$BY" "$BW" "$BH" "$WORK/before.raw" "$COL_B")"
info "wid $WA is ${PA_A}% alpha / ${PA_B}% beta;  wid $WB is ${PB_A}% alpha / ${PB_B}% beta"
MOVER=$WA; MOVER_COL=$COL_A; STAYER=$WB; STAYER_COL=$COL_B
if [ "$PA_B" -gt "$PA_A" ]; then MOVER_COL=$COL_B; STAYER_COL=$COL_A; fi
if [ "$((PA_A + PA_B))" -lt 30 ] || [ "$((PB_A + PB_B))" -lt 30 ]; then
    bad "one of the two windows is not on the framebuffer at all (${PA_A}/${PA_B} and ${PB_A}/${PB_B} per cent)"
else
    ok "both windows' pixels are on the Hamnix framebuffer, in their own colours"
fi
read -r _ SX SY SW SH _ <<<"$(winctl "$STAYER")"

# THE MOVE. `geometry` on the window's own ctl file is what wsysd's own
# dragging writes -- the desktop moving a window, spelled as a file.
NEWX=$((AX + 220)); NEWY=$((AY + 180))
poke "/dev/wsys/$MOVER/ctl" "geometry $NEWX $NEWY $AW $AH"
sleep 2
read -r _ MX MY MW MH _ <<<"$(winctl "$MOVER")"
read -r _ TX TY TW TH _ <<<"$(winctl "$STAYER")"
if [ "$MX" = "$NEWX" ] && [ "$MY" = "$NEWY" ]; then
    ok "the compositor moved wid $MOVER to ${NEWX},${NEWY}"
else
    bad "wid $MOVER did not move: it is at ${MX},${MY}, asked for ${NEWX},${NEWY}"
fi
if [ "$TX" = "$SX" ] && [ "$TY" = "$SY" ]; then
    ok "and wid $STAYER did not move with it -- THE POINT OF THE WHOLE CHANGE"
else
    bad "wid $STAYER moved too (${SX},${SY} -> ${TX},${TY}); these share a fate they should not"
fi

# ---- AND DOES THE CLIENT KNOW? --------------------------------------------
# The move above was measured in the framebuffer and in the window table, and
# for stage one that was the whole claim. It left the X client believing it
# was still where it opened: `xwininfo` on it reported the ORIGINAL corner for
# the rest of the session, and an override-redirect menu placed at "my corner
# plus twenty" was placed against a corner that had not been true since the
# first drag. Pointer coordinates were never affected -- they are
# surface-local and Xwayland adds the origin itself -- which is exactly why
# everything LOOKED right and this was easy to leave out.
#
# So the compositor now pushes the new rectangle back as a ConfigureWindow,
# which the X server turns into the ConfigureNotify the client is waiting for.
# The evidence is the X server's own answer, asked by a different program.
MOVER_NAME=alpha
[ "$MOVER_COL" = "$COL_B" ] && MOVER_NAME=beta
XI="$(xwininfo -name "$MOVER_NAME" 2>/dev/null)"
XPX="$(sed -n 's/^ *Absolute upper-left X: *\([0-9-]*\).*/\1/p' <<<"$XI" | head -1)"
XPY="$(sed -n 's/^ *Absolute upper-left Y: *\([0-9-]*\).*/\1/p' <<<"$XI" | head -1)"
PUSHED="$(sed -n 's/^x_configure_pushed \([0-9]*\)$/\1/p' "$STATE" 2>/dev/null | tail -1)"
info "the X server says '$MOVER_NAME' is at ${XPX:-?},${XPY:-?}; x_configure_pushed ${PUSHED:-?}"
if [ "${XPX:-x}" = "$NEWX" ] && [ "${XPY:-x}" = "$NEWY" ]; then
    ok "the X client was TOLD where the desktop put it -- X and wsys agree on ${NEWX},${NEWY}"
else
    bad "the X client still thinks it is at ${XPX:-?},${XPY:-?}, not ${NEWX},${NEWY}"
fi
[ "${PUSHED:-0}" -ge 1 ] \
    && ok "and the compositor counts the pushes it made ($PUSHED)" \
    || bad "x_configure_pushed is ${PUSHED:-absent}"

cp "$HAMFB_FILE" "$WORK/after.raw"
MOVED_PCT="$(colourpct "$NEWX" "$NEWY" "$MW" "$MH" "$WORK/after.raw" "$MOVER_COL")"
STAY_PCT="$(colourpct "$SX" "$SY" "$SW" "$SH" "$WORK/after.raw" "$STAYER_COL")"
info "after the move: ${MOVED_PCT}% of the new rectangle is the moved window's colour,"
info "                ${STAY_PCT}% of the old rectangle is still the other window's colour"
[ "${MOVED_PCT:-0}" -ge 30 ] \
    && ok "the moved window's PIXELS followed it" \
    || bad "the window record moved and the pixels did not (${MOVED_PCT}%)"
[ "${STAY_PCT:-0}" -ge 30 ] \
    && ok "the other window's pixels are exactly where they were" \
    || bad "the other window's pixels changed (${STAY_PCT}%) -- one X window's move disturbed another"

# ---------------------------------------------------------------------------
# 2b. IS IT A FIRST-CLASS WINDOW ON THE DESKTOP?
#     Everything above would read the same on a bare compositor. These are the
#     assertions that need the desktop to be there, and each one is a
#     relationship between two things on the screen rather than a coordinate.
# ---------------------------------------------------------------------------
echo "rless: === 2b. is an X window from the namespace a window ON THE DESKTOP?"

# OVER THE WALLPAPER. The same rectangle, on the same screen, before the X
# client existed and after: 0% then, its own colour now. The "before" half is
# what makes this evidence -- without it, a wallpaper that happened to be
# magenta would pass.
WAS=$(colourpct "$SX" "$SY" "$SW" "$SH" "$WORK/desktop.raw" "$STAYER_COL")
NOW=$(colourpct "$SX" "$SY" "$SW" "$SH" "$WORK/after.raw" "$STAYER_COL")
info "the X window's rectangle: ${WAS}% its colour on the bare desktop, ${NOW}% with the client up"
if [ "$WAS" -eq 0 ] && [ "$NOW" -ge 30 ]; then
    ok "the X window is composited OVER the wallpaper, not under it"
else
    bad "the X window is not over the wallpaper (${WAS}% before, ${NOW}% after)"
fi

# AND THE DESKTOP IS STILL A DESKTOP. A screen whose backdrop vanished when a
# window mapped would pass the check above for the wrong reason. Sample a strip
# down the left edge, clear of the bar and of both clients.
DESKLEFT=$(samepct 0 $((PANELY + PANELH + 200)) 40 400 "$WORK/after.raw" "$WORK/desktop.raw")
[ "$DESKLEFT" -ge 90 ] \
    && ok "the wallpaper is still there beside the X windows (${DESKLEFT}% unchanged)" \
    || bad "the desktop changed under the X windows (${DESKLEFT}% unchanged)"

# UNDER THE PANEL. Drive the X window up so it straddles the bar -- with the
# compositor's own `geometry` verb, which is the desktop moving a window -- and
# require the bar to win where they overlap and the window to win where they do
# not. A window that goes OVER the panel is a window you cannot get out from
# under, and it is the same z question ea23c834 was about, asked from the other
# side.
poke "/dev/wsys/$STAYER/ctl" "geometry 700 $PANELY $SW $SH"
sleep 2
cp "$HAMFB_FILE" "$WORK/overpanel.raw"
INBAR=$(colourpct 700 "$PANELY" "$SW" "$PANELH" "$WORK/overpanel.raw" "$STAYER_COL")
BELOW=$(colourpct 700 $((PANELY + PANELH + 20)) "$SW" $((SH - PANELH - 40)) \
                  "$WORK/overpanel.raw" "$STAYER_COL")
info "an X window straddling the bar: ${INBAR}% of the bar is the window, ${BELOW}% of it clear of the bar"
if [ "$INBAR" -eq 0 ] && [ "$BELOW" -ge 30 ]; then
    ok "the panel is drawn OVER an X window that overlaps it, and the window elsewhere is untouched"
else
    bad "the panel/X-window order is wrong: ${INBAR}% of the bar is the window (want 0), ${BELOW}% below it (want >=30)"
fi
# Put it back somewhere a person would have left it, so the screenshot below is
# the desktop and not the test rig.
poke "/dev/wsys/$STAYER/ctl" "geometry 700 430 $SW $SH"
sleep 2

# IN THE TASKBAR, BY ITS X NAME. /dev/wsys/windows is the file the panel's
# taskbar reads (user/hampanelscene.ad:_refresh_windows): one line per mapped
# decorated window, "<wid> <title>". An X window that the desktop cannot LIST
# is not a first-class window however well it paints, and the title has to be
# the X client's own -- wsyswl takes it from WM_NAME/_NET_WM_NAME, and the two
# xterms here are called `alpha` and `beta`.
WINLIST="$(poke /dev/wsys/windows)"
info "/dev/wsys/windows says: $(tr '\n' '|' <<<"$WINLIST")"
if grep -q 'alpha' <<<"$WINLIST" && grep -q 'beta' <<<"$WINLIST"; then
    ok "both X windows are in the taskbar list, under the names their X clients set"
else
    bad "the taskbar list does not name both X clients -- an X window the desktop cannot list"
fi

cp "$HAMFB_FILE" "$WORK/desktopshot.raw"

if [ -n "$SHOT" ]; then
    python3 - "$WORK/desktopshot.raw" "$FBW" "$FBH" "$SHOT" <<'PY'
import sys, zlib, struct
raw = open(sys.argv[1], 'rb').read()
W, H, out = int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
rows = bytearray()
for y in range(H):
    rows.append(0)
    o = y * W * 4
    line = raw[o:o + W * 4]
    rows += bytes(b for i in range(W) for b in (line[i*4+2], line[i*4+1], line[i*4]))
def chunk(tag, payload):
    c = tag + payload
    return struct.pack('>I', len(payload)) + c + struct.pack('>I', zlib.crc32(c))
open(out, 'wb').write(b'\x89PNG\r\n\x1a\n'
    + chunk(b'IHDR', struct.pack('>IIBBBBB', W, H, 8, 2, 0, 0, 0))
    + chunk(b'IDAT', zlib.compress(bytes(rows), 6)) + chunk(b'IEND', b''))
print("wrote", out)
PY
    info "screenshot written to $SHOT"
fi

# ---------------------------------------------------------------------------
# 2c. EWMH -- IS THERE A WINDOW MANAGER ON THIS SCREEN, AND WHAT CAN IT DO?
#
# Until this, the answer was byte-for-byte the answer a BARE X SCREEN gives:
# no _NET_SUPPORTED, no _NET_SUPPORTING_WM_CHECK, no _NET_WORKAREA, no
# _NET_CLIENT_LIST. That is not "answered badly" -- a toolkit correctly
# concluded there was no window manager and laid itself out accordingly, and
# it is why hamnix_x11session.sh had to SKIP its window-manager check on this
# arm rather than print a warning that was true and misleading at once.
#
# The check window is the load-bearing one and is asserted BOTH ways: the
# property on the root must name a window that exists and carries the same
# property pointing at itself. A window manager that publishes hints on the
# root and then dies leaves exactly the first half, which is what
# docs/linux_window_manager.md §4 records matchbox doing.
# ---------------------------------------------------------------------------
echo "rless: === 2c. does this screen have a window manager, as far as X is concerned?"
if command -v xprop >/dev/null; then
    SUP="$(xprop -root _NET_SUPPORTED 2>/dev/null)"
    NSUP="$(tr ',' '\n' <<<"$SUP" | grep -c '_NET_')"
    info "_NET_SUPPORTED lists $NSUP atoms"
    [ "${NSUP:-0}" -ge 8 ] \
        && ok "_NET_SUPPORTED is published with $NSUP atoms" \
        || bad "_NET_SUPPORTED has ${NSUP:-0} atoms -- a toolkit reads that as no window manager"
    CHECK="$(xprop -root _NET_SUPPORTING_WM_CHECK 2>/dev/null \
             | sed -n 's/.*window id # \(0x[0-9a-f]*\).*/\1/p')"
    if [ -n "$CHECK" ]; then
        BACKREF="$(xprop -id "$CHECK" _NET_SUPPORTING_WM_CHECK 2>/dev/null \
                   | sed -n 's/.*window id # \(0x[0-9a-f]*\).*/\1/p')"
        WMNAME="$(xprop -id "$CHECK" _NET_WM_NAME 2>/dev/null \
                  | sed -n 's/.*= "\(.*\)"/\1/p')"
        info "check window $CHECK names $BACKREF and calls itself \"$WMNAME\""
        [ "$BACKREF" = "$CHECK" ] \
            && ok "the check window exists and points back at itself -- a LIVE window manager" \
            || bad "the check window does not point back at itself ($BACKREF); this reads as a dead WM"
        [ -n "$WMNAME" ] \
            && ok "and it names itself: $WMNAME" \
            || bad "the check window carries no _NET_WM_NAME"
    else
        bad "_NET_SUPPORTING_WM_CHECK is absent -- X sees no window manager at all"
    fi
    WA="$(xprop -root _NET_WORKAREA 2>/dev/null | sed -n 's/.*= //p')"
    info "_NET_WORKAREA is $WA"
    [ -n "$WA" ] \
        && ok "_NET_WORKAREA answers, so a client asking how big the desktop is gets a number" \
        || bad "_NET_WORKAREA is absent"
    CL="$(xprop -root _NET_CLIENT_LIST 2>/dev/null | tr ',' '\n' | grep -c '0x')"
    info "_NET_CLIENT_LIST has $CL windows"
    [ "${CL:-0}" -ge 2 ] \
        && ok "_NET_CLIENT_LIST carries both X windows -- a taskbar could list them" \
        || bad "_NET_CLIENT_LIST has ${CL:-0} entries, expected 2"
else
    info "xprop is not on this host; the EWMH assertions are skipped"
fi

# ---------------------------------------------------------------------------
# 3. THE CONTROL: the same two clients, rootful, on the same compositor
# ---------------------------------------------------------------------------
echo "rless: === 3. the control -- the same two clients on a ROOTFUL Xwayland"
WIN_BEFORE="$(st windows_high_water)"
DISP2="${RLESS_DISPLAY2:-:85}"
Xwayland -shm -noreset "$DISP2" >"$WORK/xw2.log" 2>&1 &
XWPID2=$!
for _ in $(seq 1 150); do [ -S "/tmp/.X11-unix/X${DISP2#:}" ] && break; sleep 0.1; done
if [ -S "/tmp/.X11-unix/X${DISP2#:}" ]; then
    DISPLAY="$DISP2" xterm -geometry 20x5+20+20 -e "sleep 300" >/dev/null 2>&1 &
    KIDS="$KIDS $!"
    sleep 2
    DISPLAY="$DISP2" xterm -geometry 20x5+300+200 -e "sleep 300" >/dev/null 2>&1 &
    KIDS="$KIDS $!"
    sleep 4
    # The SAME filter part 2 counted with -- visible, and not full-width, so
    # the desktop's backdrop and the panel's bar are excluded from both sides
    # of the subtraction. Counting them here and not there would have made the
    # control read two extra windows and fail for a reason that is not the one
    # under test.
    NW2=0
    for wid in $(seq 2 40); do
        line="$(winctl "$wid")"
        [ -n "$line" ] || continue
        set -- $line
        [ "${8:-0}" = 1 ] || continue
        [ "${4:-0}" = "$FBW" ] && continue
        NW2=$((NW2 + 1))
    done
    ROOTFUL_WINS=$((NW2 - NW))
    info "the rootful display's two clients added $ROOTFUL_WINS wsys window(s)"
    if [ "$ROOTFUL_WINS" -le 1 ]; then
        ok "rootful: two X clients are ONE wsys window -- the thing rootless fixes, measured"
    else
        bad "the rootful arm produced $ROOTFUL_WINS windows; the control does not hold"
    fi
    CONNS2="$(st conns)"
    [ "${CONNS2:-0}" -ge 2 ] \
        && ok "and two X SERVERS are two connections ($CONNS2) -- independence is bought per server" \
        || info "conns is ${CONNS2:-0} with two Xwaylands up"
else
    info "could not start the rootful control on $DISP2; skipping part 3"
fi

# ---------------------------------------------------------------------------
# 4. THE ARITHMETIC that keeps the tables honest, carried over from
#    wsyswl_shared_fate.sh because rootless is the arm that can reach them.
# ---------------------------------------------------------------------------
echo "rless: === 4. can one X display exhaust something another client needs?"
lim() { sed -n "s/.*[ ]$1=\([0-9]*\).*/\1/p" "$STATE" 2>/dev/null | tail -1; }
MAXWIN="$(lim MAXWIN)"; MAXCONN="$(lim MAXCONN)"; WINPERCONN="$(lim WINPERCONN)"
if [ -n "$MAXWIN" ] && [ -n "$MAXCONN" ] && [ -n "$WINPERCONN" ]; then
    if [ "$MAXWIN" -ge $((MAXCONN * WINPERCONN)) ]; then
        ok "MAXWIN $MAXWIN >= MAXCONN $MAXCONN * WINPERCONN $WINPERCONN"
    else
        bad "MAXWIN $MAXWIN < MAXCONN $MAXCONN * WINPERCONN $WINPERCONN -- one client can starve another of windows"
    fi
    # ROOTLESS IS THE ARM THAT SPENDS THIS BUDGET. Rootful spends ONE window
    # per X display however many clients are on it; rootless spends one per
    # toplevel, out of WINPERCONN. That is the ceiling a namespace hits first
    # and it is written down here so the next person meets it as a number
    # rather than as "the ninth window did not appear".
    info "an X display may therefore have at most WINPERCONN=$WINPERCONN toplevels on screen at once"
    # BB_SLOTS USED TO BE THE HARDER CEILING BEHIND THIS ONE and is not any
    # more: user/linux-wsys.c ties the v2 backbuffer pool to the window table
    # with a compile-time assertion, so the paint pool can never be the first
    # thing to run out. /dev/wsys/pool states it, and tests/linux/wsyswl_ceiling.sh
    # puts twelve X windows on the screen at once and checks all twelve PIXELS.
    POOL="$(poke /dev/wsys/pool)"
    if [ -n "$POOL" ]; then
        ok "and the paint pool behind it is readable: $POOL"
    else
        bad "/dev/wsys/pool does not exist -- an exhausted paint pool would be silent again"
    fi
fi

echo "rless: $pass passed, $fail failed"
[ "$fail" = 0 ] || exit 1
