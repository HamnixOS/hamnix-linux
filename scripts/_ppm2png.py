#!/usr/bin/env python3
# scripts/_ppm2png.py — QEMU screendump (binary PPM) -> PNG.
#
# The same encoder scripts/hamlinux_shot.sh carries inline as a heredoc, in a
# file this time: tests/linux/distro_menu.sh takes three screendumps in one
# boot, and a third copy of a PNG encoder pasted into a test is how copies
# drift. hamlinux_shot.sh still has its own; it is left alone deliberately
# (other work is running against it right now) and should call this instead
# next time someone is in there.
#
# Usage: _ppm2png.py in.ppm out.png
import sys
import zlib
import struct

with open(sys.argv[1], 'rb') as f:
    assert f.readline().strip() == b'P6', 'not a binary PPM'
    line = f.readline()
    while line.startswith(b'#'):
        line = f.readline()
    w, h = map(int, line.split())
    f.readline()                       # maxval
    data = f.read()

raw = bytearray()
for y in range(h):
    raw.append(0)                      # filter type 0 for each scanline
    raw += data[y * w * 3:(y + 1) * w * 3]


def chunk(tag, payload):
    c = tag + payload
    return struct.pack('>I', len(payload)) + c + struct.pack('>I', zlib.crc32(c))


png = (b'\x89PNG\r\n\x1a\n'
       + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
       + chunk(b'IDAT', zlib.compress(bytes(raw), 6))
       + chunk(b'IEND', b''))
with open(sys.argv[2], 'wb') as f:
    f.write(png)
print(f"{sys.argv[2]}  {w}x{h}")
