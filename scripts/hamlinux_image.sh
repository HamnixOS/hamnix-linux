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

echo "[image] building $(( ${#APPS[@]} )) applications + the Adder PID 1"
BUILT=0; MISSING=()
for app in "${APPS[@]}"; do
    src="user/$app.ad"
    if [ ! -f "$src" ]; then MISSING+=("$app(no source)"); continue; fi
    if scripts/hamlinux_build.sh "$src" "$OUT/obj/$app.elf" >/dev/null 2>&1; then
        install -m755 "$OUT/obj/$app.elf" "$ROOT/bin/$app"
        BUILT=$((BUILT+1))
    else
        MISSING+=("$app")
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
WANT_MODULES="${HAMLINUX_MODULES:-virtio-gpu virtio_input evdev virtio_net virtio_blk ext4 vfat nls_ascii nls_cp437 overlay squashfs loop}"
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
