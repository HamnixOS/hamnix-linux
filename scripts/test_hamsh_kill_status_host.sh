#!/usr/bin/env bash
# scripts/test_hamsh_kill_status_host.sh — QEMU-FREE host gate for ONE rule:
# **hamsh's `kill` builtin must be able to FAIL.**
#
# WHAT IT IS GUARDING, AND HOW THAT WAS MEASURED
# ==============================================
# user/hamsh.ad's _builtin_kill was, verbatim, until 2026-08-17:
#
#       p9_note(pid, cast[Ptr[uint8]]("kill"))
#       eval_status = 0
#
# The return value DISCARDED and the status set to success unconditionally.
# p9_note fails closed -- lib/p9.ad returns -1 when the open fails, and on
# this lane note_open (user/linux-syscalls.c) fails the OPEN when kill(pid,0)
# says the target is gone -- so the information was there and was thrown away.
#
# MEASURED on the pre-fix binary through the seam this gate uses (hamsh built
# by scripts/hamlinux_build.sh and run directly on the host):
#
#       kill 999999
#       echo KST=$status E=$errstr     ->   KST=0 E=
#
# A kill of a pid that does not exist reported SUCCESS and set no error. That
# is why 900 s of tests/linux/soak_desktop.sh killing the wrong process
# printed no `hamsh:` line anywhere: the shell said it worked, every time,
# without looking. It is the same shape as the wallpaper verb, an installer
# that wrote nothing, and `hpm update` upgrading nothing.
#
# THE SEAM, AND WHY IT IS THIS ONE
# ================================
# scripts/test_hamsh_lang_host.sh's seam (adder_bin x86_64-linux, script over
# stdin) CANNOT be used here and that was established by running it, not by
# reading: on that build sys_open works but lib/p9.ad's spawn is inert, so
# `/bin/echo hi` answers "hamsh: command not found: /bin/echo" and `spawn`
# returns status 1 with no handle. Nothing about killing a real process can be
# asserted on a build that cannot start one.
#
# scripts/hamlinux_build.sh builds the SHIPPED Linux-lane hamsh -- the same
# .ad through the same clang link against user/linux-syscalls.c that the
# installed disk carries -- and that ELF runs directly on the host. Real
# rfork, real execve, real /proc/<pid>/note translated to kill(2). It is the
# shipped code path, not a stand-in for it.
#
# hamsh EXITS 0 ON A PARSE ERROR (measured, repeatedly, by this project), so a
# script that never ran looks exactly like one that ran clean. Every rc below
# therefore ends with a sentinel that must be observed, and its absence is a
# FAIL rather than a silent green.
#
# ASSERTIONS
#   1. `kill <pid that does not exist>` sets $status non-zero.
#   2. ... and sets $errstr to something that names the reason.
#   3. ... and says so on stderr, naming the pid, in words a person can act on.
#   4. THE POSITIVE HALF, so 1-3 are not satisfied by a shell that fails at
#      everything: `kill $h` on a live handle sets $status 0.
#
# NEGATIVE CONTROL, RUN, NUMBERS REPORTED BELOW: a mutant hamsh with the
# reachability probe short-circuited -- i.e. the pre-fix "cannot fail" shape
# restored -- is built and driven through the same assertions, and assertions
# 1-3 MUST go red on it. A gate that has not been shown able to go red is not
# a gate.
#
# Exit 0 = PASS, 1 = FAIL. No QEMU. ~90 s, dominated by two hamsh builds.

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT" || exit 1

TAG="[kill_status]"
OUT="${HAMNIX_KILLGATE_OUT:-build/killstatus}"
mkdir -p "$OUT" || exit 1
PASS=0; FAIL=0
ok()  { echo "$TAG PASS  $*"; PASS=$((PASS + 1)); }
bad() { echo "$TAG FAIL  $*"; FAIL=$((FAIL + 1)); }

# A pid that cannot exist: /proc/sys/kernel/pid_max is the ceiling, so
# pid_max + 1 is unallocatable by construction rather than by hoping.
PIDMAX="$(cat /proc/sys/kernel/pid_max 2>/dev/null)"
case "$PIDMAX" in ''|*[!0-9]*) PIDMAX=4194304 ;; esac
DEADPID=$((PIDMAX + 1))
echo "$TAG the unreachable pid is $DEADPID (pid_max=$PIDMAX, so it can never be allocated)"

# --------------------------------------------------------------- the rc
# One file, driven twice (once per binary). $SLEEPTAG makes the live handle's
# program findable in ps by a string nothing else on the machine carries.
SLEEPTAG=$((700000 + (RANDOM % 90000)))
RC="$OUT/kill_status.rc"
cat >"$RC" <<RCEOF
kill $DEADPID
echo NEG_STATUS=\$status
echo "NEG_ERRSTR=[\$errstr]"
n0 = ns { }
h = spawn detached \$n0 { /bin/sleep $SLEEPTAG }
echo HANDLE=\$h SPAWN_STATUS=\$status
/bin/sleep 1
kill \$h
echo POS_STATUS=\$status
echo GATE_RC_COMPLETED
exit
RCEOF

# reap_tag — kill every surviving /bin/sleep $SLEEPTAG BY PID. Never pkill by
# pattern; `pgrep -f` matching its own command line has given this project a
# wrong answer eight times, so the census is `ps -eo pid,cmd` + a bracketed
# grep that cannot match itself.
reap_tag() {
    local p
    for p in $(ps -eo pid,cmd | grep "[s]leep $SLEEPTAG" | awk '{print $1}'); do
        kill -KILL "$p" 2>/dev/null
    done
}

# build_hamsh <out.elf> <src.ad> — returns non-zero if it did not link.
build_hamsh() {
    scripts/hamlinux_build.sh "$2" "$1" >"$1.build.log" 2>&1
}

# drive <elf> <logfile> — run the rc; stdout+stderr to a FILE, never a pipe
# (the spawned /bin/sleep inherits stdout, so a pipe would never see EOF and
# the gate would hang instead of failing).
drive() {
    timeout 120 "$1" --no-echo "$RC" >"$2" 2>&1
    reap_tag
}

# ------------------------------------------------------- the fixed build
echo "$TAG building the tree's hamsh for the Linux lane ..."
if ! build_hamsh "$OUT/hamsh_fixed.elf" user/hamsh.ad; then
    echo "$TAG FAIL: the tree's own hamsh did not build"
    tail -30 "$OUT/hamsh_fixed.elf.build.log"
    exit 1
fi
LOG="$OUT/fixed.log"
drive "$OUT/hamsh_fixed.elf" "$LOG"

if ! grep -q '^GATE_RC_COMPLETED$' "$LOG"; then
    echo "$TAG FAIL: the rc did not run to its end -- hamsh exits 0 on a parse"
    echo "$TAG       error, so nothing below this point could be trusted."
    tail -30 "$LOG"
    exit 1
fi
echo "$TAG the rc ran to its sentinel"

NEG_STATUS="$(sed -n 's/^NEG_STATUS=//p' "$LOG" | tail -1)"
NEG_ERRSTR="$(sed -n 's/^NEG_ERRSTR=//p' "$LOG" | tail -1)"
POS_STATUS="$(sed -n 's/^POS_STATUS=//p' "$LOG" | tail -1)"
HANDLE="$(sed -n 's/^HANDLE=\([0-9][0-9]*\).*/\1/p' "$LOG" | tail -1)"
echo "$TAG measured: NEG_STATUS=$NEG_STATUS NEG_ERRSTR=$NEG_ERRSTR POS_STATUS=$POS_STATUS HANDLE=$HANDLE"

# (1) it can fail
if [ -n "$NEG_STATUS" ] && [ "$NEG_STATUS" != 0 ]; then
    ok "(1) \`kill $DEADPID\` set \$status=$NEG_STATUS -- a kill of a pid that cannot exist is NOT reported as success"
else
    bad "(1) \`kill $DEADPID\` set \$status='$NEG_STATUS' -- hamsh's kill still cannot fail"
fi

# (2) it says why, in $errstr
case "$NEG_ERRSTR" in
    *"no such process"*)
        ok "(2) \$errstr is $NEG_ERRSTR -- it names the reason, not just a number" ;;
    *)
        bad "(2) \$errstr is $NEG_ERRSTR -- a non-zero status with no reason is half a diagnostic" ;;
esac

# (3) it says so on stderr, naming the pid
if grep -q "hamsh: kill: pid $DEADPID: no such process" "$LOG" \
   && grep -q "NOTHING WAS KILLED" "$LOG"; then
    ok "(3) it printed a line naming pid $DEADPID and stating that nothing was killed"
else
    bad "(3) no diagnostic naming pid $DEADPID reached stderr -- the failure is silent to the person reading the console"
fi

# (4) the positive half
if [ "$POS_STATUS" = 0 ]; then
    ok "(4) \`kill \$h\` on a LIVE handle (pid $HANDLE) set \$status=0 -- assertions 1-3 are not a shell that fails at everything"
else
    bad "(4) \`kill \$h\` on a live handle set \$status='$POS_STATUS' -- killing a process that exists must succeed"
fi

# ---------------------------------------------------- NEGATIVE CONTROL
# Restore the pre-fix shape by short-circuiting the reachability probe: the
# builtin then takes the success path unconditionally, exactly as it did
# before 2026-08-17. Assertions 1-3 must go RED.
echo "$TAG NEGATIVE CONTROL: rebuilding hamsh with the reachability probe short-circuited ..."
MUT="$OUT/hamsh_mutant.ad"
sed 's/^        if p9_note_reachable(pid) < 0:$/        if 0 < 0:   # NEGATIVE CONTROL: the pre-fix "cannot fail" shape/' \
    user/hamsh.ad >"$MUT"
if cmp -s "$MUT" user/hamsh.ad; then
    bad "(NC) the mutation did not apply -- the line it edits has moved, so the control asserts NOTHING and must be repaired before its green is believed"
else
    if ! build_hamsh "$OUT/hamsh_mutant.elf" "$MUT"; then
        bad "(NC) the mutant did not build -- a red from a broken compile is not a red from the defect"
        tail -20 "$OUT/hamsh_mutant.elf.build.log"
    else
        MLOG="$OUT/mutant.log"
        drive "$OUT/hamsh_mutant.elf" "$MLOG"
        M_STATUS="$(sed -n 's/^NEG_STATUS=//p' "$MLOG" | tail -1)"
        M_ERRSTR="$(sed -n 's/^NEG_ERRSTR=//p' "$MLOG" | tail -1)"
        M_POS="$(sed -n 's/^POS_STATUS=//p' "$MLOG" | tail -1)"
        M_DIAG=0
        grep -q "hamsh: kill: pid $DEADPID" "$MLOG" && M_DIAG=1
        echo "$TAG mutant measured: NEG_STATUS=$M_STATUS NEG_ERRSTR=$M_ERRSTR POS_STATUS=$M_POS stderr-diagnostic=$M_DIAG"
        if ! grep -q '^GATE_RC_COMPLETED$' "$MLOG"; then
            bad "(NC) the mutant's rc did not reach its sentinel -- the control measured nothing"
        elif [ "$M_STATUS" = 0 ] && [ "$M_ERRSTR" = "[]" ] && [ "$M_DIAG" = 0 ]; then
            ok "(NC) the control is RED where it must be: with the probe removed, \`kill $DEADPID\` gives \$status=0, an EMPTY \$errstr and NO stderr line -- assertions 1, 2 and 3 all fail on it, so all three can fail"
        else
            bad "(NC) the control did NOT reproduce the defect (NEG_STATUS=$M_STATUS ERRSTR=$M_ERRSTR diag=$M_DIAG) -- assertions 1-3 have not been shown able to go red and their green means nothing"
        fi
        if [ "$M_POS" = 0 ]; then
            ok "(NC2) the mutant still reports 0 for the LIVE kill, so the control isolates the failure path and does not simply break the builtin"
        else
            bad "(NC2) the mutant's live kill reported '$M_POS' -- the mutation changed more than the failure path and the control is not clean"
        fi
    fi
fi

reap_tag
echo "$TAG ================================================"
echo "$TAG $PASS PASSED / $FAIL FAILED"
[ "$FAIL" = 0 ] || exit 1
exit 0
