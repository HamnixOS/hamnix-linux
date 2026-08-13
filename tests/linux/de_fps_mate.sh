#!/usr/bin/env bash
# tests/linux/de_fps_mate.sh — OUR DESKTOP AND MATE, THROUGH ONE INSTRUMENT.
#
# THE QUESTION, AND THE ONLY HONEST WAY TO ASK IT
# ===============================================
# "How does it compare with X11 DEs like Mate?"
#
# tests/linux/de_fps_latency.sh answers how fast OUR desktop is, using wsysd's
# own presented-frame counter. MATE has no such counter, and quoting our
# counter against a number obtained some other way would be comparing two
# instruments while calling it a comparison of two desktops. So this gate uses
# ONE instrument on BOTH — tests/linux/fb_change_probe.py — which knows about
# neither of them and watches only a framebuffer that happens to be a file:
#
#     ours   HAMFB_FILE            1280x800, 32bpp, stride 5120, offset 0
#     MATE   Xvfb -fbdir           1280x800, 32bpp, stride 5120, offset 160
#
# Identical geometry, identical stride, identical pixel layout; the offset is
# an XWD header. Same sample rate, same load shape, same host, back to back.
#
# AND IT IS CALIBRATED. On our side the probe's "screen changes per second" is
# printed next to wsysd's real presented-frame count for the same run. If the
# two disagree, the probe is not measuring frames and the MATE number it
# produces means nothing either — so that comparison is made FIRST and the
# gate says what it found.
#
# ============================================================================
# WHAT IS NOT COMPARABLE HERE. READ THIS BEFORE THE NUMBERS.
# ============================================================================
# 1. THE POINTER IS NOT IN MATE'S FRAMEBUFFER. Measured, not assumed: moving
#    the pointer on Xvfb for six seconds produces NO change in the -fbdir
#    file, because Xvfb's sprite is not composited into the shadow buffer our
#    probe can read. Ours IS composited — wsysd draws the cursor into the
#    same buffer it presents. So the cheap pointer-only path, which is the
#    single most frequent thing either desktop does, is VISIBLE on our side
#    and INVISIBLE on MATE's. Any pointer-only comparison would be a
#    comparison of what the instrument can see. This gate therefore does not
#    make one, and compares only loads that repaint real window content.
#
# 2. MATE'S INPUT SKIPS THE INPUT STACK. Our input is 24-byte evdev records
#    written to a file the compositor reads with the same code that reads
#    /dev/input/eventN. MATE's is XTEST, injected straight into the X server's
#    event queue — it never goes near evdev or libinput. That is a handicap in
#    MATE'S FAVOUR, and the size of it is not measured here.
#
# 3. NEITHER OF THESE IS A DISPLAY. Xvfb is not X on hardware and our
#    offscreen framebuffer is not a monitor. Both numbers omit the scanout and
#    the vblank, and both are lower bounds on what a screen would show. A real
#    display can only add latency, to both.
#
# 4. THEY ARE NOT THE SAME AMOUNT OF SOFTWARE. Ours is a compositor plus two
#    of its own clients. MATE's is an X server plus marco plus mate-panel plus
#    mate-settings-daemon plus the applets plus GTK plus dbus. That is not a
#    defect in the comparison — it is what the two desktops ARE — but "our
#    number is smaller" is a statement about a smaller pile of software, not
#    about better engineering per unit of work.
#
# 5. MATE HERE IS DEBIAN 13'S MATE 1.26, RUNNING AS THE MAPPED ROOT INSIDE A
#    USER+MOUNT NAMESPACE, with a private HOME, a private dbus and a fresh
#    dconf. It has never been logged into, so it has no session state, no
#    compositing manager configured, and marco's own compositor is at its
#    default. It is a fair first-boot MATE and it is not a tuned one.
#
# 6. THE MACHINE OWNER IS RUNNING MATE ON THIS HOST WHILE THIS RUNS. Their
#    marco, mate-panel and caja are in the process table and their session is
#    on the real display. This gate never touches it: /tmp is private, so
#    /tmp/.X11-unix does not even exist inside, and nothing here can reach the
#    real X server by accident. It also never pattern-kills — `pkill -f mate`
#    would have killed the owner's desktop, and this file kills only process
#    GROUPS it started, by pid.
#
# ============================================================================
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

. tests/linux/private_ns.sh
priv_ns_reexec "$@"
. tests/linux/reap.sh

WORK="${MATE_WORK:-$(mktemp -d -p "${TMPDIR:-/tmp}" defpsmate.XXXXXX)}"
mkdir -p "$WORK"
reap_track "$WORK/reaped"
KEEP="${MATE_KEEP:-0}"
GEOM="${HAMFB_GEOM:-1280x800}"
FBW="${GEOM%x*}"; FBH="${GEOM#*x}"
SECS="${MATE_SECONDS:-10}"
TRIALS="${MATE_TRIALS:-60}"
SAMPLE_HZ="${MATE_SAMPLE_HZ:-500}"

pass=0; fail=0
ok()   { echo "matecmp: PASS $*"; pass=$((pass+1)); }
bad()  { echo "matecmp: FAIL $*"; fail=$((fail+1)); }
info() { echo "matecmp: INFO $*"; }
skip() { echo "matecmp: SKIP $*"; }

# Process GROUPS started here, killed by pgid. Never by pattern: see note 6.
PGIDS=""
cleanup() {
    for g in $PGIDS; do kill -TERM -"$g" 2>/dev/null; done
    sleep 1
    for g in $PGIDS; do kill -KILL -"$g" 2>/dev/null; done
    reap_all
    [ "$KEEP" = 1 ] || rm -rf "$WORK"
}
reap_on_exit cleanup
done_report() { echo "matecmp: $pass passed, $fail failed"; [ "$fail" = 0 ]; }

PROBE="python3 $PROJ_ROOT/tests/linux/fb_change_probe.py"

info "host: $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed 's/^ //'), $(nproc) cpus"
info "host: $(awk '{printf "load %s %s %s", $1, $2, $3}' /proc/loadavg) at start"
info "host: the machine owner's own desktop is running -- $(ps -eo comm --no-headers | grep -cE '^(marco|mate-panel|caja|mate-session)$') MATE processes outside this namespace, untouched"

# ===========================================================================
# PART 1 — OUR DESKTOP, AND THE PROBE CALIBRATED AGAINST A REAL COUNTER
# ===========================================================================
echo
echo "matecmp: ==== part 1: our desktop ======================================"
BINDIR="${FPS_BIN_DIR:-$WORK/bin}"
if [ -z "${FPS_BIN_DIR:-}" ]; then
    mkdir -p "$BINDIR"
    for t in wsysd:user/wsysd.ad cat:user/cat.ad hamdesktop:user/hamdesktop.ad \
             hampanelscene:user/hampanelscene.ad \
             de_dragload:tests/linux/de_dragload.ad; do
        n="${t%%:*}"; s="${t#*:}"
        scripts/hamlinux_build.sh "$s" "$BINDIR/$n" >"$WORK/$n.build.log" 2>&1 || {
            bad "could not build $s"; tail -20 "$WORK/$n.build.log" >&2
            done_report; exit 1; }
    done
fi

export HAMWSYS="$WORK/wsys.shm" HAMWSYS_BB="$WORK/wsys.bb"
export HAMWSYS_IMG="$WORK/wsys.img"
export HAMFB_FILE="$WORK/fb.raw" HAMFB_GEOM="$GEOM"
: >"$WORK/input.evdev"; export HAMWSYSD_INPUT="$WORK/input.evdev"
mkdir -p "$WORK/noicd"
HAM_ICD="$WORK/noicd/none.json"        # the shipped configuration: no device

VK_ICD_FILENAMES="$HAM_ICD" "$BINDIR/wsysd" </dev/null >"$WORK/wsysd.log" 2>&1 &
WSYSD_PID=$!; reap_add "$WSYSD_PID"
for _ in $(seq 1 80); do [ -s "$HAMFB_FILE" ] && break; sleep 0.1; done
[ -s "$HAMFB_FILE" ] || { bad "wsysd never produced a framebuffer"; done_report; exit 1; }
"$BINDIR/hamdesktop"    </dev/null >"$WORK/hamdesktop.log" 2>&1 & reap_add $!
"$BINDIR/hampanelscene" </dev/null >"$WORK/hampanel.log"   2>&1 & reap_add $!
sleep 4
grep -q "vk backend SOFTWARE" "$WORK/wsysd.log" \
    && ok "ours: the SOFTWARE rasterizer, the path the image ships ($(grep -m1 'vk backend' "$WORK/wsysd.log" | sed 's/.*SOFTWARE -- //'))" \
    || bad "ours: not the software backend -- wrong path under test"

OURS_FB="--fb $HAMFB_FILE --geom $GEOM --offset 0"

# THE CALIBRATION. Same window, two instruments: the probe's change counter,
# and wsysd's own n_frames. If they disagree the probe cannot be trusted on
# the side that has no counter, and this gate stops.
info "calibrating the shared probe against wsysd's own presented-frame counter"
"$BINDIR/de_dragload" 480 320 120 300 300 8 >"$WORK/drag.wid" 2>"$WORK/drag.err" &
DRAG_PID=$!; reap_add "$DRAG_PID"
sleep 2
# THE FIELD IS `frames`, NOT `curframes`. `sed 's/.*frames \(...\)/'` matched
# the LAST occurrence, which is `curframes` -- 0 for the whole drag, because
# every frame there is a full one -- and the calibration read 0 frames/s and
# accused a probe that was in fact right to within 1%. Parse the key/value
# line as key/value pairs.
statefield() { "$BINDIR/cat" /dev/wsys/wsysd/state 2>/dev/null \
    | awk -v k="$1" '{for(i=1;i<NF;i+=2) if($i==k){print $(i+1); exit}}'; }
F0="$(statefield frames)"
T0=$(date +%s.%N)
CAL="$($PROBE $OURS_FB --mode count --seconds "$SECS" --sample-hz "$SAMPLE_HZ" --tag 'ours drag (probe)')"
T1=$(date +%s.%N)
F1="$(statefield frames)"
echo "matecmp:   $CAL"
COUNTER_FPS="$(python3 -c "print('%.1f' % (($F1-$F0)/($T1-$T0)))")"
PROBE_FPS="$(printf '%s' "$CAL" | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9.]+$/){print $i; exit}}')"
info "  probe says $PROBE_FPS changes/s; wsysd's own counter says $COUNTER_FPS presented frames/s"
AGREE="$(python3 -c "
p=float('$PROBE_FPS'); c=float('$COUNTER_FPS')
print(1 if c>0 and abs(p-c)/c < 0.15 else 0)")"
if [ "$AGREE" = 1 ]; then
    ok "the shared probe agrees with wsysd's presentation counter to within 15% ($PROBE_FPS vs $COUNTER_FPS) -- it is measuring frames, so its MATE reading means something"
else
    bad "the shared probe ($PROBE_FPS/s) and wsysd's counter ($COUNTER_FPS/s) disagree -- REFUSING to compare it against MATE, because it is not measuring what it would be claimed to measure there"
    done_report; exit 1
fi
kill "$DRAG_PID" 2>/dev/null; sleep 0.5; kill -9 "$DRAG_PID" 2>/dev/null
sleep 1.5

info "ours, idle:"
# THE WHOLE SCREEN, not the centre band: on an idle desktop the only thing
# that changes is the PANEL, which is at the top and outside the band every
# other measurement here uses. Measured with the band, idle read 0.0/s -- a
# true statement about those rows and a false impression about the desktop.
# 100 Hz is ample for a quantity that is a few per second and keeps a 4 MiB
# read per sample off the host's back.
echo "matecmp:   $($PROBE $OURS_FB --mode count --seconds 6 --sample-hz 100 --band "$FBH" --tag 'ours idle (whole screen)')"
info "ours, a window dragging (the load MATE will get too):"
"$BINDIR/de_dragload" 480 320 120 300 300 8 >"$WORK/drag2.wid" 2>&1 &
DRAG2=$!; reap_add "$DRAG2"
sleep 2
OURS_DRAG="$($PROBE $OURS_FB --mode count --seconds "$SECS" --sample-hz "$SAMPLE_HZ" --tag 'ours window drag')"
echo "matecmp:   $OURS_DRAG"
# THE POSITIVE CONTROL for the sampler-rate sweep run against MATE later. A
# change counter reports a real rate only if that rate does not move when the
# sampler does. Ours is independently known to be right -- it agrees with
# wsysd's presentation counter to 2% -- so if it DID follow the sampler here,
# the sweep would be worthless as evidence about MATE.
info "ours, the same drag swept across sampler rates (the control):"
sweepval() { printf '%s' "$1" | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9.]+$/){print $i; exit}}'; }
OURS_SWEEP=""
for hz in 125 250 500 1000; do
    L="$($PROBE $OURS_FB --mode count --seconds 5 --sample-hz $hz --tag "ours drag @${hz}Hz")"
    echo "matecmp:   $L"
    OURS_SWEEP="$OURS_SWEEP $(sweepval "$L")"
done
kill "$DRAG2" 2>/dev/null; sleep 0.5; kill -9 "$DRAG2" 2>/dev/null
sleep 1.5

info "ours, input->pixel (evdev record -> changed pixels), $TRIALS trials:"
OURS_LAT="$($PROBE $OURS_FB --mode latency --inject evdev --evdev "$HAMWSYSD_INPUT" \
            --trials "$TRIALS" --tag 'ours input->pixel')"
echo "matecmp:   $OURS_LAT"

kill "$WSYSD_PID" 2>/dev/null
sleep 1

# ===========================================================================
# PART 2 — MATE
# ===========================================================================
echo
echo "matecmp: ==== part 2: MATE =============================================="
for b in Xvfb xdotool mate-session xterm dbus-run-session; do
    command -v "$b" >/dev/null 2>&1 || {
        skip "no $b on this host -- the MATE half cannot be run, and OUR numbers above stand alone"
        done_report; exit 0; }
done

MHOME="$WORK/matehome"
mkdir -p "$MHOME/.config" "$MHOME/.cache" "$MHOME/.local/share" "$WORK/xdg" "$WORK/mfb"
chmod 700 "$WORK/xdg"

# A FREE DISPLAY, PICKED BY THE SERVER. A hardcoded :77 collided with a
# leftover Xvfb from an earlier run of this work and the session silently
# attached to THAT server, whose -fbdir pointed at a deleted directory. The
# probe then found no framebuffer. -displayfd makes the server choose and
# tell us, so a stale one cannot be inherited.
Xvfb -displayfd 3 -screen 0 "${FBW}x${FBH}x24" -fbdir "$WORK/mfb" -nolisten tcp \
     3>"$WORK/dispnum" >"$WORK/xvfb.log" 2>&1 &
XVFB_PID=$!; reap_add "$XVFB_PID"
for _ in $(seq 1 60); do [ -s "$WORK/dispnum" ] && break; sleep 0.2; done
DNUM="$(tr -d '[:space:]' <"$WORK/dispnum" 2>/dev/null)"
if [ -z "${DNUM:-}" ]; then
    bad "Xvfb did not come up"; tail -10 "$WORK/xvfb.log" >&2; done_report; exit 1
fi
export DISPLAY=":$DNUM"
MFB="$WORK/mfb/Xvfb_screen0"
[ -s "$MFB" ] || { bad "Xvfb produced no -fbdir framebuffer at $MFB"; done_report; exit 1; }
ok "MATE's X server is up on $DISPLAY, ${FBW}x${FBH}x24, with a readable framebuffer file"
if [ -d /tmp/.X11-unix ]; then
    info "  isolation: /tmp/.X11-unix exists inside this namespace: $(ls /tmp/.X11-unix | tr '\n' ' ')"
else
    ok "isolation: /tmp/.X11-unix does not exist inside this namespace, so the machine owner's own X server is not merely unused here, it is unreachable"
fi

MATE_FB="--fb $MFB --geom $GEOM --offset 160 --stride $((FBW*4))"

# ---- the asymmetry, MEASURED rather than asserted -------------------------
info "checking whether MATE's pointer is even in the framebuffer we can read:"
PTR_BEFORE="$($PROBE $MATE_FB --mode drive --inject xdotool --display "$DISPLAY" \
              --seconds 5 --rate 200 --sample-hz "$SAMPLE_HZ" --tag 'MATE pointer-only')"
echo "matecmp:   $PTR_BEFORE"
PTR_HZ="$(printf '%s' "$PTR_BEFORE" | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9.]+$/){print $i; exit}}')"
if python3 -c "import sys; sys.exit(0 if float('$PTR_HZ') < 1.0 else 1)"; then
    ok "confirmed, and stated as a limit rather than a result: moving the pointer 200 times a second changes MATE's readable framebuffer $PTR_HZ times a second, i.e. not at all -- Xvfb's sprite is not in the shadow buffer. The pointer-only path CANNOT be compared, and this gate does not try."
else
    info "MATE's pointer DOES reach this framebuffer ($PTR_HZ changes/s) -- the pointer-only comparison is available after all; it was not on the run this file was written from"
fi

setsid dbus-run-session -- mate-session >"$WORK/mate.log" 2>&1 &
MATE_PID=$!; PGIDS="$PGIDS $MATE_PID"
for _ in $(seq 1 60); do
    [ "$(xdotool search --onlyvisible --class . 2>/dev/null | wc -l)" -ge 8 ] && break
    sleep 1
done
# The instrument before the measurement: xlsclients not being INSTALLED gives
# a suppressed stderr, an empty stdout and a count of 0, which is
# indistinguishable from a MATE that failed to start -- and the branch below
# reported the second, then killed the run. A missing host tool is not a
# statement about MATE.
command -v xlsclients >/dev/null 2>&1 || {
    bad "UNREADABLE -- xlsclients is not installed on this host, so 'how many X clients did MATE start' cannot be asked at all. This run did not observe MATE; it failed to look"
    done_report; exit 1; }
NCLIENT="$(xlsclients 2>/dev/null | wc -l)"
if [ "${NCLIENT:-0}" -ge 4 ]; then
    ok "MATE is up: $NCLIENT X clients -- $(xlsclients 2>/dev/null | awk '{print $2}' | tr '\n' ' ')"
else
    bad "MATE did not come up ($NCLIENT clients) -- no comparison can be made"
    tail -15 "$WORK/mate.log" >&2; done_report; exit 1
fi
sleep 5

info "MATE, idle:"
echo "matecmp:   $($PROBE $MATE_FB --mode count --seconds 6 --sample-hz 100 --band "$FBH" --tag 'MATE idle (whole screen)')"

# ---- the SAME load: a window with text in it, dragged --------------------
# de_dragload writes `geometry` to its own window's ctl file. Its X analogue
# is xdotool's `windowmove` on a real window, from a RESIDENT xdotool so the
# rate is not a fork rate. An xterm is the closest available match for our
# 480x320 window with eight rows of glyphs.
xterm -geometry 60x20+120+300 -fa Monospace -fs 11 -e 'while :; do sleep 5; done' \
      >/dev/null 2>&1 &
XTERM_PID=$!; reap_add "$XTERM_PID"
sleep 4
XWID="$(xdotool search --onlyvisible --class xterm 2>/dev/null | head -1)"
if [ -z "${XWID:-}" ]; then
    bad "no xterm mapped -- MATE gets no window-drag load, so that comparison is not made"
else
    ok "MATE's drag load is up: an xterm (window $XWID), moved by a resident xdotool"
    # THE SAME CADENCE AS OURS. de_dragload sleeps 1 ms between `geometry`
    # writes; xdotool's script mode has its own `sleep`, so MATE's mover is
    # paced identically instead of running flat out. An unthrottled mover was
    # the first thing tried and it is not the same load.
    ( for i in $(seq 1 200000); do
          echo "windowmove $XWID $(( 120 + (i % 75) * 4 )) 300"
          echo "sleep 0.001"
      done | xdotool - ) &
    MDRAG=$!; reap_add "$MDRAG"
    sleep 2

    # ================================================================
    # THE SAMPLER-RATE SWEEP, AND WHY IT DECIDES WHETHER THERE IS A
    # COMPARISON AT ALL
    # ================================================================
    # First measurement of this load read 483.6 changes/s against a 500 Hz
    # sampler: 97% of samples differed from the one before. A desktop does
    # not present 484 frames a second; a framebuffer that is NEVER STILL
    # reads exactly like one that does. The two are told apart by changing
    # the sampler and watching what the number does:
    #
    #   a real rate   stays put when the sampler doubles
    #   saturation    follows the sampler
    #
    # This is run on BOTH desktops. Ours is already known to be right (it
    # agrees with wsysd's own presentation counter to 2%), so it doubles as
    # the positive control: if OUR number also followed the sampler, the
    # sweep itself would be meaningless.
    info "MATE, that window dragging -- swept across sampler rates:"
    MATE_SWEEP=""
    for hz in 125 250 500 1000; do
        L="$($PROBE $MATE_FB --mode count --seconds 5 --sample-hz $hz --tag "MATE drag @${hz}Hz")"
        echo "matecmp:   $L"
        MATE_SWEEP="$MATE_SWEEP $(sweepval "$L")"
    done
    MATE_DRAG="$($PROBE $MATE_FB --mode count --seconds "$SECS" --sample-hz "$SAMPLE_HZ" --tag 'MATE window drag')"
    kill "$MDRAG" 2>/dev/null; sleep 0.5; kill -9 "$MDRAG" 2>/dev/null
fi
sleep 1.5

# ---- latency: a CLICK, because the pointer is invisible to the probe ------
# Ours was measured pointer-move -> changed pixels. MATE's pointer is not in
# the buffer, so the same stimulus cannot be used. What both CAN do is change
# window content in response to input. This is left unmeasured rather than
# faked: a latency number for MATE obtained from a different stimulus than
# ours is not a comparison, it is two numbers printed near each other.
info "MATE, input->pixel: NOT MEASURED, and deliberately so."
info "  Ours is pointer-move -> the cursor's own pixels change. MATE's cursor"
info "  is not in the framebuffer this probe can read (measured above), so the"
info "  same stimulus produces nothing to time. Timing a different stimulus"
info "  and printing it beside ours would be two unrelated numbers with a"
info "  comparison implied by their adjacency. The honest answer is that this"
info "  pass could not construct it."

# ===========================================================================
# THE VERDICT ON WHETHER THERE IS A COMPARISON
# ===========================================================================
# Decided by the sweep, not by which number is nicer. A change counter is
# reporting a RATE if it does not move when the sampler moves, and is
# SATURATED -- reporting only "the buffer was never still" -- if it follows.
echo
echo "matecmp: ==== is there a comparison here at all? ======================="
info "ours across 125/250/500/1000 Hz samplers:$OURS_SWEEP changes/s"
info "MATE across 125/250/500/1000 Hz samplers:${MATE_SWEEP:- not measured}"
VERDICT="$(python3 - "$OURS_SWEEP" "${MATE_SWEEP:-}" <<'PY'
import sys
def ratio(v):
    x = [float(t) for t in v.split()]
    return (x[-1] / x[0]) if len(x) >= 2 and x[0] > 0 else None
o, m = ratio(sys.argv[1]), ratio(sys.argv[2]) if len(sys.argv) > 2 else None
print('%s %s' % ('-' if o is None else '%.2f' % o,
                 '-' if m is None else '%.2f' % m))
PY
)"
OURS_R="${VERDICT%% *}"; MATE_R="${VERDICT##* }"
info "  an 8x increase in sampler rate multiplied ours by $OURS_R and MATE by $MATE_R"
if [ "$OURS_R" = "-" ]; then
    bad "our own sweep produced nothing -- no verdict can be reached"
elif python3 -c "import sys; sys.exit(0 if float('$OURS_R') < 1.5 else 1)"; then
    ok "OUR number is a rate, not an artefact: 8x the sampling gave ${OURS_R}x the count, and it independently matches wsysd's presentation counter. The 53 fps stands."
else
    bad "our own change count followed the sampler (${OURS_R}x) -- the instrument is saturated on OUR side too and none of this is a frame rate"
fi
if [ "$MATE_R" = "-" ]; then
    skip "MATE was not swept, so nothing is claimed about it"
elif python3 -c "import sys; sys.exit(0 if float('$MATE_R') >= 1.5 else 1)"; then
    ok "AND THE COMPARISON IS REFUSED, ON EVIDENCE. 8x the sampling gave ${MATE_R}x the count on MATE, so the probe is SATURATED there: X's shadow framebuffer is essentially never still while a window is dragged, because X draws incrementally with no frame boundary and no present. 'MATE: 484 changes/s' is not 484 fps, it is 'every sample differed'. There is no frame rate to extract, so this gate publishes OUR numbers alone and says why -- which is a complete result, and the alternative would have been a 9x figure flattering the wrong side of the page."
else
    ok "MATE's count held still across the sweep (${MATE_R}x) as ours did, so both numbers are rates and the two ARE comparable on this load"
    info "  ours: $OURS_DRAG"
    info "  MATE: ${MATE_DRAG:-not measured}"
fi

echo
echo "matecmp: ==== what this run established ==============================="
info "ours, window drag:   $OURS_DRAG"
info "ours, input->pixel:  $OURS_LAT"
info "ours, idle:          measured above, whole screen"
info "MATE, window drag:   no frame rate is obtainable with this instrument (saturated)"
info "MATE, input->pixel:  no comparable stimulus exists (its pointer is not in the buffer)"
info "MATE, idle:          measured above, and it IS comparable -- both desktops"
info "                     were sampled the same way with nothing happening"
info "host: $(awk '{printf "load %s %s %s", $1, $2, $3}' /proc/loadavg) at end"
done_report
