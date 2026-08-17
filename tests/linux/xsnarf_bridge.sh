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
# tests/linux/xsnarf_bridge.sh — ONE clipboard, across the namespace boundary.
#
# The oracle for user/xsnarfd.ad. QEMU-free: an Xvfb and a couple of xclips
# stand in for "an X client inside a distribution namespace", and the SAME two
# probes tests/linux/snarf_device.sh uses stand in for the Hamnix side --
# tests/linux/snarfcopy.ad copies through lib/hamtextbox.ad (the editor / Notes
# / URL-bar path) and tests/linux/snarfpaste.ad pastes through lib/htermsel.ad
# (the grid terminal's path). So what is asserted here is not "the bridge ran":
# it is copy in one world, paste in the other, through the shipped toolkit
# code, in separate processes.
#
# WHY Xvfb AND NOT THE REAL Xwayland. What the bridge talks to is an X SERVER
# over a unix socket at a path, and Xwayland's difference from Xvfb -- that it
# is itself a Wayland client -- is on the far side of the server, in the pixels.
# Nothing in the selection protocol changes. Using Xvfb keeps this gate off
# QEMU and off the host's display; tests/linux/xsnarf_ondevice.sh is the arm
# that runs against the real Xwayland inside a real namespace, because
# offscreen proof is not on-device proof and this line has been caught by that
# gap before.
#
# WHY IT RUNS UNDER A PRIVATE MOUNT NAMESPACE WITH A tmpfs OVER /tmp. The X
# socket lives in /tmp/.X11-unix, the host's /tmp is a 16 GB tmpfs belonging to
# somebody who is using this machine, and two agents running this at once must
# not see each other's display. The tmpfs makes the display number private, so
# :77 here cannot collide with :77 there. The clipboard segment is pinned with
# $HAMSNARF for the same reason (docs/steam_namespace.md §11 -- the shared file
# that bit).
#
# NOTHING HERE TOUCHES THE HOST'S DISPLAY, sound, or /dev. Xvfb scans out to
# memory by definition.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
# REAP WHAT YOU START. This gate had no trap at all: everything it launched in
# the background survived any exit that was not the happy one -- an assertion
# that bailed early, a `timeout`, a ^C. tests/linux/reap.sh keeps a file-backed
# registry of this run's own children and kills them on every path out.
. tests/linux/reap.sh
reap_on_exit

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  PASS  $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL  $*"; }
chk()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$2] got [$3]"; fi }
has()  { if [ -n "$3" ] && [[ "$3" == *"$2"* ]]; then ok "$1"; else bad "$1: [$3] does not contain [$2]"; fi }

# THE TOOLS ARE CHECKED BY NAME AND THE ABSENCE IS NOT A PASS. A gate that
# quietly skips its own subject is the success-shaped failure NORTH_STAR names.
for t in Xvfb xclip xdpyinfo unshare; do
    command -v "$t" >/dev/null 2>&1 || {
        echo "[xsnarf] CANNOT RUN: no $t on this host. This gate needs Xvfb + xclip;"
        echo "[xsnarf] it is NOT passing, it did not run."
        exit 2
    }
done

OUT="${XSNARF_TEST_OUT:-build/xsnarf}"
mkdir -p "$OUT" || exit 1

echo "[xsnarf] building the bridge and the two probes ..."
build() {
    if ! scripts/hamlinux_build.sh "$1" "$OUT/$2.elf" >"$OUT/$2.build.log" 2>&1; then
        echo "[xsnarf] FAIL: $1 did not build"; tail -30 "$OUT/$2.build.log"; exit 1
    fi
}
build user/xsnarfd.ad          xsnarfd
build tests/linux/snarfcopy.ad snarfcopy
build tests/linux/snarfpaste.ad snarfpaste
echo "[xsnarf] built"

BODY="$OUT/body.sh"
cat >"$BODY" <<'INNER'
set -u
OUT="$1"
BR="$OUT/xsnarfd.elf"; CP="$OUT/snarfcopy.elf"; PA="$OUT/snarfpaste.elf"
DPY=77

export HAMSNARF="$OUT/seg"
rm -f "$HAMSNARF"
mount -t tmpfs tmpfs /tmp 2>/dev/null || { echo "MOUNTFAIL"; exit 90; }
mkdir -p /tmp/.X11-unix
export DISPLAY=":$DPY"
XSOCK="/tmp/.X11-unix/X$DPY"

start_x() {
    Xvfb ":$DPY" -screen 0 640x480x24 -nolisten tcp >>"$OUT/xvfb.log" 2>&1 &
    reap_add $!
    XVFB=$!
    i=0
    while [ $i -lt 60 ]; do
        xdpyinfo >/dev/null 2>&1 && return 0
        kill -0 "$XVFB" 2>/dev/null || return 1
        i=$((i+1)); sleep 0.25
    done
    return 1
}
# Every xclip that takes a selection STAYS RUNNING to serve it, so they are
# tracked and reaped by pid. `pkill xclip' would reach another agent's.
XCLIPS=""
xown() { # xown <selection> <text>
    printf '%s' "$2" | xclip -i -selection "$1" &
    reap_add $!
    XCLIPS="$XCLIPS $!"
    sleep 0.7
}
paste_x() { xclip -o -selection "$1" 2>&1; }

start_x || { echo "NOXSERVER"; exit 91; }
"$BR" "$XSOCK" test >"$OUT/xsnarfd.log" 2>&1 &
reap_add $!
BRPID=$!
sleep 1.5

echo "BEGIN"

# --- 1. Hamnix -> X: the editor copies, an X client pastes ----------------
"$CP" 0 CLIP-FROM-HAMNIX >/dev/null
sleep 0.8
echo "A $(paste_x clipboard)"
echo "B $(xclip -o -selection clipboard -t TARGETS 2>&1 | tr '\n' ' ')"
# A target we do not answer must be REFUSED, not answered with a lie.
echo "C $(xclip -o -selection clipboard -t TIMESTAMP 2>&1 | head -1)"

# --- 2. X -> Hamnix: an X client copies, the terminal pastes --------------
xown clipboard CLIP-FROM-XCLIENT
echo "D $("$PA" 0)"

# --- 3. PRIMARY, both ways, and independent from CLIPBOARD ---------------
"$CP" 1 PRIM-FROM-HAMNIX >/dev/null
sleep 0.8
echo "E $(paste_x primary)"
echo "F $(paste_x clipboard)"          # CLIPBOARD still the X client's text
xown primary PRIM-FROM-XCLIENT
echo "G $("$PA" 1)"
echo "H $("$PA" 0)"                    # ... and CLIPBOARD is still untouched

# --- 4. A handover between two OTHER X clients ---------------------------
# The bridge never owns the selection during this, so SelectionClear cannot
# tell it anything: only XFixesSelectionNotify can. This is the arm that
# fails if the XFixes watch is refused.
xown clipboard XCLIENT-ONE
echo "I $("$PA" 0)"
xown clipboard XCLIENT-TWO
echo "J $("$PA" 0)"

# --- 5. Ownership changing hands, repeatedly, without losing sync --------
n=1
while [ $n -le 4 ]; do
    "$CP" 0 "HAM-ROUND-$n" >/dev/null
    sleep 0.8
    echo "R${n}h $(paste_x clipboard)"
    xown clipboard "X-ROUND-$n"
    echo "R${n}x $("$PA" 0)"
    n=$((n+1))
done

# --- 6. The 64 KiB cap: truncate LOUDLY, never silently ------------------
awk 'BEGIN{s="";while(length(s)<70000)s=s "x";printf "%s", substr(s,1,70000)}' > "$OUT/big70k"
xclip -i -selection clipboard < "$OUT/big70k" &
reap_add $!
XCLIPS="$XCLIPS $!"
sleep 2
echo "K $("$PA" 0 | awk '{print $1, $2, $3, length($4)}')"

# --- 7. An INCR transfer is REFUSED and the clipboard is left alone ------
# MEASURED, not guessed: 400 KB is NOT enough. This server enables
# BIG-REQUESTS, so xclip sent 400 KB as one ChangeProperty and the bridge
# truncated it at 64 KiB instead -- which is a different (also loud) answer and
# would have left this arm asserting nothing. 2 MB is where xclip switches to
# the incremental protocol here.
"$CP" 0 BEFORE-THE-INCR >/dev/null
sleep 0.8
awk 'BEGIN{s="";while(length(s)<1000)s=s "y"; for(i=0;i<2000;i++) printf "%s", s}' > "$OUT/big2m"
xclip -i -selection clipboard < "$OUT/big2m" &
reap_add $!
XCLIPS="$XCLIPS $!"
sleep 3
echo "L $("$PA" 0)"

# --- 8. The X server goes away and comes back ---------------------------
# An Xwayland exits every time a distribution's X session ends. The bridge
# must notice, redial, and still be a bridge -- not wedge and not spin.
"$CP" 0 SURVIVES-A-RESTART >/dev/null
sleep 0.8
kill "$XVFB" 2>/dev/null
wait "$XVFB" 2>/dev/null
sleep 1.5
if start_x; then
    sleep 3
    echo "M $(paste_x clipboard)"
    xown clipboard AFTER-THE-RESTART
    echo "N $("$PA" 0)"
else
    echo "M NORESTART"; echo "N NORESTART"
fi

echo "O $(kill -0 "$BRPID" 2>/dev/null && echo alive || echo dead)"
echo "END"

kill $BRPID 2>/dev/null
# shellcheck disable=SC2086
kill $XCLIPS 2>/dev/null
kill "$XVFB" 2>/dev/null
wait 2>/dev/null
INNER

echo "[xsnarf] running Xvfb + the bridge in a private mount namespace ..."
LOG="$OUT/run.log"
if ! timeout 300 unshare -rm --propagation private /bin/sh "$BODY" \
        "$(pwd)/$OUT" >"$LOG" 2>&1; then
    echo "[xsnarf] FAIL: the run did not complete"; cat "$LOG"; exit 1
fi
cat "$LOG"
echo
echo "[xsnarf] --- the bridge's own log ---"
cat "$OUT/xsnarfd.log"
echo

get() { sed -n "s/^$1 //p" "$LOG" | head -1; }
BRLOG="$(cat "$OUT/xsnarfd.log")"

echo "[xsnarf] assertions"
chk "an X client pastes what the Hamnix editor copied"   "CLIP-FROM-HAMNIX"   "$(get A)"
chk "TARGETS lists exactly what the bridge answers"      "TARGETS UTF8_STRING STRING TEXT " "$(get B)"
has "a target it does not answer is REFUSED"             "not available"      "$(get C)"
chk "the Hamnix terminal pastes what an X client copied" "paste 0 17 CLIP-FROM-XCLIENT" "$(get D)"
chk "PRIMARY reaches X"                                  "PRIM-FROM-HAMNIX"   "$(get E)"
chk "CLIPBOARD is untouched by the PRIMARY copy"         "CLIP-FROM-XCLIENT"  "$(get F)"
chk "PRIMARY comes back from X"                          "paste 1 17 PRIM-FROM-XCLIENT" "$(get G)"
chk "CLIPBOARD still independent after the PRIMARY pull" "paste 0 17 CLIP-FROM-XCLIENT" "$(get H)"
chk "a handover between two OTHER X clients is seen (1)" "paste 0 11 XCLIENT-ONE" "$(get I)"
chk "a handover between two OTHER X clients is seen (2)" "paste 0 11 XCLIENT-TWO" "$(get J)"
n=1
while [ $n -le 4 ]; do
    chk "round $n: X pastes the Hamnix copy"     "HAM-ROUND-$n"          "$(get R${n}h)"
    chk "round $n: Hamnix pastes the X copy"     "paste 0 9 X-ROUND-$n"  "$(get R${n}x)"
    n=$((n+1))
done
chk "a 70 000-byte X selection lands as 65 536" "paste 0 65536 65536" "$(get K)"
has "and the truncation is said out loud"       "TRUNCATED"           "$BRLOG"
chk "an INCR transfer leaves the clipboard ALONE" "paste 0 15 BEFORE-THE-INCR" "$(get L)"
has "and the INCR refusal is said out loud"     "INCR"                "$BRLOG"
chk "the bridge redials a restarted X server"   "SURVIVES-A-RESTART"  "$(get M)"
chk "and bridges the new server both ways"      "paste 0 17 AFTER-THE-RESTART" "$(get N)"
chk "the bridge is still alive at the end"      "alive"               "$(get O)"

echo
echo "[xsnarf] passes=$PASS fails=$FAIL"
[ "$FAIL" -eq 0 ] && { echo "[xsnarf] PASS"; exit 0; }
echo "[xsnarf] FAIL"; exit 1
