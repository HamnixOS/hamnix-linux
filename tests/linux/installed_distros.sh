#!/usr/bin/env bash
#
# REGISTRATION, 2026-08-17. Until this date scripts/test_gate_registration.sh
# globbed only scripts/test_*.sh, so this directory was invisible to the gate
# against unregistered gates and every file in it read as coverage without
# being coverage. This gate is ON-DEMAND: not in ci_battery_manifest.txt
# because it boots a machine through `scripts/hamlinux_vm.sh`.
#
# tests/linux/installed_distros.sh — both distribution namespaces on an
# INSTALLED DISK, after a reboot. The part nobody had ever run.
#
# tests/linux/two_namespaces.sh proves `enter alpine { }` and `enter debian { }`
# on the LIVE boot, where everything is in RAM and the rc is
# etc/rc.boot.linux. An installed system boots etc/rc.boot.installed instead,
# off a real ext4 root, through UEFI and a unified kernel image -- and that
# file had NO distribution bind and NO `ns clean { }` template in it at all.
# So the subsystem worked on every boot that is thrown away and on none of the
# boots that persist, and nothing said so, because no test had ever booted an
# installed disk and typed the command.
#
# THE MEDIA ARE THE SAME TWO DISKS, and that is the interesting part rather
# than a shortcut: the installed root is /dev/vda2 and the distribution disks
# are whatever the firmware enumerated after it. Nothing here names a device.
# /etc/distros names ext4 volume LABELS, so the answer does not depend on how
# many disks the installed machine has that the live one did not.
#
# Each arm prints the contents of a file that exists in ONLY ONE of the two
# trees, for the same reason two_namespaces.sh does: an `enter` that entered
# nothing, or entered the wrong root, must not be able to produce a passing
# line.
#
# Usage: tests/linux/installed_distros.sh [seconds]
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

export HAMLINUX_VNC="${HAMLINUX_VNC:-none}"
export HAMLINUX_DISTRO_RO="${HAMLINUX_DISTRO_RO:-1}"

WAIT="${1:-150}"
WORK="build/installedns"; mkdir -p "$WORK"
IMG=build/image
[ -f "$IMG/distro.ext4" ] || { echo "no distro image; run scripts/hamlinux_distro.sh" >&2; exit 1; }
[ -f "$IMG/alpine.ext4" ] || { echo "no alpine image; run scripts/hamlinux_alpine.sh" >&2; exit 1; }

cat > "$WORK/rc.boot" <<'RC'
# The REAL installed boot rc, verbatim -- binds, templates, runlevel 5 and
# all. Sourcing it is what makes this a test OF etc/rc.boot.installed rather
# than a test of a copy of it that happens to agree today.
source '/etc/rc.boot.installed'

echo '[idisk] --- installed disk, as root (uid 0)'
echo '[idisk] alpine-release:'
enter alpine { /bin/cat /etc/alpine-release }
echo '[idisk] alpine status:' $status
echo '[idisk] debian_version:'
enter debian { /bin/cat /etc/debian_version }
echo '[idisk] debian status:' $status

# The negative control: the two trees must not be one tree.
echo '[idisk] alpine-release seen from INSIDE debian (must fail):'
enter debian { /bin/cat /etc/alpine-release }
echo '[idisk] cross status:' $status

# And the alias that etc/install.hamsh.linux and several tests still spell.
echo '[idisk] linux alias debian_version:'
enter linux { /bin/cat /etc/debian_version }
echo '[idisk] linux status:' $status

# AS THE PERSON WHO TYPES IT. A desktop terminal on an installed system is
# uid 1001, and resolving a volume LABEL means opening a block device, which
# uid 1001 cannot do -- so this arm is the one that proves the fallback to the
# name the boot posted the server at still holds on a disk that was installed.
setuid 1001
echo '[idisk] --- as the session user (uid 1001)'
echo '[idisk] u1001 alpine-release:'
enter alpine { /bin/cat /etc/alpine-release }
echo '[idisk] u1001 alpine status:' $status
echo '[idisk] u1001 debian_version:'
enter debian { /bin/cat /etc/debian_version }
echo '[idisk] u1001 debian status:' $status
echo '[idisk] DONE'
RC

# The disk is assembled from build/image/root, and /etc/rc.distros -- which
# is what defines the namespace templates -- is GENERATED into that root by
# scripts/hamlinux_image.sh. Run against a stale root this gate fails nine
# ways with `enter: not a namespace: alpine`, which reads exactly like the
# feature being broken rather than the image being old. Build first.
echo "[idisk] staging the image root (rc.distros is generated there)"
HAMLINUX_JOBS="${HAMLINUX_JOBS:-4}" scripts/hamlinux_image.sh >"$WORK/image.log" 2>&1 || {
    echo "FAIL image build"; tail -20 "$WORK/image.log"; exit 1; }

echo "[idisk] building an installed disk with that rc"
HAMLINUX_DISK_RC="$WORK/rc.boot" scripts/hamlinux_disk.sh \
    "$IMG/installedns.img" 3G >"$WORK/build.log" 2>&1 || {
    echo "FAIL disk build"; tail -20 "$WORK/build.log"; exit 1; }

echo "[idisk] booting the INSTALLED disk through UEFI (up to ${WAIT}s)"
( sleep "$((WAIT + 10))" ) | HAMLINUX_DISK="$IMG/installedns.img" \
    timeout "$((WAIT + 5))" scripts/hamlinux_vm.sh disk --timeout "$WAIT" \
    >"$WORK/boot.log" 2>&1

echo
grep -aE '^\[idisk\]|^rc\.boot:|^3\.[0-9]|^1[0-9]\.[0-9]' "$WORK/boot.log" || {
    echo "no probe output; boot log tail:"; tail -30 "$WORK/boot.log"; exit 1; }
echo

fail=0
check() {
    if grep -aqE "$2" "$WORK/boot.log"; then echo "idisk: PASS $1"
    else echo "idisk: FAIL $1   (no line matching /$2/)"; fail=1; fi
}
# THE LINE AFTER THE BANNER IS THE ANSWER -- see the long note in
# tests/linux/two_namespaces.sh for why a `status: 0` on its own is not one.
after() {
    got="$(grep -aA3 -F "$2" "$WORK/boot.log" | tail -n +2 | tr -d '\r')"
    if printf '%s\n' "$got" | grep -qE "$3"; then
        echo "idisk: PASS $1  -> '$(printf '%s\n' "$got" | grep -E "$3" | head -1)'"
    else
        echo "idisk: FAIL $1  (nothing matching /$3/ in the 3 lines after '$2'; got: $(printf '%s' "$got" | tr '\n' '|'))"
        fail=1
    fi
}
check "the installed root came online"  'rc\.boot: hamnix-linux \(installed\)'
after "uid 0: enter alpine printed a real /etc/alpine-release" \
      '[idisk] alpine-release:'       '^[0-9]+\.[0-9]+\.[0-9]+$'
after "uid 0: enter debian printed a real /etc/debian_version" \
      '[idisk] debian_version:'       '^[0-9]+\.[0-9]+$'
after 'the `linux` alias still reaches Debian' \
      '[idisk] linux alias debian_version:' '^[0-9]+\.[0-9]+$'
after "uid 1001: enter alpine printed a real /etc/alpine-release" \
      '[idisk] u1001 alpine-release:' '^[0-9]+\.[0-9]+\.[0-9]+$'
after "uid 1001: enter debian printed a real /etc/debian_version" \
      '[idisk] u1001 debian_version:' '^[0-9]+\.[0-9]+$'
check "uid 0: alpine enter exited 0"    '\[idisk\] alpine status: 0'
check "uid 0: debian enter exited 0"    '\[idisk\] debian status: 0'
check "uid 1001: alpine enter exited 0" '\[idisk\] u1001 alpine status: 0'
check "uid 1001: debian enter exited 0" '\[idisk\] u1001 debian status: 0'
check "the boot got to the end"         '\[idisk\] DONE'
if grep -aqE '\[idisk\] cross status: 0' "$WORK/boot.log"; then
    echo "idisk: FAIL the Debian namespace could read /etc/alpine-release -- the two namespaces are the same tree"
    fail=1
else
    echo "idisk: PASS /etc/alpine-release is not visible inside the Debian namespace"
fi
echo "(full log: $WORK/boot.log)"
exit $fail
