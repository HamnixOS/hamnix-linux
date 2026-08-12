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
# and that this is "the ONLY other way [to meet an old segment] … a live
# `hpm update` of the window system underneath a running desktop".
#
# That paragraph had never been run. It is a claim about what EVERY updating
# user is about to experience, and NORTH_STAR.md's standing rule is that a
# measurement is worth more than an argument -- including one written in a
# comment by the people who wrote the code. So this boots a real installed
# machine at the CURRENT PUBLISHED version, with a desktop up and a window
# open, runs `hpm update`, and then asks the screen and the pointer what
# happened. It asserts nothing about exit codes.
#
# THE THREE THINGS A PERSON DOES, IN ORDER, AND WHAT IS MEASURED AT EACH
# =====================================================================
#   STAGE A  the desktop as it shipped. A terminal is opened THROUGH THE DE'S
#            OWN LAUNCH QUEUE (/dev/wsys/run/launch -- what the Applications
#            menu writes), a real QMP click opens the Applications menu, and a
#            real QMP keystroke goes into the terminal. Screendumps of each.
#            This is the control: the machine demonstrably works.
#   STAGE B  `hpm update` has just run and NOTHING HAS BEEN RELAUNCHED. The
#            same click, the same keystrokes, the same screendumps. This is
#            the minute after a person types the command.
#   STAGE C  the person opens one more app -- the first NEW binary of the
#            update to attach to the running session's segment. Same click,
#            same keystrokes, same screendumps.
#
# THE WITNESSES, none of which is a version string
# ================================================
#   * THE SEGMENT'S SIZE ON DISK. `ls -l /srv` -- 19,052,956 bytes is a v6
#     window table, 37,972,380 is a v7 one. That is sizeof(struct wshm) and it
#     cannot be faked by an index field or an hpm database edit.
#   * THE WINDOW TABLE, read in the guest with `cat /dev/wsys/<wid>/ctl` and
#     `cat /dev/wsys/windows`, and the compositor's own counters from
#     `cat /dev/wsys/wsysd/state`.
#   * THE FRAMEBUFFER, over QMP `screendump`, compared with
#     tests/linux/ppmdiff.py. "Does the screen go black" is a question about
#     pixels and is answered with pixels.
#   * A REAL POINTER on `-device virtio-tablet-pci` and REAL KEYSTROKES on
#     `-device virtio-keyboard-pci`, both over QMP `input-send-event`. A
#     desktop that is up and ignores the keyboard is a FAILURE, not a pass --
#     and it is precisely the shape a v6 client parked on the now-dead keys
#     ring would produce.
#
# NO VERSION NUMBER IS HARD-CODED. The published version is READ from the live
# index at run time; the local channel this tree publishes into is derived
# strictly above it. Nothing is published anywhere: the update comes from a
# python3 http.server on the loopback, signed with a key minted for the run.
#
# Usage: tests/linux/installed_update_wsysver.sh [b1s] [b2s] [b3s]
#   HAMLINUX_WV_REUSE=1   reuse the staged image root, the channel and the disk
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"
. tests/linux/reap.sh

export HAMLINUX_VNC="${HAMLINUX_VNC:-none}"
export HAMLINUX_DISTRO_RO="${HAMLINUX_DISTRO_RO:-1}"
export TMPDIR="${TMPDIR:-$PROJ_ROOT/build/tmp}"
mkdir -p "$TMPDIR"

WAIT1="${1:-540}"
WAIT2="${2:-720}"
WAIT3="${3:-420}"
PKG=hamnix-desktop
BIN=/bin/wsysd
CHANNEL_URL="${HAMLINUX_WV_URL:-https://255.one/linux/index.json}"

WORK="${HAMLINUX_WV_WORK:-$HOME/.hamnix-build/wsysver}"; mkdir -p "$WORK"
SHOT="$WORK/shots"; mkdir -p "$SHOT"
IMG=build/image
DISK="$WORK/wsysver.img"
REPO="${HAMLINUX_WV_REPO:-build/repo}"     # the channel built from THIS tree
EXTRA="$WORK/extra"
QMP="$WORK/qmp.sock"

reap_track "$WORK/reaped"

# sizeof(struct wshm) at each version. Read out of the source rather than
# written down here, so a table that grows again does not make this gate lie.
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
# The version THIS TREE publishes into the local channel: strictly above.
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

# The bytes the live channel serves, so "the machine is running the published
# compositor" is a statement about content.
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

_wins() {   # _wins <tag> -- everything the guest can say about its own windows
    cat <<W
echo '[wv] WINS-$1'
cat '/dev/wsys/2/ctl'
cat '/dev/wsys/3/ctl'
cat '/dev/wsys/4/ctl'
cat '/dev/wsys/5/ctl'
cat '/dev/wsys/6/ctl'
echo '[wv] WINS-END-$1'
echo '[wv] TITLES-$1:'
cat '/dev/wsys/windows'
echo '[wv] STATE-$1:'
cat '/dev/wsys/wsysd/state'
echo '[wv] SEG-$1:'
ls -l /srv
W
}

# ---- phase 1: become a machine running the CURRENT PUBLISHED desktop ----
cat > "$WORK/rc.phase1" <<RC
source '/etc/rc.boot.installed'
echo '[wv] ===== PHASE 1: install the CURRENTLY PUBLISHED desktop ($LIVEVER)'
date
dhcpc
echo '[wv] p1 dhcpc status:' \$status
echo '[wv] p1 refresh (the real repository, the shipped trusted key)'
hpm refresh
echo '[wv] p1 refresh status:' \$status
echo '[wv] p1 install $PKG'
hpm install $PKG
echo '[wv] p1 install status:' \$status
echo '[wv] p1 list:'
hpm list
echo '[wv] p1 md5 of $BIN:'
md5sum $BIN
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
# rc.boot.installed ends by sourcing /etc/rc.d/rc.5; give the desktop the
# time a desktop takes.
sleep 18
# THE USER OPENS A TERMINAL, through the DE's own launch queue -- the file
# hampanelscene's Applications menu writes. The RUNNING panel spawns it, so
# this is the launch path a person's click takes and not a side door.
echo '[wv] p2 opening a terminal through the DE launch queue'
echo '/bin/hamtermscene' > '/dev/wsys/run/launch'
sleep 12
RC
_wins A0
cat <<RC
echo '[wv] MARK-A'
sleep 60
RC
_wins A1

# ---------------- the update itself ----------------
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
RC
_wins B0
cat <<RC
echo '[wv] MARK-B'
sleep 60
RC
_wins B1

# ---------------- and then the person opens one more app ----------------
cat <<RC
echo '[wv] p2 ----- the owner opens one more app, the ordinary next thing'
echo '/bin/hamtermscene' > '/dev/wsys/run/launch'
sleep 15
RC
_wins C0
cat <<RC
echo '[wv] MARK-C'
sleep 60
RC
_wins C1
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
sleep 18
echo '[wv] p3 list:'
hpm list
echo '[wv] p3 md5 of $BIN:'
md5sum $BIN
RC
_wins D0
cat <<RC
echo '[wv] MARK-D'
sleep 45
RC
_wins D1
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

# THE HAND, once per stage. Identical at A, B, C and D, so the three answers
# are comparable: photograph, click Applications, photograph, dismiss,
# type into the focused window, photograph.
stage_hand() {   # stage_hand <tag>
    local t="$1"
    sleep 3
    shot "$t-1-idle"
    sleep 3
    shot "$t-2-idle"                       # the still pair: the noise floor
    Q click "$APPBTN_X" "$APPBTN_Y" "$SCREEN_W" "$SCREEN_H"
    sleep 3
    shot "$t-3-menu"
    Q click "$NEUTRAL_X" "$NEUTRAL_Y" "$SCREEN_W" "$SCREEN_H"
    sleep 2
    shot "$t-4-dismissed"
    Q type "wsysprobe$t"
    sleep 2
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

screensize() {   # the backdrop window's w/h, out of the guest's own ctl lines
    local back sw sh
    back="$(grep -a -A1 "WINS-$1" "$LOG" | tail -1 | tr -d '\r')"
    set -- $back
    sw="${4:-}"; sh="${5:-}"
    case "$sw" in ''|*[!0-9]*) return ;; esac
    case "$sh" in ''|*[!0-9]*) return ;; esac
    [ "$sw" -gt 0 ] && [ "$sh" -gt 0 ] && { SCREEN_W="$sw"; SCREEN_H="$sh"; }
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
            screensize "${m}0"
            say "  $m: the guest is ready (screen ${SCREEN_W}x${SCREEN_H})"
            stage_hand "$m"
        else
            say "  $m: the marker never came"
        fi
    done
    wait "$VM" 2>/dev/null
    VM=""
}

say "boot 1 of 3: install the published desktop (up to ${WAIT1}s)"
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
    grep -aE '^\[wv\]|^rc\.boot:|^hpm:|^[0-9]+ [0-9]+ [0-9]+ [0-9]+ |^focus [0-9]|^total |^-rw' \
        "$WORK/boot$n.log" | tr -d '\r'
done
echo

pp() { python3 tests/linux/ppmdiff.py "$@" 2>&1; }
barh() {   # barh <log> <marker> -- the top panel's height
    awk -v m="WINS-$2" 'index($0, m) {inb=1; next}
                        inb && index($0, "WINS-END") {exit}
                        inb && NF >= 6 && $3 == 0 && $6 == 100 {print $5; exit}' \
        "$1" | tr -d '\r'
}
statefield() {   # statefield <log> <marker> <field>
    grep -aA1 -F "STATE-$2:" "$1" | tail -1 | tr -d '\r' |
        awk -v f="$3" '{for (i = 1; i < NF; i++) if ($i == f) print $(i+1)}'
}
segsize() {   # segsize <log> <marker> -- the size of /srv/wsys, in bytes
    awk -v m="SEG-$2:" 'index($0, m) {inb=1; next}
                        inb && /wsys$/ {print $5; exit}
                        inb && index($0, "[wv]") {exit}' "$1" | tr -d '\r'
}

echo "=========================================================="
echo " WHAT A PERSON SEES WHEN THEY UPDATE A RUNNING DESKTOP"
echo "=========================================================="
LOG="$WORK/boot2.log"
for s in A B C; do
    echo
    case "$s" in
      A) echo "--- STAGE A: before the update (published $LIVEVER, v6 window system)" ;;
      B) echo "--- STAGE B: hpm update has run; nothing has been relaunched" ;;
      C) echo "--- STAGE C: the person opens one more app" ;;
    esac
    echo "    window table:  $(awk -v m="WINS-${s}0" 'index($0,m){i=1;next} i&&index($0,"WINS-END"){exit} i&&NF>=6{printf "(%s) ", $0}' "$LOG" | tr -d '\r')"
    echo "    titles:        $(grep -aA6 -F "TITLES-${s}0:" "$LOG" | sed -n '2,6p' | tr -d '\r' | tr '\n' '|')"
    echo "    wsysd state:   $(grep -aA1 -F "STATE-${s}0:" "$LOG" | tail -1 | tr -d '\r')"
    echo "    /srv/wsys:     $(segsize "$LOG" "${s}0") bytes  (v6=$V6_BYTES v7=$V7_BYTES)"
    echo "    top panel:     $(barh "$LOG" "${s}0") px before the click, $(barh "$LOG" "${s}1") px after"
    echo "    state after:   $(grep -aA1 -F "STATE-${s}1:" "$LOG" | tail -1 | tr -d '\r')"
    if [ -f "$SHOT/$s-1-idle.ppm" ]; then
        echo "    the screen:    $(pp rect "$SHOT/$s-1-idle.ppm")"
        echo "    noise floor:   $(pp diff "$SHOT/$s-1-idle.ppm" "$SHOT/$s-2-idle.ppm")"
        echo "    click ->       $(pp diff "$SHOT/$s-2-idle.ppm" "$SHOT/$s-3-menu.ppm")"
        echo "    typing ->      $(pp diff "$SHOT/$s-4-dismissed.ppm" "$SHOT/$s-5-typed.ppm")"
        python3 tests/linux/ppmdiff.py png "$SHOT/$s-1-idle.ppm" "$SHOT/$s-1-idle.png" >/dev/null 2>&1
        python3 tests/linux/ppmdiff.py png "$SHOT/$s-3-menu.ppm" "$SHOT/$s-3-menu.png" >/dev/null 2>&1
    else
        echo "    the screen:    NO SCREENDUMP"
    fi
done

echo
echo "--- DID ANYTHING TELL THE PERSON?"
# Everything the machine printed between the update finishing and the app
# being opened. If a person is to learn that their session is about to lose
# its windows, this is where the sentence would be.
sed -n '/p2 update status/,/p2 ----- the owner opens one more app/p' "$WORK/boot2.log" |
    tr -d '\r' | grep -aiE 'wsys|window|restart|log ?out|session|version|reboot' |
    grep -avE '^\[wv\]' | head -20
echo "(the lines above are every mention of the window system, a restart or a"
echo " session between the update finishing and the next app opening)"

echo
echo "=========================================================="
echo " THE QUESTIONS"
echo "=========================================================="
check() { if grep -aqE "$2" "$3"; then echo "wv: PASS $1"
          else echo "wv: FAIL $1"; fail=1; fi; }

check "the installed root came online"  'rc\.boot: hamnix-linux \(installed\)' "$WORK/boot1.log"
check "the published desktop installed" '\[wv\] p1 install status: 0'          "$WORK/boot1.log"
if grep -aA3 -F '[wv] p1 md5 of' "$WORK/boot1.log" | grep -aq "$LIVE_MD5"; then
    echo "wv: PASS the machine is running the PUBLISHED compositor (md5 $LIVE_MD5)"
else
    echo "wv: FAIL the machine is not running the published compositor"; fail=1
fi

# --- STAGE A: the control. This machine works. ---
AB="$(barh "$WORK/boot2.log" A0)"; AA="$(barh "$WORK/boot2.log" A1)"
if [ -n "$AB" ] && [ -n "$AA" ] && [ "$AA" -gt "$AB" ]; then
    echo "wv: PASS STAGE A the published desktop works: a real click opened the Applications menu ($AB -> $AA px)"
else
    echo "wv: FAIL STAGE A the published desktop did NOT react to a real click ($AB -> ${AA:-none} px) -- the control is broken and nothing after it means anything"
    fail=1
fi
ASEG="$(segsize "$WORK/boot2.log" A0)"
if [ "$ASEG" = "$V6_BYTES" ]; then
    echo "wv: PASS STAGE A the running session's segment is a v6 window table ($ASEG bytes)"
else
    echo "wv: NOTE STAGE A /srv/wsys is $ASEG bytes (v6=$V6_BYTES, v7=$V7_BYTES)"
fi

# --- the update ran ---
check "hpm update exited 0" '\[wv\] p2 update status: 0' "$WORK/boot2.log"
if grep -aA3 -F '[wv] p2 md5 of /bin/wsysd after update:' "$WORK/boot2.log" | grep -aq "$NEW_MD5"; then
    echo "wv: PASS the new compositor is ON DISK (md5 $NEW_MD5)"
else
    echo "wv: FAIL the update did not put this tree's compositor on the disk"; fail=1
fi

# --- STAGE C: THE SENTENCE THIS FILE EXISTS FOR ---
CB="$(barh "$WORK/boot2.log" C0)"; CA="$(barh "$WORK/boot2.log" C1)"
CWIN="$(statefield "$WORK/boot2.log" C0 windows)"
if [ -n "$CB" ] && [ -n "$CA" ] && [ "$CA" -gt "$CB" ]; then
    echo "wv: PASS STAGE C the desktop still answers a real click after the update ($CB -> $CA px)"
elif [ -z "$CB" ]; then
    echo "wv: FINDING STAGE C THE DESKTOP HAS NO TOP PANEL after the update; the compositor reports ${CWIN:-?} windows. A person who updated and then opened an app has no Applications button to click."
else
    echo "wv: FINDING STAGE C the panel is present at $CB px and DID NOT MOVE under a real click (-> ${CA:-?} px): the desktop is up and inert."
fi

# --- STAGE D: the reboot ---
DB="$(barh "$WORK/boot3.log" D0)"; DA="$(barh "$WORK/boot3.log" D1)"
if grep -aA3 -F '[wv] p3 md5 of' "$WORK/boot3.log" | grep -aq "$NEW_MD5"; then
    echo "wv: PASS the reboot came up on the NEW compositor (md5 $NEW_MD5)"
else
    echo "wv: FAIL the reboot did not come up on the new compositor"; fail=1
fi
if [ -n "$DB" ] && [ -n "$DA" ] && [ "$DA" -gt "$DB" ]; then
    echo "wv: PASS AFTER A REBOOT THE MACHINE IS HEALTHY: a real click on the Applications button opened the menu ($DB -> $DA px)"
else
    echo "wv: FAIL AFTER A REBOOT the machine did NOT open the Applications menu under a real click ($DB -> ${DA:-none} px)"
    fail=1
fi
check "phase 3 reached the end" '\[wv\] PHASE3 DONE' "$WORK/boot3.log"

echo
echo "(logs: $WORK/boot{1,2,3}.log; screendumps: $SHOT)"
exit $fail
