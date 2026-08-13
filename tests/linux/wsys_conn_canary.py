#!/usr/bin/env python3
"""One connection, HELLO, report exactly what the server did with it."""
import socket, struct, sys, select, time

seg, leaf = sys.argv[1], sys.argv[2]
NAME = ("\0hamnix-wsys/%s/%s" % (seg, leaf)).encode()
s = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
try:
    s.connect(NAME)
except OSError as e:
    print("canary CONNECT-FAILED %s" % e.strerror); sys.exit(0)
print("canary connect OK")
# struct wsrv_hdr: magic u32, op u16, flags u16, wid i32, tag u32, len u32
hdr = struct.pack("<IHHiII", 0x51525357, 1, 1, 0, 7, 4) + struct.pack("<I", 8)
try:
    s.send(hdr)
    print("canary hello sent")
except OSError as e:
    print("canary SEND-FAILED %s" % e.strerror); sys.exit(0)
r, _, _ = select.select([s], [], [], 3.0)
if not r:
    print("canary NO-REPLY (timeout)"); sys.exit(0)
try:
    d = s.recv(65536)
except OSError as e:
    print("canary RECV-FAILED %s" % e.strerror); sys.exit(0)
if d == b"":
    print("canary REFUSED (server closed the connection: EOF)")
else:
    print("canary SERVED (%d bytes back)" % len(d))
