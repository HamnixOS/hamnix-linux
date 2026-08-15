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
# /boot is the mount point for the ESP. etc/rc.boot.installed does
# `bind '#esp' /boot` so that user/bootlogd.ad can write the boot log onto the
# FAT partition of the stick -- the one filesystem on this medium that opens on
# any computer the owner might carry it to. hamsh's bind does not create its
# mount point, so the directory has to be on the root filesystem already.
mkdir -p "$ROOTDIR"/{home,var/log,var/lib/hpm,mnt,n/distro,srv,boot}

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

# THE PACKAGE DATABASE, and without it `hpm update` is a NO-OP FOREVER on every
# machine installed from this disk.
#
# Measured at 7213661a by tests/linux/install_from_usb.sh: the installed machine
# reached 255.one over TLS, authenticated an index of 126 packages against the
# shipped trust root, and then upgraded NOTHING and exited 0 -- because
# /var/lib/hpm was an empty directory, so hpm had no record of what is on the
# disk and nothing to compare the index against. The owner's permanent rule is
# that work published here must be updatable ON the machine, and it was failing
# on the one path that makes it true.
#
# IT IS EMITTED HERE, against $ROOTDIR, and that placement is the argument. This
# is the exact directory mkfs.ext4 is about to turn into the root filesystem --
# after hamlinux_image.sh staged it and after the two rc.boot files above -- so
# the database describes the tree it ships INSIDE rather than a tree upstream of
# it. scripts/hpm_installed_db.py reads every file list out of the package
# TARBALLS (not from anything reconstructed here) and records a package only
# when this root really carries every file it holds; see its header for why an
# approximate list is worse than no list at all.
#
# NO CHANNEL, NO DATABASE, AND IT SAYS SO. A disk built on a tree with no
# build/repo cannot know what it is carrying, and a guessed database is the one
# outcome this must never produce.
#
# HAMLINUX_NO_INSTALLED_DB=1 BUILDS A DISK THAT RECORDS NOTHING, and it exists
# for one situation that is real rather than convenient: a gate that installs a
# DIFFERENT channel's entire world over this one -- a private channel at a
# synthetic version, to give the machine a past this tree never had. The
# database describes THIS tree's channel, and hpm correctly refuses to install
# a second version of a package it already records ("already installed at a
# different version"), so such a gate has to start blank. It is loud, it is
# named at every call site, and NOTHING in the shipping path passes it: a disk
# built for a person always carries the database, because the failure it closes
# is one nobody sees until they type `hpm update` on their own machine.
DBCHAN="${HAMLINUX_HPM_CHANNEL:-build/repo/linux}"
if [ "${HAMLINUX_NO_INSTALLED_DB:-0}" = 1 ]; then
    echo "[disk] HAMLINUX_NO_INSTALLED_DB=1: this disk records NO installed"
    echo "[disk] packages. \`hpm update\` on it will REFUSE. Do not ship it."
elif [ -f "$DBCHAN/index.json" ]; then
    mkdir -p "$ROOTDIR/var/lib/hpm"
    python3 scripts/hpm_installed_db.py "$DBCHAN" "$ROOTDIR" \
        "$ROOTDIR/var/lib/hpm/installed.json" \
    || { echo "[disk] REFUSING to build a disk with a database this script " \
              "could not vouch for -- see the refusal above" >&2; exit 1; }
else
    echo "[disk] NO PACKAGE DATABASE: $DBCHAN/index.json does not exist, so"
    echo "[disk] this disk carries no /var/lib/hpm/installed.json and \`hpm"
    echo "[disk] update\` on it will REFUSE (it cannot know what is installed)."
    echo "[disk] Build the channel first: scripts/hamlinux_packages.py --out build/repo"
fi

# HAMLINUX_DISK_EXTRA=<dir> overlays <dir> onto the root partition before it is
# made -- and it is applied AFTER the database above on purpose, so a gate can
# substitute a doctored one (an older recorded version, to force a real
# upgrade) without the shipping path ever emitting anything but the truth.
# HAMLINUX_DISK_RC covers the one file a test needs MOST, but a test that
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
#   keep_bootcon     IS GONE, AND HERE IS THE MEASUREMENT THAT RETIRED IT.
#                    It was here because "tty0 comes up even with NO
#                    framebuffer behind it (CONFIG_VT's dummy console)", which
#                    is TRUE and is visible in this tree's own guest log:
#                      [0.229599] Console: colour dummy device 80x25
#                      [1.365101] efifb: probing for efifb
#                      [1.371319] Console: switching to colour frame buffer
#                    so for 1.14 s the only console that can draw is earlycon.
#                    What the note missed is what keeping it costs AFTER that.
#                    earlycon=efifb and fbcon are two writers into ONE
#                    framebuffer with independent cursors. While every line is
#                    a printk they stay in step and draw the same text in the
#                    same place, which is why this was never noticed. The
#                    moment anything writes to /dev/console that is NOT a
#                    printk -- which, now that /dev/console is tty0, is the
#                    whole shell -- fbcon's cursor advances and earlycon's does
#                    not, and the next kernel message is drawn OVER the lines
#                    the shell just wrote. That is the owner's "previous lines
#                    not being cleared", and putting the shell on the screen
#                    would have made it worse, not better.
#                    The 1.14 s window is not paid in lost text: the VT layer
#                    stores what is written to it even while dummycon is the
#                    driver, and fbcon REDRAWS that buffer when it takes over,
#                    so the lines printed during the window appear the instant
#                    the framebuffer console binds. Proved by screendump, not
#                    argued -- tests/linux/console_screen.sh asserts that the
#                    kernel's early lines are on the screen with earlycon
#                    already handed off.
#   loglevel=7       the kernel's own boot messages. At loglevel=4 nothing
#                    below KERN_ERR reaches any console, so a perfect boot
#                    printed NOTHING between the EFI stub and the desktop.
#                    That is what the blinking cursor was.
#   console=tty0     IS NOW LAST, AND THAT IS THE FIX FROM THE FIRST BOOT ON
#                    METAL. It used to be first and `console=ttyS0` last,
#                    "because /dev/console follows the last console= and every
#                    gate in this tree reads the serial port". Both halves of
#                    that sentence are true and the conclusion was wrong: PID 1
#                    mirrors ITS OWN lines to /dev/kmsg, so PID 1 was visible --
#                    and nothing else was. The owner's Lenovo, 2026-08-15,
#                    printed every linuxinit line and then stopped dead at
#                    "namespace ready -- exec /bin/hamsh /etc/rc.boot", because
#                    at that instant the output stops being PID 1's and starts
#                    being the SHELL's, and the shell writes to /dev/console,
#                    which was a serial port the machine does not have. The boot
#                    was fine. It was talking into a wire that was not there.
#                    It is also the only descriptor a person can TYPE into: with
#                    ttyS0 last, the interactive shell etc/rc.boot.full hands off
#                    to reads a keyboard nobody is holding.
#   console=ttyS0    stays REGISTERED, second-to-last, so printk still reaches
#                    the serial port and every gate still sees the kernel's boot.
#                    The shell's own output reaches it too, because
#                    user/linux-syscalls.c:consmirror copies writes to
#                    /dev/console onto the serial port whenever the two are
#                    different devices. That is what lets the SHIPPED string be
#                    the string the gates boot -- the alternative, a gate-only
#                    HAMLINUX_CMDLINE, was rejected because this command line is
#                    baked into a PE section of the UKI and user/hlinstall.ad
#                    copies that very UKI onto the target's ESP, so an override
#                    would mean nothing ever tests what ships.
#
# HAMLINUX_CMDLINE still overrides the whole string; HAMLINUX_ROOT_PARTUUID
# pins the GUID (a test that rebuilds the disk and expects the same string).
#   printk.devkmsg=on
#                    WITHOUT THIS THE BOOT LOG SILENTLY LOSES LINES, AND IT
#                    LOSES THEM IN THE SHAPE OF A LOG THAT LOOKS FINE.
#                    /dev/kmsg is how user/linux-syscalls.c:consmirror gets the
#                    SHELL's output into the kernel ring, which is what
#                    user/bootlogd.ad persists onto the stick. The kernel's
#                    default for writes to that node is `ratelimit`: a global
#                    burst of ten records per five seconds, everything else
#                    dropped on the floor with no error to the writer.
#                    MEASURED, this tree, the shipped medium booted as
#                    usb-storage: the recovered \HAMNIX.LOG ran to 7.917s, then
#                    stopped for FOUR SECONDS -- swallowing every `[rc.5]` line,
#                    `rc.boot: up`, and the end-of-boot marker -- and resumed at
#                    11.905s. Nothing anywhere reported a problem; the file was
#                    the right size, had its header and its terminator, and was
#                    missing exactly the part of the boot a person would be
#                    looking for. That is the worst way for a diagnostic file to
#                    be wrong, and it is precisely the failure this whole
#                    arrangement exists to stop.
#                    It is set HERE rather than by a sysctl write in the rc
#                    because a boot parameter applies from the FIRST record,
#                    before any userland has run: a runtime write leaves a
#                    window in which the kernel's own early output and PID 1's
#                    opening burst are still being dropped. user/linuxinit.ad
#                    READS IT BACK and warns if this kernel did not honour it,
#                    because a setting that is accepted and does not take is
#                    the success-shaped answer NORTH_STAR.md forbids.
DEFAULT_CMDLINE="earlycon=efifb console=ttyS0,115200 console=tty0 root=PARTUUID=$ROOT_PARTUUID rw panic=-1 loglevel=7 printk.devkmsg=on"
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
# THE BOOT LOG, PREALLOCATED HERE, AND EVERY WORD OF THAT IS LOAD BEARING.
#
# The owner boots this stick on a Lenovo with no serial cable, no shell and no
# second machine. When a boot goes wrong the only evidence that survives is a
# photograph of the last forty lines. So the stick keeps its own log, and it
# keeps it HERE, on the FAT32 ESP, because FAT32 is the one filesystem on this
# medium that mounts on Windows, on macOS and on Linux with nothing installed
# -- he can power the machine off, plug the stick into whatever is nearby, and
# open a file. The ext4 root is fine on his Debian host and is not fine
# anywhere else. user/bootlogd.ad is the writer and its header argues the rest.
#
# PREALLOCATED, TO ITS FULL SIZE, AT BUILD TIME, and that is what makes it
# survive the power button on a filesystem with no journal. Because the file
# already exists at full length, every runtime write is an OVERWRITE IN PLACE:
# no cluster is allocated, the FAT chain is never mutated, the directory
# entry's size and start cluster never change. The only thing that has to reach
# the medium is the data blocks -- and bootlogd opens the file O_SYNC, so they
# have. ext4's journal would not have protected those blocks either;
# tests/linux/install_from_usb.sh measured exactly that, a power cut inside the
# 5 s commit window losing a write the journal had kept the filesystem
# perfectly consistent about.
#
# IT IS ALSO WHY THE LOG CANNOT FILL THE FILESYSTEM. The size is this constant,
# decided here, and there is no code path at runtime that extends the file.
#
# AND IT SHIPS WITH TEXT IN IT SAYING IT HAS NOT BEEN WRITTEN YET. An empty
# file looks identical whether nothing was written or the write went somewhere
# else, which is the exact bug this effort came out of. So the unwritten state
# says that it is the unwritten state, in words aimed at the person holding the
# stick -- and tests/linux/boot_log.sh asserts that this sentinel is present in
# a freshly built image and GONE from a booted one, which is what makes the
# readback mean something.
BOOTLOG_BYTES=$((256 * 1024))     # must match BOOTLOG_CAP in user/bootlogd.ad
BOOTLOG_SEED="$STAGE/HAMNIX.LOG"
{
    cat <<'SEED'
==== HAMNIX BOOT LOG ====

THIS FILE HAS NOT BEEN WRITTEN BY ANY BOOT YET.

It was created, at this full size, when the medium was built. If you are
reading this line then this stick has either never been booted, or a boot
did not get far enough to start /bin/bootlogd, or bootlogd could not write
here. Any of those is itself the finding -- it is NOT an empty log.

When a boot does write here, this text is replaced by that boot's kernel
log, including every line the shell and the desktop printed.

SEED
    # Newlines, not NULs: a partially written log then opens as ordinary text
    # in any editor rather than as a NUL sea some of them refuse to display.
    head -c "$BOOTLOG_BYTES" /dev/zero | tr '\0' '\n'
} | head -c "$BOOTLOG_BYTES" > "$BOOTLOG_SEED"
[ "$(stat -Lc%s "$BOOTLOG_SEED")" = "$BOOTLOG_BYTES" ] || {
    echo "[disk] ERROR: the boot-log seed is not $BOOTLOG_BYTES bytes." >&2
    exit 1; }

ESP_NEED=$(( ( $(stat -Lc%s "$UKI") \
             + $(stat -Lc%s build/image/vmlinuz) \
             + $(stat -Lc%s build/image/initramfs.cpio.gz) \
             + BOOTLOG_BYTES ) / 1048576 ))
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
# FIRST-LEVEL, 8.3, UPPER CASE: the name is what somebody sees when they plug
# this stick into a Windows or macOS machine, sitting beside EFI/. Nothing
# about it needs a long-filename entry to be found.
mcopy -i "$ESP" "$BOOTLOG_SEED" ::/HAMNIX.LOG
echo "[disk] ESP: ${ESP_MB}M (including a ${BOOTLOG_BYTES}-byte preallocated \\HAMNIX.LOG boot log)"

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
