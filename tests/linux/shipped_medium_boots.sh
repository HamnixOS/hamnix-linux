#!/usr/bin/env bash
#
# tests/linux/shipped_medium_boots.sh — BOOT THE BYTES WE SHIP, UNMODIFIED.
#
# REGISTRATION. This gate is deliberately not in ci_battery_manifest.txt because
# its input is a RELEASE ARTIFACT: a 4 GiB medium under ~/.hamnix-build/relNNNN
# that no CI runner has and that no step of this gate will build. It is a
# RELEASE gate: it is listed in HANDOFF.md's release gate table and is meant to
# be run by the release driver beside scripts/verify_medium.sh. When the
# artifact is absent this script exits NON-ZERO with 0 PASS and 0 FAIL and says
# INCONCLUSIVE in words -- because a release gate that quietly skips is the
# exact shape that let "40 of 40 pass" be written about 43 gates that scored
# nothing.
#
# WHY THIS FILE EXISTS -- THE HOLE IT CLOSES
# ==========================================
# Every other QEMU gate in this tree BUILDS ITS OWN MEDIUM. tests/linux/
# install_wizard_gui.sh, tests/linux/install_confirm_keys.sh and tests/linux/
# soak_desktop.sh each run scripts/hamlinux_disk.sh with HAMLINUX_DISK_RC
# pointing at an instrumented rc, so that the guest will narrate itself. Same
# sources, same commit -- NOT THE SAME BYTES. And scripts/verify_medium.sh, the
# one thing that does read the shipped artifact, reads it STATICALLY: it
# inspects partitions, the ESP and file presence with sfdisk/debugfs/mtools and
# never runs it.
#
# So the file a person writes to a USB stick was gated and never booted, and a
# defect introduced by the image-assembly step -- after the last thing any gate
# checks -- would ship. That is not hypothetical: root.partuuid was written to
# the root filesystem and never copied to the ESP, and the medium verified 39/0
# for weeks while its installer could not install.
#
# WHAT "UNMODIFIED" MEANS HERE, AND HOW IT IS PROVED RATHER THAN PROMISED
# ======================================================================
# This gate never calls scripts/hamlinux_image.sh or scripts/hamlinux_disk.sh,
# never sets HAMLINUX_DISK_RC, and never writes to the release artifact. It
# makes ONE copy (QEMU must be free to write to the disk it boots, exactly as a
# real stick is written to) and asserts the copy's sha256 equals the artifact's
# BEFORE booting it. Section A is that proof and it is run first: if the bytes
# under test are not the shipped bytes, nothing below is about the release.
#
# EVERY OBSERVATION IS EXTERNAL. There is no agent inside the guest and no seam
# cut into the image. Three channels only, all of them outside it:
#
#   * the SERIAL LOG -- and the strings waited for are the SHIPPED rc's own
#     ('[rc.5] compositor started', '[rc.5] desktop up', 'rc.boot: up'), not a
#     marker this gate planted. The shipped kernel command line ends
#     'console=ttyS0,115200 console=tty0', so a write to /dev/console reaches
#     both, which is why this works with nothing injected.
#   * HMP screendump -- the framebuffer, which is what a person sees.
#   * QMP input-send-event -- virtio-keyboard-pci and virtio-tablet-pci, the
#     same path a person's keyboard and mouse take.
#
# THE HEADLINE FIX, MEASURED ON THE SHIPPED BYTES FOR THE FIRST TIME
# =================================================================
# 1.0.29's headline fix is the console-keystroke bug: wsysd's fd 0 is
# /dev/console, /dev/console reads from tty0, tty0 is the same VT the evdev
# keyboard feeds, and pump_keyboard() routed every byte it read there to the
# focused window -- so every key arrived TWICE, and because the tty is
# CANONICAL, a Return released the WHOLE COOKED LINE into the next window.
# tests/linux/wsys_stdin_keydup.sh proves the fix at unit scale against an
# offscreen framebuffer, and the wizard and soak gates prove it on media they
# rebuilt. NOTHING HAD EVER CHECKED IT ON THE SHIPPED IMAGE.
#
# THE WITNESS IS A COUNTER, NOT A PICTURE OF LETTERS. /bin/hameditscene draws
# 'Ln <n>, Col <n>' in its status bar. That is an exact count of the characters
# and newlines the window received, and it is read by OCR as two integers --
# which an 8-px font survives far better than a comparison of glyph strings.
# N keystrokes must advance Col by exactly N. Under the defect they advance it
# by 2N, and a Return adds a whole replayed line.
#
# TWO CONTROLS ARE RUN, IN THIS ORDER, BECAUSE "IT WAS NOT DOUBLED" IS
# SATISFIED BY AN INSTRUMENT THAT CANNOT SEE DOUBLING AND BY A CONSOLE THAT
# NEVER RECEIVED THE KEYSTROKE:
#
#   F1 SENSITIVITY, RUN FIRST. Two presses of one key in a single burst must
#      advance Col by exactly 2. A counter that reported +1 for two presses
#      would report +N for the doubled case and pass this gate against the
#      very defect it exists to expose.
#   F4 TTY LIVENESS, RUN. The console shell (PID 1's hamsh REPL, prompting
#      'hamsh$' on /dev/console) must be shown to have received the SAME
#      characters -- it echoes them and, on Return, runs the line and reports
#      'command not found: <token>' on the serial log. Without this, "the
#      keystrokes did not reach the window twice" is also true of a machine
#      whose tty received nothing at all, and that is not the fix.
#
# THE NEGATIVE CONTROL IS RUN AND IT IS A SECOND BOOT (section G): a copy whose
# ESP has been overwritten with zeros must NOT reach the desktop. Without it,
# every green above is also what this gate prints for a medium it cannot boot.
#
# NEVER TOUCHES A PHYSICAL DEVICE. One QEMU with one file-backed disk on xHCI
# and no target disks attached; -display none; it never opens this host's
# /dev/input/*, /dev/dri/card0 or its sound hardware, and it never writes to
# the release artifact.
#
# MEASURED, dev host, 2026-08-18: green arm reaches 'rc.boot: up' about 10 s
# after power-on and the desktop is painted and driveable well inside a minute.
#
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

# ---------------------------------------------------------------- the artifact
IMG="${1:-${HAMLINUX_SHIPPED_IMG:-$HOME/.hamnix-build/rel1029/hamnix-linux-1.0.29.img}}"
WANT_SHA="${HAMLINUX_SHIPPED_SHA:-1601bc486ca0c50dd6f14cd04556524d6d4aec1ff0c36e0cd279ef422c27339c}"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  PASS  $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL  $*"; }
info() { echo "        $*"; }
say()  { echo; echo "== $* =="; }

finish() {
    echo
    printf '[shipped_medium_boots] RESULT: %d PASSED / %d FAILED\n' "$PASS" "$FAIL"
    info "artifact: $IMG"
    info "evidence: $WORK"
    [ "$FAIL" = 0 ] || exit 1
    exit 0
}

echo "=== tests/linux/shipped_medium_boots.sh -- booting the published artifact"
echo "artifact: $IMG"

for t in qemu-system-x86_64 socat python3 tesseract convert sha256sum; do
    command -v "$t" >/dev/null || { echo "INCONCLUSIVE: need $t"; exit 2; }
done
[ -r /usr/share/OVMF/OVMF_CODE_4M.fd ] || { echo "INCONCLUSIVE: need OVMF"; exit 2; }
QMP_INPUT="$PROJ_ROOT/tests/linux/qmp_input.py"
PPMDIFF="$PROJ_ROOT/tests/linux/ppmdiff.py"
[ -f "$QMP_INPUT" ] || { echo "INCONCLUSIVE: need tests/linux/qmp_input.py"; exit 2; }
[ -f "$PPMDIFF" ]   || { echo "INCONCLUSIVE: need tests/linux/ppmdiff.py"; exit 2; }

if [ ! -f "$IMG" ]; then
    echo
    echo "INCONCLUSIVE -- 0 PASSED, 0 FAILED, AND THAT IS NOT A PASS."
    echo "The release artifact is not on this machine:"
    echo "    $IMG"
    echo "This gate boots the published medium and will not substitute a rebuilt"
    echo "one for it; a rebuilt medium is the very substitution it exists to end."
    echo "Point it at the artifact:  HAMLINUX_SHIPPED_IMG=... bash \$0"
    exit 2
fi

WORK="${HAMLINUX_SHIPPED_WORK:-$HOME/.hamnix-build/shipped-boot-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$WORK" || { echo "INCONCLUSIVE: cannot create $WORK"; exit 2; }

SCREEN_W=1280
SCREEN_H=800

# ===========================================================================
say "A -- ARE THESE THE SHIPPED BYTES? (asserted before anything is booted)"
# ===========================================================================
# THE COPY IS NOT A CONVENIENCE, IT IS THE ONLY WRITE. QEMU writes to the disk
# it boots (the guest mounts its root rw -- the shipped command line says so),
# and the release artifact must come out of this gate bit-identical to how it
# went in. So: copy, then prove the copy IS the artifact, then boot the copy
# and never look at the original again.
IMG_SHA=$(sha256sum <"$IMG" | cut -d' ' -f1)
info "artifact sha256: $IMG_SHA"
if [ "$IMG_SHA" = "$WANT_SHA" ]; then
    ok "the artifact's sha256 is the published digest ($WANT_SHA)"
else
    bad "the artifact's sha256 is $IMG_SHA, NOT the published digest $WANT_SHA -- this is not the medium this gate was pointed at, and every result below describes some other file"
fi

COPY="$WORK/booted.img"
info "copying $(stat -c%s "$IMG") bytes to $COPY"
cp "$IMG" "$COPY" || { bad "could not copy the artifact"; finish; }
COPY_SHA=$(sha256sum <"$COPY" | cut -d' ' -f1)
info "copy sha256:     $COPY_SHA"
if [ "$COPY_SHA" = "$IMG_SHA" ]; then
    ok "the copy about to be booted is byte-for-byte the artifact ($COPY_SHA)"
else
    bad "the copy differs from the artifact -- the boot below is not of the shipped bytes"
fi

# NO REBUILD AND NO INJECTED rc, ASSERTED ON THIS SCRIPT'S OWN TEXT rather than
# claimed in a comment. The three names below are exactly the seams the other
# QEMU gates use to make a medium of their own.
SELF="${BASH_SOURCE[0]}"
# THE THREE SEAM NAMES ARE ASSEMBLED FROM FRAGMENTS, and that is not cuteness:
# spelled whole, the pattern would match the line that carries it and this
# assertion would be red on a gate that is behaving correctly -- the same shape
# as the tok-capacity gate that was red for seven weeks about its own grep.
S1="hamlinux_""disk.sh"
S2="hamlinux_""image.sh"
S3="HAMLINUX_""DISK_RC="
LIVE=$(grep -n -v '^[[:space:]]*#' "$SELF" | grep -F -e "$S1" -e "$S2" -e "$S3")
if [ -n "$LIVE" ]; then
    bad "this gate has a live (non-comment) reference to a medium-building seam -- it is building or instrumenting a medium and is no longer a test of the shipped one:"
    printf '%s\n' "$LIVE" | head -5 | sed 's/^/        | /'
else
    ok "this gate has no live reference to the medium-building seams the other QEMU gates use -- it cannot be building or instrumenting a medium of its own"
fi
# AND THE SAME SEARCH IS SHOWN ABLE TO FIND ONE, RUN: the comment block above
# names all three, so a search that found nothing there is a broken search.
INCOMMENT=$(grep -c -F -e "$S1" -e "$S2" -e "$S3" "$SELF")
if [ "${INCOMMENT:-0}" -ge 1 ]; then
    ok "and that same search DOES find those names in this file's comments ($INCOMMENT lines), so 'no live reference' is a measurement and not a broken grep"
else
    bad "the seam search finds those names nowhere in this file at all, including the comments that spell them out -- the search is broken and the result above is vacuous"
fi
RCVAR="HAMLINUX_""DISK_RC"
if [ -n "$(eval "printf '%s' \"\${$RCVAR:-}\"")" ]; then
    bad "$RCVAR is set in this environment -- refusing to report on a run whose environment asks for an injected rc"
else
    ok "$RCVAR is unset in this environment"
fi

[ "$FAIL" = 0 ] || { info "the bytes under test are not established; not booting"; finish; }

# ---------------------------------------------------------------------------
# HARNESS
# ---------------------------------------------------------------------------
QPID=""
D=""
kill_guest() {
    [ -n "$QPID" ] || return 0
    [ -n "$D" ] || return 0
    printf 'quit\n' | timeout 10 socat - "UNIX-CONNECT:$D/mon.sock" >/dev/null 2>&1
    sleep 2
    # BY PID, and never by pattern: `pkill -f qemu` on this host would take out
    # whatever else is booting. $! is the pid; a name match is not.
    kill -TERM "$QPID" 2>/dev/null
    sleep 1
    kill -KILL "$QPID" 2>/dev/null
    wait "$QPID" 2>/dev/null
    QPID=""
}
trap 'kill_guest' EXIT

# boot_guest <dir> <disk-image> -- starts QEMU, sets D and QPID.
boot_guest() {
    D="$1"; local disk="$2"
    rm -rf "$D"; mkdir -p "$D/shots"
    cp /usr/share/OVMF/OVMF_VARS_4M.fd "$D/OVMF_VARS.fd"
    : >"$D/serial.log"
    # NO TARGET DISKS ARE ATTACHED. The medium carries /etc/installer-medium so
    # the desktop offers 'Install Hamnix'; this gate never opens it, and with no
    # blank disk in the machine there is nothing an accidental click could
    # write to but the stick's own copy.
    qemu-system-x86_64 \
        -m 2048 -smp 2 -no-reboot \
        -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
        -drive "if=pflash,format=raw,unit=1,file=$D/OVMF_VARS.fd" \
        -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
        -display none -vga std \
        -serial "file:$D/serial.log" \
        -enable-kvm -cpu host \
        -monitor "unix:$D/mon.sock,server,nowait" \
        -qmp "unix:$D/qmp.sock,server,nowait" \
        -device virtio-keyboard-pci -device virtio-tablet-pci \
        -device qemu-xhci,id=xhci \
        -drive "file=$disk,if=none,format=raw,id=usbstick" \
        -device usb-storage,bus=xhci.0,drive=usbstick,bootindex=0 \
        >"$D/qemu.out" 2>&1 &
    QPID=$!
    info "qemu pid $QPID, serial $D/serial.log"
}

# wait_for_desktop <seconds> -- 0 if the SHIPPED rc's own last line appears.
wait_for_desktop() {
    local limit="$1" i=0
    while [ "$i" -lt "$limit" ]; do
        sleep 2; i=$((i+2))
        grep -aq 'rc\.boot: up' "$D/serial.log" 2>/dev/null && { BOOT_SECS=$i; return 0; }
        # A ZOMBIE ANSWERS YES TO kill -0, so liveness is read from the state
        # letter in /proc/<pid>/stat, not from a signal.
        local st
        st=$(awk '{print $3}' "/proc/$QPID/stat" 2>/dev/null)
        case "${st:-X}" in Z|X) BOOT_SECS=$i; return 1 ;; esac
    done
    BOOT_SECS=$i
    return 1
}

hmp()  { printf '%s\n' "$1" | timeout 20 socat - "UNIX-CONNECT:$D/mon.sock" 2>/dev/null; }
qi()   { timeout 60 python3 "$QMP_INPUT" "$D/qmp.sock" "$@" 2>&1; }
pd()   { python3 "$PPMDIFF" "$@" 2>/dev/null; }

# shot <tag> -- a screendump kept for a human. Prints the ppm path.
shot() {
    local p="$D/shots/$1.ppm"
    rm -f "$p"
    hmp "screendump $p" >/dev/null
    local prev=-1 n i=0
    while [ "$i" -lt 40 ]; do
        sleep 0.25; i=$((i+1))
        n=$(stat -c%s "$p" 2>/dev/null || echo 0)
        [ "$n" -gt 0 ] && [ "$n" = "$prev" ] && break
        prev="$n"
    done
    [ -s "$p" ] || return 1
    printf '%s' "$p"
}

# ocr <ppm> <base> <geom> -- upscaled, thresholded, --psm 6. The 8-px bitmap
# font is not resolvable at native size; 300% is what the wizard gate uses.
ocr() {
    local ppm="$1" base="$2" geom="$3"
    convert "$ppm" -crop "$geom" +repage -colorspace Gray -resize 300% \
        -sharpen 0x1 "$base.png" 2>/dev/null || return 1
    tesseract "$base.png" "$base" --psm 6 >/dev/null 2>&1 || return 1
    [ -s "$base.txt" ]
}

# THE EDITOR WINDOW. Measured from a screendump of this medium before it was
# used: /bin/hameditscene's window lands at 180,96 and is 400x290, and its
# status bar reads 'Ln <n>, Col <n>' in the bottom right. The whole window is
# OCR'd rather than a tight crop of the status bar, so that a window that moved
# still yields its numbers instead of yielding nothing.
EWIN_GEOM="400x290+180+96"
EDIT_LN=""; EDIT_COL=""; EDIT_TXT=""
read_lncol() {   # <tag> -> EDIT_LN / EDIT_COL / EDIT_TXT, 1 if unreadable
    local tag="$1" p
    p=$(shot "$tag") || return 1
    ocr "$p" "$D/shots/$tag" "$EWIN_GEOM" || return 1
    EDIT_TXT=$(cat "$D/shots/$tag.txt")
    local m
    m=$(printf '%s' "$EDIT_TXT" | grep -oE 'Ln[[:space:]]*[0-9]+,[[:space:]]*Col[[:space:]]*[0-9]+' | tail -1)
    [ -n "$m" ] || return 1
    EDIT_LN=$(printf '%s' "$m" | sed 's/.*Ln[[:space:]]*\([0-9]*\).*/\1/')
    EDIT_COL=$(printf '%s' "$m" | sed 's/.*Col[[:space:]]*\([0-9]*\).*/\1/')
    return 0
}

# ===========================================================================
say "B -- IT BOOTS: the shipped medium, on xHCI mass storage, to its own rc"
# ===========================================================================
boot_guest "$WORK/green" "$COPY"
if wait_for_desktop 180; then
    ok "the shipped medium reached its own rc.boot's last line in ${BOOT_SECS}s -- 'rc.boot: up' on the serial console, a string the SHIPPED rc prints and this gate did not plant"
else
    bad "the shipped medium did NOT reach 'rc.boot: up' in ${BOOT_SECS}s. This is the release artifact failing to boot; read $D/serial.log and $D/qemu.out"
    info "--- last 40 lines of serial ---"
    tail -40 "$D/serial.log" 2>/dev/null | sed 's/^/        | /'
    finish
fi

while IFS= read -r s; do
    [ -n "$s" ] || continue
    if grep -aqF "$s" "$D/serial.log"; then
        ok "the guest's own console says: $s"
    else
        bad "the guest's console never said: $s -- read $D/serial.log"
    fi
done <<'SERIALEOF'
[rc.5] compositor started
[rc.5] desktop backdrop started
[rc.5] panel started
[rc.5] desktop up
SERIALEOF

# THE NEGATIVE FOR THE SERIAL GREP, RUN. A grep that matched anything would
# have passed all four above on an empty file.
if grep -aqF '[rc.5] this string is not in any boot log' "$D/serial.log"; then
    bad "the serial grep matches a string that is not there -- it cannot discriminate, and the four results above are worthless"
else
    ok "and the same grep does NOT match a string that is not in the log, so those four are real matches"
fi

if grep -aqE 'Kernel panic|BUG: unable to handle|Oops:' "$D/serial.log"; then
    bad "the kernel panicked or oopsed during this boot -- read $D/serial.log"
else
    ok "no kernel panic, oops or unhandled fault on the console during the boot"
fi

# ===========================================================================
say "C -- THE COMPOSITOR PAINTS (the framebuffer, which is what a person sees)"
# ===========================================================================
sleep 8
P1=$(shot c1_desktop) && ok "the framebuffer can be screendumped ($(stat -c%s "$P1") bytes)" \
    || { bad "no screendump could be taken -- nothing below about the picture can be measured"; finish; }

RECT=$(pd rect "$P1")
info "$RECT"
NCOL=$(printf '%s' "$RECT" | sed -n 's/.*: \([0-9][0-9]*\) distinct of.*/\1/p')
NCOL="${NCOL:-0}"
info "distinct colours in the full 1280x800 frame: $NCOL"
if [ "$NCOL" -ge 64 ]; then
    ok "the frame carries $NCOL distinct colours -- a painted desktop, not a blank or single-colour screen"
else
    bad "the frame carries only $NCOL distinct colours -- the compositor has not painted anything a person would call a desktop"
fi

# THE DIFFER IS PROVED BEFORE IT IS BELIEVED, AND THE PROOF IS RUN.
cp "$P1" "$D/shots/c1_same.ppm"
SAMEOUT=$(pd diff "$P1" "$D/shots/c1_same.ppm")
info "$SAMEOUT"
# The word IDENTICAL is required rather than a parsed zero, because a parse of
# NO OUTPUT AT ALL also yields zero and would report a broken comparator as a
# perfect one.
if printf '%s' "$SAMEOUT" | grep -q 'IDENTICAL'; then
    ok "the frame comparator reports IDENTICAL for a frame against itself, so it does not invent differences"
else
    bad "the frame comparator did not report IDENTICAL for a frame against ITSELF -- it said: ${SAMEOUT:-<no output at all>}. It is noise or it is broken, and no change it reports below is a change"
fi

# AND IT IS SHOWN ABLE TO REPORT A CHANGE: the pointer is moved across the
# desktop and the picture must differ. A compositor that had painted once and
# died would pass every colour count above and fail this.
qi move 900 600 "$SCREEN_W" "$SCREEN_H" >/dev/null
sleep 3
P2=$(shot c2_moved)
MOVEDOUT=$(pd diff "$P1" "$P2")
info "$MOVEDOUT"
MOVED=$(printf '%s' "$MOVEDOUT" | sed -n 's/.*: \([0-9][0-9]*\) of .* differ.*/\1/p')
MOVED="${MOVED:-0}"
info "pixels differing after the pointer was moved: $MOVED"
if [ "$MOVED" -gt 0 ]; then
    ok "the picture CHANGES when the pointer moves (${MOVED} pixels) -- the compositor is still drawing frames, not showing a corpse"
else
    bad "the picture did not change at all when the pointer was moved -- the compositor may have painted once and stopped"
fi

# ===========================================================================
say "D -- WHAT A PERSON SEES IN THE FIRST MINUTE, READ AS TEXT"
# ===========================================================================
if ocr "$P1" "$D/shots/d_panel" "${SCREEN_W}x28+0+0"; then
    PANEL=$(cat "$D/shots/d_panel.txt")
    info "panel OCR: $(printf '%s' "$PANEL" | tr '\n' '|' | cut -c1-160)"
    printf '%s' "$PANEL" | grep -qi 'applic' \
        && ok "the top panel says 'Applications' -- the menu a person reaches for is on the screen" \
        || bad "the top panel does not read 'Applications'"
    printf '%s' "$PANEL" | grep -qiE '[0-9]{1,2}:[0-9]{2}' \
        && ok "the panel carries a clock" \
        || bad "the panel carries no clock"
    # OCR NEGATIVE CONTROL, RUN.
    printf '%s' "$PANEL" | grep -qi 'Step 5 of 5' \
        && bad "the panel OCR reports text that is certainly not on it -- it matches anything and cannot discriminate" \
        || ok "and the panel OCR does NOT report text that is not there"
else
    bad "the panel strip could not be OCR'd"
fi

if ocr "$P1" "$D/shots/d_icons" "200x760+0+28"; then
    ICONS=$(cat "$D/shots/d_icons.txt")
    info "desktop-icon OCR: $(printf '%s' "$ICONS" | tr '\n' ' ' | cut -c1-200)"
    NFOUND=0
    for lbl in Calculator Terminal Files Notes Calendar; do
        printf '%s' "$ICONS" | grep -qi "$lbl" && NFOUND=$((NFOUND+1))
    done
    if [ "$NFOUND" -ge 3 ]; then
        ok "the desktop shows its launcher icons -- $NFOUND of 5 sampled labels read back (Calculator/Terminal/Files/Notes/Calendar)"
    else
        bad "only $NFOUND of 5 sampled desktop icon labels could be read -- the desktop may be empty"
    fi
else
    bad "the desktop icon column could not be OCR'd"
fi

# ===========================================================================
say "E -- A WINDOW OPENS FROM THE MOUSE (no launch queue, no injected rc)"
# ===========================================================================
# The 'Text Editor' desktop icon, double-clicked, exactly as a person opens it.
# Its coordinates were read off a screendump of THIS medium before use.
qi click 52 327 "$SCREEN_W" "$SCREEN_H" >/dev/null
sleep 1
qi click 52 327 "$SCREEN_W" "$SCREEN_H" >/dev/null
sleep 8

if read_lncol e1_open; then
    ok "double-clicking the Text Editor icon opened a window, and its status bar reads Ln $EDIT_LN, Col $EDIT_COL"
    info "editor window OCR: $(printf '%s' "$EDIT_TXT" | tr '\n' '|' | cut -c1-160)"
else
    bad "no editor window with a readable 'Ln n, Col n' status bar appeared after a double-click on the Text Editor icon -- the keystroke measurement below has no witness; read $D/shots/"
    finish
fi
if [ "$EDIT_LN" = 1 ] && [ "$EDIT_COL" = 1 ]; then
    ok "the new editor buffer is empty (Ln 1, Col 1) -- the counter starts where the arithmetic below assumes"
else
    bad "the new editor buffer reports Ln $EDIT_LN, Col $EDIT_COL instead of Ln 1, Col 1"
fi

# Focus the body by clicking inside it, as a person would.
qi click 380 250 "$SCREEN_W" "$SCREEN_H" >/dev/null
sleep 3
read_lncol e2_focus || { bad "the status bar became unreadable after clicking into the body"; finish; }
BASE_LN="$EDIT_LN"; BASE_COL="$EDIT_COL"
info "baseline before any typing: Ln $BASE_LN, Col $BASE_COL"

# ===========================================================================
say "F -- THE CONSOLE-KEYSTROKE FIX, ON THE SHIPPED BYTES"
# ===========================================================================
SER_MARK=$(wc -c <"$D/serial.log")

# --- F1 SENSITIVITY CONTROL, RUN FIRST ------------------------------------
# Two presses of one key. Col must advance by exactly 2. If this counter
# reported +1 for two presses it could not tell a single keystroke from a
# doubled one, and F2 below would pass against the defect.
qi burst a 2 >/dev/null
sleep 4
if read_lncol f1_burst; then
    D1=$((EDIT_COL - BASE_COL))
    info "two presses of one key: Col $BASE_COL -> $EDIT_COL (delta $D1)"
    if [ "$D1" = 2 ]; then
        ok "SENSITIVITY CONTROL: two keypresses advance the column counter by exactly 2, so this instrument CAN report the doubled case that the defect produces"
    else
        bad "SENSITIVITY CONTROL FAILED: two keypresses advanced the column counter by $D1, not 2 -- this instrument cannot distinguish one keystroke from two and no result below is a measurement of the fix"
    fi
    BASE_LN="$EDIT_LN"; BASE_COL="$EDIT_COL"
else
    bad "the status bar could not be read after the sensitivity burst"
    finish
fi

# --- F2 N KEYSTROKES MUST BE N CHARACTERS ---------------------------------
# The token is a word that is not a command, so that when the console shell
# below runs the line it says so by name.
TOKEN=hamgatetoken
NCH=${#TOKEN}
qi type "$TOKEN" >/dev/null
sleep 4
if read_lncol f2_typed; then
    D2=$((EDIT_COL - BASE_COL))
    info "$NCH keystrokes: Col $BASE_COL -> $EDIT_COL (delta $D2; the defect gives $((NCH*2)))"
    if [ "$D2" = "$NCH" ]; then
        ok "THE FIX HOLDS ON THE SHIPPED BYTES: $NCH keystrokes put exactly $NCH characters in the focused window. Under the console-keystroke defect each key arrived twice and this would read $((NCH*2))"
    elif [ "$D2" = "$((NCH*2))" ]; then
        bad "THE CONSOLE-KEYSTROKE DEFECT IS BACK ON THE SHIPPED MEDIUM: $NCH keystrokes put $D2 characters in the focused window -- every key arrived twice, once from evdev and once from the console tty"
    else
        bad "$NCH keystrokes put $D2 characters in the focused window -- neither $NCH nor the defect's $((NCH*2)); read $D/shots/f2_typed.png"
    fi
    BASE_LN="$EDIT_LN"; BASE_COL="$EDIT_COL"
else
    bad "the status bar could not be read after typing"
    finish
fi

# --- F3 RETURN MUST BE ONE NEWLINE, NOT A REPLAYED LINE -------------------
# This is the worse half of the defect and the half a person actually saw: the
# console tty is CANONICAL, so it held the whole line and released it on
# Return. The window then received one newline from evdev AND the entire cooked
# line after it.
qi key ret >/dev/null
sleep 4
if read_lncol f3_return; then
    DL=$((EDIT_LN - BASE_LN))
    info "one Return: Ln $BASE_LN -> $EDIT_LN, Col -> $EDIT_COL"
    info "editor buffer OCR: $(printf '%s' "$EDIT_TXT" | tr '\n' '|' | cut -c1-160)"
    if [ "$DL" = 1 ] && [ "$EDIT_COL" = 1 ]; then
        ok "one Return produced exactly one new line and left the caret at column 1 -- the canonical console line was NOT replayed into the window"
    else
        bad "one Return moved the caret by $DL lines to column $EDIT_COL. Under the console-keystroke defect the tty releases the whole cooked line on Return, which is what this shape looks like; read $D/shots/f3_return.png"
    fi
else
    bad "the status bar could not be read after Return"
fi

# --- F4/F5 TTY LIVENESS CONTROL, RUN --------------------------------------
# Everything above is also true of a machine whose text console received
# NOTHING. The console shell must be shown to have received the same
# characters. PID 1's hamsh prompts 'hamsh$' on /dev/console, and the shipped
# command line carries console=ttyS0 beside console=tty0, so its echo and its
# reaction land on this serial log with nothing injected.
SINCE="$D/serial-since-typing.txt"
tail -c +$((SER_MARK+1)) "$D/serial.log" | tr -d '\r' >"$SINCE"
info "--- the text console, while the above was typed ---"
tail -6 "$SINCE" | sed 's/^/        | /'
if grep -q "$TOKEN" "$SINCE"; then
    ok "TTY LIVENESS CONTROL: the text console received the same characters -- the console shell echoed '$TOKEN' onto the serial log. So the keystrokes really did pass through the tty, and 'they did not arrive twice' is about the fix and not about a dead console"
else
    bad "TTY LIVENESS CONTROL FAILED: the text console shows no sign of '$TOKEN'. The keystrokes may never have reached the console tty at all, in which case nothing above measures the console-keystroke fix -- it measures a machine that has no console keystrokes to leak"
fi
if grep -qE "command not found:.*$TOKEN" "$SINCE"; then
    ok "and the console shell RAN the line on Return, reporting 'command not found' for it by name -- the console's line discipline delivered the whole cooked line to the shell, which is exactly the line the defect used to replay into the window"
else
    bad "the console shell did not report 'command not found' naming '$TOKEN' after Return -- the cooked line was not delivered to the console shell, so the replay half of the defect (F3) was not actually exercised"
fi

kill_guest

# ===========================================================================
say "G -- NEGATIVE CONTROL, RUN: a medium that does not boot must go RED"
# ===========================================================================
# Without this, everything above is also what this gate prints for a medium it
# cannot boot -- and this tree has already shipped one control that passed
# against the very defect it existed to expose.
#
# THE CORRUPTION IS THE ESP, not a random byte. Partition 1 starts at sector
# 2048 and carries \EFI\BOOT\BOOTX64.EFI, the only thing the firmware will run.
# Sixteen MiB of zeros over its start destroys the FAT boot sector and the
# start of the UKI, so the firmware finds nothing bootable. It is deterministic:
# a random flipped byte in a 4 GiB image usually lands in slack and boots fine,
# which would make this control pass for the wrong reason.
NEG="$WORK/corrupt.img"
cp "$COPY" "$NEG"
dd if=/dev/zero of="$NEG" bs=1M seek=1 count=16 conv=notrunc status=none
NEG_SHA=$(sha256sum <"$NEG" | cut -d' ' -f1)
if [ "$NEG_SHA" != "$IMG_SHA" ]; then
    ok "the negative control's medium differs from the artifact ($NEG_SHA) -- the corruption was actually applied"
else
    bad "the negative control's medium has the SAME digest as the artifact -- nothing was corrupted and the control below is a second green arm"
fi

boot_guest "$WORK/red" "$NEG"
# 90 s: the green arm reached this line in about 10 s on the host that wrote
# this file, so 90 is nine times the measured figure and not a guess.
if wait_for_desktop 90; then
    bad "NEGATIVE CONTROL FAILED: a medium with 16 MiB of zeros over its ESP still reported 'rc.boot: up'. This gate cannot tell a bootable medium from an unbootable one, and section B's green says nothing"
else
    ok "NEGATIVE CONTROL: the corrupted medium did NOT reach 'rc.boot: up' in ${BOOT_SECS}s -- section B's green is a measurement, because this gate goes red when handed a medium that does not boot"
fi

# AND WHY IT DID NOT BOOT IS NAMED, not left to be inferred from an absence.
# A control that only says "the string never appeared" is also satisfied by a
# QEMU that never started, which is not the thing being controlled for. The
# firmware says so itself when it cannot find a loader on the medium.
if grep -aqE 'failed to load Boot[0-9]+|EFI Internal Shell|UEFI Interactive Shell' \
        "$D/serial.log"; then
    ok "and the firmware itself says why: it could not load a boot entry off the corrupted medium and fell through to the EFI shell -- so the red above is the MEDIUM failing, not the harness failing to start a machine"
else
    bad "the corrupted run produced no firmware complaint about the medium either -- 'it did not boot' here may be this harness never starting QEMU rather than the medium being unbootable; read $D/serial.log and $D/qemu.out"
fi

PN=$(shot g1_corrupt) || PN=""
if [ -z "$PN" ]; then
    bad "no screendump could be taken of the corrupted run, so the panel assertion below was not made"
elif ocr "$PN" "$D/shots/g1_panel" "${SCREEN_W}x28+0+0"; then
    if grep -qi 'applic' "$D/shots/g1_panel.txt"; then
        bad "NEGATIVE CONTROL FAILED: the corrupted medium painted a desktop panel with 'Applications' on it"
    else
        ok "and the corrupted medium's panel strip OCRs to text that is not 'Applications' -- section D's OCR assertion also goes red on an unbootable medium"
    fi
else
    ok "and the corrupted medium's panel strip OCRs to NOTHING AT ALL (empty), which is what a screen with no desktop on it gives -- section D's OCR assertion also goes red on an unbootable medium"
fi
kill_guest

finish
