#!/usr/bin/env python3
"""devvm_console.py -- attach to a persistent dev VM's serial console.

WHY THIS EXISTS. `scripts/hamlinux_vm.sh dev` puts the guest console on a
UNIX socket instead of stdio, which is what lets the guest outlive the
process that started it. The cost is that a unix-socket chardev accepts
ONE client at a time, so something has to own the connection, keep a
transcript, and still let a later command inject a keystroke.

This is that something. It runs in three shapes:

  log     <rundir>                 own the socket forever, append every byte
                                   to <rundir>/console.log, and execute lines
                                   written to the FIFO <rundir>/console.in.
                                   This is what devvm_up.sh leaves running.
  send    <rundir> <text>          queue a line for the logger to type.
  expect  <rundir> <pattern> [secs]
                                   wait for a regex to appear in console.log.
                                   Exits 0 on match, 1 on timeout.
  run     <rundir> <cmd> [secs]    send + wait for the shell to come back,
                                   printing whatever the command produced.

WHAT `run` CANNOT DO, and it matters. This is a SERIAL CONSOLE, not a
protocol: there is no exit status on the wire and no framing. `run` finds
the command's output by bracketing it between two marker echoes and
returning what lands in between. If the guest shell is not at a prompt --
mid-boot, sitting in a pager, inside `enter linux` -- the markers are what
you get back and the output is empty. An EMPTY RESULT HERE IS NOT A PASS
and callers must not treat it as one; `run` prints the markers it saw so a
caller can tell "the command produced nothing" from "the shell never ran
it". Anything that needs a real exit status should go over SSH, or write a
sentinel file the host can fetch.
"""
import os
import re
import socket
import sys
import time

MARK_B = "__DEVVM_B_%d__"
MARK_E = "__DEVVM_E_%d__"


def paths(rundir):
    return (os.path.join(rundir, "console.sock"),
            os.path.join(rundir, "console.log"),
            os.path.join(rundir, "console.in"))


def do_log(rundir):
    sock_p, log_p, fifo_p = paths(rundir)
    if not os.path.exists(fifo_p):
        os.mkfifo(fifo_p)
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    # QEMU creates the socket before the guest runs, but devvm_up.sh may race
    # it by milliseconds. Retry rather than making the caller sleep a fixed
    # amount and hope.
    for _ in range(100):
        try:
            s.connect(sock_p)
            break
        except OSError:
            time.sleep(0.1)
    else:
        sys.exit("devvm_console: could not connect to %s" % sock_p)
    s.setblocking(False)
    log = open(log_p, "ab", buffering=0)
    # O_RDWR on the FIFO, not O_RDONLY: a read-only open blocks until a writer
    # appears, and every time the last writer leaves the reader would see EOF
    # and spin. Holding a writer end ourselves keeps it open forever.
    fifo = os.open(fifo_p, os.O_RDWR | os.O_NONBLOCK)
    import select
    while True:
        r, _, _ = select.select([s, fifo], [], [], 1.0)
        if s in r:
            try:
                data = s.recv(65536)
            except OSError:
                data = b""
            if not data:
                log.write(b"\n[devvm_console] guest console closed\n")
                return
            log.write(data)
        if fifo in r:
            try:
                cmd = os.read(fifo, 65536)
            except OSError:
                cmd = b""
            if cmd:
                s.sendall(cmd)


def do_send(rundir, text):
    _, _, fifo_p = paths(rundir)
    with open(fifo_p, "wb") as f:
        f.write(text.encode())


def _logsize(log_p):
    try:
        return os.path.getsize(log_p)
    except OSError:
        return 0


def do_expect(rundir, pattern, secs, since=0):
    _, log_p, _ = paths(rundir)
    rx = re.compile(pattern)
    deadline = time.time() + secs
    while time.time() < deadline:
        try:
            with open(log_p, "rb") as f:
                f.seek(since)
                if rx.search(f.read().decode("utf-8", "replace")):
                    return True
        except OSError:
            pass
        time.sleep(0.2)
    return False


def do_run(rundir, cmd, secs):
    _, log_p, _ = paths(rundir)
    n = int(time.time() * 1000) % 1000000
    b, e = MARK_B % n, MARK_E % n
    start = _logsize(log_p)
    do_send(rundir, "\necho %s; %s; echo %s\n" % (b, cmd, e))
    # THE MARKER MUST APPEAR TWICE, AND THAT IS THE WHOLE ASSERTION.
    #
    # A serial console ECHOES what is typed at it. So the moment the line is
    # sent, both markers are already in the transcript -- inside the echo of
    # the command itself -- whether or not any shell ever read it. Waiting for
    # "the end marker appeared" therefore SUCCEEDS AGAINST A GUEST THAT IS NOT
    # LISTENING AT ALL. This is not hypothetical: it is what this function did
    # on its first run against a guest whose PID 1 had stopped reading ttyS0
    # once the graphical runlevel started, and it reported success with the
    # echoed line as the "output".
    #
    # Executing the line produces a SECOND occurrence of each marker, on its
    # own. So: occurrence #1 is the echo, occurrence #2 is proof of execution.
    # Fewer than two means the guest did not run it, and that is a failure no
    # matter how much text arrived.
    def _text():
        with open(log_p, "rb") as f:
            f.seek(start)
            return f.read().decode("utf-8", "replace")

    deadline = time.time() + secs
    text = ""
    while time.time() < deadline:
        text = _text()
        if text.count(e) >= 2 and text.count(b) >= 2:
            break
        time.sleep(0.2)
    else:
        text = _text()
        print("[devvm_console] NO EXECUTION: the end marker appeared %d time(s); "
              "2 are needed (one echo, one result). The guest shell did not run "
              "this command. Transcript since the send:" % text.count(e),
              file=sys.stderr)
        sys.stderr.write(text)
        return 1
    after = text.rindex(b) + len(b)
    upto = text.rindex(e)
    if upto < after:
        sys.stderr.write(text)
        return 1
    sys.stdout.write(text[after:upto].lstrip("\r\n"))
    return 0


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    verb, rundir = sys.argv[1], sys.argv[2]
    if verb == "log":
        do_log(rundir)
    elif verb == "send":
        do_send(rundir, sys.argv[3])
    elif verb == "expect":
        secs = float(sys.argv[4]) if len(sys.argv) > 4 else 60
        sys.exit(0 if do_expect(rundir, sys.argv[3], secs) else 1)
    elif verb == "run":
        secs = float(sys.argv[4]) if len(sys.argv) > 4 else 30
        sys.exit(do_run(rundir, sys.argv[3], secs))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
