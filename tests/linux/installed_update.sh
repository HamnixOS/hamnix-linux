#!/usr/bin/env bash
# tests/linux/installed_update.sh — the update path on an INSTALLED machine.
#
# THE SENTENCE THIS TEST EXISTS FOR, said by the person the system is being
# built for:
#
#   "I want the package manager to be truly useful so an installed system can
#    just update to get any changes we make, so that I can install this on a
#    box, you make edits, they land on 255.one, and I run the update command,
#    no re-image needed."
#
# The loop was proven once (commit a548c6ec) on the LIVE image -- the boot that
# is thrown away. Every byte hpm wrote there went into a tmpfs. This runs the
# same loop on a disk that was INSTALLED, and then REBOOTS it, because the
# whole claim is about a machine that persists.
#
# That distinction has bitten this tree before and hard: `enter debian { sh }`
# worked on every live boot and had never worked on an installed one, because
# etc/rc.boot.installed carried no template at all (ce7cb65b). A subsystem can
# work on every boot that is discarded and none of the boots that keep.
#
# WHAT IS ACTUALLY MEASURED, in order:
#
#   boot 1   the installed root comes online (UEFI -> unified kernel image ->
#            the Adder PID 1 -> bind '#sysroot' / -> /etc/rc.boot)
#            dhcpc            -> a DHCP lease, not the static line the rc set
#            hpm refresh      -> the REAL https://255.one/ over TLS
#            hpm install      -> a package the image does NOT ship (diff)
#            diff             -> it runs, and gives both answers (0 and 1)
#            ... a newer build is published to a LOCAL channel ...
#            hpm update       -> the version moves 1.0.7 -> 1.0.8
#            diff             -> the UPGRADED binary still runs
#            cksum </bin/diff -> byte-identical to what the host published
#            cat /etc/hamnix-update-stamp -> a token minted by THIS test run,
#                                            i.e. "the edit landed"
#   boot 2   the same disk image, booted again with nothing rebuilt
#            the version, the bytes and the stamp are all still there
#            the upgraded binary still runs
#            and the same questions asked as uid 1001, the desktop user
#
# WHY A STAMP AND A CHECKSUM AND NOT JUST A VERSION NUMBER. "The version
# moved" is satisfied by a database edit; the owner's sentence is about CODE
# landing. The stamp is minted at test time and cannot pre-exist anywhere, and
# the CRC is computed by the host from the very bytes it served. Together they say the
# exact bytes published after the install are the bytes on the installed disk
# after a reboot. A `hpm list` line alone could not.
#
# WHY A LOCAL CHANNEL AND NOT 255.one. Publishing to the real repository is
# the machine owner's to do. "A newer build lands" is modelled exactly -- the
# same scripts/hamlinux_packages.py lane, the same static tree, served over
# HTTP -- and only the hostname differs.
#
# Usage: tests/linux/installed_update.sh [phase1-seconds] [phase2-seconds]
#   HAMLINUX_UPD_REUSE=1   reuse an already-built local channel + image root
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

export HAMLINUX_VNC="${HAMLINUX_VNC:-none}"
export HAMLINUX_DISTRO_RO="${HAMLINUX_DISTRO_RO:-1}"
# QEMU's snapshot overlay lands in TMPDIR, and /tmp on the dev box is a 16 GB
# tmpfs -- i.e. the owner's RAM. Keep it on real disk unless told otherwise.
export TMPDIR="${TMPDIR:-$PROJ_ROOT/build/tmp}"
mkdir -p "$TMPDIR"

WAIT1="${1:-900}"
WAIT2="${2:-600}"
PKG=hamnix-diff          # ships /bin/diff, which the image does NOT carry
BIN=/bin/diff

# THE "NEWER BUILD" MUST ACTUALLY BE NEWER THAN THE REAL REPOSITORY'S.
#
# This was a hard-coded 1.0.8, and it went red the day https://255.one/
# published hamnix-diff 1.0.8 itself: the first `hpm install` -- which is
# supposed to fetch the OLDER release from the real repo -- already got 1.0.8,
# so `hpm update` correctly reported `upgraded=0`, and the stamped local build
# never landed. Five checks failed and every one of them pointed at the update
# path rather than at the collision, which is the expensive kind of red.
#
# So the version is DERIVED: ask the real repository what it serves and bump
# the patch. The number this test invents can then never be a number the
# repository already has, and publishing a new release cannot break the gate
# that proves publishing works.
_repo_ver() {
    curl -fsS --max-time 20 https://255.one/linux/index.json 2>/dev/null |
    PKG="$PKG" python3 -c '
import json, os, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
p = d.get("packages", d) if isinstance(d, dict) else d
rows = p if isinstance(p, list) else [dict(v, name=k) for k, v in p.items()]
for r in rows:
    if r.get("name") == os.environ["PKG"]:
        print(r.get("version", ""))
        break
' 2>/dev/null
}
if [ -n "${HAMLINUX_UPD_VERSION:-}" ]; then
    NEWVER="$HAMLINUX_UPD_VERSION"
else
    BASEVER="$(_repo_ver)"
    if [ -n "$BASEVER" ]; then
        # <major>.<minor>.<patch+1>. A repository version this cannot parse
        # falls back rather than inventing a version that sorts BELOW it.
        NEWVER="$(printf '%s\n' "$BASEVER" | awk -F. 'NF==3 && $3 ~ /^[0-9]+$/ {print $1"."$2"."$3+1}')"
        [ -n "$NEWVER" ] || NEWVER=1.0.99
        say_ver="derived from the live repository's $BASEVER"
    else
        NEWVER=1.0.99
        say_ver="the repository did not answer; using a version above any it is likely to serve"
    fi
    echo "[iupd] the 'newer build' will be $NEWVER ($say_ver)"
fi

WORK=build/installedupd; mkdir -p "$WORK"
IMG=build/image
DISK="$IMG/installedupd.img"
REPO="$WORK/repo"
EXTRA="$WORK/extra"
[ -f "$IMG/distro.ext4" ] || { echo "no distro image; run scripts/hamlinux_distro.sh" >&2; exit 1; }

fail=0
say() { echo "[iupd] $*"; }

# --- the token that cannot pre-exist --------------------------------------
STAMP="hamnix-update-$(date +%s)-$$-$RANDOM"

# --- a free port on the host ----------------------------------------------
# The guest reaches the host at 10.0.2.2 through QEMU's user-mode stack, which
# forwards to the host's loopback. A fixed port would make two runs of this
# gate collide, and the second one would fail as a network error rather than
# as a port clash -- the failure mode this tree keeps relearning.
PORT="$(python3 - <<'PY'
import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()
PY
)"
BASE="http://10.0.2.2:$PORT/"

# =========================================================================
# 1. The image root. Built FIRST and deliberately.
# =========================================================================
# scripts/hamlinux_disk.sh packs build/image/root, and /etc/rc.distros -- the
# thing that makes `enter` work -- is GENERATED into that root by
# scripts/hamlinux_image.sh. Run against a stale root, a gate here fails in
# ways that read exactly like the feature being broken. Same lesson as
# tests/linux/installed_distros.sh.
if [ "${HAMLINUX_UPD_REUSE:-0}" = 1 ] && [ -f "$IMG/initramfs.cpio.gz" ]; then
    say "reusing the staged image root (HAMLINUX_UPD_REUSE=1)"
else
    say "staging the image root"
    HAMLINUX_JOBS="${HAMLINUX_JOBS:-4}" scripts/hamlinux_image.sh \
        >"$WORK/image.log" 2>&1 || {
        echo "FAIL image build"; tail -20 "$WORK/image.log"; exit 1; }
fi

# The negative control for step 3 has to be true: the image must NOT already
# carry the program we are about to install. If it ever does, this gate would
# "pass" while proving nothing, so it refuses instead.
if [ -e "$IMG/root$BIN" ]; then
    echo "FAIL: the image already ships $BIN -- pick a package the image does" >&2
    echo "      not carry, or this test cannot tell an install from a no-op." >&2
    exit 1
fi

# =========================================================================
# 2. "A newer build is published."
# =========================================================================
# The same lane that produces what goes to 255.one, at a higher version, into
# a directory served over HTTP. Nothing is uploaded anywhere.
if [ "${HAMLINUX_UPD_REUSE:-0}" = 1 ] && [ -f "$REPO/linux/index.json" ]; then
    say "reusing the local channel at $NEWVER (HAMLINUX_UPD_REUSE=1)"
else
    say "building the local channel at $NEWVER (this is the 'newer build')"
    scripts/hamlinux_packages.py --out "$REPO" --version "$NEWVER" \
        --channel linux --base-url "$BASE" >"$WORK/repo.log" 2>&1 || {
        echo "FAIL channel build"; tail -20 "$WORK/repo.log"; exit 1; }
fi

# THE EDIT. A file that exists in this run and in no other, added to the one
# package under test, with the index's sha256 and size corrected -- so hpm's
# own integrity check has to accept it, and an installed machine that ends up
# holding these bytes got them from here and nowhere else.
say "stamping the new $PKG-$NEWVER with $STAMP"
PUBLISHED="$WORK/published-bin"
STAMP="$STAMP" PKG="$PKG" NEWVER="$NEWVER" REPO="$REPO" PUBLISHED="$PUBLISHED" python3 - <<'PY' || { echo "FAIL: could not stamp the package"; exit 1; }
import gzip, hashlib, io, json, os, tarfile

repo, pkg, ver, stamp = (os.environ[k] for k in ("REPO", "PKG", "NEWVER", "STAMP"))
published = os.environ["PUBLISHED"]
tarpath = os.path.join(repo, "linux", "packages", "%s-%s.tar.gz" % (pkg, ver))
top = "%s-%s" % (pkg, ver)

members = []
with tarfile.open(tarpath, "r:gz") as tf:
    for ti in tf.getmembers():
        members.append((ti, tf.extractfile(ti).read() if ti.isfile() else None))

buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w:gz", compresslevel=9,
                  format=tarfile.GNU_FORMAT) as out:
    for ti, data in members:
        # Idempotent: a reused channel already carries a stamp from an
        # earlier run, and two stamps in one tarball would make the guest's
        # `cat` ambiguous. The new one replaces it.
        if ti.name.endswith("/files/etc/hamnix-update-stamp"):
            continue
        if data is None:
            out.addfile(ti)
            continue
        if ti.name.startswith(top + "/files/bin/"):
            # Keep the exact payload the guest is about to be sent, so the
            # host can state what the checksum on the installed disk MUST be.
            with open(published, "wb") as pb:
                pb.write(data)
        out.addfile(ti, io.BytesIO(data))
    payload = (stamp + "\n").encode()
    ti = tarfile.TarInfo(top + "/files/etc/hamnix-update-stamp")
    ti.size, ti.mode, ti.mtime = len(payload), 0o644, 0
    ti.uid = ti.gid = 0
    ti.uname = ti.gname = "root"
    out.addfile(ti, io.BytesIO(payload))
raw = buf.getvalue()
with open(tarpath, "wb") as fh:
    fh.write(raw)

ipath = os.path.join(repo, "linux", "index.json")
index = json.load(open(ipath))
for e in index["packages"]:
    if e["name"] == pkg:
        e["sha256"] = hashlib.sha256(raw).hexdigest()
        e["size"] = len(raw)
with open(ipath, "w") as fh:
    json.dump(index, fh, indent=2)
    fh.write("\n")
PY
[ -s "$PUBLISHED" ] || { echo "FAIL: the package carried no binary"; exit 1; }

# THE CHECKSUM THE GUEST WILL BE ASKED FOR, and why it is `cksum` and not
# `md5sum`. user/md5sum.ad is a MARKER-SHAPE STUB: it drains stdin, ignores
# its argument entirely and prints the MD5 of the empty string as a constant.
# Asked for a digest of an installed binary it would have blocked forever on
# the console and, had it not, answered d41d8cd9... for any file on the disk.
# user/cksum.ad is the real POSIX CRC-32 and agrees with GNU cksum byte for
# byte -- so the host can compute the answer here and the guest must produce
# the same two numbers.
EXPECT_CKSUM="$(cksum < "$PUBLISHED")"
say "the published $BIN is cksum '$EXPECT_CKSUM'"

# AND THE MD5, COMPUTED BY GNU md5sum, over the same bytes. user/md5sum.ad is
# a real RFC 1321 digest now; this is what the guest's copy has to agree with,
# on a 150 KB file and on a stream, or the tool is back to answering without
# doing anything.
EXPECT_MD5="$(md5sum "$PUBLISHED" | cut -d' ' -f1)"
EXPECT_MD5_STREAM="$(printf '%s\n' "$STAMP" | md5sum | cut -d' ' -f1)"
say "the published $BIN is md5 $EXPECT_MD5; the stamp stream is md5 $EXPECT_MD5_STREAM"

# SIGN IT, and give the machine the key.
#
# hpm verifies a detached Ed25519 signature over the raw index bytes before it
# trusts a single hash inside, and that is the right default. `--allow-unsigned`
# would prove the loop while proving nothing about the path a real machine
# takes, so the local channel is signed with a key minted for this run and the
# guest is handed the matching public key -- the SIGNED update path, on an
# installed disk, with no escape hatch.
mkdir -p "$EXTRA/etc/hpm"
python3 scripts/hpm_sign.py keygen --out-pub "$EXTRA/etc/hpm/test-trusted.pub" \
    --out-sec "$WORK/test.sec" >/dev/null || {
    echo "FAIL: cannot mint a signing key"; exit 1; }
python3 scripts/hpm_sign.py sign "$REPO/linux/index.json" "$WORK/test.sec" \
    "$REPO/linux/index.json.sig" || {
    echo "FAIL: cannot sign the local index"; exit 1; }
python3 scripts/hpm_sign.py verify "$REPO/linux/index.json" "$REPO/linux/index.json.sig" \
    "$EXTRA/etc/hpm/test-trusted.pub" >/dev/null 2>&1 || true
say "signed the local channel; the guest gets /etc/hpm/test-trusted.pub"

# =========================================================================
# 3. Serve it.
# =========================================================================
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$REPO" \
    >"$WORK/http.log" 2>&1 &
HTTPD=$!
# Reap what you start -- including on every early exit below.
cleanup() { kill "$HTTPD" 2>/dev/null; wait "$HTTPD" 2>/dev/null; }
trap cleanup EXIT
sleep 1
curl -fsS "http://127.0.0.1:$PORT/linux/index.json" >/dev/null || {
    echo "FAIL: the local channel is not being served"; exit 1; }
say "local channel served at $BASE (pid $HTTPD)"

# =========================================================================
# 4. The two boot scripts.
# =========================================================================
# Both `source /etc/rc.boot.installed` -- the REAL installed rc, verbatim, so
# this is a test OF that file and not of a copy that happens to agree today.
#
# The second one is staged onto the disk BEFORE the first boot and moved into
# place by the first boot, because the disk cannot be rebuilt between the two
# boots without destroying the persistence the reboot exists to prove.
mkdir -p "$EXTRA/etc"

cat > "$WORK/rc.phase1" <<RC
source '/etc/rc.boot.installed'

echo '[iupd] ===== PHASE 1: an installed machine updates itself'
date

# An address the way a real machine gets one. The installed rc sets a static
# address (it has to: it runs before any DHCP client could); this proves the
# client works on the boot that persists, and that hpm then reaches the world.
dhcpc
echo '[iupd] dhcpc status:' \$status
echo '[iupd] address after dhcpc:'
ifconfig

# The negative control. If this prints a file, an 'install' below could be a
# no-op and still look like a success.
echo '[iupd] before-install $BIN:'
ls -l $BIN
echo '[iupd] before-install status:' \$status

# Before hpm, the two things hpm needs, separately -- so a refresh that fails
# says WHICH half failed. "hpm: HTTP fetch failed" on its own does not
# distinguish a name that would not resolve from a TLS session that would not
# carry bytes, and this test spent a boot learning that.
echo '[iupd] probe: resolve 255.one'
host 255.one
echo '[iupd] probe host status:' \$status
# THE COMMAND THE OWNER TYPES, with nothing added to it. Whatever this does is
# the truth about the shipped machine, so it is run first and on its own.
echo '[iupd] refresh from the real repository, no flags'
hpm refresh
echo '[iupd] plain refresh status:' \$status

# And then whatever it takes to actually get the index, so the rest of the
# loop can be measured even when the line above refused.
echo '[iupd] refresh from the real repository, --allow-unsigned'
hpm --allow-unsigned refresh
echo '[iupd] refresh status:' \$status

echo '[iupd] install $PKG'
hpm --allow-unsigned install $PKG
echo '[iupd] install status:' \$status
echo '[iupd] installed list:'
hpm list

echo '[iupd] p1 run the freshly installed binary (same files -> 0):'
echo hello > /tmp/a
echo hello > /tmp/b
diff /tmp/a /tmp/b
echo '[iupd] p1 diff-same status:' \$status
echo world > /tmp/b
echo '[iupd] p1 run it again (different files -> 1, with output):'
diff /tmp/a /tmp/b
echo '[iupd] p1 diff-diff status:' \$status

echo '[iupd] ----- a newer build is published; update against it'
hpm --repo=$BASE --trusted-key=/etc/hpm/test-trusted.pub update
echo '[iupd] update status:' \$status
echo '[iupd] list after update:'
hpm list
echo '[iupd] p1 cksum of $BIN after update:'
cksum < $BIN
echo '[iupd] p1 the stamp the new build carried:'
cat /etc/hamnix-update-stamp
echo '[iupd] p1 stamp status:' \$status
echo '[iupd] p1 run the UPGRADED binary (different files -> 1):'
diff /tmp/a /tmp/b
echo '[iupd] p1 upgraded diff status:' \$status

# DID THE PACKAGE MANAGER TAKE THE MACHINE'S BOOT SCRIPT?
#
# An installed machine boots /etc/rc.boot, and hamnix-init carries one. If a
# package manager can replace the boot script of the machine it is running on,
# that is the thing to find out here and not on somebody's desk.
#
# /etc/rc.boot is the file hamsh IS EXECUTING right now -- pid 1 reads it as
# it goes -- so this only STATS it. Two other forms were tried and both wedged
# the boot dead on this line: rewriting it mid-script (the bytes pid 1 is
# about to read change under it), and opening it as a REDIRECT TARGET while it
# is the running script -- 'cksum < /etc/rc.boot' and 'head -3 < /etc/rc.boot'
# both hang. 'ls -l' is the form that answers. The host knows how many bytes
# this rc has, and etc/rc.boot.linux differs by thousands.
echo '[iupd] p1 stat of /etc/rc.boot after hpm ran:'
ls -l /etc/rc.boot
# AND THE SAME QUESTION ANSWERED IN ONE NUMBER. \`ls -l FILE\` on this line
# prints the file's CONTENTS, not a size, so the arm that looked for a byte
# count in its output could never have matched no matter what hpm did -- it
# reported the fault correctly by accident, and would have gone on reporting
# it after the fix. A digest of the running rc is unambiguous: the host knows
# what it wrote, and only these exact bytes produce this line.
echo '[iupd] p1 md5 of /etc/rc.boot after hpm ran:'
md5sum /etc/rc.boot

# THE DIGEST TOOL ITSELF, ON THIS MACHINE, AGAINST GNU. user/md5sum.ad used
# to drain stdin, ignore its argument and print the MD5 of the empty string as
# a constant -- it would have "verified" any file on the disk, and the line
# above would have been worthless. So the same tool is asked for a file whose
# digest the host computed with GNU md5sum over the bytes it served, and for a
# stream whose content the host minted this run.
echo '[iupd] p1 md5 of the binary the update installed:'
md5sum $BIN
# A STREAM, AND IT IS A PIPE AGAIN. \`cat /etc/hamnix-update-stamp | md5sum\`
# was tried here first and NEVER RETURNED -- the boot died on the host's
# timeout with the banner printed and no digest under it, and every later
# check in this phase failed as collateral. md5sum had answered two file
# operands correctly in the two lines above, so what did not finish was the
# PIPE'S EOF and not the hash, and this gate used \`md5sum < FILE\` instead.
#
# The cause was hamsh's own O_RDWR keeper on the fifo: a writer that never
# closed, so no reader on any pipe in the system could see EOF. Fixed in
# user/linux-fdns.c, with tests/linux/fdns_pipe.sh and
# tests/linux/pipelines.sh measuring it directly. THE PIPE IS BACK HERE
# DELIBERATELY: this line is the cleanest possible proof, because it is the
# exact command that cost the boot.
echo '[iupd] p1 md5 of a stream:'
cat /etc/hamnix-update-stamp | md5sum
# cksum and head with a FILE OPERAND -- both took none until now.
echo '[iupd] p1 cksum with a file operand:'
cksum $BIN
echo '[iupd] p1 head with a file operand:'
head -1 /etc/rc.boot.installed

date
echo '[iupd] PHASE1 DONE'
# THE 30-SECOND IDLE IS GONE, AND ITS ABSENCE IS NOW PART OF THE TEST.
# There used to be a `sleep 30` here, because nothing in the guest could flush
# and stop the machine and the ext4 journal had to be given time to commit
# before the host took the VM away. /dev/reboot is served now
# (user/linux-syscalls.c) and a verb it recognises is sync(2) then reboot(2),
# so the flush is the shutdown's job again. Everything below is written and
# the machine is reset in the same breath; if the sync were not happening,
# phase 2 would come up running the OLD rc and every phase-2 check would say
# so.
echo '[iupd] PHASE1 SETTLED'

# Arm the reboot -- LAST, for the reason above: this replaces the file pid 1
# is executing, and it is only safe once there is nothing left to read from
# it. It is also a plain test that a write to /etc lands on the ext4 root and
# survives: if it does not, phase 2 re-runs phase 1 and the checks say so.
cp /etc/rc.phase2 /etc/rc.boot
echo '[iupd] p1 armed the next boot'

# AN INSTALLED MACHINE RESTARTS ITSELF. The tree ships /bin/reboot, and it is
# the Plan-9 shape: write "reboot" to /dev/reboot. That device is served here
# by user/linux-syscalls.c, and the verb is sync(2) then reboot(2) -- so this
# is both how phase 2 gets started and the flush that makes everything written
# above survive into it. The line below never returns when it works.
echo '[iupd] p1 can this machine restart itself?'
reboot
echo '[iupd] p1 reboot status:' \$status
RC

cat > "$EXTRA/etc/rc.phase2" <<RC
source '/etc/rc.boot.installed'

echo '[iupd] ===== PHASE 2: the same disk, booted again, nothing rebuilt'
date

echo '[iupd] p2 list:'
hpm list
echo '[iupd] p2 list status:' \$status
echo '[iupd] p2 cksum of $BIN:'
cksum < $BIN
echo '[iupd] p2 the stamp:'
cat /etc/hamnix-update-stamp
echo '[iupd] p2 stamp status:' \$status

echo hello > /tmp/a
echo hello > /tmp/b
echo '[iupd] p2 run the upgraded binary (same files -> 0):'
diff /tmp/a /tmp/b
echo '[iupd] p2 diff-same status:' \$status
echo world > /tmp/b
echo '[iupd] p2 run it again (different -> 1):'
diff /tmp/a /tmp/b
echo '[iupd] p2 diff-diff status:' \$status

# WHAT ROOT LEFT FOR EVERYONE ELSE.
# hpm writes /bin, /etc and /var/lib/hpm as root, and caches the index in a
# root-created /tmp/hpm. The person at the desktop is uid 1001. Three separate
# faults in this tree have been of exactly this shape -- a directory, a lock
# file and a socket that existed only because root made them -- so the
# unprivileged half of every one of those paths is asked here.
dhcpc
hpm --repo=$BASE --trusted-key=/etc/hpm/test-trusted.pub refresh
echo '[iupd] p2 root refresh status:' \$status

setuid 1001
echo '[iupd] p2 --- as the session user (uid 1001)'
id
echo '[iupd] u1001 list:'
hpm list
echo '[iupd] u1001 list status:' \$status
echo '[iupd] u1001 run the upgraded binary:'
diff /tmp/a /tmp/b
echo '[iupd] u1001 diff status:' \$status
echo '[iupd] u1001 read the stamp:'
cat /etc/hamnix-update-stamp
echo '[iupd] u1001 stamp status:' \$status
echo '[iupd] u1001 refresh (root already made /tmp/hpm this boot):'
hpm --repo=$BASE --trusted-key=/etc/hpm/test-trusted.pub refresh
echo '[iupd] u1001 refresh status:' \$status
echo '[iupd] u1001 search:'
hpm search hamnix-awk
echo '[iupd] u1001 search status:' \$status
echo '[iupd] u1001 install (must be refused, by name):'
hpm --repo=$BASE --trusted-key=/etc/hpm/test-trusted.pub install hamnix-awk
echo '[iupd] u1001 install status:' \$status
echo '[iupd] u1001 did it write /bin anyway?'
ls -l /bin/awk
echo '[iupd] u1001 /bin/awk status:' \$status

date
echo '[iupd] PHASE2 DONE'
RC

# =========================================================================
# 5. Install a disk.
# =========================================================================
say "building an installed disk (phase-1 rc, phase-2 staged alongside it)"
HAMLINUX_DISK_RC="$WORK/rc.phase1" HAMLINUX_DISK_EXTRA="$EXTRA" \
    scripts/hamlinux_disk.sh "$DISK" 3G >"$WORK/build.log" 2>&1 || {
    echo "FAIL disk build"; tail -20 "$WORK/build.log"; exit 1; }

DISK_SUM_BEFORE="$(md5sum "$DISK" | cut -d' ' -f1)"
RC1_MD5="$(md5sum "$WORK/rc.phase1" | cut -d' ' -f1)"

# =========================================================================
# 6. Boot it. Twice. Nothing is rebuilt in between.
# =========================================================================
boot() {   # boot <logfile> <seconds>
    # STDIN CLOSES EARLY, ON PURPOSE. When the rc script ends, hamsh -- which
    # IS pid 1 -- falls through to reading the console; an open stdin would
    # hold the VM there until the host's timeout fired, and every boot would
    # cost its whole budget. With stdin at EOF pid 1 exits the moment its rc
    # is done, the kernel panics (panic=-1) and -no-reboot makes QEMU exit --
    # so the budget below is a CEILING rather than a duration. Phase 1 does not
    # reach that fallback any more: it ends by asking /dev/reboot to restart
    # the machine, which flushes and resets it properly. The rc used to idle
    # 30 s here instead, waiting on the ext4 journal.
    ( sleep 5 ) | HAMLINUX_DISK="$DISK" \
        timeout "$(($2 + 15))" scripts/hamlinux_vm.sh disk --timeout "$2" \
        >"$1" 2>&1
}
say "boot 1 of 2: install + update, through UEFI (up to ${WAIT1}s)"
boot "$WORK/boot1.log" "$WAIT1"
say "boot 2 of 2: the reboot (up to ${WAIT2}s)"
boot "$WORK/boot2.log" "$WAIT2"

DISK_SUM_AFTER="$(md5sum "$DISK" | cut -d' ' -f1)"

echo
grep -aE '^\[iupd\]|^rc\.boot:' "$WORK/boot1.log" || {
    echo "no phase-1 output; boot log tail:"; tail -30 "$WORK/boot1.log"; }
echo
grep -aE '^\[iupd\]|^rc\.boot:' "$WORK/boot2.log" || {
    echo "no phase-2 output; boot log tail:"; tail -30 "$WORK/boot2.log"; }
echo

# =========================================================================
# 7. The questions.
# =========================================================================
LOG=""
check() {   # check <name> <regex>
    if grep -aqE "$2" "$LOG"; then echo "iupd: PASS $1"
    else echo "iupd: FAIL $1   (no line matching /$2/ in $LOG)"; fail=1; fi
}
nocheck() { # nocheck <name> <regex-that-must-NOT-appear>
    if grep -aqE "$2" "$LOG"; then
        echo "iupd: FAIL $1   (found /$2/ in $LOG)"; fail=1
    else echo "iupd: PASS $1"; fi
}
# THE LINE AFTER THE BANNER IS THE ANSWER. A `status: 0` on its own is not
# one: every failure this tree has paid for was success-shaped -- see the note
# in tests/linux/two_namespaces.sh.
after() {   # after <name> <banner> <regex>
    got="$(grep -aA5 -F "$2" "$LOG" | tail -n +2 | tr -d '\r')"
    if printf '%s\n' "$got" | grep -qE "$3"; then
        echo "iupd: PASS $1  -> '$(printf '%s\n' "$got" | grep -E "$3" | head -1)'"
    else
        echo "iupd: FAIL $1  (nothing matching /$3/ in the 3 lines after '$2'; got: $(printf '%s' "$got" | tr '\n' '|'))"
        fail=1
    fi
}

echo "--- boot 1: an installed machine installs and updates itself"
LOG="$WORK/boot1.log"
check  "the installed root came online"          'rc\.boot: hamnix-linux \(installed\)'
check  "dhcpc took a lease on the installed boot" '\[iupd\] dhcpc status: 0'
after  "dhcpc's address is the DHCP one"         '[iupd] address after dhcpc:' '10\.0\.2\.15'
nocheck "the image did not already ship $BIN"    '\[iupd\] before-install status: 0'
check  "the installed machine resolves 255.one"  '\[iupd\] probe host status: 0'
check  "hpm refresh reached https://255.one/"    'hpm: fetching channel linux from https://255\.one/'
# THE OWNER'S COMMAND, WITH NOTHING ADDED. Reported rather than gated: what
# makes it fail today is that the published repository carries no
# index.json.sig, and publishing one is the repository operator's action, not
# a defect in this tree. It is printed every run so it cannot go unnoticed.
if grep -aq '\[iupd\] plain refresh status: 0' "$LOG"; then
    echo "iupd: PASS  a bare 'hpm refresh' trusts https://255.one/"
else
    echo "iupd: NOTE  a bare 'hpm refresh' REFUSES https://255.one/: $(grep -a 'index.json.sig' "$LOG" | head -1 | tr -d '\r')"
    echo "iupd: NOTE  -> publish <channel>/index.json.sig (scripts/hpm_sign.py) or the machine needs --allow-unsigned"
fi
check  "refresh exited 0 with --allow-unsigned"  '\[iupd\] refresh status: 0'
check  "the real repository answered with packages" 'hpm: refreshed index from https://255\.one/ \([0-9]+ packages'
check  "hpm install exited 0"                    '\[iupd\] install status: 0'
after  "the installed version is the published one" '[iupd] installed list:' "$PKG[^0-9]*1\.0\.[0-9]"
check  "the fresh install RUNS and says 'same'"  '\[iupd\] p1 diff-same status: 0'
check  "the fresh install RUNS and says 'differ'" '\[iupd\] p1 diff-diff status: 1'
check  "hpm update exited 0"                     '\[iupd\] update status: 0'
after  "the version MOVED to $NEWVER"            '[iupd] list after update:' "$PKG[^0-9]*$NEWVER"
after  "the bytes on disk are the bytes published" "[iupd] p1 cksum of" "$EXPECT_CKSUM"
after  "the edit landed: the stamp minted by THIS run" '[iupd] p1 the stamp' "$STAMP"
check  "the UPGRADED binary still runs"          '\[iupd\] p1 upgraded diff status: 1'
# A PACKAGE MUST NOT OWN THE MACHINE'S BOOT SCRIPT, and this is a GATE now.
#
# hamnix-init used to ship etc/rc.boot.linux AS /etc/rc.boot: on the live
# image that is the same bytes twice and invisible, and on an installed
# machine it replaced the boot script of the running system. Simply dropping
# it from the package was measured WORSE -- an upgrade removes the files the
# old version owned, and the machine ended up with no /etc/rc.boot at all.
# user/hpm.ad:_is_machine_owned is the fix: hpm neither overwrites, deletes,
# nor claims that path, and writes it only when it is ABSENT. hamnix-init
# still ships it, as the one-line etc/rc.boot.machine, for the machines whose
# own hpm predates the rule. docs/linux_installed_update.md §2b has all of it.
#
# THE DIGEST IS THE ASSERTION, NOT THE BYTE COUNT. `ls -l FILE` prints the
# file's CONTENTS on this line, so the byte-count form this arm used could
# never have matched -- it named the fault correctly by accident and would
# have gone on naming it after the fix. The host wrote rc.phase1 and knows its
# MD5; nothing else produces that line.
after  "hpm left the machine's own /etc/rc.boot alone" \
       '[iupd] p1 md5 of /etc/rc.boot after hpm ran:' "$RC1_MD5"
nocheck "and it is not the initramfs rc wearing that name" \
        'the bootstrap rc for the Linux line'
# THE TOOL THAT ANSWERS THE QUESTION ABOVE HAS TO BE REAL. It was not:
# user/md5sum.ad ignored its argument and printed the MD5 of the empty string
# as a constant, so it would have "verified" any file in the world.
after  "md5sum agrees with GNU md5sum on a 150 KB file" \
       '[iupd] p1 md5 of the binary the update installed:' "$EXPECT_MD5"
after  "md5sum agrees with GNU md5sum on a stream" \
       '[iupd] p1 md5 of a stream:' "$EXPECT_MD5_STREAM"
after  "cksum takes a FILE operand"  '[iupd] p1 cksum with a file operand:' \
       "$EXPECT_CKSUM"
# The expectation is a phrase from the FILE'S FIRST LINE, not its name: hamsh
# traces each command it runs, so 'rc.boot.installed' matches the echoed
# `head -1 /etc/rc.boot.installed` and would pass on a head that read nothing.
after  "head takes a FILE operand instead of blocking on stdin" \
       '[iupd] p1 head with a file operand:' 'the boot rc for an INSTALLED'
check  "phase 1 reached the end"                 '\[iupd\] PHASE1 DONE'
check  "the write to /etc landed (next boot armed)" '\[iupd\] p1 armed the next boot'
# THE MACHINE RESTARTS ITSELF. This used to be a NOTE rather than a check,
# because /dev/reboot is a Hamnix KERNEL device and nothing on this line served
# it -- `reboot` died on the open and the host had to take the VM away.
# user/linux-syscalls.c serves it now, so it is a real gate.
#
# The KERNEL's line is what is checked, not `reboot status: 0`. A successful
# reboot never returns, so there is no status to read; and with -no-reboot a
# PID-1 panic also makes QEMU exit, so the exit alone cannot tell the two
# apart. `reboot: Restarting system` is the kernel saying it did the thing.
# (The old NOTE greped for the first line matching 'reboot:' and would happily
# have printed the guest's own "reboot: requested reboot" as evidence of
# failure while the kernel was restarting one line below it.)
check  "the installed machine restarted ITSELF"  'reboot: Restarting system'
nocheck "and it was not the old missing-device fault" 'cannot open /dev/reboot'

echo
echo "--- boot 2: the same disk, booted again"
LOG="$WORK/boot2.log"
check  "the machine booted again after the update" 'rc\.boot: hamnix-linux \(installed\)'
check  "it ran the rc phase 1 wrote (the /etc write persisted)" 'PHASE 2: the same disk'
after  "the version survived the reboot"         '[iupd] p2 list:' "$PKG[^0-9]*$NEWVER"
after  "the BYTES survived the reboot"           "[iupd] p2 cksum of" "$EXPECT_CKSUM"
after  "the stamp survived the reboot"           '[iupd] p2 the stamp' "$STAMP"
check  "the upgraded binary runs after a reboot (same -> 0)"  '\[iupd\] p2 diff-same status: 0'
check  "the upgraded binary runs after a reboot (differ -> 1)" '\[iupd\] p2 diff-diff status: 1'
echo
echo "--- boot 2, as the desktop user (uid 1001)"
after  "uid 1001 can list what root installed"   '[iupd] u1001 list:' "$PKG[^0-9]*$NEWVER"
check  "uid 1001 can RUN the upgraded binary"    '\[iupd\] u1001 diff status: 1'
after  "uid 1001 can read the file the update installed into /etc" \
       '[iupd] u1001 read the stamp:' "$STAMP"
check  "uid 1001 can refresh through a root-made /tmp/hpm" '\[iupd\] u1001 refresh status: 0'
check  "uid 1001 can search the index"           '\[iupd\] u1001 search status: 0'
check  "uid 1001 is REFUSED an install, by name" 'hpm: package installation requires hostowner'
nocheck "and nothing landed in /bin from it"     '\[iupd\] u1001 /bin/awk status: 0'
check  "phase 2 reached the end"                 '\[iupd\] PHASE2 DONE'

echo
if [ "$DISK_SUM_BEFORE" = "$DISK_SUM_AFTER" ]; then
    echo "iupd: FAIL the disk image is byte-identical before and after both boots -- nothing persisted at all"
    fail=1
else
    echo "iupd: PASS the disk image changed on disk ($DISK_SUM_BEFORE -> $DISK_SUM_AFTER)"
fi

echo
echo "(logs: $WORK/boot1.log $WORK/boot2.log; channel: $REPO; stamp: $STAMP)"
exit $fail
