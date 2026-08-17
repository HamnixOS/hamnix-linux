#!/usr/bin/env bash
#
# REGISTRATION, 2026-08-17. Until this date scripts/test_gate_registration.sh
# globbed only scripts/test_*.sh, so this directory was invisible to the gate
# against unregistered gates and every file in it read as coverage without
# being coverage. This gate is ON-DEMAND: not in ci_battery_manifest.txt
# because nobody has measured its host runtime yet, and the battery is 12-way
# sharded under a 50-minute cap -- registering an unmeasured gate is how a
# shard goes from green to timed-out. Measure it, then move it into the
# manifest.
#
# Its host runtime and its pass/fail were NOT measured when this line was
# written. If you make it cheap enough for the battery, add the manifest line
# and delete this block.
#
# tests/linux/hpm_longname_paths.sh — THE TAR TRUNCATION, IN THE TWO LOOPS
# THAT STILL HAD IT.
#
# WHAT IT COST THE FIRST TIME
# ===========================
# A tar header has exactly 100 bytes for the entry name. GNU tar's answer is a
# preceding entry with typeflag 'L' named "././@LongLink" whose BODY is the
# real name; the header after it carries that name TRUNCATED to 100 bytes.
# Python's tarfile writes that format, so scripts/hamlinux_packages.py does,
# so every kernel-module package this project ships contains @LongLink
# entries -- `lib/modules/6.12.85+deb13-amd64/kernel/drivers/...` is over 100
# bytes before the package prefix is even added.
#
# hpm read hdr[0..100) and nothing else. MEASURED on an installed machine
# (tests/linux/install_from_usb.sh, upgrading the two kernel-module packages):
# it wrote the body to the TRUNCATED path, recorded the truncated path in
# installed.json, reported "extracted 35 files", and FOURTEEN OF SIXTY-FIVE
# modules were absent -- virtio-gpu, snd-hda-intel, usb-storage, i2c-hid-acpi,
# nvme-auth among them. The upgrade reported success. That forced 1.0.25.
#
# WHAT WAS ACTUALLY FIXED THEN, AND WHAT WAS NOT
# ==============================================
# Only `_stage_extract_files` got the 'L' branch. Two other loops in
# user/hpm.ad walked the same tar with the same
# `_name_copy_nul(&warn_buf[0], &hdr[0], 100)` and no branch at all:
#
#   _stage_tarball        writes /tmp/hpm/staging/<pkg>-<ver>/<tail> -- the
#                         tree hooks read through HPM_PKG_DIR and the tree a
#                         SOURCE package's `recipe` is compiled out of. It
#                         staged every long-named member at a truncated path.
#
#   _check_file_conflicts compares each incoming files/<rel> against every
#                         installed package's recorded paths. With a truncated
#                         name it compares a path the archive does not
#                         contain, so a REAL conflict on any path over 100
#                         bytes was silently NOT REPORTED and the install went
#                         ahead and overwrote another package's file. A gap
#                         answering something success-shaped, which is the
#                         failure mode this project has paid for most.
#
# WHAT THIS GATE MEASURES
# =======================
# It builds hpm from user/hpm.ad, puts it in a throwaway chroot with a
# file:// repository, and installs two fixture packages whose payload lives at
# a path over 100 bytes -- a real module path, and the gate REFUSES TO RUN if
# the arcname it built is not actually over 100 bytes, because a fixture that
# does not trip @LongLink would make every assertion below vacuous.
#
#   (1) INSTRUMENT: the fixture tarball really contains an @LongLink entry.
#   (2) _stage_extract_files: the installed file is at the FULL path, and the
#       truncated path does not exist. (Regression guard on the 1.0.25 fix.)
#   (3) _stage_tarball: the STAGED tree under /tmp/hpm/staging holds the
#       member at the FULL path, and not at the truncated one.
#   (4) _check_file_conflicts: installing a second package that carries THE
#       SAME long path is REFUSED, naming the owner.
#
# NEGATIVE CONTROL, RUN RATHER THAN DESCRIBED
# ===========================================
#   HAMLINUX_LONGNAME_CONTROL=1
# copies user/hpm.ad, MECHANICALLY REMOVES the 'L' branch from _stage_tarball
# and _check_file_conflicts (leaving _stage_extract_files alone, which is the
# state of the tree before this commit), builds THAT, and requires assertions
# 3 and 4 to come out the OTHER WAY: the staged file at the truncated path,
# and the conflicting install ACCEPTED. If the control run cannot produce the
# broken behaviour then this gate cannot tell the two states apart and its
# green means nothing, and the control says so by name. The control run is
# EXPECTED TO PASS -- it asserts the defect is visible.
#
# WHAT THIS GATE DOES NOT ANSWER
# ==============================
#  * Nothing about a name over 255 bytes. Both loops REFUSE those rather than
#    truncate (LONGNAME_CAP); that refusal is not exercised here.
#  * Nothing about the two remaining `_name_copy_nul` sites,
#    `_read_pkginfo_from_tar` and `_has_entry_in_tar`. Both look for
#    "<prefix>PKGINFO" and "<prefix>install.hamsh", which are short by
#    construction and cannot be the truncated member, so they were left alone
#    DELIBERATELY -- but that is an argument, not a measurement, and it is
#    named here as uncovered rather than implied to be safe.
#  * Nothing about a real installed machine. install_from_usb.sh is where the
#    module count is measured.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && cd .. && pwd)"
cd "$PROJ_ROOT"

pass=0; fail=0
ok()   { echo "longname: PASS $*"; pass=$((pass+1)); }
bad()  { echo "longname: FAIL $*"; fail=$((fail+1)); }
info() { echo "longname: INFO $*"; }
say()  { echo "longname: --- $*"; }

CONTROL="${HAMLINUX_LONGNAME_CONTROL:-0}"
W="${HAMLINUX_LONGNAME_WORK:-$HOME/.hamnix-build/hpm-longname}"
R="$W/root"
mkdir -p "$W"

for t in unshare /usr/sbin/chroot timeout; do
    command -v "$t" >/dev/null 2>&1 || [ -x "$t" ] || {
        bad "missing $t -- this gate cannot run, and a check that cannot run is red"; exit 1; }
done
unshare -Ur true 2>/dev/null || {
    bad "unprivileged user namespaces are unavailable -- this gate cannot run"; exit 1; }

if [ "$CONTROL" = 1 ]; then
    say "NEGATIVE CONTROL: HAMLINUX_LONGNAME_CONTROL=1 -- hpm is built with the"
    say "NEGATIVE CONTROL: 'L' branch REMOVED from _stage_tarball and"
    say "NEGATIVE CONTROL: _check_file_conflicts, and the truncation must SHOW."
fi

# ------------------------------------------------------------------ source
SRC="user/hpm.ad"
if [ "$CONTROL" = 1 ]; then
    SRC="$W/hpm-control.ad"
    python3 - user/hpm.ad "$SRC" <<'PYEOF' || exit 1
import re, sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
# The two blocks this commit added are keyed by their opening comment. Each
# runs from that comment through the `else:` fallback, and is replaced by the
# single line that was there before -- which is exactly the pre-commit tree.
pat = re.compile(
    r"[ \t]*# SAME GNU LONG NAME HANDLING AS _stage_extract_files.*?"
    r"\n        else:\n            nlen = _name_copy_nul\(&warn_buf\[0\], &hdr\[0\], 100\)\n",
    re.S)
s2, n = pat.subn(
    "        nlen: uint64 = _name_copy_nul(&warn_buf[0], &hdr[0], 100)\n", s)
if n != 2:
    raise SystemExit("longname: CONTROL could not remove both branches "
                     "(removed %d of 2) -- the control is broken and would "
                     "otherwise test the FIXED build while claiming otherwise" % n)
# And the two `longname_n = 0` resets those functions gained.
s2 = s2.replace(
    "    sys_mkdir(cast[Ptr[char]](&staging_root_buf[0]))\n\n"
    "    # No 'L' entry can be pending across two archives. See longname_buf.\n"
    "    longname_n = 0\n",
    "    sys_mkdir(cast[Ptr[char]](&staging_root_buf[0]))\n")
s2 = s2.replace(
    '    files_pfx_len: uint64 = 6\n\n'
    "    # No 'L' entry can be pending across two archives. See longname_buf.\n"
    "    longname_n = 0\n\n"
    "    while off + 512 <= tar_len:\n"
    "        hdr: Ptr[uint8] = &tar_buf[off]\n"
    "        if _tar_header_is_zero(hdr) != 0:\n"
    "            return 0\n"
    "        if _tar_chksum_ok(hdr) == 0:\n"
    "            return -1\n",
    '    files_pfx_len: uint64 = 6\n\n'
    "    while off + 512 <= tar_len:\n"
    "        hdr: Ptr[uint8] = &tar_buf[off]\n"
    "        if _tar_header_is_zero(hdr) != 0:\n"
    "            return 0\n"
    "        if _tar_chksum_ok(hdr) == 0:\n"
    "            return -1\n")
open(dst, "w").write(s2)
print("longname: CONTROL removed the 'L' branch from both loops")
PYEOF
fi

# ------------------------------------------------------------------- build
if [ -z "${ADDER_HOST_AC:-}" ]; then
    ADDER_HOST_AC="$PROJ_ROOT/build/cutover/host_ac_llvm.elf"
    [ -x "$ADDER_HOST_AC" ] || ADDER_HOST_AC="$PROJ_ROOT/build/cutover/host_ac.elf"
fi
if [ ! -x "$ADDER_HOST_AC" ]; then
    info "no host_ac.elf yet; bootstrapping the Adder compiler"
    # shellcheck source=../../scripts/_adder_cc.sh
    source "$PROJ_ROOT/scripts/_adder_cc.sh"
    adder_cc_bootstrap || { bad "could not bootstrap host_ac.elf"; exit 1; }
    ADDER_HOST_AC="$PROJ_ROOT/build/cutover/host_ac.elf"
fi
export ADDER_HOST_AC

info "building hpm from $SRC"
nice -n 15 bash scripts/hamlinux_build.sh "$SRC" "$W/hpm.elf" \
    > "$W/hpm.build.log" 2>&1 || {
    bad "could not build hpm from $SRC (see $W/hpm.build.log)"
    tail -8 "$W/hpm.build.log"; exit 1; }

# ------------------------------------------------------------- the sandbox
rm -rf "$R"
mkdir -p "$R"/bin "$R"/lib64 "$R"/lib/x86_64-linux-gnu "$R"/tmp "$R"/dev \
         "$R"/etc "$R"/repo/main/packages "$R"/var/lib/hpm
cp "$W/hpm.elf" "$R/bin/hpm"
for so in $(ldd "$W/hpm.elf" | awk '/=> \//{print $3}' | sort -u); do
    cp -n "$so" "$R/lib/x86_64-linux-gnu/" 2>/dev/null
done
cp /lib64/ld-linux-x86-64.so.2 "$R/lib64/" 2>/dev/null
: > "$R/dev/null"

# ------------------------------------------------------- the fixture repo
# One real module path, long enough that the tar entry name for it cannot fit
# in 100 bytes. Written out here so both the fixture builder and the
# assertions below use the SAME string.
KVER="6.12.85+deb13-amd64"
LONGREL="lib/modules/$KVER/kernel/drivers/gpu/drm/virtio/virtio-gpu-longname-fixture.ko"
echo "$LONGREL" > "$W/longrel"

python3 - "$R/repo/main" "$LONGREL" <<'PYEOF' || exit 1
import hashlib, json, os, shutil, sys, tarfile, tempfile
out, longrel = sys.argv[1], sys.argv[2]
pkgdir = os.path.join(out, "packages")
os.makedirs(pkgdir, exist_ok=True)

def write_pkg(name, payload):
    stage = tempfile.mkdtemp(prefix="longname-")
    try:
        top = os.path.join(stage, "%s-1.0.0" % name)
        fp = os.path.join(top, "files", longrel)
        os.makedirs(os.path.dirname(fp))
        open(fp, "w").write(payload)
        # A second, SHORT member, so a package that fails to place the long
        # one can still look like it installed something -- which is the
        # shape the 1.0.25 defect actually had.
        os.makedirs(os.path.join(top, "files", "share"), exist_ok=True)
        open(os.path.join(top, "files", "share", name), "w").write("short\n")
        open(os.path.join(top, "PKGINFO"), "w").write("\n".join([
            "name: %s" % name, "version: 1.0.0", "arch: x86_64",
            "description: hpm long-name gate fixture",
            "target: #hamnix-system",
            "maintainer: hamnix-linux gate"]) + "\n")
        tarpath = os.path.join(pkgdir, "%s-1.0.0.tar.gz" % name)
        arclen = 0
        with tarfile.open(tarpath, "w:gz", format=tarfile.GNU_FORMAT) as tf:
            for dirpath, dirnames, filenames in os.walk(top):
                dirnames.sort()
                for fn in sorted(filenames):
                    full = os.path.join(dirpath, fn)
                    arc = os.path.relpath(full, stage)
                    arclen = max(arclen, len(arc))
                    tf.add(full, arcname=arc)
        data = open(tarpath, "rb").read()
        return arclen, {"name": name, "version": "1.0.0", "arch": "x86_64",
                        "url": "packages/%s-1.0.0.tar.gz" % name,
                        "sha256": hashlib.sha256(data).hexdigest(),
                        "size": len(data),
                        "description": "hpm long-name gate fixture",
                        "depends": [], "target": "#hamnix-system"}
    finally:
        shutil.rmtree(stage, ignore_errors=True)

a_len, a = write_pkg("longname-a", "payload-A\n")
b_len, b = write_pkg("longname-b", "payload-B\n")
# THE FIXTURE VERIFIES ITSELF. If the arcname fits in 100 bytes there is no
# @LongLink entry and every assertion in this gate is vacuous.
if a_len <= 100:
    raise SystemExit("longname: the fixture arcname is only %d bytes -- it "
                     "would not trip @LongLink and this gate would be "
                     "measuring nothing" % a_len)
print("longname: fixture arcname is %d bytes (over tar's 100-byte name field)"
      % a_len)
json.dump({"schema": 1, "repo": "longname", "channel": "main",
           "url": "file:///repo/", "updated": "2026-08-17",
           "description": "hpm long-name gate fixture",
           "packages": [a, b]},
          open(os.path.join(out, "index.json"), "w"), indent=2)
PYEOF

# (1) INSTRUMENT: the archive really carries an @LongLink entry.
say "1. the instrument"
if tar tzvf "$R/repo/main/packages/longname-a-1.0.0.tar.gz" 2>/dev/null \
        | grep -q 'LongLink' \
   || python3 -c '
import gzip,sys
d=gzip.open(sys.argv[1],"rb").read()
sys.exit(0 if b"@LongLink" in d else 1)' "$R/repo/main/packages/longname-a-1.0.0.tar.gz"; then
    ok "(1) the fixture tarball contains a GNU @LongLink entry -- the code path under test is actually reached"
else
    bad "(1) the fixture tarball has NO @LongLink entry -- nothing below measures the truncation"
    exit 1
fi

TRUNCREL="$(python3 -c '
import sys
arc = "longname-a-1.0.0/files/" + sys.argv[1]
print(arc[:100][len("longname-a-1.0.0/files/"):])' "$LONGREL")"
info "the truncated name a broken hpm would use: files/$TRUNCREL"

# ------------------------------------------------------------------- run
rm -f "$W/stdin.fifo"; mkfifo "$W/stdin.fifo"
exec 9<> "$W/stdin.fifo"

run_ns() {   # run_ns <seconds> <logfile> <hpm args...>
    local secs="$1" log="$2"; shift 2
    unshare -Urmp --fork --mount-proc bash -c '
        R="$1"; secs="$2"; shift 2
        mount --bind /dev/null "$R/dev/null" || exit 9
        timeout "$secs" /usr/sbin/chroot "$R" /bin/hpm "$@"
        echo "__RC__=$?"
    ' _ "$R" "$secs" "$@" > "$log" 2>&1 < "$W/stdin.fifo"
}

say "2. install longname-a"
run_ns 90 "$W/refresh.log" --repo=file:///repo/ --allow-unsigned refresh
grep -q '__RC__=0' "$W/refresh.log" \
    && ok "the fixture repository refreshes" \
    || { bad "refresh failed -- nothing below ran"; sed -n '1,20p' "$W/refresh.log"; exit 1; }

run_ns 90 "$W/install-a.log" --repo=file:///repo/ --allow-unsigned install longname-a
grep -q '__RC__=0' "$W/install-a.log" \
    && ok "hpm install longname-a returned 0" \
    || { bad "hpm install longname-a failed"; sed -n '1,25p' "$W/install-a.log"; }

# (2) _stage_extract_files -- the 1.0.25 fix, guarded against regression.
say "3. _stage_extract_files: where the file landed"
if [ -f "$R/$LONGREL" ]; then
    ok "(2) the installed file is at the FULL path /$LONGREL"
else
    bad "(2) the installed file is NOT at /$LONGREL -- the extract loop lost it"
fi
if [ -e "$R/$TRUNCREL" ]; then
    bad "(2) a file exists at the TRUNCATED path /$TRUNCREL -- hpm wrote the body to a name the archive does not contain"
else
    ok "(2) nothing exists at the truncated path /$TRUNCREL"
fi

# (3) _stage_tarball -- THE FIRST OF THE TWO THIS COMMIT CLOSES.
say "4. _stage_tarball: where the STAGED copy landed"
STAGE_FULL="$R/tmp/hpm/staging/longname-a-1.0.0/files/$LONGREL"
STAGE_TRUNC="$R/tmp/hpm/staging/longname-a-1.0.0/files/$TRUNCREL"
if [ ! -d "$R/tmp/hpm/staging/longname-a-1.0.0" ]; then
    bad "(3) hpm staged no tree at /tmp/hpm/staging/longname-a-1.0.0 -- _stage_tarball did not run and this gate did NOT measure it"
else
    STAGED_FULL=0; STAGED_TRUNC=0
    [ -f "$STAGE_FULL" ] && STAGED_FULL=1
    [ -e "$STAGE_TRUNC" ] && STAGED_TRUNC=1
    info "(3) staged-at-full=$STAGED_FULL staged-at-truncated=$STAGED_TRUNC"
    if [ "$CONTROL" = 1 ]; then
        if [ "$STAGED_TRUNC" = 1 ] && [ "$STAGED_FULL" = 0 ]; then
            ok "(3) CONTROL: without the 'L' branch _stage_tarball staged the member at the TRUNCATED path and not at the full one -- the defect is real and this gate can see it"
        else
            bad "(3) CONTROL: the branch-less build did NOT stage at the truncated path (full=$STAGED_FULL trunc=$STAGED_TRUNC) -- this gate cannot distinguish fixed from broken, so its green means nothing"
        fi
    else
        [ "$STAGED_FULL" = 1 ] \
            && ok "(3) the staged tree holds the member at the FULL path" \
            || bad "(3) the staged tree does NOT hold the member at the full path -- a hook reading HPM_PKG_DIR, or a source package's recipe, would not find it"
        [ "$STAGED_TRUNC" = 0 ] \
            && ok "(3) and nothing is staged at the truncated path" \
            || bad "(3) the staged tree holds the member at the TRUNCATED path"
    fi
fi

# (4) _check_file_conflicts -- THE SECOND, and the one that answered
#     success-shaped.
say "5. _check_file_conflicts: is a conflict on a long path seen at all?"
run_ns 90 "$W/install-b.log" --repo=file:///repo/ --allow-unsigned install longname-b
B_RC="$(grep -ao '__RC__=[0-9]*' "$W/install-b.log" | head -1 | cut -d= -f2)"
SAW_CONFLICT=0
grep -q 'file conflict' "$W/install-b.log" && SAW_CONFLICT=1
info "(4) hpm install longname-b returned ${B_RC:-none}; 'file conflict' printed=$SAW_CONFLICT"
if [ "$CONTROL" = 1 ]; then
    if [ "$SAW_CONFLICT" = 0 ] && [ "${B_RC:-1}" = 0 ]; then
        ok "(4) CONTROL: without the 'L' branch hpm ACCEPTED a package whose long path is owned by longname-a and reported no conflict -- the check answered success-shaped, which is what this commit closes"
    else
        bad "(4) CONTROL: the branch-less build still reported the conflict (rc=${B_RC:-none} conflict=$SAW_CONFLICT) -- this gate cannot distinguish fixed from broken"
    fi
else
    if [ "$SAW_CONFLICT" = 1 ] && [ "${B_RC:-0}" != 0 ]; then
        ok "(4) hpm REFUSED longname-b and named the conflict: $(grep -o 'hpm: file conflict:.*' "$W/install-b.log" | head -1)"
    else
        bad "(4) hpm did NOT refuse longname-b (rc=${B_RC:-none} conflict=$SAW_CONFLICT) -- a real conflict on a path over 100 bytes went unreported and the file was overwritten"
        sed -n '1,25p' "$W/install-b.log" | sed 's/^/        /'
    fi
    # And the byte on disk, because a refusal that still wrote is not a refusal.
    if [ -f "$R/$LONGREL" ]; then
        if grep -q 'payload-A' "$R/$LONGREL"; then
            ok "(4) longname-a's file still holds ITS OWN payload -- the refused install did not overwrite it"
        else
            bad "(4) longname-a's file now holds $(head -c 32 "$R/$LONGREL" | tr -d '\n') -- the install was refused and the file was overwritten anyway"
        fi
    fi
fi

exec 9>&-
echo
echo "longname: $pass passed, $fail failed"
[ "$fail" = 0 ]
