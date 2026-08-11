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

## 3. The X clipboard is a different clipboard, and `user/xsnarfd.ad` bridges it

A Debian or Alpine program in a namespace uses X selections, owned by the
Xwayland inside that namespace; `jwm` and the Wayland path have their own.

**The boundary is measured, not asserted.** `tests/linux/snarf_device.sh` arm 3
runs the host's `/bin/cat` — standing in for a foreign binary — against
`/dev/snarf` and gets `No such file or directory`, in the same namespace where
the Hamnix `cat` prints the clipboard's contents. That is not a defect: it is
true of `/dev/wsys`, `/net` and `/fd` too, all of which are served *inside the
process* by the Hamnix runtime.

The pass that wrote this file named the shape of the fix and did not build it:

> Bridging is not a line in a device server. It needs a process that OWNS an X
> selection and mirrors it in both directions, reacting to selection-ownership
> changes on both sides.

That is what `user/xsnarfd.ad` is. §6 is its record.

## 3a. Why an X selection cannot be mirrored like a buffer

There is no place in an X server where the clipboard lives. A client **owns**
`CLIPBOARD` (and `PRIMARY`); anyone pasting sends `ConvertSelection` and the
**owner** answers, in a target the paster asked for. So:

* the bridge cannot *poll* the X side — there is nothing to read;
* the bridge cannot *write* the X side — there is nowhere to write;
* the bridge must **be a client**, take ownership when `/dev/snarf` changes,
  and answer every conversion request out of the Hamnix buffer;
* and it must notice when somebody **else** takes ownership, ask that owner
  for the bytes, and put them into `/dev/snarf`.

Both halves or neither. A bridge that mirrors on copy but not on ownership
change loses exactly the paste that mattered and says nothing.

## 3b. Where it runs, and why there is nowhere else

The two things it must touch are on opposite sides of a namespace boundary:

| | |
|--|--|
| `/dev/snarf` | served **in-process** by the Hamnix runtime over a segment named `$HAMSNARF`, or `$HAMWSYS + ".snarf"`, or `/srv/snarf`. **`/srv` is deliberately not carried into a subtree namespace**, so none of those names exist inside one. |
| the X display | **Xwayland runs inside** the distribution namespace, on `:0`, socket at that tree's `/tmp/.X11-unix/X0`. |

So it runs **outside** the namespace, as root, and reaches the display the
Plan 9 way — **by name**. The boot binds each distribution at `/n/<name>`, and
that tree's `/tmp` is the medium's own, so the socket a client inside sees as
`/tmp/.X11-unix/X0` is `/n/alpine/tmp/.X11-unix/X0` from out here. *Same
inode, two names.* Nothing is bound, nothing is copied, `/srv` stays out of the
namespace, and the socket path is an argument exactly as `wsyswl`'s is.

**One bridge per distribution, not one overall** — the same construction
`/etc/rc.distros-wl` already uses for `wsyswl`, and for the same reason: there
is one Xwayland per distribution and an X connection is to one server. They all
share the one `/dev/snarf`, and *that* is what makes it one clipboard: text
copied in Debian's Firefox lands in `/dev/snarf`, and the Alpine bridge then
claims Alpine's `CLIPBOARD` with it. The convergence is content-based, so it
terminates instead of ringing.

It is started **at boot**, from the generated `/etc/rc.distros-wl`, even though
the X server it wants will not exist until somebody launches a program: it
retries once a second and says so once a minute. Starting it *with* the session
instead would make the first copy of every session the one that is lost.

## 3c. Why the X11 wire protocol is written out by hand

Because the alternative is not available. Linking `libX11` would make the
bridge a **foreign binary**, and a foreign binary is precisely the thing that
cannot open `/dev/snarf`. It has to be a Hamnix binary to have a Hamnix
clipboard, so it speaks X11 on the wire — `user/x11/xfill.ad` already does that
against the in-tree toy server. Nothing in `xsnarfd` may assume that server's
fixed resource IDs: the root window and the resource-id base are read out of
the connection setup reply, as they must be against a real Xwayland.

`sys_unix_connect` (`user/linux-syscalls.c`) is the one new runtime primitive.
`sys_unix_listen` and `sys_unix_accept` existed for `wsyswl`'s side of a
socket; nothing had ever needed the other end.

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

* **The X / namespace clipboard bridge** (§3) is built and measured — see §6
  for what it does *not* do.
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

---

## 6. The bridge: `user/xsnarfd.ad`

    xsnarfd /n/alpine/tmp/.X11-unix/X0 alpine

An X client that owns `CLIPBOARD` and `PRIMARY` on the Xwayland inside one
distribution namespace, and mirrors both against `/dev/snarf` and
`/dev/snarf.primary`. §3a–3c are why it is shaped this way; this is what it
does, what it refuses, and what was measured.

### 6.1 The two directions

**Hamnix → X.** Both buffers are read four times a second and compared with
what the bridge last saw. A change means the Hamnix side copied, so the bridge
sends `SetSelectionOwner` — and then **asks the server who the owner is**,
because `SetSelectionOwner` has no reply and a claim the server dropped is
otherwise indistinguishable from one that took. From then on every
`SelectionRequest` is answered out of the buffer.

**X → Hamnix.** `XFixesSelectSelectionInput` on both selections, so every
change of owner produces an `XFixesSelectionNotify` — *including handovers
between two other clients, which is the case a bridge that watches only its own
`SelectionClear` cannot see at all.* On a change the bridge sends
`ConvertSelection` for `UTF8_STRING`, falls back to `STRING` once, reads the
answer with `GetProperty(delete=1)` and writes it into the device.

`SelectionClear` **also** arms the pull, XFixes or not.
`XFixesSelectSelectionInput` has no reply, so a bridge that trusted it alone
would go silently one-way if that request were ever refused — which is exactly
what a wrong length field did here once (§6.4).

**The anti-ping-pong invariant** is one line and it is the whole reason this
converges: the bridge's cache is updated *before* the device is written, so the
next poll does not see its own write as a Hamnix-side change and go claiming
the selection back off the X client that just handed it over.

### 6.2 What it answers, and what it refuses

`TARGETS`, `UTF8_STRING`, `STRING`, `TEXT` — and `TARGETS` lists **exactly**
those four. `TEXT` is answered with type `UTF8_STRING`, which is what ICCCM
asks of an owner that chose UTF-8.

`TIMESTAMP` is **refused** (`SelectionNotify` with property `None`) rather than
listed and answered with a lie: a real ownership timestamp needs the
zero-length-property-append round trip, this does not do it, and advertising a
target one cannot answer is the same class of defect as a device path with no
server behind it.

**The 64 KiB cap is the device's and is not widened here.** A larger X
selection is truncated at `SNARF_MAX` and **said so by size** — the same rule
`/dev/snarf` applies to a 70 000-byte write from a Hamnix program (§4). An
owner that answers with an **INCR** (incremental) transfer is **refused
loudly** and the Hamnix clipboard is **left alone**: a half-received INCR
stream is a corrupt paste, and the two clipboards genuinely differing is the
honest state to be in and to say.

### 6.3 Verification

`tests/linux/xsnarf_bridge.sh` — QEMU-free, **25 assertions, 25 PASS**. An
Xvfb and a few `xclip`s stand in for an X client in a namespace; the Hamnix
side is the *same two probes* `snarf_device.sh` uses —
`tests/linux/snarfcopy.ad` copying through `lib/hamtextbox.ad` (the editor /
Notes / URL-bar path) and `tests/linux/snarfpaste.ad` pasting through
`lib/htermsel.ad` (the grid terminal's path), in separate processes. So what is
asserted is **copy in one world, paste in the other, through the shipped
toolkit code**:

* both directions on **both** selections, and the two staying independent
  across a pull;
* a handover **between two other X clients** — the arm that fails if the XFixes
  watch is refused;
* **four rounds of ownership changing hands alternately**, with no loss of sync
  and no wedge;
* a 70 000-byte selection landing as exactly 65 536 with the drop named, and a
  2 MB one refused as INCR with the clipboard unchanged;
* **the X server killed and restarted underneath the bridge** — it redials and
  bridges the new one, still alive at the end. An Xwayland exits every time a
  distribution's X session ends, so this is the normal case, not the edge.

It runs in a private mount namespace with a **tmpfs over `/tmp`**, which makes
the display number and the X socket private: two agents running this at once
cannot collide on `:77`, and the host's real `/tmp` — 16 GB of somebody's RAM —
is never touched. `$HAMSNARF` is pinned per run for the reason
`docs/steam_namespace.md` §11 records. Nothing here touches the host's display:
Xvfb scans out to memory by definition.

**Xvfb, not Xwayland, and that is deliberate for this gate.** What the bridge
talks to is an X server over a unix socket at a path; Xwayland's difference —
that it is itself a Wayland client — is on the far side of the server, in the
pixels. Nothing in the selection protocol changes.

`tests/linux/xsnarf_ondevice.sh` — **8 assertions, 8 PASS, in the VM**, and
the assertion is a **mouse**. Offscreen proof is not on-device proof, and what
is only true on device is the boundary:

```
the namespace                    out here (root, the Hamnix side)
-----------------------------    -------------------------------------------
Xvfb :0                          /bin/xsnarfd /n/debian/tmp/.X11-unix/X0
  socket /tmp/.X11-unix/X0  <--- THE SAME INODE, by its other name
xterm, xdotool                   /dev/snarf, over /srv/snarf - which the
                                 namespace description does NOT bind in
```

A **triple-click** in a real Debian `xterm` makes xterm own `PRIMARY`, and
`cat /dev/snarf.primary` out here then prints the line that was on that xterm's
screen. A **middle-click** makes xterm ask the bridge for the bytes and feed
them to the shell it is running, which writes
`PASTED:[PASTE-ME-FROM-HAMNIX-9f3a]` to a file inside the namespace that this
side reads. Both are the ordinary X idiom, performed by a Debian binary that
has never heard of any of this. Also asserted: the bridge is started **before**
any X server exists and waits for it; a `CLIPBOARD` copy does not disturb
`PRIMARY`.

```
[xsnarfd debian] bridging /n/debian/tmp/.X11-unix/X0 <-> /dev/snarf
[xsnarfd debian] no X server at that socket yet; retrying every second
[xsnarfd debian] connected: root window 0x1293, resource base 0x4194304, max request 262140 bytes
[xsnarfd debian] X -> Hamnix: 24 bytes into /dev/snarf.primary
[xsnarfd debian] Hamnix -> X: owning PRIMARY with 26 bytes
[xsnarfd debian] Hamnix -> X: owning CLIPBOARD with 22 bytes
```

It plants nothing with `debugfs`: the rc and the two namespace-side scripts go
in as a **second cpio segment** and `HAMLINUX_DISTRO_RO=1` puts every guest
write in a throwaway overlay, so the shared distro media are never touched.

Three things that arm cost, kept because each is a trap for the next person:
`matchbox` **maximises** the window, so the `-geometry` asked for is not where
the text is — the first run triple-clicked a blank line and faithfully pulled
the one byte a blank line's selection is; the Debian medium has no
`xfonts-base`, so `xterm` needs `-fa/-fs` or it dies naming a font that is not
there; and a `sed` address whose marker contained a path reported **empty**
while the log plainly held the answer.

**The desktop still comes up with two bridges started at boot** —
`docs/screenshots/linux/clipboard-bridge-desktop.png`, a full VM boot with the
generated `/etc/rc.distros-wl` running a `wsyswl` *and* an `xsnarfd` per
distribution:

```
[rc.5] compositor started
[rc.5] desktop backdrop started
[rc.5] panel started
[rc.5] wayland server for debian
[rc.5] clipboard bridge for debian
[rc.5] wayland server for alpine
[rc.5] clipboard bridge for alpine
[rc.5] desktop up
```

`tests/linux/snarf_device.sh` is still **23/23** with `sys_unix_connect` added.

### 6.4 Two defects worth keeping written down

Both were found by measurement against a real X server, neither by reading.

1. **`XFixesSelectSelectionInput` is 16 bytes, length 4** — it was 20/5 for one
   run. It has no reply, so the only trace was the unmatched-error line
   printing `X error code 16 for request opcode 138`: BadLength. With the watch
   refused, the whole X → Hamnix direction was dead and nothing said so. That
   the bridge prints unmatched X errors *at all* is why this took minutes.
2. **The send-event bit.** An event a client *sent* (rather than one the server
   generated) arrives with the top bit of the type byte **set** — and
   `SendEvent` is how a selection owner answers `ConvertSelection`. So every
   `SelectionNotify` arrived as type 159, not 31, matched nothing, and was
   dropped: the Hamnix → X direction worked perfectly while X → Hamnix timed
   out three seconds at a time with no error anywhere.

### 6.5 What the bridge does not do

* **A change on the Hamnix side is noticed by CONTENT, not by a serial.**
  `struct snarfshm` has `magic` and `version` but no generation counter, so
  there is nothing cheap to compare and nothing to wait on. The bridge polls
  both buffers four times a second and compares bytes. That is correct — a
  change is a change — but it cannot tell "written again with the same bytes"
  from "not written", and it cannot wake instantly.
  **The request, precisely:** add `uint64_t serial;` to `struct snarfshm`
  (`user/linux-snarf.c`, the struct at line 127) and `(*serialp)++;` at the end
  of `hamsnarf_write` (line 289), beside the existing "the length is published
  last" store. The poll then compares one word, and a later `sys_waitfds` arm
  could park on the clipboard instead of polling it at all. That file is owned
  by another pass, so this is a request rather than a change.
* **INCR is refused, not received.** Receiving it is a `PropertyNotify` loop
  against `PropertyChangeMask` on the owner window; the 64 KiB cap means most
  of what arrives would be discarded anyway, which is why refusing loudly was
  chosen first.
* **No `TARGETS`-driven format negotiation for incoming content.** The bridge
  asks for `UTF8_STRING` and falls back to `STRING`. An owner offering only
  `COMPOUND_TEXT` or `text/plain;charset=utf-8` is refused, loudly.
* **No clipboard persistence after the owner exits.** When the last X owner
  disappears the bridge keeps the last content it saw rather than clearing —
  said on the log line, and the same choice every X clipboard manager makes.
* **Nothing bridges the Wayland side.** `wl_data_device` is a separate
  protocol; a Wayland-native client that never goes through Xwayland has a
  third clipboard. It is named here rather than implied to be covered.
