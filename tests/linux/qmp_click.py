#!/usr/bin/env python3
"""Click a real pointer into a running QEMU guest, over QMP.

The guest has a `-device virtio-tablet-pci`: an ABSOLUTE pointer, which is
what a person's mouse looks like to this VM. QMP's `input-send-event` puts
the events on that device's queue, so what the guest reads out of
/dev/input/eventN is a byte-for-byte real `struct input_event` stream that
nothing in the guest can tell from a hand on a mouse. The HMP `mouse_move`
verb is RELATIVE and cannot land on a 26-pixel-tall button; abs axes can.

usage: qmpclick.py <sock> <screen_w> <screen_h> <x> <y>
"""
import json, socket, sys, time

sock, W, H, X, Y = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
ABS_MAX = 32767

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sock)
f = s.makefile("rwb")


def cmd(obj):
    f.write((json.dumps(obj) + "\n").encode())
    f.flush()
    while True:
        line = f.readline()
        if not line:
            raise SystemExit("qmp: connection closed")
        m = json.loads(line)
        if "return" in m or "error" in m:
            return m


f.readline()                      # the greeting
cmd({"execute": "qmp_capabilities"})


def move(x, y):
    return cmd({"execute": "input-send-event", "arguments": {"events": [
        {"type": "abs", "data": {"axis": "x", "value": x * ABS_MAX // W}},
        {"type": "abs", "data": {"axis": "y", "value": y * ABS_MAX // H}},
    ]}})


def btn(down):
    return cmd({"execute": "input-send-event", "arguments": {"events": [
        {"type": "btn", "data": {"button": "left", "down": down}},
    ]}})


# The timing of a hand: arrive, settle, press, hold, release. Each phase is a
# separate QMP command so the compositor's poll sees the button EDGES the way
# a real device delivers them.
r = move(X, Y)
print("move ->", r)
time.sleep(0.6)
print("down ->", btn(True))
time.sleep(0.35)
print("up   ->", btn(False))
time.sleep(0.3)
