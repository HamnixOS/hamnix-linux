#!/usr/bin/env python3
"""serial_drive.py -- type at a booted machine's serial console and record
everything it says back.

    serial_drive.py <unix-socket> <script> <logfile> [transcript]

WHY THIS EXISTS. Every gate in tests/linux/ that boots an installed machine
attaches the serial port as `-serial file:...`, which is WRITE-ONLY: the gate
can read what the machine says and cannot say anything back. That is enough
for a probe the machine's own rc runs on its own, and it is not enough for a
LOGIN PROMPT, whose entire behaviour is a reply to something typed. So the
port is attached as `-serial unix:<sock>,server,nowait` instead and this
program is the other end of it.

WHAT IT DOES NOT DO, and this is deliberate: IT DOES NOT SCORE ANYTHING. It
drives, and it writes every byte the machine sent into <logfile> exactly as
received. The gate makes its assertions afterwards by reading that file. If
an EXPECT pattern here is wrong, the gate still reads the raw log and still
reaches the right verdict -- the instrument cannot flatter the result by
matching something the gate then trusts on its say-so.

THE SCRIPT is one directive per line; blank lines and `#` comments ignored:

    EXPECT <seconds> <python-regex>   wait for the regex in the bytes received
                                      SO FAR; fail the run if it never comes
    SEND <text>                       write <text> then "\\n". Backslash
                                      escapes \\n \\r \\t \\\\ are honoured;
                                      `SEND` with nothing sends a bare newline
    SENDRAW <text>                    as SEND but WITHOUT the trailing newline
    SLEEP <seconds>                   wait, reading and logging throughout
    DONE                              stop driving, keep reading until the
                                      socket closes or the deadline passes

EXIT STATUS: 0 if every directive completed, 1 if an EXPECT timed out (the
pattern and the last 400 bytes seen are printed to stderr), 2 for a usage or
connection error. A timed-out EXPECT still leaves the log complete up to that
point, which is usually the evidence that explains it.

A NOTE ON MATCHING. The machine's console is CRLF and echoes nothing during a
password read (user/login.ad reads raw bytes and deliberately does not echo),
so patterns should not assume they will see what was typed. Matching is done
against the whole accumulated buffer, decoded as latin-1 so no byte sequence
can raise, with re.S so `.` crosses lines.
"""
import os
import re
import socket
import sys
import time


def parse_escapes(s):
    out = []
    i = 0
    while i < len(s):
        c = s[i]
        if c == "\\" and i + 1 < len(s):
            n = s[i + 1]
            if n == "n":
                out.append("\n"); i += 2; continue
            if n == "r":
                out.append("\r"); i += 2; continue
            if n == "t":
                out.append("\t"); i += 2; continue
            if n == "\\":
                out.append("\\"); i += 2; continue
        out.append(c)
        i += 1
    return "".join(out)


def main(argv):
    if len(argv) < 4:
        print(__doc__, file=sys.stderr)
        return 2
    sockpath, scriptpath, logpath = argv[1], argv[2], argv[3]
    trpath = argv[4] if len(argv) > 4 else None

    steps = []
    with open(scriptpath) as f:
        for raw in f:
            line = raw.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            parts = line.split(None, 1)
            verb = parts[0].upper()
            rest = parts[1] if len(parts) > 1 else ""
            steps.append((verb, rest))

    # Connect. QEMU with `server,nowait` is already listening by the time it
    # has started executing, but the gate may race it, so retry briefly.
    s = None
    deadline = time.time() + 60
    while time.time() < deadline:
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.connect(sockpath)
            break
        except OSError:
            if s:
                s.close()
            s = None
            time.sleep(0.5)
    if s is None:
        print("serial_drive: could not connect to %s" % sockpath, file=sys.stderr)
        return 2
    s.setblocking(False)

    log = open(logpath, "ab", buffering=0)
    tr = open(trpath, "a", buffering=1) if trpath else None
    buf = bytearray()

    def note(msg):
        if tr:
            tr.write("[%8.2f] %s\n" % (time.time() - t0, msg))

    def pump(seconds):
        """Read for `seconds`, logging everything. Returns when time is up."""
        end = time.time() + seconds
        while time.time() < end:
            try:
                data = s.recv(65536)
            except BlockingIOError:
                time.sleep(0.05)
                continue
            except OSError:
                return False
            if not data:
                return False
            log.write(data)
            buf.extend(data)
            time.sleep(0.01)
        return True

    t0 = time.time()
    rc = 0
    for verb, rest in steps:
        if verb == "EXPECT":
            p = rest.split(None, 1)
            if len(p) != 2:
                print("serial_drive: bad EXPECT: %s" % rest, file=sys.stderr)
                rc = 2
                break
            timeout = float(p[0])
            pat = re.compile(p[1], re.S)
            note("EXPECT %ss /%s/" % (timeout, p[1]))
            end = time.time() + timeout
            hit = False
            while time.time() < end:
                if pat.search(buf.decode("latin-1")):
                    hit = True
                    break
                if not pump(0.25):
                    # Socket closed. One last look before giving up.
                    if pat.search(buf.decode("latin-1")):
                        hit = True
                    break
            if hit:
                note("  matched after %.1fs" % (time.time() - (end - timeout)))
            else:
                tail = buf[-400:].decode("latin-1")
                print("serial_drive: EXPECT TIMED OUT after %ss: /%s/"
                      % (timeout, p[1]), file=sys.stderr)
                print("serial_drive: last 400 bytes seen:\n%s" % tail,
                      file=sys.stderr)
                note("  TIMED OUT")
                rc = 1
                break
        elif verb in ("SEND", "SENDRAW"):
            text = parse_escapes(rest)
            if verb == "SEND":
                text += "\n"
            note("%s %r" % (verb, text))
            try:
                s.sendall(text.encode("latin-1"))
            except OSError as e:
                print("serial_drive: send failed: %s" % e, file=sys.stderr)
                rc = 1
                break
            # Give the guest a moment to consume it; a shell that is not
            # reading yet will otherwise lose the line.
            pump(0.4)
        elif verb == "SLEEP":
            note("SLEEP %s" % rest)
            pump(float(rest))
        elif verb == "DONE":
            note("DONE")
            pump(float(rest) if rest.strip() else 5.0)
            break
        else:
            print("serial_drive: unknown directive %r" % verb, file=sys.stderr)
            rc = 2
            break

    try:
        s.close()
    except OSError:
        pass
    log.close()
    if tr:
        tr.close()
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv))
