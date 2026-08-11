# Updating an INSTALLED hamnix-linux machine

The sentence this is measured against, from the person the system is for:

> "I want the package manager to be truly useful so an installed system can
> just update to get any changes we make, so that I can install this on a box,
> you make edits, they land on 255.one, and I run the update command, no
> re-image needed."

The update loop had been proven once, end to end, on the **live** image
(`a548c6ec`): `hpm refresh` → `hpm install` → a newer build → `hpm update` →
the upgraded binary still runs. Every byte of that went into a tmpfs the next
boot throws away. This is the same loop on a disk that was **installed**, and
then **rebooted** — the boot that keeps.

The gate is `tests/linux/installed_update.sh`: it installs a disk, boots it
through UEFI, refreshes from the real `https://255.one/`, installs a package
the image does not ship, publishes a newer **signed** build to a local
channel, updates against it, reboots the machine, and asks every question
again as the desktop user. Unattended, re-runnable, **43 PASS / 0 FAIL**.

**ONE** arm still reports rather than gates: `https://255.one/` serves no
`index.json.sig`, so the owner's command typed bare does not work on any
machine. It is named in §2a and it is a publish, not a patch. The rc.boot arm
used to be a second one — it is a real check now that §2b is closed, and it
brought four more with it: the digest tool it asks the machine for, and the
file operands `cksum` and `head` grew (§3). The reboot arm was a third and
became real when §2c closed.

Note that the §2b arm **could not have passed in the shape it was written**:
it looked for the rc's byte count in the output of `ls -l /etc/rc.boot`, and
`ls -l FILE` prints the file's *contents* on this line. It named the fault
correctly by accident and would have gone on naming it after the fix. It is an
MD5 of the running rc now, against the digest the host computed for the bytes
it wrote.

**The "newer build" version is derived, not hard-coded.** It was `1.0.8`, and
the gate went red the day the real repository published `hamnix-diff 1.0.8`
itself: the first `hpm install`, whose job is to fetch the *older* release,
already got 1.0.8, so `hpm update` correctly reported `upgraded=0` and the
stamped local build never landed. Five checks failed and all five pointed at
the update path rather than at the collision. The test now asks the repository
what it serves and bumps the patch, so publishing a release cannot break the
gate that exists to prove publishing works.

---

## 1. What works on an installed machine

Measured on a 3 GB disk built by `scripts/hamlinux_disk.sh`, booted twice with
**nothing rebuilt in between**:

| | |
|--|--|
| Boot | UEFI → a unified kernel image on the ESP → the Adder PID 1 → `bind '#sysroot' /` → `/etc/rc.boot` on ext4 |
| Address | `dhcpc` takes a real lease on the installed boot — `10.0.2.15`, gateway and resolver from the offer — over the static address `etc/rc.boot.installed` sets first |
| Names | `host 255.one` answers |
| Repository | `hpm refresh` reaches `https://255.one/linux/` over TLS and reads the 98-package index (51 902 bytes) |
| Install | `hpm install hamnix-diff` → `hamnix-init@1.0.7` + `hamnix-diff@1.0.7`, SHA-256 verified, `/bin/diff` written to the **ext4 root** |
| It runs | `diff` exits 0 on identical files and 1 with a real `1c1 / < hello / > world` on different ones — a freshly installed package is executable |
| Update | a newer build published to a local channel at 1.0.8, **Ed25519-signed**, refreshed with `--trusted-key=`; `hpm update` reports `upgraded=2` |
| The version moved | `hpm list` → `hamnix-diff 1.0.8` |
| The BYTES moved | `cksum </bin/diff` on the guest is `1495419638 144920` — the CRC the host computed over the very bytes it served |
| The EDIT landed | a token minted by the test run, carried in the new tarball as `etc/hamnix-update-stamp`, is readable on the machine |
| **The machine keeps its own rc** | `/etc/rc.boot` is byte-identical after `hpm install` and `hpm update` — checked by MD5 against what the host wrote, not by eye (§2b) |
| **After a reboot** | version, bytes and stamp all still there; the upgraded binary gives both answers again; and all of it holds as **uid 1001** |

The signature path is the one under test, not `--allow-unsigned`: the local
channel is signed with a key minted per run and the machine is handed the
matching public key, so `hpm update` verifies before it trusts a single hash.

---

## 2. What did NOT work, and what each one costs

### 2a. `hpm refresh` refuses `https://255.one/` with no flags — FIXED

**This now works, with no flags at all**, and the sentence this section used
to end with — "the fix is a publish, not a patch" — was half right, which is
the interesting part. `tests/linux/hpm_signed_refresh.sh`, in a VM, against
the live repository:

```
hpm: fetching channel linux from https://255.one/linux/
hpm:   (97 packages)
hpm: refreshed index from https://255.one/ (97 packages across 1 channels)
hpm: resolved 2 package(s): hamnix-init@1.0.8, hamnix-diff@1.0.8
hpm: SHA-256 verified ... installed
```

What this section originally recorded:

```
hpm: fetching channel linux from https://255.one/linux/
hpm: no index.json.sig for this channel (unsigned repo).
     Re-run with --allow-unsigned to trust it anyway.
hpm: refresh: aborting — untrusted index for channel linux
```

The publish happened (channel `linux`, 1.0.8, signed; the trust root was
rotated to a key whose secret exists, `6607d729`) **and the client still
refused**, with the same four lines plus `hpm: HTTP fetch failed` in front of
them. The remaining half was a patch, and the message above is what hid it for
as long as it hid it:

* `fetch_to_buf` hands its destination buffer straight to `http9.http_get`,
  whose `dst_cap` covers the **status line + headers + body**; http9 returns
  `-6` the moment the response reaches `dst_cap`. The signature buffer was
  **512 bytes**. GitHub Pages puts **640 bytes of headers** in front of the
  129-byte signature. 640 + 129 > 512, so the signature fetch failed on
  exactly the server whose 50 KB `index.json` — into a 256 KB buffer — had
  succeeded seconds earlier. Nothing about TLS, a reused connection, or the
  repository was ever involved: the identical failure reproduces over **plain
  HTTP** from a local server that merely pads its headers to 640 bytes.
* And "unsigned repo" was a diagnosis the code had not earned. A fetch that
  fails says nothing about whether a signature exists, and that advice sends
  the operator to `--allow-unsigned`, which disables signature checking
  permanently on a repository that is signed. hpm now distinguishes them: a
  real **404** says the server answered 404 and suggests the flag; anything
  else says it is a fetch failure and explicitly not evidence of an unsigned
  repo, after a line naming the actual transport error ("response (headers +
  body) exceeds the 512-byte receive buffer").

The buffer is now 64 KiB — sized for the RESPONSE, not for the resource, and
large enough to receive the **9,379-byte HTML 404 page** GitHub serves for a
channel that genuinely has no signature, because a response that overruns the
buffer loses the status code too and "404, unsigned" then cannot be told from
"the fetch broke".

Gates: `tests/linux/hpm_index_sig.sh` (7 checks, offline, ~15 s — it serves
the bytes itself with a CDN-sized header block, and the pre-fix binary fails
its first check over plain HTTP) and `tests/linux/hpm_signed_refresh.sh`
(9 checks, in a VM, against the real repository, refresh **and** install).

`scripts/hpm_sign.py sign <index.json> <secret> <index.json.sig>` is still
what produces the signature; the secret is the repository operator's and the
matching public key is compiled into `hpm` (`etc/hpm/trusted.pub`).
`tests/linux/installed_update.sh` still passes `--allow-unsigned` for the
255.one half and prints a NOTE about it; both can now go.

### 2b. FIXED — `hpm` took the installed machine's `/etc/rc.boot`

This is how it read when it was found. `hamnix-init` shipped
`etc/rc.boot.linux` **as** `/etc/rc.boot`. On the live image that is the same
bytes twice and invisible. On an installed machine it replaces the boot script
of the running system. Measured, immediately after `hpm install` on the
installed disk:

```
[iupd] p1 /etc/rc.boot after installing from the PUBLISHED 1.0.7:
# /etc/rc.boot.linux — the bootstrap rc for the Linux line, interpreted by
# hamsh running as PID 1.
```

The obvious fix — ship both rcs under their own names and let the package stop
owning `/etc/rc.boot` — was tried and **measured to be worse**. hpm's upgrade
removes the files the *old* version owned before laying down the new one, and
1.0.7 owns `etc/rc.boot`. With that change in place, after `hpm update`:

```
[iupd] p1 stat of /etc/rc.boot after hpm ran:
ls: open failed: /etc/rc.boot
```

The machine had no boot script at all. Not a smaller fault than the first one:
a brick.

**Both are the same missing concept, and it is the package manager's.** A path
can be **machine-owned**: written by whichever image or installer made the
machine, and therefore not any package's to write, to delete, or to claim.
dpkg calls these conffiles. Three parts, and each one is load-bearing:

1. **`user/hpm.ad` — `_is_machine_owned()`.** `etc/rc.boot` is never
   overwritten, never unlinked by a remove (which is what an upgrade does
   first), and never **recorded** in `installed.json` as a package's file, so
   no later remove can reach it either. hpm still writes it when it is
   **absent**, which makes an update *repair* a machine that lost its rc
   rather than leave the hole. The list is compiled in rather than read from
   package metadata for the reason in point 3: the hpm that must not delete
   your boot script is the one **already on the machine** when you type the
   command, and nothing a future package says about itself can reach it.

2. **`user/hlinstall.ad` — the installed `/etc/rc.boot` is an indirection.**
   It is `etc/rc.boot.machine`, whose only executable line is

   ```
   source '/etc/rc.boot.installed'
   ```

   Everything a release can improve lives in `/etc/rc.boot.installed`, which
   `hamnix-init` owns and an update delivers; anything specific to this box
   goes below the source line, where nothing will touch it. The installer
   prefers the image's copy of `etc/rc.boot.machine` and falls back to writing
   the line itself, so an image that does not carry that file still installs.

3. **`scripts/hamlinux_packages.py` — the transition release.** `hamnix-init`
   **still ships `/etc/rc.boot`**, now as the one-liner. This is the half that
   is easy to get wrong and it is the whole reason 2b was hard: an installed
   1.0.7/1.0.8 box runs **1.0.7's hpm**, which knows nothing of point 1 and
   will delete `etc/rc.boot` on the `hamnix-init` upgrade whatever this tree
   does. The only thing that can put a working rc back on such a machine is
   the package it is upgrading *to*. So the package ships one — and ships the
   right one, so that machine ends up sourcing the real installed rc instead
   of being handed the initramfs rc it used to get. It is safe on every other
   machine because of point 1. Dropping the entry before no pre-fix hpm is
   left in the field re-creates the brick, and the entry says so.

The gate's rc.boot arm is a **check** now rather than a note.

### 2c. FIXED — an installed machine could not restart or shut itself down

This is how it read when it was found:

```
[iupd] p1 can this machine restart itself?
reboot: requested reboot
reboot: cannot open /dev/reboot
[iupd] p1 reboot status: 1
```

`/bin/reboot`, `/bin/poweroff`, `/bin/halt` and `hamsh`'s `init 0` / `init 6`
all do the Plan-9 thing: write a verb to `/dev/reboot`. That is a Hamnix
**kernel** device, and on this line no kernel served it — nothing in
`user/linux-syscalls.c` claimed the name, so the open fell through to devtmpfs
and failed. Consequences:

* A machine somebody installed had no supported way to reboot or power off.
* **Nothing flushed the filesystems on the way down.** Every restart of an
  installed hamnix-linux to that point was the equivalent of pulling the plug,
  and survived only because ext4 has a journal. This gate worked around it by
  idling 30 s after its last write so the journal committed before the host
  took the VM away — not something a user can be asked to do.

`user/linux-syscalls.c` now serves it, ported from Hamnix's `DEV_REBOOT` cdev
(`sys/src/9/port/namec.ad:_devreboot_write`) with the protocol intact: the
**first token** of the write, delimited by NUL / `\n` / space / end-of-count,
case-sensitive, and exactly three verbs — `poweroff`, `reboot`, `halt`. Reads
are EOF so a stray `cat` cannot wedge, and an unknown verb is accepted and
ignored, as it is there. A recognised verb calls **`sync(2)` and then
`reboot(2)`** with `RB_POWER_OFF` / `RB_AUTOBOOT` / `RB_HALT_SYSTEM`. Hamnix's
`power_action()` flushes every filesystem and block device before it touches
the hardware; Linux's `reboot(2)` does not, so the port does it.

It is served **inline** rather than as a `user/linux-reboot.c`. The devices
with their own file (fb, wsys, snarf, net, audio) all carry real state — a
shared segment, a window table, a DRM master, an lseek cursor. This one
carries none, and `/proc/<pid>/note` directly above it in the same file is the
same shape (a name written to a file is a kernel action) and is served the
same way.

It does **not** stop services or the desktop first, deliberately: that policy
already lives in `hamsh`'s `svc_runlevel_halt()` / `svc_runlevel_reboot()`,
which SIGTERM every supervised service and source `rc.0` / `rc.6` *before*
they write here, exactly as Hamnix does. A shutdown that hangs forever waiting
for one service to die is worse than a fast one.

**Measured** by `tests/linux/reboot_device.sh`, **37 PASS / 0 FAIL** — a live
boot for the protocol and the privilege question, then an installed disk
booted twice:

| | |
|--|--|
| It restarts | disk boot 1 asks, the kernel says `reboot: Restarting system`, and the machine stops **on its own in 13 s** of a 240 s ceiling. Checked against the kernel's own line, because with `-no-reboot` a PID-1 panic also makes QEMU exit — the exit alone proves nothing. |
| **`sync(2)` does the work** | boot 1 writes a stamp to `/etc`, rewrites `/etc/rc.boot`, and reboots **in the same breath — no sleep, nothing given time to settle.** Boot 2 is running the rc boot 1 wrote and finds the stamp. There is no success line to fake that with: without the flush those bytes would still have been in the page cache when the CPU was reset. |
| It powers off | disk boot 2 calls `poweroff`, the kernel says `reboot: Power down`, and QEMU exits **11 s** in because the *guest* asked for S5 rather than because the host took it away. |

**Who may do it.** `reboot(2)` needs `CAP_SYS_BOOT`, and `linux-syscalls.c` is
linked into every Adder program, so the call happens as whoever wrote to the
device. That is a real difference from Hamnix, where the cdev is ungated (the
`devcons` permission hook admits every uid) and only the Linux-ABI `reboot(2)`
requires the hostowner. Here uid 1001 gets `EPERM` back from the write, and
every client in the tree already reports that **by name** and exits non-zero:

```
[rbdev] u1001 reboot:
reboot: requested reboot
reboot: reboot did not take
[rbdev] u1001 reboot status: 1
[rbdev] u1001 STILL HERE after reboot
```

The desktop's **Power Off** still works, because `hamsessui` is spawned by
`hampanelscene`, which `etc/rc.de-user.linux` keeps as **root** on purpose —
it is system chrome, and handing a session to a user is the privileged act.
So the session asks the chrome and the chrome has the authority. If that ever
changes, `user/hamsessui.ad:_power()` names the failure and exits non-zero
rather than dismissing the dialog — the shape commit `bc9b75d8` fixed.

**`poweroff` and `halt` were not in the image at all**, found by the same
test getting `127` where it expected a refusal. The app list in
`scripts/hamlinux_image.sh` carried `reboot` alone, added for the installer,
so the most obvious of the three commands answered *command not found* on a
console and on an installed disk. All three ship now.

### 2d. FIXED — root's `/tmp/hpm` locked the desktop user out of `hpm refresh`

```
[iupd] u1001 refresh (root already made /tmp/hpm this boot):
hpm: cannot open /tmp/hpm/index.json for write: Permission denied
```

The index cache was one file, `/tmp/hpm/index.json`, in a directory whichever
principal ran `hpm` first created. On an installed machine that is always root
— the boot, or the operator installing something — and root's `mkdir` leaves
`/tmp/hpm` 0755 root-owned in a sticky `/tmp`. The person at the desktop is
uid 1001, and their next `hpm refresh` (which is also the **Refresh** button
in the Software app) died on a machine where the same command worked perfectly
for root. Third fault of this exact shape in this tree; the first two were a
mount point and a socket.

Fixed in `user/hpm.ad`: the cache is now `/tmp/hpm/index-<uid>.json`, 0600,
with the directory 0777 (sticky `/tmp` still protects it). **Not** a
world-writable shared cache: the index is the root of trust for every package
hash, so a copy any local user can rewrite is a privilege escalation against
root's next `hpm install`. The gate now passes that arm.

### 2e. The gate's `NEWVER` collides with whatever 255.one is serving

`tests/linux/installed_update.sh` installs `hamnix-diff` from the live
repository and then publishes a "newer build" to a local channel at
`NEWVER`, which defaults to **1.0.8**. 255.one now serves 1.0.8 itself, so the
first install already lands 1.0.8, the local channel offers the same version,
`hpm update` correctly reports `upgraded=0`, and five checks fail — the bytes,
the stamp, and their post-reboot repeats. Nothing is wrong with the update
loop; the "newer" build was not newer.

Measured both ways on 2026-08-11: default 1.0.8 → 31 PASS / 5 FAIL,
`HAMLINUX_UPD_VERSION=1.0.9` → **36 PASS, 0 FAIL, exit 0**, including
`iupd: PASS a bare 'hpm refresh' trusts https://255.one/` where that line used
to be a NOTE. The default wants to become "one above whatever the live
repository currently serves" — read from the index rather than hard-coded, so
publishing to 255.one cannot silently fail somebody else's gate.

---

## 3. Three commands that answered without doing anything — FIXED

Found by this test hanging on them, and all three mattered beyond it.

* **`md5sum` was a marker-shape stub.** `user/md5sum.ad` drained stdin,
  ignored its argument entirely and printed the MD5 of the *empty string* as a
  compiled-in constant. `md5sum /bin/diff` blocked forever on a console and,
  on a pipe, answered `d41d8cd98f00b204e9800998ecf8427e` for every input in
  the world. It would not merely have failed to verify a file — **it would
  have verified any file**, which is worse than shipping no checksum tool, and
  it is exactly the class of failure this project is organised against.

  It is real MD5 (RFC 1321) now, streaming, shaped like `user/sha1sum.ad`:
  FILE operands, stdin when there are none, and `-c` check mode. The 64-entry
  K table is checked against `floor(abs(sin(i+1)) * 2^32)` and the round
  structure against Python's `hashlib` on twelve inputs, including every
  55/56/57/63/64/65-byte padding boundary and a 100 KB random file; on the
  device it is checked against the digest GNU `md5sum` computed on the host
  for the same bytes. (The `.ad` cannot be run on the host to compare
  directly: the runtime's `sys_*` are Hamnix numbers, not host Linux ones, so
  a host-built binary calls `lseek` where it meant `write`.)
* **`head` took no file operand.** `head -3 /etc/rc.boot` ignored the name and
  blocked on stdin forever rather than saying it could not do that. It takes
  FILEs now, with the GNU `==> NAME <==` banner when there is more than one.
* **`cksum` read stdin only**, so the only way to checksum a file was
  `cksum < FILE`. It takes FILEs now and prints the GNU
  `<crc> <bytes> <name>` form for them. It was already the real thing (POSIX
  CRC-32, agrees with GNU `cksum`) and is what the gate uses.
* **A PIPE INTO `md5sum` NEVER RETURNED**, and it cost a whole boot. The rc
  asked `cat /etc/hamnix-update-stamp | md5sum` for the stream half of the
  digest check; the banner printed, no digest appeared under it, and the VM
  died on the host's timeout with every phase-2 check failing as collateral.
  The same `md5sum` had answered two FILE operands correctly in the two lines
  immediately above, so what did not finish is the **pipe's EOF**, not the
  hash. It was not chased down here — it is a `hamsh`/`sys_pipechan` question
  and this gate was not the place to burn boots on it — and the stream arm
  used `md5sum < FILE`, the same shape as the `cksum < FILE` that has always
  worked.

  **CHASED DOWN AND FIXED SINCE.** The answer to "which end did not finish"
  is the **writer**, and the writer that never closed was **hamsh itself**.
  `sys_pipechan` (`user/linux-fdns.c`) opens each pipe slot's fifo `O_RDWR`
  and keeps that descriptor so the terminal's first open cannot deadlock —
  but `O_RDWR` is a writer, and nothing ever closed it, so no reader on any
  pipe in the system could ever see EOF. It was not an md5sum bug and it was
  not even a pipeline-specific bug; only readers that drain to EOF could show
  it. The keeper now has a lifetime rather than a presence: the slot records
  whether each REAL end has ever been opened and the keeper is closed once
  both have. Four more faults of the same family came out of the boot that
  followed — a leaking `/fd` bind table that ran out silently, a stale-bind
  clear that raced the child it was cleaning up for, two processes claiming
  one record, and `wc` ignoring its FILE operands (the fourth member of the
  `head`/`cksum`/`md5sum` family in this very list). `tests/linux/fdns_pipe.sh`
  and `tests/linux/pipelines.sh`, and **this gate's stream arm is
  `cat /etc/hamnix-update-stamp | md5sum` again** — the exact command that
  cost the boot, which makes it the cleanest available proof.
* **A redirect whose source is the running rc wedges the shell.** Inside
  `/etc/rc.boot`, both `head -3 < /etc/rc.boot` and `cksum < /etc/rc.boot`
  hang the boot dead — as does overwriting `/etc/rc.boot` mid-script, which
  replaces the bytes PID 1 is about to read. `ls -l /etc/rc.boot` is the form
  that answers. Two boots were spent learning this; the gate says so where it
  matters. Note that this is a property of the **redirect**, not of the
  commands: `head -3 /etc/rc.boot` and `cksum /etc/rc.boot`, which are now
  legal, open the file themselves and do not go through the shell.

---

## 4. Running it

```
tests/linux/installed_update.sh [phase1-seconds] [phase2-seconds]
    HAMLINUX_UPD_REUSE=1    reuse an already-built image root + local channel
    HAMLINUX_UPD_VERSION=…  the version the "newer build" carries (default 1.0.8)
```

It needs a network (it talks to the real `https://255.one/`) and a
`build/image/distro.ext4`. It serves the local channel on a port it picks at
random and reaps the server on exit; it publishes nothing anywhere.

Two mechanics worth knowing:

* `scripts/hamlinux_disk.sh` grew `HAMLINUX_DISK_EXTRA=<dir>`, an overlay
  copied onto the root partition before the filesystem is made. A test that
  reboots the machine needs its second rc *already on the disk* before the
  first boot — rebuilding the disk between the two boots would destroy the
  persistence the reboot exists to prove.
* Each boot's stdin closes after 5 s on purpose. When the rc ends, `hamsh` —
  which *is* PID 1 — falls through to reading the console; an open stdin holds
  the VM there until the host's timeout fires and every boot costs its whole
  budget. With stdin at EOF, PID 1 exits as soon as its rc is done, the kernel
  panics (`panic=-1`) and `-no-reboot` makes QEMU exit. The timeouts are
  ceilings, not durations. That is only tolerable because §2c means there is
  no clean way to stop the machine from inside it.
