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
mkdir -p "$ROOT"/{bin,etc,proc,sys,dev,srv,n,tmp,root,lib,lib64,var,usr/bin}

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
for f in hostname hosts passwd group issue motd; do
    [ -f "etc/$f" ] && install -m644 "etc/$f" "$ROOT/etc/$f"
done

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
