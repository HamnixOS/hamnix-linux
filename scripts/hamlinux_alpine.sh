#!/usr/bin/env bash
# scripts/hamlinux_alpine.sh — build the Alpine namespace filesystem.
#
# The SECOND distribution namespace, and the reason it exists is not that
# anyone needed Alpine: it is that one namespace is a special case that happens
# to work, and two is a mechanism. `enter alpine { sh }` and
# `enter debian { sh }` are the same verb with a different medium behind
# `#distro/<name>`, and nothing between them is compiled in -- see
# etc/distros.linux and the `#distro` block in user/linux-syscalls.c.
#
# WHY ALPINE AND NOT FEDORA OR ARCH.  Three reasons, in the order that decided
# it:
#
#   1. musl, NOT glibc.  This is the whole point.  Everything we might have
#      accidentally assumed about "a Linux root" while there was only Debian in
#      the tree -- the dynamic loader's name, /lib64, the NSS mechanism that
#      getpwuid() goes through, the shell being bash, `useradd` existing -- is
#      DIFFERENT here, so anything Debian-shaped in the plumbing fails rather
#      than being silently accommodated.  A Fedora namespace is glibc + a
#      different package manager; it would prove the package manager is not
#      hardcoded, which nothing here ever claimed.  Alpine is the sharper test.
#      (It found one, immediately: busybox has `adduser`, not `useradd`.)
#
#   2. It bootstraps UNPRIVILEGED with no distro-specific host tool.  Fedora
#      wants dnf --installroot (and rpm on the host); Arch wants pacstrap.
#      Alpine's minirootfs is a 3.7 MB tarball with `apk` already inside it, so
#      the build is: unpack, chroot in a user namespace, `apk add`.  No host
#      package was installed to make this work.  `mmdebstrap` had to be
#      installed for Debian; this needed nothing.
#
#   3. Size.  The Debian namespace is ~4.7 GB on disk with i386 multiarch.  If
#      the answer to "can I have another distribution?" is "another 5 GB", the
#      answer is really no.  This one is printed at the end of the script,
#      because that is the number somebody has to live with.
#
# UNPRIVILEGED, and how.  `unshare --map-auto --map-root-user -m` gives a user
# namespace with the whole /etc/subuid range mapped -- the full range and not
# just uid 0, because the tarball contains files owned by gid 42 (`shadow`) and
# a single-uid map cannot restore them: tar fails with `Cannot change ownership
# to uid 0, gid 42`.  Inside it we are root over our own mounts and can
# chroot(2), so `apk` runs as the Alpine root it expects.  `mke2fs -d` then
# copies the tree into an ext4 image FROM INSIDE that namespace, so the
# ownership it records is the ownership Alpine wants (0:0, 0:42) rather than
# the builder's.
#
# NO /proc IS MOUNTED for the chroot.  Mounting proc in this namespace returns
# EPERM (the namespace does not own a pid namespace), and apk does not need it.
# Said here rather than silently retried, because the next person will try.
#
# WHAT GOES IN:
#   the minirootfs      busybox, musl, apk.  `enter alpine { cat
#                       /etc/alpine-release }` needs only this.
#   the `live` user     uid 1001, because the DE session drops to 1001
#                       (etc/rc.de-user.linux) and a program entering this
#                       namespace arrives as 1001.  Without a passwd entry HERE
#                       getpwuid() fails inside, exactly as it did for Debian.
#                       Created with busybox `adduser`; there is no `useradd`.
#   --- the GUI set, HAMLINUX_ALPINE_GUI=0 to leave it out ---------------
#   xwayland            an X server that is itself a Wayland client.  It
#                       connects to wsyswl's socket placed inside THIS tree, so
#                       the window path is: X client -> Xwayland -> wsyswl ->
#                       /dev/wsys -> wsysd -> /dev/fb.  Identical to the Debian
#                       path and sharing none of its files.
#   xeyes, xclock       the GUI applications.  Deliberately tiny: what is being
#                       proven is that the WINDOW PATH is not Debian-specific,
#                       and a browser would prove that no better while taking
#                       400 MB to do it.
#   xkeyboard-config    NOT OPTIONAL, and Debian never had to say so.  Alpine's
#                       `xwayland` package depends on xkbcomp but not on the
#                       keymap DATA, so the server starts, fails to compile a
#                       keymap, and dies with `Failed to activate virtual core
#                       keyboard: 2` -- measured, first run of
#                       tests/linux/alpine_gui_run.sh: a clean console, a live
#                       Wayland socket, the right screen size, and a desktop
#                       with no window on it.  Debian's xwayland pulls
#                       xkb-data through its own dependencies, which is exactly
#                       the kind of thing only a second distribution finds.
#   xdpyinfo            so the session script can ask whether the X server is
#                       actually up instead of testing for a socket file --
#                       tests/linux/hamnix_x11session.sh's hardest-won line.
#   font-dejavu         xclock draws its numerals with a font or not at all.
#
#   jwm                 THE WINDOW MANAGER, and the SAME one Debian's
#                       namespace runs, with the SAME configuration file
#                       (etc/jwmrc.linux -> /etc/jwm/hamnix.jwmrc).  An
#                       earlier note here said Alpine had no window manager
#                       because "two clients do not need one" -- true for two
#                       clients and false for a desktop: with nothing managing
#                       the screen, nothing inside the namespace can move,
#                       resize, stack or close a window and every EWMH
#                       question comes back empty.
#                       IT IS NOT FREE HERE, and that is the honest difference
#                       between the two distributions.  In Debian jwm costs
#                       0.5 MiB and no new packages, because firefox-esr has
#                       already dragged in cairo, pango and librsvg.  Alpine
#                       has none of them, so jwm pulls 24 packages and
#                       22.0 MiB -- glib 5.1, librsvg 3.6, shared-mime-info
#                       2.4, harfbuzz 1.6.  Measured against this image's own
#                       /lib/apk/db/installed; docs/linux_window_manager.md
#                       has the table.  It is charged to the GRAPHICAL image
#                       only: HAMLINUX_ALPINE_GUI=0 is still 26 MiB and has no
#                       window manager because it has no X server either.
#                       fluxbox would be 8.9 MiB here and 61.7 MiB in Debian
#                       (bookworm's libimlib2 depends on libspectre1 depends
#                       on GHOSTSCRIPT), so choosing per-distribution would
#                       buy 13 MiB on one side, lose 61 MiB on the other, and
#                       give the two namespaces different window behaviour.
#                       One window manager, one configuration, both trees.
#
# Usage: scripts/hamlinux_alpine.sh [out.ext4] [size] [branch]
set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

OUT="${1:-build/image/alpine.ext4}"
# Sparse, like the Debian image: this costs nothing on the host until written.
# 2G is room for `apk add` inside the running system, not for the packages.
SIZE="${2:-2G}"
BRANCH="${3:-v3.24}"
REL="${HAMLINUX_ALPINE_REL:-3.24.1}"
MIRROR="${HAMLINUX_ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}"
# The GUI half, optional the way HAMLINUX_I386 is for Debian.
GUI="${HAMLINUX_ALPINE_GUI:-1}"
LABEL="${HAMLINUX_ALPINE_LABEL:-hamnix-alpine}"

TARBALL="alpine-minirootfs-${REL}-x86_64.tar.gz"
URL="$MIRROR/$BRANCH/releases/x86_64/$TARBALL"
CACHE="build/cache"
ROOTDIR="build/alpine-root"
mkdir -p "$CACHE" "$(dirname "$OUT")"

command -v unshare >/dev/null || { echo "[alpine] need unshare (util-linux)" >&2; exit 1; }
unshare --help 2>&1 | grep -q -- --map-auto || {
    echo "[alpine] this util-linux has no --map-auto; need >= 2.38" >&2; exit 1; }
command -v /sbin/mke2fs >/dev/null || { echo "[alpine] need e2fsprogs" >&2; exit 1; }
grep -q "^$(id -un):" /etc/subuid 2>/dev/null || {
    echo "[alpine] no /etc/subuid range for $(id -un); --map-auto cannot work" >&2
    exit 1; }

# --- the tarball, and its PUBLISHED checksum -------------------------------
# Alpine ships a .sha256 beside the image. Fetching and comparing is the whole
# of the verification; a wrong tarball here would be a wrong Alpine, silently.
if [ ! -f "$CACHE/$TARBALL" ]; then
    echo "[alpine] fetching $URL"
    curl -fL -o "$CACHE/$TARBALL.part" "$URL"
    mv "$CACHE/$TARBALL.part" "$CACHE/$TARBALL"
fi
WANT="$(curl -fsSL "$URL.sha256" | cut -d' ' -f1)"
GOT="$(sha256sum "$CACHE/$TARBALL" | cut -d' ' -f1)"
[ -n "$WANT" ] && [ "$WANT" = "$GOT" ] || {
    echo "[alpine] minirootfs sha256 mismatch (or no published sum)" >&2
    echo "  published $WANT" >&2
    echo "  got       $GOT" >&2
    exit 1; }
echo "[alpine] $TARBALL sha256 OK"

PKGS=""
if [ "$GUI" = 1 ]; then
    # xprop is NOT optional decoration. Without it the session's "is the window
    # manager actually managing this screen" check cannot ask the X server, and
    # the first Alpine run with jwm printed `WARNING jwm is not managing this
    # screen` at a screen jwm was plainly managing -- a decorated, titled
    # window in the screendump. A check that cannot run must say it cannot run;
    # it must never answer the question it failed to ask.
    PKGS="xwayland xkeyboard-config xeyes xclock xdpyinfo xprop font-dejavu jwm xterm"
fi

# The resolver. mmdebstrap copies the BUILD HOST's /etc/resolv.conf into the
# Debian image and that cost an evening (a nameserver unreachable from inside
# the VM, so every lookup timed out while the network was fine). Do not repeat
# it: write the guest's resolver explicitly.
cat > "$CACHE/alpine-resolv.conf" <<'EOF'
# hamnix-linux: the Alpine namespace's resolver.
# 10.0.2.3 is QEMU user-mode networking's DNS forwarder, and matches
# `ifconfig dns` in etc/rc.boot.linux.
nameserver 10.0.2.3
nameserver 1.1.1.1
EOF

# The in-namespace builder. Everything from here runs as root inside the user
# namespace; nothing outside it is touched.
cat > "$CACHE/alpine-build.sh" <<'BUILDEOF'
#!/bin/sh
set -eu
R="$1"; TGZ="$2"; OUT="$3"; SIZE="$4"; LABEL="$5"; RESOLV="$6"; JWMRC="$7"; shift 7
PKGS="$*"

rm -rf "$R"; mkdir -p "$R"
tar -C "$R" -xzf "$TGZ"
cp "$RESOLV" "$R/etc/resolv.conf"

# apk wants /dev/null and friends and there is no way to mknod in a user
# namespace. Bind the host's individual character devices onto empty files --
# never a directory, and never /dev/dri or anything else with hardware behind
# it. The mounts die with this namespace.
for d in null zero full random urandom; do
    [ -e "/dev/$d" ] || continue
    : > "$R/dev/$d"
    /usr/bin/mount --bind "/dev/$d" "$R/dev/$d"
done

if [ -n "$PKGS" ]; then
    echo "[alpine] apk add $PKGS"
    /usr/sbin/chroot "$R" /sbin/apk add --no-cache $PKGS
fi

# The window manager's configuration, and it is THE SAME FILE the Debian
# namespace gets. A window manager configured by each distribution's packaging
# default is two different window managers wearing one name.
if [ -r "$JWMRC" ]; then
    mkdir -p "$R/etc/jwm"
    cp "$JWMRC" "$R/etc/jwm/hamnix.jwmrc"
fi

/usr/sbin/chroot "$R" /bin/sh -eu <<'INEOF'
# chroot(2) does not change $PATH, so without this the shell inside is still
# looking down the HOST's PATH and busybox's own applets are invisible:
# `adduser: not found`, in a root that plainly has it.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
# A namespace, not a machine: no init, no services, no login. What it needs is
# to be able to RUN a program when someone enters it.
printf '%s\n' hamnix-alpine > /etc/hostname
# uid 1001 is the DE session's `live`. busybox has adduser, not useradd -- the
# first thing musl-userland Alpine broke that was Debian-shaped.
id live >/dev/null 2>&1 || adduser -D -u 1001 -h /home/live -s /bin/sh live
mkdir -p /home/live && chown 1001:1001 /home/live
mkdir -p /run /tmp/.X11-unix
chmod 1777 /tmp

# The X session, baked in rather than planted with debugfs after the fact.
# It is the Alpine twin of tests/linux/hamnix_x11session.sh and it is
# deliberately SHORTER: no dbus (nothing in this set asks for a bus), no Steam.
# It runs the SAME window manager on the SAME configuration file, though --
# a namespace whose windows behave differently depending on which distribution
# is behind it would make "does this work in the namespace" a question with
# two answers.
# What it keeps is the two lines that were paid for in the Debian one.
# ...but only when there is an X server for it to start. A HAMLINUX_ALPINE_GUI=0
# image that shipped this script would answer `hamnix-x11session` with a
# not-found from somewhere three levels down instead of not having it.
if command -v Xwayland >/dev/null 2>&1; then
cat > /usr/local/bin/hamnix-x11session <<'XEOF'
#!/bin/sh
# hamnix-x11session (Alpine) — an X11 session on top of the Hamnix Wayland
# server. wsyswl runs OUTSIDE this namespace and puts its socket at
# /n/alpine/run/wayland-0, which this tree -- whose root IS that tree -- sees
# as the ordinary /run/wayland-0. That is the whole of the crossing: a name.
set -u
# EVERYTHING THIS SCRIPT SAYS GOES TO A FILE INSIDE THE TREE, and the file is
# readable from the Hamnix side as /n/alpine/tmp/session.log. A spawned
# program's stderr stops reaching the console partway through -- measured: the
# `socket` and `screen` lines arrived and `Xwayland up`/`FAILED TO START`, one
# of which must have been printed, did not. Half a diagnostic is worse than
# none, because it reads as "it got that far and then hung".
exec >>/tmp/session.log 2>&1
echo "=== hamnix-x11session $(date) ==="
export XDG_RUNTIME_DIR=/run
export WAYLAND_DISPLAY=wayland-0
case "${HOME:-}" in ""|"/") HOME=/home/live ;; esac
[ -d "$HOME" ] || HOME=/root
export HOME

echo "hamnix-x11session(alpine): socket $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"
ls -l "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" || \
    echo "hamnix-x11session(alpine): NO WAYLAND SOCKET"

# This tree is on an ext4 and survives reboots, so an X server killed by a
# power cut leaves its lock behind for ever after and the next boot dies with
# "Server is already active for display 0".
rm -f /tmp/.X0-lock /tmp/.X11-unix/X0 2>/dev/null
mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix

# HOW BIG IS THE X SCREEN. Alpine ships Xwayland 24.1, and a rootful Xwayland
# stopped taking its size from the wl_output at 23.1 -- it comes up 640x480 no
# matter what the compositor advertises. wsyswl publishes the real geometry as
# a file beside its socket; that file is the second name that crosses, and on
# THIS distribution it is not optional the way it was on bookworm's 22.1.9.
GEOM=""
if [ -r "$XDG_RUNTIME_DIR/hamnix-screen" ]; then
    read -r SW SH < "$XDG_RUNTIME_DIR/hamnix-screen" || true
    case "${SW:-}:${SH:-}" in
        [1-9]*:[1-9]*)
            if Xwayland -help 2>&1 | grep -q -- '-geometry'; then
                GEOM="-geometry ${SW}x${SH}"
                echo "hamnix-x11session(alpine): screen ${SW}x${SH}"
            fi ;;
    esac
else
    echo "hamnix-x11session(alpine): WARNING no hamnix-screen file; the X screen size is Xwayland own default, not the display's"
fi

# shellcheck disable=SC2086
Xwayland -shm -noreset $GEOM :0 >/tmp/xwayland.log 2>&1 &
XWPID=$!
echo "hamnix-x11session(alpine): Xwayland started as pid $XWPID; polling"
# WAIT FOR THE SERVER, NOT FOR THE SOCKET: a socket file is not a server, and
# the stale one above outlived the process that made it.
#
# EVERY PROBE IS UNDER `timeout`. xdpyinfo against a socket whose server is not
# accepting does not fail, it BLOCKS in connect() -- measured: this loop, bound
# at 15 s of sleeps, was still in it 45 s later, and the only symptom was a
# session log that stopped after `polling`. A probe that can hang is not a
# probe.
up=0
i=0
while [ $i -lt 20 ]; do
    if timeout 3 env DISPLAY=:0 xdpyinfo >/tmp/xdpyinfo.log 2>&1; then up=1; break; fi
    kill -0 "$XWPID" 2>/dev/null || break
    i=$((i+1)); sleep 0.5
done
echo "hamnix-x11session(alpine): after $i polls, X server confirmed=$up"
echo "hamnix-x11session(alpine): sockets in /tmp/.X11-unix:"
ls -la /tmp/.X11-unix 2>&1 || true
if [ "$up" = 1 ]; then
    grep -E 'dimensions|depth of root' /tmp/xdpyinfo.log || true
else
    # NOT FATAL. The measurement that matters is the screendump, and refusing
    # to start the client because a probe could not confirm the server would
    # replace a picture with an opinion. Say what is unknown and carry on.
    echo "hamnix-x11session(alpine): could NOT confirm the X server; starting"
    echo "  the client anyway -- the screendump is the measurement. Xwayland is"
    kill -0 "$XWPID" 2>/dev/null && echo "  alive (pid $XWPID)." || echo "  GONE."
    tail -20 /tmp/xwayland.log 2>&1 || true
fi

export DISPLAY=:0

# THE WINDOW MANAGER. Same one as Debian's namespace, same configuration file.
# Not "none": rootful Xwayland does composite its clients onto its own root
# window, but that root window is not managed by anybody, so nothing in here
# can move, resize, stack or close what is on it -- and _NET_SUPPORTED comes
# back with zero atoms to any client that asks.
if command -v jwm >/dev/null 2>&1; then
    if [ -r /etc/jwm/hamnix.jwmrc ]; then
        jwm -f /etc/jwm/hamnix.jwmrc >/tmp/wm.log 2>&1 &
    else
        echo "hamnix-x11session(alpine): WARNING no /etc/jwm/hamnix.jwmrc; jwm will use its built-in defaults"
        jwm >/tmp/wm.log 2>&1 &
    fi
    sleep 2
    # Starting is not managing -- ask the X server, not the process table.
    # And DO NOT ANSWER A QUESTION THAT COULD NOT BE ASKED: without xprop this
    # said "not managing" about a screen jwm was managing, which is the exact
    # failure mode this whole check exists to catch, committed by the check.
    if ! command -v xprop >/dev/null 2>&1; then
        echo "hamnix-x11session(alpine): cannot check whether jwm has the screen -- no xprop in this image"
    elif timeout 3 xprop -root _NET_SUPPORTING_WM_CHECK 2>/dev/null | grep -q 'window id'; then
        echo "hamnix-x11session(alpine): jwm has the screen: $(timeout 3 xprop -root _NET_SUPPORTED 2>/dev/null | sed 's/.*= //' | tr ',' '\n' | wc -l) _NET_SUPPORTED atoms, workarea $(timeout 3 xprop -root _NET_WORKAREA 2>/dev/null | sed 's/.*= //')"
    else
        echo "hamnix-x11session(alpine): WARNING jwm is not managing this screen; its log:"
        cat /tmp/wm.log 2>&1
    fi
else
    echo "hamnix-x11session(alpine): ERROR no jwm in this namespace -- nothing will be movable. apk add jwm"
fi

# THE CLIENT'S OWN OUTPUT GOES TO A FILE. It is the one thing that explains a
# black X root window, and a spawned program's stderr does not reliably reach
# the Hamnix console across the namespace boundary -- the first run of
# tests/linux/alpine_gui_run.sh printed a completely clean log for an X server
# that had died on its keymap. /n/alpine/tmp/client.log is readable from
# outside, which is what makes it worth writing.
set +e
if [ $# -eq 0 ]; then set -- xeyes -geometry 400x300+40+40; fi
echo "hamnix-x11session(alpine): exec $*"
"$@" >/tmp/client.log 2>&1
rc=$?
echo "hamnix-x11session(alpine): client exited $rc" >> /tmp/client.log
exit $rc
XEOF
chmod 755 /usr/local/bin/hamnix-x11session
fi
INEOF

# Unmount the device binds before imaging, or mke2fs -d copies the HOST's
# /dev/urandom into the image as a regular file and reads it for ever.
for d in null zero full random urandom; do
    /usr/bin/umount "$R/dev/$d" 2>/dev/null || true
done

rm -f "$OUT"
truncate -s "$SIZE" "$OUT"
# -d copies the tree in with the ownership visible HERE, which is Alpine's.
# -F because the target is a regular file, not a block device.
/sbin/mke2fs -q -F -t ext4 -L "$LABEL" -d "$R" "$OUT"
BUILDEOF
chmod 755 "$CACHE/alpine-build.sh"

echo "[alpine] bootstrapping Alpine $BRANCH ($REL) into $OUT ($SIZE)"
[ "$GUI" = 1 ] && echo "[alpine] GUI set: $PKGS" \
               || echo "[alpine] GUI set omitted (HAMLINUX_ALPINE_GUI=0)"

PREV_SZ=0
[ -f "$OUT" ] && PREV_SZ="$(du -m "$OUT" | cut -f1)"

unshare --map-auto --map-root-user -m --propagation private \
    /bin/sh "$CACHE/alpine-build.sh" \
        "$PROJ_ROOT/$ROOTDIR" "$PROJ_ROOT/$CACHE/$TARBALL" \
        "$PROJ_ROOT/$OUT" "$SIZE" "$LABEL" \
        "$PROJ_ROOT/$CACHE/alpine-resolv.conf" "$PROJ_ROOT/etc/jwmrc.linux" $PKGS

/sbin/e2fsck -fp "$OUT" >/dev/null 2>&1 || true
NEW_SZ="$(du -m "$OUT" | cut -f1)"
TREE_SZ="$(du -sm "$ROOTDIR" | cut -f1)"

echo "[alpine] done: $OUT"
echo "[alpine] volume label: $LABEL   (that is the NAME /etc/distros resolves)"
echo "[alpine] rootfs tree: ${TREE_SZ} MiB   image on disk: ${NEW_SZ} MiB (sparse, apparent $SIZE)"
if [ "$PREV_SZ" -gt 0 ]; then
    echo "[alpine] size: ${PREV_SZ} MiB -> ${NEW_SZ} MiB (delta $((NEW_SZ - PREV_SZ)) MiB)"
fi
echo "  attach it: scripts/hamlinux_vm.sh (picks it up automatically)"
echo "  enter it:  enter alpine { cat /etc/alpine-release }"
