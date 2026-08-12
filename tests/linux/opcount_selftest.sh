#!/usr/bin/env bash
# opcount_selftest.sh — PROVE THE OP COUNTER BEFORE ANY NUMBER FROM IT IS USED.
#
# The counter exists to answer whether /dev/wsys could become a userland file
# server, by supplying the DENOMINATOR: how many operations a second would
# become round trips. A counter that under-reports would make a server look
# affordable when it is not -- the most flattering possible answer to exactly
# the question it exists to settle -- so it is checked against a load whose
# op count is known by construction, and it is required to be able to report a
# LARGE number as readily as a small one.
#
# Offscreen, software, no ICD. The display belongs to the machine owner.
set -uo pipefail
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ"
. tests/linux/reap.sh
BIN="${FPS_BIN_DIR:-/home/david/.hamnix-build/cap-power-ab/bin}"
W="$(mktemp -d -p "${TMPDIR:-/tmp}" opc.XXXXXX)"
reap_track "$W/reaped"; cleanup(){ rm -rf "$W"; }; reap_on_exit cleanup
pass=0; fail=0
ok(){ echo "opcount: PASS $*"; pass=$((pass+1)); }
bad(){ echo "opcount: FAIL $*"; fail=$((fail+1)); }

mkdir -p "$W/noicd"
export HAMWSYS="$W/s" HAMWSYS_BB="$W/b" HAMWSYS_IMG="$W/i"
export HAMFB_FILE="$W/fb.raw" HAMFB_GEOM=1280x800
: >"$W/in"; export HAMWSYSD_INPUT="$W/in"
export VK_ICD_FILENAMES="$W/noicd/none.json"

"$BIN/wsysd" </dev/null >"$W/wsysd.log" 2>&1 &
WP=$!; reap_add "$WP"
for _ in $(seq 1 100); do [ -s "$HAMFB_FILE" ] && break; sleep 0.1; done

# A KNOWN NUMBER OF OPERATIONS. de_dragload commits its scene and then writes
# exactly one `geometry` line per iteration -- one open + one write per move.
# We do not know the iteration count in advance, but we DO know the counter's
# `wid/ctl` writes must equal its opens (win_write opens, writes, closes), and
# that both must be >= the number of geometry lines it managed. The
# self-consistency of those two is what a broken counter fails.
HAMWSYS_OPCOUNT=1 "$BIN/de_dragload" 480 320 160 340 300 8 \
    >"$W/drag.out" 2>"$W/drag.opc" &
GP=$!; reap_add "$GP"
sleep 6
kill -9 "$GP" 2>/dev/null; wait "$GP" 2>/dev/null

if ! [ -s "$W/drag.opc" ]; then
    bad "the counter produced NO output with HAMWSYS_OPCOUNT=1 -- it is not wired up"
    echo "opcount: $pass passed, $fail failed"; exit 1
fi
ok "the counter emits a per-second series when asked ($(grep -c '^opcount: [0-9]' "$W/drag.opc") seconds)"

# 1. IT MUST BE ABLE TO REPORT A BIG NUMBER. A drag writes as fast as the ctl
#    file will take it, so this load is thousands of ops a second. A counter
#    that reports a few hundred here is broken in the flattering direction.
PEAK="$(grep -o '^opcount: [0-9]* ops/s' "$W/drag.opc" | awk '{print $2}' | sort -n | tail -1)"
if [ "${PEAK:-0}" -ge 1000 ]; then
    ok "it reports a LARGE rate when one exists: peak ${PEAK} ops/s on a free-running drag"
else
    bad "a free-running drag measured only ${PEAK:-0} ops/s -- the counter is under-reporting, which is the flattering direction for the question it exists to settle"
fi

# 2. SELF-CONSISTENCY: win_write() does open+write+close per line, so for
#    wid/ctl the open and write counts must match.
LAST="$(grep -n '^opcount: [0-9]* ops/s' "$W/drag.opc" | tail -1 | cut -d: -f1)"
CTL="$(tail -n +"$LAST" "$W/drag.opc" | grep -m1 'wid/ctl ')"
CO="$(echo "$CTL" | sed -n 's/.*open \([0-9]*\).*/\1/p')"
CW="$(echo "$CTL" | sed -n 's/.*write \([0-9]*\).*/\1/p')"
#    EXACTLY ONE in flight is allowed, and the tolerance is not a fudge. This
#    check first failed at opens 4345 against writes 4344, which is the client
#    being SIGKILLed in the window between its open(2) and its write(2) -- the
#    kill lands wherever it lands, and one of the two counts must therefore be
#    able to lead by one. A larger gap is a missed path; a gap of one is the
#    kill. Anything that made them always equal would be hiding the open.
D="$(( CO - CW ))"; [ "$D" -lt 0 ] && D="$(( -D ))"
if [ -n "$CO" ] && [ -n "$CW" ] && [ "$D" -le 1 ]; then
    ok "opens track writes on wid/ctl ($CO vs $CW, delta $D <= 1 for the op in flight at SIGKILL), which is what open+write+close per line must produce"
else
    bad "wid/ctl opens ($CO) != writes ($CW), delta $D -- more than one in flight means the counter is missing one of the two paths"
fi

# 3. IT MUST BE SILENT WHEN NOT ASKED. An always-on counter would change the
#    thing it measures, and every number in this tree taken without it would
#    have to be retaken.
"$BIN/de_dragload" 480 320 160 340 300 8 >"$W/d2.out" 2>"$W/d2.opc" &
G2=$!; reap_add "$G2"
sleep 3; kill -9 "$G2" 2>/dev/null; wait "$G2" 2>/dev/null
if [ -s "$W/d2.opc" ] && grep -q '^opcount:' "$W/d2.opc"; then
    bad "the counter printed WITHOUT HAMWSYS_OPCOUNT set -- it is not inert"
else
    ok "it is silent and inert unless HAMWSYS_OPCOUNT is set"
fi

echo "opcount: $pass passed, $fail failed"
[ "$fail" = 0 ]
