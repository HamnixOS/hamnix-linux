/* user/linux-audio.c — /dev/audio, /dev/audioctl and /dev/audioin.
 *
 * WHAT IT IS FOR
 * ==============
 * This is the port of Hamnix's audio character device
 * (drivers/audio/audio_cdev.ad, backed by drivers/audio/hda.ad) onto the
 * Linux kernel's ALSA PCM interface. The protocol is NOT invented here: it is
 * reproduced from that device, so user/aplay.ad, user/playtone.ad,
 * user/hamaudioscene.ad, user/hamaudioselftest.ad and lib/hamsdl_audio_dev.ad
 * run against it unchanged. A client sees three files and no ioctls:
 *
 *     ctl = open("/dev/audioctl")     aud = open("/dev/audio")
 *     write(ctl, "rate 48000\n")      write(aud, <s16le PCM>)
 *     write(ctl, "channels 2\n")      write(ctl, "start\n")
 *     write(ctl, "format s16le\n")
 *
 * Until this file existed there was no /dev/audio on this line at all, and
 * the failure had the exact shape this project exists to beat: sys_open_write
 * created unserved /dev/ paths as ORDINARY FILES, so playtone wrote 24 000
 * frames into a regular file called /dev/audio and reported that it had
 * played a 1 kHz tone. That hole is closed in linux-syscalls.c; this file is
 * the other half — the device that makes the honest answer a working one.
 *
 * THE PROTOCOL, as ported
 * =======================
 * /dev/audio
 *   write  PCM. Two modes, chosen by the ctl file:
 *            STAGED (the default): writes accumulate into a 1 MiB clip
 *              buffer at the file offset; a write at offset 0 truncates the
 *              clip. Nothing sounds until `start`. This is the mode
 *              playtone and lib/hamsdl_audio_dev.ad use.
 *            STREAM (after `streamopen`): writes go straight to the PCM
 *              ring and the offset is ignored. A write blocks while the ring
 *              is full unless `nonblock 1`, in which case it returns a SHORT
 *              COUNT — callers must loop, as user/aplay.ad's push() does.
 *          A zero-length write drains (STREAM) or starts (STAGED), matching
 *          devaudio_write's `count == 0` arms.
 *   read   ONE status line, then EOF. Byte-identical in shape to Hamnix's,
 *          with this line's own telemetry appended -- which is Hamnix's own
 *          idiom for extending it without breaking a parser that stops early:
 *            loaded <n> cap <n> master <pct> streams <p0> <p1> <p2> <p3>
 *            mute <0|1> space <bytes> pos <bytes>
 *            mixed <n> hush <n> nogain <n>
 *          user/hamctl.ad parses `master` and `mute` out of exactly this.
 *          Reading /dev/audio is NOT capture — /dev/audioin is.
 * /dev/audioctl
 *   write  one verb per line: rate, channels, bits, format, streamopen,
 *          nonblock, drain, start, stop, reset, master, mute, unmute,
 *          `stream <id> <pct>` and mixplay.
 *   read   always EOF.
 * /dev/audioin
 *   read   captured PCM, non-blocking: an empty ring answers 0, not EAGAIN.
 *   write  refused.
 *
 * Defaults are Hamnix's: 48000 Hz, 2 channels, s16le, interleaved.
 *
 * WHY RAW ALSA IOCTLS AND NOT libasound
 * =====================================
 * The whole runtime is statically reachable from every Adder binary and the
 * initramfs carries only what ldd finds. Linking libasound would drag in its
 * plugin/config machinery (/usr/share/alsa/alsa.conf and a plugin tree) for a
 * device that needs exactly one hardware substream. The kernel's PCM char
 * device is a perfectly good interface on its own — the ioctls below are the
 * same ones libasound's `hw:` plugin issues — so this file talks to
 * /dev/snd/pcmC%uD%up directly and depends on nothing but libc. The handful
 * of ALSA structures it needs are declared here rather than pulled from
 * <sound/asound.h>, so that scripts/ac-link.sh can still build the runtime
 * inside a Debian namespace that has no kernel headers installed.
 *
 * THE SOFTWARE MIXER — two programs making a sound at the same time
 * =================================================================
 * An ALSA hardware substream has exactly ONE writer, so for a while this file
 * had none: a second process opening /dev/audio while another played got
 * EBUSY, `stream` and `mixplay` returned -EINVAL, and the status line's
 * `streams 100 100 100 100` was a placeholder that meant nothing. That is now
 * gone. What replaced it is Hamnix's design, ported rather than invented, from
 * drivers/audio/hda.ad (`hda_stream_mix`, `hda_owner`, the DMA ring and the
 * service tick) and drivers/audio/mixer.ad (the four per-stream volumes, the
 * Q8 gains, the saturating sum, the master gain and the mute latch).
 *
 * THE THREE PIECES, and what each one is the port OF:
 *
 *   THE MIX RING is /srv/audio, a MAP_SHARED file (see au_attach), and it is
 *   the port of hda.ad's DMA ring: AU_RING_BYTES of s16le PCM, a monotonic
 *   `play` cursor and a monotonic `w` high-water. Every writer in the system
 *   maps it. hda.ad's ring is kernel DMA memory that every process reaches
 *   through the one kernel; here the processes are separate and the shared
 *   mapping is what stands in for that.
 *
 *   THE PUMP is the port of the DMA ENGINE and of hda.ad's service tick. It is
 *   a detached process (double-forked, setsid, reparented to PID 1) that owns
 *   the one ALSA substream and does nothing but move the ring into it, one
 *   period at a time. NOTHING WAKES IT: the blocking write(2) to the substream
 *   is paced by the hardware itself, exactly as the DMA engine is. When no
 *   writer has anything it hands the card a period of SILENCE, which is why a
 *   slow or stalled writer cannot stall the others -- the clock keeps running
 *   and the other streams keep flowing through it. After AU_IDLE_MS with
 *   nothing to play it CLOSES THE CARD and parks in a futex on the shared
 *   segment: that is hda.ad's "stop a ring whose owner has exited" from the
 *   service tick, and it is a park rather than an exit because an orphan that
 *   exits under this PID 1 is a zombie (see the PARK comment in au_pump_loop).
 *
 *   THE MIX is au_mix(), the port of hda_stream_mix() and of mixer.ad's mix
 *   loop. A writer SUMS its samples into the ring just ahead of the play
 *   cursor -- never appends behind a ring-full of somebody else's audio, which
 *   is the "two apps, half the sounds don't play" report hda.ad's comment
 *   names. Each writer carries its OWN cursor, so a slow producer falls behind
 *   on its own account and the fast one is untouched.
 *
 * CLIPPING: SATURATION, not scaling. Four streams at full scale sum to four
 * times int16, and the two honest answers are to clamp the sum or to divide
 * every stream by four. This clamps -- `_hda_sat_add_s16` and mixer.ad's
 * `_mix_sat_add` both do, and the reason is that dividing makes the COMMON
 * case (one program playing) 12 dB quiet to buy headroom for a case that
 * rarely happens. A sum that clips is audible distortion on a loud moment; a
 * mixer that is permanently a quarter volume is a device nobody can hear. The
 * per-stream volume is the control for the case where you want the other one.
 *
 * THE FOUR NUMBERS ON THE STATUS LINE ARE REAL. `streams <p0> <p1> <p2> <p3>`
 * is the four AU_SLOTS per-stream Q8 gains, in percent, and `stream <id>
 * <pct>` sets one. A slot is claimed by the pid of the first writer to use it
 * and released when that pid closes the device or dies (au_reap, the port of
 * hda.ad's `_hda_owner_alive`). AND THE FIFTH: hda_stream_mix has no voice
 * table and so no concurrency ceiling, and neither has this. A fifth
 * simultaneous writer still SOUNDS -- it is summed into the ring like the
 * others -- it just has no volume slot of its own and plays at unity. That is
 * counted, and the count is on the status line as `nogain`, because a stream
 * whose volume control silently does nothing is the kind of quiet lie this
 * tree is organised against.
 *
 * WHAT IS STILL NOT PORTED, said plainly
 * ======================================
 *  * NO RESAMPLING AND NO FORMAT CONVERSION. The pump runs the hardware at
 *    one rate/channel-count/width, set by the first stream to arrive. A later
 *    stream that asks for a different one is REFUSED BY NAME on the ctl write
 *    -- "the mixer is running at 48000 Hz / 2 ch / 16 bit; this stream asked
 *    for 44100" -- and not silently played at the wrong speed. When the mixer
 *    is idle the format is free to change.
 *  * THE MIX MATHS IS s16le, as mixer.ad's is. `bits 8`, `bits 24` and
 *    `bits 32` still work for a lone stream (the ring carries the bytes
 *    through untouched), but a SECOND writer arriving while the hardware is in
 *    one of those widths is refused by name rather than summed wrongly.
 *  * NOTHING, for `master`/`mute`: those drive the codec's own amps, the same
 *    as on Hamnix, through the control device. A card with no mixer elements
 *    at all (virtio_snd has none) falls back to scaling the mix in software in
 *    the pump, so the verb means the same thing either way.
 *  * `mixplay` is `start`. On Hamnix it means "render the mixer slots and hand
 *    the result to the DMA buffer", which is a distinct act because the plain
 *    /dev/audio path there does not go through mixer.ad. Here EVERY path goes
 *    through the mix ring, so the two verbs name the same thing and `mixplay`
 *    is honoured rather than refused.
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sched.h>
#include <signal.h>
#include <sys/syscall.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "linux-audio.h"

/* ------------------------------------------------------------------ *
 * The slice of the ALSA PCM ABI this needs.
 *
 * Declared here rather than included so the runtime builds with libc headers
 * alone. These are UAPI: the layout is fixed and cannot change.
 * ------------------------------------------------------------------ */
struct alsa_interval {
    unsigned int min, max;
    unsigned int openmin:1, openmax:1, integer:1, empty:1;
};
struct alsa_mask { uint32_t bits[8]; };          /* SNDRV_MASK_MAX 256 */

struct alsa_hw_params {
    unsigned int flags;
    struct alsa_mask masks[3];                   /* ACCESS..SUBFORMAT   */
    struct alsa_mask mres[5];
    struct alsa_interval intervals[12];          /* SAMPLE_BITS..TICK_TIME */
    struct alsa_interval ires[9];
    unsigned int rmask, cmask, info, msbits, rate_num, rate_den;
    unsigned long fifo_size;
    unsigned char sync[16];
    unsigned char reserved[48];
};

struct alsa_sw_params {
    int tstamp_mode;
    unsigned int period_step;
    unsigned int sleep_min;
    unsigned long avail_min;
    unsigned long xfer_align;
    unsigned long start_threshold;
    unsigned long stop_threshold;
    unsigned long silence_threshold;
    unsigned long silence_size;
    unsigned long boundary;
    unsigned int proto;
    unsigned int tstamp_type;
    unsigned char reserved[56];
};

/* Parameter indices. Masks are 0..2, intervals 8..19. */
#define P_ACCESS        0
#define P_FORMAT        1
#define P_SUBFORMAT     2
#define P_FIRST_MASK    0
#define P_LAST_MASK     2
#define P_SAMPLE_BITS   8
#define P_FRAME_BITS    9
#define P_CHANNELS     10
#define P_RATE         11
#define P_PERIOD_SIZE  13
#define P_PERIODS      15
#define P_BUFFER_SIZE  17
#define P_FIRST_INT     8
#define P_LAST_INT     19

#define ACCESS_RW_INTERLEAVED 3
#define FMT_S8       0
#define FMT_U8       1
#define FMT_S16_LE   2
#define FMT_S24_3LE 32
#define FMT_S32_LE  10

#define PCM_IOCTL_HW_PARAMS  _IOWR('A', 0x11, struct alsa_hw_params)
#define PCM_IOCTL_SW_PARAMS  _IOWR('A', 0x13, struct alsa_sw_params)
#define PCM_IOCTL_PREPARE    _IO('A', 0x40)
#define PCM_IOCTL_START      _IO('A', 0x42)
#define PCM_IOCTL_DROP       _IO('A', 0x43)
#define PCM_IOCTL_DRAIN      _IO('A', 0x44)
#define PCM_IOCTL_DELAY      _IOR('A', 0x21, long)

/* The control device, which is where a codec's amps live. Needed because an
 * HDA codec comes up MUTED: the guest driver played the tone correctly, the
 * DMA ran, and the emulated line-out emitted digital silence, because nothing
 * had ever unmuted it. On a desktop distribution alsactl does this at boot
 * from a saved state file; here the device does it for itself when it brings
 * the stream up, which is the right place -- /dev/audio is the whole audio
 * stack on this line and there is no session daemon behind it. */
struct alsa_elem_id {
    unsigned int numid;
    int iface;
    unsigned int device, subdevice;
    unsigned char name[44];
    unsigned int index;
};
struct alsa_elem_list {
    unsigned int offset, space, used, count;
    struct alsa_elem_id *pids;
    unsigned char reserved[50];
};
struct alsa_elem_info {
    struct alsa_elem_id id;
    int type;
    unsigned int access, count;
    int owner;
    union {
        struct { long min, max, step; } integer;
        unsigned char reserved[128];
    } value;
    unsigned char reserved[64];
};
struct alsa_elem_value {
    struct alsa_elem_id id;
    unsigned int indirect:1;
    union {
        struct { long value[128]; } integer;
        unsigned char reserved[512];
    } value;
    unsigned char reserved[128];
};
#define CTL_IOCTL_ELEM_LIST  _IOWR('U', 0x10, struct alsa_elem_list)
#define CTL_IOCTL_ELEM_INFO  _IOWR('U', 0x11, struct alsa_elem_info)
#define CTL_IOCTL_ELEM_READ  _IOWR('U', 0x12, struct alsa_elem_value)
#define CTL_IOCTL_ELEM_WRITE _IOWR('U', 0x13, struct alsa_elem_value)
#define ELEM_IFACE_MIXER  2
#define ELEM_TYPE_BOOLEAN 1
#define ELEM_TYPE_INTEGER 2

/* A device that cannot do what it was asked says so, by name, on stderr.
 * This is not debug tracing -- it only ever fires on a failure, and it exists
 * because the clients (user/playtone.ad, user/aplay.ad, lib/hamsdl_audio_dev.ad)
 * were all written against a kernel device that could not fail this way and
 * therefore check almost nothing. Without it a mis-set rate or a busy card is
 * a silent nothing, which is the one answer this line does not accept. */
static void au_fail(const char *what)
{
    fprintf(stderr, "[audio] %s: %s\n", what, strerror(errno));
}

static void mask_any(struct alsa_mask *m)   { memset(m->bits, 0xff, sizeof m->bits); }
static void mask_one(struct alsa_mask *m, unsigned bit)
{
    memset(m->bits, 0, sizeof m->bits);
    if (bit < 256) m->bits[bit >> 5] |= 1u << (bit & 31);
}
static void hwp_any(struct alsa_hw_params *p)
{
    memset(p, 0, sizeof *p);
    for (int i = P_FIRST_MASK; i <= P_LAST_MASK; i++)
        mask_any(&p->masks[i - P_FIRST_MASK]);
    for (int i = P_FIRST_INT; i <= P_LAST_INT; i++) {
        p->intervals[i - P_FIRST_INT].min = 0;
        p->intervals[i - P_FIRST_INT].max = UINT_MAX;
    }
    p->rmask = ~0u;
    p->info  = ~0u;
}
static void hwp_set_mask(struct alsa_hw_params *p, int idx, unsigned bit)
{
    mask_one(&p->masks[idx - P_FIRST_MASK], bit);
}
static void hwp_set_int(struct alsa_hw_params *p, int idx, unsigned val)
{
    struct alsa_interval *iv = &p->intervals[idx - P_FIRST_INT];
    iv->min = iv->max = val;
    iv->integer = 1;
}
static unsigned hwp_get_int(const struct alsa_hw_params *p, int idx)
{
    return p->intervals[idx - P_FIRST_INT].min;
}

/* ------------------------------------------------------------------ *
 * Device state. Global, because the Hamnix device it ports is global: the
 * format set through /dev/audioctl governs the next write to /dev/audio no
 * matter which descriptor either arrived on.
 * ------------------------------------------------------------------ */
#define CLIP_CAP  (1024u * 1024u)       /* hda.ad: hda_pcm_cap = 1 MiB */

static int      pcm_fd  = -1;           /* playback substream           */
static unsigned pcm_card;               /* the card it came from        */
static int      mixer_hw;               /* the codec has real amps, so
                                         * `master` drives them and the
                                         * software scaler stands down  */
static int      cap_fd  = -1;           /* capture substream            */
static int      pcm_prepared;           /* PREPARE issued since the last
                                         * DRAIN/DROP/underrun          */
static unsigned cfg_rate  = 48000;
static unsigned cfg_chans = 2;
static unsigned cfg_bits  = 16;
static int      cfg_dirty = 1;          /* reopen/reconfigure on next use */
static unsigned buf_bytes;              /* the ring, once configured     */
static unsigned frame_bytes = 4;

static int      stream_mode;            /* `streamopen` seen             */
static int      nonblock;               /* `nonblock 1`                  */
static unsigned master_pct = 100;
static int      muted;

static uint8_t *clip;                   /* the staged one-shot buffer    */
static unsigned clip_len;
static int      clip_pending;           /* staged, and no `start` yet    */

static uint64_t played_bytes;           /* total handed to the ring      */

/* ================================================================== *
 * THE MIX RING — the port of hda.ad's DMA ring into a shared mapping.
 *
 * Every field here is written by more than one process, so every rule about
 * who may touch what is stated where the field is. The short version: `play`
 * belongs to the pump and nothing else advances it; `w` and the ring bytes are
 * touched only under `lock`; a slot belongs to the pid in it.
 * ================================================================== */

#define AU_MAGIC     0x4155444fu        /* "AUDO"                         */
#define AU_VERSION   1

/* 245760 bytes = 1.28 s of 48 kHz stereo s16le, and it is divisible by 2, 3,
 * 4, 6, 8, 12, 16 and 24 -- every frame size this device can be configured
 * for. That is not tidiness: a ring whose length is not a whole number of
 * frames shifts every sample by a byte on each wrap and turns the stream into
 * noise a lap at a time. */
#define AU_RING_BYTES 245760u
#define AU_SLOTS      4                 /* mixer.ad: MIX_MAX_STREAMS = 4  */
#define AU_UNITY      256               /* mixer.ad: Q8, 256 == 100 %     */
#define AU_IDLE_MS    2500              /* pump quits after this much hush */
#define AU_CHUNK      8192u             /* bytes summed per lock hold     */

struct au_slot {
    int32_t  used;                      /* 1 == claimed                    */
    int32_t  pid;                        /* the process it belongs to       */
    int32_t  gain;                       /* Q8 per-stream volume, 0..256    */
    int32_t  pad;
    uint64_t mixw;                       /* THIS stream's write cursor.
                                          * Per-slot, and that is the whole
                                          * reason a slow writer cannot stall
                                          * a fast one: they fall behind
                                          * independently.                  */
    uint64_t written;                    /* bytes this stream has summed    */
};

struct au_shm {
    uint32_t magic, version;
    int32_t  lock;                       /* the ring/`w` spinlock           */
    int32_t  pump_pid;                   /* 0 == no pump                    */
    uint32_t rate, chans, bits;          /* the format the MIX runs at      */
    uint32_t fmt_gen;                    /* bumped when the format changes  */
    uint32_t period_bytes;               /* published by the pump           */
    uint32_t master_pct, muted;
    uint32_t hw_amps;                    /* the codec has real amps, so the
                                          * pump must NOT scale as well     */
    uint32_t nogain;                     /* writers that found no free slot
                                          * and are playing at unity        */
    uint64_t play;                       /* bytes the pump has consumed     */
    uint64_t w;                          /* high-water summed by anyone     */
    uint64_t mixed_in;                   /* hda_mixed_in                    */
    uint64_t clipped;                    /* hda_mix_clipped                 */
    uint64_t sat;                        /* samples the sum actually clamped*/
    uint64_t underruns;                  /* pump periods filled with hush   */
    uint32_t wake;                       /* the futex the parked pump sleeps
                                          * on; every writer bumps it       */
    uint32_t pad2;
    struct au_slot slot[AU_SLOTS];
    uint8_t  ring[AU_RING_BYTES];
};

static struct au_shm *shm;
static int  my_slot = -1;
static pid_t my_slot_pid;
static int  in_pump;                    /* this process IS the pump         */

static void au_pump_ensure(void);

/* The frame size the MIX is running at, taken from the shared format rather
 * than from this process's idea of it: a writer that never opened the card has
 * no `frame_bytes` of its own, and a partial frame in the ring shifts every
 * later sample by a byte. */
static unsigned au_frame(void)
{
    unsigned f = shm->chans * ((shm->bits + 7) / 8);
    return f ? f : 4;
}

static const char *au_shm_path(void)
{
    const char *p = getenv("HAMAUDIO");
    if (p && *p) return p;
    return "/srv/audio";                /* linuxinit mounts /srv 1777       */
}

static uint64_t au_now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000u + (uint64_t)(ts.tv_nsec / 1000000);
}

static void au_nap(unsigned ms)
{
    struct timespec ts = { ms / 1000, (long)(ms % 1000) * 1000000L };
    nanosleep(&ts, NULL);
}

/* THE PARK. An idle pump must cost nothing -- THE IDLE CENSUS in HANDOFF.md
 * is the record of what a polling loop costs on this tree -- and it must wake
 * the instant a sound arrives. A futex on a word in the shared segment is both:
 * the pump sleeps in the kernel with no timer running, and a writer's
 * increment-and-wake reaches it in microseconds. It is the same mechanism
 * sys_waitfds uses to park a /dev/wsys client on the `inputgen` word, for the
 * same reason. */
static void au_futex_wait(uint32_t *w, uint32_t val, unsigned ms)
{
    struct timespec ts = { ms / 1000, (long)(ms % 1000) * 1000000L };
    syscall(SYS_futex, w, 9 /* FUTEX_WAIT_BITSET */, val, &ts, NULL,
            (uint32_t)-1);
}
static void au_futex_wake(uint32_t *w)
{
    syscall(SYS_futex, w, 10 /* FUTEX_WAKE_BITSET */, INT_MAX, NULL, NULL,
            (uint32_t)-1);
}
static void au_kick(void)
{
    if (!shm) return;
    __sync_fetch_and_add(&shm->wake, 1);
    au_futex_wake(&shm->wake);
}

/* ATTACH BEFORE CREATE, on every candidate -- the same rule and for the same
 * reason as linux-wsys.c's shm_attach: O_CREAT on a file somebody else owns in
 * a sticky world-writable directory is refused by fs.protected_regular, and a
 * failure that falls through to the next candidate would have this process
 * mixing into a ring no pump is draining. */
static int au_attach(void)
{
    if (shm) return 0;
    const char *cands[3];
    int nc = 0;
    cands[nc++] = au_shm_path();
    cands[nc++] = "/dev/shm/hamnix-audio";
    cands[nc++] = "/tmp/hamnix-audio";

    int fd = -1;
    for (int i = 0; i < nc && fd < 0; i++) {
        fd = open(cands[i], O_RDWR);
        if (fd < 0) fd = open(cands[i], O_RDWR | O_CREAT, 0666);
    }
    if (fd < 0) return -1;
    if (fchmod(fd, 0666) < 0) { /* not the creator; the mode is already set */ }

    struct stat st;
    if (fstat(fd, &st) < 0) { int e = errno; close(fd); errno = e; return -1; }
    if ((uint64_t)st.st_size < sizeof(struct au_shm)
        && ftruncate(fd, (off_t)sizeof(struct au_shm)) < 0) {
        int e = errno; close(fd); errno = e; return -1;
    }
    void *m = mmap(NULL, sizeof(struct au_shm), PROT_READ | PROT_WRITE,
                   MAP_SHARED, fd, 0);
    int e = errno;
    close(fd);
    if (m == MAP_FAILED) { errno = e; return -1; }
    shm = (struct au_shm *)m;
    if (shm->magic != AU_MAGIC || shm->version != AU_VERSION) {
        memset(shm, 0, sizeof *shm);
        shm->magic      = AU_MAGIC;
        shm->version    = AU_VERSION;
        shm->rate       = 48000;
        shm->chans      = 2;
        shm->bits       = 16;
        shm->master_pct = 100;
        for (int i = 0; i < AU_SLOTS; i++)
            shm->slot[i].gain = AU_UNITY;   /* mixer.ad: default unity      */
    }
    return 0;
}

/* The spinlock. Held for at most AU_CHUNK bytes of summing, which is tens of
 * microseconds. A holder that is KILLED mid-sum would otherwise wedge every
 * other program on the box, so the wait has a deadline and breaking it is
 * reported rather than silent. */
static void au_lock(void)
{
    for (unsigned spin = 0;; spin++) {
        if (__sync_bool_compare_and_swap(&shm->lock, 0, 1))
            return;
        if (spin < 200) { sched_yield(); continue; }
        if (spin > 200 + 500) {
            fprintf(stderr, "[audio] breaking a mix lock held for 500 ms -- "
                            "a writer died inside it\n");
            shm->lock = 1;
            return;
        }
        au_nap(1);
    }
}
static void au_unlock(void) { __sync_lock_release(&shm->lock); }

/* hda.ad's `_hda_owner_alive`, applied to every slot: a slot whose pid is gone
 * is free. Without this a program that crashed mid-clip would hold one of the
 * four volume slots for the life of the machine. */
static void au_reap(void)
{
    for (int i = 0; i < AU_SLOTS; i++) {
        if (!shm->slot[i].used) continue;
        pid_t p = (pid_t)shm->slot[i].pid;
        if (p > 0 && kill(p, 0) == 0) continue;
        if (p > 0 && errno == EPERM) continue;   /* alive, just not ours    */
        shm->slot[i].used = 0;
        shm->slot[i].pid  = 0;
        shm->slot[i].mixw = 0;
    }
}

/* Claim this process's volume slot. Returns the slot index, or -1 when all
 * four are taken -- and -1 is NOT an error: hda_stream_mix has no voice table
 * and no ceiling, so a fifth stream still plays. It plays at unity and is
 * counted in `nogain`. */
static int au_slot_claim(void)
{
    if (my_slot >= 0 && my_slot_pid == getpid()
        && shm->slot[my_slot].used && shm->slot[my_slot].pid == (int32_t)getpid())
        return my_slot;
    my_slot = -1;
    au_lock();
    au_reap();
    for (int i = 0; i < AU_SLOTS; i++) {
        if (shm->slot[i].used) continue;
        shm->slot[i].used = 1;
        shm->slot[i].pid  = (int32_t)getpid();
        if (shm->slot[i].gain <= 0) shm->slot[i].gain = AU_UNITY;
        shm->slot[i].mixw = 0;
        shm->slot[i].written = 0;
        my_slot = i;
        my_slot_pid = getpid();
        break;
    }
    if (my_slot < 0) shm->nogain++;
    au_unlock();
    au_kick();
    return my_slot;
}

static void au_slot_release(void)
{
    if (!shm || my_slot < 0) return;
    if (shm->slot[my_slot].pid == (int32_t)getpid()) {
        shm->slot[my_slot].used = 0;
        shm->slot[my_slot].pid  = 0;
        shm->slot[my_slot].mixw = 0;
    }
    my_slot = -1;
}

static int au_live_writers(void)
{
    int n = 0;
    for (int i = 0; i < AU_SLOTS; i++)
        if (shm->slot[i].used) n++;
    return n;
}

/* ---- the mix maths, straight out of mixer.ad ---------------------- */

static int16_t au_sat_add(int32_t a, int32_t b)
{
    int32_t s = a + b;
    if (s >  32767) { shm->sat++; return  32767; }
    if (s < -32768) { shm->sat++; return -32768; }
    return (int16_t)s;
}
static int32_t au_gain(int32_t sample, int32_t g)
{
    return (int32_t)(((int64_t)sample * (int64_t)g) / 256);
}

/* THE GUARD. How far ahead of the play cursor a stream's samples are placed.
 * It must be at least one pump period, because the pump consumes [play,
 * play+period) without the writer's knowledge -- anything laid down inside
 * that window is bytes the writer wrote and nobody heard. Two periods, which
 * is hda.ad's `_hda_mix_guard` reasoning arriving at the same place: past the
 * consumer, and under the ~100 ms at which a sound stops feeling attached to
 * the thing that caused it. At 1024-frame periods and 48 kHz stereo that is
 * 43 ms. */
static uint64_t au_guard(void)
{
    uint32_t per = shm->period_bytes ? shm->period_bytes : 4096;
    uint64_t g = (uint64_t)per * 2;
    if (g > AU_RING_BYTES / 4) g = AU_RING_BYTES / 4;
    unsigned fb = au_frame();
    return (g / fb) * fb;
}

/* Sum `n` bytes into the ring ahead of the play cursor. This is
 * hda_stream_mix, and the structure is deliberately the same: anchor the
 * cursor to the live edge if it has fallen behind, refuse to run more than
 * half a ring ahead (and SAY so), take what fits, sum with saturation.
 *
 * Returns bytes consumed. Short returns are real and callers loop. */
static int64_t au_mix(const uint8_t *buf, size_t n, int blocking)
{
    if (au_attach() < 0) { errno = ENODEV; return -1; }
    /* BEFORE the loop, not after it: with no pump running nothing advances
     * `play`, so the first blocking wait would never end. */
    au_pump_ensure();
    int slot = au_slot_claim();
    int32_t g = slot >= 0 ? shm->slot[slot].gain : AU_UNITY;

    /* The mix maths is s16le. A lone stream at another width is carried
     * through untouched; a second one is refused BY NAME rather than summed
     * as if its bytes were 16-bit samples. */
    int wide = shm->bits != 16;
    if (wide && au_live_writers() > 1) {
        fprintf(stderr, "[audio] the mixer is running at %u-bit and the mix "
                        "maths is s16le: a second stream cannot be summed "
                        "into it\n", shm->bits);
        errno = EBUSY;
        return -1;
    }

    size_t done = 0;
    uint64_t stalled = 0;
    while (done < n) {
        au_lock();
        uint64_t play  = shm->play;
        uint64_t edge  = play + au_guard();
        uint64_t *mixw = slot >= 0 ? &shm->slot[slot].mixw : NULL;
        uint64_t cur   = mixw ? *mixw : 0;
        if (!mixw || cur < edge) cur = edge;
        /* Never more than half a ring ahead: past that the sound is heard so
         * late it is no longer attached to what caused it. Reported, not
         * hidden -- hda.ad's mix-in BACKLOG arm. */
        uint64_t limit = play + AU_RING_BYTES / 2;
        if (cur >= limit) {
            au_unlock();
            if (!blocking) break;
            au_pump_ensure();               /* it may have been reaped */
            au_nap(2);
            if (++stalled > 15000) {            /* 30 s: no pump is draining */
                fprintf(stderr, "[audio] no pump has drained the mix ring for "
                                "30 s; giving up with %zu of %zu bytes\n",
                        done, n);
                break;
            }
            continue;
        }
        stalled = 0;
        size_t take = n - done;
        if (take > AU_CHUNK) take = AU_CHUNK;
        if (cur + take > limit) take = (size_t)(limit - cur);
        take -= take % au_frame();
        if (take == 0) { au_unlock(); break; }

        for (size_t i = 0; i < take; ) {
            uint64_t abs = cur + i;
            size_t   p   = (size_t)(abs % AU_RING_BYTES);
            if (wide) {
                shm->ring[p] = buf[done + i];
                i += 1;
                continue;
            }
            /* Anything at or past the high-water is fresh ring: it holds the
             * silence the pump left behind, so the sum starts from zero. */
            int32_t old = 0;
            if (abs + 2 <= shm->w)
                old = (int16_t)((uint16_t)shm->ring[p]
                                | ((uint16_t)shm->ring[(p + 1) % AU_RING_BYTES] << 8));
            int32_t add = (int16_t)((uint16_t)buf[done + i]
                                    | ((uint16_t)buf[done + i + 1] << 8));
            int16_t mixed = au_sat_add(old, au_gain(add, g));
            shm->ring[p] = (uint8_t)((uint16_t)mixed & 0xff);
            shm->ring[(p + 1) % AU_RING_BYTES] = (uint8_t)(((uint16_t)mixed >> 8) & 0xff);
            i += 2;
        }
        uint64_t end = cur + take;
        if (mixw) { *mixw = end; shm->slot[slot].written += take; }
        if (end > shm->w) shm->w = end;
        shm->mixed_in++;
        au_unlock();
        done += take;
    }
    if (done < n) shm->clipped++;
    if (done) au_kick();
    return (int64_t)done;
}

/* ------------------------------------------------------------------ */

int hamaudio_kind(const char *path)
{
    if (!path) return HAMAUDIO_NONE;
    if (!strcmp(path, "/dev/audio"))    return HAMAUDIO_PCM;
    if (!strcmp(path, "/dev/audioctl")) return HAMAUDIO_CTL;
    if (!strcmp(path, "/dev/audioin"))  return HAMAUDIO_IN;
    return HAMAUDIO_NONE;
}

/* The first PCM substream of the first card that has one. `which` is 'p' for
 * playback, 'c' for capture. devtmpfs publishes these once snd-hda-intel (or
 * virtio_snd) attaches; if no module loaded there is simply no node, and the
 * open fails with ENODEV rather than half-working. */
static int pcm_node_open(char which, int flags)
{
    char path[64];
    for (unsigned card = 0; card < 8; card++) {
        for (unsigned dev = 0; dev < 4; dev++) {
            snprintf(path, sizeof path, "/dev/snd/pcmC%uD%u%c", card, dev, which);
            int fd = open(path, flags);
            if (fd >= 0) { pcm_card = card; return fd; }
            if (errno == EBUSY) return -1;   /* it exists and is taken */
        }
    }
    errno = ENODEV;
    return -1;
}

/* Is there a playback substream on this machine at all? This is what makes
 * "no sound card" an OPEN error: user/playtone.ad checks its open and prints
 * "cannot open /dev/audio (no audio device?)", which is the loud answer. A
 * device that opened fine and then swallowed 24 000 frames is the failure
 * this whole file exists to replace, and it must not come back at a lower
 * layer. */
static int pcm_present(void)
{
    char path[64];
    for (unsigned card = 0; card < 8; card++)
        for (unsigned dev = 0; dev < 4; dev++) {
            snprintf(path, sizeof path, "/dev/snd/pcmC%uD%up", card, dev);
            if (access(path, F_OK) == 0) {
                /* Remember WHICH card, so a control-only client -- the volume
                 * applet, which never opens the PCM at all -- reaches the
                 * right mixer. */
                pcm_card = card;
                return 1;
            }
        }
    return 0;
}

static unsigned alsa_format(void)
{
    switch (cfg_bits) {
    case  8: return FMT_U8;              /* 8-bit PCM is unsigned, by
                                          * convention and by lib/
                                          * hamsdl_audio_dev.ad's scaler */
    case 24: return FMT_S24_3LE;         /* 3 bytes/sample: hda.ad's frame
                                          * size is channels * bits/8    */
    case 32: return FMT_S32_LE;
    default: return FMT_S16_LE;
    }
}

/* Configure an open substream. Returns 0, or -1 with errno. */
static int pcm_configure(int fd, int playback)
{
    struct alsa_hw_params hw;
    hwp_any(&hw);
    hwp_set_mask(&hw, P_ACCESS,    ACCESS_RW_INTERLEAVED);
    hwp_set_mask(&hw, P_FORMAT,    alsa_format());
    hwp_set_mask(&hw, P_SUBFORMAT, 0);              /* STD */
    hwp_set_int(&hw, P_CHANNELS,    cfg_chans);
    hwp_set_int(&hw, P_RATE,        cfg_rate);
    hwp_set_int(&hw, P_PERIOD_SIZE, 1024);
    hwp_set_int(&hw, P_PERIODS,     8);             /* ~170 ms at 48 kHz */
    if (ioctl(fd, PCM_IOCTL_HW_PARAMS, &hw) < 0) {
        fprintf(stderr, "[audio] the card refused %u Hz / %u ch / %u bit: %s\n",
                cfg_rate, cfg_chans, cfg_bits, strerror(errno));
        return -1;
    }

    unsigned period = hwp_get_int(&hw, P_PERIOD_SIZE);
    unsigned buffer = hwp_get_int(&hw, P_BUFFER_SIZE);
    unsigned fbits  = hwp_get_int(&hw, P_FRAME_BITS);
    if (!period) period = 1024;
    if (!buffer) buffer = period * 8;
    frame_bytes = fbits ? fbits / 8 : cfg_chans * (cfg_bits / 8);
    if (!frame_bytes) frame_bytes = 4;
    if (playback)
        buf_bytes = buffer * frame_bytes;

    struct alsa_sw_params sw;
    memset(&sw, 0, sizeof sw);
    sw.tstamp_mode     = 1;                 /* ENABLE */
    sw.period_step     = 1;
    sw.avail_min       = period;
    sw.xfer_align      = 1;
    /* Start as soon as one period is in the ring for playback; capture is
     * started explicitly below.
     *
     * stop_threshold IS THE BUFFER, not the boundary, and that is a
     * correctness decision rather than a tuning one. With it at the boundary
     * the DMA never stops: once the clip is exhausted the engine keeps
     * cycling the ring and REPLAYS whatever is still in it. Measured -- a
     * 1.000 s tone came out of the capture as 2.50 s of continuous tone,
     * i.e. the whole recording, which is a device that plays for ever after
     * being asked for a second of sound. At the buffer, the stream stops the
     * moment the last frame written has been consumed and the output goes
     * silent, which is what "the clip ended" means. ring_write() recovers
     * from the resulting XRUN with a PREPARE, so the next clip plays. */
    sw.start_threshold = playback ? period : 1;
    unsigned long boundary = buffer;
    while (boundary * 2 <= (unsigned long)(LONG_MAX - buffer))
        boundary *= 2;
    sw.boundary        = boundary;
    sw.stop_threshold  = buffer;
    if (ioctl(fd, PCM_IOCTL_SW_PARAMS, &sw) < 0) {
        au_fail("SW_PARAMS");
        return -1;
    }
    if (ioctl(fd, PCM_IOCTL_PREPARE) < 0) {
        au_fail("PREPARE");
        return -1;
    }
    return 0;
}


/* Is this element part of the OUTPUT chain we are allowed to touch? Deliberately
 * a whitelist rather than "every playback control": on real hardware, winding
 * every playback volume to the top would also wind up the PC beep and whatever
 * loopback paths the codec exposes. These are the names the output chain uses
 * across the HDA generic parser, and on QEMU's codec it is `Master` and `PCM`. */
static int output_elem(const char *name)
{
    static const char *ok[] = { "Master", "PCM", "Speaker", "Headphone",
                                "Front", "Line Out", "Line-Out", NULL };
    for (int i = 0; ok[i]; i++) {
        size_t n = strlen(ok[i]);
        if (!strncmp(name, ok[i], n) && (name[n] == ' ' || name[n] == '\0'))
            return 1;
    }
    return 0;
}

/* Push `master_pct` and `muted` into the codec's amps. Returns the number of
 * elements it touched, so a card with no mixer at all (virtio_snd has none)
 * is distinguishable from one that was set -- which is what decides whether
 * the software scaler in apply_volume() is needed.
 *
 * `force` is the difference between "somebody asked for this level" and
 * "a program is about to play something". At bring-up (force = 0) the levels
 * are LEFT ALONE unless they are sitting at the bottom of their range, and
 * `master_pct` is updated FROM the hardware instead. Otherwise every program
 * that started playing would silently wind the volume back to 100 and a
 * level set through hamctl would last exactly until the next sound -- a
 * setting that does not stick, which is the same class of quiet wrongness as
 * a verb that is accepted and ignored. The mute switches are always set,
 * because a muted output is the one state in which nothing can be heard and
 * nothing says why. */
static int mixer_apply(int force)
{
    char path[64];
    snprintf(path, sizeof path, "/dev/snd/controlC%u", pcm_card);
    int fd = open(path, O_RDWR);
    if (fd < 0)
        return 0;

    struct alsa_elem_list list;
    memset(&list, 0, sizeof list);
    if (ioctl(fd, CTL_IOCTL_ELEM_LIST, &list) < 0 || list.count == 0) {
        close(fd);
        return 0;
    }
    unsigned n = list.count;
    struct alsa_elem_id *ids = calloc(n, sizeof *ids);
    if (!ids) { close(fd); return 0; }
    memset(&list, 0, sizeof list);
    list.space = n;
    list.pids  = ids;
    if (ioctl(fd, CTL_IOCTL_ELEM_LIST, &list) < 0) {
        free(ids);
        close(fd);
        return 0;
    }

    /* TWO PASSES, and the split is the fix for a bug that was measured rather
     * than reasoned about. Adopting the hardware level element-by-element in
     * one pass means the level read off the FIRST control becomes the level
     * written to the SECOND -- and on this codec the first one reads near the
     * bottom of its range, so `master` collapsed to nearly zero and the next
     * control was written to its minimum. Two tones that had been captured
     * cleanly came back as 1.8 s of digital silence. Read first, decide once,
     * then write. */
    if (!force) {
        long best_lo = 0, best_hi = 0, best_top = -1;
        int have = 0;
        for (unsigned i = 0; i < list.used; i++) {
            if (ids[i].iface != ELEM_IFACE_MIXER) continue;
            const char *nm = (const char *)ids[i].name;
            if (!strstr(nm, "Playback Volume") || !output_elem(nm)) continue;
            /* `Master` wins if the codec has one; otherwise the first
             * output control in the list stands for the chain. */
            int master = !strncmp(nm, "Master", 6);
            if (have && !master) continue;

            struct alsa_elem_info info;
            memset(&info, 0, sizeof info);
            info.id = ids[i];
            if (ioctl(fd, CTL_IOCTL_ELEM_INFO, &info) < 0) continue;
            if (info.type != ELEM_TYPE_INTEGER) continue;
            long lo = info.value.integer.min, hi = info.value.integer.max;
            if (hi <= lo) continue;

            struct alsa_elem_value cur;
            memset(&cur, 0, sizeof cur);
            cur.id = ids[i];
            if (ioctl(fd, CTL_IOCTL_ELEM_READ, &cur) < 0) continue;
            unsigned cnt = info.count > 128 ? 128 : info.count;
            long top = lo;
            for (unsigned c = 0; c < cnt; c++)
                if (cur.value.integer.value[c] > top)
                    top = cur.value.integer.value[c];
            best_lo = lo; best_hi = hi; best_top = top; have = 1;
            if (master) break;
        }
        /* A level already set and audible is the operator's, and is kept.
         * A level at the bottom is not a choice, it is a codec that has
         * never been initialised, and it gets the default. */
        if (have && best_top > best_lo)
            master_pct = (unsigned)(((best_top - best_lo) * 100)
                                    / (best_hi - best_lo));
    }

    int set = 0;
    for (unsigned i = 0; i < list.used; i++) {
        if (ids[i].iface != ELEM_IFACE_MIXER)
            continue;
        const char *nm = (const char *)ids[i].name;
        int is_vol = strstr(nm, "Playback Volume") != NULL;
        int is_sw  = strstr(nm, "Playback Switch") != NULL;
        if ((!is_vol && !is_sw) || !output_elem(nm))
            continue;

        struct alsa_elem_info info;
        memset(&info, 0, sizeof info);
        info.id = ids[i];
        if (ioctl(fd, CTL_IOCTL_ELEM_INFO, &info) < 0)
            continue;

        struct alsa_elem_value val;
        memset(&val, 0, sizeof val);
        val.id = ids[i];
        unsigned cnt = info.count > 128 ? 128 : info.count;

        if (is_sw && info.type == ELEM_TYPE_BOOLEAN) {
            for (unsigned c = 0; c < cnt; c++)
                val.value.integer.value[c] = muted ? 0 : 1;
        } else if (is_vol && info.type == ELEM_TYPE_INTEGER) {
            long lo = info.value.integer.min, hi = info.value.integer.max;
            if (hi <= lo)
                continue;
            for (unsigned c = 0; c < cnt; c++)
                val.value.integer.value[c] =
                    lo + (long)(((hi - lo) * (long)master_pct) / 100);
        } else {
            continue;
        }
        if (cnt && ioctl(fd, CTL_IOCTL_ELEM_WRITE, &val) == 0)
            set++;
    }
    free(ids);
    close(fd);
    return set;
}

/* Bring the playback substream up in the current format. */
static int pcm_ready(void)
{
    if (pcm_fd >= 0 && !cfg_dirty && pcm_prepared)
        return 0;
    if (pcm_fd >= 0 && cfg_dirty) {
        close(pcm_fd);
        pcm_fd = -1;
        pcm_prepared = 0;
    }
    if (pcm_fd < 0) {
        pcm_fd = pcm_node_open('p', O_WRONLY);
        if (pcm_fd < 0) {
            au_fail("no playback substream");
            return -1;
        }
    }
    if (pcm_configure(pcm_fd, 1) < 0) {
        int e = errno;
        close(pcm_fd);
        pcm_fd = -1;
        errno = e;
        return -1;
    }
    cfg_dirty = 0;
    pcm_prepared = 1;
    /* Unmute and set the level BEFORE the first sample goes out, or the whole
     * clip plays into a muted amp and the only evidence is silence. */
    mixer_hw = mixer_apply(0) > 0;
    return 0;
}

/* Apply `master`/`mute` to a chunk on its way out. Only s16le and u8 are
 * scaled; the wider formats are passed through untouched rather than scaled
 * wrongly, and the status line still reports the requested level. */
static const uint8_t *apply_volume(const uint8_t *src, size_t n, uint8_t *scratch,
                                   size_t scratch_cap)
{
    /* The codec's own amps have it, when the card has any: scaling the samples
     * as well would apply the level twice. */
    if (mixer_hw || (!muted && master_pct == 100))
        return src;
    if (n > scratch_cap)
        n = scratch_cap;
    unsigned g = muted ? 0 : master_pct;
    if (cfg_bits == 16) {
        size_t frames = n / 2;
        const int16_t *in = (const int16_t *)src;
        int16_t *out = (int16_t *)scratch;
        for (size_t i = 0; i < frames; i++)
            out[i] = (int16_t)(((int32_t)in[i] * (int32_t)g) / 100);
        memcpy(scratch + frames * 2, src + frames * 2, n - frames * 2);
    } else if (cfg_bits == 8) {
        for (size_t i = 0; i < n; i++) {
            int v = (int)src[i] - 128;
            scratch[i] = (uint8_t)((v * (int)g) / 100 + 128);
        }
    } else {
        return src;
    }
    return scratch;
}

/* One transfer to the ring. Returns bytes accepted, 0 on a short/again, or
 * -1 with errno. Recovers from an underrun rather than reporting it as a
 * write error the caller would read as the device dying. */
static int64_t ring_write(const uint8_t *buf, size_t n)
{
    static uint8_t scratch[16384];
    if (n > sizeof scratch && (muted || master_pct != 100))
        n = sizeof scratch;
    /* Never hand the kernel a partial frame: it would shift every later
     * sample by a byte and turn the whole stream into noise. */
    n -= n % frame_bytes;
    if (n == 0) return 0;

    const uint8_t *p = apply_volume(buf, n, scratch, sizeof scratch);
    for (;;) {
        ssize_t w = write(pcm_fd, p, n);
        if (w >= 0) {
            played_bytes += (uint64_t)w;
            return (int64_t)w;
        }
        if (errno == EINTR)
            continue;
        if (errno == EPIPE || errno == ESTRPIPE) {
            /* Underrun. PREPARE and try once more; if it happens again the
             * error is real and goes back to the caller. */
            if (ioctl(pcm_fd, PCM_IOCTL_PREPARE) < 0)
                return -1;
            w = write(pcm_fd, p, n);
            if (w >= 0) { played_bytes += (uint64_t)w; return (int64_t)w; }
            return -1;
        }
        if (errno == EAGAIN || errno == EWOULDBLOCK)
            return 0;
        au_fail("write to the ring");
        return -1;
    }
}

/* One ring's worth of SILENCE behind whatever was just written. This is
 * hda.ad's HDA_ONESHOT_PAD, and it is not decoration: the stream stops when
 * the hardware pointer catches the write pointer, and the last period or two
 * are still in flight at that moment. Measured without it, a 1.000 s tone came
 * back from the capture as 0.966 s and a half-second .wav as 0.474 s -- the
 * tail simply never reached the codec. The pad is silent, so it changes
 * nothing about what is heard except that all of it is. */
static void ring_pad(void)
{
    static const uint8_t hush[4096];
    if (pcm_fd < 0) return;
    unsigned pad = buf_bytes ? buf_bytes : (unsigned)sizeof hush;
    unsigned done = 0;
    while (done < pad) {
        unsigned want = pad - done;
        if (want > sizeof hush) want = (unsigned)sizeof hush;
        int64_t w = ring_write(hush, want);
        if (w <= 0) break;
        done += (unsigned)w;
    }
}

static void pcm_drain(void)
{
    if (pcm_fd < 0) return;
    /* Pad first, then drain: the stream stops itself the instant the ring runs
     * dry, so without the pad DRAIN is called on an already-stopped stream and
     * the last fraction of a second is simply gone. */
    ring_pad();
    if (ioctl(pcm_fd, PCM_IOCTL_DRAIN) < 0 && errno == EPIPE)
        ioctl(pcm_fd, PCM_IOCTL_PREPARE);
    pcm_prepared = 0;
}

/* ================================================================== *
 * THE PUMP — the port of hda.ad's DMA engine and its service tick.
 *
 * It owns the ONE ALSA substream and it is the only thing in the system that
 * writes to it. Its whole job is: take one period out of the mix ring, hand it
 * to the card, advance `play`. The write(2) blocks until the card has room, so
 * the HARDWARE paces this loop — there is no timer, no poll and nothing to
 * wake. That is what makes it the port of a DMA engine rather than of a
 * scheduler, and it is why a writer that stalls cannot stall anyone else: the
 * pump simply hands over a period of silence for that stream's share and every
 * other stream in the ring keeps flowing at exactly its own rate.
 *
 * It also ZEROES each byte as it consumes it. hda.ad's
 * `_hda_ring_silence_ahead` exists for the same reason: a ring that is not
 * re-silenced replays the previous lap when a producer falls behind, which is
 * the "on close it played the last sound effect over and over" report. Here it
 * has a second job — it is what lets au_mix() sum into virgin ring without
 * having to track which bytes are stale.
 * ================================================================== */

/* What silence IS depends on the width: s16/s24/s32 silence is 0, and u8
 * silence is 0x80. Filling a u8 stream's gaps with 0 would be a full-scale
 * negative DC step -- a click, on every underrun. */
static uint8_t au_hush_byte(void) { return shm->bits == 8 ? 0x80 : 0x00; }

static void au_pump_loop(void)
{
    static uint8_t chunkbuf[65536];
    in_pump = 1;
    my_slot = -1;
    uint32_t gen = (uint32_t)-1;
    uint64_t idle_since = au_now_ms();

    for (;;) {
        if (shm->fmt_gen != gen) {
            /* The format is the mix's, not this process's: the pump follows
             * whatever the first stream established. */
            if (shm->rate)  cfg_rate  = shm->rate;
            if (shm->chans) cfg_chans = shm->chans;
            if (shm->bits)  cfg_bits  = shm->bits;
            cfg_dirty = 1;
            gen = shm->fmt_gen;
        }
        /* BEFORE pcm_ready, not after: bringing the card up writes the
         * amps, and writing them from a stale level is how a `master 40` set
         * through hamctl would last exactly until the next sound. pcm_ready
         * may ADOPT the codec's own level when it configures (mixer_apply(0)),
         * so the answer is published back afterwards -- otherwise the status
         * line would report 100 for a codec sitting at 30. */
        master_pct = shm->master_pct;
        muted      = shm->muted ? 1 : 0;
        if (pcm_ready() < 0) {
            fprintf(stderr, "[audio] the mix pump cannot bring the card up: "
                            "%s\n", strerror(errno));
            shm->pump_pid = 0;
            _exit(1);
        }
        shm->master_pct   = master_pct;
        shm->period_bytes = buf_bytes ? buf_bytes / 8 : 4096;
        shm->hw_amps      = mixer_hw ? 1u : 0u;

        unsigned chunk = shm->period_bytes;
        if (chunk > sizeof chunkbuf) chunk = (unsigned)sizeof chunkbuf;
        chunk -= chunk % frame_bytes;
        if (!chunk) chunk = frame_bytes;

        uint8_t hush = au_hush_byte();
        au_lock();
        uint64_t play = shm->play;
        uint64_t w    = shm->w;
        uint64_t ahead = w > play ? w - play : 0;
        unsigned have = ahead > chunk ? chunk : (unsigned)ahead;
        for (unsigned i = 0; i < chunk; i++) {
            size_t p = (size_t)((play + i) % AU_RING_BYTES);
            if (i < have) { chunkbuf[i] = shm->ring[p]; shm->ring[p] = hush; }
            else            chunkbuf[i] = hush;
        }
        shm->play = play + chunk;
        int writers = au_live_writers();
        if (have < chunk && writers) shm->underruns++;
        au_unlock();

        if (have || writers) idle_since = au_now_ms();

        if (ring_write(chunkbuf, chunk) < 0) {
            fprintf(stderr, "[audio] the mix pump lost the card: %s\n",
                    strerror(errno));
            shm->pump_pid = 0;
            _exit(1);
        }

        /* THE PARK. Nothing to play and nobody holding a slot: give the card
         * back and sleep on the futex until a writer bumps it.
         *
         * IT PARKS RATHER THAN EXITING, and that is not a preference. PID 1
         * here is hamsh, and the runtime's reaper waits on the pids it
         * REMEMBERS -- deliberately, so it cannot steal a status from code
         * that wanted one (HANDOFF.md, THE IDLE CENSUS). An orphaned pump that
         * exited would therefore sit on the process table as a zombie, and one
         * per sound is a leak with a bell on it. So the pump is started once
         * and lives; what it gives up when idle is the CARD, which is the
         * thing that actually costs something -- an open substream keeps
         * QEMU's audio thread and a real codec's DMA engine running, and an
         * idle desktop on this tree is measured in host CPU.
         *
         * The 1 s timeout on the wait is a safety net, not the mechanism: a
         * writer that summed into the ring and died before its wake would
         * otherwise leave its audio sitting there unheard. */
        if (have == 0 && writers == 0
            && au_now_ms() - idle_since > AU_IDLE_MS) {
            pcm_drain();
            if (pcm_fd >= 0) { close(pcm_fd); pcm_fd = -1; }
            pcm_prepared = 0;
            cfg_dirty = 1;
            while (shm->w <= shm->play && au_live_writers() == 0) {
                uint32_t seen = shm->wake;
                if (shm->w > shm->play || au_live_writers()) break;
                au_futex_wait(&shm->wake, seen, 1000);
            }
            idle_since = au_now_ms();
        }
    }
}

/* Start the pump if there is not already a live one. The claim is a
 * compare-and-swap on `pump_pid`, so two programs that reach for the card in
 * the same microsecond cannot both get it -- which would be two processes
 * fighting over one substream and the exact EBUSY this whole file exists to
 * remove. */
static void au_pump_ensure(void)
{
    if (in_pump || !shm) return;
    int32_t p = shm->pump_pid;
    if (p > 0) {
        if (kill((pid_t)p, 0) == 0 || errno == EPERM) return;
    }
    if (!__sync_bool_compare_and_swap(&shm->pump_pid, p, -1))
        return;                              /* somebody else is starting it */

    pid_t f = fork();
    if (f < 0) { shm->pump_pid = 0; return; }
    if (f == 0) {
        /* DETACH. setsid plus a second fork leaves the pump reparented to PID
         * 1, so it outlives the program that started it -- which is the whole
         * point: the music must keep playing when the process that queued a
         * sound effect exits. */
        setsid();
        pid_t g = fork();
        if (g != 0) _exit(0);
        /* Nothing of the parent's descriptors comes along. A pump holding the
         * write end of its parent's pipe would keep a shell pipeline from ever
         * seeing EOF -- a hang with no visible cause. The mapping survives the
         * close; that is what mmap is for. */
        for (int fd = 3; fd < 256; fd++) close(fd);
        int nul = open("/dev/console", O_WRONLY);
        if (nul < 0) nul = open("/dev/null", O_WRONLY);
        if (nul >= 0) { dup2(nul, 1); dup2(nul, 2); if (nul > 2) close(nul); }
        int zin = open("/dev/null", O_RDONLY);
        if (zin >= 0) { dup2(zin, 0); if (zin > 0) close(zin); }
        pcm_fd = -1; cap_fd = -1; pcm_prepared = 0; cfg_dirty = 1;
        shm->pump_pid = (int32_t)getpid();
        au_pump_loop();
        _exit(0);
    }
    waitpid(f, NULL, 0);                     /* the middle process, at once  */
    /* Wait for the pump to publish its period size: au_guard() is wrong until
     * it has, and a stream placed inside the pump's own consume window is
     * bytes that were written and never heard. */
    for (int i = 0; i < 400 && shm->period_bytes == 0; i++) au_nap(5);
}

/* ------------------------------------------------------------------ */

int hamaudio_open(const char *path, int for_write, struct hamaudio_file *a)
{
    int kind = hamaudio_kind(path);
    if (kind == HAMAUDIO_NONE) { errno = ENODEV; return -1; }
    if (kind == HAMAUDIO_IN && for_write) { errno = EPERM; return -1; }
    if (!pcm_present()) { errno = ENODEV; return -1; }
    memset(a, 0, sizeof *a);
    a->kind = kind;

    /* Opening does not touch the hardware: /dev/audio is read for status by
     * the volume applet on every panel tick, and that must not seize the
     * substream from whatever is playing. The PCM device is opened lazily,
     * on the first write that has somewhere to go. */
    if (kind == HAMAUDIO_PCM && !clip) {
        clip = malloc(CLIP_CAP);
        if (!clip) { errno = ENOMEM; return -1; }
    }
    return 0;
}

void hamaudio_close(struct hamaudio_file *a)
{
    if (!a) return;
    if (a->kind == HAMAUDIO_PCM) {
        /* THE AUTO-START, and it is a port rather than a convenience.
         * hda.ad stamps `hda_stage_arm_j` on the LAST staged write and the
         * service tick starts the clip half a second later, so a program that
         * writes raw PCM to /dev/audio and never touches /dev/audioctl at all
         * is still HEARD -- lib/hamgame_dev.ad's game_dev_play_pcm does
         * exactly that, and user/audiolife.ad's `raw` and `sfx` phases
         * reproduce it. There is no timer in a library, but there is a moment
         * that means the same thing and is better: the writer closing the
         * device is "the writer has finished handing the clip over", which is
         * precisely what the deadline was standing in for.
         *
         * Closing does NOT mean "stop". What this process summed into the mix
         * ring is already there and the pump plays it out -- which is the
         * behaviour the whole port is for: a program that queues a sound
         * effect and exits is heard, and hda.ad has the same property because
         * its ring outlives the writer. All that is given up here is the
         * volume slot. A client that wanted the audio abandoned says `stop`.
         * What this process summed into the mix ring is already there and the
         * pump plays it out -- which is the behaviour the whole port is for:
         * a program that queues a sound effect and exits is HEARD, and hda.ad
         * has the same property because its ring outlives the writer. All that
         * is given up here is the volume slot. A client that wanted the audio
         */
        if (clip_pending && clip_len && !stream_mode) {
            clip_pending = 0;
            au_mix(clip, clip_len, 1);
        }
        au_slot_release();
        stream_mode = 0;
    }
    if (a->kind == HAMAUDIO_IN && cap_fd >= 0) {
        close(cap_fd);
        cap_fd = -1;
    }
    memset(a, 0, sizeof *a);
}

/* ---- the status line ---------------------------------------------- */

/* EVERY NUMBER ON THIS LINE IS MEASURED. It used to carry
 * `streams 100 100 100 100`, four constants that were there because
 * user/hamctl.ad parses the line and expects the field -- a placeholder a real
 * program reads, which is worse than an absence. They are now the four
 * per-stream Q8 gains out of the shared mixer, in percent, exactly as
 * `hda_mix_stream_pct` reports them on Hamnix.
 *
 * `space` and `pos` are the mix ring's, not one substream's: `pos` is what the
 * pump has actually handed the card (hda.ad's LPIB-derived play cursor -- what
 * was HEARD, not what a wall clock says) and `space` is what a producer may
 * append right now without running past the half-ring bound. The three
 * telemetry fields after them are appended, which is Hamnix's own idiom for
 * extending this line without breaking a parser that stops earlier:
 *   mixed   summed writes (hda_mixed_in)
 *   hush    pump periods that had to be filled with silence -- the number that
 *           goes up when a writer cannot keep up, and the one to look at when
 *           somebody says the audio is stuttering
 *   nogain  writers that found all four volume slots taken and are playing at
 *           unity with no control of their own */
static int status_line(char *out, size_t cap)
{
    if (au_attach() < 0)
        return snprintf(out, cap, "loaded %u cap %u master %u "
                        "streams 0 0 0 0 mute %d space 0 pos 0 "
                        "mixed 0 hush 0 nogain 0\n",
                        clip_len, CLIP_CAP, master_pct, muted ? 1 : 0);
    au_reap();
    uint64_t play = shm->play, w = shm->w;
    uint64_t inflight = w > play ? w - play : 0;
    uint64_t half = AU_RING_BYTES / 2;
    unsigned long space = inflight >= half ? 0ul : (unsigned long)(half - inflight);
    unsigned pct[AU_SLOTS];
    for (int i = 0; i < AU_SLOTS; i++)
        pct[i] = (unsigned)(((uint64_t)(shm->slot[i].gain < 0 ? 0
                                        : shm->slot[i].gain) * 100 + 128) / 256);
    return snprintf(out, cap,
                    "loaded %u cap %u master %u streams %u %u %u %u "
                    "mute %d space %lu pos %llu "
                    "mixed %llu hush %llu nogain %u\n",
                    clip_len, CLIP_CAP, shm->master_pct,
                    pct[0], pct[1], pct[2], pct[3],
                    shm->muted ? 1 : 0, space, (unsigned long long)play,
                    (unsigned long long)shm->mixed_in,
                    (unsigned long long)shm->underruns, shm->nogain);
}

int64_t hamaudio_read(struct hamaudio_file *a, uint8_t *buf, uint64_t cap)
{
    if (a->kind == HAMAUDIO_CTL)
        return 0;                       /* audio_cdev.ad: always EOF */

    if (a->kind == HAMAUDIO_PCM) {
        char line[192];
        int n = status_line(line, sizeof line);
        if (n < 0) return -1;
        if (a->off >= (uint64_t)n) return 0;
        uint64_t avail = (uint64_t)n - a->off;
        if (avail > cap) avail = cap;
        memcpy(buf, line + a->off, (size_t)avail);
        a->off += avail;
        return (int64_t)avail;
    }

    /* /dev/audioin. The offset is ignored: this is a stream, and the read
     * pointer is the hardware's. */
    if (cap_fd < 0) {
        cap_fd = pcm_node_open('c', O_RDONLY | O_NONBLOCK);
        if (cap_fd < 0)
            return -1;
        if (pcm_configure(cap_fd, 0) < 0 || ioctl(cap_fd, PCM_IOCTL_START) < 0) {
            int e = errno;
            close(cap_fd);
            cap_fd = -1;
            errno = e;
            return -1;
        }
    }
    uint64_t want = cap - (cap % frame_bytes);
    if (want == 0) return 0;
    ssize_t r = read(cap_fd, buf, (size_t)want);
    if (r < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)
            return 0;                   /* nothing captured yet, not EOF */
        if (errno == EPIPE) {           /* overrun: skip the lost window */
            ioctl(cap_fd, PCM_IOCTL_PREPARE);
            ioctl(cap_fd, PCM_IOCTL_START);
            return 0;
        }
        return -1;
    }
    return (int64_t)r;
}

/* ---- the ctl verbs ------------------------------------------------ */

/* Whole-token compare: `rate` must not match `rateX`. */
static int tok_eq(const char *p, size_t n, const char *word)
{
    size_t w = strlen(word);
    if (n < w || memcmp(p, word, w) != 0) return 0;
    if (n == w) return 1;
    char c = p[w];
    return c == ' ' || c == '\t' || c == '\n' || c == '\0';
}

/* The first decimal run anywhere in the line, or `dflt`. Same latitude as
 * Hamnix's _au_parse_uint_after: `rate 48000`, `rate=48000` and
 * `rate   48000` all mean the same thing. */
static unsigned uint_after(const char *p, size_t n, unsigned dflt)
{
    size_t i = 0;
    while (i < n && (p[i] < '0' || p[i] > '9')) i++;
    if (i >= n) return dflt;
    unsigned v = 0;
    while (i < n && p[i] >= '0' && p[i] <= '9') {
        v = v * 10 + (unsigned)(p[i] - '0');
        i++;
    }
    return v;
}

/* THE FORMAT IS THE MIX'S, NOT ONE PROGRAM'S.
 *
 * There is one hardware substream and the pump runs it at one rate, one
 * channel count and one width. The first stream to arrive sets them. A stream
 * that arrives later and wants something else has three possible answers and
 * only one of them is honest here: convert it (this file does no resampling
 * and says so), play it at the wrong speed (the silent lie), or REFUSE BY
 * NAME. It refuses, and the message names both formats so the person reading
 * it knows what to change.
 *
 * When the mixer is idle -- no other live writer and nothing left in the ring
 * -- the format is free, so a program that runs on its own never sees this. */
static int au_busy_with_other(void)
{
    if (!shm) return 0;
    au_reap();
    for (int i = 0; i < AU_SLOTS; i++)
        if (shm->slot[i].used && shm->slot[i].pid != (int32_t)getpid())
            return 1;
    return shm->w > shm->play;              /* audio still queued to be heard */
}

static int au_set_fmt(unsigned rate, unsigned chans, unsigned bits)
{
    if (au_attach() < 0) { errno = ENODEV; return -1; }
    if (rate == shm->rate && chans == shm->chans && bits == shm->bits) {
        cfg_rate = rate; cfg_chans = chans; cfg_bits = bits;
        return 0;
    }
    if (au_busy_with_other()) {
        fprintf(stderr, "[audio] the mixer is running at %u Hz / %u ch / "
                        "%u bit and this stream asked for %u Hz / %u ch / "
                        "%u bit; there is no resampler here, so it is refused "
                        "rather than played at the wrong speed\n",
                shm->rate, shm->chans, shm->bits, rate, chans, bits);
        errno = EBUSY;
        return -1;
    }
    shm->rate  = rate;
    shm->chans = chans;
    shm->bits  = bits;
    shm->fmt_gen++;                          /* the pump reconfigures on this */
    cfg_rate = rate; cfg_chans = chans; cfg_bits = bits;
    cfg_dirty = 1;
    return 0;
}

/* Play out everything THIS process has summed, then let go. hda_stream_drain's
 * contract: it returns when what was written has been heard, which is why
 * user/aplay.ad can end with it and know the clip finished. It waits on the
 * pump's play cursor -- the thing that actually reached the card -- not on a
 * wall clock that keeps running when nothing is being played. */
static void au_drain(void)
{
    if (au_attach() < 0) return;
    if (my_slot < 0) return;
    uint64_t target = shm->slot[my_slot].mixw;
    uint64_t last = shm->play;
    unsigned stuck = 0;
    while (shm->play < target) {
        au_pump_ensure();
        au_nap(5);
        if (shm->play == last) {
            if (++stuck > 2000) {           /* 10 s with the cursor frozen */
                fprintf(stderr, "[audio] drain: the play cursor has not moved "
                                "in 10 s with %llu bytes still queued\n",
                        (unsigned long long)(target - shm->play));
                return;
            }
        } else { stuck = 0; last = shm->play; }
    }
}

/* One line. Returns 0, or -1 with errno for a verb that cannot be honoured. */
static int ctl_line(const char *p, size_t n)
{
    while (n && (*p == ' ' || *p == '\t')) { p++; n--; }
    if (n == 0) return 0;

    if (tok_eq(p, n, "rate")) {
        unsigned v = uint_after(p, n, cfg_rate);
        if (v < 4000 || v > 384000) { errno = EINVAL; return -1; }
        return au_set_fmt(v, cfg_chans, cfg_bits);
    }
    if (tok_eq(p, n, "channels")) {
        unsigned v = uint_after(p, n, cfg_chans);
        if (v < 1) v = 1;
        if (v > 8) v = 8;               /* hda_set_channels clamps 1..8 */
        return au_set_fmt(cfg_rate, v, cfg_bits);
    }
    if (tok_eq(p, n, "bits")) {
        unsigned v = uint_after(p, n, cfg_bits);
        if (v != 8 && v != 16 && v != 24 && v != 32) { errno = EINVAL; return -1; }
        return au_set_fmt(cfg_rate, cfg_chans, v);
    }
    if (tok_eq(p, n, "format")) {
        /* Hamnix hardcodes the argument at offset 7; this scans for it, so
         * `format  s16le` works here and does not there. A superset. */
        size_t i = 6;
        while (i < n && (p[i] == ' ' || p[i] == '\t' || p[i] == '=')) i++;
        size_t k = n - i;
        unsigned v = 0;
        if      (i < n && k >= 5 && !memcmp(p + i, "s16le", 5)) v = 16;
        else if (i < n && k >= 2 && !memcmp(p + i, "u8",    2)) v = 8;
        else if (i < n && k >= 5 && !memcmp(p + i, "s24le", 5)) v = 24;
        else if (i < n && k >= 5 && !memcmp(p + i, "s32le", 5)) v = 32;
        if (!v) { errno = EINVAL; return -1; }
        return au_set_fmt(cfg_rate, cfg_chans, v);
    }
    if (tok_eq(p, n, "streamopen")) {
        /* NOT "seize the card and zero the ring", which is what this verb did
         * when there was one writer. Somebody else may be playing. It claims a
         * volume slot, makes sure the pump is up and arms the streaming write
         * path; the ring is shared and stays as it is. */
        if (au_attach() < 0) { errno = ENODEV; return -1; }
        stream_mode = 1;
        clip_len = 0;
        au_pump_ensure();
        au_slot_claim();
        return 0;
    }
    if (tok_eq(p, n, "nonblock")) {
        nonblock = uint_after(p, n, 1) != 0;
        return 0;
    }
    if (tok_eq(p, n, "drain")) {
        au_drain();
        stream_mode = 0;
        return 0;
    }
    if (tok_eq(p, n, "start") || tok_eq(p, n, "mixplay")) {
        /* Staged one-shot: sum the whole clip into the mix ring. It blocks
         * while the ring is a half-ring ahead of the play cursor, so `start`
         * returns once the last byte has been QUEUED, not once it has been
         * heard -- the clip is still sounding when the caller gets control
         * back, and it keeps sounding after the caller EXITS, because the ring
         * and the pump outlive it.
         *
         * `mixplay` lands here too: on Hamnix it renders mixer.ad's slots into
         * the DMA buffer, which is a distinct act only because the plain
         * /dev/audio path there does not go through the mixer. Here every path
         * does, so the two verbs name one thing. */
        if (clip_len == 0)
            return 0;
        clip_pending = 0;
        int64_t w = au_mix(clip, clip_len, 1);
        if (w < 0) return -1;
        if ((unsigned)w < clip_len)
            fprintf(stderr, "[audio] start: only %lld of %u staged bytes "
                            "reached the mix ring\n", (long long)w, clip_len);
        return 0;
    }
    if (tok_eq(p, n, "stop")) {
        /* STOP IS THIS STREAM'S, not the machine's. Dropping the hardware ring
         * would silence every other program mixed into it -- the exact
         * cross-program damage this file was rewritten to remove. So: give up
         * this stream's queued audio by parking its cursor, and only when
         * nothing else is playing does the ring itself get dropped. */
        if (au_attach() < 0) return 0;
        int alone = !au_busy_with_other();
        au_lock();
        if (my_slot >= 0) shm->slot[my_slot].mixw = 0;
        if (alone) {
            memset(shm->ring, au_hush_byte(), sizeof shm->ring);
            shm->w = shm->play;
        }
        au_unlock();
        return 0;
    }
    if (tok_eq(p, n, "reset")) {
        clip_len = 0;
        clip_pending = 0;
        return 0;
    }
    if (tok_eq(p, n, "master")) {
        unsigned v = uint_after(p, n, master_pct);
        master_pct = v > 100 ? 100 : v;
        if (au_attach() == 0) shm->master_pct = master_pct;
        mixer_hw = mixer_apply(1) > 0;
        if (shm) shm->hw_amps = mixer_hw ? 1u : 0u;
        return 0;
    }
    if (tok_eq(p, n, "mute") || tok_eq(p, n, "unmute")) {
        muted = tok_eq(p, n, "mute");
        if (au_attach() == 0) shm->muted = muted ? 1u : 0u;
        mixer_hw = mixer_apply(1) > 0;
        if (shm) shm->hw_amps = mixer_hw ? 1u : 0u;
        return 0;
    }
    /* "stream <id> <pct>" -- mixer.ad's hda_mix_set_stream_pct, and now a verb
     * that does something. An id outside 0..3 is an error rather than a
     * rounding: a program that meant slot 7 has a bug and being told so is the
     * point. */
    if (tok_eq(p, n, "stream")) {
        if (au_attach() < 0) { errno = ENODEV; return -1; }
        size_t i = 6;
        while (i < n && (p[i] < '0' || p[i] > '9')) i++;
        unsigned id = uint_after(p + i, n - i, 0);
        while (i < n && p[i] >= '0' && p[i] <= '9') i++;
        unsigned pct = uint_after(p + i, n - i, 100);
        if (id >= AU_SLOTS) {
            fprintf(stderr, "[audio] stream %u: the mixer has %d volume slots "
                            "(0..%d)\n", id, AU_SLOTS, AU_SLOTS - 1);
            errno = EINVAL;
            return -1;
        }
        if (pct > 100) pct = 100;
        shm->slot[id].gain = (int32_t)((pct * 256) / 100);  /* mixer.ad's Q8 */
        return 0;
    }
    /* Anything else: accepted and ignored, as audio_cdev.ad does. */
    return 0;
}

int64_t hamaudio_write(struct hamaudio_file *a, const uint8_t *buf, uint64_t n)
{
    if (a->kind == HAMAUDIO_IN) { errno = EPERM; return -1; }

    if (a->kind == HAMAUDIO_CTL) {
        uint64_t i = 0;
        int bad = 0;
        while (i < n) {
            uint64_t e = i;
            while (e < n && buf[e] != '\n' && buf[e] != '\0') e++;
            if (ctl_line((const char *)buf + i, (size_t)(e - i)) < 0)
                bad = 1;
            i = (e < n) ? e + 1 : e;
        }
        if (bad) return -1;
        return (int64_t)n;
    }

    /* /dev/audio */
    if (n == 0) {
        /* devaudio_write's count == 0 arms: drain in stream mode, start the
         * staged clip otherwise. */
        if (stream_mode) { au_drain(); return 0; }
        return ctl_line("start", 5) < 0 ? -1 : 0;
    }

    if (stream_mode) {
        int64_t w = au_mix(buf, (size_t)n, !nonblock);
        if (w > 0) a->off += (uint64_t)w;
        return w;
    }

    /* STAGED. The write is offset-addressed into the clip and a write at
     * offset 0 truncates it, which is how a client starts a new sound. */
    if (!clip) {
        clip = malloc(CLIP_CAP);
        if (!clip) { errno = ENOMEM; return -1; }
    }
    if (a->off == 0) {
        clip_len = 0;                   /* offset 0 means "a new clip"      */
        clip_pending = 0;
    }
    if (a->off >= CLIP_CAP)
        return 0;                       /* full: hda_dev_write returns 0    */
    uint64_t room = CLIP_CAP - a->off;
    uint64_t take = n < room ? n : room;
    memcpy(clip + a->off, buf, (size_t)take);
    a->off += take;
    if (a->off > clip_len)
        clip_len = (unsigned)a->off;
    clip_pending = 1;                   /* see hamaudio_close: the auto-start */
    return (int64_t)take;
}

int64_t hamaudio_seek(struct hamaudio_file *a, int64_t off, int32_t whence)
{
    int64_t base = (whence == 1) ? (int64_t)a->off
                 : (whence == 2) ? (int64_t)clip_len : 0;
    int64_t want = base + off;
    if (want < 0) { errno = EINVAL; return -1; }
    a->off = (uint64_t)want;
    return want;
}
