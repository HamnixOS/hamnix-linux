#!/usr/bin/env bash
#
# REGISTRATION. ON-DEMAND. Not in ci_battery_manifest.txt because it builds a
# medium, installs a machine onto a blank 6 GiB disk and boots it under OVMF --
# one image build and two QEMU boots, far past the battery's per-shard budget.
# It IS registered in scripts/release_gates.sh (`installed_uid_console|yes|0|23`).
#
# THIS ANNOTATION IS A REPAIR, NOT DECORATION. scripts/test_gate_registration.sh
# does not read scripts/release_gates.sh at all -- it counts a gate as covered
# only if a workflow or ci_battery_manifest.txt names it, or if its own header
# carries this rationale in the first 80 lines. Without it this file was in the
# checker's DARK set from the commit that added it, and that checker was
# therefore RED on port/tier1-syscalls at 61590f23. HANDOFF.md records the
# opposite ("STRUCK ... It PASSES"), measured before this gate existed.
# tests/linux/installed_uid_console.sh — A PROGRAM STARTED AS THE PERSON COULD
# NOT BE HEARD, AND THE RELEASE DREW A CONCLUSION FROM THE SILENCE.
#
# WHAT THIS IS ABOUT
# ==================
# Commit 416248df reverted the desktop chrome's privilege drop on the strength
# of one measurement: "THE APPLICATION NEVER OPENS A WINDOW AS uid 1001",
# tests/linux/installed_documents.sh 18/6 against 48/0, all three office
# applications failing the same assertion -- `the application never printed
# "[<app>] scene window ready"`. HANDOFF.md carries the same finding with a
# different explanation (rc.de-user, the namespace, the rfork warning).
#
# BOTH ARE WRONG, AND THIS FILE IS THE MEASUREMENT THAT SAYS SO. Booted on a
# real installed machine, 2026-08-19, with the application's stdout redirected
# to a FILE on the ext4 instead of the console: hamwrite, started as uid 1001,
# printed `[hamwrite] document /home/<user>/Documents/untitled.hdoc` and
# `[hamwrite] scene window ready`, took a new row in /dev/wsys, and was still
# alive in `ps` as the session user. IT OPENS A WINDOW. What it cannot do is be
# HEARD.
#
# THE MECHANISM, and every number here was read off a booted machine:
#
#   * the shipped kernel command line is
#     `console=ttyS0,115200 console=tty0`, and /dev/console follows the LAST
#     console=. So fd 1 of every program is THE SCREEN -- which the compositor
#     covers as soon as the desktop is up.
#   * the ONLY thing that puts a program's output on the serial line (which is
#     the whole of what a gate can read) is user/linux-syscalls.c:consmirror,
#     which OPENS /dev/ttyS0 itself, per process, after execve.
#   * /dev/ttyS0 was mode 0600 root. As uid 1001 that open is EACCES --
#     measured: `openttyS0=-13`, and `openkmsg=-13` with it.
#   * and NOTHING SAID SO. `write(1, ..., 26)` returned 26 at both uids. A
#     successful syscall is a fact about the kernel's bookkeeping, not about
#     the world.
#   * a hamsh BUILTIN in the dropped shell is still heard, which is what made
#     this look like a property of the application: the shell opened its
#     mirror while it was still root and the descriptor survives setuid(2).
#     execve does not survive it -- the fd is O_CLOEXEC -- so every EXEC'd
#     child after the drop starts mute.
#
# THE FIX UNDER TEST. user/linuxinit.ad chmods the serial console named on the
# kernel command line to 0622 at boot: any program may be HEARD, only root may
# LISTEN. user/linux-syscalls.c:consmirror_setup now also SAYS, once, on the
# console it can still reach, when that open is refused -- because a silent
# refusal is this tree's oldest recurring defect and it just cost a release.
#
# WHAT THIS GATE MEASURES
# =======================
#   1. INSTRUMENT. A root child's console line reaches the serial log. If this
#      fails nothing below means anything.
#   2. THE BOOT OPENS THE NODE. Read off the running machine: /dev/ttyS0 is
#      mode 0622 (402 decimal) before anything in this gate touches it, and
#      linuxinit says so by name. Only user/linuxinit.ad sets that mode; with
#      the call removed this assertion is the one that goes red.
#   3. THE FIX. A uid-1001 child's console line reaches the serial log.
#   4. CORROBORATION THAT DOES NOT GO THROUGH THE CONSOLE. That child also
#      wrote a report FILE onto the ext4, read here with debugfs and nothing
#      mounted, saying openttyS0 >= 0. So 3 is about a program that
#      demonstrably ran, not about a program that happened to print.
#   5. THE NEGATIVE CONTROL, IN THE SAME BOOT. The node is chmodded back to
#      0600 and the SAME program at the SAME uid goes mute again -- while its
#      report file still appears on the disk, so "mute" is distinguished from
#      "did not run". This is the arm that shows the instrument can go red and
#      that the MODE is what decides.
#   6. AND OPEN AGAIN. Mute, heard, mute, heard: a reader that never hears
#      anything cannot pass, and neither can one that hears everything.
#   7. THE WINDOW. hamwrite, launched as uid 1001, prints `scene window ready`
#      ON THE SERIAL LINE, and `ps` on the machine shows it running as the
#      session user. That is the assertion commit 416248df could not make.
#
# WHAT IT DOES NOT ESTABLISH, said plainly:
#   * It does NOT rebuild the medium with the linuxinit change reverted. The
#     red arm for the FIX is assertion 2 (the mode on a booted machine) plus
#     the in-boot pair at 5/6; a full reverted-image arm is another medium
#     build and was not run.
#   * It does NOT show a document being SAVED by a uid-1001 application, and
#     it does not click an icon. That is installed_documents.sh's job.
#   * It says nothing about /dev/kmsg, which stays root-only: a dropped
#     session's lines are still missing from HAMNIX.LOG on the stick.
#   * It stages an instrument onto the installed disk with debugfs (the probe
#     and /etc/rc.boot). The SUBJECT -- linuxinit, the runtime, the mode -- is
#     the one the image build produced.
#
# Usage: tests/linux/installed_uid_console.sh
#   UIDCONS_WORK=<dir>   work dir (default ~/.hamnix-build/uidcons)
#   UIDCONS_REUSE=1      reuse an already-built medium and installed disk
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

. tests/linux/reap.sh
reap_on_exit

W="${UIDCONS_WORK:-$HOME/.hamnix-build/uidcons}"
mkdir -p "$W"
export TMPDIR="$W/tmp"; mkdir -p "$TMPDIR"

LIVE="$W/live-usb.img"
NVME="$W/target-nvme.img"
PART="$W/part.img"
USERNAME=uidconsusr
HOSTNAME_=uidconsbox
UPASS=uidconspw
RPASS=uidconsadmin

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  PASS  $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL  $*"; }
info() { echo "        $*"; }
say()  { echo; echo "== $* =="; }
finish() { printf '\n%d PASSED, %d FAILED\n' "$PASS" "$FAIL"
           [ "$FAIL" = 0 ] && exit 0 || exit 1; }

for t in qemu-system-x86_64 python3; do
    command -v "$t" >/dev/null || { echo "INCONCLUSIVE: need $t"; exit 2; }
done
for t in /sbin/debugfs /sbin/sfdisk /sbin/e2fsck; do
    [ -x "$t" ] || { echo "INCONCLUSIVE: need $t"; exit 2; }
done
[ -f /usr/share/OVMF/OVMF_CODE_4M.fd ] || { echo "INCONCLUSIVE: need OVMF"; exit 2; }

# ---- reading (and writing) an ext4 without mounting it -------------------
part_geom() {
    /sbin/sfdisk -J "$1" 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)["partitiontable"]
ss=d.get("sectorsize",512)
p=d["partitions"][int(sys.argv[1])-1]
print(p["start"]*ss, p["size"]*ss)' "$2"
}
PART_OFF=0
carve() {
    local g off sz
    g="$(part_geom "$1" "$2")" || return 1
    [ -n "$g" ] || return 1
    off="${g% *}"; sz="${g#* }"
    [ $((off % 1048576)) -eq 0 ] || { echo "partition $2 does not start on a MiB"; return 1; }
    PART_OFF=$((off / 1048576))
    rm -f "$PART"
    dd if="$1" of="$PART" bs=1M skip="$PART_OFF" \
       count=$(( (sz + 1048575) / 1048576 )) status=none
}
# Put the carved partition back where it came from. Only ever used on this
# gate's own copy of its own disk image; never on a device.
paste_back() { dd if="$PART" of="$1" bs=1M seek="$PART_OFF" conv=notrunc status=none; }
fs_has()  { /sbin/debugfs -R "stat $2" "$1" 2>/dev/null | grep -q '^Inode:'; }
fs_cat()  { /sbin/debugfs -R "cat $2" "$1" 2>/dev/null; }

# =========================================================================
say "0 -- the medium, and one install onto a blank virtual disk"

cat >"$W/rc.install" <<RCEOF
ln -s /dev/console /dev/cons
echo 'UIDCONS-LIVE: the medium booted'
install --auto /dev/nvme0n1 --hostname $HOSTNAME_ --user $USERNAME --user-pass $UPASS --root-pass $RPASS
echo 'UIDCONS-LIVE-DONE'
sleep 8
poweroff
RCEOF

if [ "${UIDCONS_REUSE:-0}" = 1 ] && [ -s "$LIVE" ] && [ -s "$NVME" ]; then
    info "reusing $LIVE and $NVME (UIDCONS_REUSE=1)"
else
    info "building the medium (this is the slow part)"
    scripts/hamlinux_image.sh >"$W/img1.log" 2>&1 || {
        bad "lean image build -- see $W/img1.log"; finish; }
    # The seed disk is what writes /boot/root.partuuid; without it the
    # installer refuses to partition and still returns. See
    # tests/linux/installed_documents.sh, which learned that the hard way.
    scripts/hamlinux_disk.sh "$W/seed.img" 3G >"$W/disk1.log" 2>&1 || {
        bad "seed disk build -- see $W/disk1.log"; finish; }
    HAMLINUX_INSTALLER=1 scripts/hamlinux_image.sh >"$W/img2.log" 2>&1 || {
        bad "installer image build -- see $W/img2.log"; finish; }
    HAMLINUX_DISK_RC="$W/rc.install" \
        scripts/hamlinux_disk.sh "$LIVE" 4G >"$W/disk2.log" 2>&1 || {
        bad "live medium build -- see $W/disk2.log"; finish; }
    rm -f "$NVME"; truncate -s 6G "$NVME"

    d="$W/install"; rm -rf "$d"; mkdir -p "$d"
    cp /usr/share/OVMF/OVMF_VARS_4M.fd "$d/OVMF_VARS.fd"
    qemu-system-x86_64 \
        -m 2048 -smp 2 -no-reboot \
        -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
        -drive "if=pflash,format=raw,unit=1,file=$d/OVMF_VARS.fd" \
        -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
        -display none -vga none -device virtio-gpu-pci \
        -serial "file:$d/serial.log" -enable-kvm -cpu host \
        -device qemu-xhci,id=xhci -device usb-kbd -device usb-tablet \
        -drive "file=$NVME,if=none,format=raw,id=nvme0" \
        -device nvme,drive=nvme0,serial=UIDCONSTGT \
        -drive "file=$LIVE,if=none,format=raw,id=usbstick" \
        -device usb-storage,bus=xhci.0,drive=usbstick,bootindex=0 \
        >"$d/qemu.out" 2>&1 &
    IPID=$!
    reap_add "$IPID"
    i=0
    while kill -0 "$IPID" 2>/dev/null && [ "$i" -lt 900 ]; do sleep 5; i=$((i+5)); done
    kill -TERM "$IPID" 2>/dev/null; sleep 2; kill -KILL "$IPID" 2>/dev/null
    wait "$IPID" 2>/dev/null
fi

if grep -aq 'UIDCONS-LIVE-DONE' "$W/install/serial.log" 2>/dev/null; then
    ok "the install boot ran to completion on the live medium"
else
    bad "the install boot never printed UIDCONS-LIVE-DONE -- nothing below is about an installed machine"
    tail -20 "$W/install/serial.log" 2>/dev/null | sed 's/^/        /'
    finish
fi
if grep -aq '^install complete' "$W/install/serial.log"; then
    ok "and the installer reported 'install complete'"
else
    bad "the installer did NOT report 'install complete': $(grep -a '^hlinstall: ' "$W/install/serial.log" | head -2 | tr '\n' ' ' | cut -c1-200)"
    finish
fi

# =========================================================================
say "1 -- staging the instrument onto the installed disk"
# The probe and the machine's rc.boot go on with debugfs, nothing mounted.
# e2fsck AFTERWARDS IS NOT OPTIONAL AND IS NOT HYGIENE: measured on the first
# run of this harness, debugfs's allocation leaves bg 0's block bitmap
# checksum wrong, the kernel finds it at ext4lazyinit, the filesystem goes to
# error state and EVERY WRITE ON THE MACHINE FAILS SILENTLY. The boot looked
# perfect and produced no files at all. e2fsck BEFOREHAND too: on a freshly
# copied image with a dirty journal the first debugfs write of a large file
# silently does nothing.
PROBE="$W/uidwin_probe"
scripts/hamlinux_build.sh tests/linux/uidwin_probe.ad "$PROBE" \
    >"$W/probe.build.log" 2>&1 || {
    bad "the probe did not build -- see $W/probe.build.log"; finish; }
ok "the probe builds"

cat >"$W/rc.machine" <<RCEOF
# /etc/rc.boot -- staged by tests/linux/installed_uid_console.sh
source '/etc/rc.boot.installed'
echo 'UIDCONS-START'
sleep 20
ucns = ns {
}
echo 'UIDCONS-PHASE-root'
a1 = spawn detached ucns {
    /bin/uidwin_probe /var/log/uidcons.root.txt
    echo 'UIDCONS-ROOT-END'
}
sleep 8
echo 'UIDCONS-PHASE-live'
a2 = spawn detached ucns {
    setuid 1001
    /bin/uidwin_probe /home/$USERNAME/uidcons.live.txt
    echo 'UIDCONS-LIVE-END'
}
sleep 8
echo 'UIDCONS-PHASE-shut'
/bin/uidwin_probe /var/log/uidcons.shut.txt /dev/ttyS0 0600
echo 'UIDCONS-SHUT-DONE'
a3 = spawn detached ucns {
    setuid 1001
    /bin/uidwin_probe /home/$USERNAME/uidcons.mute.txt
    echo 'UIDCONS-MUTE-END'
}
sleep 8
echo 'UIDCONS-PHASE-reopen'
/bin/uidwin_probe /var/log/uidcons.reopen.txt /dev/ttyS0 0622
echo 'UIDCONS-REOPEN-DONE'
a4 = spawn detached ucns {
    setuid 1001
    /bin/uidwin_probe /home/$USERNAME/uidcons.again.txt
    echo 'UIDCONS-AGAIN-END'
}
sleep 8
echo 'UIDCONS-PHASE-window'
a5 = spawn detached ucns {
    setuid 1001
    /bin/hamwrite
}
sleep 30
cat /dev/wsys > /var/log/uidcons.win.txt 2>&1
ps > /var/log/uidcons.ps.txt 2>&1
echo 'UIDCONS-DONE'
sleep 5
poweroff > /dev/null
RCEOF

RUN="$W/run.img"
rm -f "$RUN"
cp --sparse=always "$NVME" "$RUN"
carve "$RUN" 2 || { bad "cannot carve the installed root partition"; finish; }
/sbin/e2fsck -fy "$PART" >"$W/fsck1.log" 2>&1
cat >"$W/dbg.cmds" <<EOF
cd /etc
rm rc.boot
write $W/rc.machine rc.boot
cd /bin
write $PROBE uidwin_probe
sif uidwin_probe mode 0100755
quit
EOF
/sbin/debugfs -w -f "$W/dbg.cmds" "$PART" >"$W/dbg.log" 2>&1
/sbin/e2fsck -fy "$PART" >"$W/fsck2.log" 2>&1
if fs_has "$PART" /bin/uidwin_probe && fs_cat "$PART" /etc/rc.boot | grep -q UIDCONS-PHASE-window; then
    ok "the probe and the machine's rc are on the installed disk"
else
    bad "staging failed -- see $W/dbg.log"; finish
fi
paste_back "$RUN"

# =========================================================================
say "2 -- one boot of the installed machine"
D="$W/boot"; rm -rf "$D"; mkdir -p "$D"
cp /usr/share/OVMF/OVMF_VARS_4M.fd "$D/OVMF_VARS.fd"
qemu-system-x86_64 \
    -m 2048 -smp 2 -no-reboot \
    -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
    -drive "if=pflash,format=raw,unit=1,file=$D/OVMF_VARS.fd" \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -display none -vga std \
    -serial "file:$D/serial.log" -enable-kvm -cpu host \
    -device virtio-keyboard-pci -device virtio-tablet-pci \
    -drive "file=$RUN,if=none,format=raw,id=nvme0" \
    -device nvme,drive=nvme0,serial=UIDCONSTGT \
    >"$D/qemu.out" 2>&1 &
QPID=$!
reap_add "$QPID"
i=0
while kill -0 "$QPID" 2>/dev/null && [ "$i" -lt 300 ]; do sleep 5; i=$((i+5)); done
kill -TERM "$QPID" 2>/dev/null; sleep 2; kill -KILL "$QPID" 2>/dev/null
wait "$QPID" 2>/dev/null
S="$D/serial.log"
if grep -aq 'UIDCONS-DONE' "$S"; then
    ok "the machine booted and ran every phase to the end"
else
    bad "the machine did not reach UIDCONS-DONE -- the phases below did not all run"
    tail -20 "$S" 2>/dev/null | sed 's/^/        /'
fi

# A marker printed BETWEEN two phase markers. This is what makes "heard" and
# "not heard" answerable per arm out of one log: awk from one marker to the
# next and count the probe's line inside that window only.
heard_between() {
    awk -v a="$1" -v b="$2" '
        index($0,a) {inw=1; next}
        index($0,b) {inw=0}
        inw && index($0,"UIDWIN-PROBE-CONSOLE-LINE") {n++}
        END {print n+0}' "$S"
}

say "3 -- the instrument, and the fix"
n="$(heard_between UIDCONS-PHASE-root UIDCONS-PHASE-live)"
if [ "${n:-0}" -ge 1 ]; then
    ok "a ROOT child's console line reaches the serial log ($n of them) -- the instrument is looking"
else
    bad "a root child was not heard either: this gate is not measuring what it thinks"
    finish
fi
n="$(heard_between UIDCONS-PHASE-live UIDCONS-PHASE-shut)"
if [ "${n:-0}" -ge 1 ]; then
    ok "THE FIX: a uid-1001 child's console line reaches the serial log ($n of them)"
else
    bad "a uid-1001 child was NOT heard: a program the desktop starts as the person still prints into nothing"
fi

say "4 -- the negative control, in this same boot"
n="$(heard_between UIDCONS-SHUT-DONE UIDCONS-PHASE-reopen)"
if [ "${n:-0}" = 0 ]; then
    ok "with /dev/ttyS0 back at 0600 the SAME program at the SAME uid is silent -- the mode is what decides"
else
    bad "the uid-1001 child was still heard with the node at 0600 ($n lines): this gate cannot go red, so its green means nothing"
fi
n="$(heard_between UIDCONS-REOPEN-DONE UIDCONS-PHASE-window)"
if [ "${n:-0}" -ge 1 ]; then
    ok "and opening the node again makes it audible again ($n lines): mute, heard, mute, heard"
else
    bad "re-opening the node did not restore audibility"
fi

say "5 -- what the machine wrote to its own disk, read with nothing mounted"
carve "$RUN" 2 || { bad "cannot carve the root partition after the boot"; finish; }
if fs_has "$PART" /etc/hamnix-release; then
    ok "the ext4 reader finds /etc/hamnix-release, so what it reports below is a reading"
else
    bad "the ext4 reader is not working"; finish
fi
if fs_has "$PART" /etc/there-is-no-such-file-as-this; then
    bad "the reader reports a file that cannot exist -- every absence below is meaningless"; finish
else
    ok "and it does NOT find a file that is certainly not there"
fi

R_ROOT="$(fs_cat "$PART" /var/log/uidcons.root.txt)"
R_LIVE="$(fs_cat "$PART" "/home/$USERNAME/uidcons.live.txt")"
R_MUTE="$(fs_cat "$PART" "/home/$USERNAME/uidcons.mute.txt")"
R_AGAIN="$(fs_cat "$PART" "/home/$USERNAME/uidcons.again.txt")"
for pair in "root:$R_ROOT" "live:$R_LIVE" "mute:$R_MUTE" "again:$R_AGAIN"; do
    t="${pair%%:*}"; v="${pair#*:}"
    if [ -n "$v" ]; then ok "the $t arm left a report on the disk: $(echo "$v" | head -1)"
    else bad "the $t arm left NO report: it did not run, and its console result says nothing"; fi
done

# THE MODE THE BOOT ITSELF LEFT, before this gate touched anything: 402 == 0622.
if echo "$R_ROOT" | grep -q 'ttyS0mode=402'; then
    ok "the SHIPPED boot leaves /dev/ttyS0 at mode 0622 -- user/linuxinit.ad is the only thing that sets it"
else
    bad "/dev/ttyS0 is $(echo "$R_ROOT" | sed -n 's/.*ttyS0mode=\([0-9]*\).*/\1/p') and not 402 (0622): the boot did not open the serial console to the session"
fi
if grep -aq 'is mode 0622' "$S"; then
    ok "and linuxinit says so by name on the console"
else
    bad "linuxinit printed no line about the serial console mode"
fi
if echo "$R_LIVE" | grep -qE 'openttyS0=[0-9]'; then
    ok "the uid-1001 arm could OPEN the serial console: $(echo "$R_LIVE" | sed -n 's/.*\(openttyS0=[-0-9]*\).*/\1/p')"
else
    bad "the uid-1001 arm was refused the serial console: $(echo "$R_LIVE" | sed -n 's/.*\(openttyS0=[-0-9]*\).*/\1/p')"
fi
if echo "$R_MUTE" | grep -q 'openttyS0=-13'; then
    ok "and in the 0600 arm it was refused EACCES -- which is why it was not heard, rather than not having run"
else
    bad "the 0600 arm was NOT refused: $(echo "$R_MUTE" | sed -n 's/.*\(openttyS0=[-0-9]*\).*/\1/p')"
fi
# The write that reports success and reaches nobody: the whole defect in one
# number, and it must stay TRUE in the mute arm, because the fix does not
# change it -- it only makes the bytes arrive somewhere.
if echo "$R_MUTE" | grep -q 'w1=26'; then
    ok "in the mute arm write(1) still returned the full 26 bytes: the program was told it had printed"
else
    bad "write(1) did not return 26 in the mute arm; this gate's account of the defect is wrong"
fi

say "6 -- and the application DOES open a window as uid 1001"
if awk '/UIDCONS-PHASE-window/{w=1} w && /\[hamwrite\] scene window ready/{f=1} END{exit !f}' "$S"; then
    ok "hamwrite, launched as uid 1001, printed '[hamwrite] scene window ready' ON THE SERIAL LINE"
else
    bad "hamwrite as uid 1001 did not print 'scene window ready' after the window phase began"
fi
PS="$(fs_cat "$PART" /var/log/uidcons.ps.txt)"
if echo "$PS" | grep -q "$USERNAME.*hamwrite"; then
    ok "and the machine's own ps shows hamwrite running as $USERNAME: $(echo "$PS" | grep "$USERNAME.*hamwrite" | head -1 | tr -s ' ')"
else
    bad "no hamwrite owned by $USERNAME in the machine's ps census"
fi
WIN="$(fs_cat "$PART" /var/log/uidcons.win.txt)"
if [ -n "$WIN" ]; then
    info "/dev/wsys after the uid-1001 launch: $(echo "$WIN" | tr '\n' ' ')"
    ok "the window table could be read after the uid-1001 launch"
else
    bad "the window table was not captured"
fi

finish
