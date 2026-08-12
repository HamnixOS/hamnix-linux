#!/usr/bin/env bash
# tests/linux/installed_update_live.sh — CAN A MACHINE THAT INSTALLED THIS
# DISTRIBUTION RECEIVE WORK PUBLISHED TO https://255.one/, AND THEN RUN IT?
#
# THE HALF OF THE NORTH STAR THAT WAS NEVER PROVEN END TO END
# ===========================================================
# NORTH_STAR.md carries the machine owner's permanent rule: *"changes that we
# create here will end up in the package repository and be able to be updated
# on."* One half of that is gated at build time --
# tests/linux/channel_covers_image.sh proves every binary the image ships is
# carried by some package, and scripts/hamlinux_packages.py refuses an index
# with a dangling dependency. That half asks whether the work LEAVES here.
#
# This file asks the other half, which nothing asked before: whether the work
# ARRIVES. A machine that installed hamnix-linux, runs `hpm update` against the
# REAL repository, reboots, and is then RUNNING THE NEWER CODE.
#
# tests/linux/installed_update.sh already proves the mechanism against a LOCAL
# channel: a package moves, the bytes on the disk are the bytes the host
# published, and they survive a reboot. Everything there is true and none of it
# touches https://255.one/ for the upgrade -- the local channel is a model of
# the repository, and a model cannot fail the way the real one can (a signature
# nobody published, a URL that moved, an index the shipped trusted key does not
# verify). Here the upgrade comes from the live channel, over TLS, and the
# host adds nothing to it.
#
# WHY THE EVIDENCE IS A MOUSE CLICK AND NOT A VERSION STRING
# ==========================================================
# "hpm list says 1.0.10" is satisfied by a database edit. This project has been
# bitten by exactly that class of proof often enough that NORTH_STAR.md has a
# section about it. So the question asked here is BEHAVIOURAL, and the
# behaviour is the one 1.0.10 changed:
#
#   Before commit cad406dc, `wsysd`'s deliver_pointer wrote the routed pointer
#   line to /dev/wsys/<wid>/pointer and nowhere else, while hampanelscene and
#   hamdesktop -- the panel and the desktop, the two programs a person actually
#   points at -- read /dev/wsys/<wid>/event. THE DESKTOP WAS INERT UNDER A
#   MOUSE. Clicking the Applications button did nothing whatsoever.
#
# So an update that silently did nothing cannot hide here: the desktop would
# still be dead. What this gate drives is a REAL POINTER -- QMP
# `input-send-event` onto the guest's `-device virtio-tablet-pci`, i.e. the
# absolute pointer QEMU gives every VM in this tree -- and what it measures is
# the panel window's own geometry, read in the guest with `cat
# /dev/wsys/<wid>/ctl`. A dead panel is 26 px tall. An open Applications menu
# is 250. Nothing in that chain is a string this test wrote.
#
# THE THREE BOOTS
# ===============
#   boot 1  the installed root comes up. `hpm install hamnix-desktop` from a
#           LOCAL channel built at a version BELOW the live one, whose wsysd is
#           the PRE-FIX compositor (below). The machine is now, exactly, a
#           machine that installed hamnix-linux before the mouse worked.
#   boot 2  the desktop comes up on that old compositor. A REAL CLICK on the
#           Applications button -> the panel does NOT move. The compositor's
#           own counter says the click reached IT (`pointer` goes up), so what
#           is being measured is the DE chrome being inert and not a mouse that
#           was never delivered. THEN: `hpm update`, no flags, against
#           https://255.one/.
#   boot 3  the same disk, nothing rebuilt. The desktop comes up on whatever
#           compositor the update left behind. THE SAME CLICK -> the panel
#           GROWS and the Applications menu is open.
#
# WHY THE "OLD" COMPOSITOR IS RECONSTRUCTED RATHER THAN CHECKED OUT
# =================================================================
# The image is built from this tree, so an install from this tree already has
# the fix and `hpm update` would correctly be a no-op -- the gate would have
# nothing to see. A machine that predates 1.0.10 has to be built. Rebuilding
# the whole tree at a pre-fix commit costs an hour and drags in every unrelated
# change; instead ONE LINE is reverted in a COPY of user/wsysd.ad (the
# `route_pointer_event(...)` call in deliver_pointer, which is the entire fix
# on the compositor side) and that binary is planted in the old channel's
# hamnix-desktop tarball. That reconstruction is checked, not assumed:
# `MOUSE_BIN_DIR=<dir> tests/linux/de_mouse_chrome.sh` against it scores 6
# PASS / 7 FAIL -- the exact revert-arm figure cad406dc reported -- and the
# unmodified tree scores 13/0.
#
# NO VERSION NUMBER IS WRITTEN DOWN AGAINST THE LIVE REPOSITORY
# ============================================================
# Publishing 1.0.8 once broke a test that hard-coded 1.0.8. Here the live
# version is READ from https://255.one/linux/index.json at run time and the
# "old" version is DERIVED strictly below it (and never below 1.0.0, because
# hamnix-desktop declares hamnix-init>=1 and a 0.x would make the package
# uninstallable for a reason that has nothing to do with what is being
# measured). The gate asserts "newer than what was installed", never "equal to
# some number". If the channel is at a version this cannot get below, it says
# so and stops rather than inventing an answer.
#
# AND THE BYTES, AS A SECOND WITNESS
# ==================================
# The host downloads the same hamnix-desktop tarball the guest is about to be
# sent and computes the MD5 of the wsysd inside it. The guest prints
# `md5sum /bin/wsysd` before the update and after the reboot. Before it must be
# the reconstructed pre-fix binary's digest; after it must be the digest of the
# bytes 255.one served. That is version-free: no index field can satisfy it.
#
# DELIBERATELY BREAKING IT
# ========================
#   HAMLINUX_LIVEUPD_NOUPDATE=1   phase 2 does everything EXCEPT `hpm update`.
# The machine reboots on the old compositor and boot 3's click does nothing.
# The gate must go red there, and the arm exists so that "it went green" is a
# statement about the update having happened rather than about the file
# running to the end.
#
# Usage: tests/linux/installed_update_live.sh [b1s] [b2s] [b3s]
#   HAMLINUX_LIVEUPD_REUSE=1    reuse the staged image root + local channel
#   HAMLINUX_LIVEUPD_NOUPDATE=1 the negative control above
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
BIN=/bin/wsysd
CHANNEL_URL="${HAMLINUX_LIVEUPD_URL:-https://255.one/linux/index.json}"
LIVE_BASE="$(dirname "$CHANNEL_URL")/"

WORK="${HAMLINUX_LIVEUPD_WORK:-build/liveupd}"; mkdir -p "$WORK"
IMG=build/image
DISK="$IMG/liveupd.img"
REPO="$WORK/repo"
EXTRA="$WORK/extra"
QMP="$PROJ_ROOT/$WORK/qmp.sock"
NOUPD="${HAMLINUX_LIVEUPD_NOUPDATE:-0}"

fail=0
say() { echo "[lupd] $*"; }
[ -f "$IMG/distro.ext4" ] || { echo "no distro image; run scripts/hamlinux_distro.sh" >&2; exit 1; }
command -v python3 >/dev/null || { echo "need python3" >&2; exit 1; }

# =========================================================================
# 1. WHAT IS THE LIVE CHANNEL AT, RIGHT NOW?
# =========================================================================
# Asked, never assumed. This gate is ABOUT the live repository, so a
# repository that cannot be reached is a failure of the run and not something
# to fall back from -- falling back to a local channel here would answer a
# different question in the same shape as this one, which is the exact failure
# NORTH_STAR.md names.
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

# THE "OLD" VERSION, DERIVED. Strictly below the live one and never below
# 1.0.0 (hamnix-desktop declares hamnix-init>=1: a 0.x channel would make the
# package refuse to install for a reason that is not what is being measured).
OLDVER="$(LIVEVER="$LIVEVER" python3 <<'PY'
import os, sys
try:
    a, b, c = (int(x) for x in os.environ["LIVEVER"].split("."))
except ValueError:
    sys.exit(1)
if c > 0:   print("%d.%d.0" % (a, b))
elif b > 0: print("%d.0.0" % a)
elif a > 1: print("%d.0.0" % (a - 1))
else:       sys.exit(1)
PY
)"
[ -n "$OLDVER" ] || {
    echo "FAIL: the channel is at $LIVEVER and this gate cannot derive a version" >&2
    echo "      below it that still satisfies hamnix-init>=1. Nothing is measured" >&2
    echo "      rather than measuring the wrong thing." >&2
    exit 1; }
# And the derivation is CHECKED, with the same rule hpm uses (docs/packages.md:
# field by numeric field). A gate whose 'old' is not old would report a
# no-op update as a working one.
OLDVER="$OLDVER" LIVEVER="$LIVEVER" python3 <<'PY' || {
import os, sys
def key(v): return [int(x) for x in v.split(".")]
sys.exit(0 if key(os.environ["OLDVER"]) < key(os.environ["LIVEVER"]) else 1)
PY
    echo "FAIL: derived old version $OLDVER does not sort below the live $LIVEVER" >&2; exit 1; }
say "the live channel serves $PKG $LIVEVER; this machine will be installed at $OLDVER"

# =========================================================================
# 2. THE BYTES 255.one IS SERVING, FETCHED BY THE HOST TOO.
# =========================================================================
# So that "the update landed" can be said about CONTENT and not about a
# version field. The host takes the same tarball the guest is about to be
# sent, over the same TLS, and computes the digest of the compositor inside
# it. Nothing the guest can print except those exact bytes matches it.
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
LIVE_WSYSD="$WORK/liveunpack/$PKG-$LIVEVER/files${BIN}"
[ -f "$LIVE_WSYSD" ] || {
    echo "FAIL: the live $PKG carries no $BIN" >&2; exit 1; }
LIVE_MD5="$(md5sum "$LIVE_WSYSD" | cut -d' ' -f1)"
say "the $BIN the live channel serves is md5 $LIVE_MD5 ($(stat -c%s "$LIVE_WSYSD") bytes)"

# =========================================================================
# 3. The image root.
# =========================================================================
if [ "${HAMLINUX_LIVEUPD_REUSE:-0}" = 1 ] && [ -f "$IMG/initramfs.cpio.gz" ]; then
    say "reusing the staged image root (HAMLINUX_LIVEUPD_REUSE=1)"
else
    say "staging the image root"
    HAMLINUX_JOBS="${HAMLINUX_JOBS:-4}" scripts/hamlinux_image.sh \
        >"$WORK/image.log" 2>&1 || {
        echo "FAIL image build"; tail -20 "$WORK/image.log"; exit 1; }
fi

# =========================================================================
# 4. THE MACHINE AS IT WAS BEFORE THE MOUSE WORKED.
# =========================================================================
# One line out of a copy of user/wsysd.ad -- the call that puts the routed
# pointer on the canonical EVENT ring, which is the whole compositor half of
# cad406dc. Everything else in the channel is this tree.
say "reconstructing the pre-fix compositor (the route_pointer_event call reverted)"
mkdir -p "$WORK/prefix"
grep -n 'route_pointer_event(wid, lx, ly, ptr_btn, ptr_dz)' user/wsysd.ad >/dev/null || {
    echo "FAIL: user/wsysd.ad no longer contains the call this gate reverts." >&2
    echo "      The reconstruction is stale; fix it rather than measuring a" >&2
    echo "      compositor that is identical to the shipped one." >&2
    exit 1; }
sed 's/^\( *\)route_pointer_event(wid, lx, ly, ptr_btn, ptr_dz)/\1# REVERTED BY tests\/linux\/installed_update_live.sh/' \
    user/wsysd.ad >"$WORK/prefix/wsysd.ad"
cmp -s user/wsysd.ad "$WORK/prefix/wsysd.ad" && {
    echo "FAIL: the revert changed nothing" >&2; exit 1; }
if [ "${HAMLINUX_LIVEUPD_REUSE:-0}" = 1 ] && [ -x "$WORK/prefix/wsysd" ]; then
    say "reusing the pre-fix compositor"
else
    scripts/hamlinux_build.sh "$WORK/prefix/wsysd.ad" "$WORK/prefix/wsysd" \
        >"$WORK/prefix/build.log" 2>&1 || {
        echo "FAIL: the pre-fix compositor did not build"; tail -20 "$WORK/prefix/build.log"; exit 1; }
fi
OLD_MD5="$(md5sum "$WORK/prefix/wsysd" | cut -d' ' -f1)"
[ "$OLD_MD5" != "$LIVE_MD5" ] || {
    echo "FAIL: the pre-fix compositor is byte-identical to the published one," >&2
    echo "      so this gate could not tell an update from a no-op." >&2; exit 1; }
say "the pre-fix $BIN is md5 $OLD_MD5"

# =========================================================================
# 5. The channel the machine was installed from.
# =========================================================================
PORT="$(python3 - <<'PY'
import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()
PY
)"
BASE="http://10.0.2.2:$PORT/"
if [ "${HAMLINUX_LIVEUPD_REUSE:-0}" = 1 ] && [ -f "$REPO/linux/index.json" ]; then
    say "reusing the local channel at $OLDVER (HAMLINUX_LIVEUPD_REUSE=1)"
else
    say "building the local channel at $OLDVER (the machine's original install)"
    scripts/hamlinux_packages.py --out "$REPO" --version "$OLDVER" \
        --channel linux --base-url "$BASE" >"$WORK/repo.log" 2>&1 || {
        echo "FAIL channel build"; tail -20 "$WORK/repo.log"; exit 1; }
fi

# Plant the pre-fix compositor, correct the index, and point the index at
# whatever port this run got. hpm verifies the tarball's sha256 against the
# index before it unpacks a byte, so this has to be done properly or the
# install fails -- which is the point: the machine accepts these bytes the
# same way it would accept the repository's.
say "planting the pre-fix $BIN in $PKG-$OLDVER and re-pointing the index at $BASE"
PKG="$PKG" OLDVER="$OLDVER" REPO="$REPO" BASE="$BASE" NEWBIN="$WORK/prefix/wsysd" \
BINPATH="${BIN#/}" python3 <<'PY' || { echo "FAIL: could not plant the pre-fix binary"; exit 1; }
import hashlib, io, json, os, tarfile

repo, pkg, ver = os.environ["REPO"], os.environ["PKG"], os.environ["OLDVER"]
newbin, inside = os.environ["NEWBIN"], "files/" + os.environ["BINPATH"]
tarpath = os.path.join(repo, "linux", "packages", "%s-%s.tar.gz" % (pkg, ver))
top = "%s-%s" % (pkg, ver)
payload = open(newbin, "rb").read()

members = []
with tarfile.open(tarpath, "r:gz") as tf:
    for ti in tf.getmembers():
        members.append((ti, tf.extractfile(ti).read() if ti.isfile() else None))
if not any(ti.name == top + "/" + inside for ti, _ in members):
    raise SystemExit("%s carries no %s" % (tarpath, inside))

buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w:gz", compresslevel=9,
                  format=tarfile.GNU_FORMAT) as out:
    for ti, data in members:
        if ti.name == top + "/" + inside:
            ti.size = len(payload)
            out.addfile(ti, io.BytesIO(payload))
        elif data is None:
            out.addfile(ti)
        else:
            out.addfile(ti, io.BytesIO(data))
raw = buf.getvalue()
open(tarpath, "wb").write(raw)

ipath = os.path.join(repo, "linux", "index.json")
index = json.load(open(ipath))
index["url"] = os.environ["BASE"]
for e in index["packages"]:
    if e["name"] == pkg:
        e["sha256"] = hashlib.sha256(raw).hexdigest()
        e["size"] = len(raw)
with open(ipath, "w") as fh:
    json.dump(index, fh, indent=2)
    fh.write("\n")
PY

# The local channel is SIGNED and the guest gets the matching public key: the
# install the machine's history is made of takes the same path a real one
# would, with no --allow-unsigned anywhere in this file.
mkdir -p "$EXTRA/etc/hpm"
python3 scripts/hpm_sign.py keygen --out-pub "$EXTRA/etc/hpm/test-trusted.pub" \
    --out-sec "$WORK/test.sec" >/dev/null || {
    echo "FAIL: cannot mint a signing key"; exit 1; }
python3 scripts/hpm_sign.py sign "$REPO/linux/index.json" "$WORK/test.sec" \
    "$REPO/linux/index.json.sig" || {
    echo "FAIL: cannot sign the local index"; exit 1; }

python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$REPO" \
    >"$WORK/http.log" 2>&1 &
HTTPD=$!
HTTPD_HITS="$WORK/http.log"
cleanup() {
    kill "$HTTPD" 2>/dev/null; wait "$HTTPD" 2>/dev/null
    [ -n "${VM:-}" ] && kill "$VM" 2>/dev/null
}
trap cleanup EXIT
# A bare EXIT trap does not run when the shell is killed by a signal, so a
# gate stopped by `timeout` (TERM) or ^C (INT) skipped its cleanup entirely.
# Re-exit on those, which makes the EXIT trap above run on every path out.
trap 'exit 130' INT TERM HUP
sleep 1
curl -fsS "http://127.0.0.1:$PORT/linux/index.json" >/dev/null || {
    echo "FAIL: the local channel is not being served"; exit 1; }
say "the original-install channel is served at $BASE (pid $HTTPD)"

# =========================================================================
# 6. The three boot scripts.
# =========================================================================
# Every one of them `source /etc/rc.boot.installed` -- the REAL installed rc,
# which is also what starts the desktop (it ends by sourcing /etc/rc.d/rc.5).
# So the desktop under the mouse below is the one an installed machine boots,
# not one this test arranged.
mkdir -p "$EXTRA/etc"

# The block the host reads the window geometry out of. `cat /dev/wsys/<wid>/ctl`
# prints "<wid> <x> <y> <w> <h> <z> ...", and that is the panel's own account
# of itself -- wsysd writes it, hampanelscene asked for it. wid 5 usually does
# not exist and `cat` says so, which is harmless and is left in rather than
# guessed away.
_wins() {   # _wins <phase> <tag>
    cat <<W
echo '[lupd] $1 WINS-$2'
cat /dev/wsys/2/ctl
cat /dev/wsys/3/ctl
cat /dev/wsys/4/ctl
cat /dev/wsys/5/ctl
echo '[lupd] $1 WINS-END'
echo '[lupd] $1 STATE-$2:'
cat /dev/wsys/wsysd/state
W
}

cat > "$WORK/rc.phase1" <<RC
source '/etc/rc.boot.installed'

echo '[lupd] ===== PHASE 1: this machine installs the desktop it shipped with'
date
dhcpc
echo '[lupd] p1 dhcpc status:' \$status

# The install that gives this machine its history. It comes from the local
# channel at $OLDVER, signed, with the key staged in /etc/hpm -- the same path
# a machine installed from any channel takes.
#
# THE REFRESH IS NOT DECORATION. \`hpm install\` reads a CACHED index and says
# "hpm: no cached index; run \`hpm refresh\` first" if there is none -- measured,
# on the first run of this gate, where the install exited 1 and the machine
# reached boot 2 still carrying the image's own compositor. That would have
# made boot 2's control ("the old desktop does NOT react") fail, which is the
# gate telling the truth about a broken setup rather than proceeding.
echo '[lupd] p1 refresh the original-install channel'
hpm --repo=$BASE --trusted-key=/etc/hpm/test-trusted.pub refresh
echo '[lupd] p1 refresh status:' \$status
echo '[lupd] p1 install $PKG from the original-install channel'
hpm --repo=$BASE --trusted-key=/etc/hpm/test-trusted.pub install $PKG
echo '[lupd] p1 install status:' \$status
echo '[lupd] p1 list:'
hpm list
echo '[lupd] p1 md5 of $BIN:'
md5sum $BIN

echo '[lupd] PHASE1 DONE'
cp /etc/rc.phase2 /etc/rc.boot
echo '[lupd] p1 armed the next boot'
reboot
RC

{
cat <<RC
source '/etc/rc.boot.installed'

echo '[lupd] ===== PHASE 2: the desktop this machine was installed with,'
echo '[lupd]               under a real mouse -- and then hpm update'
date
dhcpc
echo '[lupd] p2 dhcpc status:' \$status

# The desktop is already coming up: rc.boot.installed ends by sourcing
# /etc/rc.d/rc.5. Give it the time a desktop takes.
sleep 14
RC
_wins p2 BEFORE
cat <<RC
echo '[lupd] p2 md5 of $BIN before any update:'
md5sum $BIN

# THE HOST NOW CLICKS. A real pointer, on the guest's virtio-tablet, at the
# Applications button. Nothing in this guest knows it is coming.
echo '[lupd] p2 READY-FOR-CLICK'
sleep 30
RC
_wins p2 AFTER
} > "$WORK/rc.phase2"

if [ "$NOUPD" = 1 ]; then
cat >> "$WORK/rc.phase2" <<RC

# HAMLINUX_LIVEUPD_NOUPDATE=1: the update is DELIBERATELY NOT RUN. Everything
# else about this run is identical, so whatever boot 3 says is a statement
# about the update and not about the rest of the machinery.
echo '[lupd] p2 THE UPDATE WAS DELIBERATELY SKIPPED (HAMLINUX_LIVEUPD_NOUPDATE=1)'
RC
else
cat >> "$WORK/rc.phase2" <<RC

# THE COMMAND THE OWNER TYPES, WITH NOTHING ADDED TO IT, AGAINST THE REAL
# REPOSITORY. No --repo, no --allow-unsigned, no key staged by this test: hpm's
# own default channel and the trusted key the IMAGE ships.
echo '[lupd] p2 ----- hpm refresh (no flags, the real repository)'
hpm refresh
echo '[lupd] p2 refresh status:' \$status
echo '[lupd] p2 ----- hpm update (no flags, the real repository)'
hpm update
echo '[lupd] p2 update status:' \$status
echo '[lupd] p2 list after update:'
hpm list
echo '[lupd] p2 md5 of $BIN after update:'
md5sum $BIN
RC
fi

cat >> "$WORK/rc.phase2" <<RC

# A PACKAGE MUST NOT OWN THE MACHINE'S BOOT SCRIPT. This is the file hamsh is
# executing right now; \`ls -l\` is the form that answers without wedging pid 1
# (installed_update.sh paid for both of the other forms), and the digest is
# what the host asserts on.
echo '[lupd] p2 md5 of /etc/rc.boot after hpm ran:'
md5sum /etc/rc.boot

date
echo '[lupd] PHASE2 DONE'
cp /etc/rc.phase3 /etc/rc.boot
echo '[lupd] p2 armed the next boot'
reboot
RC

{
cat <<'RC'
source '/etc/rc.boot.installed'

echo '[lupd] ===== PHASE 3: the same disk, nothing rebuilt. Click it again.'
date
sleep 14
RC
_wins p3 BEFORE
cat <<RC
echo '[lupd] p3 md5 of $BIN:'
md5sum $BIN
echo '[lupd] p3 list:'
hpm list
echo '[lupd] p3 READY-FOR-CLICK'
sleep 30
RC
_wins p3 AFTER
cat <<'RC'
date
echo '[lupd] PHASE3 DONE'
# END THE MACHINE RATHER THAN LEAVING pid 1 ON A PROMPT. Phases 1 and 2 end by
# restarting; this one has nothing after it, and hamsh falling through to read
# the console held the VM for the whole remaining budget -- four minutes of a
# machine somebody else is using, per run.
reboot
RC
} > "$WORK/rc.phase3"

cp "$WORK/rc.phase2" "$EXTRA/etc/rc.phase2"
cp "$WORK/rc.phase3" "$EXTRA/etc/rc.phase3"
# THE DIGEST OF THE rc THAT IS RUNNING WHEN hpm RUNS, which is phase 2's --
# boot 1 ends by copying it over /etc/rc.boot. The first version of this file
# asserted phase 1's digest and went red on a machine where hpm had behaved
# perfectly, which is the expensive kind of red: it pointed at hpm.
RC2_MD5="$(md5sum "$WORK/rc.phase2" | cut -d' ' -f1)"

# =========================================================================
# 7. Install a disk.
# =========================================================================
say "building the installed disk"
HAMLINUX_DISK_RC="$WORK/rc.phase1" HAMLINUX_DISK_EXTRA="$EXTRA" \
    scripts/hamlinux_disk.sh "$DISK" 3G >"$WORK/build.log" 2>&1 || {
    echo "FAIL disk build"; tail -20 "$WORK/build.log"; exit 1; }
DISK_SUM_BEFORE="$(md5sum "$DISK" | cut -d' ' -f1)"

# =========================================================================
# 8. Boot it three times, and put a hand on the mouse twice.
# =========================================================================
# THE CLICK IS DRIVEN FROM OUTSIDE THE GUEST, over QMP, onto
# `-device virtio-tablet-pci`. That device is in scripts/hamlinux_vm.sh's disk
# mode already; all this adds is a QMP socket to talk to it through. What
# arrives in the guest is a `struct input_event` stream off /dev/input/eventN
# that nothing in the guest can distinguish from a hand on a mouse -- which is
# the entire reason it is done this way rather than by writing an event ring,
# the shortcut that let a completely missing input path go unnoticed for the
# life of this port (see tests/linux/de_mouse_chrome.sh).
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
            # The screen's size comes from the guest, not from this file: the
            # backdrop window (z -1) is the display. QMP's absolute axes are a
            # 0..32767 range across it, which is the same normalisation wsysd's
            # pump_input undoes on the other side.
            #
            # AND IT FALLS BACK TO THE SIZE AN EARLIER BOOT REPORTED, because a
            # boot with NO WINDOWS AT ALL has no backdrop to read -- and that is
            # exactly the boot where the click matters most. Without the
            # fallback this gate skips the click and then reports "nothing was
            # clicked", which is a true sentence about the test and a false
            # one about the machine. The click still goes in; the compositor's
            # pointer counter still answers; and "the desktop has no windows"
            # gets to be the finding rather than being hidden behind a mouse
            # that was never moved.
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
                echo "[lupd] this boot printed no window to read the screen size from" \
                     "('$back') -- clicking at the ${sw}x${sh} an earlier boot reported"
            fi
            sleep 3
            python3 tests/linux/qmp_click.py "$QMP" "$sw" "$sh" \
                "$APPBTN_X" "$APPBTN_Y" >>"$log.click" 2>&1 \
                || echo "[lupd] the QMP click itself failed; see $log.click"
        fi
    fi
    wait "$VM" 2>/dev/null
    VM=""
}

say "boot 1 of 3: the install that gives this machine its history (up to ${WAIT1}s)"
boot "$WORK/boot1.log" "$WAIT1" 0
say "boot 2 of 3: the old desktop under a real mouse, then the update (up to ${WAIT2}s)"
boot "$WORK/boot2.log" "$WAIT2" 1
say "boot 3 of 3: the same disk, clicked again (up to ${WAIT3}s)"
boot "$WORK/boot3.log" "$WAIT3" 1
DISK_SUM_AFTER="$(md5sum "$DISK" | cut -d' ' -f1)"

for n in 1 2 3; do
    echo
    echo "--------- boot $n transcript"
    grep -aE '^\[lupd\]|^rc\.boot:|^hpm:|^[0-9]+ [0-9]+ [0-9]+ [0-9]+ |^focus [0-9]' \
        "$WORK/boot$n.log" | tr -d '\r' || tail -20 "$WORK/boot$n.log"
done
echo

# =========================================================================
# 9. The questions.
# =========================================================================
LOG=""
check() { if grep -aqE "$2" "$LOG"; then echo "lupd: PASS $1"
          else echo "lupd: FAIL $1   (no line matching /$2/ in $LOG)"; fail=1; fi; }
after() {   # after <name> <banner> <regex>
    got="$(grep -aA5 -F "$2" "$LOG" | tail -n +2 | tr -d '\r')"
    if printf '%s\n' "$got" | grep -qE "$3"; then
        echo "lupd: PASS $1  -> '$(printf '%s\n' "$got" | grep -E "$3" | head -1)'"
    else
        echo "lupd: FAIL $1  (nothing matching /$3/ after '$2'; got: $(printf '%s' "$got" | tr '\n' '|'))"
        fail=1
    fi
}
# THE TOP PANEL'S HEIGHT, out of the guest's own ctl lines. The bar is the
# window at y=0 with z=100 -- the backdrop is z=-1 and the taskbar is at the
# bottom of the screen -- so no window id is guessed anywhere in this file.
barh() {   # barh <log> <marker>
    awk -v m="$2" 'index($0, m) {inb=1; next}
                   inb && index($0, "WINS-END") {exit}
                   inb && NF >= 6 && $3 == 0 && $6 == 100 {print $5; exit}' \
        "$1" | tr -d '\r'
}
# AND WHETHER ANY OF IT IS ON THE SCREEN. Field 8 of the ctl line is `visible`
# (user/linux-wsys.c snap_win_ctl: "<wid> <x> <y> <w> <h> <z> <decorate>
# <visible> <proto> …"), and until this was added NOTHING in this file read it.
#
# THAT WAS NOT A THEORETICAL HOLE. Measured offscreen on the real desktop
# (tree wsysd + hamdesktop + hampanelscene, this branch): open the Applications
# menu, then set `visible 0` on all three windows -- which is the state a
# withdrawn window is left in, geometry and enumeration intact -- and the ctl
# block reads
#
#   2 0 0 1280 800  -1 0 0 1 82 …      (the wallpaper)
#   3 0 0 1280 206 100 0 0 1 49 …      (the top bar, GROWN, invisible)
#   4 0 774 1280 26 100 0 0 1 45 …     (the taskbar)
#
# while the framebuffer is 100.0% one flat colour: the compositor's clear
# colour, no wallpaper, no panel, no menu card, nothing but the cursor. The
# verdict below, run verbatim over that log, printed
#
#   lupd: PASS THE UPDATED MACHINE RUNS THE NEWER CODE: a real click on the
#   Applications button opened the menu (the panel window grew 26 -> 206 px)
#
# about a machine whose screen is BLANK. Height alone is a proxy for "the menu
# opened" and it survives the desktop disappearing, which is exactly the
# success-shaped answer NORTH_STAR.md forbids. It is a proxy for the same
# reason it was chosen -- it is what the guest can print without a display --
# so the fix is not to drop it but to demand the OTHER field the same line
# already carries. This can only ever turn a PASS into a FAIL.
barvis() {   # barvis <log> <marker> -- the top bar's `visible` flag
    awk -v m="$2" 'index($0, m) {inb=1; next}
                   inb && index($0, "WINS-END") {exit}
                   inb && NF >= 8 && $3 == 0 && $6 == 100 {print $8; exit}' \
        "$1" | tr -d '\r'
}
statefield() {   # statefield <log> <marker> <field>
    grep -aA1 -F "$2" "$1" | tail -1 | tr -d '\r' |
        awk -v f="$3" '{for (i = 1; i < NF; i++) if ($i == f) print $(i+1)}'
}
# DID THE MOUSE ARRIVE? Two witnesses, because one of them cannot speak in the
# case that matters most. `pointer` counts events wsysd ROUTED TO A WINDOW, so
# on a boot with zero windows it stays 0 no matter how hard the mouse is
# moved -- deliver_pointer returns early when nothing is under the cursor. The
# first version of this gate read that as "nothing was clicked" and said so,
# next to a click the QMP log shows was accepted: a false sentence about the
# mouse standing in front of a true one about the desktop. `curframes` counts
# the cursor-only frames the compositor drew, which is the pointer MOVING and
# needs no window at all.
mouse_arrived() {   # mouse_arrived <log> <before-marker> <after-marker> <label>
    local pb pa cb ca
    pb="$(statefield "$1" "$2" pointer)";    pa="$(statefield "$1" "$3" pointer)"
    cb="$(statefield "$1" "$2" curframes)";  ca="$(statefield "$1" "$3" curframes)"
    if [ -n "$pb" ] && [ -n "$pa" ] && [ "$pa" -gt "$pb" ]; then
        echo "lupd: PASS the real pointer reached $4 (it routed $pb -> $pa pointer events to a window)"
    elif [ -n "$cb" ] && [ -n "$ca" ] && [ "$ca" -gt "$cb" ]; then
        echo "lupd: PASS the real pointer reached $4 (cursor-only frames $cb -> $ca; it routed none to a window, which is what zero windows means)"
    else
        echo "lupd: FAIL nothing was clicked at $4: pointer '$pb'->'$pa', curframes '$cb'->'$ca'"; fail=1
    fi
}

echo "--- boot 1: the machine gets the desktop it was installed with"
LOG="$WORK/boot1.log"
check "the installed root came online"        'rc\.boot: hamnix-linux \(installed\)'
check "dhcpc took a lease"                    '\[lupd\] p1 dhcpc status: 0'
check "the original-install channel refreshed" '\[lupd\] p1 refresh status: 0'
check "the original install exited 0"         '\[lupd\] p1 install status: 0'
after "and it recorded $PKG at $OLDVER"       '[lupd] p1 list:' "$PKG[^0-9]*$OLDVER"
after "the compositor on disk is the PRE-FIX one" '[lupd] p1 md5 of' "$OLD_MD5"
check "the machine restarted itself"          'reboot: Restarting system'

echo
echo "--- boot 2: THE DESKTOP THIS MACHINE SHIPPED WITH, UNDER A REAL MOUSE"
LOG="$WORK/boot2.log"
check "the desktop came up on the installed boot" '\[lupd\] p2 WINS-BEFORE'
B2BEFORE="$(barh "$LOG" '[lupd] p2 WINS-BEFORE')"
B2AFTER="$(barh "$LOG" '[lupd] p2 WINS-AFTER')"
if [ -n "$B2BEFORE" ] && [ -n "$B2AFTER" ]; then
    echo "lupd: INFO the top panel is ${B2BEFORE} px before the click and ${B2AFTER} px after it"
else
    echo "lupd: FAIL the guest never printed a top panel window (before='$B2BEFORE' after='$B2AFTER')"; fail=1
fi
# THE CLICK REACHED THE COMPOSITOR. Without this the line below would be
# satisfied by a mouse that was never delivered -- a gate answering
# "the desktop is dead" when the truth is "nothing was clicked".
mouse_arrived "$LOG" '[lupd] p2 STATE-BEFORE:' '[lupd] p2 STATE-AFTER:' \
              "the OLD compositor"
if [ -n "$B2BEFORE" ] && [ "${B2AFTER:-0}" = "$B2BEFORE" ]; then
    echo "lupd: PASS and the DE chrome did NOT move: the Applications button is dead on this machine (panel still $B2AFTER px)"
else
    echo "lupd: FAIL the pre-update desktop already reacted to the click ($B2BEFORE -> $B2AFTER px) -- the 'before' state is not the old one, so boot 3 proves nothing"; fail=1
fi
after "the compositor on disk is still the PRE-FIX one" '[lupd] p2 md5 of /bin/wsysd before' "$OLD_MD5"

if [ "$NOUPD" = 1 ]; then
    echo "lupd: NOTE HAMLINUX_LIVEUPD_NOUPDATE=1 -- the update was deliberately not run"
    check "and the run says so out loud" '\[lupd\] p2 THE UPDATE WAS DELIBERATELY SKIPPED'
else
    echo
    echo "--- boot 2, continued: hpm update, no flags, against $LIVE_BASE"
    check "a bare 'hpm refresh' TRUSTS the real repository" '\[lupd\] p2 refresh status: 0'
    check "and it was the real repository"          "hpm: (fetching channel|refreshed index from) .*255\.one"
    check "a bare 'hpm update' exited 0"            '\[lupd\] p2 update status: 0'
    # hpm's own account of what it did. Not `after`: hpm upgrades every
    # installed package and the line for this one is a dozen lines down.
    check "hpm named the upgrade $OLDVER -> $LIVEVER" \
          "hpm: upgrading $PKG $OLDVER -> $LIVEVER"
    check "and hpm verified the tarball it was sent" 'hpm: SHA-256 verified'
    check "hpm refused to take the machine's boot script" \
          "hpm: keeping this machine's own /etc/rc\.boot"
    after "the version moved to the live one"       '[lupd] p2 list after update:' \
          "$PKG[^0-9]*$LIVEVER"
    # THE BYTES, WHICH NO INDEX FIELD CAN SATISFY.
    after "and $BIN on the disk is now the byte-for-byte published one" \
          '[lupd] p2 md5 of /bin/wsysd after update:' "$LIVE_MD5"
fi
after "hpm left the machine's own /etc/rc.boot alone" \
      '[lupd] p2 md5 of /etc/rc.boot after hpm ran:' "$RC2_MD5"
check "phase 2 reached the end"                 '\[lupd\] PHASE2 DONE'
check "the machine restarted itself again"      'reboot: Restarting system'

echo
echo "--- boot 3: THE SAME DISK, CLICKED AGAIN"
LOG="$WORK/boot3.log"
check "the machine booted again"                'rc\.boot: hamnix-linux \(installed\)'
check "it ran the rc phase 2 wrote"             'PHASE 3: the same disk'
if [ "$NOUPD" != 1 ]; then
    after "the update survived the reboot (version)" '[lupd] p3 list:' "$PKG[^0-9]*$LIVEVER"
    after "the update survived the reboot (BYTES)"   '[lupd] p3 md5 of' "$LIVE_MD5"
fi
B3BEFORE="$(barh "$LOG" '[lupd] p3 WINS-BEFORE')"
B3AFTER="$(barh "$LOG" '[lupd] p3 WINS-AFTER')"
echo "lupd: INFO the top panel is ${B3BEFORE:-?} px before the click and ${B3AFTER:-?} px after it"
mouse_arrived "$LOG" '[lupd] p3 STATE-BEFORE:' '[lupd] p3 STATE-AFTER:' \
              "the UPDATED compositor"
# ===== THE SENTENCE THIS WHOLE FILE EXISTS FOR =====
# Three outcomes, and they are three different sentences. A gate that collapsed
# "the panel did not grow" and "there is no panel" into one line would report a
# desktop that does not exist as a desktop that ignored a click, which is the
# wrong bug on the wrong day.
P3WINS="$(statefield "$LOG" '[lupd] p3 STATE-BEFORE:' windows)"
# WHAT THE COMPOSITOR DOES HAVE, quoted, because "no top bar" and "no desktop"
# are different sentences and the published clients have produced both across
# runs: once zero windows, once the panel's BOTTOM taskbar and the wallpaper
# with the top bar -- the one carrying the Applications button -- simply absent.
P3LIST="$(awk 'index($0, "[lupd] p3 WINS-BEFORE") {inb = 1; next}
               inb && index($0, "WINS-END") {exit}
               inb && NF >= 6 && $1 ~ /^[0-9]+$/ {printf "(%s) ", $0}' "$LOG" | tr -d '\r')"
B3VIS="$(barvis "$LOG" '[lupd] p3 WINS-AFTER')"
if [ -n "$B3BEFORE" ] && [ -n "$B3AFTER" ] && [ "$B3AFTER" -gt "$B3BEFORE" ] &&
   [ "${B3VIS:-0}" = 1 ]; then
    echo "lupd: PASS THE UPDATED MACHINE RUNS THE NEWER CODE: a real click on the Applications button opened the menu (the panel window grew $B3BEFORE -> $B3AFTER px, and it is visible)"
elif [ -n "$B3BEFORE" ] && [ -n "$B3AFTER" ] && [ "$B3AFTER" -gt "$B3BEFORE" ]; then
    echo "lupd: FAIL THE MENU OPENED ONTO A SCREEN NOBODY CAN SEE: the panel window grew $B3BEFORE -> $B3AFTER px, so the click was routed and the panel reacted, but the top bar's own ctl line says visible='${B3VIS:-absent}'. A withdrawn window keeps its geometry and its place in the window table; it is simply not composited. Windows present: [${P3LIST:-none}]. The person in front of this machine has no desktop."
    fail=1
elif [ -z "$B3BEFORE" ]; then
    echo "lupd: FAIL THE UPDATE LANDED AND THE DESKTOP DID NOT COME UP. The bytes arrived (see the digest above) and the compositor is running with ${P3WINS:-?} windows, but NONE of them is the top bar (a full-width window at y=0, z=100), so there is no Applications button to click. Windows present: [${P3LIST:-none}]. What the channel is serving is not a working desktop."
    fail=1
else
    echo "lupd: FAIL THE UPDATED MACHINE IS STILL RUNNING THE OLD DESKTOP: after a real click the panel window is ${B3AFTER:-unknown} px, not more than $B3BEFORE. The work published to the channel did not reach this machine, or did not take effect."
    fail=1
fi
check "phase 3 reached the end"                 '\[lupd\] PHASE3 DONE'

echo
if [ "$DISK_SUM_BEFORE" = "$DISK_SUM_AFTER" ]; then
    echo "lupd: FAIL the disk is byte-identical before and after three boots -- nothing persisted"; fail=1
else
    echo "lupd: PASS the disk changed ($DISK_SUM_BEFORE -> $DISK_SUM_AFTER)"
fi
echo
echo "(live $PKG $LIVEVER md5 $LIVE_MD5; installed-at $OLDVER md5 $OLD_MD5)"
echo "(logs: $WORK/boot1.log $WORK/boot2.log $WORK/boot3.log)"
exit $fail
