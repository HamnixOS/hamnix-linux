#!/usr/bin/env bash
# tests/linux/wsyswl_ceiling.sh — HOW MANY X WINDOWS FIT ON THIS DESKTOP?
#
# THE QUESTION
# ============
# `wsyswl_rootless.sh` next door proved that two X clients on a rootless
# Xwayland are TWO Hamnix windows that move independently. That is the shape.
# This asks the thing that decides whether the shape can be the DEFAULT:
#
#     Rootful spends ONE v2 backbuffer slot on an entire X session.
#     Rootless spends one per TOPLEVEL. How many are there?
#
# Before this test the answer was eight, for the whole machine, and the
# failure mode at nine was the worst kind there is: a window that exists, has
# a wid, has correct geometry, appears in the window list, and is NEVER
# PAINTED, with no error anywhere. `BB_SLOTS` had already been raised once
# (3 -> 8) after exactly that -- "your fourth window is blank" -- so this is
# the second time the same silence was paid for.
#
# WHAT IS MEASURED, and it is pixels and not a count
# ==================================================
#   1. N X clients, each a solid block of a colour nothing else on the screen
#      is, moved by the DESKTOP onto a grid so that no two overlap.
#   2. Every one of them is a wsys window.
#   3. Every one of those windows' RECTANGLES IS ITS OWN COLOUR in the
#      framebuffer. A window record with nothing composited into it passes a
#      count and fails here, which is the entire point.
#   4. And the negative: when the pool IS exhausted, /dev/wsys/pool says so.
#      A ceiling nobody can read is a ceiling that gets discovered as "the
#      ninth window did not appear".
#
# N defaults to 12 -- more than the eight that used to be the whole machine's
# pool, which is the number the claim is about. Offscreen throughout.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

N="${CEIL_N:-12}"
WORK="${CEIL_WORK:-$(mktemp -d -p "${TMPDIR:-/tmp}" ceil.XXXXXX)}"
mkdir -p "$WORK"
GEOM="${HAMFB_GEOM:-1280x800}"
KEEP="${CEIL_KEEP:-0}"
# PRIVATE, all three -- see wsyswl_rootless.sh: one file per host with slots
# keyed by wid means two runs hand each other stale slots.
export HAMWSYS="$WORK/wsys.shm"
export HAMWSYS_BB="$WORK/wsys.bb"
export HAMWSYS_IMG="$WORK/wsys.img"
export HAMFB_FILE="$WORK/fb.raw"
export HAMFB_GEOM="$GEOM"
[ -r /usr/share/vulkan/icd.d/lvp_icd.json ] && \
    export VK_ICD_FILENAMES="${VK_ICD_FILENAMES:-/usr/share/vulkan/icd.d/lvp_icd.json}"
export XWAYLAND_NO_GLAMOR=1
FBW="${GEOM%x*}"; FBH="${GEOM#*x}"

pass=0; fail=0
ok()   { echo "ceil: PASS $*"; pass=$((pass+1)); }
bad()  { echo "ceil: FAIL $*"; fail=$((fail+1)); }
info() { echo "ceil: INFO $*"; }

KIDS=""; XWPID=""; WLPID=""; WSYSDPID=""
cleanup() {
    for p in $KIDS $XWPID $WLPID $WSYSDPID; do
        [ -n "${p:-}" ] && kill "$p" 2>/dev/null
    done
    sleep 0.5
    for p in $KIDS $XWPID $WLPID $WSYSDPID; do
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
         wsys_poke:tests/linux/wsys_poke.ad; do
    name="${t%%:*}"; src="${t#*:}"
    scripts/hamlinux_build.sh "$src" "$WORK/$name.elf" >"$WORK/$name.build.log" 2>&1 || {
        echo "FAIL could not build $src" >&2; tail -20 "$WORK/$name.build.log" >&2; exit 1; }
done
ok "the compositor, the Wayland server and the window probe all build"

poke()   { "$WORK/wsys_poke.elf" "$@" 2>/dev/null; }
winctl() { poke "/dev/wsys/$1/ctl"; }

FRAC_PY="$WORK/frac.py"
cat >"$FRAC_PY" <<'PY'
import sys
W, H = int(sys.argv[1]), int(sys.argv[2])
d = open(sys.argv[3], 'rb').read()
# argv[4:] is a flat list of  x y w h RRGGBB  quintuples; print one percentage
# per rectangle, so N windows cost ONE interpreter start rather than N.
out = []
a = sys.argv[4:]
for k in range(0, len(a), 5):
    x, y, w, h = (int(v) for v in a[k:k + 4])
    c = a[k + 4]
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
    out.append(0 if tot == 0 else hit * 100 // tot)
print(' '.join(str(v) for v in out))
PY

"$WORK/wsysd.elf" </dev/null >"$WORK/wsysd.log" 2>&1 &
WSYSDPID=$!
for _ in $(seq 1 60); do [ -s "$HAMFB_FILE" ] && break; sleep 0.1; done
[ -s "$HAMFB_FILE" ] || { bad "wsysd never produced a framebuffer"; cat "$WORK/wsysd.log"; exit 1; }

DISPNUM="${CEIL_DISPLAY:-:86}"
XSOCK="/tmp/.X11-unix/X${DISPNUM#:}"
[ -e "$XSOCK" ] && { echo "display $DISPNUM is already in use; set CEIL_DISPLAY" >&2; exit 1; }

WSYSWL_XWM="$XSOCK" "$WORK/wsyswl.elf" "$WORK/wayland-0" </dev/null \
    >"$WORK/wsyswl.log" 2>&1 &
WLPID=$!
for _ in $(seq 1 40); do [ -S "$WORK/wayland-0" ] && break; sleep 0.1; done
[ -S "$WORK/wayland-0" ] || { bad "wsyswl never created its socket"; cat "$WORK/wsyswl.log"; exit 1; }
STATE="$WORK/wsyswl-state"
export XDG_RUNTIME_DIR="$WORK"
export WAYLAND_DISPLAY=wayland-0

Xwayland -rootless -shm -noreset "$DISPNUM" >"$WORK/xw.log" 2>&1 &
XWPID=$!
for _ in $(seq 1 150); do [ -S "$XSOCK" ] && break; sleep 0.1; done
[ -S "$XSOCK" ] || { bad "Xwayland never created $XSOCK"; tail -20 "$WORK/xw.log"; exit 1; }
export DISPLAY="$DISPNUM"
for _ in $(seq 1 40); do
    [ "$(sed -n 's/^xwm_connected \([0-9]*\)$/\1/p' "$STATE" 2>/dev/null | tail -1)" = 1 ] && break
    sleep 0.25
done
if [ "$(sed -n 's/^xwm_connected \([0-9]*\)$/\1/p' "$STATE" 2>/dev/null | tail -1)" = 1 ]; then
    ok "the compositor's window manager has the X display"
else
    bad "the compositor never got an X connection -- nothing below can be asked"
    sed 's/^/ceil:      /' "$WORK/wsyswl.log"
    echo "ceil: $pass passed, $fail failed"; exit 1
fi

# ---------------------------------------------------------------------------
# 1. N X CLIENTS AT ONCE
# ---------------------------------------------------------------------------
echo "ceil: === 1. $N X clients on one rootless Xwayland"
# Twelve colours no two of which are within rounding distance of each other,
# and none of which is the desktop's background or its decoration.
PALETTE="ff0000 00ff00 0000ff ffff00 ff00ff 00ffff ff8000 8000ff 00ff80 ff0080 80ff00 0080ff"
COLS=($PALETTE)
while [ "${#COLS[@]}" -lt "$N" ]; do COLS+=("${COLS[$(( ${#COLS[@]} % 12 ))]}"); done

for i in $(seq 0 $((N - 1))); do
    xterm -geometry 30x8 -bg "#${COLS[$i]}" -fg "#${COLS[$i]}" \
          -T "w$i" -e "sleep 900" >/dev/null 2>&1 &
    KIDS="$KIDS $!"
    sleep 0.35
done
sleep 6

XCHILDREN="$(xwininfo -root -children 2>/dev/null | sed -n 's/^ *\(0x[0-9a-f]*\) "[^"]*".*/\1/p' | wc -l)"
info "the X root has $XCHILDREN mapped children"
[ "$XCHILDREN" -ge "$N" ] \
    && ok "all $N X clients mapped a toplevel" \
    || bad "only $XCHILDREN of $N X clients have a mapped toplevel"

sleep 1
for k in xwl_managed xwl_paired windows_high_water conns commits \
         drop_xwl_unpaired window_budget_full xwm_refused; do
    v="$(sed -n "s/^$k \([0-9-]*\)\$/\1/p" "$STATE" 2>/dev/null | tail -1)"
    info "$k ${v:-<absent>}"
done
POOL="$(poke /dev/wsys/pool)"
if [ -n "$POOL" ]; then
    info "/dev/wsys/pool: $POOL"
else
    info "/dev/wsys/pool: <the device serves no such file>"
fi

# ---------------------------------------------------------------------------
# 2. HOW MANY OF THEM ARE WSYS WINDOWS?
# ---------------------------------------------------------------------------
echo "ceil: === 2. how many are Hamnix windows, and are they PAINTED?"
WIDS=""
for wid in $(seq 2 200); do
    line="$(winctl "$wid")"
    [ -n "$line" ] || continue
    set -- $line
    [ "${8:-0}" = 1 ] || continue                  # visible
    [ "${4:-0}" = "$FBW" ] && continue             # not a full-screen backdrop
    WIDS="$WIDS $wid"
done
set -- $WIDS
NW=$#
if [ "$NW" -ge "$N" ]; then
    ok "/dev/wsys lists $NW application windows for $N X clients"
else
    bad "/dev/wsys lists $NW application windows for $N X clients -- $((N - NW)) never became windows"
fi

# THE DESKTOP PLACES THEM. wsyswl cascades new toplevels every three, so at
# twelve they sit on top of each other and "is this window painted" is not
# answerable from the framebuffer. Moving them is also the thing the desktop
# does, spelled as the same `geometry` verb wsysd's own dragging writes.
COLW=$(( (FBW - 40) / 4 ))
ROWH=$(( (FBH - 60) / 3 ))
idx=0
for wid in $WIDS; do
    col=$(( idx % 4 )); row=$(( idx / 4 % 3 ))
    gx=$(( 20 + col * COLW )); gy=$(( 40 + row * ROWH ))
    read -r _ _ _ ww hh _ <<<"$(winctl "$wid")"
    poke "/dev/wsys/$wid/ctl" "geometry $gx $gy $ww $hh"
    idx=$((idx + 1))
done
sleep 3
cp "$HAMFB_FILE" "$WORK/grid.raw"

# Which colour is which window? Ask the framebuffer: score every window's
# rectangle against every colour in one interpreter run and take the best.
ARGS=()
for wid in $WIDS; do
    read -r _ wx wy ww hh _ <<<"$(winctl "$wid")"
    for i in $(seq 0 $((N - 1))); do
        ARGS+=("$wx" "$wy" "$ww" "$hh" "${COLS[$i]}")
    done
done
SCORES=($(python3 "$FRAC_PY" "$FBW" "$FBH" "$WORK/grid.raw" "${ARGS[@]}"))

painted=0; blank=0; seen=""
idx=0
for wid in $WIDS; do
    best=0; bestc=""
    for i in $(seq 0 $((N - 1))); do
        s=${SCORES[$((idx * N + i))]}
        if [ "$s" -gt "$best" ]; then best=$s; bestc=${COLS[$i]}; fi
    done
    if [ "$best" -ge 30 ]; then
        painted=$((painted + 1))
        case " $seen " in *" $bestc "*) bad "wid $wid shows colour $bestc, which another window already claimed";; esac
        seen="$seen $bestc"
    else
        blank=$((blank + 1))
        info "wid $wid is NOT PAINTED: its best colour match is ${best}%"
    fi
    idx=$((idx + 1))
done
info "$painted of $NW windows are painted with their own client's colour; $blank are blank"
if [ "$painted" -ge "$N" ]; then
    ok "all $N X windows are on the framebuffer at once, each in its own colour"
else
    bad "only $painted of $N X windows are painted -- the paint pool is the ceiling"
fi

# ---------------------------------------------------------------------------
# 3. AND WHEN IT IS EXHAUSTED, DOES IT SAY SO?
# ---------------------------------------------------------------------------
echo "ceil: === 3. is the ceiling READABLE, or is it a blank window?"
POOL="$(poke /dev/wsys/pool)"
if [ -n "$POOL" ]; then
    ok "/dev/wsys/pool answers: $POOL"
    USED="$(sed -n 's#^slots \([0-9]*\)/.*#\1#p' <<<"$POOL")"
    TOTAL="$(sed -n 's#^slots [0-9]*/\([0-9]*\) .*#\1#p' <<<"$POOL")"
    EXH="$(sed -n 's#.* exhausted \([0-9]*\) .*#\1#p' <<<"$POOL")"
    info "parsed: used ${USED:-?} of ${TOTAL:-?}, exhaustions ${EXH:-?}"
    [ "${TOTAL:-0}" -ge "$N" ] \
        && ok "the pool has $TOTAL slots, which is more than the $N windows on screen" \
        || bad "the pool has ${TOTAL:-0} slots for $N windows"
    if [ "${EXH:-0}" = 0 ]; then
        ok "and it reports ZERO exhaustions -- no window went unpainted in silence"
    else
        bad "the paint pool was exhausted $EXH time(s) during this run"
    fi
else
    bad "/dev/wsys/pool does not exist -- an exhausted paint pool is unreadable"
fi

# ---------------------------------------------------------------------------
# 4. AND WHAT DOES A POOL THAT BIG COST?
#    The whole reason the pool could not simply be made large is that a slot
#    used to cost a screen-sized double buffer whether the window was
#    1920x1080 or 186x110 -- the segment was memset whole at creation and
#    memcpy'd whole on every frame. It is now sparse and touched only to the
#    window's own area, so the answer has to be measured in ALLOCATED BLOCKS
#    and not in the file's length, which is enormous on purpose.
# ---------------------------------------------------------------------------
echo "ceil: === 4. what does a pool this size actually cost?"
LEN="$(stat -c %s "$HAMWSYS_BB" 2>/dev/null || echo 0)"
ALLOC=$(( $(stat -c %b "$HAMWSYS_BB" 2>/dev/null || echo 0) * 512 ))
info "the backbuffer segment is $((LEN / 1024 / 1024)) MiB long and $((ALLOC / 1024)) KiB allocated"
# Twelve 186x110 windows, double buffered, is about 1 MiB of real pixels.
# Ten megabytes is a generous ceiling that a screen-sized-per-slot pool
# (12 * 16 MiB = 192 MiB) could not come near.
if [ "$ALLOC" -lt $((10 * 1024 * 1024)) ]; then
    ok "$N slots in use cost $((ALLOC / 1024)) KiB of real memory, not $((N * 16)) MiB"
else
    bad "$N windows allocated $((ALLOC / 1024 / 1024)) MiB -- a slot still costs a whole screen"
fi

if grep -c 'BACKBUFFER' "$WORK/wsysd.log" "$WORK/wsyswl.log" 2>/dev/null | grep -qv ':0$'; then
    info "a BACKBUFFER warning was printed:"
    grep -h 'BACKBUFFER' "$WORK/wsysd.log" "$WORK/wsyswl.log" 2>/dev/null | sed 's/^/ceil:      /'
fi

echo "ceil: $pass passed, $fail failed"
[ "$fail" = 0 ] || exit 1
