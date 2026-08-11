#!/usr/bin/env bash
# tests/linux/snarf_ondevice.sh — the clipboard device on a REAL BOOT.
#
# tests/linux/snarf_device.sh proves the mechanism offscreen, in a private
# mount namespace on the build host. This one proves it where it has to work:
# inside the VM, on the shipped image, with linuxinit as PID 1 and /srv the
# tmpfs it mounts.
#
# THE POINT OF A SERVED DEVICE IS THAT THE BOOT CREATES NOTHING, so there is no
# rc line to add and no image change: `grep -rn snarf etc/` is still empty
# after this work. What this test stages is an rc.boot of its OWN -- the
# HAMLINUX_RC hook tests/linux/two_namespaces.sh uses -- purely so the sequence
# runs unattended and lands on the serial log.
#
# AND IT CROSSES THE UID BOUNDARY, which is the case an ordinary file answers
# badly: root copies, `setuid 1001` (the same drop etc/rc.de-user performs),
# and the session pastes it and copies back.
#
# Usage: tests/linux/snarf_ondevice.sh [seconds-to-wait]
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

WAIT="${1:-45}"
OUT="${HAMSNARF_TEST_OUT:-build/snarf}"
mkdir -p "$OUT"
LOG="$OUT/ondevice.log"

cat > "$OUT/rc.boot" <<'RC'
echo 'rc.boot: /dev/snarf acceptance'
ln -s /dev/console /dev/cons
echo '[snarfdev] --- as root (uid 0), which is what the chrome runs as'
echo SNARF-ONDEVICE-9f3a > /dev/snarf
echo '[snarfdev] root cat /dev/snarf:'
cat /dev/snarf
echo PRIMARY-ONDEVICE-9f3a > /dev/snarf.primary
echo '[snarfdev] root cat /dev/snarf.primary:'
cat /dev/snarf.primary
echo '[snarfdev] and the CLIPBOARD is untouched by the PRIMARY write:'
cat /dev/snarf
echo '[snarfdev] the segment the FIRST OPEN created, in the /srv tmpfs:'
ls -l /srv
# The same drop etc/rc.de-user performs before handing over the session.
setuid 1001
echo '[snarfdev] --- as the session user (uid 1001)'
echo '[snarfdev] u1001 cat /dev/snarf (the chrome copied this):'
cat /dev/snarf
echo SESSION-ONDEVICE-9f3a > /dev/snarf
echo '[snarfdev] u1001 wrote it back; u1001 cat /dev/snarf:'
cat /dev/snarf
echo '[snarfdev] DONE'
RC

echo "[snarf-dev] staging an image with that rc ..."
if ! HAMLINUX_RC="$OUT/rc.boot" scripts/hamlinux_image.sh >"$OUT/img.log" 2>&1; then
    echo "[snarf-dev] FAIL: image build"; tail -20 "$OUT/img.log"; exit 1
fi

echo "[snarf-dev] booting (up to ${WAIT}s) ..."
# HAMLINUX_DISTRO_RO=1 attaches the distro media snapshot=on, so any number of
# VMs share one image and nothing the guest writes survives; HAMLINUX_VNC=none
# because two gates on the fixed VNC port kill each other with an error that
# looks nothing like contention. docs/steam_namespace.md §11.
( sleep "$((WAIT + 10))" ) | timeout "$((WAIT + 5))" \
    env HAMLINUX_DISTRO_RO=1 HAMLINUX_VNC=none \
    scripts/hamlinux_vm.sh script --timeout "$WAIT" >"$LOG" 2>&1

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS  $*"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $*"; }
# What the `cat` after a given marker line printed. The first following line
# is skipped when it is hamsh's rfork notice: after `setuid 1001` every spawn
# prints "rfork: no private namespace yet", which is a true statement about an
# unprivileged session and not this test's business.
after() {
    grep -A2 -F "$1" "$LOG" | tail -n +2 | tr -d '\r' \
        | grep -v '^rfork: ' | sed -n '1p'
}
chk() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$2] got [$3]"; fi; }

echo
echo "[snarf-dev] assertions"
grep -qF '[snarfdev] DONE' "$LOG" || bad "the rc never completed"
chk "root: cat /dev/snarf reads back what the shell wrote" \
    "SNARF-ONDEVICE-9f3a" "$(after '[snarfdev] root cat /dev/snarf:')"
chk "root: /dev/snarf.primary is a SECOND buffer" \
    "PRIMARY-ONDEVICE-9f3a" "$(after '[snarfdev] root cat /dev/snarf.primary:')"
chk "the PRIMARY write did not touch the CLIPBOARD" \
    "SNARF-ONDEVICE-9f3a" "$(after '[snarfdev] and the CLIPBOARD is untouched by the PRIMARY write:')"
chk "the uid-1001 SESSION reads what root copied" \
    "SNARF-ONDEVICE-9f3a" "$(after '[snarfdev] u1001 cat /dev/snarf (the chrome copied this):')"
chk "and copies back into the root-owned segment" \
    "SESSION-ONDEVICE-9f3a" "$(after '[snarfdev] u1001 wrote it back; u1001 cat /dev/snarf:')"
# The segment is in /srv, is 0666, and NOTHING created a file at /dev/snarf.
if grep -A6 -F '[snarfdev] the segment the FIRST OPEN created' "$LOG" \
        | grep -qE '^-rw-rw-rw-.*snarf'; then
    ok "/srv/snarf exists and is 0666 (not the umask's 0644)"
else
    bad "/srv/snarf is missing or not 0666"
    grep -A6 -F '[snarfdev] the segment the FIRST OPEN created' "$LOG"
fi

echo
echo "[snarf-dev] SUMMARY passes=$PASS fails=$FAIL"
[ "$FAIL" -eq 0 ] || { echo "[snarf-dev] RESULT: FAIL"; exit 1; }
echo "[snarf-dev] RESULT: PASS"
