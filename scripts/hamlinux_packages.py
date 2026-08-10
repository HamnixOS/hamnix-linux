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
import hashlib
import json
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

NET_CMDS = "ifconfig route ping host curl wget".split()

DESKTOP_CMDS = ("wsysd hamdesktop hampanelscene hamtermscene hameditscene "
                "hamsettings hamfm hamUI hamUId").split()

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
    "hamnix-desktop": (
        "hamnix-linux desktop -- the scene compositor and the DE clients",
        [(c, "bin/" + c) for c in DESKTOP_CMDS],
        [("etc/panel.conf", "etc/panel.conf"),
         ("etc/desktop.icons", "etc/desktop.icons")],
        ["hamnix-init>=1", "hamnix-hamsh>=1"]),
}


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
        [os.path.join(ROOT, "scripts/hamlinux_build.sh"), src, out],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=ROOT)
    return out if rc == 0 else None


def write_pkg(outdir, name, version, description, files, depends,
              target="#hamnix-system"):
    """files: list of (host path, path inside the installed tree)."""
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
        info = ["name: %s" % name,
                "version: %s" % version,
                "arch: x86_64",
                "description: %s" % description]
        if depends:
            info.append("depends: %s" % ", ".join(depends))
        info.append("target: %s" % target)
        info.append("maintainer: HamnixOS")
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
