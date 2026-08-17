#!/usr/bin/env bash
# Its host runtime and its pass/fail were NOT measured when this line was
# written. If you make it cheap enough for the battery, add the manifest line
# and delete this block.
#
# tests/linux/input_abs_pointer.sh — ABSOLUTE pointing devices land in the
# right place, and a touchpad is not a touchscreen.
#
# WHY THIS EXISTS. The owner booted the desktop on his Lenovo 20Y0X50600
# (1920x1200) and could not use it: the TrackPoint worked perfectly, the
# touchpad "ALWAYS RESETS BACK TO THE APPLICATIONS BUTTON" rather than moving
# the cursor from where it was, and a touch at the bottom-right corner of the
# touchscreen "only covers maybe a sixth of the screen".
#
# Relative input worked and absolute input did not, and both symptoms are one
# line of arithmetic. wsysd divided every EV_ABS value by 32768 -- the range
# QEMU's virtio-tablet advertises -- and multiplied by the screen. On a real
# i2c-hid device the range is its own:
#
#   * a touchpad reporting 0..1300 by 0..750 maps its ENTIRE surface onto
#     1300*1920/32768 = 76 by 750*1200/32768 = 27 pixels in the top-left
#     corner. hampanel's Applications button is x 0..56, y 0..24. The whole
#     touchpad WAS the Applications button, to within the size of the button.
#   * a touchscreen whose axes stop around 5500 reaches 5500/32768 = a sixth
#     of the way across. That is his "a sixth", and no other single constant
#     produces it.
#
# WHAT THIS GATE MEASURES, AND HOW. It runs the real compositor offscreen
# (HAMFB_FILE) at his exact 1920x1200, feeds it a file of evdev records --
# byte-identical to what a device delivers, 16 bytes of timeval then u16 type,
# u16 code, s32 value -- and then FINDS THE CURSOR IN THE FRAMEBUFFER. The
# assertion is on pixels wsysd actually painted, not on a number it printed
# about itself. The sprite is drawn with its top-left AT (ptr_x, ptr_y), so
# the first cursor-coloured pixel in scan order is the pointer position.
#
# WHICH COLOUR, AND WHY IT MATTERS. The first version of this looked for
# CUR_WHITE (0xf0f0f0) alone and reported the cursor one pixel down and right
# of where it was -- and reported NOCURSOR outright for a touch at the
# BOTTOM-RIGHT CORNER, which is the single most important case here. wsysd's
# cursor_init has a comment saying exactly why: row 0 is drawn inset, so the
# top-left pixel of the sprite is the DARK outline (0x202020) and not the
# white tip. At (1919,1199) every pixel but that one is clipped off the
# screen, so the finder was looking for the one pixel that was not there and
# would have called the fix broken. Both colours are matched now.
#
# THE DECLARED RANGE. A real device answers EVIOCGABS; a FILE has no ioctl
# interface, so the range and the INPUT_PROP_DIRECT/POINTER bit are declared
# with HAMWSYSD_ABS ("minx maxx miny maxy direct", five numbers per device in
# open order). That is a real limit on what this gate proves and it is stated
# again at the bottom: it proves the arithmetic and the property-bit logic,
# NOT that his particular touchpad reports 0..1300.
#
# THE INSTRUMENT IS PROVED ABLE TO TELL THE TWO APART BEFORE EITHER IS
# BELIEVED: case D feeds the SAME event file as case C and changes only the
# property bit, and the cursor must land somewhere else. If it did not, every
# other verdict here would be worthless.
#
# NEGATIVE CONTROL: ABSGATE_WSYSD=/path/to/an/old/wsysd.elf runs the whole
# thing against a binary built before the fix. Every absolute assertion here
# must go red there and the TrackPoint one must stay green -- which is the
# owner's bug, reproduced.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

# The names that matter -- /srv/wsys, /dev/shm/hamnix-wsys, /tmp/hamnix-* --
# are compiled into the binaries, not written here. The containment is the
# namespace, and it must come before anything that makes a file under /tmp,
# reap.sh's registry included.
. tests/linux/private_ns.sh
priv_ns_reexec "$@"

. tests/linux/reap.sh

WORK="$(mktemp -d)"
reap_track "$WORK/reaped"
cleanup() { [ -n "${KEEP:-}" ] || rm -rf "$WORK"; }
reap_on_exit cleanup

export HAMWSYS="$WORK/wsys.shm"
export HAMFB_FILE="$WORK/fb.raw"
# HIS PANEL, not a round number: the whole question is what a device range
# scales to, and 1920x1200 is what it has to scale to.
export HAMFB_GEOM=1920x1200
export HAMWSYS_BB="$WORK/wsys.bb"
# wsysd arms a REAL Vulkan backend on real silicon, and this host's GPU belongs
# to someone whose X session is live. Force the software ICD.
[ -r /usr/share/vulkan/icd.d/lvp_icd.json ] && \
    export VK_ICD_FILENAMES="${VK_ICD_FILENAMES:-/usr/share/vulkan/icd.d/lvp_icd.json}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1"; }

WSYSD="${ABSGATE_WSYSD:-}"
if [ -n "$WSYSD" ]; then
    echo "== NEGATIVE CONTROL: $WSYSD"
else
    WSYSD="$WORK/wsysd.elf"
    scripts/hamlinux_build.sh user/wsysd.ad "$WSYSD" >"$WORK/build.log" 2>&1 || {
        echo "FAIL could not build user/wsysd.ad"; sed 's/^/     /' "$WORK/build.log"
        exit 1; }
fi

# ---- the device ranges these cases declare -------------------------------
# A touchscreen in the band his "a sixth" implies, and a touchpad in the band
# a Synaptics/Elan clickpad reports. Both are PLAUSIBLE rather than measured;
# what is measured is where the compositor puts the cursor given them.
TS_MAXX=5759; TS_MAXY=3599          # touchscreen, INPUT_PROP_DIRECT
TP_MAXX=1300; TP_MAXY=750           # touchpad,    INPUT_PROP_POINTER
TS_DECL="0 $TS_MAXX 0 $TS_MAXY 1"
TP_DECL="0 $TP_MAXX 0 $TP_MAXY 0"

# ---- the cursor finder ---------------------------------------------------
cat >"$WORK/curfind.py" <<'PY'
import sys, struct
path, w, h = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
try:
    d = open(path, 'rb').read()
except OSError:
    print("NOFB"); sys.exit(1)
if len(d) < w * h * 4:
    print("SHORT"); sys.exit(1)
CUR = (0x202020, 0xf0f0f0)      # CUR_DARK, CUR_WHITE; (0,0) of the sprite is dark
for y in range(h):
    row = d[y * w * 4:(y + 1) * w * 4]
    for x in range(w):
        if (struct.unpack_from('<I', row, x * 4)[0] & 0xffffff) in CUR:
            print("%d %d" % (x, y)); sys.exit(0)
print("NOCURSOR"); sys.exit(1)
PY

# ---- the event files -----------------------------------------------------
# Every one is real evdev. Written by hand so the ORDER is the device's order:
# a touch frame is slot, tracking id, positions, then SYN_REPORT.
python3 - "$WORK" "$TS_MAXX" "$TS_MAXY" "$TP_MAXX" "$TP_MAXY" <<'PY'
import struct, sys
W, tsx, tsy, tpx, tpy = sys.argv[1], *map(int, sys.argv[2:6])
def ev(t, c, v): return struct.pack('<qqHHi', 0, 0, t, c, v)
SYN = ev(0, 0, 0)

def wr(name, b): open("%s/%s.bin" % (W, name), 'wb').write(b)

# A: the TrackPoint. Pure EV_REL. Must be untouched by any of this.
wr('rel', ev(2, 0, 100) + ev(2, 1, 50) + SYN)

# B: a touchscreen touch at the BOTTOM-RIGHT corner of the device.
wr('ts_br', ev(3, 47, 0) + ev(3, 57, 100) + ev(1, 330, 1) +
            ev(3, 53, tsx) + ev(3, 54, tsy) + ev(3, 0, tsx) + ev(3, 1, tsy) + SYN)

# C: a touchscreen touch at the exact CENTRE of the device.
wr('ts_mid', ev(3, 47, 0) + ev(3, 57, 101) + ev(1, 330, 1) +
             ev(3, 53, tsx // 2) + ev(3, 54, tsy // 2) +
             ev(3, 0, tsx // 2) + ev(3, 1, tsy // 2) + SYN)

# D: a TOUCHPAD SWIPE. First move the cursor somewhere with the TrackPoint so
# there is a "wherever it was" to be additive from, then put a finger down at
# (300,300) and drag it to (400,350). Both the ABS_MT_* and the ABS_* copies
# of each position are present, as a real touchpad sends them -- if the frame
# were not collapsed at the SYN, every delta would be counted twice.
sw  = ev(2, 0, 100) + ev(2, 1, 50) + SYN
sw += ev(3, 47, 0) + ev(3, 57, 7) + ev(1, 330, 1)
sw += ev(3, 53, 300) + ev(3, 54, 300) + ev(3, 0, 300) + ev(3, 1, 300) + SYN
sw += ev(3, 53, 400) + ev(3, 54, 350) + ev(3, 0, 400) + ev(3, 1, 350) + SYN
wr('tp_swipe', sw)

# E: a finger DOWN and nothing else. The cursor must not move at all -- this
# is the "resets back to the Applications button" symptom in one event.
wr('tp_down', ev(2, 0, 100) + ev(2, 1, 50) + SYN +
              ev(3, 47, 0) + ev(3, 57, 9) + ev(1, 330, 1) +
              ev(3, 53, 40) + ev(3, 54, 40) + ev(3, 0, 40) + ev(3, 1, 40) + SYN)

# F: LIFT AND PUT DOWN SOMEWHERE ELSE. Drag right, lift, touch down near the
# origin, drag a little. The second touch must continue from where the cursor
# was, not leap to the corner: a delta taken across a lifted finger is the
# other half of the same bug.
lp  = ev(2, 0, 100) + ev(2, 1, 50) + SYN
lp += ev(3, 47, 0) + ev(3, 57, 11) + ev(1, 330, 1)
lp += ev(3, 0, 600) + ev(3, 1, 400) + SYN
lp += ev(3, 0, 700) + ev(3, 1, 400) + SYN          # +100 units right
lp += ev(3, 57, -1) + ev(1, 330, 0) + SYN          # finger up
lp += ev(3, 57, 12) + ev(1, 330, 1)                # down again, far away
lp += ev(3, 0, 50) + ev(3, 1, 50) + SYN
lp += ev(3, 0, 100) + ev(3, 1, 50) + SYN           # +50 units right
wr('tp_liftput', lp)
PY

# ---- run one case --------------------------------------------------------
# Each case is its own compositor run against its own framebuffer: the cursor
# position is state, and a case that inherited the previous case's cursor
# would be measuring the wrong run.
run_case() {    # run_case <tag> <events.bin> <HAMWSYSD_ABS or "">  -> "x y"
    local tag="$1" evb="$2" decl="$3" pid
    rm -f "$WORK/fb.raw" "$WORK/wsys.shm" "$WORK/wsys.bb"
    if [ -n "$decl" ]; then export HAMWSYSD_ABS="$decl"; else unset HAMWSYSD_ABS; fi
    timeout 8 "$WSYSD" "$evb" </dev/null >"$WORK/$tag.log" 2>&1 &
    pid=$!
    reap_add $pid
    sleep 2
    kill $pid 2>/dev/null
    wait $pid 2>/dev/null
    python3 "$WORK/curfind.py" "$WORK/fb.raw" 1920 1200
}

# near <got> <want-x> <want-y> <tolerance>
near() {
    local got="$1" wx="$2" wy="$3" tol="$4" gx gy
    case "$got" in *[!0-9\ ]*) return 1 ;; esac
    gx="${got%% *}"; gy="${got##* }"
    [ $((gx - wx)) -le "$tol" ] && [ $((wx - gx)) -le "$tol" ] \
        && [ $((gy - wy)) -le "$tol" ] && [ $((wy - gy)) -le "$tol" ]
}

# ==========================================================================
# 0. THE INSTRUMENT ITSELF. Nothing below means anything until the cursor can
#    be found at all and found in a place chosen by input.
# ==========================================================================
BASE="$(run_case base /dev/null '')"
echo "     cursor with no input at all: $BASE   (expect the screen centre 960 600)"
if near "$BASE" 960 600 2; then
    ok "the cursor is findable in the framebuffer, at the startup centre"
else
    bad "the cursor is findable in the framebuffer, at the startup centre (got '$BASE')"
    echo "--- wsysd said:"; sed 's/^/    /' "$WORK/base.log"
    echo "     THE INSTRUMENT IS NOT WORKING; every verdict below is void."
    echo "$PASS PASSED / $((FAIL+1)) FAILED"; exit 1
fi

# ==========================================================================
# 1. THE TRACKPOINT, WHICH WORKS TODAY AND MUST GO ON WORKING.
# ==========================================================================
REL="$(run_case rel "$WORK/rel.bin" "$TS_DECL")"
echo "     TrackPoint REL_X+100 REL_Y+50 -> $REL   (expect 1060 650)"
if near "$REL" 1060 650 2; then
    ok "TrackPoint: relative motion is additive from the centre (1060 650)"
else
    bad "TrackPoint: relative motion is additive from the centre (got '$REL')"
fi

# ==========================================================================
# 2. THE TOUCHSCREEN. INPUT_PROP_DIRECT: the finger is on the pixel.
# ==========================================================================
TSBR="$(run_case ts_br "$WORK/ts_br.bin" "$TS_DECL")"
echo "     touchscreen bottom-right ($TS_MAXX,$TS_MAXY of $TS_MAXX,$TS_MAXY) -> $TSBR   (expect 1919 1199)"
if near "$TSBR" 1919 1199 2; then
    ok "touchscreen: the bottom-right corner is the bottom-right corner"
else
    bad "touchscreen: the bottom-right corner is the bottom-right corner (got '$TSBR')"
    # His symptom, named, so a red run says which bug it is.
    if near "$TSBR" $((TS_MAXX * 1920 / 32768)) $((TS_MAXY * 1200 / 32768)) 4; then
        echo "     ^ that is $((TS_MAXX * 100 / 32768))% of the way across --" \
             "the /32768 constant. THIS IS THE OWNER'S 'a sixth'."
    fi
fi

TSMID="$(run_case ts_mid "$WORK/ts_mid.bin" "$TS_DECL")"
echo "     touchscreen centre -> $TSMID   (expect ~959 599)"
if near "$TSMID" 959 599 3; then
    ok "touchscreen: the middle of the device is the middle of the screen"
else
    bad "touchscreen: the middle of the device is the middle of the screen (got '$TSMID')"
fi

# ==========================================================================
# 3. THE TOUCHPAD. INPUT_PROP_POINTER: additive from wherever the cursor is.
# ==========================================================================
# The TrackPoint prologue leaves it at (1060,650). The finger travels +100 of
# 1300 units in x and +50 of 750 in y, so the cursor travels
# 100*1920/1300 = 147 px and 50*1200/750 = 80 px: (1207, 730).
TPX=$((1060 + 100 * 1920 / TP_MAXX))
TPY=$((650 + 50 * 1200 / TP_MAXY))
SWIPE="$(run_case tp_swipe "$WORK/tp_swipe.bin" "$TP_DECL")"
echo "     touchpad swipe from (1060,650) -> $SWIPE   (expect $TPX $TPY)"
if near "$SWIPE" "$TPX" "$TPY" 2; then
    ok "touchpad: a swipe moves the cursor from where it was (additive)"
else
    bad "touchpad: a swipe moves the cursor from where it was (got '$SWIPE')"
    if near "$SWIPE" $((400 * 1920 / 32768)) $((350 * 1200 / 32768)) 4; then
        echo "     ^ that is the top-left corner, inside hampanel's" \
             "Applications button (x 0..56, y 0..24). THIS IS THE OWNER'S BUG."
    fi
fi

# AND IT SAYS WHAT IT DECIDED. On his machine that line is the only way to
# learn what the device actually reports -- this gate can only assert that the
# line exists and agrees with what it was told.
if grep -q "abs x 0\.\.$TP_MAXX y 0\.\.$TP_MAXY POINTER" "$WORK/tp_swipe.log"; then
    ok "wsysd logs the range and the kind it decided on, per device"
else
    bad "wsysd logs the range and the kind it decided on, per device"
    sed 's/^/     /' "$WORK/tp_swipe.log" | head -8
fi

DOWN="$(run_case tp_down "$WORK/tp_down.bin" "$TP_DECL")"
echo "     touchpad finger-down only, from (1060,650) -> $DOWN   (expect 1060 650)"
if near "$DOWN" 1060 650 2; then
    ok "touchpad: putting a finger down does not move the cursor"
else
    bad "touchpad: putting a finger down does not move the cursor (got '$DOWN')"
fi

# Lift and put down elsewhere: 100 units right, then 50 units right. NEITHER
# drag moves in y, so y must not change either -- and the wrong answer this
# guards against is x leaping to 50/1300 of the screen when the finger lands
# again near the origin.
LPX=$((1060 + 100 * 1920 / TP_MAXX + 50 * 1920 / TP_MAXX))
LP="$(run_case tp_liftput "$WORK/tp_liftput.bin" "$TP_DECL")"
echo "     touchpad drag, lift, re-touch far away, drag -> $LP   (expect $LPX 650)"
if near "$LP" "$LPX" 650 3; then
    ok "touchpad: a lifted finger does not drag the cursor when it lands again"
else
    bad "touchpad: a lifted finger does not drag the cursor when it lands again (got '$LP')"
fi

# ==========================================================================
# 4. THE INSTRUMENT CAN TELL THE TWO KINDS APART.
#    Same event file, same ranges, ONLY the property bit differs.
# ==========================================================================
XCHECK="$(run_case xcheck "$WORK/tp_swipe.bin" "0 $TP_MAXX 0 $TP_MAXY 1")"
echo "     the SAME swipe declared INPUT_PROP_DIRECT -> $XCHECK"
XX=$((400 * 1919 / TP_MAXX)); XY=$((350 * 1199 / TP_MAXY))
if near "$XCHECK" "$XX" "$XY" 2; then
    ok "declared DIRECT, the same records jump to the touched point ($XX $XY)"
else
    bad "declared DIRECT, the same records jump to the touched point (want $XX $XY, got '$XCHECK')"
fi
if [ "$XCHECK" != "$SWIPE" ]; then
    ok "the property bit CHANGES the outcome -- this gate can distinguish a touchpad from a touchscreen"
else
    bad "the property bit CHANGES the outcome (both gave '$SWIPE'; this gate cannot tell them apart and proves nothing)"
fi

# ==========================================================================
# 5. THE QEMU TABLET, unchanged. A device that declares nothing keeps the old
#    0..32767 absolute behaviour, or every VM would regress.
# ==========================================================================
python3 - "$WORK/tablet.bin" <<'PY'
import struct, sys
def ev(t, c, v): return struct.pack('<qqHHi', 0, 0, t, c, v)
open(sys.argv[1], 'wb').write(ev(3, 0, 32767) + ev(3, 1, 32767) + ev(0, 0, 0))
PY
TAB="$(run_case tablet "$WORK/tablet.bin" '')"
echo "     virtio-tablet 32767,32767 with nothing declared -> $TAB   (expect 1919 1199)"
if near "$TAB" 1919 1199 2; then
    ok "QEMU tablet: an undeclared, unprobeable device still spans the screen"
else
    bad "QEMU tablet: an undeclared, unprobeable device still spans the screen (got '$TAB')"
fi

echo "$PASS PASSED / $FAIL FAILED"
# WHAT A VM CANNOT SHOW. Every framebuffer here is a file and every evdev
# record is synthetic, so this proves the SCALING ARITHMETIC and the
# PROPERTY-BIT LOGIC and nothing about his hardware. The ranges above are
# declared, not measured; whether his touchpad really reports 0..1300 and his
# touchscreen really stops near 5500 can only be read off the machine itself
# (evtest, or hamin_abs_probe's own answer). What this gate does establish is
# that IF a device reports a range, the compositor now uses it.
[ "$FAIL" -eq 0 ]
