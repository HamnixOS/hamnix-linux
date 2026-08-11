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
#
# THE COMPOSITOR (RUNSWEEP_WSYSD=/bin/wsysd)
# ------------------------------------------
# A GUI program with no compositor is not being tested, it is being watched
# fail: lib/hamscreen.ad asks /dev/wsys/screen for the geometry and REFUSES TO
# GUESS when nobody has published one, so hamlock, hampanelscene, hamshotui,
# hamtoast and wsyswl all died on "no screen geometry" -- correctly, and with
# nothing measured. So the jail can bring up the real compositor, offscreen,
# in THIS namespace, before the program under test:
#
#   wsysd  ->  HAMFB_FILE (a plain file, no display, no DRM master)
#          ->  writes "screen W H" to /dev/wsys/ctl, which is what the client
#              is waiting for
#
# It has to be started HERE and not by the caller, because everything that
# makes the two processes see the same window system is inside this mount
# namespace: /srv/wsys, /srv/wsys.bb, /srv/wsys.img and /run/fb.raw are all in
# the per-program overlay upper layer. That is also the per-run isolation
# docs/steam_namespace.md §11 demands, obtained for free -- those four files
# default to ONE PER HOST, and a sweep that ran hundreds of programs against
# one segment would hand each program the previous one's windows.
#
# The program under test is NOT exec'd in this mode. We stay pid 1 so that:
#   * the compositor is a CHILD of pid 1, so when we exit the pid namespace
#     dies and the kernel reaps it -- a leaked wsysd per GUI program would be
#     a few hundred compositors;
#   * a program that exits promptly (`hamdesktop --scene-dump`) still gets a
#     frame composited after its last commit, which is what the caller's
#     framebuffer comparison reads.
#
# If the compositor cannot come up, this exits 125 (HARNESS_FAIL) and says so.
# Reporting "no screen geometry" for a run in which the harness failed to
# start the compositor would be the sweep manufacturing its own result.
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

WSYSD="${RUNSWEEP_WSYSD:-}"
WINPROBE="${RUNSWEEP_WINPROBE:-}"
FBSNAP="${RUNSWEEP_FBSNAP:-}"
if [ -z "$WSYSD" ] && [ -z "$WINPROBE" ]; then
    exec unshare --root="$MNT" --wd=/work -- "$@"
fi

# ---- with a compositor and/or a window probe ------------------------------
WPID=""
if [ -n "$WSYSD" ]; then
if [ ! -x "$MNT$WSYSD" ]; then
    echo "runsweep_jail: $WSYSD is not in the staged root -- cannot compose" >&2
    exit 125
fi
WLOG="${RUNSWEEP_WSYSD_LOG:-/dev/null}"
unshare --root="$MNT" --wd=/work -- "$WSYSD" </dev/null >"$WLOG" 2>&1 &
WPID=$!

# THE READINESS SIGNAL IS THE COMPOSITOR'S OWN ANNOUNCEMENT, not a sleep and
# not the existence of the framebuffer file: fbfile_try() ftruncate(2)s
# HAMFB_FILE to its full size the moment it opens it, so `[ -s fb.raw ]` is
# true before a single pixel has been composed. user/wsysd.ad prints
# "wsysd: screen WxH" immediately after read_screen() and immediately before
# announce_screen(), so that line is the fact we are waiting for.
#
# lib/hamscreen.ad then waits another 10 s of its own, so the residual race
# between the print and the ctl write cannot lose. What this loop is for is
# the case where the compositor DIES -- and it reports that instead of leaving
# the client to time out against a corpse.
ready=0
for _ in $(seq 1 100); do
    if [ "$WLOG" != /dev/null ] && grep -q '^wsysd: screen ' "$WLOG" 2>/dev/null; then
        ready=1; break
    fi
    kill -0 "$WPID" 2>/dev/null || break
    sleep 0.1
done
if [ "$ready" != 1 ]; then
    echo "runsweep_jail: the compositor never published a screen geometry" >&2
    [ "$WLOG" != /dev/null ] && sed 's/^/runsweep_jail: wsysd: /' "$WLOG" >&2
    kill -9 "$WPID" 2>/dev/null
    exit 125
fi
fi

# THE WINDOW PROBE, ASKED WHILE THE OWNER IS STILL ALIVE.
#
# It used to be asked afterwards, from a SEPARATE run of this jail, and it was
# only ever answered by accident. user/linux-wsys.c's win_reap_dead() -- "a
# window whose owner is gone is not a window" -- runs on every read that
# enumerates windows and frees any window whose pid answers ESRCH. Each jail
# run is its own PID NAMESPACE, so the pids stamped in the shared segment mean
# nothing in the probe's, and every window should have been reaped. It was not,
# for one reason: the program under test was `exec`ed and so was PID 1, the
# probe's own shell is PID 1 in ITS namespace, and kill(1, 0) succeeds. The
# column read "1 window" because pid 1 exists, not because a window did --
# measured here by moving the client off pid 1, at which point every gui row
# reported wins 0 while its pixels were plainly on the framebuffer.
#
# So the probe now runs INSIDE the program's own pid namespace, as a sibling,
# WHILE IT IS STILL RUNNING, sampling once a second and keeping the richest
# listing it ever saw. That answers the question the column was always meant
# to ask -- did this program own a window at any point while it was alive --
# and it no longer depends on a pid collision to do it.
# THE FRAMEBUFFER IS SAMPLED HERE TOO, AND FOR THE SAME REASON.
#
# Reading the final frame out of the overlay afterwards looks equivalent and is
# not: when a client exits, win_reap_dead() frees its window and the compositor
# repaints the screen WITHOUT it, so the last frame of a program that finished
# is the bare screen and the pixel count comes out zero. Measured on
# user/hamtoast.ad, which maps a toast, shows it, and exits 0 after five
# seconds: end-of-run fbpx 0, i.e. "put nothing on the screen", for a program
# that had. So the frame kept is the last one in which the program OWNED A
# WINDOW -- the screen as it was while the program was on it.
probe_once() {
    [ -x "$MNT/bin/cat" ] || return
    unshare --root="$MNT" --wd=/work -- /bin/cat /dev/wsys 2>/dev/null \
        > "$WINPROBE.now"
    n=$(grep -c '^[0-9][0-9]*$' "$WINPROBE.now" 2>/dev/null)
    [ -z "$n" ] && n=0
    if [ "$n" -gt "$best" ]; then best="$n"; cp "$WINPROBE.now" "$WINPROBE"; fi
    if [ "$n" -gt 0 ] && [ -n "$FBSNAP" ] && [ -s "$MNT/run/fb.raw" ]; then
        cp "$MNT/run/fb.raw" "$FBSNAP" 2>/dev/null
    fi
    cpu_sample
}

# WHAT THE PROGRAM ITSELF COST, sampled from the outside while it runs.
#
# The sweep's cpu column is bash's `times` delta, which is REAPED-CHILD time,
# and it has a hole exactly where the window system lives: `unshare
# --kill-child` SIGKILLs the subtree, nothing wait(2)s for it, and the column
# prints `-`. Every daemon and every scene client that stays up -- which is
# nearly all of them -- therefore reported NO COST AT ALL, and a GUI client
# that spins is indistinguishable from one that parks. That is THE IDLE
# CENSUS's own failure mode (HANDOFF §0), left standing in the column written
# to catch it.
#
# So: utime+stime out of /proc, for the program and the children it has
# reaped, sampled in the same once-a-second loop. It is the PROGRAM's cost and
# not the harness's -- the compositor is a different pid and is not counted,
# which also stops a busy client's repaints being charged to it or its own
# spin being hidden behind the compositor's park.
cpu_sample() {
    [ -n "$WINPROBE" ] || return
    local tot=0 c v
    for c in $(pgrep -P "$CPID" 2>/dev/null); do
        v=$(awk '{print $14+$15+$16+$17}' "/proc/$c/stat" 2>/dev/null)
        [ -n "$v" ] && tot=$((tot + v))
    done
    [ "$tot" -gt 0 ] && echo "$tot" > "$WINPROBE.cpu"
}

# `<&0` is not a no-op: POSIX redirects an asynchronous command's stdin from
# /dev/null before any explicit redirection, and the recipes table feeds some
# of these programs a file. An explicit redirection is what takes it back.
unshare --root="$MNT" --wd=/work -- "$@" <&0 &
CPID=$!

if [ -n "$WINPROBE" ]; then
    best=0
    : > "$WINPROBE"
    rm -f "$WINPROBE.cpu" "$WINPROBE.after"
    # A first sample after a second, then once a second for as long as the
    # program lives. lib/hamwid.ad's map handshake is 20 x 100 ms, so a client
    # that maps at all has done so by the second sample.
    while kill -0 "$CPID" 2>/dev/null; do
        sleep 1
        kill -0 "$CPID" 2>/dev/null || break
        probe_once
    done
    wait "$CPID"; rc=$?
    # One last look after it exited. A window still in the table here belongs
    # to a process that is GONE, which is a leak and not a pass -- it is not
    # allowed to raise `best`, and it is recorded separately so the sweep can
    # say so.
    probe_after="$(unshare --root="$MNT" --wd=/work -- /bin/cat /dev/wsys 2>/dev/null \
                   | grep -c '^[0-9][0-9]*$')"
    echo "${probe_after:-0}" > "$WINPROBE.after"
    rm -f "$WINPROBE.now"
else
    wait "$CPID"; rc=$?
fi

# One settle interval so the compositor composes the program's LAST commit
# before we exit and the kernel kills it. A client that runs to the timeout
# never reaches this line and does not need to: it has had the whole run.
if [ -n "$WPID" ]; then
    sleep "${RUNSWEEP_WSYSD_SETTLE:-0.6}"
    kill -9 "$WPID" 2>/dev/null
fi
exit "$rc"
