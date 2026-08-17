#!/usr/bin/env bash
#
# REGISTRATION, 2026-08-17. Until this date scripts/test_gate_registration.sh
# globbed only scripts/test_*.sh, so this directory was invisible to the gate
# against unregistered gates and every file in it read as coverage without
# being coverage. This gate is ON-DEMAND: not in ci_battery_manifest.txt
# because MEASURED 2026-08-17: it exits 0 in 3 s while printing no PASS, no FAIL and no assertion count at all (957 bytes of output). It is a probe, not a gate -- registering it would add a battery line that cannot go red, which is exactly the false assurance the registration gate exists to prevent.
#
#
# tests/linux/ac_host.sh — prove `ac` on the development host, including the
# part that is usually invisible: the namespace hop.
#
# THIS IS A SIMULATION, AND IT IS ONE ON PURPOSE.  On the box, `ac` (user/ac.ad)
# runs host_ac natively and then rforks a child that binds three directories
# under /n, does `bind '#distro' /` and execs /bin/sh on the Debian side.  Here
# there is no #distro and no Hamnix runtime, so the same shape is built out of
# the primitives underneath it:
#
#   what ac.ad does on the box          what this script does here
#   ---------------------------------   ---------------------------------------
#   sys_rfork(RFPROC|RFNAMEG)           unshare -Urm
#   sys_bind <dir> /n/ac                mount --bind <dir> $R/n/ac
#   sys_bind '#distro' /                chroot into a root that is NOT this one
#   exec /bin/sh /n/adder/ac-link.sh    the same, unmodified
#
# The chroot's root is populated by bind-mounting this host's /usr, /bin, /lib
# and /lib64 -- so it plays the part of the Debian namespace, using this host's
# own clang.  What it genuinely proves is the load-bearing claim of the design:
# a directory bound under /n BEFORE entering a new root is still reachable at
# /n AFTER entering it, and scripts/ac-link.sh works with the outer filesystem
# out of reach -- the wall user/hlinstall.ad's header describes.
#
# What it CANNOT prove, and what needs the VM: that #distro's enter_root()
# carries /n across (it does -- user/linux-syscalls.c binds /dev /proc /sys /n
# MS_BIND|MS_REC -- but that is read, not run), and that the Debian namespace
# has a clang in it at all.
#
# Usage: tests/linux/ac_host.sh
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

WORK="${TMPDIR:-/tmp}/ac_host.$$"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT
# A bare EXIT trap does not run when the shell is killed by a signal, so a
# gate stopped by `timeout` (TERM) or ^C (INT) skipped its cleanup entirely.
# Re-exit on those, which makes the EXIT trap above run on every path out.
trap 'exit 130' INT TERM HUP
fail() { echo "FAIL: $*" >&2; exit 1; }

HOST_AC="${ADDER_HOST_AC:-build/cutover/host_ac_llvm.elf}"
[ -x "$HOST_AC" ] || HOST_AC="build/cutover/host_ac.elf"
[ -x "$HOST_AC" ] || fail "no host_ac.elf; source scripts/_adder_cc.sh && adder_cc_bootstrap"

# --- what the hamnix-ac package installs, staged ---------------------------
# /usr/share/adder: the runtime sources and the link recipe. Assembling it here
# from the tree is also the check that the package file list is complete: if a
# runtime source is missing from this list the link fails, loudly.
SHARE="$WORK/share"; mkdir -p "$SHARE"
cp user/linux-runtime.S user/linux-*.c user/linux-*.h user/syscall_nums.h \
   scripts/adder_llvm_runtime.c scripts/ac-link.sh "$SHARE/" \
   || fail "staging /usr/share/adder"
CACHE="$WORK/cache"; mkdir -p "$CACHE"
AC="$WORK/ac";       mkdir -p "$AC"

# --- step 1: the Adder compiler, natively ----------------------------------
echo "[1/3] host_ac --backend=llvm tests/linux/hello.ad"
"$HOST_AC" --backend=llvm tests/linux/hello.ad "$AC/out.ll" \
    || fail "host_ac could not emit IR"
grep -q "^define i64 @main(" "$AC/out.ll" || fail "no @main in the IR"

# --- step 2: clang, on the far side of a root change -----------------------
echo "[2/3] link, inside a chroot that cannot see this filesystem"
R="$WORK/root"; mkdir -p "$R"/{n/ac,n/adder,n/acrt,usr,bin,lib,lib64,dev,proc,tmp}
unshare -Urm --propagation private bash -euc '
    R="$1"; AC="$2"; SHARE="$3"; CACHE="$4"; CHROOT="$5"
    # the far root: this host standing in for the Debian namespace
    # /dev and /proc come across because enter_root() carries them across on
    # the box too -- a Debian tool with no /dev/null is not a fair simulation.
    for d in usr bin lib lib64 dev proc; do
        [ -d "/$d" ] || continue
        mount --rbind "/$d" "$R/$d"
    done
    # what ac.ad binds under /n before it enters
    mount --bind "$AC"    "$R/n/ac"
    mount --bind "$SHARE" "$R/n/adder"
    mount --bind "$CACHE" "$R/n/acrt"
    # ...and the proof that the outer filesystem is gone: /n is all there is.
    "$CHROOT" "$R" /bin/sh -c "
        [ -e $AC/out.ll ] && { echo \"outer root still visible\" >&2; exit 1; }
        AC_VERBOSE=1 TMPDIR=/tmp exec /bin/sh /n/adder/ac-link.sh
    "
' _ "$R" "$AC" "$SHARE" "$CACHE" "$(command -v chroot || echo /usr/sbin/chroot)" || fail "the link step failed"

# --- step 3: the binary, on this side --------------------------------------
echo "[3/3] run it"
[ -f "$AC/out.elf" ] || fail "no binary came back out of the namespace"
cp "$AC/out.elf" "$WORK/hello" && chmod 755 "$WORK/hello"
OUT="$("$WORK/hello")" || fail "the compiled program did not run"
[ "$OUT" = "hello from adder, compiled on hamnix-linux" ] \
    || fail "wrong output: $OUT"

echo "PASS: hello.ad -> IR -> (namespace) -> ELF -> ran, and printed:"
echo "      $OUT"
