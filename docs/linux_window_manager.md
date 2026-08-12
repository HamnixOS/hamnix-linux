# The window manager inside a distribution namespace

`enter debian { … }` and `enter alpine { … }` each run an X session on top of
the Hamnix Wayland server (`user/wsyswl.ad`) through a **rootful** Xwayland.
Something has to manage the windows on that X screen. This is the record of
what was chosen, what it was chosen over, and what each of them costs —
measured against the two images this tree actually builds, not against a
package list.

**Answer: `jwm`, in both namespaces, with one configuration file
(`etc/jwmrc.linux` → `/etc/jwm/hamnix.jwmrc`) that both build scripts install.**

---

## 1. The question, and the two wrong answers that came before it

The session had `matchbox-window-manager`, and matchbox is convicted. Measured
one boot each, same image, same rc, only the WM differing: with matchbox the X
root has **one** child — matchbox's own 5×5 check window — and every Steam
window reads `IsUnMapped`; with no WM the root has **ten**, including
`"Sign in to Steam" 700x440+290+180 IsViewable` with its full Chromium render
subtree. matchbox is a single-window handheld window manager: it takes over
every `MapRequest`, makes the newest window the one and only one, and the
login dialog is then destroyed. `docs/steam_namespace.md` §6.2.

So the session was changed to start **no** window manager. That is right for a
session running one application and **wrong for a desktop**, and it was the
default for exactly one pass. Measured in the same session as everything
below, with no WM running:

```
_NET_SUPPORTING_WM_CHECK:  not found.
_NET_WORKAREA:             no such atom on any window.
_NET_SUPPORTED atoms:      0
REPARENTED:                NO, for every client -- still a child of the root
```

Nothing inside the namespace can move, resize, stack or close anything, and
every EWMH question a toolkit asks comes back empty. A window that exists and
cannot be reached is the shape this project exists to avoid.

## 2. What was measured, and how

**The size numbers are against these images, not against a wishlist.** The
Debian column is the `Depends` closure of each candidate resolved against the
image's own `/var/lib/dpkg/status` (619 packages, read out with `debugfs`,
read-only); the Alpine column is the same walk against
`/lib/apk/db/installed` (76 packages) and the v3.24 `APKINDEX`. "New packages"
therefore means *new to this image*, which is the only number anybody pays.

**The behaviour numbers are from one boot**, one X server, three window
managers brought up and taken down in turn with the same two clients on the
screen, inside the Debian namespace, through the real path
(Xwayland → wsyswl → wsys v2 → wsysd → `/dev/fb`).

## 3. The table

| WM | Debian: new pkgs / MiB | Alpine: new pkgs / MiB | reparents | EWMH atoms | needs a bus or a daemon |
|---|---|---|---|---|---|
| **jwm** | **1 / 0.5** | 24 / 22.0 | yes, 27px title bar | **66** | no |
| pekwm | 2 / 2.4 | 14 / 13.1 | yes | 57 | no |
| metacity | 11 / 4.8 | 147 / 174.8 | yes | — | GSettings/dconf |
| xfwm4 | 11 / 8.7 | 55 / 36.9 | yes | — | `xfconfd` over D-Bus |
| marco | 12 / 11.5 | 64 / 42.3 | yes | — | MATE settings + dconf |
| mutter | 23 / 22.7 | 203 / 221.1 | yes | — | `gnome-settings-daemon` |
| openbox | 21 / **57.9** | 41 / 27.5 | yes | **85** | no |
| fluxbox | 20 / 61.7 | **16 / 8.9** | yes | — | no |
| icewm | 22 / 63.0 | 49 / 33.7 | yes | — | no |
| matchbox | 1 / 0.3 | not packaged | **no** | 15 | no |

Two things in that table are worth saying out loud because they are
counter-intuitive and they decided the answer.

**openbox, fluxbox and icewm cost 58–63 MiB in Debian, and it is
Ghostscript.** All three depend on `libimlib2`, which depends on
`libspectre1`, which depends on `libgs10` — so adding a 400 KiB window manager
to this image pulls in `libgs10` (21.3 MiB), `poppler-data` (12.8 MiB) and
`fonts-urw-base35` (15.2 MiB). That is a packaging accident of bookworm's
imlib2 and not a property of the window managers, but this is a distribution
and the accident is what gets shipped. Alpine's `imlib2` has no such
dependency, which is why fluxbox is 8.9 MiB there and 61.7 MiB here.

**jwm costs 0.5 MiB in Debian because Firefox already paid for it.** All
sixteen of its dependencies — `libcairo2`, `libglib2.0-0`, `libpango-1.0-0`,
`libpangoxft-1.0-0`, `librsvg2-2`, `libjpeg62-turbo`, `libpng16-16`,
`libxft2`, `libxpm4`, `libxmu6`, `libxinerama1`, `libxrender1`, `libx11-6`,
`libxext6`, `libpangoft2-1.0-0`, and a terminal emulator — are already in the
image, dragged in by `firefox-esr` and GTK. One new package, 476 KiB, a
146 KiB `.deb`.

(The terminal-emulator dependency is `rxvt-unicode | gnome-terminal | konsole
| x-terminal-emulator`. `xterm` was moved into the base package list for that
reason: in the `HAMLINUX_I386=0` image nothing provided `x-terminal-emulator`,
so apt would have satisfied jwm by installing `rxvt-unicode` — a second
terminal emulator nobody asked for, in the one build where it would have been
hardest to notice.)

## 4. What each candidate was rejected for

* **matchbox** — does not reparent, and unmaps what it manages. Convicted by
  measurement, twice.
* **mutter, marco, xfwm4, metacity** — a desktop environment's window manager,
  and each drags its environment behind it: a settings daemon, a dconf/GSettings
  backend, and a D-Bus session it expects somebody else to have started.
  `mutter` alone pulls `gnome-settings-daemon-common`, `libpipewire`,
  `libinput` and `libwacom`; on Alpine it is 203 packages and 221 MiB. A
  namespace is not a login session and there is nothing in it to run a session
  manager. **Rejected on shape, not only on size** — this is exactly the "do
  not simply pick the biggest one" case.
* **openbox** — the best EWMH implementation in the list (85 atoms, including
  `_NET_WM_MOVERESIZE`, `_NET_WM_PING` and `_NET_WM_SYNC_REQUEST`, all three of
  which jwm lacks) and the runner-up. Rejected on the 57.9 MiB Ghostscript
  closure above, and on a second measured fact: openbox **exits** if it cannot
  load a theme (`Openbox-Message: Unable to load a theme`), which in a
  namespace with no theme data installed is a window manager that starts,
  publishes `_NET_SUPPORTED`, dies, and leaves an unmanaged screen behind
  advertising that it is managed. It got as far as setting the root properties
  in the probe run and never reparented anything.
* **fluxbox, icewm** — the same Ghostscript closure in Debian, and no
  behavioural advantage over jwm to pay it for.
* **pekwm** — genuinely close: 2.4 MiB in Debian, reparents, decorates. It
  publishes 57 atoms to jwm's 66, and in the probe run it left one of the two
  clients out of `_NET_CLIENT_LIST` — a client that a taskbar or a
  window-switcher would then not know about.
* **i3, herbstluftwm, bspwm, spectrwm, cwm, dwm** — cheap, and several of them
  cheaper than jwm on Alpine, but tiling or borderless by design. A 700×440
  CEF dialog that asks for `+290+180` would be resized to fill a frame, which
  is the same class of thing matchbox was thrown out for.

## 5. Why the same window manager in both namespaces, when Alpine pays more

Alpine's whole argument is that the namespace is **26 MiB without graphics**,
and that number is untouched: `HAMLINUX_ALPINE_GUI=0` installs no X server and
no window manager. The cost lands entirely on the graphical image, and it is
measured rather than estimated — two full builds of
`scripts/hamlinux_alpine.sh`, differing only in the package list:

```
no window manager   76 packages   269.4 MiB   (rootfs tree 273 MiB)
+ jwm              102 packages   296.7 MiB   (rootfs tree 305 MiB)   +27.3 MiB
+ jwm + xterm      105 packages   297.9 MiB   (rootfs tree 306 MiB)   +28.5 MiB
```

jwm's 27.3 MiB here is `glib` (5.1), `librsvg` (3.6), `shared-mime-info`
(2.4), `libglycin` (2.5), `harfbuzz`, `pango`, `cairo`, `libdav1d` — the stack
Debian's image already had and Alpine's did not. `xterm`'s 1.2 MiB is bought
deliberately: the root menu offers a Terminal, and a menu entry that opens
nothing is precisely the success-shaped failure `NORTH_STAR.md` names.

**fluxbox would be 8.9 MiB on Alpine — 18 MiB cheaper — and 61.7 MiB on
Debian, 61 MiB dearer.** Choosing per-distribution would save 18 MiB on the
small image, spend 61 MiB on the large one, and leave the two namespaces with
different title bars, different keybindings and different EWMH answers, so
that "does this work in the namespace" would have two answers. One window
manager, one configuration file, both trees.

## 6. The configuration is ours, and that is not a detail

`etc/jwmrc.linux` is installed as `/etc/jwm/hamnix.jwmrc` by both build
scripts, and `tests/linux/hamnix_x11session.sh` starts `jwm -f` on it.

Running with Debian's packaged `/etc/jwm/system.jwmrc` instead is a different
window manager: measured, it has a `<Tray>` at the bottom containing
`<Swallow name="xclock">xclock</Swallow>`, so it **launches its own xclock**
and reparents the session's real one into a 25px strip, and its
`<Group><Option>tiled</Option></Group>` plus `<Group><Name>xterm</Name>
<Option>vmax</Option></Group>` re-place and vertically maximise windows that
asked for neither. With that tray, `_NET_WORKAREA` came back `0,0,1280,775` on
a 1280×800 screen — every EWMH-aware client told the screen is 25 rows shorter
than it is. Ours publishes the full `0, 0, 1280, 800`.

What ours deliberately does not have — no tray, no virtual desktops, no
Exit/Restart entries — and why, is written in the file itself.

## 7. What was verified, and where the evidence is

Inside the Debian namespace, through the real path, with the real session
script:

```
hamnix-x11session: jwm started with /etc/jwm/hamnix.jwmrc
hamnix-x11session: window manager has the screen: "JWM", 66 _NET_SUPPORTED atoms, 0, 0, 1280, 800

xterm:   REPARENTED into frame 0x200034; title bar 32px
         _NET_FRAME_EXTENTS(CARDINAL) = 4, 4, 28, 4
         after move   xdotool windowmove 330 300 -> 280x186+334+328 IsViewable
         after resize xdotool windowsize 700 440 -> 700x440+334+328 IsViewable
firefox: REPARENTED into frame 0x20004b; title bar 32px
         WM_NAME "Mozilla Firefox", _NET_WM_NAME "Mozilla Firefox"
         after move+resize 900x600+32+76 IsViewable
```

and the framebuffer — the QEMU screendump of the Hamnix desktop — carries the
title bar, the minimise/maximise/close buttons, both windows and their
stacking order.

**And the case matchbox failed, which is the strongest evidence there is.**
With `jwm` and the merged compositor (`bb6ab02f`, `MAXMAP` 16 → 64), Steam's
login window is on the Hamnix desktop: the SIGN IN form, the account-name and
password fields, `Remember me`, the `Sign in` button and the QR block, beside
a decorated jwm-managed `xterm` (`build/steamprobe/steam_login_jwm.png`; the
`xterm` and Firefox arms are `wm_jwm_xterm.png` and `wm_jwm_firefox.png`
beside it). Read out of the same boot:

```
0x1a00015 "Sign in to Steam" ("steamwebhelper" "steam") 700x440+290+180  IsViewable
_NET_CLIENT_LIST(WINDOW): window id # 0x140000c, 0x1a00015
_NET_ACTIVE_WINDOW(WINDOW): window id # 0x1a00015
```

matchbox left that window `IsUnMapped`. jwm manages it, lists it, makes it the
active window — and does **not** reparent it, which is also correct: CEF sets
no-decorations and jwm honours that, so Steam draws its own chrome and gets
exactly the 700x440 at +290+180 it asked for.

The compositor's own account of the same run, `cat /run/wsyswl-state` from
inside the namespace, with a window manager in the session:

```
commits 639   rows 511200   every drop_* counter 0   map_alloc_failed 0
maps_in_use 31   maps_high_water 31   max_object_id 132   windows_high_water 1
limits MAXMAP=64 MAXOBJ=1024 MAXWIN=12 FCMAX=64
```

Two numbers in there are worth carrying forward. **31 mappings, not 26** —
adding a window manager to the X session costs about five more `wl_shm`
mappings on the one shared connection, which would have been over the old
limit of 16 by itself. And **`windows_high_water 1`**: the entire X session,
window manager, frames, Steam and all, is ONE wsys window. That is §8.

## 8. The bigger question: rootless Xwayland

`user/wsyswl.ad` already gives each `xdg_toplevel` its own wsys window — that
is how Firefox's menus became separate windows. A **rootful** Xwayland
collapses every X client into ONE `wl_surface`, which is the only reason a
window manager inside the namespace matters at all: with rootless Xwayland,
each X toplevel would get its own `wl_surface`, `wsysd` would place, stack and
decorate them exactly as it does for Wayland clients, and the namespace would
need no window manager of its own.

**That is the better long-term answer, and the MAXMAP wall is the argument
for it.** `windows_high_water 1` is not a curiosity: it means every X client in
the namespace shares one connection, one object-id space, one `wl_shm` mapping
table, one frame-callback ring — and therefore one fate. `MAXMAP` was 16 and
Steam's session needs 31; what that produced was not "Steam is broken" but an
entire X screen that painted once and then froze, with the control `xterm` and
Steam's window as the same symptom, and it took three passes to establish that
they were. `MAXWIN=12` and `FCMAX=64` are the same shape waiting to happen: a
namespace with a dozen X windows open, or a busy client asking for more frame
callbacks than the ring holds, hits a per-connection limit and everything on
that X screen stops together. Raising the constants buys headroom; it does not
remove shared fate. **Rootless removes it** — one `wl_surface`, one set of
limits, per toplevel — and hands placement, stacking and decoration to
`wsysd`, which already does all three for Wayland clients.

**It is still not what this change is.** Stating why, so the next pass does not
have to rediscover it:

* Rootless Xwayland is not a flag on the same server. It requires a real X11
  window manager **on the compositor side**: Xwayland `-rootless` emits
  `xwayland_shell_v1` surfaces and expects the compositor's own X11 WM
  (`XWM`) to own the ICCCM/EWMH half — reparenting, `WM_PROTOCOLS`,
  `WM_TRANSIENT_FOR`, override-redirect placement, selection ownership for
  clipboard and drag-and-drop, `_NET_WM_STATE` round trips. That is several
  thousand lines of X11 protocol in `wsyswl.ad`/`wsysd.ad`, in Adder, and it
  is the piece every Wayland compositor finds hardest.
* It changes where window management lives, which changes `wsysd`'s scene
  model, the uid gate on the chrome segment, and the panel's window list.
  It is a design change to the window system, not an addition to a session
  script.
* And it would be the same amount of work whether or not the namespace has a
  window manager today. Nothing here has to be undone to do it: a rootless
  session simply would not start one, which is one `case` arm in
  `tests/linux/hamnix_x11session.sh`.

So: **recommended, as its own piece of work, with `wsysd` owning window
management — which is where a Plan 9-shaped system wants it.** In the
meantime the namespace has a window manager that works, costs 0.5 MiB in
Debian, and can be deleted in one line when the compositor takes the job over.

> **§8a below revisits this section's central claim and finds it wrong.**
> Rootless is still worth wanting, for the reasons in the paragraph above —
> but *"rootless removes shared fate"*, which is the argument §8 makes for it
> and the argument that was carried forward into `HANDOFF.md`, does not
> survive being measured. The recommendation stands on the Plan 9 shape; it
> does not stand on the `MAXMAP` wall. Read §8a before starting the work.

**What it would need from `user/wsyswl.ad`**, named here rather than started,
so whoever picks it up has the list and the merge stays clean:

1. `xwayland_shell_v1` (and `xwayland_surface_v1`), so Xwayland `-rootless`
   can associate a `wl_surface` with an X window id. Today `wsyswl` binds
   `xdg_shell` only.
2. An **X11 window manager inside the compositor**, holding
   `SubstructureRedirect` on the X root: `MapRequest`/`ConfigureRequest`,
   `WM_PROTOCOLS`/`WM_DELETE_WINDOW`, `WM_TRANSIENT_FOR`, `_NET_WM_STATE`,
   override-redirect placement for menus, and selection ownership for
   `CLIPBOARD`/`PRIMARY` and XDND. This is the large piece, and it is why the
   window manager currently lives inside the namespace instead.
3. Per-toplevel limits instead of per-connection ones — the whole point.
4. `wsysd` already places, stacks and decorates; what it would need is that
   these X toplevels arrive as ordinary windows, which is the shape it has.

Nothing in this change has to be undone for any of it: a rootless session
simply sets `HAMNIX_X11_WM=none`, which is one `case` arm that already exists.

## 8a. Rootless was measured before it was built, and item 3 above is false

§8 was written from `windows_high_water 1` and it drew the right picture of
the problem and the wrong conclusion about the cure. The cure was going to be
item 3 in that list — *"per-toplevel limits instead of per-connection ones —
the whole point"* — and **a per-toplevel `wl_surface` does not produce a
per-toplevel limit, because none of these limits is per surface.** They are
per **connection**, and Xwayland opens exactly one connection either way.

Everything below is `tests/linux/wsyswl_shared_fate.sh`, which is offscreen,
needs no VM and no Steam, and runs in about two minutes.

### The census

Five X clients on one rootful Xwayland, read out of the compositor's own
`wsyswl-state`:

```
5 X windows on the root;  conns 1   windows_high_water 1
the shared mapping table is at 2 of 64 with 5 X windows on it
```

Then the same server with a **rootless** Xwayland alongside the rootful one:

```
with a rootful AND a rootless Xwayland on the server, conns 2
```

**Two servers, two connections. One connection each.** `-rootless` is not a
second Wayland client and never becomes one however many X toplevels it
carries: `MAXMAP`, `MAXOBJ`, the frame-callback slice and the window budget
are all indexed `c * LIMIT + i` in `user/wsyswl.ad`, so every X client on one
X display draws from one table in rootless exactly as in rootful. Rootless
changes *which surface freezes*; it does not change *whose table ran out*.

### And it makes the table it was supposed to fix worse

The second measurement is the one that settles it. Under rootful, the mapping
table does not grow with the X session at all:

| X clients on one rootful Xwayland | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 8, all resizing at once |
|---|---|---|---|---|---|---|---|---|---|
| `maps_in_use` | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 |
| `maps_high_water` | 2 | 2 | 2 | 2 | 2 | 2 | 2 | 2 | **2** |

Eight X windows, concurrent churn, **two** mappings — because rootful presents
one surface and double-buffers it. A Chromium (which is what CEF and therefore
Steam's UI is) with eight X windows of its own reads the same 2. Steam's 26
came from Steam's session, not from having windows.

Rootless inverts that. Each X toplevel becomes its own `wl_surface` with its
own buffers, out of **the same per-connection table** — so mapping demand
starts scaling with window count against the one budget that has already
frozen this system once. `MAXMAP` at 64 is 2 in use today; the change proposed
to relieve it is the change that would make it grow.

### Three further ceilings rootless would hit first

* **`BB_SLOTS` is 8, for the whole system.** `user/linux-wsys.c`'s v2
  backbuffer has eight slots shared by every wsys window on the machine, and
  the ninth is refused with `all slots are in use by live windows -- this
  window will never be painted`. Rootful spends **one** of those on an entire
  X session. Rootless spends one per X toplevel, so nine X windows in a
  namespace would exhaust the paint pool for the whole desktop — Firefox
  included. Raising it is not free either: a slot is `2 * 1920 * 1080 * 4`, so
  eight is already 132 MB of address space.
* **`MAXWIN` was 12, globally.** Rootful can never reach it (one window per X
  display, four connections). Rootless makes it the first thing hit.
* **`MAXCONN` was 4.** Two distribution namespaces each carry an Xwayland,
  Firefox is a native client beside them, and the desktop chrome is another —
  four before the user starts anything, and the fifth client was refused
  outright.

`tests/linux/wsyswl_shared_fate.sh` also records what rootless does today with
no X11 window manager inside the compositor: an X client on the rootless
display produces **no wsys window at all**. That is item 2 of §8's list — the
several-thousand-line piece — confirmed as load-bearing rather than optional.

### What was done instead

The shared-fate bugs that were actually there, in the actually shared tables,
all in `user/wsyswl.ad`:

| | was | now | why |
|---|---|---|---|
| frame callbacks | one table of 64, scanned end to end | `FCPERCONN` 32, partitioned by connection (`FCMAX` 256) | the client that took the 64th slot denied the 65th to **every other client on the server**, and an unanswered initial-draw callback is a window that renders one empty frame and stops for ever |
| window budget | `n_win >= MAXWIN`, 12 for the whole server | `WINPERCONN` 8 per connection, `MAXWIN` 64 = `MAXCONN * WINPERCONN` | one client's window count decided whether another client's window existed |
| connections | `MAXCONN` 4 | 8 | a connection is the unit of independence here; four was fewer than the distribution already wants, and the fifth client was refused silently |
| the refusals | silent, or a bare `return` | `window_budget_full` counted, `too many clients -- raise MAXCONN` named | §6.2a's lesson |

`MAXWIN >= MAXCONN * WINPERCONN` and `FCMAX >= MAXCONN * FCPERCONN` are now
**checked by the test as arithmetic**, so a future edit cannot quietly make
either table global again. And `wsyswl-state` splits its limits into the two
kinds, because a counter whose owner is unknown is what cost three passes:

```
conns 1
conns_high_water 1
window_budget_full 0
limits per_conn MAXMAP=64 MAXOBJ=1024 WINPERCONN=8 FCPERCONN=32
limits shared   MAXCONN=8 MAXWIN=64 FCMAX=256 MAXMAP_BUILT=64
```

### So what should give an X session its own fate?

**Its own Xwayland**, which is its own connection, which is its own everything
— and that is a session-script arm, not a compositor rewrite. `MAXCONN` at 8
is what makes it affordable: `enter debian { steam }` can have a display of
its own, and Steam filling its mapping table then cannot reach Firefox, the
desktop, or the other namespace. This is the same conclusion §8 reached about
*where* independence lives, arrived at from the other end: independence here
is bought per connection, and the cheapest connection is a second server.

**Rootless remains worth building** — for the reason §8 gives that survives:
window management belongs in `wsysd`, windows are already files under
`/dev/wsys/<wid>/`, and a namespace should not need a window manager inside
it. That is a Plan 9 argument and it is a good one. It is just not a
shared-fate argument, and it should not be started until `BB_SLOTS` and the
per-connection mapping table can carry one surface per X toplevel, because
today they cannot.

## 8b. Rootless, built — an X window is a file now

`HAMNIX_X11_WM=rootless` is a **third session arm**. `jwm` is still the
default and the rootful path is untouched; with `WSYSWL_XWM` unset the
compositor does not advertise `xwayland_shell_v1`, dials no X connection, and
takes the branch it always took. What follows is what the arm does, what was
measured, and what is deliberately not built yet.

### What it is for, stated once and not the other thing

Not shared fate — §8a settled that and this section does not reopen it.
`conns` is **1** on a rootless display exactly as on a rootful one, and
`tests/linux/wsyswl_rootless.sh` asserts that on purpose so the two claims
cannot be confused again.

The reason is the one in the first line of `NORTH_STAR.md`'s shape:

> Window management belongs in `wsysd`. Windows are already files under
> `/dev/wsys/<wid>/`.

Under rootful, an entire X session — every client, the window manager, its
frames, Steam and all — is **one** `wl_surface` and therefore **one** wsys
window. The desktop can move that rectangle; it cannot move a window inside
it, because there is no window inside it to move. That is the whole reason a
namespace needs `jwm`, and it is why a Debian application is a second-class
citizen on this desktop while Firefox gets one wsys window per
`xdg_toplevel`.

### The measurement

`tests/linux/wsyswl_rootless.sh`, 23 PASS, offscreen, about a minute, no VM
and no Steam. Two `xterm`s on one rootless Xwayland:

```
xwl_managed 2   xwl_paired 2   windows_high_water 2   conns 1
commits 4       drop_xwl_unpaired 0    xwm_refused 0
/dev/wsys lists 2 application windows for one X display: wids 2 3
wid 2 at 60,60 186x110    wid 3 at 400,60 186x110
wid 2 is 97% alpha / 0% beta;   wid 3 is 0% alpha / 96% beta
```

and then the point of the whole thing, which is stated in pixels because a
pair of window records pointing at the same pixels would pass a count:

```
the compositor moved wid 2 to 280,240
and wid 3 did not move with it
after the move: 97% of the new rectangle is the moved window's colour,
                96% of the old rectangle is still the other window's colour
```

**The control is in the same script, on the same compositor**: the same two
clients on a *rootful* Xwayland add **one** wsys window. And the negative,
which is the load-bearing half: with no XWM configured the compositor must
**not** advertise `xwayland_shell_v1`, because a client that binds it hands
over surfaces nothing can ever pair with an X window — a rootless display that
comes up managed and empty with no error anywhere.

`docs/screenshots/linux/rootless-two-x-windows.png` is that frame: two
decorated Hamnix windows carrying two X clients from one Xwayland, one of them
where the compositor put it.

**And it is a frame of the DESKTOP, which it was not.** The first version of
that screenshot showed the two windows on a bare compositor — no wallpaper, no
icons, no panel — because the gate composed `wsysd` plus the two clients and
nothing else. The machine owner spotted it. That proved the windows *exist*;
it said nothing about whether they *work on the desktop*, which is the only
claim worth making, and the difference is not hypothetical: ea23c834 fixed a
bug in which `hamdesktop`'s backdrop painted over every ordinary client window
for the whole port, with every return code 0 and the taskbar still listing the
windows it was covering. `tests/linux/wsyswl_rootless.sh` now composes the
real DE — the same `wsysd` + `hamdesktop` + `hampanelscene` composition
`tests/linux/wsys_desktop_z.sh` uses — and asserts that an X window out of a
namespace is a **first-class window on it**, each assertion a relationship
between two things on the screen rather than a coordinate:

| | measured |
|--|--|
| over the wallpaper | the X client's rectangle is **0%** its own colour on the bare desktop and **96%** with the client up — the "before" half is what makes it evidence |
| the desktop survives it | a strip of wallpaper beside the windows is **100%** unchanged from the bare-desktop frame |
| under the panel | driven up to straddle the bar with the compositor's own `geometry` verb: **0%** of the bar is the window, **98%** of the window clear of the bar |
| in the taskbar, by its X name | `/dev/wsys/windows` reads `5 alpha` / `6 beta` — the names the X clients set in `WM_NAME`, carried through the XWM onto the wsys window and read by `hampanelscene`'s taskbar |

29 PASS (was 23), still offscreen, still about a minute, still no VM.

### Two things had to be measured because reading was not enough

**`CompositeRedirectSubwindows(root, Manual)` is the request without which the
whole thing is a no-op.** With `SubstructureRedirect` held, `WL_SURFACE_SERIAL`
interned, `xwayland_shell_v1` bound by Xwayland and both clients managed and
mapped, Xwayland produced **zero** `wl_surface`s: `xwl_managed 2`,
`commits 0`, `max_object_id 16`. Xwayland only builds a surface for a window
whose drawing is redirected — `if (window->redirectDraw != RedirectDrawManual)
return;` — and it does not redirect anything itself. Every other compositor's
XWM issues that request in its first breath; nothing in the protocol
documentation says you must.

**The serial does not arrive as a window property.** The
`xwayland-shell-v1` description reads as though `set_serial`'s value appears on
the X window as `WL_SURFACE_SERIAL`. On Xwayland 24.1.6 it does not: the
toplevel's full property list is `WM_PROTOCOLS`, `_NET_WM_PID`,
`WM_CLIENT_LEADER`, `_XWAYLAND_ALLOW_COMMITS` (the one *we* set), `WM_CLASS`,
`WM_HINTS`, `WM_NORMAL_HINTS`, `WM_NAME` and friends, and **no**
`WL_SURFACE_SERIAL` — with and without a `-wm` fd, both tried. It arrives as a
**ClientMessage** of that type, addressed to the X window, delivered to the
root under `SubstructureRedirect`: `data.l[0]` is the low half, `data.l[1]` the
high half. The property path is still read as a fallback, so a server that does
set it works too.

### The shape inside the compositor

`user/wsyswl.ad` gained two things that are one thing:

1. **The Wayland half.** `xwayland_shell_v1` / `xwayland_surface_v1`,
   advertised only when the compositor is actually managing an X display. A
   surface handed over this way has no `xdg_surface` and never will: its role
   *is* an X window. `obj_e` on a `wl_surface` is `0` for an ordinary surface
   (a cursor, say), `-1` for an X surface waiting to be paired, and the X
   window id once the two halves have met.
2. **The X half.** An X11 wire-protocol client — the shape `user/xsnarfd.ad`
   already proved, with nothing assuming a fixed root window or resource base —
   holding `SubstructureRedirect | SubstructureNotify` on the root. It maps
   what it redirects, grants `ConfigureRequest`s as asked, tracks geometry and
   override-redirect, and reads `WM_NAME` / `_NET_WM_NAME` onto the wsys
   window's `title`.

   The title goes where a native Wayland client's goes and is **not visible**,
   because `wsysd`'s decoration fills a coloured bar and renders no text for
   any window, native or bridged. Checked rather than assumed: a 4× crop of
   the bar over a window titled `Hello Rootless` is plain blue. That is a
   `wsysd` gap, not a rootless one, and it is written down here so the next
   person does not spend an afternoon debugging an X property that is arriving
   correctly.

An X window and a `wl_surface` are two halves of one window and **either can
arrive first**, so both directions attempt the association; neither half is
allowed to be the one that gets there second and is ignored.

`wsyswl-state` grew `xwm`, `xwm_connected`, `xwl_managed`, `xwl_paired`,
`drop_xwl_unpaired` and `xwm_refused`, because a rootless session whose
`windows_high_water` stays at 1 has to be answerable from the state file and
not from a debugger.

### The clipboard was already done, and §8 counted it twice

§8's item 2 listed "selection ownership for `CLIPBOARD`/`PRIMARY` and XDND" as
part of this work. It is not: `user/xsnarfd.ad` is an ordinary X client on the
same display and owns those selections whether the display is rootful or
rootless. Nothing about rootless changes it.

### What is NOT built, named rather than half-done

* **`WM_PROTOCOLS` / `WM_DELETE_WINDOW`.** A title-bar close today destroys the
  wsys window and leaves the X client running. Closing a window should ask the
  client to close.
* **Compositor-side move and resize pushed back to X.** `wsysd` moving a window
  does not send the X client a `ConfigureNotify`, so a client that asks where
  it is gets its original position. Pointer coordinates are unaffected — they
  are surface-local and Xwayland adds the window's own origin — which is why
  the demonstration above works without it.
* **EWMH.** No `_NET_SUPPORTING_WM_CHECK`, `_NET_SUPPORTED`, `_NET_WORKAREA`,
  `_NET_CLIENT_LIST` or `_NET_WM_STATE`. A toolkit asking "am I maximised" or
  "how big is the usable area" gets nothing, exactly as with no WM at all. This
  is why `hamnix_x11session.sh` skips its window-manager check on the rootless
  arm rather than printing a warning that is true and misleading at once.
* **`WM_TRANSIENT_FOR` stacking**, so a dialog is not kept above its parent by
  anything but z-order luck.
* **A visible title.** The name is set on the wsys window; `wsysd` paints no
  text on a title bar for anything. Whoever adds it gets X windows named for
  free.
* **Override-redirect placement is literal.** A menu is placed at its X-screen
  coordinates, which are not its parent window's coordinates on the Hamnix
  desktop once the user has moved the parent. Menus land in the right place
  only until something is dragged.
* **The two ceilings §8a named are still the ceilings.** `WINPERCONN` is 8, so
  an X display may have eight toplevels on screen at once, and
  `user/linux-wsys.c`'s `BB_SLOTS` is 8 **for the whole machine** — rootful
  spends one of those on an entire X session, rootless spends one per X
  toplevel. This is the reason rootless is an arm and not the default: a
  namespace with nine X windows would exhaust the paint pool for the desktop,
  Firefox included. **That is the next piece of work, and it is a prerequisite
  for making this the default rather than an option.**

> **All six of the above are done — see §8c**, which is stage two. `BB_SLOTS`
> is now tied to the window table by a compile-time assertion rather than
> being a number, `WINPERCONN` is 16, and twelve X windows are on the screen
> at once with all twelve painted. The list is left standing because how each
> gap was described here and what it turned out to be are not the same in
> three of the six cases, and that difference is the useful part.

---

## 8c. Rootless, stage two — the list in 8b, and what it cost to close it

§8b ended with five named gaps and one prerequisite. All six are now done and
measured. What follows is what each one turned out to be, because in three
cases the thing that was actually wrong was not the thing that was named.

### The prerequisite: the paint pool

§8b called it "the two ceilings §8a named", and the fix is not a bigger
number. `BB_SLOTS` had already been raised once — 3 → 8, after a fourth
window went blank with no error — and a number that has been wrong twice for
the same reason should not be picked a third time. So it is not picked:

> **`BB_SLOTS == WSYS_MAX_WINDOWS`, asserted at compile time.** The paint pool
> can never be the first thing to run out. The ceiling that is left is the
> window table, which is a number the device can state.

What made a pool that size affordable is the interesting half, because it is
why it had not simply been done. A slot cost a screen-sized double buffer
*whatever the window's size was*: the segment was `memset` whole at creation,
each slot `memset` whole on fit, and the front page `memcpy`d whole into the
back **on every frame**. Three changes make the cost the window's own area:

* the pixels are no longer a member of `struct bbshm`. The headers are one
  small mapping; slot *i*'s two pages are mapped **on demand** at a computed
  offset, so a process maps only the slots it touches instead of two gigabytes
  of address space in every GUI program on the machine;
* `bb_fit` clears `w*h*4` — and the *old* extent too, so a shrink cannot leave
  the previous tenant's pixels inside the new window;
* `bb_blit`'s carry-forward copies `w*h*4`. That one was also 8 MiB per frame
  per window on the frame path.

Measured, `tests/linux/wsyswl_ceiling.sh` (9 PASS, offscreen, no VM): **twelve
X clients on one rootless Xwayland are twelve Hamnix windows, all twelve
painted in their own colour in the framebuffer**, and the backbuffer segment —
2025 MiB long, sparse on purpose — has **1924 KiB allocated**. The same run
before this gave 8 windows and four X clients that vanished.

And the ceiling is READABLE now, which is the part that had cost the most.
`/dev/wsys/pool` answers

```
slots 12/128 exhausted 0 last_refused 0 0x0
```

so a window that is never painted is diagnosable from a file after the fact,
rather than from a line on a console somebody had to be watching at the time.

The chain of ceilings behind it had one more link that nothing had noticed:
`user/wsysd.ad`'s own window table was 32 while the device's was 32, which
agreed *by accident*. Raising the device to 128 made the compositor's array
the next silent ceiling — a 33rd window would have been listed and never
painted. Both are 128, and the ceiling test is what keeps them equal.

### `WM_DELETE_WINDOW` — and why there was no close button at all

Not "the close button was broken". There was none, on any window, native or
bridged, and the reason is worth recording: the only thing `wsysd` could have
done with the click was write `close <wid>`, which **destroys the window
record and leaves the program running**. An invisible `xterm` holding a shell;
a browser you cannot see and cannot quit; an editor with unsaved work and
nobody to ask. A button that does that is worse than no button.

So the device grew a second verb. **`delete <wid>` asks.** A window whose owner
set `wmdelete 1` on its ctl gets the request on its own `event` ring and the
owner decides; anything that never heard of the verb is destroyed exactly as
`close` always did, so a scene app is unaffected. `wsyswl` sets `wmdelete 1` on
every window it opens and turns the request into `WM_DELETE_WINDOW` for an X
client that advertises it in `WM_PROTOCOLS`, `xdg_toplevel.close` for a native
Wayland toplevel, and `KillClient` for an X client that said it cannot be
asked. Which of the three happened is a counter, because *"the window would
not close"* and *"the client was killed"* are different bugs with one symptom.

`tests/linux/wsys_close_button.sh` (10 PASS): the button is painted at exactly
the coordinates the hit test uses (91% of that rectangle, the rest being the
cross); a click elsewhere on the title bar does not close; and a real click on
the button makes **the X client exit** — the process, not the window record —
while the other client is untouched.

That test needed a pointer, so `wsysd` grew `HAMWSYSD_INPUT`, which names an
evdev stream and **replaces** the `/dev/input` scan. Same justification as
`HAMFB_FILE`: an offscreen compositor with no pointer cannot be asked anything
a pointer does. What is read from it is evdev byte for byte, through the same
dispatch loop — a test that invented its own event format would be testing its
own invention — and *replacing* the scan is what keeps an offscreen run on a
development host off that host's real keyboard.

One thing the first run of that test found, worth having written down: press
and release must land in **separate 16 ms pumps**. `wsysd` keeps one
`ptr_edge`, so a collapsed pair reads as a release with no press. No human at
a mouse could produce the collapsed case; a test can, and did.

### `ConfigureNotify`, and why the absence was invisible

`wsysd` moving a window was invisible to the program inside it. An X client
that asked its own geometry got the corner it opened at for the rest of its
life, and an override-redirect menu placed at *"my parent's corner plus
twenty"* was placed against a corner that had not been true since the first
drag. **Pointer coordinates were never affected** — they are surface-local and
Xwayland adds the origin itself — which is exactly why everything *looked*
right and this was easy to leave out of stage one.

The fix is in two halves and the first is a file. `geometry` written by anyone
but the window's owner now posts the new rectangle on the window's own `event`
ring: the file-server half of `ConfigureNotify`, on a ring a parked client is
already asleep on, so it costs a wakeup when a window moves and **nothing at
all** when none does. The compositor reads it and pushes it on to the X window
as a `ConfigureWindow`, which the X server turns into the `ConfigureNotify`
the client is waiting for.

X and wsys therefore agree on where a window is — which has a second effect
worth more than the first: **a menu opened *after* a move is placed correctly
by the client, with no help from us at all.**

Measured in `wsyswl_rootless.sh` by `xprop`/`xwininfo`, a different program
asking the X server: after the compositor moves a window to 280,240, the X
server says the client is at 280,240.

### `WM_TRANSIENT_FOR` and menus that follow

`WM_TRANSIENT_FOR` is read on map: a dialog goes one z band above an ordinary
toplevel, where before it stayed on top only by having been created later and
one click on the parent buried it.

An override-redirect menu is attributed on map to the toplevel it opened over
— by `WM_TRANSIENT_FOR` when the client set it, otherwise by whose rectangle
contains its corner — and the offset is remembered, so a menu that is **already
open** when its parent is dragged moves with it. That is the one case the
client cannot get right, because nothing tells it; everything opened after the
move is handled by the coordinate sync above.

### EWMH — the answer was not "bad", it was "no window manager"

Until stage two a rootless display answered these questions **byte-for-byte
the way a bare X screen does**. That is not a poor answer; a toolkit correctly
concluded there was no window manager and laid itself out accordingly, and a
client asking how big the usable desktop is got nothing and guessed. `jwm` —
the arm this replaces — publishes 66 atoms.

Published now, from the compositor's own XWM, and **only what is true**:
`_NET_SUPPORTING_WM_CHECK` (on a real window that points back at itself and
carries `_NET_WM_NAME` "wsyswl"), `_NET_SUPPORTED` with sixteen atoms,
`_NET_WORKAREA`, `_NET_DESKTOP_GEOMETRY`, `_NET_DESKTOP_VIEWPORT`,
`_NET_NUMBER_OF_DESKTOPS`, `_NET_CURRENT_DESKTOP`, `_NET_CLIENT_LIST`,
`_NET_CLIENT_LIST_STACKING`, `_NET_ACTIVE_WINDOW`, `_NET_WM_STATE` and
`_NET_WM_STATE_FOCUSED`.

There is no `_NET_WM_STATE_FULLSCREEN`, no `_NET_MOVERESIZE_WINDOW` and no
`_NET_WM_STATE_HIDDEN`, because this compositor does not do those things: **a
hint claimed and not honoured is worse than one absent**, since absent is a
fact a client can act on. `_NET_WORKAREA` is the screen minus `wsysd`'s title
bar and frame — the same `MAX_INSET_W/H` arithmetic `xdg_toplevel.configure`
already uses, or a maximised X client and a maximised Wayland client would be
different sizes on the same desktop. `_NET_CLIENT_LIST_STACKING` carries the
same *set*, and the code says outright that its *order* is not to be trusted,
because `wsysd` owns z and this compositor does not read it back.

`hamnix_x11session.sh` no longer skips its window-manager check on the
rootless arm. That skip existed because the check would have printed a warning
that was true and misleading at once; the same question now has the same
meaning on all three arms.

Measured by `xprop`:

```
_NET_SUPPORTED lists 16 atoms
check window 0x200001 names 0x200001 and calls itself "wsyswl"
_NET_WORKAREA is 0, 0, 1160, 700
_NET_CLIENT_LIST has 2 windows
```

### The visible title — judged, and it is still out of scope

Stage one established by measurement that `wsysd` paints **no text on a title
bar for any window**, native or bridged, and §8b asked whoever came next to
judge whether to fix it here. The judgement is no, and the reason is that it is
not a rootless question at all: it is one `wsysd` change that gives every
window on the desktop a visible name, X windows included, for free. Doing it
inside a rootless pass would put it in the wrong commit and under the wrong
test. The name is already set on the wsys window and already correct; what is
missing is a glyph run in `paint_window`'s decoration, next to the close box
this pass did add.

### The two real clients, re-run

Neither had been run against this path since stage one, and everything in
this pass touches the device and the compositor that both of them go through:
`WSYS_VERSION` went to 5, the backbuffer segment was re-laid-out, `wsysd`'s
window table doubled twice, and `lib/vk/vk_2d.ad`'s source-over now composes
the alpha channel. So both were run, and both render.

**Firefox**, the native Wayland client, offscreen against `wsyswl`:
`docs/screenshots/linux/rootless-stage2-firefox-wayland.png` — full chrome,
tab strip, address bar, content, in a decorated Hamnix window with a close
button on it. 1550 backbuffer generations, every drop counter 0.

It also produced the number in "what is still not built" below: **`conns 8`,
`conns_high_water 8`**. Firefox alone is `MAXCONN`.

**Steam**, in the Debian namespace, in the VM:
`docs/screenshots/linux/rootless-stage2-steam-login.png` — "Sign in to Steam"
with the logo, both fields, the button, the QR code and the links, on the
desktop with the panel above it and the taskbar below.
`xwininfo` says `700x440+290+180`, `IsViewable`. Rootful, which is the arm
Steam uses and which this pass leaves alone by construction.

That run used `tests/linux/steam_gui_ro.sh`, which is `steam_gui_run.sh`'s
measurement **without writing to the shared namespace image**: no `debugfs`,
`HAMLINUX_DISTRO_RO=1`, and the session scripts appended to the initramfs as a
second cpio segment. `build/` is not isolated by a git worktree, and two
agents planting into `distro.ext4` at once destroy each other's runs silently.

### What is still not built

* **Resize by dragging an edge.** `wsysd` has a close button now and no move
  or resize grip; the `geometry` verb is the only mover, which is what every
  test here uses. This is the largest remaining gap in the desktop's own
  window management and it is not specific to X.
* **`_NET_WM_STATE` round trips.** The property exists and is published; a
  client *requesting* maximise through `_NET_WM_STATE` with a ClientMessage is
  not honoured yet.
* **Stacking order.** `_NET_CLIENT_LIST_STACKING` is published as a set with
  an order that is not the stacking order, and is documented as such.
* **`MAXCONN` is the next ceiling, and it is closer than it looks.** It is 8,
  and **Firefox alone reaches `conns 8`** with its content and GPU processes —
  measured, this pass. A namespace's Xwayland arriving next is the ninth, and
  hitting that ceiling does not cost a window, it costs a whole program. It is
  a counter now (`conn_refused`) rather than only a line on stderr, but the
  number has not been raised: `MAXWIN >= MAXCONN * WINPERCONN` is the
  reservation the shared-fate work established, and raising `MAXCONN` to 16
  means either halving the per-connection window budget this pass just doubled
  or taking the device's window table to 256.

  **CLOSED, TWICE OVER — see §8d.** `MAXCONN` went to 16 (table to 256), and
  has since gone to **32** with the table at **512** for the case 16 could not
  hold: two Firefoxes and two namespaces' Xwayland.

## 8d. Two browsers — and the ceiling that was really in the way

`MAXCONN` 16 did not hold two browsers, and HANDOFF named it as the next
ceiling on the arithmetic 8 + 8 + 2 = 18. Two of those numbers were measured
and one was guessed. Driven, with the real programs
(`tests/linux/wsyswl_two_browsers.sh`, 24 PASS, offscreen):

| program | Wayland connections |
|--|--|
| `firefox-esr` | **8** — content, GPU and utility processes |
| `chromium` | **2** — browser + GPU process |
| `Xwayland` | **1** per namespace, rootful or rootless, whatever is behind it |

So Firefox + Chromium is **ten**, and would have fitted. The case that does not
is the one a namespaced distribution makes ordinary: a Firefox in the native
root and a Firefox inside `enter debian { … }` — really 8 + 8 — and then the
two namespaces' Xwayland are 17 and 18.

### The memory was never being spent on anything

`MAXWIN >= MAXCONN * WINPERCONN` takes 32 connections to 512 rows, which the
previous pass measured at **36.21 MiB resident** and refused on that number.
The measurement was right and its cause was not the table. `shm_attach` ran

```c
memset(shm, 0, sizeof *shm);
```

over a segment `ftruncate(2)` had just handed it out of a **fresh tmpfs file** —
bytes the kernel had already promised read as zero and had allocated nothing
for. The memset's whole effect was to fault in and dirty every page of a window
table with no windows in it. Removed (see *the zeroes we do not write* in
`user/linux-wsys.c`), the table becomes what the paint pool beside it already
was: address space, with residency proportional to the windows that exist.

| | apparent | resident, no windows open |
|--|--|--|
| 256 rows, `MAXCONN` 16, before | 18.17 MiB | **18,608 KiB** |
| 256 rows, `MAXCONN` 16, after | 18.17 MiB | **1,024 KiB** |
| 512 rows, `MAXCONN` 32 | 36.21 MiB | **2,048 KiB** |
| 512 rows, three browsers and two namespaces running | 36.21 MiB | **2,252 KiB** |

A row holding a window still costs its 74,164 bytes. The ~4 KiB-a-row floor is
`win_find` and the `/dev/wsys/windows` reader scanning for `used`, which is the
first word of a row — one page of every row touched by a scan. 4 KiB against
74 KiB, an 18x reduction and not an infinite one.

A **shared pool** of rows with a per-connection cap was the alternative and was
rejected: it trades an invariant that is arithmetic and checkable from source
for a policy whose answer to exhaustion is that a client's guaranteed budget
stops being guaranteed and starts depending on its neighbours.

### `DEVTAB_MAX` — the fifth ceiling written down twice, and the real one

Raising `MAXCONN` and then measuring instead of trusting a green suite found
that 32 clients gave `conns 32` and **`windows_high_water 16`**.
`user/linux-syscalls.c`'s per-process synthetic-device table was **64** entries
and `wsyswl` holds four per window — `<wid>/draw/ctl`, `keys`, `pointer`,
`event` — so **sixteen windows was the ceiling of the whole machine**, with 240
rows of the window table free. `MAXWIN >= MAXCONN * WINPERCONN` had been
arithmetic over an unreachable number since it was written.

It is the worst-behaved of the five (`BB_SLOTS` 3, `BB_SLOTS` 8, `wsysd`'s own
array at 32, `waitset` at 16, this) because **it fails as somebody else's
limit**: what a person sees is *no wsys window could be opened for this
surface*, which sends them to the one table that has room.

* `DEVTAB_MAX` is **2112**, derived — 4 files per window × `WSYS_MAX_WINDOWS`
  512 + 64 — and `wsyswl_conn_ceiling.sh` re-derives it from both files.
* Exhaustion **names itself** on stderr, with the constant and the file to
  edit, and `win_open`'s device refusal gets its own counter,
  `newwindow_refused`.
* `devtab_find` is called on every read, write, lseek, close and dup, and
  scanned the whole table on a **miss** — the common case, since most fds are
  ordinary files. It is an `fd -> slot` index now, so the table is *cheaper on
  the hot path than the 64-entry one it replaces* as well as 32× larger. The
  map is a hint, always re-validated against the slot's own `used`/`fd`, which
  is what makes stale entries safe to leave behind on close.

### The segment

`WSYS_VERSION` 6 → 7. `struct wwin` is byte-for-byte unchanged and every field
of `struct wshm` before `win[]` is frozen, so a v6 and a v7 build agree about
where windows 0..255 are and disagree only about how many follow. A v6 binary
on a v7 segment maps the first 19,052,956 bytes of a 37,972,380-byte file,
re-inits what it mapped, and cannot reach rows 256..511 — its array bound is
compiled in — and the next v7 attacher punches the whole segment before
anything reads a row.

### How to run it

The compositor is told which display it manages, by name, from outside the
namespace — the same way `xsnarfd` is:

The compositor is told which display it manages, by name, from outside the
namespace — the same way `xsnarfd` is:

```
WSYSWL_XWM=/n/debian/tmp/.X11-unix/X0  wsyswl /n/debian/run/wayland-0
```

and inside, `HAMNIX_X11_WM=rootless`. The session script **refuses to start**
if the compositor serving its socket was not given `WSYSWL_XWM` — it reads
`xwm` out of `wsyswl-state`, which is published beside the socket and is
therefore the one fact that crosses the namespace boundary. A rootless X screen
with a window manager on neither side is a display on which nothing is ever
mapped, and that is not a thing to discover from an empty desktop.
