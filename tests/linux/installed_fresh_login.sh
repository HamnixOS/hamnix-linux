#!/usr/bin/env bash
#
# tests/linux/installed_fresh_login.sh — DOES A MACHINE THE INSTALLER JUST
# BUILT ASK WHO YOU ARE? Nobody had ever run the installer against the login
# work; every measurement of the guard so far was made on a disk whose
# /etc/rc.boot the GATE wrote.
#
# REGISTRATION. ON-DEMAND: not in ci_battery_manifest.txt because it builds a
# medium, runs THREE installs and boots the result twice. Same class as
# tests/linux/installed_accounts.sh, whose install machinery this borrows, and
# tests/linux/installed_boot_login.sh, whose driver, patterns and root
# detector this reuses deliberately -- an instrument that has already been
# shown to see a root shell is worth more than a new one.
#
# ================================================================
# THE DEFECT, AND WHY IT IS THE SHAPE THIS PROJECT KEEPS PAYING FOR
# ================================================================
# user/hlinstall.ad:write_machine_rc_boot copies /etc/rc.boot.machine onto the
# target as its /etc/rc.boot. That file carries the guard:
#
#     source '/etc/rc.boot.installed'
#     source '/etc/rc.login'          <- a login program on every terminal
#     supervise                       <- never returns, so PID 1 never
#                                        falls through to its own uid 0 prompt
#
# WHEN THE COPY FAILED, the fallback branch wrote a rc containing ONE line --
# `source '/etc/rc.boot.installed'` -- and RETURNED 0. An image that does not
# carry rc.boot.machine therefore installed a machine with no login program on
# any terminal and an unauthenticated root shell on the console, and the
# installer printed "install complete" over it. A GAP ANSWERING SOMETHING
# SUCCESS-SHAPED.
#
# ================================================================
# WHAT THIS GATE MEASURES, IN ORDER, AND WHAT IS A CONTROL
# ================================================================
# ONE medium boot performs FOUR installs onto FOUR blank disks, so the only
# variable between them is what the medium carried at the moment of the
# install. The medium's rc deletes (and, once, restores) a guard file between
# installs; nothing else differs -- same installer binary, same arguments,
# same disk geometry apart from the per-arm --esp-mb stamp described below.
#
# WHICH DISK IS WHICH IS MEASURED, NOT ASSUMED, and section 0b is the whole
# reason this gate was rewritten on 2026-08-20. It used to hand qemu three
# images in arm order and read them back in arm order, which silently assumes
# the guest enumerates NVMe namespaces in qemu -device order. It did not. The
# gate scored arm C's correctly-REFUSED disk as arm A's shipped install,
# reported the shipped install path as broken, and a release was refused on
# that reading. Each arm now stamps its disk with a distinct ESP size at
# partitioning time -- step 1 of 5, so the stamp survives a refusal -- and the
# host maps stamp -> arm and asserts the mapping is a bijection before it
# scores anything.
#
#   A 'shipped'    the medium carries /etc/rc.boot.machine AND /etc/rc.login,
#                  as it does today. The target's /etc/rc.boot must carry both
#                  guard lines and /etc/rc.login must be on the disk. This is
#                  also the CONTROL for arms C and D: it must SUCCEED and must
#                  print "install complete", or their refusals prove nothing.
#   D 'nologin'    /etc/rc.login deleted but rc.boot.machine KEPT, so the
#                  SHIPPED branch runs and the rc it copies names a file the
#                  target cannot get. Until 2026-08-20 that branch returned 0
#                  without looking and this install SUCCEEDED, producing a
#                  machine with no login program on any terminal. It must now
#                  FAIL LOUDLY. Nothing had ever run this configuration --
#                  the guard lived only on the fallback branch below, which is
#                  the branch almost nobody takes.
#   B 'nomachine'  /etc/rc.login restored, /etc/rc.boot.machine deleted, so the FALLBACK BRANCH
#                  runs. The target's /etc/rc.boot must STILL carry both guard
#                  lines. This is the arm the fix exists for; before the fix
#                  this disk would boot straight to a root prompt.
#   C 'noguard'    rc.boot.machine AND /etc/rc.login both deleted, so the
#                  installer CANNOT produce a machine that asks. It must FAIL
#                  LOUDLY: no "install complete", and its refusal on the wire.
#                  A missing guard must never be answered by a successful
#                  install.
#
# Then the disk from arm A is booted and driven over serial. ITS /etc/rc.boot
# IS THE INSTALLER'S OWN BYTES, asserted by comparison, and EXACTLY ONE file is
# added to a copy of the disk before it boots: /etc/rc.runlevel, asking for
# runlevel 3. Section 2 says at length why -- in short, at runlevel 5 the boot
# rc's own last two lines never run, so there is no terminal login to measure:
#
#   * the console must present `login: ` (anchored: `rc.login: getty started
#     on /dev/ttyS0` CONTAINS the substring `login:` and an unanchored grep
#     would go green on the rc merely SAYING it started one);
#   * two probes offered BEFORE any credential -- `id`, and a typed redirect
#     -- must produce no root identity;
#   * a real account's WRONG password must be refused;
#   * its RIGHT password must admit, and the session must answer `id` with the
#     uid the installer gave it.
#
# THE CONTROL RUNS, and it is a second boot of a COPY of that same disk with
# one thing changed: /etc/rc.boot replaced by the same rc with `-a hostowner`
# on the getty. `login -f` deliberately does not setuid, so it keeps PID 1's
# root and that arm MUST reach a root shell with no password. It proves the
# driver, the port, the patterns and the root detector can SEE a root shell,
# which is the only thing that makes arm A's silence mean anything. `-a` is
# not a straw man: it is the shape etc/rc.boot.full ships on the live medium.
#
# THE ROOT DETECTOR IS NOT `uid=0(`. user/id.ad prints `uid=<n>(<name>)` only
# when it resolves the number in /etc/passwd, and an installed disk has NO
# uid 0 entry (its administrative account is `hostowner`, at uid 1). A real
# root shell here answers `uid=0 gid=0` with no parentheses.
#
# WHAT THIS GATE DOES NOT MEASURE: the virtual terminals (/dev/tty2, tty3).
# /etc/rc.login starts a getty on each, and once wsysd presents it owns the
# framebuffer, so nothing on this machine can read tty2 back.
#
# Usage: tests/linux/installed_fresh_login.sh
#   FRESHLOGIN_WORK=<dir>   work dir (default ~/.hamnix-build/instfreshlogin)
#   FRESHLOGIN_REUSE=1      reuse an already-built medium and installed disks
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

. tests/linux/reap.sh
reap_on_exit

W="${FRESHLOGIN_WORK:-$HOME/.hamnix-build/instfreshlogin}"
mkdir -p "$W"
export TMPDIR="$W/tmp"; mkdir -p "$TMPDIR"

LIVE="$W/live-usb.img"
USERNAME=hamfreshusr
HOSTNAME_=hamfresh
UPASS=hamfreshpw
WRONGPASS=hamfreshNOPE
RPASS=hamfreshadmin

# THE ARM STAMP. Each arm asks the installer for a DIFFERENT ESP size, and
# nothing else about the four installs differs in geometry. The host reads the
# ESP size straight out of each image's partition table afterwards and that is
# how it knows which disk an arm wrote -- see "0b". They must stay distinct
# and >= 64 (hlinstall clamps below that).
ESP_A=512
ESP_D=520
ESP_B=528
ESP_C=536

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

# The detectors, defined once, taken verbatim from
# tests/linux/installed_boot_login.sh so the arm that proves one fires and the
# arm whose result depends on it NOT firing cannot drift apart.
has_root_identity()   { grep -aqE 'uid=0([^0-9]|$)' "$1"; }
root_identity_lines() { grep -aE  'uid=0([^0-9]|$)' "$1"; }
has_uid()             { grep -aqE "uid=$2([^0-9]|\$)" "$1"; }

part_geom() {
    /sbin/sfdisk -J "$1" 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)["partitiontable"]
ss=d.get("sectorsize",512)
p=d["partitions"][int(sys.argv[1])-1]
print(p["start"]*ss, p["size"]*ss)' "$2"
}
carve() {   # carve <disk> <partno> <out>
    local g off sz
    g="$(part_geom "$1" "$2")" || return 1
    [ -n "$g" ] || return 1
    off="${g% *}"; sz="${g#* }"
    rm -f "$3"
    dd if="$1" of="$3" bs=1M skip=$((off / 1048576)) \
       count=$(( (sz + 1048575) / 1048576 )) status=none
}

# =========================================================================
say "0 -- the medium, and ONE boot that performs FOUR installs"

# THE MEDIUM'S OWN rc. THE ONLY THING THAT DIFFERS BETWEEN THE FOUR INSTALLS
# IS WHICH OF THE TWO GUARD FILES IS ON THE MEDIUM AT THE TIME. Order matters
# and is deliberate; /etc/rc.login is stashed OUTSIDE /etc first so arm B can
# have it back after arm D has taken it away (a stash under /etc would be
# copied onto every target and pollute what this gate then reads).
#
# EACH ARM GETS ITS OWN --esp-mb, AND THAT IS NOT COSMETIC. It is how the host
# tells the four disks apart afterwards; see "0b" below for the defect that
# cost this project a refused release.
cat >"$W/rc.install" <<RCEOF
ln -s /dev/console /dev/cons
echo 'FRESHLOGIN-LIVE: the medium booted'
cp /etc/rc.login /tmp/rc.login.stash
ls /tmp/rc.login.stash
echo 'FRESHLOGIN-stash-status' \$status

# --- ARM A: the medium exactly as it ships ---------------------------
ls /etc/rc.boot.machine
echo 'FRESHLOGIN-A-machine-present-status' \$status
ls /etc/rc.login
echo 'FRESHLOGIN-A-login-present-status' \$status
echo 'FRESHLOGIN-A-BEGIN'
install --auto /dev/nvme0n1 --esp-mb $ESP_A --hostname $HOSTNAME_-a --user $USERNAME --user-pass $UPASS --root-pass $RPASS
echo 'FRESHLOGIN-A-status' \$status
echo 'FRESHLOGIN-A-END'

# --- ARM D: THE SHIPPED BRANCH WITH NO LOGIN TO SHIP -----------------
# /etc/rc.boot.machine is still here, so write_machine_rc_boot takes the
# branch every real install takes -- and /etc/rc.login is gone, so the file
# that rc.boot.machine names cannot reach the target. Until 2026-08-20 that
# branch returned 0 without looking, and this install would have SUCCEEDED
# while producing a machine with no login program on any terminal.
rm /etc/rc.login
ls /etc/rc.boot.machine
echo 'FRESHLOGIN-D-machine-present-status' \$status
ls /etc/rc.login
echo 'FRESHLOGIN-D-login-present-status' \$status
echo 'FRESHLOGIN-D-BEGIN'
install --auto /dev/nvme1n1 --esp-mb $ESP_D --hostname $HOSTNAME_-d --user $USERNAME --user-pass $UPASS --root-pass $RPASS
echo 'FRESHLOGIN-D-status' \$status
echo 'FRESHLOGIN-D-END'

# --- ARM B: the fallback branch. rc.login is back; rc.boot.machine goes.
cp /tmp/rc.login.stash /etc/rc.login
rm /etc/rc.boot.machine
ls /etc/rc.boot.machine
echo 'FRESHLOGIN-B-machine-present-status' \$status
ls /etc/rc.login
echo 'FRESHLOGIN-B-login-present-status' \$status
echo 'FRESHLOGIN-B-BEGIN'
install --auto /dev/nvme2n1 --esp-mb $ESP_B --hostname $HOSTNAME_-b --user $USERNAME --user-pass $UPASS --root-pass $RPASS
echo 'FRESHLOGIN-B-status' \$status
echo 'FRESHLOGIN-B-END'

# --- ARM C: no guard is producible at all. The install MUST refuse. --
rm /etc/rc.login
ls /etc/rc.login
echo 'FRESHLOGIN-C-login-present-status' \$status
echo 'FRESHLOGIN-C-BEGIN'
install --auto /dev/nvme3n1 --esp-mb $ESP_C --hostname $HOSTNAME_-c --user $USERNAME --user-pass $UPASS --root-pass $RPASS
echo 'FRESHLOGIN-C-status' \$status
echo 'FRESHLOGIN-C-END'

echo 'FRESHLOGIN-LIVE-DONE'
sleep 8
poweroff
RCEOF

# THE HOST IMAGE FILES ARE NAMED BY THEIR qemu SLOT, NOT BY AN ARM, and that
# is the whole point. The previous names -- target-a/-b/-c -- ASSERTED a
# mapping from qemu -device order to the guest's /dev/nvmeNn1 enumeration that
# nothing had ever checked, and on this host it is not the mapping: measured
# 2026-08-20, the guest's nvme0n1/nvme1n1/nvme2n1 were qemu's slots 2, 3 and 1.
# Section 0b resolves slot -> arm from what is written ON each disk.
SLOT1="$W/slot1.img"; SLOT2="$W/slot2.img"
SLOT3="$W/slot3.img"; SLOT4="$W/slot4.img"
SLOTS="$SLOT1 $SLOT2 $SLOT3 $SLOT4"

if [ "${FRESHLOGIN_REUSE:-0}" = 1 ] && [ -s "$LIVE" ] && [ -s "$SLOT1" ]; then
    info "reusing $LIVE and the four targets (FRESHLOGIN_REUSE=1)"
else
    info "building the medium (this is the slow part)"
    scripts/hamlinux_image.sh >"$W/img1.log" 2>&1 || {
        bad "lean image build -- see $W/img1.log"; finish; }
    scripts/hamlinux_disk.sh "$W/seed.img" 3G >"$W/disk1.log" 2>&1 || {
        bad "seed disk build -- see $W/disk1.log"; finish; }
    HAMLINUX_INSTALLER=1 scripts/hamlinux_image.sh >"$W/img2.log" 2>&1 || {
        bad "installer image build -- see $W/img2.log"; finish; }
    grep -q 'INCOMPLETE' "$W/img2.log" && \
        bad "the medium's /usr/lib/instroot is INCOMPLETE -- see $W/img2.log"
    HAMLINUX_DISK_RC="$W/rc.install" \
        scripts/hamlinux_disk.sh "$LIVE" 4G >"$W/disk2.log" 2>&1 || {
        bad "live medium build -- see $W/disk2.log"; finish; }

    for f in $SLOTS; do
        rm -f "$f"; truncate -s 6G "$f"
    done
    blank=1
    for f in $SLOTS; do
        [ "$(head -c 1048576 "$f" | tr -d '\0' | wc -c)" = 0 ] || blank=0
    done
    if [ "$blank" = 1 ]; then
        ok "all four targets are all zeroes before the install"
    else
        bad "a target is not blank"
    fi
fi
[ -s "$LIVE" ] || { bad "no live medium at $LIVE"; finish; }

# THE MEDIUM ITSELF MUST CARRY /etc/rc.boot.machine, or arm A is not the
# shipped configuration and arm B is not a contrast with anything. Checked
# on the HOST, off the medium's own filesystem, before any boot.
if carve "$LIVE" 2 "$W/livepart.img" 2>/dev/null && \
   /sbin/debugfs -R "stat /etc/rc.boot.machine" "$W/livepart.img" 2>/dev/null | grep -q '^Inode:'; then
    ok "the medium's own filesystem carries /etc/rc.boot.machine (so arm A is the shipped configuration)"
else
    info "could not read /etc/rc.boot.machine off the medium's partition 2; the in-guest \`ls\` in arm A is the authority instead"
fi

# ---- the install boot ----------------------------------------------------
if [ "${FRESHLOGIN_REUSE:-0}" != 1 ] || [ ! -s "$W/install/serial.log" ]; then
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
        -drive "file=$SLOT1,if=none,format=raw,id=nvme0" \
        -device nvme,drive=nvme0,serial=FRESHSLOT1 \
        -drive "file=$SLOT2,if=none,format=raw,id=nvme1" \
        -device nvme,drive=nvme1,serial=FRESHSLOT2 \
        -drive "file=$SLOT3,if=none,format=raw,id=nvme2" \
        -device nvme,drive=nvme2,serial=FRESHSLOT3 \
        -drive "file=$SLOT4,if=none,format=raw,id=nvme3" \
        -device nvme,drive=nvme3,serial=FRESHSLOT4 \
        -drive "file=$LIVE,if=none,format=raw,id=usbstick" \
        -device usb-storage,bus=xhci.0,drive=usbstick,bootindex=0 \
        >"$d/qemu.out" 2>&1 &
    IPID=$!
    reap_add "$IPID"
    i=0
    while kill -0 "$IPID" 2>/dev/null && [ "$i" -lt 1500 ]; do sleep 5; i=$((i+5)); done
    kill -TERM "$IPID" 2>/dev/null; sleep 2; kill -KILL "$IPID" 2>/dev/null
    wait "$IPID" 2>/dev/null
fi
ILOG="$W/install/serial.log"
tr -d '\r' <"$ILOG" >"$W/install/serial.txt" 2>/dev/null
IS="$W/install/serial.txt"
if grep -aq 'FRESHLOGIN-LIVE-DONE' "$IS"; then
    ok "the medium booted and ran all four installs to completion"
else
    bad "the install boot never printed FRESHLOGIN-LIVE-DONE -- nothing below is a statement about an installed machine"
    tail -30 "$IS" 2>/dev/null | sed 's/^/        /'
    finish
fi

istat() { sed -n "s/^FRESHLOGIN-$1-status //p" "$IS" | head -1; }

# =========================================================================
say "0b -- WHICH HOST IMAGE DID EACH ARM ACTUALLY INSTALL ONTO?"

# THE DEFECT THIS SECTION EXISTS TO CLOSE, AND IT COST A RELEASE.
#
# This gate used to name its three images target-a/-b/-c, hand them to qemu in
# that order, and then read them back as though the guest's /dev/nvme0n1 were
# qemu's first -device. NOTHING EVER CHECKED THAT. On the 1.0.33 candidate run
# it was false: the guest enumerated the namespaces rotated, so the disk the
# gate scored as "[a] shipped" was the disk arm C -- THE ARM THAT DELETES
# /etc/rc.login AND MUST REFUSE -- had installed onto. Every symptom the gate
# then reported was true of a correctly refused install and of nothing else:
# no /etc/rc.login, an /etc/passwd still at the medium's byte count so no user
# to log in as, and an 888-byte fallback rc written moments before the refusal.
# The release was refused on that reading. THE SHIPPED INSTALL PATH WAS FINE.
#
# So the mapping is now MEASURED, off each disk, from something the installer
# wrote there: the ESP SIZE each arm asked for with --esp-mb. Partitioning is
# step 1/5, so the stamp is present even on a disk whose install later refused
# -- which /etc/hostname is not, because a refusal happens before
# configure_target ever sets it.
esp_mb_of() {   # esp_mb_of <image> -> ESP size in MiB, or "" if unreadable
    /sbin/sfdisk -J "$1" 2>/dev/null | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)["partitiontable"]
except Exception:
    sys.exit(0)
ss=d.get("sectorsize",512)
ps=d.get("partitions") or []
if not ps: sys.exit(0)
print((ps[0]["size"]*ss)//1048576)'
}
hostname_of() { # hostname_of <root-partition-image> -> contents of /etc/hostname
    local t="$W/.hn.$$"
    rm -f "$t"
    /sbin/debugfs -R "dump /etc/hostname $t" "$1" >/dev/null 2>&1
    tr -d '\r\n' <"$t" 2>/dev/null
    rm -f "$t"
}

DISK_A=""; DISK_D=""; DISK_B=""; DISK_C=""
STAMPS=""
for f in $SLOTS; do
    m="$(esp_mb_of "$f")"
    info "  $(basename "$f"): ESP $([ -n "$m" ] && echo "$m MiB" || echo '(no readable partition table)')"
    STAMPS="$STAMPS $m"
    case "$m" in
        "$ESP_A") [ -z "$DISK_A" ] && DISK_A="$f" || DISK_A="AMBIGUOUS" ;;
        "$ESP_D") [ -z "$DISK_D" ] && DISK_D="$f" || DISK_D="AMBIGUOUS" ;;
        "$ESP_B") [ -z "$DISK_B" ] && DISK_B="$f" || DISK_B="AMBIGUOUS" ;;
        "$ESP_C") [ -z "$DISK_C" ] && DISK_C="$f" || DISK_C="AMBIGUOUS" ;;
    esac
done

# A BIJECTION OR NOTHING. If any arm's disk is missing or claimed twice, this
# gate cannot say which disk it is looking at, and a gate that cannot say that
# must not score anything -- that is exactly the mistake being fixed.
map_ok=1
for pair in "A:$DISK_A" "D:$DISK_D" "B:$DISK_B" "C:$DISK_C"; do
    a="${pair%%:*}"; v="${pair#*:}"
    if [ -z "$v" ]; then
        bad "[$a] no host image carries arm $a's ESP stamp -- the arm/disk mapping is broken"
        map_ok=0
    elif [ "$v" = AMBIGUOUS ]; then
        bad "[$a] more than one host image carries arm $a's ESP stamp -- the stamp is not unique"
        map_ok=0
    fi
done
if [ "$map_ok" = 1 ]; then
    ok "each of the four arms is identified with exactly one host image by its ESP stamp (a bijection)"
    info "  A -> $(basename "$DISK_A")   D -> $(basename "$DISK_D")   B -> $(basename "$DISK_B")   C -> $(basename "$DISK_C")"
else
    info "  stamps read:$STAMPS ; wanted $ESP_A/$ESP_D/$ESP_B/$ESP_C"
    finish
fi

# THE STAMP'S OWN CONTROL, and it is the one that would have caught the
# original defect: the stamp must actually DISCRIMINATE. If the four disks all
# reported the same ESP size the loop above would have said AMBIGUOUS, but a
# stamp that is unique and yet not positional is the interesting case -- so
# say out loud whether the guest enumerated the slots in qemu's order.
if [ "$DISK_A" = "$SLOT1" ] && [ "$DISK_D" = "$SLOT2" ] && \
   [ "$DISK_B" = "$SLOT3" ] && [ "$DISK_C" = "$SLOT4" ]; then
    info "  the guest DID enumerate the namespaces in qemu -device order this time"
    info "  (that is a fact about this run, not a property -- it was false on 2026-08-20)"
else
    info "  THE GUEST DID NOT ENUMERATE THE NAMESPACES IN qemu -device ORDER."
    info "  Reading these disks by position would have scored the wrong arms."
fi

# SECOND, INDEPENDENT IDENTIFIER, for the two arms that get far enough to have
# one. /etc/hostname is written by configure_target, which only runs on an
# install that did not refuse; the ESP stamp and the hostname are produced by
# different steps of the installer, so agreeing is worth something.
for pair in "A:$DISK_A:$HOSTNAME_-a" "B:$DISK_B:$HOSTNAME_-b"; do
    a="$(echo "$pair" | cut -d: -f1)"; v="$(echo "$pair" | cut -d: -f2)"
    want="$(echo "$pair" | cut -d: -f3)"
    if carve "$v" 2 "$W/.idpart.img" 2>/dev/null; then
        got="$(hostname_of "$W/.idpart.img")"
        if [ "$got" = "$want" ]; then
            ok "[$a] and the disk the ESP stamp picked carries /etc/hostname '$got' -- two independent identifiers agree"
        else
            bad "[$a] the ESP stamp and /etc/hostname disagree about this disk (hostname '$got', expected '$want')"
        fi
    else
        bad "[$a] cannot carve the root partition of the disk the ESP stamp picked"
    fi
done
rm -f "$W/.idpart.img"

TGT_A="$DISK_A"; TGT_D="$DISK_D"; TGT_B="$DISK_B"; TGT_C="$DISK_C"

# =========================================================================
say "1 -- WHAT EACH INSTALL WROTE AS THE MACHINE'S /etc/rc.boot"

# The reader's own control, both halves. Without these every presence and
# every absence below is worthless.
carve "$TGT_A" 2 "$W/part-a.img" || { bad "cannot carve arm A's root partition"; finish; }
if /sbin/debugfs -R "stat /etc/hamnix-release" "$W/part-a.img" 2>/dev/null | grep -q '^Inode:'; then
    ok "the ext4 reader finds a file that is certainly there (/etc/hamnix-release)"
else
    bad "the ext4 reader cannot find /etc/hamnix-release on the installed disk -- the instrument is not working"
    finish
fi
if /sbin/debugfs -R "stat /etc/there-is-no-such-file-as-this" "$W/part-a.img" 2>/dev/null | grep -q '^Inode:'; then
    bad "the ext4 reader reports a file that cannot exist -- every absence below is meaningless"
    finish
else
    ok "and it does NOT find a file that is certainly not there"
fi

# Score one installed disk's rc.
score_rc() {
    local arm="$1" img="$2" want="$3" label="$4"
    local p="$W/part-$arm.img" f="$W/rcboot-$arm.txt"
    carve "$img" 2 "$p" 2>/dev/null || {
        if [ "$want" = none ]; then
            ok "[$arm] $label: the disk has no readable root partition, which is consistent with an install that refused"
        else
            bad "[$arm] cannot carve the root partition of $img"
        fi
        return; }
    rm -f "$f"
    /sbin/debugfs -R "dump /etc/rc.boot $f" "$p" >/dev/null 2>&1
    if [ ! -s "$f" ]; then
        if [ "$want" = none ]; then
            ok "[$arm] $label: there is no /etc/rc.boot on this disk -- the install did not leave a bootable machine behind"
        else
            bad "[$arm] $label: no /etc/rc.boot was written at all"
        fi
        return
    fi
    info "[$arm] /etc/rc.boot is $(wc -c <"$f") bytes, $(grep -cve '^#' -e '^$' "$f") non-comment lines"
    info "[$arm]   $(grep -ve '^#' -e '^$' "$f" | tr '\n' ';' )"
    local has_installed=0 has_login=0 has_sup=0
    grep -q "^source '/etc/rc.boot.installed'" "$f" && has_installed=1
    grep -q "^source '/etc/rc.login'"          "$f" && has_login=1
    grep -q "^supervise"                       "$f" && has_sup=1
    if [ "$want" = none ]; then
        bad "[$arm] $label: a /etc/rc.boot WAS written by an install that must have refused"
        return
    fi
    if [ "$has_installed" = 1 ]; then
        ok "[$arm] $label: the rc sources /etc/rc.boot.installed (the package-owned rc a release can improve)"
    else
        bad "[$arm] $label: the rc does not source /etc/rc.boot.installed"
    fi
    if [ "$has_login" = 1 ]; then
        ok "[$arm] $label: THE GUARD, HALF ONE -- the rc sources /etc/rc.login, so a login program is started on every terminal"
    else
        bad "[$arm] $label: the rc does NOT source /etc/rc.login -- this machine starts no login program on any terminal"
    fi
    if [ "$has_sup" = 1 ]; then
        ok "[$arm] $label: THE GUARD, HALF TWO -- the rc ends in \`supervise\`, so PID 1 never falls off the end into its own uid 0 prompt"
    else
        bad "[$arm] $label: the rc does NOT end in \`supervise\` -- PID 1 will run out of script and present an unauthenticated root shell"
    fi
    # And /etc/rc.login must actually BE on the disk, or `source` is a no-op.
    if /sbin/debugfs -R "stat /etc/rc.login" "$p" 2>/dev/null | grep -q '^Inode:'; then
        ok "[$arm] $label: and /etc/rc.login is really on the disk, so the source line is not a no-op"
    else
        bad "[$arm] $label: /etc/rc.login is NOT on the disk -- the rc sources a file that is not there"
    fi
}

# WHAT A REFUSED INSTALL IS ALLOWED TO LEAVE BEHIND.
#
# A refusal happens at step 5 of 6, so the disk has already been partitioned,
# formatted and copied. This does NOT assert an untouched disk -- that would be
# asserting something the installer has never claimed and does not do. It
# asserts the thing that matters: whatever rc.boot is on that half-built disk,
# booting it must not drop anybody into an unauthenticated root prompt. Either
# there is no rc.boot at all, or the one that is there ends in `supervise`.
score_refused() {
    local arm="$1" img="$2" label="$3"
    local p="$W/part-$arm.img" f="$W/rcboot-$arm.txt"
    if ! carve "$img" 2 "$p" 2>/dev/null; then
        ok "[$arm] $label: the refused install left no readable root partition behind"
        return
    fi
    rm -f "$f"
    /sbin/debugfs -R "dump /etc/rc.boot $f" "$p" >/dev/null 2>&1
    if [ ! -s "$f" ]; then
        ok "[$arm] $label: the refused install left no /etc/rc.boot behind, so there is nothing to boot"
        return
    fi
    info "[$arm] the refused install left a $(wc -c <"$f")-byte /etc/rc.boot (steps 1-4 had already run)"
    if grep -q "^supervise" "$f"; then
        ok "[$arm] $label: and that rc still ends in \`supervise\`, so booting the half-built disk cannot fall through to an unauthenticated root prompt"
    else
        bad "[$arm] $label: the rc left behind does NOT end in \`supervise\` -- booting this refused install would present a root shell"
    fi
    if /sbin/debugfs -R "stat /etc/rc.login" "$p" 2>/dev/null | grep -q '^Inode:'; then
        bad "[$arm] $label: /etc/rc.login IS on this disk -- then the installer refused an install it could have guarded"
    else
        ok "[$arm] $label: and /etc/rc.login is genuinely absent, which is why the refusal was correct"
    fi
}

info "arm A installer exit status on the wire: '$(istat A)'"
info "arm D installer exit status on the wire: '$(istat D)'"
info "arm B installer exit status on the wire: '$(istat B)'"
info "arm C installer exit status on the wire: '$(istat C)'"

if [ "$(sed -n 's/^FRESHLOGIN-stash-status //p' "$IS" | head -1)" = 0 ]; then
    ok "the medium stashed /etc/rc.login outside /etc, so arm B can be given it back after arm D takes it away"
else
    bad "the rc.login stash failed -- arm B cannot be the fallback-WITH-a-login arm it claims to be"
fi

say "1a -- arm A 'shipped': the medium carried BOTH guard files"
if [ "$(sed -n 's/^FRESHLOGIN-A-machine-present-status //p' "$IS" | head -1)" = 0 ]; then
    ok "[A] the medium really did carry /etc/rc.boot.machine at the moment of this install"
else
    bad "[A] /etc/rc.boot.machine was NOT on the medium during arm A -- arm A is not the shipped configuration and arm B is a contrast with nothing"
fi
if [ "$(sed -n 's/^FRESHLOGIN-A-login-present-status //p' "$IS" | head -1)" = 0 ]; then
    ok "[A] and it carried /etc/rc.login too, so arm A is the fully-equipped shipped configuration"
else
    bad "[A] /etc/rc.login was NOT on the medium during arm A -- arm A is not the shipped configuration"
fi
score_rc a "$TGT_A" guarded "shipped"

# =========================================================================
say "1d -- arm D: THE SHIPPED BRANCH WITH NO LOGIN TO SHIP. IT MUST REFUSE."

# THE ARM THAT DID NOT EXIST, AND THE HOLE IT COVERS.
#
# write_machine_rc_boot's shipped branch copies /etc/rc.boot.machine and used
# to `return 0` on success -- with no check that the /etc/rc.login that file
# names is on the target. The guard existed ONLY on the fallback branch, which
# is the branch almost nobody takes. Nothing had ever run the configuration
# that separates the two: rc.boot.machine present, rc.login absent.
#
# This is that configuration. Before the 2026-08-20 fix the installer would
# have exited 0 here and printed "install complete" over a machine with no
# login program on any terminal. THE CONTROL FOR IT IS ARM A, in the same
# boot, off the same medium, differing by one `rm`: arm A must SUCCEED and
# must print "install complete". Without that this arm's refusal would be
# indistinguishable from an installer that refuses everything.
if [ "$(sed -n 's/^FRESHLOGIN-D-machine-present-status //p' "$IS" | head -1)" = 0 ]; then
    ok "[D] /etc/rc.boot.machine was STILL on the medium, so the SHIPPED branch is the branch that ran"
else
    bad "[D] /etc/rc.boot.machine was gone -- this arm ran the fallback and measures the wrong branch"
fi
if [ "$(sed -n 's/^FRESHLOGIN-D-login-present-status //p' "$IS" | head -1)" != 0 ]; then
    ok "[D] and /etc/rc.login was gone, so the rc it copies names a file the target cannot get"
else
    bad "[D] /etc/rc.login was still on the medium -- this arm is not the case it claims to be"
fi
if [ -n "$(istat D)" ] && [ "$(istat D)" != 0 ]; then
    ok "[D] THE INSTALLER FAILED, with status $(istat D) -- the shipped branch no longer answers a missing guard with success"
else
    bad "[D] the installer reported status '$(istat D)' for a machine that would have had NO login program on any terminal"
fi
if [ "$(sed -n '/FRESHLOGIN-D-BEGIN/,/FRESHLOGIN-D-END/p' "$IS" | grep -ac 'install complete')" != 0 ]; then
    bad "[D] 'install complete' was printed inside arm D -- the wizard would paint success over a login-less machine"
else
    ok "[D] 'install complete' was NOT printed in arm D"
fi
if [ "$(sed -n '/FRESHLOGIN-D-BEGIN/,/FRESHLOGIN-D-END/p' "$IS" | grep -ac 'refusing to report a successful install of an unguarded machine')" != 0 ]; then
    ok "[D] and it said why, in as many words, on the console"
else
    bad "[D] the installer produced no refusal message naming the reason"
fi
score_refused d "$TGT_D" "shipped-without-a-login"

say "1b -- arm B 'nomachine': THE FALLBACK BRANCH, which is what this fix is for"
if [ "$(sed -n 's/^FRESHLOGIN-B-machine-present-status //p' "$IS" | head -1)" != 0 ]; then
    ok "[B] /etc/rc.boot.machine was really gone from the medium, so write_machine_rc_boot's FALLBACK is what ran"
else
    bad "[B] /etc/rc.boot.machine was still present -- the fallback branch did NOT run and this arm measures nothing"
fi
if grep -aq 'no /etc/rc.boot.machine on this medium' "$IS"; then
    ok "[B] and the installer SAID SO on the wire rather than falling back silently"
else
    info "[B] the installer printed no fallback warning; the rc's contents below are the authority"
fi
score_rc b "$TGT_B" guarded "fallback"

say "1c -- arm C 'noguard': the guard CANNOT be produced, so the install must refuse"
if [ "$(sed -n 's/^FRESHLOGIN-C-login-present-status //p' "$IS" | head -1)" != 0 ]; then
    ok "[C] /etc/rc.login was really gone from the medium too"
else
    bad "[C] /etc/rc.login was still on the medium -- this arm is not the case it claims to be"
fi
if [ "$(istat C)" != 0 ] && [ -n "$(istat C)" ]; then
    ok "[C] THE INSTALLER FAILED, with status $(istat C) -- a missing guard was NOT answered by a successful install"
else
    bad "[C] the installer reported status '$(istat C)' with no way to guard the machine it was building"
fi
if grep -aq 'refusing to report a successful install of an unguarded machine' "$IS"; then
    ok "[C] and it said why, in as many words, on the console"
else
    bad "[C] the installer produced no refusal message naming the reason"
fi
if [ "$(sed -n '/FRESHLOGIN-C-BEGIN/,/FRESHLOGIN-C-END/p' "$IS" | grep -ac 'install complete')" != 0 ]; then
    bad "[C] 'install complete' was printed inside arm C -- the wizard would paint 'Install complete' over an unguarded machine"
else
    ok "[C] 'install complete' was NOT printed in arm C, so user/haminstallui.ad would paint FAILED rather than success"
fi
# And the positive half of that same check: arm A MUST have printed it, or
# the absence in arm C is not evidence of anything.
if [ "$(sed -n '/FRESHLOGIN-A-BEGIN/,/FRESHLOGIN-A-END/p' "$IS" | grep -ac 'install complete')" != 0 ]; then
    ok "[A] 'install complete' WAS printed in arm A -- so its absence in arm C is a real difference, not a grep that never matches"
else
    bad "[A] 'install complete' was not printed even in the shipped arm -- the arm C absence check is void"
fi
score_refused c "$TGT_C" "noguard"

# =========================================================================
say "2 -- BOOT THE FRESH INSTALL FROM ARM A AND TRY TO LOG IN ON A TERMINAL"

G="$(part_geom "$TGT_A" 2)"; [ -n "$G" ] || { bad "cannot read arm A's partition table"; finish; }
OFF="${G% *}"; SZ="${G#* }"
[ $((OFF % 1048576)) = 0 ] || { bad "arm A's root partition does not start on a MiB boundary ($OFF)"; finish; }

# =========================================================================
# EXACTLY ONE FILE IS ADDED TO THE DISK BEFORE IT IS BOOTED, AND IT IS NOT
# /etc/rc.boot. THIS SECTION USED TO SAY "UNTOUCHED" AND IT CANNOT ANY MORE.
#
# MEASURED on this host, 2026-08-20, on the disk arm A really installed:
# booted with nothing added at all, the serial log's LAST LINE is
#
#     hamgreet: the graphical login is presenting
#
# and no `login: ` ever appears on /dev/ttyS0. That is not a fault in this
# gate. /etc/rc.boot is `source '/etc/rc.boot.installed'` then `source
# '/etc/rc.login'` then `supervise`, and rc.boot.installed ENDS by sourcing
# /etc/rc.d/rc.5, which runs /bin/hamgreet IN THE FOREGROUND. So on a machine
# that reaches runlevel 5, THE LAST TWO LINES OF ITS OWN BOOT RC NEVER RUN:
# no login program is started on any terminal and `supervise` is never
# reached, until somebody has authenticated GRAPHICALLY.
#
# The same shape is visible in the 1.0.33 candidate's
# gates/installed_boot_login.log, where BOTH arms -- including that gate's own
# autologin CONTROL -- never reach their READY marker and both logs end on the
# same hamgreet line.
#
# THAT IS A PRODUCT QUESTION AND IT IS NOT THIS GATE'S TO ANSWER: whether an
# installed machine should start its terminal logins BEFORE the graphical one
# is a change to every installed machine, and etc/rc.d/rc.5.linux's own
# no-session branch already tells the operator to "Log in on a terminal" to
# read /var/lib/hamgreet.trace -- advice that cannot be followed today. It is
# written up in HANDOFF.md for the owner.
#
# What this gate measures is the TTY half, so it takes the documented way to
# stop short of runlevel 5 (etc/rc.boot.installed's own header: "It is for the
# gates that only ever wanted a booted machine to ask questions of"). One
# file, /etc/rc.runlevel, is written onto a COPY of arm A's disk. The rc under
# test is NOT touched, and that is asserted below by comparing it byte for
# byte with what the installer wrote.
printf 'hamnix_runlevel = 3\n' >"$W/rc.runlevel"

plant_runlevel3() {   # plant_runlevel3 <whole-disk-image> <label>
    local img="$1" label="$2" p="$W/plant-$label.img"
    carve "$img" 2 "$p" || { bad "[$label] cannot carve the disk to plant /etc/rc.runlevel"; return 1; }
    /sbin/e2fsck -fy "$p" >"$W/plant-$label-fsck1.log" 2>&1
    cat >"$W/plant-$label.dbg" <<DBEOF
cd /etc
write $W/rc.runlevel rc.runlevel
quit
DBEOF
    /sbin/debugfs -w -f "$W/plant-$label.dbg" "$p" >"$W/plant-$label-debugfs.log" 2>&1
    /sbin/e2fsck -fy "$p" >"$W/plant-$label-fsck2.log" 2>&1
    rm -f "$W/plant-$label-rb.txt"
    /sbin/debugfs -R "dump /etc/rc.runlevel $W/plant-$label-rb.txt" "$p" >/dev/null 2>&1
    if cmp -s "$W/rc.runlevel" "$W/plant-$label-rb.txt"; then
        ok "[$label] /etc/rc.runlevel landed byte-identical on the disk"
    else
        bad "[$label] /etc/rc.runlevel did not land -- see $W/plant-$label-debugfs.log"
        return 1
    fi
    dd if="$p" of="$img" bs=1M seek=$((OFF / 1048576)) conv=notrunc status=none \
        || { bad "[$label] cannot write the partition back"; return 1; }
    return 0
}

FRESHDISK="$W/target-fresh-r3.img"
cp --reflink=auto "$TGT_A" "$FRESHDISK" || { bad "cannot copy arm A's disk"; finish; }
plant_runlevel3 "$FRESHDISK" fresh || finish
# AND THE RC UNDER TEST IS UNCHANGED. Without this the section above could be
# hiding a rewritten boot rc behind the word "one file".
rm -f "$W/fresh-rcboot.txt"
/sbin/debugfs -R "dump /etc/rc.boot $W/fresh-rcboot.txt" "$W/plant-fresh.img" >/dev/null 2>&1
if cmp -s "$W/rcboot-a.txt" "$W/fresh-rcboot.txt"; then
    ok "and /etc/rc.boot on the disk about to be booted is BYTE-IDENTICAL to what the installer wrote"
else
    bad "the /etc/rc.boot about to be booted is not the one the installer wrote -- this arm tests a rc this gate made up"
    finish
fi

# The uid to expect is READ OFF THE DISK, not assumed: asserting a constant
# would be asserting this gate's memory of the installer's default.
rm -f "$W/passwd-a"
/sbin/debugfs -R "dump /etc/passwd $W/passwd-a" "$W/part-a.img" >/dev/null 2>&1
EXPECT_UID="$(awk -F: -v u="$USERNAME" '$1==u{print $3}' "$W/passwd-a" 2>/dev/null)"
if [ -n "$EXPECT_UID" ] && [ "$EXPECT_UID" != 0 ]; then
    ok "the fresh install's /etc/passwd carries '$USERNAME' at uid $EXPECT_UID"
    info "  $(awk -F: -v u="$USERNAME" '$1==u{print}' "$W/passwd-a")"
else
    bad "the fresh install has no usable '$USERNAME' entry (uid '$EXPECT_UID') -- there is nothing to log in as"
    finish
fi

cat >"$W/drive.fresh" <<DEOF
# The machine boots, presents a login prompt, and never powers off (that is
# what \`supervise\` is for), so every wait here is bounded.
EXPECT 420 \r?\nlogin:
SLEEP 5
# --- absence probe (1), BEFORE any credential: a root shell answers uid=0.
SEND id
SLEEP 3
# --- absence probe (2): a root shell executes a redirect.
SEND echo pwned > /var/log/freshlogin-pwned.txt
SLEEP 4
# Those two lines were eaten as a username and a password, so this must refuse.
EXPECT 60 Login incorrect
# --- a WRONG password for a REAL account.
SEND $USERNAME
SLEEP 2
SEND $WRONGPASS
SLEEP 4
EXPECT 60 Login incorrect
# --- the RIGHT password.
SEND $USERNAME
SLEEP 2
SEND $UPASS
SLEEP 10
SEND id
SLEEP 5
DONE 10
DEOF
cat >"$W/drive.control" <<'DEOF'
EXPECT 420 FRESHLOGIN-CONTROL-READY
SLEEP 10
SEND id
SLEEP 5
SEND echo pwned > /var/log/freshlogin-pwned.txt
SLEEP 5
DONE 10
DEOF

boot_arm() {   # boot_arm <name> <disk> <drivescript>
    local a="$1" src="$2" drv="$3"
    local D="$W/boot-$a"; rm -rf "$D"; mkdir -p "$D"
    local NVME="$D/nvme.img" SOCK="$D/serial.sock" SLOG="$D/serial.log"
    cp --reflink=auto "$src" "$NVME" || { bad "[$a] cannot copy the disk"; return 1; }
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
        -device nvme,drive=nvme0,serial=FRESHBOOT \
        >"$D/qemu.out" 2>&1 &
    local QPID=$!
    reap_add "$QPID"
    info "[$a] qemu pid $QPID, serial socket $SOCK"
    python3 tests/linux/serial_drive.py "$SOCK" "$drv" "$SLOG" "$D/drive.trace" \
        >"$D/drive.log" 2>&1
    local DRC=$?
    [ "$DRC" = 0 ] && info "[$a] the driver completed its script" \
                   || info "[$a] the driver stopped early (rc=$DRC) -- see $D/drive.log; the raw log is still read"
    # A machine running `supervise` never powers itself off. That is the
    # correct behaviour of the thing under test, so this arm is scored on the
    # SERIAL WIRE only and the machine is stopped here. Nothing this gate
    # asserts about arm A depends on the filesystem committing.
    kill -TERM "$QPID" 2>/dev/null; sleep 3; kill -KILL "$QPID" 2>/dev/null
    wait "$QPID" 2>/dev/null
    tr -d '\r' <"$SLOG" >"$D/serial.txt"
    return 0
}

boot_arm fresh "$FRESHDISK" "$W/drive.fresh" || finish
FS="$W/boot-fresh/serial.txt"
info "fresh boot log: $FS ($(wc -c <"$FS" 2>/dev/null || echo 0) bytes)"

# THE OPT-OUT'S OWN ASSERTION, and it can fail. If the runlevel file did not
# take, the machine goes to runlevel 5, blocks in hamgreet and every login
# assertion below becomes a statement about a machine that never got there --
# which is exactly the empty-reason red this treatment exists to remove. So it
# is scored, and it is scored FIRST.
if grep -aq 'RUNLEVEL 5 SKIPPED' "$FS"; then
    ok "[fresh] the machine read /etc/rc.runlevel and stopped at runlevel 3, so the graphical login is not in the way of the terminal one"
else
    bad "[fresh] the machine did NOT report skipping runlevel 5 -- the opt-out did not take, and nothing below is a measurement of the tty login"
    tail -20 "$FS" 2>/dev/null | sed 's/^/        /'
    finish
fi

if grep -aq 'rc.login: getty started on /dev/ttyS0' "$FS"; then
    ok "[fresh] the installed machine's own rc reached /etc/rc.login and started a getty on the console"
else
    bad "[fresh] the machine never reported starting a getty -- nothing below is a measurement of this machine"
    tail -40 "$FS" 2>/dev/null | sed 's/^/        /'
    finish
fi

# ANCHORED. `rc.login: getty started on /dev/ttyS0` CONTAINS `login:`.
if grep -aq '^login: ' "$FS"; then
    ok "[fresh] A FRESH INSTALL PRESENTS \`login: \` ON ITS CONSOLE ($(grep -ac '^login: ' "$FS") prompt(s)) -- the installer's machine asks who you are"
else
    bad "[fresh] NO \`login: \` prompt appeared on a machine the installer just built"
fi
if grep -aq 'Login incorrect' "$FS"; then
    ok "[fresh] and it REFUSED credentials it should refuse ($(grep -ac 'Login incorrect' "$FS") refusal(s): junk, and a real account's wrong password)"
else
    bad "[fresh] nothing was refused -- either the prompt does not authenticate or the driver never reached it"
fi
if has_uid "$FS" "$EXPECT_UID"; then
    ok "[fresh] and the RIGHT password admitted: the session answered \`id\` with uid=$EXPECT_UID, the uid the installer gave '$USERNAME'"
    info "  $(grep -aE "uid=$EXPECT_UID([^0-9]|$)" "$FS" | head -1)"
else
    bad "[fresh] the correct password did not produce a session answering uid=$EXPECT_UID"
fi
if has_root_identity "$FS"; then
    bad "[fresh] A ROOT IDENTITY ANSWERED ON THIS MACHINE'S CONSOLE:"
    root_identity_lines "$FS" | head -3 | sed 's/^/        /'
else
    ok "[fresh] and NO root identity answered anywhere on this console -- \`id\` before authenticating produced no uid=0"
fi
# Ordering: the question must come before any shell is offered.
FIRST_LOGIN=$(grep -an '^login: ' "$FS" | head -1 | cut -d: -f1)
FIRST_SHELL=$(grep -an 'hamsh\$ \|^\$ ' "$FS" | head -1 | cut -d: -f1)
info "[fresh] first 'login: ' at line ${FIRST_LOGIN:-<none>}, first shell prompt at line ${FIRST_SHELL:-<none>}"
if [ -n "$FIRST_LOGIN" ] && { [ -z "$FIRST_SHELL" ] || [ "$FIRST_LOGIN" -lt "$FIRST_SHELL" ]; }; then
    ok "[fresh] the question came before any shell prompt -- no shell was offered before authenticating"
else
    bad "[fresh] a shell prompt appeared at line $FIRST_SHELL, before the first login prompt at $FIRST_LOGIN"
fi

# =========================================================================
say "3 -- THE CONTROL, AND IT RUNS: the same disk with \`-a hostowner\`"
# Everything is identical to arm 'fresh' -- same disk image, same binaries,
# same driver, same patterns, same port -- except /etc/rc.boot, which is
# replaced by the same three lines with the console getty given `-a
# hostowner`. `login -f` does not setuid, so it keeps PID 1's root. This arm
# MUST reach a root shell with no password, and if it does not then arm
# 'fresh''s silence proves nothing at all.
# AND IT IS COPIED FROM THE ARM-'fresh' DISK, NOT FROM $TGT_A, so it carries
# the SAME /etc/rc.runlevel. A control that went to runlevel 5 while the arm it
# controls stopped at 3 would differ in two things at once, and would stall in
# hamgreet exactly as installed_boot_login's own control did in the 1.0.33
# candidate -- a control that cannot fire is worse than none.
CTLDISK="$W/target-control.img"
cp --reflink=auto "$FRESHDISK" "$CTLDISK" || { bad "cannot copy arm A's disk for the control"; finish; }
CTLPART="$W/part-control.img"
carve "$CTLDISK" 2 "$CTLPART" || { bad "cannot carve the control disk"; finish; }
/sbin/e2fsck -fy "$CTLPART" >"$W/ctl-fsck1.log" 2>&1
cat >"$W/rc.boot.control" <<'RCEOF'
# /etc/rc.boot -- rewritten by tests/linux/installed_fresh_login.sh for the
# CONTROL arm only. Identical to what the installer wrote except that the
# console getty is given `-a hostowner`, which skips the password entirely.
source '/etc/rc.boot.installed'
/bin/getty /dev/ttyS0 -a hostowner &
echo 'FRESHLOGIN-CONTROL-READY'
supervise
RCEOF
cat >"$W/ctl.dbg" <<DBEOF
cd /etc
rm rc.boot
write $W/rc.boot.control rc.boot
quit
DBEOF
/sbin/debugfs -w -f "$W/ctl.dbg" "$CTLPART" >"$W/ctl-debugfs.log" 2>&1
/sbin/e2fsck -fy "$CTLPART" >"$W/ctl-fsck2.log" 2>&1
rm -f "$W/ctl-rb.rc"
/sbin/debugfs -R "dump /etc/rc.boot $W/ctl-rb.rc" "$CTLPART" >/dev/null 2>&1
if cmp -s "$W/rc.boot.control" "$W/ctl-rb.rc"; then
    ok "[control] the autologin rc landed byte-identical on the control disk"
else
    bad "[control] the control's rc did not land -- see $W/ctl-debugfs.log; without it there is no instrument proof"
    finish
fi
dd if="$CTLPART" of="$CTLDISK" bs=1M seek=$((OFF / 1048576)) conv=notrunc status=none \
    || { bad "[control] cannot write the partition back"; finish; }

boot_arm control "$CTLDISK" "$W/drive.control" || finish
CS="$W/boot-control/serial.txt"
info "control boot log: $CS ($(wc -c <"$CS" 2>/dev/null || echo 0) bytes)"

if grep -aq 'RUNLEVEL 5 SKIPPED' "$CS"; then
    ok "[control] the control stopped at runlevel 3 too, so it differs from arm 'fresh' by the getty flag and nothing else"
else
    bad "[control] the control did NOT skip runlevel 5 -- it differs from arm 'fresh' in two things at once and is not a control"
fi
if has_root_identity "$CS"; then
    ok "[control] the console answered \`id\` with a ROOT identity -- A ROOT SHELL IS VISIBLE TO THIS INSTRUMENT, on this port, with this driver, with this detector"
    info "  $(root_identity_lines "$CS" | head -1)"
else
    bad "[control] the console did NOT answer uid=0. This gate cannot see a root shell even where one IS, so arm 'fresh''s silence proves NOTHING"
    tail -30 "$CS" 2>/dev/null | sed 's/^/        /'
fi
if grep -aq '^login: ' "$CS"; then
    bad "[control] a 'login: ' prompt appeared on the autologin arm -- \`-a\` did not take effect, so this is not the control it claims to be"
else
    ok "[control] and NO 'login: ' prompt appeared -- the root shell was reached with no password typed"
fi

finish
