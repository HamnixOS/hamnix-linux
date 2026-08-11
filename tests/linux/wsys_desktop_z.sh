#!/usr/bin/env bash
# tests/linux/wsys_desktop_z.sh — the REAL desktop, with an application on it.
#
#   wsysd (compositor) + hamdesktop (backdrop, pinned) + hampanelscene (panel)
#   + application windows  ->  /dev/fb  ->  THE PIXELS
#
# WHY THIS EXISTS.  ea23c834 fixed a bug that had shipped for the whole port:
# hamdesktop writes `background 1` on its full-screen backdrop, this port had
# no such verb, an unknown verb is IGNORED, so the backdrop kept lib/hamui.ad's
# default `z 6` and the compositor -- which paints z ASCENDING -- painted an
# opaque full-screen backdrop over every ordinary client window.  Wallpaper,
# icons and a panel, and not one application.  Every return code 0, and the
# taskbar still listing the windows it was covering.
#
# NOTHING IN THIS REPOSITORY CAUGHT IT, AND NOTHING WOULD HAVE.  That was
# checked rather than assumed: tests/linux/wsys_image.sh passes with the fix
# reverted, because it never runs hamdesktop.  Every other gate composites ONE
# client, or reads the window table, or asks a layer whether it succeeded.  No
# gate composited the real desktop with a real application window and asserted
# that the application was VISIBLE.  This is that gate.
#
# WHAT IT ASSERTS, AND WHY IT IS RELATIONSHIPS AND NOT COORDINATES.  A fixed
# pixel at a fixed place is brittle against any layout change, and this gate
# has to survive.  So every assertion here is of the form "which of two windows
# owns this region", answered by counting a client's OWN FLAT COLOUR:
#
#   1. the application's rectangle is the application's pixels     (over the backdrop)
#   2. the backdrop's z is STRICTLY below every ordinary window's  (pinned means bottom)
#   3. a click on the desktop does not bury the application        (pinned never raises)
#   4. a raise brings an occluded window to the front, both ways
#   5. the panel stays over an ordinary window that overlaps it
#   6. a closed window's pixels leave the screen
#
# 2 and 3 are the ones with TEETH against ea23c834: revert its hunk and the
# backdrop's z is 6, equal to an ordinary window's, so 2 fails outright, and a
# raise puts the backdrop over everything, so 3 fails in the framebuffer.  1 on
# its own passes either way -- the tie between two windows at z 6 goes to the
# one mapped later, which is the client -- and that is written down here rather
# than glossed, because "the gate passes" doing no work is the exact failure
# this file was created in response to.  Both arms were measured; see
# docs/linux_window_manager.md.
#
# Entirely offscreen (HAMFB_FILE): it never touches the host's display, and the
# software Vulkan ICD is forced because wsysd has a real Vulkan backend and
# this host's GPU belongs to someone.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

WORK="${ZGATE_WORK:-$(mktemp -d -p "${TMPDIR:-/tmp}" wsysz.XXXXXX)}"
mkdir -p "$WORK"
KEEP="${ZGATE_KEEP:-0}"
GEOM="${HAMFB_GEOM:-1280x800}"
SHOT="${ZGATE_SHOT:-$WORK/desktop.png}"
FBW="${GEOM%x*}"; FBH="${GEOM#*x}"

# EVERY shared file pinned into $WORK.  /srv/wsys, /srv/wsys.bb and /srv/wsys.img
# are one per HOST by default and outlive the process that made them; two runs
# sharing them hand each other stale slots.  docs/steam_namespace.md §11.
export HAMWSYS="$WORK/wsys.shm"
export HAMWSYS_BB="$WORK/wsys.bb"
export HAMWSYS_IMG="$WORK/wsys.img"
export HAMFB_FILE="$WORK/fb.raw"
export HAMFB_GEOM="$GEOM"
[ -r /usr/share/vulkan/icd.d/lvp_icd.json ] && \
    export VK_ICD_FILENAMES="${VK_ICD_FILENAMES:-/usr/share/vulkan/icd.d/lvp_icd.json}"

pass=0; fail=0
ok()   { echo "wsysz: PASS $*"; pass=$((pass+1)); }
bad()  { echo "wsysz: FAIL $*"; fail=$((fail+1)); }
info() { echo "wsysz: INFO $*"; }

PIDS=""
cleanup() {
    for p in $PIDS; do [ -n "${p:-}" ] && kill "$p" 2>/dev/null; done
    sleep 0.3
    for p in $PIDS; do [ -n "${p:-}" ] && kill -9 "$p" 2>/dev/null; done
    [ "$KEEP" = 1 ] || rm -rf "$WORK"
}
trap cleanup EXIT

# ---- the pixel arithmetic -------------------------------------------------
# "what fraction of this rectangle is exactly this colour" is the only question
# asked of the framebuffer, and it has an arithmetic answer.  The clients paint
# ONE FLAT FILL each for that reason: a gradient or a glyph would turn every
# z-order assertion into a tolerance argument.
FRAC_PY="$WORK/frac.py"
cat >"$FRAC_PY" <<'PY'
import sys
mode = sys.argv[1]
W, H = int(sys.argv[2]), int(sys.argv[3])
x, y, w, h = (int(v) for v in sys.argv[4:8])
d = open(sys.argv[8], 'rb').read()
if mode == 'colour':
    c = sys.argv[9]
    want = (int(c[0:2], 16), int(c[2:4], 16), int(c[4:6], 16))
    tot = hit = 0
    for j in range(y, min(y + h, H), 2):
        row = j * W * 4
        for i in range(x, min(x + w, W), 2):
            o = row + i * 4
            tot += 1
            if (d[o+2], d[o+1], d[o]) == want:
                hit += 1
else:                                   # 'same': identical to another frame
    e = open(sys.argv[9], 'rb').read()
    tot = hit = 0
    for j in range(y, min(y + h, H), 2):
        row = j * W * 4
        for i in range(x, min(x + w, W), 2):
            o = row + i * 4
            tot += 1
            if d[o:o+3] == e[o:o+3]:
                hit += 1
print(0 if tot == 0 else hit * 100 // tot)
PY
# $1..$4 rect, $5 frame, $6 RRGGBB
colourpct() { python3 "$FRAC_PY" colour "$FBW" "$FBH" "$1" "$2" "$3" "$4" "$5" "$6"; }
samepct()   { python3 "$FRAC_PY" same   "$FBW" "$FBH" "$1" "$2" "$3" "$4" "$5" "$6"; }
snap()      { cp "$HAMFB_FILE" "$WORK/$1.raw"; }
poke()      { "$WORK/wsys_poke.elf" "$@" 2>/dev/null; }
# The window table, straight out of the device every client reads:
#   "<wid> <x> <y> <w> <h> <z> <decorate> <visible> <proto> ..."
winctl()    { poke "/dev/wsys/$1/ctl"; }
winfield()  { winctl "$1" | awk -v k="$2" '{print $k}'; }

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
        echo "wsysz: $pass passed, $fail failed"; exit 1; }
done
ok "the compositor, the desktop, the panel and the probe client all build"

# ---- the compositor -------------------------------------------------------
"$WORK/wsysd.elf" </dev/null >"$WORK/wsysd.log" 2>&1 &
PIDS="$PIDS $!"
for _ in $(seq 1 40); do [ -s "$HAMFB_FILE" ] && break; sleep 0.1; done
[ -s "$HAMFB_FILE" ] || { bad "wsysd never produced a framebuffer"
                          cat "$WORK/wsysd.log"; echo "wsysz: $pass passed, $fail failed"; exit 1; }

# ---- the desktop ----------------------------------------------------------
"$WORK/hamdesktop.elf" </dev/null >"$WORK/hamdesktop.log" 2>&1 &
PIDS="$PIDS $!"
sleep 3
snap desk

# Find the backdrop the way anything else would: it is the full-screen,
# undecorated, visible window.  Nothing here hardcodes a wid.
BACKDROP=""
for wid in $(seq 2 33); do
    line="$(winctl "$wid")"
    [ -n "$line" ] || continue
    set -- $line
    if [ "${4:-}" = "$FBW" ] && [ "${5:-}" = "$FBH" ] && [ "${7:-}" = "0" ] && [ "${8:-}" = "1" ]; then
        BACKDROP="$wid"; break
    fi
done
if [ -n "$BACKDROP" ]; then
    ok "hamdesktop mapped a full-screen undecorated backdrop (wid $BACKDROP)"
else
    bad "hamdesktop never mapped a full-screen backdrop -- nothing below can be asked"
    sed 's/^/wsysz:      /' "$WORK/hamdesktop.log"
    echo "wsysz: $pass passed, $fail failed"; exit 1
fi

# ---- the panel ------------------------------------------------------------
"$WORK/hampanelscene.elf" </dev/null >"$WORK/hampanelscene.log" 2>&1 &
PIDS="$PIDS $!"
sleep 3
snap deskpanel

# The bar nearest the top of the screen, whichever edge the panel is on --
# nothing here assumes it is at y 0.
PANELZ=""; PANELY=""; PANELH=""
for wid in $(seq 2 33); do
    [ "$wid" = "$BACKDROP" ] && continue
    line="$(winctl "$wid")"
    [ -n "$line" ] || continue
    set -- $line
    [ "${4:-}" = "$FBW" ] || continue          # a full-width bar
    [ "${5:-0}" -lt 200 ] || continue          # ... that is a bar, not a window
    if [ -z "$PANELY" ] || [ "${3:-0}" -lt "$PANELY" ]; then
        PANELZ="${6:-}"; PANELY="${3:-}"; PANELH="${5:-}"
    fi
done
if [ -n "$PANELZ" ]; then
    ok "hampanelscene mapped a full-width bar at y $PANELY, height $PANELH, z $PANELZ"
else
    bad "hampanelscene mapped no bar -- the panel assertions below cannot be asked"
    PANELZ=100; PANELY=0; PANELH=26
fi

# ---- the applications -----------------------------------------------------
# Two ordinary windows at the default z, overlapping, in colours nothing else
# on this screen paints.
CA=7A1FA2; CB=1FA27A; CC=A21F7A
AX=200; AY=200; AW=400; AH=300
BX=400; BY=350; BW=400; BH=300
"$WORK/wsys_zclient.elf" $AX $AY $AW $AH 6 $CA appA 120 </dev/null >"$WORK/a.log" 2>&1 &
PIDS="$PIDS $!"
sleep 3
snap a
"$WORK/wsys_zclient.elf" $BX $BY $BW $BH 6 $CB appB 120 </dev/null >"$WORK/b.log" 2>&1 &
PIDS="$PIDS $!"
sleep 3
snap ab

WA="$(awk '/mapped wid/{print $NF}' "$WORK/a.log")"
WB="$(awk '/mapped wid/{print $NF}' "$WORK/b.log")"
[ -n "$WA" ] && [ -n "$WB" ] && ok "both applications mapped a window (wid $WA, wid $WB)" \
                             || { bad "an application never got a window"
                                  echo "wsysz: $pass passed, $fail failed"; exit 1; }

# The overlap of the two windows, and the part of appA that only appA can own
# (appB covers appA's bottom-right corner from here on, so every later check on
# appA is made in the part appB cannot reach -- "is the application visible" and
# "is another application in front of it" are different questions).
OX=$BX; OY=$BY; OW=$((AX + AW - BX)); OH=$((AY + AH - BY))
AOX=$AX; AOY=$AY; AOW=$((BX - AX)); AOH=$AH

# ==== 1. THE GATE: the application is ON the desktop, not under it =========
BEFORE=$(colourpct $AX $AY $AW $AH "$WORK/desk.raw" $CA)
AFTER=$(colourpct $AX $AY $AW $AH "$WORK/a.raw" $CA)
info "the application's rectangle: ${BEFORE}% its own colour with only the desktop up, ${AFTER}% with it up"
if [ "$BEFORE" -eq 0 ] && [ "$AFTER" -ge 95 ]; then
    ok "the application's window is composited OVER the desktop backdrop (${AFTER}% of its rectangle is its own pixels)"
else
    bad "the application is not on the screen: its rectangle is ${AFTER}% its own colour (was ${BEFORE}% before it started)"
fi
# The desktop must still BE a desktop -- a screen with the backdrop missing
# would pass the check above for the wrong reason.
DESKLEFT=$(samepct 0 $((PANELY + PANELH + 4)) 120 300 "$WORK/ab.raw" "$WORK/desk.raw")
[ "$DESKLEFT" -ge 90 ] && ok "the backdrop is still there beside the window (${DESKLEFT}% unchanged)" \
                       || bad "the backdrop vanished when a window mapped (${DESKLEFT}% unchanged)"

# ==== 2. STRUCTURAL: pinned means BELOW, and strictly ======================
# This is the assertion `background 1` exists to make true.  With ea23c834's
# hunk reverted the backdrop's z is 6 -- EQUAL to an ordinary window's -- and
# equal is not below: which of the two you see is then decided by the order
# they happened to map in.
BZ=$(winfield "$BACKDROP" 6)
AZ=$(winfield "$WA" 6)
BZ2=$(winfield "$WB" 6)
info "z: backdrop $BZ, appA $AZ, appB $BZ2, panel $PANELZ"
if [ "$BZ" -lt "$AZ" ] && [ "$BZ" -lt "$BZ2" ] && [ "$BZ" -lt "$PANELZ" ]; then
    ok "the backdrop's z ($BZ) is STRICTLY below every other window's -- it is pinned, not merely early"
else
    bad "the backdrop is at z $BZ, not strictly below the windows it must never cover (app $AZ, panel $PANELZ)"
fi

# ==== 3. THE GATE, second half: a click on the desktop ====================
# user/wsysd.ad's raise_window writes exactly this line when a button press
# lands on a window, so this IS a click on the desktop -- the "all windows
# vanish on desktop click" case, without an input device.
poke /dev/wsys/ctl "raise $BACKDROP"
sleep 2
snap clickdesk
CLICKED=$(colourpct $AOX $AOY $AOW $AOH "$WORK/clickdesk.raw" $CA)
NEWBZ=$(winfield "$BACKDROP" 6)
info "after a click on the desktop: backdrop z $NEWBZ, the application's rectangle ${CLICKED}% its own colour"
if [ "$CLICKED" -ge 95 ] && [ "$NEWBZ" -lt "$AZ" ]; then
    ok "a click on the desktop did NOT bury the application (a pinned backdrop never raises)"
else
    bad "a click on the desktop put the backdrop over the application (z $NEWBZ, ${CLICKED}% of the window left)"
fi

# ==== 4. a raise brings an occluded window to the front ===================
OVA=$(colourpct $OX $OY $OW $OH "$WORK/ab.raw" $CA)
OVB=$(colourpct $OX $OY $OW $OH "$WORK/ab.raw" $CB)
info "the overlap starts ${OVA}% appA / ${OVB}% appB"
poke /dev/wsys/ctl "raise $WA"
sleep 2
snap raisea
RA=$(colourpct $OX $OY $OW $OH "$WORK/raisea.raw" $CA)
poke /dev/wsys/ctl "raise $WB"
sleep 2
snap raiseb
RB=$(colourpct $OX $OY $OW $OH "$WORK/raiseb.raw" $CB)
info "after raise appA the overlap is ${RA}% appA; after raise appB it is ${RB}% appB"
if [ "$RA" -ge 95 ] && [ "$RB" -ge 95 ]; then
    ok "a raise brings the raised window to the FRONT, and it works in both directions"
else
    bad "a raise did not bring the window to the front (appA ${RA}%, then appB ${RB}%)"
fi

# ==== 5. the panel stays over an ordinary window ==========================
# A THIRD client, never raised, so it is at the default z the panel is above.
# (A raised window goes to top+1, which is above the panel too -- that is the
# compositor's current contract and this gate does not pretend otherwise.)
# Straddle the bar: 120px of window on each side of it, clamped to the screen,
# so this works whether the panel is along the top edge or the bottom.
CX=850; CW=380
CY=$((PANELY - 120)); [ "$CY" -lt 0 ] && CY=0
CH=$((PANELY + PANELH + 120 - CY))
[ $((CY + CH)) -gt "$FBH" ] && CH=$((FBH - CY))
# The part of that window the panel must NOT be over: whichever slab of it
# falls clear of the bar.
ELSEY=$((PANELY + PANELH + 10)); ELSEH=$((CY + CH - ELSEY))
if [ "$ELSEH" -lt 40 ]; then ELSEY=$CY; ELSEH=$((PANELY - CY - 10)); fi

"$WORK/wsys_zclient.elf" $CX $CY $CW $CH 6 $CC appC 90 </dev/null >"$WORK/c.log" 2>&1 &
CPID=$!
PIDS="$PIDS $CPID"
sleep 3
snap panel
INBAR=$(colourpct $CX "$PANELY" $CW "$PANELH" "$WORK/panel.raw" $CC)
BELOW=$(colourpct $CX $ELSEY $CW $ELSEH "$WORK/panel.raw" $CC)
info "a window straddling the bar: ${INBAR}% of the bar is the window's colour, ${BELOW}% of the window clear of it"
if [ "$INBAR" -eq 0 ] && [ "$BELOW" -ge 95 ]; then
    ok "the panel is drawn OVER an ordinary window that overlaps it, and the window elsewhere is untouched"
else
    bad "the panel/window order is wrong: ${INBAR}% of the bar is the window (want 0), ${BELOW}% below it (want >=95)"
fi

# ==== 6. a closed window's pixels leave the screen ========================
# The compositor patches damage rather than repainting everything (user/
# wsysd.ad's "patch" path), so the region a window VACATES is exactly the kind
# of thing that gets forgotten -- and a ghost window is indistinguishable from
# a live one until you click it.
kill "$CPID" 2>/dev/null
sleep 3
snap closed
GHOST=$(colourpct $CX $ELSEY $CW $ELSEH "$WORK/closed.raw" $CC)
BACK=$(samepct $CX $ELSEY $CW $ELSEH "$WORK/closed.raw" "$WORK/deskpanel.raw")
info "after the window closed: ${GHOST}% of its area is still its colour, ${BACK}% is back to the bare desktop"
if [ "$GHOST" -eq 0 ] && [ "$BACK" -ge 90 ]; then
    ok "a closed window's pixels left the screen and the desktop came back underneath"
else
    bad "a closed window left ${GHOST}% of its pixels behind (${BACK}% of the area is back to the desktop)"
fi

# ---- the evidence a human can look at ------------------------------------
python3 - "$WORK/panel.raw" "$FBW" "$FBH" "$SHOT" <<'PY'
import sys, zlib, struct
raw = open(sys.argv[1], 'rb').read()
w, h = int(sys.argv[2]), int(sys.argv[3])
out = bytearray()
for y in range(h):
    out.append(0)
    row = y * w * 4
    for x in range(w):
        o = row + x * 4
        out += bytes((raw[o+2], raw[o+1], raw[o]))
def chunk(tag, payload):
    c = tag + payload
    return struct.pack('>I', len(payload)) + c + struct.pack('>I', zlib.crc32(c))
png = (b'\x89PNG\r\n\x1a\n'
       + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
       + chunk(b'IDAT', zlib.compress(bytes(out), 6))
       + chunk(b'IEND', b''))
open(sys.argv[4], 'wb').write(png)
print("wsysz: INFO screenshot %s (%dx%d)" % (sys.argv[4], w, h))
PY

echo "wsysz: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
