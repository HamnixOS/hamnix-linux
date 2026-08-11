# HANDOFF — porting the Hamnix userland to the Linux kernel

You are starting with no context. Read `NORTH_STAR.md` for what this is FOR,
then this file for where it stands, then `README.md`.

---

## 0. Where this stands

> This section is the current state. Sections 1–8 below are the ORIGINAL
> handoff, written from static analysis before any of it was run; several of
> their claims have since been measured, corrected or answered outright, and
> where that has happened it is marked in place. Read this first and treat the
> rest as history plus reference.

**hamnix-linux boots to a desktop, installs itself, updates from 255.one, and
compiles Adder on the box.** Concretely, all of the following are measured
rather than argued:

| | |
|--|--|
| Boot | Linux kernel → `user/linuxinit.ad` (the Adder PID 1) → namespace via `sys_bind` → `hamsh` → the rc scripts |
| Installed boot | UEFI → a unified kernel image on an ESP → PID 1 → `bind '#sysroot' /` → the real ext4 root. Files written on one boot are there on the next. |
| Display | `/dev/fb` on fbdev AND on raw DRM/KMS, double-buffered with `MODE_PAGE_FLIP` — 481 flips, `stalled=0`. `flip` is a `/dev/fbctl` verb; double buffering arms lazily, so a program that never flips runs the old path untouched. |
| Windows | `/dev/wsys`, the port of `devwsys.ad`, in shared memory. Both protocols: the v1 scene display list and the v2 blit surface, plus the `'I'` named-image tier (a scene client can draw a real photograph without converting its window to a blit surface). The screen size is published at `/dev/wsys/screen`. |
| Compositor | `user/wsysd.ad`. A 1724-op frame at 1280×800 costs **625 µs**, down from 5503; a pointer-only frame costs **5 µs**, down from 6543. Pixel-identical to the pre-optimisation code at three geometries. |
| Input | every `/dev/input/event*`, decoded in the compositor, routed to the focused window in window-local coordinates |
| Desktop | `hamdesktop` + `hampanelscene`, unmodified. Launch a terminal from the menu, type in it, get output. |
| Session | `login` → `/dev/auth` (real `/etc/shadow` + `crypt_r`) → `setuid 1001`. The session is unprivileged; the compositor and chrome are not. |
| Access control | devwsys's uid gate is ported: `live` cannot drive system-chrome ctl verbs, and can still map and draw its own window. `tests/linux/wsys_uidgate.sh`. The chrome state lives in a SECOND segment, `/srv/wsys.chrome`, 0644 and host-owner-owned, so for chrome the file mode is the gate and the kernel enforces it against programs that skip the protocol. `tests/linux/wsys_bypass.sh`. |
| Networking | `/net` as a file tree, TCP/UDP/ICMP, TLS, `announce`/`accept` across process boundaries, and DHCP (`user/dhcpc.ad`) |
| Packages | `hpm` installs the whole distribution from `https://255.one/linux/` over TLS, including replacing `/bin/hamsh` while it is PID 1. **The update loop is proven end to end**: install at 1.0.2 from the live repo, a newer build lands, `hpm update`, the upgraded binary still runs. No re-image anywhere in it. |
| Wayland | `user/wsyswl.ad`, a Wayland compositor in Adder. Firefox runs as a native Wayland client with its menus as separate windows; XWayland carries X11 clients. |
| Windows *inside* a namespace | `jwm`, the same one and the same configuration (`etc/jwmrc.linux` → `/etc/jwm/hamnix.jwmrc`) in Debian and Alpine. Reparenting, a real title bar, 66 `_NET_SUPPORTED` atoms, `_NET_WORKAREA` the full screen, no D-Bus and no settings daemon. `xdotool` move and resize both take effect and the client stays `IsViewable`, for `xterm` and for Firefox; **Steam's `Sign in to Steam` is `IsViewable` at 700x440+290+180 and in `_NET_CLIENT_LIST`** where matchbox left it `IsUnMapped`. It costs **0.5 MiB and one new package** in Debian (Firefox had already installed all sixteen of its dependencies) and **+28.5 MiB** in the *graphical* Alpine image, measured by building it both ways; `HAMLINUX_ALPINE_GUI=0` is still 26 MiB. `docs/linux_window_manager.md` has the table for every candidate, including why openbox — the most EWMH-complete of them — costs 57.9 MiB here, and why **rootless Xwayland** is the better long-term answer and its own piece of work. |
| Shared fate between clients | **Measured, and the received answer was wrong.** `windows_high_water 1` said a rootful X session is one surface, and §8 concluded rootless would give each X toplevel its own limits. It would not: `MAXMAP`, `MAXOBJ`, the frame-callback slice and the window budget are per **connection**, and **Xwayland opens exactly one connection rootful or rootless** — measured both ways, `conns 1` each. Rootless would also make the mapping table *grow* with window count where rootful holds it at 2 for any number of X clients (8 X windows, all resizing: still 2), and it would hit `BB_SLOTS = 8` — the whole system's v2 backbuffer pool, one slot per X toplevel instead of one per X session. What was actually shared and should not have been is now fixed in `user/wsyswl.ad`: the frame-callback table was ONE table of 64 for every client (a client taking the last slot silenced everyone else's initial-draw callback), `MAXWIN` was 12 for the whole server, and `MAXCONN` was 4 — fewer than two namespaces plus Firefox plus the chrome. Now `FCPERCONN`/`WINPERCONN` partitioned per connection with `MAXWIN >= MAXCONN * WINPERCONN` checked as arithmetic by the test, and `MAXCONN` 8. `tests/linux/wsyswl_shared_fate.sh` (18 PASS) and `docs/linux_window_manager.md` §8a. |
| Debian | `enter debian { sh }` — bookworm on its own filesystem, amd64+i386. Works **from a uid-1001 desktop terminal**, and something inside can build a container (`bwrap --unshare-user`). The root switch is `MS_MOVE` + `chroot`, what `switch_root(8)` does: `pivot_root` returns EINVAL on an initramfs boot's unattached `rootfs`. `glxgears:i386` renders on the Hamnix desktop through XWayland → `wsyswl` → `wsysd` → `/dev/fb`. |
| Distributions | **Two, at once, on the live boot AND on an installed disk.** `#distro/<name>` is a parameterised subtree server; `/etc/distros` maps a name to a medium **by ext4 volume label**, so which disk is `/dev/vda` cannot silently decide which distribution you entered. `enter alpine { … }` (musl, 3.24.1) and `enter debian { … }` (glibc, 12.15) both work in ONE boot from the console AND as uid 1001 — `tests/linux/two_namespaces.sh`, with a negative control that `/etc/alpine-release` is invisible inside Debian. An unprivileged process cannot open a block device to read a label, so `bind` falls back to the mount point the boot already posted the server at: **the name is what crosses the privilege boundary.** Alpine costs **26 MiB** without graphics, 333 MiB with; Debian is 4.5 GiB. Each has its own section in the DE application menu, named for it, driven from `/etc/distros` rather than from a compiled-in path. `etc/rc.boot.installed` sources the same generated `/etc/rc.distros` the live boot does, so `enter alpine` and `enter debian` survive a reboot into an installed system -- `tests/linux/installed_distros.sh`, the boot nobody had ever run. `docs/linux_distro_namespaces.md`. |
| Audio | `/dev/audio`, `/dev/audioctl`, `/dev/audioin` on intel-hda, ported from Hamnix's `audio_cdev.ad` + `hda.ad`. Proven by FFT on a WAV captured out of QEMU: 1000.28 Hz, 444.57 Hz and a 660.90 Hz sine, right durations, square-wave harmonics. `arecord` delivers 97.4% of a 48 kHz stereo second. |
| Shutdown | **An installed machine can be turned off, and the filesystems are flushed on the way down.** `/dev/reboot` is served (`user/linux-syscalls.c`), ported from Hamnix's `DEV_REBOOT` cdev with its protocol intact — first token, three verbs `poweroff` / `reboot` / `halt`, reads are EOF. A recognised verb is `sync(2)` then `reboot(2)`. Until this landed nothing served the name, so `reboot`, `poweroff`, `halt` and `init 0` / `init 6` all died on the open and **every restart of an installed machine was the equivalent of pulling the plug** — it survived only because ext4 has a journal. An installed disk now writes to `/etc` and reboots **in the same breath with no sleep**, and the next boot is running the rc the last one wrote: `tests/linux/reboot_device.sh`, 37 PASS, `reboot: Restarting system` in 13 s and `reboot: Power down` in 11 s. `poweroff` and `halt` were not in the image at all and now are. uid 1001 gets EPERM and every client reports it **by name**; the desktop's Power Off works because `hamsessui` is spawned by the root chrome. `docs/linux_installed_update.md` §2c. |
| Compiler | `ac foo.ad -o foo` on the box: `host_ac` natively, then clang inside the Debian namespace. |
| GPU | The Vulkan userspace (loader + venus/ANV/NVK/RADV/lavapipe) installs into the **Hamnix root** by hpm — no namespace entry. `vk_core` has a real Vulkan backend (`lib/vk/vk_linux.ad` + `user/linux-vk.c`), byte-identical to the software rasterizer, armed by default on real silicon. |
| Build | **Every application in `user/` builds through the LLVM lane** — 363 of 363, with 4 of the 367 files being LIBRARY MODULES that have no `main` and are not applications. `scripts/hamlinux_sweep.sh` computes and prints that headline next to its own definition; nothing is hand-derived. `scripts/hamlinux_build.sh` knows the per-program extra objects (`wsysd` needs the Vulkan shim), so every build path links, not just the image's. |

That number used to read "359 of 367", with the eight shortfalls grouped as
four `*_host.ad` harnesses importing kernel source that is not in this
repository, three libraries with no `main`, and **one that genuinely bailed the
backend's SSA subset (`hambrowse_tabs`)**. That grouping was made by reading.
Re-measured by running, `docs/linux_build_count.md`:

* **Nothing bails the SSA subset, and nothing ever did.** `hambrowse_tabs` is a
  fourth LIBRARY, imported by `hambrowse` and `hambrowse_gfx_window`. It emits
  `funcs=28 emitted=28 bailed=0` and then printed "body bailed the SSA subset"
  because `hamlinux_build.sh` inferred a cause it had not checked: it looked
  for `@main` in the IR and, on not finding one, asserted a bail. A file with
  no `def main` was never going to emit one. That is now a distinct exit code
  (13, "no `def main`: a library module") and every `user/*.ad` in the tree
  reports `bailed=0`.
* **The four harnesses now build and RUN**, asserting 64 things about this
  tree's own `lib/htermsel.ad` and `lib/hamtextbox.ad`. The import they needed
  was pure — two byte buffers with an offset-addressed read/write surface — so
  it was ported rather than excluded: `lib/devsnarf.ad`. Four dead
  `ci_battery_manifest.txt` entries are alive again with it.
* **367 is files, not applications.** Four of them are libraries. The
  denominator is 363, the numerator is 363, and the sweep now prints both with
  their definition rather than leaving a number to be quoted into a commit
  message.

The clipboard finding that fell out of it is in the HONESTLY BROKEN list below.

### What is HONESTLY BROKEN right now

Kept here deliberately, because a handoff that lists only successes is the
same failure this project exists to beat.

* **The Hamnix clipboard and the namespace clipboard are two clipboards.**
  `/dev/snarf` is served (`user/linux-snarf.c`; `tests/linux/snarf_device.sh`
  23/23), so copy and paste work between Hamnix programs. A Debian or Alpine
  binary gets ENOENT on it — measured, and the same answer `/dev/wsys` and
  `/net` give. Bridging needs a process that OWNS an X selection and mirrors it
  both ways, reacting to ownership changes on each side; half of that is worse
  than none. Two further gaps: no locking, so two simultaneous copies
  interleave; and **no end-to-end mouse test** — a drag-select in one DE window
  pasted into another — because the click derivation was never ported from the
  Hamnix line, where that exact gap once let nine green gates sit on a dead
  feature.
* **The Debian namespace's D-Bus has no SERVICES** (the bus itself now works).
  The namespace's `/run` is on
  the ext4 and survives reboots, so the first boot's `dbus-daemon` left
  `/run/dbus/system_bus_socket` behind and the session's `[ ! -S … ]` guard
  then skipped starting the bus on every boot after; every CEF process logged
  `Connection refused` against it. The stale socket is now detected by pid
  liveness and cleared by name (`tests/linux/hamnix_x11session.sh`).
  **Now fixed and measured:** started as
  `dbus-daemon --system --nofork --print-address &`, the bus comes up,
  `/run/dbus/pid` names a live process, and `dbus-send --system … GetId`
  returns a real reply from inside the namespace. (`dbus-send` IS in the
  image — the comment that said otherwise was wrong.) **And it now comes up
  for the SESSION USER, not only for root** — that was the other half of this,
  and it was blocked by `/run/dbus` being root-owned, not by anything about
  dbus: see the fourth-fault entry below. What remains absent are
  SERVICES on the bus, which CEF names itself:
  `org.freedesktop.UPower … was not provided by any .service files`.
* **One thing is still Debian-shaped. Two were, and are not any more.**
  (1) **DONE — the DE application menu carries N distributions.**
  `user/hampanelscene.ad` no longer holds a literal
  `/n/linux/usr/share/applications` and one "Linux" section: the scan is driven
  by `/etc/distros`, one section per distribution actually attached under `/n`,
  named after it. Screenshots:
  `docs/screenshots/linux/distro-menu-{debian,alpine}.png`; gate
  `tests/linux/distro_menu.sh`, which drives the menu open with synthetic
  pointer events and reads the panel's DISPLAY LIST back per fly-out (Debian's
  `Install Steam` must be drawn under the first section and NOT under the
  second — one list drawn twice would pass a screenshot and fails this).
  Making a dead path live found four things that were already broken and said
  nothing: the boot rc bound the distributions AFTER starting the panel that
  scans them; the Applications button was pointed at `/bin/hamappmenu`, which
  this line does not build, so it spawned a missing program and printed a
  launch; `sub_open` is one global while `menu_open` is per panel, so the
  bottom taskbar closed the top panel's fly-out on any pointer event; and
  Alpine's only `.desktop` file is `NoDisplay=true`, so its section could only
  ever have been empty. `docs/linux_distro_namespaces.md` §8.
  (2) **DONE, and `user/install.ad` was the wrong file.** `.hamnix-roots` is
  read by the HAMNIX KERNEL; nothing on this line reads it — `#sysroot` is a
  device from the command line and `bind` mounts it. An installed
  hamnix-linux disk gets its distributions from the same two labelled
  filesystems the live boot uses, so it needed no second subtree and no
  sentinel line. What it needed was for `etc/rc.boot.installed` to do what the
  live rc does, and that file had **no distribution bind and no `ns clean { }`
  template in it at all**: `enter debian { sh }` on an installed system
  answered `not a namespace template`. The subsystem worked on every boot that
  is thrown away and none that persist. Both rcs now `source` a generated
  `/etc/rc.distros`; `HAMLINUX_DISK_RC` gives an installed disk the hook it
  never had, which is why it was the one boot never under test. Gate:
  `tests/linux/installed_distros.sh`, 12 PASS — UEFI boot of a real installed
  disk, both namespaces, both uids, negative control.
  `docs/linux_distro_namespaces.md` §9.
  (3) `tests/linux/hamnix_x11session.sh` is Debian's session script; Alpine's
  is a separate one baked into its image, and the two share their two
  hardest-won lines by copy. Worth merging when there is a third.
  `docs/linux_distro_namespaces.md` §7.
* **THE FOURTH FAULT OF THAT FAMILY IS FIXED, and it took the unprivileged
  half of the D-Bus gap with it. `$XDG_RUNTIME_DIR` is now `/run/user/1001`,
  0700, owned by the session user.** §8.5 named three — a mount point in the
  medium (`/n`), a stale X lock in its `/tmp`, a socket in its `/run` — each
  created by root when root was its only user, each invisible to the
  unprivileged session that came later. The fourth was the *directory* the
  third lives in: `/run` `40755` uid 0 on both media, so the session could
  **read** what `wsyswl` publishes (the socket at 0666, `hamnix-screen` at
  0644) and **create nothing**. Root now stages `/run/user/1001` at
  `bind '#distro/<name>' /n/<name>` — the same call, the same moment and the
  file next door to where the *first* fault of this family was fixed
  (`user/linux-syscalls.c`, `distro_stage_runtime` beside
  `distro_stage_mountpoints`). Narrower than the `/run` it replaces, not wider.
  **Nothing moved on disk**, which is what made it affordable: five files name
  the socket by its `/run` path and every one of them needed **no change**,
  because the three names `wsyswl` publishes are *symlinked* into the new
  directory (`../../wayland-0` &c.) and `connect(2)`, `[ -S ]` and `read` all
  follow symlinks — so `wl_display_connect(NULL)`'s
  `$XDG_RUNTIME_DIR/wayland-0` resolves for a client that has never heard of
  `/run/wayland-0`. `wsyswl` itself is untouched. **The system bus is a
  separate answer and the distinction matters**: `/run/dbus/system_bus_socket`
  is a *compile-time* path in dbus that no environment variable moves, so
  `/run/user/<uid>` alone fixes the session bus and dconf and nothing else.
  Nothing here starts the system bus as root — `hamnix-x11session` runs
  `dbus-daemon --system` itself as uid 1001 — so the same staging **chowns**
  `/run/dbus` and `/run/dconf` to the session user with their **modes
  untouched**: a transfer, not a share, since a distribution namespace has one
  session user. Measured, one boot, `tests/linux/distro_menu.sh` 0 FAIL:
  `runtime dir /run/user/1001 is WRITABLE by uid 1001: created …probe.226`,
  `(drwx------ 2 live live /run/user/1001)`,
  `system bus live on /run/dbus/system_bus_socket (pid 262)`,
  `system bus ANSWERED GetId` — where the previous boot had
  `system_bus_socket': Permission denied` and `WARNING no system bus`. The
  witness in `/etc/de-ns-run` is `ls -lL` now, not `ls -l`: the gated fact is
  the mode of the thing `connect(2)` opens and the path is a symlink, and it
  *probes by creating a file* rather than by reading a mode bit, because this
  whole family is the mode bits reading correctly while the effective answer
  is still no. Gate: `tests/linux/session_runtime_dir.sh`, **8 PASS 0 FAIL** —
  its own file rather than a corner of `distro_menu.sh`, because a permission
  fact that can only be measured by first standing up a compositor, an X server
  and a window manager is a fact nobody will re-measure; this one needs none of
  them. `docs/linux_distro_namespaces.md` §8.6.
  The `/tmp` half of it was already fixed: the generated `/etc/rc.distros`
  clears root-owned `*.log` / `*.err` left in a distribution's sticky `/tmp` by
  a root-run session, by class rather than by a list of three literal names.
* **The GPU backend has never been measured on a real GPU.** It is proven
  correct and proven to install; every microsecond quoted anywhere is
  lavapipe's, where it is 2.3–2.9× *slower* than the hand-tuned software
  rasterizer, which is why the default is gated on the device being silicon.
  venus does not come up on this dev host (the NVIDIA driver's GBM backend
  cannot create a device; wants `nvidia-drm.modeset=1` and a reboot).
* **The wsys window table is still world-writable, though the chrome is not.**
  `/dev/wsys` was one 0666 segment, so a program that mmapped `/srv/wsys`
  directly bypassed the uid gate entirely — measured: as uid 1001 it
  overwrote the `lock` chrome sink and the protocol read the new value back.
  The chrome now lives in a second segment, `/srv/wsys.chrome`, 0644 and owned
  by the host owner, so the same program is refused by the KERNEL (`open`
  `O_RDWR` → EACCES, no `PROT_WRITE|MAP_SHARED`, `mprotect` refused) while
  still reading it PROT_READ, which is what keeps the session sighted.
  `tests/linux/wsys_bypass.sh`. What remains open is the window table, which
  must stay 0666 or an unprivileged client cannot map its own window: a
  bypasser can still retitle another client's window or scribble its scene.
  Closing that needs a mapping per owner-uid or the table behind an RPC to
  wsysd — a different change, and the test asserts the hole so it cannot be
  forgotten.
* **~~`hamscene_image` renders a hole, on every image in the system.`~~ FIXED.**
  The `'I'` named-image upload is ported: devwsys's #128 scene image tier — 16
  slots, 256×256, 31-byte names, keyed by (owning wid, name), replace on
  re-upload, **refusal not eviction** at the cap — in a fourth shared segment
  `<seg>.img`, 0666 and derived from the segment `shm_attach` actually joined.
  It is on the world-writable side because the verb's gate is owner-or-host
  (the rule THE SPLIT states), and the case against is argued in the file
  rather than skipped. Three refusals answer three errnos where devwsys folds
  them into one: EMSGSIZE, ENOSPC, EINVAL.
  The compositor is a user process here, not the kernel, so the store is read
  back through files — `<wid>/draw/images` and `<wid>/draw/image/<name>` — and
  cached on a per-image SERIAL, so a video re-uploading 256 KiB a tick costs
  one small text read per unchanged frame. `<wid>/ctl` grows a twelfth field,
  `image_gen`, because a re-uploaded image leaves the scene text byte-identical
  and a compositor watching `scene_gen` alone freezes the picture on frame one.
  `lib/hamui_host.ad`'s silent `slot < 0 → return 1` now records the NAME and
  returns *not handled*; `user/wsysd.ad` reports one line per (window, name),
  once ever.
  **Two more defects fell out of it, both of the same silent-success family:**
  opening `draw/ctl` for writing used to flip the window to protocol 2, so an
  `'I'`-only scene client got a blank backbuffer painted over a correct scene
  (the opt-in is now the first `'B'`/`'D'`); and `background`/`pin` was never
  ported, so `hamdesktop`'s full-screen backdrop kept `z 6` and was painted
  OVER every ordinary client window — a desktop with wallpaper, icons, a panel
  and not one application window, with every return code 0.
  **Measured**: `tests/linux/wsys_image.sh` (8 PASS) reads the framebuffer and
  checks the pattern at natural size and through the scaler, because "every
  layer returned success" is exactly what this defect looked like for the whole
  port. All three callers verified —
  `docs/screenshots/linux/wsys-image-on-desktop.png` (hamimgscene composited
  over hamdesktop's backdrop), `wsys-image-video.png` (hamvideocore's `"frame"`,
  advancing), `wsys-image-hamsdl.png` (hamGame presents its ENTIRE surface as
  one named image, so for a hamSDL game the missing verb was the whole frame).
  Regressions re-run: `wsys_uidgate` PASS, `wsys_bypass` PASS, `wsyswl_stall`
  11, `wsyswl_shared_fate` 18, `x11_geom_probe` 9.
  **What is NOT settled**: launched from the VM's root console with
  `hamimgscene &`, the window does not appear on the booted desktop, though the
  identical composition works offscreen with the same three programs. Not
  diagnosed; the leading suspicion is that a backgrounded `hamsh` job does not
  share `/srv` with the session, which would give it a private window system —
  the failure shape `shm_attach` already names. It is a launch/namespace
  question, not an image one.
* **The 4-stream software mixer is not ported.** An ALSA hardware substream
  has one writer, so `stream`/`mixplay` return `-EINVAL` and
  `user/audiolife.ad` will not do here what it does on Hamnix. The status
  line's `streams 100 100 100 100` is a placeholder. Capture *content* is
  also unverifiable in an automated run — QEMU's only host-free input backend
  is silence — and the card is not ready for ~2 s after boot.
* The run-sweep score is **261 healthy / 325 runnable**, and it is now a
  MEASURED number rather than a floor: the full sweep was re-run end to end
  under the 12 s GUI timeout, so the ~85 unre-measured GUI rows are settled
  and `wakelat_echo` and `hamgame_mixer_demo` are examined. The score the
  sweep prints is also the score it computes — `summary.txt` has a `headline`
  block with the definition beside it (`healthy = RAN + DREW_WINDOW +
  STAYS_UP + EXPECTED_FAIL`; `runnable` = rows minus NOT_SMOKE_TESTABLE minus
  BUILD_FAIL), because the previous figure was derived by hand into a commit
  message and its denominator was simply wrong.
  **The measured baseline before this pass was 249 / 325**, not 249/323: the
  healthy count was right, the denominator was not, and one program
  (`arecord`) has been added to `user/` since. `+12`, reconciling exactly:
  five rows are the harness no longer calling a correct program broken
  (`false`, `cmp`, `diff`, `tty`, `kill` — a non-zero exit that IS the answer
  is now `EXPECTED_FAIL`); three are a recipe bug (`mktemp`, `route`, `pr`
  were being handed a literal `-` argument borrowed from the stdin column);
  three are timeouts that were killing bounded programs a second before they
  printed (`nice_lo`, `wakelat_hog`, `preempt_hog`); two are `SILENT_OK` rows
  that now report what they did (`hamgame_mixer_demo`, `hamnotify`); one is a
  real crash fixed (`hxd`); and **two go the other way for the right reason**
  — `login` and, through it, `getty`, which used to exit 0 when the login
  prompt hit end-of-input, reporting a session that was never established.
  Zero `SILENT_OK`, zero `EMPTY_EFFECT`, zero `CRASH` remain. The two
  remaining `TIMEOUT`s (`wakelat`, `sysirqprobe`) both print a named FAIL
  about `/proc/self/ctl` before they run long, so they are honest.
  Both `results.tsv` files are kept, under
  `/home/david/.hamnix-build/sweep-a4b04e0f/{BASELINE,AFTER}-preserved/` —
  **not** `/tmp`, which is a 16 GB tmpfs and is where a previous pass's
  baseline went during a disk-full cleanup, leaving its before/after resting
  on a figure it had not measured.

#### Solved, kept because the shape is the lesson

These are FIXED and measured. They stay because each is a worked example of
the failure this project keeps having — an answer shaped like success — and
the shape is more reusable than the fix. They are NOT open work.

* **The environment DOES cross `enter`; the drop is an `exec` one level up.**
  §8.5 recorded, unmeasured, that `enter` against an `ns clean { }` template
  rforks with `RFCNAMEG` and so "the environment does not appear to cross".
  The observation was right and the mechanism was wrong, which matters because
  the two boundaries are fixed in different places. `tests/linux/enter_env.sh`
  asks them separately with sentinel values no default in the tree produces:
  `rfork(RFPROC|RFCNAMEG)` is a process **fork** and `RFCNAMEG` empties the
  Pgrp — the mount table — not the address space, and `hamsh`'s exported
  variables are ordinary BSS arrays that the fork copies. But a **fresh
  `hamsh`** seeds its mirror with exactly `PATH` and `HOME` and never reads
  the inherited `environ`, so anything an ancestor exported dies at the `exec`
  into `/bin/hamsh /etc/rc.de-ns/<name> <prog>` — which is precisely how the DE
  panel spawns the launcher, and where `HAMNIX_DE_XSESSION` went. Consequence:
  the `HOME` / `XDG_RUNTIME_DIR` / `WAYLAND_DISPLAY` / `XDG_CONFIG_HOME`
  exports at the bottom of `/etc/rc.de-ns/<name>` **do** reach the client (they
  are set in the same shell that then enters), and `HAMNIX_DE_XSESSION` can
  never be steered from an outer shell no matter what is done to `enter`.
* **(SOLVED — kept because the shape is the lesson) Steam's login window is on
  the Hamnix desktop.** `build/steamprobe/steam_login_maxmap64.png`. It was
  `MAXMAP`: `wsyswl` gave each connection **16** wl_shm mappings and Steam's X
  session holds **26**. Past 16, `map_alloc` returned -1 and `commit_buffer`
  dropped every frame at `mi < 0` — and a rootful Xwayland is ONE
  `wl_surface`, so one exhausted table froze the entire X session, which is
  why the control `xterm` and Steam's window were never two problems. Two
  boots of the same image differing only in that number:
  `map_alloc_failed 10 / drop_no_mapping 508 / commits 3` and a black screen,
  against `maps_high_water 26 / every drop 0 / commits 506` and the login
  dialog (`build/steamprobe/steam_black_maxmap16.png` is the control).
  **The lesson, which is this project's own:** the answer was in the third
  suspect list, and it took three passes because a compositor that drops a
  frame said nothing. Every silent `return` in `commit_buffer` is now counted
  by reason, named once on stderr, and published as `wsyswl-state` beside the
  Wayland socket — the one directory that spans the namespace boundary, so
  `cat /run/wsyswl-state` answers from either side, like
  `/dev/wsys/wsysd/state` before it. `MAXOBJ` went 256 → 1024 in the same
  pass (nothing hit it: `max_object_id 97`).
  A SECOND fault of the same class was found and fixed on the way, in
  `user/linux-wsys.c`: a v2 window's backbuffer slot carries its own `w/h`,
  the client writes rows at THAT width and `user/wsysd.ad` re-rows them at the
  WINDOW's width, and nothing checked the two agreed — a stale slot inherited
  by wid from a dead process put the whole X screen on the scanout as two
  half-height copies side by side. `tests/linux/wsyswl_stall.sh` reproduces
  both offscreen in three minutes with no VM and no Steam, and plants the
  stride mismatch by hand as a negative control.
  What the same two boots also retired, and is worth keeping in one
  place: **matchbox** was why every Steam window read `IsUnMapped`,
  and the **system D-Bus** comes up and answers `GetId`. The session
  no longer starts matchbox; it starts `jwm` (see the table above and
  `docs/linux_window_manager.md`), under which `Sign in to Steam` is
  `IsViewable` at `700x440+290+180` **and** in `_NET_CLIENT_LIST`. Both halves
  were needed and neither was sufficient: the window has to be mapped *and*
  the frames have to be delivered. With a window manager in the session the
  same run reads `maps_high_water 31`, five above Steam's own 26 and twice the
  old limit — and `windows_high_water 1`, which is the whole rootful-Xwayland
  shared-fate problem stated as a number.
* **(historical, kept for the shape)** It installs, brings up
  pressure-vessel, and Chromium loads to `SteamApp Init - Before Login`.
  What that is NOT, now measured rather than guessed (`docs/steam_namespace.md`
  §6.1): the `(-2147483648, …)` in the CEF log is not our stack answering a
  geometry query with a sentinel — the X screen is a real 1280x800 at 96 dpi,
  `matchbox` is managing and publishes `_NET_WORKAREA = 0,0,1280,800`, and a
  real Chromium — which is what CEF is — maps a window through Xwayland →
  wsyswl → wsysd and gets its pixels onto the framebuffer. The window path is
  not the problem.
  Nor is it CEF's GPU process, which does exit twice per launch
  (`viz_main_impl.cc(166)`): run with Steam's own `-cef-disable-gpu
  -cef-disable-gpu-compositing`, those errors stop and the window tree is
  unchanged.
  What it IS: every window Steam creates it leaves **`IsUnMapped`** — the UI is
  alive behind them (the login page runs and polls), and even the *launcher's*
  `Show window`, which happens before CEF exists, puts no pixels on a
  framebuffer sampled once a second across the three seconds it is up.
  The next measurements are named in `docs/steam_namespace.md` §6.3 and none of
  them is blocked: trace the X protocol for a `MapWindow`, run the session with
  no window manager, and read what `dbus-daemon` is actually complaining about.
  Its probe is 23 PASS / 1 FAIL (the remaining one is the PulseAudio socket).
* **The image build could drop a program and still say `done`.** Fixed in this
  pass, and listed because the shape recurs: `scripts/hamlinux_image.sh` kept
  its own copy of wsysd's extra objects after 6a27c0ec moved them into
  `scripts/hamlinux_build.sh`, so the compositor failed to link, was printed in
  the same list as two programs that have no source, and the initramfs shipped
  with **no compositor at all** — booting to a black screen while rc.5 printed
  `compositor started`. Failed links are now named separately, with their build
  logs, and wsysd/hamsh/hamdesktop/hampanelscene failing to build exits 1.
* **(SOLVED — kept because the shape is the lesson) Launching an app from the
  distribution fly-out.** This entry used to say the FIRST bind of the
  template, the root switch, failed ENOENT, that the identical lines worked
  from a console shell, and that it was therefore "something about this
  SPAWNED shell's namespace". Three shapes of the launcher rc and three passes
  over the spawn gate and `rfork` went into that, and **nobody had ever asked
  which bind failed** — because `hamsh` answered with a fixed sentence naming
  a fixed suspect (`needs CAP_SYS_ADMIN … uid 1001`) for a failure that was
  ENOENT, not EPERM. The error message was the thing answering something
  success-shaped.
  It is the **LAST** bind, `#/` onto `/n`, with the root switch already
  succeeded. `enter <name>` binds /dev, /proc, /srv and /n INTO the
  distribution's own root, a bind whose target directory does not exist fails
  ENOENT, and the session user cannot create one — the distribution's `/` is
  uid 0 and **uid 0 is not mapped into the user namespace `ns_privilege()`
  acquires**, so CAP_DAC_OVERRIDE does not reach it. Those directories had
  only ever existed as a side effect of somebody running `enter <name>` AS
  ROOT on a WRITABLE medium, where `enter_root`'s own ignored `mkdir`
  succeeded: `debugfs -R 'ls -l /'` finds `n` in `distro.ext4` and not in
  `alpine.ext4`. The console and the desktop terminal "worked" because their
  tests run a root `enter` first, in the same boot.
  They are now made deliberately, by root, when the boot posts the server at
  its name (`user/linux-syscalls.c`, `distro_stage_mountpoints`), and a medium
  that refuses says so then rather than at launch. `hamsh` names the failing
  bind, its target and the kernel's own reason (`_ns_apply_failed`).
  Underneath it was a second gap: a `.desktop` names an **X11 client** and
  nothing in the namespace served X, so `etc/de-ns-run.linux` — copied into
  each tree at boot — now gives a menu-launched program a display, delegating
  to the distribution's own `hamnix-x11session` where there is one.
  `docs/linux_distro_namespaces.md` §8.4, `tests/linux/distro_menu.sh` (which
  now clicks a row and screendumps what comes up).
* **(SOLVED) A menu-launched app reached its namespace and could not reach the
  DISPLAY.** The click worked, the namespace worked, the application started —
  and Xwayland, as uid 1001 inside the namespace, could not `connect(2)` to
  `/run/wayland-0`: `/etc/rc.distros-wl` starts the per-distribution `wsyswl`
  **as root**, `bind(2)` creates a unix socket 0777 masked by the umask (022),
  so it came out `srwxr-xr-x` — owner-writable only, owner not even mapped into
  the entering process's user namespace (`nobody nogroup`). Nothing had hit it
  because every previous GUI-in-a-namespace run (`steam_gui_run.sh`,
  `alpine_gui_run.sh`) ran its client as ROOT.
  **`user/wsyswl.ad` now `sys_chmod`s its own socket 0666 at creation** — the
  server knows its own path (it is `argv[1]`), so the mode is set in the one
  place a caller cannot forget, and a failed `chmod` is named on stderr. This
  is the same 0666, for the same reason, as `/srv/wsys` (`user/linux-wsys.c`,
  THE SPLIT; `ad440707`): what a connection buys is a Wayland *client* session,
  and `wsyswl` issues no gated verb on a client's behalf — `newwindow` is
  devwsys's explicit pre-gate exception and the `<wid>/ctl` verbs it drives are
  on windows it owns. The access control is the path, as with every Wayland
  compositor: the socket is inside ONE distribution's `/run`.
  Starting `wsyswl` as the session user was considered and rejected, and the
  reason previously given for rejecting it was wrong in both halves: it does
  not need `/dev/fb` (that is `wsysd`; `wsyswl` is a *client* of `/dev/wsys`)
  and the uid gate does not block it either. What blocks it is that the
  distribution's `/run` is root-owned 0755, so a uid-1001 `wsyswl` could not
  create the socket there at all — it moves root-prepared state rather than
  removing it, and widens the blast radius from one socket to a directory.
  **Measured**: `tests/linux/distro_menu.sh` reports "launched" and "got a
  display" as two facts and both are now PASS, with the socket's mode gated
  separately (`srw-rw-rw-`, logged by the shim from *inside* the namespace);
  `build/distromenu/shot-launched.png` is `uxterm`, launched from the DE
  application menu, running in the Debian namespace on the Hamnix desktop.
  `docs/linux_distro_namespaces.md` §8.5.
* **(FIXED — same defect as the `hamscene_image` entry above; kept for the
  detail of how it was found)**
  The `/dev/wsys/<wid>/draw/ctl` `'I'` verb was never ported, so
  `hamscene_image` renders nothing on this line.** Found by tracing
  `hamimgscene`, which was exiting 2 in total silence. `user/linux-wsys.c`
  implements the blit protocol's `'B'`, `'D'` and `'C'` and dropped devwsys's
  named image upload; with no store behind it, `lib/hamui_host.ad`'s
  rasterizer takes its `slot < 0 → return 1` path and draws a hole without
  complaining. That reaches `user/hamimgscene.ad`, `lib/hamvideocore.ad`
  (the `"frame"` image a video player blits) and `lib/hamsdl.ad`. It now
  answers **ENOSYS by name** — distinct from the `EINVAL` it gives real
  garbage — and `hamimgscene` prints the whole explanation and exits 2.
  Closing it needs a named-image table in the shared segment plus `wsysd`
  registering from it; not attempted here. **That is exactly what was then
  done** — see the entry above for the shape it took and for the two further
  defects the end-to-end measurement turned up.

### What answered the original open questions

* **§3, the `/net` design.** Answered: a file tree, in shared memory. §3.3
  identified the constraint correctly — a connection must be addressable by
  integer across process boundaries — and that is exactly why a shim was the
  wrong answer. The connection TABLE is shared, so the NUMBER means the same
  thing everywhere; the socket rides across `fork`, which covers
  `httpd` → `httpd_worker`. `user/linux-net.c`.
* **§7.1, cross-process fd addressing.** Answered the same way, and it is the
  same problem: a pipe slot is a FIFO, the bindings are shared, and `/fd/<n>`
  resolves per-process. `user/linux-fdns.c`.
* **§4.4, the compositor.** Answered: `/dev/wsys` is shared memory (a faithful
  port of a KERNEL device, which is what `devwsys.ad` is), and the RASTERIZER
  moved to userland as an ordinary Adder program, `user/wsysd.ad`. It reuses
  `lib/hamui_host.ad` unchanged — that module was written as a host-test sink
  and turns out to be a compositor. §4.4's "DRM master is exclusive" blocker
  dissolved when fbdev turned out to be both the right analogue and not
  master-exclusive.

### The one thing to carry forward

Every serious bug on this line has had the same shape: **a gap that answers
something success-shaped instead of the truth.** Not a crash, not an error — a
plausible wrong answer. The list, because the pattern is more useful than any
single entry:

* `sys_chan_dir_mode` stubbed → `cp -r` created a file containing a directory
  listing and exited 0.
* `sys_get_jiffies` returning 0 → `sleep 1` hung for ever.
* `#d` bound to a real `/proc/self/fd` → every spawned program's output went to
  a read-only stdout and vanished; the program ran and exited 0.
* `dup2` of a synthetic device fd → `echo x > /dev/wsys/appmenu/launch`
  reported success and the queue stayed empty.
* `sys_openchan` fail-closed → EVERY shell redirect created its file, wrote
  nothing to it, and printed to the console.
* `sys_waitpid_nb_raw` returning waitpid(2)'s 0 for a live child → the DE
  terminal decided its shell had died the instant it started.
* `sys_read_nb` leaving `O_NONBLOCK` set → the next blocking read returned
  EAGAIN, which `hamsh` read as end-of-input and exited.
* `ps` printing a kernel banner and exiting 0, because `/proc/tasks` is
  Hamnix's process list and does not exist on Linux.
* `hpm install a b c` silently dropping `b` and `c`; and a fresh install
  arriving non-executable, hidden because overwriting an existing binary
  inherits its mode.
* Six syscalls with **no body at all** in the hosted lane — `sys_mount`,
  `sys_nslabel`, `sys_srv_open`, `sys_fdslot_arg`, `sys_svc_publish`,
  `sys_svc_ctl` fell through an `#ifndef ADDER_HOSTED` block that is compiled
  out here, ran off the end of `.text`, and executed arbitrary bytes. `hamsh`
  — PID 1 — calls all six, one of them on every `enter`. It mostly got away
  with it, which is the worst available failure mode.
* Every DE client defaulting to 800×600 because `/dev/wsys` recorded the
  screen size in fields nothing could read back, so each one opened `/dev/fb`
  privately — which can never work while the compositor holds DRM master.
  `hamlock` did it at 1024×768, covering 53% of a 1080p display: a lock
  screen that has not locked anything.
* `enter debian { steam }` from a desktop terminal running a Hamnix binary in
  the NATIVE root and exiting 0.
* `login` returning 0 when the login prompt hit end-of-input — `getty` EXECS
  it, so login's status IS the VT session's status, and a supervisor could
  not tell "logged in and out again" from "nobody ever typed a name".
* `hxd` looping for ever because its hex-byte loop was missing `b = b + 1`.
  The symptom was not a wrong dump: it wrote three bytes per iteration
  through the end of a 128-byte row buffer, over `page_len`, `file_size` and
  `top`, and on until it walked off `.bss` — a SIGSEGV whose cause was four
  frames and a whole BSS away from the missing line.
* `shm_attach` using `O_RDWR|O_CREAT` → `fs.protected_regular` refuses
  `O_CREAT` on a file you do not own in a sticky directory, so an
  unprivileged client silently created its own private window system and drew
  into a screen nobody composites.
* `background 1` — the verb `hamdesktop` sends to pin its backdrop — not
  ported, and an unknown ctl verb is IGNORED, so the backdrop kept
  `lib/hamui.ad`'s default `z 6` and the compositor, which paints z ascending,
  painted an opaque full-screen backdrop over every application window. A
  desktop with wallpaper, icons and a panel and NOT ONE application, every
  return code 0, and the taskbar still listing the windows it was covering
  (ea23c834).
* A window whose owner had exited or crashed **stayed on the screen for ever**
  — an opaque rectangle no click could reach, still listed in the taskbar,
  because `/dev/wsys` is shared memory with no fid table and nothing ever
  freed a window its owner had not freed by hand. Nothing in `lib/hamui.ad`
  ever does, so a NORMAL exit leaked one too (165195bc).

None of these failed loudly. Three were found only by tracing, one only by
running `strace` **as PID 1**, and one only after publishing the compositor's
own state as a file (`/dev/wsys/wsysd/state`) so it could be `cat`-ed from
inside a misbehaving desktop. When something here does not work, assume a call
is lying before you assume it is broken.

### The gate the last two of those got

`tests/linux/wsys_desktop_z.sh` composites **the real desktop** — `wsysd` +
`hamdesktop` + `hampanelscene` + application windows, offscreen through
`HAMFB_FILE` — and reads the answer out of the framebuffer. It exists because
nothing did: `wsys_image.sh` passes with the `background`/`pin` fix reverted,
because it never runs `hamdesktop`, and every other gate composites ONE client,
or reads the window table, or asks a layer whether it succeeded.

Six assertions, each of a z-order RELATIONSHIP rather than a fixed coordinate:
the application's rectangle is the application's pixels; the backdrop is below
the lowest z a window can *ask* for; the panel stays over a window that
overlaps it; a click on the desktop does not bury the application; a raise
brings an occluded window to the front; a closed window's pixels leave the
screen. Each client paints one flat colour, so "which of these two windows owns
this region" has an arithmetic answer.

**Both arms are measured, and the first version of assertion 2 had no teeth.**
With `ea23c834`'s hunk reverted the gate reports 9 PASS / 3 FAIL and exits 1;
with it in, 12 PASS / 0 FAIL. "The application is over the backdrop" on its own
passes in BOTH arms — the unpinned backdrop keeps `win_alloc`'s default z 5,
already below an ordinary window's 6 — which is written into the file rather
than glossed, because a gate that passes either way is what this line already
had. The last assertion found 165195bc on its first run.

### Running it

```
scripts/hamlinux_image.sh          # initramfs + kernel
scripts/hamlinux_vm.sh gpu         # boot it with a display
scripts/hamlinux_disk.sh           # an INSTALLED disk (GPT + ESP + ext4)
scripts/hamlinux_vm.sh disk-gpu    # boot the installed disk through UEFI
scripts/hamlinux_distro.sh         # the Debian namespace (Firefox lives here)
scripts/hamlinux_alpine.sh         # the Alpine namespace (HAMLINUX_ALPINE_GUI=0 for 26 MiB)
scripts/hamlinux_packages.py       # build the `linux` hpm channel
scripts/hamlinux_shot.sh out.png   # boot and screendump in one command
tests/linux/*.sh, tests/linux/*_probe.ad
```

Host packages this needs, beyond the original list: `mmdebstrap`,
`dosfstools`, `e2fsprogs`, `gdisk`, `parted`, `mtools`, `systemd-boot-efi`,
`ovmf`, `socat`.

---

## 1. What Hamnix is, and why this repo exists

Hamnix 1.0 is a from-scratch x86_64 operating system written entirely in
**Adder**, a Python-shaped systems language with a hand-written x86_64 backend
and a self-hosted compiler. There are **zero lines of C in the kernel**. Its
syscall layer is Plan 9-shaped rather than POSIX-shaped: resources are file
trees, not syscall families. Networking is `/net`, windows are `/dev/wsys`,
processes assemble their own private namespaces with `bind`. A Linux ABI shim
lets real Debian binaries run in a Linux namespace alongside it. It is released,
tagged `v1.0`, and published at 255.one.

The purity is the point, and it is also the ceiling: Hamnix must write every
driver itself. No Wi-Fi, no GPU, no modern browser, not for years.

This repository is the second line. Same Adder userland, running on the **Linux
kernel with glibc**, so that drivers, Wi-Fi, GPU and a real browser come for
free. Hamnix 1.0 keeps its version number and its purity claim; this is a
sibling, not a successor — Debian GNU/Hurd to Debian, not Debian 12 to Debian 11.

**Your job is the port. Nothing here compiles yet, by design.** The code was
copied across unchanged so the port stays a reviewable diff.

---

## 2. What was copied, and what was left behind

Copied from `HamnixOS/Hamnix` with `git-filter-repo`, full history preserved
(3,789 commits), original paths kept verbatim so patches cherry-pick cleanly
between the two repos:

| Path | Contents |
|--|--|
| `user/` | 277 applications (~180k lines) incl. `hamsh.ad` (17.6k lines), `hamUId.ad` (31.2k, the compositor), `hpm.ad` (8.2k, package manager); plus `linux-runtime.S`, `runtime.S`, `syscall_nums.h`, `*.lds` |
| `lib/` | 167 modules (~162k lines): `hamui.ad` toolkit, `web/` (42 files — a from-scratch HTML/CSS/JS engine), `vk/` (Vulkan), codecs, crypto |
| `scripts/` | 1,811 files of build and test glue |
| `tests/` | 162 entries of fixtures and gates |
| `docs/` | 188 design documents |
| `etc/`, `fonts/`, `Sounds/`, `examples/` | userland data |

**Deliberately left behind** (they are Hamnix 1.0's, and are what Linux
replaces):

`kernel/`, `arch/`, `mm/`, `fs/`, `drivers/`, `sys/` (the Plan 9 device
drivers — `sys/src/9/port/dev*.ad`), `linux_abi/`, `net/`, `init/`, `mod/`,
`kernel-modules/`, and the built `.img` artifacts.

Two of those you will need to *read* constantly, from the Hamnix repo, because
they are the specification for the file servers you must reimplement:

- **`drivers/net/devnet.ad`** — the `/net` file tree.
- **`sys/src/9/port/devwsys.ad`** — the `/dev/wsys` window file server.

The Adder compiler is **not** copied; it is a submodule at `adder/`
(see README).

### Already true, and better than you would expect

Three things are already done, and they change the shape of the job:

1. **`--target=x86_64-linux` is a working compiler target.** It emits a static,
   no-libc Linux ELF. It is used every day for host-side testing.
2. **`user/linux-runtime.S`** (543 lines) is a Linux link runtime mapping
   `sys_*` onto real Linux syscalls. About 31 entry points are genuinely
   implemented.
3. **84 `*_host.ad` harnesses already run parts of this userland on Linux**, and
   `scripts/net9_host_shim.c` (13.5 KB) is a **working `/net` file-server shim
   backed by real Linux sockets and OpenSSL**. `user/net9_host.ad` fetches a
   live HTTPS page through completely unmodified `http9.ad` + `net9.ad`. The
   central architectural question of this port already has a working prototype
   in-tree. See §3.

---

## 3. The `/net` problem

> **ANSWERED 2026-08-09 — see §0.** `/net` is a file tree served out of shared
> memory (`user/linux-net.c`). §3.3's constraint is exactly why: a connection
> number has to mean the same thing in two processes, so the TABLE is shared
> and the number is what crosses. TCP, UDP, ICMP, `announce`/`accept`, and TLS
> via the `tls <host>` ctl verb. Measured: `curl https://255.one/` and `hpm`
> installing 61 packages, both unmodified.


Hamnix has **no BSD socket syscalls at all**. `SYS_SOCKET`, `CONNECT`,
`BIND_SOCK`, `LISTEN_SOCK`, `ACCEPT_SOCK` and `SYS_TLS_CONNECT` were all
retired. TCP, UDP, ICMP and TLS are a **file tree**. On Linux that tree has to
become a userspace file server — 9p, FUSE, or a shim library that intercepts the
`sys_open`/`sys_read`/`sys_write` entry points. This section is the inventory
that lets you choose; it does not choose for you.

### 3.1 The good news: it funnels through one file

`user/net9.ad` (~450 lines) is the sole client-side implementation of the `/net`
dance. Almost every network consumer goes through it, and treats the result as
an ordinary stream fd.

```
user/net9.ad
  ├── user/http9.ad   (HTTP/1.1 + chunked + TLS over net9)
  │     ├── user/curl.ad, user/wget.ad, user/hpm.ad
  │     ├── user/hambrowse.ad + hambrowse_{host,probe_host,sdl_host}.ad
  │     ├── lib/htmlengine.ad, lib/httpchunk.ad
  │     └── lib/web/{css/cascade,dom/canvas,js/api,js/state,js/consts}.ad
  │         lib/web/js/builtins/{fetch,xhr}.ad
  ├── user/sshd.ad, user/ssh.ad
  ├── user/httpd.ad, user/httpd_worker.ad, user/u_server.ad
  ├── user/ping.ad, user/u_tlstest.ad
  └── user/x11/{x11srv,xclient_demo,xfill}.ad
```

`user/ntpd.ad` is the **one bypass**: it opens `/net/udp/...` directly and does
not use `net9.ad`.

### 3.2 Every `/net` path literal in the copied tree

Exhaustive. There are eleven.

> **VERIFIED — accurate, every entry, including the line numbers.** A sweep for
> `"/net/...` string literals across `user/` and `lib/` returns exactly these
> eleven paths at exactly these lines. The only additional hits are
> documentation strings inside comments (`"/net/tcp/<N>/<leaf>"` and friends at
> `net9.ad:40,78,96,159` and `ntpd.ad:55,100`), which are format templates, not
> paths. Nothing here needs correcting.

| File:line | Literal | Purpose |
|--|--|--|
| `user/net9.ad:151` | `/net/tcp/clone` | `net_dial` |
| `user/net9.ad:220` | `/net/tcp/clone` | `net_dial_tls` |
| `user/net9.ad:291` | `/net/tcp/clone` | `net_announce` (listen) |
| `user/net9.ad:79` | `/net/tcp/` prefix | builds `/net/tcp/<N>/<leaf>` |
| `user/net9.ad:442` | `/net/icmp/clone` | `ping` |
| `user/net9.ad:102` | `/net/icmp/` prefix | builds `/net/icmp/<N>/<leaf>` |
| `user/ntpd.ad:216` | `/net/udp/clone` | NTP, bypasses net9 |
| `user/ntpd.ad:101` | `/net/udp/` prefix | builds `/net/udp/<N>/<leaf>` |
| `user/hampanel.ad:429` | `/net/ipifc/ctl` | panel link-status read |
| `user/haminstallui.ad:382` | `/net/ipifc/ctl` | installer link-status read |
| `user/hamUId.ad:21967` | `/net/addr` | compositor reads the host address |

### 3.3 Every operation performed on the tree

**Connection lifecycle (TCP).** `net_dial` at `user/net9.ad:139`:

1. `sys_open("/net/tcp/clone")` → read back an ASCII decimal connection number
   `N` (parser at `user/net9.ad:118`).
2. `sys_open_write("/net/tcp/<N>/ctl")` → write `connect <a.b.c.d>!<port>`.
3. `sys_open_write("/net/tcp/<N>/data")` → this fd **is** the stream.
4. Close `clone` and `ctl`. The `data` fd alone holds the connection open;
   `sys_close` on it sends FIN.

**TLS.** `net_dial_tls` at `user/net9.ad:200` does the same, then additionally
writes `tls <hostname>` to `ctl`. That runs a **TLS 1.3 handshake inside the
kernel**; afterwards the `data` fd is transparently encrypted/decrypted by the
kernel record layer. There is no userspace TLS state machine to reuse — on Linux
this must become OpenSSL/rustls somewhere, and the `ctl` verb has to drive it.
The 253-byte SNI hostname is why `net9.ad`'s command buffer is 320 bytes.

**Listening.** `net_announce` at `user/net9.ad:285` writes `announce <port>` to
`ctl`. `net_accept` (`:329`) and `net_accept_conn` (`:367`) write `accept` and
read a new connection number. `net_open_conn_data` (`:407`) opens
`/net/tcp/<conn>/data` for a connection accepted by another process — this is
how `user/httpd.ad` hands work to `user/httpd_worker.ad`, and it means **a
connection must be addressable across process boundaries by integer**. A shim
library holding per-process socket state cannot express this; a real file server
can. This is the single sharpest constraint on your design choice.

**ICMP.** `user/net9.ad:417` onward. `/net/icmp/clone`, then
`connect <a.b.c.d>` or `connect <a.b.c.d>!<id>` (RFC 792 identifier, *not* a
port), then a `data` fd plus a separately-reopened `status` fd read once per
ping for a fresh snapshot.

**UDP.** `user/ntpd.ad:210`. `/net/udp/clone` → `connect <a.b.c.d>!123` →
`data`, write 48-byte NTPv3 request, read reply.

**Observed ctl verbs, complete:** `connect <ip>!<port>`, `connect <ip>`,
`connect <ip>!<id>`, `announce <port>`, `accept`, `tls <host>`, `hangup`.

**Interface configuration** is *not* on the file tree — it is a syscall,
`sys_netcfg(op, a1, a2)`, with ops 0=read config, 1=set addr/mask, 2=set
gateway, 3=set DNS, 5=enumerate routes. Callers: `user/ifconfig.ad:145,284,297,310`,
`user/route.ad:130,191,195,246`, `user/hamctl.ad`.

**DNS** is also a syscall, not a file: `sys_resolve(hostname, len) -> int64`
returning a packed big-endian IPv4. Callers: `user/http9.ad:306`,
`user/ntpd.ad:182`, `user/ping.ad:181`, `user/host.ad:140`. Plus
`sys_resolve_ptr` (reverse) used once.

### 3.4 The prototype that already exists

`scripts/net9_host_shim.c` implements exactly this contract on Linux today. It
interposes `sys_open` / `sys_open_write` / `sys_read` / `sys_write` /
`sys_close`, hands back synthetic fds above a fixed base for `/net/*` paths,
passes everything else through to the real Linux calls, parses the `ctl` verbs
(`ctl_command`, `:199`), and backs them with real sockets and OpenSSL. It also
implements `sys_resolve` over `getaddrinfo` (`:339`).

It is a **shim library**, which is the third of your three options — and it is
already known to work for the client path end-to-end against live HTTPS sites.
What it does *not* do is `announce`/`accept` across process boundaries
(§3.3), which is the case that argues for a real file server. Read it before
you decide; do not assume it settles the question.

---

## 4. Every other native-only surface

### 4.1 The syscall gap, exactly

> **VERIFIED 2026-08-09, with one class substantially wrong.** The headline
> counts hold exactly: userland declares **71** distinct `sys_*` entry points
> (`extern def` across `user/` and `lib/`), `user/linux-runtime.S` defines
> **49**, **23** are missing, and **18** share the fail-closed body. Class (a)
> below did not survive contact: it claimed ~31 genuinely implemented, and only
> **20** actually issue a syscall. Corrected in place.
>
> Much of this section has since been *closed* rather than merely corrected —
> see §4.1d.

`user/linux-runtime.S` is the Linux link runtime. Userland declares **71**
distinct `sys_*` entry points; the runtime defines **49**. Classifying every
definition body in that file:

**(a) Genuinely implemented — 20, not 31.** `sys_read`, `sys_write`,
`sys_open`, `sys_open3`, `sys_open_write`, `sys_close`, `sys_lseek`,
`sys_mkdir`, `sys_unlink`, `sys_dup`, `sys_dup2`, `sys_getcwd`, `sys_chdir`,
`sys_getuid`, `sys_yield`, `sys_setpgid`, `sys_mmap`, `sys_munmap`,
`sys_read_nb`, `sys_exit`.

**(a2) Return a constant, doing nothing — 3.** `sys_errstr` (always writes the
empty string), `sys_nsid` (0), `sys_get_jiffies` (0). These link and "succeed",
which is worse than failing: `sys_errstr` is why every diagnostic in the tree
printed `cannot open X: ` with nothing after the colon.

**(a3) Listed above as implemented, but actually `return -1` — 8.** `sys_rfork`,
`sys_execve_env`, `sys_fdbind`, `sys_chan_dir_mode`, `sys_listdir_records`,
`sys_stat_p9`, `sys_resolve`, `sys_fdslot_kind`.

**`sys_rfork` is the one that matters.** §8's step 2 — "add `sys_waitpid` and
`sys_tcsetpgrp`, get `hamsh` running" — could not have worked as written:
reaping a child is useless while the call that *creates* the child fails. The
real fail-closed count was 26 (18 + these 8), not 18.

**(b) Present but fail-closed — `return -1` (18).** These are the Plan 9
surface, and they are the port. `user/linux-runtime.S:484` onward:

> `sys_bind`, `sys_mount`, `sys_unmount`, `sys_nslabel`, `sys_srv_open`,
> `sys_openchan`, `sys_pipechan`, `sys_fdslot_arg`, `sys_svc_publish`,
> `sys_svc_ctl`, `sys_setuid`, `sys_setuid_auth`, `sys_pgrp_kill`,
> `sys_tcsetpgrp`, `sys_waitpid`, `sys_waitpid_jc`, `sys_waitpid_nb_raw`,
> `sys_waitfds`

Note `sys_waitpid` and `sys_tcsetpgrp` in that list: **`hamsh` cannot reap a
child or run job control on Linux today.** Those two are cheap (`wait4`,
`tcsetpgrp`) and unblock the shell. Do them first.

**(c) Declared by userland, absent from the runtime entirely — these are link
errors, not stubs (23).**

> `sys_execve`, `sys_pipe`, `sys_getpid`, `sys_getgid`, `sys_link`,
> `sys_symlink`, `sys_clock_gettime`, `sys_socketpair`, `sys_netcfg`,
> `sys_resolve_ptr`, `sys_rfork_thread`, `sys_semacquire`, `sys_semrelease`,
> `sys_setexitsem`, `sys_set_realtime`, `sys_srv_post`, `sys_useradd_root`,
> `sys_wsys_alloc`, `sys_wsys_free`, `sys_vk_window_frame`,
> `sys_umdf_mmio_map`, `sys_umdf_irq_open`, `sys_umdf_dma_alloc`

Most of class (c) is trivially POSIX (`execve`, `pipe2`, `getpid`, `getgid`,
`link`, `symlink`, `clock_gettime`, `socketpair`). The `sys_umdf_*` three are
userspace-driver MMIO/IRQ/DMA and should simply be **deleted** on this line —
Linux owns the hardware. `sys_wsys_*` and `sys_vk_window_frame` belong to §4.4.

### 4.1d What is now implemented — `user/linux-syscalls.c`

The gap above is largely **closed**. `user/linux-syscalls.c` is the *hosted*
half of the Linux link runtime: compiled only into the glibc lane, with the
overlapping `.S` definitions guarded out by `-DADDER_HOSTED`. The freestanding
lane is untouched and still assembles.

Implemented and demonstrated by **running programs**, not by linking:

| Group | Entry points |
|--|--|
| fork / exec / reap | `sys_rfork` (fork(2)), `sys_execve`, `sys_execve_env`, `sys_waitpid`, `sys_waitpid_jc`, `sys_waitpid_nb_raw`, `sys_tcsetpgrp`, `sys_pgrp_kill`, `sys_setuid` |
| POSIX gap (§4.1c) | `sys_getpid`, `sys_getgid`, `sys_pipe`, `sys_socketpair`, `sys_link`, `sys_symlink`, `sys_clock_gettime`, `sys_set_realtime` |
| resolver | `sys_resolve` (getaddrinfo), `sys_resolve_ptr` (getnameinfo) |
| namespace | `sys_bind` — accepts `#c → /dev` and `#d → /fd`, fails the rest (§4.2) |
| event loop | `sys_waitfds` (poll(2)) |
| diagnostics | `sys_errstr` — now `strerror_r` on `errno` |
| stat | `sys_stat_p9` (full 9P2000 record), `sys_chan_dir_mode` (compact Dir records) |
| time | `sys_get_jiffies` — CLOCK_MONOTONIC at 100 Hz |

Two things only *running* the code revealed:

1. **The `.S` wrappers return `-errno`, and never set `errno`.** Measured:
   `sys_open("/no/such")` returns `-2`, `sys_open("/etc/shadow")` returns `-13`.
   So `sys_errstr` had nothing to report. The hosted file/fd definitions
   reproduce the `-errno` return *exactly* — anything decoding it is unaffected
   — and additionally set `errno`.

2. **`ls` built, linked, ran, and failed.** `lib/p9.ad`'s `p9_listdir` `read(2)`s
   a directory fd expecting Hamnix's `"NAME\n"` stream; Linux answers `EISDIR`.
   `sys_open` now notices a directory and `sys_read` synthesises that stream from
   `readdir`, so no userland changes. `ls` output is byte-identical to `ls -A`.
   **`.` and `..` are deliberately omitted**: `du`, `find`, `cp` and the other
   `p9_listdir` recursors have no self/parent guard anywhere in the tree and
   would loop forever otherwise. That absence is also the evidence that the
   Hamnix backing does not emit them.

`sys_stat_p9` is the **only reliable file-vs-directory test in the tree** —
`user/find.ad`'s header explains why (bug #146) a `p9_listdir` success cannot
substitute. Note the trap: it is the **full 9P2000 stat record**, *not* the
compact Dir record `lib/p9.ad`'s own header documents. `lib/p9.ad:1095` flags
the difference; consumers pin `qid.type` at byte 8 and `length` at byte 33.

### The stub policy is the biggest risk this port has

Bigger than `/net`, and it is not the risk §7 names. **A fail-closed stub that
returns a success-shaped wrong answer is worse than no implementation at all**,
and this tree has already produced silent data loss from one.

`sys_chan_dir_mode` is the case study. `user/cp.ad:163` and `user/tar.ad`
implement "is this a directory?" as `open(p); p9_chan_dir_mode(fd,1,p) == 0`.
While that returned −1, every directory looked like a regular file — and
`cp -r src dst` **did not fail**. It created `dst` as a plain file containing
the bytes of `src`'s listing and **exited 0**. Nothing in the exit status,
stderr, or an `strace` flagged it; only diffing the output caught it. Six apps
were quietly wrong the same way (`cp`, `tar`, `tree`, `stat`, `hdu`, `hamfm`).

Two compounding lessons:

- **Making a read succeed can make a failure silent.** The directory-read
  synthesis (§4.1d) fixed `ls` — and simultaneously converted `cp -r` from a
  loud read error into silent destruction. A fix that unblocks one caller can
  arm another. The pair had to land together.
- **`sys_get_jiffies` returning a frozen 0 is the same design error with a
  kinder symptom.** Nine apps hung instead of corrupting anything, which is how
  it got noticed. That is luck, not design.

Both are now implemented — `sys_chan_dir_mode` answers the predicate *and*
re-renders the stream as compact Dir records so `ls -l` is right too, and
`sys_get_jiffies` is `CLOCK_MONOTONIC` in centiseconds. `cp -r` copies real
trees; `sleep 1` takes one second.

**The rule for whoever adds the next stub:** it must fail in a way the caller
cannot mistake for a valid answer. Prefer a hard error to a plausible constant,
and before stubbing anything, grep for callers that treat its return as a
*predicate* rather than a status — those are the ones that turn a stub into
data loss.

Still fail-closed, each with a stated reason in the source: the fd-slot model
(`sys_fdbind`, `sys_fdslot_*`, `sys_pipechan`), the
`#s`/`#svc` registries, `sys_netcfg`, the `wsys`/`vk` surface, the `umdf` driver
ops, and the threading model (`sys_rfork_thread`, the semaphores).

Proof, not assertion: `tests/linux/syscall_probe.ad` and
`tests/linux/spawn_probe.ad` call each addition and check its *observable
effect*, returning the failure count as the process exit code — a stub cannot
pass by resolving. Both report `ALL PASS`.

### 4.2 `bind` — much smaller than it looks

> **VERIFIED, counts slightly off, conclusion intact.** The real figure is
> **52 call sites across 50 files**, not 49 — and the original arithmetic did
> not close (45 + 3 ≠ 49). Correct breakdown: **45** identical `#c → /dev`,
> **3** `#d → /fd`, and **4** genuine namespace uses, not 1. The claim that
> matters — that this is a stub-and-move-on, not a subsystem — holds, and the
> stub is now implemented (§4.1d).

`sys_bind` appears in 50 files, which reads alarming. It is not. Of the 52
call sites, **45 are the identical single line**:

```python
sys_bind(cast[Ptr[char]]("/dev"), cast[Ptr[char]]("#c"), 0)
```

— a fixed startup incantation binding the console device (`#c`) into the
process namespace at `/dev`. Another **3** are `sys_bind("/fd", "#d", ...)`.
There is no general namespace algebra in the applications: they each perform one
canned mount at `main()` and never touch it again. Representative:
`user/hamdesktop.ad:2479`.

**Implication:** a `bind` that understands exactly `#c → /dev` and `#d → /fd`
satisfies **48 of 52** sites. This is a stub-and-move-on, not a subsystem, and
it is done — see §4.1d. Both incantations ask for something Linux already
provides at those exact paths, so accepting them and doing nothing is honest;
everything else fails loudly rather than pretending a mount happened.

The **4** genuine namespace uses are in `user/distrofs.ad` (`/n/distros`),
`user/nsrun.ad`, `user/p9srv_demo.ad`, and an `/extbind_probe` site. Per-process namespaces do have a real Linux answer
(`unshare(CLONE_NEWNS)` + `mount --bind` in a mount namespace), but you almost
certainly do not need it to get the desktop up.

### 4.3 `/dev/*` file servers

Distinct `/dev` paths opened by the copied userland, by weight:

| Surface | Hits | Notes |
|--|--|--|
| `/dev/wsys/**` | **~300** | the window system — see §4.4. Dominant by an order of magnitude. |
| `/dev/fb`, `/dev/fbctl`, `/dev/fbpix` | 20 | the framebuffer — see §4.4 |
| `/dev/blk/**` | 25 | block devices → Linux `/dev/sd*`, `/sys/block` |
| `/dev/audio`, `/dev/audioctl`, `/dev/snd/ctl` | 30 | → ALSA or PipeWire |
| `/dev/snarf` | 17 | the clipboard → Wayland/X selection |
| `/dev/cons` | 11 | console → `/dev/tty` |
| `/dev/reboot`, `/dev/stat`, `/dev/auth`, `/dev/time`, `/dev/random`, `/dev/keymap`, `/dev/kbmap`, `/dev/version`, `/dev/hostname`, `/dev/meminfo`, `/dev/loadavg`, `/dev/vt/*`, `/dev/mouse`, `/dev/loop/ctl`, `/dev/firewall`, `/dev/sync`, `/dev/win` | 1–7 each | mostly direct Linux equivalents (`/proc/meminfo`, `/proc/loadavg`, `/dev/urandom`, `reboot(2)`, …) |

`/proc/*` reads (`uptime`, `meminfo`, `loadavg`, `cpuinfo`, `version`, `mounts`,
`modules`, `kmsg`, `net/dev`) are mostly **format-compatible with Linux already**
and may need only field-offset fixes. `/proc/tasks`, `/proc/toptable`,
`/proc/svc/*`, `/proc/self/ctl` and `/proc/realtime` are Hamnix inventions and
need real work (`user/top.ad`, `user/ps.ad`, `user/service.ad`).

### 4.3b The boot, and the Debian namespace — both working

**hamnix-linux boots.** `scripts/hamlinux_image.sh` stages an image;
`scripts/hamlinux_vm.sh` runs it under QEMU/KVM. The shape is deliberately the
same as Hamnix's, because `etc/inittab` already said `/bin/hamsh`:

```
Linux kernel -> /init  (user/linuxinit.ad, the Adder PID 1)
                  -> bind '#p' /proc, '#c' /dev, '#sys' /sys, '#s' /srv, ...
                  -> load /etc/modules
                  -> exec /bin/hamsh /etc/rc.boot
                       -> the rc scripts, then an interactive shell
```

On Hamnix the *kernel* posts those file servers before ELF-loading `/init`;
Linux hands us an empty namespace, so `linuxinit` does it. **`sys_bind`
performs real Linux mounts** — `bind '#p' /proc` still says what it means. New
letters on this line: `#sys` (sysfs; Hamnix has no `/sys`) and `#pts`.

**Kernel modules.** `sys_init_module` is new and unavoidable: on a Debian
kernel essentially every driver is a module, and `/dev/dri/card0` does not
exist until virtio-gpu and its four dependencies load. `user/insmod.ad` cannot
do this — it issues `SYS_INIT_MODULE` through an `asm_volatile` block encoding
the *old* backend's frame layout, and miscompiles under LLVM. The image
resolves dependency **order** at build time (where a real `modprobe` exists)
and writes `/etc/modules`; PID 1 just walks the list.

**The Debian namespace works, and the isolation is structural.** Verified in
the VM: Debian's own `dpkg` runs inside it, the parent's namespace still has
`/bin/hamsh`, and Debian's `ls` inside the namespace **cannot find
`/bin/hamsh` at all**. Nothing `apt` installs can reach the Hamnix filesystem.

It is Hamnix's own idiom mapped one-for-one, not a Linux invention:

| Hamnix | Linux |
|--|--|
| `rfork(RFNAMEG)` without `RFPROC` | `unshare(CLONE_NEWNS)` |
| `rfork(RFPROC\|RFNAMEG)` | `fork`, child unshares |
| `bind '#distro' /n/distro` | mount the subtree's filesystem |
| `bind '#distro' /` | `chdir` + `chroot` into it |

`user/nsrun.ad:72` states the invariant this rests on — **rfork BEFORE mount** —
and every namespace user follows it. Two traps: `sys_rfork` previously refused
any flag combination without `RFPROC`, which made the invariant
*unexpressible*; and **Linux mount propagation defaults to SHARED**, which
leaks the child's bind straight back to the parent and silently defeats the
isolation. The child marks `/` `MS_REC|MS_PRIVATE`. Plan 9's namespace copy is
private by construction, so nothing in the userland asks for this.

The distro image is built by `mmdebstrap --mode=unshare --format=ext4` — no
root, no loop mount, nothing on the host touched — and attached as a separate
virtio disk, so the separation is physical as well as logical.

### 4.4 The compositor and who owns the framebuffer

**Read `docs/de_scene_file_arch.md` before touching anything here.** It changes
the difficulty estimate substantially, in both directions.

The desktop is **not** a pixel-passing compositor. Each window is a directory in
the `wsys` file server; a window's content is a `scene` file — a *line-oriented,
human-readable text display list* in window-local coordinates. Clients (via
`lib/hamui.ad`) rewrite their whole `scene` and poke `ctl` to publish a frame.
The compositor (`user/hamUId.ad`) diffs scenes to compute damage, rasterizes
only the damaged rectangle into a per-window pixel cache, and blits the caches
z-ordered to `/dev/fb`. **The kernel owns no per-window pixel buffers.**

Consequences for the port:

- **Good:** the client-side protocol is text file I/O. `wsys` can become a FUSE
  or 9p userspace server, or a Unix-socket shim, without any client changing.
  There is no shared-memory buffer handoff, no DMA-BUF, no format negotiation.
  This is far more tractable than porting a pixel compositor.
- **Bad, and this is the real problem:** on Hamnix, `/dev/fb` is a file that
  *any* process may open. **Nine programs open it directly** —
  `user/hamUId.ad` (the compositor, legitimately), plus `user/hamdesktop.ad`,
  `user/hamlock.ad`, `user/hamshotui.ad`, `user/hamshot.ad`, `user/hamtoast.ad`,
  `user/hampanelscene.ad`, `user/hamctl.ad`, `user/hambrowse.ad`. On Linux, DRM
  master is **exclusive to one process**, and fbdev is deprecated. Eight of those
  nine must be rewritten to go through `wsys` instead of the framebuffer, or the
  desktop cannot start. `user/hamshot.ad` also reads `/dev/fbpix` for
  screenshots, which needs a compositor-side capture path instead.

`sys_wsys_alloc` / `sys_wsys_free` (window-buffer allocation) and
`sys_vk_window_frame` are absent from the Linux runtime entirely (§4.1c).

> **MEASURED — the framebuffer works, and this section's premise was wrong.**
> The Adder userland paints the VM's screen today: 1024000 of 1024000 pixels
> match what `tests/linux/fb_probe.ad` wrote, using the same banded-write
> pattern `hamUId` uses to present a frame. `user/linux-fb.c` backs `/dev/fb`,
> `/dev/fbctl` and `/dev/fbpix`, so those nine programs need no I/O changes.
>
> **fbdev, not DRM/KMS.** This section assumed fbdev being deprecated ruled it
> out. The opposite held up:
>
> - A hand-rolled legacy `SETCRTC` on virtio-gpu left the host surface **black**
>   even though every ioctl returned 0, `DIRTYFB` reported success, and a
>   readback of our own mapping showed the right pixels. Booting the same guest
>   with `console=tty0` painted the display correctly — through DRM's *fbdev
>   emulation*. Whatever that layer does about deferred I/O and damage, it does
>   correctly and a hand-rolled path does not.
> - `/dev/fb0` **is** `drm_kms_helper` on any modern driver. This is not legacy
>   hardware support.
> - It is the exact analogue of what Hamnix's `/dev/fb` already is: a linear
>   CPU-writable surface with a geometry query. No modeset, no connector/CRTC
>   pairing, no dumb-buffer lifetime.
> - **DRM master is exclusive to one process; fbdev is not.** This section calls
>   that exclusivity the reason eight programs must be rewritten to go through
>   `wsys`. It does not remove the need for `wsys`, but **it stops it being a
>   hard blocker** — the eight can keep opening `/dev/fb` while `wsys` is built.
>
> Raw DRM/KMS is kept as a fallback for a device with no fbdev emulation.
>
> Two things only running it revealed. **The text console keeps drawing into
> the framebuffer** — exactly one 8×14 character cell at (0,0) went black under
> a full-screen paint, the fbcon cursor. Hamnix already has the verb for it
> ("suspend the text console"); on Linux it is `KDSETMODE KD_GRAPHICS` on
> `/dev/tty0`, and opening `/dev/fb` for writing now does it automatically. And
> **`resume` must not be issued while still presenting**: it returns the VT to
> text mode and the console redraws over you, taking a fully painted screen down
> to 16 non-black pixels.

### 4.4b The `wsys` protocol, from the client side

The server has not been written yet, but the contract it must satisfy is fixed
by `lib/hamui.ad` and is small. Every path, by weight:

| Path | Hits | Meaning |
|--|--|--|
| `/dev/wsys/ctl` | 115 | the server control file |
| `/dev/wsys/<wid>/…` | 60 | per-window directory |
| `/dev/wsys/self` | 17 | read → the wid the compositor allocated to *this* process |
| `/dev/wsys/post`, `run/launch`, `appmenu/launch` | 15 | launcher plumbing |
| `/dev/wsys/cursor/scene`, `wallpaper`, `tray`, `session`, `workspace`, `windows` | 1–4 each | shell surfaces |

**Window creation** (`lib/hamui.ad:2280`) is the load-bearing sequence:

1. read `/dev/wsys/self` → if it parses to a wid ≥ 2, the compositor already
   allocated one and it is *owned* by this process; use it.
2. otherwise write `newwindow\n` to `/dev/wsys/ctl`, then **read
   `/dev/wsys/ctl` back** for the new wid as ASCII decimal.

Note wid 0 and 1 are reserved — `hamui` rejects anything `< 2`, and wid 1 is
the foreground console window that a normal user does not own.

**Per-window `ctl` verbs**, written to `/dev/wsys/<wid>/ctl` as newline-
terminated text (`_h_win_setup`): `geometry <x> <y> <w> <h>`, `decorate 1`,
`z <n>`, `title <text>`. Per-window leaves: `scene` (the display list),
`event`, `pointer`, `keys`.

Because it is all text file I/O, `wsys` can be a FUSE or 9p userspace server or
a Unix-socket shim without any of the ~75 Tier-4 clients changing — the good
news §4.4 already identified, now with the exact surface to implement.

---

## 5. Applications ranked by expected porting difficulty

All 277 apps classified by which native surfaces they touch. Counts are exact.

### Tier 1 — 151 apps: POSIX-only, expected to port for free

They touch nothing but `open`/`read`/`write`/`close`/`exit`. This is the entire
coreutils-shaped set: `cat`, `ls`, `cp`, `mv`, `grep`, `sed`, `awk`, `sort`,
`diff`, `tar`, `bc`, `cal`, `base64`, `cksum`, `column`, `comm`, `csplit`,
`cut`, and ~130 more. **Most of the userland is in this tier.** Expect them to
build and run once class (c) of §4.1 is filled in. They are also your smoke
test: get `cat` running before anything else.

> **MEASURED 2026-08-09.** Both halves of this were checked by building and
> running, not by reading.
>
> **Building — effectively total.** `scripts/hamlinux_sweep.sh` builds all 359
> `user/*.ad` through the glibc lane: **351 build, 0 real failures.** The 8
> non-zero exits are not app failures — 4 (`net9`, `http9`, `httpdconf`,
> `hambrowse_tabs`) are *modules with no `main`*, and 4 are `*_host.ad`
> harnesses wanting `devsnarf_*` from a C shim, not `sys_*` at all. Nothing in
> `user/` fails to compile or codegen. "Nothing here builds yet" is no longer
> true, and it was never a compiler problem — only a missing link runtime.
>
> **Running — the number that matters.** 181 Tier-1 apps were run and checked
> against *their own header contracts* (see the warning below): **120 PASS,
> 25 FAIL, 36 SKIP**. Excluding SKIPs — apps needing a device this host has no
> answer for (audio, `/dev/blk`, `/dev/wsys`, a tty, root) — that is an **83%
> pass rate**.
>
> **Failures concentrated in two stubs, both now fixed:** `sys_chan_dir_mode`
> (6 apps) and `sys_get_jiffies` (9 apps) accounted for 15 of the 25. See the
> warning below and §4.1d. Remaining known-real failures: 3 apps
> (`insmod`/`modprobe`/`rmmod`) whose hand-written `asm_volatile` wrappers
> encode the *old* backend's `%rbp` frame layout and break under LLVM; 2
> (`ifconfig`, `route`) on `sys_netcfg`; 2 (`nsrun`, `nsbindprobe`) on real
> namespaces; 1 (`tty`) on `sys_fdslot_kind`; and 1 (`hxd`) that looks like a
> genuine **wrong-code bug in the LLVM backend** — a loop induction variable
> never compared or incremented. That last one is worth someone's attention on
> its own.
>
> ⚠️ **Do not verify these against GNU coreutils.** They are deliberately
> narrower reimplementations and the GNU comparison manufactures false
> failures. `user/wc.ad` *ignores filename operands and reads only stdin*;
> `user/head.ad` likewise. Both are correct, and both look broken next to GNU.
> The header comment is the contract.
>
> ⚠️ **The tier boundaries themselves are soft.** A direct re-derivation put
> 181 apps in Tier 1 against this section's 151, and 13 in Tier 2 against 27.
> The classification here was static and transitive imports blur it; treat the
> tier as a planning aid, not an inventory.

### Tier 2 — 27 apps: read Hamnix-format `/proc` and `/dev/blk`

`ps`, `top`, `free`, `df`, `uptime`, `dmesg`, `lsblk`, `lsmod`, `losetup`,
`crond`, `date`, `service`, `initctl`, `pgrep`, `nproc`, `hammon`, `hlog`,
`oopsread`, `memhog`, `sysirqprobe`, `dd_blk`, `sqfs_to_blk`, `haminstall`,
`hamnix_partition`, `live_distro_up`, `nice_hi`, `nice_lo`.

Difficulty is *parsing*, not architecture. Several `/proc` files are already
Linux-format. `ps`/`top` need `/proc/tasks` and `/proc/toptable` replaced with
a `/proc/[pid]` walk.

### Tier 3 — 18 apps: networking

`curl`, `wget`, `ssh`, `sshd`, `httpd`, `httpd_worker`, `ping`, `ntpd`, `host`,
`ifconfig`, `route`, `hfw`, `hpm`, `u_server`, `u_tlstest`, `net9`, `http9`,
`modprobe`.

**They all block on one decision (§3), and then unblock together** — 15 of the
18 only ever call into `net9.ad`/`http9.ad`. `ntpd` needs UDP separately;
`ifconfig`/`route` need `sys_netcfg` (rtnetlink) and are independent of the
`/net` decision; `hfw` needs `/dev/firewall` (nftables) and could be dropped.

### Tier 4 — 71 apps: GUI clients on `/dev/wsys`

Everything `ham*scene`, plus `hamcalc`, `hamedit`, `hamfiles`, `hamnotes`,
`hamsheet`, `hamslides`, `hamwrite`, `hamsettings`, `hamsoftware`, `haminbox`,
the games, and so on. They talk the scene-file protocol through `lib/hamui.ad`
and bind `#c → /dev` at startup.

They are **uniform** — they nearly all go through `lib/hamui.ad`. Port `hamui`
and the `wsys` server, and this tier moves as one block. Individually they are
easy; collectively they are gated on §4.4.

### Tier 5 — the hard ones

| App | Why |
|--|--|
| **`hamUId.ad`** (31.2k lines) | the compositor. Owns `/dev/fb`, `/dev/wsys`, input, audio mixing, `/net/addr`. Everything in Tier 4 waits on it. **The critical path.** |
| **`hamsh.ad`** (17.6k lines) | needs `sys_waitpid`, `sys_tcsetpgrp`, `sys_pipechan`, `sys_srv_post`, `sys_rfork` job control. Cheap-ish on Linux but touches the most stub classes. Needed early — it is how you drive everything else. |
| **`hambrowse.ad` + `lib/web/`** (42 files) | a from-scratch HTML/CSS/JS engine. Needs `/net` *and* `/dev/fb` *and* `wsys`. Substantial but self-contained; the engine itself is portable. |
| **`hamdesktop.ad`, `hampanelscene.ad`, `hamlock.ad`, `hamtoast.ad`, `hamshot.ad`, `hamshotui.ad`** | the eight direct-`/dev/fb` violators of §4.4 |
| **`hpm.ad`** (8.2k) | package manager: `/net` + namespaces + block devices |
| **`user/x11/`** (6 files) | an X11 *server* over `net9`. On Linux this is redundant — delete it. |
| **`sshd.ad`, `distrofs.ad`, `nsrun.ad`, `p9srv_demo.ad`** | the genuine namespace/9p users |

---

## 6. Desktop stack: keep vs replace

> **DECIDED: keep.** Nothing in the DE was replaced. `hamdesktop`,
> `hampanelscene`, `hamtermscene` and the rest run unmodified against
> `/dev/wsys`; the compositor is a new Adder program (`user/wsysd.ad`) that
> reuses `lib/hamui_host.ad`'s rasterizer as-is. A foreign toolkit reaches the
> screen through the v2 blit protocol that `devwsys.ad` already specified, and
> `user/xbridge.ad` is the first client of it.


**Keep.**

- **The scene-file protocol and `lib/hamui.ad`.** It is the distinctive thing
  here, it is text over files, and it ports cleanly. Discarding it for GTK would
  mean rewriting all 71 Tier-4 apps.
- **`lib/web/`.** A from-scratch engine is the project's point; it has no Linux
  dependency beyond `/net`.
- **The rasterizer inside `hamUId.ad`.** It is the part that already works and
  is independent of who owns the display.

**Replace.**

- **`/dev/fb` scanout** → a single DRM/KMS backend, or (much easier to start) a
  Wayland or SDL surface. Do *not* try to keep multi-process framebuffer access.
- **`user/x11/`** → delete. Linux has X and Wayland.
- **`/dev/audio` + `lib/hammixer.ad` software mixing** → PipeWire. Software
  mixing exists only because Hamnix had no audio server.
- **`/dev/snarf`** → the Wayland/X selection protocol.
- **`lib/vk/`** (`vk_gpu`, `vk_venus`, `vk_hostgpu`) → the real Vulkan loader
  and Mesa. Getting a genuine GPU stack is a large part of why this line exists.
- **`lib/font_ttf.ad` / `font_bdf.ad`** → probably FreeType + fontconfig, though
  keeping them costs little and preserves rendering fidelity. Judgement call.

**Open:** whether `hamUId` should remain a compositor at all, or become a
Wayland *client* that hosts the scene-file protocol inside one surface. The
latter is dramatically less work and gets you a desktop on day one; the former
preserves the architecture. This is the biggest design decision in the port and
it is not mine to make.

---

## 7. Open questions I could not resolve

> **§7.1 ANSWERED** (descriptors as names — `user/linux-fdns.c`; a pipe slot is
> a FIFO, the bind table is shared, `/fd/<n>` resolves per-process).
> **§7.4 RESOLVED** earlier (glibc, deliberately).
> The rest still stand. See §0.


1. **Shim library vs. real file server for `/net`.** `scripts/net9_host_shim.c`
   proves the shim works for clients. It does **not** handle
   `net_open_conn_data` — a connection accepted in `httpd.ad` and opened by
   integer in a *different* process (`httpd_worker.ad`, §3.3). Whether to extend
   the shim with an fd-passing side channel, or move to FUSE/9p where cross-
   process addressing is native, I could not settle without knowing whether the
   multi-process server model is something you want to keep.

2. **In-kernel TLS.** `tls <host>` on a `ctl` file currently runs a TLS 1.3
   handshake in the Hamnix kernel and the `data` fd is transparently encrypted
   after it. Where does that live on Linux — inside the `/net` server (keeps
   clients unchanged, but the server now holds all private keys for all
   processes), or does `net9.ad` grow a userspace TLS path (breaks the "no
   sockets, no TLS in userland" invariant that the architecture doc treats as
   load-bearing)?

3. **Does the no-sockets invariant still bind on this line?** Hamnix's
   architecture forbids BSD sockets in Adder code. On the Linux line that
   prohibition may be philosophy rather than architecture, and dropping it would
   erase most of §3. I did not have the standing to decide this, and it is worth
   deciding *before* anyone writes a file server.

4. ~~**glibc or stay static-nolibc?**~~ **RESOLVED — it already works, and it
   was never a question in the LLVM lane.** `scripts/adder_cc_llvm.sh` has
   clang perform the link, and clang links glibc by default: the very first
   binary built through it is a `dynamically linked ... interpreter
   /lib64/ld-linux-x86-64.so.2` PIE against `libc.so.6`. No new backend work
   was needed and none is needed for OpenSSL, Mesa, PipeWire or FreeType —
   each is an ordinary `clang` link flag.

   Exactly **one** symbol collided between `user/linux-runtime.S` and glibc:
   `_start`, which `crt1.o` also defines. It is now guarded by `ADDER_HOSTED`,
   so one runtime serves both lanes and glibc's initialisers actually run
   (required before any libc-dependent library can be called). The
   static-nolibc question survives only for the *freestanding* lane, which is
   not the shipping path.

   **`scripts/hamlinux_build.sh` is the resulting per-app build lane.** It
   differs from `adder_cc_llvm.sh` only in linking the real syscall runtime
   rather than the SSA-prelude stub — which is what anything in `user/`
   actually needs — and reports its three failure modes as distinct exit codes
   (10 emit, 11 SSA bail, 12 link) so a sweep can group failures without
   parsing logs.

5. **`hamsh`'s job-control model vs. Linux process groups.** `hamsh` uses
   `sys_rfork`, `sys_pgrp_kill`, `sys_setexitsem` and `sys_waitpid_jc`. Whether
   Plan 9 rfork semantics can be expressed adequately in `clone(2)` flags for
   *this specific shell* I did not trace through 17.6k lines.

6. **Is `hamsh`'s alias/def/scope ceiling real?** Hamnix has unverified reports
   of caps at 65 aliases, 33 defs, 128 scopes. If those are real and are
   compiler limits rather than shell limits, they will follow the code here.
   Unverified either way.

7. **The 84 `*_host.ad` harnesses.** They are the most Linux-ready code in the
   tree and probably the right scaffold to build the port on — but they were
   written as *test* harnesses, not as a runtime. Whether to promote them into
   the real Linux path or treat them as reference, I could not judge.

---

## 8. Suggested first moves

Not prescriptive — but this ordering follows from the inventory above.

1. Fill in §4.1 class (c): the ~8 trivially-POSIX symbols. Get `cat`, `ls`,
   `echo` building and running. Proves the toolchain and the runtime.
2. Add `sys_waitpid` (`wait4`) and `sys_tcsetpgrp`. Get `hamsh` running. Now you
   have a shell to drive everything else.
3. Stub `sys_bind` to understand `#c → /dev` and `#d → /fd` (§4.2). 48 of 49
   sites satisfied.
4. Sweep Tier 1 (151 apps). Expect a high pass rate; each failure is a real bug
   worth a fix, not a port decision.
5. Decide §7.1/§7.3, then do `/net`. Tier 3 unblocks as a block.
6. Decide §6's open question, then `wsys` + `hamui`. Tier 4 unblocks as a block.

Tiers 1–3 are ~196 of the 277 applications and require no architectural
decisions beyond `/net`. The desktop is the long pole; it is also separable.
