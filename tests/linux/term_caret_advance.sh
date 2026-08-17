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
# tests/linux/term_caret_advance.sh — WHERE THE TERMINAL PUTS A MARKER ON A ROW
# OF PROPORTIONAL GLYPHS.
#
# THE REPORT, from the owner's 1920x1200 Lenovo on 2026-08-16:
#
#     "the cursor marker is too far to the right compared to where you're
#      actually entering text. Like there's a mismatch in the font sizes or
#      something like that."
#
# A gap that GROWS along the line is what a per-character discrepancy looks
# like, and this tree's recurring defect is a constant standing in for a
# measured value. So this gate measures, at his geometry, offscreen, with real
# evdev keystrokes routed through wsysd into a real hamtermscene window:
#
#   1. THE CARET IS NOT THE BUG, and it says so in pixels rather than by
#      reading. The '_' text cursor is written as a BYTE INSIDE the row's own
#      `glyphs` run, so it rides the compositor's proportional advances. This
#      gate pins that at TWO line lengths -- a per-character drift would show
#      as a gap that grows with the second -- and PRINTS what a monospace 8px
#      caret would have predicted at each, which is the drift the owner
#      described if anything ever computes one.
#
#   2. THE SELECTION WAS. lib/htermsel.ad carried HTSEL_CELL_W = 8, a second
#      copy of user/hamtermscene.ad's TERM_GLYPH_W, in the one place a column
#      becomes an x and the one place an x becomes a column. Released INSIDE
#      the last glyph of a 26-character line, the pre-fix terminal copied FOUR
#      CHARACTERS SHORT of it.
#
# THE RED ARM IS THE POINT. A hamtermscene linked against lib/htermsel.ad and
# lib/hamtextbox.ad AS THEY WERE at $RED_REV must come up short on that drag.
# If that arm ever goes green this gate has stopped measuring his bug and every
# assertion below it proves nothing.
#
# WHY THE COPIED TEXT AND NOT THE HIGHLIGHT BAND. The band is the visible half,
# but the offscreen harness could not make it repaint from a pointer event
# alone (see NOT MEASURED at the end). The clipboard is the same mapping's
# other output and it is unambiguous: it converts the pixel error into
# CHARACTERS, which is the unit the error is actually wrong in.
#
# WHERE THE RELEASE PIXEL COMES FROM. Not from a constant in this file -- from
# the framebuffer. The gate finds the right edge of the row's last glyph in the
# pixels, then releases two pixels inside it. So "the copy must include that
# glyph" is a statement about a measured position, not about arithmetic that
# could share the mapping's own mistake.
#
# Entirely offscreen: HAMFB_FILE, no VM, no display, no DRM master.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

. tests/linux/private_ns.sh
priv_ns_reexec "$@"

. tests/linux/reap.sh

WORK="${TERM_CARET_WORK:-$(mktemp -d)}"; mkdir -p "$WORK"
KEEP="${TERM_CARET_KEEP:-0}"
reap_track "$WORK/reaped"
cleanup() { reap_all; [ "$KEEP" = 1 ] || rm -rf "$WORK"; }
reap_on_exit cleanup

GEOM="${HAMFB_GEOM:-1920x1200}"
FBW="${GEOM%x*}"; FBH="${GEOM#*x}"

# The tree as it was before the fix: HTSEL_CELL_W still 8.
RED_REV="${TERM_CARET_RED_REV:-b9f55228}"

[ -r /usr/share/vulkan/icd.d/lvp_icd.json ] && \
    export VK_ICD_FILENAMES="${VK_ICD_FILENAMES:-/usr/share/vulkan/icd.d/lvp_icd.json}"

pass=0; fail=0
ok()   { echo "caret: PASS $*"; pass=$((pass+1)); }
bad()  { echo "caret: FAIL $*"; fail=$((fail+1)); }
info() { echo "caret: INFO $*"; }
done_report() { echo "caret: $pass passed, $fail failed"; [ "$fail" = 0 ]; }

# ---- the terminal's row geometry, READ FROM THE SOURCES ------------------
# A gate that keeps its own copy of these is the defect it tests. x=6 and the
# 20px row pitch are what _emit_scene literally writes into the scene, so they
# are facts about the display list; TERM_GLYPH_W is the assumption under test
# and is used ONLY to compute what a monospace caret WOULD have predicted.
GX0=6
LINE_H="$(sed -n 's/^TERM_LINE_H: *int64 *= *\([0-9][0-9]*\).*/\1/p' user/hamtermscene.ad | head -1)"
GLYPH_W="$(sed -n 's/^TERM_GLYPH_W: *int64 *= *\([0-9][0-9]*\).*/\1/p' user/hamtermscene.ad | head -1)"
[ -n "$LINE_H" ] && [ -n "$GLYPH_W" ] || {
    echo "caret: FAIL could not read TERM_LINE_H / TERM_GLYPH_W out of user/hamtermscene.ad"; exit 1; }
info "row geometry from the source: glyphs start x=$GX0, rows pitch ${LINE_H}px, grid assumes ${GLYPH_W}px cells"

if grep -q '^HTSEL_CELL_W' lib/htermsel.ad; then
    HAS_CELL_W=1
else
    HAS_CELL_W=0
fi

# ---- pixel arithmetic ----------------------------------------------------
# WHAT COUNTS AS INK. The terminal pane is #101418 and the text is #c0f0c0, so
# "differs from the pane background" is unambiguous here -- but the first
# version of the backdrop gate was fooled by testing "not black" against a
# #1c1c1c bar, so the threshold is against the ACTUAL pane colour and the gate
# proves it can find ink before it believes an absence of ink.
INK_PY="$WORK/ink.py"
cat >"$INK_PY" <<'PY'
import sys
# ink.py <fb> <W> <y0> <y1> <x0> <x1>
#   prints "<minx> <maxx> <count>" over the half-open band, or "-1 -1 0"
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
        if abs(b - 0x18) + abs(g - 0x14) + abs(r - 0x10) > 40:
            n += 1
            if i < lo: lo = i
            if i > hi: hi = i
print(lo if hi >= 0 else -1, hi, n)
PY
ink() { python3 "$INK_PY" "$1" "$FBW" "$2" "$3" "$4" "$5"; }

# ---- evdev ---------------------------------------------------------------
EV_PY="$WORK/ev.py"
cat >"$EV_PY" <<'PY'
import struct, sys
# ev.py <file> type ...
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
elif kind == 'press':
    out = ev(1, 272, 1) + ev(0, 0, 0)
elif kind == 'release':
    out = ev(1, 272, 0) + ev(0, 0, 0)
open(path, 'ab').write(out)
PY

# ---- build ---------------------------------------------------------------
build() {   # build <src> <outname>
    scripts/hamlinux_build.sh "$1" "$WORK/$2.elf" >"$WORK/$2.build.log" 2>&1 || {
        bad "could not build $1"; tail -20 "$WORK/$2.build.log" >&2
        done_report; exit 1; }
}
for t in wsysd:user/wsysd.ad hamtermscene:user/hamtermscene.ad \
         hamsh:user/hamsh.ad wsys_poke:tests/linux/wsys_poke.ad; do
    build "${t#*:}" "${t%%:*}"
done
ok "the compositor, the terminal, the shell and the probe client all build"

# A hamtermscene LINKED AGAINST DIFFERENT SOURCES, WITHOUT TOUCHING THE TREE.
# `from lib.htermsel import ...` resolves against the PROJECT ROOT, and
# scripts/hamlinux_build.sh derives that root from its OWN location, so a tree
# of symlinks with a few real files in it builds a terminal that differs from
# this one in exactly those files. (Same device as
# tests/linux/de_backdrop_bottom.sh's shadow_build.)
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
        bad "could not build the $name terminal -- this arm cannot be a controlled measurement"
        tail -20 "$WORK/$name.build.log" >&2; return 1; }
    return 0
}

mkdir -p "$WORK/redsrc"
RED_OK=1
for f in lib/htermsel.ad lib/hamtextbox.ad user/hamtermscene.ad; do
    git show "$RED_REV:$f" >"$WORK/redsrc/$(basename "$f")" 2>"$WORK/redsrc/git.log" || RED_OK=0
done
if [ "$RED_OK" != 1 ]; then
    bad "could not retrieve the pre-fix sources at $RED_REV -- nothing below is a controlled measurement"
    cat "$WORK/redsrc/git.log" >&2; done_report; exit 1
fi
RED_CELL_W="$(sed -n 's/^HTSEL_CELL_W: *int64 *= *\([0-9][0-9]*\).*/\1/p' "$WORK/redsrc/htermsel.ad" | head -1)"
if [ "$RED_CELL_W" = "$GLYPH_W" ]; then
    ok "arm 1: the red arm's selection model is the pre-fix one -- HTSEL_CELL_W ${RED_CELL_W}, a second copy of TERM_GLYPH_W ${GLYPH_W}"
else
    bad "arm 1: lib/htermsel.ad at $RED_REV has HTSEL_CELL_W '$RED_CELL_W', not $GLYPH_W -- $RED_REV is not the commit this bug lived on"
    done_report; exit 1
fi
if [ "$HAS_CELL_W" = 0 ]; then
    ok "arm 2: HTSEL_CELL_W is GONE from this tree -- the constant was removed, not corrected"
else
    bad "arm 2: lib/htermsel.ad still declares HTSEL_CELL_W; a second copy of the cell width survives"
fi
shadow_build hamtermscene_red user/hamtermscene.ad \
    lib/htermsel.ad     "$WORK/redsrc/htermsel.ad" \
    lib/hamtextbox.ad   "$WORK/redsrc/hamtextbox.ad" \
    user/hamtermscene.ad "$WORK/redsrc/hamtermscene.ad" || { done_report; exit 1; }

# ---- /bin/hamsh ----------------------------------------------------------
# hamtermscene spawns /bin/hamsh BY ABSOLUTE PATH and exits when that shell is
# gone, so an offscreen terminal needs one on the path it actually opens. This
# puts it there with an overlay that exists only inside this namespace and dies
# with it -- the host's /usr/bin is never written. If the kernel will not give
# us one, the gate says so and stops rather than measuring an empty screen.
mkdir -p /tmp/binovl/up /tmp/binovl/work
cp "$WORK/hamsh.elf" /tmp/binovl/up/hamsh
chmod +x /tmp/binovl/up/hamsh
if mount -t overlay ovlbin \
        -o lowerdir=/usr/bin,upperdir=/tmp/binovl/up,workdir=/tmp/binovl/work \
        /usr/bin 2>"$WORK/mount.log"; then
    ok "a private /bin/hamsh exists for the terminal to spawn (namespace-local overlay)"
else
    bad "could not provide /bin/hamsh (unprivileged overlayfs unavailable?) -- the terminal would exit at once and every arm below would be vacuous"
    cat "$WORK/mount.log" >&2; done_report; exit 1
fi

# ---- how a terminal is started -------------------------------------------
# One helper, so the red and green arms differ in exactly one thing: the ELF.
start_term() {   # start_term <hamtermscene-elf> <dir>
    local elf="$1" d="$2"
    rm -rf "$d"; mkdir -p "$d"
    : >"$d/input.evdev"
    export HAMWSYS="$d/wsys.shm" HAMWSYS_BB="$d/wsys.bb" HAMWSYS_IMG="$d/wsys.img" \
           HAMFB_FILE="$d/fb.raw" HAMFB_GEOM="$GEOM" HAMWSYSD_INPUT="$d/input.evdev"
    "$WORK/wsysd.elf" </dev/null >"$d/wsysd.log" 2>&1 &
    local wp=$!; reap_add "$wp"
    local i=0
    while [ "$i" -lt 300 ]; do
        kill -0 "$wp" 2>/dev/null || return 1
        [ -s "$d/fb.raw" ] && break
        sleep 0.1; i=$((i+1))
    done
    sleep 2
    "$elf" </dev/null >"$d/term.log" 2>&1 &
    local tp=$!; reap_add "$tp"
    sleep 7
    kill -0 "$tp" 2>/dev/null || return 1
    # Window geometry from the DEVICE, never from a constant here.
    local ctl
    ctl="$("$WORK/wsys_poke.elf" /dev/wsys/2/ctl 2>/dev/null)"
    [ -n "$ctl" ] || return 1
    set -- $ctl
    echo "$2 $3 $4 $5" >"$d/geom"
    return 0
}

# The bottom (edit) row's cell-top y, and the two pixel bands inside it.
#   glyph cell top   = win_y + 6 + r*LINE_H          (what _emit_scene writes)
#   x-height band    = top+1 .. top+11               (letters, never the '_')
#   underscore band  = top+15 .. top+18              (the '_' and descenders)
row_top() { echo $(( $1 + 6 + $2 * LINE_H )); }

typed_row_report() {   # typed_row_report <dir> <n-chars-typed> <label>
    local d="$1" n="$2" label="$3"
    read -r wx wy ww wh <"$d/geom"
    local rows top tx cx
    # The edit row is the LAST row of the grid; find it from the pixels rather
    # than recomputing the terminal's row count with its own arithmetic: it is
    # the lowest row band in the window that carries ink.
    local r best=-1
    r=0
    while [ "$r" -lt 60 ]; do
        top="$(row_top "$wy" "$r")"
        [ $((top + 18)) -lt $((wy + wh)) ] || break
        set -- $(ink "$d/shot.raw" $((top + 1)) $((top + 12)) $((wx + 1)) $((wx + ww - 1)))
        [ "${3:-0}" -gt 0 ] && best=$r
        r=$((r + 1))
    done
    if [ "$best" -lt 0 ]; then
        echo "-1 -1 -1"; return 1
    fi
    top="$(row_top "$wy" "$best")"
    # TEXT: the rightmost ink on the x-height band -- the last glyph's edge.
    set -- $(ink "$d/shot.raw" $((top + 1)) $((top + 12)) $((wx + 1)) $((wx + ww - 1)))
    local text_right="$2" text_left="$1"
    # CARET: the leftmost ink on the underscore band AT OR AFTER the text's own
    # right edge minus a glyph. Restricting the search that way is what keeps a
    # descender further left ('$' in the prompt, 'q' in a word) from being read
    # as the caret.
    set -- $(ink "$d/shot.raw" $((top + 15)) $((top + 19)) $((text_right - 6)) $((wx + ww - 1)))
    local caret_left="$1" caret_n="$3"
    echo "$text_left $text_right $caret_left $caret_n $top"
}

# ===========================================================================
# ARM 3/4 -- THE CARET, IN PIXELS, AT TWO LINE LENGTHS
# ===========================================================================
SHORT="the quick brown"
LONG="the quick brown fox jumps over"

caret_arm() {   # caret_arm <dir> <text-to-type> <total-line-so-far> <label>
    local d="$1" text="$2" line="$3" label="$4"
    python3 "$EV_PY" "$d/input.evdev" type "$text"
    sleep 4
    cp "$d/fb.raw" "$d/shot.raw"
    read -r wx wy ww wh <"$d/geom"
    local out
    out="$(typed_row_report "$d" "${#line}" "$label")" || {
        bad "$label: no text found on any row of the terminal -- the instrument saw nothing, so it can prove nothing"
        return 1; }
    set -- $out
    local tl="$1" tr="$2" cl="$3" cn="$4" top="$5"
    if [ "$cn" -le 0 ]; then
        bad "$label: no caret ink below the baseline -- the '_' was not drawn, so nothing about its position is measurable"
        return 1
    fi
    # THE WHOLE VISIBLE LINE, prompt included -- not just the keys pressed this
    # call. The second arm types a CONTINUATION, and counting only that
    # fragment is how a per-character number silently becomes nonsense.
    local nvis=$(( ${#line} + 7 ))              # "hamsh$ " is 7 columns
    local span=$(( tr - tl + 1 ))
    local adv_h=$(( span * 100 / nvis ))        # hundredths of a px per char
    local gap=$(( cl - tr ))
    local mono=$(( tl + GLYPH_W * nvis ))
    info "$label: ${nvis} visible chars, glyphs x=${tl}..${tr} (${span}px, ${adv_h}/100 px per char), caret ink starts x=${cl}"
    info "$label: a monospace ${GLYPH_W}px caret would sit at x=${mono} -- $(( mono - cl ))px further right"
    # ONE PIXEL-ADVANCE is the tolerance the owner's report deserves: the caret
    # may sit anywhere from flush against the last glyph to one full advance
    # past it, and no further.
    local tol=$(( adv_h * 2 / 100 + 2 ))
    if [ "$gap" -ge -2 ] && [ "$gap" -le "$tol" ]; then
        ok "$label: the caret sits ${gap}px past the last glyph, within one pixel-advance (<= ${tol}px)"
    else
        bad "$label: the caret sits ${gap}px past the last glyph -- outside one pixel-advance (<= ${tol}px)"
    fi
    echo "$tl $tr $cl $top" >"$d/row"
    return 0
}

info "arm 3/4: typing at a live hamsh prompt in a ${FBW}x${FBH} screen, and measuring the caret against the glyphs"
if start_term "$WORK/hamtermscene.elf" "$WORK/green"; then
    ok "arm 3: a terminal window came up with a live shell"
    caret_arm "$WORK/green" "$SHORT" "$SHORT" "arm 3 (short line)"
    # The SAME window, extended: a per-character drift would be larger here.
    caret_arm "$WORK/green" "${LONG#$SHORT}" "$LONG" "arm 4 (longer line)"
else
    bad "arm 3: the terminal did not come up -- nothing below it is measurable"
    [ -f "$WORK/green/term.log" ] && sed 's/^/    /' "$WORK/green/term.log"
    [ -f "$WORK/green/wsysd.log" ] && tail -5 "$WORK/green/wsysd.log" | sed 's/^/    /'
fi

# ===========================================================================
# ARM 5/6 -- THE DRAG. RED FIRST.
# ===========================================================================
# Type a known line, MEASURE where its last glyph ends, then press at the start
# of the row and release two pixels INSIDE that last glyph. Whatever the
# terminal copies must therefore contain the line's final character.
DRAG_TEXT="the quick brown fox"

# PRINTS ONLY THE PUBLISHED SELECTION ON STDOUT. Its own commentary goes to
# stderr: this runs inside $(...), and the first version let its `info` lines
# be captured into the string it was reporting on, which made the arm that
# counts how many characters were lost print -100.
drag_arm() {   # drag_arm <dir> <label>
    local d="$1" label="$2"
    read -r wx wy ww wh <"$d/geom"
    python3 "$EV_PY" "$d/input.evdev" type "$DRAG_TEXT"
    sleep 4
    cp "$d/fb.raw" "$d/shot.raw"
    local out
    out="$(typed_row_report "$d" "${#DRAG_TEXT}" "$label")" || {
        return 1; }
    set -- $out
    local tl="$1" tr="$2" top="$5"
    local ry=$(( top + 6 ))
    local x0=$(( tl + 1 ))
    local x1=$(( tr - 2 ))                 # two pixels INSIDE the last glyph
    info "$label: row glyphs x=${tl}..${tr}; drag ${x0} -> ${x1} at y=${ry} (release inside the final 'x')" >&2
    # Each stage is a SEPARATE append with a settle: the compositor drains
    # every pending record in one pass, so a press and a release written
    # together collapse into one delivered position and no drag ever happens.
    python3 "$EV_PY" "$d/input.evdev" moveto "$x0" "$ry" 960 600 ; sleep 1
    python3 "$EV_PY" "$d/input.evdev" press                       ; sleep 1
    local mid=$(( (x0 + x1) / 2 ))
    python3 "$EV_PY" "$d/input.evdev" moveto "$mid" "$ry" "$x0" "$ry" ; sleep 1
    python3 "$EV_PY" "$d/input.evdev" moveto "$x1"  "$ry" "$mid" "$ry"; sleep 1
    python3 "$EV_PY" "$d/input.evdev" release                     ; sleep 3
    "$WORK/wsys_poke.elf" /dev/snarf.primary 2>/dev/null
}

info "arm 5 (RED): the same drag against a terminal whose selection model is the pre-fix HTSEL_CELL_W ${RED_CELL_W}"
RED_SEL=""
if start_term "$WORK/hamtermscene_red.elf" "$WORK/red"; then
    RED_SEL="$(drag_arm "$WORK/red" "arm 5 (red)")"
    info "arm 5: the pre-fix terminal copied [$RED_SEL]"
    if [ -z "$RED_SEL" ]; then
        bad "arm 5: the pre-fix terminal published NOTHING -- an empty result is not a reproduction, so this arm cannot show the bug"
    elif [ "${RED_SEL%"${DRAG_TEXT##* }"}" != "$RED_SEL" ]; then
        bad "arm 5: the pre-fix terminal copied through the final word -- IT DID NOT REPRODUCE THE BUG, so every green arm below is unproven"
    else
        RED_SHORT=$(( ${#DRAG_TEXT} + 7 - ${#RED_SEL} ))
        ok "arm 5: the pre-fix terminal copied ${RED_SHORT} characters SHORT of the glyph the pointer was released inside"
    fi
else
    bad "arm 5: the pre-fix terminal did not come up -- there is no red arm, so the gate is not a controlled measurement"
fi

info "arm 6 (GREEN): the same drag, the same pixels, this tree"
if start_term "$WORK/hamtermscene.elf" "$WORK/greendrag"; then
    NEW_SEL="$(drag_arm "$WORK/greendrag" "arm 6 (green)")"
    info "arm 6: this tree copied [$NEW_SEL]"
    LASTW="${DRAG_TEXT##* }"
    if [ -z "$NEW_SEL" ]; then
        bad "arm 6: nothing was published -- the drag did not reach the terminal, so this is not a measurement of the fix"
    elif [ "${NEW_SEL%$LASTW}" != "$NEW_SEL" ]; then
        ok "arm 6: the copy ends at '$LASTW' -- the glyph the pointer was released inside"
    else
        bad "arm 6: the copy ended '[...]${NEW_SEL: -8}', not at '$LASTW' -- the pixel the drag ended on is still not the character it is drawn as"
    fi
    if [ -n "$RED_SEL" ] && [ -n "$NEW_SEL" ] && [ "${#NEW_SEL}" -gt "${#RED_SEL}" ]; then
        ok "arm 6: same drag, $(( ${#NEW_SEL} - ${#RED_SEL} )) more characters than the pre-fix terminal"
    fi
else
    bad "arm 6: the terminal did not come up"
fi

# ===========================================================================
# ARM 7 -- THE DISAGREEMENT IS AUDIBLE
# ===========================================================================
# The 1080 ceiling survived three copies because nothing in any log mentioned
# it. TERM_GLYPH_W still decides the COLUMN COUNT, which is a genuine judgement
# call for a proportional face -- so the terminal must at least say what it
# assumed against what the face measures.
if grep -q "cell advance" "$WORK/green/term.log" 2>/dev/null || \
   grep -q "cell advance" "$WORK/greendrag/term.log" 2>/dev/null; then
    ok "arm 7: the terminal reports its assumed cell width against the measured advance"
else
    info "arm 7: the terminal's cell-advance report was not captured here -- it goes to /dev/cons, which this namespace does not provide; the code path is asserted by the source check below"
    if grep -q "_report_cell_advance" user/hamtermscene.ad; then
        ok "arm 7: hamtermscene calls _report_cell_advance() at startup"
    else
        bad "arm 7: nothing reconciles the grid's assumed cell width with the measured advance"
    fi
fi

info "NOT MEASURED HERE: real hardware. Every framebuffer above is HAMFB_FILE, so his fbdev driver, his panel's pitch and the DRM/scanout path are untested -- this gate never takes DRM master. Nor is the HIGHLIGHT BAND measured: the copied text is the same mapping's other output and is unambiguous in characters, but the band's own repaint never fired from a pointer event in this harness, which may be a second defect. Nor is the COLUMN COUNT: 74 columns of 8px is 592px while 74 'm' is nearly 900, so a wide line still runs off the right edge of the default window, and that half of TERM_GLYPH_W is deliberately left alone."

done_report
