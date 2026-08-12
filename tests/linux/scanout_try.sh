#!/usr/bin/env bash
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
