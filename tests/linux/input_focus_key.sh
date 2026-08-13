#!/usr/bin/env bash
# tests/linux/input_focus_key.sh — CLICK A WINDOW, TYPE, AND THE LETTER MUST
# LAND IN THE WINDOW YOU CLICKED.
#
# WHY THIS EXISTS AND WHY input_probe.sh IS NOT IT
# ================================================
# tests/linux/input_probe.sh drives one window and asserts that a keystroke
# reaches it. That is the end-to-end proof the tree needed and it is green
# again, but it CANNOT see the half of the routing that decides WHICH window a
# keystroke goes to, and it proved so by measurement: with the click-ordering
# fix in user/wsysd.ad's pump_input REMOVED, input_probe.sh still passed 1/1.
# One window plus wsysd's startup focus fallback means its key would arrive
# whether or not the click had been applied first.
#
# So this gate asks the question the other one cannot:
#
#     TWO windows. The compositor focuses the TOPMOST at startup. A click
#     lands on the OTHER one, and a keystroke follows it IN THE SAME BATCH OF
#     EVDEV RECORDS. The letter must be delivered to the window that was
#     CLICKED, and the window that merely started out focused must receive
#     NOTHING.
#
# The second half of that is not a nicety. A keystroke delivered to the window
# that used to have focus is the desktop typing a password into the wrong
# program, and it is the failure mode you get for free if focus is applied
# after the key rather than before it.
#
# WHY "IN THE SAME BATCH" IS THE REAL CASE. pump_input drains every record the
# node has pending in one pass, and a press is not routed as it is read -- it
# only sets ptr_edge, and deliver_pointer (the ONLY thing that moves focus) is
# what turns it into a click. A key is routed IMMEDIATELY. So a person who
# clicks a window and types within one poll of the click is exactly this test.
# The file of evdev records is byte-identical to what the device delivers, so
# nothing about the decode is stubbed out.
#
# THE DEFECT THIS WOULD HAVE CAUGHT, measured on this tree before the fix: the
# key went to the startup-focused window, not the clicked one.
#
# It runs offscreen (HAMFB_FILE) and never touches the host's display.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

# The names that matter -- /srv/wsys, /dev/shm/hamnix-wsys, /tmp/hamnix-* --
# are compiled into the binaries, not written here, so no care taken in this
# script can move them. The containment is the namespace, and it must come
# before anything that makes a file under /tmp, reap.sh's registry included.
. tests/linux/private_ns.sh
priv_ns_reexec "$@"

. tests/linux/reap.sh

WORK="$(mktemp -d)"
reap_track "$WORK/reaped"
cleanup() { rm -rf "$WORK"; }
reap_on_exit cleanup

export HAMWSYS="$WORK/wsys.shm"
export HAMFB_FILE="$WORK/fb.raw"
export HAMFB_GEOM=800x600
export HAMWSYS_BB="$WORK/wsys.bb"
# wsysd arms a REAL Vulkan backend on real silicon, and this host's GPU belongs
# to someone. Force the software ICD, like every other offscreen gate here.
[ -r /usr/share/vulkan/icd.d/lvp_icd.json ] && \
    export VK_ICD_FILENAMES="${VK_ICD_FILENAMES:-/usr/share/vulkan/icd.d/lvp_icd.json}"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "ok   $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL $1"; }

for t in wsysd:user/wsysd.ad zclient:tests/linux/wsys_zclient.ad; do
    name="${t%%:*}"; src="${t#*:}"
    scripts/hamlinux_build.sh "$src" "$WORK/$name.elf" >/dev/null 2>&1 || {
        echo "FAIL could not build $src" >&2; exit 1; }
done

# TWO WINDOWS THAT DO NOT OVERLAP, so "which window is under the pointer" has
# one answer and the assertion is not about stacking.
#
#   LOW  at (100,60) 300x200, z 6   -- the one that gets CLICKED
#   HIGH at (450,60) 300x200, z 9   -- topmost, so wsysd focuses it at startup
#
# z 9 is under the panel band (z >= 100) that pick_focus excludes, so HIGH is
# a legitimate startup focus rather than an accident of the exclusion rule.
# BOTH ARE DECORATED (the trailing 1). That is not cosmetic: pick_focus()
# skips undecorated windows entirely, so with the default flat rectangles the
# compositor focuses NEITHER, focus_wid stays 0, and "the unclicked window
# received nothing" would be true for the wrong reason -- nothing would be
# focused at all and no key could reach anybody. Measured that way first.
"$WORK/zclient.elf" 100 60 300 200 6 3366AA lowwin  20 1 >"$WORK/low.log"  2>&1 &
reap_add $!
"$WORK/zclient.elf" 450 60 300 200 9 AA6633 highwin 20 1 >"$WORK/high.log" 2>&1 &
reap_add $!
sleep 1

LOW_WID="$(sed -n 's/^wsys_zclient: mapped wid \([0-9]*\)$/\1/p' "$WORK/low.log"  | head -1)"
HIGH_WID="$(sed -n 's/^wsys_zclient: mapped wid \([0-9]*\)$/\1/p' "$WORK/high.log" | head -1)"
if [ -n "$LOW_WID" ] && [ -n "$HIGH_WID" ] && [ "$LOW_WID" != "$HIGH_WID" ]; then
    ok "two windows mapped (low=$LOW_WID high=$HIGH_WID)"
else
    bad "two windows mapped (low='$LOW_WID' high='$HIGH_WID')"
    echo "--- low:";  sed 's/^/    /' "$WORK/low.log"
    echo "--- high:"; sed 's/^/    /' "$WORK/high.log"
    exit 1
fi

# ONE BATCH: move onto LOW, press, and type 'a' -- no gap anywhere, which is
# the point. The compositor starts the pointer at the screen centre (400,300),
# so the relative moves are the difference to (200,140), well inside LOW.
python3 - "$WORK/events.bin" <<'PY'
import struct, sys
def ev(t, c, v):
    return struct.pack('<qqHHi', 0, 0, t, c, v)   # timeval, type, code, value
out  = ev(2, 0, 200 - 400)          # EV_REL REL_X
out += ev(2, 1, 140 - 300)          # EV_REL REL_Y
out += ev(0, 0, 0)                  # EV_SYN
out += ev(1, 272, 1)                # EV_KEY BTN_LEFT press
out += ev(0, 0, 0)
out += ev(1, 30, 1)                 # EV_KEY KEY_A press  -> 'a' = 97
out += ev(1, 30, 0)
out += ev(0, 0, 0)
open(sys.argv[1], 'wb').write(out)
PY

timeout 6 "$WORK/wsysd.elf" "$WORK/events.bin" </dev/null >"$WORK/wsysd.log" 2>&1 &
reap_add $!
# The clients poll their own channel on a 100 ms tick and live 20 s; 3 s is
# thirty of those ticks after the compositor has drained the file.
sleep 3

# THE WINDOWS ARE THE WITNESSES. Only the owner can hold a keystroke channel,
# so each window's own log is the only place this can be read.
if grep -q "wsys_zclient: keys .*d 97" "$WORK/low.log"; then
    ok "the CLICKED window received the keystroke (KEY_A as ASCII 97)"
else
    bad "the CLICKED window received the keystroke"
    echo "--- clicked window (wid $LOW_WID) said:"; sed 's/^/    /' "$WORK/low.log"
fi

# AND THE OTHER ONE MUST BE DEAF. This is the assertion that makes the first
# one mean something: a compositor that broadcast every key would pass the
# check above and be a keylogger.
if grep -q "wsys_zclient: keys" "$WORK/high.log"; then
    bad "the window that was NOT clicked received a keystroke"
    echo "--- unclicked window (wid $HIGH_WID) said:"; sed 's/^/    /' "$WORK/high.log"
else
    ok "the window that was NOT clicked received nothing"
fi

if [ $FAIL -ne 0 ]; then
    echo "--- wsysd said:"; sed 's/^/    /' "$WORK/wsysd.log"
fi
echo "$PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
