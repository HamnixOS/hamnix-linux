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
# panel_reaction.sh — DOES THE IDLE BACKOFF COST REACTION TIME?
#
# The panel now parks 100 ms instead of 16 ms once nothing has happened for
# half a second. Real events still wake it instantly (the /event fds are in
# the wait set), but POLLED state -- the window list, the config file, the
# notification bus -- has nothing to wake on, so those reactions are the ones
# that can get slower. This measures the worst of them: a new window appearing
# in the taskbar, with the panel already backed off.
#
# It times the PANEL'S OWN PIXELS, not the screen: the new window is placed in
# the middle of the display and only the top and bottom 40-row bands are
# compared, so a change means the panel repainted and not that the new window
# drew itself.
#
# Offscreen, software, no ICD. The display belongs to the machine owner.
set -uo pipefail
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ"
. tests/linux/reap.sh
B="${PANEL_BIN:-/home/david/.hamnix-build/cap-power-ab/bin}"
TRIALS="${TRIALS:-7}"
W="$(mktemp -d -p "${TMPDIR:-/tmp}" prx.XXXXXX)"
reap_track "$W/reaped"; cleanup(){ rm -rf "$W"; }; reap_on_exit cleanup
mkdir -p "$W/noicd"
export HAMWSYS="$W/s" HAMWSYS_BB="$W/b" HAMWSYS_IMG="$W/i"
export HAMFB_FILE="$W/fb.raw" HAMFB_GEOM=1280x800
: >"$W/in"; export HAMWSYSD_INPUT="$W/in"
export VK_ICD_FILENAMES="$W/noicd/none.json"
export HAMWSYS_DUMPABLE=1
"$B/wsysd" </dev/null >"$W/wsysd.log" 2>/dev/null & WP=$!; reap_add "$WP"
for _ in $(seq 1 100); do [ -s "$HAMFB_FILE" ] && break; sleep 0.1; done
"$B/hamdesktop" </dev/null >/dev/null 2>&1 & reap_add $!
"$B/hampanelscene" </dev/null >/dev/null 2>&1 & PP=$!; reap_add "$PP"
sleep 6

python3 - "$HAMFB_FILE" "$B" "$TRIALS" <<'PY'
import os, subprocess, sys, time
fb, bindir, trials = sys.argv[1], sys.argv[2], int(sys.argv[3])
Wd, Ht, BPP, BAND = 1280, 800, 4, 40
row = Wd * BPP
def bands():
    with open(fb, 'rb') as fh:
        top = fh.read(BAND * row)
        fh.seek((Ht - BAND) * row)
        return top + fh.read(BAND * row)
res = []
for t in range(trials):
    # 4 s of stillness so the backoff is definitely engaged before we poke it.
    time.sleep(4.0)
    base = bands()
    p = subprocess.Popen([bindir + "/de_dragload", "300", "200", "480", "300", "1", "2"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    t0 = time.monotonic()
    dt = None
    while time.monotonic() - t0 < 2.0:
        if bands() != base:
            dt = (time.monotonic() - t0) * 1000.0
            break
        time.sleep(0.001)
    p.kill(); p.wait()
    if dt is not None:
        res.append(dt)
        print("  trial %d: panel repainted %.1f ms after the window appeared" % (t + 1, dt))
    else:
        print("  trial %d: NO panel repaint within 2000 ms" % (t + 1))
if res:
    res.sort()
    print("panel_reaction: n=%d  p50 %.1f ms  max %.1f ms" % (len(res), res[len(res)//2], res[-1]))
else:
    print("panel_reaction: FAIL nothing was measured")
    sys.exit(1)
PY
