# N distribution namespaces on the Linux line

`enter debian { sh }` and `enter alpine { sh }`, at once, on one boot, from the
console and from a uid-1001 desktop terminal.

This document is about the **Linux line** (`hamnix-linux`). Its Hamnix sibling
is [`distro-namespaces.md`](distro-namespaces.md), which explains why a
distribution is a namespace at all; that reasoning is not repeated here. What is
here is the *plumbing*: how a name becomes a medium, and what had to change to
go from one distribution to N.

---

## 1. What was actually hardcoded

Before this change there was exactly one distribution namespace, and it was
Debian in four separate places:

| where | what it said |
|--|--|
| `user/linux-syscalls.c` | `#distro` → `getenv("HAMNIX_DISTRO")` or `/dev/vda`. One letter, one disk. |
| `etc/rc.boot.linux` | `bind '#distro' /n/distro`, and two `ns clean { }` templates (`debian`, `linux`) that were the same body. |
| `etc/rc.de-user.linux` | the same two templates again, for the session shell. |
| `scripts/hamlinux_distro.sh` | one mmdebstrap bookworm ext4. |

None of that is *wrong* for one distribution. It is simply not a mechanism: a
second distribution needed a code change in the C, and the second disk would
have been addressed as `/dev/vdb` — a name that means "whatever QEMU was handed
second".

## 2. The shape chosen, and why

### 2.1 One letter, parameterised: `#distro/<name>`

`#distro/alpine`, `#distro/debian`, and bare `#distro` for the default. This is
the `prefixed` form the device table already had for `#r/home` and `#t/foo`, so
it costs nothing structurally.

The alternative — a device letter per distribution, `#alpine`, `#fedora` — was
rejected because it puts the list of distributions in a C array. A namespace
you have to recompile to describe is not a namespace you *describe*.

### 2.2 The name-to-medium map is a file: `/etc/distros`

```
# name    source
default   LABEL=hamnix-debian
debian    LABEL=hamnix-debian
alpine    LABEL=hamnix-alpine
```

Staged from `etc/distros.linux`. A source is a block device path, a directory,
or `LABEL=<fslabel>`.

This follows Hamnix's own precedent rather than inventing one: the Hamnix
kernel parses the rootfs partition's `.hamnix-roots` sentinel at boot and posts
each **named subtree** as a file server. There is no kernel doing that here, so
`bind` reads the description itself — the same idea with one less layer.

Adding Fedora is: build a medium, label it `hamnix-fedora`, add one line here,
and add a five-line `ns clean { }` recipe. No C, no rebuild of anything.

### 2.3 The medium is addressed by LABEL, not by `/dev/vdN`

This is the part that matters most and is the least obvious.

With two distro disks attached, which one is `/dev/vda` is a property of the
order `scripts/hamlinux_vm.sh` happened to emit its `-drive` arguments. Getting
it wrong does not fail — it enters Alpine when Debian was asked for, and every
single thing downstream is confidently wrong. That is precisely the
success-shaped wrong answer `NORTH_STAR.md` names.

A label is a name. It travels with the filesystem, it survives reordering, and
it is read straight out of the ext2/3/4 superblock (magic `0xEF53` at
`1024+56`, `s_volume_name` at `1024+120`) with `/proc/partitions` as the
enumerator. No libblkid, no udev, no `/dev/disk/by-label` — none of which exist
on an initramfs boot that has only what the Adder PID 1 bound.

`scripts/hamlinux_distro.sh` now sets `hamnix-debian`;
`scripts/hamlinux_alpine.sh` sets `hamnix-alpine`.

### 2.4 `/n/<name>` — and the reason it is load-bearing, not cosmetic

`etc/rc.boot.linux` binds each distribution under `/n`:

```
bind '#distro'        /n/distro     # Debian's older name, kept working
bind '#distro/debian' /n/debian
bind '#distro/alpine' /n/alpine
```

That looks like a convention until you try it as the session user, and then it
turns out to be the whole design:

> **Reading a volume label means opening a block device, and a block device is
> `root:disk 0660`. An unprivileged process cannot resolve `LABEL=` at all.**

Measured, `tests/linux/two_namespaces.sh`, first run: uid 0 entered both
namespaces; uid 1001 entered neither, with
`bind: no distribution namespace named 'alpine'` — on a machine that had it
mounted at `/n/alpine`.

The fix is not permissions. It is Plan 9's own answer: **the server was already
posted, at a name.** `etc/rc.boot.linux` performed the mount while it was still
root. A session that later says `bind '#distro/alpine' /` is not asking to find
a disk; it is asking for the server at that name — and the name is the one
thing that crosses the privilege boundary intact. So `distro_resolve()` falls
back from the medium to the mount point, and only a *real* mount point counts
(an empty directory called `/n/alpine` would otherwise be entered as a
namespace whose root has nothing in it, and `sh: not found` is a much worse
answer than "there is no such namespace").

### 2.5 Resolution order

Most specific first, in `distro_resolve()`:

1. `$HAMNIX_DISTRO_<NAME>` — the per-name override. `$HAMNIX_DISTRO` for the
   default, which is the old variable and still means what it meant.
2. `/etc/distros` (or `$HAMNIX_DISTROS`).
3. the mount point `/n/<name>` — §2.4, the unprivileged path.
4. for the **default name only**, `/dev/vda`, which is what `#distro` meant
   before this file existed. Said out loud on stderr, once, because a fallback
   nobody can see is how the next wrong mount happens.

An explicitly named distribution that resolves to nothing **fails by name**. It
does not fall back to the default: entering Debian when Alpine was asked for is
the failure this whole scheme exists to prevent.

## 3. What did NOT have to change

This is the interesting half, because it is the evidence that the rest of the
stack was already general:

* **`hamsh`.** `alpine = ns clean { … }` and `enter alpine { … }` needed nothing.
  The shell never knew what a distribution was; it captures a description and
  enters it.
* **`enter_root()`** — the `MS_MOVE` + `chroot` root switch (commit cd4e661a),
  and the `always[]`/`sysroot_only[]` split that keeps a subtree's own `/tmp`.
  Identical for a musl root.
* **`wsyswl`.** The Wayland socket path is an argument:
  `wsyswl /n/alpine/run/wayland-0`. The compositor never had a Debian path in
  it; the crossing was always a name.
* **`wsysd`, `/dev/wsys`, `/dev/fb`.** Untouched.
* **The user-namespace acquisition** in `ns_privilege()` — `unshare(CLONE_NEWUSER
  |CLONE_NEWNS)` with an identity uid map. Same for both.

## 4. Alpine, and why Alpine

`scripts/hamlinux_alpine.sh`. The choice is argued at the top of that script;
in short:

1. **musl, not glibc.** That is the point. Everything the tree might have
   accidentally assumed about "a Linux root" while Debian was the only one —
   the loader's name, `/lib64`, NSS, bash, `useradd` — is different here, so
   anything Debian-shaped fails instead of being silently accommodated. It
   found one immediately: busybox has `adduser`, not `useradd`. Fedora would
   have been glibc plus a different package manager, which proves something
   nothing here ever claimed.
2. **It bootstraps unprivileged with no distro-specific host tool.** Fedora
   wants `dnf --installroot` (and rpm on the host); Arch wants `pacstrap`.
   Alpine's minirootfs is a 3.7 MB tarball with `apk` inside it. **No host
   package was installed for this work.** (`mmdebstrap` had to be, for Debian.)
3. **Size.** See §5.

The build is `unshare --map-auto --map-root-user -m`, then chroot + `apk add`,
then `mke2fs -d` from inside that namespace so the recorded ownership is
Alpine's rather than the builder's. `--map-auto` and not plain `--map-root-user`
because the tarball contains files owned by gid 42 (`shadow`) and a single-uid
map cannot restore them.

## 4a. What the second distribution found

Both of these are the reason for doing this with musl rather than another
glibc distribution, and neither would have shown up in Debian.

* **`busybox` has `adduser`, not `useradd`.** The Debian image creates the
  uid-1001 `live` account with `useradd`; the first Alpine build's account
  creation failed, and the *symptom* would have been `getpwuid()` returning
  NULL inside the namespace — which is what stopped Steam from starting on the
  Debian side once, and takes a while to trace back to a missing passwd entry.
* **Alpine's `xwayland` package depends on `xkbcomp` but not on the keymap
  DATA.** Without `xkeyboard-config`, Xwayland starts, fails to compile a
  keymap, and dies with `Failed to activate virtual core keyboard: 2`. The
  first run of `tests/linux/alpine_gui_run.sh` showed: a clean console, a live
  Wayland socket, the right screen size from `hamnix-screen`, and **a desktop
  with no window on it**. Debian's `xwayland` pulls `xkb-data` transitively and
  never had to say so.

And one that was ours rather than Alpine's, recorded because it is the tree's
favourite failure shape: **`xdpyinfo` against a socket whose server is not yet
accepting does not fail, it blocks in `connect()`.** The session script's
"wait for the server, not the socket" loop was bound at 15 s of sleeps and was
still inside it 45 s later; the only symptom was a session log that stopped
mid-way, which reads exactly like "it got that far and hung". Every probe in
that script is now under `timeout`, and the probe failing is no longer fatal —
the client starts anyway and the screendump is the measurement, because
refusing to run it would replace a picture with an opinion.

## 5. What it costs

Measured with `du -m` on this host, all images sparse:

| namespace | rootfs tree | image on disk | apparent |
|--|--|--|--|
| Debian bookworm, amd64+i386, Steam+clang | — | **4.5 GiB** | 12 GiB |
| Alpine 3.24.1 + `HAMLINUX_ALPINE_GUI=1` | 273 MiB | **337 MiB** | 2 GiB |
| Alpine 3.24.1 + `HAMLINUX_ALPINE_GUI=0` | 9 MiB | **26 MiB** | 512 MiB |

The GUI set is `xwayland xkeyboard-config xeyes xclock xdpyinfo font-dejavu`.
Its 264 MiB is
almost entirely **Mesa and llvm-libs**, which Alpine's `xwayland` package
depends on even though this session runs `Xwayland -shm` and never touches GL.
That is an honest number and not a small one; it is also 14× smaller than the
Debian namespace, and the no-GUI image — a complete second distribution you can
`enter` and run a shell in — is **26 MiB**, which is 0.6% of Debian's.

`HAMLINUX_ALPINE_GUI` is the optional flag, in the same spirit as
`HAMLINUX_I386` for Debian: default 1, set 0 to leave the graphics stack out.
The image itself is optional by not being built —
`scripts/hamlinux_vm.sh` attaches `build/image/alpine.ext4` only if it exists,
and a boot without it prints the `no distribution namespace named 'alpine'`
line and carries on with Debian.

## 6. Verified

`tests/linux/two_namespaces.sh` — one boot, both namespaces, both uids, plus a
negative control (`/etc/alpine-release` must NOT be readable from inside the
Debian namespace, or the two "namespaces" are one tree and every other line
proves nothing). Each arm prints the contents of a file that exists in only one
of the two trees, so an `enter` that entered nothing cannot produce a passing
line.

`tests/linux/alpine_gui_run.sh` — an X client from the Alpine namespace on the
Hamnix desktop, screendumped off the QEMU monitor: **`xeyes` from Alpine
3.24.1, on the Hamnix desktop, tracking the pointer** (`build/alpinegui/alpine.png`,
1280x800). Same four hops as Debian's:

```
X client -> Xwayland -> wsyswl -> wsys v2 blit -> wsysd -> /dev/fb -> scanout
```

`tests/linux/enter_user_run.sh` — unchanged, and still the acceptance test for
the Debian case.

## 7. What is still Debian-shaped

Named precisely, because a half-general mechanism described as general is worse
than a special case described as one.

1. ~~**The DE application menu.**~~ **DONE.** The scan is driven by
   `/etc/distros`: one section per distribution actually attached under `/n`,
   named after it, each row launching `enter <name> { … }`. See §8.
2. ~~**`user/install.ad`.**~~ **DONE, and it was the wrong file.** See §9.
3. **`user/xbridge.ad`** and several tests spell `/n/distro` literally. That
   name is kept bound for exactly this reason, so they work; they are just not
   parameterised.
4. **`tests/linux/hamnix_x11session.sh`** is Debian's session script (dbus,
   Steam). Alpine has its own, baked into its image by the build script.
   The two share their three hardest-won lines (wait for the *server*, not the
   socket; take the X screen size from `hamnix-screen`; ask the X server
   whether the window manager is actually managing, rather than the process
   table whether it started) by copy, not by a common file. Worth merging when
   there is a third. What they DO share as one file is the window manager's
   configuration: `etc/jwmrc.linux`, installed by both build scripts as
   `/etc/jwm/hamnix.jwmrc` — see `docs/linux_window_manager.md`.


---

## 8. The DE application menu, N sections

`user/hampanelscene.ad` held one literal path, `/n/linux/usr/share/applications`,
and one menu section called "Linux". It now reads the same description the
rest of the system reads.

**The panel reads only the NAMES out of `/etc/distros`, and that is the whole
design rather than an economy.** A `source` is a volume label; resolving one
means opening a block device; the panel could do it today (it runs as the host
owner) and a session-owned panel could not. The name is what crosses, and
`/n/<name>` is where the boot already posted the server — §2.4 again, one
layer up.

Three states, deliberately distinct, because this was a **dead path being made
live** and each of the wrong answers here is success-shaped:

| state | menu |
|--|--|
| named in `/etc/distros`, `/n/<name>` empty or absent | **no section.** The distribution is described, not attached. A section would claim a namespace that is not there and every click would launch into nothing. The panel says which one, once, on its log. |
| attached, but no `usr/share/applications` (or nothing displayable in it) | a section with one disabled row, `No <name> apps installed`. The namespace IS there; it ships no launchers. A different fact. |
| attached with launchers | the section, its apps, `enter <name> { … }` |

Entries sort by `cat = DE_CAT_LINUX + <section index>`, so each distribution's
rows stay contiguous and after the native ones: a section is a SLICE of the one
model, not a second model.

### 8.1 Four things this turned up, all of which were already broken

* **`etc/rc.boot.linux` bound the distributions AFTER `source '/etc/rc.d/rc.5'`.**
  The panel scans at startup, so a panel started first sees nothing. The binds
  now come first, in both boot rcs.
* **The Applications button was pointed at `/bin/hamappmenu`** (#263, a separate
  v2 window client) **which this line does not build.** So the button spawned a
  program that does not exist, printed `[panel] launched /bin/hamappmenu -self`,
  and opened nothing — on every image ever built here. It now falls back to the
  panel's own dropdown when the client is absent, and says which one it used.
* **`sub_open` is one global; `menu_open` is per panel.** The image ships two
  panels, so the bottom taskbar draining any pointer event read its own
  `menu_open` of 0 and closed the *other* panel's fly-out. The dropdown stayed
  up and the fly-out vanished with nothing said.
* **Alpine's only `.desktop` file was `org.freedesktop.Xwayland.desktop`**, which
  carries `NoDisplay=true` and is correctly hidden — so an Alpine section could
  only ever have been empty, and "Alpine ships no launchers" would have looked
  exactly like "the scan is broken". `xterm` is now in the Alpine GUI set: it is
  the one member of that set that ships a `.desktop`, and an Alpine shell in a
  window from the menu is the useful thing to put there anyway.

### 8.2 The rc scripts are GENERATED from the table

The same five-line `ns clean { }` recipe used to be written out by hand once per
distribution in three files — `etc/rc.boot.linux`, `etc/rc.boot.installed`,
`etc/rc.de-user.linux` — and they had drifted: the installed one had none of
them. `scripts/hamlinux_image.sh` now generates `/etc/rc.distros` from
`/etc/distros` and all three `source` it, so they agree by construction.

It is generated rather than looped at boot because **hamsh's `enter` takes a
namespace VALUE, not a string**: `NS='alpine'; enter $NS { }` cannot be written
at all, a template has to be captured under a literal name. Generating the
literals from the table is how the table stays the only place a distribution is
named.

`/etc/rc.distros-wl` (one `wsyswl` per distribution, socket inside its own tree)
and `/etc/rc.de-ns/<name>` (the DE launcher rc) are generated the same way.

### 8.3 Verified

`tests/linux/distro_menu.sh` — one boot, the menu driven OPEN by synthetic
pointer events written into the panel window's event ring, three screendumps,
and the panel's **display list** read back per fly-out. The scene is the
evidence: `glyphs … "Install Steam"` is the panel having drawn that row.
Debian's catalogue has `Install Steam` and Alpine's does not, so
"drawn while hovering the first section, NOT while hovering the second" is the
negative control that distinguishes two real sections from one list drawn twice.

`docs/screenshots/linux/distro-menu-debian.png`,
`docs/screenshots/linux/distro-menu-alpine.png`.

### 8.4 Launching an app from the fly-out — and the diagnosis that was wrong

**This section used to say the following, and every clause of it was mistaken
in the same way.** It is kept verbatim because the shape of the error is the
lesson:

> …reaches `enter <name>` — where the **first** bind of the template, the root
> switch, fails `ENOENT` (`chdir("/n/<name>")` inside the entered child). The
> identical five lines DO work at uid 1001 from a console shell and from a
> desktop terminal, so it is something about this **spawned shell's
> namespace** rather than the template or the drop. Three shapes of the
> launcher rc were built and measured…

Three shapes of the rc were built, three passes were spent on the spawn gate
and `rfork`, and **nobody had ever asked which bind failed.** `hamsh` printed

```
hamsh: namespace not entered -- a bind in the template failed, so the body was NOT run.
hamsh: bind performs a real mount(2) and needs CAP_SYS_ADMIN; a desktop session runs as uid 1001.
```

— a fixed sentence naming a fixed suspect, printed in the place where the
measured answer belonged. The failure was `ENOENT`; the text asserted `EPERM`.
It is the same class of fault as every entry in NORTH_STAR.md's list, except
that here the thing answering something success-shaped was the *error
message*.

#### What it actually is

`hamsh` now names the bind (`_ns_apply_failed`), and the first run said:

```
bind: could not graft `/' onto `/n': No such file or directory
hamsh: first failing bind: #/ -> /n: No such file or directory
```

The **last** bind of the template, not the first. The root switch had already
succeeded.

`enter <name>` binds `/dev`, `/proc`, `/srv` and `/n` **into** the
distribution's own root (`enter_root`'s `always[]`, plus the four bind lines
every `ns clean { }` template carries). A bind whose **target directory does
not exist** fails `ENOENT`, and the session user cannot create one: the
distribution's `/` is uid 0, and **uid 0 is not mapped into the user namespace
`ns_privilege()` acquires**, so `CAP_DAC_OVERRIDE` does not reach it.
`enter_root` calls `mkdir()` for exactly this reason and ignores the result —
because at uid 0 it always worked.

So the directories only ever existed as a **side effect** of somebody having
run `enter <name>` **as root** earlier, on a **writable** medium, where that
ignored `mkdir` succeeded and left them behind on the disk. Measured, with
`debugfs -R 'ls -l /'` on the two media:

| medium | `/dev` | `/proc` | `/srv` | `/sys` | `/n` |
|--|--|--|--|--|--|
| `build/image/distro.ext4` (Debian) | yes | yes | yes | yes | **yes** |
| `build/image/alpine.ext4` (Alpine) | yes | yes | yes | yes | **no** |

Debian had been entered by root at some point in its life; Alpine had not.
That single missing directory is the whole of it, and it explains every
observation the old text could not:

* **why the console and the desktop terminal worked** — `two_namespaces.sh`
  and `enter_user_run.sh` both run a *root* `enter` before the uid-1001 one,
  which creates the directories in the same boot;
* **why "three shapes of the rc" differed only in how many binds failed** —
  the count is the number of mount points missing from that root, nothing more;
* **why it looked like the spawned shell** — the spawned shell was simply the
  one launcher that reaches `enter` before any root `enter` has.

The negative control is direct: a spawned `hamsh`, at uid 1001, with the same
three top-level binds, entered Alpine and ran `/bin/busybox` **successfully**
— in a boot where a root `enter alpine` had run first. Same shell, same
template, same privilege drop, opposite result.

#### The fix

The mount points are made **by root, at the one moment root holds the
medium**: when the boot posts the server at its name with
`bind '#distro/<name>' /n/<name>`. `user/linux-syscalls.c`,
`distro_stage_mountpoints` — root only, `EEXIST` is success, and a medium that
refuses the `mkdir` (a read-only one) **says so then**, naming the path,
because that failure predicts the `ENOENT` an unprivileged `enter` will hit
later.

Measured, one boot, running the generated launcher rcs exactly as the panel
spawns them:

```
/bin/hamsh /etc/rc.de-ns/alpine /sbin/apk    -> apk-tools 3.0.6-r0, compiled for x86_64.
/bin/hamsh /etc/rc.de-ns/debian /usr/bin/dpkg -> Usage: dpkg [<option>...] <command>
```

Both programs exist only inside their own distribution.

#### The second gap, which was underneath it

A `.desktop` file in a distribution names an **X11 client**, and nothing in
the namespace was serving X — so even a successful `enter` produced a program
that could not open a display and exited. A desktop that offers to launch an
application owes it a display. `etc/de-ns-run.linux` is that: a POSIX-sh shim
staged into the Hamnix root, copied into each tree by the generated
`/etc/rc.distros` (it has to be a file *inside* the tree, because by the time
it runs that tree is `/`), and run by `/etc/rc.de-ns/<name>` instead of the
program directly. It delegates to the distribution's own
`/usr/local/bin/hamnix-x11session` when there is one — those are the measured
recipes and this must not become a divergent second copy of them — starts a
minimal Xwayland + `jwm` session when there is not, and runs the program as it
is when the distribution has no Xwayland at all. `HAMNIX_DE_XSESSION=0` skips
the session, so a test asking about the *namespace* does not have to pay for
an X server to find out. Everything it does lands in `/tmp/de-ns-run.log`
**inside** the tree — i.e. `/n/<name>/tmp/de-ns-run.log` from the Hamnix side,
the one path both sides can read.

`tests/linux/distro_menu.sh` no longer prints a `GAP` for the namespace. It
runs both generated launcher rcs, **clicks a fly-out row** with synthetic
pointer events, reads the shim's log back across the namespace boundary, and
takes a fourth screendump of what came up.

### 8.5 The Wayland socket was not writable by the session user — FIXED

**The click works. The namespace works. The application starts. It cannot
reach the display**, and this is the third fault of the same family in one
path, which is why it is worth naming as a family rather than as three bugs.

Measured, from `/n/debian/tmp/de-ns-run.log` — the shim's log, read from the
Hamnix side:

```
=== de-ns-run Tue Aug 11 11:29:38 UTC 2026: uxterm
de-ns-run: delegating to /usr/local/bin/hamnix-x11session
hamnix-x11session: wayland socket /run/wayland-0
srwxr-xr-x 1 nobody nogroup 0 Aug 11 11:28 /run/wayland-0
hamnix-x11session: Xwayland FAILED TO START
_XSERVTransmkdir: Owner of /tmp/.X11-unix should be set to root
could not connect to wayland server
(EE) Fatal server error:
(EE) Couldn't add screen
```

`connect(2)` on a unix socket requires **write** permission on the socket.
`/etc/rc.distros-wl` starts one `wsyswl` per distribution **as root**, at
runlevel 5, and the socket comes out `srwxr-xr-x` — owner-writable only, and
the owner is a uid that is not even mapped into the entering process's user
namespace (`nobody nogroup` is what uid 0 looks like from in there). So the
one thing a menu-launched application must do — connect to the display — is
the one thing the session user cannot do.

**Nothing had ever hit this**, and the reason is the same as everywhere else
in §8.4: every previous GUI-in-a-namespace run (`steam_gui_run.sh`,
`alpine_gui_run.sh`) ran its client **as root**, where the socket mode never
mattered. The DE application menu is the first caller that is unprivileged by
construction.

#### The fix: `wsyswl` chmods its own socket 0666 at creation

Two shapes were on the table, and the one this section used to prefer is the
one that does not work.

**Chosen: give the socket a mode a session can connect to.**
`user/wsyswl.ad`, immediately after `sys_unix_listen`, `sys_chmod(sockpath,
0o666)`. `bind(2)` creates a unix socket 0777 masked by the umask, which is
022 in every boot here, hence `srwxr-xr-x`. The server already knows its own
socket path — it is `argv[1]` — so the mode is set in the one place that
cannot be forgotten by a caller, atomically with creation, and a failed
`chmod` is named on stderr rather than leaving a display server that accepts
zero connections while printing `listening on …` exactly as it does when it
works.

**0666 is not a loosening, and the precedent is this tree's own.** `/srv/wsys`
is 0666 deliberately (`user/linux-wsys.c`, THE SPLIT; commit `ad440707`,
`tests/linux/wsys_bypass.sh`): a uid-1001 client has to be able to map and
draw its *own* window, and a desktop whose session cannot is unprivileged and
blind. The system chrome was moved to a **second** segment at 0644 owned by
the host owner, so for chrome the file mode is the gate and the kernel
enforces it. The same line falls in the same place here. What a connection to
this socket buys is a Wayland client session — bind `wl_compositor`, map a
surface, commit your own pixels — which is exactly the 0666 half. And
`wsyswl` issues **no gated verb on a client's behalf**: it drives `newwindow`
(devwsys's explicit pre-gate exception, "so a NOBODY-uid app can self-serve a
window") and the per-window `<wid>/ctl` verbs `decorate` / `z` / `version` /
`title` on windows it owns itself, every one of them owner-or-hostowner. It
*reads* `/dev/wsys/screen`, which 0644 grants everybody and which was never
gated. Nothing about connecting reaches the chrome.

**The blast radius is the directory, which is the point.** The mode is on the
socket; the access control is the path — which is how every Wayland
compositor's `$XDG_RUNTIME_DIR` socket has always worked. This socket is at
`/n/<name>/run/wayland-0`, inside **one distribution's own `/run`**, so
"anyone who can reach this path" is "anyone already inside that distribution's
namespace, plus root". That is exactly the set that should be able to draw on
that distribution's display, and it is narrower than the host-wide `/srv/wsys`
the same argument already justifies.

**Rejected: start the per-distribution `wsyswl` as the session user.** It is
the better shape in principle — a compositor serving a session need not be
root, the same argument as `etc/rc.de-user`'s privilege drop one layer out —
and the reason given above for not doing it was wrong in both halves. It does
**not** need `/dev/fb`: `wsyswl` never opens the framebuffer, `user/wsysd.ad`
does; `wsyswl` is a *client* of `/dev/wsys`. And the uid gate is not the
blocker either, for the reason just given — every verb it issues is ungated.
What actually blocks it is the **directory**: the socket lives at
`/n/<name>/run/wayland-0` and that `/run` is root-owned 0755, so a uid-1001
`wsyswl` could not create the socket, the `hamnix-screen` geometry file or
`wsyswl-state` there at all. Starting the server as the session user therefore
does not remove root-prepared state; it *moves* it, and widens the blast
radius from one socket to the whole directory. It also needs new machinery —
`rc.5` must stay root after sourcing `/etc/rc.distros-wl`, so each server
would need its own generated setuid-then-exec rc.

**Measured, one boot, the same path a person takes** — click a fly-out row,
then read the shim's log back from the Hamnix side:

```
=== de-ns-run Tue Aug 11 12:20:12 UTC 2026: uxterm
de-ns-run: wayland socket srw-rw-rw- 1 nobody nogroup 0 Aug 11 12:19 /run/wayland-0
de-ns-run: delegating to /usr/local/bin/hamnix-x11session
hamnix-x11session: screen 1280x800 from /run/hamnix-screen
hamnix-x11session: Xwayland up (  dimensions:    1280x800 pixels (339x212 millimeters))
hamnix-x11session: exec uxterm
```

`srwxr-xr-x` → `srw-rw-rw-`, and the two facts
`tests/linux/distro_menu.sh` reports separately — "launched" and "got a
display" — are both PASS, with the whole gate at 0 FAIL.
`docs/screenshots/linux/distro-menu-launched.png` is that xterm,
mapped by `jwm` inside the Debian namespace, composited through Xwayland →
`wsyswl` → `wsysd` → `/dev/fb`, on the Hamnix desktop with the taskbar reading
`Xwayland on :`. (Its interior is blank because bookworm's `uxterm` cannot find
`-misc-fixed-medium-r-semicondensed--13-120-75-75-c-60-iso10646-1` in that
medium — a missing font package, not a display fault; the window is mapped,
sized and on the scanout.)

#### The fourth fault, which is the directory itself — FIXED

§8.4 and this section name three: a mount point in the medium (`/n`), a stale
X lock in its `/tmp`, a socket in its `/run`. Looking for the fourth in the
same family found it one level up from the third. Measured with `debugfs` on
both media, and what it is now:

| path | mode | uid | now |
|--|--|--|--|
| `/run` (`= $XDG_RUNTIME_DIR`) | `40755` | 0 | unchanged — no longer `$XDG_RUNTIME_DIR` |
| `/run/user/1001` (`= $XDG_RUNTIME_DIR`) | — | — | `40700` uid **1001**, staged at boot |
| `/run/wayland-0` | `140755` → `140666` | 0 | unchanged; symlinked into the above |
| `/run/hamnix-screen` | `100644` | 0 | unchanged; symlinked into the above |
| `/run/dbus` | `40755` | 0 | `40755` uid **1001** — mode untouched |
| `/run/dconf` | `40700` | 0 | `40700` uid **1001** — mode untouched |

So the session could **read** everything `wsyswl` publishes there — the
socket's mode was the only thing in the way, and the two sibling files are 0644
already — and could **create nothing**. Fixing the socket mode fixed
*connecting*; it never touched *creating*, and the casualties were already
known: `dbus-daemon --system` could not make `/run/dbus/system_bus_socket` as
uid 1001, which is the unprivileged half of the D-Bus gap in `HANDOFF.md` §0,
and every toolkit that wants a runtime file landed on `/run/dconf`, mode 0700
root.

#### The fix: `/run/user/<uid>`, staged by root at boot — and nothing moves

A per-user `$XDG_RUNTIME_DIR` is normally `/run/user/<uid>`, owned by that uid
and mode 0700 — **narrower** than the `/run` it replaces, not wider: the
session gets a directory of its own instead of read-and-traverse over the whole
of a distribution's runtime state. The alternative, making a distribution's
`/run` world-writable, hands every principal in the namespace write access to
the display socket's directory to solve one uid's problem, and it is a real
access-control decision that does not belong in a launcher shim.

**Who creates it, and when.** There is no systemd here, so the pattern is this
tree's own: **root prepares it at boot, at the moment the boot posts the server
at its name.** `bind '#distro/<name>' /n/<name>` is that moment, and it is
already where the *first* fault of this family was fixed. `distro_stage_runtime`
(`user/linux-syscalls.c`) sits beside `distro_stage_mountpoints` and is called
from it — root only, `EEXIST` is success, a read-only medium says so once per
path.

**Nothing moves on disk, which is what makes it affordable.** The reason this
was not taken earlier is real: **four** files name the socket by its `/run`
path, and none of them is one file —

| dependant | what it names | what it needed |
|--|--|--|
| `hamnix-x11session`, Debian (`tests/linux/hamnix_x11session.sh`) | `export XDG_RUNTIME_DIR=/run`, then `$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY` and `$XDG_RUNTIME_DIR/hamnix-screen` | nothing — `/run/wayland-0` is still there |
| `hamnix-x11session`, Alpine (baked into the medium by `scripts/hamlinux_alpine.sh`) | the same two names, a second copy | nothing — same reason |
| `tests/linux/alpine_gui_run.sh` | starts a `wsyswl` by hand at `/n/alpine/run/wayland-0` | nothing |
| `tests/linux/steam_gui_run.sh` | plants the Debian session script and its `/run` paths | nothing |
| `tests/linux/x11_geom_probe.sh` | sets `XDG_RUNTIME_DIR="$WORK"` — a host-side offscreen run | nothing; it never sees a distribution's `/run` |

So the socket **stays** at `/run/wayland-0`, and what goes into the new
directory is a **symlink per published name** — `wayland-0`, `hamnix-screen`,
`wsyswl-state`, each `../../<name>`. `connect(2)`, `[ -S ]`, `[ -r ]` and
`read` all follow symlinks, so `$XDG_RUNTIME_DIR/wayland-0` — exactly what
libwayland's `wl_display_connect(NULL)` builds — resolves for a client that has
never heard of `/run/wayland-0`. The links dangle between `rc.boot` and `rc.5`,
when the per-distribution `wsyswl` actually posts its socket; a dangling
symlink is the correct state for a name whose server has not started, and it is
the same *post the server at its name* order everything else here is built on.
`wsyswl` did not have to change at all.

`/etc/rc.de-ns/<name>` (generated by `scripts/hamlinux_image.sh`) now exports
`XDG_RUNTIME_DIR=/run/user/1001`, and `XDG_CONFIG_HOME` with it — that had been
pointed at `/run` too, for the same bad reason: the first directory that
existed rather than the first one this uid could write. `/etc/de-ns-run`
prefers `/run/user/$(id -u)` over any inherited value that is **not writable**,
and leaves a writable inherited value alone.

**The witness had to change one character.** `/etc/de-ns-run` logs the socket
from **inside** the namespace, and `tests/linux/distro_menu.sh` gates on
`srw-rw-rw-` in that line. `$XDG_RUNTIME_DIR/wayland-0` is now a symlink, and
`ls -l` on a symlink prints `lrwxrwxrwx`. It is `ls -lL`: the fact the line
exists to witness is the mode of the thing `connect(2)` opens, and `-L` prints
that whether the path is a link or the socket itself.

**And the probe writes.** `[ -w ]` answers from the mode bits, and this entire
family of faults is the mode bits being read correctly while the effective
answer is still no — an unmapped uid, a sticky `/tmp`, a read-only medium under
`HAMLINUX_DISTRO_RO=1`. `/etc/de-ns-run` creates a file and reports the result
either way. Measured, one boot, `tests/linux/distro_menu.sh`, 0 FAIL:

```
de-ns-run: wayland socket srw-rw-rw- 1 nobody nogroup 0 /run/user/1001/wayland-0
de-ns-run: runtime dir /run/user/1001 is WRITABLE by uid 1001: created /run/user/1001/.de-ns-run-probe.226
de-ns-run:   (drwx------ 2 live live 4096 /run/user/1001)
de-ns-run: /run/dbus is writable by uid 1001; the system bus can be started here
```

#### The system bus is a SEPARATE directory and a separate answer

Worth stating plainly, because conflating the two is the obvious mistake here:
**`/run/user/<uid>` does not bring the system bus up.**
`/run/dbus/system_bus_socket` is a **compile-time** path in dbus and no
environment variable moves it. Getting `$XDG_RUNTIME_DIR` right fixes the
*session* bus and dconf and leaves `system_bus_socket': Permission denied`
exactly where it was.

There are two ways to close it and only one is small. Root could start a bus
per distribution at boot — new machinery, a daemon supervised by nobody. Or the
one principal that actually runs the bus can own the directory it must write:
nothing here starts the system bus as root, `hamnix-x11session` runs
`dbus-daemon --system` itself **as uid 1001**. So `distro_stage_runtime`
**chowns** `/run/dbus` and `/run/dconf` to the session user and leaves their
**modes untouched** (0755 and 0700). Inside a distribution namespace there is
exactly one session user, so this transfers a directory rather than sharing it,
and no other uid gains anything. If a distribution ever grows a real root-run
bus, that is the line to delete.

It works, and this is the unprivileged half of the D-Bus gap in `HANDOFF.md` §0
closing. Same boot as above:

```
hamnix-x11session: stale /run/dbus/system_bus_socket (no live dbus-daemon); removing
hamnix-x11session: machine id dfb3872d1bce5b75b8a82f766a7aa5b9
hamnix-x11session: system bus live on /run/dbus/system_bus_socket (pid 262)
hamnix-x11session: system bus ANSWERED GetId
hamnix-x11session: session bus unix:path=/tmp/dbus-0Y6duvEPCy,guid=...
```

The `removing` line is the second thing that had been failing: the previous
boot's `rm: cannot remove '/run/dbus/pid': Permission denied` was a root-owned
file in a root-owned directory. Unlinking needs write on the **directory**, and
`/run/dbus` is not sticky, so the session can now clear a stale bus left by a
root-run session — the same shape as the `/tmp` half of §8.5, one directory
over.

#### Two faults in the GATE, found by the fix making the run get further

Both were latent for as long as the gate has existed and neither could fire
until a menu-launched application actually reached a display. They are
recorded because the shape is this project's own, run backwards: not a gap
answering something success-shaped, but a **check answering something
failure-shaped instead of the truth.**

1. **The log became binary.** Once the socket was connectable, the shim really
   did start Xwayland, `jwm` and an xterm inside the namespace, and their
   output — which the guest `cat`s onto the console — carries NUL bytes. Two
   `grep`s in `distro_menu.sh` lacked `-a`, so they matched nothing and
   reported *"`/etc/rc.de-ns/debian` did not reach the Debian root"* about a
   launcher whose own log, printed four lines above in the same output, showed
   it reaching it. `lrc()`/`DENS()`/`sect()` now strip `\0` as well as `\r`.

2. **`grep -q` in a pipeline under `set -o pipefail` reports failure on a
   successful match.** `grep -q` exits 0 the instant it matches; the upstream
   `tr` is still writing, takes `SIGPIPE`, and dies **141**; `pipefail` then
   makes the pipeline's status 141 and the `if` takes the `else` branch. It is
   a race on how much is still buffered, so it passed for as long as this log
   was short and began failing every time the moment the log grew. Measured
   directly, same log, same shell options: the old `lrc | grep -aq …` form
   **200 failures in 200 attempts, status 141**; grepping a captured
   here-string instead, **0 in 200**. Every check in the file that decides a
   PASS now greps `"$LRC_TEXT"` / `"$DENS_TEXT"` / `"$SECT_FIRST"` /
   `"$SECT_SECOND"` — captured once — rather than a pipeline.

The second one is worth remembering beyond this file: **every**
`something | grep -q` in a `pipefail` script has it, and it fails in the
direction that turns a working system into a red gate.

#### Does the environment cross `enter`? Yes — and the drop is somewhere else

This section used to record, explicitly unmeasured, that `enter` against an
`ns clean { }` template rforks with `RFCNAMEG` whose Pgrp is empty, that
`hamsh` re-seeds only `/fd` in that child, and that the environment therefore
"does not appear to cross" — the evidence being that `HAMNIX_DE_XSESSION=0`,
exported before the `enter`, did not reach `/etc/de-ns-run`.

**The observation was right and the mechanism was wrong, and the difference
matters because the two boundaries are fixed in different places.**
`tests/linux/enter_env.sh` asks the two separately, with sentinel values that
no default anywhere in the tree would produce — `WAYLAND_DISPLAY` is set to
`envx-sentinel-wl`, not to `wayland-0`, precisely because the shim defaults
all four variables and a probe that reads back a default has learned nothing.

* **`enter` carries the environment.** `rfork(RFPROC|RFCNAMEG)` is a process
  **fork**; `RFCNAMEG` empties the Pgrp — the mount table — not the address
  space. `hamsh`'s exported variables live in ordinary BSS arrays
  (`env_name` / `env_val` / `env_used`, `user/hamsh.ad`), the fork copies
  them, and `_build_envp()` renders `envp` from that copy for the `execve`.
  Nothing in that path touches the namespace. `enter debian { /usr/bin/env }`
  — Debian's own `env(1)`, running inside the namespace — prints back:

  ```
  [envx] A-BEGIN
  PATH=/bin:/sbin:/usr/bin
  HOME=/envx-sentinel-home
  HAMNIX_ENVPROBE=envx-crossed
  WAYLAND_DISPLAY=envx-sentinel-wl
  XDG_RUNTIME_DIR=/envx-sentinel-run
  HAMNIX_DE_XSESSION=0
  [envx] A-END
  ```

  Every sentinel, across `enter`, into a program that exists only in the other
  root.
* **A fresh `hamsh` drops it.** `main()` seeds the mirror with exactly
  `PATH=/bin:/sbin:/usr/bin` and `HOME=/` and **never reads the inherited
  `environ`** — the header comment says a fresh shell "seeds the mirror from
  /env at startup", and on this line there is no `#e` device to seed from. So
  anything an ancestor exported is dropped at the **`exec` into a new
  `hamsh`**, one level *above* the `enter`. The same boot, arm B:

  ```
  [envx] B1 new-hamsh sees HAMNIX_ENVPROBE=
  [envx] B2 new-hamsh sees WAYLAND_DISPLAY=
  [envx] B3 new-hamsh, across enter:
  PATH=/bin:/sbin:/usr/bin
  HOME=/
  ```

  Exactly the two seeds `main()` sets, and nothing else. `enter` carried
  faithfully what that shell actually had, which was nothing.

That is exactly where `HAMNIX_DE_XSESSION` went: it was exported in the boot
rc's `hamsh` (PID 1), and the launcher is a **separate**
`/bin/hamsh /etc/rc.de-ns/<name> <prog>` process — which is also precisely how
the DE panel spawns it. The variable never reached that shell, so `enter` had
nothing to carry.

The practical consequences, which are the reason to write this down:

* The `HOME` / `XDG_RUNTIME_DIR` / `WAYLAND_DISPLAY` / `XDG_CONFIG_HOME`
  exports at the bottom of `/etc/rc.de-ns/<name>` **do** reach the client.
  They are set in the same `hamsh` process that then runs `enter`, so they are
  in the mirror the fork copies. They are not decorative and the shim is not
  merely re-deriving them.
* `HAMNIX_DE_XSESSION` **cannot** be steered from an outer shell, and no
  amount of work on `enter` will change that. It has to be set inside the
  launcher rc, or passed as an argument.
* `env_set` silently `return`s when the 32-slot table is full, and values are
  capped at 192 bytes. Nothing here is near either bound, but both are silent.

The four faults, together, are one lesson: **a namespace's contents are not
the namespace's interface.** Four resources — a directory in the medium
(`/n`), a lock file in its `/tmp`, a socket in its `/run`, and the `/run` that
holds it — were each created by root at a moment when root was the only one
who ever used them, and each became invisible to the unprivileged session that
came later. Each failed silently, and each now says which resource, which uid,
and what would fix it.

---

## 9. The installed disk — and `user/install.ad` was the wrong file

§7 item 2 said `user/install.ad` writes one named root, `distro distro`, into
an installed disk's `.hamnix-roots`, and that a second distribution would need a
second subtree and a second sentinel line.

**That is true of Hamnix and false of this line, and the difference is worth
recording because it is the shape of the whole port.** `.hamnix-roots` is read
by the *Hamnix kernel*, which posts each named subtree as a file server before
ELF-loading `/init`. There is no kernel doing that here: `#sysroot` resolves to
a device (`sysroot_device()`, from the kernel command line) and `bind` performs
the mount itself. Nothing on this line reads `.hamnix-roots` at all — `grep`
finds it only in `user/install.ad`, `user/useradd.ad` and comments.

An installed hamnix-linux disk is built by `scripts/hamlinux_disk.sh`, and the
distribution media are **the same two labelled filesystems**, attached as their
own disks. So a second distribution on an installed disk needs no second
subtree and no sentinel: it needs the installed boot rc to do what the live one
does.

It did not. `etc/rc.boot.installed` had **no distribution bind and no
`ns clean { }` template in it at all**, so `enter debian { sh }` on an installed
system answered `enter: debian is not a namespace template`. The subsystem
worked on every boot that is thrown away and on none of the boots that persist,
and nothing said so, because no test had ever booted an installed disk and
typed the command.

It now `source`s the same generated `/etc/rc.distros` the live boot does, before
runlevel 5.

**`HAMLINUX_DISK_RC`** (`scripts/hamlinux_disk.sh`) stages a different
`/etc/rc.boot` onto the root partition, the way `HAMLINUX_RC` does for the
initramfs — an installed disk was the one boot with no hook, which is exactly
why it was the one boot never under test. The real rc is staged alongside as
`/etc/rc.boot.installed`, so a test's rc can `source` it verbatim and then ask
its questions.

`tests/linux/installed_distros.sh` — build a disk, boot it through UEFI, and
from the installed root: `enter alpine` -> `3.24.1`, `enter debian` -> `12.15`,
the `linux` alias -> `12.15`, the negative control (Alpine's release file is not
readable inside Debian) and **both again as uid 1001**, which is the arm that
proves the mount-point fallback of §2.4 still holds on a machine whose disk
enumeration is nothing like the live boot's. 12 PASS.
