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
# tests/linux/gate_read.sh — AN EMPTY READ IS NOT A MEASUREMENT.
#
# THE SHAPE THIS EXISTS TO KILL
# =============================
# A gate reads a value. The read comes back EMPTY for a reason that has
# nothing to do with what is being tested — the helper binary was not built,
# the compositor died before the read, a file was torn between its open and
# its write, a wid went away. The script defaults it with `${VAR:-0}` or
# `${2:-none}`, the default flows into a comparison, and THE DEFAULT BECOMES A
# VERDICT: 0 is not greater than $PANELH, so the gate prints "the menu never
# opened" about a menu it never looked at. The message names a defect in the
# system under test. The evidence is an empty string.
#
# Four real instances were found in tests/linux inside two days:
# de_fps_latency.sh invented an empty desktop out of an empty NWIN;
# de_focus_dismiss.sh's `focuswid() { set -- $(wstate); echo "${2:-none}"; }`
# turned an empty read into the verdict "focus is none"; de_fps_mate.sh's
# frame delta broke on an empty statefield; de_fps_driver.py reported a frame
# delta of plus or minus the whole counter as a measurement.
#
# The immediate cause of all four — a sink that was the empty string between
# its open and its write — was fixed at the source in 7121d2d1 (69 tears in
# 300,000 became 0 in 300,000). THESE HELPERS EXIST BECAUSE THAT IS NOT THE
# FIX. The gates were still written so that ANY empty read becomes a verdict,
# and the NEXT cause of an empty read will not announce itself either.
#
# THE RULE
# ========
# A read that comes back empty must make the gate SAY SO, loudly and by name,
# rather than substitute a number. An inconclusive gate is a fine outcome. A
# gate that reports a defect it did not observe is not.
#
# USAGE
# =====
# Source it after the script's own ok/bad/info helpers are defined (shell
# functions resolve at call time, so the order only matters for readability):
#
#     . tests/linux/gate_read.sh
#
#     LINE="$(winctl "$PANEL")"
#     if gate_fields "the panel's ctl line after the click" 5 "$LINE"; then
#         set -- $LINE; GROWNH="$5"
#         if [ "$GROWNH" -gt "$PANELH" ]; then ok  "..."; else bad "..."; fi
#     fi
#
# The `if` is the point: when the read did not come back, the assertion is
# SKIPPED rather than answered. gate_fields has already said, by name, which
# read failed and what it got instead.

# How many reads came back empty this run. A caller may report it; nothing
# here requires it to.
GATE_UNREAD=0

# gate_unreadable <sentence> — record that a value could not be read, by name,
# and fail the run.
#
# Deliberately NOT `info`: a gate whose instrument did not report must not go
# green. But the text is about the READ, never about the system, so nobody
# reads it as an observed defect. If the sourcing script has no `bad`, this
# still prints and still leaves a non-zero GATE_UNREAD for the caller.
gate_unreadable() {
    GATE_UNREAD=$((GATE_UNREAD + 1))
    if declare -F bad >/dev/null 2>&1; then
        bad "UNREADABLE -- $* -- this run did not observe the system, it failed to read it. Nothing below this line about that value is a measurement."
    else
        echo "UNREADABLE -- $* -- this run did not observe the system, it failed to read it." >&2
    fi
}

# gate_fields <what> <n> <text> — true when <text> carries at least <n>
# whitespace-separated fields, i.e. the read actually came back and is long
# enough to index. On failure it names the read and returns 1 so the caller
# skips the assertion instead of answering it with a default.
gate_fields() {
    local what="$1" n="$2" text="$3" got
    set -- $text
    got=$#
    [ "$got" -ge "$n" ] && return 0
    gate_unreadable "$what came back with $got field(s), not $n (raw: '$text')"
    return 1
}

# gate_nonempty <what> <text> — true when <text> is not empty. The one-value
# form of gate_fields, for reads that are a single token rather than a line.
gate_nonempty() {
    [ -n "$2" ] && return 0
    gate_unreadable "$1 came back EMPTY"
    return 1
}
