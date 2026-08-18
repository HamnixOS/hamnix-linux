#!/usr/bin/env bash
#
# REGISTRATION, 2026-08-17. This gate is ON-DEMAND: not in
# ci_battery_manifest.txt because it boots a machine twice under
# `qemu-system-x86_64` with four virtual disks and lets a real install
# partition one of them; a run is tens of minutes, not seconds.
#
# tests/linux/install_confirm_keys.sh — HOW MANY KEYPRESSES START AN
# IRREVERSIBLE ERASE, MEASURED ON A DISK THAT REALLY GETS ERASED.
#
# THE RULE THIS GATE ASSERTS
# ==========================
#   A SINGLE KEYPRESS MUST NEVER BEGIN AN IRREVERSIBLE ERASE.
#
# WHY IT EXISTS
# =============
# tests/linux/install_wizard_gui.sh made the wizard's disk page completable
# from the keyboard, and its own header records an observation it could not
# explain: ONE Return produced a frame with the INSTALLER ALREADY RUNNING,
# where `_goto_next()` needs two calls to get from the disk page to a started
# install. That was left open. This is the instrument it asked for.
#
# THE FIRST RUN OF THIS FILE (2026-08-17, 22 PASSED / 3 FAILED) IS WHY IT
# LOOKS LIKE THIS, and the three reds were all in the INSTRUMENT:
#
#   1. IT COULD NOT SEE AN ERASE AT ALL. The medium was built with
#      HAMLINUX_INSTALLER=1 on the theory that this puts /boot/root.partuuid
#      where hlinstall reads it. IT DOES NOT: that option stages the file into
#      the ext4 root's /boot, and `etc/rc.boot.installed` then does
#      `bind '#esp' /boot`, so what hlinstall opens is the FAT ESP -- and
#      scripts/hamlinux_disk.sh mcopies BOOTX64.EFI, vmlinuz, initramfs and
#      UKI.MAP onto that ESP and NOT root.partuuid. hlinstall therefore
#      refused by name, no disk was ever touched, and every "the disk did not
#      change" in that run was a reading from a blind instrument. THE GATE
#      SAID SO ITSELF -- section 3's positive control went red and told the
#      reader to withdraw the negatives -- which is the only reason this is
#      written down as a fact and not as a green run. The gate's rc now writes
#      /boot/root.partuuid IN THE GUEST and the console must echo it back.
#
#   2. THE AUTOREPEAT PROBE WAS BLIND IN THE OTHER DIRECTION. It asked
#      tesseract whether a held key had filled a text field. tesseract does
#      not read inside the input box on this build, so it reported "no
#      repeat"; the PNG it had just written showed the field FULL, about forty
#      characters from one 3-second press. An OCR that cannot see the field is
#      not evidence about what is in the field. The probe now counts DARK
#      PIXELS in the field rectangle and calibrates itself against a known
#      one-character and five-character fill, so it reports a NUMBER OF
#      CHARACTERS and can be wrong in a way that shows.
#
#   3. It measured "one Return on the summary page" by first pressing Return
#      on the DISK page to get there -- and that press had already started the
#      install, so the frame under test was a progress pane. The subject is
#      now the disk page's own Return, which is the keystroke a person
#      actually presses, and section 1 REQUIRES the installer not to be
#      running before it.
#
#   4. AND EVEN WITH root.partuuid IN PLACE IT STILL COULD NOT ERASE (run 2,
#      29 PASSED / 3 FAILED). hlinstall got one step further and stopped at
#      "=== 1/5 partitioning ===" with its own explanation on the progress
#      pane: "This medium carries neither a Debian namespace (#distro) nor
#      /usr/lib/instroot, so sgdisk and mkfs cannot run and NOTHING HAS BEEN
#      WRITTEN." That is the installer refusing correctly; it is also a gate
#      that cannot see the thing it exists to see. The medium is built with
#      HAMLINUX_INSTALLER=1 as well now, and the guest is asked to list the
#      tools before any "the disk did not change" is believed.
#
#      RUN 2 IS NOT WORTHLESS FOR HAVING BEEN RED. Its keystroke arithmetic
#      stands (empty 14 ink, one press 41, five presses 149 -> 27 per
#      character: ONE PRESS IS ONE CHARACTER; a 3 s hold put 824 ink, about 30
#      characters, in the field), and so does the fact that ONE Return on the
#      disk page reached a spawned, running installer printing "this ERASES
#      the disk".
#
# WHAT "IRREVERSIBLE ERASE" MEANS HERE, AND WHY IT IS A MEASUREMENT
# ================================================================
# With /boot/root.partuuid present, user/hlinstall.ad passes its one
# pre-flight check and its very next act is `sgdisk --zap-all <disk>`. So the
# detector is not a spawn, not a screenshot and not a process name: it is the
# TARGET IMAGE'S OWN sha256. A 4 GiB file of zeros that comes back with a
# different digest was written. Both targets are virtual image files under
# $HOME/.hamnix-build; NOTHING HERE GOES NEAR A PHYSICAL DEVICE.
#
# THE DETECTOR IS PROVED IN BOTH DIRECTIONS, IN EVERY RUN:
#   + NEGATIVE: a single planted byte in a copy of a 4 GiB image must change
#     the digest. Run, not described.
#   + POSITIVE: section 3 deliberately completes the install by the route the
#     wizard asks for and REQUIRES the digest to change. If it does not, every
#     "the disk was not touched" above it is withdrawn as unreadable rather
#     than reported as a pass.
#
# WHAT IS MEASURED
# ================
# P.  THE PREMISES, re-grepped, plus the guest's own echo of the file that
#     makes an erase possible at all.
#
# 0.  KEYSTROKE ARITHMETIC. Before any conclusion of the form "one keypress
#     did X", it must be established what ONE keypress is on this machine.
#     Measured in the host-name field by counting ink: empty, one press, five
#     presses (which calibrates ink-per-character), and one press HELD. It
#     answers two questions with numbers -- does one press deliver one
#     character, and does a held key repeat -- and it can fail.
#
# 1.  ONE RETURN ON THE DISK PAGE (boot A). A target is selected with Tab, the
#     frame is proved to be step 5, the census is proved to have no installer
#     in it, both targets are digested, and then EXACTLY ONE Return is sent.
#     IF A TARGET'S DIGEST CHANGES, ONE KEYPRESS ERASED A DISK.
#
# 2.  ONE HELD RETURN (boot B), from the disk page with a target selected.
#     Section 0 has by then said how many events that is.
#
# 2b. TEN QUEUED RETURNS (boot B). Not one keypress, and never claimed as one:
#     this is the QUEUE shape. user/haminstallui.ad reads up to 255 bytes of
#     its /keys AT ONCE, calls _key_line on EVERY line in that read, and calls
#     emit_scene ONCE at the bottom -- so several page transitions can happen
#     with no frame painted between them. The rule asserted is the weaker and
#     still necessary one: a queue must not carry a person past a page they
#     never saw into an erase.
#
# 3.  AND IT MUST STILL BE COMPLETABLE, by keyboard. Also the positive
#     control.
#
# WHAT THIS GATE DOES NOT MEASURE, said rather than left to be assumed:
#   * the pointer as the driver. Every action under test is a key; clicks are
#     used only for focus and for the Back button, where a missed click shows
#     up as a wrong page rather than as a silent pass.
#   * a Hamnix-native boot. Linux lane only.
#   * whether the install would have SUCCEEDED. Section 3 requires the erase
#     to start, not the install to finish.
#
# Usage: tests/linux/install_confirm_keys.sh
# Env:   HAMLINUX_ICK_WORK      where to build and boot
#        HAMLINUX_ICK_REUSE=1   reuse the medium already built there
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"
. tests/linux/private_ns.sh
priv_ns_reexec "$@"
. tests/linux/reap.sh

WORK="${HAMLINUX_ICK_WORK:-$HOME/.hamnix-build/instconfirm}"
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
MARK="ICKUP7743"
CENSUS="ICKCENSUS"
PUTAG="ICKPARTUUID"
READY="scene window ready"
SCREEN_W=1280; SCREEN_H=800
WIN_X=180; WIN_Y=70; WIN_W=440; WIN_H=470
# The host-name input box, off the source: _draw_input(CONTENT_X, 92, ...)
# with FIELD_W x FIELD_H = 400 x 26 (haminstallui.ad). Inset by 3 px so the
# box's own 1-px border is not counted as ink.
FLD_X=$(( WIN_X + 20 + 3 )); FLD_Y=$(( WIN_Y + 92 + 3 ))
FLD_W=394; FLD_H=20

# ---------------------------------------------------------------------------
say "P -- THE PREMISES, RE-GREPPED"
# ---------------------------------------------------------------------------
grep -q 'Enter / Return = Next' "$UI" \
    && ok "Return is still Next in haminstallui.ad -- the hand below drives the wizard's own navigation" \
    || bad "Return may no longer be Next -- the keystrokes below are not this wizard's navigation"

grep -q 'PAGE_SUMMARY: int32 = 5' "$UI" \
    && ok "PAGE_SUMMARY is still the last page" \
    || bad "the page numbering moved -- re-read the wizard before believing anything below"

# The summary page's warning is TEXT, not an action. Pinned because it is what
# people point at when they say the erase is already confirmed. If a real
# confirmation is added this grep is EXPECTED to keep matching -- the warning
# stays. It is the confirmation that sections 1-3 measure, never this string.
grep -q 'will be ERASED' "$UI" \
    && ok "the summary page still draws its 'will be ERASED' warning -- a label, whose worth is what this gate measures" \
    || bad "the ERASED warning is gone from the summary page"

grep -q 'read_root_partuuid() != 0' user/hlinstall.ad \
    && ok "user/hlinstall.ad still refuses without /boot/root.partuuid -- which is why this gate's rc puts one there" \
    || bad "hlinstall's partuuid precondition moved -- re-read what this gate's medium implies"

grep -q 'zap-all' user/hlinstall.ad \
    && ok "and its first act on the disk is still sgdisk --zap-all, which is the irreversible step being counted" \
    || bad "hlinstall no longer zaps the disk first -- what counts as 'the erase began' has changed"

grep -q "bind '#esp' /boot" etc/rc.boot.installed \
    && ok "etc/rc.boot.installed still binds the ESP over /boot -- so /boot/root.partuuid must be written to the ESP, which is what the rc below does and what HAMLINUX_INSTALLER=1 does NOT do" \
    || bad "the '#esp' bind over /boot is gone -- this gate's way of making an erase possible may now be writing to the wrong filesystem, and a run that cannot erase reports nothing"

# haminstallui reads the whole /keys ring in one read and acts on every line
# in it. This is the mechanism section 2b is about; if it changes, 2b is
# measuring something else.
grep -q 'sys_read_nb(kfd, &kbuf\[0\], 255)' "$UI" \
    && ok "the wizard still drains its whole /keys buffer in ONE read and acts on every line in it -- the mechanism section 2b measures" \
    || bad "the wizard's key-read loop has changed shape -- re-read section 2b before believing it"

if [ "$FAIL" != 0 ]; then
    printf '\n%d PASSED, %d FAILED\n' "$PASS" "$FAIL"
    printf 'the premises do not hold; measuring against them would report on a stale comment\n'
    exit 1
fi

# ---------------------------------------------------------------------------
say "BUILDING THE MEDIUM"
# ---------------------------------------------------------------------------
# THE UUID IS PINNED so the rc that writes /boot/root.partuuid in the guest
# and the disk the medium was built with agree. hlinstall only requires a
# canonical 8-4-4-4-12 UUID, but handing it the medium's real one is what a
# real install does.
ICK_UUID_FILE="$WORK/root.partuuid"
if [ ! -s "$ICK_UUID_FILE" ]; then
    cat /proc/sys/kernel/random/uuid >"$ICK_UUID_FILE"
fi
ICK_UUID=$(tr -d '\r\n' <"$ICK_UUID_FILE")
info "pinned root PARTUUID for this medium: $ICK_UUID"

# THE rc. `echo ... > /boot/root.partuuid` is the one line that makes an erase
# reachable, and it is IMMEDIATELY READ BACK to the console so the gate can
# fail on a medium where it did not take, instead of measuring nothing.
cat >"$WORK/rc.ick" <<RCEOF
source '/etc/rc.boot.installed'
echo '$ICK_UUID' > '/boot/root.partuuid'
echo '${PUTAG}BEGIN'
cat '/boot/root.partuuid'
ls '/usr/lib/instroot/usr/sbin'
echo '${PUTAG}END'
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

if [ "${HAMLINUX_ICK_REUSE:-0}" = 1 ] && [ -f "$WORK/medium.img" ]; then
    info "reusing $WORK/medium.img"
else
    # HAMLINUX_INSTALLER=1 IS LOAD-BEARING, AND THE SECOND RUN OF THIS FILE IS
    # WHY. Without it the medium carries no /usr/lib/instroot, so hlinstall's
    # `bind '#distro'` finds nothing, sgdisk NEVER RUNS, and the install stops
    # at "1/5 partitioning" having written nothing. Its own words on the
    # progress pane were "This medium carries neither a Debian namespace
    # (#distro) nor /usr/lib/instroot ... Rebuild the medium with
    # HAMLINUX_INSTALLER=1". That is hlinstall REFUSING SAFELY -- and it left
    # this gate's erase detector unable to fire, which the positive control
    # caught and reported as "withdraw every negative above".
    #
    # It is NOT what puts /boot/root.partuuid in place: that option stages the
    # file into the ext4 root's /boot, which `bind '#esp' /boot` then hides.
    # The rc above writes it. BOTH are needed, and the guest is asked about
    # both below.
    info "rebuilding build/image/root with HAMLINUX_INSTALLER=1 (the partitioning tools)"
    HAMLINUX_INSTALLER=1 HAMLINUX_DISTRO_RO=1 scripts/hamlinux_image.sh \
        >"$WORK/image.log" 2>&1 || {
        bad "image build"; tail -30 "$WORK/image.log"; exit 1; }
    HAMLINUX_ROOT_PARTUUID="$ICK_UUID" HAMLINUX_DISK_RC="$WORK/rc.ick" \
        scripts/hamlinux_disk.sh "$WORK/medium.img" 6G >"$WORK/disk.log" 2>&1 || {
        bad "disk build"; tail -30 "$WORK/disk.log"; exit 1; }
fi

# ---------------------------------------------------------------------------
# THE ERASE DETECTOR, AND ITS NEGATIVE PROOF.
# ---------------------------------------------------------------------------
digest() { sha256sum <"$1" | cut -d' ' -f1; }

truncate -s 4G "$WORK/probe.img"
cp --sparse=always "$WORK/probe.img" "$WORK/planted.img"
printf 'X' | dd of="$WORK/planted.img" bs=1 seek=1048576 conv=notrunc status=none
if [ "$(digest "$WORK/probe.img")" != "$(digest "$WORK/planted.img")" ]; then
    ok "the erase detector sees ONE planted byte in a 4 GiB image -- 'the disk was not touched' below is a measurement, not a comparator that always agrees"
else
    bad "the erase detector gave the same digest for an image with a planted byte -- IT IS BLIND and no result below can be believed"
fi
rm -f "$WORK/probe.img" "$WORK/planted.img"

# ---------------------------------------------------------------------------
ocr_win() {
    local ppm="$1" base="$2"
    convert "$ppm" -crop "${WIN_W}x${WIN_H}+${WIN_X}+${WIN_Y}" +repage \
        -colorspace Gray -resize 300% -sharpen 0x1 "$base.png" 2>/dev/null || return 1
    tesseract "$base.png" "$base" --psm 6 >/dev/null 2>&1 || return 1
    [ -s "$base.txt" ]
}
# ink <ppm> -- dark pixels inside the host-name field. THE INSTRUMENT THE OCR
# SHOULD HAVE BEEN: tesseract does not read inside this build's input boxes,
# and reported an empty field that a human looking at the same PNG could see
# was full.
ink() {
    convert "$1" -crop "${FLD_W}x${FLD_H}+${FLD_X}+${FLD_Y}" +repage \
        -colorspace Gray -threshold 50% \
        -format '%[fx:int(w*h*(1-mean)+0.5)]' info: 2>/dev/null || printf ''
}
hmp() { printf '%s\n' "$2" | timeout 15 socat - "UNIX-CONNECT:$1/mon.sock" 2>/dev/null; }
qi()  { local d="$1"; shift; timeout 120 python3 "$QMP_INPUT" "$d/qmp.sock" "$@" 2>&1; }
shot() {
    local d="$1" tag="$2"
    local p="$d/shots/$tag.ppm"
    hmp "$d" "screendump $p" >/dev/null
    sleep 1
    [ -s "$p" ] || return 1
    ocr_win "$p" "$d/shots/$tag" || return 1
}
shot_txt() { cat "$1/shots/$2.txt" 2>/dev/null || printf ''; }

VM=""
boot_vm() {   # <dir> <nvme-img> <vblk-img>
    local d="$1" nvme="$2" vblk="$3"
    rm -rf "$d"; mkdir -p "$d/shots"
    cp /usr/share/OVMF/OVMF_VARS_4M.fd "$d/OVMF_VARS.fd"
    qemu-system-x86_64 \
        -m 3072 -smp 2 -no-reboot \
        -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
        -drive "if=pflash,format=raw,unit=1,file=$d/OVMF_VARS.fd" \
        -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
        -display none -vga std \
        -serial "file:$d/serial.log" \
        -enable-kvm -cpu host \
        -monitor "unix:$d/mon.sock,server,nowait" \
        -qmp "unix:$d/qmp.sock,server,nowait" \
        -device virtio-keyboard-pci -device virtio-tablet-pci \
        -device qemu-xhci,id=xhci \
        -drive "file=$WORK/medium.img,if=none,format=raw,id=usbstick" \
        -device usb-storage,bus=xhci.0,drive=usbstick,bootindex=0 \
        -drive "file=$nvme,if=none,format=raw,id=tgtnvme" \
        -device nvme,drive=tgtnvme,serial=ICKNVME \
        -drive "file=$vblk,if=none,format=raw,id=tgtvblk" \
        -device virtio-blk-pci,drive=tgtvblk \
        >"$d/qemu.out" 2>&1 &
    VM=$!
    reap_add "$VM"
}
kill_vm() { [ -n "$VM" ] && kill -KILL "$VM" 2>/dev/null; wait "$VM" 2>/dev/null; VM=""; }

wait_ready() {   # <dir>
    local d="$1" w=0
    while kill -0 "$VM" 2>/dev/null && [ "$w" -lt 480 ]; do
        grep -aq "$MARK" "$d/serial.log" 2>/dev/null && break
        sleep 3; w=$((w+3))
    done
    grep -aq "$MARK" "$d/serial.log" 2>/dev/null || return 1
    w=0
    while kill -0 "$VM" 2>/dev/null && [ "$w" -lt 300 ]; do
        grep -aq "$READY" "$d/serial.log" 2>/dev/null && break
        sleep 3; w=$((w+3))
    done
    grep -aq "$READY" "$d/serial.log" 2>/dev/null
}

# THE FILE THAT MAKES AN ERASE POSSIBLE, read back off the guest's own
# console. Without this the whole run is the previous run: every "the disk did
# not change" true for a reason that has nothing to do with keystrokes.
check_partuuid() {   # <dir>
    local d="$1" got
    got=$(sed -n "/${PUTAG}BEGIN/,/${PUTAG}END/p" "$d/serial.log" | tr -d '\r' \
          | grep -oiE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)
    if [ -n "$got" ]; then
        ok "the guest echoed /boot/root.partuuid back as $got -- hlinstall's one pre-flight check will pass, so this machine CAN erase a target and a 'no erase' result below is about the keystroke"
        return 0
    fi
    bad "the guest did not echo a UUID from /boot/root.partuuid -- hlinstall will refuse before touching anything and NO 'the disk did not change' result in this run is evidence about a keystroke"
    sed -n "/${PUTAG}BEGIN/,/${PUTAG}END/p" "$d/serial.log" | tr -d '\r' | head -8 | sed 's/^/  ||    /'
    return 1
}

# THE OTHER HALF OF "THIS MACHINE CAN ERASE". hlinstall shells out to sgdisk
# inside /usr/lib/instroot; without it it stops at "1/5 partitioning" having
# written nothing, and a run that cannot erase reports nothing about
# keystrokes. Asked of the GUEST, because that is the filesystem that matters.
check_tools() {   # <dir>
    local d="$1" blk
    blk=$(sed -n "/${PUTAG}BEGIN/,/${PUTAG}END/p" "$d/serial.log" | tr -d '\r')
    if printf '%s' "$blk" | grep -q 'sgdisk'; then
        ok "and the guest's own listing of /usr/lib/instroot/usr/sbin shows sgdisk -- the partitioning tools this install shells out to are on this medium"
        return 0
    fi
    bad "the guest's /usr/lib/instroot/usr/sbin does not contain sgdisk -- hlinstall will stop at '1/5 partitioning' having written nothing, and NO 'the disk did not change' result in this run is evidence about a keystroke"
    printf '%s' "$blk" | head -8 | sed 's/^/  ||    /'
    return 1
}

WIZPW=hampw
F1_X=220; F1_Y=105
F2_X=220; F2_Y=169
PARK_X=220; PARK_Y=380          # pointer parking spot: inside the window, no
                                # widget, well below the field being measured
wclick() { qi "$1" click $(( WIN_X + $2 )) $(( WIN_Y + $3 )) "$SCREEN_W" "$SCREEN_H" >/dev/null; }
wmove()  { qi "$1" move  $(( WIN_X + $2 )) $(( WIN_Y + $3 )) "$SCREEN_W" "$SCREEN_H" >/dev/null; }
clear_field() { local d="$1" i=0; while [ "$i" -lt 34 ]; do qi "$d" key backspace >/dev/null; i=$((i+1)); done; }

DRIVE_STEPS=""
drive_to_disk_page() {   # <dir> <tag-prefix>
    local d="$1" pfx="$2" n=0 tag T S
    DRIVE_STEPS=""
    while [ "$n" -lt 12 ]; do
        n=$((n+1)); tag="$pfx$(printf '%02d' "$n")"
        shot "$d" "$tag" || true
        T=$(shot_txt "$d" "$tag")
        S=$(printf '%s' "$T" | grep -oiE 'Step [0-9]' | head -1)
        info "$tag: ${S:-<no step line>} | $(printf '%s' "$T" | tr '\n' '|' | cut -c1-100)"
        case "$DRIVE_STEPS" in *"${S:-none}"*) : ;; *) DRIVE_STEPS="$DRIVE_STEPS ${S:-none}" ;; esac
        printf '%s' "$T" | grep -qi 'Step 5' && return 0
        if printf '%s' "$T" | grep -qi 'Confirm password'; then
            wclick "$d" "$F1_X" "$F1_Y"; clear_field "$d"; qi "$d" type "$WIZPW" >/dev/null
            wclick "$d" "$F2_X" "$F2_Y"; clear_field "$d"; qi "$d" type "$WIZPW" >/dev/null
            sleep 1; qi "$d" key ret >/dev/null
        else
            qi "$d" type hamwiz >/dev/null; sleep 1; qi "$d" key ret >/dev/null
        fi
        sleep 4
    done
    return 1
}

NCENSUS=0; NWSYSD=0; NINSTALL=0
census_report() {
    local d="$1"
    sed -n "/${CENSUS}BEGIN/,/${CENSUS}END/p" "$d/serial.log" | tr -d '\r' >"$d/census.txt"
    NCENSUS=$(grep -c "${CENSUS}BEGIN" "$d/census.txt")
    NWSYSD=$(grep -c 'wsysd' "$d/census.txt")
    NINSTALL=$(grep -cE '(^| |/)(install|hlinstall)( |$)' "$d/census.txt")
}

###########################################################################
say "BOOT A -- KEYSTROKE ARITHMETIC, THEN ONE RETURN ON THE DISK PAGE"
###########################################################################
A="$WORK/bootA"
A_NVME="$WORK/A-nvme.img"; A_VBLK="$WORK/A-vblk.img"
rm -f "$A_NVME" "$A_VBLK"
truncate -s 4G "$A_NVME"; truncate -s 4G "$A_VBLK"
A_NVME_0=$(digest "$A_NVME"); A_VBLK_0=$(digest "$A_VBLK")
info "both boot-A targets start as 4 GiB of zeros ($A_NVME_0)"

boot_vm "$A" "$A_NVME" "$A_VBLK"
sleep 5
hmp "$A" 'info block' >"$A/infoblock.txt"
if grep -q '^tgtnvme' "$A/infoblock.txt" && grep -q '^tgtvblk' "$A/infoblock.txt"; then
    ok "QEMU reports both blank targets attached -- a wizard that offers no disk here is not offering one that exists"
else
    bad "QEMU does not report both targets attached -- EVERYTHING IN BOOT A IS UNINTERPRETABLE"
fi

if wait_ready "$A"; then
    ok "boot A: the desktop came up and haminstallui printed '$READY'"
else
    bad "boot A: the wizard's window never came up -- nothing was measured"
    tail -30 "$A/serial.log" 2>/dev/null
    kill_vm
    printf '\n%d PASSED, %d FAILED\n' "$PASS" "$FAIL"; exit 1
fi
check_partuuid "$A" || true
check_tools "$A" || true
sleep 8

# ---------------------------------------------------------------------------
say "0 -- KEYSTROKE ARITHMETIC: what IS one keypress on this machine?"
# ---------------------------------------------------------------------------
# Nothing below may say "one keypress did X" until this says what one keypress
# is. The field is cleared, then filled in three known ways, and the INK is
# counted; the difference between one character and five gives ink-per-
# character, so the other two fills come out as a NUMBER OF CHARACTERS rather
# than as an impression.
qi "$A" click $(( WIN_X + WIN_W / 2 )) $(( WIN_Y + 250 )) "$SCREEN_W" "$SCREEN_H" >/dev/null
sleep 2
wclick "$A" "$F1_X" "$F1_Y"
wmove  "$A" "$PARK_X" "$PARK_Y"      # the cursor is drawn, and it is ink
sleep 1
clear_field "$A"
sleep 1
shot "$A" k0_empty || true
INK_0=$(ink "$A/shots/k0_empty.ppm"); INK_0=${INK_0:-0}
qi "$A" key m >/dev/null; sleep 2
shot "$A" k1_one || true
INK_1=$(ink "$A/shots/k1_one.ppm"); INK_1=${INK_1:-0}
qi "$A" key m m m m >/dev/null; sleep 2
shot "$A" k2_five || true
INK_5=$(ink "$A/shots/k2_five.ppm"); INK_5=${INK_5:-0}
info "ink in the host-name field: empty=$INK_0  after ONE press=$INK_1  after FIVE presses=$INK_5"

PERCHAR=0
if [ "${INK_1:-0}" -gt "${INK_0:-0}" ]; then
    ok "the field-ink probe SEES a character: one press moved the ink from $INK_0 to $INK_1, so a later 'the field did not fill' would be a reading and not a blind instrument"
else
    bad "one press changed the field's ink from $INK_0 to ${INK_1:-<none>} -- THE PROBE CANNOT SEE A CHARACTER and every number in section 0 is worthless"
fi
if [ "${INK_5:-0}" -gt "${INK_1:-0}" ]; then
    PERCHAR=$(( (INK_5 - INK_1) / 4 ))
    ok "and it scales: four more presses added $(( INK_5 - INK_1 )) ink, i.e. $PERCHAR per character"
else
    bad "five presses did not put more ink in the field than one ($INK_5 vs $INK_1) -- the probe cannot count and section 0 reports nothing"
fi

if [ "$PERCHAR" -gt 0 ]; then
    N_ONE=$(( (INK_1 - INK_0 + PERCHAR / 2) / PERCHAR ))
    info "so ONE press of the key op put approximately $N_ONE character(s) in the field"
    # THE QUESTION install_wizard_gui.sh's UNEXPLAINED NOTE TURNS ON. If one
    # press arrives as two, then "one Return started an install that needs two
    # Returns" is explained by the keyboard path and not by the wizard.
    if [ "$N_ONE" -le 1 ]; then
        ok "ONE PRESS IS ONE CHARACTER ($N_ONE) -- a keystroke is not being delivered twice on this machine, so a single Return below is a single _goto_next"
    else
        bad "ONE PRESS ARRIVED AS $N_ONE CHARACTERS -- keystrokes are being delivered more than once on this path, and every 'one Return' result below is really $N_ONE Returns. That, not the wizard, would explain a single Return reaching a started install"
    fi
fi

# --- and now a HELD key ----------------------------------------------------
clear_field "$A"
sleep 1
qi "$A" hold m 3 >/dev/null
sleep 3
shot "$A" k3_held || true
INK_H=$(ink "$A/shots/k3_held.ppm"); INK_H=${INK_H:-0}
REPEATS=0
if [ "$PERCHAR" -gt 0 ]; then
    N_HELD=$(( (INK_H - INK_0 + PERCHAR / 2) / PERCHAR ))
    info "ink after holding one key for 3 s: $INK_H, i.e. about $N_HELD characters"
    if [ "$N_HELD" -ge 4 ]; then
        REPEATS=1
        ok "A HELD KEY AUTOREPEATS ON THIS MACHINE: ONE physical press, held for 3 s, put about $N_HELD characters in the field. 'One keypress' can therefore mean many events -- user/wsysd.ad's handle_key treats an evdev autorepeat (value 2) exactly like a press"
    else
        ok "a held key produced about $N_HELD characters, i.e. it does NOT autorepeat here -- section 2's hold result will be reported as UNMEASURED rather than as evidence that holding a key is safe"
    fi
fi

# ---------------------------------------------------------------------------
say "1 -- ONE RETURN ON THE DISK PAGE, WITH A TARGET SELECTED"
# ---------------------------------------------------------------------------
if drive_to_disk_page "$A" a; then
    ok "boot A: the wizard was driven by keyboard to 'Step 5 of 5' (pages seen:$DRIVE_STEPS)"
else
    bad "boot A: the wizard never reached step 5 (pages seen:$DRIVE_STEPS) -- section 1 could not be set up"
fi
NSTEPS=$(printf '%s' "$DRIVE_STEPS" | tr ' ' '\n' | grep -c 'Step')
if [ "$NSTEPS" -ge 3 ]; then
    ok "and the keyboard demonstrably REACHES this window: $NSTEPS distinct numbered pages were driven through, so a key that does nothing later was refused, not lost"
else
    bad "only $NSTEPS distinct pages were seen -- the hand may not be reaching the wizard and no 'it refused' below can be believed"
fi

qi "$A" key tab >/dev/null; sleep 3
shot "$A" a_selected || true
SEL=$(shot_txt "$A" a_selected)
info "the frame the person is looking at: $(printf '%s' "$SEL" | tr '\n' '|' | cut -c1-200)"
if printf '%s' "$SEL" | grep -qi 'Step 5'; then
    ok "and after Tab the person is still on step 5, with a target selected -- which is the state the keypress below is a measurement about"
else
    bad "after Tab the frame is not step 5 -- where the person is was not established and section 1 measures nothing; read $A/shots/a_selected.png"
fi
census_report "$A"
if [ "$NINSTALL" = 0 ]; then
    ok "and the guest's own ps has NOT seen /bin/install in $NCENSUS censuses so far -- nothing was installing before the keypress under test"
else
    bad "the installer had ALREADY run before the keypress under test ($NINSTALL census lines) -- section 1 cannot attribute anything to that keypress"
fi
A_NVME_1=$(digest "$A_NVME"); A_VBLK_1=$(digest "$A_VBLK")
if [ "$A_NVME_1" = "$A_NVME_0" ] && [ "$A_VBLK_1" = "$A_VBLK_0" ]; then
    ok "and both targets are still byte-identical to the zeros they started as"
else
    bad "a target had ALREADY changed before the keypress under test -- section 1 cannot attribute anything to it"
fi

say "   ONE Return. One press, one release, nothing else."
qi "$A" key ret >/dev/null
sleep 3
shot "$A" a_after_3s || true
info "3 s after the Return:  $(shot_txt "$A" a_after_3s | tr '\n' '|' | cut -c1-200)"
sleep 25
shot "$A" a_after_28s || true
AFTER=$(shot_txt "$A" a_after_28s)
info "28 s after the Return: $(printf '%s' "$AFTER" | tr '\n' '|' | cut -c1-240)"
A_NVME_2=$(digest "$A_NVME"); A_VBLK_2=$(digest "$A_VBLK")
census_report "$A"
info "boot A census: $NCENSUS samples, wsysd=$NWSYSD lines, install/hlinstall=$NINSTALL lines"

ERASED_1=0
[ "$A_NVME_2" != "$A_NVME_1" ] && ERASED_1=1
[ "$A_VBLK_2" != "$A_VBLK_1" ] && ERASED_1=1
if [ "$ERASED_1" = 1 ]; then
    bad "ONE KEYPRESS ERASED A DISK. A single Return on the disk page changed a target image's sha256 (nvme $A_NVME_1 -> $A_NVME_2 / vblk $A_VBLK_1 -> $A_VBLK_2). Between the page a person is reading and a wiped disk there was one keystroke."
    ok "and the erase detector is thereby PROVED in this run: it has been seen to fire, so every 'the disk did not change' elsewhere is a reading"
else
    ok "ONE Return on the disk page did NOT change either target's sha256"
fi
if [ "$NINSTALL" -ge 1 ]; then
    bad "and the guest's own ps found /bin/install running after that single Return ($NINSTALL census lines) -- the wizard went from a page to a spawned installer on one keystroke"
else
    ok "and the guest's own ps still has not seen /bin/install"
fi
if printf '%s' "$AFTER" | grep -qiE 'Installing|hlinstall'; then
    bad "and the frame 28 s after that single Return shows the installer running"
else
    ok "and the frame 28 s after that single Return does not show a running installer"
fi
kill_vm

###########################################################################
say "BOOT B -- A HELD KEY, A QUEUE, AND THE DELIBERATE COMPLETION"
###########################################################################
B="$WORK/bootB"
B_NVME="$WORK/B-nvme.img"; B_VBLK="$WORK/B-vblk.img"
rm -f "$B_NVME" "$B_VBLK"
truncate -s 4G "$B_NVME"; truncate -s 4G "$B_VBLK"
B_NVME_0=$(digest "$B_NVME"); B_VBLK_0=$(digest "$B_VBLK")

boot_vm "$B" "$B_NVME" "$B_VBLK"
if wait_ready "$B"; then
    ok "boot B: the wizard's window came up"
else
    bad "boot B: the wizard's window never came up -- sections 2 and 3 measured nothing"
    tail -30 "$B/serial.log" 2>/dev/null
    kill_vm
    printf '\n%d PASSED, %d FAILED\n' "$PASS" "$FAIL"; exit 1
fi
check_partuuid "$B" || true
check_tools "$B" || true
sleep 8
qi "$B" click $(( WIN_X + WIN_W / 2 )) $(( WIN_Y + 250 )) "$SCREEN_W" "$SCREEN_H" >/dev/null
sleep 2
if drive_to_disk_page "$B" b; then
    ok "boot B: driven to 'Step 5 of 5' (pages seen:$DRIVE_STEPS)"
else
    bad "boot B: never reached step 5 (pages seen:$DRIVE_STEPS) -- sections 2 and 3 could not be set up"
fi
qi "$B" key tab >/dev/null; sleep 3
B_NVME_1=$(digest "$B_NVME"); B_VBLK_1=$(digest "$B_VBLK")
if [ "$B_NVME_1" = "$B_NVME_0" ] && [ "$B_VBLK_1" = "$B_VBLK_0" ]; then
    ok "boot B: both targets are still untouched with a target selected on the disk page"
else
    bad "boot B: a target changed before the held key was sent -- nothing in section 2 can be attributed to it"
fi

say "   2 -- ONE Return, HELD DOWN for 3 s, on the disk page with a target selected"
qi "$B" hold ret 3 >/dev/null
sleep 28
shot "$B" b_afterhold || true
info "after the held Return: $(shot_txt "$B" b_afterhold | tr '\n' '|' | cut -c1-240)"
B_NVME_2=$(digest "$B_NVME"); B_VBLK_2=$(digest "$B_VBLK")
HELD_ERASED=0
[ "$B_NVME_2" != "$B_NVME_1" ] && HELD_ERASED=1
[ "$B_VBLK_2" != "$B_VBLK_1" ] && HELD_ERASED=1
if [ "$HELD_ERASED" = 1 ]; then
    bad "ONE HELD KEY ERASED A DISK. Return was pressed once and held; the autorepeat carried the person across the summary page they were meant to read and into the erase."
elif [ "$REPEATS" = 1 ]; then
    ok "a Return held for 3 s -- with autorepeat MEASURED to arrive on this machine in section 0 -- did not erase either target"
else
    ok "the held Return did not erase either target, but section 0 did not show autorepeat arriving, so this is UNMEASURED rather than evidence that a held key is safe"
fi

say "   2b -- TEN Returns with no delay between them (the QUEUE shape)"
# Back to the disk page first, BY CLICKING Back, so this section starts where
# it says it does whatever the held key did. Back is at (BACK_X, _footer_y())
# = (20, 426), 96 x 30 in window coordinates.
qi "$B" click $(( WIN_X + 20 + 48 )) $(( WIN_Y + 426 + 15 )) "$SCREEN_W" "$SCREEN_H" >/dev/null
sleep 3
shot "$B" b_back || true
info "after clicking Back: $(shot_txt "$B" b_back | tr '\n' '|' | cut -c1-200)"
B_NVME_3=$(digest "$B_NVME"); B_VBLK_3=$(digest "$B_VBLK")
qi "$B" burst ret 10 >/dev/null
sleep 28
shot "$B" b_afterburst || true
info "after 10 queued Returns: $(shot_txt "$B" b_afterburst | tr '\n' '|' | cut -c1-240)"
B_NVME_4=$(digest "$B_NVME"); B_VBLK_4=$(digest "$B_VBLK")
BURST_ERASED=0
[ "$B_NVME_4" != "$B_NVME_3" ] && BURST_ERASED=1
[ "$B_VBLK_4" != "$B_VBLK_3" ] && BURST_ERASED=1
if [ "$BURST_ERASED" = 1 ]; then
    bad "A QUEUE OF RETURNS CARRIED THE PERSON THROUGH THE SUMMARY PAGE INTO AN ERASE. Ten Returns sent with no delay land in one read of the window's /keys; the wizard drains them all in a single loop pass, paints no frame between the pages, and a target's sha256 changed."
else
    ok "ten queued Returns did NOT erase a target -- a queue cannot carry the person past a page they never saw into the erase"
fi

###########################################################################
say "3 -- AND IT MUST STILL BE COMPLETABLE. This is also the POSITIVE CONTROL."
###########################################################################
# Everything above is a NEGATIVE result -- "the disk did not change". A
# negative from an instrument never seen to produce a positive is not a
# finding. So the install is now completed by the route the wizard asks for
# and the SAME digest comparison must fire.
#
# Space is the arming key and Return is Next. If the wizard needs no arming,
# the Space is harmless on the summary page and the Return completes it, so
# this section is not written to only pass on the fixed tree.
shot "$B" b_before_confirm || true
info "before the deliberate completion: $(shot_txt "$B" b_before_confirm | tr '\n' '|' | cut -c1-240)"
B_NVME_5=$(digest "$B_NVME"); B_VBLK_5=$(digest "$B_VBLK")

qi "$B" key spc >/dev/null; sleep 3
shot "$B" b_armed || true
info "after the arming key: $(shot_txt "$B" b_armed | tr '\n' '|' | cut -c1-240)"
qi "$B" key ret >/dev/null
sleep 60
shot "$B" b_installing || true
info "after arming + Return: $(shot_txt "$B" b_installing | tr '\n' '|' | cut -c1-280)"
B_NVME_6=$(digest "$B_NVME"); B_VBLK_6=$(digest "$B_VBLK")
census_report "$B"
info "boot B census: $NCENSUS samples, wsysd=$NWSYSD lines, install/hlinstall=$NINSTALL lines"

if [ "$NCENSUS" -ge 2 ] && [ "$NWSYSD" -ge 1 ]; then
    ok "the guest's ps ran $NCENSUS times and found wsysd -- so this census can see a running process, and its silence about /bin/install earlier was a reading"
else
    bad "the guest's ps census produced $NCENSUS blocks and found wsysd $NWSYSD times -- IT CANNOT SEE A RUNNING PROCESS, so no census result in this file can be read"
fi

DID_ERASE=0
[ "$B_NVME_6" != "$B_NVME_5" ] && DID_ERASE=1
[ "$B_VBLK_6" != "$B_VBLK_5" ] && DID_ERASE=1
if [ "$DID_ERASE" = 1 ]; then
    ok "THE DELIBERATE COMPLETION ERASED A TARGET (nvme $B_NVME_5 -> $B_NVME_6 / vblk $B_VBLK_5 -> $B_VBLK_6). The install is still completable from the keyboard, AND every 'the disk did not change' above is a reading from an instrument proved able to say otherwise IN THIS RUN."
elif [ "$ERASED_1" = 1 ] || [ "$HELD_ERASED" = 1 ] || [ "$BURST_ERASED" = 1 ]; then
    bad "the deliberate completion erased nothing -- but an erase WAS detected earlier in this run, so the detector works and this says the wizard could not be completed at the point section 3 tried. Read $B/shots/."
else
    bad "THE DELIBERATE COMPLETION ERASED NOTHING AND NOTHING ELSE IN THIS RUN DID EITHER. Either the installer is not completable -- which is not a fix -- or this run's erase detector never fires, in which case WITHDRAW every negative result above: they are unreadable, not passes."
fi
if [ "$NINSTALL" -ge 1 ]; then
    ok "and the guest's own ps found /bin/install running, which is the same event reported by a second instrument"
else
    bad "the census never found /bin/install even after the deliberate completion -- the two detectors disagree and this run needs reading by hand"
fi

kill_vm
printf '\nevidence: %s\n' "$WORK"
printf '\n%d PASSED, %d FAILED\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
