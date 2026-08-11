#!/usr/bin/env bash
# tests/linux/two_namespaces.sh — THE acceptance test for `#distro` being a
# mechanism rather than one Debian disk.
#
# It asks four questions in ONE BOOT, because "both available at once, neither
# disturbing the other" is not provable in two boots:
#
#   1. `enter alpine { cat /etc/alpine-release }` from the CONSOLE (uid 0)
#   2. `enter debian { cat /etc/debian_version }` from the console
#   3. `enter alpine { ... }` from uid 1001 -- where the machine's owner
#      actually types it, which is a desktop terminal (etc/rc.de-user.linux
#      drops to 1001). This is the interesting one: it needs mount(2) without
#      CAP_SYS_ADMIN, i.e. the user-namespace path in user/linux-syscalls.c.
#   4. `enter debian { ... }` from uid 1001, AFTER Alpine has been entered, so
#      that a first `enter` cannot have broken the second.
#
# Each arm prints the CONTENTS OF A FILE THAT ONLY EXISTS IN THAT TREE.
# /etc/alpine-release does not exist in Debian and /etc/debian_version does not
# exist in Alpine, so an `enter` that silently entered the wrong root -- or no
# root at all, which is the failure docs/steam_namespace.md was written about
# -- cannot produce a passing line by accident.
#
# Usage: tests/linux/two_namespaces.sh [seconds]
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

# A fixed VNC port means two gates cannot run at once: the second dies with
# "Failed to find an available port" before the guest is even started, and the
# failure looks nothing like a port clash in the test output. Nothing here
# needs VNC -- the screendump comes off the QEMU monitor socket.
export HAMLINUX_VNC="${HAMLINUX_VNC:-none}"

WAIT="${1:-120}"
WORK="build/twons"; mkdir -p "$WORK"
IMG=build/image
[ -f "$IMG/distro.ext4" ] || { echo "no distro image; run scripts/hamlinux_distro.sh" >&2; exit 1; }
[ -f "$IMG/alpine.ext4" ] || { echo "no alpine image; run scripts/hamlinux_alpine.sh" >&2; exit 1; }

# The labels are the whole addressing scheme; check them HERE rather than
# discovering inside the VM that a bind found nothing.
for pair in "distro.ext4:hamnix-debian" "alpine.ext4:hamnix-alpine"; do
    f="${pair%%:*}"; want="${pair##*:}"
    got="$(/sbin/e2label "$IMG/$f" 2>/dev/null)"
    [ "$got" = "$want" ] || {
        echo "FAIL $f carries label '$got', /etc/distros names '$want'" >&2
        echo "  fix: /sbin/tune2fs -L $want $IMG/$f" >&2
        exit 1; }
done
echo "[twons] volume labels OK"

cat > "$WORK/rc.boot" <<'RC'
echo 'rc.boot: two-namespace acceptance'
ln -s /dev/console /dev/cons
bind '#distro/debian' /n/debian
bind '#distro/alpine' /n/alpine
debian = ns clean {
    bind '#distro/debian' /
    bind '#c' /dev
    bind '#p' /proc
    bind '#s' /srv
    bind '#/' /n
}
alpine = ns clean {
    bind '#distro/alpine' /
    bind '#c' /dev
    bind '#p' /proc
    bind '#s' /srv
    bind '#/' /n
}

echo '[twons] --- as root (uid 0)'
echo '[twons] alpine-release:'
enter alpine { /bin/cat /etc/alpine-release }
echo '[twons] alpine status:' $status
echo '[twons] debian_version:'
enter debian { /bin/cat /etc/debian_version }
echo '[twons] debian status:' $status

# The negative control. /etc/alpine-release must NOT be readable from the
# Debian namespace: if it is, the two are the same tree and every line above
# proves nothing.
echo '[twons] alpine-release seen from INSIDE debian (must fail):'
enter debian { /bin/cat /etc/alpine-release }
echo '[twons] cross status:' $status

# AND NOW AS THE PERSON WHO TYPES IT -- the same drop etc/rc.de-user performs
# before handing the terminal to the session.
setuid 1001
echo '[twons] --- as the session user (uid 1001)'
echo '[twons] u1001 alpine-release:'
enter alpine { /bin/cat /etc/alpine-release }
echo '[twons] u1001 alpine status:' $status
echo '[twons] u1001 whoami-in-alpine:'
enter alpine { /usr/bin/id -u }
echo '[twons] u1001 debian_version:'
enter debian { /bin/cat /etc/debian_version }
echo '[twons] u1001 debian status:' $status
echo '[twons] DONE'
RC

echo "[twons] staging an image with that rc"
HAMLINUX_RC="$WORK/rc.boot" scripts/hamlinux_image.sh > "$WORK/build.log" 2>&1 || {
    echo "FAIL image build"; tail -20 "$WORK/build.log"; exit 1; }

echo "[twons] booting (up to ${WAIT}s)"
( sleep "$((WAIT + 10))" ) | timeout "$((WAIT + 5))" \
    scripts/hamlinux_vm.sh script --timeout "$WAIT" > "$WORK/boot.log" 2>&1

echo
grep -aE '^\[twons\]|^3\.[0-9]|^1[0-9]\.[0-9]' "$WORK/boot.log" || {
    echo "no probe output; boot log tail:"; tail -30 "$WORK/boot.log"; exit 1; }
echo

fail=0
check() {   # check <description> <regex>
    if grep -aqE "$2" "$WORK/boot.log"; then
        echo "twons: PASS $1"
    else
        echo "twons: FAIL $1   (no line matching /$2/)"
        fail=1
    fi
}
# THE LINE AFTER THE BANNER IS THE ANSWER. Checking only that the banner and
# `status: 0` are present would pass on an `enter` that ran nothing and exited
# 0 -- which is the exact failure docs/steam_namespace.md records, so it is the
# one thing this test must not be able to do.
#
# THREE lines, not one: stderr and stdout share the console, and hamsh's
# `rfork: no private namespace yet (needs CAP_SYS_ADMIN); one is created on the
# first bind` notice lands between the banner and the answer on every uid-1001
# arm. Three is still tight enough that only this arm's output can satisfy it.
after() {   # after <description> <banner> <regex one of the next lines must match>
    got="$(grep -aA3 -F "$2" "$WORK/boot.log" | tail -n +2 | tr -d '\r')"
    if printf '%s\n' "$got" | grep -qE "$3"; then
        echo "twons: PASS $1  -> '$(printf '%s\n' "$got" | grep -E "$3" | head -1)'"
    else
        echo "twons: FAIL $1  (nothing matching /$3/ in the 3 lines after '$2'; got: $(printf '%s' "$got" | tr '\n' '|'))"
        fail=1
    fi
}
after "uid 0: enter alpine printed a real /etc/alpine-release" \
      '[twons] alpine-release:'      '^[0-9]+\.[0-9]+\.[0-9]+$'
after "uid 0: enter debian printed a real /etc/debian_version" \
      '[twons] debian_version:'      '^[0-9]+\.[0-9]+$'
after "uid 1001: enter alpine printed a real /etc/alpine-release" \
      '[twons] u1001 alpine-release:' '^[0-9]+\.[0-9]+\.[0-9]+$'
after "uid 1001: enter debian printed a real /etc/debian_version" \
      '[twons] u1001 debian_version:' '^[0-9]+\.[0-9]+$'
after "uid 1001: the process inside Alpine really is uid 1001" \
      '[twons] u1001 whoami-in-alpine:' '^1001$'
check "uid 0: alpine enter exited 0"      '\[twons\] alpine status: 0'
check "uid 0: debian enter exited 0"      '\[twons\] debian status: 0'
check "uid 1001: alpine enter exited 0"   '\[twons\] u1001 alpine status: 0'
check "uid 1001: debian enter exited 0"   '\[twons\] u1001 debian status: 0'
check "the boot got to the end"           '\[twons\] DONE'
# The trees really are different: cat of Alpine's release file inside Debian
# must have FAILED.
if grep -aqE '\[twons\] cross status: 0' "$WORK/boot.log"; then
    echo "twons: FAIL the Debian namespace could read /etc/alpine-release -- the two namespaces are the same tree"
    fail=1
else
    echo "twons: PASS /etc/alpine-release is not visible inside the Debian namespace"
fi
echo "(full log: $WORK/boot.log)"
exit $fail
