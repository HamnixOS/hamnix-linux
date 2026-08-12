# The run sweep's unhealthy rows, by name, with the reason

`scripts/hamlinux_runsweep.sh` prints a score. This file is the other half of
it: **every row that is not in the numerator, why, and what would close it.**

It exists because a score with no list behind it is an argument rather than a
measurement, and because the four reasons a row can be unhealthy need four
different responses. Confusing them is how a harness comes to blame fifty
programs for its own file-size cap (it did — see THE CAP, below).

Two neighbouring files already carry part of this and are not repeated here:

* `tests/linux/runsweep_expected_fail.tsv` — rows whose CONTRACT is a non-zero
  exit, one reason per row, counted with the healthy. Its header states the
  bar and, more usefully, what does **not** meet it.
* `tests/linux/runsweep_recipes.tsv` — the `lib` / `disk` / `net` / `payload` /
  `unsafe` classes, which the sweep declines to run at all and which leave the
  denominator rather than joining the numerator.

---

## The four kinds

**1. A device or a file this port owes and does not serve.** The program says
so by name and exits non-zero. These are REAL GAPS: they stay unhealthy, they
stay in the denominator, and the number is supposed to be uncomfortable. The
expected-fail table's header refuses them explicitly — "the distinction is not
the message, it is whose job the missing thing was".

**2. Hardware or privilege the harness withholds on purpose.** The sweep runs
on somebody's workstation, in a user namespace, under `nice -n 15`. It has no
sound card, no CAP_SYS_NICE, no CAP_SYSLOG and no CAP_SYS_MODULE, and it must
not acquire any of them. The programs below are believed correct and cannot be
demonstrated correct **here**. They are left in the failing column deliberately:
moving them out would raise the score on the strength of a belief, and this
file is not a place to launder one.

**3. A launcher the sweep does not run.** An X server, a compositor-allocated
window id, a connection number the master would have accepted. Where the
program's own header names the launcher and refuses, the expected-fail table
already covers it — sixteen chrome-spawned overlays are in there. The two
X11 bridges below are the ones that are not.

**4. The harness's own mistake.** Not a category to live in — a bug to fix, in
the harness, immediately. The sweep's history is mostly this: a 4 s GUI
timeout, a `-` in the argv column, a staging probe that picked a static binary,
and the file-size cap twice.

---

## THE CAP, because it is the most recent and the largest

Measured 2026-08-11 on `port/tier1-syscalls`: **50 of the sweep's 88 windowed
rows** scored `UP_NO_WINDOW` and `PAINTED` had fallen from 51 to 2. None of
those fifty programs was broken. `wsysd`'s `ftruncate(2)` of the v2 backbuffer
pool was refused `EFBIG` by the harness's own `ulimit -f` and the kernel killed
it with `SIGXFSZ`, *after* it had passed the readiness gate — the pool is
allocated lazily, on the first window.

`BB_FILE_BYTES` is 4,261,478,400 bytes because `WSYS_MAX_WINDOWS` has gone
8 → 64 → 128 → 256; the cap was 256 MiB, chosen when a comment beside it said
"BB_SLOTS(8) ... = 132 MB". **The file is sparse** — 4 GB of `ftruncate` cost
22,856 KiB of blocks in that run — so the cap was bounding the wrong thing.

Fixed two ways, because a number in a comment is what went stale:

* the windowed rows get a pool-sized cap and everything else keeps 256 MiB,
  since `yes` writes real bytes onto a real disk;
* `tests/linux/runsweep_jail.sh` reports `HARNESS_FAIL` if the compositor is
  not alive when the program finishes, so the next time the pool outgrows the
  cap the sweep says so instead of blaming fifty programs.

---

## The list

### Kind 1 — real gaps: a name this port does not serve

| row | what it asks for | what would close it |
|--|--|--|
| `chvt` | `/dev/vt/ctl` | nothing in `user/linux-*.c` serves it; Linux's equivalent is the VT ioctls on `/dev/tty0` |
| `loadkeys` | `/dev/keymap` | not served; Linux's is `KDSKBENT` on the console fd |
| `hfw` | `/dev/firewall` | not served; Linux's is nftables/netlink |
| `oopsread` | `/proc/oops` | not served; Linux's equivalent record is `/sys/fs/pstore` |
| `initctl` | `/proc/svc/ctl` | `user/service.ad`'s own message is the bug report: `SYS_SVC_PUBLISH` has no implementation here and the service registry lives inside `hamsh`, which is PID 1. There is no file interface to it |
| `service` | `/proc/svc` | as above |
| `nsrun` | `sys_srv_open` | `ENOSYS` in `user/linux-syscalls.c`, and deliberately: posting an open fd under a name is HANDOFF §7.1's cross-process fd-addressing question, which the `/net` design has not answered yet |
| `umdf_host` | `sys_umdf_dma_alloc` | `ENOSYS` **on purpose** — the stub's own comment says Linux owns the hardware and "deleting the call sites is the actual fix". The self-test correctly reports the primitive is absent (it used to print FAILED and exit 0) |
| `modprobe` | `/lib/modules/modules.dep` | no `modules.dep` is generated anywhere on this port. `scripts/hamlinux_image.sh` stages `.ko` files and an `/etc/modules` list, and PID 1 loads them **by absolute path** — its own comment notes that an autoload "would quietly not happen". `scripts/build_modules_dep.py` exists and is the obvious start |

### Kind 2 — hardware or privilege the harness will not take

| row | withheld | evidence it is the harness |
|--|--|--|
| `aplay`, `arecord`, `playtone`, `hamsdl_audio_demo` | a sound card | `/dev/audioctl` **is** served (`user/linux-audio.c`), backed by the real `/dev/snd/pcmC*D*p`. The jail binds six device nodes and `/dev/snd` is not among them, because the host's audio belongs to whoever is using the machine |
| `nice_hi`, `nice_demo` | `CAP_SYS_NICE` | measured: `unshare -rm nice -n -20 nice` is "Permission denied", and the sweep itself runs under `nice -n 15`. `lib/hamnice.ad` already falls back from the Plan 9 ctl file to `setpriority(2)`; both refuse, correctly, and the program exits 1 rather than claiming a priority it did not get |
| `wakelat`, `sysirqprobe` | the same, plus `/proc/self/ctl` | both are kernel-latency instruments that need to renice their own hogs; they say `cannot open /proc/self/ctl` and then run anyway, and time out |
| `dmesg` | `CAP_SYSLOG` | measured: inside `unshare -rm`, `/proc/kmsg` is present, mode 0400, and the read is `EACCES`. dmesg now names that case separately from "no such ring buffer" |
| `insmod`, `rmmod` | `CAP_SYS_MODULE` | `init_module(2)` cannot succeed in a user namespace at all. `insmod` is additionally handed `%F`, a text file, which is not a `.ko` — its refusal is doubly correct |
| `ac` | the Debian namespace | `ac` compiles by binding `#distro` and running clang inside it (its own header, THE TWO HALVES). The jail has no `/etc/distros` and no block device, so the bind fails and it exits 126. This is the `disk` class's problem wearing a `cmd` class's label |

**These are not moved out of the denominator.** For most of them the belief
that the program is correct is well founded and still a belief: this sweep has
not seen `aplay` play anything. Leaving them visible is the conservative
reading, and the score is lower for it on purpose.

### Kind 3 — a launcher the sweep does not run

| row | needs | note |
|--|--|--|
| `xbridge` | a running `Xvfb -fbdir` | refuses by name: "start Xvfb with -fbdir first". It is the one `gui` row that needs an X server rather than a compositor |
| `xsnarfd` | an X11 socket to bridge to | given a scratch path it prints "no X server at that socket yet; retrying every second" and **parks** — `sys_waitfds`, 0.0 s of cpu — which is the correct behaviour for a bridge daemon and is scored `TIMEOUT` because the row is class `cmd`. Reclassifying it `daemon` would score it `STAYS_UP`, i.e. healthy, for a clipboard bridge that has bridged nothing. That is success-shaped, so it has been left alone |

---

## What was fixed in the pass that wrote this file

| row(s) | it was | it is |
|--|--|--|
| 50 windowed rows | `UP_NO_WINDOW` — the harness's file cap killed the compositor | `PAINTED` / `DREW_WINDOW` |
| `pgrep` | opened `/proc/tasks`, which does not exist on Linux, and so failed for every pattern | walks `/proc`'s pid directories; output byte-identical to procps' `pgrep` |
| `passwd` | `/dev/auth` served no `setpass` verb, so no password could be changed on this port by anyone | the verb is served, gated hostowner-or-self; `tests/linux/auth_setpass.sh` |
| `memhog` | the recipe asked for 16 **bytes** and read the residency refusal as a bug | the recipe spells the size the way the program documents it |
| `ps`, `md5sum`, `pgrep` claims | described programs that had been rewritten out from under them | describe the programs |
| `dmesg` | one message for two different failures | `EACCES` is named separately from "no such ring buffer" |
