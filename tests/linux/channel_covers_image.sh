#!/usr/bin/env bash
# tests/linux/channel_covers_image.sh — THE CHANNEL MUST CARRY WHAT THE IMAGE
# SHIPS.
#
# THE INVARIANT, stated by the machine's owner and now enforced here:
#
#     "changes that we create here will end up in the package repository and
#      be able to be updated on. That's something going forward must always
#      be true."
#
# A file that is in the initramfs but not in any package is a file an
# INSTALLED machine can never receive a fix to. The live image gets it because
# the image is built from the tree; a person who installed hamnix-linux and
# runs `hpm update` gets nothing, forever, and NOTHING FAILS to tell them so.
# That is the worst shape a bug can have in this project: the gap answers with
# silence rather than with the truth.
#
# It has happened at least four times before this gate covered the whole root:
#   * the audio clients, when audio first landed -- an installed machine got
#     the audio DEVICE (compiled into every binary's runtime) and none of the
#     programs that could drive it (see the AUDIO_CMDS note in
#     scripts/hamlinux_packages.py);
#   * hamnix-desktop, dropped from a whole channel by a double-link that
#     printed one line of output;
#   * the seven this gate found the day it was written: audiolife, halt,
#     hamimgscene, host_ac, install, poweroff, xsnarfd -- including the two
#     commands that turn the machine off, and the X clipboard bridge that had
#     been written that same week;
#   * and 152 files this gate COULD NOT SEE, because it compared /bin and
#     nothing else. Measured on the published 1.0.12 channel: 34 kernel
#     modules (ext4, jbd2, vfat, virtio_blk, virtio_net, evdev, overlay,
#     squashfs, loop, the nls tables, the whole snd-hda stack), the
#     modules.dep table `modprobe` had just been made to depend on, the 21
#     manual pages `man` and `help` read, the 23 Adder runtime sources
#     /bin/ac must LINK against, /etc/skel, /etc/users/*.ns, ten static /etc
#     files including /etc/profile, /usr/share/sounds/test.wav, and /init --
#     the program the kernel executes. The gate passed every one of those
#     days: it was looking one directory over.
#
# AND ONCE BY AN EXCLUSION WHOSE REASON WAS FALSE -- the fifth shape, and the
# one this table has to be read for. `bin/host_ac` sat in the list above with
# the reason "the Adder compiler built for the BUILD HOST's libc ... the
# shippable compiler is `ac`, which IS packaged." Both halves were wrong:
#
#   * /bin/ac is a DRIVER, not a compiler. It execs /bin/host_ac (a hard-coded
#     path in user/ac.ad) to turn foo.ad into LLVM IR. Measured by deleting
#     host_ac from a staged root and running the real ac binary:
#         ac: cannot run /bin/host_ac
#         ac: hello.ad: the Adder compiler could not translate this program
#     exit 10, no binary. So "ac IS packaged" bought an installed machine
#     nothing at all -- and HANDOFF.md §0 listed "compiles Adder on the box"
#     as a MEASURED capability of this distribution the whole time.
#   * host_ac is not linked against the build host's libc. readelf: no
#     .dynamic section, no INTERP, "not a dynamic executable". It is the one
#     binary in /bin that needs no libc. `ac` is the one with NEEDED
#     libssl.so.3, libcrypto.so.3, libcrypt.so.1, libc.so.6 -- the exclusion
#     kept the static file out on a dynamic-linking worry that applied only to
#     the file it let through.
#
# host_ac is now carried by hamnix-adder (ADDER_COMPILER in
# scripts/hamlinux_packages.py) and the exclusion is gone. The lesson is about
# this table, not about that file: A REASON IN THIS LIST IS A CLAIM, and an
# unmeasured claim here is indistinguishable from the silent drop the gate
# exists to catch -- it just has prose in front of it. What the channel does
# for the toolchain is now RUN, not asserted: tests/linux/channel_compiles_adder.sh.
#
# WHAT THIS MEASURES NOW: EVERY regular file under the staged image root,
# against every install path carried by any package tarball in the built
# channel. Not the build logs, not the package COUNT -- the actual file lists,
# on disk. A count is exactly the kind of evidence that agrees with a silent
# drop.
#
# HOW AN OMISSION IS ALLOWED: by name, in the EXCLUSIONS table below, WITH A
# REASON. An unlisted omission fails, anywhere in the root. This is deliberate
# -- it makes "we do not ship that" a written decision rather than an accident
# nobody noticed. A listed exclusion that is no longer in the image is
# reported too, so the table cannot quietly go stale.
#
# WHICH ROOT YOU POINT IT AT IS PART OF THE ANSWER, and for a long time
# nobody said so. There are three, and they are different files:
#
#   * the LEAN image root         scripts/hamlinux_image.sh
#   * the INSTALLER image root    HAMLINUX_INSTALLER=1 scripts/hamlinux_image.sh
#                                 -- the one the SHIPPED MEDIUM is packed from
#   * the INSTALLED-DISK root     the ext4 partition scripts/hamlinux_disk.sh
#                                 writes, which is what a person actually runs
#
# MEASURED 2026-08-19 against the published 1.0.31 channel, before the
# exclusions below covered the installer overlay:
#
#   lean image root (424 files)          8 passed,  0 failed
#   installer image root                 7 passed, 26 failed
#   installed-disk root (453 files)      7 passed, 28 failed
#
# The 26 were boot/ (5), etc/installer-medium (1) and usr/lib/instroot/ (20).
# The disk root's two extra are etc/fstab and var/lib/hpm/installed.json, which
# exist only on a written partition. 1.0.31 SHIPPED with this row RED --
# `~/.hamnix-build/rel1031/GATES_SUMMARY.txt` records "channel_covers_image
# RED 7/26 <-- against the INSTALLER root". Each of those files now has a line
# in the table below with a reason, so the red is a written decision instead of
# a number a release stepped over.
#
# AND WHAT THAT COSTS AN INSTALLED MACHINE, WRITTEN AT THE TOP SO A GREEN RUN
# CANNOT BE MISREAD AS MORE THAN IT IS:
#
#   THE KERNEL AN INSTALLED MACHINE BOOTS IS NOT UPDATABLE, AND NOTHING FAILS
#   TO SAY SO. It is sealed in the unified kernel image on that machine's ESP,
#   copied there byte for byte on install day. No package carries it, `hpm
#   update` does not touch it, and the machine boots it forever. That is a
#   real limit of this distribution, not an oversight of this gate, and the
#   boot/ exclusion below argues why a package FILE cannot be the fix.
#
#   WHAT *IS* UPDATABLE ACROSS THE BOOT is the boot-time MODULE BYTES:
#   /bin/bootsync rewrites them inside the ESP's own image and user/hpm.ad runs
#   it after every update transaction. Four assertions below read that out of
#   the built tarballs. Whether the refresh reaches a BOOTED kernel is measured
#   by tests/linux/bootsync_installed.sh, on a machine; nothing in this file
#   boots anything.
#
# THE NEGATIVE CONTROL, RUN 2026-08-19, evidence in
# `~/.hamnix-build/covergap-a847/negctl.log` (the driver is negctl.sh beside
# it). Each arm breaks ONE thing in a COPY of the 1.0.31 channel, or in a copy
# of this file, against the installed-disk root:
#
#   arm 0  nothing broken                                 12 / 0
#   arm 1  hamnix-init made to carry boot/vmlinuz          11 / 1
#   arm 2  bin/bootsync deleted from hamnix-install        10 / 2
#   arm 3  shipped rc.boot.installed stops binding '#esp'  10 / 2
#   arm 4  the hpm ELF replaced by one with no bootsync    11 / 1
#   arm 5  the boot/ EXCLUSION deleted from this file      11 / 5
#
# Arms 2 and 3 score two failures because each breaks a second thing this file
# already checked (bin/bootsync stops being covered at all; the shipped
# rc.boot.installed stops matching the image's bytes). Arm 5 is the one that
# says the five boot files are excused BY THE TABLE and not by a hole in the
# matcher.
#
# Usage: tests/linux/channel_covers_image.sh [image-root] [channel-dir]
#   defaults: build/image/root  build/repo/linux
# Requires both to have been built already; it builds nothing itself, because
# a gate that rebuilds its own inputs can hide the failure it exists to catch.

set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IMG="${1:-$ROOT/build/image/root}"
CHAN="${2:-$ROOT/build/repo/linux}"

PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); echo "PASS: $*"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

# ---------------------------------------------------------------------------
# THE EXCLUSIONS. One per line: "<pattern><TAB><reason>".
#
# A pattern is either an exact path relative to the image root, or a path
# ending in '/' which covers everything beneath it, or a path containing '*'
# (matched with bash's == inside [[ ]]).
#
# A reason has to be about the FILE -- what it is and why a package must not
# carry it -- not about the effort of packaging it. Every reason below is
# either a measurement or a mechanism somebody can go and read.
# ---------------------------------------------------------------------------
EXCLUSIONS=$(cat <<'EOF'
bin/audiolife	an audio stream LIFETIME scenario driver: a test fixture, not a program a user runs. It is in the image because the audio tests run inside the image.
init	SHIPPED, BUT BY A HOOK, and the hook is checked below. /init is byte-identical to /bin/linuxinit (which hamnix-init packages) and is what the kernel executes on an installed machine. A package FILE at /init would be opened for writing on the running PID 1's text image -- ETXTBSY -- so the install would fail on every machine that is up. hamnix-init's install.hamsh unlinks it and copies /bin/linuxinit over it instead.
etc/modules	the machine's BOOT MODULE LIST, and an append target. linuxinit walks it in file order, and every driver package's install hook appends its own modules to it. A package that shipped this file would replace it, silently un-listing the GPU driver an installed machine had added. The SIZE half of this reason is now out of date and is kept corrected rather than deleted: it said "a hard 8192-byte ceiling (linuxinit reads it with ONE read)", and that single read is exactly the defect 0fd022d4 removed. linuxinit now LOOPS, appending at the current offset into a 32768-byte buffer, and reports listed-vs-loaded on the boot line so a shortfall is visible; tests/linux/modules_list_complete.sh measures both, and measured this candidate's list at 6018 of 32768 bytes (87 module lines, 26750 spare). So appends are far less likely to blow the buffer than this line claimed, and if they ever do the boot line says so by name. The EXCLUSION still stands on its first reason alone, which is the load-bearing one: this file is an append target, and a package that shipped it would replace it. The FILES it names are packaged -- hamnix-drivers-base and hamnix-drivers-*.
lib/modules/*/modules.dep	the machine's DEPENDENCY TABLE: depmod generated it over the modules THAT machine has, and hamnix-drivers-drm, -gpu-intel and -gpu-nouveau each APPEND to it from their install hooks. A package file at this path would be deleted-then-rewritten on every upgrade, taking the appended driver lines with it -- the machine would keep i915.ko on disk and lose the only line that lets `modprobe i915` name it. The package-owned copy is modules.dep.base (hamnix-drivers-base), which its hook PREPENDS; modprobe takes the first matching line, so the shipped lines win and the appended ones survive. Checked below.
etc/shadow	this machine's password hashes, mode 0600. Shipping it would revert every password anybody had changed, on every update -- and hpm's extractor writes 0644, so it would also publish them. It is provisioned once, by the image or the installer.
etc/resolv.conf	written at runtime by dhcpc from the lease. A package copy would overwrite a working machine's resolver with the build host's placeholder.
etc/hpm/trusted.pub	the Ed25519 public key that AUTHENTICATES this channel. A package cannot carry the key its own signature is checked against: an attacker who could publish a package could then rotate the trust root that verifies the next one. It is provisioned with the medium, out of band.
etc/hpm/local-trusted.pub	the second trust root, for locally-signed test channels. Same reason as trusted.pub, and it is a DEVELOPMENT key besides.
etc/distros	the description of which distribution media THIS machine has -- `LABEL=...` lines a user edits to add a distro (the file's own header says a new distribution is a line in a file, not a recompile). A package copy would overwrite those edits on every update.
etc/rc.distros	GENERATED by scripts/hamlinux_image.sh from /etc/distros, which the machine owns and edits. Shipping the build host's copy would describe media the machine does not have and omit the ones it does.
etc/rc.distros-wl	GENERATED from /etc/distros, same as rc.distros.
etc/rc.de-ns/	GENERATED from /etc/distros, one file per distribution the machine knows about. Same reason.
version	the image BUILD STAMP -- one line naming the kernel and the git commit the initramfs was built from. It describes the medium, not the software; a package copy would make an updated machine claim the commit of whatever image it was installed from.
lib64/ld-linux-x86-64.so.2	the BUILD HOST's dynamic loader, copied in beside the glibc-linked binaries. It is not a change made here, and hpm writes files in place: replacing the loader every running process is executing through -- including hpm's own -- is not an update, it is a machine that stops between two syscalls. It travels with the medium.
lib/x86_64-linux-gnu/	the BUILD HOST's shared libraries (libc, libcrypt, libcrypto, libssl, libz, libzstd), copied in by scripts/hamlinux_image.sh's copy_libs. Same reason as the loader above, and the same fact: they are Debian's files, not this project's changes. The Mesa/Vulkan libraries this project DOES ship live under /usr/lib and ARE packaged.
home/live/	the live session's HOME, a copy of /etc/skel made by the image so a live boot can save a file. /etc/skel is the copy that ships (hamnix-desktop); an installed machine's /home belongs to its users, and a package that wrote into it would overwrite their documents.
boot/	THE INSTALLER'S PAYLOAD, and on an installed machine this path is not this directory. Staged ONLY under HAMLINUX_INSTALLER=1 (scripts/hamlinux_image.sh) so user/hlinstall.ad has bytes to write onto a TARGET disk's ESP: BOOTX64.EFI (the unified kernel image, 73 MB), vmlinuz, initramfs.cpio.gz, UKI.MAP and root.partuuid. Every one of them describes THE MEDIUM and not the machine: root.partuuid is the partition GUID the build host sealed into the UKI's kernel command line, and UKI.MAP's first line is the BYTE LENGTH of THIS image's initramfs archive, which user/bootsync.ad uses as the offset it appends its overlay at -- another medium's number there is a machine that does not boot. And a package could not deliver them anyway: etc/rc.boot.installed does `bind '#esp' /boot` on every installed boot, so /boot on a RUNNING installed machine IS the FAT32 EFI System Partition, not this ext4 directory. Measured on the 1.0.31 medium: the ESP holds EFI/BOOT/BOOTX64.EFI, vmlinuz, initramfs.cpio.gz and UKI.MAP -- NOT boot/BOOTX64.EFI -- so a package file at this path would be written into the ESP BESIDE the boot image, changing nothing about the boot. WHAT THAT COSTS, SAID PLAINLY SO THE GREEN BELOW IS NOT READ AS MORE THAN IT IS: the KERNEL BINARY and the INITRAMFS USERLAND sealed in the UKI ARE NOT UPDATABLE. An installed machine boots the kernel it was installed with, and `hpm update` neither replaces it nor fails. The BOOT-TIME MODULE BYTES ARE updatable -- /bin/bootsync rewrites them inside the ESP's own UKI and user/hpm.ad runs it after every update transaction -- and that claim is MEASURED below rather than asserted here.
usr/lib/instroot/	THE INSTALLER'S PARTITIONING TOOLS: Debian's sgdisk, mkfs.vfat, mkfs.ext4 and openssl with the build host's glibc, libext2fs, libblkid, libuuid, libssl, libstdc++ and the loader they run through, staged ONLY under HAMLINUX_INSTALLER=1 (scripts/hamlinux_image.sh). Same fact as lib/x86_64-linux-gnu above -- Debian's files, not this project's changes, and hpm writes in place -- plus one this file has to say for itself: they exist to partition a TARGET disk, which is a thing only installation media does. An installed machine is not installation media (that confusion is the defect fixed at 13755222, where an installed machine offered to install itself), so shipping them to one would be shipping the tools for a job it must not offer.
etc/installer-medium	THE MARKER THAT SAYS `THIS ROOT IS INSTALLATION MEDIA`. Four programs -- user/hamdesktop.ad, user/hampanelscene.ad, user/hamappmenu.ad and user/hamsoftware.ad's _reg_is_live -- read `it opened` as `I am running from a medium` and put the Install icon on the desktop on that alone. user/hlinstall.ad UNLINKS it from the target at install time for exactly that reason. A package that carried this file would put the installer back on every machine it updated: the 13755222 defect, delivered by the channel instead of by the installer.
etc/fstab	THIS machine's partitions, by PARTUUID, written by scripts/hamlinux_disk.sh with the two GUIDs it had just given THIS disk. A package copy would name the build host's partitions on somebody else's machine. It is on the ROOT PARTITION only -- the initramfs root does not carry it -- which is one of the two files that make a disk root's file count differ from an image root's.
var/lib/hpm/installed.json	THE MACHINE'S PACKAGE DATABASE: what hpm believes is installed here, with each package's file list, rewritten by hpm on every transaction. A package that carried it would overwrite the record of this machine's installs with the build host's -- including the record of the update in progress -- and the machine would then never upgrade whatever the shipped copy failed to mention. It is seeded once per disk by scripts/hamlinux_disk.sh. Root partition only, like etc/fstab.
EOF
)

[ -d "$IMG" ]  || { echo "FAIL: no image root at $IMG (run scripts/hamlinux_image.sh)"; exit 1; }
[ -d "$CHAN" ] || { echo "FAIL: no channel at $CHAN (run scripts/hamlinux_packages.py)"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# A bare EXIT trap does not run when the shell is killed by a signal, so a
# gate stopped by `timeout` (TERM) or ^C (INT) skipped its cleanup entirely.
# Re-exit on those, which makes the EXIT trap above run on every path out.
trap 'exit 130' INT TERM HUP

# --- what the image ships --------------------------------------------------
# Every regular file and symlink, relative to the image root. Directories are
# not compared: hpm recreates a parent from the path of the file inside it, so
# an empty directory is not something a package can carry or fail to carry.
( cd "$IMG" && find . \( -type f -o -type l \) | sed 's|^\./||' ) | sort > "$TMP/img"

# --- what the channel carries ----------------------------------------------
# Package layout is <name>-<ver>/files/<install-path>, so an installed file is
# everything after the first '/files/'.
#
# A module that ships GZIPPED covers the .ko path it is gunzipped to: the
# install hook runs `gzip -d` on it (i915.ko is 9.9 MiB, over hpm's in-RAM
# unpack cap). Stripping the suffix here is why hamnix-drivers-gpu-intel
# counts as carrying i915.ko rather than reading as an omission.
for t in "$CHAN"/packages/*.tar.gz; do
    [ -e "$t" ] || continue
    tar tzf "$t" 2>/dev/null
done | sed -n 's|^[^/]*/files/||p' | grep -v '/$' \
     | sed 's|^\(lib/modules/.*\.ko\)\.gz$|\1|' | sort -u > "$TMP/chan"

NIMG=$(wc -l < "$TMP/img")
NCHAN=$(wc -l < "$TMP/chan")
NIMGBIN=$(grep -c '^bin/' "$TMP/img" || true)
NCHANBIN=$(grep -c '^bin/' "$TMP/chan" || true)
echo "image: $NIMG files ($NIMGBIN in /bin)    channel: $NCHAN files ($NCHANBIN in /bin)"

# A sanity floor. If the extraction pattern silently matches nothing -- which
# it DID during development, when the layout was /files/bin and the pattern
# assumed /bin -- every comparison below would "find" the whole image missing,
# or worse, an empty image list would make everything pass. Refuse to report
# on lists that are implausible, rather than reporting a confident wrong answer.
if [ "$NIMGBIN" -lt 50 ] || [ "$NIMG" -lt 200 ]; then
    bad "only $NIMG files ($NIMGBIN in /bin) found in $IMG -- the image looks unbuilt or the path is wrong; NOT reporting coverage from it"
    echo; echo "$PASS passed, $FAIL failed"; exit 1
fi
if [ "$NCHANBIN" -lt 50 ] || [ "$NCHAN" -lt 200 ]; then
    bad "only $NCHAN files ($NCHANBIN in /bin) extracted from $CHAN/packages -- the tarball layout is not what this gate parses; NOT reporting coverage from it"
    echo; echo "$PASS passed, $FAIL failed"; exit 1
fi
ok "both lists are plausible ($NIMG image files, $NCHAN channel files) -- the comparison below means something"

# --- THE MEASUREMENT -------------------------------------------------------
comm -23 "$TMP/img" "$TMP/chan" > "$TMP/missing"

# Split the missing list into "excluded by name, with a reason" and the rest.
: > "$TMP/unexpected"
: > "$TMP/excused"
: > "$TMP/used_patterns"
while IFS= read -r f; do
    [ -n "$f" ] || continue
    matched=""
    while IFS=$'\t' read -r pat reason; do
        [ -n "${pat:-}" ] || continue
        case "$pat" in
            */) [[ "$f" == "$pat"* ]] && matched="$pat" ;;
            *\**) [[ "$f" == $pat ]] && matched="$pat" ;;
            *)  [ "$f" = "$pat" ] && matched="$pat" ;;
        esac
        [ -n "$matched" ] && break
    done <<< "$EXCLUSIONS"
    if [ -n "$matched" ]; then
        printf '%s\t%s\n' "$matched" "$f" >> "$TMP/excused"
        echo "$matched" >> "$TMP/used_patterns"
    else
        echo "$f" >> "$TMP/unexpected"
    fi
done < "$TMP/missing"

NMISS=$(wc -l < "$TMP/missing")
NEXC=$(wc -l < "$TMP/excused")
NUNEXP=$(wc -l < "$TMP/unexpected")

if [ "$NUNEXP" -gt 0 ]; then
    while IFS= read -r u; do
        bad "$u ships in the image and is in NO package -- an installed machine can never update it"
    done < "$TMP/unexpected"
    echo
    echo "Add each to a package in scripts/hamlinux_packages.py -- a command"
    echo "list (COREUTILS, DESKTOP_CMDS, SYS_CMDS, NET_CMDS, AUDIO_CMDS,"
    echo "AUTH_CMDS, MOD_CMDS), a COMPONENTS extras list, ADDER_SHARE,"
    echo "MAN_PAGES, SKEL_FILES or hamnix-drivers-base -- or, if it genuinely"
    echo "must not ship, add it to EXCLUSIONS in this file WITH A REASON."
    echo "Silence is not one of the options."
else
    ok "every file in the image is carried by a package or excluded by name ($NIMG checked, $NEXC excluded)"
fi

# --- the exclusion table is itself checked ---------------------------------
# An exclusion nobody exercises is a decision about a file that is no longer
# there; it is not a failure, but it must not go unsaid, or the list turns
# into folklore.
sort -u "$TMP/used_patterns" 2>/dev/null > "$TMP/used" || : > "$TMP/used"
STALE=""
while IFS=$'\t' read -r pat reason; do
    [ -n "${pat:-}" ] || continue
    grep -qxF "$pat" "$TMP/used" || STALE="$STALE $pat"
done <<< "$EXCLUSIONS"
if [ -n "$STALE" ]; then
    echo "note: exclusions that matched nothing in this image (stale, or now packaged):$STALE"
else
    ok "every exclusion in the table is still exercised by this image -- none is folklore"
fi

echo
echo "excluded by name, grouped by reason:"
cut -f1 "$TMP/excused" | sort | uniq -c | sort -rn | while read -r n pat; do
    printf '  %4d  %s\n' "$n" "$pat"
done

# --- the two exclusions that claim something IS shipped --------------------
# Both of the entries above that say "shipped, but not as a file at this path"
# are claims about a mechanism. A claim nothing measures is the shape every
# bug in this tree has worn, so measure them: read the bytes out of the built
# tarballs.
INITPKG=$(ls "$CHAN"/packages/hamnix-init-*.tar.gz 2>/dev/null | head -1)
if [ -n "$INITPKG" ]; then
    HOOK=$(tar xzOf "$INITPKG" --wildcards '*/install.hamsh' 2>/dev/null)
    if echo "$HOOK" | grep -q "cp '/bin/linuxinit' '/init'"; then
        ok "/init is excluded as a file and hamnix-init's install.hamsh really does copy /bin/linuxinit onto it"
    else
        bad "/init is excluded on the grounds that hamnix-init's install hook copies it, and that hook does NOT -- the kernel's own program is unupdatable"
    fi
    if tar tzf "$INITPKG" | grep -q 'files/bin/linuxinit'; then
        ok "hamnix-init carries bin/linuxinit, which is the bytes that hook copies"
    else
        bad "hamnix-init does not carry bin/linuxinit -- the /init hook would copy nothing"
    fi
else
    bad "no hamnix-init package in the channel -- /init and the boot files are unupdatable"
fi

DEPBASE=$(grep -c '^lib/modules/.*/modules\.dep\.base$' "$TMP/chan" || true)
if [ "$DEPBASE" -ge 1 ]; then
    ok "modules.dep is excluded as machine state and the package-owned copy (modules.dep.base) IS in the channel"
    BASEPKG=$(ls "$CHAN"/packages/hamnix-drivers-base-*.tar.gz 2>/dev/null | head -1)
    if [ -n "$BASEPKG" ] && tar xzOf "$BASEPKG" --wildcards '*/install.hamsh' 2>/dev/null \
         | grep -q "modules.dep.base' '/lib/modules/.*/modules.dep' >"; then
        ok "hamnix-drivers-base's hook PREPENDS its table to the machine's (cat base dep > new; mv) -- the lines the driver packages appended survive"
    else
        bad "hamnix-drivers-base ships modules.dep.base but its install hook does not merge it -- the table would never be refreshed"
    fi
else
    bad "modules.dep is excluded on the grounds that modules.dep.base ships instead, and NO package carries modules.dep.base"
fi

# --- THE boot/ EXCLUSION IS FOUR CLAIMS, AND HERE THEY ARE MEASURED --------
# The boot/ line in the table above is the longest reason in this file and the
# easiest one to be wrong about, so none of it is left as prose. What it claims,
# and what is read out of the BUILT CHANNEL to check it:
#
#   1. No package carries any path under boot/. This is the SAFETY half rather
#      than the coverage half, and it is the one that matters most: on an
#      installed machine etc/rc.boot.installed binds the ESP over /boot, so a
#      package file at boot/anything would be written into a FAT32 partition
#      with no journal, beside the boot image, by an hpm that knows about
#      neither. If somebody ever "fixes" this gate's boot/ failures by
#      packaging the files, this assertion goes red and says why.
#   2. /boot on an installed machine IS the ESP -- the mechanism claim the whole
#      reason rests on. Checked in the bytes hamnix-init would DELIVER, not in
#      the worktree, because the worktree is not what an update installs.
#   3. The channel carries bin/bootsync, the only program that can change what
#      an installed machine boots with.
#   4. The SHIPPED hpm binary really runs it. hpm's source says it spawns
#      /bin/bootsync after the whole transaction; the thing an installed machine
#      receives is the ELF in the tarball, so the ELF is what is read.
#
# WHAT NONE OF THIS ESTABLISHES, spelled out here as well as in the table: that
# the KERNEL is updatable. IT IS NOT. These four say the boot MODULE BYTES can
# be refreshed and that the machinery to do it ships and is itself updatable.
# Whether a refresh actually reaches a booted kernel is a different question on
# a booted machine -- tests/linux/bootsync_installed.sh -- and no line here
# stands in for it. Nothing in this file boots anything.
echo
BOOTUNPACK="$TMP/bootunpack"; mkdir -p "$BOOTUNPACK"
grep '^boot/' "$TMP/chan" > "$TMP/chanboot" 2>/dev/null || : > "$TMP/chanboot"
if [ -s "$TMP/chanboot" ]; then
    while IFS= read -r b; do
        [ -n "$b" ] || continue
        bad "a package carries $b, and on an installed machine /boot IS the FAT32 ESP (etc/rc.boot.installed binds it there) -- hpm would write into the boot partition"
    done < "$TMP/chanboot"
else
    ok "no package carries any path under boot/ -- nothing in this channel writes into an installed machine's ESP"
fi

for t in "$CHAN"/packages/hamnix-init-*.tar.gz; do
    [ -e "$t" ] || continue
    tar xzf "$t" -C "$BOOTUNPACK" --wildcards '*/files/etc/rc.boot.installed' 2>/dev/null || true
done
RCINST="$(find "$BOOTUNPACK" -path '*/files/etc/rc.boot.installed' -type f 2>/dev/null | head -1)"
if [ -n "$RCINST" ] && grep -qF "bind '#esp' /boot" "$RCINST"; then
    ok "the boot/ exclusion's mechanism holds in the bytes a machine would RECEIVE: the shipped etc/rc.boot.installed binds the ESP over /boot"
elif [ -n "$RCINST" ]; then
    bad "the shipped etc/rc.boot.installed does NOT bind the ESP over /boot -- the boot/ exclusion's reason is no longer true, and /boot on an installed machine is an ordinary ext4 directory a package could own"
else
    bad "no etc/rc.boot.installed in the channel -- an installed machine's boot script is unupdatable and the boot/ exclusion's reason cannot be checked"
fi

if grep -qx 'bin/bootsync' "$TMP/chan"; then
    ok "the channel carries bin/bootsync -- the one program that can change what an installed machine boots with is itself updatable"
else
    bad "NO package carries bin/bootsync. The boot/ exclusion stands on bootsync refreshing the boot image, and a machine whose bootsync is a release behind could never be given a fixed one"
fi

HPMPKG=$(ls "$CHAN"/packages/hpm-*.tar.gz 2>/dev/null | head -1)
if [ -n "$HPMPKG" ]; then
    tar xzOf "$HPMPKG" --wildcards '*/files/bin/hpm' > "$TMP/hpmbin" 2>/dev/null
    if [ -s "$TMP/hpmbin" ]; then
        if grep -qa '/bin/bootsync' "$TMP/hpmbin" \
           && grep -qa 'refreshing the boot image' "$TMP/hpmbin"; then
            ok "the hpm BINARY the channel ships carries the /bin/bootsync spawn path and its message -- an update on a machine really does reach for the boot image"
        else
            bad "the shipped bin/hpm does not name /bin/bootsync -- the boot/ exclusion claims hpm runs bootsync after every update transaction, and the binary an installed machine would receive does not contain it"
        fi
    else
        bad "the hpm package carries no files/bin/hpm -- cannot check whether the shipped updater runs bootsync"
    fi
else
    bad "no hpm package in the channel -- the updater itself is unupdatable"
fi

# --- THE RIGHT NAME IS NOT THE RIGHT BYTES ---------------------------------
# Everything above this line compares NAMES. NORTH_STAR.md already records
# what that misses -- hamnix-desktop 1.0.10 shipped every name, every sha256
# matched, and the desktop mapped no windows -- and it missed it again, in a
# different subsystem and in a way no binary gate could see:
#
#   The `hpm` package shipped etc/hpm/channels, the NATIVE line's
#   subscription list, whose one entry is `main`. The image stages
#   etc/hpm/channels.LINUX at that path, whose entry is `linux`. Both files
#   are called etc/hpm/channels, so the comparison above was silent. What it
#   meant is that `hpm install hamnix-base` -- the flagship package, which
#   declares hpm>=1 -- REWROTE the machine's subscription to a channel of
#   NATIVE binaries, and every `hpm refresh` and `hpm update` afterwards
#   aborted on a 404 for https://255.one/main/index.json.sig. A machine was
#   cut off from its own repository by the act of installing from it.
#
# So: for every /etc file the image stages AND a package carries, compare the
# BYTES. /etc is the whole scope of THIS file, and the reason written here
# used to be that "a per-byte compare of an ELF would go red on any legitimate
# rebuild". THAT IS NO LONGER TRUE and the sentence was costing a real defect:
# the Linux lane builds the same source to the same bytes (measured -- two
# builds of user/cat.ad into separate directories are one sha256), so the ELFs
# ARE comparable and tests/linux/channel_bytes_match_image.sh compares all 229
# of them. On its first run it found /bin/install: the image stages hlinstall
# there, the channel carried a build of user/install.ad -- a different
# installer -- and this file said `covered` because both sides spell the name
# `bin/install`. A configuration file has no such excuse either: if the
# channel's copy differs from the one the image boots with, one of the two is
# wrong and nobody knows which.
echo
: > "$TMP/etcdiff"
ETCN=0
UNPACK="$TMP/unpack"; mkdir -p "$UNPACK"
for t in "$CHAN"/packages/*.tar.gz; do
    [ -e "$t" ] || continue
    tar xzf "$t" -C "$UNPACK" --wildcards '*/files/etc/*' 2>/dev/null || true
done
#
# TWO KINDS OF ENTRY ARE SKIPPED, and neither is a judgement call:
#   * a file the channel carries and the image does not stage AT ALL is not a
#     mismatch -- it is the "more in the channel than the image" case, already
#     reported at the end of this file. etc/rc.boot.linux, .installed and
#     .machine are all of these: the image stages one of them AS /etc/rc.boot.
#   * etc/rc.boot itself, whose difference is the DESIGN: the channel ships
#     etc/rc.boot.machine there (the one-line `source '/etc/rc.boot.installed'`)
#     while the image stages etc/rc.boot.linux, and hpm's _is_machine_owned
#     keeps whichever one a machine already has. Named here with its reason,
#     the same way every exclusion in this file is.
ETC_BYTE_SKIP="etc/rc.boot"
while IFS= read -r rel; do
    case " $ETC_BYTE_SKIP " in *" $rel "*) continue ;; esac
    [ -f "$IMG/$rel" ] || continue
    src="$(find "$UNPACK" -path "*/files/$rel" -type f 2>/dev/null | head -1)"
    [ -n "$src" ] || continue
    ETCN=$((ETCN + 1))
    cmp -s "$src" "$IMG/$rel" || printf '%s\n' "$rel" >> "$TMP/etcdiff"
done < <(grep '^etc/' "$TMP/chan")
# `grep -c . file` on a missing file PRINTS 0 and EXITS 1, so the obvious
# `$(grep -c . f || echo 0)` produced the two-line string "0\n0", and
# `[ "0\n0" -gt 0 ]` is not false -- it is an ERROR ("integer expression
# expected", exit 2), which fell through to the PASS branch. The comparison
# was therefore decided by a shell error every time it was clean, which is
# this project's own worst shape in a gate: a pass that is not an answer.
NDIFF=$( [ -s "$TMP/etcdiff" ] && grep -c . "$TMP/etcdiff" || echo 0 )
if [ "$ETCN" -lt 5 ]; then
    bad "only $ETCN /etc files were found in both the image and the channel -- this comparison is not measuring anything"
elif [ "$NDIFF" -gt 0 ]; then
    while IFS= read -r d; do
        bad "/$d in the channel is NOT the bytes the image boots with -- an installed machine's copy is replaced by a different file on every update, and nothing says which one is right"
        diff "$(find "$UNPACK" -path "*/files/$d" -type f | head -1)" "$IMG/$d" \
            | head -8 | sed 's|^|      |'
    done < "$TMP/etcdiff"
else
    ok "all $ETCN /etc files the channel carries are BYTE-IDENTICAL to the ones the image stages -- no package quietly replaces a machine's configuration with a different file"
fi

# The other direction is NOT a failure -- a channel may offer more than the
# initramfs has room for -- but it is worth saying out loud, because a file in
# the channel and not the image is a file nobody has ever seen on a live boot.
EXTRA=$(comm -13 "$TMP/img" "$TMP/chan" | grep -c . || true)
if [ "$EXTRA" -gt 0 ]; then
    echo
    echo "note: $EXTRA files in the channel and not the image (never exercised on a live boot):"
    comm -13 "$TMP/img" "$TMP/chan" | sed 's|/[^/]*$||' | sort | uniq -c | sort -rn | head -12 | sed 's|^|    |'
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
