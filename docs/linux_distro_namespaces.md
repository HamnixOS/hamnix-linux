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

`tests/linux/distro_menu.sh` no longer prints a `GAP`. It runs both generated
launcher rcs, **clicks a fly-out row** with synthetic pointer events, reads the
shim's log back across the namespace boundary, and takes a fourth screendump
of what came up.

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
