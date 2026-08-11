#!/usr/bin/env bash
# scripts/hamlinux_vm.sh — boot the staged hamnix-linux image under QEMU/KVM.
#
# Everything runs inside the VM. The host is never mounted into it and no host
# filesystem is written: this is the isolation the port needs, because PID 1
# here is root and sys_bind performs real mount(2) calls.
#
# Modes:
#   serial   (default) headless, console on stdio. For shell work and CI.
#   gpu      virtio-gpu + a display window. For the compositor: this is what
#            gives the guest a DRM/KMS device (/dev/dri/card0) to scan out on.
#   venus    virtio-gpu-gl with venus=on: the guest gets a REAL, host-GPU-
#            accelerated Vulkan device. See the long note at the mode itself.
#   script   headless, non-interactive: feed a command to the guest shell and
#            exit. Used by the boot smoke test.
#
# Usage: scripts/hamlinux_vm.sh [serial|gpu|venus|script] [--timeout N]
#                               [-- qemu args]
set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

MODE="${1:-serial}"; shift || true
TIMEOUT=""
if [ "${1:-}" = "--timeout" ]; then TIMEOUT="$2"; shift 2; fi
[ "${1:-}" = "--" ] && shift

IMG=build/image
[ -f "$IMG/vmlinuz" ] || { echo "no image; run scripts/hamlinux_image.sh first" >&2; exit 1; }

# KVM when the host allows it; TCG otherwise, so this still runs in a container.
ACCEL=()
if [ -w /dev/kvm ]; then ACCEL=(-enable-kvm -cpu host); else
    echo "[vm] /dev/kvm not writable — falling back to TCG (slower)" >&2
    ACCEL=(-cpu max)
fi

COMMON=(
    -m 4096
    -smp 2
    "${ACCEL[@]}"
    -kernel "$IMG/vmlinuz"
    -initrd "$IMG/initramfs.cpio.gz"
    -no-reboot
    # virtio-gpu is always present, even headless: it is what gives the guest a
    # DRM/KMS device (/dev/dri/card0) for user/linux-fb.c to scan out on. The
    # display is separate -- serial/script modes just never open a window.
    -vga none
    -device virtio-gpu-pci
    # A keyboard and an ABSOLUTE pointer. The tablet is deliberate: it reports
    # a position rather than a delta, so the guest cursor tracks the host
    # cursor exactly and there is no pointer to grab. wsysd decodes both
    # (EV_ABS and EV_REL), so a real machine's relative mouse works too.
    -device virtio-keyboard-pci
    -device virtio-tablet-pci
    # Networking. QEMU's user-mode stack needs no host privilege and puts the
    # guest on 10.0.2.0/24 with the gateway at .2 and a DNS forwarder at .3 --
    # which is why etc/rc.boot.linux configures exactly those addresses. On
    # real hardware the same three ifconfig lines take the machine's own.
    -netdev user,id=n0
    -device virtio-net-pci,netdev=n0
)

# --- sound ----------------------------------------------------------------
# An Intel HD Audio controller with the DUPLEX codec, which is what gives the
# guest /dev/snd/pcmC0D0p (playback) AND /dev/snd/pcmC0D0c (capture), i.e. the
# two nodes user/linux-audio.c opens for /dev/audio and /dev/audioin.
#
# WHY intel-hda AND NOT virtio-sound-pci. Three reasons, in order of weight:
#   * It is the device Hamnix's own audio driver was written and measured
#     against (drivers/audio/hda.ad, scripts/run_installer.sh), so the two
#     kernels present the SAME hardware to the same userland and a difference
#     in behaviour is a difference in the port rather than in the emulation.
#   * hda-duplex carries a capture stream. virtio-sound-pci does too, but the
#     guest driver (virtio_snd) is far younger than snd-hda-intel and the
#     failure modes are less well trodden; snd-hda-intel + the generic codec
#     is the boring, universally-supported path. virtio_snd is staged into the
#     image anyway (scripts/hamlinux_image.sh), so pointing this at
#     `-device virtio-sound-pci,audiodev=snd0` instead needs no guest change.
#   * ich6 intel-hda rather than ich9-intel-hda: no MSI, no extra PCI bridge
#     requirements, and identical from the driver's seat.
#
# THE BACKEND DEFAULTS TO `none`, AND THAT IS THE POINT. `none` is a real,
# correctly-timed sink that consumes samples at the stream's rate and throws
# them away -- so the guest driver behaves exactly as it would with speakers,
# and QEMU never opens the host's sound card. Nothing on this line may play
# out of the developer's machine, and nothing in the automated gates may
# depend on the host having a card at all.
#
#   HAMLINUX_AUDIODEV=wav,path=/tmp/guest.wav   capture the codec output to a
#                                               WAV file -- this is how the
#                                               audio gates MEASURE that a
#                                               tone was really played.
#   HAMLINUX_AUDIODEV=pipewire|pa|alsa          actually hear it. Operator
#                                               choice, never a default.
AUDIODEV="${HAMLINUX_AUDIODEV:-none}"
COMMON+=(
    -audiodev "${AUDIODEV},id=snd0"
    -device intel-hda
    -device hda-duplex,audiodev=snd0
)

# The Debian namespace lives on its own filesystem image, attached as a plain
# virtio-blk disk and mounted by `bind '#distro' /n/distro`. Keeping it on a
# SEPARATE volume is the point: nothing Debian installs can reach the Hamnix
# filesystem.
if [ -f "$IMG/distro.ext4" ]; then
    COMMON+=(-drive "file=$IMG/distro.ext4,if=virtio,format=raw,cache=unsafe")
fi

# A blank disk to INSTALL onto, when one has been made. This is what turns the
# live boot into an installer test: user/hlinstall.ad partitions it, makes the
# filesystems and copies the system, and then `scripts/hamlinux_vm.sh disk`
# boots the result.
if [ -f "$IMG/target.img" ]; then
    COMMON+=(-drive "file=$IMG/target.img,if=virtio,format=raw,cache=unsafe")
fi

# panic=-1 with -no-reboot makes a PID-1 death terminate QEMU instead of
# hanging, which matters because an init that exits is exactly the failure this
# is most likely to hit.
APPEND="console=ttyS0,115200 panic=-1 loglevel=4"

case "$MODE" in
  serial)
    exec qemu-system-x86_64 "${COMMON[@]}" -display none -serial mon:stdio \
        -append "$APPEND" "$@"
    ;;
  script)
    # Non-interactive: the guest shell reads stdin, so a heredoc on our stdin
    # drives it. timeout keeps a hung boot from wedging CI.
    # The VNC display is a fixed port, which means two gates cannot run at
    # once: the second dies with "Failed to find an available port" before the
    # guest is even started, and the failure looks nothing like a port clash
    # in the test's own output. HAMLINUX_VNC overrides it -- `none` for a gate
    # that only wants the serial console.
    CMD=(qemu-system-x86_64 "${COMMON[@]}" -vnc "${HAMLINUX_VNC:-127.0.0.1:9}" -serial stdio
         -monitor unix:build/image/mon.sock,server,nowait
         -append "$APPEND" "$@")
    if [ -n "$TIMEOUT" ]; then exec timeout "$TIMEOUT" "${CMD[@]}"; else exec "${CMD[@]}"; fi
    ;;
  gpu)
    # virtio-gpu-pci gives the guest a real DRM device. Serial stays on stdio so
    # the shell is still reachable while the display window is up.
    exec qemu-system-x86_64 "${COMMON[@]}" \
        -display gtk \
        -serial mon:stdio \
        -append "$APPEND" "$@"
    ;;
  venus)
    # REAL GPU ACCELERATION IN THE GUEST, and the only mode here that is not
    # emulation.
    #
    # virtio-gpu-gl-pci with venus=on turns the virtio-gpu device into a Vulkan
    # TRANSPORT: QEMU hands the guest's Vulkan command stream to virglrenderer,
    # which replays it on the HOST's Vulkan driver. In the guest that appears
    # as an ordinary ICD -- Mesa's venus, libvulkan_virtio.so -- so the Adder
    # side changes nothing at all. Install hamnix-vulkan-venus (or build the
    # image with HAMLINUX_VULKAN=venus, which is the default) and `vkprobe`
    # prints the HOST card's name from inside a Hamnix VM.
    #
    # Three requirements, and all three fail LOUDLY rather than silently
    # falling back, which is what you want:
    #   * blob=true. Venus needs blob resources (host-visible memory); without
    #     it the device advertises no Vulkan at all.
    #   * hostmem. The window into host memory the blobs live in. 4G is enough
    #     for a desktop; QEMU's max_hostmem must not be smaller.
    #   * a host GPU. QEMU opens the host's /dev/dri and the host's Vulkan
    #     driver. THAT IS THE POINT of this mode and it is also why nothing in
    #     the automated tests here runs it: the standing rule on this tree is
    #     that host-side Vulkan is forced to the software ICD and the real
    #     hardware is the VM's business. This mode is the deliberate,
    #     operator-invoked exception -- run it by hand, on a machine whose
    #     display you are willing to have QEMU touch.
    #
    # If the host cannot do it, QEMU says so and exits. A guest that boots and
    # reports zero Vulkan devices means venus did not come up; check the guest
    # for /dev/dri/card0 first (the virtio-gpu module still has to load) and
    # then the QEMU stderr, which names the missing host capability.
    #
    # RUN ON THIS DEV BOX 2026-08-10, headless, with the machine owner's
    # explicit go-ahead. It got a long way and then stopped at a HOST driver
    # limit, so the result is written down here rather than rediscovered:
    #
    #   HAMLINUX_DISPLAY=egl-headless,rendernode=/dev/dri/renderD128
    #       -> guest gets /dev/dri/card0 AND renderD128; virtio_gpu binds;
    #          QEMU's virglrenderer processes guest commands. So the whole
    #          transport works.
    #       -> host: "nv_gbm.c:288 GBM-DRV error (nv_gbm_create_device_native)"
    #          -> every venus context create comes back 0x1200 / 0x1203
    #          -> vkCreateInstance returns -1 in the guest.
    #
    # The NVIDIA driver's GBM backend cannot create a device here. That is
    # the usual symptom of nvidia-drm.modeset=0; confirming it needs root
    # (/sys/module/nvidia_drm/parameters/modeset is 0400) and fixing it needs
    # a driver reload, which takes the display down -- i.e. exactly what
    # "headless" was chosen to avoid. NOT a fault in the guest stack.
    #
    #   HAMLINUX_DISPLAY=none  -> QEMU refuses outright: "The display backend
    #                             does not have OpenGL support enabled".
    #                             venus needs a GL-capable display backend
    #                             even though venus itself is Vulkan-only.
    #
    # So on an AMD or Intel host, or an NVIDIA host with modeset=1, the
    # egl-headless line above is the one to run. Everything below it is
    # verified; the host EGL/GBM device is the single missing link.
    VENUS=(
        -m 4096 -smp 2
        -kernel "$IMG/vmlinuz" -initrd "$IMG/initramfs.cpio.gz" -no-reboot
        -vga none
        -device virtio-gpu-gl-pci,venus=on,blob=true,hostmem=4G,max_hostmem=4G
        -device virtio-keyboard-pci -device virtio-tablet-pci
        -netdev user,id=n0 -device virtio-net-pci,netdev=n0
        -display "${HAMLINUX_DISPLAY:-gtk,gl=on}"
        -serial mon:stdio
        -append "$APPEND"
    )
    if [ -w /dev/kvm ]; then VENUS+=(-enable-kvm -cpu host); else VENUS+=(-cpu max); fi
    if [ -f "$IMG/distro.ext4" ]; then
        VENUS+=(-drive "file=$IMG/distro.ext4,if=virtio,format=raw,cache=unsafe")
    fi
    exec qemu-system-x86_64 "${VENUS[@]}" "$@"
    ;;
  disk|disk-gpu)
    # Boot the INSTALLED disk, not the initramfs: no -kernel, no -initrd, the
    # firmware finds /EFI/BOOT/BOOTX64.EFI on the ESP exactly as it would on a
    # real machine. That is the point of this mode -- it exercises the boot
    # path a physical install uses, rather than QEMU's kernel loader.
    # HAMLINUX_DISK boots a different disk -- the one the in-system installer
    # just wrote, for instance, which is the only way to prove it wrote a
    # bootable one.
    IMGFILE="${HAMLINUX_DISK:-$IMG/hamnix-linux.img}"
    [ -f "$IMGFILE" ] || { echo "no disk; run scripts/hamlinux_disk.sh" >&2; exit 1; }
    OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.fd
    OVMF_VARS_SRC=/usr/share/OVMF/OVMF_VARS_4M.fd
    [ -f "$OVMF_CODE" ] || { echo "no OVMF firmware (apt install ovmf)" >&2; exit 1; }
    VARS="$IMG/OVMF_VARS.fd"
    [ -f "$VARS" ] || cp "$OVMF_VARS_SRC" "$VARS"
    DISK=(
        -m 2048 -smp 2
        -drive "if=pflash,format=raw,unit=0,readonly=on,file=$OVMF_CODE"
        -drive "if=pflash,format=raw,unit=1,file=$VARS"
        -drive "file=$IMGFILE,if=virtio,format=raw"
        -no-reboot
        -vga none -device virtio-gpu-pci
        -device virtio-keyboard-pci -device virtio-tablet-pci
        -netdev user,id=n0 -device virtio-net-pci,netdev=n0
        # Same card as the live boot -- an INSTALLED system that lost its
        # sound hardware would be a difference nobody would look for.
        -audiodev "${AUDIODEV},id=snd0"
        -device intel-hda -device hda-duplex,audiodev=snd0
    )
    if [ -w /dev/kvm ]; then DISK+=(-enable-kvm -cpu host); else DISK+=(-cpu max); fi
    if [ -f "$IMG/distro.ext4" ]; then
        DISK+=(-drive "file=$IMG/distro.ext4,if=virtio,format=raw,cache=unsafe")
    fi
    if [ "$MODE" = disk-gpu ]; then
        exec qemu-system-x86_64 "${DISK[@]}" -display gtk -serial mon:stdio "$@"
    fi
    CMD=(qemu-system-x86_64 "${DISK[@]}" -display none -serial stdio
         -monitor "unix:$IMG/mon.sock,server,nowait" "$@")
    if [ -n "$TIMEOUT" ]; then exec timeout "$TIMEOUT" "${CMD[@]}"; else exec "${CMD[@]}"; fi
    ;;
  *)
    echo "usage: hamlinux_vm.sh [serial|gpu|venus|script|disk|disk-gpu]" >&2; exit 2 ;;
esac
