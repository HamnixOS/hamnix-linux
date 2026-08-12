# hamnix-linux changelog

Releases of the `linux` channel at <https://255.one/>. Install or update with:

    hpm refresh https://255.one/
    hpm install hamnix-base

Every entry here names what CHANGED for someone using the machine. Work that
was measured and deliberately NOT done is listed too, under "measured and
refused" — a thing this project treats as a result rather than an omission,
because the number is the deliverable.

---

## 1.0.10

The first release whose index is checked for dependency closure before it is
written (see "the channel refuses itself" below), and the first with a signed
trust root that has a matching secret key in existence.

### Desktop

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

- **Window title bars show no text.** Titles are stored and never painted.
- **The Applications menu spans the full display width**, with the right side
  blank instead of showing the desktop behind it.
- **The GPU stack has never been measured on real silicon.** The Vulkan
  userspace is real and `vkprobe` will report what an installed ICD
  enumerates, but on this build host every run has been software. Install a
  driver package and run `vkprobe`: it prints the device name or nothing, and
  there is no third answer that could be mistaken for success.
