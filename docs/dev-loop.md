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
`$DEVVM_DIR/ports`, so the other scripts need no arguments.

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

**It starts `sshd`, as `/bin/sshd &` rather than `svc start sshd`.** Nothing
in `etc/rc.boot.*` starts it on the Linux lane, deliberately
(`scripts/hamlinux_packages.py`, `SVC_SSHD_CMDS`). The dev image is the opt-in
exception, and its forward is bound to `127.0.0.1` only. It bypasses the
service supervisor because `/etc/svc/sshd.hamsh` sets `uid: 2` and port 22 is
privileged — see the SSH section below. The cost of skipping the supervisor is
that nothing restarts sshd, and `user/sshd.ad`'s `main()` serves a bounded
number of connections before exiting, so a long-lived dev VM will eventually
stop accepting SSH; restart it from the console when it does.

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

**There is no `chmod` on the image.** `mv` preserves the mode `wget` wrote, so
pushes work, but a script that chains `&& chmod` will silently stop there.

## The state of SSH — read this before relying on it

`user/sshd.ad` and `user/ssh.ad` ship in `/bin` on every image. **An SSH
session into a running hamnix-linux VM does not work today.** Measured against
a booted guest, in this order:

1. `svc start sshd` **fails to listen**. `/etc/svc/sshd.hamsh` sets `uid: 2`,
   port 22 is privileged, and `net_announce()` returns failure. The supervisor
   then restarts it on a backoff, so the console fills with the same four
   lines forever. Run as uid 0 it announces fine — `[sshd] listening on
   port 22`. The same `uid: 2` also means it cannot write
   `/var/lib/ssh/ssh_host_ecdsa_key` and logs `could not persist host key`;
   at uid 0 it logs `generated + persisted a new host key` instead.
   This is why the dev rc runs `/bin/sshd &` directly. **The shipped service
   definition is left alone**: dropping sshd to uid 2 was a deliberate
   decision (`docs/security.md` Phase 11), so making it able to bind 22 is a
   product decision — grant a capability, use a high port, or privilege-drop
   after the bind — and not one this dev loop should quietly make.
2. `/var/lib/ssh` **is not created by anything**. There is no `mkdir` in
   `user/sshd.ad`, and `scripts/hamlinux_image.sh` stages `/var/lib/hpm` but
   not `/var/lib/ssh`. The dev rc creates it.
3. With those two out of the way the protocol works, and works well. The real
   OpenSSH client completes key exchange, the banner is `SSH-2.0-Hamnix_1.0`,
   and **password authentication succeeds** (`root` / `hamnix`, hard-coded in
   `_check_credential` — note `root` is not in `/etc/passwd`, which has no
   uid 0 line at all). The guest logs `session channel opened`,
   `pty-req accepted`, `hamsh spawned for SSH session`,
   `bridging SSH channel <-> hamsh`.
4. **Then nothing.** Not one byte ever reaches the client, over a real host
   PTY, for 60 s. Not on the serial console either. The session is mute and
   the client eventually times out.

`/etc/rc.ssh` — the script sshd hands to hamsh — **is also not staged onto the
image** (`scripts/hamlinux_image.sh` never mentions it). That is a genuine
second defect, but it is *not* the cause of the mute session: pushing
`rc.ssh` into the running guest and reconnecting changes nothing, and
`/bin/hamsh /etc/rc.ssh` run directly on the console works perfectly —
it prints its banner, `rc.ssh: SSH session namespace ready`, and a prompt.

So the failure is squarely in **sshd's channel bridge**: it reports bridging
and then moves no data in either direction. Until that is fixed, the console
path above is the way in, and it is the one these scripts use.
