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
# tests/linux/gate_read_demo.sh — SHOW THE DEFECT, THEN SHOW IT GONE.
#
# tests/linux/gate_read.sh claims that an empty read used to become a verdict.
# This file proves it, on de_focus_dismiss.sh, without a compositor and
# without a framebuffer.
#
# HOW IT AVOIDS BEING A TOY. The gate bodies are EXTRACTED MECHANICALLY from
# the real file with awk — the "before" from the last commit before the fix
# (7121d2d1, overridable with GRD_BASE) and the "after" from the working
# tree. Nothing in here is a hand-written imitation of the gate; if either
# block is edited in de_focus_dismiss.sh, this file runs the edited text. The
# ONLY thing stubbed is the reader: `wstate` and `winctl` return the empty
# string, which is exactly what wsys_poke gives when it cannot read
# /dev/wsys/wsysd/state or /dev/wsys/<wid>/ctl — the compositor gone, the
# binary missing, the file torn between its open and its write.
#
# AND IT RUNS A CONTROL, both times, because an empty result is not a finding
# until the instrument has been shown able to produce a non-empty one. Fed a
# real ctl line and a real state line, BOTH versions must PASS. If they do
# not, this demo is measuring itself and not the fix.
#
# No namespace, no reaping, no children: it runs three sub-shells of text.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"
BASE="${GRD_BASE:-7121d2d1}"
W="$(mktemp -d -p "${TMPDIR:-/tmp}" gatereaddemo.XXXXXX)"
trap 'rm -rf "$W"' EXIT
pass=0; fail=0
say()  { echo "gatedemo: $*"; }
good() { echo "gatedemo: PASS $*"; pass=$((pass+1)); }
nope() { echo "gatedemo: FAIL $*"; fail=$((fail+1)); }

git show "$BASE:tests/linux/de_focus_dismiss.sh" >"$W/before.txt" 2>/dev/null || {
    nope "cannot read de_focus_dismiss.sh at $BASE -- without the pre-fix text there is nothing to compare against"
    echo "gatedemo: $pass passed, $fail failed"; exit 1; }
cp tests/linux/de_focus_dismiss.sh "$W/after.txt"

# ---- the two blocks, lifted out of the real file --------------------------
# 8:  the focused wid, read from wsysd's own published state file.
# 9:  the panel's height after the wallpaper click -- the file's headline
#     claim, THE FIX it is named for.
cut8() { awk '/^focuswid\(\)/ { print; next }
               /^FOCUS_OPEN="\$\(focuswid\)"/ { b=1 }
               b { print } b && /^fi$/ { b=0 }' "$1"; }
cut9() { awk '/^snap away$/ { b=1 } b { print } b && /^fi$/ { exit }' "$1"; }

# ---- run one block with one stubbed reader --------------------------------
runblock() {   # runblock <block-file> <stub-line>
    {
        echo 'pass=0; fail=0'
        echo 'ok()   { echo "  focus: PASS $*"; pass=$((pass+1)); }'
        echo 'bad()  { echo "  focus: FAIL $*"; fail=$((fail+1)); }'
        echo 'info() { echo "  focus: INFO $*"; }'
        echo '. tests/linux/gate_read.sh 2>/dev/null || true'
        echo 'PANEL=3; PANELH=26'
        echo 'snap() { :; }'
        echo "$2"
        cat "$1"
    } >"$W/run.sh"
    bash "$W/run.sh" 2>&1
}

EMPTY_STATE='wstate() { :; }'                       # the read that fails
REAL_STATE='wstate() { echo "focus 3 windows 4 inputs 1"; }'
EMPTY_CTL='winctl() { :; }'
REAL_CTL='winctl() { echo "3 0 0 1280 26 0 0 1"; }'  # the dismissed bare bar

demo() {   # demo <name> <cutter> <empty-stub> <real-stub> <old-verdict-grep>
    local name="$1" cut="$2" es="$3" rs="$4" want="$5" out
    say "=== $name ==="
    "$cut" "$W/before.txt" >"$W/b.body"; "$cut" "$W/after.txt" >"$W/a.body"
    [ -s "$W/b.body" ] && [ -s "$W/a.body" ] || {
        nope "$name: could not extract the block from one of the two versions -- the anchors moved, and this demo is not looking at the gate"
        return; }

    say "--- BEFORE ($BASE), the read comes back empty:"
    out="$(runblock "$W/b.body" "$es")"; echo "$out"
    if echo "$out" | grep -q "$want"; then
        good "$name: the unfixed gate stated a defect it had not observed"
    else
        nope "$name: the unfixed gate did NOT produce the expected wrong verdict -- this demo has stopped demonstrating anything"
    fi

    say "--- AFTER (working tree), the same empty read:"
    out="$(runblock "$W/a.body" "$es")"; echo "$out"
    if echo "$out" | grep -q 'UNREADABLE'; then
        good "$name: the fixed gate names the read that failed instead"
    else
        nope "$name: the fixed gate did not say UNREADABLE"
    fi
    if echo "$out" | grep -q "$want"; then
        nope "$name: the fixed gate STILL prints the invented verdict"
    else
        good "$name: and it no longer prints the invented verdict"
    fi

    # THE CONTROL. Both versions, a read that works.
    say "--- CONTROL, a read that DOES come back (both versions must pass):"
    for v in b a; do
        out="$(runblock "$W/$v.body" "$rs")"; echo "$out"
        if echo "$out" | grep -q 'focus: PASS'; then
            good "$name: the $( [ $v = b ] && echo before || echo after ) version passes on a real read"
        else
            nope "$name: the $( [ $v = b ] && echo before || echo after ) version does NOT pass on a real read -- the stub is wrong, and every line above is about this file, not about the gate"
        fi
    done
}

demo "assertion 8, the focused wid"  cut8 "$EMPTY_STATE" "$REAL_STATE" \
     'focus on wid none'
demo "assertion 9, the panel height" cut9 "$EMPTY_CTL"   "$REAL_CTL" \
     'still 0 px tall'

echo "gatedemo: $pass passed, $fail failed"
[ "$fail" = 0 ]
