#!/usr/bin/env bash
#
# tests/linux/greeter_fail_terminal.sh — WHEN THE GRAPHICAL LOGIN NEVER
# ANSWERS, IS THERE A TERMINAL TO LOG IN ON?
#
# REGISTRATION. ON-DEMAND, like graphical_login.sh and installed_boot_login.sh:
# it boots an installed disk twice under OVMF and is far past the CI battery's
# per-shard budget.
#
# WHY THIS EXISTS
# ===============
# David, 2026-08-20: "the greeter failure should leave a terminal for you to
# debug. just like Linux."
#
# /etc/rc.d/rc.5 runs /bin/hamgreet IN THE FOREGROUND -- deliberately, because
# that is what stops a desktop session existing before anybody authenticates,
# and tests/linux/graphical_login.sh measures exactly that with a process
# census. The cost was that /etc/rc.boot.machine sourced /etc/rc.login AFTER
# /etc/rc.boot.installed, so on a graphical machine the gettys were behind the
# greeter: a machine whose greeter presented and was never answered had no
# login program on any terminal, while rc.5.linux:178 printed
#
#     [rc.5] Why: /var/lib/hamgreet.trace. Log in on a terminal to read it.
#
# THE DOCUMENTED RECOVERY PATH DID NOT EXIST. That is the hole this measures,
# and etc/rc.boot.machine now sources /etc/rc.login FIRST.
#
# WHAT "THE GREETER FAILED" MEANS HERE, AND WHY IT IS THE HONEST CHOICE
# =====================================================================
# It is NOT a deleted or crashing /bin/hamgreet. A greeter that fails FAST
# would not distinguish the two orders at all: rc.5 would return, rc.boot
# .installed would return, and the OLD order would then reach `source
# '/etc/rc.login'` and start the gettys a second later. Measuring that would
# be a gate that cannot fail, which is worse than no gate.
#
# The failure that actually happened, nine times, in the 1.0.33 release run is
# a greeter that PRESENTS AND IS NEVER ANSWERED -- every one of those gate logs
# ends on `hamgreet: the graphical login is presenting`. PID 1's rc is parked
# in hamgreet forever. So this gate boots the REAL greeter on a real runlevel-5
# machine, types NOTHING at the screen, and asks the serial console whether
# anybody is home. No binary is tampered with to produce the failure; the
# failure is simply not authenticating, which is the state every unattended
# boot of this machine is in.
#
# THE TWO ARMS, AND THE SECOND ONE IS THE CONTROL
# ===============================================
#   reordered  /etc/rc.boot is etc/rc.boot.machine VERBATIM (the shipped file,
#              byte-compared on read-back). Must present `login: ` at the start
#              of a console line while the greeter is still presenting, must
#              refuse a wrong password, and must admit the account and answer
#              `id` with its uid.
#   oldorder   the SAME file with its two `source` lines swapped back to the
#              pre-2026-08-20 order. Must present NO `login: ` prompt at all.
#
# THE CONTROL IS GENERATED FROM THE SUBJECT, NOT WRITTEN OUT BY HAND, so the
# two arms cannot drift apart: the gate swaps the two lines with awk and FAILS
# if the swap did not change the file, or if the result is not a permutation of
# the same lines. An arm that is silently identical to the subject would report
# a green for the wrong reason.
#
# WHAT THIS GATE DOES NOT SAY
# ===========================
#   * NOTHING ABOUT THE SESSION-BEFORE-AUTHENTICATION PROPERTY. That is
#     tests/linux/graphical_login.sh's process census and it is unaffected by
#     the ordering here -- hamgreet is still foreground and rc.5 is untouched.
#     A green here is not a substitute for that gate; run both.
#   * NOTHING ABOUT tty2/tty3. Once wsysd presents it owns the framebuffer, so
#     no instrument on this machine can read back what is on a VT.
#     etc/rc.login.linux records the same limit.
#   * NOTHING ABOUT AN EXISTING MACHINE. /etc/rc.boot is machine-owned (hpm
#     writes it only when ABSENT), so a box installed before the change keeps
#     the old order. This gate measures the file the installer and hpm WRITE.
#
# THE MACHINE IS KILLED, NOT POWERED OFF, AND THAT IS NOT AN OVERSIGHT: the
# shipped rc ends in `supervise`, which never returns, so nothing here can ask
# the machine to leave. Every assertion below is therefore made on the WIRE,
# from the serial log; this gate makes no disk-side claim and does not need the
# filesystem to have committed.
#
# Usage: tests/linux/greeter_fail_terminal.sh
#   GFT_SRC_NVME=<img>  installed disk to copy (default:
#                       ~/.hamnix-build/instacct/target-nvme.img)
#   GFT_WORK=<dir>      work dir (default ~/.hamnix-build/greeterfail)
#   GFT_USER / GFT_UPASS   credentials that disk was installed with
#   GFT_ARMS=<list>     arms to run (default "reordered oldorder")
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

. tests/linux/reap.sh
reap_on_exit

SRC="${GFT_SRC_NVME:-$HOME/.hamnix-build/instacct/target-nvme.img}"
W="${GFT_WORK:-$HOME/.hamnix-build/greeterfail}"
USERNAME="${GFT_USER:-hamacctusr}"
UPASS="${GFT_UPASS:-hamacctpw}"
ARMS="${GFT_ARMS:-reordered oldorder}"
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
[ -f tests/linux/serial_drive.py ] || { echo "INCONCLUSIVE: need serial_drive.py"; exit 2; }
[ -s "$SRC" ] || { echo "INCONCLUSIVE: no installed disk at $SRC -- run tests/linux/installed_accounts.sh first"; exit 2; }

mkdir -p "$W"
export TMPDIR="$W/tmp"; mkdir -p "$TMPDIR"

# The uid-on-the-wire matcher, guarded at both ends so `uid=1` cannot match
# `uid=1001` and vice versa. Copied verbatim in intent from
# installed_boot_login.sh, which records why `uid=0(` was the wrong pattern on
# this tree (its /etc/passwd has no uid 0 line, so `id` prints no parentheses).
has_uid() { grep -aqE "uid=$2([^0-9]|\$)" "$1"; }
uid_lines() { grep -aE "uid=$2([^0-9]|\$)" "$1"; }

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
# The source disk predates this tree's hamsh and getty. Both are built here and
# written onto every arm's copy, so the BINARIES are a constant of the run and
# the rc is the only variable between the two arms.
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

# =========================================================================
say "1 -- the two rcs, and the control is DERIVED from the subject"
SUBJ="$PROJ_ROOT/etc/rc.boot.machine"
[ -s "$SUBJ" ] || { bad "no etc/rc.boot.machine in this tree"; finish; }

# The subject must have the NEW order for this gate to mean anything: rc.login
# strictly above rc.boot.installed. Read the line numbers rather than trusting
# the file to be what the commit message said.
LN_LOGIN=$(grep -n "^source '/etc/rc.login'" "$SUBJ" | head -1 | cut -d: -f1)
LN_INST=$(grep -n "^source '/etc/rc.boot.installed'" "$SUBJ" | head -1 | cut -d: -f1)
LN_SUP=$(grep -n '^supervise$' "$SUBJ" | head -1 | cut -d: -f1)
if [ -z "$LN_LOGIN" ] || [ -z "$LN_INST" ] || [ -z "$LN_SUP" ]; then
    bad "etc/rc.boot.machine does not carry all three of source rc.login / source rc.boot.installed / supervise -- this gate is measuring the wrong tree"
    finish
fi
if [ "$LN_LOGIN" -lt "$LN_INST" ]; then
    ok "etc/rc.boot.machine sources /etc/rc.login (line $LN_LOGIN) BEFORE /etc/rc.boot.installed (line $LN_INST)"
else
    bad "etc/rc.boot.machine still sources /etc/rc.login (line $LN_LOGIN) AFTER /etc/rc.boot.installed (line $LN_INST) -- the reorder is not in this tree"
    finish
fi
if [ "$LN_SUP" -gt "$LN_INST" ]; then
    ok "\`supervise\` (line $LN_SUP) is still last, so PID 1 cannot fall through to an interactive prompt"
else
    bad "\`supervise\` is at line $LN_SUP, above the runlevel entry at $LN_INST"
fi

cp "$SUBJ" "$W/rc.boot.reordered"

# THE CONTROL, GENERATED. Swap those two source lines and change nothing else.
awk -v a="$LN_LOGIN" -v b="$LN_INST" '
    NR==a { print "source '\''/etc/rc.boot.installed'\''"; next }
    NR==b { print "source '\''/etc/rc.login'\''"; next }
    { print }
' "$SUBJ" >"$W/rc.boot.oldorder"

if cmp -s "$W/rc.boot.reordered" "$W/rc.boot.oldorder"; then
    bad "the generated control rc is IDENTICAL to the subject -- the swap did nothing and the control cannot fire"
    finish
else
    ok "the control rc differs from the subject"
fi
# ...and differs ONLY by that swap: same bytes when both are sorted.
if [ "$(sort "$W/rc.boot.reordered" | md5sum)" = "$(sort "$W/rc.boot.oldorder" | md5sum)" ]; then
    ok "the control rc is a PERMUTATION of the subject -- the two arms differ by line order and nothing else"
else
    bad "the control rc is not a permutation of the subject; the swap changed more than the order"
    finish
fi
C_LOGIN=$(grep -n "^source '/etc/rc.login'" "$W/rc.boot.oldorder" | head -1 | cut -d: -f1)
C_INST=$(grep -n "^source '/etc/rc.boot.installed'" "$W/rc.boot.oldorder" | head -1 | cut -d: -f1)
if [ "$C_LOGIN" -gt "$C_INST" ]; then
    ok "the control rc has the OLD order: rc.login at line $C_LOGIN, below rc.boot.installed at line $C_INST"
else
    bad "the control rc did not come out in the old order (rc.login $C_LOGIN, rc.boot.installed $C_INST)"
    finish
fi

# =========================================================================
say "2 -- the drive script"
# ONE script for BOTH arms. The arms must not be driven differently, or the
# difference in what they answer would be a difference in what they were asked.
#
# The first EXPECT is the greeter SAYING IT IS PRESENTING. That is the failure
# state this gate is about: from here on PID 1's rc is parked and will not
# continue, and nothing this gate does will authenticate it.
cat >"$W/drive" <<DEOF
EXPECT 420 the graphical login is presenting
SLEEP 10
# THE WHOLE QUESTION. Is there a login program on the console while the greeter
# is still parked? Anchored on a line start, because a prompt welded to the
# tail of somebody else's line is a prompt an operator cannot read either.
EXPECT 120 \r?\nlogin:
# A wrong password first, so a green cannot be a console that admits anybody.
SEND $USERNAME
SLEEP 2
SEND $WRONGPASS
SLEEP 4
EXPECT 60 Login incorrect
SEND $USERNAME
SLEEP 2
SEND $UPASS
SLEEP 10
SEND id
SLEEP 5
DONE 10
DEOF
ok "the drive script is written, and both arms get the same one"

OFF=""; SZ=""
read -r OFF SZ < <(part_geom "$SRC" 2)
if [ -z "$OFF" ] || [ -z "$SZ" ]; then
    bad "cannot read the root partition geometry out of $SRC"
    finish
fi
info "root partition at offset $OFF, size $SZ"

# The account's uid and home, read off the machine's own /etc/passwd rather
# than assumed. A gate that assumes a uid measures its own assumption.
PASSWDTMP="$W/passwd"
dd if="$SRC" of="$W/probe-part.img" bs=1M skip=$((OFF / 1048576)) \
   count=$(( (SZ + 1048575) / 1048576 )) status=none
/sbin/debugfs -R "dump /etc/passwd $PASSWDTMP" "$W/probe-part.img" >/dev/null 2>&1
EXPECT_UID=$(awk -F: -v u="$USERNAME" '$1==u{print $3}' "$PASSWDTMP" 2>/dev/null | head -1)
if [ -n "$EXPECT_UID" ]; then
    ok "the disk's /etc/passwd gives $USERNAME uid $EXPECT_UID"
else
    bad "no $USERNAME line in the disk's /etc/passwd -- this gate cannot say what a successful login should answer"
    finish
fi

# =========================================================================
run_arm() {
    local a="$1"
    say "arm '$a' -- boot at runlevel 5, never authenticate, ask the console"
    local D="$W/boot-$a"; rm -rf "$D"; mkdir -p "$D"
    local NVME="$D/nvme.img" PART="$D/part.img"

    cp --reflink=auto "$SRC" "$NVME" || { bad "[$a] cannot copy the installed disk"; return; }
    dd if="$NVME" of="$PART" bs=1M skip=$((OFF / 1048576)) \
       count=$(( (SZ + 1048575) / 1048576 )) status=none \
       || { bad "[$a] cannot carve the root partition"; return; }

    # e2fsck before and after the debugfs writes, for the reason
    # installed_boot_login.sh records: on a freshly copied image with a dirty
    # journal the first debugfs write silently does nothing.
    /sbin/e2fsck -fy "$PART" >"$D/fsck1.log" 2>&1

    # /etc/rc.runlevel MUST GO. If a previous gate left the runlevel-3 opt-out
    # on this disk the machine would never enter runlevel 5, never start a
    # greeter, and BOTH arms would show a login prompt -- a green that measured
    # nothing. Its absence is asserted after the writes, not assumed.
    cat >"$D/dbg.cmds" <<DBEOF
cd /etc
rm rc.boot
write $W/rc.boot.$a rc.boot
rm rc.login
write $PROJ_ROOT/etc/rc.login.linux rc.login
rm rc.runlevel
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

    # READ BACK EVERY FILE THIS GATE WROTE. A gate whose subject never landed
    # measures the old machine and calls it a result.
    local staged_ok=1
    rm -f "$D/rb.rc" "$D/rb.rclogin" "$D/rb.hamsh" "$D/rb.getty"
    /sbin/debugfs -R "dump /etc/rc.boot $D/rb.rc" "$PART" >/dev/null 2>&1
    /sbin/debugfs -R "dump /etc/rc.login $D/rb.rclogin" "$PART" >/dev/null 2>&1
    /sbin/debugfs -R "dump /bin/hamsh $D/rb.hamsh" "$PART" >/dev/null 2>&1
    /sbin/debugfs -R "dump /bin/getty $D/rb.getty" "$PART" >/dev/null 2>&1
    cmp -s "$W/rc.boot.$a" "$D/rb.rc"                       || staged_ok=0
    cmp -s "$PROJ_ROOT/etc/rc.login.linux" "$D/rb.rclogin"  || staged_ok=0
    cmp -s "$BIN/hamsh.elf" "$D/rb.hamsh"                   || staged_ok=0
    cmp -s "$BIN/getty.elf" "$D/rb.getty"                   || staged_ok=0
    if [ "$staged_ok" = 1 ]; then
        ok "[$a] rc.boot, rc.login, /bin/hamsh and /bin/getty read back byte-identical"
    else
        bad "[$a] the staged files did not land byte-identical -- see $D/debugfs.log"
        return
    fi
    if /sbin/debugfs -R "stat /etc/rc.runlevel" "$PART" 2>/dev/null | grep -q '^Inode:'; then
        bad "[$a] /etc/rc.runlevel is STILL on the disk -- this machine would stop at runlevel 3 and never start a greeter, so neither arm would measure anything"
        return
    else
        ok "[$a] /etc/rc.runlevel is absent -- this machine will enter runlevel 5"
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
        -device nvme,drive=nvme0,serial=GFTTGT \
        >"$D/qemu.out" 2>&1 &
    local QPID=$!
    reap_add "$QPID"
    info "[$a] qemu pid $QPID, serial socket $SOCK"

    python3 tests/linux/serial_drive.py "$SOCK" "$W/drive" "$SLOG" "$D/drive.trace" \
        >"$D/drive.log" 2>&1
    local DRC=$?
    info "[$a] the driver exited $DRC (a timed-out EXPECT is 1, and is EXPECTED in the control arm)"

    # THE MACHINE CANNOT LEAVE. The shipped rc ends in `supervise`, which never
    # returns. Killing it here is correct and every assertion below is on the
    # wire, not on the filesystem.
    kill -TERM "$QPID" 2>/dev/null; sleep 2; kill -KILL "$QPID" 2>/dev/null
    wait "$QPID" 2>/dev/null

    tr -d '\r' <"$SLOG" >"$D/serial.txt"
    local S="$D/serial.txt"

    # ---- the shared preconditions, scored in BOTH arms --------------------
    if grep -aq 'rc.boot: entered runlevel 5\|\[rc.5\] hamnix-linux graphical runlevel' "$S"; then
        ok "[$a] the machine entered runlevel 5"
    else
        bad "[$a] the machine never entered runlevel 5 -- nothing below is a measurement of a greeter failure"
        tail -30 "$S" 2>/dev/null | sed 's/^/        /'
        return
    fi
    if grep -aq 'the graphical login is presenting' "$S"; then
        ok "[$a] the greeter presented and PID 1's rc is parked in it -- this is the failure state being measured"
    else
        bad "[$a] the greeter never said it was presenting; this boot is not in the state this gate is about"
        tail -30 "$S" 2>/dev/null | sed 's/^/        /'
        return
    fi
    # NOBODY AUTHENTICATED GRAPHICALLY. If rc.5 came back, the greeter was
    # answered and the whole premise is gone.
    if grep -aq '\[rc.5\] authenticated -- starting the session' "$S"; then
        bad "[$a] rc.5 reports it AUTHENTICATED somebody -- this gate typed nothing at the screen, so the premise of both arms is void"
        return
    else
        ok "[$a] rc.5 never authenticated anybody, so the greeter is still parked"
    fi

    local PROMPTS
    PROMPTS=$(grep -ac '^login: ' "$S")
    info "[$a] '^login: ' appears $PROMPTS time(s); the bring-up markers appear $(grep -ac 'hamsh:stage-0[1-6]\|hamsh:_start hit' "$S") time(s)"

    case "$a" in
    reordered)
        if [ "$PROMPTS" -gt 0 ]; then
            ok "[reordered] the console presents 'login: ' at the start of a line ($PROMPTS time(s)) WHILE THE GREETER IS STILL PARKED -- there is a terminal to debug on"
        else
            bad "[reordered] no 'login: ' prompt at the start of any console line -- a greeter failure still leaves no terminal"
        fi
        if grep -aq 'rc.login: every terminal on this machine now asks who you are' "$S"; then
            ok "[reordered] /etc/rc.login ran"
        else
            bad "[reordered] /etc/rc.login never ran"
        fi
        # A prompt that admits anybody is not a login.
        if grep -aq 'Login incorrect' "$S"; then
            ok "[reordered] the wrong password was REFUSED"
        else
            bad "[reordered] 'Login incorrect' never appeared -- either the prompt was never driven or it admits anything"
        fi
        if has_uid "$S" "$EXPECT_UID"; then
            ok "[reordered] the account logged in and the session answered \`id\` with uid=$EXPECT_UID -- the terminal is USABLE, not merely present"
            info "  $(uid_lines "$S" "$EXPECT_UID" | head -1)"
        else
            bad "[reordered] no uid=$EXPECT_UID on the wire; a prompt appeared but no session was reached through it"
        fi
        # And it is not a root shell handed out for free.
        if grep -aqE 'uid=0([^0-9]|$)' "$S"; then
            bad "[reordered] a ROOT identity is on this console"
        else
            ok "[reordered] no root identity anywhere on this console"
        fi
        ;;
    oldorder)
        # ---- THE CONTROL. It must go RED where the subject goes green. ----
        if [ "$PROMPTS" = 0 ]; then
            ok "[oldorder] THE CONTROL FIRED: with the two source lines in the old order the same machine, same greeter, same binaries presents NO 'login: ' prompt at all. The subject's green is about the ORDER."
        else
            bad "[oldorder] a 'login: ' prompt appeared $PROMPTS time(s) in the OLD order too -- this gate cannot tell the two orders apart and the subject's green proves nothing"
        fi
        if grep -aq 'rc.login: every terminal on this machine now asks who you are' "$S"; then
            bad "[oldorder] /etc/rc.login RAN in the old order -- the greeter did not park the rc, so this arm is not a control"
        else
            ok "[oldorder] /etc/rc.login never ran: it is below the runlevel entry and the rc never got there"
        fi
        if has_uid "$S" "$EXPECT_UID"; then
            bad "[oldorder] a session for uid=$EXPECT_UID was reached in the old order"
        else
            ok "[oldorder] no session was reachable from this console"
        fi
        ;;
    esac
}

for a in $ARMS; do run_arm "$a"; done

say "verdict"
info "subject: etc/rc.boot.machine as this tree ships it"
info "control: the same file with the two source lines swapped back"
finish
