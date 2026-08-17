#!/usr/bin/env bash
#
# REGISTRATION, 2026-08-17. Until this date scripts/test_gate_registration.sh
# globbed only scripts/test_*.sh, so this directory was invisible to the gate
# against unregistered gates and every file in it read as coverage without
# being coverage. This gate is ON-DEMAND: not in ci_battery_manifest.txt
# because nobody has measured its host runtime yet, and the battery is 12-way
# sharded under a 50-minute cap -- registering an unmeasured gate is how a
# shard goes from green to timed-out. Measure it, then move it into the
# manifest.
#
# Its host runtime and its pass/fail were NOT measured when this line was
# written. If you make it cheap enough for the battery, add the manifest line
# and delete this block.
#
# tests/linux/wsys_write_census.sh — HOW MANY WRITES A SECOND, AND OF WHAT KIND.
#
# WHY THIS GATE EXISTS
# ====================
# THE SPLIT in user/linux-wsys.c records the only mechanism that can close the
# window-table bypass tests/linux/wsys_bypass.sh drives: an RPC to `wsysd` that
# authenticates the peer's pid (SO_PEERCRED) against the window's owner, because
# a per-owner-uid mapping cannot tell two uid-1001 processes apart and that is
# the attack that matters.  It then records why it was not built: a round trip
# per frame and per keystroke would put the compositor on every client's hot
# path, so the sound design is a HYBRID -- identity and lifecycle behind the
# channel, per-frame pixels still in shared memory.
#
# THE WHOLE HYBRID RESTS ON THAT SPLIT BEING LOPSIDED, and until this file the
# lopsidedness was an ARGUMENT.  This tree's rule is that a measurement is worth
# more than an argument -- including one made by the person who wrote the file.
# So this gate MEASURES it: a real desktop (wsysd + hamdesktop + hampanelscene,
# entirely offscreen), idle for one window and under a synthetic mouse for
# another, with every mutation of the window table counted at the one choke
# point all of them pass through (THE WRITE CENSUS in user/linux-wsys.c) and
# classified:
#
#   LIFECYCLE   newwindow, destroy, setowner, focus/raise, title, geometry, z,
#               and the window attributes (decorate/visible/keyed/blend/…).
#               What an RPC authority would have to arbitrate, because these
#               are the fields whose forgery IS the attack: a title is what a
#               spoofed window shows the person, and the owner pid is what any
#               later check would be only as trustworthy as.
#   PER-FRAME   scene bytes, commits, blits, damage, image uploads, and the
#               five routed input rings.  What an authority must NEVER see,
#               because it happens per frame and per keystroke.
#
# WHAT IT ASSERTS, and why these and not a fixed number of writes per second:
# the absolute rate is a property of this host's speed and is reported, not
# gated.  What is GATED is the shape the design depends on:
#   1. the per-frame traffic is at least CENSUS_RATIO times the lifecycle
#      traffic (default 20), so an RPC on the lifecycle half is affordable;
#   2. the lifecycle rate is under CENSUS_LIFE_MAX per second across the whole
#      session (default 50), so a single-threaded authority can serve it;
#   3. an IDLE desktop does no lifecycle work at all beyond a small constant --
#      if bringing up a window cost a round trip, an idle desktop would cost
#      none, which is the property that makes the design safe on a laptop;
#   4. the census instrument is OFF by default -- a run with HAMWSYS_WRSTAT
#      unset creates no files at all.  A measurement that changes the thing it
#      measures on every boot would be worse than no measurement.
#
# Entirely offscreen (HAMFB_FILE + a file of evdev records): no VM, no display,
# no GPU.  The software Vulkan ICD is forced because wsysd has a real Vulkan
# backend and this host's GPU belongs to someone.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

# The desktop stack writes FIXED, HOST-GLOBAL names whatever this script does
# about its own $WORK: hampanelscene writes /tmp/hamnix-panel.{health,fault},
# /tmp/hamnix-panel-drop and /tmp/hamnix-notif.log; hamdesktop writes
# /tmp/hamdesktop-wp.status and /tmp/.hamdesktop.src. Those names are compiled
# into the programs under test, so no care taken here can move them, and a
# concurrent run -- another agent's, or a person's live desktop on this
# machine -- reads exactly those files. tests/linux/private_ns.sh records what
# that cost the day a gate was found writing /tmp/hamnix-panel.conf. This call
# puts everything below inside a mount namespace where /tmp, /dev/shm and /srv
# are this run's alone; it execs, and does not return.
#
# NOTE for a KEEP=1 post-mortem: $WORK is inside that private /tmp and goes
# with it. Use priv_ns_keep to copy anything you want to outlive the run.
. tests/linux/private_ns.sh
priv_ns_reexec "$@"

WORK="${CENSUS_WORK:-$(mktemp -d -p "${TMPDIR:-/tmp}" wrcensus.XXXXXX)}"
mkdir -p "$WORK"
KEEP="${CENSUS_KEEP:-0}"
GEOM="${HAMFB_GEOM:-1280x800}"
FBW="${GEOM%x*}"; FBH="${GEOM#*x}"
IDLE_SECS="${CENSUS_IDLE:-10}"
BUSY_SECS="${CENSUS_BUSY:-12}"
RATIO_MIN="${CENSUS_RATIO:-20}"
LIFE_MAX="${CENSUS_LIFE_MAX:-50}"

export HAMWSYS="$WORK/wsys.shm"
export HAMWSYS_BB="$WORK/wsys.bb"
export HAMWSYS_IMG="$WORK/wsys.img"
export HAMFB_FILE="$WORK/fb.raw"
export HAMFB_GEOM="$GEOM"
[ -r /usr/share/vulkan/icd.d/lvp_icd.json ] && \
    export VK_ICD_FILENAMES="${VK_ICD_FILENAMES:-/usr/share/vulkan/icd.d/lvp_icd.json}"

pass=0; fail=0
ok()   { echo "census: PASS $*"; pass=$((pass+1)); }
bad()  { echo "census: FAIL $*"; fail=$((fail+1)); }
info() { echo "census: INFO $*"; }

PIDS=""
cleanup() {
    for p in $PIDS; do [ -n "${p:-}" ] && kill "$p" 2>/dev/null; done
    sleep 0.3
    for p in $PIDS; do [ -n "${p:-}" ] && kill -9 "$p" 2>/dev/null; done
    [ "$KEEP" = 1 ] || rm -rf "$WORK"
}
trap cleanup EXIT
# A bare EXIT trap does not run when the shell is killed by a signal, so a
# gate stopped by `timeout` (TERM) or ^C (INT) skipped its cleanup entirely.
# Re-exit on those, which makes the EXIT trap above run on every path out.
trap 'exit 130' INT TERM HUP
done_report() { echo "census: $pass passed, $fail failed"; [ "$fail" = 0 ]; }

# ---- the reader -----------------------------------------------------------
# The category names live IN the file (see struct wrstat), so this script does
# not carry a copy of that enum that could drift away from it.
READ_PY="$WORK/read.py"
cat >"$READ_PY" <<'PY'
import struct, sys, glob, os
# LIFECYCLE vs PER-FRAME.  The classification is here and nowhere else, and it
# is by NAME, so a category added to the C enum and not classified here shows
# up as "unclassified" rather than being silently counted as harmless.
LIFE  = {"newwindow","destroy","setowner","focus","title","geometry","attr"}
FRAME = {"scene","commit","blit","damage","cursor","image",
         "keys","pointer","event","text","cmd"}
OTHER = {"sink","chrome","globalctl"}

def read(path):
    d = open(path,'rb').read()
    if len(d) < 40 or d[:8] != b'HAMWRST1':
        return None
    ncat, namelen = struct.unpack_from('<II', d, 8)
    t0, t1 = struct.unpack_from('<QQ', d, 16)
    pid,  = struct.unpack_from('<i', d, 32)
    off = 40
    names = [d[off+i*namelen: off+i*namelen+namelen].split(b'\0')[0].decode()
             for i in range(ncat)]
    off += ncat*namelen
    cnt = struct.unpack_from('<%dQ' % ncat, d, off); off += ncat*8
    byt = struct.unpack_from('<%dQ' % ncat, d, off)
    return dict(pid=pid, span=(t1-t0)/1e9, names=names, cnt=cnt, byt=byt,
                proc=os.path.basename(path).split('.')[1])

def totals(paths):
    agg, bagg, span = {}, {}, 0.0
    per = []
    for p in sorted(paths):
        r = read(p)
        if not r: continue
        per.append(r)
        span = max(span, r['span'])
        for n,c,b in zip(r['names'], r['cnt'], r['byt']):
            agg[n] = agg.get(n,0)+c
            bagg[n] = bagg.get(n,0)+b
    return agg, bagg, span, per

mode = sys.argv[1]
agg, bagg, span, per = totals(glob.glob(os.path.join(sys.argv[2], 'wr.*')))
if mode == 'report':
    wall = float(sys.argv[3])
    print("  %-12s %10s %10s %14s" % ("category","count","per sec","bytes"))
    for n in sorted(agg, key=lambda k: -agg[k]):
        if agg[n] == 0: continue
        kind = "LIFE " if n in LIFE else "FRAME" if n in FRAME else \
               "other" if n in OTHER else "UNCLASSIFIED"
        print("  %-12s %10d %10.1f %14d   %s" %
              (n, agg[n], agg[n]/wall, bagg[n], kind))
    for r in per:
        tot = sum(r['cnt'])
        if tot:
            print("  proc %-16s pid %-7d writes %d" % (r['proc'], r['pid'], tot))
elif mode == 'sums':
    wall = float(sys.argv[3])
    life  = sum(v for k,v in agg.items() if k in LIFE)
    frame = sum(v for k,v in agg.items() if k in FRAME)
    other = sum(v for k,v in agg.items() if k in OTHER)
    unk   = sum(v for k,v in agg.items() if k not in LIFE|FRAME|OTHER)
    # The pointer count comes out too: it is the one category that proves the
    # synthetic mouse actually reached a client, and assertion 0 needs it.
    print("%d %d %d %d %.3f %.3f %d" % (life, frame, other, unk,
                                        life/wall, frame/wall,
                                        agg.get("pointer", 0)))
PY

# ---- build ----------------------------------------------------------------
for t in wsysd:user/wsysd.ad \
         hamdesktop:user/hamdesktop.ad \
         hampanelscene:user/hampanelscene.ad \
         wsys_poke:tests/linux/wsys_poke.ad; do
    name="${t%%:*}"; src="${t#*:}"
    scripts/hamlinux_build.sh "$src" "$WORK/$name.elf" \
        >"$WORK/$name.build.log" 2>&1 || {
        bad "could not build $src"; tail -20 "$WORK/$name.build.log" >&2
        done_report; exit 1; }
done
ok "the compositor, the desktop and the panel all build"

# ---- 4. THE INSTRUMENT IS OFF UNLESS ASKED FOR ---------------------------
# Measured FIRST, before anything sets HAMWSYS_WRSTAT, because a census that
# is on by default is a cost every boot pays for a number nobody reads.
OFFDIR="$WORK/census.off"; mkdir -p "$OFFDIR"
unset HAMWSYS_WRSTAT
"$WORK/wsys_poke.elf" /dev/wsys/ctl >/dev/null 2>&1
if [ -z "$(ls -A "$OFFDIR" 2>/dev/null)" ]; then
    ok "with HAMWSYS_WRSTAT unset the census writes nothing at all"
else
    bad "the census produced files with no directory named: $(ls -A "$OFFDIR")"
fi

CDIR="$WORK/census"; mkdir -p "$CDIR"
export HAMWSYS_WRSTAT="$CDIR"

# ---- the mouse ------------------------------------------------------------
: >"$WORK/input.evdev"
export HAMWSYSD_INPUT="$WORK/input.evdev"
EVDEV_PY="$WORK/evdev.py"
cat >"$EVDEV_PY" <<'PY'
import struct, sys
path, W, H = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
recs = []
for tok in sys.argv[4:]:
    kind, *a = tok.split(':')
    if kind == 'move':
        x, y = int(a[0]), int(a[1])
        recs += [(3, 0, x * 32768 // W), (3, 1, y * 32768 // H), (0, 0, 0)]
    elif kind == 'down':
        recs += [(1, 272, 1), (0, 0, 0)]
    elif kind == 'up':
        recs += [(1, 272, 0), (0, 0, 0)]
with open(path, 'ab') as f:
    for t, c, v in recs:
        f.write(struct.pack('<qqHHi', 0, 0, t, c, v))
PY
ev() { python3 "$EVDEV_PY" "$WORK/input.evdev" "$FBW" "$FBH" "$@"; }

# ---- bring the session up -------------------------------------------------
"$WORK/wsysd.elf" </dev/null >"$WORK/wsysd.log" 2>&1 &
PIDS="$PIDS $!"
for _ in $(seq 1 60); do [ -s "$HAMFB_FILE" ] && break; sleep 0.1; done
[ -s "$HAMFB_FILE" ] || { bad "wsysd never produced a framebuffer"
                          cat "$WORK/wsysd.log"; done_report; exit 1; }
"$WORK/hamdesktop.elf" </dev/null >"$WORK/hamdesktop.log" 2>&1 &
PIDS="$PIDS $!"
sleep 3
"$WORK/hampanelscene.elf" </dev/null >"$WORK/hampanelscene.log" 2>&1 &
PIDS="$PIDS $!"
sleep 3

WIN_N="$(for wid in $(seq 2 40); do
             "$WORK/wsys_poke.elf" "/dev/wsys/$wid/ctl" 2>/dev/null | head -1
         done | grep -c .)"
if [ "${WIN_N:-0}" -ge 2 ]; then
    ok "a real session is up: $WIN_N windows mapped"
else
    bad "the session never mapped its windows -- there is nothing to measure"
    sed 's/^/census:      /' "$WORK/hampanelscene.log"
    done_report; exit 1
fi

# ---- PHASE A: bring-up, and then IDLE ------------------------------------
# The bring-up census is snapshotted, so phase A's numbers are the IDLE
# desktop's alone and not the startup burst's.
snapshot() { rm -rf "$1"; mkdir -p "$1"; cp "$CDIR"/wr.* "$1/" 2>/dev/null; }
delta_py() {   # delta_py <before-dir> <after-dir> <mode> <wall>
    python3 - "$1" "$2" "$3" "$4" "$READ_PY" <<'PY'
import sys, subprocess, glob, os, struct
before, after, mode, wall, readpy = sys.argv[1:6]
# Subtract by rewriting the after-files into a temp dir with before subtracted.
import tempfile, shutil
tmp = tempfile.mkdtemp()
def load(p):
    d = bytearray(open(p,'rb').read())
    ncat, namelen = struct.unpack_from('<II', d, 8)
    return d, ncat, namelen, 40 + ncat*namelen
prev = {os.path.basename(p): load(p) for p in glob.glob(os.path.join(before,'wr.*'))}
for p in glob.glob(os.path.join(after,'wr.*')):
    d, ncat, namelen, off = load(p)
    b = os.path.basename(p)
    if b in prev:
        pd, _, _, poff = prev[b]
        for i in range(ncat*2):
            a = struct.unpack_from('<Q', d, off + i*8)[0]
            o = struct.unpack_from('<Q', pd, poff + i*8)[0]
            struct.pack_into('<Q', d, off + i*8, a - o if a >= o else a)
    open(os.path.join(tmp, b), 'wb').write(bytes(d))
subprocess.run([sys.executable, readpy, mode, tmp, wall], check=True)
shutil.rmtree(tmp)
PY
}

snapshot "$WORK/snap.bringup"
info "----- phase A: the desktop as rc.5 leaves it, IDLE for ${IDLE_SECS}s -----"
sleep "$IDLE_SECS"
snapshot "$WORK/snap.idle"
delta_py "$WORK/snap.bringup" "$WORK/snap.idle" report "$IDLE_SECS"
read -r A_LIFE A_FRAME A_OTHER A_UNK A_LRATE A_FRATE A_POINTER < <(
    delta_py "$WORK/snap.bringup" "$WORK/snap.idle" sums "$IDLE_SECS")

# ---- PHASE B: a person using it ------------------------------------------
info "----- phase B: a synthetic mouse, ${BUSY_SECS}s -----"
BUSY_START="$(date +%s.%N)"
END=$(( $(date +%s) + BUSY_SECS ))
x=100
while [ "$(date +%s)" -lt "$END" ]; do
    ev "move:$x:$((120 + x % 300))"
    x=$(( (x + 37) % 1100 + 20 ))
    if [ $(( x % 5 )) -lt 2 ]; then ev "down"; ev "up"; fi
    sleep 0.05
done
sleep 1
BUSY_WALL="$(python3 -c "import sys;print(round(float(sys.argv[2])-float(sys.argv[1]),3))" \
             "$BUSY_START" "$(date +%s.%N)")"
snapshot "$WORK/snap.busy"
delta_py "$WORK/snap.idle" "$WORK/snap.busy" report "$BUSY_WALL"
read -r B_LIFE B_FRAME B_OTHER B_UNK B_LRATE B_FRATE B_POINTER < <(
    delta_py "$WORK/snap.idle" "$WORK/snap.busy" sums "$BUSY_WALL")

# ---- and the whole session, bring-up included ----------------------------
info "----- the whole session, bring-up included -----"
python3 "$READ_PY" report "$CDIR" "$BUSY_WALL" | sed 's/^/census: /'

echo "census:"
echo "census: THE SPLIT, MEASURED"
echo "census:   phase A (idle, ${IDLE_SECS}s):  lifecycle $A_LIFE ($A_LRATE/s)   per-frame $A_FRAME ($A_FRATE/s)"
echo "census:   phase B (mouse, ${BUSY_WALL}s): lifecycle $B_LIFE ($B_LRATE/s)   per-frame $B_FRAME ($B_FRATE/s)"
echo "census:"

# ---- the assertions -------------------------------------------------------
# 0. THE GATE MUST NOT PASS ON ZEROS, and this assertion exists because the
#    first draft of this file DID.  Run with the census instrument reverted out
#    of user/linux-wsys.c the whole gate came back "7 passed, 0 failed" with
#    every category empty: the ratio assertion divided 0 per-frame by 0
#    lifecycle, took the "no lifecycle writes at all" sentinel, and reported
#    999999:1.  A measurement gate that is green when it measured NOTHING is
#    the exact success-shaped answer NORTH_STAR.md names, and it would have
#    stayed green through any future change that broke the instrument.  So the
#    denominator is checked before anything is concluded from it.
CENSUS_FILES="$(ls -1 "$CDIR" 2>/dev/null | grep -c '^wr\.')"
if [ "${CENSUS_FILES:-0}" -ge 3 ]; then
    ok "the census produced a file per process ($CENSUS_FILES of them)"
else
    bad "the census produced $CENSUS_FILES files -- the instrument is not in this build, and every number below would be a zero dressed as an answer"
fi
if [ "${A_FRAME:-0}" -gt 0 ] && [ "${B_FRAME:-0}" -gt 0 ]; then
    ok "both phases recorded per-frame traffic (idle $A_FRAME, mouse $B_FRAME)"
else
    bad "a phase recorded NO per-frame writes at all (idle $A_FRAME, mouse $B_FRAME) -- a desktop that writes nothing is a desktop that is not running, or an instrument that is not counting"
fi
if [ "${B_POINTER:-0}" -gt 0 ]; then
    ok "the synthetic mouse reached a window's rings ($B_POINTER pointer writes)"
else
    bad "no pointer write was counted under a moving mouse -- the census is not seeing the hot path it exists to size"
fi

if [ "${A_UNK:-0}" = 0 ] && [ "${B_UNK:-0}" = 0 ]; then
    ok "every counted category is classified LIFECYCLE, PER-FRAME or other"
else
    bad "an unclassified write category appeared (idle $A_UNK, busy $B_UNK) -- the C enum grew and this script did not"
fi

# 1. lopsided, which is the property the hybrid rests on.
# No sentinel for f==0: a ratio computed from no per-frame traffic at all is
# not a large ratio, it is an absent measurement, and assertion 0 above has
# already said so.  0/0 reports 0 and fails this, which is the honest answer.
RATIO="$(python3 -c "import sys;l=int(sys.argv[1]);f=int(sys.argv[2]);print(0 if f==0 else (999999 if l==0 else f//l))" \
         "$B_LIFE" "$B_FRAME")"
if [ "$RATIO" -ge "$RATIO_MIN" ]; then
    ok "under a mouse, per-frame writes outnumber lifecycle writes ${RATIO}:1 (>= ${RATIO_MIN}:1)"
else
    bad "the split is NOT lopsided: per-frame ${RATIO}:1 lifecycle (needed ${RATIO_MIN}:1) -- an RPC on the lifecycle half is not obviously affordable, and THE SPLIT's hybrid needs re-arguing"
fi

# 2. an authority would have to serve the lifecycle rate.
if python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) <= float(sys.argv[2]) else 1)" \
     "$B_LRATE" "$LIFE_MAX"; then
    ok "the lifecycle rate under a mouse is $B_LRATE/s (<= $LIFE_MAX/s): one authority can serve it"
else
    bad "the lifecycle rate is $B_LRATE/s, over the $LIFE_MAX/s an RPC authority was sized for"
fi

# 3. an idle desktop must cost an authority nothing.
if python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) <= 1.0 else 1)" "$A_LRATE"; then
    ok "an IDLE desktop makes $A_LIFE lifecycle writes in ${IDLE_SECS}s ($A_LRATE/s): an authority sleeps"
else
    bad "an idle desktop makes $A_LRATE lifecycle writes a second -- an RPC would run forever on an idle laptop"
fi

echo "census:"
echo "census: WHAT THIS DOES NOT MEASURE, stated so nobody reads it as more"
echo "census: than it is: one desktop, no browser and no Xwayland. wsyswl"
echo "census: spends a window row per X toplevel, so a Steam session's"
echo "census: LIFECYCLE rate is higher than anything here -- bounded by"
echo "census: MAXCONN*WINPERCONN = 256 windows, each created once."
done_report
