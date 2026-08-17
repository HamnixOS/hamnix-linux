#!/usr/bin/env bash
# scripts/test_hamsh_loop_arena_host.sh — THE COLLECTOR MUST RUN INSIDE A LOOP.
# QEMU-free host gate.
#
# WHAT THIS IS FOR
# ================
# hamsh's mark/compact collector was reachable from exactly one place:
# run_source, at `_rs_depth == 1` — i.e. BETWEEN complete top-level inputs. A
# script whose body is one `while 1 == 1 { ... }` never returns there, so the
# collector NEVER RAN for the life of that loop and every temporary the body
# allocated was stranded until v_new hit VAL_MAX and raised:
#
#     hamsh: runtime error: value arena exhausted (VAL_MAX=16384 live cells)
#            — split the loop
#
# MEASURED, on the host build, before the fix: `while i < 5000 { s = s + i ;
# i = i + 1 }` — two integers, nothing live but two integers — died at
# ITERATION 2048 and printed a plausible partial sum. docs/HAMSH_SPEC.md
# called this by design ("Long-running work belongs in Adder") and
# scripts/test_hamsh_nosilentwrong_host.sh case 2f REQUIRED it to happen.
#
# WHAT IT COST, and this is why the gate is worth its two minutes.
# tests/linux/soak_desktop.sh's rc is a single infinite `while`. Three runs
# out of three stopped their workload at the same LAUNCH COUNT (44 launches
# at DWELL=8, 48 at DWELL=4 — counted in statements executed, not in seconds,
# which is exactly the shape of an arena filling up). The gate reported a
# WEDGE OF UNKNOWN CAUSE for three runs; sysrq-w named no blocked task and
# PID 1 sat in do_sys_poll. Both preserved serial logs
# (/home/david/.hamnix-build/soak-evidence/) end the workload with the two
# lines above, followed by `[hamsh:stage-07] loop-enter` and `hamsh$` — PID 1
# falling out of the rc into its interactive prompt. Kernel alive, userspace
# dead. It was never a kernel wedge; it was the shell running out of cells.
#
# WHAT IS ASSERTED
#   1. A 60000-iteration `while` loop COMPLETES and its answer is EXACT.
#   2. Occupancy is BOUNDED while it does — collections actually run inside
#      the loop (gc count climbs) and `vals` ends far below VAL_MAX.
#   3. EVERY CONSTRUCT THAT CARRIES A VALUE-CELL ID ACROSS A STATEMENT
#      BOUNDARY still computes the right answer with collections firing in
#      the middle of it: the three `for` forms (word list, expression list,
#      bare set variable), try/except/finally, a user function called in a
#      loop, and list/dict/string bindings made BEFORE the loop and read
#      AFTER it. This is the assertion that guards the pin stack — the minor
#      collector SLIDES VALUE CELLS, so an evaluator local holding a stale
#      cell id is a SILENT WRONG ANSWER, not a crash.
#
# THE NEGATIVE CONTROLS ARE RUN, NOT DESCRIBED
# ============================================
# Two mutant builds of the shell, compiled from a sed'd copy of
# user/hamsh.ad, both REQUIRED to fail the checks above:
#
#   NC1  the `gc_collect_minor()` call in exec_block removed. Must reproduce
#        the original defect: arena exhausted, partial sums.
#   NC2  the three `gc_pin_get(...)` reads in exec_for replaced by the raw
#        local. Must produce SILENT WRONG ANSWERS — measured: all three `for`
#        loops truncate to their FIRST element while every other check stays
#        green. Without NC2, checks 3's `for` arms could be passing because
#        no collection happened to land inside them.
#
# If either mutant PASSES, this gate is blind and reports FAIL.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
mkdir -p "$OUT"
PASS=0
FAIL=0

ok()  { printf '[loop-arena] OK: %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '[loop-arena] FAIL: %s\n' "$1"; FAIL=$((FAIL+1)); }

# --------------------------------------------------------------- the driver
# Every heavy inner `while` is 3000 iterations, which at the measured ~5 cells
# an iteration is enough to force a collection INSIDE each outer construct.
# A driver that never collected mid-construct would assert nothing about the
# pins, which is what NC2 exists to disprove.
SCRIPT="$OUT/loop_arena_drive.hs"
cat >"$SCRIPT" <<'HSEOF'
def dbl(n) { return n * 2 }
KEEP = [1, 2, 3]
DD = {'a': 11, 'b': 22}
NAME = "hamnix"
i = 0
s = 0
while i < 60000 { i = i + 1 ; s = s + i ; t = "x" + i }
echo A_SUM $s
acc = ""
for f in alpha beta gamma delta {
    k = 0
    while k < 3000 { k = k + 1 ; junk = "pad" + k }
    acc = acc + f
}
echo B_ACC $acc
tot = 0
for v in [11, 22, 33, 44] {
    k = 0
    while k < 3000 { k = k + 1 ; junk = "pad" + k }
    tot = tot + v
}
echo C_TOT $tot
w = {5, 7, 9}
sw = 0
for z in w {
    k = 0
    while k < 3000 { k = k + 1 ; junk = "pad" + k }
    sw = sw + z
}
echo D_SUM $sw
try { raise "BOOMVAL" } except e { echo E_CAUGHT $e } finally { k = 0 ; while k < 3000 { k = k + 1 ; junk = "pad" + k } }
g = 0
i = 0
while i < 5000 { i = i + 1 ; g = dbl(i) }
echo F_LAST $g
kv = ${ KEEP[1] }
echo G_KEEP $kv ${ len(KEEP) } ${ len(DD) } $NAME
arenas
exit
HSEOF

# The exact strings a healthy shell must print. 1800030000 = 60000*60001/2.
EXPECT_A='A_SUM 1800030000'
EXPECT_B='B_ACC alphabetagammadelta'
EXPECT_C='C_TOT 110'
EXPECT_D='D_SUM 21'
EXPECT_E='E_CAUGHT BOOMVAL'
EXPECT_F='F_LAST 10000'
EXPECT_G='G_KEEP 2 3 2 hamnix'

# run_driver <binary> <dumpfile> -> writes the dump
run_driver() {
    timeout 180 "$1" --no-echo <"$SCRIPT" >"$2" 2>&1
    return 0
}

# healthy <dumpfile> -> 0 if EVERY expectation is present and no arena died
healthy() {
    local d="$1" e
    for e in "$EXPECT_A" "$EXPECT_B" "$EXPECT_C" "$EXPECT_D" \
             "$EXPECT_E" "$EXPECT_F" "$EXPECT_G"; do
        grep -aqF "$e" "$d" || return 1
    done
    grep -aq 'value arena exhausted' "$d" && return 1
    return 0
}

echo "[loop-arena] compiling hamsh for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
BIN="$OUT/hamsh_looparena_host"
if ! adder_bin x86_64-linux user/hamsh.ad "$BIN" 2>"$OUT/looparena_compile.log"; then
    echo "[loop-arena] FAIL: host hamsh did not compile/link"
    grep -v 'must-use\|note:' "$OUT/looparena_compile.log" | tail -20
    exit 1
fi
ok "host hamsh compiled"

echo "[loop-arena] compiling NATIVE hamsh for x86_64-adder-user (regress guard) ..."
if ! adder_bin x86_64-adder-user user/hamsh.ad "$OUT/hamsh_looparena_native.elf" \
        2>"$OUT/looparena_native.log"; then
    echo "[loop-arena] FAIL: native (device) hamsh did not compile"
    grep -v 'must-use\|note:' "$OUT/looparena_native.log" | tail -20
    exit 1
fi
ok "native (device) hamsh still compiles"

DUMP="$OUT/loop_arena_dump.txt"
run_driver "$BIN" "$DUMP"

# ---- 1. the long loop finishes, and finishes RIGHT ------------------------
if grep -aqF "$EXPECT_A" "$DUMP"; then
    ok "a 60000-iteration while loop completes with the exact sum (1800030000)"
else
    bad "the 60000-iteration loop did not print '$EXPECT_A' -- got: $(grep -a 'A_SUM' "$DUMP" | head -1)"
fi
if grep -aq 'value arena exhausted' "$DUMP"; then
    bad "'value arena exhausted' appeared -- the collector is not running inside the loop"
else
    ok "no arena was exhausted anywhere in the session"
fi

# ---- 2. occupancy is bounded, and collections really ran -----------------
# The `arenas` line is the shell's own tally; `gc=` counts collections.
# NOT `grep '^arenas'`: the shell's own prompt is written to the same stream,
# so the line arrives as `hamsh$ arenas nodes=...`. Anchoring matched nothing
# and this check reported "0 collections" about a session that ran 46 —
# a FALSE RED that would have been read as the fix not working.
ARENAS=$(grep -ao 'arenas nodes=.*' "$DUMP" | tail -1)
GCRUNS=$(printf '%s' "$ARENAS" | sed -n 's/.* gc=\([0-9]*\).*/\1/p')
VALS=$(printf '%s' "$ARENAS" | sed -n 's/.*vals=\([0-9]*\)\/.*/\1/p')
if [ "${GCRUNS:-0}" -ge 10 ]; then
    ok "$GCRUNS collections ran during the session (they fire INSIDE the loops)"
else
    bad "only ${GCRUNS:-0} collections in a session that allocates ~350000 cells -- the mid-loop collector is not firing"
fi
if [ -n "${VALS:-}" ] && [ "$VALS" -lt 12000 ]; then
    ok "value occupancy ended BOUNDED at $VALS/16384 after ~80000 loop iterations"
else
    bad "value occupancy ended at ${VALS:-?}/16384 -- not bounded"
fi

# ---- 3. every pinned construct still computes the right answer -----------
check_expect() {  # <expected line> <what>
    if grep -aqF "$1" "$DUMP"; then
        ok "$2"
    else
        bad "$2 -- expected '$1', got: $(grep -a "${1%% *}" "$DUMP" | head -1)"
    fi
}
check_expect "$EXPECT_B" "for over a WORD LIST is intact across collections"
check_expect "$EXPECT_C" "for over an EXPRESSION LIST is intact across collections"
check_expect "$EXPECT_D" "for over a BARE SET VARIABLE is intact across collections"
check_expect "$EXPECT_E" "try/except/finally carries the raised value across a heavy finally"
check_expect "$EXPECT_F" "a user function called 5000 times in a loop returns the right value"
check_expect "$EXPECT_G" "list / dict / string bindings made BEFORE the loops survive them"

# ------------------------------------------------------- negative controls
# Both mutants are compiled from a COPY under build/ (never user/), so the
# tree fingerprint scripts/_adder_bin.sh keys its cache on is unchanged and
# no sibling gate sees a mutated source.
mutant() {  # <name> <sed program> <why it must fail>
    local name="$1" sedprog="$2" why="$3"
    local src="$OUT/hamsh_${name}.ad" bin="$OUT/hamsh_${name}"
    cp user/hamsh.ad "$src"
    sed -i "$sedprog" "$src"
    if cmp -s user/hamsh.ad "$src"; then
        bad "$name: the mutation matched NOTHING -- this control is vacuous and proves nothing"
        return
    fi
    if ! timeout 1800 python3 -m compiler.adder compile --target=x86_64-linux \
            "$src" -o "$bin" >"$OUT/${name}_compile.log" 2>&1; then
        bad "$name: the mutant did not compile -- the control could not be run"
        return
    fi
    local d="$OUT/${name}_dump.txt"
    run_driver "$bin" "$d"
    if healthy "$d"; then
        bad "$name: THE MUTANT PASSED EVERY CHECK. $why -- this gate is blind and its green above means nothing"
    else
        ok "$name: the mutant fails as it must ($why)"
    fi
}

echo "[loop-arena] negative control 1: remove the mid-loop collection ..."
mutant nc1 's/^            gc_collect_minor()$/            gc_runs = gc_runs + 0/' \
    "with no collector inside exec_block the arena must fill and the loops must die"

echo "[loop-arena] negative control 2: unpin the for-loop iterables ..."
mutant nc2 \
  's/v_list_get(gc_pin_get(lpin, items), i)/v_list_get(items, i)/; s/_iter_get(gc_pin_get(ipin, iter), i2)/_iter_get(iter, i2)/; s/_iter_get(gc_pin_get(spin, sv), si)/_iter_get(sv, si)/' \
    "an unpinned iterable is a SILENT WRONG ANSWER once the cells slide under it"

# NC2 is only a real control if it fails for the RIGHT reason. Measured: all
# three for loops truncate to one element while A/E/F/G stay correct.
NC2D="$OUT/nc2_dump.txt"
if [ -f "$NC2D" ]; then
    if grep -aqF "$EXPECT_A" "$NC2D" && ! grep -aqF "$EXPECT_B" "$NC2D"; then
        ok "nc2 fails SPECIFICALLY on the for-loops (A_SUM still right, B_ACC wrong) -- the pins are what those checks measure"
    else
        bad "nc2 did not fail in the for-loops specifically; it is not isolating the pin reads"
    fi
fi

printf '\n[loop-arena] %d PASSED, %d FAILED\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "[loop-arena] PASS"
