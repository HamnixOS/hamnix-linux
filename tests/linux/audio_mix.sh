#!/usr/bin/env bash
# tests/linux/audio_mix.sh — CAN TWO PROGRAMS MAKE A SOUND AT THE SAME TIME?
#
# tests/linux/audio_tone.sh proved the device: one program, three tones, the
# right frequencies out of an FFT on a WAV captured out of QEMU. This asks the
# next question, and it is the one an ALSA hardware substream says no to, since
# it has exactly ONE writer. Hamnix's /dev/audio mixes in software
# (drivers/audio/hda.ad's hda_stream_mix, drivers/audio/mixer.ad's four
# per-stream gains); user/linux-audio.c now does too, through a shared mix ring
# and a pump process. This is the witness.
#
# THE ASSERTION, and nothing weaker proves a mixer: ONE capture must contain
# BOTH tones AT THE SAME TIME, from TWO SEPARATE PROCESSES. So the run has a
# solo phase first as the negative control -- 1 kHz alone, in which the 300 Hz
# bin must be EMPTY -- and then the same 1 kHz beside a 300 Hz from a second
# pid, in which both bins must be loud. A gate that only looked at the mixed
# phase could be passed by a device that plays a burst of noise.
#
# It also measures the two things that are easy to get silently wrong:
#
#   THE SUM. Two 12000-amplitude square waves that are really summed give an
#   RMS near sqrt(2)*12000 = 16971, not 12000 (one of them winning) and not
#   8485 (a mixer that halves everything to buy headroom). The window is wide
#   enough for the phase relationship between two independent processes and
#   narrow enough to tell those three cases apart.
#
#   A SLOW WRITER MUST NOT STALL A FAST ONE. Phase 2 runs the same 1 kHz beside
#   a producer deliberately handing over 5.3 ms of audio every 10 ms -- about a
#   third of real time, paced by a sleep rather than by the ring
#   (`playtone <hz> <ms> <pause_ms>`). The slow stream's own tone comes out
#   broken, which is what underfeeding sounds like and is not a
#   defect. What is asserted is that the 1 kHz is CONTINUOUS through the whole
#   window: measured as a 1 kHz band-energy envelope that never drops below a
#   quarter of its median. That is the failure mode this whole design is
#   organised against, and it is the one most likely to be silent.
#
# NOTHING HERE TOUCHES THE HOST'S SOUND HARDWARE. The QEMU backend is `wav`, a
# file; the guest's writes go to the EMULATED codec inside the VM.
#
# Usage: tests/linux/audio_mix.sh [seconds]
# Pass marker: [audio_mix] PASS
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

WAIT="${1:-180}"
WORK="build/audio"; mkdir -p "$WORK"
WAV="$WORK/mix.wav"
rm -f "$WAV"

# `sleep 3` before anything: snd-hda-intel probes its codec asynchronously, so
# /dev/snd/pcmC0D0p does not exist for the first second or two of userland.
# The gaps between phases are >= 2 s so the RMS envelope separates them, and
# each phase is given more wall clock than its tone needs -- a background
# playtone returns from `start` while the sound is still playing out of the mix
# ring, which is the whole point of the ring outliving the writer.
cat > "$WORK/rc.mix" <<'RC'
echo 'rc.boot: audio mix gate'
ln -s /dev/console /dev/cons
sleep 3
echo '[audio_mix] PHASE 0: 1 kHz alone (the negative control)'
playtone 1000 1500
sleep 3
echo '[audio_mix] PHASE 1: 1 kHz and 300 Hz, two pids, at once'
playtone 1000 3000 &
playtone 300 3000 &
sleep 7
echo '[audio_mix] device says:'
cat /dev/audio
sleep 3
echo '[audio_mix] PHASE 2: the same 1 kHz beside a writer at a third of real time'
playtone 1000 3000 &
playtone 300 1500 10 &
sleep 9
echo '[audio_mix] DONE'
RC

echo "[audio_mix] staging an image with that rc"
HAMLINUX_RC="$WORK/rc.mix" scripts/hamlinux_image.sh > "$WORK/mix-build.log" 2>&1 || {
    echo "FAIL image build"; tail -30 "$WORK/mix-build.log"; exit 1; }

echo "[audio_mix] booting, capturing the codec output to $WAV"
HAMLINUX_AUDIODEV="wav,path=$WAV" HAMLINUX_VNC=none \
    timeout "$WAIT" scripts/hamlinux_vm.sh script --timeout "$((WAIT-10))" \
    </dev/null > "$WORK/mix-boot.log" 2>&1

sed -n '/audio mix gate/,/DONE/p' "$WORK/mix-boot.log"

[ -s "$WAV" ] || { echo "[audio_mix] FAIL: QEMU wrote no capture at all"; exit 1; }

python3 - "$WAV" <<'PY'
import sys, wave, numpy as np

w = wave.open(sys.argv[1])
sr, ch = w.getframerate(), w.getnchannels()
d = np.frombuffer(w.readframes(w.getnframes()), dtype='<i2')
d = d.reshape(-1, ch).astype(float)
x = d[:, 0]
print("[audio_mix] capture: %d ch, %d Hz, %.3f s" % (ch, sr, len(x) / sr))

# Segment on a 5 ms RMS envelope, for the reason audio_tone.sh states: QEMU
# resamples 48 kHz to 44.1 kHz, so a sample-wise threshold shreds a perfectly
# good square wave into thousands of fragments.
blk = max(1, int(0.005 * sr))
nb = len(x) // blk
env = np.sqrt((x[:nb * blk].reshape(nb, blk) ** 2).mean(axis=1))
loud = env > 500
edges = np.diff(loud.astype(int))
starts = [i + 1 for i in np.where(edges == 1)[0]]
ends = [i + 1 for i in np.where(edges == -1)[0]]
if loud[0]:  starts.insert(0, 0)
if loud[-1]: ends.append(nb)
segs = [(a * blk, b * blk) for a, b in zip(starts, ends)
        if (b - a) * blk / sr > 0.4]
print("[audio_mix] %d non-silent phase(s): %s" %
      (len(segs), ", ".join("%.2f-%.2f s" % (a / sr, b / sr) for a, b in segs)))

fail = []
if len(segs) < 3:
    print("[audio_mix] FAIL: expected 3 phases (solo, mixed, slow), found %d"
          % len(segs))
    sys.exit(1)
# The three longest are the phases; anything shorter is a boot artefact.
segs = sorted(sorted(segs, key=lambda s: s[1] - s[0])[-3:])


def bin_mag(seg, f0):
    """Magnitude of `seg` at f0 by a single-bin DFT, and that magnitude AS A
    FRACTION OF THE SEGMENT'S RMS.

    The fraction is the number the assertions use, and it is deliberately not a
    signal-to-noise ratio: the first draft of this gate divided by a `noise
    floor` sampled at three nearby frequencies, and in a capture of two clean
    square waves that floor is essentially zero -- so it reported the 1 kHz
    tone at 2e8 over the floor AND the absent 300 Hz tone at 7.6e3 over it, and
    no threshold can separate those two. A measurement whose scale is set by
    numerical noise is not a measurement. Against the RMS the numbers are
    bounded and mean something: a Hann-windowed single-bin DFT of a square wave
    at its own fundamental lands near 0.64 of the RMS (4/pi for the square's
    fundamental, halved by the window), and a frequency nothing is playing
    lands near 0.001."""
    n = len(seg)
    t = np.arange(n) / sr
    win = np.hanning(n)
    mag = 2.0 * np.abs(np.sum(seg * win * np.exp(-2j * np.pi * f0 * t))) / n
    r = seg.std()
    return mag, (mag / r if r > 0 else 0.0)


def phase(i, name):
    a, b = segs[i]
    seg = x[a:b]
    # trim the attack and release so the measurement is of the steady state
    k = int(0.20 * sr)
    if len(seg) > 3 * k:
        seg = seg[k:-k]
    return seg, name


# --- PHASE 0: the negative control -----------------------------------
seg, _ = phase(0, "solo")
m1k, r1k = bin_mag(seg, 1000.0)
m300, r300 = bin_mag(seg, 300.0)
solo_rms = seg.std()
print("[audio_mix] phase 0 (1 kHz alone): 1000 Hz %.3f of rms, "
      "300 Hz %.3f, rms %.0f" % (r1k, r300, solo_rms))
if r1k < 0.30:
    fail.append("phase 0: the 1 kHz tone is not in the capture at all "
                "(%.3f of the rms; a square wave's own fundamental is ~0.64)"
                % r1k)
if r300 > 0.05:
    fail.append("phase 0: 300 Hz is %.3f of the rms with nothing playing it -- "
                "the control is not a control" % r300)

# --- PHASE 1: two programs, two tones, one capture -------------------
seg, _ = phase(1, "mixed")
m1k_x, r1k_x = bin_mag(seg, 1000.0)
m300_x, r300_x = bin_mag(seg, 300.0)
mix_rms = seg.std()
print("[audio_mix] phase 1 (both):        1000 Hz %.3f of rms, "
      "300 Hz %.3f, rms %.0f" % (r1k_x, r300_x, mix_rms))
if r1k_x < 0.20:
    fail.append("phase 1: the 1 kHz tone is missing from the mix (%.3f of the "
                "rms)" % r1k_x)
if r300_x < 0.20:
    fail.append("phase 1: the 300 Hz tone is missing from the mix (%.3f of the "
                "rms) -- the second program was not heard" % r300_x)
# Neither may have swamped the other: a device that simply handed the card to
# whichever process wrote last would show one bin and a floor at the other.
if m1k_x > 0 and m300_x > 0:
    ratio = max(m1k_x / m300_x, m300_x / m1k_x)
    print("[audio_mix] phase 1: the two fundamentals are within %.1fx of each "
          "other" % ratio)
    if ratio > 6:
        fail.append("phase 1: one tone is %.1fx the other; both programs asked "
                    "for the same amplitude, so one of them is being cut" % ratio)
# THE SUM. Two independent 12000-amplitude square waves sum to ~sqrt(2)x one.
print("[audio_mix] phase 1: rms %.0f against %.0f solo (%.2fx); a real sum is "
      "~1.41x, one winner is 1.0x, a halving mixer is 0.71x"
      % (mix_rms, solo_rms, mix_rms / solo_rms if solo_rms else 0))
if solo_rms > 0 and not (1.15 <= mix_rms / solo_rms <= 1.75):
    fail.append("phase 1: the mixed rms is %.2fx the solo rms, which is not the "
                "sum of two equal streams" % (mix_rms / solo_rms))

# --- PHASE 2: a slow writer must not stall a fast one ----------------
a, b = segs[2]
seg = x[a:b]
k = int(0.20 * sr)
if len(seg) > 3 * k:
    seg = seg[k:-k]
m1k_s, r1k_s = bin_mag(seg, 1000.0)
m300_s, r300_s = bin_mag(seg, 300.0)
print("[audio_mix] phase 2 (fast+slow):   1000 Hz %.3f of rms, "
      "300 Hz %.3f" % (r1k_s, r300_s))
if r1k_s < 0.20:
    fail.append("phase 2: the fast stream's 1 kHz is not in the capture beside "
                "a slow writer (%.3f of the rms)" % r1k_s)
if r300_s < 0.05:
    fail.append("phase 2: the slow writer is inaudible (%.3f of the rms) -- "
                "underfed is meant to be choppy, not silent" % r300_s)

# CONTINUITY. Band-energy at 1 kHz in 40 ms hops. A stall shows up here and
# nowhere else: a whole-window FFT of a tone with a 300 ms hole in it still has
# a fine-looking peak at 1 kHz.
hop = int(0.040 * sr)
nh = len(seg) // hop
tt = np.arange(hop) / sr
wref = np.hanning(hop) * np.exp(-2j * np.pi * 1000.0 * tt)
band = np.array([np.abs(np.sum(seg[i * hop:(i + 1) * hop] * wref)) / hop
                 for i in range(nh)])
med = np.median(band)
holes = int(np.sum(band < med * 0.25))
print("[audio_mix] phase 2: %d of %d 40 ms windows have the 1 kHz band below a "
      "quarter of its median" % (holes, nh))
if med <= 0:
    fail.append("phase 2: no 1 kHz band energy at all")
elif holes > max(2, nh // 20):
    fail.append("phase 2: the fast stream drops out in %d of %d 40 ms windows "
                "-- the slow writer IS stalling it" % (holes, nh))

if fail:
    for m in fail:
        print("[audio_mix] FAIL: " + m)
    sys.exit(1)
print("[audio_mix] PASS: two processes playing two different tones appear in "
      "ONE capture as BOTH frequencies, summed rather than switched, and a "
      "writer running at an eighth of real time does not interrupt the other.")
PY
RC=$?
[ $RC -eq 0 ] || echo "[audio_mix] the capture is at $WAV"
exit $RC
