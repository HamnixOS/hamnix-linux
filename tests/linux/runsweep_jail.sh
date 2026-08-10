#!/usr/bin/env bash
# tests/linux/runsweep_jail.sh — the inside of one smoke test.
#
# Run by scripts/hamlinux_runsweep.sh as:
#
#   unshare -rmn --fork --pid --kill-child tests/linux/runsweep_jail.sh \
#       <base> <up> <work> <mnt> <prog> [argv...]
#
# We are already in a new USER namespace (uid 0 mapped to the invoking user), a
# new MOUNT namespace, a new NET namespace and a new PID namespace, so
# everything below is contained: nothing here can touch the host's filesystem,
# and the program under test cannot either. The pid namespace matters for a
# second reason -- this script is its init, so when the timeout kills us the
# kernel reaps every child the program spawned. Several of these programs fork
# servers, and a sweep that leaked one per application would leave a few
# hundred processes behind. The net namespace has only a down `lo` in it, so a
# program that reaches for the network finds none rather than reaching the
# user's real one.
#
# The shape, and why:
#
#   overlay(lower=<base>, upper=<up>)   The base root is staged ONCE and shared
#                                       read-only by every program; the upper
#                                       layer is per-program and empty at the
#                                       start, so afterwards it IS the diff --
#                                       exactly the set of files this program
#                                       created or changed. That is how the
#                                       sweep sees "created a file, left it
#                                       empty", which is this port's
#                                       characteristic failure and is invisible
#                                       from an exit status.
#
#   /proc, /sys                         /proc is a FRESH procfs for this pid
#                                       namespace; /sys is bind-mounted read-only
#                                       from the host, since `lsmod` and friends
#                                       read it and nothing should write it.
#
#   /dev                                NOT the host's /dev. Only null, zero,
#                                       full, tty, random and urandom are bound
#                                       in, one file at a time, onto empty
#                                       regular files staged in the base. A
#                                       program that opens /dev/sda, /dev/dri
#                                       or /dev/fb0 in here finds nothing --
#                                       which is the point, since this runs on
#                                       a real workstation.
#
# The synthetic devices (/dev/wsys, /net, /fd, /dev/fb) need no mount: they are
# served by user/linux-*.c out of shared files, and the HAM* environment set by
# the caller points them inside this root.
set -uo pipefail

BASE="$1"; UP="$2"; WRK="$3"; MNT="$4"; shift 4

mount --make-rprivate / 2>/dev/null

mount -t overlay hamsweep \
    -o "lowerdir=$BASE,upperdir=$UP,workdir=$WRK" "$MNT" || exit 125

# A FRESH procfs, not a bind of the host's: we are pid 1 of a new pid
# namespace, so the host's /proc would show this program a process table it is
# not in and pids that mean nothing to it.
mount -t proc proc "$MNT/proc" || mount --bind /proc "$MNT/proc" || exit 125
if [ -d "$MNT/sys" ]; then
    mount --bind /sys "$MNT/sys" 2>/dev/null \
        && mount -o remount,bind,ro "$MNT/sys" 2>/dev/null
fi

for d in null zero full tty random urandom; do
    [ -e "/dev/$d" ] || continue
    [ -e "$MNT/dev/$d" ] || continue
    mount --bind "/dev/$d" "$MNT/dev/$d" 2>/dev/null
done

# /dev/cons and /dev/console are symlinks to /proc/self/fd/1 in the base, so a
# program that writes to the console the Hamnix way lands on our captured
# stdout instead of vanishing. (An unbound /dev/cons is the exact shape of the
# `#d` bug in HANDOFF §0: the program runs, writes, exits 0, and the output is
# gone.)

exec unshare --root="$MNT" --wd=/work -- "$@"
