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
