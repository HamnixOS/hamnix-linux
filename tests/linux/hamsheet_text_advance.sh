#!/usr/bin/env bash
# hamsheet_text_advance.sh — A CELL'S TEXT MUST BE PLACED BY MEASUREMENT.
#
# WHAT THIS GATE IS FOR
# =====================
# lib/hamsheetcore.ad clipped, right-aligned, centred and caretted text at
# 8 px/char against a face that advances 3 to 12 px per glyph, so a
# right-aligned label floated away from its cell's right edge and a centred
# column header sat off-centre.
#
# THIS FILE IS NOT HALF OF A FORWARD/INVERSE PAIR, AND THAT WAS CHECKED
# =====================================================================
# hamsheetcore was previously grouped with lib/hamslidescore.ad as a pair that
# could not be half-fixed, on the reading that _draw_cliptext's "(w - 6) / 8"
# was the inverse of the "* 8" placements. It is not. That divide is a CLIP
# BUDGET (how many leading bytes fit in a cell), and hamsheet_hit() resolves a
# click to a cell by walking the col_w[] PIXEL rectangles -- it never divides a
# pixel by a character width. The cell edit caret and the formula-bar caret
# both sit at END of text with no in-cell click positioning, so neither has an
# inverse either. Every site here is FORWARD-ONLY, so fixing it cannot make
# clicking worse; that is why it is fixed and gated separately from
# tests/linux/hamslides_click_roundtrip.sh, which gates the one site in the
# tree that really does have an inverse.
#
# THE ASSERTION USES NO PIXEL CONSTANT OF ITS OWN
# ===============================================
# The driver reports the CELL RECTANGLE the paint pass drew into and the
# MEASURED pixel width of the string it drew. This gate then checks the
# placement identity for each alignment against the PAINTED display list:
#
#   left    drawn_x == cellx + 3
#   right   drawn_x == cellx + cellw - 3 - measured_px
#   centre  drawn_x == cellx + (cellw - measured_px) / 2
#
# and, separately and without reference to any padding at all, that the OFFSET
# of the text inside its cell actually CHANGES when the string's real width
# changes while its byte count does not. Under 8 px/char that offset is
# identical for both probes, which is the shape of the defect.
#
# THE INSTRUMENT IS PROVEN BEFORE IT IS BELIEVED
# ==============================================
# htb_text_width() FALLS BACK to 8 px/char with no face loaded, and on that
# fallback every number here would agree with the bug this gate exists to
# catch. FONT_READY 1 is asserted first and the gate refuses to read a width
# otherwise.
#
# THE NEGATIVE CONTROL IS RUN, NOT DESCRIBED
# ==========================================
# The second arm calls hamsheet_force_8px_advance(1), putting every metric
# helper in lib/hamsheetcore.ad back on 8 px/char. This gate FAILS if that arm
# passes.
#
# WHAT IT DOES NOT ASSERT
# =======================
#  * Glyph INK extents. This is pen-advance arithmetic.
#  * The CLIP budget itself. The probes are short enough to fit a default
#    72 px column uncut, deliberately, so this gate measures PLACEMENT.
#  * The column/row HEADER placements and the two carets. They call the same
#    two helpers, so they are covered by construction, not by assertion.
#  * Anything about the NATIVE target. This is the x86_64-linux host twin.
#
# No device is touched: it compiles one host binary and runs it twice.
set -uo pipefail
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ" || exit 1

pass=0; fail=0
ok()   { printf 'sha: PASS %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf 'sha: FAIL %s\n' "$*"; fail=$((fail+1)); }
note() { printf 'sha: .... %s\n' "$*"; }
done_() { printf 'sha: %d PASSED / %d FAILED\n' "$pass" "$fail"; }

OUT="${HAMLINUX_OUT:-$(mktemp -d /tmp/sha.XXXXXX)}"
mkdir -p "$OUT"
BIN="$OUT/hamsheet_advance_host"

note "project $PROJ"
note "out     $OUT"

if python3 -m compiler.adder compile --target=x86_64-linux \
        user/hamsheet_advance_host.ad -o "$BIN" > "$OUT/compile.log" 2>&1; then
    ok "sheet advance host driver compiles for x86_64-linux"
else
    bad "sheet advance host driver FAILED to compile -- see $OUT/compile.log"
    tail -20 "$OUT/compile.log"
    done_; exit 1
fi
if [ -s "$BIN" ]; then
    ok "driver binary is non-empty ($(stat -c %s "$BIN") bytes)"
else
    bad "driver binary is empty"; done_; exit 1
fi

"$BIN" "$OUT/measured.ppm" > "$OUT/measured.txt" 2> "$OUT/measured.err"
rc=$?
G="$OUT/measured.txt"
if [ "$rc" -eq 0 ]; then
    ok "GREEN arm exits 0"
else
    bad "GREEN arm exited $rc; stderr: $(head -3 "$OUT/measured.err")"
fi
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
    bad "GREEN arm did not report MODE measured"; done_; exit 1
fi

amin=$(awk '/^ADV /{print $3}' "$G" | sort -n | head -1)
amax=$(awk '/^ADV /{print $3}' "$G" | sort -n | tail -1)
if [ -n "${amin:-}" ] && [ "$amin" -lt 8 ] && [ "$amax" -gt 8 ]; then
    ok "probe glyph advances STRADDLE 8 px: narrowest ${amin}px, widest ${amax}px"
else
    bad "probe glyph advances do not straddle 8 px (min=${amin:-?} max=${amax:-?}); the instrument cannot distinguish a proportional face from the constant it is testing"
    done_; exit 1
fi

# Find the x the paint pass DREW a given string at, in a given scene dump.
# EVERY row draws the SAME two probe strings, so the string alone is ambiguous
# and matching on it picks row 0 every time -- this gate went red on correct
# code exactly once for that reason. The drawn Y is what tells the rows apart,
# so both are required, and a lookup that finds more than one run is refused
# rather than silently resolved.
drawn_x() {   # $1=file  $2=quoted string incl. quotes  $3=drawn y
    awk -v s="$2" -v y="$3" '$1=="glyphs" && $4==s && $3==y{print $2}' "$1"
}

# Report every CELL record: <tag> <align> <cellx> <cellw> <px> <texty> <"str">
records() { awk '/^CELL /{print $2, $3, $4, $5, $6, $7, $8}' "$1"; }

nrec=$(records "$G" | wc -l)
if [ "$nrec" -eq 6 ]; then
    ok "driver reported all 6 cell placements (left/right/centre x narrow/wide)"
else
    bad "driver reported $nrec cell placements, expected 6 -- an incomplete sweep is not a finding"
    done_; exit 1
fi

# The two probes must actually measure differently or every assertion is 0==0.
pn=$(awk '$1=="CELL" && $2=="LEFT.narrow"{print $6}' "$G")
pw=$(awk '$1=="CELL" && $2=="LEFT.wide"{print $6}' "$G")
if [ -n "${pn:-}" ] && [ -n "${pw:-}" ] && [ "$pn" -ne "$pw" ]; then
    ok "probe strings measure differently: narrow=${pn}px wide=${pw}px (same byte count)"
else
    bad "probe strings measure the same (${pn:-?} vs ${pw:-?}) -- every assertion below would be 0 == 0"
    done_; exit 1
fi

# ------------------------------------- the placement identity, per alignment
check() {   # $1=file  $2=label-for-messages  $3=expect-hold(1)/expect-break(0)
    local f="$1" lbl="$2" want="$3"
    while read -r tag align cx cw px ty str; do
        local got exp n
        got=$(drawn_x "$f" "$str" "$ty")
        n=$(printf '%s\n' "$got" | grep -c .)
        if [ "$n" -ne 1 ]; then
            bad "$lbl $tag: found $n glyph runs of $str at y=$ty in the painted display list, not exactly 1 -- this gate refuses to guess which one is the cell it is testing"
            continue
        fi
        case "$align" in
            0) exp=$((cx + 3)); nm="left edge + 3" ;;
            1) exp=$((cx + cw - 3 - px)); nm="cell right edge - 3 - ${px}px of measured text" ;;
            2) exp=$((cx + (cw - px) / 2)); nm="centre of the ${cw}px cell around ${px}px of measured text" ;;
        esac
        if [ "$want" = "1" ]; then
            if [ "$got" -eq "$exp" ]; then
                ok "$tag drawn at x=$got, which is the $nm"
            else
                bad "$tag drawn at x=$got but the $nm is x=$exp -- off by $((got - exp)); the placement is computed from a constant, not from the string"
            fi
        else
            if [ "$got" -eq "$exp" ]; then
                bad "NEGATIVE CONTROL DID NOT GO RED for $tag: with 8 px/char forced on it still landed at x=$got, the measured $nm. This gate cannot fail and is therefore worthless."
            else
                ok "negative control red for $tag: 8 px/char put it at x=$got where the measured $nm is x=$exp"
            fi
        fi
    done < <(records "$G")
}

check "$G" "GREEN" 1

# ------------------- and, with no padding constant at all: the offset MOVES
# Right- and centre-aligned text of the SAME byte count but different real
# width must sit at a DIFFERENT offset inside its cell. Under 8 px/char the two
# offsets are identical. This assertion mentions no padding whatsoever.
for al in RIGHT CENTRE; do
    on=""; ow=""
    for k in narrow wide; do
        cx=$(awk -v t="$al.$k" '$1=="CELL" && $2==t{print $4}' "$G")
        st=$(awk -v t="$al.$k" '$1=="CELL" && $2==t{print $8}' "$G")
        ty=$(awk -v t="$al.$k" '$1=="CELL" && $2==t{print $7}' "$G")
        dx=$(drawn_x "$G" "$st" "$ty")
        if [ "$k" = "narrow" ]; then on=$((dx - cx)); else ow=$((dx - cx)); fi
    done
    if [ "$on" -ne "$ow" ]; then
        ok "$al: the text's offset inside its cell TRACKS the string -- ${on}px for the narrow probe, ${ow}px for the wide one (same byte count)"
    else
        bad "$al: the text sits at the SAME ${on}px offset inside its cell for both probes, so the placement does not depend on the string's real width at all"
    fi
done

# =========================================================================
note "negative control: re-running with 8 px/char forced back on"
"$BIN" "$OUT/force8.ppm" force8 > "$OUT/force8.txt" 2> "$OUT/force8.err"
rc8=$?
R="$OUT/force8.txt"
if [ "$rc8" -eq 0 ]; then
    ok "RED arm exits 0 (it renders; it is the placement that is wrong)"
else
    bad "RED arm exited $rc8"
fi
if grep -qx 'MODE force8' "$R"; then
    ok "RED arm really ran in force8 mode"
else
    bad "RED arm did not report MODE force8 -- the control did not arm, so nothing below it would mean anything. (A wrapper dropping the shim argument has already caused nine controls here to pass against a binary that was never shimmed.)"
    done_; exit 1
fi
if [ "$(awk '/^FONT_READY /{print $2}' "$R")" = "1" ]; then
    ok "RED arm still has the face loaded, so its reference widths are measurements too"
else
    bad "RED arm reports FONT_READY 0 -- the control is not the defect, it is a missing font"
    done_; exit 1
fi

# The RED arm's DRAWN positions, judged against the GREEN arm's REAL
# measurements: that is the comparison this gate makes in anger. LEFT is
# excluded because left alignment does not use a width at all and correctly
# does not move.
while read -r tag align cx cw px ty str; do
    [ "$align" = "0" ] && continue
    got=$(drawn_x "$R" "$str" "$ty")
    case "$align" in
        1) exp=$((cx + cw - 3 - px)); nm="cell right edge - 3 - ${px}px of measured text" ;;
        2) exp=$((cx + (cw - px) / 2)); nm="centre of the ${cw}px cell around ${px}px of measured text" ;;
    esac
    if [ -z "${got:-}" ]; then
        bad "$tag: the string $str does not appear in the RED arm's display list"
    elif [ "$got" -eq "$exp" ]; then
        bad "NEGATIVE CONTROL DID NOT GO RED for $tag: with 8 px/char forced on it still landed at x=$got, the measured $nm. This gate cannot fail and is therefore worthless."
    else
        ok "negative control red for $tag: 8 px/char draws it at x=$got where the measured $nm is x=$exp"
    fi
done < <(records "$G")

# And under 8 px/char the offset must COLLAPSE to the same value for both
# probes -- the positive form of the same defect.
for al in RIGHT CENTRE; do
    on=""; ow=""
    for k in narrow wide; do
        cx=$(awk -v t="$al.$k" '$1=="CELL" && $2==t{print $4}' "$R")
        st=$(awk -v t="$al.$k" '$1=="CELL" && $2==t{print $8}' "$R")
        ty=$(awk -v t="$al.$k" '$1=="CELL" && $2==t{print $7}' "$R")
        dx=$(drawn_x "$R" "$st" "$ty")
        if [ "$k" = "narrow" ]; then on=$((dx - cx)); else ow=$((dx - cx)); fi
    done
    if [ "$on" -eq "$ow" ]; then
        ok "negative control red for $al: 8 px/char puts BOTH probes at the same ${on}px offset inside their cell, which is the defect itself"
    else
        bad "under 8 px/char the $al offsets still differ (${on} vs ${ow}) -- the control is not reproducing the defect this gate describes"
    fi
done

done_
[ "$fail" -eq 0 ]
