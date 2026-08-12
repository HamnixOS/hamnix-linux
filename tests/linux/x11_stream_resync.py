"""Does one oversized X11 request desynchronise x11srv's connection?

The X11 request length field is 16 bits in 4-byte units, so a client may
declare far more than the server's 4096-byte request buffer. The server used to
clamp the read to 4092 and carry on, leaving the rest of the payload in the
socket to be read as the NEXT request's header.

This sends: a GetGeometry (works), then ONE oversized request, then another
GetGeometry -- and asks whether the second one still gets a well-formed reply
carrying the sequence number it should. That is the difference between a
desynchronised stream and a healthy one, asked from outside the server.
"""
import socket
import struct
import sys
import time

PORT = 6000
host = '127.0.0.1'


def setup(s):
    # byte-order 'l', pad, major 11, minor 0, auth name len 0, auth data len 0, pad
    s.sendall(struct.pack('<BBHHHHH', ord('l'), 0, 11, 0, 0, 0, 0))
    pre = recvn(s, 8)
    if not pre or pre[0] != 1:
        return None, 'server refused the connection: %r' % (pre,)
    add_units = struct.unpack('<H', pre[6:8])[0]
    body = recvn(s, add_units * 4)
    if body is None:
        return None, 'short setup body'
    return body, None


def recvn(s, n):
    out = b''
    while len(out) < n:
        try:
            b = s.recv(n - len(out))
        except socket.timeout:
            return None
        if not b:
            return None
        out += b
    return out


def get_geometry(s, drawable=1):
    # opcode 14, unused, length 2 units, drawable
    s.sendall(struct.pack('<BBHI', 14, 0, 2, drawable))
    rep = recvn(s, 32)
    if rep is None:
        return None, 'no reply (timed out)'
    kind = rep[0]
    seq = struct.unpack('<H', rep[2:4])[0]
    if kind == 1:
        return seq, None
    if kind == 0:
        return None, 'ERROR reply, code %d, seq %d' % (rep[1], seq)
    return None, 'not a reply at all: first byte %d' % kind


def main():
    s = socket.create_connection((host, PORT), timeout=5)
    s.settimeout(5)
    body, err = setup(s)
    if err:
        print('SETUP FAILED:', err)
        return 2
    print('setup ok, %d bytes of additional data' % len(body))

    seq1, err = get_geometry(s)
    print('first  GetGeometry: %s' % (err or 'reply, seq %d' % seq1))
    if err:
        return 2

    # ONE oversized request: declared 2001 units = 8004 bytes, body 8000,
    # which is far past the server's 4092-byte request buffer.
    units = 2001
    total = units * 4
    payload = struct.pack('<BBH', 14, 0, units) + b'\xAB' * (total - 4)
    assert len(payload) == total
    s.sendall(payload)
    print('sent an oversized request: declared %d bytes (buffer is 4096)' % total)
    time.sleep(0.5)

    # Drain whatever the server said about the oversized one (a reply or an
    # error is fine; what matters is the NEXT request).
    s.settimeout(1.0)
    drained = 0
    while True:
        try:
            b = s.recv(4096)
        except socket.timeout:
            break
        if not b:
            break
        drained += len(b)
    print('drained %d bytes of server response to it' % drained)

    s.settimeout(5)
    seq2, err = get_geometry(s)
    if err:
        print('second GetGeometry: %s' % err)
        print('VERDICT: DESYNCHRONISED -- the connection is unusable after one '
              'oversized request')
        return 1
    print('second GetGeometry: reply, seq %d' % seq2)
    print('VERDICT: IN SYNC -- the server drained the excess and kept serving')
    return 0


if __name__ == '__main__':
    sys.exit(main())
