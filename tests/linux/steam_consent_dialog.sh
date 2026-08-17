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
# tests/linux/steam_consent_dialog.sh — THE CONSENT DIALOG ACTUALLY APPEARS.
#
# WHAT THIS IS FOR
# ================
# /usr/games/steam -- the shell script Debian's steam-installer puts in the
# distro image -- asks for consent before installing proprietary software, and
# it CHOOSES ITS OWN DIALOG PROGRAM:
#
#     if command -v zenity >/dev/null; then zenityish=zenity
#     else zenityish=yad; fi
#     if ! "$zenityish" --question --title="Steam installer" --icon-name=steam \
#          --width=600 --ok-label=Install --cancel-label=Cancel --text="..." \
#          --no-markup --default-cancel
#     then echo "steam: Installation cancelled" >&2; exit 1; fi
#
# NOTE WHAT THAT MEANS, and it is stronger than "yad is a fallback": yad is
# what the script EXECUTES when zenity is missing, with zenity's own option
# spelling. If yad is absent, or rejects one of those options, the failed
# command falls straight into "Installation cancelled" -- there is no third
# branch. So the swap has to be checked by running it, not by reading it.
#
# scripts/hamlinux_distro.sh used to install zenity, which is 167 KiB of
# dialog on top of a 133 MiB WebKit browser engine that nothing else in the
# image uses. It now installs yad, the second branch, which is 570 KiB against
# the GTK firefox-esr already requires.
#
# A SIZE MEASUREMENT CANNOT CHECK THAT SWAP. The audit script can prove WebKit
# left; it cannot prove the prompt still comes up, and the whole point of
# keeping a dialog at all is that the third branch -- "Installation
# cancelled", exit 1 -- is a dead end a person meets once with no explanation.
# A grep of this tree cannot check it either: the caller is a Debian shell
# script that only exists INSIDE the image.
#
# So this runs it. The real /usr/games/steam, out of the real image, against a
# real X server, and then it looks for the window.
#
# HOW IT AVOIDS THE OWNER'S SCREEN AND THE OWNER'S IMAGE
# ======================================================
#   * the image is read with debugfs(8) -- no mount, no loop device, no write.
#     The rootfs is extracted to a temp directory and THAT is what is entered.
#     The .ext4 is never opened for writing, so this is safe against an image
#     something else is using.
#   * the X server is Xvfb with -fbdir, which scans out to a file. Nothing
#     reaches /dev/dri/card0 or the owner's display.
#   * chroot happens inside `unshare -Urm`, so no privilege is needed and no
#     mount is visible outside this process.
#
# WHAT IT ASSERTS, in the order the failures matter:
#   1. a yad window with the right title is on the X server;
#   2. CLICKING Cancel makes /usr/games/steam print "steam: Installation
#      cancelled" and exit -- a dialog that draws and ignores the click would
#      pass (1) and still have thrown the consent away;
#   3. the negative control. THIS IS NOT OPTIONAL: an empty result from
#      `xwininfo` proves nothing until the same instrument has been shown
#      producing a non-empty one. With /usr/bin/yad moved aside, the identical
#      steps must find NO window and the script must fall into "Installation
#      cancelled". A gate that can only print PASS is not a gate.
#
# WHAT IT DOES NOT ASSERT, because yad is not zenity: the button labels. yad
# accepts every option this call passes without complaint, but it ignores
# --ok-label and --cancel-label -- zenity draws "Install"/"Cancel" and yad
# draws "OK"/"Cancel" (observed, screenshotted). The consent TEXT is identical
# and unabridged. Whether yad honours --default-cancel was not determined:
# there is no window manager on this Xvfb, so keyboard focus is not a fair
# test of it here, and the real session runs jwm.
#
# Usage: tests/linux/steam_consent_dialog.sh [image]
#   default image: build/image/distro.ext4
#   env: KEEP=1   keep the extracted root and the logs
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"
# shellcheck source=tests/linux/reap.sh
. tests/linux/reap.sh

IMG="${1:-build/image/distro.ext4}"
# /usr/sbin is not on an ordinary PATH, and a debugfs that "is not there"
# would make every extraction empty and every check below vacuous.
DEBUGFS="${DEBUGFS:-/usr/sbin/debugfs}"
command -v "$DEBUGFS" >/dev/null 2>&1 || DEBUGFS=debugfs

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "PASS: $*"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
skip() { echo "SKIP: $*" >&2; exit 0; }

[ -f "$IMG" ] || skip "no image at $IMG"
command -v "$DEBUGFS" >/dev/null 2>&1 || skip "no debugfs(8) (e2fsprogs); set \$DEBUGFS"
unshare -Urm --propagation private true 2>/dev/null \
    || skip "this host does not allow unprivileged user+mount namespaces"
CHROOT="${CHROOT:-$(command -v chroot || echo /usr/sbin/chroot)}"
[ -x "$CHROOT" ] || skip "no chroot(8)"

W="$(mktemp -d "${TMPDIR:-/tmp}/steamdlg.XXXXXX")"
reap_track "$W/reaped"
cleanup() {
    reap_all
    if [ "${KEEP:-0}" = 1 ]; then echo "kept $W" >&2; else rm -rf "$W"; fi
}
reap_on_exit cleanup

R="$W/root"
mkdir -p "$R"

# ---------------------------------------------------------------------------
# 0. EXTRACT. rdump reads the ext4 out of the plain file; it never mounts it.
# ---------------------------------------------------------------------------
echo "[0/4] extracting the rootfs from $IMG with debugfs (no mount, read-only)"
"$DEBUGFS" -R "rdump / $R" "$IMG" >"$W/rdump.log" 2>&1
# rdump lands the tree either directly in $R or in $R/<basename>; find it.
if [ ! -d "$R/usr" ] && [ -d "$R/$(basename "$IMG")" ]; then R="$R/$(basename "$IMG")"; fi
if [ ! -x "$R/usr/games/steam" ]; then
    bad "no /usr/games/steam in the extracted root -- steam-installer is not in this image, or the extraction failed (see $W/rdump.log)"
    echo; echo "$PASS passed, $FAIL failed"; exit 1
fi
ok "/usr/games/steam came out of the image ($(stat -c%s "$R/usr/games/steam") bytes)"

# WHAT THE SCRIPT ITSELF SAYS IT WILL DO. Read from the extracted copy, not
# from memory of what Debian ships -- if Valve's packager reorders these
# branches, the swap this gate defends stops being valid and this line is
# where that shows up.
if grep -q 'zenityish=yad' "$R/usr/games/steam"; then
    ok "/usr/games/steam names yad as a dialog it will use"
else
    bad "/usr/games/steam no longer names yad -- the zenity->yad swap in scripts/hamlinux_distro.sh is no longer supported by the caller"
fi
for b in yad zenity; do
    if [ -x "$R/usr/bin/$b" ]; then echo "     present in image: /usr/bin/$b"; fi
done
[ -x "$R/usr/bin/yad" ] || bad "the image has no /usr/bin/yad"

# ---------------------------------------------------------------------------
# the run, factored out because the negative control runs it identically
# ---------------------------------------------------------------------------
# $1 phase name, $2 action ("look" or "cancel"); runs steam under Xvfb inside
# the chroot, leaves $W/<phase>.steam.log and $W/<phase>.windows
run_phase() {
    local ph="$1" act="${2:-look}"
    unshare -Urm --propagation private bash -uc '
        R="$1"; CHROOT="$2"; W="$3"; ph="$4"; act="$5"
        mount -t proc proc "$R/proc" 2>/dev/null || true
        mount --rbind /dev "$R/dev"
        mount --rbind "$W" "$R/mnt"
        # A FRESH, EMPTY HOME is the whole trigger: /usr/games/steam prompts
        # exactly when its four `needed` paths under $STEAMDIR are missing,
        # and hamnix-steam pre-stages those in the real flow.
        rm -rf "$R/tmp/h"; mkdir -p "$R/tmp/h" "$R/tmp/xfb"
        "$CHROOT" "$R" /bin/sh -uc '"'"'
            ph="$1"; act="$2"
            export HOME=/tmp/h DISPLAY=:71 PATH=/usr/local/bin:/usr/bin:/bin:/usr/games
            Xvfb :71 -screen 0 1024x768x24 -fbdir /tmp/xfb -nolisten tcp \
                >/mnt/$ph.xvfb.log 2>&1 &
            xpid=$!
            for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
                [ -e /tmp/xfb/Xvfb_screen0 ] && break
                sleep 0.5
            done
            /usr/games/steam >/mnt/$ph.steam.log 2>&1 &
            spid=$!
            # yad/zenity need a moment to map a window; GTK on a cold image is
            # not instant. Poll rather than guess.
            for i in $(seq 1 40); do
                xwininfo -root -children 2>/dev/null | grep -q "yad\|zenity\|Steam\|steam" && break
                kill -0 $spid 2>/dev/null || break
                sleep 0.5
            done
            xwininfo -root -children >/mnt/$ph.windows 2>&1
            (xdotool search --onlyvisible --name . getwindowname %@ 2>/dev/null;
             xdotool search --class . getwindowclassname %@ 2>/dev/null) \
                >/mnt/$ph.names 2>&1
            ps -eo comm= >/mnt/$ph.ps 2>&1
            if [ "$act" = cancel ]; then
                # ANSWER IT, by clicking, at the coordinates the dialog really
                # occupies -- 600x248 at 0,0, because there is no window
                # manager here to move it. Cancel is the lower-right button.
                # A window that draws and ignores the click would pass a
                # "did it appear" check and still be broken.
                wid=$(xdotool search --name "Steam installer" | head -1)
                echo "window=$wid $(xdotool getwindowgeometry $wid 2>&1 | tr "\n" " ")" \
                    >/mnt/$ph.answer 2>&1
                xdotool windowactivate --sync $wid 2>/dev/null
                xdotool mousemove --window $wid 463 226 click 1 2>/dev/null
                for i in $(seq 1 20); do
                    kill -0 $spid 2>/dev/null || break
                    sleep 0.5
                done
                if kill -0 $spid 2>/dev/null; then
                    echo "steam still running after Cancel" >>/mnt/$ph.answer
                else
                    echo "steam exited after Cancel" >>/mnt/$ph.answer
                fi
            fi
            kill $spid 2>/dev/null
            sleep 1
            kill -9 $spid $xpid 2>/dev/null
            exit 0
        '"'"' _ "$ph" "$act"
    ' _ "$R" "$CHROOT" "$W" "$ph" "$act" >"$W/$ph.outer.log" 2>&1
}

# ---------------------------------------------------------------------------
# 1. THE ASSERTION: with yad installed, a dialog window appears.
# ---------------------------------------------------------------------------
echo "[1/4] running /usr/games/steam inside the image, on an offscreen X server"
run_phase yes look
if grep -qi 'yad' "$W/yes.windows" "$W/yes.names" "$W/yes.ps" 2>/dev/null; then
    ok "a yad window is on the X server -- the consent dialog appears"
    grep -i yad "$W/yes.windows" | head -3 | sed 's/^/     /'
else
    bad "no yad window found -- the consent prompt did NOT appear"
    echo "--- windows ---"; sed 's/^/     /' "$W/yes.windows" 2>/dev/null | head -20
    echo "--- steam ---";   sed 's/^/     /' "$W/yes.steam.log" 2>/dev/null | head -20
fi
if grep -q 'Installation cancelled' "$W/yes.steam.log" 2>/dev/null; then
    bad "the script printed 'Installation cancelled' -- it found no dialog program at all"
fi

# ---------------------------------------------------------------------------
# 2. THE NEGATIVE CONTROL. Same instrument, yad hidden: it must find NOTHING
#    and the script must say so. Without this, "a window was found" is not
#    evidence -- it is an unverified grep.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# 1b. IT IS A DIALOG, NOT A PICTURE. Clicking Cancel has to be what decides
#     that Steam is not installed -- otherwise the consent is decoration.
# ---------------------------------------------------------------------------
echo "[2/4] clicking Cancel on it"
run_phase cancel cancel
if grep -q 'Installation cancelled' "$W/cancel.steam.log" 2>/dev/null; then
    ok "clicking Cancel makes /usr/games/steam stop: 'steam: Installation cancelled'"
    sed 's/^/     /' "$W/cancel.answer" 2>/dev/null
else
    bad "clicking Cancel did not stop the install -- the dialog's answer is not being read"
    sed 's/^/     /' "$W/cancel.answer" 2>/dev/null
    sed 's/^/     /' "$W/cancel.steam.log" 2>/dev/null | head -10
fi

echo "[3/4] negative control: hide /usr/bin/yad and run the identical steps"
mv "$R/usr/bin/yad" "$R/usr/bin/yad.hidden"
run_phase no look
mv "$R/usr/bin/yad.hidden" "$R/usr/bin/yad"
if grep -qi 'yad' "$W/no.windows" 2>/dev/null; then
    bad "the control found a yad window with yad removed -- the check above proves nothing"
else
    ok "with yad gone the same check finds no dialog (the instrument can print both answers)"
fi
if grep -q 'Installation cancelled' "$W/no.steam.log" 2>/dev/null; then
    ok "and /usr/games/steam falls into 'Installation cancelled' -- the dead end this swap exists to avoid"
else
    bad "with no dialog program the script did not print 'Installation cancelled'; its branches have changed"
    sed 's/^/     /' "$W/no.steam.log" 2>/dev/null | head -20
fi

echo "[4/4] done"
echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
