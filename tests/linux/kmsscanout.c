/* kmsscanout.c — THE CEILING, MEASURED: GPU composites, display scans out.
 *
 * WHAT THIS ANSWERS. Every number on the /dev/fb path is bounded below by the
 * cost of getting 4-8 MiB from wherever the GPU wrote it to wherever the
 * display reads it, through a CPU write(2). This program removes that step
 * entirely: the compute rasterizer writes into device-local VRAM, that same
 * VRAM is exported as a dmabuf, DRM imports it as a framebuffer, and the CRTC
 * scans it out. No readback, no write(2), no /dev/fb.
 *
 * SO THE NUMBER IT PRODUCES IS THE ARCHITECTURAL CEILING, not a tuning result.
 *
 * SAFETY, and read this before running it. The console framebuffer on this box
 * is nvidia-drmdrmfb -- the same device -- so a hang while holding DRM master
 * can leave the machine with no picture AND no console.
 *   - SET_MASTER is paired with DROP_MASTER on EVERY exit path, including
 *     SIGINT/SIGTERM/SIGSEGV, via a handler that restores the saved CRTC.
 *   - alarm(N) is armed before the first modeset, so even a livelock inside a
 *     loop ends in SIGALRM -> restore -> exit.
 *   - and it is intended to be run under kms_watchdog.sh, which SIGKILLs it;
 *     process death closes the fd, which drops master in the kernel whatever
 *     state this program is in. That is the backstop that does not depend on
 *     any code in this file being correct.
 *   - the previous CRTC configuration is saved before the first SETCRTC and
 *     restored on the way out, so the console comes back where it was.
 *   - --dry-run does everything EXCEPT SET_MASTER and SETCRTC.
 *
 * Only DP-1 is driven, and only with a mode the connector advertises.
 *
 * BUILD: clang -O2 -I<user/> -o kmsscanout kmsscanout.c -ldl
 */
#define _GNU_SOURCE
#include "linux-vk.c"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <string.h>

#if defined(__has_include) && __has_include(<drm/drm.h>)
#  include <drm/drm.h>
#  include <drm/drm_mode.h>
#  include <drm/drm_fourcc.h>
#else
#  include <libdrm/drm.h>
#  include <libdrm/drm_mode.h>
#  include <libdrm/drm_fourcc.h>
#endif

extern int32_t hvk_frame_create_scanout(int32_t, int32_t, int32_t);
extern int32_t hvk_can_export_dmabuf(void);
extern int32_t hvk_frame_is_scanout(void);

/* ---- the master/modeset restore state, reachable from a signal handler --- */
static volatile sig_atomic_t g_restoring;
static int  g_drm = -1;
static int  g_have_master;
static int  g_saved_valid;
static struct drm_mode_crtc g_saved_crtc;

static void restore_console(void)
{
    if (g_restoring) return;
    g_restoring = 1;
    /* WHICH STEP HUNG, if one does. The first version printed nothing between
     * the result and the watchdog's kill, so "restore hangs" was as much as
     * could be said. These four write(2)s are async-signal-safe. */
#define STEP(s) do { const char* _m = s; write(2, _m, strlen(_m)); } while (0)
    if (g_drm >= 0) {
        /* RESTORING THE SAVED CRTC BY HAND DOES NOT WORK HERE, and it is not a
         * detail -- it hangs. On nvidia-drm, a legacy SETCRTC that puts the
         * fbcon's own framebuffer back blocks indefinitely; measured twice,
         * with a vkDeviceWaitIdle in front of it the second time, and both
         * runs sat in that ioctl until the watchdog SIGKILLed them.
         *
         * The recovery that DOES work is the one that does not ask the driver
         * to do anything: drop master (or just die, which closes the fd) and
         * let the kernel's own fb helper restore the console. That path is
         * exercised on every run and the console has come back every time.
         *
         * The save is still taken, and kept below, because it costs nothing
         * and a driver that needs an explicit restore may yet turn up. It is
         * simply not used on this one. */
        if (g_saved_valid) STEP("restore: skipping SETCRTC (hangs on nvidia-drm)\n");
        if (g_have_master) {
            STEP("restore: DROP_MASTER...");
            ioctl(g_drm, DRM_IOCTL_DROP_MASTER, 0);
            STEP(" ok\n");
        }
        STEP("restore: close...");
        close(g_drm);
        g_drm = -1;
        STEP(" ok\n");
    }
#undef STEP
}

static void on_signal(int sig)
{
    restore_console();
    _exit(sig == SIGALRM ? 124 : 128 + sig);
}

static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

int main(int argc, char** argv)
{
    /* Line-buffered: this program can be killed at any instant by its own
     * alarm or by the watchdog, and _exit() from a signal handler does not
     * flush. A block-buffered stdout through a pipe lost EVERY line of a run
     * that had in fact got as far as the modeset, which reads as "it hung
     * immediately" when it did nothing of the sort. */
    setvbuf(stdout, 0, _IONBF, 0);
    int dry = 0, seconds = 8, budget = 30, nomodeset = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--dry-run")) dry = 1;
        /* Render into the exported buffer WITHOUT taking master or setting a
         * mode: isolates the GPU path from the display path, so a hang can be
         * attributed to one or the other without risking the console. */
        else if (!strcmp(argv[i], "--no-modeset")) nomodeset = 1;
        else if (!strcmp(argv[i], "--seconds") && i + 1 < argc) seconds = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--budget")  && i + 1 < argc) budget  = atoi(argv[++i]);
    }

    if (!hvk_available()) { printf("no vulkan device: %s\n", g_err); return 1; }
    uint8_t nm[256]; hvk_device_name(nm, sizeof nm);
    printf("device: %s\n", nm);
    printf("dmabuf export available: %s\n", hvk_can_export_dmabuf() ? "YES" : "NO");
    if (!hvk_can_export_dmabuf()) {
        printf("REFUSING to continue: without the export there is no scanout path.\n");
        return 2;
    }

    /* ---- 1. open DRM and find DP-1, read-only so far ---- */
    g_drm = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
    if (g_drm < 0) { printf("open card0: %s\n", strerror(errno)); return 1; }

    struct drm_mode_card_res res;
    memset(&res, 0, sizeof res);
    if (ioctl(g_drm, DRM_IOCTL_MODE_GETRESOURCES, &res) < 0) {
        printf("GETRESOURCES: %s\n", strerror(errno)); return 1; }
    uint32_t conns[32], crtcs[32], encs[32];
    if (res.count_connectors > 32) res.count_connectors = 32;
    if (res.count_crtcs > 32) res.count_crtcs = 32;
    if (res.count_encoders > 32) res.count_encoders = 32;
    res.connector_id_ptr = (uint64_t)(uintptr_t)conns;
    res.crtc_id_ptr      = (uint64_t)(uintptr_t)crtcs;
    res.encoder_id_ptr   = (uint64_t)(uintptr_t)encs;
    res.fb_id_ptr = 0; res.count_fbs = 0;
    if (ioctl(g_drm, DRM_IOCTL_MODE_GETRESOURCES, &res) < 0) {
        printf("GETRESOURCES(2): %s\n", strerror(errno)); return 1; }
    printf("drm: %u connectors, %u crtcs, %u encoders\n",
           res.count_connectors, res.count_crtcs, res.count_encoders);

    uint32_t conn_id = 0, crtc_id = 0;
    struct drm_mode_modeinfo mode;
    memset(&mode, 0, sizeof mode);
    for (uint32_t i = 0; i < res.count_connectors && !conn_id; i++) {
        struct drm_mode_get_connector c;
        memset(&c, 0, sizeof c);
        c.connector_id = conns[i];
        if (ioctl(g_drm, DRM_IOCTL_MODE_GETCONNECTOR, &c) < 0) continue;
        /* DRM_MODE_CONNECTOR_DisplayPort == 10; only DP-1 is authorised, and
         * it is the only connected one. */
        if (c.connection != 1 /* connected */ || c.count_modes == 0) continue;
        struct drm_mode_modeinfo* ms = calloc(c.count_modes, sizeof *ms);
        uint32_t* es = calloc(c.count_encoders ? c.count_encoders : 1, 4);
        c.modes_ptr = (uint64_t)(uintptr_t)ms;
        c.encoders_ptr = (uint64_t)(uintptr_t)es;
        c.props_ptr = 0; c.prop_values_ptr = 0; c.count_props = 0;
        if (ioctl(g_drm, DRM_IOCTL_MODE_GETCONNECTOR, &c) == 0 && c.count_modes) {
            conn_id = c.connector_id;
            mode = ms[0];                       /* the connector's preferred */
            printf("drm: connector %u type %u connected, mode %ux%u@%u \"%s\"\n",
                   conn_id, c.connector_type, mode.hdisplay, mode.vdisplay,
                   mode.vrefresh, mode.name);
            /* its encoder -> a crtc */
            if (c.encoder_id) {
                struct drm_mode_get_encoder e;
                memset(&e, 0, sizeof e);
                e.encoder_id = c.encoder_id;
                if (ioctl(g_drm, DRM_IOCTL_MODE_GETENCODER, &e) == 0 && e.crtc_id)
                    crtc_id = e.crtc_id;
            }
            if (!crtc_id && res.count_crtcs) crtc_id = crtcs[0];
        }
        free(ms); free(es);
    }
    if (!conn_id || !crtc_id) { printf("no connected connector/crtc\n"); return 1; }
    printf("drm: using connector %u on crtc %u\n", conn_id, crtc_id);

    const uint32_t W = mode.hdisplay, H = mode.vdisplay, PITCH = W * 4;

    /* ---- 2. the GPU frame, device-local and exported ---- */
    int32_t dfd = hvk_frame_create_scanout((int32_t)W, (int32_t)H, 1);
    if (dfd < 0) { printf("hvk_frame_create_scanout -> %d (%s)\n", dfd, g_err); return 1; }
    printf("vk: scanout frame %ux%u, dmabuf fd %d, is_scanout %d\n",
           W, H, dfd, hvk_frame_is_scanout());

    /* ---- 3. DRM imports it and makes a framebuffer of it ---- */
    struct drm_prime_handle prime;
    memset(&prime, 0, sizeof prime);
    prime.fd = dfd;
    if (ioctl(g_drm, DRM_IOCTL_PRIME_FD_TO_HANDLE, &prime) < 0) {
        printf("PRIME_FD_TO_HANDLE: %s\n", strerror(errno)); return 1; }
    struct drm_mode_fb_cmd2 fb;
    memset(&fb, 0, sizeof fb);
    fb.width = W; fb.height = H;
    fb.pixel_format = DRM_FORMAT_XRGB8888;
    fb.handles[0] = prime.handle;
    fb.pitches[0] = PITCH;
    if (ioctl(g_drm, DRM_IOCTL_MODE_ADDFB2, &fb) < 0) {
        printf("ADDFB2: %s\n", strerror(errno)); return 1; }
    printf("drm: gem handle %u -> fb_id %u  (the GPU's VRAM is now a framebuffer)\n",
           prime.handle, fb.fb_id);

    if (dry) {
        printf("\n--dry-run: everything up to and including ADDFB2 succeeded.\n");
        printf("No master was taken and no mode was set. The console is untouched.\n");
        restore_console();
        return 0;
    }

    /* ---- 4. from here the console is at risk. Arm everything first. ---- */
    signal(SIGINT, on_signal); signal(SIGTERM, on_signal);
    signal(SIGSEGV, on_signal); signal(SIGBUS, on_signal);
    signal(SIGABRT, on_signal); signal(SIGALRM, on_signal);
    atexit(restore_console);
    alarm((unsigned)budget);          /* hard ceiling on holding master */

    if (!nomodeset) {
    if (ioctl(g_drm, DRM_IOCTL_SET_MASTER, 0) < 0) {
        printf("SET_MASTER: %s\n", strerror(errno)); return 1; }
    g_have_master = 1;

    memset(&g_saved_crtc, 0, sizeof g_saved_crtc);
    g_saved_crtc.crtc_id = crtc_id;
    if (ioctl(g_drm, DRM_IOCTL_MODE_GETCRTC, &g_saved_crtc) == 0) {
        g_saved_valid = 1;
        g_saved_crtc.set_connectors_ptr = (uint64_t)(uintptr_t)&conn_id;
        g_saved_crtc.count_connectors = g_saved_crtc.mode_valid ? 1 : 0;
        printf("drm: saved crtc %u (fb %u, mode_valid %u) for restore\n",
               crtc_id, g_saved_crtc.fb_id, g_saved_crtc.mode_valid);
    } else printf("drm: WARNING could not save the crtc: %s\n", strerror(errno));

    /* ---- 5. THE MODESET ---- */
    struct drm_mode_crtc sc;
    memset(&sc, 0, sizeof sc);
    sc.crtc_id = crtc_id;
    sc.fb_id = fb.fb_id;
    sc.set_connectors_ptr = (uint64_t)(uintptr_t)&conn_id;
    sc.count_connectors = 1;
    sc.mode = mode;
    sc.mode_valid = 1;
    if (ioctl(g_drm, DRM_IOCTL_MODE_SETCRTC, &sc) < 0) {
        printf("SETCRTC: %s\n", strerror(errno));
        restore_console();
        return 1;
    }
    printf("drm: MODESET OK -- the display is scanning out GPU VRAM directly\n");
    } else {
        printf("drm: --no-modeset: no master, no SETCRTC; rendering only\n");
    }

    /* ---- 6. render frames on the device and count them ----
     * Each frame is a full-screen clear plus a moving band, recorded and
     * dispatched through the SAME hvk op path wsysd uses. There is no
     * present: the pixels are already where the CRTC reads them. */
    double t0 = now_s(), tend = t0 + seconds;
    uint64_t frames = 0;
    double worst = 0;
    while (now_s() < tend) {
        double f0 = now_s();
        if (hvk_frame_begin() != 0) { printf("frame_begin failed\n"); break; }
        uint32_t phase = (uint32_t)(frames % 256);
        hvk_fill_rect(0, 0, 0, (int32_t)W, (int32_t)H,
                      0xff000000u | (phase << 8));
        hvk_fill_rect(0, (int32_t)(frames * 7 % (W - 200)), 100, 200, 200,
                      0xffff8000u);
        hvk_roundrect(60, (int32_t)(frames * 5 % (H - 160)) , 400, 120, 24, 15,
                      0xff2060c0u);
        if (hvk_frame_end() != 0) { printf("frame_end failed: %s\n", g_err); break; }
        double dt = now_s() - f0;
        if (dt > worst) worst = dt;
        frames++;
    }
    double el = now_s() - t0;

    printf("\n==== SCANOUT RESULT ====\n");
    printf("  %llu frames in %.2f s = %.1f fps\n",
           (unsigned long long)frames, el, frames / el);
    printf("  per frame: %.3f ms mean, %.3f ms worst\n",
           el * 1000.0 / (frames ? frames : 1), worst * 1000.0);
    printf("  gpu ns last frame: %llu\n", (unsigned long long)hvk_stat_gpu_ns());
    printf("  bytes copied toward the CPU: 0 (there is no mapping to copy from)\n");

    /* Let the device drain BEFORE handing the CRTC back. Restoring the mode
     * out from under a queue that still has submitted work referencing the
     * framebuffer is what made the first version sit in SETCRTC until the
     * watchdog killed it. */
    p_vkDeviceWaitIdle(g_dev);
    restore_console();
    printf("  console restored, master dropped.\n");
    return 0;
}
