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
# THE KEY HALF OF THIS GATE IS RED, DETERMINISTICALLY, AND IT IS NOT FLAKE.
# ========================================================================
# Characterised but NOT fixed -- written down because the next person should
# start where this stopped rather than at the beginning. 3 runs out of 3:
#
#     ok   pointer is window-local (50 50)
#     ok   left press arrived as 'd ... 1'
#     FAIL key events reached the window (the owner's own log)
#
# WHAT IS PROVEN GOOD, each measured, not reasoned:
#   * The POINTER half passes off the SAME evdev file, so the decode, the
#     device read, the window lookup and the local-coordinate mapping all work.
#   * FOCUS IS CORRECT. wsysd's own published state says `focus 2` -- the
#     click did raise the client's window, so route_key's `focus_wid < 2`
#     early return is not being taken.
#   * THE COMPOSITOR ROUTED THE KEYSTROKE. The same state line says `keys 1`:
#     handle_key decoded KEY_A, kmap turned it into 'a', and route_key ran.
#   * THE CLIENT'S KEYSTROKE CHANNEL EXISTS AND IS BOUND BY THE CLIENT. The
#     abstract socket `@hamnix-wsys/<dev>.<ino>/2/keys` is present as a bound
#     u_dgr for the run's own segment. (Checked twice: the first check used a
#     truncating `head -5` and reported it ABSENT, which was wrong.)
#   * THE UIDS AGREE, so keychan_recv's SCM_CREDENTIALS test should accept:
#     inside the private namespace the shell, the segment owner and both
#     processes are uid 0, and seg_owner is fstat'ed at attach by the creator
#     too, so seg_owner_known is set.
#   * The segment's (dev,ino) -- which is what NAMES the channel -- is
#     identical before and after wsysd attaches, so sender and receiver derive
#     the same abstract name.
#
# SO THE LOSS IS BETWEEN wsysd's sendto AND THE OWNER'S read, AND THAT IS AS
# FAR AS THIS PASS GOT. Not isolated: whether the datagram is never sent, or
# sent and dropped by keychan_recv's credential test, or received and returned
# as zero bytes. Polling the socket's Recv-Q every 50 ms for 3 s never caught
# it nonzero, which does NOT settle it -- the owner's own 100 ms read tick
# could drain it between samples. The next step is to make the owner report a
# zero-length read distinctly from no read at all; today they are the same
# silence, which is exactly the shape of failure this tree keeps paying for.
#
# WHAT THIS IS NOT: it is not the private namespace (fc82e535) by any evidence
# gathered here, and it is not a build or harness limit -- the pointer half of
# the same run passes. tests/linux/wsys_keychan.sh being green does NOT cover
# it: that gate "compiles one C file and links nothing from this tree" and
# measures KERNEL properties (abstract namespace, SCM_CREDENTIALS, first-binder
# -wins), not this tree's channel. As far as this pass can tell, THIS FILE IS
# THE ONLY END-TO-END PROOF THAT A KEYSTROKE REACHES A WINDOW, and it is red,
# so the property is currently UNPROVEN rather than merely untested.
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
