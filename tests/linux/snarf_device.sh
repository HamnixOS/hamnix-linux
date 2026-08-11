#!/usr/bin/env bash
# tests/linux/snarf_device.sh — COPY IN ONE PROGRAM, PASTE IN ANOTHER.
#
# The oracle for user/linux-snarf.c, the /dev/snarf and /dev/snarf.primary
# device. QEMU-free; a few seconds after the compiler is warm.
#
# WHY IT IS TWO PROCESSES AND TWO LIBRARIES.  "The file exists" is not the
# claim; "copy and paste between programs works" is. So tests/linux/snarfcopy.ad
# copies through lib/hamtextbox.ad (the editor / Notes / browser-URL-bar path)
# and tests/linux/snarfpaste.ad pastes through lib/htermsel.ad (the grid
# terminal's path), in a SEPARATE process each time. Nothing is shared between
# them but the device. The two libraries carry independent copies of the path
# selector, so this also proves they agree about which name is which buffer.
#
# WHY IT RUNS UNDER A PRIVATE MOUNT NAMESPACE WITH A tmpfs OVER /dev.  Two
# reasons, and the second is the interesting one:
#
#   1. The dev host's real /dev is never a test fixture. That rule is why the
#      measurement in docs/linux_build_count.md §4 was trustworthy.
#   2. It is the NEGATIVE CONTROL. Because /dev/snarf is SERVED -- intercepted
#      inside the process by dev_path() before the filesystem is consulted --
#      an empty tmpfs over /dev must not stop copy and paste from working, and
#      after a full copy/paste run there must still be NO FILE at /dev/snarf.
#      A run that passed by planting two ordinary files would fail assertion
#      "nothing was created", and a run that passed by reaching the host's
#      /dev would fail inside the namespace. Both failure modes are excluded
#      by construction rather than by inspection.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
cd .. || exit 1

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  PASS  $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL  $*"; }
chk()  { # chk <label> <expected> <actual>
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$2] got [$3]"; fi
}

OUT="${HAMSNARF_TEST_OUT:-build/snarf}"
mkdir -p "$OUT" || exit 1

echo "[snarf] building the two probes ..."
for p in snarfcopy snarfpaste; do
    if ! scripts/hamlinux_build.sh "tests/linux/$p.ad" "$OUT/$p.elf" \
            >"$OUT/$p.build.log" 2>&1; then
        echo "[snarf] FAIL: tests/linux/$p.ad did not build"
        tail -30 "$OUT/$p.build.log"; exit 1
    fi
done
echo "[snarf] probes built"

# The body runs INSIDE the namespace. It is a separate file rather than a -c
# string so quoting cannot silently change what is measured.
BODY="$OUT/body.sh"
cat >"$BODY" <<'INNER'
set -u
OUT="$1"
CP="$OUT/snarfcopy.elf"
PA="$OUT/snarfpaste.elf"

# /dev/null HAS TO SURVIVE, and finding that out is worth writing down.
#
# Every synthetic device on this line -- fb, wsys, net, auth, audio, and now
# snarf -- gets its fd from devtab_open, which opens /dev/null so the slot is
# a REAL descriptor that survives fork and cannot collide with an ordinary
# open. A bare tmpfs over /dev therefore does not test "the device with no
# filesystem underneath": it tests "the device with the devtab broken", and
# every copy fails at the open with the whole mechanism untried. (The
# measurement in docs/linux_build_count.md §4 did not hit this because the
# thing it was measuring WAS a filesystem path.)
#
# So the fixture binds the outer /dev/null aside first and rebinds it into the
# new tmpfs. Nothing is written to the host's /dev at any point -- a bind is a
# structural, read-only act, and all of it is inside a private namespace that
# ceases to exist when this shell does.
touch "$OUT/nullsrc" 2>/dev/null
mount --bind /dev/null "$OUT/nullsrc" 2>/dev/null || { echo "BINDFAIL"; exit 90; }
mount -t tmpfs tmpfs /dev 2>/dev/null || { echo "MOUNTFAIL"; exit 90; }
touch /dev/null 2>/dev/null
mount --bind "$OUT/nullsrc" /dev/null 2>/dev/null || { echo "NULLFAIL"; exit 90; }

# Pin the segment per run. docs/steam_namespace.md §11 records HAMWSYS_BB as
# "the third shared file, and it bit" -- one per host, inherited between runs.
# The clipboard is the fourth, so it is pinned here rather than trusted to a
# default that two concurrent agents would share.
export HAMSNARF="$OUT/seg"
rm -f "$HAMSNARF"

echo "BEGIN"
echo "A $("$CP" 0 CLIPBOARD-FROM-HAMTEXTBOX)"
echo "B $("$PA" 0)"
echo "C $("$CP" 1 PRIMARY-FROM-HAMTEXTBOX)"
echo "D $("$PA" 1)"
echo "E $("$PA" 0)"
# REPLACE including shrinking: 25 bytes must not survive under 5.
echo "F $("$CP" 0 short)"
echo "G $("$PA" 0)"
echo "H $("$PA" 1)"
# A 0-byte write CLEARS (Plan 9's semantics, lib/devsnarf.ad's rule).
echo "I $("$CP" 0 '')"
echo "J $("$PA" 0)"
echo "K $("$PA" 1)"
# THE 64 KiB CAP, the property two ordinary files in a RAM-backed /dev cannot
# give. 70000 bytes in, at most 65536 back.
BIG=$(awk 'BEGIN{s="";while(length(s)<70000)s=s "x";print substr(s,1,70000)}')
echo "L $("$CP" 0 "$BIG" )"
echo "M $("$PA" 0 | awk '{print $1, $2, $3, length($4)}')"
# THE NEGATIVE CONTROL: nothing was created on the filesystem.
if [ -e /dev/snarf ] || [ -e /dev/snarf.primary ]; then
    echo "N CREATED"
else
    echo "N none"
fi
echo "O $(ls -A /dev | tr '\n' ',')"
echo "END"
INNER
chmod +x "$BODY"

echo "[snarf] running in a private mount namespace with a tmpfs over /dev ..."
LOG="$OUT/run.log"
if ! unshare -rm --propagation private /bin/sh "$BODY" "$(pwd)/$OUT" \
        >"$LOG" 2>&1; then
    echo "[snarf] FAIL: could not run in a private mount namespace"
    cat "$LOG"; exit 1
fi
cat "$LOG"
echo

get() { sed -n "s/^$1 //p" "$LOG" | head -1; }

echo "[snarf] assertions"
chk "copy through hamtextbox reports success"      "copy 0 1 25"  "$(get A)"
chk "paste in ANOTHER process, through htermsel"   "paste 0 25 CLIPBOARD-FROM-HAMTEXTBOX" "$(get B)"
chk "copy to PRIMARY reports success"              "copy 1 1 23"  "$(get C)"
chk "PRIMARY pastes its own text"                  "paste 1 23 PRIMARY-FROM-HAMTEXTBOX"   "$(get D)"
chk "CLIPBOARD unchanged by the PRIMARY write"     "paste 0 25 CLIPBOARD-FROM-HAMTEXTBOX" "$(get E)"
chk "a shorter copy REPLACES (shrinks)"            "copy 0 1 5"   "$(get F)"
chk "no tail of the longer text survives"          "paste 0 5 short" "$(get G)"
chk "PRIMARY still independent after the shrink"   "paste 1 23 PRIMARY-FROM-HAMTEXTBOX"   "$(get H)"
chk "a 0-byte write is accepted"                   "copy 0 1 0"   "$(get I)"
chk "a 0-byte write CLEARS the CLIPBOARD"          "paste 0 0"    "$(get J)"
chk "clearing CLIPBOARD leaves PRIMARY alone"      "paste 1 23 PRIMARY-FROM-HAMTEXTBOX"   "$(get K)"
chk "a 70000-byte copy reports count consumed"     "copy 0 1 70000" "$(get L)"
chk "and is TRUNCATED at the 64 KiB cap"           "paste 0 65536 65536" "$(get M)"
chk "NOTHING was created under /dev"               "none"         "$(get N)"
chk "/dev holds ONLY the null the devtab needs"    "null,"        "$(get O)"


# ==================================================================
# ARM 2 — THE CROSS-UID CASE, which is the question an ordinary file
#         cannot answer well
# ==================================================================
# On a real boot the compositor and the system chrome are root and the session
# is uid 1001 (etc/rc.de-user ends with `setuid 1001`). A clipboard whose whole
# job is to carry bytes between programs has to carry them ACROSS that line in
# BOTH directions -- Ctrl+C in a root-started terminal pasting into a uid-1001
# editor, and back -- or copy/paste works only within one half of the desktop
# and says nothing when it doesn't, which is the failure this change exists to
# end.
#
# The uids are got the way tests/linux/wsys_uidgate.sh gets them: a user
# namespace with two uids mapped out of /etc/subuid. Inner 0 is the chrome's
# identity, inner 1001 is the session's.
#
# WHAT IS ACTUALLY BEING TESTED is the fchmod(0666) in shm_attach. root creates
# the segment with open(..., 0666), the kernel masks it by the umask to 0644,
# and without the fchmod every uid-1001 client fails the O_RDWR open and falls
# through to a PRIVATE clipboard of its own -- copy reports success, paste
# returns nothing, and nothing is printed anywhere. That is a measured failure
# of exactly this shape in linux-wsys.c, arriving here through the same door.
echo
echo "[snarf] arm 2: root copies, uid 1001 pastes, and back"
if ! command -v unshare >/dev/null || ! command -v setpriv >/dev/null; then
    echo "  SKIP  no unshare(1)/setpriv(1)"
elif ! grep -q "^$(id -un):" /etc/subuid 2>/dev/null; then
    echo "  SKIP  no /etc/subuid range for $(id -un); run this in the VM instead"
else
    SUB="$(awk -F: -v u="$(id -un)" '$1==u{print $2; exit}' /etc/subuid)"
    U2="$OUT/uid"
    rm -rf "$U2"; mkdir -p "$U2"; chmod 1777 "$U2"
    cp "$OUT/snarfcopy.elf" "$OUT/snarfpaste.elf" "$U2/" && chmod 755 "$U2"/*.elf

    BODY2="$OUT/body2.sh"
    cat >"$BODY2" <<'INNER2'
set -u
U2="$1"
export HAMSNARF="$U2/seg"
rm -f "$HAMSNARF"
as() { # as <uid> <cmd...>
    u="$1"; shift
    if [ "$u" = 0 ]; then "$@"
    else setpriv --reuid="$u" --regid="$u" --clear-groups "$@" 2>&1; fi
}
# The chrome (root) creates the segment and copies into the CLIPBOARD.
echo "P $(as 0 "$U2/snarfcopy.elf" 0 FROM-ROOT-CHROME)"
echo "Q $(id -u):$(stat -c '%u %a' "$HAMSNARF" 2>/dev/null)"
# The session (uid 1001) pastes it. This is the direction that breaks when the
# segment lands 0644.
echo "R $(as 1001 "$U2/snarfpaste.elf" 0)"
# ...and copies back, which needs WRITE on a root-owned segment.
echo "S $(as 1001 "$U2/snarfcopy.elf" 0 FROM-LIVE-SESSION)"
echo "T $(as 0 "$U2/snarfpaste.elf" 0)"
INNER2
    LOG2="$OUT/run2.log"
    if unshare -U \
        --map-users=0:"$(id -u)":1      --map-groups=0:"$(id -g)":1 \
        --map-users=1001:"$SUB":1       --map-groups=1001:"$SUB":1 \
        -m --propagation private \
        /bin/sh "$BODY2" "$(pwd)/$U2" >"$LOG2" 2>&1
    then
        cat "$LOG2"
        g2() { sed -n "s/^$1 //p" "$LOG2" | head -1; }
        chk "the chrome (root) copies"                  "copy 0 1 16" "$(g2 P)"
        chk "the segment is 0666, not the umask's 0644" "0:0 666"     "$(g2 Q)"
        chk "the uid-1001 SESSION pastes the chrome's text" \
            "paste 0 16 FROM-ROOT-CHROME" "$(g2 R)"
        chk "the session copies back into a root-owned segment" \
            "copy 0 1 17" "$(g2 S)"
        chk "and the chrome pastes what the session copied" \
            "paste 0 17 FROM-LIVE-SESSION" "$(g2 T)"
    else
        bad "arm 2 could not run"; cat "$LOG2"
    fi
fi


# ==================================================================
# ARM 3 — THE SHELL, which is where the offset protocol earns its keep
# ==================================================================
# `echo text > /dev/snarf` is the reason lib/devsnarf.ad is offset-addressed
# rather than replace-always, and the reason is written down as Defect 2 in
# docs/text_selection_clipboard.md: the shell's echo emits the payload and its
# trailing newline as SEPARATE write() calls, at offsets 0 and len. A
# replace-always device let the second clobber the first and the clipboard
# ended up holding one byte, "\n" -- a bug that looks like the clipboard
# working, because something was copied.
#
# This arm also runs the loop end to end through THREE different programs:
# hamsh writes it, tests/linux/snarfpaste.ad reads it back through
# lib/htermsel.ad, and user/cat.ad prints it. And it carries the negative
# control for the boundary this pass deliberately did NOT cross: the HOST's
# /bin/cat, standing in for a Debian or Alpine binary inside a namespace, does
# not see /dev/snarf at all. That is not a defect -- it is the same for
# /dev/wsys, /net and /fd, all of which are served inside the process by the
# Hamnix runtime -- but it IS the exact size of the X-clipboard gap, measured
# instead of asserted. See the header of user/linux-snarf.c.
echo
echo "[snarf] arm 3: the shell redirect, hamnix cat, and the foreign binary"
for p in hamsh cat; do
    if ! scripts/hamlinux_build.sh "user/$p.ad" "$OUT/$p.elf" \
            >"$OUT/$p.build.log" 2>&1; then
        bad "user/$p.ad did not build"; tail -20 "$OUT/$p.build.log"
    fi
done
BODY3="$OUT/body3.sh"
cat >"$BODY3" <<'INNER3'
set -u
OUT="$1"
touch "$OUT/nullsrc" 2>/dev/null
mount --bind /dev/null "$OUT/nullsrc" 2>/dev/null || { echo "BINDFAIL"; exit 90; }
mount -t tmpfs tmpfs /dev 2>/dev/null || { echo "MOUNTFAIL"; exit 90; }
touch /dev/null 2>/dev/null
mount --bind "$OUT/nullsrc" /dev/null 2>/dev/null || { echo "NULLFAIL"; exit 90; }
export HAMSNARF="$OUT/seg3"
rm -f "$HAMSNARF"
printf 'echo hello-from-the-shell > /dev/snarf\n' > "$OUT/rc1"
# NOT `>/dev/null`: the /dev in here is a fresh tmpfs whose `null` is a bind of
# the outer one, and the shell's O_CREAT open of it is refused. The Adder
# runtime's own open(2) of it is not, which is the only thing that has to work.
"$OUT/hamsh.elf" "$OUT/rc1" >"$OUT/hamsh.out" 2>&1
echo "U $("$OUT/snarfpaste.elf" 0)"
echo "V $("$OUT/cat.elf" /dev/snarf 2>&1 | head -1)"
echo "W $(/bin/cat /dev/snarf 2>&1 | head -1 | sed 's/.*: //')"
INNER3
LOG3="$OUT/run3.log"
if unshare -rm --propagation private /bin/sh "$BODY3" "$(pwd)/$OUT" \
        >"$LOG3" 2>&1; then
    cat "$LOG3"
    g3() { sed -n "s/^$1 //p" "$LOG3" | head -1; }
    # 21 bytes: the 20-byte payload AND the newline echo wrote separately at
    # offset 20. A replace-always device would answer 1 here, holding "\n".
    chk "echo > /dev/snarf lands BOTH chunks (Defect 2)" \
        "paste 0 21 hello-from-the-shell" "$(g3 U)"
    chk "hamnix cat /dev/snarf prints it" "hello-from-the-shell" "$(g3 V)"
    chk "a FOREIGN binary does not see the device" \
        "No such file or directory" "$(g3 W)"
else
    bad "arm 3 could not run"; cat "$LOG3"
fi

echo
echo "[snarf] SUMMARY passes=$PASS fails=$FAIL"
if [ "$FAIL" -ne 0 ]; then echo "[snarf] RESULT: FAIL"; exit 1; fi
echo "[snarf] RESULT: PASS"
