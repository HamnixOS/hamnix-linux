#!/usr/bin/env bash
# tests/linux/de_appmenu_realboot.sh — WHICH MENU DOES A PERSON GET WHEN THEY
# CLICK "Applications" ON AN INSTALLED MACHINE?
#
# THE QUESTION, AND WHY THE ANSWER WAS NOT ALREADY KNOWN
# ======================================================
# The machine's owner asked for the MATE Brisk menu: categories with fly-outs,
# a search box, a Favourites section. `user/hamappmenu.ad` had been exactly
# that for months and reached NOBODY -- it was in neither the image's APPS nor
# the channel's DESKTOP_CMDS, so `/bin/hamappmenu` existed on no machine and
# `hampanelscene._appmenu_available()` returned 0 on every boot. The button
# silently used the panel's own flat in-panel dropdown instead.
#
# That has been fixed in both lists, and tests/linux/de_appmenu_brisk.sh proves
# the menu works -- OFFSCREEN, with the binary placed by hand, on a framebuffer
# in a file. Two claims were then in play and only the first was proven:
#
#     "hamappmenu is in the package list"
#     "a person clicking Applications on a real machine gets it"
#
# The whole reason the feature was invisible for months is that nobody checked
# the second. So this file boots a REAL INSTALLED MACHINE -- UEFI firmware,
# OVMF, a GPT disk with an ESP and an ext4 root, the unified kernel image the
# firmware executes -- puts a REAL POINTER on the Applications button over QMP
# `input-send-event` on `virtio-tablet-pci`, and photographs the screen.
#
# HOW THE TWO MENUS ARE TOLD APART, AND WHY IT HAS TO BE PIXELS
# ==============================================================
# NOT by a log line ("[panel] launched /bin/hamappmenu -self" is printed
# whether or not a window ever appears -- that exact success-shaped claim is
# what hid the bug). NOT by which binary exists (that is the claim under test).
# The two menus are told apart by what they PUT ON THE GLASS, and they differ
# in three ways that are each a hard number:
#
#            THE NEW MENU (hamappmenu)          THE OLD ONE (panel dropdown)
#   window   its OWN window at (8,28),          NO new window; the PANEL's own
#            208px box + 200px fly-out          window GROWS from 26px tall to
#            band = 407 wide; panel             ~228, and the list is painted
#            stays 26 tall                      inside it
#   row 0    a WHITE (#ffffff) SEARCH FIELD     an app label on the #f7f8fa card
#   rows     CATEGORY BUTTONS on the #eef0f3    a FLAT list of app names
#            strip, one per category
#
# Note what is NOT a discriminator: the card's body colour. Both are #f7f8fa
# and both open just under the Applications button. "There is a menu-coloured
# card below the button" would have passed on the broken machine.
#
# BOTH ARMS, ON ONE DISK, IN ONE RUN
# ==================================
# An assertion that cannot fail is not an assertion. So the SAME disk boots
# twice and the same hand does the same things to it:
#
#   ARM NEW  /bin/hamappmenu is on the disk, as it ships. Every assertion
#            above must hold.
#   ARM OLD  the last thing ARM NEW's boot does is `mv /bin/hamappmenu
#            /bin/hamappmenu.absent` and reboot -- deliberately re-creating the
#            machine everybody has been running for months. Every assertion
#            above must FAIL, the panel must say by name that it is falling
#            back, and its own window must be the thing that grew.
#
# If ARM OLD passed the new-menu assertions they would be measuring nothing.
#
# THE MEASUREMENT MUST NOT BE THE THING IT MEASURES
# =================================================
# Screendumps, the pointer and the keyboard come from OUTSIDE the guest over
# QMP; they cannot perturb the session. The window table is read INSIDE the
# guest with `cat /dev/wsys/<wid>/ctl` -- `cat` is a wsys client, so it must be
# the same wsys version as the segment it reads (tests/linux/
# installed_update_wsysver.sh is the gate that learned this the hard way, by
# photographing the wreck a mismatched `cat` had made and blaming the desktop).
# Here the whole disk is built from THIS tree in one pass, so /bin/cat and
# /bin/wsysd are the same build by construction -- and the gate checks that
# nothing on the disk came from anywhere else.
#
# SEARCH AND FAVOURITES ARE RE-ASKED HERE, and that is not duplication of the
# offscreen gate: keyboard input on a real boot is a DIFFERENT PATH. Offscreen,
# wsysd reads 24-byte input_event records out of a file named by
# HAMWSYSD_INPUT; here it scans /dev/input/event0..15 and the keystrokes are
# QEMU's `virtio-keyboard-pci` delivering qcodes. A search box that filters in
# one and not the other is a real defect and nothing else in the tree would
# see it.
#
# Usage: tests/linux/de_appmenu_realboot.sh [boot1s] [boot2s]
#   HAMLINUX_AR_REUSE=1  reuse the disk an earlier run built
#   HAMLINUX_AR_KEEP=1   keep the work directory
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"
. tests/linux/reap.sh

export HAMLINUX_VNC="${HAMLINUX_VNC:-none}"
export HAMLINUX_DISTRO_RO="${HAMLINUX_DISTRO_RO:-1}"
export TMPDIR="${TMPDIR:-$PROJ_ROOT/build/tmp}"
mkdir -p "$TMPDIR"

WAIT1="${1:-600}"
WAIT2="${2:-600}"

WORK="${HAMLINUX_AR_WORK:-$HOME/.hamnix-build/appmenu-realboot}"; mkdir -p "$WORK"
SHOT="$WORK/shots"; mkdir -p "$SHOT"
IMG=build/image
DISK="$WORK/appmenu.img"
EXTRA="$WORK/extra"
QMP="$WORK/qmp.sock"
reap_track "$WORK/reaped"

pass=0; fail=0
ok()   { echo "realboot: PASS $*"; pass=$((pass+1)); }
bad()  { echo "realboot: FAIL $*"; fail=$((fail+1)); }
info() { echo "realboot: INFO $*"; }
say()  { echo "[ar] $*"; }

[ -f "$IMG/vmlinuz" ] || { echo "no image; run scripts/hamlinux_image.sh" >&2; exit 1; }
command -v python3 >/dev/null || { echo "need python3" >&2; exit 1; }

# ===========================================================================
# THE GEOMETRY. Every number here is read off the shipped source, not tuned to
# a screenshot: lib/appmenucore.ad's AMC_BOX_W (208), AMC_ROW_H (20),
# AMC_CHILD_W (200), and user/hamappmenu.ad's `_am_place_window(wid, 8, 28)`.
# The window is BOX_W - 1 + CHILD_W wide so a hover fly-out is contained.
# ===========================================================================
MX=8; MY=28; BOXW=208; ROWH=20; CHILDW=200
WINW=$((BOXW - 1 + CHILDW))          # 407
ROWX=$((MX + 4)); ROWW=$((BOXW - 20))
row_y() { echo $((MY + $1 * ROWH + 2)); }
R1Y="$(row_y 1)"; R6Y="$(row_y 6)"
SEARCH_X=$((MX + 2)); SEARCH_Y=$((MY + 2)); SEARCH_W=$((BOXW - 4)); SEARCH_H=$((ROWH - 4))
CATBTN=eef0f3; HDR=eceef2; WHITE=ffffff

APPBTN_X=40; APPBTN_Y=13             # the Applications button on the top bar
NEUTRAL_X=900; NEUTRAL_Y=600
SEARCH_CLICK_X=$((MX + 120)); SEARCH_CLICK_Y=$((MY + 10))
APPROW_X=$((MX + 110)); APPROW_Y=$((MY + 2 * ROWH + 10))
SCREEN_W=1280; SCREEN_H=800

# THE APP THIS GATE LAUNCHES, and why it is Files and not Calculator. The menu
# on an installed machine is built by hamappmenu's _seed_fallback() (see the
# FINDING at the end of this file), and of the eleven entries in it, "Files" is
# one of the three whose program is actually ON the machine. A launch of a
# program that is not there would still write the favourites file -- so
# choosing it would have made the Favourites assertion pass while proving
# nothing about launching.
SEARCH_TEXT=fil
LAUNCH_PROG=/bin/hamfm

# ===========================================================================
# THE GUEST SIDE. Two rc scripts, staged onto the disk before it is made.
# ===========================================================================
mkdir -p "$EXTRA/etc"

# The window table, read with the disk's OWN cat (same build as its wsysd).
# READS ONLY: `cat` on a ctl file is how tests/linux/de_mouse_chrome.sh and
# de_appmenu_brisk.sh read it, for the reason their headers give about
# instruments that break what they measure.
_probe() {   # _probe <tag>
    cat <<W
echo '[ar] WINS-$1'
/bin/cat '/dev/wsys/2/ctl'
/bin/cat '/dev/wsys/3/ctl'
/bin/cat '/dev/wsys/4/ctl'
/bin/cat '/dev/wsys/5/ctl'
/bin/cat '/dev/wsys/6/ctl'
/bin/cat '/dev/wsys/7/ctl'
/bin/cat '/dev/wsys/8/ctl'
echo '[ar] WINS-END-$1'
echo '[ar] TITLES-$1:'
/bin/cat '/dev/wsys/windows'
echo '[ar] PROBE-END-$1'
W
}

# The four moments the host's hand pauses at. The guest sleeps a fixed time
# after each marker (long enough for the hand) and then reads the table WITH
# THE MENU STILL OPEN; the host waits for PROBE-END before it moves on, so the
# two stay in step in both directions.
#
# THE FAVOURITES FILE IS LOOKED FOR IN BOTH PLACES, and that is not hedging.
# lib/homedir.ad resolves $HOME as /env/HOME, then /etc/passwd BY UID, then
# /home/live. The DE on this line is started by /etc/rc.d/rc.5 as PID 1's
# uid -- 0 -- and /etc/passwd says in as many words that "uid 0 doesn't exist
# in Hamnix", so the passwd lookup misses and every DE client's home is
# /home/live: the LIVE IMAGE's user, a directory an installed disk does not
# have. Printing both is what turns "the favourites file is missing" into
# "the favourites file is missing HERE and absent THERE", which is the
# difference between a symptom and a cause.
_stage_guest() {   # _stage_guest <tag>
    cat <<W
echo '[ar] MARK-$1-open'
sleep 55
W
    _probe "$1-open"
    cat <<W
echo '[ar] MARK-$1-search'
sleep 55
W
    _probe "$1-search"
    cat <<W
echo '[ar] MARK-$1-fav'
sleep 80
echo '[ar] FAV-$1:'
/bin/cat '/home/live/.hamde/favourites'
/bin/cat '/root/.hamde/favourites'
echo '[ar] FAV-END-$1'
W
    _probe "$1-fav"
    cat <<W
echo '[ar] MARK-$1-third'
sleep 45
W
    _probe "$1-third"
    cat <<W
echo '[ar] HOMES-$1:'
id
stat /home/live
stat /root
stat /root/.hamde
echo '[ar] PROCS-$1:'
ps
echo '[ar] PANELLOG-$1:'
# grep, not tail: the app this gate launches (/bin/hamfm) is a TUI and its
# curses output goes to the panel's stdout, which IS /var/log/panel.log -- a
# tail of that file is a screenful of escape sequences and no panel lines.
grep panel /var/log/panel.log
echo '[ar] PANELLOG-END-$1'
echo '[ar] BINS-$1:'
stat /bin/hamappmenu
stat /bin/hamfm
echo '[ar] CATALOGUE-$1:'
stat /etc/hamde
W
}

{
cat <<'RC'
source '/etc/rc.boot.installed'
echo '[ar] ===== ARM NEW: /bin/hamappmenu is on the disk, as it ships.'
date
# `stat`, NOT `ls -l`. On this line `ls` given a REGULAR FILE prints its
# CONTENTS: the first run of this gate put 450 KB of /bin/hamappmenu's ELF on
# the serial console, three times, before the desktop had finished starting.
# That is a real defect and it is reported as a FINDING at the end of this
# file; here it is simply avoided, because a probe that dumps a binary into the
# log it is being read out of is not a probe.
stat /bin/hamappmenu
stat /bin/wsysd
stat /bin/cat
# rc.boot.installed ends by sourcing /etc/rc.d/rc.5, which starts wsysd, the
# desktop and the panel. Give a desktop the time a desktop takes.
sleep 25
RC
_stage_guest NEW
cat <<'RC'
# ARM OLD IS ARMED HERE. Moving the binary aside re-creates, exactly, the
# machine everybody has been running for months: hampanelscene's
# _appmenu_available() opens /bin/hamappmenu, fails, and points the button at
# the dropdown it draws itself. Nothing else about the disk changes.
mv /bin/hamappmenu /bin/hamappmenu.absent
echo '[ar] armed ARM OLD: /bin/hamappmenu moved aside'
stat /bin/hamappmenu.absent
cp /etc/rc.arm.old /etc/rc.boot
echo '[ar] ARM-NEW DONE'
reboot
RC
} > "$WORK/rc.arm.new"

{
cat <<'RC'
source '/etc/rc.boot.installed'
echo '[ar] ===== ARM OLD: the same disk with /bin/hamappmenu moved aside --'
echo '[ar]               the machine as it was before the fix.'
date
stat /bin/hamappmenu
stat /bin/hamappmenu.absent
sleep 25
RC
_stage_guest OLD
cat <<'RC'
echo '[ar] ARM-OLD DONE'
poweroff
RC
} > "$WORK/rc.arm.old"

cp "$WORK/rc.arm.old" "$EXTRA/etc/rc.arm.old"

# ===========================================================================
# THE DISK: UEFI + ESP + ext4, built from this tree in one pass.
# ===========================================================================
if [ "${HAMLINUX_AR_REUSE:-0}" = 1 ] && [ -f "$DISK" ]; then
    say "reusing $DISK (HAMLINUX_AR_REUSE=1)"
else
    say "building the installed disk (UEFI + ESP + ext4)"
    HAMLINUX_DISK_RC="$WORK/rc.arm.new" HAMLINUX_DISK_EXTRA="$EXTRA" \
        nice -n 15 scripts/hamlinux_disk.sh "$DISK" 3G >"$WORK/build.log" 2>&1 || {
        echo "FAIL disk build"; tail -20 "$WORK/build.log"; exit 1; }
fi

# ===========================================================================
# THE HAND. Every event below leaves the host over QMP `input-send-event` and
# arrives at the guest on virtio-tablet-pci / virtio-keyboard-pci. Nothing here
# writes a wsys ring or an evdev file; the check at the end of this file
# enforces that.
# ===========================================================================
Q() { python3 tests/linux/qmp_input.py "$QMP" "$@" >>"$LOGCLICK" 2>&1; }
shot() { Q screendump "$SHOT/$1.ppm"; }
click() { Q click "$1" "$2" "$SCREEN_W" "$SCREEN_H"; }

waitmark() {   # waitmark <log> <marker> <deadline-seconds>
    local i=0
    while [ "$i" -lt "$(( $3 * 2 ))" ]; do
        grep -aq "$2" "$1" && return 0
        kill -0 "$VM" 2>/dev/null || return 1
        sleep 0.5; i=$((i + 1))
    done
    return 1
}

stage_hand() {   # stage_hand <tag>
    local t="$1"
    waitmark "$LOG" "MARK-$t-open" "$SECS" || { say "  $t: no open marker"; return 1; }
    sleep 3
    shot "$t-1-idle"
    sleep 3
    shot "$t-2-idle"                     # the noise floor: a cursor, a clock
    say "  $t: clicking Applications at ($APPBTN_X,$APPBTN_Y) with a real pointer"
    click "$APPBTN_X" "$APPBTN_Y"
    sleep 4
    shot "$t-3-menu"
    waitmark "$LOG" "PROBE-END-$t-open" 120

    waitmark "$LOG" "MARK-$t-search" "$SECS" || return 1
    sleep 2
    # Focus the menu with a press on its search row: the compositor gates the
    # keyboard on focus (wsysd's route_key), and row 0 is the one click in this
    # menu that neither launches anything nor dismisses it.
    click "$SEARCH_CLICK_X" "$SEARCH_CLICK_Y"
    sleep 2
    shot "$t-4-focused"
    say "  $t: typing '$SEARCH_TEXT' on the real keyboard"
    Q type "$SEARCH_TEXT"
    sleep 4
    shot "$t-5-filtered"
    waitmark "$LOG" "PROBE-END-$t-search" 120

    waitmark "$LOG" "MARK-$t-fav" "$SECS" || return 1
    sleep 2
    say "  $t: clicking the filtered app row at ($APPROW_X,$APPROW_Y)"
    click "$APPROW_X" "$APPROW_Y"
    sleep 8
    shot "$t-6-launched"
    say "  $t: clicking Applications again -- does the launch show up in Favourites"
    click "$APPBTN_X" "$APPBTN_Y"
    sleep 5
    shot "$t-7-reopened"
    # THE PROBE COMES BEFORE THE DISMISS, so the window table is read while
    # whatever the second click opened is still up. The first run of this gate
    # dismissed first and could then only say that nothing was there AFTER a
    # dismissing click -- which is not the same statement.
    waitmark "$LOG" "PROBE-END-$t-fav" 120

    # THE THIRD CLICK. hampanelscene's _toggle_appmenu, when it believes the
    # menu it spawned is still alive, sends it a `terminate` note and RETURNS
    # WITHOUT SPAWNING ONE. So "the second click opened nothing" has two very
    # different causes -- a stale liveness belief (the second click closed a
    # menu that had already closed itself, and a THIRD click opens one) versus
    # a menu that cannot start a second time at all -- and a third click is
    # what tells them apart. Neither would have been visible offscreen, where
    # the gate spawns the menu itself and the panel's toggle never runs.
    waitmark "$LOG" "MARK-$t-third" "$SECS" || return 1
    sleep 2
    say "  $t: clicking Applications a THIRD time"
    click "$APPBTN_X" "$APPBTN_Y"
    sleep 5
    shot "$t-8-third"
    waitmark "$LOG" "PROBE-END-$t-third" 120
    click "$NEUTRAL_X" "$NEUTRAL_Y"
    sleep 3
    shot "$t-9-dismissed"
}

boot() {   # boot <logfile> <seconds> <tag>
    local log="$1"; SECS="$2"; local tag="$3"
    LOG="$log"; LOGCLICK="$log.qmp"
    rm -f "$QMP"
    ( sleep 5 ) | HAMLINUX_DISK="$DISK" \
        timeout "$((SECS + 60))" scripts/hamlinux_vm.sh disk --timeout "$SECS" \
        -qmp "unix:$QMP,server=on,wait=off" >"$log" 2>&1 &
    VM=$!; reap_add "$VM"
    stage_hand "$tag"
    wait "$VM" 2>/dev/null
    VM=""
}

cleanup() { rm -f "$QMP"; }
reap_on_exit cleanup

say "boot 1 of 2: ARM NEW -- the machine as it ships (up to ${WAIT1}s)"
boot "$WORK/boot.new.log" "$WAIT1" NEW
say "boot 2 of 2: ARM OLD -- the same disk, hamappmenu moved aside (up to ${WAIT2}s)"
boot "$WORK/boot.old.log" "$WAIT2" OLD

# ===========================================================================
# WHAT THE SCREEN AND THE WINDOW TABLE SAY.
#
# LC_ALL=C for the readers below: the serial log is a BYTE stream with a boot
# console in it, awk in a UTF-8 locale calls that "invalid multibyte data" and
# prints a warning per line per pass, which buries the report in noise.
# ===========================================================================
export LC_ALL=C
pct() {   # pct <shot> <rrggbb> <x> <y> <w> <h>
    local s="$1"; shift
    local c="$1"; shift
    python3 tests/linux/ppmdiff.py pct "$SHOT/$s.ppm" "$c" "$@" 2>/dev/null
}
ppn() {   # ppn <a> <b> [x y w h] -- pixels differing
    local a="$1" b="$2"; shift 2
    python3 tests/linux/ppmdiff.py diff "$SHOT/$a.ppm" "$SHOT/$b.ppm" "$@" 2>/dev/null |
        sed -n 's/.*: \([0-9]*\) of .*/\1/p;s/.*IDENTICAL.*/0/p' | head -1
}
# THE WINDOW TABLE. `cat /dev/wsys/<wid>/ctl` prints
# `wid x y w h z decorate visible proto ...`.
winline() {   # winline <log> <tag> <wid>
    awk -v m="WINS-$2" -v w="$3" '
        index($0,m){i=1;next} i&&index($0,"WINS-END"){exit}
        i&&$1==w&&NF>=5{print; exit}' "$1" | tr -d '\r'
}
wintable() {   # wintable <log> <tag>
    awk -v m="WINS-$2" 'index($0,m){i=1;next} i&&index($0,"WINS-END"){exit}
                        i&&NF>=5&&$1~/^[0-9]+$/{printf "(%s) ", $0}' "$1" | tr -d '\r'
}
# THE MENU'S OWN WINDOW: at (8,28) and 407 wide. Prints its wid, or nothing.
menuwin() {   # menuwin <log> <tag>
    awk -v m="WINS-$2" -v mx="$MX" -v my="$MY" -v ww="$WINW" '
        index($0,m){i=1;next} i&&index($0,"WINS-END"){exit}
        i&&$2==mx&&$3==my&&$4==ww{print $1; exit}' "$1" | tr -d '\r'
}
# THE PANEL: the full-width bar at the top of the screen. Prints "wid height".
panelwin() {   # panelwin <log> <tag>
    awk -v m="WINS-$2" -v sw="$SCREEN_W" '
        index($0,m){i=1;next} i&&index($0,"WINS-END"){exit}
        i&&$3==0&&$4==sw&&$5<400{print $1, $5; exit}' "$1" | tr -d '\r'
}
favfile() {   # favfile <log> <tag>
    awk -v m="FAV-$2:" 'index($0,m){i=1;next} i&&index($0,"FAV-END"){exit}
                        i&&NF>0{printf "%s ", $0}' "$1" | tr -d '\r'
}
# WHAT THE PANEL ITSELF SAID. Its stdout is /var/log/panel.log INSIDE the
# guest, not the serial console, so this reads the section the guest grepped
# out of that file for us -- not the boot log, which never had those lines in
# it. (The first run of this gate asserted against the boot log and reported
# "the panel did not say it was using /bin/hamappmenu" when the panel had said
# exactly that, in a file the assertion was not looking at.)
panelsaid() {   # panelsaid <log> <tag>
    awk -v m="PANELLOG-$2:" 'index($0,m){i=1;next} i&&index($0,"PANELLOG-END"){exit}
                             i&&index($0,"[panel]"){print}' "$1" | tr -d '\r'
}

report_arm() {   # report_arm <log> <tag> <headline>
    local L="$1" t="$2"
    echo
    echo "--- ARM $t: $3"
    echo "    idle -> idle:        $(ppn "$t-1-idle" "$t-2-idle") px changed (the noise floor)"
    echo "    Applications ->      $(ppn "$t-2-idle" "$t-3-menu") px changed"
    echo "    row 0 white:         $(pct "$t-3-menu" $WHITE $SEARCH_X $SEARCH_Y $SEARCH_W $SEARCH_H)% of ${SEARCH_W}x${SEARCH_H}+${SEARCH_X}+${SEARCH_Y} is the search field"
    echo "    row 1 catbtn strip:  $(pct "$t-3-menu" $CATBTN "$ROWX" "$R1Y" "$ROWW" $((ROWH - 4)))%"
    echo "    row 1 header strip:  $(pct "$t-3-menu" $HDR "$ROWX" "$R1Y" "$ROWW" $((ROWH - 4)))% (open) / $(pct "$t-7-reopened" $HDR "$ROWX" "$R1Y" "$ROWW" $((ROWH - 4)))% (reopened after a launch)"
    echo "    2nd click ->         $(ppn "$t-6-launched" "$t-7-reopened") px changed (reopen after the launch)"
    echo "    3rd click ->         $(ppn "$t-7-reopened" "$t-8-third") px changed"
    echo "    window table (open): $(wintable "$L" "$t-open")"
    echo "    window table (2nd):  $(wintable "$L" "$t-fav")"
    echo "    window table (3rd):  $(wintable "$L" "$t-third")"
    echo "    menu's own window:   open '$(menuwin "$L" "$t-open")' / after 2nd click '$(menuwin "$L" "$t-fav")' / after 3rd '$(menuwin "$L" "$t-third")'"
    echo "    panel window:        $(panelwin "$L" "$t-open") (open)"
    echo "    favourites file:     $(favfile "$L" "$t")"
    echo "    homes:               $(awk -v m="HOMES-$t:" 'index($0,m){i=1;next} i&&index($0,"PROCS-"){exit} i&&NF>0{printf "%s ", $0}' "$L" | tr -d '\r')"
    echo "    the panel said:      $(panelsaid "$L" "$t" | sort | uniq -c | tr '\n' '|')"
    python3 tests/linux/ppmdiff.py png "$SHOT/$t-3-menu.ppm" "$SHOT/$t-3-menu.png" >/dev/null 2>&1
    python3 tests/linux/ppmdiff.py png "$SHOT/$t-8-third.ppm" "$SHOT/$t-8-third.png" >/dev/null 2>&1
    python3 tests/linux/ppmdiff.py png "$SHOT/$t-5-filtered.ppm" "$SHOT/$t-5-filtered.png" >/dev/null 2>&1
    python3 tests/linux/ppmdiff.py png "$SHOT/$t-7-reopened.ppm" "$SHOT/$t-7-reopened.png" >/dev/null 2>&1
}

echo "=========================================================="
echo " WHAT A PERSON GETS WHEN THEY CLICK Applications"
echo "=========================================================="
report_arm "$WORK/boot.new.log" NEW "/bin/hamappmenu on the disk, as it ships"
report_arm "$WORK/boot.old.log" OLD "/bin/hamappmenu moved aside -- the machine before the fix"

echo
echo "=========================================================="
echo " THE QUESTIONS"
echo "=========================================================="

# ---- 0. the machine booted at all, and is one build ----------------------
if grep -aq 'rc\.boot: hamnix-linux (installed)' "$WORK/boot.new.log"; then
    ok "the installed root came online off a UEFI disk (ESP -> unified kernel image -> PID 1 -> bind '#sysroot' /)"
else
    bad "the installed root never came online -- nothing below is a question this run can answer"
    echo "realboot: $pass passed, $fail failed"; exit 1
fi

# ---- 1. THE NEW MENU'S OWN WINDOW ---------------------------------------
NEWWID="$(menuwin "$WORK/boot.new.log" NEW-open)"
NEWPANEL="$(panelwin "$WORK/boot.new.log" NEW-open)"
NEWPANELH="${NEWPANEL#* }"
if [ -n "$NEWWID" ]; then
    ok "A NEW WINDOW APPEARED when Applications was clicked on a real boot: wid $NEWWID at ($MX,$MY), $WINW px wide -- the 208 px menu box plus the 200 px category fly-out band. The panel did not merely grow: it is still ${NEWPANELH:-?} px tall. $(winline "$WORK/boot.new.log" NEW-open "$NEWWID")"
else
    bad "NO SEPARATE MENU WINDOW on a real boot. The window table with the menu open was: $(wintable "$WORK/boot.new.log" NEW-open)"
fi
[ "${NEWPANELH:-0}" -le 40 ] 2>/dev/null &&
    ok "and the PANEL's own window stayed a bar ($NEWPANELH px tall) -- the flat in-panel dropdown, which grows it past 200, is not what opened" ||
    info "the panel window is ${NEWPANELH:-?} px tall with the menu open"

# ---- 2. THE SEARCH FIELD, IN PIXELS -------------------------------------
NEWWHITE="$(pct NEW-3-menu $WHITE $SEARCH_X $SEARCH_Y $SEARCH_W $SEARCH_H)"
if [ "${NEWWHITE:-0}" -ge 50 ]; then
    ok "the menu on the glass has a SEARCH BOX: row 0 is ${NEWWHITE}% the white search field"
else
    bad "row 0 is only ${NEWWHITE:-?}% search-field white -- what opened has no search box"
fi

# ---- 3. CATEGORY ROWS ----------------------------------------------------
NEWCAT="$(pct NEW-3-menu $CATBTN "$ROWX" "$R1Y" "$ROWW" $((ROWH - 4)))"
NEWHDR="$(pct NEW-3-menu $HDR "$ROWX" "$R1Y" "$ROWW" $((ROWH - 4)))"
if [ "${NEWCAT:-0}" -ge 40 ]; then
    ok "and CATEGORY ROWS: row 1 is ${NEWCAT}% the category-button strip -- one submenu per category, the 'Debian apps >' shape the owner pointed at"
else
    bad "row 1 is only ${NEWCAT:-?}% category-button strip -- what opened is not the categorized menu"
fi
if [ "${NEWHDR:-100}" -le 5 ]; then
    ok "CONTROL: with no launch history there is NO Favourites header in row 1 (${NEWHDR}%) -- assertion 6 cannot be satisfied by a header that was always there"
else
    bad "CONTROL: row 1 is already ${NEWHDR}% header strip before anything has been launched"
fi

# ---- 4. THE SEARCH BOX, TYPED INTO ON A REAL KEYBOARD -------------------
COVERED="$(ppn NEW-1-idle NEW-4-focused "$ROWX" "$R6Y" "$ROWW" $((ROWH - 4)))"
STILL="$(ppn NEW-1-idle NEW-5-filtered "$ROWX" "$R6Y" "$ROWW" $((ROWH - 4)))"
TOTAL="$((ROWW * (ROWH - 4)))"
if [ "${COVERED:-0}" -lt $((TOTAL / 2)) ]; then
    bad "the menu card never covered row 6 before typing ($COVERED of $TOTAL px differ from the bare desktop) -- 'typing shrank it' is not a question this run can answer"
elif [ "${STILL:-$TOTAL}" -le $((TOTAL / 20)) ]; then
    ok "TYPING '$SEARCH_TEXT' ON THE REAL KEYBOARD (virtio-keyboard-pci, over QMP) FILTERED THE LIST: row 6 went from $COVERED of $TOTAL px covering the wallpaper to $STILL -- the card actually shrank back to bare desktop"
else
    bad "THE DEFECT: after real keystrokes the card still covers row 6 ($STILL of $TOTAL px differ from the bare desktop) -- the search box did not filter on a real boot"
fi
FCAT="$(pct NEW-5-filtered $CATBTN "$ROWX" "$R1Y" "$ROWW" $((ROWH - 4)))"
FHDR="$(pct NEW-5-filtered $HDR "$ROWX" "$R1Y" "$ROWW" $((ROWH - 4)))"
if [ "${FHDR:-0}" -ge 40 ] && [ "${FCAT:-100}" -le 5 ]; then
    ok "and the filtered result is GROUPED, MATE-style: row 1 is a section header (${FHDR}%) and the category buttons are gone (${FCAT}%, was ${NEWCAT}%)"
else
    bad "the filtered list is not grouped: row 1 is ${FHDR:-?}% header and ${FCAT:-?}% category button"
fi

# ---- 5. A CLICK THAT LAUNCHES -------------------------------------------
# The launch is measured twice, because the two halves fail separately: the
# menu CLOSED (its card is off the glass and its window is out of the table),
# and the launch was RECORDED (the favourites file). On this machine the first
# is true and the second is not.
LCLOSE="$(ppn NEW-1-idle NEW-6-launched "$ROWX" "$R1Y" "$ROWW" $((ROWH - 4)))"
if [ "${LCLOSE:-$TOTAL}" -le $((TOTAL / 20)) ] && [ -z "$(menuwin "$WORK/boot.new.log" NEW-fav)" ]; then
    ok "a real click on the filtered row CLOSED the menu: row 1 is back to bare wallpaper ($LCLOSE of $TOTAL px differ) and the menu's window is gone from the table"
else
    bad "after clicking the app row the menu is still on the screen ($LCLOSE of $TOTAL px of row 1 still differ from the bare desktop)"
fi
NEWFAV="$(favfile "$WORK/boot.new.log" NEW)"
case "$NEWFAV" in
    *"$LAUNCH_PROG"*)
        ok "and the launch was RECORDED: the favourites file on the installed disk names $LAUNCH_PROG ($NEWFAV)" ;;
    *)
        bad "THE DEFECT, AND IT IS ONLY VISIBLE HERE: nothing was recorded as launched. Neither /home/live/.hamde/favourites nor /root/.hamde/favourites exists -- '$NEWFAV'. lib/homedir.ad resolves \$HOME as /env/HOME, then /etc/passwd BY UID, then /home/live; /etc/rc.d/rc.5 starts the DE as uid 0 and /etc/passwd has no uid 0 ('uid 0 doesn't exist in Hamnix'), so every DE client's home is /home/live -- the LIVE IMAGE's user, a directory an INSTALLED disk does not have -- and hamappmenu's _fav_save does one non-recursive sys_mkdir and then gives up silently. tests/linux/de_appmenu_brisk.sh cannot see this: it mounts a writable tmpfs on /root and its euid resolves there. $(awk -v m="HOMES-NEW:" 'index($0,m){i=1;next} i&&index($0,"PROCS-"){exit} i&&NF>0{printf "%s ", $0}' "$WORK/boot.new.log" | tr -d '\r')" ;;
esac

# ---- 6. FAVOURITES, ON THE REAL MACHINE ---------------------------------
RHDR="$(pct NEW-7-reopened $HDR "$ROWX" "$R1Y" "$ROWW" $((ROWH - 4)))"
RCAT="$(pct NEW-7-reopened $CATBTN "$ROWX" "$R1Y" "$ROWW" $((ROWH - 4)))"
REWID="$(menuwin "$WORK/boot.new.log" NEW-fav)"
R3WID="$(menuwin "$WORK/boot.new.log" NEW-third)"
R3="$(ppn NEW-7-reopened NEW-8-third)"
if [ "${NEWHDR:-0}" -gt 5 ]; then
    bad "row 1 was already a header before anything was launched, so 'the Favourites section appeared' is not a question this run can answer"
elif [ "${RHDR:-0}" -ge 40 ] && [ "${RCAT:-100}" -le 5 ]; then
    ok "REOPENED AFTER THE LAUNCH, THE MENU SHOWS FAVOURITES AT THE TOP: row 1 is a header (${RHDR}%, was ${NEWHDR}%) where the control measured a category button (${RCAT}%, was ${NEWCAT}%). The recency list outlived the process that recorded it, on a real disk."
elif [ -z "$REWID" ]; then
    bad "THE SECOND DEFECT: THE SECOND CLICK ON Applications OPENED NOTHING AT ALL. No menu window is in the table after it ('${REWID:-none}') and row 1 is ${RHDR:-?}% header / ${RCAT:-?}% category button -- there is no menu to hold a Favourites section. THE THIRD CLICK $( [ -n "$R3WID" ] && echo "DID open one (wid $R3WID, $R3 px changed), so the button takes two clicks after a launch: hampanelscene's _toggle_appmenu believed the menu it spawned was still alive, sent it a terminate note and returned without spawning" || echo "opened nothing either ($R3 px changed)")"
else
    bad "THE DEFECT: the reopened menu shows no Favourites section -- row 1 is ${RHDR:-?}% header and ${RCAT:-?}% category button"
fi

# ---- 7. THE ARM THAT MUST FAIL ------------------------------------------
# Everything above, asked of the same disk with the binary moved aside. If any
# of it still passed, it was not measuring the menu.
echo
OLDWID="$(menuwin "$WORK/boot.old.log" OLD-open)"
OLDPANEL="$(panelwin "$WORK/boot.old.log" OLD-open)"
OLDPANELH="${OLDPANEL#* }"
OLDWHITE="$(pct OLD-3-menu $WHITE $SEARCH_X $SEARCH_Y $SEARCH_W $SEARCH_H)"
OLDCAT="$(pct OLD-3-menu $CATBTN "$ROWX" "$R1Y" "$ROWW" $((ROWH - 4)))"
OLDCLICK="$(ppn OLD-2-idle OLD-3-menu)"
if [ -z "$OLDWID" ] && [ "${OLDWHITE:-100}" -lt 50 ] && [ "${OLDCAT:-100}" -lt 40 ]; then
    ok "THE FAILING ARM FAILS: with /bin/hamappmenu moved aside the same click opened NO window at ($MX,$MY) [table: $(wintable "$WORK/boot.old.log" OLD-open)], row 0 is ${OLDWHITE}% search-field white (was ${NEWWHITE}%) and row 1 is ${OLDCAT}% category strip (was ${NEWCAT}%). The three assertions above can tell the two menus apart."
else
    bad "THE ASSERTIONS ARE NOT MEASURING THE MENU: with hamappmenu absent they still see wid '${OLDWID:-none}', ${OLDWHITE:-?}% search field, ${OLDCAT:-?}% category strip"
fi
if [ "${OLDCLICK:-0}" -gt 5000 ] && [ "${OLDPANELH:-0}" -gt 100 ]; then
    ok "and what a person got INSTEAD is visible and identified: the click changed $OLDCLICK px and the PANEL'S OWN window grew to ${OLDPANELH} px tall (it is ${NEWPANELH} px in ARM NEW) -- the flat in-panel dropdown, drawn inside the panel window"
else
    info "ARM OLD: the click changed ${OLDCLICK:-?} px and the panel window is ${OLDPANELH:-?} px tall"
fi
if panelsaid "$WORK/boot.old.log" OLD | grep -q "no /bin/hamappmenu; Applications button -> the panel's own dropdown"; then
    ok "and the panel SAID SO BY NAME in ARM OLD: \"no /bin/hamappmenu; Applications button -> the panel's own dropdown\""
else
    bad "ARM OLD: the panel never said which menu it was using: $(panelsaid "$WORK/boot.old.log" OLD | tr '\n' '|')"
fi
if panelsaid "$WORK/boot.new.log" NEW | grep -q "Applications button -> /bin/hamappmenu"; then
    ok "and in ARM NEW it said the other thing: \"[panel] Applications button -> /bin/hamappmenu\""
else
    bad "ARM NEW: the panel did not report pointing the button at /bin/hamappmenu: $(panelsaid "$WORK/boot.new.log" NEW | tr '\n' '|')"
fi
# HOW MANY TIMES DID IT SAY IT LAUNCHED ONE? This is the number that separates
# "the panel spawned a menu that never appeared" from "the panel never spawned
# a second menu at all", and it is the reason the claim in that log line is not
# evidence of a menu: it is printed on the spawn, not on a window.
SPAWNS="$(panelsaid "$WORK/boot.new.log" NEW | grep -c 'launched /bin/hamappmenu')"
info "the panel printed \"launched /bin/hamappmenu -self\" $SPAWNS time(s) in ARM NEW, against 3 clicks on the button and $( [ -n "$NEWWID" ] && echo 1 || echo 0 )+$( [ -n "$REWID" ] && echo 1 || echo 0 )+$( [ -n "$R3WID" ] && echo 1 || echo 0 ) menu windows that actually appeared -- which is exactly why that line is not evidence"

# ---- 8. THE RULE THIS GATE KEEPS ----------------------------------------
# Same rule as tests/linux/de_mouse_chrome.sh assertion 12 and
# de_appmenu_brisk.sh assertion 15: a gate that drives the chrome by writing an
# event/pointer/keys ring is not measuring input delivery at all. Here it would
# be worse -- the whole point is that the events came off a real device.
RING_RE='/dev/wsys/[^ ]*/(event|pointer|keys)'
if grep -vE '^[[:space:]]*#' "${BASH_SOURCE[0]}" | grep -nE "$RING_RE" >/dev/null; then
    bad "THIS GATE TOUCHES AN INPUT RING BY HAND -- its clicks and keystrokes no longer prove a real device reaches the menu"
else
    ok "every click and every keystroke in this file left the host over QMP input-send-event: nothing here names an event, pointer or keys ring"
fi

# ---- THE FINDING THIS RUN TURNED UP -------------------------------------
# Reported, not failed: it is a separate defect with a separate cause, and a
# gate that goes red for somebody else's bug stops being read.
echo
echo "--- FINDING (not a failure of this gate)"
echo "    scripts/hamlinux_image.sh stages /etc by a list of FILES:"
echo "      for f in hostname hosts passwd ... hamde ...; do [ -f \"etc/\$f\" ] && install ...; done"
echo "    etc/hamde is a DIRECTORY, so [ -f ] is false and /etc/hamde/apps --"
echo "    the 27 .desktop launchers -- is on NO hamnix-linux machine. Both menus"
echo "    therefore fall back to hamappmenu's built-in _seed_fallback() list, in"
echo "    which 8 of the 11 entries name programs that are not installed"
echo "    (/bin/calculator, /bin/hamterm, /bin/hamedit, /bin/hamview,"
echo "    /bin/hambrowse, /bin/hammonscene, /bin/hamctl, /bin/hamvideoscene,"
echo "    /bin/hamaudioscene). What the guest found:"
echo "      $(awk -v m="CATALOGUE-NEW:" 'index($0,m){i=1;next} i&&NF>0{printf "%s ", $0} i&&n++>3{exit}' "$WORK/boot.new.log" | tr -d '\r')"
echo "    Clicking one of those eight is a menu entry that does nothing. This"
echo "    gate launches Files (/bin/hamfm), one of the three that are real."
echo
echo "--- FINDING 2 (not a failure of this gate)"
echo "    \`ls\` GIVEN A REGULAR FILE PRINTS ITS CONTENTS. The first run of this"
echo "    gate used \`ls -l /bin/hamappmenu\` as a probe and put 450 KB of ELF on"
echo "    the serial console, three times. Measured on the host with the image's"
echo "    own binary: build/image/root/bin/ls -l <file> cats the file, exit 0."

echo
echo "realboot: $pass passed, $fail failed"
echo "(logs: $WORK/boot.{new,old}.log; screendumps + PNGs: $SHOT)"
[ "$fail" = 0 ]
