#!/usr/bin/env python3
"""tests/linux/de_fps_driver.py -- the INSTRUMENT for de_fps_latency.sh.

WHAT IT MEASURES, AND WHY EACH NUMBER IS THE ONE IT CLAIMS TO BE
===============================================================
Two questions about a running `wsysd`, both answered from OUTSIDE it:

  fps      frames the compositor PRESENTED per second under a stated load.
           The counter is wsysd's own `n_frames`, published on
           /dev/wsys/wsysd/state, and it is incremented AFTER paint_frame()
           or cursor_only_frame() -- both of which end in present_rows(),
           which write(2)s the composite to /dev/fb. It is therefore a count
           of PRESENTATIONS, not of render calls that returned. (A render
           call that returned without presenting is exactly the
           success-shaped answer NORTH_STAR.md warns about; this counter
           cannot give it, because the increment is downstream of the write.)

  latency  input-to-pixel. The clock STARTS at the last instruction before
           the write(2) that makes the evdev record visible to wsysd -- not
           after it was queued -- and STOPS when the framebuffer bytes at
           the place the pointer is going to have changed. Nothing between
           those two points is excluded.

THE INSTRUMENT IS TESTED BEFORE IT IS BELIEVED (--selftest)
==========================================================
This project has been fooled four times by a tool that created or hid what
it measured. So before any number is reported:

  no-input      with no record injected, the pixel watcher must NOT fire
                inside a full timeout. A watcher that fires on its own
                reports latency 0 and reads as "instant".
  stopped       inject a record, then SIGSTOP wsysd for a KNOWN duration and
                SIGCONT it. The measured latency must come back >= that
                duration. This is the known quantity: a deliberately slowed
                frame HAS to show up as slower, or the clock is not attached
                to the thing it claims to time.
  counting      inject exactly N pointer moves spaced well past the tick;
                the presented-frame counter must advance by about N. If it
                advances by 0 the counter is dead; if it free-runs, it is
                counting something other than presentations.
"""

import argparse
import os
import random
import struct
import subprocess
import sys
import time

EV = struct.Struct('<qqHHi')          # struct input_event on x86-64
SYN = (0, 0, 0)
BTN_LEFT = 272


class Fb:
    """The framebuffer as a file. Reading it attaches to nothing."""

    def __init__(self, path, w, h):
        self.fd = os.open(path, os.O_RDONLY)
        self.w, self.h = w, h

    def band(self, y0, y1):
        y0 = max(0, y0)
        y1 = min(self.h, y1)
        if y1 <= y0:
            return b''
        return os.pread(self.fd, (y1 - y0) * self.w * 4, y0 * self.w * 4)


class Input:
    """Synthetic evdev, byte-identical to what /dev/input/eventN delivers."""

    def __init__(self, path, w, h):
        self.fd = os.open(path, os.O_WRONLY | os.O_APPEND)
        self.w, self.h = w, h

    def _pack(self, recs):
        return b''.join(EV.pack(0, 0, t, c, v) for t, c, v in recs)

    def move(self, x, y):
        # Absolute axes in the 0..32767 range QEMU's usb-tablet advertises,
        # which is the branch wsysd's pump_input takes for EV_ABS.
        return [(3, 0, x * 32768 // self.w), (3, 1, y * 32768 // self.h), SYN]

    def button(self, down):
        return [(1, BTN_LEFT, 1 if down else 0), SYN]

    def send(self, recs):
        """Returns (t_before_write, t_after_write) in ns."""
        buf = self._pack(recs)
        t0 = time.monotonic_ns()
        os.write(self.fd, buf)
        t1 = time.monotonic_ns()
        return t0, t1


def read_state(catbin, _tries=12):
    """wsysd's own published counters. `cat` of a file in /dev/wsys.

    A TORN READ RETURNS NOTHING, AND IT USED TO BECOME A FRAME COUNT.
    /dev/wsys/wsysd/state is rewritten in place by wsysd every time it
    publishes, and a reader that lands mid-rewrite gets an EMPTY body with
    exit status 0 -- measured at 1-in-200 on an idle desktop and 4-in-200 on
    a routed one, in both arms, so it is a property of the file and not of
    the mediator. This function used to return {} for that, and every caller
    then did `s.get('frames', 0)`, which turned one torn read into a frame
    delta of MINUS THE WHOLE COUNTER (seen: -173 frames in 10 s) or of the
    whole counter (seen: +212). Both were reported as measurements. One of
    them failed the instrument's own counting selftest -- which is the only
    reason it was ever noticed.

    So: retry, and say so out loud if the retries do not get an answer,
    rather than hand back a dictionary that is missing the key the caller is
    about to default to zero.
    """
    for attempt in range(_tries):
        try:
            out = subprocess.run([catbin, '/dev/wsys/wsysd/state'],
                                 capture_output=True, timeout=10).stdout.decode()
        except Exception:
            out = ''
        f = out.split()
        d = {f[i]: int(f[i + 1]) for i in range(0, len(f) - 1, 2)
             if f[i + 1].lstrip('-').isdigit()}
        if 'frames' in d:
            return d
        time.sleep(0.01)
    print('WARNING: /dev/wsys/wsysd/state gave no frame counter in %d tries -- '
          'every frame number derived from this sample is unusable' % _tries)
    return {}


def proc_cpu_ticks(pid):
    with open('/proc/%d/stat' % pid) as fh:
        s = fh.read()
    fields = s[s.rindex(')') + 2:].split()
    return int(fields[11]) + int(fields[12])      # utime + stime


HZ = os.sysconf('SC_CLK_TCK')


# ---------------------------------------------------------------- latency ---
def watch_change(fb, y0, y1, before, deadline_ns):
    """Spin until the band differs from `before`. Returns ns, or None."""
    while time.monotonic_ns() < deadline_ns:
        if fb.band(y0, y1) != before:
            return time.monotonic_ns()
    return None


def latency_trials(fb, inp, n, ax, ay, bx, by, band=48, timeout_ms=400,
                   settle=0.06, stopper=None, stop_ms=0, jitter=True):
    """Move the pointer A->B and time until the pixels at B change.

    THE PHASE MATTERS, AND THE FIRST VERSION OF THIS FUNCTION GOT IT WRONG.
    wsysd's loop is a fixed 16 ms tick, so how long an input waits depends on
    WHERE IN THAT TICK it arrived. With a constant settle of 60 ms + 20 ms the
    injection landed at the same phase every single trial -- 80 ms is exactly
    five ticks -- and the gate measured a median of 1.0 ms and called the
    desktop essentially instantaneous. That is a measurement of one favourable
    phase repeated 40 times, not of the latency a person experiences, and it
    is precisely the success-shaped answer NORTH_STAR.md forbids: the number
    was small because the instrument was in step with the thing it timed.

    So the settle is jittered by a full tick's worth of random delay, which
    samples the phase uniformly. The spread that comes back IS the answer --
    a mean near half a tick means the wait is the loop's sampling delay, and
    a max near a whole tick is the worst case a person hits.
    """
    rnd = random.Random(20260812)          # fixed seed: repeatable, not phased
    out = []
    for i in range(n):
        # Park at A and let the compositor finish presenting that.
        inp.send(inp.move(ax, ay))
        time.sleep(settle + (rnd.random() * 0.017 if jitter else 0.0))
        y0, y1 = by - band // 2, by + band // 2
        before = fb.band(y0, y1)
        # Confirm the band is QUIESCENT: two identical reads a tick apart.
        time.sleep(0.02)
        if fb.band(y0, y1) != before:
            continue                       # still settling; discard, do not guess
        t0, _ = inp.send(inp.move(bx, by))
        if stopper is not None:
            os.kill(stopper, 19)           # SIGSTOP -- the known quantity
            time.sleep(stop_ms / 1000.0)
            os.kill(stopper, 18)           # SIGCONT
        t1 = watch_change(fb, y0, y1, before, t0 + timeout_ms * 1_000_000)
        if t1 is None:
            out.append(None)
        else:
            out.append((t1 - t0) / 1e6)
    return out


def stats(vals):
    v = sorted(x for x in vals if x is not None)
    if not v:
        return None
    def pct(p):
        return v[min(len(v) - 1, int(round(p / 100.0 * (len(v) - 1))))]
    return dict(n=len(v), lost=sum(1 for x in vals if x is None),
                min=v[0], p50=pct(50), p95=pct(95), max=v[-1],
                mean=sum(v) / len(v))


def show(tag, s):
    if s is None:
        print('%-22s NO SAMPLE' % tag)
        return
    print('%-22s n=%-4d lost=%-3d min %6.2f  p50 %6.2f  mean %6.2f  '
          'p95 %6.2f  max %6.2f  ms' %
          (tag, s['n'], s['lost'], s['min'], s['p50'], s['mean'],
           s['p95'], s['max']))


# -------------------------------------------------------------------- fps ---
def fps_run(fb, inp, cat, pid, seconds, rate_hz, w, h, drag=False,
            title_xy=None):
    """Drive the pointer for `seconds` and count PRESENTED frames."""
    if drag:
        inp.send(inp.move(*title_xy))
        time.sleep(0.2)
        inp.send(inp.button(True))
        time.sleep(0.2)

    s0 = read_state(cat)
    c0 = proc_cpu_ticks(pid)
    t0 = time.monotonic()
    period = 1.0 / rate_hz if rate_hz > 0 else 1.0
    n_sent = 0
    nxt = t0
    # A lissajous path, so the pointer never repeats a position (a repeated
    # position produces no signature change and therefore no frame -- the
    # load has to actually be a load).
    while True:
        now = time.monotonic()
        if now - t0 >= seconds:
            break
        if rate_hz <= 0:
            # No pointer at all: the load is whatever else is on the desktop.
            time.sleep(0.05)
            continue
        if now >= nxt:
            k = n_sent
            if drag:
                x = title_xy[0] + int(120 * (0.5 - abs((k % 40) / 40.0 - 0.5)))
                y = title_xy[1] + int(80 * (0.5 - abs((k % 34) / 34.0 - 0.5)))
            else:
                x = w // 4 + int((w // 2) * abs((k % 60) / 60.0 - 0.5) * 2)
                y = h // 4 + int((h // 2) * abs((k % 47) / 47.0 - 0.5) * 2)
            inp.send(inp.move(x, y))
            n_sent += 1
            nxt += period
        else:
            time.sleep(min(0.002, max(0.0, nxt - now)))
    t1 = time.monotonic()
    c1 = proc_cpu_ticks(pid)
    s1 = read_state(cat)

    if drag:
        inp.send(inp.button(False))

    el = t1 - t0
    d_f = s1.get('frames', 0) - s0.get('frames', 0)
    d_c = s1.get('curframes', 0) - s0.get('curframes', 0)
    cpu = (c1 - c0) / HZ / el * 100.0
    return dict(elapsed=el, sent=n_sent, frames=d_f, curframes=d_c,
                full=d_f - d_c, fps=d_f / el, cpu_pct=cpu)


def show_fps(tag, r, cpu_samples=None):
    # THE CPU FIGURE IS A MEDIAN WHEN --reps SAYS SO, AND EVERY SAMPLE IS
    # PRINTED. Read the note on `--reps` in main() before quoting one number.
    line = ('%-30s %6.1f fps   (%d presented in %.2f s; %d full + %d '
            'cursor-only)   input %d ev/s   wsysd cpu %.1f%%' %
            (tag, r['fps'], r['frames'], r['elapsed'], r['full'],
             r['curframes'], round(r['sent'] / r['elapsed']), r['cpu_pct']))
    if cpu_samples and len(cpu_samples) > 1:
        line += ' (median of %d; samples: %s)' % (
            len(cpu_samples), ' '.join('%.1f' % c for c in cpu_samples))
    else:
        line += ' (ONE SAMPLE -- see --reps)'
    print(line)


# --------------------------------------------------------------- selftest ---
def selftest(fb, inp, cat, pid, w, h):
    ok = True

    # 1. The watcher must not fire on its own.
    y0, y1 = h // 2 - 24, h // 2 + 24
    before = fb.band(y0, y1)
    t = watch_change(fb, y0, y1, before,
                     time.monotonic_ns() + 1_500_000_000)
    if t is None:
        print('selftest: PASS  no-input   the pixel watcher did not fire in '
              '1.5 s with nothing injected')
    else:
        print('selftest: FAIL  no-input   the watcher fired with no input -- '
              'it would report latency for a frame nobody asked for')
        ok = False

    # 2. It must fire when something IS injected.
    s = stats(latency_trials(fb, inp, 5, w // 4, h // 4, 3 * w // 4,
                             3 * h // 4))
    if s and s['n'] >= 3:
        print('selftest: PASS  fires      %d/5 injected moves produced a pixel '
              'change (p50 %.2f ms)' % (s['n'], s['p50']))
    else:
        print('selftest: FAIL  fires      injected moves produced no pixel '
              'change -- the instrument sees nothing')
        ok = False

    # 3. THE KNOWN QUANTITY. A deliberately slowed compositor must measure
    #    slower, by about the amount it was slowed.
    for stop_ms in (100, 250):
        # The timeout has to leave room for the frame ITSELF on top of the
        # stop. stop_ms + 400 was enough on the software path (0.6 ms/frame)
        # and lost samples on the GPU path (70 ms/frame, and coalesced), where
        # the tool then reported "lost" for a compositor that was working
        # exactly as measured. A budget that only fits the fast path turns a
        # slow result into a broken instrument.
        s = stats(latency_trials(fb, inp, 5, w // 4, h // 4, 3 * w // 4,
                                 3 * h // 4, timeout_ms=stop_ms + 2000,
                                 stopper=pid, stop_ms=stop_ms))
        if s and s['min'] >= stop_ms * 0.9:
            print('selftest: PASS  stopped    wsysd SIGSTOPped %d ms -> '
                  'measured min %.1f ms, p50 %.1f ms (the slowdown shows up)'
                  % (stop_ms, s['min'], s['p50']))
        else:
            print('selftest: FAIL  stopped    wsysd SIGSTOPped %d ms but the '
                  'measurement was %s -- the clock is not timing the frame'
                  % (stop_ms, ('%.1f ms' % s['min']) if s else 'lost'))
            ok = False

    # 4. The frame counter counts presentations, against a known count.
    N = 20
    s0 = read_state(cat)
    for i in range(N):
        inp.send(inp.move(200 + (i % 2) * 300, 200 + i * 7))
        time.sleep(0.05)                    # >> the 16 ms tick: one frame each
    time.sleep(0.2)
    d = read_state(cat).get('frames', 0) - s0.get('frames', 0)
    if N * 0.75 <= d <= N * 1.35:
        print('selftest: PASS  counting   %d distinct pointer moves spaced 50 '
              'ms apart advanced the presented-frame counter by %d' % (N, d))
    else:
        print('selftest: FAIL  counting   %d spaced moves advanced the counter '
              'by %d -- it is not counting one presentation per move' % (N, d))
        ok = False
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--fb', required=True)
    ap.add_argument('--input', required=True)
    ap.add_argument('--cat', required=True)
    ap.add_argument('--pid', type=int, required=True)
    ap.add_argument('--geom', default='1280x800')
    ap.add_argument('--mode', required=True,
                    choices=['selftest', 'idle', 'fps', 'latency'])
    ap.add_argument('--seconds', type=float, default=10.0)
    ap.add_argument('--rate', type=float, default=250.0)
    ap.add_argument('--trials', type=int, default=120)
    ap.add_argument('--drag', action='store_true')
    ap.add_argument('--title', default='')
    ap.add_argument('--tag', default='')
    ap.add_argument('--nojitter', action='store_true')
    # Default 1 so existing callers are unchanged in cost and output shape;
    # a caller that wants to QUOTE the cpu column must ask for repeats, and
    # the column says "ONE SAMPLE" when it has not.
    ap.add_argument('--reps', type=int, default=1,
                    help='repeat the whole fps load N times; report the '
                         'median cpu and print every sample')
    a = ap.parse_args()

    w, h = (int(v) for v in a.geom.split('x'))
    fb = Fb(a.fb, w, h)
    inp = Input(a.input, w, h)

    if a.mode == 'selftest':
        sys.exit(0 if selftest(fb, inp, a.cat, a.pid, w, h) else 1)

    if a.mode == 'idle':
        s0 = read_state(a.cat)
        c0 = proc_cpu_ticks(a.pid)
        t0 = time.monotonic()
        time.sleep(a.seconds)
        el = time.monotonic() - t0
        c1 = proc_cpu_ticks(a.pid)
        s1 = read_state(a.cat)
        print('idle: %.1f s with NO input -- %d frames presented, '
              'wsysd cpu %.2f%% (utime+stime from /proc/%d/stat over the '
              'interval, not ps pcpu)' %
              (el, s1.get('frames', 0) - s0.get('frames', 0),
               (c1 - c0) / HZ / el * 100.0, a.pid))
        return

    if a.mode == 'fps':
        txy = None
        if a.title:
            txy = tuple(int(v) for v in a.title.split(','))
        # REPEAT THE WHOLE LOAD, because the CPU figure is a noisy quantity and
        # the noise is BETWEEN RUNS, not within one. Measured on this host, the
        # same binary under the identical pointer load gave 17.1, 11.8 and 15.2
        # in three consecutive 10 s runs, and a second binary gave 9.5, 8.6 and
        # 4.2. A single sample from each therefore supports almost any story
        # you like, including a 4x REGRESSION THAT DID NOT HAPPEN -- which is
        # what a single sample of this column was read as once.
        #
        # Sub-sampling inside one window would NOT fix it: the driver's column
        # and cpuprobe.sh, run against the same pid over the same 10 s, agree
        # to within 0.2 points on every run (17.1/17.1, 11.8/11.8, 15.2/15.0,
        # 9.5/9.5, 8.6/8.5, 4.2/4.2). The instrument is right; the QUANTITY
        # moves between runs. So the load itself is what has to be repeated.
        #
        # fps is not the problem and is not why this exists -- it came back
        # 57.1, 57.9, 57.5 across the same three runs. The median is reported
        # for both so the row stays internally consistent.
        runs = []
        for _ in range(max(1, a.reps)):
            runs.append(fps_run(fb, inp, a.cat, a.pid, a.seconds, a.rate, w, h,
                                drag=a.drag, title_xy=txy))
        cpus = sorted(x['cpu_pct'] for x in runs)
        med = sorted(runs, key=lambda x: x['cpu_pct'])[len(runs) // 2]
        med = dict(med)
        med['fps'] = sorted(x['fps'] for x in runs)[len(runs) // 2]
        show_fps(a.tag or ('drag' if a.drag else 'pointer'), med, cpus)
        return

    if a.mode == 'latency':
        v = latency_trials(fb, inp, a.trials, w // 4, h // 4,
                           3 * w // 4, 3 * h // 4, jitter=not a.nojitter)
        show(a.tag or 'input->pixel', stats(v))
        return


if __name__ == '__main__':
    main()
