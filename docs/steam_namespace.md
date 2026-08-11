# Steam-class applications in the Debian namespace

**What was asked:** *"I want even large apps to be able to run from the debian
NS, like steam."* Steam is the right target because it exercises everything at
once — 32-bit multiarch, a container runtime, a GPU stack, audio, and an X11
window path — and because each of those fails differently.

**Where it stands, in one line:** the Steam client **runs** in the namespace,
installs itself, brings up its pressure-vessel container, and — with no window
manager in the session — **maps and paints its login window on the X screen**.
What is not there yet is the last hop: those pixels do not reach the Hamnix
framebuffer, because the rootful Xwayland surface stops being delivered
through `wsyswl`. That is our code, and §6.2 says exactly how it was measured.
Everything below is measured in the VM.

---

## 1. What a run looks like today

```
enter debian { steam }
```

from the **console** (uid 0) gets you: the launcher, a ~2.5 GB client
download, the sniper container, `steamwebhelper`, and a Steam UI that logs
`SteamApp Init - Before Login` — and no window you can see. The window itself
exists and is drawn; it is on the X screen and not on the framebuffer (§6.2),
so what a person typing this sees today is a black area where Steam is.

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
| Steam UI window, in X | **works** | with no window manager, `Sign in to Steam` is `IsViewable` at 700x440+290+180 and `xwd -root` finds 210 distinct colours inside it — the UI is drawn — §6.2 |
| Steam UI window, on the framebuffer | **not yet** | the same screendump has the control `xterm` on it and nothing where Steam's window is: the rootful Xwayland surface stops being delivered through `wsyswl` — §6.2, §6.3 |
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

### 6.3 What is left, and what it would take

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

* **wsyswl stops delivering the rootful Xwayland surface.** `commit_buffer`
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
