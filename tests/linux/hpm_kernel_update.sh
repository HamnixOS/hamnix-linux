#!/usr/bin/env bash
#
# REGISTRATION: this gate is ON-DEMAND. It is not in ci_battery_manifest.txt
# because it builds two 4 GiB media and boots seven machines under
# `qemu-system-x86_64`, the same reason tests/linux/ab_kernel_slots.sh and
# tests/linux/bootsync_installed.sh are not.
#
# tests/linux/hpm_kernel_update.sh — DOES A MACHINE THAT RUNS `hpm update`
# BOOT A DIFFERENT KERNEL AFTERWARDS, WITH THE OLD ONE STILL THERE?
#
# THE QUESTION, AND HOW IT DIFFERS FROM THE GATE BEFORE IT
# ========================================================
# tests/linux/ab_kernel_slots.sh proved the A/B LAYOUT works: a machine booted,
# its slot was switched, and it booted a genuinely different kernel. But every
# write in that gate was done FROM THE HOST, with mcopy, against an image file
# while nothing was running. Nothing on the machine could write a slot, nothing
# could flip loader.conf, and `hpm update` left the kernel alone.
#
# This gate asks the other question, and it is the one the owner asked:
#
#     THE MACHINE BOOTS. `hpm update` RUNS ON IT. IT REBOOTS. IS THE KERNEL
#     DIFFERENT, AND IS THE OLD ONE STILL WHOLE?
#
# Nothing here writes the ESP from the host except to STAGE and to READ. The
# writes under test are done by /bin/hkslot, running on the machine, driven by
# /bin/hpm, out of an Ed25519-signed index the machine fetched itself.
#
# THE TRAP, STATED FIRST BECAUSE IT HAS ALREADY CAUGHT THIS TASK ONCE
# ===================================================================
# A MACHINE THAT BOOTS LOOKS IDENTICAL WHETHER IT TOOK THE UPDATE OR SILENTLY
# FELL BACK. In ab_kernel_slots.sh's red arm the machine came up perfectly in
# every one of its fifteen failures. So, before anything is measured:
#
#   1. THE TWO SLOTS ARE BUILT FROM DIFFERENT HOST KERNELS, and what is read
#      back is the RUNNING KERNEL'S OWN BANNER on the serial console --
#      `Linux version 6.12.x` -- printed before any userland exists. No
#      fallback can forge it, because the kernel that prints it is the kernel
#      that is executing.
#   2. THE NEW SLOT'S BAKED-IN COMMAND LINE CARRIES A MARKER the old one does
#      not. It is a PE section of the new image, so it can only appear on a
#      boot that ran that image.
#
# Section 0 proves both distinguishers and STOPS THE GATE if the two images
# are the same bytes. An assertion that cannot fail is worse than none.
#
# AND THE POWER BUTTON, WHICH IS THE PART THAT MATTERS MORE THAN THE HAPPY PATH
# =============================================================================
# ab_kernel_slots.sh's interruption arm was a MODEL: the torn on-disk state was
# written from the host, because no on-machine writer existed. There is one
# now, so this gate does the real thing: it SIGKILLs QEMU -- no shutdown of any
# kind, which tests/linux/boot_log.sh established is the equivalent of pulling
# the plug -- timed off a PROGRESS LINE FROM INSIDE THE WRITE LOOP. hkslot
# reports every 2 MiB, and the kill lands on the first of those, with about
# thirty-five more chunks still to write.
#
# AND IT CHECKS THAT THE TEAR REALLY HAPPENED. If the write finished before the
# kill, the image is not torn and the arm proves nothing; so the slot is pulled
# off the medium and must be NEITHER the old kernel NOR the complete new one.
# That check is what stops this arm from being a boot that was never at risk.
#
# THE NEGATIVE CONTROL IS AN ARM OF THIS SAME RUN
# ===============================================
# A SECOND medium, built identically, whose kernel artifact has had one byte
# flipped while the SIGNED index still records the original digest. Everything
# else is the same: same machine, same `hpm update`, same reboot. On it,
# `hpm update` must EXIT NON-ZERO, loader.conf must still name the old slot,
# and the reboot must run the OLD kernel. Those are the exact inversions of the
# assertions the green arm makes, so between the two arms every load-bearing
# assertion here has been seen both ways.
#
# Usage: tests/linux/hpm_kernel_update.sh
# Env:   HAMLINUX_HK_WORK      where to build and boot
#        HAMLINUX_HK_REUSE=1   reuse media already built there
#        HAMLINUX_HK_KILL_S    seconds after the 2 MiB progress line to
#                              SIGKILL the guest (default 0 -- see KILL_S)
#        HAMLINUX_HK_KEEPIMAGE=1  reuse build/image and the saved per-kernel
#                              initramfs instead of building the image twice
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"
# FIRST, before reap.sh and before $WORK -- the contract in
# tests/linux/private_ns.sh. gates_are_private.sh checks that this line is here.
. tests/linux/private_ns.sh
priv_ns_reexec "$@"
. tests/linux/reap.sh

WORK="${HAMLINUX_HK_WORK:-$HOME/.hamnix-build/hpmkernel/gate}"
mkdir -p "$WORK"
reap_track "$WORK/reaped"
reap_on_exit :

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  PASS  %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$*"; }
say()  { printf '\n== %s\n' "$*"; }
info() { printf '  ..    %s\n' "$*"; }

export PATH="$PATH:/usr/sbin:/sbin"
for t in qemu-system-x86_64 mcopy mdir sgdisk objcopy python3; do
    command -v "$t" >/dev/null || { bad "need $t"; exit 1; }
done
[ -f /usr/share/OVMF/OVMF_CODE_4M.fd ] || { bad "need OVMF"; exit 1; }
SDBOOT=/usr/lib/systemd/boot/efi/systemd-bootx64.efi
[ -f "$SDBOOT" ] || { bad "need systemd-boot at $SDBOOT"; exit 1; }
SEED=scripts/hpm_local_key.seed
[ -f "$SEED" ] || { bad "need the committed local signing seed at $SEED"; exit 1; }

# TWO DIFFERENT HOST KERNELS. The highest for the slot the medium ships with,
# a different one for the kernel the update carries.
mapfile -t KERNELS < <(ls -1 /boot/vmlinuz-* 2>/dev/null | sort -V)
if [ "${#KERNELS[@]}" -lt 2 ]; then
    bad "this host has ${#KERNELS[@]} kernel(s) under /boot; the gate needs two DIFFERENT ones to tell the slots apart"
    exit 1
fi
KERN_OLD="${KERNELS[-1]}"
KERN_NEW="${KERNELS[0]}"
VER_OLD="$(basename "$KERN_OLD" | sed 's/^vmlinuz-//')"
VER_NEW="$(basename "$KERN_NEW" | sed 's/^vmlinuz-//')"
NUM_OLD="$(printf '%s' "$VER_OLD" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+')"
NUM_NEW="$(printf '%s' "$VER_NEW" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+')"
SLOTMARK="hamnix.kupdate=NEW"
PU="${HAMLINUX_HK_PARTUUID:-21111111-2222-3333-4444-555555555555}"
# ZERO by default. The kill is timed off a marker printed 2 MiB into a 74 MB
# copy, so any positive delay is a gamble against how fast this host writes --
# and on this host the whole copy takes under two seconds.
KILL_S="${HAMLINUX_HK_KILL_S:-0}"
LOADER_CONF_BYTES=512
REPO_DIR=/hamrepo                 # on the machine's ext4 root
KVER_NEW=1.0.33

esp_off() { echo $(( $(sgdisk -i 1 "$1" | awk '/First sector/ {print $3}') * 512 )); }
esp_get() { mcopy -n -o -i "${1}@@$(esp_off "$1")" "::$2" "$3" 2>/dev/null; }
esp_put() { mcopy -o -i "${1}@@$(esp_off "$1")" "$3" "::$2" 2>/dev/null; }

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

# Boot a disk under OVMF with <rc> staged as \PHASE.RC. With <kill-after> set,
# SIGKILL the guest that many seconds after <marker> appears on the serial
# console -- the power button, timed off something the guest said rather than
# off how long the boot took.
boot_phase() { # boot_phase <img> <rc> <tag> [kill-after-s] [marker] [max-s]
    local img="$1" rc="$2" tag="$3" after="${4:-}" marker="${5:-}" maxs="${6:-240}"
    [ -n "$rc" ] && esp_put "$img" "/PHASE.RC" "$rc"
    rm -f "$WORK/$tag.log" "$WORK/vars_$tag.fd"
    cp /usr/share/OVMF/OVMF_VARS_4M.fd "$WORK/vars_$tag.fd"
    qemu-system-x86_64 -machine q35 -accel kvm -m 2048 -smp 2 \
        -display none -no-reboot \
        -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
        -drive if=pflash,format=raw,unit=1,file="$WORK/vars_$tag.fd" \
        -drive "file=$img,format=raw,if=virtio,cache=writethrough" \
        -serial "file:$WORK/$tag.log" -monitor none >/dev/null 2>&1 &
    local qp=$!
    reap_add "$qp"
    local i
    if [ -n "$after" ]; then
        local seen=0
        for i in $(seq 1 $((maxs * 50))); do
            if grep -q "$marker" "$WORK/$tag.log" 2>/dev/null; then seen=1; break; fi
            kill -0 "$qp" 2>/dev/null || break
            sleep 0.02
        done
        if [ "$seen" = 1 ]; then
            sleep "$after"
            kill -9 "$qp" 2>/dev/null
            info "$tag: SIGKILL ${after}s after '$marker' -- the power button"
        else
            kill -9 "$qp" 2>/dev/null
            info "$tag: '$marker' never appeared; killed after the timeout"
        fi
    else
        for i in $(seq 1 "$maxs"); do kill -0 "$qp" 2>/dev/null || break; sleep 1; done
        kill -9 "$qp" 2>/dev/null
    fi
    wait "$qp" 2>/dev/null
    # `tr -d '\r'` IS LOAD BEARING -- the serial console ends every line CR LF,
    # and two gates in this directory each paid a whole run to learn that.
    tr -d '\r' < "$WORK/$tag.log" > "$WORK/$tag.txt" 2>/dev/null || :
}

# Which kernel actually executed, off its own banner: OLD, NEW, BOTH or NONE.
booted_kernel() {
    local a=0 b=0
    grep -q "Linux version $NUM_OLD" "$WORK/$1.txt" 2>/dev/null && a=1
    grep -q "Linux version $NUM_NEW" "$WORK/$1.txt" 2>/dev/null && b=1
    if   [ $a = 1 ] && [ $b = 1 ]; then echo BOTH
    elif [ $a = 1 ]; then echo OLD
    elif [ $b = 1 ]; then echo NEW
    else echo NONE; fi
}

say "the host's kernels, and the two images the machine has to tell apart"
info "the medium ships:      $VER_OLD"
info "the update carries:    $VER_NEW"
[ "$NUM_OLD" != "$NUM_NEW" ] \
    && ok "the two images are built from DIFFERENT kernel versions ($NUM_OLD vs $NUM_NEW)" \
    || { bad "both images would carry kernel $NUM_OLD -- nothing below could tell them apart"; exit 1; }

# --- the media -------------------------------------------------------------
if [ "${HAMLINUX_HK_REUSE:-0}" = 1 ] && [ -f "$WORK/good.img" ] \
   && [ -f "$WORK/red.img" ] && [ -f "$WORK/uki_new.efi" ] && [ -f "$WORK/uki_old.efi" ]; then
    info "reusing the media in $WORK"
else
    say "building the root, then the UPDATE's kernel image through the shipped path"
    # REBUILT EXPLICITLY: scripts/hamlinux_disk.sh rebuilds build/image/root only
    # when it is ABSENT, so a second run would otherwise package whatever tree
    # was lying there -- the stale-artifact false report boot_log.sh paid for.
    # THE IMAGE IS BUILT TWICE, ONCE PER KERNEL, AND THE FIRST RUN OF THIS
    # GATE IS WHY.
    #
    # scripts/hamlinux_image.sh stages the modules of ONE kernel -- the newest
    # under the host's /boot -- into both the root and the initramfs. Swapping
    # only build/image/vmlinuz, which is what tests/linux/ab_kernel_slots.sh
    # does, produces a UKI that is INTERNALLY INCONSISTENT: kernel 6.12.43
    # with an initramfs full of 6.12.85 modules. That image boots -- its banner
    # and its baked-in cmdline both prove the new kernel really ran -- and then
    # `virtio_blk: disagrees about version of symbol set_capacity_and_notify`
    # 3013 times, no /dev/vda, and user/linuxinit.ad waits out its 20-second
    # root timeout and drops into the initramfs shell.
    #
    # That is a defect of the HARNESS, not of the slot mechanism, and it would
    # have been very easy to read as one of the mechanism: the machine came up
    # on the new kernel and was not usable. So the initramfs the update's UKI
    # carries is built from the update's OWN kernel, and the medium's root
    # carries BOTH module trees so either kernel can modprobe after the switch.
    if [ "${HAMLINUX_HK_KEEPIMAGE:-0}" = 1 ] && [ -d build/image/root ] \
       && [ -f "$WORK/initrd_new.cpio.gz" ] && [ -d "$WORK/mods_new" ]; then
        info "HAMLINUX_HK_KEEPIMAGE=1: reusing the build/image already present"
        info "  (this SKIPS the check that the root was built from this tree)"
    else
        # PASS 1 -- the UPDATE's kernel. Its initramfs and its module tree are
        # kept; everything else is thrown away by pass 2.
        HAMLINUX_KVER="$VER_NEW" HAMLINUX_DISTRO_RO=1 scripts/hamlinux_image.sh \
            >"$WORK/image_new.log" 2>&1 \
            || { bad "the image build for $VER_NEW failed -- see $WORK/image_new.log"; exit 1; }
        [ -d "build/image/root/lib/modules/$VER_NEW" ] \
            || { bad "the image build for $VER_NEW staged no /lib/modules/$VER_NEW -- HAMLINUX_KVER is not honoured by scripts/hamlinux_image.sh"; exit 1; }
        cp build/image/initramfs.cpio.gz "$WORK/initrd_new.cpio.gz"
        rm -rf "$WORK/mods_new"
        cp -a "build/image/root/lib/modules/$VER_NEW" "$WORK/mods_new"
        ok "pass 1: an initramfs whose modules are $VER_NEW's, for the update's kernel"

        # PASS 2 -- the kernel the medium ships. This is the root that goes on
        # both media.
        HAMLINUX_DISTRO_RO=1 scripts/hamlinux_image.sh >"$WORK/image.log" 2>&1 \
            || { bad "scripts/hamlinux_image.sh failed -- see $WORK/image.log"; exit 1; }
        ok "pass 2: build/image/root rebuilt from this tree, for $VER_OLD"
    fi
    # BOTH module trees on the root, so whichever kernel boots can resolve a
    # module by name after the root switch.
    cp -a "$WORK/mods_new" "build/image/root/lib/modules/$VER_NEW"
    [ -d "build/image/root/lib/modules/$VER_OLD" ] \
        && ok "the medium's root carries BOTH module trees ($VER_OLD and $VER_NEW)" \
        || bad "the medium's root has no /lib/modules/$VER_OLD"
    cp build/image/initramfs.cpio.gz "$WORK/initrd_old.cpio.gz"
    [ -x build/image/root/bin/hkslot ] \
        && ok "/bin/hkslot is in the image -- the machine has a slot writer" \
        || { bad "/bin/hkslot is NOT in the image; nothing below can run"; exit 1; }
    [ -x build/image/root/bin/hpm ] \
        && ok "/bin/hpm is in the image" \
        || { bad "/bin/hpm is NOT in the image"; exit 1; }
    cp build/image/vmlinuz "$WORK/vmlinuz.image"

    # THE UPDATE'S KERNEL IMAGE, built through scripts/hamlinux_disk.sh rather
    # than by a private objcopy here, so what the machine writes into its slot
    # is a UKI this tree really produces -- reservation, UKI.MAP and all.
    # BOTH HALVES OF THE UPDATE'S UKI COME FROM THE SAME KERNEL. The vmlinuz
    # AND the initramfs -- see the note above about what happens when only one
    # of them is swapped.
    cp -L "$KERN_NEW" build/image/vmlinuz
    cp "$WORK/initrd_new.cpio.gz" build/image/initramfs.cpio.gz
    CMDLINE_NEW="earlycon=efifb console=ttyS0,115200 console=tty0 root=PARTUUID=$PU rw panic=-1 loglevel=7 printk.devkmsg=on hung_task_timeout_secs=30 sysrq_always_enabled $SLOTMARK"
    HAMLINUX_DISTRO_RO=1 HAMLINUX_AB_SLOTS=1 HAMLINUX_ROOT_PARTUUID="$PU" \
        HAMLINUX_CMDLINE="$CMDLINE_NEW" \
        scripts/hamlinux_disk.sh "$WORK/scratch_new.img" 4G >"$WORK/disk_new.log" 2>&1 \
        || { bad "the update's medium would not build -- see $WORK/disk_new.log"; exit 1; }
    cp build/image/disk/BOOTX64.EFI "$WORK/uki_new.efi"
    ok "the update's kernel image built from $VER_NEW, carrying '$SLOTMARK'"

    # THE MACHINE'S OWN /etc/rc.boot: the SHIPPED one verbatim, then whatever
    # \PHASE.RC on the FAT boot partition says. That is how the host changes
    # what each boot does between boots without touching the ext4 root.
    # IT DOES NOT `source '/etc/rc.boot.installed'` FIRST, AND THAT COST A RUN.
    #
    # tests/linux/bootsync_installed.sh's rc does exactly that and then asks
    # its questions, and it worked when it was written. It does not any more:
    # rc.boot.installed now ends by entering runlevel 5, and rc.5 BLOCKS in
    # /bin/hamgreet waiting for somebody to type a password (see
    # user/hamgreet.ad -- PID 1's rc deliberately does not return until the
    # login is answered). So everything after the source line never ran. The
    # first run of this gate scored four FAILs on boot 1 -- "the machine did
    # not report an active slot", with an EMPTY quoted reason, because the
    # machine had never been asked.
    #
    # This rc therefore does the ONE thing from the shipped boot that the
    # programs under test need -- `bind '#esp' /boot`, which is what puts the
    # kernel slots and loader.conf where hkslot looks for them -- and then
    # runs the phase script. No network (the repository is a file:// path on
    # this machine's own root), no distro namespace, no runlevel 5, no
    # greeter. Each phase ends in `init 0`, so the shipped rc is never
    # reached and there is nothing to block.
    cat >"$WORK/rc.proof" <<'RCEOF'
echo 'HK-BEGIN'
ln -s /dev/console /dev/cons
esp_ok = 1
try {
    bind '#esp' /boot
} except {
    esp_ok = 0
}
if $esp_ok > 0 {
    echo 'HK-ESP=bound'
} else {
    echo 'HK-ESP=FAILED'
}
source '/boot/PHASE.RC'
echo 'HK-END'
RCEOF

    # THE REPOSITORY LIVES ON THE MACHINE'S OWN ROOT, and hpm reads it as
    # file:///hamrepo/ -- the same code path the live medium's
    # file:///iso-packages/ mirror uses. Its index is signed with the
    # COMMITTED local seed (scripts/hpm_local_key.seed) against the trust root
    # the image already ships (etc/hpm/local-trusted.pub), so hpm's signature
    # check is the real one and not a bypass: --allow-unsigned is never passed
    # anywhere in this gate.
    build_repo() {   # build_repo <artifact> <recorded-sha> <root-dir>
        local art="$1" sha="$2" root="$3"
        rm -rf "$root$REPO_DIR"
        mkdir -p "$root$REPO_DIR/linux/kernel"
        cp "$art" "$root$REPO_DIR/linux/kernel/hamnix-$KVER_NEW.efi"
        python3 - "$root$REPO_DIR/linux/index.json" "$sha" \
                 "$(stat -Lc%s "$art")" "$KVER_NEW" <<'PY'
import json, sys
out, sha, size, ver = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
json.dump({"schema": 1, "repo": "HamnixOS/packages", "channel": "linux",
           "url": "file://" + "/hamrepo/linux/", "updated": "2026-08-19",
           "packages": [],
           "kernel": {"version": ver,
                      "url": "kernel/hamnix-%s.efi" % ver,
                      "sha256": sha, "size": size}},
          open(out, "w"), indent=2)
open(out, "a").write("\n")
PY
        python3 scripts/hpm_sign.py sign "$root$REPO_DIR/linux/index.json" \
            "$SEED" "$root$REPO_DIR/linux/index.json.sig" >/dev/null
        # THE PACKAGE DATABASE. Without one `hpm update` REFUSES outright
        # ("no package database ... REFUSING") and never reaches the kernel at
        # all -- a real behaviour of this tree, and one worth naming here
        # rather than discovering as a mystery exit 1.
        mkdir -p "$root/var/lib/hpm"
        printf '{"schema":1,"packages":[]}\n' > "$root/var/lib/hpm/installed.json"
    }

    SHA_NEW=$(sha256sum "$WORK/uki_new.efi" | cut -d' ' -f1)
    info "the update's kernel image is $(stat -Lc%s "$WORK/uki_new.efi") bytes, sha256 $SHA_NEW"

    # --- MEDIUM 1: the good one -------------------------------------------
    build_repo "$WORK/uki_new.efi" "$SHA_NEW" build/image/root
    cp -L "$KERN_OLD" build/image/vmlinuz
    cp "$WORK/initrd_old.cpio.gz" build/image/initramfs.cpio.gz
    HAMLINUX_DISTRO_RO=1 HAMLINUX_AB_SLOTS=1 HAMLINUX_ROOT_PARTUUID="$PU" \
        HAMLINUX_DISK_RC="$WORK/rc.proof" \
        scripts/hamlinux_disk.sh "$WORK/good.img" 4G >"$WORK/disk_good.log" 2>&1 \
        || { bad "the good medium would not build -- see $WORK/disk_good.log"; exit 1; }
    cp build/image/disk/BOOTX64.EFI "$WORK/uki_old.efi"
    ok "good medium built; $(grep -o 'A/B: .*' "$WORK/disk_good.log" | head -1)"

    # --- MEDIUM 2: THE NEGATIVE CONTROL -----------------------------------
    # Identical in every respect except ONE BYTE of the artifact, with the
    # index still recording the ORIGINAL digest and still validly signed. So
    # the signature check passes and the CONTENT check must fail -- which is
    # the check that stands between this machine and a kernel somebody else
    # wrote.
    cp "$WORK/uki_new.efi" "$WORK/uki_corrupt.efi"
    python3 - "$WORK/uki_corrupt.efi" <<'PY'
import sys
p = sys.argv[1]
b = bytearray(open(p, "rb").read())
off = len(b) // 2
b[off] ^= 0xFF
open(p, "wb").write(bytes(b))
print("flipped one byte at offset", off)
PY
    build_repo "$WORK/uki_corrupt.efi" "$SHA_NEW" build/image/root
    HAMLINUX_DISTRO_RO=1 HAMLINUX_AB_SLOTS=1 HAMLINUX_ROOT_PARTUUID="$PU" \
        HAMLINUX_DISK_RC="$WORK/rc.proof" \
        scripts/hamlinux_disk.sh "$WORK/red.img" 4G >"$WORK/disk_red.log" 2>&1 \
        || { bad "the negative-control medium would not build -- see $WORK/disk_red.log"; exit 1; }
    ok "negative-control medium built (one byte of the artifact flipped; the index still records the ORIGINAL digest)"

    cp "$WORK/vmlinuz.image" build/image/vmlinuz
    rm -f "$WORK/scratch_new.img"
fi

# --- 0. THE DISTINGUISHER, PROVED BEFORE IT IS TRUSTED ----------------------
say "0. CAN THIS GATE TELL THE TWO KERNELS APART AT ALL? (checked first; the rest is void without it)"
pe_section "$WORK/uki_old.efi" .linux   > "$WORK/kern_old.bin" 2>/dev/null || { bad "the shipped UKI has no .linux section"; exit 1; }
pe_section "$WORK/uki_new.efi" .linux   > "$WORK/kern_new.bin" 2>/dev/null || { bad "the update's UKI has no .linux section"; exit 1; }
pe_section "$WORK/uki_old.efi" .cmdline > "$WORK/cl_old.txt"   2>/dev/null || { bad "the shipped UKI has no .cmdline"; exit 1; }
pe_section "$WORK/uki_new.efi" .cmdline > "$WORK/cl_new.txt"   2>/dev/null || { bad "the update's UKI has no .cmdline"; exit 1; }
CKO=$(cksum < "$WORK/kern_old.bin" | awk '{print $1}')
CKN=$(cksum < "$WORK/kern_new.bin" | awk '{print $1}')
[ "$CKO" != "$CKN" ] \
    && ok "the two images' .linux sections are DIFFERENT BYTES (cksum $CKO vs $CKN)" \
    || bad "the two images carry the SAME kernel bytes -- every boot assertion below is meaningless"
grep -q "$SLOTMARK" "$WORK/cl_new.txt" \
    && ok "the update's baked-in cmdline carries '$SLOTMARK'" \
    || bad "the update's cmdline does not carry the marker"
grep -q "$SLOTMARK" "$WORK/cl_old.txt" \
    && bad "the SHIPPED cmdline ALSO carries the marker -- it cannot distinguish anything" \
    || ok "the shipped cmdline does NOT carry the marker"
grep -q "root=PARTUUID=$PU" "$WORK/cl_new.txt" \
    && ok "the update's image names the same root partition the shipped one does" \
    || bad "the update's image names a different root -- a failure to boot it would prove nothing"
[ "$FAIL" = 0 ] || { printf '\n  %d PASSED / %d FAILED\n' "$PASS" "$FAIL"; exit 1; }

# --- 1. WHAT THE BUILD WROTE, WHICH IS WHAT hkslot RELIES ON ----------------
say "1. THE SHIPPED LAYOUT -- both slots preallocated, so an update allocates no cluster"
esp_get "$WORK/good.img" /EFI/Linux/hamnix-a.efi "$WORK/slot_a0.bin" \
    && ok "slot A is on the ESP" || bad "slot A is not on the ESP"
esp_get "$WORK/good.img" /EFI/Linux/hamnix-b.efi "$WORK/slot_b0.bin" \
    && ok "slot B is PREALLOCATED on a fresh medium -- hkslot overwrites in place and never creates" \
    || bad "slot B is absent; hkslot would refuse to create it"
SZA=$(stat -Lc%s "$WORK/slot_a0.bin" 2>/dev/null || echo 0)
SZB=$(stat -Lc%s "$WORK/slot_b0.bin" 2>/dev/null || echo 0)
info "slot A $SZA bytes, slot B $SZB bytes"
[ "$SZA" != 0 ] && [ "$SZA" = "$SZB" ] \
    && ok "the two slots are the SAME LENGTH, so a write into either never extends a file" \
    || bad "the slots are $SZA and $SZB bytes"
cmp -s "$WORK/slot_a0.bin" "$WORK/uki_old.efi" \
    && ok "slot A is the UKI this build produced, byte for byte" \
    || bad "slot A is not the UKI the build produced"
NEWSZ=$(stat -Lc%s "$WORK/uki_new.efi")
[ "$NEWSZ" -le "$SZA" ] \
    && ok "the update's image ($NEWSZ bytes) fits the preallocated slot ($SZA bytes)" \
    || bad "the update's image is BIGGER than the slot; hkslot will refuse (and should)"
esp_get "$WORK/good.img" /loader/loader.conf "$WORK/lc0.bin" \
    && ok "loader/loader.conf is on the ESP" || bad "no loader.conf on the ESP"
[ "$(stat -Lc%s "$WORK/lc0.bin" 2>/dev/null || echo 0)" = "$LOADER_CONF_BYTES" ] \
    && ok "loader.conf is preallocated at exactly $LOADER_CONF_BYTES bytes" \
    || bad "loader.conf is not $LOADER_CONF_BYTES bytes"
grep -q 'default hamnix-a.efi' "$WORK/lc0.bin" \
    && ok "loader.conf names slot A" || bad "loader.conf does not name slot A"

# --- 2. BOOT 1 -- the machine before anything ------------------------------
printf "echo 'HK-PHASE=observe'\nhkslot --status\nhpm --repo=file://%s/ kernel\ninit 0\n" \
    "$REPO_DIR" >"$WORK/p_observe.rc"
printf "echo 'HK-PHASE=update'\nhpm --repo=file://%s/ update\necho \"HK-UPDATE-RC=\$status\"\nhkslot --status\ninit 0\n" \
    "$REPO_DIR" >"$WORK/p_update.rc"

say "2. BOOT 1 -- the machine as installed, and what IT says about its own slots"
cp "$WORK/good.img" "$WORK/main.img"
boot_phase "$WORK/main.img" "$WORK/p_observe.rc" b1
K=$(booted_kernel b1)
[ "$K" = OLD ] && ok "boot 1 ran the shipped kernel $NUM_OLD (its own banner says so)" \
               || bad "boot 1 ran '$K', not the shipped kernel"
# THESE TWO ARE CHECKED FIRST AND THE GATE STOPS ON THEM. Everything below is
# a grep for something the machine said; if the machine's rc never ran, or the
# ESP never got bound, every one of those greps fails for a reason that has
# NOTHING to do with the mechanism -- which is exactly what the first run of
# this gate reported, four FAILs deep, with an empty quoted reason.
grep -q "HK-BEGIN" "$WORK/b1.txt" \
    && ok "the machine's rc ran at all" \
    || { bad "the machine's rc never printed HK-BEGIN -- nothing below is about the mechanism"; printf '\n  %d PASSED / %d FAILED\n' "$PASS" "$FAIL"; exit 1; }
grep -q "HK-ESP=bound" "$WORK/b1.txt" \
    && ok "and it bound its own ESP at /boot, which is where the slots live" \
    || { bad "the machine could not bind '#esp' /boot -- hkslot has nothing to look at"; printf '\n  %d PASSED / %d FAILED\n' "$PASS" "$FAIL"; exit 1; }
grep -q "$SLOTMARK" "$WORK/b1.txt" \
    && bad "boot 1's command line already carries the update's marker" \
    || ok "boot 1's command line does NOT carry the update's marker"
grep -q "hkslot: active slot   hamnix-a.efi" "$WORK/b1.txt" \
    && ok "THE MACHINE ITSELF read its ESP and reported slot A active" \
    || bad "the machine did not report an active slot -- $(grep -m2 'hkslot:' "$WORK/b1.txt" | tr '\n' ' ')"
grep -q "hkslot: hamnix-b.efi  $SZB bytes" "$WORK/b1.txt" \
    && ok "and it sees the preallocated slot B at $SZB bytes" \
    || bad "the machine does not see a preallocated slot B"
grep -q "recorded kernel: (none" "$WORK/b1.txt" \
    && ok "hpm reports this machine has never taken a kernel update" \
    || bad "hpm's kernel record is not empty on a fresh machine"
grep -q "channel offers: $KVER_NEW" "$WORK/b1.txt" \
    && ok "AND THE MACHINE AUTHENTICATED ITS OWN INDEX and found kernel $KVER_NEW in it" \
    || bad "the machine did not find a kernel in its channel -- $(grep -m3 'hpm:' "$WORK/b1.txt" | tr '\n' ' ')"

# --- 3. BOOT 2 -- `hpm update` ---------------------------------------------
say "3. BOOT 2 -- \`hpm update\` RUNS ON THE MACHINE"
boot_phase "$WORK/main.img" "$WORK/p_update.rc" b2 "" "" 480
grep -q "hkslot: the new kernel matches the digest from the signed index" "$WORK/b2.txt" \
    && ok "the machine verified the artifact against the digest in the SIGNED index" \
    || bad "no digest check on the machine -- $(grep -m3 'hkslot:' "$WORK/b2.txt" | tr '\n' ' ')"
grep -q "hkslot: WROTE " "$WORK/b2.txt" \
    && ok "the machine wrote the inactive slot itself: $(grep -m1 'hkslot: WROTE' "$WORK/b2.txt")" \
    || bad "the machine did not write a slot"
grep -q "hkslot: the slot reads back at" "$WORK/b2.txt" \
    && ok "and it READ THE SLOT BACK OFF THE MEDIUM and hashed it before flipping" \
    || bad "no read-back on the machine"
grep -q "hkslot: committed. loader.conf now names hamnix-b.efi" "$WORK/b2.txt" \
    && ok "the machine flipped loader.conf LAST, to hamnix-b.efi" \
    || bad "the machine did not flip loader.conf"
grep -q "hpm: the kernel is now $KVER_NEW" "$WORK/b2.txt" \
    && ok "hpm recorded the new kernel version" || bad "hpm did not record the new kernel"
grep -q "HK-UPDATE-RC=0" "$WORK/b2.txt" \
    && ok "\`hpm update\` exited 0" \
    || bad "\`hpm update\` did not exit 0 -- $(grep -m1 'HK-UPDATE-RC' "$WORK/b2.txt")"
grep -q "hkslot: active slot   hamnix-b.efi" "$WORK/b2.txt" \
    && ok "and the machine, asked again in the same boot, now reports slot B active" \
    || bad "the machine still reports slot A active after the update"

say "3b. AND THE BYTES ON THE MEDIUM, read off the disk rather than off a log line"
esp_get "$WORK/main.img" /EFI/Linux/hamnix-b.efi "$WORK/slot_b1.bin"
cmp -s -n "$NEWSZ" "$WORK/slot_b1.bin" "$WORK/uki_new.efi" \
    && ok "slot B on the medium is the update's kernel image, byte for byte, for all $NEWSZ bytes" \
    || bad "slot B is not the update's image"
esp_get "$WORK/main.img" /EFI/Linux/hamnix-a.efi "$WORK/slot_a1.bin"
cmp -s "$WORK/slot_a1.bin" "$WORK/uki_old.efi" \
    && ok "SLOT A IS UNTOUCHED -- the old kernel is still whole on the disk" \
    || bad "the update disturbed slot A"
esp_get "$WORK/main.img" /loader/loader.conf "$WORK/lc1.bin"
[ "$(stat -Lc%s "$WORK/lc1.bin" 2>/dev/null || echo 0)" = "$LOADER_CONF_BYTES" ] \
    && ok "after the machine's own flip loader.conf is STILL exactly $LOADER_CONF_BYTES bytes" \
    || bad "the machine's flip changed loader.conf's length"
grep -q 'default hamnix-b.efi' "$WORK/lc1.bin" \
    && ok "and it names hamnix-b.efi" || bad "loader.conf does not name hamnix-b.efi"

# --- 4. BOOT 3 -- THE RESULT -----------------------------------------------
say "4. BOOT 3 -- DID THE MACHINE ACTUALLY BOOT A DIFFERENT KERNEL?"
boot_phase "$WORK/main.img" "$WORK/p_observe.rc" b3
K=$(booted_kernel b3)
[ "$K" = NEW ] \
    && ok "BOOT 3 RAN KERNEL $NUM_NEW -- \`hpm update\` REPLACED THE KERNEL AN INSTALLED MACHINE BOOTS" \
    || bad "boot 3 ran '$K', not the update's kernel -- the update did not take"
grep -q "$SLOTMARK" "$WORK/b3.txt" \
    && ok "and boot 3's command line carries '$SLOTMARK', which only the new image contains" \
    || bad "boot 3's command line does not carry the update's marker"
grep -q "Linux version $NUM_OLD" "$WORK/b3.txt" \
    && bad "boot 3 also shows the OLD kernel $NUM_OLD" \
    || ok "boot 3 shows no trace of the old kernel $NUM_OLD"
grep -q "recorded kernel: $KVER_NEW" "$WORK/b3.txt" \
    && ok "and the machine remembers, across the reboot, that its kernel is $KVER_NEW" \
    || bad "the machine's kernel record did not survive the reboot"
grep -q "kernel $KVER_NEW is already the one" "$WORK/b3.txt" \
    && info "(hpm kernel on boot 3 also re-checked the channel)" || :

# --- 5. IS THE OLD KERNEL STILL BOOTABLE? ----------------------------------
say "5. BOOT 4 -- flip back by hand and check the old slot still boots"
cp "$WORK/main.img" "$WORK/rolledback.img"
esp_put "$WORK/rolledback.img" /loader/loader.conf "$WORK/lc0.bin"
boot_phase "$WORK/rolledback.img" "$WORK/p_observe.rc" b4
K=$(booted_kernel b4)
[ "$K" = OLD ] \
    && ok "the machine went BACK to kernel $NUM_OLD -- the old slot survived the update intact" \
    || bad "the rollback ran '$K', not the old kernel"

# --- 6. THE POWER BUTTON, ON A REAL WRITE ----------------------------------
# THE MARKER IS A LINE FROM INSIDE THE WRITE LOOP, AND THE FIRST RUN OF THIS
# GATE IS WHY. It used to kill 2 s after `hkslot: WRITING`, which hkslot
# prints immediately BEFORE the first byte. On this host all 74 263 552 bytes
# had landed and loader.conf was already flipped -- the arm scored three FAILs
# saying so, which is the gate working, but it measured a machine that was
# never at risk. hkslot now reports progress every 2 MiB, so `hkslot: at
# 2097152` is a point unambiguously INSIDE the copy with about 35 more chunks
# still to write.
KILL_MARK="hkslot: at 2097152 of"
say "6. BOOT 5 -- SIGKILL THE GUEST ${KILL_S}s AFTER IT IS 2 MiB INTO WRITING THE SLOT"
say "   (a REAL killed guest, not a torn image written from the host)"
cp "$WORK/good.img" "$WORK/torn.img"
boot_phase "$WORK/torn.img" "$WORK/p_update.rc" b5 "$KILL_S" "$KILL_MARK" 480
grep -q "hkslot: WRITING" "$WORK/b5.txt" \
    && ok "the guest reached the write and said so before it was killed" \
    || bad "the guest never started writing -- this arm measured nothing"
grep -q "$KILL_MARK" "$WORK/b5.txt" \
    && ok "and it got at least 2 MiB in, so the kill landed INSIDE the copy" \
    || bad "the guest never reported passing 2 MiB -- the kill did not land inside the write"
grep -q "hkslot: committed" "$WORK/b5.txt" \
    && bad "the write COMPLETED before the kill -- nothing was interrupted, so this arm proves nothing (LOWER HAMLINUX_HK_KILL_S)" \
    || ok "the guest was killed before hkslot committed"
# AND THE TEAR IS CHECKED, NOT ASSUMED. If the slot on the medium is either the
# old image or the complete new one, the machine was never in a torn state and
# every assertion below would be about a boot that was never at risk.
esp_get "$WORK/torn.img" /EFI/Linux/hamnix-b.efi "$WORK/slot_b_torn.bin"
TORN_IS_OLD=1; cmp -s "$WORK/slot_b_torn.bin" "$WORK/uki_old.efi" || TORN_IS_OLD=0
TORN_IS_NEW=1; cmp -s -n "$NEWSZ" "$WORK/slot_b_torn.bin" "$WORK/uki_new.efi" || TORN_IS_NEW=0
info "the killed machine's slot B: same-as-old=$TORN_IS_OLD  same-as-new=$TORN_IS_NEW"
[ "$TORN_IS_OLD" = 0 ] && [ "$TORN_IS_NEW" = 0 ] \
    && ok "SLOT B REALLY IS TORN -- neither the old image nor the complete new one" \
    || bad "slot B is not torn (old=$TORN_IS_OLD new=$TORN_IS_NEW); this arm is about a machine that was never at risk"
esp_get "$WORK/torn.img" /loader/loader.conf "$WORK/lc_torn.bin"
grep -q 'default hamnix-a.efi' "$WORK/lc_torn.bin" \
    && ok "and loader.conf STILL names hamnix-a.efi -- the flip is last, so the kill could not reach it" \
    || bad "loader.conf was flipped despite the write being interrupted"
esp_get "$WORK/torn.img" /EFI/Linux/hamnix-a.efi "$WORK/slot_a_torn.bin"
cmp -s "$WORK/slot_a_torn.bin" "$WORK/uki_old.efi" \
    && ok "slot A is untouched by the interrupted write" \
    || bad "the interrupted write damaged slot A"

say "6b. BOOT 6 -- THE MACHINE WHOSE POWER WAS PULLED MID-WRITE"
boot_phase "$WORK/torn.img" "$WORK/p_observe.rc" b6
K=$(booted_kernel b6)
[ "$K" = OLD ] \
    && ok "IT BOOTS, on the old kernel $NUM_OLD, with a half-written slot beside it" \
    || bad "a machine killed mid-write came up at '$K'"
grep -q "hkslot: active slot   hamnix-a.efi" "$WORK/b6.txt" \
    && ok "and it still reports slot A active -- nothing is half-applied" \
    || bad "the killed machine's slot state is not slot A"

# --- 7. THE NEGATIVE CONTROL, AS AN ARM OF THIS SAME RUN -------------------
say "7. BOOT 7 -- THE NEGATIVE CONTROL: the SAME machine, an artifact with ONE BYTE FLIPPED"
say "   (the index still records the ORIGINAL digest, and is still validly signed)"
cp "$WORK/red.img" "$WORK/redrun.img"
boot_phase "$WORK/redrun.img" "$WORK/p_update.rc" b7 "" "" 480
grep -q "hkslot: THE NEW KERNEL DOES NOT MATCH ITS DIGEST" "$WORK/b7.txt" \
    && ok "the machine caught it: the artifact does not match the signed digest" \
    || bad "the machine did NOT catch a corrupt kernel -- $(grep -m3 'hkslot:' "$WORK/b7.txt" | tr '\n' ' ')"
grep -q "hkslot: WROTE " "$WORK/b7.txt" \
    && bad "it wrote the slot anyway" \
    || ok "and it wrote NOTHING -- the refusal is before the first byte"
# TWO CONDITIONS, NOT ONE. "does not say RC=0" would also be true of a log
# with no RC line at all -- i.e. of a shell that never reported an exit status
# -- and this arm would then pass for a reason that has nothing to do with the
# refusal. The line must be PRESENT and it must not be zero.
if grep -q "HK-UPDATE-RC=" "$WORK/b7.txt"; then
    grep -q "HK-UPDATE-RC=0" "$WORK/b7.txt" \
        && bad "\`hpm update\` exited 0 on a kernel it refused to write" \
        || ok "\`hpm update\` exited NON-ZERO: $(grep -m1 'HK-UPDATE-RC' "$WORK/b7.txt")"
else
    bad "the guest never reported \`hpm update\`'s exit status at all"
fi
grep -q "hkslot: active slot   hamnix-a.efi" "$WORK/b7.txt" \
    && ok "the machine still reports slot A active" \
    || bad "the slot changed on a refused update"
esp_get "$WORK/redrun.img" /loader/loader.conf "$WORK/lc_red.bin"
grep -q 'default hamnix-a.efi' "$WORK/lc_red.bin" \
    && ok "loader.conf on the medium still names hamnix-a.efi" \
    || bad "loader.conf was flipped on a refused update"

say "7b. BOOT 8 -- and the machine that refused the update still boots the kernel it had"
boot_phase "$WORK/redrun.img" "$WORK/p_observe.rc" b8
K=$(booted_kernel b8)
[ "$K" = OLD ] \
    && ok "it booted kernel $NUM_OLD, exactly as it did before the refused update" \
    || bad "the machine that refused the update came up at '$K'"
grep -q "$SLOTMARK" "$WORK/b8.txt" \
    && bad "boot 8's command line carries the update's marker -- the corrupt kernel RAN" \
    || ok "boot 8's command line does NOT carry the update's marker"

printf '\n  %d PASSED / %d FAILED\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
