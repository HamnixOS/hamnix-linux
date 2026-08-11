#!/usr/bin/env bash
# tests/linux/distro_menu.sh — THE acceptance test for the DE application menu
# carrying N distributions rather than one.
#
# WHAT IT PROVES, and why it has to be a picture.
#
# `user/hampanelscene.ad` used to hold the literal path
# "/n/linux/usr/share/applications" and exactly one menu section called
# "Linux". The scan is now driven by /etc/distros -- one section per
# distribution actually attached under /n, named after it. There are two
# distinct ways for that to be wrong and only one of them shows up in a log:
#
#   * the scan finds nothing        -> the panel says so, and this test reads
#                                      the "[panel] distro section <name>: N
#                                      apps" lines it prints at startup.
#   * the scan finds the apps but the MENU does not draw them -- the rows are
#     in the model, the fly-out geometry is computed off the wrong parent row,
#     and the person clicking sees an empty popup. No log line changes.
#
# So the evidence is both: the panel's own count lines AND three screendumps
# taken off the QEMU monitor, with the menu driven OPEN by synthetic pointer
# events written into the panel window's event ring (/dev/wsys/<wid>/event,
# which the host owner may write -- user/linux-wsys.c). Clicking a menu is
# what a person does; nothing else exercises the fly-out geometry.
#
# Usage: tests/linux/distro_menu.sh [outdir]
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

export HAMLINUX_VNC="${HAMLINUX_VNC:-none}"
export HAMLINUX_DISTRO_RO="${HAMLINUX_DISTRO_RO:-1}"

WORK="${1:-build/distromenu}"; mkdir -p "$WORK"
SOCK=build/image/mon.sock
IMG=build/image
command -v socat >/dev/null || { echo "need socat" >&2; exit 1; }

# The panel's own window id. wsysd hands them out in start order and the panel
# is the second window client rc.5 starts (hamdesktop is the first, and wid 1
# is reserved), so 3 is the answer -- but it is a GUESS about start order, so
# the guest prints `ls /dev/wsys` and this script checks the rows it drove
# actually moved the menu. Override if the desktop gains a client.
PANELWID="${PANELWID:-3}"

# Row geometry, from user/hampanelscene.ad: a top panel's dropdown opens at
# y = cur_thick (26), rows are MENU_ROW_H (22) tall with a 2px inset, and the
# distribution parent rows come after the native ones. The image stages no
# /etc/hamde/apps, so the native set is _seed_fallback()'s 8 entries.
NATIVE="${NATIVE:-8}"
ROW0=$(( 26 + 2 + NATIVE * 22 + 11 ))     # centre of the FIRST distro row
ROW1=$(( ROW0 + 22 ))                     # centre of the SECOND
# The child fly-out, from _compute_sub_box: it hangs off the right edge of the
# main box (MENU_W 136, overlapping by 1px) and its top is the parent row's top
# less 2. SUBROW0 is the centre of its FIRST app row.
SUBX=$(( 136 - 1 + 40 ))
SUBROW0=$(( 26 + 2 + NATIVE * 22 - 2 + 2 + 11 ))

# --- the probe that writes the events -------------------------------------
# tests/linux/wsys_poke.ad writes one line to a /dev/wsys file. It is not in
# the image's application list (it is a test tool, not a program), so it goes
# in as a SECOND CPIO SEGMENT -- simpler than debugfs and it touches no shared
# image (docs/steam_namespace.md §11).
SEG="$WORK/seg"; rm -rf "$SEG"; mkdir -p "$SEG/bin"
scripts/hamlinux_build.sh tests/linux/wsys_poke.ad "$SEG/bin/wsys_poke" \
    >"$WORK/poke.build.log" 2>&1 || {
    echo "FAIL could not build wsys_poke"; tail -5 "$WORK/poke.build.log"; exit 1; }
chmod 755 "$SEG/bin/wsys_poke"

cat > "$WORK/rc.boot" <<RC
echo 'rc.boot: distribution application menu'
ln -s /dev/console /dev/cons

# The SAME order etc/rc.boot.linux uses, and the order is the point: the panel
# scans /n/<name> at startup, so the binds must already have happened.
bind '#distro' /n/distro
source '/etc/rc.distros'
source '/etc/rc.d/rc.5'
sleep 8

echo '[dmenu] --- the panel log (its own count of what it found)'
cat /var/log/panel.log
echo '[dmenu] --- the window ids wsysd handed out'
ls /dev/wsys
echo '[dmenu] --- what each distribution actually offers'
ls /n/debian/usr/share/applications
ls /n/alpine/usr/share/applications

# hampanelscene owns ONE WINDOW PER PANEL and the image ships two panels (a
# top bar with the Applications button and a bottom taskbar), so which wid is
# which is start order, not something a test should guess. Both get the event;
# the one whose bar is at y=0 is the top panel and the other ignores a click
# in its popup band. Naming the wrong one is exactly the kind of quiet
# no-op this file exists to make impossible, so the ring is READ BACK: an
# empty ring means the panel drained it, i.e. the event was delivered.
echo '[dmenu] click the Applications button'
wsys_poke /dev/wsys/3/event 'm 40 13 1'
wsys_poke /dev/wsys/4/event 'm 40 13 1'
sleep 1
echo '[dmenu] ring 3 after the click (empty = drained by the panel):'
cat /dev/wsys/3/event
echo '[dmenu] ring 4 after the click:'
cat /dev/wsys/4/event
wsys_poke /dev/wsys/3/event 'm 40 13 0'
wsys_poke /dev/wsys/4/event 'm 40 13 0'
sleep 6
echo '[dmenu] hover the FIRST distribution section'
wsys_poke /dev/wsys/3/event 'm 40 $ROW0 0'
wsys_poke /dev/wsys/4/event 'm 40 $ROW0 0'
sleep 8
# THE SCENE IS THE EVIDENCE, not the screendump. A display list containing a
# `glyphs ... Install Steam` op is the panel having drawn that row; counting
# lit pixels could be satisfied by anything else on the screen.
echo '[dmenu] SCENE-FIRST-BEGIN'
cat /dev/wsys/3/scene
cat /dev/wsys/4/scene
echo '[dmenu] SCENE-FIRST-END'
echo '[dmenu] hover the SECOND distribution section'
wsys_poke /dev/wsys/3/event 'm 40 $ROW1 0'
wsys_poke /dev/wsys/4/event 'm 40 $ROW1 0'
sleep 8
echo '[dmenu] SCENE-SECOND-BEGIN'
cat /dev/wsys/3/scene
cat /dev/wsys/4/scene
echo '[dmenu] SCENE-SECOND-END'

# THE LAUNCHER RC, RUN THE WAY THE MENU RUNS IT. Clicking a fly-out row spawns
# `/bin/hamsh /etc/rc.de-ns/<name> <prog>` (hampanelscene _launch_distro_ns),
# and that rc is GENERATED per distribution by scripts/hamlinux_image.sh --
# because hamsh's `enter` takes a namespace VALUE, so `enter \$NAME { }` cannot
# be written once for all names. Running it here with a program that only
# exists inside the distribution proves the generated text parses, drops to
# uid 1001, and reaches the right root. The BANNER is the evidence, not the
# status: apk and dpkg both exit nonzero when run with no arguments.
#
# HAMNIX_DE_XSESSION=0 because this arm is asking about the NAMESPACE.
# /etc/de-ns-run would otherwise start an X server for a command-line probe,
# which is a second thing that can fail in the middle of the measurement.
HAMNIX_DE_XSESSION='0'
export HAMNIX_DE_XSESSION
echo '[dmenu] LAUNCHRC-BEGIN'
/bin/hamsh /etc/rc.de-ns/alpine /sbin/apk
echo '[dmenu] LAUNCHRC-MID'
/bin/hamsh /etc/rc.de-ns/debian /usr/bin/dpkg
echo '[dmenu] LAUNCHRC-END'
HAMNIX_DE_XSESSION='1'
export HAMNIX_DE_XSESSION

# AND NOW THE THING A PERSON ACTUALLY DOES: CLICK A ROW IN THE FLY-OUT.
# Everything above measures the pieces; this measures the path. The fly-out for
# the FIRST distribution is open (we hovered ROW0 and then ROW1, so re-hover),
# and its geometry follows _compute_sub_box in user/hampanelscene.ad:
#   sub_box_x = menu_box_x + MENU_W - 1      (136 - 1, main box at x 0)
#   sub_box_y = menu_box_y + 2 + (NATIVE + section) * MENU_ROW_H - 2
# so the centre of its first app row is (sub_box_x + 40, sub_box_y + 2 + 11).
echo '[dmenu] re-hover the FIRST distribution section, then CLICK its first app'
wsys_poke /dev/wsys/3/event 'm 40 $ROW0 0'
wsys_poke /dev/wsys/4/event 'm 40 $ROW0 0'
sleep 3
wsys_poke /dev/wsys/3/event 'm $SUBX $SUBROW0 1'
wsys_poke /dev/wsys/4/event 'm $SUBX $SUBROW0 1'
sleep 1
wsys_poke /dev/wsys/3/event 'm $SUBX $SUBROW0 0'
wsys_poke /dev/wsys/4/event 'm $SUBX $SUBROW0 0'
echo '[dmenu] CLICKED'
# An X session inside a namespace is Xwayland + jwm + the client, over a
# Wayland socket. Give it real time, then read the shim's own log from the
# HAMNIX side -- /tmp/de-ns-run.log inside the tree is /n/debian/tmp from here,
# and it is the one file that spans the boundary.
sleep 75
echo '[dmenu] DENSRUNLOG-BEGIN'
cat /n/debian/tmp/de-ns-run.log
echo '[dmenu] DENSRUNLOG-END'
echo '[dmenu] DONE'
sleep 600
RC

echo "[dmenu] staging an image with that rc"
HAMLINUX_RC="$WORK/rc.boot" scripts/hamlinux_image.sh >"$WORK/build.log" 2>&1 || {
    echo "FAIL image build"; tail -20 "$WORK/build.log"; exit 1; }
( cd "$SEG" && find bin -print0 | cpio --null -o -H newc --quiet ) | gzip \
    >> "$IMG/initramfs.cpio.gz"
echo "[dmenu] planted /bin/wsys_poke as a second cpio segment"

rm -f "$SOCK" "$WORK"/shot*.ppm
# The run is long because the LAST act is a real application starting inside a
# namespace: Xwayland, a window manager and the client, over a Wayland socket.
# Cutting the boot off before that lands is how the previous version of this
# file reported a GAP for a launcher that had already worked -- the guest
# printed LAUNCHRC-BEGIN and the VM was killed three seconds later.
BOOTSECS="${HAMLINUX_DMENU_SECS:-330}"
( sleep $((BOOTSECS + 10)) ) | timeout $((BOOTSECS + 5)) \
    scripts/hamlinux_vm.sh script --timeout "$BOOTSECS" \
    >"$WORK/boot.log" 2>&1 &
QEMU=$!
mon() { printf '%s\n' "$@" | socat - UNIX-CONNECT:"$SOCK" >/dev/null 2>&1; }
for _ in $(seq 1 100); do [ -S "$SOCK" ] && break; sleep 0.2; done

# The guest's own timeline above is: rc.5 + 8s, then click, +6s, hover, +8s,
# hover, +8s, the two launcher-rc probes, re-hover +3s, CLICK, +75s. Sample
# after each settles. Boot to rc.5 is ~14s on this host.
sleep 24 ; mon "screendump $(realpath -m "$WORK/shot-menu.ppm")"
sleep 10 ; mon "screendump $(realpath -m "$WORK/shot-first.ppm")"
sleep 10 ; mon "screendump $(realpath -m "$WORK/shot-second.ppm")"
# THE DELIVERABLE. The app launched from the menu, on the Hamnix desktop.
sleep 110 ; mon "screendump $(realpath -m "$WORK/shot-launched.ppm")"
sleep 20  ; mon "quit"
kill $QEMU 2>/dev/null; wait 2>/dev/null

for p in menu first second launched; do
    [ -s "$WORK/shot-$p.ppm" ] && python3 scripts/_ppm2png.py \
        "$WORK/shot-$p.ppm" "$WORK/shot-$p.png" && rm -f "$WORK/shot-$p.ppm"
done

echo
grep -aE '^\[dmenu\]|^\[panel\]|^\[rc\.5\]' "$WORK/boot.log" | head -60
echo

fail=0
check() {
    if grep -aqE "$2" "$WORK/boot.log"; then echo "dmenu: PASS $1"
    else echo "dmenu: FAIL $1   (no line matching /$2/)"; fail=1; fi
}
check "the desktop came up"                    '\[rc\.5\] desktop up'
check "the panel found a debian section"       '\[panel\] distro section debian: [1-9]'
check "the panel found an alpine section"      '\[panel\] distro section alpine: [0-9]'
# HOW MANY apps Alpine offers is a property of the MEDIUM, not of this code:
# `HAMLINUX_ALPINE_GUI=0` builds a 26 MiB Alpine with no launchers at all, and
# the only .desktop in the graphical one that is not `xterm` carries
# NoDisplay=true. Both are legitimate; §8 gives each its own menu state. So
# assert the state that MATCHES the medium in front of us rather than failing a
# correct panel for a disk somebody built without graphics.
ALPINE_APPS="$(grep -ao '\[panel\] distro section alpine: [0-9]*' "$WORK/boot.log" \
               | tail -1 | awk '{print $NF}')"
echo "dmenu: NOTE the alpine medium offers ${ALPINE_APPS:-?} launchers"
check "the boot got to the end"                '\[dmenu\] DONE'
# A section that is DESCRIBED but not attached must not be drawn at all.
if grep -aq '\[panel\] no distribution namespace attached' "$WORK/boot.log"; then
    echo "dmenu: FAIL the panel saw no distribution namespace"; fail=1
else
    echo "dmenu: PASS the panel saw distribution namespaces"
fi
for p in menu first second; do
    if [ -s "$WORK/shot-$p.png" ]; then echo "dmenu: PASS screendump $p ($WORK/shot-$p.png)"
    else echo "dmenu: FAIL no screendump $p"; fail=1; fi
done

# --- what the panel actually DREW, per fly-out ----------------------------
# Debian's catalogue has `Install Steam`, which Alpine's does not; both have
# XTerm. So "Install Steam is drawn while hovering the FIRST section and NOT
# while hovering the SECOND" is the pair of facts that distinguishes two real
# sections from one section drawn twice -- the same negative-control shape
# tests/linux/two_namespaces.sh uses for the trees themselves.
sect() { sed -n "/SCENE-$1-BEGIN/,/SCENE-$1-END/p" "$WORK/boot.log" | tr -d '\r'; }
if sect FIRST | grep -q 'Install Steam'; then
    echo "dmenu: PASS the Debian fly-out drew a Debian-only app (Install Steam)"
else
    echo "dmenu: FAIL the Debian fly-out drew no Debian-only app"; fail=1
fi
if [ "${ALPINE_APPS:-0}" -gt 0 ] 2>/dev/null; then
    if sect SECOND | grep -q 'XTerm'; then
        echo "dmenu: PASS the Alpine fly-out drew an Alpine app (XTerm)"
    else
        echo "dmenu: FAIL the Alpine fly-out drew nothing"; fail=1
    fi
elif sect SECOND | grep -qi 'No alpine apps'; then
    # The medium ships no launchers, and the panel says exactly that -- a
    # DIFFERENT answer from "the scan is broken", which is the whole point of
    # the three-state table in §8. This arm is a real check, not a bypass.
    echo 'dmenu: PASS the Alpine section drew its "No alpine apps installed" row'
else
    echo "dmenu: FAIL Alpine offers no launchers and the panel did not say so"; fail=1
fi
if sect SECOND | grep -q 'Install Steam'; then
    echo "dmenu: FAIL the Alpine fly-out drew Debian's apps -- the sections are one list"
    fail=1
else
    echo "dmenu: PASS Debian's apps are NOT in the Alpine fly-out"
fi
# THE GUI LAUNCH PATH. This used to be a GAP line, on the strength of a
# diagnosis that was wrong: "the FIRST bind of the template -- the root switch
# -- fails ENOENT, i.e. chdir(/n/<name>)". It is the LAST bind, `#/` onto /n,
# and the root switch had already succeeded. Nothing named the bind, so nobody
# could tell; hamsh now does (_ns_apply_failed).
#
# What it actually was: `enter <name>` binds /dev, /proc, /srv and /n INTO the
# distribution's own root, and a bind whose target directory does not exist
# fails ENOENT. The session user cannot create one -- the distribution's / is
# uid 0 and uid 0 is not mapped into the user namespace sys_bind acquires. The
# directories existed on Debian's medium and not on Alpine's because somebody
# had once run `enter debian` AS ROOT on a writable disk and enter_root's own
# mkdir left them behind. They are now made deliberately, by root, when the
# boot posts the server at its name (user/linux-syscalls.c,
# distro_stage_mountpoints). docs/linux_distro_namespaces.md 8.4.
lrc() { sed -n "/LAUNCHRC-BEGIN/,/LAUNCHRC-END/p" "$WORK/boot.log" | tr -d '\r'; }
if lrc | grep -qi 'apk-tools'; then
    echo "dmenu: PASS /etc/rc.de-ns/alpine ran a program from inside Alpine (apk-tools)"
else
    echo "dmenu: FAIL /etc/rc.de-ns/alpine did not reach the Alpine root"; fail=1
fi
if lrc | grep -qi 'Usage: dpkg'; then
    echo "dmenu: PASS /etc/rc.de-ns/debian ran a program from inside Debian (dpkg)"
else
    echo "dmenu: FAIL /etc/rc.de-ns/debian did not reach the Debian root"; fail=1
fi

# --- AND THE PATH A PERSON TAKES: the click, and what came up -------------
# The panel names its own launch, so "the row was hit-tested and the launcher
# spawned" is a fact from the panel rather than an inference from a picture.
if grep -aq '\[panel\] launch in ns debian ->' "$WORK/boot.log"; then
    echo "dmenu: PASS clicking a fly-out row launched into the debian namespace"
    grep -a '\[panel\] launch in ns' "$WORK/boot.log" | sed 's/^/dmenu:      /'
else
    echo "dmenu: FAIL clicking a fly-out row launched nothing"; fail=1
fi
# The shim's log lives INSIDE the tree, which is the only place both sides can
# read. An empty one means the click never reached `enter`.
if sed -n '/DENSRUNLOG-BEGIN/,/DENSRUNLOG-END/p' "$WORK/boot.log" \
        | grep -qi 'de-ns-run: exec\|de-ns-run: delegating'; then
    echo "dmenu: PASS /etc/de-ns-run ran inside the namespace and said so"
    sed -n '/DENSRUNLOG-BEGIN/,/DENSRUNLOG-END/p' "$WORK/boot.log" \
        | grep -ai 'de-ns-run:\|hamnix-x11session:' | head -12 | sed 's/^/dmenu:      /'
else
    echo "dmenu: FAIL /etc/de-ns-run left no log inside the namespace"; fail=1
fi
if [ -s "$WORK/shot-launched.png" ]; then
    echo "dmenu: PASS screendump of the launched app ($WORK/shot-launched.png)"
else
    echo "dmenu: FAIL no screendump of the launched app"; fail=1
fi
if sect FIRST | grep -q 'Alpine apps' && sect FIRST | grep -q 'Debian apps'; then
    echo "dmenu: PASS both distributions have a parent row, named for them"
else
    echo "dmenu: FAIL the two named parent rows are not both drawn"; fail=1
fi
echo "(full log: $WORK/boot.log)"
exit $fail
