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
 *   read   ONE status line, then EOF. Byte-identical in shape to Hamnix's:
 *            loaded <n> cap <n> master <pct> streams <p0> <p1> <p2> <p3>
 *            mute <0|1> space <bytes> pos <bytes>
 *          user/hamctl.ad parses `master` and `mute` out of exactly this.
 *          Reading /dev/audio is NOT capture — /dev/audioin is.
 * /dev/audioctl
 *   write  one verb per line: rate, channels, bits, format, streamopen,
 *          nonblock, drain, start, stop, reset, master, mute, unmute.
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
 * WHAT IS NOT PORTED, said plainly
 * ================================
 *  * THE 4-STREAM SOFTWARE MIXER. Hamnix's hda.ad sums a second live
 *    process's writes into the owner's ring (drivers/audio/mixer.ad). Here a
 *    hardware substream has ONE writer: a second process opening /dev/audio
 *    while another is playing gets EBUSY straight from the kernel. That is a
 *    real difference and user/audiolife.ad depends on the mixed behaviour, so
 *    it will not do here what it does on Hamnix. The `stream` and `mixplay`
 *    ctl verbs therefore FAIL (-EINVAL) rather than being accepted and
 *    ignored, which is what Hamnix does with verbs it does not know. An
 *    accepted verb that changes nothing is precisely the success-shaped
 *    answer this tree forbids. The `streams` field of the status line reports
 *    the fixed 100s, and means nothing.
 *  * NOTHING, for `master`/`mute`: those DO drive the codec's own amps, the
 *    same as on Hamnix, through the control device. A card with no mixer
 *    elements at all (virtio_snd) falls back to scaling the samples in
 *    software, so the verb means the same thing either way.
 *  * NO RESAMPLING. `rate` is passed to the hardware. If the card refuses it
 *    the ctl write fails; it does not silently play at another rate.
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/types.h>
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

static uint64_t played_bytes;           /* total handed to the ring      */

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

/* Push a whole buffer, looping over short transfers. Honours `nonblock` by
 * stopping at the first short count, which is the contract aplay.ad's push()
 * already loops around. */
static int64_t ring_push(const uint8_t *buf, size_t n)
{
    if (pcm_ready() < 0)
        return -1;
    size_t off = 0;
    while (off < n) {
        int64_t w = ring_write(buf + off, n - off);
        if (w < 0)
            return off ? (int64_t)off : -1;
        if (w == 0) {
            if (nonblock)
                break;
            /* The descriptor is blocking, so a 0 here means the residue was
             * smaller than a frame. Nothing more can be sent. */
            break;
        }
        off += (size_t)w;
    }
    return (int64_t)off;
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
    if (a->kind == HAMAUDIO_PCM && pcm_fd >= 0) {
        /* Closing the sink means "I am done": play out what is in the ring
         * rather than letting the descriptor close cut the tail off. A
         * client that wanted the audio abandoned says `stop` first. */
        pcm_drain();
        close(pcm_fd);
        pcm_fd = -1;
        pcm_prepared = 0;
        stream_mode = 0;
    }
    if (a->kind == HAMAUDIO_IN && cap_fd >= 0) {
        close(cap_fd);
        cap_fd = -1;
    }
    memset(a, 0, sizeof *a);
}

/* ---- the status line ---------------------------------------------- */

static int status_line(char *out, size_t cap)
{
    long delay = 0;
    unsigned long space = buf_bytes;
    uint64_t pos = played_bytes;
    if (pcm_fd >= 0 && ioctl(pcm_fd, PCM_IOCTL_DELAY, &delay) == 0 && delay > 0) {
        uint64_t queued = (uint64_t)delay * frame_bytes;
        space = (queued < buf_bytes) ? (unsigned long)(buf_bytes - queued) : 0;
        pos   = (queued < played_bytes) ? played_bytes - queued : 0;
    }
    return snprintf(out, cap,
                    "loaded %u cap %u master %u streams 100 100 100 100 "
                    "mute %d space %lu pos %llu\n",
                    clip_len, CLIP_CAP, master_pct, muted ? 1 : 0,
                    space, (unsigned long long)pos);
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

/* One line. Returns 0, or -1 with errno for a verb that cannot be honoured. */
static int ctl_line(const char *p, size_t n)
{
    while (n && (*p == ' ' || *p == '\t')) { p++; n--; }
    if (n == 0) return 0;

    if (tok_eq(p, n, "rate")) {
        unsigned v = uint_after(p, n, cfg_rate);
        if (v < 4000 || v > 384000) { errno = EINVAL; return -1; }
        if (v != cfg_rate) { cfg_rate = v; cfg_dirty = 1; }
        return 0;
    }
    if (tok_eq(p, n, "channels")) {
        unsigned v = uint_after(p, n, cfg_chans);
        if (v < 1) v = 1;
        if (v > 8) v = 8;               /* hda_set_channels clamps 1..8 */
        if (v != cfg_chans) { cfg_chans = v; cfg_dirty = 1; }
        return 0;
    }
    if (tok_eq(p, n, "bits")) {
        unsigned v = uint_after(p, n, cfg_bits);
        if (v != 8 && v != 16 && v != 24 && v != 32) { errno = EINVAL; return -1; }
        if (v != cfg_bits) { cfg_bits = v; cfg_dirty = 1; }
        return 0;
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
        if (v != cfg_bits) { cfg_bits = v; cfg_dirty = 1; }
        return 0;
    }
    if (tok_eq(p, n, "streamopen")) {
        stream_mode = 1;
        clip_len = 0;
        return pcm_ready();
    }
    if (tok_eq(p, n, "nonblock")) {
        nonblock = uint_after(p, n, 1) != 0;
        return 0;
    }
    if (tok_eq(p, n, "drain")) {
        pcm_drain();
        stream_mode = 0;
        return 0;
    }
    if (tok_eq(p, n, "start")) {
        /* Staged one-shot: hand the whole clip to the ring. The transfer
         * blocks while the ring is full, so `start` returns once the last
         * period has been QUEUED, not once it has been heard -- the clip is
         * still playing out when the caller gets control back, which is what
         * playtone's post-`start` wait exists for. */
        if (clip_len == 0)
            return 0;
        if (pcm_ready() < 0)
            return -1;
        size_t off = 0;
        while (off < clip_len) {
            int64_t w = ring_write(clip + off, clip_len - off);
            if (w < 0) return -1;
            if (w == 0) break;
            off += (size_t)w;
        }
        if (off < clip_len) {
            fprintf(stderr, "[audio] start: only %zu of %u staged bytes "
                            "reached the ring\n", off, clip_len);
            return 0;
        }
        ring_pad();
        return 0;
    }
    if (tok_eq(p, n, "stop")) {
        if (pcm_fd >= 0) {
            ioctl(pcm_fd, PCM_IOCTL_DROP);
            pcm_prepared = 0;
        }
        return 0;
    }
    if (tok_eq(p, n, "reset")) {
        clip_len = 0;
        return 0;
    }
    if (tok_eq(p, n, "master")) {
        unsigned v = uint_after(p, n, master_pct);
        master_pct = v > 100 ? 100 : v;
        mixer_hw = mixer_apply(1) > 0;
        return 0;
    }
    if (tok_eq(p, n, "mute") || tok_eq(p, n, "unmute")) {
        muted = tok_eq(p, n, "mute");
        mixer_hw = mixer_apply(1) > 0;
        return 0;
    }

    /* `stream` and `mixplay` are the 4-stream software mixer, which is not
     * ported -- see the header comment. They fail rather than being accepted
     * and quietly doing nothing. */
    if (tok_eq(p, n, "stream") || tok_eq(p, n, "mixplay")) {
        errno = EINVAL;
        return -1;
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
        /* devaudio_write's count == 0 arms: drain the ring in stream mode,
         * start the staged clip otherwise. */
        if (stream_mode) { pcm_drain(); return 0; }
        return ctl_line("start", 5) < 0 ? -1 : 0;
    }

    if (stream_mode) {
        int64_t w = ring_push(buf, (size_t)n);
        if (w > 0) a->off += (uint64_t)w;
        return w;
    }

    /* STAGED. The write is offset-addressed into the clip and a write at
     * offset 0 truncates it, which is how a client starts a new sound. */
    if (!clip) {
        clip = malloc(CLIP_CAP);
        if (!clip) { errno = ENOMEM; return -1; }
    }
    if (a->off == 0)
        clip_len = 0;
    if (a->off >= CLIP_CAP)
        return 0;                       /* full: hda_dev_write returns 0 */
    uint64_t room = CLIP_CAP - a->off;
    uint64_t take = n < room ? n : room;
    memcpy(clip + a->off, buf, (size_t)take);
    a->off += take;
    if (a->off > clip_len)
        clip_len = (unsigned)a->off;
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
