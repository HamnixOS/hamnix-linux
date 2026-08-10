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
#   fonts, ca-certificates, dbus  what a browser refuses to be useful without.
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

PKGS="xvfb,x11-apps,xdotool,x11-utils,firefox-esr,ca-certificates,dbus,\
fonts-dejavu-core,fonts-liberation,libgl1,libgtk-3-0,procps,coreutils,\
bash,less,nano"

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
DISPLAY=:0 exec \"\\\$@\"
EOS
        chmod 755 /usr/local/bin/hamnix-x
    "' \
    "$SUITE" "$OUT" "$MIRROR"

echo "[distro] done: $OUT ($(du -h "$OUT" | cut -f1))"
echo "  attach it: scripts/hamlinux_vm.sh (picks it up automatically)"
