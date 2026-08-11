#!/usr/bin/env bash
# scripts/bench_vk_linux_device.sh — THE ONE COMMAND to run on the day this
# backend meets a real GPU.
#
#   scripts/bench_vk_linux_device.sh                     # whatever ICD is default
#   VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/nvidia_icd.json \
#       scripts/bench_vk_linux_device.sh                 # a named device
#
# It builds tests/linux/vk_linux_test.ad, checks the frames are byte-identical
# to the software rasterizer AT EVERY LEVER SETTING, and then sweeps the two
# levers that move the device-independent counters without moving a pixel:
#
#   HAMNIX_VK_MAX_BATCH=N    dispatches   (=1 is one dispatch per op)
#   HAMNIX_VK_NO_COVCACHE=1  staged words (the glyph coverage cache off)
#
# WHY A SWEEP AND NOT A NUMBER. A single GPU-vs-SW figure answers "is it
# faster here", which is worth knowing once. The sweep answers the question
# this backend was actually tuned against: **what does a dispatch cost on this
# device, and what does a staged word cost?** Those two slopes are what say
# whether the six optimisations in docs/vk_linux_backend.md were bought at the
# right price, and they are the only part of a measurement here that transfers
# to the next device.
#
# On lavapipe (docs/vk_linux_backend.md §"What could be measured here") the
# answers were: ~17.7 us per dispatch, and a staged word costs nothing at all
# because the arena IS host memory. A GPU should move BOTH: a dispatch is
# cheaper, and a staged word is only free while the frame is host-visible.
#
# HOST RULE: this script does NOT force the software ICD, because its whole
# purpose is to be pointed at real silicon. On the dev host, use the gate
# (scripts/test_vk_linux.sh), which does force it.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

OUT="${BENCH_VK_OUT:-build/host}"
BIN="$OUT/vk_linux_test"
REPEATS="${BENCH_VK_REPEATS:-3}"

mkdir -p "$OUT"
if [ ! -x "$BIN" ] || [ tests/linux/vk_linux_test.ad -nt "$BIN" ] \
        || [ user/linux-vk.c -nt "$BIN" ]; then
    ./scripts/hamlinux_build.sh tests/linux/vk_linux_test.ad "$BIN" \
        user/linux-vk.c -ldl >/dev/null || { echo "FAIL: could not build"; exit 1; }
fi

echo "[bench] ICD: ${VK_ICD_FILENAMES:-<loader default>}"
HDR="$("$BIN" 2>/dev/null | grep -E '^VK_DEVICE|^FRAME_DEVICE_LOCAL')"
[ -n "$HDR" ] || { echo "SKIP: the backend did not come up (no device)"; exit 0; }
echo "$HDR" | sed 's/^/[bench] /'

# A CPU ICD is not what this script is for; say so rather than let someone
# quote the number as a GPU measurement six months from now.
if echo "$HDR" | grep -q '^VK_DEVICE_IS_SILICON 0'; then
    echo "[bench] NOTE: this device is a CPU ICD. Every number below is a"
    echo "[bench]       measurement of a CPU rasterizer reached through Vulkan."
fi

fail=0
printf '\n%-18s %-8s %7s %7s %6s %6s %5s %8s %s\n' \
    lever frame gpu_us sw_us disp bars staged reuse identical

# one run -> one row per frame; identity is asserted, not reported
row() {
    local lbl="$1"; shift
    local out; out="$(env "$@" "$BIN" 2>/dev/null)"
    local k
    for k in BENCH_FILLS_1280x800 BENCH_DE_TEXT_1280x800; do
        echo "$out" | grep -q "^$k PASS byte-identical" || {
            echo "FAIL: $k was NOT byte-identical at $lbl"; fail=1; }
        # shellcheck disable=SC2086
        set -- $(echo "$out" | grep "^$k GPU_US")
        [ $# -ge 19 ] || continue
        printf '%-18s %-8s %7s %7s %6s %6s %5s %8s %s\n' \
            "$lbl" "$(echo "$k" | sed 's/BENCH_//;s/_1280x800//')" \
            "$3" "$5" "${11}" "${15}" "${17}" "${19}" ok
    done
}

# --- lever 1: dispatches, at identical pixels and identical work ----------
for b in 1 2 4 8 16 32 64 256 1024; do
    row "maxbatch=$b" "HAMNIX_VK_MAX_BATCH=$b"
done
# --- lever 2: staged words ------------------------------------------------
row "nocovcache" "HAMNIX_VK_NO_COVCACHE=1"
# --- and the shipped default, repeated, so the noise is visible -----------
i=1
while [ "$i" -le "$REPEATS" ]; do
    row "default #$i" "HAMNIX_VK_BENCH_RUN=$i"
    i=$((i+1))
done

# --- the slope, which is the number worth carrying to the next device -----
one="$(HAMNIX_VK_MAX_BATCH=1 "$BIN" 2>/dev/null | grep '^BENCH_DE_TEXT_1280x800 GPU_US')"
all="$("$BIN" 2>/dev/null | grep '^BENCH_DE_TEXT_1280x800 GPU_US')"
# shellcheck disable=SC2086
set -- $one; U1="$3"; D1="${11}"
# shellcheck disable=SC2086
set -- $all; U2="$3"; D2="${11}"
if [ -n "${U1:-}" ] && [ -n "${U2:-}" ] && [ "${D1:-0}" -gt "${D2:-0}" ]; then
    echo
    echo "[bench] DE+text frame: $D2 dispatches -> ${U2} us, $D1 dispatches -> ${U1} us"
    echo "[bench] PER-DISPATCH COST on this device:" \
         "$(( (U1 - U2) * 1000 / (D1 - D2) )) ns"
    echo "[bench] (lavapipe answered 17700 ns; that is the comparison, not the target)"
fi

[ "$fail" -eq 0 ] || { echo "BENCH_VK_LINUX FAIL"; exit 1; }
echo "BENCH_VK_LINUX PASS (byte-identical at every lever setting)"
