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
#   13 = the source has NO `def main`   (a LIBRARY MODULE, not an application)
#
# 13 exists because 11 was answering for both, and the two are opposites. The
# check used to be "no `define i64 @main(` in the .ll -> the body bailed the
# SSA subset", and it said that about four files that have no `main` to bail:
# user/http9.ad, user/net9.ad, user/httpdconf.ad and user/hambrowse_tabs.ad are
# library modules, imported by hpm/curl/wget, by the /net dialers, by httpd and
# by hambrowse. Every one of them emits every function it has --
# `funcs=74 emitted=74 bailed=0` for http9 -- and then gets reported as a
# backend coverage failure. HANDOFF.md carried "one genuinely bails the
# backend's SSA subset (hambrowse_tabs)" on the strength of that message; it
# never bailed anything.
#
# So the two cases are now told apart by the SOURCE, which is where the answer
# is: a file with a top-level `def main` that produced no `@main` really did
# bail (11); a file with no `def main` at all was never an application (13).
# Both are still non-zero -- this script's job is to produce a linked ELF and
# it did not -- but a sweep can now count them apart, and a build count whose
# denominator is "applications" can stop counting libraries as failures.
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

# /net's TLS. OpenSSL when the host has the headers; without it a `tls` ctl
# verb is an ERROR rather than a silent plaintext connection, which would send
# credentials in the clear. Decided here because it is part of the CACHE KEY
# below as well as the link line.
TLSFLAGS=""
TLSLIBS=""
if [ -f /usr/include/openssl/ssl.h ]; then
    TLSFLAGS="-DHAMNIX_TLS"
    TLSLIBS="-lssl -lcrypto"
fi

# ===========================================================================
# THE RUNTIME OBJECT CACHE — KEYED ON CONTENT, NEVER ON mtime
# ===========================================================================
# The eight objects below (linux-runtime.S and the seven device servers) are
# the same bytes for every program in the tree, so they are compiled once and
# cached. WHERE they are cached and HOW they are invalidated is the whole
# subject of this block, because getting it wrong is a shipped-defect
# mechanism this project has already paid for twice.
#
# WHAT IT USED TO DO, AND WHAT THAT COST
# --------------------------------------
# It cached them as `$OUT_DIR/.linux-wsys.o` &c — one fixed name per object,
# in the OUTPUT directory — and rebuilt one when its `.c` was NEWER than the
# object:
#
#     [ ! -f "$WS_OBJ" ] || [ user/linux-wsys.c -nt "$WS_OBJ" ]
#
# Both halves are wrong, and they compound.
#
#   * The NAME does not mention the source tree. Two checkouts that build into
#     one output directory — two agents' worktrees, a bisect, a gate handed
#     `$WORK` — share one `.linux-wsys.o`, so the FIRST tree's window system
#     is linked into the SECOND tree's binaries. Every name matches, every
#     hash matches, every dependency resolves, and the program does the wrong
#     thing. That is exactly the shape NORTH_STAR.md forbids: a success-shaped
#     answer instead of the truth.
#
#   * mtime does not mean "different content", in either direction. Two files
#     can share an mtime to the nanosecond. A checkout gives OLD content a NEW
#     mtime — `git checkout <older-rev>` routinely does, which is how a stale
#     object survives a revert. And `-nt` is false when the timestamps are
#     equal, so a fast edit inside one filesystem timestamp tick is missed.
#
# It has bitten twice, in both lanes. hamnix-desktop 1.0.10 shipped a desktop
# that mapped no windows because a stale cached object was PACKAGED — the
# packager lane, since fixed by `newest_shared_input()` in
# scripts/hamlinux_packages.py. And an agent building a negative control got a
# `wsysd` reporting wsys segment version **5** out of a v7 tree, because
# another tree had been built into the same directory first — this lane, which
# is the one being fixed here.
#
# WHAT IT DOES NOW
# ----------------
# The object's NAME CONTAINS THE HASH OF ITS INPUTS. Two trees whose
# linux-wsys.c differ ask for two different filenames, so they cannot collide
# however hard they share a directory; two trees whose linux-wsys.c is
# byte-identical ask for the same filename and SHOULD share it. Sharing stops
# being a hazard and becomes the point.
#
# The key has two halves, so that editing one device server does not recompile
# the other seven:
#
#   <src>  sha256 of that object's own source (.c or .S).
#   <env>  sha256 of everything shared: every user/linux-*.h, the TLS flag,
#          THIS SCRIPT, and the compiler's identity. Headers are keyed as a
#          set rather than per-object because the exact include graph is not
#          knowable before the compile, and over-invalidating is the safe
#          direction: a header edit rebuilds all eight, which is correct and
#          rare.
#
# The compiler's identity is its path, size and mtime. That is a heuristic —
# but it is a heuristic about a BINARY THIS TREE DOES NOT OWN, not about the
# source under test, and `clang --version` costs 15 ms on every one of the 366
# builds a sweep does. The tree's own content is hashed, always.
#
# Objects are compiled to a temp name and RENAMED INTO PLACE. rename(2) within
# a directory is atomic, so four parallel workers (HAMLINUX_JOBS) racing on
# the same cache entry produce a complete object or no object, never a half
# written one that links.
#
# HAMLINUX_OBJ_CACHE puts the cache somewhere other than the output directory
# — now a safe thing to do, and worth it for a shared build box. Unset, the
# behaviour is what it always was: objects live beside the binaries.
# ===========================================================================
command -v sha256sum >/dev/null 2>&1 || {
    # Falling back to mtime here would be the failure this block exists to
    # prevent, arrived at quietly. Refuse by name instead.
    echo "[hamlinux] ERROR: no sha256sum on PATH — the runtime object cache is keyed on content and there is no mtime fallback (that is the bug). Install coreutils." >&2
    exit 1
}

OBJ_DIR="${HAMLINUX_OBJ_CACHE:-$OUT_DIR}"
mkdir -p "$OBJ_DIR" || { echo "[hamlinux] ERROR: cannot create object cache $OBJ_DIR" >&2; exit 1; }

# The runtime sources. linux-audio.c is OPTIONAL at this point in its life:
# the .c is not in the tree on every branch, and a build script that cannot
# run without a file that may not exist is a build script that breaks a clean
# checkout. It broke exactly that way once — the audio stanza was committed
# while user/linux-audio.c was still untracked, so a fresh worktree of the
# mainline could not compile ANY program. Guarded rather than assumed.
RT_SRCS=(user/linux-runtime.S user/linux-syscalls.c user/linux-fb.c \
         user/linux-wsys.c user/linux-fdns.c user/linux-net.c \
         user/linux-auth.c user/linux-snarf.c)
[ -f user/linux-audio.c ] && RT_SRCS+=(user/linux-audio.c)

# One sha256sum pass over every runtime source: nine digests, one process.
declare -A SRC_SHA=()
while read -r _h _f; do SRC_SHA["$_f"]="${_h:0:16}"; done < <(sha256sum "${RT_SRCS[@]}")
for _f in "${RT_SRCS[@]}"; do
    [ -n "${SRC_SHA[$_f]:-}" ] || {
        echo "[hamlinux] ERROR: could not hash $_f — refusing to build against an unkeyed runtime source" >&2
        exit 1
    }
done

# The shared half of the key. `hamlinux-objcache-v1` is a salt: bump it to
# invalidate every cached object in every directory at once, should the
# meaning of a key ever have to change.
ENV_SHA="$( { printf '%s\n' hamlinux-objcache-v1 "$CLANG" "$TLSFLAGS"
              stat -Lc '%n %s %Y' "$(command -v "$CLANG")" 2>/dev/null
              cat user/linux-*.h "${BASH_SOURCE[0]}"
            } | sha256sum )"
ENV_SHA="${ENV_SHA:0:16}"
[ ${#ENV_SHA} = 16 ] || { echo "[hamlinux] ERROR: could not compute the runtime cache key" >&2; exit 1; }

CACHE_MISSED=0
# rt_obj <src> [extra clang args…] — put the path of the cached object for
# <src> in $RT_OBJ_PATH, compiling it first if this exact content has not been
# compiled into this cache yet.
#
# It ASSIGNS rather than echoes on purpose. `X=$(rt_obj …)` forks a subshell,
# and nine of those on the warm path — the path every one of the ~366 builds
# in a sweep takes — cost more than the hashing does. Same reason there is no
# `basename` here and no per-object `touch`: the warm path forks four
# processes in total (two sha256sum, a stat, a cat), and everything else is
# builtins.
RT_OBJ_PATH=""
rt_obj() {
    local src="$1"; shift
    local base="${src##*/}"; base="${base%.*}"
    RT_OBJ_PATH="$OBJ_DIR/.$base.${SRC_SHA[$src]}-$ENV_SHA.o"
    [ -f "$RT_OBJ_PATH" ] && return 0
    CACHE_MISSED=1
    local tmp="$RT_OBJ_PATH.tmp.$$"
    if ! "$CLANG" "$@" -Iuser -c "$src" -o "$tmp" >&2; then
        rm -f "$tmp"
        echo "[hamlinux] ERROR: could not compile $src" >&2
        return 1
    fi
    mv -f "$tmp" "$RT_OBJ_PATH" || { rm -f "$tmp"; return 1; }
}

#   user/linux-runtime.S   the freestanding half — the entry points that are a
#                          single raw `syscall`. -DADDER_HOSTED suppresses its
#                          _start (crt1.o owns that here) and the definitions
#                          the hosted half overrides.
rt_obj user/linux-runtime.S -x assembler-with-cpp -DADDER_HOSTED || exit 1
RT_OBJ="$RT_OBJ_PATH"
#   user/linux-syscalls.c  the hosted half — everything needing errno, wait4,
#                          poll or the resolver. See its header comment.
rt_obj user/linux-syscalls.c -O2 || exit 1
SC_OBJ="$RT_OBJ_PATH"
# The DRM/KMS framebuffer behind /dev/fb (HANDOFF §4.4).
rt_obj user/linux-fb.c -O2 || exit 1
FB_OBJ="$RT_OBJ_PATH"
# /dev/wsys, the window system device (the port of devwsys.ad).
rt_obj user/linux-wsys.c -O2 || exit 1
WS_OBJ="$RT_OBJ_PATH"
# /fd, the Plan 9 file-descriptor name space (HANDOFF §7.1).
rt_obj user/linux-fdns.c -O2 || exit 1
FD_OBJ="$RT_OBJ_PATH"
# /net, the Plan 9 network file tree (HANDOFF §3).
rt_obj user/linux-net.c -O2 $TLSFLAGS || exit 1
NET_OBJ="$RT_OBJ_PATH"
# /dev/auth, the credential device. -lcrypt for the SHA-512 verify.
rt_obj user/linux-auth.c -O2 || exit 1
AU_OBJ="$RT_OBJ_PATH"
# /dev/snarf and /dev/snarf.primary -- the clipboard device, the port of
# Hamnix's sys/src/9/port/devsnarf.ad onto a shared segment. NOT optional and
# NOT guarded like the audio stanza: every program in the tree links the
# runtime, lib/hamtextbox.ad and lib/htermsel.ad reach these two paths by name,
# and a missing object here is an undefined reference at link time rather than
# a program that builds and silently cannot paste.
rt_obj user/linux-snarf.c -O2 || exit 1
SN_OBJ="$RT_OBJ_PATH"
# /dev/audio, /dev/audioctl and /dev/audioin -- the port of Hamnix's
# drivers/audio/audio_cdev.ad onto ALSA. It talks to /dev/snd/pcmC*D*p through
# the kernel's own PCM ioctls, so there is no libasound to link and nothing
# extra for the initramfs to carry.
AUD_OBJ=""
if [ -f user/linux-audio.c ]; then
    rt_obj user/linux-audio.c -O2 || exit 1
    AUD_OBJ="$RT_OBJ_PATH"
fi

# Content keys never expire, so entries accumulate as the tree changes. Both
# halves of this run ONLY on the cold path — a warm build must not pay for
# either.
#
#   `touch` refreshes the objects this build used, so the prune below cannot
#   reach an entry that is in active service. It is one process for all nine,
#   and it is here rather than in rt_obj for that reason.
#
#   The prune is by AGE, not by "not the current key", so nothing a concurrent
#   link is reading can go away underneath it — a week-old object is not one
#   another worker has open. The pattern also collects the old fixed-name
#   objects (`.linux-wsys.o`) this block replaced, which are unreferenced now
#   and are precisely the dangerous ones.
if [ "$CACHE_MISSED" = 1 ]; then
    touch "$RT_OBJ" "$SC_OBJ" "$FB_OBJ" "$WS_OBJ" "$FD_OBJ" "$NET_OBJ" \
          "$AU_OBJ" "$SN_OBJ" ${AUD_OBJ:+"$AUD_OBJ"} 2>/dev/null
    find "$OBJ_DIR" -maxdepth 1 -name '.linux-*.o' -type f \
         -mtime +"${HAMLINUX_OBJ_CACHE_DAYS:-7}" -delete 2>/dev/null
fi

LL="${OUT_ELF%.elf}.ll"
[ "$LL" = "$OUT_ELF" ] && LL="$OUT_ELF.ll"

if ! "$HOST_AC" --backend=llvm "$IN_AD" "$LL" 2>"$LL.emit.log"; then
    sed 's/^/[emit] /' "$LL.emit.log" >&2
    exit 10
fi
grep -E "^; ADDER_STAT" "$LL" >&2 || true

if ! grep -q "^define i64 @main(" "$LL"; then
    # Which of the two is it? Ask the source, not the IR. See the exit-code
    # note in the header: a file with no top-level `def main` is a library
    # module and never had a main to bail.
    if grep -qE '^def[[:space:]]+main[[:space:]]*\(' "$IN_AD"; then
        echo "[hamlinux] ERROR: no @main emitted ($IN_AD declares main, so its body bailed the SSA subset); .ll=$LL" >&2
        exit 11
    fi
    echo "[hamlinux] NOT-AN-APPLICATION: $IN_AD has no 'def main' — it is a library module, imported by other programs, and there is nothing here to link into an ELF" >&2
    exit 13
fi

# --- per-program extra objects --------------------------------------------
# A few programs need more than the common runtime, and THE BUILD SCRIPT is
# where that has to be known -- not in one caller.
#
# This exists because it was got wrong. wsysd selects the Vulkan rasterization
# backend, so it needs user/linux-vk.c (the ICD shim), user/linux-vkhost.c
# (the glibc floor that makes lib/vk/vk_core.ad link at all) and -ldl. That
# was taught to scripts/hamlinux_image.sh alone, so the image built a working
# compositor and EVERY OTHER PATH -- this script invoked directly, which is
# what the docs tell you to do, and scripts/hamlinux_runsweep.sh -- failed to
# link the single most important program in the distribution with a wall of
# undefined hvk_* symbols. The run sweep caught it; a person following the
# README would have hit it first.
#
# They are NOT in the common list on purpose: nothing that draws a rectangle
# should acquire libdl and a Vulkan device bring-up. Per-program is the right
# granularity; one caller knowing about it was the bug.
EXTRA_OBJS=()
case "$(basename "$IN_AD" .ad)" in
    wsysd) EXTRA_OBJS=(user/linux-vk.c user/linux-vkhost.c -ldl) ;;
esac

if ! "$CLANG" "$OPTLVL" "$LL" scripts/adder_llvm_runtime.c "$RT_OBJ" "$SC_OBJ" "$FB_OBJ" "$WS_OBJ" "$FD_OBJ" "$NET_OBJ" "$AU_OBJ" "$SN_OBJ" ${AUD_OBJ:+"$AUD_OBJ"} \
        "${EXTRA_OBJS[@]}" \
        $TLSLIBS -lcrypt \
        "$@" -o "$OUT_ELF" 2>"$LL.link.log"; then
    sed 's/^/[link] /' "$LL.link.log" >&2
    exit 12
fi
echo "[hamlinux] built $OUT_ELF" >&2
exit 0
