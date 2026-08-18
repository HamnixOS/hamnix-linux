#!/usr/bin/env bash
# hamslides_click_roundtrip.sh — CLICK WHERE CHARACTER N WAS DRAWN, GET N BACK.
#
# WHAT THIS GATE IS FOR
# =====================
# tests/linux/hamui_widget_advance.sh proved that a widget's BOX is as wide as
# its MEASURED text. That is the forward direction only. The property a person
# actually experiences in an editor is the ROUND TRIP:
#
#     click at the pixel where character N was drawn  ->  caret lands on N
#
# and it is the one an "average pixel width" fix silently destroys. It is also
# why lib/hamslidescore.ad was deliberately LEFT at 8 px/char when the eleven
# hamUI sizing sites were fixed: this file has an INVERSE as well as a forward
# half. _center_x() and _draw_edit_caret() turn a character index into a pixel;
# _place_caret_from_x() turns a click's pixel back into an index. Two
# wrong-but-agreeing halves at least round-trip with each other, so fixing only
# the forward half makes CLICKING WORSE than leaving both wrong. (That exact
# regression already happened once in this tree, with the caret.)
#
# THE ASSERTION USES NO PIXEL CONSTANT OF ITS OWN
# ===============================================
# The anchor is htb_text_width() -- the same per-glyph advances the compositor
# pens out. Character N's drawn left edge is TEXTX + htb_text_width(buf, N).
# The driver clicks EXACTLY there, through the app's real public entry point
# hamslides_hit(), and reports the caret index the app landed on. If the face
# changes tomorrow every expected pixel moves with it and this gate still
# asserts the same thing.
#
# Two fields are driven, because they fail differently:
#   TITLE.content  -- box left edge is layout-derived and text-independent, so
#                     this arm isolates the caret/hit-test pair.
#   TITLE.centred  -- LAY_TITLE, where _center_x() derives the left edge FROM
#                     THE TEXT. This arm covers the centring site AND its
#                     inverse at once: if the two disagree by even the centring
#                     offset, every index in it is wrong.
#
# THE FORWARD HALF IS READ OFF THE PAINTED SCENE, NOT OFF AN ACCESSOR
# ===================================================================
# The driver also parks the caret at an index by KEY navigation (Home, then N
# Right arrows -- no pixel math involved in getting it there), repaints, and
# dumps the real display list. This gate finds the caret's actual drawn
# vertical line in that list and asserts it stands at the measured pen
# position. It also asserts the app's reported TEXTX equals the x the glyphs
# run was really drawn at, so the accessor the round trip is aimed with is not
# a second copy that could drift from the paint pass.
#
# THE PROBE STRING IS DELIBERATELY LUMPY
# ======================================
# The face spreads 3 to 12 px per glyph; the "6.78-6.95 px" figure quoted in
# older documents here is an AVERAGE and it misleads. The probe interleaves the
# narrowest and widest glyphs ("iWlM" x3), and this gate asserts that spread is
# real -- at least one probe glyph narrower than 8 px and at least one wider --
# before it believes any width. A gate driven with average-width text would
# pass against an average-width bug.
#
# THE INSTRUMENT IS PROVEN BEFORE IT IS BELIEVED
# ==============================================
# htb_text_width() FALLS BACK to 8 px/char when the TTF is not loaded, and on
# that fallback a gate testing an 8 px bug AGREES with it and goes green on a
# broken tree. So FONT_READY 1 is asserted first and this gate refuses to read
# a single width otherwise.
#
# THE NEGATIVE CONTROL IS RUN, NOT DESCRIBED
# ==========================================
# The second arm calls hamslides_force_8px_advance(1), which puts every metric
# helper in lib/hamslidescore.ad back on 8 px/char -- forward AND inverse
# together, which is the tree exactly as it stood before this change. The round
# trip must BREAK there, and this gate names the character the click lands on
# instead. If the control does not go red, the gate cannot fail and is
# worthless, and this script says so and fails.
#
# WHAT IT DOES NOT ASSERT
# =======================
#  * That the glyph INK fits the box. This is pen-advance arithmetic, not
#    rasterised extents.
#  * BOLD text. hamscene_glyphs_bold double-strikes at +1 px; the advance is
#    unchanged, so the measurement is the same, but that is reasoning, not a
#    measurement made here.
#  * Anything about the NATIVE target. This is the x86_64-linux host twin.
#  * The NOTES strip and the BULLET rows. They use the same three helpers the
#    title does, so they are covered by construction, not by assertion.
#
# No device is touched: it compiles one host binary and runs it twice.
set -uo pipefail
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ" || exit 1

pass=0; fail=0
ok()   { printf 'srt: PASS %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf 'srt: FAIL %s\n' "$*"; fail=$((fail+1)); }
note() { printf 'srt: .... %s\n' "$*"; }
done_() { printf 'srt: %d PASSED / %d FAILED\n' "$pass" "$fail"; }

OUT="${HAMLINUX_OUT:-$(mktemp -d /tmp/srt.XXXXXX)}"
mkdir -p "$OUT"
BIN="$OUT/hamslides_roundtrip_host"

note "project $PROJ"
note "out     $OUT"

PROBE='iWlMiWlMiWlM'

# ------------------------------------------------------------- arm 0: build
if python3 -m compiler.adder compile --target=x86_64-linux \
        user/hamslides_roundtrip_host.ad -o "$BIN" > "$OUT/compile.log" 2>&1; then
    ok "round-trip host driver compiles for x86_64-linux"
else
    bad "round-trip host driver FAILED to compile -- see $OUT/compile.log"
    tail -20 "$OUT/compile.log"
    done_; exit 1
fi

if [ -s "$BIN" ]; then
    ok "driver binary is non-empty ($(stat -c %s "$BIN") bytes)"
else
    bad "driver binary is empty"
    done_; exit 1
fi

"$BIN" "$OUT/measured.ppm" > "$OUT/measured.txt" 2> "$OUT/measured.err"
rc=$?
if [ "$rc" -eq 0 ]; then
    ok "GREEN arm exits 0"
else
    bad "GREEN arm exited $rc (expected 0); stderr: $(head -3 "$OUT/measured.err")"
fi

G="$OUT/measured.txt"

if grep -qx 'PPM_OK' "$G"; then
    ok "GREEN arm wrote a PPM"
else
    bad "GREEN arm did not report PPM_OK -- no pixels came out of this lane"
fi
if [ -s "$OUT/measured.ppm" ] && head -c 2 "$OUT/measured.ppm" | grep -q 'P6'; then
    ok "PPM is a P6 image of $(head -c 15 "$OUT/measured.ppm" | tr '\n' ' ')"
else
    bad "PPM missing or not P6"
fi

# ------------------------------------------- arm 0: prove the instrument first
ready=$(awk '/^FONT_READY /{print $2}' "$G")
if [ "${ready:-0}" = "1" ]; then
    ok "proportional face is LOADED (FONT_READY 1) -- widths are measurements"
else
    bad "FONT_READY=${ready:-<none>} -- htb_text_width() is on its 8 px/char FALLBACK, so every number below would agree with the bug this gate exists to catch. Refusing to read them."
    done_; exit 1
fi

if grep -qx 'MODE measured' "$G"; then
    ok "GREEN arm really ran in measured mode"
else
    bad "GREEN arm did not report MODE measured"
    done_; exit 1
fi

# The spread must be REAL and must straddle 8, or no single constant could be
# blamed and no average could be refuted.
amin=$(awk '/^ADV /{print $3}' "$G" | sort -n | head -1)
amax=$(awk '/^ADV /{print $3}' "$G" | sort -n | tail -1)
if [ -n "${amin:-}" ] && [ -n "${amax:-}" ] && [ "$amin" -lt 8 ] && [ "$amax" -gt 8 ]; then
    ok "probe glyph advances STRADDLE 8 px: narrowest ${amin}px, widest ${amax}px -- no single constant can be right and no average can fake this"
else
    bad "probe glyph advances do not straddle 8 px (min=${amin:-?} max=${amax:-?}); the instrument cannot distinguish a proportional face from the constant it is testing"
    done_; exit 1
fi

plen=$(awk '/^PROBELEN /{print $2}' "$G")
ppx=$(awk '/^PROBELEN /{print $3}' "$G")
if [ -n "${plen:-}" ] && [ -n "${ppx:-}" ] && [ "$ppx" -ne $((plen * 8)) ]; then
    ok "probe measures ${ppx}px over ${plen} bytes, which is NOT ${plen} x 8 = $((plen * 8)) -- the two answers are distinguishable"
else
    bad "probe measures ${ppx:-?}px over ${plen:-?} bytes, which equals ${plen:-?} x 8; the measured and the buggy answer are identical here and nothing below could fail"
    done_; exit 1
fi

FIELDS="TITLE.content TITLE.centred"

# nth character of the probe, 0-based, for naming what a click landed on.
charat() {
    local n="$1"
    if [ "$n" -ge "${#PROBE}" ]; then printf 'end-of-text'; else
        printf "'%s'" "${PROBE:$n:1}"
    fi
}

# ------------------------------- arm 1: THE ROUND TRIP, index by index, GREEN
for f in $FIELDS; do
    n=$(awk -v f="$f" '$1=="FIELD" && $2==f{print $6}' "$G")
    tx=$(awk -v f="$f" '$1=="FIELD" && $2==f{print $4}' "$G")
    if [ -z "${n:-}" ]; then
        bad "$f: no FIELD record -- the driver never exercised this field"
        continue
    fi
    ok "$f: field reported, text begins at x=$tx, $n bytes long"
    nrec=$(awk -v f="$f" '$1=="RT" && $2==f' "$G" | wc -l)
    if [ "$nrec" -eq $((n + 1)) ]; then
        ok "$f: driver round-tripped all $nrec caret indices (0..$n)"
    else
        bad "$f: driver reported $nrec round trips for a $n-byte field, expected $((n + 1)) -- an incomplete sweep is not a finding"
        continue
    fi
    while read -r idx clickx got; do
        if [ "$got" = "$idx" ]; then
            ok "$f: click at the drawn left edge of character $idx (x=$clickx) lands the caret on $idx"
        else
            bad "$f: click at the drawn left edge of character $idx (x=$clickx, the glyph $(charat "$idx")) landed the caret on $got (character $(charat "$got")) -- off by $((got - idx))"
        fi
    done < <(awk -v f="$f" '$1=="RT" && $2==f{print $3, $4, $5}' "$G")
done

# --------------------- arm 1: THE FORWARD HALF, off the PAINTED display list
# The caret's drawn x is the ONLY vertical line in the LAY_TITLE scene. This
# gate asserts there is exactly one, because picking the wrong line silently
# would be a gate reading its own assumption back.
while read -r tag idx want; do
    blk="$OUT/scene.$tag.$idx"
    awk -v t="$tag" -v i="$idx" '
        $1=="SCENE-BEGIN" && $2==t && $3==i {on=1; next}
        $1=="SCENE-END" {on=0}
        on' "$G" > "$blk"
    if [ ! -s "$blk" ]; then
        bad "caret $tag/$idx: the scene dump for this repaint is EMPTY -- no display list came out, so nothing below it could mean anything"
        continue
    fi
    nvert=$(awk '$1=="line" && $2==$4' "$blk" | wc -l)
    if [ "$nvert" -eq 1 ]; then
        ok "caret $tag/$idx: exactly one vertical line in the painted scene, so the caret is unambiguous"
    else
        bad "caret $tag/$idx: found $nvert vertical lines in the painted scene, not 1 -- this gate cannot tell which one is the caret and refuses to guess"
        continue
    fi
    drawn=$(awk '$1=="line" && $2==$4{print $2}' "$blk")
    if [ "$drawn" -eq "$want" ]; then
        ok "caret $tag/$idx is DRAWN at x=$drawn, the measured pen position after $idx characters"
    else
        bad "caret $tag/$idx is DRAWN at x=$drawn but the measured pen position after $idx characters is x=$want -- off by $((drawn - want))"
    fi
    # The accessor the clicks were aimed with must agree with the paint pass.
    tx=$(awk -v f="$tag" '$1=="FIELD" && $2==f{print $4}' "$G")
    gx=$(awk -v p="\"$PROBE\"" '$1=="glyphs" && $4==p{print $2}' "$blk" | head -1)
    if [ -n "${gx:-}" ] && [ "$gx" = "$tx" ]; then
        ok "caret $tag/$idx: the glyphs run was really drawn at x=$gx, matching the TEXTX=$tx the clicks were aimed with"
    else
        bad "caret $tag/$idx: the glyphs run was drawn at x=${gx:-<not found>} but the clicks were aimed with TEXTX=$tx -- the accessor is a second copy of the placement and it has drifted"
    fi
done < <(awk '/^CARETPX /{print $2, $3, $4}' "$G")

# =========================================================================
#                    THE NEGATIVE CONTROL, RUN
# =========================================================================
note "negative control: re-running with 8 px/char forced back on, FORWARD AND"
note "INVERSE TOGETHER -- the tree exactly as it stood"
"$BIN" "$OUT/force8.ppm" force8 > "$OUT/force8.txt" 2> "$OUT/force8.err"
rc8=$?
R="$OUT/force8.txt"
if [ "$rc8" -eq 0 ]; then
    ok "RED arm exits 0 (it renders; it is the arithmetic that is wrong)"
else
    bad "RED arm exited $rc8"
fi
if grep -qx 'MODE force8' "$R"; then
    ok "RED arm really ran in force8 mode"
else
    bad "RED arm did not report MODE force8 -- the control did not arm, so nothing below it would mean anything. (This exact mistake happened here once already: a wrapper dropped the shim argument and nine controls passed against a binary that had never been shimmed.)"
    done_; exit 1
fi
if [ "$(awk '/^FONT_READY /{print $2}' "$R")" = "1" ]; then
    ok "RED arm still has the face loaded, so its reference widths are measurements too"
else
    bad "RED arm reports FONT_READY 0 -- the control is not the defect, it is a missing font"
    done_; exit 1
fi

broke_total=0
for f in $FIELDS; do
    nbad=0; names=""
    while read -r idx clickx got; do
        if [ "$got" != "$idx" ]; then
            nbad=$((nbad + 1))
            names="$names $idx->$got"
        fi
    done < <(awk -v f="$f" '$1=="RT" && $2==f{print $3, $4, $5}' "$R")
    broke_total=$((broke_total + nbad))
    if [ "$nbad" -gt 0 ]; then
        ok "negative control RED for $f: with 8 px/char forced on, $nbad of the clicks land on the wrong character --$names"
    else
        bad "NEGATIVE CONTROL DID NOT GO RED for $f: every click still round-tripped with 8 px/char forced back on. This gate cannot fail and is therefore worthless."
    fi
done

if [ "$broke_total" -ge 8 ]; then
    ok "negative control breaks $broke_total clicks overall -- the defect this gate covers is large, not marginal"
else
    bad "negative control breaks only $broke_total clicks overall; that is too few to be sure the probe string exercises the defect"
fi

# The CENTRING site must also move: under 8 px/char the centred title starts at
# a different x than the measured one, which is the _center_x half of the pair.
gtx=$(awk '$1=="FIELD" && $2=="TITLE.centred"{print $4}' "$G")
rtx=$(awk '$1=="FIELD" && $2=="TITLE.centred"{print $4}' "$R")
if [ -n "${gtx:-}" ] && [ -n "${rtx:-}" ] && [ "$gtx" -ne "$rtx" ]; then
    ok "negative control moves the CENTRED title's left edge: measured x=$gtx, 8 px/char x=$rtx -- the centring site is really under test"
else
    bad "the centred title starts at the same x in both arms (${gtx:-?} vs ${rtx:-?}), so _center_x is NOT being exercised by this probe and its half of the pair is ungated"
fi

# And the RED arm's caret must be drawn somewhere other than the measured pen.
rmis=0
while read -r tag idx want; do
    blk="$OUT/r.scene.$tag.$idx"
    awk -v t="$tag" -v i="$idx" '
        $1=="SCENE-BEGIN" && $2==t && $3==i {on=1; next}
        $1=="SCENE-END" {on=0}
        on' "$R" > "$blk"
    drawn=$(awk '$1=="line" && $2==$4{print $2}' "$blk" | head -1)
    gwant=$(awk -v t="$tag" -v i="$idx" '$1=="CARETPX" && $2==t && $3==i{print $4}' "$G")
    if [ -n "${drawn:-}" ] && [ -n "${gwant:-}" ] && [ "$drawn" -ne "$gwant" ]; then
        rmis=$((rmis + 1))
    fi
done < <(awk '/^CARETPX /{print $2, $3, $4}' "$R")
if [ "$rmis" -ge 1 ]; then
    ok "negative control also misdraws the caret at $rmis of the sampled indices"
else
    bad "NEGATIVE CONTROL DID NOT GO RED for the drawn caret: 8 px/char put it at the measured pen position at every sampled index, so the forward half is not really under test"
fi

done_
[ "$fail" -eq 0 ]
