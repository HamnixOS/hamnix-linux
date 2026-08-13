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
for root in ("zenity", "yad", "firefox-esr"):
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
    # KEPT AFTER THE SWAP, deliberately: this row reads 0.0 MiB on an image
    # built from the current hamlinux_distro.sh, and a row that says zero is
    # how a regression announces itself. If a dependency ever drags WebKit
    # back in, this line goes non-zero instead of hiding inside "everything
    # else". The dialog is now yad, which is 0.6 MiB and lives under GTK.
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

# ---- 3. IS THE 32-BIT HALF LOAD-BEARING? ---------------------------------
# The section above prices the second copies; this one asks whether anything
# in there is reachable only by a path nothing takes.  It answers with three
# statements that are NOT ours -- Debian's steam-libs Depends, Debian's
# steam-libs Recommends, and Valve's own steamdeps.txt out of the bootstrap
# tarball staged in the image -- so "load-bearing" is a citation rather than
# an opinion.  Everything an i386 package is reached from is computed from
# the image's own Depends graph, arch-qualified: a dependency of an i386
# package resolves to :i386 unless it names another arch, which is what makes
# libllvm15:i386 (122 MiB, the single largest 32-bit item) attach to
# libgl1-mesa-dri:i386 rather than look like a stray second copy.
DETAIL="${HAMLINUX_AUDIT_I386_DETAIL:-0}" \
DISTRO_SH="$PROJ_ROOT/scripts/hamlinux_distro.sh" \
python3 - "$WORK/status" <<'PY'
import collections, os, re, sys

blocks = open(sys.argv[1], encoding="utf8", errors="replace").read().split("\n\n")
pkgs = {}
for blk in blocks:
    if not blk.strip():
        continue
    f, key = {}, None
    for line in blk.split("\n"):
        if line[:1] in (" ", "\t"):
            if key:
                f[key] += " " + line.strip()
            continue
        if ":" in line:
            key, _, v = line.partition(":")
            key = key.strip(); f[key] = v.strip()
    if f.get("Package"):
        pkgs[(f["Package"], f.get("Architecture", ""))] = f

byname = collections.defaultdict(list)
for (n, a) in pkgs:
    byname[n].append(a)
provides = collections.defaultdict(list)
for (n, a), f in pkgs.items():
    for p in f.get("Provides", "").split(","):
        p = p.strip()
        if p:
            provides[p.split("(")[0].strip().split(":")[0]].append((n, a))

def resolve(dep, from_arch):
    d = dep.strip().split("(")[0].strip()
    if not d:
        return []
    arch = None
    if ":" in d:
        d, arch = d.split(":", 1)
        if arch == "any":
            arch = None
    if arch:
        return [(d, arch)] if (d, arch) in pkgs else []
    for a in (from_arch, "all", "amd64"):
        if (d, a) in pkgs:
            return [(d, a)]
    if d in byname:
        return [(d, byname[d][0])]
    if d in provides:
        pr = [c for c in provides[d] if c[1] in (from_arch, "all")] or provides[d]
        return [pr[0]]
    return []

def deps_of(key):
    res = []
    for fld in ("Depends", "Pre-Depends"):
        for clause in pkgs[key].get(fld, "").split(","):
            if not clause.strip():
                continue
            got = []
            for alt in clause.split("|"):
                got = resolve(alt, key[1])
                if got:
                    break
            res.extend(got)
    return res

edges = {k: deps_of(k) for k in pkgs}

# The roots: what hamlinux_distro.sh asks for BY NAME, arch qualifier kept.
src = open(os.environ["DISTRO_SH"]).read()
rootkeys, missing = set(), []
for m in re.finditer(r'PKGS="([^"]*)"', src, re.S):
    for p in m.group(1).replace("\\\n", "").split(","):
        p = p.strip()
        if not p or p.startswith("$"):
            continue
        if ":" in p:
            n, a = p.split(":", 1)
            (rootkeys.add((n, a)) if (n, a) in pkgs else missing.append(p))
        else:
            for a in ("amd64", "all"):
                if (p, a) in pkgs:
                    rootkeys.add((p, a)); break
            else:
                missing.append(p)

def size(k):
    return int(pkgs[k].get("Installed-Size", "0") or 0)

def closure(seeds):
    seen, stack = set(), list(seeds)
    while stack:
        k = stack.pop()
        if k in seen or k not in pkgs:
            continue
        seen.add(k)
        stack.extend(edges.get(k, []))
    return seen

i386 = sorted(k for k in pkgs if k[1] == "i386")
tot = sum(size(k) for k in i386) / 1024.0
print()
print("=== IS THE 32-BIT HALF LOAD-BEARING? ===")
if missing:
    print("  (named but not installed: %s)" % " ".join(missing))

# a) Debian's own answer: steam-installer's transitive Depends.
steam = [k for k in pkgs if k[0].startswith("steam")]
sclos = closure(steam)
si = [k for k in sclos if k[1] == "i386"]
print("  Debian's own closure (steam-installer Depends*) : %6.1f MiB, %3d pkgs"
      % (sum(size(k) for k in si) / 1024.0, len(si)))

# b) what is left over, and whether anyone declared it.
sl = pkgs.get(("steam-libs", "i386"), {})
declared = set()
for fld in ("Depends", "Recommends"):
    for clause in sl.get(fld, "").split(","):
        for alt in clause.split("|"):
            n = alt.strip().split("(")[0].strip().split(":")[0]
            if n:
                declared.add(n)
# Valve's own steamdeps.txt, i386 section, from the staged bootstrap tarball.
declared |= {"libgl1-mesa-dri", "libgl1-mesa-glx", "libc6"}
i386_roots = sorted(k for k in rootkeys if k[1] == "i386")
elective = [k for k in i386_roots if k[0] not in declared]
keep = closure([r for r in rootkeys if r not in set(elective)])
gone = [k for k in i386 if k not in keep]
gmb = sum(size(k) for k in gone) / 1024.0
print("  declared by Debian steam-libs or Valve steamdeps : %6.1f MiB, %3d pkgs"
      % (tot - gmb, len(i386) - len(gone)))
print("  OURS, declared by neither                        : %6.1f MiB, %3d pkgs  (%.1f%%)"
      % (gmb, len(gone), 100.0 * gmb / tot if tot else 0))
print("    roots: %s" % " ".join(sorted(e[0] for e in elective)))
print("    drops: %s" % " ".join(sorted(g[0] for g in gone)))
print("  (mesa-utils:i386 and vulkan-tools:i386 are inside that residue and are")
print("   NOT spare: tests/linux/steam_probe.sh runs glxgears and vulkaninfo to")
print("   prove the 32-bit stack resolves at all.)")

if os.environ.get("DETAIL") == "1":
    rootreach = {}
    for r in sorted(rootkeys):
        for k in closure([r]):
            rootreach.setdefault(k, set()).add(r)
    print()
    print("  --- every i386 package and the named root(s) that reach it ---")
    for k in sorted(i386, key=lambda k: -size(k)):
        rs = sorted(rootreach.get(k, []))
        print("  %-30s %8.1f MiB  <- %s"
              % (k[0], size(k) / 1024.0,
                 ",".join("%s:%s" % r for r in rs) or "*** NOTHING NAMED REACHES THIS ***"))
PY

# ---- 4. WHAT A DOWNLOAD ACTUALLY COSTS -----------------------------------
# The number everyone argues about is the provisioned one, and it is the only
# number nobody ever transfers.  This measures the artefact instead of the
# hole: the image through a real compressor, and -- separately -- the same
# compressor fed exactly as many zero bytes as this filesystem has free
# blocks, which is the share of that download the PROVISIONING is responsible
# for.  Measured rather than asserted, because "zeros compress away" is the
# kind of claim that is true until a format change makes it not.
#
# It reads 12 GiB through four cores and takes about half a minute, so it is
# opt-in: HAMLINUX_AUDIT_DOWNLOAD=1.  Still never writes anything -- the
# compressor's output goes to `wc -c`, not to a file.
if [ "${HAMLINUX_AUDIT_DOWNLOAD:-0}" = 1 ]; then
    echo
    echo "=== WHAT A DOWNLOAD WOULD COST ==="
    if ! command -v zstd >/dev/null 2>&1; then
        echo "  (need zstd to measure this)"
    else
        ZL="${HAMLINUX_AUDIT_ZLEVEL:-12}"
        ZT="${HAMLINUX_AUDIT_ZTHREADS:-4}"
        CMP="$(zstd -T"$ZT" -"$ZL" -c "$IMG" 2>/dev/null | wc -c)"
        FREEB="$(awk -F: '/^Free blocks:/{gsub(/ /,"",$2);print $2}' "$WORK/sb")"
        BSZ="$(awk -F: '/^Block size:/{gsub(/ /,"",$2);print $2}' "$WORK/sb")"
        HOLE=0
        if [ -n "$FREEB" ] && [ -n "$BSZ" ]; then
            HOLE="$(head -c "$((FREEB * BSZ))" /dev/zero | zstd -T"$ZT" -"$ZL" -c 2>/dev/null | wc -c)"
        fi
        python3 - "$(stat -c%s "$IMG")" "$CMP" "$HOLE" "$ZL" <<'PY'
import sys
raw, cmp_, hole, zl = (int(x) for x in sys.argv[1:5])
print("  provisioned file        : %8.2f GiB" % (raw / 2**30))
print("  zstd -%-2d                : %8.1f MiB   <- what a person would transfer" % (zl, cmp_ / 2**20))
print("  of which the empty space: %8.1f MiB   (%.2f%% of the download)"
      % (hole / 2**20, 100.0 * hole / cmp_ if cmp_ else 0))
print()
print("  So the provisioned size is not a download cost: shrinking the file to fit")
print("  its contents would return %.0f KiB of a %.0f MiB transfer."
      % (hole / 1024.0, cmp_ / 2**20))
PY
    fi
    echo "  (and nothing published contains this file at all -- 255.one serves hpm"
    echo "   .tar.gz packages, and the installer medium carries a busybox-minimal"
    echo "   live tree built by scripts/build_rootfs_img.py, not this image.)"
fi
