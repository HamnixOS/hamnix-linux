#!/usr/bin/env bash
# tests/linux/input_probe.sh — prove the compositor ROUTES real input.
#
# The window system can be entirely correct and the desktop still be a
# picture. What makes it a desktop is that a mouse event picked up from
# /dev/input lands in the right window's pointer ring, in window-LOCAL
# coordinates, and that a keystroke lands in the FOCUSED window's keys ring.
#
# This drives exactly that path with a file of real evdev records. A file is
# byte-identical to what the device delivers -- struct input_event is 16 bytes
# of timeval then u16 type, u16 code, s32 value -- so nothing about the decode
# is stubbed out for the test.
#
# It runs offscreen (HAMFB_FILE), so it never touches the host's display.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# A bare EXIT trap does not run when the shell is killed by a signal, so a
# gate stopped by `timeout` (TERM) or ^C (INT) skipped its cleanup entirely.
# Re-exit on those, which makes the EXIT trap above run on every path out.
trap 'exit 130' INT TERM HUP
export HAMWSYS="$WORK/wsys.shm"
export HAMFB_FILE="$WORK/fb.raw"
export HAMFB_GEOM=800x600
# The v2 backbuffer segment defaults to one file per HOST, outliving every
# process that touches it, with slots keyed by wid -- two runs sharing it hand
# each other stale slots. Private, like the main segment above.
export HAMWSYS_BB="$WORK/wsys.bb"
# wsysd arms a REAL Vulkan backend when the device is real silicon, and this
# host has a GPU in it that belongs to someone. Nothing offscreen may touch
# it: force the software ICD, the same rule every other offscreen gate here
# follows. Without this line an ordinary `make test` runs the compositor on
# the developer's display adapter.
[ -r /usr/share/vulkan/icd.d/lvp_icd.json ] && \
    export VK_ICD_FILENAMES="${VK_ICD_FILENAMES:-/usr/share/vulkan/icd.d/lvp_icd.json}"

for t in wsysd:user/wsysd.ad client:tests/linux/wsys_client.ad \
         reader:tests/linux/input_reader.ad; do
    name="${t%%:*}"; src="${t#*:}"
    scripts/hamlinux_build.sh "$src" "$WORK/$name.elf" >/dev/null 2>&1 || {
        echo "FAIL could not build $src" >&2; exit 1; }
done

# The client maps a window at (100,60) 320x200 and stays alive.
"$WORK/client.elf" keep >"$WORK/client.log" 2>&1 &
CLIENT=$!
sleep 0.5

# The events. The window is at (100,60); a pointer at screen (150,110) is
# window-local (50,50). The compositor starts the pointer at the screen
# centre (400,300), so the relative moves are the difference.
python3 - "$WORK/events.bin" <<'PY'
import struct, sys
def ev(t, c, v):
    return struct.pack('<qqHHi', 0, 0, t, c, v)
out = b''
out += ev(2, 0, 150 - 400)          # EV_REL REL_X
out += ev(2, 1, 110 - 300)          # EV_REL REL_Y
out += ev(0, 0, 0)                  # EV_SYN
out += ev(1, 272, 1)                # EV_KEY BTN_LEFT press
out += ev(0, 0, 0)
out += ev(1, 30, 1)                 # EV_KEY KEY_A press  -> 'a'
out += ev(1, 30, 0)
out += ev(0, 0, 0)
open(sys.argv[1], 'wb').write(out)
PY

timeout 4 "$WORK/wsysd.elf" "$WORK/events.bin" </dev/null >"$WORK/wsysd.log" 2>&1 &
WSYSD=$!
sleep 2

# THE READER DRAINS THE POINTER RING; THE WINDOW'S OWNER REPORTS ITS OWN KEYS.
#
# This used to be one reader process asking for both.  It cannot be, any more:
# a window's keystrokes are delivered to whoever holds its channel and only the
# OWNER can hold one (THE KEYSTROKE CHANNEL in user/linux-wsys.c), so a separate
# reader asking for another window's keys is exactly the keylogger that closed,
# and it is refused BY NAME rather than answered with a silent zero.  The
# pointer ring is unchanged and still in the shared segment, so the reader still
# answers for it.  The client echoes every key line it receives into its own log
# and the assertion below reads it there -- which is the more truthful witness
# anyway: it is the window saying what it got.
"$WORK/reader.elf" 2 >"$WORK/reader.log" 2>&1
RC=$?
kill $WSYSD $CLIENT 2>/dev/null
wait 2>/dev/null

cat "$WORK/reader.log"
# KEY_A is Linux keycode 30; what must arrive is ASCII 'a' = 97.
if grep -q "wsys_client: keys .*d 97" "$WORK/client.log"; then
    echo "ok   key events reached the window, and KEY_A arrived as ASCII 97"
else
    echo "FAIL key events reached the window (the owner's own log):"
    sed 's/^/     /' "$WORK/client.log"
    RC=1
fi
if [ $RC -ne 0 ]; then
    echo "--- wsysd said:"; sed 's/^/    /' "$WORK/wsysd.log"
fi
exit $RC
