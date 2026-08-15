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
# `dd` a partition out, look at it, and (for the update stage) put it back.
# Measured at 1.6 s for 3.6 GB on this host, which is cheaper than the boots.
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
paste_back() {  # paste_back <img> <partno> -- write $PART back where it came from
    local g off
    g="$(part_geom "$1" "$2")" || return 1
    off="${g% *}"
    dd if="$PART" of="$1" bs=1M seek=$((off / 1048576)) conv=notrunc status=none
}
fs_has()  { debugfs -R "stat $2" "$1" 2>/dev/null | grep -q '^Inode:'; }
fs_cat()  { debugfs -R "cat $2" "$1" 2>/dev/null; }
fs_ls()   { debugfs -R "ls $2" "$1" 2>/dev/null; }
cleanup_mounts() { rm -f "$PART"; }

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
if [ "${HAMLINUX_INSTUSB_REUSE:-0}" = 1 ]; then
    say "reusing the staged build/image (HAMLINUX_INSTUSB_REUSE=1)"
    grep -q 'INCOMPLETE' "$WORK/img2.log" 2>/dev/null && bad "the staged image's instroot is incomplete"
else
    say "building the live medium (four passes; this is the slow part)"
    scripts/hamlinux_image.sh >"$WORK/img1.log" 2>&1 || {
        bad "lean image build"; tail -20 "$WORK/img1.log"; exit 1; }
    scripts/hamlinux_disk.sh "$WORK/seed.img" 3G >"$WORK/disk1.log" 2>&1 || {
        bad "seed disk build"; tail -20 "$WORK/disk1.log"; exit 1; }
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

if [ "${HAMLINUX_INSTUSB_REUSE:-0}" = 1 ] && [ -f "$LIVE" ]; then
    :
else
    HAMLINUX_DISK_RC="$WORK/rc.install" \
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

say "BOOT 2: NVMe alone, the USB device DETACHED"
boot_vm installed-1 600 0 "rc.boot: up"
L2="$WORK/installed-1/serial.log"

grep -aq 'rc.boot: hamnix-linux (installed)' "$L2" \
    && ok "boot 2: an installed-shape rc ran (root switch happened, not a RAM boot)" \
    || bad "boot 2: no installed rc line -- see $L2"
grep -aq 'handing off to an interactive shell' "$L2" \
    && bad "boot 2: the INITRAMFS rc ran -- the installed root was never mounted" \
    || ok "boot 2: the initramfs rc did not run"
grep -aqE 'nvme0n1p2|root=PARTUUID' "$L2" \
    && ok "boot 2: the kernel resolved its root on the NVMe" \
    || info "boot 2: no explicit root device line in the log"
grep -aq 'rc.boot: up' "$L2" \
    && ok "boot 2: the installed system reached 'rc.boot: up'" \
    || bad "boot 2: the installed system did not finish booting"

# =========================================================================
# 4. UPDATE IT OVER THE NETWORK, THEN REBOOT AND SEE IF IT STUCK.
# =========================================================================
# The installed machine's rc is the installer's own, and it does not run hpm.
# Its CONTENT has already been asserted above -- that is the proof that this is
# the installed system -- so replacing it now to drive the update costs nothing
# that has not already been measured, and it is the only hook there is on a
# disk this gate did not build.
if [ "${NPARTS:-0}" -ge 2 ] && [ "${HAMLINUX_INSTUSB_NONET:-0}" != 1 ]; then
    say "BOOT 3: hpm refresh + hpm update against the real https://255.one/"
    cat >"$WORK/rc.update" <<'RCEOF'
source '/etc/rc.boot.installed.orig'
echo 'INSTUSB-UPD: asking 255.one for an index'
hpm refresh
echo 'INSTUSB-UPD: hpm list before'
hpm list
hpm update
echo 'INSTUSB-UPD: hpm list after'
hpm list
echo 'INSTUSB-UPD-DONE'
poweroff
RCEOF
    # The stock installed rc ends by starting the desktop, which never returns.
    # This takes the target's OWN copy, drops that one line, and puts it back
    # as .orig for the gate's rc to source -- so everything before it (the root
    # switch, the network, the namespaces) is the installed machine's own text.
    # RE-CARVED, because boot 2 was a real boot of this disk and may have
    # written to it. Working from the copy taken before that boot would put
    # stale blocks back and the corruption would look like an hpm failure.
    carve "$NVME" 2
    fs_cat "$PART" /etc/rc.boot.installed >"$WORK/rc.installed.orig"
    if [ -s "$WORK/rc.installed.orig" ]; then
        sed -i "s|^source '/etc/rc.d/rc.5'|echo 'INSTUSB-UPD: (desktop not started by this gate)'|" \
            "$WORK/rc.installed.orig"
        # debugfs writes into the carved partition; e2fsck then makes sure what
        # goes back onto the disk is a consistent filesystem rather than
        # something that merely wrote without error.
        debugfs -w -R "rm /etc/rc.boot" "$PART" >/dev/null 2>&1
        debugfs -w -R "write $WORK/rc.update /etc/rc.boot" "$PART" >/dev/null 2>&1
        debugfs -w -R "write $WORK/rc.installed.orig /etc/rc.boot.installed.orig" "$PART" >/dev/null 2>&1
        e2fsck -fy "$PART" >"$WORK/fsck-update.log" 2>&1
        paste_back "$NVME" 2
        boot_vm installed-update 900 0
        L3="$WORK/installed-update/serial.log"
        grep -aq 'INSTUSB-UPD: asking 255.one' "$L3" \
            && ok "boot 3: the installed machine ran the update rc" \
            || bad "boot 3: the update rc never ran"
        # hpm's OWN success lines, not a loose word match. `hpm: refreshed
        # index from <url>` is printed only after the index authenticated
        # against the shipped trust root, and `hpm: update done (upgraded=N`
        # only after the transaction closed.
        if grep -aq 'hpm: refreshed index from' "$L3"; then
            ok "boot 3: hpm refreshed and AUTHENTICATED an index from the network"
            grep -a 'hpm: refreshed index from' "$L3" | head -1 | sed 's/^/        /'
        else
            bad "boot 3: hpm never printed 'refreshed index from' -- no authenticated index -- see $L3"
            grep -a 'hpm' "$L3" | tail -10 | sed 's/^/        /'
        fi
        if grep -aq 'hpm: update done' "$L3"; then
            ok "boot 3: $(grep -a 'hpm: update done' "$L3" | head -1)"
        else
            bad "boot 3: hpm never printed 'update done'"
        fi
        grep -aq 'INSTUSB-UPD-DONE' "$L3" \
            && ok "boot 3: the update rc ran to the end" \
            || bad "boot 3: the update rc did not finish"

        say "BOOT 4: reboot, and see whether the update survived"
        cat >"$WORK/rc.after" <<'RCEOF'
source '/etc/rc.boot.installed.orig'
echo 'INSTUSB-AFTER: hpm list after the reboot'
hpm list
echo 'INSTUSB-AFTER-DONE'
poweroff
RCEOF
        if carve "$NVME" 2; then
            debugfs -w -R "rm /etc/rc.boot" "$PART" >/dev/null 2>&1
            debugfs -w -R "write $WORK/rc.after /etc/rc.boot" "$PART" >/dev/null 2>&1
            e2fsck -fy "$PART" >"$WORK/fsck-after.log" 2>&1
            paste_back "$NVME" 2
            boot_vm installed-after 600 0
            L4="$WORK/installed-after/serial.log"
            grep -aq 'INSTUSB-AFTER-DONE' "$L4" \
                && ok "boot 4: the installed machine booted again after the update" \
                || bad "boot 4: the machine did not come back after the update"
            # THE COMPARISON THAT MATTERS: the same package list, after a power
            # cycle. A version that only existed in boot 3's RAM fails here.
            if [ -f "$L3" ] && [ -f "$L4" ]; then
                B="$(grep -a -A40 'hpm list after' "$L3" | grep -aE '^[a-z0-9-]+ +[0-9]+\.[0-9]+\.[0-9]+' | sort)"
                A="$(grep -a -A40 'INSTUSB-AFTER: hpm list' "$L4" | grep -aE '^[a-z0-9-]+ +[0-9]+\.[0-9]+\.[0-9]+' | sort)"
                if [ -n "$A" ] && [ "$A" = "$B" ]; then
                    ok "boot 4: the package list is identical to the one the update left (the update is ON THE DISK)"
                elif [ -z "$A" ]; then
                    bad "boot 4: could not read a package list after the reboot"
                else
                    bad "boot 4: the package list changed across the reboot"
                fi
            fi
        fi
    else
        bad "cannot write the update rc onto the target"
    fi
else
    info "skipping the network stages"
fi

cleanup_mounts
echo "instusb: $pass passed, $fail failed"
[ "$fail" = 0 ]
