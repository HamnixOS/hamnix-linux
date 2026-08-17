#!/usr/bin/env bash
# tests/linux/wedge_hunt.sh — DOES THE MACHINE STOP ANSWERING AFTER A FEW
# MINUTES ON A SLOW STICK, AND IF IT DOES, IS THE BOOT LOG WHY?
#
# THE REPORT THIS GATE EXISTS FOR
# ===============================
# The owner booted his Lenovo to the graphical desktop from a physical USB
# stick, used it, and AFTER ABOUT FIVE MINUTES THE WHOLE SYSTEM HUNG. Magic
# sysrq still answered, so the KERNEL WAS ALIVE and USERSPACE WAS WEDGED. He
# has no serial cable and no shell; there is no log from that boot.
#
# The leading suspicion was our own most recent code: user/bootlogd.ad
# snapshots the whole kernel ring onto the FAT ESP EVERY TWO SECONDS, and every
# write is O_SYNC. In a VM the ESP is a host file and O_SYNC costs nothing. ON A
# PHYSICAL STICK it is a synchronous transfer through a flash translation layer
# that rewrites the same 256 KiB region 150 times in five minutes, ON THE SAME
# DEVICE THE ROOT FILESYSTEM IS ON. Everything else userspace does -- exec a
# program, fault a page of an evicted binary back in, open a config file --
# queues behind it.
#
# A VM CANNOT REPRODUCE SLOW FLASH BY WISHING. So the medium is made slow ON
# PURPOSE: QEMU's `throttling.iops-write` / `throttling.bps-write` on the
# usb-storage drive is the honest way to say "this stick completes N write
# operations a second". WRITES ONLY ARE THROTTLED -- reads are left alone, so
# any read stall this gate sees is a read QUEUED BEHIND WRITES, which is the
# mechanism under test and not an artefact of the throttle.
#
# WHAT IS MEASURED, AND HOW A WEDGE IS SEEN AT ALL
# ================================================
# Two independent liveness probes, neither of which can be satisfied by a
# kernel that is merely alive:
#
#   1. THE HEARTBEAT. The rc under test -- which sources the SHIPPED
#      etc/rc.boot.installed verbatim, bootlogd and all -- then loops: print a
#      marker, print the guest's own clock, and RUN A PROGRAM OFF THE DISK
#      (`ls /etc`). That last part is deliberate: `echo` from an already
#      resident shell would keep ticking through a total I/O stall, and the
#      thing being hunted is exactly an I/O stall. THE GAP BETWEEN CONSECUTIVE
#      GUEST TIMESTAMPS IS THE MEASUREMENT -- read out of the serial log after
#      the fact, in the GUEST's own clock, so no host-side polling artefact and
#      no scheduling of this script can invent or hide a stall. The host also
#      samples the heartbeat count live, but only so a long run says something
#      while it is happening; the verdict comes from the guest's clock.
#
#   2. THE SCREEN. `screendump` through the QEMU monitor, every few seconds,
#      hashed. The monitor is host-side and answers even when the guest is
#      wedged, so this asks the question the owner actually asked: DID THE
#      PICTURE STOP CHANGING? An idle hamnix desktop repaints constantly (the
#      panel's clock and its system-monitor graph), so a run of identical
#      frames is a frozen desktop and not a quiet one.
#
# and one direct measurement of the accused: `info blockstats` off the same
# monitor gives wr_bytes and wr_operations FOR THE STICK, so "bootlogd is
# writing X KiB/s to the medium" stops being an argument and becomes a number.
#
# THE INSTRUMENT IS PROVED BEFORE ANY VERDICT IS BELIEVED
# ======================================================
# A desktop that "did not hang" proves nothing unless the harness can be shown
# to notice one. So the FIRST arm proves all three probes, in two halves,
# because no single stimulus can exercise them all:
#
#   * the GUEST-CLOCK probe is pure text over a serial log, and is proved on a
#     log with a planted 77 s hole -- and on one with no hole, so that a small
#     number later is a reading and not a floor. It has to be proved this way:
#     a halted vCPU has no clock, so the VM arm cannot make its timestamps
#     jump;
#   * the HEARTBEAT-SILENCE and SCREEN-FROZEN probes are proved on a real boot
#     halted for 60 s by the QEMU monitor's `stop` -- vCPUs stopped, QEMU still
#     answering, which is precisely the shape of the failure being hunted.
#
# If any of them does not fire, every later "no wedge" in this file is
# worthless, and the gate says so and stops rather than printing a reassuring
# number.
#
# THE A/B, AND WHY THE ARMS DIFFER IN ONE BYTE OF THE MEDIUM
# ==========================================================
# Arm A is the medium as it ships. Arm B is THE SAME MEDIUM with \HAMNIX.LOG
# deleted from the ESP -- which is bootlogd's documented failure path: it says
# "NO BOOT LOG", exits 0, and the boot carries on. Same kernel, same rc, same
# desktop, same throttle; the only difference is whether the two-second O_SYNC
# snapshot happens. Anything that separates A from B is bootlogd.
#
# Usage: tests/linux/wedge_hunt.sh
# Env:   HAMLINUX_WEDGE_WORK    where to build and boot
#        HAMLINUX_WEDGE_REUSE=1 reuse a medium already built there
#        HAMLINUX_WEDGE_SECS    seconds to watch each arm (default 360)
#        HAMLINUX_WEDGE_IOPS    write iops the stick is allowed (default 60)
#        HAMLINUX_WEDGE_BPS     write bytes/s the stick is allowed (default 1M)
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"
# FIRST, before reap.sh and before $WORK -- the contract in
# tests/linux/private_ns.sh. gates_are_private.sh checks that this line is here.
. tests/linux/private_ns.sh
priv_ns_reexec "$@"
. tests/linux/reap.sh

WORK="${HAMLINUX_WEDGE_WORK:-$HOME/.hamnix-build/wedge-hunt}"
mkdir -p "$WORK"
reap_track "$WORK/reaped"
reap_on_exit :

SECS="${HAMLINUX_WEDGE_SECS:-360}"
IOPS="${HAMLINUX_WEDGE_IOPS:-60}"
BPS="${HAMLINUX_WEDGE_BPS:-1048576}"
# How long a heartbeat may be missing before the machine is called wedged. The
# loop ticks about once a second; twenty is not a slow machine, it is a stopped
# one.
WEDGE_S=20
# ... and how long the picture may stand still. The panel repaints its clock
# and its CPU graph continuously, so this is generous by a wide margin.
FREEZE_S=45

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  PASS  %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$*"; }
say()  { printf '\n== %s\n' "$*"; }
info() { printf '  ..    %s\n' "$*"; }

export PATH="$PATH:/usr/sbin:/sbin"
for t in qemu-system-x86_64 mcopy mdel sgdisk socat; do
    command -v "$t" >/dev/null || { bad "need $t"; exit 1; }
done
[ -f /usr/share/OVMF/OVMF_CODE_4M.fd ] || { bad "need OVMF"; exit 1; }

MARK="WEDGEHUNTUP7741"
HB="WEDGEHB"

# THE rc UNDER TEST SOURCES THE SHIPPED ONE VERBATIM. A gate with an rc of its
# own would prove nothing about the file that ships on the stick.
#
# `while 1 == 1` rather than `while true`: a while condition is an EXPRESSION
# in hamsh (HAMSH_SPEC §8a), and `true` there is an identifier, not the
# program. A comparison of two literals cannot be misparsed.
#
# `ls /etc > /dev/null` is the load-bearing line. `echo` and the guest clock
# come out of a shell that is already resident in memory and would keep ticking
# straight through a total block-device stall; a fork+exec of a program off the
# root filesystem is what actually asks "can this machine still do anything?"
cat >"$WORK/rc.wedgehunt" <<RCEOF
source '/etc/rc.boot.installed'
echo '$MARK'
while 1 == 1 {
    echo '$HB'
    date
    ls /etc > /dev/null
    sleep 1
}
RCEOF

say "building the medium under test (the shipped rc, sourced verbatim)"
if [ "${HAMLINUX_WEDGE_REUSE:-0}" = 1 ] && [ -f "$WORK/medium.img" ]; then
    info "reusing $WORK/medium.img"
else
    # REBUILT EXPLICITLY. scripts/hamlinux_disk.sh rebuilds build/image/root
    # only when it is ABSENT, so every run after the first would otherwise
    # package whatever tree happened to be lying there -- the stale-artifact
    # false report tests/linux/boot_log.sh records paying for.
    info "rebuilding build/image/root so this gate cannot boot a stale tree"
    HAMLINUX_DISTRO_RO=1 scripts/hamlinux_image.sh >"$WORK/image.log" 2>&1 || {
        bad "image build"; tail -20 "$WORK/image.log"; exit 1; }
    HAMLINUX_DISK_RC="$WORK/rc.wedgehunt" \
        scripts/hamlinux_disk.sh "$WORK/medium.img" 3G >"$WORK/disk.log" 2>&1 || {
        bad "disk build"; tail -20 "$WORK/disk.log"; exit 1; }
fi

ESP_SECTOR=$(sgdisk -i 1 "$WORK/medium.img" | awk '/First sector/ {print $3}')
[[ "$ESP_SECTOR" =~ ^[0-9]+$ ]] || ESP_SECTOR=2048
ESP_OFF=$(( ESP_SECTOR * 512 ))
info "the ESP starts at sector $ESP_SECTOR (byte $ESP_OFF)"

# guest_max_gap <serial.log> -- the largest jump, in seconds, between two
# consecutive heartbeat timestamps THE GUEST ITSELF PRINTED. `date` emits
# `YYYY-MM-DD HH:MM:SS UTC`; the kernel's own bracketed printk timestamps are
# a different shape and are not matched. Prints 0 when there are fewer than
# two, which the caller must not read as "healthy" -- ARM_HB says whether
# there were any at all.
guest_max_gap() {
    python3 - "$1" <<'PY'
import re, sys, datetime
pat = re.compile(rb'(\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d) UTC')
ts = []
for m in pat.finditer(open(sys.argv[1], 'rb').read()):
    y, mo, d, h, mi, s = (int(x) for x in m.groups())
    ts.append(datetime.datetime(y, mo, d, h, mi, s).timestamp())
gap = 0
for a, b in zip(ts, ts[1:]):
    if b - a > gap:
        gap = b - a
print(int(gap))
PY
}

# ---------------------------------------------------------------------------
# run_arm <name> <img> <iops|0> <bps|0> <stopsecs|0>
#
# Boots the image as a throttled USB stick, watches it for $SECS, and leaves
# behind in $WORK/<name>/:
#   serial.log   the console
#   hb.tsv       host-clock seconds  ->  heartbeats seen so far
#   screens/     periodic screendumps
#   frames.tsv   host-clock seconds  ->  md5 of the frame
#   blk.tsv      host-clock seconds  ->  wr_bytes  wr_operations (the stick)
# and sets ARM_MAXGAP / ARM_FREEZE / ARM_HB / ARM_WRB / ARM_WROPS.
# ---------------------------------------------------------------------------
run_arm() {
    local name="$1" src="$2" aiops="$3" abps="$4" stopsecs="$5"
    local d="$WORK/$name"
    rm -rf "$d"; mkdir -p "$d/screens"
    cp "$src" "$d/medium.img"
    cp /usr/share/OVMF/OVMF_VARS_4M.fd "$d/OVMF_VARS.fd"

    local thr=""
    [ "$aiops" != 0 ] && thr="$thr,throttling.iops-write=$aiops"
    [ "$abps"  != 0 ] && thr="$thr,throttling.bps-write=$abps"

    qemu-system-x86_64 \
        -m 2048 -smp 2 -no-reboot \
        -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
        -drive "if=pflash,format=raw,unit=1,file=$d/OVMF_VARS.fd" \
        -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
        -display none -vga std \
        -serial "file:$d/serial.log" \
        -enable-kvm -cpu host \
        -monitor "unix:$d/mon.sock,server,nowait" \
        -device qemu-xhci,id=xhci -device usb-kbd -device usb-tablet \
        -drive "file=$d/medium.img,if=none,format=raw,id=usbstick$thr" \
        -device usb-storage,bus=xhci.0,drive=usbstick,bootindex=0 \
        >"$d/qemu.out" 2>&1 &
    local vm=$!
    reap_add "$vm"

    # Wait for the rc to finish before the clock starts, so the boot's own
    # slowness is not counted as a wedge. The boot itself is throttled too and
    # can take a while.
    local w=0
    while kill -0 "$vm" 2>/dev/null && [ "$w" -lt 420 ]; do
        grep -aq "$MARK" "$d/serial.log" 2>/dev/null && break
        sleep 2; w=$((w+2))
    done
    if ! grep -aq "$MARK" "$d/serial.log" 2>/dev/null; then
        bad "$name: the boot never reached the end of the rc in ${w}s"
        kill -KILL "$vm" 2>/dev/null; wait "$vm" 2>/dev/null
        return 1
    fi
    info "$name: the rc completed after ~${w}s; watching for ${SECS}s"

    : >"$d/hb.tsv"; : >"$d/frames.tsv"; : >"$d/blk.tsv"
    local t0 now el last_hb hb prev_md5="" i=0 stopped=0 STOP_AT=0
    t0=$(date +%s); last_hb=$t0
    ARM_MAXGAP=0; ARM_FREEZE=0; ARM_HB=0
    local freeze_start=0
    while :; do
        now=$(date +%s); el=$(( now - t0 ))
        [ "$el" -ge "$SECS" ] && break
        kill -0 "$vm" 2>/dev/null || { bad "$name: the VM died mid-run"; break; }

        # THE INSTRUMENT PROOF, when asked for: freeze the guest outright.
        #
        # The QEMU MONITOR's `stop`, and not SIGSTOP to the process. SIGSTOP
        # would freeze QEMU as well, so the monitor could not answer and the
        # SCREEN probe would take no samples at all during the very interval it
        # is supposed to notice -- it would come back to a changed frame and
        # report nothing. `stop` halts the vCPUs and leaves QEMU running, which
        # is exactly the shape of the failure being hunted: a machine that
        # stops producing output while something outside it can still look at
        # the picture.
        if [ "$stopsecs" != 0 ] && [ "$stopped" = 0 ] && [ "$el" -ge 30 ]; then
            info "$name: monitor 'stop' for ${stopsecs}s (instrument proof)"
            printf 'stop\n' | timeout 10 socat - "UNIX-CONNECT:$d/mon.sock" >/dev/null 2>&1
            stopped=1
            STOP_AT=$(date +%s)
        fi
        if [ "$stopped" = 1 ] && [ $(( now - STOP_AT )) -ge "$stopsecs" ]; then
            printf 'cont\n' | timeout 10 socat - "UNIX-CONNECT:$d/mon.sock" >/dev/null 2>&1
            info "$name: monitor 'cont'"
            stopped=2
        fi

        hb=$(grep -ac "$HB" "$d/serial.log" 2>/dev/null || echo 0)
        printf '%s\t%s\n' "$el" "$hb" >>"$d/hb.tsv"
        if [ "${hb:-0}" -gt "${ARM_HB:-0}" ]; then ARM_HB="$hb"; last_hb=$now; fi
        local gap=$(( now - last_hb ))
        [ "$gap" -gt "$ARM_MAXGAP" ] && ARM_MAXGAP="$gap"

        # A frame every third pass, hashed.
        if [ $(( i % 3 )) = 0 ]; then
            local shot="$d/screens/f$(printf '%05d' "$el").ppm"
            printf 'screendump %s\n' "$shot" \
                | timeout 10 socat - "UNIX-CONNECT:$d/mon.sock" >/dev/null 2>&1
            if [ -s "$shot" ]; then
                local m; m=$(md5sum <"$shot" | cut -d' ' -f1)
                printf '%s\t%s\n' "$el" "$m" >>"$d/frames.tsv"
                if [ "$m" = "$prev_md5" ]; then
                    [ "$freeze_start" = 0 ] && freeze_start=$now
                    local fz=$(( now - freeze_start ))
                    [ "$fz" -gt "$ARM_FREEZE" ] && ARM_FREEZE="$fz"
                else
                    freeze_start=0
                fi
                prev_md5="$m"
                # Keep only a handful: a 6-minute run at 3 s is 120 frames of
                # 5 MB. Every third one is kept for a human to look at.
                [ $(( el % 30 )) -ge 3 ] && rm -f "$shot"
            fi
            # ... and what the stick has actually been asked to write.
            printf 'info blockstats\n' \
                | timeout 10 socat - "UNIX-CONNECT:$d/mon.sock" 2>/dev/null \
                | awk -v el="$el" '/wr_bytes/ {print el "\t" $0}' >>"$d/blk.tsv"
        fi
        i=$(( i + 1 ))
        sleep 1
    done

    # The last word from the block layer, for the arm's totals.
    printf 'info blockstats\n' | timeout 10 socat - "UNIX-CONNECT:$d/mon.sock" \
        >"$d/blockstats.txt" 2>/dev/null
    # THE `usbstick:` LINE AND NOT THE FIRST ONE THAT MATCHES. `info
    # blockstats` reports every drive QEMU has, and the two pflash devices come
    # first with wr_bytes=0 -- so a parse that took the first match reported
    # that the medium had been written NOTHING, in a run whose whole subject is
    # how much it was written. That number was printed and believed for one
    # run; it is the shape of wrong this tree exists to stop.
    ARM_WRB=$(awk -F'wr_bytes=' '/^usbstick:/{split($2,a," ");print a[1];exit}' "$d/blockstats.txt")
    ARM_WROPS=$(awk -F'wr_operations=' '/^usbstick:/{split($2,a," ");print a[1];exit}' "$d/blockstats.txt")
    ARM_WRFL=$(awk -F'flush_operations=' '/^usbstick:/{split($2,a," ");print a[1];exit}' "$d/blockstats.txt")
    ARM_WRT=$(awk -F'wr_total_time_ns=' '/^usbstick:/{split($2,a," ");print a[1];exit}' "$d/blockstats.txt")
    ARM_WRB="${ARM_WRB:-0}"; ARM_WROPS="${ARM_WROPS:-0}"
    ARM_WRFL="${ARM_WRFL:-0}"; ARM_WRT="${ARM_WRT:-0}"

    kill -KILL "$vm" 2>/dev/null; wait "$vm" 2>/dev/null

    # THE VERDICT NUMBER, AND IT IS THE GUEST'S OWN CLOCK. Every heartbeat
    # carries a `date` line; the largest jump between two consecutive ones is
    # how long the machine stopped doing anything. Read after the fact off the
    # serial log, so nothing about how this script was scheduled can create a
    # gap or hide one.
    ARM_GUESTGAP=$(guest_max_gap "$d/serial.log")
    ARM_GAP="$ARM_GUESTGAP"
    [ "$ARM_MAXGAP" -gt "$ARM_GAP" ] && ARM_GAP="$ARM_MAXGAP"
    info "$name: heartbeats=$ARM_HB  longest gap in the GUEST's clock=${ARM_GUESTGAP}s  (host-observed ${ARM_MAXGAP}s)  longest frozen screen=${ARM_FREEZE}s"
    info "$name: the stick was written $ARM_WRB bytes in $ARM_WROPS operations and $ARM_WRFL cache flushes ($(( ARM_WRT / 1000000 )) ms inside write)"
    return 0
}

# ---------------------------------------------------------------------------
say "ARM 0 -- THE INSTRUMENT PROOF: can this harness see a wedge at all?"
# ---------------------------------------------------------------------------
# An unthrottled boot, deliberately frozen for 60 s by the host. If the probes
# below do not report roughly that, then nothing else in this file means
# anything, and it stops rather than printing a reassuring number.
# -- 0a, host-side and instant: does guest_max_gap find a hole that is there?
# A `stop`ped vCPU has no clock, so the VM arm below cannot exercise this half
# (that is what makes it the right proof for the OTHER two probes). This half
# is pure text over the serial log, so it is proved directly, on a log with a
# hole of a size nothing else in this file uses.
{
    printf 'WEDGEHB\n2026-01-01 00:00:00 UTC\n'
    printf 'WEDGEHB\n2026-01-01 00:00:01 UTC\n'
    printf 'WEDGEHB\n2026-01-01 00:01:18 UTC\n'
    printf 'WEDGEHB\n2026-01-01 00:01:19 UTC\n'
} >"$WORK/synthetic.log"
SYN=$(guest_max_gap "$WORK/synthetic.log")
[ "$SYN" = 77 ] \
    && ok "guest_max_gap finds a planted 77s hole in a serial log (it said ${SYN}s)" \
    || bad "guest_max_gap said ${SYN}s for a planted 77s hole -- the guest-clock probe is broken"
{ printf 'WEDGEHB\n2026-01-01 00:00:00 UTC\n'; printf 'WEDGEHB\n2026-01-01 00:00:01 UTC\n'; } >"$WORK/synthetic2.log"
SYN2=$(guest_max_gap "$WORK/synthetic2.log")
[ "$SYN2" = 1 ] \
    && ok "and reports 1s for a log with no hole, so a small number here is a real reading and not a floor" \
    || bad "guest_max_gap said ${SYN2}s for a clean log -- it cannot tell healthy from wedged"

# -- 0b, in the VM: do the heartbeat and screen probes see a machine stop?
PROOF_STOP=60
SAVED_SECS="$SECS"; SECS=150
run_arm proof "$WORK/medium.img" 0 0 "$PROOF_STOP"
SECS="$SAVED_SECS"
P_GAP="$ARM_MAXGAP"; P_FRZ="$ARM_FREEZE"
[ "${ARM_HB:-0}" -gt 20 ] \
    && ok "the proof arm produced $ARM_HB heartbeats, so the probe emits something that could go missing" \
    || bad "the proof arm produced only ${ARM_HB:-0} heartbeats -- the probe is not running"
if [ "$P_GAP" -ge $(( PROOF_STOP - 15 )) ]; then
    ok "the heartbeat probe SAW a ${PROOF_STOP}s stop (it reported ${P_GAP}s), so a silent heartbeat below is a real observation"
else
    bad "the heartbeat probe reported only ${P_GAP}s for a ${PROOF_STOP}s stop -- THIS HARNESS IS BLIND and no result below can be believed"
fi
if [ "$P_FRZ" -ge $(( PROOF_STOP - 20 )) ]; then
    ok "the screen probe SAW the same stop (${P_FRZ}s of identical frames), so an unchanging desktop below is a real observation"
else
    bad "the screen probe reported only ${P_FRZ}s of frozen frames for a ${PROOF_STOP}s stop -- the picture check is blind"
fi
[ "$FAIL" = 0 ] || { printf '\n%d PASSED, %d FAILED\n' "$PASS" "$FAIL"; exit 1; }

# ---------------------------------------------------------------------------
say "ARM A -- the medium AS IT SHIPS, on a stick throttled to ${IOPS} write iops / ${BPS} B/s"
# ---------------------------------------------------------------------------
ARM_HB=0
run_arm slow_log "$WORK/medium.img" "$IOPS" "$BPS" 0
A_GAP="$ARM_GAP"; A_FRZ="$ARM_FREEZE"; A_HB="$ARM_HB"
A_WRB="$ARM_WRB"; A_WROPS="$ARM_WROPS"; A_WRFL="$ARM_WRFL"

# ---------------------------------------------------------------------------
say "ARM B -- THE SAME MEDIUM with \\HAMNIX.LOG deleted, so bootlogd cannot run"
# ---------------------------------------------------------------------------
cp "$WORK/medium.img" "$WORK/nolog.img"
mdel -i "${WORK}/nolog.img@@${ESP_OFF}" "::/HAMNIX.LOG" 2>/dev/null
if mcopy -n -o -i "${WORK}/nolog.img@@${ESP_OFF}" "::/HAMNIX.LOG" /dev/null 2>/dev/null; then
    bad "the log file is still on the ESP after mdel -- arm B is not a control"
else
    ok "arm B's medium really has no \\HAMNIX.LOG (bootlogd will take its documented failure path)"
fi
ARM_HB=0
run_arm slow_nolog "$WORK/nolog.img" "$IOPS" "$BPS" 0
B_GAP="$ARM_GAP"; B_FRZ="$ARM_FREEZE"; B_HB="$ARM_HB"
B_WRB="$ARM_WRB"; B_WROPS="$ARM_WROPS"; B_WRFL="$ARM_WRFL"

grep -aq 'NO BOOT LOG' "$WORK/slow_nolog/serial.log" \
    && ok "arm B's bootlogd said NO BOOT LOG and the boot carried on, so the control is the one intended" \
    || bad "arm B does not show bootlogd's refusal -- the control may not be what it claims"

# ---------------------------------------------------------------------------
say "WHAT THE STICK WAS ASKED TO WRITE"
# ---------------------------------------------------------------------------
info "arm A (bootlogd running):     $A_WRB bytes, $A_WROPS write operations, $A_WRFL flushes over ${SECS}s"
info "arm B (bootlogd not running): $B_WRB bytes, $B_WROPS write operations, $B_WRFL flushes over ${SECS}s"
info "bootlogd's share: $(( A_WRB - B_WRB )) bytes, $(( A_WROPS - B_WROPS )) operations, $(( A_WRFL - B_WRFL )) flushes"

# THE BUDGET, AND WHY IT IS EXPRESSED IN FLUSHES.
#
# A cache flush is what a USB stick's controller cannot pipeline: it has to
# commit its flash translation layer before it answers. Bytes it can buffer;
# flushes it cannot. So the number that decides whether a logger is a burden on
# a boot medium is how often it makes the device commit, and that is asserted
# here rather than left as a remark.
#
# MEASURED AT THE HEAD THIS GATE WAS WRITTEN AGAINST, 360 s, 60 write iops:
# arm A 52,568,576 bytes / 2731 ops / 1219 flushes, arm B 37,347,840 / 407 / 76.
# bootlogd alone was +15.2 MB, +2324 operations and +1143 FLUSHES -- 3.2 device
# commits a second, for ever, on a machine that had nothing new to say. That is
# the seven O_SYNC write(2) calls the old snapshot() made every two seconds,
# and it made them whether or not one byte of the ring had changed.
#
# 120 over the window is one flush every three seconds and is deliberately
# loose: it is a budget, not a fit to the current number. A logger that
# persists something new is meant to flush.
BUDGET_FL=120
if [ $(( A_WRFL - B_WRFL )) -le "$BUDGET_FL" ]; then
    ok "bootlogd cost $(( A_WRFL - B_WRFL )) cache flushes over ${SECS}s, within the budget of $BUDGET_FL"
else
    bad "BOOTLOGD MADE THE BOOT MEDIUM COMMIT $(( A_WRFL - B_WRFL )) TIMES in ${SECS}s (budget $BUDGET_FL): a diagnostic is a standing load on the stick it is diagnosing"
fi

# AND THE OTHER WRITER, WHICH THIS GATE FOUND BY ACCIDENT AND WHICH IS NOT
# BOOTLOGD. Arm B has no logger at all and still wrote 37 MB in six minutes --
# about 100 KB/s from an idle desktop, in few, large, rarely-flushed
# operations, which is the signature of ordinary ext4 writeback rather than of
# anything synchronous. It is recorded here so that the number is watched; it
# is NOT yet attributed, and this gate does not pretend to know what it is.
info "arm B is the floor: an idle desktop with NO logger still wrote $B_WRB bytes to its boot medium in ${SECS}s"

# ---------------------------------------------------------------------------
say "DID ANYTHING WEDGE?"
# ---------------------------------------------------------------------------
info "arm A: heartbeats=$A_HB longest gap=${A_GAP}s longest frozen screen=${A_FRZ}s"
info "arm B: heartbeats=$B_HB longest gap=${B_GAP}s longest frozen screen=${B_FRZ}s"

if [ "$A_GAP" -lt "$WEDGE_S" ]; then
    ok "arm A: userspace never went quiet for as long as ${WEDGE_S}s"
else
    bad "arm A: USERSPACE WENT SILENT FOR ${A_GAP}s -- a wedge, with bootlogd running"
fi
if [ "$A_FRZ" -lt "$FREEZE_S" ]; then
    ok "arm A: the picture never stood still for as long as ${FREEZE_S}s"
else
    bad "arm A: THE SCREEN WAS FROZEN FOR ${A_FRZ}s -- with bootlogd running"
fi
if [ "$B_GAP" -lt "$WEDGE_S" ]; then
    ok "arm B: userspace never went quiet for as long as ${WEDGE_S}s"
else
    bad "arm B: userspace went silent for ${B_GAP}s WITHOUT bootlogd -- the cause is elsewhere"
fi

printf '\n%d PASSED, %d FAILED\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
