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

# THE IDENTITY OF THE ROOT PARTITION, decided once and used three times: in the
# kernel command line, in the GPT entry sgdisk creates, and in /etc/fstab. It
# is a partition GUID rather than a device name because a device name is a
# statement about one machine -- see the long note at the command line below.
ROOT_PARTUUID="${HAMLINUX_ROOT_PARTUUID:-$(cat /proc/sys/kernel/random/uuid)}"
BOOT_PARTUUID="${HAMLINUX_BOOT_PARTUUID:-$(cat /proc/sys/kernel/random/uuid)}"

# --- the root filesystem --------------------------------------------------
# A copy of the staged root, plus the things only a persistent system has.
ROOTDIR="$STAGE/rootdir"
cp -a build/image/root "$ROOTDIR"
mkdir -p "$ROOTDIR"/{home,var/log,var/lib/hpm,mnt,n/distro,srv}

# fstab. The Hamnix boot does not read it -- namespaces are assembled by the
# rc scripts -- but it is what a human and any Debian tooling in the distro
# namespace expect to find, and it records what the partitions ARE.
cat > "$ROOTDIR/etc/fstab" <<FSTAB
# /etc/fstab — what the partitions are.
#
# The Hamnix boot does not consult this file: the namespace is assembled by
# /etc/rc.boot with \`bind\`, which is the whole point of the design. It is here
# because it is the truth about the disk, and because Debian tooling running
# inside the distro namespace looks for it.
#
# BY PARTUUID, not by /dev/vda2. The device node is a statement about QEMU; the
# partition GUID is the same on every machine this disk is plugged into, and it
# is the same string the kernel command line uses.
PARTUUID=$ROOT_PARTUUID  /      ext4  defaults           0 1
PARTUUID=$BOOT_PARTUUID  /boot  vfat  defaults,noatime   0 2
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

# HAMLINUX_DISK_EXTRA=<dir> overlays <dir> onto the root partition before it is
# made. HAMLINUX_DISK_RC covers the one file a test needs MOST, but a test that
# reboots the machine needs a SECOND rc already on the disk before the first
# boot -- the disk cannot be rebuilt between the two boots without destroying
# the persistence the reboot is there to prove. Anything else an installed
# machine is supposed to already have (a trusted key, a seeded config) goes in
# the same way. It is an overlay, so it can also replace a staged file.
if [ -n "${HAMLINUX_DISK_EXTRA:-}" ]; then
    [ -d "$HAMLINUX_DISK_EXTRA" ] || {
        echo "[disk] HAMLINUX_DISK_EXTRA is not a directory: $HAMLINUX_DISK_EXTRA" >&2
        exit 1; }
    cp -a "$HAMLINUX_DISK_EXTRA/." "$ROOTDIR/"
    echo "[disk] overlaid $HAMLINUX_DISK_EXTRA onto the root"
fi

mkfs.ext4 -q -L hamnix -d "$ROOTDIR" -m 1 "$ROOTFS" 2600M
echo "[disk] root filesystem: $(du -h "$ROOTFS" | cut -f1)"

# --- the unified kernel image ---------------------------------------------
# One PE binary carrying the kernel, its command line and the initramfs. The
# stub is the kernel's own EFI entry point, so no bootloader is installed.
CMDLINE="$STAGE/cmdline.txt"
# THE COMMAND LINE NAMES NO DEVICE, AND THAT IS THE POINT.
#
# It used to say `root=/dev/vda2`. That is the VIRTIO disk: it exists in QEMU
# and on no physical machine on earth, where the same install is /dev/sda2 off
# a USB stick and /dev/nvme0n1p2 on a laptop. The comment in user/linuxinit.ad
# beside the root switch said "the device comes from the kernel's own command
# line, so one image boots any machine" -- true of the MECHANISM, false of the
# STRING this script baked into it.
#
# So the root is named by its GPT PARTITION GUID, chosen HERE and given to
# sgdisk below when partition 2 is created. The identifier travels with the
# partition: the same disk answers to it plugged into any machine, in any slot,
# behind any driver. user/linux-syscalls.c:sysroot_device resolves it by
# reading the GPT off every disk /sys/block lists -- no udev, no blkid -- and
# when it matches nothing it prints the identifier it wanted and every
# partition it did see, rather than mounting a guess.
#
# THE CONSOLE ARRANGEMENT, which is the other half of why a real machine
# looked dead:
#   earlycon=efifb   prints straight into the EFI framebuffer the firmware
#                    handed over, from the first line of the kernel, before
#                    any driver exists. It is the only thing that prints at
#                    all on a machine with no serial port and no fbcon yet.
#   keep_bootcon     keeps it after a "real" console registers. Without this
#                    the kernel silences earlycon the moment tty0 comes up --
#                    and tty0 comes up even with NO framebuffer behind it
#                    (CONFIG_VT's dummy console), so on the laptop the one
#                    console that could be read was turned off in favour of
#                    one that displayed nothing.
#   loglevel=7       the kernel's own boot messages. At loglevel=4 nothing
#                    below KERN_ERR reaches any console, so a perfect boot
#                    printed NOTHING between the EFI stub and the desktop.
#                    That is what the blinking cursor was.
#   console=ttyS0    stays LAST, because /dev/console follows the last
#                    console= and every gate in this tree reads the serial
#                    port. PID 1 mirrors its own lines to /dev/kmsg so they
#                    reach the screen as well -- see user/linuxinit.ad.
#
# HAMLINUX_CMDLINE still overrides the whole string; HAMLINUX_ROOT_PARTUUID
# pins the GUID (a test that rebuilds the disk and expects the same string).
DEFAULT_CMDLINE="console=tty0 earlycon=efifb keep_bootcon console=ttyS0,115200 root=PARTUUID=$ROOT_PARTUUID rw panic=-1 loglevel=7"
printf '%s' "${HAMLINUX_CMDLINE:-$DEFAULT_CMDLINE}" > "$CMDLINE"
echo "[disk] cmdline: $(cat "$CMDLINE")"
# WHAT THE IN-SYSTEM INSTALLER READS. user/hlinstall.ad copies this very UKI
# onto the target's ESP, so the target's root partition must answer to the
# PARTUUID baked in it. The installer cannot rewrite a PE section, so it does
# the other half: it reads this file and hands the GUID to sgdisk. Keeping the
# two in step is why the number is written down rather than re-generated.
printf '%s\n' "$ROOT_PARTUUID" > "$STAGE/root.partuuid"
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
# SIZED FROM WHAT GOES ON IT, not from a number somebody once measured. The
# three files here are the unified kernel image, the kernel and the initramfs,
# and they grow: staging the installer's own boot files (HAMLINUX_INSTALLER=1)
# roughly triples the initramfs, at which point a fixed 200M ESP overflows and
# mcopy says "Disk full" -- one line, mid-build, easy to read past, and the
# disk it leaves behind is missing whichever file did not fit.
ESP_NEED=$(( ( $(stat -Lc%s "$UKI") \
             + $(stat -Lc%s build/image/vmlinuz) \
             + $(stat -Lc%s build/image/initramfs.cpio.gz) ) / 1048576 ))
ESP_MB=$(( ESP_NEED + ESP_NEED / 5 + 32 ))       # 20% slack for FAT overhead
[ "$ESP_MB" -lt 200 ] && ESP_MB=200
# And the two partitions have to fit in the disk that will be truncated below.
# dd would otherwise write the root filesystem past the end of the image and
# the failure would surface as an unmountable root at boot.
SIZE_MB=$(numfmt --from=iec "$SIZE")
SIZE_MB=$(( SIZE_MB / 1048576 ))
if [ $(( ESP_MB + 2600 + 2 )) -gt "$SIZE_MB" ]; then
    echo "[disk] ERROR: a ${ESP_MB}M ESP and a 2600M root do not fit in $SIZE." >&2
    echo "[disk]        Build a bigger disk: scripts/hamlinux_disk.sh $OUT 4G" >&2
    exit 1
fi
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
# --partition-guid is the whole trick: the partition is CREATED with the GUID
# the command line already names, so the identifier is not a description of the
# disk that could drift from it -- it is the same string in both places, by
# construction, and `sgdisk -i 2` on the result proves it.
sgdisk --clear \
    --new=1:2048:+${ESP_MB}M --typecode=1:ef00 --change-name=1:HAMBOOT \
    --partition-guid=1:"$BOOT_PARTUUID" \
    --new=2:0:0              --typecode=2:8300 --change-name=2:hamnix \
    --partition-guid=2:"$ROOT_PARTUUID" \
    "$OUT" >/dev/null
# Prove it rather than assume it: a mistyped GUID here produces a disk that
# boots on this host (where the cmdline and the table were written together)
# and nowhere else, which is the exact class of fault this file is fixing.
GOT="$(sgdisk -i 2 "$OUT" | awk -F': ' '/Partition unique GUID/ {print tolower($2)}')"
if [ "$GOT" != "$(printf '%s' "$ROOT_PARTUUID" | tr 'A-Z' 'a-z')" ]; then
    echo "[disk] ERROR: partition 2's GUID is $GOT, but the command line says" >&2
    echo "[disk]        root=PARTUUID=$ROOT_PARTUUID. This disk would not boot." >&2
    exit 1
fi
echo "[disk] root partition GUID: $GOT (matches the command line)"
# Write the filesystems into their partitions. dd at the byte offsets sgdisk
# just chose; no loop device, so no root and no host mount.
ESP_OFF=$((2048 * 512))
ROOT_OFF=$(( (2048 + ESP_MB * 1024 * 1024 / 512) * 512 ))
dd if="$ESP"    of="$OUT" bs=1M seek=$((ESP_OFF / 1048576))  conv=notrunc status=none
dd if="$ROOTFS" of="$OUT" bs=1M seek=$((ROOT_OFF / 1048576)) conv=notrunc status=none

echo "[disk] done: $OUT ($(du -h "$OUT" | cut -f1))"
echo "  boot it: scripts/hamlinux_vm.sh disk"
