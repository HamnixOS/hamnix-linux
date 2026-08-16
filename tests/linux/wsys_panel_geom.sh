#!/usr/bin/env bash
# tests/linux/wsys_panel_geom.sh — THE DESKTOP ON A 1920x1200 PANEL, WHICH IS
# THE PANEL IN THE OWNER'S LAPTOP.
#
# THE BUG, AS HE SAW IT ON 2026-08-15
# ===================================
# He booted the machine to a real shell and the desktop did not start:
#
#     Fatal: no screen geometry. /dev/wsys/screen never answered
#
# He then ran `wsysd` by hand, which is the ONLY reason we know the cause:
#
#     wsysd: screen compositor starting
#     hamfb: /dev/fb0 (fbdev) 1920x1200 pitch=7680 size=9216000
#     wsysd: screen larger than the composite buffer
#
# One cause, two messages. `user/linux-wsys.c` fixed the composite ceiling at
# BB_W 1920 / BB_H 1080; `user/wsysd.ad` kept its own copy of that in
# MAX_PIXELS; his panel is 1920x1200 -- ordinary 16:10 -- so read_screen()
# refused, and a compositor that refuses to start never announces, so
# /dev/wsys/screen never answers, so every client dies on the first message.
# The visible message named the symptom. The one that named the cause was
# printed by a program nothing had run.
#
# WHY THIS FILE AND NOT ONE OF THE EXISTING WSYS GATES
# ====================================================
# Every wsys gate in the tree runs at HAMFB_GEOM=1280x800 (or accepts an
# override and is never given one). 1280x800 fits inside ANY of the ceilings
# discussed here, so all of them were green on the day the laptop would not
# boot, and all of them would stay green if the ceiling were put back. A gate
# that cannot reproduce the bug proves nothing about the fix, so:
#
# ARM 1 IS RED BY CONSTRUCTION. It builds `user/wsysd.ad` AS IT WAS at the
# commit before the fix (git show; the file is self-contained on this point --
# its own MAX_PIXELS and its own composite array) and runs it at 1920x1200. It
# must refuse, must leave no framebuffer, and a real hamdesktop against it must
# print exactly the message the owner saw. If that arm ever goes green this
# gate has stopped measuring his bug and every arm below it is worthless.
#
# WHAT IS MEASURED
# ================
#   1. RED: the pre-fix compositor refuses 1920x1200 and hamdesktop dies of
#      "no screen geometry" -- both of his symptoms, from one cause.
#   2. GREEN: the current compositor STARTS at 1920x1200 and writes a
#      framebuffer of exactly 1920*1200*4 bytes.
#   3. GREEN, PAINTED, AND BELOW THE OLD CEILING. Not a log line: the desktop,
#      both panels and an ordinary application window are asserted from PIXELS,
#      and the probe window and the taskbar are placed BELOW y=1080 on purpose
#      -- inside the 120-row band the old buffer could not have held at all.
#   4. THE CEILING IS WHERE IT SAYS IT IS: 2560x1600 is accepted and 2561x1600
#      is refused, so the check is at the stated number and not merely "big".
#   5. THE REFUSAL EXPLAINS ITSELF: it prints BOTH rectangles, it names the
#      client message it causes, it leaves the reason in a file, and
#      lib/hamscreen.ad quotes that file back under the client's own FATAL.
#      With no reason present the client says THAT instead, so "wsysd refused"
#      and "wsysd was never started" stop being the same symptom.
#   6. THE SECOND COPY OF THE CONSTANT AGREES WITH THE DEVICE: /dev/wsys/pool
#      publishes `maxsurface <w>x<h>` and wsysd checks its own COMP_W/COMP_H
#      against it, so the drift that caused this cannot happen silently again.
#
# Entirely offscreen: HAMFB_FILE, no VM, no display, no DRM master. The
# software Vulkan ICD is forced because this host's GPU belongs to someone.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

# The desktop stack writes FIXED, HOST-GLOBAL names whatever this script does
# about $WORK -- and this gate adds one of its own: user/wsysd.ad writes its
# startup refusal to /tmp/hamnix-wsysd.fault, which is the whole point of arm 5
# and is exactly the kind of name another agent's run would collide on. Inside
# the namespace this call establishes, /tmp, /dev/shm and /srv are this run's
# alone. It execs and does not return.
. tests/linux/private_ns.sh
priv_ns_reexec "$@"

WORK="${PANELGEOM_WORK:-$(mktemp -d -p "${TMPDIR:-/tmp}" panelgeom.XXXXXX)}"
mkdir -p "$WORK"
KEEP="${PANELGEOM_KEEP:-0}"

# HIS PANEL, and it is the default rather than an override nobody passes.
GEOM="${HAMFB_GEOM:-1920x1200}"
FBW="${GEOM%x*}"; FBH="${GEOM#*x}"

# The ceiling the tree claims, read from the source rather than retyped here --
# a gate with its own third copy of this constant would be the defect it tests.
CEIL_W="$(sed -n 's/^#define BB_W  *\([0-9][0-9]*\).*/\1/p' user/linux-wsys.c | head -1)"
CEIL_H="$(sed -n 's/^#define BB_H  *\([0-9][0-9]*\).*/\1/p' user/linux-wsys.c | head -1)"
COMP_W="$(sed -n 's/^COMP_W: int32 = \([0-9][0-9]*\).*/\1/p' user/wsysd.ad | head -1)"
COMP_H="$(sed -n 's/^COMP_H: int32 = \([0-9][0-9]*\).*/\1/p' user/wsysd.ad | head -1)"

# The commit the fix landed on top of: the red arm's wsysd.ad comes from here.
RED_REV="${PANELGEOM_RED_REV:-2b7ee4a4}"

FAULT=/tmp/hamnix-wsysd.fault

[ -r /usr/share/vulkan/icd.d/lvp_icd.json ] && \
    export VK_ICD_FILENAMES="${VK_ICD_FILENAMES:-/usr/share/vulkan/icd.d/lvp_icd.json}"

pass=0; fail=0
ok()   { echo "panelgeom: PASS $*"; pass=$((pass+1)); }
bad()  { echo "panelgeom: FAIL $*"; fail=$((fail+1)); }
info() { echo "panelgeom: INFO $*"; }
done_report() { echo "panelgeom: $pass passed, $fail failed"; [ "$fail" = 0 ]; }

. tests/linux/reap.sh
reap_track "$WORK/reaped"
cleanup() { reap_all; [ "$KEEP" = 1 ] || rm -rf "$WORK"; }
reap_on_exit cleanup

# ---- pixel arithmetic -----------------------------------------------------
# "what fraction of this rectangle is exactly this colour", and "what fraction
# of it is not black". The second is what asks whether the wallpaper reaches a
# band; a gradient has no single colour to name.
FRAC_PY="$WORK/frac.py"
cat >"$FRAC_PY" <<'PY'
import sys
mode = sys.argv[1]
W, H = int(sys.argv[2]), int(sys.argv[3])
x, y, w, h = (int(v) for v in sys.argv[4:8])
d = open(sys.argv[8], 'rb').read()
want = None
if mode == 'colour':
    c = sys.argv[9]
    want = (int(c[0:2], 16), int(c[2:4], 16), int(c[4:6], 16))
tot = hit = 0
for j in range(y, min(y + h, H), 2):
    row = j * W * 4
    for i in range(x, min(x + w, W), 2):
        o = row + i * 4
        if o + 3 > len(d):
            continue
        tot += 1
        px = (d[o+2], d[o+1], d[o])
        if mode == 'colour':
            if px == want:
                hit += 1
        else:                                  # 'lit': anything but black
            if px != (0, 0, 0):
                hit += 1
print(0 if tot == 0 else hit * 100 // tot)
PY
colourpct() { python3 "$FRAC_PY" colour "$FBW" "$FBH" "$1" "$2" "$3" "$4" "$5" "$6"; }
litpct()    { python3 "$FRAC_PY" lit    "$FBW" "$FBH" "$1" "$2" "$3" "$4" "$5"; }

# ---- build ----------------------------------------------------------------
build() {   # build <src> <outname>
    scripts/hamlinux_build.sh "$1" "$WORK/$2.elf" >"$WORK/$2.build.log" 2>&1 || {
        bad "could not build $1"; tail -20 "$WORK/$2.build.log" >&2
        done_report; exit 1; }
}
for t in wsysd:user/wsysd.ad \
         hamdesktop:user/hamdesktop.ad \
         hampanelscene:user/hampanelscene.ad \
         wsys_zclient:tests/linux/wsys_zclient.ad \
         wsys_poke:tests/linux/wsys_poke.ad; do
    build "${t#*:}" "${t%%:*}"
done
ok "the compositor, the desktop, the panel and the probe client all build"

# THE RED ARM'S BINARY. `user/wsysd.ad` as it was before the fix. The basename
# must be `wsysd.ad`: scripts/hamlinux_build.sh selects the Vulkan objects by
# basename, and a copy called anything else fails to link.
mkdir -p "$WORK/redsrc"
if git show "$RED_REV:user/wsysd.ad" >"$WORK/redsrc/wsysd.ad" 2>"$WORK/redsrc/git.log"; then
    :
else
    bad "could not retrieve user/wsysd.ad at $RED_REV -- the red arm cannot be built, so nothing below is a controlled measurement"
    cat "$WORK/redsrc/git.log" >&2; done_report; exit 1
fi
if grep -q 'MAX_PIXELS: uint64 = 2073600' "$WORK/redsrc/wsysd.ad"; then
    ok "the red arm's source is the pre-fix compositor: MAX_PIXELS 2073600 (1920x1080)"
else
    bad "the source at $RED_REV does not carry MAX_PIXELS 2073600 -- $RED_REV is not the commit this bug lived on, so the red arm is not his bug"
    done_report; exit 1
fi
build "$WORK/redsrc/wsysd.ad" wsysd_red

# ---- how a compositor is started ------------------------------------------
# One helper so the red and green arms differ in exactly one thing: the ELF.
#
# "STARTED" IS "THE PROCESS IS STILL ALIVE", AND THE FIRST VERSION OF THIS
# HELPER GOT IT WRONG IN A WAY WORTH RECORDING, BECAUSE IT MADE THE RED ARM
# CLAIM THE BUG WAS NOT REPRODUCIBLE. It waited for HAMFB_FILE to become
# non-empty. But read_screen() learns the geometry by READING /dev/fb, and that
# read is what initialises the framebuffer -- so user/linux-fb.c creates and
# sizes the offscreen file BEFORE the refusal that follows it. The refusing
# compositor therefore left a perfectly good 9,216,000-byte fb.raw behind and
# the gate scored it as a successful start, with "wsysd: screen larger than the
# composite buffer" sitting in the log two lines above the FAIL.
#
# A compositor that refuses exits in milliseconds and one that starts runs
# forever, so the honest question is whether it is still there after a settle
# period. The framebuffer's SIZE is still asserted -- by the arms, where it
# means something -- but its EXISTENCE says nothing.
run_wsysd() {   # run_wsysd <elf> <dir> <geom> [seconds-to-wait]
    local elf="$1" d="$2" geom="$3" wait="${4:-8}"
    rm -rf "$d"; mkdir -p "$d"
    : >"$d/input.evdev"
    rm -f "$FAULT"
    ( export HAMWSYS="$d/wsys.shm" HAMWSYS_BB="$d/wsys.bb" \
             HAMWSYS_IMG="$d/wsys.img" HAMFB_FILE="$d/fb.raw" \
             HAMFB_GEOM="$geom" HAMWSYSD_INPUT="$d/input.evdev"
      "$elf" </dev/null >"$d/wsysd.log" 2>&1 &
      echo $! >"$d/pid" )
    local p; p="$(cat "$d/pid" 2>/dev/null)"
    reap_add "$p"
    local i=0
    while [ "$i" -lt $((wait * 10)) ]; do
        kill -0 "$p" 2>/dev/null || return 1      # it refused and exited
        [ -s "$d/fb.raw" ] && break
        sleep 0.1; i=$((i+1))
    done
    # THE SETTLE. A refusal can outrun the poll above on a fast host: the
    # geometry read creates fb.raw and the refusal is the next statement.
    sleep 2
    kill -0 "$p" 2>/dev/null
}
# A DE client, against whatever compositor $1's directory holds.
run_client() {  # run_client <dir> <elf> <logname> [args...]
    local d="$1" elf="$2" log="$3"; shift 3
    ( export HAMWSYS="$d/wsys.shm" HAMWSYS_BB="$d/wsys.bb" \
             HAMWSYS_IMG="$d/wsys.img" HAMFB_FILE="$d/fb.raw" \
             HAMFB_GEOM="$GEOM"
      "$elf" "$@" </dev/null >"$d/$log" 2>&1 &
      echo $! >"$d/$log.pid" )
    reap_add "$(cat "$d/$log.pid" 2>/dev/null)"
}

# ===========================================================================
# ARM 1 -- RED. HIS BUG, REPRODUCED, BEFORE ANYTHING ELSE IS BELIEVED.
# ===========================================================================
info "arm 1 (red): the PRE-FIX compositor at ${FBW}x${FBH}, which is his panel"
if run_wsysd "$WORK/wsysd_red.elf" "$WORK/red" "$GEOM" 8; then
    bad "the pre-fix compositor STARTED at ${FBW}x${FBH} -- this gate is not reproducing the reported bug, so its green arms prove nothing"
    sed 's/^/panelgeom:      /' "$WORK/red/wsysd.log"
    done_report; exit 1
fi
ok "arm 1: the pre-fix compositor did NOT come up at ${FBW}x${FBH}"
if grep -q 'larger than the composite buffer' "$WORK/red/wsysd.log"; then
    ok "arm 1: and it failed for HIS reason -- \"$(grep -m1 'composite buffer' "$WORK/red/wsysd.log")\""
else
    bad "arm 1: the pre-fix compositor failed for some OTHER reason; this is not his bug"
    sed 's/^/panelgeom:      /' "$WORK/red/wsysd.log"
    done_report; exit 1
fi
# NOTE, and it is the reason run_wsysd is written the way it is: a framebuffer
# file DOES exist here. read_screen() reads /dev/fb to learn the geometry, and
# that read initialises the framebuffer, so the refusal happens after the file
# has been created and sized. Its existence proves nothing. What matters is
# that nothing ever composited into it and no geometry was ever announced --
# which is what the client below measures.
if [ -s "$WORK/red/fb.raw" ]; then
    info "arm 1: a $(stat -c %s "$WORK/red/fb.raw")-byte framebuffer file exists even so -- reading /dev/fb for the geometry is what creates it, and the refusal comes after. Nothing painted into it."
fi

# THE SECOND SYMPTOM, FROM THE SAME CAUSE: the message he actually saw.
run_client "$WORK/red" "$WORK/hamdesktop.elf" hamdesktop.log
sleep 14
if grep -q 'no screen geometry' "$WORK/red/hamdesktop.log"; then
    ok "arm 1: hamdesktop died of \"no screen geometry\" -- the exact message on his screen, produced here by the composite-buffer refusal above"
else
    bad "arm 1: hamdesktop did not report 'no screen geometry'; the two symptoms are not being linked"
    sed 's/^/panelgeom:      /' "$WORK/red/hamdesktop.log"
fi
reap_all
sleep 0.5

# ===========================================================================
# ARM 2 -- GREEN. THE CURRENT COMPOSITOR, AT THE SAME GEOMETRY.
# ===========================================================================
info "arm 2 (green): the current compositor at ${FBW}x${FBH}"
if run_wsysd "$WORK/wsysd.elf" "$WORK/g" "$GEOM" 20; then
    ok "arm 2: the compositor STARTED at ${FBW}x${FBH} -- the geometry that stopped his laptop"
else
    bad "arm 2: the compositor still does not start at ${FBW}x${FBH}"
    sed 's/^/panelgeom:      /' "$WORK/g/wsysd.log"
    done_report; exit 1
fi
WANT_BYTES=$((FBW * FBH * 4))
GOT_BYTES="$(stat -c %s "$WORK/g/fb.raw" 2>/dev/null || echo 0)"
if [ "$GOT_BYTES" = "$WANT_BYTES" ]; then
    ok "arm 2: the framebuffer is exactly $WANT_BYTES bytes (${FBW}*${FBH}*4) -- the full panel, not a clipped one"
else
    bad "arm 2: the framebuffer is $GOT_BYTES bytes, wanted $WANT_BYTES"
fi
if grep -q "wsysd: screen ${FBW}x${FBH} (composite buffer ${COMP_W}x${COMP_H})" "$WORK/g/wsysd.log"; then
    ok "arm 2: wsysd states BOTH rectangles at startup: screen ${FBW}x${FBH}, buffer ${COMP_W}x${COMP_H}"
else
    bad "arm 2: wsysd's startup line does not state both the screen and the buffer"
    grep -m3 'screen' "$WORK/g/wsysd.log" | sed 's/^/panelgeom:      /'
fi

# ---- arm 6, taken here because the compositor is up ------------------------
# The two copies of the ceiling, and the device's own published answer.
if [ "$CEIL_W" = "$COMP_W" ] && [ "$CEIL_H" = "$COMP_H" ]; then
    ok "arm 6: BB_W x BB_H (${CEIL_W}x${CEIL_H}, user/linux-wsys.c) and COMP_W x COMP_H (${COMP_W}x${COMP_H}, user/wsysd.ad) agree in the source"
else
    bad "arm 6: the two copies of the ceiling DISAGREE in the source: ${CEIL_W}x${CEIL_H} vs ${COMP_W}x${COMP_H} -- this is the drift that stopped his laptop"
fi
POOL="$( ( export HAMWSYS="$WORK/g/wsys.shm" HAMWSYS_BB="$WORK/g/wsys.bb" \
                  HAMWSYS_IMG="$WORK/g/wsys.img" HAMFB_FILE="$WORK/g/fb.raw"
           "$WORK/wsys_poke.elf" /dev/wsys/pool 2>/dev/null ) )"
if [ -z "$POOL" ]; then
    info "arm 6: /dev/wsys/pool could not be read from this gate, so the device's own statement of its ceiling is UNMEASURED here (the compositor's own check_maxsurface still runs -- see the drift assertion below)"
elif echo "$POOL" | grep -q "maxsurface ${CEIL_W}x${CEIL_H}"; then
    ok "arm 6: the device itself publishes \`maxsurface ${CEIL_W}x${CEIL_H}\` on /dev/wsys/pool"
else
    bad "arm 6: /dev/wsys/pool does not state maxsurface ${CEIL_W}x${CEIL_H} -- it said: $POOL"
fi
if grep -q 'have drifted apart' "$WORK/g/wsysd.log"; then
    bad "arm 6: wsysd's own startup check says its ceiling and the device's have drifted apart -- \"$(grep -m1 'drifted apart' "$WORK/g/wsysd.log")\""
else
    ok "arm 6: wsysd's startup check read the device's ceiling back and found no drift"
fi

# ===========================================================================
# ARM 3 -- PAINTED, AND PAINTED IN THE BAND THE OLD BUFFER COULD NOT HOLD.
# ===========================================================================
# Everything measured below y=1080 is inside the 120 rows that did not exist
# before this fix. A screenshot that only proves the top 1080 rows work would
# have passed on the day his laptop would not boot.
OLDH=1080
if [ "$FBH" -le "$OLDH" ]; then
    info "arm 3: this run's height ($FBH) is not past the old $OLDH ceiling, so the band assertions are being taken inside a region the old buffer also covered"
    BANDY=$((FBH - 100))
else
    BANDY=$((OLDH + 10))
fi

run_client "$WORK/g" "$WORK/hamdesktop.elf" hamdesktop.log
sleep 4
run_client "$WORK/g" "$WORK/hampanelscene.elf" hampanelscene.log
sleep 4

# An ordinary application window, placed INSIDE the new band.
APPX=300; APPY=$BANDY; APPW=360; APPH=$((FBH - BANDY - 60)); APPCOL=7A1FA2
[ "$APPH" -lt 40 ] && APPH=40
run_client "$WORK/g" "$WORK/wsys_zclient.elf" zclient.log \
    "$APPX" "$APPY" "$APPW" "$APPH" 6 "$APPCOL" pgprobe 900
sleep 5
cp "$WORK/g/fb.raw" "$WORK/shot.raw"

winctl() { ( export HAMWSYS="$WORK/g/wsys.shm" HAMWSYS_BB="$WORK/g/wsys.bb" \
                    HAMWSYS_IMG="$WORK/g/wsys.img" HAMFB_FILE="$WORK/g/fb.raw"
             "$WORK/wsys_poke.elf" "/dev/wsys/$1/ctl" 2>/dev/null ); }

TOPBAR=""; BOTBAR=""; BACKDROP=""
for wid in $(seq 2 40); do
    line="$(winctl "$wid")"; [ -n "$line" ] || continue
    set -- $line
    [ "${4:-}" = "$FBW" ] || continue                    # full width
    if [ "${5:-0}" -ge $((FBH - 40)) ]; then BACKDROP="$wid"; continue; fi
    if [ "${3:-0}" = "0" ]; then TOPBAR="$wid"; else BOTBAR="$wid"; fi
done
[ -n "$BACKDROP" ] && ok "arm 3: hamdesktop mapped a backdrop the full ${FBW}x${FBH} of the panel (wid $BACKDROP)" \
                   || bad "arm 3: no full-screen backdrop at ${FBW}x${FBH} -- the desktop did not lay itself out for this panel"
[ -n "$TOPBAR" ]   && ok "arm 3: hampanelscene mapped a full-width TOP bar (wid $TOPBAR)" \
                   || bad "arm 3: no full-width top bar"
[ -n "$BOTBAR" ]   && ok "arm 3: hampanelscene mapped a full-width BOTTOM taskbar (wid $BOTBAR), and its y is inside the panel's real height" \
                   || bad "arm 3: no full-width bottom taskbar -- the panel that has to sit at the BOTTOM of a ${FBH}-row screen is missing"

# THE PIXELS. Not a log line.
got="$(litpct 40 "$BANDY" $((FBW - 80)) 60 "$WORK/shot.raw")"
if [ "$got" -ge 90 ]; then
    ok "arm 3: the desktop is PAINTED at y=$BANDY ($got% of that band is not black) -- inside the ${FBH}-$OLDH row strip the old buffer could not hold"
else
    bad "arm 3: only $got% of the band at y=$BANDY is painted -- the bottom of the panel is black"
fi
got="$(colourpct "$APPX" "$APPY" "$APPW" "$APPH" "$WORK/shot.raw" "$APPCOL")"
if [ "$got" -ge 90 ]; then
    ok "arm 3: an ordinary application window is composited in the new band ($got% of its rect is its own colour)"
else
    bad "arm 3: the application window in the new band is only $got% of its colour -- a client cannot be painted down there"
    sed 's/^/panelgeom:      /' "$WORK/g/zclient.log"
fi
# The top of the screen too, so "painted" is not satisfied by one lucky strip.
got="$(litpct 40 200 $((FBW - 80)) 200 "$WORK/shot.raw")"
[ "$got" -ge 90 ] && ok "arm 3: the middle of the screen is painted as well ($got%)" \
                  || bad "arm 3: the middle of the screen is only $got% painted"
reap_all
sleep 0.5

# ===========================================================================
# ARM 4 -- THE CEILING IS WHERE IT SAYS IT IS.
# ===========================================================================
if run_wsysd "$WORK/wsysd.elf" "$WORK/at" "${CEIL_W}x${CEIL_H}" 25; then
    ok "arm 4: the compositor starts at exactly ${CEIL_W}x${CEIL_H}, the stated ceiling"
else
    bad "arm 4: the compositor will not start at its own stated ceiling ${CEIL_W}x${CEIL_H} -- the number it publishes is not the number it honours"
    sed 's/^/panelgeom:      /' "$WORK/at/wsysd.log"
fi
reap_all; sleep 0.5
if run_wsysd "$WORK/wsysd.elf" "$WORK/over" "$((CEIL_W + 1))x${CEIL_H}" 8; then
    bad "arm 4: the compositor started at $((CEIL_W + 1))x${CEIL_H}, one column PAST its stated ceiling -- the refusal is not where it claims"
else
    ok "arm 4: one column past the ceiling ($((CEIL_W + 1))x${CEIL_H}) is still refused, so the limit is the stated one and not merely 'big'"
fi
reap_all; sleep 0.5

# ===========================================================================
# ARM 5 -- THE REFUSAL EXPLAINS ITSELF.
# ===========================================================================
BIGW=$((CEIL_W * 2)); BIGH=$((CEIL_H * 2))
if run_wsysd "$WORK/wsysd.elf" "$WORK/big" "${BIGW}x${BIGH}" 8; then
    bad "arm 5: the compositor started at ${BIGW}x${BIGH}, which is genuinely larger than its buffer -- the refusal path is gone"
else
    ok "arm 5: a genuinely-too-large screen (${BIGW}x${BIGH}) is still refused"
fi
MSG="$(cat "$WORK/big/wsysd.log" 2>/dev/null)"
if echo "$MSG" | grep -q "${BIGW}x${BIGH}" && echo "$MSG" | grep -q "${COMP_W}x${COMP_H}"; then
    ok "arm 5: the refusal states BOTH numbers -- the screen (${BIGW}x${BIGH}) and the buffer (${COMP_W}x${COMP_H}). It used to state neither."
else
    bad "arm 5: the refusal does not state both the screen and the buffer size: $MSG"
fi
if echo "$MSG" | grep -q 'no screen geometry'; then
    ok "arm 5: and it names the message its victims will print, so the two halves of his report are connected in the log"
else
    bad "arm 5: the refusal does not mention the client-side message it causes, so the two symptoms are still unlinked"
fi
if [ -s "$FAULT" ]; then
    ok "arm 5: the reason was left in $FAULT for a program that starts later"
else
    bad "arm 5: no reason was left in $FAULT"
fi

# THE CLIENT'S MESSAGE, which is the only one a person without a shell sees.
run_client "$WORK/big" "$WORK/hamdesktop.elf" hamdesktop.log
sleep 14
DL="$WORK/big/hamdesktop.log"
if grep -q "${BIGW}x${BIGH}" "$DL" && grep -q "${COMP_W}x${COMP_H}" "$DL"; then
    ok "arm 5: hamdesktop -- the program he can see -- now prints the REAL CAUSE with both numbers, not just its own disappointed expectation"
else
    bad "arm 5: hamdesktop still names only the symptom; a person with no shell learns nothing"
    sed 's/^/panelgeom:      /' "$DL"
fi
reap_all; sleep 0.5

# AND THE OTHER BRANCH: no compositor at all must not be reported as a refusal.
rm -f "$FAULT"
mkdir -p "$WORK/none"
run_client "$WORK/none" "$WORK/hamdesktop.elf" hamdesktop.log
sleep 14
if grep -q 'left no reason' "$WORK/none/hamdesktop.log"; then
    ok "arm 5 (control): with NO fault file the client says the compositor was never started -- \"wsysd refused\" and \"wsysd was never run\" are no longer the same message"
else
    bad "arm 5 (control): with no fault file the client did not distinguish 'never started' from 'refused'"
    sed 's/^/panelgeom:      /' "$WORK/none/hamdesktop.log"
fi

# ---- what this cannot tell us ---------------------------------------------
info "NOT MEASURED HERE: real hardware. Every framebuffer above is HAMFB_FILE, so his fbdev driver, his panel's pitch (7680) and whether the kernel hands wsysd 1920x1200 at all are untested; the geometry is asserted by this gate, not discovered from a device. The scanout/DRM path is also untouched -- it belongs to his live X session and this gate never takes DRM master."

done_report
