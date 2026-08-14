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
            # NO `break`. THE BREAK THAT WAS HERE MADE THIS FILE LIE, and it
            # lied for ten hours after the same break was removed from the
            # gate this file was lifted out of.
            #
            # This module was extracted at 44412d29 (04:40) from
            # tests/linux/wsys_srv_deboot.sh's inline census, WITH the break.
            # 0965da0b (13:46) removed the break from deboot's copy and
            # recorded why: it stopped at the FIRST matching descriptor in a
            # process, so a client holding BOTH a mutation connection and a
            # read connection was counted ONCE, as whichever fd the kernel
            # listed first -- always the mutation one, dialled earlier and
            # given the lower number. deboot therefore reported "0 processes
            # hold a READ connection" for a desktop in which hamdesktop held
            # fd 3 on srv and fd 4 on rd at the same instant.
            #
            # THE EXTRACTED COPY WAS NOT UPDATED, so every number ARM F of
            # tests/linux/wsys_srv_ceiling.sh has ever printed is an
            # UNDERCOUNT of exactly the quantity that gate exists to measure:
            # armF.rd counted only processes that hold a read connection and
            # NO mutation connection. That is the wrong half of the desktop,
            # and it got worse at 7d24ef3c (nine read opens routed) and again
            # at e23ab06c (the WRITE open's existence question routed through
            # the read server), both of which add read connections to
            # processes that ALREADY hold a mutation one -- precisely the
            # population the break erased.
            #
            # The regression test for this line is not "the number is bigger";
            # it is that a process holding two connections appears TWICE, once
            # per kind, with two different fd numbers. See the self-check in
            # tests/linux/wsys_conn_budget.sh, which asserts it against a
            # process it knows holds both.

for k, pid, comm, fd in sorted(found, key=lambda r: (r[0], r[1])):
    print('%s %d %s fd=%s' % (k, pid, comm, fd))
