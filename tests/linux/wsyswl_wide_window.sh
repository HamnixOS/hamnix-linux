#!/usr/bin/env bash
# tests/linux/wsyswl_wide_window.sh -- WHAT HAPPENS TO A WINDOW WIDER THAN THE
# BACKBUFFER, AND IS ANYBODY TOLD?
#
#   X client (wide) -> Xwayland -rootless -> wsyswl -> /dev/wsys draw/ctl
#                                                   -> wsysd -> /dev/fb
#
# THE QUESTION
# ============
# Every surface in this stack is bounded by ONE number: BB_W x BB_H in
# user/linux-wsys.c, 1920x1080, the size of a window's v2 backbuffer.  Three
# separate pieces of code have their own opinion about that number, and until
# this gate existed all three were wrong in the same direction -- they answered
# something success-shaped for a window the stack cannot show.
#
#   1. user/wsyswl.ad capped a blit row at a hardcoded 8192 bytes -- 2048
#      columns -- and said nothing.  2048 is not BB_W and is not derived from
#      anything; a window between 1921 and 2048 columns wide therefore sent a
#      rect the device REFUSES (bb_blit clips at BB_W and the draw/ctl arm
#      returns EMSGSIZE for a rect wider than it), and wsyswl ignores the
#      return value of that write.  The result is a window that paints NOTHING
#      AT ALL, forever, with no message from the process that caused it.
#
#   2. user/wsyswl.ad's MAX_W -- the size a MAXIMISED client is told to be --
#      is the screen minus the frame inset.  On any screen wider than about
#      2040 that is a size no window can paint at, so "maximise" was an
#      instruction to disappear.
#
#   3. user/wsysd.ad's paint_backbuffer read a row capped at BBROW_CAP (7680 =
#      BB_W*4) into a 7680-byte array and then walked x from 0 to the WINDOW's
#      width -- reading bbrow[x*4] past the end of the array for any window
#      wider than 1920, and painting whatever it found over whatever was
#      behind the window.
#
#   4. user/linux-wsys.c's bb_for compared the size ASKED FOR against the size
#      STORED, and bb_fit clamps on the way in -- so for a window wider than
#      BB_W they could never be equal, every blit re-fit the memfd, and
#      bb_fit CLEARS it.  The window was wiped between one row and the next.
#      Found by this gate, after 1 was fixed and the window was still blank.
#
# WHAT IS ASSERTED
# ================
#   A. THE INSTRUMENT WORKS.  A NARROW window paints, right edge included.
#      A gate whose wide arm fails is only evidence if the narrow arm passes
#      on the same compositor in the same run.
#   B. A window wider than the backbuffer paints the part of itself that fits.
#      Left edge and the column just inside BB_W must both be its colour.
#   C. THE TRUNCATION IS LOUD.  wsyswl's own stderr must carry a message
#      naming the width it was asked for and the width it can send.  A
#      truncation nobody is told about is the whole defect.
#   D. NOTHING IS PAINTED PAST THE BACKBUFFER'S WIDTH.  A second window is
#      moved UNDERNEATH the strip of the wide window's declared rectangle that
#      is past BB_W, and has to still be visible there.  That is wsysd's
#      over-read, asked as pixels.
#
# NOT ASKED HERE, AND NOW ASKED NEXT DOOR.  This gate's client is an X client
# through Xwayland, and its screen is 820 tall, so it can say nothing about a
# NATIVE Wayland client over BB_W or about the HEIGHT axis at all -- wsysd's
# MAX_PIXELS forbids one screen being both over 1920 wide and over 1080 tall.
# tests/linux/wsyswl_wide_native.sh measures both, in two runs, with a client
# that speaks the Wayland wire itself.  Both were the SAME defect: measured
# against the pre-fix binaries, a 700x1600 native window painted 0% of itself.
#
# NOT asserted, because it was measured and is NOT affected: hamdesktop's
# full-screen backdrop paints correctly on a 2400-wide screen.  It is a SCENE
# window, not a v2 blit window, and none of the four defects above is on the
# scene path.
#
# Offscreen throughout: HAMFB_FILE and the host's Xwayland.  Touches no
# display, takes no DRM master.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

# Same reason as wsyswl_rootless.sh: this starts the real desktop binaries and
# they write fixed /tmp names compiled into them.  Namespace first, before any
# file is made.
. tests/linux/private_ns.sh
priv_ns_reexec "$@"

WORK="${WIDE_WORK:-$(mktemp -d -p "${TMPDIR:-/tmp}" wide.XXXXXX)}"
mkdir -p "$WORK"
# WIDE ON PURPOSE, AND SHORT ON PURPOSE.  The screen has to be big enough to
# HOLD a window bigger than the backbuffer or the case cannot be constructed --
# but user/wsysd.ad refuses to start at all above MAX_PIXELS (1920*1080 =
# 2073600), and that is a PIXEL COUNT, not a width.  2400x820 is 1,968,000
# pixels: legal for the compositor, and 480 columns wider than BB_W.  This is
# the shape of a real 2560x1080 ultrawide, which wsysd also accepts.
GEOM="${HAMFB_GEOM:-2400x820}"
KEEP="${WIDE_KEEP:-0}"
export HAMWSYS="$WORK/wsys.shm"
export HAMWSYS_BB="$WORK/wsys.bb"
export HAMWSYS_IMG="$WORK/wsys.img"
export HAMFB_FILE="$WORK/fb.raw"
export HAMFB_GEOM="$GEOM"
export HAMLINUX_VNC=none
export HAMLINUX_DISTRO_RO=1
[ -r /usr/share/vulkan/icd.d/lvp_icd.json ] && \
    export VK_ICD_FILENAMES="${VK_ICD_FILENAMES:-/usr/share/vulkan/icd.d/lvp_icd.json}"
export XWAYLAND_NO_GLAMOR=1
FBW="${GEOM%x*}"; FBH="${GEOM#*x}"

# The device's own ceiling, and the only number in this file that is allowed to
# be a constant: BB_W/BB_H in user/linux-wsys.c.  Read from the source so this
# gate moves when they move rather than going quietly stale.
BBW="$(sed -n 's/^#define BB_W  *\([0-9]*\).*/\1/p' user/linux-wsys.c | head -1)"
BBH="$(sed -n 's/^#define BB_H  *\([0-9]*\).*/\1/p' user/linux-wsys.c | head -1)"
[ -n "$BBW" ] && [ -n "$BBH" ] || { echo "cannot read BB_W/BB_H from user/linux-wsys.c" >&2; exit 1; }

pass=0; fail=0
ok()   { echo "wide: PASS $*"; pass=$((pass+1)); }
bad()  { echo "wide: FAIL $*"; fail=$((fail+1)); }
info() { echo "wide: INFO $*"; }

info "$(priv_ns_describe)"
info "screen $GEOM, device maximum surface ${BBW}x${BBH}"

# EVERY child goes in the file registry, not a shell variable -- see reap.sh
# for the 61 leaked processes that bought that rule.
. tests/linux/reap.sh
reap_track "$WORK/reaped"
wipe() { [ "$KEEP" = 1 ] || rm -rf "$WORK"; }
reap_on_exit wipe

for t in Xwayland xterm xwininfo python3; do
    command -v "$t" >/dev/null || { echo "need $t on the host" >&2; exit 1; }
done

BIN="${WIDE_BIN:-$WORK}"
if [ -z "${WIDE_BIN:-}" ]; then
    for t in wsysd:user/wsysd.ad wsyswl:user/wsyswl.ad \
             hamdesktop:user/hamdesktop.ad wsys_poke:tests/linux/wsys_poke.ad; do
        name="${t%%:*}"; src="${t#*:}"
        scripts/hamlinux_build.sh "$src" "$WORK/$name.elf" >"$WORK/$name.build.log" 2>&1 || {
            echo "FAIL could not build $src" >&2; tail -20 "$WORK/$name.build.log" >&2; exit 1; }
    done
fi
ok "the compositor, the Wayland server, the desktop and the window probe all build"

poke()   { "$BIN/wsys_poke.elf" "$@" 2>/dev/null; }
winctl() { poke "/dev/wsys/$1/ctl"; }

# What fraction of a rectangle is exactly one colour.
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

"$BIN/wsysd.elf" </dev/null >"$WORK/wsysd.log" 2>&1 &
reap_add $!
for _ in $(seq 1 80); do [ -s "$HAMFB_FILE" ] && break; sleep 0.1; done
[ -s "$HAMFB_FILE" ] || { bad "wsysd never produced a framebuffer"; cat "$WORK/wsysd.log"; exit 1; }

# THE WALLPAPER IS THE INSTRUMENT for assertion D.  On a bare compositor the
# background is black and so is an unpainted window, and the two would be
# indistinguishable; hamdesktop's backdrop makes "nothing was painted here"
# a positive observation.
"$BIN/hamdesktop.elf" </dev/null >"$WORK/hamdesktop.log" 2>&1 &
reap_add $!
sleep 4
cp "$HAMFB_FILE" "$WORK/desktop.raw"

DISPNUM="${WIDE_DISPLAY:-:87}"
XSOCK="/tmp/.X11-unix/X${DISPNUM#:}"
[ -e "$XSOCK" ] && { echo "display $DISPNUM is already in use; set WIDE_DISPLAY" >&2; exit 1; }

WSYSWL_XWM="$XSOCK" "$BIN/wsyswl.elf" "$WORK/wayland-0" </dev/null \
    >"$WORK/wsyswl.log" 2>&1 &
reap_add $!
for _ in $(seq 1 60); do [ -S "$WORK/wayland-0" ] && break; sleep 0.1; done
[ -S "$WORK/wayland-0" ] || { bad "wsyswl never created its socket"; cat "$WORK/wsyswl.log"; exit 1; }
STATE="$WORK/wsyswl-state"
export XDG_RUNTIME_DIR="$WORK"
export WAYLAND_DISPLAY=wayland-0

Xwayland -rootless -shm -noreset "$DISPNUM" >"$WORK/xw.log" 2>&1 &
reap_add $!
for _ in $(seq 1 200); do [ -S "$XSOCK" ] && break; sleep 0.1; done
[ -S "$XSOCK" ] || { bad "Xwayland never created $XSOCK"; tail -20 "$WORK/xw.log"; exit 1; }
export DISPLAY="$DISPNUM"
for _ in $(seq 1 60); do
    [ "$(sed -n 's/^xwm_connected \([0-9]*\)$/\1/p' "$STATE" 2>/dev/null | tail -1)" = 1 ] && break
    sleep 0.25
done
[ "$(sed -n 's/^xwm_connected \([0-9]*\)$/\1/p' "$STATE" 2>/dev/null | tail -1)" = 1 ] \
    || { bad "the compositor never got an X connection -- nothing below can be asked"
         sed 's/^/wide:      /' "$WORK/wsyswl.log"; echo "wide: $pass passed, $fail failed"; exit 1; }
ok "wsyswl is serving and manages the X display at $XSOCK"

# ---------------------------------------------------------------------------
# THE TWO CLIENTS, AND WHERE THEY GO.
#
# xterm because it is already a dependency of this suite and a solid -bg is a
# colour the framebuffer can be asked about.  The WIDTH is what is under test,
# so it is measured from the window table rather than assumed from the
# character cell.
#
# PLACEMENT IS NOT LEFT TO THE X GEOMETRY.  win_open cascades a new toplevel
# and then clamps it onto the screen, so `+20+460` is a request, not a fact,
# and the first run of this gate had the wide window sitting on top of its own
# control -- which reads exactly like the control failing to paint.  The
# windows are moved with the compositor's own `geometry` verb, which is the
# desktop moving a window, the same one tests/linux/wsyswl_rootless.sh uses.
# ---------------------------------------------------------------------------
COL_N=ff00ff        # the control -- and, later, the window UNDERNEATH
COL_W=00ff88        # the one that is wider than the backbuffer

xterm -geometry 200x10 -bg "#$COL_N" -fg "#$COL_N" -T narrow -e "sleep 900" \
      >/dev/null 2>&1 &
reap_add $!
sleep 5
xterm -geometry 340x10 -bg "#$COL_W" -fg "#$COL_W" -T wide -e "sleep 900" \
      >/dev/null 2>&1 &
reap_add $!
sleep 7

# The wsys window table is the truth about what gets painted where: it is what
# user/wsysd.ad's compositing loop reads.  The X geometry is a different
# rectangle (the frame sits outside it) and is not used for anything here.
wid_of()  { poke /dev/wsys/windows | awk -v t="$1" '$2 == t {print $1; exit}'; }
NWID="$(wid_of narrow)"
WWID="$(wid_of wide)"
[ -n "$NWID" ] || bad "the narrow xterm never became a wsys window"
[ -n "$WWID" ] || bad "the wide xterm never became a wsys window"
if [ -z "$NWID" ] || [ -z "$WWID" ]; then
    info "/dev/wsys/windows: $(poke /dev/wsys/windows | tr '\n' '|')"
    sed 's/^/wide:      /' "$WORK/wsyswl.log" | tail -10
    echo "wide: $pass passed, $fail failed"; exit 1
fi
set -- $(winctl "$NWID"); NW=$4; NH=$5
set -- $(winctl "$WWID"); WW=$4; WH=$5
info "narrow wsys window $NWID: ${NW}x${NH}"
info "wide   wsys window $WWID: ${WW}x${WH}"

if [ "${WW:-0}" -gt "$BBW" ]; then
    ok "the wide client really is wider than the backbuffer ($WW > $BBW) -- the case exists"
else
    bad "the wide client is only ${WW}px; this host's xterm cell is too small to build the case"
    info "raise the column count in this script, or the framebuffer geometry"
fi
if [ "${NW:-0}" -gt 0 ] && [ "${NW:-0}" -le "$BBW" ]; then
    ok "the control is ${NW}px -- inside the backbuffer, as a control must be"
else
    bad "the control is ${NW}px, which is not a control for anything"
fi

# Apart, and both fully on the screen: the control up top, the wide one below.
NX=20;  NY=60
WX=20;  WY=400
poke "/dev/wsys/$NWID/ctl" "geometry $NX $NY $NW $NH"
poke "/dev/wsys/$WWID/ctl" "geometry $WX $WY $WW $WH"
sleep 3
cp "$HAMFB_FILE" "$WORK/shot.raw"
for wid in $(poke /dev/wsys/windows | awk '{print $1}'); do
    info "  wsys $wid ctl: $(winctl "$wid")"
done
shot() {   # shot <raw> <name.png> -- only when the caller asked for pictures
    [ -n "${WIDE_SHOT_DIR:-}" ] || return 0
    mkdir -p "$WIDE_SHOT_DIR"
    python3 - "$1" "$FBW" "$FBH" "$WIDE_SHOT_DIR/$2" <<'PY2'
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
PY2
    info "screenshot $WIDE_SHOT_DIR/$2"
}
shot "$WORK/shot.raw" apart.png

# --- A. THE INSTRUMENT ------------------------------------------------------
echo "wide: === A. does a window that FITS paint, right edge and all?"
LP="$(colourpct $((NX + 8))       $((NY + 8)) 60 $((NH - 16)) "$WORK/shot.raw" "$COL_N")"
RP="$(colourpct $((NX + NW - 70)) $((NY + 8)) 60 $((NH - 16)) "$WORK/shot.raw" "$COL_N")"
info "control window: left ${LP}% right ${RP}% of its own colour"
[ "${LP:-0}" -ge 80 ] && [ "${RP:-0}" -ge 80 ] \
    && ok "the control paints edge to edge -- the framebuffer instrument works" \
    || bad "the control does not paint (left ${LP}%, right ${RP}%); nothing below is evidence"

# --- B. THE PART THAT FITS --------------------------------------------------
echo "wide: === B. does a window WIDER than the backbuffer paint the part that fits?"
WLP="$(colourpct $((WX + 8))         $((WY + 8)) 60 $((WH - 16)) "$WORK/shot.raw" "$COL_W")"
WMP="$(colourpct $((WX + BBW - 120)) $((WY + 8)) 60 $((WH - 16)) "$WORK/shot.raw" "$COL_W")"
info "wide window: left ${WLP}%, at column $((BBW - 120)) ${WMP}%, of its own colour"
[ "${WLP:-0}" -ge 80 ] \
    && ok "the wide window paints its left edge" \
    || bad "the wide window paints NOTHING at its left edge (${WLP}%) -- every blit was refused"
[ "${WMP:-0}" -ge 80 ] \
    && ok "the wide window paints out to the backbuffer's width" \
    || bad "the wide window is blank at column $((BBW - 120)) (${WMP}%) -- it does not paint what it can"

# --- C. AND SAYS SO ---------------------------------------------------------
echo "wide: === C. is the truncation LOUD, with the numbers in it?"
# The width in the message is the SURFACE's, which is the wsys window's less
# the frame the X client draws inside it -- so it is compared to BBW, which is
# the number that has to be in the line, and not to $WW.
if grep -q 'columns wide and no window' "$WORK/wsyswl.log" \
   && grep -q "exceed $BBW" "$WORK/wsyswl.log"; then
    ok "wsyswl names the width it was asked for and the width it can send"
    info "$(grep -m1 'columns wide and no window' "$WORK/wsyswl.log")"
else
    bad "wsyswl cut a window's rows and told nobody -- a silent truncation"
    info "wsyswl stderr, $(grep -c . "$WORK/wsyswl.log") lines, none of them this:"
    sed 's/^/wide:      /' "$WORK/wsyswl.log" | tail -6
fi

# --- D. AND PAINTS NOTHING PAST THE LIMIT -----------------------------------
#
# The control is moved UNDER the wide window's right-hand strip -- the part of
# the wide window's declared rectangle that is past column BB_W.  Nothing may
# be painted there: the backbuffer has no pixels for it and the row buffer has
# no bytes for it.  If the control's colour survives, nothing was.  If it goes
# black, user/wsysd.ad walked x to the WINDOW's width and painted bytes from
# beyond the end of its 7680-byte row buffer over the top of it.
echo "wide: === D. is anything painted past column $BBW?"
if [ "$WW" -gt "$((BBW + 60))" ]; then
    UX=$((WX + BBW + 20))
    UY=$((WY + 20))
    poke "/dev/wsys/$NWID/ctl" "geometry $UX $UY $NW $NH"
    sleep 3
    cp "$HAMFB_FILE" "$WORK/under.raw"
    shot "$WORK/under.raw" under.png
    UPCT="$(colourpct $((UX + 4)) $((UY + 4)) \
                      $((WX + WW - UX - 8)) $((WH - 40)) "$WORK/under.raw" "$COL_N")"
    info "under the wide window's over-wide strip: ${UPCT}% is the window BEHIND it"
    [ "${UPCT:-0}" -ge 80 ] \
        && ok "nothing is painted past column $BBW -- the window behind shows through" \
        || bad "the strip past column $BBW was painted over (${UPCT}% survived) -- pixels from outside the row buffer"
else
    info "the wide window is only ${WW} wide; D needs more than $((BBW + 60))"
fi

echo "wide: --------------------------------------------------------------"
echo "wide: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
