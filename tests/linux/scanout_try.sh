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
# Minimal: just wsysd, on the display, under the watchdog, log to stdout.
set -uo pipefail
cd /home/david/.hamnix-build/vk-present-readback
W="$(mktemp -d -p . st.XXXXXX)"
export HAMWSYS="$W/s" HAMWSYS_BB="$W/b" HAMWSYS_IMG="$W/i"
: >"$W/in"; export HAMWSYSD_INPUT="$W/in"
export VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/nvidia_icd.json
export HAMNIX_WSYSD_SCANOUT=1 HAMNIX_WSYSD_SCANOUT_SUPERVISED=1
unset HAMFB_FILE
./kms_watchdog.sh "${WD:-25}" ./bin/wsysd 2>&1 | sed 's/^/   /'
rm -rf "$W"
