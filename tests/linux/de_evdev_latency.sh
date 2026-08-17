#!/usr/bin/env bash
# Its host runtime and its pass/fail were NOT measured when this line was
# written. If you make it cheap enough for the battery, add the manifest line
# and delete this block.
#
# tests/linux/de_evdev_latency.sh — INPUT-TO-PIXEL LATENCY WHEN THE INPUT IS A
# CHARACTER DEVICE, WHICH IS WHAT A REAL MOUSE IS.
#
# THE GAP THIS CLOSES
# ===================
# tests/linux/de_fps_latency.sh measures the compositor offscreen with its
# input coming from a PLAIN FILE named by HAMWSYSD_INPUT. That is the right
# shape for a gate — it is byte-identical evdev and it touches no real device —
# but it is not the fd class a real machine uses, and after `user/wsysd.ad`
# started WAITING on its input fds the difference stopped being cosmetic:
#
#   a regular file   poll(2) says READABLE ALWAYS, whatever the offset, so
#                    sys_waitfds had to grow a fourth class for it (readiness
#                    is "offset behind EOF", the sleep is an inotify watch).
#   a character dev  the ordinary poll(2) branch — no inotify, no size check.
#
# So every latency number this tree had was measured through the arm that
# exists FOR the gates, and the arm a person's mouse uses was unmeasured. This
# gate measures that arm.
#
# WHY A pty AND NOT /dev/input/eventN
# ===================================
# Because on a developer host the real thing is not reachable, and both routes
# were tried rather than assumed — see the header of de_evdev_probe.c, and
# `de_evdev_probe --uinput-check`, which reproduces the blocker on demand:
#
#   * /dev/input/event* are root:input 0640 and an ordinary user is not in
#     group `input`. Reading the machine owner's keyboard is also not something
#     a test may do, and EVIOCGRAB would take their console away.
#   * /dev/uinput usually IS available to the seat user, and a virtual pointer
#     really can be created — but udev puts no uaccess ACL on a virtual device,
#     so the /dev/input/eventN it produces is root:input 0640 as well and
#     neither the probe nor wsysd can open it.
#
# CHECKED ON THIS HOST, WITH open(2) AND NOT WITH THE MODE BITS: all 13
# /dev/input/event* are root:input 0660, none carries an ACL for the invoking
# user, and open(2) fails on every one — with the X session DOWN and the user
# logged in at tty1 on seat0, so this is not something a session change fixes.
#
# TO CLOSE THE GAP FOR REAL, one of these has to be true of the machine, and
# both are the owner's call and not a test's:
#     usermod -aG input <user>          (then log in again), or
#     a udev rule giving the uinput-created device uaccess/mode 0660 to the
#     seat user, e.g. matching ATTRS{name}=="hamnix-latency-probe".
# When either holds, `--uinput-check` prints READABLE, this gate says so, and
# the probe should be taught to prefer that node over the pty — the device is
# already created and named for exactly that purpose.
#
# A pty slave is what is left, and it is worth exactly this much: to
# sys_waitfds it is INDISTINGUISHABLE from an evdev node — devtab_find misses
# it, fstat says S_ISCHR so it is not the regular-file class, and it goes into
# the same pfd[] slot and the same poll(2). Put in raw mode it carries the
# 24-byte records byte for byte. What it is NOT is the USB/HID transport or the
# evdev driver's own buffering, and no claim is made about those.
#
# THE INSTRUMENT ANSWERS FOR ITSELF BEFORE ANY NUMBER IS REPORTED: the pixel
# watcher must not fire with nothing injected, and a compositor deliberately
# SIGSTOPped for 100 and 250 ms must MEASURE 100 and 250 ms slower. The settle
# is jittered, and the un-jittered probe is run beside it as a control, because
# a constant settle that is a whole number of ticks phase-locks the measurement
# — that mistake reported a median 8x too good once already in this tree.
#
# IDLE IS A PASS/FAIL HERE. A pollable fd that got misclassified would turn the
# park into a busy spin, and a spin is exactly the failure that reports a
# FLATTERING latency while burning a core. So idle CPU is sampled from
# /proc/<pid>/stat over a fixed wall interval (never `ps pcpu`, a LIFETIME
# average that has misreported this tree twice) and the gate FAILS on a spin.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"
. tests/linux/private_ns.sh
priv_ns_reexec "$@"
. tests/linux/reap.sh

WORK="${EVLAT_WORK:-$(mktemp -d -p "${TMPDIR:-/tmp}" evlat.XXXXXX)}"
mkdir -p "$WORK"
reap_track "$WORK/reaped"
TRIALS="${EVLAT_TRIALS:-60}"
IDLE_S="${EVLAT_IDLE_SECONDS:-20}"
GEOM="${HAMFB_GEOM:-1280x800}"

pass=0; fail=0
ok()   { echo "evlat: PASS $*"; pass=$((pass+1)); }
bad()  { echo "evlat: FAIL $*"; fail=$((fail+1)); }
info() { echo "evlat: INFO $*"; }
cleanup() { reap_all; [ "${EVLAT_KEEP:-0}" = 1 ] || rm -rf "$WORK"; }
reap_on_exit cleanup
done_report() { echo "evlat: $pass passed, $fail failed"; [ "$fail" = 0 ]; }

info "host: $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed 's/^ //')"
info "host: $(nproc) cpus, $(awk '{printf "load %s %s %s", $1, $2, $3}' /proc/loadavg)"

# ---- build ----------------------------------------------------------------
BINDIR="${EVLAT_BIN_DIR:-$WORK/bin}"
if [ -z "${EVLAT_BIN_DIR:-}" ]; then
    mkdir -p "$BINDIR"
    for t in wsysd:user/wsysd.ad cat:user/cat.ad; do
        n="${t%%:*}"; s="${t#*:}"
        scripts/hamlinux_build.sh "$s" "$BINDIR/$n" >"$WORK/$n.build.log" 2>&1 || {
            bad "could not build $s"; tail -20 "$WORK/$n.build.log" >&2
            done_report; exit 1; }
    done
    ok "the compositor builds"
else
    info "using prebuilt binaries from $BINDIR"
fi
cc -std=gnu11 -O1 -o "$WORK/probe" tests/linux/de_evdev_probe.c \
    >"$WORK/probe.build.log" 2>&1 || {
    bad "could not build tests/linux/de_evdev_probe.c"
    cat "$WORK/probe.build.log" >&2; done_report; exit 1; }
ok "the probe builds"

# ---- WHY THIS IS A pty, ON THE PAGE RATHER THAN IN A COMMENT --------------
info "why not a real evdev node, checked rather than asserted:"
UIC="$("$WORK/probe" --uinput-check 2>&1)"
info "  $UIC"
if echo "$UIC" | grep -q "READABLE by this user"; then
    info "  (this host DOES hand the user a usable virtual evdev node -- the"
    info "   pty below is then a weaker stand-in than it needs to be, and this"
    info "   gate should be taught to use it)"
fi

export HAMWSYS="$WORK/wsys.shm" HAMWSYS_BB="$WORK/wsys.bb"
export HAMWSYS_IMG="$WORK/wsys.img"
export HAMFB_FILE="$WORK/fb.raw" HAMFB_GEOM="$GEOM"
mkdir -p "$WORK/noicd"; export VK_ICD_FILENAMES="$WORK/noicd/none.json"

# ---- one run of the probe against one compositor --------------------------
# The probe MAKES the device, so it starts first and is told to go once the
# compositor is up against it.
run_probe() {
    local tag="$1"; shift
    rm -f "$WORK/go"; mkfifo "$WORK/go"
    "$WORK/probe" --fb "$HAMFB_FILE" --geom "$GEOM" "$@" \
        <"$WORK/go" >"$WORK/probe.out" 2>&1 &
    local probe=$!; reap_add "$probe"
    exec 9>"$WORK/go"
    local i
    for i in $(seq 1 100); do
        grep -q "probe: device" "$WORK/probe.out" && break; sleep 0.1
    done
    NODE="$(sed -n 's/^probe: device \([^ ]*\).*/\1/p' "$WORK/probe.out" | head -1)"
    if [ -z "$NODE" ]; then
        bad "[$tag] the probe made no input device"; cat "$WORK/probe.out"
        exec 9>&-; return 1
    fi
    # WHAT KIND OF FILE IT IS has to be asked while it EXISTS: a pty slave
    # goes away with its master, i.e. when the probe exits.
    DEVKIND="$(stat -c '%F' "$NODE" 2>/dev/null)"
    export HAMWSYSD_INPUT="$NODE"
    "$BINDIR/wsysd" </dev/null >"$WORK/wsysd.log" 2>&1 &
    WPID=$!; reap_add "$WPID"
    for i in $(seq 1 80); do [ -s "$HAMFB_FILE" ] && break; sleep 0.1; done
    if [ ! -s "$HAMFB_FILE" ]; then
        bad "[$tag] wsysd never produced a framebuffer"; cat "$WORK/wsysd.log"
        exec 9>&-; return 1
    fi
    sleep 1
    echo "go $WPID" >&9
    wait "$probe"
    local rc=$?
    exec 9>&-
    return $rc
}

# ---- 1. THE COMPOSITOR TAKES ITS INPUT FROM A CHARACTER DEVICE ------------
run_probe first --trials "$TRIALS" || { done_report; exit 1; }
LAT="$(grep -m1 'probe: n=' "$WORK/probe.out")"
if [ "$DEVKIND" = "character special file" ]; then
    ok "the compositor's input arrived on a $DEVKIND ($NODE) -- the poll(2) fd class a real evdev node uses, not the regular-file class the other gates use"
else
    bad "the input source is a '$DEVKIND', which is not the class this gate exists to measure"
fi
if grep -q "input from $NODE only" "$WORK/wsysd.log"; then
    ok "wsysd honoured HAMWSYSD_INPUT and opened no device of this host's"
else
    bad "wsysd did not honour HAMWSYSD_INPUT -- it may be reading this host's real input"
fi
WAITN="$(sed -n 's/^wsysd: wait set \([0-9]*\) fds.*/\1/p' "$WORK/wsysd.log" | head -1)"
if [ -n "$WAITN" ] && [ "$WAITN" -ge 1 ]; then
    ok "the character device is IN the wait set ($(grep -m1 'wait set' "$WORK/wsysd.log" | sed 's/^wsysd: //'))"
elif [ -n "$WAITN" ]; then
    bad "the wait set is EMPTY -- the compositor rejected the character device as always-ready and is back on its fallback tick"
else
    info "this wsysd prints no wait-set line: it predates the wake-on-input change, so the numbers below are the TICK's"
fi
info "input-to-pixel over the character device: ${LAT#probe: }"

# ---- 2. THE INSTRUMENT, BEFORE THE NUMBER IS BELIEVED ---------------------
echo
run_probe noinput --noinput || true
if grep -q "no-input  PASS" "$WORK/probe.out"; then
    ok "the pixel watcher does not fire on its own (1.5 s, nothing injected)"
else
    bad "the pixel watcher fired with no input -- it would report a latency for a frame nobody asked for"
fi
for ms in 100 250; do
    run_probe "stop$ms" --trials 6 --stop "$ms" || true
    MIN="$(sed -n 's/.*min \([0-9.]*\) .*/\1/p' "$WORK/probe.out" | head -1)"
    if [ -n "$MIN" ] && awk -v m="$MIN" -v s="$ms" 'BEGIN{exit !(m >= s*0.9)}'; then
        ok "a compositor SIGSTOPped ${ms} ms MEASURES ${MIN} ms -- the probe can report WORSE than the truth, not only better"
    else
        bad "a compositor SIGSTOPped ${ms} ms measured ${MIN:-nothing} -- the clock is not timing the frame"
    fi
done

# ---- 3. THE PHASE-LOCK CONTROL -------------------------------------------
echo
info "control: the same probe with the jitter removed. A constant settle that"
info "         happens to be a whole number of ticks measures ONE phase over"
info "         and over; against a tick that reads 8x too good or, as easily,"
info "         too bad. Against a loop with no tick the two agree."
run_probe nojitter --trials $(( TRIALS / 2 )) --nojitter || true
info "un-jittered: $(grep -m1 'probe: n=' "$WORK/probe.out" | sed 's/^probe: //')"

# ---- 4. IDLE IS PASS/FAIL ------------------------------------------------
echo
"$WORK/probe" --hold >"$WORK/hold.out" 2>&1 &
reap_add $!
for i in $(seq 1 100); do grep -q "probe: device" "$WORK/hold.out" && break; sleep 0.1; done
NODE="$(sed -n 's/^probe: device \([^ ]*\).*/\1/p' "$WORK/hold.out" | head -1)"
export HAMWSYSD_INPUT="$NODE"
"$BINDIR/wsysd" </dev/null >"$WORK/wsysd.idle.log" 2>&1 &
IPID=$!; reap_add "$IPID"
for i in $(seq 1 80); do [ -s "$HAMFB_FILE" ] && break; sleep 0.1; done
sleep 1
cpu_ticks() { awk '{s=substr($0,index($0,")")+2); split(s,f," "); print f[12]+f[13]}' "/proc/$IPID/stat"; }
parks()     { awk '/voluntary_ctxt_switches/{print $2; exit}' "/proc/$IPID/status"; }
HZ="$(getconf CLK_TCK)"
C0="$(cpu_ticks)"; P0="$(parks)"
sleep "$IDLE_S"
C1="$(cpu_ticks)"; P1="$(parks)"
IDLE_PCT="$(awk -v c=$((C1-C0)) -v hz="$HZ" -v s="$IDLE_S" 'BEGIN{printf "%.2f", c/hz/s*100}')"
PARKS="$(awk -v p=$((P1-P0)) -v s="$IDLE_S" 'BEGIN{printf "%.1f", p/s}')"
info "idle over ${IDLE_S} s with nothing injected: ${IDLE_PCT}% of one core, ${PARKS} parks/s (from /proc/$IPID/stat and /status, not ps pcpu)"
if awk -v v="$IDLE_PCT" 'BEGIN{exit !(v < 25)}'; then
    ok "the park on a character device is a real sleep: ${IDLE_PCT}% of one core at idle"
else
    bad "the compositor burns ${IDLE_PCT}% of one core with NOTHING happening -- the input fd is being reported ready when it is not, and the loop is spinning"
fi
if awk -v v="$PARKS" 'BEGIN{exit !(v < 200)}'; then
    ok "it goes round ${PARKS} times a second at idle, which is its fallback tick and not a spin"
else
    bad "it goes round ${PARKS} times a second with no input at all"
fi

echo
done_report
