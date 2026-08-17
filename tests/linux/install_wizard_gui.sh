#!/usr/bin/env bash
# tests/linux/install_wizard_gui.sh — THE GRAPHICAL INSTALL PATH HAD NEVER BEEN
# DRIVEN. THIS DRIVES IT, WITH TWO BLANK TARGET DISKS ATTACHED, AND READS THE
# SCREEN.
#
# WHY THIS FILE EXISTS
# ====================
# tests/linux/served_install_binary.sh measured the COMMAND LINE half of a
# defect that 255.one is serving right now: `hamnix-install-1.0.26.tar.gz`
# carries user/install.ad at bin/install, and that program talks to a `/dev/blk`
# file server the Linux lane does not have. Run by hand it FAILS LOUDLY --
# `[install] FAIL: partitioning returned non-zero`, status 1, nothing written to
# the target.
#
# The graphical half was left open, and with a specific reason to expect it to
# be worse. user/haminstallui.ad -- the DE's wizard, reachable from the app menu
# because hamnix-install ships etc/hamde/apps/installer.desktop -- reads "install
# complete" (:1126) and "FAIL" (:1128) off the child's stdout, so IF it reaches
# the spawn a person sees a failure page. The question is whether it reaches the
# spawn at all, because `_enumerate_disks` (:328-331) offers the person a target
# disk by listing ONE directory:
#
#     n: int64 = p9_listdir(cast[Ptr[char]]("/dev/blk"), &lsbuf[0], 4096)
#     if n < 0:
#         return
#
# -- the same `/dev/blk` that makes the command line fail. If that listdir
# fails, n_disks stays 0, and the person is somewhere nobody has ever looked.
#
# THE THREE OUTCOMES THAT WOULD CHANGE A PUBLISH DECISION, and they are what
# this gate is built to tell apart: the wizard reports SUCCESS (worst -- #464's
# shape), the wizard HANGS, or the wizard shows NOTHING. Against those, a page
# that says why it cannot continue is a good outcome. "It failed" is not an
# answer here; WHICH failure is the answer.
#
# WHAT IS READ OFF THE SOURCE, AND LABELLED AS THAT
# =================================================
# Three source facts are stated here because they predict the result, and every
# one of them is re-grepped by section P below so a later edit cannot leave this
# comment describing a tree that no longer exists:
#
#   1. `_enumerate_disks` has exactly ONE source of disks, `/dev/blk`. There is
#      no /dev scan, no /proc/partitions fallback, no sysfs.
#   2. `etc/rc.boot.installed` -- the rc a live medium and an installed disk both
#      boot -- binds `#esp`, `#distro`, `#c`, `#p`, `#s` and `#/`. IT DOES NOT
#      BIND `#b`. Only `etc/rc.boot` (the initramfs one) tries, at line 55, and
#      user/linux-syscalls.c:3576 answers that bind with "the /dev/blk file
#      server is not written yet".
#   3. AND THE WIZARD IS INCONSISTENT WITH THE INSTALLER IT SPAWNS.
#      user/hlinstall.ad:33 says in its own words that it avoids `/dev/blk`
#      because it "has no kernel to talk to here" -- so the program that DOES
#      work on this lane deliberately does not use the interface the wizard uses
#      to decide whether that program may run. That is a defect in the shipped
#      wizard independent of which bytes are at /bin/install.
#
# SO THIS GATE RUNS ON THE TREE'S OWN IMAGE, where /bin/install IS hlinstall --
# the CORRECT installer. If the wizard cannot offer a disk with the correct
# installer staged, the 1.0.26 mix-up never arises on the graphical path,
# because the graphical path never gets that far. That is a bigger finding than
# the one this gate was sent to check, and it is why the arm is configured this
# way rather than with the served tarball.
#
# WHAT IS MEASURED, AND WITH WHICH INSTRUMENT
# ===========================================
# P. THE PREMISES, re-grepped every run. A gate whose subject moved is a gate
#    reporting on a comment. Three greps, and each of them FAILS RED if the
#    source no longer says what the paragraph above says.
#
# A. THE TARGET DISKS ARE REALLY THERE. Two blank disks are attached on two
#    different buses -- NVMe (what is inside his laptop) and virtio-blk -- so
#    "no disk was offered" can never be blamed on the bus. QEMU's own
#    `info block` is asked, host-side, that both are attached; and the guest is
#    asked what it can see. WITHOUT THIS THE WHOLE RUN IS UNINTERPRETABLE: a
#    wizard that offers no disk on a machine with no disk is CORRECT.
#
# B. THE WIZARD STARTS, THROUGH THE MENU'S OWN LAUNCH PATH.
#    `echo '/bin/haminstallui' > /dev/wsys/appmenu/launch` is the queue the
#    Applications menu itself drains (user/linux-wsys.c:7872), so this is the
#    icon's path with the pointer taken out of it. The wizard prints
#    `[haminstallui] scene window ready` when its window is up (:1386), and that
#    string on the console is what starts the clock.
#
# C. WHAT THE PERSON SEES -- READ AS TEXT, NOT AS A HASH. `screendump` through
#    the QEMU monitor, cropped to the wizard's own window (it places itself at
#    180,70 at 440x470: haminstallui.ad:1352 `geometry 180 70`, WIN_W/WIN_H at
#    :629), upscaled, and put through tesseract. A frame hash can say the
#    picture changed; only the text can say whether the person was told
#    something true.
#
#    THE OCR IS PROVED BEFORE ANY OF ITS OUTPUT IS BELIEVED, in both
#    directions, because an OCR that returns nothing would otherwise read as
#    "the window was blank" -- which is one of the three outcomes this gate
#    exists to distinguish:
#      + POSITIVE: the step-1 frame must OCR to something containing "Step 1",
#        a string the source puts there unconditionally (:734).
#      - NEGATIVE: that same frame must NOT contain "Step 5 of 5". An OCR that
#        matched everything would pass every assertion below.
#
# D. THE KEYBOARD REALLY REACHES THE WIZARD, and this is the load-bearing
#    control for the whole gate. haminstallui.ad:1328 makes Return = Next and
#    :562 makes Tab = switch field, so the wizard is fully keyboard-drivable and
#    the hand fills in host name, user and both passwords and presses Return
#    four times. IF PAGE 1 -> 2 -> 3 -> 4 -> 5 IS OBSERVED IN THE OCR, then a
#    Return that is later refused on page 5 was REFUSED BY THE WIZARD and did
#    not merely fail to arrive. That is the difference between a finding and a
#    broken instrument, and it is measured inside the same run with the same
#    keystroke mechanism rather than argued.
#
# E. DID `/bin/install` EVER RUN? The guest prints `ps` every few seconds. The
#    same census is required to FIND `wsysd`, which is certainly running -- so a
#    census with no `install` line is a reading, not a `ps` that printed
#    nothing. (`pgrep -f` is not used anywhere here: it has matched its own
#    command line and given a wrong answer seven times in this project.)
#
# F. DAMAGE. Both target images' sha256 before and after. A zeroed disk that
#    comes back byte-identical was not written. THE COMPARATOR IS PROVED with a
#    planted byte -- flipping one byte in a copy must change the digest -- so
#    "unchanged" is a measurement and not a comparator that always agrees.
#
# WHAT THIS GATE DOES NOT MEASURE, said here rather than left to be assumed:
#   * the graphical path with the WRONG (served) /bin/install staged. If the
#     spawn is unreachable, which binary sits behind it cannot matter; if a
#     later change makes a disk appear, this becomes worth running again with
#     the served tarball delivered as served_install_binary.sh does.
#   * a Hamnix-native boot, where `#b` exists and a disk presumably WOULD be
#     listed. Nothing here says the wizard is wrong on the lane it was written
#     for.
#   * the pointer. The wizard is driven by keyboard because that is provable
#     (section D); a missed click is a soak that quietly tested nothing.
#
# Usage: tests/linux/install_wizard_gui.sh
# Env:   HAMLINUX_WIZGUI_WORK      where to build and boot
#        HAMLINUX_WIZGUI_REUSE=1   reuse the medium already built there
#        HAMLINUX_WIZGUI_IMGREUSE=1 reuse build/image/root -- ITERATION ONLY
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"
# FIRST, before reap.sh and before $WORK -- the contract in
# tests/linux/private_ns.sh. gates_are_private.sh checks that this line is here.
. tests/linux/private_ns.sh
priv_ns_reexec "$@"
. tests/linux/reap.sh

WORK="${HAMLINUX_WIZGUI_WORK:-$HOME/.hamnix-build/install-wizard-gui}"
mkdir -p "$WORK"
reap_track "$WORK/reaped"
reap_on_exit :

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  PASS  %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$*"; }
say()  { printf '\n== %s\n' "$*"; }
info() { printf '  ..    %s\n' "$*"; }

export PATH="$PATH:/usr/sbin:/sbin"
for t in qemu-system-x86_64 sgdisk socat python3 tesseract convert sha256sum; do
    command -v "$t" >/dev/null || { bad "need $t"; exit 1; }
done
[ -f /usr/share/OVMF/OVMF_CODE_4M.fd ] || { bad "need OVMF"; exit 1; }
QMP_INPUT="$PROJ_ROOT/tests/linux/qmp_input.py"
[ -f "$QMP_INPUT" ] || { bad "need tests/linux/qmp_input.py"; exit 1; }

UI=user/haminstallui.ad
MARK="WIZGUIUP7743"
PREM="WIZGUIPREMISE"
CENSUS="WIZGUICENSUS"
READY="scene window ready"

SCREEN_W=1280
SCREEN_H=800
# The wizard's own window, off the source and not off a screenshot:
# haminstallui.ad:1352 writes `geometry 180 70 <WIN_W> <WIN_H>` and :629-630
# set WIN_W=440 WIN_H=470.
WIN_X=180; WIN_Y=70; WIN_W=440; WIN_H=470

# ---------------------------------------------------------------------------
say "P -- THE PREMISES, RE-GREPPED: is the tree still the tree this gate argues about?"
# ---------------------------------------------------------------------------
# Every one of these is a claim the header makes. A gate that asserts things
# about a subject it never re-read is a gate reporting on its own comment.

# P1 -- /dev/blk is the wizard's ONLY source of disks.
NBLK=$(grep -c 'p9_listdir(cast\[Ptr\[char\]\]("/dev/blk")' "$UI")
NLIST=$(grep -c 'p9_listdir' "$UI")
if [ "$NBLK" = 1 ] && [ "$NLIST" = 2 ]; then
    # 2 = the `from lib.p9 import` line plus the one call.
    ok "haminstallui.ad calls p9_listdir exactly once, on /dev/blk -- it has one source of disks"
else
    bad "haminstallui.ad has $NLIST p9_listdir mentions ($NBLK of them on /dev/blk) -- the enumeration this gate reasons about has changed; re-read it before believing anything below"
fi
if grep -qE 'listdir.*"/dev"[^/]' "$UI" || grep -q '/proc/partitions' "$UI"; then
    bad "haminstallui.ad now has a second disk source -- this gate's prediction is stale"
else
    ok "and no /dev scan and no /proc/partitions fallback beside it"
fi

# P2 -- the rc that actually boots does not bind '#b'.
if grep -q "bind '#b'" etc/rc.boot.installed; then
    bad "etc/rc.boot.installed now binds '#b' -- /dev/blk may exist on the booted desktop after all"
else
    ok "etc/rc.boot.installed binds no '#b', so the booted desktop has no /dev/blk to list"
fi
if grep -q "the /dev/blk file server is not written yet" user/linux-syscalls.c; then
    ok "and user/linux-syscalls.c still answers a '#b' bind with 'not written yet'"
else
    bad "user/linux-syscalls.c no longer refuses '#b' -- the Linux lane may have gained a block server; this gate's premise is stale"
fi

# P3 -- the installer the wizard spawns avoids the interface the wizard gates on.
if grep -q '/dev/blk' user/hlinstall.ad; then
    ok "user/hlinstall.ad still records avoiding /dev/blk -- the wizard gates on an interface its own installer refuses to use"
else
    bad "user/hlinstall.ad no longer mentions /dev/blk -- re-read the inconsistency this gate reports"
fi

# P4 -- Return is Next and Tab switches field, which is what section D drives.
grep -q 'Enter / Return = Next' "$UI" \
    && ok "haminstallui.ad still maps Return to Next, which is how the hand below drives it" \
    || bad "Return may no longer be Next in haminstallui.ad -- the keyboard drive below is not the wizard's navigation"

[ "$FAIL" = 0 ] || { printf '\n%d PASSED, %d FAILED\n' "$PASS" "$FAIL"; \
    printf 'the premises do not hold; measuring behaviour against them would be reporting on a stale comment\n'; exit 1; }

# ---------------------------------------------------------------------------
# THE GUEST'S rc: THE SHIPPED ONE, SOURCED VERBATIM, PLUS THE LAUNCH.
#
# `source '/etc/rc.boot.installed'` first, so the desktop that comes up is the
# one rc.5.linux brings up -- wsysd, hamdesktop, hampanelscene. A gate with an
# rc of its own would prove nothing about the machine that ships.
#
# EVERY CONSTRUCT BELOW IS ONE tests/linux/soak_desktop.sh HAS ALREADY RUN ON
# THIS IMAGE, and that is deliberate rather than fussy: hamsh PARSES THE WHOLE
# RC BEFORE RUNNING ANY OF IT, so one unsupported token makes the entire boot
# measure nothing while looking clean. No awk, no xargs, no pipelines, no `$!`,
# no `while true`.
#
# The premise block runs BEFORE the launch so that what the guest could see of
# its own disks is on the console even if the wizard never appears.
# ---------------------------------------------------------------------------
# THE LAUNCH QUEUE GETS A POSITIVE CONTROL, AND THE FIRST RUN OF THIS GATE IS
# WHY. It wrote `/bin/haminstallui` to /dev/wsys/appmenu/launch once, straight
# after the rc came back, and NOTHING HAPPENED: no window, no console line, and
# no `haminstallui` in any of 35 `ps` censuses. That result is UNREADABLE on its
# own -- "the wizard will not start" and "this gate cannot start anything" have
# the same signature -- so `/bin/hamcalcscene` is launched through the SAME
# QUEUE five seconds earlier. It is a program tests/linux/soak_desktop.sh has
# launched through that queue hundreds of times, so if IT appears and the wizard
# does not, the difference is the wizard.
#
# AND THE WIZARD'S OWN OUTPUT IS NOT ON THE CONSOLE, which the first run also
# had to learn. A program started from the launch queue inherits
# hampanelscene's stdout, and etc/rc.d/rc.5.linux redirects hampanelscene into
# /var/log/panel.log. So `[haminstallui] scene window ready` and
# `[haminstallui] FAIL newwindow` land in that file, not on ttyS0, and the
# census tails it.
cat >"$WORK/rc.wizgui" <<RCEOF
source '/etc/rc.boot.installed'
echo '${PREM}BEGIN'
echo '--- ls /dev'
ls /dev
echo '--- ls /dev/blk'
ls /dev/blk
echo '--- ls /dev/wsys'
ls /dev/wsys
echo '--- ls /dev/wsys/appmenu'
ls /dev/wsys/appmenu
echo '--- cat /proc/partitions'
cat '/proc/partitions'
echo '${PREM}END'
sleep 10
echo '/bin/hamcalcscene' > '/dev/wsys/appmenu/launch'
sleep 6
echo '/bin/haminstallui' > '/dev/wsys/appmenu/launch'
echo '$MARK'
while 1 == 1 {
    echo '${CENSUS}BEGIN'
    ps
    tail -20 /var/log/panel.log
    echo '${CENSUS}END'
    sleep 5
}
RCEOF

# ---------------------------------------------------------------------------
say "building the live medium (the shipped rc, sourced verbatim) and two BLANK targets"
# ---------------------------------------------------------------------------
NVME="$WORK/target-nvme.img"
VBLK="$WORK/target-virtio.img"
if [ "${HAMLINUX_WIZGUI_REUSE:-0}" = 1 ] && [ -f "$WORK/medium.img" ]; then
    info "reusing $WORK/medium.img"
else
    if [ "${HAMLINUX_WIZGUI_IMGREUSE:-0}" = 1 ] && [ -d build/image/root ]; then
        info "HAMLINUX_WIZGUI_IMGREUSE: reusing build/image/root -- ITERATION ONLY, not a result"
    else
        info "rebuilding build/image/root so this gate cannot boot a stale tree"
        HAMLINUX_DISTRO_RO=1 scripts/hamlinux_image.sh >"$WORK/image.log" 2>&1 || {
            bad "image build"; tail -20 "$WORK/image.log"; exit 1; }
    fi
    HAMLINUX_DISK_RC="$WORK/rc.wizgui" \
        scripts/hamlinux_disk.sh "$WORK/medium.img" 3G >"$WORK/disk.log" 2>&1 || {
        bad "disk build"; tail -20 "$WORK/disk.log"; exit 1; }
fi

# THE TARGETS ARE ZEROED EVERY RUN. A reused target that already carries a
# previous run's install would make the damage check below meaningless in the
# direction that matters.
rm -f "$NVME" "$VBLK"
truncate -s 4G "$NVME"
truncate -s 4G "$VBLK"
NVME_BEFORE=$(sha256sum <"$NVME" | cut -d' ' -f1)
VBLK_BEFORE=$(sha256sum <"$VBLK" | cut -d' ' -f1)
info "both targets are 4G of zeros: nvme $NVME_BEFORE"

# THE COMPARATOR PROOF, and it is run rather than described. A digest
# comparison that could not see a change would report "nothing was written"
# for a disk that had been rewritten end to end.
cp "$NVME" "$WORK/planted.img"
printf 'X' | dd of="$WORK/planted.img" bs=1 seek=1048576 conv=notrunc status=none
PLANTED=$(sha256sum <"$WORK/planted.img" | cut -d' ' -f1)
if [ "$PLANTED" != "$NVME_BEFORE" ]; then
    ok "the damage comparator sees a SINGLE planted byte in a 4G image, so 'unchanged' below is a measurement"
else
    bad "the damage comparator gave the same digest for an image with a planted byte -- IT IS BLIND and no damage result below can be believed"
fi
rm -f "$WORK/planted.img"

# ---------------------------------------------------------------------------
# ocr_win <ppm> <txt> -- the wizard's own window, as text.
#
# Cropped to the window rather than OCR'ing the whole desktop: the panel's clock
# and the backdrop contribute strings that have nothing to do with the wizard,
# and a substring search over the whole screen could match one of them.
# Upscaled 3x and thresholded because the wizard draws an 8-px bitmap font that
# tesseract will not resolve at native size. --psm 6 = "one uniform block of
# text", which is what a wizard page is.
# ---------------------------------------------------------------------------
ocr_win() {
    # <ppm> <base> -- writes <base>.png (what tesseract was shown, kept so a
    # human can check the crop) and <base>.txt (what it read).
    local ppm="$1" base="$2"
    convert "$ppm" -crop "${WIN_W}x${WIN_H}+${WIN_X}+${WIN_Y}" +repage \
        -colorspace Gray -resize 300% -sharpen 0x1 "$base.png" 2>/dev/null || return 1
    tesseract "$base.png" "$base" --psm 6 >/dev/null 2>&1 || return 1
    [ -s "$base.txt" ]
}

hmp() { printf '%s\n' "$2" | timeout 15 socat - "UNIX-CONNECT:$1/mon.sock" 2>/dev/null; }
qi()  { local d="$1"; shift; timeout 60 python3 "$QMP_INPUT" "$d/qmp.sock" "$@" 2>&1; }

# shot <dir> <tag>  -- a screendump plus its OCR, both kept for a human.
SHOT_TXT=""
shot() {
    local d="$1" tag="$2"
    local p="$d/shots/$tag.ppm"
    hmp "$d" "screendump $p" >/dev/null
    sleep 1
    SHOT_TXT="$d/shots/$tag.txt"
    : >"$SHOT_TXT"
    if [ ! -s "$p" ]; then
        info "screendump for '$tag' produced no file"
        return 1
    fi
    ocr_win "$p" "$d/shots/$tag" || return 1
    return 0
}

# ---------------------------------------------------------------------------
say "BOOTING: the live medium on xHCI mass storage, with a blank NVMe AND a blank virtio-blk target"
# ---------------------------------------------------------------------------
D="$WORK/run"
rm -rf "$D"; mkdir -p "$D/shots"
cp /usr/share/OVMF/OVMF_VARS_4M.fd "$D/OVMF_VARS.fd"

# BOTH MONITORS. HMP answers `screendump`; QMP is what qmp_input.py speaks, and
# `input-send-event` has no HMP equivalent that can type a character.
#
# virtio-keyboard-pci: the device every input gate in this tree drives, so a
# keystroke here takes the same path through wsysd's open_inputs() scan as a
# keystroke there.
#
# TWO TARGETS ON TWO BUSES. NVMe is what is inside his laptop; virtio-blk is
# added so that "no disk was offered" cannot be answered with "you attached the
# wrong kind of disk".
qemu-system-x86_64 \
    -m 2048 -smp 2 -no-reboot \
    -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
    -drive "if=pflash,format=raw,unit=1,file=$D/OVMF_VARS.fd" \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -display none -vga std \
    -serial "file:$D/serial.log" \
    -enable-kvm -cpu host \
    -monitor "unix:$D/mon.sock,server,nowait" \
    -qmp "unix:$D/qmp.sock,server,nowait" \
    -device virtio-keyboard-pci -device virtio-tablet-pci \
    -device qemu-xhci,id=xhci \
    -drive "file=$WORK/medium.img,if=none,format=raw,id=usbstick" \
    -device usb-storage,bus=xhci.0,drive=usbstick,bootindex=0 \
    -drive "file=$NVME,if=none,format=raw,id=tgtnvme" \
    -device nvme,drive=tgtnvme,serial=WIZGUINVME \
    -drive "file=$VBLK,if=none,format=raw,id=tgtvblk" \
    -device virtio-blk-pci,drive=tgtvblk \
    >"$D/qemu.out" 2>&1 &
VM=$!
reap_add "$VM"

# ---------------------------------------------------------------------------
say "A -- ARE THE TARGET DISKS REALLY ATTACHED? (without this the run cannot be read)"
# ---------------------------------------------------------------------------
sleep 5
hmp "$D" 'info block' >"$D/infoblock.txt"
if grep -q '^tgtnvme' "$D/infoblock.txt" && grep -q '^tgtvblk' "$D/infoblock.txt"; then
    ok "QEMU reports both blank targets attached (tgtnvme, tgtvblk) -- a wizard that offers no disk here is not offering a disk that exists"
else
    bad "QEMU does not report both targets attached -- EVERYTHING BELOW IS UNINTERPRETABLE, because a wizard is right to offer no disk on a machine with none"
    sed -n '1,40p' "$D/infoblock.txt"
fi

# ---------------------------------------------------------------------------
say "B -- DOES THE WIZARD START, THROUGH THE APP MENU'S OWN LAUNCH QUEUE?"
# ---------------------------------------------------------------------------
W=0
while kill -0 "$VM" 2>/dev/null && [ "$W" -lt 420 ]; do
    grep -aq "$MARK" "$D/serial.log" 2>/dev/null && break
    sleep 2; W=$((W+2))
done
if grep -aq "$MARK" "$D/serial.log" 2>/dev/null; then
    ok "the boot reached the end of the gate's rc after ~${W}s"
else
    bad "the boot never reached the end of the rc in ${W}s -- nothing below was measured"
    tail -40 "$D/serial.log" 2>/dev/null
    kill -KILL "$VM" 2>/dev/null; wait "$VM" 2>/dev/null
    printf '\n%d PASSED, %d FAILED\n' "$PASS" "$FAIL"; exit 1
fi

# WHAT THE GUEST COULD SEE OF ITS OWN DISKS. Printed whatever happens, because
# it is the direct reading of the accused directory.
say "   what the guest itself said about its disks"
sed -n "/${PREM}BEGIN/,/${PREM}END/p" "$D/serial.log" | tr -d '\r' \
    | sed 's/^/  ||    /' | head -60

# THE ACCUSED, MEASURED IN THE GUEST. `ls /dev/blk` is hamsh's ls over the same
# namespace `p9_listdir` walks. The POSITIVE CONTROL is one line above it in the
# same rc: `ls /dev` must have printed something, or an empty /dev/blk is a
# broken `ls` rather than an empty directory.
PREMBLOCK=$(sed -n "/${PREM}BEGIN/,/${PREM}END/p" "$D/serial.log" | tr -d '\r')
DEV_LINES=$(printf '%s' "$PREMBLOCK" | sed -n '/--- ls \/dev$/,/--- ls \/dev\/blk/p' | grep -cv '^---')
BLK_BLOCK=$(printf '%s' "$PREMBLOCK" | sed -n '/--- ls \/dev\/blk/,/--- cat/p' | grep -v '^---')
if [ "${DEV_LINES:-0}" -gt 3 ]; then
    ok "the guest's own \`ls /dev\` printed $DEV_LINES entries, so \`ls\` works on this machine and an empty answer for /dev/blk is a reading"
else
    bad "the guest's \`ls /dev\` printed only ${DEV_LINES:-0} entries -- the in-guest listing instrument is not working and cannot be used to report on /dev/blk"
fi
if printf '%s' "$BLK_BLOCK" | grep -q '[a-z]'; then
    info "the guest's \`ls /dev/blk\` said: $(printf '%s' "$BLK_BLOCK" | tr '\n' ' ' | cut -c1-160)"
else
    info "the guest's \`ls /dev/blk\` printed nothing at all"
fi

# THE LAUNCH QUEUE'S POSITIVE CONTROL COMES FIRST. Until a program that is
# known to start through this queue has been seen to start through it in THIS
# boot, "the wizard did not start" is a statement about the harness.
W=0
while kill -0 "$VM" 2>/dev/null && [ "$W" -lt 180 ]; do
    grep -aq "$READY" "$D/serial.log" 2>/dev/null && break
    grep -ac 'hamcalcscene' "$D/serial.log" >/dev/null 2>&1
    sleep 3; W=$((W+3))
done
sleep 12
QUEUE_OK=0
if grep -aq 'hamcalcscene' "$D/serial.log" 2>/dev/null; then
    QUEUE_OK=1
    ok "the control program hamcalcscene STARTED through /dev/wsys/appmenu/launch in this boot -- the queue works here"
else
    bad "hamcalcscene did not start through /dev/wsys/appmenu/launch either -- THE LAUNCH QUEUE IS NOT WORKING IN THIS HARNESS, and nothing below can be read as a statement about the wizard"
fi
if grep -aq "$READY" "$D/serial.log" 2>/dev/null; then
    ok "haminstallui printed '$READY' -- the app-menu launch queue started the wizard and its window is up"
elif [ "$QUEUE_OK" = 1 ]; then
    bad "hamcalcscene started through the launch queue and haminstallui DID NOT: the graphical installer cannot be started from the Applications menu at all, which is a defect in front of the one this gate was sent to measure"
else
    bad "haminstallui never printed '$READY' after ${W}s, and the queue control did not run either -- this is a harness failure, not a measurement of the wizard"
fi
info "what /var/log/panel.log says about the two launches:"
grep -a 'haminstallui\|hamcalcscene\|appmenu\|launch' "$D/serial.log" 2>/dev/null \
    | sort -u | head -12 | sed 's/^/  ||    /'

# ---------------------------------------------------------------------------
say "C -- CAN THE SCREEN BE READ AT ALL? (the OCR is proved before it is used)"
# ---------------------------------------------------------------------------
if shot "$D" p1_host; then
    ok "a screendump of the wizard's window OCR'd to $(wc -c <"$SHOT_TXT") bytes of text"
else
    bad "the wizard's window could not be screendumped or OCR'd -- 'the person saw nothing' below could not be told from 'the instrument saw nothing'"
fi
P1=$(cat "$D/shots/p1_host.txt" 2>/dev/null || printf '')
info "step-1 OCR: $(printf '%s' "$P1" | tr '\n' '|' | cut -c1-200)"
# POSITIVE: a string the source draws unconditionally on this page.
if printf '%s' "$P1" | grep -qi 'Step 1'; then
    ok "the OCR finds 'Step 1' on the first page -- it can read this font"
else
    bad "the OCR cannot find 'Step 1' on the wizard's first page -- every text assertion below is worthless"
fi
# NEGATIVE, AND IT IS RUN: an OCR that matched everything would pass the lot.
if printf '%s' "$P1" | grep -qi 'Step 5 of 5'; then
    bad "the OCR reports 'Step 5 of 5' on the FIRST page -- it matches text that is not there and cannot discriminate between pages"
else
    ok "and does NOT report 'Step 5 of 5' on the first page, so a later match is a real page change"
fi
[ "$FAIL" = 0 ] || { info "the instrument is not proved; the drive below is still run, but read its output as unverified"; }

# ---------------------------------------------------------------------------
say "D -- DRIVING THE WIZARD BY KEYBOARD TO THE DISK PAGE"
# ---------------------------------------------------------------------------
# Click inside the window first so the compositor focuses it, then type. The
# click's target is the middle of the wizard's own body -- not a widget, so it
# cannot advance anything by itself.
qi "$D" click $(( WIN_X + WIN_W / 2 )) $(( WIN_Y + 250 )) "$SCREEN_W" "$SCREEN_H" >/dev/null
sleep 2

# THE HAND READS THE SCREEN BEFORE IT ACTS, and the first driven run of this
# gate is why. It sent a FIXED script -- one Return per page, Tab between the
# two password boxes -- and the wizard ended up parked on `Step 3 of 5` with
# `Passwords do not match.` while the script carried on pressing Return at a
# page it had already left. A fixed sequence cannot tell "the wizard refused"
# from "the wizard is somewhere else", and those are the two answers this gate
# exists to separate. So every action below is chosen from the OCR of the frame
# in front of it.
#
# AND THE PASSWORD BOXES ARE FOCUSED BY CLICKING, NOT BY TAB. The wizard's own
# hint line says `(Tab switches fields.)` and haminstallui.ad:562 implements it,
# but in the run above the confirm box stayed EMPTY through a Tab and two typed
# strings -- so either the Tab qcode does not arrive as ASCII 9 or the focus did
# not move, and this gate cannot tell which. Clicking the box is what a person
# does (:1261-1268 handles it) and it is unambiguous. WHETHER TAB WORKS IS
# THEREFORE NOT MEASURED HERE and is left as an open question rather than
# reported as either answer.
#
# THE COORDINATES ARE THE SOURCE'S OWN, and they were checked against a
# screendump before being used: the field rects are (CONTENT_X, 92) and
# (CONTENT_X, 156) at FIELD_W x FIELD_H = 400x26 (haminstallui.ad:775, :633),
# the footer is at WIN_H-14-FOOTER_H = 426 and Next at WIN_W-20-120 = 300. In
# the screendump the confirm box measured window-y 158..182 against a source y
# of 156..182, so CONTENT COORDINATES ARE WINDOW COORDINATES on this build and
# absolute = window origin + content.
wclick() { qi "$D" click $(( WIN_X + $1 )) $(( WIN_Y + $2 )) "$SCREEN_W" "$SCREEN_H" >/dev/null; }
F1_X=220; F1_Y=105          # first  input box, centre
F2_X=220; F2_Y=169          # confirm input box, centre
WIZPW=hampw

clear_field() {  # 24 backspaces: the boxes are append-only and may carry text
    local i=0                   # from an earlier pass over the same page.
    while [ "$i" -lt 24 ]; do qi "$D" key backspace >/dev/null; i=$((i+1)); done
}

STEPS_SEEN=""
DISK=""
n=0
while [ "$n" -lt 12 ]; do
    n=$((n+1))
    tag=$(printf 'd%02d' "$n")
    shot "$D" "$tag" || true
    T=$(cat "$D/shots/$tag.txt" 2>/dev/null || printf '')
    S=$(printf '%s' "$T" | grep -oiE 'Step [0-9]' | head -1)
    info "$tag: ${S:-<no step line>} | $(printf '%s' "$T" | tr '\n' '|' | cut -c1-110)"
    case "$STEPS_SEEN" in
        *"${S:-none}"*) : ;;
        *) STEPS_SEEN="$STEPS_SEEN ${S:-none}" ;;
    esac
    if printf '%s' "$T" | grep -qi 'Step 5'; then
        DISK="$T"
        cp "$D/shots/$tag.png" "$D/shots/p5_disk.png" 2>/dev/null
        cp "$D/shots/$tag.txt" "$D/shots/p5_disk.txt" 2>/dev/null
        break
    fi
    if printf '%s' "$T" | grep -qi 'Confirm password'; then
        wclick "$F1_X" "$F1_Y"; clear_field; qi "$D" type "$WIZPW" >/dev/null
        wclick "$F2_X" "$F2_Y"; clear_field; qi "$D" type "$WIZPW" >/dev/null
        sleep 1
        qi "$D" key ret >/dev/null
    else
        # A VALUE IS TYPED BEFORE THE RETURN ON EVERY TEXT PAGE, AND THE THIRD
        # RUN OF THIS GATE IS WHY: a bare Return advanced Step 1 (the host name
        # is pre-seeded by `_seed_defaults`) and then sat on Step 2 for eleven
        # consecutive Returns, because THE USERNAME FIELD IS EMPTY and
        # `_page_ready` correctly refuses. That is the wizard behaving properly
        # and the harness reading it as a stuck wizard. `hamwiz` satisfies both
        # CLS_HOST and CLS_USER, so it is valid on either page and appending it
        # to a seeded field leaves a legal value.
        qi "$D" type hamwiz >/dev/null
        sleep 1
        qi "$D" key ret >/dev/null
    fi
    sleep 4
done

# THE CONTROL FOR EVERY "IT REFUSED" BELOW, and it is a measurement made inside
# this same run with this same keystroke mechanism. If the OCR shows the wizard
# passing through distinct numbered pages, then Return demonstrably reaches this
# window, and a Return that changes nothing on the disk page was REFUSED BY THE
# WIZARD rather than lost on the way.
NSTEPS=$(printf '%s' "$STEPS_SEEN" | tr ' ' '\n' | grep -c 'Step')
info "distinct wizard pages seen by the OCR:$STEPS_SEEN"
if [ "$NSTEPS" -ge 3 ]; then
    ok "the keyboard REACHES the wizard: it was driven through $NSTEPS distinct numbered pages ($STEPS_SEEN) -- so a Return that does nothing later was refused, not lost"
else
    bad "the OCR saw only $NSTEPS distinct pages ($STEPS_SEEN) -- the hand may not be reaching the wizard, and no 'it refused' below can be believed"
fi
if printf '%s' "$DISK" | grep -qi 'Step 5'; then
    ok "the wizard reached 'Step 5 of 5: Disk & partitioning' -- the disk page is what the person is looking at"
else
    bad "the wizard never reached step 5 in this drive -- see $D/shots/"
fi

# ---------------------------------------------------------------------------
say "WHAT DOES THE PERSON ACTUALLY SEE ON THE DISK PAGE?"
# ---------------------------------------------------------------------------
printf '  ||    ----- OCR of the wizard window at step 5 -----\n'
sed 's/^/  ||    /' "$D/shots/p5_disk.txt" 2>/dev/null | head -30
printf '  ||    -----------------------------------------------\n'

SAW_NODISK=0; SAW_TARGET=0
# The two strings the source draws when n_disks == 0 (haminstallui.ad:834-846).
# Matched loosely -- 'installable' and 'Rescan' are the distinctive tokens and
# the least likely to be mangled by OCR of an 8-px font.
printf '%s' "$DISK" | grep -qi 'installab' && SAW_NODISK=1
printf '%s' "$DISK" | grep -qi 'rescan'    && SAW_NODISK=1
printf '%s' "$DISK" | grep -qiE 'nvme|vd[ab]|sd[ab]' && SAW_TARGET=1

if [ "$SAW_TARGET" = 1 ]; then
    bad "THE WIZARD OFFERED A TARGET DISK. That is not what the source predicted; the spawn is reachable and the graphical path must now be measured with the SERVED /bin/install as well"
elif [ "$SAW_NODISK" = 1 ]; then
    ok "the disk page says it has NO INSTALLABLE TARGET and offers Rescan -- with two blank disks attached on two buses. The person is told, in the wizard's own red text, that it cannot continue"
else
    bad "the disk page shows NEITHER a target disk NOR the no-disk message -- the person may be looking at nothing, which is one of the outcomes this gate exists to rule out; read $D/shots/p5_disk.png"
fi

# ---------------------------------------------------------------------------
say "IS 'NEXT' REFUSED? (and does the wizard sit there, or go somewhere)"
# ---------------------------------------------------------------------------
# _page_ready() (haminstallui.ad:618) requires sel_disk >= 0 on the disk page, so
# a wizard with no disks should refuse to advance. Pressed three times: once
# could be a dropped keystroke, and section D has already shown that Return does
# reach this window.
qi "$D" key ret >/dev/null; sleep 2
qi "$D" key ret >/dev/null; sleep 2
qi "$D" key ret >/dev/null; sleep 5
shot "$D" p6_afternext || true
AFTER=$(cat "$D/shots/p6_afternext.txt" 2>/dev/null || printf '')
info "after 3 more Returns: $(printf '%s' "$AFTER" | tr '\n' '|' | cut -c1-200)"
if printf '%s' "$AFTER" | grep -qiE 'Review|install now|Installing|complete'; then
    bad "THREE MORE RETURNS MOVED THE WIZARD PAST THE DISK PAGE with no disk selected -- it is heading for the spawn without a target"
elif printf '%s' "$AFTER" | grep -qi 'Step 5'; then
    ok "three more Returns left the wizard on step 5 -- Next is REFUSED, and section D proved the keystrokes arrive"
else
    bad "after three Returns the window OCRs to neither step 5 nor any later page -- what the person is looking at is not established"
fi

# ---------------------------------------------------------------------------
say "E -- DID /bin/install EVER RUN?"
# ---------------------------------------------------------------------------
# The guest's own `ps`, over the whole run. THE POSITIVE CONTROL IS IN THE SAME
# CENSUS: wsysd is certainly running (the desktop is up and being screendumped),
# so a census that finds wsysd and not install is a reading. A census that found
# neither would be a `ps` that printed nothing.
sed -n "/${CENSUS}BEGIN/,/${CENSUS}END/p" "$D/serial.log" | tr -d '\r' >"$D/census.txt"
NCENSUS=$(grep -c "${CENSUS}BEGIN" "$D/census.txt")
NWSYSD=$(grep -c 'wsysd' "$D/census.txt")
NINSTALL=$(grep -cE '(^| |/)(install|hlinstall)( |$)' "$D/census.txt")
NUI=$(grep -c 'haminstallui' "$D/census.txt")
NCALC=$(grep -c 'hamcalcscene' "$D/census.txt")
info "$NCENSUS censuses; lines mentioning wsysd=$NWSYSD hamcalcscene=$NCALC haminstallui=$NUI install/hlinstall=$NINSTALL"
if [ "$NCENSUS" -ge 2 ] && [ "$NWSYSD" -ge 1 ]; then
    ok "the guest's \`ps\` ran $NCENSUS times and found wsysd -- so this census can see a running process"
else
    bad "the guest's \`ps\` census produced $NCENSUS blocks and found wsysd $NWSYSD times -- IT CANNOT SEE A RUNNING PROCESS and cannot report on /bin/install"
fi
if [ "$NCALC" -ge 1 ]; then
    ok "the same census found hamcalcscene, the launch-queue control -- so a process started through that queue IS visible to it"
else
    bad "the census never found hamcalcscene either, so it cannot be used to say whether the wizard ran"
fi
if [ "$NUI" -ge 1 ]; then
    ok "and it found haminstallui, so the wizard really was a live process while the screen was being read"
elif [ "$NCALC" -ge 1 ]; then
    bad "the census found the control program but NEVER haminstallui in $NCENSUS samples: the wizard was never a process on this machine"
else
    bad "the census never found haminstallui -- but it never found the control either, so this says nothing about the wizard"
fi
if [ "$NINSTALL" = 0 ]; then
    ok "/bin/install NEVER APPEARED in any census: the wizard did not reach the spawn, so which bytes sit at /bin/install could not have mattered on this path"
else
    bad "/bin/install (or hlinstall) DID appear in the census $NINSTALL times -- the spawn was reached and the served-binary question is live on the graphical path"
fi
# And the wizard's own spawn/result strings, which are what it prints when it
# gets that far (haminstallui.ad:1084 spawn, :1126 'install complete', :1128 FAIL).
for s in 'install complete' 'FAIL' 'spawn'; do
    n=$(grep -ac "$s" "$D/serial.log" 2>/dev/null || printf 0)
    info "console occurrences of '$s': $n"
done

# ---------------------------------------------------------------------------
say "F -- WAS ANYTHING WRITTEN TO EITHER TARGET DISK?"
# ---------------------------------------------------------------------------
kill -KILL "$VM" 2>/dev/null; wait "$VM" 2>/dev/null
sleep 1
NVME_AFTER=$(sha256sum <"$NVME" | cut -d' ' -f1)
VBLK_AFTER=$(sha256sum <"$VBLK" | cut -d' ' -f1)
if [ "$NVME_AFTER" = "$NVME_BEFORE" ]; then
    ok "the NVMe target is byte-identical after the whole session ($NVME_AFTER) -- nothing was written to it"
else
    bad "THE NVMe TARGET CHANGED (was $NVME_BEFORE, now $NVME_AFTER) -- something wrote to a disk the wizard never offered"
fi
if [ "$VBLK_AFTER" = "$VBLK_BEFORE" ]; then
    ok "the virtio-blk target is byte-identical too -- nothing was written to it"
else
    bad "THE virtio-blk TARGET CHANGED (was $VBLK_BEFORE, now $VBLK_AFTER)"
fi

printf '\n%d PASSED, %d FAILED\n' "$PASS" "$FAIL"
printf 'screendumps and their OCR: %s/shots/\n' "$D"
[ "$FAIL" = 0 ]
