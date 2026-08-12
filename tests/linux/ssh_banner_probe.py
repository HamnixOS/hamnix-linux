"""Can a peer make its own tail look like an identification string?

RFC 4253 bounds the identification line to 255 bytes including CR LF, but the
banner lines a peer may send BEFORE it are not bounded at all. user/sshd.ad
read those lines with `while ll < 255`, which stopped counting and left the
REST OF THE LINE in the socket. So a line of exactly 255 bytes followed
IMMEDIATELY by "SSH-..." is read as two lines: 255 bytes of padding (rejected,
it does not start with SSH-) and then the injected tail, ACCEPTED as the peer's
identification string. The exchange hash is then computed over a string the
peer smuggled past the line framing, and the binary packet protocol starts at
the wrong place.

THE PADDING LENGTH IS THE WHOLE TEST. An earlier version of this probe used 300
bytes of padding and PASSED against the broken server -- the continuation began
with padding rather than with "SSH-", so the old code rejected it too and
happened to recover on the next line. It proved nothing. 255 exactly is what
puts the injected prefix at the start of the continuation.

The verdict is taken from OUTSIDE: after KEXINIT, a server that accepted the
injected line will read this probe's REAL identification line as a binary
packet, find a length of 0x5353482d, and tear the connection down.
"""
import socket
import sys
import time

PORT = 22
mode = sys.argv[1] if len(sys.argv) > 1 else 'inject'   # 'plain' skips the banner
PAD = 255

s = socket.create_connection(('127.0.0.1', PORT), timeout=8)
s.settimeout(8)

banner = b''
while b'\n' not in banner and len(banner) < 512:
    b = s.recv(256)
    if not b:
        break
    banner += b
print('server ident: %r' % banner.split(b'\n')[0][:50])

if mode == 'inject':
    line = b'X' * PAD + b'SSH-2.0-injected_by_the_tail\r\n'
    print('sending %d bytes of padding with "SSH-" starting at byte %d'
          % (PAD, PAD + 1))
    s.sendall(line)

s.sendall(b'SSH-2.0-hamnixprobe_0.1\r\n')

try:
    d = s.recv(4096)
except socket.timeout:
    print('RESULT: no binary packet -- the server never reached KEXINIT')
    sys.exit(1)
if not d:
    print('RESULT: the server closed without sending anything')
    sys.exit(1)
ln = int.from_bytes(d[0:4], 'big')
mt = d[5] if len(d) > 5 else -1
print('first binary packet: %d declared, %d received, msg type %d' % (ln, len(d), mt))

# THE DECIDING OBSERVATION. A server that took the injected line as our id has
# our REAL id line sitting in its packet parser as a length of 0x5353482d and
# will drop the connection; one that framed the lines correctly is still there.
s.settimeout(3)
alive = True
try:
    more = s.recv(4096)
    if more == b'':
        alive = False
except socket.timeout:
    alive = True
except ConnectionResetError:
    alive = False

if mt == 20 and alive:
    print('RESULT: KEXINIT and the connection is STILL OPEN -- the over-long '
          'line was framed correctly and skipped whole')
    sys.exit(0)
if not alive:
    print('RESULT: the server DROPPED the connection -- it mis-framed the '
          'over-long line and read our identification as a binary packet')
    sys.exit(1)
print('RESULT: no well-formed KEXINIT')
sys.exit(1)
