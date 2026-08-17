#!/usr/bin/env bash
#
# REGISTRATION, 2026-08-17. Until this date scripts/test_gate_registration.sh
# globbed only scripts/test_*.sh, so this directory was invisible to the gate
# against unregistered gates and every file in it read as coverage without
# being coverage. This gate is ON-DEMAND: not in ci_battery_manifest.txt
# because it was MEASURED on 2026-08-17 and exited 1 in 18 s on a host with the channel and the image built, so it does not pass unattended here yet.
#
#
# tests/linux/wsyswl_two_browsers.sh — CAN A PERSON HAVE TWO BROWSERS OPEN?
#
# THE QUESTION
# ============
# `wsyswl_conn_ceiling.sh` next door proves the ceiling is MAXCONN and that a
# client past it is refused by name. This one asks the thing the ceiling was
# FOR, and it asks it with real programs rather than with probes:
#
#     Firefox is EIGHT Wayland connections. Can a second browser run beside it,
#     with the two namespaces NORTH_STAR says are open at the same time?
#
# HANDOFF named "two browsers do not fit" as the ceiling MAXCONN 16 left
# standing, on the arithmetic 8 + 8 + 2 = 18. Two of those three numbers were
# measured and one was assumed, so this file measures all of them, and one of
# them comes out DIFFERENT from the guess -- see the census below. That is the
# point of driving the real programs: a ceiling defended by arithmetic over an
# assumed appetite is a ceiling defended by an adjective.
#
# THE CENSUS, and every row of it is produced by this script rather than
# quoted into it:
#
#   firefox-esr            8 connections   (content, GPU and utility processes)
#   chromium               2 connections   (browser + GPU process)
#   Xwayland               1 connection    per namespace, rootful or rootless,
#                                          however many X clients are behind it
#
# CHROMIUM IS 2, NOT 8, AND THAT MATTERS. The gap statement's "8 + 8" assumed
# a second browser had a second browser's appetite; it does not. Firefox plus
# Chromium is TEN and would have fitted under the old ceiling of 16. What does
# not fit is the case a namespaced distribution makes ordinary: a Firefox in
# the native root and a Firefox inside `enter debian { … }`, which really is
# 8 + 8, and then debian's and alpine's Xwayland are 17 and 18. So the honest
# claim this file makes is not "two browsers" but "two of THESE browsers", and
# both arms are driven:
#
#   ARM A -- THE MIXED DESKTOP: firefox-esr + chromium + two Xwaylands, with a
#            real X client on each Xwayland. Both browsers must MAP A WINDOW,
#            not merely connect: a browser that is on the connection table and
#            has no surface is the failure this whole chain keeps producing.
#   ARM B -- TWO OF THE SAME BROWSER: two firefox-esr instances on separate
#            profiles with -no-remote, plus two Xwaylands. This is the arm that
#            passes 16, and the arm the old ceiling refused.
#
# AND THE CONTROL IS RUN, NOT DESCRIBED. Section 5 rebuilds this same source
# with MAXCONN put back to 16 -- one number changed, nothing else -- starts a
# fresh compositor on a fresh segment, and drives the SAME two Firefoxes at it.
# The second one must be refused, and refused BY NAME: the regression this tree
# paid for once was a refused client printing `No wl_shm global`, blaming a
# protocol global that is present and advertised.
#
# WHAT THIS GATE NEEDS FROM THE HOST, and what it does when it does not get it.
# It drives real browsers, so it is one of the few gates whose subject can be
# absent. Two failure shapes, and NEITHER is a FAIL against this tree:
#
#   * a browser that is NOT INSTALLED -- named, with the apt line, then SKIPPED
#     ENTIRELY at the prerequisite check below;
#   * a browser that is installed and CANNOT START -- caught in section 1, which
#     first proves the connection counter can count (with an Xwayland, a client
#     needing no GTK) so that `0 connections` is never read as a finding from an
#     instrument that has not been shown to work. See the XDG_DATA_DIRS note
#     below: this gate spent months at 12 passed / 11 FAILED, every red naming
#     firefox-esr, for a login-shell environment variable and nothing else.
#
# A SKIP IS COUNTED IN ITS OWN COLUMN AND NEVER AS A PASS, and a run that skips
# anything prints INCOMPLETE. The opposite mistake is on record here too -- a
# gate that went green having scored zero arms -- so a run with 0 passes exits
# non-zero no matter what.
#
# Offscreen throughout: HAMFB_FILE, no VM, no display, no host GPU.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

# THE MACHINE THIS RUNS ON IS NOT SCRATCH.
#
# It runs two wsyswl compositors and their clients; each one's Wayland socket lands in
# $XDG_RUNTIME_DIR, which the helper now shadows too.
#
# The names that matter are compiled into the binaries, not written here, so no
# care taken in this script can move them; the containment is the namespace.
# tests/linux/private_ns.sh has the table and the incident that bought it. This
# must come before anything that makes a file under /tmp, $WORK included, and
# before reap.sh, whose registry is itself a mktemp under /tmp.
. tests/linux/private_ns.sh
priv_ns_reexec "$@"

WORK="${TB_WORK:-$(mktemp -d -p "${TMPDIR:-/tmp}" twobr.XXXXXX)}"
mkdir -p "$WORK"
KEEP="${TB_KEEP:-0}"
GEOM="${HAMFB_GEOM:-1280x800}"
# PRIVATE, all four -- see wsyswl_conn_ceiling.sh: a test that inherits the
# host's segments is measuring the last run.
export HAMWSYS="$WORK/wsys.shm"
export HAMWSYS_BB="$WORK/wsys.bb"
export HAMWSYS_IMG="$WORK/wsys.img"
export HAMFB_FILE="$WORK/fb.raw"
export HAMFB_GEOM="$GEOM"
# THE HOST'S GPU BELONGS TO SOMEONE. Software rasterisers everywhere: the
# Vulkan ICD for wsysd, no glamor for Xwayland, llvmpipe for GL, and
# --use-angle=swiftshader for Chromium, which will otherwise open the host's
# real card through GBM before it falls back.
[ -r /usr/share/vulkan/icd.d/lvp_icd.json ] && \
    export VK_ICD_FILENAMES="${VK_ICD_FILENAMES:-/usr/share/vulkan/icd.d/lvp_icd.json}"
export XWAYLAND_NO_GLAMOR=1
export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER=llvmpipe

# A GTK PROGRAM NEEDS A DATA-DIR SEARCH PATH, AND A LOGIN SHELL HERE DOES NOT
# GIVE IT ONE. This gate was 12 passed / 11 FAILED for months, every red naming
# firefox-esr and `0 connections`, and NONE of it was the compositor's. Measured:
#
#   /home/david/.profile:32   export XDG_DATA_DIRS="$HOME/.local/share:$XDG_DATA_DIRS"
#
# prepends to a variable that is UNSET in any non-desktop shell, and the result
# is `/home/david/.local/share:` -- which SILENTLY DROPS /usr/share, because
# glib applies the /usr/local/share:/usr/share default only when the variable is
# absent, never when it is present and short. With /usr/share gone there is no
# /usr/share/mime, so gdk-pixbuf can identify NO image of any kind: the PNG
# decoder is present and works when handed bytes and told they are PNG (measured
# via GdkPixbuf.PixbufLoader.new_with_type -- 48x48 decoded fine) while
# gdk_pixbuf_get_file_info() on the same bytes returns NULL. Firefox then dies in
# gtkiconhelper.c:495 asserting on `image-missing.png`, BEFORE it opens a single
# Wayland connection -- which is why the number this gate read was 0 and why the
# desktop's own owner never sees it: the live MATE session has
# XDG_DATA_DIRS=/usr/share/mate:/usr/local/share/:/usr/share/ and is fine.
#
# So the browsers get the environment the tree's own launcher already gives them
# -- scripts/stage_firefox.sh:708-714 sets exactly this, and names "the mime db"
# in its comment. XDG_DATA_DIRS is the one measured to matter here; the two
# gdk-pixbuf paths are set only if they exist, matching that precedent.
export XDG_DATA_DIRS="${TB_XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
PIXBUF_CACHE=/usr/lib/x86_64-linux-gnu/gdk-pixbuf-2.0/2.10.0/loaders.cache
[ -r "$PIXBUF_CACHE" ] && {
    export GDK_PIXBUF_MODULE_FILE="$PIXBUF_CACHE"
    export GDK_PIXBUF_MODULEDIR="${PIXBUF_CACHE%/*}/loaders"; }

pass=0; fail=0; skipped=0
ok()   { echo "twobr: PASS $*"; pass=$((pass+1)); }
bad()  { echo "twobr: FAIL $*"; fail=$((fail+1)); }
info() { echo "twobr: INFO $*"; }
# A SKIP IS NOT A PASS AND MUST NEVER BE COUNTED AS ONE. It is counted in its
# own column, it is printed in the summary whether or not it is zero, and a run
# that skipped anything says so on its last line. The opposite mistake is on
# record in this tree -- a gate that exited GREEN having scored ZERO ARMS -- so
# see the end of this file: a run that skips everything and asserts nothing
# EXITS NON-ZERO, because "I measured nothing" is not a passing verdict.
skip() { echo "twobr: SKIP $*"; skipped=$((skipped+1)); }
# An empty read is not a measurement. See tests/linux/gate_read.sh; used at the
# MAXCONN=16 control in section 5.
. tests/linux/gate_read.sh

# REAP EVERYTHING. A browser is a process TREE and killing the launcher leaves
# the content and GPU processes holding their connections; a gate that leaks
# those leaves a machine slower than it found it. Every browser is started in
# its own process GROUP and the group is what is signalled.
GROUPS_TO_REAP=""; KIDS=""; SERVERS=""
reap_group() { [ -n "${1:-}" ] && kill -TERM "-$1" 2>/dev/null; }
# Kill every browser process TREE started so far and forget them. Used between
# the shipped arm and the MAXCONN=16 control, so the control is not measuring a
# machine with three browsers still on it.
reap_browsers() {
    for g in $GROUPS_TO_REAP; do reap_group "$g"; done
    sleep 2
    for g in $GROUPS_TO_REAP; do [ -n "${g:-}" ] && kill -KILL "-$g" 2>/dev/null; done
    sleep 1
    GROUPS_TO_REAP=""
}
cleanup() {
    for g in $GROUPS_TO_REAP; do reap_group "$g"; done
    for p in $KIDS $SERVERS; do [ -n "${p:-}" ] && kill -TERM "$p" 2>/dev/null; done
    sleep 1.5
    for g in $GROUPS_TO_REAP; do [ -n "${g:-}" ] && kill -KILL "-$g" 2>/dev/null; done
    for p in $KIDS $SERVERS; do [ -n "${p:-}" ] && kill -KILL "$p" 2>/dev/null; done
    sleep 0.3
    [ "$KEEP" = 1 ] || rm -rf "$WORK"
}
trap cleanup EXIT

FF="${TB_FIREFOX:-firefox-esr}"
CH="${TB_CHROMIUM:-chromium}"
# AN ABSENT PROGRAM IS NOT A DEFECT IN THIS TREE, and a gate that FAILS for
# want of one teaches everyone to ignore it -- an ignored gate is worse than no
# gate. So a missing prerequisite SKIPS, names what is missing, and says how to
# get it. It exits 0 because nothing here is broken; it prints SKIPPED ENTIRELY
# and a count of 0 assertions so that no summary can file it under PASS.
MISSING=""
for t in "$FF" "$CH" Xwayland xterm python3; do
    command -v "$t" >/dev/null || MISSING="$MISSING $t"
done
if [ -n "$MISSING" ]; then
    for t in $MISSING; do
        case "$t" in
            "$FF")     skip "no '$FF' on this host -- the firefox this gate drives (apt install firefox-esr, or point TB_FIREFOX at one)" ;;
            "$CH")     skip "no '$CH' on this host -- the second browser this gate drives (apt install chromium, or point TB_CHROMIUM at one)" ;;
            Xwayland)  skip "Xwayland is NOT INSTALLED (apt install xwayland) -- the namespace arms need it" ;;
            xterm)     skip "xterm is NOT INSTALLED (apt install xterm) -- the X clients behind each Xwayland need it" ;;
            python3)   skip "python3 is NOT INSTALLED -- tests/linux/private_ns.sh needs it to make the mount namespace" ;;
        esac
    done
    echo "twobr: ---------------------------------------------"
    echo "twobr: PASS 0  FAIL 0  SKIP $skipped"
    echo "twobr: SKIPPED ENTIRELY -- this gate drives REAL browsers and the host has none of$MISSING."
    echo "twobr: THIS IS NOT A PASS. It asserted nothing about two browsers fitting; it only"
    echo "twobr: reports that the machine cannot be asked. Install the above and re-run."
    exit 0
fi

adnum() { sed -n "s/^$2: *uint64 = \([0-9]*\).*/\1/p" "$1" | head -1; }
MAXCONN="$(adnum user/wsyswl.ad MAXCONN)"
info "MAXCONN in source is $MAXCONN"

# ---------------------------------------------------------------------------
# 0. build
# ---------------------------------------------------------------------------
echo "twobr: === 0. build"
for t in wsysd:user/wsysd.ad wsyswl:user/wsyswl.ad; do
    name="${t%%:*}"; src="${t#*:}"
    scripts/hamlinux_build.sh "$src" "$WORK/$name.elf" >"$WORK/$name.build.log" 2>&1 || {
        echo "FAIL could not build $src" >&2; tail -20 "$WORK/$name.build.log" >&2; exit 1; }
done
ok "wsysd and wsyswl build"

STATE="$WORK/wsyswl-state"
st()  { sed -n "s/^$1 \([0-9-]*\)\$/\1/p" "$STATE" 2>/dev/null | tail -1; }

start_servers() {
    "$WORK/wsysd.elf" </dev/null >"$WORK/wsysd.log" 2>&1 & SERVERS="$SERVERS $!"
    sleep 1.5
    "$WORK/wsyswl.elf" "$WORK/wayland-0" </dev/null \
        >"$WORK/wsyswl.log" 2>"$WORK/wsyswl.err" & SERVERS="$SERVERS $!"
    for _ in $(seq 1 60); do [ -S "$WORK/wayland-0" ] && break; sleep 0.1; done
    [ -S "$WORK/wayland-0" ] || { bad "wsyswl never created its socket"; exit 1; }
    export XDG_RUNTIME_DIR="$WORK"
    export WAYLAND_DISPLAY=wayland-0
    unset DISPLAY
    sleep 1
}

# Wait until `conns` has been the same value for two seconds running, or the
# budget runs out. A browser's connections arrive over several seconds as its
# child processes come up, so a fixed sleep either wastes time or measures a
# half-started browser -- and a half-started browser is exactly the reading
# that would make a too-small ceiling look big enough.
settle() {  # settle <max-seconds>
    local budget="$1" last="" same=0 c
    for _ in $(seq 1 "$budget"); do
        sleep 1
        c="$(st conns)"
        if [ "$c" = "$last" ]; then same=$((same+1)); else same=0; fi
        [ "$same" -ge 2 ] && break
        last="$c"
    done
}

# THESE SET A GLOBAL AND DO NOT PRINT, deliberately. Written to `echo "$p"` and
# called as `P=$(start_firefox a)` they run in a SUBSHELL, so every pid appended
# to KIDS/GROUPS_TO_REAP inside them is lost when the subshell exits -- and this
# gate would then leave a browser process tree per run behind it. A gate that
# leaks 61 holder processes has already happened in this tree once.
LAST_PID=""
start_firefox() {  # start_firefox <tag> -> LAST_PID
    local tag="$1"
    local prof="$WORK/ffprof-$tag"
    mkdir -p "$prof"
    MOZ_ENABLE_WAYLAND=1 MOZ_DISABLE_CONTENT_SANDBOX=1 \
    setsid "$FF" -no-remote -profile "$prof" --new-window file:///etc/services \
        </dev/null >"$WORK/ff-$tag.log" 2>&1 &
    LAST_PID=$!
    KIDS="$KIDS $LAST_PID"; GROUPS_TO_REAP="$GROUPS_TO_REAP $LAST_PID"
}

start_chromium() {  # start_chromium <tag> -> LAST_PID
    local tag="$1"
    setsid "$CH" --ozone-platform=wayland --no-sandbox \
        --user-data-dir="$WORK/chprof-$tag" --no-first-run \
        --use-gl=angle --use-angle=swiftshader --disable-features=Vulkan \
        --disable-dev-shm-usage file:///etc/services \
        </dev/null >"$WORK/ch-$tag.log" 2>&1 &
    LAST_PID=$!
    KIDS="$KIDS $LAST_PID"; GROUPS_TO_REAP="$GROUPS_TO_REAP $LAST_PID"
}

start_xwayland() {  # start_xwayland <dispnum> -> LAST_PID
    local d="$1"
    Xwayland -rootless -shm -noreset "$d" >"$WORK/xw${d#:}.log" 2>&1 &
    LAST_PID=$!
    KIDS="$KIDS $LAST_PID"
    for _ in $(seq 1 150); do [ -S "/tmp/.X11-unix/X${d#:}" ] && break; sleep 0.1; done
}

alive() { kill -0 "$1" 2>/dev/null && echo y || echo n; }

# ---------------------------------------------------------------------------
# 1. THE CENSUS: what does each program actually cost?
# ---------------------------------------------------------------------------
echo "twobr: === 1. the census -- each program's REAL appetite, one at a time"
start_servers
BASE="$(st conns)"
info "with nothing running, conns is ${BASE:-0}"

start_firefox a; P_FF1="$LAST_PID"
settle 40
FF_CONNS=$(( $(st conns) - BASE ))
FF_WINS="$(st windows_high_water)"
info "firefox-esr: $FF_CONNS connections, windows_high_water $FF_WINS, alive $(alive "$P_FF1")"

# ---------------------------------------------------------------------------
# IS THAT ZERO A FINDING, OR IS IT THE INSTRUMENT?
# ---------------------------------------------------------------------------
# FF_OK=1 means firefox-esr got far enough to be a subject. When it did not,
# every assertion below about connection accounting would be measuring a
# program that never ran, and it would BLAME THE COMPOSITOR by name for a
# client that aborted in GTK before calling connect(2) -- which is exactly the
# 11-red run this preflight exists to stop.
#
# AND THE ZERO IS NOT TAKEN AT FACE VALUE. `0 connections` is a reading, and a
# reading from a counter that has never been shown to count is worth nothing.
# So before the zero is allowed to mean "firefox made no connection", the SAME
# reader is made to count a connection that is known to exist: an Xwayland,
# which is 1 connection and needs no icon theme, no mime database and no GTK.
#   * counter moves  -> the reader works, the zero is real, firefox is the
#                       problem, and the arms that need it are SKIPPED;
#   * counter frozen -> the zero was the INSTRUMENT, and that is a FAIL against
#                       this tree, not a reason to skip anything.
FF_OK=1
if [ "${FF_CONNS:-0}" -le 0 ] && [ "$(alive "$P_FF1")" = n ]; then
    info "firefox-esr contributed 0 connections and is no longer running."
    info "PROVING THE COUNTER BEFORE READING ANYTHING INTO THAT ZERO:"
    PROBE_BEFORE="$(st conns)"
    start_xwayland :79; PROBE_XW="$LAST_PID"; sleep 3
    PROBE_DELTA=$(( $(st conns) - ${PROBE_BEFORE:-0} ))
    info "  an Xwayland (1 connection, no GTK) moved conns ${PROBE_BEFORE:-0} -> $(st conns), delta $PROBE_DELTA"
    kill -TERM "$PROBE_XW" 2>/dev/null; sleep 1; kill -KILL "$PROBE_XW" 2>/dev/null
    if [ "$PROBE_DELTA" -ge 1 ]; then
        ok "the connection counter COUNTS: a known-good client moved it by $PROBE_DELTA, so firefox-esr's 0 is a real zero and not an empty read"
        FF_OK=0
    else
        bad "the connection counter did not move for an Xwayland either (delta $PROBE_DELTA) -- the 0 read for firefox-esr is the INSTRUMENT, not the browser, and this is a defect in what this gate reads"
        FF_OK=0
    fi
fi

# WHY did it not start? Only a client-side abort earns a SKIP. A firefox that
# started, connected and was then turned away is this gate's SUBJECT and must
# stay a FAIL.
if [ "$FF_OK" = 0 ]; then
    # -a IS LOAD-BEARING AND WAS BOUGHT WITH A WRONG ANSWER. Firefox's log has a
    # NUL byte in it, so grep calls the file BINARY, prints "Binary file matches"
    # to stderr instead of the line, and $(...) is THE EMPTY STRING -- while the
    # abort it was looking for is sitting there in plain text. The first run of
    # this very branch therefore took the `no client-side abort` path and printed
    # a FAIL immediately above a tail(1) of the abort it had just failed to see.
    # An empty read invented a verdict inside the code written to stop exactly
    # that. tests/linux/gate_read.sh is the standing lesson; this is its newest
    # instance.
    FF_WHY="$(grep -a -m1 -E 'Gtk:ERROR|Bail out!|mozalloc_abort|Unrecognized image file format|pixbuf loaders or the mime database' "$WORK/ff-a.log" 2>/dev/null)"
    if [ -n "$FF_WHY" ]; then
        skip "firefox-esr IS INSTALLED ($("$FF" --version 2>/dev/null)) BUT CANNOT START ON THIS HOST, and it died before opening any Wayland connection, so nothing below it measures the compositor:"
        skip "    $FF_WHY"
        skip "    This is a GTK/gdk-pixbuf startup abort, NOT a wsyswl refusal: conn_refused is $(st conn_refused) and firefox never reached connect(2)."
        skip "    THE USUAL CAUSE, and the one measured on this machine: XDG_DATA_DIRS does not contain /usr/share, so /usr/share/mime is missing and gdk-pixbuf can identify no image at all."
        skip "    THE FIX IS ENVIRONMENT, NOT PACKAGES: re-run with TB_XDG_DATA_DIRS=/usr/local/share:/usr/share (this gate now sets that by default; something in the caller's environment has overridden it to '$XDG_DATA_DIRS')."
        skip "    Its own log is $WORK/ff-a.log; run with TB_KEEP=1 to keep it."
        tail -6 "$WORK/ff-a.log" 2>/dev/null | sed 's/^/twobr:     | /'
    else
        bad "firefox-esr opened no connection and is dead, and its log shows no client-side startup abort -- this is NOT a host prerequisite and is being reported as a real failure"
        tail -10 "$WORK/ff-a.log" 2>/dev/null | sed 's/^/twobr:     | /'
    fi
fi

if [ "$FF_OK" = 0 ]; then
    skip "firefox-esr's appetite (the '8 connections' the whole ceiling argument rests on) -- UNMEASURED on this host"
    skip "firefox-esr mapping a window -- UNMEASURED on this host"
elif [ "$FF_CONNS" -ge 8 ]; then
    ok "firefox-esr opens $FF_CONNS connections -- the 8 the ceiling was raised for, measured again here"
else
    bad "firefox-esr opened only $FF_CONNS connections; the whole ceiling argument rests on this being 8"
fi
if [ "$FF_OK" = 0 ]; then
    :   # already skipped by name above
elif [ "$(alive "$P_FF1")" = y ] && [ "${FF_WINS:-0}" -ge 1 ]; then
    ok "firefox-esr is running AND has a window on this compositor -- connected is not the same as visible"
else
    bad "firefox-esr connected but never mapped a window (alive $(alive "$P_FF1"), windows $FF_WINS)"
    tail -5 "$WORK/ff-a.log"
fi

# ---------------------------------------------------------------------------
# 2. ARM A: THE MIXED DESKTOP -- firefox + chromium + two namespaces
# ---------------------------------------------------------------------------
echo "twobr: === 2. arm A: a second, DIFFERENT browser beside it, and two namespaces' Xwayland"
BEFORE_CH="$(st conns)"
start_chromium a; P_CH="$LAST_PID"
settle 35
CH_CONNS=$(( $(st conns) - BEFORE_CH ))
info "chromium: $CH_CONNS connections (browser + GPU process), alive $(alive "$P_CH")"
if [ "$CH_CONNS" -ge 1 ]; then
    ok "chromium's real appetite is $CH_CONNS connections -- measured, not the 8 the gap statement assumed for a second browser"
else
    bad "chromium opened no connection at all"
    tail -10 "$WORK/ch-a.log"
fi
CH_ALIVE="$(alive "$P_CH")"
FF_ALIVE="$(alive "$P_FF1")"
W2="$(st windows_high_water)"
if [ "$FF_OK" = 0 ]; then
    # There is only one browser on this host, so "both" is not a question that
    # can be asked. What CAN still be asked is asked: chromium's own appetite
    # above, and that chromium alone is alive and has a surface.
    skip "TWO BROWSERS AT ONCE -- unaskable here, firefox-esr never started (see section 1)"
    if [ "$CH_ALIVE" = y ] && [ "${W2:-0}" -ge 1 ]; then
        ok "the one browser that DOES run here is alive and has a surface: chromium, windows_high_water $W2"
    else
        bad "chromium alone is not alive-with-a-window either (alive $CH_ALIVE, windows_high_water $W2)"
    fi
elif [ "$CH_ALIVE" = y ] && [ "$FF_ALIVE" = y ]; then
    ok "BOTH BROWSERS ARE RUNNING AT ONCE on one wsyswl (firefox $FF_ALIVE, chromium $CH_ALIVE)"
else
    bad "a browser died when the other was started: firefox $FF_ALIVE, chromium $CH_ALIVE"
fi
if [ "$FF_OK" = 0 ]; then
    skip "both browsers having a window -- only one browser runs on this host"
elif [ "${W2:-0}" -ge 2 ]; then
    ok "and both have a window: windows_high_water $W2 -- two browsers, two surfaces, not one program on a table"
else
    bad "windows_high_water is $W2 with two browsers up: one of them is connected and blind"
fi

BEFORE_XW="$(st conns)"
start_xwayland :71; XW1="$LAST_PID"; sleep 2
start_xwayland :72; XW2="$LAST_PID"; sleep 2
settle 15
XW_CONNS=$(( $(st conns) - BEFORE_XW ))
info "two Xwaylands: $XW_CONNS connections total"
# A namespace's Xwayland is only a real client if something is behind it.
DISPLAY=:71 xterm -geometry 30x8+40+40 -e "sleep 120" >/dev/null 2>&1 & KIDS="$KIDS $!"
DISPLAY=:72 xterm -geometry 30x8+340+40 -e "sleep 120" >/dev/null 2>&1 & KIDS="$KIDS $!"
sleep 4
A_CONNS="$(st conns)"
A_REFUSED="$(st conn_refused)"
A_WINS="$(st windows_high_water)"
info "ARM A total: conns $A_CONNS, conn_refused ${A_REFUSED:-0}, windows_high_water $A_WINS"
# The desktop this arm actually assembled, named honestly: on a host where
# firefox cannot start, saying "firefox + chromium" in a PASS line would be a
# pass describing a program that is not there.
A_DESC="firefox + chromium + 2 Xwaylands + 2 X clients"
[ "$FF_OK" = 0 ] && A_DESC="chromium + 2 Xwaylands + 2 X clients (NO firefox -- it cannot start here)"
if [ "${A_REFUSED:-1}" = 0 ]; then
    ok "the mixed desktop ($A_DESC) cost $A_CONNS connections and NOTHING was refused"
else
    bad "conn_refused is $A_REFUSED on the mixed desktop -- a program was turned away"
fi
if [ "$FF_OK" = 0 ]; then
    if [ "$(alive "$P_CH")" = y ]; then
        ok "chromium survived two namespaces' Xwayland arriving beside it"
    else
        bad "chromium died when the Xwaylands arrived"
    fi
elif [ "$(alive "$P_FF1")" = y ] && [ "$(alive "$P_CH")" = y ]; then
    ok "both browsers survived two namespaces' Xwayland arriving beside them"
else
    bad "a browser died when the Xwaylands arrived: firefox $(alive "$P_FF1"), chromium $(alive "$P_CH")"
fi
# THE HONEST NOTE, printed rather than hidden: this arm would have fitted
# under the old ceiling too. The arm below is the one that would not.
if [ "$A_CONNS" -le 16 ]; then
    info "NOTE: arm A is $A_CONNS connections and WOULD have fitted in the old MAXCONN 16 -- chromium is 2, not 8, so 'two browsers' was not one number. Arm B is the case that did not fit."
else
    info "arm A alone is $A_CONNS connections, already past the old ceiling of 16"
fi

# ---------------------------------------------------------------------------
# 3. ARM B: TWO OF THE SAME BROWSER -- the case the old ceiling refused
# ---------------------------------------------------------------------------
# `enter debian { firefox }` beside the native one. Two 8s, and then the two
# namespaces' Xwayland on top: this is 18 and sixteen cannot hold it.
echo "twobr: === 3. arm B: a SECOND FIREFOX -- 8 + 8, which is what 16 could not hold"
if [ "$FF_OK" = 0 ]; then
    # THE WHOLE ARM IS FIREFOX. 8 + 8 cannot be driven with zero, and driving
    # it anyway would produce four confident FAILs about a ceiling that was
    # never approached -- the exact red this gate used to print.
    B_CONNS="$(st conns)"; B_WINS="$(st windows_high_water)"
    skip "ARM B (two firefox-esr, 8 + 8, the case MAXCONN 16 could not hold) -- NOT DRIVEN: this host cannot start one firefox, let alone two"
    skip "    the second firefox's own appetite -- UNMEASURED"
    skip "    a desktop past the old ceiling of 16 -- UNREACHED: this run peaked at $B_CONNS connections, which is what chromium and two Xwaylands cost, NOT a verdict on the ceiling"
    skip "    three browsers alive at once -- UNTESTED"
    skip "    every browser having a surface -- UNTESTED (windows_high_water $B_WINS)"
else
BEFORE_FF2="$(st conns)"
start_firefox b; P_FF2="$LAST_PID"
settle 45
FF2_CONNS=$(( $(st conns) - BEFORE_FF2 ))
B_CONNS="$(st conns)"
B_REFUSED="$(st conn_refused)"
B_WINS="$(st windows_high_water)"
info "second firefox-esr: $FF2_CONNS connections; total conns $B_CONNS, conn_refused ${B_REFUSED:-0}, windows_high_water $B_WINS"
if [ "$FF2_CONNS" -ge 8 ]; then
    ok "the second firefox opened its own $FF2_CONNS connections -- a browser's appetite is per INSTANCE, not per machine"
else
    bad "the second firefox opened only $FF2_CONNS connections; if it was truncated this arm is measuring nothing"
fi
if [ "${B_REFUSED:-1}" = 0 ]; then
    ok "$B_CONNS connections live at once and conn_refused is 0 -- nothing was turned away"
else
    bad "conn_refused is $B_REFUSED at $B_CONNS connections: a program was refused inside the ceiling"
fi
if [ "$B_CONNS" -gt 16 ]; then
    ok "the desktop is at $B_CONNS connections, PAST the old ceiling of 16 -- this is the workload that used to lose a whole program"
else
    bad "the desktop only reached $B_CONNS connections, so this arm does not exercise anything 16 could not do"
fi
FF1_A="$(alive "$P_FF1")"; FF2_A="$(alive "$P_FF2")"; CH_A="$(alive "$P_CH")"
if [ "$FF1_A" = y ] && [ "$FF2_A" = y ] && [ "$CH_A" = y ]; then
    ok "THREE BROWSERS AND TWO NAMESPACES ARE RUNNING AT ONCE: firefox, firefox, chromium, two Xwaylands, two X clients"
else
    bad "not everything survived: firefox-a $FF1_A, firefox-b $FF2_A, chromium $CH_A"
fi
if [ "${B_WINS:-0}" -ge 3 ]; then
    ok "windows_high_water $B_WINS -- every browser has a surface, not just a slot on the connection table"
else
    bad "windows_high_water is $B_WINS with three browsers up: at least one is connected and blind"
fi
fi
# AND IT IS NOT A GAP ANSWERING SOMETHING SUCCESS-SHAPED: the server's own
# counters must show no window budget refusal and no dropped surface either.
for c in window_budget_full drop_no_window drop_no_slot frame_callbacks_full obj_id_refused; do
    v="$(st $c)"
    if [ "${v:-0}" = 0 ]; then
        ok "$c is 0 -- the connections fitting did not just move the failure to a window"
    else
        bad "$c is $v: the connection table held, and something else ran out instead"
    fi
done

# ---------------------------------------------------------------------------
# 4. THE PRICE, and it is the whole reason this was affordable
# ---------------------------------------------------------------------------
echo "twobr: === 4. what a desktop this size costs in resident memory"
SEGSZ=$(stat -c %s "$HAMWSYS" 2>/dev/null || echo 0)
SEGRES=$(du -k "$HAMWSYS" 2>/dev/null | awk '{print $1}')
MAXWIN="$(adnum user/wsyswl.ad MAXWIN)"
info "the window table: $((SEGSZ / 1048576)) MiB of address space ($MAXWIN rows), $SEGRES KiB RESIDENT with $B_WINS windows open"
# Before this pass the same table was memset whole on first attach, so this
# number would have been the whole segment whatever was open.
if [ "${SEGRES:-0}" -lt $((SEGSZ / 1024 / 2)) ]; then
    ok "$SEGRES KiB resident of $((SEGSZ / 1024)) KiB mapped -- three browsers and two namespaces cost less than a tenth of what an EMPTY table used to"
else
    bad "the table is $SEGRES KiB resident of $((SEGSZ / 1024)) KiB: it is being faulted in whole"
fi
if [ -f "$HAMWSYS_BB" ]; then
    BBSZ=$(stat -c %s "$HAMWSYS_BB"); BBRES=$(du -k "$HAMWSYS_BB" | awk '{print $1}')
    info "the paint pool: $((BBSZ / 1048576)) MiB of address space, $BBRES KiB allocated"
fi

# ---------------------------------------------------------------------------
# 5. THE NEGATIVE CONTROL: the same workload against the OLD ceiling
# ---------------------------------------------------------------------------
# A gate that only shows the new number working is a gate that would pass on a
# machine where the ceiling never mattered. So the control is run here rather
# than described: the SAME source, MAXCONN put back to 16, the same two
# Firefoxes -- and the second one must be refused BY NAME, naming 16.
#
# Only MAXCONN is changed and the per-connection arrays are left at their
# MAXCONN-32 sizes. That is deliberate and it is safe in this direction only:
# an array bigger than the ceiling wastes BSS, an array smaller than it is an
# out-of-bounds write. It also keeps the control honest -- the ONE thing
# different between the two binaries is the number being tested, not 35 array
# bounds as well.
echo "twobr: === 5. the control: MAXCONN back to 16, same two browsers"
reap_browsers
for p in $XW1 $XW2; do kill -TERM "$p" 2>/dev/null; done
sleep 1
for p in $XW1 $XW2; do kill -KILL "$p" 2>/dev/null; done
for p in $SERVERS; do kill -TERM "$p" 2>/dev/null; done
sleep 1.5
for p in $SERVERS; do kill -KILL "$p" 2>/dev/null; done
SERVERS=""

sed 's/^MAXCONN: uint64 = 32$/MAXCONN: uint64 = 16/' user/wsyswl.ad >"$WORK/wsyswl16.ad"
if grep -q '^MAXCONN: uint64 = 16$' "$WORK/wsyswl16.ad"; then
    ok "the control source differs from the shipped one in exactly one number: MAXCONN 32 -> 16"
else
    bad "could not build a MAXCONN=16 control out of user/wsyswl.ad"
fi
scripts/hamlinux_build.sh "$WORK/wsyswl16.ad" "$WORK/wsyswl16.elf" \
    >"$WORK/wsyswl16.build.log" 2>&1 || {
    bad "the MAXCONN=16 control did not build"; tail -20 "$WORK/wsyswl16.build.log"; }

# A COMPLETELY FRESH SEGMENT. The v7 table this run just made would otherwise
# be inherited, and the control would be measuring the wrong thing.
W2="$WORK/ctl"; mkdir -p "$W2"
export HAMWSYS="$W2/wsys.shm" HAMWSYS_BB="$W2/wsys.bb" HAMWSYS_IMG="$W2/wsys.img"
export HAMFB_FILE="$W2/fb.raw"
"$WORK/wsysd.elf" </dev/null >"$W2/wsysd.log" 2>&1 & SERVERS="$SERVERS $!"
sleep 1.5
"$WORK/wsyswl16.elf" "$W2/wayland-0" </dev/null \
    >"$W2/wsyswl.log" 2>"$W2/wsyswl.err" & SERVERS="$SERVERS $!"
for _ in $(seq 1 60); do [ -S "$W2/wayland-0" ] && break; sleep 0.1; done
STATE="$W2/wsyswl-state"
export XDG_RUNTIME_DIR="$W2" WAYLAND_DISPLAY=wayland-0
sleep 1
# An empty read is not a measurement -- see tests/linux/gate_read.sh. THE WAIT
# ABOVE IS FOR THE SOCKET, AND THE SOCKET IS NOT THE STATE FILE. wsyswl writes
# `limits shared MAXCONN=<n>` only when it dumps its stats, and it dumps them
# when something makes them dirty; a server that has just started and has no
# clients yet may not have written the file at all. `sed ... 2>/dev/null` on a
# missing file is the empty string, "" is not 16, and the gate said "the
# control server does not report MAXCONN=16" -- a defect named against a build
# whose state file it had not managed to read. So POLL for the line, and if it
# never comes, say which read failed instead of what the server does.
C_MAXCONN=""
for _ in $(seq 1 "${TWOBR_MAXCONN_WAIT:-60}"); do   # half-seconds; the demo shortens it
    C_MAXCONN="$(sed -n 's/.*[ ]MAXCONN=\([0-9]*\).*/\1/p' "$STATE" 2>/dev/null | tail -1)"
    [ -n "$C_MAXCONN" ] && break
    sleep 0.5
done
if ! gate_nonempty "the control server's own ceiling, from '$STATE' (no 'MAXCONN=<n>' written in 30s)" "$C_MAXCONN"; then
    :   # gate_nonempty named the read; whether the control really carries the
        # ceiling is unanswered, and the sections below are measuring an
        # UNCONFIRMED build -- which is why this leaves a FAIL behind it.
elif [ "$C_MAXCONN" = 16 ]; then
    ok "the control server states its own ceiling: MAXCONN=16"
else
    bad "the control server reports MAXCONN=$C_MAXCONN, not 16 -- the one number this control was built to change did not change"
fi

# THE SAME WORKLOAD, IN THE SAME ORDER AS A REAL SESSION: the namespaces come
# up with the desktop, and the browsers are what the person starts. Two
# Xwaylands are 2; the first Firefox takes it to 10; the second wants 8 more,
# which is 18, and 18 does not fit in 16. Exactly the arithmetic HANDOFF named.
#
# THE CONTROL IS TWO FIREFOXES. Its whole content is "the second one is refused
# at 16", so on a host that cannot start the first one there is no control to
# run -- and a control that cannot run must SAY SO, because section 3's claim
# rests on it. Note this is reached only when the arms above were skipped too:
# it is never the case that section 3 passes and its control is quietly absent.
if [ "$FF_OK" = 0 ]; then
    skip "THE NEGATIVE CONTROL (MAXCONN=16 refusing a second firefox) -- NOT RUN: it needs the two browsers this host cannot start"
    skip "    the control binary BUILT and reports its own ceiling correctly (asserted above); what is unproven here is that the ceiling BITES"
    skip "    so nothing in this run demonstrates that MAXCONN 32 removes a failure MAXCONN 16 produces"
else
start_xwayland :73; C_XW1="$LAST_PID"; sleep 2
start_xwayland :74; C_XW2="$LAST_PID"; sleep 2
sleep 2
info "control, two Xwaylands: conns $(st conns)"
start_firefox c; C_FF1="$LAST_PID"
settle 40
C1="$(st conns)"
info "control, + one firefox: conns $C1 conn_refused $(st conn_refused)"
start_firefox d; C_FF2="$LAST_PID"
settle 45
C2="$(st conns)"; C_REF="$(st conn_refused)"
info "control, + a SECOND firefox: conns $C2 conn_refused ${C_REF:-0} windows_high_water $(st windows_high_water)"
if [ "${C_REF:-0}" -gt 0 ]; then
    ok "AT MAXCONN 16 THE SECOND BROWSER IS REFUSED: conn_refused ${C_REF} -- this is the failure the shipped number removes, reproduced on demand"
else
    bad "the MAXCONN=16 control refused nothing (conns $C2): the control is not exercising the ceiling, so section 3's pass proves nothing"
fi
# AND IT MUST STILL FAIL BY NAME. The regression this tree paid for once was a
# refused client printing `No wl_shm global`, blaming a feature that is
# present. The refusal has to name the limit and its value, at 16 as at 32.
# -a here for the same reason as section 1: a single NUL anywhere in the
# compositor's stderr would make grep silent, and a silent grep on this line
# invents the FAIL "the control's stderr says nothing about a refused client"
# against a server that said it perfectly well.
CMSG="$(grep -a -m1 'connection table full' "$W2/wsyswl.err" 2>/dev/null)"
if grep -a -q "too many clients -- raise MAXCONN" "$W2/wsyswl.err"; then
    ok "the control refuses BY NAME on its own stderr, not in silence"
else
    bad "the control's stderr says nothing about a refused client"
fi
if [ "${C_REF:-0}" -gt 0 ] && [ "${C2:-0}" -le 16 ]; then
    ok "the control's table stopped at $C2 of 16 -- the ceiling is what refused, not a browser that failed to start"
else
    info "control conns $C2"
fi
fi

echo "twobr: ---------------------------------------------"
echo "twobr: PASS $pass  FAIL $fail  SKIP $skipped"
# A SKIP IS LOUD, AND IT IS NEVER FILED UNDER PASS. A reader skimming for the
# last line must not be able to mistake "the browser would not start" for "two
# browsers fit". The counts stay separate and the verdict names the skips.
if [ "$skipped" -gt 0 ]; then
    echo "twobr: INCOMPLETE -- $skipped assertion(s) DID NOT RUN. This run did not test its own subject"
    echo "twobr: INCOMPLETE    (two browsers at once); do not read it as evidence that they fit."
fi
# THE OPPOSITE MISTAKE, GUARDED. This tree has a gate on record that exited
# GREEN having scored ZERO ARMS. A run that asserted nothing has not passed,
# whatever its fail count says.
if [ "$pass" = 0 ]; then
    echo "twobr: REFUSING A GREEN VERDICT -- 0 assertions passed, so this run measured nothing at all"
    exit 1
fi
[ "$fail" = 0 ] || exit 1
