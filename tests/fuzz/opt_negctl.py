"""tests/fuzz/opt_negctl.py — shared NEGATIVE CONTROLS for the test_opt_* gates.

WHY THIS EXISTS
  On 2026-08-18 a 41-of-41 mutation census found eight REGISTERED gates that
  stayed green when the code they NAMED was broken:

      test_opt_cmpstore  test_opt_reglower   test_opt_leamuladd
      test_opt_methodsave  test_opt_nested_loops  test_opt_scor_storeelim
      test_opt_copyprop_blockleak  test_opt_loopcond_cse

  The census's diagnosis was that each names a subject in the RETIRED opt1 /
  isel / ir-emit lane (`isel_enable()` and `ir_emit_enable()` have zero call
  sites in the tree; `ra_enable()` is called only in the `--dump-regalloc`
  ANALYSIS lane) and therefore could not fail at all.

  RE-MEASURED, the second half of that diagnosis is WRONG.  All eight compile
  their fixtures through the LIVE `--opt` lane (the SSA pipeline: ssa_enable ->
  ssa_emit_program -> the SSA linear-scan allocator in ssa_emit.ad) and compare
  the RESULT against a constant or a Python-computed reference — an oracle the
  compiler under test does not produce.  Break something on THAT lane and every
  one of them goes red.  What was dead was the SUBJECT NAMED IN THEIR HEADERS,
  not the gates.

  So instead of retiring them, each now carries a NEGATIVE CONTROL that runs on
  EVERY invocation and proves, from that run's own output, that the gate can
  still fail.  A gate whose control does not fire is RED — a gate that cannot
  fail is not coverage, and now it says so itself instead of waiting for the
  next census.

THE LEVERS — both are compiler-side and need no source edit
  ADDER_RA_BREAK=2   ssa_emit.ad `sra_force_overlap()`: after linear scan, force
                     the first pair of register-assigned values with OVERLAPPING
                     live intervals to share one physical register, and (the "2")
                     SKIP the `sra_check_overlap` safety revert, so the miscompile
                     is actually emitted.  A genuine register-allocation
                     live-range defect on the live --opt lane.  Parsed by
                     ssa_emit_parse_env(), which the dump driver calls.
  ADDER_RA_OFF=1     ssa_emit.ad `sra_allocate()`: force the all-memory lowering,
                     i.e. the SSA register allocator does not allocate anything.
                     A DISABLE, not a defect: the values stay correct, so it is
                     the right control for a "the allocation actually happened"
                     assertion and the WRONG one for a value oracle.

MEASURED, dev host, 2026-08-18, logs under
~/.hamnix-build/gate8-20260818/logs/ — under ADDER_RA_BREAK=2 the value oracles
of cmpstore (4 of 5 cases), methodsave (3 of 6), nested_loops (7 of 8),
scor_storeelim (1 of 5), copyprop_blockleak (2 of 4), loopcond_cse and
leamuladd (5 of 5 sampled) all diverge from their expected constants.
reglower's deep-tree value does NOT diverge, which is why reglower's control is
the ADDER_RA_OFF=1 register-residency A/B instead (see its part E).
"""
import contextlib
import os


@contextlib.contextmanager
def _env(name, value):
    old = os.environ.get(name)
    os.environ[name] = value
    try:
        yield
    finally:
        if old is None:
            os.environ.pop(name, None)
        else:
            os.environ[name] = old


def ra_break():
    """Arm the SSA allocator's deliberate live-range overlap, safety net OFF."""
    return _env("ADDER_RA_BREAK", "2")


def ra_off():
    """Force the SSA allocator to the all-memory lowering (a DISABLE)."""
    return _env("ADDER_RA_OFF", "1")


RA_BREAK_WHAT = ("ADDER_RA_BREAK=2 (SSA linear-scan allocator forced to give two "
                 "values with OVERLAPPING live intervals the same register, "
                 "safety revert OFF)")
RA_OFF_WHAT = ("ADDER_RA_OFF=1 (SSA linear-scan allocator forced to the "
               "all-memory lowering)")


def report(tag, diverged, total, lever=RA_BREAK_WHAT):
    """Print the control's verdict.  Returns 1 if the gate must FAIL, else 0.

    `diverged` is how many of `total` re-run cases the gate's OWN oracle caught
    under the lever.  Zero means this gate cannot see a miscompile on the lane
    it tests, which is exactly the condition the 2026-08-18 census found and
    which must be loud, not silent.
    """
    if diverged > 0:
        print(f"[{tag}] NEGATIVE CONTROL RAN: with {lever} "
              f"{diverged}/{total} re-run case(s) diverged from the expected "
              f"value — this gate's oracle CAN see a miscompile on the lane it "
              f"tests.")
        return 0
    print(f"FAIL(negative-control) {tag}: with {lever} all {total} re-run "
          f"case(s) still matched the expected value. This gate cannot observe "
          f"a defect on the --opt lane it claims to guard, so its green means "
          f"nothing. See tests/fuzz/opt_negctl.py.")
    return 1
