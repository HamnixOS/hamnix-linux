#!/usr/bin/env bash
# tests/linux/channel_compiles_adder.sh — A MACHINE BUILT FROM THE CHANNEL MUST
# BE ABLE TO COMPILE AND RUN AN ADDER PROGRAM.
#
# THE CLAIM THIS DEFENDS
# ======================
# HANDOFF.md §0 lists "compiles Adder on the box" as one of this distribution's
# MEASURED capabilities, next to booting to a desktop and updating from
# 255.one. NORTH_STAR.md's standing invariant says the machines that matter are
# INSTALLED ones: "changes that we create here will end up in the package
# repository and be able to be updated on." Put together, those two say
# something specific and falsifiable -- a person who installs hamnix-linux and
# runs `hpm install hamnix-adder` can write foo.ad, compile it, and run it.
#
# IT WAS NOT TRUE, AND NOTHING SAID SO. Measured against the published channel
# at https://255.one/linux/ on 2026-08-11: hamnix-adder-1.0.12.tar.gz -- the
# only toolchain package in a 98-package channel, sha256 d22ce377e5bd... as the
# index advertises -- contained exactly two entries:
#
#     hamnix-adder-1.0.12/PKGINFO
#     hamnix-adder-1.0.12/files/bin/ac
#
# /bin/ac is a DRIVER, not a compiler. user/ac.ad execs /bin/host_ac (a
# hard-coded path) to turn foo.ad into LLVM IR, then runs the link recipe in
# the Debian namespace. host_ac was excluded from the channel by name in
# tests/linux/channel_covers_image.sh, on a reason that was backwards (see that
# file's header), and the runtime sources ac links against were carried by no
# package either. So the capability was false for exactly the machines the
# invariant is about, and every existing gate passed: the coverage gate saw an
# excluded file with prose in front of it, and both `ac` tests below build the
# toolchain from the tree, where host_ac has always been sitting.
#
# WHAT THIS FILE DOES DIFFERENTLY
# ===============================
# It BUILDS NOTHING IT ASSERTS ON. Every byte of the toolchain under test is
# unpacked out of the .tar.gz files in a built channel -- the exact bytes hpm
# downloads -- and then RUN. That is the rule tests/linux/channel_runs_desktop.sh
# established after hamnix-desktop 1.0.10 shipped a mixed build that every
# name-and-hash gate approved: "the artefact that ships is the one artefact
# nothing runs." The rule is enforced mechanically at the bottom of this file.
#
# It also asserts on the PROGRAM, not on the exit status. `ac` exiting 0 having
# written nothing, or writing a file that does not run, are both failures here:
# the test runs the produced ELF and compares its stdout to a fixed string.
# NORTH_STAR.md: a gap must never answer something success-shaped.
#
# THE SHAPE, AND WHAT IS AND IS NOT SIMULATED
# ===========================================
# This is tests/linux/ac_ns_host.sh's harness with the toolchain's SOURCE
# changed from "the tree" to "the channel". That test already runs the real
# `ac` ELF doing the real namespace hop -- its argument handling, its spawn of
# /bin/host_ac, its rfork + three binds under /n + `bind '#distro' /`, and its
# copy of the result back out. Every one of those is the compiled Adder program
# calling the same user/linux-syscalls.c runtime it calls on the box:
# sys_rfork really is unshare(CLONE_NEWNS), sys_bind really is mount(2), and
# `#distro` really is resolved by distro_resolve(), which reads HAMNIX_DISTRO
# (user/linux-syscalls.c) and bind-mounts a spec that is not a block device.
#
# SIMULATED, in exactly three places, all of them named:
#   * the whole thing runs inside `unshare -Urm`, because mount(2) needs
#     CAP_SYS_ADMIN; on the box ac is a descendant of PID 1, which has it.
#   * HAMNIX_DISTRO points at a DIRECTORY built here out of this host's own
#     /usr, rather than at the ext4 volume holding Debian. sys_bind takes both
#     (block device -> mount the filesystem; directory -> bind it), so the code
#     path differs in one branch. This host's clang stands in for Debian's.
#   * the dynamic loader and the shared libraries under /lib come from THIS
#     host, not from a package -- because they come from the medium on a real
#     machine too. They are excluded from the channel by name and for a reason
#     (see channel_covers_image.sh: replacing the loader every running process
#     is executing through is not an update).
#
# NOT SIMULATED, and this is the point: which files the machine HAS. Those come
# from the channel and from nowhere else. If hamnix-adder stops carrying the
# compiler, this test has no compiler, exactly as an installed machine would
# not -- and it says so instead of quietly using the tree's copy. THE ROOT IS
# ASSEMBLED FROM TARBALLS AND THE PROJECT TREE IS NOT MOUNTED INTO IT.
#
# WHAT STILL NEEDS A VM, said plainly rather than implied: that the box's
# distro.ext4 has a clang in it (scripts/hamlinux_distro.sh installs clang,
# libssl-dev, libdrm-dev, libcrypt-dev -- read, not run here), and that
# `#distro` resolves to that volume on a real boot. This file measures the half
# that was broken -- what the CHANNEL carries -- and does not claim the other.
#
# Usage: tests/linux/channel_compiles_adder.sh [channel-dir]
#   default channel-dir: build/repo/linux
#   env: ACCHAN_KEEP=1    keep the work directory
#        ACCHAN_OMIT=...  drop a file from the staged root before compiling, to
#                         see this gate fail: one of host_ac, share, ac-link,
#                         runtime. This is the negative control; it is how the
#                         failing case in the commit message was produced.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

CHAN="${1:-build/repo/linux}"
OMIT="${ACCHAN_OMIT:-}"
EXPECT="hello from adder, compiled on hamnix-linux"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $*"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
skip() { echo "SKIP: $*" >&2; exit 0; }

finish() {
    echo
    echo "$PASS passed, $FAIL failed"
    [ "$FAIL" = 0 ]
    exit $?
}

[ -d "$CHAN/packages" ] || { echo "FAIL: no channel at $CHAN (run scripts/hamlinux_packages.py)"; exit 1; }

unshare -Urm --propagation private true 2>/dev/null \
    || skip "this host does not allow unprivileged user+mount namespaces"
command -v chroot >/dev/null 2>&1 || CHROOT=/usr/sbin/chroot
CHROOT="${CHROOT:-$(command -v chroot)}"
[ -x "$CHROOT" ] || skip "no chroot(8) on this host"

W="$(mktemp -d "${TMPDIR:-/tmp}/acchan.XXXXXX")"
cleanup() { [ -n "${ACCHAN_KEEP:-}" ] || rm -rf "$W"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1. UNPACK THE TOOLCHAIN OUT OF THE CHANNEL. Nothing is copied from the tree.
# ---------------------------------------------------------------------------
PKG="$(ls "$CHAN"/packages/hamnix-adder-*.tar.gz 2>/dev/null | head -1)"
if [ -z "$PKG" ]; then
    bad "no hamnix-adder package in $CHAN -- an installed machine has no Adder toolchain at all"
    finish
fi
ok "the channel carries $(basename "$PKG")"

# If the channel has an index, the bytes RUN below must be the bytes it
# advertises -- otherwise this test proves something about a file nobody would
# ever receive. Same check tests/linux/channel_runs_desktop.sh makes.
IDX="$CHAN/index.json"
if [ -f "$IDX" ]; then
    WANT=$(python3 - "$IDX" <<'PY'
import json, sys
for p in json.load(open(sys.argv[1]))["packages"]:
    if p["name"] == "hamnix-adder":
        print(p["sha256"]); break
PY
)
    GOT=$(sha256sum "$PKG" | cut -d' ' -f1)
    if [ -z "$WANT" ]; then
        bad "index.json does not list hamnix-adder, but the tarball is there -- nothing would install it"
    elif [ "$WANT" = "$GOT" ]; then
        ok "the tarball this test unpacks is the one index.json advertises ($GOT)"
    else
        bad "hamnix-adder tarball sha256 $GOT != index.json's $WANT -- the bytes tested are not the bytes served"
    fi
else
    echo "note: no index.json in $CHAN (packager did not reach it); testing the tarballs as built"
fi

UNP="$W/unpacked"; mkdir -p "$UNP"
tar xzf "$PKG" -C "$UNP" || { bad "hamnix-adder tarball does not unpack"; finish; }
FILES="$UNP/$(basename "$PKG" .tar.gz)/files"
[ -d "$FILES" ] || { bad "hamnix-adder has no files/ directory"; finish; }

echo
echo "hamnix-adder carries:"
( cd "$FILES" && find . -type f | sed 's|^\./|  |' ) | sort | head -40

# ---------------------------------------------------------------------------
# 2. ASSEMBLE THE MACHINE. Hamnix side from the channel; loader and libs from
#    the medium, which is where they come from on a real machine too.
# ---------------------------------------------------------------------------
R="$W/machine"
mkdir -p "$R"/{bin,usr/bin,usr/lib,usr/lib64,usr/include,usr/share,dev,proc,sys,tmp,work,var/cache/adder}
mkdir -p "$R"/n/{ac,adder,acrt,.root}
ln -sfn usr/lib "$R/lib"; ln -sfn usr/lib64 "$R/lib64"

# /n/deb plays the Debian namespace. It gets this host's whole /usr, /bin, /lib
# and /lib64 (bound in below), because that is what the distro volume is on the
# box: a foreign root with a clang in it. THE MACHINE'S OWN /bin GETS NONE OF
# THAT -- it holds the tarball's files and nothing else, which is the only
# reason this test says anything about the channel.
mkdir -p "$R"/n/deb/{usr,bin,lib,lib64,dev,proc,tmp,etc}

cp -a "$FILES"/. "$R/" || { bad "staging the package files"; finish; }

# The negative control. Removing a file here is the only thing that
# distinguishes this run from the real one -- see ACCHAN_OMIT above.
case "$OMIT" in
    "")        ;;
    host_ac)   rm -f  "$R/bin/host_ac" ;;
    share)     rm -rf "$R/usr/share/adder" ;;
    ac-link)   rm -f  "$R/usr/share/adder/ac-link.sh" ;;
    runtime)   rm -f  "$R/usr/share/adder/linux-runtime.S" ;;
    *)         echo "unknown ACCHAN_OMIT=$OMIT" >&2; exit 2 ;;
esac
[ -n "$OMIT" ] && echo && echo "NEGATIVE CONTROL: removed '$OMIT' from the staged machine"

# THE PROGRAM TO COMPILE IS WRITTEN HERE, not taken from the package and not
# taken from the tree. It is an INPUT, not part of the toolchain, so writing it
# inline costs nothing -- and it means a channel that carries no hello.ad still
# gets its compiler exercised. That matters: the published 1.0.12 channel
# carried neither, and a gate that stopped at "nothing to compile" would have
# reported the smaller of the two findings and never reached the real one.
#
# It calls sys_write, so it does not link against the SSA prelude alone -- it
# needs the Linux syscall runtime (linux-runtime.S + linux-syscalls.c), which is
# exactly the part `ac` has to find in /usr/share/adder on the box. A program
# that only returned an exit code would link with the runtime sources missing
# and this whole gate would go green on a machine that cannot build anything.
cat > "$R/work/hello.ad" <<'AD'
extern def sys_write(fd: int32, buf: Ptr[uint8], count: uint64) -> int64

def slen(s: Ptr[uint8]) -> uint64:
    n: uint64 = 0
    while s[n] != 0:
        n = n + 1
    return n

def main() -> int32:
    s: Ptr[uint8] = "hello from adder, compiled on hamnix-linux\n"
    sys_write(1, s, slen(s))
    return 0
AD

# Separately: the package is SUPPOSED to carry a sample, so the first thing a
# curious operator types works (scripts/hamlinux_image.sh stages it for that
# reason). Missing is a finding, but not one that stops the measurement.
if [ -f "$R/usr/share/adder/hello.ad" ]; then
    ok "the package carries a sample program (/usr/share/adder/hello.ad)"
elif [ -n "$OMIT" ]; then
    echo "note: no sample program, but ACCHAN_OMIT=$OMIT removed it on purpose"
else
    bad "hamnix-adder carries no /usr/share/adder/hello.ad -- the sample an operator is told to compile is not there"
fi

# ---------------------------------------------------------------------------
# 3. COMPILE, WITH THE REAL ac DOING THE REAL NAMESPACE HOP.
# ---------------------------------------------------------------------------
if [ ! -x "$R/bin/ac" ]; then
    bad "the channel's hamnix-adder has no executable /bin/ac"
    finish
fi
ok "/bin/ac came out of the tarball executable ($(stat -c%a "$R/bin/ac"))"

echo
echo "[1/2] ac /work/hello.ad -o /work/hello   (real binary, real rfork+bind, channel bytes)"
unshare -Urm --propagation private bash -uc '
    R="$1"; CHROOT="$2"
    # Both roots need this host'"'"'s /usr: the Hamnix side for the loader and
    # libc every packaged binary is dynamically linked against, and /n/deb --
    # which plays the Debian namespace -- for clang. Note what is NOT bound
    # anywhere: the project tree. The toolchain is the tarball'"'"'s or nothing.
    mount --rbind /usr/bin     "$R/usr/bin"
    mount --rbind /usr/lib     "$R/usr/lib"
    mount --rbind /usr/lib64   "$R/usr/lib64" 2>/dev/null
    mount --rbind /usr/include "$R/usr/include"
    mount --rbind /dev         "$R/dev"
    mount -t proc proc         "$R/proc" 2>/dev/null || true
    for d in usr bin lib lib64; do
        [ -e "/$d" ] && mount --rbind "/$d" "$R/n/deb/$d"
    done
    mount --rbind /dev "$R/n/deb/dev"
    mount -t proc proc "$R/n/deb/proc" 2>/dev/null || true
    # HAMNIX_DISTRO is read by distro_resolve() in user/linux-syscalls.c; a
    # spec that is not LABEL= is used as a path, and a path that is not a block
    # device is bind-mounted as the new root.
    HAMNIX_DISTRO=/n/deb TMPDIR=/tmp PATH=/bin:/usr/bin \
        "$CHROOT" "$R" /bin/ac -v /work/hello.ad -o /work/hello
' _ "$R" "$CHROOT" 2>&1 | sed 's/^/    /'
ACRC=${PIPESTATUS[0]}

if [ "$ACRC" = 0 ]; then
    ok "ac exited 0"
else
    bad "ac exited $ACRC -- a machine built from this channel cannot compile an Adder program"
fi

# EXIT 0 IS NOT THE ASSERTION. The binary has to exist, and then it has to run.
if [ ! -f "$R/work/hello" ]; then
    bad "ac produced NO binary at /work/hello (exit was $ACRC) -- success-shaped exit, empty result"
    finish
fi
ok "ac wrote a binary ($(stat -c%s "$R/work/hello") bytes)"
[ -x "$R/work/hello" ] || bad "the binary ac wrote is not executable (mode $(stat -c%a "$R/work/hello"))"

echo
echo "[2/2] run what it produced"
OUT=$(unshare -Urm --propagation private bash -uc '
    R="$1"; CHROOT="$2"
    mount --rbind /usr/bin   "$R/usr/bin"
    mount --rbind /usr/lib   "$R/usr/lib"
    mount --rbind /usr/lib64 "$R/usr/lib64" 2>/dev/null
    mount --rbind /dev       "$R/dev"
    "$CHROOT" "$R" /work/hello
' _ "$R" "$CHROOT" 2>&1)
RUNRC=$?

echo "    program said: [$OUT]"
if [ "$RUNRC" != 0 ]; then
    bad "the compiled program did not run (exit $RUNRC): $OUT"
elif [ "$OUT" = "$EXPECT" ]; then
    ok "THE PROGRAM RAN AND PRINTED THE RIGHT THING -- a channel-built machine compiles Adder"
else
    bad "the compiled program ran but printed [$OUT], not [$EXPECT]"
fi

# ---------------------------------------------------------------------------
# 4. THE RULE, MECHANICALLY ENFORCED.
# ---------------------------------------------------------------------------
# The whole value of this file is that the toolchain came from the channel. A
# later edit that "fixes" a failure by reaching for scripts/hamlinux_build.sh
# or by copying user/ or build/cutover/ into the staged root would turn it back
# into a test of the tree -- which is precisely the test that passed while the
# published channel shipped a driver with no compiler. So the file greps
# itself, the way channel_runs_desktop.sh does.
SELF="${BASH_SOURCE[0]}"
# The pattern is assembled from pieces so that this line does not itself
# contain the strings it forbids -- the first version of this check failed
# against itself, which is funny once and useless twice.
PAT="hamlinux_""build\\.sh|build/""cutover|cp .*user/""linux-"
if grep -nE "$PAT" "$SELF" | grep -v '^ *[0-9]*:#' | grep -q .; then
    bad "this gate builds or copies the toolchain from the tree -- it must only unpack the channel"
else
    ok "the rule: this gate compiled nothing it asserts on -- the toolchain came out of $(basename "$PKG")"
fi

finish
