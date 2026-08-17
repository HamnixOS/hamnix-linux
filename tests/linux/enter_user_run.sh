#!/usr/bin/env bash
#
# REGISTRATION, 2026-08-17. Until this date scripts/test_gate_registration.sh
# globbed only scripts/test_*.sh, so this directory was invisible to the gate
# against unregistered gates and every file in it read as coverage without
# being coverage. This gate is ON-DEMAND: not in ci_battery_manifest.txt
# because it boots a machine through `scripts/hamlinux_vm.sh`.
#
# tests/linux/enter_user_run.sh — THE acceptance test for the root switch.
#
# The question is not "does `enter debian` work" -- it has worked from the
# console for a while. It is "does it work where the machine's owner types
# it", which is a desktop terminal, which runs as uid 1001 (see the long note
# on the privilege drop in etc/rc.de-user.linux). That needs mount(2), and
# mount(2) needs CAP_SYS_ADMIN, and a session does not have it.
#
# It also asks the second question in the same breath: can something INSIDE
# the namespace create a user namespace of its own? That is what bubblewrap
# and Steam's pressure-vessel need, and it is what chroot(2) made impossible
# (docs/steam_namespace.md §5).
#
# Usage: tests/linux/enter_user_run.sh [seconds]
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

WAIT="${1:-120}"
WORK="build/enteruser"; mkdir -p "$WORK"
IMG=build/image
[ -f "$IMG/distro.ext4" ] || { echo "no distro image; run scripts/hamlinux_distro.sh" >&2; exit 1; }

echo "[enteruser] planting the in-namespace probe"
/sbin/debugfs -w -R "rm /usr/local/bin/enter_user" "$IMG/distro.ext4" >/dev/null 2>&1
/sbin/debugfs -w "$IMG/distro.ext4" >/dev/null 2>&1 <<DBG
write tests/linux/enter_user.sh /usr/local/bin/enter_user
sif /usr/local/bin/enter_user mode 0100755
DBG

cat > "$WORK/rc.boot" <<'RC'
echo 'rc.boot: enter-as-user acceptance'
ln -s /dev/console /dev/cons
bind '#distro' /n/distro
debian = ns clean {
    bind '#distro' /
    bind '#c' /dev
    bind '#p' /proc
    bind '#s' /srv
    bind '#/' /n
}
echo '[enteruser] --- as root (uid 0)'
enter debian { /usr/local/bin/enter_user }
echo '[enteruser] --- root enter status:' $status

# AND NOW AS THE PERSON WHO TYPES IT. This is the same drop etc/rc.de-user
# performs before handing the terminal to the session.
setuid 1001
echo '[enteruser] --- as the session user (uid 1001)'
enter debian { /usr/local/bin/enter_user }
echo '[enteruser] --- uid 1001 enter status:' $status
echo '[enteruser] DONE'
RC

echo "[enteruser] staging an image with that rc"
HAMLINUX_RC="$WORK/rc.boot" scripts/hamlinux_image.sh > "$WORK/build.log" 2>&1 || {
    echo "FAIL image build"; tail -20 "$WORK/build.log"; exit 1; }

echo "[enteruser] booting (up to ${WAIT}s)"
( sleep "$((WAIT + 10))" ) | timeout "$((WAIT + 5))" \
    scripts/hamlinux_vm.sh script --timeout "$WAIT" > "$WORK/boot.log" 2>&1

echo
grep -E '^enteruser:|^\[enteruser\]' "$WORK/boot.log" || {
    echo "no probe output; boot log tail:"; tail -30 "$WORK/boot.log"; exit 1; }
echo
P=$(grep -c '^enteruser: PASS' "$WORK/boot.log")
F=$(grep -c '^enteruser: FAIL' "$WORK/boot.log")
echo "[enteruser] PASS $P  FAIL $F   (full log: $WORK/boot.log)"
# NO EVIDENCE IS NOT A PASS. `[ "$F" = 0 ]` on its own passed a boot in which
# the probe never ran at all: the presence check above is satisfied by
# `[enteruser] --- as root (uid 0)`, which rc.boot echoes ITSELF before
# `enter debian` is reached, and the debugfs plant that puts the probe into
# the image is `>/dev/null 2>&1`, so a plant that failed is invisible. P=0
# F=0 then exited 0 -- a clean pass over a probe that produced nothing.
# tests/linux/enter_user.sh makes three assertions and rc.boot runs it twice,
# as root and as uid 1001, so a working run cannot report fewer than one.
if [ "$((P + F))" = 0 ]; then
    echo "[enteruser] UNREADABLE -- the in-namespace probe reported neither PASS nor FAIL:"
    echo "[enteruser]   /usr/local/bin/enter_user did not run, or did not reach its first"
    echo "[enteruser]   assertion. This run did not observe 'enter' at all; it is NOT a pass."
    tail -30 "$WORK/boot.log"
    exit 1
fi
[ "$F" = 0 ]
