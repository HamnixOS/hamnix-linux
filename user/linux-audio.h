/* user/linux-audio.h — /dev/audio, /dev/audioctl, /dev/audioin.
 *
 * The port of Hamnix's drivers/audio/audio_cdev.ad onto ALSA. See
 * user/linux-audio.c for the protocol and for what is and is not ported. */
#ifndef HAMNIX_LINUX_AUDIO_H
#define HAMNIX_LINUX_AUDIO_H

#include <stdint.h>

enum {
    HAMAUDIO_NONE = 0,
    HAMAUDIO_PCM,       /* /dev/audio    — PCM sink on write, status on read */
    HAMAUDIO_CTL,       /* /dev/audioctl — text control verbs               */
    HAMAUDIO_IN,        /* /dev/audioin  — captured PCM on read             */
};

/* Per-open state. The DEVICE state (format, the staged clip, the PCM
 * descriptors) is global and lives in linux-audio.c, exactly as it is global
 * in the Hamnix kernel device this ports. */
struct hamaudio_file {
    int      kind;      /* HAMAUDIO_*                                    */
    uint64_t off;       /* byte cursor: the clip offset, or the status
                         * snapshot's read position                      */
};

int     hamaudio_kind(const char *path);
int     hamaudio_open(const char *path, int for_write, struct hamaudio_file *a);
int64_t hamaudio_read(struct hamaudio_file *a, uint8_t *buf, uint64_t cap);
int64_t hamaudio_write(struct hamaudio_file *a, const uint8_t *buf, uint64_t n);
int64_t hamaudio_seek(struct hamaudio_file *a, int64_t off, int32_t whence);
void    hamaudio_close(struct hamaudio_file *a);

#endif
