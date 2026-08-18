#!/usr/bin/env bash
# scripts/test_signed_shift.sh — revert-sensitive static check for the SIGNED
# right-shift (`>>`) codegen bug, host-only (NO QEMU). Pins BOTH backends:
# the frozen Python seed (compiler/codegen_x86.py) and the self-hosted native
# backend (compiler/codegen.ad).
#
# THE BUG: `>>` picked arithmetic (sarq) vs logical (shrq) from BOTH operands'
# signedness. But a shift's signedness is a property of the shifted VALUE (the
# LEFT operand) ALONE — the COUNT's type is irrelevant in C. So a signed value
# shifted by an UNSIGNED count, or reached through an array element / integer
# sub-expression the type resolver reported "unknown", wrongly emitted the
# LOGICAL shrq (zero-fill instead of sign-fill), corrupting every negative
# intermediate (this broke the ed25519 field/scalar reductions).
#
# THE FIXTURE (tests/fuzz/regress_signed_shift.ad) right-shifts the SAME
# negative int64 through every previously-miscompiled operand form (array
# element, integer sub-expression, function parameter, uint64 count) and
# compares each against a REFERENCE arithmetic shift; it returns 0 iff every
# form sign-extended, 1 if any zero-filled. So this asserts the actual
# SIGN-EXTENDING RUNTIME behaviour (NOT merely seed==native — both shared the
# bug): revert either backend's fix and its exit flips to 1 and this gate fails.
#
# THE BLIND AXIS, MEASURED AND NOW CLOSED (2026-08-18).
#   The paragraph above says this gate "does NOT rely on seed==native ... it
#   pins the actual sign-extending RUNTIME behaviour". That was HALF TRUE and the
#   mutation census proved which half. `arith_ref()` is COMPILED BY THE SAME
#   BACKEND UNDER TEST, so it is a reference only for defects that hit some
#   operand forms and not others. Making EVERY `>>` in the backend logical left
#   this gate GREEN: the reference degraded identically and every comparison
#   still agreed. A test whose oracle shares the defect measures AGREEMENT, not
#   correctness.
#
#   The fixture now also carries `const_table_check()` — 44 comparisons of
#   `base >> n` (n in {1,2,3,7,15,31,32,33,47,62,63}, in four operand forms)
#   against LITERAL CONSTANTS computed in PYTHON, whose `>>` on a negative int is
#   arithmetic by definition and is not this compiler. The backend has to
#   materialise those constants; it never computes them. A uniform shr-for-sar
#   defect mismatches every line and the fixture exits 2.
#   Exit codes: 0 = both checks pass; 1 = the FORM-specific agreement check
#   failed (the historical bug); 2 = the CONSTANT table failed (the uniform
#   defect the old gate could not see).
#   MEASURED 2026-08-18, logs under ~/.hamnix-build/gate8-20260818/logs/ — see
#   the run recorded in scripts/ci_battery_manifest.txt for the mutation result.
#
# Usage:  bash scripts/test_signed_shift.sh

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

fail() { echo "[signed-shift] FAIL $*"; exit 1; }

command -v python3 >/dev/null 2>&1 || fail "python3 not found"
[ "$(uname -m)" = "x86_64" ] || fail "host $(uname -m), need x86_64 to run the ELFs"

FIX="tests/fuzz/regress_signed_shift.ad"
[ -f "$FIX" ] || fail "missing fixture $FIX"
WORK="build/signed_shift"
mkdir -p "$WORK"

echo "[signed-shift] (1/2) seed: signed-operand >> must sign-extend for every form"
python3 -m compiler.adder compile --target=x86_64-linux "$FIX" \
    -o "$WORK/fixture_seed" >/dev/null 2>"$WORK/seed.cerr" \
    || { cat "$WORK/seed.cerr"; fail "seed failed to compile the fixture"; }
"$WORK/fixture_seed"; SEED_EXIT=$?
echo "[signed-shift]   seed exit = $SEED_EXIT (expect 0)"
case "$SEED_EXIT" in
  0) : ;;
  1) fail "seed emitted a LOGICAL shr for SOME signed-operand form (array/subexpr/param/uint64-count) — negative values zero-filled instead of sign-extending (agreement check, exit 1)" ;;
  2) fail "seed disagreed with the PYTHON-COMPUTED CONSTANT TABLE — a UNIFORM shr-for-sar defect: every form shifted the same wrong way, so the in-fixture reference agreed with them (exit 2)" ;;
  *) fail "seed exited $SEED_EXIT, which is neither 0, 1 nor 2 — the fixture did not run to its return" ;;
esac

echo "[signed-shift] (2/2) codegen.ad must sign-extend too (default AND --opt paths)"
AD_OUT="$(python3 - "$FIX" <<'PY'
import sys; sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
from pathlib import Path
h.build_driver(force=True)
body = open(sys.argv[1]).read()
bad = 0
for opt in (False, True):
    r = h.run_through_codegen_ad("signed_shift", body, Path("build/signed_shift"), opt=opt)
    tag = "opt" if opt else "default"
    print(f"{tag} {r.kind} {r.exit}")
    if not (r.kind == "ok" and r.exit == 0):
        bad = 1
        if r.exit == 1:
            print(f"{tag} FORM-SPECIFIC: some operand form zero-filled while "
                  f"the in-fixture reference agreed with it")
        elif r.exit == 2:
            print(f"{tag} UNIFORM: the python-computed CONSTANT TABLE "
                  f"mismatched — every `>>` lowered the same wrong way")
sys.exit(bad)
PY
)"; AD_RC=$?
echo "$AD_OUT" | sed 's/^/[signed-shift]   codegen.ad /'
[ "$AD_RC" -eq 0 ] \
    || fail "codegen.ad emitted a LOGICAL shr for a signed operand (see line above) — a sar-vs-shr divergence from the fixed seed"

echo "[signed-shift] PASS"
