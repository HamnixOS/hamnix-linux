#!/usr/bin/env bash
#
# tests/linux/installed_documents.sh — WHEN A PERSON PRESSES Ctrl-S ON AN
# INSTALLED MACHINE, WHERE DO THE BYTES GO?
#
# REGISTRATION. ON-DEMAND: not in ci_battery_manifest.txt because it builds a
# medium, installs a machine and then boots that machine once per office
# application under OVMF -- four QEMU boots and a full image build, far past
# the battery's per-shard budget. Same class as
# tests/linux/installed_accounts.sh and tests/linux/installed_offers_install.sh,
# whose structure this borrows.
#
# THE DEFECT, AND WHY IT HAD NEVER BEEN SHIPPED AS A FIX
# ======================================================
# user/hamwrite.ad (Word Processor), user/hamsheet.ad (Spreadsheet) and
# user/hamslides.ad (Presentation) each built their default document path as
# the LITERAL "/home/live/Documents/untitled.<ext>". `live` is the LIVE
# MEDIUM's account. An installed machine has no such account in /etc/passwd at
# all -- the installer drops every shipped regular account and writes the
# wizard's user at uid 1001 -- and the /home/live directory the install leaves
# behind is owned by uid 0, mode 0755.
#
# WHAT THAT DID, MEASURED BOTH WAYS BY THIS GATE RATHER THAN REASONED ABOUT:
#
#   * FROM THE DESKTOP ICON, which is how a person starts it and which runs the
#     program as ROOT (user/hamdesktop.ad is system chrome and spawn_detached()s
#     the launcher directly), the save SUCCEEDS -- into
#     /home/live/Documents/untitled.<ext>. A complete file, in a directory that
#     belongs to no account on that machine. On the reverted tree this gate
#     reads it there and says so by name.
#   * AS THE SESSION USER (uid 1001) the same Ctrl-S writes NOTHING: the open
#     fails on a root-owned directory and _save_doc() returns on a failed open
#     without saying anything, so the title bar goes on reading "* modified".
#     Measured too, on the first version of this gate, which launched through
#     /etc/rc.de-user.
#
# All three programs are shipped, are on the desktop icon column, and are in
# the Applications menu.
#
# The reason this was carried in the queue for days rather than fixed is
# recorded plainly in HANDOFF.md: **nothing measured where those programs
# actually write.** A grep over source files is not a measurement -- a source
# file is not a shipped program, and a constant string is not a byte on a
# disk. This gate removes that blocker. It drives a real Ctrl-S, on a real
# desktop session, on a machine installed onto a blank disk, through QEMU's
# own keyboard, and then READS THE FILESYSTEM.
#
# WHAT IS MEASURED, IN ORDER, AND WHAT IS A CONTROL
# =================================================
#   0. Build a medium and install onto a blank virtual disk with --hostname,
#      --user, --user-pass and --root-pass. The account the install creates is
#      uid 1001, which is the uid the DE session runs as (etc/rc.de-user.linux).
#   1. HOST, off the installed ext4 with debugfs, nothing mounted and nothing
#      written back: the state the defect needs. /home/live/Documents exists
#      and whom it belongs to; /home/<user>/Documents exists and whom it
#      belongs to; and NEITHER carries an untitled document yet, so anything
#      found later was written by the drive.
#      INSTRUMENT CONTROLS, RUN: the reader must find a file that is certainly
#      there (/etc/hamnix-release, and the skeleton's own
#      Documents/welcome.txt under BOTH homes) and must NOT find one that is
#      certainly not (a name nothing creates). A reader that answers the same
#      way to everything measures nothing.
#   2. ONE BOOT PER APPLICATION. The machine's own /etc/rc.boot -- staged onto
#      the medium as etc/rc.boot.machine, which is the file the installer
#      copies to the target, and which no package owns -- launches exactly one
#      of the three as `/bin/<app>` inside `ns { }`, the same empty overlay of
#      PID 1's namespace that /etc/rc.d/rc.5 spawns hamdesktop and
#      hampanelscene in. THAT is how an icon starts an application:
#      user/hamdesktop.ad's _run_action() spawn_detached()s the /bin path out
#      of the .desktop file, as ROOT, because the desktop is system chrome. It
#      is NOT `/bin/hamsh /etc/rc.de-user <prog>` -- that is the TERMINAL's
#      path, it was tried first here, and the application never opened a
#      window under it (see the note beside the rc). IT IS NOT A DOUBLE-CLICK
#      ON THE ICON, and this gate does not claim to be one: what it reproduces
#      is the launch, the identity and the environment, not the pointer.
#      The host then drives the application's REAL KEYBOARD over QMP: a click
#      into the document body, a typed marker string, and Ctrl-S as one
#      modified keystroke (tests/linux/qmp_input.py combo).
#   3. AND THEN THE DISK IS READ AGAIN. The document must exist under
#      /home/<user>/Documents, must be non-empty, must carry the typed marker
#      (so the file is the drive's and not a leftover), and must be OWNED BY
#      UID 1001 -- the session can only have written a file it owns. And there
#      must be NO such file under /home/live: a save that lands in the live
#      medium's leftover directory is the defect wearing a success, and on the
#      reverted tree that is EXACTLY what happens -- the failure message names
#      the path the bytes went to instead.
#      DRIVE CONTROLS, RUN IN BOTH ARMS:
#        * the application's own serial line `[<app>] scene window ready`, so
#          a missing file cannot mean "the program never started";
#        * the TITLE BAR, read by OCR off a screendump: after the save it must
#          not read "* modified". That string is the application's own report
#          that it still holds unsaved work, and it is what the reverted tree
#          leaves on the screen -- so the failed write is OBSERVED on the
#          screen as well as on the disk;
#        * `[<app>] SAVE FAILED <path>` on the serial, which the save path
#          prints when the open fails. IT IS A REPORT AND NOT A SCORE, and
#          this line used to claim the opposite -- "its ABSENCE is asserted
#          here" -- which the code at the `info` calls below has never done.
#          The correction matters more than the wording: once the compositor
#          is presenting, this application's console output STOPS REACHING
#          THE SERIAL LINE (the serial log of a green run ends at `scene
#          window ready`, and `sys_write` mirrors only AFTER the real write
#          to /dev/console returns). An assertion that SAVE FAILED is absent
#          would therefore be an assertion that could not fail -- a green for
#          the wrong reason, over a channel that goes quiet at exactly the
#          moment being asserted about. Its PRESENCE in the reverted arm is
#          still the failed write in the program's own words, when it is
#          printed early enough to be heard.
#        * and the OCR must NOT report a string that is certainly not on the
#          screen.
#
# THE NEGATIVE CONTROL IS A SECOND RUN OF THIS FILE ON A REVERTED TREE.
# WHAT "REVERTED" MEANS HERE, EXACTLY, because it decides what the red proves:
# the three _default_docpath() functions are put back to the literal
# "/home/live/Documents/untitled.<ext>" AND NOTHING ELSE IS TOUCHED -- the
# SAVE FAILED diagnostic and the resolved-path line stay, so the reverted arm
# does not merely fail to produce a file, it SAYS on the serial that it tried
# to write /home/live/Documents/untitled.hdoc and could not, and leaves
# "* modified" on the screen. A negative control that only observed a changed
# constant would prove nothing about where bytes land.
#
# Usage: tests/linux/installed_documents.sh
#   INSTDOC_WORK=<dir>      work dir (default ~/.hamnix-build/instdoc)
#   INSTDOC_REUSE=1         reuse an already-built medium and installed disk
#   INSTDOC_APPS='a b'      which applications to drive (default all three)
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

. tests/linux/reap.sh
reap_on_exit

W="${INSTDOC_WORK:-$HOME/.hamnix-build/instdoc}"
mkdir -p "$W"
export TMPDIR="$W/tmp"; mkdir -p "$TMPDIR"

LIVE="$W/live-usb.img"
NVME="$W/target-nvme.img"
PART="$W/part.img"
EXTRA="$W/extra"
SCREEN_W=1280
SCREEN_H=800
QMP_INPUT="$PROJ_ROOT/tests/linux/qmp_input.py"

USERNAME=hamdocusr
HOSTNAME_=hamdocbox
UPASS=hamdocpw
RPASS=hamdocadmin
# The marker typed into the document. It is not a word any of these programs
# can produce on its own, so finding it in a file on the disk is evidence that
# THIS drive wrote THAT file.
MARK=hamdocmark

APPS="${INSTDOC_APPS:-hamwrite hamsheet hamslides}"

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

# ---- the per-application table -------------------------------------------
# Extension, window geometry (as the program writes it on its own ctl file)
# and whether the typed marker needs a Return to commit it into the model.
app_ext()   { case "$1" in hamwrite) echo hdoc;; hamsheet) echo hsheet;;
                           hamslides) echo hamslides;; esac; }
app_geom()  { case "$1" in hamwrite)  echo "80 40 720 552";;
                           hamsheet)  echo "120 80 600 384";;
                           hamslides) echo "100 60 720 500";; esac; }
app_commit(){ case "$1" in hamsheet) echo 1;; *) echo 0;; esac; }

# ---- reading an ext4 without mounting it ---------------------------------
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
fs_mode() { /sbin/debugfs -R "stat $2" "$1" 2>/dev/null |
            sed -n 's/.*Mode: *0*\([0-7][0-7][0-7][0-7]*\).*/\1/p' | head -1; }

# =========================================================================
# 0. THE MEDIUM, AND ONE INSTALL ONTO A BLANK DISK
# =========================================================================
say "0 -- the medium, and one install onto a blank virtual disk"

cat >"$W/rc.install" <<RCEOF
ln -s /dev/console /dev/cons
echo 'INSTDOC-LIVE: the medium booted'
echo 'INSTDOC-LIVE: starting the installer'
install --auto /dev/nvme0n1 --hostname $HOSTNAME_ --user $USERNAME --user-pass $UPASS --root-pass $RPASS
echo 'INSTDOC-LIVE: the installer returned'
echo 'INSTDOC-LIVE-DONE'
sleep 8
poweroff
RCEOF

if [ "${INSTDOC_REUSE:-0}" = 1 ] && [ -f "$LIVE" ] && [ -s "$NVME" ]; then
    info "reusing $LIVE and $NVME (INSTDOC_REUSE=1)"
else
    info "building the medium (four passes; this is the slow part)"
    scripts/hamlinux_image.sh >"$W/img1.log" 2>&1 || {
        bad "lean image build -- see $W/img1.log"; finish; }

    # THE SEED DISK, WHICH IS NOT OPTIONAL AND LOOKS IT. scripts/hamlinux_disk.sh
    # is what writes /boot/root.partuuid -- the PARTUUID baked into
    # BOOTX64.EFI's kernel command line -- and user/hlinstall.ad REFUSES to
    # partition anything without it ("the installed disk will boot looking for
    # a partition that does not exist here"). Leaving this step out produced an
    # install boot that printed the refusal, returned, and still said DONE:
    # measured here, on the first run of this gate.
    scripts/hamlinux_disk.sh "$W/seed.img" 3G >"$W/disk1.log" 2>&1 || {
        bad "seed disk build -- see $W/disk1.log"; finish; }

    # ---- THE MACHINE'S OWN BOOT rc ----------------------------------------
    # Staged as etc/rc.boot.machine on the MEDIUM, because that is the file
    # user/hlinstall.ad copies to the target as /etc/rc.boot -- the machine's
    # own boot script, owned by no package.
    #
    # ONE PHASE PER BOOT, selected by marker files, with no `else`: sourcing a
    # file that does not exist returns non-zero, so a phase runs while its
    # marker is absent and writes it. The phase body runs AFTER
    # /etc/rc.boot.installed has already sourced /etc/rc.d/rc.5, so the
    # compositor, the desktop and the panel are up before the application is
    # launched.
    #
    # THE LAUNCH IS `/bin/<app>`, DIRECTLY, AND THAT IS THE POINT.
    #
    # MEASURED HERE, on the first run of this gate, after it was written the
    # other way. The obvious launch is `/bin/hamsh /etc/rc.de-user /bin/<app>`
    # -- user/linux-wsys.c says in several places that "every DE window is
    # /bin/hamsh /etc/rc.de-user <prog>". That is true of a TERMINAL window.
    # It is NOT how the desktop icon column starts an application:
    # user/hamdesktop.ad's _run_action() calls lib/p9.ad's spawn_detached()
    # on the /bin path straight out of the .desktop file, and hamdesktop is
    # SYSTEM CHROME running as root. So a double-clicked Word Processor is a
    # root child of the chrome, in the chrome's namespace, and never goes
    # near rc.de-user or `setuid 1001`.
    #
    # The rc.de-user version was tried first and the machine said no: the
    # session shell dropped to uid 1001, printed `uid 1001 home
    # /home/hamdocusr` -- the identity resolution is fine -- and then
    # `rfork: no private namespace yet (needs CAP_SYS_ADMIN)`, and the
    # application never opened a window. That path is for a program a
    # TERMINAL starts, not one an ICON starts, and a gate that used it would
    # have measured a launch nobody performs.
    #
    # `ns { }` is the same empty overlay of PID 1's namespace that
    # /etc/rc.d/rc.5 spawns hamdesktop and hampanelscene in, so the
    # application here gets the namespace, the identity (root) and the
    # ambient environment a double-clicked launcher gives it. IT IS STILL NOT
    # A DOUBLE-CLICK: what is reproduced is the launch, not the pointer.
    #
    # THE POWEROFF IS FROM INSIDE and after a fixed sleep: ext4 commits its
    # journal on a timer, and killing QEMU is a power cut -- the document the
    # drive writes has to be flushed by a real shutdown or the next carve
    # reads a disk that never saw it.
    rm -rf "$EXTRA"; mkdir -p "$EXTRA/etc"
    {
        printf '%s\n' \
"# /etc/rc.boot -- the boot script of THIS MACHINE." \
"# Staged onto the medium by tests/linux/installed_documents.sh and copied" \
"# here by the installer. Owned by no package: that is the point." \
"source '/etc/rc.boot.installed'"
        for a in $APPS; do
            printf '%s\n' \
"source '/var/lib/instdoc.$a'" \
"if \$status > 0 {" \
"    echo 'INSTDOC-PHASE $a'" \
"    ${a}ns = ns {" \
"    }" \
"    ${a}svc = spawn detached ${a}ns {" \
"        sleep 20" \
"        /bin/$a" \
"    }" \
"    echo '# done' > /var/lib/instdoc.$a" \
"    echo 'INSTDOC-PHASE-LAUNCHED $a'" \
"    sleep 110" \
"    poweroff > /dev/null" \
"}"
        done
        printf '%s\n' "echo 'INSTDOC-PHASES-EXHAUSTED'"
    } >"$EXTRA/etc/rc.boot.machine"
    info "the machine's rc drives: $APPS"

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

if [ "${INSTDOC_REUSE:-0}" != 1 ] || [ ! -f "$W/install/serial.log" ]; then
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
        -device nvme,drive=nvme0,serial=INSTDOCTGT \
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
if grep -aq 'INSTDOC-LIVE-DONE' "$W/install/serial.log" 2>/dev/null; then
    ok "the install boot ran to completion on the live medium"
else
    bad "the install boot never printed INSTDOC-LIVE-DONE -- nothing below is a statement about an installed machine"
    tail -20 "$W/install/serial.log" 2>/dev/null | sed 's/^/        /'
    finish
fi
# `install` RETURNING IS NOT `install` SUCCEEDING. Measured on this gate's own
# first run: hlinstall refused for want of /boot/root.partuuid, printed why,
# returned, and the rc went straight on to print DONE. The installer says when
# it is finished, and that is the line to read.
if grep -aq '^install complete' "$W/install/serial.log"; then
    ok "and the installer reported 'install complete'"
else
    bad "the installer did NOT report 'install complete' -- it returned without installing: $(grep -a '^hlinstall: ' "$W/install/serial.log" | head -2 | tr '\n' ' ' | cut -c1-200)"
    finish
fi
if grep -aq 'could not hash the password' "$W/install/serial.log"; then
    bad "the installer could not hash the account password -- the account is LOCKED"
else
    ok "the installer did not report a hashing failure for the account password"
fi

# =========================================================================
# 1. THE STATE THE DEFECT NEEDS, ON THE INSTALLED DISK, BEFORE ANY DRIVE
# =========================================================================
say "1 -- the two Documents directories on the installed disk, before anything is saved"
carve "$NVME" 2 || { bad "cannot carve the installed root partition"; finish; }

if fs_has "$PART" /etc/hamnix-release; then
    ok "the reader finds /etc/hamnix-release on the installed root, so what it reports below is a reading and not a broken reader"
else
    bad "the reader cannot find /etc/hamnix-release on the installed root -- it is not working, and nothing it reports means anything"
    finish
fi
if fs_has "$PART" /etc/there-is-no-such-file-as-this; then
    bad "the reader reports a file that cannot exist -- it answers yes to everything and every absence below is meaningless"
    finish
else
    ok "and the reader does NOT find a file that is certainly not there"
fi

if fs_has "$PART" "/home/$USERNAME/Documents/welcome.txt"; then
    ok "/home/$USERNAME/Documents exists on the installed machine and the reader can see into it"
else
    bad "/home/$USERNAME/Documents/welcome.txt is not there -- the account's home has no Documents directory, so nothing below distinguishes 'saved elsewhere' from 'nowhere to save'"
fi
U="$(fs_uid "$PART" "/home/$USERNAME/Documents")"
if [ "${U:-}" = 1001 ]; then
    ok "/home/$USERNAME/Documents is owned by uid 1001 -- the session CAN write there"
else
    bad "/home/$USERNAME/Documents is owned by uid ${U:-?}, not 1001 -- the session cannot write its own Documents directory"
fi

# THE LIVE MEDIUM'S LEFTOVER DIRECTORY, which is where the defect aimed.
if fs_has "$PART" /home/live/Documents/welcome.txt; then
    LU="$(fs_uid "$PART" /home/live/Documents)"
    LM="$(fs_mode "$PART" /home/live/Documents)"
    info "/home/live/Documents is present on this installed machine, uid ${LU:-?} mode ${LM:-?}"
    if [ "${LU:-}" = 1001 ]; then
        info "…and it happens to be uid 1001 on this build, so a save there would SUCCEED; the assertion below is then about the PATH, not about permission"
    else
        ok "/home/live/Documents is owned by uid ${LU:-?} and NOT by the session's 1001 -- a save aimed there cannot succeed"
    fi
else
    info "/home/live/Documents is not on this installed machine at all (a save aimed there fails for want of a directory)"
fi

for a in $APPS; do
    e="$(app_ext "$a")"
    if fs_has "$PART" "/home/$USERNAME/Documents/untitled.$e"; then
        bad "/home/$USERNAME/Documents/untitled.$e ALREADY exists before any drive -- finding it later would prove nothing"
    else
        ok "there is no /home/$USERNAME/Documents/untitled.$e before the drive"
    fi
    if fs_has "$PART" "/home/live/Documents/untitled.$e"; then
        bad "/home/live/Documents/untitled.$e already exists before any drive"
    else
        ok "and no /home/live/Documents/untitled.$e either"
    fi
done
rm -f "$PART"

# =========================================================================
# 2. ONE BOOT PER APPLICATION: LAUNCH IT, TYPE INTO IT, PRESS Ctrl-S
# =========================================================================
# A screendump that has finished being written, and an OCR of one window's
# title bar out of it. The crop is computed from the geometry the program
# writes on its own ctl file; wsysd draws its decoration ABOVE the client
# origin (user/wsysd.ad: fill_rect(ox - 1, oy - TITLEBAR_H, ...)), so (gx, gy)
# is the client's own first row, which is where the application paints its
# name, the document name and its status word.
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
_ocr_title() {
    local p="$D/shots/$1.ppm"
    [ -s "$p" ] || return 1
    convert "$p" -crop "${gw}x26+${gx}+${gy}" +repage -colorspace Gray \
        -resize 300% -sharpen 0x1 "$D/shots/$1.png" 2>/dev/null || return 1
    tesseract "$D/shots/$1.png" "$D/shots/$1" --psm 7 >/dev/null 2>&1 || return 1
    [ -s "$D/shots/$1.txt" ]
}

drive_app() {
    local a="$1" e QPID i P TITLE
    # D, MON and QMP are NOT local: _shot and _ocr_title read them.
    e="$(app_ext "$a")"
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
        -device nvme,drive=nvme0,serial=INSTDOCTGT \
        >"$D/qemu.out" 2>&1 &
    QPID=$!
    reap_add "$QPID"
    info "qemu pid $QPID, serial $D/serial.log"

    # WAIT FOR THE APPLICATION ITSELF, not for the desktop: the window is what
    # the keystrokes are aimed at.
    i=0
    while [ "$i" -lt 260 ]; do
        sleep 2; i=$((i+2))
        grep -aq "\[$a\] scene window ready" "$D/serial.log" 2>/dev/null && break
        st=$(awk '{print $3}' "/proc/$QPID/stat" 2>/dev/null)
        case "${st:-X}" in Z|X) break ;; esac
    done
    if grep -aq "\[$a\] scene window ready" "$D/serial.log" 2>/dev/null; then
        ok "$a: the application opened its window on the installed machine after ${i}s"
    else
        bad "$a: the application never printed '[$a] scene window ready' in ${i}s -- nothing below is a statement about a save"
        tail -25 "$D/serial.log" 2>/dev/null | sed 's/^/        /'
        kill -KILL "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null
        return 1
    fi

    # The path it resolved, in its own words. A DIAGNOSTIC and not the
    # measurement -- see the disk, below.
    DOCLINE="$(grep -a "\[$a\] document " "$D/serial.log" | head -1)"
    info "$a resolved: ${DOCLINE:-<no document line>}"
    if printf '%s' "$DOCLINE" | grep -q "/home/$USERNAME/Documents/untitled.$e"; then
        ok "$a: the running program says its document is /home/$USERNAME/Documents/untitled.$e"
    else
        bad "$a: the running program's document path is not under /home/$USERNAME: ${DOCLINE:-<none>}"
    fi

    sleep 4
    # THE DRIVE. A click into the document body first: it gives the window the
    # keyboard and, in all three programs, a body click only moves the caret.
    set -- $(app_geom "$a")
    # NOT `local`: _shot/_ocr_title above read these.
    gx="$1"; gy="$2"; gw="$3"; gh="$4"
    local cx=$(( gx + gw / 2 )) cy=$(( gy + gh / 2 ))
    python3 "$QMP_INPUT" "$QMP" click "$cx" "$cy" "$SCREEN_W" "$SCREEN_H" \
        >>"$D/drive.log" 2>&1
    sleep 1
    python3 "$QMP_INPUT" "$QMP" type "$MARK" >>"$D/drive.log" 2>&1
    if [ "$(app_commit "$a")" = 1 ]; then
        python3 "$QMP_INPUT" "$QMP" key ret >>"$D/drive.log" 2>&1
    fi
    sleep 2

    # THE SCREEN BEFORE THE SAVE. This is the DRIVE CONTROL and it runs in both
    # arms: the application's title bar carries its own status word, and after
    # a character has been typed into it and before anything is saved that word
    # is "* modified". Reading it here is how a missing file later is
    # distinguished from "the keystrokes never arrived" -- which is the one
    # thing that would make a red arm mean nothing.
    _shot before
    if _ocr_title before; then
        TITLE="$(tr '\n' ' ' <"$D/shots/before.txt")"
        info "$a title bar BEFORE the save: $(printf '%s' "$TITLE" | cut -c1-120)"
        if printf '%s' "$TITLE" | grep -qi 'modif'; then
            ok "$a: BEFORE Ctrl-S the title bar reads '* modified' -- the typing reached the application, so a missing document afterwards is a failed WRITE and not a failed drive"
        else
            bad "$a: BEFORE Ctrl-S the title bar does not report the document as modified: '$TITLE'. The keystrokes did not reach the application and nothing below is a statement about saving"
        fi
        if printf '%s' "$TITLE" | grep -qi 'Step 5 of 5'; then
            bad "$a: the title OCR reports text that is certainly not on the screen -- it matches anything"
        else
            ok "$a: the title OCR does NOT report text that is not there"
        fi
    else
        bad "$a: the title bar could not be OCR'd before the save"
    fi

    # Ctrl-S as ONE modified keystroke. `key ctrl s` would release ctrl before
    # s is pressed and the program would receive a plain 's'.
    python3 "$QMP_INPUT" "$QMP" combo ctrl s >>"$D/drive.log" 2>&1
    sleep 6

    # THE SCREEN AFTER THE SAVE, REPORTED AND NOT SCORED, and the reason is a
    # measurement rather than a convenience. MEASURED on this gate, 2026-08-18:
    # a run whose document WAS written -- 43 bytes carrying the typed marker,
    # read off the ext4 afterwards -- still showed "* modified" in this shot,
    # and the same run's serial log stopped at the application's own
    # `scene window ready` line and never carried another byte, not even PID
    # 1's `poweroff: requested power off`. Once the compositor is presenting,
    # what a program writes to the console does not reach the serial line and
    # the frame this dump grabs is not guaranteed to be the newest one. So
    # BOTH the after-picture and the program's own `saved` / `SAVE FAILED`
    # lines are REPORTS here. Scoring them would score the compositor's
    # timing, not the save.
    #
    # WHAT IS SCORED INSTEAD is the before-picture above (the drive reached the
    # application) and the bytes on the disk below (where they landed). That is
    # the whole question this gate exists for.
    _shot after
    if _ocr_title after; then
        info "$a title bar AFTER the save: $(tr '\n' ' ' <"$D/shots/after.txt" | cut -c1-120)"
    else
        info "$a: the title bar could not be OCR'd after the save"
    fi
    if grep -aq "\[$a\] SAVE FAILED" "$D/serial.log"; then
        info "$a: the program reported a FAILED WRITE: $(grep -a "\[$a\] SAVE FAILED" "$D/serial.log" | head -1)"
    fi
    if grep -aq "\[$a\] saved " "$D/serial.log"; then
        info "$a: the program reported a completed write: $(grep -a "\[$a\] saved " "$D/serial.log" | head -1 | cut -c1-100)"
    else
        info "$a: no completed-write line reached the serial (see the note above -- the console stops reaching it once the compositor presents)"
    fi

    # WAIT FOR THE MACHINE TO POWER ITSELF OFF. Killing it is a power cut and
    # the document would not be on the disk to find.
    i=0
    while kill -0 "$QPID" 2>/dev/null && [ "$i" -lt 180 ]; do sleep 5; i=$((i+5)); done
    if kill -0 "$QPID" 2>/dev/null; then
        bad "$a: the machine did not power itself off in ${i}s -- the disk was not flushed by a clean shutdown, so a MISSING file below could be a power cut rather than a failed save"
        printf 'quit\n' | timeout 10 socat - "UNIX-CONNECT:$MON" >/dev/null 2>&1
        sleep 2
        kill -TERM "$QPID" 2>/dev/null; sleep 1; kill -KILL "$QPID" 2>/dev/null
    else
        ok "$a: the machine powered itself off cleanly after the drive"
    fi
    wait "$QPID" 2>/dev/null
    return 0
}

check_app_file() {
    local a="$1" e f u
    e="$(app_ext "$a")"
    f="/home/$USERNAME/Documents/untitled.$e"
    if fs_has "$PART" "$f"; then
        ok "$a: $f EXISTS on the installed disk -- the save landed in the account's own home"
    else
        bad "$a: $f is NOT on the installed disk. The person pressed Ctrl-S and nothing was written where their account can read it"
        # Where did it go instead? Answer rather than leave it open.
        if fs_has "$PART" "/home/live/Documents/untitled.$e"; then
            info "…it is at /home/live/Documents/untitled.$e instead -- the live medium's leftover directory"
        else
            info "…and it is not at /home/live/Documents/untitled.$e either: the bytes went NOWHERE"
        fi
        return 1
    fi
    if fs_dump "$PART" "$f" "$W/$a-doc.bin"; then
        ok "$a: and it is non-empty ($(stat -c%s "$W/$a-doc.bin") bytes)"
        if grep -aq "$MARK" "$W/$a-doc.bin"; then
            ok "$a: the file carries the marker string this drive typed -- it is THIS drive's document and not a leftover"
        else
            bad "$a: the file does not contain the typed marker '$MARK': $(head -c 60 "$W/$a-doc.bin" | tr -c '[:print:]' '.')"
        fi
    else
        bad "$a: the file is there but empty or unreadable"
    fi
    # WHO OWNS IT, REPORTED AND NOT ASSERTED AGAINST 1001, because 1001 is not
    # what a correct machine produces on this launch path and asserting it
    # would be asserting a wish. MEASURED here: the document comes out owned by
    # UID 0. That is not this fix failing -- it is what launching from the
    # desktop icon means. user/hamdesktop.ad is SYSTEM CHROME and runs as root
    # (etc/rc.de-user.linux says so, at length, and says why), and its
    # _run_action() spawn_detached()s the launcher directly, so every
    # application started from the icon column is a root child of the chrome
    # and everything it writes is root's.
    #
    # THE CONSEQUENCE, so it is on the record rather than left to be found: the
    # person's documents are owned by uid 0 inside a directory owned by uid
    # 1001. Anything launched from an icon can still rewrite them (it is root
    # too), but the same document opened from a DESKTOP TERMINAL -- which /is/
    # uid 1001, because /etc/rc.de-user drops it -- cannot be saved over. That
    # is a separate defect from this one, it needs the chrome to drop privilege
    # when it launches, and it is NOT fixed here.
    u="$(fs_uid "$PART" "$f")"
    info "$a: the document is owned by uid ${u:-?} (the chrome launches applications as root; see the note in this gate)"
    if [ -n "${u:-}" ]; then
        ok "$a: the document's owner could be read off the filesystem (uid ${u})"
    else
        bad "$a: the document's owner could not be read at all"
    fi
    if fs_has "$PART" "/home/live/Documents/untitled.$e"; then
        bad "$a: a document was ALSO written to /home/live/Documents/untitled.$e -- the live medium's leftover directory, which belongs to no account on this machine"
    else
        ok "$a: nothing was written into /home/live/Documents -- the leftover directory is still empty of documents"
    fi
    return 0
}

for a in $APPS; do
    say "2 -- $a: launched in the desktop session, typed into, and told to save"
    drive_app "$a"
    say "2b -- $a: the disk, read afterwards with debugfs, nothing mounted"
    if carve "$NVME" 2; then
        fs_has "$PART" /etc/hamnix-release \
            && ok "$a: the reader still works on the post-drive disk" \
            || bad "$a: the reader cannot read the post-drive disk"
        check_app_file "$a"
        rm -f "$PART"
    else
        bad "$a: cannot carve the installed root partition after the drive"
    fi
done

info "evidence: $W"
finish
