#!/usr/bin/env bash
#
# REGISTRATION, 2026-08-17. Until this date scripts/test_gate_registration.sh
# globbed only scripts/test_*.sh, so this directory was invisible to the gate
# against unregistered gates and every file in it read as coverage without
# being coverage. This gate is ON-DEMAND: not in ci_battery_manifest.txt
# because it is a HELPER, not a standalone gate: run with no arguments on 2026-08-17 it printed its usage line and exited 2 in 0 s. Other gates invoke it with arguments.
#
#
# kms_watchdog.sh — NOTHING HOLDS DRM MASTER LONGER THAN N SECONDS.
#
# WHY THIS EXISTS. The console framebuffer on this box is no longer the
# independent efifb; /proc/fb says `nvidia-drmdrmfb`. So the safety net that
# used to exist -- a bad modeset kills the picture but the text console
# survives on separate hardware -- is GONE. A process that dies while holding
# master, or hangs while holding it, can leave the machine with no picture AND
# no console, with the owner sitting at that console.
#
# HOW THE RECOVERY ACTUALLY WORKS, which is why killing is sufficient: DRM
# master is a property of the OPEN FILE, not of the process. When the process
# dies the fd closes, the kernel drops master, and drm_fb_helper restores the
# fbcon. So SIGKILL is a complete recovery and does not depend on the target
# cooperating, having a signal handler, or still being scheduled.
#
# USAGE:  kms_watchdog.sh <seconds> <command> [args...]
# EXIT:   the command's status, or 137 if the watchdog fired.
set -uo pipefail
[ $# -ge 2 ] || { echo "usage: kms_watchdog.sh <seconds> <cmd> [args...]" >&2; exit 2; }
SECS="$1"; shift

"$@" &
CHILD=$!
# THE PID OF THE PROCESS WE ACTUALLY STARTED, written down rather than
# searched for later. pgrep matching a wrapper's command line -- this script's
# own, whose argv contains "./bin/wsysd" -- has now produced four wrong
# measurements on this project, the last of which reported a busy compositor
# as "0.0% of a core" because it measured a sleeping bash.
[ -n "${WATCHDOG_PIDFILE:-}" ] && printf '%s' "$CHILD" > "$WATCHDOG_PIDFILE"

( # the watchdog itself
  end=$(( SECONDS + SECS ))
  while [ "$SECONDS" -lt "$end" ]; do
      kill -0 "$CHILD" 2>/dev/null || exit 0
      sleep 0.2
  done
  if kill -0 "$CHILD" 2>/dev/null; then
      echo "watchdog: FIRED after ${SECS}s -- killing pid $CHILD; the fd closes," >&2
      echo "watchdog: the kernel drops master and fbcon comes back." >&2
      kill -9 "$CHILD" 2>/dev/null
  fi
) &
WD=$!

wait "$CHILD"; rc=$?
kill "$WD" 2>/dev/null; wait "$WD" 2>/dev/null
exit "$rc"
