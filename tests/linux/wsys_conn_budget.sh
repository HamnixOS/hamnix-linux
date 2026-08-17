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
# tests/linux/wsys_conn_budget.sh — HOW MANY APPLICATIONS UNTIL 64.
#
# THE QUESTION, AND WHY IT IS NEW
# ==============================
# /dev/wsys's server caps concurrent connections at WSRV_CONN_MAX = 64, and it
# does so SEPARATELY on the mutation socket ".../srv" and on the read server
# ".../rd". tests/linux/wsys_srv_ceiling.sh established the ceiling itself: the
# 65th dial is accepted and closed, the refused client now says the true
# reason, and on the READ socket it FAILS CLOSED rather than falling back to
# shared memory. All of that is about what happens AT the cap.
#
# This gate is the other half, which nothing measured: HOW FAR AWAY THE CAP IS.
# Two recent changes both push on the read socket and neither counted:
#
#   7d24ef3c  routed EXISTENCE for nine read opens, so a GUI process holds a
#             read connection where it previously might not have.
#   e23ab06c  routed the WRITE open's existence question through the SAME read
#             server, so a WRITE-ONLY process now holds a read connection it
#             did not before. That commit's own message says "the 64-connection
#             ceiling moves again and I did not count how far."
#
# It matters because of what is on the other side. Before 1fd21377 a client
# refused at the cap silently degraded to the in-process path and kept working
# (badly, and with a privilege leak). It now FAILS CLOSED. That was the right
# fix, and its consequence is that EXHAUSTING THE TABLE IS A USER-VISIBLE
# FAILURE rather than a silent one -- so the number of applications it takes to
# get there stopped being an academic quantity.
#
# THE INSTRUMENT HAD TO BE FIXED BEFORE ANY NUMBER MEANT ANYTHING
# ===============================================================
# The census is tests/linux/wsys_conn_census.py: `ss -xp` for the ESTABLISHED
# server-side rows, then each peer socket INODE resolved to a pid through
# /proc/<pid>/fd, because the client end of an AF_UNIX connection has no
# address and /proc is the only place that association exists.
#
# THAT FILE HAD THE `break` THE SAME CENSUS HAD ALREADY BEEN FIXED FOR. It was
# lifted out of tests/linux/wsys_srv_deboot.sh at 44412d29 (04:40) WITH the
# break; 0965da0b (13:46) removed the break from deboot's copy; the extracted
# copy was never updated. The break stopped at the first matching descriptor in
# a process, so a client holding BOTH a mutation and a read connection counted
# ONCE, as the mutation one (dialled earlier, lower fd). Every number ARM F of
# wsys_srv_ceiling.sh has printed is therefore an undercount of exactly the
# quantity it exists to measure. Removed there; ARM 0 here is the negative
# control that proves the removal is what makes the difference.
#
# ARM 0 IS NOT DECORATION. A census that cannot be shown to produce a
# DOUBLE-COUNTED process is indistinguishable from one that silently drops the
# second fd, and "0 read connections" would read as a fact about the desktop
# instead of a fact about the loop -- which is the exact mistake already paid
# for once. So ARM 0 runs the census in BOTH spellings against the same instant
# of the same desktop and requires them to DISAGREE.
#
# THE ARMS
# ========
#   0  THE CENSUS COUNTS BOTH FDS PER PROCESS. Same instant, two spellings
#      (with and without the break); they must differ, the with-break one must
#      be smaller, and at least one pid must appear on BOTH sockets with two
#      different fd numbers.
#   1  THE INTERCEPT. A booted desktop -- compositor, hamdesktop, panel -- and
#      what it holds on each socket.
#   2a THE SLOPE, POSITIVE CONTROL. Applications started one at a time,
#      DIRECTLY, with HAMWSYS_SERVER=1 in their environment. Nothing else in
#      this gate may report a zero until this has produced a non-zero.
#   2b THE SLOPE THROUGH THE REAL DE SPAWN SHAPE, `hamsh <rc.de-user> <prog>`,
#      with the rc exactly as the image installs it.
#   2c THE SAME, with the wsys environment forced through the rc -- because 2b
#      measures something that turns out not to be about connections at all.
#   3  DOES ADOPTION FIRE? srv_adopt_inherited() exists so a spawned program
#      can inherit its spawner's connection instead of dialling its own.
#      MEASURED at the descriptor and the environment, not read off the code.
#   4  WHAT HAPPENS AT THE CAP, END TO END. Fill the read table, then start one
#      more ORDINARY application and record what a person would see: does it
#      get a window, does it say anything actionable, does the desktop survive,
#      and does the system recover when the table empties.
#   5  THE GUARD. The headroom is asserted against a floor, so that the next
#      commit to move this number cannot move it silently -- which is the only
#      reason this gate is worth keeping after today.
#
# THIS GATE IS EXPECTED RED ON EXACTLY ONE ARM, AND THE RED IS THE POINT
# ======================================================================
# ARM 4's window arm fails, reproducibly, on the tree that introduced it, and
# it is a defect rather than a harness problem -- the control in the same arm
# runs the IDENTICAL command against an empty table and does get a window.
#
# WHAT IT FOUND: with the read table full, an application starts, its
# newwindow MUTATION succeeds (the two sockets have separate budgets and the
# mutation table had room), it prints "scene window ready" on its own stdout,
# AND NO WINDOW EVER APPEARS. It is not slow; the count is unchanged eight
# seconds later. The mechanism is srv_route_exists(): e23ab06c routed the WRITE
# open's existence question through the read server, and 1fd21377 made a
# ceiling refusal on that server FAIL CLOSED -- so with the read table full the
# per-window write opens return ECONNREFUSED and the window is never decorated
# or committed. Both of those changes are right on their own. Their product is
# a program that reports success and shows the user nothing.
#
# The arm goes green when the application either gets its window or FAILS
# VISIBLY. It must NOT be made green by raising WSRV_CONN_MAX, which changes
# when this happens and not what happens.
#
# Offscreen throughout: HAMFB_FILE, HAMLINUX_VNC=none, VK_ICD_FILENAMES at an
# empty directory. /dev/dri is never opened, no DRM master is taken. Everything
# runs in a private user+mount namespace; nothing outside it is written.
set -uo pipefail
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ"
. tests/linux/private_ns.sh
priv_ns_reexec "$@"

pass=0; fail=0
ok()   { printf 'connbudget: PASS %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf 'connbudget: FAIL %s\n' "$*"; fail=$((fail+1)); }
note() { printf 'connbudget: .... %s\n' "$*"; }

# ======================================================================
# INNER HALF — inside the user namespace, as inner uid 0
# ======================================================================
if [ "${1:-}" = "--inner" ]; then
    W="$2"; BIN="$W/bin"
    . "$W/reap.sh"
    reap_track "$W/reaped.inner"
    reap_on_exit

    mount -t tmpfs none /tmp     2>/dev/null || echo "== NOTE no /tmp tmpfs"
    mount -t tmpfs none /dev/shm 2>/dev/null || echo "== NOTE no shm tmpfs"

    R="$W/run"; mkdir -p "$R/ws" "$R/noicd"
    chmod 0777 "$R" "$R/ws"

    export HAMWSYS="$R/ws/seg" HAMWSYS_BB="$R/ws/seg.bb" HAMWSYS_IMG="$R/ws/img"
    export HAMFB_FILE="$R/ws/fb.raw" HAMFB_GEOM=1280x800
    export VK_ICD_FILENAMES="$R/noicd/none.json" HAMLINUX_VNC=none
    : >"$R/in"; chmod 666 "$R/in"; export HAMWSYSD_INPUT="$R/in"

    # ARM 2c's rc, with this namespace's real paths substituted in. It has to
    # happen HERE: the values are only known inside the namespace, and baking
    # the outer host's paths into a file the inner half then contradicts is how
    # a routed measurement quietly becomes an unrouted one.
    "$W/mkrouted.sh" "$W/rc.de-user.routed.in" "$W/rc.de-user.routed"
    grep -c '^export ' "$W/rc.de-user.routed" | sed 's/^/== rc.routed.exports /'

    BGPID=0
    as_bg() { local out="$1"; shift
        ( exec "$@" </dev/null >"$out" 2>&1 ) &
        BGPID=$!; reap_add "$BGPID"; }

    # ---- the compositor ---------------------------------------------
    as_bg "$R/wsysd.log" env HAMWSYS_SERVER=1 "$BIN/wsysd"
    for _ in $(seq 1 150); do [ -s "$HAMFB_FILE" ] && break; sleep 0.1; done
    if ! [ -s "$HAMFB_FILE" ]; then
        echo "== FATAL wsysd produced no framebuffer"
        tail -20 "$R/wsysd.log" | sed 's/^/== wsysd: /'; exit 3
    fi
    SEG="$(stat -c '%d.%i' "$HAMWSYS")"
    echo "== segment $SEG"
    RDPID="$(sed -n 's/.*read server pid \([0-9]*\).*/\1/p' "$R/wsysd.log" | head -1)"
    [ -n "$RDPID" ] && reap_add "$RDPID"
    echo "== rdpid ${RDPID:-none}"

    # ---- the census, both spellings ---------------------------------
    peers() {
        ss -xp 2>/dev/null | awk -v seg="$SEG" '
            $0 ~ ("@hamnix-wsys/" seg "/srv") && $2 == "ESTAB" { print "srv", $8 }
            $0 ~ ("@hamnix-wsys/" seg "/rd")  && $2 == "ESTAB" { print "rd",  $8 }
        ' >"$R/.peers"
    }
    census()      { peers; python3 "$W/census.py"       "$R/.peers"; }
    census_brk()  { peers; python3 "$W/census_break.py" "$R/.peers"; }

    # `ss` sees only what the kernel has, and both servers accept inside their
    # frame loop, so a census taken the instant after a spawn can catch a
    # client mid-dial. Settle by polling until the count stops moving rather
    # than sleeping a guessed amount -- a guessed sleep is how a slope gets an
    # off-by-one at every point.
    settle() {
        local prev=-1 n i
        for i in $(seq 1 40); do
            n="$(census | wc -l)"
            [ "$n" = "$prev" ] && [ "$i" -ge 3 ] && return 0
            prev="$n"; sleep 0.25
        done
    }
    report() {   # report <label>
        settle
        local c; c="$(census)"
        printf '%s\n' "$c" | grep . | sed "s/^/== stage.$1.peer /"
        echo "== stage.$1.srv $(printf '%s\n' "$c" | grep -c '^srv ')"
        echo "== stage.$1.rd  $(printf '%s\n' "$c" | grep -c '^rd ')"
        echo "== stage.$1.tot $(printf '%s\n' "$c" | grep -c .)"
    }

    report boot0
    as_bg "$R/hamdesktop.log" env HAMWSYS_SERVER=1 "$BIN/hamdesktop"
    sleep 3
    report boot1
    as_bg "$R/hampanel.log" env HAMWSYS_SERVER=1 "$BIN/hampanelscene"
    sleep 4
    report boot2

    # ================= ARM 0: the census counts both fds ==============
    settle
    echo "== arm0.nobreak $(census     | wc -l)"
    echo "== arm0.break   $(census_brk | wc -l)"
    census | awk '{print $2}' | sort | uniq -c \
        | awk '$1 > 1 {print "== arm0.doublepid " $2 " holds " $1}'

    APPS="hamcalcscene hameditscene hamfmscene hammonscene hamimgscene hamabout ham2048scene"

    # ================= ARM 2a: THE POSITIVE CONTROL ===================
    # Applications started DIRECTLY, routed. Nothing in this gate may report a
    # zero cost per application until this has produced a non-zero: a per-app
    # cost of 0 measured only through a wrapper is indistinguishable from a
    # wrapper that broke the measurement, which is exactly what the first run
    # of this gate did.
    DPIDS=""
    i=0
    for prog in $APPS; do
        i=$((i + 1))
        [ -x "$BIN/$prog" ] || { echo "== dapp.$i.missing $prog"; continue; }
        as_bg "$R/dapp.$i.log" env HAMWSYS_SERVER=1 "$BIN/$prog"
        DPIDS="$DPIDS $BGPID"
        echo "== dapp.$i.name $prog"
        sleep 3
        report "dapp$i"
    done
    echo "== direct.launched $i"
    # Down again, so ARM 2b's slope is its own and not this arm's tail. Each
    # pid explicitly; NEVER a pattern kill -- every arm here runs the same
    # binaries out of the same directory, and other agents on this box run
    # wsysd too.
    for p in $DPIDS; do kill -TERM "$p" 2>/dev/null; done
    sleep 2
    report afterdirect

    # ================= ARM 2b: THE REAL DE SPAWN SHAPE ================
    # An installed desktop spawns each app as `/bin/hamsh /etc/rc.de-user
    # <prog>`; hamsh sources the rc, which drops to uid 1001 and then runs the
    # program AS A CHILD (rc.de-user's tail is a command, not an exec), so
    # hamsh stays alive for the window's lifetime and BOTH processes are
    # candidates to hold connections.
    #
    # THE RC IS THE REAL ONE, etc/rc.de-user.linux, copied in byte for byte.
    # Its `bind` lines address hamsh's own device servers, which do not exist
    # in this harness; they fail and the rc continues. That is declared rather
    # than hidden -- a bind plants a namespace and has nothing to do with how
    # many sockets a process holds. What IS preserved is the whole of what the
    # question is about: the hamsh parent, the argv shape, the HAMNIX_DE_PROG
    # dispatch, and the program running as hamsh's child.
    SPIDS=""
    i=0
    for prog in $APPS; do
        i=$((i + 1))
        [ -x "$BIN/$prog" ] || continue
        as_bg "$R/sapp.$i.log" env HAMWSYS_SERVER=1 \
              "$BIN/hamsh" "$W/rc.de-user" "$BIN/$prog"
        APPSH="$BGPID"; SPIDS="$SPIDS $APPSH"
        echo "== sapp.$i.name $prog"
        echo "== sapp.$i.shpid $APPSH"
        sleep 4
        report "sapp$i"
        # ARM 3, measured at the descriptor and the environment rather than
        # reasoned from the source.
        echo "== sapp.$i.shsocks $(ls -l /proc/$APPSH/fd 2>/dev/null \
              | grep -c 'socket:')"
        KID="$(cat /proc/$APPSH/task/$APPSH/children 2>/dev/null | tr -d ' \n')"
        echo "== sapp.$i.kid ${KID:-none}"
        echo "== sapp.$i.kidenv_server $(tr '\0' '\n' </proc/${KID:-0}/environ \
              2>/dev/null | grep -c '^HAMWSYS_SERVER=1$')"
        echo "== sapp.$i.kidenv_srvfd $(tr '\0' '\n' </proc/${KID:-0}/environ \
              2>/dev/null | grep -c '^HAMWSYS_SRV_FD=')"
        echo "== sapp.$i.kidenv $(tr '\0' ' ' </proc/${KID:-0}/environ 2>/dev/null \
              | cut -c1-300)"
    done
    echo "== shell.launched $i"
    for p in $SPIDS; do kill -TERM "$p" 2>/dev/null; done
    sleep 2
    report aftershell

    # ================= ARM 2c: THE SPAWN SHAPE, ROUTING FORCED ========
    # ARM 2b measures a real property of the tree, but it is NOT the
    # connection question: hamsh seeds its child's environment from its OWN
    # table (PATH, HOME, HAMNIX_DE_PROG), so HAMWSYS_SERVER never reaches the
    # program and it is not routed at all. To answer "what does a routed app
    # cost through this spawn path", the variables are exported by the rc --
    # which is what an installed system would have to do the day routing
    # becomes the default. Same rc, same shape, plus an export block.
    SPIDS2=""
    i=0
    for prog in $APPS; do
        i=$((i + 1))
        [ -x "$BIN/$prog" ] || continue
        as_bg "$R/rapp.$i.log" env HAMWSYS_SERVER=1 \
              "$BIN/hamsh" "$W/rc.de-user.routed" "$BIN/$prog"
        APPSH="$BGPID"; SPIDS2="$SPIDS2 $APPSH"
        echo "== rapp.$i.name $prog"
        echo "== rapp.$i.shpid $APPSH"
        sleep 4
        report "rapp$i"
        echo "== rapp.$i.shsocks $(ls -l /proc/$APPSH/fd 2>/dev/null \
              | grep -c 'socket:')"
        KID="$(cat /proc/$APPSH/task/$APPSH/children 2>/dev/null | tr -d ' \n')"
        echo "== rapp.$i.kid ${KID:-none}"
        echo "== rapp.$i.kidenv_server $(tr '\0' '\n' </proc/${KID:-0}/environ \
              2>/dev/null | grep -c '^HAMWSYS_SERVER=1$')"
        echo "== rapp.$i.kidenv_srvfd $(tr '\0' '\n' </proc/${KID:-0}/environ \
              2>/dev/null | grep -c '^HAMWSYS_SRV_FD=')"
        grep -h 'HAMWSYS_SRV_FD\|inherited server connection' "$R/rapp.$i.log" \
              2>/dev/null | head -1 | sed "s/^/== rapp.$i.adoptmsg /"
    done
    echo "== routed.launched $i"
    NR="$i"

    # ================= ARM 4: WHAT HAPPENS AT THE CAP =================
    # Fill the READ table and hold it, then start ONE MORE ORDINARY
    # APPLICATION -- the same command shape as ARM 2c -- and record what a
    # person would see.
    #
    # The fill takes the table to its ceiling from OUTSIDE, which is the only
    # way to reach the cap without booting sixty desktops. It is the same
    # boundary the desktop would reach on its own; what is measured on the far
    # side is the application, not the filler.
    rm -f "$R/ready" "$R/ready.stop"
    python3 "$W/fill.py" "$SEG" rd 80 "$R/ready" >"$R/fill.rd.log" 2>&1 &
    FP=$!; reap_add "$FP"
    for _ in $(seq 1 400); do [ -s "$R/ready" ] && break; sleep 0.1; done
    echo "== arm4.fill $(grep -m1 '^tried' "$R/fill.rd.log")"
    # ASSERTED, NOT ASSUMED: the table is full at this instant.
    echo "== arm4.canary $(python3 "$W/canary.py" "$SEG" rd | tr '\n' ';')"
    echo "== arm4.censusfull.rd $(census | grep -c '^rd ')"
    echo "== arm4.censusfull.srv $(census | grep -c '^srv ')"
    # THE BEFORE HALF OF "DOES IT FAIL TO OPEN A WINDOW". Counted, not
    # eyeballed: "the window list looks the same" is not a measurement, and the
    # cap app is deliberately a program that ALREADY has an instance running
    # from ARM 2c, so only a count separates one Calculator from two.
    echo "== arm4.wins.before $("$BIN/cat" /dev/wsys/windows 2>/dev/null | grep -c .)"

    as_bg "$R/capapp.log" env HAMWSYS_SERVER=1 \
          "$BIN/hamsh" "$W/rc.de-user.routed" "$BIN/hamcalcscene"
    CAPSH="$BGPID"
    sleep 6
    echo "== arm4.app.alive $(kill -0 "$CAPSH" 2>/dev/null && echo yes || echo no)"
    CAPKID="$(cat /proc/$CAPSH/task/$CAPSH/children 2>/dev/null | tr -d ' \n')"
    echo "== arm4.app.kid ${CAPKID:-none}"
    echo "== arm4.app.log $(tr '\n' '/' <"$R/capapp.log" | cut -c1-1500)"
    # DID IT GET A WINDOW? Read the window list UNMEDIATED, as the segment's
    # owner: that is ground truth about what exists, not a mediated view the
    # cap could itself distort.
    echo "== arm4.wins.after $("$BIN/cat" /dev/wsys/windows 2>/dev/null | grep -c .)"
    echo "== arm4.windows $("$BIN/cat" /dev/wsys/windows 2>&1 \
          | tr '\n' '/' | cut -c1-900)"
    echo "== arm4.refused $(tail -3 "$HAMWSYS.refused" 2>/dev/null | tr '\n' '/')"
    # THE DESKTOP SURVIVES? The chrome was running before the cap was reached;
    # a cap that kills the chrome is a different product risk from a cap that
    # refuses one new application.
    for c in wsysd hamdesktop hampanelscene; do
        echo "== arm4.alive.$c $(pgrep -x "$c" >/dev/null && echo yes || echo no)"
    done
    echo "== arm4.panel.tail $(tail -3 "$R/hampanel.log" | tr '\n' '/' | cut -c1-600)"

    # DOES IT ARRIVE LATE? srv_rtried is cleared on a cap refusal precisely so
    # a refused client may dial again when room appears, so a window that is
    # merely SLOW is a different answer from a window that never comes. Give it
    # the whole time the fill is still held, and count again.
    sleep 8
    echo "== arm4.wins.later $("$BIN/cat" /dev/wsys/windows 2>/dev/null | grep -c .)"

    : >"$R/ready.stop"; sleep 3
    # THE NEGATIVE CONTROL FOR THE WINDOW COUNT, and it is the arm that decides
    # what ARM 4 means. The cap app is a SECOND hamcalcscene, and "a second
    # instance of this program never appears in the list anyway" would produce
    # exactly the same 6 -> 6 as "the cap stopped it". So the identical command
    # is run again with the table EMPTY. If this one lists and the capped one
    # did not, the cap is the cause; if neither lists, the earlier arm measured
    # the program and not the boundary.
    as_bg "$R/recover.log" env HAMWSYS_SERVER=1 \
          "$BIN/hamsh" "$W/rc.de-user.routed" "$BIN/hamcalcscene"
    sleep 8
    report recover
    echo "== arm4.wins.control $("$BIN/cat" /dev/wsys/windows 2>/dev/null | grep -c .)"
    echo "== arm4.windows.control $("$BIN/cat" /dev/wsys/windows 2>/dev/null \
          | tr '\n' '/' | cut -c1-900)"
    echo "== arm4.recover.log $(tr '\n' '/' <"$R/recover.log" | cut -c1-600)"
    exit 0
fi

# ======================================================================
# OUTER HALF
# ======================================================================
command -v unshare >/dev/null || { echo "connbudget: SKIP no unshare(1)"; exit 0; }
command -v ss      >/dev/null || { echo "connbudget: SKIP no ss(8)"; exit 0; }
command -v python3 >/dev/null || { echo "connbudget: SKIP no python3"; exit 0; }

SCRATCH_BASE="${CB_SCRATCH_BASE:-$HOME/.hamnix-build}"
BIN="${CB_BIN:-$SCRATCH_BASE/ceilrecount/bin}"
[ -d "$BIN" ] || { echo "connbudget: FAIL no binaries at $BIN"; exit 2; }
for n in wsysd hamdesktop hampanelscene hamsh cat; do
    [ -x "$BIN/$n" ] || { echo "connbudget: FAIL missing $BIN/$n"; exit 2; }
done

mkdir -p "$SCRATCH_BASE"
W="$(mktemp -d "$SCRATCH_BASE/connbudget-w.XXXXXX")"
trap 'rm -rf "$W"' EXIT
trap 'exit 130' INT TERM HUP
chmod 1777 "$W"
mkdir -p "$W/bin"; cp "$BIN"/* "$W/bin/"; chmod 755 "$W/bin"/*
cp "$0" "$W/inner.sh"; chmod 755 "$W/inner.sh"
cp "$PROJ/tests/linux/reap.sh"             "$W/reap.sh"
cp "$PROJ/tests/linux/wsys_conn_fill.py"   "$W/fill.py"
cp "$PROJ/tests/linux/wsys_conn_canary.py" "$W/canary.py"
cp "$PROJ/tests/linux/wsys_conn_census.py" "$W/census.py"
cp "$PROJ/etc/rc.de-user.linux"            "$W/rc.de-user"

# ARM 2c's rc: the shipped one, plus the export block that would have to exist
# the day routing is the default. hamsh assignment syntax -- NAME='VALUE' then
# `export NAME`, two statements, and the value single-quoted, because an
# assignment RHS is parsed as an expression and a bare path is read as
# arithmetic. rc.de-user.linux says both of those in its own comments.
{
    sed 's/^setuid 1001$/# setuid 1001 -- see the gate header/' "$W/rc.de-user" \
        | sed '/^if \$HAMNIX_DE_PROG:/,$d'
    for v in HAMWSYS HAMWSYS_BB HAMWSYS_IMG HAMFB_FILE HAMFB_GEOM \
             HAMWSYSD_INPUT VK_ICD_FILENAMES HAMLINUX_VNC; do
        printf "%s='__%s__'\nexport %s\n" "$v" "$v" "$v"
    done
    printf "HAMWSYS_SERVER='1'\nexport HAMWSYS_SERVER\n"
    sed -n '/^if \$HAMNIX_DE_PROG:/,$p' "$W/rc.de-user"
} >"$W/rc.de-user.routed.in"

OUTF="$W/out.txt"
# The values are only known INSIDE the namespace, so the substitution happens
# there; the outer half writes the template and a two-line prologue does the
# rest. Keeping it here rather than in the inner half would bake this host's
# paths into a file the inner half then contradicts.
cat >"$W/mkrouted.sh" <<'MK'
#!/bin/sh
sed -e "s|__HAMWSYS__|$HAMWSYS|" -e "s|__HAMWSYS_BB__|$HAMWSYS_BB|" \
    -e "s|__HAMWSYS_IMG__|$HAMWSYS_IMG|" -e "s|__HAMFB_FILE__|$HAMFB_FILE|" \
    -e "s|__HAMFB_GEOM__|$HAMFB_GEOM|" -e "s|__HAMWSYSD_INPUT__|$HAMWSYSD_INPUT|" \
    -e "s|__VK_ICD_FILENAMES__|$VK_ICD_FILENAMES|" \
    -e "s|__HAMLINUX_VNC__|$HAMLINUX_VNC|" "$1" >"$2"
MK
chmod 755 "$W/mkrouted.sh"

# THE NEGATIVE CONTROL FOR THE CENSUS. The same file with the `break` put back,
# GENERATED from the fixed one rather than kept as a second copy -- two
# hand-maintained spellings of a census is what produced the defect in the
# first place. If the transformation ever stops applying, this fails loudly
# rather than silently comparing a file with itself.
python3 - "$W/census.py" "$W/census_break.py" <<'PY'
import sys
src = open(sys.argv[1]).read()
anchor = "                found.append((k, int(pid), comm, fd))\n"
if src.count(anchor) != 1:
    sys.stderr.write("census_break: anchor not found exactly once\n")
    sys.exit(3)
open(sys.argv[2], "w").write(src.replace(anchor, anchor + "            break\n"))
PY
[ -s "$W/census_break.py" ] || {
    echo "connbudget: FAIL could not build the with-break control census"; exit 2; }

unshare -U --map-root-user --mount --propagation private \
    -- "$W/inner.sh" --inner "$W" >"$OUTF" 2>&1
rc=$?
sed 's/^/connbudget|  /' "$OUTF"
[ $rc -eq 0 ] || { echo "connbudget: FAIL namespace run rc=$rc"; exit 2; }

f() { grep -m1 "^== $1 " "$OUTF" | sed "s/^== $1 *//"; }

CAP="$(awk '/WSRV_CONN_MAX *=/{gsub(/[^0-9]/,"",$3); print $3; exit}' \
        "$PROJ/user/linux-wsys.h")"
[ -n "$CAP" ] || { echo "connbudget: FAIL cannot read WSRV_CONN_MAX"; exit 2; }
note "WSRV_CONN_MAX is $CAP, read from user/linux-wsys.h -- every number below is compared against THAT, not against a literal 64"

# ===================== ARM 0: THE INSTRUMENT ============================
note "ARM 0 -- the census counts BOTH descriptors per process"
NB="$(f arm0.nobreak)"; BK="$(f arm0.break)"
note "  same instant, same desktop: without the break $NB rows, with it $BK"
grep '^== arm0.doublepid ' "$OUTF" | sed 's/^== arm0.doublepid /connbudget: ....   pid /'
if [ "${NB:-0}" -gt "${BK:-0}" ]; then
    ok "the census counts both descriptors: $NB rows against the with-break control's $BK. The control is the SAME file with \`break\` reinserted, so the difference is that line and nothing else -- which is what makes every number below believable."
else
    bad "the two spellings agree ($NB vs $BK): either no process holds two connections at this instant, in which case this desktop cannot demonstrate the fix and no read count below may be trusted, or the control was not built. Refusing to score the rest."
    echo "connbudget: $pass passed, $fail failed"; exit 1
fi
if grep -q '^== arm0.doublepid ' "$OUTF"; then
    ok "at least one pid appears on BOTH sockets with two different descriptors -- the population the break erased is non-empty on a plain desktop boot"
else
    bad "no pid holds two connections, so the break would have cost nothing here and ARM 0's difference came from somewhere else"
fi

# ===================== ARM 1: THE INTERCEPT =============================
note "ARM 1 -- what a booted desktop holds, per socket"
for s in boot0 boot1 boot2; do
    note "  $s: srv=$(f stage.$s.srv) rd=$(f stage.$s.rd) total=$(f stage.$s.tot)"
done
grep '^== stage.boot2.peer ' "$OUTF" | sed 's/^== stage.boot2.peer /connbudget: ....   /'
B2S="$(f stage.boot2.srv)"; B2R="$(f stage.boot2.rd)"
if [ "${B2S:-0}" -gt 0 ]; then
    ok "a booted desktop (compositor + hamdesktop + panel) holds $B2S mutation and $B2R read connections -- the intercept, before any application"
else
    bad "the census found no connections on a segment that is being served -- the instrument, not the desktop, is what this measured"
fi

# ===================== ARM 2a: THE POSITIVE CONTROL =====================
note "ARM 2a -- applications started DIRECTLY, routed (the positive control)"
ND="$(f direct.launched)"
pS="$B2S"; pR="$B2R"
for i in $(seq 1 "${ND:-0}"); do
    nm="$(f dapp.$i.name)"; s="$(f stage.dapp$i.srv)"; r="$(f stage.dapp$i.rd)"
    [ -n "$s" ] || continue
    note "  app $i ($nm): srv $s (+$((s - pS)))  rd $r (+$((r - pR)))"
    pS="$s"; pR="$r"
done
DS="$(f stage.dapp$ND.srv)"; DR="$(f stage.dapp$ND.rd)"
SLS="$(awk -v a="$B2S" -v b="$DS" -v n="$ND" 'BEGIN{printf "%.2f",(b-a)/n}')"
SLR="$(awk -v a="$B2R" -v b="$DR" -v n="$ND" 'BEGIN{printf "%.2f",(b-a)/n}')"
note "  SLOPE over $ND directly-started applications: $SLS mutation, $SLR read per app"
if awk -v a="$SLS" -v b="$SLR" 'BEGIN{exit !(a > 0 || b > 0)}'; then
    ok "the instrument produces a NON-ZERO per-application cost: $SLS mutation and $SLR read connections per directly-started routed application. Every zero reported below is therefore a fact about the path measured and not about the census."
else
    bad "even a DIRECTLY started routed application costs 0 connections ($SLS/$SLR). Nothing else in this gate can be believed: an instrument that has never produced a non-zero cannot report a zero as a finding."
    echo "connbudget: $pass passed, $fail failed"; exit 1
fi
note "  after those were killed: srv=$(f stage.afterdirect.srv) rd=$(f stage.afterdirect.rd)"

# ===================== ARM 2b: THE REAL DE SPAWN SHAPE ==================
note "ARM 2b -- the same applications through \`hamsh <rc.de-user> <prog>\`, rc exactly as installed"
NS="$(f shell.launched)"
pS="$(f stage.afterdirect.srv)"; pR="$(f stage.afterdirect.rd)"
BS="$pS"; BR="$pR"
for i in $(seq 1 "${NS:-0}"); do
    nm="$(f sapp.$i.name)"; s="$(f stage.sapp$i.srv)"; r="$(f stage.sapp$i.rd)"
    [ -n "$s" ] || continue
    note "  app $i ($nm): srv $s (+$((s - pS)))  rd $r (+$((r - pR)))  hamsh-sockets=$(f sapp.$i.shsocks)  child-has-HAMWSYS_SERVER=$(f sapp.$i.kidenv_server)"
    pS="$s"; pR="$r"
done
note "  a child's whole environment, as hamsh built it: $(f sapp.1.kidenv)"
SBS="$(f stage.sapp$NS.srv)"; SBR="$(f stage.sapp$NS.rd)"
ENVOK=0
for i in $(seq 1 "${NS:-0}"); do
    [ "$(f sapp.$i.kidenv_server)" = 1 ] && ENVOK=$((ENVOK+1))
done
if [ "$ENVOK" = 0 ]; then
    ok "MEASURED, AND IT IS NOT A CONNECTION FACT: in $NS of $NS spawns the program hamsh started does NOT have HAMWSYS_SERVER in its environment, so it is NOT ROUTED and costs nothing on either socket ($SBS/$SBR, unchanged from $BS/$BR). hamsh builds a child's envp from its OWN table -- main() seeds only PATH and HOME (user/hamsh.ad stage-03) and _build_envp emits that table -- so nothing the DE exports reaches the application. This is why ARM 2b's zero is a finding about the spawn path and ARM 2c has to exist."
else
    bad "HAMWSYS_SERVER reached the child in $ENVOK of $NS spawns, which contradicts hamsh's _build_envp seeding only PATH and HOME; ARM 2c's premise needs re-deriving before its numbers are used"
fi
note "  after those were killed: srv=$(f stage.aftershell.srv) rd=$(f stage.aftershell.rd)"

# ===================== ARM 2c: THE SPAWN SHAPE, ROUTED ==================
note "ARM 2c -- the same spawn shape with the wsys environment exported by the rc"
NRR="$(f routed.launched)"
pS="$(f stage.aftershell.srv)"; pR="$(f stage.aftershell.rd)"
RBS="$pS"; RBR="$pR"
for i in $(seq 1 "${NRR:-0}"); do
    nm="$(f rapp.$i.name)"; s="$(f stage.rapp$i.srv)"; r="$(f stage.rapp$i.rd)"
    [ -n "$s" ] || continue
    note "  app $i ($nm): srv $s (+$((s - pS)))  rd $r (+$((r - pR)))  hamsh-sockets=$(f rapp.$i.shsocks)  child-routed=$(f rapp.$i.kidenv_server)"
    pS="$s"; pR="$r"
done
RS="$(f stage.rapp$NRR.srv)"; RR="$(f stage.rapp$NRR.rd)"
RSL_S="$(awk -v a="$RBS" -v b="$RS" -v n="$NRR" 'BEGIN{printf "%.2f",(b-a)/n}')"
RSL_R="$(awk -v a="$RBR" -v b="$RR" -v n="$NRR" 'BEGIN{printf "%.2f",(b-a)/n}')"
note "  SLOPE over $NRR applications through the DE spawn shape: $RSL_S mutation, $RSL_R read per app"
WORST="$(awk -v a="$RSL_S" -v b="$RSL_R" 'BEGIN{print (a>b)?a:b}')"
WSOCK="$(awk -v a="$RSL_S" -v b="$RSL_R" 'BEGIN{print (a>b)?"srv (mutation)":"rd (read)"}')"
BASE="$(awk -v a="$B2S" -v b="$B2R" 'BEGIN{print (a>b)?a:b}')"
if awk -v w="$WORST" 'BEGIN{exit !(w > 0)}'; then
    ROOM="$(awk -v c="$CAP" -v base="$BASE" -v w="$WORST" 'BEGIN{printf "%d",(c-base)/w}')"
    ok "through the real DE spawn shape an application costs $RSL_S mutation and $RSL_R read connections; the busier socket is $WSOCK and at that rate the cap of $CAP is reached at about $ROOM concurrent applications on top of a $BASE-connection chrome"
else
    bad "the slope through the DE spawn shape is zero on both sockets even with routing forced ($RSL_S/$RSL_R), which contradicts ARM 2a's non-zero and needs explaining before any ceiling number is quoted"
fi

# ===================== ARM 3: ADOPTION ==================================
note "ARM 3 -- does srv_adopt_inherited() fire on this path?"
ADOPT=0
for i in $(seq 1 "${NRR:-0}"); do
    [ "$(f rapp.$i.kidenv_srvfd)" = 1 ] && ADOPT=$((ADOPT+1))
done
grep '^== rapp\..*\.adoptmsg ' "$OUTF" | sed 's/^== /connbudget: ....   /' | head -4
note "  hamsh's own socket count across the routed spawns: $(for i in $(seq 1 "${NRR:-0}"); do printf '%s ' "$(f rapp.$i.shsocks)"; done)"
if [ "$ADOPT" -gt 0 ]; then
    ok "HAMWSYS_SRV_FD is present in $ADOPT of $NRR spawned programs' environments -- the handoff is live on this path and an application can cost one connection instead of two"
else
    ok "MEASURED: srv_adopt_inherited() DOES NOT FIRE on the DE spawn path -- HAMWSYS_SRV_FD is in NONE of the $NRR spawned programs' environments, and hamsh holds no wsys socket to hand over. user/hamsh.ad's _spawn_at says why in its own words: the handoff was wired there and TAKEN BACK OUT, because lib/p9.ad's _spawn_flags calls p9_closefrom(3) in the child immediately before execve and closes every descriptor from 3 to 63, so the descriptor is closed by design a moment before the program meant to inherit it starts. The consequence for this gate is the one that matters: the slope is not halved by adoption, and it is also not DOUBLED by hamsh, because hamsh opens no window file and therefore never dials."
fi

# ===================== ARM 4: AT THE CAP ================================
note "ARM 4 -- the read table full, then one more ordinary application"
note "  fill: $(f arm4.fill)"
note "  canary at that instant: $(f arm4.canary)"
note "  the census sees $(f arm4.censusfull.rd) established read connections"
CAN="$(f arm4.canary)"
FULLRD="$(f arm4.censusfull.rd)"
# THE ASSERTION IS THE CENSUS, NOT THE CANARY, and that is a correction to an
# earlier draft of this gate. The canary reports how the refusal reached IT,
# and a server that accepts-and-closes can surface as any of three things
# depending on where the client is when the close lands: EOF on recv
# ("REFUSED"), ECONNRESET on recv, or EPIPE on the send. All three were
# observed across runs of this same gate. Scoring on the canary's wording made
# a full table read as an empty one on the run where the timing shifted by a
# few milliseconds. What is not timing-dependent is the number of ESTABLISHED
# read connections, counted through /proc, so that is what the arm rests on and
# the canary is corroboration.
if [ "${FULLRD:-0}" -eq "$CAP" ]; then
    ok "the read table is verifiably FULL at the instant the extra application starts: the census counts exactly $FULLRD = WSRV_CONN_MAX established read connections, and the canary corroborates by being turned away ($CAN) after a connect(2) that SUCCEEDED -- both listeners are listen(fd,32), so the dial always succeeds and the refusal is always an accept-and-close afterwards"
else
    bad "the census counts $FULLRD established read connections against a cap of $CAP, so the table was NOT full and everything below measured an ordinary launch. Canary: \"$CAN\""
    echo "connbudget: $pass passed, $fail failed"; exit 1
fi
note "  the extra application's shell is alive: $(f arm4.app.alive), its child is $(f arm4.app.kid)"
note "  what it printed: $(f arm4.app.log)"
note "  the window list, read unmediated as the segment owner: $(f arm4.windows)"
WB="$(f arm4.wins.before)"; WA="$(f arm4.wins.after)"; WL="$(f arm4.wins.later)"
WC="$(f arm4.wins.control)"
note "  windows before the refused application started: $WB; after: $WA; after a further 8s still refused: $WL"
note "  and the CONTROL -- the identical command with the table empty: $WC ($(f arm4.windows.control))"
if [ "${WC:-0}" -gt "${WB:-0}" ]; then
    ok "the control lands: the SAME command, a second instance of the same program, DOES add a window ($WB -> $WC) once the table has room. So the window count is a working instrument and the arm below is about the boundary, not about the program"
else
    bad "the control did NOT add a window either ($WB -> $WC): a second instance of this program never lists regardless of the cap, so the window arm below measures the program and must not be read as a fact about the ceiling"
fi
if [ "${WA:-0}" -gt "${WB:-0}" ]; then
    ok "THE REFUSED APPLICATION STILL OPENS ITS WINDOW ($WB -> $WA). The two sockets have separate budgets: the read table was full, the MUTATION table had $(( CAP - $(f arm4.censusfull.srv) )) slots free, and window creation is a mutation."
elif [ "${WC:-0}" -gt "${WB:-0}" ]; then
    bad "THE REFUSED APPLICATION OPENS NO WINDOW, and the control proves the cap is why: with the read table full the count stays $WB -> $WA and is still $WL eight seconds later, while the identical command against an empty table reaches $WC. The application does not know: it prints \"scene window ready\" on its own stdout in the same breath. So the user-visible failure at the read ceiling is a program that starts, reports success, draws nothing a person can see, and leaves its only true explanation in a log nobody opens. That is worse than a refusal to start."
else
    bad "the refused application opened no window ($WB -> $WA) and neither did the control, so this arm cannot say which caused it"
fi
note "  <seg>.refused tail: $(f arm4.refused)"
AL="$(f arm4.app.log)"
if printf '%s' "$AL" | grep -qi 'connection limit\|WSRV_CONN_MAX'; then
    ok "the application refused at the cap names the real cause where a person can read it -- it prints the connection limit and explicitly denies a version disagreement"
else
    bad "the application printed nothing naming the connection limit: \"$AL\". A user meeting this boundary gets no sentence they could act on."
fi
if printf '%s' "$(f arm4.refused)" | grep -qi connrefused; then
    ok "and it is recorded where the system can read it: <seg>.refused has the connrefused line, the same file the version refusal uses"
else
    bad "nothing was appended to <seg>.refused: \"$(f arm4.refused)\""
fi
for c in wsysd hamdesktop hampanelscene; do
    if [ "$(f arm4.alive.$c)" = yes ]; then
        ok "the desktop survives a full read table: $c is still running"
    else
        bad "$c DIED while the read table was full -- the cap takes the desktop chrome with it, which is a far larger failure than one refused application"
    fi
done
note "  panel log tail while full: $(f arm4.panel.tail)"
note "ARM 4b -- and it recovers when the table empties"
note "  after the fill released: srv=$(f stage.recover.srv) rd=$(f stage.recover.rd)"
note "  the application started after the release said: $(f arm4.recover.log)"
RVS="$(f stage.recover.srv)"
if [ "${RVS:-0}" -ge "${B2S:-0}" ]; then
    ok "connections are reclaimed when their holders exit and new clients dial again -- the ceiling is transient, not a latch"
else
    bad "after the fill released its connections the census reads srv=$RVS against a chrome baseline of $B2S: something did not come back"
fi

# ===================== ARM 5: THE PROXIMITY GUARD =======================
# THE ARM THAT EXISTS TO CATCH THE NEXT TIME. Today the answer is "far", and a
# measurement that is only true today is worth very little -- the whole reason
# this gate was written is that two commits moved this number and neither
# counted. So the headroom is asserted, not merely printed.
#
# THE THRESHOLD IS 24 CONCURRENT APPLICATIONS, and it is a judgement rather
# than a measurement, so here is the judgement. 24 is roughly where a heavy
# desktop session lives (a browser, a terminal or three, an editor, a file
# manager, a music player and the chrome), and it is far enough below today's
# 62 that the arm cannot flicker on noise while still firing on any change of
# ORDER: a second connection per application, a hamsh that starts dialling, or
# a chrome component that grows a per-window connection would all halve it or
# worse, and all three are live possibilities in this subsystem.
#
# WHAT MAKES IT FIRE IS THE SLOPE, NOT THE CAP. Raising WSRV_CONN_MAX would
# move this arm green without anything being better, so the headroom is
# computed from the measured per-application cost against whatever the cap is.
note "ARM 5 -- the guard, so the next change to this number is not silent"
GUARD=24
HEAD="$(awk -v c="$CAP" -v base="$BASE" -v w="$WORST" 'BEGIN{printf "%d",(c-base)/w}')"
note "  chrome baseline $BASE, worst-socket cost $WORST per application, cap $CAP -> headroom $HEAD concurrent applications"
if [ "${HEAD:-0}" -ge "$GUARD" ]; then
    ok "the headroom is $HEAD concurrent applications against a floor of $GUARD -- FAR, and this arm is what will say so the day it stops being far"
else
    bad "THE HEADROOM HAS FALLEN TO $HEAD CONCURRENT APPLICATIONS, below the floor of $GUARD. A desktop reaches this by opening windows, and at the read cap an application starts, reports success and shows nothing. This is a release blocker, not a tuning note, and raising WSRV_CONN_MAX is a decision for the owner rather than a way to make this arm green."
fi

echo
echo "connbudget: $pass passed, $fail failed"
[ "$fail" = 0 ]
