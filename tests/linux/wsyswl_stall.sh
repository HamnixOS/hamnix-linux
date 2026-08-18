#!/usr/bin/env bash
#
# REGISTRATION, 2026-08-17. Until this date scripts/test_gate_registration.sh
# globbed only scripts/test_*.sh, so this directory was invisible to the gate
# against unregistered gates and every file in it read as coverage without
# being coverage. This gate is ON-DEMAND: not in ci_battery_manifest.txt
# because it was MEASURED on 2026-08-17 and exited 1 in 14 s on a host with the channel and the image built, so it does not pass unattended here yet.
#
#
# tests/linux/wsyswl_stall.sh — does the compositor KEEP delivering a surface?
#
#   X11 client -> Xwayland (rootful) -> wsyswl (Adder) -> /dev/wsys -> wsysd -> /dev/fb
#
# Steam's login window was mapped, viewable and fully PAINTED on the X screen,
# and the framebuffer did not have it. The control that settled what that meant
# needed no Steam at all: put an xterm in the same session, let it paint, then
# MOVE it. Rootful Xwayland presents the whole X screen as ONE wl_surface, so
# if the scanout does not follow the move, the surface has stopped being
# delivered and nothing about the bug is Steam-specific.
#
# This is that control, offscreen: HAMFB_FILE for the framebuffer and the
# HOST's Xwayland, so it touches no display and needs no VM. It then HAMMERS
# the surface -- dozens of moves and resizes, which is what makes Xwayland
# churn through pixmaps, shm pools and object ids -- and finishes by reading
# the compositor's own counters out of the `wsyswl-state` file it publishes
# beside its socket. A frame this server throws away is counted there by
# reason, so "it stalled" is answerable rather than arguable.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

# THE MACHINE THIS RUNS ON IS NOT SCRATCH.
#
# It runs wsyswl and a Wayland client; the socket is in $XDG_RUNTIME_DIR.
#
# The names that matter are compiled into the binaries, not written here, so no
# care taken in this script can move them; the containment is the namespace.
# tests/linux/private_ns.sh has the table and the incident that bought it. This
# must come before anything that makes a file under /tmp, $WORK included, and
# before reap.sh, whose registry is itself a mktemp under /tmp.
. tests/linux/private_ns.sh
priv_ns_reexec "$@"

WORK="${WLSTALL_WORK:-$(mktemp -d -p "${TMPDIR:-/tmp}" wlstall.XXXXXX)}"
mkdir -p "$WORK"
GEOM="${HAMFB_GEOM:-1280x800}"
KEEP="${WLSTALL_KEEP:-0}"
ROUNDS="${WLSTALL_ROUNDS:-40}"
export HAMWSYS="$WORK/wsys.shm"
export HAMFB_FILE="$WORK/fb.raw"
export HAMFB_GEOM="$GEOM"
# PRIVATE, AND THAT IS NOT TIDINESS. The v2 backbuffer segment defaults to
# /srv/wsys.bb, then /dev/shm/hamnix-wsys-bb -- one file per HOST, outliving
# every process that ever touched it. Two runs (or two agents) sharing it hand
# each other stale slots keyed by wid, which is precisely the fault this test
# exists to catch; a test that inherits one is measuring the last run.
export HAMWSYS_BB="$WORK/wsys.bb"
# The compositor has a real Vulkan backend and this host has an NVIDIA card in
# it that belongs to someone. Software ICD, always, for anything offscreen.
[ -r /usr/share/vulkan/icd.d/lvp_icd.json ] && \
    export VK_ICD_FILENAMES="${VK_ICD_FILENAMES:-/usr/share/vulkan/icd.d/lvp_icd.json}"
FBW="${GEOM%x*}"; FBH="${GEOM#*x}"

pass=0; fail=0
ok()   { echo "wlstall: PASS $*"; pass=$((pass+1)); }
bad()  { echo "wlstall: FAIL $*"; fail=$((fail+1)); }
info() { echo "wlstall: INFO $*"; }

XCLIENTS=""; XWPID=""; WLPID=""; WSYSDPID=""
cleanup() {
    for p in $XCLIENTS $XWPID $WLPID $WSYSDPID; do
        [ -n "${p:-}" ] && kill "$p" 2>/dev/null
    done
    sleep 0.3
    for p in $XCLIENTS $XWPID $WLPID $WSYSDPID; do
        [ -n "${p:-}" ] && kill -9 "$p" 2>/dev/null
    done
    [ "$KEEP" = 1 ] || rm -rf "$WORK"
}
trap cleanup EXIT
# A bare EXIT trap does not run when the shell is killed by a signal, so a
# gate stopped by `timeout` (TERM) or ^C (INT) skipped its cleanup entirely.
# Re-exit on those, which makes the EXIT trap above run on every path out.
trap 'exit 130' INT TERM HUP

for t in Xwayland xterm xdotool xdpyinfo xwininfo python3; do
    command -v "$t" >/dev/null || { echo "need $t on the host" >&2; exit 1; }
done

for t in wsysd:user/wsysd.ad wsyswl:user/wsyswl.ad; do
    name="${t%%:*}"; src="${t#*:}"
    scripts/hamlinux_build.sh "$src" "$WORK/$name.elf" >"$WORK/$name.build.log" 2>&1 || {
        echo "FAIL could not build $src" >&2; tail -20 "$WORK/$name.build.log" >&2; exit 1; }
done

"$WORK/wsysd.elf" </dev/null >"$WORK/wsysd.log" 2>&1 &
WSYSDPID=$!
sleep 1.5

"$WORK/wsyswl.elf" "$WORK/wayland-0" </dev/null >"$WORK/wsyswl.log" 2>&1 &
WLPID=$!
for _ in $(seq 1 40); do [ -S "$WORK/wayland-0" ] && break; sleep 0.1; done
[ -S "$WORK/wayland-0" ] || { bad "wsyswl never created its socket"; cat "$WORK/wsyswl.log"; exit 1; }
ok "wsyswl is listening"

STATE="$WORK/wsyswl-state"
[ -r "$STATE" ] && ok "wsyswl published its counters beside the socket" \
                || bad "no wsyswl-state file beside the socket"

export XDG_RUNTIME_DIR="$WORK"
export WAYLAND_DISPLAY=wayland-0
DISPNUM="${WLSTALL_DISPLAY:-:72}"
rm -f "/tmp/.X${DISPNUM#:}-lock" 2>/dev/null

GEOMOPT=""
if [ -r "$WORK/hamnix-screen" ]; then
    read -r PW PH < "$WORK/hamnix-screen" || true
    if Xwayland -help 2>&1 | grep -q -- '-geometry'; then GEOMOPT="-geometry ${PW}x${PH}"; fi
fi
# shellcheck disable=SC2086
Xwayland -shm -noreset $GEOMOPT "$DISPNUM" >"$WORK/xwayland.log" 2>&1 &
XWPID=$!
export DISPLAY="$DISPNUM"
up=0
for _ in $(seq 1 80); do
    xdpyinfo >/dev/null 2>&1 && { up=1; break; }
    kill -0 "$XWPID" 2>/dev/null || break
    sleep 0.25
done
[ "$up" = 1 ] && ok "Xwayland came up on $DISPNUM through wsyswl" \
              || { bad "Xwayland did not come up"; tail -20 "$WORK/xwayland.log"; exit 1; }

# The framebuffer is a plain file here, so "is there a white window at these
# coordinates" is a question with a literal answer.
whitebox() {  # x y w h -> fraction of near-white pixels, as an integer percent
    python3 - "$HAMFB_FILE" "$FBW" "$FBH" "$1" "$2" "$3" "$4" <<'PY'
import sys
path, W, H, x, y, w, h = sys.argv[1], *map(int, sys.argv[2:])
d = open(path, 'rb').read()
tot = 0; white = 0
for j in range(y, min(y + h, H), 3):
    row = j * W * 4
    for i in range(x, min(x + w, W), 3):
        o = row + i * 4
        if o + 3 > len(d): continue
        tot += 1
        if d[o] > 0xc0 and d[o+1] > 0xc0 and d[o+2] > 0xc0:
            white += 1
print(0 if tot == 0 else white * 100 // tot)
PY
}
fbhash() { python3 -c 'import hashlib,sys;print(hashlib.md5(open(sys.argv[1],"rb").read()).hexdigest())' "$HAMFB_FILE"; }

xterm -geometry 80x24+40+40 -bg white -fg black -e sleep 900 >"$WORK/xterm.log" 2>&1 &
XCLIENTS="$XCLIENTS $!"
XT=""
for _ in $(seq 1 40); do
    XT=$(xdotool search --class xterm 2>/dev/null | head -1)
    [ -n "$XT" ] && break
    sleep 0.5
done
[ -n "$XT" ] && ok "the xterm mapped a window ($XT)" || { bad "no xterm window"; exit 1; }
sleep 3

# A wsys window is placed by wsysd with a title bar, so the X screen's origin
# is not the framebuffer's. Find the offset once, by looking for the xterm
# where it started, and use it for every later coordinate.
BEST=-1; OX=0; OY=0
for oy in 0 20 24 28 32; do
  for ox in 0 2 4; do
    v=$(whitebox $((40+ox)) $((40+oy)) 300 150)
    if [ "$v" -gt "$BEST" ]; then BEST=$v; OX=$ox; OY=$oy; fi
  done
done
info "framebuffer offset for X (0,0) looks like +${OX}+${OY} (${BEST}% white in the xterm's box)"
if [ "$BEST" -gt 40 ]; then
    ok "the xterm's first paint reached the scanout framebuffer (${BEST}% white)"
else
    bad "the xterm never reached the framebuffer at all (${BEST}% white) -- the path is broken before this test can say anything"
fi

# ---- THE CONTROL: move it, and the scanout must follow --------------------
before=$(fbhash)
xdotool windowmove "$XT" 700 500
xdotool windowsize "$XT" 1000 250
sleep 4
after=$(fbhash)
oldbox=$(whitebox $((40+OX)) $((40+OY)) 300 150)
newbox=$(whitebox $((700+OX)) $((500+OY)) 900 200)
info "after the move: old box ${oldbox}% white, new box ${newbox}% white"
[ "$before" != "$after" ] && ok "the framebuffer changed when the window moved" \
                          || bad "the framebuffer is byte-identical after a move -- the surface is stale"
if [ "$newbox" -gt 40 ] && [ "$oldbox" -lt 20 ]; then
    ok "the scanout FOLLOWED the move: the window is at its new place and gone from the old"
else
    bad "the scanout did not follow the move (old ${oldbox}% white, new ${newbox}%)"
fi

# ---- THE HAMMER: keep it moving, and keep checking ------------------------
# What Steam does to this server that an xterm's first paint does not is
# CHURN: pixmaps, shm pools, buffers and object ids, over and over. Every
# resize below makes Xwayland cut a new buffer, so this is that churn with a
# stopwatch on it.
info "hammering the surface with $ROUNDS moves and resizes"
r=0
while [ "$r" -lt "$ROUNDS" ]; do
    w=$(( 400 + (r * 37) % 700 ))
    h=$(( 200 + (r * 53) % 400 ))
    x=$(( 20 + (r * 29) % 300 ))
    y=$(( 20 + (r * 41) % 300 ))
    xdotool windowsize "$XT" "$w" "$h" 2>/dev/null
    xdotool windowmove "$XT" "$x" "$y" 2>/dev/null
    sleep 0.2
    r=$((r+1))
done
sleep 3

xdotool windowsize "$XT" 900 300
xdotool windowmove "$XT" 200 420
sleep 4
lastbox=$(whitebox $((200+OX)) $((420+OY)) 800 250)
info "after $ROUNDS rounds of churn: the window's box is ${lastbox}% white"
if [ "$lastbox" -gt 40 ]; then
    ok "the surface is STILL being delivered after $ROUNDS rounds of churn"
else
    bad "the surface stopped being delivered after churn (${lastbox}% white) -- this is the Steam bug, without Steam"
fi

# THE SIZE THE PLANTED FAULT IS MEASURED AGAINST, set BEFORE the plant so that
# nothing after it has to resize -- see the comment on the move below.
xdotool windowsize "$XT" 800 400
sleep 2

# ---- THE NEGATIVE CONTROL: plant the fault, and watch it heal --------------
# This is the bug itself, injected. The v2 backbuffer slot carries its own w/h;
# the client writes rows at THAT width and user/wsysd.ad re-rows them at the
# WINDOW's width. Set them apart by hand and the scanout shows the window twice
# side by side at half height -- which, for a rootful Xwayland, is a whole X
# session that painted once and never followed a move again. The next blit must
# notice and re-fit, or nothing ever does.
#
# WHERE THE FAULT HAS TO GO, AND WHY IT MOVED. MEASURED 2026-08-17.
#
# This used to write 640x480 into `$WORK/wsys.bb` -- struct bbshm's
# `slot[]` array. TWO things were wrong with that and only the first was
# visible:
#
#   1. It hard-coded BBSHM_MAGIC as 0x42425747. The segment says 0x42425753
#      ("SWBB"), bumped "when the pixels left this file". The magic check did
#      its job and planted NOTHING, and the gate went red for a reason with
#      nothing to do with the compositor -- twice in one run, because the
#      loudness assertion below then failed as a consequence.
#   2. AND FIXING THE MAGIC DID NOT MAKE THE FAULT REAL. `bb->slot[]` is
#      ACCOUNTING ONLY: bb_pool_claim WRITES it and /dev/wsys/pool renders it,
#      and NOTHING reads its w/h to decide anything about pixels. The size
#      bb_for() compares -- the one whose mismatch is the bug this section is
#      named for -- lives in `struct bbpix`, in the window's PRIVATE memfd
#      (bbmap[i].hdr). Planting in wsys.bb wrote bytes nobody consults: the
#      run printed "planted a stale 640x480 slot on wid 2", the window was
#      never broken, "a slot whose size disagreed was re-fitted" passed
#      against a window that had never disagreed with anything, and the
#      loudness check reported silence about a re-fit that never happened.
#      Measured: 0 `wsys: BACKBUFFER` lines in either log, before or after.
#
# So the fault is planted in the memfd the code actually reads. It is not on
# the filesystem -- memfd_create(2), named "hamnix-wsys-bb" -- but it is a
# process's open file, so /proc/<pid>/fd is the way in, and BBPIX_MAGIC
# identifies the right one rather than a position being trusted.
BBPIX_MAGIC="$(sed -n 's/^#define BBPIX_MAGIC  *\(0x[0-9a-fA-F]*\)u\?.*/\1/p' \
               user/linux-wsys.c | head -1)"
[ -n "$BBPIX_MAGIC" ] || bad "cannot read BBPIX_MAGIC from user/linux-wsys.c -- nothing can be planted"
python3 - "$WLPID" "${BBPIX_MAGIC:-0}" <<'PY'
import os, struct, sys
# struct bbpix, from user/linux-wsys.c:
#   magic, version, wid, w, h, gen, front, started   -- 8 uint32/int32 = 32 B
# It is the FIRST object in the window's backbuffer memfd.
pid  = sys.argv[1]
WANT = int(sys.argv[2], 0)
d = "/proc/%s/fd" % pid
cands = []
try:
    names = sorted(os.listdir(d), key=int)
except OSError as e:
    sys.exit("wlstall: cannot read %s (%s) -- planted NOTHING" % (d, e))
for n in names:
    try:
        tgt = os.readlink(os.path.join(d, n))
    except OSError:
        continue
    if "hamnix-wsys-bb" not in tgt:
        continue
    cands.append(n)
if not cands:
    sys.exit("wlstall: no fd in %s is a hamnix-wsys-bb memfd -- this process "
             "owns no backbuffer and NOTHING was planted" % d)
planted = False
for n in cands:
    p = os.path.join(d, n)
    try:
        f = open(p, "r+b")
    except OSError as e:
        print("wlstall: INFO fd %s not writable (%s)" % (n, e))
        continue
    hdr = f.read(32)
    if len(hdr) < 32:
        f.close(); continue
    magic, ver, wid, w, h, gen, front, started = struct.unpack("<IIiiiIII", hdr)
    if magic != WANT:
        print("wlstall: INFO fd %s magic %#x is not BBPIX_MAGIC %#x -- skipped"
              % (n, magic, WANT))
        f.close(); continue
    if w <= 0 or h <= 0:
        f.close(); continue
    f.seek(0)
    f.write(struct.pack("<IIiiiIII", magic, ver, wid, 640, 480, gen, front, 0))
    f.flush(); f.close()
    print("wlstall: INFO planted a stale 640x480 backbuffer on wid %d "
          "(was %dx%d) via /proc/%s/fd/%s" % (wid, w, h, pid, n))
    planted = True
    break
if not planted:
    sys.exit("wlstall: found %d hamnix-wsys-bb memfd(s) but could not plant in "
             "any of them -- nothing was injected and the assertions below "
             "would be meaningless" % len(cands))
PY
[ $? = 0 ] || bad "the fault could not be planted, so nothing below is evidence"
# HOW MANY TIMES THE DEVICE HAD ALREADY SAID IT, BEFORE THE PLANT.
#
# `wsys: BACKBUFFER ...` comes out of bb_once(), which is a ONE-SHOT PER
# PROCESS latch (user/linux-wsys.c: `if (*flag) return;`).  The 40 rounds of
# resize above are legitimate re-fits and each of them can spend that latch --
# so "there is a BACKBUFFER line in the log" is NOT evidence that the PLANTED
# mismatch was announced, and an unqualified grep for it is an assertion that
# cannot fail once the churn has run.  The count is taken here, before the
# plant takes effect, so the check below can ask for a NEW line and can say
# out loud when the latch makes the question unanswerable.
BB_BEFORE=$(grep -c 'wsys: BACKBUFFER' "$WORK/wsyswl.log" "$WORK/wsysd.log" 2>/dev/null \
            | awk -F: '{s += $NF} END {print s + 0}')
info "BACKBUFFER lines before the plant: ${BB_BEFORE:-0}"
# ONLY A MOVE, AND THE SIZE WAS SET BEFORE THE PLANT.  This used to resize the
# window here (`xdotool windowsize 800 400`), and a resize REPAIRS THE SLOT BY
# A DIFFERENT ROUTE: the `geometry` verb calls bb_resize -> bb_fit directly,
# so the planted mismatch was gone before any blit could notice it, and
# bb_for's mismatch branch -- the code this section exists to exercise -- was
# never reached.  The gate then reported "corrected without a word", which was
# true and was not about the compositor: MEASURED 2026-08-17, zero
# `wsys: BACKBUFFER` lines in either process's log, before OR after.  A move
# re-blits at the SAME size, so bb_for is the only way back to consistency.
xdotool windowmove "$XT" 300 300
sleep 4
healed=$(whitebox $((300+OX)) $((300+OY)) 700 350)
info "after the planted mismatch: the window's box is ${healed}% white"
if [ "$healed" -gt 40 ]; then
    ok "a slot whose size disagreed with its window was re-fitted by the next blit"
else
    bad "a mismatched backbuffer slot is never corrected (${healed}% white)"
fi

echo "wlstall: === the compositor's own counters"
cat "$STATE" 2>/dev/null | sed 's/^/wlstall:   /'
DROPS=$(sed -n 's/^drop_[a-z_]* \([0-9]*\)$/\1/p;s/^map_alloc_failed \([0-9]*\)$/\1/p;s/^obj_id_refused \([0-9]*\)$/\1/p' "$STATE" 2>/dev/null | paste -sd+ - | bc 2>/dev/null)
COMMITS=$(sed -n 's/^commits \([0-9]*\)$/\1/p' "$STATE" 2>/dev/null)
info "commits=${COMMITS:-?} total drops=${DROPS:-?}"
[ "${COMMITS:-0}" -gt 10 ] && ok "the compositor accepted ${COMMITS} buffers" \
                           || bad "the compositor accepted almost nothing (${COMMITS:-0} commits)"
# drop_no_role is not a fault: it is wl_pointer.set_cursor, a surface with no
# xdg_surface, and refusing it is what stops a cursor opening a window.
NOROLE=$(sed -n 's/^drop_no_role \([0-9]*\)$/\1/p' "$STATE" 2>/dev/null)
REAL=$(( ${DROPS:-0} - ${NOROLE:-0} ))
if [ "$REAL" -le 0 ]; then
    ok "no frame was dropped for any reason but a cursor surface"
else
    bad "$REAL frames were dropped -- see the named counters above"
fi
grep -q 'DROPPING FRAMES' "$WORK/wsyswl.log" && info "wsyswl named its drops on stderr:" \
    && grep 'DROPPING FRAMES' "$WORK/wsyswl.log" | sed 's/^/wlstall:   /'
#
# AND IT IS ASKED AGAINST THE COUNT TAKEN BEFORE THE PLANT, not against zero.
# Until 2026-08-17 this was `grep -q 'wsys: BACKBUFFER' wsyswl.log`, which the
# 40 rounds of churn above can satisfy all by themselves -- and which looked
# only in wsyswl.log, though the slot's owner may be either process and only
# the OWNER prints (bb_for: `bbmap[i].own`).  Both logs are read, and a NEW
# line is what counts.
BB_AFTER=$(grep -c 'wsys: BACKBUFFER' "$WORK/wsyswl.log" "$WORK/wsysd.log" 2>/dev/null \
           | awk -F: '{s += $NF} END {print s + 0}')
info "BACKBUFFER lines after the plant: ${BB_AFTER:-0} (before: ${BB_BEFORE:-0})"
if [ "${BB_AFTER:-0}" -gt "${BB_BEFORE:-0}" ]; then
    ok "the wsys backbuffer named the PLANTED fault -- $(( BB_AFTER - BB_BEFORE )) new line(s)"
    grep -h 'wsys: BACKBUFFER' "$WORK/wsyswl.log" "$WORK/wsysd.log" 2>/dev/null \
        | sed 's/^/wlstall:   /'
elif [ "${BB_BEFORE:-0}" -gt 0 ]; then
    # NOT A PASS AND NOT A FAIL: the instrument was already spent.
    info "the one-shot bb_once() latch had ALREADY fired ${BB_BEFORE} time(s) during the churn, so a second re-fit CANNOT produce a line and this run does not distinguish a silent re-fit from an announced one -- the question is not asked, which is different from it passing"
    grep -h 'wsys: BACKBUFFER' "$WORK/wsyswl.log" "$WORK/wsysd.log" 2>/dev/null \
        | sed 's/^/wlstall:   /'
else
    bad "the planted mismatch was corrected without a word -- silence is the bug (no 'wsys: BACKBUFFER' in either wsyswl.log or wsysd.log, before or after)"
    info "wsyswl.log tail:"; tail -6 "$WORK/wsyswl.log" | sed 's/^/wlstall:   /'
    info "wsysd.log tail:";  tail -6 "$WORK/wsysd.log"  | sed 's/^/wlstall:   /'
fi

echo "wlstall: $pass PASS, $fail FAIL"
[ "$fail" = 0 ]
