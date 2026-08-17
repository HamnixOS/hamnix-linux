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
# tests/linux/wsyswl_shared_fate.sh — WHOSE LIMIT IS IT?
#
#   X11 clients -> Xwayland -> wsyswl (Adder) -> /dev/wsys -> wsysd -> /dev/fb
#
# `tests/linux/wsyswl_stall.sh` next door asks whether the compositor KEEPS
# delivering one surface. This asks the question behind it, which is the one
# that cost three passes of the Steam investigation:
#
#     when one client runs out of something, who else stops?
#
# The Steam bug was `MAXMAP`: a per-connection table of sixteen wl_shm mappings
# that a session needing twenty-six filled, after which every commit was
# dropped. What made it take three passes was not the number. It was that an
# unrelated `xterm` went stale in the same breath -- because a rootful Xwayland
# is ONE Wayland connection, and every limit in wsyswl is indexed by connection.
# Two X clients on one X display share a fate, and nothing said so.
#
# So this test states the property as a measurement, in four parts:
#
#   1. THE CENSUS. Put several X clients on a rootful Xwayland and read the
#      compositor's own count of connections. It is 1. Every per-connection
#      limit those clients touch is therefore one table between all of them.
#
#   2. THE SAME CENSUS, ROOTLESS. Run Xwayland with -rootless and count again.
#      It is ALSO 1. This is the load-bearing measurement for the design
#      question in docs/linux_window_manager.md §8a: giving each X toplevel its
#      own `wl_surface` does not give it its own mapping table, its own object
#      id space or its own frame-callback slice, because those are per
#      CONNECTION and Xwayland opens exactly one either way.
#
#   3. THE INVARIANT. No connection may be starved of windows or frame
#      callbacks by another connection's appetite. That is arithmetic, not
#      intention: MAXWIN >= MAXCONN * WINPERCONN, FCMAX >= MAXCONN * FCPERCONN.
#      A future edit that makes either table global again fails here.
#
#   4. THE BEHAVIOUR. Fill the connection table with other clients until the
#      server refuses one, and require that the X session already on the screen
#      keeps following a move -- and that the refusal was named, not silent.
#
# Offscreen throughout: HAMFB_FILE for the framebuffer and the HOST's Xwayland,
# so it touches no display, needs no VM and takes about two minutes.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

# THE MACHINE THIS RUNS ON IS NOT SCRATCH.
#
# It runs wsyswl and several Wayland clients; the socket is in $XDG_RUNTIME_DIR.
#
# The names that matter are compiled into the binaries, not written here, so no
# care taken in this script can move them; the containment is the namespace.
# tests/linux/private_ns.sh has the table and the incident that bought it. This
# must come before anything that makes a file under /tmp, $WORK included, and
# before reap.sh, whose registry is itself a mktemp under /tmp.
. tests/linux/private_ns.sh
priv_ns_reexec "$@"

WORK="${SHFATE_WORK:-$(mktemp -d -p "${TMPDIR:-/tmp}" shfate.XXXXXX)}"
mkdir -p "$WORK"
GEOM="${HAMFB_GEOM:-1280x800}"
KEEP="${SHFATE_KEEP:-0}"
export HAMWSYS="$WORK/wsys.shm"
export HAMFB_FILE="$WORK/fb.raw"
export HAMFB_GEOM="$GEOM"
# PRIVATE, for the reason wsyswl_stall.sh gives at length: the v2 backbuffer
# segment is one file per HOST with slots keyed by wid and no owner, so a test
# that inherits one is measuring the last run.
export HAMWSYS_BB="$WORK/wsys.bb"
# wsysd arms a real Vulkan backend on real silicon and this host's GPU belongs
# to someone. Software ICD, always, for anything offscreen.
[ -r /usr/share/vulkan/icd.d/lvp_icd.json ] && \
    export VK_ICD_FILENAMES="${VK_ICD_FILENAMES:-/usr/share/vulkan/icd.d/lvp_icd.json}"
FBW="${GEOM%x*}"; FBH="${GEOM#*x}"

pass=0; fail=0
ok()   { echo "shfate: PASS $*"; pass=$((pass+1)); }
bad()  { echo "shfate: FAIL $*"; fail=$((fail+1)); }
info() { echo "shfate: INFO $*"; }
# An empty read is not a measurement. See tests/linux/gate_read.sh. st() seds
# $STATE with 2>/dev/null and NOTHING IN THIS FILE EVER PROVES $STATE EXISTS --
# the startup guard at line 120 checks the SOCKET, and the compositor writes
# its state file only when a counter moves. So every `st <name>` can come back
# empty for a reason that has nothing to do with the property under test, and
# `${CONNS:-0}` / `${COMMITS_AFTER:-0}` turned that into "got none" and into
# "THE PROPERTY FAILED ... that is the Steam symptom" -- this file's headline
# claim, stated in the negative, about counters it had not read. The fix at
# line 356 below already does this by hand for map_alloc_failed; these helpers
# do it by name everywhere else.
. tests/linux/gate_read.sh

KIDS=""; XWPID=""; XWPID2=""; WLPID=""; WSYSDPID=""
cleanup() {
    for p in $KIDS $XWPID $XWPID2 $WLPID $WSYSDPID; do
        [ -n "${p:-}" ] && kill "$p" 2>/dev/null
    done
    sleep 0.4
    for p in $KIDS $XWPID $XWPID2 $WLPID $WSYSDPID; do
        [ -n "${p:-}" ] && kill -9 "$p" 2>/dev/null
    done
    [ "$KEEP" = 1 ] || rm -rf "$WORK"
}
trap cleanup EXIT
# A bare EXIT trap does not run when the shell is killed by a signal, so a
# gate stopped by `timeout` (TERM) or ^C (INT) skipped its cleanup entirely.
# Re-exit on those, which makes the EXIT trap above run on every path out.
trap 'exit 130' INT TERM HUP

for t in Xwayland xterm xdotool xdpyinfo xwininfo python3; do
    command -v "$t" >/dev/null || { echo "need $t on the host" >&2; exit 1; }
done
# weston-simple-shm is the smallest possible native Wayland client: one
# connection, one toplevel, one pool. It is how part 4 fills the connection
# table without needing a browser.
HAVE_WSS=0
command -v weston-simple-shm >/dev/null && HAVE_WSS=1

for t in wsysd:user/wsysd.ad wsyswl:user/wsyswl.ad; do
    name="${t%%:*}"; src="${t#*:}"
    scripts/hamlinux_build.sh "$src" "$WORK/$name.elf" >"$WORK/$name.build.log" 2>&1 || {
        echo "FAIL could not build $src" >&2; tail -20 "$WORK/$name.build.log" >&2; exit 1; }
done

"$WORK/wsysd.elf" </dev/null >"$WORK/wsysd.log" 2>&1 &
WSYSDPID=$!
sleep 1.5

"$WORK/wsyswl.elf" "$WORK/wayland-0" </dev/null >"$WORK/wsyswl.log" 2>&1 &
WLPID=$!
for _ in $(seq 1 40); do [ -S "$WORK/wayland-0" ] && break; sleep 0.1; done
[ -S "$WORK/wayland-0" ] || { bad "wsyswl never created its socket"; cat "$WORK/wsyswl.log"; exit 1; }
STATE="$WORK/wsyswl-state"
ok "wsyswl is listening"

# The compositor rewrites its state file twice a second, so every read here
# waits for it rather than racing it.
st() { sleep 1; sed -n "s/^$1 \([0-9-]*\)\$/\1/p" "$STATE" 2>/dev/null | tail -1; }
lim() { sed -n "s/.*[ ]$1=\([0-9]*\).*/\1/p" "$STATE" 2>/dev/null | tail -1; }

export XDG_RUNTIME_DIR="$WORK"
export WAYLAND_DISPLAY=wayland-0

# ---------------------------------------------------------------------------
# 1. THE CENSUS: several X clients, and how many connections that is
# ---------------------------------------------------------------------------
echo "shfate: === 1. how many Wayland connections is an X session with N clients?"
DISPNUM="${SHFATE_DISPLAY:-:82}"
rm -f "/tmp/.X${DISPNUM#:}-lock" 2>/dev/null
Xwayland -shm -noreset "$DISPNUM" >"$WORK/xwayland.log" 2>&1 &
XWPID=$!
export DISPLAY="$DISPNUM"
up=0
for _ in $(seq 1 80); do
    xdpyinfo >/dev/null 2>&1 && { up=1; break; }
    kill -0 "$XWPID" 2>/dev/null || break
    sleep 0.25
done
[ "$up" = 1 ] && ok "Xwayland (rootful) came up on $DISPNUM through wsyswl" \
              || { bad "Xwayland did not come up"; tail -20 "$WORK/xwayland.log"; exit 1; }

# The victim. It is the first client on the screen and it must survive
# everything the rest of this test does to the server.
xterm -geometry 80x24+40+40 -bg white -fg black -e sleep 900 >"$WORK/victim.log" 2>&1 &
KIDS="$KIDS $!"
VIC=""
for _ in $(seq 1 40); do
    VIC=$(xdotool search --class xterm 2>/dev/null | head -1)
    [ -n "$VIC" ] && break
    sleep 0.5
done
[ -n "$VIC" ] && ok "the victim xterm mapped a window ($VIC)" || { bad "no victim window"; exit 1; }

# Four more X clients on the SAME display.
for n in 1 2 3 4; do
    xterm -geometry 24x8+$((360 + n * 120))+$((420 + n * 40)) -bg white -e sleep 900 \
        >/dev/null 2>&1 &
    KIDS="$KIDS $!"
done
sleep 6
NXWIN=$(xwininfo -root -children 2>/dev/null | grep -cE '^ +0x')
CONNS=$(st conns)
WINHI=$(st windows_high_water)
info "$NXWIN X windows on the root; wsyswl says conns=$CONNS windows_high_water=$WINHI"
if ! gate_nonempty "wsyswl's own conns counter (no 'conns <n>' line in $STATE)" "$CONNS"; then
    :   # gate_nonempty named the read. "got none" was a sentence about the X
        # session; an unwritten state file is a sentence about this gate.
elif [ "$CONNS" = 1 ]; then
    ok "five X clients are ONE Wayland connection -- every per-connection limit is shared between all of them"
else
    bad "expected exactly 1 connection for a rootful X session, got $CONNS"
fi
if [ "${WINHI:-0}" = 1 ]; then
    ok "and ONE wsys window: the whole X screen, window manager and all, is one surface"
else
    info "windows_high_water is ${WINHI:-none} (1 is what rootful Xwayland gives)"
fi

MAPHI_ROOTFUL=$(st maps_high_water)
info "the shared mapping table is at ${MAPHI_ROOTFUL} of $(lim MAXMAP) with $NXWIN X windows on it"

# ---------------------------------------------------------------------------
# 2. THE SAME CENSUS, ROOTLESS -- the measurement the design question turns on
# ---------------------------------------------------------------------------
echo "shfate: === 2. and how many connections does -rootless make?"
# A SECOND Xwayland, this one rootless, on the same compositor. It needs no
# client: the question is how many Wayland connections the SERVER makes, and it
# makes them at startup.
DISP2="${SHFATE_DISPLAY2:-:83}"
rm -f "/tmp/.X${DISP2#:}-lock" 2>/dev/null
Xwayland -rootless -shm -noreset "$DISP2" >"$WORK/xwayland2.log" 2>&1 &
XWPID2=$!
up2=0
for _ in $(seq 1 60); do
    DISPLAY="$DISP2" xdpyinfo >/dev/null 2>&1 && { up2=1; break; }
    kill -0 "$XWPID2" 2>/dev/null || break
    sleep 0.25
done
if [ "$up2" = 1 ]; then
    ok "Xwayland -rootless came up on $DISP2 through wsyswl"
else
    info "Xwayland -rootless did not come up; skipping the rootless census"
fi
CONNS2=$(st conns)
info "with a rootful AND a rootless Xwayland on the server, conns=$CONNS2"
if [ "$up2" = 1 ] && [ "${CONNS2:-0}" = 2 ]; then
    ok "-rootless is ONE connection too: a per-toplevel wl_surface does NOT buy a per-toplevel mapping table, object id space or frame-callback slice"
elif [ "$up2" = 1 ]; then
    bad "expected 2 connections (one rootful + one rootless Xwayland), got ${CONNS2:-none}"
fi
# And what a rootless Xwayland does for the screen with no window manager
# inside the compositor: nothing at all. This is the size of the missing piece.
DISPLAY="$DISP2" xterm -geometry 40x12+60+60 -bg white -e sleep 300 >/dev/null 2>&1 &
KIDS="$KIDS $!"
sleep 6
WINHI2=$(st windows_high_water)
if [ "$up2" = 1 ] && [ "${WINHI2:-0}" = "${WINHI:-1}" ]; then
    ok "a client on the ROOTLESS display produced no wsys window at all -- rootless needs an X11 window manager inside the compositor before it produces anything (docs/linux_window_manager.md §8)"
elif [ "$up2" = 1 ]; then
    info "windows_high_water moved to $WINHI2 after a client on the rootless display"
fi

# ---------------------------------------------------------------------------
# 3. THE INVARIANT: no connection can be starved by another's appetite
# ---------------------------------------------------------------------------
echo "shfate: === 3. the limits, and whose they are"
sed -n 's/^limits /shfate:   limits /p' "$STATE"
L_MAXCONN=$(lim MAXCONN); L_MAXWIN=$(lim MAXWIN); L_WPC=$(lim WINPERCONN)
L_FCMAX=$(lim FCMAX);     L_FPC=$(lim FCPERCONN)
if [ -n "$L_MAXWIN" ] && [ -n "$L_MAXCONN" ] && [ -n "$L_WPC" ] \
   && [ "$L_MAXWIN" -ge $((L_MAXCONN * L_WPC)) ]; then
    ok "the window table is big enough for every connection's budget at once ($L_MAXWIN >= $L_MAXCONN * $L_WPC) -- one client cannot deny another a window"
else
    bad "MAXWIN ($L_MAXWIN) is smaller than MAXCONN * WINPERCONN ($L_MAXCONN * $L_WPC) -- a window budget that other clients can eat is not a budget"
fi
if [ -n "$L_FCMAX" ] && [ -n "$L_MAXCONN" ] && [ -n "$L_FPC" ] \
   && [ "$L_FCMAX" -ge $((L_MAXCONN * L_FPC)) ]; then
    ok "the frame-callback table is partitioned, not shared ($L_FCMAX >= $L_MAXCONN * $L_FPC) -- a busy client cannot silence another client's initial-draw callback"
else
    bad "FCMAX ($L_FCMAX) is smaller than MAXCONN * FCPERCONN ($L_MAXCONN * $L_FPC)"
fi

# ---------------------------------------------------------------------------
# 4. THE BEHAVIOUR: exhaust the server around the victim, and it must not care
# ---------------------------------------------------------------------------
echo "shfate: === 4. fill the server with other clients; the X session must keep updating"

# The framebuffer is a plain file, so "is the window here" has a literal answer.
whitebox() {  # x y w h -> percent of near-white pixels
    python3 - "$HAMFB_FILE" "$FBW" "$FBH" "$1" "$2" "$3" "$4" <<'PY'
import sys
path, W, H, x, y, w, h = sys.argv[1], *map(int, sys.argv[2:])
d = open(path, 'rb').read()
tot = 0; white = 0
for j in range(y, min(y + h, H), 3):
    row = j * W * 4
    for i in range(x, min(x + w, W), 3):
        o = row + i * 4
        if o + 3 > len(d): continue
        tot += 1
        if d[o] > 0xc0 and d[o+1] > 0xc0 and d[o+2] > 0xc0:
            white += 1
print(0 if tot == 0 else white * 100 // tot)
PY
}

export DISPLAY="$DISPNUM"
# Park the victim somewhere known and find the compositor's origin offset the
# way wsyswl_stall.sh does -- wsysd places the window with a title bar, so the
# X screen's (0,0) is not the framebuffer's.
xdotool windowmove "$VIC" 60 60
xdotool windowsize "$VIC" 420 240
sleep 4
BEST=-1; OX=0; OY=0
for oy in 0 20 24 28 32; do
  for ox in 0 2 4; do
    v=$(whitebox $((60+ox)) $((60+oy)) 360 180)
    if [ "$v" -gt "$BEST" ]; then BEST=$v; OX=$ox; OY=$oy; fi
  done
done
info "framebuffer offset for X (0,0) looks like +${OX}+${OY} (${BEST}% white in the victim's box)"
if [ "$BEST" -gt 40 ]; then
    ok "the victim is on the scanout framebuffer before the server is loaded up (${BEST}% white)"
else
    bad "the victim never reached the framebuffer (${BEST}% white) -- nothing below this can mean anything"
fi

# Now take every remaining connection. Each weston-simple-shm is one client,
# one connection, one toplevel -- which is exactly the unit of independence
# this server has -- and the last one asked for must be REFUSED.
NEED=$(( ${L_MAXCONN:-8} + 2 ))
HOGS=""
if [ "$HAVE_WSS" = 1 ]; then
    info "starting $NEED weston-simple-shm clients against a server with MAXCONN=${L_MAXCONN:-?}"
    n=0
    while [ "$n" -lt "$NEED" ]; do
        weston-simple-shm >>"$WORK/wss.log" 2>&1 &
        HOGS="$HOGS $!"; KIDS="$KIDS $!"
        n=$((n+1))
        sleep 0.4
    done
    sleep 4
    CONNS4=$(st conns)
    info "conns is now ${CONNS4:-?} of ${L_MAXCONN:-?}; conns_high_water $(st conns_high_water)"
    if grep -q 'too many clients' "$WORK/wsyswl.log"; then
        ok "the server REFUSED a connection and said so by name -- a client that gets nothing must never be turned away in silence"
    else
        bad "more clients than MAXCONN were started and nothing was refused or named"
    fi
else
    info "no weston-simple-shm on the host; the connection table cannot be filled here"
fi

# THE POINT OF THE WHOLE FILE. The server is now as loaded as it can be, other
# clients have been refused outright, and the X session must not have noticed.
#
# EVERY HOG GOT A REAL WSYS WINDOW, AND THEY ARE IN FRONT. win_open cascades
# new toplevels to (60,60), (400,60), (740,60), (60,400)… at 250x250, ON TOP of
# the X screen's own window, and the hogs were created last so they stack last.
# A pixel check at a fixed spot therefore measures OCCLUSION, not delivery --
# it read 0% white for a victim that was being composited perfectly, which is
# exactly the kind of success-shaped/failure-shaped confusion this tree exists
# to avoid. So the loaded phase is judged on evidence that occlusion cannot
# fake, and the pixels are checked afterwards with the hogs out of the way.
before=$(python3 -c 'import hashlib,sys;print(hashlib.md5(open(sys.argv[1],"rb").read()).hexdigest())' "$HAMFB_FILE")
COMMITS_BEFORE=$(st commits)
xdotool windowmove "$VIC" 300 120
xdotool windowsize "$VIC" 460 260
sleep 5
after=$(python3 -c 'import hashlib,sys;print(hashlib.md5(open(sys.argv[1],"rb").read()).hexdigest())' "$HAMFB_FILE")
COMMITS_AFTER=$(st commits)
GEOM_NOW=$(xwininfo -id "$VIC" 2>/dev/null | sed -n 's/^ *-geometry \(.*\)$/\1/p')
info "after the move under load: X says the victim is $GEOM_NOW; commits ${COMMITS_BEFORE} -> ${COMMITS_AFTER}"
[ "$before" != "$after" ] && ok "the framebuffer changed when the victim moved under a full server" \
                          || bad "the framebuffer is byte-identical -- the victim stopped being delivered when other clients loaded the server"
# THE OCCLUSION-PROOF MEASUREMENT, and the strongest one: the compositor is
# still ACCEPTING this session's buffers. A commit count that stops moving is
# the Steam symptom itself -- `commits 3` against `commits 506`.
if ! gate_nonempty "the commit counter before the move (no 'commits <n>' line in $STATE)" "$COMMITS_BEFORE" \
   || ! gate_nonempty "the commit counter after the move (no 'commits <n>' line in $STATE)" "$COMMITS_AFTER"; then
    :   # THE STRONGEST CLAIM IN THIS FILE MAY NOT BE MADE FROM AN EMPTY READ,
        # in either direction. "commits stopped at  once other clients filled
        # the server -- that is the Steam symptom" names the exact production
        # bug the file exists to rule out, on the evidence of two empty strings.
elif [ "$COMMITS_AFTER" -gt "$COMMITS_BEFORE" ]; then
    ok "THE PROPERTY: other clients filling the server and being refused did NOT stop this X session ($COMMITS_BEFORE -> $COMMITS_AFTER commits accepted)"
else
    bad "THE PROPERTY FAILED: commits stopped at ${COMMITS_BEFORE} once other clients filled the server -- that is the Steam symptom"
fi
MAPFAIL=$(st map_alloc_failed); NOMAP=$(st drop_no_mapping)
# st() seds $STATE with 2>/dev/null, and nothing above ever proved $STATE
# exists -- the startup guard checks the SOCKET. So both reads come back
# empty if the compositor has not written its state file yet, or wrote it
# without these counters, and `${MAPFAIL:-0}` = 0 then took the ok() branch
# whose text HARD-CODES the two zeroes it never read: "map_alloc_failed 0,
# drop_no_mapping 0". A pass asserting numbers nobody obtained.
if [ -z "$MAPFAIL" ] || [ -z "$NOMAP" ]; then
    bad "UNREADABLE -- the compositor's state file ($STATE) gave no map_alloc_failed / drop_no_mapping (got '$MAPFAIL'/'$NOMAP'), so whether the victim's mapping table was touched is not a question this run can answer either way"
elif [ "$MAPFAIL" = 0 ] && [ "$NOMAP" = 0 ]; then
    ok "and it did so without the victim's own mapping table being touched by anyone else (map_alloc_failed 0, drop_no_mapping 0)"
else
    bad "the victim's connection lost mappings while other clients were loading the server (map_alloc_failed ${MAPFAIL}, drop_no_mapping ${NOMAP})"
fi

# Now take the hogs off the screen and look at the pixels. If the victim was
# really being composited all along, its new geometry is white the moment
# nothing is in front of it -- with no further move, no repaint asked for.
if [ -n "$HOGS" ]; then
    for p in $HOGS; do kill "$p" 2>/dev/null; done
    sleep 4
    newbox=$(whitebox $((300+OX)) $((120+OY)) 400 220)
    info "with the hogs gone, the victim's box at its NEW place is ${newbox}% white"
    if [ "$newbox" -gt 40 ]; then
        ok "the victim really had moved and really was being painted the whole time -- the pixels were behind other windows, not missing"
    else
        bad "the victim's pixels are not at its new place even with nothing in front of it (${newbox}% white)"
    fi
    CONNS5=$(st conns)
    if [ -n "$CONNS5" ] && [ "$CONNS5" -lt "${CONNS4:-99}" ]; then
        ok "the refused clients' slots came back when they exited (conns ${CONNS4} -> ${CONNS5}) -- a full table is a queue, not a wall"
    else
        bad "connections did not drop when clients exited (conns ${CONNS4:-?} -> ${CONNS5:-?}) -- a leaked slot is a client that can never connect again"
    fi
fi

echo "shfate: === the compositor's own counters"
sed 's/^/shfate:   /' "$STATE" 2>/dev/null
NOROLE=$(sed -n 's/^drop_no_role \([0-9]*\)$/\1/p' "$STATE")
DROPS=$(sed -n 's/^drop_[a-z_]* \([0-9]*\)$/\1/p;s/^map_alloc_failed \([0-9]*\)$/\1/p;s/^obj_id_refused \([0-9]*\)$/\1/p;s/^window_budget_full \([0-9]*\)$/\1/p' "$STATE" | paste -sd+ - | bc 2>/dev/null)
REAL=$(( ${DROPS:-0} - ${NOROLE:-0} ))
if [ "$REAL" -le 0 ]; then
    ok "no frame was dropped for any reason but a cursor surface, with the server full"
else
    info "$REAL frames were dropped under load -- see the named counters above"
fi
grep -q 'DROPPING FRAMES' "$WORK/wsyswl.log" && \
    grep 'DROPPING FRAMES' "$WORK/wsyswl.log" | sed 's/^/shfate:   /'

echo "shfate: $pass PASS, $fail FAIL"
[ "$fail" = 0 ]
