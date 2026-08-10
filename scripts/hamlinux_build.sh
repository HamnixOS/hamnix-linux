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

# The Linux link runtime, assembled once and cached. -DADDER_HOSTED suppresses
# the freestanding _start (see the comment at that site in linux-runtime.S).
RT_OBJ="$OUT_DIR/.linux-runtime.o"
if [ ! -f "$RT_OBJ" ] || [ user/linux-runtime.S -nt "$RT_OBJ" ]; then
    "$CLANG" -c -x assembler-with-cpp -DADDER_HOSTED -Iuser \
        user/linux-runtime.S -o "$RT_OBJ" || {
        echo "[hamlinux] ERROR: could not assemble user/linux-runtime.S" >&2
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

if ! "$CLANG" "$OPTLVL" "$LL" scripts/adder_llvm_runtime.c "$RT_OBJ" "$@" \
        -o "$OUT_ELF" 2>"$LL.link.log"; then
    sed 's/^/[link] /' "$LL.link.log" >&2
    exit 12
fi
echo "[hamlinux] built $OUT_ELF" >&2
exit 0
