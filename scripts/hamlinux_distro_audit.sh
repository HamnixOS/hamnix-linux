#!/usr/bin/env bash
# scripts/hamlinux_distro_audit.sh — WHAT IS ACTUALLY IN distro.ext4, AND WHY
# IS IT 12 GB?
#
# The owner asked that question a long time ago and never got a proper answer;
# the standing list has carried single items ("zenity is 121 MiB of dead code")
# without anyone knowing whether they were the largest thing in there or the
# first one somebody happened to notice. This answers it with numbers, and it
# is a script rather than a paragraph so the answer can be taken again after
# the next package-list change instead of ageing quietly in a document.
#
# IT NEVER WRITES, MOUNTS OR REBUILDS ANYTHING. The image is read with
# debugfs(8), which reads an ext4 filesystem out of a plain file without a
# loop device, a mount, or privileges -- so this is safe to run against a
# build/image/distro.ext4 that another agent is using, and it cannot be the
# thing that rebuilds a 12 GB artefact in place.
#
# THE TWO NUMBERS PEOPLE CONFLATE, separated in the first section:
#   * the SIZE OF THE FILE, which is whatever it was provisioned at;
#   * the BYTES ACTUALLY OCCUPIED inside it.
# The file is sparse, so `ls -l` and `du` disagree by ~10 GB and both are
# right. A reduction pass that moves the second one does not move the first,
# and vice versa -- and only one of them is about what is installed.
#
# Usage: scripts/hamlinux_distro_audit.sh [image] [top-N]
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMG="${1:-$PROJ_ROOT/build/image/distro.ext4}"
TOPN="${2:-25}"
DEBUGFS="${DEBUGFS:-/usr/sbin/debugfs}"
DUMPE2FS="${DUMPE2FS:-/usr/sbin/dumpe2fs}"
command -v "$DUMPE2FS" >/dev/null 2>&1 || DUMPE2FS=dumpe2fs

[ -f "$IMG" ] || { echo "no image at $IMG" >&2; exit 1; }
command -v "$DEBUGFS" >/dev/null 2>&1 || { echo "need debugfs(8) from e2fsprogs (set \$DEBUGFS)" >&2; exit 1; }
command -v python3 >/dev/null || { echo "need python3" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/distroaudit.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ---- 1. the filesystem itself -------------------------------------------
echo "=== THE FILE, AND WHAT IS IN IT ==="
# sbin, not PATH: dumpe2fs lives in /usr/sbin and an ordinary user's PATH does
# not include it, which made the whole first section silently print
# "could not read the superblock" -- the two numbers this script exists to
# separate, missing, while everything after them looked fine.
"$DUMPE2FS" -h "$IMG" >"$WORK/sb" 2>/dev/null
BS="$(awk -F: '/^Block size:/{gsub(/ /,"",$2);print $2}' "$WORK/sb")"
BC="$(awk -F: '/^Block count:/{gsub(/ /,"",$2);print $2}' "$WORK/sb")"
FB="$(awk -F: '/^Free blocks:/{gsub(/ /,"",$2);print $2}' "$WORK/sb")"
if [ -n "$BS" ] && [ -n "$BC" ] && [ -n "$FB" ]; then
    python3 - "$BS" "$BC" "$FB" "$(stat -c%s "$IMG")" "$(du -B1 "$IMG" 2>/dev/null | cut -f1)" <<'PY'
import sys
bs, bc, fb = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
stat_size, allocated = int(sys.argv[4]), int(sys.argv[5] or 0)
used = (bc - fb) * bs
print("  provisioned filesystem : %8.2f GiB   (what `ls -l` reports)" % (stat_size/2**30))
print("  actually occupied      : %8.2f GiB   (%.0f%% of the filesystem is empty)"
      % (used/2**30, 100.0*fb/bc))
print("  blocks on the host disk: %8.2f GiB   (sparse: `du` -- this is what it really costs)"
      % (allocated/2**30))
print()
print("  So \"why is it 12 GB\" has two answers and only one of them is about packages:")
print("  the FILE was provisioned at %.0f GiB, and %.2f GiB of software was installed into it."
      % (stat_size/2**30, used/2**30))
PY
else
    echo "  (dumpe2fs could not read the superblock)"
fi

# ---- 2. what dpkg says is installed --------------------------------------
"$DEBUGFS" -R "dump /var/lib/dpkg/status $WORK/status" "$IMG" >/dev/null 2>&1
[ -s "$WORK/status" ] || { echo "could not read /var/lib/dpkg/status out of $IMG" >&2; exit 1; }

# The package names this project ASKS FOR by name. A package on this list is a
# deliberate root, so it must never be reported as "freed if X goes" -- which
# is the mistake the first version of this made, counting bubblewrap (a Steam
# sandbox requirement we install on purpose) as part of zenity's closure.
# PKGS IS ASSIGNED TWICE -- a base list and an i386/Steam extension that
# appends to it -- and reading only the first made bubblewrap, zenity and
# xdg-utils look like anonymous dependencies instead of things this project
# asks for on purpose. bubblewrap then showed up inside "what zenity costs",
# which is exactly the over-claim this exclusion list exists to prevent.
awk '/PKGS="/ {inb=1} inb {print; if ($0 !~ /\\$/) inb=0}' \
    "$PROJ_ROOT/scripts/hamlinux_distro.sh" |
    tr -d '\\\n"' | tr ',' '\n' | sed 's/.*PKGS=//; s/\$PKGS//' |
    sed 's/:.*//' | grep -E '^[a-z0-9.+-]+$' | sort -u > "$WORK/roots"

TOPN="$TOPN" ROOTS="$WORK/roots" python3 - "$WORK/status" <<'PY'
import collections, os, re, sys
txt = open(sys.argv[1], encoding="utf-8", errors="replace").read()
roots = set()
try:
    roots = {l.strip() for l in open(os.environ["ROOTS"]) if l.strip()}
except OSError:
    pass
pkgs = []
for block in txt.split("\n\n"):
    if not block.strip():
        continue
    f, key = {}, None
    for line in block.split("\n"):
        if line.startswith(" ") and key:
            f[key] += " " + line.strip()
        elif ":" in line:
            key, _, v = line.partition(":")
            f[key] = v.strip()
    if "Package" in f:
        pkgs.append(f)

def size(p):
    try: return int(p.get("Installed-Size", "0"))
    except ValueError: return 0

by_name = collections.defaultdict(list)
for p in pkgs:
    by_name[p["Package"]].append(p)
total = sum(size(p) for p in pkgs)
def mib(kib): return kib / 1024.0

print()
print("=== THE PACKAGES (%d of them, %.2f GiB by dpkg's own Installed-Size) ===" %
      (len(pkgs), total / 2**20))
print("%-44s %9s  %s" % ("PACKAGE", "MiB", "ARCH"))
for p in sorted(pkgs, key=size, reverse=True)[:int(os.environ.get("TOPN", 25))]:
    print("%-44s %9.1f  %s" % (p["Package"], mib(size(p)), p.get("Architecture", "?")))

rdep = collections.defaultdict(set)
for p in pkgs:
    for fld in ("Depends", "Pre-Depends"):
        for d in p.get(fld, "").split(","):
            d = d.strip()
            if d:
                rdep[d.split()[0].split(":")[0]].add(p["Package"])

def attributable(root):
    """Packages that exist ONLY because `root` does: reachable from it, not a
    deliberate root of ours, and with no installed reverse-dependency outside
    the set. Deliberately conservative -- it is a floor, not a guess."""
    seen, frontier = set(), [root]
    while frontier:
        n = frontier.pop()
        if n in seen or n not in by_name:
            continue
        seen.add(n)
        for p in by_name[n]:
            for fld in ("Depends", "Pre-Depends"):
                for d in p.get(fld, "").split(","):
                    d = d.strip()
                    if not d:
                        continue
                    dn = d.split()[0].split(":")[0]
                    if dn in by_name and dn not in roots and rdep[dn] <= seen | {n}:
                        frontier.append(dn)
    return seen

print()
print("=== WHAT ONE PACKAGE REALLY COSTS ===")
print("(its own size plus everything installed that nothing else depends on,")
print(" excluding packages this project asks for by name in hamlinux_distro.sh)")
for root in ("zenity", "firefox-esr"):
    if root not in by_name:
        continue
    c = attributable(root)
    s = sum(size(p) for n in c for p in by_name[n])
    own = sum(size(p) for p in by_name[root])
    print("  %-14s itself %6.1f MiB, with its private closure %7.1f MiB  (%d packages)"
          % (root, mib(own), mib(s), len(c)))
    for n in sorted(c, key=lambda n: -sum(size(p) for p in by_name[n]))[:6]:
        if n != root:
            print("      %-38s %7.1f MiB" % (n, mib(sum(size(p) for p in by_name[n]))))

GROUPS = [
    ("LLVM / clang toolchain",  r"^(libllvm|libclang|llvm|clang|libz3)"),
    ("Firefox",                 r"^firefox"),
    ("Mesa / graphics drivers", r"^(mesa-|libgl|libegl|libgbm|libvulkan|libdrm|libglx)"),
    ("zenity's WebKit engine",  r"^(zenity|libwebkit|libjavascriptcore)"),
    ("Media codecs",            r"^(libav|libx26|libcodec2|libmfx|libvpx|libflite|gstreamer)"),
    ("GTK / GNOME stack",       r"^(libgtk|libgdk|adwaita|libpango|libatk|gtk-)"),
    ("Perl",                    r"^(perl|libperl)"),
]
print()
print("=== BY THEME ===")
claimed, rows = set(), []
for label, rx in GROUPS:
    r, s = re.compile(rx), 0
    for n, ps in by_name.items():
        if r.match(n) and n not in claimed:
            claimed.add(n); s += sum(size(p) for p in ps)
    rows.append((s, label))
for s, label in sorted(rows, reverse=True):
    print("  %-28s %8.1f MiB  (%4.1f%%)" % (label, mib(s), 100.0*s/total))
rest = total - sum(s for s, _ in rows)
print("  %-28s %8.1f MiB  (%4.1f%%)" % ("everything else (%d pkgs)" % (len(by_name)-len(claimed)), mib(rest), 100.0*rest/total))

i386 = [p for p in pkgs if p.get("Architecture") == "i386"]
print()
print("=== 32-BIT DUPLICATION (what Steam costs in second copies) ===")
print("  %d i386 packages, %.1f MiB (%.1f%% of the content)" %
      (len(i386), mib(sum(size(p) for p in i386)), 100.0*sum(size(p) for p in i386)/total))
PY
