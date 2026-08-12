#!/usr/bin/env bash
# tests/linux/de_appmenu_installed.sh — THE APPLICATIONS MENU MUST LIST ONLY
# PROGRAMS THIS MACHINE HAS, AND MUST SAY SO WHEN IT DROPS ONE.
#
# THE DEFECT THIS EXISTS FOR
# ==========================
# Found on a real booted machine, by eye, by the person this distribution is
# being built for: the Applications menu listed eleven applications and
# clicking most of them did NOTHING. Two independent faults, both of them
# NORTH_STAR.md's worst shape -- the gap answering something success-shaped
# instead of the truth:
#
#   1. /etc/hamde/apps WAS ON NO MACHINE. scripts/hamlinux_image.sh staged
#      /etc by iterating a list and testing `[ -f "etc/$f" ]`, and the list
#      contained `hamde` -- a DIRECTORY, for which -f is false. The 26 shipped
#      .desktop launchers were therefore never staged anywhere, every menu
#      found the catalogue empty, and both hamappmenu and hampanelscene fell
#      back to a list compiled into them.
#
#   2. THOSE COMPILED-IN LISTS HAD DRIFTED. hamappmenu's named
#      /bin/calculator, /bin/hamterm, /bin/hamedit, /bin/hamview and /bin/hamfm
#      -- none of which the image builds under those names. And a click on one
#      could not fail loudly, because spawn_detached FORKS: fork(2) succeeds,
#      execve(2) fails in the child, and the panel logs `launched`.
#
# There was a third thing behind both, which is why this gate checks the
# programs and not only the files: of the 26 Exec targets in the catalogue,
# exactly THREE were in the image's APPS list. Staging the launchers correctly
# and changing nothing else would have produced a THREE-ROW Applications menu
# on a distribution that has 26 desktop applications in its tree.
#
# WHAT THIS MEASURES, AND WHY IT IS A BOOT AND NOT A GREP
# ======================================================
# A static check can see that the file lists agree. It cannot see the thing
# that actually went wrong, which is what a MENU DID on a MACHINE. So the
# first three sections read the staged image root (the file lists), and the
# fourth BOOTS IT and reads the panel's own count of the entries it built --
# with one launcher's program deliberately removed from the root beforehand,
# so that the run also proves what the menu does with a launcher it cannot
# honour:
#
#   * the entry is NOT listed (the count is one lower than the catalogue), and
#   * it is NAMED, as `appmenu-missing <Name> <prog>`, rather than dropped in
#     silence, and
#   * a launch of a program that is not there is refused BY NAME
#     (`[panel] LAUNCH FAILED <prog>: not installed`) instead of forking a
#     child that dies in execve while the panel says `launched`.
#
# The removal is done to the STAGED ROOT before the initramfs is packed, not
# by the rc at runtime: the panel scans the catalogue in its first few lines
# of main(), so anything the rc does after the DE is up is too late, and
# anything it does before would be measuring the rc rather than the panel.
#
# WHY IT IS NOT `ls | wc -l` ON THE HOST. The repository is not a machine. The
# whole defect was that the tree had 26 launchers and every machine had zero,
# and a gate that counts the tree agrees with that defect.
#
# Usage: tests/linux/de_appmenu_installed.sh
#   APPMENU_INST_WORK=<dir>   reuse a work dir (keeps the build)
#   APPMENU_INST_NOBOOT=1     sections 1-3 only (no VM)
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

# REAP WHAT YOU START -- the VM in section 4 is a background child.
. tests/linux/reap.sh
reap_on_exit

WORK="${APPMENU_INST_WORK:-$(mktemp -d -p "${TMPDIR:-/home/david/.hamnix-build}" appmenuinst.XXXXXX)}"
mkdir -p "$WORK"
echo "[appmenu-inst] work dir: $WORK"

pass=0; fail=0
ok()   { echo "appmenu-inst: PASS $*"; pass=$((pass+1)); }
bad()  { echo "appmenu-inst: FAIL $*"; fail=$((fail+1)); }
info() { echo "appmenu-inst: INFO $*"; }

# The launcher whose program section 4 removes. It is a real shipped app with
# no other role in this gate, and it is named ONCE here so the assertions and
# the removal cannot drift apart.
GHOST_DESKTOP="hamchess.desktop"

# ---- the catalogue, as the repository has it ------------------------------
CATALOGUE=(); for f in etc/hamde/apps/*.desktop; do CATALOGUE+=("$(basename "$f")"); done
NCAT="${#CATALOGUE[@]}"
info "the tree ships $NCAT launchers in etc/hamde/apps"
[ "$NCAT" -gt 0 ] || { bad "etc/hamde/apps has no launchers at all"; echo "appmenu-inst: $pass passed, $fail failed"; exit 1; }

exec_prog() {   # exec_prog <desktop file> -> the first token of its Exec=
    sed -n 's/^Exec=//p' "$1" | head -1 | awk '{print $1}'
}

# ==========================================================================
# 1. THE IMAGE STAGES THE CATALOGUE
# ==========================================================================
echo
echo "=== 1. the staged image root ==="
IMG="$WORK/image"
if [ -d "$IMG/root/bin" ] && [ -f "$IMG/initramfs.cpio.gz" ]; then
    info "reusing the image already in $IMG"
else
    echo "[appmenu-inst] staging an image (this builds the whole userland)"
    HAMLINUX_DISTRO_RO=1 nice -n 15 scripts/hamlinux_image.sh "$IMG" \
        > "$WORK/build.log" 2>&1 || {
        bad "the image build failed"; tail -25 "$WORK/build.log" >&2
        echo "appmenu-inst: $pass passed, $fail failed"; exit 1; }
fi
ROOT="$IMG/root"

nstaged=0; unstaged=()
for b in "${CATALOGUE[@]}"; do
    if [ -f "$ROOT/etc/hamde/apps/$b" ]; then nstaged=$((nstaged+1)); else unstaged+=("$b"); fi
done
if [ "${#unstaged[@]}" = 0 ]; then
    ok "all $NCAT launchers are staged at /etc/hamde/apps on the image ($nstaged found)"
else
    bad "${#unstaged[@]} of $NCAT launchers are in the tree and NOT on the image: ${unstaged[*]}. /etc/hamde/apps is the catalogue every menu in this desktop reads; with it absent they fall back to a list compiled into them."
fi

# apps-optional belongs to the optional packages that carry its programs. A
# launcher staged without its program is the defect this gate is about, in the
# other direction.
if ls "$ROOT/etc/hamde/apps-optional" >/dev/null 2>&1; then
    bad "/etc/hamde/apps-optional is staged on the image -- those launchers name programs only their optional packages install"
else
    ok "apps-optional is NOT staged (its launchers ship with the packages that carry their programs)"
fi

# ==========================================================================
# 2. EVERY LAUNCHER'S PROGRAM IS ON THE IMAGE
# ==========================================================================
echo
echo "=== 2. the programs those launchers name ==="
noprog=()
for b in "${CATALOGUE[@]}"; do
    p="$(exec_prog "etc/hamde/apps/$b")"
    [ -n "$p" ] || { bad "$b has no Exec= line"; continue; }
    [ -f "$ROOT$p" ] || noprog+=("$b -> $p")
done
if [ "${#noprog[@]}" = 0 ]; then
    ok "every one of the $NCAT launchers names a program that is in the image's /bin"
else
    printf '    %s\n' "${noprog[@]}"
    bad "${#noprog[@]} of $NCAT launchers name a program the image does not build. Each one is a menu row that does nothing when a person clicks it. Add the program to GUI_APPS in scripts/hamlinux_image.sh AND to DESKTOP_CMDS in scripts/hamlinux_packages.py."
fi

# ==========================================================================
# 3. AND THE CHANNEL CARRIES THEM
# ==========================================================================
# NORTH_STAR.md's standing rule: a file in the image and in no package is a
# file an INSTALLED machine can never receive a fix to. This is a cheap
# name-level check against the package script's own lists;
# tests/linux/channel_covers_image.sh does the authoritative one against the
# built tarballs, and will fail on anything this misses.
echo
echo "=== 3. the package lists name them too ==="
PKG=scripts/hamlinux_packages.py
if grep -q 'HAMDE_APPS' "$PKG" && grep -q 'HAMDE_APPS' <(grep -A2 'SKEL_FILES + HAMDE_APPS' "$PKG" || true); then
    ok "scripts/hamlinux_packages.py carries etc/hamde/apps in a package (HAMDE_APPS)"
else
    bad "no package carries etc/hamde/apps -- an installed machine could never receive a new launcher or a fix to one"
fi
# The command lists are several (DESKTOP_CMDS, SYS_CMDS, NET_CMDS, ...) and
# which one a program belongs to is a packaging decision, not this gate's
# business -- haminstallui is the installer's, not the desktop's. What this
# asks is only whether SOME list names it.
python3 - "$PKG" > "$WORK/pkgcmds.txt" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
names = set()
for m in re.finditer(r'^[A-Z_]*CMDS\s*=\s*\(?(.*?)\)?\.split\(\)', src, re.S | re.M):
    for s in re.findall(r'"([^"]*)"', m.group(1)):
        names.update(s.split())
print("\n".join(sorted(names)))
PY
unpkg=()
for b in "${CATALOGUE[@]}"; do
    cmd="$(basename "$(exec_prog "etc/hamde/apps/$b")")"
    grep -qx "$cmd" "$WORK/pkgcmds.txt" || unpkg+=("$cmd")
done
if [ "${#unpkg[@]}" = 0 ]; then
    ok "every launcher's program is named in one of scripts/hamlinux_packages.py's command lists ($(wc -l < "$WORK/pkgcmds.txt") programs in all)"
else
    bad "${#unpkg[@]} launcher programs are in the image and in no package: ${unpkg[*]}. tests/linux/channel_covers_image.sh will fail on these too; they are named here because THIS is where they became menu rows."
fi

if [ "${APPMENU_INST_NOBOOT:-0}" = 1 ]; then
    echo
    echo "appmenu-inst: $pass passed, $fail failed (sections 1-3 only: APPMENU_INST_NOBOOT=1)"
    exit "$( [ "$fail" = 0 ] && echo 0 || echo 1 )"
fi

# ==========================================================================
# 4. WHAT THE MENU ACTUALLY BUILT, ON A BOOTED MACHINE
# ==========================================================================
echo
echo "=== 4. the menu the panel builds on a real boot ==="
GHOST_PROG="$(exec_prog "etc/hamde/apps/$GHOST_DESKTOP")"
GHOST_NAME="$(sed -n 's/^Name=//p' "etc/hamde/apps/$GHOST_DESKTOP" | head -1)"
info "the launcher under test is $GHOST_DESKTOP ($GHOST_NAME -> $GHOST_PROG)"

# A SEPARATE image, so section 1's root is left as the image ships. The rc
# reads the panel's log back to the serial console once the DE is up: rc.5
# starts the panel with its stdout redirected to /var/log/panel.log, so that
# file, not the console, is where its telemetry lands.
BOOT="$WORK/bootimg"
cp etc/rc.boot.linux "$WORK/rc.boot"
cat >> "$WORK/rc.boot" <<'RC'

# --- what did the Applications menu actually build? -------------------
sleep 30
echo '[menucheck] LAUNCHERS'
ls '/etc/hamde/apps'
echo '[menucheck] PANELLOG'
cat '/var/log/panel.log'
echo '[menucheck] LAUNCHBAD'
echo '/bin/nosuchprogram' > '/dev/wsys/appmenu/launch'
sleep 5
cat '/var/log/panel.log'
echo '[menucheck] DONE'
RC

if [ -f "$BOOT/initramfs.cpio.gz" ]; then
    info "reusing the boot image already in $BOOT"
else
    echo "[appmenu-inst] staging the boot image"
    HAMLINUX_RC="$WORK/rc.boot" HAMLINUX_DISTRO_RO=1 nice -n 15 \
        scripts/hamlinux_image.sh "$BOOT" > "$WORK/build2.log" 2>&1 || {
        bad "the boot image build failed"; tail -25 "$WORK/build2.log" >&2
        echo "appmenu-inst: $pass passed, $fail failed"; exit 1; }
    # THE ONE MUTATION. Remove the ghost launcher's PROGRAM from the staged
    # root and repack, leaving its .desktop in place. That is precisely the
    # state the menu has to be honest about, and it is made here rather than
    # by the rc because the panel scans the catalogue before the rc could.
    rm -f "$BOOT/root$GHOST_PROG"
    ( cd "$BOOT/root" && find . -print0 | cpio --null -o -H newc --quiet ) \
        | gzip -9 > "$BOOT/initramfs.cpio.gz" || {
        bad "could not repack the initramfs"; echo "appmenu-inst: $pass passed, $fail failed"; exit 1; }
    info "removed $GHOST_PROG from the boot root and repacked ($(du -h "$BOOT/initramfs.cpio.gz" | cut -f1))"
fi

BOOTLOG="$WORK/boot.log"
: > "$BOOTLOG"
RUNTIME=150
echo "[appmenu-inst] booting (up to ${RUNTIME}s)"
( sleep "$RUNTIME" ) | HAMLINUX_VNC=none HAMLINUX_DISTRO_RO=1 HAMLINUX_IMAGE_DIR="$BOOT" \
    scripts/hamlinux_vm.sh script --timeout "$RUNTIME" > "$BOOTLOG" 2>&1 &
reap_add $!
RUNNER=$!
w=0
while ! grep -aqF '[menucheck] DONE' "$BOOTLOG"; do
    sleep 2; w=$((w + 2))
    [ "$w" -gt "$RUNTIME" ] && break
    kill -0 "$RUNNER" 2>/dev/null || break
done
kill "$RUNNER" 2>/dev/null; wait "$RUNNER" 2>/dev/null
tr -d '\r' < "$BOOTLOG" > "$WORK/boot.txt"

if grep -qF '[menucheck] PANELLOG' "$WORK/boot.txt"; then
    ok "the machine booted to a desktop and read its panel log back"
else
    bad "the boot never reached the check -- nothing below is evidence about the menu"
    tail -30 "$WORK/boot.txt" >&2
    echo; echo "appmenu-inst: $pass passed, $fail failed"; exit 1
fi

# The catalogue really is on the booted machine (assertion 1 was about a
# staged directory; this is about a machine).
GUEST_N="$(sed -n '/\[menucheck\] LAUNCHERS/,/\[menucheck\] PANELLOG/p' "$WORK/boot.txt" \
           | grep -c '\.desktop')"
if [ "$GUEST_N" = "$NCAT" ]; then
    ok "the booted machine has all $NCAT launchers under /etc/hamde/apps"
else
    bad "the booted machine has $GUEST_N launchers under /etc/hamde/apps, not $NCAT"
fi

# THE COUNT THE PANEL ITSELF REPORTS. One entry short of the catalogue, and
# short by exactly the one whose program was removed.
ENTRIES="$(grep -a 'appmenu entries:' "$WORK/boot.txt" | tail -1 | sed 's/.*entries: *//' | tr -dc '0-9')"
WANT=$((NCAT - 1))
info "the panel reports [panel] appmenu entries: ${ENTRIES:-<none>} (catalogue $NCAT, one program removed)"
if [ "$ENTRIES" = "$WANT" ]; then
    ok "the menu lists $WANT entries -- every launcher whose program is installed, and not the one whose is not"
else
    bad "the menu lists ${ENTRIES:-<none>} entries; $WANT were expected ($NCAT launchers, one of them with no program). A count EQUAL to $NCAT means a row that does nothing when clicked; a smaller one means something else was dropped."
fi

# AND IT SAID SO. A row dropped in silence is the same shape as the bug.
if grep -aq "appmenu-missing $GHOST_NAME $GHOST_PROG" "$WORK/boot.txt"; then
    ok "the panel named the launcher it dropped: appmenu-missing $GHOST_NAME $GHOST_PROG"
else
    bad "the panel dropped a launcher without naming it -- silence is the shape of the defect. Expected 'appmenu-missing $GHOST_NAME $GHOST_PROG'"
    grep -a 'appmenu-missing' "$WORK/boot.txt" | sed 's/^/    /' | head -5
fi

# AND A LAUNCH THAT CANNOT WORK FAILS BY NAME. This is the assertion the old
# code could not have passed at all: spawn_detached returns a good pid for a
# program that never ran.
if grep -aq 'LAUNCH FAILED /bin/nosuchprogram: not installed' "$WORK/boot.txt"; then
    ok "a launch of a program that is not installed is refused BY NAME, not reported as launched"
else
    bad "a launch of /bin/nosuchprogram was not refused by name"
    grep -a 'launched /bin/nosuchprogram\|LAUNCH FAILED' "$WORK/boot.txt" | sed 's/^/    /' | head -5
fi

echo
echo "appmenu-inst: $pass passed, $fail failed"
[ "$fail" = 0 ]
