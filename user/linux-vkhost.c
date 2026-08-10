/* user/linux-vkhost.c — the kernel-side symbols lib/vk/vk_core.ad needs,
 * supplied for the Linux line.
 *
 * WHY THIS EXISTS
 * ===============
 * lib/vk/vk_core.ad is Hamnix 1.0 KERNEL code. It imports `mm.slab` for
 * kmalloc, `kernel.printk` for printk, `drivers.video.console.fb_text` for the
 * framebuffer, `sys.src.port9.port.devwsys` for the window layers and (through
 * vk_gpu / vk_venus) the native virtio-gpu driver. None of those directories
 * were copied to this repository — HANDOFF §2 lists them as deliberately left
 * behind, because Linux replaces them.
 *
 * The consequence had gone unrecorded until now: **vk_core.ad does not LINK on
 * this line.** It compiles (the front end is happy) and then fails at ld with
 * forty undefined symbols, which is exactly why nothing outside lib/vk/ calls
 * vk_set_backend here. This file is the missing floor.
 *
 * WHAT EACH GROUP IS, HONESTLY
 * ============================
 *   slab / printk / tsc    Real implementations on glibc: malloc, stderr,
 *                          CLOCK_MONOTONIC. Nothing is faked.
 *   virtio_gpu_*           ABSENT, and they say so (0 / -1 everywhere). On
 *                          this line the LINUX KERNEL owns the GPU; a native
 *                          Adder driver poking virtio PCI would be fighting it
 *                          for the device. So vk_gpu_backend_available() and
 *                          vk_venus_available() are correctly 0, and
 *                          vk_set_backend(VK_BACKEND_GPU) correctly REFUSES
 *                          and stays software. The GPU on this line is reached
 *                          through VK_BACKEND_LINUX (user/linux-vk.c) instead.
 *   fb_* / wsys_draw_*     Report "no framebuffer" so vkQueuePresent does
 *                          nothing rather than scribbling somewhere it should
 *                          not. Scanout on this line belongs to
 *                          user/linux-fb.c and the compositor, which own the
 *                          real /dev/fb; these are declared WEAK so that if a
 *                          program links a real implementation of any of them,
 *                          that one wins and this stub disappears.
 *
 * Everything here is weak except the allocator and printk, so this file can be
 * added to a link without pre-empting a better implementation of any symbol.
 *
 * BUILD: pass it alongside user/linux-vk.c, e.g.
 *   scripts/hamlinux_build.sh foo.ad out.elf user/linux-vk.c user/linux-vkhost.c -ldl
 */

#define _GNU_SOURCE
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define WEAK __attribute__((weak))

/* ------------------------------- mm.slab -------------------------------- */
/* vk_core allocates its instance/device/image/command-buffer records with
 * these. glibc's allocator is the right answer here; 0 means failure, which is
 * the same contract kmalloc has. */
WEAK uint64_t kmalloc(uint64_t size)
{
    if (!size) return 0;
    return (uint64_t)(uintptr_t)malloc((size_t)size);
}

WEAK uint64_t kzalloc(uint64_t size)
{
    if (!size) return 0;
    return (uint64_t)(uintptr_t)calloc(1, (size_t)size);
}

WEAK void kfree(uint64_t obj)
{
    free((void*)(uintptr_t)obj);
}

/* ------------------------------ kernel.printk ---------------------------- */
/* The kernel's printk takes a plain NUL-terminated string plus 0-2 unsigned
 * arguments substituted for its own escapes. Nothing here parses those: the
 * message goes to stderr with the arguments appended, which is enough for a
 * diagnostic and cannot misformat. */
WEAK void printk0(const char* fmt)
{
    fprintf(stderr, "[vk] %s\n", fmt ? fmt : "");
}

WEAK void printk1(const char* fmt, uint64_t a)
{
    fprintf(stderr, "[vk] %s (%llu)\n", fmt ? fmt : "", (unsigned long long)a);
}

WEAK void printk2(const char* fmt, uint64_t a, uint64_t b)
{
    fprintf(stderr, "[vk] %s (%llu, %llu)\n", fmt ? fmt : "",
            (unsigned long long)a, (unsigned long long)b);
}

/* -------------------------- arch/x86 time ------------------------------- */
WEAK uint64_t tsc_monotonic_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

/* ------------------------- the native virtio-gpu ------------------------- */
/* There is no native virtio-gpu driver on this line and there should not be:
 * the Linux kernel drives the device. Reporting "absent" is not a stub in the
 * apologetic sense — it is the true answer, and it is what makes
 * vk_set_backend(VK_BACKEND_GPU) refuse instead of pretending. */
WEAK int32_t  virtio_gpu_available(void)        { return 0; }
WEAK uint32_t virtio_gpu_scanout_width(void)    { return 0; }
WEAK uint32_t virtio_gpu_scanout_height(void)   { return 0; }
WEAK uint64_t virtio_gpu_backing_base(void)     { return 0; }
WEAK int32_t  virtio_gpu_clear_solid(uint32_t rgba) { return -1; }
WEAK int32_t  virtio_gpu_fill_rect_solid(int32_t x, int32_t y, int32_t w,
                                         int32_t h, uint32_t rgba) { return -1; }
WEAK int32_t  virtio_gpu_present_frame(void)    { return -1; }
WEAK int32_t  virtio_gpu_present_frame_rect(int32_t x, int32_t y,
                                            int32_t w, int32_t h) { return -1; }
WEAK int32_t  virtio_gpu_present_rgba(uint64_t src, uint32_t w, uint32_t h) { return -1; }

/* virgl/venus 3D: same story, one layer up. */
WEAK int32_t  virtio_gpu_3d_available(void)     { return 0; }
WEAK int32_t  virtio_gpu_submit_3d(uint64_t cmds, uint64_t nbytes) { return -1; }
WEAK uint32_t virtio_gpu_3d_create_rt(uint32_t w, uint32_t h) { return 0; }
WEAK uint32_t virtio_gpu_3d_create_frame_rt(uint32_t w, uint32_t h) { return 0; }
WEAK uint32_t virtio_gpu_3d_create_scratch_rt(uint32_t w, uint32_t h) { return 0; }
WEAK uint32_t virtio_gpu_3d_create_cov_tex(uint32_t w, uint32_t h) { return 0; }
WEAK uint32_t virtio_gpu_3d_create_vbuf(uint32_t nbytes) { return 0; }
WEAK uint64_t virtio_gpu_3d_rt_backing(void)    { return 0; }
WEAK uint64_t virtio_gpu_3d_frame_rt_backing(void) { return 0; }
WEAK uint64_t virtio_gpu_3d_cov_tex_backing(void) { return 0; }
WEAK uint64_t virtio_gpu_3d_vbuf_backing(void)  { return 0; }
WEAK int32_t  virtio_gpu_3d_rt_readback(uint32_t rt, uint32_t w, uint32_t h) { return -1; }
WEAK int32_t  virtio_gpu_3d_frame_rt_readback(uint32_t rt, uint32_t w, uint32_t h) { return -1; }
WEAK int32_t  virtio_gpu_3d_frame_rt_upload(uint32_t rt, uint32_t w, uint32_t h) { return -1; }
WEAK int32_t  virtio_gpu_3d_cov_tex_upload(uint32_t tex, uint32_t w, uint32_t h) { return -1; }
WEAK int32_t  virtio_gpu_3d_vbuf_upload(uint32_t vbuf, uint32_t nbytes) { return -1; }
WEAK int32_t  virtio_gpu_3d_rt_roundtrip_probe(void) { return -1; }

/* --------------------- framebuffer / window layers ----------------------- */
/* Weak, and "there is no framebuffer here". vkQueuePresent consults
 * fb_get_initialized() first, so it does nothing instead of writing into a
 * framebuffer this process does not own. The compositor owns /dev/fb through
 * user/linux-fb.c; a program that links that can override every one of these. */
WEAK int32_t  fb_get_initialized(void)          { return 0; }
WEAK uint64_t fb_get_width(void)                { return 0; }
WEAK uint64_t fb_get_height(void)               { return 0; }
WEAK void     fb_present_rgba_row(uint64_t src_y, uint64_t scr_x0, uint64_t scr_y,
                                  uint64_t w, const uint8_t* src,
                                  uint64_t src_pitch_px) { }
WEAK uint64_t fb_font_glyph_addr(void)          { return 0; }
WEAK int32_t  wsys_draw_ensure_fb_layer(int32_t wid, const uint8_t* name,
                                        uint64_t namelen, int64_t w, int64_t h)
{
    return -1;
}
WEAK int64_t  wsys_draw_fb_store(int32_t wid, int32_t slot,
                                 const uint8_t* src, uint64_t count)
{
    return -1;
}
