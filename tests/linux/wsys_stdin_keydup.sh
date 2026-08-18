#!/usr/bin/env bash
#
# REGISTRATION. This gate IS in scripts/ci_battery_manifest.txt: no QEMU, no
# display, MEASURED 37 s on this host (three wsysd runs, each with a settle
# before its inputs arrive -- see the note on the flake below).
#
# tests/linux/wsys_stdin_keydup.sh — ONE KEYSTROKE MUST PUT ONE BYTE ON THE
# FOCUSED WINDOW'S RING, NOT TWO.
#
# THE DEFECT, AND IT WAS MEASURED IN A GUEST BEFORE THIS FILE EXISTED
# ===================================================================
# HANDOFF.md carried an open report for a day: "how ONE Return produced TWO
# _goto_next() calls is not established". Ruled out before this: keystroke
# doubling (27 ink per character in a text field, one press one character), a
# second handle_key call site, a second Enter keymap entry, a press/release
# pair. All of those were right, and none of them was the cause.
#
# MEASURED, 2026-08-18, in a QEMU guest booting the shipped installer medium,
# with user/haminstallui.ad temporarily printing the RAW BYTES of every read of
# its /keys (evidence: ~/.hamnix-build/keyraw-evidence-prefix/). One Return on
# the wizard's summary page produced ONE read of TEN bytes:
#
#     [keyraw] READ nbytes=10
#     [keyraw] READ bytes: 100 32 49 48 10 100 32 49 48 10     ("d 10\nd 10\n")
#     [keyraw] LINE bytes: 100 32 49 48   -> GOTO_NEXT called on page=4
#     [keyraw] LINE bytes: 100 32 49 48   -> GOTO_NEXT called on page=4
#
# TWO LINES, IN ONE READ, AND BOTH CARRY CODE 10. The standing hypothesis was
# that one line carried 10 and the other 13 (haminstallui treats both as Next);
# that is DEAD -- both are 10.
#
# WHERE THE SECOND ONE CAME FROM. user/wsysd.ad was instrumented at the same
# time to print every byte it ROUTES and the source that produced it:
#
#     wsysd: routekey src=evdev code=10 wid=5
#     wsysd: routekey src=stdin code=10 wid=5
#
# `etc/rc.d/rc.5.linux` starts the compositor as
# `/bin/wsysd > /var/log/wsysd.log &` -- stdout redirected, STDIN NOT -- so fd
# 0 is /dev/console, and the shipped kernel command line ends `console=tty0`,
# the SAME virtual terminal the evdev keyboard feeds. pump_keyboard() read that
# tty and routed every byte as a keystroke. So every key reached the focused
# window twice: once decoded from evdev, once cooked by the VT line discipline.
#
# AND IT IS WORSE THAN A DOUBLED RETURN, because the tty is CANONICAL: it holds
# a line until a newline and then releases the WHOLE LINE. Measured in the same
# guest, one Return after typing `dave` into a field routed SIX bytes --
# 10, then 100 97 118 101 10 -- and the screenshot shows the four characters
# `dave` sitting in the NEXT page's PASSWORD field, with the trailing newline
# trying to advance the wizard a second time. That is also why the ink
# measurement could not see it: a printable key with no Return after it is
# still inside the tty's line buffer, so one press really is one character.
#
# THE FIX. user/wsysd.ad's decide_stdin_keys(): stdin is a keyboard ONLY when
# no evdev node could be opened -- the headless serial boot pump_keyboard was
# written for. HAMWSYSD_STDIN_KEYS forces it either way.
#
# WHAT THIS GATE ASSERTS, AND WHY EACH ARM IS HERE
# ================================================
#   GREEN  evdev node present. A KEY_A record must arrive at the window as
#          `d 97`; a byte written on fd 0 must NOT arrive at all.
#   RED    the same run with HAMWSYSD_STDIN_KEYS=1, which restores the old
#          behaviour. The stdin byte MUST arrive. This is the negative control
#          and it is RUN: without it "the stdin byte did not arrive" is
#          satisfied by an instrument that cannot deliver a stdin byte at all,
#          which is the shape this tree has been burned by repeatedly.
#   SERIAL no evdev node could be opened (wsysd is named a path that does not
#          exist, so n_input is 0 and NOTHING on this host's /dev/input is ever
#          touched). The stdin byte MUST arrive -- the headless serial console
#          is still a keyboard, which is the behaviour the fix must not break.
#
# THE WINDOW IS THE WITNESS. Only a window's owner may hold its keystroke
# channel (THE KEYSTROKE CHANNEL, user/linux-wsys.c), so tests/linux/
# wsys_zclient.ad prints what it received and a separate reader is not
# possible -- that is the point of the channel.
#
# Offscreen (HAMFB_FILE) in a private namespace. It never opens this host's
# input devices, its display, or its sound hardware.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

. tests/linux/private_ns.sh
priv_ns_reexec "$@"

. tests/linux/reap.sh

WORK="$(mktemp -d)"
reap_track "$WORK/reaped"
cleanup() { rm -rf "$WORK"; }
reap_on_exit cleanup

export HAMWSYS="$WORK/wsys.shm"
export HAMFB_FILE="$WORK/fb.raw"
export HAMFB_GEOM=800x600
export HAMWSYS_BB="$WORK/wsys.bb"
[ -r /usr/share/vulkan/icd.d/lvp_icd.json ] && \
    export VK_ICD_FILENAMES="${VK_ICD_FILENAMES:-/usr/share/vulkan/icd.d/lvp_icd.json}"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "ok   $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL $1"; }

for t in wsysd:user/wsysd.ad zclient:tests/linux/wsys_zclient.ad; do
    name="${t%%:*}"; src="${t#*:}"
    scripts/hamlinux_build.sh "$src" "$WORK/$name.elf" >/dev/null 2>&1 || {
        echo "FAIL could not build $src" >&2; exit 1; }
done

# THE PREMISE, RE-GREPPED. If the compositor stops reading fd 0 as keys at all
# this gate is measuring nothing, and it should say so rather than go green.
grep -q 'def pump_keyboard' user/wsysd.ad \
    && ok "user/wsysd.ad still has a pump_keyboard() -- the stdin key path this gate is about still exists" \
    || bad "user/wsysd.ad has no pump_keyboard() -- the path under test is gone and every result below is vacuous"

# ONE KEY_A PRESS AND RELEASE. Byte-identical to what an evdev node delivers.
python3 - "$WORK/events.bin" <<'PY'
import struct, sys
def ev(t, c, v):
    return struct.pack('<qqHHi', 0, 0, t, c, v)
out  = ev(1, 30, 1)          # EV_KEY KEY_A press   -> 'a' = 97
out += ev(1, 30, 0)          # release
out += ev(0, 0, 0)           # EV_SYN
open(sys.argv[1], 'wb').write(out)
PY

# BOTH INPUTS ARRIVE LATE, AND THAT IS NOT A DETAIL. route_key() drops a byte
# when focus_wid < 2, and focus is not settled the instant the compositor
# starts -- the client still has to map its window. THE FIRST VERSION OF THIS
# GATE HANDED wsysd A FILE THAT ALREADY HELD THE RECORDS AND A STDIN THAT
# ALREADY HELD THE BYTE, AND IT FLAKED: the same DEFECT arm scored 6/2 and then
# 5/3 on consecutive runs, and on the second the GREEN arm's "the stdin byte
# was not routed" PASSED AGAINST THE DEFECT, because the byte had been read and
# dropped before any window existed. A negative that a race can satisfy is not
# an assertion. So the evdev file starts EMPTY and is appended to after the
# compositor has settled, and stdin is a FIFO written after the same settle.
: >"$WORK/events.empty"

# run_arm <tag> EVDEV|<path> [env=val ...] -- one wsysd, one window, one read
# of the window's own log. Returns the log path in ARM_LOG.
ARM_LOG=""
run_arm() {
    local tag="$1" inpath="$2"; shift 2
    local d="$WORK/$tag"
    mkdir -p "$d"
    export HAMWSYS="$d/wsys.shm" HAMFB_FILE="$d/fb.raw" HAMWSYS_BB="$d/wsys.bb"
    rm -f "$d/stdin.fifo"; mkfifo "$d/stdin.fifo"
    # A writer must hold the FIFO open before wsysd's `<fifo` can complete, and
    # it must not close it -- a closed writer is EOF, and EOF on fd 0 is not
    # what a console is.
    ( exec 3>"$d/stdin.fifo"; sleep 4; printf 'b\n' >&3; sleep 25 ) &
    reap_add $!
    # ONE window, DECORATED -- pick_focus() skips undecorated windows entirely,
    # and an unfocused window receives nothing whatever the fix does, which
    # would make every "it did not arrive" true for the wrong reason.
    "$WORK/zclient.elf" 100 60 300 200 6 3366AA "$tag" 18 1 >"$d/win.log" 2>&1 &
    reap_add $!
    sleep 1
    cp "$WORK/events.empty" "$d/events.bin"
    local realin="$inpath"
    [ "$inpath" = EVDEV ] && realin="$d/events.bin"
    ( for kv in "$@"; do export "$kv"; done
      exec timeout 16 "$WORK/wsysd.elf" "$realin" <"$d/stdin.fifo" ) \
        >"$d/wsysd.log" 2>&1 &
    reap_add $!
    sleep 3
    # NOW the records, with a window mapped and focused.
    cat "$WORK/events.bin" >>"$d/events.bin"
    sleep 6
    ARM_LOG="$d/win.log"
}

say_arm() { echo; echo "== $1"; }

###########################################################################
say_arm "GREEN -- an evdev node is open, so fd 0 is a duplicate of it"
###########################################################################
run_arm green EVDEV
G="$ARM_LOG"
if grep -q 'wsys_zclient: keys .*d 97' "$G"; then
    ok "the evdev KEY_A reached the focused window as 'd 97' -- the channel under test is live in this arm"
else
    bad "the evdev KEY_A did NOT reach the window; nothing below this line is a measurement about stdin"
    sed 's/^/    /' "$G"
fi
if grep -q 'wsys_zclient: keys .*d 98' "$G"; then
    bad "the byte on fd 0 was routed to the window as a keystroke -- one physical key still delivers two"
    sed 's/^/    /' "$G"
else
    ok "the byte on fd 0 was NOT routed -- the console tty is no longer a second keyboard while an evdev node is open"
fi

###########################################################################
say_arm "RED (the negative control, RUN) -- HAMWSYSD_STDIN_KEYS=1 puts it back"
###########################################################################
run_arm red EVDEV HAMWSYSD_STDIN_KEYS=1
R="$ARM_LOG"
if grep -q 'wsys_zclient: keys .*d 97' "$R"; then
    ok "the evdev KEY_A still arrives with the escape set"
else
    bad "the evdev KEY_A did not arrive in the red arm -- the arm is broken, not the escape"
    sed 's/^/    /' "$R"
fi
if grep -q 'wsys_zclient: keys .*d 98' "$R"; then
    ok "AND THE STDIN BYTE ARRIVES: the defect reproduces on demand, so 'it did not arrive' above is an assertion and not an instrument that cannot see a stdin byte"
else
    bad "the stdin byte did not arrive even with HAMWSYSD_STDIN_KEYS=1 -- this instrument CANNOT deliver a stdin byte, so the GREEN arm's negative proves nothing. Withdraw it."
    sed 's/^/    /' "$R"
    echo "--- wsysd said:"; sed 's/^/    /' "$WORK/red/wsysd.log"
fi

###########################################################################
say_arm "SERIAL -- no evdev node could be opened, so fd 0 is the only keyboard"
###########################################################################
# The path does not exist, so open_input_path() fails and n_input stays 0.
# NOTHING under this host's /dev/input is opened by this arm or any other.
run_arm serial "$WORK/no-such-input-node"
S="$ARM_LOG"
if grep -q 'wsys_zclient: keys .*d 98' "$S"; then
    ok "with zero evdev nodes the stdin byte IS routed -- a headless serial boot still has a keyboard, which the fix must not take away"
else
    bad "with zero evdev nodes the stdin byte was not routed -- the fix has removed the serial console's keyboard"
    sed 's/^/    /' "$S"
    echo "--- wsysd said:"; sed 's/^/    /' "$WORK/serial/wsysd.log"
fi
if grep -q 'stdin as a keyboard: 1' "$WORK/serial/wsysd.log"; then
    ok "and the compositor SAYS which it chose, on its own log line, rather than leaving it to be inferred"
else
    bad "the compositor did not report its stdin decision"
    sed 's/^/    /' "$WORK/serial/wsysd.log"
fi
if grep -q 'stdin as a keyboard: 0' "$WORK/green/wsysd.log"; then
    ok "and it reported the opposite decision in the GREEN arm, from the same line"
else
    bad "the GREEN arm did not report 'stdin as a keyboard: 0'"
    sed 's/^/    /' "$WORK/green/wsysd.log"
fi

echo
echo "$PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
