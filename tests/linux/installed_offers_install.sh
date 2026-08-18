#!/usr/bin/env bash
#
# tests/linux/installed_offers_install.sh — AN INSTALLED MACHINE MUST NOT
# OFFER TO INSTALL ITSELF.
#
# REGISTRATION. This gate is ON-DEMAND: not in ci_battery_manifest.txt because
# it builds a medium, installs a machine and then boots that machine twice
# under OVMF -- three QEMU boots and a full image build, far past the battery's
# per-shard budget.
#
# THE DEFECT THIS EXISTS FOR, MEASURED 2026-08-18
# ===============================================
# `/etc/installer-medium` is the marker four programs use to decide whether to
# surface the `Install Hamnix` launcher:
#
#   user/hamdesktop.ad      _desk_is_live()
#   user/hampanelscene.ad   _am_is_live()
#   user/hamappmenu.ad      _dd_is_live()
#   user/hamsoftware.ad     _reg_is_live()
#
# Each opens that path and treats "it opened" as "I am running from
# installation media". The file itself says, in its own text, "an installed
# system (which never carries it)".
#
# IT CARRIES IT. `user/hlinstall.ad` copies /etc, /usr, /boot, /bin, /lib,
# /lib64, /var, /root and /home from the live root onto the target wholesale
# (the copy_top list), and the marker is a file in /etc. So the marker means
# "installation media once touched this filesystem", not "I am running from
# installation media", and an installed machine offers to erase itself. The
# erase confirmation guards the LAST page of the wizard; it does not guard the
# offer.
#
# No package owns the marker either -- it is not in any package's file list --
# so `hpm update` can never remove it from a machine that has one.
#
# WHAT THIS GATE MEASURES, AND WHAT IS A CONTROL
# ==============================================
#   1. HOST, off the installed ext4 with debugfs, nothing mounted and nothing
#      written back: the installed root does NOT carry /etc/installer-medium.
#      INSTRUMENT CONTROL, RUN: the same reader, on the same disk, must find
#      /etc/hamnix-release (a file that is certainly there) -- an empty answer
#      from a broken reader would otherwise read as a pass.
#   2. BOOT THE INSTALLED DISK to its desktop and READ THE PICTURE: neither the
#      desktop icon column nor the opened Applications menu may say "Install".
#      OCR CONTROLS, RUN, in the same boot and the same crops: the panel must
#      read "Applications", the icon column must read back real launcher
#      labels, and the OCR must NOT report a string that is certainly not on
#      the screen.
#      WHERE THE DISCRIMINATION ACTUALLY COMES FROM, said plainly: the DESKTOP
#      ICON COLUMN. Measured on both machines, the opened Applications menu
#      renders its six CATEGORY rows (Accessories / Internet / Office / Games /
#      Sound & Video / System / Settings) and not their contents, so the menu
#      arm proves a menu opened and reads what is on it -- it does not walk one
#      level deeper into System, where the launcher would sit. The icon column
#      is the crop that read `Install Ramni` (OCR for `Install Hamnix`) on the
#      defective machine and does not read it on the fixed one.
#
#   3. THE NEGATIVE CONTROL IS A THIRD BOOT AND IT RUNS: the LIVE MEDIUM,
#      through the identical instrument and the identical crops, MUST read
#      "Install". A gate that can only report absence cannot tell an installed
#      machine from a camera with the lens cap on.
#
# WHERE THIS STANDS, MEASURED 2026-08-18 on the dev host, two full runs:
#
#   * WITH user/hlinstall.ad's removal block reverted (the tree as it was):
#     17 PASSED, 7 FAILED. The installed machine's own desktop icon column
#     OCR'd to `... Word Processor L Install Ramni` -- the same string the live
#     medium's does, off a machine with no medium attached.
#   * WITH the fix: 24 PASSED, 0 FAILED, and the negative control still reads
#     `Install Ramni` on the medium through the identical crop.
#
# Usage: tests/linux/installed_offers_install.sh
#   INSTOFFER_WORK=<dir>    work dir (default ~/.hamnix-build/instoffer)
#   INSTOFFER_REUSE=1       reuse an already-built medium and installed disk
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

. tests/linux/reap.sh
reap_on_exit

W="${INSTOFFER_WORK:-$HOME/.hamnix-build/instoffer}"
mkdir -p "$W"
export TMPDIR="$W/tmp"; mkdir -p "$TMPDIR"

LIVE="$W/live-usb.img"          # the medium, with an rc that drives the install
STOCK="$W/live-stock.img"       # the SAME medium with its SHIPPED rc, for the
                                # negative control: it boots to a desktop that
                                # is genuinely supposed to offer Install Hamnix
NVME="$W/target-nvme.img"
PART="$W/part.img"
SCREEN_W=1280
SCREEN_H=800
QMP_INPUT="$PROJ_ROOT/tests/linux/qmp_input.py"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  PASS  $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL  $*"; }
info() { echo "        $*"; }
say()  { echo; echo "== $* =="; }
finish() { printf '\n%d PASSED, %d FAILED\n' "$PASS" "$FAIL"
           [ "$FAIL" = 0 ] && exit 0 || exit 1; }

for t in qemu-system-x86_64 socat python3 tesseract convert; do
    command -v "$t" >/dev/null || { echo "INCONCLUSIVE: need $t"; exit 2; }
done
for t in /sbin/debugfs /sbin/sfdisk; do
    [ -x "$t" ] || { echo "INCONCLUSIVE: need $t"; exit 2; }
done
[ -f "$QMP_INPUT" ] || { echo "INCONCLUSIVE: need tests/linux/qmp_input.py"; exit 2; }
[ -f /usr/share/OVMF/OVMF_CODE_4M.fd ] || { echo "INCONCLUSIVE: need OVMF"; exit 2; }

# ---- reading an ext4 without mounting it ---------------------------------
# Same idiom as tests/linux/install_from_usb.sh: carve the partition out with
# dd and read it with debugfs. Nothing is mounted and nothing is written back,
# so no assertion here can be an artefact of this gate.
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
fs_has() { /sbin/debugfs -R "stat $2" "$1" 2>/dev/null | grep -q '^Inode:'; }
# `dump` and not `cat`: debugfs's `cat` truncates long files on this host, and a
# short read of /etc/passwd is exactly the shape of the defect below.
fs_dump() { rm -f "$3"; /sbin/debugfs -R "dump $2 $3" "$1" >/dev/null 2>&1; [ -s "$3" ]; }

# =========================================================================
# 0. THE MEDIUM, AND AN INSTALL ONTO A BLANK DISK
# =========================================================================
say "0 -- the medium, and one install onto a blank virtual disk"

CHAN="${HAMLINUX_HPM_CHANNEL:-build/repo/linux}"
if [ ! -f "$CHAN/index.json" ]; then
    echo "INCONCLUSIVE: no channel at $CHAN/index.json. Run:"
    echo "  python3 scripts/hamlinux_packages.py --out build/repo --version <v> --channel linux"
    exit 2
fi

# THE MEDIUM'S OWN rc RUNS THE INSTALL ENGINE AND NOTHING ELSE. It is staged
# only into the LIVE root's /etc/rc.boot, which user/hlinstall.ad OVERWRITES on
# the target with its three-line indirection -- so the installed machine boots
# the shipped rc and the shipped desktop, not anything this gate wrote.
cat >"$W/rc.install" <<'RCEOF'
ln -s /dev/console /dev/cons
echo 'INSTOFFER-LIVE: the medium booted'
echo 'INSTOFFER-LIVE: starting the installer'
install --auto /dev/nvme0n1 --hostname hamlaptop --user hamgateusr --user-pass hamgatepw --root-pass root
echo 'INSTOFFER-LIVE: the installer returned'
echo 'INSTOFFER-LIVE-DONE'
sleep 8
poweroff
RCEOF

if [ "${INSTOFFER_REUSE:-0}" = 1 ] && [ -f "$LIVE" ] && [ -f "$STOCK" ] && [ -s "$NVME" ]; then
    info "reusing $LIVE, $STOCK and $NVME (INSTOFFER_REUSE=1)"
else
    info "building the medium (four passes; this is the slow part)"
    scripts/hamlinux_image.sh >"$W/img1.log" 2>&1 || {
        bad "lean image build -- see $W/img1.log"; finish; }
    scripts/hamlinux_disk.sh "$W/seed.img" 3G >"$W/disk1.log" 2>&1 || {
        bad "seed disk build -- see $W/disk1.log"; finish; }
    HAMLINUX_INSTALLER=1 scripts/hamlinux_image.sh >"$W/img2.log" 2>&1 || {
        bad "installer image build -- see $W/img2.log"; finish; }
    HAMLINUX_DISK_RC="$W/rc.install" scripts/hamlinux_disk.sh "$LIVE" 4G \
        >"$W/disk2.log" 2>&1 || { bad "live medium build -- see $W/disk2.log"; finish; }
    # THE SAME IMAGE ROOT, PACKED AGAIN WITH NOTHING SUBSTITUTED. This is the
    # medium a person is handed, and it is the negative control's machine.
    scripts/hamlinux_disk.sh "$STOCK" 4G \
        >"$W/disk3.log" 2>&1 || { bad "stock medium build -- see $W/disk3.log"; finish; }

    rm -f "$NVME"; truncate -s 6G "$NVME"
    if [ "$(head -c 1048576 "$NVME" | tr -d '\0' | wc -c)" = 0 ]; then
        ok "the NVMe target is all zeroes before the install"
    else
        bad "the NVMe target is not blank"
    fi
fi
[ -s "$LIVE" ] || { bad "no live medium at $LIVE"; finish; }

# ---- the install boot: no display, serial only ---------------------------
INSTPID=""
if [ "${INSTOFFER_REUSE:-0}" != 1 ] || [ ! -f "$W/install/serial.log" ]; then
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
        -device nvme,drive=nvme0,serial=INSTOFFERTGT \
        -drive "file=$LIVE,if=none,format=raw,id=usbstick" \
        -device usb-storage,bus=xhci.0,drive=usbstick,bootindex=0 \
        >"$d/qemu.out" 2>&1 &
    INSTPID=$!
    reap_add "$INSTPID"
    i=0
    while kill -0 "$INSTPID" 2>/dev/null && [ "$i" -lt 900 ]; do sleep 5; i=$((i+5)); done
    kill -TERM "$INSTPID" 2>/dev/null; sleep 2; kill -KILL "$INSTPID" 2>/dev/null
    wait "$INSTPID" 2>/dev/null
    INSTPID=""
fi
if grep -aq 'INSTOFFER-LIVE-DONE' "$W/install/serial.log" 2>/dev/null; then
    ok "the installer ran to completion on the live medium"
else
    bad "the install boot never printed INSTOFFER-LIVE-DONE -- nothing below is a statement about an installed machine"
    tail -20 "$W/install/serial.log" 2>/dev/null | sed 's/^/        /'
    finish
fi

# =========================================================================
# 1. THE MARKER, READ OFF THE INSTALLED FILESYSTEM
# =========================================================================
say "1 -- what the installed root actually carries (debugfs, nothing mounted)"
carve "$NVME" 2 || { bad "cannot carve the installed root partition"; finish; }

# INSTRUMENT CONTROL FIRST. An absent-file answer from a reader that answers
# 'absent' to everything is not a measurement.
if fs_has "$PART" /etc/hamnix-release; then
    ok "the reader finds /etc/hamnix-release on the installed root, so an 'absent' answer below is a reading and not a broken reader"
else
    bad "the reader cannot find /etc/hamnix-release on the installed root -- it is not working, and no absence it reports means anything"
    finish
fi
if fs_has "$PART" /etc/installer-medium; then
    bad "THE INSTALLED ROOT CARRIES /etc/installer-medium. Every desktop program that probes it will believe this machine is installation media, and will offer 'Install Hamnix' on a machine that will erase itself if the offer is accepted"
else
    ok "the installed root carries NO /etc/installer-medium"
fi

# ---- AND THE ACCOUNT THE WIZARD ASKED FOR ------------------------------
# Not the offer, but found while measuring it and on the same disk, so it is
# asserted here rather than left for somebody to rediscover.
#
# MEASURED 2026-08-18 on a fresh install at tip AND on the installed disk left
# by tests/linux/install_from_usb.sh the day before: /etc/passwd, /etc/group
# and /etc/shadow on the target were each EXACTLY 962 bytes, containing the
# first 480 bytes of the shipped file, a newline, the same 480 bytes again, and
# a newline. No account line at all -- not the wizard's user, not `live`, not
# `hostowner`, and no password hash for anybody.
#
# The mechanism is user/hlinstall.ad's append_line, and it is two faults in one
# function: it reads the existing file into the SAME global `line_buf` its
# caller built the new line in (so the "line" it appends is the file's own
# first bytes), and it reads at most 480 of them (so anything longer is
# truncated). The number is not a guess -- 480 + 1 + 480 + 1 = 962 exactly.
USERNAME=hamgateusr
for f in passwd group shadow; do
    if fs_dump "$PART" "/etc/$f" "$W/target-$f"; then
        SZ=$(stat -c%s "$W/target-$f")
        if python3 - "$W/target-$f" <<'PY'
import sys
b = open(sys.argv[1], "rb").read()
h = (len(b) - 2) // 2
sys.exit(0 if len(b) > 2 and b[:h] == b[h + 1:2 * h + 1] else 1)
PY
        then
            bad "the installed /etc/$f is its own first half written TWICE ($SZ bytes) -- hlinstall's append_line rewrote it from the buffer its caller's line was in, and truncated it"
        else
            ok "the installed /etc/$f is not the doubled-header shape ($SZ bytes)"
        fi
    else
        bad "could not read /etc/$f off the installed root"
    fi
done
if grep -q "^$USERNAME:" "$W/target-passwd" 2>/dev/null; then
    ok "the installed /etc/passwd carries the account the wizard was told to create ($USERNAME)"
else
    bad "the installed /etc/passwd has NO $USERNAME line -- the installer was given --user $USERNAME and the machine it produced has no such account"
fi
if grep -q '^live:' "$W/target-passwd" 2>/dev/null; then
    ok "and it still carries the shipped accounts (live), which the desktop session runs as"
else
    bad "the installed /etc/passwd has lost the shipped accounts too -- there is no 'live' line, and the DE session's uid 1001 resolves to nothing"
fi

# And the same reader on the MEDIUM, where the marker MUST be there. This is
# the other half of the control: the reader is shown able to answer both ways
# on the same run.
carve "$STOCK" 2 || { bad "cannot carve the live medium's root partition"; finish; }
if fs_has "$PART" /etc/installer-medium; then
    ok "the same reader finds /etc/installer-medium on the LIVE MEDIUM, where it belongs"
else
    bad "the reader does not find /etc/installer-medium on the live medium either -- it answers 'absent' to everything and section 1's result is meaningless"
fi
# THE ACCOUNT ASSERTIONS' OWN CONTROL, AND IT RUNS. The medium's /etc/passwd is
# the file the copy starts from: it must carry `live` (so the reader really
# reads account files) and must NOT carry the wizard's user (so finding that
# name on the target means the INSTALL put it there, and not the image).
if fs_dump "$PART" /etc/passwd "$W/medium-passwd"; then
    grep -q '^live:' "$W/medium-passwd" \
        && ok "the medium's own /etc/passwd carries 'live', so the account reader reads accounts" \
        || bad "the medium's /etc/passwd has no 'live' line -- the account reader is not reading a passwd file and the target assertions above mean nothing"
    grep -q "^$USERNAME:" "$W/medium-passwd" \
        && bad "the medium ALREADY carries a $USERNAME account -- finding it on the target would prove nothing about the installer" \
        || ok "and the medium does NOT carry $USERNAME, so that name on the target can only have come from the install"
else
    bad "could not read /etc/passwd off the live medium"
fi
rm -f "$PART"

# =========================================================================
# 2 and 3. WHAT A PERSON SEES, ON BOTH MACHINES, THROUGH ONE INSTRUMENT
# =========================================================================
QPID=""; D=""
kill_guest() {
    [ -n "$QPID" ] || return 0
    printf 'quit\n' | timeout 10 socat - "UNIX-CONNECT:$D/mon.sock" >/dev/null 2>&1
    sleep 2
    kill -TERM "$QPID" 2>/dev/null; sleep 1; kill -KILL "$QPID" 2>/dev/null
    wait "$QPID" 2>/dev/null
    QPID=""
}

# boot_gui <dir> <mode: installed|medium> <source image>
# The source image is copied IN HERE, after the directory is made: QEMU must be
# free to write to the disk it boots, and the artefacts are read-only evidence.
# (An earlier revision copied it in from the caller and then `rm -rf`'d the
# directory here, which is why every GUI boot failed with "Could not open
# disk.img" -- caught by the boot check, not by a green run.)
boot_gui() {
    D="$1"; local mode="$2" src="$3"
    rm -rf "$D"; mkdir -p "$D/shots"
    cp "$src" "$D/disk.img" || { bad "could not copy $src for the boot"; return 1; }
    cp /usr/share/OVMF/OVMF_VARS_4M.fd "$D/OVMF_VARS.fd"
    : >"$D/serial.log"
    local args=(
        -m 2048 -smp 2 -no-reboot
        -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd
        -drive "if=pflash,format=raw,unit=1,file=$D/OVMF_VARS.fd"
        -netdev user,id=n0 -device virtio-net-pci,netdev=n0
        -display none -vga std
        -serial "file:$D/serial.log"
        -enable-kvm -cpu host
        -monitor "unix:$D/mon.sock,server,nowait"
        -qmp "unix:$D/qmp.sock,server,nowait"
        -device virtio-keyboard-pci -device virtio-tablet-pci
        -device qemu-xhci,id=xhci
    )
    if [ "$mode" = installed ]; then
        # THE INSTALLED MACHINE, ON ITS OWN. No medium is attached: whatever it
        # believes about installation media, it believes from its own disk.
        args+=(-drive "file=$D/disk.img,if=none,format=raw,id=nvme0"
               -device nvme,drive=nvme0,serial=INSTOFFERTGT)
    else
        args+=(-drive "file=$D/disk.img,if=none,format=raw,id=usbstick"
               -device usb-storage,bus=xhci.0,drive=usbstick,bootindex=0)
    fi
    qemu-system-x86_64 "${args[@]}" >"$D/qemu.out" 2>&1 &
    QPID=$!
    reap_add "$QPID"
    info "qemu pid $QPID, serial $D/serial.log"
}

wait_for_desktop() {
    local limit="$1" i=0 st
    while [ "$i" -lt "$limit" ]; do
        sleep 2; i=$((i+2))
        grep -aq 'rc\.boot: up' "$D/serial.log" 2>/dev/null && { BOOT_SECS=$i; return 0; }
        # A ZOMBIE ANSWERS YES TO kill -0, so liveness comes from the state
        # letter in /proc/<pid>/stat.
        st=$(awk '{print $3}' "/proc/$QPID/stat" 2>/dev/null)
        case "${st:-X}" in Z|X) BOOT_SECS=$i; return 1 ;; esac
    done
    BOOT_SECS=$i; return 1
}

hmp() { printf '%s\n' "$1" | timeout 20 socat - "UNIX-CONNECT:$D/mon.sock" 2>/dev/null; }
qi()  { timeout 60 python3 "$QMP_INPUT" "$D/qmp.sock" "$@" 2>&1; }

shot() {
    local p="$D/shots/$1.ppm" prev=-1 n i=0
    rm -f "$p"
    hmp "screendump $p" >/dev/null
    while [ "$i" -lt 40 ]; do
        sleep 0.25; i=$((i+1))
        n=$(stat -c%s "$p" 2>/dev/null || echo 0)
        [ "$n" -gt 0 ] && [ "$n" = "$prev" ] && break
        prev="$n"
    done
    [ -s "$p" ] || return 1
    printf '%s' "$p"
}

# ocr <ppm> <base> <geom> -- 300% upscale, the same recipe the wizard gate uses
# for this 8-px bitmap font.
ocr() {
    convert "$1" -crop "$3" +repage -colorspace Gray -resize 300% \
        -sharpen 0x1 "$2.png" 2>/dev/null || return 1
    tesseract "$2.png" "$2" --psm 6 >/dev/null 2>&1 || return 1
    [ -s "$2.txt" ]
}

# THE CROPS. 1280x800. The panel strip is the top 28 rows; the desktop icon
# column is the left 200 px below it; the Applications menu drops from the
# panel's left edge. Read off a screendump before use.
PANEL_GEOM="${SCREEN_W}x28+0+0"
ICONS_GEOM="220x760+0+28"
MENU_GEOM="320x600+0+28"

# look_at <tag> <expect: offered|hidden> -- one machine, read as text.
# Sets LOOK_ICONS / LOOK_MENU to what was read.
look_at() {
    local tag="$1" expect="$2" p pm
    sleep 8
    p=$(shot "${tag}_desktop") || { bad "$tag: no screendump could be taken -- nothing about this machine's picture was measured"; return 1; }
    info "$tag: screendump $(stat -c%s "$p") bytes"

    # --- the OCR's own controls, in this boot, on these crops -------------
    if ocr "$p" "$D/shots/${tag}_panel" "$PANEL_GEOM"; then
        local panel; panel=$(cat "$D/shots/${tag}_panel.txt")
        info "$tag panel OCR: $(printf '%s' "$panel" | tr '\n' '|' | cut -c1-140)"
        printf '%s' "$panel" | grep -qi 'applic' \
            && ok "$tag: the panel reads 'Applications', so this machine reached a desktop and the OCR can read it" \
            || bad "$tag: the panel does not read 'Applications' -- either no desktop or no working OCR, and the install-offer reading below is not trustworthy"
        printf '%s' "$panel" | grep -qi 'Step 5 of 5' \
            && bad "$tag: the panel OCR reports text that is certainly not on the screen -- it matches anything" \
            || ok "$tag: the panel OCR does NOT report text that is not there"
    else
        bad "$tag: the panel strip could not be OCR'd"
    fi

    if ocr "$p" "$D/shots/${tag}_icons" "$ICONS_GEOM"; then
        LOOK_ICONS=$(cat "$D/shots/${tag}_icons.txt")
    else
        LOOK_ICONS=""
        bad "$tag: the desktop icon column could not be OCR'd"
    fi
    info "$tag icon OCR: $(printf '%s' "$LOOK_ICONS" | tr '\n' ' ' | cut -c1-200)"
    local nfound=0 lbl
    for lbl in Calculator Terminal Files Notes Calendar; do
        printf '%s' "$LOOK_ICONS" | grep -qi "$lbl" && nfound=$((nfound+1))
    done
    if [ "$nfound" -ge 3 ]; then
        ok "$tag: $nfound of 5 sampled desktop-icon labels read back, so this crop DOES resolve launcher names"
    else
        bad "$tag: only $nfound of 5 sampled desktop-icon labels read back -- this crop cannot resolve launcher names, so 'Install is not in it' would be a statement about the OCR"
    fi

    # --- the Applications menu, opened with the mouse ---------------------
    qi click 40 14 "$SCREEN_W" "$SCREEN_H" >/dev/null
    sleep 3
    pm=$(shot "${tag}_menu") || { bad "$tag: the menu screendump failed"; LOOK_MENU=""; return 1; }
    # THE CLICK HAS TO HAVE DONE SOMETHING. A menu that never opened gives an
    # OCR of the plain desktop, and "Install is not in it" would then be a
    # statement about a click that missed.
    local dout ndiff
    dout=$(python3 "$PROJ_ROOT/tests/linux/ppmdiff.py" diff "$p" "$pm" 2>/dev/null)
    ndiff=$(printf '%s' "$dout" | sed -n 's/.*: \([0-9][0-9]*\) of .* differ.*/\1/p')
    ndiff="${ndiff:-0}"
    if [ "$ndiff" -gt 1000 ]; then
        ok "$tag: the click on the panel CHANGED the picture by $ndiff pixels -- a menu opened, so the menu OCR below is of a menu"
    else
        bad "$tag: the click on the panel changed only $ndiff pixels -- the Applications menu did not open, and the menu reading below is of the bare desktop"
    fi
    if ocr "$pm" "$D/shots/${tag}_menutxt" "$MENU_GEOM"; then
        LOOK_MENU=$(cat "$D/shots/${tag}_menutxt.txt")
    else
        LOOK_MENU=""
        bad "$tag: the Applications menu could not be OCR'd"
    fi
    info "$tag menu OCR: $(printf '%s' "$LOOK_MENU" | tr '\n' ' ' | cut -c1-240)"

    local both; both="$LOOK_ICONS
$LOOK_MENU"
    if [ "$expect" = hidden ]; then
        if printf '%s' "$both" | grep -qiE 'install'; then
            bad "$tag: THE INSTALLED MACHINE OFFERS TO INSTALL HAMNIX -- 'install' was read off its own desktop/menu: $(printf '%s' "$both" | grep -iE 'install' | tr '\n' '|' | cut -c1-160)"
        else
            ok "$tag: neither the desktop icons nor the Applications menu says 'Install'"
        fi
    else
        if printf '%s' "$both" | grep -qiE 'install'; then
            ok "$tag: the LIVE MEDIUM says 'Install' -- the instrument can see the offer when the offer is there (this is the negative control, and it RAN)"
        else
            bad "$tag: the live medium does NOT read 'Install' either. The instrument cannot see the offer at all, so section 2's silence is the lens cap and not a machine"
        fi
    fi
    return 0
}

say "2 -- THE INSTALLED MACHINE, BOOTED ON ITS OWN, READ AS A PICTURE"
boot_gui "$W/boot-installed" installed "$NVME"
if wait_for_desktop 240; then
    ok "the installed machine reached 'rc.boot: up' after ${BOOT_SECS}s"
    look_at installed hidden
else
    bad "the installed machine never printed 'rc.boot: up' in ${BOOT_SECS}s -- it did not reach a desktop and nothing about its menus was measured"
    tail -20 "$D/serial.log" 2>/dev/null | sed 's/^/        /'
fi
kill_guest

say "3 -- THE NEGATIVE CONTROL: THE LIVE MEDIUM, SAME INSTRUMENT, SAME CROPS"
boot_gui "$W/boot-medium" medium "$STOCK"
if wait_for_desktop 240; then
    ok "the live medium reached 'rc.boot: up' after ${BOOT_SECS}s"
    look_at medium offered
else
    bad "the live medium never printed 'rc.boot: up' in ${BOOT_SECS}s -- THE NEGATIVE CONTROL DID NOT RUN, and section 2 is unproven"
    tail -20 "$D/serial.log" 2>/dev/null | sed 's/^/        /'
fi
kill_guest

info "evidence: $W"
finish
