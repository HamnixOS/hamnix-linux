#!/usr/bin/env bash
#
# REGISTRATION, 2026-08-17. Until this date scripts/test_gate_registration.sh
# globbed only scripts/test_*.sh, so this directory was invisible to the gate
# against unregistered gates and every file in it read as coverage without
# being coverage. This gate is ON-DEMAND: not in ci_battery_manifest.txt
# because it boots a machine through `scripts/hamlinux_vm.sh`.
#
# tests/linux/reboot_device.sh — /dev/reboot: an installed machine that can be
# turned off, and files that are still there afterwards.
#
# THE FAULT THIS EXISTS FOR, measured by tests/linux/installed_update.sh and
# written down in docs/linux_installed_update.md §2c:
#
#   [iupd] p1 can this machine restart itself?
#   reboot: requested reboot
#   reboot: cannot open /dev/reboot
#   [iupd] p1 reboot status: 1
#
# /dev/reboot is a Hamnix KERNEL device. Nothing on this line served the name,
# so `reboot`, `poweroff`, `halt` and hamsh's `init 0` / `init 6` all died on
# the open. Two consequences, and the second is the worse one:
#
#   * a machine somebody installed had no supported way to stop, and
#   * NOTHING FLUSHED THE FILESYSTEMS on the way down. Every restart of an
#     installed hamnix-linux to date was the equivalent of pulling the plug.
#     The update gate survived only because ext4 has a journal, and it worked
#     around the gap by idling 30 s after its last write so the journal could
#     commit -- not something a user can be asked to do.
#
# WHAT IS ACTUALLY MEASURED, in order:
#
#   live boot   the device's PROTOCOL, ported from Hamnix's DEV_REBOOT cdev:
#               reads are EOF (a stray `cat` does not wedge), an unknown verb
#               is accepted and ignored, and /dev/rebootx is not claimed by an
#               accidental prefix match. Then the machine drops to uid 1001
#               and asks for a shutdown -- see WHO MAY DO THIS below.
#   disk boot 1 an INSTALLED disk writes a stamp to its ext4 root and calls
#               `reboot` IMMEDIATELY -- no sleep, nothing given time to
#               settle. The kernel says "Restarting system" and QEMU exits.
#   disk boot 2 the same disk, nothing rebuilt: the stamp is there, and the
#               boot script the first boot wrote is the one running. Then
#               `poweroff`, and the kernel says "Power down".
#
# WHY THE MISSING SLEEP IS THE ASSERTION. sync(2) before reboot(2) is the
# whole point of the device. Boot 1 writes to /etc and resets the machine in
# the same breath; if the flush were not happening the bytes would still be in
# the page cache when the CPU was reset, and boot 2 would run the OLD rc and
# find no stamp. That boot 2 runs the rc boot 1 wrote is itself the proof --
# it cannot be faked by a check that only greps for a success line.
#
# WHY `halt` IS NOT DRIVEN AS ROOT. It is the one verb that works by NOT
# stopping the machine: RB_HALT_SYSTEM parks the CPU with the power on, so
# QEMU would sit there until the host timeout fired and the run would cost its
# whole budget to prove something the uid-1001 arm already proves (the verb is
# recognised and reaches the action). Driving it would be slower and say less.
#
# WHO MAY DO THIS. reboot(2) needs CAP_SYS_BOOT, and user/linux-syscalls.c is
# linked into every Adder program, so the call happens as whoever wrote to the
# device. That is a real difference from Hamnix, where the cdev is ungated. It
# is checked here from uid 1001 and the requirement is that it FAILS BY NAME
# and the machine survives -- never a dialog that dismisses itself having done
# nothing, which is the shape commit bc9b75d8 fixed in the power menu.
#
# Usage: tests/linux/reboot_device.sh [live-seconds] [disk-seconds]
#   HAMLINUX_RB_REUSE=1   reuse an already-built disk image
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

export HAMLINUX_VNC="${HAMLINUX_VNC:-none}"
# Several agents may be booting VMs against the same distro media at once, and
# this test only ever reads it.
export HAMLINUX_DISTRO_RO="${HAMLINUX_DISTRO_RO:-1}"
# QEMU's snapshot overlay lands in TMPDIR, and /tmp on the dev box is a 16 GB
# tmpfs -- i.e. the owner's RAM. Keep it on real disk.
export TMPDIR="${TMPDIR:-$PROJ_ROOT/build/tmp}"
mkdir -p "$TMPDIR"

WAIT_LIVE="${1:-180}"
WAIT_DISK="${2:-240}"
WORK=build/rebootdev; mkdir -p "$WORK"
IMG=build/image
DISK="$IMG/rebootdev.img"
STAMP="rbstamp-$$-$(date +%s)"

fail=0
say() { echo "[rbdev] $*"; }

# =========================================================================
# 1. The live boot: the protocol, and the unprivileged ask.
# =========================================================================
# NOTE ON REDIRECTS. tests/linux/installed_update.sh records that a redirect
# whose SOURCE is the running rc wedges the shell dead (pid 1 is reading the
# very file being opened). Nothing here redirects from /etc/rc.boot; the only
# redirect target is /dev/reboot itself, which is a device and not a file the
# shell is reading.
#
# THE REAL BOOT RC IS PREPENDED, NOT SOURCED. etc/rc.boot.linux is staged into
# the image AS /etc/rc.boot and under no other name, so `source
# '/etc/rc.boot.linux'` inside the guest is "source: cannot open file" -- and
# because HAMLINUX_RC REPLACES that one file, sourcing the name this test
# stages would be a loop. Concatenating is also the more honest test: the
# probe then runs on a machine that booted normally, with the compositor and
# the desktop up, which is the state somebody is in when they reach for the
# power menu.
cat etc/rc.boot.linux > "$WORK/rc.live"
cat >> "$WORK/rc.live" <<'RC'

echo '[rbdev] ===== LIVE: the /dev/reboot protocol'

# A READ IS EOF, NOT A WEDGE. Hamnix's _devtab_read answers 0 for this device
# precisely so a stray `cat` terminates. If the port got this wrong the boot
# would stop here and every later marker would be missing.
echo '[rbdev] live cat /dev/reboot (must terminate, no output):'
cat /dev/reboot
echo '[rbdev] live cat status:' $status
echo '[rbdev] live STILL HERE after the cat'

# AN UNKNOWN VERB IS ACCEPTED AND IGNORED, which is what the Hamnix cdev does
# so a stray writer cannot wedge on it. The machine must be running afterwards.
echo frobnicate > /dev/reboot
echo '[rbdev] live unknown-verb status:' $status
echo '[rbdev] live STILL HERE after an unknown verb'

# NO ACCIDENTAL PREFIX MATCH. /dev/rebootx is not this device, and under /dev
# a write-open must not CREATE a file either (the note in sys_open_write).
echo x > /dev/rebootx
echo '[rbdev] live rebootx status:' $status

# ---- and now as the person at the desktop -------------------------------
# setuid is a one-way privilege DROP, so this is last: nothing after it can
# climb back. Each of the three verbs must be REFUSED and must leave the
# machine running -- the marker after each one is what says so.
echo '[rbdev] live --- dropping to uid 1001, the session user'
setuid 1001
id
echo '[rbdev] u1001 poweroff:'
poweroff
echo '[rbdev] u1001 poweroff status:' $status
echo '[rbdev] u1001 STILL HERE after poweroff'
echo '[rbdev] u1001 reboot:'
reboot
echo '[rbdev] u1001 reboot status:' $status
echo '[rbdev] u1001 STILL HERE after reboot'
echo '[rbdev] u1001 halt:'
halt
echo '[rbdev] u1001 halt status:' $status
echo '[rbdev] u1001 STILL HERE after halt'
echo '[rbdev] LIVE DONE'
RC

say "staging a live image with the protocol rc"
HAMLINUX_RC="$WORK/rc.live" scripts/hamlinux_image.sh >"$WORK/live-build.log" 2>&1 || {
    echo "FAIL live image build"; tail -20 "$WORK/live-build.log"; exit 1; }

say "live boot (up to ${WAIT_LIVE}s)"
# STDIN CLOSES EARLY, as installed_update.sh does it: hamsh IS pid 1 and falls
# through to reading the console when the rc ends, so an open stdin would hold
# the VM for the whole budget on every run. At EOF pid 1 exits, the kernel
# panics (panic=-1) and -no-reboot makes QEMU quit -- so the number below is a
# CEILING, not a duration.
( sleep 5 ) | timeout "$((WAIT_LIVE + 15))" \
    scripts/hamlinux_vm.sh script --timeout "$WAIT_LIVE" \
    >"$WORK/live.log" 2>&1

# =========================================================================
# 2. The installed disk: two boots, and the stamp that has to survive one.
# =========================================================================
cat > "$WORK/rc.disk1" <<RC
source '/etc/rc.boot.installed'

echo '[rbdev] ===== DISK BOOT 1: write, then reboot in the same breath'
date

# The stamp is minted by THIS host run and cannot pre-exist on the disk, so
# finding it on boot 2 means these exact bytes were flushed by the shutdown.
echo $STAMP > /etc/rbdev-stamp
echo '[rbdev] d1 wrote the stamp:'
cat /etc/rbdev-stamp
echo '[rbdev] d1 stamp status:' \$status

# Arm boot 2. This replaces the file pid 1 is executing, so it is done LAST,
# for the reason installed_update.sh records: rewriting it mid-script changes
# the bytes pid 1 is about to read. Nothing below reads from it.
cp /etc/rc.disk2 /etc/rc.boot
echo '[rbdev] d1 armed the next boot'

# AND NOW, IMMEDIATELY. No sleep, no settle, nothing given time to commit.
# Everything above is in the page cache; sync(2) inside /dev/reboot is the
# only thing that can put it on the platter before the CPU is reset.
echo '[rbdev] d1 rebooting NOW with nothing flushed but the device'
reboot
echo '[rbdev] d1 reboot status:' \$status
echo '[rbdev] d1 REBOOT DID NOT TAKE'
RC

cat > "$WORK/rc.disk2" <<RC
source '/etc/rc.boot.installed'

echo '[rbdev] ===== DISK BOOT 2: the same disk, nothing rebuilt'
date
echo '[rbdev] d2 the stamp written one instant before the reset:'
cat /etc/rbdev-stamp
echo '[rbdev] d2 stamp status:' \$status
echo '[rbdev] d2 DISK DONE'

# And the other end of the device: power the machine off for real. QEMU exits
# when the guest asks ACPI for S5, so "the host never had to take it away" is
# the observable.
echo '[rbdev] d2 powering off'
poweroff
echo '[rbdev] d2 poweroff status:' \$status
echo '[rbdev] d2 POWEROFF DID NOT TAKE'
RC

if [ -n "${HAMLINUX_RB_REUSE:-}" ] && [ -f "$DISK" ]; then
    say "reusing $DISK"
else
    say "building an installed disk (boot-1 rc, boot-2 rc staged alongside)"
    EXTRA="$WORK/extra"; rm -rf "$EXTRA"; mkdir -p "$EXTRA/etc"
    cp "$WORK/rc.disk2" "$EXTRA/etc/rc.disk2"
    HAMLINUX_DISK_RC="$WORK/rc.disk1" HAMLINUX_DISK_EXTRA="$EXTRA" \
        scripts/hamlinux_disk.sh "$DISK" 3G >"$WORK/disk-build.log" 2>&1 || {
        echo "FAIL disk build"; tail -20 "$WORK/disk-build.log"; exit 1; }
fi

bootdisk() {   # bootdisk <logfile> <seconds>
    # STDIN CLOSES EARLY. If the rc falls through instead of rebooting, hamsh
    # (which IS pid 1) would sit reading the console until the host timeout;
    # at EOF it exits, the kernel panics and -no-reboot makes QEMU quit. So
    # the budget is a CEILING and a working reboot is much faster than it --
    # which is also how ELAPSED below tells the two apart.
    ( sleep 5 ) | HAMLINUX_DISK="$DISK" \
        timeout "$(($2 + 15))" scripts/hamlinux_vm.sh disk --timeout "$2" \
        >"$1" 2>&1
}

say "disk boot 1 of 2: write + reboot (up to ${WAIT_DISK}s)"
T0=$SECONDS; bootdisk "$WORK/disk1.log" "$WAIT_DISK"; ELAPSED1=$((SECONDS - T0))
say "disk boot 2 of 2: the stamp + poweroff (up to ${WAIT_DISK}s)"
T0=$SECONDS; bootdisk "$WORK/disk2.log" "$WAIT_DISK"; ELAPSED2=$((SECONDS - T0))

echo
grep -aE '^\[rbdev\]|^rc\.boot:|^reboot: ' "$WORK/live.log"  || echo "(no live output)"
echo
grep -aE '^\[rbdev\]|^rc\.boot:|^reboot: ' "$WORK/disk1.log" || echo "(no disk-1 output)"
echo
grep -aE '^\[rbdev\]|^rc\.boot:|^reboot: ' "$WORK/disk2.log" || echo "(no disk-2 output)"
echo

# =========================================================================
# 3. The questions.
# =========================================================================
LOG=""
check() {   # check <name> <regex>
    if grep -aqE "$2" "$LOG"; then echo "rbdev: PASS $1"
    else echo "rbdev: FAIL $1   (no line matching /$2/ in $LOG)"; fail=1; fi
}
nocheck() { # nocheck <name> <regex-that-must-NOT-appear>
    if grep -aqE "$2" "$LOG"; then
        echo "rbdev: FAIL $1   (found /$2/ in $LOG)"; fail=1
    else echo "rbdev: PASS $1"; fi
}
# THE LINE AFTER THE BANNER IS THE ANSWER. A bare `status: 0` is not one --
# every failure this tree has paid for was success-shaped.
after() {   # after <name> <banner> <regex>
    got="$(grep -aA5 -F "$2" "$LOG" | tail -n +2 | tr -d '\r')"
    if printf '%s\n' "$got" | grep -qE "$3"; then
        echo "rbdev: PASS $1  -> '$(printf '%s\n' "$got" | grep -E "$3" | head -1)'"
    else
        echo "rbdev: FAIL $1  (nothing matching /$3/ after '$2'; got: $(printf '%s' "$got" | tr '\n' '|'))"
        fail=1
    fi
}

echo "--- the live boot: the ported protocol"
LOG="$WORK/live.log"
check "the live image booted"                       'rc\.boot: hamnix-linux'
check "a read of /dev/reboot terminates (EOF, not a wedge)" '\[rbdev\] live cat status: 0'
check "  ... and the machine is still running after it"    '\[rbdev\] live STILL HERE after the cat'
check "an unknown verb is accepted and ignored"     '\[rbdev\] live unknown-verb status: 0'
check "  ... and the machine is still running after it"    '\[rbdev\] live STILL HERE after an unknown verb'
# /dev/rebootx must NOT be claimed, and must not be created either: under /dev
# sys_open_write drops O_CREAT, so this is a non-zero status.
nocheck "/dev/rebootx is not claimed by a prefix match" '\[rbdev\] live rebootx status: 0'

echo
echo "--- the live boot, as the desktop user (uid 1001)"
after "the session really is uid 1001"              '[rbdev] live --- dropping to uid 1001' 'uid=1001'
# THE POINT OF THIS ARM. reboot(2) needs CAP_SYS_BOOT. The refusal must be
# LOUD -- the client's own "did not take" line and a non-zero status -- and
# the machine must still be running afterwards.
check "uid 1001 is refused a poweroff, by name"     'poweroff: power off did not take'
check "uid 1001's poweroff exits non-zero"          '\[rbdev\] u1001 poweroff status: 1'
check "  ... and the machine is still running"      '\[rbdev\] u1001 STILL HERE after poweroff'
check "uid 1001 is refused a reboot, by name"       'reboot: reboot did not take'
check "uid 1001's reboot exits non-zero"            '\[rbdev\] u1001 reboot status: 1'
check "  ... and the machine is still running"      '\[rbdev\] u1001 STILL HERE after reboot'
check "uid 1001 is refused a halt, by name"         'halt: halt did not take'
check "uid 1001's halt exits non-zero"              '\[rbdev\] u1001 halt status: 1'
check "  ... and the machine is still running"      '\[rbdev\] u1001 STILL HERE after halt'
# The device EXISTS for the unprivileged user -- the open succeeds and the
# refusal comes from the power action, not from a missing name. That is the
# difference between "this line has no /dev/reboot" and "you may not do this".
nocheck "the refusal is NOT the old 'cannot open' fault" 'cannot open /dev/reboot'
check "the live arm reached the end"                '\[rbdev\] LIVE DONE'

echo
echo "--- disk boot 1: an installed machine restarts itself"
LOG="$WORK/disk1.log"
check "the installed root came online"              'rc\.boot: hamnix-linux \(installed\)'
after "the stamp was written to the ext4 root"      '[rbdev] d1 wrote the stamp:' "$STAMP"
check "the next boot was armed"                     '\[rbdev\] d1 armed the next boot'
check "the machine asked to restart"                '\[rbdev\] d1 rebooting NOW'
# THE KERNEL'S OWN LINE. This is what separates "reboot(2) was reached" from
# "pid 1 died and the kernel panicked" -- with -no-reboot both make QEMU exit,
# so the exit alone proves nothing.
check "the kernel restarted the system"             'reboot: Restarting system'
nocheck "pid 1 did not simply die instead"          'Kernel panic'
nocheck "the reboot was not a no-op"                '\[rbdev\] d1 REBOOT DID NOT TAKE'
nocheck "and it was not the old open failure"       'cannot open /dev/reboot'
if [ "$ELAPSED1" -lt "$WAIT_DISK" ]; then
    echo "rbdev: PASS the machine stopped on its own, well inside the budget (${ELAPSED1}s of ${WAIT_DISK}s)"
else
    echo "rbdev: FAIL the host timeout took the VM away (${ELAPSED1}s = the whole ${WAIT_DISK}s budget)"; fail=1
fi

echo
echo "--- disk boot 2: what survived a reboot with nothing flushed but sync(2)"
LOG="$WORK/disk2.log"
check "the machine booted again"                    'rc\.boot: hamnix-linux \(installed\)'
# THE DURABILITY ASSERTION. Boot 1 wrote /etc/rc.boot and reset the machine in
# the same breath. That boot 2 is running THAT rc is the proof the write was
# flushed -- there is no success line to fake it with.
check "it is running the rc boot 1 wrote one instant before the reset" 'DISK BOOT 2: the same disk'
after "the stamp survived the reboot"               '[rbdev] d2 the stamp' "$STAMP"
check "the stamp read exited 0"                     '\[rbdev\] d2 stamp status: 0'
check "boot 2 reached the end"                      '\[rbdev\] d2 DISK DONE'
check "the machine asked to power off"              '\[rbdev\] d2 powering off'
check "the kernel powered the machine down"         'reboot: Power down'
nocheck "the poweroff was not a no-op"              '\[rbdev\] d2 POWEROFF DID NOT TAKE'
nocheck "pid 1 did not simply die instead"          'Kernel panic'
if [ "$ELAPSED2" -lt "$WAIT_DISK" ]; then
    echo "rbdev: PASS QEMU exited because the GUEST powered off (${ELAPSED2}s of ${WAIT_DISK}s)"
else
    echo "rbdev: FAIL the host timeout took the VM away (${ELAPSED2}s = the whole ${WAIT_DISK}s budget)"; fail=1
fi

echo
echo "(logs: $WORK/live.log $WORK/disk1.log $WORK/disk2.log; stamp: $STAMP)"
exit $fail
