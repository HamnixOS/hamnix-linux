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
                                 [--sign KEYFILE]
"""

import argparse
import glob
import gzip
import hashlib
import json
import lzma
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

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

NET_CMDS = "ifconfig route ping host curl wget dhcpc ntpd".split()

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
SYS_CMDS = "hlinstall haminstallui nsrun reboot".split()

DESKTOP_CMDS = ("wsysd wsyswl xbridge hamdesktop hampanelscene hamtermscene "
                "hameditscene hamsettings hamfm hamUI hamUId").split()

# Component packages: name -> (description, [binaries], [extra files as
# (source-path-in-repo, install-path)], [depends])
COMPONENTS = {
    "hamnix-init": (
        "hamnix-linux init (the Adder PID 1) and the boot rc scripts",
        [("linuxinit", "bin/linuxinit")],
        [("etc/rc.boot.linux", "etc/rc.boot"),
         ("etc/rc.d/rc.5.linux", "etc/rc.d/rc.5"),
         ("etc/rc.de-user.linux", "etc/rc.de-user"),
         ("etc/passwd", "etc/passwd"),
         ("etc/group", "etc/group"),
         ("etc/hostname", "etc/hostname"),
         ("etc/hosts", "etc/hosts")],
        []),
    "hamnix-hamsh": (
        "hamnix-linux shell -- /bin/hamsh",
        [("hamsh", "bin/hamsh")], [], ["hamnix-init>=1"]),
    "hamnix-net": (
        "hamnix-linux networking userland -- ifconfig, route, ping, host, "
        "curl, wget",
        [(c, "bin/" + c) for c in NET_CMDS], [], ["hamnix-init>=1"]),
    "hpm": (
        "Hamnix package manager (hpm), built for the Linux line",
        [("hpm", "bin/hpm")],
        [("etc/hpm/channels", "etc/hpm/channels")],
        ["hamnix-init>=1"]),
    "hamnix-auth": (
        "identity -- login, su, passwd, whoami; clients of /dev/auth",
        [(c, "bin/" + c) for c in AUTH_CMDS], [], ["hamnix-init>=1"]),
    "hamnix-modules": (
        "kernel module tools -- insmod, lsmod, modprobe, rmmod",
        [(c, "bin/" + c) for c in MOD_CMDS], [], ["hamnix-init>=1"]),
    "hamnix-install": (
        "installer and system tools -- hlinstall, haminstallui, nsrun, reboot",
        [(c, "bin/" + c) for c in SYS_CMDS], [], ["hamnix-init>=1"]),
    "hamnix-adder": (
        "the Adder compiler driver -- `ac foo.ad -o foo` on the box",
        [("ac", "bin/ac")], [], ["hamnix-init>=1"]),
    "hamnix-audio": (
        "hamnix-linux audio userland -- playtone, aplay, arecord, clients of "
        "/dev/audio",
        [(c, "bin/" + c) for c in AUDIO_CMDS], [], ["hamnix-init>=1"]),
    "hamnix-desktop": (
        "hamnix-linux desktop -- the scene compositor and the DE clients",
        [(c, "bin/" + c) for c in DESKTOP_CMDS],
        [("etc/panel.conf", "etc/panel.conf"),
         ("etc/desktop.icons", "etc/desktop.icons")],
        ["hamnix-init>=1", "hamnix-hamsh>=1"]),
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


def merge_chains(chains):
    """Topologically merge several modprobe chains into one order valid for
    all of them. Each chain is a total order over its own members, so the
    union's edges are every (earlier, later) pair within a chain. Raises if
    two chains disagree -- silently picking one would produce a load order
    that fails on somebody's hardware and nowhere else."""
    order, seen = [], set()
    for chain in chains:
        for m in chain:
            if m not in seen:
                seen.add(m)
                order.append(m)
    pos = {m: i for i, m in enumerate(order)}
    preds = {m: set() for m in order}
    for chain in chains:
        for i, later in enumerate(chain):
            preds[later].update(chain[:i])
    out, placed = [], set()
    while len(out) < len(order):
        ready = [m for m in order
                 if m not in placed and preds[m] <= placed]
        if not ready:
            raise SystemExit("hamlinux_packages: module chains disagree on "
                             "load order; refusing to guess")
        pick = min(ready, key=lambda m: pos[m])
        placed.add(pick)
        out.append(pick)
    return out


def stage_modules(kver, kos, workdir):
    """Decompress each .ko.xz into `workdir` under its /lib/modules-relative
    path, gzipping the ones too big for hpm's in-RAM unpack.

    Returns [(host file, path inside the package, absolute installed .ko path,
    gzipped?)]. The installed path is the CANONICAL one -- the same
    /lib/modules/<kver>/kernel/... path scripts/hamlinux_image.sh stages -- so
    a package and the image name the same file rather than shadowing it."""
    staged = []
    for ko in kos:
        rel = ko[len("/lib/modules/%s/" % kver):]
        if rel.endswith(".xz"):
            rel = rel[:-3]
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


def module_install_hook(pkg, staged, note):
    """The install.hamsh that makes the modules take effect on the next boot.

    Deliberately written in the smallest possible slice of hamsh -- literal
    words, `echo`, `>>`, and two spawned commands. It is generated per package
    rather than shipped as a data file because hamsh has no file-reading
    builtin, so a hook cannot read a list; the list has to BE the hook.
    """
    lines = [
        "# %s -- install hook." % pkg,
        "#",
        "# Two jobs:",
        "#   1. gunzip the modules that had to ship compressed (hpm unpacks",
        "#      in a 4 MiB / 8 MiB RAM buffer; linuxinit's finit_module call",
        "#      passes flags=0, so the kernel needs them uncompressed on disk).",
        "#   2. append them, IN DEPENDENCY ORDER, to /etc/modules, which the",
        "#      Adder PID 1 walks at boot.",
        "#",
        "# Appending is unconditional: hpm refuses to install a package that is",
        "# already installed, so this runs once per install, and a duplicate",
        "# line would be harmless anyway (sys_init_module maps EEXIST to",
        "# success). `hpm remove` does NOT take the lines back out -- see",
        "# remove.hamsh.",
        "",
        "echo '[%s] enabling %s'" % (pkg, note),
    ]
    for _host, _inside, canonical, big in staged:
        if big:
            lines.append("gzip -d '%s.gz'" % canonical)
    for _host, _inside, canonical, _big in staged:
        lines.append("echo '%s' >> /etc/modules" % canonical)
    lines += [
        "echo '[%s] %d module%s added to /etc/modules; loaded on the next "
        "boot'" % (pkg, len(staged), "" if len(staged) == 1 else "s"),
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
    # cap leaves no room to duplicate it.
    core = merge_chains([c[:-1] for c in (i915, nouveau) if c])
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
                       "hamnix-drivers-drm", core_staged, "the DRM/KMS core"),
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
                           "Intel i915 graphics"),
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
                           "Nouveau (open-source Nvidia) graphics"),
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


# Per-application additions to hamlinux_build.sh's default object list.
# wsysd selects the real-Vulkan rasterization backend, so it needs the C shim
# that dlopens the ICD (user/linux-vk.c), the glibc floor that lets
# lib/vk/vk_core.ad link outside the Hamnix kernel (user/linux-vkhost.c) and
# -ldl. Everything else builds against the defaults; a GPU bring-up and a
# libdl dependency are not something every coreutil should carry.
EXTRA_OBJS = {
    "wsysd": ["user/linux-vk.c", "user/linux-vkhost.c", "-ldl"],
}


def build_one(cmd, objdir):
    """Build user/<cmd>.ad through the Linux lane. Returns the ELF path or
    None. Reuses an existing artefact so a rebuild of the channel is cheap."""
    src = os.path.join(ROOT, "user", cmd + ".ad")
    if not os.path.exists(src):
        return None
    out = os.path.join(objdir, cmd + ".elf")
    if os.path.exists(out) and os.path.getmtime(out) > os.path.getmtime(src):
        return out
    rc = subprocess.call(
        [os.path.join(ROOT, "scripts/hamlinux_build.sh"), src, out]
        + EXTRA_OBJS.get(cmd, []),
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
        [os.path.join(ROOT, "scripts/hamlinux_build.sh"), src, out, shim,
         "-ldl"],
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
        for host, inside in files:
            dest = os.path.join(top, "files", inside)
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            shutil.copy2(host, dest)
            if inside.startswith("bin/"):
                os.chmod(dest, 0o755)
        for hook_name, body in sorted((hooks or {}).items()):
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
        with tarfile.open(tarpath, "w:gz", compresslevel=9,
                          format=tarfile.GNU_FORMAT) as tf:
            def norm(ti):
                ti.uid = ti.gid = 0
                ti.uname = ti.gname = "root"
                ti.mtime = 0
                return ti
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
    args = ap.parse_args()

    out = os.path.join(ROOT, args.out, args.channel)
    pkgdir = os.path.join(out, "packages")
    objdir = os.path.join(ROOT, "build/repo-obj")
    os.makedirs(pkgdir, exist_ok=True)
    os.makedirs(objdir, exist_ok=True)

    entries = []
    skipped = []

    # Components first: they carry the boot files everything else needs.
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
        entries.append(write_pkg(pkgdir, name, args.version, desc, files, deps))
        print("  %s (%d files)" % (name, len(files)))

    # The GPU stack, userspace first: the kernel driver packages declare a
    # dependency on the matching ICD, so the userspace half has to be built
    # before we know whether that dependency can be honoured.
    vk_built = build_vulkan_packages(pkgdir, args.version, entries, skipped)

    # GPU drivers. Not in hamnix-base: which one a machine wants depends on
    # the machine, and installing the wrong one wastes 10 MiB of RAM disk.
    build_driver_packages(pkgdir, args.version, entries, skipped, vk_built)

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
    entries.append(write_pkg(
        pkgdir, "hamnix-base", args.version,
        "hamnix-linux base system -- init, shell, coreutils, networking, "
        "package manager and desktop",
        [], ["hamnix-init>=1", "hamnix-hamsh>=1", "hamnix-coreutils>=1",
             "hamnix-net>=1", "hpm>=1", "hamnix-desktop>=1"]))

    for e in entries:
        e["channel"] = args.channel

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

    print("\n%d packages -> %s" % (len(entries), out))
    if skipped:
        # Say what is NOT in the channel. A package manager whose repository
        # quietly lacks half the system is worse than one that admits it.
        print("not packaged (%d): %s" % (len(skipped), " ".join(skipped)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
