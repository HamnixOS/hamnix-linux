# Steam-class applications in the Debian namespace

**What was asked:** *"I want even large apps to be able to run from the debian
NS, like steam."* Steam is the right target because it exercises everything at
once — 32-bit multiarch, a container runtime, a GPU stack, audio, and an X11
window path — and because each of those fails differently.

**Where it stands, in one line:** the Steam client **runs** in the namespace.
It downloads and installs itself, its pressure-vessel container comes up, and
Chromium loads the Steam UI and reaches the pre-login state. It does not yet
put a visible window on the screen. Everything below is measured in the VM.

---

## 1. What a run looks like today

```
enter debian { steam }
```

from the **console** (uid 0) gets you: the launcher, a ~2.5 GB client
download, the sniper container, `steamwebhelper`, and a Steam UI that logs
`SteamApp Init - Before Login` — and no window you can see.

From a **desktop terminal**, which is uid 1001, it used to get you something
worse: the body ran in the native root and reported success. It now gets you
the same namespace the console does, container and all. See §7.

---

## 2. The scoreboard

`tests/linux/steam_probe.sh`, run inside the namespace by
`tests/linux/steam_probe_run.sh`. **23 PASS, 1 FAIL** as of this writing --
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
| Steam UI window | **not yet** | CEF loads `steamloopback.host/library.js`, creates its browser, and no window is scanned out — §6 |
| audio | **absent** | no `/dev/snd`, no sound device in the VM at all — §8 |

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

`xwininfo` inside the namespace shows only helper windows
(`steamwebhelper` 200x200 and 10x10, `Steam` 64x24) — the login window is
never mapped at a visible size. Two leads, neither confirmed: CEF's GPU process
exits during initialisation (`viz_main_impl.cc(166)`), and the browser is
created at `(-2147483648, -2147483648)`, which `matchbox-window-manager` does
not move. **This is where the work stops today.**

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
