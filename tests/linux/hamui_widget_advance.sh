#!/usr/bin/env bash
# hamui_widget_advance.sh — A WIDGET'S BOX MUST BE MEASURED, NOT MULTIPLIED.
#
# WHAT THIS GATE IS FOR
# =====================
# lib/hamui.ad sized every text-bearing widget at `text_len * 8 + pad`. The
# DE's `text`/`glyphs` primitives have gone through the PROPORTIONAL DejaVu
# face since task #284: at WSYS_UI_PX(14) an 'i' advances 3 px and a 'W'
# advances 12. So the constant was not merely imprecise, it was wrong in BOTH
# directions -- boxes ~2x too wide for narrow text and ~1.5x too NARROW for
# wide text, which is text spilling out of a button.
#
# The caret bug fixed on 2026-08-17 was four copies of the same assumption.
# These are the sizing copies.
#
# THE ASSERTION USES NO CONSTANT -- THAT IS THE POINT
# ===================================================
# Comparing a box to a hard-coded pixel number would just move the constant
# into the gate. Instead every site is built TWICE, with two strings of the
# SAME BYTE COUNT and very different real width ("iiiiiiiiiiii" = 36 px,
# "WWWWWWWWWWWW" = 144 px). Then, for each site:
#
#   A1  box(wide) - box(narrow)  ==  textpx(wide) - textpx(narrow)
#   A2  box(narrow) - textpx(narrow)  ==  box(wide) - textpx(wide)
#         (the padding around the text does not depend on the text)
#
# Under the 8 px/char bug both boxes are IDENTICAL, so A1 reads 0 == 108 and
# the gate names the widget and both numbers. Nothing here knows or cares what
# the padding is, so a change to a padding constant does not touch this gate.
#
# THE NEGATIVE CONTROL IS RUN, NOT DESCRIBED
# ==========================================
# `hamui_advance_host OUT.ppm force8` calls hamui_force_8px_advance(1), which
# puts lib/hamui.ad's two width helpers back on 8 px/char. That arm is the
# DEFECT, running, against the same binary -- and this gate FAILS if that arm
# passes. An assertion that cannot fail is not an assertion.
#
# THE INSTRUMENT IS PROVEN BEFORE IT IS BELIEVED
# ==============================================
# htb_text_width() FALLS BACK to 8 px/char when the TTF is not loaded. If that
# fallback were live, every number here would agree with the bug and the gate
# would pass green on a broken tree. So arm 0 asserts FONT_READY 1 and asserts
# that the measured advances of 'i' and 'W' actually DIFFER before any width
# is trusted. An empty or agreeing result is not a finding until the
# instrument has been shown able to produce a disagreeing one.
#
# WHAT IT DOES NOT ASSERT
# =======================
#  * That the glyphs actually FIT inside the painted box on screen. It checks
#    box-vs-measured-text arithmetic, not rasterized ink extents.
#  * Anything about the NATIVE target. This is the x86_64-linux host twin
#    (docs/hamui_dual_target.md); it runs the same lib/hamui.ad layout and
#    paint code, but it is not a boot.
#  * The INVERSE sites (click x -> character index). lib/hamtextbox's
#    htb_hit_test() owns those inside hamui, but lib/hamslidescore.ad:2595 and
#    lib/hamsheetcore.ad:3265 still divide by 8 and are NOT covered here.
#  * hamui.ad's tooltip bubble width, which is only reachable through a hover
#    dwell no host driver drives.
#
# No device is touched: it compiles one host binary and runs it twice.
set -uo pipefail
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ" || exit 1

pass=0; fail=0
ok()   { printf 'wadv: PASS %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf 'wadv: FAIL %s\n' "$*"; fail=$((fail+1)); }
note() { printf 'wadv: .... %s\n' "$*"; }

OUT="${HAMLINUX_OUT:-$(mktemp -d /tmp/wadv.XXXXXX)}"
mkdir -p "$OUT"

BIN="$OUT/hamui_advance_host"

note "project $PROJ"
note "out     $OUT"

# ---------------------------------------------------------------- arm 0: build
if python3 -m compiler.adder compile --target=x86_64-linux \
        user/hamui_advance_host.ad -o "$BIN" > "$OUT/compile.log" 2>&1; then
    ok "host renderer compiles for x86_64-linux"
else
    bad "host renderer FAILED to compile -- see $OUT/compile.log"
    tail -20 "$OUT/compile.log"
    printf 'wadv: %d PASSED / %d FAILED\n' "$pass" "$fail"
    exit 1
fi

if [ -s "$BIN" ]; then
    ok "host renderer binary is non-empty ($(stat -c %s "$BIN") bytes)"
else
    bad "host renderer binary is empty"
fi

run_arm() {
    # $1 = tag (measured|force8), $2 = extra argv
    local tag="$1" extra="${2:-}"
    if [ -n "$extra" ]; then
        "$BIN" "$OUT/$tag.ppm" "$extra" > "$OUT/$tag.txt" 2> "$OUT/$tag.err"
    else
        "$BIN" "$OUT/$tag.ppm" > "$OUT/$tag.txt" 2> "$OUT/$tag.err"
    fi
    return $?
}

run_arm measured
rc=$?
if [ "$rc" -eq 0 ]; then
    ok "GREEN arm exits 0"
else
    bad "GREEN arm exited $rc (expected 0)"
fi

G="$OUT/measured.txt"

# ---------------------------------------------- arm 0: the instrument is real
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
    bad "FONT_READY=${ready:-<none>} -- htb_text_width() is on its 8 px/char FALLBACK, so every width below would agree with the bug it exists to catch. Refusing to read them."
    printf 'wadv: %d PASSED / %d FAILED\n' "$pass" "$fail"
    exit 1
fi

adv_i=$(awk '/^ADV i /{print $3}' "$G")
adv_w=$(awk '/^ADV W /{print $3}' "$G")
if [ -n "${adv_i:-}" ] && [ -n "${adv_w:-}" ] && [ "$adv_i" -ne "$adv_w" ]; then
    ok "instrument distinguishes glyphs: 'i' advances ${adv_i}px, 'W' advances ${adv_w}px"
else
    bad "advance of 'i' (${adv_i:-?}) and 'W' (${adv_w:-?}) are not distinguishable -- the instrument cannot see the defect it is looking for"
    printf 'wadv: %d PASSED / %d FAILED\n' "$pass" "$fail"
    exit 1
fi

# The two probe strings must actually differ in measured width, or A1 is 0==0.
tn=$(awk '$1=="W" && $2=="LABEL.narrow"{print $4}' "$G")
tw=$(awk '$1=="W" && $2=="LABEL.wide"{print $4}' "$G")
if [ -n "${tn:-}" ] && [ -n "${tw:-}" ] && [ "$tn" -ne "$tw" ]; then
    ok "probe strings measure differently: narrow=${tn}px wide=${tw}px (same byte count)"
else
    bad "probe strings measure the same (${tn:-?} vs ${tw:-?}) -- A1 would be 0 == 0"
    printf 'wadv: %d PASSED / %d FAILED\n' "$pass" "$fail"
    exit 1
fi

SITES="LABEL BUTTON CHECK RADIO STATUSBAR MENUITEM MENUTITLE POPDOWN TAB"

# check_site <file> <site> <expect: measured|force8>
#   measured -> A1 and A2 must hold
#   force8   -> A1 must NOT hold (the defect is present)
check_site() {
    local f="$1" site="$2" mode="$3"
    local bn tn2 bw tw2
    bn=$(awk -v s="$site.narrow" '$1=="W" && $2==s{print $3}' "$f")
    tn2=$(awk -v s="$site.narrow" '$1=="W" && $2==s{print $4}' "$f")
    bw=$(awk -v s="$site.wide" '$1=="W" && $2==s{print $3}' "$f")
    tw2=$(awk -v s="$site.wide" '$1=="W" && $2==s{print $4}' "$f")
    if [ -z "$bn" ] || [ -z "$bw" ]; then
        bad "$site: no record in $f -- the renderer did not report this site"
        return
    fi
    local dbox=$((bw - bn)) dtxt=$((tw2 - tn2))
    local padn=$((bn - tn2)) padw=$((bw - tw2))
    if [ "$mode" = "measured" ]; then
        if [ "$dbox" -eq "$dtxt" ]; then
            ok "$site box tracks measured text: box ${bn}->${bw} (delta $dbox) == text ${tn2}->${tw2} (delta $dtxt)"
        else
            bad "$site box does NOT track measured text: box ${bn}->${bw} (delta $dbox) but text ${tn2}->${tw2} (delta $dtxt); the box is sized by a constant, not by the string"
        fi
        if [ "$padn" -eq "$padw" ]; then
            ok "$site padding is text-independent: ${padn}px around both strings"
        else
            bad "$site padding depends on the text: ${padn}px around the narrow string, ${padw}px around the wide one"
        fi
    else
        if [ "$dbox" -eq "$dtxt" ]; then
            bad "NEGATIVE CONTROL DID NOT GO RED for $site: with 8 px/char forced back on, box delta $dbox still equals text delta $dtxt. This gate cannot fail and is therefore worthless."
        else
            ok "negative control red for $site: box delta $dbox vs text delta $dtxt"
        fi
    fi
}

for s in $SITES; do
    check_site "$G" "$s" measured
done

# ------------------------------------------- calendar centred title (site 3992)
calx=$(awk '/^CALBOX /{print $2}' "$G")
calw=$(awk '/^CALBOX /{print $3}' "$G")
caltpx=$(awk '/^CALTITLEPX /{print $2}' "$G")
titlex=$(awk '$1=="glyphs" && $0 ~ /"January 1970"/ {print $2}' "$G" | head -1)
if [ -n "${titlex:-}" ] && [ -n "${calx:-}" ]; then
    want=$(( calx + (calw - caltpx) / 2 ))
    if [ "$titlex" -eq "$want" ]; then
        ok "CALENDAR title centred on measured width: drawn at x=$titlex, centre of ${calw}px box around ${caltpx}px of text = $want"
    else
        bad "CALENDAR title NOT centred on measured width: drawn at x=$titlex, but centring ${caltpx}px of text in the ${calw}px box at x=$calx gives $want"
    fi
else
    bad "CALENDAR title record missing (titlex=${titlex:-<none>} calx=${calx:-<none>}) -- the scene dump did not contain the month title"
fi

# ------------------------------------------------- the RUN negative control
note "negative control: re-running with 8 px/char forced back on"
run_arm force8 force8
rc8=$?
if [ "$rc8" -eq 0 ]; then
    ok "RED arm exits 0 (it renders; it is the sizing that is wrong)"
else
    bad "RED arm exited $rc8"
fi
R="$OUT/force8.txt"
if grep -qx 'MODE force8' "$R"; then
    ok "RED arm really ran in force8 mode"
else
    bad "RED arm did not report MODE force8 -- the control did not arm, so nothing below it would mean anything. (This exact mistake happened once already: the wrapper dropped the argument and the control 'passed' against a tree that had never been shimmed.)"
    printf 'wadv: %d PASSED / %d FAILED\n' "$pass" "$fail"
    exit 1
fi
# The reference width in the RED arm is ALSO forced to 8/char (hamui_text_px
# shares the hook), so compare its box deltas against the GREEN arm's REAL
# text deltas: that is the comparison the gate makes in anger.
for s in $SITES; do
    bn=$(awk -v s="$s.narrow" '$1=="W" && $2==s{print $3}' "$R")
    bw=$(awk -v s="$s.wide" '$1=="W" && $2==s{print $3}' "$R")
    gtn=$(awk -v s="$s.narrow" '$1=="W" && $2==s{print $4}' "$G")
    gtw=$(awk -v s="$s.wide" '$1=="W" && $2==s{print $4}' "$G")
    if [ -z "$bn" ] || [ -z "$bw" ]; then
        bad "$s: no record in the RED arm"
        continue
    fi
    dbox=$((bw - bn)); dtxt=$((gtw - gtn))
    if [ "$dbox" -eq "$dtxt" ]; then
        bad "NEGATIVE CONTROL DID NOT GO RED for $s: box delta $dbox equals the real text delta $dtxt even with 8 px/char forced on"
    else
        ok "negative control red for $s: 8 px/char gives box delta $dbox where the real text delta is $dtxt"
    fi
done

printf 'wadv: %d PASSED / %d FAILED\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
