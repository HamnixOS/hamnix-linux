#!/usr/bin/env bash
# tests/linux/installed_recover_broken.sh — CAN A MACHINE THAT INSTALLED THE
# BROKEN hamnix-desktop 1.0.10 GET ITS DESKTOP BACK WITH `hpm update`?
#
# WHAT WENT WRONG, AND WHY THE BYTES WERE LEFT ON THE CHANNEL
# ==========================================================
# hamnix-desktop **1.0.10** was published to https://255.one/ as a MIXED BUILD.
# `scripts/hamlinux_packages.py:build_one` reused `build/repo-obj/<cmd>.elf`
# whenever its mtime beat `user/<cmd>.ad`'s and stated nothing else -- not
# `lib/*.ad`, not `user/linux-wsys.c` -- so a `wsysd` compiled at 19:17 was
# packaged beside a `hampanelscene` and a `hamdesktop` compiled at 18:25, while
# the wsys backend all three link had been modified at 19:54. Every name was
# present, every sha256 matched the bytes served, and the desktop mapped
# **no windows at all**.
#
# Those bytes are STILL ON THE CHANNEL, deliberately: they were not swapped
# under the same version number, because a machine that already believes it
# has 1.0.10 would never fetch a silently corrected one. **1.0.11 is the
# recovery**, and it is a new version precisely so that `hpm update` has
# something to see.
#
# THE CLAIM, WHICH HAD NEVER BEEN TESTED
# ======================================
#   A machine that installed the BROKEN 1.0.10 can run `hpm update` and come
#   back to a working desktop.
#
# Everything about that is plausible. NORTH_STAR.md's whole standard is that
# plausible is not measured, so this file measures it on a real UEFI+ext4 disk
# in a VM, from the real published bytes, over the real channel.
#
# HOW THIS DIFFERS FROM tests/linux/installed_update_live.sh
# ==========================================================
# That file asks the neighbouring question -- does work published here ARRIVE
# on an installed machine -- and it builds its "old" machine by reverting one
# line of `user/wsysd.ad` into a locally-built channel. A reconstruction is the
# right instrument there, because the defect it models predates the channel.
#
# Here the broken machine must NOT be reconstructed. The claim is about the
# tarball a real person actually received, so **this gate installs the genuine
# published hamnix-desktop 1.0.10 tarball, byte for byte off 255.one**, with
# its own PKGINFO as the package metadata. The host downloads it, records the
# md5 of the three binaries inside it, and the guest is made to prove it is
# running those exact bytes before anything is asked of the desktop.
#
# NO VERSION IS HARD-CODED AGAINST THE LIVE REPOSITORY
# ====================================================
# Publishing 1.0.8 once broke a test that hard-coded 1.0.8. So:
#   * the CURRENT version is READ from the channel index at run time;
#   * the known-broken published version is the variable BROKENVER
#     (`HAMLINUX_RECOVER_BROKENVER`, default 1.0.10) -- it is an historical
#     fact about what was published, not a claim about what is current;
#   * if the channel has stopped serving BROKENVER's tarballs, or has nothing
#     NEWER than BROKENVER to update to, this gate SAYS SO BY NAME and stops.
#     It never substitutes a locally built package for the published one --
#     that would answer a different question in the same shape, which is the
#     exact failure NORTH_STAR.md names.
#
# THE FAILURE IS ASSERTED FIRST, AND IT IS ALLOWED TO REFUTE THE DIAGNOSIS
# =======================================================================
# Boot 2 clicks the broken desktop with a REAL POINTER before any update. If
# the known-broken published version comes up WORKING in this run, the gate
# goes red on the spot and says the diagnosis is wrong. That is a first-class
# result: it would mean 1.0.10 is not what the handoff says it is, and it must
# not be buried under a green recovery half.
#
# The breakage has two observed shapes across runs, and this file distinguishes
# them rather than collapsing them (`docs`/HANDOFF record both): `windows 0`,
# nothing came up at all; and `windows 2`, the wallpaper and the panel's BOTTOM
# taskbar with the TOP bar -- the one carrying the Applications button --
# simply absent. Either is the breakage. A top bar that exists and does not
# move under a real click is also the breakage. A top bar that GROWS is not.
#
# BOTH HALVES ARE DRIVEN BY A REAL POINTER
# ========================================
# QMP `input-send-event` onto the guest's `-device virtio-tablet-pci`. What
# arrives in the guest is a `struct input_event` stream off /dev/input/eventN
# that nothing in the guest can tell from a hand on a mouse. NOTHING here
# writes a wsys ring by hand -- doing that as the host owner is exactly why a
# completely unclickable desktop went unnoticed for the whole port (see
# tests/linux/de_mouse_chrome.sh).
#
# THE THREE BOOTS
# ===============
#   boot 1  the installed root comes up and installs hamnix-desktop at
#           BROKENVER from a local channel whose tarballs are the GENUINE
#           published bytes. The machine is now, exactly, a machine that took
#           the bad update.
#   boot 2  the broken desktop comes up. A REAL CLICK -> it must be broken.
#           THEN: `hpm update`, no flags, against https://255.one/.
#   boot 3  the same disk, nothing rebuilt. THE SAME CLICK -> the Applications
#           menu must open.
#
# DELIBERATELY BREAKING IT
#   HAMLINUX_RECOVER_NOUPDATE=1   phase 2 does everything EXCEPT `hpm update`.
# The machine reboots still broken and boot 3 must go red. The arm exists so
# that "it went green" is a statement about the update rather than about this
# file running to the end.
#
# Usage: tests/linux/installed_recover_broken.sh [b1s] [b2s] [b3s]
#   HAMLINUX_RECOVER_REUSE=1     reuse the staged image root + fetched channel
#   HAMLINUX_RECOVER_NOUPDATE=1  the negative control above
#   HAMLINUX_RECOVER_BROKENVER=  the known-broken published version (1.0.10)
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

export HAMLINUX_VNC="${HAMLINUX_VNC:-none}"
export HAMLINUX_DISTRO_RO="${HAMLINUX_DISTRO_RO:-1}"
# /tmp on the dev box is a 16 GB tmpfs -- the owner's RAM. QEMU's overlays and
# every scratch file below stay on real disk.
export TMPDIR="${TMPDIR:-$PROJ_ROOT/build/tmp}"
mkdir -p "$TMPDIR"

WAIT1="${1:-540}"
WAIT2="${2:-540}"
WAIT3="${3:-420}"
PKG=hamnix-desktop
# The three binaries the mixed build got wrong: the compositor and the two
# programs a person actually points at. All three are asserted by digest.
BIN=/bin/wsysd
BIN2=/bin/hampanelscene
BIN3=/bin/hamdesktop
CHANNEL_URL="${HAMLINUX_RECOVER_URL:-https://255.one/linux/index.json}"
LIVE_BASE="$(dirname "$CHANNEL_URL")/"
BROKENVER="${HAMLINUX_RECOVER_BROKENVER:-1.0.10}"

WORK="${HAMLINUX_RECOVER_WORK:-build/recover}"; mkdir -p "$WORK"
IMG=build/image
DISK="$IMG/recover.img"
REPO="$WORK/repo"
EXTRA="$WORK/extra"
QMP="$PROJ_ROOT/$WORK/qmp.sock"
NOUPD="${HAMLINUX_RECOVER_NOUPDATE:-0}"

fail=0
say() { echo "[rcvr] $*"; }
[ -f "$IMG/distro.ext4" ] || { echo "no distro image; run scripts/hamlinux_distro.sh" >&2; exit 1; }
command -v python3 >/dev/null || { echo "need python3" >&2; exit 1; }

# =========================================================================
# 1. WHAT IS THE LIVE CHANNEL AT, RIGHT NOW?
# =========================================================================
# Asked, never assumed. A repository that cannot be reached is a failure of the
# run and not something to fall back from.
say "asking $CHANNEL_URL what it serves"
curl -fsS --max-time 60 "$CHANNEL_URL" -o "$WORK/live-index.json" || {
    echo "FAIL: cannot reach $CHANNEL_URL -- this gate has nothing to measure without it" >&2
    exit 1; }
LIVEVER="$(PKG="$PKG" python3 - "$WORK/live-index.json" <<'PY'
import json, os, sys
d = json.load(open(sys.argv[1]))
for r in d["packages"]:
    if r["name"] == os.environ["PKG"]:
        print(r["version"]); break
PY
)"
[ -n "$LIVEVER" ] || { echo "FAIL: the channel carries no $PKG at all" >&2; exit 1; }

# THE ONE ORDERING THIS GATE NEEDS: the channel must offer something NEWER
# than the known-broken version, or there is no recovery to measure. Compared
# with hpm's own rule (docs/packages.md: field by numeric field).
BROKENVER="$BROKENVER" LIVEVER="$LIVEVER" python3 <<'PY' || {
import os, sys
def key(v): return [int(x) for x in v.split(".")]
sys.exit(0 if key(os.environ["BROKENVER"]) < key(os.environ["LIVEVER"]) else 1)
PY
    echo "FAIL: the channel serves $PKG $LIVEVER, which is not newer than the" >&2
    echo "      known-broken published version $BROKENVER. There is no recovery" >&2
    echo "      for this gate to measure. Nothing is measured rather than" >&2
    echo "      measuring the wrong thing." >&2
    exit 1; }
say "the live channel serves $PKG $LIVEVER; the known-broken published version is $BROKENVER"

# =========================================================================
# 2. THE GENUINE PUBLISHED TARBALLS FOR THE BROKEN VERSION.
# =========================================================================
# Not rebuilt, not reconstructed, not patched: fetched from the same URLs a
# person's machine would have fetched them from, over the same TLS. If they are
# gone the gate says so by name -- it will not put a locally built package in
# their place and call the answer the same.
#
# hamnix-desktop's own dependencies come along at the same version, because
# `hpm install` resolves them out of the channel it is pointed at and this
# channel is a mirror of the day 1.0.10 shipped.
BROKEN_PKGS="$PKG hamnix-init hamnix-hamsh"
mkdir -p "$REPO/linux/packages"
for p in $BROKEN_PKGS; do
    tb="$REPO/linux/packages/$p-$BROKENVER.tar.gz"
    if [ "${HAMLINUX_RECOVER_REUSE:-0}" = 1 ] && [ -s "$tb" ]; then
        say "reusing the already-fetched $p-$BROKENVER.tar.gz"
        continue
    fi
    url="${LIVE_BASE}packages/$p-$BROKENVER.tar.gz"
    say "fetching the published $url"
    curl -fsS --max-time 300 "$url" -o "$tb" || {
        echo "FAIL: $url is no longer served." >&2
        echo "      This gate measures a recovery FROM the exact bytes that were" >&2
        echo "      published as $BROKENVER. It cannot substitute anything for" >&2
        echo "      them, so it stops here rather than measuring a lookalike." >&2
        echo "      If $BROKENVER has been withdrawn on purpose, this gate has" >&2
        echo "      outlived the thing it was written for and should be retired." >&2
        exit 1; }
done

# The digests of the three binaries the mixed build got wrong, on both sides.
# These are what the guest is held to: no index field can satisfy them.
rm -rf "$WORK/unpack"; mkdir -p "$WORK/unpack"
tar xzf "$REPO/linux/packages/$PKG-$BROKENVER.tar.gz" -C "$WORK/unpack" || {
    echo "FAIL: the published $BROKENVER tarball did not unpack" >&2; exit 1; }
BROKEN_ROOT="$WORK/unpack/$PKG-$BROKENVER/files"
for b in "$BIN" "$BIN2" "$BIN3"; do
    [ -f "$BROKEN_ROOT$b" ] || {
        echo "FAIL: the published $PKG $BROKENVER carries no $b" >&2; exit 1; }
done
BROKEN_MD5="$(md5sum "$BROKEN_ROOT$BIN"  | cut -d' ' -f1)"
BROKEN_MD5_2="$(md5sum "$BROKEN_ROOT$BIN2" | cut -d' ' -f1)"
BROKEN_MD5_3="$(md5sum "$BROKEN_ROOT$BIN3" | cut -d' ' -f1)"
say "the published $BROKENVER carries $BIN md5 $BROKEN_MD5, $BIN2 md5 $BROKEN_MD5_2, $BIN3 md5 $BROKEN_MD5_3"

# And the bytes the live channel is serving now, fetched by the host too, so
# "the update landed" can be said about CONTENT.
LIVE_URL="$(PKG="$PKG" python3 - "$WORK/live-index.json" <<'PY'
import json, os, sys
d = json.load(open(sys.argv[1]))
base = d.get("url", "")
for r in d["packages"]:
    if r["name"] == os.environ["PKG"]:
        u = r["url"]
        print(u if u.startswith("http") else base.rstrip("/") + "/" + u)
        break
PY
)"
say "fetching $LIVE_URL"
curl -fsS --max-time 300 "$LIVE_URL" -o "$WORK/live-pkg.tar.gz" || {
    echo "FAIL: cannot download the live $PKG tarball" >&2; exit 1; }
rm -rf "$WORK/liveunpack"; mkdir -p "$WORK/liveunpack"
tar xzf "$WORK/live-pkg.tar.gz" -C "$WORK/liveunpack" || {
    echo "FAIL: the live tarball did not unpack" >&2; exit 1; }
LIVE_ROOT="$WORK/liveunpack/$PKG-$LIVEVER/files"
LIVE_MD5="$(md5sum "$LIVE_ROOT$BIN"  2>/dev/null | cut -d' ' -f1)"
LIVE_MD5_2="$(md5sum "$LIVE_ROOT$BIN2" 2>/dev/null | cut -d' ' -f1)"
LIVE_MD5_3="$(md5sum "$LIVE_ROOT$BIN3" 2>/dev/null | cut -d' ' -f1)"
[ -n "$LIVE_MD5" ] && [ -n "$LIVE_MD5_2" ] && [ -n "$LIVE_MD5_3" ] || {
    echo "FAIL: the live $PKG $LIVEVER does not carry all of $BIN $BIN2 $BIN3" >&2; exit 1; }
say "the live $LIVEVER carries $BIN md5 $LIVE_MD5, $BIN2 md5 $LIVE_MD5_2, $BIN3 md5 $LIVE_MD5_3"

# A RECOVERY THAT SHIPS THE SAME BYTES IS NOT A RECOVERY. If the published
# fix is byte-identical to the break for all three, there is nothing for
# `hpm update` to deliver and this gate would report a no-op as a repair.
if [ "$LIVE_MD5" = "$BROKEN_MD5" ] && [ "$LIVE_MD5_2" = "$BROKEN_MD5_2" ] \
   && [ "$LIVE_MD5_3" = "$BROKEN_MD5_3" ]; then
    echo "FAIL: $LIVEVER ships byte-identical $BIN, $BIN2 and $BIN3 to the broken" >&2
    echo "      $BROKENVER. There is no repair in the channel to measure." >&2
    exit 1
fi

# =========================================================================
# 3. The image root.
# =========================================================================
if [ "${HAMLINUX_RECOVER_REUSE:-0}" = 1 ] && [ -f "$IMG/initramfs.cpio.gz" ]; then
    say "reusing the staged image root (HAMLINUX_RECOVER_REUSE=1)"
else
    say "staging the image root"
    HAMLINUX_JOBS="${HAMLINUX_JOBS:-4}" scripts/hamlinux_image.sh \
        >"$WORK/image.log" 2>&1 || {
        echo "FAIL image build"; tail -20 "$WORK/image.log"; exit 1; }
fi

# =========================================================================
# 4. A LOCAL MIRROR OF THE DAY 1.0.10 SHIPPED.
# =========================================================================
# The tarballs in it are the published ones, untouched. Only the INDEX is
# rebuilt, and only because the live index no longer describes $BROKENVER --
# the channel keeps one index and it has moved on. Every field in it comes
# from the tarball's own PKGINFO (the published metadata) or from the bytes
# themselves (size, sha256); nothing is invented here.
#
# The mirror is served over http from the host and SIGNED with a key staged in
# the guest's /etc/hpm, so the install the machine's history is made of takes
# the same verified path a real one would. No --allow-unsigned anywhere.
PORT="$(python3 - <<'PY'
import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()
PY
)"
BASE="http://10.0.2.2:$PORT/"
say "writing the $BROKENVER index over the published tarballs, pointed at $BASE"
REPO="$REPO" BASE="$BASE" BROKENVER="$BROKENVER" PKGS="$BROKEN_PKGS" \
LIVEIDX="$WORK/live-index.json" python3 <<'PY' || {
import hashlib, json, os, tarfile

repo, base, ver = os.environ["REPO"], os.environ["BASE"], os.environ["BROKENVER"]
live = json.load(open(os.environ["LIVEIDX"]))

def pkginfo(tarpath, name):
    top = "%s-%s" % (name, ver)
    with tarfile.open(tarpath, "r:gz") as tf:
        raw = tf.extractfile(top + "/PKGINFO").read().decode()
    out = {}
    for line in raw.splitlines():
        if ":" in line:
            k, v = line.split(":", 1)
            out[k.strip()] = v.strip()
    return out

records = []
for name in os.environ["PKGS"].split():
    tarpath = os.path.join(repo, "linux", "packages", "%s-%s.tar.gz" % (name, ver))
    blob = open(tarpath, "rb").read()
    info = pkginfo(tarpath, name)
    assert info["version"] == ver, "%s PKGINFO says %s" % (name, info["version"])
    deps = [d.strip() for d in info.get("depends", "").split(",") if d.strip()]
    records.append({
        "name": name,
        "version": ver,
        "arch": info.get("arch", "x86_64"),
        "url": "packages/%s-%s.tar.gz" % (name, ver),
        "sha256": hashlib.sha256(blob).hexdigest(),
        "size": len(blob),
        "description": info.get("description", ""),
        "depends": deps,
        "target": info.get("target", "#hamnix-system"),
        "channel": "linux",
    })

# A dangling dependency would make the install fail for a reason that has
# nothing to do with what is being measured. Refuse rather than discover it
# in a boot log twenty minutes from now.
have = {r["name"] for r in records}
for r in records:
    for d in r["depends"]:
        dn = d.split(">")[0].split("=")[0].split("<")[0].strip()
        assert dn in have, "%s depends on %s, which this mirror does not carry" % (r["name"], dn)

index = {k: v for k, v in live.items() if k != "packages"}
index["url"] = base
index["description"] = ("a local mirror of the hamnix-linux channel as it stood at %s"
                        " -- the published tarballs, byte for byte" % ver)
index["packages"] = records
with open(os.path.join(repo, "linux", "index.json"), "w") as fh:
    json.dump(index, fh, indent=2)
    fh.write("\n")
PY
    echo "FAIL: could not write the $BROKENVER mirror index"; exit 1; }

mkdir -p "$EXTRA/etc/hpm"
python3 scripts/hpm_sign.py keygen --out-pub "$EXTRA/etc/hpm/test-trusted.pub" \
    --out-sec "$WORK/test.sec" >/dev/null || {
    echo "FAIL: cannot mint a signing key"; exit 1; }
python3 scripts/hpm_sign.py sign "$REPO/linux/index.json" "$WORK/test.sec" \
    "$REPO/linux/index.json.sig" || {
    echo "FAIL: cannot sign the mirror index"; exit 1; }

python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$REPO" \
    >"$WORK/http.log" 2>&1 &
HTTPD=$!
cleanup() {
    kill "$HTTPD" 2>/dev/null; wait "$HTTPD" 2>/dev/null
    [ -n "${VM:-}" ] && kill "$VM" 2>/dev/null
}
trap cleanup EXIT
sleep 1
curl -fsS "http://127.0.0.1:$PORT/linux/index.json" >/dev/null || {
    echo "FAIL: the mirror is not being served"; exit 1; }
say "the $BROKENVER mirror is served at $BASE (pid $HTTPD)"

# =========================================================================
# 5. The three boot scripts.
# =========================================================================
# Every one of them `source /etc/rc.boot.installed` -- the REAL installed rc,
# which is also what starts the desktop (it ends by sourcing /etc/rc.d/rc.5).
mkdir -p "$EXTRA/etc"

# The block the host reads window geometry out of. `cat /dev/wsys/<wid>/ctl`
# prints "<wid> <x> <y> <w> <h> <z> ...", the window's own account of itself.
# A window id that does not exist makes `cat` say so, which is harmless and is
# left in rather than guessed away -- and on the broken boot most of them will
# not exist, which is the finding.
_wins() {   # _wins <phase> <tag>
    cat <<W
echo '[rcvr] $1 WINS-$2'
cat /dev/wsys/2/ctl
cat /dev/wsys/3/ctl
cat /dev/wsys/4/ctl
cat /dev/wsys/5/ctl
echo '[rcvr] $1 WINS-END'
echo '[rcvr] $1 STATE-$2:'
cat /dev/wsys/wsysd/state
W
}

cat > "$WORK/rc.phase1" <<RC
source '/etc/rc.boot.installed'

echo '[rcvr] ===== PHASE 1: this machine takes the bad update'
date
dhcpc
echo '[rcvr] p1 dhcpc status:' \$status

# The install that gives this machine its history: the GENUINE published
# $BROKENVER tarballs, off a signed mirror, with the key in /etc/hpm.
# \`hpm install\` reads a CACHED index, so the refresh is not decoration.
echo '[rcvr] p1 refresh the $BROKENVER mirror'
hpm --repo=$BASE --trusted-key=/etc/hpm/test-trusted.pub refresh
echo '[rcvr] p1 refresh status:' \$status
echo '[rcvr] p1 install $PKG at $BROKENVER'
hpm --repo=$BASE --trusted-key=/etc/hpm/test-trusted.pub install $PKG
echo '[rcvr] p1 install status:' \$status
echo '[rcvr] p1 list:'
hpm list
echo '[rcvr] p1 md5 of the three binaries the mixed build got wrong:'
md5sum $BIN
md5sum $BIN2
md5sum $BIN3

echo '[rcvr] PHASE1 DONE'
cp /etc/rc.phase2 /etc/rc.boot
echo '[rcvr] p1 armed the next boot'
reboot
RC

{
cat <<RC
source '/etc/rc.boot.installed'

echo '[rcvr] ===== PHASE 2: the BROKEN published desktop, under a real mouse,'
echo '[rcvr]               and then hpm update'
date
dhcpc
echo '[rcvr] p2 dhcpc status:' \$status

# The desktop is already coming up: rc.boot.installed ends by sourcing
# /etc/rc.d/rc.5. Give it the time a desktop takes.
sleep 14
RC
_wins p2 BEFORE
cat <<RC
echo '[rcvr] p2 md5 of the three binaries before any update:'
md5sum $BIN
md5sum $BIN2
md5sum $BIN3

# THE HOST NOW CLICKS. A real pointer, on the guest's virtio-tablet, at the
# Applications button. Nothing in this guest knows it is coming.
echo '[rcvr] p2 READY-FOR-CLICK'
sleep 30
RC
_wins p2 AFTER
} > "$WORK/rc.phase2"

if [ "$NOUPD" = 1 ]; then
cat >> "$WORK/rc.phase2" <<RC

# HAMLINUX_RECOVER_NOUPDATE=1: the update is DELIBERATELY NOT RUN, so whatever
# boot 3 says is a statement about the update and not about the machinery.
echo '[rcvr] p2 THE UPDATE WAS DELIBERATELY SKIPPED (HAMLINUX_RECOVER_NOUPDATE=1)'
RC
else
cat >> "$WORK/rc.phase2" <<RC

# THE COMMAND THE OWNER TYPES WHEN THEIR DESKTOP IS BROKEN, with nothing added
# to it, against the real repository. No --repo, no --allow-unsigned, no key
# staged by this test: hpm's own default channel and the trusted key the IMAGE
# ships.
echo '[rcvr] p2 ----- hpm refresh (no flags, the real repository)'
hpm refresh
echo '[rcvr] p2 refresh status:' \$status
echo '[rcvr] p2 ----- hpm update (no flags, the real repository)'
hpm update
echo '[rcvr] p2 update status:' \$status
echo '[rcvr] p2 list after update:'
hpm list
echo '[rcvr] p2 md5 of the three binaries after update:'
md5sum $BIN
md5sum $BIN2
md5sum $BIN3
RC
fi

cat >> "$WORK/rc.phase2" <<RC

# A PACKAGE MUST NOT OWN THE MACHINE'S BOOT SCRIPT. This is the file hamsh is
# executing right now.
echo '[rcvr] p2 md5 of /etc/rc.boot after hpm ran:'
md5sum /etc/rc.boot

date
echo '[rcvr] PHASE2 DONE'
cp /etc/rc.phase3 /etc/rc.boot
echo '[rcvr] p2 armed the next boot'
reboot
RC

{
cat <<'RC'
source '/etc/rc.boot.installed'

echo '[rcvr] ===== PHASE 3: the same disk, nothing rebuilt. Click it again.'
date
sleep 14
RC
_wins p3 BEFORE
cat <<RC
echo '[rcvr] p3 md5 of the three binaries:'
md5sum $BIN
md5sum $BIN2
md5sum $BIN3
echo '[rcvr] p3 list:'
hpm list
echo '[rcvr] p3 READY-FOR-CLICK'
sleep 30
RC
_wins p3 AFTER
cat <<'RC'
date
echo '[rcvr] PHASE3 DONE'
# END THE MACHINE rather than leaving pid 1 on a prompt for the rest of the
# budget -- four minutes of a machine somebody else is using, per run.
reboot
RC
} > "$WORK/rc.phase3"

cp "$WORK/rc.phase2" "$EXTRA/etc/rc.phase2"
cp "$WORK/rc.phase3" "$EXTRA/etc/rc.phase3"
# The digest of the rc that is RUNNING when hpm runs, which is phase 2's.
RC2_MD5="$(md5sum "$WORK/rc.phase2" | cut -d' ' -f1)"

# =========================================================================
# 6. Install a disk.
# =========================================================================
say "building the installed disk"
HAMLINUX_DISK_RC="$WORK/rc.phase1" HAMLINUX_DISK_EXTRA="$EXTRA" \
    scripts/hamlinux_disk.sh "$DISK" 3G >"$WORK/build.log" 2>&1 || {
    echo "FAIL disk build"; tail -20 "$WORK/build.log"; exit 1; }
DISK_SUM_BEFORE="$(md5sum "$DISK" | cut -d' ' -f1)"

# =========================================================================
# 7. Boot it three times, and put a hand on the mouse twice.
# =========================================================================
APPBTN_X=40; APPBTN_Y=13
SCREEN_W=1280; SCREEN_H=800     # only ever used as the fallback below

boot() {   # boot <logfile> <seconds> <click:0|1>
    local log="$1" secs="$2" doclick="$3"
    rm -f "$QMP"
    ( sleep 5 ) | HAMLINUX_DISK="$DISK" \
        timeout "$((secs + 25))" scripts/hamlinux_vm.sh disk --timeout "$secs" \
        -qmp "unix:$QMP,server=on,wait=off" >"$log" 2>&1 &
    VM=$!
    if [ "$doclick" = 1 ]; then
        local i=0
        while [ "$i" -lt "$((secs * 2))" ]; do
            grep -aq 'READY-FOR-CLICK' "$log" && break
            kill -0 "$VM" 2>/dev/null || break
            sleep 0.5; i=$((i + 1))
        done
        if grep -aq 'READY-FOR-CLICK' "$log"; then
            # The screen's size comes from the guest: the backdrop window
            # (z -1) is the display. QMP's absolute axes are a 0..32767 range
            # across it, the same normalisation wsysd's pump_input undoes.
            #
            # AND IT FALLS BACK to the size an earlier boot reported, because
            # a boot with NO WINDOWS AT ALL has no backdrop to read -- and on
            # this gate that is the boot where the click matters most. Without
            # the fallback the click is skipped and the run reports "nothing
            # was clicked", a true sentence about the test and a false one
            # about the machine.
            local back sw sh
            back="$(grep -a -A1 'WINS-BEFORE' "$log" | tail -1 | tr -d '\r')"
            set -- $back
            sw="${4:-}"; sh="${5:-}"
            case "$sw" in ''|*[!0-9]*) sw=0 ;; esac
            case "$sh" in ''|*[!0-9]*) sh=0 ;; esac
            if [ "$sw" -gt 0 ] && [ "$sh" -gt 0 ]; then
                SCREEN_W="$sw"; SCREEN_H="$sh"
            else
                sw="$SCREEN_W"; sh="$SCREEN_H"
                echo "[rcvr] this boot printed no window to read the screen size from" \
                     "('$back') -- clicking at the ${sw}x${sh} an earlier boot reported"
            fi
            sleep 3
            python3 tests/linux/qmp_click.py "$QMP" "$sw" "$sh" \
                "$APPBTN_X" "$APPBTN_Y" >>"$log.click" 2>&1 \
                || echo "[rcvr] the QMP click itself failed; see $log.click"
        fi
    fi
    wait "$VM" 2>/dev/null
    VM=""
}

say "boot 1 of 3: the machine takes the bad update (up to ${WAIT1}s)"
boot "$WORK/boot1.log" "$WAIT1" 0
say "boot 2 of 3: the broken desktop under a real mouse, then hpm update (up to ${WAIT2}s)"
boot "$WORK/boot2.log" "$WAIT2" 1
say "boot 3 of 3: the same disk, clicked again (up to ${WAIT3}s)"
boot "$WORK/boot3.log" "$WAIT3" 1
DISK_SUM_AFTER="$(md5sum "$DISK" | cut -d' ' -f1)"

for n in 1 2 3; do
    echo
    echo "--------- boot $n transcript"
    grep -aE '^\[rcvr\]|^rc\.boot:|^hpm:|^[0-9]+ [0-9]+ [0-9]+ [0-9]+ |^focus [0-9]|^[0-9a-f]{32}  ' \
        "$WORK/boot$n.log" | tr -d '\r' || tail -20 "$WORK/boot$n.log"
done
echo

# =========================================================================
# 8. The questions.
# =========================================================================
LOG=""
check() { if grep -aqE "$2" "$LOG"; then echo "rcvr: PASS $1"
          else echo "rcvr: FAIL $1   (no line matching /$2/ in $LOG)"; fail=1; fi; }
after() {   # after <name> <banner> <regex>
    got="$(grep -aA5 -F "$2" "$LOG" | tail -n +2 | tr -d '\r')"
    if printf '%s\n' "$got" | grep -qE "$3"; then
        echo "rcvr: PASS $1  -> '$(printf '%s\n' "$got" | grep -E "$3" | head -1)'"
    else
        echo "rcvr: FAIL $1  (nothing matching /$3/ after '$2'; got: $(printf '%s' "$got" | tr '\n' '|'))"
        fail=1
    fi
}
# THE TOP PANEL'S HEIGHT, out of the guest's own ctl lines. The bar is the
# window at y=0 with z=100 -- the backdrop is z=-1 and the taskbar sits at the
# bottom of the screen -- so no window id is guessed anywhere in this file.
barh() {   # barh <log> <marker>
    awk -v m="$2" 'index($0, m) {inb=1; next}
                   inb && index($0, "WINS-END") {exit}
                   inb && NF >= 6 && $3 == 0 && $6 == 100 {print $5; exit}' \
        "$1" | tr -d '\r'
}
statefield() {   # statefield <log> <marker> <field>
    grep -aA1 -F "$2" "$1" | tail -1 | tr -d '\r' |
        awk -v f="$3" '{for (i = 1; i < NF; i++) if ($i == f) print $(i+1)}'
}
winlist() {   # winlist <log> <marker>
    awk -v m="$2" 'index($0, m) {inb = 1; next}
                   inb && index($0, "WINS-END") {exit}
                   inb && NF >= 6 && $1 ~ /^[0-9]+$/ {printf "(%s) ", $0}' "$1" | tr -d '\r'
}
# DID THE MOUSE ARRIVE? Two witnesses, because one of them cannot speak in the
# case that matters most here. `pointer` counts events wsysd ROUTED TO A
# WINDOW, so on a boot with zero windows it stays 0 no matter how hard the
# mouse is moved. `curframes` counts the cursor-only frames the compositor
# drew -- the pointer MOVING -- and needs no window at all.
mouse_arrived() {   # mouse_arrived <log> <before-marker> <after-marker> <label>
    local pb pa cb ca
    pb="$(statefield "$1" "$2" pointer)";    pa="$(statefield "$1" "$3" pointer)"
    cb="$(statefield "$1" "$2" curframes)";  ca="$(statefield "$1" "$3" curframes)"
    if [ -n "$pb" ] && [ -n "$pa" ] && [ "$pa" -gt "$pb" ]; then
        echo "rcvr: PASS the real pointer reached $4 (it routed $pb -> $pa pointer events to a window)"
    elif [ -n "$cb" ] && [ -n "$ca" ] && [ "$ca" -gt "$cb" ]; then
        echo "rcvr: PASS the real pointer reached $4 (cursor-only frames $cb -> $ca; it routed none to a window, which is what zero windows means)"
    else
        echo "rcvr: FAIL nothing was clicked at $4: pointer '$pb'->'$pa', curframes '$cb'->'$ca'"; fail=1
    fi
}

echo "--- boot 1: the machine takes the bad update"
LOG="$WORK/boot1.log"
check "the installed root came online"        'rc\.boot: hamnix-linux \(installed\)'
check "dhcpc took a lease"                    '\[rcvr\] p1 dhcpc status: 0'
check "the $BROKENVER mirror refreshed"       '\[rcvr\] p1 refresh status: 0'
check "hpm verified the published tarball it was sent" 'hpm: SHA-256 verified'
check "the install of the broken version exited 0" '\[rcvr\] p1 install status: 0'
after "and it recorded $PKG at $BROKENVER"    '[rcvr] p1 list:' "$PKG[^0-9]*$BROKENVER"
# THE BYTES ON THE DISK ARE THE PUBLISHED BROKEN ONES. All three, because the
# mixed build got all three wrong and a gate that checked only the compositor
# would have called 1.0.10 fine -- the published wsysd IS fine.
after "the compositor on disk is the PUBLISHED BROKEN one" \
      '[rcvr] p1 md5 of the three' "$BROKEN_MD5"
after "the panel on disk is the PUBLISHED BROKEN one" \
      '[rcvr] p1 md5 of the three' "$BROKEN_MD5_2"
after "the desktop on disk is the PUBLISHED BROKEN one" \
      '[rcvr] p1 md5 of the three' "$BROKEN_MD5_3"
check "the machine restarted itself"          'reboot: Restarting system'

echo
echo "--- boot 2: IS IT REALLY BROKEN? (the half that is allowed to refute the diagnosis)"
LOG="$WORK/boot2.log"
check "the machine booted into the desktop rc" '\[rcvr\] p2 WINS-BEFORE'
after "and it is still running the published broken bytes" \
      '[rcvr] p2 md5 of the three binaries before' "$BROKEN_MD5_2"
B2WINS="$(statefield "$LOG" '[rcvr] p2 STATE-BEFORE:' windows)"
B2LIST="$(winlist "$LOG" '[rcvr] p2 WINS-BEFORE')"
B2BEFORE="$(barh "$LOG" '[rcvr] p2 WINS-BEFORE')"
B2AFTER="$(barh "$LOG" '[rcvr] p2 WINS-AFTER')"
echo "rcvr: INFO the broken desktop reports windows=${B2WINS:-?}; windows present: [${B2LIST:-none}]"
echo "rcvr: INFO the top panel is ${B2BEFORE:-absent} px before the click and ${B2AFTER:-absent} px after it"
# THE CLICK REACHED THE COMPOSITOR. Without this the verdict below could be
# satisfied by a mouse that was never delivered.
mouse_arrived "$LOG" '[rcvr] p2 STATE-BEFORE:' '[rcvr] p2 STATE-AFTER:' \
              "the BROKEN desktop"
BROKE_REPRODUCED=0
if [ -z "$B2BEFORE" ]; then
    echo "rcvr: PASS THE PUBLISHED $BROKENVER IS BROKEN ON THIS MACHINE: the compositor is running with ${B2WINS:-?} windows and NONE of them is the top bar (a window at y=0, z=100), so there is no Applications button to click. Windows present: [${B2LIST:-none}]"
    BROKE_REPRODUCED=1
elif [ "${B2AFTER:-0}" = "$B2BEFORE" ]; then
    echo "rcvr: PASS THE PUBLISHED $BROKENVER IS BROKEN ON THIS MACHINE: a top bar exists but a real click on the Applications button did not move it (panel still $B2AFTER px)"
    BROKE_REPRODUCED=1
else
    echo "rcvr: FAIL THE KNOWN-BROKEN PUBLISHED $BROKENVER CAME UP WORKING IN THIS RUN: a real click grew the panel window $B2BEFORE -> $B2AFTER px, which is a desktop that works. This gate's premise -- that $BROKENVER leaves a machine without a desktop -- is not what this machine did, and the recovery half below would prove nothing on top of it. THE DIAGNOSIS IS WRONG, OR THE BYTES ON THE CHANNEL ARE NOT THE BYTES THAT WERE PUBLISHED. That is the finding; nothing is worked around."
    fail=1
fi

if [ "$NOUPD" = 1 ]; then
    echo "rcvr: NOTE HAMLINUX_RECOVER_NOUPDATE=1 -- the update was deliberately not run"
    check "and the run says so out loud" '\[rcvr\] p2 THE UPDATE WAS DELIBERATELY SKIPPED'
else
    echo
    echo "--- boot 2, continued: hpm update, no flags, against $LIVE_BASE"
    check "a bare 'hpm refresh' TRUSTS the real repository" '\[rcvr\] p2 refresh status: 0'
    check "and it was the real repository"          "hpm: (fetching channel|refreshed index from) .*255\.one"
    check "a bare 'hpm update' exited 0"            '\[rcvr\] p2 update status: 0'
    check "hpm named the upgrade $BROKENVER -> $LIVEVER" \
          "hpm: upgrading $PKG $BROKENVER -> $LIVEVER"
    check "hpm refused to take the machine's boot script" \
          "hpm: keeping this machine's own /etc/rc\.boot"
    after "the version moved to the live one"       '[rcvr] p2 list after update:' \
          "$PKG[^0-9]*$LIVEVER"
    # THE BYTES, WHICH NO INDEX FIELD CAN SATISFY. All three.
    after "and $BIN on the disk is now the byte-for-byte published $LIVEVER" \
          '[rcvr] p2 md5 of the three binaries after update:' "$LIVE_MD5"
    after "and $BIN2 is too (this is the one the mixed build got wrong)" \
          '[rcvr] p2 md5 of the three binaries after update:' "$LIVE_MD5_2"
    after "and $BIN3 is too" \
          '[rcvr] p2 md5 of the three binaries after update:' "$LIVE_MD5_3"
fi
after "hpm left the machine's own /etc/rc.boot alone" \
      '[rcvr] p2 md5 of /etc/rc.boot after hpm ran:' "$RC2_MD5"
check "phase 2 reached the end"                 '\[rcvr\] PHASE2 DONE'
check "the machine restarted itself again"      'reboot: Restarting system'

echo
echo "--- boot 3: DID THE MACHINE COME BACK? (the same disk, clicked again)"
LOG="$WORK/boot3.log"
check "the machine booted again"                'rc\.boot: hamnix-linux \(installed\)'
check "it ran the rc phase 2 wrote"             'PHASE 3: the same disk'
if [ "$NOUPD" != 1 ]; then
    after "the update survived the reboot (version)" '[rcvr] p3 list:' "$PKG[^0-9]*$LIVEVER"
    after "the update survived the reboot (BYTES)"   '[rcvr] p3 md5 of the three' "$LIVE_MD5_2"
fi
B3WINS="$(statefield "$LOG" '[rcvr] p3 STATE-BEFORE:' windows)"
B3LIST="$(winlist "$LOG" '[rcvr] p3 WINS-BEFORE')"
B3BEFORE="$(barh "$LOG" '[rcvr] p3 WINS-BEFORE')"
B3AFTER="$(barh "$LOG" '[rcvr] p3 WINS-AFTER')"
echo "rcvr: INFO the recovered desktop reports windows=${B3WINS:-?}; windows present: [${B3LIST:-none}]"
echo "rcvr: INFO the top panel is ${B3BEFORE:-absent} px before the click and ${B3AFTER:-absent} px after it"
mouse_arrived "$LOG" '[rcvr] p3 STATE-BEFORE:' '[rcvr] p3 STATE-AFTER:' \
              "the RECOVERED desktop"
# ===== THE SENTENCE THIS WHOLE FILE EXISTS FOR =====
# Three outcomes, three different sentences. A gate that collapsed "the panel
# did not grow" and "there is no panel" into one line would report a desktop
# that does not exist as a desktop that ignored a click.
if [ -n "$B3BEFORE" ] && [ -n "$B3AFTER" ] && [ "$B3AFTER" -gt "$B3BEFORE" ]; then
    echo "rcvr: PASS A MACHINE THAT INSTALLED THE BROKEN $BROKENVER RAN \`hpm update\` AND CAME BACK: a real click on the Applications button opened the menu (the panel window grew $B3BEFORE -> $B3AFTER px)"
elif [ -z "$B3BEFORE" ]; then
    echo "rcvr: FAIL THE UPDATE LANDED AND THE DESKTOP DID NOT COME BACK. The bytes arrived (see the digests above) and the compositor is running with ${B3WINS:-?} windows, but NONE of them is the top bar (a window at y=0, z=100), so there is no Applications button to click. Windows present: [${B3LIST:-none}]. \`hpm update\` DOES NOT RECOVER A MACHINE THAT TOOK $BROKENVER."
    fail=1
else
    echo "rcvr: FAIL THE UPDATE LANDED AND THE DESKTOP IS STILL INERT: after a real click the panel window is ${B3AFTER:-unknown} px, not more than $B3BEFORE. The bytes changed and the behaviour did not, so \`hpm update\` DOES NOT RECOVER A MACHINE THAT TOOK $BROKENVER."
    fail=1
fi
check "phase 3 reached the end"                 '\[rcvr\] PHASE3 DONE'

echo
if [ "$DISK_SUM_BEFORE" = "$DISK_SUM_AFTER" ]; then
    echo "rcvr: FAIL the disk is byte-identical before and after three boots -- nothing persisted"; fail=1
else
    echo "rcvr: PASS the disk changed ($DISK_SUM_BEFORE -> $DISK_SUM_AFTER)"
fi
echo
echo "(broken $PKG $BROKENVER: wsysd $BROKEN_MD5, hampanelscene $BROKEN_MD5_2, hamdesktop $BROKEN_MD5_3)"
echo "(live   $PKG $LIVEVER: wsysd $LIVE_MD5, hampanelscene $LIVE_MD5_2, hamdesktop $LIVE_MD5_3)"
echo "(breakage reproduced in this run: $BROKE_REPRODUCED)"
echo "(logs: $WORK/boot1.log $WORK/boot2.log $WORK/boot3.log)"
exit $fail
