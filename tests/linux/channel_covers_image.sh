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
# A program that is in the initramfs but not in any package is a program an
# INSTALLED machine can never receive a fix to. The live image gets it because
# the image is built from the tree; a person who installed hamnix-linux and
# runs `hpm update` gets nothing, forever, and NOTHING FAILS to tell them so.
# That is the worst shape a bug can have in this project: the gap answers with
# silence rather than with the truth.
#
# It has happened at least three times before this gate existed:
#   * the audio clients, when audio first landed -- an installed machine got
#     the audio DEVICE (compiled into every binary's runtime) and none of the
#     programs that could drive it (see the AUDIO_CMDS note in
#     scripts/hamlinux_packages.py);
#   * hamnix-desktop, dropped from a whole channel by a double-link that
#     printed one line of output;
#   * and the seven this gate found the day it was written: audiolife, halt,
#     hamimgscene, host_ac, install, poweroff, xsnarfd -- including the two
#     commands that turn the machine off, and the X clipboard bridge that had
#     been written that same week.
#
# WHAT THIS MEASURES: every regular file under /bin in the staged image root,
# against every bin/ path carried by any package tarball in the built channel.
# Not the build logs, not the package COUNT -- the actual file lists, on disk.
# A count is exactly the kind of evidence that agrees with a silent drop.
#
# HOW AN OMISSION IS ALLOWED: by name, in HOST_ONLY below, WITH A REASON. An
# unlisted omission fails. This is deliberate -- it makes "we do not ship that"
# a written decision rather than an accident nobody noticed.
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

# Programs that are deliberately in the image and NOT in the channel. Each
# needs a reason, and the reason has to be about the program, not about the
# effort of packaging it.
#
#   host_ac   -- the Adder compiler built for the BUILD HOST's libc, used to
#                compile the tree. It is a build tool that happens to be
#                staged; the shippable compiler is `ac`, which IS packaged.
#                Shipping host_ac would hand an installed machine a binary
#                linked against a libc that is not necessarily its own.
#   audiolife -- an audio stream LIFETIME scenario driver: a test fixture, not
#                a program a user runs. It is in the image because the audio
#                tests run inside the image.
HOST_ONLY="host_ac audiolife"

[ -d "$IMG" ]  || { echo "FAIL: no image root at $IMG (run scripts/hamlinux_image.sh)"; exit 1; }
[ -d "$CHAN" ] || { echo "FAIL: no channel at $CHAN (run scripts/hamlinux_packages.py)"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# What the image ships.
( cd "$IMG/bin" && ls ) | sort > "$TMP/img"

# What the channel carries. Package layout is <name>-<ver>/files/<install-path>,
# so a binary is .../files/bin/<cmd>. Grep away anything with a further slash:
# bin/ is flat and a nested path would mean the layout changed under us.
for t in "$CHAN"/packages/*.tar.gz; do
    [ -e "$t" ] || continue
    tar tzf "$t" 2>/dev/null
done | sed -n 's|.*/files/bin/||p' | grep -v '/' | sort -u > "$TMP/chan"

NIMG=$(wc -l < "$TMP/img")
NCHAN=$(wc -l < "$TMP/chan")
echo "image /bin: $NIMG    channel /bin: $NCHAN"

# A sanity floor. If the extraction pattern silently matches nothing -- which
# it DID during development, when the layout was /files/bin and the pattern
# assumed /bin -- every comparison below would "find" the whole image missing,
# or worse, an empty image list would make everything pass. Refuse to report
# on lists that are implausible, rather than reporting a confident wrong answer.
if [ "$NIMG" -lt 50 ]; then
    bad "only $NIMG binaries found in $IMG/bin -- the image looks unbuilt or the path is wrong; NOT reporting coverage from it"
    echo; echo "$PASS passed, $FAIL failed"; exit 1
fi
if [ "$NCHAN" -lt 50 ]; then
    bad "only $NCHAN binaries extracted from $CHAN/packages -- the tarball layout is not what this gate parses; NOT reporting coverage from it"
    echo; echo "$PASS passed, $FAIL failed"; exit 1
fi
ok "both lists are plausible ($NIMG image, $NCHAN channel) -- the comparison below means something"

# THE MEASUREMENT.
MISSING=$(comm -23 "$TMP/img" "$TMP/chan")
UNEXPECTED=""
for m in $MISSING; do
    allowed=0
    for h in $HOST_ONLY; do [ "$m" = "$h" ] && allowed=1; done
    [ "$allowed" = 1 ] || UNEXPECTED="$UNEXPECTED $m"
done

for h in $HOST_ONLY; do
    if grep -qx "$h" "$TMP/chan"; then
        ok "$h is listed host-only and IS packaged -- harmless, but the list is stale"
    elif grep -qx "$h" "$TMP/img"; then
        ok "$h omitted from the channel deliberately (reason recorded in this file)"
    else
        ok "$h is in neither list -- nothing to justify"
    fi
done

if [ -n "$UNEXPECTED" ]; then
    for u in $UNEXPECTED; do
        bad "$u ships in the image and is in NO package -- an installed machine can never update it"
    done
    echo
    echo "Add each to a command list in scripts/hamlinux_packages.py (COREUTILS,"
    echo "DESKTOP_CMDS, SYS_CMDS, NET_CMDS, AUDIO_CMDS, AUTH_CMDS, MOD_CMDS) or,"
    echo "if it genuinely must not ship, add it to HOST_ONLY in this file WITH A"
    echo "REASON. Silence is not one of the options."
else
    ok "every binary in the image is carried by a package ($NIMG checked)"
fi

# The other direction is NOT a failure -- a channel may offer more than the
# initramfs has room for -- but it is worth saying out loud, because a command
# in the channel and not the image is a command nobody has ever run on a live
# boot.
EXTRA=$(comm -13 "$TMP/img" "$TMP/chan" | tr '\n' ' ')
if [ -n "$EXTRA" ]; then
    echo "note: in the channel but not the image (never exercised on a live boot):$EXTRA"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
