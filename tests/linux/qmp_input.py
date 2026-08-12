#!/usr/bin/env python3
"""qmp_input.py -- drive a running QEMU's REAL input devices and take screendumps.

WHY THIS EXISTS. `tests/linux/de_mouse_chrome.sh` proves the DE chrome reacts
to a mouse by appending 24-byte `struct input_event` records to the file named
by HAMWSYSD_INPUT. That is the right shape for an offscreen gate, and it is
NOT available inside a VM: in there `wsysd` scans /dev/input/event0..15, which
are QEMU's `virtio-keyboard-pci` and `virtio-tablet-pci`. The only way to put
a keystroke on those from outside is QEMU's own input plumbing, which is what
this speaks -- `input-send-event` over QMP, the same path a VNC viewer's key
press takes. Nothing here writes a wsys ring or an evdev file; a client that
reacts to one of these events reacted to a device event.

Absolute axes are 0..0x7FFF across the screen, which is the range QEMU's
tablet advertises and the range `wsysd`'s EV_ABS branch divides by 32768.

Usage:
  qmp_input.py <sock> screendump <file.ppm>
  qmp_input.py <sock> move <x> <y> <screen_w> <screen_h>
  qmp_input.py <sock> click <x> <y> <screen_w> <screen_h>
  qmp_input.py <sock> type <text>          # ASCII letters/digits/space
  qmp_input.py <sock> key <qcode> [qcode...]
  qmp_input.py <sock> raw '<json>'
"""
import json
import os
import socket
import sys
import time

SHIFTED = {
    '!': '1', '@': '2', '#': '3', '$': '4', '%': '5', '^': '6', '&': '7',
    '*': '8', '(': '9', ')': '0', '_': 'minus', '+': 'equal', ':': 'semicolon',
    '"': 'apostrophe', '<': 'comma', '>': 'dot', '?': 'slash', '~': 'grave_accent',
    '{': 'bracket_left', '}': 'bracket_right', '|': 'backslash',
}
PLAIN = {
    ' ': 'spc', '-': 'minus', '=': 'equal', '.': 'dot', ',': 'comma',
    '/': 'slash', ';': 'semicolon', "'": 'apostrophe', '\n': 'ret',
    '\t': 'tab', '[': 'bracket_left', ']': 'bracket_right', '\\': 'backslash',
    '`': 'grave_accent',
}


class QMP:
    def __init__(self, path):
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.settimeout(20)
        self.s.connect(path)
        self.f = self.s.makefile('rw', encoding='utf-8', newline='\n')
        self._read()                      # the greeting
        self.cmd('qmp_capabilities')

    def _read(self):
        while True:
            line = self.f.readline()
            if not line:
                raise SystemExit('qmp: the monitor closed the connection')
            m = json.loads(line)
            if 'event' in m:              # asynchronous, not our reply
                continue
            return m

    def cmd(self, ex, **args):
        m = {'execute': ex}
        if args:
            m['arguments'] = args
        self.f.write(json.dumps(m) + '\n')
        self.f.flush()
        r = self._read()
        if 'error' in r:
            raise SystemExit('qmp: %s: %s' % (ex, r['error']))
        return r.get('return')

    def send(self, events):
        self.cmd('input-send-event', events=events)


def abs_ev(axis, v):
    return {'type': 'abs', 'data': {'axis': axis, 'value': v}}


def key_ev(qcode, down):
    return {'type': 'key',
            'data': {'down': down, 'key': {'type': 'qcode', 'data': qcode}}}


def qcodes(ch):
    """The qcode(s) for one character, shift included where it is needed."""
    if ch.isdigit():
        return [ch], False
    if 'a' <= ch <= 'z':
        return [ch], False
    if 'A' <= ch <= 'Z':
        return [ch.lower()], True
    if ch in SHIFTED:
        return [SHIFTED[ch]], True
    if ch in PLAIN:
        return [PLAIN[ch]], False
    raise SystemExit('qmp: no qcode for %r' % ch)


def main():
    sock, op = sys.argv[1], sys.argv[2]
    q = QMP(sock)
    if op == 'screendump':
        out = os.path.abspath(sys.argv[3])
        q.cmd('screendump', filename=out)
        # screendump is asynchronous in the sense that the file appears when
        # the device has drawn it; wait for a non-growing file rather than
        # trusting the return.
        prev = -1
        for _ in range(60):
            time.sleep(0.25)
            try:
                n = os.path.getsize(out)
            except OSError:
                continue
            if n > 0 and n == prev:
                break
            prev = n
        print('screendump %s (%d bytes)' % (out, os.path.getsize(out)))
    elif op in ('move', 'click'):
        x, y, w, h = (int(v) for v in sys.argv[3:7])
        ax = x * 0x7FFF // max(w - 1, 1)
        ay = y * 0x7FFF // max(h - 1, 1)
        q.send([abs_ev('x', ax), abs_ev('y', ay)])
        if op == 'click':
            time.sleep(0.4)
            q.send([{'type': 'btn', 'data': {'down': True, 'button': 'left'}}])
            time.sleep(0.25)
            q.send([{'type': 'btn', 'data': {'down': False, 'button': 'left'}}])
        print('%s %d,%d -> abs %d,%d' % (op, x, y, ax, ay))
    elif op == 'type':
        text = sys.argv[3]
        for ch in text:
            codes, shift = qcodes(ch)
            ev = []
            if shift:
                ev.append(key_ev('shift', True))
            for c in codes:
                ev.append(key_ev(c, True))
            for c in reversed(codes):
                ev.append(key_ev(c, False))
            if shift:
                ev.append(key_ev('shift', False))
            q.send(ev)
            time.sleep(0.12)
        print('typed %r' % text)
    elif op == 'key':
        for c in sys.argv[3:]:
            q.send([key_ev(c, True), key_ev(c, False)])
            time.sleep(0.12)
        print('keys %s' % ' '.join(sys.argv[3:]))
    elif op == 'raw':
        print(json.dumps(q.cmd(*json.loads(sys.argv[3]))))
    elif op == 'quit':
        try:
            q.cmd('quit')
        except SystemExit:
            pass
        print('quit sent')
    else:
        raise SystemExit(__doc__)


if __name__ == '__main__':
    main()
