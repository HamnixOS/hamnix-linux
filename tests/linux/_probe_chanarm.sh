#!/usr/bin/env bash
# THROWAWAY PROBE — chanrun's TIER-3 browser arm, verbatim, against a bin dir
# handed in by $1. Isolated the same way the gate is.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"
. tests/linux/private_ns.sh
priv_ns_reexec "$@"

BIN="${PROBE_BIN_DIR:?}"
WORK="$(mktemp -d "$HOME/.hamnix-build/chanarm.XXXXXX")"
. tests/linux/reap.sh
reap_track "$WORK/reaped"
echo "work=$WORK bin=$BIN"

if [ "${PROBE_LOAD:-0}" != 0 ]; then
    echo "loading the box with $PROBE_LOAD spinners"
    for _i in $(seq 1 "$PROBE_LOAD"); do
        ( while :; do :; done ) & reap_add $!
    done
fi

PAGE="$WORK/page.html"
cat >"$PAGE" <<'HTML'
<html><body bgcolor="#ffffff"><h1>packaged</h1>
<p>a v2 blit larger than a megabyte reached the screen</p></body></html>
HTML
BROWFB="$WORK/browfb.raw"
(
  export HAMWSYS="$WORK/bwsys" HAMWSYS_BB="$WORK/bbb" HAMWSYS_IMG="$WORK/bimg"
  export HAMFB_FILE="$BROWFB" HAMFB_GEOM=1280x800
  : >"$WORK/binput.evdev"; export HAMWSYSD_INPUT="$WORK/binput.evdev"
  mkdir -p "$WORK/bnoicd"; export VK_ICD_FILENAMES="$WORK/bnoicd/none.json"
  "$BIN/wsysd" </dev/null >"$WORK/bwsysd.log" 2>&1 &
  echo $! >"$WORK/bwsysd.pid"
  for _ in $(seq 1 60); do [ -s "$BROWFB" ] && break; sleep 0.1; done
  [ -s "$BROWFB" ] || { echo "NOFB"; exit 2; }
  "$BIN/hambrowse" "file://$PAGE" </dev/null >"$WORK/bbrowse.log" 2>&1 &
  echo $! >"$WORK/bbrowse.pid"
  python3 - "$BROWFB" <<'PY'
import sys, time
W, H = 1280, 800
path = sys.argv[1]
def white():
    raw = open(path, 'rb').read()
    n = 0
    for y in range(0, H, 4):
        for x in range(0, W, 4):
            o = (y * W + x) * 4
            if raw[o] > 240 and raw[o+1] > 240 and raw[o+2] > 240:
                n += 1
    return n
deadline = time.time() + 25
best = 0
while time.time() < deadline:
    n = white()
    best = max(best, n)
    if n > 500:
        print(n)
        sys.exit(0)
    time.sleep(0.5)
print(best)
sys.exit(1)
PY
) >"$WORK/brow.out" 2>&1
BROWRC=$?
echo "BROWRC=$BROWRC white=$(tail -1 "$WORK/brow.out")"
echo "--- literal-white count (de_browser_paints' instrument, same fb):"
python3 - "$BROWFB" <<'PY'
import sys
d=open(sys.argv[1],'rb').read()
print(len(d), d.count(b'\xff\xff\xff'))
PY
echo "--- bbrowse.log:"; tail -40 "$WORK/bbrowse.log" 2>/dev/null
echo "--- bwsysd.log:"; tail -40 "$WORK/bwsysd.log" 2>/dev/null
for f in "$WORK/bbrowse.pid" "$WORK/bwsysd.pid"; do
    [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null
done
echo "KEEP=$WORK"
