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
# tests/linux/gate_read_demo_rest.sh — SHOW THE DEFECT, THEN SHOW IT GONE, for
# the four gates the first audit pass left unfixed.
#
# tests/linux/gate_read_demo.sh does this for de_focus_dismiss.sh, the file the
# ${VAR:-0} shape was found in. This is its sibling for the REMAINDER: the
# sites that invent a FAIL rather than a PASS, plus the one that is a different
# bug entirely (a `sed` with no -n and no /p, which ECHOES THE WHOLE LINE on a
# miss instead of returning nothing).
#
# HOW IT AVOIDS BEING A TOY, and it is the same discipline as its sibling: the
# gate bodies are EXTRACTED MECHANICALLY with awk from the real files -- the
# "before" from git at $GRD_BASE (the commit before this branch, overridable),
# the "after" from the working tree. Nothing here is a hand-written imitation.
# If a block is edited in its own file, this demo runs the edited text; if the
# anchors move, it says so and fails rather than quietly measuring nothing.
# The ONLY things stubbed are the READERS -- st(), the probe binary, the state
# file, the counter's own output stream -- and each is stubbed to return
# exactly what the real thing returns when it cannot report: nothing.
#
# AND EVERY CASE RUNS A CONTROL. An empty result is not a finding until the
# instrument has been shown able to produce a non-empty one -- that is the rule
# this whole audit is about, so the demo obeys it too. Fed a real reading, BOTH
# versions must PASS. If they do not, the demo is measuring itself.
#
# No namespace, no children, no compositor, no framebuffer: sub-shells of text.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"
BASE="${GRD_BASE:-1b36f360}"
W="$(mktemp -d -p "${TMPDIR:-/tmp}" gatereadrest.XXXXXX)"
trap 'rm -rf "$W"' EXIT
pass=0; fail=0
say()  { echo "restdemo: $*"; }
good() { echo "restdemo: PASS $*"; pass=$((pass+1)); }
nope() { echo "restdemo: FAIL $*"; fail=$((fail+1)); }

# ---- mechanical extraction -------------------------------------------------
# cutrange <file> <start-regex> <stop-regex> — the lines from the first line
# matching <start> up to but NOT including the next line matching <stop>. Both
# anchors are chosen to be text that is IDENTICAL in the before and after
# versions, so the same call lifts the corresponding block out of each.
cutrange() {
    awk -v s="$2" -v e="$3" '
        !b && $0 ~ s { b=1 }
        b && $0 ~ e  { exit }
        b            { print }' "$1"
}

# runblock <block-file> <prelude> — run one extracted block with stubbed
# readers and this project's usual ok/bad/info helpers.
runblock() {
    {
        echo 'set -uo pipefail'
        echo 'pass=0; fail=0'
        echo 'ok()   { echo "   PASS $*"; pass=$((pass+1)); }'
        echo 'bad()  { echo "   FAIL $*"; fail=$((fail+1)); }'
        echo 'info() { echo "   INFO $*"; }'
        echo 'PASS=0; FAIL=0'      # http9_response_cap.sh spells them upper-case
        echo '. tests/linux/gate_read.sh 2>/dev/null || true'
        echo "$2"
        cat "$1"
        echo 'echo "   ---- block finished: $pass ok, $fail bad, $PASS OK, $FAIL BAD"'
    } >"$W/run.sh"
    ( cd "$PROJ_ROOT" && bash "$W/run.sh" 2>&1 )
}

# demo <name> <file> <start-re> <stop-re> <empty-prelude> <real-prelude> <wrong-verdict-re>
demo() {
    local name="$1" file="$2" s="$3" e="$4" ep="$5" rp="$6" want="$7" out v
    say ""
    say "=========================================================="
    say "=== $name"
    say "===   $file"
    say "=========================================================="
    git show "$BASE:$file" >"$W/before.txt" 2>/dev/null || {
        nope "$name: cannot read $file at $BASE -- without the pre-fix text there is nothing to compare against"; return; }
    cp "$file" "$W/after.txt"
    cutrange "$W/before.txt" "$s" "$e" >"$W/b.body"
    cutrange "$W/after.txt"  "$s" "$e" >"$W/a.body"
    [ -s "$W/b.body" ] && [ -s "$W/a.body" ] || {
        nope "$name: could not extract the block from one of the two versions -- the anchors moved, and this demo is NOT looking at the gate"; return; }

    say "--- BEFORE ($BASE), the read comes back empty:"
    out="$(runblock "$W/b.body" "$ep")"; echo "$out"
    if echo "$out" | grep -qE "$want"; then
        good "$name: the unfixed gate stated a defect it had not observed"
    else
        nope "$name: the unfixed gate did NOT produce the expected wrong verdict -- this demo has stopped demonstrating anything"
    fi

    say "--- AFTER (working tree), the same empty read:"
    out="$(runblock "$W/a.body" "$ep")"; echo "$out"
    if echo "$out" | grep -q 'UNREADABLE'; then
        good "$name: the fixed gate names the read that failed instead"
    else
        nope "$name: the fixed gate did not say UNREADABLE"
    fi
    if echo "$out" | grep -qE "$want"; then
        nope "$name: the fixed gate STILL states the invented verdict"
    else
        good "$name: and it no longer states the invented verdict"
    fi

    say "--- CONTROL, a read that DOES come back (both versions must pass):"
    for v in b a; do
        out="$(runblock "$W/$v.body" "$rp")"; echo "$out"
        if echo "$out" | grep -qE '(PASS|OK) '; then
            good "$name: the $( [ "$v" = b ] && echo before || echo after ) version passes on a real read"
        else
            nope "$name: the $( [ "$v" = b ] && echo before || echo after ) version does NOT pass on a real read -- the stub is wrong, and every line above is about this demo, not about the gate"
        fi
    done
}

# ===========================================================================
# 1. opcount_selftest.sh -- the counter's own self-test, which is the one file
#    in the tree that MUST NOT reach a verdict it did not read. A drag.opc that
#    is non-empty but carries no `opcount:` line is a counter that did not
#    report; the gate called it "under-reporting", which is a statement about
#    the counter, in the flattering-for-nobody direction.
# ===========================================================================
mkdir -p "$W/opc"
OPC_EMPTY='W='"$W"'/opc; printf "de_dragload: scene committed\nnoise\n" >$W/drag.opc'
OPC_REAL='W='"$W"'/opc; printf "opcount: 4000 ops/s\nopcount: wid/ctl open 4345 write 4344\n" >$W/drag.opc'
demo "1a. opcount, the peak rate" tests/linux/opcount_selftest.sh \
     '^PEAK=' '^# 2[.] SELF-CONSISTENCY' \
     "$OPC_EMPTY" "$OPC_REAL" \
     'the counter is under-reporting'
demo "1b. opcount, opens vs writes" tests/linux/opcount_selftest.sh \
     '^LAST=' '^# 3[.] IT MUST BE SILENT' \
     "$OPC_EMPTY" "$OPC_REAL" \
     'wid/ctl opens \(\) != writes \(\)'

# ===========================================================================
# 2. wsyswl_shared_fate.sh -- THE HEADLINE CLAIM OF THE FILE. st() seds a state
#    file whose existence nothing ever proved (the startup guard checks the
#    SOCKET), and an unwritten state file was reported as the Steam bug itself.
# ===========================================================================
printf 'a frame\n' >"$W/fb.raw"
SF_STUBS='xdotool(){ :; }; xwininfo(){ :; }; VIC=1; before=x; HAMFB_FILE='"$W"'/fb.raw'
SF_EMPTY="$SF_STUBS"'; STATE='"$W"'/nostate; st(){ :; }'
# A control that has to survive command substitution, so the counter lives in a
# file rather than a variable: 100 the first time it is asked, 200 the second.
SF_REAL="$SF_STUBS"'; STATE='"$W"'/state; echo 100 >'"$W"'/n; st(){ local v; v="$(cat '"$W"'/n)"; echo 200 >'"$W"'/n; echo "$v"; }'
demo "2. shared_fate, 'that is the Steam symptom'" tests/linux/wsyswl_shared_fate.sh \
     '^COMMITS_BEFORE=' '^MAPFAIL=' \
     "$SF_EMPTY" "$SF_REAL" \
     'THE PROPERTY FAILED'

# ===========================================================================
# 3. wsyswl_two_browsers.sh -- the MAXCONN=16 control. The gate waits for the
#    SOCKET and then reads the STATE FILE, which wsyswl writes only when its
#    stats go dirty; a server with no clients yet may not have written it at
#    all, and "does not report MAXCONN=16" was said about a build whose state
#    file had not arrived.
# ===========================================================================
printf 'limits shared MAXCONN=16 MAXWIN=64 FCMAX=32 MAXMAP_BUILT=64\n' >"$W/tb-state"
demo "3. two_browsers, the MAXCONN=16 control" tests/linux/wsyswl_two_browsers.sh \
     '^export XDG_RUNTIME_DIR="[$]W2"' '^# THE SAME WORKLOAD' \
     'W2='"$W"'; STATE='"$W"'/tb-nostate; TWOBR_MAXCONN_WAIT=2' \
     'W2='"$W"'; STATE='"$W"'/tb-state; TWOBR_MAXCONN_WAIT=2' \
     'does not report MAXCONN=16'

# ===========================================================================
# 4. http9_response_cap.sh -- A DIFFERENT BUG, and the most interesting of the
#    four. `sed 's/.*RAW=\([0-9]*\).*/\1/'` has no -n and no /p, so ON A MISS
#    IT PRINTS THE WHOLE LINE. The probe's error text therefore became the
#    "value" of HDRLEN, BODYLEN and RAW at once. Three outcomes, all wrong, and
#    the demo shows all three:
#      empty output -> an invented FAIL against http_prepend_head;
#      "RC=-6 STATUS=200" -> `$(( ))` syntax error, the loop body ABORTS, and
#         SIX ASSERTIONS SILENTLY DO NOT RUN while the file still reports 0
#         failures -- a verdict that is not a verdict;
#      "connection refused" -> `$(( ))` reads the words as variables and
#         `set -u` KILLS THE GATE mid-run.
# ===========================================================================
# h9probe <tag> <output-text> -> a prelude installing a probe that prints
# <output-text>. THE TAG IS NOT DECORATION: the first version of this demo
# wrote every stub to one filename, both preludes were expanded before either
# ran, and THE CONTROL'S TEXT OVERWROTE THE EMPTY ONE -- so the "empty read"
# case was quietly fed a real reading and the demo reported that the unfixed
# gate had stopped misbehaving. Caught by the demo's own self-check, which is
# what it is for. One file per case.
h9probe() {
    printf '%s\n' "$2" >"$W/probe.$1.body"
    printf '#!/bin/sh\ncat %s/probe.%s.body\n' "$W" "$1" >"$W/probe.$1.sh"
    chmod +x "$W/probe.$1.sh"
    echo 'PROBE='"$W"'/probe.'"$1"'.sh; U=http://x; expect(){ case "$2" in *"$3"*) ok "$1";; *) bad "$1";; esac; }'
}
H9_REAL_TEXT='RC=0 STATUS=200 HDRLEN=129 BODYLEN=100000 RAW=100129 RAW0=HTTP/1.1 200 OK TAILMATCH=1'

demo "4a. http9, the probe reports NOTHING" tests/linux/http9_response_cap.sh \
     '^for pair in' '^# ---- what a USER sees' \
     "$(h9probe empty '')" "$(h9probe real "$H9_REAL_TEXT")" \
     'RAW= *!='

# 4b and 4c are not run through demo(): their "before" behaviour is not a wrong
# SENTENCE, it is a wrong CONTROL FLOW -- assertions that vanish, and a shell
# that dies. So they are asserted directly, on the same mechanically extracted
# blocks.
say ""
say "=========================================================="
say "=== 4b/4c. http9, the whole-line echo -- assertions that VANISH, and a"
say "===        gate that DIES, neither of which is a sentence to grep for"
say "=========================================================="
git show "$BASE:tests/linux/http9_response_cap.sh" >"$W/h9before.txt" 2>/dev/null
cutrange "$W/h9before.txt" '^for pair in' '^# ---- what a USER sees' >"$W/h9b.body"
cutrange tests/linux/http9_response_cap.sh '^for pair in' '^# ---- what a USER sees' >"$W/h9a.body"
if [ -s "$W/h9b.body" ] && [ -s "$W/h9a.body" ]; then
    for probetext in 'RC=-6 STATUS=200' 'connection refused'; do
        say "--- probe says: '$probetext'"
        say "  BEFORE ($BASE):"
        outb="$(runblock "$W/h9b.body" "$(h9probe partial "$probetext")")"; echo "$outb"
        say "  AFTER (working tree):"
        outa="$(runblock "$W/h9a.body" "$(h9probe partial "$probetext")")"; echo "$outa"
        # The before version either never finishes the block (set -u kills the
        # shell) or finishes it having asserted NOTHING.
        if ! echo "$outb" | grep -q 'block finished'; then
            good "http9 '$probetext': the unfixed gate was KILLED mid-run by set -u on a word out of the probe's error text"
        elif echo "$outb" | grep -q 'block finished: 0 ok, 0 bad, 0 OK, 0 BAD'; then
            good "http9 '$probetext': the unfixed gate ran SIX assertions and recorded NONE of them -- 0 passed and 0 failed, which any caller reads as clean"
        else
            nope "http9 '$probetext': the unfixed gate did not vanish or die as measured -- this demo has stopped demonstrating anything"
        fi
        if echo "$outa" | grep -q 'UNREADABLE' && echo "$outa" | grep -q 'block finished'; then
            good "http9 '$probetext': the fixed gate finishes, and names the read that failed"
        else
            nope "http9 '$probetext': the fixed gate did not both finish and say UNREADABLE"
        fi
    done
    say "--- CONTROL for 4b/4c: a probe that DOES report (both versions must pass):"
    for v in b a; do
        out="$(runblock "$W/h9$v.body" "$(h9probe real "$H9_REAL_TEXT")")"; echo "$out"
        if echo "$out" | grep -q 'PASS '; then
            good "http9: the $( [ "$v" = b ] && echo before || echo after ) version passes on a real read"
        else
            nope "http9: the $( [ "$v" = b ] && echo before || echo after ) version does NOT pass on a real read"
        fi
    done
else
    nope "http9 4b/4c: could not extract the block -- the anchors moved"
fi

say ""
echo "restdemo: $pass passed, $fail failed"
[ "$fail" = 0 ]
