# HANDOFF — porting the Hamnix userland to the Linux kernel

You are starting with no context. Read `NORTH_STAR.md` for what this is FOR,
then this file for where it stands, then `README.md`.

---

## 0. Where this stands

> This section is the current state. Sections 1–8 below are the ORIGINAL
> handoff, written from static analysis before any of it was run; several of
> their claims have since been measured, corrected or answered outright, and
> where that has happened it is marked in place. Read this first and treat the
> rest as history plus reference.

**hamnix-linux boots to a desktop, installs itself, updates from 255.one, and
compiles Adder on the box.** Concretely, all of the following are measured
rather than argued:

| | |
|--|--|
| Boot | Linux kernel → `user/linuxinit.ad` (the Adder PID 1) → namespace via `sys_bind` → `hamsh` → the rc scripts |
| Installed boot | UEFI → a unified kernel image on an ESP → PID 1 → `bind '#sysroot' /` → the real ext4 root. Files written on one boot are there on the next. |
| Display | `/dev/fb` on fbdev AND on raw DRM/KMS, double-buffered with `MODE_PAGE_FLIP` — 481 flips, `stalled=0`. `flip` is a `/dev/fbctl` verb; double buffering arms lazily, so a program that never flips runs the old path untouched. |
| Windows | `/dev/wsys`, the port of `devwsys.ad`, in shared memory. Both protocols: the v1 scene display list and the v2 blit surface, plus the `'I'` named-image tier (a scene client can draw a real photograph without converting its window to a blit surface). The screen size is published at `/dev/wsys/screen`. |
| Compositor | `user/wsysd.ad`. A 1724-op frame at 1280x800 costs **625 us**, down from 5503; a pointer-only frame costs **5 us**, down from 6543. Pixel-identical to the pre-optimisation code at three geometries. **AND THE DESKTOP NOW HAS A FRAME RATE AND A LATENCY, MEASURED RATHER THAN DIVIDED OUT OF THOSE** (`tests/linux/de_fps_latency.sh`, offscreen at 1280x800 on the SOFTWARE path -- the only one any shipped image has ever run): **61 fps** with the pointer moving at 250 ev/s (the cursor-only path, wsysd at 1.7% cpu), **52 fps** with a decorated 480x320 text window dragging across a 4-window desktop (every frame a full repaint, 15% cpu), **0 frames idle** from the compositor and the wallpaper, and **3.1 frames/s idle** from the panel -- which is exactly `hampanelscene`'s `SAMPLE_TICKS(20) * 16 ms = 320 ms` sysmon resample and nothing else, at 1.2% cpu. Input-to-pixel **p50 8.9 ms, p95 16.1 ms, max 18.7 ms** over 150 trials. **THE CEILING WAS THE LOOP, NOT THE RASTERIZER, AND THE LOOP IS FIXED.** `main` used to end in `sys_waitfds(&waitset[0], 0, 16)` with nfds LITERALLY 0 -- `waitset` declared and never filled -- so the compositor was a fixed 16 ms tick that no input could wake early, which capped the rate at 1000/(16 + frame_ms) ~= 60 and made the latency ~uniform 0..16 ms plus the frame. `waitset` is now FILLED with the input fds and the 16 ms timeout is the fallback. **THREE independent before/after pairs, each run back to back on the same host minutes apart** (the host's other load moved between them, which is exactly why they are reported as a range and not as one number): input-to-pixel **p50 8.68-9.64 -> 0.33-1.07 ms**, p95 **16.04-21.23 -> 0.54-7.31**, max **18.38-32.29 -> 2.67-12.22**; pointer fps **60.8-61.1 -> 240.5-250.0** (that is the 250 ev/s injection rate, not a ceiling -- at 1000 ev/s it presents 998.8 frames a second for 6.6% of a core); window-drag fps **unchanged within the noise** (52.0/46.1/39.2 against a baseline 51.9/44.6/50.4 -- with no input there is nothing to wake the loop, so it is the same fallback tick, and the mechanism says so as well as the number: parks/s at idle are 62.1 in both arms). **IDLE DOES NOT REGRESS, measured five interleaved 30 s rounds a side** from /proc/<pid>/stat: bare compositor 0.30/0.27/0.33/0.33/0.30% of one core against 0.30/0.33/0.30/0.33/0.33%, a 0.012 point difference where one clock tick over 30 s IS 0.033 points; the whole desktop 4.83/4.70/4.87% against 4.53/4.30/4.97%. It cost three passes; the first measured WORSE than the tick and the second regressed idle by +0.36 points, and both are written up below. The gate refuses to report anything until its instrument passes a selftest (a deliberately SIGSTOPped compositor must MEASURE as stopped), and it keeps its own first, WRONG answer on the page as a control: a constant 80 ms settle is exactly five ticks, phase-locked the probe, and reported **p50 1.0 ms** -- one lucky phase repeated, 8x too good. |
| Window titles | **Every window on the desktop has its name on its title bar, and until this it had none.** Not "the title was missing" — the device has held one per window since the port began (`user/linux-wsys.c`, the `title` ctl verb, 64 bytes) and publishes the set at `/dev/wsys/windows`, which is where the panel's taskbar has been reading it all along; `wsysd` drew the bar and painted no text on it, so three terminals open were three identical grey bars. **NO NEW FONT.** The title is a one-line `hamscene` display list (`glyphs`, the same builder every DE client uses) rasterized by the same `lib/hamui_host.ad` this compositor already rasterizes every window with — the same DejaVu Sans at the same 14px through the same anti-aliased TrueType path — onto a title-bar-sized surface presented **blended**, so the bar colour shows between the letters instead of a black box. **IT SAID THAT BEFORE AND IT WAS FALSE**, and the machine's owner found it in a screenshot: `#f0f0f5` ink at full strength, correct to the byte, sitting in a black box on a `#5577dd` bar, with a 23-PASS gate agreeing. The surface WAS keyed and the clear WAS transparent; `vk2d_raster_cov_mask`'s opaque fast path forced alpha 255 across each glyph's whole BOUNDING BOX, cov==0 cells included -- its comment states the assumption ("same value the composite target holds"), which is true of every target but a keyed one -- so every unpainted cell inside a letter was declared painted, and painted black. A FOURTH silent layer of `e0df2d4a`'s three, one deeper. Fixed with `vk2d_raster_cov_mask_over` (straight-alpha source-over that keeps the destination's alpha byte; over an opaque destination it reduces exactly to the old formula, so nothing that was right moved), `host_keyed` in `lib/hamui_host.ad` set from the clear it just performed, and a mode-2 present -- because `keyed` is the wrong present for anti-aliased text even once the alpha byte is honest: all-or-nothing writes a 1/255-coverage edge pixel as full ink. It is measured with `htb_text_width()`, the one place in the tree that owns that advance sum, and ellipsised to fit. **THE TITLE IS UNTRUSTED AND IS TREATED AS SUCH**: the window table is `/srv/wsys`, mode 0666, and `linux-wsys.c` says in as many words that any uid can retitle any window. A hostile title cannot inject a draw op (`_hs_emit_str` maps `"` and newline to a space, and every byte outside printable ASCII is drawn as `.`), and cannot overrun — the measurement decides where the text is CUT, the surface decides where the ink can REACH, and the two bounds are independent because one of them is arithmetic. What it CAN still do is put 63 bytes of its choosing on another client's bar: it can lie about which window is which, which needs a per-uid mapping or an RPC compositor, exactly as for the scene and the key ring. `tests/linux/wsys_title.sh` (**29 PASS**, offscreen, under a minute): every assertion is a pixel count in a rectangle derived from the window's own geometry, with an **empty-title control on the same window in the same run** — and with the change reverted the gate is **16 PASS, 7 FAIL**. One of its assertions was itself success-shaped on the first revert run and was fixed: two blank bars compared by colour "differ" the moment one is focused and the other is not, so the two-window test compares the INK MASK, not the pixels. `hamui_host_uncovered_rows()` is deliberately NOT the instrument — it unions the fill and blit rects only, glyph ink is stamped through the coverage-mask op, and `tests/linux/wsys_cover.sh` already pins that ("a window with only text in it is reported uncovered"); the clip is proven on framebuffer pixels instead. **AND THE GATE'S OWN HOLE WAS THE DEFECT'S SHAPE**: all 23 assertions were about the INK -- how much of it, how light the lightest pixel is, whether two bars carry different amounts -- and none looked at the pixels the letters do NOT cover. Six more now do, on the focused bar (`#5577dd`) and the unfocused one (`#404040`): nothing in the band is darker than the bar, not one pixel of it is `#000000`, and the bar is positively there across the ink's span. Reverted, the original 23 are unchanged and those say `432 px darker than the bar, 182 pure black, darkest #000000`. |
| Input | every `/dev/input/event*`, decoded in the compositor, routed to the focused window in window-local coordinates — **and the DE chrome actually reacts to a mouse, which for the whole port before this it did not.** This row read exactly as it does now while the Applications button, the desktop icons and every panel control were completely dead to a click: the compositor routed to `<wid>/pointer` and the chrome reads `<wid>/event`, and nothing bridged them. That is the warning this row now carries — "input is routed" was a true sentence about a desktop nobody could use. Proven from the evdev end by `tests/linux/de_mouse_chrome.sh` (13 PASS), which is forbidden to write a ring by hand and asserts that about itself, because writing the ring by hand as host owner is precisely what every earlier gate did and precisely why this went unseen. **Focus lines are still not emitted at all** (no `f in`/`f out`), so clicking away does not dismiss an open menu — see the running list. |
| Desktop | `hamdesktop` + `hampanelscene`, unmodified. Launch a terminal from the menu, type in it, get output. |
| Desktop icons | **Every application on the desktop draws its own picture, and the ones that cannot say which one.** The owner reported it as *"a lot of the icons are missing images"*; nothing was missing from disk, and there is no icon asset on disk to miss. Every icon in this desktop is vector code in `lib/hamscene.ad` — a freedesktop `Icon=` name resolved to a glyph CODE by `hamscene_icon_code()` — and that function answered `HS_ICON_FILE`, the anonymous white page, for every name it had not been taught, which is the SAME answer it gives an app that asked for the generic page. So Spreadsheet, Presentation, Word Processor, Video Player and Audio Player drew five copies of one picture; Log Viewer and System Monitor, Notes and Editor, Software and Install Hamnix each drew one picture between two apps because the two `.desktop` files literally named the same `Icon=`. **It drew successfully, and every gate stayed green** — 15 icons rendering as 9 pictures. **20 new glyphs, no new file:** office, media, log, package, sticky-note, mouse, palette, clock, units, maths, markdown, book and one per game, each composed from the existing `fill`/`line`/`roundrect`/`stroke` verbs, so the channel-coverage invariant is satisfied by construction (`channel_covers_image.sh` **8 PASS**; zero files added to the image). **AND THE SILENT FALLBACK IS GONE**: `hamscene_icon_known()` tells *"this app wanted the page"* apart from *"nobody taught me this name"*, and `hamdesktop` publishes every miss as an `icon-unknown <name>` line in `/tmp/.hamdesktop.src`. `tests/linux/de_icons_distinct.sh` (**15 PASS**, offscreen, no VM, ~40 s) composes the real desktop against a `~/Desktop` it owns (a bind-mounted `/etc/passwd` in its private namespace — left alone, `_desk_dir()` found `/home/david/Desktop` and measured the person's own screenshots, which is what its first run reported), reads hamdesktop's own icon table for the cells, and fingerprints every 44×38 icon box **with the wallpaper subtracted**. That subtraction is the gate: the first version compared raw rectangles and scored **15 PASS on the unfixed tree**, because the backdrop is a gradient and two byte-identical page glyphs on different scanlines differ in 34% of their pixels. With the change reverted it is **7 PASS / 8 FAIL** — *"15 icons render as only 9 distinct pictures"*, naming the groups. **A pre-existing truncation fell out of it:** the scene-budget stress set gave all 32 cells the CHEAPEST glyph, so `test_de_desktop_label_budget_host.sh` was measuring the labels honestly and the drawing not at all; it asked for 64 glyph runs when a complete render is 128, got **105**, and called it *all label glyph runs emitted* — six labels were being dropped off the tail of the shared 16 KiB display list, in the exact regression that file exists to catch, with the file green. The stress set now cycles every `HS_ICON_*`, `WP_ICON_RESERVE` is 12288, and the whole 128 fits at 15387 bytes. |
| Session | `login` → `/dev/auth` (real `/etc/shadow` + `crypt_r`) → `setuid 1001`. The session is unprivileged; the compositor and chrome are not. |
| Access control | devwsys's uid gate is ported: `live` cannot drive system-chrome ctl verbs, and can still map and draw its own window. `tests/linux/wsys_uidgate.sh`. The chrome state lives in a SECOND segment, `/srv/wsys.chrome`, 0644 and host-owner-owned, so for chrome the file mode is the gate and the kernel enforces it against programs that skip the protocol. `tests/linux/wsys_bypass.sh` (**60 ok**). **AND ONE OF THE USER'S OWN PROGRAMS CAN NO LONGER READ ANOTHER'S KEYSTROKES, NOR WHAT IS DRAWN INSIDE A hamUI WINDOW** — neither of which any file mode could ever have fixed. The keystrokes went to a per-window socket and the v1 display list to a per-window memfd handed UP to the compositor, neither of them needing the tier-1 authority both were recorded as blocked on. What is still readable by anything on the machine: every v2 window's PIXELS (so Firefox's screen, not a hamUI app's) and every row's identity. See the running list. |
| Networking | `/net` as a file tree, TCP/UDP/ICMP, TLS, `announce`/`accept` across process boundaries, and DHCP (`user/dhcpc.ad`) |
| Packages | `hpm` installs the whole distribution from `https://255.one/linux/` over TLS, including replacing `/bin/hamsh` while it is PID 1. **The update loop is proven end to end**: install at 1.0.2 from the live repo, a newer build lands, `hpm update`, the upgraded binary still runs. No re-image anywhere in it. |
| Wayland | `user/wsyswl.ad`, a Wayland compositor in Adder. Firefox runs as a native Wayland client with its menus as separate windows; XWayland carries X11 clients. |
| Windows *inside* a namespace | `jwm`, the same one and the same configuration (`etc/jwmrc.linux` → `/etc/jwm/hamnix.jwmrc`) in Debian and Alpine. Reparenting, a real title bar, 66 `_NET_SUPPORTED` atoms, `_NET_WORKAREA` the full screen, no D-Bus and no settings daemon. `xdotool` move and resize both take effect and the client stays `IsViewable`, for `xterm` and for Firefox; **Steam's `Sign in to Steam` is `IsViewable` at 700x440+290+180 and in `_NET_CLIENT_LIST`** where matchbox left it `IsUnMapped`. It costs **0.5 MiB and one new package** in Debian (Firefox had already installed all sixteen of its dependencies) and **+28.5 MiB** in the *graphical* Alpine image, measured by building it both ways; `HAMLINUX_ALPINE_GUI=0` is still 26 MiB. `docs/linux_window_manager.md` has the table for every candidate, including why openbox — the most EWMH-complete of them — costs 57.9 MiB here, and why **rootless Xwayland** is the better long-term answer and its own piece of work. |
| Rootless Xwayland | **An X window is a file now, and the desktop can move one.** `HAMNIX_X11_WM=rootless` is a THIRD session arm; `jwm` is still the default and the rootful path is byte-for-byte unchanged (with `WSYSWL_XWM` unset, `xwayland_shell_v1` is not advertised, no X connection is dialled, and the commit path takes the branch it always took). Under rootful an entire X session is ONE `wl_surface` and therefore ONE wsys window -- `windows_high_water 1` for a whole Steam session -- so the desktop can move that rectangle and nothing inside it, which is the only reason a namespace needs `jwm` at all. `user/wsyswl.ad` now carries `xwayland_shell_v1` AND an X11 window manager inside the compositor: an X wire-protocol client (the shape `user/xsnarfd.ad` proved) holding `SubstructureRedirect` on the root, mapping what it redirects, granting `ConfigureRequest`s, and titling from `WM_NAME`/`_NET_WM_NAME` (the name is set on the wsys window where a window list would read it; at the time of this row it was NOT visible, because `wsysd`'s decoration painted no text on a title bar for ANY window -- checked with a 4x crop of the bar, not assumed. **That is no longer true: see the WINDOW TITLES row below, and X windows got their names on their bars from it for free, as this row predicted.**). **Measured: two `xterm`s on one rootless Xwayland are TWO wsys windows** -- wids 2 and 3, `windows_high_water 2`, `xwl_paired 2`, every drop counter 0 -- and moving one with the compositor's own `geometry` verb leaves the other where it was, in the table AND in the framebuffer (97% / 96% of their rectangles). The control is in the same script: the same two clients rootful are ONE window. `tests/linux/wsyswl_rootless.sh` (**29 PASS**, offscreen, a minute, no VM), `docs/screenshots/linux/rootless-two-x-windows.png`, `docs/linux_window_manager.md` §8b. **AND IT IS PROVEN ON THE ACTUAL DESKTOP, WHICH IT WAS NOT.** The gate composed `wsysd` plus the two clients and nothing else, so the screenshot showed two X windows on a black screen -- no wallpaper, no icons, no panel -- and the machine owner spotted it. That proved the windows EXIST and said nothing about whether they WORK on the desktop, which is not a hypothetical distinction: ea23c834 fixed a bug in which hamdesktop's backdrop painted over EVERY ordinary client window for the whole port with every return code 0. The gate now composes the real DE -- the same `wsysd` + `hamdesktop` + `hampanelscene` composition `tests/linux/wsys_desktop_z.sh` uses -- and asserts an X window from a namespace is first-class ON it: **over the wallpaper** (its rectangle is 0% its own colour on the bare desktop and 96% with the client up), **the wallpaper survives it** (100% of a strip beside the windows unchanged), **under the panel** (driven up to straddle the bar with the compositor's own `geometry` verb: 0% of the bar is the window, 98% of the window clear of it), and **in the taskbar by its X name** (`/dev/wsys/windows` reads `5 alpha` / `6 beta`, the names the X clients set in `WM_NAME`). **NOT a shared-fate claim** -- `conns` is still 1 and the test asserts it. **Two things had to be measured because reading was not enough**: `CompositeRedirectSubwindows(root, Manual)` is the request without which the whole thing is a no-op (Xwayland only makes a surface for a redirected window and redirects nothing itself -- `xwl_managed 2, commits 0` was the reading), and the serial does NOT arrive as the `WL_SURFACE_SERIAL` property the protocol description implies but as a ClientMessage to the root, with and without a `-wm` fd. **STAGE TWO IS DONE and every item on that list is closed -- see the row below and `docs/linux_window_manager.md` §8c.** |
| Rootless, stage two | **All six things §8b named as missing are built and measured, and rootless is a better arm than `jwm` in every respect that was tested. It is still NOT the default, and the reason is named below rather than hedged.** THE PREREQUISITE WAS THE PAINT POOL, and the fix is not a bigger number: `BB_SLOTS` had already been raised once (3 -> 8, after a fourth window went blank with no error), and a number that has been wrong twice for the same reason should not be picked a third time. **`BB_SLOTS == WSYS_MAX_WINDOWS`, asserted at compile time**, so the paint pool can never be the first thing to run out; the ceiling left is the window table, which is a number the device can state. What made a pool that size affordable is the half that explains why it had not been done: a slot cost a screen-sized double buffer WHATEVER the window's size was -- the segment `memset` whole at creation, each slot `memset` whole on fit, and the front page `memcpy`d whole into the back ON EVERY FRAME. The pixels are no longer a struct member (headers are one small mapping; each slot's two pages are mapped ON DEMAND, so a process maps only the slots it touches instead of 2 GiB of address space in every GUI program), and both the clear and the carry-forward touch `w*h*4`. **Measured: TWELVE X clients on one rootless Xwayland are twelve Hamnix windows, all twelve PAINTED in their own colour in the framebuffer**, and the 2025 MiB segment has **1924 KiB allocated** (`tests/linux/wsyswl_ceiling.sh`, 9 PASS, offscreen). The same run before this gave 8 windows and four X clients that vanished. And the ceiling is READABLE: `/dev/wsys/pool` answers `slots 12/128 exhausted 0 last_refused 0 0x0`, so a window that is never painted is diagnosable from a file after the fact instead of from a console someone had to be watching. The chain had one more silent link -- `wsysd`'s OWN window table was 32 while the device's was 32, agreeing BY ACCIDENT, so raising the device made the compositor's array the next place a 33rd window would be listed and never painted; both are 128 and the ceiling test keeps them equal. **A CLOSE BUTTON THAT ASKS.** There was none at all, and the reason is worth keeping: the only thing `wsysd` could have done with the click was `close <wid>`, which destroys the window record and leaves the program running -- an invisible `xterm` holding a shell, a browser you cannot see and cannot quit. A button that does that is worse than no button. The device grew `delete <wid>`, which delivers the request on the window's own `event` ring when its owner set `wmdelete 1` and destroys it as before when it did not; `wsyswl` turns that into `WM_DELETE_WINDOW`, `xdg_toplevel.close`, or `KillClient` for a client that said it cannot be asked -- three separate counters, because "the window would not close" and "the client was killed" are different bugs with one symptom. `tests/linux/wsys_close_button.sh` (10 PASS): the button is painted at exactly the coordinates the hit test uses, a click elsewhere on the bar does not close, and a real evdev click on it makes **the X CLIENT EXIT** -- the process, not the window record -- with the other client untouched. **`ConfigureNotify`**, whose absence was invisible because pointer coordinates are surface-local and Xwayland adds the origin itself: `geometry` written by anyone but the owner now posts the rectangle on the window's `event` ring (the file-server half of `ConfigureNotify`, on a ring a parked client is already asleep on, so it costs a wakeup when a window moves and nothing when none does) and the XWM pushes it to the X window. X and wsys now agree on where a window is, which also means **a menu opened after a move is placed correctly by the client with no help at all**; `xwininfo` reports 280,240 after the compositor moves the window to 280,240. **`WM_TRANSIENT_FOR`** gives a dialog a z band above its parent (before, it stayed on top only by having been created later), and an override-redirect menu is attributed on map to the toplevel it opened over, so a menu ALREADY OPEN when its parent is dragged moves with it. **EWMH**: `_NET_SUPPORTING_WM_CHECK` on a real window that points back at itself and names itself "wsyswl", `_NET_SUPPORTED` with 16 atoms, `_NET_WORKAREA` (the screen minus `wsysd`'s frame, the same arithmetic `xdg_toplevel.configure` uses, or a maximised X client and a maximised Wayland client are different sizes), `_NET_CLIENT_LIST`, `_NET_ACTIVE_WINDOW`, `_NET_WM_STATE`. **Only what is true** -- no `_NET_WM_STATE_FULLSCREEN`, no `_NET_MOVERESIZE_WINDOW`, because a hint claimed and not honoured is worse than one absent. Before this the answer was byte-for-byte a BARE X SCREEN's, so a toolkit correctly concluded there was no window manager; `hamnix_x11session.sh` no longer skips its WM check on this arm. **The visible title was JUDGED and left**: it is one `wsysd` change that gives every window on the desktop a name for free, X included, and doing it inside a rootless pass would put it in the wrong commit under the wrong test. **It has since been done, in that commit and under that test -- the WINDOW TITLES row below.** `tests/linux/wsyswl_rootless.sh` is **37 PASS**. **WHY IT WAS STILL NOT THE DEFAULT, in one number**: `MAXCONN` was 8 and **Firefox ALONE reaches `conns 8`** with its content and GPU processes, measured this pass -- a namespace's Xwayland arriving next is the ninth, and hitting that ceiling does not cost a window, it costs a whole program. It is a counter now (`conn_refused`) instead of a line on stderr, and raising it means either halving the per-connection window budget this pass doubled or taking the device's table to 256. **THAT PREREQUISITE IS NOW DONE** -- the budget was kept, the table went to 256, `MAXCONN` is 16, and Firefox is half the table instead of all of it. See THE CONNECTION CEILING row above for the numbers and for the three latent defects raising it uncovered. It was never a rootless problem -- it was the same for `jwm`. |
| Shared fate between clients | **Measured, and the received answer was wrong.** `windows_high_water 1` said a rootful X session is one surface, and §8 concluded rootless would give each X toplevel its own limits. It would not: `MAXMAP`, `MAXOBJ`, the frame-callback slice and the window budget are per **connection**, and **Xwayland opens exactly one connection rootful or rootless** — measured both ways, `conns 1` each. Rootless would also make the mapping table *grow* with window count where rootful holds it at 2 for any number of X clients (8 X windows, all resizing: still 2), and it would hit `BB_SLOTS = 8` — the whole system's v2 backbuffer pool, one slot per X toplevel instead of one per X session. What was actually shared and should not have been is now fixed in `user/wsyswl.ad`: the frame-callback table was ONE table of 64 for every client (a client taking the last slot silenced everyone else's initial-draw callback), `MAXWIN` was 12 for the whole server, and `MAXCONN` was 4 — fewer than two namespaces plus Firefox plus the chrome. Now `FCPERCONN`/`WINPERCONN` partitioned per connection with `MAXWIN >= MAXCONN * WINPERCONN` checked as arithmetic by the test, and `MAXCONN` 8. `tests/linux/wsyswl_shared_fate.sh` (18 PASS) and `docs/linux_window_manager.md` §8a. |
| The connection ceiling | **`MAXCONN` was 8 and Firefox alone reaches 8, so the one number blocking rootless Xwayland from being the default is gone: it is 16.** THE CLAIM WAS CHECKED BEFORE IT WAS ACTED ON, and it holds -- `conns 8` four seconds after `firefox-esr` starts, with its content, GPU and utility processes. It is also Firefox's TRUE appetite and not a truncation, which is the measurement that picked the new number: rebuilt at `MAXCONN 32` Firefox still opens **exactly 8**, with one tab and with ten (`conn_refused 0` both ways). So the browser's demand is a bounded 8 and the ceiling only has to hold what runs beside it -- NORTH_STAR's own workload is a browser plus `enter debian` plus `enter alpine`, and an Xwayland is ONE connection per namespace however many X clients are behind it: 8 + 1 + 1 = **ten, which does not fit in eight**. Firefox is now 8 of 16 rather than 8 of 8. **WHAT A SLOT COSTS, to the byte, because a ceiling defended with an adjective gets raised again by guess:** 55,320 bytes per connection -- 45,056 of it the eleven object tables, 8,192 the reassembly buffer, 1,536 the shm mapping table. Confirmed by building the same source at 8 and at 32 and differencing the ELF (3,178,736 - 1,850,976 = 1,327,760 for 24 connections = 55,320 each, to within four bytes of padding), which is also what proves no per-connection array was missed. Sixteen is 864 KiB of BSS where eight was 432 KiB. The comment in the file said "about 350 KB" for eight and was **wrong** -- `obj_h` and `obj_i` were added later and the arithmetic was never redone. **THE PRICE IS NOT THE BSS, IT IS THE WINDOW TABLE.** `MAXWIN >= MAXCONN * WINPERCONN` is the no-starvation invariant, so 16 connections at the budget of 16 the last pass deliberately doubled means 256 rows, and `WSYS_MAX_WINDOWS` 128 -> 256 (`WSYS_VERSION` 5 -> 6). That is **18.17 MiB where it was 9.15**, and unlike the paint pool it is RESIDENT and not address space -- `shm_attach` memsets the whole of `struct wshm`, so every page is touched. Measured with `du`, not computed: 18,608 KiB allocated for 19,052,956 bytes, 74,425 bytes a row. Keeping the table at 128 was available and the price was halving `WINPERCONN` back to 8, which turns `wsyswl_ceiling.sh` red -- twelve X clients on one Xwayland are twelve windows on ONE connection. **WHY NOT 32:** it needs 512 rows and 36.21 MiB resident on every boot of every machine, and buying that with a weakened starvation guarantee is a different pass. So **two browsers at once still do not fit** (8 + 8 + 2 = 18) and that is named here rather than hoped away -- it is the next ceiling. `sys_waitfds`'s `WAITFDS_MAX` is 64, which caps `MAXCONN` at 61 for ever. **THE SEGMENT COMPATIBILITY QUESTION WAS RUN, NOT REASONED ABOUT**, in both directions, with two real builds against one file. A v6 build on a v5 segment ftruncates it up and memsets all 18.17 MiB (poison bytes gone, rows 128..255 zero). A v5 build on a v6 segment -- the new direction, the first time two builds disagree about the SIZE of the mapping -- maps only the first 9,593,244 bytes, re-inits what it mapped, and leaves rows 128..255 holding a dead session's bytes; it cannot read them (its array bound is compiled in) and the next v6 attacher memsets the lot before anything reads a row (verified: the 0xCD tail survives the v5 pass and is gone after the v6 one). No silent half-share of a table two builds disagree about. `struct wwin` is byte-for-byte unchanged and the chrome segment does not scale with the window table, so it is untouched at version 1. **THREE DEFECTS FOUND ON THE WAY, all the same shape -- a ceiling written down twice:** (1) `waitset` was `Array[16]` and the loop filling it with one entry per live connection **has no bound check at all** (only the two fds appended after it were guarded, against the literal 16), so raising `MAXCONN` alone would have written 19 entries into a 16-entry array on every pass of the event loop, into whatever BSS follows. (2) The **listen backlog was the literal 8** -- the old `MAXCONN` written a second time. Refusing a client BY NAME requires accepting it first, so a burst past the ceiling against a queue of 8 gets bounced by the kernel with ECONNREFUSED, which a Wayland client reports as *cannot open display*, as if no compositor were running. This showed up as two flaky runs before it was understood; it is `MAXCONN + 16` now and the test counts that outcome separately. (3) The refusal was staged in the shared `out` buffer, whose companion `out_fd` is a **pending descriptor** for another client -- a keymap memfd or a clipboard pipe -- so on the wrong pass a refusal would have handed a real client's fd to the client being turned away and closed it. It has its own buffer now. **AND EXHAUSTION NOW TELLS THE TRUTH TO THE CLIENT, not just to a console nobody is watching.** Before: the socket was closed, and what the refused program printed was `No wl_shm global` -- measured -- blaming a protocol global that is present and advertised. That is a gap answering something success-shaped, arriving from the client's side. Now the server sends `wl_display.error(no_memory)` before closing, with a message built from `MAXCONN` itself so it cannot drift: *wsyswl: connection table full (MAXCONN=16) -- this client was refused, not one of its windows*. `tests/linux/wsyswl_conn_ceiling.sh` (**27 PASS**, offscreen, no VM, about a minute) drives 16 clients on, asserts every one is accepted, then drives PAST the ceiling and requires the clients past it to be refused **by name on the wire** -- not accepted, not dropped in silence, and not bounced by the kernel. It also checks that the overflow costs the refused client and nobody else (all 16 still connected, `conns` unchanged), that a freed slot is reusable, and re-derives all 35 per-connection array sizes from `MAXCONN` in source, because Adder array bounds are integer literals and `Array[MAXCONN * MAXOBJ, int32]` is not expressible. **With the change reverted it is 18 PASS / 10 FAIL**, including the four overflow clients going back to `DROPPED the server said nothing and closed`. `wsyswl_ceiling.sh` is still 9 PASS (pool now `slots 12/256`), `wsyswl_shared_fate.sh` 18 PASS, `wsys_close_button.sh` 10 PASS. **SUPERSEDED IN ONE RESPECT, AND IT IS THE CENTRAL ONE: "the price is the window table" was TRUE AND MISATTRIBUTED.** The table was resident because `shm_attach` memset it, not because a window table has to be resident. See TWO BROWSERS below; `MAXCONN` is 32, the table is 512 rows, and an empty one costs 2,048 KiB rather than 36.21 MiB. |
| Two browsers | **They fit, and the memory the last pass refused to spend was never being spent on anything.** `MAXCONN` is **32**, the window table is **512 rows**, and an EMPTY table costs **2,048 KiB resident** where 256 rows cost 18,608 KiB -- half the rows, nine times the memory. The wall was real arithmetic over a misattributed cause: `MAXWIN >= MAXCONN * WINPERCONN` took the table to 512 rows, and 512 rows was measured at 36.21 MiB RESIDENT because `shm_attach` ran `memset(shm, 0, sizeof *shm)` over a segment `ftruncate(2)` had just handed it out of a **fresh tmpfs file** -- bytes the kernel had already promised read as zero and had allocated nothing for. The memset's entire effect was to fault in and dirty 4,650 pages of a window table with no windows in it. **THE ZEROES WE DO NOT WRITE**: a segment we just created needs no clearing; a pre-existing one that disagrees about version is cleared by **punching a hole**, which zeroes it AND gives the pages back (strictly more than `memset` did); and the `memset` fallback, for a kernel that will not punch, covers only the bytes that existed before our own `ftruncate`. Measured with `du`, by the gate: 256 rows 18,608 -> 1,024 KiB; 512 rows and 32 connections, ~2,048 KiB; three browsers and two namespaces actually running, **2,252 KiB of 36 MiB mapped**. A row that holds a window still costs its 74,164 bytes -- the honest price, and one that scales with what a person is doing. The ~4 KiB-a-row floor that is left is NAMED rather than rounded away: `win_find` and the `/dev/wsys/windows` reader scan the table for `used`, which is the first word of a row, so a scan touches one page of every row. 4 KiB against 74 KiB, an 18x reduction, not an infinite one. **THE INVARIANT IS KEPT WHOLE.** A shared pool of rows with a per-connection cap was the obvious alternative and was rejected in the file with the reason: it trades an invariant that is arithmetic and checkable from source for a POLICY, whose answer to exhaustion is that a client's guaranteed budget stops being guaranteed and starts depending on its neighbours. Reservation, at a price that is now address space. **AND THE ARITHMETIC THAT NAMED THIS GAP HAD A GUESSED NUMBER IN IT.** "8 + 8 + 2 = 18" assumed a second browser had a second browser's appetite. Driven: **firefox-esr is 8 connections, chromium is 2** (browser + GPU process), Xwayland 1 per namespace. Firefox + Chromium is TEN and would have fitted in 16. What does not fit is the case a namespaced distribution makes ordinary -- a Firefox in the native root and a Firefox inside `enter debian { … }` -- which really is 8 + 8, and then the two namespaces' Xwayland are 17 and 18. `tests/linux/wsyswl_two_browsers.sh` (**24 PASS**, offscreen, no VM, no host GPU) drives both arms with the real programs: firefox + chromium + two rootless Xwaylands + an xterm on each is 12 connections with `conn_refused 0` and `windows_high_water 2`, and a SECOND firefox takes it to **20 connections, three browsers and two namespaces running at once, `windows_high_water 3`**, with `window_budget_full`, `drop_no_window`, `drop_no_slot`, `frame_callbacks_full` and `obj_id_refused` all still 0 -- the connections fitting did not just move the failure to a window. **Its control is RUN, not described**: section 5 rebuilds the same source with `MAXCONN` back to 16 (one number, arrays left large so nothing else differs) on a fresh segment and drives the same workload -- `conns` stops at 16, `conn_refused` 3-4, refused BY NAME on stderr. **AND RAISING IT FOUND A FIFTH CEILING WRITTEN DOWN TWICE, which was the REAL one all along: `DEVTAB_MAX` 64.** `user/linux-syscalls.c`'s per-process synthetic-device table was 64 entries and `wsyswl` holds FOUR per window (`<wid>/draw/ctl`, `keys`, `pointer`, `event`), so **SIXTEEN WINDOWS was the true ceiling of the whole machine** -- with 240 rows of the window table free, and with `MAXWIN >= MAXCONN * WINPERCONN` having been arithmetic over an unreachable number since it was written. Measured: 32 clients gave `conns 32` and `windows_high_water 16`, every window past the sixteenth counted as `drop_no_window`. It is the worst-behaved of the five because **it fails as somebody else's limit** -- the message a person sees points at the one table that has room. `DEVTAB_MAX` is **2112** now, DERIVED (4 per window * `WSYS_MAX_WINDOWS` 512 + 64), and the ceiling gate re-derives it from both files so they cannot drift apart in silence again. Exhaustion names ITSELF on stderr with the constant and the file to edit, and `win_open`'s device refusal gets its own counter, `newwindow_refused`, so "the runtime ran out of file slots" and "the window system ran out of windows" stop looking alike. `devtab_find` -- called on every read, write, lseek, close and dup, and scanning the WHOLE table on a miss, which is the common case -- is now an `fd -> slot` index, so this is **cheaper on the hot path than the 64-entry table it replaces** as well as 32x larger; the map is a hint that is always re-validated against the slot's own `used`/`fd`, which is what makes stale entries safe. ~824 KiB of BSS per program, untouched: allocation takes the first free slot and stops. **SEGMENT COMPATIBILITY**: `WSYS_VERSION` 6 -> 7, `struct wwin` byte-for-byte unchanged and every field of `struct wshm` before `win[]` frozen, so a v6 and a v7 build agree about where windows 0..255 are and disagree only about how many follow. A v6 binary on a v7 segment maps the first 19,052,956 bytes of a 37,972,380-byte file, re-inits what it mapped, and cannot reach rows 256..511 (its array bound is compiled in); the next v7 attacher **punches the whole segment** before anything reads a row, which is strictly cleaner than the memset that used to do it. **GATES**: `wsyswl_conn_ceiling.sh` **30 PASS** (was 27; section 6 now asserts the OPPOSITE of what it did -- sparseness, as a ratio so the next `MAXWIN` need not edit it), `wsyswl_ceiling.sh` **11 PASS** (was 9; a new section drives 24 one-window clients and requires all 24 -- 36 windows at once, where it would have read 16), `wsyswl_shared_fate.sh` 18, `wsyswl_rootless.sh` 37, `wsyswl_wheel.sh` 30 (the Steam scroll path untouched). **WITH THE FOUR SOURCE FILES REVERTED**: `wsyswl_conn_ceiling.sh` is **26 PASS / 4 FAIL** (the table 18,608 KiB resident of 18,606 mapped; `DEVTAB_MAX 64 < 1024`) and `wsyswl_ceiling.sh` is **10 PASS / 1 FAIL** -- *only 16 of 24 windows were created; 39,890 surfaces were dropped for want of a window*. That revert run also caught a soft-green in the new gate and it is fixed: an ABSENT `newwindow_refused` counter and one reading 0 are the same empty string, so the check now fails when the counter does not exist. **WHAT IS LEFT**: `sys_waitfds`'s `WAITFDS_MAX` is 64, so `MAXCONN` can never exceed **61**. That wall did not move and is the only one still standing. |
| Updating the window system under a running desktop | **A version mismatch no longer wipes a desktop somebody is using — it REFUSES, and says so.** `user/linux-wsys.c` had claimed since v5 that re-initialising a foreign segment is LOUD and therefore acceptable. Measured on a real installed machine by `tests/linux/installed_update_wsysver.sh`, it is neither: `hpm update` exits 0 saying nothing, the next application opened takes the **entire desktop** away (**3 distinct colours over 1,024,000 px**, `windows 0`, `/srv/wsys` 19,052,956 → 37,972,380), and the compositor keeps running, keeps `/dev/fb` and paints nothing — no panel, nothing to click, power button only. `shm_attach` now tells a **LIVE** segment (some running process still holds a row) from a **LEFTOVER** one and refuses the first while still clearing the second. Liveness is read with `pread(2)` and never a mapping; a foreign segment's row count is recovered from its SIZE, which is sound only while `struct wwin` (73,904), `struct wsink` (4,172) and `struct wshm`'s prefix (28) stay frozen — now `_Static_assert`ed, along with the two segment sizes. **18 PASS / 0 FAIL / 2 FINDINGs**: at STAGE C `/srv/wsys` is still 19,052,956, the screen is 1,459 colours and **0 px** different from the stage before, every window is still there, the refused binary printed the refusal by name, a leftover v6 segment made in the same boot was still grown to v7, and after a reboot a REAL CLICK opens the Applications menu with the panel and the taskbar back. **Reverted: 13 PASS / 4 FAIL**, red on exactly those questions. Full story, including the ordering defect the gate caught **in the fix**, under *And the gate A LIVE VERSION BUMP got*. |
| The refusal's FIRST REAL USER — the 7 → 8 bump | **It held on a real disk: the running desktop survived the update whole, and the only thing that failed was the program the person started next.** `WSYS_VERSION` 7 → 8 (the v1 display list left the world-readable segment for a per-window memfd) was run through `tests/linux/installed_update_wsysver.sh` against the LIVE channel: install 1.0.19 (v7), update to a locally-signed 1.0.20 (v8) over the loopback, hands on a real pointer over QMP. **22 PASS / 0 FAIL / 1 FINDING.** At STAGE C the segment is the same 37,972,380 bytes it was at B, the screen is **1,571 distinct colours** and 29,641 px from B, the window table still holds the same 4 windows, and the refused v8 binary read **version 7** out of the live header AFTER the update — which is how the version is witnessed now, because **v8 is byte-for-byte v7's layout, so the SIZE no longer tells the two apart**. The leftover control was re-cut for that: one segment, four attaches, md5 `4ff2…` → `efdb…` → `efdb…` → `4ff2…`, a two-state ping-pong that only a version word explains. After the reboot a real click opens the Applications menu and the panel and taskbar are back. THE FINDING is the whole cost to a person: after the update every newly-launched program refuses, so the Applications button reacts and **no menu appears**, and the refusal is on stderr where a person sitting at the screen never sees it. The panel-lost-once defect did NOT reproduce (`visible` 1/1 at A and at B; the panel took two config reloads and survived). |
| What the person SEES when the update lands | **The finding above is closed: the machine now says, on the screen, that it needs a restart.** After an update every newly-started program refuses, so the Applications button reacted and **no menu appeared** — and the five explaining lines went to stderr, which on this image is the serial console. A correct refusal and a dead button were the same picture. **The refused program cannot draw; that is what being refused means**, so it leaves a mark and the PANEL — which attached before the update and still owns its window — draws. `user/linux-wsys.c` appends one line to `<segment>.refused` from **inside `seg_refuse_message`, past its once-per-process guard**, so the mark and the words have exactly ONE condition between them and nothing else in the tree opens that path: a mark exists **iff** a real version refusal happened. (`$HOME/.hamde/appmenu.fault`, which the panel already reads, was deliberately NOT reused — it means "the menu got no window", which a crash or a missing font satisfies too, and a notice telling somebody to reboot because their editor segfaulted is worse than none.) It lives in `/srv`, tmpfs and fresh every boot, so **the evidence cannot outlive the restart it asks for**; the reader's serial is the file's SIZE, which only grows, so dismissing acknowledges an offset and a genuinely new refusal still raises the card again. Best-effort and errno-neutral throughout — the refusal is the safety property, the notice is cosmetic on top of it. **`user/hampanelscene.ad`** grows its window for an amber card exactly as it already grows for the Applications dropdown, draws it LAST (over every popup) and hit-tests it FIRST (so a click cannot fall through to a menu row nobody can see). **THE NOTICE MEASURES ITSELF ON PIXELS, NOT A LOG LINE** — a log line is precisely what the machine already had and precisely what nobody saw. `installed_update_wsysver.sh`'s new **STAGE E** is a SECOND live update, v8 → v9, whose BOTH sides the gate builds itself from a symlink farm over this tree (only `user/linux-wsys.c` is a real file) on a separate repo root and port, because **the panel that survives an update is the OLD binary**: no change made here can put a notice on a screen owned by something that shipped last month, so the notice becomes measurable one bump later and this is that bump. It counts ONE exact colour in ONE fixed rectangle **four times in one session** and requires **EMPTY, FULL, FULL, EMPTY** — measured **0% → 0% → 82% → 82% → 0%**; the empty readings are the instrument check, since a wrong colour or rectangle makes every reading 0 and the block FAIL rather than pass. Deliberately not a size assertion: `struct wshm` is byte-identical in both directions here and a size would answer success-shaped while measuring nothing. **STAGE E: 8 PASS / 0 FAIL**, including THE REFUSAL IS INTACT at v8 → v9, the live segment still 37,972,380 bytes, `/srv/wsys.refused` read back off the disk naming `live=8 mine=9`, and the panel still answering the mouse afterwards (77,528 px against a 171 px floor). **THE FIRST RUN OF STAGE E WAS RED AND THE RED WAS THE HAND**: the Applications button is a toggle over a pid, STAGE D had left a menu open, and the panel correctly CLOSED it — no spawn, no refusal, no marker. The panel's own log said so (`launched /bin/hamappmenu -self` at D, nothing at E); the hand now clicks twice and asserts at the second. **`tests/linux/de_update_notice.sh` (10 PASS, offscreen, about a minute)** asks the same question of wsysd + hamdesktop + hampanelscene on a file-backed framebuffer with a real v9-built binary, so this stays measured without three boots. **WHAT THE SAME RUN ALSO SHOWED, and it is about the gate and not the notice: stages A–D are now measuring nothing, because the published channel CAUGHT UP.** 1.0.20 is live and it is wsys v8, which is this tree's version, so `hpm update` at STAGE B moves no version at all: at STAGE C `cat /dev/wsys/windows` **exits 0 and prints the window table**, the leftover control's md5 is `efdb…` for all four attaches, and six assertions that exist to see a bump go red for want of one. **27 PASS / 6 FAIL / 0 FINDING overall, and all six FAILs are that one cause.** Stages A–D need the published channel BELOW this tree's `WSYS_VERSION` and cannot check it themselves; that precondition is now stated in the file. STAGE E is unaffected — it builds both sides. |
| Debian | `enter debian { sh }` — bookworm on its own filesystem, amd64+i386. Works **from a uid-1001 desktop terminal**, and something inside can build a container (`bwrap --unshare-user`). The root switch is `MS_MOVE` + `chroot`, what `switch_root(8)` does: `pivot_root` returns EINVAL on an initramfs boot's unattached `rootfs`. `glxgears:i386` renders on the Hamnix desktop through XWayland → `wsyswl` → `wsysd` → `/dev/fb`. |
| Distributions | **Two, at once, on the live boot AND on an installed disk.** `#distro/<name>` is a parameterised subtree server; `/etc/distros` maps a name to a medium **by ext4 volume label**, so which disk is `/dev/vda` cannot silently decide which distribution you entered. `enter alpine { … }` (musl, 3.24.1) and `enter debian { … }` (glibc, 12.15) both work in ONE boot from the console AND as uid 1001 — `tests/linux/two_namespaces.sh`, with a negative control that `/etc/alpine-release` is invisible inside Debian. An unprivileged process cannot open a block device to read a label, so `bind` falls back to the mount point the boot already posted the server at: **the name is what crosses the privilege boundary.** Alpine costs **26 MiB** without graphics, 333 MiB with; Debian is 4.5 GiB. Each has its own section in the DE application menu, named for it, driven from `/etc/distros` rather than from a compiled-in path. `etc/rc.boot.installed` sources the same generated `/etc/rc.distros` the live boot does, so `enter alpine` and `enter debian` survive a reboot into an installed system -- `tests/linux/installed_distros.sh`, the boot nobody had ever run. `docs/linux_distro_namespaces.md`. |
| Audio | `/dev/audio`, `/dev/audioctl`, `/dev/audioin` on intel-hda, ported from Hamnix's `audio_cdev.ad` + `hda.ad`. Proven by FFT on a WAV captured out of QEMU: 1000.28 Hz, 444.57 Hz and a 660.90 Hz sine, right durations, square-wave harmonics. `arecord` delivers 97.4% of a 48 kHz stereo second. **It MIXES**: an ALSA substream has one writer, so `/srv/audio` is a shared mix ring and a detached pump owns the card — two programs playing two tones appear in ONE capture as both frequencies, summed (rms 1.42× solo), and a writer at a third of real time interrupts the other in 0 of 65 windows. `docs/linux_audio_mixer.md`. |
| Shutdown | **An installed machine can be turned off, and the filesystems are flushed on the way down.** `/dev/reboot` is served (`user/linux-syscalls.c`), ported from Hamnix's `DEV_REBOOT` cdev with its protocol intact — first token, three verbs `poweroff` / `reboot` / `halt`, reads are EOF. A recognised verb is `sync(2)` then `reboot(2)`. Until this landed nothing served the name, so `reboot`, `poweroff`, `halt` and `init 0` / `init 6` all died on the open and **every restart of an installed machine was the equivalent of pulling the plug** — it survived only because ext4 has a journal. An installed disk now writes to `/etc` and reboots **in the same breath with no sleep**, and the next boot is running the rc the last one wrote: `tests/linux/reboot_device.sh`, 37 PASS, `reboot: Restarting system` in 13 s and `reboot: Power down` in 11 s. `poweroff` and `halt` were not in the image at all and now are. uid 1001 gets EPERM and every client reports it **by name**; the desktop's Power Off works because `hamsessui` is spawned by the root chrome. `docs/linux_installed_update.md` §2c. |
| Compiler | `ac foo.ad -o foo` on the box: `host_ac` natively, then clang inside the Debian namespace. **This was true of the IMAGE and false of the CHANNEL, and the headline above said "measured" for eleven versions.** `/bin/ac` is a driver, not a compiler — it execs the hard-coded `/bin/host_ac` — and the published `hamnix-adder-1.0.12.tar.gz` (sha256 `d22ce377e5bd…`, exactly what the index advertised) contained **two entries**: `PKGINFO` and `files/bin/ac`. No compiler, no runtime sources. On a machine installed from 255.one, `ac hello.ad` answered `ac: cannot run /bin/host_ac`, exit 10, no binary — so for exactly the machines NORTH_STAR's invariant is about, the capability did not exist. `host_ac` had been excluded from the channel by name, with the reason "built for the BUILD HOST's libc … the shippable compiler is `ac`, which IS packaged"; `readelf` refutes both halves — `host_ac` has no `.dynamic` section and no `INTERP` ("not a dynamic executable"), while `ac`, the one that shipped, is the one carrying `NEEDED libssl.so.3 libcrypto.so.3 libcrypt.so.1 libc.so.6`. `hamnix-adder` now carries the compiler (79974 B → 585056 B) and the exclusion is deleted. It is enforced where it cannot be skipped: `tests/linux/channel_compiles_adder.sh` unpacks the toolchain out of the channel tarballs, stages a root whose `/bin` is those files and nothing else, runs the real `ac` through its real `rfork` + binds + `bind '#distro' /`, and **runs the ELF that comes out** — 8 PASS / 0 FAIL, 3 s, and `scripts/hamlinux_packages.py` runs it before it writes `index.json`. Against the published 1.0.12 bytes it scores 2 PASS / **3 FAIL**. |
| GPU | The Vulkan userspace (loader + venus/ANV/NVK/RADV/lavapipe) installs into the **Hamnix root** by hpm — no namespace entry. `vk_core` has a real Vulkan backend (`lib/vk/vk_linux.ad` + `user/linux-vk.c`), byte-identical to the software rasterizer, armed by default on real silicon. |
| Build | **Every application in `user/` builds through the LLVM lane** — 363 of 363, with 4 of the 367 files being LIBRARY MODULES that have no `main` and are not applications. `scripts/hamlinux_sweep.sh` computes and prints that headline next to its own definition; nothing is hand-derived. `scripts/hamlinux_build.sh` knows the per-program extra objects (`wsysd` needs the Vulkan shim), so every build path links, not just the image's. |
| Idle | **An idle desktop is idle.** It was not: with nothing open, no input and nothing running, the host's QEMU sat at **203.6%** of one cpu and `hamdesktop`, `hampanelscene` and PID 1 each burned 11 s in a 20 s window, in state R. Now **6.8%** with the bare desktop and **7.3%** with a terminal open, every process at `0:00`, no zombies. Five separate causes, all the same shape and all invisible to every functional gate — see THE IDLE CENSUS below. And an idle desktop is not the only thing that has to be idle: **an idle APPLICATION does too**, and 26 of them each burned a full core with every gate green. The run sweep's `cpu` column found them; all 26 are now at 0.1 s of cpu in a 16.7 s run and pixel-identical. `tests/linux/de_idle_cpu.sh`, `scripts/hamlinux_runsweep.sh`. |

#### THE IDLE CENSUS, and why nothing caught it

The defect the machine's owner spotted from his own panel's CPU widget. It is
worth its own section because of *how* it hid: everything worked. Every gate
on this tree passed, the screenshots were right, the display lists were right,
and the machine was on fire. A measurement of TIME was the only thing that
could see it, which is why the gate measures TIME and does it **on both sides**
of the VM boundary — guest `ps` deltas name the guilty process, and the host's
own `/proc/<qemu>/stat` catches the ones `ps` cannot see. It had to: after the
first fix every guest process read `0:00` and the host still read 104.5%.

Five causes, found in that order. The fifth is the largest by count and was
invisible until the run sweep grew a `cpu` column, because a park and a spin
are identical in every other column a sweep has.

* **`sys_waitfds` handed its fds to `poll(2)`, and a `/dev/wsys` fd is a
  descriptor on `/dev/null`.** `devtab_open` backs every synthetic-device open
  with a real `/dev/null` fd so it survives fork and cannot collide — right for
  read/write/close, catastrophic for poll, because `/dev/null` is always
  readable. So **every parking event loop in the system was a busy spin**,
  including the two written specifically not to be and commented as such.
  `sys_waitfds` now sorts its fds by what they are: a `/dev/wsys` ring waits on
  the ring's contents and sleeps in a **futex on an `inputgen` word in the
  shared segment** (the faithful stand-in for devwsys's `waitfds_notify` — a
  keystroke wakes the park at once, an idle desktop wakes never); a `/net` file
  polls the real socket underneath it; an ordinary fd still goes to `poll`.
* **`sleep` was a busy-wait** on `sys_get_jiffies`, with a `sys_yield` added
  later to make the spin polite rather than absent. Every `sleep 4` in every rc
  cost a core for four seconds. This was the 104.5% that remained when every
  process read `0:00`: `sleep` is a child that lives entirely between the two
  `ps` samples and appears in neither.
* **A shell at a prompt with nobody typing burned a core.** `ed_readline` polls
  stdin non-blocking (the heartbeat and the service supervisor must tick) and
  spun on `sys_yield` between polls. A desktop with ONE TERMINAL OPEN — the
  case a person is actually in — was back at 110.2%.
* **`RFNOWAIT` was ignored, so every detached spawn left a permanent zombie.**
  `lib/p9.ad`'s `spawn_detached` relies on the kernel reaping detached children
  at every fork; this port had no reaper and no severed link, so hamdesktop's
  boot chime was still on the process table a minute after it played. The
  runtime now remembers detached pids and waits on **those and only those** —
  not a blanket `waitpid(-1)` drain, which could steal a status from code that
  was waiting for it. Separately, background jobs were only reaped at a PROMPT,
  so on a boot whose rc is still running they stayed zombies for as long as
  that took (`jobs_reap_quiet`).
* **26 APPLICATIONS EACH BURNED A FULL CORE, AND ONLY A `cpu` COLUMN COULD SEE
  IT.** With the four above fixed the desktop idled at 6.3% — but that is the
  desktop with nothing open. Open almost any application and a core went back
  on. The run sweep now records cpu seconds beside wall seconds and named 23
  scene clients plus `hamscreensaver` at ~1.0 s of cpu per second of wall,
  while the compositor beside them — the process actually rasterizing — spent
  0.08 s in ten. `crond`, which starts on every boot, was 14.3 s of 15.6 s.
  Fixed in `hamtoast` + `crond` (the two demonstrations) then all the rest;
  **measured before and after in the same jail, 28 rows: every one of the 24
  goes 14.9 s → 0.1 s of cpu in a ~16.7 s run, and every one is
  PIXEL-IDENTICAL — the sweep's `fbpx` column reads the same number in both
  arms for all 28 rows, controls included.** Four distinct causes:

  * a yield dressed as a sleep — `while sys_get_jiffies() - s < N:
    sys_yield()` — in 8 scene clients;
  * a bare `sys_yield()` at the bottom of a `hamui` event loop, with nothing
    pacing it at all, in 9;
  * a bare jiffy spin with not even a yield in it, crond's shape, in 2;
  * **one line in a library**: `lib/hamsdl_dev.ad`'s `sdl_dev_delay()`, the
    frame pacer every hamSDL and hamGame device client ends its frame with —
    `sdlpong`, `hamgamedemo`, `hamgamesnake`, three programs from one fix.

  Two were doing worse than spinning: `hamview` re-published its WHOLE v2
  backbuffer (a full recomposite) on every pass of that loop, and
  `hamimgscene`, whose entire remaining job after uploading its image is to
  EXIST, did that with `while 1 == 1: sys_yield()`.

  **And two of the fixes were in the helpers written to cure this.**
  `lib/hamsceneloop.ad`'s `hamscene_park` fell back to `sys_yield()` when
  given no keys fd, under a comment saying that was how "a keyless app never
  busy-spins either"; `lib/hamui.ad`'s `hamui_wait` had the same fallback for
  a caller with no window yet. Both now park.

  **Nothing is less responsive and several things are more**: `/keys` is
  waitfds-wake-wired, so every client that now parks on it is woken BY the
  keystroke instead of rediscovering it on its next round-robin turn. Where a
  client has no fd to be woken by, the park interval is the same number the
  spin window was. `sdl_dev_delay` deliberately does NOT wake on a key —
  these games advance their simulation once per loop, so an early wake would
  speed the game up when you press a key.

  A last one worth keeping: **eight more programs carry the identical loop and
  the cpu column read 0.1 for every one of them**, because in the jail they
  never reach it (`hampkgscene` blocks in `hpm refresh`; `hamctl` and
  `hamfmscene` exit; the `hamdesktop` / `hampanelscene` / `hamtermscene` spins
  are fallback branches; `ham2048scene`'s is inside a tile animation). They
  are fixed on the strength of the shape. A green row for a loop that was
  never entered is not evidence about the loop.

One test-side lesson worth keeping: the reported census showed two `wsyswl`
zombies, and the first draft of this gate reproduced them — because it sourced
only `/etc/rc.d/rc.5`, skipping the distribution binds, so each per-distribution
Wayland server died on `cannot listen on /n/debian/run/wayland-0`. That is a
defect of the TEST that would have been reported as a defect of the system.
The gate boots the production `rc.boot` verbatim now.

That number used to read "359 of 367", with the eight shortfalls grouped as
four `*_host.ad` harnesses importing kernel source that is not in this
repository, three libraries with no `main`, and **one that genuinely bailed the
backend's SSA subset (`hambrowse_tabs`)**. That grouping was made by reading.
Re-measured by running, `docs/linux_build_count.md`:

* **Nothing bails the SSA subset, and nothing ever did.** `hambrowse_tabs` is a
  fourth LIBRARY, imported by `hambrowse` and `hambrowse_gfx_window`. It emits
  `funcs=28 emitted=28 bailed=0` and then printed "body bailed the SSA subset"
  because `hamlinux_build.sh` inferred a cause it had not checked: it looked
  for `@main` in the IR and, on not finding one, asserted a bail. A file with
  no `def main` was never going to emit one. That is now a distinct exit code
  (13, "no `def main`: a library module") and every `user/*.ad` in the tree
  reports `bailed=0`.
* **The four harnesses now build and RUN**, asserting 64 things about this
  tree's own `lib/htermsel.ad` and `lib/hamtextbox.ad`. The import they needed
  was pure — two byte buffers with an offset-addressed read/write surface — so
  it was ported rather than excluded: `lib/devsnarf.ad`. Four dead
  `ci_battery_manifest.txt` entries are alive again with it.
* **367 is files, not applications.** Four of them are libraries. The
  denominator is 363, the numerator is 363, and the sweep now prints both with
  their definition rather than leaving a number to be quoted into a commit
  message.

The clipboard finding that fell out of it is in the HONESTLY BROKEN list below.

### `modprobe` works now, and two things it found on the way

`modprobe <name>` resolves a name to a module and loads its dependencies in
order. It could not before: **no `modules.dep` was generated anywhere on this
port** (`docs/runsweep_unhealthy.md` Kind 1), so `insmod /abs/path.ko` -- which
resolves nothing -- was the only thing that worked. On a stock Debian kernel
every graphics, filesystem and network driver is a module, so on real hardware
that was the difference between a machine and a black screen.

* The table is the build host's `depmod -b $ROOT $KVER` run over the modules
  `scripts/hamlinux_image.sh` stages; the GPU driver packages append their own
  lines from their install hook, because a table baked at image build time is
  stale the moment `hpm install` lands a new `.ko`. `user/hlinstall.ad`'s
  `copy_top("lib")` carries the file onto an installed disk.
* Gate: `tests/linux/modprobe_deps.sh` -- **32 PASS / 0 FAIL**, and **12/19
  with the change reverted**. It loads `bridge` -> `stp` -> `llc` in a VM and
  reads the result out of `/proc/modules`, not out of an exit code.

TWO THINGS IT FOUND, both of the shape this project exists to beat:

* **`user/lsmod.ad` printed a fixed `kmod_hello` row on every machine and
  exited 0** -- and it is the tool anyone reaches for to CHECK a modprobe, so
  it would have certified a modprobe that loaded nothing. It reads
  `/proc/modules`.
* **hamsh dropped a redirect whose target contained a `+`, silently.**
  `echo X >> /lib/modules/6.12.85+deb13-amd64/modules.dep` wrote to a file
  called `/lib/modules/6.12.85`, left the named file untouched, handed the
  rest of the path to `echo` as an argument, and exited 0. The lexer splits a
  bare word at `+`; the ARGUMENT path has fused such runs with
  `_glue_adjacent()` for a long time and the four redirect-target sites did
  not. Every Debian kernel release has a `+` in it, so this was every `>>`
  into `/lib/modules/<release>/` on this port.

### The coverage gate looked at `/bin`. 152 files lived one directory over.

`tests/linux/channel_covers_image.sh` enforced the owner's permanent rule --
what ships in the image must be updatable from the channel -- by comparing the
image's `/bin` against the package tarballs. **It compared nothing else, and
neither did anyone reading it.** Measured on the published 1.0.12 channel,
whole image root against every package's file list: **154 files ship in the
image and are in NO package.** Two are `/bin` binaries (the two already
justified by name). The other **152 were in directories the gate never looked
at**:

| | |
|--|--|
| 34 | kernel modules -- `ext4`, `jbd2`, `mbcache`, `vfat`/`fat` + the `nls` tables, `virtio_blk`, `virtio_net`, `virtio_input`, `virtio-gpu`, `evdev`, `overlay`, `squashfs`, `loop`, and the whole `snd-hda` stack. Only `drm.ko` and `drm_kms_helper.ko` were carried by anything. |
| 1 | `modules.dep` -- the table `modprobe` had just been made to depend on |
| 23 | `/usr/share/adder` -- the Adder runtime SOURCES `/bin/ac` must link against; without them `ac hello.ad` compiles and dies at the linker |
| 21 | `/usr/share/man` -- every page `man` and `help` read |
| 20 | `/etc/skel` -- the launchers and documents a new account gets |
| 12 | `/etc` -- `profile`, `issue`, `motd`, `os-release`, `lsb-release`, `debian_version`, `services`, `protocols`, `networks`, `host.conf`, `users/*.ns` |
| 1 | `/usr/share/sounds/test.wav` -- the only thing `aplay` has to play |
| 1 | **`/init`** -- the program the kernel executes on an installed machine |

An installed machine could never receive a fix to the module that mounts its
**root filesystem**, and nothing failed to say so. Same shape as the audio
clients, the dropped desktop and the seven binaries.

* Now packaged: **`hamnix-drivers-base`** (the 34 modules, minus the DRM core
  `hamnix-drivers-drm` already owns -- both sets come from one
  `drm_core_modules()`, so no two packages own one path; the module NAMES are
  parsed out of `hamlinux_image.sh`'s `WANT_MODULES` so the lists cannot
  drift), **`hamnix-man`**, and the rest folded into `hamnix-adder`,
  `hamnix-desktop`, `hamnix-init` and `hamnix-audio`. `hamnix-base` now pulls
  in the manual pages and the boot modules. **100 packages**, `chanrun` 8/0.
* **`modules.dep` is not shipped, and that is the interesting part.** It is
  machine state: `depmod` wrote it over that machine's modules and three
  driver packages APPEND to it from their hooks. A package file at that path
  would be deleted-then-rewritten on every upgrade and take the appended
  driver lines with it -- `i915.ko` still on disk, and no line left that lets
  `modprobe` name it. So `hamnix-drivers-base` owns **`modules.dep.base`** and
  its hook **PREPENDS**: `cat base dep > new; mv new dep`. `user/modprobe.ad`'s
  `find_line` returns the FIRST matching line, so the shipped lines win over a
  stale copy and every appended driver line survives after them. Run under the
  packaged `hamsh` with the packaged `cat` and `mv` before it was written down.
* That hook does **not** touch `/etc/modules`, and that is a measurement:
  `linuxinit` reads it with ONE 8192-byte read, the image writes 2338 bytes,
  and appending 34 paths per update would silently truncate the boot's module
  list after three updates.
* `/init` ships from `hamnix-init`'s install hook (`rm` + `cp` from
  `/bin/linuxinit`) rather than as a package file: `hpm` would open it for
  writing on the running PID 1's text image and get `ETXTBSY`, failing the
  install on every machine that is up.
* **The gate now walks the whole root** and fails on an unlisted omission
  anywhere in it -- **7 PASS / 0 FAIL**, 281 image files checked, 42 excluded
  by name. `HOST_ONLY` became a table of path/reason pairs (host glibc and the
  loader, `/etc/shadow`, `/etc/resolv.conf`, the `hpm` trust roots,
  `/etc/distros` and everything generated from it, `/home/live`, the image
  version stamp, `/etc/modules`, `modules.dep`), and the table is itself
  checked for entries the image no longer has.
* Both directions were constructed deliberately rather than argued: dropping
  `ext4.ko`, `ls.1.md` and `etc/profile` from three built tarballs gives
  **6 PASS / 3 FAIL**, each named; stripping `hamnix-init`'s `install.hamsh`
  and `hamnix-drivers-base`'s `modules.dep.base` gives **4 PASS / 2 FAIL** --
  the two exclusions that claim "it ships by another means" are read out of
  the tarballs, not believed.

### What is HONESTLY BROKEN right now

Kept here deliberately, because a handoff that lists only successes is the
same failure this project exists to beat.

* ~~**THE COMPOSITOR CANNOT BE WOKEN BY INPUT**~~ — **FIXED, and the fix is
  8 to 27x on the number a person feels.** It was `sys_waitfds(&waitset[0], 0, 16)`
  with nfds LITERALLY 0 and `waitset: Array[4, int32]` never written, so the
  compositor was a fixed 16 ms tick and input-to-pixel was **p50 8.9 / p95
  16.1 / max 18.7 ms** against a 0.6 ms frame — 93% of the median was the loop
  not being woken. `waitset` is now `Array[16]` and FILLED (one slot per evdev
  device, `MAX_INPUT` 12, plus stdin; `WAITFDS_MAX` is 64), the 16 ms timeout
  is the FALLBACK, and three before/after pairs run back to
  back on the same host report **p50 0.33-1.07 ms, p95 0.54-7.31, max
  2.67-12.22**, pointer fps **60.8-61.1 -> 240.5-250.0** (the injection rate,
  not a ceiling: at 1000 ev/s it presents 998.8 frames a second for 6.6% of a
  core), and **idle that does not regress** — 62.1 parks/s either side from
  `/proc/<pid>/status`, 0 frames from the compositor, and five interleaved
  30 s rounds a side of `/proc/<pid>/stat` that differ by 0.012 points of one
  core when one clock tick over 30 s is 0.033. The un-jittered control that
  used to read 8x too good (p50 1.02 against a true 8.93) now agrees with the
  jittered probe to 0.02-0.75 ms, because there is no longer a tick to
  phase-lock onto. See `work/wsysd-wake-on-input`.

  **TWO THINGS THAT COST A PASS EACH AND ARE THE REUSABLE PART.**

  * **An fd only goes in the wait set if it is PROVED it can park on it.**
    poll(2) reports some descriptors readable ALWAYS — `/dev/null` does, and
    every offscreen gate runs `wsysd </dev/null`. One of those in the set does
    not make the compositor faster, it makes the park return instantly for
    ever: a busy spin that burns a core *and reports a flattering latency*.
    So `build_waitset()` drains every source and asks for a zero-timeout wait
    on each fd; one that still answers "ready" is answering about itself and
    is left out, three rounds required so a real event cannot disable a device.
  * **A REGULAR FILE IS THE SAME TRAP ONE LAYER OUT**, and it is why
    `sys_waitfds` grew a fourth fd class. `HAMWSYSD_INPUT` names a plain file
    of evdev records in every offscreen gate, and POSIX says a regular file is
    always readable whatever the offset. Readiness for one is now "the offset
    is behind the end of the file" and the sleep is an inotify `IN_MODIFY`
    watch — the mechanism the clipboard park already used.

  **AND THE FIRST VERSION OF THE FIX MEASURED WORSE THAN THE TICK IT
  REPLACED** (p50 9.89, p95 21.41, drag 51.9 -> 31.6 fps), which is kept in
  the branch history because the cause is not guessable. The wake mechanism in
  isolation is **0.039 ms**. wsysd's park, with `now_us()` either side, was
  16-40 ms where the baseline binary's is 16.107 ms every single time. The
  `poll(2)` inside it took the 16.08 ms it asked for — so the time was in the
  entry work: **creating and destroying an inotify instance on every park,
  because tearing down an fsnotify mark waits on an SRCU grace period.** The
  instance and its watches now live in the process, keyed on
  `(fd, st_dev, st_ino)` so a recycled fd cannot inherit another file's watch,
  and rebuilt only when the set changes.

  **AND THE SECOND VERSION REGRESSED IDLE, WHICH IS THE OTHER THING THIS TASK
  WAS TOLD TO WATCH.** Four interleaved 30 s rounds: baseline 1.07/0.63/1.00/
  0.67% of one core, the fix 1.33/1.10/1.23/1.13%, at the SAME 61.5-61.9
  parks/s -- the loop was not running more often, each park had got dearer by
  about 59 us against a park that costs ~136 us of CPU in all. The cause was
  the shape of the loop and not the wake: it ran a 0-timeout poll to sample
  the ordinary fds, then the sleeping poll, then went round and ran a THIRD
  0-timeout poll on the way out. The no-ring path now does ONE poll -- the
  non-pollable sources are counted first and decide whether its timeout is 0
  or the remainder, and when the sleep runs its course the regular files are
  re-checked once and the call RETURNS instead of looping, because an fd that
  becomes ready after poll(2) timed out is indistinguishable from one that
  becomes ready just after the call returns.

  **WHAT IS STILL TRUE**: a CLIENT REPAINT cannot wake this loop. wsysd learns
  a window changed by comparing a signature it reads out of `/dev/wsys/<wid>/
  ctl`, and those are snapshot files — ready by definition. The only waitable
  `/dev/wsys` object is a per-window ring, and mixing one into this set would
  be strictly WORSE than the tick: a set holding a ring sleeps in the futex on
  `inputgen` and caps its poll at 20 ms, and an evdev fd cannot futex-wake
  anything, so input would wait up to 20 ms instead of at once. The wait set
  is therefore all ordinary fds, the one shape `sys_waitfds` answers with a
  single uncapped `poll(2)`, and window-drag fps is therefore unchanged —
  measured three times over, and the spread between the three pairs (39-52 fps
  in BOTH arms) is the size of the host noise on that load, which is why the
  parks/s equality is the stronger evidence. The price of the win is named
  too: drag + pointer together is **62-66% of one core, for 244-250 fps,
  where the tick was 15-38% for 38-53 fps** — every pointer event now forces a
  full repaint instead of being coalesced into a tick, and there is no cap
  saying the compositor may not present faster than a panel can show. That cap
  is the obvious next question and it is NOT answered here.

* **THE COMPOSITOR PRESENTS AS FAST AS INPUT ARRIVES, AND CAPPING IT IS WORTH
  LESS THAN THE FRAME COUNT SAYS -- MEASURED BEFORE ANYBODY WRITES THE CAP.**
  Since the wake-on-input change there is nothing saying wsysd may not present
  faster than a panel can show: 250 pointer events a second produce 250 frames,
  1000 produce 998.8. The obvious inference is that a 60 Hz cap would save
  three quarters of the work. IT WOULD NOT. Same drag load, same binary, only
  the INPUT rate changed (which is what a cap would change about the output):

      input   60 ev/s ->  61.1 fps (907 full + 10 cursor-only)  38.6% of a core
      input  250 ev/s -> 248.0 fps (3707 full + 13 cursor-only)  60.5% of a core

  **4.1x the full repaints for 1.57x the CPU**, and the cost per presented
  frame FALLS from 6.31 ms to 2.44 ms. So the prize for capping this load at
  60 Hz is about **22 points of one core, not 45** -- real, and a third of what
  a frame-count argument promises. For scale, the OLD tick-paced compositor
  under the same load is 37.7% of a core for 39.6 fps: capping the new one to
  60 Hz would cost about what the tick cost and deliver 1.5x the frames at
  1/27th the latency.
  **THE LIKELY MECHANISM, STATED AS A HYPOTHESIS BECAUSE IT IS NOT PROVEN
  HERE**: present_rows() writes only the rows that changed, and a window that
  is being dragged moves a fixed distance per second, so four times as many
  presents each carry about a quarter of the damage. The pixels written per
  second are roughly constant and the frame COUNT is not what costs.
  **NOT MEASURED**: the same ratio on the GPU scanout path (which is
  single-buffered and tears), and whether pacing to vblank would fix the
  tearing and the power in one change. That is the design note for whoever
  writes the cap, along with: key it on the display's refresh rather than a
  constant, never cap OFFSCREEN (or every gate starts measuring a rate limiter
  instead of the compositor), and make it a MINIMUM INTERVAL BETWEEN PRESENTS
  that never delays the first input after a quiet period -- a cap that does
  delay it gives back the whole 8.93 -> 0.33 ms result for exactly the
  interaction people notice most.

* **A VERTICAL PANEL IS ACCEPTED BY THE CONFIG AND NEVER APPEARS ON SCREEN.**
  `tests/linux/de_panel_conf_shipped.sh` is 14 PASS / 1 FAIL, and it fails the
  same way with `user/wsysd.ad` and `user/linux-syscalls.c` reverted to
  `4b50eae2`, so it is nobody's regression -- but "pre-existing" is not
  "fine", and what is actually broken is now known rather than guessed. Its
  section 10 writes four panels, one per edge, and the panel agrees in its own
  log: `honoured, 4 panel(s)` and `config reload applied: 4 panel(s)`. The
  COMPOSITED SCREEN at that moment (the gate's own `maxc.raw`, scanned pixel
  by pixel) holds only the two HORIZONTAL ones: rows 0..55 and the bottom 56
  rows are panel grey `#eceef2`, the left and right edges are wallpaper
  `#284470` for at least 64 px in, and there is **not one `#ff00ff` pixel in
  the whole 1280x800 frame** -- the colour the gate gave the left panel
  precisely so it could not be confused with anything else. So `edge left` and
  `edge right` parse, count, and produce no pixels. The gate's assertion is
  right and its message ("the maximal panel set did not come up") points at
  the config, which is the one part that works.

* **THE ROOTLESS X PATH -- WHICH IS THE BROWSER PATH -- IS BROKEN, AND THE
  FIRST OF ITS TWO CAUSES IS FIXED.** `wsys_close_button` is 2 PASS / 1 FAIL
  and `wsyswl_rootless` is 7 PASS / 1 FAIL, both on "the compositor never got
  an X connection", and both fail identically at `4b50eae2`, so this predates
  everything in this session. It is not a gate problem: every X client, and
  therefore Firefox, goes through this.

  **CAUSE ONE, A DEADLOCK WITH XWAYLAND -- FIXED.** `x_read_exact()` looped on
  BLOCKING `sys_read` until it had all n bytes, called from the one thread that
  serves every Wayland client, and its callers ask for 32 bytes (`x_poll_msg`)
  or a setup reply (`xwm_connect`) after a poll that only ever guarantees ONE
  byte is readable. Both sides caught in the act, from `/proc`:

      wsyswl    state S  wchan unix_stream_read_generic  read(fd=6, count=20)
      Xwayland  state S  wchan do_epoll_wait             epoll_wait(..., -1)

  20 is the tail of a 32-byte X message after 12 bytes arrived. Xwayland is
  idle waiting on ITS Wayland connection, which only wsyswl can service;
  wsyswl is waiting for the rest of a message only Xwayland can send. Neither
  moves again, `publish_state()` is downstream of the read so the state file
  freezes mid-session (`conns 0`, `xwm_connected 0`, mtime unchanged for 26 s),
  and the compositor stops serving EVERY client, not just the X one.
  **The discriminator that localised it**: with `WSYSWL_XWM` unset the same
  binaries are healthy and wsyswl sits in `poll(2 fds, 16 ms)`. It is the X
  manager, not Wayland.
  The read is now non-blocking with a bounded wait (`X_READ_TRIES` x
  `X_READ_WAIT_MS`, 4 x 20 ms), and giving up drops the X connection and
  returns to the main loop -- which is what breaks the cycle, because once
  wsyswl is serving Wayland again Xwayland comes up and `xwm_pump`'s retry
  reconnects. **Measured after**: wsyswl stays in its 16 ms park, the state
  file keeps ticking, `conns 1`, and `xdpyinfo -display :88` succeeds -- the X
  server is up and being served. `wsyswl_conn_ceiling` is **30 PASS / 0 FAIL**,
  unchanged, so the Wayland path is not disturbed.

  **CAUSE TWO, THE X SETUP REPLY -- ALSO FIXED, AND IT IS WHY THE PATH BROKE
  IN THE FIRST PLACE.** `xwm_connect()` clamped the setup reply's additional
  data to 4096 bytes (the size of `xrep`, correctly) and NEVER DRAINED THE
  REST. Measured with a print in that function: **Xwayland 24.1.6 sends 8268
  bytes**, so 4172 stayed on a stream socket and every message afterwards
  started 4172 bytes into the wrong place. That is the desynchronisation that
  produced the 12-of-32 read, and after the deadlock fix it produced *`could
  not intern WL_SURFACE_SERIAL -- this X server is not an Xwayland`* against a
  real Xwayland that was answering `xdpyinfo` at that moment -- a message
  naming the one thing that was not wrong. `xrep` is 16 KiB now, the remainder
  is drained into `xsink` the way `x_poll_msg` already did, and the parse is
  bounded by what is in the BUFFER and not by what the server sent.
  **`wsyswl_rootless` is 37 PASS / 0 FAIL** -- the count HANDOFF recorded for
  it before it broke -- against 7 PASS / 1 FAIL both immediately before the fix
  and at `4b50eae2`.

  **STILL INTERMITTENT, AND NOT CLAIMED OTHERWISE**: `wsys_close_button` is
  10 PASS / 0 FAIL on two runs and 2 PASS / 1 FAIL on two others, same source.
  When it passes it passes completely -- two xterms mapped as wsys windows,
  `WM_DELETE_WINDOW` routed, the right client exiting and its neighbour
  surviving. When it fails it is always the same 10-second wait for
  `xwm_connected`. So the two structural defects are gone and the TIMING of the
  first connect is still marginal, most likely the one-attempt-per-32-passes
  retry cadence against that window. Cause not established, so no cadence
  change was made on a guess.

  **THE LESSON WORTH KEEPING**: a newer Xwayland is all it took. Nothing in
  this tree changed; the peer got bigger and a buffer that was never drained
  became a permanent desync. Every `if n > CAP: n = CAP` on a stream socket in
  this tree is the same bug waiting for a bigger peer.

* **`accept` HANDED BACK THE LISTENER, SO EVERY ADDER SERVER ON THIS LINE READ
  THE WRONG SOCKET.** Found by refusing to write off "x11srv fails its
  handshake on this host" as host-specific. strace says it in two lines:

      accept(5, NULL, NULL)       = 6
      read(5, ..., 12)            = -1 ENOTCONN

  It accepts a client and then reads from the socket it accepts ON.
  **PRE-EXISTING** -- both halves are byte-identical at `4b50eae2`, and the
  previous commit to `user/linux-net.c` is `8f4a1026`. **NOT host-specific**:
  it lives in this line's networking, so it is every user's, not this
  machine's.

  **WHY.** Plan 9's accept answers the NEW connection number on the ctl file.
  `user/net9.ad`'s `net_accept` does the only dance it can -- open ctl for
  WRITE, write "accept", CLOSE it (an fd opened for writing cannot be read
  back), reopen for READ, read the number. `linux-net.c` kept that answer in
  the OPEN FILE's snapshot, so the close threw it away and the reopen answered
  the LISTENER's own number. `net_accept` returned that, its caller opened
  `/net/tcp/<listener>/data`, and the first read is ENOTCONN because a
  listening socket has no peer. A lifetime mismatch between two sides' idea of
  what a ctl file remembers, and it fails as somebody else's error message --
  what x11srv printed was `setup read failed`.

  **THE BLAST RADIUS IS EVERY SERVER THAT TAKES A CONNECTION**: `httpd.ad`,
  `httpd_worker.ad`, `sshd.ad`, `u_server.ad`, `x11srv.ad`. Their own gates run
  on the BARE-METAL lane, where /net is the real devnet and the dance works --
  which is exactly why nothing here ever caught it.

  The answer is now left pending on the listener for exactly one read (the one
  open `net_accept` makes after closing the fd it wrote to), process-local on
  purpose: `struct connrec` is in a SHARED segment whose layout other builds
  agree on, and no other process has any business seeing this value.

  **GATE**: `tests/linux/x11_stream_resync.sh`, 5 PASS / 0 FAIL, offscreen,
  seconds. It asserts the handshake COMPLETES (that is the whole of this
  defect) and that the stream survives an oversized request (that is the
  clamp-without-drain one, measured at last -- it could not be, before this,
  because this defect sat in front of it). **The gate is proved able to fail**:
  against a build with the drain removed and this fix left in it reports 3 PASS
  / 1 FAIL and `VERDICT: DESYNCHRONISED`. It SKIPS rather than binding over
  anything already on port 6000, which is X display :0.

* **"CLAMP A PEER-DECLARED LENGTH AND KEEP PARSING THE SAME STREAM" IS A CLASS,
  AND THE TREE HAS BEEN SWEPT FOR IT.** The X setup reply that broke the
  browser path was one instance. The shape is: read a length off a STREAM (no
  message boundaries), clamp it to a fixed buffer, and carry on reading -- the
  leftover bytes become the next message's header, so the failure never appears
  at the clamp. It appears far away as a misparse wearing a confident wrong
  message, which is why it costs so much to find.

  **THE RULE, and it is three things and not one**: cap for the buffer, DRAIN
  the remainder, and **bound the parse by what is IN the buffer, not by what
  the peer said it sent**. That last clause is what actually prevents the
  misparse; the first two only protect memory and alignment.

  **FIXED THIS PASS** (all four found by sweeping, none by a failing test):
  `user/x11/x11srv.ad`'s request loop -- an X11 request may declare 262140
  bytes and PutImage routinely passes 4 KiB, so ONE oversized request
  desynchronised the connection for ever; `user/x11/xfill.ad` and
  `user/x11/xclient_demo.ad` -- the same setup-reply clamp as wsyswl, 504
  bytes, surviving only because in-tree they talk to a server whose reply is
  120 bytes; `user/sshd.ad` and `user/ssh.ad` -- the identification exchange
  stopped counting at 255 and left the rest of the line on the wire, which
  either accepted a truncated id (immediate binary-packet desync plus a wrong
  exchange hash) or let bytes past 255 be presented as a fresh "SSH-" line.
  **NOT EXERCISED**: those five files are the bare-metal line's, whose
  harnesses rebuild the kernel and boot a guest; they compile, and the drains
  are copies of the idiom already in the same files.

  **ALREADY RIGHT, so the next sweep can skip them**: `user/xsnarfd.ad` (drains
  into a sink, flags `rep_trunc`, and refuses an implausible setup outright --
  the model implementation, and the same protocol wsyswl got wrong);
  `wsyswl`'s `x_poll_msg`; `x11srv`'s setup auth drain; `distrofs` and
  `p9srv_demo` (REJECT an oversized 9P message, and `SRV_BUF_CAP` equals the
  advertised msize so a conforming client cannot exceed it); `ssh`/`sshd`'s
  binary packets (reject over 8192 and tear the session down); `http9` and
  `httpd_worker` (one request per connection, then close). **NTP and DHCP are
  UDP and cannot have this bug** -- a datagram keeps its own boundaries.

  **AND THE SAME DEFECT FACING OUTWARD**, which the sweep only found because it
  was looking for the shape rather than the symptom: `wsyswl`'s `o_u32` dropped
  a word when the 8192-byte output buffer was full and said nothing, so
  `emit_end` patched in a size that did not describe the bytes staged and the
  CLIENT's parser would desynchronise -- `flush()`'s own comment warns about
  exactly that. `o_cstr` was worse: its copy loop stopped at the boundary but
  the NUL and the padding after it were stored unguarded, four bytes past the
  end of the array into BSS. Overflow is recorded now and `flush()` refuses to
  send a buffer it knows is malformed.

* **THE VULKAN/GPU COMPOSITOR PATH IS 13x SLOWER THAN THE SOFTWARE ONE, AND
  NO MACHINE HAS EVER RUN IT.** The image stages only the venus ICD, which
  enumerates nothing, so `vk_set_backend(VK_BACKEND_LINUX)` fails and every
  desktop anyone has run has been on `vk_2d`. Forced on with the nvidia ICD
  (`tests/linux/de_fps_gpu.sh`, RTX 3090, `zero-copy 1, device-local 1` — the
  configuration `vk_arm()` treats as the good one): **7.5 fps** with the
  pointer, **4.1 fps** dragging, input-to-pixel **p50 84 ms**, and wsysd at
  **76% of a core WHILE IDLE**. `wsysd -bench 60` puts all of it in one place:

      software   us/frame total   679   clear 477  cursor   1  present   157
      GPU        us/frame total 66036   clear 531  cursor  99  present 67492

  `clear` — the part the device does — is the same. The 430x is `present`,
  i.e. `present_rows()`: the CPU reading the composite and `write(2)`ing it to
  /dev/fb. That follows directly from the zero-copy binding `comp_base = fb`,
  which puts the composite in device-local VRAM: every frame then drags 4 MiB
  back across PCIe uncached. A compositor whose last step is a CPU copy-out
  cannot hold its composite in device memory — either the present moves onto
  the device, or the composite stays in host memory and the device writes into
  it. Until one of those, the GPU path must not be enabled by default, and the
  fallback it never takes is the fast one.

* **THERE IS NO FAIR fps COMPARISON AGAINST MATE, AND THE REASON IS THE
  INSTRUMENT, NOT THE DESKTOPS.** `tests/linux/de_fps_mate.sh` stands MATE
  1.26 up on Xvfb at the same 1280x800 with the same stride and drives both
  with the same shared probe (`tests/linux/fb_change_probe.py`), calibrated
  on our side against wsysd's own presented-frame counter to 2%. Sweeping the
  sampler 8x:

      sampler      125 Hz   250 Hz   500 Hz   1000 Hz     8x sweep
      ours           52.4     54.2     54.8      53.0        1.01x
      MATE           14.6     30.8     69.6     138.4        9.48x

  Ours is flat — a rate. MATE's tracks the sampler one for one — saturation:
  X draws incrementally with no frame boundary and no present, so during a
  drag its shadow buffer is in flux at every sample and there is no frame rate
  in it to extract. Two more things are not comparable and are measured rather
  than assumed: **MATE's pointer is not in the framebuffer at all** (200
  moves/s produce 0.1 changes/s, because Xvfb's sprite is not in the shadow
  buffer, while ours is composited into the buffer wsysd presents), so the
  input-to-pixel figure has no MATE counterpart and is deliberately left
  unmeasured rather than re-based on a different stimulus; and MATE's input is
  XTEST straight into the X event queue, skipping evdev and libinput, which is
  a handicap in ITS favour. **What IS comparable is idle, and it is a tie**:
  ours 3.2 changes/s, MATE 3.0-3.3, both a panel applet resampling, neither
  spinning. So: our numbers stand alone, on purpose.

* ~~**`hpm update` left the desktop with NO PANEL AND NO TASKBAR.**~~ **FIXED,
  and gated offscreen.**

  Measured on a real installed machine running the published 1.0.17: the
  instant `hpm update` finished, the top panel and the taskbar vanished —
  both windows `visible` 1 → 0 — while the panel PROCESS stayed alive and
  kept logging `config reload applied: 2 panel(s)`. A real click on the
  Applications button afterwards moved 234 pixels: the mouse cursor and
  nothing else. The exact success shape NORTH_STAR.md warns about — healthy
  to anything counting processes or grepping logs, and no desktop at all to
  the person in front of it.

  `user/hampanelscene.ad`'s `_set_window_hidden` spells BOTH directions of one
  ctl verb — `hide 1` to withdraw a pooled panel window, `hide 0` to put it
  back — and `_reload_panels` writes `hide 0` to every panel window it is
  about to redraw. `user/linux-wsys.c`'s parser never read the argument: any
  line beginning `hide` set `visible = 0`. So **every reload of the panel
  config withdrew every panel window**, and rewriting `/etc/panel.conf` under
  a running panel is exactly what an update does. Nothing to do with the wsys
  version bump the same investigation was chasing, and nothing to do with hpm
  unlinking rather than rewriting — an in-place rewrite through the same inode
  reproduces it identically. `hamdesktop` is untouched because the backdrop
  never writes this verb, which is why the wallpaper survived and only the
  chrome disappeared. `tests/linux/de_panel_conf_replace.sh`, **17 PASS**,
  offscreen, ~40 s: it replaces the active config under a running panel (both
  ways) and asserts on the window table's `visible` field, on the bar PIXELS,
  and on a synthetic-evdev click producing a painted menu — never on the
  process being alive or the reload line, both of which stayed true through
  the defect. With the fix reverted: 11 PASS / 6 FAIL.

* ~~**THE SHIPPED `/etc/panel.conf` IS NEVER PARSED.**~~ **FIXED — the reader
  streams now, and a config it cannot read says so by name.**

  Found while gating the above. `_load_config` read at most 2047 bytes; the
  file as shipped is 3120 bytes and its first `panel` line does not begin
  until **byte 2834**, all of it comment header. So the file parsed to zero
  panels and the panel silently fell back to `_default_config` — which happens
  to render the same layout, which is why nobody noticed. **Editing the
  documented config file did nothing at all.** The only visible tell, and the
  thing that exposed it: the bars came up in a colour that is not the
  `color #d4d0c8` the file asks for (`_begin_panel` leaves `#eceef2`, and
  `_default_config` never overrides it). `_cfg_changed` had the same ceiling,
  so an edit to the directives at the END of the file did not even register as
  a **change**.

  **The fix is a shape, not a number.** A fixed buffer that is merely larger
  is the same defect at a larger size, and this tree has been bitten by
  exactly that three times (a 16 KiB hook-output limit, an 8 KiB
  `/etc/modules` ceiling, a `tail` that read only the first 8 KiB). So the
  file is not held in memory at all: `_load_config` reads it in **4 KiB
  chunks** and parses it **a line at a time** (`_cfg_parse_line` over a
  512-byte line buffer), and `_cfg_changed` streams the same way, hashing
  FNV-1a 64 over the whole file instead of keeping a snapshot buffer. The
  config now has **no size ceiling at all**. The one bound left is the length
  of a single LINE, which is a real bound on the grammar (the longest legal
  directive is `widget launcher <exec> <label>`; `LEXEC_SZ + LLABEL_SZ` is 88)
  — and crossing it is reported, not swallowed.

  **And it says so.** Falling back is fine; falling back *silently* is the
  bug, and it is the whole reason this survived. Every outcome now names the
  file it read, on stderr:

      hampanelscene: /etc/panel.conf: honoured, 2 panel(s)
      hampanelscene: /etc/panel.conf: parsed 0 panels from 3120 byte(s) --
          using the built-in default layout INSTEAD of this file
      hampanelscene: /etc/panel.conf: TRUNCATED -- 1 line(s) are longer than
          the 512-byte line limit and were cut; those directives are NOT what
          the file says

  `tests/linux/de_panel_conf_shipped.sh`, **14 PASS**, offscreen, ~40 s. The
  measurement is the file's own colour reaching the bar (81% of both bar
  strips are `#d4d0c8`, 0% are the fallback's `#eceef2`) — pixels, never a log
  line, because the panel logged `config reload applied: 2 panel(s)` all the
  way through the defect. Assertion 8 is the one that refuses a bigger fixed
  buffer: the same directives behind a **65,010-byte** comment header must
  still reach the bar, so a fix that moved 2048 → 8192 passes the headline
  assertion and fails that one. Assertion 9 covers the live re-read (edit only
  the `color` lines, all past byte 2834, and the bar must repaint). With the
  fix reverted — `git checkout d965f155 -- user/hampanelscene.ad`, actually
  run — **7 PASS / 7 FAIL**, headed by *"with etc/panel.conf verbatim in place
  the bars are 0% / 0% of #d4d0c8"*.

  `de_panel_conf_replace.sh` **can now use the real file, and does**: it used
  to write the shipped file's two `panel … end` blocks out by hand without the
  header, precisely because a verbatim copy was never parsed. It now copies
  `etc/panel.conf` byte for byte (and its one-panel variant is the same file
  with the second block sed-deleted, so there is no second hand-maintained
  copy of the layout either). Still **17 PASS**.

  The same audit found the **write** side of that file was worse than the read
  side: `_save_config` serializes at most `50 + MAX_PANELS(4) * (81 +
  MAX_WIDGETS(12) * 106 + 4)` = **5478 bytes** into an `Array[2048]`, and while
  `_sb_emit` clamped, the bare `_save_buf[p] = 10` newline stores and the
  `_u64_to_dec` calls did not — `p` climbed past the array, a BSS overrun
  rather than a truncation. That bound IS compile-time (unlike the read side),
  so a fixed buffer is the right shape there; it is now `SAVE_CAP` 8192 with
  every store bounds-checked, and a serialization that reaches the cap is
  refused by name rather than written. Gate assertion 10 proves the maximal
  panel set the bound is computed from is a reachable config.

  `etc/panel.conf`'s CONTENT is unchanged, so the channel's byte-compare of
  shared `/etc` files is unaffected and no new binary ships.

* ~~**THE SAME DEFECT, IN FOUR MORE SHIPPED `/etc` FILES.**~~ **ALL FIVE ARE
  NOW FIXED.** Items 1-2 were done with the panel; items 3-5 are done now —
  see *THE BOOT RC, THE SERVICE FILE AND THE DISTRIBUTION TABLE* below for
  what each one cost and what proves it. The list is kept in full because the
  measurements are the record of what the class looked like:

  1. ~~**`/etc/hpm/trusted.pub` — 718 bytes, read through 512.**~~ **FIXED.**
     Reader: `user/hpm.ad` `_set_trusted_key_path()`, which read through
     `tkey_file_buf` (512, `while total < 512`). The 64-hex key token begins
     at **byte 653**, past the ceiling, so the read captured only the 11-line
     comment header and `hpm --trusted-key=/etc/hpm/trusted.pub` died with
     *"malformed trusted-key file (want 64 hex chars)"* on a perfectly
     well-formed file. **Rotating the trust root through the shipped,
     documented mechanism was impossible.**
  2. ~~**`/etc/hpm/local-trusted.pub` — 1054 bytes, same 512-byte reader**~~,
     key token at byte 989. **FIXED with it.** Same failure, twice the margin.
  3. ~~**`/etc/rc.boot` — 15918 bytes into a 16384-byte ceiling (97.2% full).**~~
     **FIXED.**
     `user/hamsh.ad` `_run_rc_path()` (`:17872`, read loop `:17886`,
     `rc_buf` 16384): on overflow the loop **just breaks, with no diagnostic
     of any kind**. 467 more bytes — one added comment paragraph — cuts the
     file's last line, which is `source /etc/rc.boot.full`, so the entire
     boot recipe would silently never run and the box would come up on the
     cpio fallback looking fine. Same ceiling, same silence:
     `etc/rc.de-user.linux` 13267 B (81%), `etc/install.hamsh` 12850 B (78%),
     `etc/rc.boot.full` 12255 B (75%, via `builtin_source`'s `src_buf`).
  4. ~~**`/etc/services.d/hamde.svc` — 3186 bytes into 4096 (78%).**~~
     **FIXED — and the write-back really did destroy the file; it was
     reproduced before it was fixed.**
     `user/hamsh.ad:14914` `_svc_read_def_file()`, `svc_def_buf`
     (`SVC_DEF_BUF_MAX` 4096) — and `_svc_persist_enabled` (`:14232`)
     **re-writes the file from that same buffer**, so an `enable`/`disable`
     on an over-4K def would destroy the tail of the file on disk.
  5. ~~**`/etc/distros` (from `etc/distros.linux`, 1426 B) — a SINGLE unlooped
     `sys_read(fd, &_dm_buf[0], 2047)`**~~ **FIXED.** At
     `user/hampanelscene.ad` `_load_distros()`. Only 621 bytes of headroom,
     and with no accumulate loop a short read truncates at any size. The rows
     are at the END of the file behind **1336 bytes** of header (measured by
     the gate), so a truncation drops the distributions out of the
     Applications menu — silently.

  Cleared in the same sweep (no finding): `etc/passwd`/`shadow`/`group`
  (readers all ≥4096 or line-based), `etc/man/*.md` and `etc/motd` (already
  stream), `etc/hpm/channels` (16 KiB cap), the `.desktop` files (max 266 B
  into 2047), and a long tail of files under `etc/` that are shipped and
  documented but have **no reader anywhere in the tree** (`etc/services`,
  `etc/protocols`, `etc/hosts`, `etc/fstab`, `etc/inittab`, `etc/os-release`,
  … — and `etc/desktop.icons`, whose own header already admits it).

* ~~**THE BOOT RC, THE SERVICE FILE AND THE DISTRIBUTION TABLE.**~~ **FIXED —
  all three, and one of them was not a read bug at all.**

  Items 3-5 of the sweep above, in the order they matter.

  **`/etc/rc.boot` is PID 1's script and it was at 97.2% of its buffer, with a
  bare `break` for an overflow path.** 467 bytes — one added comment
  paragraph — would have cut the file's last line, which is `source
  /etc/rc.boot.full` (line 303 of 304), and the machine would have booted on
  the cpio fallback, reached a console, and looked entirely fine having run
  half its boot recipe. The same shell had two more of the identical shape:
  `builtin_source`'s `src_buf` (16 KiB; `/etc/rc.boot.full` 12255 B, 75%) and
  `_svc_read_def_file`'s `svc_def_buf` (4 KiB).

  **The size was not raised. It was removed.** `_script_load` reads a script
  into a 16 KiB static stage and, if it does not fit, replays it into an
  anonymous mapping that DOUBLES until the whole file is in hand. A 15 KiB rc
  costs exactly what it cost before and calls no `mmap` at all — which matters
  because this is PID 1 before anything else exists — and a 300 KiB rc runs.
  There are three stages, one per nesting role (boot rc / `source` / `.svc`),
  because sourcing nests: `rc.boot` is live in stage 0 when it sources
  `rc.boot.full` into stage 1. A fourth level of nesting takes the mapped path
  instead of corrupting a shared buffer, which the two 16 KiB buffers it
  replaces could do to each other.

  **What replaces the ceiling is a LOUD REFUSAL, not a bigger ceiling.** The
  loader returns NOTHING — never a prefix — names the file and the byte count,
  and every caller declines to run:

      hamsh: /etc/rc.boot: CANNOT BE READ WHOLE -- 1048576 byte(s) read and no
          memory for the rest.
      hamsh: /etc/rc.boot: NOT RUN -- none of it took effect. Half a script is
          not a script: the cut lands mid-statement, so running the part that
          fitted would be a different program than the file you wrote.

  `_run_rc_path` gains return code 4 for it and `main()` answers 4 exactly as
  it answers 3 (did-not-lex): PID 1 says THE BOOT RC DID NOT RUN and lands in
  the RESCUE SHELL rather than panicking; anyone else exits non-zero.

  **THE ONE BOUND LEFT is named rather than hidden: `TOK_MAX`, 4096 tokens for
  one lex input, and a line costs one.** It is kept precisely because it is
  LOUD — overrunning it is a lexical error, so nothing runs, the file is
  named, and PID 1 says RESCUE SHELL. `etc/rc.boot` is ~900 tokens. The gate
  asserts that loudness rather than leaving it to be rediscovered.

  **`/etc/services.d/*.svc` WAS NOT A READ BUG. `svc enable` DELETED THE
  FILE.** Verified before it was fixed, because "reads it wrong" and "eats it"
  are different bugs. `_svc_persist_enabled` read through the 4 KiB buffer and
  then `sys_open_write`'d THE SAME PATH — which truncates — and re-emitted the
  file out of that buffer. On a 5088-byte definition, with the pre-fix binary:

      size before=5088 after=4098   (lost 990 bytes)
      tail marker still present: 0
      uid: line still present:   0
      last line: `# doc line 0040 yyyyyyyyyyyyyyyyyyyyyyyyybenabled: yes`

  990 bytes deleted, a real `uid: 1234` directive gone, and — because the cut
  landed mid-line — the fresh flag welded onto the tail of a COMMENT, where
  the parser (which ends a line at the first `#`) cannot see it. **It ate the
  file AND failed to persist the enable it ate the file for.** Exit status 0,
  nothing printed. The shipped `hamde.svc` is 3186 bytes: eleven documented
  lines from an `enable` that eats its own tail. Now: the whole file or
  nothing; if it cannot be held whole the rewrite is REFUSED out loud (a
  truncating write is far worse than an unpersisted flag); the `enabled:` line
  is replaced IN PLACE rather than dropped and re-appended; and a file whose
  last line has no newline no longer makes the writer read one byte past the
  buffer. There is no `rename(2)` in either runtime, so the truncate-then-
  write window is not atomic and the source says so rather than implying it
  away.

  **`/etc/distros` was two defects in one line** — the 2047-byte ceiling AND
  a single unlooped `read(2)`, which truncates at any size because a short
  read is legal from a pipe, a fifo, a slow device or a 9P mount. Streamed
  now, a row at a time, through `_cfg_chunk`; the panel always says what it
  read (`[panel] /etc/distros: 1426 byte(s), 29 line(s), 0 attached
  distribution(s)`), and a row past the 512-byte line bound is reported and
  NOT parsed — half a name is a different distribution.

  **GATES.** `tests/linux/scripts_read_whole.sh` — **23 PASS**, ~9 min, two VM
  boots. A LADDER (20 KB, 64 KB, 256 KB, 1 MiB, 4 MiB, each with a marker on
  both sides of the padding) so no raised constant can satisfy it; the
  `ulimit -v` arm that takes the memory away and requires the refusal by name,
  a non-zero exit, and **not even the first line having run**; the `svc
  enable` fixture; and **A REAL BOOT** whose `/etc/rc.boot` is the tree's own
  `etc/rc.boot.linux` with 200 KB of padding before its last statement —
  **209,540 bytes through PID 1's reader** — asserting that the far side of
  the padding RAN and that the graphical runlevel past it started. With
  `user/hamsh.ad` reverted to `7ff7cd21` and rebuilt: **6 PASS / 17 FAIL**,
  and section 4 fails in exactly the shape the fix exists for —

      ok   (4.1) the machine booted and the FIRST half of its rc ran
      FAIL (4.2) THE TAIL OF /etc/rc.boot NEVER RAN. The machine booted
                 anyway, which is the whole danger
      FAIL (4.3) the rc's last statement (the graphical runlevel) left no trace
      ok   (4.6) no kernel panic
      ok   (4.7) and the console still answers a typed command

  — a booted machine, a live console, no panic, no diagnostic, half a boot.

  `tests/linux/de_distros_table.sh` — **10 PASS**, ~1 min, no compositor and
  no VM: it drives the menu-model build through `hampanelscene --scene-dump`
  in a private mount namespace **whose `/etc` is its own** (the host's is
  bind-mounted aside and symlinked back, so only `/etc/distros` is the
  fixture). The shipped file verbatim; the same file behind a 65 KB and then a
  300 KB header (a 2047 → 8192 fix passes the first assertion and fails
  these); **the table delivered through a FIFO by one writer that pauses
  mid-file**, so the first `read(2)` really does return only the header — the
  half no buffer size fixes; a 900-character row; and no file at all. With
  `user/hampanelscene.ad` reverted: **5 PASS / 5 FAIL**, the 66,946- and
  308,626-byte tables parsing **0 rows** and the fifo one parsing 0.

  `de_panel_conf_shipped.sh` is still **15 PASS** (the distribution parse now
  shares `_cfg_chunk` with the config parse; the two never run inside one
  another), and `gates_are_private.sh` is 3 PASS with the new gate counted
  among the isolated.

* ~~**THE TRUST ROOT COULD NOT BE ROTATED.**~~ **FIXED — `--trusted-key` now
  streams, and every refusal names the file.**

  `hpm --trusted-key=<path>` is the documented mechanism for overriding the
  compiled-in Ed25519 key that authenticates every package this distribution
  installs. It read the file into `tkey_file_buf: Array[512, uint8]`. Both
  files the tree SHIPS for that purpose are mostly the comment header that
  documents the format:

  | file | size | key token at byte |
  |--|--|--|
  | `etc/hpm/trusted.pub` | 718 | 653 |
  | `etc/hpm/local-trusted.pub` | 1054 | 989 |

  So the whole read landed inside the header and both died with *"malformed
  trusted-key file"* on well-formed files. The one reason a trust root has an
  override is that it might have to be REPLACED; on that day the documented
  path did not work.

  **Same shape as the panel fix, for the same reason.** A bigger fixed buffer
  is the same defect at a larger size and this tree has four scars from it
  (2047-byte panel config, this 512-byte key buffer, 8192-byte `/etc/modules`,
  a `tail` that read the first 8 KiB). `_set_trusted_key_path` now reads
  **4 KiB chunks and parses a line at a time** — no whole-file buffer, no size
  ceiling. The only bound left is ONE LINE (512 bytes; the token is 64
  characters), and a truncated line is never parsed at all, because half a
  token is not a token. The token is decoded into scratch and copied into
  `trusted_pub` only once 32 whole bytes are in hand; it used to decode
  straight into the live trust root, which left it half-overwritten whenever
  the token turned out to be bad.

  **And every failure is loud and names the file.** Silently falling back to
  the compiled-in root is the worst outcome available here — the operator asks
  for key A, gets key B, and installs under a root they believe they replaced:

      hpm: --trusted-key /etc/hpm/trusted.pub: cannot open it. NOT falling
          back to the built-in trust root -- the key you asked for is the key
          that must be used.
      hpm: --trusted-key K: no key in it -- read 400 byte(s) over 7 line(s) to
          end of file and found no bare 64-hex token. NOT falling back ...
      hpm: --trusted-key K: line 1 is not an Ed25519 public key -- want
          exactly 64 hex characters, this token is 8. NOT falling back ...
      hpm: --trusted-key K: 1 line(s) are longer than the 512-byte line limit
          and were NOT parsed -- a key on one of them was not read.

  all rc=1. Success is loud too (`hpm: trust root taken from <path> (718
  bytes, 12 lines)`), because an override of the thing that authenticates
  every package should not happen silently. The usage text also claimed the
  root was "(built-in, or --trusted-key / **/etc/hpm/trusted.pub**)", implying
  that file is consulted automatically. It is not and never was — the root is
  compiled in precisely so it cannot be swapped by editing a file. Reworded.

  `tests/linux/hpm_trusted_key_file.sh`, **28 PASS**, host-side, loopback,
  ~1 min, in a private mount namespace (it runs `hpm`, which writes
  `/tmp/hpm/index-<uid>.json`). The positive is proved three ways: both
  shipped files are read verbatim AND the key read out of them is USED (an
  index they do not vouch for is refused as `signature INVALID`); a key behind
  `etc/hpm/trusted.pub`'s own 653-byte header verifies, refreshes and
  **installs a package onto disk**; and `etc/hpm/local-trusted.pub` — the one
  shipped root whose secret is in the tree (`scripts/hpm_local_key.seed`) — is
  proved byte-for-byte with no substitution at all, while `trusted.pub`
  refuses that same index. Assertion 6 refuses a bigger fixed buffer: the same
  key behind a **68,555-byte** comment header must still verify, so 512 → 8192
  passes the headline assertions and fails that one. The negatives (missing,
  empty, comment-only, truncated to 400 bytes, 8-char token, non-hex token,
  900-char line) each require the message to NAME THE FILE, rc≠0, and nothing
  refreshed. The live `https://255.one/linux/index.json` is fetched, verified
  against `etc/hpm/trusted.pub`, served back from loopback and refreshed **with
  no flags** under the compiled-in root, with one flipped byte still caught —
  nothing is published, two GETs. Assertion 2 pins the compiled-in constants
  to the shipped files' bytes, so a rotation that edits one and not the other
  fails. With the fix reverted (`git checkout <pre-fix> -- user/hpm.ad`,
  actually run) — **11 PASS / 17 FAIL**, every failure carrying
  *"hpm: malformed trusted-key file (want 64 hex chars)"*.

  `tests/linux/hpm_index_sig.sh` re-run after the change: **7 PASS, 0 FAIL**.

  **What this did NOT change, and is worth knowing:** `hpm install` does not
  re-verify the index signature — it reads the per-user cache
  `/tmp/hpm/index-<uid>.json` that the last good `refresh` wrote and checks
  each tarball's sha256 against it. That is apt's model (`refresh` is where the
  trust decision is made) and the cache being per-user rather than a shared
  world-writable file is what makes it safe. The gate clears the cache before
  asking whether an untrusted package installs, and prints the cache behaviour
  as an INFO line so its green is never read as a claim that `install`
  re-checks the signature.

* ~~**A package install hook could wedge `hpm update` forever.**~~ **BOUNDED
  NOW, IN THE PARENT — but read "what this cannot help" below before believing
  it is closed.**

  hamnix-drivers-base 1.0.13 shipped an install hook containing `put in front
  of the machine's table`. The apostrophe closed the single-quoted string,
  `hamsh` hit an unterminated quote, and the runaway token swallowed the rest
  of the file **including the `\nexit\n` that `hpm` appends to every hook
  wrapper as its safety net**. The spawned shell reached its interactive REPL
  on a stdin nobody was feeding, and **`hpm update` never returned** — measured
  on a real installed machine. The modules extracted, the dependency table was
  never merged, and the machine sat wedged mid-update with no timeout and no
  diagnostic.

  `scripts/hamlinux_packages.py`'s `write_pkg` already refuses to publish a
  hook with an odd number of single quotes on any non-comment line. **That
  closes it from the publishing side only.** A hook from a third-party channel,
  a hand-written package, or the next generator bug of a different shape still
  reaches `_run_hook` — and a hook that hangs for a reason that has nothing to
  do with quoting (an infinite loop, a read from a network, a wait on a device)
  was never covered by a lexer rule at all.

  **The defect was in the PARENT: `hpm` waited forever on a process it
  spawned.** Two changes in `user/hpm.ad`'s `_run_hook`, and nothing else:

  1. **The hook's stdin is `/dev/null`.** An install hook has no business
     reading standard input, and with stdin at EOF a `hamsh` that reaches its
     REPL reads EOF on its first poll and exits — so the `exit` net holds even
     when the `exit` was swallowed, for a hook of ANY origin. **Measured, not
     assumed**, because that assumption is the whole bug one level down: on the
     exact runaway-quote wrapper, stdin on an open-but-silent pipe reaches
     `[hamsh:stage-07] loop-enter` and never returns; the same wrapper with
     stdin at `/dev/null` reaches the same line and exits in under a second.
     `sys_read_nb` reports true end-of-input as `-1` (`user/linux-syscalls.c`
     says so in as many words), which is exactly hamsh's `el == -1` EOF arm.
  2. **The wait is bounded** — 60 s, then a kill note, then a *bounded* reap.
     Where 60 comes from, measured with the tree's own `gzip` and `hamsh`: the
     slowest hook this distribution actually ships is a driver package that
     gunzips a ~10 MiB module (0.088 s) and appends its `/etc/modules` and
     `modules.dep` lines (0.033 s for 500 appends, more than any shipped hook
     has). 60 s is ~500× that. It bounds a **wedge**, not a performance budget.
     On expiry `hpm` does not go quiet: it names the hook, names the package,
     says the files are on disk and the hook did not finish, and fails the
     install. And it does not trade one unbounded wait for another — an
     unreapable corpse is reported, not waited on.

  Gated by **`tests/linux/hpm_hook_bounded.sh` — 10 PASS / 0 FAIL**, 85 s, no
  VM. It reproduces **the actual hang** first (assertion 1: the runaway-quote
  wrapper on an open stdin, killed at 8 s having reached the REPL), proves
  hamsh exits on EOF (assertion 2), then installs three fixture packages from a
  `file://` repository inside a user+mount+pid namespace: the runaway-quote
  hook, a hook that lexes perfectly and blocks forever in `open(2)` on a fifo
  with no writer, and an ordinary hook as the control. Every invocation has its
  own timeout, because a test for a hang that itself hangs teaches nobody
  anything. **With `_run_hook` reverted it is 5 PASS / 5 FAIL**, assertion 5
  reading `hpm STILL HANGS on the runaway-quote hook (killed at 45 s) -- this
  is the original bug`.

  One thing that gate had to learn the hard way and is worth carrying: **it
  gives `hpm` a stdin that is open and silent**, from a fifo held open
  read-write on fd 9. Run from a harness whose stdin is already at EOF, the
  runaway-quote install terminates *with or without the fix* — measured, as a
  green assertion 5 against fully reverted code. An installed machine's `hpm`
  inherits an open console; a gate that does not reproduce that cannot fail.

  **WHAT THIS CANNOT HELP, PLAINLY.** A machine that already installed a broken
  `hpm` runs the **old** `hpm` when it updates. This change cannot rescue a
  machine that is already wedged, and it cannot rescue a machine that takes the
  next bad hook *before* it takes this `hpm`. It protects machines from the
  hook **after** the one that carries it, and nothing else.

* ~~**OPEN QUESTION: should a lexical error be FATAL to `hamsh` when it sources
  a script?**~~ **DECIDED AND DONE. YES — and PID 1 still gets a shell.**

  It used to be a printed line and nothing else, so `hamsh <script>` exited 0
  for a script of which **nothing had run**, and `hpm` printed
  `installed hooktest-quote@1.0.0` for a package whose hook did nothing. A
  sourced file is ONE logical input to `lex_line`: a runaway quote on line 3
  swallows the rest of the file, the parser is never reached, and not even the
  lines *before* the bad quote execute. That is not a partial run; it is no
  run at all, and answering it with 0 is the success-shaped answer NORTH_STAR
  names.

  **A lexical error is now fatal to the script it is in.** `hamsh` names the
  file and **the line the construct OPENED on** (an unterminated quote is only
  *detected* at end of file, which is not the interesting place), says
  `NOT RUN -- a script whose text cannot be lexed is not executed at all`, and
  exits non-zero. `_run_rc_path` has a new return code 3 for it.

  **What each CALLER does with that non-zero is where the availability
  decision actually lives**, and that is what made this its own decision:

  - `hpm` needed no new policy — a non-zero hook exit was already an install
    failure. It now says the consequence out loud as well as the exit code:
    `lexfixture-quote is NOT correctly installed: its files were unpacked but
    its install.hamsh did not succeed`. No `installed <pkg>` line, non-zero
    exit, and the package never reaches `installed.json`.
  - **PID 1 does NOT die on it.** `hamsh` *is* PID 1 (linuxinit execs it), so
    there is no parent left to catch an exit and an exit is a kernel panic. It
    asks `sys_getpid()` in exactly one place, prints a rescue banner naming the
    file and line, and falls through to the console REPL it already falls into.
    **Measured in a real boot**, not argued: an image whose `/etc/rc.boot`
    carries the field's own apostrophe prints
    `hamsh: /etc/rc.boot:4: lexical error: a quote opened here is never closed`
    followed by `PID 1: ... in a RESCUE SHELL on the console`, and then
    `echo` and `cat /version` typed at the serial console both answer. No
    panic. Before this change the same machine reached the same shell **saying
    almost nothing** — one unnamed `hamsh: lexical error` line, no file, no
    line number, no statement that the rc had not run — which is why the arm
    exists even though the fall-through itself is not new.

  The invariant: **a lex failure is never silent, never reported as success,
  and never costs you the machine.**

  Gated by **`tests/linux/lex_error_fatal.sh` — 17 PASS / 0 FAIL**, both halves
  in one file, the second one a real QEMU boot of an image staged from the
  tree. **With `user/hamsh.ad` and `user/hpm.ad` reverted to their parent
  commit it is 8 PASS / 9 FAIL** — 1/2/3 (hamsh hangs on an open stdin, names
  nothing), 6/7/8/9 (`hpm: installed lexfixture-quote@1.0.0`, and the name goes
  into `installed.json`), 11/12 (the booted machine's whole account of its
  unreadable rc is one `hamsh: lexical error (unterminated quote or token-limit
  exceeded)`). **13–16 pass BOTH ways, and that is the point**: falling through
  to the console shell is not new behaviour, so nothing here costs a machine.
  Like the hook gate it hands `hamsh` and `hpm` an **open, silent stdin**
  (a pipe with a live writer that never writes; a held-open fifo on fd 9),
  because a harness at EOF grants the fix for free. It also matches the
  console's answers as **whole lines after ANSI stripping** — hamsh's line
  editor echoes what is typed at it, so a substring match would go green on the
  echo of a command the shell never ran.

  **FOUND WHILE DOING IT, AND IT IS THE SOFT-GREEN SHAPE AGAIN:**
  `tests/linux/hpm_hook_bounded.sh`'s assertions 1 and 2 were measuring
  nothing. Its fixture wrote the runaway-quote wrapper to
  `dirname(out)/../quote.exec` — which lands in `$R` — while both assertions
  open `$W/quote.exec`. **hamsh was handed a file that did not exist**, said
  `boot rc ... not found`, fell into its REPL, and hung on an open stdin /
  exited on `/dev/null` exactly as the real wrapper would have. Both went
  green for years of runs without the bad quote ever being lexed. It surfaced
  only because the new diagnostic was *missing* from output that claimed to be
  about it. Fixed: the fixture takes `$W` as an argument, assertion 1 now
  refuses a `not found` as evidence and asserts the new behaviour (report and
  exit non-zero, never a hang), and assertion 2 uses a well-formed hook with
  no `exit` — because a script that does not lex no longer reaches the REPL at
  all, so it can no longer be the thing that proves the REPL exits on EOF.
  Still 10 PASS, now for the stated reasons.

* ~~**One unbounded wait is deliberately left standing: `_spawn_adder_cc`.**~~
  **BOUNDED NOW, same shape as the hook wait.** `user/hpm.ad`'s on-box compile
  polls `sys_waitpid_jc` against a deadline, kills on expiry, bounds the reap,
  and on expiry names the source file it was compiling and says the package is
  NOT installed; its stdin is `/dev/null` for the same reason a hook's is. **The bound is 15 minutes and it is measured, not
  argued**: `host_ac` on `user/hamUId.ad` — 31,217 lines, the largest Adder
  program in the tree — takes **0.80 s**, and **8.9 s** for the whole
  compile+link. 15 min is ~100× that, so it bounds a wedge without being a
  performance budget. It is not covered by a gate of its own: reproducing a
  compiler that hangs needs a fixture source package with a wedging compiler
  behind `/bin/adder_cc`, which is a bigger job than the change, and it is
  named here rather than pretended about.

  Two more things `tests/linux/hpm_hook_bounded.sh` measured on the way, both
  in `hamsh` and neither touched here: a counting loop exhausts the value arena
  after 16384 live cells (`hamsh: uncaught exception: value arena exhausted
  (VAL_MAX=16384 live cells) — split the loop`), so an accidentally infinite
  hamsh loop self-terminates rather than spinning — which is why the gate's
  "hangs for another reason" fixture blocks in `open(2)` on a fifo instead.

* **FOUND WHILE FIXING THE ABOVE, NOT FIXED: a hook longer than 16 KiB is
  SILENTLY TRUNCATED, and the cut can land inside a quote.**

  `hamsh`'s `rc_buf` is `Array[16384]` and `_run_rc_path` stops reading there;
  `hpm`'s `hook_body_buf` is the same 16384. Measured: a 37,895-byte script of
  500 `echo '...' >> '...'` lines ran **217 of them** and then hit the severed
  tail (`ec0`) as a command, exiting 127. Nothing anywhere said "truncated".
  This matters because the generated driver hooks *are* one line per module and
  one line per dependency edge — `scripts/hamlinux_packages.py`'s
  `module_install_hook` — so a large enough driver package produces exactly
  this. And if the 16,384th byte falls inside a single-quoted string, the
  truncation **manufactures the unterminated quote by itself**, from a hook the
  generator's odd-quote check would have passed. Two separate fixes are wanted:
  hamsh should refuse (loudly) rather than truncate, and the hook path should
  not have a 16 KiB ceiling at all.

* ~~**`tail FILE` wedges the shell.**~~ **FIXED. `tail` NEVER OPENED THE FILE.**
  It looked at `argv[1]` only far enough to see whether it began with `-` and
  then read **stdin** whatever the arguments said, so on a console -- where
  stdin is a terminal that never reaches EOF -- `tail /lib/modules/<release>/
  modules.dep` waited forever on the keyboard while appearing to be busy with
  the file. `cat` was fine because `cat` opens its operands. **There was no
  backwards-seek loop, no unsigned counter wrapping and no stalled scan: the
  hang was an omission, not an infinite loop**, which is why it was invisible
  in the source at a glance. Reproduced ON THE HOST in seconds, no VM
  involved: `tail` built through the Linux lane, stdin a fifo held open with
  nothing on it, `rc=124` under a 10-second `timeout`.

  **THE HANG HAD A SILENT TWIN AND IT IS THE WORSE HALF.** With stdin already
  at EOF -- every script, every `rc` file, every non-interactive invocation --
  the identical bug printed **nothing and exited 0**. Anything testing `tail`
  the way `/etc/rc.boot` tests `cat` would have believed the file was empty.
  That arm is asserted separately in the gate, because a gate that only
  proved termination would have passed against it.

  This is **byte-for-byte the bug `head` had**, found by
  `tests/linux/installed_update.sh` and fixed then (`user/head.ad`'s header
  tells the story); `tail` was simply never given the same treatment. `head`
  is run as the control in the new gate and is green in both arms -- that
  difference is the whole diagnosis: one file got the fix and its twin did
  not.

  **A SECOND, QUIETER WRONG ANSWER WAS FOUND UNDERNEATH IT.** The old `tail`
  slurped the **first** 8 KiB of its input and tailed *that*, so on any input
  over 8 KiB it returned promptly with the WRONG LINES and said nothing --
  `tail huge` gave line 190 of 40,000 where GNU gives line 40,000. Returning
  fast is not a fix; the gate diffs the bytes against GNU `tail`, never merely
  the exit. `tail` now keeps a 64 KiB **trailing** ring (forward reads only --
  no backwards seek to get stuck at offset 0), and on a seekable input longer
  than the window it `lseek`s to `size - 65536` first, so a gigabyte log costs
  one seek and one window. `lseek` reporting size 0 is deliberately NOT
  believed to mean "empty" -- procfs says 0 for files that read back kilobytes
  -- so those take the streaming path. And when the requested lines genuinely
  cannot fit (one line larger than the window) the leading fragment is
  **dropped rather than printed as though it were a whole line**, stderr names
  the file, and the exit is 1.

  Gated by **`tests/linux/tail_file.sh` -- 31 PASS / 0 FAIL**, 2.6 s, no
  VM, every invocation under `timeout` because a test for a hang that itself
  hangs teaches nobody anything. Twenty-three of the assertions are diffs
  against GNU `tail` on the same argv: the real `modules.dep`, with and
  without a trailing newline, one line with no newline, a lone newline, an
  empty file, fewer lines than the default of 10 and more, `-0`/`-1`/`-99`,
  40 KB and 300 KB inputs, several FILEs with the `==> NAME <==` banner, a
  pipe, and `-` as an explicit stdin operand. **With the fix reverted it is
  11 PASS / 20 FAIL**, the fifo arm reading `tail FILE HUNG for 10s -- the
  defect` and sixteen others reading `output differs from GNU tail / ours:`
  followed by nothing at all -- the silent twin, in the transcript, in its own
  words. `tail` was already in `COREUTILS` in `scripts/hamlinux_packages.py`,
  so the channel carries the fix; no new binary was added.

* **`hamnix-desktop` 1.0.10 IS A MIXED BUILD AND A MACHINE THAT TOOK IT LOST
  ITS DESKTOP. RECOVERED — 1.0.11 IS LIVE, AND `hpm update` IS MEASURED TO
  BRING SUCH A MACHINE BACK** (`tests/linux/installed_recover_broken.sh`,
  **34 PASS / 0 FAIL**; the section on it below has the transcript). 1.0.10's
  bytes are STILL SERVED, deliberately — they were not swapped under the same
  version number, because a machine that already believes it has 1.0.10 would
  never fetch a silently corrected one. What follows is the account of the
  defect, and it is kept because the *cause* is the interesting part.

  Measured, on an
  installed disk, by `tests/linux/installed_update_live.sh`: after a bare
  `hpm update` and a reboot there is **no top bar and so no Applications
  button**, and it is not even deterministic — two runs of the same disk gave
  `windows 0` (nothing came up at all) and `windows 2`
  (`2 0 774 1280 26 100 …` the panel's BOTTOM taskbar and
  `3 0 0 1280 800 -1 …` the wallpaper; the top bar simply absent). Reproduced
  offscreen on the host in seconds: swap only
  the published `hampanelscene` into `tests/linux/de_mouse_chrome.sh`
  (`MOUSE_BIN_DIR=`) and the top bar disappears (13 PASS → 2 PASS / 1 FAIL),
  and the framebuffer's top band goes from the panel's `#ecEEf2` to the empty
  composite's `#203348`. The published **`wsysd` is fine** — pointed at it
  alone, that gate is **13/0**, so 1.0.10's compositor really does carry the
  mouse fix. It is the CLIENTS that are stale, and the cause is one line:

  > `scripts/hamlinux_packages.py:build_one` reuses `build/repo-obj/<cmd>.elf`
  > whenever its mtime beats **`user/<cmd>.ad`'s** — and it stats nothing else.
  > Not `lib/*.ad`, not `user/linux-wsys.c`, not the compiler.

  So an edit under `lib/` or to a `user/linux-*.c` backend invalidates NOTHING
  and the previous object is published. The three binaries on 255.one are
  byte-identical to the cached objects still sitting in
  `build/repo-obj`: `hampanelscene.elf` and `hamdesktop.elf` built **18:25**,
  `wsysd.elf` built **19:17**, with `user/linux-wsys.c` — the wsys backend all
  three link — modified at **19:54**. Nothing here has ever RUN those objects:
  every gate in the tree builds from source through `hamlinux_build.sh`, so
  the artefact that actually ships is the one artefact nothing tests.
  `channel_covers_image.sh` cannot see this either — it compares NAMES, and
  every name is present.

* **NO PIPELINE IN THE SYSTEM COULD END. NOW FIXED — `user/linux-fdns.c`.**
  `cat FILE | md5sum` never returned and it cost a whole boot
  (`docs/linux_installed_update.md` §3). It was never md5sum: the same md5sum
  answered two FILE operands correctly one line above. **The end that did not
  finish was the WRITER end, and the writer that never closed was hamsh
  itself.** `sys_pipechan` opens each pipe slot's fifo `O_RDWR` and keeps that
  descriptor, so the terminal's first open cannot deadlock — but `O_RDWR` is a
  writer, and nothing ever closed it. No reader on any pipe could see EOF and
  no writer could see EPIPE; only readers that DRAIN TO EOF (md5sum, wc,
  cksum, sort) could show it. Dropping the keeper is worse and the harness
  says so: the writer then finished before the reader opened, the fifo's open
  count hit zero, the kernel discarded the bytes, and the reader read "EOF
  after 0 bytes" — a silent empty answer. So the keeper has a LIFETIME: the
  slot records whether each REAL end has ever been opened, and
  `fdns_keeper_sweep()` (called from `sys_waitpid` and `sys_read`) closes it
  once both have. Four more faults of the same family fell out of the boot
  that followed, each a `/fd` name that silently resolved to the INHERITED
  descriptor: the **bind table leaked and ran out** (512 records, keyed by a
  pid that only climbs — 36 pipelines in under a second, then a hang for
  ever); the **stale-bind clear raced the child it was cleaning up for** and
  is now done BEFORE the fork, where there is no child to race; **two
  processes could claim the same free record**, now a compare-and-swap; and
  **`wc` ignored its FILE operands** and blocked on stdin, the fourth member
  of the `head`/`cksum`/`md5sum` family. `tests/linux/fdns_pipe.sh` (7 PASS,
  host, seconds) and `tests/linux/pipelines.sh` (**13 PASS**, in a boot).
  `tests/linux/installed_update.sh`'s `md5sum < FILE` workaround is
  `cat FILE | md5sum` again.
  **And the last piece is closed too: `` `{ … }` `` of a BUILTIN is FORKED
  now.** It used to run in-process, so its output went to the shell's own
  console-backed fd 1 — `` `{ echo x } `` printed `x` on the terminal and
  yielded the empty string. It said so by name and the gate asserted that it
  said so, which is honest and still broken. `_run_builtin_in_pipeline` was
  already exactly the machinery required (pin the write end before the fork,
  `RFPROC|RFFDG|RFNAMEG`, child binds the pipe at its own `/fd/1`, `do_wait 0`
  returns a PID), so the capture path now calls it, and the decision is made
  by `_builtin_dispatch_kind_check` — a predicate — instead of by RUNNING the
  verb and asking afterwards. Measured in a boot: `pipegate: bcapture ` with
  a stray `inner` on the console, before; `pipegate: bcapture inner` and no
  console leak, after. The gate asserts both halves, because a capture that
  read the right bytes *while the text was also on the console* would be the
  old bug wearing the new answer. POSIX's consequence comes with it and is
  correct: the builtin runs in a subshell, so `` `{ cd /x } `` does not move
  the shell.

* **A MIXED WAIT SET STILL CAPS AT 20 ms, AND HERE IS WHAT THAT COSTS.**
  `sys_waitfds` cannot put a futex and a `poll(2)` into one syscall, so when a
  caller mixes a `/dev/wsys` ring with an ordinary fd it caps the sleep at
  20 ms and re-runs the poll. The comment in `user/linux-syscalls.c` said
  "nothing in the tree does it today" and that was wrong when it was written:
  `user/hamterm.ad` line 498 hands `lib/hamui.ad`'s `hamui_wait` its
  shell-stdout pipe, so **an open DE terminal is exactly this path** — two
  rings plus one ordinary fd, a 50 ms park turned into 20 + 20 + 10, waking
  ~60 times a second where it needs to wake ~20.
  **Measured, both arms of that inner loop, 20 s each, `/proc/self/stat`
  either side of a fixed wall interval** (not `ps pcpu` — that is a lifetime
  average and has misreported this tree twice): the cap 59.7 wakes/s and
  0.010 s of cpu, **0.050% of one core**; a single poll over the whole set
  20.0 wakes/s and 0.000 s. One wake — a `futex_wait` that times out plus a
  0 ms poll, 200 000 of them back to back — is **3.9 µs**, so the 40 extra
  wakes/s are **0.016% of one core**, for one program, while it is open.
  **The recorded fix is an eventfd mirroring the `inputgen` word**, so the
  whole set goes into one `poll` and the cap disappears. It is the right fix
  and it is deliberately NOT done yet, for a reason worth writing down: the
  write side belongs to the WAKER, `hamwsys_input_notify()` in
  `user/linux-wsys.c`, and the substitute that avoids that file — a
  reader-side helper thread per process futex-waiting and writing an
  eventfd — buys 0.016% of a core and pays a permanent extra thread plus a
  hand-rolled wake protocol **on the keystroke path**, the one whose latency
  was the ~0.5 s echo lag and the one `tests/linux/de_probe.sh` types real
  keys through QEMU to guard. The number is in the code beside the cap so the
  next reader does not have to re-derive it.

* **`user/hello.ad` claimed to prove the VFS path and never once tested it.
  NOW FIXED.** Its header says it opens `/version`, reads it and prints it,
  "so we've proved the VFS path is reachable". Nothing in hamnix-linux ever
  created `/version`, and the read sat behind a bare `if fd >= 0:` with no
  else — so for the whole life of the port the open failed, the read was
  skipped in silence, and the program printed its banner and exited 0. A
  banner is not evidence about a filesystem. `/version` is now a plain file at
  the root of the initramfs, exactly what it is on the Hamnix line
  (`scripts/build_initramfs.py`), with the kernel release and the userland
  revision **derived** rather than asserted; and `hello` reports by name and
  exits 1 when it cannot open it, and again when the open succeeds and the
  read delivers nothing. Before/after through the run sweep: `EXIT_NONZERO`
  with `cannot open /version -- the VFS path this program exists to prove is
  UNPROVEN`, then `RAN` printing
  `hamnix-linux -- Adder userland on Linux 6.12.85+deb13-amd64`.

* **The run sweep's argv column had ONE spelling for a mistake and none for
  the truth. NOW THE OTHER WAY ROUND.** 47 recipes carried a literal `-` in
  the argv column — the STDIN column's sentinel, passed to the program as a
  real argument. It had already been found and fixed three times (`mktemp -`,
  `route -`, `pr -`) by editing the rows and leaving the shape alone, so it
  happened again: most of the GUI clients plus `md5sum`, `more`, `nl`, `od`,
  `rev`, `ps`, `pwd`, `nproc`, `lsmod` and `hamsh`. `md5sum` was being scored
  `EXIT_NONZERO` for it (`md5sum: cannot open -`) and is `RAN` with a real
  digest now. So: no-arguments is spelled `EMPTY` and that is the only
  spelling (all 193 rows that meant it say it), the loader **rejects** a blank
  column and a bare `-` by row name before anything runs, and a row that
  genuinely wants a lone dash writes `%DASH`. A blank column is not merely
  sloppy — it is what a collapsed tab looks like, the bug that once fed `wc`
  its own description.

* **The Hamnix clipboard and the namespace clipboard were two clipboards.
  NOW BRIDGED — `user/xsnarfd.ad`.** `/dev/snarf` is served
  (`user/linux-snarf.c`; `tests/linux/snarf_device.sh` 23/23), so copy and
  paste work between Hamnix programs; a Debian or Alpine binary still gets
  ENOENT on it, the same answer `/dev/wsys` and `/net` give. What was missing
  was the process this list asked for: one that **owns** an X selection and
  mirrors it both ways, reacting to ownership changes on each side. It exists,
  one per distribution, started by the generated `/etc/rc.distros-wl` beside
  that distribution's `wsyswl`, running **outside** the namespace and reaching
  the Xwayland inside it **by name** — `/n/<name>/tmp/.X11-unix/X0`, the same
  inode the namespace calls `/tmp/.X11-unix/X0`, with nothing bound and `/srv`
  still not carried in. `tests/linux/xsnarf_bridge.sh` (25/25, QEMU-free) and
  `tests/linux/xsnarf_ondevice.sh` (8/8 in the VM, where the assertion is a
  **mouse**: a triple-click in a real Debian `xterm` lands in
  `/dev/snarf.primary` out here, and a middle-click feeds what was copied out
  here to the shell that xterm is running). `docs/linux_clipboard.md` §3a–§6.
  What is still open, in that file's §6.5: an **INCR** transfer is refused
  loudly rather than received; a selection over 64 KiB is truncated loudly at
  `SNARF_MAX`; and the Wayland-native `wl_data_device` clipboard is a third one
  and is not bridged. **THE SERIAL IS DONE, and it did not land where the
  request asked.** `struct snarfshm` carries `clip_serial`/`prim_serial`,
  `/dev/snarf.serial` reads them, and its fd is a real `inotify` watch on the
  segment, so `xsnarfd` parks on the clipboard beside the X socket instead of
  polling it: **4.99 → 0.49 idle wakes/s**, sampled from
  `voluntary_ctxt_switches` over a 10 s window, not from `ps` pcpu.
  `tests/linux/snarf_serial.sh` (**17 PASS**, QEMU-free), and with the change
  reverted it is 4 PASS / 13 FAIL. Three corrections to the request as written
  here: the fields are **appended**, not put in the header at line 127 — a
  header field moves `clip[]`/`prim[]` by 8 bytes and `/srv/snarf` is a
  rendezvous between binaries that were not built together, so the v1 prefix is
  `_Static_assert`ed frozen at 131096 and the segment grew to 131120; the bump
  is `__atomic_add_fetch`, not `(*serialp)++`, or two simultaneous copies land
  on one serial and the second becomes invisible; and `version` stays at **1**
  on purpose, because a stamp can only describe the segment while the hazard is
  a live *writer* that predates the serial — so every reader reconciles on a
  timer regardless, and the gate proves that with a `python3` old client that
  mmaps the 131096-byte prefix and stores through it (no `write(2)`, no
  inotify, no bump) and is still converged into the X selection.
  **`lib/wlsnarf.ad` was converted too and the conversion was thrown away**,
  measured: `wsyswl`'s loop runs at 16 ms for the input rings whatever the
  clipboard does, so it saves **no wakes at all** and 12.7–403 µs/s of CPU
  (`tests/linux/wlsnarfbench.ad`, table in the file), while making a
  non-bumping writer 16x slower to notice. That is a bad trade and the number
  is now written next to the code. Two further gaps unchanged: no locking, so
  two simultaneous copies interleave — the serial makes that
  interleaving *noticed*, not prevented; and **no end-to-end mouse test between two DE windows** —
  a drag-select in one pasted into another — because the click derivation was
  never ported from the Hamnix line, where that exact gap once let nine green
  gates sit on a dead feature. (The bridge's own mouse test is the *namespace*
  boundary, not the DE-window one.)
* **The Debian namespace's D-Bus has no SERVICES** (the bus itself now works).
  The namespace's `/run` is on
  the ext4 and survives reboots, so the first boot's `dbus-daemon` left
  `/run/dbus/system_bus_socket` behind and the session's `[ ! -S … ]` guard
  then skipped starting the bus on every boot after; every CEF process logged
  `Connection refused` against it. The stale socket is now detected by pid
  liveness and cleared by name (`tests/linux/hamnix_x11session.sh`).
  **Now fixed and measured:** started as
  `dbus-daemon --system --nofork --print-address &`, the bus comes up,
  `/run/dbus/pid` names a live process, and `dbus-send --system … GetId`
  returns a real reply from inside the namespace. (`dbus-send` IS in the
  image — the comment that said otherwise was wrong.) **And it now comes up
  for the SESSION USER, not only for root** — that was the other half of this,
  and it was blocked by `/run/dbus` being root-owned, not by anything about
  dbus: see the fourth-fault entry below. What remains absent are
  SERVICES on the bus, which CEF names itself:
  `org.freedesktop.UPower … was not provided by any .service files`.
* **One thing is still Debian-shaped. Two were, and are not any more.**
  (1) **DONE — the DE application menu carries N distributions.**
  `user/hampanelscene.ad` no longer holds a literal
  `/n/linux/usr/share/applications` and one "Linux" section: the scan is driven
  by `/etc/distros`, one section per distribution actually attached under `/n`,
  named after it. Screenshots:
  `docs/screenshots/linux/distro-menu-{debian,alpine}.png`; gate
  `tests/linux/distro_menu.sh`, which drives the menu open with synthetic
  pointer events and reads the panel's DISPLAY LIST back per fly-out (Debian's
  `Install Steam` must be drawn under the first section and NOT under the
  second — one list drawn twice would pass a screenshot and fails this).
  Making a dead path live found four things that were already broken and said
  nothing: the boot rc bound the distributions AFTER starting the panel that
  scans them; the Applications button was pointed at `/bin/hamappmenu`, which
  this line does not build, so it spawned a missing program and printed a
  launch; `sub_open` is one global while `menu_open` is per panel, so the
  bottom taskbar closed the top panel's fly-out on any pointer event; and
  Alpine's only `.desktop` file is `NoDisplay=true`, so its section could only
  ever have been empty. `docs/linux_distro_namespaces.md` §8.
  (2) **DONE, and `user/install.ad` was the wrong file.** `.hamnix-roots` is
  read by the HAMNIX KERNEL; nothing on this line reads it — `#sysroot` is a
  device from the command line and `bind` mounts it. An installed
  hamnix-linux disk gets its distributions from the same two labelled
  filesystems the live boot uses, so it needed no second subtree and no
  sentinel line. What it needed was for `etc/rc.boot.installed` to do what the
  live rc does, and that file had **no distribution bind and no `ns clean { }`
  template in it at all**: `enter debian { sh }` on an installed system
  answered `not a namespace template`. The subsystem worked on every boot that
  is thrown away and none that persist. Both rcs now `source` a generated
  `/etc/rc.distros`; `HAMLINUX_DISK_RC` gives an installed disk the hook it
  never had, which is why it was the one boot never under test. Gate:
  `tests/linux/installed_distros.sh`, 12 PASS — UEFI boot of a real installed
  disk, both namespaces, both uids, negative control.
  `docs/linux_distro_namespaces.md` §9.
  (3) `tests/linux/hamnix_x11session.sh` is Debian's session script; Alpine's
  is a separate one baked into its image, and the two share their two
  hardest-won lines by copy. Worth merging when there is a third.
  `docs/linux_distro_namespaces.md` §7.
* **The NATIVE build lane links again — 278/278, 0 undefined — but two of the
  six entry points it got are honest −1s.** `scripts/build_user.sh` used to
  fail at `ld` for `cp`, `hpm`, `insmod`, `modprobe`, `rmmod`, `uname`,
  `nice_hi` and `nice_lo`. Six symbols had been added to the HOSTED runtime
  (`user/linux-syscalls.c`) to fix real bugs on this line and never got a
  native counterpart; `user/runtime.S` now carries them, written against the
  frozen reference at `~/Hamnix`. Four are real: **`sys_chmod`** over Plan 9
  `wstat(5)` (`SYS_WSTAT` 266 → `vfs_chmod`, persisted on ext4, documented
  no-op success on tmpfs/cpio); **`sys_init_module`** over `SYS_INIT_MODULE`
  (175), with a stat/mmap/read adapter in the runtime because that kernel has
  only the old `(image, size, params)` shape and Linux grew `finit_module(2)`;
  **`sys_delete_module`** over `SYS_DELETE_MODULE` (176), which unloads by
  SLOT ID, so an all-digits name decodes and anything else is −1 rather than
  unloading whatever slot a pointer's value landed on; and
  **`get`/`setpriority`** over `SYS_NICE` (311), self-only, so any target
  other than `(PRIO_PROCESS, 0)` is −1 rather than a re-nice that never
  happened. Two are −1 **because that is the true answer**: `sys_uname` (that
  kernel has no utsname anywhere in its number space — `user/uname.ad`'s
  existing arm prints `Hamnix`, which is shorter than the hosted lane's line
  and every byte of it is true), and **`sys_stat_mode`**, which is the one to
  know about. `SYS_STAT_P9`'s Dir record *has* a mode field, but every stat
  hook in `sys/src/9/port/sysfile.ad` hard-codes it — 0644 for a file,
  `DMDIR|0755` for a directory — including `_stat_hook_ext4`, which does it
  while holding the inode whose real `i_mode` it just read. A confident 0644
  would make `cp /bin/hamsh /n/disk/bin/hamsh` chmod the destination
  NON-EXECUTABLE; native Hamnix enforces no exec bit and would not notice, and
  the ext4 image it just wrote is the one THIS line boots — the "Attempted to
  kill init" panic, re-created from the other side. So `cp` carries no mode on
  that kernel, because that kernel has no mode to carry. **Untested on the
  native target: this repository has no Hamnix kernel in it and cannot boot
  one.** Verified only to assemble and link. Remaining lane divergence, in
  full: eleven hosted `sys_*` (`sys_unix_listen`/`_accept`/`_connect`,
  `sys_scm_send`/`_recv`, `sys_memfd`, `sys_mmap_shared`, `sys_munmap_at`,
  `sys_fd_size`, `sys_getenv`, `sys_open3`) plus `getenv`, all of them AF_UNIX
  / SCM_RIGHTS / memfd / environ mechanisms declared only by
  `user/wsyswl.ad`, `user/wsysd.ad`, `user/xsnarfd.ad` and one Linux-ABI test
  — programs `scripts/build_user.sh` does not build at all.

* **SUPERSEDED — THE GPU BACKEND HAS NOW BEEN MEASURED ON A REAL GPU, and the
  claim below that "on this machine it cannot be" was FALSE THE WHOLE TIME.**
  The desktop runs on the HOST offscreen (`HAMFB_FILE`), not only in a VM, so
  `/dev/nvidiactl` was always reachable beside the owner's running session —
  no reboot, no `modeset=1`, no VM. What made it look impossible was
  `vk_icd_survey.sh` printing `CPU-ONLY` about a for-loop that skipped
  `nvidia_icd.json` (see the running list). With the owner's consent:
  **RTX 3090, driver 550.163.01, `VK_ICD_FILENAMES=…/nvidia_icd.json
  scripts/bench_vk_linux_device.sh`, byte-identical at all 26 lever settings.**
  The findings, in `docs/vk_linux_backend.md` § *Measured on real silicon*:
  - **The DE does not use this backend today and never has on a shipped
    image** — one ICD is staged and it is venus
    (`hamlinux_image.sh:789`), venus enumerates nothing here, and `vk_arm`
    disarms on a CPU ICD by design. So this was always "do not switch yet",
    never "we shipped something slow".
  - The DE+text frame's **33 ms was 428 µs of GPU and 32.1 ms of our own CPU**
    reading the mapped Vulkan buffer back across the bus. Fixed (28×,
    byte-identical): **1,166 µs, and 3.8× FASTER than the software
    rasterizer** where it had measured 7.4× slower.
  - **All three "device-independent levers" quoted below are refuted on
    hardware.** Dispatch count moves this frame 2.6% (per-dispatch cost is
    **528 ns** here, not lavapipe's 17,700). `staged_words` is
    anti-correlated: 8.7× MORE staging was 41× faster. Arena residency
    (`HAMNIX_VK_ARENA_DEVLOCAL=1`, new) made it 5× WORSE — which is what named
    the cause, because the cost tracked how far the **CPU's read** travelled.
  - New gate: a **host-overhead ceiling** (wall ≤ 10× the device's own clock).
    The bug sat at 76.4×; a CPU ICD passes it trivially, which is why
    `test_vk_linux.sh` could never have caught it.

  The rest of this bullet is kept as written for the history of how the wall
  was believed. It is no longer the state.

  ~~**The GPU backend has never been measured on a real GPU, and on this
  machine it cannot be.**~~ It is proven correct and proven to install; every
  microsecond quoted anywhere is lavapipe's, where it is 2.3–2.9× *slower*
  than the hand-tuned software rasterizer, which is why the default is gated
  on the device being silicon. What is now *established* rather than assumed
  (`docs/vk_linux_backend.md`, "What could be measured on this host"): venus
  is blocked because `nvidia_drm` registered **no connector nodes** in
  `/sys/class/drm` — `modeset=0` seen from userspace, no root needed, so the
  recorded hypothesis is evidence; **no** other ICD on this host finds a
  device (all seven asked, with `/dev/dri` masked by a tmpfs so the host GPU
  was provably never opened); and a plain `virtio-gpu` VM was booted and
  measured to have a real DRM device, the venus ICD, and **zero** Vulkan
  devices. QEMU 10.0.8 here has no `rutabaga` backend, so there is no headless
  path to a guest Vulkan device that does not go through the host's
  `/dev/dri`. What it takes: a machine with a non-blocked GPU, or this one
  rebooted with `nvidia-drm.modeset=1` — **the owner's call, do not ask**.
  The one command on that day is
  `VK_ICD_FILENAMES=<real>.json scripts/bench_vk_linux_device.sh`.
  Meanwhile the *levers* were measured, which is the part that transfers:
  dispatch count predicts (17.7 µs each on lavapipe), `staged_words` predicts
  nothing while the frame is host-visible, and "fewer dispatches is faster" is
  refuted as a rule — on the fills frame the shipped batching is 20% slower
  than one dispatch per op, because a batch pads its grid to the max over its
  entries.
* **AND THE ATTACK THAT WALKED THROUGH THAT FIX: `/proc/<pid>/mem`. CLOSED, from
  two sides.** The entry below moved a window's keystrokes out of the shared
  segment, so the snooper reads nothing out of the table. The VICTIM still has
  them, and on Linux one process reads another of the **same uid** out of
  `/proc/<pid>/mem` with **no ptrace call, no stop and nothing to notice**. The
  chain is two steps long, because the table must stay world-readable for the
  taskbar and it hands over `pid=`:

      snoop -> pid=1234 -> open(/proc/1234/mem) -> `1 PASSWORD31337`

  It is driven as **attack 5 of 5** in `tests/linux/wsys_bypass.sh` (`peek` mode
  in `wsys_bypass.c`), and with the fix reverted it reads
  `found=1 mem=3 maps=4 secret=1 enumerable=1 ptrace=0` — the victim's password,
  read out of its address space.
  **(1) `prctl(PR_SET_DUMPABLE, 0)` IN EVERY WINDOW OWNER.** `owner_harden()` in
  `user/linux-wsys.c`, called from `keychan_bind` — the ONE place a process
  becomes the recipient of a window's keystrokes, on both the `newwindow` path
  and the lazy bind, so no future window-owning program can forget it. Measured
  against a real owner: `mem=-13 maps=-13 secret=0 enumerable=0 ptrace=-1`.
  **IT COSTS** core dumps from every window owner and same-uid `gdb -p` /
  `strace -p` / `perf -p` against a live DE client; launching a client UNDER a
  debugger still works. `HAMWSYS_DUMPABLE=1` opts out and says on stderr that it
  did. `/proc/<pid>/stat` and `/proc/<pid>/cmdline` are NOT ptrace-gated, so
  `ps`, the panel and this file's own `owns_wid` parent-pid walk are unaffected —
  checked before it landed.
  **(2) `kernel.yama.ptrace_scope=1`, SET IN `user/linuxinit.ad` AS PID 1**, the
  instant `/proc` exists. Debian's and Ubuntu's default, so not a novel policy: a
  non-ancestor same-uid attach is refused and a debugger still debugs anything it
  launched itself. **Yama IS on this kernel** — the image ships the build host's
  newest `/boot/vmlinuz-*`, which is the kernel the host is running, and
  `/proc/sys/kernel/yama/ptrace_scope` exists on it. **It is READ BACK**, and
  absent-Yama, unwritable-knob and write-did-not-take are three different
  messages naming three different causes.
  **NEITHER IS SUFFICIENT ALONE**: Yama is a boot setting a person can turn off
  and an `lsm=` line can omit, and it does not gate `/proc/<pid>/mem` at all;
  `PR_SET_DUMPABLE` is core kernel and always there, but only covers processes
  that opt in.
  **THE GATE:** `tests/linux/ptrace_scope_boot.sh`, **6 ok**, a REAL BOOT —
  ptrace_scope is not namespaced, so no unprivileged harness can measure the set
  state on the dev host. Its positive control is the same probe run on the dev
  host (scope 0, sibling attach **SUCCEEDS**). Reverted `linuxinit.ad`:
  **PASS 3 / FAIL 3**, with `uid=1001 scope=0 dumpable=1 attach=0` inside the
  boot. `wsys_bypass.sh` **42 ok → 47 ok**.
  **THE GATES LIED THREE TIMES BEFORE THEY TOLD THE TRUTH**, and every one was
  caught by running the reverted case rather than reasoning about it. (a) `peek`
  scanned only ANONYMOUS writable regions on the reasoning that a keystroke
  buffer is heap or stack — it is not, `wsys_uidgate.ad` reads into a top-level
  BSS array and a small `.bss` sits inside the binary's own **file-backed** `rw-`
  mapping, so the scrape skipped the one page the password was on and printed
  `secret=0` **on the reverted run**. (b) The boot probe ran from `rc.boot`, i.e.
  as **root**, which holds `CAP_SYS_PTRACE` and which Yama never restricts:
  `uid=0 scope=1 attach=0`, a successful attach on a correctly configured
  machine. (c) After the probe dropped to uid 1001, the uid change **cleared the
  dumpable flag** (`suid_dumpable` is 0), so the attach was refused by the
  dumpable check and the **reverted** run printed `attach=-1` and PASSED. All
  three are now asserted against by name: every writable region is scanned, a
  `uid=0` line is refused, and a refusal against a non-dumpable target is a VOID
  measurement rather than a pass.
  **WHAT IS STILL OPEN AFTERWARDS**, unchanged by any of this: SCRAPE another
  window's committed scene and backbuffer out of the 0666 table, ENUMERATE every
  row, and CORRUPT any of it. That is THE SPLIT's tier 2 remainder and it needs
  the tier-1 authority — a daemon, a new binary, a package-channel change and a
  segment at a new path — not another pass over this file.
  **THAT LAST SENTENCE WAS WRONG ABOUT THE SCENE, AND THE NEXT ENTRY IS WHY.**
  It needed no daemon, no new binary and no new path.

* **THE PIXEL HAND-UP: a window's v1 DISPLAY LIST is not in the shared segment
  either, and it needed NO TIER-1 AUTHORITY — which is the finding, not the
  feature.** SCRAPE's scene half is closed. A uid-1001 process could open
  `/srv/wsys` `O_RDONLY`, map it `PROT_READ` and read another window's committed
  display list, and that is not a picture but TEXT: the scene grammar's `glyphs`
  op carries the string it draws, so scraping a terminal's scene is reading its
  screen letter for letter, with no write and nothing for the victim to notice.
  Measured, on the reverted run: `scene=[rect 0 0 40 20 0x334455]` out of a
  uid-1001 victim's row. Each window's scene and stage now live in a per-window
  **memfd its OWNER creates**; `win[].scene`/`stage` are dead storage and
  `struct wwin` is byte-for-byte what 6 and 7 had.
  **WHY A MEMFD IS ALLOWED TO BE THE ANSWER NOW.** The recorded design was
  disproved by measurement — `/proc/<pid>/fd/<n>` IS a path — and what changed
  since is the machine, not the argument: `PR_SET_DUMPABLE(0)` in every window
  owner and `kernel.yama.ptrace_scope=1` from PID 1, against which the same
  probe measures `open=-13` and `ptrace=-1`.
  **AND WHY IT NEEDED NO AUTHORITY, which is the part that transfers.** Every
  one of THE SPLIT's three blockers follows from the authority CREATING the
  memfd and handing it DOWN, which needs the recipient proved to be the window's
  owner — and the only ownership record is `win[].pid`, in the 0666 table, which
  is exactly why THE SPLIT rules that shape unsound. **Handing UP needs no
  ownership record at all**: `memfd_create` is unprivileged, the bytes start in
  the one process definitionally entitled to them, and the only question left is
  who ELSE may have them. The kernel answers it. So: no attach rewrite (the
  client still mmaps the one named file and additionally makes a memfd, and both
  compositorless gates still run), no new binary and no package-channel change
  (the code is in `user/linux-wsys.c`, which every wsys program already links),
  and no field removed (`struct wwin` frozen, no new path, no old binary
  memsetting a live table). Same three blockers, same escape, second time.
  **THE SENDER CHECKS, AND THAT IS NOT THE KEYSTROKE CHANNEL'S RULE COPIED.**
  The rendezvous is an abstract `AF_UNIX` `SOCK_SEQPACKET` listener the
  compositor binds. An abstract name has no mode, so a *receiver-checks*
  construction — which is CORRECT for keystrokes — would here let a uid-1001
  attacker bind first and be handed every client's display list: strictly worse
  than the hole being closed, reached by copying a construction that is right in
  the other direction. Which end holds the secret decides which end checks. The
  client `connect`s, reads `SO_PEERCRED` for the listener, and passes the
  descriptor only if the kernel says it is the segment's owner. Nothing reads
  `win[].pid`. The memfd is sealed `F_SEAL_SHRINK|GROW|SEAL` before it is ever
  passed, and the receiver re-checks the seals — a receiver that maps a file the
  sender can shrink takes SIGBUS, and the receiver here paints the whole screen.
  **ON THE PARK, AND THAT TOOK FOUR TRIES — every one of them a signal
  delivered to something that had stopped listening, and every one found by ONE
  gate.** `tests/linux/wsys_image.sh` is the only gate whose client **draws once
  and stops**: `hamimgscene` uploads its photograph, commits, parks. Every other
  gate's client keeps drawing, so every other gate was **green over three
  defects stacked on each other** while the screen was empty.
  *(a)* A commit COUNT was the first draft, and a window sitting still never
  commits again — so a compositor that started late or restarted would leave it
  blank for ever. Replaced by a clock: every owned window offered every 500 ms
  while unheld, re-announced every 3 s, gated on one vDSO `clock_gettime`.
  *(b)* But driving that clock **from wsys calls covers a client that is drawing
  and misses the one that has stopped** — a parked application makes no wsys
  call again, and `wsysd` only binds the rendezvous when it first reads a
  foreign scene, which needs a window to exist, so late binding is the ORDINARY
  case. `sys_waitfds` is where every such program is: not somewhere convenient,
  the one call a client doing nothing at all still makes (`hamwsys_tick`).
  *(c)* **AND THE TWO SIDES DEADLOCKED.** `wsysd` repaints when the frame
  signature moves, reads a scene only when it repaints, and drained the listener
  only when it read a scene — so a descriptor arriving after the frame in which
  the window was refused is never accepted, nothing changes, nothing repaints,
  nothing drains. Measured: the client's second hand-up **connected and
  succeeded** and the compositor never accepted it. The park breaks the cycle
  because the park is the one thing both sides do while idle.
  *(d)* **And then the counter bumped was not the one anybody watches.**
  `shm->gen++` on install moved a number `user/wsysd.ad`'s `frame_signature()`
  does not hash — it is an FNV over the WINDOWS (geometry, z, title,
  `scene_gen`, `bbgen`, `imggen`) and `shm->gen` is not in it at all. It is the
  ROW's `scene_gen`, which is also right on its meaning: the row was advertising
  a frame that could not be fetched and now advertises one that can.
  **AND THE OTHER THING ONE GATE CAUGHT: a v2 window NEVER COMMITS A SCENE.**
  It renders its own surface and submits blits, so its scene read has always
  been a 0-byte success — and the hand-up turned that into a named refusal,
  which `paint_window` bails on (`if (n < 0) return 0`) **before it ever reaches
  `paint_backbuffer`**. Every browser, video and rootless X client would have
  stopped being painted by a confidentiality change to a path none of them use.
  A refusal is now reserved for the case that really is one: a window that HAS
  published a frame (`scene_gen > 0`) this process cannot fetch.
  **`WSYS_VERSION` 7 → 8**, the second bump where the layouts agree completely
  and only the MEANING differs. **What it costs a running desktop is now "the
  new program fails", not "the desktop dies"**: A LIVE SESSION IS NOT A LEFTOVER
  shipped in v7, so a v8 binary meeting a live v7 session refuses to attach and
  changes nothing — and `scripts/hamlinux_packages.py`'s `hpm update` warning
  **was rewritten because it had become FALSE**: it still told the person their
  desktop was about to empty, and what actually happens now is that their
  windows survive and nothing new opens until they reboot. Telling someone the
  wrong true-shaped thing is the same class of error as telling them nothing.
  **WHAT AN ATTACKER CAN STILL DO**, and the first one decides which windows
  this protects: **the v2 BACKBUFFER is untouched**. `/srv/wsys.bb` is a third
  0666 mapping holding every v2 window's pixels, and a v2 window is what a
  browser, a video and a rootless Xwayland are — so **a hamUI application's
  screen contents are private on this machine and FIREFOX'S ARE NOT**, and
  nothing about looking at the two windows says which is which. The named images
  (`/srv/wsys.img`) likewise. Both are left because they are a POOL rewrite —
  shared slots, page-mapped on demand, centrally accounted in a header every
  client reads — and not a change of where a pointer points. ENUMERATION is
  unchanged and unfixable while `/dev/wsys/windows` is the taskbar's input.
  CORRUPTION is not closed and is not made worse: an attacker can no longer
  write another window's display list, but it can still take the listener's name
  and it can still retitle, move, hide and destroy any row — integrity needs
  tier 1 and always did. And **DENIAL OF SERVICE BY NAME-SQUATTING**: a same-uid
  attacker that binds the rendezvous before `wsysd` makes `wsysd`'s bind
  `EADDRINUSE` and no v1 window is painted at all. Loud, both on stderr and on
  the screen, and the same trade the keystroke channel made — but the blast
  radius is bigger, one window there and every v1 window here.
  **THE GATES.** `tests/linux/wsys_bypass.sh` **47 ok → 60 ok**. Two controls
  are **INVERTED, not deleted**: attack 2's bypasser still opens the 0666 table
  read/write, still maps it `PROT_WRITE` and still searches it — those
  assertions must keep passing — and now asserts the display list is NOT there
  and that a scribble never reaches the protocol; `snoop` still reads
  `scene_len` and the scene bytes at the same offsets, so `scenelen=0 scene=[]`
  is a measurement and not an absent one. A NEW attack, `pixgrab`, is driven
  from BOTH uids under the rule `keysend` established — a refusal with no
  matching success proves only that the address was wrong:
  `sameuid.pixgrab uid=1001 bound=1 fds=0` against
  `hostowner.pixgrab uid=0 bound=1 gotwid=2 scenelen=24 scene=[rect 0 0 40 20
  0x334455] fds=2`. The attacker CAN take the name and not one client hands it
  anything, and the client says so BY NAME on stderr. A NEW positive control,
  `bbscrape`, scrapes the v2 backbuffer store on every green run so the open
  half cannot be believed shut — and it is exact about what it proves: this gate
  drives no v2 client, so its `found=0` means nothing blitted, not that the
  store is private. **With `user/linux-wsys.c` reverted it is 52 PASS / 8 FAIL**,
  including `sameuid.snoop` printing the victim's committed scene and
  `hostowner.pixgrab` coming back `fds=0` — the assertion that catches a fix
  whose refusal was only ever an unreachable address.
  **AND THE GATE'S OWN ISOLATION BUG, found by needing the backbuffer store to
  exist**: `HAMWSYS_BB` was never set, so `bb_attach` fell past the unwritable
  `/srv` to the HOST's `/dev/shm/hamnix-wsys-bb` — this gate created an 8.5 GB
  sparse segment outside its own temp directory on every run, and its
  `rm -f "$HAMWSYS".bb` removed a file nothing had ever made.
  Green with it: `wsys_uidgate`, `wsys_keychan`, `wsys_write_census` 10,
  `wsys_title` **29**, `wsys_image` **8**, `wsys_keyed` 8, `wsys_cover` 7,
  `de_mouse_chrome` 13, `de_focus_dismiss` 14, `wsys_desktop_z` 12,
  `de_icons_distinct` 15, `de_appmenu_brisk` 17, `de_idle_cpu` 9,
  `wsyswl_conn_ceiling` 30, `wsyswl_ceiling` 11, `wsyswl_rootless` 37.
  **THE END-TO-END PROOF IS THE PIXEL GATES, NOT THE BYPASS GATE.**
  `wsys_title`'s 29 and `wsyswl_ceiling`'s 36 painted windows are counts of
  framebuffer pixels downstream of a display list that now arrives over this
  channel; they are what would go red if the hand-up did not work, and
  `wsys_bypass.sh` would not. And all of those except `wsys_image` are ALSO
  green on the reverted library — they are regression guards, not evidence for
  the change, and the evidence for the change is `hostowner.pixgrab`'s
  `fds=2` against the reverted run's `fds=0`.
  `tests/linux/channel_covers_image.sh` was NOT run: it needs
  `build/image/root`, which this worktree has never built, and this pass adds no
  binary and changes no package file list (only the hamnix-desktop hook's
  message text), so it has nothing here to catch. Run it before publishing.

* **THE KEYLOGGER IS CLOSED: a window's keystrokes are not in the shared
  segment any more.** This was the whole of attack 4 — a uid-1001 process opened
  `/srv/wsys` `O_RDONLY`, mapped it `PROT_READ` and read a uid-1001 victim's
  typing out of its `keys` ring without moving `r` or `w`, so the victim received
  every keystroke normally and could not tell. No file mode could close it: the
  table must stay world-READABLE because `/dev/wsys/windows` is the panel
  taskbar's input. **The bytes left the mapping.** A window's keystrokes now
  travel as datagrams to a per-window ABSTRACT `AF_UNIX` address that the OWNER
  binds at `newwindow`, and the ring in `struct wwin` is dead storage.
  **THE RECORDED FIX WAS WRONG, AND IT WAS MEASURED BEFORE IT WAS BUILT ON.**
  THE SPLIT's tier 2 said "a memfd has no name in the filesystem, so there is no
  path for a bypasser to open ... the only construction that closes attack 4".
  **`/proc/<pid>/fd/<n>` is a path**, it is openable by any process of the same
  uid, and same-uid is the entire threat model — measured: `open=3`, `mmap
  PROT_READ`, `1 PASSWORD31337` read straight back out of the victim's memfd.
  Built as recorded, tier 2 would have moved the keylogger one directory deeper
  and called it shut. A socket has the property the memfd was believed to have:
  a socket inode **cannot be opened through `/proc` at all** (ENXIO), so the only
  way to receive what is sent to a bound address is to BE the process that bound
  it. It is also what NORTH_STAR asks for in as many words — *what crosses a
  process boundary is a NAME or a NUMBER, never a descriptor* — where
  `SCM_RIGHTS` is exactly a descriptor.
  **WHO MAY DELIVER A KEYSTROKE IS THE KERNEL'S ANSWER, not a field in a
  world-writable table.** Abstract sockets have no mode and the name is derived
  from public facts (the segment's `st_dev`/`st_ino` and the wid), so anybody can
  address one. The RECEIVER drops every datagram the kernel did not stamp
  (`SO_PASSCRED`/`SCM_CREDENTIALS`) with the segment owner's uid — root on a real
  boot. **That closes attack 3 for this ring as well, against a SAME-UID
  attacker**, which is the case no file mode can reach. Nothing in the path reads
  `win[].pid`, which is why this is not the "title-only RPC" THE SPLIT rules out
  as unsound: the spoofable ownership record is not consulted at all.
  **FIRST BINDER WINS AND A LOSER FAILS LOUDLY.** `bind` on a taken abstract name
  is `EADDRINUSE` and there is no unlink, so the owner's claim cannot be taken
  from it — but an attacker may pre-bind future wids, since `next_wid` is
  readable. Then `newwindow` FAILS BY NAME on stderr and no window is created: a
  silent keylogger becomes a loud denial of service, and denial of service by a
  same-uid process was already free (residue (c): anyone may exhaust the table).
  **`WSYS_VERSION` 6 → 7**, and this is the first bump where `struct wshm` and
  `struct wwin` are BYTE-FOR-BYTE unchanged and only the MEANING differs — which
  is precisely the case the counter exists for. A v6 binary in a v7 session would
  find a well-formed table, write a keystroke into the dead ring and deliver it
  to nobody, and a v6 client would park on that ring for ever reporting no
  keyboard: a silent half-share. It re-initialises instead, which costs the
  previous session's windows — loud — and is what a live `hpm update` of the
  window system has always meant. **No new binary and no package-channel
  change**: the channel is code in `user/linux-wsys.c`, which every wsys program
  already links.
  **WHAT AN ATTACKER CAN STILL DO**, named rather than left to be found: SCRAPE
  another window's committed scene and backbuffer, ENUMERATE every row's wid,
  pid, geometry and title, and CORRUPT any of it — attacks 1 and 2 are untouched
  and their positive controls still pass. One ring of five moved, and it is the
  one that carries passwords. `pointer`/`event`/`text`/`cmd` are unchanged; the
  mechanism is one call per ring away if that judgement ever stops holding.
  **AND THE ONE NOTHING IN USERLAND CAN CLOSE — SINCE TAKEN, see the entry
  above.** `/proc/sys/kernel/yama/ptrace_scope` is **0** on the dev host and was
  set NOWHERE in this tree, so a same-uid attacker could `PTRACE_ATTACH` the
  victim and read its memory directly — past this, past a memfd, past anything.
  It is now `1`, set by `user/linuxinit.ad` as PID 1 and read back, and
  `PR_SET_DUMPABLE(0)` is applied in every window owner. The dev host is
  deliberately left at 0: it is somebody's working machine, and the setting is
  measured in a real boot instead (`tests/linux/ptrace_scope_boot.sh`).
  **THE GATES.** `tests/linux/wsys_bypass.sh` is **42 ok** (now **47** — see the
  entry above), and the three
  controls that closed are **INVERTED, not deleted** — the snooper still runs
  unchanged, still maps the table read-only, still finds the row and still
  scrapes the scene, and now asserts the password is NOT there. It drives a new
  attack too (`keysend`), from BOTH uids, because a refusal with no matching
  success proves only that the address was wrong. Reverted to the pre-change
  library it is **33 ok / 8 FAIL**. `tests/linux/wsys_keychan.sh` (**17 ok**, no
  VM, seconds) is the memfd finding and the kernel facts, kept as a measurement.
  **THE GATE CAUGHT ITSELF, twice, and both were the same shape.** The victim now
  drains its own ring — it has to, since only the owner can receive — and a drain
  is DESTRUCTIVE: with the witness draining every 100 ms the snooper had nothing
  left to read, and the gate went **GREEN ON THE REVERTED RUN**, reporting that
  the keystrokes were not in the mapping about a hole that was wide open. The
  holders now read nothing until the harness sets a drain flag, after every
  attack has been driven. Two orderings had the same defect: one reader was
  consuming the answer to another assertion's question. And the *first* reverted
  run was not a revert at all — `git stash push` on an already-committed change
  stashes nothing and exits happy.
  **`tests/linux/input_probe.sh` changed shape rather than being weakened**: it
  drove real evdev records through `wsysd` and then asked a SEPARATE process what
  had been routed to wid 2. That question has no honest answer from a stranger
  now, so the window's OWNER reports its own keys and the pointer reader is
  unchanged. It is the end-to-end proof the desktop still works: real evdev →
  `route_key` → datagram → the owner's socket, `KEY_A` arriving as ASCII 97.
  Green with it: `wsys_uidgate`, `wsys_title` 23, `wsys_keyed` 8,
  `de_mouse_chrome` 13, `de_focus_dismiss` 14, `wsys_desktop_z` 12,
  `wsys_close_button` 10, `wlsnarf_bridge` 35, `wsys_write_census` 10,
  `wsyswl_conn_ceiling` 27, `wsyswl_wheel` 16 (the documented `distro.ext4` skip),
  and `de_idle_cpu` ALL PASS with a terminal open — which is the one that would
  have caught a park turned into a spin.

* **The wsys window table is still world-writable, though the chrome is not.**
  `/dev/wsys` was one 0666 segment, so a program that mmapped `/srv/wsys`
  directly bypassed the uid gate entirely — measured: as uid 1001 it
  overwrote the `lock` chrome sink and the protocol read the new value back.
  The chrome now lives in a second segment, `/srv/wsys.chrome`, 0644 and owned
  by the host owner, so the same program is refused by the KERNEL (`open`
  `O_RDWR` → EACCES, no `PROT_WRITE|MAP_SHARED`, `mprotect` refused) while
  still reading it PROT_READ, which is what keeps the session sighted.
  `tests/linux/wsys_bypass.sh`. What remains open is the window table, which
  must stay 0666 or an unprivileged client cannot map its own window: a
  bypasser can still retitle another client's window or scribble its scene.
  **AND A FOURTH ATTACK, WHICH NEEDS NO WRITE AT ALL, so no file mode and no
  write-side authority can close it.** (ITS KEYSTROKE HALF IS NOW CLOSED — see
  the entry above; what follows is the finding as it stood, and the scene and the
  row still leak exactly as described.) The three attacks the gate already drove
  are integrity and each needs `PROT_WRITE`; the table must also stay
  world-*readable*, because `/dev/wsys/windows` is the panel taskbar's input.
  That alone is enough: measured, a uid-1001 process opens the table
  `O_RDONLY`, maps it `PROT_READ`, and **reads a uid-1001 victim's KEYSTROKES
  out of its `keys` ring** — the bytes between `r` and `w`, without moving
  either, so the victim receives everything normally and cannot tell — plus its
  committed scene and its whole row. `wsys_bypass.sh`'s attack 4 of 4 (`snoop`),
  35 ok. This kills the cheapest fix anyone proposes after reading THE SPLIT:
  one table at 0644 with every write behind an authenticated RPC closes 1–3 and
  leaves a keylogger between the terminal and the browser.
* **The RPC authority is affordable — the hot path was never the blocker, and
  that had been an argument, not a measurement.** THE SPLIT said the fix was
  left because a round trip per frame and per keystroke would put `wsysd` on
  every client's path. `tests/linux/wsys_write_census.sh` counts every mutation
  of both segments at the one choke point all of them pass through, off a real
  offscreen desktop (`wsysd` + `hamdesktop` + `hampanelscene`, synthetic evdev
  mouse). **A whole session — bring-up, ten idle seconds, twelve under a mouse
  — makes FIFTEEN lifecycle writes in TOTAL** (3 `newwindow`, 6 `geometry`, 5
  attribute, 1 `focus`) against 771 per-frame ones; **435:1 while the mouse
  moves, and ZERO lifecycle writes on an idle desktop.** The instrument is off
  unless `$HAMWSYS_WRSTAT` names a directory (asserted, not promised) and
  counts into a `MAP_SHARED` file rather than flushing at exit, because every
  process that matters here is killed with a signal. 10 PASS. **The gate caught
  itself**: on the required reverted run its first draft came back *7 passed, 0
  failed* with every counter empty — 0/0 took a "no lifecycle writes" sentinel
  and reported 999999:1 — so three assertions now check the denominator before
  anything is concluded from it. Reverted: 6 passed, 4 failed.
  **THE BOUNDARY IS RECORDED FIELD BY FIELD** in THE SPLIT: tier 1 a public
  index at a NEW path, 0644, written only by `wsysd` after `SO_PEERCRED`; tier 2
  per-window `memfd`s passed over `SCM_RIGHTS` at create time for scene, rings,
  backbuffer and images (a memfd has no path, which is the only construction
  that closes attack 4); tier 3 the chrome segment unchanged. What stays open
  afterwards is named there too — enumeration, a client spoofing its OWN
  window, and row exhaustion. **Still not built**, and the surviving blockers
  are not performance: tier 2 is an attach rewrite (two gates, `wsys_uidgate.sh`
  and `wsys_bypass.sh`, prove what they prove by running a client with no
  compositor alive), a root daemon is a new binary and therefore a
  package-channel change, and the layout change REMOVES fields so this file's
  append-and-freeze rule cannot apply — the table must move to a new path or an
  old binary meeting a new segment memsets a running session's window table,
  which `hpm update` of half the desktop makes an ordinary event.
* **FIXED, AND IN THE API RATHER THAN IN THE FOUR CALLERS: a caller's
  `dst_cap` is now a cap on the BODY, and the header block is `http9`'s
  problem.** The defect was that `http9.http_get` took ONE buffer covering
  status line + headers + body and returned `-6` — discarding the status — the
  moment the response reached it, so the correctness of every caller's buffer
  size was a question about a number the caller cannot see: the SERVER's
  header block. That is what made `hpm` unable to fetch a 129-byte signature
  behind 640 bytes of CDN headers into a 512-byte buffer for the whole life of
  the repository, and report it as "unsigned repo". **Four callers each sizing
  a buffer correctly is four chances to get it wrong again**, so the head now
  lands in `http9`'s own 16 KiB buffer (`http_header_bytes()` /
  `http_header_len()` / `http_response_header()`), the body lands at `dst[0]`,
  and `http_get`/`http_post` lose their `out_body_off` parameter. **The status
  is never lost**: `*out_status` is set as soon as the head parses, INCLUDING
  on `-6`, so a caller sized for a resource can still tell a 404 that arrived
  as a 9 KB HTML page from a dead connection. A body that EXACTLY fills
  `dst_cap` is a complete body (the old test was `total >= dst_cap` and failed
  that too). New `-10` names an over-16-KiB response head as the SERVER fault
  it is.

  **What the audit actually found, measured rather than read.** `curl` and
  `wget` were **not** broken at the `hpm` edge — a 129-byte resource behind a
  642-byte header block fetched fine, because their caps were 1 MiB — and they
  were broken at the other end of the same equation: **anything from about a
  megabyte up died as `curl: transport error fetching URL`, exit 7, naming
  neither the status nor the size and indistinguishable from the network being
  down.** Measured against a 642-byte-header server, the wall was a
  **1047929-byte body**; `wget` of a package tarball, which is what a person
  runs `wget` for, is exactly the case. Both now carry 8 MiB body caps, fetch
  3 MB whole, and when something genuinely does not fit they say so **by size
  and by HTTP status** (`curl` exit 23, `wget` exit 9 with the word
  INCOMPLETE) and still write what did arrive. `hambrowse` fetched images and
  stylesheets at 262144 and a script `fetch()` at 131072 covering headers +
  body; those caps are now about the resource, and its JS transport
  reassembles head + body for the engine out of `http9`'s head buffer.

  `tests/linux/http9_response_cap.sh` — 29 PASS, host-side, QEMU-free, over
  byte-for-byte unchanged `http9`/`net9` linked to the `/net` host shim.
  **Its step 0 is a REFUSAL**: it measures the server's header block and exits
  1 below 600 bytes, because python's `http.server` sends 203 and every case
  in the file would then pass on the pre-fix code — which is exactly how this
  survived. Proved to fail on the pre-fix binaries: five assertions flip, and
  the obvious small-response case passes in both arms.
  `tests/linux/http9_chatty_server.py` is the padding server. It also gates
  the ORIGINAL incident against the live repo, because no local server can be
  trusted to imitate a CDN forever — GitHub Pages' header block measured
  **668** bytes on the day this landed, not the 640 recorded when the bug was
  found, and **DuckDuckGo's is 3080**: three kilobytes that used to come out
  of whatever buffer the caller had brought.
    `https://255.one/linux/index.json.sig` cap=512 → `RC=0 STATUS=200 BODYLEN=129`
    `https://255.one/main/index.json.sig`  cap=512 → `RC=-6 STATUS=404`
  The first is the fetch that could not be made for the life of the
  repository; the second is a channel that genuinely has no signature, still
  legible as a 404 through a buffer far too small for its error page.

  `hpm` did not regress: `tests/linux/hpm_index_sig.sh` **7 PASS**,
  `tests/linux/hpm_signed_refresh.sh` **9 PASS** against the live 255.one
  (98 packages, install + run, no flags). That second gate did report one
  failure, and it was the gate: hamsh echoes the rc script it runs, comments
  and all, and its own comment says "an unsigned repo", which its `nocheck`
  then matched on a run where `hpm` had said nothing of the kind. Fixed to
  read guest output only — **a test failing on its own source text is the same
  class of error as a program answering something success-shaped.**

  One piece of this could not be gated where it lives. `hambrowse`'s JS
  `fetch()` hands the engine the response as it came off the wire, so with the
  head in `http9`'s buffer something must put it back in front of the body —
  an OVERLAPPING shift, and one that runs the wrong way smears the tail while
  leaving the length right. Written inside `hambrowse.ad` it would only ever
  execute inside a VM, and **the on-device gate cannot be built in this
  worktree**: `scripts/build_user.sh` fails 8 programs for want of `sys_chmod`
  / `sys_stat_mode` at link (`user/cp.ad`, `user/hpm.ad`, `insmod`, `modprobe`,
  `rmmod`, `uname`, `nice_hi`, `nice_lo`) when the native lane takes over from
  LLVM — seven of them untouched by any of this, so it is the lane and not the
  change, but it does mean `tests/linux/hambrowse_fetch_ondevice` and its
  siblings come back INCONCLUSIVE here. The shift therefore moved into
  `http9.http_prepend_head`, where a host probe reaches it: the gate captures
  the body's last 16 bytes BEFORE the shift and compares them after
  (`TAILMATCH=1`), so a backwards copy done forwards fails in the gate instead
  of in someone's browser.

* **THE SOFTWARE MIXER IS PORTED. Two programs make a sound at the same time,
  and the capture carries both.** An ALSA hardware substream has one writer, so
  the mixer lives in the device server: `/srv/audio` is a `MAP_SHARED` mix ring
  standing in for `hda.ad`'s DMA buffer, every writer SUMS into it just ahead of
  the play cursor with its own cursor, and a detached PUMP process owns the one
  substream and moves the ring into it a period at a time — paced by the
  blocking `write(2)` the way the DMA engine is paced by the hardware, and
  handing the card SILENCE for a starved period, which is what stops a stalled
  writer stalling anyone else. It parks in a futex with the card closed when
  nothing is playing (it must give the card back — THE IDLE CENSUS — and must
  not exit, because an orphan under this PID 1 is a zombie). Summing SATURATES
  rather than scaling, for `mixer.ad`'s reason: halving to buy headroom makes
  the common case 12 dB quiet. Measured, `tests/linux/audio_mix.sh`: 1 kHz alone
  reads 0.645 of the rms at 1000 Hz and **0.000 at 300 Hz** (the control), 1 kHz
  and 300 Hz from two pids read **0.454 each** at an rms of **1.42× the solo**
  (a real sum is 1.41×, one winner 1.0×, a halving mixer 0.71×), and beside a
  writer running at a third of real time the fast stream's 1 kHz band drops out
  in **0 of 65** 40 ms windows. `user/audiolife.ad` is in the image and does
  here what it does on Hamnix — `tests/linux/audio_lifetime.sh`, all three of
  its reports: a 3.000 s clip sounds ONCE for 3.003 s, a raw write with no ctl
  at all sounds as itself (300 Hz 0.818 of its power, 1000 Hz 0.000) rather than
  as the previous clip's tail, and 0.65 s of a second program's effects are
  HEARD INSIDE another program's 4.001 s of music. The status line's
  `streams 100 100 100 100` was a placeholder a real program (`hamctl.ad`)
  parses; it is now the four per-slot Q8 gains, `stream <id> <pct>` sets one,
  `mixplay` is honoured instead of returning `-EINVAL`, and a format that does
  not match the running mix is refused BY NAME. `docs/linux_audio_mixer.md`.
  Still open there: no resampler (so a second stream at another rate is refused
  rather than converted), s16le-only summing, per-stream volume addressed by
  SLOT rather than by name, and `/dev/audioin` still has one reader. Capture
  *content* also remains unverifiable in an automated run — QEMU's only
  host-free input backend is silence — and the card is not ready for ~2 s after
  boot.
* **THE FOURTH FAULT OF THAT FAMILY IS FIXED, and it took the unprivileged
  half of the D-Bus gap with it. `$XDG_RUNTIME_DIR` is now `/run/user/1001`,
  0700, owned by the session user.** §8.5 named three — a mount point in the
  medium (`/n`), a stale X lock in its `/tmp`, a socket in its `/run` — each
  created by root when root was its only user, each invisible to the
  unprivileged session that came later. The fourth was the *directory* the
  third lives in: `/run` `40755` uid 0 on both media, so the session could
  **read** what `wsyswl` publishes (the socket at 0666, `hamnix-screen` at
  0644) and **create nothing**. Root now stages `/run/user/1001` at
  `bind '#distro/<name>' /n/<name>` — the same call, the same moment and the
  file next door to where the *first* fault of this family was fixed
  (`user/linux-syscalls.c`, `distro_stage_runtime` beside
  `distro_stage_mountpoints`). Narrower than the `/run` it replaces, not wider.
  **Nothing moved on disk**, which is what made it affordable: five files name
  the socket by its `/run` path and every one of them needed **no change**,
  because the three names `wsyswl` publishes are *symlinked* into the new
  directory (`../../wayland-0` &c.) and `connect(2)`, `[ -S ]` and `read` all
  follow symlinks — so `wl_display_connect(NULL)`'s
  `$XDG_RUNTIME_DIR/wayland-0` resolves for a client that has never heard of
  `/run/wayland-0`. `wsyswl` itself is untouched. **The system bus is a
  separate answer and the distinction matters**: `/run/dbus/system_bus_socket`
  is a *compile-time* path in dbus that no environment variable moves, so
  `/run/user/<uid>` alone fixes the session bus and dconf and nothing else.
  Nothing here starts the system bus as root — `hamnix-x11session` runs
  `dbus-daemon --system` itself as uid 1001 — so the same staging **chowns**
  `/run/dbus` and `/run/dconf` to the session user with their **modes
  untouched**: a transfer, not a share, since a distribution namespace has one
  session user. Measured, one boot, `tests/linux/distro_menu.sh` 0 FAIL:
  `runtime dir /run/user/1001 is WRITABLE by uid 1001: created …probe.226`,
  `(drwx------ 2 live live /run/user/1001)`,
  `system bus live on /run/dbus/system_bus_socket (pid 262)`,
  `system bus ANSWERED GetId` — where the previous boot had
  `system_bus_socket': Permission denied` and `WARNING no system bus`. The
  witness in `/etc/de-ns-run` is `ls -lL` now, not `ls -l`: the gated fact is
  the mode of the thing `connect(2)` opens and the path is a symlink, and it
  *probes by creating a file* rather than by reading a mode bit, because this
  whole family is the mode bits reading correctly while the effective answer
  is still no. Gate: `tests/linux/session_runtime_dir.sh`, **8 PASS 0 FAIL** —
  its own file rather than a corner of `distro_menu.sh`, because a permission
  fact that can only be measured by first standing up a compositor, an X server
  and a window manager is a fact nobody will re-measure; this one needs none of
  them. `docs/linux_distro_namespaces.md` §8.6.
  The `/tmp` half of it was already fixed: the generated `/etc/rc.distros`
  clears root-owned `*.log` / `*.err` left in a distribution's sticky `/tmp` by
  a root-run session, by class rather than by a list of three literal names.
* **~~`hamscene_image` renders a hole, on every image in the system.`~~ FIXED.**
  The `'I'` named-image upload is ported: devwsys's #128 scene image tier — 16
  slots, 256×256, 31-byte names, keyed by (owning wid, name), replace on
  re-upload, **refusal not eviction** at the cap — in a fourth shared segment
  `<seg>.img`, 0666 and derived from the segment `shm_attach` actually joined.
  It is on the world-writable side because the verb's gate is owner-or-host
  (the rule THE SPLIT states), and the case against is argued in the file
  rather than skipped. Three refusals answer three errnos where devwsys folds
  them into one: EMSGSIZE, ENOSPC, EINVAL.
  The compositor is a user process here, not the kernel, so the store is read
  back through files — `<wid>/draw/images` and `<wid>/draw/image/<name>` — and
  cached on a per-image SERIAL, so a video re-uploading 256 KiB a tick costs
  one small text read per unchanged frame. `<wid>/ctl` grows a twelfth field,
  `image_gen`, because a re-uploaded image leaves the scene text byte-identical
  and a compositor watching `scene_gen` alone freezes the picture on frame one.
  `lib/hamui_host.ad`'s silent `slot < 0 → return 1` now records the NAME and
  returns *not handled*; `user/wsysd.ad` reports one line per (window, name),
  once ever.
  **Two more defects fell out of it, both of the same silent-success family:**
  opening `draw/ctl` for writing used to flip the window to protocol 2, so an
  `'I'`-only scene client got a blank backbuffer painted over a correct scene
  (the opt-in is now the first `'B'`/`'D'`); and `background`/`pin` was never
  ported, so `hamdesktop`'s full-screen backdrop kept `z 6` and was painted
  OVER every ordinary client window — a desktop with wallpaper, icons, a panel
  and not one application window, with every return code 0.
  **Measured**: `tests/linux/wsys_image.sh` (8 PASS) reads the framebuffer and
  checks the pattern at natural size and through the scaler, because "every
  layer returned success" is exactly what this defect looked like for the whole
  port. All three callers verified —
  `docs/screenshots/linux/wsys-image-on-desktop.png` (hamimgscene composited
  over hamdesktop's backdrop), `wsys-image-video.png` (hamvideocore's `"frame"`,
  advancing), `wsys-image-hamsdl.png` (hamGame presents its ENTIRE surface as
  one named image, so for a hamSDL game the missing verb was the whole frame).
  **The first version of that first screenshot carried a defect of its own and
  the machine owner found it**: hamimgscene's window was a black rectangle
  roughly twice the size of the picture in it, because the client never wrote a
  `geometry` verb and took `win_alloc`'s 640x480 default while painting 320x260
  — and `wsysd` clears a window to opaque black and blits the whole `w*h` rect,
  so the difference reached the screen as black. Fixed in the client (a window
  is as big as what is painted, and it is the client that says so; devwsys's own
  default for a window that never asks is 320x240, not 640x480): black pixels
  inside the window box **223883 → 0**, same run, before and after. The
  screenshot is now the fixed one. **And the class is now gated rather than
  eyeballed** — see THE COVERAGE GUARD below.
  Regressions re-run: `wsys_uidgate` PASS, `wsys_bypass` PASS, `wsyswl_stall`
  11, `wsyswl_shared_fate` 18, `x11_geom_probe` 9.
  **What is NOT settled**: launched from the VM's root console with
  `hamimgscene &`, the window does not appear on the booted desktop, though the
  identical composition works offscreen with the same three programs. Not
  diagnosed; the leading suspicion is that a backgrounded `hamsh` job does not
  share `/srv` with the session, which would give it a private window system —
  the failure shape `shm_attach` already names. It is a launch/namespace
  question, not an image one.

#### THE COVERAGE GUARD, and the three clients still waiting on a verb

A window whose scene does not cover it reaches the screen as a black
rectangle: `user/wsysd.ad` clears a window's colour image to opaque black
before rasterizing and then blits the whole `w*h` rect. The machine owner
found **two** of these by looking at screenshots, weeks apart, and that is the
detection mechanism the tree had. Every gate passed both times — the display
lists were right, every op drew, every layer returned success.

**The sweep found the class has exactly two causes, and only one of them is a
client bug.**

* **A client that never states its size** — `user/hamimgscene.ad`, and it was
  the only one. Every other native scene client either writes a `geometry`
  verb of its own or gets one from `lib/hamui.ad`'s `_h_win_setup`, which sets
  `640x480` and whose root widget fills exactly that. `user/hamvideoselftest.ad`
  creates a window and never paints, but it runs headless as `/init` with no
  compositor and is correct as it stands. Fixed in the client, because a
  window's size is the client's to state; that is the Plan 9 shape and
  devwsys's, which keeps `wsys_win_geo_init` per window and answers
  `WSYS_SCENE_DEFAULT_W/H` = **320x240** — not 640x480 — for one that never
  said.
* **A client whose window is DELIBERATELY larger than its paint, asking the
  compositor for alpha-keyed present — and this port never implemented the
  verb.** `sys/src/9/port/devwsys.ad:8085` documents `keyed 1` as existing for
  exactly this, and names the client: *"a decorate-0 client (e.g.
  hampanelscene) whose window rect is LARGER than the pixels it actually
  paints — a panel that GROWS full-width to host an Applications dropdown,
  then paints only the bar + the menu card and leaves the rest of the grown
  band UNPAINTED"*. `user/hampanelscene.ad` already writes `keyed 1` on every
  panel window it allocates, and says why in a comment quoting the same
  user-reported symptom. **`user/linux-wsys.c` has no `keyed` and no `blend`,
  an unknown ctl verb is ignored, and so the fix regressed silently in the
  port** — the same shape and the same file as `background`/`pin`, which
  ea23c834 found the same way. Three clients are waiting on it:
  `hampanelscene` (`keyed`, the Applications dropdown — the black band in
  `docs/screenshots/linux/distro-menu-debian.png`), `hamappmenu` (`keyed`, the
  hover fly-out band), `hamshotui` (`blend`, the screenshot dim scrim, which
  is currently an opaque black rectangle over the desktop it is meant to dim).
  **This one is server-side and is NOT fixed here** — see the routing note.

**And it is a gate now.** `lib/hamui_host.ad` — the rasterizer wsysd
composites every window with — unions each painting op's destination rect into
a per-row interval and answers `hamui_host_uncovered_rows()` /
`_covered_w()` / `_covered_h()`. Like the image-miss table beside it the module
is pure and cannot print: it records, the caller reports.
`user/scene_raster_host.ad` takes an optional `[w h]` and prints the verdict
naming both sizes. `tests/linux/wsys_cover.sh` (7 PASS, host-only, seconds)
carries a positive control that a full-window fill and a full-window roundrect
are **not** accused, both real defect shapes reproduced with their exact
numbers, and the real panel's own `--scene-dump` asserted to cover its resting
bar. The measure is a per-row **union** and therefore conservative: it never
accuses a scene that is fine, and an interior hole with paint either side of
it on one row is not reported. Said out loud rather than left to be found.
* [SUPERSEDED — the score below, and the 301/328 further down, were both taken
  while the harness was killing the compositor. The measured figure is
  **306 / 329**; see THE COMPOSITOR HAD STOPPED COMING UP, below.]
  The run-sweep score is **297 healthy / 328 runnable**, re-measured end to
  end (`/home/david/.hamnix-build/sweep-a74b5560/{BEFORE,AFTER}/`), and the
  interesting part is the run BEFORE the fixes: **265 / 329, row for row
  IDENTICAL to the sweep taken forty commits earlier.** Nothing moved. The
  `sys_waitfds` park, the named-image tier, the backdrop, the clipboard,
  `/dev/reboot` — none of it changed a single verdict, and the reasons are
  worth more than the number:
  - **The sweep's own 4 MiB file cap was refusing `/dev/wsys`.** The window
    system's shared segments are FILES: `/srv/wsys.img` is 4,195,144 bytes and
    `/srv/wsys.bb` is 132 MB of v2 backbuffer, and `ulimit -f` bounds the
    offset a process may write, so both `ftruncate`s were refused EFBIG — the
    image store by 840 bytes. A/B in the same jail with the same binary: at
    4096 blocks `hamimgscene` prints "the 'I' named-image upload ... was
    refused, rc=-5" and `/srv/wsys.img` is 0 bytes; at 16384 it prints "scene
    window ready with the 32x32 image uploaded". So the sweep reported the
    tier as broken while the tier worked. It did worse with the backbuffer,
    *silently*: a v2 client's window table fits under the cap, so the probe
    found a wid and the row was scored **DREW_WINDOW while `/srv/wsys.bb`
    stayed 0 bytes and not one pixel was stored** (`sdlpong`: 0 bytes at
    4 MiB, 132,710,628 with no cap). Cap is 256 MiB now.
  - **A spin and a park are identical in every column the sweep had.** THE
    IDLE CENSUS could not have been caught here and a fix for it cannot be
    seen here — same status, same output, same wall clock. There is a `cpu`
    column now, and the summary lists anything at ≥80% of its own wall clock.
    It found `user/watch.ad` busy-waiting on `sys_get_jiffies` — the identical
    loop the census fixed in `sleep` and left behind here — in the first
    summary it ever printed: `watch -n 1 /bin/uptime`, cpu 1.0s of 1.0s wall,
    now 0.0s of 1.0s. `sleep 1` reading 0.0/1.0 is the standing sentinel that
    the census fix has not regressed. A row killed at the timeout reports `-`,
    not 0.0: `unshare --kill-child` SIGKILLs the subtree and nothing waits for
    it, so its rusage is never folded up, and "0.0" there would read as "this
    daemon used no cpu".
  - **`/dev/reboot`, `poweroff` and `halt` are class `unsafe`** and the sweep
    declines to run them by design, so that whole landing is invisible to this
    instrument on purpose.
  **+32, reconciling exactly (23 + 8 + 1).** Twenty-three rows are correct
  programs correctly refusing, now `EXPECTED_FAIL` with a REASON PER ROW in
  `tests/linux/runsweep_expected_fail.tsv` — sixteen chrome-spawned overlays
  whose own library (`lib/hamwid.ad`) says "the compositor allocates it and
  spawns this program into it ... the caller's only correct response is to
  stop with a non-zero exit", plus `login`, `getty`, `su`, `useradd`,
  `crontab`, `httpd_worker` and `wakelat_echo`. Eight are recipes that were
  asking the wrong question (`ac` handed prose to compile; `rm` handed a path
  that must not exist; `inflate_host`, `mp3decode_host`, `hamview_zoom_host`,
  `hamvideoscene_host`, `hamsdl_image_host`, `hamfmscene_host` and
  `scene_raster_host` handed nothing, the wrong file type, or one argument
  short). One is `hamimgscene`, freed by the cap. `net9_host` fetches a LIVE
  web page and is class `net`, so it leaves the DENOMINATOR rather than
  joining the numerator: 329 → 328.
  `umdf_host` is `EXIT_NONZERO` in BOTH runs and so moves nothing, but for a
  different reason each time: it used to be handed a text file as its `.ko`,
  and now runs its own `selftest-dma` — whose failure path **printed "dma
  alloc FAILED" and exited 0**, as did all three of its self-tests. That is a
  fix the headline cannot show, which is the argument for reading rows.
  What is left unhealthy is 29 `EXIT_NONZERO` and 2 `TIMEOUT`, and they are
  now almost entirely REAL GAPS named by the program: no `/dev/audioctl`,
  `/dev/vt/ctl`, `/proc/kmsg`, `/proc/svc`, `/proc/tasks`, `/proc/oops`,
  `/dev/firewall`, `/dev/keymap`, no `sys_srv_open`, no `/proc/self/ctl`
  nice control, and five scene clients that want a compositor the sweep does
  not run (`hamlock`, `hampanelscene`, `hamshotui`, `hamtoast`, `wsyswl`).
  **That last one is done — see THE SWEEP HAS A COMPOSITOR NOW, below.**

#### THE COMPOSITOR HAD STOPPED COMING UP, AND FIFTY ROWS WORE IT

**The 301 / 328 above is stale, and the reason is worth more than the
number.** Re-measured end to end on `port/tier1-syscalls`
(`/home/david/.hamnix-build/sweep-a6145486/{BEFORE,AFTER}/`, base
`836b2c8c`):

| | before | after |
|--|--|--|
| SCORE | **253 / 329** | **306 / 329** |
| `PAINTED` | 2 | **50** of 88 windowed rows |
| `UP_NO_WINDOW` | 50 | **0** |
| run phase | 308 s | 996 s |

Nothing had regressed in the desktop. **`wsysd` was being killed by the
harness before any client could map a window.** The v2 backbuffer pool is a
SPARSE FILE and `ulimit -f` bounds the OFFSET a process may write; jail_run's
cap was 256 MiB, set when the comment beside it read "BB_SLOTS(8) x 2 x
1920x1080x4 = 132 MB". `BB_SLOTS` is `WSYS_MAX_WINDOWS`, which has since gone
8 → 64 → 128 → 256 (the last for `wsyswl`'s MAXCONN), so `BB_FILE_BYTES` is
**4,261,478,400** — sixteen times the cap. `ftruncate(2)` was refused `EFBIG`
and the kernel killed the compositor with `SIGXFSZ`, *after* it had printed
`wsysd: screen 1280x800` and passed the readiness gate, because the pool is
allocated lazily on the first window. A/B, same binary, `/bin/hamclock`:
`ulimit -f 262144` → wsys.bb 0 bytes, `wins 0`; `6291456` → wsys.bb
4,261,478,400 bytes (**22,856 KiB of actual blocks — it is sparse**),
`fbpx 52117`, `PAINTED`.

**This is the third time this cap has manufactured a failure out of a working
program, and the first two were fixed by writing a bigger number in a
comment.** So it is not a number any more:

* two caps — the pool-sized one for rows that run a compositor, 256 MiB for
  everything else, because `yes` writes real bytes onto a real disk;
* the requirement is **re-derived from `user/linux-wsys.c`** at startup and a
  cap that no longer covers the pool is a FATAL error naming both figures;
* `tests/linux/runsweep_jail.sh` reports `HARNESS_FAIL` if the compositor is
  not alive when the program finishes — "the program was measured against no
  window system, so this row is the harness's failure and not the
  program's".

**And the census is clean.** With the compositor up, all fifty painting
clients read **0.0 s of cpu in a 15 s run** — the 23 that each burned a full
core are fixed, and this is the first sweep since that could see it. What is
left in that list is the four programs whose job is to burn cpu
(`preempt_hog`, `wakelat_hog`, `nice_lo`, `memhog`).

Three more rows moved, each for its own reason:

* **`pgrep` opened `/proc/tasks`**, the Hamnix kernel's single-file process
  table, which does not exist here — so it failed for every pattern, every
  time. It walks `/proc`'s pid directories now (`/proc/tasks` first, so the
  binary still works on the other kernel) and its output is byte-identical to
  procps' `pgrep` for the same pattern, 32 pids.
* **`/dev/auth` serves `setpass`**, so `passwd` can change a password at all;
  it could not, for anybody, ever. Faithful port of `_au_setpass`, gated
  hostowner-or-self, `tests/linux/auth_setpass.sh` (8 PASS, half of it the
  gate). The sweep's `passwd` row now exits 0 **and its overlay diff contains
  `etc/shadow`** — the proof it did the work rather than reporting it.
* **`memhog`'s recipe asked for 16 BYTES.** Its header says bare = bytes; the
  claim column said "N MiB". A 4 KiB allocation cannot move MemFree out of the
  noise, so the residency guard fired and a correct program was scored broken.

**The 23 that are left are named, with a reason each and which of four kinds
they are, in `docs/runsweep_unhealthy.md`** — real gaps this port owes
(`chvt`, `loadkeys`, `hfw`, `oopsread`, `initctl`, `service`, `nsrun`,
`umdf_host`, `modprobe`), hardware and privilege the harness withholds on
purpose (the four audio rows, `nice_hi`/`nice_demo`/`wakelat`/`sysirqprobe`,
`dmesg`, `insmod`/`rmmod`, `ac`), and two X11 bridges that want an Xvfb.
**None of them was moved out of the failing column to raise the score**, and
that file says why in each case.

#### THE SWEEP HAS A COMPOSITOR NOW, and a quarter of the desktop spins

The run sweep could not test a GUI program. It ran every scene client in a
jail with **no window system in it**, so the five above died in
`lib/hamscreen.ad`'s handshake with "no screen geometry" — correctly refusing
to guess, with nothing measured. Those five rows were the visible part. The
invisible part was worse: for every OTHER windowed program the verdict was
*did it exit*, because a client creates the shared `/dev/wsys` segment and maps
a window into it all by itself. Nothing composited anything, so nothing could
tell a client that DREW from one that mapped a window and painted nothing —
which is precisely how a v2 blit client came to score `DREW_WINDOW` with a
0-byte backbuffer, above.

`user/wsysd.ad` now runs **inside the jail, offscreen** (`HAMFB_FILE`), for
every `gui` and `daemon` row, and the sweep reads the framebuffer afterwards.
Measured, before and after, same 368 binaries, both preserved under
`/home/david/.hamnix-build/rs-wsysd/{before,final}/`:

| | before | after |
|--|--|--|
| SCORE | 296 / 329 | **301 / 329** |
| the five | 5 × `EXIT_NONZERO`, "no screen geometry" | 4 × `PAINTED`, `wsyswl` `STAYS_UP` and listening on `/tmp/wayland-0` |
| windowed rows with pixels on the screen | not askable | **51 `PAINTED`** of 88 |
| run phase | 895 s | 1035 s (**+16%**) |

* **`PAINTED` is a new verdict and `fbpx` a new column**: the sampled pixels in
  which this program's screen differs from **the bare compositor's own
  screen**, composed twice at the top of the run and *checked to be
  reproducible* before the column is trusted at all. "Is the framebuffer
  non-blank" would have said yes for every GUI row including the ones that
  drew nothing. `hamlock` 255,971 of 256,000 sampled — a lock screen covering
  the display, which is what it is for; `hamtoast` 5,700; `hampanelscene`
  16,640 across 2 bars.
* **One compositor PER PROGRAM.** One per class was the cheaper-sounding
  option and is wrong: the per-program overlay upper layer is this sweep's
  diff *and* its isolation, and `HAMWSYS`, `HAMWSYS_BB`, `HAMWSYS_IMG` and
  `HAMFB_FILE` are one file per HOST by default (`docs/steam_namespace.md`
  §11, where a stale backbuffer slot cost an hour) — a shared compositor hands
  each program the previous one's windows and the previous one's frame, and
  the pixel question becomes unanswerable. It costs +16% of the run phase.
  `VK_ICD_FILENAMES` is forced to lavapipe on every jail run.
* **The `wins` column was only ever answered by a pid collision.** It was
  probed from a SECOND run of the jail, i.e. a second pid namespace, and
  `win_reap_dead()` frees any window whose pid answers ESRCH — so every window
  should have been reaped. None were, because the program was `exec`ed and so
  was pid 1, the probe's own shell is pid 1 in its namespace, and `kill(1, 0)`
  succeeds. It is probed inside the program's own pid namespace now, while it
  is still alive, and a window still in the table after the program exits is
  reported as a leak instead of counted as a pass.
* **The end-of-run frame is the wrong sample point.** A client that exits has
  its window reaped and the compositor repaints without it, so the last frame
  of a program that FINISHED is the bare screen: `hamtoast` measured `fbpx 0`,
  "put nothing on the screen", for a program that had. The frame kept is the
  last one in which the program owned a window.

**AND THE COST COLUMN WAS BLIND TO THE ENTIRE DESKTOP.** `cpu` is bash's
`times` delta, i.e. reaped-child time, and `unshare --kill-child` SIGKILLs the
subtree — so every daemon and every scene client still up at the timeout, which
is nearly all of them, reported `-`. The jail samples the program's own
`$MNT/proc/<pid>/stat` while it runs now (the program's cost, not the
compositor's, which is a different pid), and the census immediately named
**twenty-three scene clients plus `hamscreensaver` each burning a FULL CORE**
for their whole run — `sdlpong`, `scenetest`, `multiwintest`, `hamview`,
`hamsnake`, `hamsettings`, `hamsessui`, `hampaint`, `hamnotesscene`, `hammon`,
`hamlogscene`, `hamlock`, `haminstallui`, `haminput`, `hamimgscene`,
`hamgamesnake`, `hamgamedemo`, `hamfiles`, `hamedit`, `hamcalscene`,
`hamcalc`, `hamappmenu`, `ham2048`. Verified independently per pid: `sdlpong`
1.11 s of cpu per second of wall clock while `wsysd` beside it — the process
actually rasterizing and presenting — spends 0.34 s in seven. `hamclock`,
`hampanelscene` and `hamdesktop` read 0.1 s, so this is not everything that
draws; it is a specific loop, and it is **THE IDLE CENSUS's third bullet still
in the tree**: a jiffy window spun on `sys_get_jiffies` with a `sys_yield` in
it to make it polite. 21 files under `user/` carry that shape.

Two are fixed here as the demonstration, both re-measured:

* **`user/hamtoast.ad`: 3.97 s → 0.06 s** over the toast's four-second life,
  pixel-for-pixel identical (`fbpx 5700` in both arms).
* **`user/crond.ad`: 14.3 s → 0.0 s.** Its poll loop was `while
  sys_get_jiffies() - start < POLL_JIFFIES: pass` — a bare spin with not even
  a yield — under a comment that says "Sleep". **crond is started on every
  boot**, so an installed machine has been burning a whole core in the
  background since it landed.

The remaining 22 are named with a number beside them by
`scripts/hamlinux_runsweep.sh`'s own summary and are the obvious next piece of
work. The park they all want is the one `lib/hamscreen.ad` and `wsysd`'s frame
loop already use: `sys_waitfds(fds, 0, ms)` with `nfds` 0, a plain timed wait.

One known miss: a client that renders and exits inside the first 0.25 s (`hamui_demo render`) is alive for none of the probe's samples and reports
`wins 0`, `fbpx 0`, while its own stdout says it rendered.
  Also found by reading OUTPUT rather than verdicts, because no exit status
  could have caught them: **`nproc` printed `1` on a twelve-core machine**
  (Linux `/proc/cpuinfo` has no `cpus_online:` field, so the fallback fired
  silently — now it counts `processor` lines and says so on stderr if it can
  do neither), and **`/dev/auth` accepted a verb it has never served** — any
  line that is not `user` or `pass` fell through and the write returned "all
  your bytes were accepted", which is how `passwd` came to report "not
  authorised, or no such user" for `setpass`, a verb that does not exist on
  this port. Unknown verb is EINVAL now and `passwd` names the real gap.
* The previous score was **261 healthy / 325 runnable**, and it was
  MEASURED rather than a floor: the full sweep was re-run end to end
  under the 12 s GUI timeout, so the ~85 unre-measured GUI rows are settled
  and `wakelat_echo` and `hamgame_mixer_demo` are examined. The score the
  sweep prints is also the score it computes — `summary.txt` has a `headline`
  block with the definition beside it (`healthy = RAN + DREW_WINDOW +
  STAYS_UP + EXPECTED_FAIL`; `runnable` = rows minus NOT_SMOKE_TESTABLE minus
  BUILD_FAIL), because the previous figure was derived by hand into a commit
  message and its denominator was simply wrong.
  **The measured baseline before this pass was 249 / 325**, not 249/323: the
  healthy count was right, the denominator was not, and one program
  (`arecord`) has been added to `user/` since. `+12`, reconciling exactly:
  five rows are the harness no longer calling a correct program broken
  (`false`, `cmp`, `diff`, `tty`, `kill` — a non-zero exit that IS the answer
  is now `EXPECTED_FAIL`); three are a recipe bug (`mktemp`, `route`, `pr`
  were being handed a literal `-` argument borrowed from the stdin column);
  three are timeouts that were killing bounded programs a second before they
  printed (`nice_lo`, `wakelat_hog`, `preempt_hog`); two are `SILENT_OK` rows
  that now report what they did (`hamgame_mixer_demo`, `hamnotify`); one is a
  real crash fixed (`hxd`); and **two go the other way for the right reason**
  — `login` and, through it, `getty`, which used to exit 0 when the login
  prompt hit end-of-input, reporting a session that was never established.
  Zero `SILENT_OK`, zero `EMPTY_EFFECT`, zero `CRASH` remain. The two
  remaining `TIMEOUT`s (`wakelat`, `sysirqprobe`) both print a named FAIL
  about `/proc/self/ctl` before they run long, so they are honest.
  Both `results.tsv` files are kept, under
  `/home/david/.hamnix-build/sweep-a4b04e0f/{BASELINE,AFTER}-preserved/` —
  **not** `/tmp`, which is a 16 GB tmpfs and is where a previous pass's
  baseline went during a disk-full cleanup, leaving its before/after resting
  on a figure it had not measured.

#### Solved, kept because the shape is the lesson

These are FIXED and measured. They stay because each is a worked example of
the failure this project keeps having — an answer shaped like success — and
the shape is more reusable than the fix. They are NOT open work.

* **The environment DOES cross `enter`; the drop is an `exec` one level up.**
  §8.5 recorded, unmeasured, that `enter` against an `ns clean { }` template
  rforks with `RFCNAMEG` and so "the environment does not appear to cross".
  The observation was right and the mechanism was wrong, which matters because
  the two boundaries are fixed in different places. `tests/linux/enter_env.sh`
  asks them separately with sentinel values no default in the tree produces:
  `rfork(RFPROC|RFCNAMEG)` is a process **fork** and `RFCNAMEG` empties the
  Pgrp — the mount table — not the address space, and `hamsh`'s exported
  variables are ordinary BSS arrays that the fork copies. But a **fresh
  `hamsh`** seeds its mirror with exactly `PATH` and `HOME` and never reads
  the inherited `environ`, so anything an ancestor exported dies at the `exec`
  into `/bin/hamsh /etc/rc.de-ns/<name> <prog>` — which is precisely how the DE
  panel spawns the launcher, and where `HAMNIX_DE_XSESSION` went. Consequence:
  the `HOME` / `XDG_RUNTIME_DIR` / `WAYLAND_DISPLAY` / `XDG_CONFIG_HOME`
  exports at the bottom of `/etc/rc.de-ns/<name>` **do** reach the client (they
  are set in the same shell that then enters), and `HAMNIX_DE_XSESSION` can
  never be steered from an outer shell no matter what is done to `enter`.
* **STEAM IS NOT STUCK AT ITS LOGIN SCREEN, and "the login window renders"
  had been standing in for "Steam works" in this file's own notes.** The
  window was DRIVEN rather than photographed — `tests/linux/steam_login_drive.sh`
  keeps the VM up and `tests/linux/qmp_input.py` puts pointer and key events
  on QEMU's own `virtio-tablet-pci`/`virtio-keyboard-pci`, which in a VM is
  the only input `wsysd` has (it scans `/dev/input/eventN`), so every event
  crossed wsysd → wsyswl → Xwayland → jwm → CEF. Nothing wrote a wsys ring by
  hand; that is `de_mouse_chrome.sh`'s rule applied to a real X11 application
  three servers down. Every number below is a pixel count over two QEMU
  screendumps (`tests/linux/ppmdiff.py`), and `docs/steam_namespace.md` §12
  is the table. **Works, with a mouse and a keyboard:** hover (moving over
  the username field repaints **97%** of it — CEF's hover state), click,
  **typing** (`hamnix` appears in Steam's username field), password masking,
  the *Remember me* checkbox and its tooltip, **a second window** (*Create a
  Free Account* replaces the 700x440 login window with an ~870x740 store
  browser carrying a live **hCaptcha** iframe — 93.8% of the old rectangle
  changed), the *Browse* mega-menu with its CDN artwork, navigating to the
  store front page, dragging the scrollbar (**96.44%** of an 830x680
  rectangle), and **live AJAX search** — `portal` returns Portal, Portal 2,
  Portal Knights and Portal Worlds with prices and cover art. **The one thing
  that did not work is the next entry.** No Steam account was used and none
  was sought, so the library, downloads and launching a game are unmeasured
  and are not claimed (§12.4).
* **(FIXED) The scroll wheel was never connected to anything — for the whole
  port, for every client.** Found by driving the real thing: with the pointer
  over Steam's store page, eight `REL_WHEEL` notches changed **0 of 564400
  pixels**, while a press-move-release DRAG of that same page's scrollbar with
  that same pointer changed **96.44%** of them. The page was scrollable; the
  wheel was not connected to it — and the drag is the control without which a
  dead POINTER would have produced the same zero. `user/wsysd.ad` had the whole
  wheel already (`EV_REL`/`REL_WHEEL` → `ptr_dz` → kind `'s'` → the **fifth**
  field of the routed pointer line); `user/wsyswl.ad`'s `handle_ptr_line`
  parsed the first four fields and stopped, and the file had no
  `wl_pointer.axis` in it at all. So the delta was computed, routed, written
  to the ring, read back, and dropped one parse short of the client — which
  means Firefox in the namespace and every other Wayland/X11 client had a dead
  wheel too. **Gate: `tests/linux/wsyswl_wheel.sh`** — offscreen, ~40 s, no VM
  and no Steam: evdev records → wsysd → wsyswl → a real rootful Xwayland →
  `xev`, which prints what the X SERVER delivered (an X11 wheel is button 4 up
  / button 5 down). **10 PASS**; reverted with the fix stashed it is **6 PASS
  / 4 FAIL** and the CONTROL (an evdev *move* arrives as `MotionNotify`) still
  passes, so it reports a dead wheel and not a dead pointer. It asserts the
  COUNT and the SIGN in both directions, because a wheel that scrolls
  backwards works and is wrong, which is worse than a dead one: nothing about
  it looks broken.
  **AND THE FIX IS NOT SUFFICIENT, which is said here rather than left to be
  discovered.** With the patched `wsyswl` in the image (verified by md5
  against the staged `/bin/wsyswl`) a second full Steam run, back on the store
  front page, wheeled over it and got **the same `IDENTICAL (0 of 564400 px)`**
  as before. So `wl_pointer.axis` was missing AND something else on the VM
  path also drops the wheel; closing one hole did not open the pipe. It is not
  `wsysd`'s routing or `wsyswl`'s translation — those are precisely what the
  offscreen gate exercises, against a real Xwayland, and they pass. The one
  thing that differs between the passing arm and the failing arm is everything
  UPSTREAM of `/dev/input`: a file of evdev records in one, QEMU's
  `virtio-tablet-pci` in the other. `tests/linux/vm_wheel_reaches.sh` is
  written and splits exactly that — `wsysd`'s own `pointer` counter across a
  wheel burst with the cursor held still, with a plain move as the control in
  the same run. **It ran: `pointer 0 → 2` for two moves, then `2 → 22` for
  twenty wheel events with the cursor STILL.** Exactly twenty. So QEMU's
  `virtio-tablet-pci` does deliver `EV_REL`/`REL_WHEEL`, `pump_input`
  accumulates it, `deliver_pointer` fires and `route_pointer` writes the `'s'`
  line — **everything upstream of `/dev/wsys/<wid>/pointer` is ruled out and
  the remaining drop is in this tree.** A SECOND defect was found and fixed
  there on the strength of that (`wl_pointer.axis_discrete` was being sent
  *after* its `axis` event; the protocol says before), and a **third** Steam
  boot still got `IDENTICAL (0 of 564400 px)` from the wheel on a loaded store
  page. So: two real compositor defects fixed, gate green and failing on
  revert, symptom still present. The one candidate left is that the gate uses
  the dev host's Xwayland (trixie, 24.x) while the namespace ships **22.1.9**
  — which makes the next step concrete and small: give `wsyswl_wheel.sh` an
  arm that runs against 22.1.9, because a gate that only ever tests a newer
  server than the distribution ships has a blind spot exactly the size of this
  bug. `docs/steam_namespace.md` §12.2a carries all three measurements.
  **THE ARM WAS BUILT, AND 22.1.9 WAS NOT THE DIFFERENCE.**
  `scripts/ns_xwayland.sh` lifts the namespace's own Xwayland out of
  `build/image/distro.ext4` with `debugfs` — no mount, no loop device, no root,
  no write to the shared image, ~16 MB and about a second — with its
  `DT_NEEDED` closure, and runs it through that image's own loader and
  libraries. `wsyswl_wheel.sh` now runs **every** assertion against both, and
  **22.1.9 and 24.1.6 behave identically**, on the core path *and* on the
  XInput2 smooth-scroll path. A second blind spot was found while looking:
  the gate only ever asked `xev`, which reads **core** X events, while
  Chromium — the whole of Steam's UI and Firefox's fallback — reads the wheel
  off an XInput2 **scroll valuator**, a different path out of the same server
  that can be dead while button 4/5 is perfect.
  `tests/linux/xi2_scroll_probe.c` is a second client asking that question in
  the same run. Both paths are green on both servers: **30 PASS**, and with
  the axis emission stashed the namespace arm is **9 PASS / 7 FAIL** with both
  controls still passing.
* **(FIXED, AND NOW PROVEN IN PIXELS IN A VM) The wheel scrolls a real program
  in the Debian namespace.** The stretch neither existing wheel test covered —
  QEMU's evdev node → `wsysd` → `wsyswl` → the namespace's *own* Xwayland
  22.1.9 → an X client, all inside one VM — is now
  `tests/linux/vm_wheel_client.sh`, ~4 minutes, no Steam and no CEF. Two
  programs out of the namespace's own `/usr/bin`, asked the two questions that
  are not the same question. `xev -root`: **six wheel-down notches arrive as
  exactly six button-5 presses and four up as exactly four button-4**, with a
  QEMU pointer MOVE as the control in the same log (4 → 14 `MotionNotify`).
  `xterm` with 3000 lines of scrollback, measured off QEMU's own screendump:
  **eight wheel-up notches changed 415 of 15840 pixels, eight back down changed
  415 again, and the net difference is 0** — the reversal is a stronger control
  than a scrollbar drag, because noise can make two screendumps differ and
  nothing but real scrolling makes A≠B, B≠C and A=C. **9 PASS.**
  Two traps this file fell into and now documents, both of which produced the
  exact zero the bug produces: the first diff rectangle was over the *blank*
  right-hand side of the terminal (`seq` writes four-digit numbers in the
  leftmost ~45 px) and read `0 of 96000` while the terminal scrolled perfectly;
  and the first wheel direction was **down**, on a terminal already sitting at
  the bottom of its scrollback, i.e. a working wheel with nowhere to go.
  **What this does NOT say: Steam was not re-measured.** The compositor chain
  is now proven end to end to a real client's pixels in the real VM; whether
  Steam's CEF scrolls is a separate measurement and nobody has taken it since
  the fixes landed. **(It has now. It is the next entry.)**
* **(MEASURED, AND IT IS STEAM'S BUG, NOT OURS) Steam still does not scroll —
  and an `xterm` in the SAME session, the same minute, does.** The measurement
  the entry above deferred, taken on the current tree, fourth full Steam boot,
  driven back to the store front page and wheeled over the same rectangle that
  produced the original `0 of 564400 px` so the numbers are comparable:

  | wheel over | 8 notches | 8 back | net |
  |--|--|--|--|
  | Steam's store page, `830x680+214+80` | `0 of 564400` | `0 of 564400` | — |
  | same, a second position mid-page | `0 of 564400` | `0 of 564400` | — |
  | same, a third position | `0 of 240000` | `0 of 240000` | — |
  | **`xterm`, same session, same minute** | **471 of 14000 (3.36%)** | **471 of 14000** | **0** |

  The xterm went 2974–3000 → 2934–2961 → back: 40 lines up, 40 down, eight
  notches of five lines, while the Steam window *behind it* stayed
  byte-identical across the same screendumps. **Three controls in that run,
  because a zero proves nothing alone:** the page has no noise floor (two
  screendumps 15 s apart with no input: `0 of 564400` — so any change would
  have been real, and the screendump is not stale); the pointer is alive and
  the framebuffer tracks it (a move changed `244 of 1024000`, bbox spanning
  both cursor positions); and the page is scrollable by something else (a
  240 px scrollbar drag changed **84.43%** of it and left the store at its
  footer). And the reversal, stronger than the drag: Steam gave A=B=C, the
  xterm gave A≠B, B≠C **and A=C**.

  **So the search space is now entirely above the X server and it is Steam's.**
  The same QEMU tablet, `wsysd`, `wsyswl`, Xwayland 22.1.9 and `jwm` carried a
  notch to one program's pixels and not to the other's, in one session — which
  is the cleanest separation of "our stack" from "Steam" this port can build,
  and it exonerates our stack. Next, in order: whether CEF's `XISelectEvents`
  mask on *that* window selects the valuator (the valuator itself is proven
  live at the server, `tests/linux/xi2_scroll_probe.c`), its GTK/SDL scroll
  settings, and whether `steamwebhelper` treats the page background as a
  scroll target at all. `docs/steam_namespace.md` §12.2c has all of it.
  Two things worth carrying forward: `spawn` does **not** search `PATH`, so
  `spawn debian { sh /tmp/... }` fails **silently** — no window, no message —
  and `/bin/sh` is required; and the store page moved ~600 px on its own
  between two screendumps with no input directed at it, probably a focus
  change scrolling an element into view, recorded because it is the only
  unexplained motion in the run.
* **(SOLVED — kept because the shape is the lesson) Steam's login window is on
  the Hamnix desktop.** `build/steamprobe/steam_login_maxmap64.png`. It was
  `MAXMAP`: `wsyswl` gave each connection **16** wl_shm mappings and Steam's X
  session holds **26**. Past 16, `map_alloc` returned -1 and `commit_buffer`
  dropped every frame at `mi < 0` — and a rootful Xwayland is ONE
  `wl_surface`, so one exhausted table froze the entire X session, which is
  why the control `xterm` and Steam's window were never two problems. Two
  boots of the same image differing only in that number:
  `map_alloc_failed 10 / drop_no_mapping 508 / commits 3` and a black screen,
  against `maps_high_water 26 / every drop 0 / commits 506` and the login
  dialog (`build/steamprobe/steam_black_maxmap16.png` is the control).
  **The lesson, which is this project's own:** the answer was in the third
  suspect list, and it took three passes because a compositor that drops a
  frame said nothing. Every silent `return` in `commit_buffer` is now counted
  by reason, named once on stderr, and published as `wsyswl-state` beside the
  Wayland socket — the one directory that spans the namespace boundary, so
  `cat /run/wsyswl-state` answers from either side, like
  `/dev/wsys/wsysd/state` before it. `MAXOBJ` went 256 → 1024 in the same
  pass (nothing hit it: `max_object_id 97`).
  A SECOND fault of the same class was found and fixed on the way, in
  `user/linux-wsys.c`: a v2 window's backbuffer slot carries its own `w/h`,
  the client writes rows at THAT width and `user/wsysd.ad` re-rows them at the
  WINDOW's width, and nothing checked the two agreed — a stale slot inherited
  by wid from a dead process put the whole X screen on the scanout as two
  half-height copies side by side. `tests/linux/wsyswl_stall.sh` reproduces
  both offscreen in three minutes with no VM and no Steam, and plants the
  stride mismatch by hand as a negative control.
  What the same two boots also retired, and is worth keeping in one
  place: **matchbox** was why every Steam window read `IsUnMapped`,
  and the **system D-Bus** comes up and answers `GetId`. The session
  no longer starts matchbox; it starts `jwm` (see the table above and
  `docs/linux_window_manager.md`), under which `Sign in to Steam` is
  `IsViewable` at `700x440+290+180` **and** in `_NET_CLIENT_LIST`. Both halves
  were needed and neither was sufficient: the window has to be mapped *and*
  the frames have to be delivered. With a window manager in the session the
  same run reads `maps_high_water 31`, five above Steam's own 26 and twice the
  old limit — and `windows_high_water 1`, which is the whole rootful-Xwayland
  shared-fate problem stated as a number.
* **(historical, kept for the shape)** It installs, brings up
  pressure-vessel, and Chromium loads to `SteamApp Init - Before Login`.
  What that is NOT, now measured rather than guessed (`docs/steam_namespace.md`
  §6.1): the `(-2147483648, …)` in the CEF log is not our stack answering a
  geometry query with a sentinel — the X screen is a real 1280x800 at 96 dpi,
  `matchbox` is managing and publishes `_NET_WORKAREA = 0,0,1280,800`, and a
  real Chromium — which is what CEF is — maps a window through Xwayland →
  wsyswl → wsysd and gets its pixels onto the framebuffer. The window path is
  not the problem.
  Nor is it CEF's GPU process, which does exit twice per launch
  (`viz_main_impl.cc(166)`): run with Steam's own `-cef-disable-gpu
  -cef-disable-gpu-compositing`, those errors stop and the window tree is
  unchanged.
  What it IS: every window Steam creates it leaves **`IsUnMapped`** — the UI is
  alive behind them (the login page runs and polls), and even the *launcher's*
  `Show window`, which happens before CEF exists, puts no pixels on a
  framebuffer sampled once a second across the three seconds it is up.
  The next measurements are named in `docs/steam_namespace.md` §6.3 and none of
  them is blocked: trace the X protocol for a `MapWindow`, run the session with
  no window manager, and read what `dbus-daemon` is actually complaining about.
  Its probe is 23 PASS / 1 FAIL (the remaining one is the PulseAudio socket).
* **The image build could drop a program and still say `done`.** Fixed in this
  pass, and listed because the shape recurs: `scripts/hamlinux_image.sh` kept
  its own copy of wsysd's extra objects after 6a27c0ec moved them into
  `scripts/hamlinux_build.sh`, so the compositor failed to link, was printed in
  the same list as two programs that have no source, and the initramfs shipped
  with **no compositor at all** — booting to a black screen while rc.5 printed
  `compositor started`. Failed links are now named separately, with their build
  logs, and wsysd/hamsh/hamdesktop/hampanelscene failing to build exits 1.
* **(SOLVED — kept because the shape is the lesson) Launching an app from the
  distribution fly-out.** This entry used to say the FIRST bind of the
  template, the root switch, failed ENOENT, that the identical lines worked
  from a console shell, and that it was therefore "something about this
  SPAWNED shell's namespace". Three shapes of the launcher rc and three passes
  over the spawn gate and `rfork` went into that, and **nobody had ever asked
  which bind failed** — because `hamsh` answered with a fixed sentence naming
  a fixed suspect (`needs CAP_SYS_ADMIN … uid 1001`) for a failure that was
  ENOENT, not EPERM. The error message was the thing answering something
  success-shaped.
  It is the **LAST** bind, `#/` onto `/n`, with the root switch already
  succeeded. `enter <name>` binds /dev, /proc, /srv and /n INTO the
  distribution's own root, a bind whose target directory does not exist fails
  ENOENT, and the session user cannot create one — the distribution's `/` is
  uid 0 and **uid 0 is not mapped into the user namespace `ns_privilege()`
  acquires**, so CAP_DAC_OVERRIDE does not reach it. Those directories had
  only ever existed as a side effect of somebody running `enter <name>` AS
  ROOT on a WRITABLE medium, where `enter_root`'s own ignored `mkdir`
  succeeded: `debugfs -R 'ls -l /'` finds `n` in `distro.ext4` and not in
  `alpine.ext4`. The console and the desktop terminal "worked" because their
  tests run a root `enter` first, in the same boot.
  They are now made deliberately, by root, when the boot posts the server at
  its name (`user/linux-syscalls.c`, `distro_stage_mountpoints`), and a medium
  that refuses says so then rather than at launch. `hamsh` names the failing
  bind, its target and the kernel's own reason (`_ns_apply_failed`).
  Underneath it was a second gap: a `.desktop` names an **X11 client** and
  nothing in the namespace served X, so `etc/de-ns-run.linux` — copied into
  each tree at boot — now gives a menu-launched program a display, delegating
  to the distribution's own `hamnix-x11session` where there is one.
  `docs/linux_distro_namespaces.md` §8.4, `tests/linux/distro_menu.sh` (which
  now clicks a row and screendumps what comes up).
* **(SOLVED) A menu-launched app reached its namespace and could not reach the
  DISPLAY.** The click worked, the namespace worked, the application started —
  and Xwayland, as uid 1001 inside the namespace, could not `connect(2)` to
  `/run/wayland-0`: `/etc/rc.distros-wl` starts the per-distribution `wsyswl`
  **as root**, `bind(2)` creates a unix socket 0777 masked by the umask (022),
  so it came out `srwxr-xr-x` — owner-writable only, owner not even mapped into
  the entering process's user namespace (`nobody nogroup`). Nothing had hit it
  because every previous GUI-in-a-namespace run (`steam_gui_run.sh`,
  `alpine_gui_run.sh`) ran its client as ROOT.
  **`user/wsyswl.ad` now `sys_chmod`s its own socket 0666 at creation** — the
  server knows its own path (it is `argv[1]`), so the mode is set in the one
  place a caller cannot forget, and a failed `chmod` is named on stderr. This
  is the same 0666, for the same reason, as `/srv/wsys` (`user/linux-wsys.c`,
  THE SPLIT; `ad440707`): what a connection buys is a Wayland *client* session,
  and `wsyswl` issues no gated verb on a client's behalf — `newwindow` is
  devwsys's explicit pre-gate exception and the `<wid>/ctl` verbs it drives are
  on windows it owns. The access control is the path, as with every Wayland
  compositor: the socket is inside ONE distribution's `/run`.
  Starting `wsyswl` as the session user was considered and rejected, and the
  reason previously given for rejecting it was wrong in both halves: it does
  not need `/dev/fb` (that is `wsysd`; `wsyswl` is a *client* of `/dev/wsys`)
  and the uid gate does not block it either. What blocks it is that the
  distribution's `/run` is root-owned 0755, so a uid-1001 `wsyswl` could not
  create the socket there at all — it moves root-prepared state rather than
  removing it, and widens the blast radius from one socket to a directory.
  **Measured**: `tests/linux/distro_menu.sh` reports "launched" and "got a
  display" as two facts and both are now PASS, with the socket's mode gated
  separately (`srw-rw-rw-`, logged by the shim from *inside* the namespace);
  `build/distromenu/shot-launched.png` is `uxterm`, launched from the DE
  application menu, running in the Debian namespace on the Hamnix desktop.
  `docs/linux_distro_namespaces.md` §8.5.
* **(FIXED — same defect as the `hamscene_image` entry above; kept for the
  detail of how it was found)**
  The `/dev/wsys/<wid>/draw/ctl` `'I'` verb was never ported, so
  `hamscene_image` renders nothing on this line.** Found by tracing
  `hamimgscene`, which was exiting 2 in total silence. `user/linux-wsys.c`
  implements the blit protocol's `'B'`, `'D'` and `'C'` and dropped devwsys's
  named image upload; with no store behind it, `lib/hamui_host.ad`'s
  rasterizer takes its `slot < 0 → return 1` path and draws a hole without
  complaining. That reaches `user/hamimgscene.ad`, `lib/hamvideocore.ad`
  (the `"frame"` image a video player blits) and `lib/hamsdl.ad`. It now
  answers **ENOSYS by name** — distinct from the `EINVAL` it gives real
  garbage — and `hamimgscene` prints the whole explanation and exits 2.
  Closing it needs a named-image table in the shared segment plus `wsysd`
  registering from it; not attempted here. **That is exactly what was then
  done** — see the entry above for the shape it took and for the two further
  defects the end-to-end measurement turned up.

### What answered the original open questions

* **§3, the `/net` design.** Answered: a file tree, in shared memory. §3.3
  identified the constraint correctly — a connection must be addressable by
  integer across process boundaries — and that is exactly why a shim was the
  wrong answer. The connection TABLE is shared, so the NUMBER means the same
  thing everywhere; the socket rides across `fork`, which covers
  `httpd` → `httpd_worker`. `user/linux-net.c`.
* **§7.1, cross-process fd addressing.** Answered the same way, and it is the
  same problem: a pipe slot is a FIFO, the bindings are shared, and `/fd/<n>`
  resolves per-process. `user/linux-fdns.c`.
* **§4.4, the compositor.** Answered: `/dev/wsys` is shared memory (a faithful
  port of a KERNEL device, which is what `devwsys.ad` is), and the RASTERIZER
  moved to userland as an ordinary Adder program, `user/wsysd.ad`. It reuses
  `lib/hamui_host.ad` unchanged — that module was written as a host-test sink
  and turns out to be a compositor. §4.4's "DRM master is exclusive" blocker
  dissolved when fbdev turned out to be both the right analogue and not
  master-exclusive.

### The one thing to carry forward

Every serious bug on this line has had the same shape: **a gap that answers
something success-shaped instead of the truth.** Not a crash, not an error — a
plausible wrong answer. The list, because the pattern is more useful than any
single entry:

* `sys_chan_dir_mode` stubbed → `cp -r` created a file containing a directory
  listing and exited 0.
* `sys_get_jiffies` returning 0 → `sleep 1` hung for ever.
* `#d` bound to a real `/proc/self/fd` → every spawned program's output went to
  a read-only stdout and vanished; the program ran and exited 0.
* `dup2` of a synthetic device fd → `echo x > /dev/wsys/appmenu/launch`
  reported success and the queue stayed empty.
* `sys_openchan` fail-closed → EVERY shell redirect created its file, wrote
  nothing to it, and printed to the console.
* `sys_waitpid_nb_raw` returning waitpid(2)'s 0 for a live child → the DE
  terminal decided its shell had died the instant it started.
* `sys_read_nb` leaving `O_NONBLOCK` set → the next blocking read returned
  EAGAIN, which `hamsh` read as end-of-input and exited.
* `ps` printing a kernel banner and exiting 0, because `/proc/tasks` is
  Hamnix's process list and does not exist on Linux.
* `hpm install a b c` silently dropping `b` and `c`; and a fresh install
  arriving non-executable, hidden because overwriting an existing binary
  inherits its mode.
* Six syscalls with **no body at all** in the hosted lane — `sys_mount`,
  `sys_nslabel`, `sys_srv_open`, `sys_fdslot_arg`, `sys_svc_publish`,
  `sys_svc_ctl` fell through an `#ifndef ADDER_HOSTED` block that is compiled
  out here, ran off the end of `.text`, and executed arbitrary bytes. `hamsh`
  — PID 1 — calls all six, one of them on every `enter`. It mostly got away
  with it, which is the worst available failure mode.
* Every DE client defaulting to 800×600 because `/dev/wsys` recorded the
  screen size in fields nothing could read back, so each one opened `/dev/fb`
  privately — which can never work while the compositor holds DRM master.
  `hamlock` did it at 1024×768, covering 53% of a 1080p display: a lock
  screen that has not locked anything.
* `enter debian { steam }` from a desktop terminal running a Hamnix binary in
  the NATIVE root and exiting 0.
* `login` returning 0 when the login prompt hit end-of-input — `getty` EXECS
  it, so login's status IS the VT session's status, and a supervisor could
  not tell "logged in and out again" from "nobody ever typed a name".
* `hxd` looping for ever because its hex-byte loop was missing `b = b + 1`.
  The symptom was not a wrong dump: it wrote three bytes per iteration
  through the end of a 128-byte row buffer, over `page_len`, `file_size` and
  `top`, and on until it walked off `.bss` — a SIGSEGV whose cause was four
  frames and a whole BSS away from the missing line.
* `shm_attach` using `O_RDWR|O_CREAT` → `fs.protected_regular` refuses
  `O_CREAT` on a file you do not own in a sticky directory, so an
  unprivileged client silently created its own private window system and drew
  into a screen nobody composites.
* `background 1` — the verb `hamdesktop` sends to pin its backdrop — not
  ported, and an unknown ctl verb is IGNORED, so the backdrop kept
  `lib/hamui.ad`'s default `z 6` and the compositor, which paints z ascending,
  painted an opaque full-screen backdrop over every application window. A
  desktop with wallpaper, icons and a panel and NOT ONE application, every
  return code 0, and the taskbar still listing the windows it was covering
  (ea23c834).
* A window whose owner had exited or crashed **stayed on the screen for ever**
  — an opaque rectangle no click could reach, still listed in the taskbar,
  because `/dev/wsys` is shared memory with no fid table and nothing ever
  freed a window its owner had not freed by hand. Nothing in `lib/hamui.ad`
  ever does, so a NORMAL exit leaked one too (165195bc).
* **THE DE CHROME COULD NOT BE CLICKED WITH A MOUSE, AND NOTHING SAID SO.**
  `user/wsysd.ad`'s `route_pointer` wrote the routed event to
  `/dev/wsys/<wid>/pointer` **and to nothing else**. `lib/hamui.ad` reads that
  file, so every ordinary application was fine. `user/hampanelscene.ad` and
  `user/hamdesktop.ad` — the panel and the desktop, the two programs a person
  actually points at — read `/dev/wsys/<wid>/event`, which is where Hamnix's
  `devwsys.ad` pushes its `'m'` pointer lines
  (`~/Hamnix/sys/src/9/port/devwsys.ad:12384`), and **nothing in this port ever
  wrote a pointer line to an event ring**. So the Applications button, the
  desktop icons and the taskbar were inert under a real mouse. Measured twice,
  independently, with a `wsys_hold` window whose owner drains neither ring:
  after a full evdev click `pointer` held `d 80 110 1 0` / `u 80 110 0 0` and
  `event` was **empty**, six consecutive reads. Every gate that drives the
  chrome — `tests/linux/distro_menu.sh`, `tests/linux/de_appmenu_band.sh` —
  writes the event ring by hand as host owner, which is why none of them
  noticed. **Fixed**: `route_pointer_event` puts the routed line on the EVENT
  ring in devwsys's exact shape — `m <x> <y> <buttons> <dz>`, type byte always
  `'m'`, the button STATE in the bitmap, which is what `hampanelscene`'s edge
  detector (`bv & (bv ^ prev_bv)`) is written against. **The event ring is
  canonical** because Hamnix says so: devwsys routes only there, and
  `~/Hamnix/user/hamappmenu.ad:415` calls `/pointer` "the legacy ring …
  now DEAD". `pointer` is still written here, unchanged, because on this line
  it is not dead — `lib/hamui.ad` reads it and every hamUI application inherits
  that; retiring it is Hamnix's migration, not this fix's. Gated by
  `tests/linux/de_mouse_chrome.sh` (13 PASS), which is forbidden to poke a ring.
* **And a click that arrived all at once was dropped entirely.** Found while
  gating the above. `pump_input` drains every pending evdev record in one pass
  and the frame loop routes ONCE afterwards, so a `move, down, up` read in a
  single pass folded into one event — the last edge won, which is the release
  with buttons 0, and the press was never delivered. That is not exotic: the
  records queue in the node, and a compositor that spent a frame painting reads
  them together. Measured: seven records written in one go left the ring holding
  exactly `u 80 110 0 0`. Fixed by flushing the pending edge (`deliver_pointer`)
  before accepting a second button transition in the same drain — devwsys routes
  per event, and this is that at the granularity this poll loop has.
* **And focus was a private variable the compositor never told anyone about.**
  Named by the agent that made the DE clickable, fixed here. `wsysd` kept
  `focus_wid`, used it to route keys and to colour the active titlebar, and
  emitted **no `f` line at all** — where devwsys pushes `f in\n` / `f out\n`
  onto the per-window EVENT ring on every focus change (`_wsys_set_focus` →
  `_wsys_evt_emit_focus`, `~/Hamnix/sys/src/9/port/devwsys.ad:12399`). The
  client half was already written and waiting: `hampanelscene`'s `_drain_events`
  parses `f out` and closes its Applications dropdown on it. So the menu could
  only be dismissed by hitting the same button a second time — clicking the
  wallpaper left the card hanging over the desktop, which a person notices in
  the first ten seconds. **Fixed**: `route_focus_event` emits Hamnix's exact
  line shape on the same ring as the `m` lines, and `set_focus` is now the ONE
  place `focus_wid` moves. Three call sites: the click-to-focus press, a press
  on bare backdrop with no window under it (`set_focus(0)`, devwsys's
  `pressed == 1 and target == 0`), and `pick_focus`, so launching a window from
  the menu dismisses the menu too. **The order it guarantees**, on wsysd's
  single thread with synchronous `/dev/wsys` writes: `f out` to the loser
  returns → `focus_wid` moves → `f in` to the gainer → *then* the caller's `m`
  line for the very press that moved focus, which is devwsys's order (focus
  first, `_wsys_evt_emit_pointer` after). A client never sees the press before
  the `f in` explaining it. **The no-change early return is load-bearing**: the
  dropdown here is not an override-redirect window, it is the panel's OWN
  window grown taller, so a click on the Applications button must emit nothing
  or the focus line would fight the toggle that already worked. Gated by
  `tests/linux/de_focus_dismiss.sh` (14 PASS).

* **A `wl_pointer.motion` THE POINTER NEVER MADE, and the PROBE that agreed
  with it for four passes.** `wsysd` writes a pointer line for every input
  event, including one carrying nothing but a wheel delta with the cursor
  standing still, and `wsyswl` answered each of those with a
  `wl_pointer.motion` at the coordinates the pointer already had. Xwayland
  routes `wl_pointer.axis` to the slave device `xwayland-relative-pointer` and
  `wl_pointer.motion` to `xwayland-pointer`, so a notch became
  `motion(6) -> axis(7) -> motion(6)` and the X master had to switch slaves
  twice per notch. Every switch is an `XI_DeviceChanged`, and a smooth-scroll
  client keeps a per-device valuator baseline it must DROP on that event —
  Chromium does — so every scroll motion was a first motion and every delta was
  zero. Steam's store page moved **0 of 564400 pixels** for four passes while
  an `xterm` in the same session scrolled 471 px, because `xterm` reads core
  button 4/5, which none of this touches. It is 97.41% and a clean reversal now
  (`docs/steam_namespace.md` §12.2d).

  **The success-shaped part is not the motion, it is the instrument.**
  `tests/linux/xi2_scroll_probe.c` was written specifically to be the client
  Steam is — the Chromium-shaped one that reads a scroll VALUATOR rather than
  button 4/5 — and it reported the wheel healthy on both Xwayland versions, 30
  PASS, through the entire bug. It never selected `XI_DeviceChanged`, so it
  accumulated straight across the device change that was resetting the real
  browser on every notch. Three passes of measurement below the X server were
  spent on the strength of that green. **When a stand-in for a program
  disagrees with the program, doubt the stand-in first.**

* **A SURVEY THAT REPORTED ITS OWN `for` LOOP AS A FACT ABOUT THE HARDWARE, and
  the 33 ms it hid for months.** `tests/linux/vk_icd_survey.sh` skips
  `nvidia_icd.json` **by design** — that ICD reaches the GPU through
  `/dev/nvidiactl`, which the survey's `tmpfs`-over-`/dev/dri` masking does not
  cover, and the card belongs to the machine's owner. Having skipped it, the
  script then summarised: `CPU-ONLY — correctness is gateable, performance is
  not`. On a box with an **RTX 3090** in it. That sentence was quoted for
  months, in this file and in `docs/vk_linux_backend.md`, as the reason the
  Vulkan backend could never be measured on real silicon. It was never a
  statement about the machine; the GPU was one command away the whole time.
  Fixed: any unrun ICD now yields `UNDETERMINED`, naming what was skipped and
  printing the command that would settle it. **A survey may report "I did not
  look"; it may never report "there is nothing there" on the strength of not
  having looked.**

  **And what it was hiding was itself an instrument.** Run at last, the bench
  said `GPU 8× faster on fills, 7.4× SLOWER on the DE+text frame` — and that
  second number was not a measurement of the GPU either. `GPU_US` was wall
  clock around the frame, which cannot tell *the device is slow* from *the host
  is slow with the device idle*. Asked for its own clock
  (`VK_QUERY_TYPE_TIMESTAMP`), the RTX 3090 answered **428 µs** for a frame
  that took **32,722 µs**. 32.1 ms of it was never submitted to anything.
  The cause was one line: the glyph coverage cache confirmed a hash hit byte
  for byte — correctly, that confirmation must stay — **against the mapped
  Vulkan buffer**, which is cached RAM on lavapipe and uncached
  write-combined memory on a discrete GPU. A host-side mirror took the frame to
  1,166 µs, byte-identical, and turned 7.4× slower into 3.8× faster.
  Gated now by a **host-overhead ceiling** in
  `scripts/bench_vk_linux_device.sh` (wall ≤ 10× the device's own clock; the
  bug sat at 76.4×), which a CPU ICD passes trivially — which is exactly why
  the software gate could never have caught it.
  **Third instrument on this page after `xi2_scroll_probe.c` and the 1.0.10
  control. Suspect the instrument.**

None of these failed loudly. Three were found only by tracing, one only by
running `strace` **as PID 1**, and one only after publishing the compositor's
own state as a file (`/dev/wsys/wsysd/state`) so it could be `cat`-ed from
inside a misbehaving desktop. When something here does not work, assume a call
is lying before you assume it is broken.

### And the variant that is not on that list: the program was loud, and nobody ran it

`hamnix-adder-1.0.12` was published carrying **one file**, `files/bin/ac`.
`/bin/ac` is a driver that execs the hard-coded `/bin/host_ac`, so on a machine
installed from 255.one the distribution's compiler did not exist. Type
`ac hello.ad` on it and it says, correctly and by name:

```
ac: cannot run /bin/host_ac
ac: hello.ad: the Adder compiler could not translate this program
```

Exit 10, no binary. **`ac` did everything right.** It did not exit 0, it did not
write an empty file, it named the missing thing. It is on this page anyway,
because the lesson is one step further out than the list above: *a program that
fails loudly is worth nothing if no gate ever runs it.* Every automated check
passed and had to — the package built, its sha256 matched its bytes, its
dependency resolved, the file it claimed to carry was really in it, and
`channel_covers_image.sh` found `bin/host_ac` **named in its exclusion table
with a reason in front of it**.

That reason was the actual defect, and it was wrong in both halves: it said
`host_ac` was "built for the BUILD HOST's libc" (`readelf`: no `.dynamic`
section, no `INTERP` — it is the one binary in `/bin` that needs no libc, while
`ac`, which shipped, is the one with `NEEDED libssl.so.3 libcrypto.so.3
libcrypt.so.1 libc.so.6`), and that "the shippable compiler is `ac`, which IS
packaged" (`ac` is not a compiler). So:

* **A reason in an exclusion table is a claim, not a measurement**, and an
  unmeasured claim there is indistinguishable from the silent drop the gate
  exists to catch — it just has prose in front of it. Both of the exclusions
  that assert a MECHANISM (`/init`, `modules.dep`) are checked by reading the
  built tarballs; the ones that assert a PROPERTY OF THE FILE were not checked
  by anything until this.
* **The image is not the machine.** Every existing `ac` test — `ac_host.sh`,
  `ac_ns_host.sh` — stages the toolchain out of the tree, where `host_ac` has
  always sat. Both passed throughout. The question "does the CHANNEL carry a
  working toolchain" had no test at all, and it is the only version of the
  question NORTH_STAR's invariant is about.

Closed by `tests/linux/channel_compiles_adder.sh` (**8 PASS / 0 FAIL**, 3 s),
which unpacks `hamnix-adder` out of the built channel, stages a root whose
`/bin` is those files **and nothing else**, runs the real `ac` through its real
`rfork` + three binds under `/n` + `bind '#distro' /`, and then RUNS the ELF
and compares its stdout — exit 0 having written nothing, and a binary that does
not run, are both failures. `scripts/hamlinux_packages.py` runs it before it
writes `index.json`, so a channel whose compiler does not work has no index.
Against the published 1.0.12 bytes it scores **2 PASS / 3 FAIL**.

### The gate the last two of those got

`tests/linux/wsys_desktop_z.sh` composites **the real desktop** — `wsysd` +
`hamdesktop` + `hampanelscene` + application windows, offscreen through
`HAMFB_FILE` — and reads the answer out of the framebuffer. It exists because
nothing did: `wsys_image.sh` passes with the `background`/`pin` fix reverted,
because it never runs `hamdesktop`, and every other gate composites ONE client,
or reads the window table, or asks a layer whether it succeeded.

Six assertions, each of a z-order RELATIONSHIP rather than a fixed coordinate:
the application's rectangle is the application's pixels; the backdrop is below
the lowest z a window can *ask* for; the panel stays over a window that
overlaps it; a click on the desktop does not bury the application; a raise
brings an occluded window to the front; a closed window's pixels leave the
screen. Each client paints one flat colour, so "which of these two windows owns
this region" has an arithmetic answer.

**Both arms are measured, and the first version of assertion 2 had no teeth.**
With `ea23c834`'s hunk reverted the gate reports 9 PASS / 3 FAIL and exits 1;
with it in, 12 PASS / 0 FAIL. "The application is over the backdrop" on its own
passes in BOTH arms — the unpinned backdrop keeps `win_alloc`'s default z 5,
already below an ordinary window's 6 — which is written into the file rather
than glossed, because a gate that passes either way is what this line already
had. The last assertion found 165195bc on its first run.

### And the gate the Applications menu got

`tests/linux/de_appmenu_band.sh`, **11 PASS**, offscreen. The owner reported
the Applications dropdown as "the full width of the display and the right part
blank", over the wallpaper *and over the other apps*. 61261904 fixed the
mechanism — devwsys's `keyed` verb, dropped by three layers of this port — and
gated it with `tests/linux/wsys_keyed.sh`, which builds a **synthetic**
full-width window out of `wsys_hold` and paints its left 200 px. Nothing
asserted anything about the Applications menu, and nothing anywhere tested the
"or the other apps" half.

So this one composes the real desktop, puts an ordinary client at z 6 *inside
the rectangle the menu is about to grow over*, opens the menu the way a person
does, and asserts the panel window GREW to 1280x206, the menu card is painted,
the wallpaper right of it is byte-identical to the frame before, and the
application under the band is still 100% its own colour. **The control is in
the same run**: `keyed 0` on the same window and the same scene buries both
(0% and 0%), then `keyed 1` and both come back — without it, "the wallpaper is
still there" is also satisfied by a menu that opened somewhere else.

**Three revert arms, all measured.** Layer 1 (the `keyed` ctl verb removed from
`user/linux-wsys.c`): 8 PASS / 3 FAIL. Layer 3 (`vk2d_raster_clear_rect_a`
stamping alpha 255 again, the `_vk2d_pack_opaque` shape): 8 PASS / 3 FAIL.
**And the arm the older gate cannot have**: `hampanelscene` writing a verb the
device does not know instead of `keyed 1` — a CLIENT-side regression —
9 PASS / 2 FAIL, where `wsys_keyed.sh` stays green because it never runs the
panel. Reported live on 2026-08-11 and **not reproducible on HEAD**: the
committed screenshot that carried the report,
`docs/screenshots/linux/distro-menu-debian.png`, predates 61261904.

### And the gate the MOUSE got

`tests/linux/de_mouse_chrome.sh`, **13 PASS**, offscreen, ~40 s. This is the
one file in the tree that is **not allowed to poke a ring**, and that rule is
the whole point of it: `distro_menu.sh` and `de_appmenu_band.sh` both open the
Applications menu by writing the panel's event ring as host owner, which is a
fine shortcut for the geometry they gate and is precisely why the entire input
path underneath could be missing with both of them green. Assertion 12 greps
this file for an `event`/`pointer`/`keys` path under `/dev/wsys` and FAILS if a
future edit takes the shortcut back. It names the RING and not the tool — it
used to say `wsys_poke`, which `cat`, `echo >` or a fresh helper would each
have walked straight past.

#### And the day this gate accused a healthy channel

`MOUSE_BIN_DIR` ran the compositor, the desktop and the panel out of a
published tarball — and then read the panel's geometry back with `wsys_poke`
**compiled from this tree**, because the substitution loop carried
`[ "$name" != wsys_poke ]` on the grounds that a test tool is not part of the
channel and *"it only ever READS a ctl line, so where it comes from cannot
change an answer"*.

That sentence is false, and `user/linux-wsys.c` says why in its own words:
every program in this tree is a wsys client, **reading included**. Opening
`/dev/wsys/<wid>/ctl` attaches to the shared segment, and an attacher whose
`WSYS_VERSION` differs re-initialises it *by design* — "the running session's
windows are gone and every live client is re-attached to an empty table". The
tree went 6 → 7 at `11ffe583`; the published desktop was 6. So the gate stood
up a healthy v6 desktop from packaged bytes, wiped it with its own v7 probe on
the first ctl read, and reported **`no full-width top bar`** against the
PACKAGES — while sitting in the publish path, before `index.json` is written.

Measured on `hamnix-desktop-1.0.17.tar.gz`, same bytes both times:

| probe | score |
|--|--|
| tree-built `wsys_poke` (v7) | **2 PASS / 1 FAIL** — `no full-width top bar` |
| the channel's own `cat` (v6) | **13 PASS / 0 FAIL** |

The same shape had already been found once and written into
`installed_update_wsysver.sh`: *"`cat /dev/wsys/2/ctl` is a wsys client … the
gate then photographed the wreck it had made and blamed the desktop."*
NORTH_STAR.md's rule is that a gap must never answer something success-shaped
instead of the truth; **a gate that manufactures a failure and bills it to the
packages is the same lie with the sign flipped.**

Two things followed:

* **The exclusion is gone.** There is no "except the test tool" case left. The
  window table is a FILE and `cat` is in the channel, so the probe is now the
  channel's own `cat`, and with `MOUSE_BIN_DIR` set this gate **compiles
  nothing at all** — no binary from this tree attaches to the segment.
  Version-matching `wsys_poke` would have removed today's instance; removing
  the tree binary removes the class.
* **And the skew is detected anyway**, because "nothing here is from the tree"
  is a property a future edit can lose quietly. `segstate` reads the first 24
  bytes of the shm segment **from the host with python3** — magic, version,
  focus, `next_wid`, desktop, gen, the prefix `linux-wsys.c` documents as
  byte-for-byte identical across v5/v6/v7. A plain file read attaches to
  nothing and cannot perturb what it is looking at. Three samples, three
  different questions: after `wsysd` (the session's version, stated out loud —
  `wsys v6 … bytes=19052956`); after the clients (a move here is a **MIXED
  CHANNEL**, the 1.0.10 shape, named as the packages' fault, and the run
  **stops** there because every pixel after a mid-run re-init is a photograph
  of wreckage); after the first ctl read (a move here can only be this gate's
  own instrument, and it says so and stops).

The first version of that last checkpoint printed *"fix the instrument"* about
an instrument that was fine, on the reconstructed 1.0.10 control — a red for
the right reason worded as a red for the wrong one, which is still the failure
this project keeps paying for. Hence the stop at checkpoint 2.

Scores, all measured: published 1.0.17 **13/0**; current tree **13/0**;
`channel_runs_desktop.sh` against the built channel **9/0** standalone and
**8/0** with `CHANRUN_NO_INDEX=1`, reporting the packaged desktop at 13/13 on a
**v6** session under a v7 tree. The reconstructed 1.0.10 mixed build
(`hamdesktop`/`hampanelscene` at `b3ecfb71^` beside a current `wsysd`) is
**2 PASS / 1 FAIL, exit 1**, and the FAIL now names the packages rather than
the top bar. With the fix reverted, the published bytes go back to
**2 PASS / 1 FAIL, `no full-width top bar`**.

**Found on the way, and now FIXED:** `scripts/hamlinux_build.sh` cached its
`.linux-*.o` objects **in the output directory**, one fixed name per object,
and invalidated them on the `.c` file's mtime. Building two different trees
into one output directory therefore linked the *first* tree's wsys backend
into the second tree's binaries, silently — the 1.0.10 mechanism, in the gate
lane rather than the packager lane, and the more dangerous of the two now that
agents work in parallel worktrees. It bit the first attempt at the negative
control above (a "current" `wsysd` that came out v5).

**The object's name now contains the sha256 of its inputs** — its own source,
plus a shared digest over every `user/linux-*.h`, the TLS flag, the build
script and the compiler's identity. Content, not mtime and not a path:
mtime cannot be the key (two files can share one; a checkout hands old content
a new timestamp; `-nt` is false on a tie), and a *path* key would have been
correct here while making every worktree recompile the runtime forever. Two
trees whose `linux-wsys.c` differ ask for two different filenames and cannot
collide however hard they share a directory; two trees whose sources are
byte-identical ask for the same filename and **share** it. Objects are renamed
into place, so four parallel workers cannot link a half-written one, and a
missing `sha256sum` is a loud refusal rather than a quiet fall back to mtime.
`HAMLINUX_OBJ_CACHE` can put the cache outside the output directory.

`tests/linux/build_obj_cache.sh`, **9 PASS**, offscreen, ~90 s. Two symlink
farms over the checkout differing in ONE FILE — `user/linux-wsys.c`, with
`#define WSYS_VERSION` moved down by two — the second backdated so the first
tree's object is newer than it (the ordinary case of two worktrees, where the
one checked out first builds second). Both build into one directory; then the
second tree's compositor is RUN and the version it stamped into the segment is
read with a 24-byte file read that attaches to nothing. **With the fix
reverted: 4 PASS / 4 FAIL, and the v7 tree's binary stamps v5.** Two
assertions that went green in that arm for reasons of their own are labelled
as what they are — one a discriminator against an *alternating* cache, one an
INFO because "no new object appeared" cannot be asked of a cache with one
entry per name.

**Cost, measured, both directions.** Warm path (the object already cached, the
path all ~366 builds of a sweep take): **0.1807 s → 0.1915 s per build**, mean
of three alternating rounds of 20 — **+10.8 ms, +6.0%**, which is two
`sha256sum`s, a `stat` and a `cat`. Cold full channel build, everything
rebuilt: **129.6 s → 128.1 s**, i.e. no measurable difference at all; both
produced 100 packages and a written index. The first version cost +46 ms
because it forked nine subshells and nine `basename`s on the warm path; the
hashing was never the expensive part, the processes were.

Every click is synthetic evdev — 24-byte `struct input_event` records appended
to `HAMWSYSD_INPUT`, parsed by `wsysd`'s own `pump_input` — and every assertion
is about what the chrome DID. It composes the real desktop (`wsysd` +
`hamdesktop` + `hampanelscene`), then: an evdev click on the Applications
button grows the panel window 26 → 206 px and paints the card (**87%** of the
card column is the dropdown body `#f7f8fa`); a second click closes it (back to
26 px, 0%); a click on the first desktop icon selects it (**59%** of the cell
is `#3584e4`); a click on the second icon MOVES the selection (65% / 0%), so it
cannot be satisfied by a desktop that highlighted everything at startup; and a
click whose move/press/release arrive in ONE evdev read still opens the menu.
Two controls run before any click at all: 0% card, 0% selection.

### And the gate CLICKING AWAY got

`tests/linux/de_focus_dismiss.sh`, **14 PASS**, offscreen, same rule: it never
pokes a ring (its last assertion greps itself, as `de_mouse_chrome.sh` does),
and `wsys_poke` appears only in reads — the window `ctl` lines and
`/dev/wsys/wsysd/state`. It opens the Applications menu with an evdev click,
then clicks the **wallpaper** at a point it has proved is inside the backdrop
window and below the grown panel, and asks whether the menu went away: the
panel window back to 26 px and 0% of the card column still the dropdown body.
Then it checks the panel is still reachable (the button re-opens the menu) and
that the path that already worked still works — a click on the menu's own
parent, the already-focused panel, where `set_focus` must emit nothing.

**The revert arm, and what it taught the file.** With `user/wsysd.ad` at
c515cae0 and the gate unchanged: **10 PASS / 2 FAIL**, `the panel window is
still 206 px tall, not 26` and `the card is still 87% painted after the click
on the wallpaper`. The first run of that arm also exposed two assertions that
were not measuring what they claimed, both since fixed:

* `wsysd moved focus panel → backdrop` **passed with the fix reverted**, and
  had to — wsysd always moved its private `focus_wid`, it just never said so,
  which *is* the defect. It is now labelled as what it is: a discriminator that
  rules out the other way the dismiss assertion could go green (the click was
  swallowed, or the panel died).
* The two follow-on assertions **failed in the revert arm for a reason that had
  nothing to do with them** — the menu was still open, so those clicks were an
  ordinary toggle. They are now gated on the away-click having actually
  dismissed, and report INFO when it did not. A question a run cannot answer
  must not be scored as an answer.

Green alongside it, unchanged: `de_mouse_chrome.sh` 13, `de_appmenu_band.sh`
11, `wsys_desktop_z.sh` 12, `wsys_title.sh` 23.

**Two revert arms, both run.** Drop the `route_pointer_event` call from
`deliver_pointer`: **6 PASS / 7 FAIL**, the panel still 1280x26 and the icon
0% selected after a full click. Drop only the button-edge flush from
`pump_input`: **12 PASS / 1 FAIL**, and the one that fails is the single-read
click — which is why that assertion is in the file rather than assumed.

### And the gate THE SHIPPED BYTES got — `tests/linux/channel_runs_desktop.sh`

**9 PASS / 0 FAIL against the 1.0.11 channel, 20 s, offscreen, no VM.**

The object-cache fix (563b0d96) closed the cause of the 1.0.10 mixed build.
This closes the hole that let it reach users, stated by the agent who found
it: *"every gate here builds from source through `hamlinux_build.sh`, so THE
ARTEFACT THAT SHIPS IS THE ONE ARTEFACT NOTHING RUNS."*

It takes the `.tar.gz` files under `build/repo/linux/packages/`, unpacks the
binaries out of them and runs those:

| Tier | What |
|--|--|
| Integrity | every needed package unpacks; **all 98** index entries hash to the bytes on disk, so what runs below is what an installed machine receives |
| The desktop | `wsysd` + `hamdesktop` + `hampanelscene` from the tarballs, driven through `de_mouse_chrome.sh`'s `MOUSE_BIN_DIR` hook — **13/13** under a synthetic evdev mouse |
| The floor | packaged `hamsh` sources an rc (PID 1 has something to exec); packaged `hpm` prints its verbs (the machine can still receive the NEXT fix); 8 packaged coreutils asserted on their real ANSWER, not exit 0 |
| The rule | the file greps itself for `hamlinux_build.sh` and fails if a future edit lets it compile anything it asserts on |

**Scope, and what is left out on purpose.** Not the other ~90 per-command
packages: the channel carries `halt`, `poweroff`, `reboot`, `rm`, `kill`,
`insmod`, `login`, `passwd`, `dhcpc`, `ntpd`, and executing those on the build
host is an incident, not a test. The defect class is *shared-input staleness*,
and the programs above link every backend between them, so a stale `lib/` or
`linux-*.c` surfaces here. Not a VM either — `HAMFB_FILE` and
`HAMWSYSD_INPUT` compose the whole desktop offscreen in 20 s, and 20 s is what
lets it sit in the publish path instead of a checklist.

**Where it sits: inside `scripts/hamlinux_packages.py`, BEFORE `index.json` is
written.** A channel that fails it has no index, so nothing can install from
it — the same shape as the duplicate-name and dangling-dependency refusals.
`--no-desktop-gate` exists, prints a paragraph saying what it is giving up,
and is used nowhere in this tree.

**The revert arm — the 1.0.10 mixture, rebuilt and packaged.** `b3ecfb71`
(19:03) is the commit: `WSYS_VERSION` 5 → 6 and `WSYS_MAX_WINDOWS` 128 → 256
in `user/linux-wsys.c`. So `hamdesktop` and `hampanelscene` were rebuilt at
`b3ecfb71^` and dropped into the `hamnix-desktop` tarball beside the current
`wsysd`, with the index's `sha256` and `size` corrected — exactly what
shipped, and exactly as verifiable.

```
chanrun: PASS all 98 packages in index.json hash to the bytes on disk -- what runs below is what an installed machine would receive
chanrun: PASS wsysd, hamdesktop, hampanelscene, hamsh and hpm came out of the channel's tarballs (nothing was compiled)
chanrun: PASS the desktop under test was the PACKAGED wsysd/hamdesktop/hampanelscene, not a fresh build
chanrun: FAIL THE PACKAGED DESKTOP IS BROKEN: de_mouse_chrome.sh scores 2 PASS / 1 FAIL against the bytes in this channel -- and these are the bytes 'hpm update' would install.
chanrun:      FAIL no full-width top bar -- there is no Applications button to click

chanrun: 8 passed, 1 failed
```

Exit status 1. And the control, on that same reconstructed channel:

```
$ tests/linux/channel_covers_image.sh build/image/root <the 1.0.10 mixture>
image /bin: 94    channel /bin: 98
PASS: every binary in the image is carried by a package (94 checked)
4 passed, 0 failed
```

The name gate is green on a channel that ships a desktop mapping no windows.
That is the hole, measured.

**And end to end through the packager.** Planting the two stale objects in
`build/repo-obj` — literally what the old one-input cache did — the packager
built all 98 packages, ran the gate, refused, and wrote **no `index.json`**
(exit 1, `ls` of the channel shows `packages` and nothing else).

One correction the arm forced, in `de_mouse_chrome.sh`: a binary
`MOUSE_BIN_DIR` did not hold used to fall through and be **compiled from the
tree**. That is a success-shaped answer to a different question — the caller
asked about somebody else's bytes. It now fails by name.

### And the gate THE UPDATE PATH got — `tests/linux/installed_update_live.sh`

The other half of NORTH_STAR.md's permanent rule. `channel_covers_image.sh`
gates work LEAVING here; nothing gated it ARRIVING — that a machine which
INSTALLED this distribution can `hpm update` off the real
`https://255.one/` and end up running the newer code.
`installed_update.sh` proves the mechanism against a LOCAL channel, and a
model of the repository cannot fail the way the repository can.

**The evidence is a mouse, not a version string.** Three boots on one
installed disk: install `hamnix-desktop` from a local channel at a version
DERIVED below the live one whose `wsysd` has the `route_pointer_event` call
reverted (the pre-1.0.10 machine, reconstructed — `MOUSE_BIN_DIR` against that
binary scores the same 6/7 as the revert arm above); boot it and click the
Applications button with a REAL pointer — QMP `input-send-event` on the
guest's `virtio-tablet`, read back as the panel window's own
`/dev/wsys/<wid>/ctl`; `hpm update`, no flags; reboot; click the same pixel.
No version number is written down against the live repository — publishing
1.0.8 once broke a test that did.

**Result, on the current channel: 28 PASS / 2 FAIL, and the 2 are real.**

| | |
|--|--|
| The old desktop under a real mouse | panel **26 px → 26 px**. Dead, exactly as 1.0.10's commit message describes — while the compositor's own counters move (`pointer 0 → 3`, `focus 0 → 3`), so it is the chrome that is inert and not a mouse that never arrived |
| A bare `hpm refresh` | **status 0** against `https://255.one/` — the shipped `/etc/hpm/trusted.pub` verifies the published `index.json.sig`, so the `--allow-unsigned` NOTE in `installed_update.sh` is closed |
| A bare `hpm update` | `upgrading hamnix-desktop 1.0.0 -> 1.0.10`, `SHA-256 verified`, `upgraded=3`, and `keeping this machine's own /etc/rc.boot` |
| The bytes | guest `md5sum /bin/wsysd` = **`52e8b468…`** = the digest the HOST computed from the tarball 255.one served. Survives the reboot. No index field can satisfy that |
| Boot 3, the point of the whole file | **no top bar.** The update landed and the desktop did not come up — see the first bullet under *What is HONESTLY BROKEN*. The delivery path works; what is being delivered does not |

Run the no-update arm and it is **21 PASS / 1 FAIL**, the FAIL being the one
sentence the file exists for: *"THE UPDATED MACHINE IS STILL RUNNING THE OLD
DESKTOP: after a real click the panel window is 26 px, not more than 26"* —
with the pointer proven delivered (`0 → 3` routed events) and the desktop
proven up (3 windows). Exit status 1.

**The did-not-update arm runs.** `HAMLINUX_LIVEUPD_NOUPDATE=1` does everything
except `hpm update`, so the green is a statement about the update having
happened rather than about the file reaching the end.

Two of this gate's own early answers were wrong in the way this project keeps
paying for and are written into it: it asserted phase 1's `rc.boot` digest
when phase 2's is the one running, and went red pointing at `hpm`, which had
behaved perfectly; and it read `pointer 0 → 0` on the zero-window boot as
"nothing was clicked" while the QMP transcript showed the click accepted —
`pointer` counts events routed TO A WINDOW, so `curframes` is the witness
there.

### And the gate A LIVE VERSION BUMP got — `tests/linux/installed_update_wsysver.sh`

**18 PASS / 0 FAIL / 2 FINDINGs, and the sentence it was built to check was
wrong.**
`user/linux-wsys.c` had said since version 5 that a segment version mismatch
"re-initialises that desktop's window table by design and always has", that
this is **LOUD** — "the windows go" — and that it is therefore the acceptable
answer. Run on a real installed UEFI+ext4 machine it is neither loud nor
acceptable:

| | |
|--|--|
| The update | `hpm update` exits **0**. Nothing between it finishing and the desktop vanishing mentions the window system, a session or a restart. |
| The next app opened | the screen becomes **3 distinct colours over 1,024,000 pixels** — a dark-blue slab and a mouse cursor — where the stage before had 1,474. `windows 0`. `/srv/wsys` 19,052,956 → 37,972,380 bytes. One run instead showed a single window titled *Terminal* painting the dead BACKDROP's wallpaper, because the new client took the dead backdrop's row. |
| The compositor | still running, still counting keystrokes, still routing them nowhere, and still holding `/dev/fb` — so the text console is not behind it. |
| The person | has no panel, no Applications button and nothing to click. On a physical machine the only control left is the power button. A reboot fixes it and nothing asks for one. |

A compositor that is up and painting nothing is exactly the success-shaped
answer NORTH_STAR.md forbids, so **the remedy stopped being unconditional.**
`shm_attach` now tells a **LEFTOVER** segment from a **LIVE** one and answers
them differently.

- **Live** — some running process still holds a row of that window table —
  means **REFUSE**: do not map it, do not punch it, do not `ftruncate` it,
  change not one byte, and print by name on stderr that the window system was
  updated underneath the session and the machine needs a reboot. The newly
  started program is the only casualty, which is the right thing to lose.
- **Leftover** — nobody holding a row — re-initialises exactly as before, so
  the first program after a boot still comes up.

**How they are told apart, and why it is not "is `wsysd` running".** Asking
after a process by NAME means `/proc`, a name that can be spoofed and a daemon
that may legitimately be called something else in a namespace. The question
that matters is narrower and the segment answers it itself: *does any row of
this window table belong to a process that is still alive?* The rows are read
with `pread(2)` — twelve bytes each, `used`/`wid`/`pid` — and the segment is
**never mapped**, so this is not the silent half-share the version counter
exists to prevent. A foreign segment's ROW COUNT is recovered from its SIZE,
which works because `struct wwin` (73,904), `struct wsink` (4,172) and `struct
wshm`'s prefix (28) are frozen across v5, v6 and v7 — asserted to the compiler
now, together with the two segment sizes, instead of only to the reader. A size
that does not decompose exactly is a layout this build has no business guessing
at, so it counts as not-live and the old behaviour stands: **this check may
never turn an unreadable segment into a refusal no reboot clears.**
`kill(pid, 0)` and not `/proc`; `EPERM` counts as alive. A recycled pid is the
one false positive available and it costs a refusal on a segment that could
have been cleared — the person reboots, which they were going to do anyway. The
opposite error costs a desktop. `HAMWSYS_FORCE_REINIT=1` is the escape hatch,
off unless set, and nothing in the rc scripts sets it.

**What the gate now asks, and every one of these was the OPPOSITE before:**

| STAGE C — the person opens one more app | |
|--|--|
| `/srv/wsys` | still **19,052,956** bytes. The whole fix in one number. |
| the screen | **1,459 distinct colours**, and **0 px** differ from STAGE B. |
| the window table | the same window count as at STAGE B, and non-zero. |
| what it said | the refusal, in full, by name, between markers bracketing that one command. |
| THE LEFTOVER CONTROL | same boot, seconds later: the PUBLISHED `cat` makes a v6 `/stale/wsys` and exits, and this tree's `cat` grows it **19,052,956 → 37,972,380**. Live and leftover shown being told apart, not asserted to be. |
| after a reboot | healthy on the new version, under a **real click** that opens the Applications menu (43,611 px, bbox 751×450) — **and the panel and the taskbar are back**, asserted as `visible` on wid 3 and wid 4 rather than as a pixel count a wallpaper could satisfy on its own. |

**WITH `user/linux-wsys.c` REVERTED** — a real `git checkout` of the parent
blob, rebuilt, repackaged and re-run, because `git stash push` on an
already-committed change stashes nothing and exits happy — the same gate is
**13 PASS / 4 FAIL**, red on exactly those questions: *the new binary
RE-INITIALISED the running session's window table: /srv/wsys is 37972380 bytes
(v7)*; *THE WHOLE SCREEN CHANGED when one app was opened: 1,023,239 of
1,024,000 px*; *the window table lost the session's windows: 0 at C against 4
at B*; and *the new binary attached (or failed) WITHOUT SAYING WHY*. (That arm
ran against the gate one commit before the panel check below was added; the
check is about STAGE D, which passed in that arm too, so it would be 14 PASS /
4 FAIL with it.)

**TWO DEFECTS THIS FOUND IN ITSELF, and one of them was in the fix:**

1. **A refusal that resized the segment.** `shm_attach`'s `fchmod` and
   `ftruncate` had always run before the header was even read, so the first
   version of the fix GREW `/srv/wsys` to 37,972,380 bytes and only then
   declined to attach. The desktop survived it whole — header untouched,
   screen pixel-identical, all four windows present — and the gate said FAIL
   anyway, correctly: the SIZE of that file is how it knows which window system
   a session IS, and a refusal that resizes it has destroyed exactly that. It
   also made the refusal's own words false. Both mutations moved below the
   decision.
2. **`HAMWSYS = /stale/wsys` is not a hamsh assignment.** hamsh parses the
   right-hand side as a NAME and the rc died with *undefined name
   '/stale/wsys' — glued arithmetic?*, aborting phase 2 before it installed
   phase 3; boot 3 then re-ran phase 2 on an already-updated disk and the
   reboot measurement was lost to a bug in a control taken AFTER it. It is
   `HAMWSYS='/stale/wsys'`, and the next boot is now armed BEFORE the control.
   While fixing it: the phase-1 heredoc is UNQUOTED and had a live
   `` `hpm update` `` inside a COMMENT, which ran ON THE HOST every time this
   gate started.

**WHAT IT DOES NOT FAIL ON, measured every run.** STAGE B — the desktop stops
answering the mouse the instant `hpm update` finishes, while the segment is
still v6 and nothing has been relaunched — is a SEPARATE defect and predates
this pass (STAGE B click 234 px against STAGE A's 43,658). The window table
names it precisely: wids **3 and 4**, the top panel and the bottom taskbar, go
`visible` **1 → 0** at STAGE B, coincident with `panel reloads: 2`. That
matched an offscreen diagnosis reached independently and is **fixed in the tree
at `d965f155`**: `ctl`'s `hide` matched by prefix and never read its argument,
so it set `visible = 0` unconditionally — and `hampanelscene`'s
`_reload_panels` writes **`hide 0`**, *show this window*, to every panel window
it is about to redraw. Every config reload withdrew every panel.

**IT STILL CANNOT PASS AT STAGE B, AND SHOULD NOT.** At STAGE B the panel
PROCESS is the pre-update binary: `hpm` replaced the file, not the running
program, and the fix cannot reach a process that is already running. That is
not an artefact of this harness — it is what every person on the published
version will experience exactly once, because the update carrying the fix is
the update whose config rewrite trips the old bug. So STAGE B and C clicks stay
FINDINGs, the survival evidence stays the segment, the pixels and the window
table (none of which needs the panel to answer), and the sentence that
distinguishes *hurt once* from *broken forever* is asserted where it can be:
after the reboot, `visible` on wid 3 and wid 4.

**WHAT THIS DOES NOT DO.** It does not make the old session keep working, and
it is not the second option the brief offered — a compositor that notices the
version changing under it and paints that on the screen. With refusal in place
no v7-or-later binary can perform the wipe, so the banner's remaining customers
are a DOWNGRADE to a pre-v7 build and `HAMWSYS_FORCE_REINIT`; it is a separate
pass with its own gate. And the refusal reaches the person through stderr —
the terminal they launched from, and `/var/log/panel.log` when the panel
spawned it — which is better than silence and is not yet a message on the
screen.

### And the gate THE RECOVERY got — `tests/linux/installed_recover_broken.sh`

**34 PASS / 0 FAIL. A machine that installed the BROKEN 1.0.10 runs
`hpm update` and comes back to a desktop that answers a real mouse.**

That claim had never been tested. 1.0.11 was published as the repair and
1.0.10's bytes were deliberately left on the channel (a machine that already
believes it has 1.0.10 would never fetch a silently corrected 1.0.10), so the
only question that matters to a person who took the bad update is whether the
ordinary command gets them out — and everything about it was plausible rather
than measured.

**Nothing is reconstructed here.** `installed_update_live.sh` builds its "old"
machine by reverting one line of `user/wsysd.ad`, which is the right
instrument for the defect *it* models. This gate installs **the genuine
published `hamnix-desktop-1.0.10.tar.gz` off 255.one**, with `hamnix-init` and
`hamnix-hamsh` at 1.0.10 beside it and each package's own `PKGINFO` as its
metadata. Only the *index* is rebuilt, because the channel keeps one index and
it has moved on; the tarballs are byte-for-byte what a person received, signed
and SHA-256-verified into the guest the same way a real install is.

**The failure half is asserted first and is allowed to refute the diagnosis.**
If 1.0.10 had come up working, the gate would go red on the spot and say the
premise did not hold, rather than letting a green recovery stand on it. It did
not come up working:

```
[rcvr] p2 WINS-BEFORE
cat: cannot open /dev/wsys/2/ctl: No such file or directory
cat: cannot open /dev/wsys/3/ctl: No such file or directory
cat: cannot open /dev/wsys/4/ctl: No such file or directory
[rcvr] p2 STATE-BEFORE:
focus 0 windows 0 inputs 3 keys 0 pointer 0 frames 125 curframes 0
52e8b468b425492067b339bc7017b868  /bin/wsysd
d662b390fcce48adfb2a3515bfc5c970  /bin/hampanelscene
9d7b27b4fa985dc0f766550ddbb04bc4  /bin/hamdesktop
```

`rc.5` had said `compositor started`, `panel started`, `desktop up` — and
`windows 0`. All three digests are the ones the HOST computed from the
tarballs 255.one served. The QMP click went in and `curframes 0 → 1` is the
witness that it arrived (`pointer` cannot speak on a boot with no windows).

**Then the recovery, on the same disk, nothing rebuilt:**

```
hpm: refreshed index from https://255.one/ (98 packages across 1 channels, 52100 bytes)
hpm: upgrading hamnix-desktop 1.0.10 -> 1.0.11
hpm: SHA-256 verified
hpm: keeping this machine's own /etc/rc.boot
hpm: update done (upgraded=3 pinned=0)
399df78a040b28d63bca38cc20263802  /bin/wsysd
80eabd3cd2730cdb27d972e866ddc470  /bin/hampanelscene
42812c3c0af475e025e67fdcf19c0b2f  /bin/hamdesktop

[rcvr] p3 WINS-BEFORE          [rcvr] p3 WINS-AFTER
2 0 0 1280 800 -1 …            2 0 0 1280 800 -1 …
3 0 0 1280  26 100 …           3 0 0 1280 250 100 …
4 0 774 1280 26 100 …          4 0 774 1280 26 100 …
focus 0 windows 3 pointer 0    focus 3 windows 3 pointer 3
```

**The top bar is back and a REAL pointer opens it: 26 px → 250 px**, with
`pointer 0 → 3` proving the click was routed to a window. All three digests
are the published 1.0.11 ones, and they survive the reboot — no index field
can satisfy that.

**Both halves are driven by QMP `input-send-event` on the guest's
`virtio-tablet-pci`.** Nothing in this file writes a wsys ring by hand; doing
that as the host owner is why a completely unclickable desktop went unnoticed
for the life of the port.

**Confirmed offscreen first, in seconds, on the published bytes alone** —
`MOUSE_BIN_DIR` against the unpacked tarballs: 1.0.10 is **2 PASS / 1 FAIL**
(`no full-width top bar — there is no Applications button to click`), 1.0.11
is **13 PASS / 0 FAIL** (panel 26 → 206 px under an evdev click). The VM arm
is what makes it a statement about an installed disk.

**No version is hard-coded against the live repository.** The current one is
read from `index.json` at run time; the known-broken one is the variable
`BROKENVER` (`HAMLINUX_RECOVER_BROKENVER`, default 1.0.10) because it is an
historical fact, not a claim about what is current. If the channel stops
serving 1.0.10's tarballs, or has nothing newer than it, the gate stops and
says which — it never substitutes a locally built lookalike, which would
answer a different question in the same shape.

**The did-not-update arm runs, and it goes red.** `HAMLINUX_RECOVER_NOUPDATE=1`
does everything except `hpm update`: **23 PASS / 1 FAIL, exit 1**, the FAIL
being the one sentence the file exists for. It also produced the OTHER
breakage shape on its own — boot 3 came up `windows 2`,
`(2 0 0 1280 800 -1 …)` the wallpaper and `(3 0 774 1280 26 100 …)` the BOTTOM
taskbar, top bar absent — so both shapes HANDOFF records for 1.0.10 turned up
across the two runs of this gate, from the published bytes, unprompted.

That arm's first run also printed a false sentence on top of a correct red:
the boot-3 verdict opened *"THE UPDATE LANDED AND THE DESKTOP DID NOT COME
BACK. The bytes arrived…"* in the arm where no update was run and no bytes
arrived. The premise now follows the arm. A red for the right reason worded
as a red for the wrong one is still the failure this project keeps paying
for.

### And the gate THE GATES got — `tests/linux/private_ns.sh`

**A gate that passes while corrupting the machine around it is the
success-shaped answer, and it was green throughout.**

`tests/linux/de_panel_conf_replace.sh` proved a real defect, scored 17 PASS,
and wrote **`/tmp/hamnix-panel.conf`** — which is not a scratch path.
`user/hampanelscene.ad`'s `_open_config` reads it *in preference to* the
shipped `/etc/panel.conf` and `user/hamsettings.ad` writes it: it is the
desktop's live runtime override, one fixed name shared by every process on the
host.

The cost is measured, not imagined. While that gate ran, **another agent's
independent offscreen run** of the published desktop binaries watched its
panel log `config reload applied: 2 panel(s)` then `1 panel(s)`, found its top
bar gone, and concluded it had reproduced a defect. It had observed this
gate's assertion 11 ("a config that drops to ONE panel must withdraw the
surplus window") landing in the middle of its run. That false reproduction was
relayed onward to a third agent as a finding. **One gate's scratch file cost
two agents' conclusions.**

**The fixed names are mostly not in the test scripts.** They are compiled into
the programs under test, so no amount of care in a gate can move them:

| program | fixed host-global names it writes |
|---|---|
| `hampanelscene` | `/tmp/hamnix-panel.conf` `…panel.health` `…panel.fault` `/tmp/hamnix-panel-drop` `/tmp/hamnix-notif.log` |
| `hamdesktop` | `/tmp/hamdesktop-wp.status` `/tmp/.hamdesktop.src` `/tmp/hamnix-panel-drop` |
| `hamctl` | `/tmp/hamnix-wallpaper.{ppm,conf}` `…-tz.conf` `…-{display,mouse,kbd,sound,net}.conf` |
| `hamsettings` | `/tmp/hamnix-wallpaper.ppm` `/tmp/hamnix-panel.conf` |
| `linux-wsys.c` | `/srv/wsys`, else `/dev/shm/hamnix-wsys`, else `/tmp/hamnix-wsys` (and `-bb`) |
| `linux-snarf.c` / `-audio` / `-net` / `-fdns` | `/srv/<name>`, else `/dev/shm/hamnix-<name>` |

Those last two rows are live on this machine today: `/dev/shm` holds
`hamnix-wsys`, `hamnix-wsys-bb`, `hamnix-net` and `hamnix-fdns`, and `/tmp`
holds a `hamnix-wsys-bb` owned by **uid 100000** — a userns-mapped uid from
somebody's earlier run. A gate that starts `wsysd` without setting `HAMWSYS`
attaches to *those*.

**The fix is at the namespace, not at the path.** `tests/linux/private_ns.sh`
re-execs the calling gate inside an unprivileged user + mount namespace where
`/tmp`, `/dev/shm` and `/srv` are each a fresh empty tmpfs of that run alone,
made after `mount --make-rprivate /` so nothing propagates back out, and taken
down by the kernel with the namespace — including on SIGKILL, which no trap
survives. Two lines in a gate:

```sh
. tests/linux/private_ns.sh
priv_ns_reexec "$@"          # FIRST -- before reap.sh, before $WORK
```

It **refuses by name** when the kernel will not provide the namespace, rather
than falling back to writing the machine. `HAMTEST_NO_PRIVNS=1` is the
deliberate, loud escape hatch. `$WORK` may stay under `/tmp`; for a `KEEP=1`
post-mortem, `priv_ns_keep` hands back a directory outside the shadowed paths.

**And it is proved, not asserted.** `tests/linux/private_ns_isolates.sh` runs
the incident as an experiment — a *second*, independent desktop up and reading
`/tmp/hamnix-panel.conf` while `de_panel_conf_replace.sh` replaces that file
four times beside it — and **calibrates the witness with a negative control**,
because a witness that survives by being unable to feel anything proves
nothing:

| | reloads the witness saw | its taskbar, in framebuffer pixels | its config marker |
|---|---|---|---|
| isolated | 0 → 0 | 81% → 81% | intact |
| `HAMTEST_NO_PRIVNS=1` | 0 → **6** | 81% → **0%** | **gone** |

That `81% → 0%` is the other agent's missing top bar, reproduced on demand.
Both experiments run inside an *outer* namespace of their own, so the control
reproduces the contamination without inflicting it on the machine, and the
host-leak assertion is by **identity** (a per-run tag), not by a count — its
first version failed on somebody *else's* concurrent file, and blaming this
run for another run's write is FAIL-shaped instead of true, the same sin in
the other direction. **7 PASS.**

**The gate still has teeth.** With `user/linux-wsys.c`'s `hide`/`show`
argument handling reverted (`git apply -R` of the fix, not `git stash push`,
which stashes nothing on an already-committed change and exits happy),
`de_panel_conf_replace.sh` scores **11 PASS / 6 FAIL** inside the namespace —
the same score it scored before it was isolated.

**And it refuses to come back.** `tests/linux/gates_are_private.sh` is the same
shape as `channel_covers_image.sh`'s packaging rule: a host-side gate that
starts the window system either isolates itself, or is named in that file's
`EXEMPT` table **with a reason** — an unlisted one FAILS, with the two lines
it needs printed in the failure. A stale exemption (a file that no longer
exists, or one since converted) fails too, so the list cannot quietly become
where unfinished things go to be forgotten. Both arms were demonstrated: a
planted unisolated gate scores 2/1, an exemption pointing at a deleted file
scores 1/2. It compiles nothing and runs in about a second, and it prints how
many exemptions are still only `NOT YET CONVERTED` so the green is never
mistaken for "all of them are private".

#### The survey: every host-side gate, and whether it is private — PAID DOWN

`gates_are_private.sh` used to end every run with *"16 of the 27 are exempt
only because nobody has converted and re-run them yet — this gate is green
with that debt named, not paid"*. **That line is gone: the count is 0.** The
gate now reads *28 host-side gates start the window system: 24 isolated,
4 exempt by name, 0 neither.*

Converted **and re-run**, because the exemption existed precisely because
nobody had re-run them. Score after isolation, and the score it had before
where one was on record:

| gate | after | before |
|---|---|---|
| `wsyswl_rootless.sh` | **37 PASS** | 37 |
| `wlsnarf_bridge.sh` | **35 PASS** | 35 |
| `wsyswl_conn_ceiling.sh` | **30 PASS** | 30 |
| `wsyswl_two_browsers.sh` | **24 PASS** | 24 |
| `wsys_title.sh` | **23 PASS** | 23 |
| `wsyswl_shared_fate.sh` | **18 PASS** | 18 |
| `wsyswl_wheel.sh` | **16 PASS** | — |
| `wsyswl_ceiling.sh` | **11 PASS** | 11 |
| `wsyswl_stall.sh` | **11 PASS** | — |
| `wsys_close_button.sh` | **10 PASS** | — |
| `x11_geom_probe.sh` | **9 PASS** | — |
| `channel_runs_desktop.sh` | **9 PASS** | — |
| `wsys_image.sh` | **8 PASS** | — |
| `input_probe.sh` | **ALL PASS** | — |

Already isolated, re-run as regressions against the helper's two changes
below: `private_ns_isolates` 7, `wsys_keychan` 14, `wsys_keyed` 8,
`de_appmenu_band` 11.

#### `$XDG_RUNTIME_DIR` — the caveat that shipped with the helper, closed

Eight of the exemptions said the same thing: *"`wsyswl`'s Wayland socket lands
in `XDG_RUNTIME_DIR`, which `private_ns.sh` does NOT shadow, so converting it
is necessary but not sufficient."* It is shadowed now, and it **keeps its
name**, so a gate that reads the variable and one that hardcodes
`/run/user/$(id -u)` both land on the same fresh tmpfs. Mode `0700`, not
`1777`, because a Wayland compositor checks that. Where it is unset the run
gets `/tmp/privns-run` inside the already-private tmpfs rather than falling
back on the machine's. `priv_ns_assert` REFUSES if it is neither a mount point
of its own nor inside the private `/tmp`.

Measured: inside the namespace `/run/user/1000` has **0** entries; a marker
written there does not appear among the host's **20**.

#### The id map — an isolation that made a gate lie, and the fix

`--map-root-user` maps exactly ONE id. `wsyswl_rootless.sh` converted with
that alone went **37 PASS → 12 PASS / 4 FAIL**, reproducibly, reading like a
compositor defect: *the X root has 1 children*, *the XWM manages 1 X windows*,
*windows_high_water is 1*, */dev/wsys lists 0 application windows*. A
standalone probe (Xvfb + two `xterm`s inside the namespace) found the cause:

```
xterm: Cannot chown /dev/pts/7 to 0,5: Invalid argument
```

and both clients dead — gid 5 (`tty`) is not in a one-id map. **That is the
NORTH STAR shape in the other direction**: a FAIL-shaped answer that was not
the truth, and an agent reading it would have gone hunting in `wsyswl`'s XWM.

So `priv_ns_reexec` now picks its map in three steps and says which it got:
`--map-auto` (needs `/etc/subuid`, `/etc/subgid` and setuid
`newuidmap`/`newgidmap`); failing that — the NESTED case, where `id -un` is
root and has no subuid line — a MIRROR of `/proc/self/{uid,gid}_map`, which a
process that is root in the namespace it is leaving may write; failing that,
the one-id map, named as such by `priv_ns_describe`.

#### And it is proved for the riskiest one — `tests/linux/rless_is_private.sh`

The same experiment `private_ns_isolates.sh` runs for
`de_panel_conf_replace.sh`, pointed at `wsyswl_rootless.sh`: a live desktop
with its own segment and framebuffer — so the only things it can share with
the gate are the fixed `/tmp` names and `/tmp/.X11-unix` — running while the
gate runs beside it. **8 PASS, 0 FAIL**, with a negative control that fires on
BOTH instruments:

| | isolated | `HAMTEST_NO_PRIVNS=1` |
|---|---|---|
| `/tmp/.hamdesktop.src` | marker intact | **MARKER GONE** |
| `/tmp/.X11-unix` peak, sampled *during* the run | 0 (from 0) | **2** (from 0) |
| witness's bars visible | 1 1 → 1 1 | 1 1 → 1 1 |
| witness's taskbar pixels | 81% → 81% | 81% → 81% |
| the gate's own score | 37 PASS | 37 PASS |

The gate scores the same 37 in both arms: the isolation changed nothing about
what it proves and everything about what it touches. The X-socket count had to
be sampled *while* the gate ran — a before/after pair reads 0 → 0 in both arms,
because the gate kills its X servers on the way out, and that is a witness that
cannot feel what it is pointed at.

#### Deliberately NOT isolated, each with the reason in the table

* **`wsys_uidgate.sh`** — its subject is the uid. `geteuid()` is 0 inside and
  `linux-wsys.c:1207`/`:1843` branch on it.
* **`wsys_bypass.sh`** — NEW, and measured: it builds its OWN user namespace
  for the uid split it is about (`unshare -U --map-users=0:$(id -u):1
  --map-users=1001:$SUB:1`, `$SUB` from `/etc/subuid` for `id -un`). Inside the
  helper's namespace `id -un` is root, `/etc/subuid` has no root line, and the
  gate correctly **SKIPs** — 47 PASS became 0. Its residue is the smallest on
  the list: one `mktemp` under `/tmp` holding `$HAMWSYS` and its derived `.bb`
  and `.chrome`, no `/srv`, no `/dev/shm`, no fixed `hamnix-*` name, no desktop
  client.
* **`runsweep_jail.sh`** — NOT a gate and already in a STRICTER jail.
  `hamlinux_runsweep.sh` runs it under `unshare -rmn --fork --pid --kill-child`
  before its first line, after which it `exec unshare --root=$MNT`s into an
  overlay root: its `/tmp`, `/dev/shm` and `/srv` are the per-program upper
  layer. It takes five positional arguments, not a gate's `"$@"`.
* **`private_ns_isolates.sh`**, **`rless_is_private.sh`** — they ARE the
  proofs; their last assertion has to see the real host.

#### One thing the record had wrong

The exemption for `channel_runs_desktop.sh` said it *"sets no `HAMWSYS` at all
— it takes `linux-wsys.c`'s `/srv`, then the `/dev/shm/hamnix-wsys` fallback"*.
**It does not.** It starts no compositor; it hands the unpacked binaries to
`de_mouse_chrome.sh`, which pins `HAMWSYS`, `HAMWSYS_BB`, `HAMWSYS_IMG` and
`HAMFB_FILE` into its own `$WORK` (`:146-150`) and is itself already isolated.
A witness desktop on the DEFAULT segment, run beside this gate with the
isolation switched **off**, saw its window table unchanged (3 windows → 3). It
is isolated anyway — "the delegate happens to pin its segment" is a property of
the delegate, not of this gate — and the note in the file now records what was
measured instead of what was assumed.

Still unsurveyed rather than exposed: `snarf_device.sh`, `snarf_serial.sh` and
`xsnarf_bridge.sh` set `HAMSNARF`, so the `/srv/snarf` and
`/dev/shm/hamnix-snarf` fallbacks should not fire; `gates_are_private.sh` does
not put them in scope because they start no compositor. `ac_ns_host.sh`,
`hpm_hook_bounded.sh` and `lex_error_fatal.sh` write `/tmp` paths only inside a
chroot/fixture root they made.

Everything under `qemu`/VM control writes inside the guest and is private by
construction.

### The Applications menu is Brisk-shaped, and it now SHIPS

The machine's owner asked for MATE's Brisk menu: a category submenu like the
panel's `Debian apps >`, a search box that filters as you type, and a
Favourites section at the top showing what has been launched recently.

**Nearly all of it was already written and reached nobody.**
`user/hamappmenu.ad` and the pure model behind it, `lib/appmenucore.ad`, have
the search row, the recency section and one hover fly-out per category.
hamappmenu was in neither `scripts/hamlinux_image.sh`'s `APPS` nor
`DESKTOP_CMDS` in `scripts/hamlinux_packages.py`, so `/bin/hamappmenu` existed
on no machine, `hampanelscene._appmenu_available()` returned 0 on every boot,
and the Applications button silently used the panel's own flat dropdown. That
is NORTH_STAR.md's worst bug shape twice over: a program in the tree and in no
ship vehicle, and a feature drawn correctly that could not run. Both lists now
carry it; `tests/linux/channel_covers_image.sh` **8 PASS / 0 FAIL** over a
freshly staged image root and a freshly built channel, with
`hamnix-desktop-*/files/bin/hamappmenu` in the tarball.

**And one thing genuinely did not work.** The menu is a separate process
spawned per click and killed on dismiss (`_am_close`), so `amc_mark_launch`
recorded the launch in module state microseconds before `sys_exit`. The
Favourites section was structurally incapable of ever holding anything: it laid
out, it rendered, and it was empty on every open, forever. It is now persisted
to **`$HOME/.hamde/favourites`**, resolved through `lib/homedir.ad` — the
user's own home, NOT a fixed `/tmp` name; `tests/linux/private_ns.sh` records
what one of those cost two agents. `lib/appmenucore.ad` gained the read-back
accessors (`amc_recent_prog`/`_len`) its own comment had already promised and
nothing could use. The section is labelled **Favourites** and holds the recency
list, which is the one thing the owner asked for, not two.

**The panel still degrades.** Absence was already handled. Present-but-broken
was not: a menu that starts and cannot get a window printed to a closed stderr
and died, and the button answered a click with nothing. hamappmenu now writes
`$HOME/.hamde/appmenu.fault` on window-allocation failure and removes it on
success; `_appmenu_available()` re-checks it on every call and falls back to
the dropdown the panel draws itself, saying so by name.

`tests/linux/de_appmenu_brisk.sh`, **17 PASS / 0 FAIL**, offscreen, private
namespace. Every click is synthetic evdev and **the search box is typed into
with real EV_KEY scancodes** (KEY_C/A/L, KEY_BACKSPACE) routed by wsysd's own
keymap to the focused window — the filter assertion is that the menu card stops
covering the wallpaper where its 6th row was, measured pixel for pixel against
a photograph of that rectangle taken before the menu existed (100% covered
before, 0% after). Same ring-rule guard as `de_mouse_chrome.sh`: nothing in the
file names an event, pointer or keys ring.

**Revert arm, run:** with `lib/appmenucore.ad`, `user/hamappmenu.ad` and
`user/hampanelscene.ad` restored, **14 PASS / 3 FAIL** — nothing persisted, a
fresh menu shows no Favourites section (row 1 is 0% header and 77% category
button, unchanged from the run with no history), and the menu that cannot open
a window exits 1 leaving no marker.

Two things the gate learned the hard way, both written into it: the failure
injection has to make **all three** of `shm_attach`'s segment candidates
(`$HAMWSYS`, `/dev/shm/hamnix-wsys`, `/tmp/hamnix-wsys`) unopenable — a
directory at each, since `open(2)` on one is EISDIR even for a namespace root
with CAP_DAC_OVERRIDE — because the first attempt let the menu build itself a
private window system nothing composites and hang for four minutes; and
`lib/homedir.ad` resolves to `/root` under the private namespace's mapped root,
so the gate mounts a fresh tmpfs there rather than measure a write that could
only fail.

#### And then it was booted, because "it is in the package list" and "a person
#### clicking Applications on a real machine gets it" are different claims

Only the first of those was proven, and the whole reason the menu was invisible
for months is that nobody checked the second. `tests/linux/de_appmenu_realboot.sh`
checks it: a UEFI + ESP + ext4 disk built from this tree, booted through OVMF,
and a **real pointer on `virtio-tablet-pci`** driven over QMP `input-send-event`
onto the Applications button. **16 PASS / 0 FAIL**, three boots of one disk,
~20 minutes.

The two menus are told apart **by their pixels and by the window table**, never
by a log line — the panel prints `launched /bin/hamappmenu -self` whether or not
a window ever appears, and that is exactly the success-shaped claim that hid the
bug. Measured on the real machine:

| | new (hamappmenu) | old (in-panel dropdown) |
|--|--|--|
| window | **wid 5 at (8,28), 407×140**, panel still 26 px | **no new window**; the PANEL grows 26 → **206 px** |
| row 0 | **70%** the white search field | 0% |
| row 1 | **77%** the category-button strip | 0% |

`fil` typed on `virtio-keyboard-pci` took row 6 from **3008 of 3008** covered
pixels back to **0** and regrouped row 1 into an **88%** section header, so the
search box filters on a real boot and not only in the offscreen harness, where
the keystrokes are records in a file rather than a device.

**Favourites are proven across a POWER CYCLE, not a process.** ARM NEW launches
from the menu and reboots; ARM FAV boots the same disk and the **first click of
the new boot** has an **85%** section header in row 1 — `Favourites / Files` —
where the machine with no history had **0%** header and 77% category button.

**The arm that must fail, and does:** ARM FAV's boot ends by moving
`/bin/hamappmenu` aside and rebooting, re-creating exactly the machine everybody
had before the fix. Same click, same hand: no window at (8,28), 0% search field,
0% category strip, the panel's own window at 206 px, and
`[panel] no /bin/hamappmenu; Applications button -> the panel's own dropdown`.

Three things came out of the real boot that no offscreen gate could have seen,
all reported rather than hidden:

- **`/etc/hamde/apps` is on NO hamnix-linux machine.** (**FIXED** — see the
  next section; it was three faults deep, not the one line it reads as.)
  `scripts/hamlinux_image.sh`
  stages `/etc` with `for f in … hamde …; do [ -f "etc/$f" ] && install …`, and
  `etc/hamde` is a **directory**, so `[ -f ]` is false and the 26 shipped
  `.desktop` launchers never land. Both menus therefore run off hamappmenu's
  built-in `_seed_fallback()` list, **8 of whose 11 entries name programs that
  are not installed** (`/bin/calculator`, `/bin/hamterm`, `/bin/hamedit`, …).
  Clicking one of those eight is a menu entry that does nothing. This is the
  same shape as the bug above it, one level further out: the feature ships, and
  the DATA it needs does not.
- **Two runs in four froze after launching from the menu**, and the same
  measurement told the two cases apart every time. (**FIXED** — hamfm parks;
  see the next section for the sampled numbers with and without the change.) The fallback list's Files is
  `/bin/hamfm`, the TUI (the shipped `files.desktop` says `/bin/hamfmscene`,
  which is not on the image either). When it lands in state **R with 2:02 of
  CPU** — 100% of a core, a TUI with no terminal — the screen stops changing:
  2nd click 0 px, 3rd click 0 px, the clock does not advance, the panel logs
  one spawn for three clicks. When it lands in **S with 0:00** the menu reopens
  on the 2nd click and toggles shut on the 3rd. Four runs, four times that
  correlation held. The gate prints the numbers every run rather than asserting
  either outcome.
- **`ls` given a REGULAR FILE prints its CONTENTS**, exit 0. A probe that said
  `ls -l /bin/hamappmenu` put 450 KB of ELF on the serial console three times.

Green alongside it, unchanged: `de_mouse_chrome.sh` 13 (measured against the
PACKAGED bytes by `channel_runs_desktop.sh`), `de_appmenu_band.sh` 11,
`de_focus_dismiss.sh` 14, `de_panel_conf_replace.sh` 17,
`de_panel_conf_shipped.sh` 15, `wsys_desktop_z.sh` 12, `gates_are_private.sh`
3.

### The menu lists applications that are on the machine, and hamfm no longer
### freezes the desktop

Both defects the real boot above reported are fixed, and the first of them was
**three faults deep**, not the one line it was reported as.

**1. `/etc/hamde/apps` was on no machine.** `scripts/hamlinux_image.sh` staged
`/etc` by iterating a list and testing `[ -f "etc/$f" ]`; the list contained
`hamde`, a **directory**, for which `-f` is false. Staging it is one line. It
is not the fix:

- **The channel has to carry the launchers**, or `tests/linux/channel_covers_image.sh`
  goes red — it walks the whole image root, and a file in the initramfs and in
  no package is a file an installed machine can never receive a fix to. Checked
  by running it, not by reading it.
- **The programs have to exist.** Of the 26 launchers' `Exec` targets, exactly
  **THREE** were in the image's `APPS` — `hamtermscene`, `hameditscene`,
  `haminstallui`. A correctly staged catalogue and nothing else would have
  produced a **three-row** Applications menu on a distribution with 26 desktop
  applications in its tree, every one of which builds (`hamlinux_sweep.sh`: 363
  of 363) and every one of which the run sweep already drives. All 23 are in
  the image now.
- **And they did not fit in a package.** Put into `hamnix-desktop`,
  `scripts/hamlinux_packages.py` **refused to publish it**: *tar.gz 7,431,064 B
  / cap 4,194,304, inflated 16,220,160 B / cap 8,388,608* — hpm unpacks
  entirely in RAM through two fixed arrays. So it is **one package per
  application** (`hamnix-app-<cmd>`, generated from the launcher files), a
  `hamnix-apps` metapackage in `hamnix-base`'s closure, and **each package
  carries the launcher beside the program it launches**. That pairing is worth
  more than the size fix: the defect this whole pass is about is a launcher and
  its program living in different places with one of them missing, and paired
  in one package it cannot happen — `hpm remove hamnix-app-hamchessscene` takes
  the chess program and the chess row off the menu together.

**2. The menu is honest about what it lists.** A launcher whose program is not
on the machine is **dropped from the menu AND NAMED** on the panel's own
stdout as `appmenu-missing <Name> <prog>` — the shape `hamdesktop` already uses
for `icon-unknown`. Hidden rather than greyed out, deliberately: a disabled row
is the right answer for an optional package you could go and install, and the
wrong one for a name that exists nowhere in the distribution, which is a
packaging fault and not a user choice. **The click is guarded too**, because
the scan cannot be the whole answer — `spawn_detached` FORKS, so `fork(2)`
succeeds, `execve(2)` fails in the child, and the panel used to log
`[panel] launched /bin/hamview` for a program that never ran. It now refuses
by name: `[panel] LAUNCH FAILED <prog>: not installed`. Distribution launchers
are NOT judged — they name programs inside a namespace this process cannot see.

The compiled-in fallback lists are corrected rather than probed, and the reason
is written down where they are: a probe that can empty the fallback defeats the
only thing it is for (the DE is never menu-less), and the case it runs in is by
definition a root nobody staged. Those rows are made honest at the click. Five
of hamappmenu's eleven were wrong — including **`/bin/hamfm`, the console TUI**,
where the shipped `files.desktop` has always said `/bin/hamfmscene`.

**3. `hamfm` parks instead of spinning.** `if n == 0: sys_yield(); continue` —
a TUI has nothing to draw between keystrokes, so on a machine where nobody is
typing into it (every machine, since the desktop launched it behind a graphical
session) `sys_read_nb` answers *nothing yet* for ever and the yield turns that
into a full core. It is the **27th** instance of THE IDLE CENSUS shape, and the
census missed it because the run sweep exits `hamfm` before it reaches that
loop. It parks in `sys_waitfds` on fd 0. **Park and not exit-on-no-terminal**:
it already exits when there is no terminal (`sys_read_nb` returns a negative on
true EOF), and an inherited console fd cannot tell *no terminal* from *a
terminal nobody is typing into* — guessing there would kill a working session.

**THE GATES, and what they measure that nothing did before.**

- `tests/linux/de_appmenu_installed.sh` — **10 PASS**. Reads the STAGED IMAGE
  ROOT, not the repository (the whole defect was that the tree had 26 launchers
  and every machine had zero, so a gate that counts the tree agrees with the
  defect), then BOOTS it with one launcher's program deliberately removed. The
  panel reports **24** entries — 26 launchers, minus the live-only installer on
  a non-installer boot, minus the one whose program is gone — names it
  (`appmenu-missing Chess /bin/hamchessscene`), and refuses
  `/bin/nosuchprogram` by name. **Reverted: 2 PASS / 10 FAIL** — 26 of 26
  launchers absent from the image, 23 of 26 naming a program it does not build,
  the menu at **8** entries, nothing named, and `[panel] launched
  /bin/nosuchprogram` printed for a program that does not exist.
- `tests/linux/de_idle_cpu.sh` — **phase C**, and this gate needed it: it
  measured the desktop as rc.5 leaves it and one terminal its own rc line
  opened. **Nothing in it had ever come off the menu**, which is the point of
  having one, so a defect arriving only that way was out of its reach. Phase C
  launches through `/dev/wsys/appmenu/launch`, the queue the menu writes and
  the panel reads. **ALL PASS**: host QEMU 6.5% / 7.1% / **7.2%**, hamfm in
  state **S with 0:00**. **With `user/hamfm.ad` reverted: SOME FAILED** —
  `hamfm R 20.0s -> 100.0% of one cpu`, host QEMU **102.7%**, with phases A and
  B unchanged at 6.3% and 9.4%. CPU is a delta of `TIME` over a stated window
  on the guest and of `/proc/<qemu>/stat` on the host; `ps` pcpu is a lifetime
  average and is not used.

**TWO GATES WERE GREEN ON THE WRONG ANSWER, and both are the reason to check.**
`de_appmenu_brisk.sh` asserted the favourites file names `/bin/calculator` — a
program **no image builds** — so it was green about a menu row that could not
launch anything anywhere, and went red the moment the row was corrected. It
reads the expected program out of `user/hamappmenu.ad` now. And
`channel_covers_image.sh` computed its `/etc` difference count as
`$(grep -c . f || echo 0)`, and `grep -c .` on a **missing** file prints `0`
and exits `1`, so on the clean path the variable was the two-line string
`0\n0` and `[ "0\n0" -gt 0 ]` was not false but an **error** — which fell
through to the PASS branch. That comparison was decided by a shell error every
time it was clean.

`de_appmenu_realboot.sh`'s `LAUNCH_PROG` was the literal `/bin/hamfm`, so its
one launch was simultaneously the thing under test and the thing breaking the
test. It is read out of `files.desktop`.

**THE SCREENSHOT**, which is what the owner asked for:
`docs/screenshots/linux/appmenu-installed-apps.png` and
`-flyout.png`, taken by `scripts/hamlinux_shot_appmenu.sh` — a real boot, a
real pointer on the Applications button over QMP `input-send-event`, and the
QEMU screendump of the scanned-out surface. Seven categories including
**Office** and **Sound & Video**, which the fallback list never had, and an
Accessories fly-out listing Calculator, Screenshot, Editor, Notes and Files.

**AND A THIRD GATE WAS ABOUT TO GO SOFT-GREEN, in the same family.**
`de_appmenu_realboot.sh`'s `panelwin()` selected the panel's window with
`$5 < 400` — a bound put there to keep the desktop backdrop (also full-width
and top-anchored, at 1280x800) out of the answer, when the ARM OLD panel grew
to ~206 px to hold the flat dropdown. With the catalogue staged that dropdown
holds 25 rows and the panel grows to **580**, so the filter stopped matching,
`panelwin` returned nothing, and the assertion reading it **degraded to an
INFO line**: 16 PASS became 15 *with nothing red*. The height is the answer,
so it must not be in the question; the backdrop is excluded by its Z (-1 by
construction) instead. **16 PASS / 0 FAIL**, and its favourites file names
`/bin/hamfmscene` — the WINDOWED file manager, which is what a click reaches
now.

Green alongside: `de_appmenu_realboot.sh` **16**, `de_appmenu_brisk.sh` **17**,
`de_icons_distinct.sh` **15**, `de_mouse_chrome.sh` **13**,
`channel_covers_image.sh` **8** (331 image files, 804 channel files, 41
excluded by name), `gates_are_private.sh` **3**, and the channel builds
**124 packages** with `channel_runs_desktop.sh` and
`channel_compiles_adder.sh` green inside it.

### Running it

```
scripts/hamlinux_image.sh          # initramfs + kernel
scripts/hamlinux_vm.sh gpu         # boot it with a display
scripts/hamlinux_disk.sh           # an INSTALLED disk (GPT + ESP + ext4)
scripts/hamlinux_vm.sh disk-gpu    # boot the installed disk through UEFI
scripts/hamlinux_distro.sh         # the Debian namespace (Firefox lives here)
scripts/hamlinux_alpine.sh         # the Alpine namespace (HAMLINUX_ALPINE_GUI=0 for 26 MiB)
scripts/hamlinux_packages.py       # build the `linux` hpm channel
scripts/hamlinux_shot.sh out.png   # boot and screendump in one command
scripts/hamlinux_shot_appmenu.sh <imgdir> out.png   # ... with the Applications menu OPEN
tests/linux/*.sh, tests/linux/*_probe.ad
```

Host packages this needs, beyond the original list: `mmdebstrap`,
`dosfstools`, `e2fsprogs`, `gdisk`, `parted`, `mtools`, `systemd-boot-efi`,
`ovmf`, `socat`.

---

## 1. What Hamnix is, and why this repo exists

Hamnix 1.0 is a from-scratch x86_64 operating system written entirely in
**Adder**, a Python-shaped systems language with a hand-written x86_64 backend
and a self-hosted compiler. There are **zero lines of C in the kernel**. Its
syscall layer is Plan 9-shaped rather than POSIX-shaped: resources are file
trees, not syscall families. Networking is `/net`, windows are `/dev/wsys`,
processes assemble their own private namespaces with `bind`. A Linux ABI shim
lets real Debian binaries run in a Linux namespace alongside it. It is released,
tagged `v1.0`, and published at 255.one.

The purity is the point, and it is also the ceiling: Hamnix must write every
driver itself. No Wi-Fi, no GPU, no modern browser, not for years.

This repository is the second line. Same Adder userland, running on the **Linux
kernel with glibc**, so that drivers, Wi-Fi, GPU and a real browser come for
free. Hamnix 1.0 keeps its version number and its purity claim; this is a
sibling, not a successor — Debian GNU/Hurd to Debian, not Debian 12 to Debian 11.

**Your job is the port. Nothing here compiles yet, by design.** The code was
copied across unchanged so the port stays a reviewable diff.

---

## 2. What was copied, and what was left behind

Copied from `HamnixOS/Hamnix` with `git-filter-repo`, full history preserved
(3,789 commits), original paths kept verbatim so patches cherry-pick cleanly
between the two repos:

| Path | Contents |
|--|--|
| `user/` | 277 applications (~180k lines) incl. `hamsh.ad` (17.6k lines), `hamUId.ad` (31.2k, the compositor), `hpm.ad` (8.2k, package manager); plus `linux-runtime.S`, `runtime.S`, `syscall_nums.h`, `*.lds` |
| `lib/` | 167 modules (~162k lines): `hamui.ad` toolkit, `web/` (42 files — a from-scratch HTML/CSS/JS engine), `vk/` (Vulkan), codecs, crypto |
| `scripts/` | 1,811 files of build and test glue |
| `tests/` | 162 entries of fixtures and gates |
| `docs/` | 188 design documents |
| `etc/`, `fonts/`, `Sounds/`, `examples/` | userland data |

**Deliberately left behind** (they are Hamnix 1.0's, and are what Linux
replaces):

`kernel/`, `arch/`, `mm/`, `fs/`, `drivers/`, `sys/` (the Plan 9 device
drivers — `sys/src/9/port/dev*.ad`), `linux_abi/`, `net/`, `init/`, `mod/`,
`kernel-modules/`, and the built `.img` artifacts.

Two of those you will need to *read* constantly, from the Hamnix repo, because
they are the specification for the file servers you must reimplement:

- **`drivers/net/devnet.ad`** — the `/net` file tree.
- **`sys/src/9/port/devwsys.ad`** — the `/dev/wsys` window file server.

The Adder compiler is **not** copied; it is a submodule at `adder/`
(see README).

### Already true, and better than you would expect

Three things are already done, and they change the shape of the job:

1. **`--target=x86_64-linux` is a working compiler target.** It emits a static,
   no-libc Linux ELF. It is used every day for host-side testing.
2. **`user/linux-runtime.S`** (543 lines) is a Linux link runtime mapping
   `sys_*` onto real Linux syscalls. About 31 entry points are genuinely
   implemented.
3. **84 `*_host.ad` harnesses already run parts of this userland on Linux**, and
   `scripts/net9_host_shim.c` (13.5 KB) is a **working `/net` file-server shim
   backed by real Linux sockets and OpenSSL**. `user/net9_host.ad` fetches a
   live HTTPS page through completely unmodified `http9.ad` + `net9.ad`. The
   central architectural question of this port already has a working prototype
   in-tree. See §3.

---

## 3. The `/net` problem

> **ANSWERED 2026-08-09 — see §0.** `/net` is a file tree served out of shared
> memory (`user/linux-net.c`). §3.3's constraint is exactly why: a connection
> number has to mean the same thing in two processes, so the TABLE is shared
> and the number is what crosses. TCP, UDP, ICMP, `announce`/`accept`, and TLS
> via the `tls <host>` ctl verb. Measured: `curl https://255.one/` and `hpm`
> installing 61 packages, both unmodified.


Hamnix has **no BSD socket syscalls at all**. `SYS_SOCKET`, `CONNECT`,
`BIND_SOCK`, `LISTEN_SOCK`, `ACCEPT_SOCK` and `SYS_TLS_CONNECT` were all
retired. TCP, UDP, ICMP and TLS are a **file tree**. On Linux that tree has to
become a userspace file server — 9p, FUSE, or a shim library that intercepts the
`sys_open`/`sys_read`/`sys_write` entry points. This section is the inventory
that lets you choose; it does not choose for you.

### 3.1 The good news: it funnels through one file

`user/net9.ad` (~450 lines) is the sole client-side implementation of the `/net`
dance. Almost every network consumer goes through it, and treats the result as
an ordinary stream fd.

```
user/net9.ad
  ├── user/http9.ad   (HTTP/1.1 + chunked + TLS over net9)
  │     ├── user/curl.ad, user/wget.ad, user/hpm.ad
  │     ├── user/hambrowse.ad + hambrowse_{host,probe_host,sdl_host}.ad
  │     ├── lib/htmlengine.ad, lib/httpchunk.ad
  │     └── lib/web/{css/cascade,dom/canvas,js/api,js/state,js/consts}.ad
  │         lib/web/js/builtins/{fetch,xhr}.ad
  ├── user/sshd.ad, user/ssh.ad
  ├── user/httpd.ad, user/httpd_worker.ad, user/u_server.ad
  ├── user/ping.ad, user/u_tlstest.ad
  └── user/x11/{x11srv,xclient_demo,xfill}.ad
```

`user/ntpd.ad` is the **one bypass**: it opens `/net/udp/...` directly and does
not use `net9.ad`.

### 3.2 Every `/net` path literal in the copied tree

Exhaustive. There are eleven.

> **VERIFIED — accurate, every entry, including the line numbers.** A sweep for
> `"/net/...` string literals across `user/` and `lib/` returns exactly these
> eleven paths at exactly these lines. The only additional hits are
> documentation strings inside comments (`"/net/tcp/<N>/<leaf>"` and friends at
> `net9.ad:40,78,96,159` and `ntpd.ad:55,100`), which are format templates, not
> paths. Nothing here needs correcting.

| File:line | Literal | Purpose |
|--|--|--|
| `user/net9.ad:151` | `/net/tcp/clone` | `net_dial` |
| `user/net9.ad:220` | `/net/tcp/clone` | `net_dial_tls` |
| `user/net9.ad:291` | `/net/tcp/clone` | `net_announce` (listen) |
| `user/net9.ad:79` | `/net/tcp/` prefix | builds `/net/tcp/<N>/<leaf>` |
| `user/net9.ad:442` | `/net/icmp/clone` | `ping` |
| `user/net9.ad:102` | `/net/icmp/` prefix | builds `/net/icmp/<N>/<leaf>` |
| `user/ntpd.ad:216` | `/net/udp/clone` | NTP, bypasses net9 |
| `user/ntpd.ad:101` | `/net/udp/` prefix | builds `/net/udp/<N>/<leaf>` |
| `user/hampanel.ad:429` | `/net/ipifc/ctl` | panel link-status read |
| `user/haminstallui.ad:382` | `/net/ipifc/ctl` | installer link-status read |
| `user/hamUId.ad:21967` | `/net/addr` | compositor reads the host address |

### 3.3 Every operation performed on the tree

**Connection lifecycle (TCP).** `net_dial` at `user/net9.ad:139`:

1. `sys_open("/net/tcp/clone")` → read back an ASCII decimal connection number
   `N` (parser at `user/net9.ad:118`).
2. `sys_open_write("/net/tcp/<N>/ctl")` → write `connect <a.b.c.d>!<port>`.
3. `sys_open_write("/net/tcp/<N>/data")` → this fd **is** the stream.
4. Close `clone` and `ctl`. The `data` fd alone holds the connection open;
   `sys_close` on it sends FIN.

**TLS.** `net_dial_tls` at `user/net9.ad:200` does the same, then additionally
writes `tls <hostname>` to `ctl`. That runs a **TLS 1.3 handshake inside the
kernel**; afterwards the `data` fd is transparently encrypted/decrypted by the
kernel record layer. There is no userspace TLS state machine to reuse — on Linux
this must become OpenSSL/rustls somewhere, and the `ctl` verb has to drive it.
The 253-byte SNI hostname is why `net9.ad`'s command buffer is 320 bytes.

**Listening.** `net_announce` at `user/net9.ad:285` writes `announce <port>` to
`ctl`. `net_accept` (`:329`) and `net_accept_conn` (`:367`) write `accept` and
read a new connection number. `net_open_conn_data` (`:407`) opens
`/net/tcp/<conn>/data` for a connection accepted by another process — this is
how `user/httpd.ad` hands work to `user/httpd_worker.ad`, and it means **a
connection must be addressable across process boundaries by integer**. A shim
library holding per-process socket state cannot express this; a real file server
can. This is the single sharpest constraint on your design choice.

**ICMP.** `user/net9.ad:417` onward. `/net/icmp/clone`, then
`connect <a.b.c.d>` or `connect <a.b.c.d>!<id>` (RFC 792 identifier, *not* a
port), then a `data` fd plus a separately-reopened `status` fd read once per
ping for a fresh snapshot.

**UDP.** `user/ntpd.ad:210`. `/net/udp/clone` → `connect <a.b.c.d>!123` →
`data`, write 48-byte NTPv3 request, read reply.

**Observed ctl verbs, complete:** `connect <ip>!<port>`, `connect <ip>`,
`connect <ip>!<id>`, `announce <port>`, `accept`, `tls <host>`, `hangup`.

**Interface configuration** is *not* on the file tree — it is a syscall,
`sys_netcfg(op, a1, a2)`, with ops 0=read config, 1=set addr/mask, 2=set
gateway, 3=set DNS, 5=enumerate routes. Callers: `user/ifconfig.ad:145,284,297,310`,
`user/route.ad:130,191,195,246`, `user/hamctl.ad`.

**DNS** is also a syscall, not a file: `sys_resolve(hostname, len) -> int64`
returning a packed big-endian IPv4. Callers: `user/http9.ad:306`,
`user/ntpd.ad:182`, `user/ping.ad:181`, `user/host.ad:140`. Plus
`sys_resolve_ptr` (reverse) used once.

### 3.4 The prototype that already exists

`scripts/net9_host_shim.c` implements exactly this contract on Linux today. It
interposes `sys_open` / `sys_open_write` / `sys_read` / `sys_write` /
`sys_close`, hands back synthetic fds above a fixed base for `/net/*` paths,
passes everything else through to the real Linux calls, parses the `ctl` verbs
(`ctl_command`, `:199`), and backs them with real sockets and OpenSSL. It also
implements `sys_resolve` over `getaddrinfo` (`:339`).

It is a **shim library**, which is the third of your three options — and it is
already known to work for the client path end-to-end against live HTTPS sites.
What it does *not* do is `announce`/`accept` across process boundaries
(§3.3), which is the case that argues for a real file server. Read it before
you decide; do not assume it settles the question.

---

## 4. Every other native-only surface

### 4.1 The syscall gap, exactly

> **VERIFIED 2026-08-09, with one class substantially wrong.** The headline
> counts hold exactly: userland declares **71** distinct `sys_*` entry points
> (`extern def` across `user/` and `lib/`), `user/linux-runtime.S` defines
> **49**, **23** are missing, and **18** share the fail-closed body. Class (a)
> below did not survive contact: it claimed ~31 genuinely implemented, and only
> **20** actually issue a syscall. Corrected in place.
>
> Much of this section has since been *closed* rather than merely corrected —
> see §4.1d.

`user/linux-runtime.S` is the Linux link runtime. Userland declares **71**
distinct `sys_*` entry points; the runtime defines **49**. Classifying every
definition body in that file:

**(a) Genuinely implemented — 20, not 31.** `sys_read`, `sys_write`,
`sys_open`, `sys_open3`, `sys_open_write`, `sys_close`, `sys_lseek`,
`sys_mkdir`, `sys_unlink`, `sys_dup`, `sys_dup2`, `sys_getcwd`, `sys_chdir`,
`sys_getuid`, `sys_yield`, `sys_setpgid`, `sys_mmap`, `sys_munmap`,
`sys_read_nb`, `sys_exit`.

**(a2) Return a constant, doing nothing — 3.** `sys_errstr` (always writes the
empty string), `sys_nsid` (0), `sys_get_jiffies` (0). These link and "succeed",
which is worse than failing: `sys_errstr` is why every diagnostic in the tree
printed `cannot open X: ` with nothing after the colon.

**(a3) Listed above as implemented, but actually `return -1` — 8.** `sys_rfork`,
`sys_execve_env`, `sys_fdbind`, `sys_chan_dir_mode`, `sys_listdir_records`,
`sys_stat_p9`, `sys_resolve`, `sys_fdslot_kind`.

**`sys_rfork` is the one that matters.** §8's step 2 — "add `sys_waitpid` and
`sys_tcsetpgrp`, get `hamsh` running" — could not have worked as written:
reaping a child is useless while the call that *creates* the child fails. The
real fail-closed count was 26 (18 + these 8), not 18.

**(b) Present but fail-closed — `return -1` (18).** These are the Plan 9
surface, and they are the port. `user/linux-runtime.S:484` onward:

> `sys_bind`, `sys_mount`, `sys_unmount`, `sys_nslabel`, `sys_srv_open`,
> `sys_openchan`, `sys_pipechan`, `sys_fdslot_arg`, `sys_svc_publish`,
> `sys_svc_ctl`, `sys_setuid`, `sys_setuid_auth`, `sys_pgrp_kill`,
> `sys_tcsetpgrp`, `sys_waitpid`, `sys_waitpid_jc`, `sys_waitpid_nb_raw`,
> `sys_waitfds`

Note `sys_waitpid` and `sys_tcsetpgrp` in that list: **`hamsh` cannot reap a
child or run job control on Linux today.** Those two are cheap (`wait4`,
`tcsetpgrp`) and unblock the shell. Do them first.

**(c) Declared by userland, absent from the runtime entirely — these are link
errors, not stubs (23).**

> `sys_execve`, `sys_pipe`, `sys_getpid`, `sys_getgid`, `sys_link`,
> `sys_symlink`, `sys_clock_gettime`, `sys_socketpair`, `sys_netcfg`,
> `sys_resolve_ptr`, `sys_rfork_thread`, `sys_semacquire`, `sys_semrelease`,
> `sys_setexitsem`, `sys_set_realtime`, `sys_srv_post`, `sys_useradd_root`,
> `sys_wsys_alloc`, `sys_wsys_free`, `sys_vk_window_frame`,
> `sys_umdf_mmio_map`, `sys_umdf_irq_open`, `sys_umdf_dma_alloc`

Most of class (c) is trivially POSIX (`execve`, `pipe2`, `getpid`, `getgid`,
`link`, `symlink`, `clock_gettime`, `socketpair`). The `sys_umdf_*` three are
userspace-driver MMIO/IRQ/DMA and should simply be **deleted** on this line —
Linux owns the hardware. `sys_wsys_*` and `sys_vk_window_frame` belong to §4.4.

### 4.1d What is now implemented — `user/linux-syscalls.c`

The gap above is largely **closed**. `user/linux-syscalls.c` is the *hosted*
half of the Linux link runtime: compiled only into the glibc lane, with the
overlapping `.S` definitions guarded out by `-DADDER_HOSTED`. The freestanding
lane is untouched and still assembles.

Implemented and demonstrated by **running programs**, not by linking:

| Group | Entry points |
|--|--|
| fork / exec / reap | `sys_rfork` (fork(2)), `sys_execve`, `sys_execve_env`, `sys_waitpid`, `sys_waitpid_jc`, `sys_waitpid_nb_raw`, `sys_tcsetpgrp`, `sys_pgrp_kill`, `sys_setuid` |
| POSIX gap (§4.1c) | `sys_getpid`, `sys_getgid`, `sys_pipe`, `sys_socketpair`, `sys_link`, `sys_symlink`, `sys_clock_gettime`, `sys_set_realtime` |
| resolver | `sys_resolve` (getaddrinfo), `sys_resolve_ptr` (getnameinfo) |
| namespace | `sys_bind` — accepts `#c → /dev` and `#d → /fd`, fails the rest (§4.2) |
| event loop | `sys_waitfds` (poll(2)) |
| diagnostics | `sys_errstr` — now `strerror_r` on `errno` |
| stat | `sys_stat_p9` (full 9P2000 record), `sys_chan_dir_mode` (compact Dir records) |
| time | `sys_get_jiffies` — CLOCK_MONOTONIC at 100 Hz |

Two things only *running* the code revealed:

1. **The `.S` wrappers return `-errno`, and never set `errno`.** Measured:
   `sys_open("/no/such")` returns `-2`, `sys_open("/etc/shadow")` returns `-13`.
   So `sys_errstr` had nothing to report. The hosted file/fd definitions
   reproduce the `-errno` return *exactly* — anything decoding it is unaffected
   — and additionally set `errno`.

2. **`ls` built, linked, ran, and failed.** `lib/p9.ad`'s `p9_listdir` `read(2)`s
   a directory fd expecting Hamnix's `"NAME\n"` stream; Linux answers `EISDIR`.
   `sys_open` now notices a directory and `sys_read` synthesises that stream from
   `readdir`, so no userland changes. `ls` output is byte-identical to `ls -A`.
   **`.` and `..` are deliberately omitted**: `du`, `find`, `cp` and the other
   `p9_listdir` recursors have no self/parent guard anywhere in the tree and
   would loop forever otherwise. That absence is also the evidence that the
   Hamnix backing does not emit them.

`sys_stat_p9` is the **only reliable file-vs-directory test in the tree** —
`user/find.ad`'s header explains why (bug #146) a `p9_listdir` success cannot
substitute. Note the trap: it is the **full 9P2000 stat record**, *not* the
compact Dir record `lib/p9.ad`'s own header documents. `lib/p9.ad:1095` flags
the difference; consumers pin `qid.type` at byte 8 and `length` at byte 33.

### The stub policy is the biggest risk this port has

Bigger than `/net`, and it is not the risk §7 names. **A fail-closed stub that
returns a success-shaped wrong answer is worse than no implementation at all**,
and this tree has already produced silent data loss from one.

`sys_chan_dir_mode` is the case study. `user/cp.ad:163` and `user/tar.ad`
implement "is this a directory?" as `open(p); p9_chan_dir_mode(fd,1,p) == 0`.
While that returned −1, every directory looked like a regular file — and
`cp -r src dst` **did not fail**. It created `dst` as a plain file containing
the bytes of `src`'s listing and **exited 0**. Nothing in the exit status,
stderr, or an `strace` flagged it; only diffing the output caught it. Six apps
were quietly wrong the same way (`cp`, `tar`, `tree`, `stat`, `hdu`, `hamfm`).

Two compounding lessons:

- **Making a read succeed can make a failure silent.** The directory-read
  synthesis (§4.1d) fixed `ls` — and simultaneously converted `cp -r` from a
  loud read error into silent destruction. A fix that unblocks one caller can
  arm another. The pair had to land together.
- **`sys_get_jiffies` returning a frozen 0 is the same design error with a
  kinder symptom.** Nine apps hung instead of corrupting anything, which is how
  it got noticed. That is luck, not design.

Both are now implemented — `sys_chan_dir_mode` answers the predicate *and*
re-renders the stream as compact Dir records so `ls -l` is right too, and
`sys_get_jiffies` is `CLOCK_MONOTONIC` in centiseconds. `cp -r` copies real
trees; `sleep 1` takes one second.

**The rule for whoever adds the next stub:** it must fail in a way the caller
cannot mistake for a valid answer. Prefer a hard error to a plausible constant,
and before stubbing anything, grep for callers that treat its return as a
*predicate* rather than a status — those are the ones that turn a stub into
data loss.

Still fail-closed, each with a stated reason in the source: the fd-slot model
(`sys_fdbind`, `sys_fdslot_*`, `sys_pipechan`), the
`#s`/`#svc` registries, `sys_netcfg`, the `wsys`/`vk` surface, the `umdf` driver
ops, and the threading model (`sys_rfork_thread`, the semaphores).

Proof, not assertion: `tests/linux/syscall_probe.ad` and
`tests/linux/spawn_probe.ad` call each addition and check its *observable
effect*, returning the failure count as the process exit code — a stub cannot
pass by resolving. Both report `ALL PASS`.

### 4.2 `bind` — much smaller than it looks

> **VERIFIED, counts slightly off, conclusion intact.** The real figure is
> **52 call sites across 50 files**, not 49 — and the original arithmetic did
> not close (45 + 3 ≠ 49). Correct breakdown: **45** identical `#c → /dev`,
> **3** `#d → /fd`, and **4** genuine namespace uses, not 1. The claim that
> matters — that this is a stub-and-move-on, not a subsystem — holds, and the
> stub is now implemented (§4.1d).

`sys_bind` appears in 50 files, which reads alarming. It is not. Of the 52
call sites, **45 are the identical single line**:

```python
sys_bind(cast[Ptr[char]]("/dev"), cast[Ptr[char]]("#c"), 0)
```

— a fixed startup incantation binding the console device (`#c`) into the
process namespace at `/dev`. Another **3** are `sys_bind("/fd", "#d", ...)`.
There is no general namespace algebra in the applications: they each perform one
canned mount at `main()` and never touch it again. Representative:
`user/hamdesktop.ad:2479`.

**Implication:** a `bind` that understands exactly `#c → /dev` and `#d → /fd`
satisfies **48 of 52** sites. This is a stub-and-move-on, not a subsystem, and
it is done — see §4.1d. Both incantations ask for something Linux already
provides at those exact paths, so accepting them and doing nothing is honest;
everything else fails loudly rather than pretending a mount happened.

The **4** genuine namespace uses are in `user/distrofs.ad` (`/n/distros`),
`user/nsrun.ad`, `user/p9srv_demo.ad`, and an `/extbind_probe` site. Per-process namespaces do have a real Linux answer
(`unshare(CLONE_NEWNS)` + `mount --bind` in a mount namespace), but you almost
certainly do not need it to get the desktop up.

### 4.3 `/dev/*` file servers

Distinct `/dev` paths opened by the copied userland, by weight:

| Surface | Hits | Notes |
|--|--|--|
| `/dev/wsys/**` | **~300** | the window system — see §4.4. Dominant by an order of magnitude. |
| `/dev/fb`, `/dev/fbctl`, `/dev/fbpix` | 20 | the framebuffer — see §4.4 |
| `/dev/blk/**` | 25 | block devices → Linux `/dev/sd*`, `/sys/block` |
| `/dev/audio`, `/dev/audioctl`, `/dev/snd/ctl` | 30 | → ALSA or PipeWire |
| `/dev/snarf` | 17 | the clipboard → Wayland/X selection |
| `/dev/cons` | 11 | console → `/dev/tty` |
| `/dev/reboot`, `/dev/stat`, `/dev/auth`, `/dev/time`, `/dev/random`, `/dev/keymap`, `/dev/kbmap`, `/dev/version`, `/dev/hostname`, `/dev/meminfo`, `/dev/loadavg`, `/dev/vt/*`, `/dev/mouse`, `/dev/loop/ctl`, `/dev/firewall`, `/dev/sync`, `/dev/win` | 1–7 each | mostly direct Linux equivalents (`/proc/meminfo`, `/proc/loadavg`, `/dev/urandom`, `reboot(2)`, …) |

`/proc/*` reads (`uptime`, `meminfo`, `loadavg`, `cpuinfo`, `version`, `mounts`,
`modules`, `kmsg`, `net/dev`) are mostly **format-compatible with Linux already**
and may need only field-offset fixes. `/proc/tasks`, `/proc/toptable`,
`/proc/svc/*`, `/proc/self/ctl` and `/proc/realtime` are Hamnix inventions and
need real work (`user/top.ad`, `user/ps.ad`, `user/service.ad`).

### 4.3b The boot, and the Debian namespace — both working

**hamnix-linux boots.** `scripts/hamlinux_image.sh` stages an image;
`scripts/hamlinux_vm.sh` runs it under QEMU/KVM. The shape is deliberately the
same as Hamnix's, because `etc/inittab` already said `/bin/hamsh`:

```
Linux kernel -> /init  (user/linuxinit.ad, the Adder PID 1)
                  -> bind '#p' /proc, '#c' /dev, '#sys' /sys, '#s' /srv, ...
                  -> load /etc/modules
                  -> exec /bin/hamsh /etc/rc.boot
                       -> the rc scripts, then an interactive shell
```

On Hamnix the *kernel* posts those file servers before ELF-loading `/init`;
Linux hands us an empty namespace, so `linuxinit` does it. **`sys_bind`
performs real Linux mounts** — `bind '#p' /proc` still says what it means. New
letters on this line: `#sys` (sysfs; Hamnix has no `/sys`) and `#pts`.

**Kernel modules.** `sys_init_module` is new and unavoidable: on a Debian
kernel essentially every driver is a module, and `/dev/dri/card0` does not
exist until virtio-gpu and its four dependencies load. `user/insmod.ad` cannot
do this — it issues `SYS_INIT_MODULE` through an `asm_volatile` block encoding
the *old* backend's frame layout, and miscompiles under LLVM. The image
resolves dependency **order** at build time (where a real `modprobe` exists)
and writes `/etc/modules`; PID 1 just walks the list.

**The Debian namespace works, and the isolation is structural.** Verified in
the VM: Debian's own `dpkg` runs inside it, the parent's namespace still has
`/bin/hamsh`, and Debian's `ls` inside the namespace **cannot find
`/bin/hamsh` at all**. Nothing `apt` installs can reach the Hamnix filesystem.

It is Hamnix's own idiom mapped one-for-one, not a Linux invention:

| Hamnix | Linux |
|--|--|
| `rfork(RFNAMEG)` without `RFPROC` | `unshare(CLONE_NEWNS)` |
| `rfork(RFPROC\|RFNAMEG)` | `fork`, child unshares |
| `bind '#distro' /n/distro` | mount the subtree's filesystem |
| `bind '#distro' /` | `chdir` + `chroot` into it |

`user/nsrun.ad:72` states the invariant this rests on — **rfork BEFORE mount** —
and every namespace user follows it. Two traps: `sys_rfork` previously refused
any flag combination without `RFPROC`, which made the invariant
*unexpressible*; and **Linux mount propagation defaults to SHARED**, which
leaks the child's bind straight back to the parent and silently defeats the
isolation. The child marks `/` `MS_REC|MS_PRIVATE`. Plan 9's namespace copy is
private by construction, so nothing in the userland asks for this.

The distro image is built by `mmdebstrap --mode=unshare --format=ext4` — no
root, no loop mount, nothing on the host touched — and attached as a separate
virtio disk, so the separation is physical as well as logical.

### 4.4 The compositor and who owns the framebuffer

**Read `docs/de_scene_file_arch.md` before touching anything here.** It changes
the difficulty estimate substantially, in both directions.

The desktop is **not** a pixel-passing compositor. Each window is a directory in
the `wsys` file server; a window's content is a `scene` file — a *line-oriented,
human-readable text display list* in window-local coordinates. Clients (via
`lib/hamui.ad`) rewrite their whole `scene` and poke `ctl` to publish a frame.
The compositor (`user/hamUId.ad`) diffs scenes to compute damage, rasterizes
only the damaged rectangle into a per-window pixel cache, and blits the caches
z-ordered to `/dev/fb`. **The kernel owns no per-window pixel buffers.**

Consequences for the port:

- **Good:** the client-side protocol is text file I/O. `wsys` can become a FUSE
  or 9p userspace server, or a Unix-socket shim, without any client changing.
  There is no shared-memory buffer handoff, no DMA-BUF, no format negotiation.
  This is far more tractable than porting a pixel compositor.
- **Bad, and this is the real problem:** on Hamnix, `/dev/fb` is a file that
  *any* process may open. **Nine programs open it directly** —
  `user/hamUId.ad` (the compositor, legitimately), plus `user/hamdesktop.ad`,
  `user/hamlock.ad`, `user/hamshotui.ad`, `user/hamshot.ad`, `user/hamtoast.ad`,
  `user/hampanelscene.ad`, `user/hamctl.ad`, `user/hambrowse.ad`. On Linux, DRM
  master is **exclusive to one process**, and fbdev is deprecated. Eight of those
  nine must be rewritten to go through `wsys` instead of the framebuffer, or the
  desktop cannot start. `user/hamshot.ad` also reads `/dev/fbpix` for
  screenshots, which needs a compositor-side capture path instead.

`sys_wsys_alloc` / `sys_wsys_free` (window-buffer allocation) and
`sys_vk_window_frame` are absent from the Linux runtime entirely (§4.1c).

> **MEASURED — the framebuffer works, and this section's premise was wrong.**
> The Adder userland paints the VM's screen today: 1024000 of 1024000 pixels
> match what `tests/linux/fb_probe.ad` wrote, using the same banded-write
> pattern `hamUId` uses to present a frame. `user/linux-fb.c` backs `/dev/fb`,
> `/dev/fbctl` and `/dev/fbpix`, so those nine programs need no I/O changes.
>
> **fbdev, not DRM/KMS.** This section assumed fbdev being deprecated ruled it
> out. The opposite held up:
>
> - A hand-rolled legacy `SETCRTC` on virtio-gpu left the host surface **black**
>   even though every ioctl returned 0, `DIRTYFB` reported success, and a
>   readback of our own mapping showed the right pixels. Booting the same guest
>   with `console=tty0` painted the display correctly — through DRM's *fbdev
>   emulation*. Whatever that layer does about deferred I/O and damage, it does
>   correctly and a hand-rolled path does not.
> - `/dev/fb0` **is** `drm_kms_helper` on any modern driver. This is not legacy
>   hardware support.
> - It is the exact analogue of what Hamnix's `/dev/fb` already is: a linear
>   CPU-writable surface with a geometry query. No modeset, no connector/CRTC
>   pairing, no dumb-buffer lifetime.
> - **DRM master is exclusive to one process; fbdev is not.** This section calls
>   that exclusivity the reason eight programs must be rewritten to go through
>   `wsys`. It does not remove the need for `wsys`, but **it stops it being a
>   hard blocker** — the eight can keep opening `/dev/fb` while `wsys` is built.
>
> Raw DRM/KMS is kept as a fallback for a device with no fbdev emulation.
>
> Two things only running it revealed. **The text console keeps drawing into
> the framebuffer** — exactly one 8×14 character cell at (0,0) went black under
> a full-screen paint, the fbcon cursor. Hamnix already has the verb for it
> ("suspend the text console"); on Linux it is `KDSETMODE KD_GRAPHICS` on
> `/dev/tty0`, and opening `/dev/fb` for writing now does it automatically. And
> **`resume` must not be issued while still presenting**: it returns the VT to
> text mode and the console redraws over you, taking a fully painted screen down
> to 16 non-black pixels.

### 4.4b The `wsys` protocol, from the client side

The server has not been written yet, but the contract it must satisfy is fixed
by `lib/hamui.ad` and is small. Every path, by weight:

| Path | Hits | Meaning |
|--|--|--|
| `/dev/wsys/ctl` | 115 | the server control file |
| `/dev/wsys/<wid>/…` | 60 | per-window directory |
| `/dev/wsys/self` | 17 | read → the wid the compositor allocated to *this* process |
| `/dev/wsys/post`, `run/launch`, `appmenu/launch` | 15 | launcher plumbing |
| `/dev/wsys/cursor/scene`, `wallpaper`, `tray`, `session`, `workspace`, `windows` | 1–4 each | shell surfaces |

**Window creation** (`lib/hamui.ad:2280`) is the load-bearing sequence:

1. read `/dev/wsys/self` → if it parses to a wid ≥ 2, the compositor already
   allocated one and it is *owned* by this process; use it.
2. otherwise write `newwindow\n` to `/dev/wsys/ctl`, then **read
   `/dev/wsys/ctl` back** for the new wid as ASCII decimal.

Note wid 0 and 1 are reserved — `hamui` rejects anything `< 2`, and wid 1 is
the foreground console window that a normal user does not own.

**Per-window `ctl` verbs**, written to `/dev/wsys/<wid>/ctl` as newline-
terminated text (`_h_win_setup`): `geometry <x> <y> <w> <h>`, `decorate 1`,
`z <n>`, `title <text>`. Per-window leaves: `scene` (the display list),
`event`, `pointer`, `keys`.

Because it is all text file I/O, `wsys` can be a FUSE or 9p userspace server or
a Unix-socket shim without any of the ~75 Tier-4 clients changing — the good
news §4.4 already identified, now with the exact surface to implement.

---

## 5. Applications ranked by expected porting difficulty

All 277 apps classified by which native surfaces they touch. Counts are exact.

### Tier 1 — 151 apps: POSIX-only, expected to port for free

They touch nothing but `open`/`read`/`write`/`close`/`exit`. This is the entire
coreutils-shaped set: `cat`, `ls`, `cp`, `mv`, `grep`, `sed`, `awk`, `sort`,
`diff`, `tar`, `bc`, `cal`, `base64`, `cksum`, `column`, `comm`, `csplit`,
`cut`, and ~130 more. **Most of the userland is in this tier.** Expect them to
build and run once class (c) of §4.1 is filled in. They are also your smoke
test: get `cat` running before anything else.

> **MEASURED 2026-08-09.** Both halves of this were checked by building and
> running, not by reading.
>
> **Building — effectively total.** `scripts/hamlinux_sweep.sh` builds all 359
> `user/*.ad` through the glibc lane: **351 build, 0 real failures.** The 8
> non-zero exits are not app failures — 4 (`net9`, `http9`, `httpdconf`,
> `hambrowse_tabs`) are *modules with no `main`*, and 4 are `*_host.ad`
> harnesses wanting `devsnarf_*` from a C shim, not `sys_*` at all. Nothing in
> `user/` fails to compile or codegen. "Nothing here builds yet" is no longer
> true, and it was never a compiler problem — only a missing link runtime.
>
> **Running — the number that matters.** 181 Tier-1 apps were run and checked
> against *their own header contracts* (see the warning below): **120 PASS,
> 25 FAIL, 36 SKIP**. Excluding SKIPs — apps needing a device this host has no
> answer for (audio, `/dev/blk`, `/dev/wsys`, a tty, root) — that is an **83%
> pass rate**.
>
> **Failures concentrated in two stubs, both now fixed:** `sys_chan_dir_mode`
> (6 apps) and `sys_get_jiffies` (9 apps) accounted for 15 of the 25. See the
> warning below and §4.1d. Remaining known-real failures: 3 apps
> (`insmod`/`modprobe`/`rmmod`) whose hand-written `asm_volatile` wrappers
> encode the *old* backend's `%rbp` frame layout and break under LLVM; 2
> (`ifconfig`, `route`) on `sys_netcfg`; 2 (`nsrun`, `nsbindprobe`) on real
> namespaces; 1 (`tty`) on `sys_fdslot_kind`; and 1 (`hxd`) that looks like a
> genuine **wrong-code bug in the LLVM backend** — a loop induction variable
> never compared or incremented. That last one is worth someone's attention on
> its own.
>
> ⚠️ **Do not verify these against GNU coreutils.** They are deliberately
> narrower reimplementations and the GNU comparison manufactures false
> failures. `user/wc.ad` *ignores filename operands and reads only stdin*;
> `user/head.ad` likewise. Both are correct, and both look broken next to GNU.
> The header comment is the contract.
>
> ⚠️ **The tier boundaries themselves are soft.** A direct re-derivation put
> 181 apps in Tier 1 against this section's 151, and 13 in Tier 2 against 27.
> The classification here was static and transitive imports blur it; treat the
> tier as a planning aid, not an inventory.

### Tier 2 — 27 apps: read Hamnix-format `/proc` and `/dev/blk`

`ps`, `top`, `free`, `df`, `uptime`, `dmesg`, `lsblk`, `lsmod`, `losetup`,
`crond`, `date`, `service`, `initctl`, `pgrep`, `nproc`, `hammon`, `hlog`,
`oopsread`, `memhog`, `sysirqprobe`, `dd_blk`, `sqfs_to_blk`, `haminstall`,
`hamnix_partition`, `live_distro_up`, `nice_hi`, `nice_lo`.

Difficulty is *parsing*, not architecture. Several `/proc` files are already
Linux-format. `ps`/`top` need `/proc/tasks` and `/proc/toptable` replaced with
a `/proc/[pid]` walk.

### Tier 3 — 18 apps: networking

`curl`, `wget`, `ssh`, `sshd`, `httpd`, `httpd_worker`, `ping`, `ntpd`, `host`,
`ifconfig`, `route`, `hfw`, `hpm`, `u_server`, `u_tlstest`, `net9`, `http9`,
`modprobe`.

**They all block on one decision (§3), and then unblock together** — 15 of the
18 only ever call into `net9.ad`/`http9.ad`. `ntpd` needs UDP separately;
`ifconfig`/`route` need `sys_netcfg` (rtnetlink) and are independent of the
`/net` decision; `hfw` needs `/dev/firewall` (nftables) and could be dropped.

### Tier 4 — 71 apps: GUI clients on `/dev/wsys`

Everything `ham*scene`, plus `hamcalc`, `hamedit`, `hamfiles`, `hamnotes`,
`hamsheet`, `hamslides`, `hamwrite`, `hamsettings`, `hamsoftware`, `haminbox`,
the games, and so on. They talk the scene-file protocol through `lib/hamui.ad`
and bind `#c → /dev` at startup.

They are **uniform** — they nearly all go through `lib/hamui.ad`. Port `hamui`
and the `wsys` server, and this tier moves as one block. Individually they are
easy; collectively they are gated on §4.4.

### Tier 5 — the hard ones

| App | Why |
|--|--|
| **`hamUId.ad`** (31.2k lines) | the compositor. Owns `/dev/fb`, `/dev/wsys`, input, audio mixing, `/net/addr`. Everything in Tier 4 waits on it. **The critical path.** |
| **`hamsh.ad`** (17.6k lines) | needs `sys_waitpid`, `sys_tcsetpgrp`, `sys_pipechan`, `sys_srv_post`, `sys_rfork` job control. Cheap-ish on Linux but touches the most stub classes. Needed early — it is how you drive everything else. |
| **`hambrowse.ad` + `lib/web/`** (42 files) | a from-scratch HTML/CSS/JS engine. Needs `/net` *and* `/dev/fb` *and* `wsys`. Substantial but self-contained; the engine itself is portable. |
| **`hamdesktop.ad`, `hampanelscene.ad`, `hamlock.ad`, `hamtoast.ad`, `hamshot.ad`, `hamshotui.ad`** | the eight direct-`/dev/fb` violators of §4.4 |
| **`hpm.ad`** (8.2k) | package manager: `/net` + namespaces + block devices |
| **`user/x11/`** (6 files) | an X11 *server* over `net9`. On Linux this is redundant — delete it. |
| **`sshd.ad`, `distrofs.ad`, `nsrun.ad`, `p9srv_demo.ad`** | the genuine namespace/9p users |

---

## 6. Desktop stack: keep vs replace

> **DECIDED: keep.** Nothing in the DE was replaced. `hamdesktop`,
> `hampanelscene`, `hamtermscene` and the rest run unmodified against
> `/dev/wsys`; the compositor is a new Adder program (`user/wsysd.ad`) that
> reuses `lib/hamui_host.ad`'s rasterizer as-is. A foreign toolkit reaches the
> screen through the v2 blit protocol that `devwsys.ad` already specified, and
> `user/xbridge.ad` is the first client of it.


**Keep.**

- **The scene-file protocol and `lib/hamui.ad`.** It is the distinctive thing
  here, it is text over files, and it ports cleanly. Discarding it for GTK would
  mean rewriting all 71 Tier-4 apps.
- **`lib/web/`.** A from-scratch engine is the project's point; it has no Linux
  dependency beyond `/net`.
- **The rasterizer inside `hamUId.ad`.** It is the part that already works and
  is independent of who owns the display.

**Replace.**

- **`/dev/fb` scanout** → a single DRM/KMS backend, or (much easier to start) a
  Wayland or SDL surface. Do *not* try to keep multi-process framebuffer access.
- **`user/x11/`** → delete. Linux has X and Wayland.
- **`/dev/audio` + `lib/hammixer.ad` software mixing** → PipeWire. Software
  mixing exists only because Hamnix had no audio server.
- **`/dev/snarf`** → the Wayland/X selection protocol.
- **`lib/vk/`** (`vk_gpu`, `vk_venus`, `vk_hostgpu`) → the real Vulkan loader
  and Mesa. Getting a genuine GPU stack is a large part of why this line exists.
- **`lib/font_ttf.ad` / `font_bdf.ad`** → probably FreeType + fontconfig, though
  keeping them costs little and preserves rendering fidelity. Judgement call.

**Open:** whether `hamUId` should remain a compositor at all, or become a
Wayland *client* that hosts the scene-file protocol inside one surface. The
latter is dramatically less work and gets you a desktop on day one; the former
preserves the architecture. This is the biggest design decision in the port and
it is not mine to make.

---

## 7. Open questions I could not resolve

> **§7.1 ANSWERED** (descriptors as names — `user/linux-fdns.c`; a pipe slot is
> a FIFO, the bind table is shared, `/fd/<n>` resolves per-process).
> **§7.4 RESOLVED** earlier (glibc, deliberately).
> The rest still stand. See §0.


1. **Shim library vs. real file server for `/net`.** `scripts/net9_host_shim.c`
   proves the shim works for clients. It does **not** handle
   `net_open_conn_data` — a connection accepted in `httpd.ad` and opened by
   integer in a *different* process (`httpd_worker.ad`, §3.3). Whether to extend
   the shim with an fd-passing side channel, or move to FUSE/9p where cross-
   process addressing is native, I could not settle without knowing whether the
   multi-process server model is something you want to keep.

2. **In-kernel TLS.** `tls <host>` on a `ctl` file currently runs a TLS 1.3
   handshake in the Hamnix kernel and the `data` fd is transparently encrypted
   after it. Where does that live on Linux — inside the `/net` server (keeps
   clients unchanged, but the server now holds all private keys for all
   processes), or does `net9.ad` grow a userspace TLS path (breaks the "no
   sockets, no TLS in userland" invariant that the architecture doc treats as
   load-bearing)?

3. **Does the no-sockets invariant still bind on this line?** Hamnix's
   architecture forbids BSD sockets in Adder code. On the Linux line that
   prohibition may be philosophy rather than architecture, and dropping it would
   erase most of §3. I did not have the standing to decide this, and it is worth
   deciding *before* anyone writes a file server.

4. ~~**glibc or stay static-nolibc?**~~ **RESOLVED — it already works, and it
   was never a question in the LLVM lane.** `scripts/adder_cc_llvm.sh` has
   clang perform the link, and clang links glibc by default: the very first
   binary built through it is a `dynamically linked ... interpreter
   /lib64/ld-linux-x86-64.so.2` PIE against `libc.so.6`. No new backend work
   was needed and none is needed for OpenSSL, Mesa, PipeWire or FreeType —
   each is an ordinary `clang` link flag.

   Exactly **one** symbol collided between `user/linux-runtime.S` and glibc:
   `_start`, which `crt1.o` also defines. It is now guarded by `ADDER_HOSTED`,
   so one runtime serves both lanes and glibc's initialisers actually run
   (required before any libc-dependent library can be called). The
   static-nolibc question survives only for the *freestanding* lane, which is
   not the shipping path.

   **`scripts/hamlinux_build.sh` is the resulting per-app build lane.** It
   differs from `adder_cc_llvm.sh` only in linking the real syscall runtime
   rather than the SSA-prelude stub — which is what anything in `user/`
   actually needs — and reports its three failure modes as distinct exit codes
   (10 emit, 11 SSA bail, 12 link) so a sweep can group failures without
   parsing logs.

5. **`hamsh`'s job-control model vs. Linux process groups.** `hamsh` uses
   `sys_rfork`, `sys_pgrp_kill`, `sys_setexitsem` and `sys_waitpid_jc`. Whether
   Plan 9 rfork semantics can be expressed adequately in `clone(2)` flags for
   *this specific shell* I did not trace through 17.6k lines.

6. **Is `hamsh`'s alias/def/scope ceiling real?** Hamnix has unverified reports
   of caps at 65 aliases, 33 defs, 128 scopes. If those are real and are
   compiler limits rather than shell limits, they will follow the code here.
   Unverified either way.

7. **The 84 `*_host.ad` harnesses.** They are the most Linux-ready code in the
   tree and probably the right scaffold to build the port on — but they were
   written as *test* harnesses, not as a runtime. Whether to promote them into
   the real Linux path or treat them as reference, I could not judge.

---

## 8. Suggested first moves

Not prescriptive — but this ordering follows from the inventory above.

1. Fill in §4.1 class (c): the ~8 trivially-POSIX symbols. Get `cat`, `ls`,
   `echo` building and running. Proves the toolchain and the runtime.
2. Add `sys_waitpid` (`wait4`) and `sys_tcsetpgrp`. Get `hamsh` running. Now you
   have a shell to drive everything else.
3. Stub `sys_bind` to understand `#c → /dev` and `#d → /fd` (§4.2). 48 of 49
   sites satisfied.
4. Sweep Tier 1 (151 apps). Expect a high pass rate; each failure is a real bug
   worth a fix, not a port decision.
5. Decide §7.1/§7.3, then do `/net`. Tier 3 unblocks as a block.
6. Decide §6's open question, then `wsys` + `hamui`. Tier 4 unblocks as a block.

Tiers 1–3 are ~196 of the 277 applications and require no architectural
decisions beyond `/net`. The desktop is the long pole; it is also separable.
