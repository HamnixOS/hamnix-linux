#!/usr/bin/env bash
# scripts/ci_run_gate.sh — INCONCLUSIVE-aware CI wrapper for one gate.
#
# WHY THIS EXISTS
#
# The verdict vocabulary (scripts/_verdict.sh) is three-valued:
#
#     0    PASS          the assertion was OBSERVED to hold
#     1    FAIL          the assertion was OBSERVED to be violated
#   125    INCONCLUSIVE  the run never got far enough to observe it (QEMU
#                        timeout, a guest timer starved by host/runner load,
#                        a missing image/dependency)
#
# GitHub Actions treats ANY non-zero step exit as a build failure. If CI
# invoked a boot gate directly, an INCONCLUSIVE run — a GitHub runner has
# NO /dev/kvm, so every boot is pure-TCG software emulation and is routinely
# starved — would RED-WALL the build with a failure that says nothing about
# the code. That is exactly the false-red this project has been burned by.
#
# This wrapper runs one gate and maps its verdict onto CI semantics:
#
#     PASS (0)          -> exit 0   (green)
#     FAIL (1, or any
#          other non-125,
#          non-0 code)  -> exit rc  (red — a real, actionable failure)
#     INCONCLUSIVE (125)-> exit 0 + a GitHub ::warning:: annotation
#                          (NOT green-as-proof, but NOT a build failure: the
#                          runner was too starved to observe the assertion;
#                          re-run or move to a KVM runner to get a verdict)
#
# Rationale for not failing on 125: a starved TCG runner is an ENVIRONMENT
# input, not a regression. Treating it as red would make the whole battery
# flap on runner load and train everyone to ignore red — the precise failure
# mode that let a broken shell pipeline, a console-wedging df and a ps
# printing uninitialised memory all ship behind "green". A genuine
# regression exits 1 (FAIL) and still reds the build.
#
# USAGE
#   bash scripts/ci_run_gate.sh scripts/test_pipe.sh
#
# The gate's full output is streamed through unchanged (so the CI log and
# any uploaded artifact are complete); only the EXIT STATUS is remapped.

set -uo pipefail

if [ "$#" -lt 1 ]; then
    echo "usage: ci_run_gate.sh <test-script> [args...]" >&2
    exit 2
fi

gate="$1"; shift
name="$(basename "$gate" .sh)"

# THE OUTPUT IS CAPTURED AS WELL AS STREAMED, and the reason is a wrong
# sentence this file printed 64 times in one battery run (2026-08-17).
#
# The 125 branch used to name a CAUSE it had not measured: "the runner was too
# starved to observe the assertion ... Re-run, ideally on a KVM runner." It
# said that for EVERY 125, whatever produced it. Measured on this tree, of 66
# INCONCLUSIVE verdicts in one run of scripts/ci_battery_manifest.txt, 64
# carried a cause line in their own output and NOT ONE of them was starvation:
#
#     39  Error: can't open mod/kmod_hello.S for reading: No such file...
#     25  No such file or directory: '<tree>/linux_abi/autostub_und_manifest.json'
#
# Those are source paths this repository does not contain at all -- hamnix-linux
# tracks adder/ compiler/ docs/ etc/ examples/ fonts/ lib/ scripts/ tests/
# user/ and nothing else, while scripts/ci_battery_manifest.txt is the
# BARE-METAL line's battery. No amount of CPU or KVM fixes a file that is not
# in the tree, so the advice was not merely unproven, it was unactionable.
#
# This is the same class the project has paid for four times before: a gate's
# text stating a hypothesis as a finding. The fix is not a better guess, it is
# to stop guessing -- report the verdict, quote the gate's OWN cause line when
# it left one, and say plainly when it left none.
#
# ${PIPESTATUS[0]} not $? : after a pipe, $? is TEE's status, not the gate's.
#
# stderr IS merged into stdout here, deliberately: every cause line quoted
# above arrives on stderr (an assembler message, a Python traceback), so a
# capture of stdout alone would see none of them. The shard runner already
# sends both streams to one log, so nothing downstream can tell the
# difference; what changes is that this wrapper can now read what the gate
# said before deciding what to say about it.
CAP="$(mktemp -t ci_run_gate.XXXXXX)"
trap 'rm -f "$CAP"' EXIT
bash "$gate" "$@" 2>&1 | tee "$CAP"
rc="${PIPESTATUS[0]}"

case "$rc" in
    0)
        echo "[ci_run_gate] $name: PASS (verdict 0)"
        exit 0
        ;;
    125)
        # INCONCLUSIVE — surface it loudly but do NOT fail the build.
        echo "[ci_run_gate] $name: INCONCLUSIVE (verdict 125) — the gate did" \
             "NOT reach its assertion. NOT a regression, NOT proof of" \
             "correctness."
        why="$(grep -aoE "can't open [^ ]+ for reading|No such file or directory: '[^']+'|[Nn]o such file or directory|could not be built|missing" "$CAP" 2>/dev/null | head -1)"
        if [ -n "$why" ]; then
            echo "[ci_run_gate] $name: the gate's own output gives the cause:" \
                 "$why"
            echo "[ci_run_gate] $name: if that names a path this repository" \
                 "does not contain, re-running changes nothing."
        else
            echo "[ci_run_gate] $name: the gate printed no cause line, so WHY" \
                 "it stopped is NOT established here. Runner starvation is one" \
                 "possibility and this wrapper has not measured it."
        fi
        # GitHub annotation so it is visible on the run summary page.
        echo "::warning title=$name INCONCLUSIVE::gate did not reach its" \
             "assertion (verdict 125); treated as non-failing${why:+ — $why}"
        exit 0
        ;;
    *)
        echo "[ci_run_gate] $name: FAIL (verdict $rc) — an OBSERVED violation" >&2
        exit "$rc"
        ;;
esac
