# hamnix-linux changelog

Releases of the `linux` channel at <https://255.one/>. Install or update with:

    hpm refresh https://255.one/
    hpm install hamnix-base

Every entry here names what CHANGED for someone using the machine. Work that
was measured and deliberately NOT done is listed too, under "measured and
refused" — a thing this project treats as a result rather than an omission,
because the number is the deliverable.

---

## Unreleased

### A shell that ran too long killed itself, and it looked exactly like the machine freezing

Leave the desktop working for about five minutes and everything stops. The
pointer does not move, no window redraws, and the machine ignores you — but the
keyboard's emergency keys still answer, which is the signature of a kernel that
is alive underneath a userland that is not.

It was the shell running out of memory for values. Every step a script takes
allocates a few cells to hold its intermediate results, and the only thing that
ever handed them back ran **between** commands you type — never inside a running
script. The system's own startup script is one endless loop, so it never reached
that point. After about two thousand turns of the loop the cells ran out, the
script stopped with an error, and what was left behind was **a shell sitting at a
prompt waiting for someone to type**. Nothing was hung. Nothing was crashed. The
desktop simply had nobody left to run it, and the machine looked frozen because
in every way that mattered to you it was.

The machine had been printing the reason on its console the whole time. Three
recorded failures each carried the line `value arena exhausted` one step below
where the tools stopped looking, and the automated check that watched those runs
**reported them as healthy** — it looked for the desktop going quiet for too long
and a run that stops has no "too long", only an ending.

Now the memory is reclaimed while a script is still running. Measured across a
fifteen-minute session: the desktop completed **109 cycles of work where it used
to manage 44**, and the longest the picture stood still went from nearly twelve
minutes to **zero**. An accidentally infinite loop no longer ends your session.

**This is not confirmed to be the freeze seen on real hardware.** It explains
that shape exactly — a dead desktop over a live kernel — and it was reproducible
here three times out of three. It has not been caught in the act on the laptop.

### The install wizard could not see any disk you could install on

The graphical installer's disk page said "No installable target disk detected"
on a machine with two perfectly good empty drives attached. It asked one place
for the list of disks — a directory that the installed system never sets up — so
the answer was always empty, while the ordinary listing of devices showed both
drives under the names it wanted. Its own command-line installer avoids that same
directory deliberately, and records why. **The wizard was gating on something its
own installer refuses to use.** It now finds real disks, names their sizes,
leaves out the drive you booted from, and can be driven from the keyboard.

### Choosing a wallpaper said it worked whether or not it had

The Settings app wrote your chosen colour, told the desktop to use it, printed
"wallpaper applied", and never once looked at whether either step succeeded. The
system underneath had been taught to *refuse* that request, specifically so this
could stop happening — and the refusal arrived and was thrown away unread. Three
places that wrote the picture file reported success without checking the write,
and three more gave up in complete silence, so a click could do nothing at all
with no explanation anywhere. The same unchecked pattern covered **logging out
and shutting down**: if the request to power off was lost, you would have been
told nothing, standing in front of a machine that was still running.

### A module list that outgrew its buffer would have taken sound with it

The list of hardware drivers to load at boot was read in one gulp into a fixed
buffer, and it had grown to within a quarter of filling it — **with the entire
sound stack on the last lines**. One more family of hardware and sound would have
vanished from a freshly written stick with nothing anywhere saying why, days
after a release whose headline was that sound finally had its drivers. The boot
also announced "loaded 63 drivers" — the same sentence whether the list held 63
or 65, so it could never show you a loss. It now reads the list however long it
is, says so loudly if it ever does not fit, and reports **how many it loaded out
of how many were listed**.

### When the system refused something, it explained itself to nobody

Typing `enter debian {sh}` gave "no distribution namespace" and nothing more. In
fact the system had composed a careful explanation naming four separate things
that would fix it — and sent it to the text console, which on a desktop nobody is
looking at. Reasons now reach the window where you typed the command.

### The installer in the channel was not the installer on the stick

`/bin/install` is the program the desktop's install wizard spawns and the one
a person types at the live prompt. The live medium's copy is `hlinstall` —
274,840 bytes, the installer every gate in this tree drives and the one that
partitions an NVMe and writes a bootable machine. **The copy in the package
channel was a different program**: `scripts/hamlinux_packages.py` listed
`install` among the system commands, which builds `user/install.ad` — the
NATIVE line's installer, 338,432 bytes, which installs a base system through
`hpm --target-dev` and a kernel `install_file` verb this kernel does not have.

So a machine that installed `hamnix-install`, or updated it, replaced its
working installer with one from the other product line, **under the same
version number and with nothing saying so**. Verified rather than reasoned
about: the channel's copy is byte-identical to a fresh build of
`user/install.ad`, the channel's `bin/hlinstall` is byte-identical to the
image's, and `hamnix-install-1.0.26.tar.gz` **fetched from 255.one** carries
the same 338,432-byte `bin/install` — this is shipped, not hypothetical.

`bin/install` is now built from `user/hlinstall.ad` and laid down at that
path, which is exactly what the image does, so the two copies are one compile
and cannot drift apart again.

**And now a machine has been booted to watch it run.** The line that used to
stand here said no machine had been. `tests/linux/served_install_binary.sh`
installs a shipping-shape disk, points `hpm update` at a signed channel that
carries the tarball 255.one is serving right now, verifies by digest that the
machine's `/bin/install` really is the served 338,432 bytes, and then runs the
exact argv the desktop wizard spawns. **It fails loudly.** It gets one step in
and stops:

    [install] (1/5) partition /dev/blk//dev/vdc (GPT + ESP + ext4 root)
    [install] FAIL: partitioning returned non-zero

exit status **1**. It does not hang, it never prints `install complete` — the
string `user/haminstallui.ad` reads to paint its success page — and the word
`FAIL` in that line is what the wizard reads to paint its FAILURE page. A
640 MB blank disk attached as the install target came back **byte-identical**
to the pattern the host seeded it with, with no partition table, so it wrote
nothing; and `/etc/passwd`, `/etc/shadow`, `/bin/hamsh` and
`/etc/rc.boot.installed`, digested on the machine immediately before and
immediately after that one command, are unchanged. **No silent success and no
damage** — the defect costs a person an installer that refuses, not a disk.

`/dev/blk` is not readable on the booted machine, measured — which is the
reason: every disk operation in `user/install.ad` goes through it, and
`user/linux-syscalls.c`'s bind table answers `#b` with "the /dev/blk file
server is not written yet".

**20 PASSED / 0 FAILED.** The control (`HAMLINUX_SVI_CONTROL=1`) is
**21 PASSED / 0 FAILED**: it replaces the one command under measurement with
`enter debian { sgdisk … /dev/vdc }` and requires the host to see the target
come back written — it does, with **2 partitions** — which is the only thing
that makes "unchanged, no partition table" in the main run a measurement
rather than a blind spot.

Two of this gate's own instruments were caught by that control rather than by
reasoning, and both had failed toward "looks fine":

* **`sfdisk` is in `/sbin`, not on `$PATH`.** `sfdisk -J target.img` answered
  `command not found`, which the gate read as "no partition table" — the same
  shape already recorded here for `debugfs` and `dumpe2fs`. It is resolved by
  absolute path now, and a host without it goes RED instead of quietly
  agreeing.
* **hamsh parses the whole rc before running any of it**, so one bad token
  anywhere means *nothing* runs — and then the target is untouched and the
  root's files are unchanged for a reason that has nothing to do with any
  installer. `-n 1:2048:+64M` did it (hamsh lexes `:` as its own token) and so
  did interpolating a quoted command into `echo '…'`. Two whole boots measured
  nothing. The gate now fails red on `hamsh: parse error` before it reports
  anything else.

**Still not measured, and named rather than implied:** the wizard itself was
never driven. Its `_enumerate_disks` lists `/dev/blk` too, so whether it can
even reach the spawn on this lane is a separate open question. And
`user/hlinstall.ad` was measured to REFUSE on an installed machine —
`/boot/root.partuuid is missing or is not a UUID`, because that file is written
onto an installer medium — so on this lane *neither* program installs from an
installed root, and only one of them says so for a reason anybody intended.

### A gate that compares the bytes, not the names

Both sides rebuilt from one tree in one run with `HAMLINUX_VERSION=1.0.26`,
this gate is **3 PASSED / 0 FAILED**: the release check agrees (image
`/etc/hamnix-release` 1.0.26, channel tarballs 1.0.26), 238 ELFs are staged,
**229 pairs compared and all 229 byte-identical**. Negative control
(`HAMLINUX_ELFCMP_CORRUPT=3`) re-run on the same pair: **2 PASSED / 3 FAILED**,
naming `/bin/ac`, `/bin/host_ac` and `/bin/ham2048scene` — exactly the three
broken.

`tests/linux/channel_bytes_match_image.sh` (~30 s, no VM) compares
every ELF the image stages against the copy a package carries for the same
path — **229 pairs**. Nothing did this before. The name gate next door saw
`bin/install` on both sides and said "covered"; its header explained that a
per-byte ELF compare "would go red on any legitimate rebuild", which stopped
being true when the Linux lane became reproducible, and that one stale
sentence is what let the defect above ship. Measured on the way in: the same
source built twice into two directories is one sha256, and every file inside
five packages **fetched from 255.one** at 1.0.26 is byte-identical to this
tree's local build of 1.0.26 (0 differing of 92).

**On the tree as it stood the gate was 1 PASS / 1 FAIL**, naming
`/bin/install` with both sizes and both hashes. **Negative control**
(`HAMLINUX_ELFCMP_CORRUPT=3`, one byte flipped in three of the gate's own
extracted copies): **1 PASS / 3 FAIL**, and the three reported are exactly the
three broken, by name — the gate checks its own control.

### "Are the bytes I built the bytes served?" — asked for all 130, and the answer has two halves

With the gzip wrapper fixed, `tests/linux/pkg_tar_reproducible.sh` reaches its
scan and passes it: **all 130** channel tarballs carry gzip MTIME 0 and a clear
FNAME flag, and two builds of one package two seconds apart are byte-identical
`.tar.gz`. Its section C then compares those 130 against what 255.one serves at
the same version and reports **130 of 130 differing** — so the gate is
**5 PASSED / 1 FAILED**, and the failure is real rather than a harness fault.

The interesting part is *why*, and it is not one reason. Every published
tarball was fetched (109 MB), its sha256 checked against the published index,
and its difference from the local build separated into the gzip wrapper and the
tar stream inside it:

* **126 of 130 — the wrapper alone.** The inflated tar streams are
  **byte-identical**; only the `.tar.gz` differs. Measured, not assumed: the
  published side carries a nonzero gzip MTIME on **130 of 130** and the FNAME
  flag on **130 of 130**; the local side carries neither on any of the 130. The
  published 1.0.26 was written by the previous packager — its gzip stamp reads
  **2026-08-17 04:47:07**, which is when it was built.
* **4 of 130 — the content really differs**, one member each, and every one is
  attributable to a commit landed *after* that 04:47 publication:
  `hamnix-install`/`bin/install` 274,840 vs 338,432 (the `SYS_ALIASES` fix,
  50933418 at 06:07); `hpm`/`bin/hpm` (d8ca6018 at 06:35);
  `hamnix-desktop`/`bin/hamsettings` and `hamnix-app-hamctl`/`bin/hamctl` (both
  108dd667 at 05:56).

Nothing is left unexplained: 126 wrapper-only + 4 with named causes = 130. The
honest reading is that **both** explanations are true at once, of disjoint sets
— so a rebuild of this tree cannot be expected to reproduce 1.0.26's bytes, and
the reproducibility claim will only be checkable against a release published
*by the fixed packager*.

Also measured, and worth knowing before it costs somebody an hour: an Adder
ELF's `.strtab` embeds the **output file name**, so building
`user/install.ad` to `install_ad.elf` gives 338,440 bytes and a different
sha256 from building it to `install.elf` (338,432) — every other section is
identical in size and offset. Built to the name the packager uses, it is
byte-for-byte the `bin/install` 255.one serves.

### The install-from-USB loop is green end to end, and the last red is gone

`tests/linux/install_from_usb.sh` is **75 PASSED / 0 FAILED** on a full run —
three boots under OVMF, a live USB stick installed onto a blank NVMe, the
stick pulled out, and the installed machine updated over the network from
255.one. The one assertion that was red at 1.0.26's publication was red
because the machine updates from the LIVE site and the gate compares what it
recorded against the LOCAL candidate, so it could only agree once the
candidate was served. It is served, and the assertion is green: the database
on the installed disk records `hamnix-man` at **1.0.26**, the machine printed
`hpm: upgrading hamnix-man 1.0.22 -> 1.0.26` and `update done (upgraded=5
pinned=0)`, and the file it rewrote is byte-identical to this tree's
`etc/man/cat.1.md`.

## 1.0.26 — 2026-08-17

**PUBLISHED and verified as served**: the live index reports 1.0.26 across all
130 packages, its signature verifies against the trust root installed machines
already carry, and both `hamnix-drivers-sof-1.0.26.tar.gz` and the firmware
package fetched from the site are byte-identical to the gated build. Thirteen
polls between pushing and serving.

**Everything here came from running the desktop on a real laptop.**

**Known issues, shipped knowingly.** This is **not** proof that sound works — no
virtual machine has that hardware and the build machine is a different
generation that never takes that path; what is proven is that the medium carries
what such a laptop asks for. **Firmware, the boot module list and the kernel
command line arrive only on freshly written media** — no update delivers them.
A desktop **froze about five minutes into a session on real hardware and the
cause is still unknown**: two standing write loads were found and removed and
neither was shown to be it. Eleven places in the widget toolkit still size
buttons and labels with the same wrong 8-pixel assumption, left alone
deliberately because nothing measures toolkit layout yet. And a wallpaper image
reports that it was applied while the desktop never loads it.

### Sound never had a chance: no firmware, and a log line that lied

On a laptop whose audio uses Intel's newer sound engine, **nothing played**. The
boot log looked reassuring — it named the sound driver and said it was using that
engine — and it meant the opposite: that message comes from the arbiter the
driver consults, and it means **the driver declined and bound nothing**.

Underneath it, two things were simply absent. None of the twenty-two modules that
engine needs were on the medium. And **the image builder had no way to carry
firmware at all** — it copied kernel modules and nothing else, while the package
side had been shipping firmware for months. So the engine could never load the
blob it starts from.

Both are fixed: 22 modules and 31 firmware files, about 12 MB. **Firmware and the
boot module list can only arrive on freshly written media** — no update can
deliver them.

**This is not proof that sound works.** No virtual machine has that hardware, and
the build machine is a different generation that never takes that path. What is
proven is that the medium now carries what such a laptop asks for.

### The text cursor sat further right the more you typed

In text fields the caret drifted right of the text — 22 pixels after 15
characters, 44 after 30. The glyphs are proportional, about 6.8 pixels wide on
average; the caret was placed at **a flat 8 pixels per character**. The two
disagreed by about 1.2 pixels every character.

The same wrong assumption was in **four** places in the shared widget toolkit —
both places a caret is drawn, and both places a mouse click is turned back into a
character position, which were wrong in the other direction, so clicking put the
cursor on the wrong letter. All four now ask the one component that actually
measures text. A fifth copy in the terminal made text selection come back short
by whole words.

The reason this survived: **the toolkit's rendering had never been tested at
all** — its demo program draws one frame and exits unless asked to stay, so every
attempt to photograph it caught an empty screen.

### The desktop's background stopped 120 rows short of the bottom

On a 1920x1200 screen a black band sat above the bottom panel, always beginning
at exactly row 1080 whatever the screen height. A third copy of an old
1920x1080 limit lived in the component every window is drawn through, and when a
window did not fit it **quietly shrank it and reported success** — so the part of
the system whose job is to notice unpainted rows measured them against the
shortened height and saw nothing wrong.

### The machine wrote to your USB stick 42 times more than it needed to

**Found while hunting a freeze on real hardware, and it does not claim to have
fixed that freeze.** With the desktop up and nobody touching the machine, two
things were writing to the boot medium continuously.

**Ours:** the boot log rewrote itself completely every two seconds — header,
whole buffer, terminator, in seven synchronous writes — **whether or not a
single byte had changed**. That is 1,143 forced flushes to the stick in six
minutes. It now writes only the part that actually differs, so an idle machine
performs no transaction with the stick at all, and it slows itself down on a
slow medium and says so in its own log.

**The kernel's, and it was larger:** a freshly made filesystem leaves most of
its inode tables uninitialised, and the kernel quietly zeroes them — 42.7 MB of
them — in the background of the **first** read-write mount. Measured at about
110 KB/s, that is roughly **seven minutes of continuous writing beginning at the
first boot of every stick**, which is the only boot most sticks get. The
filesystem is now built with those tables already initialised, which costs
nothing at build time and removes the work entirely from the machine.

Together, on an idle desktop over three minutes: **22.9 MB written down to
0.5 MB**, and time spent waiting inside write calls down from **25.1 seconds out
of 180 to 0.1**.

**And if it does freeze again, it will say who.** The kernel's hung-task
detector is now switched on, so a process stuck in the kernel for 30 seconds has
its name, process id and stack written into the log on the stick — with nobody
pressing anything.

### The desktop would not start on a 1920x1200 screen

**Found on real hardware, on the first boot that reached a graphical
environment.** The compositor keeps a fixed-size buffer to compose the screen
into, and it was 1920x1080. On a 16:10 panel — ordinary on ThinkPads — it
refused to start at all. Everything downstream then failed in a way that named
the symptom instead of the cause: the desktop reported *"no screen geometry,
/dev/wsys/screen never answered"*, which was true, and useless. The owner only
learned the real reason by running the compositor by hand.

The ceiling is now 2560x1600, which covers 1920x1080, 1920x1200, 2560x1440 and
2560x1600. Not 4K: the buffer's size also caps a per-connection reassembly
buffer that a program can drive, and 4K would take that from 8 MB to 33 MB.
Raising it costs nothing at rest — the pixels live in sparse memory and the
untouched part is never resident.

**And the refusal now explains itself.** It prints both numbers, says outright
that *"screen never answered"* is its own downstream symptom, and leaves the
reason in a file that every program quotes under its own error — so the next
person sees the cause without needing a shell. A compositor that starts
successfully deletes that file, so "it refused" and "it was never started" are
no longer the same message.

### The touchpad's entire surface was the Applications button

**Also found on real hardware.** The TrackPoint worked perfectly; the touchpad
was unusable, its cursor pinned to a tiny area at the top-left that always reset
to the same spot, and touching the bottom-right of the touchscreen reached about
a sixth of the way across.

One cause. Relative pointing devices report *movement*; touchpads and
touchscreens report a *position* in their own coordinate range, which has to be
read from the device and scaled to the screen. Nothing read it. The code carried
a single hardcoded number — the range a QEMU tablet happens to use — so a
touchpad reporting roughly 1300x750 had its whole surface mapped onto **76x27
pixels** in the corner. The Applications button is 56x24 pixels in that corner.
The touchpad was not *near* the button; its entire coordinate space *was* the
button.

Absolute devices are now measured rather than assumed, and a touchpad is no
longer treated as a touchscreen: dragging on the pad moves the cursor from where
it is, while touching the screen jumps to the point touched. The two are told
apart by the property the kernel publishes for exactly that purpose, not by
guessing from the range or the device's name. Multitouch events, which were
discarded entirely, are now handled.

**`hpm update` can finally change what your machine BOOTS with.** Until now it
could not, and nothing said so. An update lands new kernel drivers on your root
filesystem, and `modprobe` uses them from that moment — but the drivers your
machine loads *at boot* come out of the initramfs sealed inside
`/boot/EFI/BOOT/BOOTX64.EFI`, which the installer copied onto your ESP byte for
byte on the day you installed and which nothing in this project has ever
regenerated. So an upgraded `nvme.ko`, `usb-storage`, `psmouse` or `i2c-hid` had
no effect on any boot, on any machine, ever. Those are the disk, the install
stick and the touchpad.

`hpm update` now runs `bootsync` after the transaction, which writes the current
bytes of the boot modules into a reservation inside the boot image and then
moves ONE FOUR-BYTE FIELD to switch to them. **A failure at any point leaves the
machine booting exactly as it was installed** — which is the same outcome as
never having run it, and is the only acceptable failure mode for something with
no shell to fix it from. Measured on an installed disk over eleven UEFI boots:
the running kernel's module goes from the installed-day one to the updated one,
and a machine SIGKILLed 6.0 MB into the write boots normally on the old one and
succeeds on a retry. `tests/linux/bootsync_installed.sh`, **33 PASS / 0 FAIL**.
And the whole loop the way you will actually live it — live USB, install onto a
blank NVMe, pull the stick, boot, `hpm update`, reboot to the desktop —
`tests/linux/install_from_usb.sh`, **75 PASS / 0 FAIL**.

**This needs new media.** The reservation is created by
`scripts/hamlinux_disk.sh`, so a machine installed from a 1.0.25 or earlier
stick has no room to write into and `bootsync` will say so and change nothing.
Machines installed from media built after this land are the ones it helps.

**Measured and refused:** `bootsync` does NOT change the boot module *list*,
only the bytes behind the names already in it. Promoting a driver package's
appended `/etc/modules` lines to boot modules would start loading a GPU driver
before the root switch on a machine that has never done so; that is a decision
for the machine's owner, not a side effect of an update.

## 1.0.25 — 2026-08-15

**PUBLISHED and verified as served**: the live index reports 1.0.25 across all
126 packages, its signature verifies against the trust root installed machines
already carry, and `hpm-1.0.25.tar.gz` fetched from the site is byte-identical
to the gated build. Eleven polls again between pushing and serving.

**IF YOU INSTALLED FROM 1.0.24 MEDIA, THIS NEEDS ONE MANUAL STEP.** The old
package manager truncated long filenames *during your original install*, so 14
of 65 kernel modules are already stubs on your disk. Updating heals the package
manager itself — its own name is short enough to unpack correctly — but it does
**not** repair those modules, and a second update does nothing because the
machine already believes it is current. **The machine never repairs itself.**
After updating, run:

    hpm remove hamnix-drivers-base && hpm install hamnix-drivers-base
    hpm remove hamnix-drivers-hw   && hpm install hamnix-drivers-hw

Measured: that gives 35/35 and 30/30 files byte-identical at their full paths,
with no leftover stubs. Installing from a fresh 1.0.25 medium also works.

**Known issue.** The long-name fix is in one of four places the package manager
reads tar archives. The others are not reachable by anything shipped today —
install hooks only touch short paths — but a file conflict on a very long path
would go unnoticed. Written down rather than left to be found.

### `hpm update` can now upgrade the boot kernel modules

1.0.24 shipped knowing it could not, and that it bit hardest exactly where the
nine new touchpad and HID modules were. It can now, and closing it turned up a
second defect that had been hiding behind the first.

**The one file that blocked it.** A package is recorded as installed only when
the root carries *every* file its tarball holds — because `hpm` upgrades by
unlinking the recorded list, and a list naming a file the machine never had is a
list that can delete the wrong thing. `hamnix-drivers-base` and
`hamnix-drivers-hw` each held one file the image did not stage,
`modules.dep.<group>`, so neither was ever recorded and neither could ever be
upgraded. The image stages it now. **88 of 126 packages recorded before, 90
after** — reproduced in both directions by deleting the two staged tables from a
mirror of the root and re-running the emitter — with both file lists
set-identical to their tarballs and **0 of 838 paths claimed by two packages**.

That file is *not* machine state and is not generated at install time; the
install hook only consumes it. The canonical `modules.dep` **is** machine state
and is still not shipped, so an upgrade still cannot take away the line that
lets `modprobe i915` name a file.

**And it exposed a bug that would have destroyed a driver tree.** A tar header
holds 100 bytes of name; GNU tar puts anything longer in a preceding
`././@LongLink` entry and truncates the header's own field. `hpm` read only that
field, so it **wrote the file to the truncated path and recorded the truncated
path** — measured on an installed machine, upgrading these two packages: *"hpm:
extracted 35 files"*, and **14 of 65 modules missing**, including `virtio-gpu`,
`snd-hda-intel`, `usb-storage`, `nvme-auth` and `i2c-hid-acpi`. It was invisible
because these were the only packages with names that long and they had never been
installable at all. The fix is in `hpm` rather than the packager, so the tarballs
1.0.24 already serves install correctly; over 255 bytes it now **refuses** rather
than truncating, and the packager refuses to build such a name in the first
place.

***Correction, measured after this was written: that understated it.** A machine
installed from 1.0.24 media is not merely "at risk" — **it is already damaged**,
because the truncation happened during its original install, before any update.
`hpm update` heals `hpm` itself but not the modules; the remedy is at the top of
this release's notes.*

**Measured on a booted machine**, `tests/linux/install_from_usb.sh` **65 passed,
0 failed** (negative control **42 / 0**): live USB → install to blank NVMe →
detach → boot → `hpm update` against the real 255.one → reboot. Three files on
the medium were a marker string — one `.ko` from each package and `hw`'s
dependency table — and after the update and a power cycle both modules are ELF
again (`hid-multitouch` byte-identical to the channel's copy), the table is 29
real dependency lines, **all 304 paths recorded before or after the update are
still on the disk**, the machine's own `modules.dep` still names `ext4.ko` and
`nvme.ko`, and the machine reaches `rc.boot: up`. Read both by the host off the
ext4 and by the machine with its own `cat`. With the database withheld, all three
files still hold the marker.

### Known issue, and it is a different one

An upgraded module lands on the root filesystem and is what `modprobe` resolves
from that moment on — but it is **not what the next boot loads**. The PID 1
reads `/etc/modules` before the root switch, out of the initramfs, and the
installer copies the UKI onto the target byte for byte and never regenerates it.
Nothing in the tree regenerates a UKI on an installed machine.

### `hamnix-drivers-hw` is not one module short

`i2c-designware-platform` is `CONFIG_I2C_DESIGNWARE_PLATFORM=y` and listed in
`modules.builtin`: the driver is inside `vmlinuz`, there is no `.ko` to package
and none is needed — which is why the touchpad bound on metal anyway. 29 modules
for 30 names is correct. The packager now says *"BUILT INTO this kernel"* rather
than *"modprobe resolved nothing"*, a sentence that has been false in that file
before and cost twenty files when it was.

## 1.0.24 — 2026-08-15

**PUBLISHED and verified as served**: the live index reports 1.0.24 across all
126 packages, its signature verifies against the trust root installed machines
already carry, and `hamnix-desktop-1.0.24.tar.gz` fetched from the site is
byte-identical to the gated build. The site took eleven polls to pick it up —
pushing and serving are different events.

**Every fix here exists because someone booted this system on a laptop for the
first time and it did not reach a desktop.** All of them are the same shape:
something reporting success while doing nothing.

**Measured against the published 1.0.23 rather than assumed** — all 126 of its
tarballs downloaded, every hash matched, payloads compared: 126 packages before
and after, none added or dropped, **36 byte-identical and 90 changed**, almost
all recompiles because every binary links the file the console fix touched.

**Known issues, shipped knowingly.** `hpm update` **still cannot upgrade the
boot kernel modules**, and that bites harder here than in 1.0.23: the nine new
touchpad and HID modules are exactly what an installed machine would want and
cannot receive — they arrive only with a freshly built medium. The driver
packages are each excluded from the installed database over exactly one
*generated* file the package owns and no image stages. `hamnix-drivers-hw` also
ships one module short of its name, because that module does not exist on the
build host's kernel. And **real hardware has booted this system exactly once and
did not reach a desktop** — the console fix below is what will finally show why.
Every other claim here is a VM claim.

### Two more fixes that landed after this list was first written

**The stick keeps its own boot log.** `\HAMNIX.LOG` on the FAT boot partition,
readable from any computer with nothing installed, preallocated at build time
and only ever overwritten in place with every write synced — so a power cut
cannot lose it by mutating filesystem metadata. It captures the kernel *and* the
shell in one stream. Two defects were found by running it: the kernel's message
ring is rate-limited by default and **drops records with no error**, which
produced a log of the right size, with its header and terminator, missing four
seconds out of its middle; and the program that writes it **shipped in no
package**, so the one program whose bug could not be reported was the one that
could not be fixed remotely.

**Nine touchpad and HID modules**, measured working on a real Lenovo — the
internal keyboard was already built into the kernel, but nothing drove a
built-in pointer, so the desktop would have come up with no way to move the
cursor.

### Booting from a USB stick quietly ran the whole system from RAM

The machine came up with a full desktop, both panels and a working menu — and
**nothing you did was being saved**. It had given up looking for the disk about
a second and a half before the disk appeared, and carried on from memory without
saying so.

USB and SD media do not exist the moment their driver loads: the driver
registers, and the bus reset, the enquiry and the partition scan all happen
afterwards. Measured on a real laptop: the stick was ready **33 seconds** into
the boot. The system now waits up to 20 seconds and says what it is waiting for,
and a disk that is ready immediately still costs nothing at all.

### The installer could not partition a disk when run from a USB stick

It reached for its partitioning tools on a **second drive that only exists
inside a test machine**. On a real stick there is no such drive. The tools now
travel on the medium itself, at a cost of 7 MB rather than the 2 GB the old
arrangement implied.

Two smaller faults alongside it: the graphical installer announced **"Install
FAILED" after a completely successful install**, because it was watching for a
sentence the installer had stopped saying; and there was no way to launch the
installer from the desktop at all, because the marker file every menu checks for
was never written.

### `hpm update` did nothing on a freshly installed machine, and said it worked

Install, reboot, run `hpm update`: it fetched the package index, checked its
signature, reported success, and **upgraded nothing, ever**. The installed
system carried no record of what was on it, so there was nothing to compare the
index against.

An installed disk now carries that record, built from the same package files it
was installed from. And when the record is missing or unreadable, `hpm` now
**refuses and says so** instead of treating the machine as empty — the old
behaviour would happily "update" a full system to nothing.

### Everything the system said after start-up went to a port with nothing plugged into it

On a real laptop the boot got as far as starting the shell and the screen
stopped changing. It was not frozen — it was talking to a serial port. Console
output follows the *last* console named on the kernel command line, and that was
the serial port, chosen so automated tests could read it.

The screen is now the console, which also means **it is the one you can type
into**. Two symptoms of the same cause went with it: the boot was slow because
every message was being pushed through a 115200-baud port, and the screen
corrupted because two consoles were drawing into one framebuffer with separate
cursors.

Also fixed here: an installed machine had **QEMU's own IP addresses baked into
it** — a network that is configured, looks fine, and cannot reach anything. It
asks for an address by DHCP now.

## 1.0.23 — 2026-08-13

**PUBLISHED and verified as served**: the live index at `https://255.one/`
reports 1.0.23 across all 126 packages, its signature verifies against the trust
root installed machines already carry, and `hamnix-desktop-1.0.23.tar.gz`
fetched from the site is byte-identical to the gated build. Gated on freshly
built artifacts — the image root and the channel were rebuilt from this commit
first, because a day-old pair passes the coverage gate while saying nothing
about the tree. `channel_covers_image` 8/0, `channel_runs_desktop` 10/0,
`channel_compiles_adder` 7/0.

**Known issues shipped knowingly** — see the end of this section for the
window-system boundary, which is inert on this line and could not receive its
own switch even if something set it.

Everything below this heading and above `## 1.0.22` is **on** the channel now.
Each item was merged after the 1.0.22 candidate, placed by ancestry rather than
by date, because two of them landed the same hour that release published and on
the other side of the cut.

### `ls` on a plain file printed the file's CONTENTS

`ls notes.txt` printed the text of `notes.txt`. It has done that for the whole
life of this port. It now prints the name, and `ls -l notes.txt` prints one
long-format line — the same line the directory listing would show for that
file, byte for byte.

Both paths reached the file with open-then-read, and on a regular file both of
those succeed, so the bytes that came back *were the file* and nothing
distinguished that from a listing. The library routine underneath carried a
comment promising it returned an error when the path "isn't a directory", and
**it contained no such check** — which is why nobody looked there.

The eleven other programs that share that routine were checked rather than
assumed: `du` and `find` on a plain file were both already correct, because
they ask what the path is before opening it. `ls` was the only one that fell in.

### The Steam consent dialog never actually drew — and cost 197.6 MiB to not draw

Debian's `steam` asks you to agree before it installs Valve's software. On the
image as shipped, **that box never appeared**: the program drawing it died
inside GTK while loading its own icon, `steam` read the missing answer as "no",
printed `Installation cancelled` and stopped. So the prompt was a dead end
rather than a question, which is precisely the outcome it exists to prevent.

It is drawn by a smaller program now and it comes up. The one it replaced
dragged an entire browser engine into the image to render a yes/no box, needed
by nothing else installed: the Debian namespace goes from **2254.7 MiB to
2057.1 MiB occupied — 197.6 MiB** — and from 619 packages to 565. On the host's
disk that is 1.95 GiB down to 1.82 GiB.

**The honest limits.** This was proven by running the real `/usr/games/steam`
in a test harness with a scanned-out framebuffer, and **not** in a booted VM;
that the old one aborts is a harness finding reported as such. The buttons
read OK/Cancel rather than Install/Cancel, because the replacement ignores the
labels it is given — the wording of the question is identical. And the
downloaded image is **not** 197.6 MiB smaller: the file is provisioned at a
fixed 12 GiB and that is a separate lever nothing here moves.

**AND `hpm update` CANNOT DELIVER THIS ONE.** The change is a line in
`scripts/hamlinux_distro.sh`, which builds the Debian medium — it is not a
file in the image root and not a file in any package, so no gate that
compares the two can see it and no installed machine receives it by updating.
It arrives only with a freshly built distribution medium. That is a property
of the thing being fixed rather than a mistake here, and it is written down
because the other entries in this section *are* deliverable and a reader
would reasonably assume this one is too.

### An idle panel cost more CPU than the compositor drawing it

With nothing open and nobody touching the machine, the panel spent **1.7% of a
core** against the compositor's 1.1%, and made **1016 window-system calls a
second** to do about six calls' worth of work — re-reading its config file, the
window list and two notification sinks about 111 times a second, for ever.

It now waits longer between those checks once the desktop has been completely
still for half a second: **0.3% of a core and 176 calls a second**. Anything
with something to wake on — a keystroke, a click, a new window, a notification
— is unaffected, because those arrive on descriptors the loop already sleeps on.

**What it costs, measured rather than waved away:** things the panel can only
*notice by looking* now take about twice as long to appear. A window opening
while the panel is idle reaches the taskbar in **40 ms rather than 19 ms**
(worst seen 69 ms). That is still under the ~100 ms a person reads as
instantaneous, and it is one constant if the trade is judged wrong.

### `ssh` and `sshd` trusted lengths the other end chose, including before login

**They are on a machine now, and until this release neither was.** This entry
used to open "Both are installed by `hpm install hamnix-base`", which was
false: `ssh` and `sshd` were in no package and in no `/bin`, so a fix to a
read a stranger could trigger *before logging in* reached nobody at all.

`ssh` now comes with `hpm install hamnix-base`, in `hamnix-net` beside `curl`
and `ping`. **`sshd` is a separate package you have to ask for** —
`hpm install hamnix-svc-sshd` — and installing it does not start it; that is
`svc start sshd`. A machine does not begin listening on port 22 because
somebody wanted a desktop.

Proven by running the packaged programs against each other rather than by
reading a file list: a whole SSH-2 session, key exchange, host key signature
verified, encryption on, password accepted, a shell opened over the channel
and a clean disconnect — which is also the only way to reach the parsing this
release is about, since it sits behind key exchange.

Five places took a size or an offset straight off the wire and used it without
checking it against the packet that carried it.

**One of them is reachable before authentication.** A peer that had done
nothing but negotiate a connection could send a length near four billion and
make `sshd` read about four gigabytes past the end of an 8 KiB buffer. Two more
would let a hostile *server* make your own `ssh` client read its own memory out
onto your terminal, and one let an authenticated peer push a similar read into
a shell's input.

Every peer-chosen field is now bounded against the actual packet length before
it is used — not against the size of the array it lands in, since reading 8000
bytes out of a 40-byte packet is wrong even when it stays inside the buffer.

**The honest limits.** None of this was found by anything misbehaving; it was
found by looking for the shape, and nothing is known to have exploited it.
`sshd` is not started for you — it ships as a service definition you have to
turn on — so on a default machine the pre-authentication one has nothing
listening to reach. And the first pass fixed one arm of a two-arm defect and
missed the other, which is the reason the second pass exists.

### The web server answered a too-large request by guessing at it

**This one still reaches nobody, and now we know why.** `httpd` is in no
package and in no `/bin`, and unlike `ssh` it was NOT added in this release —
because on this system it cannot answer a request at all. Traced: it takes
the connection, starts the program that is supposed to reply, and that
program exits a fifth of a millisecond later having read nothing and said
nothing. Every request gets silence.

The cause is not in either program. The web server hands the reply-writer a
connection by *number*, and on this system a number is not enough to find the
connection — it was written for a kernel where it is. Shipping the server
anyway would put a web server on every machine that answers nothing, forever,
without ever failing; that is the thing this project refuses to do, and it is
the same reason `initctl` and `telinit` are not shipped either.

So the fix below is real and correct, and it is not the blocker. When the
reply-writer can reach the connection, `httpd` ships and this entry stops
being about a program nobody has.

`httpd` reads a request into an 8 KiB buffer. Headers that did not fit were
parsed **as though they were the whole request**, with the remainder left
unread on the connection — there was no way for it to tell that case apart from
the legitimate "the client sent headers and hung up". It now answers **431
Request Header Fields Too Large**, naming the 8192-byte limit.

The same buffer bounded the body, and a CGI script was handed the
`Content-Length` the *client claimed* rather than the number of bytes it was
actually going to get. The script is now told the real number, and a request
promising more body than fits is refused with **413 Payload Too Large** instead
of being silently short-fed.

### A window whose drawing was exactly 16,384 bytes lost its last instruction

A program hands the compositor a display list, and the largest one it is
allowed to send is 16,384 bytes. At exactly that size — and only exactly that
size — the compositor read 16,383 of them and dropped the final drawing
operation, with no error anywhere: the window simply came up missing whatever
it drew last.

100 bytes worked. 16,383 worked. 16,384, the producer's own maximum, did not.
The receiving buffer is one byte larger now.

### The drivers that read your disk and your keyboard could never be updated

An installed machine gets its SATA, NVMe, USB and keyboard drivers from the
image it was installed from, and **no package carried any of them**, so a fix
to the module that reads your root disk could never reach a machine that had
already been installed. Twenty files: `ahci`, `libahci`, `libata`; `nvme`,
`nvme-core`, `nvme-auth`; `sd_mod`, `scsi_mod`, `scsi_common`; `usb-storage`,
`uas`, `usbcore`, `usb-common`, the two EHCI and two XHCI host-controller
drivers; and `hid`, `hid-generic`, `usbhid`.

Nothing failed while this was true. The build printed one line saying those
modules were "not packaged" and gave a reason — *the image does not stage them
either* — and that reason was **false**: the image stages every one of them.
The build script names them in a shell variable and the shell expands it; the
packager read that line with a text search and got the variable's *name*,
which no module is called. A build that says "not packaged" and explains why
looks exactly like a build that is fine.

They are packaged now, as `hamnix-drivers-hw`, and `hpm install hamnix-base`
pulls it in. They needed a package of their own: all of them together are
13.1 MB unpacked against the 8 MiB `hpm` can unpack in memory, so until this
split existed they could not have been shipped at all.

This is new since 1.0.22 — the hardware driver list was added after that
release went out — so it is a hole this candidate would have shipped rather
than one that has been there.

### The first keys you typed after the desktop came up went nowhere

If you started typing quickly enough — before the desktop had finished looking
at its own window list — **the letters were thrown away.** Not delayed, not
mistyped: read from the keyboard and discarded, because at that instant the
system did not yet believe any window existed to give them to.

The mouse did not have the problem, and that is why it took so long to find. A
mouse position is *remembered* and handed over whenever the window is ready; a
keystroke is passed along the instant it arrives and has nowhere to wait. The
same drain of the same keyboard file lost every key and kept every click.

Fixing that uncovered a second fault underneath it, which is the worse of the
two: when you clicked one window and immediately typed, **the letter could be
delivered to a different window than the one you clicked** — the click and the
keys arrive together, and the click had not yet been acted on. That is typing
into the wrong program, and there was no test in this project that could have
noticed: the existing one uses a single window, where the answer is right by
accident. There is now one with two windows that checks the clicked window got
the letter *and the other got nothing*.

### Opening enough windows let a program read what it had been refused

The window system is being moved behind a server that decides who may see what.
One of its rules is that a program which owns no window is told nothing about
anyone else's windows — it asks, and it gets an empty answer.

That rule could be turned off by **anyone, without any special access, using no
tools**. The server accepts a limited number of connections at once. Once that
number is reached, the next program was quietly handed back the old,
unsupervised path — the one where it reads the window list directly and **the
list answers everybody in full**. Measured: a program owning nothing got zero
bytes normally, and another user's window title once enough connections were
held open.

Reaching that state took no attack and no unusual privilege. It is fixed: a
program that is refused a connection is now refused the answer too, rather than
being handed a way around it.

Two things found alongside it are worth naming, because both would have cost
somebody a wasted day. The message printed in that situation **blamed a version
mismatch that did not exist** — both sides agreed, and the number in the message
was a field nobody had filled in — which would have pointed anyone debugging it
at a system-wide upgrade instead of a one-line limit. And the design note
describing this case said the connection would fail; it does not fail, it
succeeds and is closed afterwards, which is why nobody had noticed the fallback.

None of this affects a normal session — a whole desktop uses five connections
out of sixty-four.

### A window painted in pieces stopped painting at 1 MiB — and painted NOTHING

A program that draws a window by sending it a row at a time, rather than all at
once, was cut off once the picture passed one megabyte. It did not draw a
partial picture. **It drew nothing at all**, because a drawing that is never
finished is never applied — so the window stayed black, and the program was
told its writes had succeeded.

This is the second half of a bug fixed earlier this month, where a two-megabyte
drawing sent in one piece was refused and no window larger than about 512×512
had ever painted. That fix stopped sending whole drawings through the
reassembly buffer; **it never made the buffer bigger**. Anything still sent in
pieces kept hitting the same one-megabyte wall. Measured before the fix on a
1024×768 window sent as 768 rows: 513 of the 768 rows were refused, the first
at row 255 — exactly where the total crossed 1,048,576 bytes — and all three
colour bands read back black, including the band that fitted.

The buffer now grows as needed, up to the largest drawing a window can hold,
and every refusal says so out loud instead of returning a quiet error nobody
prints. A second fault was found in the same place: **one buffer was shared by
every window a program owned**, so two windows drawn at once could splice their
pixels into each other. It is now one per window. A third: an oversized
rectangle's byte count could overflow and wrap past its own bounds check, so
the size is now refused before the pixels are read.

No program shipped on the image hits the size limit today — the one that draws
in pieces caps its rows well under it — so this is a fix to a floor nobody had
stood on yet rather than a defect anyone reported.

### Landed and deliberately NOT listed above

`/dev/wsys` is being turned into a real file server with a boundary a program
cannot talk its way past. Seven stages of it are in the tree, along with a
written plan for the rest and a rehearsal of the version bump that ends it, and
**all of it is inert unless `HAMWSYS_SERVER=1` is set, which nothing sets.**

Two things are worth stating plainly for whoever reads this later, because both
were measured rather than assumed. The boundary is **not** closed yet: of the
nineteen files under `/dev/wsys`, four are routed through the server for writing
and six for reading. What that buys has grown past a window's title: another
program on the machine can no longer **read your windows' geometry, list the
windows that exist, or drain their event queues** — all three were measured
open, and all three now refuse. What it does **not** yet buy is the thing under
all of it: a program can still map the shared segment directly and read
everything, so the boundary binds a program that asks politely and not one that
does not. That is the next step and it is a large one. And the rehearsal of
the bump showed the update **refuses rather than wipes** — the session survives
untouched, byte for byte, and the person is told why — but only if the panel
they are already running is new enough to know how to tell them.

A person using
the machine cannot tell it is there, so it is not a changelog entry yet; it
becomes one when the version bump that removes the old path lands, and that
bump is the last step rather than the first. `HANDOFF.md` §0 and
`docs/wsys_server_design.md` carry where it stands, including what is proven
and what is not.

## 1.0.22 — 2026-08-12

Published to <https://255.one/> and verified as served: the index reports
1.0.22 across all 124 packages, `hamnix-desktop-1.0.22.tar.gz` fetched from
the site hashes to the sha256 the index names, and the index signature
verifies against the same key installed machines already trust.

### Web pages render, instead of a blank grey rectangle

Open a page in the browser and you now see the page. Until now you got a flat
dark grey rectangle where the content should be — the window, the chrome and
the scrollbars all present, and nothing drawn inside.

**This never worked on this port.** It is not something that broke and was put
back: no window using the newer, faster hand-off path had ever put a frame on
this system's screen if it was bigger than about 512x512 pixels.

The reason is a size. A program using that path composes a whole frame and
hands it over in ONE piece — for an 880x600 window that is 2,112,018 bytes —
and the receiving side copied every hand-off into a 1 MiB staging buffer first
and rejected anything that did not fit. So the frame was refused outright,
nothing was ever stored for that window, and the compositor drew its
"this window has not painted yet" colour. Which is exactly what you saw, every
time, for as long as this port has existed.

Measured with the same script against the same tree, with only the fix between
the two runs: **51,542 white pixels where there had been none**, plus the page
text and the browser's own greys.

The desktop's own applications were never affected — they use a different,
older path, which is why everything else has always drawn.

### A window sometimes opened blank when two programs started at once

Start two programs at the same moment — a launcher opening one while another
is still coming up, a session starting several at login — and one of them could
appear as an empty frame. No title, no contents, nothing to click. Closing it
and trying again usually worked, which is the worst kind of fault: it looked
like a fluke rather than a bug.

It was a race, and it has been there for as long as this port has had a window
system. Claiming a window took three separate steps — check a slot is free,
clear it, mark it taken — and two programs arriving together could both pass
the first step before either finished the third. They ended up holding the same
window, and the one that lost found every part of its own window missing: the
system had no record matching what it was holding.

**This is not a regression.** It has been there since this port had a window
system — 1.0.20 has it too — and it is the reason the internal check for this
area failed about one run in four —
which is how it was finally caught, because a test that fails a quarter of the
time trains people to run it again rather than look.

Claiming a window is now a single indivisible step, so two programs arriving at
the same instant get two different windows. Measured: the check that was red
about one run in four is green six times out of six.

### Every desktop application was quietly refusing the fast path

Applications on this system ask the window system for a newer, faster way of
handing over what they have drawn. The request was written to a file the window
system did not implement — and the write **succeeded anyway**, because unknown
names were being routed to a generic buffer that accepts anything and does
nothing.

So every application asked, was told yes, and believed for the rest of its life
that it had the fast path, while its window carried the old one. Nothing looked
wrong from either side: the program had a success, the window system had a
window, and the two disagreed silently. There was no message to notice, because
nothing failed.

The control file is now real, and it is the one the original system defines —
with its own commands and its own permission rule, which is what lets an
application started by the desktop under a different account opt in at all. A
program that asks for the new path now gets it or is told it did not.

**This did not, on its own, make the browser draw** — it was one of two things
that had to be true, and the other is the entry above. Reaching the fast path
was necessary and not sufficient: the frames were then refused for being too
big. Both are fixed in this release.

### Dragging a window no longer costs five times the power it needs to

The compositor now presents at the display's refresh rate instead of as fast as
it can, and it no longer wakes up for applications while a frame it already owes
is still waiting.

The two counts tell the story on their own:

- it drew **908 frames a second** at a screen that can show 60. Now **57**.
- it woke **920 times a second** to decide whether to draw. Now **118**.

That cost **about 36% of a CPU core** while dragging a window, and now costs
**under 4%**.

Measured on a real display in one session with one binary, with the probe proven
against a known 50% load in the same run. **Treat the CPU figures as a floor
rather than a promise:** they were measured with a test window that draws less
than a real one, so a desktop with real content in it will use somewhat more at
both ends. The two counts above are unaffected by that — they count how often
things happened, not what each one cost.

**Capping the frame rate was only half of it, and the half it left behind was
the larger one.** With the cap alone the CPU fell 5.1x while the frame rate fell
15.8x, because the compositor still *woke* about as often — 920 times a second
down to 861 — and simply declined to paint on almost all of them. Being woken,
not painting, was most of what remained.

So it now also stops waking for applications while a frame is already owed.
Wakes fell to **118 a second** and a dragged window costs **3.5% of a core**
instead of 7.0%, with the frame rate unchanged. Input is never deferred by this
— only the repainting is — and the input-to-pixel figure above got slightly
better rather than worse.

**Together: 35.7% of a core down to 3.5%**, for a screen showing the same 60
frames a second it could always show.

### The Applications menu no longer downgrades itself permanently after an update

If you clicked Applications after a window-system update, the menu could not
open — correctly, and it now tells you so. But it also recorded that the menu
program was **broken**, and that record sat on your disk and **survived the
reboot**. From then on the Applications button quietly used an older, plainer
dropdown, forever. The restart that fixed everything else did not fix this one,
and because the older dropdown does open, nothing looked wrong.

The program now knows the difference between "I was refused because the window
system changed underneath me" and "I am broken", because it asks its own
experience instead of reading a note left on disk.

### X programs work again — including the browser

Anything that runs through X — Firefox above all — stopped the instant it
connected. Not slowly, not badly: the moment the X server came up, the bridge
that serves it froze, and so did the program.

It was a deadlock, and it was **not caused by any change here**. A newer
Xwayland simply outgrew an assumption: the setup message it sends at connection
is 8,268 bytes, and the bridge only ever read the first 4,096 and never
collected the rest. Every read after that landed 4,172 bytes into the wrong
place. The version of this that shipped before worked only because the X server
used to be smaller.

The rootless-X checks are back to 37 passing, 0 failing — the same count they
had before this broke.

### The desktop repaints when you move the mouse, not when a clock says so

Moving the pointer, dragging a window and typing now reach the screen in
**about 0.3 ms instead of about 10 ms**. The compositor used to wake on a fixed
16 ms timer no matter what you did; it now wakes because you did something.

You will notice it most while dragging a window, where the desktop went from
about 60 repaints a second to as many as the mouse actually reports.

Idle cost did not change.

### Another program running as you can no longer read your windows' pixels

If you typed a password into a web page, it sat in a store that any other
program running as you could read — and read **by name**, so it could pick your
browser deliberately. Typed into one of this system's own dialogs it was already
private. Nothing about the two windows told you which kind you were looking at.

That is closed. Window pixels now live in per-window memory handed up from the
program that owns them, not in a shared slab.

The attack was written first and **proved it worked** before anything was fixed:
a separate account-mate process recovered a test window's literal text out of the
shared store. After the fix it recovers nothing — while a control proves the
desktop itself still receives those pixels, so the check cannot pass by simply
breaking everything.

**Still open, deliberately:** other programs can still see that a window exists,
its size, position and title (the taskbar needs that), and can still move,
retitle or close windows. What is closed is *reading what is drawn in them*.

### The desktop now SAYS a restart is needed, instead of just not opening

1.0.20 shipped the safe half of this: after a window-system update your desktop
survives whole, and anything you start afterwards declines to open rather than
wiping the screen. But the explanation only reached the console, so on screen it
looked like the click did nothing at all.

Now an amber card appears under the panel: **"The window system was updated.
Restart before opening new apps. Windows already open are safe. Click this
notice to dismiss it."** Clicking it dismisses it.

The notice cannot appear unless a real version refusal happened — the mark that
raises it is written in exactly one place, inside the same function that prints
the refusal, past the same guard. A notice that fired when nothing was refused
would be worse than no notice.

Measured on a real UEFI+ext4 disk, asserted on pixels rather than a log line:
the card's colour fills 82% of its rectangle when raised and 0% before and after
dismissal. The refusal logic itself is unchanged.

**One limit worth stating plainly:** updating *from* the version that shipped
this cannot show the notice, because the panel that survives an update is the
old one. The first update this helps is the one after it.

### The "restart needed" notice no longer outlives the restart

The amber card above tells you the window system was updated and that you
should restart before opening new applications. On most machines it
disappears when you do.

On a machine installed to a real disk it could come back after the reboot — the
note that raises it was being kept on disk rather than in memory, so the reboot
that fixed the problem did not clear the reminder about it. You would restart,
be told again to restart, and have no way to tell that you had already done the
thing being asked.

The note now records which boot it was written on. A note from this boot still
raises the card; a note from a previous boot is ignored, because whatever it was
warning about has already been dealt with by the restart that happened in
between.

**Not a regression:** the notice itself is new in this release, so this was a
fault in a feature that had not reached anyone yet — it is fixed in the same
release that introduces it.

## 1.0.20

### Before you update, if a desktop is running

**After updating, restart your session or reboot before opening new
applications.** Your desktop keeps working — windows, panel, wallpaper, all of
it — but anything you start after the update will refuse to open, with an
explanation that only reaches the console. On screen it looks like the click
did nothing. A reboot finishes the update and everything is normal.

This is the safe end of a trade. The previous time the window system changed
this way, opening an application **wiped the whole desktop** to a blank screen
with nothing left but the power button. Now the new program declines to start,
changes nothing, and says why. Measured on a real installed machine: the
desktop survives with all four windows and a live shell, and after a reboot
the panel and taskbar are back.

### The Applications menu now lists programs that exist

It was listing **eleven entries, nine of which named programs that were not on
the machine.** Clicking those did nothing at all.

Three faults were stacked: the application catalogue was never installed (a
directory was being tested as though it were a file); once installed, it was
not carried by the package repository; and of its 26 entries, only **three**
named a program the system actually shipped. All 23 others existed in the
source and in no released package.

The menu now shows **25 real applications** in seven categories, including
Office and Sound & Video, which the fallback list never had. Every application
now ships **with its own launcher in the same package**, so a menu entry
cannot be published without the program it points at. An entry whose program
is genuinely missing is hidden and named on the console rather than silently
doing nothing, and a launch that fails now says so.

### A file manager was burning a whole CPU core

Opening the file manager from the menu left it spinning at **102.7% of one
core**, which froze the desktop — the screen stopped updating, later clicks
did nothing, the clock stopped. It was polling for keystrokes that were never
coming instead of waiting for them. It now waits: **7.2%**, idle.

### Under the hood

- What a window is drawing is now private to that window. A program running as
  you could previously read another window's screen contents out of shared
  memory; that display list now lives in memory only its owner and the
  compositor can reach.
- Three checks that were passing while measuring the wrong thing — including
  one whose comparison was decided by a shell error on every clean run — now
  measure what they claim.

## 1.0.19

### Three things you can see

All three were reported by the machine's owner looking at a screenshot, and all
three turned out to have a real defect underneath rather than a rough edge.

- **Window titles no longer sit in a black box.** The text is composited onto
  the title bar properly, and its anti-aliased edges finally blend against the
  bar instead of against nothing. The cause was one line in the glyph
  rasteriser: it marked *every cell of a letter's bounding box* as fully
  painted, including the empty space between strokes — so each word arrived as
  an opaque black rectangle with correct ink inside it, and every layer of the
  compositor reported success.
- **The Applications menu is the categorised one.** Search box at the top,
  Favourites showing what you launched recently, and a category list with
  fly-out submenus — the shape MATE's Brisk menu has. This menu was **already
  written**; it had simply never been added to the image or the package list,
  so it existed on no machine and the panel quietly fell back to a flat list.
  Favourites also never worked: the menu is a separate program started per
  click, so it recorded your launch and then exited, every time. Both fixed.
  Your history lives in your own home directory.
- **Application icons are distinguishable.** Fifteen desktop icons were
  drawing as nine pictures. Nothing was missing from disk — every icon here is
  drawn in code, and any name the drawing code had not been taught fell back
  to a generic page, which is also what an application that *wants* a generic
  page gets. Twenty new icons, and an unrecognised name is now reported by
  name instead of silently drawing the wrong thing.

### Things that could have destroyed data

- **`svc enable` was truncating service definition files.** It read the file
  into a buffer too small for it and then **wrote that buffer back** — losing
  998 bytes of a real file under measurement, welding two lines together inside a
  comment where nothing would parse them, and exiting 0 without having saved
  the change it destroyed the file for.
- **The boot script was at 97% of the buffer that reads it**, and the overflow
  path was to silently stop reading. A slightly longer boot script would have
  produced a machine that boots with the tail of its configuration never
  having run, and said nothing. Scripts are now read whole, and one that
  cannot be says so and does not run at all.
- **The build could link one source tree's code into another tree's
  binaries**, because its cache was keyed on timestamps. That is the same
  mechanism that shipped a broken desktop in 1.0.10.

## 1.0.18

### Read this before updating, if a desktop is running

**This update costs you the panel once, and a reboot brings it back.** That
sentence is measured on a real installed machine, not assumed.

Updating replaces the window system underneath a session that is already
running. Two things follow, and both are now safe rather than silent:

- **Your desktop survives the update.** Until this release, the first
  application you opened afterwards wiped the screen to a blank slab — your
  windows, the panel, and your own terminal, gone, with the compositor still
  running and repainting nothing. It also still owned the display, so the text
  console was not behind it: on a physical machine the only thing left was the
  power button. Now a program that meets a session belonging to the *previous*
  window system **refuses to attach, changes nothing, and says so**:
  *"REFUSING to attach: it is a LIVE window-system session of version 6 and
  this program is version 7. Attaching would erase every window on that
  desktop, so nothing has been changed. REBOOT and start this program again."*
  The desktop keeps working; only the newly-started program fails.
- **The panel disappears the moment the update finishes**, and this one cannot
  be fixed from inside the update. The cause was a window-system command whose
  argument was never read, so "show this window" was executed as "hide it" —
  and the panel issues exactly that whenever its configuration changes, which
  updating does. It is fixed here, but the fix arrives as a file on disk while
  the *running* panel is still the old program. So the update carrying the
  repair is the last one to suffer it. After a reboot the panel and taskbar
  are back — asserted, not hoped.

A message printed during the update tells you to reboot before opening
anything else.

### Also in this release

- **The trust root can be rotated.** The documented override for the key that
  authenticates every package read the file into a fixed 512-byte buffer,
  while the key file this project ships is 718 bytes with its key at byte 653
  — so the mechanism failed on a well-formed file and the trust root could not
  be replaced at all. It now streams, with no size limit, and a key file it
  cannot use says which file and why, and **refuses to fall back** to the
  built-in key.
- **The desktop's configuration file is read.** `/etc/panel.conf` is 3,120
  bytes and was read into 2,048 — the cut landed inside the comment header, so
  it parsed to nothing and a built-in default was drawn instead. Editing the
  documented file did nothing at all. It now streams line by line, and a file
  that cannot be parsed says so instead of falling back in silence.
- Two build-time defects that could ship wrong binaries with every check
  passing: the packaging cache keyed objects on timestamps, so two source
  trees built in one place could cross-link; and the test that runs the
  packaged desktop could be blinded by its own sandbox and blame the packages.
  Both fixed, both with tests that fail if the fix is removed.

## 1.0.17

### A script that cannot be read is no longer run, and no longer lies about it

A file the shell cannot parse — one stray apostrophe is enough, since there is
no escape inside a quoted string — used to fail almost silently: a single
unnamed line, no file, no line number, and no statement that the script had
not run. Now it names the file and **the line the quote opened on** (not the
end of the file, where the failure is merely detected), says plainly that the
script was not executed at all, and fails.

Two things follow from that, and the second is the one that matters:

- **The package manager no longer reports a package installed when its install
  script did nothing.** It names the package and the script, says the files
  were unpacked but the script did not succeed, and the package's name never
  reaches the installed list — so the machine will not believe it on the next
  update.
- **Your machine still boots.** This was measured on a real boot before
  anything was changed: a boot script that fails to parse already dropped to a
  usable console shell, and it still does — now with a rescue banner that says
  what happened. An init that exits is a kernel panic, so it does not exit.

The compiler the package manager runs for source packages is also bounded now
(15 minutes against a measured worst case of 9 seconds), so it cannot hang an
update either.

### Under the hood

A survey of what the window system's shared table actually costs found that
**writes to it are overwhelmingly per-frame, not structural** — 15 structural
writes in a whole session against hundreds per second of drawing. That matters
because the reason recorded for not putting access control on that table was
that it would slow the drawing path, and the measurement says it would not.

What does block it is worse than what was on file, and it is written down now
rather than discovered later: the table has to stay readable by everyone,
because the taskbar reads it — so one of your own programs can read another's
keystrokes without writing anything at all. The design that closes it is
recorded in full; it is not built yet, and this release does not claim it is.

## 1.0.16

### Steam scrolls, and so does Firefox

**The scroll wheel now works in a distribution namespace.** Eight notches over
Steam's store page move **97.4%** of it and scroll back to a byte-identical
frame; Firefox moves 18.8% in the same session. Before this, the page changed
**zero pixels of 564,400**, across four full sessions, while a terminal in the
same session scrolled perfectly.

The cause was ours and it was a single event that should never have been sent:
for an input carrying nothing but a wheel delta — the cursor standing still —
the compositor was reporting a pointer *movement* alongside the scroll. The X
server routes movement and scrolling to **two different input devices**, so
every notch made the pointer appear to switch devices twice, and a browser
resets its smooth-scrolling baseline whenever the device changes. Every scroll
was therefore treated as the first scroll, and every first scroll is zero. A
terminal reads the older, coarser scroll path, which is untouched by any of
this — which is exactly why a terminal scrolled while the browser did not, in
the same session, on the same events.

The test written to catch this had been green throughout, because it never
subscribed to the device-changed notification and so accumulated straight
across the reset that was breaking the real browser. It now does what a
browser does.

### Updates cannot be wedged by a package's install script

A hook that fails to parse used to take the machine's update with it: nothing
in the hook ran, the safety net at the end of the file was swallowed too, and
the package manager waited forever on a shell sitting at a prompt nobody was
typing at. Hooks now run with **no input** and a **60-second limit**, so a
hook that hangs for any reason fails by name with its package named. The limit
comes from timing the slowest hook this distribution actually ships — about
500× headroom.

**This cannot rescue a machine already running an older package manager**: it
protects against the *next* bad hook, not the one that arrives before this
update does.

A hook of 16 KiB or more is now refused at publish time. Beyond that size it
is silently truncated, and a cut landing inside a quoted string manufactures
exactly the parse failure described above — out of a hook that was correct in
the file.

### Known, and stated rather than left to be discovered

A hook that fails to parse still reports the package as installed. The machine
no longer hangs, but it is told a half-done install succeeded. Fixing that
means deciding what happens when the *boot* script fails to parse, which is
the same code path — being worked on separately rather than guessed at.

## 1.0.15

**If you are on 1.0.13 or 1.0.14, this is the release that lets your machine
take an update at all.** Both of the following were live.

- **`hpm update` hung forever.** A package's install hook contained the words
  *"in front of the machine's table"*, and the apostrophe closed a quoted
  string. The shell reported an unterminated quote, and the runaway token
  swallowed the rest of the file — **including the `exit` the package manager
  appends to every hook as its safety net**. The shell then reached an
  interactive prompt on input nobody was feeding, and the update never
  returned. The modules extracted; the dependency table was never merged; the
  machine sat wedged mid-update. Caused by an `echo`.
- **Installing from the repository disconnected you from it.** The package
  manager's own package shipped the subscription list belonging to the *other*
  line of this system — one channel name, wrong for this kernel. Since the
  flagship package depends on it, installing rewrote the machine's
  subscription, and every later refresh failed on a missing index.

Two refusals so neither can return: publishing rejects any hook line with an
odd number of single quotes — a build error nobody sees beats an update that
hangs on every machine that takes it — and the coverage check now compares the
**bytes** of every `/etc` file the image and a package share, not merely that
the path is carried. That second check named the subscription file by itself.

**Proven afterwards on a real installed disk, against this channel:** a machine
that *updates* can load a kernel module with real dependencies — verified from
the kernel's own module list, with the dependency edge visible in it, and the
module's bytes matching the published ones. The lines a driver package had
appended to that machine's table **survived** the update; the shipped lines win
by order, not by overwriting. And a plain refresh works after installing the
package manager itself, which no machine had ever been able to demonstrate.

## 1.0.14

**`ac` could not compile anything on a machine built from this channel, and
the reason it couldn't was a mistake in the rule meant to prevent exactly
that.** `/bin/ac` is a driver: it hands the work to `/bin/host_ac`. The
package carried `ac` and **nothing else** — a driver with no compiler — so
`ac hello.ad` on an updated machine failed with `cannot run /bin/host_ac`.
This project's own notes list "compiles Adder on the box" as a measured
capability; it was true of a machine installed from the image, and false of
every machine built from the package repository.

`host_ac` had been excluded from the channel on the written grounds that it
was "built for the build host's libc, while the shippable compiler is `ac`".
Both halves were backwards, and it is checkable in one command: `host_ac` has
no interpreter and no library dependencies at all — the one binary here that
needs no libc — while `ac`, the one that did ship, depends on four libraries.
The exclusion is deleted rather than reworded.

The package grows from 80 KB to 585 KB, which is 14% of the package manager's
archive limit and 27% of its in-memory unpack limit — measured, because `hpm`
unpacks in RAM.

A new check runs before any index is written: it unpacks the toolchain **out
of the built archive**, stages a root containing those files and nothing else,
compiles a program with it, and **runs the result**, comparing what it prints.
Exiting 0 with no binary, and producing a binary that does not run, are both
failures.

## 1.0.13

**152 files could never have been updated on your machine, and nobody could
see it.** The gate that enforces "everything we build here reaches the package
repository" compared the image's `/bin` and nothing else. Every other directory
was invisible to it, and it passed cleanly the whole time.

What was in the image and in no package: **34 kernel modules** — `ext4`,
`vfat`, `virtio_blk`, `virtio_net`, `evdev`, `overlay`, `squashfs`, `loop`,
the NLS tables and the entire `snd-hda` sound stack; the **`modules.dep`
table** `modprobe` had just been made to depend on; the **23 Adder runtime
sources** `ac` links against; **21 manual pages**; `/etc/skel`, `/etc/profile`
and nine other static `/etc` files; the test sound; and **`/init`, the program
the kernel executes**. Installing from the image always worked, because the
installer copies the live root — so this only ever hurt the machines that
updated, which is the entire point of the rule.

Two new packages carry the modules and the manual pages, and the module list
is parsed out of the image build so the two cannot drift apart. The gate now
walks **every regular file** in the image root; an omission has to be listed by
name with a reason, and a listed exclusion that is no longer in the image is
reported too, so the list cannot quietly rot. Two exclusions claim "this ships
another way" — the gate now **reads the archives to check that claim** rather
than believing it.

- **`tail FILE` never opened the file.** It checked whether its first argument
  began with `-` and then read **standard input** regardless. At a console,
  where stdin is a terminal that never reaches end-of-file, `tail somefile`
  waited on the keyboard forever and took the shell with it. The quieter half
  is the worse one: in a script, where stdin is already at end-of-file, the
  same bug printed **nothing and exited 0** — so anything that probed a file
  with `tail` concluded it was empty. `head` had been given its file operand
  months ago and its own comments describe this exact bug; `tail` was never
  given the same treatment, and it now runs as the control proving the
  difference.
  A second wrong answer was underneath it: the old code read the **first**
  8 KiB and tailed that, so on any file over 8 KiB it returned promptly with
  the wrong lines and said nothing. It now keeps a trailing window and seeks
  to it, so a gigabyte log costs one seek. A line too large to fit is dropped
  with a reason on stderr and a non-zero exit, rather than printed as though
  it were whole.

## 1.0.12

**The first release the build refuses to publish unless the packaged binaries
run.** `tests/linux/channel_runs_desktop.sh` takes the built archives apart and
runs what is inside them — the desktop under a synthetic mouse, the shell, the
package manager, the coreutils checked on real answers rather than exit 0. It
compiles nothing it asserts on, and proves that by inspecting itself. The
packaging script will not write an index if it fails, so a channel whose
binaries do not work installs nowhere.

This exists because of 1.0.10 below, where every other check passed: the names
were all present, the hashes all matched the bytes served, the dependency
closure resolved. Nothing ran the binaries, because every test in this tree
builds from source — so the thing that shipped was the one thing nothing had
executed. 1.0.11 was checked this way by hand; from 1.0.12 the build enforces
it.

### Things that did not work at all, and now do

- **`modprobe` can resolve a module name.** No `modules.dep` was generated
  anywhere on this distribution, and `modprobe`'s default path pointed at
  `/lib/modules/modules.dep` — no kernel release in it, a path nothing has
  ever written, so the default could only ever fail. On a stock kernel every
  graphics, filesystem and network driver is a module, so on real hardware
  this was the difference between a working machine and a black screen.
  The table is now generated at image build time by running `depmod` over the
  staged tree — it reads the modules' own symbol tables, so it describes the
  modules this image *has* rather than the thousands the build host has. A
  driver package that arrives later by `hpm install` appends its own lines
  from its install hook, so a module installed after the image was built is
  resolvable too. Proved on a module with real dependencies, loaded leaf-first
  and verified out of the kernel's own list — not on a leaf, which would pass
  without a dependency table at all.
- **`passwd` could not change a password. For anyone. Ever.** The authentication
  device served no "set password" operation at all. It does now: `$6$` hashing
  with a 16-character random salt, written through a temporary file with the
  right mode, synced, and renamed into place, and permitted only for the host
  owner or for your own account. The result of a password change is kept
  separate from the result of an identity check, so one can never be mistaken
  for the other.
- **`lsmod` was a lie.** It printed one hard-coded fake row on every machine
  and exited 0. It is the tool you would use to check whether a `modprobe`
  worked, so it would have certified a `modprobe` that loaded nothing. It now
  reads the kernel's own list.
- **`pgrep` matched nothing, ever.** It opened a process-table file that
  exists on Hamnix's own kernel and not on Linux, so it failed for every
  pattern. Its output is now byte-identical to the standard `pgrep`.

### The shell silently wrote to the wrong file

- **A redirect whose target contained `+` was truncated at the `+`.**
  `echo X >> /path/a+b/f.txt` wrote to `/path/a`, left the named file
  untouched, passed the rest as an argument, and exited 0. The tokeniser
  splits a bare word at `+`; the argument path had rejoined those pieces for a
  long time and the four redirect-target sites had not. **Every Debian kernel
  release has a `+` in its name**, so this was every append into
  `/lib/modules/<release>/`.

### Measured, and not what anyone expected

- **50 of the run sweep's failures were one broken harness, not fifty broken
  programs.** The sweep's file-size limit was smaller than the window system's
  backbuffer pool, which is allocated lazily — so the compositor passed the
  readiness check and was killed by the kernel moments later, and every
  windowed program was scored against a window system that was no longer
  running. The score was **253/329**, not the 301 the docs claimed; it is now
  **306/329**. The limit is now derived from the source rather than written
  down, and the harness reports its OWN failure instead of blaming the
  program. 23 remain, each named with its reason, and nothing was
  reclassified to look healthier.
- **The 23 programs recorded as each burning a whole CPU core are fixed** —
  all 50 painting clients now measure 0.0 s of CPU across a 15-second run.
  This is the first sweep since the fix that could see it.

## 1.0.11

**Recovers a machine that took 1.0.10.** If you installed or updated to
1.0.10, `hpm update` brings the desktop back.

**Measured this release, and worth knowing before you judge what runs here:**
Steam, in a Debian namespace, is driven far past its login window. Typing puts
text in its username field and masks a password; hovering repaints the field;
"Create a Free Account" opens a second window carrying a live captcha; the
Browse menu drops down with store artwork; the real store front page loads;
dragging the scrollbar scrolls it; and a search for a game returns titles with
prices and cover art. Every one of those events entered through the same path
a person's mouse and keyboard use — no test wrote a window-system ring by
hand. What does NOT work is the scroll wheel (above). No Steam account was
used, so the library, downloads and launching a game remain unmeasured and are
not claimed.

1.0.10's bytes were deliberately left as published rather than corrected under
the same version number: a machine that already believes it has 1.0.10 would
never fetch a silently fixed one, so the fix has to arrive as a new version.

- **Clicking away dismisses an open menu.** The compositor emitted no focus
  lines at all, so no window was ever told it lost focus and the Applications
  menu closed only by clicking its button a second time. `f in`/`f out` now go
  out on the window's own event ring, in the reference implementation's order:
  the loser is told before the winner, and both before the pointer line for
  the very click that moved focus — so a client never sees the press before
  the message explaining it.
- **The clipboard stopped polling.** There was no way to ask "has the
  clipboard changed?", so both bridges re-read the entire clipboard four times
  a second forever and compared bytes. There is now a serial per buffer, and
  the file that reports it is a real kernel watch, so a bridge sleeps until
  something actually happens: **4.99 → 0.49 wakes/s** measured on the X
  bridge, by sampling voluntary context switches over a stated 10-second
  interval.
  The Wayland half was **measured and refused**: that compositor's loop runs
  at 16 ms for input regardless, so the serial saves it exactly zero wakes —
  0.04% of one core at the worst constructible clipboard size — while making a
  non-bumping writer take 2 s instead of 128 ms to be noticed. It still polls
  by content, with the table of numbers next to the code.
- **The scroll wheel exists.** `wsysd` had plumbed the whole wheel — the evdev
  event, the delta, the fifth field of the routed pointer line — and the
  Wayland server's pointer parser read four fields and stopped at the fifth.
  So every Wayland and X client behind this compositor has had a **dead scroll
  wheel for the entire life of the port**, Firefox included. `wl_pointer.axis`
  is now sent, and `axis_discrete` precedes it as the protocol requires.
  **The wheel now moves a real program's pixels in a real VM**, on the Xwayland
  this distribution actually ships: `tests/linux/vm_wheel_client.sh` scrolls an
  `xterm` in the Debian namespace 415 px up, 415 px back, net 0.
  **What it does NOT fix, stated rather than glossed:** Steam inside a
  distribution namespace still does not scroll, now across four full boots.
  That is no longer a mystery about this stack — in the fourth boot an `xterm`
  in the **same X session, the same minute**, given the identical wheel events,
  scrolled and scrolled back while Steam's store page changed **0 of 564400
  pixels**, with a scrollbar drag of that same page moving 84.43% of it as the
  control. The two candidates this entry used to name are both dead by
  measurement: the compositor's counter advances by exactly twenty for twenty
  notches with the cursor still, and Xwayland 22.1.9 and 24.1.6 behave
  identically on both the core and the XInput2 smooth-scroll paths. The fault
  is above the X server and it is Steam's own input handling.

## 1.0.10

> **BROKEN — do not install this version.** `hamnix-desktop` 1.0.10 shipped a
> mixed build: a compositor compiled at 19:17 beside desktop and panel clients
> compiled at 18:25, with the window-system backend all three link modified at
> 19:54. A machine that installs or updates to it comes up with a desktop that
> maps **no windows at all**. Update to 1.0.11, which recovers it.
>
> The cause was an object cache that compared each artefact only against its
> own `.ad` source, so an edit to a shared library or backend invalidated
> nothing. Fixed, and the gate described under Unreleased now runs the
> packaged binaries before any index is written.

The first release whose index is checked for dependency closure before it is
written (see "the channel refuses itself" below), and the first with a signed
trust root that has a matching secret key in existence.

### Desktop

- **THE DESKTOP CAN BE CLICKED WITH A MOUSE.** It could not, at all, before
  this release. The compositor delivered pointer events to one ring and the
  panel and desktop read a different ring that nothing ever filled, so a real
  click on the Applications menu or a desktop icon did nothing whatever. It
  survived unnoticed because every test in the tree wrote that ring by hand as
  the host owner — the gate that proves it now drives synthetic evdev instead,
  and asserts about itself that it never pokes a ring.
  A second defect was found in the same place: the compositor drained every
  pending input record before routing once per frame, so a move/press/release
  arriving together collapsed into a lone release and the PRESS was never
  delivered at all.
- **Windows have their names on their title bars.** Titles were stored and
  never painted, so several open windows were indistinguishable. Long titles
  are ellipsised, under two independent bounds: the measurement decides where
  text is cut, and the surface rasterized into decides where ink can reach.
  A client can set any title it likes and cannot escape its band or inject a
  drawing command — but it CAN lie about which window is which, which needs a
  per-uid window table to fix and is recorded rather than glossed.
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

- **The connection ceiling is 16, up from 8, and the window table is 256.**
  Firefox alone opened 8 connections, so a browser exhausted the compositor by
  itself and a namespace's Xwayland arriving next lost a whole program, not a
  window. Firefox's 8 was confirmed to be its true appetite rather than a
  truncation: rebuilt with room for 32, it still opens exactly 8, with one tab
  and with ten. The cost is honest and worth knowing — the window segment is
  resident, not sparse, so it grew from 9.15 MiB to **18.17 MiB always
  resident**. Two browsers still do not fit (18 > 16); that is the next
  ceiling and it is named rather than hidden.
  Three latent defects turned up while raising it, all the same shape — a
  ceiling written down twice: a fixed 16-entry wait array with no bound check
  that the new limit would have overrun on every pass of the event loop; a
  listen backlog left as a literal 8; and a refusal message staged into a
  buffer that held another client's pending file descriptor, which would have
  handed a real client's keymap to the program being turned away.
- **Being turned away says so.** A refused connection used to close the socket,
  and the program printed `No wl_shm global` — blaming a feature that is
  present. It now gets a named protocol error built from the actual limit.
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

- **Clicking away does not dismiss an open menu.** The compositor emits no
  focus lines at all, so a window is never told it lost focus; the
  Applications menu closes only if you click its button a second time.
- **Two browsers at once still do not fit** in the 16-connection ceiling.
- **The GPU stack has never been measured on real silicon.** The Vulkan
  userspace is real and `vkprobe` will report what an installed ICD
  enumerates, but on this build host every run has been software. Install a
  driver package and run `vkprobe`: it prints the device name or nothing, and
  there is no third answer that could be mistaken for success.
