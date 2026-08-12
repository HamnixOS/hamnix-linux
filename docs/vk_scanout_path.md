# The composite, the bus, and the display: what the GPU path costs and where its ceiling is

This is the implementation record for `work/vk-present-readback`. Everything
in it is measured on one machine — an RTX 3090 reached through the **host's
proprietary NVIDIA ICD, which the distro does not ship**. Installed machines
reach this card through **NVK**. Structural findings transfer; microseconds do
not. Each section says which it is.

---

## 1. The defect, isolated

`present_rows()` ends in `sys_write(fd, comp_base + off, ...)` — the CPU reads
the whole composite and hands it to `/dev/fb`. `comp_base` was the Vulkan
frame, and that frame was allocated `DEVICE_LOCAL`, unconditionally, in
`hvk_frame_create`.

On a discrete card without resizable BAR, `DEVICE_LOCAL|HOST_VISIBLE` is the
256 MiB PCIe BAR aperture. It is host-mappable, so nothing failed and nothing
warned. It is uncached, so every CPU read of it is a synchronous bus round trip
with no prefetching.

The write loop is now timed by itself (`bench: writeback`), so this is no
longer an inference. Same wsysd, same `-bench 60`, same 4,096,000 bytes per
frame; only the frame's placement varies:

| frame placement | writeback/frame | share of `present` | bandwidth | frame total |
|---|---|---|---|---|
| software (ordinary RAM) | 163 us | 96% | 24,988 MB/s | 472 us |
| GPU, `DEVICE_LOCAL` (the BAR) | **66,602 us** | 99% | 61 MB/s | 67,246 us |
| GPU, `HOST_VISIBLE\|HOST_COHERENT` | 10,044 us | 99% | 407 MB/s | 10,308 us |
| GPU, `HOST_CACHED` | **155 us** | 97% | 26,417 MB/s | 445 us |

The write loop is 96–99% of `present` in every configuration. `present` **is**
the readback; it is not syscall overhead and not the flip.

A standalone probe (`tests/linux/memprobe.c`) gets the same answer without
wsysd in the way, by `memcpy`ing 4 MiB out of each placement: 88.0 ms from the
BAR, 10.7 ms from uncached host RAM, 0.22 ms from host-cached, against 0.16 ms
for ordinary `malloc`'d memory.

**Structural.** A compositor reads its own composite every frame — for the
present and for the cursor save-under. Any placement that puts that read behind
PCIe costs two orders of magnitude. This is true on NVK too. The particular
figures are not.

### The lever that did not exist

The brief proposed flipping `vk_linux_frame_alloc(w, h, 1)` to `0`. That third
argument is `bgra`, not device-local (`lib/vk/vk_core.ad:1255` →
`hvk_frame_create(w, h, bgra)`); passing `0` swaps red and blue. Device-local
was hardcoded one level down. The three levers prior work refuted were batch
size, the coverage cache, and the **arena's** placement — the **frame's**
placement had never been a lever, which is why nobody had swept it. It is one
now: `HAMNIX_VK_FRAME_MEM=cached|coherent|device`, default `cached`, with
`device` kept so the 13x-slower predecessor stays reproducible.

### Why cached wins, and why it is not symmetric

Moving the frame to host memory moves the PCIe crossing onto the GPU's
**writes**. That is a good trade because the two directions are not
symmetric: a GPU write across PCIe is **posted** — fire-and-forget, the device
does not stall on it — while a CPU read of VRAM is synchronous. Same bus, 429x
apart.

---

## 2. End-to-end result of the placement fix

`tests/linux/de_fps_gpu.sh`, 1280x800, offscreen, same harness as the software
baseline:

| | GPU before | GPU after | software baseline |
|---|---|---|---|
| pointer, 250 ev/s | 7.5 fps | **58.1 fps** | 61 fps |
| drag, full frames | 4.1 fps | **39.5 fps** | 52 fps |
| input→pixel p50 | 84.3 ms | **8.50 ms** | 8.9 ms |
| wsysd CPU, idle | 76 % | **3.87 %** | 1.2 % |
| wsysd CPU, dragging | 93 % | **18.2 %** | 15 % |

The idle burn was the same defect: an idle desktop still presents, and every
present was 67 ms of uncached reads. It was never a busy-wait.

**Still slower than software: drag, 39.5 vs 53.2 fps.** Explained in §3a.

The software path was re-run in the same session to confirm it did not move:
`tests/linux/de_fps_latency.sh` gives 61.2 fps pointer, 53.2 fps drag, p50
8.64 ms, 8 passed / 0 failed. That is the published baseline, so nothing here
regressed the path every shipped desktop actually runs.

One further check worth recording: `lavapipe` — a CPU ICD — also advertises
the three export extensions and `hvk_frame_create_scanout()` succeeds on it,
returning a dmabuf that DRM imports. So the scanout plumbing does not depend
on the proprietary driver being present, though nothing about its *speed*
follows from that.

So the placement fix takes the GPU path from 13x slower to roughly parity. It
does not make it faster, and it cannot: at parity the frame is dominated by
work both paths do identically.

---

## 3a. Why drag is still slower: the shader now rasterizes across PCIe

`wsysd -bench` composites with **no windows** — `paint_window()` never runs, so
the vk router (armed inside it for the full-screen backdrop) is never armed and
the device rasterizes nothing. A drag is the opposite: a full repaint of a real
window set every frame. The measurement that could explain the drag gap was
exactly the one `-bench` cannot make, which is why it went unexplained.

`HAMNIX_WSYSD_BENCH_LIVE=N` turns the same per-phase counters on in the live
loop. Real desktop, 4 windows, a window dragging, 1280x800, **us per full
frame**:

| | scene | rast | submit | copy | cursor | present |
|---|---|---|---|---|---|---|
| software | 730 | 6600 | — | 540 | 7 | 850 |
| GPU, host-cached | 900 | 7500 | **6300** | 650 | 8 | 950 |
| GPU, device-local | 230 | 2370 | **2095** | 290 | 210 | **157000** |

Read the `submit` column. The same shader, the same ops, the same frame:
**2.1 ms into device-local VRAM, 6.3 ms into host memory.** The GPU is 3x
faster than the CPU at rasterizing a desktop frame (2.1 ms vs 6.6 ms) — but
only when the target is device-local. Put the frame in host memory and the
shader reaches it across PCIe on every op, and the device ends up costing what
the CPU costs.

**So the drag gap is the other half of the placement fix.** It moved the PCIe
crossing off the CPU's read and onto the GPU's write. For pointer frames and
latency that is a huge win, because those barely rasterize. For a full-frame
repaint the GPU's write is as expensive as the CPU's entire rasterize, and the
advantage cancels. There is no placement good for both: device-local costs
157 ms of present, host-cached costs 4.3 ms of extra rasterize.

This is the strongest argument for scanout, because scanout is the only
configuration where **both** terms are cheap: device-local rasterize (2.1 ms)
*and* no present at all. On these numbers a scanout drag frame would be about
`230 + 2370 + 290 + 210 = 3.1 ms` against software's 8.7 ms — roughly **2.9x**,
not 50x, because scene reading, window copy and the cursor are CPU work that
scanout does not touch. **That is the honest ceiling for a real desktop frame**,
as against the 12,870 fps delivery-cost ceiling in §3.

**What this does not explain.** The instrumented phases sum to 8.7 ms
(software) vs 10.0 ms (GPU) — 15%. The measured rates differ by 35%. So about
half the gap is *outside* `paint_frame()`. Unmeasured candidates:
`scan_windows()`, `pump_input()`, `publish_state()`, `report_uncovered()`, and
the interaction between a longer frame and the fixed `sys_waitfds(…, 0, 16)`
tick. Also unexplained: `scene` and `copy` are *faster* on the device-local arm
(230/290) than the host-cached arm (900/650), and both are pure CPU work on
memory that is not the frame.

## 3. The ceiling, measured rather than scoped

The owner's question is why a 3090 is not 50x a software rasterizer. The answer
is that on the `/dev/fb` path the device's own work is already negligible and
everything else is copying. `DE_TEXT` device time is 435 us; in the scanout
demo below the GPU reports **31.7 us** for a 1920x1080 frame. The device has
never been the problem, so no amount of tuning the copy can produce 50x — the
copy has to stop existing.

It can. `tests/linux/kmsscanout.c` allocates the frame `DEVICE_LOCAL` and
**exportable** and never maps it, exports a dmabuf, hands it to DRM
(`PRIME_FD_TO_HANDLE` → `ADDFB2`), sets a mode on DP-1, and then rasterizes
with the same `hvk` op path wsysd uses. There is no present step, because the
pixels are already where the CRTC reads them.

```
device: NVIDIA GeForce RTX 3090
dmabuf export available: YES
drm: connector 92 type 10 connected, mode 1920x1080@60
vk: scanout frame 1920x1080, dmabuf fd 35, is_scanout 1
drm: gem handle 1 -> fb_id 109  (the GPU's VRAM is now a framebuffer)
drm: MODESET OK -- the display is scanning out GPU VRAM directly

==== SCANOUT RESULT ====
  64350 frames in 5.00 s = 12870.0 fps
  per frame: 0.078 ms mean, 1.231 ms worst
  gpu ns last frame: 31744
  bytes copied toward the CPU: 0 (there is no mapping to copy from)
```

**12,870 fps at 1920x1080**, with 0 bytes moving toward the CPU, against 58.1
fps at 1280x800 on the fixed `/dev/fb` path and 61 fps for software. That is
the ceiling the architecture allows, and it is not 50x — it is ~210x the
software path on a larger surface.

Two honest qualifications, both important:

- **This is not a desktop.** It is three primitives a frame with no window
  scenes, no glyphs, no input and no compositor logic. It measures the cost of
  *delivering* a frame, which is the thing under test, and nothing else. A real
  desktop on this path would be bounded by its own rasterization and by the
  60 Hz refresh, not by 12,870 fps.
- **It is unthrottled.** Nothing waits for vblank, so most of those frames are
  never seen. The number is a throughput ceiling, not a frame rate a user
  would experience.

What it does establish, and what the `/dev/fb` numbers cannot, is that the
delivery cost on this path is **zero to three significant figures**, and that
the GPU's own rasterization of a full-screen frame is 31.7 us. Everything the
DE currently spends per frame is therefore addressable.

---

## 3b. wsysd ON the display, via scanout — measured

Landed and run: `HAMNIX_WSYSD_SCANOUT=1` (plus the supervision assertion).
wsysd probes DP-1's mode, allocates the frame in VRAM, exports it, DRM imports
it, the mode is set, and the compositor draws entirely on the device. Real
desktop, dragging window, **1920x1080** (the display's mode — 2x the pixels of
the software baseline), µs per full frame:

| | scene | rast | copy | cursor | **present** | **writeback** |
|---|---|---|---|---|---|---|
| software, 1280x800 | 730 | 6600 | 540 | 7 | 850 | 830 |
| **scanout, 1920x1080** | 100–490 | **88–460** | 39–190 | 0 | **0** | **0** |

`present` and `writeback` are **zero**, not small: the CRTC and the compute
shader address the same VRAM, so there is nothing to copy and `/dev/fb` is
never written. And `rast` collapsed from 6.6 ms to 0.1–0.5 ms because the
full-screen backdrop is now rasterized *on the device*, into device-local
memory, at twice the resolution.

**Total instrumented compositor work per frame: ~0.2–1.1 ms at 1920x1080,
against ~8.7 ms at 1280x800 — roughly 8–40x less work for 2x the pixels.**
That is well past the ~2.9x this document predicted, because the prediction
assumed `rast` stayed on the CPU; routing the backdrop to the device removed
it too.

### But the frame RATE barely moved, and that is the honest headline

Derived from the same counters: **50.4 fps at 1920x1080**, against the
software baseline's **50.0 fps at 1280x800**.

The compositor is no longer what limits the desktop. `sys_waitfds(&waitset[0],
0, 16)` is — the fixed 16 ms tick that HANDOFF.md already lists as broken, with
`nfds` literally 0 so no input can wake the loop. A 16 ms tick caps the desktop
at 62.5 fps no matter how cheap a frame becomes, and both paths now sit just
under it. **Making frames 8–40x cheaper bought 0.4 fps, because the frame was
never the constraint at this rate.**

This also resolves an open item from §3a: the reason the phase counters
explained only half the software/GPU rate gap is that the tick quantises the
period, so per-frame work and delivered rate are only loosely coupled.

**So the owner's 50x is real in the compositor and invisible on the screen
until the tick is fixed.** The next win on how the desktop *feels* is not
graphics work at all; it is filling `waitset` with the input fds.

### What was not measured on this path, and why

- **input→pixel latency and idle CPU.** Both harnesses sample the framebuffer
  *file*; on scanout there is no file, by construction. Measuring latency here
  needs a different instrument (a GPU-side timestamp, or a vblank-referenced
  probe) and I did not build one. The numbers are therefore absent rather than
  estimated.
- **Tearing.** Single-buffered: the shader writes the surface being scanned
  out. See "What fixing the tearing costs" below.
- **Un-encodable ops.** On the scanout path the router's identity is a host
  array (see `rast_target()`); an op the device cannot encode would fall back
  to writing that array, where it would be lost rather than displayed. No such
  op occurred in these runs — `pixcmp` is byte-clean — but nothing yet *detects*
  one. That is a real hole and it is not closed.

### What fixing the tearing costs

The scanout frame is single-buffered: the compute shader writes the surface the
CRTC is reading, so a frame that lands mid-scan tears. Concretely, to fix it:

- **Two exported frames instead of one.** `hvk_frame_create_scanout()` becomes
  a pair, and `rebind_descriptors()` has to point binding 0 at whichever is the
  back buffer, per frame. That is one `vkUpdateDescriptorSets` per frame — the
  function already exists and is called on every resize.
- **Two `ADDFB2` ids in `linux-fb.c`**, and `fb_flip()` alternating between
  them with `MODE_PAGE_FLIP`. That code is already written and already works —
  481 flips, stalled=0 — it is currently skipped because `fb.have_two` is 0 on
  the scanout path.
- **Memory**: one extra 1920x1080x4 = 8.3 MiB of VRAM. Negligible.
- **The real cost is the wait.** A flip completes at vblank, so *something*
  must not run ahead of it. The compositor must not block in the main loop on
  the flip event — that would reintroduce a clock-paced loop and undo the
  wake-on-input work, which is exactly the accident to avoid. The right shape
  is to add the DRM fd to the existing wait set (it becomes readable when the
  flip event arrives) rather than to introduce a second wait, and to skip the
  flip when one is already pending, which is what `fb_drain_flip_event()`
  already does.

**This is the same mechanism a present-rate cap wants**, so the two should be
built together rather than separately: the DRM fd's flip events *are* the
display's frame clock, and `linux-fb.c` is where a refresh figure would come
from — `fb.mode.vrefresh` is already populated by the modeset path, and
`hamfb_probe_mode()` could return it alongside width and height. Two different
notions of the display's frame time would be worse than either.

## 4. What it would take to put wsysd on this path

Verified working here: export, import, ADDFB2, modeset, render. What is missing
is entirely on the Hamnix side.

**`user/linux-vk.c`** — done in this branch. `hvk_frame_create_scanout()`,
`hvk_can_export_dmabuf()`, `hvk_frame_is_scanout()`; the device is created with
`VK_KHR_external_memory`, `VK_KHR_external_memory_fd` and
`VK_EXT_external_memory_dma_buf` when advertised.

### Status: what is built, and what is deliberately NOT

**Built and committed on this branch:**
- `hvk_frame_create_scanout()` / `hvk_can_export_dmabuf()` /
  `hvk_frame_is_scanout()`, and the device is created with the three export
  extensions when advertised.
- `hamfb_attach_scanout(fd, w, h, pitch)` in `user/linux-fb.c` — import,
  `ADDFB2`, modeset — with `hamfb_write()` returning `EOPNOTSUPP` once
  attached. `linux-fb.c` is part of every binary's runtime, so **no fd has to
  cross a process boundary** and `/dev/fbctl` needs no new verb after all.
  That resolves the open question in the previous revision of this document.

**Deliberately not built: the compositor rewrite, and wsysd does not arm any
of this.** `comp_base` would become 0, and five sites write the composite from
the CPU by construction: `fill_rect` (via `clear_desktop`), `put_px` (via
`paint_cursor`), `blit_window_image_mode`, `cursor_save_under` /
`cursor_restore_under`, and the software fallback in `paint_window` when
`vk_route_end()` fails. Each has a device equivalent already present in the
backend (`hvk_fill_rect`, `hvk_blit`), and the cursor save-under would simply
be dropped in favour of always-full frames — at 3.1 ms a frame that is
affordable.

I stopped short of it on purpose. A half-converted compositor holds DRM master
while dereferencing a NULL `comp_base`, on a machine whose console is the same
device and whose only proven recovery is process death, with the owner sitting
at that console. The remaining work is mechanical but must be done and tested
as one piece, not left partially armed. Nothing in this branch takes master
unless a test binary is run explicitly.

**`user/linux-fb.c`** — the remaining display-side work. It currently owns the display: it creates
*dumb buffers* (`drm_make_buf`: `CREATE_DUMB` → `ADDFB` → `MAP_DUMB`), sets the
mode, and page-flips between two of them, with `/dev/fb` writes landing in the
mapped back buffer. What changes, by function:

- `drm_make_buf` gains a sibling that takes an **imported** handle instead of
  creating a dumb one: `PRIME_FD_TO_HANDLE` + `ADDFB2` (note `ADDFB2`, not
  `ADDFB` — the modifier-aware form). No `MAP_DUMB`, and `fb.map` must become
  `NULL`, which is the invariant change that everything else follows from.
- `fb_init` must accept "the buffer comes from outside" as a mode, and must
  not fall back to a dumb buffer silently if the import fails — a silent
  fallback here reintroduces the 88 ms copy while reporting success.
- the write path (`/dev/fb` writes into `fb.map`) has **no meaning** on this
  path and must return an error rather than a short write. Nine programs write
  `/dev/fb` directly; every one of them is incompatible with scanout and has to
  go through wsys first. This is the same §4.4 exclusivity problem, and
  scanout makes it mandatory rather than merely correct.
- `fb_flip` keeps `MODE_PAGE_FLIP` unchanged — it already works, 481 flips,
  stalled=0 — but flips between two *imported* fb_ids, so wsysd needs two
  scanout frames and must alternate the render target.
- the dirty-rect path (`DIRTYFB`) is not needed and should be skipped: there is
  nothing to transfer.

**`/dev/fbctl`** needs one new verb, something like `scanout <fd>`, to receive
the dmabuf — which means fbctl's writer must be able to pass a **file
descriptor**, not just text. That is the single genuinely new mechanism: an
`SCM_RIGHTS` sendmsg over a unix socket, or having linux-fb.c do the Vulkan
export itself so the fd never crosses a process boundary. The second is much
simpler and is what I would do first.

**`user/wsysd.ad`** — `comp_base` becomes 0 and the CPU can no longer touch the
composite. That breaks, by construction:
- `cursor_save_under` / `cursor_restore_under`, which read and write the
  composite directly. They must become device ops (a blit to a scratch region
  and back), or the cursor must become a DRM **plane**, which is what it is for
  and would be faster than either.
- the software fallback in `paint_window` when `vk_route_end()` fails. On the
  scanout path there is nowhere to fall back *to*, so a mid-frame device
  failure has to drop the whole path back to a mapped frame and re-arm — which
  the code already knows how to do, but must now do without reading the old
  composite.
- `present_rows` / `present` become no-ops plus a flip.

**Expected saving, with its reasoning.** On the fixed path `present` is 155 us
of a 445 us frame, so removing it entirely is worth ~35% of the compositor's
CPU frame at 1280x800, and more at 1920x1080 where the copy scales with area
and the rest does not. The larger win is not the microseconds but the
**latency floor and the CPU**: the frame stops being bounded by a 4 MiB
memcpy and wsysd stops touching 4 MiB per frame at all, which is most of its
remaining idle and drag CPU.

**What would falsify it.** If, after the change, wsysd's frame time does not
drop by approximately the current `writeback` figure, the model is wrong. That
is a sharp prediction and it is worth checking rather than assuming — the
`bench: writeback` counter added in this branch is exactly the instrument for
it.

---

## 5. Operating this safely, and two things that do not work

The console framebuffer on this box is `nvidia-drmdrmfb` — **the console and
the display are the same device**. The old safety net (efifb survives a bad
modeset) is gone. What was built and proven:

- `tests/linux/kms_watchdog.sh` SIGKILLs its child after N seconds. DRM master
  is a property of the open **file**, so process death closes the fd and the
  kernel drops master regardless of what state the program is in. This is the
  backstop that does not depend on any of our code being correct.
- **Proven, not asserted.** `tests/linux/hangmaster.c` takes master, ignores
  SIGTERM and SIGINT, and hangs in `pause()` forever. The watchdog fired at
  5.2 s and killed it; a second run then took master again, which is the
  evidence that the first hold was really released. A watchdog that has never
  fired is not a watchdog.
- `kmsscanout` additionally arms `alarm(budget)` before touching anything and
  pairs SET_MASTER with DROP_MASTER on every signal path.

**Two things that do not work on nvidia-drm, both discovered the hard way:**

1. **Restoring the saved CRTC with a legacy `SETCRTC` hangs.** Measured twice,
   the second time with `vkDeviceWaitIdle` in front of it; both runs sat in the
   ioctl until the watchdog killed them.
2. **`DROP_MASTER` itself hangs** after a modeset. The run then exits via its
   own `alarm()` (rc 124).

In both cases the console came back — because the *process died*, not because
the cleanup worked. **The reliable recovery on this driver is process death.**
Anything built on this path must be supervised by something that can kill it,
and must not rely on its own orderly shutdown. That is a substantive constraint
on shipping a scanout compositor, not a footnote.

**Not persisted deliberately:** `nvidia-drm.modeset=1` was set by a module
reload, not by `/etc/modprobe.d` or the kernel cmdline, so a reboot restores
`modeset=N`. That reboot is the rollback; keep it working.

### Would atomic modesetting avoid the hangs? Undetermined.

Atomic is **available** — `tests/linux/atomiccap.c`, capability probe only, no
master taken and no commit performed:

```
  UNIVERSAL_PLANES       -> ACCEPTED
  ATOMIC                 -> ACCEPTED
  ASPECT_RATIO           -> ACCEPTED
  WRITEBACK_CONN         -> ACCEPTED
  DRM_CAP_PRIME          -> 0x1 (import; Vulkan does the export)
  ASYNC_PAGE_FLIP        -> 256
```

So the atomic path is on the table on this driver, and universal planes means
the cursor could become a real plane rather than composited pixels.

**Still UNDETERMINED after this pass** — I did not pursue it, because the
tearing fix above turned out not to need it (legacy `PAGE_FLIP` already works
on this driver, 481 flips, stalled=0) and the teardown hangs are already
covered by the supervision requirement. If someone does pursue it, the payoff
would be a *clean* teardown rather than relying on process death, which would
remove the single most awkward constraint on this path.

**Whether atomic avoids either hang is UNDETERMINED.** Establishing it requires
a real atomic commit — building a property blob for the mode, setting
CRTC/connector/plane properties, committing, and then testing whether an atomic
disable-commit and `DROP_MASTER` return. I did not do that, and I am not
willing to infer it from the capability bit: "the driver accepts the client
cap" and "the driver's atomic teardown does not hang" are different claims, and
this project has been bitten by exactly that kind of substitution before.

---

## 6. What I did not measure

- **NVK.** Every number here is the proprietary ICD. Whether NVK exports
  dmabufs, what its memory types look like, and whether its `DROP_MASTER`
  hangs, are all unknown and must be re-checked on it rather than inferred.
- **A real desktop on the scanout path.** The 12,870 fps is three primitives a
  frame, unthrottled, with no window scenes, no glyphs and no input.
- **Why drag is still 39.5 vs 52 fps** after the placement fix.
- **The GPU-side copy alternative** (`vkCmdCopyBuffer` device-local → host
  cached staging). The probe measured the copy at 0.35–1.3 ms for 4 MiB, plus
  0.22 ms for the CPU read — i.e. strictly worse than simply placing the frame
  in host-cached memory (0.22 ms total), so it was not pursued. It would only
  become interesting if the device's rasterization were measurably slower into
  host memory, which was not observed here.
- **Vblank-synchronised scanout**, and therefore any honest input→pixel latency
  figure on the scanout path.
