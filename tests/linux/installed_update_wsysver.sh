#!/usr/bin/env bash
# tests/linux/installed_update_wsysver.sh — WHAT DOES A LIVE `hpm update` OF
# THE WINDOW SYSTEM DO TO A PERSON WHO IS SITTING IN FRONT OF THE MACHINE?
#
# THE SENTENCE THIS FILE EXISTS TO MEASURE
# ========================================
# user/linux-wsys.c bumps WSYS_VERSION 6 -> 7 and says, in as many words, that
# a version mismatch
#
#     "re-initialises that desktop's window table by design and always has …
#      The re-initialise it forces costs the previous session's windows, which
#      is what a version mismatch has always meant here, and it is LOUD -- the
#      windows go -- where the alternative is a desktop that looks right and
#      ignores the keyboard."
#
# and that the only way to meet an old segment is "a live `hpm update` of the
# window system underneath a running desktop".
#
# That paragraph had never been run. It is a claim about what EVERY updating
# user is about to experience, and NORTH_STAR.md's rule is that a measurement
# is worth more than an argument -- including one written in a comment by the
# people who wrote the code. So this boots a real installed machine at the
# CURRENT PUBLISHED version, with a desktop up and a window open, runs
# `hpm update`, and asks the SCREEN and the POINTER what happened. It asserts
# nothing about exit codes.
#
# THE THREE THINGS A PERSON DOES, IN ORDER
# ========================================
#   STAGE A  the desktop as it shipped. A terminal is opened THROUGH THE DE'S
#            OWN LAUNCH QUEUE (/dev/wsys/run/launch -- the file the
#            Applications menu writes, drained by the RUNNING panel). Then a
#            real QMP click on the Applications button and real QMP keystrokes.
#            This is the control: the machine demonstrably works.
#   STAGE B  `hpm update` has run and NOTHING has been relaunched.
#   STAGE C  the person opens one more app -- the first NEW binary to attach to
#            the running session's segment.
#
# THE MEASUREMENT MUST NOT BE THE THING IT MEASURES
# =================================================
# The first version of this gate answered "the desktop has no windows" at
# STAGE A, before any update -- and it was RIGHT about the pixels and WRONG
# about the cause. `cat /dev/wsys/2/ctl` is a wsys client: every program in
# this tree links user/linux-wsys.c, so /bin/cat off the IMAGE (built from
# this tree, version 7) attached to the running v6 session and punched it,
# and the gate then photographed the wreck it had made and blamed the desktop.
# Two things follow and both are load-bearing:
#
#   1. The machine is installed at the published version WHOLE -- `hpm install
#      hamnix-base`, which is coreutils and hamsh and the desktop -- so that no
#      binary the rc script runs is newer than the session it is inspecting.
#   2. THE HOST'S EVIDENCE COMES FIRST, ALWAYS. Screendumps, the pointer and
#      the keyboard are driven from OUTSIDE the guest over QMP and cannot
#      perturb the segment. Only after the hand has been taken off the mouse
#      does the guest read its own window table -- and it reads it with a
#      binary of the same wsys version as the segment it is reading (a copy of
#      the published `cat`, stashed at /probe-cat before the update, for the
#      stages where the session is still v6).
#
# THE WITNESSES, none of which is a version string
# ================================================
#   * THE FRAMEBUFFER, over QMP `screendump`, compared with ppmdiff.py. "Does
#     the screen go black" is a question about pixels and is answered in pixels.
#   * A REAL POINTER on `-device virtio-tablet-pci` and REAL KEYSTROKES on
#     `-device virtio-keyboard-pci`. A desktop that is up and ignores the
#     keyboard is a FAILURE, not a pass -- and it is exactly the shape a v6
#     client parked on the now-dead keys ring would produce.
#   * THE SEGMENT'S SIZE. `ls -l /srv` -- 19,052,956 bytes is a 256-row window
#     table, 37,972,380 a 512-row one. That is sizeof(struct wshm); no index
#     field and no hpm database edit can fake it. (At 6 -> 7 that number WAS
#     the version. At 7 -> 8 it is not -- see THE SECOND BUMP below, which is
#     where this gate's version witness now comes from.)
#   * THE COMPOSITOR'S AND THE PANEL'S OWN LOGS, /var/log/{wsysd,panel,
#     hamdesktop}.log, tailed at the end of every stage.
#
# NO VERSION NUMBER IS HARD-CODED. The published version is READ from the live
# index at run time and the local channel is derived strictly above it. Nothing
# is published: the update is served by python3 -m http.server on the loopback,
# signed with a key minted for the run.
#
# WHAT THIS GATE MEASURED, AND WHAT WAS DONE ABOUT IT
# ====================================================
# The first run answered the question and the answer was worse than the comment
# claimed.  At STAGE C the screen became THREE DISTINCT COLOURS over 1,024,000
# pixels -- a featureless dark-blue slab and a mouse cursor -- where STAGE B had
# 1,474; the compositor reported `windows 0`; /srv/wsys had grown from
# 19,052,956 bytes to 37,972,380; and nothing between `hpm update` finishing and
# the desktop vanishing had mentioned the window system, a session or a restart.
# The compositor kept running, kept counting keystrokes, kept owning /dev/fb and
# painted nothing.  There was no panel and nothing to click.
#
# user/linux-wsys.c now REFUSES rather than wipes: a build meeting a segment of
# another version that some LIVE process still holds a window in declines to
# attach, says so by name on stderr, and changes not one byte of it.  A
# LEFTOVER segment -- nobody holding a row -- is still re-initialised, which is
# what keeps the first program after a boot working.  So this file now asks
# four more questions, and all four are about STAGE C:
#
#   * IS THE SEGMENT STILL THERE?  /srv/wsys must still be 19,052,956 bytes
#     after the new binary has met it.  This is the whole fix in one number.
#   * IS THE SCREEN STILL A DESKTOP?  Answered in pixels, and specifically in
#     DISTINCT COLOURS, because that is what told the slab apart from a desktop:
#     a wallpaper with a panel and windows on it is over a thousand, the slab is
#     three.  Also that the screen at C is substantially the screen at B.
#   * DOES THE WINDOW TABLE STILL HOLD THE SESSION'S WINDOWS?  `windows 0` was
#     the shape of the failure; the count at C must equal the count at B.
#   * DID IT SAY SO?  The refused binary must print the refusal BY NAME.  A
#     program that silently declines to draw is the same success-shaped silence
#     in a smaller box.
#
# AND ONE CONTROL, because "refuse" that cannot be switched off is a machine
# that never boots again: THE LEFTOVER CONTROL at the end of phase 2 makes a
# v6 segment with a PUBLISHED binary that then exits, so no process holds a row
# in it, and requires this tree's binary to re-initialise it -- 19,052,956 ->
# 37,972,380 bytes -- in the same boot in which /srv/wsys was refused.  One run,
# both answers, so "live" and "leftover" are demonstrably being told apart and
# not merely asserted.
#
# WHAT THIS FILE DELIBERATELY DOES NOT FAIL ON, and it is measured every run.
# STAGE B -- the desktop stops answering the mouse the instant `hpm update`
# finishes, while the segment is still v6 and before anything has been
# relaunched -- is a SEPARATE defect with a separate cause, and it was already
# here before this pass (baseline: the STAGE B click moved 234 px against 43,666
# at STAGE A).  It is reported as a FINDING, not a failure, because a gate that
# goes red for somebody else's bug stops being read.  Its consequence for THIS
# gate is named rather than worked around: because the panel is not answering
# clicks at B, the STAGE C CLICK cannot pass either, so the evidence that the
# session survived C is the segment, the pixels and the window table -- none of
# which depends on the panel answering.
#
# AT 7 -> 8 THAT DEFECT DID NOT REPRODUCE, and the paragraph above is kept as
# history rather than rewritten because it is what the 6 -> 7 run measured.
# The 1.0.19 -> 1.0.20 run: the STAGE B click moved 31,762 px against a 113 px
# noise floor, the panel and the taskbar were `visible` 1 at A and at B, and the
# panel logged two config reloads and survived them.  So the STAGE C click is
# no longer excused by B -- see WHY THE CLICK AT C CAN LEGITIMATELY DO NOTHING,
# which replaces the excuse with two measurements.
#
# =========================================================================
# THE SECOND BUMP THIS GATE HAS MEASURED: 7 -> 8, AND WHY IT NEEDED A NEW SET
# OF WITNESSES
# =========================================================================
# Everything above was written for 6 -> 7, where the refusal did not yet exist
# in the binary the machine was RUNNING -- so what it measured was v7 binaries
# not wiping a v6 session.  WSYS_VERSION is 8 now (the v1 display list left the
# world-readable segment for a per-window memfd, tests/linux/wsys_bypass.sh),
# the published channel is v7, and THIS is the first bump where the refusal
# that shipped in v7 is the RUNNING code that has to protect a real person.
#
# THE SIZE STOPPED BEING A WITNESS, and that is a fact about v8 and not a
# weakening of this file.  6 -> 7 doubled the table, so `ls -l /srv` told the
# two versions apart by 19,052,956 against 37,972,380.  v8's struct wshm is
# BYTE-FOR-BYTE v7's -- 512 rows, 37,972,380 bytes, only the MEANING of the
# scene buffers changed -- so a size is no longer an answer to "which window
# system is this session".  Substituted, and each is a real read of the bytes
# rather than an inference:
#
#   * THE REFUSAL'S OWN WORDS.  The refused v8 binary prints the version it
#     found in the header it just pread(2)'d.  At STAGE C that number must be
#     the OLD one -- i.e. after the update, the live segment is still what the
#     desktop made -- and the version it names for itself must be this tree's
#     WSYS_VERSION, which is read out of user/linux-wsys.c and not typed here.
#   * THE WINDOW TABLE AND THE PIXELS, exactly as before: the count at C must
#     equal the count at B, and the screen must still be a desktop.
#   * THE SIZE, still checked, but now as "the file was not resized or
#     truncated under the person" and no longer as a version.
#   * THE LEFTOVER CONTROL IS NOW A FOUR-POINT md5 SIGNATURE.  A leftover
#     segment re-initialised in place does not change size at all at 7 -> 8, so
#     the control drives the same file through four attaches and asserts the
#     shape of the sequence: published-makes-it (m1), this tree's binary meets
#     it (m2), this tree's binary meets it again (m3), the published binary
#     meets it again (m4).  m1 != m2 is the re-initialise; m2 == m3 is "it
#     recognised its own and wrote nothing"; m3 != m4 is the old build taking
#     it back; and m4 == m1 is the control on the control -- a fresh segment is
#     deterministic, so the only thing the differences can be is the version
#     word.  A single "it changed" could have been an innocent write; this
#     two-state ping-pong could not.
#
# Usage: tests/linux/installed_update_wsysver.sh [b1s] [b2s] [b3s]
#   HAMLINUX_WV_REUSE=1   reuse the disk built by an earlier run
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"
. tests/linux/reap.sh

export HAMLINUX_VNC="${HAMLINUX_VNC:-none}"
export HAMLINUX_DISTRO_RO="${HAMLINUX_DISTRO_RO:-1}"
export TMPDIR="${TMPDIR:-$PROJ_ROOT/build/tmp}"
mkdir -p "$TMPDIR"

WAIT1="${1:-900}"
WAIT2="${2:-1500}"
WAIT3="${3:-480}"
PKG=hamnix-desktop
BIN=/bin/wsysd
CHANNEL_URL="${HAMLINUX_WV_URL:-https://255.one/linux/index.json}"

WORK="${HAMLINUX_WV_WORK:-$HOME/.hamnix-build/wsysver}"; mkdir -p "$WORK"
SHOT="$WORK/shots"; mkdir -p "$SHOT"
IMG=build/image
DISK="$WORK/wsysver.img"
REPO="${HAMLINUX_WV_REPO:-build/repo}"
EXTRA="$WORK/extra"
QMP="$WORK/qmp.sock"

reap_track "$WORK/reaped"

# THE SEGMENT SIZE, AND WHAT IT CAN AND CANNOT ANSWER NOW.  256 rows is
# 19,052,956 bytes and 512 rows is 37,972,380; v7 AND v8 are both 512 rows, so
# at this bump the size distinguishes NOTHING about the version and is used
# only to say the file was not resized under a running desktop.  Kept as three
# names so a future bump that DOES move the size still has them.
V6_BYTES=19052956
V7_BYTES=37972380
SEG_BYTES=37972380
# THIS TREE'S WINDOW-SYSTEM VERSION, READ FROM THE SOURCE.  No version number
# in this file is typed by hand -- not the package version (taken off the live
# index above) and not this one.
NEWWSYS="$(sed -n 's/^#define WSYS_VERSION *\([0-9][0-9]*\).*/\1/p' user/linux-wsys.c | head -1)"
[ -n "$NEWWSYS" ] || { echo "FAIL: cannot read WSYS_VERSION out of user/linux-wsys.c" >&2; exit 1; }

fail=0
say() { echo "[wv] $*"; }
[ -f "$IMG/vmlinuz" ] || { echo "no image; run scripts/hamlinux_image.sh" >&2; exit 1; }
command -v python3 >/dev/null || { echo "need python3" >&2; exit 1; }

# =========================================================================
# 1. WHAT IS PUBLISHED RIGHT NOW, ASKED RATHER THAN ASSUMED.
# =========================================================================
say "asking $CHANNEL_URL what it serves"
curl -fsS --max-time 60 "$CHANNEL_URL" -o "$WORK/live-index.json" || {
    echo "FAIL: cannot reach $CHANNEL_URL -- the machine under test has to be" >&2
    echo "      installed at the CURRENT PUBLISHED version and nothing else" >&2
    echo "      can say what that is." >&2; exit 1; }
LIVEVER="$(PKG="$PKG" python3 - "$WORK/live-index.json" <<'PY'
import json, os, sys
d = json.load(open(sys.argv[1]))
for r in d["packages"]:
    if r["name"] == os.environ["PKG"]:
        print(r["version"]); break
PY
)"
[ -n "$LIVEVER" ] || { echo "FAIL: the channel carries no $PKG at all" >&2; exit 1; }
NEWVER="${HAMLINUX_WV_NEWVER:-$(LIVEVER="$LIVEVER" python3 <<'PY'
import os
a, b, c = (int(x) for x in os.environ["LIVEVER"].split("."))
print("%d.%d.%d" % (a, b, c + 1))
PY
)}"
NEWVER="$NEWVER" LIVEVER="$LIVEVER" python3 <<'PY' || {
import os, sys
def key(v): return [int(x) for x in v.split(".")]
sys.exit(0 if key(os.environ["NEWVER"]) > key(os.environ["LIVEVER"]) else 1)
PY
    echo "FAIL: $NEWVER does not sort above the published $LIVEVER" >&2; exit 1; }
say "published: $PKG $LIVEVER. This tree will be offered as $NEWVER."

LIVE_URL="$(PKG="$PKG" python3 - "$WORK/live-index.json" <<'PY'
import json, os, sys
d = json.load(open(sys.argv[1]))
base = d.get("url", "")
for r in d["packages"]:
    if r["name"] == os.environ["PKG"]:
        u = r["url"]
        print(u if u.startswith("http") else base.rstrip("/") + "/" + u); break
PY
)"
curl -fsS --max-time 300 "$LIVE_URL" -o "$WORK/live-pkg.tar.gz" || {
    echo "FAIL: cannot download the published $PKG" >&2; exit 1; }
rm -rf "$WORK/liveunpack"; mkdir -p "$WORK/liveunpack"
tar xzf "$WORK/live-pkg.tar.gz" -C "$WORK/liveunpack" || {
    echo "FAIL: the published tarball did not unpack" >&2; exit 1; }
LIVE_WSYSD="$WORK/liveunpack/$PKG-$LIVEVER/files${BIN}"
[ -f "$LIVE_WSYSD" ] || { echo "FAIL: the published $PKG carries no $BIN" >&2; exit 1; }
LIVE_MD5="$(md5sum "$LIVE_WSYSD" | cut -d' ' -f1)"
say "the published $BIN is md5 $LIVE_MD5"

NEW_TAR="$REPO/linux/packages/$PKG-$NEWVER.tar.gz"
[ -f "$NEW_TAR" ] || {
    echo "FAIL: no $NEW_TAR -- build the channel first:" >&2
    echo "  python3 scripts/hamlinux_packages.py --out $REPO --version $NEWVER \\" >&2
    echo "      --channel linux --base-url http://10.0.2.2:9999/" >&2; exit 1; }
rm -rf "$WORK/newunpack"; mkdir -p "$WORK/newunpack"
tar xzf "$NEW_TAR" -C "$WORK/newunpack" || {
    echo "FAIL: the local tarball did not unpack" >&2; exit 1; }
NEW_MD5="$(md5sum "$WORK/newunpack/$PKG-$NEWVER/files$BIN" | cut -d' ' -f1)"
[ "$NEW_MD5" != "$LIVE_MD5" ] || {
    echo "FAIL: this tree's $BIN is byte-identical to the published one, so" >&2
    echo "      there is no window-system change to measure the effect of." >&2
    exit 1; }
say "this tree's $BIN is md5 $NEW_MD5"

# =========================================================================
# 2. Serve the local channel, signed, on the loopback. NOTHING IS PUBLISHED.
# =========================================================================
PORT="$(python3 - <<'PY'
import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()
PY
)"
BASE="http://10.0.2.2:$PORT/"
python3 - "$REPO/linux/index.json" "$BASE" <<'PY' || {
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["url"] = sys.argv[2]
with open(p, "w") as fh:
    json.dump(d, fh, indent=2); fh.write("\n")
PY
    echo "FAIL: could not re-point the local index" >&2; exit 1; }

mkdir -p "$EXTRA/etc/hpm"
python3 scripts/hpm_sign.py keygen --out-pub "$EXTRA/etc/hpm/wv-trusted.pub" \
    --out-sec "$WORK/wv.sec" >/dev/null || {
    echo "FAIL: cannot mint a signing key" >&2; exit 1; }
python3 scripts/hpm_sign.py sign "$REPO/linux/index.json" "$WORK/wv.sec" \
    "$REPO/linux/index.json.sig" || {
    echo "FAIL: cannot sign the local index" >&2; exit 1; }

python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$REPO" \
    >"$WORK/http.log" 2>&1 &
HTTPD=$!; reap_add "$HTTPD"
sleep 1
curl -fsS "http://127.0.0.1:$PORT/linux/index.json" >/dev/null || {
    echo "FAIL: the local channel is not being served" >&2; exit 1; }
say "this tree's channel is served at $BASE (pid $HTTPD)"

cleanup() { rm -f "$QMP"; }
reap_on_exit cleanup

# =========================================================================
# 3. The three boot scripts.
# =========================================================================
mkdir -p "$EXTRA/etc"

# THE PROBE, AND WHY IT TAKES THE `cat` TO USE AS AN ARGUMENT. A wsys client
# reading another build's segment re-initialises it -- that is the whole
# subject of this gate -- so the inspector must be the same version as the
# thing inspected. /probe-cat is the PUBLISHED cat, stashed on the disk before
# the update; /bin/cat is whatever the machine has now.
_probe() {   # _probe <tag> <cat>
    cat <<W
echo '[wv] WINS-$1'
$2 '/dev/wsys/2/ctl'
$2 '/dev/wsys/3/ctl'
$2 '/dev/wsys/4/ctl'
$2 '/dev/wsys/5/ctl'
$2 '/dev/wsys/6/ctl'
echo '[wv] WINS-END-$1'
echo '[wv] TITLES-$1:'
$2 '/dev/wsys/windows'
echo '[wv] STATE-$1:'
$2 '/dev/wsys/wsysd/state'
echo '[wv] SEG-$1:'
ls -l /srv
echo '[wv] DELOG-$1 wsysd:'
tail -6 /var/log/wsysd.log
echo '[wv] PANELCONF-$1:'
ls -l /etc/panel.conf
echo '[wv] DELOG-$1 panel:'
tail -30 /var/log/panel.log
echo '[wv] DELOG-$1 desktop:'
tail -6 /var/log/hamdesktop.log
echo '[wv] PROBE-END-$1'
W
}

# ---- phase 1: become a machine running the CURRENT PUBLISHED system ----
cat > "$WORK/rc.phase1" <<RC
source '/etc/rc.boot.installed'
echo '[wv] ===== PHASE 1: install the CURRENTLY PUBLISHED system ($LIVEVER)'
date
dhcpc
echo '[wv] p1 dhcpc status:' \$status
echo '[wv] p1 refresh (the real repository, the shipped trusted key)'
hpm refresh
echo '[wv] p1 refresh status:' \$status
# THE WHOLE PUBLISHED USERLAND, not just the desktop. hamnix-base pulls
# coreutils, hamsh, net, hpm, the drivers and the desktop -- so after this the
# machine is what a person who installed hamnix-linux and ran \`hpm update\`
# today HAS, and nothing on it is newer than the window system it is running.
# (The backslashes are not decoration: this heredoc is UNQUOTED, so the
# backticks ran \`hpm update\` ON THE HOST every time this gate started -- it
# printed "hpm: command not found" and ate the words out of the comment. A
# host with hpm on its PATH would have had its own machine updated by a
# comment in a test.)
echo '[wv] p1 install hamnix-base'
hpm install hamnix-base
echo '[wv] p1 install status:' \$status
echo '[wv] p1 list:'
hpm list
echo '[wv] p1 md5 of $BIN:'
md5sum $BIN
# The inspector for the stages where the session is still the published one.
cp /bin/cat /probe-cat
echo '[wv] p1 md5 of /bin/cat and /probe-cat:'
md5sum /bin/cat /probe-cat
echo '[wv] PHASE1 DONE'
cp /etc/rc.phase2 /etc/rc.boot
reboot
RC

# ---- phase 2: the machine a person is sitting in front of ----
{
cat <<RC
source '/etc/rc.boot.installed'
echo '[wv] ===== PHASE 2: a desktop is up, with a window open, and the'
echo '[wv]               owner runs hpm update.'
date
dhcpc
echo '[wv] p2 dhcpc status:' \$status
echo '[wv] p2 md5 of $BIN (this is the PUBLISHED compositor):'
md5sum $BIN
# rc.boot.installed ends by sourcing /etc/rc.d/rc.5; give the desktop the time
# a desktop takes.
sleep 20
# THE USER OPENS A TERMINAL, through the DE's own launch queue -- the file
# hampanelscene's Applications menu writes. The RUNNING panel spawns it, so
# this is the launch path a person's click takes and not a side door.
echo '[wv] p2 opening a terminal through the DE launch queue'
echo '/bin/hamtermscene' > '/dev/wsys/run/launch'
sleep 14
# THE HOST'S HAND GOES ON THE MOUSE HERE, AND NOTHING IN THIS GUEST TOUCHES
# /dev/wsys UNTIL IT IS OFF AGAIN.
echo '[wv] MARK-A'
sleep 60
RC
_probe A /probe-cat
cat <<RC

echo '[wv] p2 ----- hpm refresh against the local channel'
hpm --repo=$BASE --trusted-key=/etc/hpm/wv-trusted.pub refresh
echo '[wv] p2 refresh status:' \$status
echo '[wv] p2 ----- hpm update'
hpm --repo=$BASE --trusted-key=/etc/hpm/wv-trusted.pub update
echo '[wv] p2 update status:' \$status
echo '[wv] p2 list after update:'
hpm list
echo '[wv] p2 md5 of $BIN after update:'
md5sum $BIN
echo '[wv] p2 THE UPDATE HAS RUN AND NOTHING HAS BEEN RESTARTED'
sleep 4
echo '[wv] MARK-B'
sleep 60
RC
_probe B /probe-cat
cat <<RC

echo '[wv] p2 ----- the owner opens one more app, the ordinary next thing'
echo '/bin/hamtermscene' > '/dev/wsys/run/launch'
sleep 18
echo '[wv] MARK-C'
sleep 60
RC
# THE INSPECTOR AT C IS STILL THE PUBLISHED cat, AND THAT IS THE POINT.
# It used to be /bin/cat here, on the reasoning that by stage C the session had
# already been flipped to v7 by the app that was opened, so the new binary was
# the matching one.  If the session SURVIVES, that reasoning inverts: /srv/wsys
# is still v6, so v6 is still the build that may read it, and a v7 /bin/cat
# reading it would be one more client attaching -- the very act under test.
# The v7 attach is driven DELIBERATELY, once, immediately below, where its
# refusal is the measurement rather than a side effect of taking one.
cat <<RC

echo '[wv] REFUSE-C:'
/bin/cat '/dev/wsys/windows'
echo '[wv] p2 refuse status:' \$status
echo '[wv] REFUSE-END-C'
RC
_probe C /probe-cat
cat <<RC

# THE NEXT BOOT IS ARMED HERE, BEFORE THE CONTROL BELOW AND NOT AFTER IT.
# The first version of this file armed it last, and the leftover control --
# which is the newest and least-exercised code in the guest -- aborted the rc
# with a parse error, so phase 3 never got installed and boot 3 ran PHASE 2
# again on a disk that was already updated. The measurement of the reboot was
# lost to a bug in a control taken after it. Anything below this line can now
# fail without costing the boot that follows.
cp /etc/rc.phase3 /etc/rc.boot

# THE LEFTOVER CONTROL.  Everything above is about a segment somebody is USING.
# A segment nobody is using must still be re-initialised, or the first program
# after a boot never starts and the machine is bricked in a new way.  Both
# answers are taken in this one boot, seconds apart, so the two cases are
# demonstrably being told apart:
#   * the PUBLISHED cat creates /stale/wsys, a segment of the PUBLISHED
#     version, and EXITS -- so no process holds a row in it;
#   * this tree's cat meets it and must RE-INITIALISE it.
#
# AT 6 -> 7 THAT SHOWED UP AS A SIZE (19,052,956 -> 37,972,380).  At 7 -> 8 the
# two layouts are the same size, so the file is driven through four attaches
# and the SEQUENCE of md5s is the witness -- see THE SECOND BUMP at the top of
# this file.  md5sum is on the machine already (the phase-1 rc uses it on
# /bin/wsysd), so this needs nothing the published userland does not have.
#
# THE QUOTES AND THE ABSENT SPACES ARE LOAD-BEARING. hamsh's assignment is
# \`NAME='value'\`: written \`HAMWSYS = /stale/wsys\` the right-hand side is
# parsed as a NAME and the rc dies with "undefined name '/stale/wsys' -- glued
# arithmetic?", which is exactly how the first run of this control lost its
# phase 3. etc/rc.de-user carries the same warning over its own HOME=.
mkdir '/stale'
HAMWSYS='/stale/wsys'
export HAMWSYS
echo '[wv] p2 ----- THE LEFTOVER CONTROL'
/probe-cat '/dev/wsys/windows'
echo '[wv] p2 stale make status:' \$status
echo '[wv] STALE-BEFORE:'
ls -l /stale
echo '[wv] STALE-MD5-1:'
md5sum /stale/wsys
/bin/cat '/dev/wsys/windows'
echo '[wv] p2 stale use status:' \$status
echo '[wv] STALE-AFTER:'
ls -l /stale
echo '[wv] STALE-MD5-2:'
md5sum /stale/wsys
/bin/cat '/dev/wsys/windows'
echo '[wv] p2 stale reuse status:' \$status
echo '[wv] STALE-MD5-3:'
md5sum /stale/wsys
/probe-cat '/dev/wsys/windows'
echo '[wv] p2 stale back status:' \$status
echo '[wv] STALE-MD5-4:'
md5sum /stale/wsys
HAMWSYS='/srv/wsys'
export HAMWSYS
date
echo '[wv] PHASE2 DONE'
reboot
RC
} > "$WORK/rc.phase2"

# ---- phase 3: does the machine come back healthy on the new version? ----
{
cat <<RC
source '/etc/rc.boot.installed'
echo '[wv] ===== PHASE 3: the same disk, rebooted. Is it healthy?'
date
sleep 20
echo '[wv] p3 list:'
hpm list
echo '[wv] p3 md5 of $BIN:'
md5sum $BIN
echo '[wv] p3 opening a terminal through the DE launch queue'
echo '/bin/hamtermscene' > '/dev/wsys/run/launch'
sleep 14
echo '[wv] MARK-D'
sleep 60
RC
_probe D /bin/cat
cat <<'RC'
date
echo '[wv] PHASE3 DONE'
reboot
RC
} > "$WORK/rc.phase3"

cp "$WORK/rc.phase2" "$EXTRA/etc/rc.phase2"
cp "$WORK/rc.phase3" "$EXTRA/etc/rc.phase3"

# =========================================================================
# 4. Install a disk.
# =========================================================================
if [ "${HAMLINUX_WV_REUSE:-0}" = 1 ] && [ -f "$DISK" ]; then
    say "reusing $DISK (HAMLINUX_WV_REUSE=1)"
else
    say "building the installed disk"
    HAMLINUX_DISK_RC="$WORK/rc.phase1" HAMLINUX_DISK_EXTRA="$EXTRA" \
        nice -n 15 scripts/hamlinux_disk.sh "$DISK" 3G >"$WORK/build.log" 2>&1 || {
        echo "FAIL disk build"; tail -20 "$WORK/build.log"; exit 1; }
fi

# =========================================================================
# 5. Boot it, and put a hand on the mouse and the keyboard.
# =========================================================================
APPBTN_X=40; APPBTN_Y=13
NEUTRAL_X=900; NEUTRAL_Y=600
SCREEN_W=1280; SCREEN_H=800

Q() { python3 tests/linux/qmp_input.py "$QMP" "$@" >>"$LOGCLICK" 2>&1; }
shot() { Q screendump "$SHOT/$1.ppm"; }

# THE HAND, identical at A, B, C and D so the four answers are comparable:
# photograph twice (the noise floor), click Applications, photograph, dismiss,
# photograph, type into whatever has focus, photograph.
stage_hand() {   # stage_hand <tag>
    local t="$1"
    sleep 3
    shot "$t-1-idle"
    sleep 3
    shot "$t-2-idle"
    Q click "$APPBTN_X" "$APPBTN_Y" "$SCREEN_W" "$SCREEN_H"
    sleep 3
    shot "$t-3-menu"
    Q click "$NEUTRAL_X" "$NEUTRAL_Y" "$SCREEN_W" "$SCREEN_H"
    sleep 3
    shot "$t-4-dismissed"
    Q type "wsysprobe"
    sleep 3
    shot "$t-5-typed"
}

waitmark() {   # waitmark <log> <marker> <deadline-seconds>
    local i=0
    while [ "$i" -lt "$(( $3 * 2 ))" ]; do
        grep -aq "$2" "$1" && return 0
        kill -0 "$VM" 2>/dev/null || return 1
        sleep 0.5; i=$((i + 1))
    done
    return 1
}

boot() {   # boot <logfile> <seconds> <marker>...
    local log="$1" secs="$2"; shift 2
    LOG="$log"; LOGCLICK="$log.qmp"
    rm -f "$QMP"
    ( sleep 5 ) | HAMLINUX_DISK="$DISK" \
        timeout "$((secs + 30))" scripts/hamlinux_vm.sh disk --timeout "$secs" \
        -qmp "unix:$QMP,server=on,wait=off" >"$log" 2>&1 &
    VM=$!; reap_add "$VM"
    local m
    for m in "$@"; do
        if waitmark "$log" "MARK-$m" "$secs"; then
            say "  stage $m: the guest is ready; taking the screen and the mouse"
            stage_hand "$m"
        else
            say "  stage $m: the marker never came"
        fi
    done
    wait "$VM" 2>/dev/null
    VM=""
}

say "boot 1 of 3: install the published system (up to ${WAIT1}s)"
boot "$WORK/boot1.log" "$WAIT1"
say "boot 2 of 3: the live update, in three stages (up to ${WAIT2}s)"
boot "$WORK/boot2.log" "$WAIT2" A B C
say "boot 3 of 3: is the machine healthy after a reboot (up to ${WAIT3}s)"
boot "$WORK/boot3.log" "$WAIT3" D

# =========================================================================
# 6. What happened.
# =========================================================================
for n in 1 2 3; do
    echo; echo "--------- boot $n transcript"
    grep -aE '^\[wv\]|^rc\.boot:|^\[rc\.5\]|^hpm:|^cat: |^[0-9]+ [0-9]+ [0-9]+ [0-9]+ |^focus [0-9]|wsys$' \
        "$WORK/boot$n.log" | tr -d '\r'
done
echo

pp() { python3 tests/linux/ppmdiff.py "$@" 2>&1; }
ppn() {  # ppn <a> <b> -- just the number of differing pixels
    pp diff "$1" "$2" | sed -n 's/.*: \([0-9]*\) of .*/\1/p;s/.*IDENTICAL.*/0/p' | head -1
}
statefield() {   # statefield <log> <tag> <field>
    grep -aA1 -F "STATE-$2:" "$1" | tail -1 | tr -d '\r' |
        awk -v f="$3" '{for (i = 1; i < NF; i++) if ($i == f) print $(i+1)}'
}
sizeat() {   # sizeat <log> <marker> -- the size of the `wsys` line after <marker>
    # The \r comes off the serial console and made $NF "wsys\r", which matched
    # nothing and printed an empty size next to the one number in this gate
    # that says which window system the session IS. Strip it first, not after.
    tr -d '\r' <"$1" |
        awk -v m="$2" 'index($0, m) {inb=1; next}
                       inb && $NF == "wsys" {print $(NF-1); exit}
                       inb && index($0, "DELOG") {exit}'
}
segsize() {   # segsize <log> <tag>
    sizeat "$1" "SEG-$2:"
}
# HOW MANY COLOURS ARE ON THE SCREEN.  The slab and a desktop are told apart by
# this number and by nothing else that is cheap: a wallpaper with a panel, a
# taskbar and windows on it is over a thousand distinct colours, and the
# featureless slab the first run photographed is THREE (the fill, plus 117 px
# of mouse cursor).  ppmdiff.py `rect` prints "N distinct of M px".
distinct() {   # distinct <ppm>
    pp rect "$1" | sed -n 's/.*: \([0-9]*\) distinct of .*/\1/p' | head -1
}
wins() {   # wins <log> <tag>
    awk -v m="WINS-$2" 'index($0,m){i=1;next} i&&index($0,"WINS-END"){exit}
                        i&&NF>=6&&$1~/^[0-9]+$/{printf "(%s) ", $0}' "$1" | tr -d '\r'
}

# IS A GIVEN WINDOW MARKED VISIBLE?  `cat /dev/wsys/<wid>/ctl` prints
# `wid x y w h z decorate visible proto ...`, so field 8 is `visible`. This is
# the field that tells "the panel is gone" apart from "the panel is there and
# the click missed it", and it is the field that named the SEPARATE defect
# below: wids 3 and 4 -- the top panel and the bottom taskbar -- go 1 -> 0 the
# instant `hpm update` finishes, with the segment still v6.
visfield() {   # visfield <log> <tag> <wid>
    awk -v m="WINS-$2" -v w="$3" '
        index($0,m){i=1;next} i&&index($0,"WINS-END"){exit}
        i&&$1==w&&NF>=8{print $8; exit}' "$1" | tr -d '\r'
}

report_stage() {   # report_stage <log> <tag> <headline>
    local L="$1" s="$2"
    echo
    echo "--- STAGE $s: $3"
    echo "    the screen:      $(pp rect "$SHOT/$s-1-idle.ppm")"
    local noise click typed
    noise="$(ppn "$SHOT/$s-1-idle.ppm" "$SHOT/$s-2-idle.ppm")"
    click="$(ppn "$SHOT/$s-2-idle.ppm" "$SHOT/$s-3-menu.ppm")"
    typed="$(ppn "$SHOT/$s-4-dismissed.ppm" "$SHOT/$s-5-typed.ppm")"
    echo "    idle -> idle:    $noise px changed  (the noise floor: a cursor, a clock)"
    echo "    Applications ->  $click px changed  $(pp diff "$SHOT/$s-2-idle.ppm" "$SHOT/$s-3-menu.ppm" | sed 's/^[^;]*; //')"
    echo "    typing ->        $typed px changed"
    echo "    distinct colours: $(distinct "$SHOT/$s-1-idle.ppm")  (a desktop is >1000; the slab was 3)"
    echo "    window table:    $(wins "$L" "$s")"
    echo "    titles:          $(grep -aA6 -F "TITLES-$s:" "$L" | sed -n '2,6p' | tr -d '\r' | grep -v '^\[wv\]' | tr '\n' '|')"
    echo "    wsysd state:     $(grep -aA1 -F "STATE-$s:" "$L" | tail -1 | tr -d '\r')"
    echo "    /srv/wsys:       $(segsize "$L" "$s") bytes  (256 rows=$V6_BYTES, 512 rows=$V7_BYTES -- v7 AND v8 are 512)"
    echo "    wsysd log:       $(grep -aA6 -F "DELOG-$s wsysd:" "$L" | sed -n '2,7p' | tr -d '\r' | tr '\n' '|')"
    echo "    /etc/panel.conf: $(grep -aA1 -F "PANELCONF-$s:" "$L" | tail -1 | tr -d '\r')"
    echo "    panel reloads:   $(grep -aA30 -F "DELOG-$s panel:" "$L" | tr -d '\r' | grep -c 'config reload applied')"
    echo "    panel log:       $(grep -aA30 -F "DELOG-$s panel:" "$L" | tr -d '\r' | grep -vE '^\[panelbeacon\]|^\[wv\]' | sed -n '2,8p' | tr '\n' '|')"
    echo "    panel beacon:    $(grep -aA30 -F "DELOG-$s panel:" "$L" | tr -d '\r' | grep '^\[panelbeacon\]' | tail -1)"
    python3 tests/linux/ppmdiff.py png "$SHOT/$s-1-idle.ppm" "$SHOT/$s-1-idle.png" >/dev/null 2>&1
    python3 tests/linux/ppmdiff.py png "$SHOT/$s-3-menu.ppm" "$SHOT/$s-3-menu.png" >/dev/null 2>&1
}

echo "=========================================================="
echo " WHAT A PERSON SEES WHEN THEY UPDATE A RUNNING DESKTOP"
echo "=========================================================="
report_stage "$WORK/boot2.log" A "before the update -- the published $LIVEVER desktop"
report_stage "$WORK/boot2.log" B "hpm update has run; nothing has been relaunched"
report_stage "$WORK/boot2.log" C "the person opens one more app"
report_stage "$WORK/boot3.log" D "after a reboot, on the new $NEWVER"

echo
echo "--- DID ANYTHING TELL THE PERSON?"
sed -n '/p2 update status/,/the owner opens one more app/p' "$WORK/boot2.log" |
    tr -d '\r' | grep -aiE 'wsys|window|restart|log ?out|session|reboot' |
    grep -avE '^\[wv\]' | head -20
echo "(everything the machine said about the window system, a restart or a"
echo " session, between the update finishing and the next app opening)"

echo
echo "=========================================================="
echo " THE QUESTIONS"
echo "=========================================================="
check() { if grep -aqE "$2" "$3"; then echo "wv: PASS $1"
          else echo "wv: FAIL $1"; fail=1; fi; }
# "The desktop answered the click" -- in pixels, with the stage's own noise
# floor as the control. An Applications menu is a 200x250 card; a cursor is
# a few hundred pixels.
answered() {   # answered <tag> -- 0 if the click opened something
    local n c
    n="$(ppn "$SHOT/$1-1-idle.ppm" "$SHOT/$1-2-idle.ppm")"
    c="$(ppn "$SHOT/$1-2-idle.ppm" "$SHOT/$1-3-menu.ppm")"
    [ -n "$n" ] && [ -n "$c" ] || return 1
    [ "$c" -gt 5000 ] && [ "$c" -gt "$((n * 5 + 500))" ]
}

check "the installed root came online"  'rc\.boot: hamnix-linux \(installed\)' "$WORK/boot1.log"
check "the published system installed"  '\[wv\] p1 install status: 0'          "$WORK/boot1.log"
if grep -aA3 -F '[wv] p1 md5 of /bin/wsysd' "$WORK/boot1.log" | grep -aq "$LIVE_MD5"; then
    echo "wv: PASS the machine is running the PUBLISHED compositor (md5 $LIVE_MD5)"
else
    echo "wv: FAIL the machine is not running the published compositor"; fail=1
fi

if answered A; then
    echo "wv: PASS STAGE A the published desktop WORKS: a real click on the Applications button opened the menu"
else
    echo "wv: FAIL STAGE A the published desktop did not answer a real click -- the control is broken and nothing after it means anything"
    fail=1
fi
ASEG="$(segsize "$WORK/boot2.log" A)"
# THE SIZE IS NOT THE VERSION AT THIS BUMP.  It says how many ROWS the running
# session's table has, and both the published window system and this tree's
# have 512.  Which VERSION the session is comes from the refusal below, which
# is the new binary reading the header it refused to attach to.
[ "$ASEG" = "$SEG_BYTES" ] &&
    echo "wv: PASS STAGE A the running session's window table is the expected $ASEG bytes (512 rows)" ||
    echo "wv: NOTE STAGE A /srv/wsys is ${ASEG:-?} bytes (256 rows=$V6_BYTES, 512 rows=$V7_BYTES)"

check "hpm update exited 0" '\[wv\] p2 update status: 0' "$WORK/boot2.log"
if grep -aA3 -F '[wv] p2 md5 of /bin/wsysd after update:' "$WORK/boot2.log" | grep -aq "$NEW_MD5"; then
    echo "wv: PASS the new compositor is ON DISK (md5 $NEW_MD5)"
else
    echo "wv: FAIL the update did not put this tree's compositor on the disk"; fail=1
fi

if answered B; then
    echo "wv: PASS STAGE B the desktop still answers the mouse right after the update"
else
    echo "wv: FINDING STAGE B the desktop stopped answering the mouse as soon as the update finished, before anything was relaunched"
fi

CWIN="$(statefield "$WORK/boot2.log" C windows)"
BWIN="$(statefield "$WORK/boot2.log" B windows)"
# WHY THE CLICK AT C CAN LEGITIMATELY DO NOTHING, and why that must be told
# apart from a dead panel rather than excused in a sentence.
#
# The Applications button is not a menu. It SPAWNS one -- /bin/hamappmenu --
# and after the update that binary is this tree's, so it meets the running
# session, refuses, and never maps a window. The panel is the pre-update
# process and answers perfectly; the person sees the button react and no menu.
# So a C click that moves few pixels is EXPECTED at a version bump, and the
# evidence for that is the panel's own log (it recorded the click and the
# spawn) plus the refusal the spawned program printed. If those are absent,
# something else is wrong and it is reported as exactly that.
#
# The previous pass excused this line with "STAGE B does not answer either".
# At 7 -> 8 STAGE B DID answer (31,762 px against a 113 px noise floor), so
# that excuse would have been a stale sentence standing in for a measurement.
CCLICK_LOGGED=0
grep -aA30 -F "DELOG-C panel:" "$WORK/boot2.log" | tr -d '\r' |
    grep -aq 'Applications button ->' && CCLICK_LOGGED=1
CSPAWN_REFUSED=0
sed -n '/\[wv\] MARK-C/,/\[wv\] REFUSE-C:/p' "$WORK/boot2.log" | tr -d '\r' |
    grep -aq 'REFUSING to attach' && CSPAWN_REFUSED=1
if answered C; then
    echo "wv: PASS STAGE C the desktop still answers the mouse after an app was opened"
elif [ "$CCLICK_LOGGED" = 1 ] && [ "$CSPAWN_REFUSED" = 1 ]; then
    echo "wv: FINDING STAGE C the click IS answered -- the panel logged the button and spawned /bin/hamappmenu -- but the menu never appears, because the spawned binary is the new one and it refuses the running session BY NAME. Nothing on the SCREEN says so; the words are on stderr. That is this bump's whole cost to a person, and it is the designed one."
else
    echo "wv: FINDING STAGE C the desktop does not answer the mouse after an app is opened, and NOT because a spawned program refused: the panel logged the click=${CCLICK_LOGGED}, a refusal followed=${CSPAWN_REFUSED}. The compositor reports ${CWIN:-?} windows."
fi

# =========================================================================
# 7. DID THE RUNNING SESSION SURVIVE THE NEW BINARY?
# =========================================================================
# Four witnesses, none of which needs the panel to answer a click, and every
# one of which was the OPPOSITE before user/linux-wsys.c learned to refuse.
CSEG="$(segsize "$WORK/boot2.log" C)"
BSEG="$(segsize "$WORK/boot2.log" B)"
if [ -n "$CSEG" ] && [ "$CSEG" = "$BSEG" ] && [ "$CSEG" = "$SEG_BYTES" ]; then
    echo "wv: PASS STAGE C THE SEGMENT WAS NOT RESIZED UNDER THE PERSON: /srv/wsys is still $CSEG bytes, the same as at STAGE B"
else
    echo "wv: FAIL STAGE C /srv/wsys is ${CSEG:-?} bytes at C against ${BSEG:-?} at B (expected $SEG_BYTES). The new binary resized the running session's window table."
    fail=1
fi

CDIST="$(distinct "$SHOT/C-1-idle.ppm")"
BDIST="$(distinct "$SHOT/B-1-idle.ppm")"
if [ -n "$CDIST" ] && [ "$CDIST" -ge 500 ]; then
    echo "wv: PASS STAGE C THE SCREEN IS STILL A DESKTOP: $CDIST distinct colours (STAGE B had ${BDIST:-?}; the featureless slab this gate photographed before the fix had 3)"
else
    echo "wv: FAIL STAGE C THE SCREEN IS A FEATURELESS SLAB: ${CDIST:-?} distinct colours over 1,024,000 pixels. There is nothing on it to click."
    fail=1
fi

BCDIFF="$(ppn "$SHOT/B-1-idle.ppm" "$SHOT/C-1-idle.ppm")"
if [ -n "$BCDIFF" ] && [ "$BCDIFF" -lt 512000 ]; then
    echo "wv: PASS STAGE C the screen did not turn over underneath the person: $BCDIFF px differ from STAGE B (a whole-screen repaint is 1,024,000)"
else
    echo "wv: FAIL STAGE C THE WHOLE SCREEN CHANGED when one app was opened: ${BCDIFF:-?} of 1,024,000 px"
    fail=1
fi

if [ -n "$CWIN" ] && [ -n "$BWIN" ] && [ "$CWIN" = "$BWIN" ] && [ "$CWIN" != 0 ]; then
    echo "wv: PASS STAGE C the compositor still has the session's windows: $CWIN, the same as at STAGE B"
else
    echo "wv: FAIL STAGE C the window table lost the session's windows: ${CWIN:-?} at C against ${BWIN:-?} at B"
    fail=1
fi

# DID IT SAY SO?  A refusal nobody can read is the same silence in a smaller
# box.  The message has to name the file, both versions and the remedy, and it
# has to come out of the binary that was refused -- so it is looked for between
# the markers that bracket that one command and nowhere else.
if sed -n '/\[wv\] REFUSE-C:/,/\[wv\] REFUSE-END-C/p' "$WORK/boot2.log" |
        tr -d '\r' | grep -aq 'REFUSING to attach'; then
    echo "wv: PASS THE NEW BINARY SAID SO, BY NAME:"
    sed -n '/\[wv\] REFUSE-C:/,/\[wv\] REFUSE-END-C/p' "$WORK/boot2.log" |
        tr -d '\r' | grep -a '^wsys:' | sed 's/^/        /'
else
    echo "wv: FAIL the new binary attached (or failed) WITHOUT SAYING WHY -- this is what it printed:"
    sed -n '/\[wv\] REFUSE-C:/,/\[wv\] REFUSE-END-C/p' "$WORK/boot2.log" |
        tr -d '\r' | sed 's/^/        /' | head -8
    fail=1
fi

# AND WHICH WINDOW SYSTEM WAS IT LOOKING AT?  This is the witness that replaces
# the size at a bump where the size does not move.  The two numbers in the
# refusal are read out of the SEGMENT'S HEADER by the binary that refused --
# a pread(2) of the live file, taken after `hpm update` -- so "the session is
# still the published window system" is an observation and not an assumption.
REF="$(sed -n '/\[wv\] REFUSE-C:/,/\[wv\] REFUSE-END-C/p' "$WORK/boot2.log" | tr -d '\r')"
VERPAIR="$(printf '%s\n' "$REF" | sed -n 's/^wsys: *version \([0-9][0-9]*\) and this program is version \([0-9][0-9]*\).*/\1 \2/p' | head -1)"
SEGVER="${VERPAIR%% *}"; PROGVER="${VERPAIR##* }"
[ "$VERPAIR" = "$SEGVER" ] && PROGVER=""
if [ -n "$SEGVER" ] && [ -n "$PROGVER" ] && [ "$PROGVER" = "$NEWWSYS" ] && [ "$SEGVER" != "$NEWWSYS" ]; then
    echo "wv: PASS STAGE C THE RUNNING SESSION IS STILL THE PUBLISHED WINDOW SYSTEM: the refused binary (version $PROGVER, this tree's WSYS_VERSION) read version $SEGVER out of the live segment AFTER the update"
else
    echo "wv: FAIL STAGE C the refusal did not name a live segment of some older version against this tree's $NEWWSYS: it said segment=${SEGVER:-?} program=${PROGVER:-?}"
    fail=1
fi

# WHAT THE PERSON WHO CLICKED ACTUALLY GOT, and this one IS scored.
#
# The refusal checked above was driven from the console by this gate. The case
# that decides whether a person is told anything is the app the DE LAUNCHED
# ITSELF -- the terminal off /dev/wsys/run/launch, which is the path a click on
# the Applications menu takes. "Fails with the named refusal" and "fails" are
# different sentences to put in a release note, and only one of them is
# acceptable: a program that declines to draw without a word is the
# success-shaped silence NORTH_STAR.md forbids, in a smaller box.
if sed -n '/\[wv\] PROBE-END-B/,/\[wv\] MARK-C/p' "$WORK/boot2.log" | tr -d '\r' |
        grep -aq 'REFUSING to attach'; then
    echo "wv: PASS THE APP THE DESKTOP LAUNCHED FAILED BY NAME, not silently:"
    sed -n '/\[wv\] PROBE-END-B/,/\[wv\] MARK-C/p' "$WORK/boot2.log" | tr -d '\r' |
        grep -aE '^wsys:|FAIL newwindow|newwindow alloc failed' | sed 's/^/        /' | head -8
else
    echo "wv: FAIL the app the desktop launched at STAGE C failed WITHOUT the refusal -- this is everything it said:"
    sed -n '/\[wv\] PROBE-END-B/,/\[wv\] MARK-C/p' "$WORK/boot2.log" | tr -d '\r' |
        grep -av '^\[panelbeacon\]' | tail -8 | sed 's/^/        /'
    fail=1
fi

echo "wv: NOTE what the launched app's refusal reached, between the update and STAGE C:"
# The range STOPS at REFUSE-C, which is where this gate deliberately runs the
# new binary on the console; including it would let the gate's own evidence
# answer a question about what the PERSON got.
sed -n '/\[wv\] MARK-B/,/\[wv\] REFUSE-C:/p' "$WORK/boot2.log" | tr -d '\r' |
    grep -a 'REFUSING to attach' | head -3 | sed 's/^/        /'
sed -n '/\[wv\] MARK-B/,/\[wv\] REFUSE-C:/p' "$WORK/boot2.log" | tr -d '\r' |
    grep -aq 'REFUSING to attach' ||
    echo "        (nothing: the program the person launched failed without a word reaching the console or the DE logs)"

# =========================================================================
# 8. AND A LEFTOVER SEGMENT MUST STILL BE RE-INITIALISED.
# =========================================================================
# Same boot, seconds after the refusal above, so this is the two cases being
# TOLD APART rather than one behaviour being described twice.
SB="$(sizeat "$WORK/boot2.log" 'STALE-BEFORE:')"
SA="$(sizeat "$WORK/boot2.log" 'STALE-AFTER:')"
stalemd5() {   # stalemd5 <n> -- the md5 printed after STALE-MD5-<n>:
    grep -aA1 -F "STALE-MD5-$1:" "$WORK/boot2.log" | tail -1 | tr -d '\r' |
        awk '{print $1}'
}
M1="$(stalemd5 1)"; M2="$(stalemd5 2)"; M3="$(stalemd5 3)"; M4="$(stalemd5 4)"
if [ "$SB" = "$SEG_BYTES" ] && [ "$SA" = "$SEG_BYTES" ]; then
    echo "wv: PASS THE LEFTOVER CONTROL starts from a real segment nobody holds a row in ($SB bytes) and it is not resized ($SA)"
else
    echo "wv: FAIL THE LEFTOVER CONTROL could not make a segment of the expected size: /stale/wsys is ${SB:-?} then ${SA:-?} bytes, wanted $SEG_BYTES"; fail=1
fi
echo "wv: NOTE the leftover segment's md5, four attaches: published=$M1 -> this tree=$M2 -> this tree again=$M3 -> published again=$M4"
if [ -n "$M1" ] && [ -n "$M2" ] && [ "$M1" != "$M2" ]; then
    echo "wv: PASS A LEFTOVER SEGMENT IS STILL RE-INITIALISED: this tree's binary rewrote /stale/wsys ($M1 -> $M2) instead of refusing it -- so a fresh boot still comes up"
else
    echo "wv: FAIL A LEFTOVER SEGMENT WAS NOT RE-INITIALISED: /stale/wsys is byte-identical (${M1:-?}) after this tree's binary met it. Either the refusal is refusing too much -- and the first program after a boot will not start -- or a foreign table was silently shared."
    fail=1
fi
if [ -n "$M2" ] && [ "$M2" = "$M3" ]; then
    echo "wv: PASS the second attach by the same build changed nothing ($M2): it recognised its own segment"
else
    echo "wv: FAIL this tree's binary re-initialised a segment IT HAD JUST MADE: $M2 -> ${M3:-?}. Every program started would wipe the one before it."
    fail=1
fi
if [ -n "$M4" ] && [ "$M3" != "$M4" ] && [ "$M4" = "$M1" ]; then
    echo "wv: PASS the published binary took the leftover back and landed on the SAME bytes it first made ($M4 = $M1), so a fresh segment is deterministic and the differences above are the version and nothing else"
elif [ -n "$M4" ] && [ "$M3" != "$M4" ]; then
    echo "wv: NOTE the published binary re-initialised it again ($M3 -> $M4) but did not land on its own first bytes ($M1) -- something other than the version word also differs between two fresh segments; the re-initialise above still happened"
else
    echo "wv: FAIL the published binary did NOT re-initialise a leftover segment of this tree's version: ${M3:-?} -> ${M4:-?}"
    fail=1
fi
if sed -n '/THE LEFTOVER CONTROL/,/PHASE2 DONE/p' "$WORK/boot2.log" |
        tr -d '\r' | grep -aq 'REFUSING to attach'; then
    echo "wv: FAIL the leftover segment was REFUSED. Nobody holds a row in it; refusing here is the machine that never boots again."
    sed -n '/THE LEFTOVER CONTROL/,/PHASE2 DONE/p' "$WORK/boot2.log" | tr -d '\r' |
        grep -a '^wsys:' | sed 's/^/        /' | head -5
    fail=1
else
    echo "wv: PASS nothing refused the leftover segment"
fi

if grep -aA3 -F '[wv] p3 md5 of /bin/wsysd' "$WORK/boot3.log" | grep -aq "$NEW_MD5"; then
    echo "wv: PASS the reboot came up on the NEW compositor (md5 $NEW_MD5)"
else
    echo "wv: FAIL the reboot did not come up on the new compositor"; fail=1
fi
if answered D; then
    echo "wv: PASS AFTER A REBOOT THE MACHINE IS HEALTHY: a real click on the Applications button opened the menu"
else
    echo "wv: FAIL AFTER A REBOOT the machine did not open the Applications menu under a real click"
    fail=1
fi

# DID THE PANEL COME BACK, OR IS IT GONE FOREVER?
# =========================================================================
# These are two very different sentences to put in a release note, and until
# this check the gate could not tell them apart. The panel and the taskbar go
# `visible` 1 -> 0 at STAGE B -- a config-reload defect in the RUNNING
# pre-update binary, which `hpm` cannot reach because it replaced the file and
# not the process. A person on the published version therefore pays for it
# exactly once, on the update that carries its fix. That is only true if the
# panel is back after the reboot, so the reboot is where it is asserted, by
# name and by window id rather than by a pixel count that a wallpaper could
# satisfy on its own.
BPAN="$(visfield "$WORK/boot2.log" B 3)"; BTASK="$(visfield "$WORK/boot2.log" B 4)"
APAN="$(visfield "$WORK/boot2.log" A 3)"; ATASK="$(visfield "$WORK/boot2.log" A 4)"
DPAN="$(visfield "$WORK/boot3.log" D 3)"; DTASK="$(visfield "$WORK/boot3.log" D 4)"
echo "wv: NOTE the panel (wid 3) and the taskbar (wid 4) are visible=${APAN:-?}/${ATASK:-?} at STAGE A and visible=${BPAN:-?}/${BTASK:-?} at STAGE B -- the SEPARATE config-reload defect, measured here and not scored here"
if [ "$DPAN" = 1 ] && [ "$DTASK" = 1 ]; then
    echo "wv: PASS AFTER A REBOOT THE PANEL AND THE TASKBAR ARE BACK (wid 3 and wid 4 both visible) -- the update hurt the session once, it did not break the desktop"
else
    echo "wv: FAIL AFTER A REBOOT the panel is wid 3 visible=${DPAN:-?} and the taskbar wid 4 visible=${DTASK:-?}: the desktop did not come back, so this is not a one-time cost of the update"
    fail=1
fi
check "phase 3 reached the end" '\[wv\] PHASE3 DONE' "$WORK/boot3.log"

echo
echo "(logs: $WORK/boot{1,2,3}.log; screendumps + PNGs: $SHOT)"
exit $fail
