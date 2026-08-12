#!/usr/bin/env bash
# tests/linux/wsys_image.sh — does a named image actually DRAW?
#
#   hamimgscene -> 'I' verb on /dev/wsys/<wid>/draw/ctl -> the named-image
#   store -> <wid>/draw/images + <wid>/draw/image/<name> -> wsysd -> /dev/fb
#
# This is the end-to-end evidence for the draw/ctl 'I' verb.  The whole reason
# the verb was missing for the entire port without anyone noticing is that
# every layer answered success while nothing was drawn, so this probe does not
# ask any layer whether it worked: it reads the PIXELS OUT OF THE FRAMEBUFFER
# and checks that the picture is there.
#
# hamimgscene's 32x32 test image is a red 2px border around a blue field with
# a green diagonal and a translucent top-right corner, drawn twice -- once at
# natural size at (150,34) and once scaled to 128x128 at (150,92), both in
# window coordinates.  Those three colours in those three places are what is
# checked, because "some pixels changed" is exactly the kind of evidence that
# would have passed before this verb existed.
#
# Entirely offscreen (HAMFB_FILE) -- it never touches the host's display, and
# the software Vulkan ICD is forced because wsysd has a real Vulkan backend and
# this host's GPU belongs to someone.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

# THE MACHINE THIS RUNS ON IS NOT SCRATCH.
#
# It sets HAMWSYS and HAMWSYS_BB, so the segment is already per-run; what is not
# per-run is /srv/wsys and /dev/shm/hamnix-* if either export is ever dropped, and
# $WORK itself.
#
# The names that matter are compiled into the binaries, not written here, so no
# care taken in this script can move them; the containment is the namespace.
# tests/linux/private_ns.sh has the table and the incident that bought it. This
# must come before anything that makes a file under /tmp, $WORK included, and
# before reap.sh, whose registry is itself a mktemp under /tmp.
. tests/linux/private_ns.sh
priv_ns_reexec "$@"

WORK="${WSYSIMG_WORK:-$(mktemp -d -p "${TMPDIR:-/tmp}" wsysimg.XXXXXX)}"
mkdir -p "$WORK"
KEEP="${WSYSIMG_KEEP:-0}"
GEOM="${HAMFB_GEOM:-1280x800}"
SHOT="${WSYSIMG_SHOT:-$WORK/shot.png}"

# EVERY shared file pinned into $WORK.  /srv/wsys, /srv/wsys.bb and now
# /srv/wsys.img are one per HOST by default and outlive the process that made
# them; two runs sharing them hand each other stale slots.
# docs/steam_namespace.md §11.
export HAMWSYS="$WORK/wsys.shm"
export HAMWSYS_BB="$WORK/wsys.bb"
export HAMWSYS_IMG="$WORK/wsys.img"
export HAMFB_FILE="$WORK/fb.raw"
export HAMFB_GEOM="$GEOM"
[ -r /usr/share/vulkan/icd.d/lvp_icd.json ] && \
    export VK_ICD_FILENAMES="${VK_ICD_FILENAMES:-/usr/share/vulkan/icd.d/lvp_icd.json}"

pass=0; fail=0
ok()   { echo "wsysimg: PASS $*"; pass=$((pass+1)); }
bad()  { echo "wsysimg: FAIL $*"; fail=$((fail+1)); }
info() { echo "wsysimg: INFO $*"; }

WSYSDPID=""; APPPID=""
cleanup() {
    for p in $APPPID $WSYSDPID; do [ -n "${p:-}" ] && kill "$p" 2>/dev/null; done
    sleep 0.3
    for p in $APPPID $WSYSDPID; do [ -n "${p:-}" ] && kill -9 "$p" 2>/dev/null; done
    [ "$KEEP" = 1 ] || rm -rf "$WORK"
}
trap cleanup EXIT
# A bare EXIT trap does not run when the shell is killed by a signal, so a
# gate stopped by `timeout` (TERM) or ^C (INT) skipped its cleanup entirely.
# Re-exit on those, which makes the EXIT trap above run on every path out.
trap 'exit 130' INT TERM HUP

for t in wsysd:user/wsysd.ad hamimgscene:user/hamimgscene.ad; do
    name="${t%%:*}"; src="${t#*:}"
    scripts/hamlinux_build.sh "$src" "$WORK/$name.elf" \
        >"$WORK/$name.build.log" 2>&1 || {
        bad "could not build $src"; tail -20 "$WORK/$name.build.log" >&2
        echo "wsysimg: $pass passed, $fail failed"; exit 1; }
done
ok "wsysd and hamimgscene both build"

"$WORK/wsysd.elf" </dev/null >"$WORK/wsysd.log" 2>&1 &
WSYSDPID=$!
for _ in $(seq 1 40); do [ -s "$WORK/fb.raw" ] && break; sleep 0.1; done
sleep 1

"$WORK/hamimgscene.elf" </dev/null >"$WORK/app.log" 2>&1 &
APPPID=$!
sleep 3

# 1. The app must not have said FATAL.  Before the verb existed it printed the
#    whole ENOSYS explanation and exited 2.
if grep -q FATAL "$WORK/app.log"; then
    bad "hamimgscene reported a fatal error:"
    sed 's/^/wsysimg:      /' "$WORK/app.log"
else
    ok "hamimgscene uploaded its image and committed without a refusal"
fi

# 2. The store must actually hold it, under the window's own directory.
IMGLINE=""
if [ -s "$WORK/wsys.img" ]; then
    IMGLINE="$(strings -n 3 "$WORK/wsys.img" 2>/dev/null | grep -x logo | head -1)"
fi
[ -n "$IMGLINE" ] && ok "the named-image segment holds an image called 'logo'" \
                  || bad "no image named 'logo' in $WORK/wsys.img"

# 3. THE PIXELS.  This is the only check that separates "every layer returned
#    success" from "a human can see a picture".
python3 - "$WORK/fb.raw" "$GEOM" "$SHOT" <<'PY'
import sys, zlib, struct
raw = open(sys.argv[1], 'rb').read()
w, h = (int(x) for x in sys.argv[2].split('x'))
def px(x, y):
    o = (y * w + x) * 4
    b, g, r = raw[o], raw[o+1], raw[o+2]      # /dev/fb is XRGB8888
    return r, g, b

# hamimgscene's window is 320x260 at (120,90) -- the size IT states with a
# `geometry` verb, which is exactly the rectangle it paints. It used to state
# nothing and take the compositor's 640x480 default, so everything outside
# 320x260 reached the screen as unpainted black; tests/linux/wsys_cover.sh is
# the gate on that. It is undecorated, so window (wx,wy) is screen
# (120+wx, 90+wy) either way and every check below is unchanged.
OX, OY = 120, 90
def near(p, r, g, b, tol=60):
    return abs(p[0]-r) <= tol and abs(p[1]-g) <= tol and abs(p[2]-b) <= tol

checks = [
    # (label, screen x, y, expected r,g,b) -- from _build_image_verb's pattern.
    ("natural 32x32: red border, top-left",  OX+151, OY+35,  220, 40, 40),
    ("natural 32x32: blue field",            OX+160, OY+50,   40, 70, 200),
    ("scaled 128x128: red border, top-left", OX+154, OY+96,  220, 40, 40),
    ("scaled 128x128: blue field",           OX+200, OY+160,  40, 70, 200),
    ("scaled 128x128: green diagonal",       OX+214, OY+156,  40, 200, 60),
]
bad = 0
for label, x, y, r, g, b in checks:
    p = px(x, y)
    if near(p, r, g, b):
        print(f"wsysimg: PASS {label} -- rgb{p} at ({x},{y})")
    else:
        print(f"wsysimg: FAIL {label} -- wanted ~({r},{g},{b}), got rgb{p} at ({x},{y})")
        bad += 1

# A PNG of the whole screen, so the evidence is something a human can LOOK at
# and not only a list of assertions.
out = bytearray()
for y in range(h):
    out.append(0)
    for x in range(w):
        o = (y * w + x) * 4
        out += bytes((raw[o+2], raw[o+1], raw[o]))
def chunk(tag, payload):
    c = tag + payload
    return struct.pack('>I', len(payload)) + c + struct.pack('>I', zlib.crc32(c))
png = (b'\x89PNG\r\n\x1a\n'
       + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
       + chunk(b'IDAT', zlib.compress(bytes(out), 6))
       + chunk(b'IEND', b''))
open(sys.argv[3], 'wb').write(png)
print(f"wsysimg: INFO screenshot {sys.argv[3]} ({w}x{h})")
sys.exit(1 if bad else 0)
PY
if [ $? -eq 0 ]; then pass=$((pass+5)); else fail=$((fail+1)); fi

# 4. An image nobody uploaded must be NAMED, not silently skipped.  This is the
#    other half of the defect: lib/hamui_host.ad's `slot < 0 -> return 1`.
if grep -q "never uploaded" "$WORK/wsysd.log"; then
    info "wsysd named an unknown image (expected only if something asked for one)"
fi

echo "wsysimg: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
