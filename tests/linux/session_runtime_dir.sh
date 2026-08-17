#!/usr/bin/env bash
#
# REGISTRATION, 2026-08-17. Until this date scripts/test_gate_registration.sh
# globbed only scripts/test_*.sh, so this directory was invisible to the gate
# against unregistered gates and every file in it read as coverage without
# being coverage. This gate is ON-DEMAND: not in ci_battery_manifest.txt
# because it boots a machine through `scripts/hamlinux_vm.sh`.
#
# tests/linux/session_runtime_dir.sh — can the SESSION USER create a file in
# its own runtime directory, and does the system bus come up for it?
#
# THE FOURTH FAULT OF THE FAMILY docs/linux_distro_namespaces.md §8.4 opened.
# Three of them were the same mistake -- a thing root made when root was its
# only user, invisible to the unprivileged session that came later: a mount
# point in the medium (`/n`), a stale X lock in its `/tmp`, the Wayland socket
# in its `/run` at `srwxr-xr-x` when connect(2) needs write. The fourth is the
# DIRECTORY the third lives in. `$XDG_RUNTIME_DIR` was the distribution's whole
# `/run`, 40755 uid 0 on both media, so the session could READ everything
# wsyswl publishes there and CREATE NOTHING.
#
# WHY THIS IS A SEPARATE FILE FROM tests/linux/distro_menu.sh. That gate boots
# the whole desktop and drives a menu with synthetic pointer events, because
# what it is asking about is a fly-out. This asks one question about
# permissions and needs no compositor, no Xwayland and no window manager -- and
# a permission fact that can only be measured by first standing up three
# servers is a fact nobody will re-measure. It boots, drops to uid 1001,
# enters, and writes.
#
# AND IT MEASURES BY WRITING. Every fault in this family is the mode bits
# reading correctly while the effective answer is still no -- a uid that is not
# mapped into the user namespace, a sticky /tmp, a read-only medium. `[ -w ]`
# would have passed on some of them. `NORTH_STAR.md`: a gap must never answer
# something success-shaped instead of the truth.
#
# NOTHING SHARED IS WRITTEN. The probe goes in as a SECOND CPIO SEGMENT
# (docs/steam_namespace.md §11) and root copies it into the tree at run time,
# where HAMLINUX_DISTRO_RO=1 puts the write in a throwaway overlay. No
# `debugfs` plant into build/image/distro.ext4, which is shared between agents.
#
# Usage: tests/linux/session_runtime_dir.sh [seconds]
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"
# REAP WHAT YOU START. This gate had no trap at all: everything it launched in
# the background survived any exit that was not the happy one -- an assertion
# that bailed early, a `timeout`, a ^C. tests/linux/reap.sh keeps a file-backed
# registry of this run's own children and kills them on every path out.
. tests/linux/reap.sh
reap_on_exit

WAIT="${1:-150}"
WORK="build/sessionrt"; mkdir -p "$WORK"
IMG=build/image
export HAMLINUX_VNC="${HAMLINUX_VNC:-none}"
export HAMLINUX_DISTRO_RO="${HAMLINUX_DISTRO_RO:-1}"
[ -e "$IMG/distro.ext4" ] || { echo "no distro image; run scripts/hamlinux_distro.sh" >&2; exit 1; }

# --- the probe, which runs INSIDE the namespace as uid 1001 ---------------
SEG="$WORK/seg"; rm -rf "$SEG"; mkdir -p "$SEG/etc"
cat > "$SEG/etc/rtprobe.sh" <<'PROBE'
#!/bin/sh
# Runs inside the distribution, as the session user. POSIX sh: this is the
# distribution's shell (bash in Debian, busybox ash in Alpine), not hamsh.
set -u
say() { echo "sessionrt: $*"; }
ok()  { echo "sessionrt: PASS $*"; }
bad() { echo "sessionrt: FAIL $*"; }

U=$(id -u 2>/dev/null)
say "INFO uid $U, XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-<unset>}"

# 1. THE DIRECTORY EXISTS AND IS THE PER-USER ONE, not the distribution's /run.
XRD="${XDG_RUNTIME_DIR:-}"
case "$XRD" in
    /run/user/*) ok "XDG_RUNTIME_DIR is a per-user directory ($XRD)" ;;
    *)           bad "XDG_RUNTIME_DIR is '$XRD', not /run/user/<uid>" ;;
esac

# 2. IT IS OURS, AT 0700. Narrower than the /run it replaces, which is the
#    whole argument for taking this route over a world-writable /run.
say "INFO $(ls -ld "$XRD" 2>&1)"
if [ -O "$XRD" ]; then ok "$XRD is owned by uid $U"
else bad "$XRD is NOT owned by uid $U"; fi

# 3. THE ONE THAT MATTERS: CREATE A FILE. Not `[ -w ]`.
P="$XRD/.sessionrt.$$"
if : > "$P" 2>/dev/null; then
    ok "uid $U CREATED a file in its runtime directory ($P)"
    rm -f "$P" 2>/dev/null
else
    bad "uid $U could not create a file in $XRD -- this is the fourth fault"
fi

# 4. AND A DIRECTORY, because dconf and every toolkit cache makes one.
D="$XRD/.sessionrt.d.$$"
if mkdir "$D" 2>/dev/null; then
    ok "uid $U created a subdirectory in its runtime directory"
    rmdir "$D" 2>/dev/null
else
    bad "uid $U could not mkdir in $XRD"
fi

# 5. THE SOCKET DID NOT MOVE, AND THE NAME IN THE NEW DIRECTORY STILL FINDS
#    IT. Five files name /run/wayland-0 by that path; the fix symlinks the
#    published names into /run/user/<uid> instead of relocating them. This is
#    the link, not the server: no wsyswl runs in this gate, so the target is
#    legitimately absent and `readlink` is the question to ask.
L="$XRD/wayland-0"
if [ -L "$L" ]; then
    T=$(readlink "$L" 2>/dev/null)
    say "INFO $L -> $T"
    case "$T" in
        */wayland-0) ok "the wayland-0 name in $XRD is a link to the real socket" ;;
        *)           bad "$L links to '$T', which is not a wayland-0" ;;
    esac
else
    bad "no wayland-0 link in $XRD -- a client's wl_display_connect() will not find the display"
fi
[ -L "$XRD/hamnix-screen" ] && ok "the hamnix-screen geometry name is linked too" \
    || bad "no hamnix-screen link in $XRD; a rootful Xwayland will come up 640x480"

# 6. THE SYSTEM BUS, WHICH IS A SEPARATE DIRECTORY AND A SEPARATE ANSWER.
#    /run/dbus/system_bus_socket is a COMPILE-TIME path in dbus: no
#    XDG_RUNTIME_DIR moves it, so item 3 passing tells us nothing about this.
say "INFO $(ls -ld /run/dbus 2>&1)"
DP="/run/dbus/.sessionrt.$$"
if : > "$DP" 2>/dev/null; then
    ok "uid $U can write /run/dbus (dbus-daemon --system can bind its socket)"
    rm -f "$DP" 2>/dev/null
else
    bad "uid $U cannot write /run/dbus -- the system bus cannot come up for the session"
fi

if command -v dbus-daemon >/dev/null 2>&1; then
    # A stale socket on the medium outlives the reboot and is not a live bus.
    # Clearing it needs write on the DIRECTORY, which is item 6 again.
    rm -f /run/dbus/system_bus_socket /run/dbus/pid 2>/dev/null
    command -v dbus-uuidgen >/dev/null 2>&1 && dbus-uuidgen --ensure 2>/dev/null
    dbus-daemon --system --nofork --print-address >/tmp/sessionrt-dbus.log 2>&1 &
    reap_add $!
    i=0
    while [ $i -lt 40 ]; do
        [ -S /run/dbus/system_bus_socket ] && break
        i=$((i+1)); sleep 0.25
    done
    # TALK TO IT. A socket file is not a bus -- the same lesson
    # tests/linux/hamnix_x11session.sh learned when a stale socket made its
    # `[ -S ]` guard skip starting the bus on every boot for ever.
    if command -v dbus-send >/dev/null 2>&1; then
        if dbus-send --system --dest=org.freedesktop.DBus --print-reply \
               --type=method_call / org.freedesktop.DBus.GetId >/tmp/sessionrt-getid.log 2>&1; then
            ok "the system bus came up AS UID $U and answered GetId"
        else
            bad "the system bus did not answer GetId as uid $U"
            sed 's/^/sessionrt:   dbus: /' /tmp/sessionrt-dbus.log 2>/dev/null | head -6
        fi
    else
        say "INFO no dbus-send here; cannot ask the bus anything"
    fi
else
    say "INFO no dbus-daemon in this distribution; skipping the bus"
fi
say "PROBE-DONE"
PROBE

# --- the boot -------------------------------------------------------------
# `source /etc/rc.distros` is what posts each distribution at its name, and it
# is the call that stages the runtime directory (user/linux-syscalls.c,
# distro_stage_runtime, reached from distro_stage_mountpoints). Everything
# under test happens there, as root, before the drop.
cat > "$WORK/rc.boot" <<'RC'
echo 'rc.boot: the session user runtime directory'
ln -s /dev/console /dev/cons
source '/etc/rc.distros'

# Root plants the probe INSIDE the tree, because by the time it runs that tree
# is `/'. Same reason and the same moment /etc/de-ns-run is copied in.
cp /etc/rtprobe.sh /n/debian/tmp/rtprobe.sh
echo '[sessionrt] --- what root staged in the debian /run'
ls /n/debian/run/user
ls /n/debian/run/user/1001

# THE DROP. Same order etc/rc.de-user and the generated /etc/rc.de-ns/<name>
# use: everything needing CAP_SYS_ADMIN first, then setuid, then the program.
setuid 1001
HOME='/home/live'
export HOME
XDG_RUNTIME_DIR='/run/user/1001'
export XDG_RUNTIME_DIR
echo '[sessionrt] --- as the session user (uid 1001), inside debian'
enter debian { /bin/sh /tmp/rtprobe.sh }
echo '[sessionrt] --- probe status:' $status
echo '[sessionrt] DONE'
RC

echo "[sessionrt] staging an image with that rc and the probe"
HAMLINUX_RC="$WORK/rc.boot" scripts/hamlinux_image.sh > "$WORK/build.log" 2>&1 || {
    echo "FAIL image build"; tail -20 "$WORK/build.log"; exit 1; }
# The second segment. The initramfs loader unpacks concatenated gzipped `newc`
# archives in order, so this adds /etc/rtprobe.sh without unpacking anything.
( cd "$SEG" && find etc -print | cpio -o -H newc 2>/dev/null | gzip ) \
    >> "$IMG/initramfs.cpio.gz"

echo "[sessionrt] booting (up to ${WAIT}s)"
( sleep "$((WAIT + 10))" ) | timeout "$((WAIT + 5))" \
    scripts/hamlinux_vm.sh script --timeout "$WAIT" > "$WORK/boot.log" 2>&1

echo
# `-a`: once the probe reaches a distribution's tools the console carries NUL
# bytes, and a grep without -a matches nothing and reports the run as silent.
# That is exactly how two checks in tests/linux/distro_menu.sh came to answer
# something failure-shaped instead of the truth.
grep -aE '^sessionrt:|^\[sessionrt\]' "$WORK/boot.log" | tr -d '\0\r' || {
    echo "no probe output; boot log tail:"; tail -30 "$WORK/boot.log"; exit 1; }
echo
# A here-string, NOT a pipe into `grep -c`: under `set -o pipefail` a
# successful match makes grep exit early, upstream dies 141 on SIGPIPE and
# pipefail promotes it to failure. It passed here for years and broke the
# moment a log got long.
P=$(grep -ac '^sessionrt: PASS' "$WORK/boot.log")
F=$(grep -ac '^sessionrt: FAIL' "$WORK/boot.log")
# THE PROBE MUST HAVE FINISHED. Zero PASS and zero FAIL is a boot that never
# reached the probe, and without this line that reads as a clean run.
if ! grep -aq 'sessionrt: PROBE-DONE' "$WORK/boot.log"; then
    echo "[sessionrt] FAIL the probe never ran to completion (no PROBE-DONE)"
    F=$((F + 1))
fi
echo "[sessionrt] PASS $P  FAIL $F   (full log: $WORK/boot.log)"
[ "$F" = 0 ]
