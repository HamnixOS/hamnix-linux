#!/usr/bin/env bash
# tests/linux/audio_tone.sh — THE acceptance test for sound on this line.
#
# The question is not "did playtone exit 0". It exited 0 for months while
# writing 24 000 frames into a regular file called /dev/audio, which is the
# exact failure this project is organised against. The question is whether the
# emulated codec was fed the signal that was asked for, and the only witness
# that cannot be argued with is the waveform.
#
# So: boot the image, play two known tones, and have QEMU capture what the
# codec was actually handed (`-audiodev wav`). Then MEASURE the capture --
# duration, RMS, peak, and an FFT whose fundamental has to land on the
# requested frequency. A pass here means a person with speakers would have
# heard a 1 kHz tone for a second, an A440 for half of one, and then a clean
# 660 Hz sine streamed out of a .wav file by aplay.
#
# NOTHING HERE TOUCHES THE HOST'S SOUND HARDWARE. The QEMU backend is `wav`,
# a file; the guest's mixer writes go to the EMULATED codec inside the VM.
#
# Usage: tests/linux/audio_tone.sh [seconds]
# Pass marker: [audio_tone] PASS
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

WAIT="${1:-120}"
WORK="build/audio"; mkdir -p "$WORK"
WAV="$WORK/capture.wav"
rm -f "$WAV"

# The rc. `sleep 3` before the first tone is not padding: snd-hda-intel probes
# its codec ASYNCHRONOUSLY, so /dev/snd/pcmC0D0p does not exist for the first
# second or two of userland. Without the wait the very first boot command
# reaches an empty /dev/snd and the device correctly reports that there is no
# card -- honest, and not what this gate is asking about.
cat > "$WORK/rc.boot" <<'RC'
echo 'rc.boot: audio tone gate'
ln -s /dev/console /dev/cons
sleep 3
echo '[audio_tone] /dev/snd:'
ls /dev/snd
playtone 1000 1000
echo '[audio_tone] tone 1 status:' $status
sleep 1
playtone 440 500
echo '[audio_tone] tone 2 status:' $status
sleep 1
aplay /usr/share/sounds/test.wav
echo '[audio_tone] aplay status:' $status
sleep 1
echo '[audio_tone] device says:'
cat /dev/audio
echo '[audio_tone] DONE'
RC

echo "[audio_tone] staging an image with that rc"
HAMLINUX_RC="$WORK/rc.boot" scripts/hamlinux_image.sh > "$WORK/build.log" 2>&1 || {
    echo "FAIL image build"; tail -20 "$WORK/build.log"; exit 1; }

echo "[audio_tone] booting, capturing the codec output to $WAV"
# HAMLINUX_VNC=none overrides the script mode's fixed 127.0.0.1:9, so this gate
# can run beside another VM without both wanting the same port -- and it wants
# no display at all. QEMU also says "Could not create a backend for voice `adc'"
# here, which is correct and harmless: the wav backend records the codec's
# OUTPUT and has no input side, so /dev/audioin has nothing to capture in this
# mode. tests/linux/audio_capture.sh covers that with `-audiodev none`.
HAMLINUX_AUDIODEV="wav,path=$WAV" HAMLINUX_VNC=none \
    timeout "$WAIT" scripts/hamlinux_vm.sh script --timeout "$((WAIT-10))" \
    </dev/null > "$WORK/boot.log" 2>&1

sed -n '/audio tone gate/,/DONE/p' "$WORK/boot.log"

[ -s "$WAV" ] || { echo "[audio_tone] FAIL: QEMU wrote no capture at all"; exit 1; }

python3 - "$WAV" <<'PY'
import sys, wave, numpy as np

# (Hz, seconds, shape). The first two are playtone, which stages a clip and
# plays it with `start`. The third is aplay streaming a .wav, which goes down
# the OTHER path entirely -- `streamopen`, short-write retries, `drain` -- so
# both halves of the device's write protocol are measured here.
want = [(1000.0, 1.000, 'square'),
        (440.0,  0.500, 'square'),
        (660.0,  0.500, 'sine')]

# What playtone can ACTUALLY synthesise. It flips the wave every
# `rate / (2*freq)` samples with integer division, so the tone it emits is
# 48000 / (2*half). For 1000 Hz that is exactly 1000; for 440 Hz the half
# period rounds from 54.55 to 54 and the tone is 444.44 Hz. Checking against
# the requested number would fail on a device that is doing exactly what it
# was told, and "fix" it by loosening the tolerance until a wrong rate passed
# too. This is the generator's quantisation, stated rather than absorbed.
RATE = 48000.0
def synth(freq):
    half = int(RATE / (2 * freq)) or 1
    return RATE / (2 * half)

w = wave.open(sys.argv[1])
sr, ch = w.getframerate(), w.getnchannels()
d = np.frombuffer(w.readframes(w.getnframes()), dtype='<i2')
d = d.reshape(-1, ch).astype(float)
x = d[:, 0]
print("[audio_tone] capture: %d ch, %d Hz, %.3f s" % (ch, sr, len(x) / sr))

# Segment on a 5 ms RMS ENVELOPE, not on the samples.
#
# Worth the sentence, because doing it on the samples is wrong in a way that
# looks right: QEMU resamples 48 kHz to 44.1 kHz, so every edge of a square
# wave gets an interpolated sample near zero. A sample-wise |x| > threshold
# test therefore chops a perfectly good 1 s tone into a few thousand
# sub-millisecond fragments and reports that the capture contains no audio at
# all -- a measurement that failed while the thing it measured worked.
blk = max(1, int(0.005 * sr))
nb = len(x) // blk
env = np.sqrt((x[:nb*blk].reshape(nb, blk) ** 2).mean(axis=1))
loud = env > 500
edges = np.diff(loud.astype(int))
starts = [i + 1 for i in np.where(edges == 1)[0]]
ends   = [i + 1 for i in np.where(edges == -1)[0]]
if loud[0]:  starts.insert(0, 0)
if loud[-1]: ends.append(nb)
segs = [(a * blk, b * blk) for a, b in zip(starts, ends)
        if (b - a) * blk / sr > 0.05]

print("[audio_tone] %d non-silent segment(s)" % len(segs))
fail = []
if len(segs) != len(want):
    fail.append("expected %d tones, the capture has %d" % (len(want), len(segs)))

for i, (a, b) in enumerate(segs):
    seg = x[a:b]
    dur = (b - a) / sr
    rms, pk = seg.std(), np.abs(seg).max()
    sp = np.abs(np.fft.rfft(seg * np.hanning(len(seg))))
    f = np.fft.rfftfreq(len(seg), 1.0 / sr)
    f0 = f[np.argmax(sp)]
    print("[audio_tone]   seg %d: %.4f s  f0 %.2f Hz  rms %.0f  peak %.0f"
          % (i + 1, dur, f0, rms, pk))
    if i >= len(want):
        continue
    wf, wd, shape = want[i]
    ef = synth(wf) if shape == 'square' else wf
    # The fundamental of a square wave is exact; 1% is slack for the FFT bin
    # width of the shorter tone, not for a wrong sample rate.
    if abs(f0 - ef) / ef > 0.01:
        fail.append("seg %d: fundamental %.1f Hz; asked for %.0f Hz, which "
                    "playtone synthesises as %.2f Hz" % (i+1, f0, wf, ef))
    if abs(dur - wd) > 0.06:
        fail.append("seg %d: %.3f s of audio, asked for %.3f s" % (i+1, dur, wd))
    if rms < 5000:
        fail.append("seg %d: rms %.0f -- audible in principle, not in fact" % (i+1, rms))
    # HARMONIC SHAPE, which is what separates "the right tone" from "a tone at
    # the right pitch". A square wave carries odd harmonics at 1/3, 1/5, 1/7
    # of the fundamental; the sine in test.wav carries none.
    h3 = sp[np.argmin(np.abs(f - 3*f0))] / sp.max()
    if shape == 'square' and not (0.2 < h3 < 0.6):
        fail.append("seg %d: 3rd harmonic at %.2f of the fundamental -- not a "
                    "square wave" % (i+1, h3))
    if shape == 'sine' and h3 > 0.10:
        fail.append("seg %d: 3rd harmonic at %.2f of the fundamental -- the "
                    "sine came through distorted" % (i+1, h3))

if fail:
    for m in fail:
        print("[audio_tone] FAIL: " + m)
    sys.exit(1)
print("[audio_tone] PASS: every tone asked for is in the capture, at the right "
      "frequency, for the right length, with a square wave's harmonics.")
PY
RC=$?
[ $RC -eq 0 ] || echo "[audio_tone] the capture is at $WAV"
exit $RC
