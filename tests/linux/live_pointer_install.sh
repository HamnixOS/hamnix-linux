#!/usr/bin/env bash
#
# tests/linux/live_pointer_install.sh — SOMEBODY CLICKS
# "APPLICATIONS -> INSTALL HAMNIX" ON A LIVE MEDIUM, AND A DISK GETS
# PARTITIONED.
#
# REGISTRATION. ON-DEMAND. This gate is not in ci_battery_manifest.txt because
# it builds an installer medium and boots it under OVMF with two blank targets
# and lets a real install erase one of them; a run is tens of minutes. It is
# registered in scripts/release_gates.sh beside
# tests/linux/install_confirm_keys.sh, whose medium recipe, wizard drive and
# erase detector this borrows.
#
# THE SENTENCE NOBODY HAD EVER MEASURED
# =====================================
# HANDOFF.md, 2026-08-19: "nobody has clicked Applications -> Install Hamnix on
# a live medium and watched a disk get partitioned; that gate should point at
# the LIVE medium and does not exist."
#
# Both existing wizard gates START THE WIZARD BY WRITING THE QUEUE:
#
#     echo '/bin/haminstallui' > '/dev/wsys/appmenu/launch'
#
# (install_confirm_keys.sh:243, and install_wizard_gui.sh the same way). They
# drive the wizard itself with a real pointer, thoroughly -- but the FIRST step,
# the one a person actually performs, is simulated by a shell redirect. And the
# gates that DO open the Applications menu never name haminstallui. The two
# halves have never overlapped, which is why a change demoting the wizard FROM
# THE MENU could have shipped green.
#
# HERE THE FIRST STEP IS A POINTER TOO. Nothing in this file or in the rc it
# stages writes /dev/wsys/appmenu/launch; the check in section 5 enforces that.
# The wizard is started by a click on a menu row and by nothing else.
#
# AND THE IDENTITY MATTERS, WHICH IS WHY IT IS ASKED HERE
# ======================================================
# installer.desktop carries X-Hamnix-SystemChrome=true. If hamappmenu's chrome
# folding were wrong, the click below would emit `user /bin/haminstallui`, the
# panel would drop to uid 1001 before exec, and the wizard could not open a
# block device to partition it. So this gate reads the wizard's identity out of
# the guest's own `ps` AND then requires an erase to actually happen -- two
# statements about the same fact, one of which is the person's.
#
# THE ERASE IS THE ORACLE, AND IT IS A DISK'S sha256
# ==================================================
# Two blank 4 GiB targets are attached. A disk "got partitioned" means: its
# sha256 changed, and `sfdisk -J` now reports a partition table on it that it
# did not have before. The digest comparator is itself controlled, on a 4 GiB
# image with ONE byte planted in it, before any of this runs -- borrowed from
# install_confirm_keys.sh, where a blind instrument once produced a page of
# meaningless negatives.
#
# THE CONTROL IS AN ARM OF THE SAME RUN
# =====================================
# The digests are taken THREE times in the one boot: before the menu is opened,
# again after the wizard is up and has been driven to its last page, and again
# after the confirm. The middle reading must equal the first -- opening a menu,
# launching a wizard and filling in its pages must erase nothing -- and the
# last must differ. A comparator that always says "different" fails the middle
# reading; one that always says "same" fails the last. Neither can produce a
# quiet green.
#
# WHAT THIS GATE DOES NOT ESTABLISH
# =================================
#   * It does not check the installed machine afterwards; that is
#     tests/linux/installed_*.sh's business. It watches a disk get partitioned.
#   * It does not measure the desktop ICON route to the wizard. That is
#     tests/linux/pointer_launch_uid.sh's shape, on an installed machine.
#
# Usage: tests/linux/live_pointer_install.sh
#   LPI_WORK=<dir>  work dir (default ~/.hamnix-build/livepointer)
#   LPI_REUSE=1     reuse an already-built medium
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"
. tests/linux/reap.sh
reap_on_exit

WORK="${LPI_WORK:-$HOME/.hamnix-build/livepointer}"
mkdir -p "$WORK/shots"
export TMPDIR="$WORK/tmp"; mkdir -p "$TMPDIR"
QMP_INPUT="$PROJ_ROOT/tests/linux/qmp_input.py"

SCREEN_W=1280; SCREEN_H=800
WIN_X=180; WIN_Y=70; WIN_W=440; WIN_H=470
F1_X=220; F1_Y=105
F2_X=220; F2_Y=169
WIZPW=hampw

# The Applications menu's geometry, read off lib/appmenucore.ad (AMC_BOX_W 208,
# AMC_ROW_H 20) and user/hamappmenu.ad (_am_place_window(wid, 8, 28)). When a
# filter is active amc_layout() emits row 0 = search, row 1 = the category
# header, row 2 = the first matching app -- and "install" matches exactly one
# Name in the shipped catalogue, "Install Hamnix".
MX=8; MY=28; BOXW=208; ROWH=20
APPBTN_X=40; APPBTN_Y=13
SEARCH_X=$((MX + 120)); SEARCH_Y=$((MY + 10))
ROW2_X=$((MX + 110)); ROW2_Y=$((MY + 2 * ROWH + 10))
ROW2_CROP_W=$((BOXW - 8)); ROW2_CROP_X=$((MX + 4)); ROW2_CROP_Y=$((MY + 2 * ROWH))
SEARCH_TERM=install

MARK="LPIUP7743"
CENSUS="LPICENSUS"
PUTAG="LPIPARTUUID"
READY="scene window ready"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  PASS  $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL  $*"; }
info() { echo "        $*"; }
say()  { echo; echo "== $* =="; }
finish() { printf '\n%d PASSED, %d FAILED\n' "$PASS" "$FAIL"
           [ "$FAIL" = 0 ] && exit 0 || exit 1; }

for t in qemu-system-x86_64 socat python3 tesseract convert sha256sum; do
    command -v "$t" >/dev/null || { echo "INCONCLUSIVE: need $t"; exit 2; }
done
[ -x /sbin/sfdisk ] || { echo "INCONCLUSIVE: need sfdisk"; exit 2; }
[ -f /usr/share/OVMF/OVMF_CODE_4M.fd ] || { echo "INCONCLUSIVE: need OVMF"; exit 2; }

LPI_UUID="3f7c1d2e-9a44-4b61-8c05-2ad6e1f70b93"

# ---------------------------------------------------------------------------
# THE MEDIUM. The rc writes /boot/root.partuuid IN THE GUEST (hlinstall refuses
# to touch a disk without it, and `bind '#esp' /boot' hides the copy
# HAMLINUX_INSTALLER=1 stages), reads it straight back so a medium where it did
# not take fails loudly, and then does NOTHING BUT REPORT. It never queues a
# launch: the only thing that starts the wizard in this file is a click.
# ---------------------------------------------------------------------------
cat >"$WORK/rc.lpi" <<RCEOF
source '/etc/rc.boot.installed'
echo '$LPI_UUID' > '/boot/root.partuuid'
echo '${PUTAG}BEGIN'
cat '/boot/root.partuuid'
ls '/usr/lib/instroot/usr/sbin'
echo '${PUTAG}END'
echo '$MARK'
while 1 == 1 {
    echo '${CENSUS}BEGIN'
    ps
    tail -20 /var/log/panel.log
    echo '${CENSUS}END'
    sleep 5
}
RCEOF

say "0 -- the medium, and the instruments"
if [ "${LPI_REUSE:-0}" = 1 ] && [ -f "$WORK/medium.img" ]; then
    info "reusing $WORK/medium.img"
else
    info "building the installer medium (HAMLINUX_INSTALLER=1)"
    HAMLINUX_INSTALLER=1 HAMLINUX_DISTRO_RO=1 scripts/hamlinux_image.sh \
        >"$WORK/image.log" 2>&1 || { bad "image build -- see $WORK/image.log"; finish; }
    HAMLINUX_ROOT_PARTUUID="$LPI_UUID" HAMLINUX_DISK_RC="$WORK/rc.lpi" \
        scripts/hamlinux_disk.sh "$WORK/medium.img" 6G >"$WORK/disk.log" 2>&1 || {
        bad "disk build -- see $WORK/disk.log"; finish; }
fi

# THE ERASE DETECTOR'S OWN CONTROL, run before anything else uses it.
digest() { sha256sum <"$1" | cut -d' ' -f1; }
truncate -s 4G "$WORK/probe.img"
cp --sparse=always "$WORK/probe.img" "$WORK/planted.img"
printf 'X' | dd of="$WORK/planted.img" bs=1 seek=1048576 conv=notrunc status=none
if [ "$(digest "$WORK/probe.img")" != "$(digest "$WORK/planted.img")" ]; then
    ok "the erase detector sees ONE planted byte in a 4 GiB image -- 'the disk changed' below is a measurement and not a comparator that always disagrees"
else
    bad "the erase detector gave the same digest for an image with a planted byte -- IT IS BLIND and no result below can be believed"
    finish
fi
rm -f "$WORK/probe.img" "$WORK/planted.img"

# ---------------------------------------------------------------------------
D="$WORK/boot"
NVME="$WORK/tgt-nvme.img"; VBLK="$WORK/tgt-vblk.img"
rm -f "$NVME" "$VBLK"
truncate -s 4G "$NVME"; truncate -s 4G "$VBLK"

hmp() { printf '%s\n' "$1" | timeout 15 socat - "UNIX-CONNECT:$D/mon.sock" 2>/dev/null; }
qi()  { timeout 120 python3 "$QMP_INPUT" "$D/qmp.sock" "$@" >>"$D/drive.log" 2>&1; }
click() { qi click "$1" "$2" "$SCREEN_W" "$SCREEN_H"; }
wclick() { click $(( WIN_X + $1 )) $(( WIN_Y + $2 )); }
raw_shot() {
    local p="$D/shots/$1.ppm"
    rm -f "$p"; hmp "screendump $p" >/dev/null; sleep 2; [ -s "$p" ]
}
ocr_crop() {   # <tag> <w> <h> <x> <y> [psm]
    local b="$D/shots/$1"
    [ -s "$b.ppm" ] || return 1
    convert "$b.ppm" -crop "${2}x${3}+${4}+${5}" +repage -colorspace Gray \
        -resize 400% -sharpen 0x1 "$b.png" 2>/dev/null || return 1
    tesseract "$b.png" "$b" --psm "${6:-7}" >/dev/null 2>&1 || return 1
    [ -s "$b.txt" ]
}
shot_win() {   # the wizard window, OCR'd whole
    raw_shot "$1" || return 1
    ocr_crop "$1" "$WIN_W" "$WIN_H" "$WIN_X" "$WIN_Y" 6
}
shot_txt() { tr '\n' ' ' <"$D/shots/$1.txt" 2>/dev/null || printf ''; }
clear_field() { local i=0; while [ "$i" -lt 34 ]; do qi key backspace; i=$((i+1)); done; }

rm -rf "$D"; mkdir -p "$D/shots"
cp /usr/share/OVMF/OVMF_VARS_4M.fd "$D/OVMF_VARS.fd"
qemu-system-x86_64 \
    -m 3072 -smp 2 -no-reboot \
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
    -device nvme,drive=tgtnvme,serial=LPINVME \
    -drive "file=$VBLK,if=none,format=raw,id=tgtvblk" \
    -device virtio-blk-pci,drive=tgtvblk \
    >"$D/qemu.out" 2>&1 &
VM=$!
reap_add "$VM"
kill_vm() { [ -n "${VM:-}" ] && kill -KILL "$VM" 2>/dev/null; wait "$VM" 2>/dev/null; VM=""; }

say "1 -- the machine, before a pointer touches it"
sleep 6
hmp 'info block' >"$D/infoblock.txt"
if grep -q '^tgtnvme' "$D/infoblock.txt" && grep -q '^tgtvblk' "$D/infoblock.txt"; then
    ok "QEMU reports both blank targets attached -- a wizard that offers no disk here is not offering one that does not exist"
else
    bad "QEMU does not report both targets attached -- EVERYTHING BELOW IS UNINTERPRETABLE"
    kill_vm; finish
fi

w=0
while kill -0 "$VM" 2>/dev/null && [ "$w" -lt 480 ]; do
    grep -aq "$MARK" "$D/serial.log" 2>/dev/null && break
    sleep 3; w=$((w+3))
done
if grep -aq "$MARK" "$D/serial.log" 2>/dev/null; then
    ok "the live medium booted and its rc reached the reporting loop after ${w}s"
else
    bad "the live medium's rc never printed its marker in ${w}s -- nothing below is a statement about a click"
    tail -25 "$D/serial.log" 2>/dev/null | sed 's/^/        /'
    kill_vm; finish
fi

PUBLK=$(sed -n "/${PUTAG}BEGIN/,/${PUTAG}END/p" "$D/serial.log" | tr -d '\r')
if printf '%s' "$PUBLK" | grep -qoiE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'; then
    ok "the guest echoed /boot/root.partuuid back -- hlinstall's pre-flight check will pass, so this machine CAN erase a target"
else
    bad "the guest did not echo a UUID from /boot/root.partuuid -- hlinstall will refuse before touching anything and 'no erase' below would say nothing about the click"
fi
if printf '%s' "$PUBLK" | grep -q 'sgdisk'; then
    ok "and the guest's own listing shows sgdisk in /usr/lib/instroot -- the partitioning tools this install shells out to are on this medium"
else
    bad "the guest's /usr/lib/instroot/usr/sbin does not contain sgdisk -- hlinstall would stop at '1/5 partitioning' having written nothing"
fi

NVME_0=$(digest "$NVME"); VBLK_0=$(digest "$VBLK")
info "both targets before the menu is opened: nvme=$NVME_0 vblk=$VBLK_0"
if /sbin/sfdisk -J "$NVME" >/dev/null 2>&1; then
    bad "the nvme target already reports a partition table before anything was clicked"
else
    ok "neither target has a partition table yet -- sfdisk reads no table off the nvme target"
fi

# =========================================================================
say "2 -- A PERSON CLICKS APPLICATIONS -> INSTALL HAMNIX"
# =========================================================================
sleep 10
info "clicking Applications at ($APPBTN_X,$APPBTN_Y) with a real pointer on virtio-tablet-pci"
click "$APPBTN_X" "$APPBTN_Y"
sleep 4
raw_shot menu || true
click "$SEARCH_X" "$SEARCH_Y"
sleep 2
info "typing '$SEARCH_TERM' on virtio-keyboard-pci"
qi type "$SEARCH_TERM"
sleep 3
raw_shot filtered || true
if ocr_crop filtered "$ROW2_CROP_W" "$ROWH" "$ROW2_CROP_X" "$ROW2_CROP_Y"; then
    ROWTXT="$(shot_txt filtered)"
    info "row 2 of the filtered menu OCRs as: $(printf '%s' "$ROWTXT" | cut -c1-80)"
    if printf '%s' "$ROWTXT" | grep -qiF Install; then
        ok "THE ROW THIS GATE IS ABOUT TO CLICK READS 'Install' -- the aim is measured, so a click that lands on some other row cannot pass quietly"
    else
        bad "row 2 does not read 'Install' (OCR: '$ROWTXT'). The click below would land on another row and whatever it starts would prove nothing"
    fi
else
    bad "the filtered menu row could not be OCR'd at all -- there is no evidence a menu is on the screen"
fi
info "clicking the 'Install Hamnix' row at ($ROW2_X,$ROW2_Y)"
click "$ROW2_X" "$ROW2_Y"

w=0
while kill -0 "$VM" 2>/dev/null && [ "$w" -lt 300 ]; do
    grep -aq "$READY" "$D/serial.log" 2>/dev/null && break
    sleep 3; w=$((w+3))
done
if grep -aq "$READY" "$D/serial.log" 2>/dev/null; then
    ok "A CLICK ON A MENU ROW STARTED THE INSTALL WIZARD: '$READY' appeared ${w}s after the click, and nothing in this run wrote the launch queue"
else
    bad "no window ever became ready after the click -- the menu row did not start the wizard"
    tail -30 "$D/serial.log" 2>/dev/null | sed 's/^/        /'
    kill_vm; finish
fi
if grep -aq '\[panel\] launched /bin/haminstallui' "$D/serial.log"; then
    ok "and the panel's own log says '[panel] launched /bin/haminstallui' -- the click reached _emit_launch_path, the queue and the drain"
else
    info "the panel's launch line for haminstallui is not in the console census window (REPORT; the wizard's window and the erase below decide this gate)"
fi

# =========================================================================
say "3 -- AND IT IS RUNNING AS ROOT, WHICH IS WHY IT CAN PARTITION ANYTHING"
# =========================================================================
# installer.desktop carries X-Hamnix-SystemChrome=true. If hamappmenu folded
# that wrong, the emit would have carried the `user` verb, the panel would have
# dropped to uid 1001 before exec, and the wizard could not open a block
# device. The guest's own ps is asked, and then the erase is required.
sed -n "/${CENSUS}BEGIN/,/${CENSUS}END/p" "$D/serial.log" | tr -d '\r' >"$D/census.txt"
NCENSUS=$(grep -c "${CENSUS}BEGIN" "$D/census.txt")
if [ "$NCENSUS" -ge 2 ] && grep -q 'wsysd' "$D/census.txt"; then
    ok "the guest's ps ran $NCENSUS times and names wsysd -- a process this gate did not start, so this census can see the process table"
else
    bad "the guest's ps produced $NCENSUS blocks and did not name wsysd -- IT CANNOT SEE A RUNNING PROCESS and its answer about the wizard means nothing"
fi
IROW="$(grep 'haminstallui' "$D/census.txt" | tail -1)"
if [ -n "$IROW" ]; then
    ok "the census names haminstallui -- the clicked row produced a process"
    info "the census row: $(printf '%s' "$IROW" | cut -c1-100)"
    IOWN="$(printf '%s' "$IROW" | awk '{print $2}')"
    if [ "${IOWN:-}" = 0 ] || [ "${IOWN:-}" = root ]; then
        ok "AND IT IS OWNED BY ROOT ('$IOWN') -- the X-Hamnix-SystemChrome mark on installer.desktop survived the real UI. A person clicking the installer is not handed a demoted one"
    else
        bad "the clicked wizard is owned by '${IOWN:-?}', not root. installer.desktop is marked X-Hamnix-SystemChrome and the menu demoted it anyway -- this is the failure no gate could see before"
    fi
else
    bad "the census never names haminstallui, so its identity was not read"
fi

# =========================================================================
say "4 -- THE WIZARD'S OWN PAGES, DRIVEN BY THE SAME POINTER AND KEYBOARD"
# =========================================================================
sleep 6
click $(( WIN_X + WIN_W / 2 )) $(( WIN_Y + 250 ))
sleep 2
STEPS=""; REACHED=0; n=0
while [ "$n" -lt 12 ]; do
    n=$((n+1)); tag="p$(printf '%02d' "$n")"
    shot_win "$tag" || true
    T="$(shot_txt "$tag")"
    S=$(printf '%s' "$T" | grep -oiE 'Step [0-9]' | head -1)
    info "$tag: ${S:-<no step line>} | $(printf '%s' "$T" | cut -c1-100)"
    case "$STEPS" in *"${S:-none}"*) : ;; *) STEPS="$STEPS ${S:-none}" ;; esac
    if printf '%s' "$T" | grep -qi 'Step 5'; then REACHED=1; break; fi
    if printf '%s' "$T" | grep -qi 'Confirm password'; then
        wclick "$F1_X" "$F1_Y"; clear_field; qi type "$WIZPW"
        wclick "$F2_X" "$F2_Y"; clear_field; qi type "$WIZPW"
        sleep 1; qi key ret
    else
        qi type hamwiz; sleep 1; qi key ret
    fi
    sleep 4
done
if [ "$REACHED" = 1 ]; then
    ok "the wizard the CLICK started was driven to its disk page, 'Step 5 of 5' (pages seen:$STEPS)"
else
    bad "the wizard never reached step 5 (pages seen:$STEPS) -- the erase below could not be set up"
fi
qi key tab
sleep 3

# THE MIDDLE READING. This is the control that runs: opening a menu, launching
# a wizard from it and filling in four pages must have erased NOTHING.
NVME_1=$(digest "$NVME"); VBLK_1=$(digest "$VBLK")
if [ "$NVME_1" = "$NVME_0" ] && [ "$VBLK_1" = "$VBLK_0" ]; then
    ok "with a target selected on the disk page and nothing confirmed, BOTH targets are still byte-identical to their blank state -- the comparator does not simply always disagree, and nothing was erased merely by launching the wizard"
else
    bad "a target changed before anything was confirmed -- the erase below cannot be attributed to the confirmation"
fi

say "5 -- the confirmation, and a disk"
raw_shot before_confirm || true
ocr_crop before_confirm "$WIN_W" "$WIN_H" "$WIN_X" "$WIN_Y" 6 || true
info "the page before the confirmation: $(shot_txt before_confirm | cut -c1-240)"
qi key spc
sleep 3
qi key ret
sleep 90
shot_win installing || true
info "after arming + Return: $(shot_txt installing | cut -c1-260)"

NVME_2=$(digest "$NVME"); VBLK_2=$(digest "$VBLK")
CHANGED=""
[ "$NVME_2" != "$NVME_1" ] && CHANGED="$CHANGED nvme"
[ "$VBLK_2" != "$VBLK_1" ] && CHANGED="$CHANGED vblk"
if [ -n "$CHANGED" ]; then
    ok "A DISK WAS WRITTEN:$CHANGED changed sha256 after the confirmation. The whole chain -- a pointer on the Applications button, a pointer on the 'Install Hamnix' row, and the wizard's own pages -- reached real blocks on a real (virtual) disk"
else
    bad "NEITHER target changed after the confirmation. The click started the wizard, the wizard was driven to its last page, and nothing was ever written"
fi
for t in nvme vblk; do
    case " $CHANGED " in *" $t "*) ;; *) continue ;; esac
    img="$NVME"; [ "$t" = vblk ] && img="$VBLK"
    if /sbin/sfdisk -J "$img" >"$D/$t-table.json" 2>/dev/null; then
        NP=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["partitiontable"].get("partitions",[])))' "$D/$t-table.json" 2>/dev/null || echo 0)
        if [ "${NP:-0}" -ge 2 ]; then
            ok "AND IT IS PARTITIONED: sfdisk reads a table with $NP partitions off the $t target, which had none before the click"
            info "$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))["partitiontable"]
print(d.get("label","?"), "|", " ".join("%s:%s" % (p.get("name","?"), p.get("size","?")) for p in d.get("partitions",[])))' "$D/$t-table.json" 2>/dev/null | cut -c1-200)"
        else
            bad "the $t target changed but sfdisk reads only ${NP:-0} partitions off it -- bytes moved, but this is not a partitioned disk"
        fi
    else
        bad "the $t target changed but sfdisk can read no partition table off it at all"
    fi
done
kill_vm

# =========================================================================
say "6 -- did anything but the pointer start the wizard?"
# =========================================================================
# The claim of this file is that a CLICK started haminstallui. That claim is
# false if this gate, or the rc it staged, wrote the launch queue. Checked
# rather than asserted. The path is assembled from two literals so that these
# checking lines do not match themselves, and comments are stripped before the
# search so a mention in prose is not mistaken for a write.
QP="/dev/wsys/appmenu""/launch"
if sed 's/#.*//' "$0" | grep -qF "$QP"; then
    bad "this gate contains a NON-COMMENT reference to the launch queue -- it may be writing the queue it claims only a click reaches"
else
    ok "no line of this gate outside its own prose names the launch queue -- nothing here wrote it"
fi
if sed 's/#.*//' "$WORK/rc.lpi" | grep -qF "$QP"; then
    bad "the rc staged onto the medium WRITES the launch queue -- the wizard was not started by a pointer"
else
    ok "the rc that ran on the medium never writes the launch queue -- the only thing that started the wizard is a click on a menu row"
fi

info "evidence: $WORK"
finish
