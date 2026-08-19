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
# ONE medium boot performs THREE installs onto THREE blank disks, so the only
# variable between them is what the medium carried at the moment of the
# install. The medium's rc deletes a file between installs; nothing else
# differs -- same installer binary, same arguments, same disk geometry.
#
#   A 'shipped'    the medium carries /etc/rc.boot.machine, as it does today.
#                  The target's /etc/rc.boot must carry BOTH guard lines.
#   B 'nomachine'  /etc/rc.boot.machine deleted first, so the FALLBACK BRANCH
#                  runs. The target's /etc/rc.boot must STILL carry both guard
#                  lines. This is the arm the fix exists for; before the fix
#                  this disk would boot straight to a root prompt.
#   C 'noguard'    rc.boot.machine AND /etc/rc.login both deleted, so the
#                  installer CANNOT produce a machine that asks. It must FAIL
#                  LOUDLY: no "install complete", and its refusal on the wire.
#                  A missing guard must never be answered by a successful
#                  install.
#
# Then the disk from arm A -- BYTE FOR BYTE AS THE INSTALLER LEFT IT, with
# nothing written into it by this gate -- is booted and driven over serial:
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
say "0 -- the medium, and ONE boot that performs THREE installs"

# THE MEDIUM'S OWN rc. THE ONLY THING THAT DIFFERS BETWEEN THE THREE INSTALLS
# IS THE `rm` LINES BETWEEN THEM. Order matters and is deliberate: the
# shipped arm runs while the medium is intact, then rc.boot.machine goes, then
# rc.login goes.
cat >"$W/rc.install" <<RCEOF
ln -s /dev/console /dev/cons
echo 'FRESHLOGIN-LIVE: the medium booted'

# --- ARM A: the medium exactly as it ships ---------------------------
ls /etc/rc.boot.machine
echo 'FRESHLOGIN-A-machine-present-status' \$status
echo 'FRESHLOGIN-A-BEGIN'
install --auto /dev/nvme0n1 --hostname $HOSTNAME_-a --user $USERNAME --user-pass $UPASS --root-pass $RPASS
echo 'FRESHLOGIN-A-status' \$status
echo 'FRESHLOGIN-A-END'

# --- ARM B: the fallback branch. Only rc.boot.machine is gone. -------
rm /etc/rc.boot.machine
ls /etc/rc.boot.machine
echo 'FRESHLOGIN-B-machine-present-status' \$status
echo 'FRESHLOGIN-B-BEGIN'
install --auto /dev/nvme1n1 --hostname $HOSTNAME_-b --user $USERNAME --user-pass $UPASS --root-pass $RPASS
echo 'FRESHLOGIN-B-status' \$status
echo 'FRESHLOGIN-B-END'

# --- ARM C: no guard is producible at all. The install MUST refuse. --
rm /etc/rc.login
ls /etc/rc.login
echo 'FRESHLOGIN-C-login-present-status' \$status
echo 'FRESHLOGIN-C-BEGIN'
install --auto /dev/nvme2n1 --hostname $HOSTNAME_-c --user $USERNAME --user-pass $UPASS --root-pass $RPASS
echo 'FRESHLOGIN-C-status' \$status
echo 'FRESHLOGIN-C-END'

echo 'FRESHLOGIN-LIVE-DONE'
sleep 8
poweroff
RCEOF

TGT_A="$W/target-a.img"; TGT_B="$W/target-b.img"; TGT_C="$W/target-c.img"

if [ "${FRESHLOGIN_REUSE:-0}" = 1 ] && [ -s "$LIVE" ] && [ -s "$TGT_A" ]; then
    info "reusing $LIVE and the three targets (FRESHLOGIN_REUSE=1)"
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

    for f in "$TGT_A" "$TGT_B" "$TGT_C"; do
        rm -f "$f"; truncate -s 6G "$f"
    done
    if [ "$(head -c 1048576 "$TGT_A" | tr -d '\0' | wc -c)" = 0 ]; then
        ok "the three targets are all zeroes before the install"
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
        -drive "file=$TGT_A,if=none,format=raw,id=nvme0" \
        -device nvme,drive=nvme0,serial=FRESHA \
        -drive "file=$TGT_B,if=none,format=raw,id=nvme1" \
        -device nvme,drive=nvme1,serial=FRESHB \
        -drive "file=$TGT_C,if=none,format=raw,id=nvme2" \
        -device nvme,drive=nvme2,serial=FRESHC \
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
    ok "the medium booted and ran all three installs to completion"
else
    bad "the install boot never printed FRESHLOGIN-LIVE-DONE -- nothing below is a statement about an installed machine"
    tail -30 "$IS" 2>/dev/null | sed 's/^/        /'
    finish
fi

istat() { sed -n "s/^FRESHLOGIN-$1-status //p" "$IS" | head -1; }

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

info "arm A installer exit status on the wire: '$(istat A)'"
info "arm B installer exit status on the wire: '$(istat B)'"
info "arm C installer exit status on the wire: '$(istat C)'"

say "1a -- arm A 'shipped': the medium carried /etc/rc.boot.machine"
if [ "$(sed -n 's/^FRESHLOGIN-A-machine-present-status //p' "$IS" | head -1)" = 0 ]; then
    ok "[A] the medium really did carry /etc/rc.boot.machine at the moment of this install"
else
    bad "[A] /etc/rc.boot.machine was NOT on the medium during arm A -- arm A is not the shipped configuration and arm B is a contrast with nothing"
fi
score_rc a "$TGT_A" guarded "shipped"

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

# =========================================================================
say "2 -- BOOT THE FRESH INSTALL FROM ARM A, UNTOUCHED, AND TRY TO LOG IN"

G="$(part_geom "$TGT_A" 2)"; [ -n "$G" ] || { bad "cannot read arm A's partition table"; finish; }
OFF="${G% *}"; SZ="${G#* }"
[ $((OFF % 1048576)) = 0 ] || { bad "arm A's root partition does not start on a MiB boundary ($OFF)"; finish; }

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

boot_arm fresh "$TGT_A" "$W/drive.fresh" || finish
FS="$W/boot-fresh/serial.txt"
info "fresh boot log: $FS ($(wc -c <"$FS" 2>/dev/null || echo 0) bytes)"

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
CTLDISK="$W/target-control.img"
cp --reflink=auto "$TGT_A" "$CTLDISK" || { bad "cannot copy arm A's disk for the control"; finish; }
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
