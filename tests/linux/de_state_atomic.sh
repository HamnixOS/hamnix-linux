#!/usr/bin/env bash
# Its host runtime and its pass/fail were NOT measured when this line was
# written. If you make it cheap enough for the battery, add the manifest line
# and delete this block.
#
# tests/linux/de_state_atomic.sh — IS /dev/wsys/wsysd/state READ-ATOMIC?
#
# THE DEFECT THIS GATES
# =====================
# `/dev/wsys/wsysd/state` is the compositor's own published counters (frames,
# pointer, focus, windows, inputs). wsysd REWRITES IT IN PLACE every frame, and
# a reader that landed mid-rewrite GOT AN EMPTY BODY WITH EXIT STATUS 0.
#
# The line was in user/linux-wsys.c, hamwsys_open(), HAMWSYS_SINK, for_write:
#
#     s->len = 0;                        /* open-for-write truncates */
#
# The body arrives in a LATER write(2). Between those two syscalls the sink is
# the empty string to every reader in the system. Nothing about that is
# specific to the state file — it was true of every sink under /dev/wsys.
#
# WHY IT MATTERS MORE THAN A COSMETIC GLITCH
# ==========================================
# This is the project's defining failure shape — a gap answering something
# success-shaped instead of the truth — and it was aimed at the INSTRUMENTS.
# An empty body with status 0 is indistinguishable from a successful read of a
# desktop that has no windows, no focus and no frames, so:
#
#   * tests/linux/de_fps_driver.py parsed the empty read as `{}` and callers
#     wrote `s.get('frames', 0)`. ONE torn read became a frame delta of plus or
#     minus THE ENTIRE COUNTER: a "-173 frames in 10 s" was reported as an idle
#     measurement, and a "+212" was briefly read as an eightfold regression.
#     Commit 12bacfb2 fixed that ONE file by retrying.
#   * tests/linux/de_focus_dismiss.sh's `focuswid() { set -- $(wstate); echo
#     "${2:-none}"; }` turns a torn read into the VERDICT "focus is none".
#   * tests/linux/de_fps_latency.sh's `NWIN` becomes empty, and `${NWIN:-0}`
#     then fails the run with "this is not the desktop, it is an empty screen".
#
# Every reader retrying is a workaround. This gates the FILE.
#
# WHAT IS MEASURED
# ================
#   1. everything builds.
#   2. wsysd comes up offscreen and publishes a state line at all.
#   3. CONTROL — THE INSTRUMENT READS WHOLE BODIES. The hammer reports 100/100
#      good against the live file. Without this, a later "0 torn" says only
#      that the instrument is broken.
#   4. CONTROL — THE INSTRUMENT CAN REPORT TORN. The same hammer against a sink
#      that was NEVER WRITTEN reports 100/100 empty. A zero from an instrument
#      never shown capable of a non-zero is not a finding, and that rule is the
#      entire subject of this file.
#   5. THE GATE: N tight reads of the live state file while the desktop is up.
#      EMPTY reads must be 0. On the unfixed tree this is NOT 0 — see below.
#   6. and no SHORT reads either (a body that came back without its last
#      field), which is a different defect from an empty one and would mean the
#      body itself is assembled in pieces.
#
# THE NUMBER THIS WENT RED WITH
# =============================
# Measured on this host, 1280x800 offscreen, wsysd + hamdesktop + hampanelscene:
#
#     unfixed   reads 100000  good  99975  empty 25  short 0
#     fixed     reads 300000  good 300000  empty  0  short 0
#
# `short` is 0 in BOTH arms, which sharpens the defect: the tear is EMPTY-ONLY,
# never partial. publish_state() builds the whole line into one buffer and
# writes it in a single sys_write, so len=0 was the only intermediate state a
# reader could ever observe. A gate that also demanded short==0 on the unfixed
# tree would pass it, which is why 5 and 6 are separate assertions.
#
# WHY THE HAMMER IS A PROGRAM (tests/linux/wsys_hammer.ad)
# ========================================================
# The window is a few microseconds wide. `wsys_poke` reads once per process, so
# hammering with it costs a fork+exec per sample — 200 samples is seconds, and
# 200 samples of a rare event is a coin flip. wsys_hammer reads IN-PROCESS, so
# N can be 300000 and the answer stops being luck.
#
# STATE_N=<n> sets the hammer's N (default 300000).
# STATE_KEEP=1 keeps $WORK.

set -u

# A private mount namespace FIRST: /tmp, /dev/shm and /srv are this run's alone,
# so nothing here can touch a real desktop's segments. It execs and does not
# return. NOTE for a KEEP=1 post-mortem: $WORK is inside that private /tmp.
. tests/linux/private_ns.sh
priv_ns_reexec "$@"

. tests/linux/reap.sh

WORK="${STATE_WORK:-$(mktemp -d -p "${TMPDIR:-/tmp}" stateatomic.XXXXXX)}"
mkdir -p "$WORK"
KEEP="${STATE_KEEP:-0}"
N="${STATE_N:-300000}"
GEOM="${HAMFB_GEOM:-1280x800}"

# OFFSCREEN, ALWAYS. The owner's X session is live on /dev/dri/card0; a
# framebuffer in a file and no VNC means this gate never asks for DRM master.
export HAMWSYS="$WORK/wsys.shm"
export HAMWSYS_BB="$WORK/wsys.bb"
export HAMWSYS_IMG="$WORK/wsys.img"
export HAMFB_FILE="$WORK/fb.raw"
export HAMFB_GEOM="$GEOM"
export HAMLINUX_VNC=none
# wsysd must not open this host's real input devices.
export HAMWSYSD_INPUT="$WORK/input.evdev"
: >"$WORK/input.evdev"

pass=0; fail=0
ok()   { echo "stateatomic: PASS $*"; pass=$((pass+1)); }
bad()  { echo "stateatomic: FAIL $*"; fail=$((fail+1)); }
info() { echo "stateatomic: INFO $*"; }
done_report() { echo "stateatomic: $pass passed, $fail failed"; [ "$fail" = 0 ]; }

reap_track "$WORK/reaped"
cleanup() { [ "$KEEP" = 1 ] || rm -rf "$WORK"; }
reap_on_exit cleanup

# ---- build ---------------------------------------------------------------
for t in wsysd:user/wsysd.ad \
         hamdesktop:user/hamdesktop.ad \
         hampanelscene:user/hampanelscene.ad \
         wsys_poke:tests/linux/wsys_poke.ad \
         wsys_hammer:tests/linux/wsys_hammer.ad; do
    name="${t%%:*}"; src="${t#*:}"
    scripts/hamlinux_build.sh "$src" "$WORK/$name.elf" \
        >"$WORK/$name.build.log" 2>&1 || {
        bad "could not build $src"; tail -20 "$WORK/$name.build.log" >&2
        done_report; exit 1; }
done
ok "the compositor, the desktop, the panel and the hammer all build"

# ---- the compositor and a real desktop on top of it ----------------------
# The desktop and panel are here so the state file is being republished by a
# compositor that is actually compositing, which is the condition the tear was
# measured under. An idle wsysd with nothing mapped still republishes, but a
# gate should reproduce the reported conditions, not easier ones.
"$WORK/wsysd.elf" </dev/null >"$WORK/wsysd.log" 2>&1 &
reap_add $!
for _ in $(seq 1 80); do [ -s "$HAMFB_FILE" ] && break; sleep 0.1; done
[ -s "$HAMFB_FILE" ] || { bad "wsysd never produced a framebuffer"
                          sed 's/^/stateatomic:      /' "$WORK/wsysd.log"
                          done_report; exit 1; }
"$WORK/hamdesktop.elf" </dev/null >"$WORK/hamdesktop.log" 2>&1 &
reap_add $!
sleep 3
"$WORK/hampanelscene.elf" </dev/null >"$WORK/hampanelscene.log" 2>&1 &
reap_add $!
sleep 3

STATE="$("$WORK/wsys_poke.elf" /dev/wsys/wsysd/state 2>/dev/null)"
case "$STATE" in
    *frames*) ok "wsysd publishes its state: $STATE" ;;
    *) bad "wsysd published no usable state line (got '$STATE') -- nothing below can measure anything"
       sed 's/^/stateatomic:      /' "$WORK/wsysd.log"
       done_report; exit 1 ;;
esac

# ---- 3. CONTROL: the instrument reads WHOLE bodies -----------------------
hammer() { "$WORK/wsys_hammer.elf" "$1" "$2" 2>/dev/null; }
field()  { echo "$1" | sed -n "s/.* $2 \([0-9]*\).*/\1/p"; }

C1="$(hammer /dev/wsys/wsysd/state 100)"
info "control (live file, 100 reads): $C1"
if [ "$(field "$C1" good)" = 100 ]; then
    ok "CONTROL: the hammer reads whole bodies -- 100/100 good on the live file"
else
    bad "CONTROL: the hammer did not read 100/100 whole bodies ($C1) -- a torn count from this instrument would mean nothing"
    done_report; exit 1
fi

# ---- 4. CONTROL: the instrument CAN report torn --------------------------
# A sink nobody ever wrote answers an empty body -- deliberately (see
# hamwsys_open: "never written: empty, not ENOENT"). So it is the one input
# guaranteed to drive the empty counter, which is what proves the counter
# works. Without this, assertion 5's zero is unfalsifiable.
C2="$(hammer /dev/wsys/de-state-atomic-never-written 100)"
info "control (never-written sink, 100 reads): $C2"
if [ "$(field "$C2" empty)" = 100 ]; then
    ok "CONTROL: the hammer CAN report a torn read -- 100/100 empty on a sink that was never written"
else
    bad "CONTROL: a never-written sink did not read back empty ($C2) -- the empty counter is not proven to work, so a 0 below proves nothing"
    done_report; exit 1
fi

# ---- 5+6. THE GATE -------------------------------------------------------
info "hammering /dev/wsys/wsysd/state $N times while the desktop is up"
H="$(hammer /dev/wsys/wsysd/state "$N")"
info "$H"
EMPTY="$(field "$H" empty)"; SHORT="$(field "$H" short)"
GOOD="$(field "$H" good)";   OF="$(field "$H" openfail)"

if [ "${OF:-1}" != 0 ]; then
    bad "$OF of $N reads could not OPEN the state file -- this run measured availability, not atomicity"
fi

if [ "${EMPTY:-x}" = 0 ]; then
    ok "NO TORN READS: 0 empty bodies in $N reads of a file being republished every frame (good $GOOD)"
else
    bad "TORN: $EMPTY of $N reads of /dev/wsys/wsysd/state came back EMPTY with success -- a reader landing between the open-for-write truncate and the write(2) sees no desktop at all, and de_focus_dismiss.sh reads that as 'focus is none'"
fi

if [ "${SHORT:-x}" = 0 ]; then
    ok "and none of the $N bodies was SHORT -- the published line is never assembled in pieces"
else
    bad "$SHORT of $N reads came back without the last field -- the body itself is being assembled in pieces, which is a different defect from the empty read"
fi

# ---- 7. THE REGRESSION THE FIX COULD HAVE CAUSED -------------------------
# The truncate did not disappear, it MOVED: out of hamwsys_open, where it was
# a window held open until somebody wrote, and into hamwsys_close, where it is
# one store. So `> /dev/wsys/foo` with no write must still empty the sink --
# and if it silently stopped doing so, every DE component that clears a sink
# that way would be reading a stale message forever, which is a worse bug than
# the one this file fixes and would not show up in any count above.
#
# `wsys_poke -t` is the only way to reach that path: /dev/wsys is served inside
# hamnix processes, so a host shell's `: > /dev/wsys/post` gets ENOENT from the
# real filesystem and would pass this assertion without testing anything.
TSINK=/dev/wsys/de-state-atomic-trunc
"$WORK/wsys_poke.elf" "$TSINK" 'a body that must not survive' >/dev/null 2>&1
BEFORE="$("$WORK/wsys_poke.elf" "$TSINK" 2>/dev/null)"
if [ -n "${BEFORE//[[:space:]]/}" ]; then
    "$WORK/wsys_poke.elf" -t "$TSINK" >/dev/null 2>&1
    AFTER="$("$WORK/wsys_poke.elf" "$TSINK" 2>/dev/null)"
    if [ -z "${AFTER//[[:space:]]/}" ]; then
        ok "NO REGRESSION: opening a sink for writing and closing without writing still EMPTIES it (the truncate moved to close, it did not vanish)"
    else
        bad "a sink opened for writing and closed without a write kept its body ('$AFTER') -- the truncate was lost when it moved out of hamwsys_open, so every component that clears a sink this way now reads a stale message forever"
    fi
else
    bad "could not stage a body in $TSINK to truncate (read back '$BEFORE') -- assertion 7 did not test anything"
fi

echo
done_report
