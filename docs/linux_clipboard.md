# The clipboard on the Linux line — `/dev/snarf` and `/dev/snarf.primary`

`docs/linux_build_count.md` §4 and `HANDOFF.md` §0 recorded this as honestly
broken: **there was no clipboard on this line.** `lib/hamtextbox.ad` and
`lib/htermsel.ad` — the shipped code the editor, Notes, the browser URL bar and
the grid terminal all go through — reach the clipboard **by path**, and nothing
in this repository served or created those two paths. `htsel_clip_put` opened
`/dev/snarf`, got `-ENOENT`, and returned 0 to a caller that ignored it. Copy
and paste between programs did nothing, and said nothing when it didn't.

It is served now, by `user/linux-snarf.c`, and this is the record of what was
decided and why — including the cheaper answer that was not taken.

---

## 1. The decision: a device, not two ordinary files

The measurement that scoped this (build_count §4) was right, and it is worth
restating because it is the strongest argument against what was built:

> Two ordinary files at those paths give exactly the semantics the toolkit
> needs. `sys_open_write` is `O_WRONLY|O_TRUNC` so a write REPLACES including
> shrinking, `sys_read` is offset-addressed and hits EOF, the two are
> independent, and being real files they persist across processes. Creating
> them in the rc scripts would make copy/paste work with no new server and no
> client change.

All of that is true. **It was not taken, for four reasons, and each is a thing
this tree has already been bitten by once.** The full argument lives in the
header of `user/linux-snarf.c`; in brief:

1. **`/dev/snarf` would not be a device**, and the `O_CREAT` guard in
   `sys_open_write` — the one that stopped `playtone` writing 24 000 audio
   frames into a regular file called `/dev/audio` and reporting success —
   depends on the premise that `dev_path()` claims exactly the paths that have
   a server behind them. Planting two ordinary files under `/dev` retires that
   premise by hand.
2. **The 64 KiB cap.** `/dev` is devtmpfs and `/srv` is tmpfs: both are RAM.
   An ordinary file has no cap, so `cat bigfile > /dev/snarf` — an entirely
   ordinary thing to type at a shell that has a clipboard — puts an unbounded
   amount of the owner's memory beyond reach, with no error. `lib/devsnarf.ad`
   has always said `SNARF_MAX = 65536`; this is where that number became true.
3. **The offset protocol is the device's, not the filesystem's.** `off == 0`
   REPLACES (a 0-byte write CLEARS, which is Plan 9's semantics), `off > 0`
   writes there and EXTENDS. A file gets the first half of that from `O_TRUNC`
   at open — a different mechanism that happens to agree today. The case where
   it stops agreeing is already written down as Defect 2 in
   `docs/text_selection_clipboard.md`.
4. **Lifetime and ownership are stated, not inherited.** Whoever first opens an
   ordinary `/dev/snarf` owns it, at whatever the umask of that moment says —
   and on this line the first opener is not predictable, because the compositor
   and chrome are root and the session is uid 1001.

**What a device does not buy, said plainly.** The segment is 0666 and
`MAP_SHARED`, so a program that skips the runtime and mmaps `/srv/snarf` itself
can read and write the clipboard whatever any `if` in `linux-snarf.c` says —
the same asymmetry `linux-wsys.c` names for its SEGMENT A. Unlike wsys there is
no split to make: **a clipboard has no privileged half.** Its entire purpose is
to carry bytes across the root-chrome / uid-1001-session boundary, so "writable
by every uid that can see these windows" is the correct policy, not a
compromise. Reads are ungated, as they are everywhere in this tree.

## 2. The shape

`user/linux-snarf.c` + `user/linux-snarf.h`, hooked into the existing synthetic
device table in `user/linux-syscalls.c` exactly as `/dev/fb`, `/dev/wsys`,
`/net`, `/dev/auth` and `/dev/audio` are: `hamsnarf_kind()` claims the two exact
paths, `devtab_open()` routes them, and `sys_read` / `sys_read_nb` /
`sys_write` / `sys_lseek` / `sys_close` / `sys_dup` / `sys_dup2` dispatch on the
`issn` flag.

**The buffer semantics are `lib/devsnarf.ad`'s, ported rather than
re-decided** — `_sn_store` and `devsnarf_read` are reproduced rule for rule,
including "a write past the cap is truncated but still reports `count` consumed
so a userland write loop terminates". `lib/devsnarf.ad` stays exactly as it is:
it is the module the four `*_host.ad` harnesses (64 assertions) test, and it is
now the written-down specification the C server implements.

The state is a shared segment, because in-process state is not a clipboard:

```
$HAMSNARF                     explicit, pinned per run
$HAMWSYS + ".snarf"           when a window system is pinned  ← see below
/srv/snarf                    the posted-server name on a real boot
/dev/shm/hamnix-snarf         host-run fallbacks
/tmp/hamnix-snarf
```

Attach-before-create on every candidate, then `fchmod(fd, 0666)`. Both of those
are copied deliberately from `linux-wsys.c`'s `shm_attach`, where each fixes a
measured silent failure: `O_CREAT` on another uid's file in a sticky
world-writable directory is refused by `fs.protected_regular`, and `open(2)`'s
mode is masked by PID 1's umask to 0644. Either one makes a uid-1001 client
fall through to a **private** clipboard — copy reports success, paste returns
nothing, nothing is printed anywhere.

**Whose clipboard is it? One per WINDOW SYSTEM, deliberately.** The scope of a
clipboard should be exactly the set of programs that can see each other's
windows, and that set is named by `/srv/wsys`. So when `$HAMWSYS` is set — how
an offscreen or per-run window system is pinned — the segment is *derived* from
it. That is the fix for a hazard already paid for: `docs/steam_namespace.md` §11
records `HAMWSYS_BB` as "the third shared file, and it bit", one per host, where
one offscreen run inherited another's state. The clipboard is the fourth such
file, and it is pinned by construction rather than by remembering to.

**No rc line, no image change.** A served device needs nothing created at boot,
which is why this change touches no file in `etc/` and no build recipe beyond
one compile stanza.

## 3. The X clipboard is a different clipboard, and this pass did not bridge it

A Debian or Alpine program in a namespace uses X selections, owned by the
Xwayland inside that namespace; `jwm` and the Wayland path have their own. That
is a genuine design question and the answer here is *separate, for now, and
said out loud*.

**The boundary is measured, not asserted.** `tests/linux/snarf_device.sh` arm 3
runs the host's `/bin/cat` — standing in for a foreign binary — against
`/dev/snarf` and gets `No such file or directory`, in the same namespace where
the Hamnix `cat` prints the clipboard's contents. That is not a defect: it is
true of `/dev/wsys`, `/net` and `/fd` too, all of which are served *inside the
process* by the Hamnix runtime.

Bridging is not a line in a device server. It needs a process that OWNS an X
selection and mirrors it in both directions, reacting to selection-ownership
changes on both sides — a program, and one that belongs beside the Wayland/X
path rather than here. **Doing half of it** — mirroring X into Hamnix but not
back, or on copy but not on ownership change — **would be exactly the
success-shaped failure NORTH_STAR exists to beat**, so it is named as not done
instead of quietly approximated. The Plan 9 half is already in place: a name is
what crosses a boundary, and `/dev/snarf` is reachable from inside any
namespace that runs Hamnix binaries, with nothing bound.

## 4. Verification

`tests/linux/snarf_device.sh` — QEMU-free, **23 assertions, 23 PASS**. It is
the oracle for the claim "copy and paste between programs works", not for "the
file exists":

* **`tests/linux/snarfcopy.ad` copies through `lib/hamtextbox.ad`** (the editor
  / Notes / URL-bar path) and **`tests/linux/snarfpaste.ad` pastes through
  `lib/htermsel.ad`** (the grid terminal's path), in a **separate process**
  each time. The two libraries carry independent copies of the path selector —
  `_htb_clip_path` and `_htsel_clip_path` — because importing hamtextbox into
  the terminal would drag the proportional TTF font engine with it, so a test
  that copied and pasted through one library would not have proved they agree
  about which name is which buffer. This one does.
* CLIPBOARD and PRIMARY are independent in both directions; a shorter copy
  REPLACES including shrinking; a 0-byte write CLEARS one and leaves the other;
  a 70 000-byte copy reports 70 000 consumed and reads back exactly 65 536.
* **Arm 2, the cross-uid case:** two uids out of `/etc/subuid` in a user
  namespace, the technique `tests/linux/wsys_uidgate.sh` uses. Inner root (the
  chrome) copies, inner 1001 (the session) pastes it, copies back into the
  root-owned segment, and root pastes that. The segment is asserted to be
  `0666`, which is the assertion that fails if the `fchmod` is ever removed.
* **Arm 3, the shell:** `echo hello-from-the-shell > /dev/snarf` under `hamsh`
  lands **21 bytes** — the 20-byte payload *and* the newline `echo` wrote as a
  separate `write()` at offset 20. A replace-always device answers 1 here,
  holding `"\n"`. That is Defect 2, and it is the reason the protocol is
  offset-addressed.
* It all runs in a **private mount namespace with a tmpfs over `/dev`**, which
  is both the safety rule and the negative control: after a full copy/paste run
  there is still **no file at `/dev/snarf`**, so a run that passed by planting
  ordinary files would fail, and one that reached the host's `/dev` could not
  have got that far.

**One thing that fixture teaches, worth writing down.** A bare tmpfs over
`/dev` does not test "the device with no filesystem underneath" — it tests "the
device with the devtab broken". Every synthetic device on this line gets its fd
from `devtab_open`, which opens `/dev/null` so the slot is a real descriptor
that survives fork; with `/dev` emptied, every open fails before the mechanism
under test runs. The fixture binds the outer `/dev/null` aside and rebinds it,
and `/dev` is then asserted to hold *only* `null`. (The §4 measurement did not
hit this because the thing it was measuring *was* a filesystem path.)

`tests/linux/snarf_ondevice.sh` — **6 assertions, 6 PASS, in the VM**, on the
shipped image with `linuxinit` as PID 1 and `/srv` the tmpfs it mounts. Offscreen
proof is not on-device proof, and this line has been caught by that gap before.

```
[snarfdev] root cat /dev/snarf:                  SNARF-ONDEVICE-9f3a
[snarfdev] root cat /dev/snarf.primary:          PRIMARY-ONDEVICE-9f3a
[snarfdev] and the CLIPBOARD is untouched:       SNARF-ONDEVICE-9f3a
[snarfdev] the segment the FIRST OPEN created:   -rw-rw-rw- 131096 /srv/snarf
[snarfdev] --- setuid 1001 ---
[snarfdev] u1001 cat /dev/snarf:                 SNARF-ONDEVICE-9f3a
[snarfdev] u1001 wrote it back, u1001 cat:       SESSION-ONDEVICE-9f3a
```

131096 bytes is `sizeof(struct snarfshm)` — the two 64 KiB buffers and their
lengths — and `-rw-rw-rw-` is the `fchmod` doing its job against PID 1's umask.
The test stages an rc.boot of its own through the `HAMLINUX_RC` hook (the one
`tests/linux/two_namespaces.sh` uses) only so the sequence runs unattended:
**`grep -rn snarf etc/` is still empty after this work**, because a served
device needs nothing created at boot.

`build/image/desktop_snarf.png` — a full VM boot with this change in: the
desktop comes up, panel, backdrop, application grid, clock, both Wayland
servers started.

Still green, unchanged by this work:

| gate | result |
|--|--|
| `scripts/test_snarf_primary_host.sh` | `passes=16 fails=0` / PASS |
| `scripts/test_htb_evt_paste_host.sh` | `passes=17 fails=0` / PASS |
| `scripts/test_htermsel_evt_host.sh` | PASS |
| `scripts/test_primary_paste_chain_host.sh` | `passes=9 fails=0` / PASS |
| `tests/linux/wsys_uidgate.sh` | PASS |
| `tests/linux/wsys_bypass.sh` | PASS |

## 5. What is left undone

* **The X / namespace clipboard bridge** (§3). Named, not started.
* **No locking.** The length is published after the bytes, so a reader never
  walks off the end of what has been written, but two programs copying at the
  same instant still interleave. That is what it means anywhere; a seqlock
  would buy a consistent snapshot and has not been needed.
* **A bypasser can still mmap the segment** (§1). Closing that needs a mapping
  per owner-uid or an RPC server, the same open item `linux-wsys.c` records for
  its SEGMENT A.
* **No `/dev/snarf` in a directory listing of `/dev`.** Nothing walks `/dev`
  looking for it, and the synthetic devices on this line are uniformly invisible
  to `ls`.
* **No screenshot of a drag-select in one DE window pasted into another.** The
  mechanism is measured at every layer under it — the two toolkit libraries in
  separate processes, the shell, the uid boundary, and the device on a real
  boot — and the desktop is measured to still come up. What is NOT measured is
  the mouse path from a drag in `hameditscene` to a middle-click in the
  terminal, which needs the wid-and-`/ctl`-rect click derivation
  `scripts/test_middle_paste_ondevice.sh` uses on the Hamnix line, ported. Said
  here rather than implied by the assertions that were run: on the Hamnix line
  it was exactly this gap that let nine green gates sit on top of a feature
  that was dead on device (`docs/text_selection_clipboard.md` §4).
