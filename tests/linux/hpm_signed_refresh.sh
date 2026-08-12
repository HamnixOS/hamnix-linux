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
#
# WHICH GATE ANSWERS WHICH QUESTION -- read this before adding an assertion
# =========================================================================
# Four files touch the PUBLISHED channel and they are not interchangeable.
# Working that out cost a whole pass: a gate was named as "the cover" for
# something it does not cover, and two full runs were spent before the log
# said so. The division is deliberate and each line names what the file does
# NOT answer, because that is the half that gets forgotten.
#
#   tests/linux/hpm_signed_refresh.sh   THE SIGNED DELIVERY PATH.  ~6 min, ONE
#     throwaway initramfs boot, no disk.  A bare `hpm refresh` + `hpm install`
#     against the real 255.one with NO FLAGS: the index authenticates against
#     the SHIPPED trust root, one published package downloads, its hash is
#     checked against that authenticated index, it unpacks, and the program it
#     carries RUNS.  Does NOT answer: whether a desktop comes up, whether an
#     installed disk survives a reboot, or anything about a package larger than
#     the one it installs.  It is the fast one on purpose -- strengthening it to
#     boot a desktop would make it a slower duplicate of the file below and
#     leave nothing that can be run on every push.
#
#   tests/linux/installed_update_live.sh   THE WHOLE PATH, TO A WORKING SCREEN.
#     ~30 min, THREE boots of a real UEFI+ext4 disk.  Installs an OLDER local
#     channel, then takes the REAL published update with no flags, reboots, and
#     puts a REAL POINTER on the Applications button over QMP.  This is the
#     only file that answers "what is published today boots and works".  Does
#     NOT answer: anything about a WSYS_VERSION bump, and nothing about
#     packages other than the desktop's own delivery.
#
#   tests/linux/installed_update_modules.sh   PUBLISHED MODULE BYTES, into the
#     kernel's own /proc/modules on a rebooted installed disk.  Nothing
#     graphical.
#
#   tests/linux/installed_update_wsysver.sh   A WSYS_VERSION BOUNDARY, and
#     NOTHING PUBLISHED AT ALL -- it builds all three of its channels itself,
#     one version apart, with no network, because a boundary that exists only
#     when the channel happens to be behind the tree is a boundary that stops
#     existing right after every release.  It gave up the published-bytes arm
#     on purpose; the two files above are where that lives.
#
# And two that never fetch and never boot: channel_runs_desktop.sh runs the
# LOCAL channel's binaries offscreen, channel_covers_image.sh compares names
# and /etc bytes.
#
# WHAT THIS FILE DOES NOT PROVE, SAID HERE SO IT IS NOT ASSUMED. The boot is a
# throwaway initramfs one and the package is `hamnix-diff`, chosen because it
# is small and the image does not already carry /bin/diff. So this is evidence
# about the DELIVERY PATH -- authenticate, fetch, verify, unpack, run -- and
# not about the desktop, an installed disk, or a reboot. That is a deliberate
# scope and not a gap to be closed here: this file is cheap enough to run on
# every push, and tests/linux/installed_update_live.sh already spends three
# boots proving the rest. Making this one boot a desktop would cost most of
# that file's time and leave the tree with no fast signature check at all.
#
# Usage: tests/linux/hpm_signed_refresh.sh [seconds]
#
# It needs the network (255.one) and it builds a PRIVATE image — nothing under
# the shared build/image is written, per docs/steam_namespace.md §11.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

export HAMLINUX_VNC="${HAMLINUX_VNC:-none}"
# Nothing here enters a distribution namespace, but a build/image that has the
# distro media in it would otherwise be opened with an exclusive write lock and
# collide with any other VM on this host. Read-only, snapshot-backed.
export HAMLINUX_DISTRO_RO="${HAMLINUX_DISTRO_RO:-1}"
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
    # hamsh ECHOES the rc script it is running, comments and all, so the
    # console carries this file's own prose as well as the guest's output.
    # One of the phrases below ("an unsigned repo") appears in a comment two
    # dozen lines up, and matching it made this gate fail on a run in which
    # hpm had said nothing of the kind — a test failing on its own source
    # text is the same class of error as a program answering something
    # success-shaped: the string was there, it just was not evidence.
    # Echoed lines are prefixed "> "; only unprefixed lines are guest output.
    if grep -av '^> ' "$WORK/boot.log" | grep -aqE "$2"; then
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
