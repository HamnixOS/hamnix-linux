#!/usr/bin/env python3
# Three servers on three ports, all serving the SAME artifact differently.
#   /good      -- the whole file, correct Content-Length
#   /short     -- declares the FULL Content-Length, then sends only a PREFIX
#                 and CLOSES. This is the dropped connection, and it is the
#                 case the RAM buffer exists to make safe.
#   /big       -- an artifact LARGER than the slot
import socket, threading, sys, os

ART = sys.argv[1]
PORT = int(sys.argv[2])
BIG  = sys.argv[3] if len(sys.argv) > 3 else None
body = open(ART,'rb').read()
bigbody = open(BIG,'rb').read() if BIG else b''

def handle(c):
    try:
        c.settimeout(10)
        req = b''
        while b'\r\n\r\n' not in req:
            d = c.recv(4096)
            if not d: return
            req += d
        line = req.split(b'\r\n',1)[0].decode('latin1')
        path = line.split(' ')[1] if len(line.split(' '))>1 else '/'
        if path.startswith('/good'):
            c.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n' % len(body))
            c.sendall(body)
        elif path.startswith('/short'):
            # DECLARE the full length, deliver 40% of it, then hang up.
            c.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n' % len(body))
            cut = int(len(body)*0.4)
            c.sendall(body[:cut])
            sys.stderr.write("serve: /short sent %d of %d then CLOSED\n" % (cut, len(body)))
            sys.stderr.flush()
        elif path.startswith('/big'):
            c.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n' % len(bigbody))
            c.sendall(bigbody)
        else:
            c.sendall(b'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n')
    except Exception as e:
        sys.stderr.write("serve: %s\n" % e)
    finally:
        try: c.shutdown(socket.SHUT_RDWR)
        except Exception: pass
        c.close()

s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', PORT)); s.listen(16)
sys.stderr.write("serve: listening on %d\n" % PORT); sys.stderr.flush()
while True:
    c,_ = s.accept()
    threading.Thread(target=handle, args=(c,), daemon=True).start()
