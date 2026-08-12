#!/usr/bin/env python3
"""tests/linux/fb_change_probe.py -- ONE INSTRUMENT, POINTED AT TWO DESKTOPS.

WHY THIS FILE EXISTS SEPARATELY FROM de_fps_driver.py
=====================================================
de_fps_driver.py measures our own compositor using wsysd's own presented-frame
counter, which is the best instrument available for it and is available for
nothing else. MATE has no such counter. Comparing "wsysd's n_frames" against
"a number obtained some other way" would be comparing two instruments and
calling it a comparison of two desktops.

So this file is the instrument BOTH sides get, and it knows nothing about
either of them. It watches a framebuffer that is a FILE:

    ours    HAMFB_FILE     1280x800, 4 bytes/px, stride 5120, offset 0
    MATE    Xvfb -fbdir    1280x800, 4 bytes/px, stride 5120, offset 160
                           (an XWD header; the pixels after it are identical
                           in layout to ours, which is why this works at all)

and it answers two questions with the same code on both:

  count     how many times a second does the screen CHANGE, sampled at a
            fixed high rate. This is NOT a presentation counter and is not
            claimed to be one -- it is a change rate, and it is an upper
            bound on frames when the sampler is faster than the desktop and
            a lower bound when it is slower. It is CALIBRATED on our side
            against wsysd's real presentation counter (they agree to a few
            percent, which is what makes it usable on the side that has no
            counter). Its sample rate is printed with every result, because
            a change rate quoted without the sampler's rate is meaningless.

  latency   time from handing an input event to the next process, to the
            first sampled framebuffer that differs. On our side the handoff
            is a write(2) of an evdev record to the file wsysd polls; on
            MATE's it is a write(2) of a command line to a resident
            `xdotool -`. Both clocks therefore start at "this process has
            let go of the input", which is the only definition that can mean
            the same thing on both.

WHAT THIS INSTRUMENT CANNOT SEE, STATED SO IT IS NOT LATER FORGOTTEN
====================================================================
A partial draw. Neither X nor wsysd writes its framebuffer atomically, so a
sample can catch a half-drawn screen and be counted as a change. That
inflates `count` on whichever side draws in more separate operations -- X,
generally. It is why `count` is reported as a change rate and why the
calibration against a real counter is done and printed rather than assumed.
"""

import argparse
import os
import subprocess
import sys
import time


class Fb:
    def __init__(self, path, w, h, offset=0, stride=None, bpp=4):
        self.fd = os.open(path, os.O_RDONLY)
        self.w, self.h, self.off = w, h, offset
        self.stride = stride if stride else w * bpp

    def band(self, y0, y1):
        y0, y1 = max(0, y0), min(self.h, y1)
        if y1 <= y0:
            return b''
        return os.pread(self.fd, (y1 - y0) * self.stride,
                        self.off + y0 * self.stride)

    def rows_for(self, y, half):
        return (y - half, y + half)


def count_changes(fb, seconds, hz, y0, y1):
    """Sample the band at `hz` and count how often it differs from the last.

    Returns (changes, samples, elapsed, actual_hz).
    """
    period = 1.0 / hz
    prev = fb.band(y0, y1)
    t0 = time.monotonic()
    nxt = t0 + period
    changes = samples = 0
    while True:
        now = time.monotonic()
        if now - t0 >= seconds:
            break
        if now < nxt:
            continue                      # spin: sleep() cannot hold 500 Hz
        nxt += period
        cur = fb.band(y0, y1)
        samples += 1
        if cur != prev:
            changes += 1
            prev = cur
    el = time.monotonic() - t0
    return changes, samples, el, samples / el


class EvdevInjector:
    """OUR side: 24-byte struct input_event records into HAMWSYSD_INPUT."""

    import struct as _s
    EV = _s.Struct('<qqHHi')

    def __init__(self, path, w, h):
        self.fd = os.open(path, os.O_WRONLY | os.O_APPEND)
        self.w, self.h = w, h

    def move(self, x, y):
        buf = b''.join(self.EV.pack(0, 0, t, c, v) for t, c, v in
                       ((3, 0, x * 32768 // self.w), (3, 1, y * 32768 // self.h),
                        (0, 0, 0)))
        t0 = time.monotonic_ns()
        os.write(self.fd, buf)
        return t0

    def close(self):
        os.close(self.fd)


class XdotoolInjector:
    """MATE's side: a RESIDENT `xdotool -`, so the clock is not timing a fork.

    A fresh `xdotool mousemove` per event costs a process spawn and a new X
    connection -- tens of milliseconds, which would be charged to MATE and
    would be entirely this harness's fault. Script mode keeps one process and
    one connection open for the whole run, so what is timed is a write to a
    pipe, which is the closest thing X has to our write to the evdev file.
    """

    def __init__(self, display):
        env = dict(os.environ, DISPLAY=display)
        self.p = subprocess.Popen(['xdotool', '-'], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, env=env, bufsize=0)
        self.move(10, 10)
        time.sleep(0.5)

    def move(self, x, y):
        line = ('mousemove %d %d\n' % (x, y)).encode()
        t0 = time.monotonic_ns()
        self.p.stdin.write(line)
        return t0

    def roundtrip_ms(self, n=20):
        """Upper bound on this injector's OWN overhead.

        mousemove followed by getmouselocation: the reply cannot come back
        until xdotool has read the pipe, talked to the X server and been
        answered. Whatever the injection costs, it is less than this. It is
        printed next to MATE's latency so the reader can see how much of that
        number could be the harness rather than the desktop.
        """
        out = []
        for i in range(n):
            t0 = time.monotonic_ns()
            self.p.stdin.write(('mousemove %d %d\ngetmouselocation\n'
                                % (200 + i, 200)).encode())
            self.p.stdout.readline()
            out.append((time.monotonic_ns() - t0) / 1e6)
        out.sort()
        return out[len(out) // 2]

    def close(self):
        try:
            self.p.stdin.close()
            self.p.wait(timeout=3)
        except Exception:
            self.p.kill()


def latency_trials(fb, inj, n, ax, ay, bx, by, band=48, timeout_ms=500,
                   settle=0.06, jitter_ms=17.0):
    """Identical logic for both desktops. See de_fps_driver.py on the jitter:
    a constant settle phase-locks the probe to a tick-driven compositor and
    produces a flatteringly small median that is one lucky phase repeated."""
    import random
    rnd = random.Random(20260812)
    out = []
    y0, y1 = by - band // 2, by + band // 2
    for _ in range(n):
        inj.move(ax, ay)
        time.sleep(settle + rnd.random() * jitter_ms / 1000.0)
        before = fb.band(y0, y1)
        time.sleep(0.02)
        if fb.band(y0, y1) != before:
            continue                      # not settled; discard, do not guess
        t0 = inj.move(bx, by)
        deadline = t0 + timeout_ms * 1_000_000
        hit = None
        while time.monotonic_ns() < deadline:
            if fb.band(y0, y1) != before:
                hit = time.monotonic_ns()
                break
        out.append(None if hit is None else (hit - t0) / 1e6)
    return out


def stats(vals):
    v = sorted(x for x in vals if x is not None)
    if not v:
        return None
    def pct(p):
        return v[min(len(v) - 1, int(round(p / 100.0 * (len(v) - 1))))]
    return dict(n=len(v), lost=sum(1 for x in vals if x is None), min=v[0],
                p50=pct(50), mean=sum(v) / len(v), p95=pct(95), max=v[-1])


def show(tag, s):
    if s is None:
        print('%-26s NO SAMPLE' % tag)
        return
    print('%-26s n=%-4d lost=%-3d min %6.2f  p50 %6.2f  mean %6.2f  '
          'p95 %6.2f  max %6.2f  ms' %
          (tag, s['n'], s['lost'], s['min'], s['p50'], s['mean'], s['p95'],
           s['max']))


def drive_and_count(fb, inj, seconds, rate_hz, sample_hz, w, h, y0, y1):
    """Move the pointer at rate_hz and count screen changes at sample_hz.

    The two cannot run in one thread at 500 Hz and 250 Hz honestly, so the
    injection is folded into the sampling loop: every Nth sample also sends a
    move. The realised rates are measured and reported, not assumed.
    """
    period = 1.0 / sample_hz
    every = max(1, int(round(sample_hz / rate_hz))) if rate_hz > 0 else 0
    prev = fb.band(y0, y1)
    t0 = time.monotonic()
    nxt = t0 + period
    changes = samples = sent = 0
    while True:
        now = time.monotonic()
        if now - t0 >= seconds:
            break
        if now < nxt:
            continue
        nxt += period
        if every and samples % every == 0:
            # THE POINTER STAYS INSIDE THE WATCHED BAND. It has to: this
            # counts changes in [y0,y1), and a pointer that wandered out of
            # the band would produce frames the sampler could not see and an
            # undercount that looked like a slow desktop.
            k = sent
            x = w // 8 + int((3 * w // 4) * abs((k % 60) / 60.0 - 0.5) * 2)
            lo, hi = y0 + 24, y1 - 24
            y = lo + int((hi - lo) * abs((k % 47) / 47.0 - 0.5) * 2)
            inj.move(x, y)
            sent += 1
        cur = fb.band(y0, y1)
        samples += 1
        if cur != prev:
            changes += 1
            prev = cur
    el = time.monotonic() - t0
    return dict(changes=changes, samples=samples, elapsed=el,
                sample_hz=samples / el, input_hz=sent / el,
                change_hz=changes / el)


def show_count(tag, r):
    print('%-26s %6.1f screen changes/s   (sampler ran at %.0f Hz, %d samples '
          'in %.1f s; input %.0f ev/s)' %
          (tag, r['change_hz'], r['sample_hz'], r['samples'], r['elapsed'],
           r['input_hz']))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--fb', required=True)
    ap.add_argument('--geom', default='1280x800')
    ap.add_argument('--offset', type=int, default=0)
    ap.add_argument('--stride', type=int, default=0)
    ap.add_argument('--band', type=int, default=200,
                    help='rows watched, centred on the screen')
    ap.add_argument('--mode', required=True,
                    choices=['count', 'latency', 'drive'])
    ap.add_argument('--inject', choices=['evdev', 'xdotool'], default='evdev')
    ap.add_argument('--evdev', default='')
    ap.add_argument('--display', default='')
    ap.add_argument('--seconds', type=float, default=10.0)
    ap.add_argument('--rate', type=float, default=250.0)
    ap.add_argument('--sample-hz', type=float, default=500.0)
    ap.add_argument('--trials', type=int, default=90)
    ap.add_argument('--tag', default='')
    a = ap.parse_args()

    w, h = (int(v) for v in a.geom.split('x'))
    fb = Fb(a.fb, w, h, a.offset, a.stride or None)
    y0, y1 = h // 2 - a.band // 2, h // 2 + a.band // 2

    inj = None
    if a.mode in ('latency', 'drive'):
        if a.inject == 'evdev':
            inj = EvdevInjector(a.evdev, w, h)
        else:
            inj = XdotoolInjector(a.display)
            print('%-26s xdotool round-trip (mousemove+getmouselocation) '
                  'p50 %.2f ms -- an UPPER BOUND on how much of the latency '
                  'below is this harness' % (a.tag or 'harness:',
                                             inj.roundtrip_ms()))

    if a.mode == 'count':
        c, s, el, hz = count_changes(fb, a.seconds, a.sample_hz, y0, y1)
        print('%-26s %6.1f screen changes/s   (sampler ran at %.0f Hz, %d '
              'samples in %.1f s; NO input)' %
              (a.tag or 'idle', c / el, hz, s, el))
    elif a.mode == 'drive':
        show_count(a.tag or 'driven',
                   drive_and_count(fb, inj, a.seconds, a.rate, a.sample_hz,
                                   w, h, y0, y1))
    else:
        show(a.tag or 'input->pixel',
             stats(latency_trials(fb, inj, a.trials, w // 4, h // 4,
                                  3 * w // 4, 3 * h // 4)))
    if inj:
        inj.close()


if __name__ == '__main__':
    main()
