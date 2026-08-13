#!/usr/bin/env bash
# tests/linux/de_browser_paints.sh — THE BROWSER PUTS A PAGE ON THE SCREEN,
# AND THE COMPOSITOR DOES NOT SAY OTHERWISE.
#
# Two assertions, and the second exists because the first was true while the
# log said the opposite.
#
# 1. THE PAGE IS PAINTED. hambrowse is the tree's only v2 blit client that a
#    person actually looks at. Until the draw/ctl write path stopped refusing
#    records larger than its 1 MiB reassembly buffer, no v2 window bigger than
#    about 512x512 had ever put a frame on this port's screen -- every blit
#    from an 880x600 browser window was refused with EMSGSIZE and the window
#    was the compositor's grey. This asserts on PIXELS: the page background
#    must actually be in the framebuffer.
#
# 2. THE COMPOSITOR MUST NOT REPORT IT AS PAINTING NOTHING. wsysd's
#    report_uncovered() measures coverage of the RASTERIZED SCENE, and a v2
#    window's content does not come from its scene at all -- it comes from the
#    backbuffer, composited by paint_backbuffer() before the scene is ever
#    rasterized. So for a v2 window that measurement is of the wrong thing, and
#    it printed
#
#        wsysd: window 2 paints 880x0 of its 880x600 window --
#               600 rows reach the screen as the compositor's clear colour.
#
#    on EVERY run, deterministically, about a window that was painting 468,480
#    pixels of page. That is the same shape report_uncovered already exempts
#    keyed and blended windows for, in its own words: "painting less than you
#    own is the CORRECT and requested behaviour ... so reporting them would be
#    a warning that is always wrong, which is how a warning stops being read."
#    A warning that is always wrong for the one client a person sees is worse
#    than none: it is the first thing anyone debugging the browser will find.
#
# WHY hambrowse AND NOT A TOY. A small blit sails through every version of this
# code -- the 512-byte one in tests/linux/wsys_wctl.sh went green while every
# real window was being refused. A test too small to see the thing it claims to
# cover is worse than no test, so this drives the real browser at its real size.
#
# Entirely offscreen: HAMFB_FILE plus a file of evdev records. No VM, no DRM,
# and HAMNIX_WSYSD_SCANOUT is deliberately left unset so the scanout path
# refuses and nothing can approach a real display.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"
# PRIVATE NAMESPACE FIRST -- before reap.sh, before $W, before the build.
# "Entirely offscreen" above is about the DISPLAY, and it is true; it is not a
# statement about the filesystem. wsysd's names are compiled into it -- /srv/wsys,
# /dev/shm/hamnix-wsys, /tmp/hamnix-wsys -- and hambrowse is a desktop client, so
# a run of this beside the machine's own live desktop shares names with it (the
# table is in tests/linux/private_ns.sh). Nothing here asserts about a uid, so
# the helper's one fidelity cost (euid 0 inside) touches nothing this gate
# claims; $WORK stays under $HOME/.hamnix-build, which the helper does not
# shadow, so a pinned BROWSER_PAINTS_BIN_DIR still finds its binaries.
. tests/linux/private_ns.sh
priv_ns_reexec "$@"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*"; }
info() { printf '  info %s\n' "$*"; }

WORK="${BROWSER_PAINTS_WORK:-$HOME/.hamnix-build/browser_paints}"
mkdir -p "$WORK"
W="$(mktemp -d "$WORK/run.XXXXXX")"
. tests/linux/reap.sh
reap_track "$W/reaped"
cleanup() { rm -rf "$W"; }
reap_on_exit cleanup

BIN="${BROWSER_PAINTS_BIN_DIR:-$W/bin}"
mkdir -p "$BIN"
if [ -z "${BROWSER_PAINTS_BIN_DIR:-}" ]; then
    for t in wsysd:user/wsysd.ad hambrowse:user/hambrowse.ad; do
        n="${t%%:*}"; s="${t#*:}"
        ./scripts/hamlinux_build.sh "$s" "$BIN/$n" >"$W/$n.build.log" 2>&1 || {
            bad "could not build $s"; tail -15 "$W/$n.build.log"; exit 1; }
    done
fi

echo "== does the browser put a page on the screen?"
info "$(priv_ns_describe)"

export HAMWSYS="$W/seg" HAMWSYS_BB="$W/bb" HAMWSYS_IMG="$W/img"
export HAMFB_FILE="$W/fb" HAMFB_GEOM=1280x800
: >"$W/input.evdev"; export HAMWSYSD_INPUT="$W/input.evdev"
mkdir -p "$W/noicd"; export VK_ICD_FILENAMES="$W/noicd/none.json"

cat >"$W/page.html" <<'HTML'
<html><body><h1>BROWSERPAINTS</h1><p>a page with a white background</p></body></html>
HTML

"$BIN/wsysd" </dev/null >"$W/wsysd.log" 2>&1 &
reap_add $!
for _ in $(seq 1 80); do [ -s "$HAMFB_FILE" ] && break; sleep 0.1; done
[ -s "$HAMFB_FILE" ] || { bad "wsysd never produced a framebuffer"; exit 1; }

"$BIN/hambrowse" "file://$W/page.html" </dev/null >"$W/browse.log" 2>&1 &
reap_add $!
sleep 7

WHITE="$(python3 - "$HAMFB_FILE" <<'PY'
import sys
d=open(sys.argv[1],'rb').read()
print(d.count(b'\xff\xff\xff'))
PY
)"
info "page-background pixels in the framebuffer: $WHITE"
# A blank window is the compositor's 0x1C1C1C fill and has no white in it at
# all; a painted page is hundreds of thousands of pixels. The threshold is far
# below what a real page produces (measured: 468,480) and far above noise.
if [ "${WHITE:-0}" -gt 50000 ] 2>/dev/null; then
    ok "THE BROWSER PAINTS: $WHITE page-background pixels reached the framebuffer"
else
    bad "THE BROWSER PAINTED NOTHING: only $WHITE page-background pixels."\
        "A v2 window whose blits are refused shows the compositor's grey --"\
        "check whether draw/ctl is refusing a full-sized record (EMSGSIZE)."
fi

if grep -q 'paints .*x0 of its' "$W/wsysd.log"; then
    bad "THE COMPOSITOR REPORTS IT AS PAINTING NOTHING while it is painting"\
        "$WHITE pixels: $(grep -m1 'paints .*x0 of its' "$W/wsysd.log")."\
        "report_uncovered() measures the rasterized SCENE, and a v2 window's"\
        "content comes from its backbuffer instead -- the measurement is of the"\
        "wrong thing, exactly as it is for a keyed or blended window."
else
    ok "and the compositor does not claim it paints nothing -- no scene-coverage warning for a window whose pixels come from its backbuffer"
fi

echo
echo "de_browser_paints: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || { echo "FAIL de_browser_paints"; exit 1; }
echo "PASS de_browser_paints"
