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

## 1.0.10

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
