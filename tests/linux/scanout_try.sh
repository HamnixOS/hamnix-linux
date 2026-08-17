#!/usr/bin/env bash
#
# REGISTRATION, 2026-08-17. Until this date scripts/test_gate_registration.sh
# globbed only scripts/test_*.sh, so this directory was invisible to the gate
# against unregistered gates and every file in it read as coverage without
# being coverage. This gate is ON-DEMAND: not in ci_battery_manifest.txt
# because MEASURED 2026-08-17: it exits 0 in 25 s while printing no PASS, no FAIL and no assertion count at all (737 bytes of output). It is a probe, not a gate -- registering it would add a battery line that cannot go red, which is exactly the false assurance the registration gate exists to prevent.
#
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
