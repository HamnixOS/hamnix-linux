#!/usr/bin/env bash
# tests/linux/de_update_notice.sh — DOES THE SCREEN SAY THE UPDATE NEEDS A RESTART?
#
# THE DEFECT THIS GATES
# =====================
# `user/linux-wsys.c` REFUSES to attach a new-version program to a LIVE
# old-version /srv/wsys rather than wiping the desktop somebody is sitting in
# front of (A LIVE SESSION IS NOT A LEFTOVER, above shm_attach). That refusal
# is correct and it is the safety property of the whole update path —
# tests/linux/installed_update_wsysver.sh measured it on a real installed disk
# at 7 -> 8: the running desktop survived whole, 4 windows, 1,571 colours, the
# segment not resized by a byte.
#
# And what the PERSON got was nothing. They click Applications; the panel logs
# the click and spawns hamappmenu; hamappmenu refuses BY NAME — on stderr,
# which on this image is the serial console — and dies. No menu appears and
# nothing on the desktop says why. A correct refusal and a dead button are the
# same picture, and "I clicked and nothing happened" is the last thing between
# this and a distribution a stranger can update.
#
# THE FIX THIS ASSERTS
# ====================
# The refused program cannot draw; that is what being refused means. So it
# leaves a mark and the PANEL — which attached before the update and still
# owns its window — draws:
#
#   * user/linux-wsys.c appends one line to `<segment>.refused` from INSIDE
#     seg_refuse_message, past its once-per-process guard. The mark and the
#     five stderr lines therefore have exactly ONE condition between them, and
#     nothing else in the tree opens that path: a mark exists if and only if a
#     real version refusal happened. (Deliberately NOT reused for this:
#     $HOME/.hamde/appmenu.fault, which the panel already reads and which a
#     crash or a missing font satisfies just as well. A notice that appears
#     when nothing was refused is worse than no notice.)
#   * user/hampanelscene.ad polls it — the serial is the file's SIZE, which
#     only grows — grows its window for an amber card the same way it already
#     grows for the Applications dropdown, and dismisses on a click.
#
# WHAT IS MEASURED, AND WHY IT CANNOT ANSWER SUCCESS-SHAPED BY ACCIDENT
# ====================================================================
#   1. the compositor, the desktop and the panel build.
#   2. a probe built at WSYS_VERSION+1 exists and DIFFERS from this tree's —
#      otherwise the refusal below would be a bump that never happened.
#   3. CONTROL, before anything is refused: the notice rectangle is not the
#      notice colour, and no marker file exists.
#   4. the v+1 probe meets the live segment and REFUSES BY NAME (the safety
#      property, re-asserted here so a pretty card can never be bought with
#      it).
#   5. the marker names the pair — live=<N>, mine=<N+1> — read off the disk.
#   6. THE FIX: the notice rectangle goes from the control reading to mostly
#      the card colour. One EXACT colour in ONE FIXED rectangle: no menu,
#      window, toast or wallpaper in this desktop is that colour.
#   7. a click far away leaves it up — it is a notice a person can read, not a
#      one-frame flash.
#   8. a click ON it takes the rectangle back to empty.
#   9. and the desktop still works afterwards: the Applications button still
#      opens the panel's dropdown.
#  10. A SECOND refusal, after the first was dismissed, RAISES IT AGAIN --
#      and the marker GREW rather than being rewritten, which is what makes
#      its size usable as a serial. "Dismissed" and "nothing was refused" are
#      different states inside the panel and have to stay different: waving
#      the card away must not silence the NEXT program that refuses.
#  11. A REFUSED Applications menu leaves NO $HOME/.hamde/appmenu.fault. That
#      file means "this program is broken" and the panel, having seen it once,
#      drops the Applications button to its legacy dropdown for the rest of
#      its life -- and it is on the ext4 root, so it OUTLIVES the reboot the
#      refusal asks for. A refusal is about the SESSION, not the program.
#  12. CONTROL for 11: a menu that was NOT refused does not take the
#      suppressing branch, so the fix is conditional and a genuinely broken
#      menu still gets written down.
#
# 3 and 8 are the instrument check. If the colour or the rectangle were wrong
# EVERY reading would be 0 and 6 would FAIL — there is no way for a broken
# measurement here to score. The whole sequence is empty -> full -> full ->
# empty of one rectangle in one session: a single "it changed" could be a
# repaint; that could not.
#
# Entirely offscreen (HAMFB_FILE + a file of evdev records): no VM, no
# display, no GPU. The software Vulkan ICD is forced because wsysd has a real
# Vulkan backend and this host's GPU belongs to someone.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

# The desktop stack writes FIXED, HOST-GLOBAL names whatever this script does
# about its own $WORK — /tmp/hamnix-panel.{health,fault}, /tmp/hamnix-notif.log
# and, the subject of this gate, /srv. Those names are compiled into the
# programs under test. This puts everything below inside a mount namespace
# where /tmp, /dev/shm and /srv are this run's alone; it execs and does not
# return. NOTE: it also means this file cannot be run from inside /tmp.
. tests/linux/private_ns.sh
priv_ns_reexec "$@"

WORK="${NOTICE_WORK:-$(mktemp -d -p "${TMPDIR:-/tmp}" updnotice.XXXXXX)}"
mkdir -p "$WORK"
KEEP="${NOTICE_KEEP:-0}"
GEOM="${HAMFB_GEOM:-1280x800}"
FBW="${GEOM%x*}"; FBH="${GEOM#*x}"

export HAMWSYS="$WORK/wsys.shm"
export HAMWSYS_BB="$WORK/wsys.bb"
export HAMWSYS_IMG="$WORK/wsys.img"
export HAMFB_FILE="$WORK/fb.raw"
export HAMFB_GEOM="$GEOM"
[ -r /usr/share/vulkan/icd.d/lvp_icd.json ] && \
    export VK_ICD_FILENAMES="${VK_ICD_FILENAMES:-/usr/share/vulkan/icd.d/lvp_icd.json}"

pass=0; fail=0
ok()   { echo "updnotice: PASS $*"; pass=$((pass+1)); }
bad()  { echo "updnotice: FAIL $*"; fail=$((fail+1)); }
info() { echo "updnotice: INFO $*"; }

PIDS=""
cleanup() {
    for p in $PIDS; do [ -n "${p:-}" ] && kill "$p" 2>/dev/null; done
    sleep 0.3
    for p in $PIDS; do [ -n "${p:-}" ] && kill -9 "$p" 2>/dev/null; done
    [ "$KEEP" = 1 ] || rm -rf "$WORK"
}
trap cleanup EXIT
# A bare EXIT trap does not run when the shell is killed by a signal, so a gate
# stopped by `timeout` (TERM) or ^C (INT) skipped its cleanup entirely.
trap 'exit 130' INT TERM HUP
done_report() { echo "updnotice: $pass passed, $fail failed"; [ "$fail" = 0 ]; }

# ---- the pixel probe (the same one de_mouse_chrome.sh uses) ---------------
FRAC_PY="$WORK/frac.py"
cat >"$FRAC_PY" <<'PY'
import sys
W, H = int(sys.argv[1]), int(sys.argv[2])
x, y, w, h = (int(v) for v in sys.argv[3:7])
d = open(sys.argv[7], 'rb').read()
c = sys.argv[8]
want = (int(c[0:2], 16), int(c[2:4], 16), int(c[4:6], 16))
tot = hit = 0
for j in range(y, min(y + h, H)):
    row = j * W * 4
    for i in range(x, min(x + w, W)):
        o = row + i * 4
        tot += 1
        if (d[o+2], d[o+1], d[o]) == want:
            hit += 1
print(0 if tot == 0 else hit * 100 // tot)
PY
colourpct() { python3 "$FRAC_PY" "$FBW" "$FBH" "$1" "$2" "$3" "$4" "$HAMFB_FILE" "$5"; }

# THE NOTICE RECTANGLE, and where the numbers come from: user/hampanelscene.ad
# puts the card at window-local (8, bar + cur_thick), NOTICE_W x NOTICE_H =
# 340 x 86, and the top panel's window origin is (0,0) with a PANEL_H = 26 bar
# at bar = 0. The values below are that box inset past the 2px border and the
# 8px corner radius, so corner antialiasing cannot dilute a flat-fill count.
NX=14; NY=32; NW=328; NH=74
FACE=ffe9b0                          # _notice_draw's inset face colour
CARD_CX=178; CARD_CY=69              # the middle of the card, for the dismiss

TREE_VER="$(sed -n 's/^#define[[:space:]]\+WSYS_VERSION[[:space:]]\+\([0-9]\+\).*/\1/p' \
            user/linux-wsys.c | head -1)"
case "$TREE_VER" in
    ''|*[!0-9]*)
        bad "user/linux-wsys.c has no '#define WSYS_VERSION <n>' -- this gate's whole subject is that constant"
        done_report; exit 1;;
esac
NEXT=$((TREE_VER + 1))
info "this tree is wsys v$TREE_VER; the refusing probe will be v$NEXT"

# ---- build ---------------------------------------------------------------
for t in wsysd:user/wsysd.ad \
         hamdesktop:user/hamdesktop.ad \
         hampanelscene:user/hampanelscene.ad \
         wsys_poke:tests/linux/wsys_poke.ad; do
    name="${t%%:*}"; src="${t#*:}"
    scripts/hamlinux_build.sh "$src" "$WORK/$name.elf" \
        >"$WORK/$name.build.log" 2>&1 || {
        bad "could not build $src"; tail -20 "$WORK/$name.build.log" >&2
        done_report; exit 1; }
done
ok "the compositor, the desktop and the panel all build"

# ---- a v(N+1) tree, one constant apart -----------------------------------
# The symlink farm is tests/linux/build_obj_cache.sh's mktree: only
# user/linux-wsys.c is a real file, and it is safe against the shared object
# cache because rt_obj's cache key is the hash of the SOURCE.
TREE9="$WORK/tree-v$NEXT"
mkdir -p "$TREE9/user"
for e in "$PROJ_ROOT"/* "$PROJ_ROOT"/.[!.]*; do
    [ -e "$e" ] || continue
    case "${e##*/}" in user) continue ;; esac
    ln -sfn "$e" "$TREE9/${e##*/}"
done
for e in "$PROJ_ROOT"/user/*; do ln -sfn "$e" "$TREE9/user/${e##*/}"; done
rm -f "$TREE9/user/linux-wsys.c"
sed "s/^\(#define[[:space:]]\+WSYS_VERSION[[:space:]]\+\)[0-9]\+/\1$NEXT/" \
    "$PROJ_ROOT/user/linux-wsys.c" > "$TREE9/user/linux-wsys.c"
grep -q "^#define[[:space:]]\+WSYS_VERSION[[:space:]]\+$NEXT\$" \
    "$TREE9/user/linux-wsys.c" || {
    bad "the staged v$NEXT tree is not v$NEXT"; done_report; exit 1; }
"$TREE9/scripts/hamlinux_build.sh" tests/linux/wsys_poke.ad "$WORK/poke9.elf" \
    >"$WORK/poke9.build.log" 2>&1 || {
    bad "the v$NEXT probe did not build"; tail -20 "$WORK/poke9.build.log" >&2
    done_report; exit 1; }
if cmp -s "$WORK/wsys_poke.elf" "$WORK/poke9.elf"; then
    bad "the v$NEXT probe is byte-identical to the v$TREE_VER one, so the refusal below would be a version bump that never happened"
    done_report; exit 1
fi
ok "a v$NEXT probe built, and it differs from the v$TREE_VER one"

# ---- THE MOUSE (synthetic evdev, as de_focus_dismiss.sh) -----------------
: >"$WORK/input.evdev"
export HAMWSYSD_INPUT="$WORK/input.evdev"
EVDEV_PY="$WORK/evdev.py"
cat >"$EVDEV_PY" <<'PY'
import struct, sys
path, W, H = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
recs = []
for tok in sys.argv[4:]:
    kind, *a = tok.split(':')
    if kind == 'move':
        x, y = int(a[0]), int(a[1])
        recs += [(3, 0, x * 32768 // W), (3, 1, y * 32768 // H), (0, 0, 0)]
    elif kind == 'down':
        recs += [(1, 272, 1), (0, 0, 0)]
    elif kind == 'up':
        recs += [(1, 272, 0), (0, 0, 0)]
with open(path, 'ab') as f:
    for t, c, v in recs:
        f.write(struct.pack('<qqHHi', 0, 0, t, c, v))
PY
ev() { python3 "$EVDEV_PY" "$WORK/input.evdev" "$FBW" "$FBH" "$@"; }
click() { ev "move:$1:$2"; sleep 0.4; ev "down"; sleep 0.4; ev "up"; sleep 1.5; }

# ---- the session ---------------------------------------------------------
"$WORK/wsysd.elf" </dev/null >"$WORK/wsysd.log" 2>&1 &
PIDS="$PIDS $!"
for _ in $(seq 1 60); do [ -s "$HAMFB_FILE" ] && break; sleep 0.1; done
[ -s "$HAMFB_FILE" ] || { bad "wsysd never produced a framebuffer"
                          cat "$WORK/wsysd.log"; done_report; exit 1; }
"$WORK/hamdesktop.elf" </dev/null >"$WORK/hamdesktop.log" 2>&1 &
PIDS="$PIDS $!"
sleep 3
"$WORK/hampanelscene.elf" </dev/null >"$WORK/hampanelscene.log" 2>&1 &
PIDS="$PIDS $!"
sleep 4

# ---- 3. CONTROL ----------------------------------------------------------
BEFORE="$(colourpct $NX $NY $NW $NH $FACE)"
if [ "$BEFORE" -le 1 ]; then
    ok "CONTROL: with nothing refused, the notice rectangle is ${BEFORE}% #$FACE"
else
    bad "a notice was on the screen before anything had been refused (${BEFORE}%)"
fi
if [ -e "$HAMWSYS.refused" ]; then
    bad "a refusal marker existed before any refusal: $HAMWSYS.refused"
else
    ok "no refusal marker exists yet"
fi

# ---- 4/5. THE REFUSAL, and what it left behind ---------------------------
"$WORK/poke9.elf" "/dev/wsys/windows" >"$WORK/poke9.out" 2>"$WORK/poke9.err"
if grep -q 'REFUSING to attach' "$WORK/poke9.err"; then
    ok "THE REFUSAL IS INTACT: the v$NEXT binary refused the live v$TREE_VER session by name"
    sed 's/^/        /' "$WORK/poke9.err" | head -5
else
    bad "the v$NEXT binary did NOT refuse the live v$TREE_VER session -- the notice must never be bought with the refusal"
    sed 's/^/        /' "$WORK/poke9.err" | head -5
fi
if [ -s "$HAMWSYS.refused" ] &&
        grep -q "refused live=$TREE_VER mine=$NEXT" "$HAMWSYS.refused"; then
    ok "the marker names the pair the refusal was about: $(head -1 "$HAMWSYS.refused")"
else
    bad "no usable marker at $HAMWSYS.refused -- whatever the panel draws below, it did not come from this"
fi

# ---- 6. THE FIX ----------------------------------------------------------
sleep 3
AFTER="$(colourpct $NX $NY $NW $NH $FACE)"
if [ "$AFTER" -ge 40 ] && [ "$AFTER" -gt "$BEFORE" ]; then
    ok "THE PERSON IS TOLD: the notice rectangle went ${BEFORE}% -> ${AFTER}% #$FACE on a real refusal"
else
    bad "no notice appeared: the rectangle is ${AFTER}% #$FACE (control ${BEFORE}%). A correct refusal is still an invisible one."
fi

# ---- 7. it stays up ------------------------------------------------------
click 900 600
STILL="$(colourpct $NX $NY $NW $NH $FACE)"
if [ "$STILL" -ge 40 ]; then
    ok "a click at (900,600), far from it, left the notice up (${STILL}%)"
else
    bad "a click somewhere else took the notice away (${STILL}%): a person who looks away has lost the only thing that told them what to do"
fi

# ---- 8. and it goes away when asked --------------------------------------
click "$CARD_CX" "$CARD_CY"
GONE="$(colourpct $NX $NY $NW $NH $FACE)"
if [ "$GONE" -le 1 ]; then
    ok "THE NOTICE IS DISMISSIBLE: a click on the card took the rectangle to ${GONE}%"
else
    bad "the notice would not dismiss (${GONE}%): it is now the thing covering the desktop"
fi

# ---- 9. and the desktop is not wedged ------------------------------------
# The Applications button is under where the notice was; if the card left
# anything behind — a grown window, a swallowed click — this is where it shows.
click 40 13
sleep 1
MENU="$(colourpct 8 30 130 180 f7f8fa)"
if [ "$MENU" -ge 20 ]; then
    ok "THE DESKTOP IS NOT WEDGED: after the notice, the Applications button still opens the panel's dropdown (${MENU}% of the menu column is the card colour)"
else
    bad "after the notice the Applications button no longer opens anything (${MENU}%)"
fi

# ---- 10. A SECOND REFUSAL RAISES IT AGAIN --------------------------------
# THE PATH THIS EXERCISES, AND WHY IT NEEDED ITS OWN ASSERTION. Dismissing
# does not delete the marker -- it records the marker's SIZE as the offset
# already answered for (`notice_ack`). So "dismissed" and "no refusal has
# happened" are different states inside the panel, and the whole design rests
# on them staying different: a person who waves the card away must not be
# told again about the SAME refusal, and must still be told about the NEXT
# one. Both halves are now measured -- 7 above is the first (a click that is
# not on the card leaves the count alone) and this is the second.
#
# It is also the only assertion here that runs against a marker file that is
# ALREADY NON-EMPTY, which is the state every real machine is in after the
# first program refuses. Everything above it started from nothing.
SZ1="$(wc -c <"$HAMWSYS.refused" 2>/dev/null || echo 0)"
"$WORK/poke9.elf" "/dev/wsys/windows" >"$WORK/poke9b.out" 2>"$WORK/poke9b.err"
SZ2="$(wc -c <"$HAMWSYS.refused" 2>/dev/null || echo 0)"
if [ "$SZ2" -gt "$SZ1" ]; then
    ok "the second refusal appended to the marker rather than rewriting it ($SZ1 -> $SZ2 bytes), which is what makes the size a serial"
else
    bad "the second refusal did not grow the marker ($SZ1 -> $SZ2 bytes): a dismissed notice can never come back, because the panel compares the size against what it already answered for"
fi
sleep 3
AGAIN="$(colourpct $NX $NY $NW $NH $FACE)"
if [ "$AGAIN" -ge 40 ]; then
    ok "A SECOND REFUSAL RAISES THE NOTICE AGAIN: the rectangle is back to ${AGAIN}% #$FACE after a dismissal took it to ${GONE}%"
else
    bad "after being dismissed once the notice never came back (${AGAIN}%): the machine tells a person about the first program that refused and stays silent about every one after it"
fi

# ---- 11. A REFUSED MENU MUST NOT LEAVE "THIS PROGRAM IS BROKEN" ----------
# THE DEFECT: $HOME/.hamde/appmenu.fault means "hamappmenu could not open a
# window", and the panel, having seen it once, routes the Applications button
# to its own legacy dropdown for the rest of its life. That is right for a
# broken menu and wrong for a REFUSED one -- and the fault is in $HOME on the
# ext4 root, so it OUTLIVES THE REBOOT the refusal asks for. Measured on a real
# disk: after the restart that fixes everything else, the machine comes up
# healthy and the categorised Applications menu is gone for good, with nothing
# anywhere saying why.
#
# BOTH DIRECTIONS ARE ASKED, because suppressing the fault altogether would
# also make the first half pass and would be a different defect.
export HOME="$WORK/home"
mkdir -p "$HOME"
"$TREE9/scripts/hamlinux_build.sh" user/hamappmenu.ad "$WORK/appmenu9.elf" \
    >"$WORK/appmenu9.build.log" 2>&1 || {
    bad "the v$NEXT hamappmenu did not build"; tail -20 "$WORK/appmenu9.build.log" >&2
    done_report; exit 1; }

rm -rf "$HOME/.hamde"
# `timeout` on both arms: a refused menu returns on its own, but a menu that
# unexpectedly GETS a window never does -- it sits in its event loop -- and an
# assertion that can hang is an assertion that never reports.
timeout 40 "$WORK/appmenu9.elf" -self >"$WORK/appmenu9.out" 2>"$WORK/appmenu9.err"
if grep -q 'REFUSING to attach' "$WORK/appmenu9.err"; then
    ok "the v$NEXT Applications menu was refused by the live v$TREE_VER session"
else
    bad "the v$NEXT Applications menu was not refused -- this assertion is not about what it thinks it is"
    sed 's/^/        /' "$WORK/appmenu9.err" | head -5
fi
if [ -e "$HOME/.hamde/appmenu.fault" ]; then
    bad "A REFUSED MENU LEFT A FAULT FILE ($HOME/.hamde/appmenu.fault). The panel reads it and drops the Applications button to its legacy dropdown -- permanently, and across the reboot the refusal asks for. The restart that fixes everything else would not fix this."
else
    ok "A REFUSED MENU LEAVES NO FAULT: the refusal is about the SESSION, not the program, so the Applications button survives the restart that fixes it"
fi

# THE CONTROL, and an honest account of how strong it is.
#
# What I wanted to assert: a failure that is NOT a refusal still leaves the
# fault, so the fix above is not just "stop reporting faults" -- which would
# leave a genuinely broken menu answering the Applications button with nothing
# at all, for ever.
#
# WHY THAT EXACT ASSERTION IS NOT RUNNABLE HERE, measured rather than assumed:
# the obvious way to make hamappmenu fail without being refused is to point
# $HAMWSYS at something unusable. shm_attach's CANDIDATE LIST then does its
# documented job -- /dev/shm/hamnix-wsys, then /tmp/hamnix-wsys -- so the menu
# CREATES ITS OWN SEGMENT, gets a window in it, and sits in its event loop
# forever drawing into a screen nobody composites. The first version of this
# control hung for thirty minutes doing exactly that.
#
# So the control asks the discriminating half instead: that the suppression is
# CONDITIONAL. A run that is not refused must not take the new branch -- it
# must not print the line, which means it reached the fault write the same way
# it always did. Bounded by `timeout`, because a menu that DOES get a window
# never returns.
CTRL_HOME="$WORK/home-ctrl"
rm -rf "$CTRL_HOME"; mkdir -p "$CTRL_HOME"
mkdir -p "$WORK/notasegment"
( export HOME="$CTRL_HOME"
  export HAMWSYS="$WORK/notasegment"
  timeout 25 "$WORK/appmenu9.elf" -self >"$WORK/appmenuctrl.out" 2>"$WORK/appmenuctrl.err" )
if grep -q 'REFUSING to attach' "$WORK/appmenuctrl.err"; then
    bad "CONTROL: the not-refused arm was refused after all, so it discriminates nothing"
elif grep -q 'NOT leaving a fault' "$WORK/appmenuctrl.err"; then
    bad "CONTROL: a menu that was NOT refused still took the new branch and suppressed its fault. The fix is unconditional, which is indistinguishable from deleting the fault mechanism: a genuinely broken menu would now answer the Applications button with nothing at all."
    sed 's/^/        /' "$WORK/appmenuctrl.err" | head -5
else
    ok "CONTROL: a menu that was NOT refused did not take the fault-suppressing branch, so the suppression is conditional on the refusal and the panel's fallback is intact for a genuinely broken menu"
fi

done_report
