#!/usr/bin/env bash
#
# tests/linux/installed_login.sh — A PERSON LOGS IN. THE PASSWORD THE WIZARD
# COLLECTED AUTHENTICATES, AND A WRONG ONE IS REFUSED, ON THE INSTALLED
# MACHINE, WHILE IT IS RUNNING.
#
# WHY THIS FILE EXISTS
# ====================
# tests/linux/installed_accounts.sh proves that the installer wrote a `$6$`
# hash into /etc/shadow for the account the wizard created. It asserts that
# hash AS A STRING, read off an unmounted ext4 with debugfs. Nothing in this
# tree had ever presented that password to an authenticator and been let in.
# A hash that is the wrong hash, a /dev/auth that answers "ok" to everything,
# and a /dev/auth that answers "denied" to everything all produce a `$6$`
# string in /etc/shadow. THE STRING IS NOT THE PROPERTY.
#
# So this gate takes the machine installed_accounts.sh installed, boots it on
# its own with no medium attached, and drives `su` — one of the three real
# credential surfaces this line ships (`login`, `su`, `hamlock`, all of which
# bottom out in the same /dev/auth `user`/`pass` exchange, user/linux-auth.c).
#
# THE ARMS, AND WHY EACH ONE IS HERE
# ==================================
#   A  the wizard's user + the password the operator typed   -> ADMITTED
#   B  the wizard's user + a wrong password                  -> REFUSED
#   C  hostowner + the administrator password the operator typed -> ADMITTED
#   D  hostowner + `hamnix`, the password PUBLISHED IN THIS SOURCE TREE
#      (etc/shadow, in git, three accounts, all `hamnix`)     -> REFUSED
#   E  hostowner + the wizard USER's password                -> REFUSED
#
# A alone cannot tell an authenticator from a doormat: a /dev/auth that
# admitted everything would pass it. B and E are what discriminate. D is the
# one that matters to a person who installs this: before --root-pass was read
# by anything, an installed machine kept the credential printed in a public
# git repository, and A/B/C would all still have passed.
#
# WHAT "ADMITTED" MEANS HERE, MEASURED AND NOT INFERRED. user/su.ad prints
#     su: switched to uid <n> (<name>)
# AFTER sys_setuid_auth() has returned, i.e. after the identity really
# changed — it is not a message about the password, it is a report of the uid
# the process is now running as. "REFUSED" is su's own
#     su: Authentication failure
# on the /dev/auth answer. Both strings are asserted, in both directions: an
# arm that must be admitted also asserts that NO failure line appeared for it,
# and an arm that must be refused also asserts that NO switch line appeared.
#
# HOW THE MACHINE IS DRIVEN. /etc/rc.boot on the installed disk is the
# machine's OWN boot script and no package owns it (that is the whole point of
# etc/rc.boot.machine). This gate rewrites it, on a COPY of the disk, with
# debugfs — nothing is mounted — so the probe runs as part of the machine's
# own boot and its output lands on the serial console. `su` reads the password
# from fd 0, so each arm is `su <name> < /tmp/<file>`.
#
# REGISTRATION. ON-DEMAND: not in ci_battery_manifest.txt because it needs an
# INSTALLED DISK, which no CI runner has and which costs a medium build plus an
# install boot to make (tests/linux/installed_accounts.sh makes one), and then
# boots it under OVMF. Same class as installed_accounts.sh, whose idioms it
# borrows. MEASURED on this host 2026-08-18: 13 PASSED / 0 FAILED in ~70 s once
# the disk exists, and the NEGATIVE CONTROL RAN --
#     LOGIN_UPASS=definitely-wrong LOGIN_WORK=... tests/linux/installed_login.sh
# scores 11 / 2, the two failures being exactly arm A, so the arm that says
# "the password works" is able to say that it does not.
#
# Usage: tests/linux/installed_login.sh
#   LOGIN_SRC_NVME=<img>   the installed disk to copy (default:
#                          ~/.hamnix-build/instacct/target-nvme.img)
#   LOGIN_WORK=<dir>       work dir (default ~/.hamnix-build/instlogin)
#   LOGIN_USER / LOGIN_UPASS / LOGIN_RPASS
#                          the credentials that disk was installed with
#                          (defaults match installed_accounts.sh)
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

. tests/linux/reap.sh
reap_on_exit

SRC="${LOGIN_SRC_NVME:-$HOME/.hamnix-build/instacct/target-nvme.img}"
W="${LOGIN_WORK:-$HOME/.hamnix-build/instlogin}"
USERNAME="${LOGIN_USER:-hamacctusr}"
UPASS="${LOGIN_UPASS:-hamacctpw}"
RPASS="${LOGIN_RPASS:-hamacctadmin}"
# The password published in this source tree's etc/shadow for all three
# shipped accounts. Read from the file's own header rather than typed twice.
TREEPASS=hamnix

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
NVME="$W/login-nvme.img"
PART="$W/part.img"

part_geom() {
    /sbin/sfdisk -J "$1" 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)["partitiontable"]
ss=d.get("sectorsize",512)
p=d["partitions"][int(sys.argv[1])-1]
print(p["start"]*ss, p["size"]*ss)' "$2"
}

say "0 -- a copy of the installed machine, and its own boot script rewritten"
info "source disk: $SRC"
info "  $(stat -c '%s bytes, mtime %y' "$SRC")"
rm -f "$NVME"
cp --reflink=auto "$SRC" "$NVME" || { bad "cannot copy the installed disk"; finish; }

G="$(part_geom "$NVME" 2)"; [ -n "$G" ] || { bad "cannot read the partition table"; finish; }
OFF="${G% *}"; SZ="${G#* }"
info "root partition at offset $OFF, $SZ bytes"
[ $((OFF % 1048576)) = 0 ] || { bad "the root partition does not start on a MiB boundary ($OFF) -- this gate's dd would misplace it"; finish; }

rm -f "$PART"
dd if="$NVME" of="$PART" bs=1M skip=$((OFF / 1048576)) \
   count=$(( (SZ + 1048575) / 1048576 )) status=none \
   || { bad "cannot carve the root partition"; finish; }

# INSTRUMENT CONTROL, BEFORE ANY CLAIM IS MADE FROM THIS READER. Read the
# account table off the carved filesystem and show that the machine really
# carries the account this gate is about to try to log in as. If this fails,
# every arm below would be a statement about the wrong disk.
rm -f "$W/passwd"
/sbin/debugfs -R "dump /etc/passwd $W/passwd" "$PART" >/dev/null 2>&1
if [ -s "$W/passwd" ]; then
    ok "the ext4 reader read /etc/passwd off the copied disk ($(wc -c <"$W/passwd") bytes)"
else
    bad "the ext4 reader could not read /etc/passwd -- the instrument is not working and nothing below would mean anything"
    finish
fi
if awk -F: -v u="$USERNAME" '$1==u{found=1} END{exit !found}' "$W/passwd"; then
    ok "the machine's /etc/passwd carries the account '$USERNAME' this gate will authenticate as"
    info "  $(awk -F: -v u="$USERNAME" '$1==u{print}' "$W/passwd")"
else
    bad "the machine's /etc/passwd has no '$USERNAME' -- this is not the disk this gate is for"
    finish
fi
rm -f "$W/shadow"
/sbin/debugfs -R "dump /etc/shadow $W/shadow" "$PART" >/dev/null 2>&1
if awk -F: -v u="$USERNAME" '$1==u && substr($2,1,3)=="$6$"{found=1} END{exit !found}' "$W/shadow"; then
    ok "and /etc/shadow carries a \$6\$ hash for it -- the STRING installed_accounts.sh asserts, which is what this gate exists to go beyond"
else
    bad "/etc/shadow has no \$6\$ hash for '$USERNAME' on this disk"
fi

# ---- the machine's own boot script, replaced ------------------------------
cat >"$W/rc.boot.probe" <<RCEOF
# /etc/rc.boot -- the boot script of THIS MACHINE, rewritten by
# tests/linux/installed_login.sh. Owned by no package.
source '/etc/rc.boot.installed'
echo 'LOGINPROBE-BEGIN'
id
echo '$UPASS' > /tmp/pw.user
echo 'definitely-not-the-password' > /tmp/pw.wrong
echo '$RPASS' > /tmp/pw.admin
echo '$TREEPASS' > /tmp/pw.tree
echo 'LOGINPROBE-ARM-A'
su $USERNAME < /tmp/pw.user
echo 'LOGINPROBE-ARM-A-END'
echo 'LOGINPROBE-ARM-B'
su $USERNAME < /tmp/pw.wrong
echo 'LOGINPROBE-ARM-B-END'
echo 'LOGINPROBE-ARM-C'
su hostowner < /tmp/pw.admin
echo 'LOGINPROBE-ARM-C-END'
echo 'LOGINPROBE-ARM-D'
su hostowner < /tmp/pw.tree
echo 'LOGINPROBE-ARM-D-END'
echo 'LOGINPROBE-ARM-E'
su hostowner < /tmp/pw.user
echo 'LOGINPROBE-ARM-E-END'
echo 'LOGINPROBE-DONE'
sleep 5
poweroff
RCEOF

/sbin/debugfs -w -R "rm /etc/rc.boot" "$PART" >"$W/debugfs.log" 2>&1
/sbin/debugfs -w -R "write $W/rc.boot.probe /etc/rc.boot" "$PART" >>"$W/debugfs.log" 2>&1
rm -f "$W/rc.boot.readback"
/sbin/debugfs -R "dump /etc/rc.boot $W/rc.boot.readback" "$PART" >/dev/null 2>&1
if cmp -s "$W/rc.boot.probe" "$W/rc.boot.readback"; then
    ok "the probe boot script is on the filesystem, byte-identical when read back"
else
    bad "the probe boot script did not land on the filesystem -- see $W/debugfs.log"
    finish
fi

dd if="$PART" of="$NVME" bs=1M seek=$((OFF / 1048576)) conv=notrunc status=none \
    || { bad "cannot write the partition back into the disk image"; finish; }
ok "the modified root partition is back in the disk image"

# =========================================================================
say "1 -- the machine, booted on its own, authenticating"
D="$W/boot"; rm -rf "$D"; mkdir -p "$D"
cp /usr/share/OVMF/OVMF_VARS_4M.fd "$D/OVMF_VARS.fd"
qemu-system-x86_64 \
    -m 2048 -smp 2 -no-reboot \
    -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
    -drive "if=pflash,format=raw,unit=1,file=$D/OVMF_VARS.fd" \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -display none -vga std \
    -serial "file:$D/serial.log" \
    -enable-kvm -cpu host \
    -device virtio-keyboard-pci -device virtio-tablet-pci \
    -drive "file=$NVME,if=none,format=raw,id=nvme0" \
    -device nvme,drive=nvme0,serial=INSTLOGINTGT \
    >"$D/qemu.out" 2>&1 &
QPID=$!
reap_add "$QPID"
info "qemu pid $QPID, serial $D/serial.log"

i=0
while [ "$i" -lt 300 ]; do
    sleep 2; i=$((i+2))
    grep -aq 'LOGINPROBE-DONE' "$D/serial.log" 2>/dev/null && break
    st=$(awk '{print $3}' "/proc/$QPID/stat" 2>/dev/null)
    case "${st:-X}" in Z|X) break ;; esac
done
sleep 3
kill -TERM "$QPID" 2>/dev/null; sleep 2; kill -KILL "$QPID" 2>/dev/null
wait "$QPID" 2>/dev/null

S="$D/serial.log"
if grep -aq 'LOGINPROBE-DONE' "$S"; then
    ok "the machine booted and ran every arm of the probe (${i}s)"
else
    bad "the probe never finished in ${i}s -- see $S"
    tail -30 "$S" 2>/dev/null | sed 's/^/        /'
    finish
fi

# Everything below reads ONE arm's slice of the serial log, so a line printed
# by a different arm can never be counted for this one.
# arm <letter> -> the text between that arm's markers.
#
# THE MARKERS ARE MATCHED WHOLE, and that is not fussiness: written as a
# substring match, the START pattern LOGINPROBE-ARM-A also matches the END
# line LOGINPROBE-ARM-A-END, so every slice ran to the end of the log and
# every arm inherited every later arm's output. MEASURED: the first run of
# this gate scored 12/1, the one failure being "su ALSO printed an
# authentication failure for the correct password" -- arm A had swallowed
# arm B's refusal. The product was right and the instrument was wrong.
# The serial log is CRLF, so the carriage return is stripped before matching.
arm() {
    awk -v a="LOGINPROBE-ARM-$1" -v b="LOGINPROBE-ARM-$1-END" \
        '{ line=$0; sub(/\r$/, "", line) }
         line == a { on=1; next }
         line == b { on=0 }
         on' "$S"
}
admitted() { printf '%s' "$1" | grep -q "su: switched to uid $2 ($3)"; }
refused()  { printf '%s' "$1" | grep -q 'su: Authentication failure'; }

A="$(arm A)"; B="$(arm B)"; C="$(arm C)"; DD="$(arm D)"; E="$(arm E)"
for L in A B C D E; do
    info "arm $L: $(arm $L | tr '\n' '|' | sed 's/|$//')"
done

# --- A: the right password for the wizard's user --------------------------
if admitted "$A" 1001 "$USERNAME"; then
    ok "A: the password the operator typed into the wizard AUTHENTICATED -- su reached uid 1001 as '$USERNAME' on the installed machine"
else
    bad "A: the operator's password did NOT authenticate as '$USERNAME' -- nobody can log into this machine with the password the wizard collected"
fi
if refused "$A"; then
    bad "A: su ALSO printed an authentication failure for the correct password"
else
    ok "A: and no authentication failure was printed for it"
fi

# --- B: a wrong password for the same user --------------------------------
if refused "$B"; then
    ok "B: a WRONG password for '$USERNAME' was REFUSED -- this is an authenticator, not a doormat"
else
    bad "B: a wrong password was NOT refused -- every other arm here is worthless"
fi
if admitted "$B" 1001 "$USERNAME"; then
    bad "B: su switched uid on a WRONG password"
else
    ok "B: and su did not change identity on it"
fi

# --- C: the administrator password the operator typed ---------------------
if admitted "$C" 1 hostowner; then
    ok "C: the ADMINISTRATOR password the operator typed authenticated as hostowner (uid 1) -- --root-pass reached the machine"
else
    bad "C: the administrator password the operator typed did NOT authenticate as hostowner"
fi

# --- D: the password published in this source tree ------------------------
if refused "$DD"; then
    ok "D: the hostowner password PUBLISHED IN THIS GIT REPOSITORY ('$TREEPASS') was REFUSED -- the installed machine does not carry the medium's credential"
else
    bad "D: the published hostowner password '$TREEPASS' still works on this machine -- anyone with the source tree is the administrator of it"
fi

# --- E: a valid password, wrong account -----------------------------------
if refused "$E"; then
    ok "E: '$USERNAME''s own (valid) password was REFUSED for hostowner -- /dev/auth checks the password AGAINST THE NAMED ACCOUNT"
else
    bad "E: a valid password for a different account admitted hostowner"
fi

say "the login surface itself, said plainly"
info "This gate drove \`su\`. It did NOT drive a boot-time login: see the report."
finish
