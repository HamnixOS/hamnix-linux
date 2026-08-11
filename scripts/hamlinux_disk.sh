#!/usr/bin/env bash
# scripts/hamlinux_disk.sh — build an INSTALLED hamnix-linux disk.
#
# The initramfs image (scripts/hamlinux_image.sh) boots, but everything it
# holds is in RAM and gone at reboot.  The north star is a machine you install
# on and then use, so this produces the other thing: a partitioned disk with a
# real root filesystem, a bootloader, and persistence.
#
#   GPT
#   ├─ p1  ESP, FAT32   /boot   kernel + initramfs + the EFI bootloader
#   └─ p2  ext4         /       the Hamnix root
#
# BOOT PATH.  p1 holds a UNIFIED KERNEL IMAGE at /EFI/BOOT/BOOTX64.EFI --
# kernel, initramfs and command line in one PE binary that firmware executes
# directly.  That is deliberate: it is the one path that needs no bootloader
# installed on the target and no firmware NVRAM entry, so the same disk boots
# in QEMU under OVMF and on a real machine from a USB stick, with nothing
# machine-specific written anywhere.
#
# THE INITRAMFS IS STILL THERE, and does the same job it does on every Linux
# distribution: it is the small root that comes up first, and its `/init` --
# the Adder PID 1 -- mounts the real root and switches to it.  Hamnix spells
# that `bind '#sysroot' /`, which is exactly what etc/rc.boot does on the
# native line, so the boot process is the tree's own rather than a Linux one
# wearing its name.
#
# Nothing here needs root: everything is built into a file with mkfs's -d
# staging and mcopy, and the loop device is never involved.
#
# Usage: scripts/hamlinux_disk.sh [out.img] [size]
set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
export PATH="$PATH:/usr/sbin:/sbin"

OUT="${1:-build/image/hamnix-linux.img}"
SIZE="${2:-3G}"
STAGE="build/image/disk"
ESP="$STAGE/esp.img"
ROOTFS="$STAGE/root.img"

for t in sgdisk mkfs.vfat mkfs.ext4 mmd mcopy objcopy; do
    command -v "$t" >/dev/null || { echo "[disk] need $t" >&2; exit 1; }
done

# The root filesystem content is the same tree the initramfs is built from,
# minus the throwaway parts. Build it first so a stale image is never packed.
[ -d build/image/root ] || scripts/hamlinux_image.sh >/dev/null
[ -f build/image/vmlinuz ] || { echo "[disk] no kernel staged" >&2; exit 1; }

rm -rf "$STAGE"
mkdir -p "$STAGE"

# --- the root filesystem --------------------------------------------------
# A copy of the staged root, plus the things only a persistent system has.
ROOTDIR="$STAGE/rootdir"
cp -a build/image/root "$ROOTDIR"
mkdir -p "$ROOTDIR"/{home,var/log,var/lib/hpm,mnt,n/distro,srv}

# fstab. The Hamnix boot does not read it -- namespaces are assembled by the
# rc scripts -- but it is what a human and any Debian tooling in the distro
# namespace expect to find, and it records what the partitions ARE.
cat > "$ROOTDIR/etc/fstab" <<'FSTAB'
# /etc/fstab — what the partitions are.
#
# The Hamnix boot does not consult this file: the namespace is assembled by
# /etc/rc.boot with `bind`, which is the whole point of the design. It is here
# because it is the truth about the disk, and because Debian tooling running
# inside the distro namespace looks for it.
/dev/vda2  /      ext4  defaults           0 1
/dev/vda1  /boot  vfat  defaults,noatime   0 2
FSTAB

# The installed system's boot rc differs from the initramfs one in exactly one
# way: it brings the real root online first.
#
# It is staged TWICE, under both names, and that is not redundancy: an
# installed disk is the one boot with no HAMLINUX_RC hook, so until now nothing
# could drive an installed system non-interactively and the installed boot was
# the only one never under test -- which is exactly why `enter debian` had
# never worked there. HAMLINUX_DISK_RC stages a different /etc/rc.boot, and a
# test's rc can `source '/etc/rc.boot.installed'` to run the REAL one verbatim
# and then ask its questions.
install -m644 etc/rc.boot.installed "$ROOTDIR/etc/rc.boot.installed"
install -m644 "${HAMLINUX_DISK_RC:-etc/rc.boot.installed}" "$ROOTDIR/etc/rc.boot"

mkfs.ext4 -q -L hamnix -d "$ROOTDIR" -m 1 "$ROOTFS" 2600M
echo "[disk] root filesystem: $(du -h "$ROOTFS" | cut -f1)"

# --- the unified kernel image ---------------------------------------------
# One PE binary carrying the kernel, its command line and the initramfs. The
# stub is the kernel's own EFI entry point, so no bootloader is installed.
CMDLINE="$STAGE/cmdline.txt"
printf 'console=tty0 console=ttyS0,115200 root=/dev/vda2 rw panic=-1 loglevel=4' > "$CMDLINE"
STUB=/usr/lib/systemd/boot/efi/linuxx64.efi.stub
UKI="$STAGE/BOOTX64.EFI"
if [ -f "$STUB" ]; then
    # Section addresses must land ABOVE the stub's own image, and aligned to
    # its SectionAlignment -- objcopy will otherwise refuse with "section
    # below image base" and hand back a PE the firmware cannot execute.
    # Derived from the stub rather than hardcoded, because the numbers change
    # when systemd is updated.
    align=$(objdump -p "$STUB" | awk '/SectionAlignment/ {print strtonum($2)}')
    base=$(objdump -h "$STUB" | awk 'NF==7 {sz=strtonum("0x"$3); off=strtonum("0x"$4)} END {print sz+off}')
    next_at() {   # round $1 up to the next alignment boundary
        local v=$1
        echo $(( v + align - (v % align) ))
    }
    osrel_o=$(next_at "$base")
    cmdline_o=$(next_at $(( osrel_o + $(stat -Lc%s "$ROOTDIR/etc/os-release") )))
    linux_o=$(next_at $(( cmdline_o + $(stat -Lc%s "$CMDLINE") )))
    initrd_o=$(next_at $(( linux_o + $(stat -Lc%s build/image/vmlinuz) )))

    objcopy \
        --add-section .osrel="$ROOTDIR/etc/os-release" --change-section-vma .osrel=$(printf 0x%x $osrel_o) \
        --add-section .cmdline="$CMDLINE"             --change-section-vma .cmdline=$(printf 0x%x $cmdline_o) \
        --add-section .linux=build/image/vmlinuz      --change-section-vma .linux=$(printf 0x%x $linux_o) \
        --add-section .initrd=build/image/initramfs.cpio.gz \
        --change-section-vma .initrd=$(printf 0x%x $initrd_o) \
        "$STUB" "$UKI"
    echo "[disk] unified kernel image: $(du -h "$UKI" | cut -f1)"
else
    # No stub on this host: fall back to the kernel's OWN EFI stub, which
    # every x86_64 Debian kernel is built with. The command line then has to
    # come from the firmware, so this path works in QEMU (-append) but not
    # from a bare firmware boot menu -- say so rather than produce a disk that
    # mysteriously boots to the wrong root.
    cp build/image/vmlinuz "$UKI"
    echo "[disk] WARNING: no systemd-boot EFI stub on this host." >&2
    echo "[disk]          The kernel's own stub is used, so the command line" >&2
    echo "[disk]          must come from the firmware. Fine under QEMU with" >&2
    echo "[disk]          -append; a real machine needs systemd-boot-efi" >&2
    echo "[disk]          installed at build time." >&2
fi

# --- the ESP ---------------------------------------------------------------
ESP_MB=200
mkfs.vfat -F 32 -n HAMBOOT -C "$ESP" $((ESP_MB * 1024)) >/dev/null
mmd -i "$ESP" ::/EFI ::/EFI/BOOT
mcopy -i "$ESP" "$UKI" ::/EFI/BOOT/BOOTX64.EFI
# The plain kernel and initramfs go on too: a rescue boot, and what an
# installer would replace on an update.
mcopy -i "$ESP" build/image/vmlinuz ::/vmlinuz
mcopy -i "$ESP" build/image/initramfs.cpio.gz ::/initramfs.cpio.gz
echo "[disk] ESP: ${ESP_MB}M"

# --- assemble the disk -----------------------------------------------------
rm -f "$OUT"
truncate -s "$SIZE" "$OUT"
sgdisk --clear \
    --new=1:2048:+${ESP_MB}M --typecode=1:ef00 --change-name=1:HAMBOOT \
    --new=2:0:0              --typecode=2:8300 --change-name=2:hamnix \
    "$OUT" >/dev/null
# Write the filesystems into their partitions. dd at the byte offsets sgdisk
# just chose; no loop device, so no root and no host mount.
ESP_OFF=$((2048 * 512))
ROOT_OFF=$(( (2048 + ESP_MB * 1024 * 1024 / 512) * 512 ))
dd if="$ESP"    of="$OUT" bs=1M seek=$((ESP_OFF / 1048576))  conv=notrunc status=none
dd if="$ROOTFS" of="$OUT" bs=1M seek=$((ROOT_OFF / 1048576)) conv=notrunc status=none

echo "[disk] done: $OUT ($(du -h "$OUT" | cut -f1))"
echo "  boot it: scripts/hamlinux_vm.sh disk"
