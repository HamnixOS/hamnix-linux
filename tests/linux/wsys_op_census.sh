#!/usr/bin/env bash
# wsys_op_census.sh — HOW MANY /dev/wsys OPERATIONS DOES A REAL SESSION DO?
#
# The denominator for the file-server question. Every op counted here would be
# a round trip if wsysd became the thing clients talk TO rather than a peer
# sharing memory with them.
#
# THE COUNTER IS PER-CLIENT, because /dev/wsys is in-process: there is no
# central place where all traffic passes, which is the point of the question.
# So each client is run with HAMWSYS_OPCOUNT=1 and its series collected
# separately, and the session total is their sum plus the compositor's own.
#
# Loads: idle, pointer motion, a window drag PACED LIKE A MOUSE, a window drag
# FREE-RUNNING (the worst case, which is what the gates actually run), the
# Applications menu, and starting an application.
#
# Offscreen, software, no ICD. The display belongs to the machine owner.
set -uo pipefail
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ"
# PRIVATE NAMESPACE FIRST -- before reap.sh (whose registry defaults to a mktemp
# under /tmp, and a registry made before the tmpfs lands on /tmp is one this
# script can no longer see) and before $W. "The display belongs to the machine
# owner" above is about the DISPLAY and is true; the filesystem is a separate
# question and the answer was no. wsysd's names are compiled into it
# (/srv/wsys, /dev/shm/hamnix-wsys, /tmp/hamnix-wsys), hamdesktop's and
# hampanelscene's are too (/tmp/hamdesktop-wp.status, /tmp/.hamdesktop.src,
# /tmp/hamnix-panel.health, /tmp/hamnix-notif.log) -- the table is in
# tests/linux/private_ns.sh -- and this machine's own live desktop holds every
# one of them.
#
# THIS SCRIPT ASSERTS NOTHING, so there is no verdict line to preserve; what has
# to survive is the REGIME of the six loads it measures. Isolation costs it
# nothing it uses: it starts no process as a second uid, $BIN stays under
# $HOME/.hamnix-build (which the helper does not shadow) and the tmpfs over /tmp
# is the same 16 GB RAM-backed filesystem the run used before.
. tests/linux/private_ns.sh
priv_ns_reexec "$@"
. tests/linux/reap.sh
BIN="${FPS_BIN_DIR:-/home/david/.hamnix-build/cap-power-ab/bin}"
SECS="${SECS:-10}"
W="$(mktemp -d -p "${TMPDIR:-/tmp}" opcen.XXXXXX)"
reap_track "$W/reaped"; cleanup(){ rm -rf "$W"; }; reap_on_exit cleanup

mkdir -p "$W/noicd"
export HAMWSYS="$W/s" HAMWSYS_BB="$W/b" HAMWSYS_IMG="$W/i"
export HAMFB_FILE="$W/fb.raw" HAMFB_GEOM=1280x800
: >"$W/in"; export HAMWSYSD_INPUT="$W/in"
export VK_ICD_FILENAMES="$W/noicd/none.json"

# The compositor is itself a /dev/wsys client (publish_state, scan_windows), so
# its own traffic counts toward the session -- but in a file-server world it is
# the SERVER and its ops become internal calls again. Counted separately and
# labelled, never silently folded in.
HAMWSYS_OPCOUNT=1 "$BIN/wsysd" </dev/null >"$W/wsysd.log" 2>"$W/wsysd.opc" &
WP=$!; reap_add "$WP"
for _ in $(seq 1 100); do [ -s "$HAMFB_FILE" ] && break; sleep 0.1; done
HAMWSYS_OPCOUNT=1 "$BIN/hamdesktop"    </dev/null >/dev/null 2>"$W/desk.opc" & reap_add $!
HAMWSYS_OPCOUNT=1 "$BIN/hampanelscene" </dev/null >/dev/null 2>"$W/panel.opc" & reap_add $!
sleep 5

# rate <file> <first-second-to-count> -> median ops/s over the window, all
# samples printed. Median of the per-second series, which is what the counter
# already produces -- three samples minimum, and the whole series shown.
series() { since_mark "$1" | grep -o '^opcount: [0-9]* ops/s' | awk '{print $2}'; }
peak10() { since_mark "$1" | grep -o 'peak [0-9]* per 10ms' | awk '{print $2}' | sort -n | tail -1; }

report() {   # label file...
    local label="$1"; shift
    local all="" tot=0 pk=0 f v
    for f in "$@"; do
        [ -s "$f" ] || continue
        v="$(series "$f" | tail -n "$SECS" | sort -n | awk '{a[NR]=$1} END{if(NR)print a[int((NR+1)/2)]; else print 0}')"
        tot=$(( tot + ${v:-0} ))
        all="$all $(basename "$f" .opc)=${v:-0}"
        local p; p="$(peak10 "$f")"; [ "${p:-0}" -gt "$pk" ] && pk="${p:-0}"
    done
    printf 'census: %-26s %6d ops/s total  [%s ]  worst 10ms burst %d ops (=%d/s)\n' \
        "$label" "$tot" "$all" "$pk" "$(( pk * 100 ))"
}

# MARK, NEVER TRUNCATE. The first version of this did `: >file` between loads
# to clear the window. The writers hold those files open at a non-zero offset,
# so truncating leaves the file NUL-padded up to that offset -- and grep then
# calls it a binary file and matches nothing. Every load reported 0 ops/s,
# which is exactly the kind of zero this project requires to be disproved
# before it is believed: the compositor publishes on every iteration and
# cannot possibly do 0 operations. Marking the line count instead touches
# nothing the writer owns.
MARKF="$W/marks"
mark_all() { : >"$MARKF"
    for f in "$W"/*.opc; do
        [ -e "$f" ] || continue
        printf '%s %s\n' "$f" "$(wc -l <"$f" 2>/dev/null || echo 0)" >>"$MARKF"
    done
}
since_mark() {   # since_mark <file> -> the lines added since mark_all
    local f="$1" m
    m="$(awk -v f="$f" '$1==f{print $2}' "$MARKF" 2>/dev/null)"
    tail -n "+$(( ${m:-0} + 1 ))" "$f" 2>/dev/null
}

echo "census: each figure is the MEDIAN of the per-second series over ${SECS}s,"
echo "census: per client; the worst 10 ms burst is the max across the window."
echo "census: $(priv_ns_describe)"
echo

mark_all; sleep "$SECS"
report "1 idle" "$W/desk.opc" "$W/panel.opc"
report "1 idle (+compositor)" "$W/wsysd.opc"

# ---- pointer motion ------------------------------------------------------
mark_all
python3 tests/linux/de_fps_driver.py --fb "$HAMFB_FILE" --input "$W/in" \
    --cat "$BIN/cat" --pid "$WP" --geom 1280x800 --mode fps \
    --seconds "$SECS" --rate 250 --tag p >/dev/null 2>&1
report "2 pointer 250 ev/s" "$W/desk.opc" "$W/panel.opc"
report "2 pointer (+compositor)" "$W/wsysd.opc"

# ---- a window drag, PACED LIKE A MOUSE -----------------------------------
# de_dragload free-runs by design ("as fast as the ctl file will take it"),
# which is the stress case and NOT what a hand does. A mouse reports at
# 125-1000 Hz; at most one window move per report. HAMNIX_DRAGLOAD_SLEEP_US
# does not exist, so the paced arm is produced by SIGSTOP/SIGCONT duty-cycling
# the client, which bounds its op rate without touching its code.
mark_all
HAMWSYS_OPCOUNT=1 "$BIN/de_dragload" 480 320 160 340 300 8 >/dev/null 2>"$W/drag.opc" &
GP=$!; reap_add "$GP"
( end=$(( SECONDS + SECS + 2 ))
  while [ "$SECONDS" -lt "$end" ]; do
      kill -STOP "$GP" 2>/dev/null; sleep 0.0075
      kill -CONT "$GP" 2>/dev/null; sleep 0.0005
  done ) &
PACER=$!; reap_add "$PACER"
sleep "$SECS"
kill -9 "$PACER" 2>/dev/null; kill -CONT "$GP" 2>/dev/null
report "3 drag, mouse-paced" "$W/drag.opc" "$W/desk.opc" "$W/panel.opc"
kill -9 "$GP" 2>/dev/null; wait "$GP" 2>/dev/null

# ---- a window drag, FREE-RUNNING (the gates' load, the worst case) -------
mark_all
HAMWSYS_OPCOUNT=1 "$BIN/de_dragload" 480 320 160 340 300 8 >/dev/null 2>"$W/drag2.opc" &
GP=$!; reap_add "$GP"
sleep "$SECS"
report "4 drag, free-running" "$W/drag2.opc" "$W/desk.opc" "$W/panel.opc"
report "4 drag free (+compositor)" "$W/wsysd.opc"
kill -9 "$GP" 2>/dev/null; wait "$GP" 2>/dev/null

# ---- starting an application --------------------------------------------
# The cost that matters here is the BURST at startup: connect, negotiate,
# allocate, commit a first scene. Measured over the app's own first seconds.
mark_all
HAMWSYS_OPCOUNT=1 "$BIN/de_dragload" 300 200 40 40 100 4 >/dev/null 2>"$W/app.opc" &
AP=$!; reap_add "$AP"
sleep 3
report "5 app start (first 3s)" "$W/app.opc"
kill -9 "$AP" 2>/dev/null; wait "$AP" 2>/dev/null
echo
echo "census: host load: $(cat /proc/loadavg)"
