#!/usr/bin/env bash
#
# REGISTRATION, 2026-08-17. Until this date scripts/test_gate_registration.sh
# globbed only scripts/test_*.sh, so this directory was invisible to the gate
# against unregistered gates and every file in it read as coverage without
# being coverage. This gate is ON-DEMAND: not in ci_battery_manifest.txt
# because it boots a machine under `qemu-system-x86_64`.
#
# tests/linux/bootsync_installed.sh — AFTER AN UPDATE AND A REBOOT, DOES THE
# RUNNING KERNEL HAVE THE NEW MODULE, OR ONLY THE DISK?
#
# THE QUESTION, AND WHY EVERY OTHER GATE ANSWERS A DIFFERENT ONE
# ==============================================================
# tests/linux/installed_update_modules.sh proves an updated machine ends up with
# the .ko files on its ext4 root and a modules.dep it can resolve a name
# through. tests/linux/install_from_usb.sh proves the whole live-USB → install →
# update → reboot loop. NEITHER OF THEM ASKS WHETHER THE BOOT CHANGED, and it
# did not: user/linuxinit.ad:load_modules reads /etc/modules and loads every
# path in it BEFORE `bind '#sysroot' /`, so the .ko files an installed machine
# boots with come out of the INITRAMFS -- a PE section of the unified kernel
# image user/hlinstall.ad copied onto the ESP byte for byte on install day.
# `hpm update` could land a new nvme.ko and the next boot would still use the
# one from that day. On the owner's laptop that set is nvme (to find the disk at
# all), usb-storage (to read the stick), psmouse and i2c-hid (to have a
# pointer): exactly the modules that could not be updated.
#
# user/bootsync.ad closes it. This gate is the measurement.
#
# THE INSTRUMENT IS PROVED TO TELL THE TWO STATES APART BEFORE IT IS BELIEVED
# ==========================================================================
# Almost every obvious instrument answers "is it on the disk", which is the
# question that was already yes. /sys/module/<m>/coresize answers the other one:
# it is the number of bytes the module loader ALLOCATED for the module that is
# in the kernel RIGHT NOW. So one boot module on the ext4 root is given an extra
# SHF_ALLOC section -- 64 KiB, which moves coresize and nothing else -- standing
# in for what `hpm update` lands, and:
#
#   BOOT 1, BEFORE ANY SYNC, IS THE NEGATIVE CONTROL AND IT IS THE OWNER'S BUG:
#   the disk file is the new one and coresize is the OLD number. If those two
#   ever agree before bootsync has run, every assertion below is meaningless and
#   this gate says so rather than passing.
#
# WHAT IS COMPARED IS BYTES, NOT LOG LINES
# ========================================
# bootsync printing "committed" proves nothing, and it once printed exactly that
# while writing 16 MB into the middle of the live compressed archive (the
# machine still booted, with `Initramfs unpacking failed` in a log nobody was
# reading -- see user/bootsync.ad's note). So the boot image is pulled OFF THE
# ESP WITH mcopy, its .initrd overlay is walked as a newc archive, and the
# module's bytes inside it are compared to the file on the root. And the boot
# after the sync must carry NO `Initramfs unpacking failed` line.
#
# AND THE POWER BUTTON
# ====================
# A machine with a broken boot image does not boot, and there is no shell to fix
# it from. So the second image is SIGKILLed -- no shutdown of any kind, which
# tests/linux/boot_log.sh established is the equivalent of pulling the plug --
# in the middle of the overlay write, timed off a marker the guest prints so the
# window does not move with how long the boot took. That image must then boot,
# and must boot the modules it was INSTALLED with.
#
# Usage: tests/linux/bootsync_installed.sh
# Env:   HAMLINUX_BOOTSYNC_WORK   where to build and boot
#        HAMLINUX_BOOTSYNC_REUSE=1  reuse media already built there
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"
# FIRST, before reap.sh and before $WORK -- the contract in
# tests/linux/private_ns.sh. gates_are_private.sh checks that this line is here.
. tests/linux/private_ns.sh
priv_ns_reexec "$@"
. tests/linux/reap.sh

WORK="${HAMLINUX_BOOTSYNC_WORK:-$HOME/.hamnix-build/bootsync-installed}"
mkdir -p "$WORK"
reap_track "$WORK/reaped"
reap_on_exit :

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  PASS  %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$*"; }
say()  { printf '\n== %s\n' "$*"; }
info() { printf '  ..    %s\n' "$*"; }

export PATH="$PATH:/usr/sbin:/sbin"
for t in qemu-system-x86_64 mcopy sgdisk objcopy python3; do
    command -v "$t" >/dev/null || { bad "need $t"; exit 1; }
done
[ -f /usr/share/OVMF/OVMF_CODE_4M.fd ] || { bad "need OVMF"; exit 1; }

# The module the gate fattens. nls_ascii is in the image's boot list, is tiny,
# and nothing at boot depends on it -- so growing it cannot change whether the
# machine comes up, only what coresize reads.
MOD_REL="lib/modules"
KVER="$(basename "$(ls -1 /boot/vmlinuz-* | sort -V | tail -1)" | sed 's/^vmlinuz-//')"
MOD_PATH="/lib/modules/$KVER/kernel/fs/nls/nls_ascii.ko"
GROW=65536

# --- helpers ---------------------------------------------------------------
esp_off() { echo $(( $(sgdisk -i 1 "$1" | awk '/First sector/ {print $3}') * 512 )); }

# Pull one file off partition 1 of a disk image.
esp_get() { mcopy -n -o -i "${1}@@$(esp_off "$1")" "::$2" "$3" 2>/dev/null; }
esp_put() { mcopy -o -i "${1}@@$(esp_off "$1")" "$3" "::$2" 2>/dev/null; }

# .initrd geometry of a UKI, as "vsize rawsize rawptr".
uki_geom() {
    python3 - "$1" <<'PY'
import struct, sys
b = open(sys.argv[1], "rb").read()
lfa = struct.unpack_from("<I", b, 0x3C)[0]
if b[lfa:lfa+4] != b"PE\0\0":
    raise SystemExit("notpe")
n = struct.unpack_from("<H", b, lfa + 6)[0]
o = struct.unpack_from("<H", b, lfa + 20)[0]
for i in range(n):
    s = lfa + 24 + o + i * 40
    if b[s:s+8].rstrip(b"\0") == b".initrd":
        vs, va, raw, ptr = struct.unpack_from("<IIII", b, s + 8)
        print(vs, raw, ptr)
        break
else:
    raise SystemExit("noinitrd")
PY
}

# Boot a disk image under OVMF with <rc> installed as \PHASE.RC.
# boot_phase <img> <rc-file> <tag> [kill-after-seconds] [marker]
boot_phase() {
    local img="$1" rc="$2" tag="$3" after="${4:-}" marker="${5:-A23E-ARMED}"
    esp_put "$img" "/PHASE.RC" "$rc"
    [ -f "$WORK/vars_$tag.fd" ] || cp /usr/share/OVMF/OVMF_VARS_4M.fd "$WORK/vars_$tag.fd"
    rm -f "$WORK/$tag.log"
    qemu-system-x86_64 -machine q35 -accel kvm -m 2048 -smp 2 \
        -display none -no-reboot \
        -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
        -drive if=pflash,format=raw,unit=1,file="$WORK/vars_$tag.fd" \
        -drive "file=$img,format=raw,if=virtio,cache=writethrough" \
        -serial "file:$WORK/$tag.log" -monitor none >/dev/null 2>&1 &
    local qp=$!
    reap_add "$qp"
    if [ -n "$after" ]; then
        local i
        for i in $(seq 1 900); do
            grep -q "$marker" "$WORK/$tag.log" 2>/dev/null && break
            kill -0 "$qp" 2>/dev/null || break
            sleep 0.1
        done
        sleep "$after"
        kill -9 "$qp" 2>/dev/null
        info "$tag: SIGKILL ${after}s after '$marker' -- the power button"
    else
        local i
        for i in $(seq 1 240); do kill -0 "$qp" 2>/dev/null || break; sleep 1; done
        kill -9 "$qp" 2>/dev/null
    fi
    wait "$qp" 2>/dev/null
}

# The value the guest printed between two markers.
#
# `tr -d '\r'` IS LOAD BEARING. The serial console ends every line with CR LF,
# so `grep -E '^[0-9]+$'` matches NOTHING against a log full of numbers -- which
# is what this gate did on its first run, reporting "the instrument is not
# reading" about an instrument that was reading perfectly.
between() {
    tr -d '\r' <"$WORK/$1.log" | sed -n "/$2/,/$3/p" | grep -E "^[0-9]+$" | head -1
}

# --- the media -------------------------------------------------------------
say "building the root, then FATTENING one boot module on the disk copy only"
if [ "${HAMLINUX_BOOTSYNC_REUSE:-0}" = 1 ] && [ -f "$WORK/pristine.img" ]; then
    info "reusing $WORK/pristine.img"
else
    # REBUILT EXPLICITLY. scripts/hamlinux_disk.sh rebuilds build/image/root only
    # when it is ABSENT, so every run after the first would otherwise package
    # whatever tree happened to be lying there -- the stale-artifact false
    # report tests/linux/boot_log.sh paid to learn about.
    HAMLINUX_DISTRO_RO=1 scripts/hamlinux_image.sh >"$WORK/image.log" 2>&1 \
        || { bad "scripts/hamlinux_image.sh failed -- see $WORK/image.log"; exit 1; }
    ok "build/image/root rebuilt from this tree"

    ORIG_KO="build/image/root$MOD_PATH"
    [ -f "$ORIG_KO" ] || { bad "no $MOD_PATH in the staged root"; exit 1; }
    cp "$ORIG_KO" "$WORK/nls_ascii.orig.ko"
    # THE FATTENING HAPPENS AFTER THE INITRAMFS IS PACKED AND BEFORE THE EXT4
    # ROOT IS, which is the whole arrangement: scripts/hamlinux_image.sh has
    # already written build/image/initramfs.cpio.gz from the ORIGINAL module,
    # and scripts/hamlinux_disk.sh copies build/image/root -- as it is now --
    # into the root filesystem. That is exactly the state `hpm update` leaves a
    # machine in: new module on the ext4 root, old module sealed in the boot
    # image.
    head -c "$GROW" /dev/zero > "$WORK/fat.bin"
    objcopy --add-section .hamnixfat="$WORK/fat.bin" \
            --set-section-flags .hamnixfat=alloc,readonly,data \
            "$ORIG_KO" "$WORK/fat.ko" \
        || { bad "objcopy could not fatten $MOD_PATH"; exit 1; }
    cp "$WORK/fat.ko" "$ORIG_KO"
    ok "$MOD_PATH on the root is $(stat -Lc%s "$ORIG_KO") bytes; the initramfs still has $(stat -Lc%s "$WORK/nls_ascii.orig.ko")"

    # The rc under test SOURCES THE SHIPPED ONE VERBATIM and then reports.
    # \PHASE.RC comes off the FAT boot partition, so the host can change what
    # each boot does between boots without touching the ext4 root.
    cat >"$WORK/rc.proof" <<RCEOF
source '/etc/rc.boot.installed'
echo 'A23E-BEGIN'
echo 'A23E-CORESIZE'
cat /sys/module/nls_ascii/coresize
echo 'A23E-DISKSUM'
cksum <$MOD_PATH
echo 'A23E-PHASE'
source '/boot/PHASE.RC'
echo 'A23E-END'
RCEOF
    HAMLINUX_DISTRO_RO=1 HAMLINUX_DISK_RC="$WORK/rc.proof" \
        scripts/hamlinux_disk.sh "$WORK/pristine.img" 4G >"$WORK/disk.log" 2>&1 \
        || { bad "scripts/hamlinux_disk.sh failed -- see $WORK/disk.log"; exit 1; }
    ok "installed disk built: $(grep -o 'UKI.MAP: .*' "$WORK/disk.log")"

    # A SECOND MEDIUM WITH A RESERVATION TOO SMALL TO HOLD THE OVERLAY.
    # The refusal is the most important path in the program -- it is what
    # happens on a medium built before the reservation was sized for the boot
    # set it ends up with -- and a refusal that has never been executed is a
    # comment. 1 MiB against ~16 MB of modules.
    HAMLINUX_DISTRO_RO=1 HAMLINUX_DISK_RC="$WORK/rc.proof" \
        HAMLINUX_INITRD_RESERVE=1048576 \
        scripts/hamlinux_disk.sh "$WORK/tight.img" 4G >"$WORK/disk_tight.log" 2>&1 \
        || { bad "the small-reservation disk would not build"; exit 1; }
    ok "a second disk built with a 1 MiB reservation, for the refusal path"
fi

printf "echo 'A23E-PHASE=observe'\ninit 0\n"                      >"$WORK/p_observe.rc"
printf "echo 'A23E-PHASE=sync'\necho 'A23E-ARMED'\nbootsync\ninit 0\n" >"$WORK/p_sync.rc"
printf "echo 'A23E-PHASE=twice'\nbootsync\nbootsync\ninit 0\n"     >"$WORK/p_twice.rc"

# These two are what every assertion below is measured against, so their
# absence is a hard stop rather than a default: a REUSE run whose work
# directory lost them would otherwise compare against an empty string and pass.
for f in "$WORK/nls_ascii.orig.ko" "$WORK/fat.ko"; do
    [ -f "$f" ] || { bad "$f is missing -- rerun without HAMLINUX_BOOTSYNC_REUSE"; exit 1; }
done
ORIG_SZ=$(stat -Lc%s "$WORK/nls_ascii.orig.ko")
FAT_SUM=$(cksum <"$WORK/fat.ko")

# --- 1. the reservation exists at all --------------------------------------
say "the shipped boot image carries a reservation, and UKI.MAP describes it"
esp_get "$WORK/pristine.img" "/EFI/BOOT/BOOTX64.EFI" "$WORK/shipped.efi" \
    && ok "BOOTX64.EFI is on the ESP at the removable-media path" \
    || { bad "no BOOTX64.EFI on the ESP -- nothing below can be trusted"; exit 1; }
read -r VS0 RAW0 PTR0 <<<"$(uki_geom "$WORK/shipped.efi")"
info ".initrd: VirtualSize=$VS0 SizeOfRawData=$RAW0 PointerToRawData=$PTR0"
[ "$((RAW0 - VS0))" -ge $((16 * 1024 * 1024)) ] \
    && ok "the reservation is $((RAW0 - VS0)) bytes -- room for the whole boot set" \
    || bad "the reservation is only $((RAW0 - VS0)) bytes"
esp_get "$WORK/pristine.img" "/UKI.MAP" "$WORK/uki.map" \
    && ok "UKI.MAP is on the ESP beside it" \
    || bad "no UKI.MAP on the ESP -- bootsync will refuse"
MAP_BASE=$(head -1 "$WORK/uki.map")
[ "$MAP_BASE" = "$VS0" ] \
    && ok "UKI.MAP's base ($MAP_BASE) is the shipped .initrd length" \
    || bad "UKI.MAP says base=$MAP_BASE but the section says $VS0"
MAP_N=$(grep -c '^/' "$WORK/uki.map")
[ "$MAP_N" -gt 30 ] \
    && ok "UKI.MAP names $MAP_N boot modules" \
    || bad "UKI.MAP names only $MAP_N boot modules"

# --- 2. THE NEGATIVE CONTROL, which is the owner's bug ---------------------
say "BOOT 1 -- the disk has the new module and the running kernel does not"
cp "$WORK/pristine.img" "$WORK/main.img"
rm -f "$WORK/vars_b1.fd"
boot_phase "$WORK/main.img" "$WORK/p_observe.rc" b1
B1_CORE=$(between b1 "A23E-CORESIZE" "A23E-DISKSUM")
B1_SUM=$(tr -d '\r' <"$WORK/b1.log" | sed -n '/A23E-DISKSUM/,/A23E-PHASE/p' | grep -E '^[0-9]+ [0-9]+$' | head -1)
info "coresize=$B1_CORE   disk cksum=$B1_SUM"
[ -n "$B1_CORE" ] \
    && ok "the guest reported /sys/module/nls_ascii/coresize at all" \
    || { bad "no coresize from boot 1 -- the instrument is not reading"; exit 1; }
[ "$B1_SUM" = "$FAT_SUM" ] \
    && ok "the ext4 root really carries the NEW module ($B1_SUM)" \
    || bad "the disk module is $B1_SUM, expected the fattened $FAT_SUM"
B1_CORE_N=$B1_CORE
[ "$B1_CORE_N" -lt "$((ORIG_SZ + GROW))" ] \
    && ok "and the RUNNING kernel has the OLD one (coresize $B1_CORE_N) -- the bug, measured" \
    || bad "coresize is already $B1_CORE_N before any sync: the instrument cannot tell the two apart"

# --- 3. the sync ------------------------------------------------------------
say "BOOT 2 -- bootsync"
rm -f "$WORK/vars_b2.fd"
boot_phase "$WORK/main.img" "$WORK/p_sync.rc" b2
grep -q "bootsync: committed" "$WORK/b2.log" \
    && ok "bootsync committed" \
    || bad "bootsync did not commit -- $(grep -m2 'bootsync:' "$WORK/b2.log" | tr '\n' ' ')"
grep -q "modules verified in the boot image" "$WORK/b2.log" \
    && ok "it read the overlay back against the files on the root before committing" \
    || bad "no read-back line"

# --- 4. THE BYTES, off the medium, not off a log line ----------------------
say "the boot image on the ESP really carries the module's CURRENT bytes"
esp_get "$WORK/main.img" "/EFI/BOOT/BOOTX64.EFI" "$WORK/synced.efi"
read -r VS1 RAW1 PTR1 <<<"$(uki_geom "$WORK/synced.efi")"
info ".initrd: VirtualSize=$VS1 (was $VS0), SizeOfRawData=$RAW1 (was $RAW0)"
[ "$VS1" -gt "$VS0" ] \
    && ok "VirtualSize grew by $((VS1 - VS0)) bytes" \
    || bad "VirtualSize did not move"
[ "$RAW1" = "$RAW0" ] \
    && ok "SizeOfRawData is untouched -- the file's length never changed" \
    || bad "SizeOfRawData moved: $RAW0 -> $RAW1"
python3 - "$WORK/synced.efi" "$PTR1" "$VS0" "$VS1" "${MOD_PATH#/}" "$WORK/fat.ko" \
        >"$WORK/walk.txt" 2>&1 <<'PY'
# Walk the appended newc archive by its own headers -- not by anything the
# guest said -- and compare the named module's payload to the file on the root.
import sys
efi, ptr, base, vsize, want, ref = sys.argv[1:7]
ptr, base, vsize = int(ptr), int(base), int(vsize)
b = open(efi, "rb").read()
p = ptr + base
end = ptr + vsize
n = 0
found = None
while p < end:
    if b[p:p + 6] != b"070701":
        raise SystemExit("no newc magic at overlay+%d" % (p - ptr - base))
    fs = int(b[p + 54:p + 62], 16)
    ns = int(b[p + 94:p + 102], 16)
    name = b[p + 110:p + 110 + ns - 1].decode("latin1")
    q = p + 110 + ns
    q += (-q) % 4
    if name == "TRAILER!!!":
        print("TRAILER after %d entries; archive ends at overlay+%d"
              % (n, q - ptr - base))
        break
    n += 1
    if name == want:
        found = b[q:q + fs]
    p = q + fs
    p += (-p) % 4
else:
    raise SystemExit("ran off the end of the section with no TRAILER")
print("%d entries in the overlay" % n)
if found is None:
    raise SystemExit("%s is not in the overlay" % want)
disk = open(ref, "rb").read()
print("%s: %d bytes in the boot image, %d on the root"
      % (want, len(found), len(disk)))
if found != disk:
    raise SystemExit("THE BYTES DIFFER")
print("byte for byte identical")
PY
WALK_RC=$?
cat "$WORK/walk.txt" | sed 's/^/  ..    /'
[ "$WALK_RC" = 0 ] && ok "the overlay parses as newc and the module's bytes are IDENTICAL to the file on the root" \
                   || bad "the overlay does not carry the module's bytes (see $WORK/walk.txt)"

# --- 5. the boot that matters ----------------------------------------------
say "BOOT 3 -- after the sync, what does the RUNNING kernel have?"
rm -f "$WORK/vars_b3.fd"
boot_phase "$WORK/main.img" "$WORK/p_observe.rc" b3
B3_CORE=$(between b3 "A23E-CORESIZE" "A23E-DISKSUM")
info "coresize=$B3_CORE (was $B1_CORE_N, the module grew by $GROW)"
[ "$B3_CORE" = "$((B1_CORE_N + GROW))" ] \
    && ok "THE RUNNING KERNEL HAS THE NEW MODULE: $B1_CORE_N + $GROW = $B3_CORE" \
    || bad "coresize is $B3_CORE, expected $((B1_CORE_N + GROW))"
grep -q "Initramfs unpacking failed" "$WORK/b3.log" \
    && bad "the kernel reported 'Initramfs unpacking failed' -- the archive is CORRUPT and the boot only looked fine" \
    || ok "no 'Initramfs unpacking failed': the whole archive unpacked"
B1_MODS=$(tr -d '\r' <"$WORK/b1.log" | grep -o "loaded [0-9]* kernel modules" | head -1)
B3_MODS=$(tr -d '\r' <"$WORK/b3.log" | grep -o "loaded [0-9]* kernel modules" | head -1)
[ -n "$B3_MODS" ] && [ "$B1_MODS" = "$B3_MODS" ] \
    && ok "the same module count as before the sync ($B3_MODS): nothing was lost" \
    || bad "module count changed: '$B1_MODS' -> '$B3_MODS'"

# --- 6. running it twice does not creep ------------------------------------
say "twice in one boot leaves ONE overlay"
rm -f "$WORK/vars_b4.fd"
boot_phase "$WORK/main.img" "$WORK/p_twice.rc" b4
esp_get "$WORK/main.img" "/EFI/BOOT/BOOTX64.EFI" "$WORK/twice.efi"
read -r VS2 _ _ <<<"$(uki_geom "$WORK/twice.efi")"
[ "$VS2" = "$VS1" ] \
    && ok "VirtualSize is still $VS2 after two more runs -- the reservation does not creep" \
    || bad "VirtualSize moved to $VS2 on a repeat run"

# --- 7. THE POWER BUTTON ---------------------------------------------------
say "INTERRUPTED MID-WRITE -- does the machine still boot?"
cp "$WORK/pristine.img" "$WORK/killed.img"
rm -f "$WORK/vars_k1.fd"
# Killed the instant step 1 reports, which is the start of the overlay write.
boot_phase "$WORK/killed.img" "$WORK/p_sync.rc" k1 0 "installed with."
grep -q "bootsync: committed" "$WORK/k1.log" \
    && bad "bootsync finished before the kill -- the window was missed, this arm proves nothing" \
    || ok "the guest died before bootsync committed"
esp_get "$WORK/killed.img" "/EFI/BOOT/BOOTX64.EFI" "$WORK/killed.efi"
read -r VSK RAWK PTRK <<<"$(uki_geom "$WORK/killed.efi")"
[ "$VSK" = "$VS0" ] \
    && ok "the interrupted image records the SHIPPED length ($VSK)" \
    || bad "VirtualSize is $VSK after the kill, not the shipped $VS0"
PARTIAL=$(python3 - "$WORK/killed.efi" "$PTRK" "$VS0" <<'PY'
import sys
b = open(sys.argv[1], "rb").read()
s = int(sys.argv[2]) + int(sys.argv[3])
seg = b[s:]
i = len(seg) - 1
while i >= 0 and seg[i] == 0:
    i -= 1
print(i + 1)
PY
)
[ "$PARTIAL" -gt 0 ] \
    && ok "$PARTIAL bytes of overlay were already on the medium: the kill really landed mid-write" \
    || bad "nothing had been written yet -- the kill was too early to prove anything"
rm -f "$WORK/vars_k2.fd"
boot_phase "$WORK/killed.img" "$WORK/p_observe.rc" k2
K2_CORE=$(between k2 "A23E-CORESIZE" "A23E-DISKSUM")
[ -n "$K2_CORE" ] \
    && ok "THE INTERRUPTED MACHINE BOOTS and reaches its boot rc" \
    || bad "the interrupted machine did not reach its rc -- IT IS BRICKED"
[ "$K2_CORE" = "$B1_CORE_N" ] \
    && ok "and it boots the modules it was INSTALLED with (coresize $K2_CORE)" \
    || bad "coresize is $K2_CORE after the interruption, expected the shipped $B1_CORE_N"
grep -q "Initramfs unpacking failed" "$WORK/k2.log" \
    && bad "the interrupted image's archive is corrupt" \
    || ok "no 'Initramfs unpacking failed' on the interrupted image"

# --- 8. and it can be retried ----------------------------------------------
say "the interrupted machine can simply run it again"
rm -f "$WORK/vars_k3.fd"
boot_phase "$WORK/killed.img" "$WORK/p_sync.rc" k3
grep -q "bootsync: committed" "$WORK/k3.log" \
    && ok "bootsync committed on the retry" \
    || bad "bootsync could not recover from the interrupted state"
rm -f "$WORK/vars_k4.fd"
boot_phase "$WORK/killed.img" "$WORK/p_observe.rc" k4
K4_CORE=$(between k4 "A23E-CORESIZE" "A23E-DISKSUM")
[ "$K4_CORE" = "$((B1_CORE_N + GROW))" ] \
    && ok "and the reboot after it has the new module (coresize $K4_CORE)" \
    || bad "coresize is $K4_CORE after the retry, expected $((B1_CORE_N + GROW))"

# --- 9. THE REFUSAL, which is the path a bad medium takes ------------------
say "a reservation too small to hold the overlay: refuse and change NOTHING"
esp_get "$WORK/tight.img" "/EFI/BOOT/BOOTX64.EFI" "$WORK/tight_before.efi"
read -r VTB RTB PTB <<<"$(uki_geom "$WORK/tight_before.efi")"
info "the tight medium's reservation is $((RTB - VTB)) bytes"
rm -f "$WORK/vars_t1.fd"
boot_phase "$WORK/tight.img" "$WORK/p_sync.rc" t1
grep -q "DOES NOT FIT THE RESERVATION" "$WORK/t1.log" \
    && ok "bootsync refused by name" \
    || bad "bootsync did not refuse on a 1 MiB reservation"
grep -q "bootsync: committed" "$WORK/t1.log" \
    && bad "it committed anyway" \
    || ok "and it did not commit"
esp_get "$WORK/tight.img" "/EFI/BOOT/BOOTX64.EFI" "$WORK/tight_after.efi"
cmp -s "$WORK/tight_before.efi" "$WORK/tight_after.efi" \
    && ok "the boot image is byte-identical to before the attempt: not one byte was written" \
    || bad "the boot image changed despite the refusal"
rm -f "$WORK/vars_t2.fd"
boot_phase "$WORK/tight.img" "$WORK/p_observe.rc" t2
T2_CORE=$(between t2 "A23E-CORESIZE" "A23E-DISKSUM")
[ "$T2_CORE" = "$B1_CORE_N" ] \
    && ok "and it boots exactly as it was installed (coresize $T2_CORE)" \
    || bad "the refused machine boots differently: coresize $T2_CORE"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
