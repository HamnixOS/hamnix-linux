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
# tests/linux/fdns_slot_exhaust.sh -- DOES A REDIRECT STILL APPLY AFTER A
# DESKTOP HAS BEEN OPENING APPLICATIONS ALL AFTERNOON?
#
# tests/linux/soak_desktop.sh answers that in seventeen minutes and a VM: it
# drove a desktop, and at 16m48s -- 118 launch cycles -- `ls /etc > /dev/null`
# began printing /etc to the console and said nothing about it.  This answers
# the same question in a few seconds, at the layer the resource lives in.  See
# tests/linux/fdns_slot_exhaust.c for what is modelled and why it is the
# desktop's shape rather than an arbitrary loop.
#
# FOUR ARMS, AND THREE OF THEM ARE MEANT TO BE RED WITHOUT THE FIX.  Every one
# builds the SAME two source files with different -D, so no arm is a story
# about code that is not in the tree:
#
#   RED (exhaustion) -DMAX_SLOTS=64 -DMAX_BINDS=512 -DMODEL_HEAD_HAMSH
#                    the tables and the shell exactly as they stood at
#                    6d183262.  Must reproduce the soak: a redirect whose
#                    bytes go TO THE CONSOLE, silently.
#   RED (collision)  -DFDNS_ALLOC_NO_CAS
#                    the allocator before the compare-and-swap claim.  Must
#                    reproduce the OTHER thing measuring this found: two
#                    processes taking the same slot, so a redirect's bytes
#                    land in somebody else's fifo.
#   GREEN            the tree as it ships.  Every redirect applies.
#   LOUD             -DMAX_SLOTS=4, a table too small to get anywhere.  Not
#                    "does it fail" -- of course it does -- but does it SAY
#                    SO and refuse, rather than run the command elsewhere.
#
# Usage: tests/linux/fdns_slot_exhaust.sh
# Env:   FDNS_EXHAUST_LAUNCHES  how many applications to open (default 400)
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"
# FIRST, before reap.sh and before $WORK -- the contract in
# tests/linux/private_ns.sh. gates_are_private.sh checks that this line is here.
. tests/linux/private_ns.sh
priv_ns_reexec "$@"
. tests/linux/reap.sh

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fdns_slot_exhaust.XXXXXX")"
reap_track "$WORK/reaped"
reap_on_exit :
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
# A bare EXIT trap does not run when the shell is killed by a signal, so a gate
# stopped by `timeout` (TERM) or ^C (INT) skipped its cleanup entirely.
trap 'exit 130' INT TERM HUP

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS  %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$*"; }
say() { printf '\n== %s\n' "$*"; }

LAUNCHES="${FDNS_EXHAUST_LAUNCHES:-400}"

# build_and_run <tag> <launches> [extra cc flags...]
# Leaves the arm's output in $WORK/<tag>.log and its rc in $ARM_RC.
build_and_run() {
    local tag="$1"; shift
    local n="$1"; shift
    mkdir -p "$WORK/$tag.srv" "$WORK/$tag.out"
    if ! cc -std=c11 -Wall -Wextra -Wno-unused-parameter -O1 -g \
            -I user -o "$WORK/bin.$tag" "$@" \
            tests/linux/fdns_slot_exhaust.c user/linux-fdns.c \
            >"$WORK/$tag.build" 2>&1; then
        ARM_RC=99
        sed 's/^/    /' "$WORK/$tag.build"
        return 1
    fi
    # Every arm gets its OWN segment and its OWN /srv: the tables are
    # process-shared by design, and two arms sharing one would measure each
    # other.  A wall-clock ceiling as well -- an arm that wedges must cost a
    # timeout, never the gate.
    env HAMFDNS="$WORK/$tag.shm" HAMFDNS_DIR="$WORK/$tag.srv" \
        FDNS_EXHAUST_DIR="$WORK/$tag.out" FDNS_EXHAUST_LAUNCHES="$n" \
        timeout 300 "$WORK/bin.$tag" >"$WORK/$tag.log" 2>&1
    ARM_RC=$?
    if [ "$ARM_RC" -eq 124 ]; then
        printf '    the %s arm did not finish in 300 s\n' "$tag"
        return 1
    fi
    return 0
}

curve() {   # the shape, without the per-launch noise
    grep -v '^\[fdns\]' "$WORK/$1.log" | sed -n '1,12p;$p' | sed 's/^/    /'
}

# ---------------------------------------------------------------------------
say "RED ARM 1 -- the tables and the shell as they stood at 6d183262"
if ! build_and_run red "$LAUNCHES" \
        -DMAX_SLOTS=64 -DMAX_BINDS=512 -DMODEL_HEAD_HAMSH=1; then
    bad "the exhaustion red arm did not run"
else
    curve red
    if grep -q 'THE CONSOLE' "$WORK/red.log"; then
        ok "RED: a redirect DOES silently go to the console -- $(grep -m1 'first failure at launch' "$WORK/red.log" | sed 's/^ *//')"
    else
        bad "RED: the negative control did NOT reproduce the failure in $LAUNCHES launches. Nothing below this line means anything: the instrument has not been shown able to produce a non-empty answer."
    fi
    # The shell half of the defect, stated separately from the table half.
    # linux-fdns.c is built from the tree in every arm, so the red arm DOES
    # get the "slot table full" note this branch added -- what it does not get
    # is a shell that acts on it.  That is the assertion: at 6d183262 the
    # command ran anyway, with whatever descriptors it had inherited.
    if grep -q 'REFUSED' "$WORK/red.log"; then
        bad "RED: the pre-fix shell model refused a command, which it never did"
    else
        ok "RED: and the command RAN ANYWAY -- nothing was refused, which is the half of the defect that lives in the shell"
    fi
fi

# ---------------------------------------------------------------------------
say "RED ARM 2 -- the allocator before the compare-and-swap claim"
# Two processes allocating at once took the SAME slot, and the record ended up
# with one allocator's kind and the other's PATH.  The redirect then opened
# that path, wrote, and returned success -- into somebody else's fifo.  It
# needs only a couple of dozen launches to show up, and it is intermittent, so
# the arm runs several times and asserts that at least one saw it.
#
# HOW MANY ATTEMPTS, AND WHY NOT SIX. A race arm that is itself flaky turns a
# green gate into a coin toss, which is worse than no arm. Measured hit rate is
# 2-3 runs in 6 at 24 launches, so six attempts miss about one time in twenty.
# Ten attempts of forty launches costs a couple of seconds and puts that under
# a thousandth -- and if it ever DOES come up empty the gate says so and calls
# everything below it meaningless, rather than passing quietly.
RACE_SEEN=0
for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if build_and_run "race$attempt" 40 -DFDNS_ALLOC_NO_CAS=1; then
        if grep -q 'NOWHERE' "$WORK/race$attempt.log"; then
            RACE_SEEN=$((RACE_SEEN+1))
            RACE_LINE=$(grep -m1 'NOWHERE' "$WORK/race$attempt.log" | sed 's/^ *//')
        fi
    fi
done
if [ "$RACE_SEEN" -gt 0 ]; then
    ok "RED: without the CAS claim a redirect's bytes reach neither the file nor the console ($RACE_SEEN of 10 runs): $RACE_LINE"
else
    bad "RED: the collision did not reproduce in 10 runs of 40 launches -- this arm is not shown able to go red, so the green one below proves nothing about the claim"
fi

# ---------------------------------------------------------------------------
say "GREEN ARM -- the tree as it ships"
if ! build_and_run green "$LAUNCHES"; then
    bad "the gate binary did not run"
else
    curve green
    if grep -q 'THE CONSOLE' "$WORK/green.log"; then
        bad "GREEN: a redirect silently went to the inherited descriptor"
    else
        ok "GREEN: no redirect went to the console in $LAUNCHES launches"
    fi
    if grep -q 'NOWHERE' "$WORK/green.log"; then
        bad "GREEN: a redirect's bytes reached neither the file nor the console"
    else
        ok "GREEN: no redirect's bytes went missing in $LAUNCHES launches"
    fi
    if [ "$ARM_RC" -eq 0 ]; then
        ok "GREEN: the harness's own assertions passed"
    else
        bad "GREEN: the harness reported failures (rc=$ARM_RC)"
    fi
fi

# ---------------------------------------------------------------------------
say "LOUD ARM -- a redirect that CANNOT be applied must say so and not run"
if ! build_and_run loud 12 -DMAX_SLOTS=4; then
    bad "the loud-failure arm did not run"
else
    if grep -qi 'slot table full' "$WORK/loud.log"; then
        ok "the exhausted table names itself: $(grep -m1 -i 'slot table full' "$WORK/loud.log" | sed 's/^ *//')"
    else
        bad "the slot table filled and said nothing -- the silence the soak found is still here"
    fi
    if grep -q 'THE CONSOLE' "$WORK/loud.log"; then
        bad "with the table full the bytes STILL went to the inherited descriptor"
    else
        ok "with the table full nothing was written to the wrong destination"
    fi
    if grep -q 'REFUSED' "$WORK/loud.log"; then
        ok "the command was refused rather than run with the wrong descriptors"
    else
        bad "nothing was refused -- the failing redirect did not stop its command"
    fi
fi

printf '\n%d PASSED / %d FAILED\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
