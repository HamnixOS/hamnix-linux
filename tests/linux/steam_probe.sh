#!/bin/sh
# tests/linux/steam_probe.sh — what a Steam-class application needs, checked
# one piece at a time, from INSIDE the Debian namespace.
#
# This is staged into the namespace image (scripts/hamlinux_steamtest.sh writes
# it in with debugfs) and run by `enter debian { /usr/local/bin/steam_probe }`.
# It runs on the guest, as a Debian /bin/sh, with the Hamnix filesystem not
# even reachable -- which is the only place any of these answers mean anything.
#
# Every check prints ONE line beginning `steamprobe:` and containing PASS or
# FAIL, so the harness can grep and nothing can be satisfied by a plausible
# blank. A check that cannot be run says SKIP and says why, rather than
# reporting the absence of a failure as a pass.

say() { echo "steamprobe: $*"; }
ok()  { say "PASS $*"; }
no()  { say "FAIL $*"; }
skip(){ say "SKIP $*"; }

say "BEGIN"
say "uname $(uname -m) / $(cat /etc/debian_version 2>/dev/null)"

# --- 1. multiarch ----------------------------------------------------------
# dpkg has to KNOW about i386, not merely have some 32-bit files lying around:
# without the foreign architecture registered nothing can be installed or
# upgraded on that side later.
fa="$(dpkg --print-foreign-architectures 2>/dev/null | tr '\n' ' ')"
case "$fa" in *i386*) ok "dpkg foreign architectures: $fa" ;;
              *)      no "dpkg foreign architectures: '$fa' (no i386)" ;; esac

# --- 2. a 32-bit binary actually EXECS -------------------------------------
# The interesting failure is not "no i386 packages" but "i386 packages and no
# /lib/ld-linux.so.2", which fails at exec time with ENOENT on a path the user
# never typed. So run one.
if [ -e /lib/ld-linux.so.2 ] || [ -e /lib32/ld-linux.so.2 ]; then
    ok "32-bit loader present: $(ls /lib/ld-linux.so.2 2>/dev/null || echo /lib32/ld-linux.so.2)"
else
    no "no /lib/ld-linux.so.2 -- no 32-bit binary can be exec'd"
fi

G=/usr/bin/glxgears
if [ -x "$G" ]; then
    t="$(file -bL "$G" | cut -c1-40)"   # -L: /usr/bin/glxgears is a symlink
    case "$t" in *"ELF 32-bit"*) ok "glxgears is 32-bit: $t" ;;
                 *)              no "glxgears is not 32-bit: $t" ;; esac
else
    skip "no /usr/bin/glxgears (mesa-utils:i386 not installed)"
fi

# The 32-bit Steam bootstrapper itself. This is the binary that has no 64-bit
# build and is therefore the reason multiarch is not optional.
S=/opt/hamnix-steam/bootstrap.tar.xz
if [ -f "$S" ]; then
    ok "Steam bootstrap staged: $(wc -c < "$S") bytes"
else
    no "no /opt/hamnix-steam/bootstrap.tar.xz"
fi

# --- 3. 32-bit dynamic linking, end to end ---------------------------------
# `ldd` on a 32-bit binary resolves through the i386 loader and the i386
# ld.so.cache. "not found" here is the multiarch failure that matters, and it
# is the one that makes Steam exit 1 with no message at all.
if [ -x "$G" ]; then
    miss="$(ldd "$G" 2>/dev/null | grep -c 'not found')"
    if [ "$miss" = 0 ]; then ok "32-bit NEEDED closure resolves (ldd glxgears)"
    else no "32-bit ldd: $miss libraries not found"; fi
fi

# --- 4. GPU: whose Mesa, and what does it find? ----------------------------
# The Vulkan userspace that matters HERE is the namespace's own Debian Mesa,
# not the one hpm installs into the Hamnix root: a Debian process resolves
# /usr/share/vulkan/icd.d and /usr/lib/i386-linux-gnu/dri inside THIS tree.
if [ -e /dev/dri/card0 ]; then ok "/dev/dri/card0 present in the namespace"
else no "/dev/dri/card0 not visible (enter_root binds /dev; is virtio_gpu loaded?)"; fi
ls /dev/dri 2>/dev/null | sed 's/^/steamprobe:   \/dev\/dri\//'

for d in /usr/lib/i386-linux-gnu/dri /usr/lib/x86_64-linux-gnu/dri; do
    if [ -d "$d" ]; then ok "DRI drivers: $d ($(ls "$d" | wc -l) drivers)"
    else no "no $d"; fi
done
if [ -d /usr/share/vulkan/icd.d ]; then
    ok "Vulkan ICDs: $(ls /usr/share/vulkan/icd.d | tr '\n' ' ')"
else
    no "no /usr/share/vulkan/icd.d in the namespace"
fi

# vulkaninfo enumerates without a window system, so this is the one graphics
# check that is meaningful on a serial boot. It is the i386 build deliberately.
if command -v vulkaninfo >/dev/null 2>&1; then
    v="$(vulkaninfo --summary 2>&1 | grep -E 'deviceName|driverName' | head -4 | tr '\n' ';')"
    if [ -n "$v" ]; then ok "32-bit Vulkan devices: $v"
    else no "vulkaninfo found no device: $(vulkaninfo --summary 2>&1 | tail -3 | tr '\n' ';')"; fi
else
    skip "no vulkaninfo"
fi

# --- 5. bubblewrap, the Steam container question ---------------------------
# Steam's per-GAME runtimes (soldier/sniper, "pressure-vessel") build a
# container with bwrap. The client itself does not -- it uses the
# LD_LIBRARY_PATH scout runtime -- so this is not on the path to a Steam
# window, but it IS on the path to launching a game, and it is the part most
# likely to fight a namespace that is already a chroot in a private mount
# namespace. Answer it rather than guess.
if command -v bwrap >/dev/null 2>&1; then
    # AS ROOT, WITHOUT A USER NAMESPACE. This is the configuration Steam's
    # pressure-vessel actually uses when it is running as root, and it is the
    # one that decides whether a game's container can be built at all.
    out="$(bwrap --unshare-pid --unshare-ipc --unshare-uts \
             --ro-bind / / --proc /proc --dev /dev \
             /bin/echo BWRAP_RAN 2>&1)"
    case "$out" in
      *BWRAP_RAN*) ok "bwrap WITHOUT --unshare-user runs (uid $(id -u))" ;;
      *)           no "bwrap without --unshare-user: $out" ;;
    esac

    # WITH a user namespace. This is what bwrap must do when it is NOT root --
    # i.e. for the desktop session, which etc/rc.de-user.linux drops to uid
    # 1001. `enter debian` is implemented as chroot(2), and the kernel refuses
    # CLONE_NEWUSER to a chrooted process (create_user_ns -> current_chrooted()
    # -> EPERM) regardless of uid or of user.max_user_namespaces. So this is
    # expected to FAIL here, and the failure is structural rather than a
    # misconfiguration -- it would go away if enter_root used pivot_root.
    out2="$(bwrap --unshare-all --ro-bind / / --proc /proc --dev /dev \
             /bin/echo USERNS_RAN 2>&1)"
    case "$out2" in
      *USERNS_RAN*) ok "bwrap --unshare-user runs (the chroot restriction is gone)" ;;
      *)            no "bwrap --unshare-user: $out2" ;;
    esac
    if [ -r /proc/sys/user/max_user_namespaces ]; then
        say "INFO max_user_namespaces=$(cat /proc/sys/user/max_user_namespaces) (so the sysctl is NOT the cause)"
    fi
else
    skip "no bwrap installed"
fi

# --- 5b. the two /dev holes that stop large apps dead --------------------
# Neither announces itself. /dev/fd missing breaks bash process substitution,
# which is what Steam's runtime setup.sh uses; /dev/shm missing stops Chromium
# -- and Steam's whole UI is Chromium -- from starting a renderer.
[ -e /dev/fd ] && ok "/dev/fd present (bash <(...) works)" \
               || no "no /dev/fd -- bash process substitution fails"
if [ -d /dev/shm ] && [ -w /dev/shm ]; then ok "/dev/shm present and writable"
else no "no writable /dev/shm -- Chromium/Steam cannot map shared memory"; fi

# Loopback. Steam's own IPC binds 127.0.0.1 and says only
# "socket bind failed: Cannot assign requested address" when it cannot.
if ip -4 addr show lo 2>/dev/null | grep -q 127.0.0.1 \
   || ifconfig lo 2>/dev/null | grep -q 127.0.0.1; then
    ok "loopback has 127.0.0.1"
else
    no "loopback has no address -- every local socket bind fails"
fi
command -v dbus-launch >/dev/null 2>&1 && ok "dbus-launch present (session bus possible)" \
                                       || no "no dbus-launch (dbus-x11 not installed)"

# --- 6. audio --------------------------------------------------------------
# Steam wants a sound server. Report what is missing rather than papering over
# it: the client-side library being present proves nothing about a device.
if [ -d /dev/snd ]; then ok "/dev/snd present: $(ls /dev/snd | tr '\n' ' ')"
else no "no /dev/snd -- the VM has no sound device and no snd modules"; fi
if [ -e /usr/lib/i386-linux-gnu/libpulse.so.0 ]; then
    ok "32-bit libpulse present (client side only)"
else
    no "no 32-bit libpulse -- Steam's audio would not even link"
fi
[ -S /run/pulse/native ] && ok "a PulseAudio server is listening" \
                         || no "no PulseAudio server socket at /run/pulse/native"

# --- 7. the network Steam cannot start without -----------------------------
# The bootstrap downloads ~300 MB of client from Valve's CDN on first run.
# There is no offline path: no amount of image staging removes this.
if getent hosts deb.debian.org >/dev/null 2>&1; then
    ok "DNS resolves (getent hosts deb.debian.org)"
else
    no "DNS does not resolve in the namespace -- check /etc/resolv.conf"
fi
if command -v curl >/dev/null 2>&1; then
    if curl -s -m 20 -o /dev/null -w '%{http_code}' \
        https://repo.steampowered.com/steam/archive/stable/ 2>/dev/null \
        | grep -qE '^[23]'; then
        ok "HTTPS reaches repo.steampowered.com"
    else
        no "HTTPS to repo.steampowered.com failed"
    fi
else
    skip "no curl"
fi

# --- 8. the account Steam looks itself up in -------------------------------
u="$(id -un 2>/dev/null)"
if [ -n "$u" ]; then ok "getpwuid resolves: uid $(id -u) is '$u', HOME=$HOME"
else no "getpwuid($(id -u)) does not resolve in this namespace"; fi

# --- 9. the launcher -------------------------------------------------------
[ -x /usr/games/steam ]           && ok "/usr/games/steam present" \
                                  || no "/usr/games/steam missing"
[ -x /usr/local/bin/hamnix-steam ] && ok "/usr/local/bin/hamnix-steam present" \
                                  || no "/usr/local/bin/hamnix-steam missing"

say "END"
