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
#   * THE SEGMENT'S SIZE. `ls -l /srv` -- 19,052,956 bytes is a v6 window
#     table, 37,972,380 a v7 one. That is sizeof(struct wshm); no index field
#     and no hpm database edit can fake it.
#   * THE COMPOSITOR'S AND THE PANEL'S OWN LOGS, /var/log/{wsysd,panel,
#     hamdesktop}.log, tailed at the end of every stage.
#
# NO VERSION NUMBER IS HARD-CODED. The published version is READ from the live
# index at run time and the local channel is derived strictly above it. Nothing
# is published: the update is served by python3 -m http.server on the loopback,
# signed with a key minted for the run.
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

V7_BYTES=37972380
V6_BYTES=19052956

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
echo '[wv] DELOG-$1 panel:'
tail -6 /var/log/panel.log
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
# machine is what a person who installed hamnix-linux and ran `hpm update`
# today HAS, and nothing on it is newer than the window system it is running.
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
_probe C /bin/cat
cat <<RC
date
echo '[wv] PHASE2 DONE'
cp /etc/rc.phase3 /etc/rc.boot
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
segsize() {   # segsize <log> <tag>
    awk -v m="SEG-$2:" 'index($0, m) {inb=1; next}
                        inb && $NF == "wsys" {print $(NF-1); exit}
                        inb && index($0, "DELOG") {exit}' "$1" | tr -d '\r'
}
wins() {   # wins <log> <tag>
    awk -v m="WINS-$2" 'index($0,m){i=1;next} i&&index($0,"WINS-END"){exit}
                        i&&NF>=6&&$1~/^[0-9]+$/{printf "(%s) ", $0}' "$1" | tr -d '\r'
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
    echo "    window table:    $(wins "$L" "$s")"
    echo "    titles:          $(grep -aA6 -F "TITLES-$s:" "$L" | sed -n '2,6p' | tr -d '\r' | tr '\n' '|')"
    echo "    wsysd state:     $(grep -aA1 -F "STATE-$s:" "$L" | tail -1 | tr -d '\r')"
    echo "    /srv/wsys:       $(segsize "$L" "$s") bytes  (v6=$V6_BYTES v7=$V7_BYTES)"
    echo "    wsysd log:       $(grep -aA6 -F "DELOG-$s wsysd:" "$L" | sed -n '2,7p' | tr -d '\r' | tr '\n' '|')"
    echo "    panel log:       $(grep -aA6 -F "DELOG-$s panel:" "$L" | sed -n '2,7p' | tr -d '\r' | tr '\n' '|')"
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
[ "$ASEG" = "$V6_BYTES" ] &&
    echo "wv: PASS STAGE A the running session is a v6 window table ($ASEG bytes)" ||
    echo "wv: NOTE STAGE A /srv/wsys is ${ASEG:-?} bytes (v6=$V6_BYTES v7=$V7_BYTES)"

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
if answered C; then
    echo "wv: PASS STAGE C the desktop still answers the mouse after an app was opened"
else
    echo "wv: FINDING STAGE C THE DESKTOP NO LONGER ANSWERS THE MOUSE once an app is opened after the update. The compositor reports ${CWIN:-?} windows. A person in front of this machine has no Applications button to click."
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
check "phase 3 reached the end" '\[wv\] PHASE3 DONE' "$WORK/boot3.log"

echo
echo "(logs: $WORK/boot{1,2,3}.log; screendumps + PNGs: $SHOT)"
exit $fail
