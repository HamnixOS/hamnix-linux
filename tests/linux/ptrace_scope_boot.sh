#!/usr/bin/env bash
#
# REGISTRATION, 2026-08-17. Until this date scripts/test_gate_registration.sh
# globbed only scripts/test_*.sh, so this directory was invisible to the gate
# against unregistered gates and every file in it read as coverage without
# being coverage. This gate is ON-DEMAND: not in ci_battery_manifest.txt
# because it boots a machine under `qemu-system-x86_64`.
#
# tests/linux/ptrace_scope_boot.sh — the boot policy that everything else in
# the window system's confidentiality story rests on, MEASURED IN A REAL BOOT.
#
# WHAT IS UNDER TEST
# ==================
# user/linux-wsys.c moved a window's keystrokes out of the shared segment into
# a per-window abstract socket (THE KEYSTROKE CHANNEL) and made every window
# owner non-dumpable (owner_harden).  Both are userland arrangements between
# processes.  A same-uid PTRACE_ATTACH is underneath all of them: attach to the
# victim and its memory is yours, socket or no socket.
#
# Linux's answer is the Yama LSM.  user/linuxinit.ad sets
# kernel.yama.ptrace_scope=1 as PID 1, the instant /proc exists -- Debian's and
# Ubuntu's default, so not a novel policy: a non-ancestor same-uid attach is
# refused, and a debugger still debugs anything it launched itself.
#
# WHY IT IS A BOOT TEST AND NOT A HOST TEST
# =========================================
# ptrace_scope is not namespaced.  A user namespace cannot write it, so there is
# no way to measure the SET state on the dev host without being root on the dev
# host -- which this tree does not do to the machine it is built on.  A real
# boot is the only honest place to measure it, and it is also the only place
# that measures the thing that actually ships: PID 1's own code path, running as
# PID 1, with the kernel the image carries.
#
# THREE THINGS, AND THE FIRST TWO ARE THE POSITIVE CONTROL
# ========================================================
#   1. YAMA EXISTS ON THE KERNEL THIS IMAGE SHIPS.  scripts/hamlinux_image.sh
#      copies the newest /boot/vmlinuz-* off the build host, so the guest kernel
#      IS the host kernel and /proc/sys/kernel/yama/ptrace_scope on the host is
#      a fact about the guest.  If that file is absent this gate says SO, by
#      name, and does not pretend the setting is in force -- which is the whole
#      reason linuxinit reads the value back instead of writing and hoping.
#   2. THE ATTACK WORKS WHEN NOTHING STOPS IT.  tests/linux/ptrace_attack.c is
#      run on the dev host, where ptrace_scope is 0, and its sibling-to-sibling
#      PTRACE_ATTACH must SUCCEED.  A refusal measured without a matching
#      success proves only that the probe is broken.
#   3. THE SAME BINARY IS REFUSED INSIDE THE BOOT, and the console says the
#      knob was set and read back.
#
# REVERT-SENSITIVE.  With user/linuxinit.ad reverted, assertions 4, 5 and 6 go
# red: the console carries no ptrace_scope line, the guest reads 0, and the
# sibling attach inside the guest SUCCEEDS.
#
# Usage: tests/linux/ptrace_scope_boot.sh
#        PTRACEGATE_SKIP_BOOT=1 ...   host half only (seconds)
#        PTRACEGATE_REBUILD_IMAGE=1   restage the private image
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT" || exit 1

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL $*"; }
note() { echo "  --   $*"; }

# Nothing here is backgrounded -- the guest runs in the foreground under
# `timeout` -- but the registry is installed anyway, so a ^C or a SIGTERM to
# this script still runs the EXIT path rather than skipping it.
. tests/linux/reap.sh

# A private build tree, keyed on the checkout: several agents share this box and
# build/image is one directory.
KEY="$(printf '%s' "$PROJ_ROOT" | sha256sum | cut -c1-12)"
W="${PTRACEGATE_DIR:-$HOME/.hamnix-build/ptrace_scope_boot.$KEY}"
mkdir -p "$W" || exit 1
reap_track "$W/reaped"
reap_on_exit

echo "[ptracegate] PART 1 -- is Yama on the kernel this image ships?"

KNOB=/proc/sys/kernel/yama/ptrace_scope
HOSTKERNEL="$(ls -1 /boot/vmlinuz-* 2>/dev/null | sort -V | tail -1)"
IMGKVER="$(basename "${HOSTKERNEL:-none}" | sed 's/^vmlinuz-//')"
note "the image ships $IMGKVER (scripts/hamlinux_image.sh takes the newest /boot/vmlinuz-*)"
note "this host is running $(uname -r)"

if [ -e "$KNOB" ]; then
    ok "(1) $KNOB exists, so the Yama LSM is built in and enabled -- current value $(cat "$KNOB")"
else
    bad "(1) $KNOB DOES NOT EXIST on this kernel."
    note "     user/linuxinit.ad will say so on the console and warn that same-uid"
    note "     ptrace is unrestricted, which is the correct behaviour -- but the"
    note "     window system's same-uid confidentiality does NOT hold on this"
    note "     kernel, and no line in this tree can make it hold.  Report it as"
    note "     an open hole rather than treating this gate's skip as a pass."
    echo "[ptracegate] PASS $PASS  FAIL $FAIL"
    exit 1
fi

if [ "$IMGKVER" = "$(uname -r)" ]; then
    ok "(2) and it is the SAME kernel the guest boots, so this is a fact about the guest and not only about the build host"
else
    bad "(2) the host is running $(uname -r) but the image ships $IMGKVER; the Yama reading above is about a kernel the guest will not boot"
fi

echo "[ptracegate] PART 2 -- the attack itself, on the dev host (the control)"
PROBE="$W/ptraceprobe"
cc -std=gnu11 -O1 -static -o "$PROBE" tests/linux/ptrace_attack.c \
    >"$W/probe.build.log" 2>&1 || {
    cat "$W/probe.build.log"; echo "[ptracegate] BUILD FAILED"; exit 2; }

HOSTOUT="$("$PROBE")"
echo "  $HOSTOUT"
HOSTSCOPE="$(cat "$KNOB")"
if [ "$HOSTSCOPE" = "0" ]; then
    if printf '%s' "$HOSTOUT" | grep -q 'attach=0'; then
        ok "(3) with ptrace_scope=0 a SIBLING process attaches to its sibling and reads it: the attack is real and the probe works"
    else
        bad "(3) ptrace_scope is 0 here and the attach STILL failed -- the probe is broken, so nothing it reports inside the guest means anything: $HOSTOUT"
    fi
else
    note "this host has ptrace_scope=$HOSTSCOPE already, so the positive control"
    note "cannot be driven here; the guest half below still measures the refusal."
    ok "(3) skipped: the dev host already restricts ptrace (scope=$HOSTSCOPE)"
fi

if [ "${PTRACEGATE_SKIP_BOOT:-0}" = "1" ]; then
    echo "[ptracegate] PART 3 skipped (PTRACEGATE_SKIP_BOOT=1)"
    echo "[ptracegate] PASS $PASS  FAIL $FAIL"
    [ "$FAIL" = 0 ] || exit 1
    exit 0
fi

for t in qemu-system-x86_64 cpio gzip timeout; do
    command -v "$t" >/dev/null 2>&1 || {
        echo "[ptracegate] SKIP PART 3: $t not available"
        echo "[ptracegate] PASS $PASS  FAIL $FAIL"
        [ "$FAIL" = 0 ] || exit 1
        exit 0; }
done

echo "[ptracegate] PART 3 -- a real boot: linuxinit as PID 1, and the same probe"
IMG="${PTRACEGATE_IMAGE:-$W/image}"
if [ ! -f "$IMG/vmlinuz" ] || [ "${PTRACEGATE_REBUILD_IMAGE:-0}" = "1" ]; then
    echo "[ptracegate] staging a private image (this takes a few minutes)"
    HAMLINUX_DISTRO_RO=1 HAMLINUX_JOBS="${HAMLINUX_JOBS:-4}" nice -n 15 \
        bash scripts/hamlinux_image.sh "$IMG" > "$W/image.build.log" 2>&1 || {
        echo "[ptracegate] FAIL: image build (see $W/image.build.log)"
        tail -20 "$W/image.build.log"; exit 1; }
else
    echo "[ptracegate] reusing the staged image at $IMG"
fi

# THE PROBE GOES IN THE PRIVATE IMAGE ONLY, never in the shipped one.  It is a
# test binary: NORTH_STAR.md's standing rule is that everything in the shipped
# /bin must also be in a package, and a gate's fixture has no business being
# either.  It is copied into this gate's own staged root, which is packed into
# this gate's own initramfs and thrown away.
cp "$PROBE" "$IMG/root/bin/ptraceprobe"
chmod 755 "$IMG/root/bin/ptraceprobe"

# THE GUEST RUNS IT FROM ITS OWN rc, AND IS NOT TYPED AT.
#
# The first version of this gate fed the commands to the interactive shell over
# the serial console, the way tests/linux/lex_error_fatal.sh does.  It does not
# work here, and the reason is worth recording: that gate boots a machine whose
# rc DID NOT RUN, so its console is idle.  This one boots the FULL rc -- the
# whole desktop comes up, the compositor and the clipboard bridges and the panel
# are all live -- and the line editor got through about thirty characters in a
# hundred seconds, interleaving three commands into one unrunnable line.  Every
# assertion below it failed for a reason that had nothing to do with ptrace.
#
# So the probe is prepended to the rc instead: it runs BEFORE the desktop, its
# output is on the console by construction, and there is no race with a shell
# that may or may not be reading.  linuxinit has already set ptrace_scope by
# then -- that happens in PID 1, before hamsh is even exec'd -- so early is not
# only faster, it is the honest place to ask.
RC="$IMG/root/etc/rc.boot"
[ -f "$RC" ] || { echo "[ptracegate] FAIL: no $RC in the staged root"; exit 1; }
cp "$RC" "$W/rc.boot.orig"
{
    echo "echo ptracegate-probe-begin"
    echo "cat /proc/sys/kernel/yama/ptrace_scope"
    echo "/bin/ptraceprobe"
    echo "echo ptracegate-probe-end"
    cat "$W/rc.boot.orig"
} > "$RC.new" && mv "$RC.new" "$RC"

BOOTDIR="$W/boot"
rm -rf "$BOOTDIR"; mkdir -p "$BOOTDIR"
cp "$IMG/vmlinuz" "$BOOTDIR/vmlinuz"
CPIO="$W/pack.cpio"; : > "$CPIO"
( cd "$IMG/root" && find . -path './home/*' -prune -o -print0 \
    | cpio --null -o -H newc --quiet -R 0:0 ) >> "$CPIO"
( cd "$IMG/root" && find ./home/live -print0 \
    | cpio --null -o -H newc --quiet -R 1001:1001 ) >> "$CPIO" 2>/dev/null
( cd "$IMG/root" && find ./home/hostowner -print0 \
    | cpio --null -o -H newc --quiet -R 1:1 ) >> "$CPIO" 2>/dev/null
gzip -9 < "$CPIO" > "$BOOTDIR/initramfs.cpio.gz"
rm -f "$CPIO"

# PUT THE STAGED ROOT BACK THE WAY IT WAS, NOW THAT THE CPIO IS SEALED.  The
# image directory can be shared with another gate (PTRACEGATE_IMAGE), and a
# staged root left carrying this gate's fixture would put a test binary and four
# lines of rc into somebody else's boot -- which is the failure this project
# calls the worst shape there is, arriving from the side.
mv "$W/rc.boot.orig" "$RC"
rm -f "$IMG/root/bin/ptraceprobe"

LOG="$W/boot.log"
SECS="${PTRACEGATE_BOOT_SECONDS:-110}"
# stdin is closed, not fed: nothing is typed at this machine.
HAMLINUX_IMAGE_DIR="$BOOTDIR" HAMLINUX_VNC=none \
    timeout "$((SECS + 20))" scripts/hamlinux_vm.sh script --timeout "$SECS" \
    < /dev/null > "$LOG" 2>&1
sed -e 's/\r$//' "$LOG" | tr -d '\0' \
    | sed -e 's/\x1b\[[0-9;?]*[A-Za-z]//g' -e 's/\x1b[()][A-Z0-9]//g' > "$LOG.txt"
B="$LOG.txt"

if grep -q 'linuxinit: kernel.yama.ptrace_scope = 1' "$B"; then
    ok "(4) PID 1 set it AND read it back, and says so on the console: $(grep -m1 -o 'linuxinit: kernel.yama.ptrace_scope.*' "$B")"
else
    bad "(4) PID 1 never reported kernel.yama.ptrace_scope = 1"
    grep -i 'yama\|ptrace' "$B" | sed -n '1,10p'
fi

# THE KERNEL'S OWN COPY, read by an ordinary command in the booted machine --
# not PID 1's report of what it wrote.  A sysctl that is written, read back by
# the writer and then reset by something later in the boot would satisfy (4) and
# fail here, which is why both are asked.  Matched INSIDE the marker bracket, so
# a stray `1` anywhere else on a busy console cannot answer for it.
BLOCK="$W/block.txt"
awk '/ptracegate-probe-begin/{f=1;next} /ptracegate-probe-end/{f=0} f' "$B" > "$BLOCK"
if [ ! -s "$BLOCK" ]; then
    bad "(5) the rc probe block never ran: no output between the markers"
    grep -n 'ptracegate-probe' "$B" | sed -n '1,6p'
elif grep -qx '1' "$BLOCK"; then
    ok "(5) and the booted machine reads 1 out of /proc/sys/kernel/yama/ptrace_scope"
else
    bad "(5) the guest's own /proc/sys/kernel/yama/ptrace_scope did not read 1"
    sed -n '1,8p' "$BLOCK"
fi

PLINE="$(grep -m1 '^== ptraceprobe' "$B")"
if [ -z "$PLINE" ]; then
    bad "(6) the probe produced no line at all inside the guest -- it did not run, so nothing here is measured"
    grep -n 'ptracegate-probe' "$B" | sed -n '1,6p'
elif printf '%s' "$PLINE" | grep -q 'uid=0 '; then
    # ROOT IS NOT THE THREAT MODEL and must never answer for it. root holds
    # CAP_SYS_PTRACE, Yama does not apply to it, and an `attach=0` from uid 0
    # would be the kernel behaving correctly and this gate reporting a hole
    # that is not there. The probe drops privileges itself; if it did not, the
    # measurement is void and says so rather than passing or failing.
    bad "(6) the probe measured ROOT (uid=0), which Yama never restricts -- it did not drop privileges: $PLINE"
elif ! printf '%s' "$PLINE" | grep -q 'dumpable=1'; then
    # A NON-DUMPABLE VICTIM REFUSES AN ATTACH ON ITS OWN, and this gate would
    # then be reporting Yama's answer while measuring somebody else's. It was
    # not hypothetical: changing uid clears the dumpable flag, so the probe's
    # own privilege drop made the victim non-dumpable, and the REVERTED run --
    # scope=0, nothing in force -- printed attach=-1 and passed. Never again:
    # if the victim is not dumpable, the measurement is void and says so.
    bad "(6) the victim was NOT dumpable, so a refusal here would not be Yama's -- the measurement is void: $PLINE"
elif printf '%s' "$PLINE" | grep -q 'attach=-1'; then
    ok "(6) and the SAME binary that attached on the host is REFUSED inside the boot: $PLINE"
else
    bad "(6) a same-uid sibling PTRACE_ATTACH SUCCEEDED inside the booted machine: $PLINE"
fi

echo "[ptracegate] ================================================"
echo "[ptracegate] PASS $PASS  FAIL $FAIL   (console log: $B)"
[ "$FAIL" = 0 ] || exit 1
exit 0
