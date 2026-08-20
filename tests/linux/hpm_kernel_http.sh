#!/usr/bin/env bash
#
# REGISTRATION: this gate is ON-DEMAND, and it is in scripts/release_gates.sh.
# Not in ci_battery_manifest.txt because it builds a 4 GiB medium and boots
# several machines under qemu, which is far outside the battery's 50-minute
# 12-way-sharded cap.
#
# THAT SENTENCE IS WANTED VERBATIM by scripts/test_gate_registration.sh, and
# the note below has always said the same thing in different words -- so this
# gate has read as "a gate nothing runs" to the checker for its whole life,
# alongside tests/linux/hkslot_http_fetch.sh and tests/linux/_hkslot_sandbox.sh.
#
# It builds a 4 GiB medium and boots
# several machines under `qemu-system-x86_64`, the same reason
# tests/linux/hpm_kernel_update.sh and tests/linux/ab_kernel_slots.sh are not
# in ci_battery_manifest.txt.
#
# tests/linux/hpm_kernel_http.sh -- DOES A MACHINE FETCH ITS KERNEL OVER
# http(s) FROM A REAL SERVER, VERIFY IT IN RAM, AND BOOT IT?
#
# WHAT THIS ASKS THAT tests/linux/hpm_kernel_update.sh DOES NOT
# ============================================================
# That gate proved `hpm update` replaces the kernel on a running machine, but
# every byte came from `file:///hamrepo/` on the machine's OWN ROOT. There was
# no transport: the artifact was already on the disk. hpm refused an http(s)
# channel outright, so https://255.one/ -- the repo this project actually
# ships from -- COULD NOT SHIP A KERNEL AT ALL.
#
# This gate asks the question that blocker was hiding:
#
#     THE MACHINE BOOTS. IT TAKES A DHCP LEASE. IT FETCHES A SIGNED INDEX AND
#     A ~74 MB KERNEL OVER http FROM A SERVER ON THE OTHER SIDE OF A VIRTUAL
#     NIC. DOES IT VERIFY THEM, WRITE ITS INACTIVE SLOT, AND BOOT THE RESULT?
#
# THE DESIGN BEING MEASURED, AS THE OWNER CHOSE IT
# ================================================
# The artifact is buffered WHOLE IN RAM and verified there before one byte
# reaches the ESP. The buffer is sys_mmap'd when an update is actually pending
# and released afterwards -- not a static array -- and its cap is THE INACTIVE
# SLOT'S OWN LENGTH, read off the medium each run. See user/hkslot.ad.
#
# THE TRAP, STATED FIRST BECAUSE IT HAS ALREADY CAUGHT THIS TASK
# ==============================================================
# A MACHINE THAT BOOTS LOOKS IDENTICAL WHETHER IT TOOK THE UPDATE OR SILENTLY
# FELL BACK. So the two images are built from DIFFERENT HOST KERNELS and what
# is read back is the RUNNING KERNEL'S OWN BANNER on the serial console --
# `Linux version 6.12.x` -- printed before any userland exists, plus a marker
# baked into the new image's command line as a PE section. Section 0 proves
# both distinguishers and STOPS THE GATE if the two images are the same bytes.
#
# THE NEGATIVE CONTROLS ARE ARMS OF THIS SAME RUN, AND http MAKES THEM CHEAP
# =========================================================================
# tests/linux/hpm_kernel_update.sh needed a SECOND 4 GiB medium to corrupt an
# artifact. Over http the artifact does not live on the medium at all, so a
# negative control is just a server that misbehaves -- same medium, same
# signed index, same machine. There are two, and each is the exact inversion
# of the green arm:
#
#   CUT   the server declares the artifact's full Content-Length, sends 45% of
#         it, and CLOSES. THIS IS THE ONE THE RAM BUFFER EXISTS FOR. It must
#         produce a named refusal, an untouched slot, and a next boot on the
#         OLD kernel. A short read that reported success here would be this
#         project's signature failure mode landing on the kernel itself.
#   FLIP  the server serves the whole artifact with ONE BYTE flipped while the
#         index still records the ORIGINAL digest and is still validly signed.
#         The signature check must PASS and the content check must FAIL.
#
# Usage: tests/linux/hpm_kernel_http.sh
# Env:   HAMLINUX_HKH_WORK       where to build and boot
#        HAMLINUX_HKH_REUSE=1    reuse the medium already built there
#        HAMLINUX_HKH_KEEPIMAGE=1  reuse build/image and the saved per-kernel
#                                initramfs instead of building the image twice
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"
# FIRST, before reap.sh and before $WORK -- the contract in
# tests/linux/private_ns.sh. gates_are_private.sh checks that this line is here.
. tests/linux/private_ns.sh
priv_ns_reexec "$@"
. tests/linux/reap.sh

WORK="${HAMLINUX_HKH_WORK:-$HOME/.hamnix-build/hpmkernelhttp/gate}"
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

# --- THE SERVER THE MACHINE FETCHES FROM -----------------------------------
# It runs on this host, inside the gate's private namespace, and the guest
# reaches it at 10.0.2.2 through QEMU's user-mode stack -- the same way
# tests/linux/installed_update.sh reaches its package repo. The port is picked
# by the kernel so two gates can run at once.
PORT="$(python3 tests/linux/_hkhttp_freeport.py)"
BASEURL="http://10.0.2.2:$PORT/"
REPO="$WORK/repo"                 # served over http FROM THIS HOST
MODEFILE="$WORK/servermode"
KVER_NEW=1.0.33
mkdir -p "$REPO"
echo good > "$MODEFILE"

start_server() {
    if [ -n "${SRVPID:-}" ]; then kill "$SRVPID" 2>/dev/null; fi
    python3 tests/linux/_hkhttp_repo_server.py "$REPO" "$PORT" "$MODEFILE" ".efi" \
        >"$WORK/server.log" 2>&1 &
    SRVPID=$!
    reap_add "$SRVPID"
    sleep 1
    if ! kill -0 "$SRVPID" 2>/dev/null; then
        bad "the repository server would not start -- see $WORK/server.log"; exit 1
    fi
}
set_mode() { echo "$1" > "$MODEFILE"; info "server mode := $1"; }

build_repo() {   # build_repo <artifact> <recorded-sha>
    local art="$1" sha="$2"
    rm -rf "$REPO"
    mkdir -p "$REPO/linux/kernel"
    cp "$art" "$REPO/linux/kernel/hamnix-$KVER_NEW.efi"
    python3 - "$REPO/linux/index.json" "$sha" \
             "$(stat -Lc%s "$art")" "$KVER_NEW" "$BASEURL" <<'PY'
import json, sys
out, sha, size, ver, base = (sys.argv[1], sys.argv[2], int(sys.argv[3]),
                         sys.argv[4], sys.argv[5])
json.dump({"schema": 1, "repo": "HamnixOS/packages", "channel": "linux",
       "url": base + "linux/", "updated": "2026-08-19",
       "packages": [],
       "kernel": {"version": ver,
                  "url": "kernel/hamnix-%s.efi" % ver,
                  "sha256": sha, "size": size}},
      open(out, "w"), indent=2)
open(out, "a").write("\n")
PY
    python3 scripts/hpm_sign.py sign "$REPO/linux/index.json" \
        "$SEED" "$REPO/linux/index.json.sig" >/dev/null
}

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
PU="${HAMLINUX_HKH_PARTUUID:-21111111-2222-3333-4444-555555555555}"
# ZERO by default. The kill is timed off a marker printed 2 MiB into a 74 MB
# copy, so any positive delay is a gamble against how fast this host writes --
# and on this host the whole copy takes under two seconds.
KILL_S="${HAMLINUX_HKH_KILL_S:-0}"
LOADER_CONF_BYTES=512

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
        -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
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
if [ "${HAMLINUX_HKH_REUSE:-0}" = 1 ] && [ -f "$WORK/good.img" ] \
   && [ -f "$WORK/uki_new.efi" ] && [ -f "$WORK/uki_old.efi" ]; then
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
    if [ "${HAMLINUX_HKH_KEEPIMAGE:-0}" = 1 ] && [ -d build/image/root ] \
       && [ -f "$WORK/initrd_new.cpio.gz" ] && [ -d "$WORK/mods_new" ]; then
        info "HAMLINUX_HKH_KEEPIMAGE=1: reusing the build/image already present"
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
    # runs the phase script -- plus, here, `dhcpc`, because unlike that gate
    # this machine's repository is on the far side of a NIC. No distro
    # namespace, no runlevel 5, no greeter. Each phase ends in `init 0`, so
    # the shipped rc is never reached and there is nothing to block.
    # THE ONE DIFFERENCE FROM tests/linux/hpm_kernel_update.sh's rc: this
    # machine needs a NETWORK, because its repository is on the other side of
    # a virtual NIC. `dhcpc` takes the lease QEMU's user-mode stack offers
    # (10.0.2.15, gateway 10.0.2.2) exactly as tests/linux/installed_update.sh
    # does. Everything else is unchanged, INCLUDING the deliberate refusal to
    # `source '/etc/rc.boot.installed'` -- that file now ends in runlevel 5 and
    # BLOCKS in /bin/hamgreet, so anything after it never runs.
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
dhcpc
echo 'HK-DHCP-RC='$status
echo 'HK-IFCONFIG'
ifconfig
source '/boot/PHASE.RC'
echo 'HK-END'
RCEOF

    # THE REPOSITORY LIVES ON THIS HOST AND IS SERVED OVER http. The machine
    # holds no copy of the artifact at all -- which is the entire point of
    # this gate and the reason its negative controls need no second medium.
    # The index is signed with the COMMITTED local seed
    # (scripts/hpm_local_key.seed) against the trust root the image already
    # ships (etc/hpm/local-trusted.pub), so hpm's signature check is the real
    # one: --allow-unsigned is never passed anywhere in this gate.

    # THE PACKAGE DATABASE, on the machine's root. Without one `hpm update`
    # REFUSES outright ("no package database ... REFUSING") and never reaches
    # the kernel at all -- a real behaviour of this tree, named here rather
    # than discovered as a mystery exit 1.
    mkdir -p build/image/root/var/lib/hpm
    printf '{"schema":1,"packages":[]}\n' > build/image/root/var/lib/hpm/installed.json


    # --- THE ONE MEDIUM -----------------------------------------------------
    # There is only one, and that is the point. In
    # tests/linux/hpm_kernel_update.sh the artifact lived on the machine's own
    # root, so corrupting it meant building a SECOND 4 GiB medium. Here the
    # artifact lives on the server, so every negative control is the same
    # medium against a server told to misbehave.
    cp -L "$KERN_OLD" build/image/vmlinuz
    cp "$WORK/initrd_old.cpio.gz" build/image/initramfs.cpio.gz
    HAMLINUX_DISTRO_RO=1 HAMLINUX_AB_SLOTS=1 HAMLINUX_ROOT_PARTUUID="$PU" \
        HAMLINUX_DISK_RC="$WORK/rc.proof" \
        scripts/hamlinux_disk.sh "$WORK/good.img" 4G >"$WORK/disk_good.log" 2>&1 \
        || { bad "the medium would not build -- see $WORK/disk_good.log"; exit 1; }
    cp build/image/disk/BOOTX64.EFI "$WORK/uki_old.efi"
    ok "medium built; $(grep -o 'A/B: .*' "$WORK/disk_good.log" | head -1)"

    cp "$WORK/vmlinuz.image" build/image/vmlinuz
    rm -f "$WORK/scratch_new.img"
fi

# THE SERVER'S CONTENT AND THE SERVER ITSELF, built every run even when the
# medium is reused -- the port is new each time and the artifact's digest is
# what the whole gate turns on.
SHA_NEW=$(sha256sum "$WORK/uki_new.efi" | cut -d' ' -f1)
NEWSZ_REAL=$(stat -Lc%s "$WORK/uki_new.efi")
info "the update's kernel image is $NEWSZ_REAL bytes, sha256 $SHA_NEW"
build_repo "$WORK/uki_new.efi" "$SHA_NEW"
start_server
ok "the repository is being served over http at $BASEURL"

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
#
# `--trusted-key=/etc/hpm/local-trusted.pub` IS LOAD-BEARING, AND THE FIRST RUN
# OF THIS GATE IS WHY. It scored 52 / 23 with a single root cause: every arm
# died at "hpm: index signature INVALID".
#
# THAT WAS hpm BEING RIGHT, NOT hpm BEING BROKEN, and the distinction is the
# whole reason this line has a paragraph. _verify_index_signature routes on the
# SCHEME: a file:// repo is checked against the LOCAL trust root
# (etc/hpm/local-trusted.pub, whose secret scripts/hpm_local_key.seed IS
# committed, because those bytes never cross a network), while an http(s) repo
# is checked against the PRODUCTION root (etc/hpm/trusted.pub, whose secret is
# held out of band and is NOT in this tree). tests/linux/hpm_kernel_update.sh
# never met this because it is file:// throughout.
#
# So a locally-signed repo served over http MUST be rejected by default -- that
# is the property protecting 255.one -- and a gate cannot get around it by
# signing harder. It has to say out loud which root it is trusting. The flag
# names the file the image already ships, and NOTHING here passes
# --allow-unsigned: the signature is still verified, against a root named on
# the command line.
TKEY=/etc/hpm/local-trusted.pub
printf "echo 'HK-PHASE=observe'\nhkslot --status\nhpm --trusted-key=%s --repo=%s kernel\ninit 0\n" \
    "$TKEY" "$BASEURL" >"$WORK/p_observe.rc"
printf "echo 'HK-PHASE=update'\nhpm --trusted-key=%s --repo=%s update\necho \"HK-UPDATE-RC=\$status\"\nhkslot --status\ninit 0\n" \
    "$TKEY" "$BASEURL" >"$WORK/p_update.rc"

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
# THE NETWORK IS CHECKED BEFORE ANYTHING THAT NEEDS IT, AND THE GATE STOPS ON
# IT. Every assertion below is a grep for something the machine said after
# talking to a server; if it never got an address, all of them fail for a
# reason that has nothing to do with the kernel mechanism.
grep -q "HK-DHCP-RC=0" "$WORK/b1.txt" \
    && ok "the machine took a DHCP lease" \
    || { bad "dhcpc did not succeed -- $(grep -m2 'HK-DHCP-RC' "$WORK/b1.txt" | tr '\n' ' ')"; printf '\n  %d PASSED / %d FAILED\n' "$PASS" "$FAIL"; exit 1; }
grep -q "10\.0\.2\.15" "$WORK/b1.txt" \
    && ok "and it has QEMU's DHCP address 10.0.2.15, so it can reach the host at 10.0.2.2" \
    || { bad "the machine has no 10.0.2.15 address after dhcpc"; printf '\n  %d PASSED / %d FAILED\n' "$PASS" "$FAIL"; exit 1; }
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
# AND IT CAME OVER THE WIRE. The machine names the URL it fetched, and the
# scheme in that URL is the thing under test.
grep -q "fetching channel linux from http://" "$WORK/b1.txt" \
    && ok "and it fetched that index over http: $(grep -m1 'fetching channel linux from' "$WORK/b1.txt")" \
    || bad "the machine did not report fetching its channel over http"
# WHICH TRUST ROOT WAS IN FORCE, said out loud. hpm prints this only when an
# explicit --trusted-key was accepted, so its ABSENCE would mean the machine
# had silently fallen back to the production root -- and the run would then be
# measuring a different trust decision than the one it claims to.
grep -q "hpm: trust root taken from /etc/hpm/local-trusted.pub" "$WORK/b1.txt" \
    && ok "and it announced WHICH trust root it used, rather than falling back silently" \
    || bad "the machine did not announce the local trust root -- $(grep -m2 'trust root' "$WORK/b1.txt" | tr '\n' ' ')"

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
    && bad "the write COMPLETED before the kill -- nothing was interrupted, so this arm proves nothing (LOWER HAMLINUX_HKH_KILL_S)" \
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

# --- 7. NEGATIVE CONTROL ONE: THE CONNECTION DROPS MID-TRANSFER ------------
#
# THIS IS THE ONE THE RAM BUFFER EXISTS FOR, and it is the arm to read first.
# The server declares the artifact's full Content-Length, sends 45% of it, and
# closes. Until this cycle http9 answered that with rc 0 and a short buffer --
# a SHORT READ THAT REPORTS SUCCESS, this project's signature failure mode,
# sitting on the transport a kernel would ride in on.
#
# Note what CANNOT be measured here and is not claimed: the guest's TCP stack
# sees a clean FIN, not a severed cable. What is measured is the case that
# matters to the machine -- the body ended before the server said it would.
say "7. BOOT 7 -- NEGATIVE CONTROL: THE SERVER HANGS UP PART-WAY THROUGH THE KERNEL"
set_mode cut
cp "$WORK/good.img" "$WORK/cutrun.img"
boot_phase "$WORK/cutrun.img" "$WORK/p_update.rc" b7 "" "" 480
grep -q "the connection ended after" "$WORK/b7.txt" \
    && ok "the machine NAMED the dropped transfer: $(grep -m1 'connection ended after' "$WORK/b7.txt" | tr -s ' ')" \
    || bad "the machine did not name a dropped transfer -- $(grep -m3 'hkslot:' "$WORK/b7.txt" | tr '\n' ' ')"
grep -q "PREFIX of the kernel" "$WORK/b7.txt" \
    && ok "and it said what arrived is a PREFIX of the kernel, not the kernel" \
    || bad "the machine did not say the body was a prefix"
grep -q "hkslot: downloaded " "$WORK/b7.txt" \
    && bad "the machine reported a COMPLETED download of a transfer that was cut short" \
    || ok "and it never claimed the download completed"
grep -q "hkslot: WROTE " "$WORK/b7.txt" \
    && bad "it wrote the slot anyway" \
    || ok "it wrote NOTHING -- the refusal is before the first byte reaches the ESP"
grep -q "CUT " "$WORK/server.log" \
    && ok "the SERVER's own log confirms it cut the transfer: $(grep -m1 'CUT ' "$WORK/server.log")" \
    || bad "the server never logged a cut transfer -- this arm may not have exercised what it claims"
# TWO CONDITIONS, NOT ONE. "does not say RC=0" would also be true of a log with
# no RC line at all -- a shell that never reported an exit status -- and this
# arm would then pass for a reason unrelated to the refusal.
if grep -q "HK-UPDATE-RC=" "$WORK/b7.txt"; then
    grep -q "HK-UPDATE-RC=0" "$WORK/b7.txt" \
        && bad "\`hpm update\` exited 0 on a transfer that was cut short" \
        || ok "\`hpm update\` exited NON-ZERO: $(grep -m1 'HK-UPDATE-RC' "$WORK/b7.txt")"
else
    bad "the guest never reported \`hpm update\`'s exit status at all"
fi
grep -q "hkslot: active slot   hamnix-a.efi" "$WORK/b7.txt" \
    && ok "the machine still reports slot A active" \
    || bad "the slot changed on a refused update"
esp_get "$WORK/cutrun.img" /EFI/Linux/hamnix-b.efi "$WORK/slot_b_cut.bin"
cmp -s "$WORK/slot_b_cut.bin" "$WORK/slot_b0.bin" \
    && ok "AND SLOT B ON THE MEDIUM IS BYTE-IDENTICAL TO THE FRESH MEDIUM'S -- nothing was half-written" \
    || bad "slot B changed on a transfer that was refused"
esp_get "$WORK/cutrun.img" /loader/loader.conf "$WORK/lc_cut.bin"
grep -q 'default hamnix-a.efi' "$WORK/lc_cut.bin" \
    && ok "loader.conf on the medium still names hamnix-a.efi" \
    || bad "loader.conf was flipped on a refused update"

say "7b. BOOT 8 -- and the machine whose download was cut still boots the kernel it had"
boot_phase "$WORK/cutrun.img" "$WORK/p_observe.rc" b8
K=$(booted_kernel b8)
[ "$K" = OLD ] \
    && ok "it booted kernel $NUM_OLD, exactly as it did before the refused update" \
    || bad "the machine that refused the update came up at '$K'"
grep -q "$SLOTMARK" "$WORK/b8.txt" \
    && bad "boot 8's command line carries the update's marker -- a partial kernel RAN" \
    || ok "boot 8's command line does NOT carry the update's marker"

# --- 8. NEGATIVE CONTROL TWO: THE ARTIFACT IS COMPLETE BUT WRONG -----------
#
# The whole body arrives, with ONE BYTE FLIPPED, while the index still records
# the ORIGINAL digest and is still validly signed. So the SIGNATURE check must
# PASS and the CONTENT check must FAIL: this is the check that stands between
# the machine and a kernel somebody else wrote. It is distinct from arm 7 --
# there the transport failed; here the transport succeeded perfectly.
say "8. BOOT 9 -- NEGATIVE CONTROL: A COMPLETE DOWNLOAD WITH ONE BYTE FLIPPED"
set_mode flip
cp "$WORK/good.img" "$WORK/fliprun.img"
boot_phase "$WORK/fliprun.img" "$WORK/p_update.rc" b9 "" "" 480
grep -q "hkslot: downloaded " "$WORK/b9.txt" \
    && ok "the download itself COMPLETED -- this is a content failure, not a transport one" \
    || bad "the download did not complete, so this arm is not measuring what it claims"
grep -q "hkslot: THE NEW KERNEL DOES NOT MATCH ITS DIGEST" "$WORK/b9.txt" \
    && ok "the machine caught it: the artifact does not match the signed digest" \
    || bad "the machine did NOT catch a corrupt kernel -- $(grep -m3 'hkslot:' "$WORK/b9.txt" | tr '\n' ' ')"
grep -q "hkslot: WROTE " "$WORK/b9.txt" \
    && bad "it wrote the slot anyway" \
    || ok "and it wrote NOTHING -- the refusal is before the first byte"
if grep -q "HK-UPDATE-RC=" "$WORK/b9.txt"; then
    grep -q "HK-UPDATE-RC=0" "$WORK/b9.txt" \
        && bad "\`hpm update\` exited 0 on a kernel it refused to write" \
        || ok "\`hpm update\` exited NON-ZERO: $(grep -m1 'HK-UPDATE-RC' "$WORK/b9.txt")"
else
    bad "the guest never reported \`hpm update\`'s exit status at all"
fi
esp_get "$WORK/fliprun.img" /EFI/Linux/hamnix-b.efi "$WORK/slot_b_flip.bin"
cmp -s "$WORK/slot_b_flip.bin" "$WORK/slot_b0.bin" \
    && ok "slot B on the medium is byte-identical to the fresh medium's" \
    || bad "slot B changed on a refused update"
esp_get "$WORK/fliprun.img" /loader/loader.conf "$WORK/lc_flip.bin"
grep -q 'default hamnix-a.efi' "$WORK/lc_flip.bin" \
    && ok "loader.conf on the medium still names hamnix-a.efi" \
    || bad "loader.conf was flipped on a refused update"

say "8b. BOOT 10 -- and that machine still boots the kernel it had"
boot_phase "$WORK/fliprun.img" "$WORK/p_observe.rc" b10
K=$(booted_kernel b10)
[ "$K" = OLD ] \
    && ok "it booted kernel $NUM_OLD" \
    || bad "the machine that refused the corrupt kernel came up at '$K'"
grep -q "$SLOTMARK" "$WORK/b10.txt" \
    && bad "boot 10's command line carries the update's marker -- the corrupt kernel RAN" \
    || ok "boot 10's command line does NOT carry the update's marker"

set_mode good

printf '\n  %d PASSED / %d FAILED\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
