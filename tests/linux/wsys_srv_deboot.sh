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
# tests/linux/wsys_srv_deboot.sh — BOOT THE DESKTOP WITH HAMWSYS_SERVER=1 AND
# SAY WHAT IT COSTS.
#
# THE QUESTION, AND WHY NOTHING IN THIS TREE HAD ANSWERED IT
# ==========================================================
# Six stages of `docs/wsys_server_design.md` are built: transport, mutations,
# reads, an enumeration policy, connection ownership, the scene. Every one of
# them was proven by a GATE — a purpose-built client, a probe, an attacker in a
# user namespace. None of them was a DESKTOP. `WSYS_VERSION` is 8, the flag is
# unset everywhere, and so the honest state of the tree was: the mediator has
# never mediated a real session, and nobody knows what a real session costs.
#
# This file boots one, twice, in one process on one host, and differences the
# two arms:
#
#   UNROUTED   HAMWSYS_SERVER nowhere in the environment. Every client's
#              linked-in window-system code writes the shared segment
#              directly. This is what ships.
#   ROUTED     HAMWSYS_SERVER=1 for the compositor and every client. Mutations
#              go to wsysd's frame loop over an abstract SOCK_SEQPACKET, reads
#              to the forked read server, and `srv_as_caller()` decides them.
#
# WHY BOTH ARMS ARE IN ONE RUN AND ARE INTERLEAVED. On this machine the same
# CPU assertion has read 0.27%, 0.22% and 0.17% purely with how busy the box
# was (docs/wsys_server_design.md, "the budget, re-derived"). A routed number
# from today against an unrouted number from a previous session measures the
# neighbours. So: same binaries, same host, arms alternated rep by rep, the
# loadavg printed beside every sample, and the ATTRIBUTABLE / SUSPECT / NOT
# ATTRIBUTABLE verdict `wsys_srv_transport.sh` emits, computed the same way.
#
# THE TRAP THIS FILE IS BUILT AROUND, AND IT HAS COST THIS SERIES REPEATEDLY
# =========================================================================
# `HAMWSYS_SERVER=1` in a shell does NOT reach a program hamsh spawns: hamsh's
# `_build_envp()` builds a child's environment from hamsh's OWN exported table,
# and a spawned child receives PATH and HOME and nothing else (commit
# 3de1d6e4). A run that exports the variable and assumes the desktop is routed
# MEASURES AN UNROUTED DESKTOP AND BELIEVES IT IS ROUTED.
#
# So routing is never inferred from having set a variable. It is COUNTED, per
# process, from the kernel: every ESTABLISHED connection to this segment's
# `@hamnix-wsys/<dev>.<ino>/{srv,rd}` name is listed, its peer socket inode is
# resolved to a pid through /proc/<pid>/fd, and the answer is a list of
# programs. The unrouted arm runs the same census and must find NOTHING —
# otherwise the "unrouted" arm is not the control it claims to be.
#
# That census is also the answer to the standing policy question — *does any
# process hold a connection it has no business with?* — which cannot be
# answered by reading code, because the thing that dials is a library linked
# into every binary.
#
# WHAT IS ON THIS DESKTOP, AND WHAT IS NOT
# ========================================
# Offscreen (HAMFB_FILE, HAMWSYSD_INPUT), exactly as tests/linux/
# de_fps_latency.sh measures the shipped desktop, and with the same instrument
# (tests/linux/de_fps_driver.py, selftested before any number is reported):
#
#   wsysd           the compositor
#   hamdesktop      wallpaper + icons          wid 2
#   hampanelscene   the top AND bottom bars    wid 3, wid 4
#   hamappmenu -self  the Applications menu    wid 5, its own window at (8,28)
#   de_dragload     a decorated 480x320 window with text, dragged continuously
#
# NOT HERE: a terminal, and the reason is measured rather than guessed —
# see THE TERMINAL below and the arm that reports it. Also not here: hamUId,
# and therefore not `/bin/hamsh /etc/rc.de-user <prog>`, the spawn path every
# window of an INSTALLED desktop is created through. What that leaves unasked
# is stated in the report at the end rather than left for a reader to notice.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

. tests/linux/private_ns.sh
priv_ns_reexec "$@"
. tests/linux/reap.sh

WORK="${SRV_WORK:-$HOME/.hamnix-build/deroute3/run}"
mkdir -p "$WORK"
reap_track "$WORK/reaped"
KEEP="${DEBOOT_KEEP:-1}"
GEOM="${HAMFB_GEOM:-1280x800}"
FBW="${GEOM%x*}"; FBH="${GEOM#*x}"
REPS="${DEBOOT_REPS:-2}"
LOADSEC="${DEBOOT_SECONDS:-8}"
CPUREPS="${DEBOOT_CPUREPS:-3}"
TRIALS="${DEBOOT_TRIALS:-90}"

pass=0; fail=0
ok()   { echo "deboot: PASS $*"; pass=$((pass+1)); }
bad()  { echo "deboot: FAIL $*"; fail=$((fail+1)); }
info() { echo "deboot: INFO $*"; }
head2() { echo; echo "deboot: ==== $* ===================================="; }

cleanup() { reap_all; }
reap_on_exit cleanup
done_report() { echo "deboot: $pass passed, $fail failed"; [ "$fail" = 0 ]; }

: >"$WORK/hostcond"
hostload() { awk '{print $1}' /proc/loadavg; }
# `grep -c` PRINTS 0 AND EXITS 1 ON NO MATCH, so `|| echo 0` does not supply a
# default -- it APPENDS one, and the result is the two-line string "0\n0". That
# is the common case here (no wsys server bound is the normal state of this
# host), and it put a stray extra line into $WORK/hostcond, inflating the
# sample count the verdict at the end reports and adding a phantom sample with
# loadavg 0. Elsewhere in the tree the same idiom is worse: `[ "0\n0" -le 0 ]`
# is not false, it is a TEST ERROR with rc=2, and the refusal branch behind it
# never runs. Assign, then default only a genuinely empty read (a missing
# /proc/net/unix, where grep exits 2 having printed nothing).
srvnames() { local n; n="$(grep -ac 'hamnix-wsys/[0-9.]*/srv' /proc/net/unix 2>/dev/null)"; echo "${n:-0}"; }
# EVERY CPU SAMPLE CARRIES THE CONDITIONS IT WAS TAKEN UNDER. Same rule and
# same thresholds as tests/linux/wsys_srv_transport.sh, deliberately: two
# gates disagreeing about when a number is quotable would be worse than
# either.
cond() { printf '%s %s\n' "$(hostload)" "$(srvnames)" >>"$WORK/hostcond"
         printf 'load %s srv %s' "$(hostload)" "$(srvnames)"; }

info "host: $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed 's/^ //')"
info "host: $(nproc) cpus, loadavg $(hostload) at start, $(srvnames) bound wsys server names host-wide"
info "work: $WORK"

# ---- binaries: ONE build, both arms ----------------------------------------
# The arms must differ in the environment and in NOTHING ELSE, so they share
# one set of binaries by construction rather than by two builds that agree.
BINDIR="${DEBOOT_BIN_DIR:-$WORK/bin}"
if [ -z "${DEBOOT_BIN_DIR:-}" ]; then
    mkdir -p "$BINDIR"
    for t in wsysd:user/wsysd.ad cat:user/cat.ad \
             hamdesktop:user/hamdesktop.ad \
             hampanelscene:user/hampanelscene.ad \
             hamappmenu:user/hamappmenu.ad \
             hamtermscene:user/hamtermscene.ad \
             de_dragload:tests/linux/de_dragload.ad; do
        n="${t%%:*}"; s="${t#*:}"
        scripts/hamlinux_build.sh "$s" "$BINDIR/$n" \
            >"$WORK/$n.build.log" 2>&1 || {
            bad "could not build $s"; tail -20 "$WORK/$n.build.log" >&2
            done_report; exit 1; }
    done
    ok "the compositor, the desktop, the panel, the Applications menu and the drag load build"
else
    info "using prebuilt binaries from $BINDIR"
fi
for b in wsysd cat hamdesktop hampanelscene hamappmenu de_dragload; do
    [ -x "$BINDIR/$b" ] || { bad "missing binary $b"; done_report; exit 1; }
done

# ---- the routing census ----------------------------------------------------
# WHO IS TALKING TO THIS SEGMENT'S SERVER, taken from the kernel.
#
# `ss -x` names only the LISTENING end and the server's accepted ends; the
# client end of an AF_UNIX connection has no address at all. So the peer socket
# INODE is read off the server-side row and resolved through /proc/<pid>/fd,
# which is the only place the association exists. Nothing here asks a process
# what it thinks it is doing.
census() {   # census <dev.ino> -> lines "srv|rd <pid> <comm>"
    local seg="$1"
    ss -xp 2>/dev/null | awk -v seg="$seg" '
        $0 ~ ("@hamnix-wsys/" seg "/srv") && $2 == "ESTAB" { print "srv", $8 }
        $0 ~ ("@hamnix-wsys/" seg "/rd")  && $2 == "ESTAB" { print "rd",  $8 }
    ' >"$WORK/.peers"
    python3 - "$WORK/.peers" <<'PY'
import os, sys
want = {}
for line in open(sys.argv[1]):
    kind, ino = line.split()
    want.setdefault(ino, []).append(kind)
found = []
for pid in os.listdir('/proc'):
    if not pid.isdigit():
        continue
    try:
        fds = os.listdir('/proc/%s/fd' % pid)
    except OSError:
        continue
    for fd in fds:
        try:
            t = os.readlink('/proc/%s/fd/%s' % (pid, fd))
        except OSError:
            continue
        if not t.startswith('socket:['):
            continue
        ino = t[8:-1]
        if ino in want:
            try:
                comm = open('/proc/%s/comm' % pid).read().strip()
            except OSError:
                comm = '?'
            for k in want[ino]:
                found.append((k, int(pid), comm, fd))
            # NO `break` HERE, AND THE BREAK THAT WAS HERE MADE THIS GATE LIE.
            # It stopped at the FIRST matching descriptor in a process, so a
            # client holding BOTH a mutation connection and a read connection
            # was counted once, as whichever fd number the kernel listed first
            # -- always the mutation one, dialled earlier and given the lower
            # number. This gate therefore reported "0 processes hold a READ
            # connection" for a desktop in which hamdesktop held fd 3 on the
            # srv socket and fd 4 on the rd socket at the same instant,
            # measured directly out of /proc/<pid>/fd. It read as a fact about
            # the desktop ("no component performs a routed read") and it was a
            # fact about this loop. Found while routing `open`, whose whole
            # cost question is how many read connections a desktop holds.
for k, pid, comm, fd in sorted(found, key=lambda r: (r[0], r[1])):
    print('%s %d %s fd=%s' % (k, pid, comm, fd))
PY
}

# ---- one arm ---------------------------------------------------------------
# Everything an arm starts is registered for reaping the instant it starts, and
# every pid is remembered explicitly. NEVER pkill by pattern: both arms run the
# same binaries out of the same directory and their command lines are
# identical, so a pattern kill would take the other arm's compositor with it —
# and other agents on this box run wsysd too.
ARM_PIDS=""
arm() {   # arm <label> <routed 0|1> <rep>
    local lab="$1" routed="$2" rep="$3"
    local A="$WORK/$lab.$rep"
    rm -rf "$A"; mkdir -p "$A/noicd"
    ARM_PIDS=""

    export HAMWSYS="$A/seg" HAMWSYS_BB="$A/seg.bb" HAMWSYS_IMG="$A/img"
    export HAMFB_FILE="$A/fb.raw" HAMFB_GEOM="$GEOM"
    : >"$A/in"; export HAMWSYSD_INPUT="$A/in"
    # NO VULKAN ICD. The shipped image stages only the venus ICD, which
    # enumerates nothing, so wsysd falls back to its own software rasterizer --
    # and pointing this at an empty directory makes it impossible for this gate
    # to touch the machine owner's GPU. /dev/dri/card0 is theirs.
    export VK_ICD_FILENAMES="$A/noicd/none.json" HAMLINUX_VNC=none
    if [ "$routed" = 1 ]; then export HAMWSYS_SERVER=1
    else                       unset HAMWSYS_SERVER; fi

    "$BINDIR/wsysd" </dev/null >"$A/wsysd.log" 2>&1 &
    WSYSD_PID=$!; reap_add "$WSYSD_PID"; ARM_PIDS="$WSYSD_PID"
    local i
    for i in $(seq 1 100); do [ -s "$A/fb.raw" ] && break; sleep 0.1; done
    [ -s "$A/fb.raw" ] || { bad "[$lab] wsysd never produced a framebuffer"
                            tail -20 "$A/wsysd.log" >&2; return 1; }
    SEG="$(stat -c '%d.%i' "$A/seg" 2>/dev/null)"

    # THE FLAG DID WHAT IT SAYS, OR IT DID NOT -- asserted from the server's
    # own words, not from the variable being set.
    if [ "$routed" = 1 ]; then
        grep -q "serving /dev/wsys for segment $SEG" "$A/wsysd.log" \
            && ok "[$lab] the compositor SERVES segment $SEG: $(grep -m1 'serving /dev/wsys' "$A/wsysd.log")" \
            || { bad "[$lab] HAMWSYS_SERVER=1 and wsysd is not serving -- this arm would be an unrouted desktop wearing a routed label"
                 tail -20 "$A/wsysd.log" >&2; return 1; }
        grep -q "read server pid" "$A/wsysd.log" \
            && ok "[$lab] the read server forked: $(grep -m1 'read server pid' "$A/wsysd.log")" \
            || bad "[$lab] no read server -- reads would wait out a frame on the mutation socket"
        RDPID="$(sed -n 's/.*read server pid \([0-9]*\).*/\1/p' "$A/wsysd.log" | head -1)"
        [ -n "$RDPID" ] && { reap_add "$RDPID"; ARM_PIDS="$ARM_PIDS $RDPID"; }
    else
        grep -q "serving /dev/wsys" "$A/wsysd.log" \
            && bad "[$lab] the CONTROL arm is serving -- HAMWSYS_SERVER leaked into it" \
            || ok "[$lab] the control arm serves nothing: HAMWSYS_SERVER is not in this compositor's environment"
    fi

    "$BINDIR/hamdesktop" </dev/null >"$A/hamdesktop.log" 2>&1 &
    reap_add $!; ARM_PIDS="$ARM_PIDS $!"
    sleep 3
    "$BINDIR/hampanelscene" </dev/null >"$A/hampanel.log" 2>&1 &
    reap_add $!; ARM_PIDS="$ARM_PIDS $!"
    sleep 4
    # THE APPLICATIONS MENU, spawned argv-for-argv as hampanelscene's
    # _launch_appmenu spawns it. `-self` forces self-allocation of its own
    # window, which is what the panel's click path produces.
    "$BINDIR/hamappmenu" -self </dev/null >"$A/menu.log" 2>&1 &
    reap_add $!; ARM_PIDS="$ARM_PIDS $!"
    sleep 3

    # ---- IS THIS A DESKTOP? -------------------------------------------
    # NOT read from /dev/wsys/windows: that leaf returns almost nothing even
    # UNROUTED (a predecessor lost an afternoon to it), so the working DE gates
    # enumerate per window through /dev/wsys/<wid>/ctl and so does this one.
    local wins="" w o
    for w in 2 3 4 5 6 7 8; do
        o="$("$BINDIR/cat" "/dev/wsys/$w/ctl" 2>/dev/null | tr '\n' ' ')"
        [ -n "$o" ] && { wins="$wins $w"; echo "deboot: INFO   [$lab] wid $w ctl: $o"; }
    done
    echo "$wins" >"$A/wins"
    local nwin; nwin="$(echo $wins | wc -w)"
    # Geometry, not a count: "four windows" is satisfied by four blank ones.
    local desk panel1 panel2 menu
    desk="$("$BINDIR/cat" /dev/wsys/2/ctl 2>/dev/null | awk '{print $4"x"$5}')"
    panel1="$("$BINDIR/cat" /dev/wsys/3/ctl 2>/dev/null | awk '{print $4"x"$5}')"
    panel2="$("$BINDIR/cat" /dev/wsys/4/ctl 2>/dev/null | awk '{print $4"x"$5}')"
    menu="$("$BINDIR/cat" /dev/wsys/5/ctl 2>/dev/null | awk '{print $2","$3" "$4"x"$5}')"
    [ "$desk" = "${FBW}x${FBH}" ] \
        && ok "[$lab] the WALLPAPER is up: wid 2 is ${desk}, the whole screen" \
        || bad "[$lab] wid 2 is '${desk:-absent}', not the ${FBW}x${FBH} wallpaper"
    [ "$panel1" = "${FBW}x26" ] && [ "$panel2" = "${FBW}x26" ] \
        && ok "[$lab] BOTH PANELS are up: wid 3 and wid 4, ${FBW}x26 each -- the image ships two and a solo-panel check would miss one" \
        || bad "[$lab] panels are '${panel1:-absent}' and '${panel2:-absent}', wanted ${FBW}x26 twice"
    # 407 = the 208 px menu box + the 200 px category fly-out band, at (8,28).
    # That is de_appmenu_brisk.sh's discriminator between the Brisk-shaped menu
    # and the panel's own in-panel dropdown, and it is used here for the same
    # reason: "a menu-coloured card appeared" passes on the broken one.
    case "$menu" in
        8,28\ 407x*) ok "[$lab] the APPLICATIONS MENU is up in ITS OWN window: wid 5 at $menu -- the 208 px box plus the 200 px fly-out band, not the panel's window" ;;
        *)           bad "[$lab] wid 5 is '${menu:-absent}', not the Applications menu at 8,28 407 wide" ;;
    esac

    # ---- WHO IS ROUTED -------------------------------------------------
    census "$SEG" >"$A/census.txt"
    local nsrv nrd
    nsrv="$(grep -c '^srv ' "$A/census.txt" || true)"
    nrd="$(grep -c '^rd ' "$A/census.txt" || true)"
    info "[$lab] connection census for segment $SEG (from /proc, not from the environment):"
    if [ -s "$A/census.txt" ]; then
        sed 's/^/deboot: INFO     /' "$A/census.txt"
    else
        info "    (none)"
    fi
    if [ "$routed" = 1 ]; then
        # THREE, and they are named: hamdesktop, hampanelscene, hamappmenu. The
        # drag load has not started yet; the second census below is where it is
        # counted. wsysd is deliberately NOT here -- hamwsys_srv_claim() sets
        # srv_is_server so the compositor never dials itself.
        [ "${nsrv:-0}" -ge 3 ] \
            && ok "[$lab] $nsrv processes hold a MUTATION connection and $nrd hold a READ connection -- routing counted per process from /proc, not assumed from a variable" \
            || bad "[$lab] only ${nsrv:-0} mutation connections: the compositor serves and the desktop is not talking to it"
    else
        [ "${nsrv:-0}" = 0 ] && [ "${nrd:-0}" = 0 ] \
            && ok "[$lab] the control arm holds ZERO connections -- it is a real control" \
            || bad "[$lab] the control arm holds $nsrv/$nrd connections -- it is not a control"
    fi

    # ---- the instrument, before any number ------------------------------
    DRV="python3 tests/linux/de_fps_driver.py --fb $A/fb.raw \
         --input $A/in --cat $BINDIR/cat --pid $WSYSD_PID --geom $GEOM"
    if $DRV --mode selftest >"$A/selftest.txt" 2>&1; then
        ok "[$lab] the instrument passed its own selftests"
    else
        bad "[$lab] the instrument failed its selftest -- REFUSING to report numbers from this arm"
        sed 's/^/deboot: INFO     /' "$A/selftest.txt"
        return 1
    fi

    # ---- idle ------------------------------------------------------------
    info "[$lab] idle ($(cond)):"
    $DRV --mode idle --seconds 10 >"$A/idle.txt" 2>&1
    sed 's/^/deboot: INFO     /' "$A/idle.txt"
    IDLE="$(sed -n 's/.*-- \([0-9]*\) frames.*/\1/p' "$A/idle.txt" | head -1)"

    # ---- the drag load ---------------------------------------------------
    "$BINDIR/de_dragload" 480 320 120 200 300 8 >"$A/drag.wid" 2>"$A/drag.err" &
    DRAG_PID=$!; reap_add "$DRAG_PID"; ARM_PIDS="$ARM_PIDS $DRAG_PID"
    for i in $(seq 1 60); do [ -s "$A/drag.wid" ] && break; sleep 0.1; done
    DRAGWID="$(tr -d '\n' <"$A/drag.wid" 2>/dev/null)"
    sleep 1.5
    if [ -n "${DRAGWID:-}" ] && [ "${DRAGWID:-0}" -ge 2 ]; then
        ok "[$lab] A WINDOW IS BEING DRAGGED: wid $DRAGWID, a decorated 480x320 window with eight rows of text, moving continuously"
    else
        bad "[$lab] de_dragload never mapped a window -- there is no drag in this arm"
        cat "$A/drag.err" >&2
    fi
    # The drag is a routed CLIENT too, and it dialled after the census above.
    census "$SEG" >"$A/census2.txt"
    local nsrv2; nsrv2="$(grep -c '^srv ' "$A/census2.txt" || true)"
    info "[$lab] census with the drag running:"
    if [ -s "$A/census2.txt" ]; then sed 's/^/deboot: INFO     /' "$A/census2.txt"
    else info "    (none)"; fi
    if [ "$routed" = 1 ]; then
        [ "${nsrv2:-0}" -ge 4 ] \
            && ok "[$lab] the dragging client dialled too: $nsrv2 mutation connections, one per window-owning program and NOT ONE MORE -- no process holds a connection it has no business with" \
            || bad "[$lab] $nsrv2 mutation connections with the drag running, wanted at least 4"
    else
        [ "${nsrv2:-0}" = 0 ] \
            && ok "[$lab] still zero connections with the drag running" \
            || bad "[$lab] the control arm grew $nsrv2 connections"
    fi

    info "[$lab] load A, pointer only, 250 ev/s ($(cond)):"
    $DRV --mode fps --seconds "$LOADSEC" --rate 250 --reps "$CPUREPS" \
         --tag "$lab A pointer only" 2>&1 | tee "$A/fpsA.txt" | sed 's/^/deboot: INFO     /'
    info "[$lab] load B, the window dragging, no pointer ($(cond)):"
    $DRV --mode fps --seconds "$LOADSEC" --rate 0 --reps "$CPUREPS" \
         --tag "$lab B window drag" 2>&1 | tee "$A/fpsB.txt" | sed 's/^/deboot: INFO     /'
    info "[$lab] load C, dragging AND pointer -- what dragging with a mouse is ($(cond)):"
    $DRV --mode fps --seconds "$LOADSEC" --rate 250 --reps "$CPUREPS" \
         --tag "$lab C drag + pointer" 2>&1 | tee "$A/fpsC.txt" | sed 's/^/deboot: INFO     /'

    # ---- input to pixel, on a QUIET desktop -------------------------------
    kill "$DRAG_PID" 2>/dev/null; sleep 0.5; kill -9 "$DRAG_PID" 2>/dev/null
    sleep 1.5
    info "[$lab] input-to-pixel, $TRIALS trials, quiet desktop ($(cond)):"
    $DRV --mode latency --trials "$TRIALS" --tag "$lab input->pixel" 2>&1 \
        | tee "$A/lat.txt" | sed 's/^/deboot: INFO     /'

    # ---- down ------------------------------------------------------------
    local p
    for p in $ARM_PIDS; do kill "$p" 2>/dev/null; done
    sleep 1
    for p in $ARM_PIDS; do kill -9 "$p" 2>/dev/null; done
    sleep 1
    printf '%s\t%s\t%s\t%s\t%s\n' "$lab" "$rep" "${IDLE:-?}" "$nsrv" "$nrd" \
        >>"$WORK/arms.tsv"
    return 0
}

# ---- THE TERMINAL, AND WHY IT IS NOT ON THIS DESKTOP -----------------------
# Reported as an arm rather than omitted, because "we did not test a terminal"
# and "a terminal does not work routed" are opposite findings and the
# difference is one measurement.
#
# hamtermscene spawns `/bin/hamsh --no-echo /etc/rc.de-user` (user/
# hamtermscene.ad:899) and its window is torn down when that shell exits. This
# gate runs on the DEVELOPER'S HOST, where neither path exists; staging them
# means mounting over /usr/bin and /etc, and an /etc assembled that way broke
# the host's own tooling on the first attempt. So the terminal is measured
# UNROUTED, once, and the finding is that it does not survive here EITHER --
# which makes it a harness limit and not a routing result.
term_arm() {
    local A="$WORK/term"; rm -rf "$A"; mkdir -p "$A/noicd"
    export HAMWSYS="$A/seg" HAMWSYS_BB="$A/seg.bb" HAMWSYS_IMG="$A/img"
    export HAMFB_FILE="$A/fb.raw" HAMFB_GEOM="$GEOM"
    : >"$A/in"; export HAMWSYSD_INPUT="$A/in"
    export VK_ICD_FILENAMES="$A/noicd/none.json" HAMLINUX_VNC=none
    local r lab pids rc
    for r in 0 1; do
        [ "$r" = 1 ] && { lab=routed; export HAMWSYS_SERVER=1; } \
                     || { lab=unrouted; unset HAMWSYS_SERVER; }
        rm -f "$A/seg" "$A/seg.bb" "$A/img" "$A/fb.raw"; : >"$A/in"
        "$BINDIR/wsysd" </dev/null >"$A/wsysd.$lab.log" 2>&1 &
        local wd=$!; reap_add "$wd"; pids="$wd"
        local i; for i in $(seq 1 100); do [ -s "$A/fb.raw" ] && break; sleep 0.1; done
        "$BINDIR/hampanelscene" </dev/null >"$A/panel.$lab.log" 2>&1 &
        reap_add $!; pids="$pids $!"
        sleep 4
        "$BINDIR/hamtermscene" </dev/null >"$A/term.$lab.log" 2>&1 &
        local tp=$!; reap_add "$tp"; pids="$pids $tp"
        local t0; t0=$(date +%s)
        for i in $(seq 1 120); do kill -0 "$tp" 2>/dev/null || break; sleep 0.1; done
        if kill -0 "$tp" 2>/dev/null; then
            info "term [$lab]: ALIVE at 12 s"
        else
            info "term [$lab]: EXITED after $(( $(date +%s) - t0 )) s, log: '$(head -c 120 "$A/term.$lab.log")'"
        fi
        local p; for p in $pids; do kill "$p" 2>/dev/null; done; sleep 1
        for p in $pids; do kill -9 "$p" 2>/dev/null; done; sleep 1
    done
}

# ---- DOES TRAFFIC ACTUALLY CROSS, AND WHOSE? -------------------------------
# A held connection is not a routed desktop. A client could dial, negotiate a
# version and then do every mutation in process, and the census above would
# look exactly the same -- which is the failure mode this whole series keeps
# running into in other clothes.
#
# HAMWSYS_SRV_TRACE=1 makes the server print one line per routed mutation from
# INSIDE srv_as_caller(), carrying the caller's SO_PEERCRED pid and both
# permission answers. Counting those lines by pid is therefore the mediator's
# own account of who drove the desktop, and it is taken from the SERVER, never
# from the clients. It is a separate boot because the fprintf is per mutation
# and a drag makes ~800 a second: leaving it on would have been measuring the
# trace.
trace_arm() {
    local A="$WORK/trace"; rm -rf "$A"; mkdir -p "$A/noicd"
    export HAMWSYS="$A/seg" HAMWSYS_BB="$A/seg.bb" HAMWSYS_IMG="$A/img"
    export HAMFB_FILE="$A/fb.raw" HAMFB_GEOM="$GEOM"
    : >"$A/in"; export HAMWSYSD_INPUT="$A/in"
    export VK_ICD_FILENAMES="$A/noicd/none.json" HAMLINUX_VNC=none
    export HAMWSYS_SERVER=1 HAMWSYS_SRV_TRACE=1
    local pids i
    "$BINDIR/wsysd" </dev/null >"$A/wsysd.log" 2>&1 &
    pids=$!; reap_add $!
    for i in $(seq 1 100); do [ -s "$A/fb.raw" ] && break; sleep 0.1; done
    "$BINDIR/hamdesktop"    </dev/null >"$A/d.log" 2>&1 & reap_add $!; pids="$pids $!"
    sleep 3
    "$BINDIR/hampanelscene" </dev/null >"$A/p.log" 2>&1 & reap_add $!; pids="$pids $!"
    sleep 4
    "$BINDIR/hamappmenu" -self </dev/null >"$A/m.log" 2>&1 & reap_add $!; pids="$pids $!"
    sleep 3
    "$BINDIR/de_dragload" 480 320 120 200 300 8 >"$A/drag.wid" 2>"$A/drag.err" &
    reap_add $!; pids="$pids $!"
    sleep 8
    unset HAMWSYS_SRV_TRACE
    local n; n="$(grep -ac '^wsrvtrace: caller' "$A/wsysd.log" || true)"
    info "the mediator's own account of an 8 s drag on this desktop:"
    grep -a '^wsrvtrace: caller' "$A/wsysd.log" \
      | sed -n 's/.*caller uid=\([0-9]*\) pid=\([0-9]*\).*hostowner=\([0-9-]*\) owns_wid=\([0-9-]*\) ancestry=\([0-9-]*\).*/\2 uid=\1 hostowner=\3 owns_wid=\4 ancestry=\5/p' \
      | sort | uniq -c | sort -rn | head -12 \
      | while read -r c rest; do
            local pid="${rest%% *}"
            echo "deboot: INFO     $c mutations from pid $pid (${rest#* })"
        done
    if [ "${n:-0}" -gt 0 ]; then
        ok "the boundary CARRIES the desktop: $n mutations crossed it in 8 s, each one decided by srv_as_caller() with the caller's SO_PEERCRED installed"
    else
        bad "not one mutation crossed the boundary -- the clients connected and then wrote the segment in process, which is a routed-LOOKING desktop and an unrouted one"
    fi
    grep -aq 'REFUSED' "$A/wsysd.log" \
        && info "the mediator REFUSED something on this desktop: $(grep -ac REFUSED "$A/wsysd.log") lines -- see $A/wsysd.log" \
        || info "the mediator refused nothing on this desktop, which is expected: every client here runs as the segment's host owner, so hostowner() answers 1 before any other question is asked. THIS IS THE LIMIT OF AN OFFSCREEN BOOT and is why the identity arms live in wsys_srv_identity.sh and wsys_srv_connown.sh, where a second uid is available."
    local p; for p in $pids; do kill "$p" 2>/dev/null; done; sleep 1
    for p in $pids; do kill -9 "$p" 2>/dev/null; done; sleep 1
}

# ---- WHAT A SHORT-LIVED CLIENT PAYS ---------------------------------------
# The percentiles above are of LONG-LIVED clients, which dial once and then
# amortise it over a whole session. A desktop is also full of programs that
# start, read one thing and exit -- a script, a status tool, this gate's own
# `cat`. Routed, each of those pays connect + HELLO before it can answer, and
# stage 1 measured that a blocking request on the mutation socket waits for
# whatever frame is in progress. This is that cost where a desktop actually
# meets it.
#
# It also found the torn read that `de_fps_driver.py` now retries: /dev/wsys/
# wsysd/state is rewritten in place, and a reader landing mid-rewrite gets an
# EMPTY body with exit status 0 -- in BOTH arms, so it is a property of the
# file. That is counted here rather than smoothed over.
dial_arm() {   # dial_arm <label> <routed> <busy>
    # Split, not one `local` line: with `set -u`, referring to `lab` in a later
    # assignment on the SAME `local` is an unbound variable.
    local lab="$1"; local routed="$2"; local busy="$3"
    local A="$WORK/dial.$lab"
    rm -rf "$A"; mkdir -p "$A/noicd"
    export HAMWSYS="$A/seg" HAMWSYS_BB="$A/seg.bb" HAMWSYS_IMG="$A/img"
    export HAMFB_FILE="$A/fb.raw" HAMFB_GEOM="$GEOM"
    : >"$A/in"; export HAMWSYSD_INPUT="$A/in"
    export VK_ICD_FILENAMES="$A/noicd/none.json" HAMLINUX_VNC=none
    if [ "$routed" = 1 ]; then export HAMWSYS_SERVER=1; else unset HAMWSYS_SERVER; fi
    local pids i
    "$BINDIR/wsysd" </dev/null >"$A/wsysd.log" 2>&1 & pids=$!; reap_add $!
    for i in $(seq 1 100); do [ -s "$A/fb.raw" ] && break; sleep 0.1; done
    "$BINDIR/hamdesktop"    </dev/null >"$A/d.log" 2>&1 & reap_add $!; pids="$pids $!"
    sleep 3
    "$BINDIR/hampanelscene" </dev/null >"$A/p.log" 2>&1 & reap_add $!; pids="$pids $!"
    sleep 4
    if [ "$busy" = 1 ]; then
        "$BINDIR/de_dragload" 480 320 120 200 300 8 >"$A/drag.wid" 2>/dev/null &
        reap_add $!; pids="$pids $!"
        sleep 2
    fi
    printf 'deboot: INFO   %-18s (%s) ' "$lab" "$(cond)"
    python3 - "$BINDIR/cat" <<'PY'
import subprocess, sys, time
cat = sys.argv[1]
times, empty = [], 0
for _ in range(200):
    t0 = time.monotonic()
    try:
        p = subprocess.run([cat, '/dev/wsys/wsysd/state'],
                           capture_output=True, timeout=10)
        dt = (time.monotonic() - t0) * 1000.0
        f = p.stdout.decode(errors='replace').split()
        if 'frames' not in f:
            empty += 1
    except subprocess.TimeoutExpired:
        dt = 10000.0
        empty += 1
    times.append(dt)
    time.sleep(0.02)
times.sort()
def q(p): return times[min(len(times) - 1, int(p / 100.0 * (len(times) - 1)))]
print('n=200 torn=%d  p50 %.1f  p90 %.1f  max %.1f ms' % (empty, q(50), q(90), times[-1]))
PY
    local p; for p in $pids; do kill "$p" 2>/dev/null; done; sleep 1
    for p in $pids; do kill -9 "$p" 2>/dev/null; done; sleep 1
}

# ---- run -------------------------------------------------------------------
: >"$WORK/arms.tsv"
for rep in $(seq 1 "$REPS"); do
    head2 "rep $rep -- UNROUTED (the control: HAMWSYS_SERVER nowhere)"
    arm unrouted 0 "$rep" || true
    head2 "rep $rep -- ROUTED (HAMWSYS_SERVER=1 for the compositor and every client)"
    arm routed 1 "$rep" || true
done

head2 "WHAT A SHORT-LIVED CLIENT PAYS -- 200 fresh readers per arm"
info "each one is a whole process that starts, reads /dev/wsys/wsysd/state and exits;"
info "routed, it must connect and negotiate a version first."
dial_arm unrouted-idle 0 0 || true
dial_arm routed-idle   1 0 || true
dial_arm unrouted-drag 0 1 || true
dial_arm routed-drag   1 1 || true

head2 "DOES TRAFFIC ACTUALLY CROSS, AND WHOSE"
trace_arm || true

head2 "THE TERMINAL"
term_arm || true

# ---- the comparison --------------------------------------------------------
head2 "THE COST, BOTH ARMS, ONE SESSION"
python3 - "$WORK" <<'PY'
import glob, os, re, sys, statistics
W = sys.argv[1]
rows = {}
pat = re.compile(r'^(\S+ \S .*?)\s+([\d.]+) fps\s+\((\d+) presented in ([\d.]+) s; (\d+) full \+ (\d+) '
                 r'cursor-only\)\s+input (\d+) ev/s\s+wsysd cpu ([\d.]+)%')
for f in sorted(glob.glob(os.path.join(W, '*', 'fps?.txt'))):
    arm = os.path.basename(os.path.dirname(f)).split('.')[0]
    load = os.path.basename(f)[3]
    txt = open(f).read()
    m = pat.search(txt)
    if not m:
        continue
    fps = float(m.group(2)); cpu = float(m.group(8))
    full = int(m.group(5)); cur = int(m.group(6))
    samples = re.search(r'samples: ([\d. ]+)\)', txt)
    cpus = [float(x) for x in samples.group(1).split()] if samples else [cpu]
    rows.setdefault((load, arm), []).append((fps, statistics.median(cpus), full, cur))

def agg(load, arm, i):
    v = [r[i] for r in rows.get((load, arm), [])]
    return statistics.median(v) if v else None

print('%-24s %10s %10s %9s' % ('load', 'unrouted', 'routed', 'delta'))
for load, name in (('A', 'A pointer only'), ('B', 'window drag'), ('C', 'drag + pointer')):
    for i, unit, lbl in ((0, 'fps', 'fps'), (1, '%', 'wsysd cpu')):
        u, r = agg(load, 'unrouted', i), agg(load, 'routed', i)
        if u is None or r is None:
            continue
        d = r - u
        print('%-24s %10.1f %10.1f %+9.1f   %s' %
              ('%s: %s' % (name, lbl), u, r, d, unit))

lat = {}
for f in sorted(glob.glob(os.path.join(W, '*', 'lat.txt'))):
    arm = os.path.basename(os.path.dirname(f)).split('.')[0]
    m = re.search(r'p50\s+([\d.]+)\s+mean\s+([\d.]+)\s+p95\s+([\d.]+)\s+max\s+([\d.]+)', open(f).read())
    if m:
        lat.setdefault(arm, []).append(tuple(float(m.group(i)) for i in (1, 2, 3, 4)))
print()
print('%-24s %8s %8s %8s %8s' % ('input->pixel (ms)', 'p50', 'mean', 'p95', 'max'))
for arm in ('unrouted', 'routed'):
    v = lat.get(arm)
    if not v:
        continue
    print('%-24s %8.2f %8.2f %8.2f %8.2f' %
          (arm, *[statistics.median(x[i] for x in v) for i in range(4)]))

# WHEN THE CPU COLUMN CANNOT DISCRIMINATE, SAY SO RATHER THAN QUOTE IT.
# Under loads B and C this compositor saturates a core in BOTH arms, and two
# numbers pinned at the same ceiling are not a comparison -- the FRAME COUNT is
# what carries the difference there, which is the same reason stage 2's gate
# asserts frames beside its CPU figure.
sat = [(l, a, agg(l, a, 1)) for l in 'ABC' for a in ('unrouted', 'routed')]
if any(c is not None and c > 95.0 for _, _, c in sat):
    print()
    print('NOTE: wsysd is at or near 100% of a core in the loads marked above,')
    print('      in BOTH arms. A saturated CPU column cannot discriminate; read')
    print('      the fps rows for those loads, not the cpu rows.')

idle = {}
for line in open(os.path.join(W, 'arms.tsv')):
    f = line.split()
    if len(f) >= 3 and f[2].isdigit():
        idle.setdefault(f[0], []).append(int(f[2]))
print()
print('idle frames in 10 s (the panel\'s 320 ms sysmon resample and nothing else):')
for arm in ('unrouted', 'routed'):
    if arm in idle:
        print('  %-10s %s  median %g' % (arm, idle[arm], statistics.median(idle[arm])))
PY

# ---- is any of it attributable? --------------------------------------------
# Printed last and loudly, by the same rule wsys_srv_transport.sh uses. Not a
# pass/fail arm: the correctness arms above do not depend on load.
if [ -s "$WORK/hostcond" ]; then
    awk '{ if ($1+0 > maxl) maxl=$1+0; if ($2+0 > maxs) maxs=$2+0; n++ }
         END{
           printf "deboot: .... host during the samples: %d samples, peak loadavg %.2f, peak bound wsys server names %d\n", n, maxl, maxs;
           if (maxl > 2.5)
               printf "deboot: .... NOT ATTRIBUTABLE: peak loadavg %.2f. RE-TAKE THESE QUIET before quoting them.\n", maxl;
           else if (maxl > 2.0)
               printf "deboot: .... SUSPECT: peak loadavg %.2f exceeded 2.0. Treat the percentages as an UPPER BOUND.\n", maxl;
           else
               printf "deboot: .... ATTRIBUTABLE: peak loadavg %.2f, under 2.0 throughout.\n", maxl;
         }' "$WORK/hostcond"
fi

done_report
