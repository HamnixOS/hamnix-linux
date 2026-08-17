#!/usr/bin/env bash
# tests/linux/hamui_v2_ceiling.sh — A v2 BLIT OVER 1 MiB IS ACCEPTED, AND THE
# TOOLKIT'S CEILING IS THE DEVICE'S.
#
# WHY THIS GATE EXISTS, AND IT IS THE SAME REASON TWICE.
#
# A packaging run refused to publish 1.0.25 with "a v2 blit bigger than
# ~512x512 is being refused by these bytes". IT WAS NOT: measured on the very
# binaries that run named -- tests/linux/de_mouse_chrome.sh 14 PASSED / 0
# FAILED and tests/linux/de_browser_paints.sh 463,989 page pixels against
# build/repo-obj -- and a full packager run on the same commit published a
# channel whose own chanrun scored 9/0 four times in a row. But the reason
# nobody could answer that in less than an hour is real and is what this file
# fixes: THE >1 MiB BLIT WAS ASSERTED NOWHERE A MERGE RUNS.
# tests/linux/wsys_chunkblit.sh, written for exactly this, was referenced by
# NOTHING in the tree -- no manifest, no runner, no other gate. The first
# thing to exercise the path was a publish.
#
# TWO ASSERTIONS, and neither is reachable by a smaller test:
#
# 1. AN 880x600 v2 WINDOW BLITS. 880*600*4 + 18 = 2,112,018 bytes, which is
#    the exact record size a 1 MiB reassembly buffer refused for the whole
#    life of this port -- "no v2 window over about 512x512 had ever painted,
#    the browser included" (ee62e0fc). A 512-byte blit sails through every
#    version of that code, so the size is the test; asserting on a small one
#    is what let the defect live. The rc is read from the toolkit AND the
#    pixels are read from the framebuffer, because a commit that returns 0
#    having painted nothing is the documented failure mode here.
#
# 2. hamui's BACKBUFFER CEILING EQUALS THE DEVICE'S `maxsurface`. lib/hamui.ad
#    held its own 1280x800 copy and clamped to it silently, returning success,
#    which would leave any window wider than 1280 painting its top-left corner
#    and nothing else. It reads /dev/wsys/pool now. THIS ASSERTION CANNOT BE
#    REPLACED BY A PIXEL TEST ON THIS MACHINE: the test framebuffer is
#    1280x800, which is precisely the number the stale copy held, so a
#    re-introduced copy would clip nothing here and say nothing. The probe
#    reads the pool ITSELF and compares that against what the toolkit
#    allocated, so the two numbers come from two places.
#
# Fast and unconditional: one compositor, one 15-line client, no browser, no
# desktop, no QEMU, no VNC. Entirely offscreen -- HAMFB_FILE and an evdev file.
#
#   env: CEILING_BIN_DIR=<dir>   run these binaries instead of building
#        CEILING_KEEP=1          keep the work directory
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"
# PRIVATE NAMESPACE FIRST -- before reap.sh and before $W. wsysd's names are
# compiled into it (/srv/wsys, /dev/shm/hamnix-wsys, /tmp/hamnix-wsys), so a
# run of this beside the machine's own live desktop would share them; the table
# is in tests/linux/private_ns.sh. Nothing here asserts about a uid, so the
# helper's one fidelity cost (euid 0 inside) touches nothing this gate claims.
. tests/linux/private_ns.sh
priv_ns_reexec "$@"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*"; }
info() { printf '  info %s\n' "$*"; }

WORK="${CEILING_WORK:-$HOME/.hamnix-build/hamui_v2_ceiling}"
mkdir -p "$WORK"
W="$(mktemp -d "$WORK/run.XXXXXX")"
. tests/linux/reap.sh
reap_track "$W/reaped"
cleanup() { [ "${CEILING_KEEP:-0}" = 1 ] || rm -rf "$W"; }
reap_on_exit cleanup

BIN="${CEILING_BIN_DIR:-$W/bin}"
mkdir -p "$BIN"
if [ -z "${CEILING_BIN_DIR:-}" ]; then
    for t in wsysd:user/wsysd.ad hamui_v2_ceiling:tests/linux/hamui_v2_ceiling.ad; do
        n="${t%%:*}"; s="${t#*:}"
        ./scripts/hamlinux_build.sh "$s" "$BIN/$n" >"$W/$n.build.log" 2>&1 || {
            bad "could not build $s"; tail -20 "$W/$n.build.log"; exit 1; }
    done
fi

echo "== does a v2 window over 1 MiB blit, and whose ceiling is it?"
info "$(priv_ns_describe)"

export HAMWSYS="$W/seg" HAMWSYS_BB="$W/bb" HAMWSYS_IMG="$W/img"
export HAMFB_FILE="$W/fb" HAMFB_GEOM=1280x800
: >"$W/input.evdev"; export HAMWSYSD_INPUT="$W/input.evdev"
mkdir -p "$W/noicd"; export VK_ICD_FILENAMES="$W/noicd/none.json"

"$BIN/wsysd" </dev/null >"$W/wsysd.log" 2>&1 &
reap_add $!
for _ in $(seq 1 100); do [ -s "$HAMFB_FILE" ] && break; sleep 0.1; done
# ASSERTED, not waited for. An unasserted wait on a compositor is how "wsysd
# was still starting" gets reported as "the blit was refused": that is exactly
# the shape of the false accusation in tests/linux/channel_runs_desktop.sh's
# browser arm, whose 6-second wait had no `||` after it.
if [ -s "$HAMFB_FILE" ]; then
    ok "wsysd produced a framebuffer ($(stat -c %s "$HAMFB_FILE") bytes) -- everything below is about the blit, not about a compositor that had not started"
else
    bad "wsysd never produced a framebuffer in 10 s -- nothing below is a question this run can answer"
    tail -20 "$W/wsysd.log" | sed 's/^/       /'
    echo; echo "hamui_v2_ceiling: $PASS passed, $FAIL failed"
    echo "FAIL hamui_v2_ceiling"; exit 1
fi

# ---- the client ------------------------------------------------------------
# IT HOLDS, and the pixel arm is measured WHILE IT DOES. A v2 window's content
# lives in the client's backbuffer, so a client that has exited has no pixels
# for the compositor to composite -- measuring after it returns reads an empty
# screen and would blame the blit for it.
"$BIN/hamui_v2_ceiling" 880 600 hold >"$W/probe.out" 2>"$W/probe.err" &
PROBE_PID=$!
reap_add $PROBE_PID
for _ in $(seq 1 60); do grep -q '^blit ' "$W/probe.out" 2>/dev/null && break; sleep 0.1; done
sleep 1.5
sed 's/^/       probe: /' "$W/probe.out"
[ -s "$W/probe.err" ] && sed 's/^/       probe(err): /' "$W/probe.err"

POOL="$(sed -n 's/^pool maxsurface=//p' "$W/probe.out" | head -1)"
BBW="$(sed -n 's/.* bbw=\([0-9-]*\) .*/\1/p' "$W/probe.out" | head -1)"
BBH="$(sed -n 's/.* bbh=\([0-9-]*\)$/\1/p' "$W/probe.out" | head -1)"
BLITB="$(sed -n 's/^blit bytes=\([0-9]*\) .*/\1/p' "$W/probe.out" | head -1)"
BLITRC="$(sed -n 's/^blit .*rc=\([0-9-]*\)$/\1/p' "$W/probe.out" | head -1)"

# MEASURED NOW, WHILE THE CLIENT IS STILL HOLDING ITS WINDOW OPEN. Asserted
# further down, so the report reads in the order a person would ask the
# questions; the datum has to be taken here.
RED="$(python3 - "$HAMFB_FILE" <<'PY'
import sys
W, H = 1280, 800
raw = open(sys.argv[1], 'rb').read()
n = 0
for y in range(0, H, 2):
    for x in range(0, W, 2):
        o = (y * W + x) * 4
        if o + 2 < len(raw):
            b, g, r = raw[o], raw[o+1], raw[o+2]
            if (abs(r - 220) < 24 and abs(g - 40) < 24 and abs(b - 40) < 24) or \
               (abs(b - 220) < 24 and abs(g - 40) < 24 and abs(r - 40) < 24):
                n += 1
print(n)
PY
)"
case "$RED" in ''|*[!0-9]*) RED=0;; esac
if kill -0 "$PROBE_PID" 2>/dev/null; then
    info "the client was still alive when the framebuffer was sampled"
else
    bad "the probe was already gone when the framebuffer was sampled -- it exited instead of holding its window, so the pixel arm below is measuring an empty screen and is not about the blit"
    tail -10 "$W/probe.err" | sed 's/^/       /'
fi

# ---- 1. THE DEVICE STATES ITS CEILING ---------------------------------------
case "$POOL" in
    [0-9]*x[0-9]*)
        ok "/dev/wsys/pool states its own ceiling: maxsurface $POOL" ;;
    *)
        bad "/dev/wsys/pool did not state a readable 'maxsurface <w>x<h>' (got '${POOL:-nothing}') -- with no published ceiling every client is back to holding its own copy, which is the defect this asserts against" ;;
esac

# ---- 2. THE TOOLKIT ALLOCATED WHAT IT ASKED FOR -----------------------------
# 880x600 is under any sane ceiling, so a toolkit whose ceiling is the device's
# gives back exactly 880x600. A toolkit carrying a 1280x800 copy ALSO gives
# back 880x600 -- which is why assertion 3 exists and this one is not enough.
if [ "$BBW" = 880 ] && [ "$BBH" = 600 ]; then
    ok "the toolkit allocated the window it was asked for: bbw=$BBW bbh=$BBH (these are the dims every v2 draw primitive clips against)"
else
    bad "the toolkit allocated ${BBW}x${BBH} for an 880x600 window -- a v2 client clips its own drawing to these, so it would paint part of its window and believe it had painted all of it"
fi

# ---- 3. THE TOOLKIT'S CEILING IS THE DEVICE'S, NOT ITS OWN ------------------
# Ask for a window ONE PIXEL WIDER than the device's published ceiling. A
# toolkit reading the device clamps to exactly that ceiling and SAYS SO; a
# toolkit with its own smaller copy clamps to the copy, silently. The
# distinguishing datum is the number it comes back with, so this is asserted on
# bbw/bbh and not on the presence of a message.
if [ -n "$POOL" ]; then
    PW="${POOL%x*}"; PH="${POOL#*x}"
    "$BIN/hamui_v2_ceiling" "$((PW + 1))" "$PH" >"$W/over.out" 2>"$W/over.err"
    sleep 1
    OBBW="$(sed -n 's/.* bbw=\([0-9-]*\) .*/\1/p' "$W/over.out" | head -1)"
    info "asked for $((PW + 1))x$PH (one column over the device's ceiling); the toolkit came back with bbw=${OBBW:-none}"
    if [ "$OBBW" = "$PW" ]; then
        ok "THE CEILING IS THE DEVICE'S: a request one column over $POOL was cut to $PW, the number /dev/wsys/pool published -- lib/hamui.ad is not carrying a copy"
    elif [ -z "$OBBW" ]; then
        bad "the over-ceiling run produced no bbw at all -- this gate cannot tell whose ceiling the toolkit used"
        tail -10 "$W/over.err" | sed 's/^/       /'
    else
        bad "THE TOOLKIT HAS ITS OWN CEILING AGAIN: a request for $((PW + 1)) columns was cut to $OBBW, not to the device's $PW. A client granted a window between $OBBW and $PW columns will rasterize and commit only its left $OBBW and leave the rest the compositor's clear colour. This is the fourth copy of this number in the Linux lane; two of the previous three reached the owner's screen (fd0d4f79, ae019748)."
    fi
    # AND IT MUST NOT BE SILENT. The clamp above is correct -- the device would
    # refuse a bigger blit rect -- but a client told nothing paints nothing for
    # ever, which is what b9f55228 was: "the clamp RETURNED SUCCESS".
    if grep -q 'exceeds the window system.s maximum surface' "$W/over.err"; then
        ok "and the clamp is LOUD: $(grep -m1 'exceeds the window system' "$W/over.err" | cut -c1-120)"
    else
        bad "the over-ceiling clamp said NOTHING on stderr -- a silent clamp that returns success is the exact shape of b9f55228 and ae019748"
    fi
else
    info "no published ceiling to test against, so 'whose ceiling is it' was not asked"
fi

# ---- 4. THE >1 MiB BLIT WAS ACCEPTED ----------------------------------------
if [ "${BLITB:-0}" -le 1048576 ] 2>/dev/null; then
    bad "the record this gate shipped was only ${BLITB:-0} bytes, which is NOT over 1 MiB -- a test too small to reach the defect is worse than no test (a 512-byte blit went green through every broken version of this code)"
elif [ "$BLITRC" = 0 ]; then
    ok "A v2 RECORD OF $BLITB BYTES WAS ACCEPTED (rc=0) -- over 1 MiB, and 2,112,018 is the exact size the old 1 MiB reassembly buffer refused"
else
    bad "THE >1 MiB BLIT WAS REFUSED: a $BLITB-byte record came back rc=$BLITRC. This is the ee62e0fc defect or one shaped like it: every v2 window over about 512x512 -- which is every browser window -- paints nothing."
    grep -aiE 'refus|EMSGSIZE|carry|maximum|-90' "$W/probe.err" "$W/wsysd.log" | head -8 | sed 's/^/       /'
fi

# ---- 5. AND THE PIXELS ARE ON THE SCREEN ------------------------------------
# rc=0 having painted nothing is the documented failure mode of this path: "a
# record that never completes is never applied, so the window painted NOTHING
# rather than part of a picture" (ee62e0fc). So the rc is not the last word.
# 880x600 sampled every other pixel in both axes is 132,000. Well over half of
# the window is the floor, and the compositor's clear (0x1C1C1C) contributes
# none of it.
info "rgb(220,40,40) pixels in the framebuffer (sampled 1 in 4): $RED"
if [ "$RED" -gt 60000 ]; then
    ok "THE PIXELS ARE ON THE SCREEN: $RED sampled pixels of the client's fill reached the framebuffer, so the accepted record was also APPLIED"
else
    bad "only $RED sampled pixels of the client's fill are in the framebuffer. A blit that returns 0 and paints nothing is this path's documented failure mode -- an incomplete record is never applied, so the window shows the compositor's clear colour rather than part of a picture."
    grep -aiE 'refus|EMSGSIZE|carry|maximum|-90' "$W/wsysd.log" | head -8 | sed 's/^/       /'
fi

echo
echo "hamui_v2_ceiling: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || { echo "FAIL hamui_v2_ceiling"; exit 1; }
echo "PASS hamui_v2_ceiling"
