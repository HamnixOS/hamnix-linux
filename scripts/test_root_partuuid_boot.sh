#!/usr/bin/env bash
# scripts/test_root_partuuid_boot.sh — the two reasons a real machine could not
# boot this image, each as an assertion.
#
# THE HISTORY. An image built by scripts/hamlinux_disk.sh was written to a USB
# stick and booted on the owner's laptop (commit 58c3f506). It printed the EFI
# stub's line, then a blinking cursor, then nothing, forever. Two faults were
# suspected and neither could be confirmed, because the machine had no way to
# say anything:
#
#   1. root=/dev/vda2 was baked into the command line. That is the VIRTIO disk.
#      No physical machine has one.
#   2. Nothing printed. `loglevel=4` silences every kernel message below
#      KERN_ERR, and PID 1's own output goes to /dev/console, which is the LAST
#      console= -- the serial port. So a boot that reached hamsh looked exactly
#      like one that died in the stub.
#
# WHAT IS ASSERTED HERE, in the order the faults were found:
#
#   A. THE CONTROL, and it must be observed BEFORE anything else is believed.
#      The OLD command line is booted and the framebuffer is screendumped: it
#      must be a SINGLE COLOUR, i.e. a black screen. That is what a person saw,
#      and it is what makes this instrument trustworthy -- a screen test that
#      has never seen a blank screen is not a screen test.
#   B. The NEW command line, same kernel, same instant: the framebuffer carries
#      more than one colour, i.e. text.
#   C. root=PARTUUID=<the GUID this disk actually has> resolves to a device and
#      the root is mounted. Nothing on the command line names /dev/anything.
#   D. root=PARTUUID=<a GUID nothing has> prints the identifier it wanted, the
#      partitions it did find WITH THEIR REAL IDENTIFIERS, and the fact that
#      the machine is now running from RAM. A boot that cannot find its root
#      says so instead of looking installed.
#
# WHAT IT DOES NOT PROVE. Nothing here has run on physical hardware. QEMU's
# OVMF hands over an EFI framebuffer exactly as a laptop's firmware does, and
# that is the mechanism being tested -- but the machine in the story is still
# untested, and this gate cannot change that.
#
# REGISTRATION. This gate is not in ci_battery_manifest.txt because it needs
# three things the sharded battery does not have: a writable /dev/kvm, OVMF
# firmware, and a built 3 GB installed disk image (scripts/hamlinux_disk.sh),
# which is minutes of work before the first assertion. It is the same category
# as scripts/test_installer_full.sh and scripts/test_img_uefi_hamui.sh, which
# are on-demand for the same reasons. Run it by hand after touching the boot
# path: scripts/hamlinux_image.sh, scripts/hamlinux_disk.sh, then this.
#
# The kernel and initramfs are booted DIRECTLY (-kernel/-initrd) under OVMF
# rather than through the disk's unified kernel image: same EFI handover, same
# framebuffer, same PID 1, and the command line becomes a parameter of the
# test instead of something baked into a 3 GB rebuild per case.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"

TAG=test_root_partuuid_boot
IMG="${HAMLINUX_IMAGE_DIR:-build/image}"
DISK="${HAMLINUX_DISK:-$IMG/hamnix-linux.img}"
OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.fd
OVMF_VARS=/usr/share/OVMF/OVMF_VARS_4M.fd
WAIT="${WAIT:-6}"          # extra seconds after the frames, for the serial log
export PATH="$PATH:/usr/sbin:/sbin"

for f in "$IMG/vmlinuz" "$IMG/initramfs.cpio.gz" "$DISK" "$OVMF_CODE"; do
    [ -f "$f" ] || verdict_inconclusive "$TAG" \
        "$f is missing; run scripts/hamlinux_image.sh and scripts/hamlinux_disk.sh"
done
command -v socat >/dev/null || verdict_inconclusive "$TAG" "socat is not installed"
command -v sgdisk >/dev/null || verdict_inconclusive "$TAG" "sgdisk is not installed"

WORK="$(mktemp -d)"
cleanup() { [ "${KEEP_LOGS:-0}" = 1 ] || rm -rf "$WORK"; }
. "$PROJ_ROOT/tests/linux/reap.sh"
reap_on_exit cleanup

# The GUID the disk REALLY has, read off the image with a tool that is not the
# one that wrote it. Everything below is compared against this.
REAL_PARTUUID="$(sgdisk -i 2 "$DISK" \
    | awk -F': ' '/Partition unique GUID/ {print tolower($2)}')"
case "$REAL_PARTUUID" in
    ????????-????-????-????-????????????) ;;
    *) verdict_inconclusive "$TAG" \
        "could not read partition 2's GUID from $DISK (got '$REAL_PARTUUID')" ;;
esac
echo "[$TAG] the disk's own root PARTUUID: $REAL_PARTUUID"

# boot <name> <cmdline> — boot, screendump once a second through the early
# boot, and leave $WORK/<name>.log and $WORK/<name>-t<N>.ppm behind.
#
# A SEQUENCE OF FRAMES, not one. The window in which the console is the only
# thing on the screen is about two seconds wide: before it the firmware is
# still drawing, after it the desktop has painted over everything. A single
# screendump at a fixed moment would measure whichever of the three the host's
# load happened to serve up, which is the kind of instrument that reports a
# different answer on a busy machine.
boot() {
    local name="$1" append="$2"
    local log="$WORK/$name.log" mon="$WORK/$name.mon" vars="$WORK/$name.vars"
    cp "$OVMF_VARS" "$vars"
    qemu-system-x86_64 \
        -m 2048 -smp 2 $ACCEL \
        -drive "if=pflash,format=raw,unit=0,readonly=on,file=$OVMF_CODE" \
        -drive "if=pflash,format=raw,unit=1,file=$vars" \
        -kernel "$IMG/vmlinuz" -initrd "$IMG/initramfs.cpio.gz" \
        -drive "file=$DISK,if=virtio,format=raw,snapshot=on" \
        -no-reboot -vga std -display none \
        -serial stdio -monitor "unix:$mon,server,nowait" \
        -append "$append" </dev/null >"$log" 2>&1 &
    local pid=$!
    reap_add "$pid"
    # EVERY THIRD OF A SECOND for the first four seconds. The window in which
    # the console is the only thing on the screen closed in under a second on
    # this host once the initramfs got smaller; a one-second sampler simply
    # missed it, and reported "the screen was never blank" about a boot whose
    # screen was blank.
    local t
    for t in $(seq 1 12); do
        python3 -c 'import time; time.sleep(0.33)'
        printf 'screendump %s\n' "$WORK/$name-t$t.ppm" \
            | socat - "UNIX-CONNECT:$mon" >/dev/null 2>&1 || true
    done
    sleep "$WAIT"
    kill "$pid" 2>/dev/null
    sleep 1
    kill -9 "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    return 0
}

# classify <name> — read every frame of a boot and print one word per frame:
#
#   blank   exactly one colour. The blinking cursor.
#   text    a mostly-black screen CARRYING A SCREENFUL of pixels in the
#           console's own foreground colours (#ffffff for the EFI earlycon,
#           #aaaaaa for fbcon). This is what "the kernel is talking to me"
#           looks like.
#   other   anything else: the firmware's own drawing, or the desktop.
#
# TWO THINGS THE FIRST TWO DRAFTS OF THIS GOT WRONG, both caught by the control
# arm rather than by inspection:
#   * Counting DISTINCT COLOURS alone is not enough: a frame of the desktop
#     wallpaper mid-paint has three colours in it, and so does a screen of
#     console text.
#   * The FIRMWARE also writes white text on black. OVMF's own few lines came
#     to 7109 white pixels; a screen of kernel log comes to 70000-odd. So the
#     threshold is a screenful, not a line, and the control arm -- which must
#     go blank -- is what proves the distinction is being made.
classify() {
    python3 - "$WORK" "$1" <<'PY'
import sys, os
from collections import Counter
work, name = sys.argv[1], sys.argv[2]
out = []
for t in range(1, 13):
    p = f"{work}/{name}-t{t}.ppm"
    if not os.path.exists(p) or os.path.getsize(p) == 0:
        out.append("none"); continue
    d = open(p, 'rb').read()
    i, f = 0, []
    while len(f) < 4:
        while d[i:i+1].isspace(): i += 1
        j = i
        while not d[j:j+1].isspace(): j += 1
        f.append(d[i:j]); i = j
    px = d[i+1:]
    c = Counter(px[k:k+3] for k in range(0, len(px), 3))
    total = sum(c.values())
    ink = c[b'\xff\xff\xff'] + c[b'\xaa\xaa\xaa']
    if len(c) == 1:
        out.append("blank")
    elif c[b"\x00\x00\x00"] > total * 0.5 and ink > 25000:
        out.append("text")
    else:
        out.append("other")
print(" ".join(out))
PY
}

ACCEL="-cpu max"
[ -w /dev/kvm ] && ACCEL="-enable-kvm -cpu host"

OLD_CMDLINE="console=tty0 console=ttyS0,115200 root=/dev/vda2 rw panic=-1 loglevel=4"
NEW_HEAD="console=tty0 earlycon=efifb keep_bootcon console=ttyS0,115200"

# --- A. the control: the old command line, and a screen with nothing on it ---
echo "[$TAG] A. the OLD command line — the screen a person actually saw"
boot old "$OLD_CMDLINE"
OLD_FRAMES="$(classify old)"
echo "[$TAG]    frames every 0.33 s: $OLD_FRAMES"
case "$OLD_FRAMES" in
    *none*none*none*) verdict_inconclusive "$TAG" \
        "no screendumps from the control boot; the monitor socket or -vga std failed" ;;
esac
grep -aq "linuxinit:" "$WORK/old.log" || verdict_inconclusive "$TAG" \
    "the control boot never reached PID 1 at all; a blank screen would say nothing"
case "$OLD_FRAMES" in
    *blank*) ;;
    *) verdict_fail "$TAG" \
        "the CONTROL boot never showed a blank screen ($OLD_FRAMES). Either the old command line is no longer silent, or this instrument is not measuring what a person sees -- and until it has produced a blank frame, its non-blank answers mean nothing." ;;
esac
case "$OLD_FRAMES" in
    *text*) verdict_fail "$TAG" \
        "the CONTROL boot put console text on the screen ($OLD_FRAMES), so the old command line was not the silent one this whole change is about" ;;
esac
echo "[$TAG]    PASS: a blank screen, while the serial port had the entire boot on it."

# --- B. the new command line, same kernel, same moment -----------------------
echo "[$TAG] B. the NEW command line — earlycon + loglevel=7"
boot new "$NEW_HEAD root=PARTUUID=$REAL_PARTUUID rw panic=-1 loglevel=7"
NEW_FRAMES="$(classify new)"
echo "[$TAG]    frames every 0.33 s: $NEW_FRAMES"
case "$NEW_FRAMES" in
    *text*) ;;
    *) verdict_fail "$TAG" \
        "with earlycon=efifb and loglevel=7 the screen never carried console text ($NEW_FRAMES): nothing a person could read reached the framebuffer" ;;
esac

# --- C. the root, named by nothing that exists only in a VM ------------------
if ! grep -aq "sysroot: root=PARTUUID=$REAL_PARTUUID is /dev/" "$WORK/new.log"; then
    verdict_fail "$TAG" \
        "root=PARTUUID=$REAL_PARTUUID was not resolved to a device; see $WORK/new.log"
fi
RESOLVED="$(grep -a -o "sysroot: root=PARTUUID=$REAL_PARTUUID is /dev/[a-z0-9]*" \
    "$WORK/new.log" | head -1 | sed 's/.* is //')"
grep -aq "linuxinit: root filesystem online" "$WORK/new.log" || verdict_fail "$TAG" \
    "the PARTUUID resolved to $RESOLVED but the root was never mounted; see $WORK/new.log"
echo "[$TAG]    PASS: root=PARTUUID -> $RESOLVED, mounted, and the screen had text on it."

# --- D. a root that is not there says so -------------------------------------
echo "[$TAG] D. a PARTUUID nothing on the machine has"
BOGUS=deadbeef-0000-0000-0000-000000000000
boot bogus "$NEW_HEAD root=PARTUUID=$BOGUS rw panic=-1 loglevel=7"
for want in \
    "NO PARTITION ON THIS MACHINE MATCHES root=PARTUUID=$BOGUS" \
    "PARTUUID=$REAL_PARTUUID" \
    "running FROM RAM"
do
    grep -aq "$want" "$WORK/bogus.log" || verdict_fail "$TAG" \
        "a boot with an unfindable root never said \"$want\"; see $WORK/bogus.log"
done
BOGUS_FRAMES="$(classify bogus)"
echo "[$TAG]    frames every 0.33 s: $BOGUS_FRAMES"
case "$BOGUS_FRAMES" in
    *text*) ;;
    *) verdict_fail "$TAG" \
        "the failure was on the serial port but never on the screen ($BOGUS_FRAMES), which is the half of this that matters on a machine with no serial port" ;;
esac
echo "[$TAG]    PASS: it named the identifier, listed the real partitions, and said the system is running from RAM."

verdict_pass "$TAG" \
    "the old command line leaves a blank screen and the new one does not; root=PARTUUID=$REAL_PARTUUID resolves to $RESOLVED and mounts; an unfindable root prints what it wanted and what it saw. Physical hardware remains untested."
