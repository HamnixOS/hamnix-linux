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
# THE ANSWER WAS THAT IT WAS 13x SLOWER AND BURNED A CORE. IT IS FIXED.
# ======================================================================
# Everything below this block was true and is now HISTORY, kept because a
# measurement whose predecessor cannot be re-run is a claim. Re-run it with
# HAMNIX_VK_FRAME_MEM=device, which restores the exact configuration it
# describes.
#
# THE CAUSE was where the composite LIVED. vk's frame was allocated
# DEVICE_LOCAL unconditionally, which on a discrete card without resizable BAR
# is the PCIe BAR aperture: host-mappable, so nothing failed or warned, and
# uncached, so every CPU read of it was a bus round trip. present_rows()
# write(2)s the whole composite to /dev/fb every frame, so that placement cost
# 66.6 ms per frame -- timed on its own by the `bench: writeback` counter this
# work added, which reports the sys_write loop separately and finds it is
# 96-99% of `present` in every configuration.
#
#   frame placement          writeback/frame   bandwidth
#   DEVICE_LOCAL (the BAR)        66602 us        61 MB/s
#   HOST_VISIBLE|COHERENT         10044 us       407 MB/s
#   HOST_CACHED (now default)       155 us     26417 MB/s
#   software, for scale             163 us     24988 MB/s
#
# AFTER, on this host, same harness, same geometry:
#
#                        before      after     software
#   sustained, pointer   7.5 fps   58.1 fps     61 fps
#   sustained, drag      4.1 fps   39.5 fps     52 fps
#   input->pixel p50    84.3 ms     8.50 ms     8.9 ms
#   wsysd cpu, IDLE       76 %       3.87 %     1.2 %
#
# So this gate's own attribution check now prints "present is not the dominant
# term on this host", which is the correct report and not a regression: the
# term it was built to find is gone. Drag remains 39.5 vs 52 and is NOT
# explained. See docs/vk_scanout_path.md for the ceiling above all of this
# (GPU composites into a dmabuf the display scans out: 12870 fps, zero bytes
# toward the CPU) and for what it would take to put wsysd there.
#
# ---- WHAT FOLLOWS IS THE ORIGINAL FINDING, PRESERVED ------------------
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
# THIS USED TO BE A DIAGNOSTIC AND IS NOW A GATE, and the polarity is
# reversed. When the defect existed, "present dominates" was the FINDING and
# was reported with ok(). It is now the REGRESSION: present dominating means
# the composite is back behind the bus. A check that passes when the bug is
# present is worse than no check.
GPU_WB="$(sed -n 's/.*writeback us\/frame \([0-9]*\).*/\1/p' "$WORK/bench_gpu.txt" | head -1)"
SW_WB="$(sed -n 's/.*writeback us\/frame \([0-9]*\).*/\1/p' "$WORK/bench_sw.txt" | head -1)"
GPU_HC="$(sed -n 's/.*host_cached \([0-9]*\).*/\1/p' "$WORK/bench_gpu.txt" | head -1)"
info "writeback (the sys_write loop alone): SW ${SW_WB}us -> GPU ${GPU_WB}us; frame host_cached ${GPU_HC}"
if [ "${GPU_PRE:-0}" -gt "$(( ${GPU_CLR:-1} * 10 ))" ]; then
    bad "REGRESSION: present is ${GPU_PRE}us against clear ${GPU_CLR}us, i.e. the composite is behind the bus again. The writeback alone is ${GPU_WB}us against software's ${SW_WB}us. Check the frame's placement: host_cached is ${GPU_HC} and must be 1. See docs/vk_scanout_path.md."
else
    ok "the readback is gone: present ${GPU_PRE}us against the CPU path's ${SW_PRE}us, writeback ${GPU_WB}us against ${SW_WB}us, and clear (what the device does) ${GPU_CLR}us against ${SW_CLR}us"
fi
# ---- 1b. DEVICE COMPOSITING MUST STILL PRODUCE THE SOFTWARE'S PIXELS ------
# The compositor can now write the composite entirely with device ops
# (HAMNIX_WSYSD_VKCOMP=1), which is what the scanout path requires. That
# conversion is exactly the kind that yields a frame which looks like a
# desktop and is wrong -- it already rendered a blue window orange once, and
# the cursor did not catch it because both cursor colours are grey.
#
# So this gate runs the pixel comparison, and it is RED WITHOUT THE FIX: with
# the source R/B flip left at the router's default, 867,069 of 1,024,000
# pixels differ. Shown going red in the commit that added it.
echo
echo "gpupath: ---- device compositing, pixel-compared with software -------"
if [ -x tests/linux/pixcmp.sh ]; then
    if PIXCMP_OUT="$WORK/pixcmp.txt" FPS_BIN_DIR="$BINDIR" \
            tests/linux/pixcmp.sh >"$WORK/pixcmp.txt" 2>&1; then
        ok "device compositing: $(grep -m1 'differ in R,G or B' "$WORK/pixcmp.txt" | sed 's/^pixcmp: //')"
    else
        bad "device compositing does NOT match the software rasterizer -- $(grep -m1 'differ in R,G or B' "$WORK/pixcmp.txt" | sed 's/^pixcmp: //'). See $WORK/pixcmp.txt"
    fi
    grep -E "differ|PASS|FAIL" "$WORK/pixcmp.txt" | sed 's/^/gpupath:   /'
else
    info "tests/linux/pixcmp.sh not executable; skipping the pixel gate"
fi

if [ "${GPU_HC:-0}" != 1 ]; then
    bad "the GPU frame is NOT host-cached (host_cached=${GPU_HC:-?}); every present pays the PCIe bus. This is the 13x-slower configuration."
else
    ok "the GPU frame is host-cached, which is what makes the readback an ordinary memory copy"
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
