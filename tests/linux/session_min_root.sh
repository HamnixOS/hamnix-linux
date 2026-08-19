#!/usr/bin/env bash
#
# tests/linux/session_min_root.sh — WHAT BREAKS WHEN `/` IS NOT THE MACHINE'S
# ROOT. The first measurement of the architectural direction in HANDOFF.md
# ("THE ARCHITECTURAL DIRECTION IS SETTLED: A MINIMAL GLOBAL ROOT"), which
# until now was source reading with nothing booted.
#
# THE OWNER'S CONSTRAINT, which is what this is a measurement of:
#
#   "the global root should be min as possable, with apps and things living
#    on fileserver very plan 9 shaped. Drivers can live on the real global
#    root, but that should be an underpinning not the thing the user in
#    userland gets to be running cd /"
#
# REGISTRATION. ON-DEMAND: not in ci_battery_manifest.txt because it rebuilds
# the image and boots a machine. Same class as tests/linux/enter_user_run.sh,
# whose structure this borrows.
#
# ================================================================
# WHAT IS FAKED, SAID FIRST, BECAUSE IT BOUNDS EVERY RESULT BELOW
# ================================================================
# THERE IS NO HAMNIX APP SERVER TO SERVE A CONSTRUCTED ROOT FROM. So each
# candidate root here is a DIRECTORY on the machine, with the machine's own
# directories bind-mounted into it. That is enough to answer "what resolves
# and what does not" -- every absolute path a program opens is resolved
# against the session's root either way -- and it is NOT enough to answer:
#
#   * anything about 9P/file-server latency, caching or reconnection;
#   * anything about a server that can REFUSE a name (a bind-mounted
#     directory carries the machine's own permissions, unchanged);
#   * anything about serving one root to several machines;
#   * anything about a root whose contents are not already on this disk.
#
# What it DOES prove is which absolute paths a session's programs assume, and
# that is the list an app server would have to serve. Read every PASS below as
# "this name resolved", never as "a file server would work".
#
# ================================================================
# THE MECHANISM, AND THE TRAP IN IT (host-measured, see arm 0)
# ================================================================
# user/linux-syscalls.c:sys_bind has TWO branches and they do NOT do the same
# thing when the destination is "/":
#
#   * `bind '#<something>' /`  -> the device-server branch -> enter_root(),
#     which is mount(new,"/",MS_MOVE) followed by chroot("."). This REALLY
#     replaces the root. It is what `enter debian` uses.
#
#   * `bind /some/directory /` -> the plain-path branch -> a single
#     ns_mount(src, "/", MS_BIND|MS_REC). On Linux THAT CALL RETURNS 0 AND THE
#     PROCESS'S ROOT DOES NOT CHANGE: mounting over the "/" mount point does
#     not move the process's own root (mnt,dentry) pair. Arm 0 measures this
#     on the host with the same primitive.
#
# SO THE OBVIOUS WAY TO FAKE AN APP SERVER -- point `bind` at a directory --
# IS A GAP THAT ANSWERS SUCCESS-SHAPED, which is this project's oldest and
# most expensive failure mode. Every arm below therefore goes through the
# DEVICE branch, using the `$HAMNIX_DISTRO_<NAME>` override
# (user/linux-syscalls.c:distro_resolve) to point a named distro namespace at
# a plain directory -- which distro_source_spec passes through verbatim, so
# the directory reaches enter_root and the switch is real.
#
# AND EVERY ARM PROVES THE SWITCH HAPPENED BEFORE IT MEASURES ANYTHING ELSE:
# each candidate root holds a marker file that exists NOWHERE on the machine's
# real root, and `cat /MINROOT-MARKER-<arm>` inside the arm must print it. An
# arm that cannot show its marker has its remaining results discarded, because
# an arm that never left the machine's root would report the machine's root
# working perfectly and call it a constructed root.
#
# ================================================================
# THE FOUR CANDIDATE ROOTS
# ================================================================
#   r1  BARE      nothing but the mount points enter_root makes itself.
#   r2  +bin      the machine's /bin bound in. "Apps live on a file server."
#   r3  +bin+etc  and the machine's /etc.
#   r4  +bin+etc+var+usr+lib   everything the suspects are known to want.
#
# Reading DOWN that list tells you the minimum set of names an app server
# would have to serve, which is the actionable form of "what breaks".
#
# THE SUSPECTS NAMED IN THE BRIEF, and where each is measured:
#   hpm            `hpm list` in every arm. It opens /etc/hpm/repo and
#                  /var/lib/hpm/channels (user/hpm.ad:712,893).
#   the window     `cat /dev/wsys/wsysd/state` in every arm -- /dev is bound
#   system         across by enter_root's always[], so this asks whether the
#                  compositor's NAME still resolves from a constructed root.
#   the launcher   `/bin/hamappmenu` and `/bin/hamtermscene` presence, and
#                  whether an exec from a constructed root works at all.
#
# WHAT THIS GATE DELIBERATELY DOES NOT MEASURE, said plainly so nobody reads
# a green run as more than it is: no client was made to actually DRAW into a
# window from inside a constructed root, and no screenshot was taken. Whether
# a scene client can map and commit a window from a constructed root is
# UNMEASURED here; only whether the server's name resolves.
#
# Usage: tests/linux/session_min_root.sh [seconds]
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

WAIT="${1:-180}"
W="${MINROOT_WORK:-$HOME/.hamnix-build/minroot}"
mkdir -p "$W"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  PASS  $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL  $*"; }
info() { echo "        $*"; }
say()  { echo; echo "== $* =="; }
finish() { printf '\n%d PASSED, %d FAILED\n' "$PASS" "$FAIL"
           [ "$FAIL" = 0 ] && exit 0 || exit 1; }

for t in qemu-system-x86_64 python3 unshare; do
    command -v "$t" >/dev/null || { echo "INCONCLUSIVE: need $t"; exit 2; }
done

# =========================================================================
say "0 -- THE TRAP, measured on the host with the same primitive sys_bind uses"
# This is not a detour. The whole gate below is built to AVOID this branch,
# and the reason has to be a measurement rather than a claim, because if a
# plain-directory bind onto / did work, every arm below could have been
# written the obvious way and the reader deserves to know why it was not.
#
# The call is the one at user/linux-syscalls.c:5176 --
# ns_mount(src, "/", NULL, MS_BIND|MS_REC, NULL) -- run here through
# mount(8)'s --bind, in a private mount namespace so nothing on this host is
# touched. -r maps our uid to 0 inside a user namespace, which is exactly the
# privilege ns_privilege() acquires.
MR="$W/hostroot"; rm -rf "$MR"; mkdir -p "$MR/bin" "$MR/etc"
echo 'this file exists only in the candidate root' > "$MR/MINROOT-HOST-MARKER"
cat >"$W/hostprobe.sh" <<'HPEOF'
#!/bin/sh
D="$1"
mount --make-rprivate / 2>/dev/null
if mount --bind "$D" / 2>/tmp/e; then echo "HOSTPROBE: mount-rc=0"
else echo "HOSTPROBE: mount-failed: $(cat /tmp/e 2>/dev/null)"; fi
if [ -e /MINROOT-HOST-MARKER ]; then echo "HOSTPROBE: marker-visible=yes"
else echo "HOSTPROBE: marker-visible=no"; fi
HPEOF
unshare -m -r sh "$W/hostprobe.sh" "$MR" >"$W/hostprobe.log" 2>&1
info "$(tr '\n' ' ' <"$W/hostprobe.log")"
if grep -q 'HOSTPROBE: mount-rc=0' "$W/hostprobe.log"; then
    ok "a plain-directory bind onto \"/\" RETURNS SUCCESS"
else
    # Not a failure of the tree -- it would mean this host refuses the call,
    # and then the trap this gate is built around does not exist here.
    info "this host refused the call outright; the success-shaped trap does not reproduce here"
    ok "the host-side control ran and reported its result"
fi
if grep -q 'HOSTPROBE: marker-visible=no' "$W/hostprobe.log"; then
    ok "...AND THE ROOT DID NOT CHANGE -- the candidate root's marker is not visible after a call that returned 0. \`bind <directory> /\` is a gap that answers success-shaped; every arm below uses the device branch instead"
elif grep -q 'HOSTPROBE: marker-visible=yes' "$W/hostprobe.log"; then
    info "the root DID change on this host -- the plain-path branch would work after all, and the note at the top of this file should be corrected"
    ok "the host-side control reported a root switch"
else
    bad "the host-side probe reported neither outcome -- see $W/hostprobe.log"
fi

# =========================================================================
say "1 -- the rc that constructs four candidate roots and probes each"

# THE PROBE SET, written once. Every arm runs exactly these, so two arms'
# results are comparable by construction rather than by diligence.
#
# `cat /MINROOT-MARKER-<arm>` IS FIRST AND IT IS THE GUARD. It is the only
# line that distinguishes "the constructed root works" from "the switch
# silently did nothing and I am still on the machine".
emit_probes() {
    local a="$1"
    cat <<PEOF
echo 'MINROOT-$a-BEGIN'
# --- THE GUARD: prove we actually left the machine's root ---------
enter $a { cat /MINROOT-MARKER-$a }
echo 'MINROOT-$a-marker-status' \$status
# --- what a person typing \`cd /\` would see ----------------------
enter $a { ls / }
echo 'MINROOT-$a-lsroot-status' \$status
# --- INSTRUMENT CONTROL: a name that is on NO root must still fail.
# Without this, an arm in which every open fails for some unrelated
# reason would read exactly like an arm in which the root is minimal.
enter $a { cat /MINROOT-NO-SUCH-FILE-ANYWHERE }
echo 'MINROOT-$a-absent-status' \$status
# --- the machine's own root, still reachable from below at /n -----
# rc.de-user.linux binds '#/' -> /n and enter_root carries /n across;
# if this fails the Plan 9 "roots that are not yours" convention does
# not survive a constructed root, which is worth knowing on its own.
enter $a { cat /n/MINROOT-REALROOT-MARKER }
echo 'MINROOT-$a-nmarker-status' \$status
# --- CAN ANYTHING BE EXEC'D AT ALL from this root? ----------------
enter $a { /bin/id }
echo 'MINROOT-$a-binid-status' \$status
# --- SUSPECT 1: hpm. /etc/hpm/repo and /var/lib/hpm/channels ------
enter $a { /bin/hpm list }
echo 'MINROOT-$a-hpmlist-status' \$status
# --- SUSPECT 2: the window system's name --------------------------
enter $a { cat /dev/wsys/wsysd/state }
echo 'MINROOT-$a-wsys-status' \$status
# --- SUSPECT 3: the launcher's binary ------------------------------
enter $a { ls /bin/hamappmenu }
echo 'MINROOT-$a-launcher-status' \$status
echo 'MINROOT-$a-END'
PEOF
}

{
cat <<'RCHEAD'
echo 'MINROOT: rc.boot begins'
ln -s /dev/console /dev/cons

# A marker on the MACHINE's real root. Two jobs: it is what `/n` is checked
# for inside each arm, and its ABSENCE inside an arm's `ls /` is part of how
# an arm proves it is not standing on the machine.
echo 'real' > /MINROOT-REALROOT-MARKER

# --- POSITIVE CONTROL, before any switch: what `ls /` says on the machine.
# If this does not show the machine's root then `ls` is not working and no
# absence measured below means anything.
echo 'MINROOT-CONTROL-BEGIN'
ls /
echo 'MINROOT-CONTROL-END'

# =====================================================================
# THE FOUR CANDIDATE ROOTS. Each is a directory; the machine's own
# directories are bound INTO it. See the header for what that does and does
# not prove.
# =====================================================================
mkdir /r1
mkdir /r2
mkdir /r3
mkdir /r4
echo 'r1' > /r1/MINROOT-MARKER-r1
echo 'r2' > /r2/MINROOT-MARKER-r2
echo 'r3' > /r3/MINROOT-MARKER-r3
echo 'r4' > /r4/MINROOT-MARKER-r4

# THE MOUNT POINTS, MADE BY HAND, AND THIS IS ITSELF A FINDING.
# enter_root() mkdir's /dev /proc /sys /n inside the new root (its `always[]`)
# but /srv and /tmp are in `sysroot_only[]` -- they are carried across only
# for a `#sysroot` switch, NOT for the `#distro`-shaped switch a session root
# uses. So a constructed session root gets NO /tmp at all unless somebody
# makes it, and the four bind lines every `ns clean {}` template in this tree
# carries do not mention /tmp either. A bind whose target directory does not
# exist fails ENOENT (docs/linux_distro_namespaces.md §8.4 is the whole story
# of that fault), so they are made here rather than discovered later.
mkdir /r1/srv
mkdir /r1/tmp
mkdir /r2/srv
mkdir /r2/tmp
mkdir /r3/srv
mkdir /r3/tmp
mkdir /r4/srv
mkdir /r4/tmp

# r2 = r1 + the machine's /bin.
bind /bin /r2/bin
# r3 = r2 + /etc.
bind /bin /r3/bin
bind /etc /r3/etc
# r4 = r3 + /var /usr /lib.
bind /bin /r4/bin
bind /etc /r4/etc
bind /var /r4/var
bind /usr /r4/usr
bind /lib /r4/lib

# THE DEVICE BRANCH, REACHED WITH THE ENV OVERRIDE. distro_resolve() reads
# $HAMNIX_DISTRO_<UPPERNAME> first and distro_source_spec() passes anything
# that is not LABEL= through verbatim, so a plain directory reaches
# enter_root -- which is the REAL root switch (MS_MOVE + chroot).
HAMNIX_DISTRO_R1='/r1'
export HAMNIX_DISTRO_R1
HAMNIX_DISTRO_R2='/r2'
export HAMNIX_DISTRO_R2
HAMNIX_DISTRO_R3='/r3'
export HAMNIX_DISTRO_R3
HAMNIX_DISTRO_R4='/r4'
export HAMNIX_DISTRO_R4

# The templates. Deliberately the SAME four bind lines etc/rc.de-user.linux
# carries for `enter debian`, so an arm differs from a shipping session root
# only in which root it is aimed at.
r1 = ns clean {
    bind '#distro/r1' /
    bind '#c' /dev
    bind '#p' /proc
    bind '#s' /srv
    bind '#/' /n
}
r2 = ns clean {
    bind '#distro/r2' /
    bind '#c' /dev
    bind '#p' /proc
    bind '#s' /srv
    bind '#/' /n
}
r3 = ns clean {
    bind '#distro/r3' /
    bind '#c' /dev
    bind '#p' /proc
    bind '#s' /srv
    bind '#/' /n
}
r4 = ns clean {
    bind '#distro/r4' /
    bind '#c' /dev
    bind '#p' /proc
    bind '#s' /srv
    bind '#/' /n
}
RCHEAD
emit_probes r1
emit_probes r2
emit_probes r3
emit_probes r4
cat <<'RCTAIL'
echo 'MINROOT: ALL-ARMS-DONE'
RCTAIL
} > "$W/rc.boot"

info "rc.boot: $(wc -l <"$W/rc.boot") lines -> $W/rc.boot"

# =========================================================================
say "2 -- build an image carrying that rc, and boot it"
if ! HAMLINUX_RC="$W/rc.boot" scripts/hamlinux_image.sh >"$W/build.log" 2>&1; then
    bad "image build failed -- see $W/build.log"
    tail -20 "$W/build.log" | sed 's/^/        /'
    finish
fi
ok "built an image whose /etc/rc.boot is this gate's rc"

HAMLINUX_VNC=none timeout "$((WAIT + 15))" \
    scripts/hamlinux_vm.sh script --timeout "$WAIT" </dev/null >"$W/boot.log" 2>&1
info "boot log: $W/boot.log ($(wc -c <"$W/boot.log") bytes)"

tr -d '\r' <"$W/boot.log" >"$W/boot.txt"
B="$W/boot.txt"

if grep -q 'MINROOT: rc.boot begins' "$B"; then
    ok "the machine booted and reached this gate's rc"
else
    bad "the machine never reached this gate's rc -- nothing below is a measurement"
    tail -30 "$B" | sed 's/^/        /'
    finish
fi

# =========================================================================
say "3 -- the positive control: what \`ls /\` says on the MACHINE's root"
sed -n '/MINROOT-CONTROL-BEGIN/,/MINROOT-CONTROL-END/p' "$B" >"$W/control.txt"
info "$(tr '\n' ' ' <"$W/control.txt" | cut -c1-200)"
CTRL_N=$(grep -cvE 'MINROOT-CONTROL-(BEGIN|END)' "$W/control.txt")
if grep -qw 'bin' "$W/control.txt" && grep -qw 'etc' "$W/control.txt"; then
    ok "the machine's own root carries 'bin' and 'etc' ($CTRL_N entries) -- \`ls\` works and a constructed root's SHORTER listing will mean something"
else
    bad "the machine's own root does not list 'bin' and 'etc' -- \`ls\` is not working, so every absence below is meaningless"
    finish
fi
if grep -q 'MINROOT-REALROOT-MARKER' "$W/control.txt"; then
    ok "and it carries MINROOT-REALROOT-MARKER, which is how each arm's /n is checked"
else
    bad "the real root's marker was not created -- the /n check in every arm is void"
fi

# =========================================================================
# Score one arm. `arm_slice` is everything between this arm's BEGIN and END,
# so no assertion can accidentally read another arm's output.
arm_slice() { sed -n "/MINROOT-$1-BEGIN/,/MINROOT-$1-END/p" "$B"; }
# The status line hamsh printed after a probe. `enter` propagates its body's
# status; a probe that never ran leaves no line at all, which is scored
# differently from one that ran and failed.
pstat() { arm_slice "$1" | sed -n "s/^MINROOT-$1-$2-status //p" | head -1; }

score_arm() {
    local a="$1" desc="$2"
    say "arm '$a' -- $desc"
    arm_slice "$a" >"$W/arm-$a.txt"
    if [ ! -s "$W/arm-$a.txt" ]; then
        bad "[$a] produced no output at all between its markers -- this arm did not run"
        return
    fi
    info "[$a] $(wc -l <"$W/arm-$a.txt") lines -> $W/arm-$a.txt"

    # ---- THE GUARD ------------------------------------------------------
    if grep -qx "$a" "$W/arm-$a.txt"; then
        ok "[$a] THE ROOT REALLY CHANGED: /MINROOT-MARKER-$a resolved and printed '$a' -- a file that exists on NO other root on this machine"
    else
        bad "[$a] the marker did NOT resolve, so this arm never left the machine's root and NOTHING else it reports is a measurement of a constructed root"
        info "[$a] marker probe status: '$(pstat "$a" marker)'"
        return
    fi

    # ---- THE INSTRUMENT CONTROL -----------------------------------------
    local ABS; ABS="$(pstat "$a" absent)"
    if [ -n "$ABS" ] && [ "$ABS" != 0 ]; then
        ok "[$a] and a name that is on NO root FAILED (status $ABS) -- an absence reported below is a real absence, not this arm failing at everything"
    else
        bad "[$a] a name that cannot exist anywhere reported status '$ABS' -- this arm's instrument cannot tell present from absent and its absences prove nothing"
        return
    fi

    # ---- what `cd /` shows ----------------------------------------------
    local LS; LS="$(sed -n "/MINROOT-$a-BEGIN/,/MINROOT-$a-lsroot-status/p" "$B" |
                    grep -vE 'MINROOT-|^'"$a"'$')"
    info "[$a] \`ls /\` -> $(echo "$LS" | tr '\n' ' ' | cut -c1-200)"
    if echo "$LS" | grep -qw 'MINROOT-REALROOT-MARKER'; then
        bad "[$a] the machine's own root marker is visible in \`ls /\` -- this is the machine's root wearing a new name"
    else
        ok "[$a] the machine's root marker is NOT in \`ls /\` -- \`cd /\` is not the machine"
    fi

    # ---- the machine, still reachable from below ------------------------
    local NST; NST="$(pstat "$a" nmarker)"
    if [ "$NST" = 0 ]; then
        ok "[$a] and the machine's real root IS still reachable at /n (the Plan 9 place for roots that are not yours)"
    else
        bad "[$a] the machine's real root is NOT reachable at /n (status '$NST') -- a constructed root that cannot see the underpinning"
    fi

    # ---- the three suspects, REPORTED not required ----------------------
    # These are the MEASUREMENT. An arm in which hpm fails is not a failing
    # arm -- it is the answer. They are recorded as info and turned into
    # PASS/FAIL only by the cross-arm assertions in section 5, which is where
    # a real expectation exists.
    local EX HP WS LA
    EX="$(pstat "$a" binid)"; HP="$(pstat "$a" hpmlist)"
    WS="$(pstat "$a" wsys)";  LA="$(pstat "$a" launcher)"
    info "[$a] exec /bin/id      -> status '${EX:-<no line>}'"
    info "[$a] hpm list          -> status '${HP:-<no line>}'"
    info "[$a] /dev/wsys state   -> status '${WS:-<no line>}'"
    info "[$a] launcher binary   -> status '${LA:-<no line>}'"
    printf '%s %s %s %s %s\n' "$a" "${EX:-x}" "${HP:-x}" "${WS:-x}" "${LA:-x}" >>"$W/matrix.txt"
}

rm -f "$W/matrix.txt"
score_arm r1 "BARE: nothing but the mount points enter_root makes itself"
score_arm r2 "+bin: the machine's /bin bound in"
score_arm r3 "+bin +etc"
score_arm r4 "+bin +etc +var +usr +lib"

# =========================================================================
say "4 -- did every arm run?"
if grep -q 'MINROOT: ALL-ARMS-DONE' "$B"; then
    ok "the rc reached its last line, so no arm was cut short by the boot ending"
else
    bad "the rc did NOT reach its last line -- an arm may have hung or the timeout cut the run; later arms' results are suspect"
    tail -15 "$B" | sed 's/^/        /'
fi

# =========================================================================
say "5 -- THE FINDING: the cross-arm assertions"
# THE ONLY expectations this gate is willing to state as PASS/FAIL, because
# they are the ones that are true of ANY correct system rather than of this
# tree's current contents.
if [ -s "$W/matrix.txt" ]; then
    echo
    echo "        arm   exec  hpm   wsys  launcher   (0 = the name resolved)"
    while read -r a e h w l; do
        printf '        %-5s %-5s %-5s %-5s %s\n' "$a" "$e" "$h" "$w" "$l"
    done <"$W/matrix.txt"
    echo
fi

got() { grep -q "^$1 " "$W/matrix.txt" 2>/dev/null; }
val() { awk -v a="$1" -v c="$2" '$1==a{print $c}' "$W/matrix.txt"; }

# (a) A BARE root must NOT be able to exec the machine's programs. If it can,
#     the root switch is not confining anything and every other result here is
#     about a namespace that leaks.
if got r1; then
    if [ "$(val r1 2)" = 0 ]; then
        bad "[r1] /bin/id EXEC'D from a root that has no /bin -- the switch does not confine, so no arm below measures a constructed root"
    else
        ok "[r1] /bin/id could NOT be exec'd from a root with no /bin (status $(val r1 2)) -- the switch confines"
    fi
fi
# (b) Adding /bin must make exec work. If it does not, an app server serving
#     /bin is not enough and that is the headline.
if got r2; then
    if [ "$(val r2 2)" = 0 ]; then
        ok "[r2] binding ONLY /bin into a constructed root is enough to EXEC a program -- the machine's binaries do not need the machine's root"
    else
        bad "[r2] /bin was bound in and /bin/id still could not run (status $(val r2 2)) -- serving /bin is NOT sufficient; see $W/arm-r2.txt for what it said"
    fi
fi
# (c) The whole point: the machine's root must not be what a session lands in,
#     and the machine must still be reachable from below.
if got r4; then
    if [ "$(val r4 2)" = 0 ]; then
        ok "[r4] the maximal constructed root runs programs -- a session CAN be given a root that is not the machine's and still work"
    else
        bad "[r4] even /bin+/etc+/var+/usr+/lib bound into a constructed root could not run /bin/id (status $(val r4 2)) -- something outside those five names is assumed"
    fi
fi

finish
