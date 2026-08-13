#!/usr/bin/env bash
# wsys_enum_policy.sh — A CLIENT THAT OWNS NOTHING CAN STILL ENUMERATE
# EVERYTHING, AND THE CURRENT DESIGN CANNOT EXPRESS OTHERWISE.
#
# RED ON PURPOSE, AND RED FIRST. This gate asserts the property the file
# server exists to make possible, so it FAILS on the in-process design. That
# is the point: a gate written after the fix cannot show the fix was needed.
#
# THE PROPERTY. "Which windows exist" should be answerable DIFFERENTLY for
# different callers. A taskbar needs the list -- that is its whole job. An
# arbitrary program does not, and today it gets the same answer, because
# /dev/wsys/windows is a read of shared memory that the reader's own linked-in
# code performs. There is no mediator to ask, so there is no place a policy
# could live. Namespaces decide who can REACH /dev/wsys; nothing decides what
# a process may LEARN once it is in.
#
# This is the same absence as the same-uid pixel scrape and as win_alloc
# racing two clients onto one row: not a missing check, a missing MEDIATOR.
#
# WHAT "GREEN" WILL MEAN. With wsysd as a file server, enumeration becomes a
# request the server answers, so it can return the caller's own windows to an
# ordinary client and the full list only to a caller holding the taskbar
# capability. This gate goes green when an unprivileged, window-less client
# can no longer see another client's window title.
#
# Offscreen, software, no ICD. The display belongs to the machine owner.
set -uo pipefail
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ"
. tests/linux/reap.sh
BIN="${FPS_BIN_DIR:-/home/david/.hamnix-build/cap-power-ab/bin}"
W="$(mktemp -d -p "${TMPDIR:-/tmp}" enum.XXXXXX)"
reap_track "$W/reaped"; cleanup(){ rm -rf "$W"; }; reap_on_exit cleanup
pass=0; fail=0
ok(){ echo "enumpol: PASS $*"; pass=$((pass+1)); }
bad(){ echo "enumpol: FAIL $*"; fail=$((fail+1)); }

mkdir -p "$W/noicd"
export HAMWSYS="$W/s" HAMWSYS_BB="$W/b" HAMWSYS_IMG="$W/i"
export HAMFB_FILE="$W/fb.raw" HAMFB_GEOM=1280x800
: >"$W/in"; export HAMWSYSD_INPUT="$W/in"
export VK_ICD_FILENAMES="$W/noicd/none.json"

"$BIN/wsysd" </dev/null >"$W/wsysd.log" 2>&1 & WP=$!; reap_add "$WP"
for _ in $(seq 1 100); do [ -s "$HAMFB_FILE" ] && break; sleep 0.1; done
[ -s "$HAMFB_FILE" ] || { bad "wsysd produced no framebuffer"; exit 1; }

# THE VICTIM: a client that owns a window with a distinctive title.
"$BIN/de_dragload" 480 320 160 340 300 8 >"$W/victim.wid" 2>&1 & VP=$!
reap_add "$VP"
sleep 3
VWID="$(tr -d '\n' <"$W/victim.wid" 2>/dev/null)"
if [ -z "${VWID:-}" ] || [ "${VWID:-0}" -lt 2 ]; then
    bad "the victim never mapped a window -- this gate would be vacuous"
    echo "enumpol: $pass passed, $fail failed"; exit 1
fi
ok "a victim client owns window $VWID"

# THE SNOOPER: a process that owns NO window at all. `cat` is an ordinary
# program; it has never called newwindow and holds nothing.
"$BIN/cat" /dev/wsys/windows >"$W/seen.txt" 2>"$W/seen.err" || true
echo "enumpol: what a window-less process can read from /dev/wsys/windows:"
sed 's/^/enumpol:   /' "$W/seen.txt" | head -8

# INSTRUMENT CHECK FIRST: an empty read would make the assertion below pass
# for the wrong reason -- "it saw nothing" and "it could not look" are not the
# same, and a gate that cannot tell them apart is worthless.
if ! [ -s "$W/seen.txt" ]; then
    bad "the snooper read NOTHING at all -- cannot distinguish a working policy from a broken read; refusing to report this as the property holding"
    echo "enumpol: $pass passed, $fail failed"; exit 1
fi
ok "the snooper's read returned data, so a negative result below would be meaningful"

# THE ASSERTION. RED TODAY.
if grep -q "^${VWID} " "$W/seen.txt"; then
    bad "a process owning NO window enumerated window $VWID (\"$(grep -m1 "^${VWID} " "$W/seen.txt" | cut -c1-60)\"). Enumeration is not mediated: the reader's own linked-in code answered from shared memory, so there is nowhere a policy could live. THIS IS THE EXPECTED RED until /dev/wsys is served by wsysd."
else
    ok "a window-less process cannot see window $VWID -- enumeration is mediated"
fi

echo "enumpol: $pass passed, $fail failed"
[ "$fail" = 0 ]
