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
#   script   headless, non-interactive: feed a command to the guest shell and
#            exit. Used by the boot smoke test.
#
# Usage: scripts/hamlinux_vm.sh [serial|gpu|script] [--timeout N] [-- qemu args]
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
    -m 2048
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

# The Debian namespace lives on its own filesystem image, attached as a plain
# virtio-blk disk and mounted by `bind '#distro' /n/distro`. Keeping it on a
# SEPARATE volume is the point: nothing Debian installs can reach the Hamnix
# filesystem.
if [ -f "$IMG/distro.ext4" ]; then
    COMMON+=(-drive "file=$IMG/distro.ext4,if=virtio,format=raw,cache=unsafe")
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
    CMD=(qemu-system-x86_64 "${COMMON[@]}" -vnc 127.0.0.1:9 -serial stdio
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
  disk|disk-gpu)
    # Boot the INSTALLED disk, not the initramfs: no -kernel, no -initrd, the
    # firmware finds /EFI/BOOT/BOOTX64.EFI on the ESP exactly as it would on a
    # real machine. That is the point of this mode -- it exercises the boot
    # path a physical install uses, rather than QEMU's kernel loader.
    IMGFILE="$IMG/hamnix-linux.img"
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
    echo "usage: hamlinux_vm.sh [serial|gpu|script|disk|disk-gpu]" >&2; exit 2 ;;
esac
