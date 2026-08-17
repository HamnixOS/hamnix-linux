#!/usr/bin/env bash
#
# REGISTRATION, 2026-08-17. Until this date scripts/test_gate_registration.sh
# globbed only scripts/test_*.sh, so this directory was invisible to the gate
# against unregistered gates and every file in it read as coverage without
# being coverage. This gate is ON-DEMAND: not in ci_battery_manifest.txt
# because it boots a machine through `scripts/hamlinux_vm.sh`.
#
# tests/linux/audio_lifetime.sh — user/audiolife.ad, on the Linux kernel.
#
# audiolife is not a test program in the usual sense: it is the REPRODUCTION of
# three things a person said about a shipped machine, written on Hamnix and run
# there by scripts/test_audio_stream_lifetime.sh against a QEMU `-audiodev wav`
# capture.
#
#   1. "on the first sound effect it played the end of the boot jingle"
#   2. "on close it played the last sound effect over and over"
#   3. "two apps playing audio ... 1/2 the sounds don't play while the music
#      is playing"
#
# On this line the program built and ran for months and could not answer (3) at
# all, because /dev/audio had ONE writer: the second program to open it got
# EBUSY. HANDOFF.md said so, and said audiolife "does not do here what it does
# on Hamnix". This is the gate for the claim that it now does.
#
# Each phase is a SEPARATE PROCESS, deliberately -- the whole defect class is
# about a buffer outliving the process that owns it, and running the phases as
# function calls inside one pid would hide exactly the bug. The timeline is
# audiolife's own (see its header); this file only reads the waveform.
#
#   D  clip   3.0 s of 1000 Hz, staged + `start`, then the pid EXITS
#   E  raw    ONE 150 ms 300 Hz write, no ctl at all, then the pid EXITS
#   C  music  4.0 s of 1500 Hz, a streaming nonblock producer
#   B  sfx    six 100 ms 300 Hz bursts OVER C, each its own open/write/close
#
# WHAT IS ASSERTED, and each one is one of the three reports:
#
#   (1) E's effect is 300 Hz. If the device let a dead process's clip go on
#       cycling, E's window would carry 1000 Hz -- the end of the jingle.
#   (2) D's clip sounds ONCE and for ~3 s. A cyclic buffer nobody stopped
#       replays it; on Hamnix's pre-fix build that was 7.272 s of a 3.000 s
#       clip.
#   (3) C AND B SOUND AT THE SAME TIME. In C's window the capture must carry
#       BOTH 1500 Hz and 300 Hz. This is the one that was impossible here
#       before the mixer, and it is the point of the file.
#
# NOTHING HERE TOUCHES THE HOST'S SOUND HARDWARE: the backend is `wav`.
#
# Usage: tests/linux/audio_lifetime.sh [seconds]
# Pass marker: [audio_lifetime] PASS
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

WAIT="${1:-200}"
WORK="build/audio"; mkdir -p "$WORK"
WAV="$WORK/lifetime.wav"
rm -f "$WAV"

cat > "$WORK/rc.life" <<'RC'
echo 'rc.boot: audio lifetime gate'
ln -s /dev/console /dev/cons
sleep 3
audiolife
RC

echo "[audio_lifetime] staging an image with that rc"
HAMLINUX_RC="$WORK/rc.life" scripts/hamlinux_image.sh > "$WORK/life-build.log" 2>&1 || {
    echo "FAIL image build"; tail -30 "$WORK/life-build.log"; exit 1; }

echo "[audio_lifetime] booting, capturing the codec output to $WAV"
HAMLINUX_AUDIODEV="wav,path=$WAV" HAMLINUX_VNC=none \
    timeout "$WAIT" scripts/hamlinux_vm.sh script --timeout "$((WAIT-10))" \
    </dev/null > "$WORK/life-boot.log" 2>&1

sed -n '/audio lifetime gate/,/SCENARIO done/p' "$WORK/life-boot.log"

[ -s "$WAV" ] || { echo "[audio_lifetime] FAIL: QEMU wrote no capture"; exit 1; }

python3 - "$WAV" <<'PY'
import sys, wave, numpy as np

w = wave.open(sys.argv[1])
sr, ch = w.getframerate(), w.getnchannels()
d = np.frombuffer(w.readframes(w.getnframes()), dtype='<i2')
x = d.reshape(-1, ch).astype(float)[:, 0]
print("[audio_lifetime] capture: %d ch, %d Hz, %.3f s" % (ch, sr, len(x) / sr))

blk = max(1, int(0.005 * sr))
nb = len(x) // blk
env = np.sqrt((x[:nb * blk].reshape(nb, blk) ** 2).mean(axis=1))
loud = env > 500
e = np.diff(loud.astype(int))
st = [i + 1 for i in np.where(e == 1)[0]]
en = [i + 1 for i in np.where(e == -1)[0]]
if loud[0]:  st.insert(0, 0)
if loud[-1]: en.append(nb)
segs = [(a * blk, b * blk) for a, b in zip(st, en) if (b - a) * blk / sr > 0.05]


def band(seg, f0, bw=60.0):
    """Fraction of `seg`'s power within bw of f0. Power, not a coherent bin:
    B's six bursts and E's single one are re-anchored at the ring's live edge
    each time they are summed in (au_mix, and hda_stream_mix before it), so
    their phase restarts and a coherent measure cancels them."""
    n = len(seg)
    sp = np.abs(np.fft.rfft(seg * np.hanning(n))) ** 2
    f = np.fft.rfftfreq(n, 1.0 / sr)
    t = sp.sum()
    return float(sp[(f > f0 - bw) & (f < f0 + bw)].sum() / t) if t > 0 else 0.0


print("[audio_lifetime] %d non-silent segment(s):" % len(segs))
for a, b in segs:
    seg = x[a:b]
    print("[audio_lifetime]   %6.2f-%6.2f s (%.3f s) rms %5.0f  "
          "1000 %.3f  1500 %.3f  300 %.3f"
          % (a / sr, b / sr, (b - a) / sr, seg.std(),
             band(seg, 1000.0), band(seg, 1500.0), band(seg, 300.0)))

fail = []

# --- (2) D's clip: one segment of ~3 s dominated by 1000 Hz ---------
d_segs = [(a, b) for a, b in segs
          if (b - a) / sr > 1.0 and band(x[a:b], 1000.0) > 0.25]
if not d_segs:
    fail.append("phase D's 3 s 1000 Hz clip is not in the capture at all")
else:
    a, b = d_segs[0]
    dur = (b - a) / sr
    print("[audio_lifetime] D: one 1000 Hz clip of %.3f s (asked for 3.000)" % dur)
    if len(d_segs) > 1:
        fail.append("phase D's clip sounds %d times -- a buffer nobody stopped "
                    "is replaying it" % len(d_segs))
    if not (2.6 <= dur <= 3.6):
        fail.append("phase D's clip is %.3f s of a 3.000 s clip -- %s"
                    % (dur, "it is being replayed" if dur > 3.6 else "it is cut short"))

# --- (1) E's raw effect: 300 Hz, not the jingle's tail ---------------
# It is the short segment that follows D's, before the music starts.
tail = [(a, b) for a, b in segs
        if d_segs and a > d_segs[0][1] and (b - a) / sr < 1.0]
if not tail:
    fail.append("phase E's raw 150 ms effect never sounded -- a write to "
                "/dev/audio with no ctl at all is what lib/hamgame_dev.ad does")
else:
    a, b = tail[0]
    seg = x[a:b]
    p300, p1k = band(seg, 300.0), band(seg, 1000.0)
    print("[audio_lifetime] E: %.3f s at %.2f s -- 300 Hz %.3f of the power, "
          "1000 Hz %.3f" % ((b - a) / sr, a / sr, p300, p1k))
    if p300 < 0.10:
        fail.append("phase E's effect carries %.3f of its power at 300 Hz -- "
                    "it is not the effect that was written" % p300)
    if p1k > p300:
        fail.append("phase E's effect is more 1000 Hz than 300 Hz: it played "
                    "the END OF THE JINGLE, which is report (1) exactly")

# --- (3) THE MIX: C's music and B's effects at the same time --------
# C is the long 1500 Hz segment. B's bursts are summed into it, so they do not
# appear as segments of their own -- which is itself the answer to report (3):
# on a device with one writer they either came out AFTER the music or not at
# all, and either way they are not INSIDE it.
c_segs = [(a, b) for a, b in segs
          if (b - a) / sr > 1.0 and band(x[a:b], 1500.0) > 0.25]
if not c_segs:
    fail.append("phase C's 4 s 1500 Hz music is not in the capture")
else:
    a, b = c_segs[-1]
    seg = x[a:b]
    p1500, p300 = band(seg, 1500.0), band(seg, 300.0)
    print("[audio_lifetime] C+B: %.3f s of music -- 1500 Hz %.3f of the power, "
          "300 Hz %.3f, rms %.0f" % ((b - a) / sr, p1500, p300, seg.std()))
    if p1500 < 0.20:
        fail.append("the music is not in its own window (1500 Hz %.3f)" % p1500)
    if p300 < 0.02:
        fail.append("REPORT (3), unfixed: the six sound effects are not in the "
                    "music's window (300 Hz %.3f of its power). Either they "
                    "were refused or they came out after the music -- which is "
                    "'half the sounds don't play' from the player's seat"
                    % p300)
    else:
        # HOW MUCH of the effects, and WHERE. The report was "HALF the sounds
        # don't play", so the number that answers it is how many SECONDS of
        # 300 Hz are in the music's window against the 0.600 s phase B wrote
        # (six bursts of 100 ms).
        #
        # It is NOT how widely they are spread, which is what the first draft
        # of this assertion measured and got wrong: B sleeps 100 ms between
        # 100 ms bursts, so 0.6 s of effects occupies about 0.65 s of wall
        # clock and always will. Demanding that they span a quarter of a 4 s
        # window was demanding a scenario audiolife does not run.
        hop = int(0.050 * sr)
        nh = len(seg) // hop
        f = np.fft.rfftfreq(hop, 1.0 / sr)
        m = (f > 240) & (f < 360)
        b300 = np.array([np.abs(np.fft.rfft(seg[i*hop:(i+1)*hop]
                                            * np.hanning(hop)))[m].sum()
                         for i in range(nh)])
        hot = np.where(b300 > b300.max() * 0.35)[0]
        secs = len(hot) * 0.050
        print("[audio_lifetime] C+B: %.2f s of 300 Hz inside the music, "
              "against the 0.60 s phase B wrote; from %.2f s to %.2f s of a "
              "%.2f s window"
              % (secs, hot[0] * 0.050 if len(hot) else 0,
                 hot[-1] * 0.050 if len(hot) else 0, nh * 0.050))
        if secs < 0.40:
            fail.append("REPORT (3): only %.2f s of the 0.60 s of effects is "
                        "inside the music -- that IS 'half the sounds don't "
                        "play'" % secs)
        # ...and inside it, not leaking off either end, which is what an
        # APPENDING device does: the effects come out after the music.
        if len(hot) and (hot[0] == 0 or hot[-1] >= nh - 1):
            fail.append("the effects touch the edge of the music's window -- "
                        "they are being queued around it rather than summed "
                        "into it")

if fail:
    for m in fail:
        print("[audio_lifetime] FAIL: " + m)
    sys.exit(1)
print("[audio_lifetime] PASS: audiolife's scenario does on the Linux kernel "
      "what it does on Hamnix -- a staged clip plays once and stops, a raw "
      "write with no ctl sounds as itself and not as the last clip's tail, and "
      "a second program's effects are HEARD INSIDE another program's music.")
PY
RC=$?
[ $RC -eq 0 ] || echo "[audio_lifetime] the capture is at $WAV"
exit $RC
