#!/usr/bin/env bash
#
# tests/linux/install_refuses_reserved.sh — THE INSTALLER REFUSES A NAME THAT
# WOULD DESTROY THE MACHINE'S ADMINISTRATOR, AND REFUSES ONE TOO LONG FOR ITS
# OWN BUFFER — MEASURED ON A REAL DISK, NOT IN THE SOURCE.
#
# REGISTRATION. ON-DEMAND: it builds a medium and boots it under OVMF, past the
# battery's per-shard budget. The QEMU-free half of the same rule is
# scripts/test_install_names_host.sh, which runs lib/instnames.ad against real
# strings in milliseconds and IS cheap enough to register.
#
# THE TWO DEFECTS
# ===============
#   1. `install --auto /dev/nvme0n1 --user hostowner` CONVERTED THE MACHINE'S
#      ADMINISTRATOR INTO AN ORDINARY ACCOUNT. user/hlinstall.ad rewrites the
#      account table rather than appending to it: the requested name goes on
#      its DROP list, so any existing line for that name is removed, and the
#      name is then written at uid 1001 with home /home/<name> and shell
#      /bin/hamsh. For `hostowner` that deletes the uid-1 administrator and
#      re-creates it as a regular user; the machine ends with no owner at all.
#      `sshd`, `hamsh-svc` and `nobody` are reachable the same way.
#   2. `copy_str()` COPIED UP TO 120 BYTES INTO Array[64, uint8] GLOBALS, so
#      `--user <65+ characters>` overran the global next to `user_buf` -- on
#      that command line, the password buffers.
#
# WHAT IS MEASURED, AND WHAT IS A CONTROL
# =======================================
# TWO BOOTS, ONE DISK ATTACHED TO EACH, AND THE SECOND SHAPE IS THE RESULT OF A
# MEASUREMENT RATHER THAN a preference.
#
# THE FIRST VERSION ATTACHED BOTH DISKS AT ONCE and aimed the refusals at
# /dev/nvme1n1 and the control install at /dev/nvme0n1. IT RAN TWICE AND THE TWO
# DISKS SWAPPED IDENTITIES BETWEEN THE RUNS -- same QEMU command line, same
# medium: in one run the control account landed on the control disk, in the next
# it landed on the refusal disk and the `hostowner` attempt landed on the
# control one. Linux names NVMe namespaces by controller INSTANCE, and instances
# are handed out as probes COMPLETE, so with two controllers the mapping from
# `-device nvme,drive=nvme0` to /dev/nvme0n1 is a race. A gate that assumes it
# is reading the disk it thinks it is reading, is not reading anything.
#
# So: ONE controller per boot. The refusals run in a boot with only the refusal
# disk attached; the control install runs in a second boot with only the control
# disk attached; both address /dev/nvme0n1, which is the only namespace there
# is. Which phase a boot performs is chosen by a marker file the medium writes
# on ITS OWN root between them.
#
#   * the refusal disk must still be ALL ZEROES afterwards. sgdisk writes a
#     protective MBR and a GPT header in the first sector of anything it
#     touches, so a refusal that happened after the partitioner ran would show.
#   * the control disk must be partitioned, mountable, and its /etc/passwd must
#     carry BOTH `hostowner` (uid 1, the administrator that survived) and the
#     ordinary account the control install created.
#   * the serial log must carry the installer's refusal, BY NAME, once per
#     reserved name and once for the over-long one.
#
# THE CONTROL IS THE SUCCESSFUL INSTALL, and it is what makes the refusals mean
# something: an installer that refused everything would satisfy every "it did
# not write" assertion above while being completely broken.
#
# THE NEGATIVE CONTROL is a second run on a tree with the refusals removed:
# there the refusal disk comes back PARTITIONED and its /etc/passwd carries
# `hostowner:x:1001:1001::/home/hostowner:/bin/hamsh` and no uid-1 line at all
# -- the administrator deleted and rewritten as an ordinary user, which is the
# defect itself. `hostowner` is the LAST of the six attempts for that reason:
# they all write the same disk, so only the last is readable afterwards.
#
# Usage: tests/linux/install_refuses_reserved.sh
#   INSTRES_WORK=<dir>   work dir (default ~/.hamnix-build/instres)
#   INSTRES_REUSE=1      reuse an already-built medium
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

. tests/linux/reap.sh
reap_on_exit

W="${INSTRES_WORK:-$HOME/.hamnix-build/instres}"
mkdir -p "$W"
export TMPDIR="$W/tmp"; mkdir -p "$TMPDIR"

LIVE="$W/live-usb.img"
GOOD="$W/good-nvme.img"          # the control install's target
BLANK="$W/blank-nvme.img"        # every refusal is aimed here
PART="$W/part.img"

GOODUSER=hamresusr
# 65 'a's: one more than user_buf holds. Built here rather than typed, so the
# number in the assertion is the number on the command line.
LONGUSER="$(python3 -c 'print("a"*65)')"

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
fs_dump() { rm -f "$3"; /sbin/debugfs -R "dump $2 $3" "$1" >/dev/null 2>&1; [ -s "$3" ]; }
all_zero() { [ "$(head -c 4194304 "$1" | tr -d '\0' | wc -c)" = 0 ]; }

say "0 -- a medium whose rc points the installer at a blank disk, by name"

# THE MEDIUM'S OWN rc, IN TWO PHASES SELECTED BY A MARKER ON ITS OWN ROOT.
# Sourcing a file that does not exist returns non-zero, so phase 1 runs while
# the marker is absent and writes it. Each phase addresses /dev/nvme0n1, which
# is the only namespace attached in that boot -- see the header for the two runs
# that swapped two controllers' names and why this shape exists.
#
# `poweroff > /dev/null`: user/poweroff.ad writes its banner to fd 1 BEFORE it
# opens /dev/reboot, and a console the compositor has taken blocks that write,
# so an unredirected poweroff can hang instead of powering off (measured in
# tests/linux/installed_documents.sh). There is no compositor here, but the
# redirect costs nothing and the failure it avoids costs a whole run.
{
    printf '%s\n' \
"ln -s /dev/console /dev/cons" \
"echo 'INSTRES-LIVE: the medium booted'" \
"source '/var/lib/instres.refused'" \
"if \$status > 0 {"
    # ORDER IS EVIDENCE. All six refusals write the SAME disk, so on a reverted
    # tree each install overwrites the last and only the FINAL one is readable
    # afterwards. `hostowner` is LAST so that what the disk carries is the
    # defect itself. Measured on the first negative control, where the
    # 65-character name went last instead and the table showed its TRUNCATED
    # form (37 a's) but not the administrator being rewritten.
    for n in sshd hamsh-svc nobody root; do
        printf '%s\n' \
"    echo 'INSTRES-TRY $n'" \
"    install --auto /dev/nvme0n1 --hostname resbox --user $n --user-pass respw --root-pass resadmin" \
"    echo 'INSTRES-RC $n' \$status"
    done
    printf '%s\n' \
"    echo 'INSTRES-TRY toolong'" \
"    install --auto /dev/nvme0n1 --hostname resbox --user $LONGUSER --user-pass respw --root-pass resadmin" \
"    echo 'INSTRES-RC toolong' \$status" \
"    echo 'INSTRES-TRY hostowner'" \
"    install --auto /dev/nvme0n1 --hostname resbox --user hostowner --user-pass respw --root-pass resadmin" \
"    echo 'INSTRES-RC hostowner' \$status" \
"    echo '# refusals done' > /var/lib/instres.refused" \
"    echo 'INSTRES-REFUSALS-DONE'" \
"    sleep 5" \
"    poweroff > /dev/null" \
"}" \
"echo 'INSTRES-TRY control'" \
"install --auto /dev/nvme0n1 --hostname resbox --user $GOODUSER --user-pass respw --root-pass resadmin" \
"echo 'INSTRES-RC control' \$status" \
"echo 'INSTRES-CONTROL-DONE'" \
"sleep 5" \
"poweroff > /dev/null"
} >"$W/rc.install"

if [ "${INSTRES_REUSE:-0}" = 1 ] && [ -f "$LIVE" ]; then
    info "reusing $LIVE (INSTRES_REUSE=1)"
else
    info "building the medium (this is the slow part)"
    scripts/hamlinux_image.sh >"$W/img1.log" 2>&1 || {
        bad "lean image build -- see $W/img1.log"; finish; }
    # THE SEED DISK IS NOT OPTIONAL: scripts/hamlinux_disk.sh writes
    # /boot/root.partuuid, and hlinstall REFUSES to partition anything without
    # it -- which would make every "the installer refused" assertion below
    # true for the wrong reason.
    scripts/hamlinux_disk.sh "$W/seed.img" 3G >"$W/disk1.log" 2>&1 || {
        bad "seed disk build -- see $W/disk1.log"; finish; }
    HAMLINUX_INSTALLER=1 scripts/hamlinux_image.sh >"$W/img2.log" 2>&1 || {
        bad "installer image build -- see $W/img2.log"; finish; }
    HAMLINUX_DISK_RC="$W/rc.install" \
        scripts/hamlinux_disk.sh "$LIVE" 4G >"$W/disk.log" 2>&1 || {
        bad "live medium build -- see $W/disk.log"; finish; }
fi
[ -s "$LIVE" ] || { bad "no live medium at $LIVE"; finish; }

rm -f "$GOOD" "$BLANK"
truncate -s 6G "$GOOD"
truncate -s 6G "$BLANK"
all_zero "$GOOD"  && ok "the control target is all zeroes before the boot" \
                  || bad "the control target is not blank"
all_zero "$BLANK" && ok "the refusal target is all zeroes before the boot" \
                  || bad "the refusal target is not blank"

# boot_phase <tag> <disk-image> -- one boot, one NVMe namespace attached.
boot_phase() {
    local tag="$1" img="$2" IPID i
    d="$W/boot-$tag"; rm -rf "$d"; mkdir -p "$d"
    cp /usr/share/OVMF/OVMF_VARS_4M.fd "$d/OVMF_VARS.fd"
    qemu-system-x86_64 \
        -m 2048 -smp 2 -no-reboot \
        -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
        -drive "if=pflash,format=raw,unit=1,file=$d/OVMF_VARS.fd" \
        -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
        -display none -vga none -device virtio-gpu-pci \
        -serial "file:$d/serial.log" -enable-kvm -cpu host \
        -device qemu-xhci,id=xhci -device usb-kbd -device usb-tablet \
        -drive "file=$img,if=none,format=raw,id=nvme0" \
        -device nvme,drive=nvme0,serial=INSTRESTGT \
        -drive "file=$LIVE,if=none,format=raw,id=usbstick" \
        -device usb-storage,bus=xhci.0,drive=usbstick,bootindex=0 \
        >"$d/qemu.out" 2>&1 &
    IPID=$!
    reap_add "$IPID"
    i=0
    while kill -0 "$IPID" 2>/dev/null && [ "$i" -lt 900 ]; do sleep 5; i=$((i+5)); done
    kill -TERM "$IPID" 2>/dev/null; sleep 2; kill -KILL "$IPID" 2>/dev/null
    wait "$IPID" 2>/dev/null
}

say "1 -- boot one: six installs that must be refused, with ONLY the refusal disk attached"
boot_phase refusals "$BLANK"
REFLOG="$d/serial.log"
if grep -aq 'INSTRES-REFUSALS-DONE' "$REFLOG" 2>/dev/null; then
    ok "the medium booted and ran all six refused install attempts to completion"
else
    bad "the refusals boot never printed INSTRES-REFUSALS-DONE -- nothing below is a statement about an installer"
    tail -25 "$REFLOG" 2>/dev/null | sed 's/^/        /'
    finish
fi

say "1b -- boot two: the install that MUST succeed, with ONLY the control disk attached"
boot_phase control "$GOOD"
CTLLOG="$d/serial.log"
if grep -aq 'INSTRES-CONTROL-DONE' "$CTLLOG" 2>/dev/null; then
    ok "the medium booted a second time and ran the control install to completion"
else
    bad "the control boot never printed INSTRES-CONTROL-DONE"
    tail -25 "$CTLLOG" 2>/dev/null | sed 's/^/        /'
    finish
fi

# AND THE CONTROL INSTALL MUST HAVE SUCCEEDED, not merely returned. Without
# /boot/root.partuuid the installer refuses everything and every assertion in
# section 2 would be true for a reason that has nothing to do with names.
if grep -aq '^install complete' "$CTLLOG"; then
    ok "the control install reported 'install complete' -- the installer on this medium can install"
else
    bad "the control install never reported 'install complete': $(grep -a '^hlinstall: ' "$CTLLOG" | head -2 | tr '\n' ' ' | cut -c1-200)"
fi

say "2 -- what the installer SAID, once per refused name"
for n in hostowner sshd hamsh-svc nobody root; do
    if grep -aq "^hlinstall: --user $n is a RESERVED system account" "$REFLOG"; then
        ok "the installer refused --user $n by name"
    else
        bad "the installer did NOT refuse --user $n: $(grep -a -A2 "INSTRES-TRY $n" "$REFLOG" | tail -2 | tr '\n' ' ' | cut -c1-160)"
    fi
done
if grep -aq '^hlinstall: --user is longer than 63 bytes' "$REFLOG"; then
    ok "and it refused a 65-character --user rather than copying it into a 64-byte buffer"
else
    bad "the installer did NOT refuse a 65-character --user: $(grep -a -A2 'INSTRES-TRY toolong' "$REFLOG" | tail -2 | tr '\n' ' ' | cut -c1-160)"
fi
# THE CONTROL: it must NOT have refused the ordinary name.
if grep -aq "hlinstall: --user $GOODUSER is a RESERVED" "$CTLLOG"; then
    bad "the installer refused the ORDINARY name $GOODUSER too -- it refuses everything, and the refusals above mean nothing"
else
    ok "and it did NOT refuse the ordinary name $GOODUSER"
fi

say "3 -- what the installer DID, read off two disks"
if all_zero "$BLANK"; then
    ok "the refusal target is STILL ALL ZEROES: six refused installs wrote not one byte, not even a partition table"
else
    bad "the refusal target was WRITTEN TO. A refused install partitioned a disk"
    /sbin/sfdisk -l "$BLANK" 2>/dev/null | sed 's/^/        /' | head -12
    if carve "$BLANK" 2 && fs_dump "$PART" /etc/passwd "$W/blank-passwd"; then
        info "and its /etc/passwd says: $(grep -v '^#' "$W/blank-passwd" | tr '\n' ' ' | cut -c1-200)"
        grep -q '^hostowner:x:1001:' "$W/blank-passwd" \
            && bad "…including hostowner:x:1001 -- the ADMINISTRATOR REWRITTEN AS AN ORDINARY USER, which is the whole defect" \
            || info "…without a hostowner:x:1001 line"
    fi
    rm -f "$PART"
fi

# THE CONTROL INSTALL, which is what makes the zeroes above a measurement.
if carve "$GOOD" 2; then
    ok "the control target has a partition table and a root partition -- the installer CAN install"
    if fs_dump "$PART" /etc/passwd "$W/good-passwd"; then
        grep -q "^$GOODUSER:x:1001:1001::/home/$GOODUSER:" "$W/good-passwd" \
            && ok "the control install created $GOODUSER at uid 1001" \
            || bad "the control install did not create $GOODUSER: $(grep -v '^#' "$W/good-passwd" | tr '\n' ' ' | cut -c1-200)"
        grep -q '^hostowner:x:1:' "$W/good-passwd" \
            && ok "and hostowner is still uid 1 on that machine -- the administrator the refusals protect" \
            || bad "hostowner is not at uid 1 on the control machine: $(grep '^hostowner:' "$W/good-passwd")"
    else
        bad "could not read /etc/passwd off the control target"
    fi
    rm -f "$PART"
else
    bad "the control target has no root partition -- the installer installed NOTHING, so 'it refused' above is indistinguishable from 'it is broken'"
fi

info "evidence: $W"
finish
