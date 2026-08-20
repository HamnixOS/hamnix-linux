# The development loop: iterating against a running VM

Every gate in `tests/linux/` boots its own VM, drives it once, powers it off,
and reads the result out of the disk image afterwards. That is the right shape
for deciding whether to ship. It is the wrong shape for changing one line of
one program, and because the gates share `build/image` they cannot even run in
parallel — so a battery is hours and a one-line edit costs a full
build → boot → power-off cycle.

This is the other loop. It boots **one** VM, leaves it up, and pushes freshly
built binaries into it over HTTP.

## The measured numbers

Measured on this dev box, x86_64, KVM enabled, against the tree at the commit
that added this file. Times are wall-clock, from a script that timestamps
either side of the work — not estimates.

| | seconds |
|---|---|
| Full image build, warm object cache (`scripts/devvm_image.sh`) | **209** |
| Cold boot of that image to a usable prompt (`scripts/devvm_up.sh`) | **2** |
| **Cold path total** — rebuild + reboot for one changed line | **211** |
| **Push path** — one changed line built and *running* in the guest already up, verified | **1** |

The push figure is the whole loop: compile the one `.ad`, serve it, make the
guest fetch it, replace the binary, and run it to confirm the new behaviour.
It was measured twice — **4 s** on the first push of a program (the object
cache had nothing for it) and **1 s** on the next one. Both are the real
number for their case; the cache state is the difference, so expect a few
seconds on the first touch of a given program and about a second thereafter.

The 209 s build figure is itself a *warm* one. A fresh checkout pays the
`adder_cc_bootstrap` seed compile on top.

Re-measured on 2026-08-20, on the same box against a different commit and a
private image directory: **213 s**. Written down as 213 and not rounded to the
209 above, because they are two measurements of two trees and the honest thing
to record is both.

Two things this table is not. It is not a comparison against the full release
path — the gate loop the brief describes (build → medium → install → boot →
power-off → `debugfs`) is longer than 211 s, and none of it was re-measured
here. And 211 s is the honest cold number *for this text-only dev image*; a
gate that also builds a distro medium and installs a machine costs more.

## Using it

```sh
# once: stage the dev image (209 s)
scripts/devvm_image.sh ~/.hamnix-build/devvm/image

# once: boot it and leave it up (2 s)
HAMLINUX_IMAGE_DIR=~/.hamnix-build/devvm/image \
DEVVM_DIR=~/.hamnix-build/devvm/run \
  scripts/devvm_up.sh

# then, per edit (~1 s)
DEVVM_DIR=~/.hamnix-build/devvm/run scripts/devvm_push.sh user/uname.ad

# run anything in the guest
python3 scripts/devvm_console.py run ~/.hamnix-build/devvm/run 'uname; id'

# when finished
DEVVM_DIR=~/.hamnix-build/devvm/run scripts/devvm_down.sh
```

`scripts/devvm_up.sh` prints the SSH and HTTP port numbers and writes them to
`$DEVVM_DIR/ports`, so the other scripts need no arguments — and the SSH port
is now good for an actual shell, not just a forward that nothing answers. See
the SSH section at the end.

## Why the dev image differs from the shipped one

`scripts/devvm_image.sh` derives its boot rc from `etc/rc.boot.linux` by
substitution — never a second copy, so it cannot drift — and changes two
things.

**It does not enter the graphical runlevel.** This is not a preference. PID 1
on this system *is a shell*, and `etc/rc.boot.linux` ends by sourcing
`/etc/rc.d/rc.5`; while the greeter runs, PID 1 is still inside that source
and never falls through to the interactive serial prompt the file promises.
Measured on a stock image: the guest **echoes** a line typed at `ttyS0` and
never executes it. `etc/rc.boot.linux`'s own comment above that line says
"Comment this line out for a text-only boot"; that is exactly what the dev
image does.

**It starts `sshd`, with `svc start sshd`.** Nothing in `etc/rc.boot.*` starts
it on the Linux lane, deliberately (`scripts/hamlinux_packages.py`,
`SVC_SSHD_CMDS`). The dev image is the opt-in exception, and its forward is
bound to `127.0.0.1` only. It used to spell this `/bin/sshd &` to go *around*
the supervisor, because `/etc/svc/sshd.hamsh` set `uid: 2` and port 22 is
privileged; sshd now binds while privileged and drops to uid 2 itself, so the
shipped path works and the dev image uses it. That also gives the dev VM
restart-on-failure, which it did not have: `user/sshd.ad`'s `main()` serves a
bounded number of connections and exits, and nothing was bringing it back, so
a long-lived dev VM used to stop accepting SSH.

## How bytes get from the host into the guest

**HTTP from the SLIRP gateway at `10.0.2.2`.** The guest ships `wget`; the
host side is a `python3 -m http.server` on loopback serving `$DEVVM_DIR/push`.
Proven byte-exact: a 3565-byte file pushed into a running guest came back with
`cksum 533660337` on both sides.

**It is not 9P, and it cannot be.** The Plan-9-shaped answer would be a
virtio-9p host share. There is no 9P client on a hamnix-linux guest:
`scripts/hamlinux_image.sh` contains no 9p of any kind, and the driver the
transport would need (`drivers/virtio/virtio_9p.ad`) **does not exist in this
repository** — there is no `drivers/` directory at all, and `git ls-files`
lists none. `scripts/test_virtio9p.sh` is still in the tree but compiles
`init/main.ad`, which is also absent; it and `scripts/test_sshd.sh` and
`scripts/test_sshd_pubkey.sh` are leftovers of the removed bare-metal lane and
cannot run here. Only `lib/9p/9p.ad`, the wire codec, survives.

## What the loop cannot cover

**A push replaces a file in a RAM-backed root. It does not survive a reboot** —
the initramfs is rebuilt from the tree every boot, so anything pushed is gone
on the next cold cycle. That is a feature (no state accumulates) and a trap
(a fix that works in the guest is not yet a fix in the tree).

**These changes still need a cold rebuild and reboot**, because they only run
at boot or are not files in `/bin`:

- `etc/rc.boot*` and everything they source, including `etc/rc.d/rc.5`
- `linuxinit` — PID 1 itself
- the installer, the greeter's place in the runlevel, kernel A/B slots
- anything in the kernel or the initramfs layout

**The dev VM is text-only**, so it cannot test the desktop, the compositor, or
the greeter at all. Use the normal gates for those. `scripts/hamlinux_vm.sh
dev` does expose QMP at `$DEVVM_DIR/qmp.sock`, so
`tests/linux/qmp_input.py` can drive a real keyboard and tablet and take
screendumps against an already-running guest — but that only helps for an
image whose rc *does* enter the graphical runlevel.

**`devvm_console.py run` proves execution, never success.** A serial console
has no exit status on the wire. `run` brackets the command between two marker
echoes and requires each marker to appear **twice** — once as the terminal's
echo, once as real output — because a console echoes what is typed at it
whether or not any shell is reading. Waiting for the marker only *once*
succeeds against a guest that is not listening at all, which is exactly what
the first version of this tool did. Even so, a command that runs and fails
still returns 0 here; assert on the command's own output, as
`scripts/devvm_push.sh` does with `PUSH_OK`.

**A pushed file's mode used to be wrong, and this file used to say it did not
matter.** The claim here was "`mv` preserves the mode `wget` wrote, so pushes
work". `wget` writes through `sys_open_write` — `open(..., 0666)` — so a
fetched file lands **0644, with no execute bit**. What rescued earlier pushes
was `mv` truncating an *existing* destination and leaving that destination's
own 0755 alone; push over a **running** binary and `sys_open_write`'s
`ETXTBSY` fallback unlinks and re-creates it at 0644, and the guest answers
`execve(2) EACCES` after `devvm_push.sh` has already printed "done". There is
a `/bin/chmod` now (`user/chmod.ad`), `devvm_push.sh` uses it, and it
**asserts** the destination came out executable.

## SSH into the running VM

**This works.** `ssh -p <port> <user>@127.0.0.1`, password `hamnix`, gets an
interactive `hamsh` prompt in the running guest, and a command typed into it
runs there and sends its output back. The port is the one `devvm_up.sh`
printed and wrote to `$DEVVM_DIR/ports` as `DEVVM_SSH_PORT`.

```sh
. ~/.hamnix-build/devvm/run/ports
ssh -p "$DEVVM_SSH_PORT" root@127.0.0.1        # password: hamnix
```

### What it costs

Measured on this dev box against an already-running guest, wall-clock from
`ssh` being invoked to the first prompt: **2.5 s**, of which most is the key
exchange; the client is at a prompt and the session then stays up. That is
per *session*, and it replaces nothing in the table above — it is the thing
the push loop could not do at all, which is get a shell.

For comparison, from that same table: **1 s** to push one rebuilt program
into the guest, **213 s** to rebuild the image and **2 s** to boot it. SSH is
how you look at the result; the push is how you change it.

`root` is hard-coded in `user/sshd.ad`'s `_check_credential` with the
password `hamnix`, and is **not in `/etc/passwd`**, which has no uid 0 line
at all.

### What a session can and cannot do

sshd binds port 22 while privileged and then **drops to uid 2** before it
accepts anything (`docs/security.md` Phase 11 — see the long note in
`/etc/svc/sshd.hamsh`). That is not a claim in a comment; `id` in a live
session answers

```
uid=2(sshd) gid=2(sshd) groups=2(sshd)
```

Ordinary commands, pipelines and the shell are unaffected — measured.

**A namespace may not be.** A uid-2 process has no `CAP_SYS_ADMIN`, and on a
guest where `/etc/rc.ssh` had not been staged an SSH session's pipeline
printed `rfork: no private namespace yet (needs CAP_SYS_ADMIN)` twice. With
`/etc/rc.ssh` staged that message did not appear and the session reported
`rc.ssh: SSH session namespace ready (enter linux { ... } available)` — but
**that line is `rc.ssh` announcing itself, not a test of `enter linux`**, and
`enter linux` was *not* exercised here: the dev image has no Debian namespace
installed to enter. So: treat namespace work over SSH as unproven, use the
serial console for it, and if you need the answer, measure it — do not read
it off that banner.

### Gate it

`tests/linux/ssh_session_gate.py <ssh-port>` asserts both directions and
exits non-zero unless both hold:

- **positive** — a fresh lower-case nonce is typed into the session and its
  UPPER-case form is asserted on, with `tr` in the guest doing the work. The
  assertion is on something the guest *computed*, never on something that was
  typed, because **a pty echoes what you type** and an assertion on typed text
  passes against a guest that is not listening. That is not hypothetical: the
  first version of this gate typed `echo A B` and asserted on `AB`, and
  reported FAIL against a session that demonstrably worked.
- **negative** — a wrong password must draw an explicit `Permission denied`.
  "No shell appeared" was equally true of the bug below, so the control has to
  distinguish a refusal from a silence, not merely observe the absence of a
  prompt.

Run against the pre-fix `sshd` on the same guest, the same gate reports
`POSITIVE: FAIL` with **115 bytes** received in 25 s and no prompt, while the
negative still passes. So it can go red, and it goes red for the right reason.

### What was actually wrong, since the last version of this file blamed the
### wrong component

This file used to say the session was mute past authentication and that "the
failure is squarely in **sshd's channel bridge**". The bridge was fine. Three
defects, none of them in it, all measured in a guest on 2026-08-20:

1. **A child was closing its parent's socket.** sshd rforks hamsh through
   `lib/p9.ad:spawn_stdio_pipes`, whose child ends with `p9_closefrom(3)` —
   the clean-fd sweep, whose whole job is not leaking the launcher's
   descriptors past the exec. `sys_close` ran the *device* teardown on those
   inherited fds, and `hamnet_close` → `conn_free` writes into a **shared**
   segment, so the child marked the **parent's** connection free. The TCP
   connection stayed up; sshd's every subsequent read of its own live socket
   answered `-ENOTCONN`, which its bridge read as "client disconnected". The
   same sweep closed the parent's ends of hamsh's stdio pipes, which is why
   hamsh exited without printing even its banner. A device is now torn down
   only by the process that opened it.
2. **The bridge's idle bound was commented "~10 min" and measured under one
   second.** Its idle throttle was four `sys_yield()` calls, on the premise
   that there is no timer preemption — but on the Linux lane `sys_yield` is
   `sched_yield(2)`, which returns immediately. With (1) fixed, the client got
   a prompt and sshd closed the connection in under a second. The throttle is
   now a real park (`sys_waitfds(nfds=0, 10 ms)`) and the bound is derived
   from it.
3. **A socket at end-of-input answered "nothing ready yet."**
   `sys_read_nb`'s `/net` branch returned `read(2)`'s 0 verbatim, collapsing
   EOF and would-block for every socket. The bridge could not see a client
   leave — it only ever "noticed" one via the `ENOTCONN` that (1) was
   producing.

`/var/lib/ssh` and `/etc/rc.ssh` were also staged by nothing; both are staged
now, and sshd `mkdir`s `/var/lib/ssh` itself as well.
