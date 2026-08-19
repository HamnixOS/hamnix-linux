#!/usr/bin/env bash
#
# tests/linux/pointer_launch_uid.sh — A REAL POINTER, ON A REAL ROW, AND WHOSE
# PROCESS IS IT AFTERWARDS?
#
# REGISTRATION. ON-DEMAND. This gate is not in ci_battery_manifest.txt because
# it builds a medium, installs a machine onto a blank disk and then boots that
# machine once per arm under OVMF -- six QEMU boots and a full image build, far
# past the battery's per-shard budget. It is registered in
# scripts/release_gates.sh beside tests/linux/installed_launch_uid.sh, whose
# debugfs reader, medium build and install step this borrows almost unchanged.
#
# THE HOLE THIS FILLS
# ===================
# tests/linux/installed_launch_uid.sh proved that a payload of `user <path>` on
# /dev/wsys/appmenu/launch produces a process owned by uid 1001 and a document
# owned by uid 1001 on the disk. It says so itself, under WHAT THIS GATE DOES
# NOT ESTABLISH:
#
#     IT DOES NOT CLICK AN ICON OR A MENU ROW. It drives the queue that a
#     click writes to.
#
# So the step from A PERSON PUTTING A POINTER ON A ROW to `_emit_launch_path()`
# writing `user <path>` rested on static assertions and a native compile. And
# there was a demonstrated hole of exactly that shape: the two gates that start
# the install wizard write the queue directly and never open a menu, while the
# gates that drive the menu never name a chrome program at all. THE TWO HALVES
# DID NOT OVERLAP, so a change that demoted a chrome program FROM THE MENU
# would have shipped green.
#
# This gate closes both halves in one run. Every launch below begins with a
# pointer event that left the host over QMP `input-send-event` and arrived in
# the guest on virtio-tablet-pci. NOTHING here writes /dev/wsys/appmenu/launch.
# The check at the end of this file enforces that.
#
# THE TWO ROUTES, BECAUSE THEY ARE DIFFERENT CODE
# ===============================================
#   MENU  user/hamappmenu.ad paints a row; a click on it calls
#         _emit_launch_path(), which writes `user <path>` (or a BARE path for
#         a chrome row) to /dev/wsys/appmenu/launch; user/hampanelscene.ad's
#         _drain_one_launch_queue() parses it and spawns.
#   ICON  user/hamdesktop.ad paints a cell; a double-click calls _run_action(),
#         which does NOT touch the launch queue at all -- it calls
#         spawn_detached_as() itself. That column was changed on 2026-08-19 and
#         WAS EXERCISED BY NO BOOT IN THIS TREE. Its privilege-drop branch is
#         booted here for the first time.
#
# THE NEGATIVE CONTROL IS AN ARM OF THE SAME RUN, AND IT ISOLATES ONE KEY
# ======================================================================
# The chrome arms do not run a different program. The machine's own rc writes
# TWO EXTRA .desktop files before the desktop starts:
#
#     /etc/hamde/apps/qwrite.desktop      Name=Qwrite Copy   Exec=/bin/hamwrite
#     ~/Desktop/qslides.desktop           Name=Qslides Copy  Exec=/bin/hamslides
#
# Each is a plausible copy of a shipped person's launcher with ONE LINE ADDED:
# `X-Hamnix-SystemChrome=true`. So arm MENUCHROME launches /bin/hamwrite -- the
# SAME PROGRAM arm MENUPERSON launches -- from the same menu, with the same
# pointer, through the same emit function, and the only difference in the
# entire run is that one key. If both arms come out the same uid, the marking
# does nothing and this gate FAILS on that. The same holds for ICONCHROME
# against ICONPERSON on /bin/hamslides.
#
# A fifth arm clicks the SHIPPED Control Center row, which is the chrome entry
# a person can actually reach on an installed machine, so the marking is
# measured on a file this tree ships and not only on one this gate writes.
#
# WHY NOT THE INSTALLER ENTRY: installer.desktop carries X-Hamnix-LiveOnly=true,
# so hamappmenu and hamdesktop both HIDE it on an installed machine. Clicking
# Applications -> Install Hamnix belongs on the LIVE medium and is NOT reached
# by this file. Said plainly rather than approximated with a different row.
#
# THE INSTRUMENTS, AND NEITHER IS A SERIAL LINE
# =============================================
#   (a) THE PROCESS CENSUS. The machine's rc runs `ps` INTO A FILE ON THE EXT4
#       while the launched program is up; this gate reads it with debugfs after
#       the machine has powered itself off. `ps` prints the owner column, so
#       this is the launched process's identity as the kernel holds it.
#   (b) THE BYTES ON THE DISK. In the two PERSON arms the program's own
#       keyboard is driven over QMP -- click into the body, type a marker,
#       Ctrl-S -- and the document's owner is read off the UNMOUNTED partition
#       with debugfs. That is the defect in the terms of the person who saved
#       it.
#   The chrome arms carry instrument (a) only, and that is a real asymmetry:
#   they are not driven to save, because a root-owned document dropped into
#   the account's Documents directory would poison the precondition of every
#   arm after it. Said here rather than papered over.
#
# CONTROLS THAT RUN, NOT ASSUMPTIONS
# ==================================
#   * THE AIM IS MEASURED BEFORE THE CLICK. In the menu arms the search box is
#     typed into with a term that matches exactly ONE catalogue Name, so the
#     row model is deterministic (row 0 search, row 1 category header, row 2
#     the app -- lib/appmenucore.ad amc_layout, filtering branch). That row's
#     band is OCR'd BEFORE it is clicked and must read the expected name. A
#     mis-aimed click therefore cannot pass quietly.
#   * THE ICON ARMS PIN THEIR TARGET. The rc writes ~/Desktop/.hamdesktop.pos,
#     which user/hamdesktop.ad's _load_positions() honours, so the two icons
#     under test sit at cell origins this gate chose. hamdesktop's own
#     published table (/tmp/.hamdesktop.src) is copied onto the ext4 and read
#     back afterwards, and the pinned coordinates must appear in it.
#   * The debugfs reader must find a file that is certainly there and must NOT
#     find one that is certainly not.
#   * The census must name a process this gate did not start.
#   * The account's Documents directory must exist, be owned by 1001, and hold
#     neither document before any arm runs.
#   * The OCR must not report a string that is certainly not on the screen.
#
# WHAT THIS GATE DOES NOT ESTABLISH
# =================================
#   * It does not click Applications -> Install Hamnix on a LIVE medium and
#     watch a disk get partitioned. That gate still does not exist.
#   * It does not rebuild the medium with the fix removed; its red arms are
#     chrome-marked copies inside the same boot sequence.
#   * It says nothing about hamUId, which is started on no medium this tree
#     builds.
#
# Usage: tests/linux/pointer_launch_uid.sh
#   PLU_WORK=<dir>   work dir (default ~/.hamnix-build/ptrlaunch)
#   PLU_REUSE=1      reuse an already-built medium and installed disk
#   PLU_ARMS="..."   run only these arms
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

. tests/linux/reap.sh
reap_on_exit

W="${PLU_WORK:-$HOME/.hamnix-build/ptrlaunch}"
mkdir -p "$W"
export TMPDIR="$W/tmp"; mkdir -p "$TMPDIR"

LIVE="$W/live-usb.img"
NVME="$W/target-nvme.img"
PART="$W/part.img"
EXTRA="$W/extra"
SCREEN_W=1280
SCREEN_H=800
QMP_INPUT="$PROJ_ROOT/tests/linux/qmp_input.py"

USERNAME=hamptruser
HOSTNAME_=hamptrbox
UPASS=hamptrpw
RPASS=hamptradmin
MARK=hamptrmark

# ---- THE MENU'S GEOMETRY -------------------------------------------------
# Every number is read off the shipped source, not tuned to a screenshot:
# lib/appmenucore.ad's AMC_BOX_W (208) and AMC_ROW_H (20), and
# user/hamappmenu.ad's _am_place_window(wid, 8, 28). Same derivation as
# tests/linux/de_appmenu_realboot.sh, which clicks the same button.
MX=8; MY=28; BOXW=208; ROWH=20
APPBTN_X=40; APPBTN_Y=13
SEARCH_CLICK_X=$((MX + 120)); SEARCH_CLICK_Y=$((MY + 10))
ROW2_X=$((MX + 110)); ROW2_Y=$((MY + 2 * ROWH + 10))
ROW2_CROP_W=$((BOXW - 8)); ROW2_CROP_X=$((MX + 4)); ROW2_CROP_Y=$((MY + 2 * ROWH))

# ---- THE ICON COLUMN'S GEOMETRY -----------------------------------------
# Not derived: CHOSEN, and then imposed on the desktop through the position
# sidecar user/hamdesktop.ad already honours. CELL_W is 84 and CELL_H is 72,
# so a click 40 px right and 30 px down from the pinned origin is inside the
# cell and clear of both panels.
ICONP_X=600; ICONP_Y=300          # the person's icon (Presentation)
ICONC_X=600; ICONC_Y=420          # the chrome-marked copy (Qslides Copy)

# ===========================================================================
# THE ARMS. One boot each, on ONE installed disk, selected by marker files.
# ===========================================================================
ARMS="${PLU_ARMS:-menuperson menuchrome menushipped iconperson iconchrome}"
arm_route() { case "$1" in menu*) echo menu;; *) echo icon;; esac; }
arm_term()  { case "$1" in menuperson) echo word;; menuchrome) echo qwrite;;
                           menushipped) echo control;; *) echo -;; esac; }
arm_label() { case "$1" in menuperson) echo "Word Processor";;
                           menuchrome) echo "Qwrite Copy";;
                           menushipped) echo "Control Center";;
                           iconperson) echo "Presentation";;
                           iconchrome) echo "Qslides Copy";; esac; }
arm_prog()  { case "$1" in menuperson|menuchrome) echo hamwrite;;
                           menushipped) echo hamctl;;
                           iconperson|iconchrome) echo hamslides;; esac; }
arm_uid()   { case "$1" in menuperson|iconperson) echo 1001;; *) echo 0;; esac; }
arm_ext()   { case "$1" in menuperson) echo hdoc;; iconperson) echo hamslides;;
                           *) echo -;; esac; }
arm_geom()  { case "$(arm_prog "$1")" in hamwrite)  echo "80 40 720 552";;
                                         hamslides) echo "100 60 720 500";;
                                         *) echo "- - - -";; esac; }
arm_icon_xy() { case "$1" in iconperson) echo "$ICONP_X $ICONP_Y";;
                             iconchrome) echo "$ICONC_X $ICONC_Y";;
                             *) echo "- -";; esac; }
# What the OCR of the row band must NOT say. A control on the OCR itself.
NOTONSCREEN="Step 5 of 5"

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

# ---- reading an ext4 without mounting it (from installed_launch_uid.sh) ---
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
echo 'PLU-LIVE: the medium booted'
install --auto /dev/nvme0n1 --hostname $HOSTNAME_ --user $USERNAME --user-pass $UPASS --root-pass $RPASS
echo 'PLU-LIVE: the installer returned'
echo 'PLU-LIVE-DONE'
sleep 8
poweroff
RCEOF

if [ "${PLU_REUSE:-0}" = 1 ] && [ -f "$LIVE" ] && [ -s "$NVME" ]; then
    info "reusing $LIVE and $NVME (PLU_REUSE=1)"
else
    # PLU_FASTMEDIUM=1 keeps the build/image tree an earlier run left behind
    # (which is already the HAMLINUX_INSTALLER=1 one, because that is the last
    # pass below) and the seed disk, and rebuilds only the live medium and the
    # install. It exists so that a fix to THE rc -- which is baked into the
    # medium -- can be re-measured without repeating two full compiles of 118
    # applications. It is NOT the default: a fresh run compiles everything.
    if [ "${PLU_FASTMEDIUM:-0}" = 1 ] && [ -f build/image/vmlinuz ] && [ -f "$W/seed.img" ]; then
        info "PLU_FASTMEDIUM=1: keeping the existing build/image and seed disk, rebuilding only the medium and the install"
    else
    info "building the medium (four passes; this is the slow part)"
    scripts/hamlinux_image.sh >"$W/img1.log" 2>&1 || {
        bad "lean image build -- see $W/img1.log"; finish; }
    # The SEED DISK is what writes /boot/root.partuuid; hlinstall refuses to
    # partition anything without it. See installed_launch_uid.sh's note.
    scripts/hamlinux_disk.sh "$W/seed.img" 3G >"$W/disk1.log" 2>&1 || {
        bad "seed disk build -- see $W/disk1.log"; finish; }
    fi

    # ---- THE MACHINE'S OWN BOOT rc ---------------------------------------
    # Staged as etc/rc.boot.machine on the MEDIUM; user/hlinstall.ad copies it
    # to the target as /etc/rc.boot.
    #
    # THE STAGING BLOCK RUNS FIRST, BEFORE rc.boot.installed, and that ordering
    # is load-bearing: hamdesktop scans ~/Desktop once at startup, so a
    # launcher written after rc.5 has started would not be on the desktop at
    # all. hamappmenu is spawned fresh on every Applications click and would
    # not have cared, but one ordering for both is simpler to reason about.
    #
    # NOTHING IN THIS rc WRITES /dev/wsys/appmenu/launch. That is the whole
    # point of this file: the only thing that reaches the launch queue is a
    # pointer event this gate sends over QMP.
    #
    # THE ORDER INSIDE A PHASE IS NOT COSMETIC, AND TWO RUNS PAID FOR IT.
    # It used to read: ps, then `cat /tmp/.hamdesktop.src`, then the PHASE
    # MARKER, then poweroff. THE cat DOES NOT ALWAYS RETURN, so the marker was
    # not written, the machine did not power off, and THE NEXT BOOT RAN THE
    # SAME PHASE AGAIN. menuperson's own numbers were real (the census and the
    # document both reached the ext4 before the block), but every arm after it
    # would have been a second menuperson wearing another arm's name and the
    # gate would have reported five arms having measured one. It was caught by
    # reading the second boot's serial log, not by an assertion.
    #
    # WHY THE cat BLOCKS, measured across the two runs: the three arms whose
    # boot HAD /tmp/.hamdesktop.src powered off cleanly; the two whose boot did
    # not, hung. user/hamdesktop.ad's _report_icon_source() is explicitly
    # best-effort ("a read-only /tmp simply skips it"), so the file can be
    # absent -- and `cat` with a path it cannot open falls back to STDIN, which
    # for PID 1's shell never ends. It now takes its input BY REDIRECTION, so
    # an absent file fails the redirect instead of arming an infinite read.
    #
    # The marker is written FIRST regardless, so a phase can never repeat even
    # if something later in the block does block.
    rm -rf "$EXTRA"; mkdir -p "$EXTRA/etc"
    {
        printf '%s\n' \
"# /etc/rc.boot -- the boot script of THIS MACHINE." \
"# Staged onto the medium by tests/linux/pointer_launch_uid.sh." \
"" \
"# --- the two chrome-marked COPIES, which are this gate's negative control." \
"# Each is a copy of a shipped person's launcher with ONE extra key." \
"echo '[Desktop Entry]' > /etc/hamde/apps/qwrite.desktop" \
"echo 'Type=Application' >> /etc/hamde/apps/qwrite.desktop" \
"echo 'Name=Qwrite Copy' >> /etc/hamde/apps/qwrite.desktop" \
"echo 'Exec=/bin/hamwrite' >> /etc/hamde/apps/qwrite.desktop" \
"echo 'Icon=x-office-document' >> /etc/hamde/apps/qwrite.desktop" \
"echo 'Categories=Office;' >> /etc/hamde/apps/qwrite.desktop" \
"echo 'X-Hamnix-SystemChrome=true' >> /etc/hamde/apps/qwrite.desktop" \
"echo '[Desktop Entry]' > /home/$USERNAME/Desktop/qslides.desktop" \
"echo 'Type=Application' >> /home/$USERNAME/Desktop/qslides.desktop" \
"echo 'Name=Qslides Copy' >> /home/$USERNAME/Desktop/qslides.desktop" \
"echo 'Exec=/bin/hamslides' >> /home/$USERNAME/Desktop/qslides.desktop" \
"echo 'Icon=x-office-presentation' >> /home/$USERNAME/Desktop/qslides.desktop" \
"echo 'Categories=Office;' >> /home/$USERNAME/Desktop/qslides.desktop" \
"echo 'X-Hamnix-SystemChrome=true' >> /home/$USERNAME/Desktop/qslides.desktop" \
"" \
"# --- pin the two icons under test where this gate will aim." \
"echo 'Presentation|$ICONP_X|$ICONP_Y' > /home/$USERNAME/Desktop/.hamdesktop.pos" \
"echo 'Qslides Copy|$ICONC_X|$ICONC_Y' >> /home/$USERNAME/Desktop/.hamdesktop.pos" \
"" \
"cat /etc/hamde/apps/qwrite.desktop > /var/lib/plu-staged-menu" \
"cat /home/$USERNAME/Desktop/qslides.desktop > /var/lib/plu-staged-icon" \
"cat /home/$USERNAME/Desktop/.hamdesktop.pos > /var/lib/plu-staged-pos" \
"echo 'PLU-STAGED'" \
"" \
"source '/etc/rc.boot.installed'"
        for a in $ARMS; do
            printf '%s\n' \
"source '/var/lib/plu.$a'" \
"if \$status > 0 {" \
"    echo 'PLU-PHASE $a route=$(arm_route "$a") label=[$(arm_label "$a")] want-uid=$(arm_uid "$a")'" \
"    sleep 22" \
"    echo 'PLU-READY $a'" \
"    sleep 105" \
"    echo '# done' > /var/lib/plu.$a" \
"    ps > /var/lib/plu-ps.$a" \
"    echo 'PLU-PS-WRITTEN $a'" \
"    echo 'PLU-CAT-BEGIN $a'" \
"    cat < /tmp/.hamdesktop.src > /var/lib/plu-icons.$a" \
"    echo 'PLU-CAT-END $a'" \
"    sleep 30" \
"    poweroff > /dev/null" \
"}"
        done
        printf '%s\n' "echo 'PLU-PHASES-EXHAUSTED'"
    } >"$EXTRA/etc/rc.boot.machine"
    info "the machine's rc drives: $ARMS"

    if [ "${PLU_FASTMEDIUM:-0}" = 1 ] && [ -f build/image/vmlinuz ]; then
        info "PLU_FASTMEDIUM=1: not recompiling the installer image"
    else
        HAMLINUX_INSTALLER=1 scripts/hamlinux_image.sh >"$W/img2.log" 2>&1 || {
            bad "installer image build -- see $W/img2.log"; finish; }
        grep -q 'INCOMPLETE' "$W/img2.log" && bad "the medium's /usr/lib/instroot is INCOMPLETE -- see $W/img2.log"
    fi

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

if [ "${PLU_REUSE:-0}" != 1 ] || [ ! -f "$W/install/serial.log" ]; then
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
        -device nvme,drive=nvme0,serial=PLUTGT \
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
if grep -aq 'PLU-LIVE-DONE' "$W/install/serial.log" 2>/dev/null; then
    ok "the install boot ran to completion on the live medium"
else
    bad "the install boot never printed PLU-LIVE-DONE -- nothing below is a statement about an installed machine"
    tail -20 "$W/install/serial.log" 2>/dev/null | sed 's/^/        /'
    finish
fi
# `install` RETURNING IS NOT `install` SUCCEEDING.
if grep -aq '^install complete' "$W/install/serial.log"; then
    ok "and the installer reported 'install complete'"
else
    bad "the installer did NOT report 'install complete': $(grep -a '^hlinstall: ' "$W/install/serial.log" | head -2 | tr '\n' ' ' | cut -c1-200)"
    finish
fi

# =========================================================================
# 1. THE STATE THE MEASUREMENT NEEDS, BEFORE ANY ARM RUNS
# =========================================================================
say "1 -- the installed disk, read with debugfs, before any pointer touches it"
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

U="$(fs_uid "$PART" "/home/$USERNAME/Documents")"
if [ "${U:-}" = 1001 ]; then
    ok "/home/$USERNAME/Documents is owned by uid 1001 -- the session CAN write there"
else
    bad "/home/$USERNAME/Documents is owned by uid ${U:-?}, not 1001"
fi
if fs_has "$PART" "/home/$USERNAME/Desktop/hamwrite.desktop"; then
    ok "/home/$USERNAME/Desktop carries the shipped launchers -- there is an icon column to click on"
else
    bad "/home/$USERNAME/Desktop/hamwrite.desktop is not on the installed disk -- there is no icon column, and the icon arms cannot mean anything"
fi
for a in $ARMS; do
    e="$(arm_ext "$a")"
    [ "$e" = - ] && continue
    if fs_has "$PART" "/home/$USERNAME/Documents/untitled.$e"; then
        bad "/home/$USERNAME/Documents/untitled.$e ALREADY exists before any drive -- finding it later would prove nothing"
    else
        ok "there is no /home/$USERNAME/Documents/untitled.$e before the drive"
    fi
done
rm -f "$PART"

# =========================================================================
# 2. ONE BOOT PER ARM. A REAL POINTER DOES ALL THE LAUNCHING.
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
# OCR an arbitrary crop of a screendump. $2..$5 = w h x y.
_ocr() {
    local p="$D/shots/$1.ppm"
    [ -s "$p" ] || return 1
    convert "$p" -crop "${2}x${3}+${4}+${5}" +repage -colorspace Gray \
        -resize 400% -sharpen 0x1 "$D/shots/$1.png" 2>/dev/null || return 1
    tesseract "$D/shots/$1.png" "$D/shots/$1" --psm 7 >/dev/null 2>&1 || return 1
    [ -s "$D/shots/$1.txt" ]
}
Q() { python3 "$QMP_INPUT" "$QMP" "$@" >>"$D/drive.log" 2>&1; }
click() { Q click "$1" "$2" "$SCREEN_W" "$SCREEN_H"; }

# THE HAND, MENU ROUTE. Click Applications; click the search row to give the
# menu the keyboard (wsysd gates keys on focus); type a term that matches
# exactly one Name; OCR row 2 and CHECK IT before clicking it.
drive_menu() {
    local a="$1" term label txt
    term="$(arm_term "$a")"; label="$(arm_label "$a")"
    info "$a: clicking Applications at ($APPBTN_X,$APPBTN_Y) with a real pointer"
    click "$APPBTN_X" "$APPBTN_Y"
    sleep 4
    _shot "$a-menu"
    click "$SEARCH_CLICK_X" "$SEARCH_CLICK_Y"
    sleep 2
    info "$a: typing '$term' on virtio-keyboard-pci"
    Q type "$term"
    sleep 3
    _shot "$a-filtered"
    if _ocr "$a-filtered" "$ROW2_CROP_W" "$ROWH" "$ROW2_CROP_X" "$ROW2_CROP_Y"; then
        txt="$(tr '\n' ' ' <"$D/shots/$a-filtered.txt")"
        info "$a: row 2 of the filtered menu OCRs as: $(printf '%s' "$txt" | cut -c1-80)"
        if printf '%s' "$txt" | grep -qiF "$(printf '%s' "$label" | cut -d' ' -f1)"; then
            ok "$a: the row this gate is about to click reads '$label' -- the AIM IS MEASURED, so a mis-aimed click cannot pass quietly"
        else
            bad "$a: row 2 does not read '$label' (OCR: '$txt'). The click below would land on some other row, and whatever it launches would prove nothing"
        fi
        if printf '%s' "$txt" | grep -qiF "$NOTONSCREEN"; then
            bad "$a: the row OCR reports '$NOTONSCREEN', which is certainly not on the screen -- it matches anything"
        else
            ok "$a: and the row OCR does NOT report text that is not there"
        fi
    else
        bad "$a: the filtered menu row could not be OCR'd at all -- there is no evidence a menu is on the screen"
    fi
    info "$a: clicking row 2 at ($ROW2_X,$ROW2_Y) with a real pointer"
    click "$ROW2_X" "$ROW2_Y"
}

# THE HAND, ICON ROUTE. TWO clicks on the same pinned cell. They do not need to
# be fast: user/hamdesktop.ad treats a click on an ALREADY-SELECTED cell as a
# double-click (`if sel_idx == idx: is_dbl = 1`), which is what makes a
# two-invocation drive over QMP work at all.
drive_icon() {
    local a="$1" cx cy
    set -- $(arm_icon_xy "$a")
    cx=$(( $1 + 40 )); cy=$(( $2 + 30 ))
    _shot "$a-desktop"
    info "$a: clicking the pinned '$(arm_label "$a")' cell at ($cx,$cy) -- select"
    click "$cx" "$cy"
    sleep 2
    _shot "$a-selected"
    info "$a: clicking the same cell again -- activate"
    click "$cx" "$cy"
}

drive_arm() {
    local a="$1" QPID i st
    D="$W/boot-$a"; rm -rf "$D"; mkdir -p "$D/shots"
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
        -device nvme,drive=nvme0,serial=PLUTGT \
        >"$D/qemu.out" 2>&1 &
    QPID=$!
    reap_add "$QPID"
    info "qemu pid $QPID, serial $D/serial.log"

    # WAIT FOR PLU-READY: the rc's own echo, a hamsh builtin in the ROOT PID-1
    # shell, whose console descriptor was opened while privileged and survives
    # the compositor presenting. Nothing else on this machine is guaranteed to
    # reach the serial line once wsysd is up.
    i=0
    while [ "$i" -lt 300 ]; do
        sleep 2; i=$((i+2))
        grep -aq "PLU-READY $a" "$D/serial.log" 2>/dev/null && break
        st=$(awk '{print $3}' "/proc/$QPID/stat" 2>/dev/null)
        case "${st:-X}" in Z|X) break ;; esac
    done
    if grep -aq "PLU-READY $a" "$D/serial.log" 2>/dev/null; then
        ok "$a: the machine reached its desktop and said so after ${i}s -- the pointer drive below happens on a live session"
    else
        bad "$a: the rc never printed PLU-READY in ${i}s -- nothing below is a statement about a click"
        tail -25 "$D/serial.log" 2>/dev/null | sed 's/^/        /'
        kill -KILL "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null
        return 1
    fi
    if grep -aq 'PLU-STAGED' "$D/serial.log" 2>/dev/null; then
        ok "$a: the rc staged its two chrome-marked launcher copies before the desktop started"
    else
        bad "$a: the rc never printed PLU-STAGED -- the chrome-marked copies may not exist, and the chrome arms would then be clicking nothing"
    fi

    sleep 3
    if [ "$(arm_route "$a")" = menu ]; then drive_menu "$a"; else drive_icon "$a"; fi

    # Let the launch land, then photograph the screen.
    sleep 12
    _shot "$a-launched"

    # THE PERSON ARMS ARE DRIVEN TO SAVE. The chrome arms are not: see the
    # header. A click into the body gives the window the keyboard and only
    # moves the caret in both of these programs.
    if [ "$(arm_ext "$a")" != - ]; then
        set -- $(arm_geom "$a")
        gx="$1"; gy="$2"; gw="$3"; gh="$4"
        click $(( gx + gw / 2 )) $(( gy + gh / 2 ))
        sleep 1
        Q type "$MARK"
        sleep 2
        _shot "$a-typed"
        if _ocr "$a-typed" "$gw" 26 "$gx" "$gy"; then
            TITLE="$(tr '\n' ' ' <"$D/shots/$a-typed.txt")"
            info "$a title bar BEFORE the save: $(printf '%s' "$TITLE" | cut -c1-110)"
            if printf '%s' "$TITLE" | grep -qi 'modif'; then
                ok "$a: BEFORE Ctrl-S the title bar reads '* modified' -- THE CLICK PRODUCED A REAL WINDOW with the keyboard focus, so a missing document afterwards is a failed WRITE and not a failed launch"
            else
                bad "$a: BEFORE Ctrl-S the title bar does not report the document as modified: '$TITLE'"
            fi
            if printf '%s' "$TITLE" | grep -qiF "$NOTONSCREEN"; then
                bad "$a: the title OCR reports text that is certainly not on the screen"
            else
                ok "$a: the title OCR does NOT report text that is not there"
            fi
        else
            bad "$a: the title bar could not be OCR'd before the save"
        fi
        Q combo ctrl s
        sleep 6
        _shot "$a-saved"
    fi

    # WAIT FOR THE MACHINE TO POWER ITSELF OFF. Killing it is a power cut and
    # ext4 would not have committed.
    i=0
    while kill -0 "$QPID" 2>/dev/null && [ "$i" -lt 300 ]; do sleep 5; i=$((i+5)); done
    if kill -0 "$QPID" 2>/dev/null; then
        bad "$a: the machine did not power itself off in ${i}s -- a MISSING file below could be a power cut rather than a failed save"
        printf 'quit\n' | timeout 10 socat - "UNIX-CONNECT:$MON" >/dev/null 2>&1
        sleep 2
        kill -TERM "$QPID" 2>/dev/null; sleep 1; kill -KILL "$QPID" 2>/dev/null
    else
        ok "$a: the machine powered itself off cleanly after the drive"
    fi
    wait "$QPID" 2>/dev/null
    return 0
}

# ==========================================================================
# THE PROCESS CENSUS, READ OFF THE EXT4 -- INSTRUMENT (a)
# ==========================================================================
check_ps_census() {
    local a="$1" want prog f owner
    want="$(arm_uid "$a")"; prog="$(arm_prog "$a")"
    f="$W/$a-ps.txt"
    if ! fs_dump "$PART" "/var/lib/plu-ps.$a" "$f"; then
        bad "$a: /var/lib/plu-ps.$a is not on the disk -- the census never ran, so there is no reading of the clicked process's identity"
        return 1
    fi
    ok "$a: the process census was written to the ext4 and read back ($(wc -l <"$f") rows)"
    if grep -q 'hampanelscene' "$f"; then
        ok "$a: the census names hampanelscene -- a process this gate did not start, so it is a census and not an echo of the query"
    else
        bad "$a: the census does not name hampanelscene, which is certainly running -- it is not reading the process table"
        sed 's/^/        /' "$f" | head -20
        return 1
    fi
    if ! grep -q "$prog" "$f"; then
        bad "$a: THE CLICK PRODUCED NO $prog PROCESS. The census has no $prog row at all"
        info "$a: what the census DOES show beyond the chrome: $(awk '$1>200 && $5!="" {print $5}' "$f" | sort -u | tr '\n' ' ' | cut -c1-200)"
        return 1
    fi
    ok "$a: THE CLICK PRODUCED A $prog PROCESS -- a pointer event on a row, and nothing else, started it"
    owner="$(grep "$prog" "$f" | head -1 | awk '{print $2}')"
    info "$a: the census row: $(grep "$prog" "$f" | head -1 | cut -c1-100)"
    if [ "$want" = 0 ]; then
        if [ "${owner:-}" = root ] || [ "${owner:-}" = 0 ]; then
            ok "$a: NEGATIVE CONTROL HOLDS -- the row is marked X-Hamnix-SystemChrome and the clicked process is owned by ROOT ('$owner'). The chrome marking survives the real UI, which is what keeps the install wizard working when a person clicks it"
        else
            bad "$a: NEGATIVE CONTROL FAILED -- a chrome-marked row was clicked and the process is owned by '${owner:-?}', not root. A chrome program demoted FROM THE MENU is exactly the failure no gate could see before this one"
        fi
    else
        if [ "${owner:-}" = "$USERNAME" ] || [ "${owner:-}" = 1001 ]; then
            ok "$a: the clicked process is owned by the SESSION USER ('$owner') -- clicking the person's launcher runs it as the person"
        else
            bad "$a: the clicked process is owned by '${owner:-?}', not $USERNAME. Clicking the person's launcher still starts it as root"
        fi
    fi
    return 0
}

# ==========================================================================
# WHAT THE LAUNCHER ITSELF SAID, READ OFF THE EXT4
# ==========================================================================
# rc.5.linux starts the panel as `/bin/hampanelscene > /var/log/panel.log` and
# the desktop as `/bin/hamdesktop > /var/log/hamdesktop.log`, so each route's
# launcher speaks into its own file on the ext4. Neither reaches the serial.
check_launcher_log() {
    local a="$1" route prog f which
    route="$(arm_route "$a")"; prog="$(arm_prog "$a")"
    if [ "$route" = menu ]; then which=/var/log/panel.log; else which=/var/log/hamdesktop.log; fi
    f="$W/$a-launcher.log"
    if ! fs_dump "$PART" "$which" "$f"; then
        info "$a: $which is not on the disk or is empty (REPORT; the census and the disk decide the arm)"
        return 0
    fi
    if [ "$route" = menu ]; then
        if grep -aq "\[panel\] launched /bin/$prog" "$f"; then
            ok "$a: the PANEL's own log says '[panel] launched /bin/$prog' -- the menu click reached _emit_launch_path, the queue and the drain, in the launcher's own words"
        else
            bad "$a: the panel's log has no '[panel] launched /bin/$prog' line: $(grep -a '\[panel\]' "$f" | tail -3 | tr '\n' ' ' | cut -c1-200)"
        fi
    else
        if grep -aq "\[hamdesktop\] launched /bin/$prog" "$f"; then
            ok "$a: the DESKTOP's own log says '[hamdesktop] launched /bin/$prog' -- the double-click reached _run_action, in the icon column's own words"
        else
            bad "$a: hamdesktop's log has no '[hamdesktop] launched /bin/$prog' line: $(grep -a '\[hamdesktop\]' "$f" | tail -3 | tr '\n' ' ' | cut -c1-200)"
        fi
    fi
    if grep -aq 'REFUSING' "$f"; then
        info "$a: the launcher REFUSED a launch rather than running it as root: $(grep -a 'REFUSING' "$f" | head -1 | cut -c1-160)"
    fi
    return 0
}

# ==========================================================================
# WHERE THE POINTER WAS AIMED, CHECKED AGAINST WHERE THE ICON ACTUALLY WAS
# ==========================================================================
check_icon_aim() {
    local a="$1" f label xy
    [ "$(arm_route "$a")" = icon ] || return 0
    label="$(arm_label "$a")"
    set -- $(arm_icon_xy "$a"); xy="$1 $2"
    f="$W/$a-icons.txt"
    # WHAT THIS CAN AND CANNOT SAY, and the difference was measured rather than
    # assumed. hamdesktop publishes its icon table to /tmp/.hamdesktop.src so a
    # gate need not re-derive the column flow. On the tree this gate first ran
    # against, the STARTUP path published that table BEFORE _load_positions()
    # applied the pins -- so it listed the default flow (x=18 and x=102) while
    # the desktop was drawing the pinned icons at (600,300) and (600,420). The
    # clicks at the pinned points launched the pinned icons' programs anyway,
    # which is how the staleness was found. user/hamdesktop.ad now re-publishes
    # after _load_positions(), so the table below should agree with the pin.
    #
    # A DISAGREEMENT HERE IS REPORTED, NOT SCORED, and that is deliberate: the
    # table is an observability surface, and scoring the gate on it would mean
    # a stale publish could turn a correct launch red. WHAT IS SCORED is which
    # program started and whose it was -- see check_launcher_log and
    # check_ps_census, both of which name the program and the identity.
    if ! fs_dump "$PART" "/var/lib/plu-icons.$a" "$f"; then
        info "$a: hamdesktop published no icon table on this boot (REPORT -- the aim is scored by which program started, below)"
        return 0
    fi
    if grep -q "^icon $xy $label\$" "$f"; then
        ok "$a: hamdesktop's OWN published table puts '$label' at the cell this gate pinned it to ($xy), so the table and the screen agree"
    else
        info "$a: hamdesktop's published table does not list '$label' at ($xy) -- it says: $(grep -F "$label" "$f" | head -1). REPORT: if the click below started the right program, the table is stale rather than the pin having failed"
    fi
    if grep -q "^src=/home/$USERNAME/Desktop " "$f"; then
        ok "$a: and the icon column was built from /home/$USERNAME/Desktop -- the person's own desktop directory"
    else
        info "$a: the icon source line reads: $(head -1 "$f")"
    fi
    return 0
}

# ==========================================================================
# THE BYTES ON THE DISK -- INSTRUMENT (b), AND THE ONE THAT DECIDES THE ARM
# ==========================================================================
check_app_file() {
    local a="$1" e f u
    e="$(arm_ext "$a")"
    [ "$e" = - ] && { info "$a: a chrome arm is not driven to save -- it carries the census only, by design (see the header)"; return 0; }
    f="/home/$USERNAME/Documents/untitled.$e"
    if fs_has "$PART" "$f"; then
        ok "$a: $f EXISTS on the installed disk -- the save landed in the account's own home"
    else
        bad "$a: $f is NOT on the installed disk. The person clicked, typed and pressed Ctrl-S and nothing was written where their account can read it"
        return 1
    fi
    if fs_dump "$PART" "$f" "$W/$a-doc.bin"; then
        ok "$a: and it is non-empty ($(stat -c%s "$W/$a-doc.bin") bytes)"
        if grep -aq "$MARK" "$W/$a-doc.bin"; then
            ok "$a: the file carries the marker string this drive typed -- it is THIS drive's document and not a leftover"
        else
            bad "$a: the file does not contain the typed marker '$MARK'"
        fi
    else
        bad "$a: the file is there but empty or unreadable"
    fi
    u="$(fs_uid "$PART" "$f")"
    if [ -z "${u:-}" ]; then
        bad "$a: the document's owner could not be read off the filesystem at all"
        return 1
    fi
    if [ "$u" = 1001 ]; then
        ok "$a: THE DOCUMENT IS OWNED BY UID 1001 -- a person put a pointer on their own launcher, and the file that came out is theirs"
    else
        bad "$a: the document is owned by uid ${u}, not 1001. A person clicked their own launcher and the file that came out is not theirs"
    fi
    local du
    du="$(fs_uid "$PART" "/home/$USERNAME/Documents")"
    if [ "${du:-}" = 1001 ]; then
        ok "$a: and the directory it sits in is still owned by uid 1001 -- file and directory agree"
    else
        bad "$a: the directory /home/$USERNAME/Documents is owned by uid ${du:-?}, not 1001"
    fi
    return 0
}

for a in $ARMS; do
    say "2 -- $a: a real pointer on the '$(arm_label "$a")' $(arm_route "$a") entry (expects /bin/$(arm_prog "$a") at uid $(arm_uid "$a"))"
    drive_arm "$a"
    say "2b -- $a: the disk, read afterwards with debugfs, nothing mounted"
    if carve "$NVME" 2; then
        fs_has "$PART" /etc/hamnix-release \
            && ok "$a: the reader still works on the post-drive disk" \
            || bad "$a: the reader cannot read the post-drive disk"
        check_icon_aim "$a"
        check_ps_census "$a"
        check_launcher_log "$a"
        check_app_file "$a"
        rm -f "$PART"
    else
        bad "$a: cannot carve the installed root partition after the drive"
    fi
done

# =========================================================================
# 3. THE INSTRUMENT'S OWN CONTROL: NOTHING HERE WROTE THE LAUNCH QUEUE
# =========================================================================
# The claim of this file is that a POINTER caused every launch above. That
# claim is falsified if anything in this gate, or in the rc it stages, writes
# /dev/wsys/appmenu/launch. So it is checked rather than asserted, against
# both this file and the rc that actually ran on the machine.
say "3 -- did anything but the pointer reach the launch queue?"
# The path is assembled from two adjacent literals so that these checking
# lines do not match THEMSELVES, and comments are stripped before the search so
# a mention in prose is not read as a write. The first version of this check
# did neither and reported a FAIL against its own source -- caught before it
# ever ran, but it is exactly the shape of "a gate's red is about its own
# grep", so it is written down here rather than quietly corrected.
QP="/dev/wsys/appmenu""/launch"
if sed 's/#.*//' "$0" | grep -qF "$QP"; then
    bad "this gate contains a NON-COMMENT reference to the launch queue -- it may be writing the queue it claims only a click reaches"
else
    ok "no line of this gate outside its own prose names the launch queue -- nothing here wrote it"
fi
if [ -f "$EXTRA/etc/rc.boot.machine" ]; then
    if sed 's/#.*//' "$EXTRA/etc/rc.boot.machine" | grep -qF "$QP"; then
        bad "the rc staged onto the machine WRITES the launch queue -- the launches above were not caused by a pointer"
    else
        ok "the rc that ran on the machine never writes the launch queue -- the only thing that reached it is a click"
    fi
else
    info "the staged rc is not in this work directory (PLU_REUSE); the queue-write check above covers this file only"
fi

# =========================================================================
say "3b -- the two ICON clicks, against each other"
# =========================================================================
# THE CLAIM THIS SECTION CARRIES: each icon click hit the icon this gate pinned
# under it, and not some other one. It is not asserted from hamdesktop's
# published table (see check_icon_aim for why that table can be stale); it is
# asserted from the fact that TWO CLICKS AT TWO DIFFERENT POINTS produced TWO
# DIFFERENT IDENTITIES.
#
# Only two entries on this desktop run /bin/hamslides -- the shipped
# Presentation and the chrome-marked copy this gate wrote -- and which identity
# a launch gets is decided by the CLICKED ICON's chrome flag (user/hamdesktop.ad
# _run_action, `if ic_chrome[i] != 0`). So a run in which one click yields 1001
# and the other yields 0 cannot be a run in which both clicks landed on the same
# cell, and cannot be a run in which either landed on bare desktop, because bare
# desktop launches nothing at all.
IP="$(grep 'hamslides' "$W/iconperson-ps.txt" 2>/dev/null | head -1 | awk '{print $2}')"
IC="$(grep 'hamslides' "$W/iconchrome-ps.txt" 2>/dev/null | head -1 | awk '{print $2}')"
if [ -n "${IP:-}" ] && [ -n "${IC:-}" ]; then
    info "iconperson clicked ($ICONP_X,$ICONP_Y)+(40,30) and got owner '$IP'; iconchrome clicked ($ICONC_X,$ICONC_Y)+(40,30) and got owner '$IC'"
    if [ "$IP" != "$IC" ]; then
        ok "TWO POINTER CLICKS AT TWO DIFFERENT POINTS ON THE DESKTOP PRODUCED TWO DIFFERENT IDENTITIES from the same program -- so each click hit the icon pinned under it, a bare-desktop miss (which launches nothing) is excluded, and the icon column's chrome branch is what separated them"
    else
        bad "both icon clicks produced owner '$IP' -- either they landed on the same cell or the icon column does not distinguish a chrome-marked launcher, and neither icon arm means what it says"
    fi
else
    info "one of the icon arms produced no hamslides census row, so the two cannot be compared (the arms are scored individually above)"
fi

say "4 -- the arms, side by side"
for a in $ARMS; do
    info "$(printf '%-12s route=%-5s prog=%-10s want-uid=%-5s label=%s' \
        "$a" "$(arm_route "$a")" "$(arm_prog "$a")" "$(arm_uid "$a")" "$(arm_label "$a")")"
done
info "menuperson and menuchrome launch THE SAME PROGRAM by THE SAME ROUTE and differ only in one key of one .desktop file; so do iconperson and iconchrome"
info "evidence: $W"
finish
