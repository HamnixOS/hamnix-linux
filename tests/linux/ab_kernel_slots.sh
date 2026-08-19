#!/usr/bin/env bash
#
# tests/linux/ab_kernel_slots.sh — CAN THE KERNEL AN INSTALLED MACHINE BOOTS BE
# REPLACED, AND DOES THE MACHINE SURVIVE LOSING POWER WHILE IT IS BEING?
#
# Not in ci_battery_manifest.txt because it builds two 4 GiB media and boots six
# machines under `qemu-system-x86_64`, which is tens of minutes and no part of a
# 50-minute sharded battery. ON-DEMAND, the same way
# tests/linux/bootsync_installed.sh is.
#
# THE QUESTION
# ============
# Until this gate, `hpm update` left the kernel alone: nothing was written and
# nothing failed, so an installed machine booted the kernel it was installed
# with forever (HANDOFF.md, "THE KERNEL AN INSTALLED MACHINE BOOTS IS NOT
# UPDATABLE"). The obstacle was never the bytes -- it was that firmware executes
# exactly ONE file on the removable-media path, \EFI\BOOT\BOOTX64.EFI, and
# rewriting 176 MB of it on a journal-less FAT32 has a minutes-long window in
# which the power button leaves a machine that cannot boot.
#
# scripts/hamlinux_disk.sh's HAMLINUX_AB_SLOTS=1 layout removes that window: the
# file firmware runs becomes systemd-boot, written once at build time and never
# rewritten; the kernel images sit beside it as EFI/Linux/hamnix-{a,b}.efi; and
# an update writes the INACTIVE slot and then rewrites ONE PREALLOCATED
# 512-BYTE loader.conf. This gate is the measurement of that claim.
#
# THE TRAP THIS GATE IS BUILT AROUND, STATED FIRST
# ================================================
# A MACHINE THAT BOOTS LOOKS IDENTICAL WHETHER IT BOOTED THE NEW KERNEL OR
# SILENTLY FELL BACK TO THE OLD ONE. Every assertion below would go green
# against a mechanism that does nothing at all, if the only thing measured were
# "did it come up". So the two slots are made DISTINGUISHABLE BEFORE ANYTHING IS
# MEASURED, in two independent ways, and the gate proves the distinguisher
# itself before it trusts it:
#
#   1. DIFFERENT KERNEL BINARIES. Slot A and slot B are built from two
#      different host kernels. What is read back is the RUNNING KERNEL'S OWN
#      BANNER on the serial console -- `Linux version 6.12.x` -- which no
#      fallback can forge, because it is printed by the kernel that is
#      executing.
#   2. DIFFERENT KERNEL COMMAND LINES. Slot B's cmdline carries a marker that
#      slot A's does not. It is a PE section of slot B's image, so it can only
#      appear on a boot that ran slot B's image.
#
# Assertion 0 below compares the two UKIs' .linux sections and their cmdlines
# and STOPS THE GATE if they are the same bytes. An instrument that cannot tell
# the two states apart is the failure this project has paid for repeatedly, and
# it is checked rather than assumed.
#
# AND THE POWER BUTTON, WHICH IS THE PART THAT MATTERS MORE THAN THE HAPPY PATH
# ============================================================================
# Two arms, and THE SECOND IS WHY THE FIRST MEANS ANYTHING:
#
#   ARM I  -- slot B half written, loader.conf still naming A. This is the state
#             the disk is in for the whole minutes-long copy. The machine must
#             boot, on the old kernel.
#   ARM II -- THE NEGATIVE CONTROL, and it must go RED-shaped: the same half
#             written slot B, but loader.conf ALREADY FLIPPED to it. This
#             machine must NOT boot. If it boots anyway, then arm I proves
#             nothing -- it would mean this firmware tolerates a torn image and
#             the ordering rule is untested folklore.
#
# Usage: tests/linux/ab_kernel_slots.sh
# Env:   HAMLINUX_AB_WORK    where to build and boot
#        HAMLINUX_AB_REUSE=1 reuse media already built there
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"
# FIRST, before reap.sh and before $WORK -- the contract in
# tests/linux/private_ns.sh. gates_are_private.sh checks that this line is here.
. tests/linux/private_ns.sh
priv_ns_reexec "$@"
. tests/linux/reap.sh

WORK="${HAMLINUX_AB_WORK:-$HOME/.hamnix-build/abkernel/gate}"
mkdir -p "$WORK"
reap_track "$WORK/reaped"
reap_on_exit :

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  PASS  %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$*"; }
say()  { printf '\n== %s\n' "$*"; }
info() { printf '  ..    %s\n' "$*"; }

export PATH="$PATH:/usr/sbin:/sbin"
for t in qemu-system-x86_64 mcopy mdir mdel sgdisk objcopy python3; do
    command -v "$t" >/dev/null || { bad "need $t"; exit 1; }
done
[ -f /usr/share/OVMF/OVMF_CODE_4M.fd ] || { bad "need OVMF"; exit 1; }
SDBOOT=/usr/lib/systemd/boot/efi/systemd-bootx64.efi
[ -f "$SDBOOT" ] || { bad "need systemd-boot at $SDBOOT"; exit 1; }

# TWO DIFFERENT HOST KERNELS. Highest version for slot A (what the image would
# have shipped anyway), and a DIFFERENT one for slot B.
mapfile -t KERNELS < <(ls -1 /boot/vmlinuz-* 2>/dev/null | sort -V)
if [ "${#KERNELS[@]}" -lt 2 ]; then
    bad "this host has ${#KERNELS[@]} kernel(s) under /boot; the gate needs two DIFFERENT ones to tell the slots apart"
    exit 1
fi
KERN_A="${KERNELS[-1]}"
KERN_B="${KERNELS[0]}"
VER_A="$(basename "$KERN_A" | sed 's/^vmlinuz-//')"
VER_B="$(basename "$KERN_B" | sed 's/^vmlinuz-//')"
# What gets grepped out of the kernel's own banner: the numeric version only.
NUM_A="$(printf '%s' "$VER_A" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+')"
NUM_B="$(printf '%s' "$VER_B" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+')"
SLOTMARK="hamnix.abslot=B"

# One PARTUUID for BOTH builds: slot B's cmdline must name the same root
# partition slot A's does, or booting slot B would fail for a reason that has
# nothing to do with this mechanism.
PU="${HAMLINUX_AB_PARTUUID:-11111111-2222-3333-4444-555555555555}"

esp_off() { echo $(( $(sgdisk -i 1 "$1" | awk '/First sector/ {print $3}') * 512 )); }
esp_get() { mcopy -n -o -i "${1}@@$(esp_off "$1")" "::$2" "$3" 2>/dev/null; }
esp_put() { mcopy -o -i "${1}@@$(esp_off "$1")" "$3" "::$2" 2>/dev/null; }
esp_del() { mdel     -i "${1}@@$(esp_off "$1")" "::$2" 2>/dev/null; }
esp_ls()  { mdir -/  -i "${1}@@$(esp_off "$1")" "::$2" 2>/dev/null; }

# Print the named PE section of a file to stdout, or exit non-zero.
pe_section() {
    python3 - "$1" "$2" <<'PY'
import struct, sys
b = open(sys.argv[1], "rb").read()
want = sys.argv[2].encode()
lfa = struct.unpack_from("<I", b, 0x3C)[0]
if b[lfa:lfa+4] != b"PE\0\0":
    sys.exit("notpe")
n = struct.unpack_from("<H", b, lfa + 6)[0]
o = struct.unpack_from("<H", b, lfa + 20)[0]
for i in range(n):
    s = lfa + 24 + o + i * 40
    if b[s:s+8].rstrip(b"\0") == want:
        vs, va, raw, ptr = struct.unpack_from("<IIII", b, s + 8)
        sys.stdout.buffer.write(b[ptr:ptr+vs])
        break
else:
    sys.exit("nosection")
PY
}

# loader.conf, at the FIXED length the disk builder wrote. A flip that changed
# the length would allocate a cluster and mutate the FAT chain, which is the one
# thing this design must never do -- so the length is asserted, not assumed.
LOADER_CONF_BYTES=512
mkconf() { # mkconf <slot-file> <out>
    printf 'timeout 0\ndefault %s\neditor no\n' "$1" > "$2.head"
    { cat "$2.head"
      head -c $(( LOADER_CONF_BYTES - $(stat -Lc%s "$2.head") - 1 )) /dev/zero | tr '\0' '#'
      printf '\n'
    } > "$2"
    rm -f "$2.head"
    [ "$(stat -Lc%s "$2")" = "$LOADER_CONF_BYTES" ]
}

# Boot a disk image under OVMF. No PHASE.RC: what is read is the KERNEL'S OWN
# banner and command line, which are printed before any userland exists and
# cannot be produced by a machine that booted the other slot.
boot() { # boot <img> <tag> [seconds]
    local img="$1" tag="$2" secs="${3:-150}"
    rm -f "$WORK/$tag.log"
    cp /usr/share/OVMF/OVMF_VARS_4M.fd "$WORK/vars_$tag.fd"
    timeout "$secs" qemu-system-x86_64 -machine q35 -accel kvm -m 2048 -smp 2 \
        -display none -no-reboot \
        -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
        -drive if=pflash,format=raw,unit=1,file="$WORK/vars_$tag.fd" \
        -drive "file=$img,format=raw,if=virtio,cache=writethrough" \
        -serial "file:$WORK/$tag.log" -monitor none >/dev/null 2>&1
    # `tr -d '\r'` IS LOAD BEARING -- the serial console ends every line CR LF,
    # and tests/linux/bootsync_installed.sh paid a whole run to learn that.
    tr -d '\r' < "$WORK/$tag.log" > "$WORK/$tag.txt" 2>/dev/null || :
}

# Which kernel actually executed, read off its own banner: A, B, BOTH or NONE.
booted_kernel() {
    local a=0 b=0
    grep -q "Linux version $NUM_A" "$WORK/$1.txt" 2>/dev/null && a=1
    grep -q "Linux version $NUM_B" "$WORK/$1.txt" 2>/dev/null && b=1
    if   [ $a = 1 ] && [ $b = 1 ]; then echo BOTH
    elif [ $a = 1 ]; then echo A
    elif [ $b = 1 ]; then echo B
    else echo NONE; fi
}

say "the host's kernels, and the two the slots are built from"
info "slot A: $VER_A"
info "slot B: $VER_B"
[ "$NUM_A" != "$NUM_B" ] \
    && ok "the two slots are built from DIFFERENT kernel versions ($NUM_A vs $NUM_B)" \
    || { bad "both slots would carry kernel $NUM_A -- nothing below could tell them apart"; exit 1; }

# --- the media -------------------------------------------------------------
if [ "${HAMLINUX_AB_REUSE:-0}" = 1 ] && [ -f "$WORK/pristine.img" ] \
   && [ -f "$WORK/uki_a.efi" ] && [ -f "$WORK/uki_b.efi" ]; then
    info "reusing the media in $WORK"
else
    say "building the root, then TWO media -- one per kernel -- through the shipped path"
    # REBUILT EXPLICITLY: scripts/hamlinux_disk.sh rebuilds build/image/root only
    # when it is ABSENT, so a second run would otherwise package whatever tree
    # was lying there -- the stale-artifact false report boot_log.sh paid for.
    if [ "${HAMLINUX_AB_KEEPIMAGE:-0}" = 1 ] && [ -d build/image/root ]; then
        info "HAMLINUX_AB_KEEPIMAGE=1: reusing the build/image already present"
    else
        HAMLINUX_DISTRO_RO=1 scripts/hamlinux_image.sh >"$WORK/image.log" 2>&1 \
            || { bad "scripts/hamlinux_image.sh failed -- see $WORK/image.log"; exit 1; }
        ok "build/image/root rebuilt from this tree"
    fi
    [ -f build/image/vmlinuz ] || { bad "no build/image/vmlinuz after the image build"; exit 1; }
    cp build/image/vmlinuz "$WORK/vmlinuz.image"

    # THE RED ARM, AS AN ARM OF THIS SAME GATE RATHER THAN A SEPARATE SCRIPT.
    #
    # HAMLINUX_AB_REDARM=1 builds the media with the A/B layout OFF -- i.e. the
    # tree exactly as it was before this work -- and scores them with the
    # identical assertions. It exists because every number above is
    # success-shaped: a machine that boots looks the same either way, and a
    # gate that has never been seen to fail is a comment. The red arm is what
    # says these assertions are about the mechanism and not about QEMU.
    AB="${HAMLINUX_AB_REDARM:+0}"; AB="${AB:-1}"
    [ "$AB" = 1 ] || info "HAMLINUX_AB_REDARM=1: building WITHOUT the A/B layout; this arm is EXPECTED TO FAIL"

    # SLOT A -- the medium exactly as it would ship, with the A/B layout on.
    cp -L "$KERN_A" build/image/vmlinuz
    HAMLINUX_DISTRO_RO=1 HAMLINUX_AB_SLOTS="$AB" HAMLINUX_ROOT_PARTUUID="$PU" \
        scripts/hamlinux_disk.sh "$WORK/pristine.img" 4G >"$WORK/diskA.log" 2>&1 \
        || { bad "the slot-A medium would not build -- see $WORK/diskA.log"; exit 1; }
    cp build/image/disk/BOOTX64.EFI "$WORK/uki_a.efi"
    ok "slot-A medium built; $(grep -o 'A/B: .*' "$WORK/diskA.log" | head -1)"

    # SLOT B -- THE SAME SHIPPED PATH, a DIFFERENT kernel, a MARKED cmdline and
    # THE SAME ROOT PARTUUID. Built through scripts/hamlinux_disk.sh rather than
    # by a private objcopy in this gate, so what is installed into slot B below
    # is a UKI this tree really produces, reservation and all.
    cp -L "$KERN_B" build/image/vmlinuz
    CMDLINE_B="earlycon=efifb console=ttyS0,115200 console=tty0 root=PARTUUID=$PU rw panic=-1 loglevel=7 printk.devkmsg=on hung_task_timeout_secs=30 sysrq_always_enabled $SLOTMARK"
    HAMLINUX_DISTRO_RO=1 HAMLINUX_AB_SLOTS="$AB" HAMLINUX_ROOT_PARTUUID="$PU" \
        HAMLINUX_CMDLINE="$CMDLINE_B" \
        scripts/hamlinux_disk.sh "$WORK/slotb.img" 4G >"$WORK/diskB.log" 2>&1 \
        || { bad "the slot-B medium would not build -- see $WORK/diskB.log"; exit 1; }
    cp build/image/disk/BOOTX64.EFI "$WORK/uki_b.efi"
    ok "slot-B UKI built from $VER_B, carrying '$SLOTMARK'"

    cp "$WORK/vmlinuz.image" build/image/vmlinuz
fi

# --- 0. THE DISTINGUISHER, PROVED BEFORE IT IS TRUSTED ----------------------
say "0. CAN THIS GATE TELL THE TWO SLOTS APART AT ALL? (checked first; the rest is void without it)"
pe_section "$WORK/uki_a.efi" .linux   > "$WORK/kern_a.bin" 2>/dev/null || { bad "slot A's UKI has no .linux section"; exit 1; }
pe_section "$WORK/uki_b.efi" .linux   > "$WORK/kern_b.bin" 2>/dev/null || { bad "slot B's UKI has no .linux section"; exit 1; }
pe_section "$WORK/uki_a.efi" .cmdline > "$WORK/cl_a.txt"   2>/dev/null || { bad "slot A's UKI has no .cmdline"; exit 1; }
pe_section "$WORK/uki_b.efi" .cmdline > "$WORK/cl_b.txt"   2>/dev/null || { bad "slot B's UKI has no .cmdline"; exit 1; }
CKA=$(cksum < "$WORK/kern_a.bin" | awk '{print $1}')
CKB=$(cksum < "$WORK/kern_b.bin" | awk '{print $1}')
[ "$CKA" != "$CKB" ] \
    && ok "the two slots' .linux sections are DIFFERENT BYTES (cksum $CKA vs $CKB)" \
    || bad "the two slots carry the SAME kernel bytes -- every boot assertion below is meaningless"
grep -q "$SLOTMARK" "$WORK/cl_b.txt" \
    && ok "slot B's baked-in cmdline carries '$SLOTMARK'" \
    || bad "slot B's cmdline does not carry the marker"
grep -q "$SLOTMARK" "$WORK/cl_a.txt" \
    && bad "slot A's cmdline ALSO carries the marker -- it cannot distinguish anything" \
    || ok "slot A's cmdline does NOT carry the marker"
grep -q "root=PARTUUID=$PU" "$WORK/cl_b.txt" \
    && ok "slot B names the same root partition slot A does" \
    || bad "slot B names a different root -- a failure to boot it would prove nothing about A/B"
[ "$FAIL" = 0 ] || { printf '\n  %d PASSED / %d FAILED\n' "$PASS" "$FAIL"; exit 1; }

# --- 1. THE SHIPPED LAYOUT --------------------------------------------------
say "1. WHAT THE BUILD ACTUALLY WROTE ONTO THE ESP"
esp_get "$WORK/pristine.img" /EFI/BOOT/BOOTX64.EFI "$WORK/boot_efi.bin" \
    && ok "EFI/BOOT/BOOTX64.EFI is present -- the one file firmware executes" \
    || bad "no EFI/BOOT/BOOTX64.EFI on the ESP"
if cmp -s "$WORK/boot_efi.bin" "$SDBOOT"; then
    ok "and it is systemd-boot BYTE FOR BYTE -- not a kernel image, so an update never rewrites it"
else
    bad "EFI/BOOT/BOOTX64.EFI is not the systemd-boot binary this build was given"
fi
if pe_section "$WORK/boot_efi.bin" .linux >/dev/null 2>&1; then
    bad "the file firmware runs still EMBEDS a kernel -- the 176 MB rewrite window is still there"
else
    ok "the file firmware runs embeds NO kernel (.linux absent) -- nothing large is ever rewritten in place"
fi
esp_get "$WORK/pristine.img" /EFI/Linux/hamnix-a.efi "$WORK/slot_a_onesp.bin" \
    && ok "slot A is on the ESP at EFI/Linux/hamnix-a.efi" \
    || bad "slot A is not on the ESP"
cmp -s "$WORK/slot_a_onesp.bin" "$WORK/uki_a.efi" \
    && ok "and it is the UKI this build produced, byte for byte" \
    || bad "the slot A on the ESP is not the UKI the build produced"
esp_get "$WORK/pristine.img" /loader/loader.conf "$WORK/lc.bin" \
    && ok "loader/loader.conf is on the ESP" \
    || bad "no loader/loader.conf on the ESP"
LCLEN=$(stat -Lc%s "$WORK/lc.bin" 2>/dev/null || echo 0)
[ "$LCLEN" = "$LOADER_CONF_BYTES" ] \
    && ok "loader.conf is PREALLOCATED at exactly $LOADER_CONF_BYTES bytes -- a flip allocates no cluster" \
    || bad "loader.conf is $LCLEN bytes, not $LOADER_CONF_BYTES -- a flip would mutate the FAT chain"
grep -q 'default hamnix-a.efi' "$WORK/lc.bin" \
    && ok "loader.conf names slot A" || bad "loader.conf does not name slot A"
if esp_get "$WORK/pristine.img" /EFI/Linux/hamnix-b.efi "$WORK/should_not_exist.bin"; then
    bad "slot B is ALREADY written on a fresh medium -- it should be empty space"
else
    ok "slot B is not written on a fresh medium; it is the room the first update fills"
fi
# The room has to actually be there, or the first update fails on a full ESP.
FREE=$(mdir -i "$WORK/pristine.img@@$(esp_off "$WORK/pristine.img")" :: 2>/dev/null \
       | grep -oE '[0-9 ]+ bytes free' | tr -d ' a-z')
NEED=$(stat -Lc%s "$WORK/uki_b.efi")
info "ESP free: $FREE bytes; a second slot needs $NEED bytes"
[ -n "$FREE" ] && [ "$FREE" -ge "$NEED" ] \
    && ok "the ESP has room for the second slot WITHOUT growing the partition" \
    || bad "the ESP does not have room for a second slot (free=$FREE need=$NEED)"

# --- 2. BOOT 1 --------------------------------------------------------------
say "2. BOOT 1 -- the machine as built, before any update"
boot "$WORK/pristine.img" b1
K=$(booted_kernel b1)
[ "$K" = A ] && ok "boot 1 ran slot A's kernel $NUM_A (its own banner says so)" \
             || bad "boot 1 ran '$K', not slot A"
grep -q "$SLOTMARK" "$WORK/b1.txt" \
    && bad "boot 1's command line carries slot B's marker" \
    || ok "boot 1's command line does NOT carry slot B's marker"

# --- 3. THE UPDATE, IN THE ORDER THE DESIGN REQUIRES ------------------------
say "3. THE UPDATE -- write the INACTIVE slot, read it back, and only then flip"
cp "$WORK/pristine.img" "$WORK/updated.img"
esp_put "$WORK/updated.img" /EFI/Linux/hamnix-b.efi "$WORK/uki_b.efi" \
    && ok "slot B written into the free space beside slot A" \
    || bad "could not write slot B"
# THE READ-BACK. bootsync makes the same argument: a write that reported success
# and landed wrong has happened in this tree before, so the bytes are compared
# to the ones they came from BEFORE anything points the firmware at them.
esp_get "$WORK/updated.img" /EFI/Linux/hamnix-b.efi "$WORK/readback_b.bin"
cmp -s "$WORK/readback_b.bin" "$WORK/uki_b.efi" \
    && ok "slot B reads back byte for byte -- verified BEFORE the flip, never after" \
    || bad "slot B did not read back correctly"
esp_get "$WORK/updated.img" /EFI/Linux/hamnix-a.efi "$WORK/a_after_write.bin"
cmp -s "$WORK/a_after_write.bin" "$WORK/uki_a.efi" \
    && ok "slot A is UNTOUCHED by the write of slot B -- the old kernel is still there" \
    || bad "writing slot B disturbed slot A"
mkconf hamnix-b.efi "$WORK/lc.b" || { bad "loader.conf B is not $LOADER_CONF_BYTES bytes"; exit 1; }
esp_put "$WORK/updated.img" /loader/loader.conf "$WORK/lc.b"
esp_get "$WORK/updated.img" /loader/loader.conf "$WORK/lc.check"
[ "$(stat -Lc%s "$WORK/lc.check")" = "$LOADER_CONF_BYTES" ] \
    && ok "after the flip loader.conf is STILL exactly $LOADER_CONF_BYTES bytes" \
    || bad "the flip changed loader.conf's length"

say "4. BOOT 2 -- did the kernel actually change?"
boot "$WORK/updated.img" b2
K=$(booted_kernel b2)
[ "$K" = B ] && ok "BOOT 2 RAN SLOT B'S KERNEL $NUM_B -- THE KERNEL AN INSTALLED MACHINE BOOTS WAS REPLACED" \
             || bad "boot 2 ran '$K', not slot B -- the update did not take"
grep -q "$SLOTMARK" "$WORK/b2.txt" \
    && ok "and boot 2's command line carries '$SLOTMARK', which only slot B's image contains" \
    || bad "boot 2's command line does not carry slot B's marker"
grep -q "Linux version $NUM_A" "$WORK/b2.txt" \
    && bad "boot 2 also shows the OLD kernel $NUM_A" \
    || ok "boot 2 shows no trace of the old kernel $NUM_A"

say "5. IS THE OLD SLOT STILL INTACT? -- flip back and boot it"
cp "$WORK/updated.img" "$WORK/rolledback.img"
mkconf hamnix-a.efi "$WORK/lc.a" || { bad "loader.conf A is not $LOADER_CONF_BYTES bytes"; exit 1; }
esp_put "$WORK/rolledback.img" /loader/loader.conf "$WORK/lc.a"
boot "$WORK/rolledback.img" b3
K=$(booted_kernel b3)
[ "$K" = A ] && ok "the machine went BACK to slot A's kernel $NUM_A -- the old slot survived the update" \
             || bad "rollback ran '$K', not slot A"

# --- 6/7. THE POWER BUTTON, AND ITS NEGATIVE CONTROL ------------------------
say "6. ARM I -- POWER LOST WHILE SLOT B IS BEING WRITTEN (loader.conf still names A)"
cp "$WORK/pristine.img" "$WORK/torn.img"
# The state the disk is in for the whole copy: a prefix of the new image, and
# then whatever was there. Modelled by writing a truncated slot B.
head -c $(( NEED / 3 )) "$WORK/uki_b.efi" > "$WORK/half_b.efi"
head -c $(( NEED / 3 )) /dev/zero        >> "$WORK/half_b.efi"
esp_put "$WORK/torn.img" /EFI/Linux/hamnix-b.efi "$WORK/half_b.efi"
boot "$WORK/torn.img" b4
K=$(booted_kernel b4)
[ "$K" = A ] && ok "THE MACHINE BOOTED, on the old kernel $NUM_A, with a half-written slot B beside it" \
             || bad "an interrupted slot-B write left the machine at '$K'"

say "7. ARM II -- THE NEGATIVE CONTROL: the SAME torn slot B, but ALREADY flipped to"
say "   (this arm must NOT boot; if it does, arm I proved nothing)"
cp "$WORK/torn.img" "$WORK/torn_flipped.img"
esp_put "$WORK/torn_flipped.img" /loader/loader.conf "$WORK/lc.b"
boot "$WORK/torn_flipped.img" b5 90
K=$(booted_kernel b5)
info "arm II booted: $K"
if [ "$K" = NONE ]; then
    ok "pointing the loader at an INCOMPLETE slot really does cost the boot -- so arm I is a real result, and the flip-last order is MEASURED, not preferred"
else
    bad "arm II booted '$K' anyway -- this firmware tolerates a torn image, and the ordering rule above is untested"
fi

say "8. THE WORST A TORN 512-BYTE loader.conf WRITE CAN LEAVE"
cp "$WORK/updated.img" "$WORK/zeroconf.img"
head -c "$LOADER_CONF_BYTES" /dev/zero > "$WORK/lc.zero"
esp_put "$WORK/zeroconf.img" /loader/loader.conf "$WORK/lc.zero"
boot "$WORK/zeroconf.img" b6
K=$(booted_kernel b6)
info "with loader.conf entirely zeroed the machine booted: $K"
[ "$K" != NONE ] \
    && ok "a destroyed loader.conf still boots (slot $K) -- sd-boot falls back to discovering the entries" \
    || bad "a destroyed loader.conf left the machine unbootable"

printf '\n  %d PASSED / %d FAILED\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
