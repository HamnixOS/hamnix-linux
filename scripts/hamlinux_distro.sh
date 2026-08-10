#!/usr/bin/env bash
# scripts/hamlinux_distro.sh — build the Debian namespace filesystem.
#
# `bind '#distro' /n/distro` splices a Debian tree into the namespace, and
# `enter linux { }` makes it the process's root.  This builds what goes behind
# that: an ext4 image holding a Debian bookworm rootfs, on its OWN volume so
# that nothing Debian installs is ever written into the Hamnix filesystem.
# That separation is the entire reason for the design, and keeping it on a
# separate disk rather than a subdirectory is what makes it structural rather
# than a promise.
#
# UNPRIVILEGED.  mmdebstrap --mode=unshare --format=ext4 bootstraps straight
# into a filesystem image inside a user namespace: no sudo, no loop device, no
# host mount.  (An earlier version bootstrapped to a directory and then ran
# mke2fs -d over it, which fails on Debian's /var/lib/dpkg/lock-frontend --
# mode 000 and owned by a subuid the outer user cannot read.)
#
# WHAT GOES IN, and why each thing is there:
#   xvfb           an X server that scans out to a FILE, which is what
#                  user/xbridge.ad blits onto the Hamnix desktop.
#   firefox-esr    the browser the north star names.
#   xdotool        input injection: the compositor routes keys and clicks to
#                  the bridge's window, and this is what replays them into X.
#   x11-apps       xclock/xeyes, so the bridge can be proven without waiting
#                  for a browser to start.
#   matchbox-window-manager
#                  a WINDOW MANAGER. Without one, X places windows wherever
#                  they ask and never resizes them, so Firefox's main window
#                  and its session-restore window landed side by side, each
#                  clipped -- which looks exactly like a compositor bug and is
#                  not one. matchbox fullscreens whatever is on top, which is
#                  right here: the Hamnix compositor is already doing the
#                  window management, and the X session inside the bridge is
#                  one application's screen.
#   fonts, ca-certificates, dbus  what a browser refuses to be useful without.
#   gdisk, dosfstools, e2fsprogs, rsync, mtools
#                  THE INSTALLER'S TOOLS. Partitioning a disk and making an
#                  ext4 or a FAT filesystem are Linux-ecosystem jobs, and the
#                  Debian namespace is where Linux-ecosystem tools live -- the
#                  tree's own user/mkfs_ext4.ad is a thin wrapper around the
#                  HAMNIX kernel's /dev/blk ctl grammar and has no kernel to
#                  talk to here. So etc/install.hamsh reaches for them the way
#                  it would reach for a driver: `enter linux { mkfs.ext4 ... }`.
#                  That is the boundary docs/packages.md draws anyway -- hpm
#                  does not try to be apt, and Hamnix does not try to
#                  reimplement e2fsprogs.
#
# Usage: scripts/hamlinux_distro.sh [out.ext4] [size] [suite]
set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

OUT="${1:-build/image/distro.ext4}"
SIZE="${2:-6G}"
SUITE="${3:-bookworm}"
MIRROR="${HAMLINUX_MIRROR:-http://deb.debian.org/debian}"

command -v mmdebstrap >/dev/null || {
    echo "[distro] need mmdebstrap (apt install mmdebstrap)" >&2; exit 1; }

PKGS="xvfb,x11-apps,xdotool,x11-utils,matchbox-window-manager,\
firefox-esr,ca-certificates,dbus,fonts-dejavu-core,fonts-liberation,\
libgl1,libgtk-3-0,procps,coreutils,bash,less,nano,\
gdisk,dosfstools,e2fsprogs,rsync,mtools"

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"

echo "[distro] bootstrapping Debian $SUITE into $OUT ($SIZE)"
echo "[distro] this downloads a few hundred megabytes and takes a while"

# --format=ext4 needs the target to exist at the size we want.
truncate -s "$SIZE" "$OUT"

mmdebstrap \
    --mode=unshare \
    --format=ext4 \
    --variant=important \
    --include="$PKGS" \
    --components=main,contrib \
    --customize-hook='chroot "$1" sh -c "
        # A namespace, not a machine: no init, no services, no login. What it
        # needs is to be able to RUN a program when someone enters it.
        mkdir -p /tmp/xfb /run/dbus
        printf %s\\\\n \"hamnix-distro\" > /etc/hostname
        # The bridge and the browser meet here.
        cat > /usr/local/bin/hamnix-x <<EOS
#!/bin/sh
# Start the X server whose framebuffer user/xbridge.ad blits, then run the
# program given as arguments on it. Called from the Hamnix side inside
# \\\`enter linux { }\\\`.
: \\\${HAMX_W:=1024}
: \\\${HAMX_H:=768}
mkdir -p /tmp/xfb
Xvfb :0 -screen 0 \\\${HAMX_W}x\\\${HAMX_H}x24 -fbdir /tmp/xfb -nolisten tcp &
for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -e /tmp/xfb/Xvfb_screen0 ] && break
    sleep 0.5
done
DISPLAY=:0 matchbox-window-manager -use_titlebar no &
sleep 1
DISPLAY=:0 exec \"\\\$@\"
EOS
        chmod 755 /usr/local/bin/hamnix-x
    "' \
    "$SUITE" "$OUT" "$MIRROR"

echo "[distro] done: $OUT ($(du -h "$OUT" | cut -f1))"
echo "  attach it: scripts/hamlinux_vm.sh (picks it up automatically)"
