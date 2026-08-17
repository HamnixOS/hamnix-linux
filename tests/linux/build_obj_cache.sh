#!/usr/bin/env bash
# Its host runtime and its pass/fail were NOT measured when this line was
# written. If you make it cheap enough for the battery, add the manifest line
# and delete this block.
#
# tests/linux/build_obj_cache.sh -- ONE TREE'S OBJECTS MUST NEVER BE LINKED
# INTO ANOTHER TREE'S BINARIES.
#
# THE GAP THIS CLOSES
# ===================
# scripts/hamlinux_build.sh compiles the eight runtime objects -- the Linux
# link runtime and the seven device servers, /dev/wsys among them -- once and
# caches them. It used to cache them under ONE FIXED NAME PER OBJECT IN THE
# OUTPUT DIRECTORY:
#
#     RT_OBJ="$OUT_DIR/.linux-runtime.o"
#     WS_OBJ="$OUT_DIR/.linux-wsys.o"
#     …
#
# and rebuild one when its `.c` was NEWER than the object (`-nt`). Both halves
# are wrong, and together they are a mechanism this project has already paid
# for.
#
#   * The name says nothing about WHICH TREE the object came from. Two
#     checkouts building into one output directory -- two agents' worktrees, a
#     bisect, a gate handed the same $WORK twice -- share one
#     `.linux-wsys.o`, so the FIRST tree's window system is linked into the
#     SECOND tree's binaries.
#
#   * mtime is not identity. Two files can share one to the nanosecond; a
#     checkout hands old content a new timestamp; and `-nt` is false when they
#     are equal, so an edit inside a single filesystem tick is missed. In the
#     shared-directory case above the object is simply newer than the second
#     tree's source -- which is what happens whenever the OLDER WORKTREE
#     builds SECOND -- and the second tree is served the first tree's bytes.
#
# Nothing about that is loud. Every filename matches, every sha256 matches,
# every dependency resolves, the build prints `built …` and exits 0. It is the
# NORTH_STAR failure exactly: a success-shaped answer instead of the truth.
#
# It has landed twice. hamnix-desktop 1.0.10 shipped a desktop that mapped NO
# WINDOWS because a stale cached object was packaged -- the packager lane,
# fixed since by `newest_shared_input()` in scripts/hamlinux_packages.py. And
# an agent building a negative control got a `wsysd` that reported wsys
# segment version FIVE out of a version SEVEN tree, because another tree had
# been built into the same directory first -- the gate lane, which is the one
# this file is about, and which is the more dangerous of the two now that
# agents work in parallel worktrees.
#
# WHAT THIS GATE MEASURES, AND WHY THE TELL IS THE SEGMENT VERSION
# ================================================================
# It builds TWO TREES INTO ONE OUTPUT DIRECTORY and then asks the SECOND
# tree's binary, at run time, whose window system it is carrying.
#
# `#define WSYS_VERSION` in user/linux-wsys.c is the ideal discriminator. It
# lives in one of the cached objects and nowhere else -- not in wsysd.ad, not
# in any header -- so a binary's version is decided entirely by WHICH
# `.linux-wsys.o` was linked into it. And it is READABLE FROM OUTSIDE the
# program with no cooperation from it: `struct wshm` opens { uint32 magic,
# version; … }, a prefix user/linux-wsys.c documents as byte-for-byte
# identical across v5, v6 and v7, so 24 bytes of a plain file read off
# $HAMWSYS answers the question. That read attaches to nothing and cannot
# perturb what it is looking at.
#
# So: tree A is this tree with WSYS_VERSION moved down by two, tree B is this
# tree unmodified. Build A into the shared directory, then B, then RUN B's
# compositor and read the version it wrote. B must report B's number. Under
# the defect it reports A's.
#
# THE TREES ARE SYMLINK FARMS, not copies. Every entry is a symlink to this
# checkout except `user/`, which is a directory of symlinks with exactly one
# real file in it -- the tree's own linux-wsys.c. So the two trees differ in
# ONE FILE and are otherwise the same bytes, which is the cleanest possible
# statement of the question: nothing here can be explained by the trees being
# generally different.
#
# ASSERTION 5 IS THE ONE THAT MAKES SHARING SAFE RATHER THAN FORBIDDEN. A
# third tree, byte-identical to B but at a DIFFERENT PATH, must produce NO new
# object at all -- it must hit B's cache entry. That is the difference between
# keying on content and keying on a path: a path key would be correct here and
# would also make every worktree recompile the runtime from scratch forever.
#
# Entirely offscreen: HAMFB_FILE for the framebuffer, an empty evdev file for
# input (so the compositor opens no real device on this host), the software
# Vulkan ICD. No VM, no display, no GPU.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

# wsysd reaches /srv/wsys and /dev/shm/hamnix-wsys by names compiled into
# user/linux-wsys.c, which no care taken here can move. Run inside a mount
# namespace where /tmp, /dev/shm and /srv are this run's alone -- see
# tests/linux/private_ns.sh for what a gate writing a host-global name cost.
. tests/linux/private_ns.sh
priv_ns_reexec "$@"
. tests/linux/reap.sh

WORK="${OBJCACHE_WORK:-$(mktemp -d -p "${TMPDIR:-/tmp}" objcache.XXXXXX)}"
mkdir -p "$WORK"
KEEP="${OBJCACHE_KEEP:-0}"
reap_track "$WORK/reaped"

pass=0; fail=0
ok()   { echo "objcache: PASS $*"; pass=$((pass+1)); }
bad()  { echo "objcache: FAIL $*"; fail=$((fail+1)); }
info() { echo "objcache: INFO $*"; }
cleanup() { [ "$KEEP" = 1 ] || rm -rf "$WORK"; }
reap_on_exit cleanup
done_report() { echo "objcache: $pass passed, $fail failed"; [ "$fail" = 0 ]; }

export HAMFB_GEOM="${HAMFB_GEOM:-640x480}"
FBW="${HAMFB_GEOM%x*}"; FBH="${HAMFB_GEOM#*x}"
[ -r /usr/share/vulkan/icd.d/lvp_icd.json ] && \
    export VK_ICD_FILENAMES="${VK_ICD_FILENAMES:-/usr/share/vulkan/icd.d/lvp_icd.json}"

# ---- the discriminator ----------------------------------------------------
TREE_VER="$(sed -n 's/^#define[[:space:]]\+WSYS_VERSION[[:space:]]\+\([0-9]\+\).*/\1/p' \
            user/linux-wsys.c | head -1)"
case "$TREE_VER" in
    ''|*[!0-9]*)
        bad "user/linux-wsys.c has no '#define WSYS_VERSION <n>' -- this gate's whole tell is that constant, and it cannot proceed without it"
        done_report; exit 1;;
esac
OLD_VER=$((TREE_VER - 2))
[ "$OLD_VER" -ge 1 ] || OLD_VER=1
info "this tree is wsys v$TREE_VER; the decoy tree will be v$OLD_VER"

# ---- the two trees --------------------------------------------------------
# mktree <dir> <wsys-version> -- a symlink farm over $PROJ_ROOT whose only
# real file is user/linux-wsys.c, with WSYS_VERSION set to <wsys-version>.
mktree() {
    local dir="$1" ver="$2" e
    mkdir -p "$dir/user"
    for e in "$PROJ_ROOT"/* "$PROJ_ROOT"/.[!.]*; do
        [ -e "$e" ] || continue
        case "${e##*/}" in user) continue ;; esac
        ln -sfn "$e" "$dir/${e##*/}"
    done
    for e in "$PROJ_ROOT"/user/*; do
        ln -sfn "$e" "$dir/user/${e##*/}"
    done
    rm -f "$dir/user/linux-wsys.c"
    sed "s/^\(#define[[:space:]]\+WSYS_VERSION[[:space:]]\+\)[0-9]\+/\1$ver/" \
        "$PROJ_ROOT/user/linux-wsys.c" > "$dir/user/linux-wsys.c"
    grep -q "^#define[[:space:]]\+WSYS_VERSION[[:space:]]\+$ver\$" "$dir/user/linux-wsys.c"
}

TA="$WORK/treeA"; TB="$WORK/treeB"; TC="$WORK/treeC"
mktree "$TA" "$OLD_VER" || { bad "could not stage the v$OLD_VER decoy tree"; done_report; exit 1; }
mktree "$TB" "$TREE_VER" || { bad "could not stage the v$TREE_VER tree"; done_report; exit 1; }
mktree "$TC" "$TREE_VER" || { bad "could not stage the byte-identical third tree"; done_report; exit 1; }

if cmp -s "$TB/user/linux-wsys.c" "$TC/user/linux-wsys.c" \
   && ! cmp -s "$TA/user/linux-wsys.c" "$TB/user/linux-wsys.c"; then
    ok "the two trees differ in exactly one file (user/linux-wsys.c, v$OLD_VER vs v$TREE_VER) and tree C is byte-identical to tree B"
else
    bad "the staged trees are not what this gate needs -- A must differ from B and C must equal B"
    done_report; exit 1
fi

# THE MTIME TRAP, STATED OUT LOUD. Tree B's linux-wsys.c is backdated so that
# it is OLDER than any object tree A is about to produce. That is not a
# contrivance: it is the ordinary case of TWO WORKTREES, where the one checked
# out first builds second. The old cache asked `is the source newer than the
# object` and got `no`, and served tree A's object to tree B.
touch -d '2020-01-01 00:00:00' "$TB/user/linux-wsys.c" "$TC/user/linux-wsys.c"

# ---- build both trees into ONE output directory ---------------------------
SHARED="$WORK/shared"
mkdir -p "$SHARED"

build() {   # build <tree> <out-name>
    local tree="$1" out="$2"
    "$tree/scripts/hamlinux_build.sh" user/wsysd.ad "$SHARED/$out.elf" \
        >"$WORK/$out.build.log" 2>&1
}

build "$TA" wsysdA || { bad "tree A's wsysd did not build"; tail -20 "$WORK/wsysdA.build.log" >&2
                        done_report; exit 1; }
build "$TB" wsysdB || { bad "tree B's wsysd did not build"; tail -20 "$WORK/wsysdB.build.log" >&2
                        done_report; exit 1; }
ok "both trees built wsysd into one shared output directory ($SHARED)"

# ---- run each compositor and read the version it wrote --------------------
SEG_PY="$WORK/seg.py"
cat >"$SEG_PY" <<'PY'
import struct, sys
try:
    with open(sys.argv[1], 'rb') as f:
        h = f.read(24)
except OSError:
    print("absent"); raise SystemExit
if len(h) < 24:
    print("short"); raise SystemExit
magic, ver = struct.unpack('<II', h[:8])
print("nomagic" if magic != 0x53595357 else "v%d" % ver)
PY

# segver_of <elf> <tag> -- run this compositor offscreen in a segment of its
# own and report the wsys version it stamped. Each run gets FRESH segment
# paths: a version mismatch against a segment somebody else initialised is a
# different question from the one being asked here.
segver_of() {
    local elf="$1" tag="$2" i
    export HAMWSYS="$WORK/$tag.shm" HAMWSYS_BB="$WORK/$tag.bb" \
           HAMWSYS_IMG="$WORK/$tag.img" HAMFB_FILE="$WORK/$tag.fb"
    : >"$WORK/$tag.evdev"
    export HAMWSYSD_INPUT="$WORK/$tag.evdev"
    rm -f "$HAMWSYS" "$HAMWSYS_BB" "$HAMWSYS_IMG" "$HAMFB_FILE"
    "$elf" </dev/null >"$WORK/$tag.log" 2>&1 &
    local p=$!; reap_add "$p"
    for i in $(seq 1 80); do [ -s "$HAMFB_FILE" ] && break; sleep 0.1; done
    local v; v="$(python3 "$SEG_PY" "$HAMWSYS")"
    kill "$p" 2>/dev/null; sleep 0.2; kill -9 "$p" 2>/dev/null
    printf '%s\n' "$v"
}

VA="$(segver_of "$SHARED/wsysdA.elf" A)"
if [ "$VA" = "v$OLD_VER" ]; then
    ok "the decoy compositor really is different -- it stamped the segment $VA"
else
    bad "the decoy compositor stamped $VA, not v$OLD_VER -- the discriminator this gate is built on does not work, and nothing below can be trusted"
    tail -20 "$WORK/A.log" >&2
    done_report; exit 1
fi

# THE ASSERTION. Tree B's binary, built second into the directory tree A
# already populated, must carry TREE B's window system.
VB="$(segver_of "$SHARED/wsysdB.elf" B)"
if [ "$VB" = "v$TREE_VER" ]; then
    ok "the binary built from the v$TREE_VER tree stamped the segment $VB -- it carries ITS OWN tree's window system, though a v$OLD_VER tree was built into the same directory first"
else
    bad "the binary built from the v$TREE_VER tree stamped the segment $VB -- ANOTHER TREE'S OBJECT WAS LINKED INTO IT, silently, and the build exited 0 (this is the 1.0.10 mechanism)"
    tail -20 "$WORK/B.log" >&2
fi

# ---- and the other direction ---------------------------------------------
# A DISCRIMINATOR, NOT AN INDEPENDENT ASSERTION, and it is labelled that way
# because it PASSES WITH THE FIX REVERTED and has to. Under the defect the one
# shared entry already holds tree A's object, so of course A gets it back.
# What it rules out is the other way the assertion above could go green: a
# cache that merely ALTERNATED -- rebuilding whichever tree asked last -- would
# hand each tree the right bytes every other run and the wrong bytes in
# between, and would look identical from B's side alone. It fails only for
# that one reason, which is why it is worth running.
build "$TA" wsysdA2 || bad "tree A did not rebuild after tree B"
if [ -x "$SHARED/wsysdA2.elf" ]; then
    VA2="$(segver_of "$SHARED/wsysdA2.elf" A2)"
    if [ "$VA2" = "v$OLD_VER" ]; then
        ok "discriminator: rebuilding the v$OLD_VER tree after the v$TREE_VER tree still gives it $VA2, so the trees are not simply taking turns evicting each other"
    else
        bad "the v$OLD_VER tree rebuilt to $VA2 -- the cache is alternating between trees, not keeping them apart"
    fi
fi

# ---- the structural half --------------------------------------------------
# The run-time evidence above is the truth; this is the property that MAKES it
# true, asserted directly so that a future edit cannot lose it quietly. Two
# trees with two different linux-wsys.c must have produced TWO objects.
WSOBJS=$(find "$SHARED" -maxdepth 1 -name '.linux-wsys*.o' -type f | wc -l)
if [ "$WSOBJS" -ge 2 ]; then
    ok "the shared directory holds $WSOBJS distinct linux-wsys objects -- the two trees asked for two different filenames and could not collide"
else
    bad "the shared directory holds $WSOBJS linux-wsys object(s) -- two different sources are competing for ONE cache entry, which is the defect whatever this run happened to link"
fi
UNKEYED=0
if find "$SHARED" -maxdepth 1 -name '.linux-wsys.o' -type f | grep -q .; then
    bad "the shared directory holds an object named .linux-wsys.o -- a name with no content key in it is a name two trees will collide on"
    UNKEYED=1
else
    ok "no runtime object is cached under an unkeyed name"
fi

# ASSERTION 5: content, not path. Tree C is byte-identical to tree B at a
# different path, so it must reuse B's object and add nothing.
#
# GATED, because it cannot be asked at all when the cache has one entry per
# object NAME: "no new object appeared" is then true of every tree in the
# world, identical or not, and scoring it as a pass would be scoring a
# question this run cannot answer. It reports INFO in that arm instead.
BEFORE=$(find "$SHARED" -maxdepth 1 -name '.linux-wsys*.o' -type f | wc -l)
build "$TC" wsysdC || bad "the byte-identical third tree did not build"
AFTER=$(find "$SHARED" -maxdepth 1 -name '.linux-wsys*.o' -type f | wc -l)
if [ "$UNKEYED" = 1 ]; then
    info "whether identical trees SHARE a cache entry is not a question this arm can answer -- the objects are named without a content key, so every tree shares every entry. Skipped, not passed."
elif [ "$AFTER" = "$BEFORE" ]; then
    ok "a third tree with byte-identical sources at a different path added no new object ($BEFORE) -- identical content SHARES the cache, so keeping trees apart costs no rebuilds"
else
    bad "the byte-identical third tree added an object ($BEFORE -> $AFTER) -- the cache is keyed on where the tree is rather than what is in it, which makes every worktree recompile the runtime forever"
fi
if [ -x "$SHARED/wsysdC.elf" ]; then
    VC="$(segver_of "$SHARED/wsysdC.elf" C)"
    if [ "$VC" = "v$TREE_VER" ]; then
        ok "and the shared object was the right one -- the third tree's compositor stamped $VC"
    else
        bad "the third tree's compositor stamped $VC, not v$TREE_VER"
    fi
fi

done_report
