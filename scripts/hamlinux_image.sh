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
# The object/build-log directory. It survived every build in a tree that had
# already built once, so a FRESH checkout was the only thing that hit it: every
# `>"$OUT/obj/$app.build.log"` redirect failed, every application landed in
# MISSING, and the first honest error was `no host_ac.elf` several hundred
# lines later.
mkdir -p "$OUT/obj"
mkdir -p "$ROOT"/{bin,etc,proc,sys,dev,srv,n,tmp,root,home,mnt,boot,lib,lib64,var/log,var/lib/hpm,var/cache,usr/bin,usr/share/adder}

# The applications that go in /bin. Kept to things that build AND run today
# (measured -- see HANDOFF.md §5); the point of the image is to boot, not to be
# complete. `hamsh` is the important one: it is PID 1 after linuxinit execs it.
#
# `rmdir` AND `file` WERE IN THIS LIST AND HAVE NEVER EXISTED. Both have been
# named here since the first boot commit (d8853529) and neither user/rmdir.ad
# nor user/file.ad was ever written, so every build of this image has printed
#
#     [image] not included: rmdir(no source) file(no source)
#
# and every machine built from it has had no `rmdir` and no `file`. The list
# said, one line above, that it is "kept to things that build AND run today",
# so it contradicted itself on every run -- which is the kind of small lie that
# makes the honest lines beside it worth less.
#
# They are removed rather than stubbed. Nothing in the tree calls either one:
# no rc script, no install hook, no package. So this is a name with nothing
# behind it, not a script shelling out to a missing binary, and the fix is to
# stop promising it. To bring `rmdir` back, write user/rmdir.ad (rmdir(2) is
# reachable -- `rm` already unlinks) and put the name back in this list;
# hamlinux_packages.py's COREUTILS is where it would also need to go to reach
# an installed machine.
APPS=(
    hamsh
    ls cat echo cp mv rm mkdir ln touch pwd
    grep sed sort uniq head tail wc cut tr
    find du df stat tree
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
    # THE SSH CLIENT AND THE SSH SERVER. Both build on this line, both were
    # in NO image and NO package -- so a PRE-AUTHENTICATION bounds fix in
    # sshd, landed and gated, reached nobody at all. They are in BOTH lists
    # for the reason hamappmenu is: this one puts them in /bin,
    # scripts/hamlinux_packages.py puts them in a package so `hpm update` can
    # ever fix them, and tests/linux/channel_covers_image.sh only NOTICES a
    # missing package for a file the image actually ships.
    #
    # MEASURED BEFORE BEING LISTED, with the packaged binaries: `ssh` with no
    # arguments spawns /bin/sshd and drives a whole SSH-2 session against it
    # -- key exchange, host key signature verified, encryption active,
    # password USERAUTH accepted, session channel opened, hamsh spawned and
    # bridged, clean disconnect.
    #
    # sshd is here and is NOT started. Nothing in etc/rc.boot.* runs
    # `svc start sshd`; the service definition ships in its own package
    # (hamnix-svc-sshd) and a person turns it on. A listening SSH server that
    # arrives because somebody asked for a desktop is not a default this
    # project gets to pick for them.
    #
    # httpd AND httpd_worker ARE NOT HERE, and the reason is measured rather
    # than assumed: on this line httpd accepts the connection, spawns the
    # worker, and the worker exits 0 having read nothing and written nothing,
    # so every request is answered with silence. A connection record's `fd`
    # in user/linux-net.c is a PER-PROCESS descriptor, and the worker is
    # handed only the connection NUMBER. Full trace and the rest of the
    # reasoning in scripts/hamlinux_packages.py above NET_CMDS. Same call
    # this list already makes about initctl and telinit, ten lines up, and
    # for the same reason.
    ssh sshd
    insmod modprobe lsmod rmmod
    xbridge wsyswl nsrun dhcpc ntpd
    # THE BOOT LOG WRITER, and it is here rather than in a package because a
    # machine that will not boot cannot install one. It is what turns a failed
    # boot on a machine with no serial cable from a photograph of the last
    # forty lines into a file the owner can carry to another computer:
    # etc/rc.boot.installed binds the stick's own FAT boot partition and spawns
    # this, which snapshots the kernel log ring -- shell output included, via
    # user/linux-syscalls.c:consmirror -- onto it every couple of seconds. Its
    # header is where the whole arrangement is argued.
    bootlogd
    # THE ONLY THING IN THIS TREE THAT CAN CHANGE WHAT AN INSTALLED MACHINE
    # BOOTS WITH, and it is here for the same reason bootlogd is: a machine
    # whose boot image is stale cannot install the program that fixes it from
    # a driver package, because the driver package is exactly what it cannot
    # boot. `hpm update` upgrades /lib/modules on the ext4 root; linuxinit
    # loads modules out of the INITRAMFS before the root switch, so until this
    # runs the upgrade has no effect on any boot. Its header is the argument.
    bootsync
    # The clipboard bridge. It is here rather than among the GUI apps because
    # it draws nothing: it is an X CLIENT that owns CLIPBOARD and PRIMARY on
    # the Xwayland inside a distribution namespace and mirrors both against
    # /dev/snarf, so that Firefox in Debian and the Hamnix editor have ONE
    # clipboard. One per distribution, started by the generated
    # /etc/rc.distros-wl beside that distribution's wsyswl.
    xsnarfd
    hlinstall haminstallui
    # Stopping the machine. `reboot` was here alone because the installer
    # wanted it; `poweroff` and `halt` were not shipped at all, so on a booted
    # system they answered `command not found` -- measured by
    # tests/linux/reboot_device.sh, which found 127 where it expected a
    # refusal. All three are one write of one verb to /dev/reboot
    # (user/linux-syscalls.c), they differ only in the verb, and `poweroff` is
    # the one most people type. A distribution that cannot be turned off by
    # name is not one somebody installs.
    #
    # initctl/telinit are deliberately NOT here: they reach PID 1 by writing
    # /proc/svc/ctl, a Hamnix-kernel node this line does not serve, so they
    # could only ever fail. hamsh's `init 0` / `init 6` builtins do the same
    # job in-process and DO work. Shipping a command that cannot work would be
    # the success-shaped answer this tree exists to avoid.
    reboot poweroff halt
    # Audio. All three are thin Plan 9 clients of /dev/audio, /dev/audioctl
    # and /dev/audioin (user/linux-audio.c) and none of them knows anything
    # about ALSA: `playtone` synthesises a square wave and needs no fixture at
    # all, which is what makes it the thing a gate can drive on a bare
    # console; `aplay` streams a .wav; `arecord` captures one. They were
    # absent from the image while the device was absent -- and `playtone`
    # reported success into a regular FILE called /dev/audio, which is exactly
    # why they are here now that there is a device behind the name.
    playtone aplay arecord
    # The audio LIFETIME scenario driver.  It is here for the same reason
    # hamimgscene is: it is the reproduction.  Its five phases are the shapes
    # every real audio client in this tree has (a staged clip that exits, a raw
    # write with no ctl at all, a streaming producer, a burst of effects over
    # music), and it is the only program on the box that runs two of them AT
    # ONCE -- which is the whole question tests/linux/audio_lifetime.sh asks.
    # 197 KB.
    audiolife
)

# The desktop. wsysd is the compositor (user/wsysd.ad — the userland half of
# the devwsys.ad port); the rest are ordinary scene clients that talk to it
# through /dev/wsys and know nothing about which kernel is underneath.
GUI_APPS=(
    wsysd
    hamdesktop hampanelscene hamtermscene hameditscene hamsettings hamfm
    hamUI hamUId
    # THE APPLICATIONS MENU. It is here because for the whole of the port it
    # was NOT, and hampanelscene's _appmenu_available() says what that cost in
    # as many words: the Applications button was pointed at /bin/hamappmenu,
    # the image did not build it, so the button spawned a program that did not
    # exist on every real machine and the panel quietly used its own flat
    # dropdown instead. The categorised menu -- search box, Favourites, one
    # fly-out per category, the Brisk shape the machine owner asked for --
    # existed in the tree and reached nobody. That is NORTH_STAR.md's worst
    # bug shape (a program in the tree and in no ship vehicle), and it is only
    # closed by BOTH this line and DESKTOP_CMDS in scripts/hamlinux_packages.py
    # -- tests/linux/channel_covers_image.sh fails if either is missing.
    hamappmenu
    # The demo for the scene IMAGE tier (the draw/ctl 'I' verb).  It is here
    # because for the whole of the port before the verb was ported it would
    # have been the ONLY thing on the box that could tell you the tier was
    # broken -- every other image client drew a hole and exited 0.  It is 40 KB
    # and it is the reproduction.
    hamimgscene
    # ---- THE APPLICATIONS THE MENU LISTS -----------------------------------
    # THE OTHER HALF OF /etc/hamde/apps. Staging the 26 shipped launchers (see
    # the /etc block below) is only honest if the programs they name are here:
    # of those 26 Exec targets, exactly THREE were in the list above --
    # hamtermscene, hameditscene, haminstallui -- so a correctly staged
    # catalogue would have produced a three-row Applications menu on a
    # distribution that has 26 desktop applications in its tree, all 26 of
    # which BUILD (scripts/hamlinux_sweep.sh: 363 of 363) and all 26 of which
    # the run sweep already drives (tests/linux/runsweep_recipes.tsv).
    #
    # They were never excluded on purpose; the launcher file and the APPS list
    # are two places an application has to be named and nothing compared them.
    # tests/linux/de_appmenu_installed.sh compares them now, in both
    # directions, so a launcher without a program and a program the channel
    # does not carry both fail by name instead of turning into a menu row that
    # does nothing when clicked.
    #
    # As with hamappmenu, BOTH lists are needed: this one puts them in /bin,
    # DESKTOP_APPS in scripts/hamlinux_packages.py puts them in a package, and
    # tests/linux/channel_covers_image.sh fails if either is missing.
    ham2048scene hamaudioscene hambrowse hamcalcscene hamcalscene
    hamchessscene hamctl hamfmscene hamgamedemo hamgamesnake haminput
    hamlogscene hamminescene hammonscene hamnotesscene hamsheet hamshotui
    hamslides hamsnakescene hamsoftware hamtetrisscene hamvideoscene hamwrite
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
# AND UNDER THEIR OWN NAMES, because hamnix-init PROMISES them and a package is
# only installed if the machine really carries every file it holds.
#
# etc/rc.boot.linux was on the image only as /etc/rc.boot -- a different path --
# and etc/rc.boot.machine was not on it at all, so hamnix-init could never be
# recorded in /var/lib/hpm/installed.json (scripts/hpm_installed_db.py). That is
# not cosmetic: hamnix-init owns /etc/rc.boot.installed, the file the machine's
# own one-line rc SOURCES, so an installed machine that cannot record
# hamnix-init is an installed machine no release can ever improve the boot of --
# and every other package depends on hamnix-init>=1, so an upgrade of ANY of
# them would drag an unrecorded hamnix-init in as a fresh install.
#
# etc/rc.boot.machine is also what user/hlinstall.ad's write_machine_rc_boot
# prefers when it is there, so the installed machine's /etc/rc.boot is now the
# package's own indirection rather than the six-line fallback that function
# writes when the file is missing. Both are the same three-line contract.
install -m644 etc/rc.boot.linux "$ROOT/etc/rc.boot.linux"
install -m644 etc/rc.boot.machine "$ROOT/etc/rc.boot.machine"
for f in hostname hosts passwd group issue motd panel.conf desktop.icons \
         os-release lsb-release debian_version profile resolv.conf \
         services protocols networks host.conf; do
    [ -f "etc/$f" ] && install -m644 "etc/$f" "$ROOT/etc/$f"
done

# THE MEDIUM MUST BE ABLE TO SAY WHICH RELEASE IT IS.
#
# Until 2026-08-17 it could not. /etc/os-release says VERSION="1.0" and
# /etc/lsb-release says DISTRIB_RELEASE=1.0 -- the SERIES, not the release --
# and nothing anywhere in the image root recorded 1.0.23 from 1.0.26. The
# packager takes its version from `--version` (default 1.0.0) and the image
# script took none at all, so the two halves of a release had no shared
# statement of what they were.
#
# That is not cosmetic. tests/linux/channel_bytes_match_image.sh compares the
# image's binaries against the channel's byte for byte and every failure it
# prints says the two "run different programs under one version" -- a claim
# about sameness that nothing could check. Run against an image and a channel
# built four hours apart it printed 31 such lines, all true about the bytes
# and all wrong about the cause. A gate cannot attribute drift between two
# trees that will not say which release they are.
#
# So: one line, written from the same version the channel is built with.
# HAMLINUX_VERSION is what the release runner already passes to the packager's
# --version; when it is unset this says so IN THE FILE rather than inventing a
# number, because a wrong stamp is worse than an absent one.
: "${HAMLINUX_VERSION:=unstamped}"
printf '%s\n' "$HAMLINUX_VERSION" > "$ROOT/etc/hamnix-release"
chmod 644 "$ROOT/etc/hamnix-release"
echo "[hamlinux] /etc/hamnix-release = $HAMLINUX_VERSION"

# THE SERVICE DEFINITIONS. /etc/svc/<name>.hamsh is one of the two places
# hamsh's `svc` builtin looks (svc_def_load: /etc/services.d/<n>.svc first,
# then here). MEASURED on this line before shipping it, because the image
# script already refuses initctl and telinit for looking working while being
# unable to work: in a chroot, `svc start` on a control service reached
# `state=running` with a live pid, and `svc start sshd` registered, forked and
# tracked the real /bin/sshd, which then started and generated a host key.
# So the supervisor works here even though user/linux-runtime.S stubs
# sys_svc_publish to -1 -- that stub costs `cat /proc/svc/<name>`, not the
# service. Nothing in etc/rc.boot.* starts any of these.
if [ -d etc/svc ]; then
    mkdir -p "$ROOT/etc/svc"
    for f in etc/svc/*.hamsh; do
        [ -f "$f" ] && install -m644 "$f" "$ROOT/etc/svc/$(basename "$f")"
    done
fi

# THE APPLICATIONS MENU'S DATA. `hamde` used to sit in the loop above, and the
# loop tests `[ -f "etc/$f" ]` -- FALSE for a directory. So the 26 shipped
# launchers were never staged on ANY machine, every menu found
# /etc/hamde/apps empty, and both the Brisk menu and the panel's dropdown fell
# back to their compiled-in lists -- lists naming /bin/calculator,
# /bin/hamterm, /bin/hamedit, /bin/hamview, /bin/hambrowse, /bin/hammonscene,
# /bin/hamctl, /bin/hamvideoscene and /bin/hamaudioscene, none of which the
# image's APPS above builds. Clicking one of those rows did nothing at all.
# Same shape as the bug that hid the menu itself: the feature ships, the data
# it needs does not.
#
# apps-optional/ is deliberately NOT staged: those launchers belong to the
# optional packages that carry them (scripts/build_packages.py installs each
# one with its program), and staging a launcher whose program is in no package
# would recreate the very defect above.
#
# It is only half a fix on its own -- a file in the image and in no package is
# a file an installed machine can never receive a fix to (NORTH_STAR.md), so
# HAMDE_APPS in scripts/hamlinux_packages.py carries the same files and
# tests/linux/channel_covers_image.sh fails if it stops.
if [ -d etc/hamde/apps ]; then
    mkdir -p "$ROOT/etc/hamde/apps"
    for f in etc/hamde/apps/*.desktop; do
        [ -f "$f" ] || continue
        install -m644 "$f" "$ROOT/etc/hamde/apps/$(basename "$f")"
    done
    echo "[image] staged $(ls "$ROOT/etc/hamde/apps" | wc -l) application launchers"
fi
# The distribution namespaces. /etc/distros maps a NAME to the medium behind
# it, and `bind '#distro/alpine' /n/alpine` reads it -- so a second (or fifth)
# distribution is a line in a file, not a recompile. See etc/distros.linux.
install -m644 "${HAMLINUX_DISTROS:-etc/distros.linux}" "$ROOT/etc/distros"
# The shim the DE application menu runs a distribution's program through. It
# is staged HERE, in the Hamnix root, and copied INTO each distribution by the
# generated /etc/rc.distros at boot -- see etc/de-ns-run.linux for why it has
# to be a file inside the tree.
install -m755 etc/de-ns-run.linux "$ROOT/etc/de-ns-run"

# --- and the rc scripts DERIVED from that table ---------------------------
# Three hand-written copies of the same five-line `ns clean { }` recipe used to
# live in etc/rc.boot.linux, etc/rc.boot.installed and etc/rc.de-user.linux,
# one per distribution per file. That is not a mechanism either: adding Fedora
# meant editing three files in three places and remembering the installed one,
# which is exactly the thing that had never been run.
#
# So they are GENERATED HERE from /etc/distros, and the three rc scripts each
# `source` the result. The description is the single source of truth, and the
# thing that crosses into every one of these files is the NAME.
#
# WHY GENERATED AND NOT LOOPED AT BOOT: hamsh's `enter` takes a namespace
# VALUE, not a string, so `NS='alpine'; enter $NS { }` cannot be written at
# all -- a template has to be captured under a literal name. Generating the
# literals from the table at build time is how the table stays the only place
# a distribution is named.
DISTRO_NAMES="$(awk '{sub(/#.*/,"")} NF>=2 && $1!="default" {print $1}' "$ROOT/etc/distros")"
{
    echo "# /etc/rc.distros -- GENERATED by scripts/hamlinux_image.sh from"
    echo "# /etc/distros. Do not edit: edit etc/distros.linux and rebuild."
    echo "#"
    echo "# For each distribution named in the table: bind its subtree server"
    echo "# under /n/<name>, and capture -- not enter -- an \`ns clean { }\`"
    echo "# template called after it. Capturing grants nothing; \`enter alpine"
    echo "# { sh }\` is what spends it."
    echo "#"
    echo "# The \`bind '#distro/<name>' /n/<name>\` below is ALSO what creates"
    echo "# the mount points inside that distribution's own root (/n, /dev,"
    echo "# /proc, /sys, /srv), because it is the one moment root holds the"
    echo "# medium -- user/linux-syscalls.c, distro_stage_mountpoints. The"
    echo "# session user cannot make them and \`enter <name>\` cannot work"
    echo "# without them: docs/linux_distro_namespaces.md 8.4."
    echo "#"
    echo "# And it is where /etc/de-ns-run is copied INTO each tree. That is"
    echo "# the shim the DE application menu runs a distribution's program"
    echo "# through (etc/de-ns-run.linux): by the time it runs, that tree is"
    echo "# \`/', so it has to be a file inside it, and root at boot is the"
    echo "# only one who can put it there."
    for n in $DISTRO_NAMES; do
        echo ""
        echo "bind '#distro/$n' /n/$n"
        echo "cp /etc/de-ns-run /n/$n/etc/de-ns-run"
        echo "# Stale X session state, cleared by ROOT because the session user"
        echo "# cannot. A distribution's /tmp is the medium's own and survives"
        echo "# the reboot (user/linux-syscalls.c, enter_root), it is sticky"
        echo "# 1777, and the lock, socket and log a ROOT-run X session left"
        echo "# behind are root-owned -- so uid 1001 can neither truncate nor"
        echo "# unlink them, and \`hamnix-x11session' dies on"
        echo "# \`cannot create /tmp/xwayland.log: Permission denied'. The X"
        echo "# server that made them cannot still be running: we just booted."
        echo "rm /n/$n/tmp/.X0-lock 2>/dev/null"
        echo "rm /n/$n/tmp/.X11-unix/X0 2>/dev/null"
        echo "# AND EVERY OTHER LOG THE SESSION APPENDS TO, not just Xwayland's."
        echo "# The three names above were the ones that had been MEASURED; the"
        echo "# rest of the family only became visible once the Wayland socket"
        echo "# was connectable (docs/linux_distro_namespaces.md 8.5) and the"
        echo "# session got far enough to reach them. Then the same boot printed"
        echo "#   hamnix-x11session: 246: cannot create /tmp/dbus-system.log: Permission denied"
        echo "#   hamnix-x11session: 132: cannot create /tmp/xtrace-untar.log: Permission denied"
        echo "# -- root-owned 0644 files baked into the medium's /tmp, which is"
        echo "# sticky 1777, so uid 1001 may neither truncate nor unlink them and"
        echo "# a plain \`> file' redirect dies. A GLOB rather than a fourth,"
        echo "# fifth and sixth literal name: the failing thing is the CLASS"
        echo "# (a session log left by a root-run session), and a list that has to"
        echo "# be extended every time somebody adds a log line is the same"
        echo "# whack-a-mole this section already lost once. Safe because we just"
        echo "# booted: nothing in this tree is running yet to own a /tmp file."
        echo "rm /n/$n/tmp/*.log 2>/dev/null"
        echo "rm /n/$n/tmp/*.err 2>/dev/null"
        echo "$n = ns clean {"
        echo "    bind '#distro/$n' /"
        echo "    bind '#c' /dev"
        echo "    bind '#p' /proc"
        echo "    bind '#s' /srv"
        echo "    bind '#/' /n"
        echo "}"
    done
} > "$ROOT/etc/rc.distros"
chmod 644 "$ROOT/etc/rc.distros"

# The mount points. `bind '#distro/alpine' /n/alpine` needs /n/alpine to
# exist, and distro_resolve()'s unprivileged fallback needs it to be a REAL
# mount point -- an empty directory of that name is the case it refuses.
for n in $DISTRO_NAMES; do mkdir -p "$ROOT/n/$n"; done
mkdir -p "$ROOT/n/distro"

# One launcher rc per distribution, for the DE application menu's GUI rows.
# user/hampanelscene.ad spawns `/bin/hamsh /etc/rc.de-ns/<name> <prog>`; hamsh
# stamps HAMNIX_DE_PROG from argv[2] and sources this. Same shape as
# /etc/rc.de-user: plant the surface while privileged, drop to the session
# user, then run the program -- here inside the distribution's namespace.
mkdir -p "$ROOT/etc/rc.de-ns"
for n in $DISTRO_NAMES; do
    cat > "$ROOT/etc/rc.de-ns/$n" <<RCNS
# /etc/rc.de-ns/$n -- GENERATED by scripts/hamlinux_image.sh.
#
# Run one program inside the \`$n\` distribution namespace, as the session
# user, with the Wayland client environment set. Spawned by the DE panel's
# application menu (user/hampanelscene.ad, _launch_distro_ns).
#
# THREE BINDS, AND THE TWO THAT ARE MISSING ARE THE POINT. Both were measured
# by tests/linux/distro_menu.sh, which runs this file the way the menu runs it
# and reads what came back:
#
#   * \`bind '#/' /n\` is NOT here. It mounts the root over /n, and /n/$n IS
#     the name this namespace is reachable by after the drop -- resolving the
#     medium means reading a volume LABEL off a block device, which uid 1001
#     cannot open, so distro_resolve falls back to the mount point the boot
#     posted (docs/linux_distro_namespaces.md 2.4). With it, every bind in the
#     template failed ENOENT and the program never ran while the launch
#     reported success. Re-binding /n/$n afterwards did not undo it.
#   * The other three ARE here, and dropping them all did not work either: the
#     root switch alone then failed ENOENT. \`bind\` is what gives this shell
#     a PRIVATE mount namespace, and it has to be acquired while the process is
#     still root -- after \`setuid 1001\` the only way to get one is a user
#     namespace, and a mount moved into one it does not own is not the same
#     mount. It is the same order etc/rc.de-user and
#     tests/linux/two_namespaces.sh use, which is why those work.
bind '#c' /dev
bind '#p' /proc
bind '#s' /srv
$n = ns clean {
    bind '#distro/$n' /
    bind '#c' /dev
    bind '#p' /proc
    bind '#s' /srv
    bind '#/' /n
}
# The program is the person's, so it runs as the person. Everything above
# needed CAP_SYS_ADMIN; nothing below may have it.
#
# HOME IS SET AND EXPORTED BEFORE THE DROP, AND THE DROP RESOLVES THE REAL ONE.
# \`setuid\` re-reads /etc/passwd for the new uid and rewrites HOME in the
# environment (user/hamsh.ad:builtin_setuid), so on an INSTALLED machine this
# launcher hands the distribution's program the home of the account the install
# wizard created rather than the live medium's /home/live. Exporting AFTER the
# drop would publish this fallback over the resolved value -- \`export NAME\`
# copies the SHELL variable, which the drop does not touch.
HOME='/home/live'
export HOME
setuid 1001
# THE RUNTIME DIRECTORY IS THE SESSION'S OWN, NOT THE DISTRIBUTION'S /run.
# This used to say /run, which is 40755 uid 0 on both media: the session could
# read everything wsyswl publishes there and create nothing --
# docs/linux_distro_namespaces.md 8.6, the fourth fault of the family 8.4 and
# 8.5 opened. /run/user/1001 is staged 0700 owned by uid 1001 at boot, by root,
# in the same breath as the mount points (user/linux-syscalls.c,
# distro_stage_runtime), and the names wsyswl publishes in /run are symlinked
# into it -- so this moves the DIRECTORY without moving the socket, which four
# other files name by its /run path.
XDG_RUNTIME_DIR='/run/user/1001'
export XDG_RUNTIME_DIR
WAYLAND_DISPLAY='wayland-0'
export WAYLAND_DISPLAY
# And these two followed /run for the same bad reason -- they were pointed at
# the first directory that existed, not the first one this uid could write.
XDG_CONFIG_HOME='/run/user/1001'
export XDG_CONFIG_HOME
if \$HAMNIX_DE_PROG:
    echo 'rc.de-ns: entering $n to run' \$HAMNIX_DE_PROG
    # THROUGH /etc/de-ns-run, NOT DIRECTLY. A \`.desktop\` file in a
    # distribution names an X11 client, and nothing in the namespace was
    # serving X -- so even a successful \`enter\` produced a program that
    # could not open a display and exited. The shim (etc/de-ns-run.linux,
    # copied into this tree by /etc/rc.distros) starts the distribution's own
    # X session if it has one and otherwise runs the program as it is. Its
    # log is /tmp/de-ns-run.log INSIDE the tree, i.e. /n/$n/tmp/de-ns-run.log
    # from out here -- which is the only place either side can read it.
    enter $n {
        /bin/sh /etc/de-ns-run \$HAMNIX_DE_PROG
    }
    exit \$status
echo 'rc.de-ns: no HAMNIX_DE_PROG set; nothing to launch'
exit 0
RCNS
    chmod 644 "$ROOT/etc/rc.de-ns/$n"
done

# The Wayland server each distribution's GUI clients connect to. wsyswl's
# socket path is an ARGUMENT (docs/linux_distro_namespaces.md §3) -- it never
# had a Debian path in it -- so one instance per distribution, each with its
# socket INSIDE that distribution's tree, is the whole of it: a client whose
# root is that tree finds it at the ordinary /run/wayland-0. Sourced by
# /etc/rc.d/rc.5 after the panel.
{
    echo "# /etc/rc.distros-wl -- GENERATED by scripts/hamlinux_image.sh."
    echo "# One Wayland server per distribution namespace, socket inside its"
    echo "# own tree. See tests/linux/alpine_gui_run.sh, which does this by"
    echo "# hand for one distribution."
    echo "#"
    echo "# And one CLIPBOARD BRIDGE per distribution, for the same reason and"
    echo "# by the same construction: there is one Xwayland per distribution,"
    echo "# an X connection is to one server, and the socket path is an"
    echo "# argument. Both servers run OUT HERE, as root, and reach into the"
    echo "# tree by name -- /srv (where the clipboard segment lives) is"
    echo "# deliberately not carried into a subtree namespace, and the X socket"
    echo "# a client inside sees as /tmp/.X11-unix/X0 is this same inode."
    echo "# They all share the one /dev/snarf, which is what makes it ONE"
    echo "# clipboard across every namespace. See docs/linux_clipboard.md."
    for n in $DISTRO_NAMES; do
        echo "/bin/wsyswl /n/$n/run/wayland-0 > /var/log/wsyswl-$n.log &"
        echo "echo '[rc.5] wayland server for $n'"
        # The X server inside the namespace is started by the SESSION (the
        # first menu launch), not by the boot, so the bridge will not find it
        # for a while. It retries once a second and says so once a minute --
        # which is why it is started here and not from the launch path: it has
        # to be there BEFORE the first X client takes a selection, or the first
        # copy of the session is the one that is lost.
        echo "/bin/xsnarfd /n/$n/tmp/.X11-unix/X0 $n > /var/log/xsnarfd-$n.log &"
        echo "echo '[rc.5] clipboard bridge for $n'"
    done
} > "$ROOT/etc/rc.distros-wl"
chmod 644 "$ROOT/etc/rc.distros-wl"
echo "[image] distribution namespaces: $(echo $DISTRO_NAMES | tr '\n' ' ')"
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
# in with request_module(), and PID 1 here loads modules by absolute path and
# resolves nothing -- there is a modules.dep now, but the kernel's
# request_module() reaches for /sbin/modprobe, which is not what this root
# calls it -- so an autoload would quietly not happen
# and the card would enumerate with no PCM device at all. Loading the codec
# first makes that impossible. virtio_snd rides along so an image booted
# against `-device virtio-sound-pci` finds a card too.
# THE STORAGE DRIVERS A MACHINE THAT IS NOT A VM NEEDS, and why they are not
# optional. Until this line, the only block driver loaded at boot was
# virtio_blk. On the owner's laptop that means PID 1 comes up with NO DISK
# VISIBLE AT ALL: not the USB stick it booted from, not the NVMe it would be
# installed on. `root=` then cannot be resolved by any spelling -- device node,
# PARTUUID or UUID -- because there is nothing to resolve it against, and the
# root switch fails on a machine whose disk is sitting right there.
#
#   nvme         the root of nearly every laptop made since 2016
#   ahci, sd_mod SATA disks and the SCSI disk layer they appear through
#   usb-storage, uas, xhci_pci, ehci_pci
#                THE INSTALL MEDIUM. A USB stick is a SCSI disk behind a USB
#                host controller; without these the installer cannot read the
#                image it is running from once the initramfs hands over.
#   usbhid, hid-generic
#                the keyboard and touchpad of a real machine. virtio_input is
#                QEMU's; a laptop has neither.
#
# THE POINTER OF A LAPTOP, which the line above claimed and did not deliver.
# "the keyboard and touchpad of a real machine" was half true: usbhid drives an
# EXTERNAL USB mouse, and an internal keyboard needs nothing here at all --
# CONFIG_SERIO_I8042 and CONFIG_KEYBOARD_ATKBD are BUILT IN to the Debian
# kernel this image ships (checked in /boot/config-*), so the built-in keyboard
# works with no module. The built-in POINTER is a module in every case, and
# neither kind was staged, so the desktop -- which is driven by a pointer --
# had nothing to move the cursor with on a machine with no USB mouse plugged
# in. Two kinds, because laptops split about evenly between them:
#
#   psmouse      the PS/2 touchpad and trackpoint (Synaptics, ALPS, Elantech
#                and the rest are all built INTO psmouse -- CONFIG_MOUSE_PS2_*
#                are =y inside it -- so this one module covers them).
#   i2c-hid-acpi, hid-multitouch
#                the I2C-HID precision touchpad of a modern machine, and the
#                HID driver that turns its reports into pointer events.
#   i2c-designware-platform, intel-lpss-pci, i2c-i801
#                the BUS that touchpad hangs off. i2c-hid-acpi alone binds
#                nothing: without a controller driver there is no I2C adapter
#                for the ACPI-declared device to be on, which is a silence
#                that looks exactly like an unsupported touchpad.
#
#                i2c-designware-platform IS NOT A MODULE ON THIS KERNEL and
#                the name is kept anyway. CONFIG_I2C_DESIGNWARE_PLATFORM=y in
#                /boot/config-6.12.85+deb13-amd64 and modules.builtin lists it,
#                so the driver is inside vmlinuz: modprobe resolves nothing,
#                the image stages nothing, hamnix-drivers-hw carries 29 modules
#                where the list names 30, and the touchpad works anyway --
#                which is what the owner measured on metal. Naming it here is
#                what makes the packager say "BUILT INTO this kernel" instead
#                of the old "modprobe resolved nothing", and it is the line
#                that will start shipping a .ko the day a kernel makes it =m.
#
# NOT MEASURED ON HARDWARE -- there is no laptop here, and a VM has neither a
# PS/2 touchpad nor an I2C-HID one, so this is the one change in this pass that
# the VM cannot confirm. What IS measured is that it costs nothing to carry:
# the hw package goes 20 -> 29 modules, 1,433,411 -> 1,638,471 bytes gzipped
# against hpm's 4 MiB TARBALL_CAP and 6,778,880 inflated against its 8 MiB
# TAR_CAP, so both ceilings that made these packages get split in the first
# place still have room.
HW_MODULES="nvme ahci sd_mod usb-storage uas xhci_pci ehci_pci usbhid hid-generic psmouse i2c-i801 intel-lpss-pci i2c-designware-platform i2c-hid-acpi hid-multitouch"
#
# --- SOUND ON A MODERN INTEL LAPTOP, WHICH snd-hda-intel DOES NOT DRIVE ------
#
# THE OWNER'S REPORT WAS "Audio does not seem to work", AND HIS OWN BOOT LOG
# NAMES THE REASON:
#
#   snd_hda_intel 0000:00:1f.3: Digital mics found on Skylake+ platform,
#                               using SOF driver
#
# THAT LINE IS A REFUSAL, NOT A SUCCESS, and reading it as "the driver probed,
# so the driver is fine" is the trap this list exists to close. The string
# lives in snd-intel-dspcfg.ko (verified: `xzcat .../sound/hda/
# snd-intel-dspcfg.ko.xz | strings | grep "Digital mics"` -- it is NOT in
# snd-hda-intel.ko), which is the arbiter snd_hda_intel's probe consults
# FIRST. When that arbiter answers SOF, snd_hda_intel returns -ENODEV and
# BINDS NOTHING. The message is printed with snd_hda_intel's dev prefix
# because it is called from snd_hda_intel's probe path, which is exactly why
# it reads like the opposite of what it is.
#
# So on his machine the PCI device is claimed by NOBODY: snd-hda-intel steps
# aside for a Sound Open Firmware stack that WAS NOT IN THIS IMAGE AT ALL.
# There is no card, therefore no /dev/snd/pcmC0D0p, therefore user/
# linux-audio.c's open() of it fails and every program above it correctly
# reports "no audio device". The chain broke at the first link.
#
#   snd-sof-pci-intel-tgl       the PCI probe for Tiger Lake, which is what
#                               his Lenovo 20Y0X50600 (BIOS N32ET93W) is. It
#                               pulls the whole DSP stack behind it: snd-sof,
#                               snd-sof-pci, snd-sof-intel-hda-common,
#                               snd-sof-xtensa-dsp and the rest.
#   snd-sof-intel-hda-generic   the machine driver that turns a DSP with an
#                               HDA codec hanging off it into a CARD with PCM
#                               devices. WITHOUT THIS the DSP boots the
#                               firmware and no /dev/snd node ever appears --
#                               a card that exists to the driver and not to
#                               userland.
#   snd-soc-hdac-hda            the codec half: the analogue jacks and the
#                               speaker amp reached THROUGH the DSP.
#
# NAMING ONLY -tgl IS DELIBERATE AND IT IS NOT NARROW: the dependency closure
# drags in snd-sof-pci-intel-cnl as well, and snd-sof-intel-hda-generic binds
# any Skylake+ part the arbiter hands it. Machines older than Skylake never
# reach this code -- snd-intel-dspcfg answers LEGACY for them and
# snd-hda-intel, which is still in the list below, drives them as before.
# THE TWO DRIVERS DO NOT FIGHT: snd-intel-dspcfg is the single arbiter and
# exactly one of them binds. That is why this is safe to load unconditionally
# on every machine, including this build host, which is a Cannon Lake part
# (8086:a348, subvendor 0x1458) where the arbiter answers LEGACY and
# snd_hda_intel keeps the device.
#
# MEASURED COST, resolved with `modprobe --dry-run --show-depends` against
# /lib/modules/6.12.85+deb13-amd64 and decompressed: the closure is 31
# modules, of which 22 are NEW (the other 9 are snd, snd-pcm, snd-timer,
# snd-hda-core and friends that snd-hda-intel already brought), totalling
# 4,187,913 bytes. On a 4 GiB medium that is noise; against hpm's 8 MiB
# TAR_CAP the `sof` package this creates has room.
#
# NOT MEASURED ON HIS SILICON, and no VM can measure it: QEMU's intel-hda is
# a plain HDA controller with no DSP, so the arbiter answers LEGACY there and
# NONE of these modules bind in any VM on any host. Everything below about
# SOF is reasoned from the kernel's own metadata and from his boot log.
SOF_MODULES="snd-sof-pci-intel-tgl snd-sof-intel-hda-generic snd-soc-hdac-hda"
WANT_MODULES="${HAMLINUX_MODULES:-virtio-gpu virtio_input evdev virtio_net virtio_blk $HW_MODULES ext4 vfat nls_ascii nls_cp437 overlay squashfs loop snd-hda-codec-generic snd-hda-intel virtio_snd $SOF_MODULES}"
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
    # `|| true`, not `|| echo 0`: grep -c already printed the count (it prints
    # "0" and exits 1 when there is none), so `echo 0` appended a SECOND line
    # and split this message across two lines. Cosmetic here -- nothing
    # compares the value -- but the same idiom is a live defect elsewhere.
    echo "[image] staged $(grep -c . "$ROOT/etc/modules" 2>/dev/null || true) kernel modules for $KVER"

    # --- modules AVAILABLE to modprobe but NOT loaded at boot -------------
    # The list above is "what this machine loads before it has a shell".
    # That is not the same question as "what drivers are on the disk for
    # modprobe to reach for", and conflating them is why there was no way to
    # ship a module without also booting it. A driver staged here is on disk
    # and in modules.dep; nothing loads it until somebody types modprobe.
    for m in ${HAMLINUX_MODULES_EXTRA:-}; do
        "$MODPROBE" --dry-run --show-depends -S "$KVER" "$m" 2>/dev/null \
        | awk '/^insmod /{print $2}' | while read -r ko; do
            [ -f "$ko" ] || continue
            rel="${ko#/lib/modules/$KVER/}"
            out="$ROOT/lib/modules/$KVER/${rel%.xz}"
            mkdir -p "$(dirname "$out")"
            [ -f "$out" ] && continue
            case "$ko" in
                *.xz) xz -dc "$ko" > "$out" ;;
                *)    cp -L "$ko" "$out" ;;
            esac
        done
    done
    [ -n "${HAMLINUX_MODULES_EXTRA:-}" ] && \
        echo "[image] staged extra (not boot-loaded): ${HAMLINUX_MODULES_EXTRA}"

    # --- modules ON DISK but deliberately NOT IN THE TABLE ----------------
    # This is the state a machine is in AFTER `hpm install` lands a driver
    # package: the .ko files are there, and modules.dep -- generated when the
    # image was built -- has never heard of them. It is the case the driver
    # packages' install hooks exist to repair, so it has to be constructible
    # or that repair is untestable.
    #
    # It is staged BEFORE depmod runs and then subtracted from the table
    # afterwards, rather than simply copied in later, so the files are exactly
    # what depmod would have described had it been asked -- the test is about
    # the TABLE being incomplete, not about the files being different.
    #
    # This existed only in tests/linux/modprobe_deps.sh, which passed
    # HAMLINUX_MODULES_LATE to this script -- and this script read no such
    # variable, in any commit. So the module was never staged, phase 2's
    # "8021q.ko is on the disk" could not hold, and the gate scored 27/5 the
    # first time it was run outside the worktree that reported 32/0. The gate
    # was measuring a feature that did not exist.
    LATE_KOS=""
    for m in ${HAMLINUX_MODULES_LATE:-}; do
        "$MODPROBE" --dry-run --show-depends -S "$KVER" "$m" 2>/dev/null \
        | awk '/^insmod /{print $2}' | while read -r ko; do
            [ -f "$ko" ] || continue
            rel="${ko#/lib/modules/$KVER/}"
            out="$ROOT/lib/modules/$KVER/${rel%.xz}"
            mkdir -p "$(dirname "$out")"
            [ -f "$out" ] && continue
            case "$ko" in
                *.xz) xz -dc "$ko" > "$out" ;;
                *)    cp -L "$ko" "$out" ;;
            esac
        done
        LATE_KOS="$LATE_KOS $m"
    done
    [ -n "${HAMLINUX_MODULES_LATE:-}" ] && \
        echo "[image] staged late (on disk, WITHHELD from modules.dep):${LATE_KOS}"

    # --- modules.dep, WHICH IS WHAT MAKES modprobe A REAL COMMAND ---------
    # Before this, no modules.dep was generated anywhere on this port
    # (docs/runsweep_unhealthy.md named it as a real gap), so `modprobe NAME`
    # could not resolve a name to a file at all and `insmod /abs/path.ko` --
    # which resolves no dependencies -- was the only thing that worked. On a
    # stock Debian kernel every graphics, filesystem and network driver is a
    # module, so on REAL HARDWARE that is the difference between a working
    # machine and a black screen.
    #
    # The table is the BUILD HOST's `depmod` run over the tree we just staged,
    # which is exactly what a normal distribution does at install time. depmod
    # reads the ELF symbol tables of the .ko files themselves, so it is not
    # taking our word for the dependencies -- and it is run against $ROOT, so
    # the table describes THE MODULES THIS IMAGE ACTUALLY HAS rather than the
    # ~4000 the build host has.
    #
    # Sorted, because depmod emits in hash-table order and an initramfs whose
    # bytes change for no reason defeats every "did the image change?" check.
    #
    # Only modules.dep is kept. depmod also writes modules.alias/.symbols and
    # four .bin indexes; nothing on this port reads them, and a stale binary
    # index that nothing maintains is a thing to be misled by later.
    #
    # ON AN INSTALLED MACHINE: user/hlinstall.ad copies the live root onto the
    # disk, so this file travels with the .ko files it describes -- the same
    # way /etc/modules and the modules themselves do. Modules that arrive
    # LATER, by `hpm install`, are not in it: those packages append their own
    # lines from their install hook (scripts/hamlinux_packages.py,
    # module_install_hook). If neither happened, modprobe says so by name and
    # exits non-zero rather than resolving to nothing.
    DEPMOD=""
    for d in /sbin/depmod /usr/sbin/depmod; do [ -x "$d" ] && DEPMOD="$d" && break; done
    if [ -n "$DEPMOD" ]; then
        # The three "could not open modules.order/.builtin" warnings are
        # expected and harmless: those files describe the BUILD of a kernel
        # tree, and we are describing a staged subset of one.
        "$DEPMOD" -b "$ROOT" "$KVER" 2>/dev/null || true
        DEPF="$ROOT/lib/modules/$KVER/modules.dep"
        if [ -s "$DEPF" ]; then
            sort -o "$DEPF" "$DEPF"
            # WITHHOLD the late modules from the table. depmod has just
            # described every .ko under $ROOT, including the ones staged as
            # "on disk but unknown to modprobe", so the rows it wrote for them
            # are removed here -- leaving precisely the post-`hpm install`
            # state a driver package's hook has to repair. The line is matched
            # by its leading path, so a module whose NAME appears as another
            # module's dependency keeps that mention (which is the point: the
            # dependency is what makes the resolution non-trivial).
            for m in ${HAMLINUX_MODULES_LATE:-}; do
                before=$(grep -c . "$DEPF")
                grep -v "^[^:]*/${m}\.ko:" "$DEPF" > "$DEPF.tmp" && mv "$DEPF.tmp" "$DEPF"
                after=$(grep -c . "$DEPF")
                echo "[image] withheld $m from modules.dep ($before -> $after rows) -- the post-install state"
            done
            rm -f "$ROOT/lib/modules/$KVER"/modules.*.bin \
                  "$ROOT/lib/modules/$KVER"/modules.alias \
                  "$ROOT/lib/modules/$KVER"/modules.symbols \
                  "$ROOT/lib/modules/$KVER"/modules.devname \
                  "$ROOT/lib/modules/$KVER"/modules.softdep \
                  "$ROOT/lib/modules/$KVER"/modules.weakdep
            echo "[image] modules.dep: $(grep -c . "$DEPF") modules, $(wc -c < "$DEPF") bytes — modprobe can resolve by name"
        else
            # Do NOT leave a zero-byte file behind: modprobe would read it,
            # find nothing and report every module missing. An absent file
            # makes it say "cannot read modules.dep", which is the truth.
            rm -f "$DEPF"
            echo "[image] depmod produced no modules.dep — modprobe will refuse by name" >&2
        fi
    else
        echo "[image] no depmod on this host — NO modules.dep; modprobe will refuse" >&2
        echo "[image] (install the kmod package). insmod by path still works." >&2
    fi

    # --- modules.dep.<group>: THE FILE THAT MAKES THE DRIVER PACKAGES ------
    # --- UPGRADABLE ON AN INSTALLED MACHINE -------------------------------
    # This is NOT the table above and it is not read at boot. Each
    # hamnix-drivers-<group> package ships one, and its install hook PREPENDS
    # it to the machine's modules.dep so a refreshed module can still be named
    # by modprobe. Until now the image did not stage it, and that one absence
    # cost the whole update path: scripts/hpm_installed_db.py records a package
    # as installed only when the root carries EVERY file its tarball holds --
    # because hpm upgrades by unlinking the recorded list, and a list naming a
    # file the machine never had is a list that can delete the wrong thing --
    # so hamnix-drivers-base and hamnix-drivers-hw were left OUT of
    # /var/lib/hpm/installed.json, and what is not recorded is never upgraded.
    # An installed machine could not receive a fix to the driver that mounts
    # its root disk, and 1.0.24's nine touchpad and HID modules could reach it
    # only on a freshly built medium.
    #
    # THE BYTES ARE THE PACKAGE'S OWN, not a reconstruction: the same
    # image_module_selection() and the same dep_lines_for_paths() that
    # scripts/hamlinux_packages.py uses to build the tarball produce this copy.
    # There is one definition of which module belongs to which group, so the
    # image cannot stage a table under a name no package owns
    # (tests/linux/channel_covers_image.sh would call that a coverage hole) nor
    # miss one a package holds.
    #
    # NOT `|| true`. A silent failure here restores exactly the defect this
    # exists to close, and it would present as a green image build followed by
    # a machine that cannot update its drivers -- the failure mode that took a
    # release to notice.
    if command -v python3 >/dev/null 2>&1; then
        python3 "$PROJ_ROOT/scripts/hamlinux_packages.py" \
            --stage-dep-tables "$ROOT" || {
            echo "[image] FAILED to stage modules.dep.<group>; hamnix-drivers-*" >&2
            echo "[image] will be left out of the installed database and \`hpm" >&2
            echo "[image] update\` will not be able to upgrade the kernel modules" >&2
            exit 1
        }
    else
        echo "[image] no python3 — NO modules.dep.<group> staged; hamnix-drivers-*" >&2
        echo "[image] cannot be recorded as installed and cannot be updated" >&2
    fi
else
    echo "[image] no modprobe or /lib/modules/$KVER — image will have no drivers" >&2
fi

# --- /lib/firmware: THE HALF OF A DRIVER THAT IS NOT A .ko -----------------
#
# UNTIL THIS BLOCK EXISTED THIS IMAGE STAGED NO FIRMWARE OF ANY KIND. Every
# path above copies `.ko` files and nothing else; `grep -n firmware
# scripts/hamlinux_image.sh` matched NOTHING before this comment (every
# `firmware` in scripts/ was OVMF, i.e. the host's UEFI blob for QEMU). So a
# driver that asks the kernel's firmware loader for a blob got a silent
# -ENOENT on this medium, and the packager already knew better: it has had a
# firmware_files() collector and shipped hamnix-firmware-i915-dmc/-guc and
# hamnix-firmware-nouveau for some time. THE CHANNEL COULD SHIP FIRMWARE THAT
# THE IMAGE ITSELF COULD NOT CARRY.
#
# THAT IS THE SECOND BREAK IN THE OWNER'S AUDIO CHAIN, and it is independent
# of the first: even with $SOF_MODULES staged above, a Sound Open Firmware DSP
# does NOTHING until it is handed a signed boot image and a topology. SOF asks
# for exactly two things at probe time, and the request paths are in the
# driver binary (`xzcat .../snd-sof-pci-intel-tgl.ko.xz | strings` lists
# `intel/sof`, `intel/sof-tplg`, `intel/sof-ipc4/tgl-h` and the rest):
#
#   intel/sof/sof-tgl-h.ri        the DSP BOOT IMAGE for his Tiger Lake part.
#                                 Without it the DSP never runs and the probe
#                                 fails -- no card, no /dev/snd, same symptom
#                                 as no driver at all.
#   intel/sof-tplg/sof-hda-*.tplg the TOPOLOGY: the description of the mixers,
#                                 PCMs and DAI links that BECOMES the card's
#                                 control and PCM devices. A DSP that booted
#                                 and got no topology has no PCM device
#                                 either.
#
# WHAT IS STAGED, AND WHY EACH GLOB IS THAT SHAPE:
#
#   intel/sof/*.ri                all 18 Intel platform boot images, 7,840,064
#                                 bytes. His is one of them; the other 17 are
#                                 what make this fix work on somebody else's
#                                 Skylake..Raptor Lake laptop instead of only
#                                 on his. Several are SYMLINKS into
#                                 intel/sof/intel-signed/ on the build host,
#                                 so this copies with `-L` and lands real
#                                 content at the path the kernel asks for --
#                                 intel-signed/ itself is deliberately NOT
#                                 staged, which would double the bytes for no
#                                 new path.
#   sof-hda-generic*.tplg         13 files, 510,023 bytes: the generic-HDA
#                                 topologies, which is the family a laptop
#                                 with an HDA codec and digital mics asks for,
#                                 across every dmic count (1/2/3/4ch) and the
#                                 idisp (HDMI) variants. The full sof-tplg
#                                 directory is 294 files and 9,563,578 bytes,
#                                 almost all of it topologies for specific
#                                 I2S codecs that no machine here has.
#
# DELIBERATELY NOT STAGED, said out loud rather than quietly omitted:
#
#   intel/sof/*.ldc               1,586,332 bytes of firmware LOG DICTIONARIES
#                                 used only to decode DSP trace output. Sound
#                                 works without them.
#   intel/sof-ipc4/**             THE ONE REAL RESIDUAL RISK IN THIS FIX. The
#                                 6.12 driver can talk IPC3 or IPC4 to a Tiger
#                                 Lake DSP, and which one it defaults to
#                                 decides whether it loads intel/sof/
#                                 sof-tgl-h.ri (staged) or intel/sof-ipc4/
#                                 tgl-h/sof-tgl-h.ri (not staged, 674,268 B,
#                                 plus intel/sof-ipc4-tplg at 5,615,674 B).
#                                 TGL's documented default on this kernel is
#                                 IPC3, which is what is staged -- BUT THAT IS
#                                 READ FROM DOCUMENTATION AND FROM THE DRIVER
#                                 BINARY, NOT MEASURED ON HIS MACHINE, and
#                                 this build host cannot measure it because it
#                                 is a Cannon Lake part that never enters the
#                                 SOF path at all. If his next boot log says
#                                 the firmware request FAILED for an
#                                 intel/sof-ipc4/ path, add that glob here and
#                                 sof-ipc4-tplg with it. His boot log is the
#                                 instrument; there is no other one.
#
# The kernel's firmware loader takes these paths relative to /lib/firmware, so
# the directory layout under $ROOT/lib/firmware must match the host's exactly.
# THE GLOBS ARE ENUMERATED PER PART RATHER THAN WRITTEN `intel/sof/*.ri`, and
# that is hpm's ceiling reaching back into this file: every glob here is owned
# by exactly one package in scripts/hamlinux_packages.py's
# SOF_FIRMWARE_PACKAGES, which parses THIS line, and that file refuses to build
# if the two lists differ in either direction. All 18 blobs in one package
# measured 93 % of hpm's 8 MiB in-RAM TAR_CAP, so they are split by DSP
# generation; the split has to be visible here because this is the list the
# packager reads.
WANT_FIRMWARE="${HAMLINUX_FIRMWARE:-intel/sof/sof-tgl*.ri intel/sof/sof-adl*.ri intel/sof/sof-rpl*.ri intel/sof/sof-ehl.ri intel/sof/sof-icl.ri intel/sof/sof-jsl.ri intel/sof/sof-cml.ri intel/sof/sof-cnl.ri intel/sof/sof-cfl.ri intel/sof/sof-apl.ri intel/sof/sof-glk.ri intel/sof/sof-bdw.ri intel/sof/sof-byt.ri intel/sof/sof-cht.ri intel/sof-tplg/sof-hda-generic*.tplg}"
FW_SRC="${HAMLINUX_FIRMWARE_SRC:-/lib/firmware}"
if [ -d "$FW_SRC" ]; then
    fw_n=0
    fw_b=0
    for pat in $WANT_FIRMWARE; do
        # Unquoted on purpose: the shell must expand the glob against the
        # host's tree. A pattern that matches nothing expands to ITSELF, which
        # the -f test below then rejects -- so a firmware set this host does
        # not have is skipped rather than creating a file named `*.ri`.
        for src in $FW_SRC/$pat; do
            [ -f "$src" ] || continue
            rel="${src#$FW_SRC/}"
            dst="$ROOT/lib/firmware/$rel"
            [ -f "$dst" ] && continue
            mkdir -p "$(dirname "$dst")"
            # -L, not -a: several of these are symlinks into intel-signed/ and
            # the kernel asks for the LINK's path, so the content has to be at
            # that path on a medium that does not carry the target.
            cp -L "$src" "$dst" || continue
            fw_n=$((fw_n + 1))
            fw_b=$((fw_b + $(stat -Lc %s "$src" 2>/dev/null || echo 0)))
        done
    done
    if [ "$fw_n" -gt 0 ]; then
        echo "[image] staged $fw_n firmware files ($fw_b bytes) from $FW_SRC"
    else
        # LOUD, because this is an absence that presents as "audio does not
        # work" three weeks later on somebody else's desk.
        echo "[image] WARNING: staged NO firmware — $FW_SRC has none of:" >&2
        echo "[image]   $WANT_FIRMWARE" >&2
        echo "[image]   (Debian: apt install firmware-sof-signed) — SOF audio" >&2
        echo "[image]   will not work on Skylake+ Intel machines" >&2
    fi
else
    echo "[image] WARNING: no $FW_SRC on this host — NO firmware staged; SOF" >&2
    echo "[image] audio will not work on Skylake+ Intel machines" >&2
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
    # The PARTUUID baked into that unified kernel image's command line.
    # user/hlinstall.ad copies the UKI onto the target's ESP unchanged -- it
    # cannot rewrite a PE section -- so it reads this file and creates the
    # target's root partition WITH that GUID. Without it the installed disk
    # boots looking for a partition that only exists on the build host.
    [ -f build/image/disk/root.partuuid ] \
        && cp build/image/disk/root.partuuid "$ROOT/boot/root.partuuid"
    # THE OTHER SIDE FILE, and without it an installed machine can never change
    # what it boots with. It names the length of the archive inside that UKI and
    # the boot module list that archive holds; user/bootsync.ad refuses to touch
    # the boot image without it, because guessing either number means writing
    # over the initramfs instead of after it. user/hlinstall.ad copies it onto
    # the target's ESP beside BOOTX64.EFI.
    [ -f build/image/disk/UKI.MAP ] \
        && cp build/image/disk/UKI.MAP "$ROOT/boot/UKI.MAP"
    cp -L "$(ls -1 /boot/vmlinuz-* | sort -V | tail -1)" "$ROOT/boot/vmlinuz"
    # The initramfs cannot contain the copy of itself we are about to build,
    # so the PREVIOUS one is staged.  Building twice is what makes the staged
    # copy current: the second build packs the first build's output.
    [ -f "$OUT/initramfs.cpio.gz" ] \
        && cp "$OUT/initramfs.cpio.gz" "$ROOT/boot/initramfs.cpio.gz"
    install -m644 etc/rc.boot.installed "$ROOT/etc/rc.boot.installed"
    BOOT_SZ=$(du -sm "$ROOT/boot" | cut -f1)
    echo "[image] staged the installer's boot files into /boot (${BOOT_SZ}M)"
    # THE BOOT FILES COMPOUND, and the growth is silent until an ESP or a disk
    # will not hold them. build/image/disk/BOOTX64.EFI carries the initramfs
    # that was current when it was built; staging it here puts it INSIDE the
    # next initramfs, whose copy then goes inside the next UKI. Measured on
    # this tree: 36M -> 119M -> 285M over two turns of that loop.
    #
    # The install medium is meant to be built ONCE from a lean image:
    #   scripts/hamlinux_image.sh            (no HAMLINUX_INSTALLER)
    #   scripts/hamlinux_disk.sh             (makes the UKI)
    #   HAMLINUX_INSTALLER=1 scripts/hamlinux_image.sh
    # Going round again feeds the output back in.
    if [ "$BOOT_SZ" -gt 128 ]; then
        echo "[image] WARNING: /boot is ${BOOT_SZ}M. That is the compounding" >&2
        echo "[image]          above: build/image/disk/BOOTX64.EFI already" >&2
        echo "[image]          contains an initramfs that contains a UKI." >&2
        echo "[image]          Reset it with a lean pass:" >&2
        echo "[image]            rm -rf build/image/disk build/image/root/boot" >&2
        echo "[image]            scripts/hamlinux_image.sh && scripts/hamlinux_disk.sh" >&2
    fi

    # --- THE PARTITIONING TOOLS, ON THE MEDIUM ITSELF ---------------------
    # user/hlinstall.ad shells out to sgdisk, mkfs.vfat and mkfs.ext4, and it
    # used to be able to reach them in exactly ONE way: `bind '#distro' /`,
    # the full Debian namespace. On a development host that always works --
    # scripts/hamlinux_vm.sh appends `-drive file=build/image/distro.ext4` to
    # every VM it starts -- so every install ever driven here found them, and
    # HANDOFF.md's end-to-end installer run is true of a VM with two disks.
    #
    # A LAPTOP BOOTED FROM A USB STICK HAS NEITHER. /etc/distros resolves
    # `#distro` to LABEL=hamnix-debian; scripts/hamlinux_disk.sh writes a
    # TWO-partition medium (ESP + root) and gives neither that label. So on
    # the owner's actual configuration the bind failed, sgdisk never ran, and
    # the installer in the Applications menu could not partition a disk.
    #
    # The fix is NOT a copy of Debian: the closure of those three programs is
    # 7.0 MB measured, against 2.0 GB for distro.ext4. It is staged as a
    # directory here and bound as a namespace root by hlinstall, which is a
    # source /etc/distros already documents ("/some/dir, bind-mounted here")
    # and user/linux-syscalls.c already implements (the MS_BIND tail of
    # sys_bind). The mount points are made HERE because that bind is not a
    # `#distro` post, so distro_stage_mountpoints does not run for it.
    INSTROOT="$ROOT/usr/lib/instroot"
    rm -rf "$INSTROOT"
    mkdir -p "$INSTROOT"/usr/sbin "$INSTROOT"/etc "$INSTROOT"/dev \
             "$INSTROOT"/proc "$INSTROOT"/sys "$INSTROOT"/srv \
             "$INSTROOT"/n "$INSTROOT"/tmp
    INST_OK=1
    INST_LIBS=""
    # /usr/sbin AND /sbin, explicitly. These three tools live in sbin and a
    # non-root login often has neither on PATH -- which is exactly what
    # happened the first time this ran: all three lookups missed, the block
    # staged 44K of nothing, and only the "INCOMPLETE" warning below said so.
    # scripts/hamlinux_disk.sh has carried the same `export PATH=...:/usr/sbin:/sbin`
    # since it was written, for the same three programs.
    for t in sgdisk mkfs.vfat mkfs.ext4; do
        p="$(PATH="$PATH:/usr/sbin:/sbin" command -v "$t" 2>/dev/null || true)"
        if [ -z "$p" ]; then
            echo "[image] ERROR: no $t on this build host; the installer on" >&2
            echo "[image]        this medium would not be able to partition." >&2
            INST_OK=0
            continue
        fi
        install -m755 "$(readlink -f "$p")" "$INSTROOT/usr/sbin/$t"
        # The closure, from ldd rather than from a hand-written list: a list
        # goes stale the first time a distribution relinks one of these and
        # the symptom is `sgdisk: error while loading shared libraries`
        # AFTER the target disk has already been zapped.
        INST_LIBS="$INST_LIBS
$(ldd "$p" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /^\//) print $i}')"
    done
    for l in $(printf '%s\n' "$INST_LIBS" | sort -u); do
        [ -f "$l" ] || continue
        mkdir -p "$INSTROOT$(dirname "$l")"
        install -m755 "$(readlink -f "$l")" "$INSTROOT$l"
    done
    # --- AND openssl, WHICH IS WHAT TURNS A TYPED PASSWORD INTO AN ACCOUNT.
    # user/hlinstall.ad::hash_password runs `openssl passwd -6 <plain>` inside
    # this same namespace and puts the result in the target's /etc/shadow. On a
    # DEVELOPMENT HOST that call found openssl because `#distro` is the whole
    # Debian medium. A USB STICK HAS NO SUCH DISK, and this toolbox carried
    # three programs, none of them openssl -- so the hash failed and the
    # account was written with `*`, i.e. LOCKED. MEASURED on a stick-shaped
    # install: "WARNING: could not hash the password", and the installed
    # /etc/shadow line was `hamgateusr:*:20000:...`. The wizard collects a
    # password on its own page and produced a machine nobody could log into.
    #
    # /usr/bin, not /usr/sbin: that is the path hlinstall execs.
    OSSL="$(PATH="$PATH:/usr/bin" command -v openssl 2>/dev/null || true)"
    if [ -z "$OSSL" ]; then
        echo "[image] ERROR: no openssl on this build host; the installer on" >&2
        echo "[image]        this medium could not hash the account password" >&2
        echo "[image]        and would create every account LOCKED." >&2
        INST_OK=0
    else
        mkdir -p "$INSTROOT/usr/bin"
        install -m755 "$(readlink -f "$OSSL")" "$INSTROOT/usr/bin/openssl"
        for l in $(ldd "$OSSL" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /^\//) print $i}' | sort -u); do
            [ -f "$l" ] || continue
            mkdir -p "$INSTROOT$(dirname "$l")"
            install -m755 "$(readlink -f "$l")" "$INSTROOT$l"
        done
        # PROVE IT HASHES, here. A copied openssl with a missing provider is
        # indistinguishable from a working one until an install is half done.
        if ! "$INSTROOT/usr/bin/openssl" passwd -6 hamnix 2>/dev/null | grep -q '^\$6\$'; then
            echo "[image] ERROR: the staged openssl does not produce a \$6\$ hash." >&2
            INST_OK=0
        fi
    fi

    # mkfs.ext4 reads this for its feature defaults. Without it the filesystem
    # is still made, so its absence would be a silent difference rather than
    # an error -- which is the reason to copy it rather than to find out.
    [ -f /etc/mke2fs.conf ] && install -m644 /etc/mke2fs.conf "$INSTROOT/etc/mke2fs.conf"
    if [ "$INST_OK" = 1 ]; then
        # PROVE THE THING RUNS, here, where a build can still fail. A copied
        # binary with a missing library is indistinguishable from a working
        # one until the moment it is asked to erase a disk.
        if ! "$INSTROOT/usr/sbin/sgdisk" --version >/dev/null 2>&1; then
            echo "[image] ERROR: the staged sgdisk does not run on this host." >&2
            INST_OK=0
        fi
    fi
    # AND THE NAME THAT REACHES IT. user/hlinstall.ad binds `#distro/insttools`,
    # and `#distro/<name>` is the ONLY spelling that chroots: sys_bind's
    # plain-path branch bind-mounts and returns 0 WITHOUT entering the tree
    # (enter_root is reached only from the device-server branch), so
    # `bind '/usr/lib/instroot' /` succeeds, changes nothing, and the exec then
    # fails with ENOENT -- measured, and it is why this line exists rather than
    # a bare path in the installer.
    #
    # APPENDED HERE, which is AFTER /etc/rc.distros was generated from this
    # same file a few hundred lines up, and that is deliberate: the generator
    # emits `bind '#distro/<name>' /n/<name>` plus a de-ns-run copy for every
    # name it sees, and the panel grows an Applications section per /n/<name>.
    # A partitioning toolbox is not a distribution somebody enters, so it gets
    # a resolvable NAME (distro_table_lookup reads this file at run time) and
    # no boot-time mount and no menu section.
    printf 'insttools %s\n' /usr/lib/instroot >>"$ROOT/etc/distros"

    # --- THE MARKER THAT MAKES THE INSTALLER VISIBLE AT ALL ---------------
    # WITHOUT THIS FILE THERE IS NO WAY TO START THE INSTALLER FROM THE
    # DESKTOP. etc/hamde/apps/installer.desktop carries X-Hamnix-LiveOnly=true,
    # and all FOUR surfaces that could offer it check for /etc/installer-medium
    # before showing it:
    #
    #   user/hamdesktop.ad     _desk_is_live()  -- the desktop icon
    #   user/hampanelscene.ad  _am_is_live()    -- the panel's fallback menu
    #   user/hamappmenu.ad     _dd_is_live()    -- the Applications menu
    #   user/hamsoftware.ad    _reg_is_live()   -- the software registry
    #
    # (It said THREE until 2026-08-18; hamsoftware.ad is the fourth. And the
    # sentence written into the file below -- "an installed system (which never
    # carries it)" -- was FALSE until the same date: user/hlinstall.ad copies
    # /etc onto the target wholesale, so every installed machine carried this
    # marker and offered to install over itself. Measured by booting one and
    # reading its screen; see tests/linux/installed_offers_install.sh and the
    # removal block in user/hlinstall.ad that makes the sentence true.)
    #
    # That marker is planted by scripts/build_initramfs.py and
    # scripts/build_installer_img.sh -- the HAMNIX-KERNEL installer media --
    # and hamappmenu.ad's own comment says so ("planted in the cpio ONLY by").
    # This script never wrote it. So on a hamnix-linux live USB the installer
    # was on the medium, in /bin, with a launcher in /etc/hamde/apps, and
    # INVISIBLE in every menu that could have started it: boot the stick, get a
    # desktop, and there is no Install Hamnix anywhere.
    #
    # It is written only under HAMLINUX_INSTALLER=1, which is exactly the
    # condition that makes an image an install medium (it is the same flag that
    # stages /boot and the tools above), so an ordinary developer image still
    # correctly reports itself as not-live.
    {
        echo "# /etc/installer-medium -- this root is an INSTALL MEDIUM."
        echo "#"
        echo "# Written by scripts/hamlinux_image.sh under HAMLINUX_INSTALLER=1."
        echo "# Its EXISTENCE is the signal; nothing reads the contents. The"
        echo "# desktop, the panel and the Applications menu each show the"
        echo "# 'Install Hamnix' launcher only when this file is present, so an"
        echo "# installed system (which never carries it) does not offer to"
        echo "# install over itself."
    } >"$ROOT/etc/installer-medium"

    INST_SZ=$(du -sk "$INSTROOT" | cut -f1)
    echo "[image] staged the installer's partitioning tools into" \
         "/usr/lib/instroot (${INST_SZ}K, sgdisk + mkfs.vfat + mkfs.ext4 + openssl)"
    [ "$INST_OK" = 1 ] || echo "[image] WARNING: /usr/lib/instroot is INCOMPLETE" >&2
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
# --- /version -------------------------------------------------------------
# The one-line identity of this system, as a PLAIN FILE AT THE ROOT of the
# initramfs. That is exactly what it is on the Hamnix line
# (scripts/build_initramfs.py: ("/version", b"Hamnix bare-metal kernel, ...")),
# and it is read by user/init.S and user/hello.ad, the smallest end-to-end
# case on the box: open /version, read it, print it. Nothing in this port had
# ever created the name, so that read failed on every run since the port began
# and hello.ad skipped it in silence and exited 0 -- its header's claim to
# "prove the VFS path is reachable" was never tested. The name exists now and
# hello.ad exits non-zero when it cannot read it.
#
# The string is DERIVED, not asserted: the kernel release is the one actually
# staged beside this initramfs, and the userland revision is this checkout.
HL_REV="$(git -C "$PROJ_ROOT" describe --always --dirty 2>/dev/null || echo unknown)"
printf 'hamnix-linux -- Adder userland on Linux %s, initramfs boot (%s)\n' \
    "${KVER:-unknown}" "$HL_REV" > "$ROOT/version"
chmod 644 "$ROOT/version"

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
