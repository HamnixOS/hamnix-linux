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
