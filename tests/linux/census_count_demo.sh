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
# tests/linux/census_count_demo.sh — SHOW THE CENSUS SKIPPING ITS OWN FINDING,
# THEN SHOW IT REPORTING IT.
#
# THE DEFECT.  `grep -c PAT file` PRINTS THE COUNT AND EXITS 1 when the count
# is zero.  So `X=$(grep -c PAT f || echo 0)` does not give "0"; it gives the
# TWO-LINE STRING "0\n0", because grep printed its own 0 first and the `||`
# then fired anyway.  `[ "$X" -le 0 ]` on that is not false — it is
# `[: integer expression expected`, rc=2 — and `if` skips a branch whose
# condition ERRORED.  The check does not fail; it does not run.
#
# In scripts/test_leak_hours_census.sh that landed on the worst possible
# branch: the "mapped NO window in 30s" finding, which fires when a launch
# maps zero windows — i.e. exactly when the count is zero — i.e. exactly the
# input that produces "0\n0".  A leak census that cannot report the leak.
#
# `|| true` is NOT the same bug and is not touched anywhere in this tree: it
# prints nothing, so the value is grep's own clean "0".  ONLY `|| echo N`
# appends the second line.
#
# HOW THIS AVOIDS BEING A TOY.  Both versions of the code are EXTRACTED
# MECHANICALLY with awk from the real script — the "before" from the last
# commit before the fix (164098f5, overridable with CCD_BASE) and the "after"
# from the working tree.  Nothing here is a hand-written imitation; edit
# test_leak_hours_census.sh and this file runs the edited text.  The ONLY
# things stubbed are the guest and the clock: `printf ... >&3` goes to a file
# instead of a QEMU serial fifo, and `sleep` advances bash's own SECONDS
# instead of waiting, so the 30 s launch window elapses instantly.
#
# AND IT RUNS A CONTROL, on both versions, because a "finding reported" result
# is worthless until the instrument has been shown able to STAY QUIET when the
# window really does appear.  Scenario B feeds a log in which the mapped count
# genuinely increases; BOTH versions must report nothing.  If the fixed
# version cries wolf there, this demo is measuring itself and not the fix.
#
# No guest, no compositor, no framebuffer, no children to reap: three
# sub-shells of text.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"
BASE="${CCD_BASE:-164098f5}"
SRC=scripts/test_leak_hours_census.sh
W="$(mktemp -d -p "${TMPDIR:-/tmp}" censuscountdemo.XXXXXX)"
trap 'rm -rf "$W"' EXIT
pass=0; fail=0
say()  { echo "censusdemo: $*"; }
good() { echo "censusdemo: PASS $*"; pass=$((pass+1)); }
nope() { echo "censusdemo: FAIL $*"; fail=$((fail+1)); }

git show "$BASE:$SRC" >"$W/before.txt" 2>/dev/null || {
    nope "cannot read $SRC at $BASE -- without the pre-fix text there is nothing to compare against"
    echo "censusdemo: $pass passed, $fail failed"; exit 1; }
cp "$SRC" "$W/after.txt"

# ---- the two blocks, lifted out of the real file --------------------------
# (1) mapped_count itself. Before the fix it is a one-liner ending in "; }";
#     after it is a multi-line function preceded by MAPPED_UNREADABLE=. One
#     awk handles both: start at whichever anchor appears, stop at the closing
#     brace (same line for the one-liner, a bare "}" for the function).
cut_fn() { awk '
    /^MAPPED_UNREADABLE=/ { b=1 }
    /^mapped_count\(\)/   { b=1 }
    b { print }
    b && /^mapped_count\(\).*; \}$/ { exit }
    b && /^\}$/ { exit }' "$1"; }
# (2) the launch-and-check block: from `before=$(mapped_count)` down to the
#     `fi` that closes the no-window finding.
cut_blk() { awk '
    /^        before=\$\(mapped_count\)$/ { b=1 }
    b { print }
    b && /^        fi$/ { exit }' "$1"; }

# ---- run one version against one log fixture ------------------------------
# Emits the block'"'"'s own stderr/stdout, then a RESULT line naming the two
# things that matter: whether the finding fired, and whether the log was
# declared unreadable.
runver() {   # runver <src-file> <logsetup-line> <out-prefix>
    local src="$1" logsetup="$2" pre="$3"
    {
        echo 'set -uo pipefail'
        echo "OUT_DIR='$W/out'; mkdir -p \"\$OUT_DIR\"; rm -f \"\$OUT_DIR\"/mapped_count_unreadable"
        echo "LOG='$W/serial.log'"
        echo "TAG='$pre'"
        # The guest side of the fifo: the block writes the launch command to
        # &3. Point &3 at a file and, each time the clock advances, append
        # whatever the fixture says the guest logged.
        echo "exec 3>'$W/guest.in'"
        echo "$logsetup"
        # Stub the clock, not the code: SECONDS is assignable in bash, so the
        # 30 s window elapses in three iterations with no real waiting. This
        # is also where the fixture gets to make the log grow.
        echo 'sleep() { SECONDS=$(( SECONDS + 10 )); guest_tick; }'
        echo 'guest_tick() { :; }; type fixture_tick >/dev/null 2>&1 && guest_tick() { fixture_tick; }'
        echo 'QEMU_PID=$$'
        echo 'gl_cycles=1; gl_launched=0; gl_nowindow=0; gl_pool_i=0; n=0'
        echo 'GAP_LOAD_PER_CYCLE=1; app=hamwrite'
        cut_fn "$src"
        echo 'demo_one() {'
        echo '  local before line pid'
        echo '  for _once in 1; do'
        cut_blk "$src"
        echo '  done'
        echo '}'
        echo 'demo_one'
        echo 'unread=no; [ -e "$OUT_DIR/mapped_count_unreadable" ] && unread=yes'
        echo 'echo "RESULT nowindow=$gl_nowindow unreadable=$unread"'
    } >"$W/run.sh"
    bash "$W/run.sh" 2>&1
}

# The fixture hook: redefined per scenario by exporting FIXTURE_TICK text.
scenario() {   # scenario <name> <logsetup>
    local name="$1" setup="$2" b a
    say ""
    say "===== $name ====="
    b="$(runver "$W/before.txt" "$setup" "  before>")"
    a="$(runver "$W/after.txt"  "$setup" "  after>")"
    printf '%s\n' "$b" | sed 's/^/    BEFORE | /'
    printf '%s\n' "$a" | sed 's/^/    AFTER  | /'
    B_RES="$(printf '%s\n' "$b" | grep '^RESULT ' | tail -1)"
    A_RES="$(printf '%s\n' "$a" | grep '^RESULT ' | tail -1)"
}

# ---------------------------------------------------------------------------
# A. THE REAL CASE: the log exists and NO window is ever mapped. This is the
#    silent cap the finding was written for.
# ---------------------------------------------------------------------------
scenario "A. log readable, launch maps NO window (the silent-cap case)" \
    ": > \"\$LOG\"; echo '[boot] unrelated line' >> \"\$LOG\""
if [ "$B_RES" = "RESULT nowindow=0 unreadable=no" ]; then
    good "A/before: the finding was SKIPPED -- nowindow=0 with zero windows mapped. rc=2 from \`[\` is not false, it is an error, and \`if\` skipped the branch. THIS IS THE DEFECT."
else
    nope "A/before: expected the pre-fix block to skip its finding (nowindow=0); got '$B_RES'. Either \$CCD_BASE is wrong or the defect is not where this demo thinks it is."
fi
if [ "$A_RES" = "RESULT nowindow=1 unreadable=no" ]; then
    good "A/after: the finding FIRED -- nowindow=1. The census can now report the case it was written for."
else
    nope "A/after: expected nowindow=1 unreadable=no; got '$A_RES'"
fi

# ---------------------------------------------------------------------------
# B. THE CONTROL: a window really is mapped during the wait. Neither version
#    may report a finding. Without this, "the fixed one reports it" would be
#    indistinguishable from "the fixed one always reports it".
# ---------------------------------------------------------------------------
scenario "B. CONTROL: a window IS mapped during the wait (no finding is correct)" \
    ": > \"\$LOG\"; echo '[devwsys] window 1 mapped pid=100' >> \"\$LOG\"; fixture_tick() { echo '[devwsys] window 2 mapped pid=101' >> \"\$LOG\"; }"
if [ "$B_RES" = "RESULT nowindow=0 unreadable=no" ] && [ "$A_RES" = "RESULT nowindow=0 unreadable=no" ]; then
    good "B/control: BOTH versions stayed quiet when the window appeared. The fixed version is not simply always-firing, so A/after is a real result."
else
    nope "B/control: both versions must report nowindow=0 here; before='$B_RES' after='$A_RES'. This demo cannot be trusted until that holds."
fi

# ---------------------------------------------------------------------------
# C. THE GAP: the log cannot be read at all. "grep found nothing" and "the
#    census could not read its input" are DIFFERENT SITUATIONS, and the second
#    must never be answered with a success-shaped zero.
#
#    A CORRECTION THIS DEMO MADE TO ITS OWN AUTHOR. I expected the pre-fix
#    block to report nowindow=0 here too, and wrote the assertion that way.
#    It does not: with the log MISSING, grep exits 2 and prints NOTHING, so
#    `|| echo 0` yields a clean single-line "0", the comparison works, and the
#    finding fires. The pre-fix defect is therefore narrower than "zero counts
#    are broken" -- it needs a log that EXISTS and does not match. What the
#    pre-fix code gets wrong here is not the count but the ATTRIBUTION: it
#    blames the guest ("hamwrite mapped NO window in 30s") for what is really
#    the census failing to read its own input. The assertion below now checks
#    the thing that actually differs.
# ---------------------------------------------------------------------------
scenario "C. the serial log does not exist (a gap, not a measurement)" \
    "rm -f \"\$LOG\""
if [ "$B_RES" = "RESULT nowindow=1 unreadable=no" ]; then
    good "C/before: the pre-fix block blamed the GUEST -- 'hamwrite mapped NO window' -- for a log it could not read. Right count, wrong story, and nothing in the verdict says the input was missing."
else
    say "C/before: got '$B_RES' (pre-fix behaviour on a missing log)"
fi
case "$A_RES" in
    "RESULT nowindow=1 unreadable=yes")
        good "C/after: the missing log is declared UNREADABLE and the launch is counted loudly, so the run's verdict says so instead of reporting zero leaks." ;;
    *)
        nope "C/after: expected 'RESULT nowindow=1 unreadable=yes'; got '$A_RES'" ;;
esac

# ---------------------------------------------------------------------------
# D. scripts/test_usb_hid_v2.sh:165 -- the claim that it is RIGHT BY ACCIDENT.
#    Same bug, but the errored `if` happens to skip the OK branch and land on
#    MISS, which is the correct verdict for zero loads. Shown here with the
#    real comparison, and with the operator inverted to show how thin the luck
#    is. Extracted mechanically from the pre-fix file.
# ---------------------------------------------------------------------------
say ""
say "===== D. test_usb_hid_v2.sh:165 -- verifying the 'right by accident' claim ====="
git show "$BASE:scripts/test_usb_hid_v2.sh" >"$W/hid_before.txt" 2>/dev/null || {
    nope "D: cannot read test_usb_hid_v2.sh at $BASE"; }
if [ -s "$W/hid_before.txt" ]; then
    {
        echo 'set -uo pipefail'
        echo "LOG='$W/hid.log'"; echo ': > "$LOG"'
        echo 'fail=0'
        awk '/^n_md_loads=\$\(grep -cE/ { b=1 } b { print } b && /^fi$/ { exit }' "$W/hid_before.txt"
        echo 'printf "n_md_loads=%q verdict_fail=%s\n" "$n_md_loads" "$fail"'
        # The counterfactual: same broken value, operator inverted.
        echo 'if [ "$n_md_loads" -lt 5 ]; then echo "COUNTERFACTUAL(-lt): MISS (right)"; else echo "COUNTERFACTUAL(-lt): OK (WRONG -- zero loads reported as success)"; fi'
    } >"$W/hid.sh"
    hidout="$(bash "$W/hid.sh" 2>&1)"
    printf '%s\n' "$hidout" | sed 's/^/    HID    | /'
    if printf '%s\n' "$hidout" | grep -q 'verdict_fail=1'; then
        good "D: CONFIRMED -- with zero loads the pre-fix code still set fail=1. The verdict is right; the reasoning is not: \`[\` errored (rc=2), \`if\` skipped the OK branch, and the else happened to be the correct answer."
    else
        nope "D: the 'right by accident' claim does not hold -- pre-fix code did not set fail=1 on zero loads"
    fi
    if printf '%s\n' "$hidout" | grep -q 'COUNTERFACTUAL(-lt): OK (WRONG'; then
        good "D: and the luck is one token deep -- rewritten as \`-lt 5\` with the branches swapped, the SAME value reports OK on zero loads."
    else
        nope "D: the -lt counterfactual did not invert as expected"
    fi
fi

say ""
echo "censusdemo: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
