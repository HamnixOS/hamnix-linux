#!/usr/bin/env python3
"""scripts/hpm_installed_db.py -- write /var/lib/hpm/installed.json for a root
that was STAGED rather than installed package by package.

WHY THIS EXISTS.  `hpm update` on a freshly installed machine was a no-op, and
it exited 0 while doing nothing.  The index authenticated over TLS -- 126
packages, signature checked against the shipped trust root -- and then nothing
upgraded, because /var/lib/hpm was an empty directory.  hpm had no record of
what is on the disk, so it had nothing to compare against and reported success
having done nothing.  That is the owner's permanent invariant ("work published
here must be updatable ON the machine") failing on the one path that makes it
true: boot the USB, install, reboot, update.

WHY THE DATABASE IS NOT MERELY SEEDED WITH A PLAUSIBLE FILE LIST.  hpm upgrades
by REMOVING the old version and installing the new one, and the remove unlinks
every path the database records (user/hpm.ad, cmd_remove: "Delete files in
REVERSE install order").  A wrong or approximate list makes the FIRST UPGRADE
DELETE THE WRONG FILES on a machine the owner is standing in front of.  An
installed.json that is merely plausible is worse than none: none fails loudly,
and a wrong one destroys a working system quietly.

SO THE LISTS ARE NOT RECONSTRUCTED.  They are read back out of the package
TARBALLS -- the same bytes hpm itself unpacks -- and they are filtered by
exactly the rules hpm applies when it records a file, which are not obvious and
are all in user/hpm.ad's _stage_extract_files:

  * only entries under "<name>-<version>/files/" are laid down at all;
  * only REGULAR files are recorded (typeflag '\\0' or '0').  Directory
    entries are mkdir'd and never recorded; anything else is skipped with a
    warning.  So a directory in this list would be a path hpm would try to
    unlink and cannot;
  * a MACHINE-OWNED path is neither written nor claimed when it already
    exists.  Today that list is exactly "etc/rc.boot" (_is_machine_owned), and
    it is the file whose deletion during an upgrade left a measured machine
    with no boot script at all.  A database that claimed it would re-create
    that brick on the first update.

AND A PACKAGE IS ONLY RECORDED IF THE ROOT REALLY CARRIES IT.  Every file the
tarball holds must exist under the staged root; one missing file and the
package is left OUT, by name, with a reason printed.  "Installed" has to mean
installed -- a channel carries GPU drivers and firmware that no image stages,
and claiming those would have hpm remove-then-install packages the machine
never had.

THE CALLERS.  scripts/hamlinux_disk.sh runs this against the exact directory it
is about to mkfs, which is the strongest available statement: the database
describes the tree it ships inside, not a tree upstream of it.
scripts/hamlinux_packages.py can run it too (--installed-db) so a channel build
can check its own emission against a root without building a disk.

Usage:
    scripts/hpm_installed_db.py <channel-dir> <root-dir> <out.json>

<channel-dir> is a built channel: index.json + packages/*.tar.gz.
"""

import json
import os
import sys
import tarfile

# hpm's own limits, from user/hpm.ad.  Exceeding any of them is a refusal here
# rather than a failure on the machine.
INSTALLED_CAP = 131072     # INSTALLED_CAP: the read buffer AND rewrite_buf
INST_MAX = 256             # the inst_* tables
FILE_MAX = 8192            # inst_file_off / inst_file_len

# user/hpm.ad:_is_machine_owned.  Keep in step with it: an entry here that hpm
# does not know about would be deleted by an upgrade, and an entry hpm has that
# is missing here would be claimed by a package that never wrote it.
MACHINE_OWNED = ("etc/rc.boot",)


def package_files(channel_dir, name, version):
    """The relative paths hpm WOULD record for this package, read out of the
    tarball hpm itself downloads.  Returns (files, skipped_nonregular)."""
    tarpath = os.path.join(channel_dir, "packages",
                           "%s-%s.tar.gz" % (name, version))
    prefix = "%s-%s/files/" % (name, version)
    files = []
    skipped = []
    with tarfile.open(tarpath, "r:gz") as tf:
        for ti in tf:
            if not ti.name.startswith(prefix):
                continue
            rel = ti.name[len(prefix):]
            if not rel:
                continue
            if ti.isdir():
                continue                      # mkdir'd, never recorded
            if not ti.isfile():
                skipped.append(rel)           # hpm warns and skips these
                continue
            files.append(rel)
    return files, skipped


def render(packages):
    """Serialise in the BYTE-FOR-BYTE shape user/hpm.ad writes, so the file the
    machine ships with is indistinguishable from one hpm wrote itself and the
    size measured here is the size hpm's rewrite_buf will need."""
    out = ['{\n  "schema": 1,\n  "packages": [\n']
    parts = []
    for name, version, target, files in packages:
        parts.append(
            '    {\n      "name": "%s",\n      "version": "%s",\n'
            '      "installed_at": "",\n      "pinned": false,\n'
            '      "target": "%s",\n      "files": [%s]\n    }'
            % (name, version, target,
               ", ".join('"%s"' % f for f in files)))
    out.append(",\n".join(parts))
    out.append("\n  ]\n}\n")
    return "".join(out)


def build(channel_dir, root_dir, log=print):
    index = json.load(open(os.path.join(channel_dir, "index.json")))
    included = []
    excluded = []
    nonregular = []
    for e in index["packages"]:
        name, version = e["name"], e["version"]
        files, skipped = package_files(channel_dir, name, version)
        for rel in skipped:
            nonregular.append((name, rel))
        missing = [f for f in files
                   if not os.path.lexists(os.path.join(root_dir, f))]
        if missing:
            excluded.append((name, len(files), len(missing), missing[:2]))
            continue
        recorded = [f for f in files if f not in MACHINE_OWNED]
        included.append((name, version, e.get("target", "#hamnix-system"),
                         recorded))

    # NO FILE MAY BE CLAIMED TWICE.  An upgrade of one package unlinks every
    # path it claims, so a path two packages both claim is a path the FIRST
    # upgrade deletes out from under the second.  Refusing here is the whole
    # point of building the lists from the tarballs: it is a fact about the
    # channel, checkable before anything ships.
    claimed = {}
    for name, _v, _t, files in included:
        for f in files:
            claimed.setdefault(f, []).append(name)
    collided = sorted(f for f, ns in claimed.items() if len(ns) > 1)
    if collided:
        raise SystemExit(
            "hpm_installed_db: REFUSING to write a database in which %d "
            "path(s) are claimed by more than one package:\n%s\n"
            "hpm upgrades by removing the old version's recorded files and "
            "installing the new one, so the first upgrade of either package "
            "would delete a file the other one owns."
            % (len(collided),
               "\n".join("    %s <- %s" % (f, " ".join(claimed[f]))
                         for f in collided[:20])))

    text = render(included)
    nfiles = sum(len(f) for _n, _v, _t, f in included)
    if len(included) > INST_MAX:
        raise SystemExit("hpm_installed_db: %d packages, over hpm's %d-package "
                         "table" % (len(included), INST_MAX))
    if nfiles > FILE_MAX:
        raise SystemExit("hpm_installed_db: %d files, over hpm's %d-entry file "
                         "table (inst_file_off)" % (nfiles, FILE_MAX))
    if len(text) >= INSTALLED_CAP:
        raise SystemExit(
            "hpm_installed_db: the database is %d bytes, at or over hpm's "
            "%d-byte INSTALLED_CAP. hpm would read a TRUNCATED file and its "
            "rewrite_buf could not serialise the result."
            % (len(text), INSTALLED_CAP))

    log("[installed-db] %d of %d packages are on this root (%d files, %d bytes"
        " / cap %d)" % (len(included), len(index["packages"]), nfiles,
                        len(text), INSTALLED_CAP))
    if excluded:
        log("[installed-db] NOT on this root, so NOT recorded as installed "
            "(%d):" % len(excluded))
        for name, tot, nm, ex in excluded:
            log("[installed-db]   %-28s %d of %d files absent, e.g. %s"
                % (name, nm, tot, " ".join(ex)))
    for name, rel in nonregular:
        log("[installed-db] %s: %s is not a regular file; hpm would skip it "
            "and so does this" % (name, rel))
    return text, included, excluded


def main(argv):
    if len(argv) != 4:
        sys.stderr.write(__doc__.rsplit("Usage:", 1)[-1])
        return 2
    channel_dir, root_dir, out = argv[1], argv[2], argv[3]
    if not os.path.exists(os.path.join(channel_dir, "index.json")):
        sys.stderr.write("hpm_installed_db: no index.json in %s\n" % channel_dir)
        return 1
    if not os.path.isdir(root_dir):
        sys.stderr.write("hpm_installed_db: not a directory: %s\n" % root_dir)
        return 1
    text, _inc, _exc = build(channel_dir, root_dir)
    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    with open(out, "w") as fh:
        fh.write(text)
    print("[installed-db] wrote %s" % out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
