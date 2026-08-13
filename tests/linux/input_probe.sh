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
#
# THIS GATE WAS RED FOR ITS KEY HALF, DETERMINISTICALLY, AND IT IS GREEN NOW.
# ========================================================================
# Kept in full because the WRONG diagnosis it carried is the useful part.
#
# WHAT IT LOOKED LIKE, 3 runs out of 3:
#
#     ok   pointer is window-local (50 50)
#     ok   left press arrived as 'd ... 1'
#     FAIL key events reached the window (the owner's own log)
#
# WHAT THE PREVIOUS PASS CONCLUDED, and it was wrong in its first clause: "the
# compositor is NOT at fault -- wsysd's published state says `focus 2` and
# `keys 1`, so route_key ran; the client's channel is bound; the uids agree;
# SO THE LOSS IS BETWEEN wsysd's sendto AND THE OWNER'S read." Every fact in
# that list was true. The inference was not, and the reason is worth keeping:
# `focus 2` and `keys 1` were read from a state line published LATER IN THE
# RUN. `keys 1` counts what handle_key DECODED, not what route_key delivered,
# and `focus 2` was true by the time it was read and false when it mattered.
# A counter that says a stage was entered is not a witness that it completed.
#
# WHAT IT ACTUALLY WAS, measured three ways (see the fix commit on
# user/wsysd.ad):
#   * strace of both processes: the client BINDS its channel and calls recvmsg
#     every 100 ms getting EAGAIN; wsysd issues exactly ONE sendto in the whole
#     run and it is the wake datagram. NEVER SENT -- which excludes both of the
#     other two candidates (credentials, zero-length read) outright.
#   * a debug line inside keychan_send and inside hamwsys_write's
#     HAMWSYS_WIN_KEYS branch: neither ever printed.
#   * a debug line at the top of route_key: `route_key code=97 focus=0`. The
#     decode was always right. `route_key`'s first line is
#     `if focus_wid < 2: return`.
#
# focus was 0 because `fd_is_waitable` -- the wait-set probe -- calls
# pump_input() and pump_keyboard() to reach quiescence, and it runs from
# build_waitset() BEFORE the main loop, so before the first scan_windows().
# The probe swallowed this gate's entire evdev file against an empty window
# table. The POINTER survived because motion and button edges are accumulated
# STATE that deliver_pointer routes later; a key is routed immediately and had
# nowhere to wait. That asymmetry is the whole reason this looked like a
# transport bug for two passes.
#
# WHAT THIS GATE PROVES AND WHAT IT DOES NOT. It proves a keystroke travels
# evdev record -> decode -> route -> keystroke channel -> the owning window's
# own read, in this tree's own code. tests/linux/wsys_keychan.sh does NOT
# cover that: it compiles one C file, links nothing from this tree, and
# measures KERNEL properties (abstract namespace, SCM_CREDENTIALS,
# first-binder-wins).
#
# It does NOT prove WHICH window a keystroke reaches. Measured: with the
# click-ordering half of the fix removed, this gate still passes 1 of 1, since
# one window plus wsysd's startup focus fallback makes the answer right
# whether or not the click was applied first. tests/linux/input_focus_key.sh
# is the gate for that half, and it catches exactly that removal -- with the
# key delivered to the WRONG WINDOW, not merely lost.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

# THE MACHINE THIS RUNS ON IS NOT SCRATCH.
#
# It sets HAMWSYS and HAMWSYS_BB and starts no desktop client, so the known residue
# was small -- which is not the same as measured. $WORK was a bare mktemp -d in the
# host's /tmp, and /srv and /dev/shm were the machine's.
#
# The names that matter are compiled into the binaries, not written here, so no
# care taken in this script can move them; the containment is the namespace.
# tests/linux/private_ns.sh has the table and the incident that bought it. This
# must come before anything that makes a file under /tmp, $WORK included, and
# before reap.sh, whose registry is itself a mktemp under /tmp.
. tests/linux/private_ns.sh
priv_ns_reexec "$@"

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
