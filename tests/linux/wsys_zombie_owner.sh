#!/usr/bin/env bash
# wsys_zombie_owner.sh — A ZOMBIE MUST NOT READ AS A LIVE WINDOW OWNER.
#
# WHAT THIS GATE IS FOR
# =====================
# user/linux-wsys.c's win_reap_dead() reclaims a window whose owner has died.
# Until 2026-08-17 it asked `kill(pid, 0) == 0` and read a successful syscall
# as a fact about the world. It is not one. `kill(2)` SUCCEEDS ON A ZOMBIE: a
# process that has exited and has not been wait4'd still has a process table
# entry, and an entry is all kill(2) is asking about. So a corpse answered
# "alive", the reaper kept its window, and a 900 s desktop soak ended with 92
# windows listed, 3 live application processes and 86 corpses.
#
# The measurement that matters is not "the reaper was called" -- it was called
# every frame throughout -- but "the reaper can tell a program from a corpse".
#
# THE TWO ARMS, AND WHY THE RED ONE IS RUN
# ========================================
# An assertion that cannot fail is not an assertion, and every defect this tree
# has caught in its own instruments was caught by a negative control. So the
# same scenario is run TWICE against the same binary:
#
#   GREEN  (default)               the window whose owner is a zombie is GONE.
#   RED    HAMWSYS_LIVENESS=kill   the identical window is STILL THERE.
#
# HAMWSYS_LIVENESS=kill restores the exact predicate that shipped before, so
# the red arm is not a simulation of the bug, it IS the bug, running. If the
# red arm ever goes green this gate has stopped being attributable and says so.
#
# THE PREMISE IS MEASURED, NOT QUOTED. Arm 0 checks, on the corpse this gate
# just made, that `kill(pid, 0)` returns 0 -- because the whole argument rests
# on that and "the man page says so" is not a reading off this kernel.
#
# WHAT IT DOES NOT ASSERT
# =======================
#  * Anything about pid recycling. A window whose owner's pid number has been
#    reused answers "live" and is KEPT, deliberately (see win_reap_dead), and
#    nothing here manufactures a recycled pid.
#  * Anything about a compositor. No wsysd runs: /dev/wsys is shared memory and
#    the reaper runs inside whichever process reads the directory, so the
#    reading `cat` is the reaper under test. That is the same code path the
#    compositor and the taskbar walk.
#  * That /proc is present. When it is not, pid_liveness() falls back to the
#    old kill(2) probe and answers UNKNOWN for anything but ESRCH -- windows
#    are kept, exactly as before. This gate runs where /proc exists and does
#    not measure the fallback.
#
# Offscreen, no framebuffer, no /dev/dri, no device touched.
set -uo pipefail
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ" || exit 1

pass=0; fail=0
ok()   { printf 'zowner: PASS %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf 'zowner: FAIL %s\n' "$*"; fail=$((fail+1)); }
note() { printf 'zowner: .... %s\n' "$*"; }

OUT="${HAMLINUX_OUT:-$(mktemp -d /tmp/zowner.XXXXXX)}"
mkdir -p "$OUT/bin"
trap 'rm -rf "$OUT/run"' EXIT

# ---------------------------------------------------------------- build
if ! command -v gcc >/dev/null 2>&1; then
    echo "zowner: SKIP no gcc"; exit 0
fi
gcc -Wall -O1 -o "$OUT/bin/zparent" tests/linux/zombie_owner_parent.c \
    >"$OUT/zparent.log" 2>&1 || {
    echo "zowner: FATAL zombie_owner_parent.c did not build"; sed 's/^/== /' "$OUT/zparent.log"; exit 1; }

for t in cat:user/cat.ad wsys_hold:tests/linux/wsys_hold.ad; do
    n="${t%%:*}"
    [ -x "$OUT/bin/$n" ] && continue
    scripts/hamlinux_build.sh "${t#*:}" "$OUT/bin/$n" >"$OUT/build.$n.log" 2>&1 || {
        echo "zowner: FATAL ${t#*:} did not build"; tail -20 "$OUT/build.$n.log"; exit 1; }
done
note "built zparent, cat, wsys_hold into $OUT/bin"

# HOST SCALE, NAMED. p9_listdir's 4096-byte truncation was invisible on a guest
# with 40 processes, so every check in this tree now says how big the table it
# ran against was.
NPROC_HOST=$(ls -d /proc/[0-9]* 2>/dev/null | wc -l)
note "host process table: $NPROC_HOST processes"

# ---------------------------------------------------------------- one arm
# $1 = arm name, $2 = "kill" to run the old predicate.
# Leaves: $OUT/run/$1/{before.txt,after.txt,zop.log,owner}
run_arm() {
    local arm="$1" mode="$2"
    local W="$OUT/run/$arm"
    rm -rf "$W"; mkdir -p "$W"; : > "$W/script"

    # A FIFO, not a pipe into a subshell: this half of the shell has to be able
    # to write the kill trigger at a moment of its own choosing, long after the
    # process started.
    mkfifo "$W/trigger" || return 90
    (
        export HAMWSYS="$W/seg"
        [ "$mode" = kill ] && export HAMWSYS_LIVENESS=kill
        export ZOP_HOLDLOG="$W/hold.log"
        exec "$OUT/bin/zparent" "$OUT/bin/wsys_hold" "$W/script" \
             <"$W/trigger" >"$W/zop.log" 2>"$W/zop.err"
    ) &
    echo $! > "$W/zpid"
    # Hold the FIFO open from this side so zparent's read does not see EOF.
    exec {TRIG}>"$W/trigger"

    local i owner wid
    for i in $(seq 1 200); do grep -q '^ALIVE ' "$W/zop.log" 2>/dev/null && break; sleep 0.1; done
    owner=$(awk '/^OWNER /{print $2}' "$W/zop.log" 2>/dev/null)
    wid=$(head -1 "$W/hold.log" 2>/dev/null | tr -dc '0-9')
    echo "${owner:-0}" > "$W/owner"; echo "${wid:-0}" > "$W/wid"
    if [ -z "${owner:-}" ] || [ -z "${wid:-}" ]; then
        exec {TRIG}>&-
        return 91
    fi

    # BEFORE: the owner is running and has not been signalled. This reading is
    # the positive control -- an empty result later means nothing unless a
    # non-empty one was seen first.
    ( export HAMWSYS="$W/seg"; [ "$mode" = kill ] && export HAMWSYS_LIVENESS=kill
      "$OUT/bin/cat" /dev/wsys ) > "$W/before.txt" 2>&1

    # Now, and only now, let it kill the holder.
    printf '\n' >&$TRIG

    for i in $(seq 1 200); do grep -q '^ZOMBIE ' "$W/zop.log" 2>/dev/null && break; sleep 0.1; done
    awk '{print $3}' "/proc/$owner/stat" 2>/dev/null > "$W/state"

    # AFTER: two reads, because the reaper mutates shared state on the first
    # and a fix that only works once is not a fix.
    ( export HAMWSYS="$W/seg"; [ "$mode" = kill ] && export HAMWSYS_LIVENESS=kill
      "$OUT/bin/cat" /dev/wsys ) > "$W/after.txt" 2>&1
    ( export HAMWSYS="$W/seg"; [ "$mode" = kill ] && export HAMWSYS_LIVENESS=kill
      "$OUT/bin/cat" /dev/wsys ) > "$W/after2.txt" 2>&1

    exec {TRIG}>&-
    return 0
}

# Kill the arm's parent by PID -- never by pattern. `pgrep -f` has given a
# wrong answer eight times in this tree; it matches the searcher's own command
# line.
stop_arm() {
    local W="$OUT/run/$1"
    local z; z=$(cat "$W/zpid" 2>/dev/null)
    [ -n "${z:-}" ] && kill "$z" 2>/dev/null
    wait "$z" 2>/dev/null
    return 0
}

listed() { grep -qx "$2" "$1" 2>/dev/null; }

# ================================================================ GREEN
if run_arm green proc; then
    W="$OUT/run/green"
    OWNER=$(cat "$W/owner"); WID=$(cat "$W/wid"); ST=$(cat "$W/state" 2>/dev/null)
    note "green: owner pid $OWNER, window $WID, owner state after kill '${ST:-?}'"

    # arm 0 -- THE PREMISE, MEASURED ON THIS KERNEL.
    if [ "$ST" = "Z" ]; then
        ok "the owner really is a ZOMBIE: /proc/$OWNER/stat state = Z"
    else
        bad "the owner never became a zombie (state '${ST:-?}') -- every arm below this line is measuring something other than the case under test"
    fi
    if kill -0 "$OWNER" 2>/dev/null; then
        ok "kill($OWNER, 0) SUCCEEDS on that corpse -- which is why the old predicate could never see it"
    else
        bad "kill($OWNER, 0) failed on the corpse; this kernel does not behave as the fix assumes and the fix's premise needs re-reading"
    fi

    if listed "$W/before.txt" "$WID"; then
        ok "window $WID is listed while its owner is RUNNING"
    else
        bad "window $WID was NOT listed even while its owner was running -- the instrument never produced a non-empty reading, so its later emptiness proves nothing"
    fi
    if listed "$W/after.txt" "$WID"; then
        bad "window $WID SURVIVED its owner becoming a zombie: win_reap_dead still cannot tell a corpse from a program"
    else
        ok "window $WID is GONE once its owner is a zombie"
    fi
    if listed "$W/after2.txt" "$WID"; then
        bad "window $WID came back on the second read"
    else
        ok "and it is still gone on a second read"
    fi
    # The reaper must not eat the furniture on its way past.
    for leaf in ctl self windows screen pool; do
        if listed "$W/after.txt" "$leaf"; then :; else
            bad "the reaper removed /dev/wsys/$leaf, which is not a window"
        fi
    done
    ok "the non-window entries of /dev/wsys survived the sweep"
else
    bad "the green arm could not be set up (rc $?) -- no reading was taken"
fi
stop_arm green

# ================================================================ RED
# THE NEGATIVE CONTROL, RUN. Same code, same scenario, old predicate.
if run_arm red kill; then
    W="$OUT/run/red"
    OWNER=$(cat "$W/owner"); WID=$(cat "$W/wid"); ST=$(cat "$W/state" 2>/dev/null)
    note "red: owner pid $OWNER, window $WID, owner state after kill '${ST:-?}'"
    if [ "$ST" = "Z" ]; then
        ok "negative control reached the same state: owner $OWNER is a zombie"
    else
        bad "negative control's owner never became a zombie (state '${ST:-?}')"
    fi
    if listed "$W/before.txt" "$WID"; then
        ok "negative control: window $WID listed while its owner runs"
    else
        bad "negative control: window $WID was never listed at all"
    fi
    if listed "$W/after.txt" "$WID"; then
        ok "NEGATIVE CONTROL RED AS REQUIRED: under HAMWSYS_LIVENESS=kill the window whose owner is a corpse is STILL LISTED -- the green arm above is attributable to the /proc test and nothing else"
    else
        bad "NEGATIVE CONTROL WENT GREEN: the old kill(2) predicate reclaimed the window too, so this gate cannot distinguish the fix from the bug and its green arm proves nothing"
    fi
else
    bad "the red arm could not be set up (rc $?) -- the gate has NOT been shown able to fail"
fi
stop_arm red

printf 'zowner: %d PASSED / %d FAILED (host process table %s)\n' \
       "$pass" "$fail" "$NPROC_HOST"
[ "$fail" -eq 0 ] || exit 1
exit 0
