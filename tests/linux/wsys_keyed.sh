#!/usr/bin/env bash
#
# REGISTRATION, 2026-08-17. Until this date scripts/test_gate_registration.sh
# globbed only scripts/test_*.sh, so this directory was invisible to the gate
# against unregistered gates and every file in it read as coverage without
# being coverage. This gate is ON-DEMAND: not in ci_battery_manifest.txt
# because nobody has measured its host runtime yet, and the battery is 12-way
# sharded under a 50-minute cap -- registering an unmeasured gate is how a
# shard goes from green to timed-out. Measure it, then move it into the
# manifest.
#
# Its host runtime and its pass/fail were NOT measured when this line was
# written. If you make it cheap enough for the battery, add the manifest line
# and delete this block.
#
# tests/linux/wsys_keyed.sh — DOES A WINDOW THAT PAINTS PART OF ITSELF LET THE
# DESKTOP SHOW THROUGH THE REST?
#
# THE BUG, as the machine's owner reported it
# ===========================================
# The Applications dropdown is the full width of the display with the right
# side blank, covering the wallpaper and the desktop icons.
#
# AND THE CLIENT WAS ALREADY CORRECT. `~/Hamnix/sys/src/9/port/devwsys.ad:8085`
# documents a `keyed` ctl verb and names `hampanelscene` IN ITS OWN COMMENT as
# the reason it exists -- "a panel that GROWS full-width to host an
# Applications dropdown, then paints only the bar + the menu card and leaves
# the rest of the grown band UNPAINTED". `user/hampanelscene.ad` has been
# writing `keyed 1` at two call sites the whole time. `user/linux-wsys.c`
# implemented neither `keyed` nor `blend`, and AN UNKNOWN CTL VERB IS SILENTLY
# IGNORED -- so a fix that exists upstream, that the client already asks for,
# regressed into a black rectangle in the port with every return code 0. Same
# shape and the same function as `background`/`pin`, which was found the same
# way and cost a desktop with no windows on it.
#
# WHAT IS MEASURED, in pixels, with a negative control
# ====================================================
#   1. A green backdrop, and above it an undecorated band the full width of
#      the screen whose scene paints only its left 200 px in magenta -- the
#      shape of the grown panel exactly.
#   2. keyed 1: the left is magenta and THE REST IS THE BACKDROP.
#   3. keyed 0, the same window, same scene: the rest is BLACK. That is the
#      control, and without it "the right side is green" only proves the
#      backdrop exists.
#   4. blend 1, a full-screen scrim of #00000066 over the same backdrop: the
#      desktop must be DIMMED and still visible, not covered.
#
# Offscreen: HAMFB_FILE, no VM, no display, seconds.
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

WORK="${KEYED_WORK:-$(mktemp -d -p "${TMPDIR:-/tmp}" keyed.XXXXXX)}"
mkdir -p "$WORK"
GEOM="${HAMFB_GEOM:-1280x800}"
KEEP="${KEYED_KEEP:-0}"
export HAMWSYS="$WORK/wsys.shm"
export HAMWSYS_BB="$WORK/wsys.bb"
export HAMWSYS_IMG="$WORK/wsys.img"
export HAMFB_FILE="$WORK/fb.raw"
export HAMFB_GEOM="$GEOM"
[ -r /usr/share/vulkan/icd.d/lvp_icd.json ] && \
    export VK_ICD_FILENAMES="${VK_ICD_FILENAMES:-/usr/share/vulkan/icd.d/lvp_icd.json}"
FBW="${GEOM%x*}"; FBH="${GEOM#*x}"

pass=0; fail=0
ok()   { echo "keyed: PASS $*"; pass=$((pass+1)); }
bad()  { echo "keyed: FAIL $*"; fail=$((fail+1)); }
info() { echo "keyed: INFO $*"; }

# A file-backed registry, because `hold` below is called as `A="$(hold a)"` and
# a command substitution is a subshell: a $HOLDERS variable assigned in there
# is gone by the time the trap reads it. See tests/linux/reap.sh.
. tests/linux/reap.sh
reap_track "$WORK/reaped"
cleanup() { [ "$KEEP" = 1 ] || rm -rf "$WORK"; }
reap_on_exit cleanup

for t in wsysd:user/wsysd.ad wsys_poke:tests/linux/wsys_poke.ad \
         wsys_hold:tests/linux/wsys_hold.ad; do
    name="${t%%:*}"; src="${t#*:}"
    scripts/hamlinux_build.sh "$src" "$WORK/$name.elf" >"$WORK/$name.build.log" 2>&1 || {
        echo "FAIL could not build $src" >&2; tail -20 "$WORK/$name.build.log" >&2; exit 1; }
done
ok "the compositor, the window probe and the window holder build"

poke()  { "$WORK/wsys_poke.elf" "$@" 2>/dev/null; }
# An offscreen wsysd must not open this host's real keyboard and mouse.
: >"$WORK/input.evdev"
export HAMWSYSD_INPUT="$WORK/input.evdev"

# A WINDOW NEEDS A LIVING OWNER. user/linux-wsys.c's win_reap_dead() destroys
# any window whose creating process has exited -- deliberately, so a client
# killed with SIGKILL leaves no rectangle behind -- so a test driving the
# window system with one wsys_poke per verb creates a window that is already
# dead by the next line, and the symptom is a compositor that paints nothing
# while every command returns 0. tests/linux/wsys_hold.ad is one process that
# makes the window, stays alive, and obeys a script file as the test appends
# to it.
hold() {    # hold <name> -> prints the wid; $WORK/<name>.script drives it
    : >"$WORK/$1.script"
    "$WORK/wsys_hold.elf" "$WORK/$1.script" >"$WORK/$1.wid" 2>"$WORK/$1.err" &
    reap_add $!
    for _ in $(seq 1 40); do [ -s "$WORK/$1.wid" ] && break; sleep 0.1; done
    tr -d '\n' <"$WORK/$1.wid"
}
say()   { echo "$2" >>"$WORK/$1.script"; sleep 0.4; }
# One pixel, as RRGGBB.
px() { python3 - "$HAMFB_FILE" "$FBW" "$1" "$2" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
W, x, y = int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
o = (y * W + x) * 4
print('%02x%02x%02x' % (d[o+2], d[o+1], d[o]) if o + 3 <= len(d) else 'none')
PY
}

"$WORK/wsysd.elf" </dev/null >"$WORK/wsysd.log" 2>&1 &
WSYSDPID=$!; reap_add "$WSYSDPID"
for _ in $(seq 1 60); do [ -s "$HAMFB_FILE" ] && break; sleep 0.1; done
[ -s "$HAMFB_FILE" ] || { bad "wsysd never produced a framebuffer"; cat "$WORK/wsysd.log"; exit 1; }

# MOVE THE POINTER OUT OF THE PICTURE. wsysd parks the cursor at the centre of
# the screen at startup and draws it there, so the first version of this test
# sampled (640,400), read 0x202020 -- the cursor sprite's dark grey, CUR_DARK
# -- and reported that the backdrop had not painted. It had. A pixel probe on
# a compositor has to say where the cursor is or it is measuring the cursor.
python3 - "$WORK/input.evdev" <<'PY'
import struct, sys
with open(sys.argv[1], 'ab') as f:
    for t, c, v in ((3, 0, 100), (3, 1, 100), (0, 0, 0)):   # ABS_X/Y ~4,2 px
        f.write(struct.pack('<qqHHi', 0, 0, t, c, v))
PY
sleep 0.6

# ---------------------------------------------------------------------------
# THE DESKTOP: a full-screen pinned backdrop, which is what hamdesktop is.
# ---------------------------------------------------------------------------
BACK="$(hold back)"
say back "ctl geometry 0 0 $FBW $FBH"
say back "ctl decorate 0"
say back "ctl background 1"
say back "scene fill 0 0 $FBW $FBH #00a000"
sleep 1.5
[ "$(px 640 400)" = "00a000" ] \
    && ok "the backdrop is on the screen (wid $BACK, green)" \
    || { bad "the backdrop did not paint: middle pixel is $(px 640 400)"
         sed 's/^/keyed:      /' "$WORK/wsysd.log" | tail -20
         echo "keyed: $pass passed, $fail failed"; exit 1; }

# ---------------------------------------------------------------------------
# THE GROWN PANEL: full width, paints its left 200 px only.
# ---------------------------------------------------------------------------
BAND="$(hold band)"
BANDY=300
say band "ctl geometry 0 $BANDY $FBW 200"
say band "ctl decorate 0"
say band "ctl z 9"
say band "scene fill 0 0 200 200 #ff00ff"
sleep 1.5

echo "keyed: === 1. the control: an ordinary window blits its whole rect"
L="$(px 100 $((BANDY + 100)))"; R="$(px 900 $((BANDY + 100)))"
info "unkeyed band: painted part $L, unpainted part $R"
[ "$L" = "ff00ff" ] \
    && ok "the part the scene painted is the scene's colour" \
    || bad "the painted part is $L, expected ff00ff"
[ "$R" = "000000" ] \
    && ok "and the part it did NOT paint is BLACK -- the reported bug, reproduced" \
    || bad "the unpainted part is $R; expected the black rectangle this is about"

echo "keyed: === 2. and with the verb the client has been writing all along"
say band "ctl keyed 1"
say band "scene fill 0 0 200 200 #ff00ff"
sleep 1.5
L="$(px 100 $((BANDY + 100)))"; R="$(px 900 $((BANDY + 100)))"
info "keyed band: painted part $L, unpainted part $R"
[ "$L" = "ff00ff" ] \
    && ok "the painted part is unchanged" \
    || bad "keyed changed the painted part to $L"
[ "$R" = "00a000" ] \
    && ok "and the desktop shows THROUGH the part the panel did not paint" \
    || bad "the unpainted part is $R, not the backdrop -- keyed did nothing"

echo "keyed: === 3. and it is not sticky: keyed 0 puts the black band back"
say band "ctl keyed 0"
say band "scene fill 0 0 200 200 #ff00ff"
sleep 1.5
R="$(px 900 $((BANDY + 100)))"
[ "$R" = "000000" ] \
    && ok "keyed 0 is opaque again ($R)" \
    || bad "keyed 0 still shows $R -- the flag is not being read per frame"
say band "ctl hide"
sleep 1

# ---------------------------------------------------------------------------
# 4. BLEND: hamshotui's "select area" scrim, which is meant to DIM the
#    desktop and is currently an opaque black rectangle over the thing it is
#    dimming.
# ---------------------------------------------------------------------------
echo "keyed: === 4. blend: does a scrim dim the desktop or cover it?"
SCRIM="$(hold scrim)"
say scrim "ctl geometry 0 0 $FBW $FBH"
say scrim "ctl decorate 0"
say scrim "ctl z 10"
say scrim "ctl blend 1"
say scrim "scene fill 0 0 $FBW $FBH #00000066"
sleep 1.5
S="$(px 640 400)"
info "a #00000066 scrim over #00a000 reads $S"
# THE ARITHMETIC, because a magic constant here is unfalsifiable. The scrim is
# black at alpha 0x66 = 102, so the surviving fraction of the backdrop is
# (255-102)/255 = 0.6, and the backdrop's green is 0xa0 = 160: 160 * 153 / 255
# = 96 = 0x60. Anything else is not source-over.
if [ "$S" = "006000" ]; then
    ok "the desktop is DIMMED and still there -- source-over, not a cover"
elif [ "$S" = "000000" ]; then
    bad "the scrim is OPAQUE BLACK over the desktop it is meant to dim"
    info "this is what it did before lib/vk/vk_2d.ad's source-over composed the"
    info "ALPHA channel as well as the colour: a translucent scene fill left the"
    info "rasterizer's image opaque, so the present had nothing to blend with."
else
    bad "the scrim reads $S, which is neither dimmed (006000) nor opaque (000000)"
fi

echo "keyed: $pass passed, $fail failed"
[ "$fail" = 0 ] || exit 1
