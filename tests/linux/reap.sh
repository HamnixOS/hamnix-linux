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
# tests/linux/reap.sh -- REAP WHAT YOU START, ON EVERY PATH OUT.
#
# THE GAP THIS CLOSES
# ===================
# tests/linux/wsys_title.sh had a `cleanup` that killed `$HOLDERS`, and a
# `trap cleanup EXIT` to run it. It looked right. It leaked every holder it
# ever started, on the SUCCESS path, because the holders were started from
#
#     BACK="$(hold back)"
#
# and `hold` did `HOLDERS="$HOLDERS $!"`. A command substitution is a SUBSHELL:
# the assignment happened in a child that then exited, and the parent's
# $HOLDERS stayed empty for the whole run. The trap fired, killed nothing, and
# the gate printed "23 passed, 0 failed" -- the success-shaped answer, with
# three parked processes left behind each time. 61 of them were found alive on
# this machine one morning, the oldest eight hours old.
#
# So the registry here is a FILE, not a shell variable. A file written by a
# subshell is still there when the subshell is gone. That is the whole idea,
# and it is the reason this is a helper rather than a fixed-up variable: no
# variable-based registry can survive `$( )`, however carefully it is written.
#
# THE SECOND HALF: HOW THE GATE ENDS
# ==================================
# `trap cleanup EXIT` does NOT run when the shell dies of an untrapped signal.
# A gate killed by `timeout` (SIGTERM), or by ^C at the terminal (SIGINT), or
# by its terminal going away (SIGHUP), skips the EXIT trap entirely and leaks
# everything. reap_on_exit installs a handler for those three that exits, so
# the EXIT trap does run. Cleanup that only happens when the run went well is
# not cleanup.
#
# USE
# ===
#     . tests/linux/reap.sh
#     reap_track "$WORK/reaped"        # optional: pick the registry's path
#     reap_on_exit cleanup             # your own cleanup, run on every path
#     foo &  reap_add $!               # after EVERY background launch
#
# reap_add is safe to call from inside `$( )`, from a function, from a
# subshell, from a pipeline -- anywhere. reap_all kills everything registered
# (TERM, then KILL) and is idempotent.

# The registry. Defaults to a private temp file; reap_track moves it somewhere
# the gate chooses (inside $WORK, say, so a KEEP=1 run can be inspected).
REAP_FILE="${REAP_FILE:-$(mktemp -p "${TMPDIR:-/tmp}" reapreg.XXXXXX)}"
export REAP_FILE

reap_track() {  # reap_track <path> -- put the registry here instead
    REAP_FILE="$1"
    : >"$REAP_FILE"
    export REAP_FILE
}

reap_add() {    # reap_add <pid>... -- remember a process to kill on the way out
    local p
    for p in "$@"; do
        case "$p" in
            ''|*[!0-9]*) continue ;;   # not a pid; a caller passing "" is fine
        esac
        printf '%s\n' "$p" >>"$REAP_FILE" 2>/dev/null
    done
}

reap_pids() {   # reap_pids -- every pid registered so far, one per line
    [ -s "$REAP_FILE" ] && sort -un "$REAP_FILE"
    return 0
}

reap_all() {    # reap_all -- kill everything registered. Idempotent.
    local p alive=0
    [ -n "${REAP_FILE:-}" ] || return 0
    [ -s "$REAP_FILE" ] || return 0
    for p in $(sort -un "$REAP_FILE"); do
        kill "$p" 2>/dev/null && alive=1
    done
    [ "$alive" = 1 ] && sleep 0.3
    for p in $(sort -un "$REAP_FILE"); do
        kill -9 "$p" 2>/dev/null
    done
    return 0
}

# reap_on_exit [extra-cleanup-function]
#
# Installs the traps. EXIT runs reap_all and then the caller's own cleanup, if
# named -- reap_all first, so a cleanup that unmounts or deletes $WORK is not
# racing processes that still have it open. INT/TERM/HUP re-exit so that the
# EXIT trap runs at all; 130 is the conventional "killed by a signal" status
# and keeps a runner from reading an interrupted gate as a pass.
reap_on_exit() {
    REAP_USER_CLEANUP="${1:-}"
    trap 'reap_all; [ -n "$REAP_USER_CLEANUP" ] && "$REAP_USER_CLEANUP"' EXIT
    trap 'exit 130' INT TERM HUP
}
