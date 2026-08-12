# Steam-class applications in the Debian namespace

**What was asked:** *"I want even large apps to be able to run from the debian
NS, like steam."* Steam is the right target because it exercises everything at
once — 32-bit multiarch, a container runtime, a GPU stack, audio, and an X11
window path — and because each of those fails differently.

**Where it stands, in one line:** the Steam client **runs** in the namespace,
installs itself, brings up its pressure-vessel container, and **its login
window is on the Hamnix desktop** — mapped, managed by the session's window
manager, and scanned out. Two things had to be true at once and each hid the
other: `matchbox` was unmapping the window (§6.2, now `jwm` —
`docs/linux_window_manager.md`), and `wsyswl` was dropping every frame past
16 wl_shm mappings when Steam's X session holds 26 (`MAXMAP`, §6.2b).
Everything below is measured in the VM.

---

## 1. What a run looks like today

```
enter debian { steam }
```

from the **console** (uid 0) gets you: the launcher, a ~2.5 GB client
download, the sniper container, `steamwebhelper`, and the login window on the
Hamnix desktop — `Sign in to Steam`, 700x440 at +290+180, undecorated because
CEF draws its own chrome and `jwm` honours that, alongside whatever else is on
the session's X screen.

From a **desktop terminal**, which is uid 1001, it used to get you something
worse: the body ran in the native root and reported success. It now gets you
the same namespace the console does, container and all. See §7.

---

## 2. The scoreboard

`tests/linux/steam_probe.sh`, run inside the namespace by
`tests/linux/steam_probe_run.sh`. **23 PASS, 1 FAIL**, re-measured after the
window-manager change and unmoved by it --
and it now scores the same from a uid-1001 session as from the console, which
it could not do at all before (§7). The one remaining FAIL is the PulseAudio
server socket (§8).

| Piece | State | Evidence |
|--|--|--|
| i386 multiarch | **works** | `dpkg --print-foreign-architectures` = i386; `/lib/ld-linux.so.2` present; a 32-bit `glxgears` execs and its NEEDED closure resolves |
| 32-bit GL, on screen | **works** | screenshot: `glxgears:i386` compositing on the Hamnix desktop |
| 32-bit Vulkan | **works** | a 32-bit `vulkaninfo` enumerates `llvmpipe (LLVM 15.0.6)` from the namespace's own `lvp_icd.i686.json` |
| network + DNS | **works** | `getent hosts`, and HTTPS to `repo.steampowered.com` |
| Steam client install | **works** | bootstrap pre-staged, client downloaded, `Steam client's requirements are satisfied` |
| pressure-vessel container | **works as root** | `srt-bwrap` alive with the sniper runtime, `steamwebhelper` running inside it |
| pressure-vessel as a user | **works** | the root switch is `MS_MOVE` onto `/`, not `chroot`, so `bwrap --unshare-user` builds a container as uid 1001 — §5, §7 |
| X screen geometry | **works** | 1280x800 at 96 dpi inside the namespace; the session's window manager publishes `_NET_WORKAREA = 0,0,1280,800` — §6.1 |
| window management in the namespace | **works** | `jwm`, reparenting, 27px title bar, 66 `_NET_SUPPORTED` atoms, `xdotool` move and resize both take effect and the client stays `IsViewable`; Firefox too — `docs/linux_window_manager.md` |
| a Chromium window, end to end | **works** | `tests/linux/x11_geom_probe.sh`: a real Chromium maps a 1000x600 toplevel through Xwayland → wsyswl → wsysd and its pixels reach the framebuffer |
| Steam UI window, in X | **works** | `Sign in to Steam` is `IsViewable` at 700x440+290+180 and in `_NET_CLIENT_LIST` under `jwm`, and `xwd -root` finds 210 distinct colours inside it — the UI is drawn — §6.2 |
| Steam UI window, on the framebuffer | **works** | it was `MAXMAP`: 16 wl_shm mappings per connection against the 26 Steam's X session holds, so `commit_buffer` dropped every frame at `mi < 0` and one exhausted table froze the whole rootful X screen. 64 now, and every drop is counted by reason in `wsyswl-state` — §6.2b |
| audio | **works** | `/dev/audio` on intel-hda since b18e105b, FFT-proven on a WAV captured out of QEMU. Steam's one remaining probe FAIL is the PulseAudio *socket*, which is a different thing from having a card. |

---

## 3. i386 multiarch, and what it costs

`scripts/hamlinux_distro.sh` now passes `--architectures=amd64,i386`, which is
mmdebstrap's way of doing `dpkg --add-architecture i386` *before* the first
package is unpacked. Steam's bootstrapper (`ubuntu12_32/steam`) is
`ELF 32-bit LSB, Intel i386` and has no 64-bit build, so this is not optional.

**The size, because this is a distro and it matters:**

```
1303 MiB  ->  2062 MiB     delta +759 MiB
```

Most of that is one thing: the i386 Mesa (`libgl1-mesa-dri:i386` plus
`mesa-vulkan-drivers:i386`). `HAMLINUX_I386=0` builds the old
single-architecture image with no Steam in it.

The **filesystem** also had to grow, and this was a real trap: mmdebstrap sizes
the ext4 to fit what it installed and truncates the file back down, so the
`truncate -s 12G` before it bought nothing — the first multiarch image came out
with **310 MB free inside a 12 GB file**. Steam wants ~2.5 GB for the client
alone. The script now `resize2fs`es after the bootstrap. The file stays sparse,
so the headroom is free until it is used.

---

## 4. GPU: which Vulkan userspace applies, and why

**The namespace's own Debian Mesa, not the Hamnix root's.** Commits 8c402a9d /
8d9dd4a6 put a Vulkan userspace in the *Hamnix* root, and that is right for
what it is for — `lib/vk/*` and Adder programs resolve their ICD there. A
Debian process inside `enter debian` cannot see any of it: its root **is** the
Debian tree, so it resolves `/usr/share/vulkan/icd.d` and
`/usr/lib/i386-linux-gnu/dri` inside that tree and nowhere else. The two stacks
are not in competition and neither substitutes for the other.

What crosses the boundary is the **device**, not the driver: `enter_root`
bind-mounts `/dev` with `MS_REC`, so `/dev/dri/card0` and `renderD128` are
visible inside. Confirmed by the probe.

**No real GPU acceleration is measurable on this host, and none is claimed.**
QEMU's plain `virtio-gpu-pci` offers no virgl, so Mesa falls back to
`llvmpipe`/`lavapipe`; and venus does not come up on this machine at all — the
long note in `scripts/hamlinux_vm.sh` records exactly where it stops (the
host's NVIDIA GBM backend). Everything graphical here is software rasterised
and says so.

---

## 5. The Steam runtime container — the honest answer

This was flagged as the part most likely to be genuinely hard. It is, and the
answer is sharper than "does bubblewrap work".

**Two separate things use two separate mechanisms.** The Steam *client* runs
under the old LD_LIBRARY_PATH "scout" runtime and needs no container at all.
`steamwebhelper` (the UI) and *games* run under **pressure-vessel**, which
builds a container with bubblewrap.

**As root, it works.** Measured, not argued — from `ps` inside the namespace
while Steam was up:

```
311 ? Ss  .../pressure-vessel/libexec/steam-runtime-tools-0/srt-bwrap --args 26 ...
441 ? Ss  /usr/lib/pressure-vessel/from-host/.../pv-adverb ... --overrides-path ...
498 ? S<l ./steamwebhelper ...
```

The sniper container is built and `steamwebhelper` is running inside it,
inside a chroot, inside a private mount namespace. bwrap as root does not need
a user namespace, and everything else it wants — `CLONE_NEWNS`, `CLONE_NEWPID`,
mounts — is available.

**It used to be impossible as a non-root user, and the reason was structural.**
bwrap run by an unprivileged user must create a user namespace first, and the
kernel refuses that to a chrooted process — `create_user_ns()` →
`current_chrooted()` → `EPERM`. bubblewrap's own message blames the sysctl,
the sysctl was fine (`max_user_namespaces=15605`), and `enter debian` was
implemented as `chroot(2)`.

**FIXED. `enter_root` no longer chroots into the namespace; it moves the new
root onto `/` first.** Both halves of the scoreboard now pass, and they pass
for the session user as well as for root:

```
steamprobe: PASS bwrap WITHOUT --unshare-user runs (uid 0)
steamprobe: PASS bwrap --unshare-user runs (the chroot restriction is gone)
steamprobe: PASS bwrap WITHOUT --unshare-user runs (uid 1001)
steamprobe: PASS bwrap --unshare-user runs (the chroot restriction is gone)
```

**The prescription in the previous version of this section was wrong, and the
measurement that corrected it is worth keeping.** "Use `pivot_root` instead of
`chroot`" is the textbook answer and it does not work on this boot:

```
nsprobe: initial root mount id=38 parent=38 UNATTACHED | 38 38 0:2 / / rw - rootfs
nsprobe: RESULT pivot_root(".","."): FAIL Invalid argument
nsprobe: RESULT MS_MOVE -> /: OK
nsprobe: RESULT after-switch nested CLONE_NEWUSER: OK
```

On the live initramfs boot the root mount is `rootfs`, whose mount id equals
its parent id — it is not attached to anything — and `pivot_root(2)` rejects
that with `EINVAL`, for root and unprivileged alike. What works is what
`switch_root(8)` has always done on exactly this filesystem:
`mount(new, "/", MS_MOVE)` then `chroot(".")`. The kernel's
`current_chrooted()` walks down from the mount namespace's root dentry through
whatever is mounted there and compares that with the process's root; moving
the new root onto `/` makes those the same path, so the `chroot(2)` that
follows is invisible to it. Same confinement, and the user namespaces work.
The probe is `tests/linux/ns_probe.c`; run it from a boot rc.

**The privilege the session user is missing is taken, not borrowed.** `mount(2)`
needs `CAP_SYS_ADMIN`, and `unshare(CLONE_NEWUSER)` grants a full capability
set in the namespace it creates — so the first `bind` that fails `EPERM` makes
one and retries (`ns_privilege()` in `user/linux-syscalls.c`). Two traps, both
measured: `/proc/self/uid_map` opens `EACCES` after a `setuid(2)` drop until
`prctl(PR_SET_DUMPABLE, 1)` undoes what `commit_creds()` did, and a namespace
with *no* map is uid 65534 with nothing mapped, which fails the nested
`CLONE_NEWUSER` bwrap needs anyway. The map is the **identity** (`1001 1001 1`)
— see §7.

---

## 6. The window path, and where Steam stops

```
32-bit X11 client -> Xwayland -> wsyswl (Adder) -> wsys v2 blit -> wsysd -> /dev/fb
```

**Xwayland runs inside the namespace and `wsyswl` runs outside it**, so they
have to meet on a socket both can name. They do, and no binding was needed:
start the server with its socket path *inside the Debian tree* —

```
/bin/wsyswl /n/distro/run/wayland-0
```

— and the namespace, whose root **is** that tree, finds it at the ordinary
`/run/wayland-0`.

**Verified end to end** with a 32-bit GL client: `glxgears:i386` renders on the
Hamnix desktop, in a wsys window, composited to the scanned-out framebuffer
(`build/steamprobe/glxgears.png`).

**Steam gets almost all the way.** From its own logs: the client launches,
verifies its installation, opens the display, starts `steam-runtime-launcher-service`,
brings up the sniper container, and CEF loads the Steam UI —

```
CreateBrowser id:2322243126 ... / BrowserReady: handle:65536
PopupHTMLWindow: idx:131073 handle:65536
CONSOLE(2) "SteamApp Init - Before Login - SystemNetworkStore - ERROR
            TypeError: SteamClient.System.Network.RegisterForDeviceChanges is not a function"
```

### 6.1 What was checked, and what it ruled out

The loudest clue was `(-2147483648, -2147483648)` — `INT32_MIN`, which is what
a toolkit uses when a geometry query gave it nothing. Three hypotheses were
tested, in this order. **Two of them are dead, by measurement.**

**The X screen is not garbage.** Inside the namespace, with Steam running:

```
xdiag: === xdpyinfo
  dimensions:    1280x800 pixels (338x211 millimeters)
  resolution:    96x96 dots per inch
```

That is the display's real size and a sane DPI. Nothing in our stack answers
the screen-size question with a sentinel.

**Something *is* managing the windows, and it publishes a work area.**
`matchbox-window-manager` is running and the EWMH handshake is complete:

```
_NET_SUPPORTING_WM_CHECK(WINDOW): window id # 0x200006
_NET_WORKAREA(CARDINAL) = 0, 0, 1280, 800
_NET_DESKTOP_GEOMETRY(CARDINAL) = 1280, 800
_NET_ACTIVE_WINDOW(WINDOW): window id # 0x1800015
_NET_SUPPORTED(ATOM) = _NET_WM_WINDOW_TYPE_TOOLBAR, ... _NET_WM_PING
```

A client asking "how much room have I got" gets `1280x800`, not silence.

**The window path carries Chromium — which is what CEF is.**
`tests/linux/x11_geom_probe.sh` runs the whole chain offscreen against the
host's own Xwayland and puts a real Chromium down it: it maps a 1000x600
toplevel and its pixels land in the framebuffer
(`build/x11geom/chromium_offscreen.png`). So a Chromium window is not
something this stack is incapable of showing.

**What the hypotheses DID find** is written up in its own commit and is real,
just not Steam's blocker: `wsyswl` had the screen size as the literal
`1280x800`, so every Wayland and X11 client in the namespace was told the dev
VM's resolution rather than the display's; and a *rootful* Xwayland stopped
sizing itself from the `wl_output` at version 23.1, so the X screen size was
silently a property of the Xwayland version. Both are fixed — `wsyswl` reads
`/dev/wsys/screen` through `lib/hamscreen.ad` and publishes the answer as a
file beside its socket, which is the one name that crosses the namespace
boundary, and the session passes it as `-geometry` **when the server has that
option** (22.1.9 does not, and does not need it).

### 6.2 Where Steam actually stops

**It was matchbox, and then it was us.** Two things were wrong, one behind the
other, and the first was hiding the second.

**(1) matchbox is what left every window `IsUnMapped`.** With
`matchbox-window-manager` running, the X root has exactly one child — the WM's
own 5x5 check window — and every Steam window reads `IsUnMapped`. Run the
identical session with **no window manager at all** and the same Steam, at the
same point in its startup, has this on the root:

```
0x1a00015 "Sign in to Steam" ("steamwebhelper" "steam") 700x440+290+180  IsViewable
0x40000c  "sh" ("xterm" "XTerm")                        364x212+40+40    IsViewable   <- control
0x1800003 "steamwebhelper"    200x200+0+0     IsUnMapped
0x1800001 "steamwebhelper"     10x10+10+10    IsUnMapped
0x1600001 "Chromium clipboard" 10x10-100-100  IsUnMapped
0xc00005  ("Steam" "Steam")    64x24+0+0      IsUnMapped
0xe00001  "steam"              10x10+10+10    IsUnMapped
```

`xev -root` — the X server's own witness, selecting `SubstructureNotify` on
the root — recorded **23 CreateNotify and 2 MapNotify** across the run: one for
the control `xterm`, one for `Sign in to Steam`. So **Steam does issue
MapWindow**, and the seven windows that stay unmapped are supposed to:
Chromium's clipboard window, the launcher's 1x1 IPC windows, steamwebhelper's
10x10 hidden helpers. The tracing question in §6.3 was answered by the WM
experiment before a tracer was needed.

`tests/linux/hamnix_x11session.sh` therefore stopped starting matchbox. For
one pass it started **no window manager at all**, which was right for a
session running one application and wrong for a desktop — with nothing
managing the screen, nothing inside the namespace can move, resize, stack or
close a window and `_NET_SUPPORTED` comes back with zero atoms. The default is
now **`jwm`**: reparenting, a real title bar, 66 `_NET_SUPPORTED` atoms, no
D-Bus and no settings daemon, and **0.5 MiB and one new package** in this
image because `firefox-esr` had already installed all sixteen of its
dependencies. `HAMNIX_X11_WM=none` restores the WM-less arm these
measurements used and `HAMNIX_X11_WM=matchbox` the original behaviour;
`docs/linux_window_manager.md` has the full table, including why openbox
(85 atoms, the best EWMH of the candidates) costs 57.9 MiB here and why that
is Ghostscript's fault.

**(2) The window is mapped AND painted, and the framebuffer does not have
it.** This is ours, not Steam's. The X server's own screen contents, read with
`xwd -root` from inside the namespace and measured per window rectangle:

```
xshot: 1280x800 depth=24 bpp=24 bpl=5120
xshot: 0x1a00015 700x440+290+180: 210 distinct of 6300 samples;
                 #191a1ex2290, #212328x1297, #ffffffx578, #393c44x324
xshot: 0x40000c  244x134+40+60:     2 distinct of 700 samples; #ffffffx646, #000000x54
```

210 distinct colours in Steam's rectangle, dominated by Steam's own dark
chrome — and the coarse map of the root prints the login dialog's fields,
buttons and the QR block as recognisable shapes. **The Steam UI is drawn, on
this X screen, right now.**

The QEMU screendump of the same VM at the same moment has the control `xterm`
on it and nothing where Steam's window is. The Hamnix desktop is not frozen —
the panel clock advances between frames — and the `xterm`, which painted
earlier, is there. So the scanout is carrying an OLD frame of the rootful
Xwayland surface: `Xwayland → wsyswl → wsys v2 blit → wsysd → /dev/fb` stops
delivering that surface's updates at some point after the first client paints.

**The control settles it.** Put an `xterm` in the same session, let it paint —
it DOES reach the framebuffer, so the path is not broken in general — and then
move it with `xdotool windowmove 0x40000c 700 500` and resize it to 1000x700.
X reports the new geometry immediately. The screendump 60 seconds later still
shows that `xterm` 244x134 at +40+60. Rootful Xwayland presents the whole X
screen as ONE `wl_surface`, so a stale `xterm` and an invisible Steam window
are the same fact: **the surface stopped being delivered**, and none of this
is about Steam.

`build/steamprobe/` holds both sides: `nowm_xwd.boot.log` /
`nowm_move.boot.log` for the X side and the move, `nowm_move.png` for the
scanout at the same second, and `burst_nowm.log`, whose forty frames are
byte-identical across 200 seconds.

The UI itself is alive: the login page runs and polls, which is a thing only
a loaded page does —

```
CONSOLE(2) "Login: Failed to poll auth session. Result 2. Transport Error: 2"
```

and the last line CEF ever writes is `atom_cache.cc(229) Add STEAM_GAME to
kAtomsToCache`, after which nothing further happens. So Steam builds its UI,
runs it, and never shows it.

Two things are wrong around it, both measured, and neither yet proven to be
the cause:

* **CEF's GPU process exiting is NOT the cause.** It does exit, twice per
  launch — `[518:518] ERROR:viz_main_impl.cc(166) Exiting GPU process due to
  errors during initialization`, once for the GPU process and once for its
  fallback, with no error of its own beforehand. So it was tested directly, by
  running Steam with its own pass-through switches:

  ```
  hamnix-steam -cef-disable-gpu -cef-disable-gpu-compositing
  ```

  They reach the webhelper (`exec ./steamwebhelper … --disable-gpu-compositing
  --disable-gpu …`), the `viz_main_impl` errors stop completely, and **the
  window tree is byte-for-byte the same**: the same four Steam windows, all
  still `IsUnMapped`. That hypothesis is dead.

* **Steam's launcher DOES try to show a window, and nothing appears.** Its
  console log has `Show window` and, three seconds later, `Destroy window`,
  around the "Verifying installation..." dialog — before CEF exists at all.
  `tests/linux/steam_gui_burst.sh` screendumps every second across that
  interval (37 frames spanning `04:01:00`, which is when `Show window`
  happened) and every frame is byte-identical black. So the thing that does
  not reach the screen is not specific to CEF.
* **The system D-Bus is NOT dead — that entry was wrong.** With the corpse
  cleared by pid liveness and the daemon started as
  `dbus-daemon --system --nofork --print-address &`, `/run/dbus/pid` names a
  live process and

  ```
  dbus-send --system --dest=org.freedesktop.DBus --print-reply \
      /org/freedesktop/DBus org.freedesktop.DBus.GetId
  method return ... string "f5d187a9a3b4a08a2ac8d1c16a7abcc4"
  ```

  answers from inside the namespace. (`dbus-send` IS in this image; an earlier
  note in the session script said it was not.) What is genuinely missing are
  the SERVICES on the bus, and CEF names them itself:
  `org.freedesktop.UPower ... was not provided by any .service files`. Missing
  services are not a missing bus, and neither of them is why the window is
  invisible.
* **The system D-Bus was dead, and for the tree's signature reason.** The
  namespace's `/run` is on the ext4 and survives reboots, so the first boot's
  `dbus-daemon` left `/run/dbus/system_bus_socket` behind for ever; the
  session's `[ ! -S ... ]` guard saw a socket, skipped starting the daemon,
  and every CEF process logged `Failed to connect to socket
  /run/dbus/system_bus_socket: Connection refused`. **Waiting for the socket
  is not waiting for the server** — the same trap as `/tmp/.X0-lock` in §10,
  one directory over. `hamnix_x11session.sh` now pings the bus and clears the
  corpse; `hamnix_xdiag.sh` reports which of the two it found.

### 6.2a THE ANSWER: sixteen shm mappings, and Steam holds twenty-six

**It was the first suspect in §6.3's list, and the reason it took three passes
to reach is that nothing said so.** `wsyswl` gave each connection `MAXMAP = 16`
wl_shm mappings. Steam's X session holds **26** at once. Past the sixteenth,
`map_alloc` returns -1, the pool has no mapping, and `commit_buffer` returns at
`mi < 0` — for every frame, for ever. A rootful Xwayland presents the whole X
screen as ONE `wl_surface`, so one exhausted table freezes the entire session
at once: that is why the control `xterm` went stale in the same breath as
Steam's window went missing, and why neither was ever about Steam.

Two boots of the same image, differing only in that number, read off the
counters the compositor now publishes:

| | `MAXMAP=16` | `MAXMAP=64` |
|--|--|--|
| `commits` | 3 | 506 |
| `map_alloc_failed` | 10 | 0 |
| `drop_no_mapping` | 508 | 0 |
| `maps_high_water` | 16 (full) | 26 |
| the screen | black where Steam is; the `xterm` still 484x316 at +40+40 sixty seconds after `xdotool` moved it to 900x500+300+250 | **`Sign in to Steam`** — fields, buttons and QR block — with the moved `xterm` behind it |

`build/steamprobe/steam_login_maxmap64.png` and, as the control,
`build/steamprobe/steam_black_maxmap16.png`.

**And this time the console said it itself**, the first time it happened:

```
wsyswl: DROPPING FRAMES -- wl_shm mappings exhausted -- raise MAXMAP
wsyswl: DROPPING FRAMES -- the wl_buffer has no shm mapping (map_alloc failed earlier)
```

#### What the compositor publishes now

Every silent `return` in `commit_buffer` is counted by reason, named **once**
on stderr, and the whole set is written to `wsyswl-state` **beside the Wayland
socket** — the one directory that spans the namespace boundary (§6), so
`cat /run/wsyswl-state` answers from inside Debian and
`cat /n/distro/run/wsyswl-state` from outside it. `/dev/wsys/wsysd/state` is
the precedent, and reading a server's own state with `cat` is how the bug
before this one was caught. Counters and not `WSYSWL_VERBOSE=1`, whose
line-per-commit filled the initramfs tmpfs and silenced the guest console
inside two minutes, twice.

`MAXOBJ` went 256 → 1024 in the same pass. Nothing hit it — `max_object_id 97`
under Steam — but an id at or above `MAXOBJ` is an object that is unknown for
the rest of the run, and it is counted now rather than guessed at.

#### The second fault, found on the way and fixed with it

A v2 backbuffer slot carries its own `w/h`; `user/linux-wsys.c`'s `bb_blit`
writes rows at THAT width and `user/wsysd.ad`'s `paint_backbuffer` re-rows them
at the WINDOW's width. **Two authorities for one stride, and nothing checked
they agreed.** When they did not, the scanout showed the client twice side by
side at half height with everything below row h/2 gone — for a rootful
Xwayland, a whole X session that painted once and never moved again.

They came apart two ways, both now closed: a **stale slot** (the segment is a
file that outlives the process, and a killed client never releases its slot, so
the next run's window takes the same low wid and inherits its size), and
`bb_resize` beginning `if (!bb) return;`, which made it a no-op in any process
that had not blitted yet — exactly when `wsyswl` sends the geometry it
deliberately sends first. `bb_for` now re-fits any slot whose size disagrees
with its window, reclaims the slots of windows that no longer exist before
declaring itself full, and names every remaining failure once.

#### The test that outlives the bug

`tests/linux/wsyswl_stall.sh` — the whole chain offscreen against the host's
Xwayland, three minutes, no VM and no Steam. An `xterm` moved and resized 40
times, then the stride mismatch **planted by hand** to prove the next blit
notices. 11 PASS; without the `linux-wsys.c` change the planted fault is never
corrected and never mentioned, which is the two FAILs it exists to produce. It
pins `HAMWSYS_BB` into its own work directory (the default is one file per
HOST — two agents sharing it hand each other stale slots, which is how this was
found) and forces the software Vulkan ICD.

Firefox, the existing native-Wayland client of this same path, still renders
its full chrome through it: 13514 commits, zero drops
(`build/steamprobe/firefox_wayland_offscreen.png`).

### 6.3 What is left, and what it would take

> **Answered.** §6.2a is the answer: it was `MAXMAP`, the first suspect below.
> The list is kept because the elimination in it is still true and still worth
> what it cost.

**This is where the work stops today.** What has been eliminated is worth as
much as what has not, so, plainly:

* it is **not** the X screen size (1280x800, 96 dpi, measured),
* it is **not** a missing window manager or a missing `_NET_WORKAREA`
  (matchbox is up, EWMH is complete, measured),
* it is **not** our window path (a real Chromium goes down it and lands its
  pixels on the framebuffer, measured),
* it is **not** CEF's GPU process (disabled by Steam's own switch, errors
  gone, window tree unchanged, measured).

All three of the measurements this section used to ask for have now been run,
and two of them came back the opposite way round:

1. **Is `MapWindow` ever issued?** Yes. `xev -root` counted 2 MapNotify, one of
   them `Sign in to Steam`. (An `xtrace` proxy was set up too and is not needed
   for this answer; two traps in it are worth keeping: `command -v xtrace`
   finds GLIBC's unrelated program of the same name, and the X11 one exits 255
   having printed only `xauth remove terminated with exit code 1!` when `xauth`
   is missing.)
2. **matchbox.** Convicted. It is why every window read `IsUnMapped`, and the
   session no longer starts it. The session now starts `jwm` instead of
   starting nothing — see §6.2 and `docs/linux_window_manager.md`; that is a
   change to what a desktop in the namespace can do, not to this diagnosis.
3. **The system bus.** It comes up and answers. Retired as a suspect.

**What is left is one hop, and it is ours.** The X screen has a fully painted
`Sign in to Steam` on it and the framebuffer does not. The suspects, in the
order they are cheapest to test:

* **CONVICTED — see §6.2a. wsyswl stops delivering the rootful Xwayland
  surface.** `commit_buffer`
  has four silent `return`s and any of them would produce exactly this: `mi <
  0` when `map_alloc` runs out of its **16** per-connection mappings,
  `pos + rowbytes > maplen` when a pool grew without the mapping following,
  `slot < 0` when the window lost its wsysd slot, and `configured == 0` on the
  xdg surface. Each one needs a name in a log rather than a bare `return` —
  this is the tree's own recurring shape, a gap answering silence.
  **`WSYSWL_VERBOSE=1` is not the way to find out which**: it prints a line
  per commit into `/var/log/wsyswl.log`, which is the initramfs tmpfs, i.e.
  the VM's RAM, and the guest console went silent inside two minutes of Steam
  starting in two separate boots. Count and rate-limit instead — one line the
  first time each `return` fires, and a total at exit.
* **`MAXOBJ` is 256 per connection.** Xwayland is a far larger client than
  anything this server has carried; `valid_id` refuses an id at or above 256
  and the object is then silently unknown for the rest of the run.
* The control is already written and costs nothing: put an `xterm` in the same
  session, let it paint, and then MOVE it. If the scanout does not follow the
  move, the whole surface is stale and no part of this is about Steam.

---

## 7. `enter debian { … }` from the desktop session — solved

The single most user-visible defect found, and it had nothing to do with
Steam. `etc/rc.de-user.linux` drops the session to uid 1001, and `enter`
performs `unshare(CLONE_NEWNS)` + `mount(2)` + a root switch, all of which
need `CAP_SYS_ADMIN`. The namespace was not entered, the body ran in the
**native** root, and the exit status was **0** — the tree's own recurring
failure shape. Commit 526a168e made that fail loudly with 126 instead, which
was honest but still did not work.

**It works now.** The acceptance test is `tests/linux/enter_user_run.sh`, which
drops to 1001 exactly the way the session does and then enters:

```
[enteruser] --- as the session user (uid 1001)
enteruser: PASS this is Debian 12.15
enteruser: INFO uid=1001 user=live
enteruser: PASS unshare -U (CLONE_NEWUSER) from inside the namespace
enteruser: PASS bwrap --unshare-user builds a container
[enteruser] --- uid 1001 enter status: 0
```

Three changes made it work, all in `user/linux-syscalls.c`:

* **The privilege is created, not required.** A `mount(2)` that fails `EPERM`
  makes a user namespace the caller owns and retries. Lazily, on the first
  failing bind — `RFPROC|RFFDG|RFNAMEG` is on *every* spawn in this tree and
  `ls` has no use for a user namespace.
* **`bind '#distro' /` binds the mount that already exists.** `etc/rc.boot`
  mounts the Debian filesystem at `/n/distro` while it is still root; mounting
  the same block device a second time was always questionable and is flatly
  impossible for anyone but real root, because no user namespace can grant a
  real filesystem mount. The device is looked up in `/proc/self/mountinfo`
  and bound from where it already is.
* **The new root is `MS_MOVE`d onto `/`** rather than chroot'd into — §5.

**The uid mapping is the identity, and that is a security property.** Mapping
1001 → 0 would be the conventional rootless-container choice and it would
break `user/linux-wsys.c`'s uid gate wide open: that gate asks whether
`geteuid()` equals the owner of the `/srv/wsys` segment, and inside a
1001 → 0 namespace both sides read 0, so the session would be handed the lock
screen and the spawn queue. Measured with the identity map instead:

```
gate: before-userns: geteuid=1001  stat(/srv/wsys).st_uid=0      -> not host owner
gate: in-userns:     geteuid=1001  stat(/srv/wsys).st_uid=65534  -> not host owner
```

It fails **closed** — root's segment is not in the map, so it reads back as
`nobody` — and the harness arm where the segment belongs to 1001 itself still
recognises its owner, because 1001 maps to 1001. `tests/linux/wsys_uidgate.sh`
passes unchanged. There is no conflict with bubblewrap: bwrap does not need to
be uid 0 inside, it needs its uid to *be mapped*, which the identity map does.
And a process that is already root never escalates at all — its mounts
succeed, and `ns_privilege()` refuses outright for `geteuid() == 0`.

Inside `enter debian` the question is moot anyway: `enter_root` carries
`/dev /proc /sys /n` into a subtree namespace but **not** `/srv`, so
`enter debian { ls -l /srv }` prints `total 0` — the empty tmpfs the
template's own `bind '#s' /srv` just mounted.

---

## 8. Audio: what is actually missing

Not the userland. `libpulse0:i386` is installed, so Steam's audio links; a
PulseAudio server is installed too. What is missing is **the device**:

```
steamprobe: FAIL no /dev/snd -- the VM has no sound device and no snd modules
steamprobe: FAIL no PulseAudio server socket at /run/pulse/native
```

`scripts/hamlinux_vm.sh` adds no `-device` for audio at all, so there is no
sound hardware for a driver to bind. `user/linux-syscalls.c` serving
`/dev/audio` is the *Hamnix* side of this and is not reachable from the Debian
namespace, whose root is the Debian tree — the same boundary as §4. Three
things are needed and none of them is written: a sound device in the VM
(`-device intel-hda -device hda-duplex` or virtio-sound), the ALSA modules in
`/etc/modules`, and a server started in the session. Steam runs without audio;
it will simply be silent.

---

## 9. The gaps that stopped things dead, and were fixed

Each of these was invisible until something large needed it. All are fixed in
`etc/rc.boot.linux`, and all of them fix Firefox and any other big client too,
not just Steam.

| Missing | Symptom |
|--|--|
| `/dev/fd` (and `/dev/std{in,out,err}`) | bash process substitution `<(...)` fails. Steam's runtime `setup.sh` uses it: `setup.sh: line 131: /dev/fd/63: No such file or directory` — from a script that is plainly there. |
| `/dev/shm` | Chromium — which **is** Steam's UI — cannot map shared memory and dies: `Unable to access(W_OK\|X_OK) /dev/shm`. Steam's controller subsystem fails first and more quietly. |
| loopback address | nothing brought `lo` up, so `127.0.0.1` was unassignable and Steam's own IPC reported `socket bind failed: Cannot assign requested address`. Note that `sys_netcfg` takes the interface from `$HAMNIX_IFACE`, **not** from `ifconfig`'s first argument, so `ifconfig lo …` alone would have configured `eth0`. |
| `dbus-x11` | `steam-runtime-launcher-service` exits on startup — `Can't find session bus: Failed to execute child process 'dbus-launch'` — and retries until it disables itself. `dbus` does not pull `dbus-launch` in. |
| a passwd entry for uid 1001 | the session runs as 1001, and without an entry in the *namespace's* `/etc/passwd`, `getpwuid(getuid())` returns NULL and Steam cannot find its own data directory. Created by the build. |
| the build host's `/etc/resolv.conf` | mmdebstrap copies it in, and the build host's nameserver is unreachable from the VM — so DNS in the namespace timed out while the network was fine, and it looked like Steam being broken. |

Two more worth writing down because they cost time and are not Steam's fault:

* **The namespace's `/tmp` is on disk and survives reboots.** `enter_root`
  deliberately does not carry the Hamnix tmpfs across. So an X server killed by
  a power cut leaves `/tmp/.X0-lock` behind for ever, and the next boot gets
  `Fatal server error: Server is already active for display 0`.
* **Waiting for the socket is not waiting for the server.** The stale
  `/tmp/.X11-unix/X0` outlived the server that made it, so a `[ -S ... ]` check
  reported an X server that was not running — and the session then exec'd Steam
  into a display that did not exist. `tests/linux/hamnix_x11session.sh` now
  connects with `xdpyinfo` instead.

---

## 10. How to reproduce

```sh
scripts/hamlinux_distro.sh                    # multiarch image, prints the size delta
tests/linux/wsyswl_stall.sh                   # does the compositor KEEP delivering
                                              # a surface? OFFSCREEN, 3 minutes,
                                              # no VM and no Steam (§6.2a)
tests/linux/x11_geom_probe.sh                 # the window path, OFFSCREEN, no VM at all
tests/linux/steam_probe_run.sh                # the 24-check scoreboard, headless
tests/linux/steam_gui_run.sh \
    "/usr/local/bin/hamnix-x11session /usr/bin/glxgears" out.png 60
tests/linux/steam_gui_run.sh \
    "/usr/local/bin/hamnix-x11session /usr/local/bin/hamnix-steam" steam.png 330 250
```

The GUI harness plants its session scripts into the namespace image with
`debugfs` rather than rebuilding 2 GB to change 2 KB. One trap in that: `rm`
and `write` **must be separate debugfs invocations with an fsck between**, or
the new directory entry keeps the old inode's type and you get a zero-length
symlink where a script should be — whose only symptom is
`hamsh: command not found` on a path that plainly exists.

**No Steam was installed on the dev host.** The build downloads Valve's
`steam_1.0.0.75.tar.gz`, verifies its sha256 against the value in Debian's own
`/usr/games/steam`, and unpacks the bootstrap **into the image**. Nothing from
it is executed on the host. No host packages were installed for any of this
work.

**One artefact in the built image, deliberately left:** `/home/live/.steam` is
a symlink to `/.steam`. The first Steam run happened before `$HOME` was pinned
(§9), so the 2.5 GB client landed at the root of the namespace; the symlink
points the corrected `$HOME` at it rather than making every subsequent test
re-download it. A freshly built image has neither, and Steam will install to
`/home/live/.steam` on its own.

---

## 11. Running any of this without clobbering another agent's image

`build/` is NOT isolated by a git worktree — it is symlinked back to the one
tree — so `scripts/hamlinux_image.sh` and every `debugfs` plant in
`tests/linux/steam_gui_run.sh` write the SHARED `build/image/distro.ext4`.
Two agents doing that at once destroy each other's runs silently, and did.

What the measurements in §6.2 used instead, and what the next pass should use:

* A private image directory (`/home/david/.hamnix-build/<tag>/image`) holding
  a copy of `vmlinuz` and `initramfs.cpio.gz` and a **symlink** to the shared
  `distro.ext4`, with `build/image` in the worktree pointed at it. Every
  script here resolves `build/image` relative to its own `PROJ_ROOT`, so that
  is the whole redirection.
* `HAMLINUX_DISTRO_RO=1` (dff3d7ed), which attaches the distro media
  `snapshot=on,file.locking=off`. Any number of VMs then share one image and
  **nothing the guest writes survives** — which is also what makes the next
  point safe.
* No `debugfs` at all. Unpack the initramfs, drop the new `rc.boot` and the
  test scripts into `/etc`, repack, and have `rc.boot` `cp` them into
  `/n/distro/tmp/` at run time. The writes land in the throwaway overlay.
  Invoke them as `/bin/sh /tmp/x.sh`, because the image has no `chmod`.
* `TMPDIR` on `/home`. QEMU puts the `snapshot=on` overlay in `TMPDIR`, and
  `/tmp` on this host is a 16 GB tmpfs, i.e. the owner's RAM.
* `HAMLINUX_VNC=none`, and never `pkill` a QEMU by pattern: every VM in this
  tree has the same argv. `quit` on its own monitor socket is how a run ends.

Two more, learned in the pass that closed §6.2a:

* **`build/` is not always the shared one.** In this worktree it was an empty
  private directory, so the whole redirection was `mkdir build/image` and a
  symlink to the shared `distro.ext4` and `alpine.ext4`; every script resolves
  it from its own `PROJ_ROOT`. `scripts/hamlinux_image.sh` then writes a
  private `vmlinuz` (copied from the host's `/boot`) and `initramfs.cpio.gz`,
  and nothing shared is written at all. Check which you have before assuming.
* **The scripts go in as a SECOND CPIO SEGMENT, which is simpler than either
  debugfs or unpack-and-repack.** The initramfs loader unpacks concatenated
  gzipped `newc` archives in order, so
  `find etc | cpio -o -H newc | gzip >> build/image/initramfs.cpio.gz` adds
  files to `/etc`, and `rc.boot` copies them into `/n/distro/tmp/` at run time
  where `HAMLINUX_DISTRO_RO=1` puts the write in the throwaway overlay.
* **`HAMWSYS_BB` is the third shared file, and it bit.** The v2 backbuffer
  segment defaults to `/srv/wsys.bb`, then `/dev/shm/hamnix-wsys-bb`, then
  `/tmp/hamnix-wsys-bb` — one per HOST, with slots keyed by wid and no owner.
  An offscreen run inherited another run's slot, at another window's size, and
  spent an hour looking like a compositor bug. Pin it per run.

---

## 12. PAST THE LOGIN SCREEN — how far Steam actually gets

**What this section replaces.** §6.2a ends at *"the `Sign in to Steam` window
is on the framebuffer"*, and for three passes that sentence stood in for
"Steam works". It does not. A window that renders and cannot be typed into is
a screenshot. So the window was **driven** rather than photographed, and the
answer is much better than the notes said and has one concrete hole in it.

**How it was driven, and why not with the existing harness.**
`tests/linux/steam_gui_ro.sh` boots, waits, screendumps once and quits.
`tests/linux/steam_login_drive.sh` boots the same session and **leaves the VM
up** with a QMP socket and the console shell on a fifo, and
`tests/linux/qmp_input.py` puts pointer and key events on QEMU's own
`virtio-tablet-pci` / `virtio-keyboard-pci`. In a VM that is the **only**
input `wsysd` has — it scans `/dev/input/event0..15` — so every event below
travelled the whole chain:

```
QEMU virtio-tablet/keyboard -> /dev/input/eventN -> wsysd -> /dev/wsys/<wid>/pointer,keys
  -> wsyswl (wl_pointer / wl_keyboard) -> Xwayland -> jwm -> Steam's CEF
```

Nothing wrote a wsys ring by hand. That is the rule
`tests/linux/de_mouse_chrome.sh` sets for the DE chrome, applied to a real
X11 application three servers further down. Every number below is a pixel
count from `tests/linux/ppmdiff.py` over two QEMU screendumps.

### 12.1 The scoreboard, in the order it was measured

| Step | Result | The measurement |
|--|--|--|
| the login window is on screen | **works** | non-black bounding box of the framebuffer is `699x440+290+180` — the same rectangle §6.2 reported, now found by scanning pixels rather than by asking X |
| the pointer moves | **works** | the 12x17 cursor sprite left `+640+400` and appeared where it was sent |
| Steam sees the pointer | **works** | moving over the username field repainted **97% of that field** — CEF's hover state. `wl_pointer.motion` reached the DOM |
| a click focuses a field | **works** | a caret, then `3.46%` of the window repainted |
| **typing** | **works** | `hamnix` typed on QEMU's keyboard **appears in Steam's username field** |
| the password field masks | **works** | `secret123` → nine dots, `97%` of that field repainted |
| a checkbox toggles | **works** | *Remember me* cleared, `97.7%` of the 22x22 box changed, and its hover tooltip drew |
| **a second window, and navigation** | **works** | *Create a Free Account* replaced the 700x440 login window with an **~870x740 browser window** on the Steam store — `93.8%` of the old rectangle changed |
| remote web content | **works** | that page loads the store chrome, an **hCaptcha** iframe and its assets, over the namespace's own network |
| a dropdown menu | **works** | the store's *Browse* mega-menu opened: `99.99%` of the 260x300 column below it changed, with the CDN capsule artwork in it |
| navigating the store | **works** | *Store Home* loaded the real front page — Counter-Strike 2 artwork, review counts, the discount carousel |
| dragging | **works** | press-move-release on the page's scrollbar scrolled it: `96.44%` of an 830x680 rectangle changed |
| **search, and live results** | **works** | `portal` typed into the store search box returned Portal, Portal 2, Portal Knights and Portal Worlds with prices and cover art, over the network, as an AJAX response |
| **the scroll wheel** | **works — see 12.2d** | it was **ours**: `wsyswl` answered every wheel line with a `wl_pointer.motion` the pointer never made, Xwayland routed that to a different slave device from the axis, and the resulting `XI_DeviceChanged` before every scroll motion reset Chromium's per-device valuator baseline — so every delta was zero. Eight notches now move **97.41%** of the store page and eight back return it to `IDENTICAL (0 of 564400)`. |

`build/steamprobe/` is not where these live; the run's screendumps are under
`~/.hamnix-build/steamdrive/shots-run1/` (`s0.png` the login window, `s3_typed.png`
the typed username, `s6_create.png` the second window, `s11_store.png` the
store, `s16.png` the search results).

**So the honest one-line answer is the opposite of the one this file used to
imply:** Steam is not stuck at its login screen. Everything reachable
*without an account* — the login form, account creation, the whole store,
search — works, with a mouse and a keyboard, on this distribution.

### 12.2 THE FIRST CONCRETE BLOCKER: the scroll wheel was never connected

**The measurement.** With the pointer resting over Steam's store page, eight
`REL_WHEEL` notches:

```
diff 830x680+214+80: IDENTICAL (0 of 564400 px)
```

**And the control that makes it mean something.** The same pointer, on the
same page, pressed on the scrollbar, moved 240 px and released:

```
diff 830x680+214+80: 544328 of 564400 px (96.44%) differ
```

The page was scrollable. The wheel was not connected to it. A dead pointer
would have produced the same zero, and the control is the only thing that
rules it out.

**What was wrong.** `user/wsysd.ad` has had the whole wheel since its input
pump was written: `pump_input` accumulates `EV_REL`/`REL_WHEEL` into
`ptr_dz`, `deliver_pointer` gives the routed line kind `'s'` for scroll, and
`route_pointer` writes the delta as the **fifth** field of
`<kind> <x> <y> <buttons> <dz>`. `user/wsyswl.ad`'s `handle_ptr_line` parsed
the first four fields and stopped, and the file contained no
`wl_pointer.axis` at all. So the delta was computed, routed, written to the
ring, read back — and dropped on the floor one parse short of the client.

That is not a Steam bug and it was never about Steam: **every** Wayland
client behind this compositor, and through Xwayland every X11 client behind
that, has had a dead scroll wheel for the whole port. Firefox in the
namespace, a text editor, a file manager — all of them.

**The fix** is three events and a version gate: `wl_pointer.axis` (version 1,
always safe), plus `axis_source` and `axis_discrete` (version 5) gated on the
version the client **bound `wl_seat` at**, not on the version this server
advertises — libwayland aborts on an event a proxy has no listener slot for,
which is the trap `wl_seat.name` was already gated for. The sign is inverted
on purpose: evdev `REL_WHEEL` is positive away from the hand, and
`wl_pointer.axis` is positive in the direction the content moves.

**The gate: `tests/linux/wsyswl_wheel.sh`.** Offscreen, ~40 s, no VM and no
Steam: a file of evdev records → `wsysd` → `wsyswl` → a real rootful
Xwayland → `xev`, which prints what the **X server** delivered. An X11 wheel
is button 4 (up) and button 5 (down), so one `xev` line is the whole chain.
**10 PASS.** With the fix stashed and nothing else changed it is **6 PASS /
4 FAIL**, and the four are the wheel ones — the control (an evdev *move*
arrives as `MotionNotify`) still passes, so the file reports a dead wheel and
not a dead pointer. It also asserts the **count** (four notches → exactly
four button-5 presses) and the **sign** in both directions, because a wheel
that scrolls backwards works and is wrong, which is worse than a dead one:
nothing about it looks broken.

### 12.2a AND THE FIX IS NOT SUFFICIENT — Steam still does not scroll

**This is written down because the alternative is a success-shaped answer.**
The gate above is real: it fails without the fix and passes with it, against
a real Xwayland. The fix is in the image — the staged `/bin/wsyswl` md5-matches
the patched build. And a second full Steam run, all the way back to the store
front page, wheeled over it:

```
diff 830x680+214+80: IDENTICAL (0 of 564400 px)
```

**Byte for byte the same zero as before the fix.** So `wl_pointer.axis` was
missing AND something else on the VM path also drops the wheel. Closing one
hole did not open the pipe.

**The obvious suspect was QEMU, and it is not QEMU.** The offscreen gate
writes evdev records into a *file*; the VM has `virtio-tablet-pci` writing
them into a *device node*, and that is the one thing the two arms do not
share. `tests/linux/vm_wheel_reaches.sh` asks the compositor directly — the
desktop alone, no Steam and no namespace, with `wsysd`'s own
`/dev/wsys/wsysd/state` published on the serial line by `rc.boot`. Its
`pointer` field counts `deliver_pointer` calls, and `deliver_pointer` returns
early unless something changed **including a non-zero `ptr_dz`**, so with the
cursor held completely still that counter is a wheel detector:

```
pointer  0 ->  2     two QEMU pointer MOVEs        (the control)
pointer  2 -> 22     twenty wheel events, cursor STILL
```

**Exactly twenty.** So QEMU's `virtio-tablet-pci` does deliver
`EV_REL`/`REL_WHEEL` to this guest (`wheel-axis=on` is its default),
`pump_input` accumulates it, `deliver_pointer` runs for each one, and
`route_pointer` writes an `'s'` line with the delta to the window under the
cursor. **Everything upstream of `/dev/wsys/<wid>/pointer` is ruled out, and
the remaining hole is ours.**

**What is left, stated as the narrow thing it now is.** The routed line
reaches the ring and the client does not scroll, while the identical code
path with a *different* Xwayland does. Two candidates were named. One of them
has since been **tested and eliminated**:

1. **Event order inside the frame — TRIED, AND IT IS NOT THIS.**
   `wl_pointer.axis_discrete` was being emitted *after* its `axis` event; the
   protocol says it "shall be sent before the corresponding
   wl_pointer.axis event". That was wrong and is now fixed (the gate is still
   10 PASS with the corrected order). A **third** full Steam boot, staged
   binary timestamped after the source change, navigated back to the store
   front page (124587 distinct colours in the page rectangle — it is loaded)
   and wheeled over it:
   ```
   diff 830x680+214+80: IDENTICAL (0 of 564400 px)
   ```
   The order was a real protocol violation worth fixing on its own. It is not
   what is stopping the scroll.
2. **Xwayland's version — the one still standing.** The passing arm is the dev
   host's Xwayland (trixie, 24.x); the failing arm is the namespace's
   **22.1.9** (bookworm). The gate is therefore measuring a *newer* server
   than this distribution ships, which is a gap in the gate as much as a
   hypothesis about the bug: **the next thing to do is make
   `wsyswl_wheel.sh` run against 22.1.9** — the namespace has one, so the arm
   can be added — and only then look further up.

**The honest state after three Steam boots:** two real defects found in
`wsyswl` (no `wl_pointer.axis` at all; `axis_discrete` in the wrong order),
both fixed, with a gate that fails on revert — and the user-visible symptom
that found them **still present in the VM**. The search space is narrowed
from "the whole input stack" to "`wsyswl`'s axis emission as seen by Xwayland
22.1.9", by measurement rather than by argument, and the gate's own blind
spot is now named.

### 12.2b THE VERSION WAS NOT IT, AND THE WHEEL NOW MOVES REAL PIXELS IN A VM

**Both candidates §12.2a left standing are dead, by measurement.**

**1. Xwayland 22.1.9 behaves exactly like 24.1.6.** `scripts/ns_xwayland.sh`
lifts the namespace's own `/usr/bin/Xwayland` out of `build/image/distro.ext4`
with `debugfs` together with its `DT_NEEDED` closure and runs it through that
image's own loader and libraries. No mount, no loop device, no root, no write
to the shared image; about 16 MB and a second. (`debugfs dump` does not follow
symlinks and every soname in a Debian lib dir is one, so links are chased off
`stat`, and the extraction is verified by running `Xwayland -version` rather
than assumed — a closure one library short yields a wrapper that exists and
cannot run.) `tests/linux/wsyswl_wheel.sh` now runs every assertion against
both servers:

```
wheel: ===== arm: namespace (…/ns-xwayland/Xwayland) on :87
wheel: PASS [namespace] … Xwayland Version 22.1.9 (12201009) is on it at :87
wheel: PASS [namespace] four notches produced exactly four button-5 presses
…
wheel: ===== arm: host (/usr/bin/Xwayland) on :88
wheel: PASS [host] … Xwayland Version 24.1.6 (12401006) is on it at :88
wheel: 30 passed, 0 failed
```

**2. And a blind spot found on the way, which was the better hypothesis and is
also not it.** The gate only ever asked `xev`, and `xev` reads **core** X
events. Chromium — the whole of Steam's user interface, and Firefox's fallback
— does not: it calls `XISelectEvents` and reads the wheel off an XInput2
**scroll valuator**. Those are two paths out of one X server fed by one
`wl_pointer.axis` and one can be dead while the other is perfect, which would
have explained "green gate, dead Steam" exactly.
`tests/linux/xi2_scroll_probe.c` asks it: a second client, its own window, its
own pixel, in the same run. **The valuator moves, on both servers, with the
sign right in both directions.**

**3. THE STRETCH NOTHING MEASURED, AND IT WORKS.** `wsyswl_wheel.sh` is the
compositor half on the dev host; `vm_wheel_reaches.sh` is QEMU's half into
`wsysd`. They meet in the middle and nothing covered the join: QEMU's evdev
node → `wsysd` → `wsyswl` → the namespace's *own* Xwayland → an X client, all
inside one VM. `tests/linux/vm_wheel_client.sh` is that, in ~4 minutes, with no
Steam and no CEF — two programs out of the namespace's own `/usr/bin`:

```
vmwc: PASS CONTROL: a QEMU pointer MOVE reaches the X client in the namespace (4 MotionNotify)
vmwc: INFO MotionNotify 4 -> 14, button-5 presses 0 -> 6, button-4 0 -> 4
vmwc: PASS SIX WHEEL-DOWN NOTCHES REACH THE X CLIENT AS BUTTON 5 in a real VM (0 -> 6)
vmwc: PASS and four wheel-UP notches reach it as button 4 (0 -> 4)
vmwc: INFO pixels changed in 48x330+10+40 of 15840: up 415, back down 415, net 0
vmwc: PASS EIGHT WHEEL-UP NOTCHES MOVED THE PIXELS OF A REAL PROGRAM: 415 of 15840 changed
vmwc: PASS CONTROL: eight notches back DOWN moved them again (415 of 15840)
vmwc: PASS and the screen RETURNED to where it started (0 of 15840 differ)
vmwc: 9 passed, 0 failed
```

The reversal is the control, and it is stronger than the scrollbar drag that
§12.2 used: a repaint, a cursor blink or a clock ticking can make two
screendumps differ, and nothing but content that really scrolls and really
scrolls back makes A≠B, B≠C **and** A=C.

**Two ways that file answered a success-shaped zero before it answered the
truth, both kept in its comments.** Its first diff rectangle was 400x240 over
the *blank* right-hand side of the terminal — `seq 1 3000` writes four-digit
numbers in the leftmost ~45 pixels — and read `0 of 96000` while the terminal
behind it scrolled perfectly. And its first wheel direction was **down**, at a
terminal already sitting at the bottom of its scrollback: a correctly working
wheel with nowhere to go, reading identically to a dead one.

**WHAT THIS DOES NOT SAY.** Steam has not been re-measured. What is now proven
is the whole compositor chain, end to end, to a real client's pixels, in the
real VM, on the Xwayland that actually ships. Whether Steam's CEF scrolls is a
separate measurement and nobody has taken it since these fixes landed — say so
rather than assume it, in either direction.

*(That measurement has since been taken. It is §12.2c, and the answer is no.)*

### 12.2c STEAM STILL DOES NOT SCROLL — AND AN `xterm` IN THE SAME SESSION DOES

**This is the measurement §12.2b said nobody had taken.** A fourth full Steam
boot, on the current tree, driven back to the store front page and wheeled
over — the same page, the same eight notches, the same `830x680+214+80`
rectangle as the `0 of 564400 px` that started all of this, so the numbers are
directly comparable. Then, **without rebooting and without touching the
compositor**, a second X client was put into the *same* X session and given
the identical wheel events.

| what the wheel was over | 8 notches one way | 8 notches back | net |
|--|--|--|--|
| **Steam's store page**, `830x680+214+80` | `IDENTICAL (0 of 564400 px)` | `IDENTICAL (0 of 564400 px)` | — |
| **Steam's store page**, second position, mid-page | `IDENTICAL (0 of 564400 px)` | `IDENTICAL (0 of 564400 px)` | — |
| **Steam's store page**, third position, after the xterm was up | `IDENTICAL (0 of 240000 px)` | `IDENTICAL (0 of 240000 px)` | — |
| **`xterm`, same session, same minute**, `40x350+16+30` | **471 of 14000 px (3.36%)** | **471 of 14000 px (3.36%)** | **`IDENTICAL (0 of 14000 px)`** |

The xterm went from showing lines 2974–3000 to lines 2934–2961 and back — 40
lines up, 40 lines down, eight notches of five lines each, exactly as a wheel
should. The Steam window **behind it** is byte-identical across the same three
screendumps.

**THREE CONTROLS, ALL IN THAT RUN, BECAUSE A ZERO PROVES NOTHING ON ITS OWN.**

1. **The page is quiet.** Two screendumps 15 s apart with no input at all:
   `diff 830x680+214+80: IDENTICAL (0 of 564400 px)`. So the rectangle has no
   noise floor — the featured carousel was not rotating under the measurement,
   and a change of *any* size would have been real. This control is new here
   and it cuts both ways: it is also why the zeros above cannot be an artefact
   of a screendump that never refreshed.
2. **The pointer is alive and the framebuffer tracks it.** A plain move:
   `244 of 1024000 px differ; bbox 543x687+500+20` — the cursor sprite left
   where it was and arrived where it was sent. A dead pointer produces the
   same zero as a dead wheel, and this is the only thing that separates them.
3. **The page is scrollable by something else.** Press–move–release on that
   page's own scrollbar, 240 px:
   `diff 830x680+214+80: 476499 of 564400 px (84.43%) differ`. The store front
   page then really was at its footer. So "nothing moved" means the wheel is
   not connected to *this client*, not that there was nowhere to go.

**And the reversal, which is stronger than the drag.** Down-then-up on Steam
gave A=B=C, which is the shape of nothing happening. Up-then-down on the
xterm gave A≠B, B≠C **and A=C** — the triple that only real content that
really scrolls and really scrolls back can produce. Same session. Same wheel.
Same eight notches, ~90 seconds apart.

**SO THE SEARCH SPACE IS NOW ENTIRELY ABOVE THE X SERVER, AND IT IS STEAM'S.**
Everything below is proven in this run, not argued from another one: the same
QEMU `virtio-tablet-pci`, the same `wsysd`, the same `wsyswl`, the same
Xwayland 22.1.9, the same `jwm` — carried a wheel notch to a program's pixels
while Steam's CEF, one window over, did nothing with it. That is as clean a
separation of "our stack" from "Steam" as this port can construct, and it says
our stack is not the problem.

*(All three of those were tried and none of them was it; the answer is §12.2d,
and it was in `wsyswl` after all. The paragraph is kept as written because the
reasoning that produced it was sound and still wrong: every measurement in it
holds, and the conclusion drawn from them -- "our stack is not the problem" --
did not. What the run could not see was that the compositor was ALSO sending
something extra, and the thing it broke was two servers downstream.)*

What this pass thought was left to look at, in the order it recommended, was
Steam's own input handling: CEF's `XISelectEvents` mask on **that** window (the XI2
valuator is proven live at the server — `tests/linux/xi2_scroll_probe.c` — so
the question is whether Steam selects for it), its GTK/SDL scroll settings,
and whether `steamwebhelper` treats the store page's outer frame as a scroll
target at all when the pointer is over page background rather than over a
list. `docs/steam_namespace.md` §12.3's note that the console drops characters
under load is what makes asking Steam's own logs hard, and it is the thing to
fix first if that route is taken.

**One thing seen and not explained, recorded rather than tidied away.**
Between two screendumps about two minutes apart, with **no** pointer, key or
wheel event directed at Steam in between — only console typing that started a
second X client — the store page moved on its own from mid-page to its footer,
roughly 600 px. It is not the wheel (the wheel diffs immediately before and
after are zero), and the most likely reading is a focus change on the new
window making CEF scroll a focused element into view. It is written down
because it is the only unexplained motion in the run.

**How this was run**, so it can be repeated: `tests/linux/steam_login_drive.sh
boot 400` with `SLD_WORK` and a private `build/image` (§11), then the
navigation *Create a Free Account* → *Browse* → *Store Home* by
`tests/linux/qmp_input.py`. The comparison client goes in through the shim
that boot now stages into the namespace:

```
spawn debian { /bin/sh /tmp/de-ns-run xterm -sb -j -hold -geometry 80x40+0+0 -e /usr/bin/seq 1 3000 }
```

`/bin/sh` and not `sh`: `spawn` does not search `PATH`, and with the bare name
the command **fails silently** — no window, no message, nothing on the console.
That cost a boot's worth of time and is exactly the shape this project's
standard of evidence is about, so it is named here rather than left as a
footgun.

### 12.2d SOLVED, AND IT WAS OURS: A `wl_pointer.motion` THE POINTER NEVER MADE

**Steam scrolls.** Same page, same eight notches, same `830x680+214+80`
rectangle as the `0 of 564400 px` that started all of this:

| | 8 notches down | 8 notches back up | A vs C |
|--|--|--|--|
| **before** (§12.2c, and re-measured on the current tree) | `IDENTICAL (0 of 564400)` | `IDENTICAL (0 of 564400)` | — |
| **after** | **549754 of 564400 (97.41%)** | **549754 (97.41%)** | **`IDENTICAL (0 of 564400)`** |
| **after, second boot, independently** | **549379 (97.34%)** | **549379 (97.34%)** | **`IDENTICAL (0 of 564400)`** |

with, in the same run: a **noise floor** of `0 of 564400` over 15 s with no
input; a **pointer control** (a plain move changed 1040 px, bbox on the cursor
sprite); and the **scrollbar-drag control** still moving 96.45% of the same
rectangle. The reversal triple — A≠B, B≠C, **A=C** — is what says the page
really scrolled and really scrolled back rather than merely repainting. With
the pointer over the page's blank left MARGIN rather than over a list, eight
notches moved 99.98%; §12.2c's guess that CEF might ignore the wheel over page
background was not it either.

**THE BUG.** `wsysd` writes a pointer line for every input event, including one
that carries nothing but a `REL_WHEEL` delta with the cursor standing still.
`wsyswl`'s `handle_ptr_line` answered every such line with a
`wl_pointer.motion` at the coordinates the pointer already had. That looks
harmless, and it is not, because of where Xwayland routes the two events —
measured with an XI2 client that selects `XIAllDevices` the way CEF does,
against the namespace's own Xwayland 22.1.9:

```
wl_pointer.axis    ->  slave device 7, 'xwayland-relative-pointer:4'
wl_pointer.motion  ->  slave device 6, 'xwayland-pointer:4'
```

so one notch was `motion(6) -> axis(7) -> motion(6)` and the X **master**
pointer had to switch slaves twice per notch. Every switch is an
`XI_DeviceChanged`. Before the fix, one notch, verbatim:

```
DeviceChanged deviceid=2 sourceid=7 reason=1
Motion        deviceid=2 sourceid=7 valmask= [3]=1.00      <- the scroll valuator
ButtonPress   deviceid=2 sourceid=7 detail=5
DeviceChanged deviceid=2 sourceid=7 reason=1
DeviceChanged deviceid=2 sourceid=6 reason=1
Motion        deviceid=2 sourceid=6 valmask= [0]=7168.00 [1]=26951.68
```

that last line being the motion we invented. After the fix: **one**
`DeviceChanged` at the first event and then none, with the valuator running
`1.00 -> 2.00` on one device.

**WHY THAT KILLS A BROWSER AND NOT AN `xterm`.** A scroll valuator is a
*running total*, so a client that reads the wheel from it keeps a baseline per
device — and must throw that baseline away on `XI_DeviceChanged`, because the
new device's valuator has nothing to do with the old one's. Chromium
(`DeviceDataManagerX11`), which is Steam's entire user interface, does exactly
that. With a `DeviceChanged` before every scroll motion the baseline was
dropped every time, every motion was a first motion, and every delta was zero,
forever. `xterm` reads **core button 4/5**, which none of this touches — which
is precisely why §12.2c saw an `xterm` scroll 471 px in the same X session, in
the same minute, in which Steam's store page moved nothing.

**In the VM, counted:** `XI_DeviceChanged` delivered to Steam's client,
before **332** for 32 notches; after **19** for 16 notches, of which the last
is at t=329.8 s — the first notch of the first burst — and none at all for the
fifteen notches after it.

**AND THE PROBE THAT SAID IT WAS FINE.** §12.2b's headline was "the XInput2
smooth-scroll valuator moves, on both servers, with the sign right in both
directions", and it was measured with `tests/linux/xi2_scroll_probe.c`, which
existed *specifically* to be the client Steam is. It was not shaped like it in
the one way that mattered: it never selected `XI_DeviceChanged` and so never
dropped its baseline. It accumulated straight through the device change that
was resetting the real browser on every notch, and reported a healthy wheel
for four passes. It now does what Chromium does, and
`tests/linux/wsyswl_wheel.sh` is the regression gate:

```
with the fix     30 passed, 0 failed
fix reverted     26 passed, 4 failed
```

and the four are exactly `THE XI2 SMOOTH-SCROLL VALUATOR NEVER MOVED` and its
reversal, **on both arms**, while every core button 4/5 assertion still passes
— the real symptom, reproduced offscreen in 40 seconds: an `xterm` scrolls and
a browser does not.

**What Steam asked for, and what it was told.** Answered by
`tests/linux/x11_record_trace.c`, a RECORD tracer attached before Steam draws
(`XIGetSelectedEvents` cannot answer it: the server filters that request with
`SameClient()`, so aimed at another client's window it returns an empty list
whether that client selected everything or nothing — a probe that says "Steam
selected nothing" no matter what is true). Steam selects XI2 on
`deviceid=0`/`XIAllDevices`, so it receives the slave copy *and* the master
copy of every event, and it was being told everything: with the pointer over
the store page and the wheel turning, the server delivered
`XI2 ButtonPress detail=4/5` **and** `XI2 Motion` to client `0x01600000` on
window `0x1600014` — and the page did not move. "Steam was never told" was
never the answer; "Steam was told, and told to forget, before every single
notch" was.

**Which window the notch landed on.** `xdotool getmouselocation` at the
measured point: window `0x1a0001b`, `"Create Steam Account"`,
`WM_CLASS = "steamwebhelper", "steam"`, 900x800+190+0, a child of the root —
with the CEF render window `0x1600014` (852x744+214+32) inside it, which is the
window the trace shows the events arriving on. The events were landing exactly
where they should.

**Firefox, in the same X session, on the same server, after the fix:** eight
notches over `file:///etc/services` moved **52547 of 280000 px (18.77%)**, eight
back moved the same, and A=C `IDENTICAL (0 of 280000)`, with a `0 of 280000`
noise floor. The second browser engine agrees.

*(Firefox took two runs to launch, and the first failure is worth the line it
takes: `Running Firefox as root in a regular user's session is not supported.
($HOME is /home/live which is owned by live.)` — printed, and then **exit 0**.
A launcher reporting success with no window. It was caught only because the
harness puts the program's own stderr on the serial console.)*

**Cost of the search, and the one line that would have shortened it.** Four
passes looked below the X server because a probe built to model Chromium said
the smooth-scroll path was healthy. The probe was green and the program was
dead, and the difference between them was a single event type nobody had
thought to select. When a stand-in for a program disagrees with the program,
the stand-in is the thing to doubt first.

### 12.3 Two things seen in passing that are NOT the blocker

* **`wsyswl` printed `DROPPING FRAMES -- the wl_buffer has no shm mapping`
  once**, when Steam's second (store) window appeared — the `MAXMAP` counter
  of §6.2a, now at 64, brushed again by a session holding two CEF windows.
  It did not stop anything: every interaction after that warning — the Browse
  menu, two navigations, the scrollbar drag and the live search — repainted
  normally. Worth watching, not the thing in the way. The exact counters
  could not be read off this run, for the next reason.
* **The console shell drops typed characters under load.** Driving the guest
  console over a fifo while Steam is writing to the same serial line, `hamsh`
  echoed `cat /n/distro/run/wsyswl-state` as far as `cat /n/distr` and then
  ran *that*, reporting `cannot open /n/distr`. It is not a lost newline —
  the line was truncated mid-word. This is why §12.1 is measured entirely
  from the framebuffer rather than from inside the namespace, and it is its
  own defect, unrelated to Steam and not chased here.

### 12.4 What was deliberately not attempted

**No Steam account was used and none was sought.** Everything above is what
the client does with no credentials. Not measured, and each needs an account:
signing in, the library view, downloading or launching a game, the friends
list, the overlay. `pressure-vessel`'s container comes up (§5) and
`steamwebhelper` runs inside it, but no *game* has ever been started here and
this section does not imply one would.
