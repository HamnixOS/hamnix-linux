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
# tests/linux/x11_geom_probe.sh — what does an X11 client actually SEE through
# our stack?
#
#   X11 client -> Xwayland -> wsyswl (Adder) -> /dev/wsys -> wsysd -> /dev/fb
#
# Steam's CEF creates its browser at (-2147483648, -2147483648) = INT32_MIN,
# which is what a toolkit uses when a geometry query gave it nothing. This
# probe asks the same questions CEF asks -- the X screen dimensions, the
# RandR monitor list, _NET_WORKAREA and the EWMH window-manager handshake --
# and prints the answers, so "our stack answers with garbage" stops being a
# hypothesis.
#
# It runs entirely offscreen (HAMFB_FILE) and uses the HOST's Xwayland, so it
# never touches the host's display and needs no VM.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

# THE MACHINE THIS RUNS ON IS NOT SCRATCH.
#
# It runs wsyswl and an X client; the Wayland socket and the X socket directory are
# both fixed names outside this gate.
#
# The names that matter are compiled into the binaries, not written here, so no
# care taken in this script can move them; the containment is the namespace.
# tests/linux/private_ns.sh has the table and the incident that bought it. This
# must come before anything that makes a file under /tmp, $WORK included, and
# before reap.sh, whose registry is itself a mktemp under /tmp.
. tests/linux/private_ns.sh
priv_ns_reexec "$@"

WORK="${X11GEOM_WORK:-$(mktemp -d -p "${TMPDIR:-/tmp}" x11geom.XXXXXX)}"
mkdir -p "$WORK"
GEOM="${HAMFB_GEOM:-1280x800}"
KEEP="${X11GEOM_KEEP:-0}"
export HAMWSYS="$WORK/wsys.shm"
export HAMFB_FILE="$WORK/fb.raw"
export HAMFB_GEOM="$GEOM"
# The v2 backbuffer segment defaults to /srv/wsys.bb then /dev/shm/... -- ONE
# FILE PER HOST, outliving every process that touches it, with slots keyed by
# wid. Two runs sharing it hand each other stale slots and each measures the
# other's last window. See docs/steam_namespace.md §6.2a and §11.
export HAMWSYS_BB="$WORK/wsys.bb"
# wsysd has a real Vulkan backend and this host has a real GPU in it that
# belongs to someone. Software ICD for anything offscreen.
[ -r /usr/share/vulkan/icd.d/lvp_icd.json ] && \
    export VK_ICD_FILENAMES="${VK_ICD_FILENAMES:-/usr/share/vulkan/icd.d/lvp_icd.json}"

pass=0; fail=0
ok()   { echo "x11geom: PASS $*"; pass=$((pass+1)); }
bad()  { echo "x11geom: FAIL $*"; fail=$((fail+1)); }
info() { echo "x11geom: INFO $*"; }

cleanup() {
    for p in $XCLIENTS $XWPID $WLPID $WSYSDPID; do
        [ -n "${p:-}" ] && kill "$p" 2>/dev/null
    done
    sleep 0.3
    for p in $XCLIENTS $XWPID $WLPID $WSYSDPID; do
        [ -n "${p:-}" ] && kill -9 "$p" 2>/dev/null
    done
    [ "$KEEP" = 1 ] || rm -rf "$WORK"
}
XCLIENTS=""; XWPID=""; WLPID=""; WSYSDPID=""
trap cleanup EXIT
# A bare EXIT trap does not run when the shell is killed by a signal, so a
# gate stopped by `timeout` (TERM) or ^C (INT) skipped its cleanup entirely.
# Re-exit on those, which makes the EXIT trap above run on every path out.
trap 'exit 130' INT TERM HUP

command -v Xwayland >/dev/null || { echo "need Xwayland on the host" >&2; exit 1; }
command -v xdpyinfo >/dev/null || { echo "need xdpyinfo on the host" >&2; exit 1; }

for t in wsysd:user/wsysd.ad wsyswl:user/wsyswl.ad; do
    name="${t%%:*}"; src="${t#*:}"
    scripts/hamlinux_build.sh "$src" "$WORK/$name.elf" >"$WORK/$name.build.log" 2>&1 || {
        echo "FAIL could not build $src" >&2; tail -20 "$WORK/$name.build.log" >&2; exit 1; }
done

"$WORK/wsysd.elf" </dev/null >"$WORK/wsysd.log" 2>&1 &
WSYSDPID=$!
sleep 1.5

WSYSWL_VERBOSE=1 "$WORK/wsyswl.elf" "$WORK/wayland-0" </dev/null >"$WORK/wsyswl.log" 2>&1 &
WLPID=$!
for _ in $(seq 1 40); do [ -S "$WORK/wayland-0" ] && break; sleep 0.1; done
[ -S "$WORK/wayland-0" ] && ok "wsyswl is listening on a wayland socket" \
                         || { bad "wsyswl never created its socket"; cat "$WORK/wsyswl.log"; exit 1; }

# Xwayland, exactly as tests/linux/hamnix_x11session.sh starts it inside the
# namespace: -shm because there is no GL on the Wayland side.
export XDG_RUNTIME_DIR="$WORK"
export WAYLAND_DISPLAY=wayland-0
DISPNUM="${X11GEOM_DISPLAY:-:71}"
rm -f "/tmp/.X${DISPNUM#:}-lock" 2>/dev/null

# The geometry wsyswl published beside its socket -- the same file, read the
# same way, as tests/linux/hamnix_x11session.sh does inside the namespace.
GEOMOPT=""
if [ -r "$WORK/hamnix-screen" ]; then
    read -r PW PH < "$WORK/hamnix-screen" || true
    case "${PW:-}:${PH:-}" in
        [1-9]*:[1-9]*)
            ok "wsyswl published its screen size as a file (${PW}x${PH})"
            # -geometry only exists from Xwayland 23.1; bookworm's 22.1.9 dies
            # on it and is also the version that does not need it.
            if Xwayland -help 2>&1 | grep -q -- '-geometry'; then
                GEOMOPT="-geometry ${PW}x${PH}"
            else
                info "this Xwayland has no -geometry; it must size itself from the wl_output"
            fi ;;
    esac
fi
[ -n "$GEOMOPT" ] || bad "wsyswl published no screen size beside its socket"

# shellcheck disable=SC2086
Xwayland -shm -noreset $GEOMOPT "$DISPNUM" >"$WORK/xwayland.log" 2>&1 &
XWPID=$!
export DISPLAY="$DISPNUM"
up=0
for _ in $(seq 1 80); do
    xdpyinfo >/dev/null 2>&1 && { up=1; break; }
    kill -0 "$XWPID" 2>/dev/null || break
    sleep 0.25
done
[ "$up" = 1 ] && ok "Xwayland came up on $DISPNUM through wsyswl" \
              || { bad "Xwayland did not come up"; tail -20 "$WORK/xwayland.log"; exit 1; }

WANT_W="${GEOM%x*}"; WANT_H="${GEOM#*x}"

echo "x11geom: === the X screen, as every client sees it"
xdpyinfo | sed -n '/^screen #0/,/^  number of visuals/p' | head -20
DIMS=$(xdpyinfo | sed -n 's/^  dimensions: *\([0-9]*\)x\([0-9]*\) pixels.*/\1 \2/p' | head -1)
SW="${DIMS%% *}"; SH="${DIMS##* }"
info "X screen dimensions = ${SW}x${SH} (compositor output is ${WANT_W}x${WANT_H})"
if [ "${SW:-0}" -gt 0 ] && [ "${SH:-0}" -gt 0 ]; then
    ok "the X screen has a nonzero size"
else
    bad "the X screen has no size at all -- ${SW}x${SH}"
fi
if [ "${SW:-0}" = "$WANT_W" ] && [ "${SH:-0}" = "$WANT_H" ]; then
    ok "the X screen matches the compositor's output size"
else
    bad "the X screen is ${SW}x${SH}, the compositor output is ${WANT_W}x${WANT_H}"
fi

RES=$(xdpyinfo | sed -n 's/^  resolution: *\([0-9]*x[0-9]*\) dots per inch.*/\1/p' | head -1)
MM=$(xdpyinfo | sed -n 's/^  dimensions:.*(\(.*\) millimeters).*/\1/p' | head -1)
info "physical size = ${MM:-?} mm, resolution = ${RES:-?} dpi"
case "${RES:-}" in
    9[0-9]x9[0-9]|1[0-9][0-9]x1[0-9][0-9]|[7-8][0-9]x[7-8][0-9])
        ok "the reported DPI is in a sane range (${RES})" ;;
    *)  bad "the reported DPI is ${RES:-none} -- a toolkit scales its window by this" ;;
esac

if command -v xrandr >/dev/null 2>&1; then
    echo "x11geom: === RandR, which is how a modern toolkit enumerates monitors"
    xrandr --query 2>&1 | head -12
    if xrandr --query 2>/dev/null | grep -q ' connected'; then
        ok "RandR reports at least one connected output"
    else
        bad "RandR reports NO connected output -- a toolkit asking 'which monitor am I on' gets nothing"
    fi
else
    info "no xrandr on the host; skipping the RandR questions"
fi

echo "x11geom: === EWMH: is anything managing these windows?"
# The session inside the namespace runs jwm (docs/linux_window_manager.md); the
# list below is tried in that order so that, on a host which happens to have
# it, this probe asks the EWMH questions of the same window manager the
# namespace runs rather than of whatever else is installed. The host
# usually has no window manager to stand in for it, so with none started the
# EWMH answers below are the answers a client gets from a BARE X server --
# reported, but not counted as our failure. tests/linux/hamnix_xdiag.sh asks
# the same questions inside the namespace, where the session's own window
# manager is actually running.
WM=""
for w in jwm openbox twm matchbox-window-manager; do
    command -v "$w" >/dev/null 2>&1 && { WM="$w"; break; }
done
if [ -n "$WM" ]; then
    $WM >"$WORK/wm.log" 2>&1 &
    XCLIENTS="$XCLIENTS $!"
    sleep 2
    info "started $WM as the window manager"
    WMFAIL=bad
else
    info "no window manager available on this host; the EWMH answers below are a bare X server's"
    WMFAIL=info
fi
if command -v xprop >/dev/null 2>&1; then
    xprop -root _NET_SUPPORTING_WM_CHECK _NET_WORKAREA _NET_DESKTOP_GEOMETRY \
                _NET_CURRENT_DESKTOP _NET_SUPPORTED 2>&1 | cut -c1-160
    if xprop -root _NET_SUPPORTING_WM_CHECK 2>/dev/null | grep -q 'window id'; then
        ok "_NET_SUPPORTING_WM_CHECK is set -- a window manager is present"
    else
        $WMFAIL "no _NET_SUPPORTING_WM_CHECK -- nothing is managing X windows"
    fi
    if xprop -root _NET_WORKAREA 2>/dev/null | grep -q '='; then
        ok "_NET_WORKAREA is published"
    else
        $WMFAIL "_NET_WORKAREA is not published -- a client asking for the usable area gets nothing"
    fi
else
    info "no xprop on the host; skipping the EWMH questions"
fi

echo "x11geom: === what a client that maps a window actually gets"
if command -v xterm >/dev/null 2>&1; then
    xterm -geometry 80x24+40+40 -e sleep 30 >"$WORK/xterm.log" 2>&1 &
    XCLIENTS="$XCLIENTS $!"
    sleep 3
    xwininfo -root -children 2>&1 | head -20
fi

# THE QUESTION THAT ACTUALLY MATTERS FOR STEAM. Steam's UI is CEF, which is
# Chromium. If a plain Chromium maps a window through this path and its pixels
# reach the framebuffer, then "Steam shows no window" is not a defect of the
# window path -- and the search moves inside Steam. Skipped when there is no
# Chromium on the host; nothing about it touches the host's display.
if command -v chromium >/dev/null 2>&1 && [ "${X11GEOM_CHROMIUM:-1}" = 1 ]; then
    echo "x11geom: === Chromium, which is what Steam's UI is made of"
    rm -rf "$WORK/chromeprof"
    LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe \
    chromium --user-data-dir="$WORK/chromeprof" --no-sandbox --disable-gpu \
             --disable-dev-shm-usage --no-first-run \
             --window-size=1000,600 --window-position=100,80 \
             about:blank >"$WORK/chromium.log" 2>&1 &
    XCLIENTS="$XCLIENTS $!"
    sleep 20
    if xwininfo -root -children 2>/dev/null | grep -q 'Chromium'; then
        ok "Chromium mapped a toplevel through Xwayland -> wsyswl -> wsys"
    else
        bad "Chromium mapped no toplevel -- the window path cannot carry CEF"
    fi
    # Pixels, not just a window id. The framebuffer is a plain file here, so
    # "did the user see it" is a question with a literal answer.
    if python3 - "$HAMFB_FILE" "$SW" "$SH" <<'PY'
import sys, collections
d = open(sys.argv[1], 'rb').read()
w, h = int(sys.argv[2]), int(sys.argv[3])
c = collections.Counter(d[i:i+4] for i in range(0, min(len(d), w*h*4), 4))
white = sum(n for px, n in c.items() if px[0] > 0xe0 and px[1] > 0xe0 and px[2] > 0xe0)
print("x11geom: INFO %d framebuffer pixels are near-white (a browser page is)" % white)
sys.exit(0 if white > 50000 else 1)
PY
    then
        ok "Chromium's pixels reached the scanout framebuffer"
    else
        bad "no browser-shaped pixels in the framebuffer"
    fi
fi

echo "x11geom: $pass PASS, $fail FAIL"
[ "$fail" = 0 ]
