#!/usr/bin/env bash
# tests/linux/vm_wheel_client.sh — DOES THE WHEEL REACH AN X CLIENT **IN THE VM**?
#
# WHY A THIRD WHEEL TEST. There are two already and neither can answer this:
#
#   * `tests/linux/wsyswl_wheel.sh` drives a FILE of evdev records into wsysd
#     on the dev host, offscreen, and proves the whole compositor half --
#     against the namespace's own Xwayland 22.1.9 as well as the host's 24.1.6,
#     on the core path and the XInput2 smooth-scroll path. 30 PASS.
#   * `tests/linux/vm_wheel_reaches.sh` boots a VM and proves QEMU's
#     virtio-tablet delivers `REL_WHEEL` into the guest: wsysd's own `pointer`
#     counter goes 2 -> 22 across twenty wheel events with the cursor held
#     still. Exactly twenty.
#
# Both are green, and the wheel still did nothing to Steam's store page in a
# VM: eight notches, `IDENTICAL (0 of 564400 px)`, with a scrollbar DRAG of the
# same page by the same pointer in the same run moving 96.44% of it
# (docs/steam_namespace.md §12.2a). So the two green tests meet in the middle
# and the gap between them -- QEMU's evdev node -> wsysd -> wsyswl -> the
# namespace's Xwayland -> an X client, all inside one VM -- is the only stretch
# nothing measures. This file measures exactly that stretch. No Steam and no
# CEF: two ordinary programs out of the namespace's own /usr/bin, asked the two
# questions that are not the same question.
#
#   1. `xev -root` -- WHAT DID THE X SERVER DELIVER? `-root` because the
#      position of the Xwayland window on the Hamnix screen is wsysd's business
#      and not a thing this test should have to predict: the whole X screen is
#      the target, so any point inside it works.
#   2. `xterm` with 3000 lines of scrollback -- DID A PROGRAM ACTUALLY SCROLL?
#      Answered in PIXELS, off QEMU's own screendump. This is the part that
#      matters, and the reason it is here is that for three passes the answer to
#      1 was yes and the answer to 2 was no, and only 1 was being asked.
#
# THE CONTROL IS IN THE SAME RUN AND THE SAME LOG. A plain pointer MOVE must
# arrive as `MotionNotify` before "no ButtonPress" is allowed to mean anything.
# Without it a pointer that never reached the window at all reads exactly like
# a dead wheel -- which is the failure this whole family of tests exists to
# stop being confused with.
#
# SYNCHRONISATION IS THE GUEST'S, not a sleep. rc.boot prints its own markers
# on the serial console and this script waits for each one before it drives
# anything, because a fixed sleep reads the log from BEFORE the events and
# reports every counter unchanged -- which is the shape of the answer this file
# must never give.
#
# ~4 minutes. HAMLINUX_DISTRO_RO=1: the distro medium is attached snapshot=on,
# so nothing the guest writes survives and any number of these can run at once.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

WORK="${VMWC_WORK:-$HOME/.hamnix-build/vmwheelclient}"
IMG=build/image
QMP="$IMG/qmpwc.sock"
LOG="$WORK/console.log"
mkdir -p "$WORK"
export HAMLINUX_DISTRO_RO=1 HAMLINUX_VNC=none
export TMPDIR="${TMPDIR:-$HOME/.hamnix-build/tmp}"
mkdir -p "$TMPDIR"

NSNAME="${VMWC_DISTRO:-debian}"
# WHERE THE POINTER IS AIMED, in HAMNIX SCREEN pixels. Two different targets:
#   AIMX/AIMY   bare X root, clear of the xterm -- where `xev -root` is asked
#               whether button 4/5 arrives at all.
#   XTX/XTY     inside the xterm, where the wheel is asked to move pixels.
# The xterm is placed at the X screen's top-left (+0+0, 90x30) so both are
# known without having to predict where wsysd put the Xwayland window.
AIMX="${VMWC_AIMX:-900}"
AIMY="${VMWC_AIMY:-600}"
XTX="${VMWC_XTX:-250}"
XTY="${VMWC_XTY:-200}"
# THE RECTANGLE DIFFED, and picking it is not a formality. `seq 1 3000` writes
# four-digit numbers in the leftmost ~45 pixels of the xterm and leaves the rest
# of an 90x30 window blank white -- so the first version of this test diffed
# 400x240 of that blank area, measured `0 of 96000` while the terminal behind it
# scrolled perfectly, and would have reported the bug it was written to rule
# out. The rectangle is the COLUMN OF DIGITS. It also excludes the block cursor
# on the last line (which blinks) and the scrollbar (which moves for reasons
# other than the wheel).
# The xterm is at X +0+0; wsysd puts the Xwayland window at about screen (8,25),
# which is where these numbers come from.
RX="${VMWC_RX:-10}"; RY="${VMWC_RY:-40}"; RW="${VMWC_RW:-48}"; RH="${VMWC_RH:-330}"

pass=0; fail=0
ok()   { echo "vmwc: PASS $*"; pass=$((pass+1)); }
bad()  { echo "vmwc: FAIL $*"; fail=$((fail+1)); }
info() { echo "vmwc: INFO $*"; }
done_report() { echo "vmwc: $pass passed, $fail failed"; [ "$fail" = 0 ]; }

cat > "$WORK/rc.boot" <<RC
echo 'rc.boot: hamnix-linux starting'
ln -s /dev/console /dev/cons
ln -s /proc/self/fd /dev/fd
ln -s /proc/self/fd/0 /dev/stdin
ln -s /proc/self/fd/1 /dev/stdout
ln -s /proc/self/fd/2 /dev/stderr
mkdir /dev/shm
bind '#t' /dev/shm

source '/etc/rc.distros'
source '/etc/rc.d/rc.5'
sleep 5
echo '[vmwc] the desktop is up'

# The X client, in the namespace, through the SAME shim the application menu
# uses -- so this is the session a person gets, not a special one built for a
# test. Its stdout and stderr land in /tmp/de-ns-run.log INSIDE the tree, which
# is /n/$NSNAME/tmp/de-ns-run.log from out here.
echo '[vmwc] launching xev -root in the $NSNAME namespace'
spawn $NSNAME { /bin/sh /etc/de-ns-run xev -root }
sleep 25
# AND A CLIENT WITH PIXELS. "the X server delivered button 5" and "a program
# scrolled" are different claims, and the whole reason this bug took four
# passes is that the first was true while the second was not. xterm with a
# scrollbar and 3000 lines behind it is the cheapest program in this image that
# turns a wheel notch into a changed framebuffer -- and the framebuffer is what
# a person looking at the machine sees. It reuses the X server the line above
# started; de-ns-run says so ("an X server is already on :0").
echo '[vmwc] launching xterm in the $NSNAME namespace'
spawn $NSNAME { /bin/sh /etc/de-ns-run xterm -sb -j -geometry 90x30+0+0 -e /bin/sh -c 'seq 1 3000; sleep 9999' }

# THE MARKERS ARE THE CLOCK. Nothing is typed at the guest -- hamsh's console
# line editor drops characters under load and only advances when more input
# arrives (docs/steam_namespace.md §12.3), so the guest talks and the host
# listens.
sleep 40
echo '[vmwc] --- the shim log so far'
cat /n/$NSNAME/tmp/de-ns-run.log
echo 'VMWC-READY'
sleep 30
echo 'VMWC-A-BEGIN'
cat /n/$NSNAME/tmp/de-ns-run.log
echo 'VMWC-A-END'
sleep 30
echo 'VMWC-B-BEGIN'
cat /n/$NSNAME/tmp/de-ns-run.log
echo 'VMWC-B-END'
# The pixel phase is driven entirely from the host over QMP -- screendumps and
# pointer events, nothing typed here. This sleep is the window it runs in.
sleep 100
echo '[vmwc] --- wsyswl state for $NSNAME'
cat /n/$NSNAME/run/wsyswl-state
echo '[vmwc] --- wsysd state'
cat /dev/wsys/wsysd/state
echo 'VMWC-DONE'
sleep 900
RC

if [ "${VMWC_SKIP_BUILD:-0}" = 1 ] && [ -f "$IMG/initramfs.cpio.gz" ]; then
    info "reusing the staged initramfs (VMWC_SKIP_BUILD=1)"
else
    info "staging the initramfs"
    HAMLINUX_RC="$WORK/rc.boot" scripts/hamlinux_image.sh > "$WORK/build.log" 2>&1 || {
        bad "image build"; tail -20 "$WORK/build.log"; done_report; exit 1; }
fi

rm -f "$QMP" "$LOG"
( timeout 900 scripts/hamlinux_vm.sh script -qmp "unix:$QMP,server,nowait" \
    </dev/null > "$LOG" 2>&1 ) &
VM=$!
cleanup() {
    python3 tests/linux/qmp_input.py "$QMP" quit >/dev/null 2>&1
    sleep 1; kill "$VM" 2>/dev/null; sleep 1; kill -9 "$VM" 2>/dev/null
}
trap cleanup EXIT
for _ in $(seq 1 150); do [ -S "$QMP" ] && break; sleep 0.2; done
[ -S "$QMP" ] || { bad "the VM never opened its QMP socket"; done_report; exit 1; }

Q() { python3 tests/linux/qmp_input.py "$QMP" "$@" >/dev/null 2>&1; }
waitfor() {                      # waitfor <marker> <tries>
    local m="$1" n="${2:-150}" _
    for _ in $(seq 1 "$n"); do
        grep -aq "$m" "$LOG" && return 0
        kill -0 "$VM" 2>/dev/null || return 1
        sleep 2
    done
    return 1
}
# ButtonPress on a given button, out of one slice of the console log. xev
# prints the number on the `state 0x0, button 5, ...` line two lines below the
# `ButtonPress event` header, so the two cannot be matched on one line and a
# bare count of "button 5," counts the RELEASE too and doubles everything.
btn() {                          # btn <slice-file> <button>
    awk -v b="$2" '
        /ButtonPress event/ { p = 1; next }
        /button [0-9]+,/    { if (p && $0 ~ ("button " b ",")) n++; p = 0 }
        END                 { print n + 0 }' "$1"
}
slice() {                        # slice <begin> <end> -> stdout
    sed -n "/$1/,/$2/p" "$LOG"
}

waitfor 'VMWC-READY' 240 || { bad "the X session never came up in the namespace"
    info "the last of the console:"; tail -40 "$LOG"; done_report; exit 1; }
ok "the desktop booted and the $NSNAME X session started"
info "the shim said:"
sed -n '/--- the shim log so far/,/VMWC-READY/p' "$LOG" | sed 's/^/vmwc:      /' | head -30

# ---- CONTROL: a plain MOVE ----------------------------------------------
Q move "$AIMX" "$AIMY" 1280 800; sleep 1
Q move $((AIMX + 30)) $((AIMY + 20)) 1280 800; sleep 1
Q move $((AIMX + 60)) $((AIMY + 40)) 1280 800
waitfor 'VMWC-A-END' 60 || { bad "the guest stopped talking before the first log slice"
    tail -30 "$LOG"; done_report; exit 1; }
slice VMWC-A-BEGIN VMWC-A-END > "$WORK/a.log"
MA="$(grep -ac MotionNotify "$WORK/a.log" | head -1)"
if [ "${MA:-0}" -gt 0 ]; then
    ok "CONTROL: a QEMU pointer MOVE reaches the X client in the namespace ($MA MotionNotify)"
else
    bad "CONTROL: the X client saw NO MotionNotify -- the pointer never reached the Xwayland window at ${AIMX},${AIMY}, so this run cannot say anything about the wheel. Set VMWC_AIMX/VMWC_AIMY."
    info "what the client did print:"; sed 's/^/vmwc:      /' "$WORK/a.log" | tail -20
    done_report; exit 1
fi

# ---- THE WHEEL, with the cursor held still ------------------------------
DA5="$(btn "$WORK/a.log" 5)"; DA4="$(btn "$WORK/a.log" 4)"
Q wheel down 6; sleep 2
Q wheel up 4
waitfor 'VMWC-B-END' 60 || { bad "the guest stopped talking before the second log slice"
    tail -30 "$LOG"; done_report; exit 1; }
slice VMWC-B-BEGIN VMWC-B-END > "$WORK/b.log"
DB5="$(btn "$WORK/b.log" 5)"; DB4="$(btn "$WORK/b.log" 4)"
MB="$(grep -ac MotionNotify "$WORK/b.log" | head -1)"
info "MotionNotify $MA -> $MB, button-5 presses $DA5 -> $DB5, button-4 $DA4 -> $DB4"

if [ "$((DB5 - DA5))" -gt 0 ]; then
    ok "SIX WHEEL-DOWN NOTCHES REACH THE X CLIENT AS BUTTON 5 in a real VM ($DA5 -> $DB5)"
else
    bad "THE DEFECT, IN THE VM: six QEMU wheel-down events, the pointer demonstrably live over the same window, and the X client got NO button 5. wsysd sees the wheel (tests/linux/vm_wheel_reaches.sh) and the compositor delivers it offscreen (tests/linux/wsyswl_wheel.sh); it is lost between them, in the VM only."
fi
if [ "$((DB4 - DA4))" -gt 0 ]; then
    ok "and four wheel-UP notches reach it as button 4 ($DA4 -> $DB4)"
else
    bad "wheel UP produced no button 4 in the VM ($DA4 -> $DB4)"
fi
if [ "$((DB5 - DA5))" = 6 ] && [ "$((DB4 - DA4))" = 4 ]; then
    ok "and the COUNTS are exact: six down, four up"
else
    info "counts are not exact (six down / four up expected, got $((DB5 - DA5)) / $((DB4 - DA4))) -- QEMU coalescing, not necessarily a defect"
fi

# ---- AND DOES A REAL PROGRAM ACTUALLY SCROLL? ---------------------------
# THE LESSON THIS BUG ALREADY TAUGHT ONCE, written into the file so it cannot
# be forgotten again: a green protocol assertion is necessary and not
# sufficient. "the X server delivered button 5" was true for three passes while
# the page on the screen did not move by one pixel. So the last word here is
# the framebuffer.
#
# THE CONTROL IS THE REVERSAL, and it is stronger than a scrollbar drag: the
# wheel is run UP and then back DOWN, and the third screendump must return to
# the first. Noise, a repaint, a cursor blink or a clock ticking can make two
# screendumps differ; nothing but the content actually scrolling and scrolling
# back makes A != B, B != C and A == C.
#
# UP FIRST, AND THAT IS NOT A PREFERENCE. `seq 1 3000` leaves the terminal
# already at the BOTTOM of its scrollback, so a wheel DOWN there is a correctly
# working wheel with nowhere to go -- and the first run of this test measured
# `0 of 15840` for wheel-down and reported the defect it exists to rule out,
# against a terminal that scrolled the moment it was asked to scroll UP. A test
# whose subject has no room to move in the direction it is pushed answers
# something that looks exactly like the bug.
PPMA="$WORK/a.ppm"; PPMB="$WORK/b.ppm"; PPMC="$WORK/c.ppm"
pix() { python3 tests/linux/ppmdiff.py "$@" 2>/dev/null; }
# ppmdiff prints EITHER "...: IDENTICAL (0 of N px)" OR "...: M of N px (..%)",
# and a regex that only knows the second returns the EMPTY STRING for a
# perfectly good zero -- which then reads as "no measurement" in one place and
# as 0 in another. Take the number that precedes " of ", whichever line it is on.
ndiff() {
    pix diff "$1" "$2" "$RX" "$RY" "$RW" "$RH" |
        sed -n 's/.*[ (]\([0-9][0-9]*\) of [0-9].*/\1/p' | head -1
}

Q move "$XTX" "$XTY" 1280 800; sleep 2
Q screendump "$PPMA" >/dev/null 2>&1
sleep 1
if [ ! -s "$PPMA" ]; then
    bad "no screendump came back over QMP -- the pixel half of this test cannot run"
else
    NCOL="$(pix rect "$PPMA" "$RX" "$RY" "$RW" "$RH" | head -1)"
    info "the rectangle before anything: $NCOL"
    Q wheel up 8; sleep 3
    Q screendump "$PPMB" >/dev/null 2>&1; sleep 1
    Q wheel down 8; sleep 3
    Q screendump "$PPMC" >/dev/null 2>&1; sleep 1
    DAB="$(ndiff "$PPMA" "$PPMB")"; DBC="$(ndiff "$PPMB" "$PPMC")"
    DAC="$(ndiff "$PPMA" "$PPMC")"
    TOT=$((RW * RH))
    info "pixels changed in ${RW}x${RH}+${RX}+${RY} of $TOT: up ${DAB:-?}, back down ${DBC:-?}, net ${DAC:-?}"
    if [ "${DAB:-0}" -gt $((TOT / 100)) ]; then
        ok "EIGHT WHEEL-UP NOTCHES MOVED THE PIXELS OF A REAL PROGRAM: $DAB of $TOT changed"
    else
        bad "eight wheel-up notches changed ${DAB:-0} of $TOT pixels -- the X server delivers button 4/5 (above) and the program on the screen does not move"
    fi
    if [ "${DBC:-0}" -gt $((TOT / 100)) ]; then
        ok "CONTROL: eight notches back DOWN moved them again ($DBC of $TOT) -- it is the wheel doing this, in both directions"
    else
        bad "the wheel scrolled up and would not scroll back down ($DBC of $TOT)"
    fi
    # ONLY MEANINGFUL IF SOMETHING MOVED. "it came back to where it started" is
    # trivially true of a screen that never left, so with the axis emission
    # stashed this read PASS in the middle of four FAILs -- an assertion that is
    # green precisely when the feature is dead. It is gated on the scroll having
    # happened, and says so by name when it did not.
    if [ "${DAB:-0}" -le $((TOT / 100)) ]; then
        info "not asserting the return-to-start: nothing scrolled in the first place"
    elif [ "${DAC:-0}" -lt $((TOT / 100)) ]; then
        ok "and the screen RETURNED to where it started (${DAC} of $TOT differ) -- up eight and down eight is the same place, so this is scrolling and not noise"
    else
        info "up-8 then down-8 did not land exactly back (${DAC} of $TOT differ) -- a cursor, a clock or a half-page rounding, not necessarily a defect"
    fi
fi

waitfor 'VMWC-DONE' 90 || true
info "wsyswl state: $(sed -n '/--- wsyswl state/,/--- wsysd state/p' "$LOG" | tail -3 | tr '\n' ' ')"
info "wsysd state:  $(sed -n '/--- wsysd state/,/VMWC-DONE/p' "$LOG" | tail -2 | tr '\n' ' ')"
done_report
