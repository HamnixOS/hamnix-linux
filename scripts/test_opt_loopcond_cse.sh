#!/usr/bin/env bash
# scripts/test_opt_loopcond_cse.sh — focused, host-only DYNAMIC regression gate
# for the --opt LOOP-CONDITION CSE miscompile that hung the graphical desktop.
#
# ROOT CAUSE (adder/compiler/opt.ad): the Phase-2 local CSE (cse_stmt_expr_roots)
# processed WHILE / DO_WHILE loop CONDITIONS. A repeated pure subexpression in a
# loop condition (e.g. `s[start + blen]` read twice in `!= 0 and != '/'`) was
# minted into a `__cse_N = start + blen` temp and cse_block spliced that temp into
# the loop PREHEADER — computed ONCE. A loop condition is RE-EVALUATED every
# iteration, and here `blen` is incremented in the body, so the temp went STALE:
# the scanned address never advanced and the loop spun forever (fs/vfs.ad
# _cpio_listdir_at basename scan -> sys_open on a directory never returned ->
# desktop hang under HAMNIX_KERNEL_OPT=1). FIX: local CSE no longer touches loop
# conditions; hoisting a genuinely loop-INVARIANT condition subexpression is
# Phase-3 LICM's job (it computes the loop-body clobber set first).
#
# WHAT IT PROVES (no QEMU): the native codegen.ad compiles tests/opt/
# regress_loopcond_cse.ad BOTH --opt and --no-opt, both ELFs RUN, the --opt build
# TERMINATES (no spin), and both return the SAME correct value (13). A regression
# re-hoists the loop-variant index and the --opt build hangs -> timeout -> FAIL.
#
# RE-AIMED 2026-08-18 — READ THIS BEFORE THE HISTORY ABOVE.
#   `adder/compiler/opt.ad` AND ITS `cse_stmt_expr_roots` DO NOT EXIST IN THIS
#   TREE: opt.ad was deleted in ba2e4bcf (2026-07-21) and `--opt` now arms the
#   SSA pipeline. The specific defect named above cannot be restored, so the
#   2026-08-18 mutation census could not red this gate through its own subject.
#
#   IT IS NOT BLIND, AND THAT WAS MEASURED, NOT ASSUMED. Logs under
#   ~/.hamnix-build/gate8-20260818/logs/:
#     * ssa_emit.ad SVO_ICMP `emit_setcc_al(sv_c[v])` -> `emit_setcc_al(0x94)`:
#       **RED — `--opt` returned 0, `--no-opt` 13, exit 1**.
#     * ADDER_RA_BREAK=2 (SSA linear-scan allocator forced to overlap two live
#       intervals, safety revert off): **RED — `--opt` returned -11 (SIGSEGV),
#       exit 1**.
#   WHAT IT GUARDS NOW is the property, not the pass: a loop condition's
#   subexpression must be re-evaluated every iteration on whatever optimizer
#   `--opt` arms, and the fixture must TERMINATE and return 13. The 13 is a
#   hand-computed constant, not compiler output. Hoisting a loop-variant index
#   out of a loop is a bug the SSA LICM pass can make just as easily as opt.ad's
#   local CSE could, so the fixture keeps its value. The second lever above is
#   now a NEGATIVE CONTROL that RUNS on every invocation.
#
# HOST-ONLY: python3 + as/ld (x86_64), via the fuzz dump-driver + ELF wrapper. NO
# QEMU.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

fail() { echo "[opt_loopcond_cse] FAIL: $*" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "[opt_loopcond_cse] SKIP: no python3"; exit 0; }
command -v as >/dev/null 2>&1 || { echo "[opt_loopcond_cse] SKIP: no as"; exit 0; }
[ "$(uname -m)" = "x86_64" ] || { echo "[opt_loopcond_cse] SKIP: host $(uname -m) != x86_64"; exit 0; }

SRC="tests/opt/regress_loopcond_cse.ad"
[ -f "$SRC" ] || fail "missing fixture $SRC"

python3 - "$SRC" <<'PY'
import sys, subprocess, tempfile, os
from pathlib import Path
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as H

src = Path(sys.argv[1])

def run(opt):
    d = H.run_dump(src, opt=opt, timeout=120)
    if d.status != "ok":
        print(f"[opt_loopcond_cse] FAIL: --opt={opt} dump status={d.status} "
              f"{getattr(d,'detail','')[:200]}", file=sys.stderr)
        sys.exit(1)
    out = Path(tempfile.mktemp(suffix=".elf"))
    H.wrap_elf(d, out)
    os.chmod(out, 0o755)
    try:
        cp = subprocess.run([str(out)], timeout=8, capture_output=True)
        return cp.returncode
    except subprocess.TimeoutExpired:
        # A spin — the exact miscompile this gate guards.
        return "SPIN"
    finally:
        out.unlink(missing_ok=True)

noopt = run(False)
opt = run(True)
print(f"[opt_loopcond_cse] --no-opt rc={noopt}  --opt rc={opt}")
if opt == "SPIN":
    print("[opt_loopcond_cse] FAIL: --opt build SPINS (loop-condition CSE "
          "hoisted a loop-variant index into the preheader)", file=sys.stderr)
    sys.exit(1)
if noopt == "SPIN":
    print("[opt_loopcond_cse] FAIL: --no-opt build spins (fixture/env bug)",
          file=sys.stderr)
    sys.exit(1)
if noopt != 13:
    print(f"[opt_loopcond_cse] FAIL: --no-opt returned {noopt}, expected 13",
          file=sys.stderr)
    sys.exit(1)
if opt != noopt:
    print(f"[opt_loopcond_cse] FAIL: --opt {opt} != --no-opt {noopt}",
          file=sys.stderr)
    sys.exit(1)
# ---------------------------------------------------------------------------
# NEGATIVE CONTROL, RUN ON EVERY INVOCATION (see tests/fuzz/opt_negctl.py).
# ADDER_RA_BREAK=2 makes the SSA linear-scan allocator emit a real live-range
# aliasing miscompile; if this fixture STILL returns 13 under it, this gate
# cannot observe a defect on the lane it tests and its green means nothing.
# ---------------------------------------------------------------------------
import opt_negctl as NC
with NC.ra_break():
    nc = run(True)
if nc == 13:
    NC.report("opt_loopcond_cse", 0, 1)
    sys.exit(1)
print(f"[opt_loopcond_cse] NEGATIVE CONTROL RAN: with {NC.RA_BREAK_WHAT} the "
      f"--opt build returned {nc!r} instead of 13 — this gate CAN see a "
      f"miscompile on the lane it tests.")

print("[opt_loopcond_cse] PASS — loop-condition subexpression is not hoisted "
      "out of the loop; --opt terminates and matches --no-opt (13); negative "
      "control RAN")
PY