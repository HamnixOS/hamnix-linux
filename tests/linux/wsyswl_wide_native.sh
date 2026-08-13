#!/usr/bin/env bash
# tests/linux/wsyswl_wide_native.sh -- THE TWO THINGS tests/linux/wsyswl_wide_window.sh
# LEFT UNMEASURED: a NATIVE Wayland client over the device's width, and the
# HEIGHT axis at all.
#
#   native Wayland client -> wsyswl (Adder) -> /dev/wsys draw/ctl -> wsysd -> /dev/fb
#
# WHAT THE OTHER GATE ESTABLISHED, AND WHAT IT DID NOT
# ====================================================
# wsyswl_wide_window.sh measured an X client, through rootless Xwayland, wider
# than BB_W.  It found the defect that made such a window paint NOTHING, and it
# said in its own text that two things were left over:
#
#   1. A NATIVE Wayland client over BB_W was REASONED safe -- same commit_buffer
#      path -- and never measured.  This gate measures it.
#   2. THE HEIGHT AXIS WAS NEVER TESTED.  The clamp and its message are
#      symmetric with the width ones BY INSPECTION.  This gate measures them,
#      and it has to do it IN A SEPARATE RUN: user/wsysd.ad refuses a screen
#      over MAX_PIXELS (2073600), which is a PIXEL COUNT, so no single screen
#      can be both over 1920 wide and over 1080 tall.  Hence two phases, each
#      with its own compositor on its own framebuffer.
#
# WHY A PURPOSE-BUILT CLIENT (tests/linux/wl_size_client.c)
# ========================================================
# Because no native client on this host can construct the case, and the reason
# is itself a finding: user/wsyswl.ad:clamp_maximised cuts MAX_W/MAX_H to the
# device's ceiling, and set_fullscreen is answered with MAX_W/MAX_H too -- so
# weston-terminal --fullscreen on a 2400-wide screen is TOLD 1920 and never
# oversteps.  weston-simple-shm is a fixed 250x250.  A native client only
# exceeds the ceiling if it picks its own size and ignores the configure, which
# is exactly what Xwayland does for an X window.  wl_size_client does that
# deliberately, in one colour, speaking the wire itself.
#
# WHAT IS ASSERTED, EACH PHASE
# ============================
#   A. THE INSTRUMENT WORKS.  A native client INSIDE the ceiling paints, far
#      edge included.  Nothing below is evidence unless this passes in the
#      same run on the same compositor.
#   B. A client OVER the ceiling paints the part of itself that fits -- near
#      edge, and the line just inside the ceiling.
#   C. THE CUT IS LOUD, with both numbers in it, and NAMES THE RIGHT AXIS.
#      "columns" for width, "rows" for height.  A message that says columns
#      when it means rows costs somebody a day.
#   D. NOTHING IS PAINTED PAST THE CEILING.  The control window is moved under
#      the over-size window's declared-but-undrawable strip and has to survive.
#
# Offscreen throughout: HAMFB_FILE, HAMLINUX_VNC=none.  No X, no Xwayland, no
# DRM, no display.
#
# Env:
#   NATIVE_AXIS=width|height|both   (default both)
#   NATIVE_BIN=<dir>                use the binaries already in <dir> instead of
#                                   building.  THIS IS HOW THE OLD BUG IS SHOWN:
#                                   build wsysd/wsyswl/hamdesktop/wsys_poke from
#                                   a worktree at the commit before the fix and
#                                   point this at them.  A test that cannot show
#                                   the old bug is not testing the fix.  Same
#                                   shape as WIDE_BIN in wsyswl_wide_window.sh.
#   NATIVE_SHOT_DIR=<dir>           write PNGs of what landed on the screen.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

# Same reason as wsyswl_wide_window.sh: this starts the real desktop binaries
# and they write fixed /tmp names compiled into them.  Namespace FIRST.
. tests/linux/private_ns.sh
priv_ns_reexec "$@"

WORK="${NATIVE_WORK:-$(mktemp -d -p "${TMPDIR:-/tmp}" wlnat.XXXXXX)}"
mkdir -p "$WORK"
KEEP="${NATIVE_KEEP:-0}"
AXIS="${NATIVE_AXIS:-both}"
PREBUILT="${NATIVE_BIN:-}"

export HAMLINUX_VNC=none
export HAMLINUX_DISTRO_RO=1

BBW="$(sed -n 's/^#define BB_W  *\([0-9]*\).*/\1/p' user/linux-wsys.c | head -1)"
BBH="$(sed -n 's/^#define BB_H  *\([0-9]*\).*/\1/p' user/linux-wsys.c | head -1)"
[ -n "$BBW" ] && [ -n "$BBH" ] || { echo "cannot read BB_W/BB_H from user/linux-wsys.c" >&2; exit 1; }

pass=0; fail=0
ok()   { echo "native: PASS $*"; pass=$((pass+1)); }
bad()  { echo "native: FAIL $*"; fail=$((fail+1)); }
info() { echo "native: INFO $*"; }

info "$(priv_ns_describe)"
info "device maximum surface ${BBW}x${BBH}; axis=$AXIS binaries=${PREBUILT:-built here}"

. tests/linux/reap.sh
reap_track "$WORK/reaped"
wipe() { [ "$KEEP" = 1 ] || rm -rf "$WORK"; }
reap_on_exit wipe

command -v python3 >/dev/null || { echo "need python3 on the host" >&2; exit 1; }
command -v gcc >/dev/null     || { echo "need gcc on the host" >&2; exit 1; }

# --- build -----------------------------------------------------------------
#
# NATIVE_BIN IS HOW THE OLD BUG IS SHOWN.  The unfixed behaviour lives in two
# files at once -- the clamp in user/wsyswl.ad and bb_for's clamped comparison
# in user/linux-wsys.c, which is what stopped a re-fit from CLEARING the
# backbuffer between one row and the next -- and scripts/hamlinux_build.sh
# compiles user/linux-wsys.c from a fixed path inside the tree it is run from.
# So the honest way to build the old side is a git worktree at the parent of
# the fix and this gate pointed at its output, not a source shuffle in here.
BIN="$WORK/bin"; mkdir -p "$BIN"
if [ -n "$PREBUILT" ]; then
    for b in wsysd wsyswl hamdesktop wsys_poke; do
        [ -x "$PREBUILT/$b.elf" ] || { echo "NATIVE_BIN=$PREBUILT has no $b.elf" >&2; exit 1; }
    done
    BIN="$PREBUILT"
    info "using the binaries in $PREBUILT -- NOT built from this tree"
else
    build() {   # build <src> <out>
        scripts/hamlinux_build.sh "$1" "$2" >"$2.build.log" 2>&1 || {
            echo "FAIL could not build $1" >&2; tail -25 "$2.build.log" >&2; return 1; }
    }
    for t in wsysd:user/wsysd.ad wsyswl:user/wsyswl.ad \
             hamdesktop:user/hamdesktop.ad wsys_poke:tests/linux/wsys_poke.ad; do
        build "${t#*:}" "$BIN/${t%%:*}.elf" || exit 1
    done
fi
# The client is always built from THIS tree: it is the instrument, not the
# thing under test, and both sides of a before/after have to be measured with
# the same one.
CLIENT="$WORK/wl_size_client"
gcc -O1 -Wall -Wextra -o "$CLIENT" tests/linux/wl_size_client.c \
    >"$WORK/wlsz.build.log" 2>&1 || {
    echo "FAIL could not build tests/linux/wl_size_client.c" >&2
    cat "$WORK/wlsz.build.log" >&2; exit 1; }
ok "the Wayland server, the compositor, the desktop, the probe and the native client are all present"

# --- pixel arithmetic ------------------------------------------------------
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

shot_png() {   # shot_png <raw> <W> <H> <out.png>
    python3 - "$1" "$2" "$3" "$4" <<'PY2'
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
}

COL_N=ff00ff        # the control -- and, later, the window UNDERNEATH
COL_B=00ff88        # the one that is bigger than the device's ceiling

# ---------------------------------------------------------------------------
# ONE PHASE: bring a compositor up on its own framebuffer, put a control and an
# over-size native client on it, and ask the four questions.
#
# PLACEMENT IS GIVEN, NOT DERIVED.  win_open cascades a new toplevel and then
# clamps it onto the screen, so where a window lands is the compositor's answer
# and not the client's request -- the first run of the sibling gate had its
# over-size window sitting on top of its own control, which reads exactly like
# the control failing to paint.  Every window here is moved with the
# compositor's own `geometry` verb afterwards, and the two rectangles below are
# chosen so they cannot overlap on either screen.
#
# $1 axis (width|height)  $2 screen geom  $3 control WxH+X+Y  $4 over-size WxH+X+Y
# ---------------------------------------------------------------------------
phase() {
    local axis="$1" geom="$2" ctlg="$3" bigg="$4"
    local P="$WORK/$axis"; mkdir -p "$P"
    local FBW="${geom%x*}" FBH="${geom#*x}"
    local CW CH NX NY BW BH BX BY
    IFS='x+' read -r CW CH NX NY <<<"$ctlg"
    IFS='x+' read -r BW BH BX BY <<<"$bigg"
    # The device's ceiling ON THE AXIS UNDER TEST, and the other one for the
    # message check.
    local LIM=$BBW; local UNIT=columns
    [ "$axis" = height ] && { LIM=$BBH; UNIT=rows; }

    echo "native: =========================================================="
    echo "native: PHASE $axis -- screen $geom, control $ctlg, over-size $bigg"
    echo "native: =========================================================="

    export HAMWSYS="$P/wsys.shm"
    export HAMWSYS_BB="$P/wsys.bb"
    export HAMWSYS_IMG="$P/wsys.img"
    export HAMFB_FILE="$P/fb.raw"
    export HAMFB_GEOM="$geom"
    export XDG_RUNTIME_DIR="$P"
    export WAYLAND_DISPLAY=wayland-0

    colourpct() { python3 "$FRAC_PY" "$FBW" "$FBH" "$1" "$2" "$3" "$4" "$5" "$6"; }
    poke()   { "$BIN/wsys_poke.elf" "$@" 2>/dev/null; }

    "$BIN/wsysd.elf" </dev/null >"$P/wsysd.log" 2>&1 &
    reap_add $!
    local i
    for i in $(seq 1 80); do [ -s "$HAMFB_FILE" ] && break; sleep 0.1; done
    [ -s "$HAMFB_FILE" ] || { bad "[$axis] wsysd never produced a framebuffer"
                              sed 's/^/native:      /' "$P/wsysd.log" | tail -10; return 1; }

    # THE WALLPAPER IS THE INSTRUMENT for D: on a bare compositor an unpainted
    # window and the background are both black and cannot be told apart.
    "$BIN/hamdesktop.elf" </dev/null >"$P/hamdesktop.log" 2>&1 &
    reap_add $!
    sleep 4

    "$BIN/wsyswl.elf" "$P/wayland-0" </dev/null >"$P/wsyswl.log" 2>&1 &
    reap_add $!
    for i in $(seq 1 60); do [ -S "$P/wayland-0" ] && break; sleep 0.1; done
    [ -S "$P/wayland-0" ] || { bad "[$axis] wsyswl never created its socket"
                               sed 's/^/native:      /' "$P/wsyswl.log" | tail -10; return 1; }
    # WHAT THE DEVICE ITSELF SAYS ITS CEILING IS.  wsyswl reads this and will
    # not guess without it, so it is the first thing to look at when a clip
    # does not happen -- and on a pre-fix build the field is simply absent,
    # which is visible here rather than inferred.
    info "[$axis] /dev/wsys/pool: $(poke /dev/wsys/pool | tr '\n' ' ')"

    # --- the two clients ---------------------------------------------------
    "$CLIENT" ${NATIVE_CLIENT_V:+-v} -w "$CW" -h "$CH" -c "$COL_N" -t control -hold 120 \
        >"$P/ctl.log" 2>&1 &
    reap_add $!
    sleep 3
    "$CLIENT" ${NATIVE_CLIENT_V:+-v} -w "$BW" -h "$BH" -c "$COL_B" -t oversize -hold 120 \
        >"$P/big.log" 2>&1 &
    reap_add $!
    sleep 5

    info "[$axis] control client: $(tr '\n' '|' <"$P/ctl.log")"
    info "[$axis] oversize client: $(tr '\n' '|' <"$P/big.log")"

    local NWID BWID
    NWID="$(poke /dev/wsys/windows | awk '$2 == "control"  {print $1; exit}')"
    BWID="$(poke /dev/wsys/windows | awk '$2 == "oversize" {print $1; exit}')"
    if [ -z "$NWID" ] || [ -z "$BWID" ]; then
        bad "[$axis] a native client did not become a wsys window (control='$NWID' oversize='$BWID')"
        info "/dev/wsys/windows: $(poke /dev/wsys/windows | tr '\n' '|')"
        sed 's/^/native:      /' "$P/wsyswl.log" | tail -10
        return 1
    fi
    ok "[$axis] BOTH NATIVE WAYLAND CLIENTS BECAME WINDOWS -- wid $NWID and wid $BWID, no X anywhere in this run"
    local NW NH BWv BHv
    set -- $(poke "/dev/wsys/$NWID/ctl"); NW=$4; NH=$5
    set -- $(poke "/dev/wsys/$BWID/ctl"); BWv=$4; BHv=$5
    info "[$axis] control wsys window $NWID: ${NW}x${NH}"
    info "[$axis] oversize wsys window $BWID: ${BWv}x${BHv}"

    # Does the case exist at all, on the axis under test?
    local GOT=$BWv; [ "$axis" = height ] && GOT=$BHv
    if [ "${GOT:-0}" -gt "$LIM" ]; then
        ok "[$axis] the native client really is over the ceiling ($GOT > $LIM) -- the case exists"
    else
        bad "[$axis] the native client is only $GOT on this axis; the case was not constructed"
        return 1
    fi

    poke "/dev/wsys/$NWID/ctl" "geometry $NX $NY $NW $NH"
    poke "/dev/wsys/$BWID/ctl" "geometry $BX $BY $BWv $BHv"
    sleep 3
    cp "$HAMFB_FILE" "$P/shot.raw"
    [ -n "${NATIVE_SHOT_DIR:-}" ] && {
        mkdir -p "$NATIVE_SHOT_DIR"
        shot_png "$P/shot.raw" "$FBW" "$FBH" "$NATIVE_SHOT_DIR/$axis-apart.png"
        info "screenshot $NATIVE_SHOT_DIR/$axis-apart.png"; }

    # --- A. the instrument -------------------------------------------------
    echo "native: === A. [$axis] does a native client INSIDE the ceiling paint, far edge and all?"
    local LP FP
    if [ "$axis" = width ]; then
        LP="$(colourpct $((NX + 8))       $((NY + 8)) 40 $((NH - 16)) "$P/shot.raw" "$COL_N")"
        FP="$(colourpct $((NX + NW - 48)) $((NY + 8)) 40 $((NH - 16)) "$P/shot.raw" "$COL_N")"
    else
        LP="$(colourpct $((NX + 8)) $((NY + 8))       $((NW - 16)) 40 "$P/shot.raw" "$COL_N")"
        FP="$(colourpct $((NX + 8)) $((NY + NH - 48)) $((NW - 16)) 40 "$P/shot.raw" "$COL_N")"
    fi
    info "[$axis] control: near ${LP}%, far ${FP}%, of its own colour"
    if [ "${LP:-0}" -ge 80 ] && [ "${FP:-0}" -ge 80 ]; then
        ok "[$axis] a native Wayland client paints end to end -- the instrument works"
    else
        bad "[$axis] the control does not paint (near ${LP}%, far ${FP}%); nothing below is evidence"
    fi

    # --- B. the part that fits ---------------------------------------------
    echo "native: === B. [$axis] does a native client OVER the ceiling paint the part that fits?"
    local BP MP
    if [ "$axis" = width ]; then
        BP="$(colourpct $((BX + 8))         $((BY + 8)) 40 $((BHv - 16)) "$P/shot.raw" "$COL_B")"
        MP="$(colourpct $((BX + LIM - 120)) $((BY + 8)) 40 $((BHv - 16)) "$P/shot.raw" "$COL_B")"
    else
        BP="$(colourpct $((BX + 8)) $((BY + 8))         $((BWv - 16)) 40 "$P/shot.raw" "$COL_B")"
        MP="$(colourpct $((BX + 8)) $((BY + LIM - 120)) $((BWv - 16)) 40 "$P/shot.raw" "$COL_B")"
    fi
    info "[$axis] oversize window: near ${BP}%, at $UNIT $((LIM - 120)) ${MP}%, of its own colour"
    [ "${BP:-0}" -ge 80 ] \
        && ok "[$axis] the over-size window paints its near edge" \
        || bad "[$axis] the over-size window paints NOTHING at its near edge (${BP}%) -- every blit was lost"
    [ "${MP:-0}" -ge 80 ] \
        && ok "[$axis] the over-size window paints out to the device's ceiling" \
        || bad "[$axis] the over-size window is blank at $UNIT $((LIM - 120)) (${MP}%) -- it does not paint what it can"

    # --- C. and says so, ON THE RIGHT AXIS ---------------------------------
    echo "native: === C. [$axis] is the cut LOUD, with the numbers, and does it name $UNIT?"
    local WANT="$UNIT"
    if grep -q "$WANT.*no window on this system may exceed $LIM" "$P/wsyswl.log"; then
        ok "[$axis] wsyswl names the size it was asked for, the ceiling, and the axis ($UNIT)"
        info "[$axis] $(grep -m1 "no window on this system may exceed $LIM" "$P/wsyswl.log")"
    else
        bad "[$axis] wsyswl cut this window and did not say so in $UNIT against $LIM"
        info "[$axis] wsyswl stderr, $(grep -c . "$P/wsyswl.log") lines:"
        sed 's/^/native:      /' "$P/wsyswl.log" | tail -8
    fi
    # AND THE OTHER AXIS MUST NOT BE BLAMED.  A message that says columns when
    # it means rows is worse than no message: this project has already shipped
    # one that blamed a version mismatch that did not exist.
    local OTHER=rows; [ "$axis" = height ] && OTHER=columns
    if grep -q "$OTHER wide and no window\|$OTHER tall and no window" "$P/wsyswl.log"; then
        bad "[$axis] wsyswl also complained about $OTHER, which is not the axis that was exceeded"
    else
        ok "[$axis] wsyswl does NOT blame the other axis"
    fi

    # --- D. and paints nothing past the ceiling ----------------------------
    echo "native: === D. [$axis] is anything painted past $UNIT $LIM?"
    local UX UY
    if [ "$axis" = width ]; then UX=$((BX + LIM + 20)); UY=$((BY + 20))
    else                         UX=$((BX + 20));       UY=$((BY + LIM + 20))
    fi
    local room=1
    if [ "$axis" = width ]; then
        [ $((UX + NW)) -le "$FBW" ] || room=0
    else
        [ $((UY + NH)) -le "$FBH" ] || room=0
    fi
    if [ "$room" = 1 ]; then
        poke "/dev/wsys/$NWID/ctl" "geometry $UX $UY $NW $NH"
        sleep 3
        cp "$HAMFB_FILE" "$P/under.raw"
        [ -n "${NATIVE_SHOT_DIR:-}" ] && {
            shot_png "$P/under.raw" "$FBW" "$FBH" "$NATIVE_SHOT_DIR/$axis-under.png"
            info "screenshot $NATIVE_SHOT_DIR/$axis-under.png"; }
        local UPCT
        if [ "$axis" = width ]; then
            UPCT="$(colourpct $((UX + 4)) $((UY + 4)) $((BX + BWv - UX - 8)) $((NH - 8)) "$P/under.raw" "$COL_N")"
        else
            UPCT="$(colourpct $((UX + 4)) $((UY + 4)) $((NW - 8)) $((BY + BHv - UY - 8)) "$P/under.raw" "$COL_N")"
        fi
        info "[$axis] under the over-size window's undrawable strip: ${UPCT}% is the window BEHIND it"
        [ "${UPCT:-0}" -ge 80 ] \
            && ok "[$axis] nothing is painted past $UNIT $LIM -- the window behind shows through" \
            || bad "[$axis] the strip past $UNIT $LIM was painted over (${UPCT}% survived)"
    else
        info "[$axis] no room on the screen to put the control under the strip; D not asked"
    fi

    # LET THIS PHASE'S PROCESSES GO BEFORE THE NEXT ONE STARTS.  Both phases
    # run the same binaries with the same compiled-in fixed names, and a second
    # wsysd meeting the first one's segment is not a second measurement.  The
    # registry is emptied so the EXIT reap does not try again on dead pids --
    # and NOTHING here matches by pattern: pgrep -f has produced a wrong answer
    # in this tree seven times.
    reap_all
    : >"$REAP_FILE"
    sleep 1
    return 0
}

# WIDTH: 2400x820 is 1,968,000 pixels -- under MAX_PIXELS, and 480 columns
# wider than BB_W.  The shape of a real 2560x1080 ultrawide.
# HEIGHT: 1000x2000 is 2,000,000 pixels -- under MAX_PIXELS, and 920 rows
# taller than BB_H.  A portrait monitor, which is a real thing people own.
W_GEOM=2400x820;  W_CTL=400x140+20+60;   W_BIG=2100x600+2+210
H_GEOM=1000x2000; H_CTL=260x700+730+60;  H_BIG=700x1600+10+60
case "$AXIS" in
    width)  phase width  "$W_GEOM" "$W_CTL" "$W_BIG" ;;
    height) phase height "$H_GEOM" "$H_CTL" "$H_BIG" ;;
    both)   phase width  "$W_GEOM" "$W_CTL" "$W_BIG"
            phase height "$H_GEOM" "$H_CTL" "$H_BIG" ;;
    *) echo "NATIVE_AXIS must be width, height or both" >&2; exit 1 ;;
esac

echo "native: --------------------------------------------------------------"
echo "native: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
