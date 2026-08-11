#!/usr/bin/env bash
# tests/linux/hpm_signed_refresh.sh — `hpm refresh` against the REAL
# https://255.one/, in a VM, WITH NO FLAGS.
#
# WHY THIS IS THE ACCEPTANCE TEST AND NOT tests/linux/hpm_index_sig.sh. That
# one is the mechanism gate: it serves the bytes itself, so it is fast, offline
# and sharp. This one asks the question the machine's owner asks, against the
# server the machine's owner runs, over TLS, from inside the guest:
#
#     hpm refresh          — no --allow-unsigned, no --trusted-key
#     hpm install <pkg>    — and the installed program RUNS
#
# Signing has never worked on this line. The trust root shipped for months had
# no secret key anywhere, so no signature could ever have been produced, and
# --allow-unsigned was the only path that had ever worked. The repo is signed
# now; this is the first boot on which the flag is not needed, and the install
# is here because a refusal that stops printing is not the same as a trusted
# path that works.
#
# The install half also proves the OTHER thing the signature is for: every
# package hash hpm verifies comes out of the index it just authenticated, so
# an install with no --allow-unsigned anywhere is an end-to-end trusted chain
# rather than a signature check that passed and was then ignored.
#
# Usage: tests/linux/hpm_signed_refresh.sh [seconds]
#
# It needs the network (255.one) and it builds a PRIVATE image — nothing under
# the shared build/image is written, per docs/steam_namespace.md §11.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

export HAMLINUX_VNC="${HAMLINUX_VNC:-none}"
WAIT="${1:-300}"
WORK="build/hpmsigvm"; mkdir -p "$WORK"
PKG="${HAMLINUX_SIGPKG:-hamnix-diff}"     # ships /bin/diff, which the image does NOT carry
BIN="${HAMLINUX_SIGBIN:-/bin/diff}"

# QEMU's overlay lands in TMPDIR and /tmp here is a 16 GB tmpfs, i.e. the
# owner's RAM.
export TMPDIR="${TMPDIR:-$PROJ_ROOT/build/tmp}"; mkdir -p "$TMPDIR"

cat > "$WORK/rc.boot" <<'RC'
echo 'rc.boot: hpm signed-refresh acceptance'
ln -s /dev/console /dev/cons
bind '#c' /dev
bind '#p' /proc
bind '#s' /srv

# The same three lines etc/rc.boot.linux uses for QEMU's user-mode stack.
ifconfig lo 127.0.0.1 netmask 255.0.0.0
ifconfig eth0 10.0.2.15 netmask 255.255.255.0
ifconfig gw 10.0.2.2
ifconfig dns 10.0.2.3

echo '[hsig] channels:'
cat /etc/hpm/channels
echo '[hsig] --- hpm refresh, NO FLAGS, against the real repo'
hpm refresh
echo '[hsig] refresh status:' $status
echo '[hsig] --- hpm install, NO FLAGS'
hpm install PKGNAME
echo '[hsig] install status:' $status
# It has to RUN, and it has to give BOTH answers -- a `diff` that exited 0 on
# everything would satisfy "status: 0" while doing nothing.
echo '[hsig] --- the installed program runs (identical files, expect 0):'
BINPATH /etc/hpm/channels /etc/hpm/channels
echo '[hsig] run status:' $status
echo '[hsig] --- and differing files (expect 1):'
BINPATH /etc/hpm/channels /etc/rc.boot
echo '[hsig] diff status:' $status
# The negative controls -- a tampered index, an unsigned repo, a failed
# signature fetch -- are in tests/linux/hpm_index_sig.sh, which serves the
# bytes itself and can therefore corrupt them. Against a live repository that
# somebody else operates there is nothing here to make go wrong on purpose.
echo '[hsig] DONE'
RC
sed -i "s#PKGNAME#$PKG#; s#BINPATH#$BIN#" "$WORK/rc.boot"

# A PRIVATE image directory. build/ is symlinked back to the one tree on this
# host, so a plain hamlinux_image.sh run would overwrite the initramfs another
# agent is booting. Nothing here needs the distro media, so none is attached
# and no shared file is touched at all.
echo "[hsig] building a private image (log: $WORK/build.log)"
HAMLINUX_RC="$WORK/rc.boot" scripts/hamlinux_image.sh > "$WORK/build.log" 2>&1 || {
    echo "FAIL image build"; tail -30 "$WORK/build.log"; exit 1; }

echo "[hsig] booting (up to ${WAIT}s)"
( sleep "$((WAIT + 10))" ) | timeout "$((WAIT + 15))" \
    scripts/hamlinux_vm.sh script --timeout "$WAIT" > "$WORK/boot.log" 2>&1

echo
grep -aE '^\[hsig\]|^hpm:' "$WORK/boot.log" | sed 's/^/    /'
echo

fail=0
check() {   # check <description> <regex>
    if grep -aqE "$2" "$WORK/boot.log"; then
        echo "hsig: PASS $1"
    else
        echo "hsig: FAIL $1   (no line matching /$2/)"
        fail=1
    fi
}
nocheck() { # nocheck <description> <regex that must NOT appear>
    if grep -aqE "$2" "$WORK/boot.log"; then
        echo "hsig: FAIL $1   (found /$2/)"
        fail=1
    else
        echo "hsig: PASS $1"
    fi
}

check   "the boot reached the end"                    '\[hsig\] DONE'
check   "refresh loaded a real index from 255.one"    'hpm: refreshed index from https://255\.one/'
check   "refresh exited 0"                            '\[hsig\] refresh status: 0'
check   "the install completed"                       '\[hsig\] install status: 0'
check   "the installed program ran (identical -> 0)"  '\[hsig\] run status: 0'
check   "and it really compared (differing -> 1)"     '\[hsig\] diff status: 1'
# THE POINT. No flag was passed, so this warning cannot appear -- and if the
# signature check had been skipped, it would.
nocheck "no --allow-unsigned warning anywhere"        'NOT verifying signature'
nocheck "the repo was never called unsigned"          'unsigned repo'
nocheck "nothing aborted for an untrusted index"      'refresh: aborting'
echo "(full log: $WORK/boot.log)"
exit $fail
