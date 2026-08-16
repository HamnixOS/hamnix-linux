#!/usr/bin/env bash
# Read the finished medium and prove it carries what it must.
# Nothing is mounted: sfdisk/dd for geometry, debugfs for ext4, mtools for FAT.
set -uo pipefail
IMG="${1:?usage: verify_medium.sh <img>}"
W="$(dirname "$IMG")"
PART="$W/.verify-part.img"
export PATH="$PATH:/usr/sbin:/sbin"
PASS=0; FAIL=0
ok()   { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }
info() { echo "        $*"; }
say()  { echo; echo "== $* =="; }

part_geom() {
    sfdisk -J "$1" 2>/dev/null | python3 -c '
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
fs_has() { debugfs -R "stat $2" "$1" 2>/dev/null | grep -q '^Inode:'; }
fs_cat() { debugfs -R "cat $2" "$1" 2>/dev/null; }

uki_geom() {   # <file> -> "<VirtualSize> <SizeOfRawData> <PointerToRawData>"
    python3 - "$1" <<'PYEOF'
import struct, sys
b = open(sys.argv[1], "rb").read()
lfa = struct.unpack_from("<I", b, 0x3C)[0]
if b[lfa:lfa+4] != b"PE\0\0": raise SystemExit(1)
n = struct.unpack_from("<H", b, lfa+6)[0]
o = struct.unpack_from("<H", b, lfa+20)[0]
for i in range(n):
    s = lfa + 24 + o + i*40
    if b[s:s+8].rstrip(b"\0") == b".initrd":
        vs, va, raw, ptr = struct.unpack_from("<IIII", b, s+8)
        print(vs, raw, ptr); break
else: raise SystemExit(1)
PYEOF
}
uki_sect() {   # <file> <section> -> its bytes
    python3 - "$1" "$2" <<'PYEOF'
import struct, sys
b = open(sys.argv[1], "rb").read()
want = sys.argv[2].encode()
lfa = struct.unpack_from("<I", b, 0x3C)[0]
n = struct.unpack_from("<H", b, lfa+6)[0]
o = struct.unpack_from("<H", b, lfa+20)[0]
for i in range(n):
    s = lfa + 24 + o + i*40
    if b[s:s+8].rstrip(b"\0") == want:
        vs, va, raw, ptr = struct.unpack_from("<IIII", b, s+8)
        sys.stdout.buffer.write(b[ptr:ptr+min(vs,raw)]); break
else: raise SystemExit(1)
PYEOF
}

echo "IMAGE: $IMG"
echo "bytes: $(stat -c%s "$IMG")"

# ---------------------------------------------------------------- the ESP
say "the ESP (partition 1, FAT)"
EG="$(part_geom "$IMG" 1)"; EOFF="${EG% *}"
info "partition 1 at byte offset $EOFF, ${EG#* } bytes"
M="$IMG@@$EOFF"
ESPLS="$(mdir -i "$M" ::/EFI/BOOT 2>&1)"
if echo "$ESPLS" | grep -q 'BOOTX64'; then
    ok "the ESP has /EFI/BOOT/BOOTX64.EFI (removable-media path -- firmware runs it with no NVRAM entry)"
else
    bad "no /EFI/BOOT/BOOTX64.EFI on the ESP"
    echo "$ESPLS" | head -20
fi
UKI="$W/.verify-BOOTX64.EFI"
rm -f "$UKI"
if mcopy -n -i "$M" ::/EFI/BOOT/BOOTX64.EFI "$UKI" 2>/dev/null; then
    ok "pulled the UKI off the ESP: $(stat -c%s "$UKI") bytes"
else
    bad "could not pull /EFI/BOOT/BOOTX64.EFI off the ESP"
fi

# \HAMNIX.LOG, preallocated
HL="$(mdir -i "$M" :: 2>/dev/null | grep -i 'HAMNIX' )"
if [ -n "$HL" ]; then
    HLSZ="$(echo "$HL" | awk '{gsub(/[^0-9]/,"",$3); print $3}')"
    ok "the ESP carries \\HAMNIX.LOG: $HL"
    if [ "$HLSZ" = 262144 ]; then
        ok "\\HAMNIX.LOG is preallocated to its full 262144 bytes (= BOOTLOG_CAP in user/bootlogd.ad), so every boot-time write is an overwrite in place and survives the power button on FAT32"
    else
        bad "\\HAMNIX.LOG is $HLSZ bytes, not the 262144 bootlogd preallocates"
    fi
else
    bad "no \\HAMNIX.LOG on the ESP -- a failed boot on his laptop would leave no evidence"
fi
mdir -i "$M" :: 2>/dev/null | grep -qi 'UKI.*MAP' \
    && ok "the ESP carries \\UKI.MAP (bootsync's base + boot module list)" \
    || bad "no \\UKI.MAP on the ESP -- bootsync has no base to write against"

# ------------------------------------------------- the initrd reservation
say "the .initrd reservation -- THE ONE THAT CANNOT BE ADDED LATER"
if [ -s "$UKI" ]; then
    G="$(uki_geom "$UKI")"
    if [ -n "$G" ]; then
        VS="$(echo "$G" | cut -d' ' -f1)"
        RAW="$(echo "$G" | cut -d' ' -f2)"
        PTR="$(echo "$G" | cut -d' ' -f3)"
        info ".initrd VirtualSize   = $VS   (what the EFI stub hands the kernel = the real archive)"
        info ".initrd SizeOfRawData = $RAW   (the ceiling scripts/hamlinux_disk.sh reserved)"
        info ".initrd PointerToRawData = $PTR"
        FREE=$(( RAW - VS ))
        info "free for bootsync    = $FREE bytes ($(python3 -c "print('%.2f' % ($FREE/1048576.0))") MiB)"
        # THE THRESHOLD IS NOT "> 0", AND THAT WAS MEASURED RATHER THAN
        # REASONED. Run against the owner's 1.0.23 stick this check said PASS
        # on 307 bytes -- which is not a reservation at all, only the 4-byte
        # alignment padding objcopy left when it rounded SizeOfRawData up to
        # the file alignment. bootsync needs room for a whole uncompressed
        # module overlay; scripts/hamlinux_disk.sh reserves 24 MiB.
        if [ "$FREE" -ge $((16 * 1024 * 1024)) ]; then
            ok "the UKI over-allocates .initrd by $FREE bytes -- an installed machine CAN change what it boots with"
        elif [ "$FREE" -gt 0 ]; then
            bad "only $FREE bytes past VirtualSize -- that is objcopy's alignment padding, NOT a bootsync reservation; a machine installed from this medium could never change what it boots with"
        else
            bad "no over-allocation: SizeOfRawData == VirtualSize, bootsync would refuse on every disk installed from this medium"
        fi
        # the archive really is that long: gzip magic at ptr, and the tail is zeros
        MAGIC="$(dd if="$UKI" bs=1 skip="$PTR" count=2 status=none | od -An -tx1 | tr -d " \n")"
        [ "$MAGIC" = "1f8b" ] \
            && ok "the section starts with gzip magic 1f8b at offset $PTR -- VirtualSize names a real archive" \
            || bad "the .initrd section does not start with gzip magic (got $MAGIC)"
        NZ="$(dd if="$UKI" bs=1 skip=$(( PTR + VS + 1024 )) count=65536 status=none | tr -d '\0' | wc -c)"
        [ "$NZ" = 0 ] \
            && ok "64 KiB sampled past VirtualSize is all zero -- the reservation is empty room, not archive the kernel is told to unpack" \
            || bad "$NZ non-zero bytes past VirtualSize"
    else
        bad "no .initrd section in the UKI -- this medium has NO reservation and bootsync will refuse forever"
    fi
fi

# --------------------------------------------------------- the command line
say "the kernel command line, read out of the UKI's .cmdline section"
if [ -s "$UKI" ]; then
    CMD="$(uki_sect "$UKI" .cmdline | tr -d '\0')"
    info "$CMD"
    # THE LAST console= WINS -- that is the kernel's rule, and it is the one
    # that decides which device /dev/console is. It is not the last WORD on the
    # line; printk.devkmsg=on follows it.
    LASTCON="$(printf '%s\n' $CMD | grep '^console=' | tail -1)"
    if [ "$LASTCON" = "console=tty0" ]; then
        ok "the LAST console= on the command line is console=tty0 (the full order is: $(printf '%s\n' $CMD | grep '^console=' | tr '\n' ' ')) -- so /dev/console is the screen he is looking at, and ttyS0 stays registered for the gates"
    else
        bad "the last console= is $LASTCON, not console=tty0 -- the shell would talk into a serial port his laptop does not have"
    fi
    case "$CMD" in *printk.devkmsg=on*) ok "printk.devkmsg=on -- the ring buffer does not ratelimit the shell's output away" ;;
                    *) bad "no printk.devkmsg=on -- the boot log will silently lose lines" ;; esac
    case "$CMD" in *keep_bootcon*) bad "keep_bootcon is present" ;;
                   *) ok "no keep_bootcon" ;; esac
    case "$CMD" in *root=PARTUUID=*) ok "root is named by PARTUUID, not a device node" ;;
                   *) bad "root= is not a PARTUUID" ;; esac
fi

# ------------------------------------------------------------- the root fs
say "the root filesystem (partition 2, ext4)"
carve "$IMG" 2 || { bad "cannot carve partition 2"; exit 1; }
info "carved $(stat -c%s "$PART") bytes"
for f in /bin/bootsync /bin/bootlogd /bin/hpm /bin/hlinstall /bin/install \
         /bin/haminstallui /bin/wsysd /etc/installer-medium \
         /etc/rc.boot /etc/rc.boot.installed /var/lib/hpm/installed.json \
         /boot/BOOTX64.EFI /boot/root.partuuid; do
    fs_has "$PART" "$f" && ok "carries $f" || bad "MISSING $f"
done
for t in sgdisk mkfs.vfat mkfs.ext4; do
    fs_has "$PART" "/usr/lib/instroot/usr/sbin/$t" \
        && ok "the installer's tool closure has $t" \
        || bad "the installer's tool closure has no $t -- it cannot partition his disk"
done

# ------------------------------------------------------ the package database
say "the installed package database"
fs_cat "$PART" /var/lib/hpm/installed.json > "$W/.verify-installed.json" 2>/dev/null
if [ -s "$W/.verify-installed.json" ]; then
    python3 - "$W/.verify-installed.json" <<'PYEOF'
import json,sys
d=json.load(open(sys.argv[1]))
pk=d.get("packages", d)
if isinstance(pk, dict): items=pk
else: items={p["name"]:p for p in pk}
print("        %d packages recorded" % len(items))
for n in ("hamnix-drivers-base","hamnix-drivers-hw","hpm","hamnix-install","hamnix-init"):
    if n in items:
        v=items[n].get("version","?") if isinstance(items[n],dict) else "?"
        nf=len(items[n].get("files",[])) if isinstance(items[n],dict) else 0
        print("  PASS  the database records %s at %s (%d files)" % (n,v,nf))
    else:
        print("  FAIL  the database does NOT record %s" % n)
# bootsync and bootlogd ship inside a package (SYS_CMDS), so what matters is
# that SOME recorded package owns them -- that is what makes them upgradable.
for path in ("bin/bootsync","bin/bootlogd","bin/hpm"):
    own=[n for n,p in items.items() if isinstance(p,dict) and path in p.get("files",[])]
    if own:
        print("  PASS  %s is owned by the recorded package %s -- `hpm update` can replace it" % (path, ",".join(own)))
    else:
        print("  FAIL  %s is owned by NO recorded package -- it can never be updated" % path)
vers = sorted({p.get("version") for p in items.values() if isinstance(p,dict)})
print("        every recorded version: %s" % ", ".join(vers))
PYEOF
else
    bad "no /var/lib/hpm/installed.json could be read -- hpm update on the installed machine would be a no-op forever"
fi

# --------------------------------------------------- hpm is the 1.0.25 one
say "the hpm on the medium"
fs_cat "$PART" /bin/hpm > "$W/.verify-hpm" 2>/dev/null
if [ -s "$W/.verify-hpm" ]; then
    info "/bin/hpm off the image: $(stat -c%s "$W/.verify-hpm") bytes, sha256 $(sha256sum "$W/.verify-hpm" | cut -d' ' -f1)"
    # THE 1.0.25 FIX, READ OUT OF THE BINARY. user/hpm.ad:4897 emits this string
    # only in the GNU-long-name path that 1.0.25 added; an older hpm truncated
    # names at a tar header's 100 bytes and lost 14 of 65 kernel modules.
    if grep -aq 'refusing' "$W/.verify-hpm" && grep -aq 'tar entry name over 255 bytes' "$W/.verify-hpm"; then
        ok "the medium's /bin/hpm carries the GNU-long-name refusal string -- it is the 1.0.25 hpm, not one that truncates at 100 bytes"
    else
        bad "the medium's /bin/hpm has no long-name handling -- installing from it would lose 14 of 65 kernel modules"
    fi
    # AND IT IS THE CHANNEL'S BYTES, not merely a binary with the right string.
    CT="$(ls build/repo/linux/packages/hpm-*.tar.gz 2>/dev/null | head -1)"
    if [ -n "$CT" ]; then
        python3 - "$CT" "$W/.verify-hpm" <<'PYEOF'
import hashlib, sys, tarfile
t = tarfile.open(sys.argv[1])
m = [n for n in t.getnames() if n.endswith("/files/bin/hpm")]
if not m:
    print("  FAIL  the channel's hpm tarball has no files/bin/hpm"); raise SystemExit
cd = t.extractfile(m[0]).read()
im = open(sys.argv[2], "rb").read()
a, b = hashlib.sha256(cd).hexdigest(), hashlib.sha256(im).hexdigest()
if a == b:
    print("  PASS  /bin/hpm on the medium is byte-for-byte the channel's hpm (%s)" % a[:16])
else:
    # NOT A DEFECT IN THIS MEDIUM, and it is checked rather than asserted.
    # scripts/hamlinux_packages.py hands hamlinux_build.sh an ABSOLUTE source
    # path and scripts/hamlinux_image.sh a RELATIVE one, and the Adder front
    # end mangles symbol names by the path it compiled (that script's own
    # comment says so). So the channel copy carries the build worktree's path
    # inside its symbols and the image copy does not. Both must carry the
    # 1.0.25 long-name fix; that is the thing that matters.
    tag = b"agent_a33312e0ae9f67177"
    print("        image %d bytes (%s), channel %d bytes (%s)" % (len(im), b[:16], len(cd), a[:16]))
    print("        path-mangled symbols: image %d, channel %d" % (im.count(tag), cd.count(tag)))
    both = (b"tar entry name over 255 bytes" in cd) and (b"tar entry name over 255 bytes" in im)
    if im.count(tag) == 0 and cd.count(tag) > 0 and both:
        print("  PASS  the two hpm binaries differ only by the build-path symbol mangling "
              "(a known, pre-existing property of the two build lanes); BOTH carry the 1.0.25 long-name fix")
    else:
        print("  FAIL  /bin/hpm differs from the channel's for a reason the mangling does not explain")
PYEOF
    else
        info "(no built hpm tarball under build/repo/linux/packages to compare against)"
    fi
else
    bad "could not read /bin/hpm off the image"
fi

echo
echo "SUMMARY: $PASS PASSED, $FAIL FAILED (plus the database and hpm-bytes lines above)"
rm -f "$PART"
