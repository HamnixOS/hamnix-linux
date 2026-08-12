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

**Still slower than software: drag, 39.5 vs 52 fps.** Not investigated. Flagged,
not explained.

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

## 4. What it would take to put wsysd on this path

Verified working here: export, import, ADDFB2, modeset, render. What is missing
is entirely on the Hamnix side.

**`user/linux-vk.c`** — done in this branch. `hvk_frame_create_scanout()`,
`hvk_can_export_dmabuf()`, `hvk_frame_is_scanout()`; the device is created with
`VK_KHR_external_memory`, `VK_KHR_external_memory_fd` and
`VK_EXT_external_memory_dma_buf` when advertised.

**`user/linux-fb.c`** — the work. It currently owns the display: it creates
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
