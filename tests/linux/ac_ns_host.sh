#!/usr/bin/env bash
# tests/linux/ac_ns_host.sh — run the REAL `ac` binary, doing the REAL
# namespace hop, on a development host.
#
# tests/linux/ac_host.sh proves the link recipe across a root change but drives
# it from bash.  This one runs user/ac.ad's own ELF: its argument handling, its
# spawn of /bin/host_ac, its rfork + three binds under /n + `bind '#distro' /`,
# and its copy of the result back out.  Every one of those is the compiled
# Adder program calling the same user/linux-syscalls.c runtime it will call on
# the box -- sys_rfork really is unshare(CLONE_NEWNS), sys_bind really is
# mount(2), `#distro` really is HAMNIX_DISTRO.
#
# STILL A SIMULATION, in exactly two places:
#   * the whole thing runs inside `unshare -Urm`, because mount(2) needs
#     CAP_SYS_ADMIN and on the box ac is a descendant of PID 1 which has it;
#   * HAMNIX_DISTRO points at a DIRECTORY built here out of this host's own
#     /usr, rather than at the ext4 volume holding Debian.  sys_bind takes both
#     (user/linux-syscalls.c: block device -> mount the filesystem, directory ->
#     bind it), so the code path differs only in that one branch.
#
# What still needs the VM: that the box's Debian volume has a clang in it, and
# that #distro resolves to that volume.
#
# Usage: tests/linux/ac_ns_host.sh
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

W="$(mktemp -d "${TMPDIR:-/tmp}/ac_ns.XXXXXX")"
trap 'rm -rf "$W"' EXIT
# A bare EXIT trap does not run when the shell is killed by a signal, so a
# gate stopped by `timeout` (TERM) or ^C (INT) skipped its cleanup entirely.
# Re-exit on those, which makes the EXIT trap above run on every path out.
trap 'exit 130' INT TERM HUP
fail() { echo "FAIL: $*" >&2; exit 1; }
skip() { echo "SKIP: $*" >&2; exit 0; }

unshare -Urm --propagation private true 2>/dev/null \
    || skip "this host does not allow unprivileged user+mount namespaces"

HOST_AC="${ADDER_HOST_AC:-build/cutover/host_ac_llvm.elf}"
[ -x "$HOST_AC" ] || HOST_AC="build/cutover/host_ac.elf"
[ -x "$HOST_AC" ] || fail "no host_ac.elf"

echo "[1/3] build user/ac.ad through the Linux lane"
scripts/hamlinux_build.sh user/ac.ad "$W/ac.elf" >/dev/null 2>"$W/build.log" \
    || { cat "$W/build.log" >&2; fail "ac.ad did not build"; }

# The two roots this test needs are both "a chrootable tree that has this
# host's /usr in it": one plays the Hamnix root (it holds /bin/ac,
# /bin/host_ac, /usr/share/adder), the other plays the Debian namespace (it
# holds clang).  /bin is a real directory of symlinks rather than the usual
# symlink to usr/bin, because that is the one place anything gets added.
mkroot() {
    local r="$1"
    mkdir -p "$r"/{bin,usr/bin,usr/lib,usr/lib64,usr/include,usr/share,dev,proc,sys,tmp,n,var/cache}
    ln -sfn usr/lib   "$r/lib"
    ln -sfn usr/lib64 "$r/lib64"
    ln -sfn usr/bin   "$r/sbin"
    local f
    for f in /usr/bin/*; do
        ln -sfn "/usr/bin/${f##*/}" "$r/bin/${f##*/}" 2>/dev/null
    done
}

R="$W/ham"; mkroot "$R"
D="$R/n/deb"; mkroot "$D"

# What the hamnix-ac package installs.
cp "$HOST_AC" "$R/bin/host_ac" && chmod 755 "$R/bin/host_ac"
cp "$W/ac.elf" "$R/bin/ac"     && chmod 755 "$R/bin/ac"
mkdir -p "$R/usr/share/adder"
cp user/linux-runtime.S user/linux-*.c user/linux-*.h user/syscall_nums.h \
   scripts/adder_llvm_runtime.c scripts/ac-link.sh "$R/usr/share/adder/" \
   || fail "staging /usr/share/adder"
cp tests/linux/hello.ad "$R/tmp/hello.ad"

echo "[2/3] ac hello.ad -o hello, inside the namespace"
unshare -Urm --propagation private bash -euc '
    R="$1"; CHROOT="$2"
    for r in "$R" "$R/n/deb"; do
        mount --rbind /usr/bin  "$r/usr/bin"
        mount --rbind /usr/lib  "$r/usr/lib"
        mount --rbind /usr/lib64 "$r/usr/lib64"
        mount --rbind /usr/include "$r/usr/include"
        mount --rbind /dev      "$r/dev"
        mount -t proc proc      "$r/proc" 2>/dev/null || true
    done
    # HAMNIX_DISTRO is the path #distro resolves to, INSIDE this root.
    HAMNIX_DISTRO=/n/deb TMPDIR=/tmp PATH=/bin:/usr/bin \
        "$CHROOT" "$R" /bin/ac -v /tmp/hello.ad -o /tmp/hello
' _ "$R" "$(command -v chroot || echo /usr/sbin/chroot)" \
    || fail "ac exited non-zero"

echo "[3/3] run what it produced"
[ -x "$R/tmp/hello" ] || fail "ac produced no executable at /tmp/hello"
OUT="$("$R/tmp/hello")" || fail "the compiled program did not run"
[ "$OUT" = "hello from adder, compiled on hamnix-linux" ] \
    || fail "wrong output: $OUT"
echo "PASS: /bin/ac compiled and linked hello.ad across the namespace, and it"
echo "      printed: $OUT"
