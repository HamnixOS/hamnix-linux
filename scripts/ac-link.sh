#!/bin/sh
# scripts/ac-link.sh — the second half of `ac`, and the only half that needs a
# C toolchain.  Installed as /usr/share/adder/ac-link.sh and run INSIDE the
# Debian namespace by user/ac.ad.
#
# WHY IT IS A SHELL SCRIPT AND NOT PART OF ac.ad
# ----------------------------------------------
# Everything below runs on the far side of `bind '#distro' /`, where the
# Hamnix root does not exist and Debian's /bin/sh does.  Keeping it as a script
# means the recipe -- which objects, which flags, which order -- is readable and
# editable in one place, instead of being an argv table built a slot at a time
# in Adder.  ac.ad's job is the namespace dance; this file's job is the compile.
#
# THE THREE DIRECTORIES, and why they are bind mounts rather than paths
# --------------------------------------------------------------------
# A process that has entered the Debian root cannot see the Hamnix root -- that
# is the isolation working, and it is the same wall user/hlinstall.ad hits.  The
# way through is that `bind '#distro' /` carries /n across (enter_root() in
# user/linux-syscalls.c binds /dev, /proc, /sys and /n into the new root,
# MS_BIND|MS_REC).  So ac.ad binds what this script needs UNDER /n before it
# enters, and the recursive bind of /n carries them in:
#
#   AC_WORK   /n/ac      the per-compile scratch dir (holds out.ll, gets out.elf)
#   AC_SRC    /n/adder   the runtime sources, read-only in practice
#   AC_CACHE  /n/acrt    the object cache, /var/cache/adder on the Hamnix side
#
# Nothing else of the Hamnix filesystem is visible to clang.  The compiler sees
# a scratch directory, the runtime sources and its own cache -- not your home
# directory.
#
# They are env vars with those defaults so that the SAME script can be driven
# on a development host with no namespace hop at all, which is what
# tests/linux/ac_host.sh does.
#
# THE OBJECT CACHE is what makes the second compile fast.  The runtime objects
# are ~1.4s of clang on a development host and never change unless the runtime
# sources do, so they are built once into AC_CACHE and rebuilt only when a
# source is newer; a warm compile of a small program is then ~90 ms.  This is
# scripts/hamlinux_build.sh's caching rule, moved onto the box.
set -u

AC_WORK="${AC_WORK:-/n/ac}"
AC_SRC="${AC_SRC:-/n/adder}"
AC_CACHE="${AC_CACHE:-/n/acrt}"
AC_OPT="${AC_OPT:--O2}"
AC_LL="${AC_LL:-$AC_WORK/out.ll}"
AC_OUT="${AC_OUT:-$AC_WORK/out.elf}"
AC_VERBOSE="${AC_VERBOSE:-0}"

say() { [ "$AC_VERBOSE" = 0 ] || echo "[ac] $*" >&2; }
die() { echo "ac: $*" >&2; exit 1; }

CC="${AC_CC:-}"
if [ -z "$CC" ]; then
    for c in clang clang-19 clang-16 clang-15 clang-14 cc gcc; do
        command -v "$c" >/dev/null 2>&1 && { CC="$c"; break; }
    done
fi
[ -n "$CC" ] || die "no C compiler in the Debian namespace.
    The LLVM IR the Adder compiler emits still has to be optimised, codegen'd
    and linked, and that is clang's job.  Install it once:
        enter debian { apt-get install -y clang libssl-dev }
    (about 250 MB, and it lives on the Debian volume, not the Hamnix one.)"
command -v "$CC" >/dev/null 2>&1 || die "$CC: not found"

[ -r "$AC_LL" ] || die "$AC_LL: no LLVM IR to compile"
[ -d "$AC_SRC" ] || die "$AC_SRC: the Adder runtime sources are not installed
    (hpm install hamnix-ac)"
mkdir -p "$AC_CACHE" || die "$AC_CACHE: not writable"

# TLS is OpenSSL when the namespace has the headers.  Without it a `tls` ctl
# verb on /net is an ERROR rather than a silent plaintext connection, which is
# the rule scripts/hamlinux_build.sh already sets and the reason it is not a
# warning: a program that quietly sends credentials in the clear is worse than
# one that will not build.
TLSFLAGS=""
TLSLIBS=""
if [ -f /usr/include/openssl/ssl.h ]; then
    TLSFLAGS="-DHAMNIX_TLS"
    TLSLIBS="-lssl -lcrypto"
fi

# newer <a> <b> — true when a is newer than b, or b does not exist.
newer() { [ ! -f "$2" ] || [ "$1" -nt "$2" ]; }

# The runtime headers are included by several of the .c files, so any header
# being newer than an object invalidates all of them.  Cheap and correct beats a
# per-file dependency graph for six files.
HDRS_NEWER=0
for h in "$AC_SRC"/*.h; do
    [ -f "$h" ] || continue
    for o in "$AC_CACHE"/*.o; do
        [ -f "$o" ] || continue
        [ "$h" -nt "$o" ] && HDRS_NEWER=1
    done
done

build_obj() {                        # build_obj <src> <obj> <extra flags...>
    src="$1"; obj="$2"; shift 2
    if [ "$HDRS_NEWER" = 0 ] && ! newer "$src" "$obj"; then
        return 0
    fi
    say "cc $(basename "$src")"
    case "$src" in
    *.S) "$CC" -c -x assembler-with-cpp -DADDER_HOSTED -I"$AC_SRC" \
             "$@" "$src" -o "$obj" ;;
    *)   "$CC" -O2 -I"$AC_SRC" "$@" -c "$src" -o "$obj" ;;
    esac || die "could not build $(basename "$src") -- the Adder runtime does
    not compile in this Debian namespace.  Its C library headers (libc6-dev)
    come with clang; OpenSSL's (libssl-dev) are needed for /net TLS."
}

# THE OBJECT LIST IS DISCOVERED, NOT WRITTEN DOWN.
#
# scripts/hamlinux_build.sh names its six-and-counting runtime objects one
# stanza at a time, and while this file was being written another change added
# a seventh (user/linux-auth.c, /dev/auth).  A hardcoded copy of that list here
# would have been wrong within the hour, and wrong in the worst way: the
# runtime would build, the link would fail on undefined references, and the
# error would name a symbol rather than the omission.
#
# So the rule is "everything in AC_SRC": the assembler half, then every .c
# beside it.  The PACKAGE decides what the runtime is by what it ships; adding
# a source to the runtime needs no edit here at all.
#
#   linux-runtime.S   the freestanding half; -DADDER_HOSTED so crt1.o keeps
#                     _start and glibc's initialisers actually run
#   linux-syscalls.c  the hosted half -- errno, wait4, poll, the resolver
#   linux-fb.c        /dev/fb on DRM/KMS         linux-net.c   /net
#   linux-wsys.c      /dev/wsys                  linux-auth.c  /dev/auth
#   linux-fdns.c      /fd                        adder_llvm_runtime.c the prelude
OBJS=""
build_obj "$AC_SRC/linux-runtime.S" "$AC_CACHE/linux-runtime.o"
OBJS="$AC_CACHE/linux-runtime.o"
for c in "$AC_SRC"/*.c; do
    [ -f "$c" ] || continue
    o="$AC_CACHE/$(basename "$c" .c).o"
    build_obj "$c" "$o" $TLSFLAGS
    OBJS="$OBJS $o"
done
[ -n "$OBJS" ] || die "$AC_SRC: no runtime sources there"

say "link $(basename "$AC_OUT")"
# -lcrypt is glibc's SHA-512 crypt(3), which /dev/auth verifies passwords with;
# libc6-dev pulls libcrypt-dev, so it is there whenever the headers are.
# shellcheck disable=SC2086
"$CC" "$AC_OPT" "$AC_LL" $OBJS $TLSLIBS -lcrypt ${AC_LDFLAGS:-} -o "$AC_OUT" \
    || exit 12
exit 0
