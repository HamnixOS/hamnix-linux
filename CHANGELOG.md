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

Landed in the tree, NOT yet on an installed machine. This section exists
because of the invariant above: work that has landed but not shipped is
exactly the state in which "we fixed that" and "you have that fix" quietly
stop meaning the same thing, so the gap is written down rather than carried
in someone's head.

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
