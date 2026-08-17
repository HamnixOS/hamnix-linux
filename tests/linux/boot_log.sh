#!/usr/bin/env bash
#
# REGISTRATION, 2026-08-17. Until this date scripts/test_gate_registration.sh
# globbed only scripts/test_*.sh, so this directory was invisible to the gate
# against unregistered gates and every file in it read as coverage without
# being coverage. This gate is ON-DEMAND: not in ci_battery_manifest.txt
# because it boots a machine under `qemu-system-x86_64`.
#
# tests/linux/boot_log.sh — AFTER THE POWER BUTTON, IS THERE A FILE?
#
# THE PROBLEM THIS GATE IS ABOUT, AND IT IS THE HUMAN LOOP RATHER THAN THE CODE
# ============================================================================
# The owner boots a Lenovo off a stick this tree builds. He has no serial cable,
# no shell and no second machine attached. When something goes wrong the only
# evidence that survives is a PHOTOGRAPH OF THE SCREEN -- the last forty lines,
# in whatever state the console left them, quite possibly with the compositor
# painted over the top of them. On 2026-08-15 that photograph cost a whole
# investigation to conclude that the boot in it had been fine.
#
# So the stick keeps its own log (user/bootlogd.ad), and this gate asks the only
# question that matters about it:
#
#   IF THE MACHINE IS SWITCHED OFF AT THE WALL, IS THE FILE STILL THERE, AND
#   DOES IT SAY WHAT HAPPENED?
#
# WHY THE READBACK IS THE WHOLE TEST
# ==================================
# A log that was never read back off a powered-off image is not a log. Every
# assertion below is made against bytes recovered with `mcopy` FROM THE DISK
# IMAGE, WITH THE GUEST DEAD -- never against the serial log, which is precisely
# the channel the owner does not have and which would happily show a "wrote the
# log" line for a write that went into a page cache and evaporated.
#
# AND THE POWER CUT IS A REAL ONE. SIGKILL to QEMU, with no shutdown of any
# kind, which tests/linux/install_from_usb.sh established is the equivalent of
# pulling the plug and which it measured DESTROYING an ext4 write that had not
# reached its 5 s journal commit. That is the failure mode this arrangement is
# built to survive, so it is the one that is performed.
#
# THE INSTRUMENT IS PROVED BEFORE IT IS BELIEVED
# ==============================================
# An empty or seedless recovered file looks identical whether the boot wrote
# nothing or `mcopy` was pointed at the wrong offset -- which is the exact class
# of bug this whole effort came out of. So the preallocated file SHIPS WITH A
# SENTINEL SENTENCE in it saying it has not been written yet, and this gate
# asserts BOTH directions:
#
#   * in a FRESHLY BUILT, NEVER BOOTED image the sentinel IS present -- which
#     proves mcopy is reading the right file off the right partition, and that
#     "the sentinel is gone" later is a real observation and not a misdirected
#     read;
#   * in the POWER-CUT image the sentinel is GONE and the boot's own lines are
#     there instead.
#
# THE FAILURE PATH IS ALSO A TEST. A third boot is given a medium whose log file
# has been DELETED from the ESP. The boot must still complete and must say so on
# the console. A logging facility that can stop a boot is worse than none.
#
# `-vga std` and usb-storage on qemu-xhci throughout: no DRM driver, an EFI GOP
# framebuffer, the closest a VM gets to the efifb-only laptop this was found on.
#
# Usage: tests/linux/boot_log.sh
# Env:   HAMLINUX_BOOTLOG_WORK   where to build and boot
#        HAMLINUX_BOOTLOG_REUSE=1  reuse a medium already built there
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"
# FIRST, before reap.sh and before $WORK -- the contract in
# tests/linux/private_ns.sh. gates_are_private.sh checks that this line is here.
. tests/linux/private_ns.sh
priv_ns_reexec "$@"
. tests/linux/reap.sh

WORK="${HAMLINUX_BOOTLOG_WORK:-$HOME/.hamnix-build/boot-log}"
mkdir -p "$WORK"
reap_track "$WORK/reaped"
reap_on_exit :

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  PASS  %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$*"; }
say()  { printf '\n== %s\n' "$*"; }
info() { printf '  ..    %s\n' "$*"; }

# sgdisk lives in /sbin, which is not on a normal user's PATH -- and
# scripts/hamlinux_disk.sh, which this gate drives, adds it for the same reason.
export PATH="$PATH:/usr/sbin:/sbin"
for t in qemu-system-x86_64 mcopy mdel sgdisk; do
    command -v "$t" >/dev/null || { bad "need $t"; exit 1; }
done
[ -f /usr/share/OVMF/OVMF_CODE_4M.fd ] || { bad "need OVMF"; exit 1; }

# The marker is printed BY THE SHELL, after linuxinit has exec'd it -- the half
# of the boot that was invisible on the laptop and the half a kernel-only log
# would not have. A digit run that cannot occur in a kernel message by accident.
MARK="BOOTLOGPROOF8823"
# The sentence the build script writes into the preallocated file. If this
# string changes in scripts/hamlinux_disk.sh it must change here.
SEED_SENTINEL="THIS FILE HAS NOT BEEN WRITTEN BY ANY BOOT YET"

# THE rc UNDER TEST SOURCES THE REAL ONE VERBATIM, which is the arrangement
# scripts/hamlinux_disk.sh's own header describes for exactly this purpose: a
# test that overrode /etc/rc.boot with something of its own would prove nothing
# about the file that ships. So this runs etc/rc.boot.installed unchanged -- the
# bind, the spawn and the on-screen marker included -- and then asks its
# questions afterwards.
#
# NO poweroff. The whole point is that the machine is killed at the wall while
# it is running, so the shell parks instead.
cat >"$WORK/rc.bootlogproof" <<RCEOF
source '/etc/rc.boot.installed'
echo '$MARK'
sleep 600
RCEOF

say "building the medium under test (the shipped rc, sourced verbatim)"
if [ "${HAMLINUX_BOOTLOG_REUSE:-0}" = 1 ] && [ -f "$WORK/medium.img" ]; then
    info "reusing $WORK/medium.img"
else
    # THE ROOT TREE IS REBUILT EXPLICITLY, AND THIS GATE PAID TO LEARN WHY.
    # scripts/hamlinux_disk.sh rebuilds it only when build/image/root is
    # ABSENT -- `[ -d build/image/root ] || scripts/hamlinux_image.sh` -- so
    # every run after the first packages whatever tree happened to be lying
    # there. A change to user/linuxinit.ad was made, the gate was run three
    # times, and the guest booted the OLD PID 1 every time while the gate
    # reported on it as though it were the new one. That is the stale-artifact
    # false-report class 5ea565a6 went through this tree to kill, and it is
    # cheap to close here: ~3 minutes when nothing changed.
    info "rebuilding build/image/root so this gate cannot boot a stale tree"
    scripts/hamlinux_image.sh >"$WORK/image.log" 2>&1 || {
        bad "image build"; tail -20 "$WORK/image.log"; exit 1; }
    HAMLINUX_DISK_RC="$WORK/rc.bootlogproof" \
        scripts/hamlinux_disk.sh "$WORK/medium.img" 3G >"$WORK/disk.log" 2>&1 || {
        bad "disk build"; tail -20 "$WORK/disk.log"; exit 1; }
fi
grep -q 'preallocated .*HAMNIX.LOG boot log' "$WORK/disk.log" \
    && ok "the build preallocated \\HAMNIX.LOG on the ESP" \
    || bad "the build said nothing about preallocating \\HAMNIX.LOG"

# THE RATE LIMIT, WHICH COST A DAY AND LEFT NO TRACE. Writes to /dev/kmsg
# default to ten records per five seconds, GLOBALLY, and the rest are dropped
# with no error to the writer. That is how the mirror gets the shell's output
# into the ring, so without this parameter the log loses whole seconds out of
# its middle and looks completely healthy doing it. Asserted on the SHIPPED
# command line, not on a gate override, because it is baked into a PE section
# of the UKI and user/hlinstall.ad copies that very UKI onto an installed
# machine's ESP.
SHIPPED_CMDLINE="$(grep -m1 '^\[disk\] cmdline: ' "$WORK/disk.log" | sed 's/^\[disk\] cmdline: //')"
info "cmdline baked into the UKI: $SHIPPED_CMDLINE"
case "$SHIPPED_CMDLINE" in
    *printk.devkmsg=on*)
        ok "the shipped command line carries printk.devkmsg=on, so /dev/kmsg is not rate limited" ;;
    *) bad "printk.devkmsg=on is NOT on the shipped command line: the boot log will silently lose lines from its middle" ;;
esac

# --- where partition 1 starts, read back from the GPT rather than assumed ----
ESP_SECTOR=$(sgdisk -i 1 "$WORK/medium.img" | awk '/First sector/ {print $3}')
[[ "$ESP_SECTOR" =~ ^[0-9]+$ ]] || ESP_SECTOR=2048
ESP_OFF=$(( ESP_SECTOR * 512 ))
info "the ESP starts at sector $ESP_SECTOR (byte $ESP_OFF)"

# recover_log <img> <out> -- pull \HAMNIX.LOG off partition 1 of an image.
recover_log() {
    mcopy -n -o -i "${1}@@${ESP_OFF}" "::/HAMNIX.LOG" "$2" 2>/dev/null
}

# ---------------------------------------------------------------------------
say "STEP 0 -- THE INSTRUMENT: the file in a FRESHLY BUILT, NEVER BOOTED image"
# ---------------------------------------------------------------------------
# Read the log out of the image BEFORE anything boots it. This is what makes
# every later reading mean something: it proves the offset is right, the file is
# there, and that a recovered file which does NOT contain the sentinel is a real
# observation rather than a misdirected mcopy.
if recover_log "$WORK/medium.img" "$WORK/fresh.log"; then
    ok "mcopy can pull \\HAMNIX.LOG off partition 1 of a freshly built image"
    FRESH_BYTES=$(stat -c%s "$WORK/fresh.log")
    info "fresh \\HAMNIX.LOG is $FRESH_BYTES bytes"
    [ "$FRESH_BYTES" = 262144 ] \
        && ok "it is preallocated at exactly 262144 bytes (the size bootlogd expects)" \
        || bad "it is $FRESH_BYTES bytes, not the 262144 the writer is built for"
    grep -aq "$SEED_SENTINEL" "$WORK/fresh.log" \
        && ok "an unbooted stick SAYS it has not been written yet -- an unwritten log cannot be mistaken for an empty one" \
        || bad "the unbooted file does not carry the sentinel, so 'the sentinel is gone' later would prove nothing"
    grep -aq "$MARK" "$WORK/fresh.log" \
        && bad "the marker is in the file BEFORE any boot -- this gate cannot measure anything" \
        || ok "the marker is NOT in the file before any boot (the control is clean)"
else
    bad "could not mcopy \\HAMNIX.LOG off a freshly built image -- nothing below can be trusted"
    exit 1
fi

# ---------------------------------------------------------------------------
# boot_and_cut <name> <img> -- boot the image as a USB stick, wait for the
# shell's marker on the serial port, let a snapshot or two happen, then CUT THE
# POWER. Returns with $d/serial.log and the image mutated in place.
# ---------------------------------------------------------------------------
boot_and_cut() {
    local name="$1" src="$2" waitfor="${3:-$MARK}"
    local d="$WORK/$name"
    rm -rf "$d"; mkdir -p "$d"
    cp "$src" "$d/medium.img"
    cp /usr/share/OVMF/OVMF_VARS_4M.fd "$d/OVMF_VARS.fd"
    qemu-system-x86_64 \
        -m 2048 -smp 2 -no-reboot \
        -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
        -drive "if=pflash,format=raw,unit=1,file=$d/OVMF_VARS.fd" \
        -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
        -display none -vga std \
        -serial "file:$d/serial.log" \
        -enable-kvm -cpu host \
        -device qemu-xhci,id=xhci -device usb-kbd -device usb-tablet \
        -drive "file=$d/medium.img,if=none,format=raw,id=usbstick" \
        -device usb-storage,bus=xhci.0,drive=usbstick,bootindex=0 \
        >"$d/qemu.out" 2>&1 &
    local vm=$!
    reap_add "$vm"
    local w=0
    while kill -0 "$vm" 2>/dev/null && [ "$w" -lt 300 ]; do
        grep -aq "$waitfor" "$d/serial.log" 2>/dev/null && break
        sleep 2; w=$((w+2))
    done
    BOOT_WAITED="$w"
    # Long enough for at least two of bootlogd's two-second snapshots after the
    # marker, so a failure below is about persistence and not about timing.
    sleep 6
    # THE POWER CUT. No SIGTERM first, no shutdown, no sync -- SIGKILL to QEMU
    # is what the owner's thumb on the power button is.
    kill -KILL "$vm" 2>/dev/null
    wait "$vm" 2>/dev/null
    [ -s "$d/serial.log" ] || { bad "$name: EMPTY SERIAL LOG -- the VM never ran"; return 1; }
    return 0
}

# ---------------------------------------------------------------------------
say "STEP 1 -- boot the stick, then CUT THE POWER while it is running"
# ---------------------------------------------------------------------------
boot_and_cut cut "$WORK/medium.img" || exit 1
A="$WORK/cut"
info "the shell's marker appeared after ~${BOOT_WAITED}s"

grep -aq 'root filesystem online' "$A/serial.log" \
    && ok "the root switch happened, so the rc under test is the DISK's" \
    || bad "no root switch -- this boot ran from RAM and its rc is not the one under test"
grep -aq 'printk.devkmsg=on — the boot log records every console line' "$A/serial.log" \
    && ok "PID 1 READ THE SETTING BACK and confirms the log is not rate limited" \
    || bad "PID 1 did not confirm printk_devkmsg=on -- this kernel may be dropping log records"
grep -aq "$MARK" "$A/serial.log" \
    && ok "the boot reached the end of the rc (the marker is on the serial port)" \
    || bad "the boot never reached the end of the rc"
grep -aq 'esp: the boot medium' "$A/serial.log" \
    && ok "the ESP was resolved by its UEFI type GUID on the disk carrying the root" \
    || info "no esp: resolution line on the serial port (it is a <7> kmsg line, not always printed)"
grep -aq 'THIS BOOT IS BEING LOGGED TO THE STICK' "$A/serial.log" \
    && ok "the console TELLS THE PERSON where the log is, at the end, where a photograph would catch it" \
    || bad "nothing on the console says a log was written, so nobody would go looking for it"

# ---------------------------------------------------------------------------
say "STEP 2 -- THE KEYSTONE: read the log back off the powered-off image"
# ---------------------------------------------------------------------------
# The guest is dead. Everything from here is host-side bytes off the disk.
if ! recover_log "$A/medium.img" "$A/recovered.log"; then
    bad "could not mcopy \\HAMNIX.LOG off the ESP of the power-cut image"
    exit 1
fi
ok "\\HAMNIX.LOG is still on the FAT partition of an image that was killed at the wall"
REC_BYTES=$(stat -c%s "$A/recovered.log")
info "recovered $REC_BYTES bytes"

[ "$REC_BYTES" = 262144 ] \
    && ok "it is still exactly 262144 bytes -- the file was overwritten in place, never extended" \
    || bad "the file is now $REC_BYTES bytes: something extended or truncated it, which is what the whole no-metadata-write argument rests on"

NONZERO=$(tr -d '\0' < "$A/recovered.log" | wc -c)
[ "$NONZERO" -gt 0 ] \
    && ok "the file is not all-NUL ($NONZERO non-NUL bytes)" \
    || bad "the file is entirely NUL -- nothing reached the medium"

grep -aq "$SEED_SENTINEL" "$A/recovered.log" \
    && bad "the build-time sentinel is STILL THERE: this boot never wrote the log, and the earlier readback proves the file itself is reachable" \
    || ok "the build-time sentinel is GONE -- this boot really wrote over it"

grep -aq '==== HAMNIX BOOT LOG ====' "$A/recovered.log" \
    && ok "the log carries bootlogd's own header" \
    || bad "no bootlogd header in the recovered file"
grep -aq 'END OF HAMNIX BOOT LOG' "$A/recovered.log" \
    && ok "the log carries its terminator, so a reader can tell where this boot's text stops" \
    || bad "no terminator -- a reader cannot tell this boot's text from a previous one's"

# THE KERNEL'S HALF.
grep -aqE 'usb-storage|Linux version|SCSI disk' "$A/recovered.log" \
    && ok "THE KERNEL'S half of the boot survived the power cut, on the stick" \
    || bad "no kernel boot lines in the recovered log"

# THE SHELL'S HALF -- the half that was invisible on the laptop, and the entire
# reason a plain dmesg dump would not have been enough.
grep -aq "$MARK" "$A/recovered.log" \
    && ok "THE SHELL'S MARKER SURVIVED THE POWER CUT AND IS ON THE STICK -- this is the whole point" \
    || bad "the shell's marker is NOT in the recovered log: the log captures the kernel only, which is the half that was never missing"
grep -aq 'cons: rc.boot' "$A/recovered.log" \
    && ok "rc.boot's own lines are in the log, tagged 'cons:' so a reader can tell program output from kernel output" \
    || bad "rc.boot's lines are not in the recovered log"
grep -aq 'cons: linuxinit' "$A/recovered.log" \
    && ok "PID 1's lines are in the log too" \
    || bad "PID 1's lines are not in the recovered log"

# EARLY AS WELL AS LATE. Starting the logger part-way through the boot must not
# cost the beginning of it -- the ring already held it.
if grep -aqE 'cons: linuxinit: Hamnix on Linux' "$A/recovered.log"; then
    ok "the log reaches back to PID 1's FIRST line, although bootlogd started long after it"
else
    bad "the log starts part-way through: the ring snapshot is not capturing the beginning of the boot"
fi

# ---------------------------------------------------------------------------
say "STEP 3 -- THE FAILURE PATH: a medium whose log file has been removed"
# ---------------------------------------------------------------------------
# The rule this proves: if the log target is missing or unwritable, THE BOOT
# MUST CONTINUE -- say so on screen and carry on.
cp "$WORK/medium.img" "$WORK/nolog.img"
mdel -i "${WORK}/nolog.img@@${ESP_OFF}" "::/HAMNIX.LOG" 2>/dev/null
if recover_log "$WORK/nolog.img" "$WORK/gone.log"; then
    bad "the log file is still on the ESP after mdel -- the failure path is not being tested"
else
    ok "the log file has been deleted from the ESP (the failure path is real)"
fi

if boot_and_cut nolog "$WORK/nolog.img"; then
    B="$WORK/nolog"
    grep -aq "$MARK" "$B/serial.log" \
        && ok "THE BOOT STILL COMPLETED with no log file on the medium" \
        || bad "the boot did not reach the end of the rc when the log file was missing -- logging can stop a boot"
    grep -aq 'NO BOOT LOG' "$B/serial.log" \
        && ok "and it SAID SO, by name, on the console" \
        || bad "the boot said nothing about the missing log -- a silent degradation"
    grep -aq 'No such file' "$B/serial.log" \
        && ok "with the reason the kernel gave, not a guess" \
        || info "no errno text alongside the refusal"
    grep -aq 'root filesystem online' "$B/serial.log" \
        && ok "and the root still came up, so the failure was confined to the log" \
        || bad "the root did not come up on the no-log boot"
fi

printf '\n%d PASSED, %d FAILED\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
