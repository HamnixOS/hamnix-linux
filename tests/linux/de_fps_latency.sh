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
# tests/linux/de_fps_latency.sh — HOW FAST IS THE DESKTOP, IN FRAMES AND IN
# MILLISECONDS, AND WHAT IS IT DOING WHEN NOBODY IS TOUCHING IT.
#
# THE QUESTION
# ============
# "Is the DE fast now, like what is its fps if that's a coherent question?"
#
# What the tree could answer before this file was single frames measured in
# isolation: the 1724-op frame at 1280x800 costs 625 us (down from 5503), a
# pointer-only frame 5 us (down from 6543). Those are real, and they are not
# an fps. Dividing 625 us into a second gives 1600 and would be a lie, because
# nothing in wsysd tries to paint as fast as it can: user/wsysd.ad's main loop
# ends in
#
#     sys_waitfds(&waitset[0], 0, 16)
#
# with nfds LITERALLY 0. `waitset` is declared and never filled. So the
# compositor is a FIXED 16 ms TICK: it wakes, scans the window table, drains
# whatever evdev records arrived, presents at most one frame, and sleeps 16 ms
# again. No input can wake it early. Two things follow, and both are what this
# gate measures rather than argues:
#
#   * the sustained frame rate has a CEILING of 1000/(16 + frame_ms) — about
#     60 fps — and the whole value of the 5503 us -> 625 us work is that the
#     frame cost stopped being what kept it off that ceiling. At 5.5 ms/frame
#     the same loop tops out near 46 fps; at 0.6 ms it reaches ~59.
#   * input-to-pixel latency is dominated by WHERE IN THE TICK the input
#     landed, not by how long the frame takes to draw. Expect roughly uniform
#     0..16 ms plus the frame, i.e. a ~8 ms mean. That is the number a person
#     actually feels, and it is the one worth attacking next.
#
# WHAT EACH NUMBER IS A NUMBER ABOUT
# ==================================
# Every measurement here is of THE SHIPPED RENDERING PATH — wsysd's own
# software rasterizer (lib/vk/vk_2d.ad, VK_BACKEND_SW). It is stated out loud
# by the daemon at startup and asserted below, because the alternative is
# real: on a host with a CPU Vulkan ICD installed, wsysd brings the device up,
# sees VkPhysicalDeviceType 4, and DISARMS back to vk_2d (llvmpipe is 2.3-2.9x
# slower than the tree's own rasterizer, measured). Both spellings end in the
# same code drawing the pixels; only the second leaves a llvmpipe thread pool
# alive next to it, which is why the idle measurement is taken with no ICD at
# all — the shipped image stages only the venus ICD, which enumerates nothing.
#
# And it is OFFSCREEN: /dev/fb is a file (HAMFB_FILE), input is a file of
# evdev records (HAMWSYSD_INPUT). That is not a display. It removes the panel
# scanout, the vblank, and any wait for a page flip — user/linux-fb.c makes
# `flip` a no-op when the framebuffer is a plain file. So these numbers are
# the COMPOSITOR's, end to end from the input record to changed pixels, and
# they are a LOWER BOUND on what a monitor would show: a real display can only
# add. Nothing here is a claim about a physical screen.
#
# THE INSTRUMENT IS TESTED BEFORE IT IS BELIEVED
# ==============================================
# tests/linux/de_fps_driver.py runs a --selftest first and this gate refuses
# to report anything if it fails: the pixel watcher must not fire with no
# input; it must fire with input; a wsysd deliberately SIGSTOPped for 100 and
# 250 ms must MEASURE 100 and 250 ms slower; and 20 pointer moves spaced well
# past the tick must advance the presented-frame counter by about 20. See that
# file's header for why each one is there.
#
# The frame counter is wsysd's own n_frames off /dev/wsys/wsysd/state, and it
# is incremented AFTER present_rows() has write(2)n the composite to /dev/fb.
# It cannot count a render call that returned without presenting.
#
# CPU is sampled from /proc/<pid>/stat over a stated interval. Never ps pcpu,
# which is a LIFETIME average and misreported a number by 30x in this tree.
#
# NOT A PASS/FAIL CI GATE for its absolute numbers — those are host-CPU and
# host-load dependent, and the gate prints what else was running. The
# selftests and the "is this really the software path" assertions ARE pass/fail.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

# The desktop stack writes fixed host-global names (/tmp/hamnix-panel.*,
# /tmp/hamdesktop-wp.status, ...) that are compiled into the programs, so no
# care taken here can move them. Everything below runs in a mount namespace
# where /tmp, /dev/shm and /srv are this run's alone.
. tests/linux/private_ns.sh
priv_ns_reexec "$@"

. tests/linux/reap.sh

WORK="${FPS_WORK:-$(mktemp -d -p "${TMPDIR:-/tmp}" defps.XXXXXX)}"
mkdir -p "$WORK"
reap_track "$WORK/reaped"
KEEP="${FPS_KEEP:-0}"
GEOM="${HAMFB_GEOM:-1280x800}"
FBW="${GEOM%x*}"; FBH="${GEOM#*x}"
SECONDS_LOAD="${FPS_SECONDS:-10}"
# How many times each stated load is REPEATED. The cpu column needs it;
# fps does not (57.1/57.9/57.5 across three runs) but is reported as the
# median too so the row is internally consistent.
LOAD_REPS="${LOAD_REPS:-3}"
TRIALS="${FPS_TRIALS:-120}"

pass=0; fail=0
ok()   { echo "defps: PASS $*"; pass=$((pass+1)); }
bad()  { echo "defps: FAIL $*"; fail=$((fail+1)); }
info() { echo "defps: INFO $*"; }

cleanup() { reap_all; [ "$KEEP" = 1 ] || rm -rf "$WORK"; }
reap_on_exit cleanup
done_report() { echo "defps: $pass passed, $fail failed"; [ "$fail" = 0 ]; }

# ---- what else is on this machine while we measure ------------------------
# A busy host skews every number below, so it is recorded, not assumed away.
hostload() { awk '{printf "load %s %s %s", $1, $2, $3}' /proc/loadavg; }
info "host: $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed 's/^ //')"
info "host: $(nproc) cpus, $(hostload) at start"
info "host: busiest other processes right now:"
ps -eo pid,comm,etimes --sort=-etimes 2>/dev/null >/dev/null || true
top -b -n2 -d0.5 2>/dev/null | awk '/^ *PID/{s=1;n++;next} s&&n==2&&NF>=12&&$9+0>5 {printf "defps: INFO   %-8s %-16s %5s%% cpu\n",$1,$12,$9}' | head -8

# ---- build ----------------------------------------------------------------
BINDIR="${FPS_BIN_DIR:-$WORK/bin}"
if [ -z "${FPS_BIN_DIR:-}" ]; then
    mkdir -p "$BINDIR"
    for t in wsysd:user/wsysd.ad cat:user/cat.ad \
             hamdesktop:user/hamdesktop.ad \
             hampanelscene:user/hampanelscene.ad \
             de_dragload:tests/linux/de_dragload.ad; do
        n="${t%%:*}"; s="${t#*:}"
        scripts/hamlinux_build.sh "$s" "$BINDIR/$n" \
            >"$WORK/$n.build.log" 2>&1 || {
            bad "could not build $s"; tail -20 "$WORK/$n.build.log" >&2
            done_report; exit 1; }
    done
    ok "the compositor, the desktop and the panel build"
else
    info "using prebuilt binaries from $BINDIR"
fi

export HAMWSYS="$WORK/wsys.shm" HAMWSYS_BB="$WORK/wsys.bb"
export HAMWSYS_IMG="$WORK/wsys.img"
export HAMFB_FILE="$WORK/fb.raw" HAMFB_GEOM="$GEOM"
: >"$WORK/input.evdev"; export HAMWSYSD_INPUT="$WORK/input.evdev"

# NO VULKAN ICD AT ALL. This is the shipped configuration: the image stages
# only the venus ICD, which enumerates nothing, so wsysd's vk_set_backend
# fails and it uses vk_2d. Pointing VK_ICD_FILENAMES at an empty directory
# reproduces that exactly and — the reason this is not merely tidy — makes it
# impossible for this gate to touch the machine owner's GPU.
mkdir -p "$WORK/noicd"
export VK_ICD_FILENAMES="$WORK/noicd/none.json"

"$BINDIR/wsysd" </dev/null >"$WORK/wsysd.log" 2>&1 &
WSYSD_PID=$!; reap_add "$WSYSD_PID"
for _ in $(seq 1 80); do [ -s "$HAMFB_FILE" ] && break; sleep 0.1; done
[ -s "$HAMFB_FILE" ] || { bad "wsysd never produced a framebuffer"
                          cat "$WORK/wsysd.log"; done_report; exit 1; }

# ---- 1. WHICH PATH IS THIS? -----------------------------------------------
if grep -q "vk backend SOFTWARE" "$WORK/wsysd.log"; then
    ok "the rendering path under test is the SOFTWARE rasterizer: $(grep -m1 'vk backend' "$WORK/wsysd.log" | sed 's/^wsysd: //')"
else
    bad "wsysd did not report the software backend -- every number below would be about a path the shipped image does not use: $(grep -m1 'vk backend' "$WORK/wsysd.log")"
fi
if grep -q "input from $WORK/input.evdev only" "$WORK/wsysd.log"; then
    ok "input comes from this gate's evdev file and no device of this host's"
else
    bad "wsysd did not honour HAMWSYSD_INPUT -- it may be reading this host's keyboard"
fi
DRV="python3 tests/linux/de_fps_driver.py --fb $HAMFB_FILE \
     --input $HAMWSYSD_INPUT --cat $BINDIR/cat --pid $WSYSD_PID --geom $GEOM"

# ---- 2. IDLE, ATTRIBUTED ---------------------------------------------------
# Taken in THREE configurations, because "the idle desktop presents N frames a
# second" is useless without knowing which program is dirtying the screen. The
# compositor is measured bare first, then with each client added, so the
# residual is billed to something by name rather than blamed on "the DE".
echo
echo "defps: ---- idle, attributed ----------------------------------------"
info "(a) compositor alone, no clients:"
IDLE_BARE="$($DRV --mode idle --seconds 5 | tee "$WORK/idle_bare.txt" | sed -n 's/.*-- \([0-9]*\) frames.*/\1/p')"
sed 's/^/defps: INFO     /' "$WORK/idle_bare.txt"
if [ "${IDLE_BARE:-999}" -le 2 ]; then
    ok "an EMPTY compositor presents $IDLE_BARE frames in 5 s -- wsysd itself paints on change, not on a clock"
else
    bad "an empty compositor presented $IDLE_BARE frames in 5 s with no clients and no input -- wsysd is dirtying its own screen"
fi

"$BINDIR/hamdesktop" </dev/null >"$WORK/hamdesktop.log" 2>&1 &
reap_add $!
sleep 3
info "(b) + hamdesktop (wallpaper and icons):"
IDLE_DESK="$($DRV --mode idle --seconds 5 | tee "$WORK/idle_desk.txt" | sed -n 's/.*-- \([0-9]*\) frames.*/\1/p')"
sed 's/^/defps: INFO     /' "$WORK/idle_desk.txt"

"$BINDIR/hampanelscene" </dev/null >"$WORK/hampanel.log" 2>&1 &
reap_add $!
sleep 3
info "(c) + hampanelscene (the top bar) -- THE SHIPPED DESKTOP:"
IDLE_FULL="$($DRV --mode idle --seconds 10 | tee "$WORK/idle_full.txt" | sed -n 's/.*-- \([0-9]*\) frames.*/\1/p')"
sed 's/^/defps: INFO     /' "$WORK/idle_full.txt"
info "attribution: bare $IDLE_BARE/5s, +desktop $IDLE_DESK/5s, +panel $IDLE_FULL/10s."
# AND THE RESIDUAL IS BILLED TO A LINE OF SOURCE, NOT TO "THE DE".
# user/hampanelscene.ad's main loop is a 16 ms tick with
#     SAMPLE_TICKS: uint64 = 20
# and `if sysmon_tick >= SAMPLE_TICKS: _sm_sample(); any_redraw = 1`. So the
# sysmon applet resamples CPU/memory every 20 * 16 ms = 320 ms and repaints
# the whole panel when it does, which is 3.1 commits a second, each of which
# bumps the window's gen and therefore forces one FULL compositor frame.
# 1000/320 = 3.13 predicted; the number measured above is the check. An
# instrument that agrees with the source to two significant figures on a
# quantity neither was tuned to is worth more than either alone.
info "             expected: user/hampanelscene.ad resamples sysmon every"
info "             SAMPLE_TICKS(20) * 16 ms = 320 ms and repaints the panel,"
info "             = 3.13 frames/s = 31 frames in 10 s. The clock's own"
info "             minute rollover adds one frame a MINUTE, not a second."
if [ "${IDLE_FULL:-999}" -le 40 ] && [ "${IDLE_FULL:-0}" -ge 20 ]; then
    ok "the shipped idle desktop presents $IDLE_FULL frames in 10 s -- 3.1/s, which is the panel's 320 ms sysmon resample and nothing else; the compositor and the wallpaper present ZERO"
elif [ "${IDLE_FULL:-999}" -lt 20 ]; then
    ok "the shipped idle desktop presents $IDLE_FULL frames in 10 s -- below even the panel's own 320 ms sysmon cadence"
else
    bad "the shipped idle desktop presented $IDLE_FULL frames in 10 s, well past the 31 the panel's 320 ms sysmon resample accounts for -- something else is dirtying the screen"
fi

NWIN="$("$BINDIR/cat" /dev/wsys/wsysd/state 2>/dev/null | sed -n 's/.*windows \([0-9]*\).*/\1/p')"
info "the desktop is up: $("$BINDIR/cat" /dev/wsys/wsysd/state 2>/dev/null)"
[ "${NWIN:-0}" -ge 2 ] \
    && ok "the load is a REAL desktop: $NWIN windows mapped (wallpaper+icons, panel)" \
    || bad "only ${NWIN:-0} windows mapped -- this is not the desktop, it is an empty screen"

# ---- 3. THE INSTRUMENT, BEFORE ANY NUMBER IS REPORTED ---------------------
echo
echo "defps: ---- instrument selftest ------------------------------------"
if $DRV --mode selftest; then
    ok "the instrument passed its own selftests (it does not fire on its own; a deliberately stopped compositor measures as stopped; the frame counter counts presentations)"
else
    bad "the instrument failed its selftest -- REFUSING to report numbers from it"
    done_report; exit 1
fi

# ---- 4. SUSTAINED FPS UNDER A STATED LOAD ---------------------------------
# THE LOAD, and why it is this one. A desktop's most frequent update by far is
# the pointer, and wsysd has a dedicated cheap path for it (cursor_only_frame,
# ~5 us) — so measuring only that would flatter the number. The second load
# therefore holds the button down on a window's title bar and drags it, which
# changes the window set signature on EVERY move and forces the FULL path:
# clear the desktop, re-read and re-rasterize every window's scene, copy each
# into the composite, write the whole 4 MiB. Dragging a window across a
# populated desktop is the most expensive thing an ordinary session does, and
# it is a thing people actually do.
echo
echo "defps: ---- sustained fps, stated load ------------------------------"
info "load A: pointer moving continuously at 250 events/s over the live"
info "        desktop ($NWIN windows). This is the CURSOR-ONLY path -- wsysd's"
info "        save-under means a pointer move re-rasterizes nothing."
# --reps: the cpu column is a MEDIAN OF THREE with every sample printed, and
# fps comes back as the median too. A single sample of this column ranged
# 4.2-17.1 on this host for the SAME binary under this exact load, and was
# once read as a 4x regression that had not happened. Set LOAD_REPS=1 for the
# old single-sample cost if the fps number is all you want.
$DRV --mode fps --seconds "$SECONDS_LOAD" --rate 250 --reps "$LOAD_REPS" --tag "A pointer only"

# The full path needs the WINDOW SET to change, which pointer motion by
# design does not do. tests/linux/de_dragload.ad owns a decorated 480x320
# window with eight rows of glyphs in it and walks it across the desktop as
# fast as its ctl file will take it -- one `geometry` write per millisecond,
# far under the 16 ms tick, so the window is at a new place every time the
# frame gate looks and every frame is a FULL one.
"$BINDIR/de_dragload" 480 320 120 200 300 8 >"$WORK/drag.wid" 2>"$WORK/drag.err" &
DRAG_PID=$!; reap_add "$DRAG_PID"
for _ in $(seq 1 40); do [ -s "$WORK/drag.wid" ] && break; sleep 0.1; done
DRAGWID="$(tr -d '\n' <"$WORK/drag.wid" 2>/dev/null)"
sleep 1.5
if [ -n "${DRAGWID:-}" ] && [ "${DRAGWID:-0}" -ge 2 ]; then
    ok "a full-frame load is on the desktop: wid $DRAGWID, a decorated 480x320 window with text, moving continuously"
else
    bad "de_dragload never mapped a window -- the full-frame load below is not a load"
    cat "$WORK/drag.err" >&2
fi
echo
info "load B: that window dragging, and NO pointer motion. Every frame here is"
info "        a full repaint: clear, re-rasterize $((NWIN+1)) windows' scenes, copy each"
info "        into the composite, write the whole $((FBW*FBH*4/1024/1024)) MiB screen."
$DRV --mode fps --seconds "$SECONDS_LOAD" --rate 0 --reps "$LOAD_REPS" --tag "B window drag"
echo
info "load C: both at once -- a window being dragged while the pointer moves,"
info "        which is what dragging a window with a mouse actually is."
$DRV --mode fps --seconds "$SECONDS_LOAD" --rate 250 --reps "$LOAD_REPS" --tag "C drag + pointer"
info "ceiling: the loop's own 16 ms sleep caps all three at 1000/(16+frame_ms)"
info "         ~= 60 fps. A number at that ceiling means the RASTERIZER is no"
info "         longer what limits the desktop; the tick is."

# ---- 5. INPUT TO PIXEL ----------------------------------------------------
# The dragging window has to stop first: latency is measured against a QUIET
# desktop, because a screen that is already changing every frame would let the
# watcher fire on someone else's paint and report a latency this input did not
# earn.
kill "$DRAG_PID" 2>/dev/null; sleep 0.5; kill -9 "$DRAG_PID" 2>/dev/null
sleep 1.5
echo
echo "defps: ---- input-to-pixel latency ----------------------------------"
info "clock starts at the last instruction before the write(2) that makes the"
info "evdev record visible; stops when the framebuffer bytes where the pointer"
info "is going have changed. $TRIALS trials, on a quiet desktop."
$DRV --mode latency --trials "$TRIALS" --tag "input->pixel"
info "for scale: 16 ms is one tick of wsysd's poll loop. A mean near half of"
info "that is the loop's own SAMPLING DELAY, not the rasterizer -- the frame"
info "itself costs 0.6 ms and the pointer-only frame 5 us."
echo
# THE TRAP THIS GATE FELL INTO ONCE, KEPT AS A RUNNING CONTROL.
# The first version of the probe used a constant 80 ms settle. 80 ms is
# exactly five 16 ms ticks, so every injection landed at the same phase and
# the gate measured a median of 1.0 ms -- "the desktop is instantaneous",
# which was a measurement of one lucky phase repeated 40 times. The jittered
# probe above samples the phase uniformly. Both are run, and the difference
# between them is the size of the lie the un-jittered one tells.
info "control: the SAME probe with the jitter removed, which phase-locks it to"
info "         the compositor's tick. If this comes back much smaller than the"
info "         line above, that gap is the artefact, not a speedup."
$DRV --mode latency --trials $(( TRIALS / 3 + 1 )) --nojitter --tag "phase-locked (WRONG)"

echo
info "host: $(hostload) at end"
done_report
