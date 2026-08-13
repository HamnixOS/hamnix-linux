#!/usr/bin/env python3
"""WHO IS TALKING TO THIS SEGMENT'S SERVER, taken from the kernel.

This is tests/linux/wsys_srv_deboot.sh's census, lifted into a file so
tests/linux/wsys_srv_ceiling.sh can reuse the mechanism rather than restate
it -- two spellings of "which processes hold a wsys connection" would be two
answers to the question the whole connection ceiling is about.

`ss -x` names only the LISTENING end and the server's accepted ends; the
client end of an AF_UNIX connection HAS NO ADDRESS AT ALL. So the peer socket
INODE is read off the server-side row and resolved through /proc/<pid>/fd,
which is the only place in the system that association exists. Nothing here
asks a process what it thinks it is doing.

Input: a file of "srv|rd <peer-inode>" lines, as produced by the awk over
`ss -xp` in the calling gate. Output: "srv|rd <pid> <comm> fd=<n>".
"""
import os, sys

want = {}
for line in open(sys.argv[1]):
    parts = line.split()
    if len(parts) != 2:
        continue
    kind, ino = parts
    want.setdefault(ino, []).append(kind)

found = []
for pid in os.listdir('/proc'):
    if not pid.isdigit():
        continue
    try:
        fds = os.listdir('/proc/%s/fd' % pid)
    except OSError:
        continue
    for fd in fds:
        try:
            t = os.readlink('/proc/%s/fd/%s' % (pid, fd))
        except OSError:
            continue
        if not t.startswith('socket:['):
            continue
        ino = t[8:-1]
        if ino in want:
            try:
                comm = open('/proc/%s/comm' % pid).read().strip()
            except OSError:
                comm = '?'
            for k in want[ino]:
                found.append((k, int(pid), comm, fd))
            break

for k, pid, comm, fd in sorted(found, key=lambda r: (r[0], r[1])):
    print('%s %d %s fd=%s' % (k, pid, comm, fd))
