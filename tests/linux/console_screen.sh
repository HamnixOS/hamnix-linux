#!/usr/bin/env bash
# tests/linux/console_screen.sh — DOES A SHIPPED MEDIUM SHOW THE PERSON WHAT
# THE SHELL IS DOING, AND DOES THE SERIAL PORT STILL CARRY IT FOR THE GATES?
#
# THE BUG THIS EXISTS FOR
# =======================
# The owner booted a Lenovo from a stick on 2026-08-15. It reached
#
#     linuxinit: namespace ready -- exec /bin/hamsh /etc/rc.boot
#
# and the screen stopped changing. It had not hung -- sysrq and REISUB both
# worked. The command line ended `console=ttyS0,115200`, /dev/console follows
# the LAST console=, and PID 1 mirrors its own lines to /dev/kmsg (printk goes
# to every console) while the SHELL does not. So everything up to the exec was
# on the screen and everything after it went into a serial port the laptop does
# not have. A boot that had gone right was indistinguishable from one that died.
#
# WHAT IS MEASURED HERE, AND WHY IT NEEDS A SCREEN AND NOT A LOG
# ==============================================================
# A serial log cannot answer this question. It looks the same whether the shell
# printed to the screen or not -- which is literally the bug. So this gate
# reads the FRAMEBUFFER, through the QEMU monitor's `screendump`, and OCRs it.
# The guest is given an rc that prints a marker FROM THE SHELL and then holds
# the screen still long enough to photograph.
#
# `-vga std` on purpose: no DRM driver, an EFI GOP framebuffer and fbcon, which
# is the closest a VM gets to the efifb-only laptop this was found on.
#
# THE NEGATIVE CONTROL IS THE POINT. An OCR that finds nothing looks exactly
# like an OCR that was pointed at the wrong thing, so the same medium is booted
# twice: once as it SHIPS (console=tty0 last) and once with the OLD arrangement
# forced back on through HAMLINUX_CMDLINE (console=ttyS0 last). The shipped one
# must show the marker on the SCREEN; the old one must NOT -- and BOTH must
# carry it on the serial port, because that half is what every other gate in
# this tree reads and the fix must not have bought the screen with it.
#
# Usage: tests/linux/console_screen.sh
# Env:   HAMLINUX_CONSGATE_WORK   where to build and boot (default under
#                                 ~/.hamnix-build/console-screen)
#        HAMLINUX_CONSGATE_REUSE=1  reuse a medium already built there
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"
. tests/linux/reap.sh

WORK="${HAMLINUX_CONSGATE_WORK:-$HOME/.hamnix-build/console-screen}"
mkdir -p "$WORK"
reap_track "$WORK/reaped"
reap_on_exit :

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  PASS  %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$*"; }
say()  { printf '\n== %s\n' "$*"; }
info() { printf '  ..    %s\n' "$*"; }

for t in qemu-system-x86_64 tesseract socat; do
    command -v "$t" >/dev/null || { bad "need $t"; exit 1; }
done
python3 -c 'import PIL' 2>/dev/null || { bad "need python3 Pillow"; exit 1; }

# THE MARKER IS SHAPED FOR OCR, not for prose: upper case, no punctuation that
# a console font renders ambiguously, and a digit run that cannot occur by
# accident in a kernel message.
MARK="HAMSHONSCREEN4711"

cat >"$WORK/rc.consproof" <<RCEOF
# /etc/rc.boot for tests/linux/console_screen.sh. Everything below is printed
# by THE SHELL, after linuxinit has exec'd it -- which is the whole question.
ln -s /dev/console /dev/cons
echo '$MARK'
echo '$MARK'
echo '$MARK'
echo '$MARK'
echo '$MARK'
echo '$MARK'
echo '$MARK'
echo '$MARK'
echo 'CONSPROOF DONE'
sleep 60
poweroff
RCEOF

say "building the medium under test"
if [ "${HAMLINUX_CONSGATE_REUSE:-0}" = 1 ] && [ -f "$WORK/medium.img" ]; then
    info "reusing $WORK/medium.img"
else
    # THIS GATE BOOTED A THREE-DAY-OLD PID 1 AND REPORTED ON IT AS THOUGH IT
    # WERE THE TREE UNDER TEST. scripts/hamlinux_disk.sh builds build/image/root
    # only when it is ABSENT, so once anything has ever built it, every later
    # run packages whatever was lying there. Run against a tree whose whole
    # point was a change to the console arrangement in user/linuxinit.ad and
    # user/linux-syscalls.c, the guest booted the OLD userland and the gate
    # scored 5/7 with "no root switch -- this boot ran from RAM": a red that
    # says nothing about the change, on a gate that had reported 12/0 when its
    # author happened to have a fresh root. tests/linux/boot_log.sh:123 closes
    # the same hole for the same reason; this is that fix, here.
    info "rebuilding build/image/root so this gate cannot boot a stale tree"
    scripts/hamlinux_image.sh >"$WORK/image.log" 2>&1 || {
        bad "image build"; tail -20 "$WORK/image.log"; exit 1; }
    HAMLINUX_DISK_RC="$WORK/rc.consproof" \
        scripts/hamlinux_disk.sh "$WORK/medium.img" 3G >"$WORK/disk.log" 2>&1 || {
        bad "disk build"; tail -20 "$WORK/disk.log"; exit 1; }
fi
SHIPPED_CMDLINE="$(grep -m1 '^\[disk\] cmdline: ' "$WORK/disk.log" | sed 's/^\[disk\] cmdline: //')"
info "cmdline baked into the UKI: $SHIPPED_CMDLINE"

case "$SHIPPED_CMDLINE" in
    *"console=ttyS0"*"console=tty0"*)
        ok "the shipped command line ends with console=tty0, so /dev/console is the SCREEN" ;;
    *) bad "the shipped command line does not put console=tty0 last: $SHIPPED_CMDLINE" ;;
esac
case "$SHIPPED_CMDLINE" in
    *keep_bootcon*) bad "keep_bootcon is back: earlycon and fbcon will both draw into the EFI framebuffer with independent cursors, and every kernel message after the shell writes will be drawn over what the shell wrote" ;;
    *) ok "keep_bootcon is not on the shipped command line, so earlycon hands the framebuffer over" ;;
esac

# THE OLD ARRANGEMENT, rebuilt from the shipped one rather than typed out, so
# the control differs in exactly the thing under test and nothing else.
OLD_CMDLINE="$(printf '%s\n' "$SHIPPED_CMDLINE" \
    | sed 's/console=ttyS0,115200 console=tty0/console=tty0 console=ttyS0,115200/')"
[ "$OLD_CMDLINE" != "$SHIPPED_CMDLINE" ] \
    && ok "negative control command line derived: console=ttyS0 put back last" \
    || bad "could not derive the negative control from the shipped command line"

boot_and_shoot() {  # boot_and_shoot <name> <img> [cmdline-override]
    local name="$1" img="$2" cl="${3:-}"
    local d="$WORK/$name"
    rm -rf "$d"; mkdir -p "$d"
    local use="$img"
    if [ -n "$cl" ]; then
        # A different command line is a different UKI, so the medium is rebuilt
        # rather than patched -- the string lives in a PE section.
        #
        # HAMLINUX_ROOT_PARTUUID IS NOT OPTIONAL HERE, and leaving it out cost a
        # run: the override command line carries the SHIPPED medium's partition
        # GUID, while a rebuild mints a fresh one for its own partition 2. The
        # kernel then found no root, fell back to the initramfs, and the control
        # booted a RAM system whose rc is not the one under test -- a boot that
        # printed no marker for a reason that had nothing to do with consoles.
        # The GUID is read back out of the command line being used, so the two
        # cannot disagree.
        local uuid
        uuid="$(printf '%s\n' "$cl" | sed -n 's/.*root=PARTUUID=\([0-9a-fA-F-]*\).*/\1/p')"
        [ -n "$uuid" ] || { bad "$name: no root=PARTUUID in the override command line"; return 1; }
        HAMLINUX_CMDLINE="$cl" HAMLINUX_ROOT_PARTUUID="$uuid" \
        HAMLINUX_DISK_RC="$WORK/rc.consproof" \
            scripts/hamlinux_disk.sh "$d/medium.img" 3G >"$d/disk.log" 2>&1 || {
            bad "$name: disk build"; tail -10 "$d/disk.log"; return 1; }
        use="$d/medium.img"
    fi
    cp /usr/share/OVMF/OVMF_VARS_4M.fd "$d/OVMF_VARS.fd"
    truncate -s 4G "$d/nvme.img"
    qemu-system-x86_64 \
        -m 2048 -smp 2 -no-reboot \
        -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
        -drive "if=pflash,format=raw,unit=1,file=$d/OVMF_VARS.fd" \
        -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
        -display none -vga std \
        -serial "file:$d/serial.log" \
        -enable-kvm -cpu host \
        -monitor "unix:$d/mon.sock,server,nowait" \
        -device qemu-xhci,id=xhci -device usb-kbd -device usb-tablet \
        -drive "file=$d/nvme.img,if=none,format=raw,id=nvme0" \
        -device nvme,drive=nvme0,serial=CONSGATE \
        -drive "file=$use,if=none,format=raw,id=usbstick" \
        -device usb-storage,bus=xhci.0,drive=usbstick,bootindex=0 \
        >"$d/qemu.out" 2>&1 &
    local vm=$!
    reap_add "$vm"
    # Wait for the guest to say it is done ON THE SERIAL PORT -- which both
    # arrangements do, and which is itself one of the assertions below.
    local w=0
    while kill -0 "$vm" 2>/dev/null && [ "$w" -lt 240 ]; do
        grep -aq 'CONSPROOF DONE' "$d/serial.log" 2>/dev/null && break
        sleep 2; w=$((w+2))
    done
    sleep 3   # let fbcon finish drawing what the shell just wrote
    printf 'screendump %s\n' "$d/screen.ppm" \
        | timeout 15 socat - "UNIX-CONNECT:$d/mon.sock" >/dev/null 2>&1
    kill -TERM "$vm" 2>/dev/null; sleep 2; kill -KILL "$vm" 2>/dev/null
    wait "$vm" 2>/dev/null
    [ -s "$d/serial.log" ] || { bad "$name: EMPTY SERIAL LOG -- the VM never ran"; return 1; }
    [ -s "$d/screen.ppm" ] || { bad "$name: NO SCREENDUMP -- the monitor never answered"; return 1; }
    tesseract "$d/screen.ppm" "$d/screen" 2>/dev/null
    return 0
}

say "BOOT A: the medium AS IT SHIPS (console=tty0 last), -vga std"
boot_and_shoot shipped "$WORK/medium.img" || exit 1
A="$WORK/shipped"

grep -aq 'root filesystem online' "$A/serial.log" \
    && ok "shipped: the root switch happened, so the rc under test is the DISK's" \
    || bad "shipped: no root switch -- this boot ran from RAM and its rc is not the one under test"
grep -aq "$MARK" "$A/serial.log" \
    && ok "shipped: the shell's marker IS on the serial port (the gates still capture)" \
    || bad "shipped: the shell's marker is NOT on the serial port -- every gate in this tree just went blind"
grep -aq 'namespace ready' "$A/serial.log" \
    && ok "shipped: PID 1's lines are still on the serial port" \
    || bad "shipped: PID 1's lines are not on the serial port"
# THE OTHER HALF OF RETIRING keep_bootcon. earlycon is handed off the moment the
# VT console registers, which this tree's guest log puts at 0.23 s -- over a
# second before efifb probes. If the VT layer did NOT hold what was written to
# it while dummycon was the driver, and fbcon did not redraw that buffer on
# takeover, everything printed in that window would be lost and the screen would
# start mid-boot. `usb-storage` and the root scan are both in it.
if grep -aqE 'usb-storage|SCSI disk|Attached' "$A/screen.txt" 2>/dev/null; then
    ok "shipped: the kernel's own early boot lines are on the screen with earlycon already handed off"
else
    bad "shipped: the kernel's early boot lines are NOT on the screen -- dropping keep_bootcon lost them"
fi
if grep -aqE '^\[ *[0-9]+\.[0-9]+\] *linuxinit' "$A/screen.txt" 2>/dev/null; then
    bad "shipped: PID 1's lines are on the screen TWICE (a bare copy and a printk copy) -- the kmsg mirror is being printed as well"
else
    ok "shipped: PID 1's lines appear on the screen once, not once bare and once with a printk timestamp"
fi
if grep -aq "$MARK" "$A/screen.txt" 2>/dev/null; then
    ok "shipped: THE SHELL'S MARKER IS ON THE SCREEN (OCR of the framebuffer)"
else
    bad "shipped: the shell's marker is NOT on the screen -- this is the laptop bug"
    info "OCR read: $(tr '\n' ' ' <"$A/screen.txt" 2>/dev/null | cut -c1-200)"
fi

say "BOOT B: THE NEGATIVE CONTROL -- the same medium with console=ttyS0 last"
boot_and_shoot control "$WORK/medium.img" "$OLD_CMDLINE" || exit 1
B="$WORK/control"

grep -aq 'root filesystem online' "$B/serial.log" \
    && ok "control: the root switch happened, so the rc under test is the DISK's" \
    || bad "control: no root switch -- this boot ran from RAM and its rc is not the one under test"
grep -aq "$MARK" "$B/serial.log" \
    && ok "control: the shell's marker is on the serial port (so the guest DID run and DID print it)" \
    || bad "control: the marker is not even on the serial port -- the control did not run, so it proves nothing"
if grep -aq "$MARK" "$B/screen.txt" 2>/dev/null; then
    bad "control: the marker is on the screen even with console=ttyS0 last -- the instrument is not measuring what it claims"
else
    ok "control: the marker is NOT on the screen, which is the bug reproduced -- so BOOT A's screen reading means something"
fi

printf '\n%d PASSED, %d FAILED\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
