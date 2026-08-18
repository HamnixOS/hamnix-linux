#!/usr/bin/env bash
# scripts/test_hamsh_spawn_kill_host.sh — QEMU-FREE host gate for ONE rule:
# **`kill $h` must end the PROGRAM the caller spawned, not the wrapper shell
# that happens to be running it.**
#
# WHAT IT IS GUARDING, AND HOW THAT WAS MEASURED RATHER THAN READ
# ===============================================================
# `spawn NS { prog }` forks a child that RUNS THE BLOCK -- user/hamsh.ad's
# exec_spawn calls exec_block, it does not exec the program in place -- so the
# pid tagged into the VT_PROC handle is an INTERMEDIATE SHELL and `prog` is
# that shell's own child.
#
# tests/linux/soak_desktop.sh reported the consequence and could only offer a
# hypothesis with line numbers for the cause. This is the measurement, taken
# on the shipped Linux-lane hamsh (scripts/hamlinux_build.sh) run directly on
# the host, before the fix:
#
#     PROBE_H=3763489                                 <- the handle
#     3763491 3763489 /bin/sleep 987654               <- pid, PPID, the program
#     PROBE_KST=0                                     <- the kill said it worked
#     3763491       1 /bin/sleep 987654               <- and it is STILL RUNNING
#
# The handle named 3763489; the program was 3763491 with PPID 3763489; after
# `kill $h` the shell reported success and the program survived, reparented to
# init. Both halves of the soak's hypothesis are confirmed, and the confirming
# evidence is a ps census, not a reading of the source.
#
# THE FIX AND THE THIRD DEFECT IT UNCOVERED
# =========================================
# hamsh's builtin now posts the note through lib/p9.ad's p9_note_tree, which
# reaches the target's ATTACHED descendants first -- the call user/kill.ad has
# used since the 2026-07-25 lifetime-cohort fix, so the builtin and the
# program of the same name finally agree. `spawn detached` severs only the
# SHELL's link to the wrapper; the wrapper's own child is attached.
#
# THAT DID NOT WORK EITHER, AT FIRST, AND THE REASON IS WORTH THE PARAGRAPH.
# Driven against user/kill.ad on this host, the cohort sweep MISSED the
# grandchild and exited 0. _p9_collect_children took ONE p9_listdir of /proc
# into a 4096-byte buffer, and p9_listdir stops at the caller's buffer size
# and returns a length indistinguishable from a complete read. MEASURED: this
# workstation has 2130 live pids and a 16442-byte /proc listing, so three
# quarters of the machine's pids were never looked at and p9_note_tree
# reported success having noted nothing. The guest desktop has ~40 processes
# and never hit it. The walk now STREAMS the listing. A gate that only ever
# ran on a small machine would have called the first fix green.
#
# THE SHAPE OF THE ASSERTION
# ==========================
# Two runs of the same shell, so that "gone" is a disappearance and not an
# instrument that never saw anything (an empty result is not a finding until
# the instrument has produced a non-empty one):
#
#   RUN A -- CONTROL, NO KILL. Spawn `/bin/sleep <tagA>`, print the handle,
#     exit. `spawn detached` is RFNOWAIT, so the wrapper outlives the shell
#     and the whole chain is still standing when the census runs. It must
#     find the program, and its PPID must BE the handle -- which is this
#     gate's direct statement of what the handle names.
#
#   RUN B -- THE ACT. Spawn `/bin/sleep <tagB>`, kill the handle, exit. The
#     program must be GONE by name, and so must the wrapper.
#
# NEGATIVE CONTROL, RUN, NUMBERS BELOW: a mutant hamsh with p9_note_tree put
# back to p9_note -- the shipped defect, exactly -- is built and driven
# through RUN B. Its program must SURVIVE. If it does not, this gate has not
# been shown able to go red and its green means nothing.
#
# hamsh EXITS 0 ON A PARSE ERROR, so every rc ends in a sentinel that must be
# observed. `pgrep -f` matching its own command line has given this project a
# wrong answer eight times; every census here is `ps -eo pid,ppid,cmd` with a
# bracketed grep, and every cleanup kills named pids one at a time.
#
# Exit 0 = PASS, 1 = FAIL. No QEMU. ~2 min, dominated by two hamsh builds.

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT" || exit 1

TAG="[spawn_kill]"
OUT="${HAMNIX_SPAWNKILL_OUT:-build/spawnkill}"
mkdir -p "$OUT" || exit 1
PASS=0; FAIL=0
ok()  { echo "$TAG PASS  $*"; PASS=$((PASS + 1)); }
bad() { echo "$TAG FAIL  $*"; FAIL=$((FAIL + 1)); }

BASE=$((500000 + (RANDOM % 90000)))
TAG_A=$BASE                 # RUN A, fixed build
TAG_B=$((BASE + 1))         # RUN B, fixed build
TAG_M=$((BASE + 2))         # RUN B, mutant build
ALL_TAGS="$TAG_A $TAG_B $TAG_M"
echo "$TAG program tags for this run: A=$TAG_A (control, not killed)  B=$TAG_B (killed)  M=$TAG_M (killed, mutant)"

# census <tag> -> prints "pid ppid cmd" lines for /bin/sleep <tag>, or nothing.
census() { ps -eo pid,ppid,cmd | grep "[s]leep $1"; }
# reap <tag...> — kill survivors BY PID, one at a time.
reap() {
    local t p
    for t in "$@"; do
        for p in $(census "$t" | awk '{print $1}'); do kill -KILL "$p" 2>/dev/null; done
    done
}
# reap_pid <pid> — for the wrapper shells, which carry no distinctive argv.
reap_pid() { [ -n "${1:-}" ] && [ "$1" -gt 1 ] 2>/dev/null && kill -KILL "$1" 2>/dev/null; }
trap 'reap $ALL_TAGS' EXIT

build_hamsh() { scripts/hamlinux_build.sh "$2" "$1" >"$1.build.log" 2>&1; }

# write_rc <file> <tag> <kill?> — one rc. Output goes to a FILE, never a pipe:
# the spawned program inherits stdout, so a pipe would never see EOF and this
# gate would hang instead of reporting.
write_rc() {
    local f="$1" t="$2" dokill="$3"
    {
        echo "n0 = ns { }"
        echo "h = spawn detached \$n0 { /bin/sleep $t }"
        echo 'echo HANDLE=$h SPAWN_STATUS=$status'
        echo "/bin/sleep 1"
        if [ "$dokill" = 1 ]; then
            echo 'kill $h'
            echo 'echo KILL_STATUS=$status'
            echo "/bin/sleep 1"
        fi
        echo "echo GATE_RC_COMPLETED"
        echo "exit"
    } >"$f"
}

# drive <elf> <rc> <log> — run it; return 1 if the rc did not reach its end.
drive() {
    timeout 120 "$1" --no-echo "$2" >"$3" 2>&1
    grep -q '^GATE_RC_COMPLETED$' "$3"
}
handle_of() { sed -n 's/^HANDLE=\([0-9][0-9]*\).*/\1/p' "$1" | tail -1; }

# ------------------------------------------------------- the fixed build
echo "$TAG building the tree's hamsh for the Linux lane ..."
if ! build_hamsh "$OUT/hamsh_fixed.elf" user/hamsh.ad; then
    echo "$TAG FAIL: the tree's own hamsh did not build"
    tail -30 "$OUT/hamsh_fixed.elf.build.log"; exit 1
fi

# ------------------------------------------------ RUN A: control, no kill
write_rc "$OUT/runA.rc" "$TAG_A" 0
if ! drive "$OUT/hamsh_fixed.elf" "$OUT/runA.rc" "$OUT/runA.log"; then
    echo "$TAG FAIL: RUN A's rc did not reach its sentinel (hamsh exits 0 on a parse error, so nothing below could be trusted)"
    tail -20 "$OUT/runA.log"; exit 1
fi
HA="$(handle_of "$OUT/runA.log")"
CA="$(census "$TAG_A")"
echo "$TAG RUN A handle=$HA ; census: ${CA:-<nothing>}"

if [ -n "$CA" ]; then
    ok "(A1) the census FINDS a spawned program that was not killed: $CA -- so an empty census later is a disappearance and not a blind instrument"
else
    bad "(A1) the census found nothing for a program that was never killed -- the instrument cannot see what it is meant to count, and every 'gone' below is worthless"
fi

A_PPID="$(printf '%s\n' "$CA" | awk 'NR==1{print $2}')"
if [ -n "$HA" ] && [ "$A_PPID" = "$HA" ]; then
    ok "(A2) the program's PPID is $A_PPID and the handle is $HA -- MEASURED: the handle spawn hands back names the WRAPPER SHELL, and the program is that wrapper's child. This is the defect, stated as a number."
else
    bad "(A2) the program's PPID is '$A_PPID' but the handle is '$HA' -- the relationship this gate is built on does not hold; re-derive it before reading anything below"
fi
reap "$TAG_A"; reap_pid "$HA"

# ---------------------------------------------------------- RUN B: the act
write_rc "$OUT/runB.rc" "$TAG_B" 1
if ! drive "$OUT/hamsh_fixed.elf" "$OUT/runB.rc" "$OUT/runB.log"; then
    echo "$TAG FAIL: RUN B's rc did not reach its sentinel"
    tail -20 "$OUT/runB.log"; exit 1
fi
HB="$(handle_of "$OUT/runB.log")"
KB="$(sed -n 's/^KILL_STATUS=//p' "$OUT/runB.log" | tail -1)"
CB="$(census "$TAG_B")"
echo "$TAG RUN B handle=$HB kill-status=$KB ; census after the kill: ${CB:-<nothing>}"

if [ "$KB" = 0 ]; then
    ok "(B1) the kill of a live handle reported \$status=0"
else
    bad "(B1) the kill of a live handle reported \$status='$KB'"
fi
if [ -z "$CB" ]; then
    ok "(B2) THE PROGRAM IS GONE: no /bin/sleep $TAG_B anywhere in ps after \`kill \$h\`, and the same census found the RUN A program a moment ago"
else
    bad "(B2) /bin/sleep $TAG_B SURVIVED the kill: $CB -- \`kill \$h\` is still ending the wrapper and orphaning the program"
fi
if [ -n "$HB" ] && ! ps -p "$HB" >/dev/null 2>&1; then
    ok "(B3) the wrapper shell (pid $HB) is gone too, so the fix reaches the cohort rather than moving the leak"
else
    bad "(B3) the wrapper shell (pid $HB) is still alive after the kill"
fi
reap "$TAG_B"; reap_pid "$HB"

# ---------------------------------------------------- NEGATIVE CONTROL
# Put the note back to p9_note -- the shipped defect, one token. RUN B's
# program must SURVIVE on this binary.
echo "$TAG NEGATIVE CONTROL: rebuilding hamsh with the cohort note put back to a single-process note ..."
MUT="$OUT/hamsh_mutant.ad"
sed 's/^        p9_note_tree(pid, cast\[Ptr\[uint8\]\]("kill"))$/        p9_note(pid, cast[Ptr[uint8]]("kill"))   # NEGATIVE CONTROL: the shipped defect/' \
    user/hamsh.ad >"$MUT"
if cmp -s "$MUT" user/hamsh.ad; then
    bad "(NC) the mutation did not apply -- the line it edits has moved, so the control asserts NOTHING and must be repaired before its green is believed"
elif ! build_hamsh "$OUT/hamsh_mutant.elf" "$MUT"; then
    bad "(NC) the mutant did not build -- a red from a broken compile is not a red from the defect"
    tail -20 "$OUT/hamsh_mutant.elf.build.log"
else
    write_rc "$OUT/runM.rc" "$TAG_M" 1
    if ! drive "$OUT/hamsh_mutant.elf" "$OUT/runM.rc" "$OUT/runM.log"; then
        bad "(NC) the mutant's rc did not reach its sentinel -- the control measured nothing"
    else
        HM="$(handle_of "$OUT/runM.log")"
        KM="$(sed -n 's/^KILL_STATUS=//p' "$OUT/runM.log" | tail -1)"
        CM="$(census "$TAG_M")"
        echo "$TAG mutant: handle=$HM kill-status=$KM ; census after the kill: ${CM:-<nothing>}"
        if [ -n "$CM" ]; then
            ok "(NC) the control is RED where it must be: with the note put back to p9_note the kill still reported \$status=$KM and /bin/sleep $TAG_M SURVIVED -- $CM. Assertion B2 fails on it, so B2 can fail."
        else
            bad "(NC) the mutant ALSO ended the program, so assertion B2 has not been shown able to go red and its green means nothing -- the fix under test may not be what is doing the work"
        fi
        reap "$TAG_M"; reap_pid "$HM"
    fi
fi

reap $ALL_TAGS
echo "$TAG ================================================"
echo "$TAG $PASS PASSED / $FAIL FAILED"
[ "$FAIL" = 0 ] || exit 1
exit 0
