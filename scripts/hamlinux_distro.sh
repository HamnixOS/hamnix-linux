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
#   xwayland       X11 apps as Wayland clients.  The design's phase 4: one
#                  protocol implemented, and X11 comes free -- XWayland is an
#                  X server that is itself a Wayland client.  Needs -shm (the
#                  pure-pixman screen; the default glamor path wants GL) and
#                  -noreset (or the server resets when its last client exits
#                  and tears the Wayland surface down with it).
#   jwm            THE WINDOW MANAGER, and the third answer this line has had.
#                  matchbox-window-manager was the first and is convicted: it
#                  is a single-window handheld WM that takes over every
#                  MapRequest, and with it running the X root has ONE child --
#                  its own 5x5 check window -- and Steam's login dialog reads
#                  IsUnMapped. No window manager at all was the second, and it
#                  is right for a session running one application and wrong
#                  for a desktop: nothing inside the namespace can then move,
#                  resize, stack or close a window, and every EWMH question
#                  comes back empty.
#                  jwm reparents, draws a real title bar, and publishes 66
#                  _NET_SUPPORTED atoms (measured; openbox publishes 85 and
#                  costs 57.9 MiB here, because bookworm's libimlib2 depends
#                  on libspectre1 which depends on GHOSTSCRIPT).
#                  IT COSTS 0.5 MiB AND NOT ONE NEW PACKAGE: all sixteen of
#                  its dependencies -- cairo, pango, librsvg, Xft, Xpm, Xmu --
#                  are already here because firefox-esr and GTK dragged them
#                  in. It wants no D-Bus, no settings daemon and no session
#                  manager, which is what rules out marco, xfwm4 and metacity
#                  whatever their size. docs/linux_window_manager.md has the
#                  measured table for every candidate.
#                  Its configuration is OURS -- etc/jwmrc.linux, copied in
#                  below as /etc/jwm/hamnix.jwmrc. Debian's default
#                  /etc/jwm/system.jwmrc launches its own xclock into a tray
#                  and vertically maximises xterms, which is the same class of
#                  behaviour matchbox was thrown out for.
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
#   --- the Steam-class set, added because the owner asked for large apps ---
#   i386 MULTIARCH  Steam's bootstrap (`ubuntu12_32/steam`) is an ELF 32-bit
#                  i386 dynamic binary and there is no 64-bit build of it, so
#                  the namespace has to be a multiarch namespace or the top
#                  of the Steam stack cannot be exec'd at all.  This is
#                  `--architectures=amd64,i386`, which is mmdebstrap's way of
#                  saying `dpkg --add-architecture i386` before the first
#                  package is unpacked rather than after.
#                  IT IS NOT FREE: the i386 Mesa (libgl1-mesa-dri:i386 plus
#                  mesa-vulkan-drivers:i386) is the single largest thing in
#                  this image after clang.  The size delta is printed at the
#                  end of this script, because this is a distro and it matters.
#   steam-installer  Debian's contrib wrapper.  It is NOT Steam: it is a shell
#                  script at /usr/games/steam that downloads Valve's
#                  bootstrap and unpacks it into $HOME.  Its dependency list
#                  (steam-libs:i386) is the authoritative statement of what a
#                  32-bit Steam needs from the host system, which is why it is
#                  used here instead of a hand-written list.
#   the bootstrap, PRE-SEEDED
#                  /usr/games/steam's first run pops a zenity dialog and then
#                  curls repo.steampowered.com.  Both are staged in here at
#                  build time instead (/opt/hamnix-steam/bootstrap.tar.xz,
#                  sha256-verified on the host), so first run inside the VM
#                  needs neither a GUI prompt nor that round trip.  What it
#                  still needs is the network, because the ~300 MB Steam
#                  CLIENT is downloaded by the bootstrap from Valve's CDN and
#                  nothing in this image can pre-empt that.
#   mesa-utils:i386, vulkan-tools:i386
#                  the representative 32-bit graphics clients: glxgears and
#                  glxinfo (GLX/X11), vkcube and vulkaninfo (Vulkan, X11 and
#                  Wayland).  Deliberately the i386 build of each and not the
#                  amd64 one -- an amd64 glxgears proves nothing about the
#                  32-bit path, and the 32-bit path is the one Steam is on.
#   bubblewrap     what Steam's sniper/soldier container runtimes (pressure-
#                  vessel) call to build a game's container.  Installed so the
#                  question can be ANSWERED rather than guessed at; see
#                  docs/steam_namespace.md for what the answer turned out to
#                  be.
#   pulseaudio, libpulse0:i386
#                  Steam expects a sound server.  The client-side library is
#                  what Steam links; the server is here so that the missing
#                  piece is provably the DEVICE and not the userland.
#   the `live` user (uid 1001)
#                  the DE session drops to uid 1001 (etc/rc.de-user.linux), so
#                  a program entering this namespace arrives as 1001 with
#                  $HOME=/home/live.  Without a matching passwd entry HERE,
#                  getpwuid(getuid()) fails inside the namespace and Steam --
#                  which uses it to find its own data directory -- does not
#                  start.  Nothing announces this; the account is created so
#                  it cannot happen.
#   clang, libssl-dev
#                  THE COMPILER'S SECOND HALF, and the reason hamnix-linux can
#                  compile Adder on itself.  `ac foo.ad` (user/ac.ad) runs
#                  host_ac natively to emit LLVM IR and then runs clang IN HERE
#                  to optimise, codegen and link it -- the same split, and the
#                  same boundary, as mkfs.ext4 above.  clang is a Debian binary
#                  whichever directory it is copied into, so it lives with the
#                  other Debian binaries rather than being renamed native.
#                  It costs about 300 MB on THIS volume (clang + libclang-cpp +
#                  libllvm + libc6-dev + binutils), and it is baked in rather
#                  than left to `apt install` because a machine that needs a
#                  network and a mirror before it can build a program is not
#                  self-hosting.  libssl-dev is what makes /net's `tls` verb
#                  compile into what the user builds; without it a program that
#                  asks for TLS gets an ERROR rather than a plaintext socket.
#
# Usage: scripts/hamlinux_distro.sh [out.ext4] [size] [suite]
set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

OUT="${1:-build/image/distro.ext4}"
# 6G was the pre-multiarch size and it does not fit any more: the i386 Mesa
# alone is most of a gigabyte.  The file is SPARSE, so this costs nothing on
# the host until it is written to.
SIZE="${2:-12G}"
SUITE="${3:-bookworm}"
MIRROR="${HAMLINUX_MIRROR:-http://deb.debian.org/debian}"
# Set HAMLINUX_I386=0 for the old single-architecture image (no Steam).
I386="${HAMLINUX_I386:-1}"

command -v mmdebstrap >/dev/null || {
    echo "[distro] need mmdebstrap (apt install mmdebstrap)" >&2; exit 1; }

# xterm is in the BASE list, not only in the Steam set: jwm's first dependency
# is `rxvt-unicode | gnome-terminal | konsole | x-terminal-emulator`, and with
# nothing providing x-terminal-emulator apt satisfies it by installing
# rxvt-unicode -- a second terminal emulator nobody asked for, in the
# single-architecture image only, where it would be very easy not to notice.
PKGS="xvfb,x11-apps,xdotool,x11-utils,jwm,xterm,matchbox-window-manager,\
firefox-esr,xwayland,ca-certificates,dbus,dbus-x11,fonts-dejavu-core,fonts-liberation,\
libgl1,libgtk-3-0,procps,coreutils,bash,less,nano,\
gdisk,dosfstools,e2fsprogs,rsync,mtools,\
clang,libssl-dev,libdrm-dev,libcrypt-dev,\
libgl1-mesa-dri,libglx-mesa0,libvulkan1,mesa-vulkan-drivers,\
curl,file,xz-utils,strace,psmisc,net-tools,iputils-ping"

ARCHS="amd64"
if [ "$I386" = 1 ]; then
    ARCHS="amd64,i386"
    # steam-installer pulls steam-libs:i386, which is Debian's own statement of
    # the 32-bit closure.  The rest are steam-libs' Recommends -- mmdebstrap
    # does not install Recommends, and every one of these is a library Steam
    # dlopen()s for graphics or input rather than an optional extra.
    #
    # yad, NOT zenity -- THE CONSENT DIALOG, WITHOUT A BROWSER ENGINE.
    #
    #   WHAT ASKS FOR IT.  /usr/games/steam -- the shell script steam-installer
    #   itself installs -- asks for consent before installing proprietary
    #   software, and it does so exactly when its four `needed` paths under
    #   $STEAMDIR are missing:
    #
    #       for needed in steam.sh ubuntu12_32/steam \
    #                     ubuntu12_32/steam-runtime/run.sh setup.sh
    #           [ -x "$STEAMDIR/$needed" ] || new_installation=yes
    #       if [ -n "$new_installation" ]; then ... "$zenityish" --question ...
    #
    #   and $zenityish is chosen by that script, not by us:
    #
    #       if [ -x /usr/bin/zenity ]; then zenityish=zenity
    #       elif [ -x /usr/bin/yad ]; then zenityish=yad
    #       else echo "Installation cancelled"; exit 1
    #
    #   So yad is a path Valve's packager already supports, and the failure
    #   mode of installing NEITHER is a person meeting "Installation
    #   cancelled" with no explanation.  A grep of OUR tree could never have
    #   found any of this: the caller is a Debian shell script in here.
    #
    #   WHY IT IS REACHED AT ALL.  /usr/local/bin/hamnix-steam pre-stages
    #   exactly those four paths, so the INTENDED path never sees the dialog.
    #   A person who runs /usr/games/steam directly, or whose $HOME differs
    #   from the one the wrapper staged into, does -- which is why this is a
    #   swap and not a deletion.
    #
    #   WHAT THE SWAP RETURNED, measured with scripts/hamlinux_distro_audit.sh
    #   before and after a real rebuild: PENDING-MEASUREMENT.
    #   zenity is 167 KiB and drags
    #   a WEB BROWSER in behind it: libwebkit2gtk-4.1-0 (90.4 MiB),
    #   libjavascriptcoregtk-4.1-0 (31.2), zenity-common (11.2) -- 133 MiB of
    #   core that nothing else installed depended on -- plus WebKit's media
    #   and spell-check tail (libflite1, a 26.9 MiB speech synthesiser; the
    #   gstreamer plugin sets; hunspell) for 195 MiB of private closure.  yad
    #   is 570 KiB against GTK alone.  libgtk-3-0 is in neither number:
    #   firefox-esr needs it and it stays whatever happens here.
    #
    #   IT IS NOT THE BIGGEST THING IN HERE, and the two bigger ones are not
    #   bugs.  LLVM/clang is 494.6 MiB in three copies -- libllvm15:amd64 for
    #   Mesa, libllvm15:i386 for the 32-bit Mesa Steam runs on, libllvm14 for
    #   clang -- and every one of them is load-bearing; see the `clang` note
    #   at the top of this file.  firefox-esr is 270.7 MiB and is the north
    #   star.  The largest number of all is not software: the FILE is
    #   provisioned at 12 GiB and 10 of that is empty space for Steam's
    #   client and a game, which no package change moves.
    PKGS="$PKGS,steam-installer,yad,xdg-utils,bubblewrap,\
pulseaudio,libasound2-plugins,\
mesa-utils:i386,vulkan-tools:i386,mesa-utils-bin,\
libgl1:i386,libgl1-mesa-dri:i386,libglx-mesa0:i386,libegl1:i386,libgbm1:i386,\
libvulkan1:i386,mesa-vulkan-drivers:i386,\
libx11-6:i386,libx11-xcb1:i386,libxext6:i386,libxfixes3:i386,libxdamage1:i386,\
libxrandr2:i386,libxcursor1:i386,libxcomposite1:i386,libxinerama1:i386,\
libxi6:i386,libxss1:i386,libxxf86vm1:i386,libxtst6:i386,\
libsdl2-2.0-0:i386,libasound2:i386,libpulse0:i386,libnss3:i386,\
libfontconfig1:i386,libfreetype6:i386,libexpat1:i386,libdbus-1-3:i386"
fi

# --- Valve's bootstrap, staged on the HOST ---------------------------------
# /usr/games/steam does exactly this at first run, and the version, URL and
# sha256 are read off that script rather than invented here.  Doing it now
# means the first `steam` inside the VM does not need a GUI prompt or a round
# trip to repo.steampowered.com.  NOTHING is installed on the host: the
# tarball is unpacked into the image and never executed here.
STEAM_VER=1.0.0.75
STEAM_DEBVER="${STEAM_VER}+ds-5"
STEAM_SHA=e52565a5e33b9a4184c5bdc222978b7fea958efd32641d5d5967774d751236a7
STEAM_URL="https://repo.steampowered.com/steam/archive/stable/steam_${STEAM_VER}.tar.gz"
CACHE="build/cache"
STAGE="build/distro-stage"
mkdir -p "$CACHE" "$STAGE/opt/hamnix-steam" "$STAGE/usr/local/bin"

if [ "$I386" = 1 ]; then
    TGZ="$CACHE/steam_${STEAM_VER}.tar.gz"
    if [ ! -f "$TGZ" ]; then
        echo "[distro] fetching Valve's Steam bootstrap ($STEAM_URL)"
        curl -fL -o "$TGZ.part" "$STEAM_URL"
        mv "$TGZ.part" "$TGZ"
    fi
    got="$(sha256sum "$TGZ" | cut -d' ' -f1)"
    # A wrong tarball here would be a wrong Steam, silently. Fail on it.
    [ "$got" = "$STEAM_SHA" ] || {
        echo "[distro] steam tarball sha256 mismatch" >&2
        echo "  expected $STEAM_SHA" >&2
        echo "  got      $got" >&2
        exit 1; }
    tar -C "$STAGE/opt/hamnix-steam" --strip-components=1 -xzf "$TGZ" \
        steam-launcher/bootstraplinux_ubuntu12_32.tar.xz
    mv "$STAGE/opt/hamnix-steam/bootstraplinux_ubuntu12_32.tar.xz" \
       "$STAGE/opt/hamnix-steam/bootstrap.tar.xz"
    echo "$STEAM_DEBVER" > "$STAGE/opt/hamnix-steam/version"

    cat > "$STAGE/usr/local/bin/hamnix-steam" <<'STEAMEOS'
#!/bin/sh
# hamnix-steam — run Steam inside the Debian namespace.
#
# /usr/games/steam (Debian's steam-installer) wants to ask a zenity question
# and then curl Valve's bootstrap.  Both were done at image build time, so all
# this does is put the pre-staged bootstrap where that script looks for it and
# then get out of the way.  The four `needed` paths and the version file are
# exactly what /usr/games/steam tests for; if they are present and current it
# does no network I/O of its own at all.
set -e

# $HOME matters more than it looks: Steam installs ~2.5 GB of client under it.
# hamsh hands an entering program the placeholder "/" when it has not resolved
# a passwd entry, and "/" IS a directory -- so a `[ -d ]` guard accepts it and
# the whole client lands in /.steam at the root of the namespace. Reject the
# placeholder by name.
case "${HOME:-}" in
    ""|"/") HOME=/home/live ;;
esac
[ -d "$HOME" ] || mkdir -p "$HOME" 2>/dev/null || HOME=/root
export HOME

STEAMDIR="$HOME/.steam/debian-installation"
if [ ! -x "$STEAMDIR/steam.sh" ]; then
    echo "hamnix-steam: seeding $STEAMDIR from /opt/hamnix-steam" >&2
    mkdir -p "$STEAMDIR/deb-installer"
    tar -C "$STEAMDIR" -xf /opt/hamnix-steam/bootstrap.tar.xz
    cp /opt/hamnix-steam/bootstrap.tar.xz "$STEAMDIR/bootstrap.tar.xz"
    cp /opt/hamnix-steam/version "$STEAMDIR/deb-installer/version"
fi

# Steam refuses to draw without a display.  Both are legitimate here: the
# Wayland socket is wsyswl's (run it on the Hamnix side with its socket path
# inside this tree -- `wsyswl /n/distro/run/wayland-0`), and DISPLAY is
# XWayland's.  Neither is defaulted, because a wrong one looks like a Steam
# bug rather than a missing compositor.
if [ -z "${DISPLAY-}" ] && [ -z "${WAYLAND_DISPLAY-}" ]; then
    echo "hamnix-steam: no DISPLAY and no WAYLAND_DISPLAY -- Steam has no" >&2
    echo "  screen to draw on.  Start wsyswl on the Hamnix side and set" >&2
    echo "  XDG_RUNTIME_DIR=/run WAYLAND_DISPLAY=wayland-0, or run Xwayland" >&2
    echo "  in here and set DISPLAY=:0." >&2
    exit 1
fi

exec /usr/games/steam "$@"
STEAMEOS
    chmod 755 "$STAGE/usr/local/bin/hamnix-steam"
fi

# /etc/resolv.conf.  mmdebstrap copies the BUILD HOST's in, and the build
# host's nameserver is not reachable from inside the VM -- so every DNS lookup
# in the namespace timed out while the network itself was fine.  Steam cannot
# reach its CDN without this, and the failure looks like Steam being broken.
# 10.0.2.3 is QEMU user-mode networking's forwarder, which is the same address
# etc/rc.boot.linux hands to `ifconfig dns`.
mkdir -p "$STAGE/etc"
cat > "$STAGE/etc/resolv.conf" <<'RESOLVEOS'
# hamnix-linux: the Debian namespace's resolver.
# 10.0.2.3 is QEMU user-mode networking's DNS forwarder (scripts/hamlinux_vm.sh
# puts the guest on 10.0.2.0/24), and matches `ifconfig dns` in rc.boot.linux.
# The second line is what a real machine falls back to until DHCP writes here.
nameserver 10.0.2.3
nameserver 1.1.1.1
RESOLVEOS

# --- the window manager's configuration ------------------------------------
# ONE file for every namespace: Alpine's build copies the same etc/jwmrc.linux
# to the same path. What is inside it, and what is deliberately not, is
# documented in the file itself; the short version is that Debian's own
# /etc/jwm/system.jwmrc launches an xclock into a tray and vertically
# maximises xterms, so running with the packaging default would be running a
# window manager nobody chose.
mkdir -p "$STAGE/etc/jwm"
cp "$PROJ_ROOT/etc/jwmrc.linux" "$STAGE/etc/jwm/hamnix.jwmrc"

mkdir -p "$(dirname "$OUT")"
PREV_SZ=0
[ -f "$OUT" ] && PREV_SZ="$(du -m "$OUT" | cut -f1)"
rm -f "$OUT"

echo "[distro] bootstrapping Debian $SUITE into $OUT ($SIZE)"
echo "[distro] this downloads a few hundred megabytes and takes a while"

# --format=ext4 needs the target to exist at the size we want.
truncate -s "$SIZE" "$OUT"

# The Steam staging only exists in the multiarch build; without i386 there is
# nothing that could run the bootstrap, so shipping it would be a lie on disk.
STEAM_HOOKS=()
if [ "$I386" = 1 ]; then
    STEAM_HOOKS=(
        --customize-hook="copy-in $STAGE/opt/hamnix-steam /opt"
        --customize-hook="copy-in $STAGE/usr/local/bin/hamnix-steam /usr/local/bin"
    )
fi

mmdebstrap \
    "${STEAM_HOOKS[@]}" \
    --mode=unshare \
    --format=ext4 \
    --variant=important \
    --architectures="$ARCHS" \
    --include="$PKGS" \
    --components=main,contrib \
    --customize-hook="copy-in $STAGE/etc/resolv.conf /etc" \
    --customize-hook="copy-in $STAGE/etc/jwm/hamnix.jwmrc /etc/jwm" \
    --customize-hook='chroot "$1" sh -c "
        # The DE session runs as uid 1001 (etc/rc.de-user.linux drops to it),
        # so a program that enters this namespace arrives as 1001. Without a
        # passwd entry HERE, getpwuid(getuid()) returns NULL in the namespace
        # and Steam -- which uses it to locate its own data directory -- exits
        # before drawing anything. Create the account so it resolves.
        id live >/dev/null 2>&1 || useradd -u 1001 -m -s /bin/bash live
        mkdir -p /home/live && chown 1001:1001 /home/live
    "' \
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
DISPLAY=:0 jwm -f /etc/jwm/hamnix.jwmrc &
sleep 1
DISPLAY=:0 exec \"\\\$@\"
EOS
        chmod 755 /usr/local/bin/hamnix-x
    "' \
    "$SUITE" "$OUT" "$MIRROR"

# GROW THE FILESYSTEM TO $SIZE.  mmdebstrap sizes the ext4 to fit what it
# installed and truncates the file down to it, so the `truncate -s 12G` above
# buys no free space at all -- the first build came out with 310 MB free
# INSIDE a 12 GB file.  That is not enough for Steam to unpack its ~300 MB
# client, let alone a game, and the failure would arrive as ENOSPC in the
# middle of a download rather than as anything about image sizing.  The file
# stays sparse, so the headroom costs nothing until it is used.
if command -v /sbin/resize2fs >/dev/null; then
    truncate -s "$SIZE" "$OUT"
    /sbin/resize2fs "$OUT" >/dev/null 2>&1 || echo "[distro] resize2fs failed; image has only its packed size" >&2
    echo "[distro] filesystem grown to $SIZE ($(/sbin/dumpe2fs -h "$OUT" 2>/dev/null | awk '/Free blocks:/{print $3*4/1024/1024" GiB"}') free)"
else
    echo "[distro] no resize2fs -- the image has no free space beyond its packages" >&2
fi

# THE VOLUME LABEL IS THE NAME. /etc/distros says `debian LABEL=hamnix-debian`,
# and `bind '#distro/debian' /n/debian` finds the medium by reading superblocks
# rather than by trusting that this image is the one QEMU happened to enumerate
# first. With a second distro disk attached that assumption is a coin flip, and
# losing it does not fail -- it enters the wrong distribution and says nothing.
LABEL="${HAMLINUX_DISTRO_LABEL:-hamnix-debian}"
/sbin/tune2fs -L "$LABEL" "$OUT" >/dev/null
echo "[distro] volume label: $LABEL"

NEW_SZ="$(du -m "$OUT" | cut -f1)"
echo "[distro] done: $OUT ($(du -h "$OUT" | cut -f1))"
echo "[distro] architectures: $ARCHS"
if [ "$PREV_SZ" -gt 0 ]; then
    # This is a distro. What multiarch costs is a number somebody has to live
    # with, so it is printed rather than left to be discovered.
    echo "[distro] size: ${PREV_SZ} MiB -> ${NEW_SZ} MiB (delta $((NEW_SZ - PREV_SZ)) MiB)"
fi
echo "  attach it: scripts/hamlinux_vm.sh (picks it up automatically)"
