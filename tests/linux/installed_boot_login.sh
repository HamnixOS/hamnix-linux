#!/usr/bin/env bash
#
# tests/linux/installed_boot_login.sh — THE MACHINE ASKS WHO YOU ARE BEFORE IT
# GIVES YOU A SHELL, AND THERE IS NO LONGER A WAY PAST IT.
#
# REGISTRATION. Not in ci_battery_manifest.txt because it needs an INSTALLED
# DISK, which no CI runner has and which costs a medium build plus an install
# boot to make (tests/linux/installed_accounts.sh makes one), and then boots it
# twice under OVMF. It IS registered in scripts/release_gates.sh
# (installed_boot_login|yes|0|27). Same class as installed_login.sh, whose disk
# and idioms it borrows.
#
# WHY THIS FILE EXISTS
# ====================
# tests/linux/installed_login.sh drives `su` on a running machine and proves
# the wizard's password authenticates and a wrong one is refused. Its own last
# line says what it did not do:
#
#     "This gate drove `su`. It did NOT drive a boot-time login."
#
# That mattered, because the machine never asked. hamsh IS PID 1; /etc/rc.boot
# is the script it runs, and when that script ENDED, PID 1 fell through into
# its own interactive prompt — an unauthenticated uid 0 shell on the console
# of a freshly booted machine. Every credential in installed_login.sh was real
# and nothing ever demanded one. The fix (etc/rc.boot.machine, etc/rc.login,
# and hamsh's new `supervise` builtin) is what this gate measures.
#
# THE TWO ARMS, AND THEY ARE ARMS OF ONE RUN
# ==========================================
# Both arms boot the SAME installed disk, with the SAME /bin/hamsh and the
# SAME /bin/getty written onto it by this gate. THE ONLY DIFFERENCE IN THE
# WHOLE RUN IS TWO LINES OF /etc/rc.boot:
#
#   guarded     /bin/getty /dev/ttyS0 &
#   autologin   /bin/getty /dev/ttyS0 -a hostowner &
#
# THAT IS THE WHOLE DIFFERENCE: two words, `-a hostowner`. Everything else --
# the disk, /bin/hamsh, /bin/getty, /etc/rc.login, `supervise`, the driver,
# the patterns, the port -- is identical.
#
#   guarded    -> the console must present `login: `, must refuse a wrong
#                 password, must admit the right one, and must NEVER answer a
#                 command with a root identity before it does.
#   autologin  -> user/login.ad's `-f` path deliberately does NOT setuid: it
#                 keeps the identity getty inherited, which is PID 1's, which
#                 is root. So this arm MUST reach a root shell with no
#                 password. THIS ARM IS THE NEGATIVE CONTROL AND IT IS THE
#                 POINT OF THE FILE. It is not a straw man either: `-a` is the
#                 shape this tree SHIPS on the live medium today
#                 (etc/rc.boot.full: `getty 2 -a live`).
#
# WHY THE NEGATIVE CONTROL IS NOT OPTIONAL HERE. The central claim of the
# guarded arm is an ASSERTION OF ABSENCE — "no root shell is reachable without
# authenticating". An absence assertion that cannot fail is worthless: a
# driver typing into a dead socket, a machine that never booted, a regex with
# a typo, and a genuinely fixed machine ALL produce "no root shell seen". So
# the instrument is shown to be able to SEE a root shell, on this disk, over
# this serial socket, with this driver and this pattern, in the same run,
# seconds apart — and only then is its silence in the other arm evidence.
#
# HOW THE ABSENCE IS PROBED, twice, by two independent instruments:
#
#   (1) ON THE WIRE. The gate types `id` at the console and reads the answer.
#       A root shell answers with uid=0. A `login: ` prompt takes `id` as a
#       USERNAME, asks for a password, and refuses. So a root identity in an
#       arm's serial log IS a root shell answering, and the autologin arm
#       proves it is reachable.
#
#       THE PATTERN IS `uid=0([^0-9]|$)`, NOT `uid=0(`, and the difference
#       would have cost a run. user/id.ad prints `uid=<n>(<name>)` only when
#       it can resolve the number in /etc/passwd and bare `uid=<n>` when it
#       cannot -- and THIS DISK HAS NO uid 0 ENTRY (its administrative account
#       is `hostowner` at uid 1). A real root shell here answers `uid=0 gid=0`
#       with no parentheses, so the first version of this detector would have
#       reported "no root shell" in the very arm built to contain one.
#
#   (2) ON THE DISK. The gate types a command that WRITES A FILE
#       (/var/log/bootlogin-pwned.txt). A root shell creates it; a login
#       prompt eats the text as a credential and creates nothing. The file is
#       read back afterwards with debugfs off the unmounted ext4. This one
#       survives the compositor, needs no serial output from the program, and
#       is the check that would still work if every console mirror on the
#       machine were mute — which is the failure mode this project has been
#       burned by three times.
#
#   (3) IN THE ORDERING. A `hamsh$ ` prompt on the port is NOT by itself a
#       defect — the authenticated session's own shell prints one. What must
#       never happen is a shell prompt BEFORE the login prompt, and that is
#       what is asserted, by line number, rather than the presence of a
#       string that a correct run also produces.
#
# A NOTE ON AN ARM THAT WAS TRIED AND REPLACED, because the result is worth
# keeping: the first version of this gate used the LITERAL old rc as its
# control (source /etc/rc.boot.installed and stop, letting PID 1 fall through).
# PID 1 does fall through — that run's serial log carries `[hamsh:stage-07]
# loop-enter` and a `hamsh$ ` prompt with no login prompt anywhere — but the
# prompt COULD NOT BE DRIVEN over this socket: the typed lines were echoed and
# never executed, so it answered neither probe and the control scored 0/2 on a
# machine that genuinely had a root shell. PID 1's own fd 0/1/2 are
# /dev/console, which follows the LAST `console=` on the shipped command line
# and is therefore tty0, THE SCREEN — while its line-editor echo still reaches
# the serial line through the Adder runtime's console mirror. An arm that
# cannot be driven cannot prove an instrument works.
#
# WHY THE SERIAL PORT IS A SOCKET AND NOT A FILE. A login prompt's entire
# behaviour is a reply to something typed, and `-serial file:` is write-only.
# The port is `-serial unix:<sock>,server,nowait` and tests/linux/serial_drive.py
# is the other end. That program DOES NOT SCORE ANYTHING — it types, and it
# writes every byte received into the log this gate then reads. An EXPECT
# pattern of its own that is wrong cannot make this gate pass.
#
# WHAT THIS GATE DOES NOT ESTABLISH
# =================================
#   * The VIRTUAL TERMINALS. /etc/rc.login also starts getty on /dev/tty2 and
#     /dev/tty3. That they are STARTED is asserted (the rc says so on the
#     console); that a person can log in on one is NOT — once wsysd presents
#     it owns the framebuffer and nothing on this machine can read tty2 back.
#   * THE GRAPHICAL SESSION. rc.5 still starts the desktop without asking. The
#     hole this gate closes is the CONSOLE root shell. A desktop session that
#     starts unauthenticated is a separate hole and this gate is silent on it.
#   * A CONSTRUCTED ROOT. The authenticated session gets the machine's real
#     root, so `cd /` still shows the machine. The seam is documented in
#     etc/rc.login.linux and nothing here measures it.
#   * SSH, hamlock, or any credential surface other than the boot console.
#
# Usage: tests/linux/installed_boot_login.sh
#   BLOGIN_SRC_NVME=<img>  installed disk to copy (default:
#                          ~/.hamnix-build/instacct/target-nvme.img)
#   BLOGIN_WORK=<dir>      work dir (default ~/.hamnix-build/instbootlogin)
#   BLOGIN_USER / BLOGIN_UPASS
#                          credentials that disk was installed with
#                          (defaults match installed_accounts.sh)
#   BLOGIN_ARMS=<list>     arms to run (default "guarded autologin")
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

. tests/linux/reap.sh
reap_on_exit

SRC="${BLOGIN_SRC_NVME:-$HOME/.hamnix-build/instacct/target-nvme.img}"
W="${BLOGIN_WORK:-$HOME/.hamnix-build/instbootlogin}"
USERNAME="${BLOGIN_USER:-hamacctusr}"
UPASS="${BLOGIN_UPASS:-hamacctpw}"
ARMS="${BLOGIN_ARMS:-guarded autologin}"
WRONGPASS='definitely-not-the-password'

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
for t in /sbin/debugfs /sbin/sfdisk; do
    [ -x "$t" ] || { echo "INCONCLUSIVE: need $t"; exit 2; }
done
[ -f /usr/share/OVMF/OVMF_CODE_4M.fd ] || { echo "INCONCLUSIVE: need OVMF"; exit 2; }
[ -s "$SRC" ] || { echo "INCONCLUSIVE: no installed disk at $SRC -- run tests/linux/installed_accounts.sh first"; exit 2; }

mkdir -p "$W"
export TMPDIR="$W/tmp"; mkdir -p "$TMPDIR"

# THE ROOT-IDENTITY DETECTOR, defined ONCE so the arm that proves it fires
# and the arm whose result depends on it NOT firing cannot drift apart.
#
# NOT `uid=0(`. THAT WAS THE FIRST VERSION AND IT WOULD HAVE FAILED THE
# CONTROL ON A CORRECT MACHINE. user/id.ad prints `uid=<n>(<name>)` only when
# it can resolve the number in /etc/passwd, and `uid=<n>` bare when it cannot
# -- and THIS DISK HAS NO uid 0 ENTRY AT ALL (its only administrative account
# is `hostowner`, at uid 1). So a real root shell here answers `uid=0 gid=0`,
# with no parentheses, and a detector requiring `(` would have reported "no
# root shell" in the very arm built to contain one.
#
# The trailing guard is what stops `uid=0` matching `uid=1001`: the number
# must be followed by something that is not a digit, or end the line.
has_root_identity()   { grep -aqE 'uid=0([^0-9]|$)' "$1"; }
root_identity_lines() { grep -aE  'uid=0([^0-9]|$)' "$1"; }
# The same shape for the account this gate logs in as. `uid=1001` must not be
# matched by a pattern looking for `uid=1`, and `uid=1` must not be matched by
# one looking for `uid=1001`, so both ends are guarded.
has_uid()   { grep -aqE "uid=$2([^0-9]|\$)" "$1"; }
uid_lines() { grep -aE  "uid=$2([^0-9]|\$)" "$1"; }

part_geom() {
    /sbin/sfdisk -J "$1" 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)["partitiontable"]
ss=d.get("sectorsize",512)
p=d["partitions"][int(sys.argv[1])-1]
print(p["start"]*ss, p["size"]*ss)' "$2"
}

# =========================================================================
say "0 -- the programs under test, built for THIS lane"
# hamsh carries the new `supervise` builtin and getty carries the device-path
# mode; neither is on the source disk, which predates both. They are built
# here and written onto every arm's copy, so the binaries are a CONSTANT of
# the run and the rc is the only variable.
BIN="$W/bin"; mkdir -p "$BIN"
for prog in hamsh getty; do
    if scripts/hamlinux_build.sh "user/$prog.ad" "$BIN/$prog.elf" >"$W/build-$prog.log" 2>&1; then
        ok "built /bin/$prog for this lane ($(stat -c %s "$BIN/$prog.elf") bytes)"
    else
        bad "could not build user/$prog.ad -- see $W/build-$prog.log"
        tail -20 "$W/build-$prog.log" | sed 's/^/        /'
        finish
    fi
done

# The `supervise` builtin must actually BE in the binary this gate is about to
# install, and the rc must actually name it. Both are checked from the SOURCE
# side here so a green run cannot be a run of the old shell under a new name.
if grep -q 'cstr_eq(cmd, "supervise")' user/hamsh.ad; then
    ok "user/hamsh.ad dispatches a 'supervise' builtin"
else
    bad "user/hamsh.ad has no 'supervise' builtin -- this gate is measuring the wrong tree"
    finish
fi

# =========================================================================
say "1 -- the installed disk, and the account this gate will log in as"
info "source disk: $SRC"
info "  $(stat -c '%s bytes, mtime %y' "$SRC")"

G="$(part_geom "$SRC" 2)"; [ -n "$G" ] || { bad "cannot read the partition table"; finish; }
OFF="${G% *}"; SZ="${G#* }"
info "root partition at offset $OFF, $SZ bytes"
[ $((OFF % 1048576)) = 0 ] || { bad "the root partition does not start on a MiB boundary ($OFF) -- this gate's dd would misplace it"; finish; }

# Read the account table ONCE, off the pristine source, to learn the uid this
# gate should expect. Asserting `uid=1001` from a constant would be asserting
# this gate's memory of another gate's default; the disk is the authority.
PROBEPART="$W/probe-part.img"
rm -f "$PROBEPART"
dd if="$SRC" of="$PROBEPART" bs=1M skip=$((OFF / 1048576)) \
   count=$(( (SZ + 1048575) / 1048576 )) status=none \
   || { bad "cannot carve the root partition"; finish; }

rm -f "$W/passwd"
/sbin/debugfs -R "dump /etc/passwd $W/passwd" "$PROBEPART" >/dev/null 2>&1
if [ -s "$W/passwd" ]; then
    ok "the ext4 reader read /etc/passwd off the disk ($(wc -c <"$W/passwd") bytes)"
else
    bad "the ext4 reader could not read /etc/passwd -- the instrument is not working and nothing below would mean anything"
    finish
fi
# THE OTHER HALF OF THE READER CONTROL: it must also NOT find what is not
# there, or every absence this gate reports off the disk is meaningless.
if /sbin/debugfs -R "stat /etc/there-is-no-such-file-as-this" "$PROBEPART" 2>/dev/null | grep -q '^Inode:'; then
    bad "the ext4 reader reports a file that cannot exist -- every absence below would be meaningless"
    finish
else
    ok "and it does NOT find a file that is certainly not there"
fi

EXPECT_UID="$(awk -F: -v u="$USERNAME" '$1==u{print $3}' "$W/passwd")"
if [ -n "$EXPECT_UID" ]; then
    ok "the machine's /etc/passwd carries '$USERNAME' at uid $EXPECT_UID"
    info "  $(awk -F: -v u="$USERNAME" '$1==u{print}' "$W/passwd")"
else
    bad "the machine's /etc/passwd has no '$USERNAME' -- this is not the disk this gate is for"
    finish
fi
USERHOME="$(awk -F: -v u="$USERNAME" '$1==u{print $6}' "$W/passwd")"
[ -n "$USERHOME" ] || USERHOME="/home/$USERNAME"
info "  home directory, read from that same /etc/passwd: $USERHOME"
if [ "$EXPECT_UID" = "0" ]; then
    bad "'$USERNAME' is uid 0 on this disk -- this gate's whole discriminator is 'uid=0 means a root shell', and it would be blind"
    finish
fi

# The auto-poweroff script. EVERY arm gets it, and it is what makes an arm's
# evidence reach the ext4: a machine killed by the host is a power cut and the
# filesystem will not have committed. It is INDEPENDENT of anything this gate
# types, so an arm whose console never answers still powers down and still
# yields its disk-side evidence.
cat >"$W/rc.autopoweroff" <<'APEOF'
# Started as a background child of PID 1 by every arm of
# tests/linux/installed_boot_login.sh. Its only job is to end the boot on a
# timer, whatever the console does.
sleep 300
echo 'BOOTLOGIN-POWEROFF-NOW'
init 0
sleep 25
poweroff
APEOF

# ---- the two rcs. THE ONLY DIFFERENCE BETWEEN THE ARMS. -------------------
# guarded: the shape etc/rc.boot.machine now ships.
cat >"$W/rc.boot.guarded" <<RCEOF
# /etc/rc.boot -- rewritten by tests/linux/installed_boot_login.sh, arm
# 'guarded'. This is the shape etc/rc.boot.machine ships: the login rc, then
# supervise, which never returns.
source '/etc/rc.boot.installed'
/bin/hamsh /etc/rc.autopoweroff &
source '/etc/rc.login'
echo 'BOOTLOGIN-READY-guarded'
supervise
RCEOF
# autologin: THE NEGATIVE CONTROL, and it differs from 'guarded' BY ONE FLAG.
#
# `getty /dev/ttyS0 -a hostowner` is AUTOLOGIN: getty execs `login -f
# hostowner`, and user/login.ad's -f path deliberately does NOT call setuid --
# it keeps the identity getty inherited, which is PID 1's, which is root. So
# this arm puts a ROOT SHELL ON THE SAME PORT, through the SAME getty, read by
# the SAME driver with the SAME patterns, and the only difference in the whole
# run is the two words `-a hostowner`.
#
# That is what makes the guarded arm's silence mean something. It is also not
# a straw man: `-a` autologin is the shape this tree SHIPS TODAY on the live
# medium (etc/rc.boot.full: `getty 2 -a live`, `getty 3 -a live`, `getty 4 -a
# live`), so this arm is a real configuration of a real program.
#
# WHY NOT THE LITERAL OLD rc (source rc.boot.installed and stop, letting PID 1
# fall through)? IT WAS TRIED FIRST AND IT IS RECORDED HERE BECAUSE THE RESULT
# IS WORTH KNOWING. PID 1 does fall through -- its serial log carries
# `[hamsh:stage-07] loop-enter` and a `hamsh$ ` prompt, with no login prompt
# anywhere -- but that prompt could not be DRIVEN over this socket: the typed
# lines were echoed and never executed, neither answering `id` nor creating a
# file. PID 1's own fd 0/1/2 are /dev/console, which follows the LAST
# `console=` on the shipped command line and is therefore tty0, THE SCREEN --
# not this port -- while its line-editor echo still reaches the serial through
# the Adder runtime's console mirror. An arm that cannot be driven cannot
# prove an instrument works, so the control is the one below, which opens the
# port explicitly.
cat >"$W/rc.boot.autologin" <<RCEOF
# /etc/rc.boot -- rewritten by tests/linux/installed_boot_login.sh, arm
# 'autologin'. Identical to the 'guarded' arm except that the console getty is
# given '-a hostowner', which skips the password entirely.
source '/etc/rc.boot.installed'
/bin/hamsh /etc/rc.autopoweroff &
/bin/getty /dev/ttyS0 -a hostowner &
echo 'BOOTLOGIN-READY-autologin'
supervise
RCEOF

# ---- the drive scripts ----------------------------------------------------
# guarded: probe for a root shell FIRST (before any credential is offered),
# then do a real login wrong-then-right.
cat >"$W/drive.guarded" <<DEOF
EXPECT 300 BOOTLOGIN-READY-guarded
SLEEP 8
# THE PROMPT ITSELF. If the console is a login prompt this is here; if it is a
# root shell it is not.
EXPECT 60 \r?\nlogin: 
# --- absence probe (1): ask the console who it is. A root shell says uid=0.
SEND id
SLEEP 3
# --- absence probe (2): ask it to write a file. A root shell creates it.
SEND echo pwned > /var/log/bootlogin-pwned.txt
SLEEP 4
# Those two lines were eaten as a username and a password, so this must refuse.
EXPECT 45 Login incorrect
# --- a WRONG password for a REAL account.
SEND $USERNAME
SLEEP 2
SEND $WRONGPASS
SLEEP 4
EXPECT 45 Login incorrect
# --- the RIGHT password.
SEND $USERNAME
SLEEP 2
SEND $UPASS
SLEEP 10
# In a session now. Say who, on the wire and on the disk.
SEND id
SLEEP 4
SEND id > \$HOME/bootlogin-id.txt
SLEEP 4
DONE 10
DEOF
# autologin: the same two probes, and nothing else. It must answer both.
cat >"$W/drive.autologin" <<DEOF
EXPECT 300 BOOTLOGIN-READY-autologin
SLEEP 10
SEND id
SLEEP 5
SEND echo pwned > /var/log/bootlogin-pwned.txt
SLEEP 5
DONE 10
DEOF

# =========================================================================
# One boot per arm, all in this one invocation.
run_arm() {
    local a="$1"
    say "arm '$a' -- boot, drive, power off"
    local D="$W/boot-$a"; rm -rf "$D"; mkdir -p "$D"
    local NVME="$D/nvme.img" PART="$D/part.img"

    cp --reflink=auto "$SRC" "$NVME" || { bad "[$a] cannot copy the installed disk"; return; }
    dd if="$NVME" of="$PART" bs=1M skip=$((OFF / 1048576)) \
       count=$(( (SZ + 1048575) / 1048576 )) status=none \
       || { bad "[$a] cannot carve the root partition"; return; }

    # e2fsck BEFORE and AFTER the debugfs writes. Not hygiene: on a freshly
    # copied image with a dirty journal the first debugfs write of a large
    # file silently does nothing, and debugfs's allocation leaves bg 0's
    # block bitmap checksum wrong, which the kernel finds at ext4lazyinit --
    # the filesystem goes to error state and EVERY WRITE ON THE MACHINE FAILS
    # SILENTLY, which would make this gate's disk-side evidence a lie.
    /sbin/e2fsck -fy "$PART" >"$D/fsck1.log" 2>&1

    cat >"$D/dbg.cmds" <<DBEOF
cd /etc
rm rc.boot
write $W/rc.boot.$a rc.boot
write $W/rc.autopoweroff rc.autopoweroff
rm rc.login
write $PROJ_ROOT/etc/rc.login.linux rc.login
cd /bin
rm hamsh
write $BIN/hamsh.elf hamsh
sif hamsh mode 0100755
write $BIN/getty.elf getty
sif getty mode 0100755
quit
DBEOF
    /sbin/debugfs -w -f "$D/dbg.cmds" "$PART" >"$D/debugfs.log" 2>&1
    /sbin/e2fsck -fy "$PART" >"$D/fsck2.log" 2>&1

    # READ BACK EVERY FILE THIS GATE WROTE and compare byte for byte. A gate
    # whose subject never landed on the disk would otherwise measure the old
    # machine and call it a result.
    local staged_ok=1
    rm -f "$D/rb.rc" "$D/rb.hamsh" "$D/rb.getty" "$D/rb.rclogin"
    /sbin/debugfs -R "dump /etc/rc.boot $D/rb.rc" "$PART" >/dev/null 2>&1
    /sbin/debugfs -R "dump /etc/rc.login $D/rb.rclogin" "$PART" >/dev/null 2>&1
    /sbin/debugfs -R "dump /bin/hamsh $D/rb.hamsh" "$PART" >/dev/null 2>&1
    /sbin/debugfs -R "dump /bin/getty $D/rb.getty" "$PART" >/dev/null 2>&1
    cmp -s "$W/rc.boot.$a" "$D/rb.rc"            || staged_ok=0
    cmp -s "$PROJ_ROOT/etc/rc.login.linux" "$D/rb.rclogin" || staged_ok=0
    cmp -s "$BIN/hamsh.elf" "$D/rb.hamsh"        || staged_ok=0
    cmp -s "$BIN/getty.elf" "$D/rb.getty"        || staged_ok=0
    if [ "$staged_ok" = 1 ]; then
        ok "[$a] rc.boot, rc.login, /bin/hamsh and /bin/getty are on the filesystem, byte-identical when read back"
    else
        bad "[$a] the staged files did not land byte-identical -- see $D/debugfs.log"
        return
    fi

    # The pwned file must NOT be there before the machine boots, or its
    # presence afterwards would say nothing.
    if /sbin/debugfs -R "stat /var/log/bootlogin-pwned.txt" "$PART" 2>/dev/null | grep -q '^Inode:'; then
        bad "[$a] /var/log/bootlogin-pwned.txt already exists before the boot -- the disk-side probe is void"
        return
    else
        ok "[$a] /var/log/bootlogin-pwned.txt does not exist before the boot"
    fi

    dd if="$PART" of="$NVME" bs=1M seek=$((OFF / 1048576)) conv=notrunc status=none \
        || { bad "[$a] cannot write the partition back"; return; }

    local SOCK="$D/serial.sock" SLOG="$D/serial.log"
    : >"$SLOG"
    cp /usr/share/OVMF/OVMF_VARS_4M.fd "$D/OVMF_VARS.fd"
    qemu-system-x86_64 \
        -m 2048 -smp 2 -no-reboot \
        -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
        -drive "if=pflash,format=raw,unit=1,file=$D/OVMF_VARS.fd" \
        -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
        -display none -vga std \
        -serial "unix:$SOCK,server,nowait" \
        -enable-kvm -cpu host \
        -device virtio-keyboard-pci -device virtio-tablet-pci \
        -drive "file=$NVME,if=none,format=raw,id=nvme0" \
        -device nvme,drive=nvme0,serial=BLOGINTGT \
        >"$D/qemu.out" 2>&1 &
    local QPID=$!
    reap_add "$QPID"
    info "[$a] qemu pid $QPID, serial socket $SOCK"

    python3 tests/linux/serial_drive.py "$SOCK" "$W/drive.$a" "$SLOG" "$D/drive.trace" \
        >"$D/drive.log" 2>&1
    local DRC=$?
    if [ "$DRC" = 0 ]; then
        info "[$a] the driver completed its script"
    else
        info "[$a] the driver stopped early (rc=$DRC) -- see $D/drive.log; the log below is still read"
    fi

    # Wait for the machine to power ITSELF off. Killing it is a power cut and
    # the ext4 will not have committed the disk-side evidence.
    local i=0
    while [ "$i" -lt 320 ]; do
        sleep 2; i=$((i+2))
        local st
        st=$(awk '{print $3}' "/proc/$QPID/stat" 2>/dev/null)
        case "${st:-X}" in Z|X) break ;; esac
    done
    if [ "$i" -lt 320 ]; then
        ok "[$a] the machine powered itself off (${i}s) -- the filesystem committed"
    else
        bad "[$a] the machine did NOT power itself off in ${i}s; the disk-side evidence below may be uncommitted"
    fi
    kill -TERM "$QPID" 2>/dev/null; sleep 2; kill -KILL "$QPID" 2>/dev/null
    wait "$QPID" 2>/dev/null

    # ---- score this arm ---------------------------------------------------
    # Strip CR: the console is CRLF.
    tr -d '\r' <"$SLOG" >"$D/serial.txt"
    local S="$D/serial.txt"

    if grep -aq "BOOTLOGIN-READY-$a" "$S"; then
        ok "[$a] the machine booted and reached this arm's rc marker"
    else
        bad "[$a] the machine never reached BOOTLOGIN-READY-$a -- nothing below is a measurement of this arm"
        tail -30 "$S" 2>/dev/null | sed 's/^/        /'
        return
    fi

    # Re-carve the partition to read the disk-side evidence.
    rm -f "$PART"
    dd if="$NVME" of="$PART" bs=1M skip=$((OFF / 1048576)) \
       count=$(( (SZ + 1048575) / 1048576 )) status=none 2>/dev/null
    local PWNED=no IDFILE=""
    if /sbin/debugfs -R "stat /var/log/bootlogin-pwned.txt" "$PART" 2>/dev/null | grep -q '^Inode:'; then
        PWNED=yes
    fi
    rm -f "$D/idfile"
    # IN THE USER'S OWN HOME, not /var/log. THE FIRST RUN OF THIS GATE PUT IT
    # IN /var/log AND SCORED A FALSE FAIL: the session runs as uid $EXPECT_UID
    # and /var/log belongs to root, so the redirect could not create the file.
    # The gate was asserting that an unprivileged session can write a
    # root-owned directory, which it must not be able to do. The home
    # directory is read from the machine's own /etc/passwd, not assumed.
    /sbin/debugfs -R "dump $USERHOME/bootlogin-id.txt $D/idfile" "$PART" >/dev/null 2>&1
    [ -s "$D/idfile" ] && IDFILE="$(tr -d '\r\n' <"$D/idfile")"
    info "[$a] disk: pwned-file=$PWNED  id-file='${IDFILE:-<none>}'"
    info "[$a] wire: $(root_identity_lines "$S" | wc -l) line(s) carry a root identity"

    case "$a" in
    autologin)
        # ---- THE INSTRUMENT PROOF ----------------------------------------
        # Everything here must PASS, and if any of it fails the guarded arm's
        # absence results are worthless and say so.
        if has_root_identity "$S"; then
            ok "[autologin] the console answered \`id\` with a root identity -- A ROOT SHELL IS VISIBLE TO THIS INSTRUMENT, on this port, with this driver and this pattern"
            info "  $(root_identity_lines "$S" | head -1)"
        else
            bad "[autologin] the console did NOT answer with uid=0. This gate cannot see a root shell even where one IS, so the guarded arm's silence proves NOTHING"
        fi
        if [ "$PWNED" = yes ]; then
            ok "[autologin] the console executed a redirect and CREATED /var/log/bootlogin-pwned.txt -- the disk-side probe can fire"
        else
            bad "[autologin] the console did not create the pwned file, so the disk-side absence check in the guarded arm proves nothing"
        fi
        # And it got there WITHOUT a password, which is the property `-a` has.
        if grep -aq '^login: ' "$S"; then
            bad "[autologin] a 'login: ' prompt appeared on an autologin arm -- \`-a\` did not take effect, so this is not the control it claims to be"
        else
            ok "[autologin] and NO 'login: ' prompt appeared -- the root shell was reached with no password typed"
        fi
        if grep -aq 'Login incorrect' "$S"; then
            bad "[autologin] 'Login incorrect' appeared on an arm that never offered a credential"
        else
            ok "[autologin] and nothing was refused, because nothing was asked"
        fi
        ;;
    guarded)
        # ---- THE PROMPT ---------------------------------------------------
        if grep -aq 'rc.login: getty started on /dev/ttyS0' "$S"; then
            ok "[guarded] the rc started a getty on the console"
        else
            bad "[guarded] the rc did not report starting a getty on /dev/ttyS0"
        fi
        if grep -aq 'rc.login: getty started on /dev/tty2' "$S" && \
           grep -aq 'rc.login: getty started on /dev/tty3' "$S"; then
            ok "[guarded] and gettys on /dev/tty2 and /dev/tty3 (STARTED only -- no instrument here reads them back)"
        else
            bad "[guarded] the rc did not report starting the virtual-terminal gettys"
        fi
        # ANCHORED AT LINE START, and that is not style. The rc's own
        # progress line `rc.login: getty started on /dev/ttyS0` CONTAINS the
        # substring `login:`, so an unanchored grep here would go green on
        # the rc having merely SAID it started a getty -- the gate would be
        # reporting its own output. user/login.ad writes "login: " at the
        # start of a line; `rc.login:` never is.
        if grep -aq '^login: ' "$S"; then
            ok "[guarded] THE CONSOLE PRESENTED A 'login: ' PROMPT (matched anchored, so the rc's own 'rc.login:' line cannot satisfy it)"
            info "  prompts seen: $(grep -ac '^login: ' "$S")"
        else
            bad "[guarded] no 'login: ' prompt at the start of any console line"
        fi

        # ---- REFUSAL ------------------------------------------------------
        local nwrong
        nwrong=$(grep -ac 'Login incorrect' "$S")
        if [ "$nwrong" -ge 2 ]; then
            ok "[guarded] a wrong password was REFUSED ('Login incorrect' x$nwrong: the junk credential and the real account's wrong password)"
        else
            bad "[guarded] expected at least 2 'Login incorrect' (junk credential, then '$USERNAME' with a wrong password); saw $nwrong"
        fi

        # ---- ADMISSION ----------------------------------------------------
        if has_uid "$S" "$EXPECT_UID"; then
            ok "[guarded] the RIGHT password ADMITTED: the session answered \`id\` with uid=$EXPECT_UID"
            info "  $(uid_lines "$S" "$EXPECT_UID" | head -1)"
        else
            bad "[guarded] the right password did not yield a session running as uid $EXPECT_UID"
        fi
        printf '%s\n' "$IDFILE" >"$D/idline.txt"
        if [ -n "$IDFILE" ] && has_uid "$D/idline.txt" "$EXPECT_UID"; then
            ok "[guarded] and the session wrote a file the machine kept: $IDFILE"
        else
            bad "[guarded] the session did not leave $USERHOME/bootlogin-id.txt saying uid=$EXPECT_UID (got '${IDFILE:-<none>}')"
        fi

        # ---- THE ABSENCE, three instruments -------------------------------
        # (0) ORDERING. A `hamsh$ ` prompt on this port is not by itself a
        # defect -- the AUTHENTICATED session's own shell prints one, and in a
        # passing run it does. What must never happen is a shell prompt
        # BEFORE the login prompt. Measured on the first run of this gate:
        # `getty: terminal ready` at line 625, `login: ` at 626, and the first
        # `hamsh$ ` at 647, after the password was accepted.
        local first_login first_sh
        first_login=$(grep -an '^login: ' "$S" | head -1 | cut -d: -f1)
        first_sh=$(grep -an 'hamsh\$' "$S" | head -1 | cut -d: -f1)
        if [ -z "$first_login" ]; then
            bad "[guarded] no login prompt at all, so the ordering check cannot be made"
        elif [ -z "$first_sh" ]; then
            ok "[guarded] no shell prompt appeared on the console at any point"
        elif [ "$first_sh" -gt "$first_login" ]; then
            ok "[guarded] the first shell prompt (line $first_sh) comes AFTER the first login prompt (line $first_login) -- no shell was offered before the question"
        else
            bad "[guarded] a shell prompt appeared at line $first_sh, BEFORE the login prompt at line $first_login"
        fi

        # ---- THE ABSENCE, both typed instruments --------------------------
        # The probes were typed BEFORE any correct credential was offered.
        # Everything before the first successful login is what must contain
        # no root identity.
        local PRE
        PRE="$(awk '/uid='"$EXPECT_UID"'([^0-9]|$)/{exit} {print}' "$S")"
        printf '%s\n' "$PRE" >"$D/pre-auth.txt"
        if has_root_identity "$D/pre-auth.txt"; then
            bad "[guarded] A ROOT SHELL ANSWERED BEFORE ANYONE AUTHENTICATED -- the hole is NOT closed"
            root_identity_lines "$D/pre-auth.txt" | head -3 | sed 's/^/        /'
        else
            ok "[guarded] NO ROOT IDENTITY ANSWERED THE CONSOLE BEFORE AUTHENTICATION (and the autologin arm proves this check can fail)"
        fi
        if [ "$PWNED" = no ]; then
            ok "[guarded] and the console created NO file -- the redirect was eaten as a credential, not executed (the autologin arm proves the file can appear)"
        else
            bad "[guarded] /var/log/bootlogin-pwned.txt EXISTS -- something executed a typed command without authenticating"
        fi
        ;;
    esac
}

for a in $ARMS; do
    run_arm "$a"
done

say "evidence"
info "$W"
finish
