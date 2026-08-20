#!/usr/bin/env bash
# scripts/devvm_down.sh — stop the persistent dev VM named by DEVVM_DIR.
#
# EVERY KILL HERE IS BY PID, FROM A PIDFILE, AND EVERY PID IS CHECKED AGAINST
# /proc BEFORE IT IS SIGNALLED. That is not ceremony. This box routinely runs
# a dozen QEMUs and several python servers for other agents, pids get reused,
# and `pkill -f qemu` or `pgrep -f devvm` would match both somebody else's
# work and this script's own command line. A detector that sees itself is a
# mistake this tree has already paid for.
set -uo pipefail
DEVVM_DIR="${DEVVM_DIR:-$HOME/.hamnix-build/devvm}"

[ -d "$DEVVM_DIR" ] || { echo "devvm: no rundir $DEVVM_DIR" >&2; exit 0; }

# stop <pidfile> <substring that must appear in /proc/<pid>/cmdline>
stop() {
    local pidfile="$1" want="$2" pid
    [ -f "$pidfile" ] || return 0
    pid=$(cat "$pidfile" 2>/dev/null || true)
    if [ -z "$pid" ] || [ ! -d "/proc/$pid" ]; then
        rm -f "$pidfile"; return 0
    fi
    # The identity check. Without it a recycled pid means this script kills an
    # unrelated process and reports success -- the failure would be silent and
    # would land on whoever owned that pid.
    if ! grep -qa -- "$want" "/proc/$pid/cmdline" 2>/dev/null; then
        echo "devvm: pid $pid is not '$want' any more — refusing to kill it" >&2
        rm -f "$pidfile"; return 0
    fi
    kill -TERM "$pid" 2>/dev/null
    for _ in $(seq 1 20); do
        [ -d "/proc/$pid" ] || break
        sleep 0.5
    done
    if [ -d "/proc/$pid" ]; then
        echo "devvm: pid $pid ignored SIGTERM, sending SIGKILL" >&2
        kill -KILL "$pid" 2>/dev/null
    fi
    rm -f "$pidfile"
    echo "devvm: stopped $want (pid $pid)"
}

stop "$DEVVM_DIR/qemu.pid"           qemu-system
stop "$DEVVM_DIR/http.pid"           http.server
stop "$DEVVM_DIR/console_reader.pid" devvm_console.py

rm -f "$DEVVM_DIR/console.sock" "$DEVVM_DIR/qmp.sock"
echo "devvm: down (console.log and push/ kept in $DEVVM_DIR)"
