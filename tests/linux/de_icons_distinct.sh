#!/usr/bin/env bash
# tests/linux/de_icons_distinct.sh — TWO DIFFERENT APPLICATIONS MUST NOT DRAW
# THE SAME PICTURE.
#
# THE BUG, as the machine's owner reported it
# ===========================================
#   "A lot of the icons are missing images. We should generate images for each
#    application for their icon."
#
# They were looking at /home/david/.hamnix-build/wsysver-hook2/shots/A-3-menu.png:
# a column of desktop launchers down the left in which Text Editor, Video
# Player, Spreadsheet, Presentation and Word Processor are FIVE COPIES OF THE
# SAME WHITE PAGE. Nothing was missing from disk. There is no icon asset on
# disk at all — every icon in this desktop is vector code in lib/hamscene.ad,
# `Icon=` names resolved to a glyph CODE by hamscene_icon_code() — and that
# function answered HS_ICON_FILE, the generic page, for every name it had not
# been taught: x-office-document, x-office-spreadsheet, x-office-presentation,
# multimedia-video-player, multimedia-audio-player, input-mouse. It answered
# successfully. It drew successfully. Every existing gate stayed green.
#
# That is the shape NORTH_STAR.md is about: the answer was success-shaped and
# was not the truth. So this gate does not ask "did an icon get drawn" — a
# blank rectangle passes that. It asks the owner's actual question, in pixels:
#
#     ARE ANY TWO OF THESE THE SAME PICTURE?
#
# WHAT IS MEASURED
# ================
#   1. the real desktop, composed offscreen: wsysd + hamdesktop, no VM, no
#      display, no GPU, against a ~/Desktop this gate owns (so the icon set
#      under test is the SHIPPED etc/skel/Desktop set and not whatever the
#      person running this has on their own desktop).
#   2. hamdesktop's own published icon table (/tmp/.hamdesktop.src, "icon
#      <cx> <cy> <label>") gives the cell of every launcher BY NAME. The gate
#      does not re-derive the column flow — a guess that misses measures the
#      wrong rectangle and reports a false result either way.
#   3. NO `icon-unknown` LINE. hamdesktop now publishes the name of every
#      `Icon=` that failed to resolve, because an icon that cannot be drawn
#      must say WHICH ONE rather than quietly drawing a blank page. A name
#      here fails this gate and tells you what to add.
#   4. every icon rect DIFFERS FROM THE BARE WALLPAPER at the same scanline —
#      something was actually painted. (A glyph that draws nothing is the
#      "success-shaped" failure mode this whole file exists to refuse.)
#   5. every icon rect carries several distinct colours: not one flat block.
#   6. THE HEADLINE: all N icons are pairwise DIFFERENT PICTURES. The rects
#      are fingerprinted and the number of distinct fingerprints must equal
#      the number of icons.
#   7. the five pairs the owner was actually looking at, called out by name
#      with the fraction of pixels that differ, so a regression says which
#      two apps collided rather than "a duplicate exists".
#   8. THE NEGATIVE CONTROL, in the same run: the same icon compared with
#      ITSELF across two frames must be ~0% different. Without it, "these two
#      differ by 40%" is not evidence — a metric that reports everything as
#      different would satisfy every assertion above.
#
# Entirely offscreen (HAMFB_FILE): no VM, no display, no GPU.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

# hamdesktop writes FIXED, HOST-GLOBAL names whatever this script does about
# its own $WORK: /tmp/.hamdesktop.src and /tmp/hamdesktop-wp.status are
# compiled into the program under test, and this gate READS the first one, so
# a concurrent run — another agent's, or a person's live desktop on this
# machine — would answer for it. tests/linux/private_ns.sh puts everything
# below inside a mount namespace where /tmp, /dev/shm and /srv are this run's
# alone. It execs, and does not return.
. tests/linux/private_ns.sh
priv_ns_reexec "$@"
. tests/linux/reap.sh

WORK="${ICONS_WORK:-$(mktemp -d -p "${TMPDIR:-/tmp}" deicons.XXXXXX)}"
mkdir -p "$WORK"
KEEP="${ICONS_KEEP:-0}"
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
ok()   { echo "deicons: PASS $*"; pass=$((pass+1)); }
bad()  { echo "deicons: FAIL $*"; fail=$((fail+1)); }
info() { echo "deicons: INFO $*"; }

reap_track "$WORK/reaped"
cleanup() {
    reap_all
    [ "$KEEP" = 1 ] || rm -rf "$WORK"
}
reap_on_exit cleanup
done_report() { echo "deicons: $pass passed, $fail failed"; [ "$fail" = 0 ]; }

# ---- the desktop this gate owns ------------------------------------------
# hamdesktop builds its grid from the SESSION USER'S ~/Desktop, and it does
# NOT mean getenv("HOME"): user/hamdesktop.ad:_desk_dir asks /env/HOME (the
# Plan 9 spelling, which does not exist on a Linux host), then /etc/passwd BY
# UID, then each regular account. Left alone on this host it therefore found
# /home/david/Desktop and measured THE PERSON'S OWN DESKTOP -- 3 icons of
# screenshots and a stray file, nothing to do with the distribution. Measured;
# it is what the first run of this gate reported.
#
# So the gate supplies a passwd. We are root in a private MOUNT namespace
# (tests/linux/private_ns.sh), so one bind-mount of one file redirects the
# resolution at its source and touches nothing on the host.
DESKHOME="$WORK/home"
mkdir -p "$DESKHOME/Desktop"
cp etc/skel/Desktop/*.desktop "$DESKHOME/Desktop/" 2>/dev/null
UID_NOW="$(id -u)"
{ printf 'gateuser:x:%s:%s::%s:/bin/sh\n' "$UID_NOW" "$(id -g)" "$DESKHOME"
  grep -v ":x:$UID_NOW:" /etc/passwd; } >"$WORK/passwd"
python3 - "$WORK/passwd" <<'PY' || { echo "deicons: FAIL cannot bind a passwd"; exit 1; }
import ctypes, os, sys
libc = ctypes.CDLL("libc.so.6", use_errno=True)
MS_BIND = 4096
if libc.mount(sys.argv[1].encode(), b"/etc/passwd", None,
              ctypes.c_ulong(MS_BIND), None) != 0:
    sys.stderr.write("bind /etc/passwd: %s\n"
                     % os.strerror(ctypes.get_errno()))
    raise SystemExit(1)
PY
info "/etc/passwd in this namespace puts uid $UID_NOW's home at $DESKHOME"
export HOME="$DESKHOME"
NDESK=$(ls -1 "$DESKHOME/Desktop"/*.desktop 2>/dev/null | wc -l)
if [ "$NDESK" -lt 8 ]; then
    bad "etc/skel/Desktop has only $NDESK launchers -- nothing to compare"
    done_report; exit 1
fi
info "the shipped desktop is $NDESK launchers, copied into $DESKHOME/Desktop"

# ---- build ----------------------------------------------------------------
for t in wsysd:user/wsysd.ad hamdesktop:user/hamdesktop.ad; do
    name="${t%%:*}"; src="${t#*:}"
    scripts/hamlinux_build.sh "$src" "$WORK/$name.elf" \
        >"$WORK/$name.build.log" 2>&1 || {
        bad "could not build $src"; tail -20 "$WORK/$name.build.log" >&2
        done_report; exit 1; }
done
ok "the compositor and the desktop both build"

# ---- the compositor -------------------------------------------------------
# An offscreen wsysd must not open this host's real keyboard and mouse.
: >"$WORK/input.evdev"
export HAMWSYSD_INPUT="$WORK/input.evdev"
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

# THE CURSOR IS PARKED OFF EVERY MEASURED RECTANGLE. wsysd draws its sprite at
# the centre of the screen at startup, and a pixel probe on a compositor that
# does not say where the cursor is ends up measuring the cursor.
python3 - "$WORK/input.evdev" <<'PY'
import struct, sys
with open(sys.argv[1], 'ab') as f:
    for t, c, v in ((3, 0, 32000), (3, 1, 30000), (0, 0, 0)):
        f.write(struct.pack('<qqHHi', 0, 0, t, c, v))
PY

# ---- the desktop ---------------------------------------------------------
"$WORK/hamdesktop.elf" </dev/null >"$WORK/hamdesktop.log" 2>&1 &
reap_add $!
sleep 4
cp "$HAMFB_FILE" "$WORK/frame1.raw"
sleep 1.5
cp "$HAMFB_FILE" "$WORK/frame2.raw"      # the negative control's second frame

SRC=/tmp/.hamdesktop.src
if [ -s "$SRC" ] && grep -q "^src=$DESKHOME/Desktop " "$SRC"; then
    ok "hamdesktop published its icon table and built the grid from THIS gate's $DESKHOME/Desktop"
else
    bad "no icon table at $SRC for $DESKHOME/Desktop -- the desktop is showing someone else's icons, or none"
    [ -s "$SRC" ] && sed 's/^/deicons:      /' "$SRC"
    sed 's/^/deicons:      /' "$WORK/hamdesktop.log"
    done_report; exit 1
fi

# One icon per launcher -- MINUS the live-medium-only ones. `Install Hamnix`
# carries X-Hamnix-LiveOnly and hamdesktop deliberately hides it on a system
# that is not the live image, which this host is not. Both counts are named so
# neither reading is a guess.
NICON=$(grep -c '^icon ' "$SRC")
# `grep -lix` was this file's own reading and it DISAGREED with the one in
# de_appmenu_installed.sh, which counts the same key with `grep -l`. Neither
# matched lib/desktopentry.ad, the code that really hides these launchers, and
# a trailing space or CR in a .desktop file made the two diverge and FABRICATE
# an icon-count defect here -- "the desktop drew N icons for N+1 launchers",
# said about the desktop, caused by whitespace in a text file. One shared
# reading now, derived from the parser; see tests/linux/desktop_liveonly.sh.
. tests/linux/desktop_liveonly.sh
NLIVE=$(desktop_liveonly_count "$DESKHOME/Desktop"/*.desktop)
NEXP=$((NDESK - NLIVE))
if [ "$NICON" = "$NEXP" ]; then
    ok "one icon per launcher the desktop should show ($NICON of $NDESK, $NLIVE live-medium-only entry hidden)"
else
    bad "the desktop drew $NICON icons for $NDESK launchers ($NLIVE of them live-medium-only, so $NEXP expected)"
fi

# ---- 3. THE MISSES, NAMED ------------------------------------------------
# hamscene_icon_code() answers the generic page for a name it does not know,
# which is indistinguishable from "this app wanted the generic page". So
# hamdesktop publishes the unresolved names; any line here is an application
# whose icon silently became the anonymous white rectangle.
UNK=$(grep '^icon-unknown' "$SRC" || true)
if [ -z "$UNK" ]; then
    ok "every shipped Icon= name resolved to a real glyph -- no silent fallbacks"
else
    bad "these Icon= names resolved to the anonymous page glyph:"
    printf '%s\n' "$UNK" | sed 's/^/deicons:      /'
fi

# ---- the pixel arithmetic ------------------------------------------------
# The icon box inside a cell, from user/hamdesktop.ad: CELL_W 84, ICON_W 44,
# ICON_H 38, ICON_INSET_Y 4 -> the box is at (cx + (84-8-44)/2, cy + 4).
ICON_DX=16; ICON_DY=4; ICON_W=44; ICON_H=38
# A rectangle of BARE WALLPAPER at the same scanlines, well right of the two
# icon columns and of anything else on this desktop.
EMPTY_X=900

MEASURE="$WORK/measure.py"
cat >"$MEASURE" <<'PY'
# Reads the framebuffer + hamdesktop's icon table; writes two TSVs:
#   icons.tsv  label  ncolours  pct-painted  fingerprint  pct-differs-from-self
#   pairs.tsv  labelA labelB  pct-of-the-GLYPH-that-differs
#
# THE BACKGROUND HAD TO GO, and finding that out is the reason this comment
# exists. The first version of this file compared the raw 44x38 rectangles.
# It scored 15 PASS ON THE UNFIXED TREE: the desktop wallpaper is a vertical
# gradient, the generic page glyph covers only the middle two thirds of its
# box, and so two icons that were byte-for-byte THE SAME PICTURE differed in
# 34% of their pixels -- entirely in the margins, entirely because they sit on
# different scanlines. A gate that cannot fail is not a gate, and that one was
# measuring the wallpaper.
#
# So every rect is NORMALISED against the bare wallpaper at its own scanlines
# (a rectangle of the same shape taken from an empty part of the desktop):
# a pixel equal to its background becomes None. What is left is the GLYPH, in
# a form that no longer knows which row it was drawn on -- two copies of one
# picture at different heights normalise to identical arrays and compare 0%.
import sys, hashlib
W, H = int(sys.argv[1]), int(sys.argv[2])
DX, DY, IW, IH, EX = (int(v) for v in sys.argv[3:8])
src, fb1, fb2, outdir = sys.argv[8:12]
d = open(fb1, 'rb').read()
d2 = open(fb2, 'rb').read()

icons = []
for ln in open(src):
    f = ln.split(None, 3)
    if len(f) == 4 and f[0] == 'icon':
        icons.append((f[3].strip(), int(f[1]) + DX, int(f[2]) + DY))

def rect(buf, x, y):
    px = []
    for j in range(y, min(y + IH, H)):
        row = j * W * 4
        for i in range(x, min(x + IW, W)):
            o = row + i * 4
            px.append(buf[o:o+3])
    return px

def glyph(buf, x, y):
    """The rect with its own background subtracted -- see the note above."""
    r = rect(buf, x, y)
    bare = rect(buf, EX, y)
    return [None if k < len(bare) and p == bare[k] else p
            for k, p in enumerate(r)]

def pctdiff(a, b):
    n = min(len(a), len(b))
    if n == 0:
        return 0
    return sum(1 for k in range(n) if a[k] != b[k]) * 100 // n

table = []
with open(outdir + '/icons.tsv', 'w') as f:
    for label, x, y in icons:
        g = glyph(d, x, y)
        painted = sum(1 for p in g if p is not None) * 100 // max(1, len(g))
        ncol = len(set(p for p in g if p is not None))
        fp = hashlib.md5(repr(g).encode()).hexdigest()[:12]
        self2 = pctdiff(g, glyph(d2, x, y))      # the negative control
        f.write('%s\t%d\t%d\t%s\t%d\n' % (label, ncol, painted, fp, self2))
        table.append((label, g))

with open(outdir + '/pairs.tsv', 'w') as f:
    for i in range(len(table)):
        for j in range(i + 1, len(table)):
            f.write('%s\t%s\t%d\n'
                    % (table[i][0], table[j][0],
                       pctdiff(table[i][1], table[j][1])))
PY
python3 "$MEASURE" "$FBW" "$FBH" "$ICON_DX" "$ICON_DY" "$ICON_W" "$ICON_H" \
        "$EMPTY_X" "$SRC" "$WORK/frame1.raw" "$WORK/frame2.raw" "$WORK" \
        >"$WORK/measure.log" 2>&1 || {
    bad "the pixel measurement itself failed"; cat "$WORK/measure.log" >&2
    done_report; exit 1; }

# ---- 4. SOMETHING WAS ACTUALLY PAINTED -----------------------------------
BLANK=$(awk -F'\t' '$3 < 25 { print $1 " (" $3 "% of its box painted)" }' \
        "$WORK/icons.tsv")
if [ -z "$BLANK" ]; then
    ok "every icon painted over at least a quarter of the box it was given"
else
    bad "these icons barely changed the pixels they cover -- they drew nothing:"
    printf '%s\n' "$BLANK" | sed 's/^/deicons:      /'
fi

# ---- 5. NOT ONE FLAT BLOCK -----------------------------------------------
FLAT=$(awk -F'\t' '$2 < 4 { print $1 " (" $2 " colours)" }' "$WORK/icons.tsv")
if [ -z "$FLAT" ]; then
    ok "every icon carries at least 4 distinct colours -- none is a plain rectangle"
else
    bad "these icons are near-flat rectangles:"
    printf '%s\n' "$FLAT" | sed 's/^/deicons:      /'
fi

# ---- 6. THE HEADLINE: NO TWO APPLICATIONS DRAW THE SAME PICTURE ----------
NFP=$(cut -f4 "$WORK/icons.tsv" | sort -u | wc -l)
NROW=$(wc -l <"$WORK/icons.tsv")
if [ "$NFP" = "$NROW" ] && [ "$NROW" -gt 0 ]; then
    ok "all $NROW desktop icons are DIFFERENT PICTURES ($NFP distinct fingerprints)"
else
    bad "THE REPORTED BUG: $NROW icons render as only $NFP distinct pictures. Sharing a picture:"
    awk -F'\t' '{ c[$4] = c[$4] ", " $1 } END { for (k in c) if (c[k] ~ /,.*,/) print substr(c[k], 3) }' \
        "$WORK/icons.tsv" | sed 's/^/deicons:      /'
fi

# The weakest pair, whoever it is. A distinct fingerprint is not enough: two
# icons that differ in 3% of their pixels are the SAME PICTURE to a person,
# which is the complaint. (Labels contain spaces, so the fields are cut by
# tab, never by `read`.)
WEAK=$(sort -t'	' -k3,3n "$WORK/pairs.tsv" | head -1)
WA=$(printf '%s' "$WEAK" | cut -f1)
WB=$(printf '%s' "$WEAK" | cut -f2)
WP=$(printf '%s' "$WEAK" | cut -f3)
if [ "${WP:-0}" -ge 15 ]; then
    ok "even the most similar pair on the desktop differs in $WP% of its pixels ($WA vs $WB)"
else
    bad "$WA and $WB differ in only $WP% of their pixels -- to a person they are the same icon"
fi

# ---- 7. THE PAIRS THE OWNER WAS LOOKING AT -------------------------------
pairpct() {   # pairpct <labelA> <labelB>
    awk -F'\t' -v a="$1" -v b="$2" \
        '($1 == a && $2 == b) || ($1 == b && $2 == a) { print $3; found = 1 }
         END { if (!found) print "-1" }' "$WORK/pairs.tsv" | head -1
}
namedpair() {  # namedpair <labelA> <labelB>
    local p; p="$(pairpct "$1" "$2")"
    if [ "$p" = "-1" ]; then
        info "no icons labelled '$1' and '$2' on this desktop -- pair not measured"
    elif [ "$p" -ge 15 ]; then
        ok "$1 and $2 are different pictures ($p% of their pixels differ)"
    else
        bad "THE REPORTED BUG: $1 and $2 differ in only $p% of their pixels"
    fi
}
# Each of these five pairs drew ONE picture before this gate existed:
# the first three because both names were unknown to hamscene_icon_code and
# fell to the generic page; the last two because the two .desktop files
# literally named the same Icon=.
namedpair Spreadsheet Presentation
namedpair "Word Processor" "Video Player"
namedpair "Audio Player" "Video Player"
namedpair "Text Editor" Notes
namedpair "Log Viewer" "System Monitor"

# ---- 8. THE NEGATIVE CONTROL ---------------------------------------------
# Everything above rests on "these two rectangles differ". A metric that
# called every pair of rectangles different would satisfy all of it. So:
# the SAME icon, in two frames a second and a half apart, must be ~identical.
NOISY=$(awk -F'\t' '$5 > 2 { print $1 " (" $5 "% differs from itself)" }' \
        "$WORK/icons.tsv")
if [ -z "$NOISY" ]; then
    ok "NEGATIVE CONTROL: every icon compared with itself across two frames is <=2% different -- the metric above is measuring the drawing, not noise"
else
    bad "the frames are not stable, so the differences above prove nothing:"
    printf '%s\n' "$NOISY" | sed 's/^/deicons:      /'
fi

info "the icon table:"
sed 's/^/deicons:      /' "$WORK/icons.tsv"

# The private /tmp dies with the run, so a caller that wants the frame it just
# measured (to look at it, which is how this bug was reported in the first
# place) names a directory OUTSIDE the shadowed paths and gets the raw BGRA
# framebuffer and the icon table copied there.
if [ -n "${ICONS_SHOT:-}" ]; then
    mkdir -p "$ICONS_SHOT" && cp "$WORK/frame1.raw" "$WORK/icons.tsv" \
        "$WORK/pairs.tsv" "$ICONS_SHOT/" && \
        info "frame + icon table copied to $ICONS_SHOT"
fi
done_report
