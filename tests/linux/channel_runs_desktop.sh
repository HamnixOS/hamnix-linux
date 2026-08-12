#!/usr/bin/env bash
# tests/linux/channel_runs_desktop.sh — THE BYTES THAT SHIP MUST RUN.
#
# THE HOLE THIS CLOSES
# ====================
# hamnix-desktop 1.0.10 went to https://255.one/ carrying a `wsysd` compiled
# at 19:17 beside a `hampanelscene` and a `hamdesktop` compiled at 18:25,
# while `user/linux-wsys.c` -- the wsys backend all three link, and the file
# that had just doubled WSYS_MAX_WINDOWS and moved every field after it in
# `struct wwin` -- had been modified at 19:54. The object cache in
# scripts/hamlinux_packages.py stat'd only `user/<cmd>.ad`, so the two clients
# were never rebuilt and the channel shipped a mixed build. A machine that ran
# `hpm update` came up with a desktop that mapped NO WINDOWS AT ALL.
#
# EVERY EXISTING CHECK PASSED, AND HAD TO:
#   * tests/linux/channel_covers_image.sh compares NAMES. Every name was
#     present -- wsysd, hamdesktop and hampanelscene were all in the channel.
#   * the index's sha256 matched the bytes served. They were the wrong bytes,
#     consistently.
#   * scripts/hamlinux_packages.py resolved the dependency closure and found
#     no dangling requirement, no duplicate name, and printed a package count.
#   * the build printed `done`.
#
# And the sentence that names the actual gap, from the agent who found it:
#
#     "Every gate here builds from source through hamlinux_build.sh, so THE
#      ARTEFACT THAT SHIPS IS THE ONE ARTEFACT NOTHING RUNS."
#
# That is what this file is. It builds NOTHING it tests. It takes the .tar.gz
# files under a built channel's packages/ directory -- the exact bytes hpm
# downloads and unpacks -- pulls the binaries out of them, and RUNS them.
#
# THE RULE, MECHANICALLY ENFORCED (assertion "the rule" at the bottom): this
# file must never invoke scripts/hamlinux_build.sh for a program it makes an
# assertion about. A gate that can be satisfied by a rebuild from source is
# worthless here, because a rebuild from source is precisely what every other
# gate already does and precisely why 1.0.10 shipped.
#
# WHAT IT RUNS, AND WHY THAT SET
# ==============================
# Tier 1 -- INTEGRITY. Every tarball named below is unpacked from the channel;
#   when index.json exists, each one's sha256 is checked against what the index
#   advertises, so the bytes that are RUN below are provably the bytes an
#   installed machine would receive.
#
# Tier 2 -- THE DESKTOP, WHICH IS THE FAILURE THAT SHIPPED. wsysd, hamdesktop
#   and hampanelscene are unpacked into one directory and handed to
#   tests/linux/de_mouse_chrome.sh through its MOUSE_BIN_DIR hook, which
#   composes a real offscreen desktop and clicks it with synthetic evdev. It
#   asserts windows are MAPPED, the top bar exists, the Applications menu
#   opens and paints, and the desktop icons take a selection. A desktop that
#   maps no windows cannot reach its second assertion. These are the exact
#   three programs of the 1.0.10 mixture.
#
# Tier 3 -- THE REST OF THE MACHINE'S FLOOR, cheaply. `hamsh` (what PID 1
#   execs -- a machine whose shell does not run has no prompt to type the fix
#   into), `hpm` (the only route by which any future fix can ever arrive; a
#   broken hpm is a machine that can never be repaired remotely), and a
#   handful of side-effect-free coreutils asserted on their real output, which
#   exercise the shared runtime -- lib/*.ad and the user/linux-*.c device
#   backends -- from PACKAGED bytes rather than fresh ones.
#
# WHAT IT DELIBERATELY DOES NOT RUN, and why:
#   * The other ~90 per-command packages. Three reasons, in order of weight.
#     (a) SAFETY: the channel contains `halt`, `poweroff`, `reboot`, `rm`,
#         `kill`, `insmod`, `rmmod`, `modprobe`, `login`, `su`, `passwd`,
#         `dhcpc` and `ntpd`. Executing those on the build host is not a test,
#         it is an incident. This machine belongs to someone using it.
#     (b) The defect class is SHARED-INPUT staleness -- one edit under lib/ or
#         to a linux-*.c backend going into some binaries and not others. The
#         programs above link every one of those backends between them (wsys,
#         fb, input, proc/ns, net, the Adder runtime), so a stale shared
#         object shows up here.
#     (c) Time. This gate runs inside the packager, before the index is
#         written. MEASURED: 20 s end to end against the 98-package channel.
#         At 20 s it gets run; at ten minutes it gets skipped, and a gate that
#         is skipped is worth exactly nothing.
#   * A VM. Nothing here needs one: HAMFB_FILE gives wsysd a file to scan out
#     to and HAMWSYSD_INPUT gives it a file of evdev records to read, so the
#     whole desktop composes offscreen. Booting a VM would make this
#     too slow to sit in the publish path, which is the one place it has to be.
#     tests/linux/installed_update_live.sh is the VM-side gate and it measures
#     a different question -- whether a real installed disk can RECEIVE this.
#
# Usage:  tests/linux/channel_runs_desktop.sh [channel-dir]
#   default channel-dir: build/repo/linux
#   env: CHANRUN_KEEP=1   keep the work directory
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

CHAN="${1:-$PROJ_ROOT/build/repo/linux}"
KEEP="${CHANRUN_KEEP:-0}"
WORK="$(mktemp -d -p "${CHANRUN_TMP:-${TMPDIR:-/tmp}}" chanrun.XXXXXX)"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "chanrun: PASS $*"; }
bad()  { FAIL=$((FAIL+1)); echo "chanrun: FAIL $*"; }
info() { echo "chanrun: INFO $*"; }
cleanup() { [ "$KEEP" = 1 ] || rm -rf "$WORK"; }
trap cleanup EXIT
# A bare EXIT trap does not run when the shell is killed by a signal, so a
# gate stopped by `timeout` (TERM) or ^C (INT) skipped its cleanup entirely.
# Re-exit on those, which makes the EXIT trap above run on every path out.
trap 'exit 130' INT TERM HUP
report() {
    echo
    echo "chanrun: $PASS passed, $FAIL failed   (channel: $CHAN)"
    [ "$FAIL" = 0 ]
}

# A channel that is not there is not a pass. Every refusal below exits
# non-zero: "there was nothing to check" must never read as "it checked out".
[ -d "$CHAN/packages" ] || {
    bad "no channel at $CHAN/packages -- run scripts/hamlinux_packages.py first"
    report; exit 1; }

# =========================================================================
# TIER 1 -- get the binaries OUT OF THE TARBALLS, and prove they are the ones
# the index advertises.
# =========================================================================
BIN="$WORK/bin"; mkdir -p "$BIN"
UNPACK="$WORK/unpacked"; mkdir -p "$UNPACK"

# package:binary,binary,... -- the set justified in the header.
NEEDED="hamnix-desktop:wsysd,hamdesktop,hampanelscene
hamnix-hamsh:hamsh
hpm:hpm
hamnix-echo:echo
hamnix-seq:seq
hamnix-basename:basename
hamnix-md5sum:md5sum
hamnix-uname:uname
hamnix-true:true
hamnix-false:false
hamnix-cat:cat
hamnix-wc:wc"

# CHANRUN_NO_INDEX=1 is set by scripts/hamlinux_packages.py, which runs this
# gate BEFORE it writes index.json -- so that a channel that fails here never
# gets an index at all. Any index.json sitting in the directory at that moment
# is the PREVIOUS run's and describes bytes that are gone; checking against it
# would be worse than not checking, because it would answer confidently about
# the wrong build.
INDEX="$CHAN/index.json"
[ "${CHANRUN_NO_INDEX:-0}" = 1 ] && INDEX="$CHAN/index.json.notyet"
missing_pkg=""
for spec in $NEEDED; do
    pkg="${spec%%:*}"
    tgz="$(ls "$CHAN/packages/$pkg"-*.tar.gz 2>/dev/null | head -1)"
    if [ -z "$tgz" ]; then
        missing_pkg="$missing_pkg $pkg"
        continue
    fi
    tar xzf "$tgz" -C "$UNPACK" 2>/dev/null || missing_pkg="$missing_pkg $pkg(corrupt)"
done
if [ -n "$missing_pkg" ]; then
    bad "the channel does not carry:$missing_pkg -- a machine cannot install what is not there"
    report; exit 1
fi
ok "every package this gate runs is present in the channel and unpacks"

# Flatten the unpacked bin/ trees into one directory. Nothing is compiled.
find "$UNPACK" -path '*/files/bin/*' -type f -exec cp {} "$BIN/" \; 2>/dev/null
chmod +x "$BIN"/* 2>/dev/null

# The bytes that are about to be RUN are the bytes the index advertises. Not
# a version string, not a name -- the sha256 of the tarball they came out of.
if [ -f "$INDEX" ]; then
    HASHOUT="$(INDEX="$INDEX" CHAN="$CHAN" python3 - <<'PY'
import hashlib, json, os, sys
idx = json.load(open(os.environ["INDEX"]))
chan = os.environ["CHAN"]
checked = bad = 0
for e in idx.get("packages", []):
    f = e.get("url") or e.get("file") or e.get("filename") or e.get("path")
    want = e.get("sha256") or e.get("sha256sum")
    if not f or not want:
        print("NOHASH %s" % e.get("name")); bad += 1; continue
    p = os.path.join(chan, "packages", os.path.basename(f))
    if not os.path.exists(p):
        print("MISSING %s" % os.path.basename(f)); bad += 1; continue
    got = hashlib.sha256(open(p, "rb").read()).hexdigest()
    checked += 1
    if got != want:
        print("MISMATCH %s" % os.path.basename(f)); bad += 1
print("SUMMARY %d %d" % (checked, bad))
PY
)"
    set -- $(echo "$HASHOUT" | sed -n 's/^SUMMARY //p')
    NCHECK="${1:-0}"; NBAD="${2:-1}"
    if [ "$NCHECK" -lt 20 ]; then
        bad "only $NCHECK index entries carried a file+sha256 -- this gate cannot say the bytes it is about to run are the published ones"
    elif [ "$NBAD" = 0 ]; then
        ok "all $NCHECK packages in index.json hash to the bytes on disk -- what runs below is what an installed machine would receive"
    else
        bad "$NBAD package(s) do not match their index sha256:"
        echo "$HASHOUT" | grep -E '^(MISSING|MISMATCH|NOHASH)' | sed 's/^/chanrun:      /'
    fi
else
    # Called from inside scripts/hamlinux_packages.py, the index is written
    # AFTER this runs -- deliberately, so a channel that fails here never gets
    # an index at all. Say so; do not score it either way.
    info "no index.json yet (invoked before the index is written) -- the sha256 cross-check is NOT part of this run's score"
fi

# The three programs of the 1.0.10 mixture, by name, before anything runs.
# de_mouse_chrome.sh falls back to building anything MOUSE_BIN_DIR does not
# hold, so "is it there" has to be answered here or a missing binary would be
# silently replaced by a fresh one -- exactly the substitution this gate exists
# to forbid.
absent=""
for b in wsysd hamdesktop hampanelscene hamsh hpm; do
    [ -x "$BIN/$b" ] || absent="$absent $b"
done
if [ -n "$absent" ]; then
    bad "unpacked from the channel but NOT present:$absent"
    report; exit 1
fi
ok "wsysd, hamdesktop, hampanelscene, hamsh and hpm came out of the channel's tarballs (nothing was compiled)"
info "$(cd "$BIN" && ls | wc -l) binaries unpacked into $BIN"

# =========================================================================
# TIER 2 -- THE DESKTOP THAT SHIPPED, RUN.
# =========================================================================
# MOUSE_BIN_DIR is de_mouse_chrome.sh's own hook for this: with it set, the
# compositor, the desktop and the panel are the ELFs in that directory and the
# question becomes "do THOSE bytes route a click".
info "running the packaged desktop under tests/linux/de_mouse_chrome.sh (offscreen)"
MOUSE_LOG="$WORK/de_mouse_chrome.log"
MOUSE_BIN_DIR="$BIN" MOUSE_WORK="$WORK/mouse" \
    timeout 400 tests/linux/de_mouse_chrome.sh >"$MOUSE_LOG" 2>&1
MRC=$?
MPASS="$(sed -n 's/^mouse: \([0-9]*\) passed.*/\1/p' "$MOUSE_LOG" | tail -1)"
MFAIL="$(sed -n 's/^mouse: [0-9]* passed, \([0-9]*\) failed.*/\1/p' "$MOUSE_LOG" | tail -1)"
MPASS="${MPASS:-0}"; MFAIL="${MFAIL:-}"

if ! grep -q "came from $BIN" "$MOUSE_LOG"; then
    bad "de_mouse_chrome.sh did not report that it used the unpacked binaries -- it may have built from source, which would make this whole gate meaningless"
else
    ok "the desktop under test was the PACKAGED wsysd/hamdesktop/hampanelscene, not a fresh build"
fi

if [ "$MRC" = 124 ]; then
    bad "the packaged desktop ran for 400 s without finishing -- it hung"
elif [ -z "$MFAIL" ]; then
    bad "de_mouse_chrome.sh produced no score at all against the packaged binaries (exit $MRC) -- the packaged desktop did not get far enough to be measured"
    tail -25 "$MOUSE_LOG" | sed 's/^/chanrun:      /'
elif [ "$MFAIL" = 0 ] && [ "$MPASS" -ge 13 ]; then
    ok "THE PACKAGED DESKTOP WORKS: $MPASS/$MPASS under a synthetic mouse -- windows mapped, the top bar is there, the Applications menu opens and paints, and the desktop icons take a selection"
else
    bad "THE PACKAGED DESKTOP IS BROKEN: de_mouse_chrome.sh scores $MPASS PASS / $MFAIL FAIL against the bytes in this channel -- and these are the bytes 'hpm update' would install."
    grep '^mouse: FAIL' "$MOUSE_LOG" | sed 's/^mouse: /chanrun:      /'
fi
info "full desktop log: $MOUSE_LOG (CHANRUN_KEEP=1 to keep it)"

# =========================================================================
# TIER 3 -- THE FLOOR: the shell, the package manager, the runtime.
# =========================================================================
# hamsh is what user/linuxinit.ad execs as PID 1. It has no -c; argv[1] is an
# rc file, which is exactly how the boot rc is sourced, so this is the real
# path and not a special one.
RC="$WORK/rc.hamsh"
printf 'echo CHANRUN-SHELL-OK\nexit\n' >"$RC"
SHOUT="$(cd "$WORK" && timeout 60 "$BIN/hamsh" "$RC" 2>&1)"
if echo "$SHOUT" | grep -q 'CHANRUN-SHELL-OK'; then
    ok "the packaged hamsh runs and sources an rc script -- PID 1 has something to exec"
else
    bad "THE PACKAGED hamsh DID NOT RUN AN RC SCRIPT -- a machine that installs this channel boots to no shell"
    echo "$SHOUT" | tail -12 | sed 's/^/chanrun:      /'
fi

# hpm with no arguments prints its usage and touches nothing. This is the one
# program whose failure is unrecoverable: a machine whose hpm does not run can
# never be sent another fix.
HPMOUT="$(cd "$WORK" && timeout 60 "$BIN/hpm" 2>&1)"
if echo "$HPMOUT" | grep -q 'refresh' && echo "$HPMOUT" | grep -q 'install'; then
    ok "the packaged hpm runs and knows its own verbs -- an installed machine can still receive the NEXT fix"
else
    bad "THE PACKAGED hpm DID NOT PRINT ITS VERBS -- a machine that installs this channel can never be updated again"
    echo "$HPMOUT" | tail -12 | sed 's/^/chanrun:      /'
fi

# The runtime, from packaged bytes. Every one of these is side-effect-free and
# is asserted on REAL OUTPUT, not on an exit status -- `ps` exiting 0 having
# listed nothing is in NORTH_STAR.md as the shape to refuse.
runq() { ( cd "$WORK" && timeout 30 "$BIN/$1" "${@:2}" 2>/dev/null ); }
CU_OK=0; CU_BAD=""
check() {  # check <label> <expected> <actual>
    if [ "$3" = "$2" ]; then CU_OK=$((CU_OK+1)); else CU_BAD="$CU_BAD $1(want='$2' got='$3')"; fi
}
printf 'chanrun\n' >"$WORK/probe.txt"
check echo     "hamnix"        "$(runq echo hamnix)"
check seq      "1 2 3"         "$(runq seq 1 3 | tr '\n' ' ' | sed 's/ $//')"
check basename "c.txt"         "$(runq basename /a/b/c.txt)"
check cat      "chanrun"       "$(runq cat probe.txt)"
check wc       "1"             "$(runq wc -l probe.txt | tr -s ' ' | sed 's/^ *//' | cut -d' ' -f1)"
check md5sum   "$(md5sum "$WORK/probe.txt" | cut -d' ' -f1)" "$(runq md5sum probe.txt | cut -d' ' -f1)"
check uname    "Hamnix"        "$(runq uname | cut -d' ' -f1)"
runq true;  TRC=$?
runq false; FRC=$?
if [ "$TRC" = 0 ] && [ "$FRC" != 0 ]; then CU_OK=$((CU_OK+1))
else CU_BAD="$CU_BAD exit-status(true=$TRC false=$FRC)"; fi
if [ -z "$CU_BAD" ]; then
    ok "$CU_OK/$CU_OK packaged coreutils produced the right ANSWER (not merely exit 0) -- the shared Adder runtime in these bytes works"
else
    bad "packaged coreutils gave wrong answers:$CU_BAD"
    info "a wrong answer from several unrelated commands at once means the SHARED runtime in this channel is stale or broken, not one program"
fi

# =========================================================================
# THE RULE THIS GATE EXISTS TO KEEP
# =========================================================================
# If a future edit lets this file compile any of the programs it asserts on,
# it stops measuring the channel and starts measuring the working tree -- and
# a channel with a stale desktop would go green again. Say so rather than go
# quietly green. (The grep skips comments, and skips its own two lines.)
if grep -vE '^[[:space:]]*#' "${BASH_SOURCE[0]}" \
        | grep -v 'hamlinux_build.sh is never' \
        | grep -q 'hamlinux_build\.sh'; then
    bad "THIS GATE BUILDS FROM SOURCE -- it no longer proves anything about the bytes in the channel"
else
    ok "nothing in this file compiles anything: hamlinux_build.sh is never invoked here, so every assertion above is about the channel's own bytes"
fi

report
