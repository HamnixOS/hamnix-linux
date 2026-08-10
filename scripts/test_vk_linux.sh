#!/usr/bin/env bash
# scripts/test_vk_linux.sh — the gate for VK_BACKEND_LINUX, the vk spine's
# real-Vulkan rasterization backend on the Linux line.
#
# WHAT IT ASSERTS
#   1. tests/linux/vk_linux_test.ad — the BACKEND is byte-identical to the
#      software rasterizer (lib/vk/vk_2d.ad) for the whole 2D op vocabulary, in
#      BOTH store orders, at a 96x64 edge-case scene and at a 1280x800 DE-shaped
#      frame; and it prints the GPU-vs-SW timings for that frame with and
#      without its text.
#   2. tests/linux/vk_core_linux_test.ad — the SEAM: lib/vk/vk_selftest.ad's
#      software conformance suite still passes, and a vk_core command buffer
#      submitted through vkQueueSubmit produces identical pixels routed or not,
#      including an op with no device path (a self-blit) composited on the CPU
#      mid-frame.
#   3. REFUSE-TO-SW: with the backend forced off, vk_set_backend(VK_BACKEND_LINUX)
#      returns an error and the backend STAYS software. This is the assertion
#      that matters most — a graphics backend that silently pretends is worse
#      than one that is absent.
#
# HOST RULE: never the dev host's real /dev/dri. The gate forces the SOFTWARE
# ICD (lavapipe) unless VK_ICD_FILENAMES is already set by the caller, and
# lavapipe is a real, conformant Vulkan implementation, so every code path
# except actual silicon is exercised. Real-hardware validation happens in the
# VM, not here.
#
# SKIPs cleanly (exit 0) when the Adder compiler or libvulkan is absent.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

OUT=build/host
mkdir -p "$OUT"

[ -x build/cutover/host_ac_llvm.elf ] || [ -x build/cutover/host_ac.elf ] || {
    echo "SKIP: no host_ac.elf (run scripts/_adder_cc.sh adder_cc_bootstrap)"; exit 0; }
ls /usr/lib/x86_64-linux-gnu/libvulkan.so.1 >/dev/null 2>&1 || {
    echo "SKIP: no libvulkan.so.1 on this host"; exit 0; }

export VK_ICD_FILENAMES="${VK_ICD_FILENAMES:-/usr/share/vulkan/icd.d/lvp_icd.json}"
echo "[vk_linux] ICD: $VK_ICD_FILENAMES"

fail=0
note() { echo "[vk_linux] $*"; }

# ---- 1. the backend gate -------------------------------------------------
note "building tests/linux/vk_linux_test.ad"
./scripts/hamlinux_build.sh tests/linux/vk_linux_test.ad "$OUT/vk_linux_test" \
    user/linux-vk.c -ldl || { echo "FAIL: could not build vk_linux_test"; exit 1; }
BACKEND_OUT="$("$OUT/vk_linux_test" 2>/dev/null)"
echo "$BACKEND_OUT"
echo "$BACKEND_OUT" | grep -q "VK_LINUX_GATE PASS" || {
    if echo "$BACKEND_OUT" | grep -q "^SKIP"; then
        note "backend unavailable; the refusal path is still checked below"
    else
        echo "FAIL: backend gate did not pass"; fail=1
    fi
}
# Identity is the standard; assert each case by name so a silently dropped
# comparison cannot masquerade as a pass.
if echo "$BACKEND_OUT" | grep -q "VK_DEVICE "; then
    for k in IDENTITY_RGBA IDENTITY_BGRA BENCH_FILLS_1280x800 BENCH_DE_TEXT_1280x800; do
        echo "$BACKEND_OUT" | grep -q "^$k PASS byte-identical" || {
            echo "FAIL: $k was not byte-identical"; fail=1; }
    done
fi

# ---- 1b. the dispatch budget --------------------------------------------
# ops, dispatches and barriers are DEVICE-INDEPENDENT: an op is an op and a
# dispatch is a dispatch on llvmpipe and on silicon, which is why they and not
# the microseconds are what this backend is optimised against. Assert a
# CEILING rather than an exact number -- the point is that a change which
# quietly reintroduces one-dispatch-per-op, or the bounding-box union that
# bought 60 pipeline barriers a frame for nothing, fails here instead of
# showing up as a slow desktop on hardware nobody here can measure.
if echo "$BACKEND_OUT" | grep -q "^BENCH_DE_TEXT_1280x800 GPU_US"; then
    DISP=$(echo "$BACKEND_OUT" | sed -n 's/.*BENCH_DE_TEXT_1280x800 .* dispatches \([0-9]*\) .*/\1/p')
    BARS=$(echo "$BACKEND_OUT" | sed -n 's/.*BENCH_DE_TEXT_1280x800 .* barriers \([0-9]*\) .*/\1/p')
    note "DE+text frame: ${DISP} dispatches, ${BARS} barriers (1724 ops)"
    [ -n "$DISP" ] && [ "$DISP" -le 30 ] || {
        echo "FAIL: DE+text frame took $DISP dispatches (budget 30; measured 15)"
        fail=1; }
    [ -n "$BARS" ] && [ "$BARS" -le 24 ] || {
        echo "FAIL: DE+text frame needed $BARS barriers (budget 24; measured 12)"
        fail=1; }
fi

# ---- 2. the vk_core seam gate -------------------------------------------
note "building tests/linux/vk_core_linux_test.ad"
./scripts/hamlinux_build.sh tests/linux/vk_core_linux_test.ad "$OUT/vk_core_linux_test" \
    user/linux-vk.c user/linux-vkhost.c -ldl \
    || { echo "FAIL: could not build vk_core_linux_test"; exit 1; }
SEAM_OUT="$("$OUT/vk_core_linux_test" 2>/dev/null)"
echo "$SEAM_OUT"
echo "$SEAM_OUT" | grep -q "SW_SELFTEST PASS" || { echo "FAIL: vk_selftest regressed"; fail=1; }
if echo "$SEAM_OUT" | grep -q "^ROUTER "; then
    echo "$SEAM_OUT" | grep -q "ROUTER_IDENTITY PASS" || {
        echo "FAIL: routed frame differed from the SW replay"; fail=1; }
    echo "$SEAM_OUT" | grep -q "VK_CORE_LINUX_GATE PASS" || {
        echo "FAIL: vk_core seam gate did not pass"; fail=1; }
fi

# ---- 3. refuse-to-SW ------------------------------------------------------
note "checking the backend REFUSES and stays software when it cannot come up"
REFUSE_OUT="$(HAMNIX_VK_DISABLE=1 "$OUT/vk_core_linux_test" 2>/dev/null)"
echo "$REFUSE_OUT" | grep -q "SKIP vk_set_backend(LINUX) refused; backend stayed 0" || {
    echo "FAIL: with the backend disabled, vk_set_backend did not refuse to SW"
    echo "$REFUSE_OUT"; fail=1; }
REFUSE2="$(VK_ICD_FILENAMES=/nonexistent/icd.json "$OUT/vk_core_linux_test" 2>/dev/null)"
echo "$REFUSE2" | grep -q "SKIP vk_set_backend(LINUX) refused; backend stayed 0" || {
    echo "FAIL: with no usable ICD, vk_set_backend did not refuse to SW"
    echo "$REFUSE2"; fail=1; }
note "refusal path OK (both HAMNIX_VK_DISABLE and a bogus ICD)"

if [ "$fail" -ne 0 ]; then
    echo "VK_LINUX_TEST FAIL"
    exit 1
fi
echo "VK_LINUX_TEST PASS"
exit 0
