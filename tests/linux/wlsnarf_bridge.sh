#!/usr/bin/env bash
# tests/linux/wlsnarf_bridge.sh — ONE CLIPBOARD, ACROSS ALL THREE WORLDS.
#
# The oracle for the wl_data_device half of the clipboard: user/wsyswl.ad's
# "the Wayland clipboard" section plus lib/wlsnarf.ad. QEMU-free, offscreen,
# about a minute.
#
# WHAT IS BEING ASSERTED, and it is not "the compositor advertises the
# manager" -- it advertised the manager for the whole port and there was
# nothing behind it. It is:
#
#   1. COPY IN A WAYLAND CLIENT, PASTE IN A HAMNIX PROGRAM, and the reverse --
#      through the SHIPPED TOOLKIT CODE on the Hamnix side. The two probes are
#      the same ones tests/linux/snarf_device.sh and xsnarf_bridge.sh use:
#      tests/linux/snarfcopy.ad copies through lib/hamtextbox.ad (the editor /
#      Notes / URL-bar path) and tests/linux/snarfpaste.ad pastes through
#      lib/htermsel.ad (the grid terminal's path), in separate processes.
#
#   2. AND THE X BRIDGE AND THIS ONE DO NOT FIGHT. "One clipboard" is a claim
#      about all three at once, so arm 8 runs an Xvfb with user/xsnarfd.ad on
#      it AND the Wayland compositor at the same time, on ONE $HAMSNARF, and
#      requires text copied in any of the three worlds to arrive in the other
#      two. A bridge that works alone and loops or loses sync beside the other
#      one would pass every arm above this and be useless.
#
#   3. AND A REAL THIRD-PARTY WAYLAND CLIENT, not only the test's own. Arm 9
#      puts Xwayland on the compositor -- Xwayland is a native Wayland client
#      with a real wl_data_device, which is the same thing Firefox is and the
#      reason this work exists.
#
# WHY THE TEST BRINGS ITS OWN CLIENT (tests/linux/wlclip.ad). `wl-copy` and
# `wl-paste` are NOT on this host -- checked by name below, and their absence
# is an exit 2, never a pass. Xwayland is here and is used, but Xwayland
# answers only what its own X selection code chooses to ask for: it cannot be
# told "offer a mime nobody can deliver" or "ask for a type the compositor
# does not have", which are the arms that prove a refusal is a refusal rather
# than a silence. So wlclip speaks the Wayland wire by hand, the way
# user/xsnarfd.ad speaks X11 by hand.
#
# NOTHING HERE TOUCHES THE HOST'S DISPLAY, GPU, SOUND OR /dev. The framebuffer
# is HAMFB_FILE, Xvfb scans out to memory by definition, Vulkan is pinned to
# the software ICD, and HAMWSYS / HAMWSYS_BB / HAMWSYS_IMG / HAMSNARF are all
# pinned per run for the reason docs/steam_namespace.md §11 records -- each of
# them defaults to ONE FILE PER HOST and two agents running this at once would
# hand each other stale state. /tmp inside the run is a private tmpfs so the
# X display number cannot collide either.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT" || exit 1

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  PASS  $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL  $*"; }
chk()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$2] got [$3]"; fi }
has()  { if [ -n "$3" ] && [[ "$3" == *"$2"* ]]; then ok "$1"; else bad "$1: [$3] does not contain [$2]"; fi }
hasnt(){ if [ -z "$3" ] || [[ "$3" != *"$2"* ]]; then ok "$1"; else bad "$1: [$3] SHOULD NOT contain [$2]"; fi }

# THE TOOLS ARE CHECKED BY NAME AND THE ABSENCE IS NOT A PASS.
for t in Xvfb xclip xdpyinfo Xwayland unshare; do
    command -v "$t" >/dev/null 2>&1 || {
        echo "[wlsnarf] CANNOT RUN: no $t on this host."
        echo "[wlsnarf] it is NOT passing, it did not run."
        exit 2
    }
done
# ... and the thing whose absence is the reason wlclip exists is recorded.
if command -v wl-copy >/dev/null 2>&1; then
    echo "[wlsnarf] NOTE: wl-copy IS on this host; wlclip is still used, because"
    echo "[wlsnarf] wl-copy cannot be told to offer a mime nobody can deliver."
else
    echo "[wlsnarf] NOTE: no wl-copy/wl-paste on this host -- tests/linux/wlclip.ad"
    echo "[wlsnarf] is the Wayland client, and Xwayland is the third-party arm."
fi

OUT="${WLSNARF_TEST_OUT:-build/wlsnarf}"
mkdir -p "$OUT" || exit 1

echo "[wlsnarf] building the compositor, the Wayland server, the X bridge and the probes ..."
build() {
    if ! scripts/hamlinux_build.sh "$1" "$OUT/$2.elf" >"$OUT/$2.build.log" 2>&1; then
        echo "[wlsnarf] FAIL: $1 did not build"; tail -30 "$OUT/$2.build.log"; exit 1
    fi
}
build user/wsysd.ad             wsysd
build user/wsyswl.ad            wsyswl
build user/xsnarfd.ad           xsnarfd
build tests/linux/wlclip.ad     wlclip
build tests/linux/snarfcopy.ad  snarfcopy
build tests/linux/snarfpaste.ad snarfpaste
echo "[wlsnarf] built"

BODY="$OUT/body.sh"
cat >"$BODY" <<'INNER'
set -u
OUT="$1"
WSYSD="$OUT/wsysd.elf"; WL="$OUT/wsyswl.elf"; XSN="$OUT/xsnarfd.elf"
CL="$OUT/wlclip.elf";   CP="$OUT/snarfcopy.elf"; PA="$OUT/snarfpaste.elf"

mount -t tmpfs tmpfs /tmp 2>/dev/null || { echo "MOUNTFAIL"; exit 90; }
mkdir -p /tmp/.X11-unix

# EVERY SHARED FILE PINNED PER RUN. docs/steam_namespace.md §11.
export HAMWSYS="$OUT/wsys.shm" HAMWSYS_BB="$OUT/wsys.bb" HAMWSYS_IMG="$OUT/wsys.img"
export HAMFB_FILE="$OUT/fb.raw" HAMFB_GEOM=800x600
export HAMSNARF="$OUT/snarf.seg"
rm -f "$HAMSNARF" "$HAMWSYS" "$HAMWSYS_BB" "$HAMWSYS_IMG" "$HAMFB_FILE"
[ -r /usr/share/vulkan/icd.d/lvp_icd.json ] && \
    export VK_ICD_FILENAMES="${VK_ICD_FILENAMES:-/usr/share/vulkan/icd.d/lvp_icd.json}"
export XWAYLAND_NO_GLAMOR=1

SOCK="$OUT/wayland-0"
KIDS=""
reap() { for p in $KIDS; do kill "$p" 2>/dev/null; done; sleep 0.4
         for p in $KIDS; do kill -9 "$p" 2>/dev/null; done; }
trap reap EXIT

"$WSYSD" </dev/null >"$OUT/wsysd.log" 2>&1 &
KIDS="$KIDS $!"
i=0; while [ $i -lt 80 ]; do [ -s "$HAMFB_FILE" ] && break; i=$((i+1)); sleep 0.1; done
[ -s "$HAMFB_FILE" ] || { echo "NOFB"; exit 91; }

"$WL" "$SOCK" </dev/null >"$OUT/wsyswl.log" 2>&1 &
KIDS="$KIDS $!"
WLPID=$!
i=0; while [ $i -lt 80 ]; do [ -S "$SOCK" ] && break; i=$((i+1)); sleep 0.1; done
[ -S "$SOCK" ] || { echo "NOSOCK"; exit 92; }
sleep 0.5

# wcopy <mode> <arg> -- starts a client that OWNS the selection.
#
# THE PREVIOUS OWNER IS REAPED FIRST, and that is not tidiness. A wl_data
# source has to stay alive to serve its bytes, so each of these is a live
# Wayland connection, and MAXCONN on this compositor is 8 -- the first draft
# of this file leaked one per copy and had exhausted the server by arm 8, at
# which point Xwayland could not connect and three arms failed for a reason
# that had nothing to do with the clipboard. Killing the old owner is also the
# more faithful thing: an application that copies and then closes is the
# ordinary case, and this bridge is expected to survive it because the bytes
# were pulled into /dev/snarf at set_selection time rather than left with the
# client. Arm 6 asserts exactly that.
WCOPY_PID=""
wcopy() {
    [ -n "$WCOPY_PID" ] && { kill "$WCOPY_PID" 2>/dev/null; wait "$WCOPY_PID" 2>/dev/null; }
    "$CL" "$SOCK" "$1" "$2" >>"$OUT/wlclip.log" 2>&1 &
    WCOPY_PID=$!
    KIDS="$KIDS $WCOPY_PID"
    sleep 1.0
}
wpaste() {  "$CL" "$SOCK" paste ${1:+"$1"} 2>&1 | head -1; }
wmimes() {  "$CL" "$SOCK" mimes 2>&1 | head -1; }

echo "BEGIN"

# --- 1. Wayland -> Hamnix: a Wayland client copies, the terminal pastes ----
wcopy copy WL-COPY-ONE
echo "A $("$PA" 0)"
# ... and the client that copied then EXITS. On the Wayland wire a selection
# lives with its source, so a compositor that forwarded pastes to the owner
# would lose this. The bytes are in /dev/snarf, so it does not.
kill "$WCOPY_PID" 2>/dev/null; wait "$WCOPY_PID" 2>/dev/null; WCOPY_PID=""
sleep 0.5
echo "A2 $(wpaste)"
echo "A3 $("$PA" 0)"

# --- 2. Hamnix -> Wayland: the editor copies, a Wayland client pastes ------
"$CP" 0 HAM-COPY-ONE >/dev/null
sleep 1.0
echo "B $(wpaste)"
echo "C $(wmimes)"

# --- 3. What it refuses -----------------------------------------------------
# A type the bridge does not have. The answer must be an empty paste AND a
# named refusal on the log, not an empty paste alone.
echo "D $(wpaste image/png)"
# A source that offers ONLY something nobody can deliver: the clipboard must
# be left exactly as it was, and the client must be TOLD it lost the source.
wcopy copybare NONSENSE-PAYLOAD
echo "E $("$PA" 0)"

# --- 4. A client that arrives AFTER the copy still sees it ------------------
# Every `wpaste` above is a fresh process, so this is really asserting the
# announce-on-get_data_device path, but it is worth its own line: without it
# the FIRST paste of every newly started program returns nothing, silently.
"$CP" 0 LATE-JOINER-SEES-IT >/dev/null
sleep 1.0
echo "F $(wpaste)"

# --- 5. The 64 KiB cap: truncate LOUDLY -------------------------------------
awk 'BEGIN{s="";while(length(s)<70000)s=s "x";printf "%s", substr(s,1,70000)}' > "$OUT/big70k"
wcopy copyfile "$OUT/big70k"
sleep 1.0
echo "G $("$PA" 0 | awk '{print $1, $2, $3, length($4)}')"

# --- 6. Giving the selection up does not empty the clipboard ---------------
"$CP" 0 STILL-HERE-AFTERWARDS >/dev/null
sleep 1.0
"$CL" "$SOCK" copynull >>"$OUT/wlclip.log" 2>&1
sleep 0.5
echo "H $("$PA" 0)"
echo "I $(wpaste)"

# --- 7. Ownership changing hands, repeatedly, with no loss of sync ---------
n=1
while [ $n -le 4 ]; do
    "$CP" 0 "HAM-ROUND-$n" >/dev/null
    sleep 1.0
    echo "R${n}w $(wpaste)"
    wcopy copy "WL-ROUND-$n"
    echo "R${n}h $("$PA" 0)"
    n=$((n+1))
done

# --- 8. ALL THREE WORLDS AT ONCE -------------------------------------------
# An Xvfb with user/xsnarfd.ad bridging it, beside the Wayland compositor, on
# ONE $HAMSNARF. This is where "one clipboard" is either true or it is not.
DPY=79
export DISPLAY=":$DPY"
Xvfb ":$DPY" -screen 0 640x480x24 -nolisten tcp >>"$OUT/xvfb.log" 2>&1 &
KIDS="$KIDS $!"
i=0; XUP=0
while [ $i -lt 60 ]; do xdpyinfo >/dev/null 2>&1 && { XUP=1; break; }; i=$((i+1)); sleep 0.25; done
if [ "$XUP" = 1 ]; then
    "$XSN" "/tmp/.X11-unix/X$DPY" wl >>"$OUT/xsnarfd.log" 2>&1 &
    KIDS="$KIDS $!"
    sleep 2
    # Wayland -> /dev/snarf -> X
    wcopy copy WAYLAND-TO-X
    sleep 1.5
    echo "J $(xclip -o -selection clipboard 2>&1)"
    # X -> /dev/snarf -> Wayland
    printf '%s' X-TO-WAYLAND | xclip -i -selection clipboard &
    KIDS="$KIDS $!"
    sleep 2
    echo "K $(wpaste)"
    echo "L $("$PA" 0)"
else
    echo "J NOXSERVER"; echo "K NOXSERVER"; echo "L NOXSERVER"
fi

# --- 9. A THIRD-PARTY Wayland client on the same compositor ----------------
#
# Xwayland is a native Wayland client with a real wl_data_device, which is the
# same thing Firefox is. Two separate things are asserted here and they must
# not be confused:
#
#   (a) THE COMPOSITOR KEEPS BRIDGING WITH A BIG FOREIGN CLIENT ON IT. Xwayland
#       is by far the largest client this server carries, and every clipboard
#       arm above ran with only wlclip connected.
#
#   (b) AND XWAYLAND'S OWN SELECTION BRIDGE IS **NOT** LIVE HERE, which is a
#       MEASURED BOUNDARY and not a defect in the code under test. An X client
#       on this Xwayland copies, and /dev/snarf does NOT change -- rootful
#       Xwayland does not turn an X selection into a wl_data_source at all.
#       That is exactly WHY user/xsnarfd.ad exists, one bridge per
#       distribution namespace: the X clipboard inside a namespace is reached
#       by owning its selections, not by going through Xwayland.
#
#       Measured, not assumed, and the obvious explanation was tested and
#       REJECTED: the first guess was that Xwayland had no input serial
#       because this compositor sends wl_keyboard.enter only on the first
#       keystroke into a window (drain_window). Injecting a keystroke with
#       tests/linux/wsys_poke.ad into the Xwayland window's keys ring did NOT
#       change the answer, and neither did `-rootless`. So the reason is
#       Xwayland's, this arm records the state of affairs, and if a later pass
#       (the rootless XWM) makes Xwayland bridge, THIS ARM WILL FAIL and force
#       the claim to be rewritten. That is the point of asserting a negative.
export WAYLAND_DISPLAY=wayland-0
export XDG_RUNTIME_DIR="$OUT"
Xwayland -shm -noreset :81 >>"$OUT/xwayland.log" 2>&1 &
KIDS="$KIDS $!"
i=0; XWUP=0
while [ $i -lt 60 ]; do
    DISPLAY=:81 xdpyinfo >/dev/null 2>&1 && { XWUP=1; break; }
    i=$((i+1)); sleep 0.25
done
if [ "$XWUP" = 1 ]; then
    echo "M up"
    "$CP" 0 BEFORE-THE-XWAYLAND-COPY >/dev/null
    sleep 1.0
    printf '%s' FROM-XWAYLAND-CLIENT | DISPLAY=:81 xclip -i -selection clipboard &
    KIDS="$KIDS $!"
    sleep 3
    echo "N $("$PA" 0)"
    # ... and with Xwayland still attached, the bridge under test still works.
    wcopy copy WITH-XWAYLAND-ATTACHED
    echo "O $("$PA" 0)"
    "$CP" 0 STILL-REACHES-WAYLAND >/dev/null
    sleep 1.0
    echo "O2 $(wpaste)"
else
    echo "M down"; echo "N NOXWAYLAND"; echo "O NOXWAYLAND"; echo "O2 NOXWAYLAND"
fi

# --- 10. and the compositor is still alive, and still bridging -------------
echo "P $(kill -0 "$WLPID" 2>/dev/null && echo alive || echo dead)"
"$CP" 0 THE-VERY-LAST-ONE >/dev/null
sleep 1.0
echo "Q $(wpaste)"
echo "END"
INNER

echo "[wlsnarf] running the compositor, the Wayland server and two X servers in a private mount namespace ..."
LOG="$OUT/run.log"
if ! timeout 420 unshare -rm --propagation private /bin/sh "$BODY" \
        "$(cd "$OUT" && pwd)" >"$LOG" 2>&1; then
    echo "[wlsnarf] FAIL: the run did not complete"; cat "$LOG"; exit 1
fi
cat "$LOG"
echo
echo "[wlsnarf] --- the compositor's own clipboard log ---"
grep -a clipboard "$OUT/wsyswl.log" | head -40
echo

get() { sed -n "s/^$1 //p" "$LOG" | head -1; }
WLLOG="$(cat "$OUT/wsyswl.log" 2>/dev/null)"
CLLOG="$(cat "$OUT/wlclip.log" 2>/dev/null)"

echo "[wlsnarf] assertions"
chk "the compositor says it bridged the clipboard" \
    "1" "$(grep -ac 'clipboard bridged to /dev/snarf' <<<"$WLLOG")"

# 1 + 2: the two directions, through the shipped toolkit code
chk "a Hamnix program pastes what a Wayland client copied" \
    "paste 0 11 WL-COPY-ONE" "$(get A)"
chk "the clipboard survives the client that copied EXITING (Wayland side)" \
    "wlpaste 11 WL-COPY-ONE" "$(get A2)"
chk "... and the Hamnix side too" \
    "paste 0 11 WL-COPY-ONE" "$(get A3)"
chk "a Wayland client pastes what a Hamnix program copied" \
    "wlpaste 12 HAM-COPY-ONE" "$(get B)"
chk "it offers exactly the four types it can deliver" \
    "wlmimes text/plain;charset=utf-8 text/plain UTF8_STRING TEXT" "$(get C)"
hasnt "and STRING is NOT among them (it means Latin-1)" "STRING " "$(get C | sed 's/UTF8_STRING/x/')"

# 3: refusals
chk "a paste asking for a type it does not have gets nothing" "wlpaste 0 " "$(get D)"
has  "... and the refusal names the type"  "REFUSED a paste asking for image/png" "$WLLOG"
chk "a source offering NO deliverable type leaves the clipboard alone" \
    "paste 0 12 HAM-COPY-ONE" "$(get E)"
has  "... and that refusal is said out loud" "in NO type this bridge can deliver" "$WLLOG"
has  "... and the client is TOLD it lost the source" "CANCELLED our data source" "$CLLOG"

# 4: the late joiner
chk "a client that connects after the copy still sees it" \
    "wlpaste 19 LATE-JOINER-SEES-IT" "$(get F)"

# 5: the cap
chk "a 70 000-byte Wayland copy lands as exactly 65 536" "paste 0 65536 65536" "$(get G)"
has "... and the truncation is said out loud, by size" "TRUNCATED, 4464 bytes dropped" "$WLLOG"

# 6: giving up the selection
chk "set_selection(NULL) does not empty /dev/snarf" \
    "paste 0 21 STILL-HERE-AFTERWARDS" "$(get H)"
chk "... and a Wayland client can still paste it" \
    "wlpaste 21 STILL-HERE-AFTERWARDS" "$(get I)"

# 7: ownership changing hands
n=1
while [ $n -le 4 ]; do
    chk "round $n: Wayland pastes the Hamnix copy" \
        "wlpaste 11 HAM-ROUND-$n" "$(get R${n}w)"
    chk "round $n: Hamnix pastes the Wayland copy" \
        "paste 0 10 WL-ROUND-$n" "$(get R${n}h)"
    n=$((n+1))
done

# 8: all three worlds
chk "an X client pastes what a WAYLAND client copied" "WAYLAND-TO-X" "$(get J)"
chk "a Wayland client pastes what an X client copied" "wlpaste 12 X-TO-WAYLAND" "$(get K)"
chk "... and the Hamnix side has the same bytes"      "paste 0 12 X-TO-WAYLAND" "$(get L)"

# 9: Xwayland, a real third-party Wayland client
chk "Xwayland came up as a client of this compositor" "up" "$(get M)"
# THE MEASURED BOUNDARY, and it is a negative on purpose -- see arm 9.
chk "a rootful Xwayland does NOT bridge its X selection (xsnarfd's job)" \
    "paste 0 24 BEFORE-THE-XWAYLAND-COPY" "$(get N)"
chk "the bridge still works with Xwayland attached (Wayland -> Hamnix)" \
    "paste 0 22 WITH-XWAYLAND-ATTACHED" "$(get O)"
chk "... and Hamnix -> Wayland too" \
    "wlpaste 21 STILL-REACHES-WAYLAND" "$(get O2)"

# 10
chk "the compositor is still alive after all of it" "alive" "$(get P)"
chk "... and still bridging"  "wlpaste 17 THE-VERY-LAST-ONE" "$(get Q)"

echo
echo "[wlsnarf] passes=$PASS fails=$FAIL"
[ "$FAIL" -eq 0 ] && { echo "[wlsnarf] PASS"; exit 0; }
echo "[wlsnarf] FAIL"; exit 1
