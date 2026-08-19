#!/usr/bin/env bash
#
# tests/linux/graphical_login.sh — DOES THE MACHINE ASK WHO YOU ARE BEFORE IT
# DRAWS A DESKTOP, AND IS THERE ANYTHING BEHIND THE QUESTION?
#
# REGISTRATION. ON-DEMAND. Not in ci_battery_manifest.txt: it builds a medium,
# installs a machine onto a blank disk and boots that machine twice under
# OVMF, which is far past the battery's per-shard budget. It is registered in
# scripts/release_gates.sh beside tests/linux/pointer_launch_uid.sh, whose
# medium build, install step and debugfs reader this borrows almost unchanged.
#
# THE HOLE THIS FILLS
# ===================
# tests/linux/installed_boot_login.sh and installed_fresh_login.sh proved the
# TTY half: an installed machine presents `login:` on /dev/ttyS0, refuses junk
# and the account's wrong password, admits on the right one, and no root shell
# is reachable without authenticating. Both drive a serial line.
#
# THE GRAPHICAL HALF HAD NO GATE AND NO PROGRAM. /etc/rc.d/rc.5 started the
# compositor, the backdrop and the panel unconditionally, so a machine that
# had just booted put a person's desktop on the screen with nobody having said
# who they were. user/hamgreet.ad closes that and this measures it.
#
# THE ONE PROPERTY THAT SEPARATES A DISPLAY MANAGER FROM A LOCK SCREEN
# ====================================================================
# It is NOT "a password box appears". user/hamlock.ad puts a password box on
# the screen and everything behind it is already running as somebody. The
# property is that THE SESSION'S PROGRAMS DO NOT EXIST YET, and that is an
# ABSENCE -- the dangerous kind of assertion, and the one this file spends
# most of its length on.
#
# HOW THE ABSENCE IS MEASURED, AND WHY IT CAN BE BELIEVED
# =======================================================
# A process census, taken FOUR times on ONE boot by ONE instrument:
#
#   /var/lib/hamgreet-ps.pre      the instant the greeter's window came up
#   /var/lib/hamgreet-ps.denied   the instant a password was REFUSED
#   /var/lib/hamgreet-ps.ok       the instant /dev/auth said "ok"
#   /var/lib/hgt-ps.after         after the session has been running 20 s
#
# The first three are written by hamgreet at the exact moment it reaches that
# state -- no clock between the state and the reading. The fourth is written
# by `hamgreet -census <path>`, which is THE SAME CODE invoked as a one-shot
# from the machine's rc. That is what makes the control exact rather than
# rhetorical: the reading that must find hamdesktop and hampanelscene is taken
# by the identical lister as the three that must not. If the instrument were
# blind, the fourth would be empty too, and this gate fails on that FIRST.
#
# A truncated census would look exactly like the absence it is supposed to
# prove -- the first version of the lister silently cut a 933-process listing
# at 16,383 bytes mid-line on the dev host. It now writes CENSUS-TRUNCATED
# when it overflows and this gate fails on that string in any of the four.
#
# THE NEGATIVE CONTROLS, AND THREE OF THE FOUR ARE ARMS OF THE SAME BOOT
# ======================================================================
#   1. THE INSTRUMENT CAN SEE A SESSION PROGRAM. The `after` census must name
#      hamdesktop AND hampanelscene. Same boot, same lister.
#   2. THE OCR CAN SEE THE GREETER GO. The same crop of the same screen, read
#      the same way, must contain the greeter's title BEFORE authentication
#      and must NOT contain it after. Same boot.
#   3. A WRONG PASSWORD IS REFUSED, TWICE, FOR TWO DIFFERENT REASONS: an
#      account that does not exist, and the real account's wrong password.
#      Both must leave the greeter on the screen reading "Login incorrect",
#      and the census taken at that instant must still have no session
#      program in it. Same boot.
#   4. THE ANSWER DOES NOT OUTLIVE THE BOOT. A SECOND boot of the same
#      installed disk -- with /var/lib/hamsession.rc already on it, written
#      and committed by the first -- must present the greeter again. This is
#      the one that needs a second invocation, because "reboot" is what it is
#      about. Without hamgreet's unlink-on-entry this arm would find a desktop.
#
# AND THE OCR IS CONTROLLED TOO: every band this gate reads is also required
# NOT to report a string that is certainly not on that screen.
#
# WHOSE SESSION IS IT? READ OFF THE DISK, NOTHING MOUNTED
# =======================================================
# After the machine has powered itself off, this gate carves the root
# partition out of the raw NVMe image and reads it with debugfs. hamgreet
# writes <home>/.hamsession AFTER sys_setuid_auth on the verified /dev/auth
# fd, so the file's owner on the ext4 is the uid that fd resolved to. It is
# never asked of the running system.
#
# WHAT THIS GATE DOES NOT ESTABLISH
# =================================
#   * IT DOES NOT MEASURE WHAT THE SESSION'S `/` IS. hamgreet stamps
#     HAMNIX_NEWSHELL_USER and rc.5 sources /etc/rc.de-user inside the
#     authenticated branch, which is the seam the constructed-root work will
#     use -- but /etc/users/default.ns is still subtractive, so an
#     authenticated graphical session still lands in the machine's root. That
#     is the state of the tree, not a claim of this file.
#   * IT DOES NOT MEASURE hamdesktop's OR hampanelscene's OWN UID. They are
#     system chrome and still root by design (etc/rc.de-user.linux argues it
#     at length). What is measured here is the greeter's own drop.
#   * IT DOES NOT DRIVE tty1..tty3. Once the compositor presents it owns the
#     framebuffer; etc/rc.login.linux records the same limit.
#   * IT SAYS NOTHING ABOUT hamlock, which is STILL in no ship vehicle.
#
# Usage: tests/linux/graphical_login.sh
#   HGT_WORK=<dir>   work dir (default ~/.hamnix-build/graphlogin)
#   HGT_REUSE=1      reuse an already-built medium and installed disk
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

. tests/linux/reap.sh
reap_on_exit

W="${HGT_WORK:-$HOME/.hamnix-build/graphlogin}"
mkdir -p "$W"
export TMPDIR="$W/tmp"; mkdir -p "$TMPDIR"

LIVE="$W/live-usb.img"
NVME="$W/target-nvme.img"
PART="$W/part.img"
EXTRA="$W/extra"
SCREEN_W=1280
SCREEN_H=800
QMP_INPUT="$PROJ_ROOT/tests/linux/qmp_input.py"

USERNAME=hamgrtuser
HOSTNAME_=hamgrtbox
UPASS=hamgrtpw
RPASS=hamgrtadmin
WRONGPASS=notthepassword
JUNKUSER=nosuchperson
JUNKPASS=alsowrong

# What the OCR must NOT report. A control on the instrument itself: it is on
# no screen this gate photographs.
NOTONSCREEN="Step 5 of 5"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  PASS  $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL  $*"; }
info() { echo "        $*"; }
say()  { echo; echo "== $* =="; }
finish() { printf '\n%d PASSED, %d FAILED\n' "$PASS" "$FAIL"
           [ "$FAIL" = 0 ] && exit 0 || exit 1; }

for t in qemu-system-x86_64 socat python3 tesseract convert identify; do
    command -v "$t" >/dev/null || { echo "INCONCLUSIVE: need $t"; exit 2; }
done
for t in /sbin/debugfs /sbin/sfdisk; do
    [ -x "$t" ] || { echo "INCONCLUSIVE: need $t"; exit 2; }
done
[ -f "$QMP_INPUT" ] || { echo "INCONCLUSIVE: need tests/linux/qmp_input.py"; exit 2; }
[ -f /usr/share/OVMF/OVMF_CODE_4M.fd ] || { echo "INCONCLUSIVE: need OVMF"; exit 2; }

# ---- reading an ext4 without mounting it (from pointer_launch_uid.sh) -----
part_geom() {
    /sbin/sfdisk -J "$1" 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)["partitiontable"]
ss=d.get("sectorsize",512)
p=d["partitions"][int(sys.argv[1])-1]
print(p["start"]*ss, p["size"]*ss)' "$2"
}
carve() {
    local g off sz
    g="$(part_geom "$1" "$2")" || return 1
    [ -n "$g" ] || return 1
    off="${g% *}"; sz="${g#* }"
    rm -f "$PART"
    dd if="$1" of="$PART" bs=1M skip=$((off / 1048576)) \
       count=$(( (sz + 1048575) / 1048576 )) status=none
}
fs_has()  { /sbin/debugfs -R "stat $2" "$1" 2>/dev/null | grep -q '^Inode:'; }
fs_dump() { rm -f "$3"; /sbin/debugfs -R "dump $2 $3" "$1" >/dev/null 2>&1; [ -s "$3" ]; }
fs_uid()  { /sbin/debugfs -R "stat $2" "$1" 2>/dev/null |
            sed -n 's/.*User: *\([0-9][0-9]*\).*/\1/p' | head -1; }

# =========================================================================
# 0. THE MEDIUM, AND ONE INSTALL ONTO A BLANK DISK
# =========================================================================
say "0 -- the medium, and one install onto a blank virtual disk"

cat >"$W/rc.install" <<RCEOF
ln -s /dev/console /dev/cons
echo 'HGT-LIVE: the medium booted'
install --auto /dev/nvme0n1 --hostname $HOSTNAME_ --user $USERNAME --user-pass $UPASS --root-pass $RPASS
echo 'HGT-LIVE: the installer returned'
echo 'HGT-LIVE-DONE'
sleep 8
poweroff
RCEOF

if [ "${HGT_REUSE:-0}" = 1 ] && [ -f "$LIVE" ] && [ -s "$NVME" ]; then
    info "reusing $LIVE and $NVME (HGT_REUSE=1)"
else
    info "building the medium (two image passes; this is the slow part)"
    scripts/hamlinux_image.sh >"$W/img1.log" 2>&1 || {
        bad "lean image build -- see $W/img1.log"; finish; }
    # The SEED DISK is what writes /boot/root.partuuid; hlinstall refuses to
    # partition anything without it.
    scripts/hamlinux_disk.sh "$W/seed.img" 3G >"$W/disk1.log" 2>&1 || {
        bad "seed disk build -- see $W/disk1.log"; finish; }

    # ---- THE MACHINE'S OWN BOOT rc ---------------------------------------
    # Staged as etc/rc.boot.machine on the MEDIUM; user/hlinstall.ad copies it
    # to the target as /etc/rc.boot.
    #
    # IT DELIBERATELY DOES NOT SOURCE /etc/rc.login OR RUN `supervise`.
    # etc/rc.boot.machine's own header says a gate that replaces this file is
    # opting out of them "deliberately and visibly", and this one is: PID 1
    # must return from rc.5 so that the after-the-session census and the
    # poweroff can happen. THAT IS A DEPARTURE FROM THE SHIPPED MACHINE and it
    # is the reason this gate cannot also assert "no root shell": section 6
    # says so rather than leaving it to be discovered.
    #
    # NOTHING HERE STARTS A SESSION PROGRAM AND NOTHING HERE TOUCHES
    # /dev/auth. Every window on the screen below is started by the shipped
    # /etc/rc.d/rc.5, and the only thing that authenticates is a keystroke
    # this gate sends over QMP.
    #
    # THE PHASE FILE decides which boot this is. It is written FIRST in each
    # phase, before anything that could fail to return -- pointer_launch_uid.sh
    # paid for that ordering with a run in which four arms wore another arm's
    # name.
    rm -rf "$EXTRA"; mkdir -p "$EXTRA/etc"
    cat >"$EXTRA/etc/rc.boot.machine" <<'MRCEOF'
# /etc/rc.boot -- the boot script of THIS MACHINE.
# Staged onto the medium by tests/linux/graphical_login.sh.
#
# Boot 1 runs the whole thing. Boot 2 exists to prove the answer boot 1 gave
# does NOT outlive it, so boot 2 must NOT power off by itself: the gate wants
# to photograph a greeter that is still asking. The phase file is what tells
# them apart, and it is written by boot 1 before it does anything else it
# could fail to finish.
hgt_phase = 1
try {
    source '/var/lib/hgt.phase'
} except {
    hgt_phase = 1
}
echo '[hgt] rc.boot entered'

if $hgt_phase > 1 {
    echo 'HGT-PHASE-2'
} else {
    echo 'HGT-PHASE-1'
    echo 'hgt_phase = 2' > /var/lib/hgt.phase
}

# rc.5 BLOCKS in the greeter. Nothing below this line runs until somebody has
# authenticated -- which is itself one of the things being measured, because
# HGT-RC5-RETURNED cannot appear on the serial line before it happens.
source '/etc/rc.boot.installed'

echo 'HGT-RC5-RETURNED'

if $hgt_phase > 1 {
    echo 'HGT-PHASE-2-UNEXPECTED-SESSION'
    sleep 60
} else {
    sleep 20
    # THE CONTROL ON THE CENSUS: the same lister the greeter used, run as a
    # one-shot, now that the session IS up.
    /bin/hamgreet -census /var/lib/hgt-ps.after
    echo 'HGT-AFTER-CENSUS'
    sleep 10
    echo 'HGT-DONE'
    sleep 5
    poweroff > /dev/null
}
MRCEOF
    info "the machine's rc is staged"

    HAMLINUX_INSTALLER=1 scripts/hamlinux_image.sh >"$W/img2.log" 2>&1 || {
        bad "installer image build -- see $W/img2.log"; finish; }
    grep -q 'INCOMPLETE' "$W/img2.log" && bad "the medium's /usr/lib/instroot is INCOMPLETE -- see $W/img2.log"

    HAMLINUX_DISK_RC="$W/rc.install" HAMLINUX_DISK_EXTRA="$EXTRA" \
        scripts/hamlinux_disk.sh "$LIVE" 4G >"$W/disk2.log" 2>&1 || {
        bad "live medium build -- see $W/disk2.log"; finish; }

    rm -f "$NVME"; truncate -s 6G "$NVME"
    if [ "$(head -c 1048576 "$NVME" | tr -d '\0' | wc -c)" = 0 ]; then
        ok "the NVMe target is all zeroes before the install"
    else
        bad "the NVMe target is not blank"
    fi
fi
[ -s "$LIVE" ] || { bad "no live medium at $LIVE"; finish; }

if [ "${HGT_REUSE:-0}" != 1 ] || [ ! -f "$W/install/serial.log" ]; then
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
        -device nvme,drive=nvme0,serial=HGTTGT \
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
if grep -aq 'HGT-LIVE-DONE' "$W/install/serial.log" 2>/dev/null; then
    ok "the install boot ran to completion on the live medium"
else
    bad "the install boot never printed HGT-LIVE-DONE -- nothing below is a statement about an installed machine"
    tail -20 "$W/install/serial.log" 2>/dev/null | sed 's/^/        /'
    finish
fi
if grep -aq '^install complete' "$W/install/serial.log"; then
    ok "and the installer reported 'install complete'"
else
    bad "the installer did NOT report 'install complete': $(grep -a '^hlinstall: ' "$W/install/serial.log" | head -2 | tr '\n' ' ' | cut -c1-200)"
    finish
fi
# THE LIVE MEDIUM ITSELF MUST NOT HAVE ASKED FOR A PASSWORD. hamgreet takes
# the /etc/installer-medium branch there, and an installer that presented a
# login box to somebody with no account would be a worse bug than the one this
# work fixes.
if grep -aq 'installer-medium is present' "$W/install/serial.log"; then
    ok "the greeter recognised the LIVE MEDIUM and did not ask for a password there"
else
    info "the medium's console did not carry the greeter's live-medium line (it may not have reached rc.5 before the installer finished)"
fi

# =========================================================================
# 1. THE STATE THE MEASUREMENT NEEDS, BEFORE THE MACHINE HAS EVER BOOTED
# =========================================================================
say "1 -- the installed disk, read with debugfs, before it has ever run"
carve "$NVME" 2 || { bad "cannot carve the installed root partition"; finish; }

if fs_has "$PART" /etc/hamnix-release; then
    ok "the reader finds /etc/hamnix-release on the installed root, so what it reports below is a reading and not a broken reader"
else
    bad "the reader cannot find /etc/hamnix-release -- it is not working, and nothing it reports means anything"
    finish
fi
if fs_has "$PART" /etc/there-is-no-such-file-as-this; then
    bad "the reader reports a file that cannot exist -- every absence below is meaningless"
    finish
else
    ok "and the reader does NOT find a file that is certainly not there"
fi

# THE SHIP VEHICLE. NORTH_STAR.md's worst bug shape is a program in the tree
# and in no ship vehicle -- which is exactly what hamgreet was until this
# commit, and what hamlock still is. Asserted on the DISK, not in the build
# log.
if fs_has "$PART" /bin/hamgreet; then
    ok "/bin/hamgreet is ON THE INSTALLED DISK -- the greeter is in a ship vehicle, not only in the tree"
else
    bad "/bin/hamgreet is NOT on the installed disk. The image's GUI_APPS or the package's DESKTOP_CMDS did not carry it, and nothing below can be a statement about a greeter"
    finish
fi
# The live probe MUST be gone, or the greeter this gate photographs would be
# the live-medium branch (which asks nobody for anything) wearing the name of
# the real one.
if fs_has "$PART" /etc/installer-medium; then
    bad "/etc/installer-medium is STILL on the installed root -- hamgreet would take its live-medium branch and this machine would never ask for a password"
    finish
else
    ok "/etc/installer-medium is NOT on the installed root, so the greeter that runs there is the real one and not the live-medium branch"
fi
for f in /var/lib/hamsession.rc /var/lib/hamgreet.trace /var/lib/hamgreet-ps.pre \
         /var/lib/hamgreet-ps.denied /var/lib/hamgreet-ps.ok /var/lib/hgt-ps.after \
         "/home/$USERNAME/.hamsession"; do
    if fs_has "$PART" "$f"; then
        bad "$f ALREADY exists on a disk that has never booted -- finding it later would prove nothing"
    else
        ok "there is no $f before the machine has ever run"
    fi
done
U="$(fs_uid "$PART" "/home/$USERNAME")"
if [ "${U:-}" = 1001 ]; then
    ok "/home/$USERNAME is owned by uid 1001 -- there is a home the greeter's session marker can land in"
else
    bad "/home/$USERNAME is owned by uid ${U:-?}, not 1001"
fi
rm -f "$PART"

# =========================================================================
# THE INSTRUMENTS
# =========================================================================
_shot() {
    local p="$D/shots/$1.ppm" prev=-1 n i=0
    rm -f "$p"
    printf 'screendump %s\n' "$p" | timeout 20 socat - "UNIX-CONNECT:$MON" >/dev/null 2>&1
    while [ "$i" -lt 40 ]; do
        sleep 0.25; i=$((i+1))
        n=$(stat -c%s "$p" 2>/dev/null || echo 0)
        [ "$n" -gt 0 ] && [ "$n" = "$prev" ] && break
        prev="$n"
    done
    [ -s "$p" ]
}
# OCR a crop of a screendump. $1 = the shot, $2 = a name for THIS crop (so two
# bands of one shot do not overwrite each other's evidence), $3..$6 = w h x y.
# Sets OCRTXT.
OCRTXT=""
_ocr() {
    local shot="$1" tag="$1-$2" p="$D/shots/$1.ppm"
    OCRTXT=""
    [ -s "$p" ] || return 1
    convert "$p" -crop "${3}x${4}+${5}+${6}" +repage -colorspace Gray \
        -resize 400% -sharpen 0x1 "$D/shots/$tag.png" 2>/dev/null || return 1
    tesseract "$D/shots/$tag.png" "$D/shots/$tag" --psm 7 >/dev/null 2>&1 || return 1
    [ -s "$D/shots/$tag.txt" ] || return 1
    OCRTXT="$(tr '\n' ' ' <"$D/shots/$tag.txt")"
    return 0
}
Q() { python3 "$QMP_INPUT" "$QMP" "$@" >>"$D/drive.log" 2>&1; }
click() { Q click "$1" "$2" "$SCREEN_W" "$SCREEN_H"; }

# THE GREETER'S GEOMETRY IS DERIVED FROM THE SCREENDUMP, NOT ASSUMED.
# user/hamgreet.ad centres a 420x220 panel on whatever size the compositor
# published, and this gate does not get to decide what that was -- so the
# crops are computed from the PPM's real dimensions. A hardcoded 1280x800
# here would silently mis-aim every OCR on a machine that came up at another
# resolution and every band would read empty, which is indistinguishable from
# "the greeter is not there".
GB_W=0; GB_H=0; BX=0; BY=0
_geom_from() {
    local p="$D/shots/$1.ppm" wh
    wh="$(identify -format '%w %h' "$p" 2>/dev/null)" || return 1
    [ -n "$wh" ] || return 1
    GB_W="${wh% *}"; GB_H="${wh#* }"
    BX=$(( GB_W / 2 - 210 ))
    BY=$(( GB_H / 2 - 110 ))
    return 0
}
# The two bands, in the panel's own coordinates (see user/hamgreet.ad _paint).
_band_title() { _ocr "$1" title  460 26 $(( BX - 20 )) $(( BY + 10 )); }
_band_status(){ _ocr "$1" status 400 24 $(( BX + 16 )) $(( BY + 168 )); }

# Every OCR reading is scored the same way: it must say what it should, and it
# must NOT say something that is certainly not on the screen.
_ocr_control() {
    if printf '%s' "$OCRTXT" | grep -qiF "$NOTONSCREEN"; then
        bad "$1: the OCR reports '$NOTONSCREEN', which is on no screen this gate photographs -- it matches anything and the reading above means nothing"
    else
        ok "$1: and the OCR does NOT report text that is not there"
    fi
}

# =========================================================================
# 2. BOOT 1 -- THE GREETER, TWO REFUSALS AND ONE ADMISSION
# =========================================================================
say "2 -- boot 1: does the machine ask, does it refuse, does it admit"

D="$W/boot1"; rm -rf "$D"; mkdir -p "$D/shots"
MON="$D/mon.sock"; QMP="$D/qmp.sock"
cp /usr/share/OVMF/OVMF_VARS_4M.fd "$D/OVMF_VARS.fd"
qemu-system-x86_64 \
    -m 2048 -smp 2 -no-reboot \
    -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
    -drive "if=pflash,format=raw,unit=1,file=$D/OVMF_VARS.fd" \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -display none -vga std \
    -serial "file:$D/serial.log" \
    -enable-kvm -cpu host \
    -monitor "unix:$MON,server,nowait" \
    -qmp "unix:$QMP,server,nowait" \
    -device virtio-keyboard-pci -device virtio-tablet-pci \
    -drive "file=$NVME,if=none,format=raw,id=nvme0" \
    -device nvme,drive=nvme0,serial=HGTTGT \
    >"$D/qemu.out" 2>&1 &
QPID=$!
reap_add "$QPID"
info "qemu pid $QPID, serial $D/serial.log"

GREETLINE='the graphical login is starting'
i=0
while [ "$i" -lt 300 ]; do
    sleep 2; i=$((i+2))
    grep -aq "$GREETLINE" "$D/serial.log" 2>/dev/null && break
    st=$(awk '{print $3}' "/proc/$QPID/stat" 2>/dev/null)
    case "${st:-X}" in Z|X) break ;; esac
done
if grep -aq "$GREETLINE" "$D/serial.log" 2>/dev/null; then
    ok "boot 1: rc.5 reached the graphical login after ${i}s"
else
    bad "boot 1: rc.5 never said it was starting the graphical login in ${i}s -- nothing below is a statement about a greeter"
    tail -25 "$D/serial.log" 2>/dev/null | sed 's/^/        /'
    kill -KILL "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null
    finish
fi

# THE ORDERING ASSERTION, AND IT IS THE WHOLE ARCHITECTURAL CLAIM ON ONE LINE.
# `[rc.5] desktop backdrop started` must NOT be in the log yet. It is the
# first session program rc.5 starts, and PID 1's echo is the one message on
# this machine that is guaranteed to reach the serial line once the compositor
# has the framebuffer.
if grep -aq 'desktop backdrop started' "$D/serial.log"; then
    bad "boot 1: the desktop backdrop was ALREADY started when the greeter came up -- rc.5 is not blocking, and the greeter is a curtain over a session that exists"
else
    ok "boot 1: the desktop backdrop has NOT been started at the moment the greeter presents -- rc.5 is blocked in it"
fi
if grep -aq 'panel started' "$D/serial.log"; then
    bad "boot 1: the panel was ALREADY started when the greeter came up"
else
    ok "boot 1: and neither has the panel"
fi

sleep 8
if _shot greeter && _geom_from greeter; then
    ok "boot 1: a screendump was taken (${GB_W}x${GB_H}); the greeter's panel is derived at ${BX},${BY}"
else
    bad "boot 1: no screendump -- there is no visual evidence of anything"
    kill -KILL "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null
    finish
fi

if _band_title greeter; then
    info "boot 1: the title band OCRs as: $(printf '%s' "$OCRTXT" | cut -c1-90)"
    if printf '%s' "$OCRTXT" | grep -qi 'hamnix'; then
        ok "boot 1: THE MACHINE IS ASKING WHO YOU ARE -- the greeter's title is on the screen before any session program has been started"
    else
        bad "boot 1: the title band does not read the greeter's title (OCR: '$OCRTXT')"
    fi
    _ocr_control "boot 1 title"
else
    bad "boot 1: the title band could not be OCR'd at all"
fi
if _band_status greeter; then
    info "boot 1: the status band OCRs as: $(printf '%s' "$OCRTXT" | cut -c1-90)"
    if printf '%s' "$OCRTXT" | grep -qi 'password'; then
        ok "boot 1: and it is asking for a password"
    else
        bad "boot 1: the status band does not mention a password (OCR: '$OCRTXT')"
    fi
    _ocr_control "boot 1 status"
else
    bad "boot 1: the status band could not be OCR'd"
fi

# Give the greeter the keyboard. It is the only window on the screen and its
# first scene commit raises and focuses it, so this is belt and braces -- but
# wsysd gates keys on focus and a gate that assumed focus would be measuring
# an assumption.
click $(( GB_W / 2 )) $(( GB_H / 2 ))
sleep 2

# ---- ARM A: an account that does not exist ------------------------------
info "boot 1 / ARM A: typing an account that is not on this machine"
Q type "$JUNKUSER"; sleep 1; Q key ret; sleep 1
Q type "$JUNKPASS"; sleep 1; Q key ret
sleep 6
_shot junk
if _band_status junk; then
    info "boot 1 / ARM A: the status band OCRs as: $(printf '%s' "$OCRTXT" | cut -c1-90)"
    if printf '%s' "$OCRTXT" | grep -qi 'incorrect'; then
        ok "boot 1 / ARM A: an account that does not exist is REFUSED, and the greeter says so"
    else
        bad "boot 1 / ARM A: the greeter did not report a refusal for a nonexistent account (OCR: '$OCRTXT')"
    fi
    _ocr_control "boot 1 / ARM A"
else
    bad "boot 1 / ARM A: the status band could not be OCR'd after the junk attempt"
fi
if _band_title junk && printf '%s' "$OCRTXT" | grep -qi 'hamnix'; then
    ok "boot 1 / ARM A: and the greeter is STILL on the screen -- a refusal does not let anybody past"
else
    bad "boot 1 / ARM A: the greeter's title is gone after a REFUSED attempt (OCR: '$OCRTXT')"
fi

# ---- ARM B: the real account, the wrong password ------------------------
info "boot 1 / ARM B: typing the real account with the wrong password"
Q type "$USERNAME"; sleep 1; Q key ret; sleep 1
Q type "$WRONGPASS"; sleep 1; Q key ret
sleep 6
_shot wrong
if _band_status wrong; then
    info "boot 1 / ARM B: the status band OCRs as: $(printf '%s' "$OCRTXT" | cut -c1-90)"
    if printf '%s' "$OCRTXT" | grep -qi 'incorrect'; then
        ok "boot 1 / ARM B: THE REAL ACCOUNT'S WRONG PASSWORD IS REFUSED -- so the check is on the secret and not on the name"
    else
        bad "boot 1 / ARM B: the greeter did not report a refusal for the real account's wrong password (OCR: '$OCRTXT')"
    fi
    _ocr_control "boot 1 / ARM B"
else
    bad "boot 1 / ARM B: the status band could not be OCR'd after the wrong password"
fi
if grep -aq 'desktop backdrop started' "$D/serial.log"; then
    bad "boot 1 / ARM B: a session program started after TWO REFUSED passwords"
else
    ok "boot 1 / ARM B: still no session program after two refusals -- the serial log has no backdrop line"
fi

# ---- ARM C: the real account, the right password ------------------------
info "boot 1 / ARM C: typing the real account with the RIGHT password"
Q type "$USERNAME"; sleep 1; Q key ret; sleep 1
Q type "$UPASS"; sleep 1; Q key ret

i=0
while [ "$i" -lt 120 ]; do
    sleep 2; i=$((i+2))
    grep -aq 'HGT-RC5-RETURNED' "$D/serial.log" 2>/dev/null && break
done
if grep -aq 'HGT-RC5-RETURNED' "$D/serial.log"; then
    ok "boot 1 / ARM C: the right password ADMITS -- rc.5 came back and the boot continued after ${i}s"
else
    bad "boot 1 / ARM C: rc.5 never returned in ${i}s. The right password did not get past the greeter"
    tail -25 "$D/serial.log" | sed 's/^/        /'
fi
if grep -aq 'authenticated -- starting the session' "$D/serial.log"; then
    ok "boot 1 / ARM C: and rc.5 took the AUTHENTICATED branch"
else
    bad "boot 1 / ARM C: rc.5 did not print its authenticated line"
fi
if grep -aq 'NO SESSION' "$D/serial.log"; then
    bad "boot 1 / ARM C: rc.5 printed its NO SESSION refusal -- the recipe did not come back with hamsession_ok"
else
    ok "boot 1 / ARM C: rc.5 did NOT print its NO SESSION refusal"
fi
if grep -aq 'desktop backdrop started' "$D/serial.log"; then
    ok "boot 1 / ARM C: the session's first program started AFTER authentication and not before -- the same line that was absent twice above"
else
    bad "boot 1 / ARM C: the desktop backdrop never started even after authentication"
fi

sleep 20
_shot session
if _band_title session; then
    info "boot 1 / ARM C: the same title band now OCRs as: $(printf '%s' "$OCRTXT" | cut -c1-90)"
    if printf '%s' "$OCRTXT" | grep -qi 'hamnix'; then
        bad "boot 1 / ARM C: the greeter is STILL on the screen after authentication (OCR: '$OCRTXT')"
    else
        ok "boot 1 / ARM C: THE GREETER IS GONE from the crop that carried it twice -- the same instrument, the same band, the opposite reading"
    fi
    _ocr_control "boot 1 / ARM C"
else
    bad "boot 1 / ARM C: the title band could not be OCR'd after authentication"
fi

# Wait for the machine to power itself off. Killing it is a power cut and ext4
# would not have committed the censuses this gate is about to read.
i=0
while kill -0 "$QPID" 2>/dev/null && [ "$i" -lt 300 ]; do sleep 5; i=$((i+5)); done
if kill -0 "$QPID" 2>/dev/null; then
    bad "boot 1: the machine did not power itself off in ${i}s -- a MISSING file below could be a power cut rather than a missing write"
    printf 'quit\n' | timeout 10 socat - "UNIX-CONNECT:$MON" >/dev/null 2>&1
    sleep 2
    kill -TERM "$QPID" 2>/dev/null; sleep 1; kill -KILL "$QPID" 2>/dev/null
else
    ok "boot 1: the machine powered itself off cleanly"
fi
wait "$QPID" 2>/dev/null

# =========================================================================
# 3. THE CENSUS, READ OFF THE UNMOUNTED EXT4
# =========================================================================
say "3 -- four readings by one instrument: was anything of the session there before the password was right"
carve "$NVME" 2 || { bad "cannot carve the installed root partition after boot 1"; finish; }

declare -A CENSUS
for pair in "pre:/var/lib/hamgreet-ps.pre" \
            "denied:/var/lib/hamgreet-ps.denied" \
            "ok:/var/lib/hamgreet-ps.ok" \
            "after:/var/lib/hgt-ps.after"; do
    tag="${pair%%:*}"; path="${pair#*:}"
    f="$W/census-$tag.txt"
    if fs_dump "$PART" "$path" "$f"; then
        CENSUS[$tag]="$f"
        ok "the '$tag' census is on the disk and reads back ($(wc -l <"$f") rows)"
    else
        CENSUS[$tag]=""
        bad "$path is NOT on the disk -- the '$tag' reading was never taken"
    fi
done

# THE CONTROL COMES FIRST. If the instrument cannot see a session program when
# one is certainly running, every absence below is worthless and this gate
# stops.
AFTER="${CENSUS[after]:-}"
if [ -z "$AFTER" ]; then
    bad "there is no AFTER census -- the instrument was never shown to be able to see a session program, so no absence above or below means anything"
    finish
fi
ctl_ok=1
for prog in hamdesktop hampanelscene; do
    if grep -q "$prog" "$AFTER"; then
        ok "CONTROL: the AFTER census names $prog -- the instrument CAN see a session program when one is there"
    else
        bad "CONTROL FAILED: the AFTER census does not name $prog, which was certainly running. The instrument is blind and every absence below is meaningless"
        ctl_ok=0
    fi
done
[ "$ctl_ok" = 1 ] || { sed 's/^/        /' "$AFTER" | head -30; finish; }

for tag in pre denied ok after; do
    f="${CENSUS[$tag]:-}"
    [ -n "$f" ] || continue
    if grep -q 'CENSUS-TRUNCATED' "$f"; then
        bad "the '$tag' census OVERFLOWED its buffer -- it is a partial listing, and a partial listing is indistinguishable from the absence it would be used to prove"
    else
        ok "the '$tag' census is complete (no CENSUS-TRUNCATED marker)"
    fi
done

# Each pre-authentication reading must be a REAL reading, not an empty file
# that happens to lack the names being looked for.
for tag in pre denied ok; do
    f="${CENSUS[$tag]:-}"
    [ -n "$f" ] || continue
    if grep -q 'wsysd' "$f" && grep -q 'hamgreet' "$f"; then
        ok "the '$tag' census names wsysd AND hamgreet -- it is a reading of a live process table, not an empty file"
    else
        bad "the '$tag' census does not name both wsysd and hamgreet, so it is not a reading of the machine at that moment"
        sed 's/^/        /' "$f" | head -20
    fi
done

# THE ABSENCE.
for tag in pre denied ok; do
    f="${CENSUS[$tag]:-}"
    [ -n "$f" ] || continue
    for prog in hamdesktop hampanelscene hamtermscene; do
        if grep -q "$prog" "$f"; then
            bad "THE '$tag' CENSUS NAMES $prog -- a session program existed before anybody was authenticated"
        else
            ok "the '$tag' census has no $prog in it"
        fi
    done
done

# =========================================================================
# 4. THE GREETER'S OWN TRACE, AND THE RECIPE IT WROTE
# =========================================================================
say "4 -- what the greeter says it did, and the one file that authorises a session"
if fs_dump "$PART" /var/lib/hamgreet.trace "$W/trace.txt"; then
    ok "/var/lib/hamgreet.trace is on the disk"
    info "the trace:"
    sed 's/^/          /' "$W/trace.txt"
    for want in presenting DENIED authenticated; do
        if grep -q "$want" "$W/trace.txt"; then
            ok "the trace records '$want'"
        else
            bad "the trace does not record '$want'"
        fi
    done
    n="$(grep -c 'DENIED' "$W/trace.txt")"
    if [ "${n:-0}" -ge 2 ]; then
        ok "the trace records $n refusals -- both arms above reached /dev/auth and were turned away"
    else
        bad "the trace records ${n:-0} refusals; this gate drove two"
    fi
else
    bad "/var/lib/hamgreet.trace is not on the disk -- the greeter kept no record of what it did"
fi

if fs_dump "$PART" /var/lib/hamsession.rc "$W/recipe.txt"; then
    ok "/var/lib/hamsession.rc is on the disk -- the greeter wrote the session recipe"
    info "the recipe: $(grep -v '^#' "$W/recipe.txt" | tr '\n' ' ')"
    if grep -q 'hamsession_ok = 1' "$W/recipe.txt"; then
        ok "the recipe sets hamsession_ok = 1, which is the only thing that can start a session on this machine"
    else
        bad "the recipe does not set hamsession_ok = 1"
    fi
    if grep -q "hamsession_user='$USERNAME'" "$W/recipe.txt"; then
        ok "and it names $USERNAME -- the account that was TYPED, not one the machine chose"
    else
        bad "the recipe does not name $USERNAME"
    fi
    # THE SEAM. Not a claim that the session's root is constructed -- it is
    # not, today -- but that the stamp the constructed-root work will read is
    # on the graphical path as well as the tty one.
    if grep -q "HAMNIX_NEWSHELL_USER='$USERNAME'" "$W/recipe.txt"; then
        ok "and it stamps HAMNIX_NEWSHELL_USER -- the same per-session namespace seam login stamps on a tty, so the graphical session is not hardcoded to the machine's root"
    else
        bad "the recipe does not stamp HAMNIX_NEWSHELL_USER; the graphical path has no namespace seam"
    fi
else
    bad "/var/lib/hamsession.rc is not on the disk"
fi

# =========================================================================
# 5. WHOSE SESSION IS IT -- READ OFF THE DISK, NOTHING MOUNTED
# =========================================================================
say "5 -- the uid the verified /dev/auth fd resolved to, read off the ext4"
if fs_has "$PART" "/home/$USERNAME/.hamsession"; then
    ok "/home/$USERNAME/.hamsession is on the disk -- the greeter wrote it AFTER sys_setuid_auth"
    U="$(fs_uid "$PART" "/home/$USERNAME/.hamsession")"
    if [ "${U:-}" = 1001 ]; then
        ok "IT IS OWNED BY uid 1001 -- the greeter dropped to the account it authenticated, and the drop is read off the disk rather than asked of the machine"
    elif [ "${U:-}" = 0 ]; then
        bad "it is owned by uid 0. sys_setuid_auth did not take, and the greeter stayed root after saying yes"
    else
        bad "it is owned by uid ${U:-?}, which is neither the account nor root"
    fi
    fs_dump "$PART" "/home/$USERNAME/.hamsession" "$W/marker.txt" && \
        info "its contents: $(tr '\n' ' ' <"$W/marker.txt")"
    if grep -q "$USERNAME" "$W/marker.txt" 2>/dev/null; then
        ok "and it names $USERNAME"
    else
        bad "it does not name $USERNAME"
    fi
else
    bad "/home/$USERNAME/.hamsession is NOT on the disk -- either the drop failed or the marker was never written, and whose session this is has not been measured"
fi
rm -f "$PART"

# =========================================================================
# 6. BOOT 2 -- THE ANSWER MUST NOT OUTLIVE THE BOOT THAT EARNED IT
# =========================================================================
# /var/lib is on the root partition and survives a reboot. Section 4 just read
# /var/lib/hamsession.rc OFF THE DISK, so it is there, valid, and naming a real
# account. If hamgreet did not unlink it on entry, this boot would source last
# boot's answer and hand out a desktop without asking. This arm is a second
# invocation rather than an arm of boot 1 because REBOOTING is the thing it is
# about.
#
# This boot is NOT expected to power itself off -- rc.5 blocks in the greeter
# and the gate's rc waits. It is killed after the photograph, which is a power
# cut, which is why nothing is read off the disk after it.
say "6 -- boot 2: the same disk, with a valid recipe already on it"

D="$W/boot2"; rm -rf "$D"; mkdir -p "$D/shots"
MON="$D/mon.sock"; QMP="$D/qmp.sock"
cp /usr/share/OVMF/OVMF_VARS_4M.fd "$D/OVMF_VARS.fd"
qemu-system-x86_64 \
    -m 2048 -smp 2 -no-reboot \
    -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
    -drive "if=pflash,format=raw,unit=1,file=$D/OVMF_VARS.fd" \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -display none -vga std \
    -serial "file:$D/serial.log" \
    -enable-kvm -cpu host \
    -monitor "unix:$MON,server,nowait" \
    -qmp "unix:$QMP,server,nowait" \
    -device virtio-keyboard-pci -device virtio-tablet-pci \
    -drive "file=$NVME,if=none,format=raw,id=nvme0" \
    -device nvme,drive=nvme0,serial=HGTTGT \
    >"$D/qemu.out" 2>&1 &
QPID2=$!
reap_add "$QPID2"
i=0
while [ "$i" -lt 300 ]; do
    sleep 2; i=$((i+2))
    grep -aq "$GREETLINE" "$D/serial.log" 2>/dev/null && break
    st=$(awk '{print $3}' "/proc/$QPID2/stat" 2>/dev/null)
    case "${st:-X}" in Z|X) break ;; esac
done
if grep -aq 'HGT-PHASE-2' "$D/serial.log" 2>/dev/null; then
    ok "boot 2: this is the second boot of the same disk (the phase file from boot 1 survived)"
else
    bad "boot 2: the machine did not report phase 2, so this may not be a second boot of a disk that has already authenticated"
fi
if grep -aq "$GREETLINE" "$D/serial.log" 2>/dev/null; then
    ok "boot 2: rc.5 reached the graphical login AGAIN after ${i}s"
else
    bad "boot 2: rc.5 never reached the graphical login in ${i}s"
    tail -25 "$D/serial.log" 2>/dev/null | sed 's/^/        /'
fi
if grep -aq 'HGT-RC5-RETURNED' "$D/serial.log" 2>/dev/null; then
    bad "boot 2: RC5 RETURNED WITHOUT ANYBODY TYPING ANYTHING. Last boot's session recipe authorised this boot -- the greeter did not unlink it"
else
    ok "boot 2: rc.5 has NOT returned, so nothing on this boot has been authorised yet"
fi
if grep -aq 'desktop backdrop started' "$D/serial.log" 2>/dev/null; then
    bad "boot 2: the session started on a boot where nobody typed a password"
else
    ok "boot 2: no session program has started on a boot where nobody typed a password"
fi
sleep 8
if _shot boot2 && _geom_from boot2 && _band_title boot2; then
    info "boot 2: the title band OCRs as: $(printf '%s' "$OCRTXT" | cut -c1-90)"
    if printf '%s' "$OCRTXT" | grep -qi 'hamnix'; then
        ok "boot 2: THE MACHINE ASKS AGAIN. A valid recipe on the disk did not get anybody in"
    else
        bad "boot 2: the greeter is not on the screen (OCR: '$OCRTXT')"
    fi
    _ocr_control "boot 2 title"
else
    bad "boot 2: could not photograph or OCR the screen"
fi
printf 'quit\n' | timeout 10 socat - "UNIX-CONNECT:$MON" >/dev/null 2>&1
sleep 2
kill -TERM "$QPID2" 2>/dev/null; sleep 1; kill -KILL "$QPID2" 2>/dev/null
wait "$QPID2" 2>/dev/null

# =========================================================================
# 7. WHAT THIS FILE ITSELF MUST NOT DO
# =========================================================================
say "7 -- the gate's own hygiene"
# THE MACHINE'S rc IS WHAT THIS GATE PUT ON THE MACHINE, and it is the one
# place a gate could cheat: an rc that wrote a recipe, or started hamdesktop
# itself, would produce every green above with no greeter involved at all. So
# the STAGED FILE is read back and required not to contain either. This is the
# same self-check pointer_launch_uid.sh applies to the launch queue.
RCFILE="$EXTRA/etc/rc.boot.machine"
if [ -f "$RCFILE" ]; then
    if grep -q 'hamsession' "$RCFILE"; then
        bad "the machine's rc mentions the session recipe -- it could have authorised a session without the greeter"
    else
        ok "the machine's rc never mentions the session recipe; only /bin/hamgreet writes it"
    fi
    if grep -qE 'hamdesktop|hampanelscene|/dev/auth' "$RCFILE"; then
        bad "the machine's rc starts a session program or touches /dev/auth itself"
    else
        ok "the machine's rc starts no session program and never touches /dev/auth -- every window above was started by the shipped /etc/rc.d/rc.5, and the only thing that authenticated was a keystroke sent over QMP"
    fi
else
    info "the staged rc is not present in this work dir (HGT_REUSE=1 run); the hygiene check could not run"
fi

finish
