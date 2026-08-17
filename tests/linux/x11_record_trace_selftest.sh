#!/usr/bin/env bash
# Its host runtime and its pass/fail were NOT measured when this line was
# written. If you make it cheap enough for the battery, add the manifest line
# and delete this block.
#
# tests/linux/x11_record_trace_selftest.sh — DOES THE TRACER SEE WHAT THE
# CLIENT ACTUALLY GOT?
#
# tests/linux/x11_record_trace.c is the instrument that answers "what does
# Steam ask the X server for, and what does the server hand it back"
# (docs/steam_namespace.md §12.2d). An instrument whose failure mode is
# SILENCE cannot be pointed at a bug whose symptom is also silence: "Steam
# never selected the scroll events" and "the tracer recorded nothing" produce
# the identical empty log, and only one of them is an answer.
#
# So this runs both halves against a throwaway Xvfb, in one session:
#
#   * tests/linux/xi2_scroll_probe.c is the WATCHED client. It prints what it
#     received -- XI2 motion, XI2 button 4, XI2 button 5 -- from its own
#     connection.
#   * the tracer watches that same client over RECORD.
#
# The assertion is that the two agree. That control is not decoration: it is
# what caught the tracer's own first version recording NOTHING while the probe
# was receiving everything, because `delivered_events` had been asked for as
# two XRecordRanges (4..6 and 35..35) instead of one contiguous 4..35. Merged,
# it works; split, it is silent -- and silent is the wrong answer's shape.
#
# ~20 s, no VM, no Steam, no root, its own display number.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

WORK="${XRT_WORK:-$HOME/.hamnix-build/xrecordtrace}"
DPY="${XRT_DISPLAY:-:93}"
mkdir -p "$WORK"

pass=0; fail=0
ok()   { echo "xrt: PASS $*"; pass=$((pass+1)); }
bad()  { echo "xrt: FAIL $*"; fail=$((fail+1)); }
info() { echo "xrt: INFO $*"; }
done_report() { echo "xrt: $pass passed, $fail failed"; [ "$fail" = 0 ]; }

for t in Xvfb xdotool cc; do
    command -v "$t" >/dev/null || {
        echo "xrt: SKIP no $t on this host; this gate needs Xvfb, xdotool and a C compiler" >&2
        exit 2; }
done

cc -O2 -o "$WORK/rectrace" tests/linux/x11_record_trace.c -lX11 -lXtst 2>"$WORK/cc1.log" || {
    bad "cannot build x11_record_trace.c (need libx11-dev libxtst-dev)"
    sed 's/^/xrt:      /' "$WORK/cc1.log"; done_report; exit 1; }
cc -O2 -o "$WORK/xi2probe" tests/linux/xi2_scroll_probe.c -lX11 -lXi 2>"$WORK/cc2.log" || {
    bad "cannot build xi2_scroll_probe.c (need libx11-dev libxi-dev)"
    sed 's/^/xrt:      /' "$WORK/cc2.log"; done_report; exit 1; }
ok "both programs build"

Xvfb "$DPY" -screen 0 800x600x24 >"$WORK/xvfb.log" 2>&1 &
XV=$!
TR=""; PR=""
cleanup() { kill $PR $TR $XV 2>/dev/null; wait $XV 2>/dev/null; }
trap cleanup EXIT
# A bare EXIT trap does not run when the shell is killed by a signal, so a
# gate stopped by `timeout` (TERM) or ^C (INT) skipped its cleanup entirely.
# Re-exit on those, which makes the EXIT trap above run on every path out.
trap 'exit 130' INT TERM HUP
for _ in $(seq 1 40); do
    DISPLAY="$DPY" xdpyinfo >/dev/null 2>&1 && break
    sleep 0.25
done
DISPLAY="$DPY" xdpyinfo >/dev/null 2>&1 || {
    bad "Xvfb never came up on $DPY"; done_report; exit 1; }

DISPLAY="$DPY" "$WORK/rectrace" >"$WORK/trace.log" 2>&1 &
TR=$!
sleep 2
grep -q "attached to all clients" "$WORK/trace.log" \
    && ok "the tracer attached (RECORD $(sed -n 's/^rectrace: RECORD //p' "$WORK/trace.log"))" \
    || { bad "the tracer never attached"; sed 's/^/xrt:      /' "$WORK/trace.log"
         done_report; exit 1; }

DISPLAY="$DPY" "$WORK/xi2probe" 10 10 400 300 >"$WORK/probe.log" 2>&1 &
PR=$!
sleep 3
DISPLAY="$DPY" xdotool mousemove 100 100
sleep 1
DISPLAY="$DPY" xdotool click 4
sleep 1
DISPLAY="$DPY" xdotool click 5
sleep 3

# --- what the watched client says it got (the control) --------------------
pb4=$(grep -c '^XI2 button 4$' "$WORK/probe.log")
pb5=$(grep -c '^XI2 button 5$' "$WORK/probe.log")
pmo=$(grep -c '^XI2 motion$'   "$WORK/probe.log")
info "the watched client received: motion $pmo, button-4 $pb4, button-5 $pb5"
[ "$pb4" -ge 1 ] && [ "$pb5" -ge 1 ] && [ "$pmo" -ge 1 ] \
    && ok "CONTROL: the watched client really did receive XI2 motion and buttons 4 and 5" \
    || { bad "the watched client received nothing -- the display, not the tracer, is broken"
         sed 's/^/xrt:      /' "$WORK/probe.log"; done_report; exit 1; }

# --- and what the tracer saw of the same events ---------------------------
win=$(sed -n 's/^XI2 selected on window \([0-9]*\) .*/\1/p' "$WORK/probe.log")
winhex=$(printf '0x%x' "${win:-0}")
info "the watched client's window is $winhex"

sel=$(grep -c "XISelectEvents win=$winhex" "$WORK/trace.log")
[ "$sel" -ge 1 ] \
    && ok "the tracer saw the XISelectEvents on $winhex" \
    || bad "the tracer never saw an XISelectEvents on $winhex"

grep -q "XISelectEvents win=$winhex" -A1 "$WORK/trace.log" &&
grep -A1 "XISelectEvents win=$winhex" "$WORK/trace.log" | grep -q "mask:.*Motion" \
    && ok "and decoded the mask, including Motion -- the bit a smooth-scroll client needs" \
    || bad "the mask under that XISelectEvents did not decode with Motion in it"

g4=$(grep -c "GOT XI2 ButtonPress dev=[0-9]* detail=4 win=$winhex" "$WORK/trace.log")
g5=$(grep -c "GOT XI2 ButtonPress dev=[0-9]* detail=5 win=$winhex" "$WORK/trace.log")
gm=$(grep -c "GOT XI2 Motion dev=[0-9]* detail=0 win=$winhex" "$WORK/trace.log")
info "the tracer saw DELIVERED to that client: motion $gm, button-4 $g4, button-5 $g5"
[ "$g4" -ge 1 ] && [ "$g5" -ge 1 ] \
    && ok "THE TRACER SEES WHAT THE CLIENT GETS: both wheel directions, on the client's own window" \
    || bad "the client received the wheel and the tracer did not record it -- the tracer is silent, not the client"
[ "$gm" -ge 1 ] \
    && ok "and it records delivered XI_Motion, which is how a smooth-scroll notch arrives" \
    || bad "no delivered XI_Motion was recorded although the client reported one"

dev=$(grep -c "cl=0x00000000 DEV " "$WORK/trace.log")
info "device-level (pre-delivery) events recorded: $dev"
[ "$dev" -ge 1 ] \
    && ok "and it separates DEVICE events (no recipient) from DELIVERED ones (a client and a window)" \
    || bad "no device-level events at all; the two categories cannot be told apart"

done_report
