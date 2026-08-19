#!/usr/bin/env bash
#
# tests/linux/installed_launch_uid.sh — WHOSE FILE IS IT, WHEN THE DESKTOP
# STARTS THE PROGRAM THAT WROTE IT?
#
# REGISTRATION. ON-DEMAND. Not in ci_battery_manifest.txt because it builds a
# medium, installs a machine onto a blank disk and then boots that machine once
# per arm under OVMF -- four QEMU boots and a full image build, far past the
# battery's per-shard budget (12-way sharded, 50-minute cap). Same class as
# tests/linux/installed_documents.sh, whose structure and whose debugfs reader
# this borrows almost unchanged, and it is registered in
# scripts/release_gates.sh beside it.
#
# THE DEFECT
# ==========
# A person saves a document from the word processor on the desktop. It is
# written OWNED BY UID 0, into a directory that belongs to their account.
# THE SAVE SUCCEEDS -- this is the part that kept it hidden. Nothing fails,
# nothing is printed, the file is complete and in the right place. What the
# person meets later is a file that saved and cannot be written again: a
# desktop TERMINAL is uid 1001 (etc/rc.de-user drops it) and cannot save over
# a root-owned file.
#
# The cause is that the desktop chrome runs as root and launched their
# program as a child of itself.
#
# WHAT THIS GATE MEASURES THAT installed_documents.sh CANNOT
# ==========================================================
# installed_documents.sh REPRODUCES the launch from the machine's rc --
# `spawn detached ns { /bin/<app> }` -- and says so in its own header. That is
# faithful to the identity and the namespace, but it does NOT execute one line
# of user/hampanelscene.ad, user/hamappmenu.ad or user/hamdesktop.ad. So it can
# neither confirm nor refute a change to the launcher, and its 48/0 is
# unmoved by one.
#
# THIS gate drives THE REAL LAUNCH QUEUE. The machine's rc writes a payload to
# /dev/wsys/appmenu/launch -- the same file
# tests/linux/install_confirm_keys.sh starts the install wizard with -- and
# the panel's own _drain_one_launch_queue() reads it, parses it and spawns.
# The code under test is the shipped panel binary on an installed disk.
#
# THE GRAMMAR UNDER TEST
# ======================
#     <serial> user <path> [args...]   drop to the session user before exec
#     <serial> <path> [args...]        the chrome's identity -- TODAY'S MEANING
#
# The kernel prepends <serial> on read (user/linux-wsys.c, sink_is_launch_queue),
# so a writer writes only the payload.
#
# THE ARMS, AND WHY THEY ARE SHAPED LIKE THIS
# ===========================================
# Three boots on ONE installed disk, one application each, selected by marker
# files exactly as installed_documents.sh selects its phases:
#
#   1. hamwrite   queued as `user /bin/hamwrite`    -> expect the session user
#   2. hamsheet   queued as `/bin/hamsheet`  (BARE) -> expect root
#   3. hamslides  queued as `user /bin/hamslides`   -> expect the session user
#
# ARM 2 IS THE NEGATIVE CONTROL AND IT RUNS. It is not a second run of this
# file on a reverted tree: it is the SAME binary, the SAME queue, the SAME
# boot sequence and the SAME drain function, given a payload five bytes
# shorter. If it comes out owned by the session user too, then the drop is not
# caused by the verb and arms 1 and 3 prove nothing -- and this gate FAILS,
# loudly, on that.
#
# ARM 3 EXISTS TO REMOVE THE OBVIOUS CONFOUND. With only arms 1 and 2 the
# split could be hamwrite-vs-hamsheet rather than verb-vs-no-verb. Two
# different applications on the `user` side and one on the bare side means the
# outcome cannot line up with "which program" and can only line up with "which
# payload".
#
# TWO INSTRUMENTS PER ARM, AND NEITHER IS A SERIAL LINE
# ====================================================
#   (a) THE RUNNING PROCESS. The rc runs `ps` and redirects it INTO A FILE ON
#       THE EXT4, which this gate later reads with debugfs. It is deliberately
#       not read off the serial console: measured on this tree (HANDOFF, "THE
#       REAL CONSOLE WRITE HAPPENS BEFORE THE MIRROR"), once the compositor is
#       presenting, a program's console write can stop at the screen and never
#       reach the serial port -- a green or a red read off that line would be
#       reading the compositor's timing. The serial copy is still taken and is
#       REPORTED, never scored.
#   (b) THE BYTES ON THE DISK. The application's real keyboard is driven over
#       QMP (click into the body, type a marker, Ctrl-S), the machine powers
#       ITSELF off so ext4 commits, and the document's owner is read off the
#       unmounted partition with debugfs. This is the question in the defect's
#       own terms and it is the one that decides the gate.
#
# The two must AGREE within an arm. A `ps` that says hamdocusr beside a file
# owned by 0 would mean the drop happened and the write did not go where the
# process's identity says it should, and this gate scores that agreement
# rather than assuming it.
#
# INSTRUMENT CONTROLS, RUN, NOT ASSUMED
# =====================================
#   * the debugfs reader must find a file that is certainly there
#     (/etc/hamnix-release) and must NOT find one that is certainly not;
#   * /home/<user>/Documents must exist and be owned by 1001 BEFORE any arm,
#     and must hold none of the three untitled documents yet;
#   * the `ps` census must name a process this gate did not start (the panel
#     itself) -- a census that finds only what it is looking for is not a
#     census;
#   * the application's own `[<app>] scene window ready` must appear, so a
#     missing file cannot mean "the launch never happened";
#   * the title bar is OCR'd BEFORE the save and must read "* modified", so a
#     missing document afterwards is a failed WRITE and not a failed drive;
#   * and the OCR must NOT report a string that is certainly not on the screen.
#
# WHAT THIS GATE DOES **NOT** ESTABLISH
# =====================================
#   * IT DOES NOT CLICK AN ICON OR A MENU ROW. It drives the queue that a
#     click writes to. The step from `hamappmenu` painting a row to
#     `_emit_launch_path` writing `user <path>` is covered by
#     scripts/test_de_home_resolve_host.sh's static assertions and by the
#     native compile, NOT by a pointer here.
#   * It does not rebuild the medium with the change removed. Its red arm is
#     the BARE payload inside the same boot sequence, which is a control over
#     the verb and not over the whole commit.
#   * It says nothing about the desktop icon column (user/hamdesktop.ad) or
#     about hamUId, neither of which reads this queue on this kernel.
#   * It does not measure whether the session user can OPEN the saved document
#     again -- only who owns it.
#
# Usage: tests/linux/installed_launch_uid.sh
#   IUID_WORK=<dir>      work dir (default ~/.hamnix-build/instuidlaunch)
#   IUID_REUSE=1         reuse an already-built medium and installed disk
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

. tests/linux/reap.sh
reap_on_exit

W="${IUID_WORK:-$HOME/.hamnix-build/instuidlaunch}"
mkdir -p "$W"
export TMPDIR="$W/tmp"; mkdir -p "$TMPDIR"

LIVE="$W/live-usb.img"
NVME="$W/target-nvme.img"
PART="$W/part.img"
EXTRA="$W/extra"
SCREEN_W=1280
SCREEN_H=800
QMP_INPUT="$PROJ_ROOT/tests/linux/qmp_input.py"

USERNAME=hamuiduser
HOSTNAME_=hamuidbox
UPASS=hamuidpw
RPASS=hamuidadmin
# The marker typed into the document. It is not a word any of these programs
# can produce on its own, so finding it in a file on the disk is evidence that
# THIS drive wrote THAT file.
MARK=hamuidmark

# THE THREE ARMS, IN BOOT ORDER. The value beside each name is the PAYLOAD
# VERB: `user` queues "user /bin/<app>" and `bare` queues "/bin/<app>". Arm 2
# is the negative control and arm 3 removes the which-program confound; see
# the header.
APPS="hamwrite hamsheet hamslides"
app_verb()  { case "$1" in hamsheet) echo bare;; *) echo user;; esac; }
# The uid each arm must produce, given the verb it was queued with. 1001 is
# the account the install wizard creates (etc/rc.de-user.linux drops the
# session to it); 0 is the chrome's own identity, which a BARE payload keeps
# and must go on keeping.
app_want_uid() { case "$(app_verb "$1")" in user) echo 1001;; *) echo 0;; esac; }
# The payload the machine's rc writes to /dev/wsys/appmenu/launch.
app_payload() { case "$(app_verb "$1")" in
                    user) echo "user /bin/$1";;
                    *)    echo "/bin/$1";; esac; }

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
echo 'IUID-LIVE: the medium booted'
echo 'IUID-LIVE: starting the installer'
install --auto /dev/nvme0n1 --hostname $HOSTNAME_ --user $USERNAME --user-pass $UPASS --root-pass $RPASS
echo 'IUID-LIVE: the installer returned'
echo 'IUID-LIVE-DONE'
sleep 8
poweroff
RCEOF

if [ "${IUID_REUSE:-0}" = 1 ] && [ -f "$LIVE" ] && [ -s "$NVME" ]; then
    info "reusing $LIVE and $NVME (IUID_REUSE=1)"
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
    # compositor, the desktop and THE PANEL are up before anything is queued --
    # and the panel is the thing under test, so that ordering is not incidental.
    #
    # THE LAUNCH IS A WRITE TO /dev/wsys/appmenu/launch, AND THAT IS THE WHOLE
    # POINT OF THIS FILE.
    #
    # tests/linux/installed_documents.sh reproduces the launch instead --
    # `spawn detached ns { /bin/<app> }` -- and is right to, for the question it
    # asks. But it executes no line of the launcher, so it cannot see a change
    # to one. Here the rc writes a payload and then does nothing further: the
    # process that execs the application is user/hampanelscene.ad's
    # _drain_one_launch_queue(), running from the shipped panel binary on this
    # installed disk. The same file, written the same way,
    # tests/linux/install_confirm_keys.sh starts the GUI install wizard with.
    #
    # The kernel prepends the serial on READ (user/linux-wsys.c,
    # sink_is_launch_queue), so the rc writes ONLY the payload -- exactly as
    # install_confirm_keys.sh does.
    #
    # THE ps CENSUS GOES TO A FILE ON THE EXT4, NOT TO THE SERIAL LINE, and
    # that is a measured decision rather than a stylistic one. Once the
    # compositor is presenting, a program's write to /dev/console can stop at
    # the screen and never reach the serial port (HANDOFF.md, "THE REAL CONSOLE
    # WRITE HAPPENS BEFORE THE MIRROR"; the serial log of a GREEN
    # installed_documents run ends at the application's own `scene window
    # ready` and carries nothing after it). A uid read off that line could go
    # quiet for a reason that has nothing to do with uids. The file is carved
    # out with debugfs afterwards. A copy still goes to the console so the
    # serial log is readable by a human; it is REPORTED, never scored.
    #
    # THE SLEEPS. 20s lets rc.5 finish and the panel reach its poll loop before
    # anything is queued; 25s lets the launched application get far enough to
    # appear in `ps` with its final identity; the long tail is the keyboard
    # drive plus the flush, and the poweroff is from INSIDE because ext4
    # commits on a timer and killing QEMU is a power cut.
    rm -rf "$EXTRA"; mkdir -p "$EXTRA/etc"
    {
        printf '%s\n' \
"# /etc/rc.boot -- the boot script of THIS MACHINE." \
"# Staged onto the medium by tests/linux/installed_launch_uid.sh and copied" \
"# here by the installer. Owned by no package: that is the point." \
"source '/etc/rc.boot.installed'"
        for a in $APPS; do
            printf '%s\n' \
"source '/var/lib/instuid.$a'" \
"if \$status > 0 {" \
"    echo 'IUID-PHASE $a verb=$(app_verb "$a") payload=[$(app_payload "$a")]'" \
"    sleep 20" \
"    echo '$(app_payload "$a")' > /dev/wsys/appmenu/launch" \
"    echo 'IUID-PHASE-LAUNCHED $a'" \
"    sleep 25" \
"    ps > /var/lib/instuid-ps.$a" \
"    ps" \
"    echo 'IUID-PS-WRITTEN $a'" \
"    echo '# done' > /var/lib/instuid.$a" \
"    sleep 95" \
"    poweroff > /dev/null" \
"}"
        done
        printf '%s\n' "echo 'IUID-PHASES-EXHAUSTED'"
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

if [ "${IUID_REUSE:-0}" != 1 ] || [ ! -f "$W/install/serial.log" ]; then
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
        -device nvme,drive=nvme0,serial=IUIDTGT \
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
if grep -aq 'IUID-LIVE-DONE' "$W/install/serial.log" 2>/dev/null; then
    ok "the install boot ran to completion on the live medium"
else
    bad "the install boot never printed IUID-LIVE-DONE -- nothing below is a statement about an installed machine"
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
say "1 -- the account's Documents directory on the installed disk, before any arm runs"
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
# 2. ONE BOOT PER ARM: QUEUE THE PAYLOAD, TYPE INTO THE WINDOW IT PRODUCES,
#    PRESS Ctrl-S, AND THEN READ THE DISK
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
        -device nvme,drive=nvme0,serial=IUIDTGT \
        >"$D/qemu.out" 2>&1 &
    QPID=$!
    reap_add "$QPID"
    info "qemu pid $QPID, serial $D/serial.log"

    # WAIT FOR THE MACHINE'S OWN rc, NOT FOR THE APPLICATION.
    #
    # installed_documents.sh waits for `[<app>] scene window ready` on the
    # serial. IT CANNOT BE WAITED FOR HERE, and the reason is a property of the
    # launcher this gate exists to test rather than an accident: the panel
    # spawns with SPAWN_STDIO_NS (`-2, -2`), so the launched application's
    # fd 1 is routed through the panel's own /fd/1 -- and /etc/rc.d/rc.5.linux
    # starts the panel as `/bin/hampanelscene > /var/log/panel.log`. So the
    # application's startup lines land IN THAT LOG FILE, on the ext4, and never
    # on the serial line at all. They are read there, with debugfs, after the
    # machine is off; see the panel-log section below.
    #
    # What IS audible is the rc's own `echo`, which is a hamsh BUILTIN in the
    # ROOT PID-1 shell: it opened its console mirror while privileged and that
    # descriptor survives everything. IUID-PS-WRITTEN is printed after the
    # launch and after the census, so it is the moment the drive may begin.
    i=0
    while [ "$i" -lt 260 ]; do
        sleep 2; i=$((i+2))
        grep -aq "IUID-PS-WRITTEN $a" "$D/serial.log" 2>/dev/null && break
        st=$(awk '{print $3}' "/proc/$QPID/stat" 2>/dev/null)
        case "${st:-X}" in Z|X) break ;; esac
    done
    if grep -aq "IUID-PS-WRITTEN $a" "$D/serial.log" 2>/dev/null; then
        ok "$a: the machine queued the payload and took its process census after ${i}s"
    else
        bad "$a: the rc never printed IUID-PS-WRITTEN in ${i}s -- the payload was not queued and nothing below is a statement about a launch"
        tail -25 "$D/serial.log" 2>/dev/null | sed 's/^/        /'
        kill -KILL "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null
        return 1
    fi
    info "$a: the payload the rc wrote: $(grep -a "IUID-PHASE $a " "$D/serial.log" | head -1)"

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

    # THE SCREEN BEFORE THE SAVE. This is the DRIVE CONTROL and it runs in
    # every arm: the application's title bar carries its own status word, and
    # after a character has been typed into it and before anything is saved
    # that word is "* modified". Reading it here is how a missing file later is
    # distinguished from "the keystrokes never arrived" -- which is the one
    # thing that would make any arm below mean nothing. IT IS ALSO THE ONLY
    # PROOF, AT THIS POINT IN THE RUN, THAT THE WINDOW IS ON THE SCREEN AT ALL:
    # a title bar cannot be OCR'd out of a screendump of a bare desktop.
    _shot before
    if _ocr_title before; then
        TITLE="$(tr '\n' ' ' <"$D/shots/before.txt")"
        info "$a title bar BEFORE the save: $(printf '%s' "$TITLE" | cut -c1-120)"
        if printf '%s' "$TITLE" | grep -qi 'modif'; then
            ok "$a: BEFORE Ctrl-S the title bar reads '* modified' -- the queued launch produced a REAL WINDOW with the keyboard focus, so a missing document afterwards is a failed WRITE and not a failed launch"
        else
            bad "$a: BEFORE Ctrl-S the title bar does not report the document as modified: '$TITLE'. Either the launch queue never produced a window or the keystrokes did not reach it, and nothing below is a statement about saving"
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

    # The after-picture is a REPORT. Measured on installed_documents.sh
    # (2026-08-18): a run whose document WAS written still showed "* modified"
    # in this shot, because once the compositor is presenting the frame this
    # dump grabs is not guaranteed to be the newest one. Scoring it would score
    # the compositor's timing. What is scored is the before-picture above and
    # the bytes on the disk below.
    _shot after
    if _ocr_title after; then
        info "$a title bar AFTER the save: $(tr '\n' ' ' <"$D/shots/after.txt" | cut -c1-120)"
    else
        info "$a: the title bar could not be OCR'd after the save"
    fi

    # WAIT FOR THE MACHINE TO POWER ITSELF OFF. Killing it is a power cut and
    # the document would not be on the disk to find.
    i=0
    while kill -0 "$QPID" 2>/dev/null && [ "$i" -lt 240 ]; do sleep 5; i=$((i+5)); done
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


# ==========================================================================
# THE PROCESS CENSUS, READ OFF THE EXT4 -- INSTRUMENT (a)
# ==========================================================================
# The rc ran `ps > /var/lib/instuid-ps.<app>` while the application was up.
# `ps` prints one row per process with the OWNER'S NAME, so this answers "what
# identity did the launch queue give it?" directly, on the running machine,
# without asking anything to print to a console that may already be mute.
check_ps_census() {
    local a="$1" want f owner
    want="$(app_want_uid "$a")"
    f="$W/$a-ps.txt"
    if ! fs_dump "$PART" "/var/lib/instuid-ps.$a" "$f"; then
        bad "$a: /var/lib/instuid-ps.$a is not on the disk or is empty -- the census never ran, so there is no reading of the launched process's identity"
        return 1
    fi
    ok "$a: the process census was written to the ext4 and read back ($(wc -l <"$f") rows)"

    # THE CENSUS CONTROL. A census that only ever finds the thing being looked
    # for is not a census. hampanelscene is the process that DID the launching;
    # it is certainly running, this gate did not start it, and it must appear.
    if grep -q 'hampanelscene' "$f"; then
        ok "$a: the census names hampanelscene -- a process this gate did not start, so it is a census and not an echo of the query"
    else
        bad "$a: the census does not name hampanelscene, which is certainly running -- it is not reading the process table and its answer about $a means nothing"
        sed 's/^/        /' "$f" | head -20
        return 1
    fi

    if ! grep -q "$a" "$f"; then
        bad "$a: the census contains no $a row at all -- the queue payload did not produce a process"
        sed 's/^/        /' "$f" | head -30
        return 1
    fi
    ok "$a: the census contains an $a row -- the launch queue produced a process"

    # The owner column, as the machine itself names it.
    owner="$(grep "$a" "$f" | head -1 | awk '{print $2}')"
    info "$a: the census row: $(grep "$a" "$f" | head -1 | cut -c1-100)"
    if [ "$want" = 0 ]; then
        if [ "${owner:-}" = root ] || [ "${owner:-}" = 0 ]; then
            ok "$a: queued as a BARE path, the process is owned by ROOT ('${owner}') -- a bare payload still means what it has always meant, which is what keeps the install wizard working"
        else
            bad "$a: queued as a BARE path, the process is owned by '${owner:-?}' and not root. A bare payload has changed identity, which is exactly the demotion that reverted this fix once (install_confirm_keys 33/1)"
        fi
    else
        if [ "${owner:-}" = "$USERNAME" ] || [ "${owner:-}" = 1001 ]; then
            ok "$a: queued as 'user /bin/$a', the process is owned by the SESSION USER ('${owner}') -- the verb dropped privilege"
        else
            bad "$a: queued as 'user /bin/$a', the process is owned by '${owner:-?}' and not $USERNAME. The verb did not drop privilege"
        fi
    fi
    return 0
}


# ==========================================================================
# THE PANEL'S OWN LOG, READ OFF THE EXT4
# ==========================================================================
# /etc/rc.d/rc.5.linux starts the panel as `/bin/hampanelscene >
# /var/log/panel.log`, and the panel spawns with SPAWN_STDIO_NS, so BOTH the
# panel's own `[panel] launched <path>` line and the launched application's
# `[<app>] scene window ready` land in that one file. It is the only place on
# this machine where the launcher and the launched both speak.
check_panel_log() {
    local a="$1" f
    f="$W/$a-panel.log"
    if ! fs_dump "$PART" /var/log/panel.log "$f"; then
        info "$a: /var/log/panel.log is not on the disk or is empty -- the panel's own account of the launch is unavailable (this is a REPORT; the census and the disk decide the arm)"
        return 0
    fi
    if grep -aq "\[panel\] launched /bin/$a" "$f"; then
        ok "$a: the PANEL's own log says '[panel] launched /bin/$a' -- the drain parsed the payload and spawned, in the launcher's own words"
    else
        bad "$a: the panel's log has no '[panel] launched /bin/$a' line. $(grep -a '\[panel\]' "$f" | tail -3 | tr '\n' ' ' | cut -c1-200)"
    fi
    if grep -aq "\[$a\] scene window ready" "$f"; then
        ok "$a: and the application printed '[$a] scene window ready' into that same log -- it opened a window"
    else
        info "$a: no '[$a] scene window ready' in the panel log (REPORT -- the title-bar OCR above is what scores the window)"
    fi
    if grep -aq "\[$a\] document " "$f"; then
        info "$a: the application resolved: $(grep -a "\[$a\] document " "$f" | head -1 | cut -c1-120)"
    fi
    if grep -aq 'REFUSING TO LAUNCH' "$f"; then
        info "$a: the launcher REFUSED a launch rather than running it as root: $(grep -a 'REFUSING TO LAUNCH' "$f" | head -1 | cut -c1-160)"
    fi
    if grep -aq ": not installed" "$f"; then
        info "$a: the panel refused a path by name: $(grep -a ': not installed' "$f" | tail -1 | cut -c1-120)"
    fi
    return 0
}


# ==========================================================================
# THE BYTES ON THE DISK -- INSTRUMENT (b), AND THE ONE THAT DECIDES THE GATE
# ==========================================================================
check_app_file() {
    local a="$1" e f u want
    e="$(app_ext "$a")"
    want="$(app_want_uid "$a")"
    f="/home/$USERNAME/Documents/untitled.$e"
    if fs_has "$PART" "$f"; then
        ok "$a: $f EXISTS on the installed disk -- the save landed in the account's own home"
    else
        bad "$a: $f is NOT on the installed disk. The person pressed Ctrl-S and nothing was written where their account can read it"
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

    # WHO OWNS IT. THIS IS THE DEFECT, IN THE ONE FORM THAT MATTERS TO THE
    # PERSON WHO SAVED IT.
    #
    # installed_documents.sh REPORTS this number and does not assert it against
    # 1001, and its note says why: on the launch path THAT gate reproduces --
    # the machine's rc spawning /bin/<app> as root -- uid 1001 is not what a
    # correct machine produces, so asserting it would be asserting a wish. That
    # note is still correct about that gate.
    #
    # HERE IT IS ASSERTED, because here the launch went through the queue and
    # the queue was told whose program it is. In the `user` arms the only
    # correct answer is the session user: a document the person cannot save
    # over is the whole defect, and ownership is what decides that.
    #
    # AND IN THE BARE ARM THE ONLY CORRECT ANSWER IS 0. That is not a
    # concession -- it is the control. A bare payload keeps the chrome's
    # identity, which is what lets the install wizard go on being started by
    # `echo '/bin/haminstallui' > '/dev/wsys/appmenu/launch'`. If this arm came
    # out 1001 the verb would not be what caused the drop and the `user` arms
    # would be measuring something else.
    u="$(fs_uid "$PART" "$f")"
    if [ -z "${u:-}" ]; then
        bad "$a: the document's owner could not be read off the filesystem at all"
        return 1
    fi
    info "$a: the document is owned by uid ${u} (this arm was queued as '$(app_payload "$a")')"
    if [ "$want" = 0 ]; then
        if [ "$u" = 0 ]; then
            ok "$a: NEGATIVE CONTROL HOLDS -- queued as a BARE path, the saved document is owned by uid 0. The bare form still means what it always meant, so the drop in the other arms is caused by the verb and not by the boot"
        else
            bad "$a: NEGATIVE CONTROL FAILED -- queued as a BARE path, the saved document is owned by uid ${u}, not 0. Identity changed WITHOUT the verb, so the other arms prove nothing about the verb -- and a bare payload silently changing identity is the demotion that reverted this fix once"
        fi
    else
        if [ "$u" = 1001 ]; then
            ok "$a: THE DOCUMENT IS OWNED BY UID 1001 -- the session user's own account, in the session user's own home. The person can save over their own file"
        else
            bad "$a: the document is owned by uid ${u}, not 1001. It was saved from a program the desktop launch queue started with the 'user' verb, and it still is not the person's file"
        fi
    fi

    # AND THE OWNER MUST AGREE WITH THE DIRECTORY. A file owned by 1001 in a
    # directory owned by 0 would be as unusable as the defect itself.
    local du
    du="$(fs_uid "$PART" "/home/$USERNAME/Documents")"
    if [ "${du:-}" = 1001 ]; then
        ok "$a: and the directory it sits in is still owned by uid 1001 -- file and directory agree"
    else
        bad "$a: the directory /home/$USERNAME/Documents is owned by uid ${du:-?}, not 1001"
    fi

    if fs_has "$PART" "/home/live/Documents/untitled.$e"; then
        bad "$a: a document was ALSO written to /home/live/Documents/untitled.$e -- the live medium's leftover directory, which belongs to no account on this machine"
    else
        ok "$a: nothing was written into /home/live/Documents -- the leftover directory is still empty of documents"
    fi
    return 0
}


for a in $APPS; do
    say "2 -- $a: queued on /dev/wsys/appmenu/launch as '$(app_payload "$a")', typed into, and told to save"
    drive_app "$a"
    say "2b -- $a: the disk, read afterwards with debugfs, nothing mounted"
    if carve "$NVME" 2; then
        fs_has "$PART" /etc/hamnix-release \
            && ok "$a: the reader still works on the post-drive disk" \
            || bad "$a: the reader cannot read the post-drive disk"
        check_ps_census "$a"
        check_panel_log "$a"
        check_app_file "$a"
        rm -f "$PART"
    else
        bad "$a: cannot carve the installed root partition after the drive"
    fi
done

# =========================================================================
# 3. THE ARMS, SIDE BY SIDE
# =========================================================================
# Stated once, at the end, because the claim this gate makes is not about any
# single arm: it is that the OUTCOME LINES UP WITH THE PAYLOAD AND NOT WITH
# THE PROGRAM. Two different applications were queued with the verb and one
# without; if the split followed the program instead, hamwrite and hamslides
# would not agree with each other while disagreeing with hamsheet.
say "3 -- did the outcome follow the payload, or the program?"
for a in $APPS; do
    info "$(printf '%-10s verb=%-5s want-uid=%-5s' "$a" "$(app_verb "$a")" "$(app_want_uid "$a")")"
done
info "the arms above are scored individually; this table is a reading aid, not an assertion"

info "evidence: $W"
finish
