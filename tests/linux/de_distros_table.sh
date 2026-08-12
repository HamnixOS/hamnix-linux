#!/usr/bin/env bash
# tests/linux/de_distros_table.sh — /etc/distros IS READ TO THE END, AND A ROW
# THE PANEL CANNOT READ IS NEVER A ROW IT SILENTLY DROPS.
#
# WHAT WAS WRONG
# ==============
# user/hampanelscene.ad's _load_distros() read the distribution table with ONE
# UNLOOPED CALL:
#
#     n: int64 = sys_read(fd, &_dm_buf[0], 2047)
#
# into a 2048-byte buffer. Two independent defects in one line:
#
#   * THE CEILING. etc/distros.linux ships at 1426 bytes, of which ~1300 is
#     the comment header that documents the format. 621 bytes of headroom, and
#     the rows that matter are at the END.
#   * THE SHORT READ, which has no size at all. read(2) may legally return
#     fewer bytes than asked for — from a pipe, a fifo, a slow device, a 9P
#     mount — and with no accumulate loop the rest of the table is simply
#     gone. What a short read costs here is exactly the distributions, because
#     the header is first.
#
# Either way the Applications menu loses its `Debian` and `Alpine` sections
# and NOTHING says so. The panel comes up, the menu opens, the sections are
# absent — the success-shaped answer NORTH_STAR.md names.
#
# WHAT THIS GATE DEFENDS
# ======================
#   1. THE SHIPPED FILE, VERBATIM. Its rows are parsed — header and all.
#   2. NO NEW CEILING. The same file behind a 65 KB header, and again behind a
#      300 KB one. A fix that works by raising 2047 to 8192 passes assertion 1
#      and fails these; that is what they are for.
#   3. A SHORT READ IS SURVIVED. The table is delivered through a FIFO in two
#      chunks with a pause between them, so the first read(2) returns the
#      header and nothing else. An unlooped reader takes the header for the
#      whole file. This is the half that no buffer size can fix.
#   4. AND WHEN A ROW REALLY IS TOO LONG, IT IS SAID OUT LOUD and the row is
#      NOT parsed — half a distribution name is a different distribution, and
#      entering the wrong one is what this table exists to prevent.
#
# HOW IT LOOKS AT THE PANEL WITHOUT A DISPLAY: user/hampanelscene.ad's
# `--scene-dump` hook builds the menu model (and therefore runs _load_distros)
# with no /dev/wsys at all. So this gate needs no compositor, no framebuffer
# and no VM, and runs in about a minute.
#
# The evidence it reads is the panel's own startup log:
#   [panel] /etc/distros: <bytes> byte(s), <lines> line(s), <n> attached ...
#   [panel] distribution not attached at /n/: <name>      (one per row parsed)
# The "not attached" line is printed for every row the parse UNDERSTOOD, which
# is exactly the question here — this host has no /n/debian, and whether the
# namespace is attached is a different gate (tests/linux/distro_menu.sh).
#
# REVERT-SENSITIVE: with user/hampanelscene.ad reverted, assertions 2, 3 and 4
# go red — the 65 KB and 300 KB tables parse ZERO rows, and the fifo delivers
# only its header.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT" || exit 1

# The panel writes /tmp/hamnix-panel.* under fixed names even on this path, so
# the run is isolated before anything is built. The call execs and does not
# return. (gates_are_private.sh fails an unlisted gate that starts the panel.)
. tests/linux/private_ns.sh
priv_ns_reexec "$@"
. tests/linux/reap.sh

pass=0; fail=0
ok()   { echo "distros: PASS $*"; pass=$((pass+1)); }
bad()  { echo "distros: FAIL $*"; fail=$((fail+1)); }
info() { echo "distros: INFO $*"; }

WORK="${DISTROS_WORK:-$(mktemp -d -p "${TMPDIR:-/tmp}" distros.XXXXXX)}"
mkdir -p "$WORK"
reap_track "$WORK/reaped"
reap_on_exit
info "$(priv_ns_describe)"

SHIPPED="$PROJ_ROOT/etc/distros.linux"
[ -r "$SHIPPED" ] || { bad "etc/distros.linux is missing"; exit 1; }

# ---- 0. THE FILE IS THE HARD CASE, measured not assumed -------------------
read -r SZ FIRSTROW <<EOF
$(python3 - "$SHIPPED" <<'PY'
import re, sys
d = open(sys.argv[1], 'rb').read()
first = -1
off = 0
for line in d.splitlines(True):
    s = line.split(b'#', 1)[0].split()
    if len(s) >= 2:
        first = off
        break
    off += len(line)
print(len(d), first)
PY
)
EOF
info "etc/distros.linux is $SZ bytes; its first real row begins at byte $FIRSTROW"
if [ "${FIRSTROW:-0}" -gt 1000 ]; then
    ok "(0) the shipped table's rows are behind a $FIRSTROW-byte header -- a truncated read of this file loses the distributions, not the comments"
else
    bad "(0) the shipped table's first row is at byte ${FIRSTROW:-?}, so this gate no longer reproduces the shape it exists for"
fi

# ---- build ---------------------------------------------------------------
BIN="${DISTROS_BIN:-}"
if [ -z "$BIN" ]; then
    if [ -z "${ADDER_HOST_AC:-}" ]; then
        ADDER_HOST_AC="$PROJ_ROOT/build/cutover/host_ac_llvm.elf"
        [ -x "$ADDER_HOST_AC" ] || ADDER_HOST_AC="$PROJ_ROOT/build/cutover/host_ac.elf"
    fi
    export ADDER_HOST_AC
    nice -n 15 scripts/hamlinux_build.sh user/hampanelscene.ad \
        "$WORK/hampanelscene.elf" >"$WORK/build.log" 2>&1 || {
        bad "could not build user/hampanelscene.ad"; tail -20 "$WORK/build.log"
        echo "distros: $pass passed, $fail failed"; exit 1; }
    BIN="$WORK/hampanelscene.elf"
fi
info "panel under test: $BIN"

# ---- a private /etc, so the fixture can BE /etc/distros -------------------
# /etc/distros is a fixed path (rightly: it is the machine's description, not
# a runtime override), so the only honest way to feed it a fixture is to give
# this namespace its own /etc. The host's /etc is bind-mounted aside first and
# every entry symlinked back, so ld.so.cache, passwd and the rest still
# resolve; only `distros` is ours. Nothing outside this mount namespace can
# see any of it.
mkdir -p "$WORK/etcref"
python3 - "$WORK/etcref" <<'PY' || { echo "distros: SKIP: cannot build a private /etc here"; exit 0; }
import ctypes, os, sys
libc = ctypes.CDLL("libc.so.6", use_errno=True)
def mount(src, tgt, fs, flags, data):
    r = libc.mount(src.encode() if src else None, tgt.encode(),
                   fs.encode() if fs else None, ctypes.c_ulong(flags),
                   data.encode() if data else None)
    if r != 0:
        sys.stderr.write("distros: cannot mount %s: %s\n"
                         % (tgt, os.strerror(ctypes.get_errno())))
        raise SystemExit(1)
MS_BIND, MS_REC = 4096, 16384
ref = sys.argv[1]
mount("/etc", ref, None, MS_BIND | MS_REC, None)
mount("none", "/etc", "tmpfs", 0, "mode=755")
for e in os.listdir(ref):
    try:
        os.symlink(os.path.join(ref, e), os.path.join("/etc", e))
    except OSError:
        pass
PY
[ -e /etc/passwd ] || { info "SKIP: the private /etc did not come up"; exit 0; }
ok "(0b) this run has its own /etc (the host's is bind-mounted aside and symlinked back; only /etc/distros is the fixture)"

# ---- the driver ----------------------------------------------------------
# Runs the panel's menu-model build with no display and returns its log.
panel_log() {   # panel_log <logfile>
    ( cd "$WORK" && timeout 60 "$BIN" --scene-dump "$WORK/scene.out" ) \
        >"$1" 2>&1
    return 0
}
rows_seen() { grep -c 'distribution not attached at /n/: ' "$1"; }
row_named() { grep -q "distribution not attached at /n/: $2\$" "$1"; }

pad_table() {   # pad_table <header-bytes> <out>
    python3 - "$SHIPPED" "$1" "$2" <<'PY'
import sys
src, n, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
line = "# " + ("h" * 117) + "\n"
d = open(src).read()
with open(out, "w") as f:
    f.write(line * (n // len(line)))
    f.write(d)
PY
}

# ---- 1. the shipped table, verbatim --------------------------------------
cp "$SHIPPED" /etc/distros
panel_log "$WORK/log.shipped"
n=$(rows_seen "$WORK/log.shipped")
if [ "$n" -ge 2 ] && row_named "$WORK/log.shipped" debian \
   && row_named "$WORK/log.shipped" alpine; then
    ok "(1) the shipped $SZ-byte table parses its rows: $n row(s), debian and alpine both named"
else
    bad "(1) the shipped table parsed $n row(s) and did not name both debian and alpine"
    grep -a 'distros\|distribution' "$WORK/log.shipped" | head -5
fi
if grep -qa "/etc/distros: $SZ byte(s), " "$WORK/log.shipped"; then
    ok "(1b) and the panel says how much it read: $(grep -oa '/etc/distros: .*' "$WORK/log.shipped" | head -1)"
else
    bad "(1b) the panel did not report the byte count it read"
    grep -a '/etc/distros' "$WORK/log.shipped" | head -3
fi

# ---- 2. NO NEW CEILING ---------------------------------------------------
for hdr in 65536 307200; do
    pad_table "$hdr" /etc/distros
    tsz=$(wc -c < /etc/distros)
    panel_log "$WORK/log.$hdr"
    n=$(rows_seen "$WORK/log.$hdr")
    if [ "$n" -ge 2 ] && row_named "$WORK/log.$hdr" debian \
       && row_named "$WORK/log.$hdr" alpine; then
        ok "(2.$hdr) the same rows behind a $hdr-byte header ($tsz bytes total) still parse"
    else
        bad "(2.$hdr) a $tsz-byte table parsed $n row(s) -- the ceiling moved, it did not go"
        grep -a '/etc/distros' "$WORK/log.$hdr" | head -3
    fi
done

# ---- 3. A SHORT READ IS SURVIVED -----------------------------------------
# No buffer size fixes this one. The table arrives through a FIFO in two
# writes with a pause between them: the first read(2) returns the header and
# stops. An unlooped reader calls that the whole file.
rm -f /etc/distros
mkfifo /etc/distros 2>/dev/null || { info "(3) SKIP: cannot make a fifo at /etc/distros"; }
if [ -p /etc/distros ]; then
    python3 - "$SHIPPED" "$WORK/half1" "$WORK/half2" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
cut = d.rfind(b'\n', 0, len(d) - 200) + 1     # split before the rows
open(sys.argv[2], 'wb').write(d[:cut])
open(sys.argv[3], 'wb').write(d[cut:])
print("distros: INFO fifo halves: %d bytes then %d" % (cut, len(d) - cut))
PY
    # ONE writer holding the fifo open across the pause. Two `cat`s would be
    # two writers, and the reader would see EOF when the first one closed --
    # which would make an unlooped reader look correct for the wrong reason.
    ( exec 3>/etc/distros
      cat "$WORK/half1" >&3
      sleep 0.5
      cat "$WORK/half2" >&3
      exec 3>&- ) &
    fifopid=$!
    reap_add "$fifopid"
    panel_log "$WORK/log.fifo"
    wait "$fifopid" 2>/dev/null
    n=$(rows_seen "$WORK/log.fifo")
    if [ "$n" -ge 2 ]; then
        ok "(3) a table delivered in two short reads is still read to the end: $n row(s)"
    else
        bad "(3) a short read truncated the table -- $n row(s) parsed. No buffer size fixes this"
        grep -a '/etc/distros\|distribution' "$WORK/log.fifo" | head -4
    fi
    rm -f /etc/distros
fi

# ---- 4. a row that really is too long is LOUD, and is NOT parsed ---------
python3 - "$SHIPPED" /etc/distros <<'PY'
import sys
d = open(sys.argv[1]).read()
with open(sys.argv[2], "w") as f:
    f.write(d)
    f.write("%s LABEL=hamnix-monster\n" % ("m" * 900))    # one 900-char name
PY
panel_log "$WORK/log.longrow"
if grep -qa 'TRUNCATED' "$WORK/log.longrow"; then
    ok "(4) an over-long row is reported: $(grep -oa '/etc/distros: TRUNCATED.*' "$WORK/log.longrow" | head -1)"
else
    bad "(4) a 900-character row was swallowed without a word"
    grep -a '/etc/distros' "$WORK/log.longrow" | head -3
fi
if grep -qa 'distribution not attached at /n/: mmm' "$WORK/log.longrow"; then
    bad "(4b) and HALF THE NAME was parsed as a distribution -- half a name is a different distribution"
else
    ok "(4b) and the cut row was not parsed at all: half a name is never taken for a name"
fi

# ---- 5. the control: no file at all --------------------------------------
rm -f /etc/distros
panel_log "$WORK/log.none"
if grep -qa 'no /etc/distros' "$WORK/log.none"; then
    ok "(5) control: with no table at all the panel says so, and 'absent' still reads differently from 'empty'"
else
    bad "(5) a missing /etc/distros produced no diagnostic"
    head -5 "$WORK/log.none"
fi

echo "distros: $pass passed, $fail failed"
[ "$fail" = 0 ]
