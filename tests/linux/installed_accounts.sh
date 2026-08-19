#!/usr/bin/env bash
#
# tests/linux/installed_accounts.sh — AN INSTALLED MACHINE KEEPS ITS ACCOUNTS,
# AND THE ACCOUNT THE WIZARD CREATED IS THE ONE THE DESKTOP SESSION RUNS AS.
#
# REGISTRATION. ON-DEMAND: not in ci_battery_manifest.txt because it builds a
# medium, installs a machine and then boots that machine twice under OVMF --
# three QEMU boots and a full image build, far past the battery's per-shard
# budget. Same class as tests/linux/installed_offers_install.sh, whose
# structure this borrows.
#
# THE THREE DEFECTS THIS EXISTS FOR, ALL MEASURED ON A REAL INSTALLED DISK
# (~/.hamnix-build/instoffer/target-nvme.img, read with debugfs, nothing
# mounted, 2026-08-18):
#
#   1. `hpm update` DELETED THE INSTALLER'S USER. hpm's _is_machine_owned
#      matched exactly one path -- etc/rc.boot -- and hamnix-init SHIPS
#      etc/passwd and etc/group, so the first update rewrote both from the
#      package. /etc/shadow is in NO package, so the hashes stayed and the
#      names they belong to did not: a machine with hashes and no names.
#
#   2. THE NAMED USER WAS NEVER THE SESSION USER. The installer appended
#      `<name>:x:1000:1000` to a table that already carried `dave:x:1000` (an
#      auth fixture out of the source tree) and `live:x:1001`. So the wizard's
#      account was a DUPLICATE of uid 1000 and the SECOND one -- every
#      getpwuid(1000) resolved to `dave` -- while the desktop session, which
#      runs as uid 1001 (etc/rc.de-user.linux), stayed `live` with /home/live
#      as its home. /home/<name> was created empty and nothing ever looked in
#      it. The installed /etc/shadow also carried the tree's PUBLISHED hashes
#      for hostowner, dave and live, verbatim.
#
#   3. THE PASSWORD WAS NEVER STORED ON THE ONE CONFIGURATION THAT MATTERS.
#      hlinstall hashes with `openssl passwd -6` inside the `#distro`
#      namespace. A USB stick has no Debian medium -- the partitioning tools
#      already fall back to /usr/lib/instroot for exactly that reason -- and
#      the hash call did not. MEASURED in that install's own serial log:
#      "WARNING: could not hash the password", and the account was written
#      `hamgateusr:*:20000:...`, i.e. LOCKED. The wizard collects a password
#      on its own page and produced a machine nobody could log into. The
#      administrator password it collects on the page before was read by
#      NOTHING at all (`--root-pass` was parsed and never used).
#
# WHAT THIS GATE MEASURES, IN ORDER, AND WHAT IS A CONTROL
# =======================================================
#   0. Build a medium, install onto a blank virtual disk with --hostname,
#      --user, --user-pass and --root-pass.
#   1. HOST, off the installed ext4 with debugfs, nothing mounted and nothing
#      written back: the account table, the hashes, the home and its OWNER.
#      INSTRUMENT CONTROLS, RUN: the same reader must find a file that is
#      certainly there (/etc/hamnix-release), and the MEDIUM's own /etc/passwd
#      must carry `live` and must NOT carry the wizard's name -- so a name
#      found on the target can only have come from the install.
#   2. BOOT THE INSTALLED MACHINE and run `hpm update` against a local channel
#      it is one version behind on. Then read the SAME account assertions off
#      the SAME disk. This is the whole of defect 1: an update that rewrites
#      /etc/passwd shows up here as the account being gone.
#      CONTROL, RUN: the update must report that it really upgraded a package
#      (`upgraded=1`), so "the account survived" is not "nothing happened".
#   3. BOOT IT AGAIN, to its desktop, and read WHOSE session it is:
#        * the serial line `uid 1001 home /home/<name>` -- the DE session
#          shell's own report of the identity it dropped to and the home it
#          resolved for it (user/hamsh.ad:builtin_setuid);
#        * /var/log/hamdesktop.log, read off the disk afterwards, naming the
#          directory the desktop actually watched (user/hamdesktop.ad:_desk_dir);
#        * and the picture: the panel reads "Applications" and the icon column
#          resolves launcher names, so the desktop really came up.
#      OCR CONTROLS, RUN: the OCR must NOT report a string that is certainly
#      not on the screen.
#
# THE NEGATIVE CONTROL IS A SECOND RUN OF THIS FILE ON A REVERTED TREE, and
# the numbers of both are in the commit message and in HANDOFF.md. Everything
# here is a statement about a machine that was built, installed, updated and
# booted; nothing is a statement about source code.
#
# Usage: tests/linux/installed_accounts.sh
#   INSTACCT_WORK=<dir>     work dir (default ~/.hamnix-build/instacct)
#   INSTACCT_REUSE=1        reuse an already-built medium and installed disk
#   INSTACCT_VERSION=<v>    the channel version (default 1.0.99)
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

. tests/linux/reap.sh
reap_on_exit

W="${INSTACCT_WORK:-$HOME/.hamnix-build/instacct}"
mkdir -p "$W"
export TMPDIR="$W/tmp"; mkdir -p "$TMPDIR"

LIVE="$W/live-usb.img"          # the medium, with an rc that drives the install
NVME="$W/target-nvme.img"
PART="$W/part.img"
REPO="$W/repo"
EXTRA="$W/extra"
NEWVER="${INSTACCT_VERSION:-1.0.99}"
SCREEN_W=1280
SCREEN_H=800
QMP_INPUT="$PROJ_ROOT/tests/linux/qmp_input.py"

# The machine this gate installs.
USERNAME=hamacctusr
HOSTNAME_=hamlaptop
UPASS=hamacctpw
RPASS=hamacctadmin

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  PASS  $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL  $*"; }
info() { echo "        $*"; }
say()  { echo; echo "== $* =="; }
finish() { printf '\n%d PASSED, %d FAILED\n' "$PASS" "$FAIL"
           [ "$FAIL" = 0 ] && exit 0 || exit 1; }

for t in qemu-system-x86_64 socat python3 tesseract convert curl; do
    command -v "$t" >/dev/null || { echo "INCONCLUSIVE: need $t"; exit 2; }
done
for t in /sbin/debugfs /sbin/sfdisk; do
    [ -x "$t" ] || { echo "INCONCLUSIVE: need $t"; exit 2; }
done
[ -f "$QMP_INPUT" ] || { echo "INCONCLUSIVE: need tests/linux/qmp_input.py"; exit 2; }
[ -f /usr/share/OVMF/OVMF_CODE_4M.fd ] || { echo "INCONCLUSIVE: need OVMF"; exit 2; }

# ---- reading an ext4 without mounting it ---------------------------------
# The idiom tests/linux/install_from_usb.sh and installed_offers_install.sh
# use: carve the partition out with dd and read it with debugfs. Nothing is
# mounted and nothing is written back, so no assertion here can be an artefact
# of this gate.
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
# `dump` and not `cat`: debugfs's `cat` truncates long files on this host, and
# a short read of /etc/passwd is the exact shape of a defect this gate hunts.
fs_dump() { rm -f "$3"; /sbin/debugfs -R "dump $2 $3" "$1" >/dev/null 2>&1; [ -s "$3" ]; }
# The owner uid of a path, or the empty string.
fs_uid()  { /sbin/debugfs -R "stat $2" "$1" 2>/dev/null |
            sed -n 's/.*User: *\([0-9][0-9]*\).*/\1/p' | head -1; }

# =========================================================================
# 0. THE CHANNEL, THE MEDIUM, AND ONE INSTALL ONTO A BLANK DISK
# =========================================================================
say "0 -- the channel, the medium, and one install onto a blank virtual disk"

# ---- the medium's own rc: it runs the installer and stops ----------------
cat >"$W/rc.install" <<RCEOF
ln -s /dev/console /dev/cons
echo 'INSTACCT-LIVE: the medium booted'
echo 'INSTACCT-LIVE: starting the installer'
install --auto /dev/nvme0n1 --hostname $HOSTNAME_ --user $USERNAME --user-pass $UPASS --root-pass $RPASS
echo 'INSTACCT-LIVE: the installer returned'
echo 'INSTACCT-LIVE-DONE'
sleep 8
poweroff
RCEOF

# ---- a free port on the host, for the channel the machine updates from ---
PORT="$(python3 - <<'PY'
import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()
PY
)"
BASE="http://10.0.2.2:$PORT/"

if [ "${INSTACCT_REUSE:-0}" = 1 ] && [ -f "$LIVE" ] && [ -s "$NVME" ] \
   && [ -f "$REPO/linux/index.json" ] && [ -f "$W/test.sec" ]; then
    info "reusing $LIVE, $NVME and $REPO (INSTACCT_REUSE=1)"
else
    info "building the medium (four passes plus a channel; this is the slow part)"
    scripts/hamlinux_image.sh >"$W/img1.log" 2>&1 || {
        bad "lean image build -- see $W/img1.log"; finish; }

    # THE CHANNEL. It is both what the disk's package database is emitted from
    # and what the machine updates against, so the two cannot disagree.
    rm -rf "$REPO"
    python3 scripts/hamlinux_packages.py --out "$REPO" --version "$NEWVER" \
        --channel linux --base-url "$BASE" >"$W/repo.log" 2>&1 || {
        bad "channel build -- see $W/repo.log"; finish; }
    [ -f "$REPO/linux/index.json" ] || { bad "the channel has no index"; finish; }
    info "channel: $NEWVER, $(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["packages"]))' "$REPO/linux/index.json") packages"

    # SIGN IT, and give the machine the key. `--allow-unsigned` would prove
    # the loop while proving nothing about the path a real machine takes.
    rm -rf "$EXTRA"; mkdir -p "$EXTRA/etc/hpm" "$EXTRA/var/lib/hpm"
    python3 scripts/hpm_sign.py keygen --out-pub "$EXTRA/etc/hpm/test-trusted.pub" \
        --out-sec "$W/test.sec" >/dev/null || { bad "cannot mint a signing key"; finish; }
    python3 scripts/hpm_sign.py sign "$REPO/linux/index.json" "$W/test.sec" \
        "$REPO/linux/index.json.sig" || { bad "cannot sign the local channel"; finish; }

    export HAMLINUX_HPM_CHANNEL="$REPO/linux"
    scripts/hamlinux_disk.sh "$W/seed.img" 3G >"$W/disk1.log" 2>&1 || {
        bad "seed disk build -- see $W/disk1.log"; finish; }
    HAMLINUX_INSTALLER=1 scripts/hamlinux_image.sh >"$W/img2.log" 2>&1 || {
        bad "installer image build -- see $W/img2.log"; finish; }
    grep -q 'INCOMPLETE' "$W/img2.log" && bad "the medium's /usr/lib/instroot is INCOMPLETE -- see $W/img2.log"

    # ---- THE MACHINE'S OWN BOOT rc, WHICH IS HOW THE UPDATE GETS RUN -----
    # It is staged as etc/rc.boot.machine on the MEDIUM, because that is the
    # file user/hlinstall.ad copies to the target as /etc/rc.boot -- the
    # machine's own boot script, which no package owns and hpm must not
    # touch. So the driver of this gate survives the very update it is
    # driving, which a hook spliced into the package-owned
    # /etc/rc.boot.installed would not (that file IS replaced by the
    # hamnix-init upgrade below, deliberately).
    #
    # TWO PHASES OUT OF ONE FILE, with no `else`: sourcing a file that does
    # not exist returns non-zero, so phase 1 runs while the marker is absent
    # and writes it.
    cat >"$EXTRA/etc/rc.boot.machine" <<RCEOF
# /etc/rc.boot -- the boot script of THIS MACHINE.
# Staged onto the medium by tests/linux/installed_accounts.sh and copied here
# by the installer. Owned by no package: that is the point.
source '/etc/rc.boot.installed'
source '/var/lib/instacct.done'
if \$status > 0 {
    echo 'INSTACCT-P1: first boot of the installed machine'
    id
    dhcpc
    echo 'INSTACCT-P1: dhcpc status:' \$status
    hpm --repo=$BASE --trusted-key=/etc/hpm/test-trusted.pub update
    echo 'INSTACCT-P1: update status:' \$status
    hpm list
    echo "# phase 2: boot normally" > /var/lib/instacct.done
    echo 'INSTACCT-P1-DONE'
    # SLEEP, THEN POWER OFF FROM INSIDE. ext4 commits its journal on a timer
    # and killing QEMU is a power cut: the marker (and everything the update
    # wrote) has to be flushed by a real shutdown or the next boot repeats
    # phase 1, which reads exactly like "the disk is not persistent".
    sleep 8
    poweroff
}
echo 'INSTACCT-P2: this machine has been updated and rebooted'
RCEOF

    # ---- THE PACKAGE DATABASE, DOCTORED SO THE UPDATE HAS WORK TO DO -----
    # The disk builder emits a database recording every package this tree
    # carries AT THIS CHANNEL'S VERSION, so a correct `hpm update` against
    # that same channel legitimately has nothing to do -- and "upgraded=0" is
    # the output a broken machine produces too. hamnix-init is recorded one
    # version behind instead: it is the package that OWNS etc/passwd and
    # etc/group, so it is exactly the upgrade that used to take the machine's
    # accounts. Its file LISTS are untouched -- they come from the tarballs.
    DB_SRC="build/image/disk/rootdir/var/lib/hpm/installed.json"
    [ -s "$DB_SRC" ] || { bad "the seed disk left no package database at $DB_SRC"; finish; }
    python3 - "$DB_SRC" "$EXTRA/var/lib/hpm/installed.json" <<'PYEOF' || { bad "could not doctor the package database"; finish; }
import json, sys
db = json.load(open(sys.argv[1]))
pkgs = db["packages"]
rows = pkgs if isinstance(pkgs, list) else [dict(v, name=k) for k, v in pkgs.items()]
hit = 0
for r in rows:
    if r.get("name") == "hamnix-init":
        r["version"] = "0.9.0"
        hit += 1
if hit != 1:
    print("hamnix-init appears %d times in the database" % hit)
    sys.exit(1)
if not isinstance(pkgs, list):
    db["packages"] = {r["name"]: {k: v for k, v in r.items() if k != "name"} for r in rows}
json.dump(db, open(sys.argv[2], "w"), indent=2)
PYEOF
    ok "the medium's package database records hamnix-init one version behind the channel, so the update has real work to do"

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

# ---- the install boot: no display, serial only ---------------------------
if [ "${INSTACCT_REUSE:-0}" != 1 ] || [ ! -f "$W/install/serial.log" ]; then
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
        -device nvme,drive=nvme0,serial=INSTACCTTGT \
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
if grep -aq 'INSTACCT-LIVE-DONE' "$W/install/serial.log" 2>/dev/null; then
    ok "the installer ran to completion on the live medium"
else
    bad "the install boot never printed INSTACCT-LIVE-DONE -- nothing below is a statement about an installed machine"
    tail -20 "$W/install/serial.log" 2>/dev/null | sed 's/^/        /'
    finish
fi

# THE INSTALLER'S OWN REPORT OF THE PASSWORD IT HASHED. A locked account is
# what defect 3 produced, and the installer says so when it happens.
if grep -aq 'could not hash the password' "$W/install/serial.log"; then
    bad "the installer could not hash the account password on this medium -- the account is LOCKED and the wizard's password was collected and discarded"
else
    ok "the installer did not report a hashing failure for the account password"
fi
if grep -aq 'could not hash the administrator password' "$W/install/serial.log"; then
    bad "the installer could not hash the ADMINISTRATOR password -- the machine keeps the medium's published hostowner password"
else
    ok "the installer did not report a hashing failure for the administrator password"
fi

# =========================================================================
# 1. WHAT THE INSTALLED ROOT CARRIES, BEFORE ANY UPDATE
# =========================================================================
say "1 -- the account table on the installed disk (debugfs, nothing mounted)"
carve "$NVME" 2 || { bad "cannot carve the installed root partition"; finish; }

# INSTRUMENT CONTROL FIRST. An answer from a reader that answers the same way
# to everything is not a measurement.
if fs_has "$PART" /etc/hamnix-release; then
    ok "the reader finds /etc/hamnix-release on the installed root, so what it reports below is a reading and not a broken reader"
else
    bad "the reader cannot find /etc/hamnix-release on the installed root -- it is not working, and nothing it reports means anything"
    finish
fi

# check_accounts <tag> -- every account assertion, run twice: once on the
# freshly installed disk and once after `hpm update`. Identical text both
# times, deliberately: the whole question is whether the answer CHANGED.
check_accounts() {
    local tag="$1" f
    for f in passwd group shadow; do
        fs_dump "$PART" "/etc/$f" "$W/$tag-$f" \
            || { bad "$tag: could not read /etc/$f off the installed root"; return 1; }
    done
    # The doubled-header shape of the 962-byte defect, checked by arithmetic
    # rather than by eye.
    for f in passwd group shadow; do
        if python3 - "$W/$tag-$f" <<'PY'
import sys
b = open(sys.argv[1], "rb").read()
h = (len(b) - 2) // 2
sys.exit(0 if len(b) > 2 and b[:h] == b[h + 1:2 * h + 1] else 1)
PY
        then
            bad "$tag: /etc/$f is its own first half written TWICE ($(stat -c%s "$W/$tag-$f") bytes)"
        else
            ok "$tag: /etc/$f is not the doubled-header shape ($(stat -c%s "$W/$tag-$f") bytes)"
        fi
    done

    grep -q "^$USERNAME:x:1001:1001::/home/$USERNAME:" "$W/$tag-passwd" \
        && ok "$tag: /etc/passwd carries $USERNAME at uid 1001 with home /home/$USERNAME -- the uid the desktop session runs as" \
        || bad "$tag: /etc/passwd has no '$USERNAME:x:1001:1001::/home/$USERNAME' line. It has: $(grep -v '^#' "$W/$tag-passwd" | tr '\n' ' ' | cut -c1-200)"
    grep -q "^$USERNAME:x:1001:" "$W/$tag-group" \
        && ok "$tag: /etc/group carries the $USERNAME group at gid 1001" \
        || bad "$tag: /etc/group has no $USERNAME group -- the account's own group is gone"
    # awk, NOT grep. The obvious `grep "^$USERNAME:\$6\$"` reads its trailing
    # backslash-dollar as the END-OF-LINE ANCHOR in a BRE, so it demands a line
    # that stops after the 6 and can never match a hash. MEASURED: it reported
    # "no $6$ hash" for a machine whose hash this gate PRINTED on the same
    # line. The instrument was wrong and the only reason it was caught is that
    # the failure message quotes what was read.
    if awk -F: -v u="$USERNAME" '$1==u && $2 ~ /^[$]6[$]/ {f=1} END{exit !f}' "$W/$tag-shadow"; then
        ok "$tag: /etc/shadow carries a real \$6\$ SHA-512 hash for $USERNAME"
    else
        bad "$tag: /etc/shadow has no \$6\$ hash for $USERNAME -- the password the wizard collected is not on this machine: $(grep "^$USERNAME:" "$W/$tag-shadow" | cut -c1-40)"
    fi

    # NAMES AND HASHES TOGETHER, WHICH IS THE POINT. A machine with one and
    # not the other is worse than a machine with neither, so the two files are
    # asserted against each other rather than separately.
    if python3 - "$W/$tag-passwd" "$W/$tag-shadow" <<'PY'
import sys
def names(p):
    out = set()
    for line in open(p):
        line = line.strip()
        if line and not line.startswith("#") and ":" in line:
            out.add(line.split(":", 1)[0])
    return out
pw, sh = names(sys.argv[1]), names(sys.argv[2])
sys.exit(0 if sh <= pw else 1)
PY
    then
        ok "$tag: every name in /etc/shadow is a name in /etc/passwd -- no orphaned password hashes"
    else
        bad "$tag: /etc/shadow holds a hash for a name /etc/passwd does not have -- this is the 'hashes without names' state: $(python3 -c '
import sys
def names(p):
    return set(l.split(":",1)[0] for l in open(p) if l.strip() and not l.startswith("#") and ":" in l)
print(sorted(names(sys.argv[2]) - names(sys.argv[1])))' "$W/$tag-passwd" "$W/$tag-shadow")"
    fi

    # THE PUBLISHED CREDENTIALS MUST NOT SURVIVE THE INSTALL. hostowner, dave
    # and live all have hashes in etc/shadow IN THE SOURCE TREE.
    grep -q '^live:' "$W/$tag-passwd" \
        && bad "$tag: /etc/passwd still carries the live medium's own 'live' account -- its password is published in the source tree, and it competes with $USERNAME for uid 1001" \
        || ok "$tag: the live medium's 'live' account is not on this machine"
    grep -q '^dave:' "$W/$tag-passwd" \
        && bad "$tag: /etc/passwd still carries the 'dave' auth fixture from the source tree, at uid 1000, with a published password" \
        || ok "$tag: the source tree's 'dave' fixture account is not on this machine"
    if grep -q '^hostowner:' "$W/$tag-shadow"; then
        if grep -qF "$(grep '^hostowner:' "$PROJ_ROOT/etc/shadow")" "$W/$tag-shadow"; then
            bad "$tag: the hostowner password hash on this machine is the SOURCE TREE's, character for character -- the administrator password the wizard collected was discarded"
        else
            ok "$tag: the hostowner hash is NOT the source tree's -- the administrator password the wizard collected is what this machine has"
        fi
    else
        bad "$tag: there is no hostowner line in /etc/shadow at all"
    fi

    # THE HOME, WHICH IS WHAT MAKES THE NAME A SESSION.
    if fs_has "$PART" "/home/$USERNAME/Desktop/terminal.desktop"; then
        ok "$tag: /home/$USERNAME/Desktop carries the desktop launchers -- the account has a real home, not an empty directory"
    else
        bad "$tag: /home/$USERNAME/Desktop/terminal.desktop is not there -- the account's home is empty and the desktop will fall back to somebody else's"
    fi
    local u
    u="$(fs_uid "$PART" "/home/$USERNAME")"
    if [ "${u:-}" = 1001 ]; then
        ok "$tag: /home/$USERNAME is owned by uid 1001 -- the session can write its own home"
    else
        bad "$tag: /home/$USERNAME is owned by uid ${u:-?}, not 1001 -- the session user cannot write its own home"
    fi
    u="$(fs_uid "$PART" "/home/$USERNAME/Desktop/terminal.desktop")"
    if [ "${u:-}" = 1001 ]; then
        ok "$tag: the files inside the home are owned by uid 1001 too"
    else
        bad "$tag: the files inside the home are owned by uid ${u:-?}, not 1001"
    fi
    if fs_has "$PART" "/etc/users/$USERNAME.ns"; then
        ok "$tag: /etc/users/$USERNAME.ns exists, so this user's shell does not fall back to Hamnix's default.ns (every line of which fails EPERM on this kernel)"
    else
        bad "$tag: there is no /etc/users/$USERNAME.ns -- every login prints a screenful of EPERM from default.ns"
    fi
    fs_dump "$PART" /etc/hostname "$W/$tag-hostname" && \
        grep -q "^$HOSTNAME_" "$W/$tag-hostname" \
        && ok "$tag: /etc/hostname is still '$HOSTNAME_', the name the wizard was given" \
        || bad "$tag: /etc/hostname is not '$HOSTNAME_' -- it says: $(cat "$W/$tag-hostname" 2>/dev/null | head -1)"
    return 0
}

check_accounts installed

# THE ACCOUNT ASSERTIONS' OWN CONTROL, AND IT RUNS. The medium's /etc/passwd
# is the file the copy starts from: it must carry `live` (so the reader really
# reads account files) and must NOT carry the wizard's user (so finding that
# name on the target means the INSTALL put it there, and not the image).
carve "$LIVE" 2 || { bad "cannot carve the live medium's root partition"; finish; }
if fs_dump "$PART" /etc/passwd "$W/medium-passwd"; then
    grep -q '^live:' "$W/medium-passwd" \
        && ok "the medium's own /etc/passwd carries 'live', so the account reader reads accounts" \
        || bad "the medium's /etc/passwd has no 'live' line -- the reader is not reading a passwd file and every assertion above is meaningless"
    grep -q "^$USERNAME:" "$W/medium-passwd" \
        && bad "the medium ALREADY carries a $USERNAME account -- finding it on the target would prove nothing about the installer" \
        || ok "and the medium does NOT carry $USERNAME, so that name on the target can only have come from the install"
else
    bad "could not read /etc/passwd off the live medium"
fi
rm -f "$PART"

# =========================================================================
# 2. THE UPDATE, ON THE MACHINE, AND THE SAME QUESTIONS AFTERWARDS
# =========================================================================
say "2 -- the machine updates itself, and the accounts are read again"

python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$REPO" \
    >"$W/http.log" 2>&1 &
HTTPD=$!
cleanup() { kill "$HTTPD" 2>/dev/null; wait "$HTTPD" 2>/dev/null; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
sleep 1
curl -fsS "http://127.0.0.1:$PORT/linux/index.json" >/dev/null \
    && ok "the local channel is served at $BASE" \
    || { bad "the local channel is not being served"; finish; }

d="$W/update"; rm -rf "$d"; mkdir -p "$d"
cp /usr/share/OVMF/OVMF_VARS_4M.fd "$d/OVMF_VARS.fd"
qemu-system-x86_64 \
    -m 2048 -smp 2 -no-reboot \
    -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
    -drive "if=pflash,format=raw,unit=1,file=$d/OVMF_VARS.fd" \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -display none -vga none -device virtio-gpu-pci \
    -serial "file:$d/serial.log" -enable-kvm -cpu host \
    -drive "file=$NVME,if=none,format=raw,id=nvme0" \
    -device nvme,drive=nvme0,serial=INSTACCTTGT \
    >"$d/qemu.out" 2>&1 &
UPID=$!
reap_add "$UPID"
i=0
while kill -0 "$UPID" 2>/dev/null && [ "$i" -lt 900 ]; do sleep 5; i=$((i+5)); done
kill -TERM "$UPID" 2>/dev/null; sleep 2; kill -KILL "$UPID" 2>/dev/null
wait "$UPID" 2>/dev/null

if grep -aq 'INSTACCT-P1-DONE' "$d/serial.log" 2>/dev/null; then
    ok "the installed machine booted on its own and ran the update to completion"
else
    bad "the installed machine never printed INSTACCT-P1-DONE -- no update was measured"
    tail -25 "$d/serial.log" 2>/dev/null | sed 's/^/        /'
fi
UPG="$(grep -a 'hpm: update done' "$d/serial.log" | head -1 | sed 's/.*upgraded=\([0-9]*\).*/\1/')"
if [ "${UPG:-0}" -ge 1 ] 2>/dev/null; then
    ok "the update really upgraded ${UPG} package(s) -- it is not a no-op that exits 0"
else
    bad "the update reported upgraded=${UPG:-?}: the database recorded hamnix-init one version behind, so a working update has one to do. Nothing below is a statement about what an update does to the accounts"
fi
grep -a 'hpm: upgrading hamnix-init' "$d/serial.log" | head -1 | sed 's/^/        /'
if grep -aq 'hpm: upgrading hamnix-init' "$d/serial.log"; then
    ok "and the package it upgraded is hamnix-init, the one that SHIPS etc/passwd and etc/group"
else
    bad "hamnix-init was not upgraded, so this run says nothing about what an update does to the account files"
fi
# THE PACKAGE MANAGER SAYS SO WHEN IT KEEPS A MACHINE'S FILE. This is hpm's
# own report and not the measurement -- the measurement is the disk, below.
for f in etc/passwd etc/group; do
    grep -aq "keeping this machine's own /$f" "$d/serial.log" \
        && ok "hpm reported keeping this machine's own /$f" \
        || info "hpm printed no 'keeping this machine's own /$f' line (the disk below is what decides)"
done

say "2b -- THE SAME ACCOUNT ASSERTIONS, ON THE SAME DISK, AFTER THE UPDATE"
carve "$NVME" 2 || { bad "cannot carve the installed root partition after the update"; finish; }
fs_has "$PART" /etc/hamnix-release \
    && ok "the reader still finds /etc/hamnix-release after the update" \
    || { bad "the reader cannot read the post-update disk"; finish; }
check_accounts updated

# AND THE UPDATE REALLY DID REPLACE THE FILES IT OWNS. Without this, "the
# accounts survived" could mean "hpm wrote nothing at all".
if fs_dump "$PART" /etc/rc.boot.installed "$W/updated-rcbootinstalled"; then
    if cmp -s "$W/updated-rcbootinstalled" "$PROJ_ROOT/etc/rc.boot.installed"; then
        ok "the update DID lay down the package's own /etc/rc.boot.installed -- so hpm was writing files on this machine, and skipped the account files deliberately"
    else
        bad "/etc/rc.boot.installed on the machine is not the one this tree ships, so it is not clear the upgrade wrote anything"
    fi
else
    bad "there is no /etc/rc.boot.installed on the machine after the update"
fi
if fs_dump "$PART" /etc/rc.boot "$W/updated-rcboot"; then
    grep -q 'INSTACCT-P1' "$W/updated-rcboot" \
        && ok "and /etc/rc.boot is still THIS MACHINE's own boot script, untouched by the upgrade" \
        || bad "/etc/rc.boot was replaced by the upgrade -- the machine lost its own boot script"
else
    bad "there is no /etc/rc.boot on the machine after the update"
fi
rm -f "$PART"

# =========================================================================
# 3. WHOSE SESSION IS IT? THE MACHINE, BOOTED TO ITS DESKTOP, AFTER THE UPDATE
# =========================================================================
say "3 -- the desktop, after the update, read as a picture and as a log"

D="$W/boot-desktop"; rm -rf "$D"; mkdir -p "$D/shots"
cp /usr/share/OVMF/OVMF_VARS_4M.fd "$D/OVMF_VARS.fd"
qemu-system-x86_64 \
    -m 2048 -smp 2 -no-reboot \
    -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
    -drive "if=pflash,format=raw,unit=1,file=$D/OVMF_VARS.fd" \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -display none -vga std \
    -serial "file:$D/serial.log" \
    -enable-kvm -cpu host \
    -monitor "unix:$D/mon.sock,server,nowait" \
    -qmp "unix:$D/qmp.sock,server,nowait" \
    -device virtio-keyboard-pci -device virtio-tablet-pci \
    -drive "file=$NVME,if=none,format=raw,id=nvme0" \
    -device nvme,drive=nvme0,serial=INSTACCTTGT \
    >"$D/qemu.out" 2>&1 &
QPID=$!
reap_add "$QPID"
info "qemu pid $QPID, serial $D/serial.log"

BOOT_SECS=0
i=0
while [ "$i" -lt 240 ]; do
    sleep 2; i=$((i+2))
    grep -aq 'rc\.boot: up' "$D/serial.log" 2>/dev/null && break
    # A ZOMBIE ANSWERS YES TO kill -0, so liveness comes from the state letter.
    st=$(awk '{print $3}' "/proc/$QPID/stat" 2>/dev/null)
    case "${st:-X}" in Z|X) break ;; esac
done
BOOT_SECS=$i
if grep -aq 'rc\.boot: up' "$D/serial.log" 2>/dev/null; then
    ok "the updated machine reached 'rc.boot: up' after ${BOOT_SECS}s"
else
    bad "the updated machine never printed 'rc.boot: up' in ${BOOT_SECS}s -- it did not reach a desktop"
    tail -25 "$D/serial.log" 2>/dev/null | sed 's/^/        /'
fi

# ---- WHOSE IDENTITY THE SESSION SHELL DROPPED TO ------------------------
# etc/rc.d/rc.5 pre-warms /etc/rc.de-user on every graphical boot, and
# `setuid` prints the uid it reached AND the home it resolved for that uid out
# of /etc/passwd (user/hamsh.ad:builtin_setuid). That line is the DE session
# shell's own statement of who it is.
SESSLINE="$(grep -a 'uid 1001 home ' "$D/serial.log" | head -1)"
info "session line: ${SESSLINE:-<none>}"
if printf '%s' "$SESSLINE" | grep -q "home /home/$USERNAME"; then
    ok "the DE session dropped to uid 1001 and resolved HOME=/home/$USERNAME -- the session is the account the wizard created"
elif printf '%s' "$SESSLINE" | grep -q 'home /home/live'; then
    bad "the DE session dropped to uid 1001 and resolved HOME=/home/live -- the session on this machine is still the live medium's user, and $USERNAME has no session"
else
    bad "no 'uid 1001 home ...' line in the boot log: the DE session's identity was not reported at all"
fi

sleep 8
hmp() { printf '%s\n' "$1" | timeout 20 socat - "UNIX-CONNECT:$D/mon.sock" 2>/dev/null; }
shot() {
    local p="$D/shots/$1.ppm" prev=-1 n i=0
    rm -f "$p"
    hmp "screendump $p" >/dev/null
    while [ "$i" -lt 40 ]; do
        sleep 0.25; i=$((i+1))
        n=$(stat -c%s "$p" 2>/dev/null || echo 0)
        [ "$n" -gt 0 ] && [ "$n" = "$prev" ] && break
        prev="$n"
    done
    [ -s "$p" ] || return 1
    printf '%s' "$p"
}
ocr() {
    convert "$1" -crop "$3" +repage -colorspace Gray -resize 300% \
        -sharpen 0x1 "$2.png" 2>/dev/null || return 1
    tesseract "$2.png" "$2" --psm 6 >/dev/null 2>&1 || return 1
    [ -s "$2.txt" ]
}
PANEL_GEOM="${SCREEN_W}x28+0+0"
ICONS_GEOM="220x760+0+28"

if P=$(shot desktop); then
    info "screendump $(stat -c%s "$P") bytes"
    if ocr "$P" "$D/shots/panel" "$PANEL_GEOM"; then
        PANEL=$(cat "$D/shots/panel.txt")
        info "panel OCR: $(printf '%s' "$PANEL" | tr '\n' '|' | cut -c1-140)"
        printf '%s' "$PANEL" | grep -qi 'applic' \
            && ok "the panel reads 'Applications', so this machine reached a desktop and the OCR can read it" \
            || bad "the panel does not read 'Applications' -- either no desktop or no working OCR"
        printf '%s' "$PANEL" | grep -qi 'Step 5 of 5' \
            && bad "the panel OCR reports text that is certainly not on the screen -- it matches anything" \
            || ok "the panel OCR does NOT report text that is not there"
    else
        bad "the panel strip could not be OCR'd"
    fi
    if ocr "$P" "$D/shots/icons" "$ICONS_GEOM"; then
        ICONS=$(cat "$D/shots/icons.txt")
        info "icon OCR: $(printf '%s' "$ICONS" | tr '\n' ' ' | cut -c1-200)"
        n=0
        for lbl in Calculator Terminal Files Notes Calendar; do
            printf '%s' "$ICONS" | grep -qi "$lbl" && n=$((n+1))
        done
        if [ "$n" -ge 3 ]; then
            ok "$n of 5 sampled launcher labels read back off the desktop -- the icon grid is a real directory listing"
        else
            bad "only $n of 5 sampled launcher labels read back -- the desktop is not showing a populated ~/Desktop"
        fi
    else
        bad "the desktop icon column could not be OCR'd"
    fi
else
    bad "no screendump could be taken -- nothing about this machine's picture was measured"
fi

printf 'quit\n' | timeout 10 socat - "UNIX-CONNECT:$D/mon.sock" >/dev/null 2>&1
sleep 2
kill -TERM "$QPID" 2>/dev/null; sleep 1; kill -KILL "$QPID" 2>/dev/null
wait "$QPID" 2>/dev/null

# ---- WHICH DIRECTORY THE DESKTOP ACTUALLY WATCHED -----------------------
# user/hamdesktop.ad resolves its directory through the shared chain ($HOME ->
# passwd by uid -> the first regular account with a ~/Desktop) and now names
# the winner in its log. The log is on the disk, so it is read the same way
# everything else here is read.
say "3b -- the directory the desktop resolved, read off the disk"
carve "$NVME" 2 || { bad "cannot carve the installed root after the desktop boot"; finish; }
if fs_dump "$PART" /var/log/hamdesktop.log "$W/hamdesktop.log"; then
    DLINE="$(grep -a 'desktop directory' "$W/hamdesktop.log" | head -1)"
    info "hamdesktop log: ${DLINE:-<no directory line>}"
    if printf '%s' "$DLINE" | grep -q "/home/$USERNAME/Desktop"; then
        ok "the desktop watched /home/$USERNAME/Desktop -- the icons on that screen are the account's own"
    elif printf '%s' "$DLINE" | grep -q '/home/live/Desktop'; then
        bad "the desktop watched /home/live/Desktop -- on a machine whose user is $USERNAME. Nothing they put on their desktop appears, and nothing on the screen is theirs"
    else
        bad "hamdesktop's log does not say which directory it resolved: ${DLINE:-<none>}"
    fi
else
    bad "could not read /var/log/hamdesktop.log off the disk"
fi
rm -f "$PART"

info "evidence: $W"
finish
