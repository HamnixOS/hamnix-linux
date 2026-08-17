#!/usr/bin/env bash
# tests/linux/served_install_binary.sh — NOBODY HAD EVER WATCHED THE WRONG
# /bin/install RUN. THIS BOOTS A MACHINE AND WATCHES IT.
#
# THE DEFECT, stated as measurements rather than as a story
# ========================================================
# `hamnix-install-1.0.26.tar.gz` on https://255.one/ carries TWO DIFFERENT
# PROGRAMS at two paths, and this gate re-measures all of it every run rather
# than trusting the sentence:
#
#   files/bin/hlinstall   274,840 bytes  sha256 d9cb5b55b1b2a9f3…
#   files/bin/install     338,432 bytes  sha256 8d7bca58b567fcea…
#
# The image stages hlinstall AT /bin/install (`install -m755 $ROOT/bin/hlinstall
# $ROOT/bin/install`), so a live medium's /bin/install is d9cb5b55…, which is
# byte-identical to the served bin/hlinstall. The CHANNEL put something else
# there: scripts/hamlinux_packages.py had `install` in SYS_CMDS, which builds
# user/install.ad. MEASURED here on 2026-08-17, not inferred --
# `scripts/hamlinux_build.sh user/install.ad build/…/install.elf` produces
# 8d7bca58b567fceac3137c9db0bbe5df030f0e9310e5185c13a929219b5a42b0, byte-for-byte
# the served bin/install. So the program 255.one serves at /bin/install IS
# user/install.ad.
#
# user/install.ad is THE NATIVE LINE'S INSTALLER. Every disk operation in it
# goes through the Hamnix kernel's `/dev/blk` file server and its
# `install_file` ctl verb. user/linux-syscalls.c's bind table says, in the
# tree, what this lane has:
#
#   { "#b", NULL, NULL, 0, "the /dev/blk file server is not written yet" },
#
# so `bind '#b' /dev/blk` — etc/rc.boot line 55 — cannot succeed here. That is
# a source reading; what a booted machine actually has is measured below.
#
# SO EVERY MACHINE THAT RUNS `hpm update` GETS ITS /bin/install REPLACED WITH A
# PROGRAM THAT HAS NO KERNEL TO TALK TO. scripts/hamlinux_packages.py is fixed
# in-tree (SYS_ALIASES), and the fix IS NOT PUBLISHED.
#
# THE QUESTION THAT DECIDES WHETHER THIS IS URGENT
# ================================================
# Does it fail loudly, fail silently, or DO DAMAGE? An installer that reports
# success while writing nothing is a shape this project has hit before (#464),
# and user/haminstallui.ad — the DE's install wizard, reachable from the app
# menu because hamnix-install ships etc/hamde/apps/installer.desktop — spawns
# `/bin/install --auto <disk> --repo … --esp-mb … --part-mode … --hostname …
# --user … --user-pass … --root-pass …` and calls the install SUCCEEDED when it
# sees the line "install complete" on that child's stdout. So the answer is
# also the answer for the graphical path.
#
# It is not an argv error, and the two programs' argv is not identical either.
# BOTH accept the token `--auto`, so neither rejects the wizard's command line:
#   user/install.ad:1492    `--auto` is a BARE boolean; the disk is positional
#   user/hlinstall.ad:656   `--auto` CONSUMES THE NEXT ARGUMENT as the disk
# The wizard passes `--auto <disk>`, which both therefore read as "unattended,
# onto <disk>". The difference is the kernel underneath, not the command line.
#
# WHAT THIS GATE MEASURES, AND WITH WHAT INSTRUMENT
# =================================================
# A. THE PREMISE, off the wire. Fetches https://255.one/linux/index.json and
#    the hamnix-install tarball it names, and requires the tarball to carry
#    bin/install and bin/hlinstall AS DIFFERENT BYTES. If they are ever the
#    same, the defect has been published away: this gate says so and stops
#    measuring behaviour, because there is no longer a wrong binary to watch.
#
# B. DELIVERY. A private channel is built by copying the tree's own 1.0.26
#    channel and putting the SERVED tarball into it, re-versioned to
#    <pub>+1 — so `hpm update` on an installed machine finds exactly ONE
#    upgradable package and the machine ends up holding the bytes 255.one is
#    serving right now. It is signed, and the machine gets the public key, so
#    this is the SIGNED update path with no escape hatch. The guest's own
#    md5sum of /bin/install before and after the update is compared against
#    GNU md5sum of the two files on the host: the gate proves WHICH program is
#    on the disk before it runs anything.
#
# C. BEHAVIOUR, IN A VM, on an installed disk booted through UEFI. The rc runs
#    the wizard's exact argv, prints `$status`, and prints a RETURNED marker
#    on the line after — because "it hung" is a third answer and has to be
#    distinguishable from "it failed".
#
# D. DAMAGE, ATTRIBUTED. Two instruments, because "the disk changed" is not
#    attributable to anything — ANY boot changes the root disk, and comparing
#    a whole-disk sha256 across a boot is a measurement that cannot name a
#    cause. Instead:
#
#    D1. A SECOND, BLANK DISK is attached as the install target. The host
#        writes it full of a KNOWN pattern from a fixed seed and records its
#        sha256; nothing in a boot of this machine touches an unpartitioned
#        spare volume, so any change to it is the installer's. After the boot
#        the host re-hashes it and asks `sfdisk -J` for a partition table --
#        the same instrument tests/linux/install_from_usb.sh uses to say "THE
#        TARGET HAS NO PARTITION TABLE -- the installer wrote nothing".
#    D2. NAMED FILES ON THE RUNNING ROOT, digested by the guest immediately
#        before and immediately after the installer runs: /etc/passwd,
#        /etc/shadow, /bin/hamsh, /etc/rc.boot.installed. A change in one of
#        those between two lines of one rc script is attributable to the
#        command between them.
#
# THE CONTROL, RUN RATHER THAN DESCRIBED — AND ITS FIRST FORM WAS WRONG
# =====================================================================
#   HAMLINUX_SVI_CONTROL=1
#
# WHAT D1 NEEDS FROM A CONTROL. "The target disk did not change" only means
# "the installer wrote nothing" if this harness can be shown to NOTICE a target
# disk that DID change. Nothing else in the run establishes that.
#
# THE FIRST ATTEMPT AT THIS CONTROL WAS RUN AND IT WENT RED, which is why it is
# not the one here. It delivered the tree's OWN hamnix-install (bin/install ==
# hlinstall, the correct program for this lane) and required the target to come
# back partitioned. hlinstall REFUSED, on this exact machine, and said why:
#
#   hlinstall: /boot/root.partuuid is missing or is not a UUID.
#
# /boot is the machine's own ESP (`bind '#esp' /boot`) and that file is written
# onto an INSTALLER MEDIUM, not onto an installed root — hlinstall is meant to
# be run FROM the stick. So the correct program cannot install from an
# installed machine either, and using it as the control measured that fact
# instead of measuring the instrument. It left the target untouched too, and
# two identical outcomes from two different programs is exactly the shape a
# blind instrument produces.
#
# SO THE CONTROL VALIDATES THE INSTRUMENT DIRECTLY, with no installer in it.
# The rc writes a GPT onto the target from inside the Debian namespace —
# `enter debian { sgdisk … /dev/vd? }`, which is the same route
# user/hlinstall.ad uses for partitioning (its header: "sgdisk, mkfs.vfat and
# mkfs.ext4 run INSIDE the Debian namespace") — and this gate then requires the
# host to see the target CHANGED and `sfdisk -J` to find a table on it. That is
# the narrow claim D1 rests on and the only one a control has to establish:
# if something in this VM writes a partition table to that volume, this harness
# notices. A control run is EXPECTED TO PASS.
#
# WHAT THIS GATE DOES NOT ANSWER
# ==============================
#  * NOTHING ABOUT THE GRAPHICAL PATH BEING DRIVEN. It runs the argv
#    user/haminstallui.ad spawns, on the console, and reads the child's output
#    the way the wizard's _emit_install_line does. It does NOT start wsysd,
#    click through the wizard, or prove the wizard's own disk picker offers a
#    disk -- and that last one matters, because
#    user/haminstallui.ad::_enumerate_disks lists `/dev/blk` too. Whether the
#    wizard can even reach the spawn is a separate question and is named here
#    as uncovered rather than implied.
#  * Nothing about a machine whose installed database records a version
#    255.one does not serve. This gate gives the machine the shipping-shape
#    database scripts/hamlinux_disk.sh writes.
#  * Nothing about the NATIVE Hamnix line, where user/install.ad is the
#    correct program and this whole file is inapplicable.
#
# Usage: tests/linux/served_install_binary.sh [boot-seconds]
#   HAMLINUX_SVI_CONTROL=1   the negative control described above
#   HAMLINUX_SVI_REUSE=1     reuse an already-built private channel
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

export HAMLINUX_VNC="${HAMLINUX_VNC:-none}"
export HAMLINUX_DISTRO_RO="${HAMLINUX_DISTRO_RO:-1}"
export TMPDIR="${TMPDIR:-$PROJ_ROOT/build/tmp}"
mkdir -p "$TMPDIR"

WAIT="${1:-900}"
CONTROL="${HAMLINUX_SVI_CONTROL:-0}"
CHAN="${HAMLINUX_HPM_CHANNEL:-build/repo/linux}"
PUB_BASE="${HAMLINUX_SVI_PUB:-https://255.one/linux}"

pass=0; fail=0
ok()   { echo "svi: PASS $*"; pass=$((pass+1)); }
bad()  { echo "svi: FAIL $*"; fail=$((fail+1)); }
info() { echo "svi: INFO $*"; }
say()  { echo "svi: --- $*"; }

WORK=build/servedinst
IMG=build/image
mkdir -p "$WORK"
if [ "$CONTROL" = 1 ]; then
    say "CONTROL: HAMLINUX_SVI_CONTROL=1 -- no installer runs. The rc writes a"
    say "CONTROL: GPT onto the target through the Debian namespace, and the"
    say "CONTROL: target MUST come back CHANGED and partitioned, or D1 is blind"
    say "CONTROL: and the main run's quiet target means nothing."
    WORK=build/servedinst-control
    mkdir -p "$WORK"
fi
REPO="$WORK/repo"
EXTRA="$WORK/extra"
DISK="$WORK/machine.img"
TARGET="$WORK/target.img"

[ -f "$IMG/distro.ext4" ] || { echo "svi: no $IMG/distro.ext4 -- the control's installer needs the Debian namespace for sgdisk/mkfs" >&2; exit 1; }
[ -d "$CHAN/packages" ]   || { echo "svi: no channel at $CHAN/packages -- build one: python3 scripts/hamlinux_packages.py --out build/repo --version <v>" >&2; exit 1; }

# =========================================================================
# A. THE PREMISE, OFF THE WIRE.
# =========================================================================
say "A. what https://255.one/ serves at bin/install today"

if ! curl -sS --max-time 60 -o "$WORK/pub-index.json" "$PUB_BASE/index.json"; then
    bad "could not fetch $PUB_BASE/index.json -- this gate's whole premise is a statement about what is SERVED, and it could not be read. Red rather than silent."
    echo; echo "svi: $pass passed, $fail failed"; exit 1
fi
read -r PUBVER PUBURL PUBSHA <<<"$(python3 - "$WORK/pub-index.json" <<'PY'
import json, sys
for p in json.load(open(sys.argv[1]))["packages"]:
    if p["name"] == "hamnix-install":
        print(p["version"], p["url"], p["sha256"]); break
PY
)"
if [ -z "${PUBVER:-}" ]; then
    bad "$PUB_BASE/index.json names no hamnix-install package -- nothing to measure"
    echo; echo "svi: $pass passed, $fail failed"; exit 1
fi
info "the published hamnix-install is $PUBVER ($PUBURL)"

PUBTAR="$WORK/hamnix-install-$PUBVER.tar.gz"
# `curl -f`, AND IT IS THE POINT. Without it this line fetched a 404 page,
# saved it as the tarball, and the sha256 guard below is the only reason that
# was caught rather than becoming "the served tarball has no bin/install".
if [ ! -s "$PUBTAR" ]; then
    curl -fsS --max-time 300 -o "$PUBTAR" "$PUB_BASE/$PUBURL" \
      || { bad "could not fetch $PUB_BASE/$PUBURL -- the bytes this gate is about could not be read"; rm -f "$PUBTAR"; echo; echo "svi: $pass passed, $fail failed"; exit 1; }
fi
GOTSHA="$(sha256sum "$PUBTAR" | cut -d' ' -f1)"
if [ "$GOTSHA" = "$PUBSHA" ]; then
    ok "the fetched tarball is the one the index names (sha256 ${GOTSHA:0:16}…)"
else
    bad "the fetched hamnix-install tarball's sha256 ${GOTSHA:0:16}… is not the index's ${PUBSHA:0:16}… -- NOT drawing conclusions from bytes whose provenance this gate cannot establish"
    echo; echo "svi: $pass passed, $fail failed"; exit 1
fi

rm -rf "$WORK/pubx"; mkdir -p "$WORK/pubx"
tar xzf "$PUBTAR" -C "$WORK/pubx" || { bad "the published tarball did not extract"; echo; echo "svi: $pass passed, $fail failed"; exit 1; }
PTOP="$WORK/pubx/hamnix-install-$PUBVER"
SERVED_INSTALL="$PTOP/files/bin/install"
SERVED_HLINSTALL="$PTOP/files/bin/hlinstall"

DEFECT_SERVED=0
if [ ! -f "$SERVED_INSTALL" ]; then
    bad "the published hamnix-install carries NO files/bin/install -- the image stages one at that path, so an update would leave a machine's /bin/install unowned. That is a different defect from the one this gate measures and it is not measured here."
elif [ ! -f "$SERVED_HLINSTALL" ]; then
    bad "the published hamnix-install carries NO files/bin/hlinstall"
elif cmp -s "$SERVED_INSTALL" "$SERVED_HLINSTALL"; then
    ok "the published bin/install and bin/hlinstall are BYTE-IDENTICAL ($(stat -c%s "$SERVED_INSTALL") bytes) -- the defect this gate exists for is NOT being served any more"
    info "sections B, C and D measure the behaviour of a wrong binary and there is no wrong binary to measure. NOT CHECKED, and scoring nothing."
    echo; echo "svi: $pass passed, $fail failed"; exit "$fail"
else
    DEFECT_SERVED=1
    ok "the published hamnix-install carries TWO DIFFERENT programs: bin/install is $(stat -c%s "$SERVED_INSTALL") bytes ($(sha256sum "$SERVED_INSTALL" | cut -c1-16)…) and bin/hlinstall is $(stat -c%s "$SERVED_HLINSTALL") bytes ($(sha256sum "$SERVED_HLINSTALL" | cut -c1-16)…)"
fi
[ "$DEFECT_SERVED" = 1 ] || { echo; echo "svi: $pass passed, $fail failed"; exit 1; }

# WHICH of the two the IMAGE stages, and whether the served hlinstall is the
# same program. Both are one `cmp` and both are load-bearing for the story
# above, so neither is left as prose.
if [ -f "$IMG/root/bin/install" ] && [ -f "$IMG/root/bin/hlinstall" ]; then
    if cmp -s "$IMG/root/bin/install" "$IMG/root/bin/hlinstall"; then
        ok "the staged image's /bin/install IS its /bin/hlinstall ($(stat -c%s "$IMG/root/bin/install") bytes) -- a live medium runs the Linux installer"
    else
        bad "the staged image's /bin/install is NOT its /bin/hlinstall -- the image side of this story is not what this gate assumed, and the assumption is now measured wrong"
    fi
    if cmp -s "$IMG/root/bin/hlinstall" "$SERVED_HLINSTALL"; then
        ok "the image's /bin/hlinstall is byte-identical to the SERVED bin/hlinstall -- the two sides agree about that program, so the disagreement is only at bin/install"
    else
        info "the image's /bin/hlinstall differs from the served one -- this tree and 255.one are not the same build of it, so the comparison above is about paths and not about a regression"
    fi
else
    info "NOT CHECKED: no staged image root at $IMG/root, so which program the image puts at /bin/install was not measured this run"
fi

# =========================================================================
# B. A PRIVATE CHANNEL THAT DELIVERS THOSE EXACT BYTES.
# =========================================================================
# The version is <published>+1 so `hpm update` performs a REAL upgrade. Only
# hamnix-install moves; every other package in the copied channel stays where
# the tree built it, so the machine's update log is about one package.
NEWVER="$(printf '%s\n' "$PUBVER" | awk -F. 'NF==3 && $3 ~ /^[0-9]+$/ {print $1"."$2"."$3+1}')"
[ -n "$NEWVER" ] || { bad "could not derive a version above $PUBVER"; echo; echo "svi: $pass passed, $fail failed"; exit 1; }
say "B. a private channel: everything at the tree's version, hamnix-install at $NEWVER"

PORT="$(python3 - <<'PY'
import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()
PY
)"
BASE="http://10.0.2.2:$PORT/"

if [ "${HAMLINUX_SVI_REUSE:-0}" = 1 ] && [ -f "$REPO/linux/index.json" ]; then
    say "reusing the private channel (HAMLINUX_SVI_REUSE=1)"
else
    rm -rf "$REPO"; mkdir -p "$REPO/linux/packages"
    cp "$CHAN"/packages/*.tar.gz "$REPO/linux/packages/"
    cp "$CHAN/index.json" "$REPO/linux/index.json"
    # THE ONE PACKAGE THIS GATE IS ABOUT, and the control uses the SAME payload
    # on purpose: the control boot differs from the main boot in exactly one
    # line of the rc -- what is run at the point of measurement -- and in
    # nothing else. A control that also changed the channel would differ in two
    # places and could not attribute its own result either.
    SRCTAR="$PUBTAR"
    say "repackaging the tarball 255.one serves as hamnix-install-$NEWVER"
    SRCTAR="$SRCTAR" NEWVER="$NEWVER" REPO="$REPO" WORK="$WORK" python3 - <<'PY' || { bad "could not repackage hamnix-install"; echo; echo "svi: $pass passed, $fail failed"; exit 1; }
import gzip, hashlib, io, json, os, re, tarfile

src, newver, repo, work = (os.environ[k] for k in ("SRCTAR", "NEWVER", "REPO", "WORK"))
newtop = "hamnix-install-%s" % newver
out_path = os.path.join(repo, "linux", "packages", newtop + ".tar.gz")

# Rewrite ONLY the top-level directory name and PKGINFO's version line. Every
# payload byte is carried across untouched -- that is the whole point: the
# machine must end up holding the bytes that were served.
members = []
with tarfile.open(src, "r:gz") as tf:
    oldtop = None
    for ti in tf.getmembers():
        top = ti.name.split("/", 1)[0]
        if oldtop is None:
            oldtop = top
        data = tf.extractfile(ti).read() if ti.isfile() else None
        members.append((ti, data))

buf = io.BytesIO()
gz = gzip.GzipFile(filename="", mode="wb", fileobj=buf, compresslevel=9, mtime=0)
with tarfile.open(fileobj=gz, mode="w", format=tarfile.GNU_FORMAT) as out:
    for ti, data in members:
        ti.name = newtop + ti.name[len(oldtop):]
        ti.uid = ti.gid = 0
        ti.uname = ti.gname = "root"
        ti.mtime = 0
        if data is not None and ti.name.endswith("/PKGINFO"):
            data = re.sub(rb"(?m)^version:.*$", b"version: " + newver.encode(), data)
            ti.size = len(data)
        if data is None:
            out.addfile(ti)
        else:
            out.addfile(ti, io.BytesIO(data))
gz.close()
raw = buf.getvalue()
open(out_path, "wb").write(raw)

# The payload the machine must end up holding, kept where the host can hash it.
with tarfile.open(out_path, "r:gz") as tf:
    for name, dest in ((newtop + "/files/bin/install", "delivered-install"),
                       (newtop + "/files/bin/hlinstall", "delivered-hlinstall")):
        try:
            open(os.path.join(work, dest), "wb").write(tf.extractfile(name).read())
        except KeyError:
            pass

ipath = os.path.join(repo, "linux", "index.json")
index = json.load(open(ipath))
seen = False
for e in index["packages"]:
    if e["name"] == "hamnix-install":
        e["version"] = newver
        e["url"] = "packages/" + newtop + ".tar.gz"
        e["sha256"] = hashlib.sha256(raw).hexdigest()
        e["size"] = len(raw)
        seen = True
if not seen:
    raise SystemExit("the copied index has no hamnix-install entry")
json.dump(index, open(ipath, "w"), indent=2)
open(ipath, "a").write("\n")
print("wrote %s (%d bytes)" % (out_path, len(raw)))
PY
    # The old tarball must not also be in the channel: two versions of one
    # package in one directory is a state no machine should be offered.
    rm -f "$REPO/linux/packages/hamnix-install-$PUBVER.tar.gz"
    for t in "$CHAN"/packages/hamnix-install-*.tar.gz; do
        [ -e "$t" ] || continue
        b="$(basename "$t")"
        [ "$b" = "hamnix-install-$NEWVER.tar.gz" ] || rm -f "$REPO/linux/packages/$b"
    done
fi

[ -s "$WORK/delivered-install" ] || { bad "the private channel's hamnix-install carries no bin/install -- the update could not deliver the program under test"; echo; echo "svi: $pass passed, $fail failed"; exit 1; }
EXPECT_MD5_INSTALL="$(md5sum "$WORK/delivered-install" | cut -d' ' -f1)"
EXPECT_SZ_INSTALL="$(stat -c%s "$WORK/delivered-install")"
say "the channel will deliver /bin/install = $EXPECT_MD5_INSTALL ($EXPECT_SZ_INSTALL bytes)"

# WHICH PROGRAM IS THAT, said in one line the report can quote.
if cmp -s "$WORK/delivered-install" "$SERVED_INSTALL"; then
    DELIVERS=served
    ok "the channel delivers the SERVED bin/install byte-for-byte -- what the machine ends up running is what 255.one hands out"
else
    DELIVERS=other
    bad "the channel's bin/install is not the served bytes -- this gate would be measuring some other program"
fi

# The tree's own /bin/install, for the guest's before-update digest.
BEFORE_MD5=""
[ -f "$IMG/root/bin/install" ] && BEFORE_MD5="$(md5sum "$IMG/root/bin/install" | cut -d' ' -f1)"

# SIGN IT. `--allow-unsigned` would prove the loop while proving nothing about
# the path a real machine takes.
mkdir -p "$EXTRA/etc/hpm"
python3 scripts/hpm_sign.py keygen --out-pub "$EXTRA/etc/hpm/test-trusted.pub" \
    --out-sec "$WORK/test.sec" >/dev/null || { bad "cannot mint a signing key"; echo; echo "svi: $pass passed, $fail failed"; exit 1; }
python3 scripts/hpm_sign.py sign "$REPO/linux/index.json" "$WORK/test.sec" \
    "$REPO/linux/index.json.sig" || { bad "cannot sign the private index"; echo; echo "svi: $pass passed, $fail failed"; exit 1; }

python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$REPO" \
    >"$WORK/http.log" 2>&1 &
HTTPD=$!
cleanup() { kill "$HTTPD" 2>/dev/null; wait "$HTTPD" 2>/dev/null; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
sleep 1
curl -fsS "http://127.0.0.1:$PORT/linux/index.json" >/dev/null \
    || { bad "the private channel is not being served"; echo; echo "svi: $pass passed, $fail failed"; exit 1; }
say "private channel served at $BASE (pid $HTTPD)"

# =========================================================================
# D1's INSTRUMENT, PREPARED: a blank target disk full of a known pattern.
# =========================================================================
# A fixed seed, so the "before" state is reproducible and this file can say
# what it was. Sparse would be wrong: a hole and a zero read the same to the
# guest but not to every tool that might later be pointed at this file, and a
# pattern that is not all-zero also means an installer that writes zeroes over
# it is a CHANGE this gate can see.
say "seeding a 640 MB blank target disk with a known pattern"
python3 - "$TARGET" <<'PY'
import hashlib, sys
# 640 MB: bigger than the 512 MB ESP user/haminstallui.ad asks for plus slack,
# so a correct installer has somewhere to put a root partition.
size = 640 * 1024 * 1024
block = b""
h = hashlib.sha256(b"served_install_binary/target-seed")
while len(block) < 1 << 20:
    h = hashlib.sha256(h.digest())
    block += h.digest()
block = block[: 1 << 20]
with open(sys.argv[1], "wb") as f:
    for _ in range(size >> 20):
        f.write(block)
PY
# sfdisk IS IN /sbin AND NOT ON PATH, and finding that out cost a control boot.
# `sfdisk -J "$TARGET"` from an ordinary user's shell fails with "command not
# found" -- and this gate's own instrument check read that as "no partition
# table", which is the success-shaped answer from a tool that was never there.
# The control is what caught it: sgdisk wrote a GPT, the guest kernel printed
# `vdc: vdc1 vdc2`, the target's sha256 changed, and this gate still said no
# table. Exactly the shape tests/linux's notes record for debugfs and dumpe2fs.
# So the binary is RESOLVED, and a gate that cannot find it goes RED.
SFDISK=""
for c in /sbin/sfdisk /usr/sbin/sfdisk "$(command -v sfdisk 2>/dev/null)"; do
    [ -n "$c" ] && [ -x "$c" ] && { SFDISK="$c"; break; }
done
if [ -z "$SFDISK" ]; then
    bad "no sfdisk on this host (looked in /sbin, /usr/sbin and \$PATH) -- D1's partition-table half CANNOT RUN, and a check that cannot run is red rather than quietly answering 'no table'"
    echo; echo "svi: $pass passed, $fail failed"; exit 1
fi
info "partition tables will be read with $SFDISK"

TARGET_SHA_BEFORE="$(sha256sum "$TARGET" | cut -d' ' -f1)"
TARGET_SZ="$(stat -c%s "$TARGET")"
say "target disk before the boot: $TARGET_SZ bytes, sha256 ${TARGET_SHA_BEFORE:0:16}…"

# WHICH /dev/vd? THE TARGET WILL BE, derived from the drive order
# scripts/hamlinux_vm.sh's `disk` mode builds rather than guessed: the machine's
# own root is the first virtio-blk volume, then distro.ext4, then alpine.ext4 if
# the tree has one, and this gate's target is appended after all of them. The
# guest is asked for /proc/partitions and the derivation is CHECKED against the
# size, below -- a wrong letter would otherwise make the installer fail for a
# reason that has nothing to do with which program it is.
SVI_TARGET_DEV=/dev/vdc
[ -f "$IMG/alpine.ext4" ] && SVI_TARGET_DEV=/dev/vdd
TARGET_KB=$((TARGET_SZ / 1024))
say "the target will be $SVI_TARGET_DEV ($TARGET_KB 1K-blocks); the guest's /proc/partitions is checked against that"
# THE INSTRUMENT, CHECKED BEFORE IT IS TRUSTED. `sfdisk -J` must say NOTHING
# about a disk full of pattern, or "no partition table afterwards" would be a
# blind spot rather than a measurement.
if "$SFDISK" -J "$TARGET" >/dev/null 2>&1; then
    bad "INSTRUMENT: sfdisk -J already reports a partition table on the freshly seeded target -- it cannot tell a written target from an unwritten one, so D1 would be meaningless"
else
    ok "INSTRUMENT: sfdisk -J finds no partition table on the seeded target, so a table afterwards is a measurement and not a blind spot"
fi

# =========================================================================
# C's SCRIPT. The order is deliberate: everything that must be known is
# measured BEFORE the installer is invoked, because the installer may not
# return and then nothing below it runs.
# =========================================================================
mkdir -p "$EXTRA/etc"
# THE ONE LINE THE TWO BOOTS DIFFER BY. The main run invokes the program under
# test with the argv user/haminstallui.ad spawns. The control writes a GPT onto
# the same target through the Debian namespace -- the same route
# user/hlinstall.ad partitions by -- and runs no installer at all.
# EVERY COLON-BEARING OPERAND IS QUOTED, and it is not decoration. hamsh lexes
# `:` as its own token (it opens a suite), so the unquoted form
# `-n 1:2048:+64M` made the WHOLE rc fail to parse -- `hamsh: parse error
# [line 48]: unexpected token after command`, at parse time, so not one line of
# the script ran and the control measured nothing at all. Measured, in a boot.
if [ "$CONTROL" = 1 ]; then
    MEASURED_CMD="enter debian { /usr/sbin/sgdisk --zap-all -n '1:2048:+64M' -t '1:ef00' -n '2:0:0' -t '2:8300' $SVI_TARGET_DEV }"
else
    MEASURED_CMD="/bin/install --auto $SVI_TARGET_DEV --repo file:///iso-packages --esp-mb 512 --part-mode guided --hostname svibox --user svi --user-pass svipass --root-pass rootpass"
fi
cat > "$WORK/rc.phase1" <<RC
source '/etc/rc.boot.installed'

echo '[svi] ===== an installed machine updates itself, then runs /bin/install'
date

echo '[svi] BEFORE-UPDATE md5 of /bin/install:'
md5sum /bin/install
echo '[svi] BEFORE-UPDATE md5 of /bin/hlinstall:'
md5sum /bin/hlinstall

echo '[svi] update against the private channel'
hpm --repo=$BASE --trusted-key=/etc/hpm/test-trusted.pub update
echo '[svi] update status:' \$status
echo '[svi] hpm list after update:'
hpm list

echo '[svi] AFTER-UPDATE md5 of /bin/install:'
md5sum /bin/install
echo '[svi] AFTER-UPDATE md5 of /bin/hlinstall:'
md5sum /bin/hlinstall
echo '[svi] AFTER-UPDATE ls -l /bin/install:'
ls -l /bin/install

# WHAT THIS MACHINE HAS TO INSTALL ONTO, measured rather than assumed. The
# whole story about user/install.ad rests on /dev/blk, so the machine is asked
# for it directly and the answer goes in the log either way.
echo '[svi] does this machine have /dev/blk?'
ls /dev/blk
echo '[svi] ls /dev/blk status:' \$status
echo '[svi] what the Linux kernel enumerated (/proc/partitions):'
cat /proc/partitions
echo '[svi] what /sys/block holds (hlinstall reads this):'
ls /sys/block
echo '[svi] ls /sys/block status:' \$status

# D2: the running root's own files, digested immediately before the installer.
echo '[svi] PRE-RUN md5 /etc/passwd:'
md5sum /etc/passwd
echo '[svi] PRE-RUN md5 /etc/shadow:'
md5sum /etc/shadow
echo '[svi] PRE-RUN md5 /bin/hamsh:'
md5sum /bin/hamsh
echo '[svi] PRE-RUN md5 /etc/rc.boot.installed:'
md5sum /etc/rc.boot.installed

# ===== THE MEASUREMENT. The banner does NOT quote the command: \$MEASURED_CMD
# contains single quotes of its own (see the note beside it on the host side),
# and interpolating it inside echo '…' closed the outer quoting and produced a
# second parse error -- another whole boot in which nothing ran. The host prints
# the command in its VERDICT lines instead, where no shell has to lex it.
echo '[svi] ===== RUN: the command under measurement'
$MEASURED_CMD
echo '[svi] MEASURED status:' \$status
echo '[svi] MEASURED RETURNED'

# D2 again, on the far side of that one command.
echo '[svi] POST-RUN md5 /etc/passwd:'
md5sum /etc/passwd
echo '[svi] POST-RUN md5 /etc/shadow:'
md5sum /etc/shadow
echo '[svi] POST-RUN md5 /bin/hamsh:'
md5sum /bin/hamsh
echo '[svi] POST-RUN md5 /etc/rc.boot.installed:'
md5sum /etc/rc.boot.installed

date
echo '[svi] PHASE1 DONE'
reboot
RC

# =========================================================================
# BUILD THE MACHINE. Shipping shape, database included: this is the disk a
# person has, and the database is what makes `hpm update` do anything at all
# (it was a no-op on every freshly installed machine before commit dbe56404).
# =========================================================================
say "building the installed disk (shipping shape, with the package database)"
HAMLINUX_DISK_RC="$WORK/rc.phase1" HAMLINUX_DISK_EXTRA="$EXTRA" \
HAMLINUX_HPM_CHANNEL="$CHAN" \
    scripts/hamlinux_disk.sh "$DISK" 3G >"$WORK/build.log" 2>&1 || {
    bad "the installed disk did not build"; tail -20 "$WORK/build.log" | sed 's|^|        |'
    echo; echo "svi: $pass passed, $fail failed"; exit 1; }
grep -q 'NO PACKAGE DATABASE\|records NO installed' "$WORK/build.log" \
    && bad "the disk was built WITHOUT a package database -- \`hpm update\` on it refuses, and section B would not deliver anything" \
    || ok "the disk carries the shipping-shape package database"

# =========================================================================
# BOOT IT. The target disk is attached as an extra virtio volume; disk mode
# passes trailing arguments straight to QEMU.
# =========================================================================
say "booting the installed machine through UEFI (up to ${WAIT}s)"
( sleep 5 ) | HAMLINUX_DISK="$DISK" \
    timeout "$((WAIT + 20))" scripts/hamlinux_vm.sh disk --timeout "$WAIT" \
    -drive "file=$TARGET,if=virtio,format=raw" \
    >"$WORK/boot.log" 2>&1
info "serial log: $WORK/boot.log ($(stat -c%s "$WORK/boot.log" 2>/dev/null || echo 0) bytes)"

TARGET_SHA_AFTER="$(sha256sum "$TARGET" | cut -d' ' -f1)"

echo
grep -aE '^\[svi\]|^rc\.boot:|^\[install\]|^hlinstall|^hamnix-linux installer' "$WORK/boot.log" \
    || { echo "no guest output at all; boot log tail:"; tail -30 "$WORK/boot.log"; }
echo

# =========================================================================
# THE QUESTIONS.
# =========================================================================
LOG="$WORK/boot.log"
if [ ! -s "$LOG" ]; then
    bad "THE SERIAL LOG IS EMPTY -- a harness failure, not a verdict on any installer"
    echo; echo "svi: $pass passed, $fail failed"; exit 1
fi
check()   { if grep -aqE "$2" "$LOG"; then ok "$1"; else bad "$1   (no line matching /$2/)"; fi; }
afterN()  { n="$1"; shift
            got="$(grep -aA"$n" -F "$2" "$LOG" | tail -n +2 | tr -d '\r')"
            if printf '%s\n' "$got" | grep -qE "$3"; then
                ok "$1  -> '$(printf '%s\n' "$got" | grep -E "$3" | head -1 | cut -c1-100)'"
            else
                bad "$1  (nothing matching /$3/ in the $n lines after '$2')"
            fi; }
after()   { got="$(grep -aA4 -F "$2" "$LOG" | tail -n +2 | tr -d '\r')"
            if printf '%s\n' "$got" | grep -qE "$3"; then
                ok "$1  -> '$(printf '%s\n' "$got" | grep -E "$3" | head -1 | cut -c1-100)'"
            else
                bad "$1  (nothing matching /$3/ after '$2'; got: $(printf '%s' "$got" | tr '\n' '|' | cut -c1-200))"
            fi; }

# THE GAP THAT WOULD HAVE ANSWERED SUCCESS-SHAPED, and it is checked FIRST.
# hamsh parses the whole rc before running any of it, so ONE bad token anywhere
# in the script means not a single line executes -- and then the target disk is
# untouched, the running root's files are unchanged, and every "it wrote
# nothing" observation below is true of a boot in which nothing ran at all.
# This happened: an unquoted `-n 1:2048:+64M` in the control's command produced
# `hamsh: parse error [line 48]: unexpected token after command` and a boot
# whose log contained no [svi] line whatsoever.
if grep -aq 'hamsh: parse error' "$LOG"; then
    bad "THE rc DID NOT PARSE, so nothing in it ran and NOTHING below is a measurement of any program: $(grep -a 'hamsh: parse error' "$LOG" | head -1 | tr -d '\r')"
    sed -n "$(grep -a -o 'line [0-9]*' "$LOG" | head -1 | awk '{print $2}')p" "$WORK/rc.phase1" 2>/dev/null | sed 's|^|        offending line: |'
    echo; echo "svi: $pass passed, $fail failed"; exit 1
fi

say "the machine, and what the update put on it"
check "the installed root came online" 'rc\.boot: hamnix-linux \(installed\)'
[ -n "$BEFORE_MD5" ] && after "before the update, /bin/install was the image's own program" \
    '[svi] BEFORE-UPDATE md5 of /bin/install:' "$BEFORE_MD5"
check "hpm update exited 0" '\[svi\] update status: 0'
# `hpm list` prints a line per installed package -- 130 of them -- so this is
# a whole-log grep and not an "the line after the banner" match. The version
# string is one this tree has never built and 255.one does not serve, so only
# the update can have put it in this log.
check  "the machine's own list records hamnix-install at $NEWVER" "hamnix-install[^0-9]*$NEWVER"
# THE LOAD-BEARING ONE. Everything below is only a statement about the program
# under test if the program under test is what is on the disk.
after  "the update REPLACED /bin/install with the bytes the channel served" \
       '[svi] AFTER-UPDATE md5 of /bin/install:' "$EXPECT_MD5_INSTALL"

say "what this machine has to install onto"
if grep -aq '\[svi\] ls /dev/blk status: 0' "$LOG"; then
    info "/dev/blk IS readable on this machine -- the source reading in this file's header (#b unimplemented) does not describe the booted system, and the reason user/install.ad fails is NOT simply an absent /dev/blk"
else
    ok "/dev/blk is NOT readable on this machine, measured -- every disk operation in user/install.ad goes through it"
fi
# THE DERIVATION, CHECKED. `$SVI_TARGET_DEV` was worked out from the drive
# order on the host; if the guest's kernel put a volume of the target's size
# somewhere else, the installer was pointed at the wrong disk and every result
# about it below would be about that mistake instead of about the program.
TGT_BARE="${SVI_TARGET_DEV#/dev/}"
afterN 14 "the kernel enumerated a $TARGET_KB-block volume at $TGT_BARE, so the installer was pointed at the target and not at something else" \
      '[svi] what the Linux kernel enumerated (/proc/partitions):' \
      "[[:space:]]$TARGET_KB[[:space:]]+$TGT_BARE\$"

say "THE ANSWER: what the command under measurement did"
if grep -aq '\[svi\] MEASURED RETURNED' "$LOG"; then
    ok "it RETURNED -- it did not hang, so 'loudly or silently' is the whole question"
    STAT="$(grep -a '\[svi\] MEASURED status:' "$LOG" | head -1 | tr -d '\r' | awk '{print $NF}')"
    info "its exit status was ${STAT:-unreadable}"
    if [ "${STAT:-x}" = 0 ]; then
        SVI_VERDICT="exited 0"
    else
        SVI_VERDICT="exited ${STAT:-unreadable}"
    fi
else
    bad "it NEVER RETURNED -- the rc has no line after it, so this program HANGS on this machine rather than failing. That is a third answer and a worse one: the DE wizard would sit on its progress page forever."
    SVI_VERDICT="hung"
fi
# The wizard's own success criterion, applied to the same bytes it would read.
if grep -aq 'install complete' "$LOG"; then
    SVI_SAIDOK=yes
else
    SVI_SAIDOK=no
fi

say "D1: did anything reach the target disk?"
info "target sha256 before ${TARGET_SHA_BEFORE:0:16}… after ${TARGET_SHA_AFTER:0:16}…"
TARGET_TOUCHED=no
[ "$TARGET_SHA_BEFORE" = "$TARGET_SHA_AFTER" ] || TARGET_TOUCHED=yes
TARGET_TABLE=no
"$SFDISK" -J "$TARGET" >"$WORK/target-table.json" 2>/dev/null && TARGET_TABLE=yes
info "the target disk was $( [ "$TARGET_TOUCHED" = yes ] && echo CHANGED || echo UNCHANGED ), and $SFDISK -J $( [ "$TARGET_TABLE" = yes ] && echo FINDS || echo finds NO ) partition table on it"
if [ "$TARGET_TABLE" = yes ]; then
    NPARTS="$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["partitiontable"]["partitions"]))' "$WORK/target-table.json" 2>/dev/null || echo 0)"
    info "the target has ${NPARTS:-0} partitions"
fi

say "D2: did the RUNNING system change across that one command?"
d2() {  # d2 <file> <pre-banner> <post-banner>
    a="$(grep -aA2 -F "$2" "$LOG" | tail -n +2 | grep -aoE '^[0-9a-f]{32}' | head -1)"
    b="$(grep -aA2 -F "$3" "$LOG" | tail -n +2 | grep -aoE '^[0-9a-f]{32}' | head -1)"
    if [ -z "$a" ] || [ -z "$b" ]; then
        bad "$1: this gate did not get both digests (pre='${a:-none}' post='${b:-none}') -- NOT reporting it as unchanged"
    elif [ "$a" = "$b" ]; then
        ok "$1 is unchanged across the installer's run ($a)"
    else
        bad "$1 CHANGED across the installer's run ($a -> $b) -- the command between those two lines is the only thing that ran"
    fi
}
d2 /etc/passwd            '[svi] PRE-RUN md5 /etc/passwd:'            '[svi] POST-RUN md5 /etc/passwd:'
d2 /etc/shadow            '[svi] PRE-RUN md5 /etc/shadow:'            '[svi] POST-RUN md5 /etc/shadow:'
d2 /bin/hamsh             '[svi] PRE-RUN md5 /bin/hamsh:'             '[svi] POST-RUN md5 /bin/hamsh:'
d2 /etc/rc.boot.installed '[svi] PRE-RUN md5 /etc/rc.boot.installed:' '[svi] POST-RUN md5 /etc/rc.boot.installed:'

check "the rc reached its end" '\[svi\] PHASE1 DONE'

# =========================================================================
# THE VERDICT, and the control's own assertion.
# =========================================================================
echo
say "VERDICT: measured command: $MEASURED_CMD"
say "VERDICT: /bin/install on the disk = $EXPECT_MD5_INSTALL ($EXPECT_SZ_INSTALL bytes, $( [ "$DELIVERS" = served ] && echo 'the bytes 255.one serves' || echo 'NOT the served bytes' ))"
say "VERDICT:   it $SVI_VERDICT"
say "VERDICT:   it did $( [ "$SVI_SAIDOK" = yes ] && echo '' || echo 'NOT ')print 'install complete' (the DE wizard's success criterion)"
say "VERDICT:   the blank target disk was $( [ "$TARGET_TOUCHED" = yes ] && echo CHANGED || echo UNCHANGED ) and has $( [ "$TARGET_TABLE" = yes ] && echo 'a partition table' || echo 'NO partition table' )"

if [ "$CONTROL" = 1 ]; then
    say "the control's own assertion -- THIS IS WHAT MAKES D1 EVIDENCE"
    if [ "$TARGET_TOUCHED" = yes ] && [ "$TARGET_TABLE" = yes ]; then
        ok "CONTROL: a GPT written from inside this VM came back visible to the host -- the target disk CHANGED and sfdisk -J found ${NPARTS:-?} partitions. So 'UNCHANGED, no partition table' in the main run is a measurement of a program that wrote nothing, and not a blind instrument."
    else
        bad "CONTROL: sgdisk ran in the guest and the host still sees the target $( [ "$TARGET_TOUCHED" = yes ] && echo 'changed but unpartitioned' || echo UNCHANGED ) -- this harness cannot see a target disk being written, so the main run's quiet target proves NOTHING"
        grep -a -A6 '\[svi\] ===== RUN' "$LOG" | head -12 | sed 's|^|        |'
    fi
else
    # THE ONE THING A GREEN MAIN RUN MUST NOT BE. A run that reports the wrong
    # program said "install complete" over an untouched disk is the #464 shape
    # and is the urgent answer; it is a FAIL here so it can never be missed.
    if [ "$SVI_SAIDOK" = yes ] && [ "$TARGET_TABLE" = no ]; then
        bad "SILENT SUCCESS: the wrong /bin/install printed 'install complete' and the target disk has no partition table. The DE wizard reads exactly that string to paint its success page, so the graphical installer would tell a person their disk was installed when nothing was written to it."
    fi
    if [ "$TARGET_TOUCHED" = yes ]; then
        bad "THE WRONG PROGRAM WROTE TO THE TARGET DISK (sha256 ${TARGET_SHA_BEFORE:0:16}… -> ${TARGET_SHA_AFTER:0:16}…). Whatever it wrote, it was not asked to write it by anything that understands this lane."
    fi
fi

echo
echo "(log: $WORK/boot.log; channel: $REPO; target: $TARGET)"
echo "svi: $pass passed, $fail failed"
[ "$fail" = 0 ]
