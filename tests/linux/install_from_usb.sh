#!/usr/bin/env bash
# tests/linux/install_from_usb.sh — BOOT THE LIVE USB, INSTALL ONTO A BLANK
# DISK, PULL THE USB OUT, BOOT THE INSTALLED MACHINE, UPDATE IT OVER THE
# NETWORK, AND REBOOT AGAIN.
#
# THE LOOP NOTHING HAS EVER DRIVEN
# ================================
# tests/linux/installed_update_live.sh is 30/0 and proves that an INSTALLED
# machine takes a published update and survives a reboot. It gets its installed
# machine by BUILDING one with scripts/hamlinux_disk.sh, on the host, from the
# development tree. Not one line of the installer runs in it.
#
# That is the whole gap. The owner is about to dd a live image, boot a laptop
# from it, and click Install Hamnix. Between "a disk built by the host boots"
# and "a disk the INSTALLER wrote boots" sits every line of user/hlinstall.ad,
# and the difference is not academic:
#
#   * the host has sgdisk, mkfs.vfat and mkfs.ext4 on its PATH. The installer
#     has to find them on the MEDIUM, and until the commit above this one it
#     could only find them in a Debian namespace that a USB stick does not
#     carry (see DEFECT 1 there, and the `instroot` assertion below).
#   * the host writes the kernel command line and the partition GUID TOGETHER,
#     so they cannot disagree. The installer copies a UKI it cannot rewrite and
#     has to give the target's root partition the GUID that UKI already names.
#   * the host knows where its output goes. The installer has to find a disk,
#     and must not find the stick it booted from.
#
# WHY IT IS DRIVEN AS USB-STORAGE ONTO NVMe AND NOT AS TWO VIRTIO DISKS
# ====================================================================
# Because 146649bd measured the difference and it was a real bug: `usb-storage`
# registered at 1.336 s and its partitions did not appear until 2.964 s, so a
# root scan that ran in between found an EMPTY /sys/block, gave up, and the
# machine came up looking perfect while running entirely from RAM. A virtio
# boot resolves on the first look and hides that completely. HANDOFF.md's
# end-to-end installer run was `install --auto /dev/vdb` on virtio, with the
# Debian medium attached as a third virtio drive by scripts/hamlinux_vm.sh --
# a configuration the owner will never have.
#
# So: the live image is a USB mass-storage device on an xHCI controller, the
# target is NVMe, and NOTHING attaches a Debian disk. That is his laptop.
#
# TWO DISKS ALSO FORCE THE HARD CASE. With one candidate, "find the root" is
# satisfied by taking the only disk there is. With two, the resolver has to go
# by partition GUID -- and the installed disk deliberately carries the SAME
# root GUID as the medium it came from (user/hlinstall.ad says so at length),
# so boot 2 detaches the USB entirely rather than trusting a tie-break.
#
# HOW A BOOT IS PROVED TO BE THE INSTALLED SYSTEM, WHICH IS NOT WHAT THE
# HANDOFF SAYS
# ======================================================================
# The standing advice is to check WHICH rc RAN, because
# `rc.boot: hamnix-linux (installed)` "exists only on the disk root". THAT IS
# NOT TRUE OF THIS MEDIUM AND IT COST A PASS TO FIND OUT.
# scripts/hamlinux_disk.sh line 96 stages etc/rc.boot.installed as /etc/rc.boot
# on EVERY disk it builds, and the live USB image is a disk it builds. Measured:
# the live medium's /etc/rc.boot is byte-identical to etc/rc.boot.installed.
# So the live stick prints that exact line too.
#
# It still proves something -- that a root switch happened at all, as opposed to
# the initramfs rc (`rc.boot: handing off to an interactive shell`) running from
# RAM. It does not prove WHICH root. So this gate proves the installed system
# three independent ways, and the first of them is the one that actually
# discriminates:
#
#   1. /etc/rc.boot ON THE TARGET IS A THREE-LINE INDIRECTION. user/hlinstall.ad
#      writes `source '/etc/rc.boot.installed'` rather than a copy, deliberately,
#      so that an hpm upgrade of the rc reaches an installed machine. The live
#      medium carries the full file. Read off the image by the HOST, with the
#      guest powered off.
#   2. The USB device is not attached to the VM at all, so the only disk the
#      firmware can boot is the one the installer wrote.
#   3. The root the kernel resolved is an nvme node, in the guest's own log.
#
# WHAT THIS FILE DOES NOT ANSWER
# ==============================
# It drives /bin/install, which is the engine. It does not click through
# user/haminstallui.ad's pages with a mouse -- that wizard spawns exactly
# `/bin/install --auto <disk> ...` and is checked here only for the one thing
# that made it lie (the "install complete" handshake, asserted below against
# both programs' text). A gate that drove the pointer would be measuring the
# compositor, which tests/linux/installed_update_live.sh already does.
#
# Nothing here says anything about physical hardware: real firmware, a real
# stick's timings, a real NVMe, or Secure Boot (the UKI is UNSIGNED -- verified
# at 146649bd, rva=0 size=0 -- so he must turn Secure Boot off, and no VM can
# tell him that).

# WHERE THIS STANDS, MEASURED (three boots under OVMF): 53 PASSED, 0 FAILED on a
# full run, 52 with HAMLINUX_INSTUSB_REUSE=1 -- the difference is the one
# assertion on the seed disk pass, which a reuse run does not make. The negative
# control, HAMLINUX_INSTUSB_NO_DB=1, is 38 PASSED, 0 FAILED with every database
# assertion inverted. All three were run on this tree.
#
# THE LAST RED IS CLOSED, AND IT WAS THIS: `hpm update` was a NO-OP on a freshly
# installed machine. The index authenticated over TLS and then nothing upgraded,
# because /var/lib/hpm was an empty directory -- hpm had no record of what is on
# the disk, so it compared the index against nothing and exited 0. The medium
# now carries /var/lib/hpm/installed.json, emitted by scripts/hamlinux_disk.sh
# from the channel's TARBALLS against the very directory it mkfs's, and
# hlinstall's copy_top("var") carries it to the target. MEASURED on the
# installed disk after two power cycles: `update done (upgraded=3)`, a file
# whose bytes were a marker string is 568 bytes of the real manual page, and the
# database on the disk records hamnix-man at 1.0.23 where the medium shipped it
# at 1.0.22. The negative control, same medium and same network with the
# database withheld, leaves that file stale and makes hpm REFUSE by name.
#
# THE PREVIOUS MEASUREMENT, kept because it is what this section was written
# against: 33 PASSED, 2 FAILED, both reds that one defect.
#
# GREEN, and this is the whole loop the owner asked for, minus one step:
#   * the live medium boots as usb-storage on xHCI and switches root (not RAM)
#   * the installer finds sgdisk/mkfs on the MEDIUM with no Debian disk anywhere
#   * it partitions a blank NVMe, makes both filesystems, copies the system,
#     writes /EFI/BOOT/BOOTX64.EFI onto the target ESP and prints
#     "install complete"
#   * with the USB DETACHED the machine boots its own disk, resolving
#     root=PARTUUID to /dev/nvme0n1p2
#   * it reaches 255.one over TLS and AUTHENTICATES the index (126 packages)
#   * it reboots and phase 1's marker is still on the disk (so the root really
#     is persistent), and it goes all the way to `rc.boot: up` after the update
#
# NOW ALSO GREEN, and this is the step that was missing:
#   * the medium carries a package database whose every file list came out of
#     the package TARBALLS -- 89 packages, 238 paths, checked one by one against
#     the tarballs and one by one against the medium's own ext4
#   * `hpm update` on the installed machine upgrades three packages for real
#   * a file's CONTENT changes on the installed disk, and is still changed after
#     a power cycle -- read by the host off the ext4, and read back by the guest
#
# AND NOW THE KERNEL MODULES, WHICH WAS THE NEXT HOLE AND IS CLOSED HERE.
# hamnix-drivers-base and hamnix-drivers-hw used to be excluded from the
# database for ONE file each -- modules.dep.<group>, which the image did not
# stage -- so `hpm update` could not upgrade the modules that find the disk or
# the nine touchpad and HID drivers 1.0.24 added. The image stages that file
# now (scripts/hamlinux_image.sh, after depmod), both packages are recorded, and
# this gate downgrades them alongside the three inert ones so the update has
# real work to do. Three files are the marker string on the medium -- one .ko
# from each package and hw's dependency table -- and after the update and a
# power cycle the two modules are ELF again (one of them byte-identical to the
# channel's copy) and the table is real dependency lines, read both by the host
# off the ext4 and by the machine with its own cat.
#
# THE HOLE THAT IS LEFT, AND IT IS A DIFFERENT ONE. user/linuxinit.ad loads
# /etc/modules BEFORE the root switch, out of the INITRAMFS, and
# user/hlinstall.ad copies /boot/BOOTX64.EFI -- kernel and initramfs in one UKI
# -- onto the target BYTE FOR BYTE and never regenerates it. So an upgraded
# module lands on the root filesystem, is what `modprobe` resolves from that
# moment on, and is NOT what the next boot loads. Nothing in this tree
# regenerates a UKI on an installed machine. Closing that is not this change.
#
# STILL NOT COVERED BY ANY OF IT: 36 of the channel's 126 packages are not on
# the medium and so are not recorded -- the GPU drivers, the Vulkan stack, the
# 407 nouveau firmware blobs, and six coreutils the image never staged. Those
# are correctly absent, not missing.

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && cd .. && pwd)"
cd "$PROJ_ROOT"
# sgdisk, sfdisk, debugfs and e2fsck all live in sbin, and a non-root login
# usually has neither sbin on PATH. scripts/hamlinux_disk.sh has carried the
# same line since it was written.
export PATH="$PATH:/usr/sbin:/sbin"

# Isolated before anything is built or booted: gates_are_private.sh is 3/0 and
# every new gate has to keep it there.
. tests/linux/private_ns.sh
priv_ns_reexec "$@"
. tests/linux/reap.sh

pass=0; fail=0
ok()   { echo "instusb: PASS $*"; pass=$((pass+1)); }
bad()  { echo "instusb: FAIL $*"; fail=$((fail+1)); }
info() { echo "instusb: INFO $*"; }
say()  { echo "instusb: --- $*"; }

WORK="${HAMLINUX_INSTUSB_WORK:-$HOME/.hamnix-build/install-from-usb}"
mkdir -p "$WORK"
reap_track "$WORK/reaped"
reap_on_exit
info "$(priv_ns_describe)"
info "work directory: $WORK"

LIVE="$WORK/live-usb.img"          # the medium he will dd
NVME="$WORK/target-nvme.img"       # the machine's own disk, blank at the start
PART="$WORK/part.img"              # a partition, carved out for inspection

# NOTHING HERE MOUNTS ANYTHING, and that is forced rather than chosen.
# priv_ns_reexec puts this gate in a user namespace where it is uid 0 but
# CANNOT set up a loop device -- measured: "failed to setup loop device" --
# and `sudo` inside that namespace cannot even read its own config
# ("/etc/sudo.conf is owned by uid 65534"). So the disks are read the way
# scripts/hamlinux_disk.sh WRITES them: by byte offset, with sgdisk, mtools and
# debugfs, none of which need a kernel mount. It is also the stronger position
# -- a gate that never mounts a filesystem cannot be the thing that corrupted
# it, and no physical device is reachable from here at all.
#
# `dd` a partition out and look at it. Measured at 1.6 s for 3.6 GB on this
# host, which is cheaper than any of the boots. NOTHING IS EVER WRITTEN BACK:
# the installed disk is read-only evidence from the moment the installer
# finishes, so no assertion about it can be an artefact of this gate.
part_geom() {  # part_geom <img> <partno> -> "<byte offset> <byte size>"
    sfdisk -J "$1" 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)["partitiontable"]
ss=d.get("sectorsize",512)
p=d["partitions"][int(sys.argv[1])-1]
print(p["start"]*ss, p["size"]*ss)' "$2"
}
carve() {  # carve <img> <partno> -- extract into $PART
    local g off sz
    g="$(part_geom "$1" "$2")" || return 1
    [ -n "$g" ] || return 1
    off="${g% *}"; sz="${g#* }"
    rm -f "$PART"
    dd if="$1" of="$PART" bs=1M skip=$((off / 1048576)) \
       count=$(( (sz + 1048575) / 1048576 )) status=none
}
fs_has()  { debugfs -R "stat $2" "$1" 2>/dev/null | grep -q '^Inode:'; }
fs_cat()  { debugfs -R "cat $2" "$1" 2>/dev/null; }
fs_ls()   { debugfs -R "ls $2" "$1" 2>/dev/null; }
cleanup_mounts() { rm -f "$PART"; }

# uki_initrd_geom <file> -> "<VirtualSize> <SizeOfRawData> <PointerToRawData>"
# of the .initrd section of a unified kernel image. VirtualSize is the length
# the EFI stub hands the kernel -- the field user/bootsync.ad moves -- and
# SizeOfRawData is the ceiling scripts/hamlinux_disk.sh reserved. Read out of
# the PE, so it is a statement about the file the firmware will run rather than
# about anything a build log said.
uki_initrd_geom() {
    python3 - "$1" 2>/dev/null <<'PYEOF'
import struct, sys
b = open(sys.argv[1], "rb").read()
lfa = struct.unpack_from("<I", b, 0x3C)[0]
if b[lfa:lfa + 4] != b"PE\0\0":
    raise SystemExit(1)
n = struct.unpack_from("<H", b, lfa + 6)[0]
o = struct.unpack_from("<H", b, lfa + 20)[0]
for i in range(n):
    s = lfa + 24 + o + i * 40
    if b[s:s + 8].rstrip(b"\0") == b".initrd":
        vs, va, raw, ptr = struct.unpack_from("<IIII", b, s + 8)
        print(vs, raw, ptr)
        break
else:
    raise SystemExit(1)
PYEOF
}

# =========================================================================
# 0. THE ARTEFACTS.
# =========================================================================
# The medium is built the way scripts/hamlinux_image.sh documents and in that
# order, because the order is load bearing: the installer's /boot has to
# contain the UKI from a PREVIOUS lean pass, and going round the loop twice
# feeds the output back into the input (36M -> 119M -> 285M, measured there).
#
#   1. lean image      -> initramfs with no /boot
#   2. hamlinux_disk   -> makes build/image/disk/{BOOTX64.EFI,root.partuuid}
#   3. INSTALLER image -> stages those into /boot, and the partitioning tools
#                         into /usr/lib/instroot
#   4. hamlinux_disk   -> the live USB medium, with the install-driving rc
# REUSE=1 skips the three IMAGE passes (build/image is already staged); the
# medium itself is still rebuilt unless it is also already there, because it is
# the cheap pass and the one that carries this gate's rc.

# ---- THE CHANNEL, WHICH IS WHERE THE PACKAGE DATABASE COMES FROM --------
# scripts/hamlinux_disk.sh emits /var/lib/hpm/installed.json from the built
# channel's TARBALLS, against the very directory it is about to mkfs. No
# channel, no database, and `hpm update` on the installed machine has nothing
# to compare the index against -- which is the defect this section was added
# for, measured red at 7213661a.
#
# HAMLINUX_INSTUSB_NO_DB=1 IS THE NEGATIVE CONTROL, and it is the only way to
# reproduce that red now: the medium is built with the database deleted, and
# every assertion below flips to demanding hpm REFUSE rather than silently
# succeed. A gate that can only show green cannot show that the green means
# anything.
CHAN="${HAMLINUX_HPM_CHANNEL:-build/repo/linux}"
NO_DB="${HAMLINUX_INSTUSB_NO_DB:-0}"
if [ "$NO_DB" = 1 ]; then
    say "NEGATIVE CONTROL: HAMLINUX_INSTUSB_NO_DB=1 -- the medium will carry NO package database"
fi
if [ -f "$CHAN/index.json" ]; then
    info "channel: $CHAN ($(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["packages"]))' "$CHAN/index.json") packages)"
else
    bad "no built channel at $CHAN/index.json -- the disk builder cannot emit a package database and this gate cannot test the update. Run: python3 scripts/hamlinux_packages.py --out build/repo --version <v>"
    exit 1
fi

if [ "${HAMLINUX_INSTUSB_REUSE:-0}" = 1 ]; then
    say "reusing the staged build/image (HAMLINUX_INSTUSB_REUSE=1)"
    grep -q 'INCOMPLETE' "$WORK/img2.log" 2>/dev/null && bad "the staged image's instroot is incomplete"
else
    say "building the live medium (four passes; this is the slow part)"
    scripts/hamlinux_image.sh >"$WORK/img1.log" 2>&1 || {
        bad "lean image build"; tail -20 "$WORK/img1.log"; exit 1; }
    scripts/hamlinux_disk.sh "$WORK/seed.img" 3G >"$WORK/disk1.log" 2>&1 || {
        bad "seed disk build"; tail -20 "$WORK/disk1.log"; exit 1; }
    grep -q '^\[installed-db\]' "$WORK/disk1.log" \
        && ok "$(grep -m1 '^\[installed-db\] [0-9]' "$WORK/disk1.log" | sed 's/^\[installed-db\] //')" \
        || bad "scripts/hamlinux_disk.sh emitted no package database -- see $WORK/disk1.log"
    HAMLINUX_INSTALLER=1 scripts/hamlinux_image.sh >"$WORK/img2.log" 2>&1 || {
        bad "installer image build"; tail -20 "$WORK/img2.log"; exit 1; }
    grep -q 'INCOMPLETE' "$WORK/img2.log" && {
        bad "the medium's /usr/lib/instroot is incomplete -- see $WORK/img2.log"
        grep -a 'instroot\|ERROR' "$WORK/img2.log" | head -8 | sed 's/^/        /'; }
fi

# ---- THE MEDIUM'S OWN rc, which drives the install ----------------------
# A person clicks Install Hamnix and the wizard spawns `/bin/install --auto`.
# This runs the same program with the same argv from the medium's rc, because a
# gate cannot click and because the engine is the part that can fail on his
# hardware. The wizard's own contract is asserted separately, below.
cat >"$WORK/rc.install" <<'RCEOF'
# /etc/rc.boot on the LIVE MEDIUM, for tests/linux/install_from_usb.sh.
ln -s /dev/console /dev/cons
echo 'INSTUSB-LIVE: the medium booted'
echo 'INSTUSB-LIVE: /proc/partitions:'
cat /proc/partitions
echo 'INSTUSB-LIVE: is there an instroot on this medium?'
ls /usr/lib/instroot/usr/sbin
echo 'INSTUSB-LIVE: /boot:'
ls /boot
echo 'INSTUSB-LIVE: starting the installer'
install --auto /dev/nvme0n1 --hostname hamlaptop --user dave --user-pass dave --root-pass root
echo 'INSTUSB-LIVE: the installer returned'
echo 'INSTUSB-LIVE: /proc/partitions after:'
cat /proc/partitions
echo 'INSTUSB-LIVE-DONE'
poweroff
RCEOF

# ---- THE INSTALLED MACHINE'S rc, DELIVERED BY THE INSTALLER ITSELF ------
# The update has to run ON the machine the installer wrote, and this gate did
# not build that disk -- so there has to be a hook. The first attempt wrote one
# onto the target afterwards with `debugfs -w`, and it DID NOT WORK: debugfs
# creates the inode but does not update the group descriptor's itable_unused,
# so the very next e2fsck said "Entry 'rc.boot.installed.orig' in /etc has
# deleted/unused inode. Clear? yes" and threw both files away. The boot that
# followed ran the stock rc, the update never happened, and the only reason
# that was not read as an hpm failure is that the desktop showed up in a log
# that should have had hpm in it.
#
# So the hook is delivered the way everything else on the target is: by BEING
# ON THE MEDIUM. hlinstall copies the live root onto the target, so a file
# staged here arrives there. /etc/rc.boot.installed is the right one to use --
# the installer writes the target's /etc/rc.boot as a three-line INDIRECTION to
# it, which is the discriminator asserted above, so using it leaves that proof
# intact. Nothing is written to the installed disk by this gate at any point.
#
# TWO PHASES OUT OF ONE FILE, with no `else`: sourcing a file that does not
# exist returns non-zero (the idiom etc/rc.d/rc.5 already uses for its
# self-test), so phase 1 runs when the marker is absent and WRITES the marker
# as a one-line script that sources phase 2. The next boot sources it and runs
# phase 2 instead.
EXTRA="$WORK/extra"
rm -rf "$EXTRA"; mkdir -p "$EXTRA/etc"
sed "s|^source '/etc/rc.d/rc.5'|source '/etc/instusb.phase'\nsource '/etc/rc.d/rc.5'|" \
    etc/rc.boot.installed >"$EXTRA/etc/rc.boot.installed"
grep -q "instusb.phase" "$EXTRA/etc/rc.boot.installed" || {
    bad "could not splice the phase hook into etc/rc.boot.installed"; exit 1; }
cat >"$EXTRA/etc/instusb.phase" <<'RCEOF'
# Staged by tests/linux/install_from_usb.sh onto the LIVE medium, carried onto
# the installed disk by the installer's copy, and run by the installed
# machine's own /etc/rc.boot.installed.
source '/var/lib/instusb.done'
if $status > 0 {
    echo 'INSTUSB-P1: first boot of the installed machine'
    hpm refresh
    echo 'INSTUSB-P1: hpm list before'
    hpm list
    echo 'INSTUSB-P1: THE DRIVER TABLE BEFORE THE UPDATE'
    cat '@DEP_HW@'
    echo 'INSTUSB-P1: BEFORE-END'
    hpm update
    echo 'INSTUSB-P1: hpm list after'
    hpm list
    echo "source '/etc/instusb.p2'" > /var/lib/instusb.done
    echo 'INSTUSB-P1-DONE'
    # SLEEP, THEN POWER OFF, AND BOTH HALVES ARE LOAD BEARING. The first
    # version of this let the host KILL the VM the moment INSTUSB-P1-DONE
    # appeared, and the marker file did not survive: ext4 commits its journal
    # on a timer (5 s by default) and SIGKILL to QEMU is a power cut, so the
    # write was still in the guest's page cache. The next boot ran phase 1
    # AGAIN -- which reads exactly like "the installed root is not
    # persistent", the most alarming failure this tree has, and it was the
    # harness. Powering off from INSIDE the guest is what a person does and is
    # the only thing that makes the reboot honest.
    sleep 8
    poweroff
}
RCEOF
cat >"$EXTRA/etc/instusb.p2" <<'RCEOF'
echo 'INSTUSB-P2: this machine has been rebooted since the update'
hpm list
echo 'INSTUSB-P2: the file the update rewrote, read back after a power cycle'
cat /usr/share/man/cat.1.md
echo 'INSTUSB-P2: and two files no upgrade was entitled to touch'
cat /etc/rc.boot
ls /bin/cat
echo 'INSTUSB-P2: THE DRIVER TABLE AFTER THE UPDATE AND A POWER CYCLE'
cat '@DEP_HW@'
echo 'INSTUSB-P2: AFTER-END'
echo 'INSTUSB-P2: and the two mangled modules, read back by the machine itself'
ls '@KO_BASE@'
ls '@KO_HW@'
echo 'INSTUSB-P2-DONE'
RCEOF

# ---- WHAT MAKES THE UPDATE MEANINGFUL, AND WHY IT IS A FIXTURE ----------
# 1.0.23 is published and served, and this tree BUILDS 1.0.23, so a machine
# installed from this medium is already level with the channel and a correct
# `hpm update` legitimately has nothing to do. "update done (upgraded=0)" would
# pass a grep and prove nothing: it is the same output the broken machine
# produced, arrived at honestly. So the medium is given a database that records
# THREE packages one version behind, which is what a machine that took the
# medium before the release actually looks like, and the channel then has real
# work to do. installed_update_wsysver.sh builds its baseline the same way and
# for the same reason.
#
# IT IS DERIVED FROM THE REAL ONE, not written by hand. scripts/hamlinux_disk.sh
# left build/image/disk/rootdir/var/lib/hpm/installed.json behind on the seed
# pass above; every file list in it came out of the package tarballs, and the
# only thing changed here is three version strings. The lists are still checked
# against the tarballs, on the medium, further down.
#
# THE THREE ARE INERT ON PURPOSE. hamnix-man is 21 markdown files, cal is a
# calendar and bc is a calculator. An upgrade is a remove followed by an
# install, so a failed download leaves a hole where the old file was -- and a
# hole in /bin/hamsh or /bin/cat is a machine that does not boot. Nothing in the
# boot path is put at risk to measure the mechanism. hamnix-vkprobe was the
# obvious fourth and is deliberately NOT here: it depends on hamnix-vulkan,
# which this medium does not carry, so upgrading it would pull a 24-file GPU
# stack down as a side effect and measure that instead.
#
# ALL THREE DEPEND ON hamnix-init>=1, AND THAT IS THE POINT OF CHECKING. hpm
# resolves an upgrade through the normal solver, so a dependency the database
# does not record is one it INSTALLS -- and hamnix-init owns
# /etc/rc.boot.installed, which on this medium carries the phase hook driving
# this gate. It is recorded (see the hamnix-init note in
# scripts/hamlinux_image.sh), so the solver finds it satisfied and lays nothing
# down. If that ever regresses, phase 2 stops running and this gate says so.
#
# AND THE TWO THAT ARE NOT INERT, WHICH IS THE POINT OF ADDING THEM.
# hamnix-drivers-base and hamnix-drivers-hw are the kernel modules the machine
# boots with -- the driver that finds the disk and, since 1.0.24, the nine
# touchpad and HID modules measured working on the owner's Lenovo. Until the
# commit above this one NEITHER COULD EVER BE UPGRADED: the image did not stage
# their modules.dep.<group>, so scripts/hpm_installed_db.py left them out of the
# database, and what is not recorded is never upgraded. They are downgraded here
# for exactly the reason the other three are -- so the channel has real work to
# do -- and everything that follows about what an upgrade DELETES is aimed at
# them, because these are the files a wrong list would cost a machine.
#
# THEY ARE NOT INERT AND THAT IS SURVIVABLE, MEASURED RATHER THAN HOPED.
# user/linuxinit.ad calls load_modules() BEFORE the root switch, out of the
# INITRAMFS, by absolute path -- so every module in either package is already in
# the kernel before anything on the disk is read. A mangled or missing copy on
# the ROOT FILESYSTEM cannot stop this machine booting, which is what makes it
# safe to mangle one from each and still assert the boot. (It is also the
# separate hole named at the top of this file: the UKI on the ESP carries its
# own copies and no package updates it.)
DB_SRC="build/image/disk/rootdir/var/lib/hpm/installed.json"
DOWNGRADE="hamnix-man hamnix-cal hamnix-bc hamnix-drivers-base hamnix-drivers-hw"
MANGLED_MAN="usr/share/man/cat.1.md"
MANGLE_MARK="INSTUSB-STALE-CONTENT-THE-UPDATE-MUST-REPLACE-THIS"
# THE THREE DRIVER PATHS ARE READ OUT OF THE TARBALLS, not written here. A
# hard-coded kernel-version path would rot the first time the build host's
# kernel moved, and it would rot SILENTLY -- as a file the update "replaced"
# that no package ever owned. Refuses by name if a chosen module is not in the
# package that is supposed to own it.
python3 - "$CHAN" >"$WORK/mangle.paths" <<'PYEOF' || { echo "cannot resolve the driver paths to mangle"; exit 1; }
import json, os, sys
sys.path.insert(0, "scripts")
import hpm_installed_db as H
chan = sys.argv[1]
idx = {e["name"]: e["version"]
       for e in json.load(open(os.path.join(chan, "index.json")))["packages"]}
want = [("MANGLED_KO_BASE", "hamnix-drivers-base", "kernel/fs/nls/nls_ascii.ko"),
        ("MANGLED_KO_HW", "hamnix-drivers-hw", "kernel/drivers/hid/hid-multitouch.ko"),
        ("MANGLED_DEP_HW", "hamnix-drivers-hw", "modules.dep.hw")]
for var, pkg, tail in want:
    files, _ = H.package_files(chan, pkg, idx[pkg])
    hit = [f for f in files if f.endswith("/" + tail)]
    if len(hit) != 1:
        raise SystemExit("instusb: %s owns %d files ending in %s; expected 1"
                         % (pkg, len(hit), tail))
    print("%s=%s" % (var, hit[0]))
print("KVER=%s" % sorted(files)[0].split("/")[2])
PYEOF
. "$WORK/mangle.paths"
[ -n "${MANGLED_KO_BASE:-}" ] && [ -n "${MANGLED_KO_HW:-}" ] && \
[ -n "${MANGLED_DEP_HW:-}" ] && [ -n "${KVER:-}" ] || {
    echo "instusb: the driver mangle paths did not resolve"; exit 1; }
MACHINE_DEP="lib/modules/$KVER/modules.dep"
if [ "$NO_DB" = 1 ]; then
    # THE NEGATIVE CONTROL, and it is produced the way the defect was: the disk
    # builder is pointed at a channel that is not there, so it emits nothing and
    # /var/lib/hpm is the empty directory scripts/hamlinux_image.sh created. The
    # overlay cannot do this -- `cp -a` only adds files -- and deleting from the
    # finished image afterwards is the debugfs trap this gate already paid for.
    DISK_CHAN_OVERRIDE="$WORK/no-such-channel"
    info "negative control: the live medium is built with HAMLINUX_HPM_CHANNEL=$DISK_CHAN_OVERRIDE, so it carries no installed.json at all"
else
    # The seed pass above leaves the real database in the staging rootdir. A
    # REUSE run (or a run following the negative control, whose live pass
    # deliberately emitted none) may not have it, so it is regenerated from the
    # same script and the same channel rather than skipped.
    if [ ! -f "$DB_SRC" ] && [ -d build/image/disk/rootdir ]; then
        info "no $DB_SRC; regenerating it from $CHAN"
        python3 scripts/hpm_installed_db.py "$CHAN" build/image/disk/rootdir \
            "$DB_SRC" >"$WORK/dbregen.log" 2>&1 \
            || { bad "could not regenerate the package database"; tail -5 "$WORK/dbregen.log"; }
    fi
fi
if [ "$NO_DB" != 1 ] && [ -f "$DB_SRC" ]; then
    mkdir -p "$EXTRA/var/lib/hpm" "$EXTRA/usr/share/man"
    python3 - "$DB_SRC" "$EXTRA/var/lib/hpm/installed.json" $DOWNGRADE <<'PYEOF'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
want = set(sys.argv[3:])
db = json.load(open(src))
hit = []
for p in db["packages"]:
    if p["name"] in want:
        p["version"] = "1.0.22"
        hit.append(p["name"])
missing = sorted(want - set(hit))
if missing:
    raise SystemExit("instusb: the disk builder did not record %s as installed, "
                     "so this fixture cannot downgrade it" % " ".join(missing))
# hpm's own serialisation shape (user/hpm.ad:_installed_rewrite_with_added), so
# the file on the medium is indistinguishable from one hpm wrote.
out = ['{\n  "schema": 1,\n  "packages": [\n']
out.append(",\n".join(
    '    {\n      "name": "%s",\n      "version": "%s",\n      "installed_at": "",\n'
    '      "pinned": false,\n      "target": "%s",\n      "files": [%s]\n    }'
    % (p["name"], p["version"], p.get("target", "#hamnix-system"),
       ", ".join('"%s"' % f for f in p["files"])) for p in db["packages"]))
out.append("\n  ]\n}\n")
open(dst, "w").write("".join(out))
print("instusb: fixture records %d packages, %s at 1.0.22"
      % (len(db["packages"]), " ".join(sorted(hit))))
PYEOF
    [ -s "$EXTRA/var/lib/hpm/installed.json" ] || {
        bad "could not build the downgraded package-database fixture"; exit 1; }
    # AND A FILE WHOSE CONTENT THE UPDATE MUST CHANGE. `hpm update` exiting 0 is
    # not evidence that anything moved; a byte on the disk is. This one is owned
    # by hamnix-man and by nothing else (checked below), so restoring it is hpm
    # unlinking the recorded path and laying the 1.0.23 tarball's copy down.
    ok "the medium's package database records $(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["packages"]))' "$EXTRA/var/lib/hpm/installed.json") packages, three of them one version behind the channel"
elif [ "$NO_DB" != 1 ]; then
    bad "no $DB_SRC after the seed disk pass -- scripts/hamlinux_disk.sh did not emit a package database"
fi
# THE STALE FILE IS STAGED IN BOTH DIRECTIONS, and that is what makes it a
# control rather than a decoration. On the green run the update must replace it;
# on the negative control -- same medium, same install, same network, no
# database -- it must STILL BE THERE afterwards. One assertion, two runs, and
# the difference between them is the whole claim.
mkdir -p "$EXTRA/usr/share/man"
printf '%s\n' "$MANGLE_MARK" >"$EXTRA/$MANGLED_MAN"
# AND THE SAME TRICK ON THE DRIVERS, WHICH IS THE ASSERTION THAT MATTERS.
# "hpm update said upgraded=5" is an exit code. These are bytes: one .ko owned
# by hamnix-drivers-base, one owned by hamnix-drivers-hw (hid-multitouch, one of
# the nine 1.0.24 added for the owner's touchpad), and the hw dependency table,
# each replaced on the medium by the marker string. After the update every one
# of them must be the package's real content -- ELF for the two modules, the
# dependency lines for the table -- and after the power cycle it must still be.
# On the negative control, the same three must STILL SAY THE MARKER.
mkdir -p "$EXTRA/$(dirname "$MANGLED_KO_BASE")" \
         "$EXTRA/$(dirname "$MANGLED_KO_HW")" \
         "$EXTRA/$(dirname "$MANGLED_DEP_HW")"
printf '%s\n' "$MANGLE_MARK" >"$EXTRA/$MANGLED_KO_BASE"
printf '%s\n' "$MANGLE_MARK" >"$EXTRA/$MANGLED_KO_HW"
printf '%s\n' "$MANGLE_MARK" >"$EXTRA/$MANGLED_DEP_HW"
info "mangled on the medium: $MANGLED_KO_BASE, $MANGLED_KO_HW, $MANGLED_DEP_HW"
# The two phase scripts were written from QUOTED heredocs above, so these paths
# are substituted here rather than interpolated there -- an unquoted heredoc
# would also expand `$status`, which is hamsh's and not the host shell's, and
# phase 1's two-phase idiom rests on it.
for f in "$EXTRA/etc/instusb.phase" "$EXTRA/etc/instusb.p2"; do
    sed -i -e "s|@DEP_HW@|/$MANGLED_DEP_HW|g" \
           -e "s|@KO_BASE@|/$MANGLED_KO_BASE|g" \
           -e "s|@KO_HW@|/$MANGLED_KO_HW|g" "$f"
done
if grep -q '@DEP_HW@\|@KO_BASE@\|@KO_HW@' "$EXTRA/etc/instusb.phase" \
        "$EXTRA/etc/instusb.p2"; then
    bad "a placeholder survived substitution in the phase scripts"; exit 1
fi

if [ "${HAMLINUX_INSTUSB_REUSE:-0}" = 1 ] && [ -f "$LIVE" ]; then
    :
else
    HAMLINUX_DISK_RC="$WORK/rc.install" HAMLINUX_DISK_EXTRA="$EXTRA" \
    HAMLINUX_HPM_CHANNEL="${DISK_CHAN_OVERRIDE:-$CHAN}" \
        scripts/hamlinux_disk.sh "$LIVE" 4G >"$WORK/disk2.log" 2>&1 || {
        bad "live medium build"; tail -20 "$WORK/disk2.log"; exit 1; }
fi
[ -f "$LIVE" ] || { bad "no live medium at $LIVE"; exit 1; }
info "live medium: $(stat -c%s "$LIVE") bytes"

# ---- THE MEDIUM CARRIES WHAT THE INSTALLER NEEDS ------------------------
# Asserted on the IMAGE, before any boot, because all four of these were
# missing from the image the boot work left behind and each one fails the
# install at a different place.
say "what the medium actually carries"
carve "$LIVE" 2 || { bad "cannot carve the live root partition"; exit 1; }
for f in /bin/hlinstall /bin/install /bin/haminstallui /etc/hamde/apps/installer.desktop; do
    fs_has "$PART" "$f" && ok "the medium carries $f" || bad "the medium has no $f"
done
# THE MARKER THAT MAKES THE INSTALLER REACHABLE BY A PERSON. Without it
# user/hamdesktop.ad, user/hampanelscene.ad and user/hamappmenu.ad all hide the
# Install Hamnix launcher (X-Hamnix-LiveOnly=true), so the installer is on the
# medium and startable from nowhere in the GUI. This is the only assertion here
# about what he can actually CLICK.
fs_has "$PART" /etc/installer-medium \
    && ok "the medium carries /etc/installer-medium, so the desktop, the panel and the Applications menu will offer Install Hamnix" \
    || bad "no /etc/installer-medium -- the installer is on the medium but HIDDEN in every menu that could start it"
fs_has "$PART" /boot/BOOTX64.EFI \
    && ok "the medium carries /boot/BOOTX64.EFI for the target's ESP" \
    || bad "no /boot/BOOTX64.EFI -- the installer has nothing to make the target bootable with"
MEDIUM_PARTUUID="$(fs_cat "$PART" /boot/root.partuuid | tr -d '[:space:]' | tr 'A-Z' 'a-z')"
if [ -n "$MEDIUM_PARTUUID" ]; then
    ok "the medium carries /boot/root.partuuid ($MEDIUM_PARTUUID)"
else
    bad "no /boot/root.partuuid -- the target's root would get a GUID the copied UKI does not name"
fi
# THE DEFECT THIS GATE EXISTS FOR. Without these three the installer reaches
# `bind '#distro' /`, finds no Debian medium on a USB stick, and cannot
# partition anything.
for t in sgdisk mkfs.vfat mkfs.ext4; do
    fs_ls "$PART" /usr/lib/instroot/usr/sbin | grep -q "$t" \
        && ok "the medium carries $t (no Debian disk needed)" \
        || bad "the medium has no $t -- the installer cannot partition"
done
# AND THE LIVE rc IS THE ONE THAT LOOKS LIKE AN INSTALLED ONE. Recorded here so
# the discriminator used after the install is a measurement, not a claim.
# ---- THE PACKAGE DATABASE, READ OFF THE MEDIUM ITSELF -------------------
# Everything here is read out of the ext4 filesystem on the medium with
# debugfs, not out of the staging directory that produced it. The claim being
# checked is about the disk the owner will hold.
#
# AND THE LISTS ARE CHECKED AGAINST THE TARBALLS, EVERY PACKAGE, EVERY FILE.
# hpm upgrades by REMOVING the recorded files and installing the new version
# (user/hpm.ad, cmd_remove), so a database whose lists are approximate makes
# the first update delete the wrong files on a machine he is standing in front
# of. This is the assertion that says they are not approximate: for each
# recorded package, open <name>-<version>.tar.gz and compare its regular-file
# entries under files/ with what the database says, as sets.
if [ "$NO_DB" = 1 ]; then
    if fs_has "$PART" /var/lib/hpm/installed.json; then
        bad "negative control: the medium carries an installed.json and it was not supposed to"
    else
        ok "negative control: the medium carries NO /var/lib/hpm/installed.json (this is 7213661a's state, reproduced)"
    fi
elif fs_has "$PART" /var/lib/hpm/installed.json; then
    fs_cat "$PART" /var/lib/hpm/installed.json >"$WORK/medium-installed.json"
    if [ -s "$WORK/medium-installed.json" ]; then
        ok "the medium carries /var/lib/hpm/installed.json ($(stat -c%s "$WORK/medium-installed.json") bytes)"
    else
        bad "the medium's installed.json is empty"
    fi
    python3 - "$WORK/medium-installed.json" "$CHAN" >"$WORK/dbcheck.txt" 2>&1 <<'PYEOF'
import json, os, sys, tarfile
db = json.load(open(sys.argv[1]))
chan = sys.argv[2]
# The published index says which version's tarball each recorded package would
# be compared against. The fixture records three at 1.0.22, which this channel
# does not carry -- their lists came from the 1.0.23 tarball, so that is what
# they are checked against.
idx = {e["name"]: e["version"]
       for e in json.load(open(os.path.join(chan, "index.json")))["packages"]}
checked = mismatched = 0
claimed = {}
lines = []
for p in db["packages"]:
    name = p["name"]
    ver = idx.get(name)
    if ver is None:
        lines.append("NOTINCHANNEL %s" % name)
        continue
    prefix = "%s-%s/files/" % (name, ver)
    tarpath = os.path.join(chan, "packages", "%s-%s.tar.gz" % (name, ver))
    real = set()
    for ti in tarfile.open(tarpath, "r:gz"):
        if ti.name.startswith(prefix) and ti.isfile():
            rel = ti.name[len(prefix):]
            if rel:
                real.add(rel)
    # user/hpm.ad:_is_machine_owned -- hpm neither writes nor CLAIMS this path
    # when it already exists, and a database that claimed it would have the
    # first upgrade delete the machine's boot script.
    real.discard("etc/rc.boot")
    recorded = set(p["files"])
    checked += 1
    if recorded != real:
        mismatched += 1
        lines.append("MISMATCH %s extra=%s missing=%s"
                     % (name, sorted(recorded - real)[:4], sorted(real - recorded)[:4]))
    for f in recorded:
        claimed.setdefault(f, []).append(name)
dupes = sorted(f for f, ns in claimed.items() if len(ns) > 1)
lines.append("CHECKED %d" % checked)
lines.append("MISMATCHED %d" % mismatched)
lines.append("FILES %d" % len(claimed))
lines.append("DUPES %d" % len(dupes))
for f in dupes[:10]:
    lines.append("DUPE %s %s" % (f, " ".join(claimed[f])))
lines.append("RCBOOT %d" % len([1 for p in db["packages"] if "etc/rc.boot" in p["files"]]))
print("\n".join(lines))
PYEOF
    DB_CHECKED="$(grep -m1 '^CHECKED ' "$WORK/dbcheck.txt" | awk '{print $2}')"
    DB_MISMATCH="$(grep -m1 '^MISMATCHED ' "$WORK/dbcheck.txt" | awk '{print $2}')"
    DB_FILES="$(grep -m1 '^FILES ' "$WORK/dbcheck.txt" | awk '{print $2}')"
    DB_DUPES="$(grep -m1 '^DUPES ' "$WORK/dbcheck.txt" | awk '{print $2}')"
    DB_RCBOOT="$(grep -m1 '^RCBOOT ' "$WORK/dbcheck.txt" | awk '{print $2}')"
    if [ "${DB_MISMATCH:-x}" = 0 ] && [ "${DB_CHECKED:-0}" -gt 0 ]; then
        ok "every one of the $DB_CHECKED recorded packages has the file list its TARBALL actually contains ($DB_FILES distinct paths) -- not one is reconstructed"
    else
        bad "the medium's file lists do not match the tarballs (checked=${DB_CHECKED:-?} mismatched=${DB_MISMATCH:-?})"
        grep '^MISMATCH\|^NOTINCHANNEL' "$WORK/dbcheck.txt" | head -8 | sed 's/^/        /'
    fi
    if [ "${DB_DUPES:-x}" = 0 ]; then
        ok "no path is claimed by more than one package, so no upgrade can delete a file a different package owns"
    else
        bad "$DB_DUPES path(s) are claimed by two packages -- upgrading either would delete the other's file"
        grep '^DUPE ' "$WORK/dbcheck.txt" | head -6 | sed 's/^/        /'
    fi
    # hamnix-init IS THE ONE EVERY OTHER PACKAGE DEPENDS ON. If it is not
    # recorded, the solver treats every upgrade as needing a fresh hamnix-init
    # install, which lays /etc/rc.boot.installed down again -- and that is the
    # file a release improves the boot with, so an unrecorded hamnix-init also
    # means an installed machine no update can ever improve.
    if grep -q '"hamnix-init"' "$WORK/medium-installed.json"; then
        ok "hamnix-init is recorded, so an upgrade of anything that depends on it does not drag a fresh copy of the boot scripts in"
    else
        bad "hamnix-init is NOT recorded -- every upgrade would reinstall it and overwrite /etc/rc.boot.installed"
    fi
    if [ "${DB_RCBOOT:-x}" = 0 ]; then
        ok "no package claims etc/rc.boot, so an upgrade cannot take the machine's boot script (user/hpm.ad:_is_machine_owned)"
    else
        bad "$DB_RCBOOT package(s) claim etc/rc.boot -- the first upgrade would leave the machine with no boot script"
    fi
    # AND EVERY RECORDED PATH IS REALLY ON THE MEDIUM. "Installed" has to mean
    # installed: a record for a package the image never staged would have hpm
    # remove-then-install something the machine never had. One debugfs run over
    # a command file, so 200-odd stats cost one open of a 4 GB image.
    python3 -c '
import json,sys
db=json.load(open(sys.argv[1]))
for p in db["packages"]:
    for f in p["files"]:
        print("stat /"+f)' "$WORK/medium-installed.json" >"$WORK/dbstat.cmds"
    debugfs -f "$WORK/dbstat.cmds" "$PART" >"$WORK/dbstat.out" 2>&1
    DB_WANT="$(wc -l <"$WORK/dbstat.cmds")"
    DB_GOT="$(grep -c '^Inode:' "$WORK/dbstat.out" || true)"
    if [ "$DB_WANT" -gt 0 ] && [ "$DB_GOT" = "$DB_WANT" ]; then
        ok "all $DB_WANT recorded paths exist on the medium's root filesystem -- every package it calls installed really is"
    else
        bad "only $DB_GOT of $DB_WANT recorded paths exist on the medium -- the database claims packages the medium does not carry"
        grep -B1 'File not found' "$WORK/dbstat.out" | head -8 | sed 's/^/        /'
    fi
    # THE INSTRUMENT IS SHOWN ABLE TO SAY NO. A `stat` of a path that is not
    # there must not be counted as an Inode line, or the check above would pass
    # on an empty medium.
    echo "stat /var/lib/hpm/there-is-no-such-file" >"$WORK/dbstat.neg"
    debugfs -f "$WORK/dbstat.neg" "$PART" 2>&1 | grep -q '^Inode:' \
        && bad "the debugfs presence check reports an inode for a file that does not exist -- it cannot tell present from absent" \
        || ok "the presence check answers NO for a path that is not on the medium (so the count above means something)"
else
    bad "the medium carries no /var/lib/hpm/installed.json -- \`hpm update\` on the installed machine will have nothing to compare the index against"
fi

fs_cat "$PART" /etc/rc.boot >"$WORK/live-rc.boot"
LIVE_RCBOOT_MD5="$(md5sum "$WORK/live-rc.boot" | cut -d' ' -f1)"
info "the LIVE medium's /etc/rc.boot is md5 $LIVE_RCBOOT_MD5, $(wc -l <"$WORK/live-rc.boot") lines"

# ---- THE WIZARD'S SUCCESS HANDSHAKE, IN THE SOURCE ----------------------
# user/haminstallui.ad decides an install worked by scanning the child's output
# for one literal string. If the engine stops printing it, the wizard paints
# "Install FAILED" over a perfect install -- which is what it did until the
# commit above this one. Asserted as a PAIR so the two cannot drift apart
# again without a red gate.
WIZ_NEEDLE='install complete'
if grep -q "\"$WIZ_NEEDLE\"" user/haminstallui.ad; then
    if grep -q "$WIZ_NEEDLE" user/hlinstall.ad; then
        ok "the wizard's success string ('$WIZ_NEEDLE') is printed by the engine it spawns"
    else
        bad "user/haminstallui.ad waits for '$WIZ_NEEDLE' and user/hlinstall.ad never prints it -- the wizard would report FAILED after a successful install"
    fi
else
    info "user/haminstallui.ad no longer waits for '$WIZ_NEEDLE'; this assertion is stale"
fi

# =========================================================================
# 1. BOOT THE LIVE MEDIUM AS A USB STICK, WITH A BLANK NVMe BESIDE IT.
# =========================================================================
say "creating a blank NVMe target"
rm -f "$NVME"
truncate -s 6G "$NVME"
# BLANK MEANS BLANK, and it is checked: a target with a stale partition table
# would let a do-nothing installer look like a working one.
if [ "$(head -c 1048576 "$NVME" | tr -d '\0' | wc -c)" = 0 ]; then
    ok "the NVMe target is all zeroes before the install"
else
    bad "the NVMe target is not blank"
fi

QEMU_BIN="$(command -v qemu-system-x86_64 || true)"
[ -n "$QEMU_BIN" ] || { bad "no qemu-system-x86_64"; exit 1; }

boot_vm() {  # boot_vm <name> <seconds> <attach_usb:0|1> [done-marker]
    # THE DONE-MARKER IS NOT A CONVENIENCE. An installed boot ends by starting
    # the desktop, which never returns, so without it every such boot burns its
    # full timeout -- ten minutes of wall clock per boot to re-learn something
    # the guest said at t=8 s. The marker is a string the GUEST prints when it
    # has finished the thing being measured; the VM is stopped once it appears.
    # Boots that end in `poweroff` do not need one.
    local name="$1" secs="$2" usb="$3" marker="${4:-}"
    local d="$WORK/$name"
    rm -rf "$d"; mkdir -p "$d"
    cp /usr/share/OVMF/OVMF_VARS_4M.fd "$d/OVMF_VARS.fd"
    local args=(
        -m 2048 -smp 2 -no-reboot
        -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd
        -drive "if=pflash,format=raw,unit=1,file=$d/OVMF_VARS.fd"
        -netdev user,id=n0 -device virtio-net-pci,netdev=n0
        -display none -vga none -device virtio-gpu-pci
        -serial "file:$d/serial.log"
        -enable-kvm -cpu host
        -device qemu-xhci,id=xhci -device usb-kbd -device usb-tablet
        # The target. NVMe, because that is what is inside a laptop.
        -drive "file=$NVME,if=none,format=raw,id=nvme0"
        -device nvme,drive=nvme0,serial=INSTUSBTGT
    )
    if [ "$usb" = 1 ]; then
        # HIS CONFIGURATION: a mass-storage device on xHCI, not virtio.
        args+=(
            -drive "file=$LIVE,if=none,format=raw,id=usbstick"
            -device usb-storage,bus=xhci.0,drive=usbstick,bootindex=0
        )
    fi
    # QEMU IS STARTED DIRECTLY, not under `timeout`, so that the pid handed to
    # reap_add is the pid of the VM. Wrapping it means registering the
    # WRAPPER: killing that on the way out leaves the emulator orphaned and
    # running, which is exactly the leak tests/linux/reap.sh was written for
    # (61 strays found alive one morning, the oldest eight hours old).
    "$QEMU_BIN" "${args[@]}" >"$d/qemu.out" 2>&1 &
    local vm=$!
    reap_add "$vm"
    local waited=0 hit=0
    while kill -0 "$vm" 2>/dev/null && [ "$waited" -lt "$secs" ]; do
        if [ -n "$marker" ] && grep -aq "$marker" "$d/serial.log" 2>/dev/null; then
            hit=1
            info "$name: reached '$marker' after ${waited}s; stopping the VM"
            break
        fi
        sleep 2; waited=$((waited + 2))
    done
    if kill -0 "$vm" 2>/dev/null; then
        [ "$hit" = 1 ] || info "$name: still running after ${secs}s; stopping it"
        kill -TERM "$vm" 2>/dev/null
        sleep 3
        kill -KILL "$vm" 2>/dev/null
    fi
    wait "$vm" 2>/dev/null
    # QEMU CAN REFUSE TO START, and then every assertion below reads an empty
    # log and answers FAIL -- a paragraph about a machine that was never
    # switched on. Caught here, by name, once.
    if [ ! -s "$d/serial.log" ]; then
        bad "$name: THE SERIAL LOG IS EMPTY. This is a failure of the harness, not a verdict on the installer:"
        head -5 "$d/qemu.out" | sed 's/^/        /'
        return 1
    fi
    return 0
}

say "BOOT 1: the live medium as usb-storage on xHCI, blank NVMe attached"
boot_vm live-install 600 1
L1="$WORK/live-install/serial.log"
info "boot 1 serial log: $L1 ($(stat -c%s "$L1" 2>/dev/null || echo 0) bytes)"

# Did the medium come up at all, and did it switch root rather than run from RAM?
grep -aq 'INSTUSB-LIVE: the medium booted' "$L1" \
    && ok "boot 1: the live medium switched root and ran its rc" \
    || bad "boot 1: the live medium's rc never ran"
grep -aq 'handing off to an interactive shell' "$L1" \
    && bad "boot 1: the INITRAMFS rc ran -- the medium was running FROM RAM" \
    || ok "boot 1: the initramfs rc did not run, so this was not a RAM-only boot"

# The two disks the installer had to tell apart.
if grep -aq 'nvme0n1' "$L1"; then
    ok "boot 1: the kernel enumerated the NVMe target"
else
    bad "boot 1: no nvme0n1 in /proc/partitions -- the installer had no disk to install onto"
fi

# The tools, on the medium, seen by the guest.
grep -aq 'sgdisk' "$L1" \
    && ok "boot 1: the guest found the partitioning tools on its own medium" \
    || bad "boot 1: no sgdisk on the medium as the guest sees it"

# THE INSTALLER'S OWN VERDICT.
if grep -aq 'install complete' "$L1"; then
    ok "boot 1: the installer reported 'install complete'"
elif grep -aq 'cannot enter the Debian namespace\|no partitioning tools' "$L1"; then
    bad "boot 1: THE INSTALLER COULD NOT REACH sgdisk/mkfs -- this is the USB-stick defect"
    grep -a -A4 'no partitioning tools' "$L1" | head -8 | sed 's/^/        /'
else
    bad "boot 1: the installer neither completed nor named a reason"
    grep -a 'hlinstall\|===' "$L1" | tail -15 | sed 's/^/        /'
fi
grep -aq 'INSTUSB-LIVE-DONE' "$L1" \
    && ok "boot 1: the medium's rc ran to the end" \
    || info "boot 1: the rc did not reach its last line (the installer may have hung)"

# =========================================================================
# 2. WHAT THE INSTALLER ACTUALLY WROTE, READ BY THE HOST.
# =========================================================================
# From outside the guest, with it powered off, because "the installer said it
# worked" is exactly the claim under test.
say "reading the target disk from the host"
if sfdisk -J "$NVME" >"$WORK/target-table.json" 2>/dev/null; then
    ok "the target now has a partition table (it was zeroes)"
    NPARTS="$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["partitiontable"]["partitions"]))' "$WORK/target-table.json" 2>/dev/null || echo 0)"
    [ "${NPARTS:-0}" -ge 2 ] \
        && ok "the target has $NPARTS partitions (ESP + root)" \
        || bad "the target has $NPARTS partitions"
    TGT_ROOT_GUID="$(sgdisk -i 2 "$NVME" 2>/dev/null | awk -F': ' '/Partition unique GUID/{print tolower($2)}')"
    info "the target's root partition GUID is $TGT_ROOT_GUID"
    # THE WART, ASSERTED RATHER THAN DISCOVERED. user/hlinstall.ad gives the
    # target the GUID the copied UKI already names, so the installed disk and
    # the medium carry the SAME one. That is why boot 2 detaches the USB
    # instead of relying on a tie-break, and it is a real hazard on his laptop
    # if he leaves the stick in.
    if [ -n "$TGT_ROOT_GUID" ] && [ "$TGT_ROOT_GUID" = "$MEDIUM_PARTUUID" ]; then
        info "the target's root GUID EQUALS the medium's ($TGT_ROOT_GUID) -- by design, and the reason a stick left plugged in is ambiguous"
    fi
else
    bad "THE TARGET HAS NO PARTITION TABLE -- the installer wrote nothing"
    NPARTS=0
fi

if [ "${NPARTS:-0}" -ge 2 ]; then
    TGT_ESP_OFF="$(part_geom "$NVME" 1)"; TGT_ESP_OFF="${TGT_ESP_OFF% *}"

    # THE ESP, and the file the firmware will actually run. mtools reads a FAT
    # at a byte offset with no mount at all.
    if mdir -i "$NVME@@$TGT_ESP_OFF" ::/EFI/BOOT >"$WORK/target-esp.txt" 2>&1 \
       && grep -qi 'BOOTX64' "$WORK/target-esp.txt"; then
        ok "the target's ESP carries /EFI/BOOT/BOOTX64.EFI (the removable-media path firmware runs with no NVRAM entry)"
    else
        bad "the target's ESP has no /EFI/BOOT/BOOTX64.EFI -- the disk cannot boot"
        head -5 "$WORK/target-esp.txt" | sed 's/^/        /'
    fi

    # AND THE SIDE FILE WITHOUT WHICH THIS MACHINE COULD NEVER CHANGE WHAT IT
    # BOOTS. The hole named at the top of this file -- the UKI carries its own
    # copies of the boot modules and no package updates it -- is closed by
    # user/bootsync.ad, which writes the root's current bytes into a
    # reservation inside that PE. It can only find the reservation if it knows
    # where the SHIPPED archive ends, and that length is in /boot/UKI.MAP.
    # user/hlinstall.ad copies it onto the target beside BOOTX64.EFI, and a
    # medium that did not carry one installs a machine that boots forever on
    # the drivers it was installed with. This is the only place that copy is
    # exercised.
    if mcopy -n -o -i "$NVME@@$TGT_ESP_OFF" ::/UKI.MAP "$WORK/target-uki.map" 2>/dev/null \
       && [ -s "$WORK/target-uki.map" ]; then
        TGT_MAP_BASE="$(head -1 "$WORK/target-uki.map" | tr -d '\r')"
        TGT_MAP_N="$(grep -c '^/' "$WORK/target-uki.map")"
        ok "the installer copied /boot/UKI.MAP onto the target's ESP (base $TGT_MAP_BASE, $TGT_MAP_N boot modules)"
    else
        bad "the target's ESP has no UKI.MAP -- this machine's boot modules can never be refreshed by an update"
        TGT_MAP_BASE=""
    fi
    # The reservation itself, read out of the copied PE rather than assumed
    # from the build log: this is the file the FIRMWARE will run.
    if mcopy -n -o -i "$NVME@@$TGT_ESP_OFF" ::/EFI/BOOT/BOOTX64.EFI "$WORK/target-uki.efi" 2>/dev/null; then
        read -r TGT_VS0 TGT_RAW0 TGT_PTR0 <<<"$(uki_initrd_geom "$WORK/target-uki.efi")"
        if [ -n "${TGT_VS0:-}" ] && [ "$((TGT_RAW0 - TGT_VS0))" -gt 0 ]; then
            ok "the installed boot image has a $((TGT_RAW0 - TGT_VS0))-byte reservation in .initrd for bootsync to write into"
        else
            bad "the installed boot image has NO reservation in .initrd -- bootsync will refuse on this machine"
        fi
        [ -n "${TGT_MAP_BASE:-}" ] && [ "$TGT_MAP_BASE" = "${TGT_VS0:-}" ] \
            && ok "UKI.MAP's base matches the copied PE's .initrd VirtualSize ($TGT_VS0) -- the map and the image are the same build" \
            || bad "UKI.MAP says base=${TGT_MAP_BASE:-none} and the copied PE says ${TGT_VS0:-none}"
    fi

    # THE ROOT, AND THE ONE FILE THAT TELLS AN INSTALLED SYSTEM FROM THE LIVE
    # MEDIUM. See the header: the `(installed)` log line does NOT.
    if carve "$NVME" 2 && debugfs -R "ls /" "$PART" >/dev/null 2>&1; then
        ok "the target's root partition carries a readable ext4 filesystem"
        fs_has "$PART" /bin/hamsh \
            && ok "the target root carries the userland (/bin/hamsh)" \
            || bad "the target root has no /bin/hamsh -- the copy did not happen"
        fs_cat "$PART" /etc/rc.boot >"$WORK/target-rc.boot"
        if [ -s "$WORK/target-rc.boot" ]; then
            TGT_RCBOOT_MD5="$(md5sum "$WORK/target-rc.boot" | cut -d' ' -f1)"
            if grep -q "source '/etc/rc.boot.installed'" "$WORK/target-rc.boot" \
               && [ "$TGT_RCBOOT_MD5" != "$LIVE_RCBOOT_MD5" ]; then
                ok "the target's /etc/rc.boot is the installer's INDIRECTION, not the medium's copy (md5 $TGT_RCBOOT_MD5 vs the medium's $LIVE_RCBOOT_MD5) -- this is the live-vs-installed discriminator"
            else
                bad "the target's /etc/rc.boot is not the installer-written indirection (md5 $TGT_RCBOOT_MD5, medium $LIVE_RCBOOT_MD5)"
            fi
        else
            bad "the target root has no /etc/rc.boot"
        fi
    else
        bad "the target's root partition has no readable filesystem -- mkfs.ext4 did not run or did not finish"
    fi
fi

# =========================================================================
# 3. PULL THE USB OUT AND BOOT THE MACHINE'S OWN DISK.
# =========================================================================
# The USB device is not on the command line at all, so there is no tie-break to
# get wrong and no way for a pass here to be the medium booting again.
# AND ONLY IF THERE IS SOMETHING TO BOOT. With no partition table the firmware
# has nothing to run, so this boot sits in the UEFI shell until its timeout --
# ten minutes per run, three times over, to re-measure a disk the host has
# already read as empty. Skipping is not softening the verdict: the install
# has already been marked FAIL above, by name.
if [ "${NPARTS:-0}" -lt 2 ]; then
    info "skipping boots 2-4: the installer wrote no partition table, so there is nothing to boot"
    cleanup_mounts
    echo "instusb: $pass passed, $fail failed"
    exit 1
fi

say "BOOT 2: NVMe alone, the USB device DETACHED -- and the update runs on it"
# The marker is phase 1's LAST line, so the VM is stopped once the update has
# finished rather than after the desktop has idled for ten minutes.
boot_vm installed-1 900 0
L2="$WORK/installed-1/serial.log"

grep -aq 'rc.boot: hamnix-linux (installed)' "$L2" \
    && ok "boot 2: an installed-shape rc ran (root switch happened, not a RAM boot)" \
    || bad "boot 2: no installed rc line -- see $L2"
grep -aq 'handing off to an interactive shell' "$L2" \
    && bad "boot 2: the INITRAMFS rc ran -- the installed root was never mounted" \
    || ok "boot 2: the initramfs rc did not run"
grep -aqE 'is /dev/nvme0n1p2' "$L2" \
    && ok "boot 2: the kernel resolved root=PARTUUID to /dev/nvme0n1p2 with no USB attached" \
    || bad "boot 2: the root was not resolved to the NVMe"
grep -aq 'INSTUSB-P1: first boot of the installed machine' "$L2" \
    && ok "boot 2: the installed machine ran the phase-1 hook the INSTALLER carried onto it" \
    || bad "boot 2: the phase hook never ran -- the installer did not copy it, or hamsh could not source it"

# =========================================================================
# 4. THE UPDATE, OVER THE REAL NETWORK, ON THE DISK THE INSTALLER WROTE.
# =========================================================================
# hpm's OWN success lines, not a loose word match. `hpm: refreshed index from`
# is printed only after the index authenticated against the SHIPPED trust root,
# and `hpm: update done (upgraded=N` only after the transaction closed.
if grep -aq 'hpm: refreshed index from' "$L2"; then
    ok "boot 2: $(grep -a 'hpm: refreshed index from' "$L2" | head -1 | tr -d '\r')"
else
    bad "boot 2: hpm never printed 'refreshed index from' -- no authenticated index"
    grep -a 'hpm' "$L2" | tail -10 | sed 's/^/        /'
fi
if [ "$NO_DB" = 1 ]; then
    # THE THIRD REQUIREMENT, MEASURED: when hpm cannot know what is on the
    # machine it must say so and REFUSE, not treat the machine as empty. That
    # last is exactly what it did at 7213661a -- "no packages installed;
    # nothing to update", exit 0, on a machine with a full userland on it.
    if grep -aq 'this machine.s package state is UNKNOWN' "$L2"; then
        ok "boot 2 (negative control): with no database hpm REFUSED and named the file -- $(grep -a 'no package database at' "$L2" | head -1 | tr -d '\r')"
    elif grep -aq 'no packages installed; nothing to update' "$L2"; then
        bad "boot 2 (negative control): hpm treated a machine with no database as a machine with nothing installed -- this is 7213661a's bug and it is still here"
    else
        bad "boot 2 (negative control): hpm said neither of the two things it could say"
        grep -a 'hpm' "$L2" | tail -8 | sed 's/^/        /'
    fi
    grep -aq 'hpm: update done' "$L2" \
        && bad "boot 2 (negative control): hpm reported a completed update with no package database" \
        || ok "boot 2 (negative control): hpm did NOT report a completed update"
elif grep -aq 'hpm: update done' "$L2"; then
    ok "boot 2: $(grep -a 'hpm: update done' "$L2" | head -1 | tr -d '\r')"
    UPG="$(grep -a 'hpm: update done' "$L2" | head -1 | sed 's/.*upgraded=\([0-9]*\).*/\1/')"
    if [ "${UPG:-0}" -ge 5 ]; then
        ok "boot 2: the update actually upgraded $UPG packages -- it is not a no-op that exits 0"
    else
        bad "boot 2: the update reported upgraded=${UPG:-?}; the medium recorded FIVE packages a version behind (three inert ones and the two kernel-module packages), so a working update has five to do"
    fi
    grep -aq 'hpm: upgrading hamnix-man 1.0.22 ->' "$L2" \
        && ok "boot 2: hpm named the transition it performed ($(grep -ao 'hpm: upgrading hamnix-man 1.0.22 -> [0-9.]*' "$L2" | head -1))" \
        || bad "boot 2: hpm never printed the hamnix-man upgrade line"
    # THE TWO THIS COMMIT EXISTS FOR. Before the image staged
    # modules.dep.<group> these were not in the database at all, so hpm had
    # nothing to name here however healthy the rest of the update looked.
    for P in hamnix-drivers-base hamnix-drivers-hw; do
        grep -aq "hpm: upgrading $P 1.0.22 ->" "$L2" \
            && ok "boot 2: hpm upgraded $P ($(grep -ao "hpm: upgrading $P 1.0.22 -> [0-9.]*" "$L2" | head -1 | sed 's/hpm: upgrading //'))" \
            || bad "boot 2: hpm never upgraded $P -- the boot kernel modules are still unreachable by \`hpm update\`"
    done
    # AND THE HOOK RAN. hamnix-drivers-*'s install.hamsh is what merges the
    # shipped table into the machine's modules.dep; a package whose files land
    # and whose hook did not run leaves modprobe unable to name what it just
    # installed.
    grep -aq 'modules.dep' "$L2" \
        && ok "boot 2: a driver package's install hook spoke about modules.dep -- $(grep -a 'modules.dep' "$L2" | head -1 | tr -d '\r' | cut -c1-90)" \
        || bad "boot 2: neither driver package's install hook said anything about modules.dep"
    # AND THE HALF THAT IS NOT A PACKAGE AT ALL. Everything above moves files on
    # the ext4 root. user/linuxinit.ad loads /etc/modules BEFORE the root switch,
    # so none of it reaches a boot -- the hole this file's own header names, two
    # sections up, when it says the mangled modules cannot stop the machine
    # booting. user/hpm.ad:_sync_boot_image runs bootsync once at the end of the
    # transaction; it is the only thing on this machine that can change what it
    # boots with.
    grep -aq 'hpm: refreshing the boot image' "$L2" \
        && ok "boot 2: hpm ran the boot-image refresh after the transaction" \
        || bad "boot 2: hpm never refreshed the boot image -- the upgraded drivers reach modprobe and NOT the next boot"
    if grep -aq 'bootsync: committed' "$L2"; then
        ok "boot 2: bootsync committed -- $(grep -a 'bootsync: .* boot modules,' "$L2" | head -1 | tr -d '\r')"
    elif grep -aq 'bootsync:' "$L2"; then
        bad "boot 2: bootsync did not commit: $(grep -a 'bootsync:' "$L2" | head -2 | tr -d '\r' | tr '\n' ' ')"
    else
        bad "boot 2: bootsync said nothing at all"
    fi
    grep -aq 'bootsync: .* modules verified in the boot image' "$L2" \
        && ok "boot 2: it read the overlay back against the files on the root before moving the length field" \
        || bad "boot 2: bootsync committed without a read-back"
    # THE MEDIUM, NOT THE LOG. The boot image is pulled off the target's ESP
    # with the guest dead and its .initrd re-read: the field must have moved,
    # and it must still be inside the reservation.
    if [ -n "${TGT_VS0:-}" ] \
       && mcopy -n -o -i "$NVME@@$TGT_ESP_OFF" ::/EFI/BOOT/BOOTX64.EFI "$WORK/target-uki-after.efi" 2>/dev/null; then
        read -r TGT_VS1 TGT_RAW1 _ <<<"$(uki_initrd_geom "$WORK/target-uki-after.efi")"
        [ "${TGT_VS1:-0}" -gt "$TGT_VS0" ] \
            && ok "the boot image ON THE TARGET grew by $((TGT_VS1 - TGT_VS0)) bytes of overlay (VirtualSize $TGT_VS0 -> $TGT_VS1)" \
            || bad "the boot image on the target is unchanged: VirtualSize is still ${TGT_VS1:-?}"
        [ "${TGT_RAW1:-0}" = "$TGT_RAW0" ] \
            && ok "and SizeOfRawData is untouched -- the file's length never changed, so no FAT cluster was allocated" \
            || bad "SizeOfRawData moved: $TGT_RAW0 -> ${TGT_RAW1:-?}"
    fi
elif grep -aq 'no packages installed; nothing to update' "$L2"; then
    # SAY WHICH KIND OF NOTHING. The index authenticated and 126 packages came
    # down, so the network, the TLS and the shipped trust root are all fine --
    # and `hpm update` STILL did nothing, because the machine has no record of
    # having anything installed. scripts/hamlinux_image.sh creates
    # /var/lib/hpm as an EMPTY DIRECTORY and nothing ever writes
    # installed.json into it, so a freshly installed machine's package
    # database is empty and `hpm update` is a no-op FOREVER. That is the
    # owner's permanent rule (work published here must be updatable ON the
    # machine) failing on the only machine that matters.
    bad "boot 2: THE UPDATE IS A NO-OP -- the index authenticated (126 packages) but the installed machine has an EMPTY PACKAGE DATABASE, so there is nothing for hpm to upgrade. /var/lib/hpm/installed.json is never written by the image build."
else
    bad "boot 2: hpm never printed 'update done'"
    grep -a 'hpm' "$L2" | tail -8 | sed 's/^/        /'
fi
grep -aq 'rc.boot: up' "$L2" \
    && ok "boot 2: the installed system reached 'rc.boot: up' (the desktop rc ran after the update)" \
    || info "boot 2: stopped at the phase marker before 'rc.boot: up'"

# =========================================================================
# 5. REBOOT, AND SEE WHETHER THE UPDATE IS STILL THERE.
# =========================================================================
# Nothing is written to this disk between the two boots. Phase 1 left a marker
# ON THE INSTALLED FILESYSTEM, so if the root were not persistent -- the whole
# failure mode 146649bd found, a machine running from RAM and discarding
# everything at power-off -- phase 2 could not run at all.
say "BOOT 3: the same disk again, nothing changed by the host"
# NO poweroff in phase 2 and a marker instead: this is the LAST boot, nothing
# has to survive it, so it is allowed to run all the way through the desktop rc
# and is stopped on `rc.boot: up`. That makes this the one boot in the gate that
# proves the INSTALLED machine completes a full desktop boot after taking an
# update.
boot_vm installed-2 900 0 "rc.boot: up"
L3="$WORK/installed-2/serial.log"

grep -aq 'INSTUSB-P2: this machine has been rebooted since the update' "$L3" \
    && ok "boot 3: phase 2 ran, so phase 1's marker SURVIVED THE POWER CYCLE on the installed root" \
    || bad "boot 3: phase 2 did not run -- the marker did not persist"
grep -aq 'INSTUSB-P1: first boot' "$L3" \
    && bad "boot 3: phase 1 ran AGAIN -- the installed root is not persistent" \
    || ok "boot 3: phase 1 did not run again"
grep -aq 'rc.boot: hamnix-linux (installed)' "$L3" \
    && ok "boot 3: the installed system booted again" \
    || bad "boot 3: the machine did not come back after the update"
grep -aq 'rc.boot: up' "$L3" \
    && ok "boot 3: it went all the way through the desktop rc to 'rc.boot: up' AFTER the update" \
    || bad "boot 3: the updated machine did not finish its boot"
# THE BOOT THAT RAN THE REWRITTEN IMAGE. A boot image whose archive is damaged
# does not necessarily fail to boot -- measured: a bootsync that wrote 16 MB
# into the middle of the live archive produced a machine that came up, loaded
# every module and reached the desktop, with this line at t=1.17s in a log
# nobody was reading. It is the difference between a machine that works and one
# that is one unlucky file away from not working.
grep -aq 'Initramfs unpacking failed' "$L3" \
    && bad "boot 3: THE KERNEL COULD NOT UNPACK THE WHOLE INITRAMFS -- the rewritten boot image is damaged, and this boot only LOOKED fine" \
    || ok "boot 3: no 'Initramfs unpacking failed' -- the rewritten boot image unpacked completely"
B2_MODS="$(grep -ao 'loaded [0-9]* kernel modules' "$L2" | head -1)"
B3_MODS="$(grep -ao 'loaded [0-9]* kernel modules' "$L3" | head -1)"
[ -n "$B3_MODS" ] && [ "$B2_MODS" = "$B3_MODS" ] \
    && ok "boot 3: the same boot module count as before the refresh ($B3_MODS) -- nothing was lost from the boot set" \
    || bad "boot 3: the boot module count changed across the refresh: '$B2_MODS' -> '$B3_MODS'"

# THE COMPARISON THAT MATTERS: the same package list, after a power cycle. A
# version that only ever existed in boot 2's RAM cannot appear here.
AFTER_UPD="$(grep -a -A40 'INSTUSB-P1: hpm list after' "$L2" 2>/dev/null | grep -aE '^[a-z0-9-]+ +[0-9]+\.[0-9]+\.[0-9]+' | sort)"
REBOOTED="$(grep -a -A40 'INSTUSB-P2: this machine' "$L3" 2>/dev/null | grep -aE '^[a-z0-9-]+ +[0-9]+\.[0-9]+\.[0-9]+' | sort)"
if [ "$NO_DB" = 1 ]; then
    # THE CONTROL'S EXPECTATION IS THE OPPOSITE ONE. With no database there is
    # no package list to compare, and demanding one here would score the
    # control's correct behaviour as a failure. What IS asserted is that the
    # machine says the same nothing on both sides of the reboot.
    if [ -z "$REBOOTED" ] && [ -z "$AFTER_UPD" ]; then
        ok "boot 3 (negative control): still no package list after the reboot, on both sides -- the machine's state did not silently acquire one"
    else
        bad "boot 3 (negative control): a package list appeared on a machine with no database"
    fi
elif [ -n "$REBOOTED" ] && [ "$AFTER_UPD" = "$REBOOTED" ]; then
    ok "boot 3: the package list is byte-identical to the one the update left -- THE UPDATE IS ON THE DISK"
    printf '%s\n' "$REBOOTED" | head -6 | sed 's/^/        /'
elif [ -z "$REBOOTED" ]; then
    bad "boot 3: could not read a package list after the reboot"
else
    bad "boot 3: the package list changed across the reboot"
    diff <(printf '%s\n' "$AFTER_UPD") <(printf '%s\n' "$REBOOTED") | head -10 | sed 's/^/        /'
fi

# =========================================================================
# 6. WHAT THE UPDATE LEFT ON THE DISK, READ BY THE HOST AFTER THE POWER CYCLE.
# =========================================================================
# `hpm update` exiting 0 is not evidence that anything moved. This reads the
# INSTALLED NVMe -- after two power cycles, with the guest off and nothing
# writing -- and asks whether the bytes changed. Anything that existed only in
# boot 2's page cache cannot be here.
if [ "$NO_DB" = 1 ]; then
    say "negative control: nothing should have changed on the disk"
    if carve "$NVME" 2; then
        fs_cat "$PART" "/$MANGLED_MAN" >"$WORK/after-man.txt" 2>/dev/null || true
        grep -q "$MANGLE_MARK" "$WORK/after-man.txt" 2>/dev/null \
            && ok "negative control: the stale file is STILL stale, because nothing upgraded it" \
            || bad "negative control: the stale marker is gone, so something upgraded a machine hpm said it knew nothing about"
        # The same question of the drivers. This is the half that says the
        # green run's driver assertions are about the UPDATE and not about
        # something the install or the image would have done anyway.
        for f in "$MANGLED_KO_BASE" "$MANGLED_KO_HW" "$MANGLED_DEP_HW"; do
            fs_cat "$PART" "/$f" >"$WORK/negctl-drv.bin" 2>/dev/null || true
            grep -q "$MANGLE_MARK" "$WORK/negctl-drv.bin" 2>/dev/null \
                && ok "negative control: /$f still holds the marker -- with no database the kernel modules are NOT upgraded" \
                || bad "negative control: /$f no longer holds the marker, so something replaced a driver on a machine hpm knew nothing about"
        done
    fi
else
    say "WHAT THE UPDATE PUT ON THE DISK"
    if carve "$NVME" 2; then
        # 6a. THE CONTENT CHANGED. The medium carried a file whose bytes were a
        # marker string and whose owning package was recorded one version back.
        # If it still says the marker, the update touched nothing on the disk
        # however cheerful its exit status was.
        fs_cat "$PART" "/$MANGLED_MAN" >"$WORK/after-man.txt" 2>/dev/null || true
        if [ ! -s "$WORK/after-man.txt" ]; then
            bad "boot 3: /$MANGLED_MAN is missing or empty on the installed disk -- the upgrade removed it and did not put it back"
        elif grep -q "$MANGLE_MARK" "$WORK/after-man.txt"; then
            bad "boot 3: /$MANGLED_MAN still holds the stale marker -- \`hpm update\` exited 0 and changed nothing on the disk"
        else
            ok "boot 3: /$MANGLED_MAN NO LONGER holds the stale marker and is $(stat -c%s "$WORK/after-man.txt") bytes of real content -- the update rewrote a file on the installed disk and it SURVIVED THE POWER CYCLE"
            info "boot 3: it now begins: $(head -1 "$WORK/after-man.txt" | tr -d '\r' | cut -c1-70)"
            if cmp -s "$WORK/after-man.txt" etc/man/cat.1.md; then
                ok "boot 3: and it is byte-identical to this tree's etc/man/cat.1.md -- the channel delivered the file the source says it should"
            else
                info "boot 3: it differs from this tree's etc/man/cat.1.md; 255.one's 1.0.23 was built from an older tree, so this is expected unless that file changed since the release"
            fi
        fi

        # 6b. THE DATABASE MOVED WITH IT. A machine whose files changed but
        # whose record did not would upgrade the same package again forever.
        fs_cat "$PART" /var/lib/hpm/installed.json >"$WORK/after-db.json" 2>/dev/null || true
        if [ -s "$WORK/after-db.json" ]; then
            AFTER_MAN_VER="$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
print(next((p["version"] for p in d["packages"] if p["name"]=="hamnix-man"), "ABSENT"))' "$WORK/after-db.json" 2>/dev/null || echo UNPARSEABLE)"
            # THE VERSION IS READ OUT OF THE CHANNEL, NOT WRITTEN HERE. It was
            # the literal "1.0.23" and went red the day 1.0.24 was published --
            # a gate that has to be edited on every release is a gate that gets
            # edited without being read.
            CHAN_MAN_VER="$(python3 -c '
import json,sys
i=json.load(open(sys.argv[1]))
print(next((e["version"] for e in i["packages"] if e["name"]=="hamnix-man"), "ABSENT"))' \
                "$CHAN/index.json" 2>/dev/null || echo UNKNOWN)"
            if [ "$AFTER_MAN_VER" = "$CHAN_MAN_VER" ] && [ "$AFTER_MAN_VER" != "1.0.22" ]; then
                ok "boot 3: the package database on the disk now records hamnix-man at $AFTER_MAN_VER, which is what the channel serves (it shipped recording 1.0.22)"
            else
                bad "boot 3: the database on the disk records hamnix-man at $AFTER_MAN_VER; the channel serves $CHAN_MAN_VER"
            fi
        else
            bad "boot 3: no readable /var/lib/hpm/installed.json on the installed disk after the update"
        fi

        # 6c. AND NOTHING ELSE WENT. The whole reason the lists are taken from
        # the tarballs is that an upgrade UNLINKS them, so the files a
        # NON-upgraded package owns, and the file no package owns, are what a
        # wrong list would have destroyed.
        fs_has "$PART" /bin/cat \
            && ok "boot 3: /bin/cat is still there -- upgrading three packages did not delete a file a fourth one owns" \
            || bad "boot 3: /bin/cat IS GONE after the update"
        fs_cat "$PART" /etc/rc.boot >"$WORK/after-rc.boot" 2>/dev/null || true
        if [ -s "$WORK/after-rc.boot" ] && grep -q "source '/etc/rc.boot.installed'" "$WORK/after-rc.boot"; then
            ok "boot 3: /etc/rc.boot is still the installer's indirection -- the update did not take the machine's own boot script"
        else
            bad "boot 3: /etc/rc.boot is gone or no longer the indirection after the update -- this is the brick shape"
        fi
        fs_has "$PART" /bin/hamsh \
            && ok "boot 3: /bin/hamsh survived the update" \
            || bad "boot 3: /bin/hamsh IS GONE after the update"

        # =================================================================
        # 6d. THE KERNEL MODULES, WHICH IS WHAT THIS WHOLE THING IS FOR.
        # =================================================================
        # Three files were the marker string on the medium: one .ko owned by
        # hamnix-drivers-base, one owned by hamnix-drivers-hw, and hw's
        # dependency table. Read off the installed NVMe, after two power
        # cycles, with the guest off.
        for f in "$MANGLED_KO_BASE" "$MANGLED_KO_HW"; do
            fs_cat "$PART" "/$f" >"$WORK/after-drv.bin" 2>/dev/null || true
            if [ ! -s "$WORK/after-drv.bin" ]; then
                bad "boot 3: /$f is missing or empty on the installed disk -- the upgrade removed a kernel module and did not put it back"
            elif grep -q "$MANGLE_MARK" "$WORK/after-drv.bin"; then
                bad "boot 3: /$f STILL holds the stale marker -- \`hpm update\` did not replace the kernel module"
            elif [ "$(head -c4 "$WORK/after-drv.bin" | od -An -c | tr -d ' \n')" = '177ELF' ]; then
                ok "boot 3: /$f is a real ELF kernel module again ($(stat -c%s "$WORK/after-drv.bin") bytes) -- the update REPLACED it and it survived the power cycle"
            else
                bad "boot 3: /$f is neither the marker nor an ELF -- $(head -c40 "$WORK/after-drv.bin" | tr -d '\0' | head -1)"
            fi
        done
        # AND IT IS THE CHANNEL'S BYTES, not merely different bytes. Compared
        # against the tarball this tree built, which is byte-identical member
        # for member to the one 255.one serves.
        python3 - "$CHAN" "$WORK/after-drv-hw.expect" "$MANGLED_KO_HW" <<'PYEOF' 2>/dev/null || true
import json, os, sys, tarfile
chan, out, rel = sys.argv[1], sys.argv[2], sys.argv[3]
idx = {e["name"]: e["version"]
       for e in json.load(open(os.path.join(chan, "index.json")))["packages"]}
v = idx["hamnix-drivers-hw"]
tf = tarfile.open(os.path.join(chan, "packages",
                               "hamnix-drivers-hw-%s.tar.gz" % v), "r:gz")
want = "hamnix-drivers-hw-%s/files/%s" % (v, rel)
for ti in tf:
    if ti.name == want:
        open(out, "wb").write(tf.extractfile(ti).read())
        break
PYEOF
        fs_cat "$PART" "/$MANGLED_KO_HW" >"$WORK/after-drv-hw.bin" 2>/dev/null || true
        if [ -s "$WORK/after-drv-hw.expect" ] && cmp -s "$WORK/after-drv-hw.bin" "$WORK/after-drv-hw.expect"; then
            ok "boot 3: the replaced $(basename "$MANGLED_KO_HW") is BYTE-IDENTICAL to the one in hamnix-drivers-hw's tarball -- the channel delivered the module, not just some bytes"
        else
            bad "boot 3: the replaced $(basename "$MANGLED_KO_HW") does not match hamnix-drivers-hw's tarball copy"
        fi
        # THE TABLE. Text, so this one is readable and the guest reads it too.
        fs_cat "$PART" "/$MANGLED_DEP_HW" >"$WORK/after-dep-hw.txt" 2>/dev/null || true
        if [ ! -s "$WORK/after-dep-hw.txt" ]; then
            bad "boot 3: /$MANGLED_DEP_HW is missing after the update"
        elif grep -q "$MANGLE_MARK" "$WORK/after-dep-hw.txt"; then
            bad "boot 3: /$MANGLED_DEP_HW still holds the stale marker"
        elif grep -q '\.ko:' "$WORK/after-dep-hw.txt"; then
            ok "boot 3: /$MANGLED_DEP_HW is $(grep -c . "$WORK/after-dep-hw.txt") real dependency lines again"
        else
            bad "boot 3: /$MANGLED_DEP_HW is neither the marker nor a dependency table"
        fi
        # THE MACHINE'S OWN modules.dep STILL RESOLVES, AND GREW RATHER THAN
        # BEING REPLACED. The install hook PREPENDS the shipped table; if it
        # had overwritten instead, every line a driver package appended -- the
        # only thing that lets `modprobe i915` name a file -- would be gone.
        fs_cat "$PART" "/$MACHINE_DEP" >"$WORK/after-machine-dep.txt" 2>/dev/null || true
        if [ ! -s "$WORK/after-machine-dep.txt" ]; then
            bad "boot 3: the machine's /$MACHINE_DEP is GONE after the update -- modprobe can no longer resolve any name"
        else
            DEPN="$(grep -c . "$WORK/after-machine-dep.txt")"
            DEPB="$(stat -c%s "$WORK/after-machine-dep.txt")"
            if grep -q 'ext4\.ko:' "$WORK/after-machine-dep.txt" \
               && grep -q 'nvme\.ko:' "$WORK/after-machine-dep.txt"; then
                ok "boot 3: the machine's modules.dep survived the update and still names ext4.ko and nvme.ko ($DEPN lines, $DEPB bytes)"
            else
                bad "boot 3: the machine's modules.dep no longer names ext4.ko and nvme.ko -- the root and disk drivers became unresolvable"
            fi
            # user/modprobe.ad:DEP_CAP is 262144 and it REFUSES loudly past it.
            # The hook prepends unconditionally, so the table grows by the two
            # shipped tables on every update; this is the number that says how
            # much headroom is left.
            if [ "$DEPB" -lt 262144 ]; then
                info "boot 3: modules.dep is $DEPB bytes against modprobe's 262144-byte DEP_CAP; the hooks prepend unconditionally, so it grows by the two shipped tables per update"
            else
                bad "boot 3: modules.dep is $DEPB bytes, at or over modprobe's DEP_CAP -- modprobe reads a truncated table"
            fi
        fi

        # 6e. NOTHING THE DATABASE CLAIMS WENT MISSING. The upgrade unlinked
        # every path the five recorded-old versions owned and laid the new ones
        # down; this stats EVERY path the post-update database records, on the
        # disk, in one debugfs run. It is the strongest available statement of
        # "it deleted nothing it should not" -- 280-odd files, not a spot check.
        if [ -s "$WORK/after-db.json" ]; then
            python3 -c '
import json,sys
db=json.load(open(sys.argv[1]))
for p in db["packages"]:
    for f in p["files"]:
        print("stat /"+f)' "$WORK/after-db.json" >"$WORK/afterstat.cmds" 2>/dev/null || true
            # AND EVERY PATH THE MEDIUM'S DATABASE RECORDED BEFORE THE UPDATE,
            # because the shape being guarded against is a file that the OLD
            # version owned, the remove unlinked, and the new version does not
            # carry -- which the post-update database would not mention at all.
            python3 -c '
import json,sys
db=json.load(open(sys.argv[1]))
for p in db["packages"]:
    for f in p["files"]:
        print("stat /"+f)' "$WORK/medium-installed.json" >>"$WORK/afterstat.cmds" 2>/dev/null || true
            sort -u "$WORK/afterstat.cmds" -o "$WORK/afterstat.cmds"
            debugfs -f "$WORK/afterstat.cmds" "$PART" >"$WORK/afterstat.out" 2>&1
            AS_WANT="$(wc -l <"$WORK/afterstat.cmds")"
            AS_GOT="$(grep -c '^Inode:' "$WORK/afterstat.out" || true)"
            if [ "$AS_WANT" -gt 0 ] && [ "$AS_GOT" = "$AS_WANT" ]; then
                ok "boot 3: all $AS_WANT paths recorded before OR after the update are still on the disk -- the upgrade of five packages deleted nothing it should not"
            else
                bad "boot 3: only $AS_GOT of $AS_WANT recorded paths survive on the disk -- the upgrade DELETED files"
                grep -B1 'File not found' "$WORK/afterstat.out" | head -10 | sed 's/^/        /'
            fi
            AFTER_DRV_VER="$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
print(" ".join("%s=%s" % (p["name"], p["version"]) for p in d["packages"]
               if p["name"] in ("hamnix-drivers-base","hamnix-drivers-hw")) or "ABSENT")' \
                "$WORK/after-db.json" 2>/dev/null || echo UNPARSEABLE)"
            case "$AFTER_DRV_VER" in
                *hamnix-drivers-base=1.0.2*hamnix-drivers-hw=1.0.2*)
                    ok "boot 3: the database on the disk now records $AFTER_DRV_VER (it shipped recording both at 1.0.22)" ;;
                *) bad "boot 3: the database records the driver packages as: $AFTER_DRV_VER" ;;
            esac
        fi
    else
        bad "boot 3: cannot carve the installed root to see what the update did"
    fi
    # THE GUEST SAW THE SAME THING, after the reboot, with its own eyes.
    if grep -a -A6 'INSTUSB-P2: the file the update rewrote' "$L3" | grep -q "$MANGLE_MARK"; then
        bad "boot 3: the REBOOTED machine still reads the stale marker out of $MANGLED_MAN"
    elif grep -aq 'INSTUSB-P2: the file the update rewrote' "$L3"; then
        ok "boot 3: the rebooted machine read $MANGLED_MAN back for itself and the stale marker is not in it"
    else
        info "boot 3: phase 2 did not reach the file read-back"
    fi
    # THE BEFORE AND THE AFTER, BOTH READ BY THE MACHINE, on opposite sides of
    # an update and a power cycle. Phase 1 cat'd the hw dependency table before
    # `hpm update` ran and got the marker; phase 2 cat'd the same path after the
    # reboot. Two reads by the same program on the same machine is the strongest
    # form of this the gate can take -- the host's debugfs reads above agree
    # with it, but they are a different instrument.
    B1="$(sed -n '/INSTUSB-P1: THE DRIVER TABLE BEFORE/,/INSTUSB-P1: BEFORE-END/p' "$L2" 2>/dev/null | tr -d '\r')"
    A1="$(sed -n '/INSTUSB-P2: THE DRIVER TABLE AFTER/,/INSTUSB-P2: AFTER-END/p' "$L3" 2>/dev/null | tr -d '\r')"
    if printf '%s' "$B1" | grep -q "$MANGLE_MARK"; then
        ok "boot 2: BEFORE the update the machine read the marker out of /$MANGLED_DEP_HW with its own cat"
        if printf '%s' "$A1" | grep -q "$MANGLE_MARK"; then
            bad "boot 3: AFTER the update and a power cycle the machine still reads the marker out of /$MANGLED_DEP_HW"
        elif printf '%s' "$A1" | grep -q '\.ko:'; then
            ok "boot 3: AFTER the update the same machine reads real dependency lines out of the same path -- $(printf '%s' "$A1" | grep -m1 '\.ko:' | cut -c1-70)"
        else
            bad "boot 3: the machine read neither the marker nor a dependency table back from /$MANGLED_DEP_HW"
        fi
    else
        bad "boot 2: phase 1 never read the marker out of /$MANGLED_DEP_HW, so there is no BEFORE to compare against"
    fi
fi

cleanup_mounts
echo "instusb: $pass passed, $fail failed"
[ "$fail" = 0 ]
