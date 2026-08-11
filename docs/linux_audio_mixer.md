# The software mixer behind `/dev/audio`

Two programs can make a sound at the same time on this line. This is the record
of how, of what was ported rather than invented, and of what is still refused.

Files: `user/linux-audio.c`, `user/playtone.ad`, `tests/linux/audio_mix.sh`,
`tests/linux/audio_lifetime.sh`.

---

## 1. The problem, exactly

`/dev/audio` on this line is served by `user/linux-audio.c` against the Linux
kernel's raw PCM ioctls on `/dev/snd/pcmC*D*p`. **An ALSA hardware substream has
exactly one writer.** The second process to open it gets `EBUSY` from the kernel,
and no amount of care in the device could change that.

So the port had one writer, and said so. `stream` and `mixplay` returned
`-EINVAL`, `user/audiolife.ad` could not run its third phase at all, and the
status line carried `streams 100 100 100 100` — four constants, present because
`user/hamctl.ad` parses the field. A placeholder that a real program reads is
worse than an absence, and `HANDOFF.md` §0 listed all of it under HONESTLY
BROKEN.

On Hamnix the same name mixes. The behaviour to port lives in two files:

* `drivers/audio/hda.ad` — `hda_stream_mix`, `hda_owner`, the DMA ring, the
  one-shot lap accounting, and the service tick that stops a stream whose owner
  has exited.
* `drivers/audio/mixer.ad` — four concurrent streams, a Q8 per-stream gain, a
  saturating sum, a master gain and a mute latch that does not destroy the
  stored level.

Two things in `hda.ad` are easy to miss and are the load-bearing ones:

> THERE IS NO VOICE OR SLOT TABLE HERE, AND SO NO CONCURRENCY CEILING: the mix
> is done in place into the one ring, so any number of processes can be summed.

and, on `hda_mixw`:

> A mix-in arrives in chunks (a 100 ms effect is a dozen 4 KiB writes), and the
> play cursor barely moves while those chunks are handed over — so placing every
> chunk at "play + guard" stacks them all on top of each other and all but the
> last ~25 ms of the effect is lost. Measured: 0.075 s of a 0.600 s effect
> stream survived.

The four streams of `mixer.ad` are therefore **four volume slots, not four
voices**. That distinction decides what happens when a fifth program asks.

---

## 2. The shape, and what each piece is the port of

### The mix ring — `hda.ad`'s DMA buffer

`/srv/audio`, a file in the tmpfs `linuxinit` mounts, `MAP_SHARED` into every
process that writes audio. 245 760 bytes of PCM (1.28 s of 48 kHz stereo s16le),
a monotonic `play` cursor and a monotonic `w` high-water. `hda.ad`'s ring is
kernel DMA memory that every process reaches through the one kernel; here the
processes are separate and the shared mapping is what stands in for that. The
fallback candidates are `/dev/shm/hamnix-audio` and `/tmp/hamnix-audio`, joined
ATTACH-BEFORE-CREATE for the reason `linux-wsys.c` documents at length:
`O_CREAT` on a file you do not own inside a sticky world-writable directory is
refused by `fs.protected_regular`, and a fall-through to the next candidate
would leave a program mixing into a ring nothing drains.

The length is divisible by 2, 3, 4, 6, 8, 12, 16 and 24 — every frame size this
device can be configured for. A ring whose length is not a whole number of
frames shifts every sample by a byte on each wrap.

### The pump — `hda.ad`'s DMA engine and its service tick

A detached process (double `fork`, `setsid`, reparented to PID 1) that owns the
one ALSA substream and does nothing but move one period of the ring into it at a
time.

**Nothing wakes it.** The blocking `write(2)` to the substream is paced by the
hardware, exactly as the DMA engine is paced by the hardware. That is what makes
it the port of a DMA engine and not of a scheduler.

**A starved period is silence.** When no writer has anything ready for the next
period, the pump hands the card a period of hush and advances `play` anyway. It
is the whole answer to "a slow or stalled writer must not stall the others": the
clock does not stop, so every other stream in the ring keeps flowing at exactly
its own rate. It is also why `au_hush_byte()` exists — silence is `0x00` for
s16/s24/s32 and `0x80` for u8, and filling a u8 stream's gaps with zero would be
a full-scale DC step, i.e. a click on every underrun.

It **zeroes each byte as it consumes it**, which is `hda.ad`'s
`_hda_ring_silence_ahead`. A ring that is not re-silenced replays the previous
lap when a producer falls behind — "on close it played the last sound effect
over and over". Here it has a second job: it is what lets a writer sum into
virgin ring without tracking which bytes are stale.

**It parks, it does not exit.** After 2.5 s with nothing to play and no writer
holding a slot, the pump closes the card and sleeps in a futex on a word in the
shared segment; a writer's increment-and-wake reaches it in microseconds. This
is not a preference:

* It must give up the CARD when idle. An open substream keeps QEMU's audio
  thread and a real codec's DMA engine running, and an idle desktop on this tree
  is measured in host CPU (`HANDOFF.md`, THE IDLE CENSUS). The desktop plays a
  boot chime, so a pump that held the card forever would be armed on every boot.
* It must not EXIT. PID 1 here is `hamsh`, and the runtime's reaper waits on the
  pids it *remembers* — deliberately, so it cannot steal a status from code that
  wanted one. An orphaned pump that exited would sit on the process table as a
  zombie, and one per sound is a leak with a bell on it.

The futex wait carries a 1 s timeout as a safety net, not as the mechanism: a
writer that summed into the ring and died before its wake would otherwise leave
its audio sitting there unheard.

### The mix — `hda_stream_mix` and `mixer.ad`'s mix loop

`au_mix()`. A writer **sums** its samples into the ring just ahead of the play
cursor. It never appends behind a ring-full of somebody else's audio, which is
the failure `hda.ad`'s own comment names:

> with a music player streaming 4.000 s into the ring, a game's six 100 ms
> effects came out AFTER all of the music … Zero of the 0.600 s of effects
> overlapped the music. From the player's seat that is "half the sounds don't
> play".

Each writer carries **its own cursor**, so a slow producer falls behind on its
own account and a fast one is untouched. The cursor is re-anchored to
`play + guard` whenever it has fallen behind, and refuses to run more than half a
ring ahead — reported, not hidden, exactly as `hda.ad` reports its mix-in
BACKLOG.

The guard is **two pump periods** (43 ms at 1024-frame periods and 48 kHz
stereo). It must be at least one, because the pump consumes `[play, play+period)`
without the writer's knowledge and anything laid inside that window is bytes a
program wrote and nobody heard. Two, because the pump can advance between a
writer reading `play` and the writer finishing its sum. `hda.ad`'s
`_hda_mix_guard` reasons its way to the same 42 ms from the other end — past the
controller's FIFO prefetch, under the ~100 ms at which a sound stops feeling
attached to the action it accompanies.

A short spinlock guards the ring and `w`. It is held for at most 8 KiB of
summing — tens of microseconds — and the wait has a deadline, because a writer
killed inside it would otherwise wedge every program on the box. Breaking it is
printed, not silent.

---

## 3. The decisions, and why

### Clipping: saturation, not scaling

Four streams at full scale sum to four times `int16`. The two honest answers are
to clamp the sum or to divide every stream by four.

**This clamps.** `_hda_sat_add_s16` and `mixer.ad`'s `_mix_sat_add` both do, and
the reason is that dividing makes the COMMON case — one program playing — 12 dB
quiet in order to buy headroom for a case that rarely happens. A sum that clips
is audible distortion on a loud moment; a mixer that is permanently a quarter
volume is a device nobody can hear. The per-stream volume is the control for the
case where you want the other behaviour, and the count of samples the sum
actually clamped is kept.

`tests/linux/audio_mix.sh` measures the consequence rather than trusting it: two
independent 12000-amplitude square waves give an RMS of **16 807 against 11 832
solo, 1.42×**, where a real sum is 1.41×, one writer winning is 1.0× and a
halving mixer is 0.71×.

### The four numbers on the status line

They are real now.

```
loaded 0 cap 1048576 master 100 streams 100 100 100 100 mute 0
space 122880 pos 2498560 mixed 303 hush 218 nogain 0
```

`streams` is the four `AU_SLOTS` per-stream Q8 gains in percent, as
`hda_mix_stream_pct` reports them on Hamnix, and `stream <id> <pct>` sets one. A
slot is claimed by the pid of the first writer to use it and released when that
pid closes the device or dies — `au_reap`, the port of `_hda_owner_alive`.

`space` and `pos` are the mix ring's, not one substream's: `pos` is what the pump
actually handed the card, and `space` is what a producer may append right now
without running past the half-ring bound. The three fields after `pos` are
appended, which is Hamnix's own idiom for extending this line without breaking a
parser that stops earlier: `mixed` is summed writes (`hda_mixed_in`), `hush` is
pump periods that had to be filled with silence — the number that goes up when a
writer cannot keep up — and `nogain` is the fifth-writer count below.

`mixplay` is honoured rather than refused. On Hamnix it means "render
`mixer.ad`'s slots into the DMA buffer", which is a distinct act only because the
plain `/dev/audio` path there does not go through the mixer. Here every path
does, so `mixplay` and `start` name one thing.

### What happens when a fifth program asks

**It still sounds.** `hda_stream_mix` has no voice table and no concurrency
ceiling, and neither has this: the mix is done in place into the one ring, so any
number of processes can be summed. What the fifth writer does not get is a volume
slot of its own; it plays at unity and cannot be attenuated individually. That is
counted and reported as `nogain` on the status line, because a stream whose
volume control silently does nothing is precisely the quiet lie this tree is
organised against.

### Formats: refused by name

The pump runs the hardware at one rate, one channel count and one width, set by
the first stream to arrive. A later stream that wants something else has three
possible answers, and only one is honest here: convert it (this file has no
resampler), play it at the wrong speed (the silent lie), or refuse.

It refuses, and names both formats:

```
[audio] the mixer is running at 48000 Hz / 2 ch / 16 bit and this stream asked
for 44100 Hz / 2 ch / 16 bit; there is no resampler here, so it is refused
rather than played at the wrong speed
```

When the mixer is idle — no other live writer and nothing left in the ring — the
format is free, so a program that runs on its own never sees this.

The mix maths is s16le, as `mixer.ad`'s is. `bits 8`, `bits 24` and `bits 32`
still work for a lone stream, because the ring carries those bytes through
untouched; a SECOND writer arriving while the hardware is in one of those widths
is refused by name rather than summed as if its bytes were 16-bit samples.

### `stop` is this stream's, not the machine's

Dropping the hardware ring would silence every other program mixed into it — the
exact cross-program damage this work exists to remove. `stop` parks this stream's
cursor, and only when nothing else is playing does the ring itself get dropped.

### `close` is not `stop`

What a process summed into the ring is already there and the pump plays it out.
A program that queues a sound effect and exits **is heard** — `hda.ad` has the
same property, because its ring outlives the writer. All that a close gives up is
the volume slot.

---

## 4. Two defects the waveform found

Both were introduced by this work and both were caught by
`tests/linux/audio_lifetime.sh` reading the capture, not by anything exiting
non-zero.

**The clip that played twice.** `hda.ad` auto-starts a staged clip from the
service tick half a second after the last staged write, so a program that writes
raw PCM to `/dev/audio` and never touches `/dev/audioctl` is still heard —
`lib/hamgame_dev.ad`'s `game_dev_play_pcm` does exactly that. A library has no
timer, but it has a moment that means the same thing and is better: the writer
closing the device is "the writer has finished handing the clip over".

Then `user/audiolife.ad`'s phase D closed `/dev/audio` and *afterwards* wrote
`start` to `/dev/audioctl`. Both fired, the clip was mixed twice, and a 3.000 s
tone came out of the capture as **5.373 s** of overlapping 1 kHz — report (2),
"it played the last sound effect over and over", reintroduced by the fix for
report (1). `hda.ad` does not have the problem because `hda_start` on an
already-running stream is a no-op. The auto-start now CONSUMES the clip, so a
following `start` sees an empty one and returns 0. Measured after: **3.003 s**.

**The six effects welded into one.** A writer's cursor continues across writes so
that chunks of one sound lay down end to end. But `lib/hamgame_dev.ad` opens
`/dev/audio`, writes one effect and closes, once per effect — so six effects
fired 200 ms apart share one process, and continuing the cursor across them made
them one continuous 600 ms tone: all six audible, none of them WHEN it happened.
**The open is the boundary between one sound and the next**, so it parks the
cursor and the next write re-anchors to the live edge.

---

## 5. What is measured

### `tests/linux/audio_mix.sh` — two programs, two tones, one capture

Three phases in one boot, captured to a WAV by QEMU's `wav` audiodev. Nothing
touches the host's sound hardware.

| | 1000 Hz | 300 Hz | rms |
|--|--|--|--|
| phase 0 — 1 kHz alone (the negative control) | 0.645 of rms | **0.000** | 11 832 |
| phase 1 — 1 kHz and 300 Hz, two pids | 0.454 | **0.454** | 16 807 (**1.42×**) |
| phase 2 — 1 kHz beside a writer at a third of real time | 0.520 | band power 21 % | |

The solo phase is the control and it matters: a gate that only looked at the
mixed phase could be passed by a device that plays a burst of noise. In phase 1
the two fundamentals are within **1.0×** of each other, so neither program is
being cut.

Phase 2 is the slow-writer measurement. `playtone` gained a third argument —
`playtone <hz> <ms> <pause_ms>` — that opens the continuous stream and hands over
one 256-frame chunk (5.3 ms of audio) every `pause_ms`, i.e. deliberately slower
than real time. The assertion is that the fast stream is CONTINUOUS: 1 kHz band
energy in 40 ms hops, **0 of 65 windows** below a quarter of its median. A
whole-window FFT of a tone with a 300 ms hole in it still has a fine-looking
peak, which is why the hops exist.

The slow stream's own audio is measured as **band power**, not as a coherent bin,
and that is the design showing through the arithmetic: a writer whose cursor has
fallen behind is re-anchored to the live edge, so each of its bursts starts a
fresh phase and a coherent sum over 2.6 s CANCELS them. Measured at 0.022 of the
RMS while the RMS itself said the energy was plainly there. Band power is 21 % of
the total against 0.000003 % in phase 0 — a factor of eight million.

### `tests/linux/audio_lifetime.sh` — `user/audiolife.ad`, all three reports

`audiolife` is the reproduction of three things a person said about a shipped
machine. Each phase is a separate process, because the whole defect class is
about a buffer outliving the process that owns it.

| report | measured |
|--|--|
| (2) "on close it played the last sound effect over and over" | D's 3.000 s clip sounds **once**, for **3.003 s** |
| (1) "on the first sound effect it played the end of the boot jingle" | E's raw 150 ms write sounds as **300 Hz 0.818 of its power, 1000 Hz 0.000** — as itself, not as D's tail |
| (3) "two apps playing audio … 1/2 the sounds don't play" | C's 4.001 s of 1500 Hz music carries **0.65 s of 300 Hz inside it**, against the 0.60 s phase B wrote, from 0.50 s to 1.10 s of the window |

Report (3) could not be *asked* on this line before the mixer. `audiolife` is in
the image (197 KB) for the same reason `hamimgscene` is: it is the reproduction.

### Regressions

`tests/linux/audio_tone.sh` PASS — 1000.28 Hz / 1.0027 s, 444.57 Hz / 0.5039 s
and a 660.32 Hz sine / 0.5088 s, every tone now travelling through the mix ring
and the pump rather than straight to the substream. It drives both halves of the
write protocol: `playtone` stages a clip and sends `start`, `aplay` does
`streamopen` + short-write retries + `drain`.

`tests/linux/audio_capture.sh` PASS — 187 380 bytes in 1000 ms, 97.6 %.

---

## 6. What is still not done

* **No resampling and no format conversion.** Stated above; refused by name
  rather than converted. A resampler is the obvious next piece of work, and it
  would remove the only case in which a program is refused rather than mixed.
* **Summing widths other than s16le.** A lone stream at 8, 24 or 32 bits plays;
  a second one alongside it is refused. `mixer.ad` has the same restriction.
* **Per-stream volume is addressed by SLOT, not by name.** `stream 1 50` means
  "whatever is in slot 1", which is whichever program claimed it first. Hamnix is
  the same. A volume applet that wants to attenuate *the music* has no way to say
  so, and that is a real gap rather than a small one.
* **Capture is still one reader.** `/dev/audioin` opens the capture substream
  directly; nothing mixes or fans it out, and a second reader gets `EBUSY`. The
  same pump-and-shared-ring shape would work in reverse, and nothing here
  prepares for it.
* **The mix runs at the hardware's period granularity.** Latency from a write to
  the codec is the two-period guard plus the ALSA buffer, ~43 ms + ~170 ms at the
  current 8×1024-frame geometry. That is fine for a notification and marginal for
  a game; the geometry is a constant in `pcm_configure` and has never been tuned
  against a measurement.
