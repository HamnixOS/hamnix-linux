#!/usr/bin/env bash
# scanout_desktop.sh — THE REAL DESKTOP, ON THE DISPLAY, VIA SCANOUT.
#
# wsysd takes DP-1 with a GPU dmabuf and composites entirely on the device.
# There is no framebuffer FILE to sample, so fps comes from wsysd's own live
# phase counters (HAMNIX_WSYSD_BENCH_LIVE), timestamped as they arrive.
#
# SAFETY. wsysd is the watchdog's direct child, so the SIGKILL lands on the
# process that holds DRM master -- which is the only recovery that works on
# this driver. Clients are started separately and reaped here.
set -uo pipefail
cd /home/david/.hamnix-build/vk-present-readback
BIN=./bin
SECS="${SECS:-20}"
WD="${WD:-45}"
EVERY="${EVERY:-60}"
W="$(mktemp -d -p . so.XXXXXX)"
export HAMWSYS="$W/s" HAMWSYS_BB="$W/b" HAMWSYS_IMG="$W/i"
: >"$W/in"; export HAMWSYSD_INPUT="$W/in"
export VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/nvidia_icd.json
export HAMNIX_WSYSD_SCANOUT=1 HAMNIX_WSYSD_SCANOUT_SUPERVISED=1
export HAMNIX_WSYSD_BENCH_LIVE="$EVERY"
unset HAMFB_FILE           # a real display, not a file

echo "=== arming watchdog (${WD}s) and starting wsysd on the display"
./kms_watchdog.sh "$WD" "$BIN/wsysd" >"$W/wsysd.log" 2>&1 &
WDPID=$!
sleep 10
if ! grep -q "SCANOUT armed" "$W/wsysd.log"; then
    echo "!!! scanout did not arm:"; sed 's/^/   /' "$W/wsysd.log" | head -20
    wait "$WDPID" 2>/dev/null; rm -rf "$W"; exit 1
fi
sed -n '1,8p' "$W/wsysd.log" | sed 's/^/   /'

"$BIN/hamdesktop" </dev/null >/dev/null 2>&1 & DP=$!
sleep 3
"$BIN/de_dragload" 480 320 160 340 300 8 >/dev/null 2>&1 & GP=$!
sleep "$SECS"

kill "$GP" "$DP" 2>/dev/null; sleep 0.5; kill -9 "$GP" "$DP" 2>/dev/null

echo "=== live phase counters (us per FULL frame, drag load)"
grep "^benchlive: seq" "$W/wsysd.log" | tail -6 | sed 's/^/   /'
echo "=== deriving fps from the dumps: ${EVERY} full frames per dump"
grep -c "^benchlive: seq" "$W/wsysd.log" | awk -v e="$EVERY" -v s="$SECS" \
    '{printf "   %d dumps x %d frames = %d full frames in ~%ds => %.1f fps\n",
      $1, e, $1*e, s, ($1*e)/s}'
wait "$WDPID" 2>/dev/null
echo "=== watchdog returned; console recovery is process death by design"
cp "$W/wsysd.log" ./scanout_desktop.log
rm -rf "$W"
