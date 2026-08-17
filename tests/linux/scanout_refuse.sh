#!/usr/bin/env bash
#
# REGISTRATION, 2026-08-17. Until this date scripts/test_gate_registration.sh
# globbed only scripts/test_*.sh, so this directory was invisible to the gate
# against unregistered gates and every file in it read as coverage without
# being coverage. This gate is ON-DEMAND: not in ci_battery_manifest.txt
# because nobody has measured its host runtime yet, and the battery is 12-way
# sharded under a 50-minute cap -- registering an unmeasured gate is how a
# shard goes from green to timed-out. Measure it, then move it into the
# manifest.
#
# Its host runtime and its pass/fail were NOT measured when this line was
# written. If you make it cheap enough for the battery, add the manifest line
# and delete this block.
#
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
