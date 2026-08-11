#!/usr/bin/env bash
# tests/linux/steam_probe_run.sh — boot the VM and ask the Debian namespace
# what a Steam-class application would find there.
#
# The probe itself (tests/linux/steam_probe.sh) runs INSIDE the namespace, as a
# Debian /bin/sh, with the Hamnix filesystem unreachable. This harness only
# gets it there: it stages a bootstrap rc that configures the interface, binds
# `#distro`, captures the `debian` template and enters it, then boots that
# headless and reads the console.
#
# The probe is written into the namespace image with debugfs rather than by
# rebuilding it, because a rebuild is a 2 GB download and the probe is 8 KB.
#
# Usage: tests/linux/steam_probe_run.sh [seconds]
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

WAIT="${1:-150}"
WORK="${STEAM_PROBE_WORK:-build/steamprobe}"; mkdir -p "$WORK"
IMG=build/image
[ -f "$IMG/distro.ext4" ] || { echo "no distro image; run scripts/hamlinux_distro.sh" >&2; exit 1; }

echo "[steamprobe] planting the probe in the namespace image"
/sbin/debugfs -w -R "rm /usr/local/bin/steam_probe" "$IMG/distro.ext4" >/dev/null 2>&1
/sbin/debugfs -w "$IMG/distro.ext4" >/dev/null 2>&1 <<EOF
write tests/linux/steam_probe.sh /usr/local/bin/steam_probe
sif /usr/local/bin/steam_probe mode 0100755
EOF

cat > "$WORK/rc.boot" <<'RC'
# A headless bootstrap rc for the Steam probe. No rc.5: the compositor is not
# what is under test here and its beacon lines bury the console.
echo 'rc.boot: hamnix-linux starting'
ln -s /dev/console /dev/cons
ln -s /proc/self/fd /dev/fd
ln -s /proc/self/fd/0 /dev/stdin
ln -s /proc/self/fd/1 /dev/stdout
ln -s /proc/self/fd/2 /dev/stderr
mkdir /dev/shm
bind '#t' /dev/shm

ifconfig eth0 10.0.2.15 netmask 255.255.255.0
ifconfig gw 10.0.2.2
ifconfig dns 10.0.2.3
HAMNIX_IFACE='lo'
export HAMNIX_IFACE
ifconfig lo 127.0.0.1 netmask 255.0.0.0
HAMNIX_IFACE='eth0'
export HAMNIX_IFACE
echo 'rc.boot: network configured'

bind '#distro' /n/distro
debian = ns clean {
    bind '#distro' /
    bind '#c' /dev
    bind '#p' /proc
    bind '#s' /srv
    bind '#/' /n
}

echo '[steamprobe] --- entering the Debian namespace'
enter debian { /usr/local/bin/steam_probe }
echo '[steamprobe] --- probe exited'

# AND NOW AS THE PERSON WHO ACTUALLY TYPES IT. etc/rc.de-user.linux drops the
# desktop session to uid 1001, and `enter debian` performs unshare(CLONE_NEWNS)
# + mount(2) + chroot(2) -- all of which need CAP_SYS_ADMIN. So the question
# "does `enter debian { steam }` work from a desktop terminal?" is not the same
# question as "does it work from the console", and this is where it gets asked.
echo '[steamprobe] --- dropping to uid 1001 and entering again'
setuid 1001
enter debian { /bin/id }
echo '[steamprobe] --- uid 1001 enter status:' $status
RC

echo "[steamprobe] staging an image with that rc"
HAMLINUX_RC="$WORK/rc.boot" scripts/hamlinux_image.sh > "$WORK/build.log" 2>&1 || {
    echo "FAIL image build"; tail -20 "$WORK/build.log"; exit 1; }

echo "[steamprobe] booting (up to ${WAIT}s)"
( sleep "$((WAIT + 10))" ) | timeout "$((WAIT + 5))" \
    scripts/hamlinux_vm.sh script --timeout "$WAIT" > "$WORK/boot.log" 2>&1

echo
grep -E '^steamprobe:|^\[steamprobe\]' "$WORK/boot.log" || {
    echo "no probe output at all; boot log tail:"; tail -30 "$WORK/boot.log"; exit 1; }
echo
P=$(grep -c '^steamprobe: PASS' "$WORK/boot.log")
F=$(grep -c '^steamprobe: FAIL' "$WORK/boot.log")
S=$(grep -c '^steamprobe: SKIP' "$WORK/boot.log")
echo "[steamprobe] PASS $P  FAIL $F  SKIP $S   (full log: $WORK/boot.log)"
[ "$F" = 0 ]
