#!/usr/bin/env python3
"""ppmdiff.py -- what changed between two QEMU screendumps, and where.

The framebuffer is what a person looking at this machine sees, so it is the
last word on "did anything happen". Two questions only:

  rect  <a.ppm> [x y w h]        distinct colours + a digest of that rectangle
  diff  <a.ppm> <b.ppm> [x y w h]  how many pixels differ, and the bounding box
                                   of the difference
  pct   <a.ppm> <rrggbb> x y w h   what percent of that rectangle is EXACTLY
                                   that colour -- prints one integer
  png   <a.ppm> <out.png>        so a human can look at it
  map   <a.ppm> [x y w h]        a coarse ASCII map, one char per 16x16 cell

`pct` is the question tests/linux/de_appmenu_brisk.sh asks of the offscreen
framebuffer ("is row 0 the white search field, is row 1 the category-button
strip"), asked of a QEMU screendump instead, so the SAME assertion can be made
about a real booted machine. It prints a bare integer so a shell can compare
it, and nothing else.
"""
import sys
import zlib
import struct


def read_ppm(path):
    d = open(path, 'rb').read()
    if not d.startswith(b'P6'):
        raise SystemExit('%s is not a P6 ppm' % path)
    i, f = 2, []
    while len(f) < 3:
        while i < len(d) and d[i:i + 1].isspace():
            i += 1
        if d[i:i + 1] == b'#':
            while d[i:i + 1] != b'\n':
                i += 1
            continue
        j = i
        while j < len(d) and not d[j:j + 1].isspace():
            j += 1
        f.append(int(d[i:j]))
        i = j
    i += 1
    w, h = f[0], f[1]
    return w, h, d[i:i + w * h * 3]


def rect_args(w, h, argv):
    if len(argv) >= 4:
        x, y, rw, rh = (int(v) for v in argv[:4])
    else:
        x, y, rw, rh = 0, 0, w, h
    return x, y, min(rw, w - x), min(rh, h - y)


def main():
    op = sys.argv[1]
    if op == 'rect':
        w, h, px = read_ppm(sys.argv[2])
        x, y, rw, rh = rect_args(w, h, sys.argv[3:])
        cols = {}
        buf = bytearray()
        for j in range(y, y + rh):
            row = (j * w + x) * 3
            seg = px[row:row + rw * 3]
            buf += seg
            for k in range(0, len(seg), 3):
                c = seg[k:k + 3]
                cols[bytes(c)] = cols.get(bytes(c), 0) + 1
        top = sorted(cols.items(), key=lambda kv: -kv[1])[:4]
        print('rect %dx%d+%d+%d: %d distinct of %d px; %s; digest %08x'
              % (rw, rh, x, y, len(cols), rw * rh,
                 ', '.join('#%s x%d' % (c.hex(), n) for c, n in top),
                 zlib.crc32(bytes(buf))))
    elif op == 'diff':
        w, h, a = read_ppm(sys.argv[2])
        w2, h2, b = read_ppm(sys.argv[3])
        if (w, h) != (w2, h2):
            raise SystemExit('different sizes: %dx%d vs %dx%d' % (w, h, w2, h2))
        x, y, rw, rh = rect_args(w, h, sys.argv[4:])
        n = 0
        minx, miny, maxx, maxy = w, h, -1, -1
        for j in range(y, y + rh):
            row = (j * w + x) * 3
            sa = a[row:row + rw * 3]
            sb = b[row:row + rw * 3]
            if sa == sb:
                continue
            for k in range(0, len(sa), 3):
                if sa[k:k + 3] != sb[k:k + 3]:
                    n += 1
                    i = x + k // 3
                    minx = min(minx, i); maxx = max(maxx, i)
                    miny = min(miny, j); maxy = max(maxy, j)
        tot = rw * rh
        if n == 0:
            print('diff %dx%d+%d+%d: IDENTICAL (0 of %d px)' % (rw, rh, x, y, tot))
        else:
            print('diff %dx%d+%d+%d: %d of %d px (%.2f%%) differ; bbox '
                  '%dx%d+%d+%d'
                  % (rw, rh, x, y, n, tot, 100.0 * n / tot,
                     maxx - minx + 1, maxy - miny + 1, minx, miny))
    elif op == 'pct':
        w, h, px = read_ppm(sys.argv[2])
        c = sys.argv[3].lstrip('#')
        want = bytes((int(c[0:2], 16), int(c[2:4], 16), int(c[4:6], 16)))
        x, y, rw, rh = rect_args(w, h, sys.argv[4:])
        tot = hit = 0
        for j in range(y, y + rh):
            row = (j * w + x) * 3
            seg = px[row:row + rw * 3]
            for k in range(0, len(seg), 3):
                tot += 1
                if seg[k:k + 3] == want:
                    hit += 1
        print(0 if tot == 0 else hit * 100 // tot)
    elif op == 'map':
        w, h, px = read_ppm(sys.argv[2])
        x, y, rw, rh = rect_args(w, h, sys.argv[3:])
        ramp = ' .:-=+*#%@'
        for j in range(y, y + rh, 16):
            line = ''
            for i in range(x, x + rw, 16):
                o = (j * w + i) * 3
                lum = (px[o] * 30 + px[o + 1] * 59 + px[o + 2] * 11) // 100
                line += ramp[min(lum * len(ramp) // 256, len(ramp) - 1)]
            print(line)
    elif op == 'png':
        w, h, px = read_ppm(sys.argv[2])
        rows = bytearray()
        for j in range(h):
            rows.append(0)
            rows += px[j * w * 3:(j + 1) * w * 3]

        def chunk(t, p):
            c = t + p
            return struct.pack('>I', len(p)) + c + struct.pack('>I', zlib.crc32(c))
        open(sys.argv[3], 'wb').write(
            b'\x89PNG\r\n\x1a\n'
            + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(bytes(rows), 6))
            + chunk(b'IEND', b''))
        print('wrote %s (%dx%d)' % (sys.argv[3], w, h))
    else:
        raise SystemExit(__doc__)


if __name__ == '__main__':
    main()
