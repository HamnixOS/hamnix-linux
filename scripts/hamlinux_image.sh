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
mkdir -p "$ROOT"/{bin,etc,proc,sys,dev,srv,n,tmp,root,lib,lib64,var/log,usr/bin}

# The applications that go in /bin. Kept to things that build AND run today
# (measured -- see HANDOFF.md §5); the point of the image is to boot, not to be
# complete. `hamsh` is the important one: it is PID 1 after linuxinit execs it.
APPS=(
    hamsh
    ls cat echo cp mv rm mkdir rmdir ln touch pwd
    grep sed sort uniq head tail wc cut tr
    find du df stat tree file
    date sleep true false yes seq basename dirname
    env_show printenv id hostname uname
    ps kill
    tar gzip base64 cksum md5sum
    more less
    bc cal
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
    ldd "$bin" 2>/dev/null | awk '/=> \//{print $3} /^\t\//{print $1}' | sort -u | while read -r lib; do
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
         hamde os-release lsb-release debian_version profile; do
    [ -f "etc/$f" ] && install -m644 "etc/$f" "$ROOT/etc/$f"
done
# The graphical runlevel. Kept separate from Hamnix's etc/rc.d/rc.5, which
# brings the DE up through the declarative service supervisor and the kernel
# scene compositor -- neither of which exists on this line yet.
mkdir -p "$ROOT/etc/rc.d"
install -m644 etc/rc.d/rc.5.linux "$ROOT/etc/rc.d/rc.5"
# The namespace a DE-spawned shell gets. Same reasoning as rc.5 above: this is
# the Linux-line variant, and its header says what it leaves out and why.
install -m644 etc/rc.de-user.linux "$ROOT/etc/rc.de-user"

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
WANT_MODULES="${HAMLINUX_MODULES:-virtio-gpu virtio_input evdev virtio_net virtio_blk ext4 overlay}"
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

echo "[image] packing initramfs"
( cd "$ROOT" && find . -print0 | cpio --null -o -H newc --quiet ) | gzip -9 > "$OUT/initramfs.cpio.gz"

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
