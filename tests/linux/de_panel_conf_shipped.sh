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
# tests/linux/de_panel_conf_shipped.sh — IS THE SHIPPED /etc/panel.conf
# ACTUALLY READ?
#
# THE DEFECT THIS GATES
# =====================
# MEASURED, on this tree, before the fix: `etc/panel.conf` is 3120 bytes and
# its first `panel` directive begins at byte 2834. `user/hampanelscene.ad`'s
# `_load_config` read the file into a 2047-byte buffer. The entire read
# therefore landed INSIDE the comment header that documents the format; the
# file parsed to ZERO panels; and the panel silently fell back to
# `_default_config`.
#
#   **Editing the documented configuration file did nothing at all.**
#
# Nobody noticed for the reason NORTH_STAR.md names: the fallback renders
# essentially the same layout, so everything downstream looked right. The gap
# answered something success-shaped — a desktop with a panel on it — instead
# of the truth, which is that its config was never read.
#
# THE ONE VISIBLE TELL, and therefore what this gate measures
# -----------------------------------------------------------
# The shipped file asks for `color #d4d0c8`. `_begin_panel` initialises a
# panel to `#eceef2` and `_default_config` never overrides it. So the two
# paths are told apart by ONE THING that a person can see: with the file
# honoured the bars are #d4d0c8; with the file dropped on the floor they are
# #eceef2. That is a PIXEL question, and every assertion below that matters
# is answered out of the framebuffer, never out of a log line — the panel
# logged `config reload applied: 2 panel(s)` all the way through the defect.
#
# WHY A BIGGER BUFFER IS NOT THE FIX, and what this gate holds to it
# ------------------------------------------------------------------
# A fixed buffer that is merely larger has the same defect at a larger size,
# and this tree has been bitten by exactly that three times (a 16 KiB hook
# limit that truncated silently, an 8 KiB /etc/modules ceiling, a `tail` that
# read only the first 8 KiB). So `_load_config` now STREAMS: 4 KiB chunks,
# parsed one LINE at a time, no whole-file buffer and no size ceiling.
# Assertion 8 holds the fix to that claim rather than to a number — it
# prepends 64 KiB of comments to the same file and demands the same pixels.
# Any fix that is "2048 -> 8192" fails assertion 8.
#
# AND A CONFIG THAT CANNOT BE READ MUST SAY SO
# --------------------------------------------
# Falling back to the built-in default is fine. Falling back SILENTLY is the
# bug — it is what made this defect survive. Assertions 10-13 write configs
# that are unusable in each distinct way (nothing parseable; a line past the
# line limit) and require the panel to name THE FILE and WHAT WENT WRONG on
# stderr, *and* require the fallback it then draws to be visible in pixels.
# The message is asserted only for the failure paths, where a message is the
# whole point; nothing here reads a log to decide whether the panel works.
#
# Entirely offscreen (HAMFB_FILE): no VM, no display, no GPU, about half a
# minute. Software Vulkan ICD is forced because wsysd has a real Vulkan
# backend and this host's GPU belongs to someone.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

# ISOLATE FIRST, before anything creates a file. This gate writes
# /tmp/hamnix-panel.conf, which is NOT scratch: user/hampanelscene.ad reads it
# in preference to the shipped /etc/panel.conf, so it is the live configuration
# override of every desktop on this machine. An earlier gate wrote the real one
# and cost two agents their conclusions -- the incident is written up in
# tests/linux/private_ns.sh. Everything below this line runs in a mount
# namespace whose /tmp, /dev/shm and /srv belong to this run alone; the call
# execs and does not return.
#
# reap.sh is sourced AFTER it, deliberately: its registry defaults to a mktemp
# under /tmp, and a registry made before the tmpfs lands on /tmp is a registry
# this gate can no longer see.
. tests/linux/private_ns.sh
priv_ns_reexec "$@"
. tests/linux/reap.sh

WORK="${PANELSHIP_WORK:-$(mktemp -d -p "${TMPDIR:-/tmp}" panelship.XXXXXX)}"
mkdir -p "$WORK"
KEEP="${PANELSHIP_KEEP:-0}"
GEOM="${HAMFB_GEOM:-1280x800}"
FBW="${GEOM%x*}"; FBH="${GEOM#*x}"

export HAMWSYS="$WORK/wsys.shm"
export HAMWSYS_BB="$WORK/wsys.bb"
export HAMWSYS_IMG="$WORK/wsys.img"
export HAMFB_FILE="$WORK/fb.raw"
export HAMFB_GEOM="$GEOM"
export HAMWSYSD_INPUT="$WORK/input.evdev"
: >"$HAMWSYSD_INPUT"
[ -r /usr/share/vulkan/icd.d/lvp_icd.json ] && \
    export VK_ICD_FILENAMES="${VK_ICD_FILENAMES:-/usr/share/vulkan/icd.d/lvp_icd.json}"

# The active panel config. `_open_config` prefers the writable runtime
# override and falls back to the shipped read-only /etc/panel.conf; this host
# has no writable /etc, so the shipped file's BYTES are exercised through the
# override path. They are copied VERBATIM — header and all — which is the
# whole point of this gate and is checked byte-for-byte at assertion 3.
CONF=/tmp/hamnix-panel.conf
SHIPPED="$PROJ_ROOT/etc/panel.conf"

pass=0; fail=0
# An empty read is not a measurement. See the header of tests/linux/gate_read.sh:
# vis_of below used to end ${8:-x}, so assertion 13 could print "the shipped
# file no longer paints its own colour ... visible top=x" about two windows
# this run never managed to read.
. tests/linux/gate_read.sh

ok()   { echo "panelship: PASS $*"; pass=$((pass+1)); }
bad()  { echo "panelship: FAIL $*"; fail=$((fail+1)); }
info() { echo "panelship: INFO $*"; }

reap_track "$WORK/reaped"
cleanup() {
    rm -f "$CONF"
    [ "$KEEP" = 1 ] || rm -rf "$WORK"
}
reap_on_exit cleanup
done_report() { echo "panelship: $pass passed, $fail failed"; [ "$fail" = 0 ]; }

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

# ---- 1. THE FILE IS THE HARD CASE, measured not assumed -------------------
# If somebody shortens the header this gate stops being about anything, so it
# says out loud what it is standing on. 2047 is the buffer that used to be
# there; the point is that the first directive is PAST it.
read -r CONFSZ FIRSTAT <<EOF
$(python3 - "$SHIPPED" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
i = d.find(b'\npanel ')
print(len(d), (i + 1) if i >= 0 else -1)
PY
)
EOF
if [ "${FIRSTAT:-0}" -gt 2047 ]; then
    ok "the shipped etc/panel.conf is $CONFSZ bytes and its first \`panel\` directive begins at byte $FIRSTAT -- past the 2047-byte read that used to swallow this file whole"
else
    bad "etc/panel.conf's first \`panel\` directive is at byte ${FIRSTAT:-?} of ${CONFSZ:-?} -- it now fits inside the old buffer, so this gate no longer reproduces the defect it exists for"
fi
if grep -q 'color #d4d0c8' "$SHIPPED"; then
    ok "and it asks for \`color #d4d0c8\` -- the colour that is the measurement below"
else
    bad "etc/panel.conf no longer asks for #d4d0c8 -- the discriminator this gate is built on is gone"
    done_report; exit 1
fi

# ---- build ----------------------------------------------------------------
BINDIR="${PANELSHIP_BIN_DIR:-}"
for t in wsysd:user/wsysd.ad \
         hamdesktop:user/hamdesktop.ad \
         hampanelscene:user/hampanelscene.ad \
         wsys_poke:tests/linux/wsys_poke.ad; do
    name="${t%%:*}"; src="${t#*:}"
    if [ -n "$BINDIR" ] && [ "$name" != wsys_poke ]; then
        [ -f "$BINDIR/$name" ] || {
            bad "PANELSHIP_BIN_DIR=$BINDIR does not contain $name -- refusing to substitute a fresh build for the binary you asked about"
            done_report; exit 1; }
        cp "$BINDIR/$name" "$WORK/$name.elf"; chmod +x "$WORK/$name.elf"
        continue
    fi
    scripts/hamlinux_build.sh "$src" "$WORK/$name.elf" \
        >"$WORK/$name.build.log" 2>&1 || {
        bad "could not build $src"; tail -20 "$WORK/$name.build.log" >&2
        done_report; exit 1; }
done
ok "the compositor, the desktop and the panel all build"

winctl() { "$WORK/wsys_poke.elf" "/dev/wsys/$1/ctl" 2>/dev/null; }
# Field 8 of the ctl line is `visible`, field 5 the height. These used to
# default to x / 0 on a ctl line that did not come back, and those defaults
# WERE VERDICTS -- "visible top=x" reads as a withdrawn window when it only
# means the read failed. An unreadable line now yields the EMPTY STRING and
# the caller asks gate_nonempty before it draws any conclusion.
vis_of() { set -- $(winctl "$1"); echo "${8:-}"; }
h_of()   { set -- $(winctl "$1"); echo "${5:-}"; }

# ---- 3. THE SHIPPED FILE, VERBATIM ---------------------------------------
cp "$SHIPPED" "$CONF"
if cmp -s "$SHIPPED" "$CONF"; then
    ok "the active config is etc/panel.conf byte-for-byte ($CONFSZ bytes, comment header and all) -- not a header-less copy of its directives"
else
    bad "the active config is not a verbatim copy of etc/panel.conf"
fi

"$WORK/wsysd.elf" </dev/null >"$WORK/wsysd.log" 2>&1 &
reap_add $!
for _ in $(seq 1 60); do [ -s "$HAMFB_FILE" ] && break; sleep 0.1; done
[ -s "$HAMFB_FILE" ] || { bad "wsysd never produced a framebuffer"
                          cat "$WORK/wsysd.log"; done_report; exit 1; }
if grep -q "input from $WORK/input.evdev only" "$WORK/wsysd.log"; then
    ok "wsysd took its input from the test's evdev file and opened no real device"
else
    bad "wsysd did not honour HAMWSYSD_INPUT -- it may be reading this host's keyboard"
fi

"$WORK/hamdesktop.elf" </dev/null >"$WORK/hamdesktop.log" 2>&1 &
reap_add $!
sleep 3
"$WORK/hampanelscene.elf" </dev/null >"$WORK/panel.log" 2>&1 &
reap_add $!
sleep 4

# ---- 5. the window table: two bars, from a two-panel file -----------------
BACKDROP=""; TOPBAR=""; BOTBAR=""; TOPH=""; BOTH=""; BOTY=0
for wid in $(seq 2 40); do
    line="$(winctl "$wid")"; [ -n "$line" ] || continue
    set -- $line
    [ "${4:-}" = "$FBW" ] || continue
    if [ "${5:-0}" -ge 200 ]; then BACKDROP="$wid"; continue; fi
    if [ "${3:-0}" = "0" ]; then TOPBAR="$wid"; TOPH="${5:-}"
    else                          BOTBAR="$wid"; BOTH="${5:-}"; BOTY="${3:-}"; fi
done
if [ -n "$TOPBAR" ] && [ -n "$BOTBAR" ] && [ -n "$BACKDROP" ]; then
    ok "the window table holds a backdrop (wid $BACKDROP), a top panel (wid $TOPBAR, ${TOPH}px) and a taskbar (wid $BOTBAR, ${BOTH}px at y=$BOTY)"
else
    bad "the desktop did not come up (backdrop='$BACKDROP' top='$TOPBAR' bottom='$BOTBAR') -- nothing below can be answered"
    sed 's/^/panelship:      /' "$WORK/panel.log" | tail -20
    done_report; exit 1
fi

BARCOL=d4d0c8          # what etc/panel.conf asks for
FALLCOL=eceef2         # what _begin_panel/_default_config leave behind
TOPSTRIP_X=$((FBW / 2 - 100)); TOPSTRIP_W=200
BOTSTRIP_X=$((FBW - 300));     BOTSTRIP_W=200
topstrip() { colourpct "$TOPSTRIP_X" 2 "$TOPSTRIP_W" $((TOPH - 4)) "$1" "$2"; }
botstrip() { colourpct "$BOTSTRIP_X" $((BOTY + 2)) "$BOTSTRIP_W" $((BOTH - 4)) "$1" "$2"; }

# ---- 6+7. THE MEASUREMENT: the file's OWN COLOUR reaches the bar ----------
snap shipped
t_want="$(topstrip "$WORK/shipped.raw" "$BARCOL")"
b_want="$(botstrip "$WORK/shipped.raw" "$BARCOL")"
t_fall="$(topstrip "$WORK/shipped.raw" "$FALLCOL")"
if [ "$t_want" -ge 60 ] && [ "$b_want" -ge 60 ]; then
    ok "THE SHIPPED FILE IS HONOURED: both bars are painted in the #$BARCOL the file itself asks for (top ${t_want}%, taskbar ${b_want}%) -- the config was read past byte $FIRSTAT"
else
    bad "THE DEFECT: with etc/panel.conf verbatim in place the bars are ${t_want}% / ${b_want}% of #$BARCOL. The file asked for that colour and did not get it -- it was never parsed"
fi
if [ "$t_fall" -le 5 ]; then
    ok "and NOT the #$FALLCOL of the built-in fallback (${t_fall}% of the top strip) -- the two paths are distinguishable, so the assertion above means something"
else
    bad "THE DEFECT, in the other direction: the top bar is ${t_fall}% #$FALLCOL -- that is \`_default_config\`'s colour, i.e. the shipped file was dropped on the floor and the built-in default drawn in its place"
fi

# ---- 8. NO CEILING, not a bigger one -------------------------------------
# The same directives behind 64 KiB of comments. A fix that moved the buffer
# from 2048 to 8192 (or to 65536) passes assertion 6 and fails this one.
BIGHDR="$WORK/big.conf"
python3 - "$SHIPPED" "$BIGHDR" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
pad = ''.join('# padding line %d, and the directives are all still below it\n' % i
              for i in range(1000))
open(dst, 'w').write(pad + open(src).read())
PY
BIGSZ="$(wc -c <"$BIGHDR")"
cp "$BIGHDR" "$CONF"
for _ in $(seq 1 80); do
    sleep 0.25
    snap bighdr
    [ "$(topstrip "$WORK/bighdr.raw" "$BARCOL")" -ge 60 ] && break
done
t_big="$(topstrip "$WORK/bighdr.raw" "$BARCOL")"
b_big="$(botstrip "$WORK/bighdr.raw" "$BARCOL")"
if [ "$t_big" -ge 60 ] && [ "$b_big" -ge 60 ]; then
    ok "the SAME directives behind a ${BIGSZ}-byte comment header still reach the bar (top ${t_big}%, taskbar ${b_big}%) -- the reader has no size ceiling, so this is not a bigger fixed buffer wearing the fix's hat"
else
    bad "a ${BIGSZ}-byte config parses to ${t_big}% / ${b_big}% of #$BARCOL -- the ceiling was RAISED, not removed, and the next file to cross it will fail exactly as silently as this one did"
fi

# ---- 9. and the live re-read sees past the old ceiling too ---------------
# `_cfg_changed` compared the first 2047 bytes, so an edit to the directives
# at the END of the shipped file did not even register as a CHANGE. Change
# only the colour lines -- every one of them is past byte 2834.
ALT=b0c4de
sed "s/#d4d0c8/#$ALT/" "$SHIPPED" >"$CONF"
for _ in $(seq 1 80); do
    sleep 0.25
    snap altcol
    [ "$(topstrip "$WORK/altcol.raw" "$ALT")" -ge 60 ] && break
done
t_alt="$(topstrip "$WORK/altcol.raw" "$ALT")"
if [ "$t_alt" -ge 60 ]; then
    ok "editing ONLY the \`color\` lines (all of them past byte 2834) repaints the bar #$ALT within seconds (${t_alt}%) -- the live re-read compares the whole file, not its comment header"
else
    bad "an edit to the directives at the END of the file changed ${t_alt}% of the bar to #$ALT -- the live re-read still only looks at the head of the file, so an edit down here is not even noticed as a CHANGE"
fi

# ---- 10. THE MAXIMAL PANEL SET ------------------------------------------
# MAX_PANELS(4) x MAX_WIDGETS(12) launchers is the biggest thing the panel
# model can hold, and it is the input `_save_config`'s buffer bound is
# computed from (50 + 4 * 1357 = 5478 bytes serialized; the buffer was 2048
# and its newline stores were unguarded, i.e. a BSS overrun rather than a
# truncation). This proves that input is REACHABLE through the config, so the
# bound is a real bound and not a hypothetical one. A vertical panel is used
# as the pixel witness because its band is somewhere no other panel paints.
MAXC="$WORK/max.conf"
: >"$MAXC"
i=0
for e in top bottom left right; do
    i=$((i + 1))
    { echo "panel p$i"; echo "  edge $e"; echo "  size 56"; } >>"$MAXC"
    [ "$e" = left ] && echo "  color #ff00ff" >>"$MAXC"
    for w in $(seq 1 12); do
        echo "  widget launcher /bin/hamtermscene T$w" >>"$MAXC"
    done
    echo end >>"$MAXC"
done
cp "$MAXC" "$CONF"
for _ in $(seq 1 80); do
    sleep 0.25
    grep -aq 'honoured, 4 panel(s)' "$WORK/panel.log" && break
done
# WAIT FOR THE PIXELS, NOT FOR THE LOG LINE. `honoured, 4 panel(s)` is printed
# when the config has been PARSED; the two new windows still have to be
# created, painted, committed and composited after that. This assertion used to
# snapshot the framebuffer the instant that line appeared and then blame the
# CONFIG for the empty band -- the one part that had already worked. Measured
# while fixing it: at that instant all four windows exist with the right
# geometry (`0 0 56 800` for the left one) and are at gen 2 with nothing
# presented; two seconds later they are at gen 9 and the band is 96% #ff00ff.
# So the wait is for the thing being asserted, bounded, and what it prints when
# it runs out says which half is missing.
V_DEADLINE="${PANELSHIP_VPANEL_WAIT_S:-10}"
v_max=0
v_t0=$SECONDS
while :; do
    snap maxc
    v_max="$(colourpct 2 $((FBH / 2 - 60)) 50 120 "$WORK/maxc.raw" ff00ff)"
    [ "$v_max" -ge 60 ] && break
    [ $((SECONDS - v_t0)) -ge "$V_DEADLINE" ] && break
    sleep 0.25
done
V_CTL="$(winctl 5 | tr -d '\n')"
[ -n "$V_CTL" ] || V_CTL="$(winctl 4 | tr -d '\n')"
if grep -aq 'honoured, 4 panel(s)' "$WORK/panel.log" && [ "$v_max" -ge 60 ]; then
    ok "the maximal panel set (4 panels x 12 launcher widgets, 5478 bytes serialized) is honoured and its VERTICAL panel is painted (${v_max}% of the left band is #ff00ff, after $((SECONDS - v_t0)) s)"
elif ! grep -aq 'honoured, 4 panel(s)' "$WORK/panel.log"; then
    bad "the maximal panel set was never PARSED: no 'honoured, 4 panel(s)' line. The config is what failed here, not the drawing."
else
    bad "the config was honoured (4 panels) but the VERTICAL panel never PAINTED within ${V_DEADLINE}s -- the left band is ${v_max}% #ff00ff and wants 60. A vertical panel's window: ${V_CTL:-<no window at wid 4 or 5>}. If that window exists with a sane width and height, the parse and the geometry are fine and what is missing is the paint or the composite; if it does not, the panel never mapped a window."
fi

# ---- 11+12. A CONFIG THAT PARSES TO NOTHING SAYS SO ----------------------
# The shipped file's comment header ALONE -- the exact bytes the old reader
# saw and drew a desktop from without a word.
python3 - "$SHIPPED" "$CONF" <<'PY'
import sys
d = open(sys.argv[1]).read()
head = d[:d.index('\npanel ')] + '\n'
open(sys.argv[2], 'w').write(head)
PY
NOPANELSZ="$(wc -c <"$CONF")"
for _ in $(seq 1 80); do
    sleep 0.25
    grep -aq 'parsed 0 panels' "$WORK/panel.log" && break
done
if grep -a 'parsed 0 panels' "$WORK/panel.log" | grep -q "$CONF"; then
    ok "a config that describes no panel is announced BY NAME and by size: $(grep -a 'parsed 0 panels' "$WORK/panel.log" | tail -1)"
else
    bad "the panel fell back to its built-in default from a ${NOPANELSZ}-byte config that parses to zero panels and SAID NOTHING -- that silence is what let this defect live"
    grep -a 'panel.conf' "$WORK/panel.log" | tail -5 | sed 's/^/panelship:      /'
fi
sleep 1
snap nopanel
t_np="$(topstrip "$WORK/nopanel.raw" "$FALLCOL")"
if [ "$t_np" -ge 60 ]; then
    ok "and the fallback it announced is the one actually on screen: the top bar is ${t_np}% #$FALLCOL -- the message and the pixels agree"
else
    bad "the panel announced a fallback but the bar is ${t_np}% #$FALLCOL -- the message does not describe what was drawn"
fi

# ---- 12. A LINE TOO LONG SAYS SO ----------------------------------------
# The one bound the streaming reader still has is the length of ONE LINE.
# It is a real bound on the grammar, and crossing it must be reported --
# a truncated directive that silently means something else is the same
# defect at line scale.
{
    printf '# a config with one absurd line\n'
    printf 'widget launcher /bin/'
    python3 -c "print('x' * 900, end='')"
    printf ' Terminal\n'
    cat "$SHIPPED"
} >"$CONF"
for _ in $(seq 1 80); do
    sleep 0.25
    grep -aq 'TRUNCATED' "$WORK/panel.log" && break
done
if grep -a 'TRUNCATED' "$WORK/panel.log" | grep -q "$CONF"; then
    ok "a line past the reader's line limit is announced BY NAME: $(grep -a 'TRUNCATED' "$WORK/panel.log" | tail -1)"
else
    bad "a 920-byte config line was cut in half and nothing said so -- the directive the panel acted on is not the one the file contains"
fi

# ---- 13. back to the shipped file, and the shipped colour comes back ------
cp "$SHIPPED" "$CONF"
for _ in $(seq 1 80); do
    sleep 0.25
    snap back
    [ "$(topstrip "$WORK/back.raw" "$BARCOL")" -ge 60 ] && break
done
t_back="$(topstrip "$WORK/back.raw" "$BARCOL")"
b_back="$(botstrip "$WORK/back.raw" "$BARCOL")"
tv="$(vis_of "$TOPBAR")"; bv="$(vis_of "$BOTBAR")"
if ! gate_nonempty "the top panel's visible field (/dev/wsys/$TOPBAR/ctl) after the round trip" "$tv"; then
    :
elif ! gate_nonempty "the taskbar's visible field (/dev/wsys/$BOTBAR/ctl) after the round trip" "$bv"; then
    :
elif [ "$t_back" -ge 60 ] && [ "$b_back" -ge 60 ] && [ "$tv" = 1 ] && [ "$bv" = 1 ]; then
    ok "putting etc/panel.conf back restores #$BARCOL on both bars (top ${t_back}%, taskbar ${b_back}%) with both windows still visible (top=$tv taskbar=$bv) -- honoured, dropped and honoured again, all live"
else
    bad "the shipped file no longer paints its own colour after the round trip (top ${t_back}%, taskbar ${b_back}%, visible top=$tv taskbar=$bv)"
fi

info "what the panel said about its config:"
grep -a 'panel\.conf:' "$WORK/panel.log" | tail -8 | sed 's/^/panelship:      /'
done_report
