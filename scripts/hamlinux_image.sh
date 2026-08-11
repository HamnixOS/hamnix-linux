#!/usr/bin/env bash
# scripts/hamlinux_image.sh — stage a bootable hamnix-linux root and pack it
# into an initramfs.
#
# The shape of the boot, which is deliberately the SAME shape as Hamnix's:
#
#   Linux kernel  ->  /init (user/linuxinit.ad, the Adder PID 1)
#                       -> binds #p /proc, #c /dev, #s /srv, ... via sys_bind
#                       -> exec /bin/hamsh /etc/rc.boot
#                            -> the rc scripts, then an interactive shell
#
# On Hamnix the kernel posts those file servers itself before ELF-loading
# /init; Linux hands us an empty namespace, so linuxinit does it. Everything
# above that line is unchanged Hamnix userland.
#
# Nothing here touches the host: it stages into build/image/ and packs a cpio.
# Mounting only ever happens inside the VM, where PID 1 is root. Run as an
# ordinary user.
#
# Usage: scripts/hamlinux_image.sh [outdir]
set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

OUT="${1:-build/image}"
ROOT="$OUT/root"
rm -rf "$ROOT"
mkdir -p "$ROOT"/{bin,etc,proc,sys,dev,srv,n,tmp,root,home,mnt,boot,lib,lib64,var/log,var/lib/hpm,var/cache,usr/bin,usr/share/adder}

# The applications that go in /bin. Kept to things that build AND run today
# (measured -- see HANDOFF.md §5); the point of the image is to boot, not to be
# complete. `hamsh` is the important one: it is PID 1 after linuxinit execs it.
APPS=(
    hamsh
    ls cat echo cp mv rm mkdir rmdir ln touch pwd
    grep sed sort uniq head tail wc cut tr
    find du df stat tree file
    date sleep true false yes seq basename dirname
    # `id` and `whoami` earn their place twice over now that the DE session
    # runs as a different uid from the console: they are how a person checks
    # WHICH identity a given window actually got.
    env_show printenv id whoami hostname uname
    #
    # login, su and passwd. They were kept out until now for a good reason,
    # recorded here because the reason is instructive: they build cleanly and
    # parse /etc/passwd correctly, but every credential path bottomed out in
    # sys_setuid_auth(), which was a flat -1 -- so `login` could only ever
    # answer "Login incorrect" and `su` could only ever refuse. Shipping them
    # then would have been a worse lie than their absence.
    #
    # user/linux-auth.c now serves /dev/auth against the real /etc/shadow, so
    # they work, and nothing in them had to change -- which is what the Plan 9
    # shape buys: the password checker lives behind a device and the programs
    # that use it never see a hash.
    login su passwd
    ac
    ps kill
    tar gzip base64 cksum md5sum
    more less
    bc cal
    ifconfig route ping host curl wget hpm
    insmod modprobe lsmod rmmod
    xbridge wsyswl nsrun dhcpc ntpd
    hlinstall reboot haminstallui
    # Audio. All three are thin Plan 9 clients of /dev/audio, /dev/audioctl
    # and /dev/audioin (user/linux-audio.c) and none of them knows anything
    # about ALSA: `playtone` synthesises a square wave and needs no fixture at
    # all, which is what makes it the thing a gate can drive on a bare
    # console; `aplay` streams a .wav; `arecord` captures one. They were
    # absent from the image while the device was absent -- and `playtone`
    # reported success into a regular FILE called /dev/audio, which is exactly
    # why they are here now that there is a device behind the name.
    playtone aplay arecord
)

# The desktop. wsysd is the compositor (user/wsysd.ad — the userland half of
# the devwsys.ad port); the rest are ordinary scene clients that talk to it
# through /dev/wsys and know nothing about which kernel is underneath.
GUI_APPS=(
    wsysd
    hamdesktop hampanelscene hamtermscene hameditscene hamsettings hamfm
    hamUI hamUId
)
APPS+=("${GUI_APPS[@]}")

# NO app_extra_objs() HERE. 6a27c0ec moved the per-program object list into
# scripts/hamlinux_build.sh, which is the only place that can be right; this
# script kept its own copy and passed it as well, so wsysd was compiled with
# user/linux-vk.c TWICE and the link died on a page of "multiple definition of
# hvk_*". The image then dropped it into a MISSING list printed among the
# harmless "(no source)" entries and said `done`, so every image built since
# has shipped a desktop with NO COMPOSITOR -- and the boot log's only symptom
# was `hamsh: command not found: /bin/wsysd` in the middle of rc.5, followed by
# `[rc.5] compositor started`. The build script knows. Ask it and nothing else.

echo "[image] building $(( ${#APPS[@]} )) applications + the Adder PID 1"
BUILT=0; MISSING=(); FAILED=()
for app in "${APPS[@]}"; do
    src="user/$app.ad"
    if [ ! -f "$src" ]; then MISSING+=("$app(no source)"); continue; fi
    if scripts/hamlinux_build.sh "$src" "$OUT/obj/$app.elf" \
            >"$OUT/obj/$app.build.log" 2>&1; then
        install -m755 "$OUT/obj/$app.elf" "$ROOT/bin/$app"
        BUILT=$((BUILT+1))
    else
        MISSING+=("$app"); FAILED+=("$app")
    fi
done

# --- the Adder compiler, on the box ---------------------------------------
# `ac foo.ad` builds a running binary without a development host.  Two halves,
# and the split is a measurement rather than a preference:
#
#   host_ac  is ALREADY a static Linux ELF, so it is just another /bin binary.
#            It is shipped rather than built here because host_ac cannot emit a
#            host-Linux binary at all -- the adder submodule documents this at
#            15301ae, and `--target=x86_64-linux` writes a 152-byte ELF that
#            segfaults.  So the compiler is a first-class FILE on the box, not
#            a first-class build product of it.
#   clang    stays in the Debian namespace.  A minimal closure is 250-300 MB
#            and libLLVM is nearly all of it; copying that into /bin would be
#            copying a Debian binary and calling it native.  user/ac.ad reaches
#            for it exactly as user/hlinstall.ad reaches for mkfs.ext4.
#
# The runtime sources go with it, because linking needs them: ac-link.sh
# DISCOVERS the object list from what is present rather than carrying a copy
# of the build script's, so a new user/linux-*.c is picked up instead of
# turning into an undefined symbol.
if [ -f build/cutover/host_ac.elf ]; then
    install -m755 build/cutover/host_ac.elf "$ROOT/bin/host_ac"
    install -m644 user/linux-runtime.S user/linux-*.c user/linux-*.h \
        user/syscall_nums.h scripts/adder_llvm_runtime.c \
        "$ROOT/usr/share/adder/"
    install -m644 scripts/ac-link.sh "$ROOT/usr/share/adder/ac-link.sh"
    # A source to try it on, so the first thing a curious operator types
    # works: `ac /usr/share/adder/hello.ad -o /tmp/hello`.
    [ -f tests/linux/hello.ad ] && install -m644 tests/linux/hello.ad "$ROOT/usr/share/adder/hello.ad"
    echo "[image] staged the Adder compiler (ac + host_ac + runtime sources)"
else
    echo "[image] NOTE: no build/cutover/host_ac.elf -- /bin/ac will have no compiler" >&2
fi

# /bin/install is the SAME program as /bin/hlinstall. user/haminstallui.ad --
# the DE's install wizard -- spawns "/bin/install --auto <disk> ..." and was
# written against that name and that argv; the wizard is the part worth
# keeping, so the name follows it rather than the other way round.
[ -f "$ROOT/bin/hlinstall" ] && install -m755 "$ROOT/bin/hlinstall" "$ROOT/bin/install"

# /init is the Adder PID 1. The kernel execs it directly out of the initramfs.
scripts/hamlinux_build.sh user/linuxinit.ad "$OUT/obj/linuxinit.elf" >/dev/null
install -m755 "$OUT/obj/linuxinit.elf" "$ROOT/init"
install -m755 "$OUT/obj/linuxinit.elf" "$ROOT/bin/linuxinit"

echo "[image] built $BUILT/${#APPS[@]} apps"
[ ${#MISSING[@]} -gt 0 ] && echo "[image] not included: ${MISSING[*]}"

# A PROGRAM THAT FAILED TO BUILD IS NOT THE SAME AS A PROGRAM WITH NO SOURCE,
# and printing them in one list is how a missing compositor went unnoticed.
# Say which ones broke, show why, and -- for the handful the system cannot
# boot a desktop without -- refuse to call the image done.
if [ ${#FAILED[@]} -gt 0 ]; then
    echo "[image] THESE FAILED TO BUILD (they have source and it did not link):" >&2
    for app in "${FAILED[@]}"; do
        echo "[image]   $app -- $OUT/obj/$app.build.log" >&2
        tail -3 "$OUT/obj/$app.build.log" 2>/dev/null | sed 's/^/[image]     /' >&2
    done
    for app in "${FAILED[@]}"; do
        case "$app" in
            wsysd|hamsh|hamdesktop|hampanelscene)
                echo "[image] FATAL: $app is not optional -- there is no desktop without it." >&2
                exit 1 ;;
        esac
    done
fi

# This lane links glibc (HANDOFF.md §7.4), so the loader and libc have to be in
# the image. That is the deliberate trade: a dynamic link is what buys us
# OpenSSL, Mesa and PipeWire later without any backend work.
echo "[image] copying the dynamic loader and libc"
copy_libs() {
    local bin="$1"
    # `|| true` because ldd EXITS NON-ZERO on a static binary, and with
    # `set -euo pipefail` that aborted the whole image build. It never fired
    # while every binary was dynamic; /bin/host_ac is the first static one,
    # and it took the build down at the copy step with no message about why.
    { ldd "$bin" 2>/dev/null || true; } \
        | awk '/=> \//{print $3} /^\t\//{print $1}' | sort -u | while read -r lib; do
        [ -f "$lib" ] || continue
        local dest="$ROOT$lib"
        mkdir -p "$(dirname "$dest")"
        [ -f "$dest" ] || cp -L "$lib" "$dest"
    done
}
for b in "$ROOT"/bin/* "$ROOT/init"; do copy_libs "$b"; done
# ld.so itself is named in the ELF interpreter, not in ldd's "=>" list.
INTERP="$(readelf -l "$ROOT/init" | awk -F': *' '/interpreter/{sub(/\]$/,"",$2); print $2}')"
if [ -n "$INTERP" ] && [ ! -f "$ROOT$INTERP" ]; then
    mkdir -p "$(dirname "$ROOT$INTERP")"
    cp -L "$INTERP" "$ROOT$INTERP"
fi

# The rc that hamsh runs as PID 1. Staged from etc/rc.boot.linux -- the Hamnix
# etc/rc.boot assumes a rootfs partition and the #sysroot server, neither of
# which exists in an initramfs-only developer boot.
# HAMLINUX_RC lets a test stage a different bootstrap rc -- the smoke test
# drives the guest by putting commands IN the rc rather than racing the BIOS
# for stdin, which is not reproducible.
install -m644 "${HAMLINUX_RC:-etc/rc.boot.linux}" "$ROOT/etc/rc.boot"
for f in hostname hosts passwd group issue motd panel.conf desktop.icons \
         hamde os-release lsb-release debian_version profile resolv.conf \
         services protocols networks host.conf; do
    [ -f "etc/$f" ] && install -m644 "etc/$f" "$ROOT/etc/$f"
done
# The package manager's channel list and trust roots.
mkdir -p "$ROOT/etc/hpm" "$ROOT/var/lib/hpm"
for f in trusted.pub local-trusted.pub; do
    [ -f "etc/hpm/$f" ] && install -m644 "etc/hpm/$f" "$ROOT/etc/hpm/$f"
done
# The Linux line subscribes to the `linux` channel, not `main`: `main` holds
# native Hamnix binaries, which install here perfectly and then segfault.
install -m644 etc/hpm/channels.linux "$ROOT/etc/hpm/channels"
# The manual pages. etc/man/ has 19 of them and nothing was staging them, so
# on the shipped image `help` reported its own index missing and `man
# <anything>` failed -- both exiting 0 about it.
if [ -d etc/man ]; then
    mkdir -p "$ROOT/usr/share/man"
    install -m644 etc/man/*.md "$ROOT/usr/share/man/" 2>/dev/null || true
    echo "[image] staged $(ls -1 etc/man/*.md 2>/dev/null | wc -l) manual pages"
fi

# The graphical runlevel. Kept separate from Hamnix's etc/rc.d/rc.5, which
# brings the DE up through the declarative service supervisor and the kernel
# scene compositor -- neither of which exists on this line yet.
mkdir -p "$ROOT/etc/rc.d"
install -m644 etc/rc.d/rc.5.linux "$ROOT/etc/rc.d/rc.5"
# The namespace a DE-spawned shell gets. Same reasoning as rc.5 above: this is
# the Linux-line variant, and its header says what it leaves out and why.
install -m644 etc/rc.de-user.linux "$ROOT/etc/rc.de-user"

# --- the accounts ---------------------------------------------------------
# The image is multi-user now: /etc/rc.de-user ends with `setuid 1001`, so a
# desktop terminal and everything launched from it run as the regular user
# `live` rather than as the machine's owner. For that to be an ACCOUNT rather
# than a bare number, three things have to be true in the image, and all three
# are done here.
#
# (1) The database. passwd + group are staged above; shadow is staged here
#     because it needs mode 0600 and the loop above installs 0644. The hashes
#     in it are honest $6$-crypt of `hamnix` and are what /dev/auth will read
#     when it exists -- on this line sys_setuid_auth is still a -1 stub
#     (user/linux-runtime.S) and there is no /dev/auth cdev, so nothing
#     consults the file yet. It ships anyway: an account database with the
#     credentials missing is a half-provisioned account, and the file's mode
#     is the thing that has to be right from the start.
install -m600 etc/shadow "$ROOT/etc/shadow"
# (2) The per-user namespace recipe. hamsh sources /etc/users/<user>.ns for
#     any regular-user shell and falls back to default.ns; live.ns.linux
#     exists to stop that fallback, for reasons its own header gives.
mkdir -p "$ROOT/etc/users"
install -m644 etc/users/default.ns "$ROOT/etc/users/default.ns"
install -m644 etc/users/live.ns.linux "$ROOT/etc/users/live.ns"
# (3) The home directory, with the skeleton in it. A session whose $HOME does
#     not exist cannot save a file, and hamsh's _chdir_home would leave it in
#     the filesystem root. /etc/skel is the same skeleton the installer copies
#     for a real account (Desktop/Documents/Downloads/Pictures, plus the
#     .desktop launchers hamdesktop draws).
#     /home/hostowner exists too, empty: it is the home /etc/passwd promises
#     uid 1, and `newshell hostowner` chdir's into it.
cp -a etc/skel "$ROOT/etc/skel"
mkdir -p "$ROOT/home/live" "$ROOT/home/hostowner"
cp -a etc/skel/. "$ROOT/home/live/"

# --- a sound to play ------------------------------------------------------
# /usr/share/sounds/test.wav, so `aplay` has something to play on a machine
# that has just booted an initramfs, and so the audio gates can exercise the
# STREAMING path (aplay uses `streamopen` + `drain`) and not only the staged
# one-shot that playtone uses.
#
# It is SYNTHESISED here rather than committed as a binary: half a second of a
# 660 Hz sine at 48 kHz stereo s16le, which is a signal an FFT can check
# exactly, and 96 KB that nobody has to review. The header is the canonical
# 44-byte RIFF/WAVE one user/aplay.ad parses.
mkdir -p "$ROOT/usr/share/sounds"
python3 - "$ROOT/usr/share/sounds/test.wav" <<'WAVPY'
import math, struct, sys
rate, chans, secs, freq, amp = 48000, 2, 0.5, 660.0, 11000
n = int(rate * secs)
pcm = bytearray()
for i in range(n):
    v = int(amp * math.sin(2 * math.pi * freq * i / rate))
    pcm += struct.pack('<hh', v, v)
data = bytes(pcm)
hdr = (b'RIFF' + struct.pack('<I', 36 + len(data)) + b'WAVEfmt '
       + struct.pack('<IHHIIHH', 16, 1, chans, rate,
                     rate * chans * 2, chans * 2, 16)
       + b'data' + struct.pack('<I', len(data)))
open(sys.argv[1], 'wb').write(hdr + data)
WAVPY
echo "[image] staged /usr/share/sounds/test.wav ($(du -h "$ROOT/usr/share/sounds/test.wav" | cut -f1))"

# --- kernel modules -------------------------------------------------------
# The north star is real hardware, and on a Debian kernel nearly every driver
# is a module -- even in QEMU, /dev/dri/card0 does not exist until virtio-gpu
# and its dependencies are loaded. Resolve the load ORDER here, where a real
# modprobe is available, and write it to /etc/modules as absolute paths; the
# Adder PID 1 just walks that list. Modules are decompressed because the guest
# kernel's in-kernel decompressor is not guaranteed to be built in.
KVER="$(basename "${KERNEL:-}" 2>/dev/null | sed 's/^vmlinuz-//')"
KERNEL="$(ls -1 /boot/vmlinuz-* 2>/dev/null | sort -V | tail -1)"
KVER="$(basename "$KERNEL" | sed 's/^vmlinuz-//')"
MODPROBE=/usr/sbin/modprobe
# vfat is here because the INSTALLER needs it: an ESP is FAT32, and without
# the driver `bind /dev/sdb1 /n/esp` fails with ENODEV -- which reads like a
# broken partition rather than a missing module.
# The sound modules are here for the same reason virtio-gpu is: without them
# devtmpfs never publishes /dev/snd/pcmC0D0p and user/linux-audio.c's
# /dev/audio has nothing to open. snd-hda-codec-generic is listed BEFORE
# snd-hda-intel deliberately -- the controller normally pulls its codec driver
# in with request_module(), and PID 1 here loads modules by absolute path with
# no modules.dep to resolve against, so an autoload would quietly not happen
# and the card would enumerate with no PCM device at all. Loading the codec
# first makes that impossible. virtio_snd rides along so an image booted
# against `-device virtio-sound-pci` finds a card too.
WANT_MODULES="${HAMLINUX_MODULES:-virtio-gpu virtio_input evdev virtio_net virtio_blk ext4 vfat nls_ascii nls_cp437 overlay squashfs loop snd-hda-codec-generic snd-hda-intel virtio_snd}"
: > "$ROOT/etc/modules"
if [ -x "$MODPROBE" ] && [ -d "/lib/modules/$KVER" ]; then
    mkdir -p "$ROOT/lib/modules/$KVER"
    for m in $WANT_MODULES; do
        "$MODPROBE" --dry-run --show-depends -S "$KVER" "$m" 2>/dev/null \
        | awk '/^insmod /{print $2}' | while read -r ko; do
            [ -f "$ko" ] || continue
            rel="${ko#/lib/modules/$KVER/}"
            out="$ROOT/lib/modules/$KVER/${rel%.xz}"
            mkdir -p "$(dirname "$out")"
            if [ ! -f "$out" ]; then
                case "$ko" in
                    *.xz) xz -dc "$ko" > "$out" ;;
                    *)    cp -L "$ko" "$out" ;;
                esac
                # Append in dependency order, skipping ones already listed.
                grep -qxF "/lib/modules/$KVER/${rel%.xz}" "$ROOT/etc/modules" \
                    || echo "/lib/modules/$KVER/${rel%.xz}" >> "$ROOT/etc/modules"
            fi
        done
    done
    echo "[image] staged $(grep -c . "$ROOT/etc/modules" 2>/dev/null || echo 0) kernel modules for $KVER"
else
    echo "[image] no modprobe or /lib/modules/$KVER — image will have no drivers" >&2
fi

# --- the Vulkan userspace -------------------------------------------------
# The kernel modules above give the machine a DRM device and a framebuffer.
# They do not give it anything that can DRAW. That is the ICD -- a userspace
# driver reached through libvulkan.so.1 -- and it belongs in the HAMNIX root,
# not in the Debian namespace, because the whole point of this line is that the
# Adder userland talks to the GPU itself. tests/linux/vkprobe.ad proved an
# Adder binary on this lane can dlopen the loader and enumerate a real device.
#
# Everything is taken from the BUILD HOST, for the same reason ld-linux and
# libc are taken from the build host a few lines up: one ABI. The Debian
# namespace is a different release with a different glibc, and an ICD built
# against one libc loaded by another is the classic way to get a driver that
# initialises and then finds no devices.
#
# Libraries install under their DT_SONAME as REGULAR FILES, never symlinks:
# ld.so matches the string, and a dangling link is a failure that reads like a
# missing driver.
#
#   HAMLINUX_VULKAN=none      no Vulkan at all
#   HAMLINUX_VULKAN=venus     (default) loader + venus. ~7 MiB. venus is the
#                             virtio-gpu driver -- the one that makes a VM
#                             genuinely GPU-accelerated (hamlinux_vm.sh venus).
#   HAMLINUX_VULKAN=lavapipe  loader + venus + lavapipe, the CPU rasteriser.
#                             +165 MiB, nearly all libLLVM, and the only ICD
#                             that enumerates a device on a plain virtio-gpu --
#                             which is what makes an unaccelerated VM able to
#                             test the Vulkan path at all.
#   HAMLINUX_VULKAN=all       every ICD this host has: also ANV, NVK, RADV.
#
# On an INSTALLED machine the same files arrive as hpm packages
# (scripts/hamlinux_packages.py: hamnix-vulkan, hamnix-vulkan-<icd>). This
# staging is for the developer boot, where there is no network and no repo.
VK_LIBDIR=/usr/lib/x86_64-linux-gnu
VK_MODE="${HAMLINUX_VULKAN:-venus}"

vk_stage_so() {
    # Install one library under the name ld.so will look for.
    local lib="$1" name
    name="$(readelf -d "$lib" 2>/dev/null \
            | sed -n 's/.*SONAME.*\[\(.*\)\]/\1/p' | head -1)"
    [ -n "$name" ] || name="$(basename "$lib")"
    mkdir -p "$ROOT$VK_LIBDIR"
    [ -f "$ROOT$VK_LIBDIR/$name" ] || cp -L "$lib" "$ROOT$VK_LIBDIR/$name"
}

vk_stage_closure() {
    # A library and everything it needs. ldd is already transitive, so one
    # call is the whole closure -- and it reports what the LOADER would pick,
    # which is the question. libc and ld.so are already staged above.
    local lib="$1" dep
    [ -f "$lib" ] || return 0
    vk_stage_so "$lib"
    { ldd "$lib" 2>/dev/null || true; } | awk '/=> \//{print $3}' | sort -u \
    | while read -r dep; do
        case "$(basename "$dep")" in
            libc.so.6|ld-linux-x86-64.so.2) continue ;;
        esac
        [ -f "$dep" ] && vk_stage_so "$dep"
    done
}

if [ "$VK_MODE" != none ] && [ -f "$VK_LIBDIR/libvulkan.so.1" ]; then
    case "$VK_MODE" in
        venus)    VK_ICDS="virtio" ;;
        lavapipe) VK_ICDS="virtio lvp" ;;
        all)      VK_ICDS="virtio lvp intel nouveau radeon" ;;
        *)        VK_ICDS="$VK_MODE" ;;
    esac
    vk_stage_closure "$VK_LIBDIR/libvulkan.so.1"
    mkdir -p "$ROOT/usr/share/vulkan/icd.d"
    VK_STAGED=""
    for icd in $VK_ICDS; do
        json="/usr/share/vulkan/icd.d/${icd}_icd.json"
        [ -f "$json" ] || json="/usr/share/vulkan/icd.d/${icd}_icd.x86_64.json"
        [ -f "$json" ] || continue
        lib="$VK_LIBDIR/$(sed -n 's/.*"library_path"[^"]*"\([^"]*\)".*/\1/p' "$json")"
        [ -f "$lib" ] || continue
        vk_stage_closure "$lib"
        install -m644 "$json" "$ROOT/usr/share/vulkan/icd.d/$(basename "$json")"
        VK_STAGED="$VK_STAGED $icd"
    done
    # `if`, not `[ ... ] && { ... }`: under `set -e` a false test at the end of
    # an && list is the script's exit status, and an image build that stopped
    # here on a host without libdrm's PCI-id table would be a mystery.
    if [ -f /usr/share/libdrm/amdgpu.ids ]; then
        mkdir -p "$ROOT/usr/share/libdrm"
        install -m644 /usr/share/libdrm/amdgpu.ids \
            "$ROOT/usr/share/libdrm/amdgpu.ids"
    fi
    echo "[image] staged the Vulkan loader + ICDs:$VK_STAGED ($(du -sh "$ROOT$VK_LIBDIR" | cut -f1) of libraries)"
else
    echo "[image] no Vulkan userspace staged (HAMLINUX_VULKAN=$VK_MODE)"
fi

# vkprobe: the one program that answers "is the GPU stack real?" without
# guessing. It dlopens the loader, creates an instance and prints every
# physical device an ICD enumerates -- so a device NAME on the console is
# proof, and no output is proof of the opposite. Built specially because it is
# an Adder program plus a C shim plus -ldl, which the plain app loop above does
# not do.
if scripts/hamlinux_build.sh tests/linux/vkprobe.ad "$OUT/obj/vkprobe.elf" \
        tests/linux/vkprobe.c -ldl >/dev/null 2>&1; then
    install -m755 "$OUT/obj/vkprobe.elf" "$ROOT/bin/vkprobe"
    echo "[image] staged /bin/vkprobe"
else
    echo "[image] NOTE: vkprobe did not build" >&2
fi

# --- the installer's boot files -------------------------------------------
# HAMLINUX_INSTALLER=1 stages the kernel, the initramfs and the unified kernel
# image into /boot, so user/hlinstall.ad has something to write onto the ESP of
# the machine it is installing.  Off by default: it roughly triples the image,
# and a developer boot has no use for a copy of itself.
if [ -n "${HAMLINUX_INSTALLER:-}" ]; then
    mkdir -p "$ROOT/boot"
    [ -f build/image/disk/BOOTX64.EFI ] \
        && cp build/image/disk/BOOTX64.EFI "$ROOT/boot/BOOTX64.EFI"
    cp -L "$(ls -1 /boot/vmlinuz-* | sort -V | tail -1)" "$ROOT/boot/vmlinuz"
    # The initramfs cannot contain the copy of itself we are about to build,
    # so the PREVIOUS one is staged.  Building twice is what makes the staged
    # copy current: the second build packs the first build's output.
    [ -f "$OUT/initramfs.cpio.gz" ] \
        && cp "$OUT/initramfs.cpio.gz" "$ROOT/boot/initramfs.cpio.gz"
    install -m644 etc/rc.boot.installed "$ROOT/etc/rc.boot.installed"
    echo "[image] staged the installer's boot files into /boot"
fi

# --- packing, and who owns what ------------------------------------------
# The cpio records the uid/gid of every file and the kernel's initramfs
# unpacker honours them, so THIS is where the image's ownership is decided --
# there is no chown on this line to fix it up afterwards, and no writable
# root filesystem to fix it up in.
#
# It used to be decided by accident: the archive was written from the
# developer's checkout, so /bin, /etc and everything else came out owned by
# whatever uid built it (1000 on a typical box -- which is `dave` in
# /etc/passwd). Harmless while every process was root, and wrong the instant
# the DE session drops to uid 1001: the ownership of the system would be an
# artefact of the build machine.
#
# GNU cpio's -R sets one owner for a whole archive, and we need three. The
# kernel unpacker loops over CONCATENATED cpio archives (it eats the padding
# after each TRAILER!!! and reads the next header), which is the documented
# way to do exactly this, so we write one archive per owner and cat them:
#
#   0:0        everything else. uid 0 is the seat PID 1 actually runs in --
#              the Linux kernel starts /init as root and offers no choice --
#              so the system's files belong to the identity that maintains
#              them. /etc/shadow's 0600 becomes meaningful here: root-only.
#   1001:1001  /home/live. The session runs as 1001; a home owned by anyone
#              else is a home the user cannot write.
#   1:1        /home/hostowner, the home /etc/passwd gives uid 1.
#
# Directory ENTRIES for ./home come from the first archive (0:0, 0755): the
# parent of the homes is the system's, only the homes themselves are the
# users'.
echo "[image] packing initramfs"
CPIO="$OUT/initramfs.cpio"
: > "$CPIO"
( cd "$ROOT" && find . -path './home/*' -prune -o -print0 \
    | cpio --null -o -H newc --quiet -R 0:0 ) >> "$CPIO"
( cd "$ROOT" && find ./home/live -print0 \
    | cpio --null -o -H newc --quiet -R 1001:1001 ) >> "$CPIO"
( cd "$ROOT" && find ./home/hostowner -print0 \
    | cpio --null -o -H newc --quiet -R 1:1 ) >> "$CPIO"
gzip -9 < "$CPIO" > "$OUT/initramfs.cpio.gz"
rm -f "$CPIO"

# Use the host's newest Debian kernel. Building a kernel is not the interesting
# part of this port and can come later, when the install target is real
# hardware rather than QEMU.
KERNEL="$(ls -1 /boot/vmlinuz-* 2>/dev/null | sort -V | tail -1)"
[ -n "$KERNEL" ] || { echo "[image] ERROR: no /boot/vmlinuz-* on this host" >&2; exit 1; }
cp -L "$KERNEL" "$OUT/vmlinuz"

echo "[image] done:"
echo "  kernel:    $OUT/vmlinuz  ($(basename "$KERNEL"))"
echo "  initramfs: $OUT/initramfs.cpio.gz  ($(du -h "$OUT/initramfs.cpio.gz" | cut -f1))"
echo "  boot it:   scripts/hamlinux_vm.sh"
