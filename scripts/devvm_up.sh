#!/usr/bin/env bash
# scripts/devvm_up.sh — bring up ONE persistent hamnix-linux dev VM and leave
# it running, then hand back the two addresses you need to iterate against it:
# an SSH port and a host HTTP port the guest can fetch new binaries from.
#
# WHY. Every gate in tests/linux/ boots its own VM, drives it once and powers
# it off, and because they share build/image they cannot even do that in
# parallel. That is the right shape for deciding whether to ship and the wrong
# shape for changing one line of one program: it makes a thirty-second edit
# cost a full build -> boot -> power-off cycle. This script pays that cost
# ONCE and then stays up. docs/dev-loop.md has the measured numbers.
#
# WHAT IT LEAVES BEHIND, all under $DEVVM_DIR:
#   qemu.pid       the guest's pid. Stop it with scripts/devvm_down.sh, which
#                  reads this file. NEVER pkill by pattern: this box routinely
#                  runs a dozen unrelated QEMUs for other agents.
#   console.sock   the guest serial console (QEMU chardev, one client).
#   console.log    a full transcript, written by scripts/devvm_console.py.
#   console.in     a FIFO; a line written here is typed at the guest console.
#   qmp.sock       QMP, for tests/linux/qmp_input.py (real keyboard, tablet,
#                  screendumps) against an ALREADY-RUNNING guest.
#   push/          served to the guest over HTTP at 10.0.2.2:$HTTP_PORT.
#                  scripts/devvm_push.sh puts binaries here.
#   ports          the two port numbers, so later scripts need no arguments.
#
# ENV:
#   HAMLINUX_IMAGE_DIR  the staged image (REQUIRED to be a private dir; see
#                       the note in hamlinux_vm.sh about agents racing over
#                       build/image).
#   DEVVM_DIR           rundir. Default ~/.hamnix-build/devvm.
#   DEVVM_SSH_PORT      host port -> guest 22. Default: a free one.
#   DEVVM_BOOT_TIMEOUT  seconds to wait for the boot marker. Default 180.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

DEVVM_DIR="${DEVVM_DIR:-$HOME/.hamnix-build/devvm}"
IMG="${HAMLINUX_IMAGE_DIR:-build/image}"
BOOT_TIMEOUT="${DEVVM_BOOT_TIMEOUT:-180}"

[ -f "$IMG/vmlinuz" ] || {
    echo "devvm: no staged image at $IMG" >&2
    echo "devvm: run  scripts/hamlinux_image.sh <dir>  and set HAMLINUX_IMAGE_DIR" >&2
    exit 1; }

# --- refuse to start a second guest in the same rundir -------------------
# Two VMs sharing a rundir fight over console.sock and qmp.sock, and the
# loser's failure looks like a broken guest rather than a port clash. Check
# the pid AND that it is really QEMU: pids are reused, and killing or
# adopting somebody else's process because a stale pidfile pointed at it is
# exactly the class of mistake the "identify by serial, never by kernel name"
# rule exists to prevent.
if [ -f "$DEVVM_DIR/qemu.pid" ]; then
    OLD=$(cat "$DEVVM_DIR/qemu.pid" 2>/dev/null || true)
    if [ -n "$OLD" ] && [ -d "/proc/$OLD" ] &&
       grep -qa 'qemu-system' "/proc/$OLD/cmdline" 2>/dev/null; then
        echo "devvm: a dev VM is already up (pid $OLD, rundir $DEVVM_DIR)" >&2
        echo "devvm: stop it with scripts/devvm_down.sh, or set DEVVM_DIR" >&2
        exit 1
    fi
    rm -f "$DEVVM_DIR/qemu.pid"
fi

mkdir -p "$DEVVM_DIR/push"
: > "$DEVVM_DIR/console.log"

freeport() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }
SSH_PORT="${DEVVM_SSH_PORT:-$(freeport)}"
HTTP_PORT="$(freeport)"

# --- the host side of the byte pipe --------------------------------------
# The guest reaches the host at the SLIRP gateway alias 10.0.2.2. This is the
# transport the tree already uses for kernels and packages (hpm_kernel_http.sh,
# hpm_signed_refresh.sh), which is the whole reason it is the one used here:
# virtio-9p would be the Plan-9-shaped answer and it DOES work -- but only for
# the bare-metal Hamnix kernel. drivers/virtio/virtio_9p.ad is reachable from
# init/main.ad and the tests/*_smoke.ad suites; scripts/hamlinux_image.sh
# contains no 9p of any kind, so there is no 9P client on a hamnix-linux guest
# to mount with. Measured, not assumed. Bound to loopback: nothing here should
# be reachable from outside this machine.
setsid nohup python3 -m http.server "$HTTP_PORT" --bind 127.0.0.1 \
    --directory "$DEVVM_DIR/push" > "$DEVVM_DIR/http.log" 2>&1 < /dev/null &
HTTP_PID=$!
echo "$HTTP_PID" > "$DEVVM_DIR/http.pid"

cat > "$DEVVM_DIR/ports" <<EOF
DEVVM_SSH_PORT=$SSH_PORT
DEVVM_HTTP_PORT=$HTTP_PORT
DEVVM_DIR=$DEVVM_DIR
HAMLINUX_IMAGE_DIR=$IMG
EOF

# --- the guest -----------------------------------------------------------
# setsid, because a VM that dies when the thing that started it goes away is
# not persistent -- and because a battery in this tree was reaped mid-run for
# exactly this reason.
HAMLINUX_RUNDIR="$DEVVM_DIR" \
HAMLINUX_IMAGE_DIR="$IMG" \
HAMLINUX_HOSTFWD=",hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22" \
HAMLINUX_DISTRO_RO=1 \
    setsid nohup bash scripts/hamlinux_vm.sh dev \
        > "$DEVVM_DIR/qemu.log" 2>&1 < /dev/null &

# --- the console reader --------------------------------------------------
setsid nohup python3 scripts/devvm_console.py log "$DEVVM_DIR" \
    > "$DEVVM_DIR/console_reader.log" 2>&1 < /dev/null &
echo "$!" > "$DEVVM_DIR/console_reader.pid"

echo "devvm: booting (ssh port $SSH_PORT, host http port $HTTP_PORT)"
echo "devvm: rundir $DEVVM_DIR"

# --- wait for the guest to be a guest -------------------------------------
# The marker is a line etc/rc.boot.linux prints once the rc has finished, not
# merely "qemu started": a QEMU that exits three seconds in because the image
# is unbootable would otherwise look like a successful boot for as long as
# nobody tried to use it.
if python3 scripts/devvm_console.py expect "$DEVVM_DIR" \
        "$(printf '%s' "${DEVVM_BOOT_MARKER:-rc.boot: .*(complete|done)|hamsh|\\$ }")" \
        "$BOOT_TIMEOUT"; then
    echo "devvm: guest console is alive"
else
    echo "devvm: WARNING — no console marker within ${BOOT_TIMEOUT}s." >&2
    echo "devvm: the guest may still be booting; read $DEVVM_DIR/console.log" >&2
fi
echo "devvm: console log  $DEVVM_DIR/console.log"
echo "devvm: attach       python3 scripts/devvm_console.py run $DEVVM_DIR '<cmd>'"
echo "devvm: stop         scripts/devvm_down.sh"
