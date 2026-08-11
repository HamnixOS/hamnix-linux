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
again as the desktop user. Unattended, re-runnable, **39 PASS / 0 FAIL**.

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
| **After a reboot** | version, bytes and stamp all still there; the upgraded binary gives both answers again; and all of it holds as **uid 1001** |

The signature path is the one under test, not `--allow-unsigned`: the local
channel is signed with a key minted per run and the machine is handed the
matching public key, so `hpm update` verifies before it trusts a single hash.

---

## 2. What did NOT work, and what each one costs

### 2a. `hpm refresh` refuses `https://255.one/` with no flags

```
hpm: fetching channel linux from https://255.one/linux/
hpm: no index.json.sig for this channel (unsigned repo).
     Re-run with --allow-unsigned to trust it anyway.
hpm: refresh: aborting — untrusted index for channel linux
```

`https://255.one/linux/index.json.sig` is **404**, and so is
`https://255.one/main/index.json.sig`. hpm is right to refuse — an unsigned
index is a MITM's index — but the owner's command, typed exactly, does not
work today on any machine, live or installed. The index itself fetches fine
over TLS; only the signature is missing.

**The fix is a publish, not a patch.** `scripts/hpm_sign.py sign <index.json>
<secret> <index.json.sig>` produces it; the secret is the repository
operator's and the matching public key is already compiled into `hpm`
(`etc/hpm/trusted.pub`). Until then a machine needs `--allow-unsigned`, which
is what the gate uses for the 255.one half so the rest can be measured.

### 2b. `hpm` takes the installed machine's `/etc/rc.boot` — and removing it is worse

`hamnix-init` ships `etc/rc.boot.linux` **as** `/etc/rc.boot`. On the live
image that is the same bytes twice and invisible. On an installed machine it
replaces the boot script of the running system. Measured, immediately after
`hpm install` on the installed disk:

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

The machine had no boot script at all. So the shipped behaviour is left as it
is, and the whole measurement is recorded in the `hamnix-init` entry of
`scripts/hamlinux_packages.py`.

**What actually fixes it** (needs `user/hlinstall.ad`, which this agent does
not own): an installed `/etc/rc.boot` should be one line —

```
source '/etc/rc.boot.installed'
```

— written by the installer and owned by no package, with `hamnix-init`
shipping `etc/rc.boot.linux` and `etc/rc.boot.installed` under their own
names. Then an update delivers every change to either rc and cannot touch the
machine's own boot configuration. The transition needs **one release that
ships `/etc/rc.boot` as well**, so the upgrade does not remove it from the
machines that already have it.

### 2c. An installed machine cannot restart or shut itself down

```
[iupd] p1 can this machine restart itself?
reboot: requested reboot
reboot: cannot open /dev/reboot
[iupd] p1 reboot status: 1
```

`/bin/reboot`, `/bin/poweroff`, `/bin/halt` and `hamsh`'s `init 0` / `init 6`
all do the Plan-9 thing: write a verb to `/dev/reboot`. That is a Hamnix
**kernel** device, and on this line no kernel serves it — nothing in
`user/linux-syscalls.c` claims the name, so the open falls through to devtmpfs
and fails. Consequences:

* A machine somebody installed has no supported way to reboot or power off.
* Nothing flushes the filesystems on the way down. The gate works around it by
  idling 30 s after its last write so the ext4 journal commits before the host
  takes the VM away — not something a user can be asked to do.

The fix is a `/dev/reboot` in `user/linux-syscalls.c` (not this agent's file):
open claims the name; a write of `reboot` / `poweroff` / `halt` calls
`sync(2)` and then `reboot(2)` with `LINUX_REBOOT_CMD_RESTART` / `_POWER_OFF`
/ `_HALT`. ~20 lines, and it makes `reboot`, `poweroff`, `halt` and both
runlevel paths in `hamsh` work at once, live and installed.

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

---

## 3. Three commands that answer without doing anything

Found by this test hanging on them, and all three matter beyond it.

* **`md5sum` is a marker-shape stub.** `user/md5sum.ad` drains stdin, ignores
  its argument entirely and prints the MD5 of the *empty string* as a
  constant. `md5sum /bin/diff` blocks forever on a console and, on a pipe,
  answers `d41d8cd98f00b204e9800998ecf8427e` for every input in the world.
  `user/cksum.ad` is the real thing (POSIX CRC-32, agrees with GNU `cksum`)
  and is what the gate uses — but it reads stdin only, so `cksum < FILE`.
* **`head` takes no file operand.** `head -3 /etc/rc.boot` blocks on stdin
  forever rather than saying it cannot do that.
* **A redirect whose source is the running rc wedges the shell.** Inside
  `/etc/rc.boot`, both `head -3 < /etc/rc.boot` and `cksum < /etc/rc.boot`
  hang the boot dead — as does overwriting `/etc/rc.boot` mid-script, which
  replaces the bytes PID 1 is about to read. `ls -l /etc/rc.boot` is the form
  that answers. Two boots were spent learning this; the gate says so where it
  matters.

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
