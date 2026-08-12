#!/usr/bin/env bash
# tests/linux/de_mouse_chrome.sh — CAN A PERSON CLICK THE DESKTOP WITH A MOUSE?
#
# THE DEFECT THIS GATES
# =====================
# `user/wsysd.ad`'s `deliver_pointer` wrote the routed pointer line to
# `/dev/wsys/<wid>/pointer` and to nothing else. `lib/hamui.ad` reads that
# file, so every ordinary hamUI application was fine. But the two programs a
# person actually points at -- `user/hampanelscene.ad` (the Applications
# button, the taskbar) and `user/hamdesktop.ad` (the wallpaper and the icons)
# -- read `/dev/wsys/<wid>/event`, which is where Hamnix's devwsys pushes its
# `'m'` lines (`~/Hamnix/sys/src/9/port/devwsys.ad:12384`), and NOTHING in
# this port ever wrote a pointer line to an event ring. Measured before the
# fix, with a window whose owner drained neither ring: after a full evdev
# click `pointer` held `d 80 110 1 0` / `u 80 110 0 0` and `event` was EMPTY,
# six consecutive reads. The DE chrome was inert under a real mouse.
#
# WHY EVERY EXISTING GATE STAYED GREEN, AND WHAT THIS ONE MUST THEREFORE DO
# =========================================================================
# `tests/linux/distro_menu.sh` and `tests/linux/de_appmenu_band.sh` both open
# the Applications menu by WRITING THE PANEL'S EVENT RING BY HAND as the host
# owner (`wsys_poke /dev/wsys/<wid>/event "m 40 13 1"`). That is a legitimate
# shortcut for what those files gate -- menu geometry, keyed compositing --
# and it is exactly why the input path underneath could be entirely missing
# with both of them passing. de_appmenu_band.sh says so at the bottom, under
# THE INPUT GAP.
#
# So this gate is not allowed to touch a ring. Every click below is SYNTHETIC
# EVDEV -- 24-byte `struct input_event` records appended to the file named by
# HAMWSYSD_INPUT, byte for byte what `/dev/input/eventN` delivers, read by
# wsysd's own `pump_input` -- and every assertion is about what the CHROME
# DID: the panel window's geometry, and the pixels in the framebuffer.
# Assertion 12 enforces the rule mechanically by grepping this file.
#
# WHAT IS MEASURED
# ================
#   1. wsysd + hamdesktop + hampanelscene build, and the compositor takes its
#      input from the test's evdev file and opens none of this host's devices.
#   2. a full-width top bar exists (there is an Applications button to click).
#   3. CONTROL, before any click: the menu column is not the dropdown body
#      colour, and the first desktop icon carries no selection highlight.
#   4. an EVDEV click on the Applications button opens the menu: the panel
#      window GROWS to the full width of the display and gets taller.
#   5. and the menu is PAINTED -- the dropdown body colour fills the card.
#   6. a second EVDEV click on the same button CLOSES it again: the window
#      shrinks back to the bar and the card colour goes away. A one-shot that
#      cannot be undone would be a stuck panel, not a routed click.
#   7. an EVDEV click on the first desktop ICON selects it: hamdesktop's
#      #3584e4 selection fill appears in the cell. That is a SECOND program,
#      on a different ring, reacting to the same mechanism -- the panel alone
#      could be satisfied by something particular to hampanelscene.
#   8. and clicking a different icon MOVES the highlight (cell 1 loses it,
#      cell 2 gains it), so 7 cannot be satisfied by a desktop that lit
#      everything up at startup.
#
# THE INSTRUMENT IS NOT ALLOWED TO BREAK THE THING IT MEASURES
# ============================================================
# This gate spent a day accusing a healthy channel. `MOUSE_BIN_DIR` took the
# compositor, the desktop and the panel out of a published tarball -- and then
# read the panel's geometry back with `wsys_poke` COMPILED FROM THIS TREE,
# because the substitution loop below carried `[ "$name" != wsys_poke ]` on the
# grounds that a test tool is not part of the channel and "it only ever READS a
# ctl line, so where it comes from cannot change an answer".
#
# That sentence is false, and user/linux-wsys.c says why in its own words: EVERY
# program in this tree is a wsys client, reading included. Opening
# /dev/wsys/<wid>/ctl attaches to the shared segment, and an attacher whose
# WSYS_VERSION differs from the segment's RE-INITIALISES IT BY DESIGN -- "the
# running session's windows are gone and every live client is re-attached to an
# empty table". The tree went 6 -> 7 (11ffe583); the published desktop was 6.
# So the gate stood up a healthy v6 desktop from the packaged bytes, wiped it
# with its own v7 probe on the first ctl read, and reported
#
#     mouse: FAIL no full-width top bar -- there is no Applications button
#
# against a channel that was fine. Measured on hamnix-desktop-1.0.17.tar.gz:
# 2 PASS / 1 FAIL with the tree-built probe, 13 PASS / 0 FAIL with a v6 one.
# The same shape had already been found and written down once, in
# tests/linux/installed_update_wsysver.sh: "`cat /dev/wsys/2/ctl` is a wsys
# client ... the gate then photographed the wreck it had made and blamed the
# desktop." NORTH_STAR.md's rule is that a gap must never answer something
# success-shaped instead of the truth; a gate that manufactures a failure and
# bills it to the packages is the same lie with the sign flipped, and this one
# decides whether a release ships.
#
# TWO THINGS FOLLOW, and both are here:
#
#   1. THE EXCLUSION IS GONE. There is no "except the test tool" case left.
#      When MOUSE_BIN_DIR is set, every binary that touches the segment comes
#      out of it, and a name it does not hold is refused BY NAME rather than
#      substituted. The window table is a FILE and `cat` is in the channel, so
#      the probe is now the channel's own `cat` -- the same idiom
#      installed_update_wsysver.sh settled on, and the same one
#      installed_recover_broken.sh reads window rows with. wsys_poke, a tree
#      binary in a gate whose whole purpose is "run the bytes somebody else
#      produced", is no longer part of this measurement at all. That removes
#      the CLASS; version-matching wsys_poke would only have removed today's
#      instance of it, and left the next tree binary someone reaches for.
#
#   2. AND THE SKEW IS DETECTED ANYWAY, because "nothing here is from the tree"
#      is a property a future edit can lose quietly. `segstate` below reads the
#      first 24 bytes of the shm segment FROM THE HOST with python3 -- magic,
#      version, focus, next_wid, desktop, gen, the prefix of `struct wshm` that
#      user/linux-wsys.c documents as byte-for-byte identical across v5, v6 and
#      v7. A plain file read attaches to nothing and cannot perturb anything.
#      It is sampled three times, and each gap answers a different question:
#        after wsysd          -- the session's version, stated out loud;
#        after the clients    -- did hamdesktop/hampanelscene agree with the
#                                compositor? A disagreement here is a MIXED
#                                CHANNEL and is the packages' fault, named as
#                                such (this is the 1.0.10 shape);
#        after the first read -- did the PROBE change it? That can only be this
#                                gate's own instrument, and it says so and
#                                stops, instead of going on to photograph the
#                                wreck and blame the top bar.
#
# Entirely offscreen (HAMFB_FILE + a file of evdev records): no VM, no
# display, no GPU. The software Vulkan ICD is forced because wsysd has a real
# Vulkan backend and this host's GPU belongs to someone.
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

WORK="${MOUSE_WORK:-$(mktemp -d -p "${TMPDIR:-/tmp}" mousechrome.XXXXXX)}"
mkdir -p "$WORK"
KEEP="${MOUSE_KEEP:-0}"
GEOM="${HAMFB_GEOM:-1280x800}"
FBW="${GEOM%x*}"; FBH="${GEOM#*x}"

export HAMWSYS="$WORK/wsys.shm"
export HAMWSYS_BB="$WORK/wsys.bb"
export HAMWSYS_IMG="$WORK/wsys.img"
export HAMFB_FILE="$WORK/fb.raw"
export HAMFB_GEOM="$GEOM"
[ -r /usr/share/vulkan/icd.d/lvp_icd.json ] && \
    export VK_ICD_FILENAMES="${VK_ICD_FILENAMES:-/usr/share/vulkan/icd.d/lvp_icd.json}"

pass=0; fail=0
ok()   { echo "mouse: PASS $*"; pass=$((pass+1)); }
bad()  { echo "mouse: FAIL $*"; fail=$((fail+1)); }
info() { echo "mouse: INFO $*"; }

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
done_report() { echo "mouse: $pass passed, $fail failed"; [ "$fail" = 0 ]; }

# ---- the pixel probe ------------------------------------------------------
# One question: what fraction of this rectangle is exactly this colour.
FRAC_PY="$WORK/frac.py"
cat >"$FRAC_PY" <<'PY'
import sys
W, H = int(sys.argv[1]), int(sys.argv[2])
x, y, w, h = (int(v) for v in sys.argv[3:7])
d = open(sys.argv[7], 'rb').read()
c = sys.argv[8]
want = (int(c[0:2], 16), int(c[2:4], 16), int(c[4:6], 16))
tot = hit = 0
for j in range(y, min(y + h, H), 2):
    row = j * W * 4
    for i in range(x, min(x + w, W), 2):
        o = row + i * 4
        tot += 1
        if (d[o+2], d[o+1], d[o]) == want:
            hit += 1
print(0 if tot == 0 else hit * 100 // tot)
PY
colourpct() { python3 "$FRAC_PY" "$FBW" "$FBH" "$1" "$2" "$3" "$4" "$5" "$6"; }
snap()      { cp "$HAMFB_FILE" "$WORK/$1.raw"; }

# ---- the segment probe, which is not a wsys client -----------------------
# `struct wshm` opens { uint32 magic, version; int32 focus_wid, next_wid,
# desktop; uint32 gen; } and user/linux-wsys.c states that this prefix is
# byte-for-byte the same in v5, v6 and v7 -- the versions disagree only about
# how many rows follow it. So the segment's own version is readable with a
# 24-byte pread and NO ATTACH: this reads the file, it does not open
# /dev/wsys/anything, and therefore cannot re-initialise what it is looking at.
# That is the whole point -- the one measurement in this gate that is
# structurally incapable of causing the thing it reports.
SEG_PY="$WORK/seg.py"
cat >"$SEG_PY" <<'PY'
import os, struct, sys
p = sys.argv[1]
try:
    with open(p, 'rb') as f:
        h = f.read(24)
    sz = os.path.getsize(p)
except OSError:
    print("absent - - - - -"); raise SystemExit
if len(h) < 24:
    print("short - - - - -"); raise SystemExit
magic, ver, focus, nextwid, desktop, gen = struct.unpack('<IIiiiI', h)
if magic != 0x53595357:                      # "WSYS"
    print("nomagic - - - - -"); raise SystemExit
print("v%d next=%d focus=%d desktop=%d gen=%d bytes=%d"
      % (ver, nextwid, focus, desktop, gen, sz))
PY
segstate() { python3 "$SEG_PY" "$HAMWSYS"; }
segver()   { segstate | cut -d' ' -f1; }
segnext()  { segstate | sed -n 's/.* next=\([0-9-]*\).*/\1/p'; }

# ---- build ----------------------------------------------------------------
# MOUSE_BIN_DIR RUNS THIS GATE AGAINST BINARIES SOMEBODY ELSE PRODUCED.
# Unset -- the normal case -- every program is compiled from this tree, and
# the question is "does the source in front of me route a click". Set to a
# directory of ELFs, the question becomes "do THOSE bytes route a click", and
# the caller is tests/linux/channel_runs_desktop.sh, which unpacks the
# hamnix-desktop tarball the packager is about to publish (or that
# https://255.one/ is serving right now) and asks whether the PUBLISHED
# compositor carries the fix. A version string in an index cannot answer that;
# running the bytes can.
#
# THE LIST INCLUDES `cat`, AND THAT IS THE POINT. `cat` is how the panel's
# geometry is read back (winctl, below), and reading /dev/wsys/<wid>/ctl makes
# it a wsys client like any other -- see THE INSTRUMENT IS NOT ALLOWED TO BREAK
# THE THING IT MEASURES at the top. So it is version-matched to the bytes under
# test by coming out of the same channel they did, and with MOUSE_BIN_DIR set
# this loop compiles NOTHING AT ALL: no binary from this tree touches the
# segment. There is no "except the test tool" case any more.
BINDIR="${MOUSE_BIN_DIR:-}"
for t in wsysd:user/wsysd.ad \
         hamdesktop:user/hamdesktop.ad \
         hampanelscene:user/hampanelscene.ad \
         cat:user/cat.ad; do
    name="${t%%:*}"; src="${t#*:}"
    if [ -n "$BINDIR" ]; then
        # A binary MOUSE_BIN_DIR does not hold used to fall through and get
        # compiled from this tree. That is the one substitution this hook must
        # never make: the caller asked about SOMEBODY ELSE'S bytes, and quietly
        # answering about the working tree's is a success-shaped answer to a
        # different question. Refuse by name instead.
        [ -f "$BINDIR/$name" ] || {
            bad "MOUSE_BIN_DIR=$BINDIR does not contain $name -- refusing to substitute a fresh build for the binary you asked about"
            done_report; exit 1; }
        cp "$BINDIR/$name" "$WORK/$name.elf"; chmod +x "$WORK/$name.elf"
        continue
    fi
    scripts/hamlinux_build.sh "$src" "$WORK/$name.elf" \
        >"$WORK/$name.build.log" 2>&1 || {
        bad "could not build $src"; tail -20 "$WORK/$name.build.log" >&2
        done_report; exit 1; }
done
if [ -n "$BINDIR" ]; then
    ok "the compositor, the desktop, the panel AND the ctl probe came from $BINDIR (nothing was built here, so nothing from this tree attaches to the segment)"
else
    ok "the compositor, the desktop, the panel and the ctl probe all build"
fi

# READS ONLY, and by `cat` -- the window table is a file. See assertion 12 for
# the rule that keeps it reads-only, and the header for why the binary that
# does the reading has to be version-matched to the session.
winctl() { "$WORK/cat.elf" "/dev/wsys/$1/ctl" 2>/dev/null; }

# ---- THE MOUSE ------------------------------------------------------------
# A real one. `struct input_event` is { struct timeval (16 bytes), __u16 type,
# __u16 code, __s32 value } -- 24 bytes on x86-64 -- and wsysd's pump_input
# parses exactly that off whatever HAMWSYSD_INPUT names. The absolute axes are
# the virtio/usb-tablet range QEMU advertises (0..32767 across the screen),
# which is the branch wsysd takes for EV_ABS.
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

# move, settle, press, hold, release -- the timing of a human click, and each
# phase is a separate append so the compositor's 16 ms poll sees the button
# EDGES the way a real device delivers them.
click() {   # click <x> <y>
    ev "move:$1:$2"; sleep 0.4
    ev "down"; sleep 0.4
    ev "up";  sleep 1.2
}

# ---- the compositor -------------------------------------------------------
"$WORK/wsysd.elf" </dev/null >"$WORK/wsysd.log" 2>&1 &
PIDS="$PIDS $!"
for _ in $(seq 1 60); do [ -s "$HAMFB_FILE" ] && break; sleep 0.1; done
[ -s "$HAMFB_FILE" ] || { bad "wsysd never produced a framebuffer"
                          cat "$WORK/wsysd.log"; done_report; exit 1; }
if grep -q "input from $WORK/input.evdev only" "$WORK/wsysd.log"; then
    ok "wsysd took its input from the test's evdev file and opened no real device"
else
    bad "wsysd did not honour HAMWSYSD_INPUT -- it may be reading this host's keyboard"
fi
# IS THIS COMPOSITOR WOKEN BY INPUT, OR IS IT STILL TICKING?  One more grep of
# the log already open above, and it closes a hole that was measured rather
# than supposed: every assertion in this file passes identically whether wsysd
# sleeps in poll(2) on a wait set or spins on the 16 ms fallback tick, because
# the mouse gets answered either way -- just later.  So input-to-pixel latency
# could regress from 0.33 ms back to ~9 ms, which is the whole of the
# wake-on-input work, and this gate would stay green and say nothing.
#
# wsysd states it itself at startup (user/wsysd.ad's build_waitset):
#     "wsysd: wait set N fds wake this loop, M always-ready and excluded; ..."
#     "wsysd: NOTHING can wake this loop -- it is the 16 ms tick"   (when N == 0)
# The second line is the regression, by name, so it is failed on directly; the
# first is required to be present AND to carry a non-zero N, so that a build
# which stops printing either line cannot pass by silence.
#
# IT IS ASSERTED HERE AND NOT IN A LATENCY NUMBER on purpose: this gate has no
# clock accurate enough to tell 0.33 ms from 9 ms through a synthetic mouse, and
# a timing assertion on a shared build host would flake. The compositor's own
# statement about its own loop is the cheap, stable witness.
WAKELINE="$(grep -m1 'wake this loop' "$WORK/wsysd.log" 2>/dev/null || true)"
NWAKE="$(printf '%s' "$WAKELINE" | sed -n 's/.*wait set \([0-9][0-9]*\) fds wake this loop.*/\1/p')"
if grep -q 'NOTHING can wake this loop' "$WORK/wsysd.log"; then
    bad "THE COMPOSITOR IS NOT WOKEN BY INPUT -- it fell back to the 16 ms tick:"\
        "$(grep -m1 'NOTHING can wake this loop' "$WORK/wsysd.log")."\
        "Input-to-pixel latency regresses to a tick period; the mouse still"\
        "works, which is why nothing else in this file notices."
elif [ -n "$NWAKE" ] && [ "$NWAKE" -ge 1 ] 2>/dev/null; then
    ok "the compositor is WOKEN BY INPUT, not ticking: $WAKELINE"
else
    bad "wsysd did not say whether anything can wake its loop -- this gate cannot"\
        "tell a woken compositor from a ticking one, so the wake-on-input work is"\
        "unmeasured here. Expected a 'wait set N fds wake this loop' line; got:"\
        "${WAKELINE:-(no such line)}"
fi

# CHECKPOINT 1 of 3 -- the session's wsys version, stated out loud, read off
# the segment file by a program that is not a wsys client. Everything below is
# measured against this number.
SEG0="$(segstate)"; SEGV0="$(segver)"
info "the session under test is wsys $SEG0"
case "$SEGV0" in
    v[0-9]*) : ;;
    *) bad "wsysd produced a framebuffer but $HAMWSYS carries no WSYS segment header ($SEG0) -- nothing below can be trusted"
       done_report; exit 1;;
esac

# ---- the desktop and the panel -------------------------------------------
"$WORK/hamdesktop.elf" </dev/null >"$WORK/hamdesktop.log" 2>&1 &
PIDS="$PIDS $!"
sleep 3
"$WORK/hampanelscene.elf" </dev/null >"$WORK/hampanelscene.log" 2>&1 &
PIDS="$PIDS $!"
sleep 3

# CHECKPOINT 2 of 3 -- DID THE CLIENTS AGREE WITH THE COMPOSITOR? hamdesktop
# and hampanelscene have now attached. If the version moved, the desktop and
# the panel are a different wsys build from the wsysd they were shipped beside,
# each one wiping the other's table on attach. That is a MIXED CHANNEL -- the
# 1.0.10 shape, a stale object cache packaging binaries from two builds -- and
# it is the packages' fault, so say which and do not let it read as chrome that
# ignored a click.
#
# AND IT STOPS HERE, which is the second half of the lesson. The first version
# of this checkpoint reported the mixed channel and carried on -- and the NEXT
# checkpoint then correctly observed that the probe had changed the version
# back, and said "fix the instrument" about an instrument that was fine. A red
# for the right reason worded as a red for the wrong one is still the failure
# this project keeps paying for. Once the table has been re-initialised under a
# live desktop nothing below is a question this run can answer: the panel and
# the wallpaper are attached to a segment that was punched out from under them,
# so every pixel from here on is a photograph of wreckage.
SEG1="$(segstate)"; SEGV1="$(segver)"
if [ "$SEGV1" != "$SEGV0" ]; then
    bad "MIXED CHANNEL: the segment was $SEGV0 when wsysd made it and is $SEGV1 now that hamdesktop and hampanelscene have attached -- these three binaries are not one build, and each re-initialises the others' window table. THIS IS A DEFECT IN THE BYTES, not in this gate: it is the 1.0.10 shape, a stale object cache packaging a compositor and its clients from two different builds."
    info "  before the clients: $SEG0"
    info "  after  the clients: $SEG1"
    [ -n "$BINDIR" ] && info "  the bytes came from $BINDIR"
    info "  stopping: the window table was re-initialised under a live desktop, so 'is there a top bar' is not a question the pixels below can answer"
    done_report; exit 1
fi

# CHECKPOINT 3 of 3 -- DID THE INSTRUMENT SURVIVE CONTACT? One ctl read, then
# look at the segment again. Nothing else has happened in between, so anything
# that moved was moved by the probe: a version bump means the probe is a
# different wsys build from the session (the exact defect this file's header
# describes -- a v7 `cat` reading a v6 desktop's ctl line), and next_wid
# falling back to 2 means the table was re-initialised and every window the
# desktop had mapped is gone. Either way the desktop below would photograph as
# empty, and blaming the packages for that is the failure this checkpoint
# exists to make impossible.
NEXT_BEFORE="$(segnext)"
winctl 2 >/dev/null 2>&1
SEG2="$(segstate)"; SEGV2="$(segver)"; NEXT_AFTER="$(segnext)"
if [ "$SEGV2" != "$SEGV1" ]; then
    bad "THIS GATE'S OWN PROBE WIPED THE SESSION: the segment was $SEGV1 and one ctl read by $WORK/cat.elf made it $SEGV2. Reading /dev/wsys/<wid>/ctl attaches, and an attacher of a different WSYS_VERSION re-initialises the table by design. The bytes under test are NOT implicated -- fix the instrument."
    info "  before the read: $SEG1"
    info "  after  the read: $SEG2"
    [ -n "$BINDIR" ] && info "  the probe must come from $BINDIR like everything else; it did not, or that channel's cat is a different wsys build from its wsysd"
    done_report; exit 1
elif [ "${NEXT_BEFORE:-0}" -gt 2 ] && [ "${NEXT_AFTER:-0}" -le 2 ]; then
    bad "THIS GATE'S OWN PROBE WIPED THE SESSION: next_wid went $NEXT_BEFORE -> $NEXT_AFTER across a single ctl read, so the window table was re-initialised under a live desktop. The bytes under test are NOT implicated -- fix the instrument."
    info "  before the read: $SEG1"
    info "  after  the read: $SEG2"
    done_report; exit 1
else
    # INFO and not PASS, deliberately. This is a PRECONDITION on the run being
    # able to answer anything, not one of the eight things this file measures
    # about a mouse -- and the score is quoted across HANDOFF.md and compared
    # between channels (1.0.10 is 2/1, 1.0.11 and 1.0.17 are 13/0). A validity
    # check that inflated the denominator would make every one of those
    # comparisons a different question.
    info "the probe left the session alone (still $SEGV2, next_wid $NEXT_BEFORE -> $NEXT_AFTER) -- it is version-matched to the bytes under test, so every FAIL below is about THEM"
fi

# The top panel, found rather than guessed: the full-width bar nearest the top
# of the screen that is not the full-screen backdrop.
PANEL=""; PANELH=""
for wid in $(seq 2 40); do
    line="$(winctl "$wid")"; [ -n "$line" ] || continue
    set -- $line
    [ "${4:-}" = "$FBW" ] || continue           # full width
    [ "${5:-0}" -lt 200 ] || continue           # a bar, not the backdrop
    [ "${3:-0}" = "0" ] || continue             # at the top of the screen
    PANEL="$wid"; PANELH="${5:-}"
done
if [ -n "$PANEL" ]; then
    ok "hampanelscene mapped a full-width top bar (wid $PANEL, height $PANELH)"
else
    # This sentence spent a day being wrong about a healthy channel, so it now
    # carries the segment's own state with it. If the table is empty and
    # next_wid is back at 2, the windows were WIPED rather than never mapped,
    # and the three checkpoints above have already said by whom.
    bad "no full-width top bar -- there is no Applications button to click"
    info "  segment now: $(segstate)   (at wsysd start: $SEG0)"
    sed 's/^/mouse:      /' "$WORK/hampanelscene.log"
    done_report; exit 1
fi

# Geometry, from the two programs themselves.
#   hampanelscene: the Applications button is the leftmost item on the bar;
#     (40, 13) is inside it (the same point tests/linux/de_appmenu_band.sh
#     pokes). MENU_W is 136 and the card hangs below the bar.
#   hamdesktop: ICON_MARGIN_X 18, ICON_TOP 16, CELL_W 84, CELL_H 72; the
#     selection fill is #3584e4 over (cx-3, cy-1, CELL_W-2, CELL_H-2).
APPBTN_X=40; APPBTN_Y=13
CARDW=136
CELL_W=84; CELL_H=72; ICON_MARGIN_X=18; ICON_TOP=16
SELCOL=3584e4
BODYCOL=f7f8fa
# Cell i's measured rect, kept clear of the top panel band.
cell_x() { echo $((ICON_MARGIN_X - 3)); }
cell_y() { echo $((ICON_TOP + $1 * CELL_H + 4)); }
icon_click_x=$((ICON_MARGIN_X + CELL_W / 2 - 4))
icon_click_y() { echo $((ICON_TOP + $1 * CELL_H + CELL_H / 2)); }
# The card rectangle we measure is BELOW the cursor's resting place after the
# click on the Applications button (the sprite is 12x17 at 40,13), so the
# pointer itself can never be what these percentages are counting.
CARD_Y=$((PANELH + 34))
CARD_H=140

# ---- 3. THE CONTROL, before a single click -------------------------------
snap before
got="$(colourpct 4 "$CARD_Y" $((CARDW - 8)) "$CARD_H" "$WORK/before.raw" "$BODYCOL")"
if [ "$got" -le 5 ]; then
    ok "control: with no click yet, the menu card is not drawn ($got% of the column is the dropdown body)"
else
    bad "control: the dropdown body colour is already $got% of the card column before any click -- this rectangle is not measuring the menu"
fi
SEL0_X="$(cell_x)"; SEL0_Y="$(cell_y 0)"
got="$(colourpct "$SEL0_X" "$SEL0_Y" "$CELL_W" $((CELL_H - 8)) "$WORK/before.raw" "$SELCOL")"
if [ "$got" -le 2 ]; then
    ok "control: with no click yet, the first desktop icon carries no selection highlight ($got%)"
else
    bad "control: the first icon is already $got% selection-coloured before any click"
fi

# ---- 4+5. THE APPLICATIONS BUTTON, CLICKED WITH A MOUSE ------------------
click "$APPBTN_X" "$APPBTN_Y"
snap open
set -- $(winctl "$PANEL")
GROWNW="${4:-0}"; GROWNH="${5:-0}"
if [ "$GROWNW" = "$FBW" ] && [ "$GROWNH" -gt "$PANELH" ]; then
    ok "an EVDEV CLICK on the Applications button opened the menu: the panel window grew ${PANELH} -> ${GROWNH} px tall"
else
    bad "THE DEFECT: after a full evdev click on the Applications button the panel window is still ${GROWNW}x${GROWNH} -- the chrome never saw the click"
    sed 's/^/mouse:      /' "$WORK/hampanelscene.log" | tail -20
fi
got="$(colourpct 4 "$CARD_Y" $((CARDW - 8)) "$CARD_H" "$WORK/open.raw" "$BODYCOL")"
if [ "$got" -ge 60 ]; then
    ok "and the menu is PAINTED in the framebuffer ($got% of the card column is the dropdown body)"
else
    bad "THE DEFECT: the card column is only $got% of the dropdown body colour -- nothing was drawn, so no pixel moved for the click"
fi

# ---- 6. AND CLICKED AGAIN, WHICH MUST CLOSE IT ---------------------------
click "$APPBTN_X" "$APPBTN_Y"
snap closed
set -- $(winctl "$PANEL")
BACKH="${5:-0}"
# "it is back to 26 px" is ALSO true of a panel that never grew, which is the
# reverted state this file exists to catch -- so the open is a precondition of
# the close, not a separate question.
if [ "$GROWNH" -le "$PANELH" ]; then
    bad "the menu never opened, so 'the second click closed it' is not a question this run can answer"
elif [ "$BACKH" = "$PANELH" ]; then
    ok "a second evdev click on the same button closed the menu again (the panel window is back to ${BACKH} px)"
else
    bad "the second click did not close the menu -- the panel window is ${BACKH} px tall, not ${PANELH}. One click that cannot be undone is a stuck panel, not a routed click"
fi
got="$(colourpct 4 "$CARD_Y" $((CARDW - 8)) "$CARD_H" "$WORK/closed.raw" "$BODYCOL")"
if [ "$GROWNH" -le "$PANELH" ]; then
    bad "the card was never painted, so 'the card is gone' is not a question this run can answer"
elif [ "$got" -le 5 ]; then
    ok "and the card is gone from the framebuffer ($got% of the column is the dropdown body)"
else
    bad "the card is still $got% painted after the closing click"
fi

# ---- 7+8. THE DESKTOP ICONS, A SECOND PROGRAM ON A SECOND RING -----------
click "$icon_click_x" "$(icon_click_y 0)"
snap icon0
got="$(colourpct "$SEL0_X" "$SEL0_Y" "$CELL_W" $((CELL_H - 8)) "$WORK/icon0.raw" "$SELCOL")"
if [ "$got" -ge 20 ]; then
    ok "an EVDEV CLICK on the first desktop icon SELECTED it ($got% of the cell is hamdesktop's selection fill)"
else
    bad "THE DEFECT: clicking the first desktop icon with a mouse left it $got% selected -- hamdesktop never saw the click"
    sed 's/^/mouse:      /' "$WORK/hamdesktop.log" | tail -20
fi

SEL1_X="$(cell_x)"; SEL1_Y="$(cell_y 1)"
click "$icon_click_x" "$(icon_click_y 1)"
snap icon1
got1="$(colourpct "$SEL1_X" "$SEL1_Y" "$CELL_W" $((CELL_H - 8)) "$WORK/icon1.raw" "$SELCOL")"
got0="$(colourpct "$SEL0_X" "$SEL0_Y" "$CELL_W" $((CELL_H - 8)) "$WORK/icon1.raw" "$SELCOL")"
if [ "$got1" -ge 20 ] && [ "$got0" -le 2 ]; then
    ok "clicking the SECOND icon moved the selection (cell 2 is $got1% selected, cell 1 back to $got0%) -- the highlight follows the mouse, it was not painted at startup"
else
    bad "the selection did not move: cell 2 is $got1% and cell 1 is still $got0%"
fi

# ---- 9. A CLICK THAT ARRIVES ALL AT ONCE ---------------------------------
# The clicks above are appended phase by phase, so wsysd's 16 ms poll sees the
# press and the release on separate passes. A real device does not promise
# that: the records are queued in the node and one read drains ALL of them, so
# a compositor that spent a frame painting reads `move, down, up` in a single
# pass. `pump_input` used to fold that into ONE routed event -- the last edge
# won, which is the RELEASE, buttons 0 -- and the press was never delivered at
# all. Measured before the fix: seven records written in one go left the
# window's ring holding exactly `u 80 110 0 0`, and a client that derives a
# click from the button bitmap (which is what hampanelscene does, and what
# devwsys's line shape asks of it) can never see that click.
ev "move:$APPBTN_X:$APPBTN_Y" "down" "up"
sleep 2
snap fastopen
set -- $(winctl "$PANEL")
FASTH="${5:-0}"
if [ "$FASTH" -gt "$PANELH" ]; then
    ok "a click whose move/press/release arrive in ONE evdev read still opens the menu (the panel grew to $FASTH px)"
else
    bad "a click delivered in a single evdev read was LOST: the panel window is still $FASTH px tall -- the press and release were folded into one event and the press edge never reached the panel"
fi

# ---- 12. THE RULE THIS GATE EXISTS TO KEEP -------------------------------
# Every gate that came before drove the chrome by writing an event ring as the
# host owner, which is why a completely missing input path went unnoticed for
# the life of the port. If a future edit takes that shortcut here, this file
# stops testing anything and must say so rather than go quietly green.
#
# The pattern names the RING, not the tool. It used to say `wsys_poke`, and
# that was already too narrow before wsys_poke left this file: `cat`, `echo >`,
# a future helper or a fresh copy of wsys_poke would each have walked straight
# past it. What must not appear here is an event, pointer or keys path under
# /dev/wsys at all -- reading one is as disqualifying as writing one, since a
# gate that drains a ring it did not create is no longer measuring delivery.
# The regex is built in a variable so its own two uses cannot match it (the
# literal that follows `/dev/wsys/` here is `[^ ]*`, and `[^ ]*` cannot match
# `[^` and then find the `/` the pattern demands).
RING_RE='/dev/wsys/[^ ]*/(event|pointer|keys)'
if grep -vE '^[[:space:]]*#' "${BASH_SOURCE[0]}" \
        | grep -nE "$RING_RE" >/dev/null; then
    bad "THIS GATE TOUCHES AN INPUT RING BY HAND -- it no longer proves a mouse reaches the chrome"
    grep -vE '^[[:space:]]*#' "${BASH_SOURCE[0]}" \
        | grep -nE "$RING_RE" | sed 's/^/mouse:      /'
else
    ok "every click in this file came from the evdev end: nothing here names an event, pointer or keys ring, whatever program it might have used to do it"
fi

info "clicks delivered: $(grep -c . "$WORK/input.evdev" 2>/dev/null || echo '?') evdev bytes at $(stat -c%s "$WORK/input.evdev") total"
done_report
