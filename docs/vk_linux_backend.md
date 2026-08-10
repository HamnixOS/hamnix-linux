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
| `scripts/shaders/vk2d_raster.comp` | the compute rasterizer (pre-existing; extended here — see "shader changes"). |
| `tests/linux/vk_linux_test.ad`, `tests/linux/vk_core_linux_test.ad`, `scripts/test_vk_linux.sh` | the gates. |

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

**So: do not enable this by default on the strength of the host gate.** The
host gate proves it is *correct*. Whether it is *faster* is a per-device
question, it must be answered in the VM or on the target with these two
benches, and the backend is built to be flipped off in one call when the answer
is no.

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
| `HAMNIX_VK_DISABLE=1` | force the backend off (the refusal path the gate asserts) |
| `HAMNIX_VK_SPV=<path>` | use a `.spv` from disk instead of the embedded one, for shader work. A named-but-unreadable file says so on stderr and falls back — it does not silently downgrade. |
| `VK_ICD_FILENAMES` | standard Vulkan ICD selection; the gate forces lavapipe |
