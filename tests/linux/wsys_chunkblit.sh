#!/usr/bin/env bash
# tests/linux/wsys_chunkblit.sh — does a big blit paint when it is SPLIT across
# write(2) calls?
#
#   wsys_chunkblit -> 'B' header write + 768 row writes on /dev/wsys/<wid>/draw/ctl
#                  -> user/linux-wsys.c's reassembly buffer -> the backbuffer
#                  -> wsysd -> /dev/fb
#
# THE DEFECT THIS GATES
# ---------------------
# linux-wsys.c's draw/ctl arm holds an incomplete draw record in a reassembly
# buffer called `carry` and completes it from the next write. That buffer was
# a fixed 1 MiB array. A one-shot 2 MB blit was already found to be refused by
# it once (no v2 window over ~512x512 had ever painted, the browser included);
# that was fixed by routing COMPLETE records around the buffer, and the buffer
# was left at 1 MiB. Which leaves the split case exactly where it was: a client
# that writes a 3 MB blit in 4 KiB pieces still accumulates it in `carry` and
# still hits the wall at 1 MiB.
#
# tests/linux/wsys_chunkblit.ad is that client. It paints three horizontal
# bands and puts the band boundaries AT the wall — red is the last 256 rows
# that could ever fit in 1 MiB, green and blue are past it — so a run that
# paints red-and-nothing-else, or black, is telling you where it stopped.
#
# WHAT IT PRINTED BEFORE THE FIX (measured, on the 1 MiB fixed array):
#
#   wsys: /dev/wsys/2/draw/ctl: a draw record split across writes exceeds the
#         1048576-byte reassembly buffer (1044498 pending + 4096 now).
#   wsys_chunkblit: rows=768 refused=513 first_refused_row=255 rc=-90
#   chunkblit: FAIL red band   -- wanted ~(220,40,40),  got rgb(0, 0, 0) at (400,100)
#   chunkblit: FAIL green band -- wanted ~(40,200,60),  got rgb(0, 0, 0) at (400,300)
#   chunkblit: FAIL blue band  -- wanted ~(40,70,200),  got rgb(0, 0, 0) at (400,600)
#   chunkblit: 1 passed, 2 failed
#
#   -90 is EMSGSIZE. 1044498 is 18 + 255*4096, so row 255 is exactly where the
#   record crossed 1048576. Note that EVERY band is black, the red one
#   included: a record that never completes is never applied at all, so the
#   window painted nothing rather than painting the part that fitted.
#
# AND AFTER:
#
#   wsys_chunkblit: rows=768 refused=0 first_refused_row=-1 rc=0
#   chunkblit: PASS blue band (well past it) -- rgb(40, 70, 200) at (400,600)
#   chunkblit: 6 passed, 0 failed
#
# This gate does not ask any layer whether the write worked — every layer in
# this stack has answered success while drawing nothing. It reads the PIXELS
# out of the framebuffer.
#
# Entirely offscreen (HAMFB_FILE): it never touches the host's display.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

# THE MACHINE THIS RUNS ON IS NOT SCRATCH. /srv/wsys and /dev/shm/hamnix-* are
# one per HOST if either export is ever dropped, and the names that matter are
# compiled into the binaries, not written here. The containment is the
# namespace; see tests/linux/private_ns.sh for the table and the incident that
# bought it. This must come before anything that makes a file under /tmp.
. tests/linux/private_ns.sh
priv_ns_reexec "$@"
. tests/linux/reap.sh

WORK="${CHUNKBLIT_WORK:-$(mktemp -d -p "${TMPDIR:-/tmp}" chunkblit.XXXXXX)}"
mkdir -p "$WORK"
reap_track "$WORK/reaped"
KEEP="${CHUNKBLIT_KEEP:-0}"
GEOM="${HAMFB_GEOM:-1280x800}"
SHOT="${CHUNKBLIT_SHOT:-$WORK/shot.png}"

export HAMWSYS="$WORK/wsys.shm"
export HAMWSYS_BB="$WORK/wsys.bb"
export HAMWSYS_IMG="$WORK/wsys.img"
export HAMFB_FILE="$WORK/fb.raw"
export HAMFB_GEOM="$GEOM"
export HAMLINUX_DISTRO_RO=1
[ -r /usr/share/vulkan/icd.d/lvp_icd.json ] && \
    export VK_ICD_FILENAMES="${VK_ICD_FILENAMES:-/usr/share/vulkan/icd.d/lvp_icd.json}"

pass=0; fail=0
ok()   { echo "chunkblit: PASS $*"; pass=$((pass+1)); }
bad()  { echo "chunkblit: FAIL $*"; fail=$((fail+1)); }
info() { echo "chunkblit: INFO $*"; }

cleanup() {
    reap_all
    [ "$KEEP" = 1 ] || rm -rf "$WORK"
}
reap_on_exit cleanup

for t in wsysd:user/wsysd.ad chunkblit:tests/linux/wsys_chunkblit.ad; do
    name="${t%%:*}"; src="${t#*:}"
    scripts/hamlinux_build.sh "$src" "$WORK/$name.elf" \
        >"$WORK/$name.build.log" 2>&1 || {
        bad "could not build $src"; tail -20 "$WORK/$name.build.log" >&2
        echo "chunkblit: $pass passed, $fail failed"; exit 1; }
done
ok "wsysd and wsys_chunkblit both build"

"$WORK/wsysd.elf" </dev/null >"$WORK/wsysd.log" 2>&1 &
reap_add $!
for _ in $(seq 1 40); do [ -s "$WORK/fb.raw" ] && break; sleep 0.1; done
sleep 1

"$WORK/chunkblit.elf" live </dev/null >"$WORK/app.log" 2>&1 &
reap_add $!
sleep 3

sed 's/^/chunkblit:      /' "$WORK/app.log"

# 1. THE CLIENT'S OWN VERDICT. Not evidence that pixels landed — it is the one
#    place the old defect was ever mentioned at all — but it names the errno
#    and the row, which is what makes a failure diagnosable.
if grep -q "OK every chunk accepted" "$WORK/app.log"; then
    ok "every one of the 768 row writes was accepted"
elif grep -q "REFUSED" "$WORK/app.log"; then
    bad "the split record was refused: $(grep -o 'rows=.*' "$WORK/app.log" | head -1)"
else
    bad "the client did not reach its verdict at all"
fi

# 2. THE PIXELS. The only check that separates "every layer returned success"
#    from "a human can see a picture".
python3 - "$WORK/fb.raw" "$GEOM" "$SHOT" <<'PY'
import sys, zlib, struct
raw = open(sys.argv[1], 'rb').read()
w, h = (int(x) for x in sys.argv[2].split('x'))
def px(x, y):
    o = (y * w + x) * 4
    b, g, r = raw[o], raw[o+1], raw[o+2]      # /dev/fb is XRGB8888
    return r, g, b

# The window is 1024x768 undecorated at (0,0), so window (x,y) is screen (x,y).
# The bands are the client's, and their boundaries sit at the 1 MiB wall:
# 18 + 256*4096 = 1048594 > 1048576, so row 255 is the last one that could
# ever have been buffered by a 1 MiB `carry`.
def near(p, r, g, b, tol=60):
    return abs(p[0]-r) <= tol and abs(p[1]-g) <= tol and abs(p[2]-b) <= tol

checks = [
    ("red band (inside 1 MiB of carry)",  400, 100, 220,  40,  40),
    ("green band (past 1 MiB of carry)",  400, 300,  40, 200,  60),
    ("blue band (well past it)",          400, 600,  40,  70, 200),
    ("blue band, far right column",      1000, 700,  40,  70, 200),
]
bad = 0
for label, x, y, r, g, b in checks:
    p = px(x, y)
    if near(p, r, g, b):
        print(f"chunkblit: PASS {label} -- rgb{p} at ({x},{y})")
    else:
        print(f"chunkblit: FAIL {label} -- wanted ~({r},{g},{b}), got rgb{p} at ({x},{y})")
        bad += 1

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
print(f"chunkblit: INFO screenshot {sys.argv[3]} ({w}x{h})")
sys.exit(1 if bad else 0)
PY
if [ $? -eq 0 ]; then pass=$((pass+4)); else fail=$((fail+1)); fi

# 3. A REFUSAL MUST BE LOUD. The recurring defect in this tree is a gap that
#    answers something success-shaped, so if the kernel did drop the frame it
#    has to have said so on stderr and returned a negative to the client.
if grep -q "rc=-90\|rc=-" "$WORK/app.log"; then
    if grep -qi "reassembly\|exceeds" "$WORK/app.log" "$WORK/wsysd.log"; then
        info "the refusal was announced as well as returned"
    else
        bad "a write was refused and NOTHING was printed about it"
    fi
fi

echo "chunkblit: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
