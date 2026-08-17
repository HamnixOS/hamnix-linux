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
# tests/linux/tail_file.sh — `tail FILE` must answer, not hang, and the
# answer must be GNU tail's.
#
# WHAT IS UNDER TEST.  user/tail.ad's FILE operand.  Before it, `tail`
# inspected argv[1] only far enough to see whether it began with '-' and
# then read STDIN whatever the arguments said.  Two failures fell out of
# that one omission:
#
#   * on a console, stdin is the terminal, so `tail /lib/modules/<rel>/
#     modules.dep` blocked forever.  HANDOFF.md's honestly-broken list
#     recorded it as "tail FILE wedges the shell"; a VM sat in it until
#     the host timeout took it away.
#   * in a script, where stdin is already at EOF, the same command
#     printed NOTHING and exited 0 — the hang's twin, wearing a success.
#
# So this file asserts BOTH: bounded time (every run is under `timeout`,
# because a test for a hang that itself hangs teaches nobody anything)
# AND the exact bytes, diffed against GNU tail on the identical input.
# `head` is checked on the same shapes as the control: it grew the FILE
# operand months ago and is the reason we know what the fix looks like.
#
# THE SHAPES, chosen because the differences between them are diagnoses:
# the real modules.dep that wedged the VM; files with and without a
# trailing newline; fewer lines than tail's default of 10 and more; one
# line with no newline; a wholly empty file; a file read from a PIPE
# rather than a path; "-" as an explicit stdin operand; several FILEs at
# once (the `==> NAME <==` banner); a missing file; and inputs LARGER
# than tail's internal window, where the old code silently tailed the
# first 8 KiB and printed the wrong lines.
#
# No VM. Builds tail and head through the Linux lane and runs them on
# the host, because a hang is a hang and `tail` is an ordinary program.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && cd .. && pwd)"
cd "$PROJ_ROOT"

WORK="${HAMLINUX_TAIL_WORK:-$(mktemp -d "${TMPDIR:-/tmp}/tail_file.XXXXXX")}"
KEEP="${HAMLINUX_TAIL_KEEP:-0}"
cleanup() { [ "$KEEP" = 1 ] || rm -rf "$WORK"; }
trap cleanup EXIT
# A bare EXIT trap does not run when the shell is killed by a signal, so a
# gate stopped by `timeout` (TERM) or ^C (INT) skipped its cleanup entirely.
# Re-exit on those, which makes the EXIT trap above run on every path out.
trap 'exit 130' INT TERM HUP

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$*"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$*"; }
note(){ printf '%s\n' "$*"; }

# Every invocation of the program under test goes through this. TMO is
# the whole point of the gate: the defect was an unbounded wait, so a
# run that needs more than TMO seconds has failed by definition and the
# harness moves on instead of joining it.
TMO="${HAMLINUX_TAIL_TIMEOUT:-10}"

command -v tail >/dev/null 2>&1 || { echo "no GNU tail on this host"; exit 2; }
command -v head >/dev/null 2>&1 || { echo "no GNU head on this host"; exit 2; }

# ---- build ---------------------------------------------------------------
BIN="$WORK/bin"; mkdir -p "$BIN"
for prog in tail head; do
    if ! nice -n 15 scripts/hamlinux_build.sh "user/$prog.ad" "$BIN/$prog" \
            >"$WORK/build.$prog.log" 2>&1; then
        note "build of user/$prog.ad FAILED:"; sed -e 's/^/    /' "$WORK/build.$prog.log"
        exit 2
    fi
done
ok "built user/tail.ad and user/head.ad through the Linux lane"

# ---- fixtures ------------------------------------------------------------
F="$WORK/f"; mkdir -p "$F"
seq 1 20        | sed -e 's/^/line /'            > "$F/20lines"
seq 1 3         | sed -e 's/^/line /'            > "$F/3lines"
printf 'alpha\nbeta\ngamma'                      > "$F/no_final_nl"
printf 'solo line with no newline'               > "$F/one_line_no_nl"
printf 'one\n'                                   > "$F/one_line"
printf '\n'                                      > "$F/just_newline"
: > "$F/empty"
seq 1 5000      | sed -e 's/^/row /'             > "$F/big"          # ~40 KB
seq 1 40000     | sed -e 's/^/row /'             > "$F/huge"         # ~300 KB
# A single line far larger than the 65536-byte window: the case where a
# complete answer is impossible and must therefore not be faked.
{ head -c 200000 /dev/zero | tr '\0' 'x'; printf '\n'; } > "$F/onehugeline"

# The file that actually wedged the VM. Use the host's own modules.dep
# when there is one (same shape, few KB, thousands of colon-separated
# lines); otherwise synthesise one so the case is never silently skipped.
REALDEP="$(ls -1 /lib/modules/*/modules.dep 2>/dev/null | head -1 || true)"
if [ -n "$REALDEP" ] && [ -r "$REALDEP" ]; then
    head -c 8192 "$REALDEP" > "$F/modules.dep.raw"
    # keep whole lines only
    sed -e '$d' "$F/modules.dep.raw" > "$F/modules.dep"
    note "modules.dep fixture taken from $REALDEP"
else
    for i in $(seq 1 200); do
        printf 'kernel/drivers/x/m%d.ko: kernel/lib/dep%d.ko\n' "$i" "$i"
    done > "$F/modules.dep"
    note "modules.dep fixture synthesised (host has none)"
fi

# ---- the oracle comparison ----------------------------------------------
# cmp_run <label> <flag-or-empty> <file...>
# Runs GNU tail and ours with identical argv and identical (empty) stdin,
# then diffs stdout AND exit status. stdin is </dev/null deliberately: it
# is the SCRIPT shape, in which the old tail exited 0 having printed
# nothing, so a gate that only asserted "it terminated" would have passed
# against the bug.
cmp_run() {
    local label="$1"; shift
    local -a args=("$@")
    local g_out o_out g_rc o_rc
    g_out="$(timeout "$TMO" tail "${args[@]}" </dev/null 2>"$WORK/g.err")"; g_rc=$?
    o_out="$(timeout "$TMO" "$BIN/tail" "${args[@]}" </dev/null 2>"$WORK/o.err")"; o_rc=$?
    if [ "$o_rc" = 124 ]; then
        bad "$label: HUNG (no answer in ${TMO}s) — this is the defect"
        return
    fi
    if [ "$o_out" != "$g_out" ]; then
        bad "$label: output differs from GNU tail"
        printf '       gnu: %s\n' "$(printf '%s' "$g_out" | head -3 | tr '\n' '|')"
        printf '       ours: %s\n' "$(printf '%s' "$o_out" | head -3 | tr '\n' '|')"
        return
    fi
    if [ "$o_rc" != "$g_rc" ]; then
        bad "$label: exit $o_rc, GNU tail exit $g_rc"
        return
    fi
    ok "$label: matches GNU tail (exit $o_rc, $(printf '%s' "$o_out" | wc -l) lines)"
}

note ""
note "== the hang itself, reproduced in the shape the console has"
# Every other case here runs with stdin at /dev/null, which is the SCRIPT
# shape: the old tail read EOF at once and exited 0 having printed
# nothing. On a console stdin is a terminal that never reaches EOF, and
# that is where the same omission became an unbounded wait. A fifo held
# open read-write by this script is exactly that: a stdin with a live
# writer that sends nothing. `tail FILE` must not look at it.
mkfifo "$WORK/never" || { note "cannot mkfifo"; exit 2; }
exec 9<>"$WORK/never"
o="$(timeout "$TMO" "$BIN/tail" -3 "$F/20lines" <&9 2>/dev/null)"; rc=$?
exec 9>&-
if [ "$rc" = 124 ]; then
    bad "stdin is a live-but-silent fifo: tail FILE HUNG for ${TMO}s — the defect"
elif [ "$o" != "$(tail -n 3 "$F/20lines")" ]; then
    bad "stdin is a live-but-silent fifo: returned, but with the wrong lines"
else
    ok "stdin is a live-but-silent fifo: tail FILE answers from the FILE and exits"
fi

note ""
note "== tail FILE — the case that wedged the shell"
cmp_run "tail modules.dep"            "$F/modules.dep"
cmp_run "tail 20lines"                "$F/20lines"
cmp_run "tail 3lines (fewer than 10)" "$F/3lines"
cmp_run "tail no-final-newline"       "$F/no_final_nl"
cmp_run "tail one line, no newline"   "$F/one_line_no_nl"
cmp_run "tail one line"               "$F/one_line"
cmp_run "tail a lone newline"         "$F/just_newline"
cmp_run "tail empty file"             "$F/empty"

note ""
note "== -N"
cmp_run "tail -1 20lines"   -1 "$F/20lines"
cmp_run "tail -5 20lines"   -5 "$F/20lines"
cmp_run "tail -99 20lines"  -99 "$F/20lines"
cmp_run "tail -0 20lines"   -0 "$F/20lines"
cmp_run "tail -1 no-final-newline" -1 "$F/no_final_nl"
cmp_run "tail -1 empty"     -1 "$F/empty"

note ""
note "== larger than the internal window"
# The old tail slurped the FIRST 8 KiB and tailed that, so on these it
# terminated promptly with the WRONG lines. Returning fast is not a fix.
cmp_run "tail big (~40 KB)"    "$F/big"
cmp_run "tail huge (~300 KB)"  "$F/huge"
cmp_run "tail -3 huge"         -3 "$F/huge"
cmp_run "tail -200 huge"       -200 "$F/huge"

note ""
note "== several FILEs (the ==> NAME <== banner)"
cmp_run "tail 3lines 20lines"          "$F/3lines" "$F/20lines"
# GNU refuses the obsolete `-N` form once there is more than one FILE
# ("option used in invalid context"), so for this one case the oracle is
# spelled `-n 2` while ours is `-2`. Same request, same expected bytes.
g="$(timeout "$TMO" tail -n 2 "$F/3lines" "$F/20lines" "$F/empty" </dev/null)"; grc=$?
o="$(timeout "$TMO" "$BIN/tail" -2 "$F/3lines" "$F/20lines" "$F/empty" </dev/null)"; orc=$?
if [ "$orc" = 124 ]; then bad "tail -2 over three FILEs: HUNG"
elif [ "$o" != "$g" ]; then
    bad "tail -2 over three FILEs: banner/output differs from GNU tail -n 2"
    printf '       gnu: %s\n' "$(printf '%s' "$g" | tr '\n' '|')"
    printf '       ours: %s\n' "$(printf '%s' "$o" | tr '\n' '|')"
elif [ "$orc" != "$grc" ]; then bad "tail -2 over three FILEs: exit $orc vs GNU $grc"
else ok "tail -2 over three FILEs: banners and lines match GNU tail -n 2"; fi

note ""
note "== stdin still works"
g="$(timeout "$TMO" bash -c "cat '$F/20lines' | tail")"
o="$(timeout "$TMO" bash -c "cat '$F/20lines' | '$BIN/tail'")"; rc=$?
if [ "$rc" = 124 ]; then bad "pipe: HUNG"
elif [ "$o" = "$g" ]; then ok "pipe: cat FILE | tail matches GNU tail"
else bad "pipe: output differs from GNU tail"; fi

g="$(timeout "$TMO" bash -c "cat '$F/huge' | tail -4")"
o="$(timeout "$TMO" bash -c "cat '$F/huge' | '$BIN/tail' -4")"; rc=$?
if [ "$rc" = 124 ]; then bad "pipe huge: HUNG"
elif [ "$o" = "$g" ]; then ok "pipe: 300 KB through a pipe matches GNU tail -4"
else bad "pipe huge: output differs from GNU tail"; fi

g="$(timeout "$TMO" bash -c "cat '$F/20lines' | tail -3 -")"
o="$(timeout "$TMO" bash -c "cat '$F/20lines' | '$BIN/tail' -3 -")"; rc=$?
if [ "$rc" = 124 ]; then bad "explicit '-' operand: HUNG"
elif [ "$o" = "$g" ]; then ok "explicit '-' operand reads stdin, matches GNU tail"
else bad "explicit '-' operand: output differs from GNU tail"; fi

note ""
note "== failure is by name, not by silence"
o="$(timeout "$TMO" "$BIN/tail" "$F/nonesuch" </dev/null 2>"$WORK/e.err")"; rc=$?
if [ "$rc" = 124 ]; then bad "missing file: HUNG"
elif [ "$rc" = 0 ]; then bad "missing file: exited 0"
elif ! grep -q "nonesuch" "$WORK/e.err"; then
    bad "missing file: exit $rc but the name is not in the message"
else ok "missing file: exit $rc and stderr names it"; fi

# One line bigger than the window. A complete answer is impossible, so
# what must NOT happen is a fragment printed as though it were a line.
o="$(timeout "$TMO" "$BIN/tail" -1 "$F/onehugeline" </dev/null 2>"$WORK/h.err")"; rc=$?
if [ "$rc" = 124 ]; then bad "line larger than the window: HUNG"
elif [ "$rc" = 0 ]; then bad "line larger than the window: exited 0 on a short answer"
elif [ -n "$o" ]; then bad "line larger than the window: printed a fragment as a line"
elif ! grep -qi "window" "$WORK/h.err"; then
    bad "line larger than the window: exit $rc but stderr does not say why"
else ok "line larger than the window: exit $rc, no fragment, stderr says why"; fi

# ---- head, the control ---------------------------------------------------
# head is the same shape of program and had the same bug; it was fixed
# when tests/linux/installed_update.sh found it. If head were broken too
# the diagnosis would be "neither ever grew a FILE operand"; it passing
# is what makes "tail alone was left behind" the finding.
note ""
note "== head, the control (already has the FILE operand)"
hcmp() {
    local label="$1"; shift
    local g o grc orc
    g="$(timeout "$TMO" head "$@" </dev/null 2>/dev/null)"; grc=$?
    o="$(timeout "$TMO" "$BIN/head" "$@" </dev/null 2>/dev/null)"; orc=$?
    if [ "$orc" = 124 ]; then bad "head $label: HUNG"
    elif [ "$o" != "$g" ]; then bad "head $label: output differs from GNU head"
    else ok "head $label: matches GNU head"; fi
}
hcmp "20lines"        "$F/20lines"
hcmp "-3 20lines"     -3 "$F/20lines"
hcmp "no-final-newline" "$F/no_final_nl"
hcmp "modules.dep"    "$F/modules.dep"

note ""
note "tail_file.sh: $pass PASS / $fail FAIL"
[ "$fail" = 0 ] || exit 1
exit 0
