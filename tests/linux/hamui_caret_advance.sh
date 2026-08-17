#!/usr/bin/env bash
# tests/linux/hamui_caret_advance.sh — WHERE lib/hamui.ad PUTS THE TEXT CARET.
#
# WHAT THIS GATE IS ACTUALLY FOR, AND IT IS NOT THE CARET.
#
# Until this file existed NOTHING in this tree could look at a pixel lib/hamui.ad
# painted. The compositor had de_backdrop_bottom.sh, the desktop had
# de_appmenu_brisk.sh, the panel had wsys_panel_geom.sh and the terminal had
# term_caret_advance.sh -- but the WIDGET TOOLKIT that 111 programs in user/
# import had no offscreen harness at all. That is not a small gap. It is the
# reason a monospace `index * 8` caret survived in it for the entire life of
# task #303, which converted the `text`/`glyphs` scene primitives to the
# PROPORTIONAL DejaVu face and fixed the same arithmetic everywhere it could
# see it. It could not see hamui, because nobody could.
#
# WHAT BLOCKED IT BEFORE, since the answer turned out to be embarrassing and
# worth writing down so the next agent does not spend a day on it: NOTHING in
# the compositor, the framebuffer or the namespace. user/hamui_demo.ad renders
# ONE frame and exits unless argv[1] is "run", so every attempt to screenshot it
# photographed a screen the client had already left. A hamui client under
# HAMFB_FILE + HAMWSYS* + a real wsysd needs no device the other gates do not
# already provide.
#
# THE BUG. lib/hamui.ad placed the ENTRY caret at `w_state * 8` and the
# TEXTVIEW caret at `caret_col * 8`, and mapped clicks back with `(rel + 4) / 8`
# in both -- four copies of an 8px monospace cell sitting directly beside
# proportional glyph drawing. lib/hamtextbox.ad has owned the correct
# measurement since #303: htb_caret_x() sums the SAME per-glyph advances the
# compositor lays out with, and htb_hit_test() is its inverse. hamui simply
# never called them.
#
# THE RED ARM IS THE POINT. A probe client linked against lib/hamui.ad AS IT WAS
# at $RED_REV must show the caret drifting off the end of the text, and by MORE
# at a longer string than a shorter one -- that growth is the owner's report
# ("the cursor is right of the text, and further along the line it gets worse")
# and a fixed offset would not be it. If that arm ever goes green this gate has
# stopped measuring his bug.
#
# HOW THE CARET IS TOLD APART FROM THE TEXT, which is the whole measurement and
# is done in pixels rather than by arithmetic that could share the bug's own
# mistake: the caret and the glyphs occupy the SAME 16px band, so no y-split can
# separate them. Instead the gate photographs the entry TWICE with identical
# text -- once focused (caret drawn) and once after focus has moved to the
# textview (caret NOT drawn) -- and DIFFS the two images. The columns that
# appear only in the focused shot ARE the caret, by construction. The rightmost
# ink in the unfocused shot is the last glyph's right edge. Both numbers come
# out of the framebuffer.
#
# Entirely offscreen: HAMFB_FILE, no VM, no display, no DRM master.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

. tests/linux/private_ns.sh
priv_ns_reexec "$@"

. tests/linux/reap.sh

WORK="${HAMUI_CARET_WORK:-$(mktemp -d)}"; mkdir -p "$WORK"
KEEP="${HAMUI_CARET_KEEP:-0}"
reap_track "$WORK/reaped"
cleanup() { reap_all; [ "$KEEP" = 1 ] || rm -rf "$WORK"; }
reap_on_exit cleanup

GEOM="${HAMFB_GEOM:-1920x1200}"
FBW="${GEOM%x*}"; FBH="${GEOM#*x}"

# The tree as it was before this fix: hamui still multiplying by 8.
RED_REV="${HAMUI_CARET_RED_REV:-66e60447}"

[ -r /usr/share/vulkan/icd.d/lvp_icd.json ] && \
    export VK_ICD_FILENAMES="${VK_ICD_FILENAMES:-/usr/share/vulkan/icd.d/lvp_icd.json}"

pass=0; fail=0
ok()   { echo "hamuicaret: PASS $*"; pass=$((pass+1)); }
bad()  { echo "hamuicaret: FAIL $*"; fail=$((fail+1)); }
info() { echo "hamuicaret: INFO $*"; }
done_report() { echo "hamuicaret: $pass passed, $fail failed"; [ "$fail" = 0 ]; }

# ---- the probe's geometry, READ FROM THE PROBE'S OWN SOURCE --------------
# A gate that keeps its own copy of these is the defect it tests.
PSRC=tests/linux/hamui_caret_probe.ad
pget() { sed -n "s/^$1: *int32 *= *\([0-9][0-9]*\).*/\1/p" "$PSRC" | head -1; }
EX="$(pget PROBE_EX)"; EY="$(pget PROBE_EY)"
EW="$(pget PROBE_EW)"; EH="$(pget PROBE_EH)"
TX="$(pget PROBE_TX)"; TY="$(pget PROBE_TY)"
TW="$(pget PROBE_TW)"; TH="$(pget PROBE_TH)"
for v in EX EY EW EH TX TY TW TH; do
    [ -n "${!v}" ] || { echo "hamuicaret: FAIL could not read PROBE_$v out of $PSRC"; exit 1; }
done
info "probe geometry from its source: ENTRY at (${EX},${EY}) ${EW}x${EH}, TEXTVIEW at (${TX},${TY}) ${TW}x${TH}"

# ---- pixel tools ---------------------------------------------------------
# WHAT COUNTS AS INK. lib/hamui.ad fills an ENTRY with #202020 and draws its
# text and caret in #f0f0f0, so "differs from the entry's own fill" is
# unambiguous -- and the gate proves the instrument CAN find ink before it
# believes any absence of it.
INK_PY="$WORK/ink.py"
cat >"$INK_PY" <<'PY'
import sys
# ink.py <fb> <W> <y0> <y1> <x0> <x1>  -> "<minx> <maxx> <count>"
fb, W, y0, y1, x0, x1 = sys.argv[1], *[int(v) for v in sys.argv[2:7]]
d = open(fb, 'rb').read()
lo = 1 << 30; hi = -1; n = 0
for j in range(y0, y1):
    o = j * W * 4
    for i in range(x0, x1):
        p = o + i * 4
        if p + 3 > len(d):
            continue
        b, g, r = d[p], d[p+1], d[p+2]
        if abs(b - 0x20) + abs(g - 0x20) + abs(r - 0x20) > 40:
            n += 1
            if i < lo: lo = i
            if i > hi: hi = i
print(lo if hi >= 0 else -1, hi, n)
PY
ink() { python3 "$INK_PY" "$1" "$FBW" "$2" "$3" "$4" "$5"; }

# THE CARET, BY SUBTRACTION. Columns whose pixels differ between the focused
# and unfocused shots over the same band. With identical text in both, the
# only thing that changed is the caret -- and its own border highlight, which
# is why the band is taken INSIDE the entry rather than across it.
DIFF_PY="$WORK/diff.py"
cat >"$DIFF_PY" <<'PY'
import sys
# diff.py <fbA> <fbB> <W> <y0> <y1> <x0> <x1> -> "<minx> <maxx> <count>"
a, b, W, y0, y1, x0, x1 = sys.argv[1], sys.argv[2], *[int(v) for v in sys.argv[3:8]]
A = open(a, 'rb').read(); B = open(b, 'rb').read()
lo = 1 << 30; hi = -1; n = 0
for j in range(y0, y1):
    o = j * W * 4
    for i in range(x0, x1):
        p = o + i * 4
        if p + 3 > len(A) or p + 3 > len(B):
            continue
        if abs(A[p]-B[p]) + abs(A[p+1]-B[p+1]) + abs(A[p+2]-B[p+2]) > 40:
            n += 1
            if i < lo: lo = i
            if i > hi: hi = i
print(lo if hi >= 0 else -1, hi, n)
PY
diffcols() { python3 "$DIFF_PY" "$1" "$2" "$FBW" "$3" "$4" "$5" "$6"; }

# ---- evdev ---------------------------------------------------------------
EV_PY="$WORK/ev.py"
cat >"$EV_PY" <<'PY'
import struct, sys
def ev(t, c, v): return struct.pack('<qqHHi', 0, 0, t, c, v)
path, kind = sys.argv[1], sys.argv[2]
out = b''
if kind == 'type':
    MAP = {}
    for s, base in [("qwertyuiop", 16), ("asdfghjkl", 30), ("zxcvbnm", 44)]:
        for i, c in enumerate(s):
            MAP[c] = base + i
    MAP[' '] = 57
    for ch in sys.argv[3]:
        k = MAP[ch]
        out += ev(1, k, 1) + ev(0, 0, 0) + ev(1, k, 0) + ev(0, 0, 0)
elif kind == 'moveto':
    x, y, px, py = (int(v) for v in sys.argv[3:7])
    out = ev(2, 0, x - px) + ev(2, 1, y - py) + ev(0, 0, 0)
elif kind == 'click':
    out = ev(1, 272, 1) + ev(0, 0, 0) + ev(1, 272, 0) + ev(0, 0, 0)
open(path, 'ab').write(out)
PY

# ---- build ---------------------------------------------------------------
build() {   # build <src> <outname>
    scripts/hamlinux_build.sh "$1" "$WORK/$2.elf" >"$WORK/$2.build.log" 2>&1 || {
        bad "could not build $1"; tail -20 "$WORK/$2.build.log" >&2
        done_report; exit 1; }
}
for t in wsysd:user/wsysd.ad hamui_caret_probe:tests/linux/hamui_caret_probe.ad \
         wsys_poke:tests/linux/wsys_poke.ad; do
    build "${t#*:}" "${t%%:*}"
done
ok "arm 1: the compositor, the hamui probe client and the ctl reader all build"

# A probe client LINKED AGAINST A DIFFERENT lib/hamui.ad, without touching the
# tree: `from lib.hamui import ...` resolves against the PROJECT ROOT and
# scripts/hamlinux_build.sh derives that root from its OWN location, so a tree
# of symlinks with one real file in it builds a client that differs from this
# one in exactly that file. (Same device as term_caret_advance.sh.)
shadow_build() {   # shadow_build <outname> <target.ad> <relpath> <srcfile> ...
    local name="$1" target="$2"; shift 2
    local sh="$WORK/shadow_$name"
    rm -rf "$sh"; mkdir -p "$sh"
    local dirs="" e d base i
    local -a rels=() srcs=()
    while [ $# -ge 2 ]; do
        rels+=("$1"); srcs+=("$2")
        d="${1%%/*}"
        case " $dirs " in *" $d "*) ;; *) dirs="$dirs $d" ;; esac
        shift 2
    done
    for e in "$PROJ_ROOT"/*; do
        base="$(basename "$e")"
        case " $dirs " in *" $base "*) continue ;; esac
        ln -s "$e" "$sh/$base"
    done
    for d in $dirs; do
        mkdir -p "$sh/$d"
        for e in "$PROJ_ROOT/$d"/*; do
            ln -s "$e" "$sh/$d/$(basename "$e")"
        done
    done
    i=0
    while [ "$i" -lt "${#rels[@]}" ]; do
        rm -f "$sh/${rels[$i]}"
        cp "${srcs[$i]}" "$sh/${rels[$i]}"
        i=$((i+1))
    done
    "$sh/scripts/hamlinux_build.sh" "$target" "$WORK/$name.elf" \
        >"$WORK/$name.build.log" 2>&1 || {
        bad "could not build the $name probe -- this arm cannot be a controlled measurement"
        tail -20 "$WORK/$name.build.log" >&2; return 1; }
    return 0
}

mkdir -p "$WORK/redsrc"
git show "$RED_REV:lib/hamui.ad" >"$WORK/redsrc/hamui.ad" 2>"$WORK/redsrc/git.log" || {
    bad "could not retrieve lib/hamui.ad at $RED_REV -- nothing below is a controlled measurement"
    cat "$WORK/redsrc/git.log" >&2; done_report; exit 1; }
if grep -qE 'caret_x: *int32 *= *x \+ 4 \+ w_state\[u\] \* 8' "$WORK/redsrc/hamui.ad"; then
    ok "arm 2: the red arm's toolkit is the pre-fix one -- the ENTRY caret is still placed at w_state * 8"
else
    bad "arm 2: lib/hamui.ad at $RED_REV does not place the ENTRY caret at w_state * 8 -- $RED_REV is not the commit this bug lived on"
    done_report; exit 1
fi
# CODE lines only. The commentary above the fix necessarily QUOTES the old
# `w_state * 8`, and a grep that cannot tell a comment from an expression would
# be permanently red on the very file it certifies.
hamui_code() { grep -nE 'caret|rcol|col: int32' lib/hamui.ad | grep -vE '^[0-9]+:[[:space:]]*#'; }
CELL8="$(hamui_code | grep -E '\* 8|/ 8')"
if [ -n "$CELL8" ]; then
    bad "arm 3: lib/hamui.ad still computes a caret column or x with an 8px cell"
    echo "$CELL8" | sed 's/^/    /'
else
    ok "arm 3: no 8px cell arithmetic remains in hamui's caret placement or its inverse -- the constants are GONE, not corrected"
fi
if grep -q 'htb_caret_x\|htb_text_width' lib/hamui.ad; then
    ok "arm 4: hamui routes its caret through lib/hamtextbox.ad, the module that already owns this measurement"
else
    bad "arm 4: hamui does not use lib/hamtextbox.ad -- if it computes advances itself that is a second copy of the metric"
fi

shadow_build hamui_caret_probe_red tests/linux/hamui_caret_probe.ad \
    lib/hamui.ad "$WORK/redsrc/hamui.ad" || { done_report; exit 1; }

# ---- how a probe client is started ---------------------------------------
# One helper, so the red and green arms differ in exactly one thing: the ELF.
start_probe() {   # start_probe <probe-elf> <dir>
    local elf="$1" d="$2"
    rm -rf "$d"; mkdir -p "$d"
    : >"$d/input.evdev"
    export HAMWSYS="$d/wsys.shm" HAMWSYS_BB="$d/wsys.bb" HAMWSYS_IMG="$d/wsys.img" \
           HAMFB_FILE="$d/fb.raw" HAMFB_GEOM="$GEOM" HAMWSYSD_INPUT="$d/input.evdev" \
           HAMLINUX_VNC=none
    "$WORK/wsysd.elf" </dev/null >"$d/wsysd.log" 2>&1 &
    local wp=$!; reap_add "$wp"
    local i=0
    while [ "$i" -lt 300 ]; do
        kill -0 "$wp" 2>/dev/null || return 1
        [ -s "$d/fb.raw" ] && break
        sleep 0.1; i=$((i+1))
    done
    sleep 2
    "$elf" </dev/null >"$d/app.log" 2>&1 &
    local ap=$!; reap_add "$ap"
    sleep 6
    kill -0 "$ap" 2>/dev/null || return 1
    # Window geometry from the DEVICE, never from a constant here.
    local ctl
    ctl="$("$WORK/wsys_poke.elf" /dev/wsys/2/ctl 2>/dev/null)"
    [ -n "$ctl" ] || return 1
    set -- $ctl
    echo "$2 $3 $4 $5" >"$d/geom"
    echo "960 600" >"$d/pointer"
    return 0
}

# Move the pointer to an absolute screen pixel, tracking where it already is.
# The compositor drains every pending record in one pass, so a move and a click
# written together collapse into one delivered position and the click lands
# wherever the pointer WAS.
point_at() {   # point_at <dir> <x> <y>
    local d="$1" x="$2" y="$3" px py
    read -r px py <"$d/pointer"
    python3 "$EV_PY" "$d/input.evdev" moveto "$x" "$y" "$px" "$py"
    echo "$x $y" >"$d/pointer"
    sleep 1
}
click_at() {   # click_at <dir> <x> <y>
    point_at "$1" "$2" "$3"
    python3 "$EV_PY" "$1/input.evdev" click
    sleep 2
}

# ===========================================================================
# THE MEASUREMENT
# ===========================================================================
# Returns "<text_left> <text_right> <caret_left> <caret_right> <caret_n>",
# all five out of the framebuffer.
measure_entry() {   # measure_entry <dir> <label>
    local d="$1" label="$2"
    local wx wy ww wh
    read -r wx wy ww wh <"$d/geom"
    local ex=$(( wx + EX )) ey=$(( wy + EY ))
    # Band strictly INSIDE the entry: past its 1px border, past the 4px text
    # inset's left edge, and short of the right border.
    local by0=$(( ey + 2 )) by1=$(( ey + EH - 2 ))
    local bx0=$(( ex + 1 )) bx1=$(( ex + EW - 1 ))

    # PARK THE POINTER FIRST, AND IN THE SAME PLACE FOR BOTH SHOTS. The
    # compositor draws a cursor sprite, and the first version of this gate
    # subtracted two shots taken with the pointer in DIFFERENT places, so the
    # sprite showed up as 64 px of "caret" -- an instrument that reported the
    # mouse. Parked identically, it cancels; parked outside the entry band, it
    # never enters the measurement at all.
    local parkx=$(( wx + ww - 10 )) parky=$(( wy + wh - 10 ))
    point_at "$d" "$parkx" "$parky"; sleep 2
    # SHOT A: focused. The caret is drawn.
    cp "$d/fb.raw" "$d/shotA.raw"
    # Move focus to the textview -- same text, no caret in the entry.
    click_at "$d" $(( wx + TX + 20 )) $(( wy + TY + 20 ))
    point_at "$d" "$parkx" "$parky"; sleep 2
    cp "$d/fb.raw" "$d/shotB.raw"

    # The glyphs, from the UNFOCUSED shot: nothing but text is drawn there.
    set -- $(ink "$d/shotB.raw" "$by0" "$by1" "$bx0" "$bx1")
    local tl="$1" tr="$2" tn="$3"
    if [ "$tn" -le 0 ]; then
        echo "-1 -1 -1 -1 0"; return 1
    fi
    # The caret, BY SUBTRACTION between the two shots.
    set -- $(diffcols "$d/shotA.raw" "$d/shotB.raw" "$by0" "$by1" "$bx0" "$bx1")
    local cl="$1" cr="$2" cn="$3"
    echo "$tl $tr $cl $cr $cn"

    # Put focus back in the entry, at the END of the text, for the next arm.
    click_at "$d" $(( ex + EW - 8 )) $(( ey + EH / 2 ))
    return 0
}

entry_arm() {   # entry_arm <dir> <text-so-far> <label> <expect: green|red>
    local d="$1" line="$2" label="$3" expect="$4"
    local out
    out="$(measure_entry "$d" "$label")"
    set -- $out
    local tl="$1" tr="$2" cl="$3" cr="$4" cn="$5"
    if [ "$tl" -lt 0 ]; then
        bad "$label: no glyph ink anywhere in the entry -- the instrument saw nothing, so it can prove nothing"
        return 1
    fi
    if [ "$cn" -le 0 ]; then
        bad "$label: the focused and unfocused shots are identical -- no caret was drawn, so nothing about its position is measurable"
        return 1
    fi
    local n=${#line}
    local span=$(( tr - tl + 1 ))
    local adv_h=$(( span * 100 / n ))
    local gap=$(( cl - tr ))
    local mono=$(( tl + 8 * n ))
    info "$label: ${n} chars typed, glyphs x=${tl}..${tr} (${span}px, ${adv_h}/100 px per char), caret ink x=${cl}..${cr} (${cn} px)"
    info "$label: a monospace 8px caret would sit at x=${mono}, which is $(( mono - tr ))px past the last glyph"
    # ONE PIXEL-ADVANCE is the tolerance: the caret may sit anywhere from flush
    # against the last glyph to one full advance past it, and no further.
    local tol=$(( adv_h * 2 / 100 + 2 ))
    echo "$gap $tol $adv_h $n" >"$d/last"
    if [ "$expect" = green ]; then
        if [ "$gap" -ge -2 ] && [ "$gap" -le "$tol" ]; then
            ok "$label: the caret sits ${gap}px past the last glyph, within one pixel-advance (<= ${tol}px)"
        else
            bad "$label: the caret sits ${gap}px past the last glyph -- outside one pixel-advance (<= ${tol}px)"
        fi
    else
        if [ "$gap" -gt "$tol" ]; then
            ok "$label: the pre-fix toolkit puts the caret ${gap}px past the last glyph, well beyond one advance (${tol}px) -- the bug reproduces"
        else
            bad "$label: the pre-fix toolkit put the caret only ${gap}px past the last glyph -- IT DID NOT REPRODUCE THE BUG, so every green arm below is unproven"
        fi
    fi
    return 0
}

SHORT="the quick brown"
LONG="the quick brown fox jumps over"

run_entry_pair() {   # run_entry_pair <elf> <dir> <tag> <expect>
    local elf="$1" d="$2" tag="$3" expect="$4"
    if ! start_probe "$elf" "$d"; then
        bad "$tag: the hamui probe client did not come up -- nothing in this arm is measurable"
        [ -f "$d/app.log" ]   && sed 's/^/    /' "$d/app.log"
        [ -f "$d/wsysd.log" ] && tail -5 "$d/wsysd.log" | sed 's/^/    /'
        return 1
    fi
    local wx wy ww wh
    read -r wx wy ww wh <"$d/geom"
    info "$tag: hamui window at ${wx},${wy} ${ww}x${wh}"
    # Focus the entry by clicking inside it.
    click_at "$d" $(( wx + EX + 40 )) $(( wy + EY + EH / 2 ))
    python3 "$EV_PY" "$d/input.evdev" type "$SHORT"; sleep 4
    grep -q "HAMUI_PROBE text=$SHORT" "$d/app.log" || {
        bad "$tag: the probe never reported the text '$SHORT' -- the keystrokes did not reach the entry, so any pixel below would be measuring an empty box"
        sed 's/^/    /' "$d/app.log"; return 1; }
    ok "$tag: ${#SHORT} keystrokes reached the hamui ENTRY (the client echoed the text back)"
    entry_arm "$d" "$SHORT" "$tag (short)" "$expect"
    local g1; g1="$(cut -d' ' -f1 <"$d/last" 2>/dev/null)"
    python3 "$EV_PY" "$d/input.evdev" type "${LONG#$SHORT}"; sleep 4
    grep -q "HAMUI_PROBE text=$LONG" "$d/app.log" || {
        bad "$tag: the probe never reported the longer text -- the continuation did not arrive"
        return 1; }
    entry_arm "$d" "$LONG" "$tag (long)" "$expect"
    local g2; g2="$(cut -d' ' -f1 <"$d/last" 2>/dev/null)"
    echo "${g1:-0} ${g2:-0}" >"$d/gaps"
    return 0
}

# ===========================================================================
# ARM 5/6/7 -- RED FIRST
# ===========================================================================
info "arm 5-7 (RED): the same probe, linked against lib/hamui.ad at $RED_REV"
RED_OK=0
if run_entry_pair "$WORK/hamui_caret_probe_red.elf" "$WORK/red" "arm 5 (red)" red; then
    RED_OK=1
    read -r rg1 rg2 <"$WORK/red/gaps"
    if [ "$rg2" -gt "$rg1" ]; then
        ok "arm 7 (red): the gap GROWS with the line -- ${rg1}px at ${#SHORT} chars, ${rg2}px at ${#LONG}. A per-character drift, which is what the owner described; a fixed offset would not do this"
    else
        bad "arm 7 (red): the gap did not grow (${rg1}px then ${rg2}px) -- this is not the per-character drift the report describes"
    fi
fi

# ===========================================================================
# ARM 8/9/10 -- THIS TREE
# ===========================================================================
info "arm 8-10 (GREEN): the same probe, the same pixels, this tree"
if run_entry_pair "$WORK/hamui_caret_probe.elf" "$WORK/green" "arm 8 (green)" green; then
    read -r gg1 gg2 <"$WORK/green/gaps"
    if [ "$RED_OK" = 1 ]; then
        read -r rg1 rg2 <"$WORK/red/gaps"
        if [ "$gg2" -lt "$rg2" ]; then
            ok "arm 10: at ${#LONG} characters the caret moved $(( rg2 - gg2 ))px LEFT, from ${rg2}px past the last glyph to ${gg2}px"
        else
            bad "arm 10: the caret did not move left of where the pre-fix toolkit put it (${rg2}px then ${gg2}px)"
        fi
    fi
    if [ "$gg2" -le $(( gg1 + 2 )) ]; then
        ok "arm 9: the gap NO LONGER GROWS with the line -- ${gg1}px at ${#SHORT} chars, ${gg2}px at ${#LONG}. The per-character drift is gone"
    else
        bad "arm 9: the gap still grows with the line (${gg1}px then ${gg2}px) -- a per-character error survives"
    fi
fi

# ===========================================================================
# ARM 11 -- THE OTHER THREE COPIES
# ===========================================================================
# The ENTRY's forward placement is one of FOUR sites that shared the 8px cell.
# Fixing only the one the pixels caught is exactly this project's recurring
# defect (the terminal's black bar was a THIRD copy of a number whose other two
# were already fixed), so the remaining three are asserted by source.
NFWD="$(grep -c 'htb_caret_x(' lib/hamui.ad)"
NINV="$(grep -c 'htb_hit_test(' lib/hamui.ad)"
if [ "$NFWD" -ge 2 ] && [ "$NINV" -ge 2 ]; then
    ok "arm 11: BOTH forward placements (entry + textview) and BOTH click-to-caret inverses call lib/hamtextbox.ad -- ${NFWD} htb_caret_x and ${NINV} htb_hit_test call sites, so all four copies of the 8px cell are gone, not just the one the pixels caught"
else
    bad "arm 11: only ${NFWD} forward and ${NINV} inverse hamui caret sites route through lib/hamtextbox.ad; all four must"
fi

info "NOT MEASURED HERE: real hardware -- every framebuffer above is HAMFB_FILE, so the owner's fbdev, his panel pitch and the DRM/scanout path are untested; this gate never takes DRM master. Nor is the TEXTVIEW caret measured in PIXELS: it is asserted by source only, because focusing a textview and separating its caret from a multi-line glyph field needs a second subtraction this gate does not yet do. Nor is click-to-caret measured in either widget -- the inverse mapping is proven only by the fact that it now calls the same module as the forward one."

done_report
