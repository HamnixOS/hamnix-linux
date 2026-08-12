#!/usr/bin/env bash
# The scanout gate must REFUSE without the supervision assertion, and must do
# so BEFORE it can possibly take DRM master. Run offscreen.
set -uo pipefail
cd /home/david/.hamnix-build/vk-present-readback
W="$(mktemp -d -p . sg.XXXXXX)"
export HAMWSYS="$W/s" HAMWSYS_BB="$W/b" HAMWSYS_IMG="$W/i"
export HAMFB_FILE="$W/fb.raw" HAMFB_GEOM=1280x800
: >"$W/in"; export HAMWSYSD_INPUT="$W/in"
export VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/nvidia_icd.json
echo "--- HAMNIX_WSYSD_SCANOUT=1 with NO supervision assertion:"
HAMNIX_WSYSD_SCANOUT=1 timeout 20 ./bin/wsysd -bench 2 2>&1 | head -8
echo "--- no scanout requested at all (the default, must be unchanged):"
timeout 20 ./bin/wsysd -bench 2 2>&1 | grep -E "vk backend|SCANOUT|writeback" | head -4
rm -rf "$W"
