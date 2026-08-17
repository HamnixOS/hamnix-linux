#!/usr/bin/env bash
# tests/linux/soak_wincensus_negctl.sh -- THE NEGATIVE CONTROL FOR THE WINDOW-
# TABLE CENSUS IN tests/linux/soak_desktop.sh, RUN INSTEAD OF DESCRIBED.
#
# WHY THIS FILE EXISTS
# ====================
# soak_desktop.sh's window verdict is 900 seconds of QEMU away. Nobody is going
# to re-run it to find out whether a change to the READER still distinguishes
# its four answers, and a reader that has silently stopped discriminating is
# this project's most-repeated failure: a check that cannot fail is not a check.
#
# So the verdict block is lifted OUT of soak_desktop.sh by this file -- verbatim,
# by marker, from the gate itself, never a copy that can drift -- and driven
# with synthetic serial logs whose right answer is known by construction. It
# needs no QEMU, no image, no network and no device, and it takes under a
# second.
#
# WHAT IT ASSERTS, AND WHY EACH ONE IS A DIFFERENT FAILURE
# =======================================================
#   1. both counts flat                 -> NEITHER      (the green case)
#   2. wsysd's state climbs, table flat -> HARNESS       (the count is not the
#                                                         window table)
#   3. both climb                       -> REAL LEAK     (rows are held)
#   4. no census sections at all        -> PRODUCED NOTHING -- the run did not
#      answer the question, which must NEVER read as "the counts agreed".
#      "Nothing bad happened" and "nothing happened" are different verdicts.
#   5. both climb AND ps shows one live app process per window
#                                       -> WINDOWS TRACK THE PROCESSES, and
#      the leak verdict must STILL be printed alongside it: the two are not
#      alternatives, they are a finding and its cause.
#   6. both climb with NO ps lines      -> the process correlation must say
#      NOT MEASURED. This one was RED when it was first written on 2026-08-17:
#      the block printed "live application processes: 0 -> 0" and an offset
#      that was just the window count with a different label. An empty
#      instrument was reporting a finding. Fixed in soak_desktop.sh; this
#      assertion is what keeps it fixed.
#
# THE CONTROL ON THE CONTROL: it refuses to run if the lifted block is empty or
# does not contain the verdict string, so a rename in soak_desktop.sh that made
# the marker stop matching fails LOUDLY here instead of passing 0 assertions.
#
# Exit 0 = PASS, 1 = FAIL.
set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"
GATE="tests/linux/soak_desktop.sh"
[ -f "$GATE" ] || { echo "wcnc: FAIL no $GATE"; exit 1; }

S=$(mktemp -d "${TMPDIR:-/tmp}/wcnc.XXXXXX")
trap 'rm -rf "$S"' EXIT

sed -n '/^say "COMPOSITOR OR HARNESS/,/^fi$/p' "$GATE" >"$S/block.sh"
[ -s "$S/block.sh" ] || {
    echo "wcnc: FAIL the COMPOSITOR OR HARNESS block could not be lifted out of $GATE -- the marker moved. This gate asserted NOTHING."; exit 1; }
for tok in 'REAL LEAK' 'HARNESS' 'PRODUCED NOTHING' 'NEITHER'; do
    grep -q "$tok" "$S/block.sh" || {
        echo "wcnc: FAIL the lifted block does not contain the verdict '$tok' -- it is not the block this gate tests."; exit 1; }
done

mklog() {   # mklog <out> <n> <state0> <step> <dir0> <dirstep> <wcen 0|1> [ps 0|1]
    local out=$1 n=$2 s0=$3 ss=$4 d0=$5 ds=$6 wc=$7 ps=${8:-0} i j
    : >"$out"
    for ((i = 0; i < n; i++)); do
        printf 'focus 7 windows %d inputs 3 keys 9 pointer 4 frames 55 curframes 12\n' \
            $((s0 + i * ss)) >>"$out"
        # A DECOY the whole-console reader used to swallow: a tailed log line
        # with the word `windows` followed by a number that is a BYTE COUNT.
        printf 'wsysd.log: reaped 2 windows 4096 bytes\n' >>"$out"
        if [ "$wc" = 1 ]; then
            echo 'SOAKWINCEN dir' >>"$out"
            printf 'ctl\nself\nwindows\nscreen\npool\n' >>"$out"
            for ((j = 0; j < d0 + i * ds; j++)); do echo $((j + 2)) >>"$out"; done
            echo 'SOAKWINCEN taskbar' >>"$out"
            for ((j = 0; j < d0 + i * ds; j++)); do echo "$((j + 2)) a window" >>"$out"; done
            echo 'SOAKWINCEN end' >>"$out"
        fi
        if [ "$ps" = 1 ]; then
            for ((j = 0; j < s0 + i * ss - 3; j++)); do
                echo "$((1000 + j)) hamcalcscene" >>"$out"
            done
        fi
    done
}

PASSES=0
FAILURES=0
run() {   # run <label> <logfile> <expected token>
    local label=$1 log=$2 want=$3 out
    mkdir -p "$S/soak"; cp "$log" "$S/soak/serial.log"
    out=$(
        WORK="$S" WCEN=SOAKWINCEN SECS=900
        SOAK_APPS="hamcalcscene hamnotesscene hammonscene hamtermscene"
        HAMLINUX_SOAK_CLOSE=0
        say()  { echo "== $*"; }
        info() { echo "-- $*"; }
        ok()   { echo "OK $*"; }
        bad()  { echo "BAD $*"; }
        . "$S/block.sh"
    ) 2>&1
    if printf '%s' "$out" | grep -q "$want"; then
        echo "wcnc: PASS  $label -> $want"
        PASSES=$((PASSES + 1))
    else
        echo "wcnc: FAIL  $label: expected '$want' and it is not there:"
        printf '%s\n' "$out" | sed 's/^/  ..  /'
        FAILURES=$((FAILURES + 1))
    fi
}

mklog "$S/flat.log" 12 3 0 3 0 1
run "both counts flat"                    "$S/flat.log" 'NEITHER'
mklog "$S/harn.log" 12 3 8 3 0 1
run "state climbs, table flat"            "$S/harn.log" 'HARNESS'
mklog "$S/leak.log" 12 3 8 3 8 1
run "both climb"                          "$S/leak.log" 'REAL LEAK'
mklog "$S/none.log" 12 3 8 3 8 0
run "no census sections at all"           "$S/none.log" 'PRODUCED NOTHING'
mklog "$S/proc.log" 12 3 8 3 8 1 1
run "both climb, ps shows live owners"    "$S/proc.log" 'WINDOWS TRACK THE PROCESSES'
run "...and the leak is still called"     "$S/proc.log" 'REAL LEAK'
run "both climb, no ps lines"             "$S/leak.log" 'NOT MEASURED'

echo "wcnc: $PASSES passed, $FAILURES failed"
[ "$FAILURES" -eq 0 ] || exit 1
exit 0
