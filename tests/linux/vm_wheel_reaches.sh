#!/usr/bin/env bash
# tests/linux/vm_wheel_reaches.sh — DOES A SCROLL WHEEL REACH THE COMPOSITOR
# INSIDE A VM AT ALL?
#
# WHY THIS EXISTS SEPARATELY FROM tests/linux/wsyswl_wheel.sh. That gate proves
# the compositor's half: a file of evdev records reaches an X client as button
# 4/5, offscreen, with a real Xwayland. It passes. The wheel STILL does nothing
# to Steam in a VM, and there are two entirely different reasons that could be
# true:
#
#   (a) QEMU's virtio-tablet never delivers REL_WHEEL to the guest, so no
#       wheel event exists to route -- nothing in this tree is wrong; or
#   (b) it does, and something between /dev/input/eventN and the client drops
#       it -- ours.
#
# Nothing about "the page did not scroll" distinguishes those, and guessing
# between them is how a whole pass gets spent on the wrong half.
#
# THE MEASUREMENT. `wsysd` publishes `/dev/wsys/wsysd/state`, whose `pointer`
# field counts `deliver_pointer` calls -- and `deliver_pointer` returns early
# unless something changed, INCLUDING a non-zero `ptr_dz`. So with the cursor
# held still, a rise in `pointer` across a burst of wheel events means wsysd
# saw the wheel; a flat `pointer` means it never arrived on any evdev node it
# has open. The state is asked for at the guest console, which is reliable
# HERE because there is no Steam writing to the same serial line -- the
# character-dropping in docs/steam_namespace.md §12.3 is a property of a busy
# console, and this one is idle.
#
# The control is in the same run: a plain MOVE, on the same devices, through
# the same counter. A dead pointer would otherwise read exactly like a dead
# wheel.
#
# No Steam, no namespace: the desktop alone, so this is ~2 minutes.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

WORK="${VMW_WORK:-$HOME/.hamnix-build/steamdrive/vmwheel}"
IMG=build/image
QMP="$IMG/qmp.sock"
LOG="$WORK/console.log"
mkdir -p "$WORK"
export HAMLINUX_DISTRO_RO=1 HAMLINUX_VNC=none
export TMPDIR="${TMPDIR:-$HOME/.hamnix-build/tmp}"
mkdir -p "$TMPDIR"

pass=0; fail=0
ok()   { echo "vmwheel: PASS $*"; pass=$((pass+1)); }
bad()  { echo "vmwheel: FAIL $*"; fail=$((fail+1)); }
info() { echo "vmwheel: INFO $*"; }

cat > "$WORK/rc.boot" <<'RC'
echo 'rc.boot: hamnix-linux starting'
ln -s /dev/console /dev/cons
ln -s /proc/self/fd /dev/fd
ln -s /proc/self/fd/0 /dev/stdin
ln -s /proc/self/fd/1 /dev/stdout
ln -s /proc/self/fd/2 /dev/stderr
mkdir /dev/shm
bind '#t' /dev/shm
source '/etc/rc.d/rc.5'
sleep 3
echo '[vmwheel] the desktop is up'
# THE STATE GOES ON THE SERIAL LINE BY ITSELF, and the console is not used at
# all. Two reasons, both measured: hamsh's console line editor echoes about
# one character per second here, and worse, it only ADVANCES when more input
# arrives -- on an idle system a typed line stalls half-finished for ever.
#
# TWO PIECES OF hamsh SYNTAX, both found by running the shell on the HOST
# against a scratch script rather than by another eight-minute VM round trip:
# `while 1 { }` is a parse error (the loop that works is `for VAR in WORDS`),
# and `spawn detached { }` is one too -- `spawn` wants a NAMESPACE, which is
# what `ns { }` describes and what every caller in /etc/rc.d/rc.5 passes.
# 40 iterations at 5 s is longer than this run.
stateloop = ns {
}
spawn detached stateloop {
    for i in a b c d e f g h i j k l m n o p q r s t u v w x y z 1 2 3 4 5 6 7 8 9 0 A B C D {
        echo -n 'VMWHEEL '
        cat /dev/wsys/wsysd/state
        sleep 5
    }
}
RC

if [ "${VMW_SKIP_BUILD:-0}" = 1 ] && [ -f "$IMG/initramfs.cpio.gz" ]; then
    info "reusing the staged initramfs (VMW_SKIP_BUILD=1)"
else
    echo "[vmwheel] staging the initramfs"
    HAMLINUX_RC="$WORK/rc.boot" scripts/hamlinux_image.sh > "$WORK/build.log" 2>&1 || {
        bad "image build"; tail -20 "$WORK/build.log"; exit 1; }
fi

rm -f "$QMP" "$LOG"
( timeout 600 scripts/hamlinux_vm.sh script -qmp "unix:$QMP,server,nowait" \
    </dev/null > "$LOG" 2>&1 ) &
VM=$!
cleanup() {
    python3 tests/linux/qmp_input.py "$QMP" quit >/dev/null 2>&1
    sleep 1; kill "$VM" 2>/dev/null; sleep 1; kill -9 "$VM" 2>/dev/null
}
trap cleanup EXIT
for _ in $(seq 1 150); do [ -S "$QMP" ] && break; sleep 0.2; done
[ -S "$QMP" ] || { bad "the VM never opened its QMP socket"; exit 1; }

Q() { python3 tests/linux/qmp_input.py "$QMP" "$@" >/dev/null 2>&1; }
# WAIT FOR A NEW LINE, never for a number of seconds. rc.boot publishes the
# state every 5 s on the serial console by itself -- nothing is typed at the
# guest, because hamsh's line editor echoes about one character per second
# here and, worse, only advances when more input arrives, so on an idle
# system a typed line stalls half-finished for ever (measured; the first two
# attempts at this file died there). A fixed sleep would read the PREVIOUS
# answer back and report every counter unchanged, which is the exact shape of
# the failure this file exists to rule out. Two fresh lines, so the one being
# read was published entirely after the events were sent.
nstates() { grep -ac VMWHEEL "$LOG" 2>/dev/null | head -1; }
settle() {
    local before; before="$(nstates)"
    for _ in $(seq 1 60); do
        [ "$(nstates)" -gt $((before + 1)) ] && return 0
        sleep 2
    done
    return 1
}
ptrcount() { sed -n 's/.*VMWHEEL .*pointer \([0-9]*\) .*/\1/p' "$LOG" | tail -1; }

for _ in $(seq 1 80); do [ -n "$(ptrcount)" ] && break; sleep 3; done
P0="$(ptrcount)"
if [ -z "$P0" ]; then
    bad "wsysd never published a state line -- the desktop did not come up"
    tail -25 "$LOG"; exit 1
fi
ok "the desktop is up and publishing its own state (pointer $P0)"

# ---- CONTROL: a plain MOVE ----------------------------------------------
Q move 400 300 1280 800; sleep 1
Q move 600 500 1280 800
settle
P1="$(ptrcount)"
if [ "${P1:-0}" -gt "${P0:-0}" ]; then
    ok "CONTROL: a QEMU pointer MOVE reaches wsysd (pointer $P0 -> $P1)"
else
    bad "CONTROL: a QEMU pointer move does not reach wsysd at all (pointer $P0 -> ${P1:-?}) -- this run cannot say anything about the wheel"
    tail -25 "$LOG"; exit 1
fi

# ---- THE WHEEL, with the cursor held still ------------------------------
Q wheel down 10; sleep 2
Q wheel up 10
settle
P2="$(ptrcount)"
if [ "${P2:-0}" -gt "${P1:-0}" ]; then
    ok "TWENTY WHEEL EVENTS REACH wsysd with the cursor still (pointer $P1 -> $P2) -- QEMU's virtio-tablet does deliver REL_WHEEL, so a wheel that does nothing is ours"
else
    bad "QEMU's wheel never reaches wsysd (pointer $P1 -> ${P2:-?} across 20 events, cursor still). The virtio-tablet is not delivering REL_WHEEL to this guest -- nothing between /dev/input and the client can be blamed for a scroll that does not happen in a VM"
fi
info "last state line: $(grep -a VMWHEEL "$LOG" | tail -1)"
echo "vmwheel: $pass passed, $fail failed"
[ "$fail" = 0 ]
