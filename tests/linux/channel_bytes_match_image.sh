#!/usr/bin/env bash
#
# REGISTRATION, 2026-08-17. Until this date scripts/test_gate_registration.sh
# globbed only scripts/test_*.sh, so this directory was invisible to the gate
# against unregistered gates and every file in it read as coverage without
# being coverage. This gate is ON-DEMAND: not in ci_battery_manifest.txt
# because it builds a full image or disk
# (`hamlinux_image.sh`/`hamlinux_disk.sh`), which is minutes of wall time and
# gigabytes of scratch.
#
# tests/linux/channel_bytes_match_image.sh — THE IMAGE AND THE CHANNEL MUST
# AGREE, BYTE FOR BYTE, ABOUT WHAT THE USER RUNS.
#
# WHAT WAS ALREADY COVERED AND WHAT WAS NOT
# =========================================
# tests/linux/channel_covers_image.sh compares NAMES: every file staged in the
# image root must be carried by some package, or be excluded by name with a
# reason. It also compares BYTES, but only under /etc, and it says why in its
# own header:
#
#     "/etc is the whole scope on purpose -- the binaries are covered by
#      tests/linux/channel_runs_desktop.sh, which RUNS them, and a per-byte
#      compare of an ELF would go red on any legitimate rebuild."
#
# The second half of that sentence WAS true and is not any more. The Linux
# lane builds the same source to the same bytes, so an ELF in the image and
# the ELF a package carries for the same path are comparable, and comparing
# them is the only thing that answers the question neither existing gate asks:
#
#     the live medium boots /bin/wsysd. An installed machine that runs
#     `hpm update` gets hamnix-desktop's /bin/wsysd. ARE THEY THE SAME
#     PROGRAM?
#
# A name gate cannot see a difference; a run gate runs one of the two copies
# and says nothing about the other. If they differ, the person who booted the
# stick and the person who installed and updated are running different
# software under one version number, and NOTHING SAYS SO.
#
# WHAT IS MEASURED HERE, EXACTLY
# ==============================
# For every path that exists BOTH as a regular file in the staged image root
# AND as a `files/<path>` member of some channel tarball, where the IMAGE copy
# begins with the four bytes \x7fELF: extract the channel's copy and `cmp` it
# against the image's. Every such pair is one comparison. A pair whose bytes
# differ is one FAIL, reported with both sizes and both sha256s -- the
# measurement, not a diagnosis of it. This gate does NOT know why two ELFs
# differ and does not guess: a difference can be a non-reproducible build, a
# stale object cache, a package built from a different tree, or a genuinely
# different program, and the four are indistinguishable from the bytes alone.
#
# THE SELECTION IS THE IMAGE'S MAGIC, not a directory or a suffix. `bin/` would
# have missed the Vulkan drivers under usr/lib and the kernel modules under
# lib/modules; a `.so`/`.ko` suffix list would have missed /bin, and both would
# be a list somebody has to remember to update. Four bytes read off the file
# cannot go stale.
#
# WHAT IT DOES NOT ANSWER
# =======================
#  * NOTHING ABOUT THE PUBLISHED CHANNEL. Both sides are local build products.
#    "the bytes on 255.one are the bytes I built" is a different question and
#    tests/linux/hpm_signed_refresh.sh and the release procedure answer it by
#    downloading. This gate would pass on a tree that never published.
#  * Nothing about non-ELF files outside /etc (fonts, firmware blobs, manual
#    pages, /etc/skel). Those are names-only, as they were.
#  * Nothing about a file only ONE side has. That is channel_covers_image.sh's
#    question in one direction and is reported here only as a count.
#  * Nothing about the gzipped kernel modules: a package that ships
#    lib/modules/.../foo.ko.gz carries no member at the image's path, so the
#    pair does not exist and is counted as uncompared rather than as equal.
#    Naming that as a hole is the honest answer; gunzipping to compare would
#    make this gate assert something about gzip's output.
#
# NEGATIVE CONTROL, and it is RUN rather than described:
#   HAMLINUX_ELFCMP_CORRUPT=<n>  flips one byte in <n> of the channel copies
#   AFTER they are extracted (into this gate's own temp tree -- nothing in
#   build/ is ever written) and requires this gate to report EXACTLY those <n>
#   paths as mismatched. A run with n>0 is expected to FAIL, and it fails with
#   the names it was told to break; if it reported fewer, or different ones,
#   the control itself goes red.
#
# WHERE THIS STANDS, MEASURED on a 1.0.26 channel and a 1.0.26 image both
# built from this tree on 2026-08-17:
#
#   FIRST RUN, on the tree as it was:      1 PASSED, 1 FAILED
#     /bin/install -- image 274,840 bytes, channel 338,432. The image stages
#     hlinstall at that path (`install -m755 $ROOT/bin/hlinstall
#     $ROOT/bin/install`); scripts/hamlinux_packages.py had `install` in
#     SYS_CMDS, which builds user/install.ad -- the NATIVE line's system
#     installer, a different program. Verified rather than inferred: the
#     channel's copy is byte-identical to a fresh build of user/install.ad,
#     the channel's bin/hlinstall is byte-identical to the image's, and
#     hamnix-install-1.0.26.tar.gz FETCHED FROM 255.one carries the same
#     338,432-byte bin/install -- so this shipped.
#   AFTER THE FIX (bin/install is built from user/hlinstall.ad):
#                                          2 PASSED, 0 FAILED, 229 pairs
#   NEGATIVE CONTROL, HAMLINUX_ELFCMP_CORRUPT=3:
#                                          1 PASSED, 3 FAILED -- /bin/ac,
#     /bin/host_ac and /bin/ham2048scene, which are exactly the three that
#     were broken, reported by name.
#
# WHAT THE PREMISE RESTS ON, measured before this file was written rather than
# assumed: user/cat.ad built twice through scripts/hamlinux_build.sh into two
# separate output directories is one sha256. And across machines and three
# days: every file inside hamnix-man, hpm, hamnix-coreutils, hamnix-desktop
# and hamnix-init fetched from 255.one at 1.0.26 is byte-identical to this
# tree's locally built 1.0.26 (0 differing of 92). THE .tar.gz WRAPPERS ARE
# NOT identical and that is NOT this gate's business: gzip stamps its own
# mtime, and the uncompressed tar of hpm-1.0.26 IS byte-identical.
#
# Usage: tests/linux/channel_bytes_match_image.sh [image-root] [channel-dir]
#   defaults: build/image/root  build/repo/linux
# Builds nothing: a gate that rebuilds its own inputs can hide the difference
# it exists to catch. About 30 s on a built tree.

set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
# THIS GATE STARTS NOTHING -- it reads two trees and runs `cmp`. It is isolated
# anyway, because tests/linux/gates_are_private.sh's detector reads the FILE
# (`hamlinux_build.sh` or `$BIN/` plus a compositor name, both of which appear
# in the prose above) and a gate that argues with the detector in an EXEMPT
# entry is a gate somebody has to re-argue with later. The namespace costs this
# file nothing: everything it touches is under $ROOT, and its own temporaries
# go to a private /tmp, which is strictly better than sharing one.
. tests/linux/private_ns.sh
priv_ns_reexec "$@"
IMG="${1:-$ROOT/build/image/root}"
CHAN="${2:-$ROOT/build/repo/linux}"
CORRUPT="${HAMLINUX_ELFCMP_CORRUPT:-0}"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $*"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

[ -d "$IMG" ]  || { echo "FAIL: no image root at $IMG (run scripts/hamlinux_image.sh)"; exit 1; }
[ -d "$CHAN/packages" ] || { echo "FAIL: no channel at $CHAN/packages (run scripts/hamlinux_packages.py)"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
trap 'exit 130' INT TERM HUP

# ---------------------------------------------------------------------------
# 1. WHICH IMAGE FILES ARE ELF. Read the magic; do not infer it from a path.
#    Symlinks are followed by `head -c`, so -type f alone would count
#    /bin/install (a copy) and miss nothing -- but a symlink has no bytes of
#    its own to compare, so only regular files are candidates.
# ---------------------------------------------------------------------------
( cd "$IMG" && find . -type f -printf '%P\n' ) | sort > "$TMP/img.all"
: > "$TMP/img.elf"
while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    if [ "$(head -c4 "$IMG/$rel" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "7f454c46" ]; then
        printf '%s\n' "$rel" >> "$TMP/img.elf"
    fi
done < "$TMP/img.all"
NIMG=$(grep -c . "$TMP/img.all" || true)
NELF=$( [ -s "$TMP/img.elf" ] && grep -c . "$TMP/img.elf" || echo 0 )
echo "image: $NIMG regular files, $NELF of them ELF"

# ---------------------------------------------------------------------------
# 2. WHICH CHANNEL MEMBERS LAND ON THOSE PATHS. One `tar tzf` per tarball.
#    A path carried by two packages is a defect of a different gate's; here it
#    is reported and BOTH copies are compared, because either one can be what
#    a machine ends up with.
# ---------------------------------------------------------------------------
: > "$TMP/pairs"          # <tarball>\t<member>\t<install path>
NTAR=0
for t in "$CHAN"/packages/*.tar.gz; do
    [ -e "$t" ] || continue
    NTAR=$((NTAR + 1))
    tar tzf "$t" 2>/dev/null | grep '/files/' | grep -v '/$' \
    | while IFS= read -r m; do
        rel="${m#*/files/}"
        [ "$rel" != "$m" ] || continue
        grep -qxF "$rel" "$TMP/img.elf" || continue
        printf '%s\t%s\t%s\n' "$t" "$m" "$rel"
      done >> "$TMP/pairs"
done
NPAIR=$( [ -s "$TMP/pairs" ] && grep -c . "$TMP/pairs" || echo 0 )
echo "channel: $NTAR tarballs, $NPAIR members landing on an ELF path the image also has"

# A SANITY FLOOR, because the failure mode of a parser is an empty list, and
# an empty list makes every comparison below vacuously true. This is the shape
# channel_covers_image.sh's header records paying for twice.
NPAIRBIN=$(cut -f3 "$TMP/pairs" 2>/dev/null | grep -c '^bin/' || true)
if [ "$NELF" -lt 100 ] || [ "$NPAIR" -lt 100 ] || [ "$NPAIRBIN" -lt 50 ]; then
    bad "only $NELF ELFs in the image and $NPAIR comparable channel members ($NPAIRBIN in bin/) -- one of the two trees is unbuilt or the tarball layout is not what this gate parses; NOT reporting agreement from it"
    echo; echo "$PASS passed, $FAIL failed"; exit 1
fi
# ---------------------------------------------------------------------------
# 2b. THE TWO TREES MUST BE THE SAME RELEASE, and this gate must say so BEFORE
#     it accuses anything of drifting.
#
#     Every failure line below ends "...run different programs under one
#     version". On 2026-08-17 I ran this gate in a tree whose build/repo/linux
#     held 1.0.25 tarballs and whose build/image/root was four hours older than
#     the 1.0.26 candidate, and it printed 31 of those lines. Every one was
#     true about the bytes and WRONG ABOUT THE CAUSE: the two sides were not
#     one version, so of course they differed. A sentence that names a cause it
#     did not measure is the failure mode this tree has paid an hour for
#     before -- "a v2 blit bigger than 512x512 is being refused", inferred from
#     nothing but a low pixel count.
#
#     WHAT THIS GUARD STILL CANNOT SEE, stated because a half-guard that is
#     believed to be whole is worse than none: two trees can carry the SAME
#     version string and still have been built from different commits. The
#     version is a label chosen at build time, not a fingerprint of the
#     sources. Running this gate against a matched pair of labels built hours
#     apart still produced 31 unattributable failures. A commit stamp on both
#     sides would close it; the channel tarballs carry no such field today.
#     Until then: build BOTH sides from one tree, in one run.
#
#     So: read the version off the channel's own tarball names, read it off the
#     image, and REFUSE TO COMPARE when they disagree. A refusal is red, not
#     green -- an unrunnable check must never answer something success-shaped.
# ---------------------------------------------------------------------------
CHANVER=$(ls "$CHAN"/packages/*.tar.gz 2>/dev/null \
          | sed -n 's/.*-\([0-9][0-9.]*\)\.tar\.gz$/\1/p' | sort -u)
NCHANVER=$(printf '%s\n' "$CHANVER" | grep -c . || true)
if [ "$NCHANVER" -ne 1 ]; then
    bad "the channel at $CHAN carries $NCHANVER different versions ($(printf '%s ' $CHANVER)) -- it is a mix of runs, and any disagreement below would be unattributable. Delete build/repo/linux and rebuild."
    echo; echo "$PASS passed, $FAIL failed"; exit 1
fi
# /etc/hamnix-release, written by scripts/hamlinux_image.sh from the same
# HAMLINUX_VERSION the packager is given. Before it existed the image root's
# only version statements were os-release's VERSION="1.0" and lsb-release's
# DISTRIB_RELEASE=1.0 -- the SERIES, which is identical for every release and
# therefore useless for telling 1.0.23 from 1.0.26.
IMGVER=""
if [ -f "$IMG/etc/hamnix-release" ]; then
    IMGVER=$(sed -n 's/^[[:space:]]*\([0-9]\+\.[0-9]\+\.[0-9]\+\)[[:space:]]*$/\1/p' \
             "$IMG/etc/hamnix-release" | head -1)
fi
# An explicit assertion, for an image built before the stamp existed or by
# hand. It is a PROMISE BY THE CALLER, echoed as such, not a measurement --
# so it is named in the output and never silently assumed.
if [ -z "$IMGVER" ] && [ -n "${HAMLINUX_ELFCMP_VERSION:-}" ]; then
    IMGVER="$HAMLINUX_ELFCMP_VERSION"
    echo "NOTE: the image carries no /etc/hamnix-release; taking $IMGVER on the caller's word via HAMLINUX_ELFCMP_VERSION. This is asserted, NOT measured."
fi
if [ -z "$IMGVER" ]; then
    # NOT a pass. The image does not say what it is, so the "one version"
    # claim in every failure line below is unverifiable, and this gate will
    # not make an accusation it cannot support.
    bad "the image at $IMG has no /etc/hamnix-release, so this gate cannot show the two sides are the same release -- and every failure it prints asserts exactly that. Rebuild the image with HAMLINUX_VERSION set, or pass HAMLINUX_ELFCMP_VERSION=<ver> to assert it. Refusing to compare rather than reporting drift it cannot attribute."
    echo; echo "$PASS passed, $FAIL failed"; exit 1
fi
if [ "$IMGVER" != "$CHANVER" ]; then
    bad "SKEW, NOT DRIFT: the image is $IMGVER and the channel is $CHANVER. These are different releases and differing bytes between them mean nothing. Rebuild both from one tree -- do NOT read the comparison below as a regression."
    echo; echo "$PASS passed, $FAIL failed"; exit 1
fi
ok "the image and the channel are both $IMGVER, so 'different bytes under one version' is a claim this gate can actually make"

ok "both sides are plausible: $NELF ELFs staged in the image, $NPAIR of them also carried by a package ($NPAIRBIN in bin/) -- the comparison below means something"

# ---------------------------------------------------------------------------
# 3. EXTRACT, PERTURB IF ASKED, COMPARE.
# ---------------------------------------------------------------------------
X="$TMP/x"; mkdir -p "$X"
cut -f1 "$TMP/pairs" | sort -u > "$TMP/tars"
while IFS= read -r t; do
    awk -F'\t' -v t="$t" '$1==t {print $2}' "$TMP/pairs" > "$TMP/members"
    tar xzf "$t" -C "$X" -T "$TMP/members" 2>/dev/null || true
done < "$TMP/tars"

# THE NEGATIVE CONTROL. The corrupted copies are this gate's own extracted
# temporaries; $IMG and $CHAN are never written.
: > "$TMP/broken"
if [ "$CORRUPT" -gt 0 ]; then
    echo "NEGATIVE CONTROL: flipping one byte in $CORRUPT extracted channel copies"
    n=0
    while IFS=$'\t' read -r t m rel; do
        [ "$n" -lt "$CORRUPT" ] || break
        f="$X/$m"
        [ -f "$f" ] || continue
        # Byte 64 is inside the ELF header of every candidate here; a flip
        # there is a difference `cmp` must see and nothing else can explain.
        printf '\xff' | dd of="$f" bs=1 seek=64 count=1 conv=notrunc status=none
        printf '%s\n' "$rel" >> "$TMP/broken"
        n=$((n + 1))
    done < "$TMP/pairs"
    [ "$(grep -c . "$TMP/broken")" = "$CORRUPT" ] \
        || { echo "FAIL: the control could not break $CORRUPT files"; exit 1; }
fi

: > "$TMP/diff"
: > "$TMP/gone"
NCMP=0
while IFS=$'\t' read -r t m rel; do
    f="$X/$m"
    if [ ! -f "$f" ]; then printf '%s\n' "$rel" >> "$TMP/gone"; continue; fi
    NCMP=$((NCMP + 1))
    cmp -s "$f" "$IMG/$rel" || printf '%s\t%s\t%s\n' "$rel" "$t" "$m" >> "$TMP/diff"
done < "$TMP/pairs"

NGONE=$( [ -s "$TMP/gone" ] && grep -c . "$TMP/gone" || echo 0 )
if [ "$NGONE" -gt 0 ]; then
    bad "$NGONE members were listed in a tarball and did not extract -- this gate could not read them, so it is NOT reporting them as equal"
    head -5 "$TMP/gone" | sed 's|^|      |'
fi

NDIFF=$( [ -s "$TMP/diff" ] && grep -c . "$TMP/diff" || echo 0 )
if [ "$NDIFF" -gt 0 ]; then
    while IFS=$'\t' read -r rel t m; do
        bad "/$rel: the image's copy and $(basename "$t")'s copy are DIFFERENT BYTES -- a live boot and an updated install run different programs under one version"
        printf '        image  : %10s bytes  %s\n' \
            "$(stat -c%s "$IMG/$rel")" "$(sha256sum "$IMG/$rel" | cut -c1-16)"
        printf '        channel: %10s bytes  %s\n' \
            "$(stat -c%s "$X/$m")" "$(sha256sum "$X/$m" | cut -c1-16)"
    done < "$TMP/diff"
else
    ok "all $NCMP ELFs carried by both the image and the channel are BYTE-IDENTICAL -- what a live boot runs is what an updated machine receives"
fi

# ---------------------------------------------------------------------------
# 4. THE CONTROL IS ITSELF CHECKED. Reporting SOME failure is not evidence:
#    it has to be exactly the files that were broken.
# ---------------------------------------------------------------------------
if [ "$CORRUPT" -gt 0 ]; then
    cut -f1 "$TMP/diff" 2>/dev/null | sort -u > "$TMP/diffnames"
    sort -u "$TMP/broken" > "$TMP/brokennames"
    if cmp -s "$TMP/diffnames" "$TMP/brokennames"; then
        echo "CONTROL: the $CORRUPT reported mismatches are exactly the $CORRUPT that were broken -- this gate can fail, and fails by name"
    else
        echo "CONTROL FAILED: broken $(grep -c . "$TMP/brokennames"), reported $(grep -c . "$TMP/diffnames"):"
        diff "$TMP/brokennames" "$TMP/diffnames" | head -10 | sed 's|^|      |'
        FAIL=$((FAIL + 1))
    fi
fi

echo
echo "compared $NCMP ELF pairs across $NTAR channel tarballs"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
