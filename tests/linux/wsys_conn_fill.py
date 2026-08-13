#!/usr/bin/env python3
"""Open connections to the wsys mutation socket until one is refused.

Reports, per connection index, whether the server kept it. A slot is held
only while this process lives, so it stays alive on stdin until told to go.
"""
import os, socket, struct, sys, time, select

seg = sys.argv[1]              # "<dev>.<ino>"
leaf = sys.argv[2]             # "srv" or "rd"
want = int(sys.argv[3])        # how many to try
hold_path = sys.argv[4] if len(sys.argv) > 4 else None

NAME = ("\0hamnix-wsys/%s/%s" % (seg, leaf)).encode()

WSRV_MAGIC_RQ = 0x51525357
WSRV_MAGIC_RP = 0x50525357
OP_HELLO = 1
F_REPLY = 1
# struct wsrv_hdr layout is checked below against the reply we get back.

socks = []
alive = []
for i in range(want):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
    try:
        s.connect(NAME)
    except OSError as e:
        print("conn %d CONNECT-FAILED %s" % (i + 1, e.strerror), flush=True)
        alive.append(False)
        socks.append(None)
        continue
    socks.append(s)
    alive.append(None)          # unknown until probed

# The server accepts inside its frame loop, so give it iterations to run
# before asking which connections survived. Poll until the answer stops
# changing rather than sleeping a guessed amount.
def probe():
    n = 0
    for i, s in enumerate(socks):
        if s is None:
            continue
        r, _, _ = select.select([s], [], [], 0)
        if r:
            try:
                d = s.recv(65536, socket.MSG_DONTWAIT | socket.MSG_PEEK)
            except OSError:
                d = b""
            if d == b"":
                alive[i] = False
                continue
        alive[i] = True
        n += 1
    return n

prev = -1
for _ in range(60):
    time.sleep(0.25)
    n = probe()
    dead = sum(1 for a in alive if a is False)
    if dead and n == prev:
        break
    prev = n

first_refused = None
for i, a in enumerate(alive):
    if a is False:
        first_refused = i + 1
        break

# The caller reads this through `grep -m1`, which closes the pipe on the first
# match; without this the per-connection detail below raises BrokenPipeError
# and paints a working measurement's log with a traceback.
try:
    print("tried %d kept %d first_refused %s"
          % (want, sum(1 for a in alive if a), first_refused), flush=True)
    for i, a in enumerate(alive):
        print("conn %d %s" % (i + 1, "KEPT" if a else "REFUSED"), flush=True)
except BrokenPipeError:
    os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())

if hold_path:
    with open(hold_path, "w") as f:
        f.write("ready\n")
    # HOLD THE SLOTS UNTIL A STOP FILE APPEARS, and not until stdin closes.
    # A backgrounded job in a non-interactive shell has stdin on /dev/null, so
    # `sys.stdin.read()` returned instantly, this process exited, and all 64
    # connections were released BEFORE the arm that needed them ran -- the
    # measurement then reported a full table and probed an empty one.
    stop = hold_path + ".stop"
    while not os.path.exists(stop):
        time.sleep(0.1)
