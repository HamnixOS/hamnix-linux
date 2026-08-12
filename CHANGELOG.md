# hamnix-linux changelog

Releases of the `linux` channel at <https://255.one/>. Install or update with:

    hpm refresh https://255.one/
    hpm install hamnix-base

Every entry here names what CHANGED for someone using the machine. Work that
was measured and deliberately NOT done is listed too, under "measured and
refused" — a thing this project treats as a result rather than an omission,
because the number is the deliverable.

---

## Unreleased

Landed in the tree, NOT yet on an installed machine. This section exists
because of the invariant above: work that has landed but not shipped is
exactly the state in which "we fixed that" and "you have that fix" quietly
stop meaning the same thing, so the gap is written down rather than carried
in someone's head.

*(nothing right now — 1.0.12 carries everything that had landed.)*

## 1.0.12

**The first release the build refuses to publish unless the packaged binaries
run.** `tests/linux/channel_runs_desktop.sh` takes the built archives apart and
runs what is inside them — the desktop under a synthetic mouse, the shell, the
package manager, the coreutils checked on real answers rather than exit 0. It
compiles nothing it asserts on, and proves that by inspecting itself. The
packaging script will not write an index if it fails, so a channel whose
binaries do not work installs nowhere.

This exists because of 1.0.10 below, where every other check passed: the names
were all present, the hashes all matched the bytes served, the dependency
closure resolved. Nothing ran the binaries, because every test in this tree
builds from source — so the thing that shipped was the one thing nothing had
executed. 1.0.11 was checked this way by hand; from 1.0.12 the build enforces
it.

### Things that did not work at all, and now do

- **`modprobe` can resolve a module name.** No `modules.dep` was generated
  anywhere on this distribution, and `modprobe`'s default path pointed at
  `/lib/modules/modules.dep` — no kernel release in it, a path nothing has
  ever written, so the default could only ever fail. On a stock kernel every
  graphics, filesystem and network driver is a module, so on real hardware
  this was the difference between a working machine and a black screen.
  The table is now generated at image build time by running `depmod` over the
  staged tree — it reads the modules' own symbol tables, so it describes the
  modules this image *has* rather than the thousands the build host has. A
  driver package that arrives later by `hpm install` appends its own lines
  from its install hook, so a module installed after the image was built is
  resolvable too. Proved on a module with real dependencies, loaded leaf-first
  and verified out of the kernel's own list — not on a leaf, which would pass
  without a dependency table at all.
- **`passwd` could not change a password. For anyone. Ever.** The authentication
  device served no "set password" operation at all. It does now: `$6$` hashing
  with a 16-character random salt, written through a temporary file with the
  right mode, synced, and renamed into place, and permitted only for the host
  owner or for your own account. The result of a password change is kept
  separate from the result of an identity check, so one can never be mistaken
  for the other.
- **`lsmod` was a lie.** It printed one hard-coded fake row on every machine
  and exited 0. It is the tool you would use to check whether a `modprobe`
  worked, so it would have certified a `modprobe` that loaded nothing. It now
  reads the kernel's own list.
- **`pgrep` matched nothing, ever.** It opened a process-table file that
  exists on Hamnix's own kernel and not on Linux, so it failed for every
  pattern. Its output is now byte-identical to the standard `pgrep`.

### The shell silently wrote to the wrong file

- **A redirect whose target contained `+` was truncated at the `+`.**
  `echo X >> /path/a+b/f.txt` wrote to `/path/a`, left the named file
  untouched, passed the rest as an argument, and exited 0. The tokeniser
  splits a bare word at `+`; the argument path had rejoined those pieces for a
  long time and the four redirect-target sites had not. **Every Debian kernel
  release has a `+` in its name**, so this was every append into
  `/lib/modules/<release>/`.

### Measured, and not what anyone expected

- **50 of the run sweep's failures were one broken harness, not fifty broken
  programs.** The sweep's file-size limit was smaller than the window system's
  backbuffer pool, which is allocated lazily — so the compositor passed the
  readiness check and was killed by the kernel moments later, and every
  windowed program was scored against a window system that was no longer
  running. The score was **253/329**, not the 301 the docs claimed; it is now
  **306/329**. The limit is now derived from the source rather than written
  down, and the harness reports its OWN failure instead of blaming the
  program. 23 remain, each named with its reason, and nothing was
  reclassified to look healthier.
- **The 23 programs recorded as each burning a whole CPU core are fixed** —
  all 50 painting clients now measure 0.0 s of CPU across a 15-second run.
  This is the first sweep since the fix that could see it.

## 1.0.11

**Recovers a machine that took 1.0.10.** If you installed or updated to
1.0.10, `hpm update` brings the desktop back.

**Measured this release, and worth knowing before you judge what runs here:**
Steam, in a Debian namespace, is driven far past its login window. Typing puts
text in its username field and masks a password; hovering repaints the field;
"Create a Free Account" opens a second window carrying a live captcha; the
Browse menu drops down with store artwork; the real store front page loads;
dragging the scrollbar scrolls it; and a search for a game returns titles with
prices and cover art. Every one of those events entered through the same path
a person's mouse and keyboard use — no test wrote a window-system ring by
hand. What does NOT work is the scroll wheel (above). No Steam account was
used, so the library, downloads and launching a game remain unmeasured and are
not claimed.

1.0.10's bytes were deliberately left as published rather than corrected under
the same version number: a machine that already believes it has 1.0.10 would
never fetch a silently fixed one, so the fix has to arrive as a new version.

- **Clicking away dismisses an open menu.** The compositor emitted no focus
  lines at all, so no window was ever told it lost focus and the Applications
  menu closed only by clicking its button a second time. `f in`/`f out` now go
  out on the window's own event ring, in the reference implementation's order:
  the loser is told before the winner, and both before the pointer line for
  the very click that moved focus — so a client never sees the press before
  the message explaining it.
- **The clipboard stopped polling.** There was no way to ask "has the
  clipboard changed?", so both bridges re-read the entire clipboard four times
  a second forever and compared bytes. There is now a serial per buffer, and
  the file that reports it is a real kernel watch, so a bridge sleeps until
  something actually happens: **4.99 → 0.49 wakes/s** measured on the X
  bridge, by sampling voluntary context switches over a stated 10-second
  interval.
  The Wayland half was **measured and refused**: that compositor's loop runs
  at 16 ms for input regardless, so the serial saves it exactly zero wakes —
  0.04% of one core at the worst constructible clipboard size — while making a
  non-bumping writer take 2 s instead of 128 ms to be noticed. It still polls
  by content, with the table of numbers next to the code.
- **The scroll wheel exists.** `wsysd` had plumbed the whole wheel — the evdev
  event, the delta, the fifth field of the routed pointer line — and the
  Wayland server's pointer parser read four fields and stopped at the fifth.
  So every Wayland and X client behind this compositor has had a **dead scroll
  wheel for the entire life of the port**, Firefox included. `wl_pointer.axis`
  is now sent, and `axis_discrete` precedes it as the protocol requires.
  **The wheel now moves a real program's pixels in a real VM**, on the Xwayland
  this distribution actually ships: `tests/linux/vm_wheel_client.sh` scrolls an
  `xterm` in the Debian namespace 415 px up, 415 px back, net 0.
  **What it does NOT fix, stated rather than glossed:** Steam inside a
  distribution namespace still does not scroll, now across four full boots.
  That is no longer a mystery about this stack — in the fourth boot an `xterm`
  in the **same X session, the same minute**, given the identical wheel events,
  scrolled and scrolled back while Steam's store page changed **0 of 564400
  pixels**, with a scrollbar drag of that same page moving 84.43% of it as the
  control. The two candidates this entry used to name are both dead by
  measurement: the compositor's counter advances by exactly twenty for twenty
  notches with the cursor still, and Xwayland 22.1.9 and 24.1.6 behave
  identically on both the core and the XInput2 smooth-scroll paths. The fault
  is above the X server and it is Steam's own input handling.

## 1.0.10

> **BROKEN — do not install this version.** `hamnix-desktop` 1.0.10 shipped a
> mixed build: a compositor compiled at 19:17 beside desktop and panel clients
> compiled at 18:25, with the window-system backend all three link modified at
> 19:54. A machine that installs or updates to it comes up with a desktop that
> maps **no windows at all**. Update to 1.0.11, which recovers it.
>
> The cause was an object cache that compared each artefact only against its
> own `.ad` source, so an edit to a shared library or backend invalidated
> nothing. Fixed, and the gate described under Unreleased now runs the
> packaged binaries before any index is written.

The first release whose index is checked for dependency closure before it is
written (see "the channel refuses itself" below), and the first with a signed
trust root that has a matching secret key in existence.

### Desktop

- **THE DESKTOP CAN BE CLICKED WITH A MOUSE.** It could not, at all, before
  this release. The compositor delivered pointer events to one ring and the
  panel and desktop read a different ring that nothing ever filled, so a real
  click on the Applications menu or a desktop icon did nothing whatever. It
  survived unnoticed because every test in the tree wrote that ring by hand as
  the host owner — the gate that proves it now drives synthetic evdev instead,
  and asserts about itself that it never pokes a ring.
  A second defect was found in the same place: the compositor drained every
  pending input record before routing once per frame, so a move/press/release
  arriving together collapsed into a lone release and the PRESS was never
  delivered at all.
- **Windows have their names on their title bars.** Titles were stored and
  never painted, so several open windows were indistinguishable. Long titles
  are ellipsised, under two independent bounds: the measurement decides where
  text is cut, and the surface rasterized into decides where ink can reach.
  A client can set any title it likes and cannot escape its band or inject a
  drawing command — but it CAN lie about which window is which, which needs a
  per-uid window table to fix and is recorded rather than glossed.
- **Windows can be closed with the mouse.** The close button ASKS the client
  to close rather than destroying its window underneath it, so a program gets
  to decide what happens to unsaved work.
- **The Applications dropdown no longer paints a black band.** The band was
  three separate silent layers agreeing on the wrong answer, not one bug.
- **Keyed and blended windows work.** Transparency was silently dropped in
  THREE places between a client asking for it and the compositor drawing it;
  all three now carry it, and it is stated as a scene-window property rather
  than re-derived per layer.
- **The paint pool is no longer a ceiling.** Windows past the pool's capacity
  used to fail to get a buffer; the pool grows.
- **A coverage guard** now exists (`hamui_host_uncovered_rows()`): a window
  that paints fewer pixels than it owns can be caught by name instead of by
  someone noticing a black rectangle in a screenshot.

### X and Wayland clients

- **The connection ceiling is 16, up from 8, and the window table is 256.**
  Firefox alone opened 8 connections, so a browser exhausted the compositor by
  itself and a namespace's Xwayland arriving next lost a whole program, not a
  window. Firefox's 8 was confirmed to be its true appetite rather than a
  truncation: rebuilt with room for 32, it still opens exactly 8, with one tab
  and with ten. The cost is honest and worth knowing — the window segment is
  resident, not sparse, so it grew from 9.15 MiB to **18.17 MiB always
  resident**. Two browsers still do not fit (18 > 16); that is the next
  ceiling and it is named rather than hidden.
  Three latent defects turned up while raising it, all the same shape — a
  ceiling written down twice: a fixed 16-entry wait array with no bound check
  that the new limit would have overrun on every pass of the event loop; a
  listen backlog left as a literal 8; and a refusal message staged into a
  buffer that held another client's pending file descriptor, which would have
  handed a real client's keymap to the program being turned away.
- **Being turned away says so.** A refused connection used to close the socket,
  and the program printed `No wl_shm global` — blaming a feature that is
  present. It now gets a named protocol error built from the actual limit.
- **Rootless Xwayland**: an X window from a distribution namespace is a window
  ON THE DESKTOP, alongside native ones, not a client on a separate bare
  compositor. Firefox and Steam both render.
- **EWMH**: X clients can now tell there is a window manager on the screen,
  which is what several toolkits check before drawing anything at all.
- **A close button an X client understands**, and an X client that knows where
  its window actually is on screen.

### Clipboard

- **Three clipboards, two bridges.** Native `/dev/snarf`, X, and Wayland now
  share one clipboard. The Wayland side was previously a handshake with
  nothing behind it — a protocol conversation that completed successfully and
  transferred no data.
- A 64 KiB clipboard payload is asserted to survive the round trip intact.

### Shell

- **`` `{ … } `` of a builtin now captures its output.** It used to run the
  builtin to find out whether it was a builtin — so the answer arrived after
  the output had already gone to the console.
- **The `-` stdin sentinel is gone from 47 recipe rows**, and the loader now
  rejects a blank or bare `-` argument column BY ROW NAME instead of passing a
  literal `-` to the program. Four commands, including `md5sum`, were failing
  with `cannot open -` because of it.

### Honesty fixes

- **`hello` proves what it claims.** `/version` did not exist and the read sat
  behind a bare success check, so the program whose entire purpose is proving
  the VFS path printed a banner and exited 0 having proved nothing. It now
  fails by name, loudly, when it cannot read `/version`.
- **The channel refuses itself when it is incomplete.** Publishing now
  resolves every declared dependency against the packages actually in the
  index and REFUSES to write an index with a dangling one. A build that
  silently dropped the compositor previously produced a channel whose
  flagship `hamnix-base` package could not install — and said `done`. That
  failure had to reach a user's prompt to be visible; now it stops here.
- The packaging script no longer advertises a `--sign` flag it never had.

### Under it

- **The native lane links again**, with two syscalls deliberately returning
  −1 rather than a plausible-looking value.
- **Pipe EOF**: the keeper lifetime bug that could leave a pipe's read end
  waiting on a writer that was already gone.
- The backbuffer segment's fd is close-on-exec.

### Measured and refused

- **The 20 ms cap on a mixed wait set.** Measured at 59.7 vs 20.0 wakes/s;
  one wake costs 3.9 µs, so the cap costs **40 extra wakes/s = 0.016% of one
  core**, for one program, while it is open. The fix would put a permanent
  helper thread and a hand-rolled wake protocol on the KEYSTROKE path — the
  same path whose latency was a visible half-second echo lag. Not worth it.
  The number is recorded next to the cap so it does not get re-derived.

### Known broken

See `HANDOFF.md` for the full list, which is kept honest rather than short.
The ones most likely to be noticed:

- **Clicking away does not dismiss an open menu.** The compositor emits no
  focus lines at all, so a window is never told it lost focus; the
  Applications menu closes only if you click its button a second time.
- **Two browsers at once still do not fit** in the 16-connection ceiling.
- **The GPU stack has never been measured on real silicon.** The Vulkan
  userspace is real and `vkprobe` will report what an installed ICD
  enumerates, but on this build host every run has been software. Install a
  driver package and run `vkprobe`: it prints the device name or nothing, and
  there is no third answer that could be mistaken for success.
