#!/usr/bin/env bash
# scripts/hamlinux_build.sh — build ONE Adder application for the Linux line.
#
# This is the hamnix-linux build lane: host_ac emits textual LLVM IR, clang
# optimises/codegens it and links it against **glibc** together with the Linux
# link runtime (user/linux-runtime.S, assembled -DADDER_HOSTED so crt1.o keeps
# ownership of _start and glibc's initialisers actually run).
#
# It differs from scripts/adder_cc_llvm.sh in exactly one way that matters:
# that script links only the tiny SSA-prelude stub runtime, so every sys_*
# reference is an undefined symbol. This one links the real syscall runtime,
# which is what an application in user/ actually needs.
#
# Usage:
#   scripts/hamlinux_build.sh <in.ad> <out-elf> [extra clang args...]
#
# Env:
#   ADDER_HOST_AC   LLVM-capable host_ac.elf (default build/cutover/host_ac.elf)
#   BENCH_CLANG     clang binary (default clang-19, then clang)
#   HAMLINUX_OPT    clang optimisation level (default -O2)
#
# Exit: 0 on a built+linked ELF. Distinguishes the two failure modes by exit
# code so a sweep can group them without parsing logs:
#   10 = host_ac failed to emit IR      (front-end / language failure)
#   11 = @main bailed the SSA subset    (backend coverage failure)
#   12 = clang link failed              (missing sys_* runtime symbols)
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

if [ $# -lt 2 ]; then
    echo "usage: hamlinux_build.sh <in.ad> <out-elf> [clang args...]" >&2
    exit 2
fi
IN_AD="$1"; OUT_ELF="$2"; shift 2

HOST_AC="${ADDER_HOST_AC:-build/cutover/host_ac_llvm.elf}"
[ -x "$HOST_AC" ] || HOST_AC="build/cutover/host_ac.elf"
[ -x "$HOST_AC" ] || {
    echo "[hamlinux] ERROR: no host_ac.elf; run: source scripts/_adder_cc.sh && adder_cc_bootstrap" >&2
    exit 1
}

CLANG="${BENCH_CLANG:-}"
if [ -z "$CLANG" ]; then
    if command -v clang-19 >/dev/null 2>&1; then CLANG=clang-19; else CLANG=clang; fi
fi
command -v "$CLANG" >/dev/null 2>&1 || { echo "[hamlinux] ERROR: $CLANG not found" >&2; exit 1; }

OPTLVL="${HAMLINUX_OPT:--O2}"
OUT_DIR="$(dirname "$OUT_ELF")"
mkdir -p "$OUT_DIR"

# The Linux link runtime is two objects, assembled/compiled once and cached:
#
#   user/linux-runtime.S   the freestanding half — the entry points that are a
#                          single raw `syscall`. -DADDER_HOSTED suppresses its
#                          _start (crt1.o owns that here) and the definitions
#                          the hosted half overrides.
#   user/linux-syscalls.c  the hosted half — everything needing errno, wait4,
#                          poll or the resolver. See its header comment.
RT_OBJ="$OUT_DIR/.linux-runtime.o"
if [ ! -f "$RT_OBJ" ] || [ user/linux-runtime.S -nt "$RT_OBJ" ]; then
    "$CLANG" -c -x assembler-with-cpp -DADDER_HOSTED -Iuser \
        user/linux-runtime.S -o "$RT_OBJ" || {
        echo "[hamlinux] ERROR: could not assemble user/linux-runtime.S" >&2
        exit 1
    }
fi
SC_OBJ="$OUT_DIR/.linux-syscalls.o"
if [ ! -f "$SC_OBJ" ] || [ user/linux-syscalls.c -nt "$SC_OBJ" ] \
        || [ user/linux-fb.h -nt "$SC_OBJ" ] \
        || [ user/linux-wsys.h -nt "$SC_OBJ" ] \
        || [ user/linux-fdns.h -nt "$SC_OBJ" ] \
        || [ user/linux-net.h -nt "$SC_OBJ" ] \
        || [ user/linux-auth.h -nt "$SC_OBJ" ]; then
    "$CLANG" -O2 -Iuser -c user/linux-syscalls.c -o "$SC_OBJ" || {
        echo "[hamlinux] ERROR: could not compile user/linux-syscalls.c" >&2
        exit 1
    }
fi
# The DRM/KMS framebuffer behind /dev/fb (HANDOFF §4.4).
FB_OBJ="$OUT_DIR/.linux-fb.o"
if [ ! -f "$FB_OBJ" ] || [ user/linux-fb.c -nt "$FB_OBJ" ] \
        || [ user/linux-fb.h -nt "$FB_OBJ" ]; then
    "$CLANG" -O2 -Iuser -c user/linux-fb.c -o "$FB_OBJ" || {
        echo "[hamlinux] ERROR: could not compile user/linux-fb.c" >&2
        exit 1
    }
fi

# /dev/wsys, the window system device (the port of devwsys.ad).
WS_OBJ="$OUT_DIR/.linux-wsys.o"
if [ ! -f "$WS_OBJ" ] || [ user/linux-wsys.c -nt "$WS_OBJ" ] \
        || [ user/linux-wsys.h -nt "$WS_OBJ" ]; then
    "$CLANG" -O2 -Iuser -c user/linux-wsys.c -o "$WS_OBJ" || {
        echo "[hamlinux] ERROR: could not compile user/linux-wsys.c" >&2
        exit 1
    }
fi

# /fd, the Plan 9 file-descriptor name space (HANDOFF §7.1).
FD_OBJ="$OUT_DIR/.linux-fdns.o"
if [ ! -f "$FD_OBJ" ] || [ user/linux-fdns.c -nt "$FD_OBJ" ] \
        || [ user/linux-fdns.h -nt "$FD_OBJ" ]; then
    "$CLANG" -O2 -Iuser -c user/linux-fdns.c -o "$FD_OBJ" || {
        echo "[hamlinux] ERROR: could not compile user/linux-fdns.c" >&2
        exit 1
    }
fi

# /net, the Plan 9 network file tree (HANDOFF §3). TLS is OpenSSL when the
# host has the headers; without it a `tls` ctl verb is an ERROR rather than a
# silent plaintext connection, which would send credentials in the clear.
NET_OBJ="$OUT_DIR/.linux-net.o"
TLSFLAGS=""
TLSLIBS=""
if [ -f /usr/include/openssl/ssl.h ]; then
    TLSFLAGS="-DHAMNIX_TLS"
    TLSLIBS="-lssl -lcrypto"
fi
if [ ! -f "$NET_OBJ" ] || [ user/linux-net.c -nt "$NET_OBJ" ] \
        || [ user/linux-net.h -nt "$NET_OBJ" ]; then
    "$CLANG" -O2 -Iuser $TLSFLAGS -c user/linux-net.c -o "$NET_OBJ" || {
        echo "[hamlinux] ERROR: could not compile user/linux-net.c" >&2
        exit 1
    }
fi

# /dev/auth, the credential device. -lcrypt for the SHA-512 verify.
AU_OBJ="$OUT_DIR/.linux-auth.o"
if [ ! -f "$AU_OBJ" ] || [ user/linux-auth.c -nt "$AU_OBJ" ] \
        || [ user/linux-auth.h -nt "$AU_OBJ" ]; then
    "$CLANG" -O2 -Iuser -c user/linux-auth.c -o "$AU_OBJ" || {
        echo "[hamlinux] ERROR: could not compile user/linux-auth.c" >&2
        exit 1
    }
fi

LL="${OUT_ELF%.elf}.ll"
[ "$LL" = "$OUT_ELF" ] && LL="$OUT_ELF.ll"

if ! "$HOST_AC" --backend=llvm "$IN_AD" "$LL" 2>"$LL.emit.log"; then
    sed 's/^/[emit] /' "$LL.emit.log" >&2
    exit 10
fi
grep -E "^; ADDER_STAT" "$LL" >&2 || true

if ! grep -q "^define i64 @main(" "$LL"; then
    echo "[hamlinux] ERROR: no @main emitted (body bailed the SSA subset); .ll=$LL" >&2
    exit 11
fi

if ! "$CLANG" "$OPTLVL" "$LL" scripts/adder_llvm_runtime.c "$RT_OBJ" "$SC_OBJ" "$FB_OBJ" "$WS_OBJ" "$FD_OBJ" "$NET_OBJ" "$AU_OBJ" \
        $TLSLIBS -lcrypt \
        "$@" -o "$OUT_ELF" 2>"$LL.link.log"; then
    sed 's/^/[link] /' "$LL.link.log" >&2
    exit 12
fi
echo "[hamlinux] built $OUT_ELF" >&2
exit 0
