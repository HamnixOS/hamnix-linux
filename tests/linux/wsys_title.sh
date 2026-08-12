#!/usr/bin/env bash
# tests/linux/wsys_title.sh — CAN YOU TELL TWO WINDOWS APART ON THIS DESKTOP?
#
# THE GAP
# =======
# wsysd drew a title bar on every decorated window and painted NO TEXT on it,
# for the whole life of this compositor. HANDOFF.md says so in its own words,
# twice: "the name is set on the wsys window where a window list would read
# it; it is NOT visible, because wsysd's decoration paints no text on a title
# bar for ANY window", and "the visible title was JUDGED and left". The title
# was never missing -- user/linux-wsys.c has held one per window since the
# port began and publishes it at /dev/wsys/windows, which is where the panel's
# taskbar reads it from. Three terminals open were three identical grey bars.
#
# WHY THIS IS A PIXEL TEST AND NOT A "TEXT APPEARED" TEST
# ======================================================
# "The title renders" is the success-shaped answer. Every assertion below is
# a count of framebuffer pixels in a rectangle computed from the window's own
# geometry, and every positive one has a NEGATIVE CONTROL in the same run --
# the same rectangle, the same window, with the title emptied. Without that
# control "there are non-background pixels on the bar" is also what a stray
# bevel, a cursor sprite or an off-by-one close box would say.
#
# WHAT IS MEASURED
# ================
#   1. THE CONTROL. A decorated window with an EMPTY title: the text band of
#      its bar is 100% the bar's own colour. Nothing is there.
#   2. THE TITLE. The same window, same geometry, `title Terminal`: the same
#      band now has ink in it, and the ink is the chrome's ink colour.
#   2b. AND THE GAPS BETWEEN THE LETTERS, which is what this gate MISSED and
#      the machine's owner found in a screenshot. Assertions 1, 2 and 4 are
#      all about the INK -- how much of it there is, how light it is, whether
#      two bars carry different amounts. None of them looks at the pixels the
#      letters do not cover, and those were BLACK: the title's keyed surface
#      declared each glyph's whole bounding box painted, so #f0f0f5 ink at
#      full strength sat in a black box on a #5577dd bar and every count above
#      was correct. Now: nothing in the band is darker than the bar, no pixel
#      of it is #000000, and the bar's own colour positively fills the gaps --
#      asserted on the FOCUSED bar (#5577dd) and the UNFOCUSED one (#404040),
#      because a bug that keyed on one colour would answer for one of them.
#   3. AND ONLY THERE. The 5px gap kept clear before the close box is still
#      100% bar colour, the close box is still the close box, the row above
#      the bar and the backdrop beyond the window's right edge are still 100%
#      the desktop's green. A title that overruns its bar is the failure this
#      whole clip exists for.
#   4. TWO WINDOWS, TWO NAMES. Two windows with different titles have
#      DIFFERENT ink on their bars. This is the user-facing claim in one
#      assertion: you can tell them apart.
#   5. A RETITLE REPAINTS. `title` moves nothing and commits no scene, so if
#      it is not in the compositor's frame signature the screen does not
#      change until something unrelated forces a frame. Asserted by changing
#      ONLY the title and watching the same band change.
#   6. A HOSTILE TITLE. The window table is /srv/wsys, mode 0666, and
#      user/linux-wsys.c says in as many words that any uid can retitle any
#      window. So: a 63-byte title must be ellipsised and must not touch the
#      close box, the neighbouring pixels or the backdrop; a title carrying a
#      double quote and a `fill` verb must not paint a rectangle; a title of
#      control bytes must not paint outside its band.
#
# Offscreen: HAMFB_FILE, no VM, no display, under a minute.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

# THE MACHINE THIS RUNS ON IS NOT SCRATCH.
#
# It sets HAMWSYS and HAMWSYS_BB but starts the window system, and /srv and
# /dev/shm/hamnix-* are the fallbacks a dropped export lands on.
#
# The names that matter are compiled into the binaries, not written here, so no
# care taken in this script can move them; the containment is the namespace.
# tests/linux/private_ns.sh has the table and the incident that bought it. This
# must come before anything that makes a file under /tmp, $WORK included, and
# before reap.sh, whose registry is itself a mktemp under /tmp.
. tests/linux/private_ns.sh
priv_ns_reexec "$@"

WORK="${TITLE_WORK:-$(mktemp -d -p "${TMPDIR:-/tmp}" wtitle.XXXXXX)}"
mkdir -p "$WORK"
GEOM="${HAMFB_GEOM:-1280x800}"
KEEP="${TITLE_KEEP:-0}"
export HAMWSYS="$WORK/wsys.shm"
export HAMWSYS_BB="$WORK/wsys.bb"
export HAMWSYS_IMG="$WORK/wsys.img"
export HAMFB_FILE="$WORK/fb.raw"
export HAMFB_GEOM="$GEOM"
[ -r /usr/share/vulkan/icd.d/lvp_icd.json ] && \
    export VK_ICD_FILENAMES="${VK_ICD_FILENAMES:-/usr/share/vulkan/icd.d/lvp_icd.json}"
FBW="${GEOM%x*}"; FBH="${GEOM#*x}"

pass=0; fail=0
ok()   { echo "title: PASS $*"; pass=$((pass+1)); }
bad()  { echo "title: FAIL $*"; fail=$((fail+1)); }
info() { echo "title: INFO $*"; }

# Every process this gate starts is registered in a FILE, not a variable:
# `hold` below is called as `A="$(hold a)"`, and a command substitution is a
# subshell, so an assignment to a $HOLDERS variable there is thrown away when
# the subshell exits. That is exactly what this gate used to do, and it leaked
# all three holders on the SUCCESS path, every run. See tests/linux/reap.sh.
. tests/linux/reap.sh
reap_track "$WORK/reaped"
cleanup() { [ "$KEEP" = 1 ] || rm -rf "$WORK"; }
reap_on_exit cleanup

command -v python3 >/dev/null || { echo "need python3 on the host" >&2; exit 1; }

BUILD_AC="${ADDER_HOST_AC:-}"
for t in wsysd:user/wsysd.ad wsys_hold:tests/linux/wsys_hold.ad; do
    name="${t%%:*}"; src="${t#*:}"
    ADDER_HOST_AC="$BUILD_AC" scripts/hamlinux_build.sh "$src" "$WORK/$name.elf" \
        >"$WORK/$name.build.log" 2>&1 || {
        echo "FAIL could not build $src" >&2; tail -20 "$WORK/$name.build.log" >&2; exit 1; }
done
ok "the compositor and the window holder build"

# ---------------------------------------------------------------------------
# The instrument. Every assertion in this file is one of these two calls.
# ---------------------------------------------------------------------------
# rectstat <x> <y> <w> <h>  -> "<total> <distinct-colours> <top-colour> <top-count>"
RECTPY="$WORK/rect.py"
cat >"$RECTPY" <<'PY'
import sys, collections
f, W, x, y, w, h = (sys.argv[1], int(sys.argv[2]), int(sys.argv[3]),
                    int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6]))
d = open(f, 'rb').read()
c = collections.Counter()
tot = 0
for j in range(y, y + h):
    for i in range(x, x + w):
        o = (j * W + i) * 4
        if o + 3 > len(d):
            continue
        tot += 1
        c['%02x%02x%02x' % (d[o+2], d[o+1], d[o])] += 1
top, n = c.most_common(1)[0] if c else ('none', 0)
print(tot, len(c), top, n)
PY
rectstat() { python3 "$RECTPY" "$HAMFB_FILE" "$FBW" "$1" "$2" "$3" "$4"; }

# nonbg <x> <y> <w> <h> <bg>  -> how many pixels in the rect are NOT <bg>
NONBGPY="$WORK/nonbg.py"
cat >"$NONBGPY" <<'PY'
import sys
f, W, x, y, w, h, bg = (sys.argv[1], int(sys.argv[2]), int(sys.argv[3]),
                        int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6]),
                        sys.argv[7])
d = open(f, 'rb').read()
n = 0
for j in range(y, y + h):
    for i in range(x, x + w):
        o = (j * W + i) * 4
        if o + 3 > len(d):
            continue
        if '%02x%02x%02x' % (d[o+2], d[o+1], d[o]) != bg:
            n += 1
print(n)
PY
nonbg() { python3 "$NONBGPY" "$HAMFB_FILE" "$FBW" "$1" "$2" "$3" "$4" "$5"; }

# THE GAPS BETWEEN THE LETTERS, which is where this gate had a hole exactly
# the shape of the defect it was written for.
#
# Every assertion above and below counts pixels that DIFFER from the bar, or
# reads the LIGHTEST pixel present. Both are questions about the INK. The
# title was rasterized into a bar-sized keyed surface precisely so the bar
# colour would show BETWEEN the letters -- and it did not: each glyph arrived
# in a black box the size of its bounding box, #f0f0f5 ink at full strength
# sitting on #000000, and every assertion here passed. The owner found it in a
# screenshot. So:
#
#   gapstat <x> <y> <w> <h> <bar>
#     -> "<darker> <black> <span> <ingap> <darkest>"
#
#   darker  pixels in the band DARKER than the bar in any channel. The title
#           ink (#f0f0f5) is lighter than either bar colour in every channel,
#           and source-over between two colours is monotone per channel, so
#           every pixel of correctly composited text is >= the bar. ONE pixel
#           darker than the bar is a pixel that was composited against
#           something that is not the bar -- which is the whole bug.
#   black   pixels that are exactly #000000: the colour of the transparent
#           clear the title surface opens with, i.e. the box itself.
#   span    width of the ink's horizontal extent (first to last column that
#           differs from the bar), so `ingap` has a denominator.
#   ingap   pixels INSIDE that span that are exactly the bar colour -- the
#           counter-assertion to `black`: not merely "no black" but "the bar,
#           positively, in the gaps". SAID PLAINLY: this one PASSES on the
#           defect (47% of the span was still bar colour with a black box
#           round every letter), and a threshold tuned until it did not would
#           be a threshold tuned to this font at this size. It is here so that
#           "no pixel is #000000" cannot be satisfied by painting the gaps
#           some third colour; `darker` and `black` are the two that
#           discriminate, and the reverted run below shows which is which.
#   darkest the darkest colour in the band, reported so a failure names what
#           the letters are actually sitting on.
GAPPY="$WORK/gap.py"
cat >"$GAPPY" <<'PY'
import sys
f, W, x, y, w, h, bar = (sys.argv[1], int(sys.argv[2]), int(sys.argv[3]),
                         int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6]),
                         sys.argv[7])
br, bg, bb = (int(bar[0:2], 16), int(bar[2:4], 16), int(bar[4:6], 16))
d = open(f, 'rb').read()
px = {}
for j in range(y, y + h):
    for i in range(x, x + w):
        o = (j * W + i) * 4
        if o + 3 > len(d):
            continue
        px[(i, j)] = (d[o+2], d[o+1], d[o])
darker = sum(1 for (r, g, b) in px.values() if r < br or g < bg or b < bb)
black = sum(1 for v in px.values() if v == (0, 0, 0))
cols = sorted({i for (i, j), v in px.items() if v != (br, bg, bb)})
if cols:
    x0, x1 = cols[0], cols[-1]
    span = x1 - x0 + 1
    ingap = sum(1 for (i, j), v in px.items()
                if x0 <= i <= x1 and v == (br, bg, bb))
else:
    span, ingap = 0, 0
dk = min(px.values(), key=lambda v: (v[0] + v[1] + v[2])) if px else (0, 0, 0)
print(darker, black, span, ingap, '%02x%02x%02x' % dk)
PY
gapstat() { python3 "$GAPPY" "$HAMFB_FILE" "$FBW" "$1" "$2" "$3" "$4" "$5"; }

# gaps_are_bar <label> <x> <y> <w> <h> <bar> -- the three assertions above,
# run identically on the FOCUSED bar (#5577dd) and the UNFOCUSED one
# (#404040), because a key colour that happened to match one of them would
# answer correctly for that one and black for the other.
gaps_are_bar() {
    local what="$1" gx="$2" gy="$3" gw="$4" gh="$5" gbar="$6"
    local s; s="$(gapstat "$gx" "$gy" "$gw" "$gh" "$gbar")"
    local dk bl sp ig dark
    dk="$(echo "$s" | cut -d' ' -f1)"; bl="$(echo "$s" | cut -d' ' -f2)"
    sp="$(echo "$s" | cut -d' ' -f3)"; ig="$(echo "$s" | cut -d' ' -f4)"
    dark="$(echo "$s" | cut -d' ' -f5)"
    info "$what (#$gbar): $dk px darker than the bar, $bl pure black, ${sp}px ink span holding $ig bar-coloured px, darkest #$dark"
    [ "$dk" = 0 ] \
        && ok "$what: NOTHING in the band is darker than the bar -- the darkest pixel IS the bar (#$dark)" \
        || bad "$what: $dk pixels are darker than the bar (darkest #$dark) -- the text is composited against something that is not the bar"
    [ "$bl" = 0 ] \
        && ok "$what: and not one pixel of the title band is #000000" \
        || bad "$what: $bl pixels of the title band are pure black -- the letters are sitting in a black box"
    [ "${ig:-0}" -ge $((sp * gh / 4)) ] \
        && ok "$what: the gaps between the letters are the bar itself ($ig of $((sp * gh)) px across the ink span)" \
        || bad "$what: only $ig of $((sp * gh)) px inside the ink span are #$gbar -- the bar does not show between the letters"
}

# A fingerprint of a rectangle, so "these two bars say different things" is a
# question with an answer that does not depend on knowing the font.
SUMPY="$WORK/sum.py"
cat >"$SUMPY" <<'PY'
import sys, hashlib
f, W, x, y, w, h = (sys.argv[1], int(sys.argv[2]), int(sys.argv[3]),
                    int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6]))
d = open(f, 'rb').read()
b = bytearray()
for j in range(y, y + h):
    o = (j * W + x) * 4
    b += d[o:o + w * 4]
print(hashlib.sha256(bytes(b)).hexdigest()[:16])
PY
rectsum() { python3 "$SUMPY" "$HAMFB_FILE" "$FBW" "$1" "$2" "$3" "$4"; }

# The same, but of the INK MASK -- which pixels differ from the given
# background -- rather than of the colours. Two title bars compared by colour
# differ the moment one of them is FOCUSED and the other is not, so a raw
# fingerprint answers "these bars are different" with a yes that has nothing
# to do with text. It did, on the reverted control run: two empty bars, one
# #5577dd and one #404040, and the assertion passed while nothing was drawn.
# The mask throws the chrome colour away and leaves only what was painted ON
# it, so two blank bars are identical whatever colour they are.
MASKPY="$WORK/mask.py"
cat >"$MASKPY" <<'PY'
import sys, hashlib
f, W, x, y, w, h, bg = (sys.argv[1], int(sys.argv[2]), int(sys.argv[3]),
                        int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6]),
                        sys.argv[7])
d = open(f, 'rb').read()
b = bytearray()
for j in range(y, y + h):
    for i in range(x, x + w):
        o = (j * W + i) * 4
        v = '%02x%02x%02x' % (d[o+2], d[o+1], d[o]) if o + 3 <= len(d) else 'none'
        b.append(0 if v == bg else 1)
print(hashlib.sha256(bytes(b)).hexdigest()[:16])
PY
inksum() { python3 "$MASKPY" "$HAMFB_FILE" "$FBW" "$1" "$2" "$3" "$4" "$5"; }

# An offscreen wsysd must not open this host's real keyboard and mouse.
: >"$WORK/input.evdev"
export HAMWSYSD_INPUT="$WORK/input.evdev"

"$WORK/wsysd.elf" </dev/null >"$WORK/wsysd.log" 2>&1 &
WSYSDPID=$!; reap_add "$WSYSDPID"
for _ in $(seq 1 60); do [ -s "$HAMFB_FILE" ] && break; sleep 0.1; done
[ -s "$HAMFB_FILE" ] || { bad "wsysd never produced a framebuffer"; cat "$WORK/wsysd.log"; exit 1; }

# Park the pointer in the top-left corner. wsysd centres the cursor at start
# and COMPOSITES it, so a probe that does not say where the cursor is is
# measuring the cursor -- tests/linux/wsys_keyed.sh learned that the hard way.
python3 - "$WORK/input.evdev" <<'PY'
import struct, sys
with open(sys.argv[1], 'ab') as f:
    for t, c, v in ((3, 0, 60), (3, 1, 60), (0, 0, 0)):
        f.write(struct.pack('<qqHHi', 0, 0, t, c, v))
PY
sleep 0.6

hold() {    # hold <name> -> prints the wid; $WORK/<name>.script drives it
    : >"$WORK/$1.script"
    "$WORK/wsys_hold.elf" "$WORK/$1.script" >"$WORK/$1.wid" 2>"$WORK/$1.err" &
    reap_add $!
    for _ in $(seq 1 40); do [ -s "$WORK/$1.wid" ] && break; sleep 0.1; done
    tr -d '\n' <"$WORK/$1.wid"
}
say() { printf '%s\n' "$2" >>"$WORK/$1.script"; sleep 0.4; }

# ---------------------------------------------------------------------------
# The desktop: a full-screen green backdrop, so "beyond the window" has a
# colour of its own and an overrun cannot hide in black.
# ---------------------------------------------------------------------------
BACK="$(hold back)"
say back "ctl geometry 0 0 $FBW $FBH"
say back "ctl decorate 0"
say back "ctl background 1"
say back "scene fill 0 0 $FBW $FBH #00a000"
sleep 1.5
BACKRGB=00a000
[ "$(rectstat 640 500 1 1 | cut -d' ' -f3)" = "$BACKRGB" ] \
    && ok "the backdrop is on the screen (wid $BACK, green)" \
    || { bad "the backdrop did not paint"; sed 's/^/title:      /' "$WORK/wsysd.log" | tail -20
         echo "title: $pass passed, $fail failed"; exit 1; }

# ---------------------------------------------------------------------------
# The window under test. Geometry chosen so its bar is clear of the screen
# edges and of the backdrop probe points.
# ---------------------------------------------------------------------------
WX=200; WY=220; WW=400; WH=180
A="$(hold a)"
say a "ctl geometry $WX $WY $WW $WH"
say a "ctl decorate 1"
say a "ctl z 5"
say a "scene fill 0 0 $WW $WH #101820"
say a "ctl title"
sleep 1.5

# THE SAME ARITHMETIC AS user/wsysd.ad, from the same window geometry.
#   TITLEBAR_H 22, CLOSE_SZ 14, TITLE_PAD 5, TITLE_GAP 5, TITLE_TOP 3
TITLEBAR_H=22; CLOSE_SZ=14; TITLE_PAD=5; TITLE_GAP=5; TITLE_TOP=3
BARY=$((WY - TITLEBAR_H))                       # top row of the bar
CBX=$((WX + WW - CLOSE_SZ - 3))                 # close box left
TX=$((WX + TITLE_PAD))                          # text left
TW=$((CBX - TITLE_GAP - TX))                    # text width budget
BANDY=$((BARY + TITLE_TOP))                     # the 16px text cell
BANDH=16
info "wid $A: bar y=$BARY..$((BARY + TITLEBAR_H - 1)), text band ${TX},${BANDY} ${TW}x${BANDH}"

# The bar's own colour, read from the bar ABOVE the text cell -- 3 rows that
# no glyph can reach, so this is a probe of the chrome and not of the title.
BAR="$(rectstat $((WX + 2)) $BARY $((WW - 40)) 2 | cut -d' ' -f3)"
BARN="$(rectstat $((WX + 2)) $BARY $((WW - 40)) 2)"
info "the title bar's colour is #$BAR ($BARN)"
[ "$(echo "$BARN" | cut -d' ' -f2)" = 1 ] \
    && ok "the strip above the text cell is one flat colour (#$BAR) -- a usable background" \
    || bad "the bar above the text cell is not flat; every probe below is unreliable"

# ---------------------------------------------------------------------------
echo "title: === 1. THE CONTROL: an empty title leaves the band untouched"
# ---------------------------------------------------------------------------
CTRL="$(nonbg $TX $BANDY $TW $BANDH "$BAR")"
CTRLSUM="$(rectsum $TX $BANDY $TW $BANDH)"
info "with no title, $CTRL of $((TW * BANDH)) band pixels differ from the bar colour"
[ "$CTRL" = 0 ] \
    && ok "an empty title paints NOTHING on the bar -- the band is 100% #$BAR" \
    || bad "$CTRL pixels are already non-background with no title set; the probe is measuring something else"

# ---------------------------------------------------------------------------
echo "title: === 2. THE TITLE: the name appears, in ink, in that same band"
# ---------------------------------------------------------------------------
say a "ctl title Terminal"
sleep 1.5
INK="$(nonbg $TX $BANDY $TW $BANDH "$BAR")"
INKSUM="$(rectsum $TX $BANDY $TW $BANDH)"
info "with 'Terminal', $INK of $((TW * BANDH)) band pixels differ from the bar colour"
[ "$INK" -ge 60 ] \
    && ok "the title is PAINTED: $INK non-background pixels where there were $CTRL" \
    || bad "only $INK non-background pixels -- 'Terminal' did not render"
[ "$INKSUM" != "$CTRLSUM" ] \
    && ok "and the band's pixels changed ($CTRLSUM -> $INKSUM)" \
    || bad "the band is byte-identical to the empty-title control"
# The ink is the chrome's ink, not some other thing that happens to differ.
# #F0F0F5 anti-aliased against the bar, so the brightest pixel present must be
# close to it -- assert on the LIGHTEST colour in the band.
LIGHT="$(python3 - "$HAMFB_FILE" "$FBW" "$TX" "$BANDY" "$TW" "$BANDH" <<'PY'
import sys
f, W, x, y, w, h = (sys.argv[1], int(sys.argv[2]), int(sys.argv[3]),
                    int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6]))
d = open(f, 'rb').read()
best = (-1, 'none')
for j in range(y, y + h):
    for i in range(x, x + w):
        o = (j * W + i) * 4
        if o + 3 > len(d):
            continue
        s = d[o] + d[o+1] + d[o+2]
        if s > best[0]:
            best = (s, '%02x%02x%02x' % (d[o+2], d[o+1], d[o]))
print(best[1])
PY
)"
info "the lightest pixel in the band is #$LIGHT (the chrome's ink is #f0f0f5)"
[ "$LIGHT" = "f0f0f5" ] \
    && ok "the ink is the compositor's title ink, at full strength" \
    || bad "the lightest pixel is #$LIGHT, not the #f0f0f5 the code says it paints"

# ---------------------------------------------------------------------------
echo "title: === 2b. AND BETWEEN THE LETTERS: the bar, not a black box"
# ---------------------------------------------------------------------------
# The gate's hole and the defect's shape. Everything above asks about the ink;
# this asks about the gaps. With the fix reverted every assertion above is
# still PASS, byte for byte, and this section says:
#
#   the focused bar (#5577dd): 432 px darker than the bar, 182 pure black,
#       53px ink span holding 400 bar-coloured px, darkest #000000
#   the unfocused bar (#404040): 100 px darker than the bar, 72 pure black,
#       27px ink span holding 205 bar-coloured px, darkest #000000
gaps_are_bar "the focused bar" $TX $BANDY $TW $BANDH "$BAR"

# ---------------------------------------------------------------------------
echo "title: === 3. AND ONLY THERE: nothing outside the band moved"
# ---------------------------------------------------------------------------
GAP="$(nonbg $((CBX - TITLE_GAP)) $BARY $TITLE_GAP $TITLEBAR_H "$BAR")"
[ "$GAP" = 0 ] \
    && ok "the ${TITLE_GAP}px gap before the close box is 100% bar colour" \
    || bad "$GAP pixels of the close-box gap are painted -- the title runs into the button"
BOXPCT="$(python3 - "$HAMFB_FILE" "$FBW" "$CBX" "$((BARY + (TITLEBAR_H - CLOSE_SZ) / 2))" "$CLOSE_SZ" <<'PY'
import sys
f, W, x, y, n = (sys.argv[1], int(sys.argv[2]), int(sys.argv[3]),
                 int(sys.argv[4]), int(sys.argv[5]))
d = open(f, 'rb').read()
tot = hit = 0
for j in range(y, y + n):
    for i in range(x, x + n):
        o = (j * W + i) * 4
        if o + 3 > len(d):
            continue
        tot += 1
        if (d[o+2], d[o+1], d[o]) == (0xCC, 0x55, 0x3B):
            hit += 1
print(0 if tot == 0 else hit * 100 // tot)
PY
)"
[ "${BOXPCT:-0}" -ge 60 ] \
    && ok "the close button is intact (${BOXPCT}% its own colour)" \
    || bad "the close button is ${BOXPCT}% its own colour -- the title painted over it"
ABOVE="$(nonbg $WX $((BARY - 4)) $WW 3 "$BACKRGB")"
[ "$ABOVE" = 0 ] \
    && ok "the 3 rows above the title bar are 100% backdrop" \
    || bad "$ABOVE pixels above the bar are not the backdrop -- ink escaped upward"
RIGHT="$(nonbg $((WX + WW + 2)) $BARY 60 $TITLEBAR_H "$BACKRGB")"
[ "$RIGHT" = 0 ] \
    && ok "the 60px of backdrop right of the window is untouched" \
    || bad "$RIGHT pixels beyond the window's right edge are painted"
LEFT="$(nonbg $((WX - 40)) $BARY 38 $TITLEBAR_H "$BACKRGB")"
[ "$LEFT" = 0 ] \
    && ok "and the backdrop left of the window is untouched" \
    || bad "$LEFT pixels left of the window are painted"

# ---------------------------------------------------------------------------
echo "title: === 4. TWO WINDOWS, TWO NAMES -- the whole point"
# ---------------------------------------------------------------------------
BX=700
B="$(hold b)"
say b "ctl geometry $BX $WY $WW $WH"
say b "ctl decorate 1"
say b "ctl z 6"
say b "scene fill 0 0 $WW $WH #101820"
say b "ctl title Files"
sleep 1.5
BBAR="$(rectstat $((BX + 2)) $BARY $((WW - 40)) 2 | cut -d' ' -f3)"
BINK="$(nonbg $((BX + TITLE_PAD)) $BANDY $TW $BANDH "$BBAR")"
info "wid $B's bar is #$BBAR with $BINK ink pixels"
[ "$BINK" -ge 40 ] \
    && ok "the second window's title is painted too ($BINK pixels)" \
    || bad "the second window's bar is empty ($BINK pixels)"
# AND THE UNFOCUSED BAR'S GAPS TOO. #404040, not #5577dd: a present that
# keyed on one particular colour, or a bar whose gaps happen to be dark, would
# be caught here and not there.
gaps_are_bar "the unfocused bar" $((BX + TITLE_PAD)) $BANDY $TW $BANDH "$BBAR"

BSUM="$(rectsum $((BX + TITLE_PAD)) $BANDY $TW $BANDH)"
AMASK="$(inksum $TX $BANDY $TW $BANDH "$BAR")"
BMASK="$(inksum $((BX + TITLE_PAD)) $BANDY $TW $BANDH "$BBAR")"
[ "$AMASK" != "$BMASK" ] \
    && ok "'Terminal' and 'Files' put DIFFERENT ink on their bars ($AMASK vs $BMASK)" \
    || bad "two windows with different titles carry identical ink -- you cannot tell them apart"

# ---------------------------------------------------------------------------
echo "title: === 5. A RETITLE REPAINTS, with nothing else changed"
# ---------------------------------------------------------------------------
BEFORE="$(rectsum $TX $BANDY $TW $BANDH)"
say a "ctl title Editor"
sleep 1.5
AFTER="$(rectsum $TX $BANDY $TW $BANDH)"
[ "$BEFORE" != "$AFTER" ] \
    && ok "changing ONLY the title changed the bar ($BEFORE -> $AFTER)" \
    || bad "the bar did not repaint after a retitle -- the title is not in the frame signature"
say a "ctl title Terminal"
sleep 1.2

# ---------------------------------------------------------------------------
echo "title: === 6. A HOSTILE TITLE (the table is 0666: any uid can set this)"
# ---------------------------------------------------------------------------
LONG="$(python3 -c 'print("W" * 63)')"
say a "ctl title $LONG"
sleep 1.5
LGAP="$(nonbg $((CBX - TITLE_GAP)) $BARY $TITLE_GAP $TITLEBAR_H "$BAR")"
[ "$LGAP" = 0 ] \
    && ok "63 W's are ellipsised: the close-box gap is still 100% bar colour" \
    || bad "$LGAP gap pixels are painted -- a long title runs into the close button"
LBOX="$(nonbg $CBX $((BARY + (TITLEBAR_H - CLOSE_SZ) / 2)) $CLOSE_SZ $CLOSE_SZ "$BAR")"
LRIGHT="$(nonbg $((WX + WW + 2)) $BARY 60 $TITLEBAR_H "$BACKRGB")"
[ "$LRIGHT" = 0 ] \
    && ok "and nothing escaped past the window's right edge" \
    || bad "$LRIGHT backdrop pixels beyond the window are painted by a 63-byte title"
LABOVE="$(nonbg $WX $((BARY - 4)) $WW 3 "$BACKRGB")"
LBELOW="$(nonbg $((WX + 2)) $((WY + 2)) $((WW - 4)) 6 "101820")"
[ "$LABOVE" = 0 ] && [ "$LBELOW" = 0 ] \
    && ok "nor above the bar, nor down into the client area" \
    || bad "a long title painted outside its band (above $LABOVE, below $LBELOW)"
LINK="$(nonbg $TX $BANDY $TW $BANDH "$BAR")"
[ "$LINK" -ge 60 ] \
    && ok "and it is still SHOWN, clipped rather than dropped ($LINK pixels)" \
    || bad "a long title rendered nothing at all ($LINK pixels)"

# INJECTION. The scene grammar is text and a title goes into a quoted token in
# it. A `"` that closed the token early would make the rest of the title a
# display-list verb of the client's choosing -- so: a title that IS one.
say a 'ctl title x" fill 0 0 1280 800 #ff0000'
sleep 1.5
RED="$(python3 - "$HAMFB_FILE" "$FBW" "$FBH" <<'PY'
import sys
f, W, H = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
d = open(f, 'rb').read()
n = 0
for j in range(0, H, 3):
    for i in range(0, W, 3):
        o = (j * W + i) * 4
        if o + 3 <= len(d) and (d[o+2], d[o+1], d[o]) == (0xff, 0x00, 0x00):
            n += 1
print(n)
PY
)"
[ "$RED" = 0 ] \
    && ok "a title carrying a quote and a fill verb painted NO rectangle anywhere" \
    || bad "$RED sampled pixels are #ff0000 -- a title injected a draw op into the display list"
IGAP="$(nonbg $((CBX - TITLE_GAP)) $BARY $TITLE_GAP $TITLEBAR_H "$BAR")"
IRIGHT="$(nonbg $((WX + WW + 2)) $BARY 60 $TITLEBAR_H "$BACKRGB")"
[ "$IGAP" = 0 ] && [ "$IRIGHT" = 0 ] \
    && ok "and it stayed inside its band like any other title" \
    || bad "the injection attempt escaped the band (gap $IGAP, right $IRIGHT)"

# CONTROL BYTES. Not a codepoint the rasterizer has to have an opinion about.
say a "$(printf 'ctl title \001\002\003\a\t\033[31mred')"
sleep 1.5
CRIGHT="$(nonbg $((WX + WW + 2)) $BARY 60 $TITLEBAR_H "$BACKRGB")"
CGAP="$(nonbg $((CBX - TITLE_GAP)) $BARY $TITLE_GAP $TITLEBAR_H "$BAR")"
CABOVE="$(nonbg $WX $((BARY - 4)) $WW 3 "$BACKRGB")"
[ "$CRIGHT" = 0 ] && [ "$CGAP" = 0 ] && [ "$CABOVE" = 0 ] \
    && ok "a title of control bytes and an ANSI escape stayed inside its band" \
    || bad "control bytes escaped the band (right $CRIGHT, gap $CGAP, above $CABOVE)"

# AND THE OTHER WINDOW WAS NEVER TOUCHED BY ANY OF IT.
BSUM2="$(rectsum $((BX + TITLE_PAD)) $BANDY $TW $BANDH)"
[ "$BSUM2" = "$BSUM" ] \
    && ok "wid $B's title bar is byte-identical through every hostile title on wid $A" \
    || bad "a hostile title on one window changed another window's bar"

echo "title: $pass passed, $fail failed"
[ "$fail" = 0 ] || exit 1
