#!/usr/bin/env python3
"""scripts/hamlinux_packages.py — build the hamnix-linux hpm channel.

WHY THIS EXISTS
===============
The canonical repository at https://255.one/ ships Hamnix NATIVE binaries.
hpm installs them here perfectly and they do not run: a native Hamnix user ELF
segfaults on Linux.  So hamnix-linux needs its own channel, built through this
lane, with the same package NAMES and the same format -- the difference is the
binaries and the `channel` field, not the shape.

    /etc/hpm/channels on the native line   -> main
    /etc/hpm/channels on the Linux line    -> linux

Two channels, one repository, one hpm.  A machine subscribes to the one that
matches its kernel, and a package name means the same thing on both.

WHAT IT PRODUCES
----------------
    <out>/linux/index.json
    <out>/linux/packages/<name>-<version>.tar.gz

which is exactly the static tree docs/packages.md describes, so it can be
served by anything -- `file://` for a local test, an HTTP server for a VM, or
uploaded under 255.one/linux/ for real.

Each per-command package holds one binary and depends on hamnix-init, which
carries the boot files.  Two metapackages tie it together: hamnix-coreutils
(every command) and hamnix-base (the components + coreutils + the desktop),
so `hpm install hamnix-base` resolves the whole distribution.

Usage:
    scripts/hamlinux_packages.py [--out build/repo] [--version 1.0.0]
                                 [--channel linux] [--base-url https://255.one/]
                                 [--no-desktop-gate]

Before it writes the index it UNPACKS THE TARBALLS IT JUST WROTE AND RUNS THEM
(tests/linux/channel_runs_desktop.sh): the desktop under a synthetic mouse, the
shell, hpm, the coreutils.  A channel whose binaries do not work gets no index
and therefore installs nowhere.  --no-desktop-gate skips it, loudly.

There is NO --sign here, though this line used to advertise one. Signing is a
separate step over the finished index, because the key does not live in the
tree and must not be reachable from a build:

    python3 scripts/hpm_sign.py sign <out>/index.json \\
        ~/.hamnix_keys/repo.sec <out>/index.json.sig
"""

import argparse
import glob
import gzip
import hashlib
import json
import lzma
import math
import os
import re
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# scripts/ on the path so `--installed-db` can import hpm_installed_db however
# this script was invoked (by path, from another directory, or as a module).
sys.path.insert(0, os.path.join(ROOT, "scripts"))

# The commands that go in the channel, grouped the way the packages are.
# Anything that builds through the lane can be added; these are the ones the
# image already ships and therefore the ones known to RUN, not merely link.
COREUTILS = """
    ls cat echo cp mv rm mkdir ln touch pwd
    grep sed sort uniq head tail wc cut tr
    find du df stat tree
    date sleep true false yes seq basename dirname
    env_show printenv id hostname uname
    ps kill
    tar gzip base64 cksum md5sum
    more less bc cal
    ascii awk cmp column comm diff
""".split()
# `install` IS NOT install(1) IN THIS TREE, AND THIS COMMENT USED TO SAY IT
# WAS. What stood here was:
#
#     "`install` (install(1), the file-copy-with-modes tool) is NOT in the
#      list above even though it belongs there by nature ... It rides in
#      SYS_CMDS instead"
#
# There is no install(1) in this tree. `install` in SYS_CMDS built
# user/install.ad -- the NATIVE line's system installer, a different program
# from user/hlinstall.ad -- and shipped it as /bin/install, which is the path
# the image stages hlinstall at and the path user/haminstallui.ad spawns.
# MEASURED on the built 1.0.26 channel and on the tarball fetched from
# 255.one: image /bin/install is 274,840 bytes and byte-identical to
# /bin/hlinstall; hamnix-install's bin/install was 338,432 bytes and
# byte-identical to a fresh build of user/install.ad. Two different installers
# under one path, one on the medium and the other in the channel.
# tests/linux/channel_bytes_match_image.sh is the gate that found it, on its
# first run, and it is the only thing in the tree that could have: the name
# gate next door sees `bin/install` on both sides and says covered.
#
# So bin/install is now hlinstall's bytes, by the same aliasing the image uses
# (`install -m755 $ROOT/bin/hlinstall $ROOT/bin/install`): the (source, path)
# pair below builds user/hlinstall.ad and lays it down at bin/install, so the
# two copies cannot drift apart again -- they are one compile.

# THE SAME SPLIT THE NATIVE LINE ALREADY MADE, and it is copied deliberately
# rather than re-derived. This file's own header says the two channels carry
# "the same package NAMES and the same format -- the difference is the binaries
# and the `channel` field", so a name cannot mean two different sets of
# programs depending on which kernel you booted. scripts/build_packages.py's
# _files_net carries ifconfig, ping, route, httpd, curl, wget, ssh, host, ntpd
# and httpd_worker; its _files_svc_sshd carries sshd plus the service
# definition, "decoupled from the base because a headless embedded board can
# opt out of remote login".
#
# ssh, httpd and httpd_worker were in NEITHER list here and in no image, so a
# PRE-AUTHENTICATION bounds fix in sshd and the 431/413 fix in httpd shipped
# nowhere. That is NORTH_STAR.md's invariant failing, and it failed silently:
# nothing named the four programs, so nothing could miss them.
#
# ssh is a CLIENT, and it is here because it WORKS -- measured, not assumed:
# the packaged ssh and the packaged sshd complete a whole SSH-2 session
# against each other (key exchange, host key signature verified, encryption
# active, password USERAUTH accepted, session channel opened, hamsh spawned
# and bridged, clean disconnect).
#
# httpd AND httpd_worker ARE DELIBERATELY NOT HERE, AND THAT IS A MEASUREMENT
# RATHER THAN AN OVERSIGHT. On this line httpd cannot serve a single request.
# Traced, with both programs out of a built channel: the master announces,
# accepts (`accept(5) = 6`) and spawns `/bin/httpd_worker 3 /www`; the worker
# attaches THE SAME /srv/net segment as the master and then calls
# `exit_group(0)` 200 microseconds later, having read nothing, written
# nothing, and never opened the connection's data file. It did not take its
# own error path either -- that writes "could not open connection data" and
# exits 1 -- so it reached serve(), read zero bytes, treated the request as
# empty and returned. Every request is answered with silence.
#
# THE MECHANISM IS STRUCTURAL, not a bug in either program: user/linux-net.c
# keeps the connection table in shared memory but a record's `fd` is a
# PER-PROCESS descriptor, so a worker handed a connection NUMBER cannot reach
# the socket the master accepted. On the native kernel /net is a kernel device
# and the number is global, which is why the same source works there.
# user/linux-syscalls.c already records the symptom in its own words -- "why
# user/httpd.ad could not serve one request here" -- and fixed a different
# half of it (the spawned worker losing HAM* out of its environment).
#
# So packaging them would put a web server on every machine that installs
# hamnix-base and answers nothing, forever, silently. That is the same call
# scripts/hamlinux_image.sh already makes about initctl and telinit -- they
# reach PID 1 through a node this line does not serve, so they are not
# shipped -- and for the same reason: a command that cannot work is the
# success-shaped answer this tree exists to avoid.
#
# WHAT THIS COSTS, said out loud: the 431/413 fix in user/httpd_worker.ad is
# in the tree and reaches nobody. It is the right fix and it is not the
# blocker. The blocker is above; when a worker can reach the accepted
# connection, both names go in this list and the entry in CHANGELOG.md stops
# being about a program nobody has.
NET_CMDS = ("ifconfig route ping host curl wget dhcpc ntpd "
            "ssh").split()

# sshd is NOT in the list above, and that is the deliberate half. It LISTENS,
# and it accepts bytes from anyone who can reach the port before any
# authentication has happened -- the very code path the bounds fix is about.
# A package that arrives because somebody asked for a desktop must not open a
# port; `hpm install hamnix-svc-sshd` is a person deciding. Same reasoning as
# the native line's, and the same package NAME.
SVC_SSHD_CMDS = ["sshd"]

# The /dev/audio clients. They are thin Plan 9 clients of the device served by
# user/linux-audio.c and know nothing about ALSA. They are packaged SEPARATELY
# rather than folded into the base command set because they are only useful on
# a machine that has a sound card, and because leaving them out of the channel
# entirely -- which is what happened when audio first landed -- means an
# installed machine that runs `hpm update` gets the audio DEVICE (it is
# compiled into the runtime of every binary) and none of the programs that can
# drive it. The gap was silent: nothing failed, there was simply no way to
# play a sound.
AUDIO_CMDS = "playtone aplay arecord".split()

# Identity. These three are the whole reason /dev/auth exists: they change
# who you are, and none of them ever sees a password hash. Packaged together
# because a machine that can log in but cannot change a password is not a
# system you can administer.
AUTH_CMDS = "login su passwd whoami".split()

# Kernel modules. On a stock Debian kernel every graphics, filesystem and
# network driver is a module, so on real hardware these are the difference
# between a working machine and a black screen -- see the GPU packages below,
# which install .ko files these programs are the only way to load.
MOD_CMDS = "insmod lsmod modprobe rmmod".split()

# Bringing a machine up and putting a system on it: the installer (CLI and
# the GUI wizard), the namespace launcher, and reboot.
# `halt` and `poweroff` were in the IMAGE and not in the CHANNEL, which meant
# an installed machine could never receive a fix to the two commands that turn
# it off. Same silent shape as the audio note above: nothing failed at build
# time, the programs simply were not there to update.
#
# bootlogd is here for a reason that is the same shape and sharper. It is the
# program that writes \HAMNIX.LOG onto the boot medium's FAT partition, which is
# what turns a failed boot on a machine with no serial cable from a photograph
# of the last forty lines into a file the owner can carry to another computer.
# A bug in THAT is the one bug a person cannot report, because the thing that
# would have reported it is the thing that is broken -- so of everything in the
# image it is among the most important to be able to fix remotely.
#
# bootsync is here for the sharpest version of the same argument. It is the ONLY
# thing on an installed machine that can change what that machine BOOTS: it
# writes the current bytes of the boot modules into a reservation inside
# /boot/EFI/BOOT/BOOTX64.EFI, because user/linuxinit.ad loads /etc/modules
# before the root switch and everything `hpm update` lands on the ext4 root is
# therefore invisible to the next boot. A machine whose bootsync is broken
# cannot receive a fix for it through the one path that would matter -- the boot
# -- so it must be in the channel, and `hpm update` calls it
# (user/hpm.ad:_sync_boot_image), which means an upgrade of THIS package
# replaces the very program the transaction is about to run. That is safe for
# the reason hamnix-init's hook exists: the running binary is replaced on disk
# and the CURRENT process keeps its own image, and bootsync is spawned after all
# the file movement is finished.
SYS_CMDS = ("hlinstall haminstallui nsrun reboot halt poweroff "
            "bootlogd bootsync").split()
# bin/install, built from user/hlinstall.ad. See the block above line 86 for
# what it was and what that cost; the image does the same thing with `install
# -m755 $ROOT/bin/hlinstall $ROOT/bin/install`.
SYS_ALIASES = [("hlinstall", "bin/install")]

# xsnarfd is the X clipboard bridge and hamimgscene is the image viewer. Both
# ship in the image; neither was in the channel until the coverage gate below
# was written and named them.
# hamappmenu is the Applications menu the panel's Applications button spawns
# (hampanelscene _launch_appmenu). It was in neither this list nor the image's
# APPS, so `_appmenu_available()` returned 0 on every installed machine and
# the categorised menu shipped nowhere -- the exact shape NORTH_STAR.md calls
# the project's worst bug. Both lists are needed: the image's APPS puts it in
# /bin, this one puts it in a package so `hpm update` can ever fix it.
DESKTOP_CMDS = ("wsysd wsyswl xbridge hamdesktop hampanelscene hamtermscene "
                "hameditscene hamsettings hamfm hamUI hamUId xsnarfd "
                "hamimgscene hamappmenu hamgreet").split()


# --------------------------------------------------------------------------
# The files that are not programs
# --------------------------------------------------------------------------
# THE GATE LOOKED AT /bin AND NOTHING ELSE, AND SO DID EVERYONE READING IT.
# Measured on the published 1.0.12 channel: 154 files were in the staged image
# root and in no package. TWO of them were /bin binaries -- the two the gate
# checked, both already justified by name. The other 152 were in directories
# nothing had ever compared: 34 kernel modules (ext4, jbd2, vfat, the nls
# tables, virtio_blk, virtio_net, virtio_input, evdev, overlay, squashfs,
# loop, and the whole snd-hda stack), the dependency table modprobe was just
# made to depend on, the 21 manual pages `man` and `help` read, the 23 Adder
# runtime sources without which the on-box compiler cannot LINK, /etc/skel
# (every desktop launcher a new account gets), /etc/users/*.ns, ten static
# /etc files including /etc/profile and /etc/os-release, the sound aplay
# plays, and /init itself -- the program the kernel executes on an installed
# machine.
#
# Same shape as every earlier one: the image had them because the image is
# built from the tree, `hpm update` could never refresh them, and nothing
# failed. tests/linux/channel_covers_image.sh now walks the WHOLE image root,
# so the lists below are checked rather than believed.

def tree_files(reldir, install_prefix):
    """Every file under `reldir` (repo-relative), as extras entries that
    install under `install_prefix`. Directories are recreated by hpm from the
    file paths, so nothing here has to name one."""
    out = []
    base = os.path.join(ROOT, reldir)
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames.sort()
        for fn in sorted(filenames):
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, base)
            out.append((os.path.relpath(full, ROOT),
                        "%s/%s" % (install_prefix, rel)))
    return out


def glob_files(patterns, install_prefix):
    """Extras entries for repo-relative globs, installed flat under
    `install_prefix` by basename -- the way scripts/hamlinux_image.sh stages
    them (`install -m644 user/linux-*.c "$ROOT/usr/share/adder/"`)."""
    out, seen = [], set()
    for pat in patterns:
        for host in sorted(glob.glob(os.path.join(ROOT, pat))):
            if not os.path.isfile(host):
                continue
            rel = os.path.relpath(host, ROOT)
            inside = "%s/%s" % (install_prefix, os.path.basename(host))
            if inside in seen:
                continue
            seen.add(inside)
            out.append((rel, inside))
    return out


# The Adder runtime, as SOURCE. /bin/ac compiles a .ad on the box and then has
# to LINK it, and scripts/ac-link.sh discovers the object list from whatever is
# present in /usr/share/adder -- so without these files `ac hello.ad` gets
# through the compiler and dies at the linker with undefined symbols. The image
# stages them (hamlinux_image.sh, beside host_ac); no package carried them, so
# an installed machine could never receive a fix to the runtime its own
# compiler links against.
ADDER_SHARE = glob_files(
    ["user/linux-runtime.S", "user/linux-*.c", "user/linux-*.h",
     "user/syscall_nums.h", "scripts/adder_llvm_runtime.c",
     "scripts/ac-link.sh", "tests/linux/hello.ad"],
    "usr/share/adder")

# THE ADDER COMPILER ITSELF. /bin/ac is a DRIVER, not a compiler: it execs
# /bin/host_ac to turn foo.ad into LLVM IR and then runs the link recipe in the
# Debian namespace (user/ac.ad's header, and the hard-coded "/bin/host_ac" in
# its spawn). So a machine with `ac` and no `host_ac` has no compiler at all.
#
# THIS PACKAGE SHIPPED WITHOUT IT, AND THE CHANNEL SHOWS IT. Measured against
# the published channel at https://255.one/linux/ on 2026-08-11:
# hamnix-adder-1.0.12.tar.gz (sha256 d22ce377e5bd..., 79974 B, the bytes the
# index advertises) contains exactly two entries -- PKGINFO and files/bin/ac.
# A machine installed from that channel therefore gets the driver and neither
# the compiler nor the runtime sources, and `ac hello.ad` on it answers:
#
#     ac: cannot run /bin/host_ac
#     ac: hello.ad: the Adder compiler could not translate this program
#
# (exit 10, no binary written -- measured, tests/linux/channel_compiles_adder.sh).
# HANDOFF.md §0 lists "compiles Adder on the box" as a measured capability of
# this distribution; for an INSTALLED machine it was not true.
#
# WHY IT IS SAFE TO SHIP, against the reason it was excluded for. The exclusion
# in tests/linux/channel_covers_image.sh said host_ac was "linked against a
# libc that is not necessarily its own". That is backwards, and readelf says so:
#
#     host_ac: no .dynamic section, no INTERP -- "not a dynamic executable"
#     ac:      NEEDED libssl.so.3, libcrypto.so.3, libcrypt.so.1, libc.so.6
#
# host_ac is the ONE binary in /bin that depends on no libc at all; `ac`, which
# was packaged the whole time, is the one that carries the host-libc coupling.
# scripts/hamlinux_image.sh says the same thing where it stages the file:
# "host_ac is ALREADY a static Linux ELF, so it is just another /bin binary."
#
# It is an `extras` entry rather than a `bins` entry because it is not built
# from a user/<cmd>.ad by build_one(): host_ac cannot emit a host-Linux binary,
# so it is a first-class FILE in the tree (built by the Python seed into
# build/cutover/) rather than a build product of this script. write_pkg chmods
# anything installed under bin/ to 0755, so it lands executable.
ADDER_COMPILER = [("build/cutover/host_ac.elf", "bin/host_ac")]

# ---------------------------------------------------------------------------
# EXTRAS THAT MAY LEGITIMATELY BE ABSENT -- and nothing else may be.
# ---------------------------------------------------------------------------
# A named `extras` source that is not in the tree is a file a package PROMISES
# and does not carry, and until now it was recorded in `skipped` and packaged
# anyway. That is how hamnix-adder came out of this script with `ac` and no
# `host_ac`: the package was present, its hash matched, and the machine that
# installed it had a compiler driver with no compiler. The toolchain gate at
# the end caught it four minutes later -- which is the gate working -- but the
# fact was knowable at copy time, and every other refusal in this file was
# learned by shipping the failure once.
#
# So a missing extra is now a REFUSAL. If a source may genuinely be absent, it
# needs an entry here WITH A REASON, because "sometimes it is not there" is
# exactly the sentence that hid the missing compiler.
#
# Keys are the repo-relative source path as written in the component's extras
# list; values are why absence is acceptable. Empty today, deliberately: every
# extras entry in this file is either a literal path that is always in the tree
# or comes from glob_files()/tree_files(), which only ever name files they have
# already found on disk.
EXTRAS_MAY_BE_ABSENT = {}


# The manual pages. hamsh's `man` and `help` read /usr/share/man/*.md (see
# user/hamsh.ad's discovery index, which walks that directory). The image
# stages etc/man/*.md there; nothing shipped them, so `man ls` on an installed
# machine was frozen at whatever the install medium happened to carry.
MAN_PAGES = glob_files(["etc/man/*.md"], "usr/share/man")

# /etc/skel -- the skeleton a new account is given: the Desktop launchers
# hamdesktop draws, and the starter documents. It belongs with the desktop,
# because the launchers name the desktop's own programs. /home/live is NOT
# shipped: see the exclusion list in tests/linux/channel_covers_image.sh.
SKEL_FILES = tree_files("etc/skel", "etc/skel")

# --------------------------------------------------------------------------
# /etc/hamde/apps -- THE APPLICATIONS MENU'S DATA, AND THE PROGRAMS IT NAMES
# --------------------------------------------------------------------------
# Every menu in this desktop (hamappmenu's Brisk menu, hampanelscene's
# dropdown, hamde) is data-driven from these *.desktop launchers. Until this
# block, NO PACKAGE CARRIED THEM AT ALL and the image did not stage them
# either, so every machine ran on its menu's compiled-in fallback list -- a
# list naming programs the image does not build. See
# tests/linux/de_appmenu_installed.sh.
#
# ONE PACKAGE PER APPLICATION, CARRYING THE LAUNCHER AND THE PROGRAM TOGETHER.
# That pairing is the whole point, and it is structural rather than a rule
# somebody has to remember: the defect this is fixing is exactly a launcher
# and its program being in different places and one of them being missing.
# With them in one package, a machine cannot have the row without the program
# it launches, and `hpm remove` cannot leave the row behind.
#
# It is also what the sizes force, which is worth recording rather than
# discovering again. Putting all 23 into hamnix-desktop produced a package
# hpm CANNOT INSTALL and hamlinux_packages refused to publish it -- 7,431,064
# B gzipped against TARBALL_CAP 4 MiB and 16,220,160 B inflated against
# TAR_CAP 8 MiB (user/hpm.ad unpacks entirely in RAM through two fixed
# arrays). The refusal is the same shape as every other one in this file: a
# repository that offers an uninstallable package is a lie. One package per
# app is the same answer the coreutils already use, and `hamnix-apps` is the
# metapackage that pulls the set in, exactly as `hamnix-coreutils` does.
#
# apps-optional/ is NOT here: each of those launchers ships with the optional
# package that carries its program (scripts/build_packages.py) -- the same
# invariant, arrived at independently.
#
# THREE LAUNCHERS ARE NOT IN THIS TABLE, because their programs already ship
# in another package and the pairing rule sends the launcher after the
# program, not the other way round:
#   terminal.desktop  -> hamtermscene, editor.desktop -> hameditscene, both
#                        in hamnix-desktop (they are the DE's own chrome apps)
#   installer.desktop -> haminstallui, in hamnix-install
# They are named in those components' extras below.
DESKTOP_APP_HOMES = {          # launcher -> the package that already has its program
    "terminal.desktop":  "hamnix-desktop",
    "editor.desktop":    "hamnix-desktop",
    "installer.desktop": "hamnix-install",
}


def desktop_apps():
    """[(cmd, launcher-basename, Name, Comment)] for every launcher whose
    program needs a package of its own. Derived from the FILES, so adding an
    application is still dropping a .desktop file."""
    out = []
    d = os.path.join(ROOT, "etc/hamde/apps")
    for fn in sorted(os.listdir(d)):
        if not fn.endswith(".desktop") or fn in DESKTOP_APP_HOMES:
            continue
        name = comment = ""
        prog = None
        for line in open(os.path.join(d, fn)):
            line = line.rstrip("\n")
            if line.startswith("Exec=") and prog is None:
                prog = line[5:].split()[0]
            elif line.startswith("Name=") and not name:
                name = line[5:]
            elif line.startswith("Comment=") and not comment:
                comment = line[8:]
        if prog:
            out.append((os.path.basename(prog), fn, name or fn, comment))
    return out


def launchers_for(pkg):
    """Launcher entries this component owns outright (see DESKTOP_APP_HOMES)."""
    return [("etc/hamde/apps/" + f, "etc/hamde/apps/" + f)
            for f, home in sorted(DESKTOP_APP_HOMES.items()) if home == pkg]

# --------------------------------------------------------------------------
# Component packages: name -> (description, [binaries], [extra files as
# (source-path-in-repo, install-path)], [depends])
COMPONENTS = {
    "hamnix-init": (
        "hamnix-linux init (the Adder PID 1) and the boot rc scripts",
        [("linuxinit", "bin/linuxinit")],
        # /etc/rc.boot IS STILL SHIPPED, BUT IT IS NO LONGER THE LIVE RC --
        # it is the one-line etc/rc.boot.machine, and it is here for exactly
        # one reason: the TRANSITION. Both of the earlier shapes were measured
        # on a real installed disk by tests/linux/installed_update.sh:
        #
        #   * SHIPPING etc/rc.boot.linux AS /etc/rc.boot (what this was). On
        #     the live image that is the same bytes twice and invisible. On an
        #     INSTALLED machine `hpm install` replaced the boot script of the
        #     running system with the initramfs one -- measured: after the
        #     install the machine's /etc/rc.boot began "# /etc/rc.boot.linux
        #     -- the bootstrap rc for the Linux line".
        #
        #   * SHIPPING IT UNDER ITS OWN NAME ONLY deleted it. An upgrade
        #     removes the files the OLD version owned before laying the new
        #     one down, and 1.0.7 owns etc/rc.boot. Measured, with exactly
        #     that change in place: after `hpm update` on the installed disk,
        #     `ls -l /etc/rc.boot` answered "ls: open failed: /etc/rc.boot".
        #     The machine had no boot script at all -- a brick, not a smaller
        #     fault.
        #
        # THE FIX IS IN hpm, NOT HERE. user/hpm.ad:_is_machine_owned makes
        # etc/rc.boot a path hpm never overwrites and never deletes; it writes
        # it only when ABSENT. A machine running that hpm keeps its own rc
        # through any install or update, and this list cannot hurt it.
        #
        # WHICH LEAVES THE MACHINES ALREADY OUT THERE. The hpm that deletes
        # your boot script is the one ALREADY ON THE MACHINE when you type the
        # command -- an installed 1.0.7/1.0.8 box runs 1.0.7's hpm, which
        # knows none of this and WILL remove etc/rc.boot on the hamnix-init
        # upgrade. The only thing that can put a working rc back on such a
        # machine is the package it is upgrading TO. So this release ships
        # one, and ships the RIGHT one: the one-line
        # `source '/etc/rc.boot.installed'`, which leaves that machine booting
        # the real installed rc (also in this package) instead of the
        # initramfs one it used to be given.
        #
        # It is safe on every other machine because of the hpm rule above: a
        # live image or a machine that already has an rc keeps the one it has.
        # This entry may be dropped once no machine running a pre-fix hpm is
        # expected to update -- and dropping it earlier re-creates the brick.
        [("etc/rc.boot.machine", "etc/rc.boot"),
         ("etc/rc.boot.machine", "etc/rc.boot.machine"),
         ("etc/rc.boot.linux", "etc/rc.boot.linux"),
         ("etc/rc.boot.installed", "etc/rc.boot.installed"),
         ("etc/rc.d/rc.5.linux", "etc/rc.d/rc.5"),
         ("etc/rc.de-user.linux", "etc/rc.de-user"),
         ("etc/passwd", "etc/passwd"),
         ("etc/group", "etc/group"),
         ("etc/hostname", "etc/hostname"),
         ("etc/hosts", "etc/hosts"),
         # The rest of the static /etc the image stages (hamlinux_image.sh's
         # `for f in hostname hosts passwd group issue motd ... host.conf`).
         # Every one of these was in the image and in no package: a fix to
         # /etc/profile, to the network databases, or to what /etc/os-release
         # calls this system could never reach an installed machine.
         # THESE ARE SHIPPED FILES, NOT CONFFILES. hpm has one rule for a
         # file a machine may have edited -- _is_machine_owned, which today
         # names etc/rc.boot alone -- so an update REPLACES each of these.
         # That is the right trade for files whose content is the
         # distribution's answer rather than the operator's (what
         # /etc/os-release calls this system, the port numbers in
         # /etc/services), and it is the wrong one for a file an operator is
         # invited to edit -- which is why /etc/distros is excluded rather
         # than shipped. If /etc/profile ever becomes a file people edit, it
         # belongs in _is_machine_owned, not in a list here.
         #
         # NOT here, deliberately, and each named with its reason in
         # tests/linux/channel_covers_image.sh: etc/shadow (the machine's own
         # password hashes), etc/resolv.conf (dhcpc writes it), etc/hpm/
         # *.pub (the trust roots that authenticate this very channel) and
         # etc/distros + everything generated from it.
         ("etc/issue", "etc/issue"),
         ("etc/motd", "etc/motd"),
         ("etc/os-release", "etc/os-release"),
         ("etc/lsb-release", "etc/lsb-release"),
         ("etc/debian_version", "etc/debian_version"),
         ("etc/profile", "etc/profile"),
         ("etc/services", "etc/services"),
         ("etc/protocols", "etc/protocols"),
         ("etc/networks", "etc/networks"),
         ("etc/host.conf", "etc/host.conf"),
         # The per-user namespace recipes hamsh sources for a regular-user
         # shell (/etc/users/<user>.ns, falling back to default.ns).
         ("etc/users/default.ns", "etc/users/default.ns"),
         ("etc/users/live.ns.linux", "etc/users/live.ns")],
        []),
    "hamnix-hamsh": (
        "hamnix-linux shell -- /bin/hamsh",
        [("hamsh", "bin/hamsh")], [], ["hamnix-init>=1"]),
    "hamnix-net": (
        "hamnix-linux networking userland -- ifconfig, route, ping, host, "
        "curl, wget and the ssh client",
        [(c, "bin/" + c) for c in NET_CMDS], [], ["hamnix-init>=1"]),
    "hamnix-svc-sshd": (
        "the hamnix SSH-2 server (curve25519-sha256 + chacha20-poly1305): "
        "/bin/sshd and the service definition hamsh's `svc` builtin reads. "
        "SEPARATE FROM hamnix-base ON PURPOSE -- installing it is how a "
        "person opens port 22, and nothing starts it for them: after "
        "`hpm install hamnix-svc-sshd`, `svc start sshd`.",
        [(c, "bin/" + c) for c in SVC_SSHD_CMDS],
        # The definition travels WITH the binary it names. Shipping one
        # without the other gives either a server nothing can start or a
        # service definition whose exec does not exist -- and the second is
        # worse, because `svc start sshd` then fails at spawn time with the
        # machine looking correctly configured.
        [("etc/svc/sshd.hamsh", "etc/svc/sshd.hamsh")],
        # hamnix-net, because sshd is the server half of a networking
        # userland and the client half is where `ssh` lives -- the same
        # dependency the native line declares.
        ["hamnix-init>=1", "hamnix-net>=1"]),
    "hpm": (
        "Hamnix package manager (hpm), built for the Linux line",
        [("hpm", "bin/hpm")],
        # THE LINUX CHANNEL'S FILE, NOT THE NATIVE ONE. This line used to read
        # ("etc/hpm/channels", "etc/hpm/channels") -- and etc/hpm/channels is
        # the NATIVE line's subscription list, whose single entry is `main`.
        # scripts/hamlinux_image.sh stages etc/hpm/channels.LINUX (whose entry
        # is `linux`) at that path for exactly the reason the header of this
        # file gives: main holds Hamnix NATIVE binaries and linux holds the
        # same userland built against the Linux kernel.
        #
        # So `hpm install hamnix-base` -- the flagship package, which declares
        # hpm>=1 -- REWROTE the machine's subscription to `main`, and every
        # `hpm refresh` and `hpm update` after it went to
        # https://255.one/main/, found no index.json.sig there, and aborted:
        #
        #   hpm: fetching channel main from https://255.one/main/
        #   hpm: https://255.one/main/index.json.sig: HTTP 404, not 200 OK
        #   hpm: refresh: aborting - untrusted index for channel main
        #
        # A machine that installed this distribution was cut off from its own
        # repository by the act of installing from it, permanently, and
        # nothing said so. Measured on a real installed disk by
        # tests/linux/installed_update_modules.sh, which is where it surfaced.
        # tests/linux/channel_covers_image.sh compared NAMES; both files are
        # called etc/hpm/channels, so it saw nothing -- the "right NAMES are
        # not the right BYTES" shape NORTH_STAR.md already names. That gate now
        # compares the BYTES of every /etc file a package and the image share.
        [("etc/hpm/channels.linux", "etc/hpm/channels")],
        ["hamnix-init>=1"]),
    "hamnix-auth": (
        "identity -- login, su, passwd, whoami; clients of /dev/auth",
        [(c, "bin/" + c) for c in AUTH_CMDS], [], ["hamnix-init>=1"]),
    "hamnix-modules": (
        "kernel module tools -- insmod, lsmod, modprobe, rmmod",
        [(c, "bin/" + c) for c in MOD_CMDS], [], ["hamnix-init>=1"]),
    "hamnix-install": (
        "installer and system tools -- hlinstall, haminstallui, nsrun, reboot",
        [(c, "bin/" + c) for c in SYS_CMDS] + SYS_ALIASES,
        launchers_for("hamnix-install"), ["hamnix-init>=1"]),
    "hamnix-adder": (
        "the Adder toolchain -- `ac foo.ad -o foo` on the box: the driver "
        "(/bin/ac), the compiler it execs (/bin/host_ac, static), and the "
        "runtime sources in /usr/share/adder that ac-link.sh links against",
        [("ac", "bin/ac")], ADDER_COMPILER + ADDER_SHARE, ["hamnix-init>=1"]),
    "hamnix-audio": (
        "hamnix-linux audio userland -- playtone, aplay, arecord, clients of "
        "/dev/audio, and /usr/share/sounds/test.wav to play",
        [(c, "bin/" + c) for c in AUDIO_CMDS], [], ["hamnix-init>=1"]),
    "hamnix-man": (
        "the manual pages -- /usr/share/man/*.md, which hamsh's `man` and "
        "`help` read. Without them `help` reports its own index missing.",
        [], MAN_PAGES, ["hamnix-init>=1"]),
    "hamnix-desktop": (
        "hamnix-linux desktop -- the scene compositor, the DE clients, and "
        "/etc/skel (the launchers and starter documents a new account gets)",
        [(c, "bin/" + c) for c in DESKTOP_CMDS],
        [("etc/panel.conf", "etc/panel.conf"),
         ("etc/desktop.icons", "etc/desktop.icons"),
         # The shim the application menu runs a distribution's program
         # through, so a .desktop file in Debian or Alpine gets a display to
         # draw on. /etc/rc.distros copies it INTO each tree at boot.
         ("etc/de-ns-run.linux", "etc/de-ns-run")] + SKEL_FILES
        + launchers_for("hamnix-desktop"),
        ["hamnix-init>=1", "hamnix-hamsh>=1"]),
}


# Install hooks for the component packages above. Kept beside COMPONENTS
# rather than inside it so the tuple shape (and every reader of it) is
# unchanged; main() looks a package up here after it has built its file list.
#
# /init IS NOT A PACKAGE FILE, AND THAT IS NOT AN OMISSION. It is the program
# the kernel executes -- user/hlinstall.ad copies it to the target beside the
# rest of the root (`copy_file("/init", "/n/target/init")`) -- and it is
# byte-identical to /bin/linuxinit. Shipping it as a FILE would have hpm open
# it for writing while it is the running PID 1's text image, and Linux answers
# ETXTBSY: the install would fail on every machine that is up, which is every
# machine anyone would run `hpm update` on. Unlinking first and copying gives
# the same update without that fault -- the running PID 1 keeps the inode it
# is executing, and the next boot gets the new one.
#
# Measured, not assumed: the two lines were run under the PACKAGED hamsh with
# the PACKAGED rm and cp, over an /init holding different bytes from
# /bin/linuxinit, and the copy landed.
#
# WHAT IT DOES ON AN INSTALL TO A FRESH DISK: nothing that matters. hpm runs
# every hook by spawning the LIVE /bin/hamsh (user/hpm.ad, _run_hook), so on a
# `hlinstall`-style install the files go to the target and this hook copies the
# live /bin/linuxinit onto the live /init -- the same bytes it already has. The
# target's /init is written by user/hlinstall.ad, which copies it explicitly.
COMPONENT_HOOKS = {
    "hamnix-init": {"install.hamsh": "\n".join([
        "# hamnix-init -- install hook.",
        "#",
        "# Refresh /init, the program the kernel executes. It is the same",
        "# bytes as /bin/linuxinit, which this package has just laid down.",
        "# It is copied rather than shipped because a package FILE at /init",
        "# would be opened for writing on the running PID 1's text image ->",
        "# ETXTBSY -> a failed install on any machine that is up. rm unlinks",
        "# the name (the running process keeps its inode); cp makes a new one.",
        "rm '/init'",
        "cp '/bin/linuxinit' '/init'",
        "echo '[hamnix-init] /init refreshed from /bin/linuxinit -- the next "
        "boot runs it'",
        "exit 0",
        "",
    ])},
    # ------------------------------------------------------------------
    # hamnix-desktop -- SAY, IN THE TERMINAL THE PERSON IS LOOKING AT, THAT
    # THEIR RUNNING SESSION IS NOW A DEAD SESSION.
    # ------------------------------------------------------------------
    # The window system's shared segment carries a version counter
    # (WSYS_VERSION in user/linux-wsys.c). When it moves -- 6 -> 7 moved the
    # window table to 512 rows AND took the keystrokes out of the segment;
    # 7 -> 8 took the v1 DISPLAY LIST out of it -- the running session and the
    # newly installed binaries no longer agree about what the bytes mean.
    #
    # WHAT HAPPENS HAS CHANGED SINCE THIS TEXT WAS FIRST WRITTEN, and the
    # message below has been rewritten to match rather than left to be
    # comforting. It used to be: the FIRST program built against the new
    # version that attaches to a running session's segment RE-INITIALISES IT,
    # emptying the desktop -- windows, panel and all. That is what
    # tests/linux/installed_update_wsysver.sh measured for 6 -> 7 and it is why
    # this hook exists.
    #
    # A LIVE SESSION IS NOT A LEFTOVER (user/linux-wsys.c, above shm_attach)
    # ships IN version 7, so from 7 onwards the new binary REFUSES to attach to
    # a segment some live process still holds a window in: it says so by name on
    # stderr and changes nothing. The running desktop survives whole. What fails
    # is every newly started program -- which is to say, from the moment the
    # update lands, NOTHING NEW OPENS until the machine is rebooted.
    #
    # Both of those need a reboot and neither of them is silent any more, but
    # they are DIFFERENT THINGS TO BE TOLD, and telling a person their desktop
    # is about to empty when it is not is the same class of error as telling
    # them nothing.
    #
    # MEASURED, on a real installed UEFI+ext4 disk, by
    # tests/linux/installed_update_wsysver.sh: the machine is left showing the
    # compositor's flat backdrop and NOTHING ELSE. No panel, no Applications
    # button, no window. The pointer still reaches the compositor and the
    # keyboard still reaches it, and both have nowhere to go. Nothing on the
    # machine recovers it; a reboot does.
    #
    # AND NOTHING TOLD THE PERSON. hpm printed its upgrade lines and exited 0,
    # the desktop kept working for exactly as long as they did not open
    # anything, and then the screen emptied. That is the failure shape
    # NORTH_STAR.md names by name: the gap answering with silence instead of
    # the truth.
    #
    # THIS HOOK CANNOT PREVENT IT, and it is important to be exact about why:
    # the code that would have to hold its fire is the OLD compositor, which is
    # already on the person's disk and cannot be changed by anything shipped
    # after it. What a hook CAN do is put the sentence where the person is
    # looking -- the terminal they typed `hpm update` into -- and it reaches
    # THIS update, because hpm runs the hook out of the NEW tarball with the
    # OLD hpm. A change in user/hpm.ad or user/wsysd.ad would not: it would
    # only help the update after the one that needs it.
    #
    # IT IS UNCONDITIONAL, AND THAT IS THE SECOND THING THIS PASS MEASURED.
    #
    # The first version guarded the message with `ls '/srv/wsys' > /dev/null`
    # and `if $status == 0`, on the reasoning that /srv is tmpfs and made fresh
    # every boot, so the segment exists exactly when a window system came up.
    # The reasoning was right and the command was not: user/ls.ad's plain mode
    # calls p9_listdir on whatever it is given, so `ls` ON A PLAIN FILE reads
    # the file as if it were a directory, and on a 19 MB one it prints
    # "listing TRUNCATED at 65536 bytes" and EXITS 1. Measured on the installed
    # disk, in the real hpm update: the hook ran, the test said no, and the
    # person was told nothing -- the warning had silently deleted itself.
    #
    # So there is no test. A warning that can quietly not appear is not a
    # warning, and the sentence below is true in every case a hook can be in:
    # it is addressed to a session that may or may not be running, and it says
    # which. The only thing it needs is `echo`, which is a hook's floor --
    # hamnix-init's hook has printed through it since it was written.
    "hamnix-desktop": {"install.hamsh": "\n".join([
        "# hamnix-desktop -- install hook. See COMPONENT_HOOKS in",
        "# scripts/hamlinux_packages.py for the measurement behind this.",
        "echo ''",
        "echo 'hamnix-desktop: THE WINDOW SYSTEM WAS REPLACED.'",
        "echo 'hamnix-desktop: If a desktop session is running on this machine "
        "right now, it'",
        "echo 'hamnix-desktop: belongs to the OLD window system, and the two "
        "cannot share one'",
        "echo 'hamnix-desktop: session. Your windows and your panel are safe "
        "and will keep'",
        "echo 'hamnix-desktop: working -- but from now until you reboot, "
        "NOTHING NEW WILL OPEN.'",
        "echo 'hamnix-desktop: Every program you start will refuse the running "
        "session by name'",
        "echo 'hamnix-desktop: and exit. (If this machine is older still, the "
        "desktop empties'",
        "echo 'hamnix-desktop: instead, and a reboot is the only way back.)'",
        "echo 'hamnix-desktop: REBOOT WHEN YOU CAN. Finish what is open first.'",
        "echo ''",
        "exit 0",
        "",
    ])},
}


# --------------------------------------------------------------------------
# GPU driver packages
# --------------------------------------------------------------------------
# WHY THESE EXIST
# ---------------
# The kernel is a stock Debian kernel and every graphics driver in it is a
# MODULE. user/linux-fb.c scans out through fbdev (/dev/fbN) and falls back to
# raw DRM/KMS -- both i915 and nouveau provide fbdev emulation -- so on an
# Intel or an Nvidia machine the difference between "no display" and "a
# desktop" is literally whether the right .ko got loaded. The base image
# (scripts/hamlinux_image.sh) stages virtio-gpu and friends, which is what a
# QEMU developer boot needs and exactly nothing that real hardware needs.
#
# HOW THE INSTALLED SYSTEM PICKS THEM UP
# --------------------------------------
# user/linuxinit.ad (the Adder PID 1) reads /etc/modules -- one ABSOLUTE .ko
# path per line, already in dependency order -- and finit_module()s each one
# before it execs hamsh. There is no modprobe in that path and no dependency
# resolution: the ORDER IN THE FILE IS THE ORDER OF LOADING. So these packages
# ship a `install.hamsh` hook that appends their modules, in the order
# `modprobe --show-depends` gave at BUILD time, to /etc/modules. Next boot
# loads them. That is the whole mechanism.
#
# /etc/modules HAS A CEILING: linuxinit reads it with ONE 8192-byte read and
# ignores anything past that. The base image writes ~1.5 KiB; the DRM core plus
# one GPU driver adds ~1.2 KiB, so a fully loaded machine sits near 2.7 KiB.
# There is room, but it is finite -- a driver package that wanted to append
# fifty modules would silently lose the tail, so keep these lists to the
# modules modprobe actually named.
#
# Duplicate lines are harmless: user/linux-syscalls.c's sys_init_module maps
# EEXIST to success, so a module the base image already loaded is a no-op when
# a driver package lists it again. That is what lets the shared DRM core be a
# package without having to know what the image underneath already carries.
#
# THREE HARD LIMITS SHAPE THE PACKAGE SPLIT
# -----------------------------------------
#   1. hpm unpacks in RAM: 4 MiB per .tar.gz, 8 MiB inflated (write_pkg
#      enforces this). i915.ko alone is ~9.9 MiB decompressed.
#   2. sys_init_module passes flags=0 to finit_module, so the kernel will NOT
#      accept a compressed module. Modules must be on disk DECOMPRESSED.
#   3. (1) and (2) together mean a big .ko cannot be shipped as-is. So a
#      module over MODULE_GZIP_THRESHOLD ships gzipped and the install hook
#      runs `gzip -d` on it -- which is why these packages depend on
#      hamnix-gzip. Only the two giant ones (i915, nouveau) hit this.
#
# The real fix for (1) is a bigger TARBALL_CAP/TAR_CAP or a streaming unpack
# in user/hpm.ad; this lane does not own that file.

HPM_TARBALL_CAP = 4 * 1024 * 1024      # user/hpm.ad TARBALL_CAP
HPM_TAR_CAP = 8 * 1024 * 1024          # user/hpm.ad TAR_CAP
MODULE_GZIP_THRESHOLD = 4 * 1024 * 1024

MODPROBE = "/usr/sbin/modprobe"


def kernel_version():
    """The kernel these modules are FOR -- the newest /boot/vmlinuz-*, chosen
    the same way scripts/hamlinux_image.sh chooses it, so a package built here
    matches the kernel that image boots."""
    kernels = sorted(glob.glob("/boot/vmlinuz-*"))
    if not kernels:
        return None
    kver = os.path.basename(kernels[-1])[len("vmlinuz-"):]
    return kver if os.path.isdir("/lib/modules/" + kver) else None


def modprobe_chain(kver, mod):
    """The .ko files `mod` needs, in load order, straight out of modprobe.

    Only field 2 is taken. modprobe also prints the module PARAMETERS it would
    pass -- on this build host /etc/modprobe.d says `options nouveau modeset=0`
    (the proprietary Nvidia installer put it there), and carrying that across
    would ship a nouveau that comes up with kernel modesetting DISABLED, i.e. a
    black screen. linuxinit passes no parameters at all, which is what we want.
    """
    if not os.path.exists(MODPROBE):
        return []
    try:
        out = subprocess.check_output(
            [MODPROBE, "--dry-run", "--show-depends", "-S", kver, mod],
            stderr=subprocess.DEVNULL).decode()
    except (subprocess.CalledProcessError, OSError):
        return []
    chain = []
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[0] == "insmod" and os.path.exists(parts[1]):
            chain.append(parts[1])
    return chain


def _ko_relpath(path):
    """/lib/modules/<kver>/kernel/... -> kernel/..., compression suffix gone.

    The key shape host_dep_table() uses, so an absolute path out of
    modprobe_chain() can be looked up in depmod's own table.
    """
    m = re.search(r"/lib/modules/[^/]+/(.*)$", path)
    rel = m.group(1) if m else os.path.basename(path)
    for ext in (".xz", ".gz", ".zst"):
        if rel.endswith(ext):
            rel = rel[: -len(ext)]
            break
    return rel


def merge_chains(chains, kver=None):
    """Topologically merge several modprobe chains into one order valid for
    all of them.

    THE EDGES COME FROM depmod, NOT FROM POSITION IN THE CHAIN, and that
    correction is the whole of this function's history. It used to treat each
    chain as a TOTAL order -- "the union's edges are every (earlier, later)
    pair within a chain" -- and that premise is FALSE. `modprobe
    --show-depends` prints *a* valid topological order, not the only one, so two
    chains that share a set of mutually independent modules routinely print
    them in different relative orders. Under the old model every such pair
    became a contradictory edge and the merge raised
    "module chains disagree on load order; refusing to guess".

    IT HAD NEVER FIRED BECAUSE ONLY TWO CHAINS HAD EVER BEEN MERGED -- i915 and
    nouveau, which happen to agree. Adding the Sound Open Firmware stack (three
    more chains over a shared sound core) produced 40+ "conflicting" pairs on
    the first run, and NOT ONE OF THEM WAS A REAL DEPENDENCY: snd-compress vs
    snd-hda-codec, snd-hda-core vs snd-intel-dspcfg, snd-hwdep vs
    snd-soc-core -- siblings, neither of which depends on the other, so either
    order loads. The refusal was correct about "these chains disagree" and
    wrong about it mattering, and it failed the image build outright.

    THE FIX IS THE NARROWEST ONE THAT WORKS, because the alternative changed an
    order that is already shipping. Deriving every edge from depmod instead
    produced a VALID order (checked: zero modules loaded before a dependency)
    that was nonetheless a DIFFERENT order for the DRM core -- 16 modules,
    first divergence drm_ttm_helper vs rc-core -- and hamnix-drivers-drm has
    been shipping the old one. A gratuitous reordering of GPU module loading is
    exactly the change that "fails on somebody's hardware and nowhere else".

    So: every chain edge is kept EXCEPT the ones another chain contradicts.
    A contradicted pair is, by construction, two modules that some valid order
    puts either way round, so the constraint was never real; the pair falls
    back to depmod's table, which is consulted for a genuine dependency, and
    to chain position as the tiebreak. WHERE NO CHAIN CONTRADICTS ANOTHER THIS
    IS BIT-FOR-BIT THE OLD FUNCTION -- verified: the DRM core comes out
    identical, and the full 32-chain image set that used to refuse now merges
    into 87 modules with zero order violations against depmod.

    THE REFUSAL IS KEPT for a genuine cycle -- a real one would mean depmod's
    table is circular, which is not something to paper over with a guess.
    """
    order, seen = [], set()
    for chain in chains:
        for m in chain:
            if m not in seen:
                seen.add(m)
                order.append(m)
    pos = {m: i for i, m in enumerate(order)}

    # Every (before, after) pair any chain asserts, and the ones some other
    # chain asserts the opposite of.
    edges = set()
    for chain in chains:
        for i, later in enumerate(chain):
            for earlier in chain[:i]:
                edges.add((earlier, later))
    contradicted = {(a, b) for (a, b) in edges if (b, a) in edges}

    kver = kver or kernel_version()
    table = host_dep_table(kver) if kver else {}
    by_rel = {_ko_relpath(m): m for m in order}

    preds = {m: set() for m in order}
    for (a, b) in edges:
        if (a, b) not in contradicted:
            preds[b].add(a)
    # depmod's real dependencies, which outrank any chain accident. For a
    # contradicted pair this is the only thing that could still order it, and
    # for every other pair it is already implied.
    for m in order:
        for d in table.get(_ko_relpath(m), []):
            dm = by_rel.get(d)
            if dm is not None and dm != m:
                preds[m].add(dm)

    out, placed = [], set()
    while len(out) < len(order):
        ready = [m for m in order
                 if m not in placed and preds[m] <= placed]
        if not ready:
            stuck = [os.path.basename(m) for m in order if m not in placed]
            raise SystemExit(
                "hamlinux_packages: a real dependency CYCLE among these "
                "modules, per depmod's own table -- refusing to guess a load "
                "order: %s" % ", ".join(sorted(stuck)[:12]))
        pick = min(ready, key=lambda m: pos[m])
        placed.add(pick)
        out.append(pick)
    return out


def host_dep_table(kver):
    """The build host's own modules.dep, as {relative .ko path: [dep paths]}.

    depmod wrote it; it is derived from the ELF symbol tables of the modules
    themselves, and it is already TRANSITIVELY FLATTENED with the most
    dependent module first -- which is exactly the format user/modprobe.ad
    parses. Compression suffixes are stripped from both sides because the
    modules this channel installs are decompressed (the kernel's
    finit_module(2) is called with flags=0 and will not take a compressed
    module), so the paths in the table must name the files that exist.
    """
    path = "/lib/modules/%s/modules.dep" % kver
    table = {}
    if not os.path.exists(path):
        return table

    def strip(p):
        for ext in (".xz", ".gz", ".zst"):
            if p.endswith(ext):
                return p[:-len(ext)]
        return p

    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or ":" not in line:
                continue
            mod, _, deps = line.partition(":")
            table[strip(mod.strip())] = [strip(d) for d in deps.split()]
    return table


def dep_lines(kver, staged):
    """The modules.dep lines a package must add for the modules it installs.

    WHY A PACKAGE CARRIES THESE AT ALL. The image's modules.dep is generated
    by depmod at IMAGE BUILD TIME (scripts/hamlinux_image.sh) over the modules
    the image stages. It is therefore stale the instant a package installs a
    .ko the image never had -- which is precisely what these GPU driver
    packages do. Without this, `hpm install hamnix-drivers-gpu-intel` would put
    i915.ko on the disk and `modprobe i915` would answer "not found": the
    module present, the name unresolvable, and nothing saying why. So the
    package ships the lines and its install hook appends them, exactly as it
    already appends to /etc/modules.

    Returns [] if the host has no table to copy from, and the caller must
    treat that as a refusal rather than shipping a package whose modules
    modprobe cannot name.
    """
    return dep_lines_for_paths(
        kver, [canonical for _h, _i, canonical, _b in staged])


def dep_lines_for_paths(kver, canonicals):
    """dep_lines() by absolute installed path, so a test can ask for the very
    lines a hook would emit for a given set of .ko files without having to
    build the package around them."""
    table = host_dep_table(kver)
    if not table:
        return []
    prefix = "/lib/modules/%s/" % kver
    out = []
    for canonical in canonicals:
        rel = canonical[len(prefix):]
        if rel not in table:
            raise SystemExit(
                "hamlinux_packages: %s is not in the host's modules.dep; "
                "refusing to ship a module modprobe could not resolve" % rel)
        out.append("%s: %s" % (rel, " ".join(table[rel])))
    return out


def canonical_ko(kver, ko):
    """The path a module OCCUPIES once installed, from the host path modprobe
    named. The image decompresses `foo.ko.xz` to `foo.ko` and so does
    stage_modules, so both the package and the image name the same file; this
    is the one place that rule is written down."""
    rel = ko[len("/lib/modules/%s/" % kver):]
    if rel.endswith(".xz"):
        rel = rel[:-3]
    return "/lib/modules/%s/%s" % (kver, rel)


def stage_modules(kver, kos, workdir):
    """Decompress each .ko.xz into `workdir` under its /lib/modules-relative
    path, gzipping the ones too big for hpm's in-RAM unpack.

    Returns [(host file, path inside the package, absolute installed .ko path,
    gzipped?)]. The installed path is the CANONICAL one -- the same
    /lib/modules/<kver>/kernel/... path scripts/hamlinux_image.sh stages -- so
    a package and the image name the same file rather than shadowing it."""
    staged = []
    for ko in kos:
        rel = canonical_ko(kver, ko)[len("/lib/modules/%s/" % kver):]
        if ko.endswith(".xz"):
            body = lzma.open(ko, "rb").read()
        else:
            with open(ko, "rb") as fh:
                body = fh.read()
        canonical = "/lib/modules/%s/%s" % (kver, rel)
        inside = "lib/modules/%s/%s" % (kver, rel)
        host = os.path.join(workdir, inside)
        os.makedirs(os.path.dirname(host), exist_ok=True)
        big = len(body) > MODULE_GZIP_THRESHOLD
        if big:
            inside += ".gz"
            host += ".gz"
            with gzip.GzipFile(host, "wb", compresslevel=9, mtime=0) as fh:
                fh.write(body)
        else:
            with open(host, "wb") as fh:
                fh.write(body)
        staged.append((host, inside, canonical, big))
    return staged


def module_install_hook(pkg, staged, note, deps=(), kver=None):
    """The install.hamsh that makes the modules take effect on the next boot.

    Deliberately written in the smallest possible slice of hamsh -- literal
    words, `echo`, `>>`, and two spawned commands. It is generated per package
    rather than shipped as a data file because hamsh has no file-reading
    builtin, so a hook cannot read a list; the list has to BE the hook.
    """
    lines = [
        "# %s -- install hook." % pkg,
        "#",
        "# Three jobs:",
        "#   1. gunzip the modules that had to ship compressed (hpm unpacks",
        "#      in a 4 MiB / 8 MiB RAM buffer; linuxinit's finit_module call",
        "#      passes flags=0, so the kernel needs them uncompressed on disk).",
        "#   2. append them, IN DEPENDENCY ORDER, to /etc/modules, which the",
        "#      Adder PID 1 walks at boot.",
        "#   3. append their modules.dep lines to the machine's dependency",
        "#      table, so `modprobe <name>` can RESOLVE them. The image's table",
        "#      was written by depmod when the image was built and knows",
        "#      nothing about a module installed afterwards; without this the",
        "#      .ko would be on the disk and modprobe would say 'not found'.",
        "#",
        "# Appending USED TO BE UNCONDITIONAL, and the reason given for that",
        "# was FALSE FOR UPGRADES. The rationale read: hpm refuses to install",
        "# a package that is already installed, so this runs once per install.",
        "# True of a first install. An UPGRADE runs the hook again, and `hpm",
        "# remove` does NOT take the lines back out -- so every `hpm update`",
        "# touching a driver package appended the same lines a second time,",
        "# and a third, measured at roughly 5.3 KB of modules.dep per update.",
        "#",
        "# The duplicates were harmless to RESOLUTION -- sys_init_module maps",
        "# EEXIST to success and modprobe takes the first matching line -- but",
        "# not to SIZE. /etc/modules is read by user/linuxinit.ad",
        "# load_modules() into a fixed buffer; that buffer was 8192 bytes with",
        "# the file at 6018 and the whole SOF audio stack on its last lines,",
        "# and is now 32768 with an explicit overflow warning. The growth ate",
        "# exactly that headroom: an unbounded append against a bounded read,",
        "# one problem and not two.",
        "#",
        "# WHAT WAS MEASURED BEFORE THIS WAS WRITTEN, because the previous",
        "# comment here refused to guess and it was right to. Every line below",
        "# was RUN, against the real user/hamsh.ad and the real user/grep.ad",
        "# built by scripts/hamlinux_build.sh -- not against bash:",
        "#",
        "#   * hamsh parse_if() takes an EXPRESSION, so `if grep -q ...` is",
        "#     NOT the form. `VAR = $(cmd)` command substitution IS wired, and",
        "#     `if $VAR == '0':` parses and branches correctly.",
        "#   * `or` in an if condition is NOT wired: `if $a == '0' or ...`",
        "#     is `parse error [line N]: expected '{' or ':' to open block`.",
        "#     So the decision is made by three separate ifs over a variable,",
        "#     which was measured to give yes/no/yes for '0'/'3'/''.",
        "#   * grep -cFx prints '1' for a present line and '0' for an absent",
        "#     one; on a MISSING FILE it prints nothing and the capture is the",
        "#     EMPTY STRING, which is why '' is handled separately and appends",
        "#     rather than skipping -- a file that is not there cannot already",
        "#     contain the line.",
        "#   * WITH grep ABSENT FROM $PATH the capture is ALSO '0', which is",
        "#     indistinguishable from 'ran and found nothing'. Named here",
        "#     because it is a real hole and not a theoretical one: on a",
        "#     machine with no /bin/grep this hook degrades to exactly the",
        "#     unconditional append it replaces. That is the OLD behaviour,",
        "#     never a lost module, which is why the hole is acceptable.",
        "#     /bin/grep is in hamlinux_image.sh's APPS list and in COREUTILS.",
        "#   * hamsh parses the WHOLE script before running any of it, and a",
        "#     parse error makes the shell EXIT 0 -- measured. So a bad token",
        "#     anywhere here means the entire hook does nothing while hpm",
        "#     reports success. tests/linux/hpm_module_hook_idempotent.sh",
        "#     RUNS this generated text twice for that reason; a hook that has",
        "#     not been seen to run twice is not shippable.",
        "#",
        "# THE GUARD IS PER FILE, NOT PER LINE, and that is a decision worth",
        "# stating: all of a package's /etc/modules lines are appended by this",
        "# one hook as a single block, so the presence of the FIRST is",
        "# evidence for the block. One `grep` per file instead of one per line",
        "# also keeps the cost off a path hpm has already measured (500 quoted",
        "# appends through hamsh: 0.033 s). The case it does not cover is a",
        "# hook interrupted mid-block on a previous run, which would leave a",
        "# partial list this guard then skips -- accepted, and named.",
        "#",
        "# `hpm remove` still does NOT take the lines back out -- see",
        "# remove.hamsh.",
        "",
        "echo '[%s] enabling %s'" % (pkg, note),
    ]
    for _host, _inside, canonical, big in staged:
        if big:
            lines.append("gzip -d '%s.gz'" % canonical)

    def _guarded(sentinel, target, body, present_msg):
        """The three-if decision measured above, wrapped round `body`.

        `sentinel` is the line whose presence in `target` means the block has
        already been applied.  Emitted as literal hamsh, four spaces of
        indent, which is what parse_suite() takes for a colon-suite.
        """
        out = [
            "_have = $(grep -cFx '%s' '%s')" % (sentinel, target),
            "_do = 'yes'",
            "if $_have != '0':",
            "    _do = 'no'",
            "if $_have == '':",
            "    _do = 'yes'",
            "    echo '[%s] %s could not be read to test for a line already "
            "there -- appending unconditionally'" % (pkg, target),
            "if $_do == 'yes':",
        ]
        out += ["    " + b for b in body]
        out += [
            "else:",
            "    echo '%s'" % present_msg,
        ]
        return out

    mod_body = ["echo '%s' >> '/etc/modules'" % canonical
                for _host, _inside, canonical, _big in staged]
    mod_body.append(
        "echo '[%s] %d module%s added to /etc/modules; loaded on the next "
        "boot'" % (pkg, len(staged), "" if len(staged) == 1 else "s"))
    if staged:
        lines += _guarded(
            staged[0][2], "/etc/modules", mod_body,
            "[%s] %d module%s already in /etc/modules -- NOT appended again"
            % (pkg, len(staged), "" if len(staged) == 1 else "s"))

    if deps and kver:
        depfile = "/lib/modules/%s/modules.dep" % kver
        # THE REDIRECT TARGET IS QUOTED, and it has to be. hamsh's lexer
        # splits a BARE word at a '+', and every Debian kernel release has
        # one -- 6.12.85+deb13-amd64. Unquoted, `>> /lib/modules/6.12.85+
        # deb13-amd64/modules.dep` wrote to a file called
        # /lib/modules/6.12.85, left the real table untouched and exited 0.
        # user/hamsh.ad now glues redirect targets the way it has always
        # glued arguments, so this is fixed at the source -- but a machine
        # INSTALLED BEFORE that fix still has the old shell and would run
        # this hook with it, so the quotes stay. The SAME rule covers the
        # grep argument in the guard above: the sentinel and the file it is
        # looked for in are both single-quoted for the same '+'.
        dep_body = ["echo '%s' >> '%s'" % (dl, depfile) for dl in deps]
        dep_body.append(
            "echo '[%s] %d modules.dep line%s appended to %s'"
            % (pkg, len(deps), "" if len(deps) == 1 else "s", depfile))
        lines += _guarded(
            deps[0], depfile, dep_body,
            "[%s] %d modules.dep line%s already in %s -- NOT appended again"
            % (pkg, len(deps), "" if len(deps) == 1 else "s", depfile))

    lines += [
        "exit 0",
        "",
    ]
    return "\n".join(lines)


def module_remove_hook(pkg, staged):
    """hpm deletes the files it installed; it cannot edit /etc/modules.

    Nothing here tries to: hamsh has no in-place line editor, `grep` in this
    userland has no -v, and the module paths are the canonical ones the base
    image may ALSO list -- so a text filter would risk cutting the boot's own
    drm.ko line out from under virtio-gpu. Rather than a clever edit that is
    wrong on some machines, say plainly what is left behind."""
    return "\n".join([
        "# %s -- remove hook. See the docstring in scripts/" % pkg,
        "# hamlinux_packages.py: this hook does NOT clean /etc/modules.",
        "echo '[%s] NOTE: /etc/modules still lists the modules just removed.'"
        % pkg,
        "echo '[%s] Stale entries are not fatal -- linuxinit prints a warning'"
        % pkg,
        "echo '[%s] per missing module and carries on -- but edit /etc/modules'"
        % pkg,
        "echo '[%s] by hand if you want the boot quiet again.'" % pkg,
        "exit 0",
        "",
    ])


def firmware_files(patterns, exclude=()):
    """Collect /lib/firmware paths. Returns [(host, path inside package)]."""
    out = []
    for pat in patterns:
        for host in sorted(glob.glob("/lib/firmware/" + pat, recursive=True)):
            if not os.path.isfile(host):
                continue
            rel = os.path.relpath(host, "/lib/firmware")
            if any(ex in rel for ex in exclude):
                continue
            out.append((host, "lib/firmware/" + rel))
    return out


def image_module_groups():
    """The module NAMES scripts/hamlinux_image.sh stages, GROUPED BY SOURCE.

    Returns [(label, [names])]: ("base", the names written inline in
    WANT_MODULES) followed by one group per shell variable that line
    interpolates, labelled after the variable ($HW_MODULES -> "hw").

    THE GROUPING IS NOT COSMETIC -- IT IS WHAT KEEPS EACH PACKAGE UNDER hpm's
    CEILING. hpm unpacks in RAM: 4 MiB per .tar.gz and 8 MiB inflated. All
    twenty-four names in one package is 13,139,881 bytes inflated, which
    write_pkg refuses outright ("too big for hpm to install"), so the twenty
    hardware .ko files could not be shipped at all in one lump. Split by the
    boundary the image script itself already draws, they are 34 modules /
    7,267,437 B and 20 modules / 5,872,444 B -- two packages, both under the
    cap, with ZERO files in common (measured, not assumed: two packages owning
    one path means `hpm remove` on either takes the file away from the other).

    PARSED OUT OF THAT SCRIPT, not copied here. The list is the image's, and a
    second copy of it in this file would drift the first time somebody added a
    driver -- silently, and in exactly the direction that leaves a module in
    the image and in no package. Refuses rather than guessing if the
    assignment is not where it expects: an empty list would make the package
    below ship nothing and the coverage gate name twenty files, which is loud,
    but a WRONG list would ship the wrong modules quietly.

    A SHELL VARIABLE IN THAT LIST IS EXPANDED, AND NOT EXPANDING IT COST
    TWENTY FILES. The image script writes

        HW_MODULES="nvme ahci sd_mod usb-storage uas xhci_pci ehci_pci \\
                    usbhid hid-generic"
        WANT_MODULES="${HAMLINUX_MODULES:-... $HW_MODULES ...}"

    and the SHELL expands `$HW_MODULES`, so the image stages nvme, ahci,
    sd_mod, usb-storage, uas, the two USB host controllers and the two HID
    drivers -- twenty .ko files -- while this parse returned the literal
    token `$HW_MODULES`, which modprobe cannot resolve. The nine names then
    fell into the `unresolved` branch of build_base_module_package, whose
    note says "the image cannot stage what modprobe cannot resolve either,
    so this is not a coverage hole". THAT SENTENCE WAS FALSE: the image
    stages them by a different mechanism. Measured by
    tests/linux/channel_covers_image.sh, which went 7 PASS / 20 FAIL naming
    every one of those files -- the drivers that read an NVMe or SATA root
    disk and the ones that make a USB keyboard work, in the image and in no
    package, on exactly the real hardware this port is being aimed at.

    So simple `NAME="..."` assignments earlier in the same file are
    substituted, and a `$NAME` this file cannot resolve is a REFUSAL rather
    than a token passed downstream: an unresolvable name reaching modprobe
    is indistinguishable from a module that genuinely does not exist, which
    is the silence that hid this.
    """
    path = os.path.join(ROOT, "scripts/hamlinux_image.sh")
    with open(path) as fh:
        text = fh.read()
    m = re.search(r'^WANT_MODULES="\$\{HAMLINUX_MODULES:-([^}"]*)\}"',
                  text, re.M)
    if not m:
        raise SystemExit(
            "hamlinux_packages: cannot find WANT_MODULES in %s -- refusing to "
            "guess which modules the image stages" % path)
    # Every plain `NAME="value"` assignment in the script, for substitution.
    assigns = dict(re.findall(r'^([A-Za-z_][A-Za-z0-9_]*)="([^"$]*)"$',
                              text, re.M))
    groups = []                       # [(label, [names])], in source order
    inline = []
    for tok in m.group(1).split():
        if not tok.startswith("$"):
            inline.append(tok)
            continue
        var = tok[1:].strip("{}")
        if var not in assigns:
            raise SystemExit(
                "hamlinux_packages: WANT_MODULES in %s references %s, which "
                "this file cannot resolve -- refusing to package a module "
                "list that does not match the one the image stages"
                % (path, tok))
        label = var.lower()
        if label.endswith("_modules"):
            label = label[: -len("_modules")]
        groups.append((label, assigns[var].split()))
    return [("base", inline)] + groups


def image_want_modules():
    """Every module name the image stages, flattened. See image_module_groups."""
    names = []
    for _label, ns in image_module_groups():
        names.extend(ns)
    return names


def image_want_firmware():
    """The /lib/firmware GLOBS scripts/hamlinux_image.sh stages, as a list.

    PARSED OUT OF THAT SCRIPT FOR THE SAME REASON image_module_groups() parses
    WANT_MODULES: there must be exactly one definition of what the medium
    carries. A second copy of this list in this file would drift the first time
    somebody added a blob, and it would drift SILENTLY in the direction that
    leaves firmware in the image and in no package -- which
    tests/linux/channel_covers_image.sh calls a coverage hole and NORTH_STAR's
    updatable invariant calls a file that can never be fixed on a machine
    somebody already installed.

    WHY THIS FUNCTION EXISTS AT ALL: until the commit that added it, the image
    staged NO firmware, while this file had already grown a firmware_files()
    collector and shipped hamnix-firmware-i915-dmc, -guc and
    hamnix-firmware-nouveau. The channel could carry firmware the image could
    not, so the two halves had never had to agree and there was nothing to
    keep in step. The owner's audio is what made it matter: Sound Open
    Firmware is a driver whose working half is a BLOB, and a .ko-only staging
    path can no more make his speakers work than an empty directory could.

    Refuses rather than guessing, exactly as the module parser does: if the
    assignment is not where it expects, an empty list here would ship no
    firmware package while the image staged 31 files, and the coverage gate
    would name every one of them.
    """
    path = os.path.join(ROOT, "scripts/hamlinux_image.sh")
    with open(path) as fh:
        text = fh.read()
    m = re.search(r'^WANT_FIRMWARE="\$\{HAMLINUX_FIRMWARE:-([^}"]*)\}"',
                  text, re.M)
    if not m:
        raise SystemExit(
            "hamlinux_packages: cannot find WANT_FIRMWARE in %s -- refusing to "
            "guess which firmware the image stages" % path)
    return m.group(1).split()


# The firmware packages: (package name, [globs it owns], description). EVERY
# GLOB IN WANT_FIRMWARE MUST APPEAR HERE, checked below to be exhaustive, so a
# new glob in the image script cannot be staged onto the medium and forgotten
# by the channel in silence.
#
# THE SPLIT IS hpm's CEILING AND NOTHING ELSE (user/hpm.ad unpacks entirely in
# RAM: TARBALL_CAP 4 MiB gzipped, TAR_CAP 8 MiB inflated), and the first
# version of this table got it wrong in the direction worth recording. All 18
# .ri in ONE package MEASURED 3,463,256 gzipped and 7,840,876 inflated -- both
# under the caps, so it built and reported success at 93 % OF TAR_CAP. That is
# not headroom, it is a package that the next kernel's firmware bump breaks,
# and `tar chf -` had made it look far safer than it was (5,447,680) by
# coalescing the identical blobs that 15 of the 18 names reach through symlinks
# into intel-signed/ -- a coalescing that shutil.copy2 into the staging tree
# does NOT do. THE MEASUREMENT THAT MATTERS IS THE ONE TAKEN THROUGH write_pkg,
# not through tar.
#
# So it is split by DSP generation, measured through write_pkg:
#
#   hamnix-firmware-sof        13 files  3,966,976 B   47 % of TAR_CAP
#   hamnix-firmware-sof-older   5 files  1,215,040 B   14 %
#   hamnix-firmware-sof-tplg   13 files    510,696 B    6 %
#
# with ZERO paths in common -- which matters because two packages owning one
# path means `hpm remove` on either takes the file away from the other.
#
# HIS PART IS IN THE FIRST ONE. sof-tgl-h.ri is what the owner's Lenovo
# 20Y0X50600 loads, so the package a machine most needs is also the one with
# the most room to grow.
SOF_FIRMWARE_PACKAGES = [
    ("hamnix-firmware-sof",
     ["intel/sof/sof-tgl*.ri", "intel/sof/sof-adl*.ri",
      "intel/sof/sof-rpl*.ri", "intel/sof/sof-ehl.ri"],
     "Intel Sound Open Firmware DSP boot images for Tiger Lake, Alder Lake, "
     "Raptor Lake and Elkhart Lake. WITHOUT THIS THERE IS NO SOUND CARD AT "
     "ALL on such a machine, not merely no sound: snd_hda_intel consults "
     "snd-intel-dspcfg, sees a DSP, returns -ENODEV and binds NOTHING, and "
     "the SOF driver that takes the device over cannot start its DSP without "
     "this blob -- so no PCM device is ever created and /dev/snd stays empty. "
     "Needs hamnix-firmware-sof-tplg with it. The kernel loads the one file "
     "matching the part it found and ignores the rest."),
    ("hamnix-firmware-sof-older",
     ["intel/sof/sof-icl.ri", "intel/sof/sof-jsl.ri",
      "intel/sof/sof-cml.ri", "intel/sof/sof-cnl.ri",
      "intel/sof/sof-cfl.ri", "intel/sof/sof-apl.ri",
      "intel/sof/sof-glk.ri", "intel/sof/sof-bdw.ri",
      "intel/sof/sof-byt.ri", "intel/sof/sof-cht.ri"],
     "Intel Sound Open Firmware DSP boot images for the older parts -- Ice "
     "Lake, Jasper Lake, Comet Lake, Cannon Lake, Coffee Lake, Apollo Lake, "
     "Gemini Lake, Broadwell, Baytrail and Cherrytrail. Split from "
     "hamnix-firmware-sof only because hpm unpacks in RAM and the two "
     "together leave no headroom. Same role: without the blob for the part a "
     "machine actually has, that machine has no sound card at all."),
    ("hamnix-firmware-sof-tplg",
     ["intel/sof-tplg/sof-hda-generic*.tplg"],
     "Intel Sound Open Firmware TOPOLOGIES for generic HDA codecs -- the "
     "description of the mixers, PCMs and DAI links that the SOF driver turns "
     "INTO the card's control and PCM devices. A DSP that booted its firmware "
     "and got no topology has no /dev/snd/pcmC0D0p either, so this is "
     "REQUIRED alongside the boot-image packages rather than optional. All "
     "digital-mic counts (1/2/3/4ch) and the idisp (HDMI) variants."),
]

SOF_FIRMWARE_LICENSE = "license: nonfree (Intel firmware redistributable)"
SOF_FIRMWARE_HOME = "https://github.com/thesofproject/sof-bin"


def build_firmware_packages(pkgdir, version, entries, skipped):
    """The /lib/firmware packages for the blobs the IMAGE stages.

    Returns the set of package names built, for hamnix-base to depend on. They
    belong in the flagship package for the same reason the boot modules do:
    every installed machine already has these files (the image staged them and
    user/hlinstall.ad copied the live root), and a machine that cannot update
    the firmware its sound card needs is the gap the invariant exists to close.
    """
    built = set()
    staged = image_want_firmware()
    owned = {g for _n, gs, _d in SOF_FIRMWARE_PACKAGES for g in gs}
    unknown = [g for g in staged if g not in owned]
    if unknown:
        # A REFUSAL, not a warning. The alternative is an index that ships an
        # image carrying firmware no package owns -- the exact shape of the
        # $HW_MODULES defect that put twenty real .ko files in the image and
        # in no package, and reported nothing.
        raise SystemExit(
            "hamlinux_packages: scripts/hamlinux_image.sh stages firmware "
            "globs this file has no package for: %s\n"
            "Add them to SOF_FIRMWARE_PACKAGES, or the image will carry "
            "firmware the channel cannot update."
            % ", ".join(unknown))
    # AND THE OTHER DIRECTION, which is the one that ships bytes nobody asked
    # for: a package glob the image does NOT stage would put firmware in the
    # channel that no medium carries, so `hpm install` would add files the
    # coverage gate never checks and no machine needs. Both lists are the same
    # list or this refuses.
    extra = [g for g in sorted(owned) if g not in staged]
    if extra:
        raise SystemExit(
            "hamlinux_packages: SOF_FIRMWARE_PACKAGES owns globs the image "
            "does not stage: %s\n"
            "Add them to WANT_FIRMWARE in scripts/hamlinux_image.sh, or drop "
            "them here." % ", ".join(extra))
    for pname, globs, blurb in SOF_FIRMWARE_PACKAGES:
        fw = firmware_files(globs)
        if not fw:
            # NOT a refusal: a build host without firmware-sof-signed
            # installed genuinely has nothing to ship, and the image script
            # prints its own warning for the same absence. Recorded as a skip
            # so the closure check below drops it from hamnix-base loudly.
            skipped.append("%s (this build host has none of %s -- apt install "
                           "firmware-sof-signed)" % (pname, " ".join(globs)))
            continue
        total = sum(os.path.getsize(h) for h, _ in fw)
        entries.append(write_pkg(
            pkgdir, pname, version,
            "%s %d files, %.1f MiB installed."
            % (blurb, len(fw), total / 1048576.0),
            fw, [],
            extra_info=[SOF_FIRMWARE_LICENSE,
                        "homepage: " + SOF_FIRMWARE_HOME]))
        built.add(pname)
        print("  %s (%d files, %d bytes)" % (pname, len(fw), total))
    return built


def builtin_modules(kver):
    """The modules this kernel has BUILT IN, from /lib/modules/<kver>/
    modules.builtin, as names with '-' folded to '_' (modprobe treats them as
    the same character).

    WHY THIS EXISTS, AND IT IS A CORRECTION RATHER THAN A FEATURE. The packager
    said, of every name modprobe could not resolve:

        "%s: modprobe resolved nothing for %s (the image does not stage them
         either)"

    which reads as "not a coverage hole" and was said out loud about
    i2c-designware-platform -- the I2C bus a modern laptop's touchpad hangs
    off, and one of the nine names 1.0.24 added. THAT SENTENCE HAS BEEN FALSE
    IN THIS FILE BEFORE: the same reassurance was printed for $HW_MODULES,
    twenty real .ko files WERE in the image, and a gate went 7/20 naming every
    one of them. So it is worth knowing WHICH kind of nothing.

    MEASURED on this build host: /boot/config-6.12.85+deb13-amd64 has
    CONFIG_I2C_DESIGNWARE_PLATFORM=y and modules.builtin lists
    kernel/drivers/i2c/busses/i2c-designware-platform.ko. There is no .ko to
    package because the driver is already inside vmlinuz -- which is also why
    the owner's touchpad bound on metal from a package that "shipped one module
    short of its name". The package name is right and the module list is right;
    only the diagnostic was wrong.
    """
    path = "/lib/modules/%s/modules.builtin" % kver
    out = set()
    if not os.path.exists(path):
        return out
    with open(path) as fh:
        for line in fh:
            base = os.path.basename(line.strip())
            for ext in (".ko.xz", ".ko.gz", ".ko.zst", ".ko"):
                if base.endswith(ext):
                    base = base[:-len(ext)]
                    break
            if base:
                out.add(base.replace("-", "_"))
    return out


def drm_core_modules(kver):
    """The shared DRM/KMS core: everything the i915 and nouveau chains need
    EXCEPT the hardware driver itself. hamnix-drivers-drm owns these files, so
    the base module package below must not also claim them -- two packages
    owning one path means `hpm remove` on either takes the file away from the
    other."""
    chains = [c for c in (modprobe_chain(kver, "i915"),
                          modprobe_chain(kver, "nouveau")) if c]
    if not chains:
        return []
    return merge_chains([c[:-1] for c in chains])


def base_module_install_hook(pkg, staged, kver, depname):
    """The install.hamsh for hamnix-drivers-base.

    IT DOES NOT TOUCH /etc/modules, AND THAT IS A MEASUREMENT. linuxinit reads
    that file with ONE 8192-byte read and ignores the rest. The image writes
    2338 bytes of it (36 absolute .ko paths); appending these thirty-four
    again is ~2.2 KiB PER INSTALL, and `hpm update` is a remove followed by an
    install, so three updates would push the tail of the boot list past 8192
    bytes and
    linuxinit would silently stop loading the modules at the end of it --
    which on this list is the sound stack, and then ext4 as the file grew
    further. A silent truncation of the boot's module list is precisely the
    failure shape this project refuses. It does not need the append either:
    these modules are the ones the IMAGE stages and lists, every installed
    machine got that list from the image (user/hlinstall.ad copies the live
    root), and this package replaces the very same canonical paths.

    WHAT IT DOES DO is merge the dependency table, and the direction matters:

        cat modules.dep.base modules.dep > modules.dep.new
        mv  modules.dep.new modules.dep

    PREPEND, not append, and nothing is replaced. user/modprobe.ad's find_line
    returns the FIRST line whose basename matches, so the package's fresh
    lines win over whatever the machine's depmod wrote, while every line a
    driver package appended (hamnix-drivers-drm, -gpu-intel, -gpu-nouveau all
    do `echo '<line>' >> modules.dep` from their own hooks) survives verbatim
    after them and is still found for the modules THIS package does not name.
    That is the append-package-meets-replace-package case made correct rather
    than plausible: no package replaces the table, and the one that ships a
    base copy puts it in front instead of on top.

    Verified with the packaged binaries, not reasoned about: this exact pair
    of lines was run under the packaged hamsh with the packaged cat and mv,
    over a table carrying appended drm.ko/i915.ko lines and a stale base line,
    and produced the fresh line first, the stale one shadowed and the driver
    lines intact. (cat also keeps going past a file that is not there, so a
    machine with NO table at all ends up with this one rather than nothing.)

    ON AN INSTALL TO A FRESH DISK the files land on the target and this hook,
    like every hpm hook, runs against the LIVE root (user/hpm.ad's _run_hook
    spawns the live /bin/hamsh) -- so it prepends the installing machine's own
    table with the same lines it already has, which is a no-op, and the
    target's table arrives with the rest of the root that hlinstall copies.

    THE ONE THING THAT GROWS: each install prepends the base table again, so
    modules.dep gains the size of that table (2680 bytes for the thirty-four
    modules here, printed in this package's description at build time) per
    update, against user/modprobe.ad's 256 KiB DEP_CAP -- around 95 updates of
    headroom on a machine whose table starts at the image's 2765 bytes. The
    overflow is LOUD:
    read_dep_file returns -2 and modprobe says the table is too big for the
    buffer rather than reporting a module missing. The durable fix is a
    modprobe that reads a modules.dep.d directory; it is not in this change.
    """
    dep = "/lib/modules/%s/modules.dep" % kver
    lines = [
        "# %s -- install hook." % pkg,
        "#",
        "# 1. gunzip anything that had to ship compressed (hpm unpacks in a",
        "#    4 MiB / 8 MiB RAM buffer; finit_module(flags=0) will not take a",
        "#    compressed module).",
        "# 2. put this package's dependency lines IN FRONT of the machine's",
        "#    table. Prepend, never replace: modprobe takes the first",
        "#    matching line, so these win, and the lines the GPU driver",
        "#    packages appended to the end of that table are still there and",
        "#    still found. Nothing here edits /etc/modules -- read the",
        "#    docstring in scripts/hamlinux_packages.py for the 8192-byte",
        "#    reason.",
        "",
        "echo '[%s] refreshing the base kernel modules'" % pkg,
    ]
    for _host, _inside, canonical, big in staged:
        if big:
            lines.append("gzip -d '%s.gz'" % canonical)
    lines += [
        # The redirect target is quoted for the same reason the driver hooks
        # quote theirs: a machine installed before the hamsh fix splits a BARE
        # word at the '+' in 6.12.85+deb13-amd64 and writes somewhere else,
        # exiting 0 about it.
        "cat '%s' '%s' > '%s.new'" % (depname, dep, dep),
        "mv '%s.new' '%s'" % (dep, dep),
        # NO APOSTROPHE. This line used to read "...in front of the machine's
        # table", and hamsh takes a single quote inside a single-quoted string
        # as the CLOSING quote: the rest of the file became one unterminated
        # token, `lex_line` failed, and NOTHING IN THE HOOK RAN -- not the cat,
        # not the mv. Worse, the `\nexit\n` hpm appends to every hook wrapper
        # for exactly this eventuality was swallowed by the same unterminated
        # quote, so the spawned hamsh dropped to its interactive prompt on a
        # stdin nobody was feeding and `hpm update` NEVER RETURNED. Measured on
        # a real installed disk (tests/linux/installed_update_modules.sh):
        #
        #   hpm: extracted 35 files
        #   hpm: running hook install.hamsh
        #   hamsh: lexical error (unterminated quote or token-limit exceeded)
        #   hamsh$          <- pid 1's update, wedged until the host killed it
        #
        # The check in write_pkg below now refuses to publish any hook with an
        # odd number of quotes on a line, so this cannot be reintroduced by
        # typing an ordinary English possessive into a message.
        "echo '[%s] %d modules refreshed; %s is now in front of the table "
        "this machine had'" % (pkg, len(staged), depname),
        "exit 0",
        "",
    ]
    return "\n".join(lines)


def base_module_remove_hook(pkg):
    return "\n".join([
        "# %s -- remove hook." % pkg,
        "# hpm deletes the files this package installed. It does NOT put the",
        "# machine's dependency table back the way it was, because the lines",
        "# this package prepended are indistinguishable from the ones depmod",
        "# wrote at image build time -- they are the same lines. They are",
        "# harmless: a modules.dep line naming a .ko that is not there makes",
        "# modprobe say so, by name, when somebody asks for that module.",
        "echo '[%s] NOTE: the base modules are gone; /etc/modules and'" % pkg,
        "echo '[%s] modules.dep still name them. Boot will warn per missing'"
        % pkg,
        "echo '[%s] module and carry on. Reinstall this package to undo.'"
        % pkg,
        "exit 0",
        "",
    ])


def build_base_module_package(pkgdir, version, entries, skipped):
    """hamnix-drivers-base -- the kernel modules the IMAGE boots with.

    Thirty-four modules were in the image and in no package on the published
    1.0.12 channel: ext4, jbd2, mbcache, crc16, crc32c, vfat + fat + the nls
    tables, virtio_blk, virtio_net + net_failover + failover, virtio_input,
    virtio_dma_buf, virtio-gpu, drm_shmem_helper, evdev, overlay, squashfs,
    loop, and the whole snd-hda stack. An installed machine could never
    receive a fix to the module that mounts its ROOT FILESYSTEM, and nothing
    said so. Only drm.ko and drm_kms_helper.ko were carried by anything, by
    hamnix-drivers-drm -- which is why that package's set is subtracted here:
    two packages owning one path means `hpm remove` on either takes the file
    away from the other.

    ONE PACKAGE PER GROUP, BECAUSE ONE PACKAGE DOES NOT FIT. image_module_groups
    returns the image's list split at the boundary the image script itself
    draws, and each group becomes its own package -- hamnix-drivers-base for
    the inline names, hamnix-drivers-<label> for each interpolated variable.
    All twenty-four names together are 13.1 MB inflated against hpm's 8 MiB
    in-RAM ceiling, so the twenty real-hardware .ko files (nvme, ahci, sd_mod,
    the USB stack, the HID stack) could not be carried at all until this split
    existed; they were in the image and in no package, and
    tests/linux/channel_covers_image.sh named every one of them.

    NO FILE IS IN TWO PACKAGES. Each group's set has the DRM core subtracted
    (hamnix-drivers-drm owns those) and everything an earlier group already
    claimed subtracted too, so `hpm remove` on one cannot take a file the
    other installed.

    Returns the package names it built, so hamnix-base can depend on all of
    them rather than on a hard-coded one.
    """
    kver = kernel_version()
    if kver is None or not os.path.exists(MODPROBE):
        skipped.append("hamnix-drivers-base (no modprobe or /lib/modules "
                       "on this host)")
        return []
    built = []
    for label, pkg, mine in image_module_selection(kver, skipped):
        if _build_one_module_package(pkgdir, version, entries, skipped,
                                     kver, pkg, label, mine):
            built.append(pkg)
    return built


def image_module_selection(kver, skipped=None):
    """WHICH .ko FILES EACH hamnix-drivers-* PACKAGE OWNS. Returns
    [(label, package name, [host .ko paths])].

    ONE DEFINITION, TWO CONSUMERS, AND THAT IS THE POINT. The packager below
    builds a package per group from this; scripts/hamlinux_image.sh asks
    group_dep_tables() (which is this, plus dep_lines_for_paths) for the
    modules.dep.<label> table each of those packages ships, and stages it into
    the image root. A SECOND COPY OF THIS SELECTION WOULD DRIFT, and the
    direction it would drift in is a file staged in the image under a name no
    package owns -- or, worse, a package whose file the image lacks, which is
    exactly the condition that kept these two packages out of the installed
    database in the first place.

    `claimed` starts at the DRM core (hamnix-drivers-drm owns those files) and
    each group extends it, so no two packages in a channel can own one path.

    `skipped`, when given, collects the same human-readable refusals the
    packager reports; the image-side caller passes None because staging a
    table is not the place to announce a packaging gap.
    """
    claimed = set(drm_core_modules(kver))
    out = []
    for label, names in image_module_groups():
        pkg = ("hamnix-drivers-base" if label == "base"
               else "hamnix-drivers-" + label)
        chains, unresolved = [], []
        for n in names:
            chain = modprobe_chain(kver, n)
            if chain:
                chains.append(chain)
            else:
                unresolved.append(n)
        if unresolved and skipped is not None:
            # TWO KINDS OF NOTHING, AND THEY ARE NOT THE SAME NEWS. A name the
            # kernel has BUILT IN has no .ko to package and needs none -- the
            # driver is in vmlinuz and works. A name that is neither a module
            # nor builtin is a driver this channel does not have. The old text
            # said the second thing about both; see builtin_modules().
            builtin = builtin_modules(kver)
            inside = [n for n in unresolved if n.replace("-", "_") in builtin]
            gone = [n for n in unresolved if n.replace("-", "_") not in builtin]
            if inside:
                skipped.append(
                    "%s: %s is BUILT INTO this kernel (modules.builtin), so "
                    "there is no .ko to package and none is needed -- the "
                    "driver is in vmlinuz" % (pkg, " ".join(inside)))
            if gone:
                skipped.append(
                    "%s: modprobe resolved nothing for %s and this kernel does "
                    "NOT have it builtin either -- the channel has no such "
                    "driver" % (pkg, " ".join(gone)))
        if not chains:
            if skipped is not None:
                skipped.append("%s (modprobe resolved nothing)" % pkg)
            continue
        mine = [ko for ko in merge_chains(chains) if ko not in claimed]
        if not mine:
            if skipped is not None:
                skipped.append(
                    "%s (every module is already in another package)" % pkg)
            continue
        claimed.update(mine)
        out.append((label, pkg, mine))
    return out


def group_dep_tables(kver=None):
    """The modules.dep.<label> file each hamnix-drivers-* package SHIPS, as
    [(label, package, absolute installed path, body text)].

    WHY THE IMAGE NEEDS THIS AT ALL, which is the whole point of this change.
    scripts/hpm_installed_db.py records a package as installed only if the root
    carries EVERY file the tarball holds -- because hpm upgrades by unlinking
    the recorded list, and a list naming a file the machine never had is a list
    that can delete the wrong thing. hamnix-drivers-base and -hw each hold
    exactly one file the image did not stage: this table. So neither was ever
    recorded, and what is not recorded is never upgraded: `hpm update` on an
    installed machine could not replace the modules that mount its root disk or
    run its touchpad.

    IT IS NOT MACHINE STATE AND IT IS NOT GENERATED AT INSTALL TIME. The
    install hook only CONSUMES it (`cat modules.dep.<label> modules.dep > new;
    mv new modules.dep`); the bytes are produced HERE, at package build time,
    out of the build host's own depmod table, for a module set the image script
    itself decides. Nothing about it depends on the target machine, so the
    image can hold the identical file, and it does: the same selection and the
    same dep_lines_for_paths() call produce it on both sides.

    THE CANONICAL modules.dep IS STILL MACHINE STATE AND IS STILL NOT SHIPPED.
    That distinction is untouched -- see the note in _build_one_module_package.
    """
    if kver is None:
        kver = kernel_version()
    if kver is None or not os.path.exists(MODPROBE):
        return []
    out = []
    for label, pkg, mine in image_module_selection(kver):
        deps = dep_lines_for_paths(kver, [canonical_ko(kver, k) for k in mine])
        if not deps:
            # dep_lines() treats an empty table as a refusal to ship the
            # package at all, so there is no file to stage either.
            continue
        out.append((label, pkg,
                    "/lib/modules/%s/modules.dep.%s" % (kver, label),
                    "\n".join(deps) + "\n"))
    return out


def stage_dep_tables(root):
    """Write every group_dep_tables() file into a staged image root. Returns
    the number written. Loud and non-zero on refusal, because the failure it
    guards against is silent: without these files the two module packages are
    left out of the installed database and the machine can never upgrade
    them."""
    tables = group_dep_tables()
    if not tables:
        raise SystemExit(
            "hamlinux_packages --stage-dep-tables: this host resolved NO "
            "module groups (no modprobe, no /lib/modules, or no modules.dep). "
            "The image would carry no modules.dep.<group>, hamnix-drivers-* "
            "would be left out of the installed database, and `hpm update` "
            "could not upgrade the boot kernel modules.")
    n = 0
    for label, pkg, path, body in tables:
        dest = os.path.join(root, path.lstrip("/"))
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "w") as fh:
            fh.write(body)
        print("[image] staged %s (%d bytes, %d lines) -- the table %s ships, "
              "so the root carries every file that package holds"
              % (path, len(body), body.count("\n"), pkg))
        n += 1
    return n


def _build_one_module_package(pkgdir, version, entries, skipped,
                              kver, pkg, label, mine):
    """One module package, over the .ko set image_module_selection() gave it."""
    workdir = tempfile.mkdtemp(prefix="hambase-")
    try:
        staged = stage_modules(kver, mine, workdir)
        deps = dep_lines(kver, staged)
        if not deps:
            skipped.append("%s (this host has no modules.dep "
                           "to copy the dependency lines from)" % pkg)
            return False
        depname = "/lib/modules/%s/modules.dep.%s" % (kver, label)
        inside = depname.lstrip("/")
        host = os.path.join(workdir, inside)
        os.makedirs(os.path.dirname(host), exist_ok=True)
        body = "\n".join(deps) + "\n"
        with open(host, "w") as fh:
            fh.write(body)
        # THE TABLE IS SHIPPED UNDER ITS OWN NAME, not as modules.dep. The
        # canonical table is machine state: depmod generated it over the
        # modules THAT MACHINE has, and three driver packages append to it. A
        # package file at that path would be deleted-then-rewritten by hpm on
        # every upgrade, taking the appended driver lines with it -- the
        # machine would keep i915.ko on disk and lose the only line that lets
        # `modprobe i915` name it. So the package owns modules.dep.base and
        # the hook merges. tests/linux/channel_covers_image.sh records
        # modules.dep as a named exclusion for this reason and checks that
        # this file is in the channel.
        files = [(h, i) for h, i, _c, _b in staged] + [(host, inside)]
        needs_gzip = any(b for _h, _i, _c, b in staged)
        entries.append(write_pkg(
            pkgdir, pkg, version,
            "Kernel modules the hamnix-linux image stages, for %s (%s set). "
            "These are the modules the image boots with; this package is how "
            "an INSTALLED machine receives a fix to them. It does not change "
            "/etc/modules (the machine already lists them); it refreshes the "
            "files and puts its dependency lines in front of the machine's "
            "modules.dep. %d modules, %d bytes of table."
            % (kver, label, len(staged), len(body)),
            files,
            ["hamnix-init>=1"] + (["hamnix-gzip>=1"] if needs_gzip else []),
            hooks={"install.hamsh": base_module_install_hook(
                       pkg, staged, kver, depname),
                   "remove.hamsh": base_module_remove_hook(pkg)},
            extra_info=["license: GPL-2.0", "homepage: https://kernel.org/"]))
        print("  %s (%d modules + %d dependency lines, %s)"
              % (pkg, len(staged), len(deps), kver))
        return True
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


def build_driver_packages(pkgdir, version, entries, skipped, vk_built=None):
    """The GPU packages. Everything is resolved against the BUILD HOST's
    /lib/modules and /lib/firmware, so the channel only ever offers drivers
    for the kernel the rest of this lane targets."""
    # A GPU driver package pulls in its own USERSPACE half. This is the whole
    # point of the change: before it, `hpm install hamnix-drivers-gpu-nouveau`
    # gave you a kernel module and a framebuffer and nothing that could draw a
    # triangle. The dependency runs kernel -> userspace, never the reverse, so
    # there is no cycle and the ICD is still installable on its own.
    vk_built = vk_built or {}
    vk_dep = lambda key: (["hamnix-vulkan-%s>=1" % key]
                          if key in vk_built else [])
    kver = kernel_version()
    if kver is None or not os.path.exists(MODPROBE):
        skipped.append("GPU driver packages (no modprobe or /lib/modules here)")
        return

    i915 = modprobe_chain(kver, "i915")
    nouveau = modprobe_chain(kver, "nouveau")
    if not i915 and not nouveau:
        skipped.append("GPU driver packages (modprobe resolved nothing)")
        return

    # The shared DRM/KMS core: everything both chains need EXCEPT the
    # hardware driver itself. Packaged separately because it is ~4 MiB that
    # Intel and Nvidia machines both want, and because hpm's per-package RAM
    # cap leaves no room to duplicate it. hamnix-drivers-base subtracts this
    # same set (drm_core_modules) so no two packages own one .ko path.
    core = drm_core_modules(kver)
    workdir = tempfile.mkdtemp(prefix="hamgpu-")
    try:
        core_staged = stage_modules(kver, core, workdir)
        entries.append(write_pkg(
            pkgdir, "hamnix-drivers-drm", version,
            "DRM/KMS core modules for %s -- drm, drm_kms_helper, ttm, "
            "drm_display_helper and the rest of the stack every GPU driver "
            "needs. Loaded from /etc/modules at boot. No display on its own; "
            "install hamnix-drivers-gpu-intel or -gpu-nouveau on top." % kver,
            [(h, i) for h, i, _c, _b in core_staged],
            ["hamnix-init>=1", "hamnix-gzip>=1"],
            hooks={"install.hamsh": module_install_hook(
                       "hamnix-drivers-drm", core_staged, "the DRM/KMS core",
                       dep_lines(kver, core_staged), kver),
                   "remove.hamsh": module_remove_hook(
                       "hamnix-drivers-drm", core_staged)},
            extra_info=["license: GPL-2.0", "homepage: https://kernel.org/"]))
        print("  hamnix-drivers-drm (%d modules, %s)"
              % (len(core_staged), kver))

        # --- Intel -------------------------------------------------------
        if i915:
            # Firmware. /lib/firmware/i915 is ~13 MiB on this host, which is
            # both over hpm's cap and mostly irrelevant to putting a picture
            # on a screen, so it is split by ROLE and only the display-
            # relevant halves are shipped:
            #   DMC  display microcontroller -- display power management,
            #        every gen9+ part, 0.6 MiB. Cheap, always wanted.
            #   GuC  graphics microcontroller -- OPTIONAL on gen9..gen12 but
            #        REQUIRED on DG2/Arc and Meteor Lake, which will not
            #        initialise without it. 6.6 MiB.
            # NOT shipped: HuC (5.5 MiB) and GSC (2.3 MiB). Both are media /
            # protected-content firmware; i915 logs their absence and scans
            # out fine. Say so rather than quietly bloating the channel.
            fw_deps = []
            for fwname, pats, blurb in (
                ("dmc", ["i915/*dmc*.bin"],
                 "Intel i915 DMC firmware (display microcontroller) -- all "
                 "gen9+ parts. Needed for display power management; i915 "
                 "warns and still scans out without it."),
                ("guc", ["i915/*guc*.bin"],
                 "Intel i915 GuC firmware (graphics microcontroller) -- "
                 "OPTIONAL on Skylake..Alder Lake, REQUIRED on DG2/Arc and "
                 "Meteor Lake, which do not initialise without it."),
            ):
                fw = firmware_files(pats)
                if not fw:
                    continue
                pname = "hamnix-firmware-i915-" + fwname
                entries.append(write_pkg(
                    pkgdir, pname, version,
                    "%s %d files, %.1f MiB installed."
                    % (blurb, len(fw),
                       sum(os.path.getsize(h) for h, _ in fw) / 1048576.0),
                    fw, [],
                    extra_info=["license: nonfree (Intel firmware "
                                "redistributable)",
                                "homepage: https://01.org/linuxgraphics"]))
                fw_deps.append(pname + ">=1")
                print("  %s (%d files)" % (pname, len(fw)))

            i915_staged = stage_modules(kver, i915[-1:], workdir)
            entries.append(write_pkg(
                pkgdir, "hamnix-drivers-gpu-intel", version,
                "Intel integrated graphics (i915) for %s, plus the DMC and "
                "GuC firmware. Ships gzipped and is unpacked by the install "
                "hook: i915.ko is ~9.9 MiB, larger than hpm's in-RAM unpack "
                "buffer. Adds itself to /etc/modules; takes effect on the "
                "next boot. NOT shipped: HuC/GSC media firmware. Pulls in "
                "hamnix-vulkan-anv, so this is a WHOLE stack -- kernel driver, "
                "Vulkan loader and Mesa ICD -- not just a display." % kver,
                [(h, i) for h, i, _c, _b in i915_staged],
                ["hamnix-drivers-drm>=1", "hamnix-gzip>=1"] + fw_deps
                + vk_dep("anv"),
                hooks={"install.hamsh": module_install_hook(
                           "hamnix-drivers-gpu-intel", i915_staged,
                           "Intel i915 graphics",
                           dep_lines(kver, i915_staged), kver),
                       "remove.hamsh": module_remove_hook(
                           "hamnix-drivers-gpu-intel", i915_staged)},
                extra_info=["license: GPL-2.0",
                            "homepage: https://kernel.org/"]))
            print("  hamnix-drivers-gpu-intel (i915 + %d firmware packages)"
                  % len(fw_deps))
        else:
            skipped.append("hamnix-drivers-gpu-intel (no i915 module here)")

        # --- Nvidia, open driver ------------------------------------------
        if nouveau:
            # /lib/firmware/nvidia is 123 MiB on this host and 121 MiB of that
            # is GSP-RM: nvidia/550.163.01/gsp_*.bin and the per-chip gsp/
            # directories. Excluded, and the exclusion is the reason the
            # Ampere caveat below is in the description rather than hidden.
            # What is left is the falcon microcode (acr/gr/sec2/nvdec) that
            # Maxwell..Turing need: ~3.5 MiB. tegra* is ARM, not this arch.
            fw = firmware_files(["nvidia/**/*.bin"],
                                exclude=("/gsp/", "550.163.01", "tegra"))
            fw_deps = []
            if fw:
                entries.append(write_pkg(
                    pkgdir, "hamnix-firmware-nouveau", version,
                    "Nvidia falcon microcode for nouveau (acr, gr, sec2, "
                    "nvdec) -- Maxwell, Pascal, Volta and Turing. %d files, "
                    "%.1f MiB. Does NOT include GSP-RM firmware (121 MiB), so "
                    "Ampere (GA10x) and Ada (AD10x) are not covered."
                    % (len(fw), sum(os.path.getsize(h) for h, _ in fw)
                       / 1048576.0),
                    fw, [],
                    extra_info=["license: nonfree (Nvidia firmware "
                                "redistributable)",
                                "homepage: https://nouveau.freedesktop.org/"]))
                fw_deps.append("hamnix-firmware-nouveau>=1")
                print("  hamnix-firmware-nouveau (%d files)" % len(fw))

            nv_staged = stage_modules(kver, nouveau[-1:], workdir)
            entries.append(write_pkg(
                pkgdir, "hamnix-drivers-gpu-nouveau", version,
                "Nouveau -- the open-source Nvidia driver -- for %s. Covers "
                "Kepler through Turing; Ampere and newer need GSP-RM "
                "firmware, which is 121 MiB and is not in this channel, so "
                "those cards will NOT come up with this package. Ships "
                "gzipped and is unpacked by the install hook. Adds itself to "
                "/etc/modules; takes effect on the next boot. Pulls in "
                "hamnix-vulkan-nvk, the open Vulkan driver: on Turing and "
                "newer that is real 3D, on older cards it is a display only."
                % kver,
                [(h, i) for h, i, _c, _b in nv_staged],
                ["hamnix-drivers-drm>=1", "hamnix-gzip>=1"] + fw_deps
                + vk_dep("nvk"),
                hooks={"install.hamsh": module_install_hook(
                           "hamnix-drivers-gpu-nouveau", nv_staged,
                           "Nouveau (open-source Nvidia) graphics",
                           dep_lines(kver, nv_staged), kver),
                       "remove.hamsh": module_remove_hook(
                           "hamnix-drivers-gpu-nouveau", nv_staged)},
                extra_info=["license: MIT/GPL-2.0",
                            "homepage: https://nouveau.freedesktop.org/"]))
            print("  hamnix-drivers-gpu-nouveau (nouveau + %d firmware "
                  "packages)" % len(fw_deps))
        else:
            skipped.append("hamnix-drivers-gpu-nouveau (no nouveau module)")
    finally:
        shutil.rmtree(workdir, ignore_errors=True)

    # --- Nvidia, proprietary ---------------------------------------------
    # This package installs NOTHING, on purpose. See NVIDIA_REFUSAL.
    entries.append(write_pkg(
        pkgdir, "hamnix-drivers-gpu-nvidia", version,
        "The proprietary NVIDIA driver. NOT AVAILABLE on this line and this "
        "package will not install -- it exists so the name gives you the "
        "reason instead of a 'no such package'. Use "
        "hamnix-drivers-gpu-nouveau.",
        [], [], hooks={"pre-install.hamsh": NVIDIA_REFUSAL})
    )
    print("  hamnix-drivers-gpu-nvidia (refusal package -- installs nothing)")


# WHY hamnix-drivers-gpu-nvidia REFUSES TO INSTALL
# ------------------------------------------------
# The proprietary driver is not a .ko you can copy. nvidia.ko is built from
# source against the exact kernel being run, by a toolchain (kbuild: make,
# a C compiler, the kernel headers, ~1 GiB of build tree) that does not exist
# in this userland; the shipped part is a licence-encumbered binary blob that
# a distributor may not simply redistribute unpacked; and the display path
# here is fbdev/DRM, whereas the proprietary stack expects its own modesetting
# module plus a userspace GL driver that has no Hamnix build.
#
# Every shortcut ends in a black screen on a machine that had a working
# console five minutes earlier, which is the single worst failure this
# package could cause. So the package refuses, out loud, and points at the
# driver that does work. When the pieces exist -- an in-system kbuild, a
# licence-acceptance prompt, a nvidia-drm modesetting path -- this becomes a
# real package and this text goes away.
NVIDIA_REFUSAL = """\
# hamnix-drivers-gpu-nvidia -- pre-install hook.
#
# A non-zero exit here aborts the install BEFORE any file is staged and
# BEFORE installed.json is touched (user/hpm.ad: "pre-install hook failed;
# aborting install"). Nothing lands on the system. That is the point: this
# package is a message, not a driver.
echo '========================================================'
echo 'hamnix-drivers-gpu-nvidia is NOT INSTALLABLE.'
echo ''
echo 'The proprietary NVIDIA driver cannot be packaged honestly yet:'
echo '  * nvidia.ko must be COMPILED against the running kernel. That'
echo '    needs kbuild, a C compiler and the kernel headers, none of'
echo '    which exist in this userland.'
echo '  * the blob carries a licence that has to be accepted by the'
echo '    person installing it, and hpm has no prompt for that.'
echo '  * the display path here is fbdev / DRM-KMS. The proprietary'
echo '    stack brings its own modesetting module and a userspace GL'
echo '    driver that has no build on this line.'
echo ''
echo 'A package that pretended otherwise would leave you with a black'
echo 'screen on a machine that had a working console. So it refuses.'
echo ''
echo 'Install this instead -- open-source, in this channel, works:'
echo '    hpm install hamnix-drivers-gpu-nouveau'
echo ''
echo 'That is nouveau (the kernel driver) plus NVK (the open Vulkan'
echo 'driver, hamnix-vulkan-nvk). Be clear about what you get:'
echo '  * Turing (GTX 16 / RTX 20): a display AND real Vulkan. NVK is'
echo '    a conformant driver there. It is slower than the blob and it'
echo '    does not do CUDA, NVENC or ray tracing at parity.'
echo '  * Kepler, Maxwell, Pascal: a display. NVK starts at Turing, so'
echo '    `vkprobe` finds no device on those cards even though the'
echo '    console and the desktop work.'
echo '  * Ampere (RTX 30) and Ada (RTX 40): NOTHING YET. Those need'
echo '    GSP-RM firmware, 121 MiB that is not in this channel, and'
echo '    the KERNEL driver does not come up without it.'
echo '  * CUDA: no. Not now and not from this package.'
echo '========================================================'
exit 1
"""


# --------------------------------------------------------------------------
# The Vulkan userspace -- the half that was missing
# --------------------------------------------------------------------------
# WHY THIS EXISTS
# ---------------
# Everything above this line ships KERNEL modules. A kernel module gets you
# /dev/dri/card0 and a framebuffer to scan out on; it does not get you a single
# triangle. The thing that draws is a USERSPACE driver -- an ICD -- reached
# through the Vulkan loader, and until now there was none anywhere in the
# Hamnix root. `hpm install hamnix-drivers-gpu-intel` handed you i915.ko and a
# working console and called that GPU support, which is exactly the
# success-shaped answer HANDOFF.md §0 warns about.
#
# tests/linux/vkprobe.ad (commit 1703d382) proved the missing half is reachable:
# an Adder binary on this lane dlopen()s libvulkan.so.1 and talks to a real
# ICD, because this lane links glibc dynamically. So the job is not to write a
# driver, it is to SHIP one -- in the Hamnix root, installed by hpm, with no
# Debian namespace anywhere in the picture.
#
# WHERE THE BINARIES COME FROM, AND WHY
# -------------------------------------
# The BUILD HOST, not scripts/hamlinux_distro.sh's Debian namespace, and the
# reason is the ABI. scripts/hamlinux_image.sh already copies the host's
# ld-linux-x86-64.so.2 and libc.so.6 into the Hamnix root -- that is what makes
# the glibc lane work at all. The namespace is a DIFFERENT Debian release
# (bookworm) with a different glibc and a different libstdc++. Mixing an ICD
# built against one libc with the loader and libc of another is the classic way
# to get a library that loads, enumerates nothing, and blames your GPU. Same
# host, same closure, one ABI.
#
# It also means these packages are only ever offered for the kernel and the
# userland the rest of this lane targets, exactly like the module packages.
#
# HOW THE LOADER FINDS ANY OF IT
# ------------------------------
# Nothing is configured and nothing needs to be. The Vulkan loader searches
# /usr/share/vulkan/icd.d for *.json manifests; each manifest names its ICD by
# SONAME; ld.so resolves that out of /usr/lib/x86_64-linux-gnu. All three of
# those paths are inside the Hamnix root and are the SAME paths on the host, so
# an ICD package is a straight file copy. VK_ICD_FILENAMES can still pin one
# driver by hand, which is what the host-side rule about the software ICD uses.
#
# SONAMES, NOT SYMLINKS. Every library is installed under the name in its
# DT_SONAME (libvulkan.so.1, not libvulkan.so.1.4.309) as a REGULAR FILE. The
# tar format can carry a symlink but hpm's unpacker is not known to honour one,
# and a dangling libvulkan.so.1 is a stack that fails at dlopen with a message
# about the wrong file. ld.so matches the string, not the inode, so a plain
# file under the soname is correct and has no moving parts.
#
# THE SIZE PROBLEM, AND THE SPLIT
# -------------------------------
# hpm unpacks a package entirely in RAM: 4 MiB of .tar.gz, 8 MiB inflated
# (user/hpm.ad, TARBALL_CAP/TAR_CAP; write_pkg enforces both). Mesa is not
# small -- ANV is 20.9 MiB, NVK 15.6 MiB, and lavapipe drags in libLLVM.so.19.1
# at 129.7 MiB. Not one of them fits.
#
# So a payload takes one of three routes, by measurement, and each is a file
# the guest can reconstruct with tools that already exist in this userland:
#
#   plain  under 6 MiB raw: shipped as-is. No hook.
#   gz     gzipped by this script; the install hook runs `gzip -d`. This is the
#          same trick the i915.ko package already uses. MEASURED: user/gzip.ad's
#          inflate does 129.7 MiB in 1.4 s and is byte-identical to the input,
#          so this costs nothing worth counting.
#   split  the gzip stream cut into <=3.5 MiB pieces, one per PACKAGE, staged
#          under /var/lib/hpm/parts/. The consumer's install hook `cat`s them
#          back in order, gunzips, and removes the pieces.
#
# The split is ugly and it is honest about being ugly. The parts are ORDERED BY
# THE HOOK, not by hpm's dependency walk: a hook that spelled out the order is
# reviewable, whereas relying on install order would produce a corrupt library
# whenever hpm changed its mind about traversal. The real fix is a streaming
# unpack in user/hpm.ad, which this lane does not own; when that lands, every
# `-partNN` package here collapses into its parent and nothing else changes.

VK_LIBDIR = "/usr/lib/x86_64-linux-gnu"
VK_ICD_DIR = "usr/share/vulkan/icd.d"
VK_PARTS_DIR = "var/lib/hpm/parts"

# Ship raw below this; above it, gzip. Comfortably under TAR_CAP (8 MiB) with
# room for the rest of a package's files.
VK_RAW_MAX = 6 * 1024 * 1024
# One part / one single gz file. Under TARBALL_CAP (4 MiB) with room for
# PKGINFO, the hooks and tar's own headers.
VK_PART_MAX = 3 * 1024 * 1024 + 512 * 1024

# ld.so and libc come with the Adder binaries themselves -- every program in
# /bin needs them and scripts/hamlinux_image.sh's copy_libs already staged
# them. Everything ELSE in an ICD's closure ships, including libraries the
# image happens to carry today (libz, libzstd, arriving via OpenSSL). Byte-
# identical files from the same host, so a duplicate costs a megabyte and
# removes a whole class of "it loaded and then found nothing" failure. Deciding
# by what the image happens to stage would make these packages depend on a
# detail of a different script.
VK_ASSUMED = {"libc.so.6", "ld-linux-x86-64.so.2", "linux-vdso.so.1"}


def so_name(path):
    """The name a library must be INSTALLED as: its DT_SONAME if it has one,
    else its own basename. This is the string ld.so will look for."""
    try:
        out = subprocess.check_output(["readelf", "-d", path],
                                      stderr=subprocess.DEVNULL).decode()
    except (subprocess.CalledProcessError, OSError):
        return os.path.basename(path)
    for line in out.splitlines():
        if "SONAME" in line and "[" in line:
            return line.split("[", 1)[1].split("]", 1)[0]
    return os.path.basename(path)


def ldd_closure(paths):
    """Every shared object `paths` need, transitively, as host paths.

    ldd is already transitive, so one call per input is the whole closure. It
    is also the only thing that reports what the LOADER will actually pick,
    which is the question being asked. Anything in VK_ASSUMED is dropped.
    """
    found = {}
    for p in paths:
        try:
            out = subprocess.check_output(["ldd", p],
                                          stderr=subprocess.DEVNULL).decode()
        except (subprocess.CalledProcessError, OSError):
            continue
        for line in out.splitlines():
            line = line.strip()
            if "=> /" in line:
                host = line.split("=> ", 1)[1].split(" (")[0]
            elif line.startswith("/") and " (0x" in line:
                host = line.split(" (")[0]
            else:
                continue
            host = os.path.realpath(host)
            if not os.path.isfile(host):
                continue
            name = so_name(host)
            if name in VK_ASSUMED or os.path.basename(host) in VK_ASSUMED:
                continue
            found[name] = host
    return found


def vk_payload(workdir, host, install_dir, seq):
    """Stage one library for shipping. Returns

        (files, parts, hook_lines)

    files      [(host file, path inside THIS package)]
    parts      [[(host file, path inside a part package)], ...] -- one list per
               part package that has to be created
    hook_lines the install.hamsh lines that reconstruct the file, or []

    `seq` disambiguates staging paths when two libraries share a basename.
    """
    name = so_name(host)
    dest = "%s/%s" % (install_dir.lstrip("/"), name)
    with open(host, "rb") as fh:
        body = fh.read()
    if len(body) <= VK_RAW_MAX:
        return [(host, dest)], [], []

    gz_host = os.path.join(workdir, "%d-%s.gz" % (seq, name))
    with gzip.GzipFile(gz_host, "wb", compresslevel=9, mtime=0) as fh:
        fh.write(body)
    gz_size = os.path.getsize(gz_host)

    if gz_size <= VK_PART_MAX:
        # One file, one gunzip.
        return ([(gz_host, dest + ".gz")], [],
                ["gzip -d '/%s'" % (dest + ".gz")])

    with open(gz_host, "rb") as fh:
        blob = fh.read()
    nparts = (len(blob) + VK_PART_MAX - 1) // VK_PART_MAX
    parts, hook = [], []
    for i in range(nparts):
        chunk = blob[i * VK_PART_MAX:(i + 1) * VK_PART_MAX]
        pname = "%s.gz.%02d" % (name, i)
        phost = os.path.join(workdir, "%d-%s" % (seq, pname))
        with open(phost, "wb") as fh:
            fh.write(chunk)
        parts.append([(phost, "%s/%s" % (VK_PARTS_DIR, pname))])
        hook.append("cat '/%s/%s' %s '/%s.gz'"
                    % (VK_PARTS_DIR, pname, ">" if i == 0 else ">>", dest))
    hook.append("gzip -d '/%s.gz'" % dest)
    for i in range(nparts):
        hook.append("rm '/%s/%s.gz.%02d'" % (VK_PARTS_DIR, name, i))
    return [], parts, hook


def vk_package(pkgdir, version, entries, name, description, libs, extras,
               depends, workdir, seq_base):
    """Build one Vulkan package plus whatever `-partNN` packages its payload
    needs. `libs` are host library paths, `extras` are (host, inside) pairs
    already in final form (the ICD manifests). Returns the package name."""
    files = list(extras)
    hook = []
    part_pkgs = []
    needs_gzip = False
    for n, lib in enumerate(libs):
        f, parts, h = vk_payload(workdir, lib, VK_LIBDIR, seq_base + n)
        files += f
        hook += h
        if h:
            needs_gzip = True
        for i, pfiles in enumerate(parts):
            pname = "%s-part%02d" % (name, len(part_pkgs) + 1)
            entries.append(write_pkg(
                pkgdir, pname, version,
                "Payload part %d of %s (%s). Carries no program: it is one "
                "piece of a library too large for hpm's 4 MiB in-RAM unpack. "
                "%s's install hook reassembles the pieces."
                % (i + 1, name, so_name(lib), name),
                pfiles, []))
            part_pkgs.append(pname)
    # Declare exactly the tools the generated hook actually runs. A payload
    # that only needed gzipping does not need `cat` or `rm`, and a package that
    # over-declares its dependencies drags files onto machines that will never
    # use them.
    deps = list(depends) + [p + ">=1" for p in part_pkgs]
    if needs_gzip:
        deps += ["hamnix-gzip>=1"]
    if part_pkgs:
        deps += ["hamnix-cat>=1", "hamnix-rm>=1"]
    hooks = {}
    if hook:
        hooks["install.hamsh"] = "\n".join(
            ["# %s -- install hook: reassemble the payload." % name,
             "#",
             "# Every line here is generated from a MEASURED size at build",
             "# time. See scripts/hamlinux_packages.py, 'THE SIZE PROBLEM'.",
             "echo '[%s] reassembling the driver payload'" % name]
            + hook
            + ["echo '[%s] installed'" % name, "exit 0", ""])
    entries.append(write_pkg(pkgdir, name, version, description, files, deps,
                             hooks=hooks or None,
                             extra_info=["license: MIT (Mesa) / Apache-2.0 "
                                         "(Vulkan loader)",
                                         "homepage: https://mesa3d.org/"]))
    print("  %s (%d files, %d part package%s)"
          % (name, len(files), len(part_pkgs),
             "" if len(part_pkgs) == 1 else "s"))
    return name


# Each ICD: package suffix -> (library, icd manifest, extra libraries,
#                              extra depends, description)
VK_ICDS = {
    "venus": (
        "libvulkan_virtio.so", "virtio_icd.x86_64.json", [], [],
        "Mesa VENUS -- the Vulkan driver for virtio-gpu. This is the one that "
        "makes a VIRTUAL MACHINE genuinely GPU-accelerated: the guest's Vulkan "
        "calls are forwarded over virtio to the host's real driver. Needs a "
        "host that offers it (QEMU: -device virtio-gpu-gl-pci,venus=on -- see "
        "scripts/hamlinux_vm.sh venus). On a plain virtio-gpu it enumerates "
        "nothing, which is correct, not broken."),
    "anv": (
        "libvulkan_intel.so", "intel_icd.x86_64.json",
        ["libdrm_intel.so.1"], [],
        "Mesa ANV -- the Vulkan driver for Intel integrated and Arc graphics, "
        "Skylake onward. Userspace only: it needs the i915 KERNEL driver, and "
        "hamnix-drivers-gpu-intel is what depends on this rather than the "
        "other way round, so that installing the driver installs the whole "
        "stack. That package's firmware caveats apply here too."),
    "nvk": (
        "libvulkan_nouveau.so", "nouveau_icd.x86_64.json",
        ["libdrm_nouveau.so.2"], [],
        "Mesa NVK -- the OPEN Vulkan driver for NVIDIA hardware, on top of "
        "nouveau. Turing (RTX 20) and newer are where it is a real driver; "
        "Kepler through Pascal are supported by the KERNEL side but NVK "
        "requires the GSP firmware path, so on those cards you get a display "
        "and no Vulkan. This is not the proprietary driver and does not "
        "pretend to match it -- see hamnix-drivers-gpu-nvidia."),
    "radv": (
        "libvulkan_radeon.so", "radeon_icd.x86_64.json",
        ["libdrm_amdgpu.so.1"], ["hamnix-vulkan-llvm>=1"],
        "Mesa RADV -- the Vulkan driver for AMD GCN and RDNA. NOTE: there is "
        "no hamnix-drivers-gpu-amd in this channel yet, so the amdgpu KERNEL "
        "driver has to come from somewhere else; this package is the userspace "
        "half only. Links libLLVM, hence the hamnix-vulkan-llvm dependency."),
    "lavapipe": (
        "libvulkan_lvp.so", "lvp_icd.x86_64.json", [], ["hamnix-vulkan-llvm>=1"],
        "Mesa LAVAPIPE -- Vulkan on the CPU. No GPU, no kernel driver, no "
        "firmware: it enumerates a device on any machine that can run this "
        "userland at all, which makes it the fallback and the thing to test "
        "against when a real driver misbehaves. It is a SOFTWARE rasteriser "
        "and it is slow. Costs 165 MiB installed, nearly all of it libLLVM."),
}


def build_vulkan_packages(pkgdir, version, entries, skipped):
    """The userspace driver stack: loader, ICDs, manifests, libdrm.

    Returns {icd key: package name} for the ICDs that were actually built, so
    the KERNEL driver packages can depend on the matching userspace half and
    `hpm install hamnix-drivers-gpu-nouveau` means a whole stack rather than a
    console. Empty when this host has no Mesa to package."""
    built = {}
    loader = os.path.join(VK_LIBDIR, "libvulkan.so.1")
    if not os.path.exists(loader):
        skipped.append("Vulkan userspace (no libvulkan.so.1 on this host)")
        return built
    loader = os.path.realpath(loader)

    icd_src = "/usr/share/vulkan/icd.d"
    present = {}
    for key, (lib, _json, extra, _dep, _desc) in VK_ICDS.items():
        libs = [os.path.join(VK_LIBDIR, lib)] + \
               [os.path.join(VK_LIBDIR, e) for e in extra]
        if all(os.path.exists(p) for p in libs):
            present[key] = [os.path.realpath(p) for p in libs]
    if not present:
        skipped.append("Vulkan ICDs (mesa-vulkan-drivers not installed here)")
        return built

    workdir = tempfile.mkdtemp(prefix="hamvk-")
    try:
        # --- the loader, and the closure every ICD shares -------------------
        # Split this way because it is what the ICDs agree on: one copy of
        # libstdc++ and the xcb/wayland presentation libraries, not one per
        # driver. An ICD package on its own would otherwise be 5 MiB of
        # duplicated dependency.
        shared = ldd_closure([loader] + sorted(
            {p for ps in present.values() for p in ps}))
        # LLVM is not shared -- only lavapipe and RADV want it, it is 165 MiB,
        # and it gets its own package for exactly that reason.
        llvm_only = ldd_closure([os.path.join(VK_LIBDIR, "libvulkan_lvp.so")]) \
            if "lavapipe" in present else {}
        no_llvm = ldd_closure(
            [loader] + [p for k, ps in present.items()
                        if k not in ("lavapipe", "radv") for p in ps])
        llvm_names = set(llvm_only) - set(no_llvm)

        # Anything an ICD package carries itself -- its driver library and its
        # per-chip libdrm -- must NOT also land in the shared package, or two
        # packages own the same file and `hpm remove` on one breaks the other.
        icd_own = {so_name(p) for ps in present.values() for p in ps}
        base = {n: h for n, h in shared.items()
                if n not in llvm_names
                and n not in icd_own
                and not n.startswith("libvulkan_")
                and n != "libvulkan.so.1"}
        base["libvulkan.so.1"] = loader
        base_files = []
        for n, h in sorted(base.items()):
            base_files.append((h, "%s/%s" % (VK_LIBDIR.lstrip("/"), n)))
        # libdrm's PCI-id table. RADV reads it to name an AMD part; without it
        # the driver still works and the device is named less precisely.
        for extra_data in ("/usr/share/libdrm/amdgpu.ids",):
            if os.path.exists(extra_data):
                base_files.append((extra_data,
                                   extra_data.lstrip("/")))
        raw = sum(os.path.getsize(h) for h, _ in base_files)
        entries.append(write_pkg(
            pkgdir, "hamnix-vulkan", version,
            "The Vulkan LOADER (libvulkan.so.1) and the dependency closure "
            "every ICD shares -- libdrm, libstdc++, the xcb/wayland "
            "presentation libraries. %.1f MiB. Installs NO driver: the loader "
            "reads /usr/share/vulkan/icd.d and finds whatever ICD packages are "
            "installed alongside it. `vkprobe` will report zero devices until "
            "one is. Everything here lives in the HAMNIX root -- no Debian "
            "namespace is involved at any point."
            % (raw / 1048576.0),
            base_files, ["hamnix-init>=1"],
            extra_info=["license: Apache-2.0 (loader), MIT (Mesa)",
                        "homepage: https://vulkan.lunarg.com/"]))
        print("  hamnix-vulkan (loader + %d shared libraries, %.1f MiB)"
              % (len(base_files), raw / 1048576.0))

        # --- LLVM, for lavapipe and RADV ------------------------------------
        if llvm_names:
            llvm_libs = sorted(llvm_only[n] for n in llvm_names)
            total = sum(os.path.getsize(p) for p in llvm_libs)
            vk_package(
                pkgdir, version, entries, "hamnix-vulkan-llvm",
                "libLLVM and its closure, %.1f MiB, because Debian's Mesa "
                "links lavapipe and RADV against it. Nothing else in this "
                "channel needs LLVM and nothing here is a compiler you can "
                "run -- it is a shader backend that two ICDs dlopen through "
                "DT_NEEDED. It is split across part packages purely because "
                "hpm unpacks in a 4 MiB RAM buffer."
                % (total / 1048576.0),
                llvm_libs, [], ["hamnix-vulkan>=1"], workdir, 100)

        # --- one package per ICD --------------------------------------------
        for seq, key in enumerate(sorted(present)):
            lib, jsonname, _extra, dep, desc = VK_ICDS[key]
            manifest = os.path.join(icd_src, jsonname)
            if not os.path.exists(manifest):
                # Debian names them without the arch infix.
                manifest = os.path.join(icd_src,
                                        jsonname.replace(".x86_64", ""))
            extras = []
            if os.path.exists(manifest):
                extras.append((manifest, "%s/%s"
                               % (VK_ICD_DIR, os.path.basename(manifest))))
            else:
                skipped.append("hamnix-vulkan-%s (no ICD manifest)" % key)
                continue
            built[key] = vk_package(
                pkgdir, version, entries, "hamnix-vulkan-" + key,
                desc, present[key], extras,
                ["hamnix-vulkan>=1"] + list(dep), workdir, 200 + seq * 10)
    finally:
        shutil.rmtree(workdir, ignore_errors=True)
    return built


def synth_test_wav(workdir):
    """/usr/share/sounds/test.wav -- the same half second of 660 Hz stereo
    s16le that scripts/hamlinux_image.sh synthesises into the image, by the
    same arithmetic, so the package and the image carry identical bytes.

    It is generated rather than committed for the reason the image script
    gives (96 KB nobody has to review), and it is PACKAGED because `aplay`
    without it is a program with nothing to play: the image had the sound, the
    channel did not, and an installed machine's only audio sample could never
    be replaced.
    """
    rate, chans, secs, freq, amp = 48000, 2, 0.5, 660.0, 11000
    n = int(rate * secs)
    frames = bytearray()
    for i in range(n):
        v = int(amp * math.sin(2.0 * math.pi * freq * i / rate))
        frames += struct.pack("<h", v) * chans
    data = bytes(frames)
    hdr = (b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVEfmt "
           + struct.pack("<IHHIIHH", 16, 1, chans, rate,
                         rate * chans * 2, chans * 2, 16)
           + b"data" + struct.pack("<I", len(data)))
    path = os.path.join(workdir, "test.wav")
    with open(path, "wb") as fh:
        fh.write(hdr + data)
    return path


def synth_hamnix_release(workdir, version):
    """/etc/hamnix-release -- the one line naming the release this machine IS.

    scripts/hamlinux_image.sh writes it into the image root
    (`printf '%s\\n' "$HAMLINUX_VERSION" > "$ROOT/etc/hamnix-release"`), and
    from the commit that introduced it until now NO PACKAGE CARRIED IT.
    tests/linux/channel_covers_image.sh says exactly what that means:

        FAIL: etc/hamnix-release ships in the image and is in NO package --
              an installed machine can never update it

    So a machine installed from a 1.0.26 stick and then brought fully up to
    date with `hpm update` kept a file saying 1.0.26 while every binary
    beside it was 1.0.27. Nothing on the machine reads the file today, which
    is why it was survivable and why it was easy to miss -- but a version
    marker that cannot move is a small lie sitting next to honest lines, and
    the invariant it breaks is the one this project treats as permanent:
    what is built here must be able to reach an installed machine.

    GENERATED, not copied, and the version comes from the packager's own
    --version rather than from a file the image left lying about. That is
    what makes it correct on an installed machine: the marker then says which
    release the PACKAGES are, which is the thing `hpm update` actually moved.
    A copy of the image's file would say which release the machine was
    IMAGED at, which is the bug in a different place.

    Byte-for-byte the same as the image's line (value + "\\n"), so the
    "every /etc file the channel carries is byte-identical to the image's"
    assertion in the same gate keeps holding.
    """
    path = os.path.join(workdir, "hamnix-release")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("%s\n" % version)
    return path


def pkg_name_for(cmd):
    """docs/packages.md: underscores become hyphens in the PACKAGE name; the
    installed binary keeps its own filename."""
    return "hamnix-" + cmd.replace("_", "-")


def describe(cmd):
    man = os.path.join(ROOT, "etc/man", cmd + ".1.md")
    if os.path.exists(man):
        with open(man, encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
        for i, line in enumerate(lines):
            if line.strip().lower().startswith("# name") or \
               line.strip().lower() == "## name":
                for nxt in lines[i + 1:i + 4]:
                    if nxt.strip():
                        return nxt.strip()
    return "hamnix-linux %s command" % cmd


# NO per-application object list here. scripts/hamlinux_build.sh knows which
# programs need extra objects (wsysd needs the Vulkan shim, the glibc floor
# and -ldl) and adds them itself since 6a27c0ec.
#
# This file used to keep its own copy, and passing them a SECOND time is 27
# `multiple definition of hvk_*` errors -- so wsysd did not link and
# hamnix-desktop was silently dropped from the channel with one line of
# output. It went unnoticed because build_one REUSES a cached .elf newer than
# its source: every channel built in a tree that had already built wsysd
# picked up the old artefact and packaged it. Only a clean worktree actually
# ran the compiler, and the first one that did produced a channel with no
# desktop in it.
#
# scripts/hamlinux_image.sh had the identical duplicate and it shipped an
# initramfs with NO COMPOSITOR for hours (069f7c1f). This was the third copy.
# One place knows: the build script.

_NEWEST_SHARED_INPUT = None


def newest_shared_input():
    """The mtime of the most recently modified thing EVERY program here links
    against: EVERY .ad under lib/ at ANY depth, EVERY .ad directly under user/
    (the four that are library modules included), user/linux-*.c and their
    headers, the build script, scripts/adder_llvm_runtime.c -- which is on the
    link line of every binary -- and THE COMPILER, build/cutover/host_ac*.elf.
    Computed once.

    IT USED TO GLOB `lib/*.ad` AND `lib/*/*.ad` AND STOP THERE, WHICH LEFT 40
    OF THE 174 SHARED SOURCES INVISIBLE -- and they are not obscure ones, they
    are the entire web engine: lib/web/js/interp.ad, lib/web/dom/domtree.ad,
    lib/web/css/cascade.ad, lib/web/layout/flow.ad and 36 more, three and four
    directories deep. MEASURED against this function rather than argued, by
    touching a file and asking build_one's own predicate whether it would reuse
    the existing artefact:

        after touching lib/web/js/interp.ad    reuse=True   STALE BINARY SHIPS
        after touching lib/web/dom/domtree.ad  reuse=True   STALE BINARY SHIPS
        after touching lib/web/layout/flow.ad  reuse=True   STALE BINARY SHIPS
        after touching lib/hamui.ad            reuse=False  rebuilt (correct)

    So a fix to the JS interpreter, the DOM or the layout engine would have
    published the PREVIOUS hambrowse, by exactly the mechanism described below
    that this function was written to close. Every name would be present, every
    sha256 would match, and the browser on the machine would be last week's.
    It walks lib/ now instead of guessing its depth.

    This exists because the cache below used to stat exactly ONE input,
    user/<cmd>.ad, AND THAT SHIPPED A BROKEN DESKTOP. hamnix-desktop 1.0.10
    went to https://255.one/ with a wsysd compiled at 19:17 beside a
    hampanelscene and a hamdesktop compiled at 18:25, while user/linux-wsys.c
    -- the wsys backend all three link -- had been modified at 19:54. Every
    package NAME was present, every sha256 matched the bytes served, the
    dependency closure resolved, and the machine that ran `hpm update` came up
    with a desktop mapping NO WINDOWS AT ALL. Measured on a real installed disk
    by tests/linux/installed_update_live.sh.

    Note what could NOT have caught it. channel_covers_image.sh compares NAMES,
    and every name was there. The index checks compare hashes to the bytes on
    disk, and those agreed -- they were the wrong bytes, consistently. And no
    gate in this tree runs these objects at all, because every test builds from
    source through hamlinux_build.sh; the artefact that actually ships was the
    one artefact nothing executed.

    The cost of correctness is real and is accepted deliberately: touching
    anything under lib/ now rebuilds all 98 packages. That is the right trade.
    The machine's owner made it a standing invariant that work done here must
    reach the package repository and be updatable, and a cache that can publish
    a stale binary does not merely risk that invariant -- it breaks it while
    every other check reports success."""
    global _NEWEST_SHARED_INPUT
    if _NEWEST_SHARED_INPUT is not None:
        return _NEWEST_SHARED_INPUT
    newest = 0.0
    for f in shared_inputs():
        try:
            newest = max(newest, os.path.getmtime(f))
        except OSError:
            pass
    _NEWEST_SHARED_INPUT = newest
    return newest


def shared_inputs():
    """The LIST newest_shared_input() takes its maximum over -- every path
    whose modification must rebuild every program in the channel.

    It is a separate function so that it can be ASSERTED ON rather than
    inferred from a timestamp. tests/linux/packager_sees_its_inputs.sh asks
    this for the set and fails by NAME on anything missing; the version of
    this check that lived only inside the max() was measurable only by
    touching files in the working tree and reading a boolean back, which is a
    destructive probe nobody wants in the battery."""
    pats = [os.path.join(ROOT, "user", "*.c"),
            os.path.join(ROOT, "user", "*.h"),
            os.path.join(ROOT, "user", "*.S")]
    files = [f for p in pats for f in glob.glob(p)]
    # EVERY .ad under lib/, at whatever depth it sits. A recursive walk rather
    # than a list of globs, so a new subdirectory of lib/ is covered the day it
    # appears instead of the day somebody notices -- lib/web/js/builtins/ is
    # four deep and nothing was watching it.
    for dirpath, _dirnames, filenames in os.walk(os.path.join(ROOT, "lib")):
        for fn in filenames:
            if fn.endswith(".ad"):
                files.append(os.path.join(dirpath, fn))
    # EVERY .ad under user/ TOO, and not only user/<cmd>.ad. Four files in
    # user/ have no `def main` at all -- scripts/hamlinux_build.sh names them
    # in its own header and exits 13 on them -- because they are LIBRARY
    # MODULES that applications import: user/hambrowse_tabs.ad (hambrowse),
    # user/http9.ad (hpm, curl, wget), user/net9.ad (the /net dialers) and
    # user/httpdconf.ad (httpd). They were invisible here, exactly as
    # lib/web/js/interp.ad was before the walk above. MEASURED with this
    # function and build_one's own reuse predicate, against build/repo-obj:
    #
    #     after touching user/hambrowse_tabs.ad      reuse=True   STALE SHIPS
    #     after touching user/http9.ad               reuse=True   STALE SHIPS
    #     after touching scripts/adder_llvm_runtime.c reuse=True  STALE SHIPS
    #     after touching build/cutover/host_ac.elf   reuse=True   STALE SHIPS
    #     after touching lib/hamui.ad                reuse=False  rebuilt
    #     after touching lib/web/js/interp.ad        reuse=False  rebuilt
    #     after touching user/linux-wsys.c           reuse=False  rebuilt
    #
    # The last three are the control: the same probe answers both ways, so
    # `reuse=True` is a finding and not a broken instrument.
    for fn in glob.glob(os.path.join(ROOT, "user", "*.ad")):
        files.append(fn)
    files.append(os.path.join(ROOT, "scripts/hamlinux_build.sh"))
    # scripts/adder_llvm_runtime.c IS LINKED INTO EVERY BINARY THIS FILE
    # PACKAGES -- it is on hamlinux_build.sh's clang line beside the runtime
    # objects -- and nothing here was watching it. A fix to it would have
    # published every previous program in the channel.
    files.append(os.path.join(ROOT, "scripts/adder_llvm_runtime.c"))
    # AND THE COMPILER ITSELF, which is the one input that changes what EVERY
    # byte of every program is. Keyed by the same selection hamlinux_build.sh
    # makes (the LLVM host_ac if it is there, else the other), and both are
    # listed rather than only the winner so that installing the LLVM one
    # invalidates too.
    #
    # This is the mechanism that produces the exact shape reported against
    # 1.0.25 -- "the tree's browser works, the channel's does not". Every gate
    # in tests/linux/ builds from source through hamlinux_build.sh on every
    # run, so a gate ALWAYS has a binary from the current compiler; only this
    # file reuses. Re-bootstrap the compiler without touching lib/ or user/
    # and the tree goes green on freshly built bytes while the channel ships
    # whatever the previous compiler emitted, with every name present and
    # every sha256 matching the bytes served.
    #
    # The compiler's SOURCES (adder/compiler/*.ad) are deliberately NOT here.
    # Editing them changes nothing about the bytes emitted until host_ac is
    # re-bootstrapped, and that rewrites host_ac.elf -- so the binary is the
    # honest key and the sources would invalidate 98 packages on every
    # submodule checkout for no change in output. Re-measured after this
    # change, adder/compiler/ssa_llvm.ad is the one candidate that still
    # answers reuse=True, which is the intended answer and keeps the probe
    # able to say both things.
    files.append(os.path.join(ROOT, "build/cutover/host_ac_llvm.elf"))
    files.append(os.path.join(ROOT, "build/cutover/host_ac.elf"))
    return files


# THE SOURCE PATH HANDED TO THE BUILD SCRIPT IS RELATIVE TO ROOT, AND THAT IS
# NOT A STYLE CHOICE.
#
# The Adder front end puts the COMPILED PATH into the symbol names it emits, so
# `hamlinux_build.sh user/hpm.ad` and `hamlinux_build.sh /abs/…/user/hpm.ad`
# produce two ELFs that are not byte-identical. This file used to pass the
# absolute form while scripts/hamlinux_image.sh passes the relative one, so
# /bin/hpm on an image and the hpm in the channel had different sha256s --
# 531,680 bytes against 542,600 -- and "the bytes tested are the bytes served"
# was not literally true of anything this project ships.
#
# MEASURED, so that nobody has to re-chase it: building user/hambrowse.ad both
# ways in one tree, minutes apart, the ONLY section that differs is .strtab
# (0x1e06e relative, 0x1f4d8 absolute, +5,226 bytes of longer name strings).
# .symtab is the same size, every allocated section is the same size, and
# .text and .rodata are BYTE-IDENTICAL by sha256. Both binaries score 2/0 on
# tests/linux/de_browser_paints.sh. So the split was never a behaviour
# difference and the absolute path was never the reason a packaged program
# misbehaved -- but a build that is bit-reproducible across its two callers is
# worth having for free, and a differing sha256 is a permanent invitation to
# blame the wrong thing.
#
# `cwd=ROOT` below is what makes the relative form resolve, and
# hamlinux_build.sh cds to its own PROJ_ROOT first thing regardless.
def _relsrc(path):
    """`path` as hamlinux_build.sh will be given it: relative to ROOT, the same
    string scripts/hamlinux_image.sh passes. Falls back to the absolute path if
    the file is somehow not under ROOT, which cannot happen for anything this
    file builds but must not become a traceback if it ever does."""
    rel = os.path.relpath(path, ROOT)
    return path if rel.startswith(os.pardir) else rel


def build_one(cmd, objdir):
    """Build user/<cmd>.ad through the Linux lane. Returns the ELF path or
    None. Reuses an existing artefact only when that artefact is newer than
    EVERY input it was built from -- its own source and every shared input (see
    newest_shared_input, and read it: the one-input version of this check
    published a desktop that mapped no windows)."""
    src = os.path.join(ROOT, "user", cmd + ".ad")
    if not os.path.exists(src):
        return None
    out = os.path.join(objdir, cmd + ".elf")
    newest_src = max(os.path.getmtime(src), newest_shared_input())
    if os.path.exists(out) and os.path.getmtime(out) > newest_src:
        return out
    rc = subprocess.call(
        [os.path.join(ROOT, "scripts/hamlinux_build.sh"), _relsrc(src), out],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=ROOT)
    return out if rc == 0 else None


def build_vkprobe(objdir):
    """tests/linux/vkprobe.ad + its C shim. Not in COREUTILS because it is not
    one file: the shim is what calls dlopen/vkCreateInstance, and it needs
    -ldl. Same shape as the other user/linux-*.c device backends, except this
    one lives in tests/ because it is a probe, not a device."""
    src = os.path.join(ROOT, "tests/linux/vkprobe.ad")
    shim = os.path.join(ROOT, "tests/linux/vkprobe.c")
    if not (os.path.exists(src) and os.path.exists(shim)):
        return None
    out = os.path.join(objdir, "vkprobe.elf")
    rc = subprocess.call(
        [os.path.join(ROOT, "scripts/hamlinux_build.sh"), _relsrc(src), out,
         _relsrc(shim), "-ldl"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=ROOT)
    return out if rc == 0 else None


def write_pkg(outdir, name, version, description, files, depends,
              target="#hamnix-system", hooks=None, extra_info=()):
    """files: list of (host path, path inside the installed tree).
    hooks: {"install.hamsh": "<script text>", ...} -- docs/packages.md §hooks.
    extra_info: additional `key: value` PKGINFO lines (license, homepage...)."""
    stage = tempfile.mkdtemp(prefix="hpmpkg-")
    try:
        top = os.path.join(stage, "%s-%s" % (name, version))
        os.makedirs(os.path.join(top, "files"))
        # AN ENTRY NAME HPM CANNOT HOLD IS A FILE THAT GOES MISSING ON A
        # MACHINE, AND IT HAS. A tar header has 100 bytes for the name; GNU tar
        # (which is what tarfile writes here) puts anything longer in a
        # preceding 'L' entry and truncates the header's own field. hpm read
        # only that field, so it wrote the body to the TRUNCATED path and
        # recorded the truncated path -- measured on an installed machine
        # upgrading hamnix-drivers-base and -hw: 14 of 65 modules replaced by
        # junk names, "extracted 35 files" printed over the top of it.
        # user/hpm.ad now reads the 'L' entry (see longname_buf), and its
        # ceiling is 255 bytes, which is what warn_buf and safe_buf hold. This
        # refuses at the same number so a package can never again ship a name
        # the machine's unpacker has to shorten.
        for host, inside in files:
            entry = "%s-%s/files/%s" % (name, version, inside)
            if len(entry.encode("utf-8")) > 255:
                raise SystemExit(
                    "hamlinux_packages: %s: the tar entry name is %d bytes, "
                    "over the 255 user/hpm.ad's LONGNAME_CAP holds:\n  %s\n"
                    "hpm would refuse the archive on the machine. Shorten the "
                    "installed path or the package name."
                    % (name, len(entry.encode("utf-8")), entry))
        for host, inside in files:
            dest = os.path.join(top, "files", inside)
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            shutil.copy2(host, dest)
            if inside.startswith("bin/"):
                os.chmod(dest, 0o755)
        for hook_name, body in sorted((hooks or {}).items()):
            # A HOOK THAT DOES NOT LEX WEDGES THE MACHINE THAT INSTALLS IT.
            # hamsh has no escape inside a single-quoted string, so one stray
            # apostrophe makes the rest of the file a single unterminated
            # token: lex_line fails, NOTHING in the hook runs, and the
            # `\nexit\n` hpm appends to the wrapper is swallowed with it -- so
            # the spawned shell falls through to its interactive REPL on a
            # stdin nobody is feeding and `hpm update` never returns. That is
            # not a package that installs badly; it is a package that stops
            # the machine, and it shipped: hamnix-drivers-base 1.0.13 said
            # "in front of the machine's table" in an echo.
            #
            # Refusing here is the same shape as the closure and duplicate
            # refusals below: a build error nobody sees beats an update that
            # hangs on every machine that takes it.
            # AND A HOOK OVER 16 KiB IS SILENTLY TRUNCATED, which manufactures
            # the very fault the loop below catches. hamsh's `rc_buf` and
            # hpm's `hook_body_buf` are both Array[16384]: a longer hook is
            # cut with nothing said, and measured, a 37,895-byte script of 500
            # appends ran 217 of them and then fed the severed tail to the
            # shell as a command. Worse, if the cut lands inside a quoted
            # string it creates an unterminated quote OUT OF A HOOK THIS CHECK
            # WOULD HAVE PASSED -- the balance is correct in the file and
            # wrong in the 16 KiB the machine actually reads.
            #
            # Nothing ships close to it today: the largest published hook is
            # hamnix-drivers-drm at 4,921 bytes, 30% of the ceiling. But these
            # hooks are ONE LINE PER MODULE and one per dependency edge, so
            # the margin is a package's worth of driver, not a design bound.
            # Refuse at the limit rather than discover it on a machine.
            if len(body.encode("utf-8")) >= 16384:
                raise SystemExit(
                    "hamlinux_packages: %s's %s is %d bytes, at or over the "
                    "16384-byte ceiling in hamsh's rc_buf and hpm's "
                    "hook_body_buf. It would be TRUNCATED with nothing said, "
                    "and a cut inside a quoted string manufactures an "
                    "unterminated quote that wedges the machine installing "
                    "it. Split the hook or shorten what it emits."
                    % (name, hook_name, len(body.encode("utf-8"))))
            for lineno, line in enumerate(body.splitlines(), 1):
                if line.lstrip().startswith("#"):
                    continue
                if line.count("'") % 2:
                    raise SystemExit(
                        "hamlinux_packages: %s's %s line %d has an odd number "
                        "of single quotes, so hamsh cannot lex it and the "
                        "hook would wedge every machine that installs this "
                        "package:\n    %s"
                        % (name, hook_name, lineno, line))
            hpath = os.path.join(top, hook_name)
            with open(hpath, "w") as fh:
                fh.write(body)
            os.chmod(hpath, 0o755)
        info = ["name: %s" % name,
                "version: %s" % version,
                "arch: x86_64",
                "description: %s" % description]
        if depends:
            info.append("depends: %s" % ", ".join(depends))
        info.append("target: %s" % target)
        info.append("maintainer: HamnixOS")
        info.extend(extra_info)
        with open(os.path.join(top, "PKGINFO"), "w") as fh:
            fh.write("\n".join(info) + "\n")

        tarpath = os.path.join(outdir, "%s-%s.tar.gz" % (name, version))
        # Deterministic: same inputs -> same bytes -> same sha256, so a
        # rebuilt channel does not churn every package's hash for nothing.
        #
        # AND THE COMMENT ABOVE WAS HALF FALSE UNTIL THIS LINE. Every TarInfo
        # is normalised (uid/gid/uname/gname/mtime), so the UNCOMPRESSED tar
        # was already byte-identical build to build -- MEASURED: the local and
        # the published 1.0.26 `hpm` tarballs inflate to identical bytes and
        # their .tar.gz files still differ. `tarfile.open(..., "w:gz")` builds
        # its own gzip.GzipFile with the DEFAULT mtime, which is time.time(),
        # and stamps it into the 4-byte MTIME field of the gzip header. So the
        # sha256 of a package changed on every rebuild for no reason but the
        # clock, and "the bytes I built are the bytes served" was not checkable
        # at the tarball level at all -- only after inflating.
        #
        # Driving the GzipFile explicitly with mtime=0 AND filename="" (which
        # suppresses the optional FNAME field, otherwise taken from the
        # fileobj's name) makes the wrapper a pure function of the tar.
        # tests/linux/pkg_tar_reproducible.sh is the gate.
        def norm(ti):
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = "root"
            ti.mtime = 0
            return ti
        with open(tarpath, "wb") as raw:
            with gzip.GzipFile(filename="", mode="wb", compresslevel=9,
                               fileobj=raw, mtime=0) as gzf:
                with tarfile.open(fileobj=gzf, mode="w",
                                  format=tarfile.GNU_FORMAT) as tf:
                    for dirpath, dirnames, filenames in os.walk(top):
                        dirnames.sort()
                        for fn in sorted(filenames):
                            full = os.path.join(dirpath, fn)
                            arc = os.path.relpath(full, stage)
                            tf.add(full, arcname=arc, filter=norm)
        with open(tarpath, "rb") as fh:
            data = fh.read()
        # hpm unpacks a package ENTIRELY IN RAM through two fixed arrays
        # (user/hpm.ad: TARBALL_CAP 4 MiB for the .tar.gz, TAR_CAP 8 MiB for
        # the inflated tar). A package over either limit downloads and then
        # fails at the user's prompt, so refuse to publish one here instead --
        # a repository that offers an uninstallable package is a lie.
        inflated = 0
        with gzip.open(tarpath, "rb") as gz:
            while True:
                chunk = gz.read(1 << 20)
                if not chunk:
                    break
                inflated += len(chunk)
        if len(data) > HPM_TARBALL_CAP or inflated > HPM_TAR_CAP:
            raise SystemExit(
                "hamlinux_packages: %s is too big for hpm to install "
                "(tar.gz %d B / cap %d, inflated %d B / cap %d)"
                % (name, len(data), HPM_TARBALL_CAP, inflated, HPM_TAR_CAP))
        return {"name": name, "version": version, "arch": "x86_64",
                "url": "packages/%s-%s.tar.gz" % (name, version),
                "sha256": hashlib.sha256(data).hexdigest(),
                "size": len(data),
                "description": description,
                "depends": list(depends),
                "target": target}
    finally:
        shutil.rmtree(stage, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="build/repo")
    ap.add_argument("--version", default="1.0.0")
    ap.add_argument("--channel", default="linux")
    ap.add_argument("--base-url", default="https://255.one/")
    # The escape hatch is deliberately unattractive and deliberately loud. It
    # exists for a channel built on a host with no python3/vulkan to compose an
    # offscreen desktop on -- not for "this is taking a while". Nothing in this
    # tree passes it.
    # THE INSTALLED-PACKAGE DATABASE, emitted from the tarballs this run just
    # wrote. The file lists come from the same source of truth that built the
    # packages rather than from anything reconstructed on the machine
    # afterwards -- see scripts/hpm_installed_db.py for why an approximate list
    # is worse than no list at all. The SHIPPING emission is in
    # scripts/hamlinux_disk.sh, against the directory it is about to mkfs; this
    # option exists so a channel build can check its own emission (and the
    # no-path-claimed-twice refusal) against a staged root without building a
    # disk.
    ap.add_argument("--installed-db", metavar="PATH",
                    help="also write an hpm installed.json for --installed-db-"
                         "root, listing every package this root really carries")
    ap.add_argument("--installed-db-root", metavar="DIR",
                    default="build/image/root",
                    help="the staged root --installed-db describes "
                         "(default build/image/root)")
    # THE IMAGE-SIDE HALF OF THE INSTALLED DATABASE. See group_dep_tables():
    # hamnix-drivers-base and -hw each hold one file the image did not stage,
    # so hpm_installed_db left both OUT and `hpm update` could never upgrade
    # the boot kernel modules. scripts/hamlinux_image.sh calls this after
    # depmod. It builds no packages and writes no channel -- it exits as soon
    # as the tables are down, so the image build does not pay for a channel.
    ap.add_argument("--stage-dep-tables", metavar="ROOT",
                    help="write each hamnix-drivers-* package's "
                         "modules.dep.<group> table into a staged image root "
                         "and exit; builds nothing else")
    ap.add_argument("--no-desktop-gate", action="store_true",
                    help="do NOT run the packaged binaries before writing the "
                         "index (tests/linux/channel_runs_desktop.sh). Writes "
                         "an index on the strength of names and hashes alone.")
    args = ap.parse_args()

    if args.stage_dep_tables:
        if not os.path.isdir(args.stage_dep_tables):
            raise SystemExit("hamlinux_packages --stage-dep-tables: not a "
                             "directory: %s" % args.stage_dep_tables)
        stage_dep_tables(args.stage_dep_tables)
        return 0

    out = os.path.join(ROOT, args.out, args.channel)
    pkgdir = os.path.join(out, "packages")
    # THIS CACHE IS SHARED, AND A GATE CAN POISON IT WITH ITS OWN TREE.
    # tests/linux/installed_update_wsysver.sh builds three private channels
    # from symlink farms whose `build` reaches back into THIS root, so its
    # packager runs write objects here. Measured: a channel built right after
    # that gate carried a wsysd and an sshd whose symbols read
    # `_home_david__hamnix_build_..._wsysver_tree_next_user_wsysd__` -- the
    # farm's path, baked into every module-private name, because the Adder
    # front end mangles by the path it compiled.
    #
    # THE BYTES WERE STILL RIGHT, and that was checked rather than assumed:
    # the farm symlinks every source except user/linux-wsys.c, the cache is
    # keyed by content, and the contaminated channel's wsysd attached a
    # segment made by this tree's wsysd WITHOUT the version refusal that a
    # WSYS_VERSION mismatch produces. So the damage is to PROVENANCE, not to
    # behaviour -- but provenance is what "the bytes tested are the bytes
    # served" rests on, and a publish should start from an empty cache.
    objdir = os.path.join(ROOT, "build/repo-obj")
    os.makedirs(pkgdir, exist_ok=True)
    os.makedirs(objdir, exist_ok=True)

    entries = []
    skipped = []

    # The files this script generates rather than copies out of the tree.
    gendir = tempfile.mkdtemp(prefix="hamgen-")
    # hamnix-init is where the rest of the static /etc lives (os-release,
    # profile, services, passwd...), so the release marker belongs beside
    # them rather than in a package of its own.
    generated = {"hamnix-audio": [(synth_test_wav(gendir),
                                   "usr/share/sounds/test.wav")],
                 "hamnix-init": [(synth_hamnix_release(gendir, args.version),
                                  "etc/hamnix-release")]}

    # Components first: they carry the boot files everything else needs.
    missing_extras = []
    for name, (desc, bins, extras, deps) in COMPONENTS.items():
        files = []
        ok = True
        for cmd, inside in bins:
            elf = build_one(cmd, objdir)
            if not elf:
                ok = False
                skipped.append("%s (%s did not build)" % (name, cmd))
                break
            files.append((elf, inside))
        if not ok:
            continue
        for src, inside in extras:
            host = os.path.join(ROOT, src)
            if os.path.exists(host):
                files.append((host, inside))
            elif src in EXTRAS_MAY_BE_ABSENT:
                skipped.append("%s: %s absent (%s)"
                               % (name, src, EXTRAS_MAY_BE_ABSENT[src]))
            else:
                # A named extra that is not in the tree is a file this package
                # PROMISES and does not carry. Silence here is how a config
                # file leaves the channel without anyone noticing; the
                # coverage gate would then blame the image. It is collected
                # and refused below rather than skipped -- see
                # EXTRAS_MAY_BE_ABSENT.
                missing_extras.append((name, src, os.path.join("ROOT", src)))
        files.extend(generated.get(name, []))
        entries.append(write_pkg(pkgdir, name, args.version, desc, files, deps,
                                 hooks=COMPONENT_HOOKS.get(name)))
        print("  %s (%d files)" % (name, len(files)))

    # A PROMISE A PACKAGE CANNOT KEEP IS NOT A WARNING.
    #
    # This fires before the GPU stack, the drivers, the index and the desktop
    # gate, so the message a person sees names the missing FILE rather than the
    # symptom it causes several minutes later in a program that could not run.
    if missing_extras:
        lines = "\n".join("    %s promises %s -- not in the tree"
                           % (n, src) for n, src, _ in missing_extras)
        raise SystemExit(
            "\nREFUSING TO PUBLISH: %d named file(s) that package(s) promise "
            "are not in this tree:\n%s\n"
            "Each is an `extras` entry in this script. Either the file is "
            "meant to exist and something upstream of this build did not "
            "produce it (a fresh worktree with no build/ directory is the "
            "usual cause -- build/cutover/host_ac.elf is the one that has "
            "shipped a compiler driver with no compiler before), or its "
            "absence is legitimate and belongs in EXTRAS_MAY_BE_ABSENT with a "
            "reason. No index.json was written, so nothing can install from "
            "this channel."
            % (len(missing_extras), lines))

    # The GPU stack, userspace first: the kernel driver packages declare a
    # dependency on the matching ICD, so the userspace half has to be built
    # before we know whether that dependency can be honoured.
    vk_built = build_vulkan_packages(pkgdir, args.version, entries, skipped)

    # GPU drivers. Not in hamnix-base: which one a machine wants depends on
    # the machine, and installing the wrong one wastes 10 MiB of RAM disk.
    build_driver_packages(pkgdir, args.version, entries, skipped, vk_built)

    # The modules the image itself boots with -- ext4, the virtio drivers,
    # sound. These ARE in hamnix-base: every machine has them already (the
    # image staged them and the installer copied them), and a machine that
    # cannot update the driver that mounts its root filesystem is the exact
    # gap the invariant exists to close.
    module_pkgs = build_base_module_package(pkgdir, args.version, entries,
                                            skipped)

    # The FIRMWARE those modules are useless without. Same argument as the
    # module packages above and the same place in hamnix-base: the image
    # stages these blobs, so every installed machine already has them, and a
    # machine that cannot update the firmware its sound card needs is exactly
    # the gap the updatable invariant exists to close. A .ko is only half of a
    # Sound Open Firmware driver; this is the other half.
    # set(), not |=: build_base_module_package returns a LIST on its early-out
    # path (no modprobe / no /lib/modules here), and `list |= set` is a
    # TypeError -- which would turn "this host cannot build driver packages", a
    # case that is meant to degrade to a skip, into a crashed packager run.
    module_pkgs = set(module_pkgs) | build_firmware_packages(
        pkgdir, args.version, entries, skipped)

    # vkprobe -- the diagnostic that answers "is the GPU stack real?" from
    # inside the Hamnix root. It is the same program that proved this path
    # exists (commit 1703d382), and it is the first thing to run after
    # installing a driver: it prints the device name the ICD reports, or
    # nothing, and there is no third answer to mistake for success.
    vkprobe = build_vkprobe(objdir)
    if vkprobe:
        entries.append(write_pkg(
            pkgdir, "hamnix-vkprobe", args.version,
            "vkprobe -- open the Vulkan loader, create an instance and print "
            "every physical device the installed ICDs enumerate. The check "
            "that a GPU package did something real. Prints nothing but a "
            "device count of 0 when no driver is installed.",
            [(vkprobe, "bin/vkprobe")],
            ["hamnix-init>=1"] + (["hamnix-vulkan>=1"] if vk_built else [])))
        print("  hamnix-vkprobe")
    else:
        skipped.append("hamnix-vkprobe (did not build)")

    # ONE PACKAGE PER DESKTOP APPLICATION, each carrying its program AND the
    # .desktop launcher that puts it on the Applications menu. See
    # DESKTOP_APP_HOMES above for why they are paired and why they are not one
    # package. A launcher whose program did not build is DROPPED WITH IT --
    # `skipped` is what the closure check below refuses an index over, and a
    # row on a menu with nothing behind it is the defect this whole block
    # exists to close.
    app_pkgs = []
    for cmd, launcher, name, comment in desktop_apps():
        elf = build_one(cmd, objdir)
        if not elf:
            skipped.append("hamnix-app-%s (%s did not build)" % (cmd, cmd))
            continue
        desc = "%s -- %s" % (name, comment) if comment else name
        entries.append(write_pkg(
            pkgdir, "hamnix-app-" + cmd, args.version,
            desc + " (/bin/%s, and the launcher that lists it in the "
                   "Applications menu)" % cmd,
            [(elf, "bin/" + cmd),
             (os.path.join(ROOT, "etc/hamde/apps", launcher),
              "etc/hamde/apps/" + launcher)],
            ["hamnix-desktop>=1"]))
        app_pkgs.append("hamnix-app-" + cmd)

    # One package per command.
    cmd_pkgs = []
    for cmd in COREUTILS:
        elf = build_one(cmd, objdir)
        if not elf:
            skipped.append(cmd)
            continue
        name = pkg_name_for(cmd)
        entries.append(write_pkg(pkgdir, name, args.version, describe(cmd),
                                 [(elf, "bin/" + cmd)], ["hamnix-init>=1"]))
        cmd_pkgs.append(name)

    # The two metapackages. A metapackage carries no files, which the format
    # allows -- what it carries is the dependency closure.
    entries.append(write_pkg(
        pkgdir, "hamnix-coreutils", args.version,
        "hamnix-linux core userland -- pulls in every per-command package",
        [], sorted(cmd_pkgs)))
    # The application set, the same shape as hamnix-coreutils: what it carries
    # is the closure. `hpm remove hamnix-app-hamchess` takes the chess program
    # and the chess row off the menu together, which is the property the
    # per-app split was for.
    entries.append(write_pkg(
        pkgdir, "hamnix-apps", args.version,
        "hamnix-linux desktop applications -- pulls in every per-application "
        "package, each carrying its program and the launcher that lists it in "
        "the Applications menu",
        [], sorted(app_pkgs) + ["hamnix-desktop>=1"]))
    # hamnix-base pulls in the manual pages and the boot modules too. Both are
    # conditional on having been BUILT: the closure check below refuses an
    # index whose flagship package names something the channel does not carry,
    # and a host with no /lib/modules cannot produce hamnix-drivers-base.
    built_names = {e["name"] for e in entries}
    # hamnix-apps is in here for the reason NORTH_STAR.md's invariant is about:
    # a machine installed with `hpm install hamnix-base` gets the desktop, and
    # a desktop whose Applications menu has three rows on it is not the
    # distribution this tree builds. It is in the closure-checked list below
    # like every other dependency, so a channel that failed to build one of
    # the app packages has no index rather than a menu with a hole in it.
    base_deps = ["hamnix-init>=1", "hamnix-hamsh>=1", "hamnix-coreutils>=1",
                 "hamnix-net>=1", "hpm>=1", "hamnix-desktop>=1",
                 "hamnix-apps>=1"]
    # EVERY module package, not a hard-coded one. The hardware set is its own
    # package now (see build_base_module_package: one package per group,
    # because all of them together exceed hpm's 8 MiB in-RAM ceiling), and a
    # hard-coded "hamnix-drivers-base" here would have left the nvme/ahci/USB
    # /HID modules in the channel and out of the flagship package -- reachable
    # only by somebody who knew to type its name.
    for optional in ["hamnix-man"] + sorted(module_pkgs):
        if optional in built_names:
            base_deps.append(optional + ">=1")
        else:
            skipped.append("%s missing from hamnix-base (it did not build)"
                           % optional)
    entries.append(write_pkg(
        pkgdir, "hamnix-base", args.version,
        "hamnix-linux base system -- init, shell, coreutils, networking, "
        "package manager, desktop, manual pages and the boot kernel modules",
        [], base_deps))

    for e in entries:
        e["channel"] = args.channel

    # THE DEPENDENCY CLOSURE IS CHECKED, not asserted. Every `skipped` package
    # above is a DROP, and a drop is silent in the worst possible way: the
    # package that wanted it keeps its dependency line, so the index ships a
    # requirement naming something the channel does not carry. hamnix-base is
    # the one that matters -- it declares hamnix-desktop>=1 unconditionally, so
    # the build that silently lost wsysd (see the note above build_one) wrote
    # an index whose flagship package COULD NOT INSTALL, and said `done`.
    #
    # The failure had to travel all the way to a user's prompt to be seen. The
    # docstring at the top of this file claims `hpm install hamnix-base`
    # resolves the whole distribution; until now nothing measured it, and a
    # claim nothing measures is the shape every bug in this tree has worn.
    #
    # So: resolve it here, and refuse to write an index that cannot. Refusing
    # is the honest answer -- publishing a channel with a dangling dependency
    # replaces a build error nobody sees with an install error every user sees.
    # NO TWO PACKAGES MAY SHARE A NAME. A package's tarball path is derived
    # from name+version, so a duplicate name does not merely confuse the
    # index -- the SECOND package's bytes OVERWRITE the first's on disk, and
    # the first entry keeps the sha256 it computed before the overwrite. The
    # index then advertises a checksum for bytes that no longer exist, so the
    # download either fails its hash check or silently installs the wrong
    # package's contents.
    #
    # This is not hypothetical. Adding `install` to COREUTILS collided with
    # the `hamnix-install` COMPONENT (the installer: hlinstall, haminstallui,
    # nsrun, reboot, halt, poweroff): the one-file coreutils package landed on
    # top of it, and six system programs -- including the two that turn the
    # machine off -- vanished from the channel while the build printed nothing
    # but a package count that had gone UP. It was caught by
    # tests/linux/channel_covers_image.sh, not by anything here.
    dupes = {}
    for e in entries:
        dupes.setdefault(e["name"], []).append(e)
    collided = sorted(n for n, es in dupes.items() if len(es) > 1)
    if collided:
        raise SystemExit(
            "REFUSING TO PUBLISH: %d package name(s) used twice: %s\n"
            "Two packages with one name overwrite each other's tarball, and "
            "the loser's sha256 in the index then describes bytes that are no "
            "longer on disk. Rename one -- note that pkg_name_for('foo') is "
            "'hamnix-foo', so a COREUTILS entry can collide with a COMPONENT."
            % (len(collided), " ".join(collided)))

    have = set(e["name"] for e in entries)
    dangling = []
    for e in entries:
        for dep in e.get("depends", []):
            dep_name = re.split(r"[<>=!]", dep, 1)[0].strip()
            if dep_name and dep_name not in have:
                dangling.append("%s requires %s" % (e["name"], dep))
    if dangling:
        raise SystemExit(
            "REFUSING TO PUBLISH: %d dependency/ies name a package this "
            "channel does not carry:\n    %s\n"
            "Those packages were dropped above (see 'not packaged'), but the "
            "packages depending on them kept the requirement, so the index "
            "would install-fail at the user's prompt instead of failing here.\n"
            "Fix the build that dropped them, or drop the dependency too."
            % (len(dangling), "\n    ".join(dangling)))

    # THE PACKAGED BYTES ARE RUN, and the index is not written until they have
    # been. Every guard above this line -- the duplicate name, the dependency
    # closure, the sha256 the index will carry, and
    # tests/linux/channel_covers_image.sh outside this file -- is about NAMES
    # and NUMBERS. All of them passed for hamnix-desktop 1.0.10, which shipped
    # a wsysd from 19:17 beside clients from 18:25 (see newest_shared_input)
    # and put a desktop mapping NO WINDOWS on a machine that ran `hpm update`.
    # Measured here: tests/linux/channel_covers_image.sh scores 4 PASS / 0 FAIL
    # against a reconstruction of that channel, and every sha256 in its index
    # matches the bytes on disk. They were the wrong bytes, consistently.
    #
    # So the gate that closes it cannot be another check on the manifest. It
    # unpacks the tarballs and RUNS the programs -- the desktop under a
    # synthetic mouse, the shell, hpm itself, and the coreutils -- and it must
    # sit HERE rather than in a publish checklist, for the same reason the two
    # guards above do: a gate a person has to remember is a gate that shipped
    # 1.0.10 while every automated check said `done`.
    #
    # It runs BEFORE index.json is written, so a channel that fails it has no
    # index and nothing can install from it. MEASURED: 20 s.
    if not args.no_desktop_gate:
        gate = os.path.join(ROOT, "tests/linux/channel_runs_desktop.sh")
        print("\nrunning the packaged desktop (tests/linux/channel_runs_desktop.sh)")
        sys.stdout.flush()   # the gate writes to this fd; keep the log in order
        env = dict(os.environ, CHANRUN_NO_INDEX="1")
        rc = subprocess.call([gate, out], cwd=ROOT, env=env)
        if rc != 0:
            raise SystemExit(
                "\nREFUSING TO PUBLISH: the binaries in this channel do not "
                "work.\nThe tarballs under %s were unpacked and run, and the "
                "run above says what failed. No index.json was written, so "
                "nothing can install from this channel.\nThis is the check "
                "hamnix-desktop 1.0.10 did not have: every name was present, "
                "every hash matched, and the desktop mapped no windows."
                % pkgdir)
    else:
        print("\n*** --no-desktop-gate: the packaged binaries were NOT RUN. "
              "This index is being written on the strength of names and "
              "hashes alone, which is exactly what hamnix-desktop 1.0.10 "
              "shipped on. ***")

    # AND THE TOOLCHAIN, for the same reason and in the same place.
    #
    # hamnix-adder 1.0.12 was published carrying one file, files/bin/ac -- the
    # DRIVER, without /bin/host_ac which it execs and without the runtime
    # sources it links against. `ac hello.ad` on a machine installed from that
    # channel answers "ac: cannot run /bin/host_ac", exit 10, no binary, while
    # HANDOFF.md §0 lists "compiles Adder on the box" as a measured capability.
    #
    # Every check in this file passed it, and had to: the package built, its
    # hash matched its bytes, its dependency resolved, and the one file it
    # carried was genuinely in it. The coverage gate saw host_ac named in an
    # exclusion table with a reason in front of it, and a reason is not a
    # measurement -- that reason turned out to be false in both halves.
    #
    # So this runs the toolchain instead: it unpacks hamnix-adder, stages a
    # root whose /bin is the tarball's files and nothing else, runs the real
    # /bin/ac through its real namespace hop, and RUNS what comes out.
    # MEASURED: 3 s. It SKIPs (exit 0) on a host with no unprivileged user
    # namespaces, no chroot or no clang -- said out loud when it happens,
    # because a skip in the publish path is a check that did not run.
    gate = os.path.join(ROOT, "tests/linux/channel_compiles_adder.sh")
    print("\nrunning the packaged Adder toolchain "
          "(tests/linux/channel_compiles_adder.sh)")
    sys.stdout.flush()
    rc = subprocess.call([gate, out], cwd=ROOT)
    if rc != 0:
        raise SystemExit(
            "\nREFUSING TO PUBLISH: the Adder toolchain in this channel "
            "cannot compile a program.\nThe run above says which piece is "
            "missing. No index.json was written, so nothing can install from "
            "this channel.\nThis is the check hamnix-adder 1.0.12 did not "
            "have: the package was present, its hash matched, and it "
            "contained a compiler driver with no compiler.")

    index = {
        "schema": 1,
        "repo": "HamnixOS/packages",
        "channel": args.channel,
        "url": args.base_url.rstrip("/") + "/" + args.channel + "/",
        "updated": time.strftime("%Y-%m-%d"),
        "description":
            "hamnix-linux channel -- the Hamnix userland built against the "
            "Linux kernel. Same package names as `main`; the binaries are "
            "glibc-linked ELFs for this line, not native Hamnix ELFs.",
        "packages": entries,
    }
    with open(os.path.join(out, "index.json"), "w") as fh:
        json.dump(index, fh, indent=2)
        fh.write("\n")

    if args.installed_db:
        import hpm_installed_db
        root = os.path.join(ROOT, args.installed_db_root)
        if not os.path.isdir(root):
            raise SystemExit(
                "hamlinux_packages: --installed-db needs a staged root; %s is "
                "not a directory. Run scripts/hamlinux_image.sh first."
                % root)
        print("\nwriting the installed-package database for %s" % root)
        text, _inc, _exc = hpm_installed_db.build(out, root)
        dbpath = os.path.join(ROOT, args.installed_db)
        os.makedirs(os.path.dirname(dbpath) or ".", exist_ok=True)
        with open(dbpath, "w") as fh:
            fh.write(text)
        print("[installed-db] wrote %s" % dbpath)

    print("\n%d packages -> %s" % (len(entries), out))
    if skipped:
        # Say what is NOT in the channel. A package manager whose repository
        # quietly lacks half the system is worse than one that admits it.
        print("not packaged (%d): %s" % (len(skipped), " ".join(skipped)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
