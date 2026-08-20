#!/usr/bin/env python3
"""tests/linux/ssh_session_gate.py -- does SSH into a running hamnix machine
actually give you a shell?

WHAT IT ASSERTS, and why each assertion can go red.

  POSITIVE  With the right password, the real OpenSSH client must reach a
            hamsh prompt, and a command typed into that session must run IN
            THE GUEST and send its output back. The proof is a NONCE minted
            by this script and echoed by the guest -- not a fixed string, so
            a cached transcript or a replayed log cannot satisfy it, and not
            merely "the client connected", which was true for months while
            the session was mute.

            It is asserted on something the guest COMPUTED, never on the
            echo. A pty echoes what you type, so any string you type appears
            on the wire the instant it is typed whether or not anything is
            reading -- the exact trap docs/dev-loop.md records
            `devvm_console.py run` falling into, and the trap the first
            version of this gate fell into too: it typed `echo A B` and
            asserted on "AB", which a real session does not produce either,
            so the gate went red against a session that worked.

            So: the nonce is typed in LOWER case and piped through `tr a-z
            A-Z`, and the assertion is on the UPPER-case form. That string
            exists nowhere in the typed line, appears only if a shell in the
            guest ran a pipeline, and is fresh per run, so a cached
            transcript or replayed log cannot satisfy it.

  NEGATIVE  With a wrong password, the server must REFUSE -- and the refusal
            must be distinguishable from the silence this gate exists to
            catch. "No shell appeared" is true of a rejected login and was
            also true of the bug; so the negative control asserts the client
            saw an explicit authentication failure, not just an absent
            prompt.

Usage:
    ssh_session_gate.py <ssh-port> [password]

Exit 0 only if BOTH the positive and the negative assertion hold.
"""
import os
import pty
import random
import select
import string
import sys
import time

DEADLINE = float(os.environ.get("SSH_GATE_DEADLINE", "45"))
USER = os.environ.get("SSH_GATE_USER", "root")


def ssh_argv(port, tries):
    return ["ssh", "-tt", "-p", str(port),
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "PreferredAuthentications=password",
            "-o", "PubkeyAuthentication=no",
            "-o", "NumberOfPasswordPrompts=%d" % tries,
            "-o", "ConnectTimeout=10",
            "%s@127.0.0.1" % USER]


def drive(port, password, command=None, tries=1, deadline=DEADLINE):
    """Run one ssh session over a REAL pty and return everything it printed."""
    pid, fd = pty.fork()
    if pid == 0:
        os.execvp("ssh", ssh_argv(port, tries))
        os._exit(1)                                   # unreachable
    buf = b""
    t0 = time.time()
    sent_pw = False
    sent_cmd = command is None
    try:
        while time.time() - t0 < deadline:
            r, _, _ = select.select([fd], [], [], 0.5)
            if r:
                try:
                    d = os.read(fd, 65536)
                except OSError:
                    break
                if not d:
                    break
                buf += d
            if not sent_pw and b"assword" in buf:
                time.sleep(0.3)
                os.write(fd, (password + "\n").encode())
                sent_pw = True
                continue
            # Only type the command once a PROMPT has come back -- which is
            # itself the thing under test.
            if sent_pw and not sent_cmd and b"hamsh$" in buf:
                time.sleep(0.5)
                os.write(fd, (command + "\n").encode())
                sent_cmd = True
            if sent_cmd and command is not None and b"__GATE_DONE__" in buf:
                # Drain the tail of the reply, but NEVER with a bare read on a
                # pty -- that blocks for ever when there is nothing more, and
                # a gate that hangs is a gate that cannot go red.
                tail_until = time.time() + 1.5
                while time.time() < tail_until:
                    rr, _, _ = select.select([fd], [], [], 0.2)
                    if not rr:
                        continue
                    try:
                        more = os.read(fd, 65536)
                    except OSError:
                        break
                    if not more:
                        break
                    buf += more
                break
    finally:
        try:
            os.kill(pid, 9)
            os.waitpid(pid, 0)
        except Exception:
            pass
    return buf.decode("utf8", "replace"), time.time() - t0


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    port = sys.argv[1]
    password = sys.argv[2] if len(sys.argv) > 2 else "hamnix"

    nonce = "".join(random.choice(string.ascii_lowercase) for _ in range(12))
    expect = nonce.upper()

    print("=" * 70)
    print("POSITIVE: correct password must yield a shell that runs a command")
    print("  typing nonce %r; asserting on the guest's UPPER-cased %r"
          % (nonce, expect))
    # The typed line contains only the lower-case form. The upper-case form
    # can only come from `tr` having actually run inside the guest.
    cmd = "echo %s | tr a-z A-Z; echo __GATE_DONE__" % nonce
    out, secs = drive(port, password, command=cmd)
    print("-" * 70)
    print(out)
    print("-" * 70)
    print("  session ran for %.1f s, %d bytes from the guest" % (secs, len(out)))

    saw_prompt = "hamsh$" in out
    saw_computed = expect in out
    print("  prompt reached ............ %s" % saw_prompt)
    print("  guest computed the reply .. %s  (%r seen in the reply)"
          % (saw_computed, expect))
    positive = saw_prompt and saw_computed

    print("=" * 70)
    print("NEGATIVE CONTROL: a wrong password must be REFUSED, and the")
    print("refusal must be visibly different from the mute session.")
    bad = password + "_WRONG"
    out2, secs2 = drive(port, bad, command=None, tries=2, deadline=25)
    print("-" * 70)
    print(out2)
    print("-" * 70)
    refused = ("Permission denied" in out2
               or "Authentication failed" in out2
               or out2.count("assword") >= 2)
    no_shell = "hamsh$" not in out2
    print("  explicit refusal seen ..... %s" % refused)
    print("  no shell handed out ....... %s" % no_shell)
    negative = refused and no_shell

    print("=" * 70)
    print("POSITIVE: %s" % ("PASS" if positive else "FAIL"))
    print("NEGATIVE: %s" % ("PASS" if negative else "FAIL"))
    ok = positive and negative
    print("ssh_session_gate: %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
