# `VK_BACKEND_LINUX` — the vk spine as a real Vulkan client

The Hamnix DE is already Vulkan-shaped: `lib/vk/` is a Vulkan-shaped API
written in Adder, `lib/hamui_host.ad` (what the compositor rasterizes through)
is a vk client, and every fill, blit and glyph in the desktop goes through
`lib/vk/vk_2d.ad`. Until now, on this line, **all of it executed on the CPU** —
the only two backends were `vk_raster` (software) and `vk_gpu` (native
virtio-gpu, which pokes PCI directly and is meaningless here because the Linux
kernel owns the device).

This is the third backend: `vk_core` selects it with
`vk_set_backend(VK_BACKEND_LINUX)`, and it is a genuine Vulkan client —
`dlopen("libvulkan.so.1")`, `vkCreateInstance`, a physical device, a logical
device and compute queue, a SPIR-V compute pipeline, real dispatches on a real
`VkDevice`.

No Mesa in the Debian namespace. No per-GPU-family driver written from scratch.
The dividend of being on this kernel is that the kernel driver **and** the
userspace ICD already exist for every GPU family, and neither of them belongs
to Debian.

## Files

| | |
|--|--|
| `user/linux-vk.c` | the C shim — dlopens the ICD, hand-declares the ABI subset, owns the device/pipeline/memory, records and submits the frame. Same pattern as `user/linux-fb.c` / `user/linux-wsys.c`. |
| `user/linux-vk-spv.h` | the compute rasterizer's SPIR-V, embedded (the Hamnix root has no `scripts/` tree). Regenerate with `scripts/gen_linux_vk_spv.py`. |
| `user/linux-vkhost.c` | the kernel-side symbols `vk_core.ad` needs in order to LINK at all on this line — see "vk_core did not link" below. |
| `lib/vk/vk_linux.ad` | the Adder seam, same shape as `lib/vk/vk_gpu.ad`: `vk_core → vk_linux → the C shim`, no import cycle, the shim knows nothing about vk. |
| `lib/vk/vk_core.ad` | `VK_BACKEND_LINUX`, `vk_set_backend`, and the frame router inside `vkQueueSubmit`. |
| `lib/vk/vk_2d.ad` | the **op router** — five optional function-pointer hooks, armed for exactly one surface, that hand each 2D primitive to the device instead of running the CPU loop. |
| `user/wsysd.ad` | the compositor: the silicon gate, the zero-copy binding, and the five hooks. |
| `scripts/shaders/vk2d_raster.comp` | the compute rasterizer (pre-existing; extended here — see "shader changes"). |
| `tests/linux/vk_linux_test.ad`, `tests/linux/vk_core_linux_test.ad`, `scripts/test_vk_linux.sh` | the gates. |

## The compositor selects it — and the gate is the interesting part

`user/wsysd.ad` calls `vk_set_backend(VK_BACKEND_LINUX)` at startup and then
decides, on the device it got, whether to keep it:

| device | default | why |
|--|--|--|
| `VkPhysicalDeviceType` 1/2/3 (integrated, discrete, virtual) | **GPU** | real silicon; this is the case the backend exists for |
| `VkPhysicalDeviceType` 4 (CPU — lavapipe et al.) | **software** | measured 2.3x slower on fills, 2.9x with glyphs; see below |
| no ICD / no device / no pipeline | **software** | `vk_set_backend` refuses rather than pretends |

Defaulting on unconditionally would have made the FALLBACK configuration —
the one a machine with no GPU runs — three times slower. That is the whole
reason the gate is on device type and not on "did Vulkan come up".

`HAMNIX_WSYSD_VK=1` forces it on (this is how the GPU path is exercised at all
on a host whose real GPU is off limits); `HAMNIX_WSYSD_VK=0` forces it off
without a rebuild. Either way the compositor prints ONE line naming the
device, its type, whether it is silicon, whether the frame is zero-copy and
whether that frame is device-local — because a compositor that silently picks
a slow path is exactly the failure this tree keeps hitting:

```
wsysd: vk backend SOFTWARE -- device is a CPU ICD (llvmpipe (LLVM 19.1.7, 256 bits),
       VkPhysicalDeviceType 4); vk_2d is 2.3-2.9x faster there
wsysd: vk backend GPU -- llvmpipe (...) (VkPhysicalDeviceType 4, silicon 0,
       zero-copy 1, device-local 1) [forced on by HAMNIX_WSYSD_VK; NOT the default here]
```

### How a compositor frame reaches the device at all

`wsysd` does not build `vk_core` command buffers — it rasterizes through
`lib/hamui_host.ad`, which calls `vk2d_raster_*` **directly**. So there was no
seam. The seam added here is a set of five function-pointer hooks in
`lib/vk/vk_2d.ad`, armed for exactly one `(base, img_w, img_h)` surface:

* **function pointers, not an import** — 66 files reach `vk_2d` through
  `hamui_host`, and none of them should acquire a `libdl` dependency and a
  Vulkan bring-up in order to draw a rectangle;
* **one surface** — the device has one frame buffer, so an op aimed anywhere
  else (a small window's private image, a test target) takes the CPU path
  after a three-integer compare. Routing it would paint the wrong surface;
* **a hook returns non-zero to decline**, and `vk_2d` then runs its own loop
  over the same memory — which is only sound because the hook calls
  `vk_linux_frame_sync()` first;
* the hooks see the op colour **before** `_vk2d_bgra`'s R/B swap, because the
  backend applies its own. A pre-swapped colour would double-swap.

The armed surface is the screen composite, and `wsysd` arms it around the
**full-screen backdrop's** rasterize — the window that already rendered
straight into the composite, and the bulk of a real session's pixels.

### Zero copy, measured

`wsysd`'s `comp_base` — the address every read and write of the screen
composite goes through — is set to `vk_linux_frame_alloc()`'s return value.
The composite IS the GPU frame. Measured on lavapipe: `zero_copy 1`,
`device_local 1`, and the resulting framebuffer is **byte-identical** to the
software compositor's, md5 for md5, across the whole offscreen fixture.

`device_local 1` is lavapipe's answer, and it is the answer any integrated GPU
or resizable-BAR discrete card will give. A discrete card without ReBAR will
answer 0, and `wsysd` prints a warning when it does, because
`docs/hambrowse_gpu_render.md` measured that case collapsing a 17x win to
~1.1x. **This has not been measured on real silicon and cannot be on this
host** (see "Performance" below).

## Entry points

For the compositor, two calls matter:

```
vk_set_backend(VK_BACKEND_LINUX)     # arms it; REFUSES and stays SW if it cannot
vk_linux_frame_alloc(w, h, bgra)     # the zero-copy frame buffer (see below)
```

`vk_set_backend(VK_BACKEND_LINUX)` returns `VK_SUCCESS` only when a real ICD, a
real physical device, a logical device+queue and the compute pipeline **all**
came up. Anything short of that returns `VK_ERROR_INVALID`, leaves
`vk_get_backend()` at `VK_BACKEND_SW`, and leaves the raster router disarmed.
`vk_set_backend(VK_BACKEND_SW)` disarms it again at any time.
`vk_linux_device_name()` carries the reason as text when it refuses.

`vk_linux_frame_alloc(w, h, bgra)` returns the **mapped address of the
GPU-resident frame buffer**. Bind the vk color image / the compositor shadow to
that address and a routed frame costs no upload and no readback. See below for
why that is the difference between a win and a loss.

Per-frame introspection, so "GPU accelerated" is never a claim taken on faith:
`vk_linux_frames_rendered()`, `vk_linux_last_frame_gpu_ops()`,
`vk_linux_last_frame_sw_ops()`, `vk_linux_frame_zero_copy()`,
`vk_linux_frame_submit_us()`.

## What runs on the device, and what does not

**On the device:** `fill_rect`, `fill_rect_alpha` (any alpha), `roundrect`
(anti-aliased corners), `line` (any angle, any thickness), `blit` (nearest,
scaled, source-over) from any source image, and `glyph` coverage masks. That is
the whole of `vk_2d.ad`'s raster vocabulary — strictly more than the venus
router encodes, which has no roundrect, no diagonal line and only intra-frame
blits.

**Not on the device, and why:**

* **Present.** Scanout on this line is `/dev/fb` (`user/linux-fb.c`). This
  backend owns no swapchain and makes no claim about the flush; the
  frame-to-framebuffer copy is exactly where it was. The DE frame breakdown
  (1280×800: total 625 µs, rast 432, copy 31, present 149) says rasterization
  is 68% of the frame, so that is what was attacked.
* **A blit whose source IS the frame** (a scroll / self-copy). One compute
  shader reading and writing the same storage buffer would race itself. These
  fall to the CPU op-by-op — cheap here, because the frame is host-mapped, so
  a CPU op is a `vk2d` call on the same pointer after one fence wait, with no
  transfer in either direction. The gate deliberately includes one.
* **The 3D path** (`VK_OP_DRAW` / `vk_raster_draw_triangle_list`). A 3D draw
  disqualifies the frame and the whole thing replays in software, unchanged.
* **Text shaping and glyph rasterization.** `lib/font_ttf.ad` still produces
  coverage bitmaps on the CPU; only the *compositing* of those bitmaps moved.

## The memory model is the interesting part

The venus/virtio-gpu routers own a device-side render target and must read it
back before any CPU op and upload after it. At 1280×800 that is 4 MiB each way.
**That design cannot win here**: the measured software rasterization budget for
the whole frame is 432 µs, and a 4 MiB memcpy costs more than that.

So the Linux backend's frame is a **host-visible, host-coherent storage buffer,
mapped once and never unmapped**. Two consequences:

1. If the render target IS that buffer (`vk_linux_frame_alloc`), a GPU frame
   costs **zero copies**.
2. A device-ineligible op does not force the frame back to the CPU — the
   software rasterizer runs on the same pointer, in draw order, after a fence.

We prefer a memory type that is `DEVICE_LOCAL` *and* host-visible (resizable
BAR, integrated graphics, software ICDs) and fall back to plain host-visible.
`vk_linux_frame_device_local()` reports which one you got. **0 means the shader
reaches the frame across the host bus**, which is exactly when GPU raster may
lose — the flag exists so that judgement is made on measurement, not hope.

## Correctness: byte-identity, not resemblance

The compute shader reproduces `vk_2d.ad`'s integer pixel math exactly — the
same `/255` source-over, the same Bresenham square brush, the same integer
Newton `isqrt` corner coverage — so a GPU frame is **byte-identical** to the
software rasterizer's, not merely similar. That is the only standard that
matters for a rasterization backend, and it is asserted, not asserted-about:

```
$ VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.json scripts/test_vk_linux.sh
VK_DEVICE llvmpipe (LLVM 19.1.7, 256 bits)
IDENTITY_RGBA           PASS byte-identical    24576 bytes
IDENTITY_BGRA           PASS byte-identical    24576 bytes
BENCH_FILLS_1280x800    PASS byte-identical  4096000 bytes
BENCH_DE_TEXT_1280x800  PASS byte-identical  4096000 bytes
SW_SELFTEST PASS
ROUTER gpu_ops=9 sw_ops=1 zero_copy=0
ROUTER_IDENTITY         PASS byte-identical    61440 bytes
VK_LINUX_TEST PASS
```

Both store orders are gated, because the R/B handling differs per op:
`vk_2d` swaps the OP COLOUR for fills/lines/roundrects/ink but swaps the SOURCE
PIXEL for blits. A backend that got only one of those right would pass an
RGBA-only gate and then paint the desktop with blue faces.

The scenes include the cases where two independent clip hoists can disagree:
negative origins, rects clipped off every edge, a glyph clipped at the right
edge, a scaled blit, translucent ink, and partial corner masks.

## Performance: what was measured, and what it does and does not mean

Measured on **lavapipe** (`llvmpipe`, a CPU Vulkan implementation), 1280×800,
best of 20, against `vk_2d.ad` compiled through the same lane on the same
machine:

| frame | GPU | SW (`vk_2d`) | |
|--|--|--|--|
| DE frame, fills/roundrects/blits only | 9.6 ms | 4.1 ms | GPU is **2.3× slower** |
| DE frame + 1680 glyph runs | 14.3 ms | 4.9 ms | GPU is **2.9× slower** |

**On lavapipe this backend loses, and that number says nothing about a GPU.**
lavapipe executes the same integer math on the same CPU, but through a JIT'd
generic SPIR-V with a thread-pool dispatch, while `vk_2d` is a hand-tuned
rasterizer with packed-word stores, hoisted constants and a vectorized glyph
inner loop. Comparing them measures llvmpipe's shader JIT against Hamnix's
rasterizer — which is a real and slightly humbling result about how good
`vk_2d` is, and not a measurement of GPU acceleration.

The number that would settle it is real silicon, and this host's real GPU is
off limits by policy (never the dev host's `/dev/dri`). The closest existing
evidence is this repository's own, for the **same shader**:

* `docs/vk_hostgpu_bridge.md`: fill + full-screen alpha blend on an RTX 3090,
  0.11 ms at 1280×720 against 1.87 ms on the CPU (**16×**), and the GPU time is
  nearly flat with resolution while the CPU cost scales linearly.
* `docs/hambrowse_gpu_render.md`: a real 888×1126 browser page — backgrounds,
  borders and 40 anti-aliased text runs as coverage masks — 1.28 ms on the RTX
  3090 against 1.41 ms on the CPU, on a **host-visible (PCIe-mapped)** buffer.

That last one is the honest caution as much as the encouragement: on a discrete
GPU without resizable BAR, a host-visible frame is reached over PCIe and the
win shrinks to ~1.1×. This is precisely what `vk_linux_frame_device_local()`
exists to report.

**So the default is the device-type gate above, not "on".** The host gate
proves the backend is *correct*. Whether it is *faster* is a per-device
question that must be answered in the VM or on the target with these two
benches, and the gate is what keeps a wrong answer from being the shipped
default. Nothing in this document claims a GPU measurement: this host's real
GPU is off limits by policy, and venus in the VM does not come up (the host
NVIDIA driver's GBM backend cannot create a device — see the comment in
`scripts/hamlinux_vm.sh`).

### What made the difference between "10× slower" and "3× slower"

Worth recording, because the first version was a plausible-looking backend that
genuinely ran on the device and was ten times slower than doing nothing:

1. **One dispatch per op is fatal.** A page of text is one op per *glyph*:
   1723 dispatches for one DE frame, 50 ms. Removing the barriers between
   non-overlapping ops changed nothing — the cost was the dispatches.
2. **Ops with disjoint destination rects can share one dispatch.** The host
   tracks the union of the rects written since the last barrier; an op disjoint
   from that union is provably disjoint from every op in it, so it needs no
   barrier *and* can be packed into the same batched dispatch
   (`OP_BATCH`, `gl_WorkGroupID.z` selects the entry). 1723 dispatches → 76.
   50 ms → 24 ms.
3. **A batch must not mix sizes.** The grid is the max over the batch, so a
   full-screen fill batched with a glyph launches millions of workgroups that
   immediately return. The batch grows only while the padded launch stays
   within 2× the work separate dispatches would have done.
4. **Loading 23 push-constant-equivalent fields per invocation cost more than
   the pixels.** Only the fields every op needs are loaded eagerly; the rest go
   through `fld()`, which reads the batch entry or falls back to the push
   constants. 24 ms → 14 ms.
5. **The overlap test was a bounding-box union, and a union is a lie.** An op
   needed a barrier if it touched the UNION of everything written since the
   last one. A row of glyphs unions into a band; the next UI element lands
   inside that band without touching a single glyph, and got a full pipeline
   barrier for it. The union is now only the O(1) *reject* — when it says
   "maybe", the individual rects it is a union of are consulted, and only a
   real overlap serializes. Measured on the DE-with-text frame, per frame:
   **barriers 72 → 12, dispatches 75 → 15**. That is the largest single
   change since the batching itself, and it is the one that matters most on
   real silicon, where a compute barrier is a pipeline flush and 60 of those
   were being bought for nothing.
6. **A page of text is a few hundred SHAPES drawn thousands of times.** Every
   glyph re-expanded its coverage mask into the source arena — 1680 glyphs of
   12x16 is 1.3 MiB of staging per frame. A per-frame cache keyed on a hash of
   the coverage bytes (the caller reuses one scratch buffer, so the pointer
   says nothing) and **confirmed byte for byte before it is trusted** — a hash
   collision would paint one letter with another's shape — cuts the DE-with-
   text frame's staging from **363,792 to 41,808 uint32s**. Honest caveat: in
   that fixture every glyph is the same cell, so 1679 of 1680 hit; a real page
   has ~100 distinct shapes and would see roughly 10-20x, not 1680x.
7. **One command buffer, recycled.** It was allocated and freed every submit
   for a recording that is a different list but always the same shape.

### Per-frame counters, and why they are the thing to optimise

`tests/linux/vk_linux_test.ad` prints `ops`, `dispatches`, `batched_ops`,
`barriers`, `staged_words` and `cov_reuse` **per frame**. These are
device-independent — an op is an op and a dispatch is a dispatch on llvmpipe
and on an RTX — which is exactly why they, and not the microseconds beside
them, are what the optimisations above were measured against. Current:

| frame | ops | dispatches | barriers | staged_words |
|--|--|--|--|--|
| DE fills only | 44 | 19 → **15** | 13 → **9** | 1,296 |
| DE + 1680 glyphs | 1,724 | 75 → **15** | 72 → **12** | 363,792 → **41,808** |

`wsysd -bench N` prints the same counters for a real compositor frame
(`ops/frame`, `dispatch/frame`, `batched/frame`, `barriers/frame`).

## First: the DE does NOT use this backend today

Ask this before reading any number below, because it changes what they mean.
**The desktop runs on the software rasteriser (`vk_2d`) on every machine this
tree currently produces.** Not "sometimes", not "unless a GPU is present" —
today, everywhere. Three independent reasons, each sufficient on its own:

1. **The shipped image carries one ICD, and it is venus.**
   `scripts/hamlinux_image.sh:789` — `VK_MODE="${HAMLINUX_VULKAN:-venus}"`.
   The built initramfs contains exactly `libvulkan.so.1`,
   `libvulkan_virtio.so` and `usr/share/vulkan/icd.d/virtio_icd.json`, and
   nothing else Vulkan.
2. **Venus enumerates nothing on this host's plain virtio-gpu**, so
   `vk_set_backend(VK_BACKEND_LINUX)` refuses and `wsysd` prints
   `vk backend SOFTWARE -- no usable Vulkan device (Vulkan loader found no
   physical device)` (`user/wsysd.ad:872`).
3. **Even where an ICD does come up, `vk_arm` disarms on a CPU ICD by
   design** (`user/wsysd.ad:880`) — a conformant software ICD is refused
   because `vk_2d` is 2.3–2.9× faster there. So a `HAMLINUX_VULKAN=lavapipe`
   image is *also* on the software path.

Nothing in `tests/linux/` asserts on that `wsysd: vk backend …` line at all, so
which path the desktop took has never been gated either way.

**This is why the 33 ms below is "do not switch yet", not "we shipped something
slow."** No user has ever run the frame that was slow. It also means the fix in
this section is not a user-visible speedup today; it is the removal of the
thing that would have made turning the GPU path on a *regression*.

One caveat on transfer: the measurement uses this host's **proprietary NVIDIA
ICD**, which the distribution does not ship. An installed machine with this
card would reach it through **NVK** (`hamnix-vulkan-nvk`, pulled in by
`hamnix-drivers-gpu-nvidia`). The defect found below is a property of *discrete
GPU memory* — mapped device memory is uncached on any of them — so it
transfers; the absolute microseconds do not.

## Measured on real silicon, and the 33 ms was not the GPU

**Date: 2026-08. Device: NVIDIA GeForce RTX 3090, driver 550.163.01, Vulkan
1.3.277, `VkPhysicalDeviceType` 2, `/usr/share/vulkan/icd.d/nvidia_icd.json`,
offscreen with the desktop running beside it, with the machine owner's
consent.** Everything below this heading supersedes the lavapipe conclusions in
the two sections that follow it, which are kept because being wrong in public
is how the levers got tested at all.

The first run said `GPU 8× faster on fills, 7.4× SLOWER on the text frame`.
That second number is the interesting one, and **it was not a measurement of
the GPU.** `GPU_US` was wall clock around `frame_begin … frame_end`, which
cannot tell the device being slow from the *host* being slow with the device
idle. So the backend now reports the split, and the split is the whole answer:

```
BENCH_DE_TEXT_1280x800  GPU_US 32722   record_us 52   wait_us 535   gpu_us 428
```

- `gpu_us` — the **device's own clock**, `VK_QUERY_TYPE_TIMESTAMP` from
  `TOP_OF_PIPE` at the head of the command buffer to `BOTTOM_OF_PIPE` at its
  tail, scaled by `VkPhysicalDeviceLimits::timestampPeriod`: **428 µs.**
- `record_us` + `wait_us` — CPU building the command buffer, then CPU blocked
  on the fence: **587 µs together.**
- `GPU_US` — the whole frame: **32,722 µs.**

**32.1 ms of that frame was never submitted to anything.** It was the host,
inside the frame body, before a single command was recorded. The RTX 3090 does
this frame in 428 µs — 3 µs more than it spends on the *fills* frame that was
called "8× faster".

### Where the 32 ms went: a cache that confirmed itself across the bus

`hvk_glyph`'s per-frame coverage cache keys on a hash of the coverage bytes and
then **confirms the hit byte for byte** before trusting it — deliberately, and
that confirmation must stay: a hash collision there paints one letter with
another letter's shape, which is exactly the plausible-wrong-answer shape this
tree keeps being bitten by.

It confirmed against `g_amap` — **the mapped Vulkan buffer**.

On lavapipe that buffer is ordinary cached RAM and the compare is free, which
is why this shipped and why every gate in the tree stayed green. On a discrete
GPU it is uncached, write-combined host memory: writes stream, but every *load*
is a bus round trip of order 100 ns rather than an L1 hit. 1,679 cache hits ×
~192 words × ~100 ns is the 32 ms, and the frame stayed byte-perfect the whole
time.

The fix is a host-side mirror of the arena (`g_ashadow`), written in lockstep
from the same source bytes and confirmed against instead. Same comparison, same
collision safety, no bus.

| | wall | device clock | vs software |
|--|--|--|--|
| DE+text, before | 32,722 µs | 428 µs | **7.4× slower** |
| DE+text, after | 1,166 µs | 428 µs | **3.8× faster** |

**28×, byte-identical at every lever setting.**

### All three "device-independent levers" are now refuted on hardware

This is the part worth carrying forward, because the project quoted these
counters as predictors for the life of the backend.

| lever | what it does to the counters | what it did to the frame |
|--|--|--|
| `MAX_BATCH` 1 → 1024 | dispatches 1,724 → 15 (115×) | 2.6% (per-dispatch cost here is 517 ns, vs lavapipe's 17,700 ns) |
| `NO_COVCACHE=1` | staged words 41,808 → 364,176 (8.7× **more**) | **41× faster** before the fix, and still ~30% faster after it |
| `ARENA_DEVLOCAL=1` (new) | nothing; pixel-neutral | **5× worse** (164 ms) |

That last row is what *named* the cause. Asking for a `DEVICE_LOCAL |
HOST_VISIBLE` arena moved the CPU's readback from write-combined system memory
to VRAM across the PCIe BAR, and the frame got five times slower — the cost
tracked how far the **CPU's read** had to travel, which is not a fact about
dispatches, staging volume, or the shader.

The residual: `NO_COVCACHE` is still ~30% faster than the fixed cache on this
device (805 µs vs 1,166 µs), so the coverage cache is *still* net-negative
here — the FNV hash plus the linear scan now cost more than the staging they
save, because staging into write-combined memory is nearly free. That is a
recorded observation, not a fix; on a bus-limited device the trade flips back.

### The gate that would have caught it

`scripts/bench_vk_linux_device.sh` now enforces a **host-overhead ceiling**:
wall clock may not exceed 10× the device's own clock for any frame at any lever
setting. Before the fix the DE+text frame sat at **76.4×**; after it, at 2.7×,
and fills at 1.2×.

It is a ceiling on a bug shape, not a performance target. The shape is
specific: *the backend doing work on the CPU that the device is waiting on,
while every pixel stays correct.* A CPU ICD passes it trivially (`dev_us`
tracks the wall clock because llvmpipe **is** the host), which is precisely why
`scripts/test_vk_linux.sh` could never have caught this and why this script
exists. When a device reports no usable timestamp the bench says the ceiling
**could not be checked** — an unrun gate, not a passed one.

## Do those counters predict anything? Measured, and the answer is "one of them"

> **Superseded on hardware.** The section above measured all three levers on an
> RTX 3090. Keep reading for how they behave on lavapipe; do not quote the
> conclusions as properties of the backend.

The paragraph above was an argument, not a measurement: the counters were
*asserted* to be device-independent and *assumed* to be the right levers.
Neither had been tested, because nothing could move a counter without also
moving the pixels — and a number you cannot vary cannot be shown to predict
anything.

`user/linux-vk.c` now has two levers that move the counters and **not** a
single output pixel (the gate asserts byte-identity at both settings):

| | |
|--|--|
| `HAMNIX_VK_MAX_BATCH=N` | cap the `OP_BATCH` entry count. `=1` is exactly the one-dispatch-per-op shape the batching replaced. |
| `HAMNIX_VK_NO_COVCACHE=1` | disable the per-frame glyph coverage cache — the 1.3 MiB-of-staging shape the cache replaced. |

`scripts/bench_vk_linux_device.sh` sweeps both. Everything below is lavapipe
on the dev host (12 cores, 1280×800, the same two fixture frames), and every
row was byte-identical to the software rasterizer.

### 1. The counters really are a property of the op stream, not the device

`LP_NUM_THREADS` changes how fast the "device" is by 3.6× and changes the
counters by nothing at all:

| LP_NUM_THREADS | DE+text µs | fills µs | ops | dispatches | barriers | staged |
|--|--|--|--|--|--|--|
| 1 | 38,229 | 27,902 | 1724 | 15 | 12 | 41,808 |
| 2 | 20,728 | 15,122 | 1724 | 15 | 12 | 41,808 |
| 4 | 11,225 | 7,744 | 1724 | 15 | 12 | 41,808 |
| 8 | 10,492 | 7,427 | 1724 | 15 | 12 | 41,808 |

That is the claim "these are device-independent" turned into evidence. It is
the weak half of the question, but it had never been shown either.

### 2. Dispatch count predicts — strongly, and at 17.7 µs each

DE+text frame, identical pixels, identical barriers (12) and identical staging
(41,808 words) in every row. The *only* thing that changes is how many
dispatches the same 1,724 ops are packed into:

| `MAX_BATCH` | dispatches | GPU µs |
|--|--|--|
| 1 | 1,724 | 38,300 |
| 2 | 866 | 27,200 |
| 4 | 439 | 18,100 |
| 8 | 227 | 13,400 |
| 16 | 119 | 10,600 |
| 32 | 67 | 9,800 |
| 64 | 39 | 8,700 |
| 1024 (default) | **15** | **8,100** |

4.7× from that lever alone, and the slope is **≈17.7 µs per dispatch** on
lavapipe — which is what "one dispatch per glyph is fatal" was worth, now as a
number rather than a before/after anecdote.

### 3. Fewer dispatches is NOT always faster, and the fills frame proves it

The same sweep on the 44-op fills frame runs the other way:

| `MAX_BATCH` | dispatches | GPU µs |
|--|--|--|
| 1 | 44 | **5,000** |
| 2 | 23 | 10,200 |
| 4 | 19 | 5,800 |
| 8 | 15 | 6,600 |
| 1024 (default) | 15 | 6,200 |

One dispatch per op is the **fastest** setting for that frame, and the shipped
default is ~20% slower. The cause is in the code and is not subtle: a batch
launches `max(gx) × max(gy)` workgroups for *every* entry, and the growth
guard permits up to 2× padded waste — so at `MAX_BATCH=2` a full-screen fill
pairs with a small one and the frame costs 1.7× the unbatched one. The guard
is doing its job (the wider settings recover); what is refuted is the shorthand
that dispatch count alone is the lever. **The lever is the pair (dispatches,
padded workgroups)**, and only the first of the two is currently counted.

### 4. Staged words predict nothing here, and that is a fact about the memory

| | staged_words | GPU µs |
|--|--|--|
| coverage cache on (default) | 41,808 | 8,100 |
| coverage cache off | 364,176 | 8,100 |

8.7× the staging costs no measurable time. That is not a defect in the cache —
it is the memory model doing exactly what "The memory model is the interesting
part" says: the arena is host-visible, host-coherent memory, and the "device"
reads it at CPU speed, so staging a megabyte more is a megabyte of memcpy lost
in an 8 ms frame. **On a discrete card without resizable BAR that same
staging crosses PCIe**, which is precisely the case
`vk_linux_frame_device_local()` reports and precisely where this row should
change. Until then, `staged_words` is an honest counter of a cost this device
does not charge for.

### So: what transfers to real silicon, and what does not

* **Transfers**: the counters themselves (shown, not argued), and the *shape*
  of the dispatch result — a per-dispatch cost exists on every device and the
  batching is worth roughly `dispatches × that cost`.
* **Does not transfer**: the 17.7 µs. On a GPU a dispatch is a command
  processor's packet, not a CPU thread-pool fan-out, and it should be far
  cheaper — which also moves the crossover in §3, because an idle workgroup
  retires nearly free on a GPU and does not on llvmpipe. The fills result is
  the first thing to re-check on hardware, and its *sign* may flip.
* **Untested anywhere**: the staging slope. It is zero here by construction.

## What could be measured on this host, and what could not

The wall is recorded in `scripts/hamlinux_vm.sh` and it is real. What follows
is what was *checked* rather than assumed, so the next pass does not re-do it.

### The venus wall is confirmed, and it did not need root

`hamlinux_vm.sh` records the NVIDIA GBM failure as "the usual symptom of
`nvidia-drm.modeset=0`" and notes that confirming it needs root, because
`/sys/module/nvidia_drm/parameters/modeset` is `0400`. It does not:

```
$ ls /sys/class/drm/
card0  renderD128  version
```

`nvidia_drm` **is** loaded (`lsmod`), and it registered a DRM device — but no
connectors (`tests/linux/vk_icd_survey.sh` prints the connector count for
every card it finds, which is why that survey is the first thing to run on a
new machine). A KMS-capable DRM driver exposes one `cardN-<connector>` node per
output (`card0-DP-1`, `card0-HDMI-A-1`, …); there is not one here. That is
modeset being off, observed from userspace, without opening the device and
without a privilege this tree does not have. The recorded hypothesis is now
evidence.

### No other ICD on this host can find a device

Every Mesa ICD in `/usr/share/vulkan/icd.d/` was asked to enumerate, in a
private mount namespace with a `tmpfs` mounted over `/dev/dri` — so the host
GPU's nodes were *provably* never opened, which is the standing rule here.
That is `tests/linux/vk_icd_survey.sh`, and it is a script rather than a
paragraph because every word of this section is a claim about the MACHINE,
which goes stale the moment someone plugs in a card:

```
$ tests/linux/vk_icd_survey.sh
[icdsurvey]   card0: driver nvidia, 0 KMS connector(s)
[icdsurvey]     ^ no connectors: this driver is not modesetting
[icdsurvey] lvp_icd.json             DEVICE type 4  llvmpipe (LLVM 19.1.7, 256 bits)
[icdsurvey] nvidia_icd.json: NOT RUN (reaches the GPU through /dev/nvidiactl)
[icdsurvey] <every other ICD>        no-device (... -> VkResult -3)
[icdsurvey] UNDETERMINED — every ICD this survey RAN is a CPU rasterizer,
[icdsurvey]   but it did not run: nvidia_icd.json
```

> **That last line used to read `CPU-ONLY — correctness is gateable,
> performance is not`, and it was wrong in the most expensive way available.**
> The survey skips `nvidia_icd.json` *by design*, and then summarised as
> though the skip had been a result. The sentence was quoted for months as a
> fact about this machine's hardware; it was a fact about this script's own
> `for` loop. The RTX 3090 was reachable the entire time — see
> [§ measured on real silicon](#measured-on-real-silicon-and-the-33-ms-was-not-the-gpu).
> The verdict is now `UNDETERMINED` whenever any ICD went unrun, because a
> survey may report *"I did not look"* and may never report *"there is nothing
> there"* on the strength of not having looked. This is the fourth time in this
> project an instrument created or hid the effect it was measuring.

| ICD | result |
|--|--|
| `lvp` (lavapipe) | `llvmpipe (LLVM 19.1.7, 256 bits)`, type 4 |
| `virtio` (venus) | `vkEnumeratePhysicalDevices` → `VK_ERROR_INITIALIZATION_FAILED` |
| `gfxstream` | same |
| `nouveau`, `radeon`, `intel`, `intel_hasvk` | same |
| `nvidia` | **not run** — that is the host's GPU |

And this is not an artefact of the mask. The host has exactly one DRM device,
`/sys/class/drm/card0`, whose driver is `/sys/bus/pci/drivers/nvidia`
(`01:00.0 GeForce RTX 3090`). Every Mesa ICD in that list claims a *different*
kernel driver — `nouveau`, `amdgpu`, `i915`/`xe`, `virtio_gpu` — so none of
them would claim that node even unmasked, and the one that would is the one
that is off limits. `gfxstream` and `virtio` both want a **virtgpu** node,
which exists only inside a VM. There is no third option on this box.

### QEMU without venus does not give the guest a Vulkan device — measured

The tempting reasoning is that plain `virtio-gpu-pci` is at least a *different
profile*: a real PCI device, real DMA, real scanout, even if the rasterizer is
still a CPU. So it was booted and asked, rather than argued about
(`scripts/hamlinux_vm.sh script`, an `/etc/rc.boot` appended to the initramfs
as a second cpio segment — `docs/steam_namespace.md` §11):

```
VKPROBE_DRI:    card0  renderD128        <- a real virtio-gpu DRM device
VKPROBE_ICD:    virtio_icd.json          <- the image ships venus, and only venus
VKPROBE_RUN:    vkprobe: instance ok, 0 physical device(s)
```

The loader comes up, venus loads, `vkCreateInstance` succeeds — and there are
**zero** physical devices, because a plain `virtio-gpu-pci` advertises no
venus capset for the ICD to claim. A real device on a real bus is not a Vulkan
device. Two ways to make that a different profile, neither of which is a GPU
measurement:

* install **lavapipe into the guest** (`HAMLINUX_VULKAN=lavapipe`) — then the
  numbers are llvmpipe's again, on 2 vCPUs instead of 12, and §1 above already
  says the counters will be identical;
* `virtio-gpu-gl-pci,venus=on`, which is the mode that needs the host's
  `/dev/dri` and is exactly the wall above.

There is no QEMU GPU path on this host that reaches a Vulkan device without
the host's `/dev/dri`. QEMU 10.0.8 here offers `virtio-gpu-pci`,
`virtio-gpu-gl-pci` and their `-device` variants and **no `virtio-gpu-rutabaga`**,
which is the one backend that could have been driven headless by a host
*software* Vulkan driver. `-display none` is refused outright by the GL path,
and `egl-headless` needs a GBM-capable render node, i.e. the host GPU.

### So: the one command, on the day a machine is available

On any machine with a real GPU — including this one after a reboot with
`nvidia-drm.modeset=1`, which is the **owner's** call and nobody else's:

```
VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/<real>_icd.json \
    scripts/bench_vk_linux_device.sh
```

It builds what it needs, refuses to be quoted as a GPU result if the device
turns out to be a CPU ICD, asserts byte-identity at every lever setting, and
prints the three tables above for that device plus the per-dispatch cost. The
four numbers to bring back are: `VK_DEVICE_IS_SILICON`, `FRAME_DEVICE_LOCAL`,
the default-vs-`MAX_BATCH=1` pair (the per-dispatch cost), and the
`nocovcache` row (the staging slope, which is zero here and should not be
there). Five minutes, and the last big unknown in the graphics stack is a
table instead of a caveat.

Inside a VM on such a host, the venus path is
`HAMLINUX_DISPLAY=egl-headless,rendernode=/dev/dri/renderD128
scripts/hamlinux_vm.sh venus` — everything but the host EGL/GBM device is
already verified (see the comment block in `scripts/hamlinux_vm.sh`).

## Shader changes (backwards compatible, and verified so)

`scripts/shaders/vk2d_raster.comp` gained three things. Every one of them is a
no-op for existing callers, because `scripts/vk_hostgpu_bridge.c` builds its
push constants from `PushC pc = {0}`:

* `mask_off` doubles as the **BLIT source base**, so one frame can carry many
  different source images in one shared `src[]` arena (was: sources had to
  start at `src[0]`).
* `corners` doubles as the **BLIT source R/B swap flag**, which a BGRA frame
  needs because `vk_2d`'s blit keeps its source in RGBA order and flips per
  pixel.
* `OP_BATCH`, described above.

The bridge's own gates (`raster`, `pageraster`) still report
`MISMATCH 0` after all three.

## vk_core did not link on this line — that is why nothing called it

Worth stating plainly, because it explains the state the task found:
`lib/vk/vk_core.ad` is Hamnix 1.0 **kernel** code. It imports `mm.slab`,
`kernel.printk`, `drivers.video.console.fb_text`, `sys.src.port9.port.devwsys`
and (through `vk_gpu`/`vk_venus`) the native virtio-gpu driver. HANDOFF §2
lists all of those directories as deliberately left behind. So vk_core
*compiled* here and then failed at `ld` with forty undefined symbols.

`user/linux-vkhost.c` is the missing floor: real glibc implementations for the
allocator, printk and the monotonic clock, and **truthful "absent" answers**
for the native virtio-gpu — there is no such driver on this line and there
should not be, because the Linux kernel drives the device. That is what makes
`vk_set_backend(VK_BACKEND_GPU)` correctly refuse rather than pretend. The
framebuffer and window-layer symbols report "no framebuffer" and are declared
**weak**, so a program that links a real implementation (the compositor, via
`user/linux-fb.c`) overrides every one of them.

## Building a program against the backend

```
scripts/hamlinux_build.sh foo.ad build/host/foo user/linux-vk.c -ldl
# ...and, if it imports lib/vk/vk_core.ad:
scripts/hamlinux_build.sh foo.ad build/host/foo user/linux-vk.c user/linux-vkhost.c -ldl
```

These are not in `scripts/hamlinux_build.sh`'s default object list on purpose:
only a program that actually wants the GPU should carry a `libdl` dependency
and a Vulkan device bring-up.

Environment:

| | |
|--|--|
| `HAMNIX_WSYSD_VK=1` / `=0` | the compositor's override, both directions: arm on a CPU ICD / never arm at all |
| `HAMNIX_VK_DISABLE=1` | force the backend off at the shim (the refusal path the gate asserts) |
| `HAMNIX_VK_SPV=<path>` | use a `.spv` from disk instead of the embedded one, for shader work. A named-but-unreadable file says so on stderr and falls back — it does not silently downgrade. |
| `VK_ICD_FILENAMES` | standard Vulkan ICD selection; the gate forces lavapipe |
