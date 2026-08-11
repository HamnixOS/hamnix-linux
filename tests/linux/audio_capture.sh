#!/usr/bin/env bash
# tests/linux/audio_capture.sh — does /dev/audioin deliver frames?
#
# The companion to tests/linux/audio_tone.sh, and a WEAKER claim, stated
# weakly on purpose.
#
# WHAT THIS CAN PROVE. That opening /dev/audioin brings up the codec's capture
# substream, that it runs at the rate that was asked for, and that a client
# reading it gets the right NUMBER of bytes for the time it read -- 192 bytes
# per millisecond at 48 kHz stereo s16le. A capture path that is not wired up
# at all delivers zero bytes, and that is the failure this catches.
#
# WHAT IT CANNOT PROVE, and no automated run on this tree can. That the SAMPLES
# are right. QEMU has no file-backed audio INPUT: `-audiodev wav` records the
# codec's output and has no input side at all (it says so: "Could not create a
# backend for voice `adc'"), and the only backends that can feed real audio in
# -- alsa, pipewire, pa -- open the HOST's microphone, which nothing on this
# line is allowed to do. So this runs on `-audiodev none`, whose input side is
# correctly-timed SILENCE. The bytes are real and their timing is real; their
# content is zeros, and it would be zeros whether or not the samples were being
# carried faithfully. Hearing a recording back is an operator's job:
#
#   HAMLINUX_AUDIODEV=pipewire scripts/hamlinux_vm.sh serial
#   ... arecord /tmp/x.raw 3000 ; aplay /tmp/x.raw
#
# Usage: tests/linux/audio_capture.sh [seconds]
# Pass marker: [audio_capture] PASS
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

WAIT="${1:-120}"
WORK="build/audio"; mkdir -p "$WORK"

cat > "$WORK/rc.capture" <<'RC'
echo 'rc.boot: audio capture gate'
ln -s /dev/console /dev/cons
sleep 3
arecord /tmp/cap.raw 1000
echo '[audio_capture] arecord status:' $status
echo '[audio_capture] DONE'
RC

echo "[audio_capture] staging an image with that rc"
HAMLINUX_RC="$WORK/rc.capture" scripts/hamlinux_image.sh > "$WORK/cap-build.log" 2>&1 || {
    echo "FAIL image build"; tail -20 "$WORK/cap-build.log"; exit 1; }

echo "[audio_capture] booting on -audiodev none (silence in, correctly timed)"
HAMLINUX_AUDIODEV=none HAMLINUX_VNC=none \
    timeout "$WAIT" scripts/hamlinux_vm.sh script --timeout "$((WAIT-10))" \
    </dev/null > "$WORK/cap-boot.log" 2>&1

sed -n '/audio capture gate/,/DONE/p' "$WORK/cap-boot.log"

GOT=$(grep -a '^\[arecord\] captured ' "$WORK/cap-boot.log" | head -1 | awk '{print $3}')
[ -n "$GOT" ] || { echo "[audio_capture] FAIL: arecord printed no byte count -- it did not run"; exit 1; }

# 1000 ms at 48000 Hz, 2 channels, 16 bits = 192 000 bytes. The window is wide
# on the low side only because the stream starts a moment after the clock does.
python3 - "$GOT" <<'PY'
import sys
got = int(sys.argv[1])
want = 48000 * 2 * 2          # bytes per second
lo, hi = int(want * 0.80), int(want * 1.05)
print("[audio_capture] captured %d bytes in 1000 ms (%.1f%% of the %d a "
      "48 kHz stereo s16le second is worth)" % (got, 100.0*got/want, want))
if got == 0:
    print("[audio_capture] FAIL: no frames at all -- /dev/audioin delivered nothing")
    sys.exit(1)
if not (lo <= got <= hi):
    print("[audio_capture] FAIL: %d bytes is outside [%d, %d]; the capture "
          "stream is running at the wrong rate" % (got, lo, hi))
    sys.exit(1)
print("[audio_capture] PASS: the capture substream runs and delivers frames at "
      "the configured rate. Their CONTENT is silence, because QEMU's only "
      "host-free input backend is silence -- see the header.")
PY
exit $?
