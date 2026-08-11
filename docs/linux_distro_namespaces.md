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

1. **The DE application menu.** `user/hampanelscene.ad`'s `_linux_apps_dir()`
   is the literal string `/n/linux/usr/share/applications`, and the menu has
   exactly one "Linux" section. To carry N distributions it needs the scan to
   be driven by `/etc/distros` — one section per name, each launching
   `enter <name> { … }` — which is a real change to the panel's Adder, not a
   path edit. **It is inert on this line today**: `etc/rc.d/rc.5.linux` never
   binds `/n/linux`, so the section is empty whichever distribution is
   installed. Nothing regressed; nothing was gained either.
2. **`user/install.ad`.** The installed-disk story is one named root called
   `distro` written into a `.hamnix-roots` sentinel (`sysroot .` / `distro
   distro`). A second distribution on an installed disk would need a second
   subtree and a second sentinel line. Untested here — this work was verified
   on the live/initramfs boot, not on an installed disk.
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
