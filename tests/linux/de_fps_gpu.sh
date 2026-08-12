#!/usr/bin/env bash
# tests/linux/de_fps_gpu.sh — THE PATH NO MACHINE HAS EVER RUN, MEASURED.
#
# WHY THIS EXISTS
# ===============
# user/wsysd.ad has a real Vulkan backend, and the shipped image has never
# used it: the image stages only the venus ICD, which enumerates nothing, so
# vk_set_backend(VK_BACKEND_LINUX) fails and every desktop anyone has run has
# been on the software rasterizer. "The GPU path is presumably faster" was
# therefore an untested belief about the only part of the compositor nobody
# had ever executed. This gate executes it.
#
# THE ANSWER IS THAT IT IS 13x SLOWER AND BURNS A CORE, AND WHERE
# ===============================================================
# On this host (RTX 3090, zero-copy 1, device-local 1 — the configuration the
# code treats as the good one, and it says so out loud) against the identical
# offscreen desktop, identical geometry, back to back:
#
#                          software         GPU        ratio
#   sustained, pointer      60.9 fps      6.5 fps       0.11x
#   sustained, drag         52.4 fps      4.1 fps       0.08x
#   input->pixel p50         8.8 ms     112.5 ms         13x worse
#   wsysd cpu, dragging      15 %          93 %
#   wsysd cpu, IDLE          1.2 %         76 %
#
# and wsysd's own `-bench 60` breakdown says exactly where it goes:
#
#   software   us/frame total   649   clear 479  cursor   1  present    169
#   GPU        us/frame total 70105   clear 546  cursor 107  present  69451
#
# THE RASTERIZATION IS NOT THE PROBLEM. `clear` — the part the GPU actually
# does — is 546 us against the CPU's 479, i.e. the same. The entire loss, 410x
# of it, is in `present`, and present is present_rows(): the CPU reading the
# composite and write(2)ing it to /dev/fb.
#
# That is a direct consequence of THE ZERO-COPY BINDING. vk_arm() sets
#
#     comp_base = fb          # "From here the composite IS device memory."
#
# which is a win for anything that only WRITES the composite from the device,
# and a catastrophe for anything that READS it from the CPU — and something
# always does, because /dev/fb is a separate destination that the compositor
# has to copy into. So every frame drags 4 MiB back across PCIe out of
# device-local VRAM, uncached, and 0.17 ms becomes 69 ms. The cursor path is
# the same story at the same ratio: 5 us becomes 3107 us, because
# cursor_save_under() and cursor_restore_under() read and write the composite
# from the CPU by construction.
#
# SO THIS IS NOT "THE GPU IS SLOW". It is: a compositor whose final step is a
# CPU copy-out cannot put its composite in device-local memory. Either the
# present has to happen on the device (scanout from the same buffer, or a
# device-side blit into the display's), or the composite has to stay in host
# memory and the device has to write into it. Nothing here is evidence about
# which; it is evidence that the current arrangement of the two costs 69 ms a
# frame and that no one had run it.
#
# SAFETY. Offscreen only: /dev/fb is a plain file (HAMFB_FILE) and input is a
# file of evdev records. NO KMS, NO DRM MASTER, NO MODESET — nothing here
# opens /dev/dri/card0 for output, and the machine owner's screen cannot be
# reached from inside the namespace this runs in. GPU COMPUTE ONLY, which is
# what the Vulkan backend uses.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

. tests/linux/private_ns.sh
priv_ns_reexec "$@"
. tests/linux/reap.sh

WORK="${GPU_WORK:-$(mktemp -d -p "${TMPDIR:-/tmp}" defpsgpu.XXXXXX)}"
mkdir -p "$WORK"
reap_track "$WORK/reaped"
KEEP="${GPU_KEEP:-0}"
GEOM="${HAMFB_GEOM:-1280x800}"
SECS="${GPU_SECONDS:-8}"
TRIALS="${GPU_TRIALS:-40}"
ICD="${GPU_ICD:-/usr/share/vulkan/icd.d/nvidia_icd.json}"

pass=0; fail=0
ok()   { echo "gpupath: PASS $*"; pass=$((pass+1)); }
bad()  { echo "gpupath: FAIL $*"; fail=$((fail+1)); }
info() { echo "gpupath: INFO $*"; }
skip() { echo "gpupath: SKIP $*"; }
cleanup() { reap_all; [ "$KEEP" = 1 ] || rm -rf "$WORK"; }
reap_on_exit cleanup
done_report() { echo "gpupath: $pass passed, $fail failed"; [ "$fail" = 0 ]; }

[ -r "$ICD" ] || { skip "no $ICD on this host -- there is no GPU path to measure"
                   done_report; exit 0; }

BINDIR="${FPS_BIN_DIR:-$WORK/bin}"
if [ -z "${FPS_BIN_DIR:-}" ]; then
    mkdir -p "$BINDIR"
    for t in wsysd:user/wsysd.ad cat:user/cat.ad hamdesktop:user/hamdesktop.ad \
             hampanelscene:user/hampanelscene.ad \
             de_dragload:tests/linux/de_dragload.ad; do
        n="${t%%:*}"; s="${t#*:}"
        scripts/hamlinux_build.sh "$s" "$BINDIR/$n" >"$WORK/$n.build.log" 2>&1 || {
            bad "could not build $s"; done_report; exit 1; }
    done
fi

export HAMWSYS="$WORK/wsys.shm" HAMWSYS_BB="$WORK/wsys.bb"
export HAMWSYS_IMG="$WORK/wsys.img"
export HAMFB_FILE="$WORK/fb.raw" HAMFB_GEOM="$GEOM"
: >"$WORK/input.evdev"; export HAMWSYSD_INPUT="$WORK/input.evdev"
mkdir -p "$WORK/noicd"

# ---- 1. THE PER-FRAME BREAKDOWN, BOTH PATHS, wsysd'S OWN NUMBERS ---------
echo "gpupath: ---- wsysd -bench 60, both backends -------------------------"
VK_ICD_FILENAMES="$WORK/noicd/none.json" "$BINDIR/wsysd" -bench 60 \
    >"$WORK/bench_sw.txt" 2>&1
VK_ICD_FILENAMES="$ICD" "$BINDIR/wsysd" -bench 60 >"$WORK/bench_gpu.txt" 2>&1
grep -h "vk backend\|us/frame\|cursor-only" "$WORK/bench_sw.txt" | sed 's/^/gpupath:   SW  /'
grep -h "vk backend\|us/frame\|cursor-only" "$WORK/bench_gpu.txt" | sed 's/^/gpupath:   GPU /'

if ! grep -q "vk backend GPU" "$WORK/bench_gpu.txt"; then
    skip "the GPU backend did not arm here ($(grep -m1 'vk backend' "$WORK/bench_gpu.txt")) -- refusing to report software numbers as GPU ones"
    done_report; exit 0
fi
ok "the GPU backend armed: $(grep -m1 'vk backend GPU' "$WORK/bench_gpu.txt" | sed 's/^wsysd: //')"

field() { sed -n "s/.*$2 \([0-9]*\).*/\1/p" "$1" | head -1; }
SW_TOT="$(field "$WORK/bench_sw.txt" total)";   GPU_TOT="$(field "$WORK/bench_gpu.txt" total)"
SW_PRE="$(field "$WORK/bench_sw.txt" present)"; GPU_PRE="$(field "$WORK/bench_gpu.txt" present)"
SW_CLR="$(field "$WORK/bench_sw.txt" clear)";   GPU_CLR="$(field "$WORK/bench_gpu.txt" clear)"
info "per frame: total ${SW_TOT}us -> ${GPU_TOT}us; clear ${SW_CLR}us -> ${GPU_CLR}us; present ${SW_PRE}us -> ${GPU_PRE}us"
if [ "${GPU_PRE:-0}" -gt "$(( ${GPU_CLR:-1} * 10 ))" ]; then
    ok "the cost is LOCALISED and it is not the rasterizer: clear (what the device does) is ${GPU_CLR}us against the CPU's ${SW_CLR}us, while present (the CPU reading the composite back out of device-local VRAM to write /dev/fb) is ${GPU_PRE}us against ${SW_PRE}us"
else
    info "present is not the dominant term on this host -- the attribution in this file's header does not hold here and the header must be re-read against these numbers"
fi

# ---- 2. THE LIVE DESKTOP ON THE GPU PATH --------------------------------
echo
echo "gpupath: ---- the same desktop, on the GPU ------------------------"
VK_ICD_FILENAMES="$ICD" "$BINDIR/wsysd" </dev/null >"$WORK/wsysd.log" 2>&1 &
WP=$!; reap_add "$WP"
for _ in $(seq 1 100); do [ -s "$HAMFB_FILE" ] && break; sleep 0.1; done
[ -s "$HAMFB_FILE" ] || { bad "wsysd produced no framebuffer on the GPU path"
                          done_report; exit 1; }
"$BINDIR/hamdesktop"    </dev/null >"$WORK/d.log" 2>&1 & reap_add $!
"$BINDIR/hampanelscene" </dev/null >"$WORK/p.log" 2>&1 & reap_add $!
sleep 5
DRV="python3 tests/linux/de_fps_driver.py --fb $HAMFB_FILE --input $HAMWSYSD_INPUT \
     --cat $BINDIR/cat --pid $WP --geom $GEOM"

# The instrument's `counting` selftest spaces its moves 50 ms apart, which
# assumes a frame is shorter than that. Here a frame is 70 ms, so THAT
# ASSUMPTION is what fails, not the instrument -- and the failure is itself
# the finding. The other three selftests are the ones that establish the
# clock is attached to the frame, and they are the ones required to pass.
$DRV --mode selftest >"$WORK/selftest.txt" 2>&1 || true
sed 's/^/gpupath:   /' "$WORK/selftest.txt"
# EACH SELFTEST IS CHECKED BY ITS *FAIL* COUNT, NOT BY WHETHER A PASS EXISTS.
# The first version of this loop was `grep -q "PASS  stopped"`, and `stopped`
# runs TWICE (100 ms and 250 ms). On this path the 250 ms one was lost and the
# 100 ms one passed, so the grep found its PASS and this gate printed
#     gpupath: PASS instrument: stopped
# over the top of a FAIL two lines above it. A gate that reports the pass it
# can find rather than the failure it has is the same success-shaped answer
# NORTH_STAR.md is about, committed by the file that was written to prevent
# it. Count the FAILs.
for t in no-input fires stopped; do
    nfail="$(grep -c "FAIL  $t" "$WORK/selftest.txt" || true)"
    if [ "${nfail:-0}" -eq 0 ]; then
        ok "instrument: $t (no failures across $(grep -c "  $t" "$WORK/selftest.txt") run(s))"
    else
        bad "instrument: $t failed ${nfail} time(s) on the GPU path -- its numbers are not usable"
    fi
done
if grep -q "FAIL  counting" "$WORK/selftest.txt"; then
    info 'the `counting` selftest fails here BY BEING RIGHT: it spaces 20 moves'
    info '50 ms apart and expects ~20 frames; a frame on this path takes 70 ms,'
    info 'so most of them are coalesced. That is the result, not a broken tool.'
fi

info "idle:"; $DRV --mode idle --seconds "$SECS" | sed 's/^/gpupath:   /'
info "pointer at 250 ev/s:"
$DRV --mode fps --seconds "$SECS" --rate 250 --tag "GPU pointer" | sed 's/^/gpupath:   /'
"$BINDIR/de_dragload" 480 320 120 300 300 8 >"$WORK/drag.wid" 2>&1 &
DP=$!; reap_add "$DP"
sleep 3
info "a window dragging (full frames):"
$DRV --mode fps --seconds "$SECS" --rate 0 --tag "GPU drag" | sed 's/^/gpupath:   /'
kill "$DP" 2>/dev/null; sleep 1; kill -9 "$DP" 2>/dev/null
sleep 1
info "input->pixel, $TRIALS trials:"
$DRV --mode latency --trials "$TRIALS" --tag "GPU input->pixel" | sed 's/^/gpupath:   /'

info "compare tests/linux/de_fps_latency.sh for the same measurements on the"
info "software path -- that is the one every shipped desktop actually runs."
done_report
