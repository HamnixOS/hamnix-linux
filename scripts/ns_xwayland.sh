#!/usr/bin/env bash
# scripts/ns_xwayland.sh — LIFT THE DISTRIBUTION'S OWN Xwayland OUT OF ITS IMAGE
# AND MAKE IT RUNNABLE ON THIS HOST.
#
# WHY THIS EXISTS. `tests/linux/wsyswl_wheel.sh` measured the compositor against
# the DEV HOST's Xwayland (trixie, 24.1.6) while the Debian namespace ships
# **22.1.9** (bookworm), and the wheel bug it was chasing was green on one and
# present on the other. A gate that only ever tests a newer server than the
# distribution ships has a blind spot exactly the size of that difference, and
# no amount of care in the gate itself closes it -- only running the version
# that ships does.
#
# HOW, AND WHY NOT THE OBVIOUS WAY. Three ways to reach that binary:
#
#   * boot a VM with HAMLINUX_DISTRO_RO=1 and drive it -- honest, and ~4 minutes
#     per run plus a serial console to read the answer off. The wheel gate is
#     40 seconds; a version arm that costs six times the whole gate does not get
#     run.
#   * mount build/image/distro.ext4 -- needs root and a loop device, and it is
#     the SHARED image two other agents may be booting (docs/steam_namespace.md
#     §11). Not worth it for a read.
#   * read the file out of the ext4 with `debugfs`, which needs no mount, no
#     loop, no root and no write -- and pull its DT_NEEDED closure the same way.
#     16 MB, about a second, and the binary is byte for byte the one that ships.
#
# The third. What comes back is the namespace's Xwayland run through the
# namespace's OWN loader and libraries -- glibc, libwayland-client, libgbm,
# libepoxy -- so nothing about it is the host's except the kernel.
#
# `debugfs dump` does NOT follow symlinks, and every soname in a Debian library
# directory is one (libfoo.so.0 -> libfoo.so.0.4.2), so links are read off
# `stat` and chased by hand. Getting that wrong is not an error, it is an empty
# file, which is why the extraction is verified by running `Xwayland -version`
# before this script says it worked.
#
# Usage:  scripts/ns_xwayland.sh [dest-dir]
# Prints, on success, the path of a wrapper that runs it. Exits 2 (not 1) when
# the image simply is not there, so a caller can skip the arm rather than fail.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DEST="${1:-${NSXW_DEST:-$HOME/.hamnix-build/ns-xwayland}}"
IMG="${NSXW_IMG:-$PROJ_ROOT/build/image/distro.ext4}"
DEBUGFS="${DEBUGFS:-/sbin/debugfs}"

[ -r "$IMG" ] || { echo "ns_xwayland: no readable $IMG" >&2; exit 2; }
[ -x "$DEBUGFS" ] || { echo "ns_xwayland: no $DEBUGFS" >&2; exit 2; }
command -v readelf >/dev/null || { echo "ns_xwayland: need readelf" >&2; exit 2; }

ROOT="$DEST/root"
WRAP="$DEST/Xwayland"

# Already extracted and still runnable? Then say so and stop -- this is called
# from a gate that may run several times a minute.
if [ -x "$WRAP" ] && "$WRAP" -version >/dev/null 2>&1; then
    echo "$WRAP"
    exit 0
fi

rm -rf "$DEST"
mkdir -p "$ROOT"

linkdest() {
    "$DEBUGFS" -R "stat $1" "$IMG" 2>/dev/null |
        sed -n 's/.*Fast link dest: "\(.*\)".*/\1/p' | head -1
}

pull() {                        # pull <path-in-image>, chasing symlinks
    local p="$1" d t hops=0
    d="$ROOT$p"
    [ -e "$d" ] && return 0
    while :; do
        t="$(linkdest "$p")"
        [ -z "$t" ] && break
        hops=$((hops + 1)); [ "$hops" -gt 8 ] && return 1
        case "$t" in
            /*) p="$t" ;;
            *)  p="$(dirname "$p")/$t" ;;
        esac
    done
    mkdir -p "$(dirname "$d")"
    "$DEBUGFS" -R "dump $p $d" "$IMG" >/dev/null 2>&1
    [ -s "$d" ] || { rm -f "$d"; return 1; }
    chmod u+rw "$d"
    return 0
}

resolve() {                     # resolve <soname> across the usual lib dirs
    local so="$1" dir
    for dir in /usr/lib/x86_64-linux-gnu /lib/x86_64-linux-gnu /usr/lib /lib; do
        if pull "$dir/$so"; then echo "$dir/$so"; return 0; fi
    done
    return 1
}

declare -A seen
queue=()
add_needed() {
    local f="$1" so
    while read -r so; do
        [ -n "$so" ] || continue
        [ -n "${seen[$so]:-}" ] && continue
        seen[$so]=1
        queue+=("$so")
    done < <(readelf -d "$f" 2>/dev/null |
             sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')
}

pull /usr/bin/Xwayland || { echo "ns_xwayland: no /usr/bin/Xwayland in $IMG" >&2; exit 2; }
chmod 755 "$ROOT/usr/bin/Xwayland"
add_needed "$ROOT/usr/bin/Xwayland"

LOADER=/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2
pull "$LOADER" || { LOADER=/lib64/ld-linux-x86-64.so.2; pull "$LOADER"; } \
    || { echo "ns_xwayland: no dynamic loader in $IMG" >&2; exit 2; }
chmod 755 "$ROOT$LOADER"

missing=""
while [ "${#queue[@]}" -gt 0 ]; do
    so="${queue[0]}"; queue=("${queue[@]:1}")
    if p="$(resolve "$so")"; then
        chmod 755 "$ROOT$p"
        add_needed "$ROOT$p"
    else
        missing="$missing $so"
    fi
done
[ -n "$missing" ] && echo "ns_xwayland: NOT FOUND in the image:$missing" >&2

cat >"$WRAP" <<EOF
#!/bin/sh
# The Debian namespace's OWN Xwayland, lifted out of the distribution image by
# scripts/ns_xwayland.sh and run through that image's loader and libraries.
R="$ROOT"
exec "\$R$LOADER" \\
    --library-path "\$R/usr/lib/x86_64-linux-gnu:\$R/lib/x86_64-linux-gnu:\$R/usr/lib:\$R/lib" \\
    "\$R/usr/bin/Xwayland" "\$@"
EOF
chmod 755 "$WRAP"

# VERIFIED, NOT ASSUMED. A closure with one library missing produces a wrapper
# that exists and cannot run, and a caller that only checked for the file would
# report the arm as present and then skip every assertion in it.
if ! ver="$("$WRAP" -version 2>&1 | head -1)"; then
    echo "ns_xwayland: the extracted Xwayland will not run:" >&2
    "$WRAP" -version 2>&1 | sed 's/^/ns_xwayland:   /' >&2
    exit 1
fi
case "$ver" in
    *Xwayland*) ;;
    *) echo "ns_xwayland: unexpected -version output: $ver" >&2; exit 1 ;;
esac
echo "ns_xwayland: $ver" >&2
echo "$WRAP"
