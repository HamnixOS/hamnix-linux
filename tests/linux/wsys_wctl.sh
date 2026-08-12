#!/usr/bin/env bash
# tests/linux/wsys_wctl.sh — DOES A hamui APP'S v2 NEGOTIATION REACH THE
# WINDOW SYSTEM AT ALL?
#
# THE DEFECT THIS EXISTS FOR, and it is the project's canonical failure shape:
# a gap that answers something SUCCESS-SHAPED instead of the truth.
#
# lib/hamui.ad's hamui_set_protocol_v2_dims() opens /dev/wsys/<wid>/wctl and
# writes "version 2\n" (_h_build_wsys_path(win_wid, "wctl")).  Every hamui
# application on this port calls it -- hambrowse calls it unconditionally at
# startup.  user/linux-wsys.c's classify() had no `wctl` leaf, and its
# window-relative final `else` sent any unrecognised name to HAMWSYS_SINK, a
# generic named buffer.  So:
#
#     the open succeeded, the write succeeded, the call returned 0,
#     the client set h_v2_active = 1 and believed it was a v2 client
#     for the rest of its life -- and the window system never heard it.
#
# The window stayed protocol 1, no backbuffer was ever allocated, and the
# per-window memfd confidentiality work (THE BACKBUFFER MEMFD in
# user/linux-wsys.c) protected a path that NOTHING ON THIS PORT REACHED.
# Nothing anywhere said so.  The comment on the `else` line even named the leaf
# it was swallowing: `leaf = HAMWSYS_SINK;  /* wctl, … */`.
#
# WHY IT IS ASSERTED ON THREE NUMBERS AND NOT ON THE WRITE'S RETURN.  The write
# returns success in BOTH the broken and the fixed world -- that is the entire
# defect.  So this gate reads back what the WINDOW SYSTEM did:
#
#   wctlrc   the negotiation write's return.  hamui believes >= 0.
#   proto    field 9 of /dev/wsys/<wid>/ctl -- 1 means the request never landed,
#            2 means the window system honoured it.
#   pool     /dev/wsys/pool -- `slots 0/512` means no backbuffer was ever
#            claimed for this window.
#
# BEFORE the fix: wctlrc >= 0, proto=1, slots 0/512.   <- success-shaped lie
# AFTER  the fix: wctlrc >= 0, proto=2, slots >= 1.
#
# AND IT DOES NOT STOP AT THE FLAG.  A window that negotiates v2 for the first
# time takes the v2 PAINT path for the first time too, and user/wsysd.ad's
# paint_window() bails at `if n < 0` on the scene read before it ever reaches
# paint_backbuffer -- a v2 window's scene read succeeds with 0 bytes only while
# scene_gen == 0.  So this gate also blits known pixels through the v2 protocol
# and asserts the COMPOSITOR PUT THEM ON THE SCREEN.  A green confidentiality
# gate must not stand in for a window that is never painted.
#
# THE MIRROR ASSERTION.  This gate drives the wctl write itself rather than
# linking hamui, so it also asserts that lib/hamui.ad still TARGETS `wctl` --
# if hamui is ever pointed somewhere else, the probe stops mirroring it and
# this gate says so instead of silently testing a path nobody uses.
#
# WHAT REACHING v2 DOES NOT BY ITSELF FIX, measured against a real hamui app so
# nobody reads this gate's green as more than it is.  hambrowse, unmodified, on
# a file:// page, A/B against a reverted tree (both arms built WHOLE -- /dev/wsys
# is implemented in-process, linux-wsys.c is linked into every binary, so a
# pre-fix arm needs a pre-fix BROWSER as well as a pre-fix compositor):
#
#   pre-fix   ctl: 2 50 40 880 600 12 1 1 1 3 ...   proto = 1
#   fixed     ctl: 2 50 40 880 600 12 1 1 2 4 ...   proto = 2
#
# and wsysd says "window 2 paints 880x0 of its 880x600 window" on BOTH arms.
# The browser is not painted either way: the scene it commits covers no rows,
# which is that diagnostic's own third case ("either the scene should cover its
# window, or the window should be the size of the scene, or it wants keyed 1").
# So the negotiation landing is necessary and NOT sufficient -- there is a
# separate, older gap in the hamui paint path on this port, and it is not this
# fix's to claim.  The one extra stderr line the fixed arm emits (the scene
# hand-up's "neither owns window N nor holds its display list") was counted at
# 3 s, 8 s and 15 s and stays at 1: the startup race the hand-up clock exists to
# clear, not a state the window sits in.
#
# Entirely offscreen: HAMFB_FILE and a file of evdev records, no VM, no DRM.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*"; }
info() { printf '  info %s\n' "$*"; }

WORK="${WSYS_WCTL_WORK:-$HOME/.hamnix-build/wsys_wctl}"
mkdir -p "$WORK"
W="$(mktemp -d "$WORK/run.XXXXXX")"
. tests/linux/reap.sh
reap_track "$W/reaped"
cleanup() { rm -rf "$W"; }
reap_on_exit cleanup

BIN="${WSYS_WCTL_BIN_DIR:-$W/bin}"
mkdir -p "$BIN"
if [ -z "${WSYS_WCTL_BIN_DIR:-}" ]; then
    for t in wsysd:user/wsysd.ad probe:tests/linux/wsys_uidgate.ad; do
        n="${t%%:*}"; s="${t#*:}"
        ./scripts/hamlinux_build.sh "$s" "$BIN/$n" >"$W/$n.build.log" 2>&1 || {
            bad "could not build $s"; tail -15 "$W/$n.build.log"; exit 1; }
    done
fi

echo "== does a hamui app's v2 negotiation reach the window system?"

# 0. THE MIRROR ASSERTION -- the probe below writes `version 2` to <wid>/wctl
#    because that is what lib/hamui.ad does. If that stops being true, this
#    gate is testing a path no application takes.
if grep -q '_h_build_wsys_path(win_wid, "wctl")' lib/hamui.ad; then
    ok "lib/hamui.ad still negotiates on <wid>/wctl, so the probe mirrors a real hamui app"
else
    bad "lib/hamui.ad no longer writes to <wid>/wctl -- this gate is now testing a path hamui does not take; re-point the probe"
fi

export HAMWSYS="$W/seg" HAMWSYS_BB="$W/bb" HAMWSYS_IMG="$W/img"
export HAMFB_FILE="$W/fb" HAMFB_GEOM=1280x800
: >"$W/input.evdev"; export HAMWSYSD_INPUT="$W/input.evdev"
mkdir -p "$W/noicd"; export VK_ICD_FILENAMES="$W/noicd/none.json"
# Deliberately NOT setting HAMNIX_WSYSD_SCANOUT: scanout refuses without it, so
# this gate cannot go near a real display.

"$BIN/wsysd" </dev/null >"$W/wsysd.log" 2>&1 &
reap_add $!
for _ in $(seq 1 80); do [ -s "$HAMFB_FILE" ] && break; sleep 0.1; done
[ -s "$HAMFB_FILE" ] || { bad "wsysd never produced a framebuffer"; \
                          tail -5 "$W/wsysd.log"; exit 1; }

# 1. THE NEGOTIATION, exactly as hamui performs it.
OUT="$("$BIN/probe" wctlv2 2>&1)"
echo "     $OUT"
WCTLRC="$(printf '%s' "$OUT" | sed -n 's/.*wctlrc=\(-\{0,1\}[0-9]\{1,\}\).*/\1/p')"
CTL="$(printf '%s' "$OUT" | sed -n 's/.*ctl=\[\([^]]*\)\].*/\1/p')"
POOL="$(printf '%s' "$OUT" | sed -n 's/.*pool=\[\([^]]*\)\].*/\1/p')"
PROTO="$(printf '%s' "$CTL" | awk '{print $9}')"
SLOTS="$(printf '%s' "$POOL" | sed -n 's/^slots \([0-9]\{1,\}\)\/.*/\1/p')"

# THE WRITE SUCCEEDS IN BOTH WORLDS -- reported, never asserted on alone.
if [ -n "$WCTLRC" ] && [ "$WCTLRC" -ge 0 ] 2>/dev/null; then
    info "the negotiation write returned $WCTLRC -- hamui takes this as success and sets h_v2_active=1"
else
    info "the negotiation write returned ${WCTLRC:-?}"
fi

if [ "${PROTO:-}" = "2" ]; then
    ok "THE WINDOW SYSTEM HONOURED IT: <wid>/ctl reports proto=2 (ctl: $CTL)"
else
    bad "THE NEGOTIATION NEVER LANDED: <wid>/ctl reports proto=${PROTO:-?}, not 2."\
        "hamui believes it is a v2 client and the window system has not heard of it."\
        "(ctl: $CTL)"
fi

# THE POOL IS READ AFTER A BLIT, and the proto above BEFORE one -- see the
# probe. A slot is claimed lazily on the first blit (Hamnix keeps the
# backbuffer in the client; the slot pool is this port's own construct), so a
# window that negotiates and never draws legitimately has none. Reading proto
# before the blit is what keeps this gate honest: a 'B' record opts a window
# into v2 by itself, so a blit first would turn proto=2 green on a tree where
# the negotiation still went nowhere.
if [ -n "${SLOTS:-}" ] && [ "$SLOTS" -ge 1 ] 2>/dev/null; then
    ok "and once it blits, a backbuffer IS claimed for it: $POOL"
else
    bad "and NO backbuffer was claimed even after a blit: ${POOL:-<unreadable>}."\
        "The per-window memfd confidentiality work protects a path nothing reaches."
fi

# 2. AND IT MUST BE PAINTED. A first-ever v2 window takes the v2 paint path for
#    the first time; paint_window() bails on the scene read before reaching
#    paint_backbuffer unless a v2 window's scene reads as a 0-byte success.
"$BIN/probe" fillwin >"$W/fill.out" 2>&1 &
reap_add $!
sleep 3
FILL="$(python3 - "$HAMFB_FILE" <<'PY'
import sys
d=open(sys.argv[1],'rb').read()
print(d.count(b'\x11\x22\x33')+d.count(b'\x33\x22\x11'))
PY
)"
if [ "${FILL:-0}" -gt 0 ] 2>/dev/null; then
    ok "AND THE COMPOSITOR PAINTS IT: $FILL pixels of the v2 window's own colour reached the framebuffer"
else
    bad "a v2 window was negotiated and NOTHING WAS PAINTED ($FILL pixels on screen)."\
        "See paint_window()'s scene-read bail in user/wsysd.ad -- a v2 window's"\
        "scene must read as a 0-byte SUCCESS, not a refusal."
fi

# 3. A FULL-SIZED BLIT IN ONE WRITE -- the size a real window actually sends.
#    lib/hamui.ad composes the whole 'B' header plus the RGBA payload into one
#    scratch buffer and issues ONE write of it, so an 880x600 window blits
#    2,112,018 bytes at once. The draw/ctl write path used to copy every write
#    into a 1 MiB reassembly buffer and refuse anything larger, so EVERY blit
#    from EVERY v2 window bigger than about 512x512 was refused: measured,
#    write(2) returned -90 (EMSGSIZE) and the window painted nothing. The small
#    blit above is 512 bytes and sails through, which is exactly why this
#    assertion has to exist separately -- a tiny test cannot see this.
BIG="$("$BIN/probe" bigblit 2>&1 | head -1)"
echo "     $BIG"
BW="$(printf '%s' "$BIG" | sed -n 's/.*wrote=\(-\{0,1\}[0-9]\{1,\}\).*/\1/p')"
BB="$(printf '%s' "$BIG" | sed -n 's/.*bytes=\([0-9]\{1,\}\).*/\1/p')"
if [ -n "$BW" ] && [ "$BW" = "${BB:-x}" ]; then
    ok "a FULL-SIZED blit is accepted whole: ${BB} bytes in one write(2)"
elif [ "${BW:-0}" = "-90" ]; then
    bad "A FULL-SIZED BLIT IS REFUSED: write(2) returned -90 (EMSGSIZE) for"\
        "${BB} bytes. Every v2 window bigger than ~512x512 -- which is every"\
        "browser -- cannot put a single frame on screen."
else
    bad "a full-sized blit was not accepted: wrote=${BW:-?} of ${BB:-?} bytes"
fi

echo
echo "wsys_wctl: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || { echo "FAIL wsys_wctl"; exit 1; }
echo "PASS wsys_wctl"
