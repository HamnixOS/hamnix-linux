#!/usr/bin/env bash
# init_orphan_reap.sh — AN INIT MUST wait4 THE CHILDREN IT ADOPTS, AND MUST NOT
# EAT THE ONES SOMEBODY IS WAITING FOR.
#
# WHAT THIS GATE IS FOR
# =====================
# PID 1 on this port is hamsh, and a shell is not an init. Every orphan on the
# machine reparents to it, and until 2026-08-17 nothing there ever wait4'd one:
# a 900 s desktop soak ended with 86 corpses, all of them scene applications
# whose wrapper shell had been killed in the same sweep that killed them, so
# the parent that would have waited died first.
#
# The fix is user/linux-syscalls.c's reap_orphans(). The DANGEROUS fix is the
# obvious one -- `while (waitpid(-1, &st, WNOHANG) > 0);` -- which reaps
# orphans and also throws away the exit statuses that hamsh's job control,
# sys_waitpid_jc and the detached-handle path are each waiting to read. A shell
# that cannot report why a job died is a worse bug than the zombies and a
# silent one. So this gate asserts BOTH halves, and runs a negative control for
# each, because "it did not break job control" is trivially true of a function
# that does nothing and there is no way to tell those apart without watching
# the assertion fail on demand.
#
# THE FOUR ARMS
# =============
#   on       GREEN. The adopted orphan is reaped; an own child's status is
#            still 42; the detached table strands nobody.
#   off      RED, RUN. HAMNIX_ORPHAN_REAP=off. The orphan stays a corpse.
#            Without this arm, "no zombies" could just as well mean the
#            scenario never made one.
#   greedy   RED, RUN. HAMNIX_ORPHAN_REAP=greedy makes the reaper ignore the
#            own-children table -- the blanket-drain bug, on purpose. The own
#            child's status must be GONE. This is the arm that proves the
#            must-not-break assertion is an assertion.
#   dclear   RED, RUN. HAMNIX_DETACHED_FULL=clear restores detached_remember()'s
#            old `detached_n = 0`. Its corpses must be counted, because
#            "the table stranded the wrapper shells" was read off the source
#            and never measured.
#
# HOW IT GETS TO BE AN INIT, AND WHY NOT A PID NAMESPACE
# ======================================================
# tests/linux/subreap_exec.c sets PR_SET_CHILD_SUBREAPER and execs the driver,
# so orphaned descendants reparent to it exactly as they would to PID 1 --
# on the HOST, against the host's whole /proc. `unshare --pid --fork` would
# make it PID 1 for real and would also shrink the process table to a handful,
# and a scan that is only ever run small is a scan that will call a broken
# version green. This tree has paid for that once already: a 4096-byte
# directory read looked complete on a guest with 40 processes.
#
# It is NOT the production mechanism, and the gate says so rather than implying
# otherwise. What it shares with production is every line after
# adopts_orphans() returns 1.
#
# WHAT IT DOES NOT ASSERT
# =======================
#  * That hamsh itself is fixed. This gate runs the RUNTIME's reaper under a
#    driver of its own; the soak is what measures hamsh as PID 1.
#  * That the reaper is cheap. It costs one waitid(2) when idle by
#    construction; nothing here times it.
#  * Anything about signals. reap_orphans is polled from sys_rfork and the idle
#    park; there is no SIGCHLD handler and this gate does not pretend there is.
#
# No device is touched. No framebuffer, no /dev/dri, no audio.
set -uo pipefail
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ" || exit 1

pass=0; fail=0
ok()   { printf 'orphan: PASS %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf 'orphan: FAIL %s\n' "$*"; fail=$((fail+1)); }
note() { printf 'orphan: .... %s\n' "$*"; }

OUT="${HAMLINUX_OUT:-$(mktemp -d /tmp/orphan.XXXXXX)}"
mkdir -p "$OUT/bin"

command -v gcc >/dev/null 2>&1 || { echo "orphan: SKIP no gcc"; exit 0; }
gcc -Wall -O1 -o "$OUT/bin/subreap_exec" tests/linux/subreap_exec.c \
    >"$OUT/subreap.log" 2>&1 || {
    echo "orphan: FATAL subreap_exec.c did not build"; sed 's/^/== /' "$OUT/subreap.log"; exit 1; }
if [ ! -x "$OUT/bin/init_orphan" ]; then
    scripts/hamlinux_build.sh tests/linux/init_orphan.ad "$OUT/bin/init_orphan" \
        >"$OUT/build.init_orphan.log" 2>&1 || {
        echo "orphan: FATAL init_orphan.ad did not build"
        tail -20 "$OUT/build.init_orphan.log"; exit 1; }
fi

NPROC_HOST=$(ls -d /proc/[0-9]* 2>/dev/null | wc -l)
note "host process table: $NPROC_HOST processes -- the scan runs against all of it"

# ---------------------------------------------------------------- one arm
# $1 = arm name.  Leaves $OUT/run/$1/{out.log,children.txt}
run_arm() {
    local arm="$1"
    local W="$OUT/run/$arm"
    rm -rf "$W"; mkdir -p "$W"
    (
        case "$arm" in
            off|greedy) export HAMNIX_ORPHAN_REAP="$arm" ;;
            dclear)     export HAMNIX_DETACHED_FULL=clear ;;
        esac
        exec "$OUT/bin/subreap_exec" "$OUT/bin/init_orphan" \
             >"$W/out.log" 2>&1
    ) &
    local dp=$!
    echo "$dp" > "$W/dpid"

    local i
    for i in $(seq 1 600); do
        grep -q '^DONE ' "$W/out.log" 2>/dev/null && break
        sleep 0.2
    done
    if ! grep -q '^DONE ' "$W/out.log" 2>/dev/null; then
        kill "$dp" 2>/dev/null; wait "$dp" 2>/dev/null
        return 1
    fi

    # THE PROCESS TABLE, READ FROM OUTSIDE, WHILE THE STATE STILL EXISTS.
    # Not `ps --ppid`: `ps -e` silently overrides --ppid in this tree's
    # experience, and a sweep once ran against every process on the box
    # believing it was looking at four. /proc/<pid>/stat is read directly, and
    # the state is taken from the LAST ')' because comm may contain spaces and
    # parentheses.
    local self; self=$(awk '/^SELF /{print $2}' "$W/out.log")
    echo "$self" > "$W/self"
    : > "$W/children.txt"
    local d p line st pp
    for d in /proc/[0-9]*; do
        p=${d#/proc/}
        line=$(cat "$d/stat" 2>/dev/null) || continue
        line=${line##*\)}                       # everything after the LAST ')'
        set -- $line
        st="${1:-}"; pp="${2:-}"
        [ "$pp" = "$self" ] && printf '%s %s %s\n' "$p" "$st" "$pp" >> "$W/children.txt"
    done
    kill "$dp" 2>/dev/null; wait "$dp" 2>/dev/null
    return 0
}

f()  { awk -v k="$1" '$1==k{print $2}' "$2/out.log" | head -1; }
nz() { awk '$2=="Z"' "$1/children.txt" | wc -l; }

# ================================================================== ARM on
if run_arm on; then
    W="$OUT/run/on"
    SELF=$(cat "$W/self"); BST=$(f BSTAT "$W"); RE=$(f REAPED "$W")
    GK=$(f GRANDKID "$W"); DR=$(f DROPPED "$W"); DS=$(f DSPAWN "$W")
    note "on: self $SELF, orphan $GK, BSTAT $BST, REAPED $RE, detached spawned $DS dropped $DR"

    if [ "$BST" = "42" ]; then
        ok "an own child's exit status SURVIVED the reaper: sys_waitpid returned 42"
    else
        bad "the reaper ATE an own child's status: sys_waitpid returned '$BST', not 42 -- this is the failure that would silently break hamsh's job control"
    fi
    if [ "${RE:-0}" -ge 1 ]; then
        ok "the runtime's own counter says it reaped $RE adopted orphan(s)"
    else
        bad "sys_orphans_reaped() is $RE -- the reaper never reclaimed anything, so any absence of corpses below is somebody else's doing"
    fi
    if grep -q "^$GK Z " "$W/children.txt"; then
        bad "the adopted orphan $GK is STILL A ZOMBIE under $SELF"
    else
        ok "the adopted orphan $GK is GONE from the process table"
    fi
    Z=$(nz "$W")
    if [ "$Z" -eq 0 ]; then
        ok "no corpse of any kind is left under $SELF (detached spawns: $DS)"
    else
        bad "$Z corpses remain under $SELF after $DS detached spawns and one adopted orphan"
    fi
    if [ "${DR:-0}" -eq 0 ]; then
        ok "the detached table dropped nobody: it grew to hold $DS live children instead of evicting them"
    else
        bad "the detached table evicted $DR pids it had promised to wait for"
    fi
else
    bad "arm on never reached DONE -- no reading was taken"
fi

# ================================================================= ARM off
if run_arm off; then
    W="$OUT/run/off"
    SELF=$(cat "$W/self"); GK=$(f GRANDKID "$W"); RE=$(f REAPED "$W"); BST=$(f BSTAT "$W")
    note "off: self $SELF, orphan $GK, REAPED $RE, BSTAT $BST"
    if [ "${RE:-0}" -eq 0 ]; then
        ok "negative control really did disable the reaper: sys_orphans_reaped() is 0"
    else
        bad "HAMNIX_ORPHAN_REAP=off did not disable the reaper (reaped $RE) -- this arm is not the control it claims to be"
    fi
    if grep -q "^$GK Z " "$W/children.txt"; then
        ok "NEGATIVE CONTROL RED AS REQUIRED: without the reaper the adopted orphan $GK is a permanent zombie -- so arm on's empty process table is the reaper's doing and not the scenario's"
    else
        bad "NEGATIVE CONTROL WENT GREEN: the orphan vanished with the reaper disabled, so this gate cannot attribute anything and arm on proves nothing"
    fi
    if [ "$BST" = "42" ]; then
        ok "and with the reaper off the own child's status is 42, as it must be either way"
    else
        bad "the own child's status was '$BST' with the reaper OFF -- something other than the reaper is eating statuses"
    fi
else
    bad "arm off never reached DONE"
fi

# ============================================================== ARM greedy
if run_arm greedy; then
    W="$OUT/run/greedy"
    SELF=$(cat "$W/self"); BST=$(f BSTAT "$W"); GK=$(f GRANDKID "$W")
    note "greedy: self $SELF, BSTAT $BST, orphan $GK"
    if [ "$BST" = "42" ]; then
        bad "NEGATIVE CONTROL WENT GREEN: a reaper that deliberately ignores the own-children table STILL left the status intact, so arm on's 42 does not show the table is load-bearing and the must-not-break assertion is not an assertion"
    else
        ok "NEGATIVE CONTROL RED AS REQUIRED: ignoring the own-children table loses the status (sys_waitpid returned '$BST') -- the ownership check is what keeps arm on's 42"
    fi
    if grep -q "^$GK Z " "$W/children.txt"; then
        bad "greedy did not even reap the orphan"
    else
        ok "greedy reaped the orphan too, as expected -- it over-reaps, it does not under-reap"
    fi
else
    bad "arm greedy never reached DONE"
fi

# ============================================================== ARM dclear
# THE detached_remember() OVERFLOW, MEASURED. Read the long note at that
# function for what turned out to be conditional about it.
if run_arm dclear; then
    W="$OUT/run/dclear"
    SELF=$(cat "$W/self"); DS=$(f DSPAWN "$W"); GK=$(f GRANDKID "$W")
    Z=$(nz "$W")
    note "dclear: self $SELF, detached spawned $DS, corpses left $Z"
    if [ "$Z" -gt 0 ]; then
        ok "NEGATIVE CONTROL RED AS REQUIRED: the old 'detached_n = 0' stranded $Z of $DS concurrently live detached children as permanent corpses -- arm on's zero is the growable table's doing"
    else
        bad "NEGATIVE CONTROL WENT GREEN: the old overflow behaviour stranded nothing, so arm on's zero is not attributable to the change and the claim that this stranded the soak's wrapper shells stays unmeasured"
    fi
else
    bad "arm dclear never reached DONE"
fi

printf 'orphan: %d PASSED / %d FAILED (host process table %s)\n' \
       "$pass" "$fail" "$NPROC_HOST"
[ "$fail" -eq 0 ] || exit 1
exit 0
