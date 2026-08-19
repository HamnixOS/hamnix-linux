#!/usr/bin/env bash
#
# scripts/release_gates.sh — THE RELEASE DRIVER, IN THE TREE.
#
# WHY THIS FILE EXISTS, AND WHERE IT USED TO LIVE
# ===============================================
# Until 2026-08-18 the thing that decided whether a release shipped was
# `~/.hamnix-build/rel<NNNN>/gates.sh` — a file typed fresh each release,
# living OUTSIDE the repository, reviewed by nobody, and regressed by nothing.
# It had, in its own scoring, the exact defect this tree has spent a week
# cataloguing everywhere else. Two of them, both measured:
#
#   1. IT COUNTED THE WORD "PASS". Its scorer was
#          grep -cE '(^|[[:space:]])PASS([[:space:]]|:)' "$log"
#      tests/linux/wsys_stdin_keydup.sh reports assertions as `ok   <text>` and
#      summarises as `8 passed, 0 failed` — lowercase, no bare `PASS` token.
#      So `rel1029/GATES_SUMMARY.txt` recorded, verbatim:
#
#          wsys_stdin_keydup EXIT=0
#          wsys_stdin_keydup PASS-lines: 0
#          wsys_stdin_keydup FAIL-lines: 0
#
#      for a gate that really scored 8 / 0. A gate that asserted EIGHT things
#      and a gate that asserted NOTHING produced byte-identical scores. That is
#      "exit 0 read as a pass" — the class this tree keeps finding — alive in
#      the one script that gates the release.
#
#   2. THE MEDIUM GATE WAS NOT IN IT. `scripts/verify_medium.sh` appears zero
#      times in rel1029/gates.sh. Its 39 / 0 came from a separate invocation
#      typed by hand. The one gate that inspects the shipped medium was never
#      run by the driver that gates the shipped medium.
#
# THE RULES THIS DRIVER OBEYS
# ===========================
#   * A GATE IS SCORED BY WHAT IT ASSERTED, NOT BY WHAT IT RETURNED. The exit
#     status is recorded and cross-checked, never used as the pass criterion.
#   * A GATE WHOSE OUTPUT CANNOT BE PARSED IS **UNSCORABLE**, NOT ZERO. It
#     turns the release red and says so in words. Silence must never be
#     spendable as a green.
#   * A GATE THAT SCORED 0 / 0 ASSERTED NOTHING, AND THAT IS NOT A PASS.
#   * MANY VOCABULARIES, ONE MEANING. `8 passed, 0 failed`,
#     `14 PASSED / 0 FAILED`, `18 PASSED, 0 FAILED`, `pass=21 fail=1`,
#     `SUMMARY: 39 PASSED, 39 FAILED` are all read. A gate is free to print in
#     its own dialect; the driver is not free to score only one dialect.
#   * THE SUMMARY IS CROSS-CHECKED AGAINST THE GATE'S OWN ASSERTION LINES. If a
#     gate printed FAIL lines under a summary claiming zero failures, the
#     release goes red — the summary is not believed over the body.
#   * A KNOWN FAILURE MUST BE DECLARED HERE, IN THE REGISTRY, WITH ITS REASON.
#     An undeclared failure is red however long it has been failing.
#   * A GATE THAT ASSERTS FEWER THINGS THAN IT USED TO IS RED. Each registry
#     row carries `expect_min`, the number of assertions the gate is known to
#     make. MEASURED 2026-08-18: scripts/verify_medium.sh scored 39 / 0 for the
#     1.0.29 release and 38 / 0 from a clean worktree — it drops its
#     '/bin/hpm on the medium is the channel's hpm' assertion, silently and
#     with no FAIL line, when build/repo/linux/packages is absent. A driver
#     that only reads 'N passed, 0 failed' cannot tell a gate that lost an
#     assertion from one that passed them all.
#
# NEGATIVE CONTROL
# ================
#   bash scripts/release_gates.sh --self-test
# runs the driver over two synthetic gates: one that scores 8 / 0 in the exact
# `ok` / `FAIL` vocabulary the old driver could not see, and one that exits 0
# having asserted nothing at all. The driver must score the first 8 / 0 GREEN
# and refuse the second. If those two come out the same, this driver is as
# blind as the one it replaces and the self-test fails.
#
# USAGE
# =====
#   HAMLINUX_RELEASE_IMG=~/.hamnix-build/rel1029/hamnix-linux-1.0.29.img \
#   HAMLINUX_RELEASE_DIR=~/.hamnix-build/rel1029 \
#     bash scripts/release_gates.sh [gate-name ...]
#
#   --list        print the registry and exit
#   --self-test   run the negative control described above and exit
#   --host-only   skip every gate marked as booting QEMU
#
# Environment:
#   HAMLINUX_RELEASE_IMG   the medium under test (required by the medium gates)
#   HAMLINUX_RELEASE_SHA   its expected sha256 (passed to shipped_medium_boots)
#   HAMLINUX_RELEASE_DIR   where logs are written (default: a mktemp -d)
#
# REGISTRATION: this file is not in ci_battery_manifest.txt because it is a
# release driver, not a gate — it runs gates, several of which boot QEMU and
# take a release artifact that no CI runner has. Its own correctness is gated
# by --self-test, which is QEMU-free and IS registered.
#
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

IMG="${HAMLINUX_RELEASE_IMG:-}"
SHA="${HAMLINUX_RELEASE_SHA:-}"
OUT="${HAMLINUX_RELEASE_DIR:-}"

# =============================================================================
# THE SCORER
# =============================================================================
# score_log <file> — echoes "<pass> <fail> <dialect>" and returns 0, or returns
# 1 having echoed nothing, meaning THE OUTPUT COULD NOT BE PARSED. Returning 1
# is a real answer: it is "I do not know what this gate asserted", which is a
# different thing from "it asserted nothing", which is different again from
# "it asserted things and none failed". The old driver collapsed all three.
score_log() {
    awk '
        function take(p, f, d) { P = p; F = f; D = d; seen = 1 }
        # 1. "<n> PASSED / <m> FAILED"  and  "<n> PASSED, <m> FAILED"
        match($0, /[0-9]+[ \t]+PASSED[ \t]*[,\/][ \t]*[0-9]+[ \t]+FAILED/) {
            s = substr($0, RSTART, RLENGTH)
            n = s; sub(/[^0-9].*$/, "", n)
            m = s; sub(/^[^,\/]*[,\/][ \t]*/, "", m); sub(/[^0-9].*$/, "", m)
            take(n, m, "N PASSED/FAILED"); next
        }
        # 2. "<n> passed, <m> failed"  (lowercase — the dialect that scored 0)
        match($0, /[0-9]+[ \t]+passed[ \t]*[,\/][ \t]*[0-9]+[ \t]+failed/) {
            s = substr($0, RSTART, RLENGTH)
            n = s; sub(/[^0-9].*$/, "", n)
            m = s; sub(/^[^,\/]*[,\/][ \t]*/, "", m); sub(/[^0-9].*$/, "", m)
            take(n, m, "n passed, m failed"); next
        }
        # 3. "pass=<n> fail=<m>"
        match($0, /pass=[0-9]+[ \t]+fail=[0-9]+/) {
            s = substr($0, RSTART, RLENGTH)
            n = s; sub(/^pass=/, "", n); sub(/[^0-9].*$/, "", n)
            m = s; sub(/^.*fail=/, "", m); sub(/[^0-9].*$/, "", m)
            take(n, m, "pass=n fail=m"); next
        }
        # 4. "<n> PASS / <m> FAIL"  (no -ED)
        match($0, /[0-9]+[ \t]+PASS[ \t]*[,\/][ \t]*[0-9]+[ \t]+FAIL([^A-Za-z]|$)/) {
            s = substr($0, RSTART, RLENGTH)
            n = s; sub(/[^0-9].*$/, "", n)
            m = s; sub(/^[^,\/]*[,\/][ \t]*/, "", m); sub(/[^0-9].*$/, "", m)
            take(n, m, "N PASS/FAIL"); next
        }
        END { if (seen) printf "%d %d %s\n", P, F, D }
    ' "$1"
}

# tally_log <file> — echoes "<ok-lines> <fail-lines>". This is the CROSS-CHECK,
# not the score: it counts the gate's own per-assertion lines in every prefix
# vocabulary this tree uses (`ok  `, `  PASS  `, `  FAIL  `, `FAIL `, `not ok`)
# so that a summary line claiming zero failures over a body full of FAILs can
# be caught. verify_medium.sh's own header records that exact escape happening.
#
# THE `[tag] PASS` DIALECT WAS NOT COUNTED, AND THAT IS THE SAME BLINDNESS THIS
# FILE EXISTS FOR. scripts/test_de_home_resolve_host.sh and
# scripts/test_install_names_host.sh print `[homedir] PASS ...` /
# `[instnames] FAIL ...`, and both scored "0 ok-ish, 0 fail-ish" here -- meaning
# the body-versus-summary cross-check, the one that catches a gate claiming
# 0 FAILED over a body full of failures, was OFF for them while the driver
# reported them GREEN. Measured 2026-08-18, the day they were registered. The
# bracketed tag is OPTIONAL in the pattern, so every older dialect counts
# exactly as it did.
tally_log() {
    awk '
        /^[ \t]*(\[[A-Za-z0-9_.-]+\][ \t]+)?(ok|PASS)[ \t]/   { o++ }
        /^[ \t]*(\[[A-Za-z0-9_.-]+\][ \t]+)?(FAIL|not ok)[ \t]/ { f++ }
        END { printf "%d %d\n", o+0, f+0 }
    ' "$1"
}

# =============================================================================
# THE REGISTRY
# =============================================================================
# One record per line:
#   name | qemu | allow_fail | expect_min | reason-for-allowance | command
# `qemu` is yes/no. `allow_fail` is the number of failures DECLARED acceptable;
# anything above it is red, and 0 is the default. `expect_min` is the number of
# assertions the gate is KNOWN to make; scoring fewer is red even when none of
# them failed. Every number here was measured on this host on 2026-08-18 and is
# a reviewable act in version control, which is the entire point of this file
# not living in a scratch directory any more.
registry() {
cat <<'REGISTRY'
wsys_stdin_keydup|no|0|8||bash tests/linux/wsys_stdin_keydup.sh
hamsh_eof_exit|no|0|14||bash tests/linux/hamsh_eof_exit.sh
wsys_zombie_strand|no|0|8||bash tests/linux/wsys_zombie_strand.sh
# wsys_zombie_owner.sh was in scripts/ci_battery_manifest.txt and NOT here.
# The driver ran the gate for the 2026-08-18 segment fix and not the gate for
# the 2026-08-17 window-reaper fix in the same file. Measured 9 / 0 on this
# host, 2026-08-18, before it was registered.
wsys_zombie_owner|no|0|9||bash tests/linux/wsys_zombie_owner.sh
test_hamsh_tok_capacity|no|0|18||bash scripts/test_hamsh_tok_capacity.sh
test_livedom_functional_host|no|1|22|06_class_style_toggle is declared in the gate's own KNOWNFAIL list|bash scripts/test_livedom_functional_host.sh
# THE TWO HOST GATES FOR THE OFFICE-DOCUMENT AND ACCOUNT-NAME FIXES. Both are
# QEMU-free and run in seconds, so there is no excuse for a release not to run
# them. Both numbers were MEASURED on this host, 2026-08-18, immediately before
# they were written here.
#
# test_de_home_resolve_host also RUNS hd_home_join() -- the join
# hamwrite/hamsheet/hamslides now use instead of the literal
# "/home/live/Documents/" -- so its 26 includes run-time evidence that those
# string literals are not NULL at run time, which on this backend is a real
# hazard for globals and the reason the installer once segfaulted after writing
# every file correctly. Where those programs ACTUALLY WRITE is measured by
# tests/linux/installed_documents.sh, which boots an installed machine; that
# gate is on-demand and is not registered here.
test_de_home_resolve_host|no|0|26||bash scripts/test_de_home_resolve_host.sh
test_install_names_host|no|0|23||bash scripts/test_install_names_host.sh
channel_bytes_match_image|no|0|3||bash tests/linux/channel_bytes_match_image.sh
# WHICH ROOT THIS RUNS AGAINST, because the number means nothing without it.
# The driver runs after the build has rebuilt build/image/root with
# HAMLINUX_INSTALLER=1, so this row measures the INSTALLER root -- the one
# the shipped medium is packed from. At 1.0.31 that root scored 7 / 26 and
# the release shipped RED on this row: the 26 were the installer overlay
# (boot/ 5, etc/installer-medium 1, usr/lib/instroot/ 20), which no package
# owns and none of which was in the gate's exclusion table. They are in it
# now, each with a reason, and the gate grew four assertions that MEASURE the
# boot/ reason instead of asserting it.
#
# expect_min is 11 and not 12 deliberately. MEASURED on this host, 2026-08-19,
# against the 1.0.31 channel:
#     lean image root (424 files)          11 / 0
#     installer image root                 11 / 0
#     installed-disk root (453 files)      12 / 0
# The disk root scores one more because etc/fstab and var/lib/hpm/installed.json
# exist only on a partition scripts/hamlinux_disk.sh wrote, so on an image root
# those two exclusions match nothing and the 'no exclusion is folklore' PASS
# becomes a note. 11 is the floor every root clears.
channel_covers_image|no|0|11||bash tests/linux/channel_covers_image.sh
pkg_tar_reproducible|no|0|5||bash tests/linux/pkg_tar_reproducible.sh
verify_medium|no|0|39||bash scripts/verify_medium.sh @IMG@
install_confirm_keys|yes|0|34||bash tests/linux/install_confirm_keys.sh
install_wizard_gui|yes|0|34||bash tests/linux/install_wizard_gui.sh
# THE SOAK'S DURATION IS PINNED HERE, not left to an env var typed at the
# console. tests/linux/soak_desktop.sh defaults to 3600 s; expect_min=26 was
# measured at 900 s with ARM 0 ARMED (no HAMLINUX_SOAK_SKIPPROOF). A release
# driver that inherits the duration from whoever invoked it is not a record
# of what was run. env(1) is used because the runner word-splits this command
# and a bare VAR=x prefix would be taken as the program name.
soak_desktop|yes|0|26||env HAMLINUX_SOAK_SECS=900 bash tests/linux/soak_desktop.sh
shipped_medium_boots|yes|0|31||bash tests/linux/shipped_medium_boots.sh @IMG@
# THE THREE GATES THAT INSPECT AN INSTALLED MACHINE, AND WERE IN NO REGISTRY
# AT ALL. installed_accounts.sh and installed_offers_install.sh carry the whole
# of the account, password and self-offering-installer work -- the fixes this
# line shipped in 1.0.30 and 1.0.31 -- and NOTHING RAN THEM. That is precisely
# the defect this file was written to eliminate ("the one gate that inspects
# the shipped medium was never run by the driver that gates it"), reproduced on
# the gates that matter most. installed_documents.sh is the new one: it drives
# a Save in the word processor on a booted installed machine and reads the
# disk.
#
# installed_documents's 48 WAS measured, twice, on this host on 2026-08-18: the
# tree as committed scores 48/0, and the same file on a tree whose three
# _default_docpath() functions are reverted to the "/home/live/Documents/..."
# literal scores its failures on the disk assertions. The other two numbers
# were not.
#
# THE OTHER TWO WERE BLANK, WHICH MEANT ZERO, AND THEY ARE FILLED IN NOW --
# MEASURED, ON THIS HOST, IN THE 1.0.32 RELEASE RUN OF 2026-08-19, not copied
# from the HANDOFF entry that reported the same two figures from an earlier
# tree. The previous session left them blank rather than copy an unmeasured
# number, which was right; this session ran them and they came out
#
#     installed_accounts        61 PASSED / 0 FAILED
#     installed_offers_install  24 PASSED / 0 FAILED
#
# on a tree that has a package database on the installed-disk path, which is
# the change that made the earlier figures a report rather than a measurement.
# They agree with the report; that is a fact about the run, not the reason for
# the number.
installed_accounts|yes|0|61||bash tests/linux/installed_accounts.sh
installed_offers_install|yes|0|24||bash tests/linux/installed_offers_install.sh
installed_documents|yes|0|48||bash tests/linux/installed_documents.sh

# WHOSE FILE IS IT, WHEN THE DESKTOP STARTS THE PROGRAM THAT WROTE IT? 66/0
# measured on this host, 2026-08-19, in the run that registered it -- one medium
# build, one install onto a blank disk, three boots.
#
# THIS IS THE GATE installed_documents CANNOT BE. That one REPRODUCES the launch
# from the machine's rc (`spawn detached ns { /bin/<app> }`) and says so in its
# own header; it executes no line of hampanelscene, hamappmenu or hamdesktop, so
# its 48/0 is unmoved by any change to a launcher -- and it still reads uid 0 on
# every document, correctly, because the rc it drives is not the desktop. THIS
# one writes a payload to /dev/wsys/appmenu/launch and lets the shipped panel's
# own _drain_one_launch_queue() do the spawning.
#
# ITS NEGATIVE CONTROL IS AN ARM, NOT A SECOND RUN: hamsheet is queued as a BARE
# path in the same boot sequence, through the same binary and the same drain
# function, and must come out uid 0 -- which is what keeps
# install_confirm_keys's `echo '/bin/haminstallui' > '/dev/wsys/appmenu/launch'`
# working. A third arm (hamslides, `user`) exists so the split cannot line up
# with WHICH PROGRAM instead of WHICH PAYLOAD.
installed_launch_uid|yes|0|66||bash tests/linux/installed_launch_uid.sh
# THE POINTER HALF OF THE SAME QUESTION, and the half no gate could see before
# it. installed_launch_uid says in its own header "IT DOES NOT CLICK AN ICON OR
# A MENU ROW"; this one does both, on five boots of one installed disk, with a
# real pointer over QMP and nothing writing the launch queue. Its negative
# control is an ARM of the same run: menuperson and menuchrome launch the SAME
# /bin/hamwrite from the SAME menu and differ only by X-Hamnix-SystemChrome in
# one .desktop file, and the identity flips 1001 -> 0. The expected count is
# left at 0 until a clean full run is recorded here; the run that landed this
# file scored 75/4 with all four reds in the gate's own instrument, both since
# fixed (see the commit).
pointer_launch_uid|yes|0|0||bash tests/linux/pointer_launch_uid.sh
# THE GRAPHICAL LOGIN. The gdm-shaped half of the owner's "getty ... and a gdm
# like login interface for the GUI too". installed_boot_login and
# installed_fresh_login measure the TTY half on a serial line; this one
# measures the graphical half with OCR of a screendump and a process census
# read off an unmounted ext4 with debugfs. The claim it exists for is an
# ABSENCE -- that no session program exists before somebody authenticates --
# so the control that the same instrument CAN see one after authentication is
# an ARM OF THE SAME BOOT and is scored before any absence is believed. A
# SECOND boot of the same disk proves last boot's session recipe does not
# authorise this one. The expected count is left at 0 until a clean full run
# is recorded here.
graphical_login|yes|0|0||bash tests/linux/graphical_login.sh
# A PERSON CLICKS APPLICATIONS -> INSTALL HAMNIX ON A LIVE MEDIUM AND A DISK
# GETS PARTITIONED. 19/0 measured 2026-08-19. Both other wizard gates start
# haminstallui by writing the launch queue; this one starts it with a pointer
# on a menu row, requires it to be ROOT (installer.desktop is chrome-marked),
# and then requires a target's sha256 to move and sfdisk to read a GPT off it
# that was not there before. Two arm-and-confirm rounds were needed and that is
# scored: one would be the single-keypress-erase defect install_confirm_keys
# exists to prevent.
live_pointer_install|yes|0|19||bash tests/linux/live_pointer_install.sh
# The end-to-end half of the reserved-name / over-long-name refusals. 16/0
# measured on this host, 2026-08-18, immediately before it was written here;
# the QEMU-free half is test_install_names_host above.
install_refuses_reserved|yes|0|16||bash tests/linux/install_refuses_reserved.sh
# DOES `poweroff` POWER OFF A MACHINE WHOSE COMPOSITOR IS PRESENTING? Until
# 2026-08-19 it did not: user/poweroff.ad wrote its banner to fd 1 before it
# opened /dev/reboot, and once the compositor is presenting that write does not
# return -- so the /dev/reboot write was never reached and three graphical
# boots in a row sat past a 300 s deadline. `halt` and `reboot` had the same
# shape. The gate boots three machines: the shipped binary on a graphical one
# (must power off), the SAME program with the banner line put back on the same
# desktop (must hang -- the negative control, and it is RUN), and that same
# reverted binary on a machine with no GPU at all (must power off, so a red in
# the second arm cannot be a broken build).
#
# expect_min 22, MEASURED on this host in the 1.0.32 release run of 2026-08-19,
# by the gate AS IT NOW STANDS. It was left blank until then and the reason is
# worth keeping: the gate had been run at 21 PASSED / 3 FAILED, and then its
# arm-B scoring was changed because THE NEGATIVE CONTROL DID NOT FIRE -- the
# banner-restored binary powered a presenting graphical machine off in 21 s and
# again in 18 s, in two different display configurations. Two of those three
# assertion lines became reports in that change, so 22 was available by
# ARITHMETIC on a run of the OLD scoring, and a computed number is exactly what
# a blank exists to refuse. The release run then scored the new gate at 22 / 0
# and that is where this number comes from. That the two agree is an
# observation, not the reason.
poweroff_graphical|yes|0|22||bash tests/linux/poweroff_graphical.sh

# CAN A PROGRAM RUNNING AS THE PERSON BE HEARD AT ALL? 23/0 measured on this
# host, 2026-08-19, in the run that registered it -- one medium build, one
# install, one boot. It matters to every OTHER gate in this list: until
# 2026-08-19 /dev/ttyS0 was mode 0600 root, so anything a uid-1001 process
# printed reached the screen and nothing else, while write(2) reported the full
# byte count. A gate whose oracle is a serial line printed by a dropped session
# read that as "it never ran" -- which is exactly what installed_documents.sh
# did, and a fix was reverted over it (416248df).
installed_uid_console|yes|0|23||bash tests/linux/installed_uid_console.sh

# DOES THE MACHINE ASK WHO YOU ARE BEFORE IT GIVES YOU A SHELL? Until
# 2026-08-19 it did not: /etc/rc.boot ended, and PID 1 -- which IS hamsh --
# fell through into its own interactive prompt, an unauthenticated uid 0 shell
# on the console of a machine that had just booted. installed_login.sh proved
# the passwords WORK; nothing demanded one. 27/0 measured on this host in the
# run that registered it, two arms of one invocation.
#
# THE COUNT INCLUDES ITS OWN NEGATIVE CONTROL, which is why it is worth 27 and
# not 13: the guarded arm's central claim is an ASSERTION OF ABSENCE ("no root
# shell before authentication"), and the autologin arm -- the same rc, the same
# getty, the same port, differing by the two words `-a hostowner` -- must
# REACH a root shell for the guarded arm's silence to mean anything. If the
# control stops firing this gate goes red on the control, not on the product.
installed_boot_login|yes|0|27||bash tests/linux/installed_boot_login.sh

# DOES A MACHINE THE INSTALLER JUST BUILT ASK WHO YOU ARE? installed_boot_login
# above proved the guard works; it did so on a disk whose /etc/rc.boot THE GATE
# WROTE. Nobody had ever run the installer against the change, and its fallback
# branch -- reached when the medium carries no /etc/rc.boot.machine -- wrote a
# one-line rc with NO login program and NO `supervise`, then returned 0. That is
# an installer printing "install complete" over a machine that boots straight to
# an unauthenticated root prompt. 31/0 measured on this host, 2026-08-19, in the
# run that registered it: one medium build, THREE installs in one boot, and two
# boots of the resulting disk.
#
# THE COUNT INCLUDES TWO CONTROLS THAT RUN. Arm C deletes /etc/rc.login as well,
# so the installer CANNOT produce a machine that asks, and must fail loudly --
# it exited 1 and never printed "install complete", while arm A did print it, so
# the absence is a difference and not a grep that never matches. And the boot
# control is the same installed disk with `-a hostowner` on the console getty,
# which MUST reach a root shell with no password; it answered `uid=0 gid=0`. If
# either control stops firing this gate goes red on the control, not the product.
installed_fresh_login|yes|0|31||bash tests/linux/installed_fresh_login.sh

# WHAT BREAKS WHEN `/` IS NOT THE MACHINE'S ROOT -- the first booted measurement
# of the owner's "the global root should be min as possable" direction. 16 PASSED
# / 4 FAILED on this host, 2026-08-19, in the run that registered it.
#
# THE FOUR FAILURES ARE DECLARED, AND THEY ARE NOT ONE KIND. Do not raise this
# number to make a new red go away; if the count moves, read which arm moved.
#
#   TWO ARE THE LADDER'S LOWER RUNGS, and they are the measurement, not a bug.
#   r1 (no /bin) and r2 (/bin but no dynamic loader) cannot run a program at
#   all, so the gate refuses to report anything else from them. r1 says
#   `command not found` (cat and ls are hamsh BUILTINS and an `enter` body does
#   not dispatch builtins); r2 says NOTHING and exits 127, which is
#   user/hamsh.ad's own documented silent shape. If r2 ever goes green the
#   loader stopped being needed and this comment is stale.
#
#   TWO ARE A REAL DEFECT AND SHOULD GO GREEN WHEN IT IS FIXED. In r3 and r4 --
#   which DO work: `cd /` shows ten entries instead of the machine's nineteen,
#   and /bin/id, /bin/hpm and the launcher all run -- `cat
#   /n/MINROOT-REALROOT-MARKER` answers "No such file or directory". The
#   template runs `bind '#/' /n` exactly as etc/rc.de-user.linux does, and THE
#   MACHINE'S REAL ROOT IS STILL NOT REACHABLE AT /n. That is the Plan 9
#   underpinning the owner's whole direction rests on, and it does not survive
#   the root switch. When it does, this line becomes |2| and then |0|.
session_min_root|yes|4|16||bash tests/linux/session_min_root.sh
REGISTRY
}

# =============================================================================
# THE RUNNER
# =============================================================================
RED=0; GREEN=0; UNSCORABLE=0; TOTAL_ASSERTED=0
VERDICTS=""

run_gate() {   # run_gate <name> <allow_fail> <expect_min> <reason> <cmd...>
    local name="$1" allow="$2" expect="$3" reason="$4"; shift 4
    [ -n "$expect" ] || expect=0
    local log="$OUT/$name.log"
    printf '########## %-32s %s\n' "$name" "$(date +%H:%M:%S)"
    "$@" >"$log" 2>&1
    local rc=$?

    local s p f dialect
    s="$(score_log "$log")"
    if [ -z "$s" ]; then
        printf '  %-14s exit=%s  -- THE DRIVER COULD NOT PARSE THIS GATE'"'"'S OUTPUT.\n' "UNSCORABLE" "$rc"
        echo   "                 It printed no summary line in any dialect this driver knows."
        echo   "                 THIS IS NOT A ZERO AND IT IS NOT A PASS. Either the gate"
        echo   "                 asserted nothing, or it speaks a dialect that must be added"
        echo   "                 to score_log() in scripts/release_gates.sh. Log: $log"
        UNSCORABLE=$((UNSCORABLE+1)); RED=$((RED+1))
        VERDICTS="$VERDICTS$name UNSCORABLE (exit $rc)\n"
        echo; return
    fi
    p="${s%% *}"; f="$(echo "$s" | cut -d' ' -f2)"; dialect="$(echo "$s" | cut -d' ' -f3-)"

    local t to tf
    t="$(tally_log "$log")"; to="${t%% *}"; tf="${t##* }"

    local verdict="PASS" why=""
    if [ "$p" -eq 0 ] && [ "$f" -eq 0 ]; then
        verdict="RED"; why="THE GATE ASSERTED NOTHING -- 0 passed and 0 failed is not a pass"
    elif [ "$f" -gt "$allow" ]; then
        verdict="RED"; why="$f failed, $allow declared acceptable"
    elif [ "$tf" -gt 0 ] && [ "$f" -eq 0 ]; then
        verdict="RED"; why="the gate printed $tf FAIL line(s) under a summary claiming 0 failures -- the body is believed, not the summary"
    elif [ "$rc" -ne 0 ] && [ "$f" -le "$allow" ]; then
        verdict="RED"; why="exit status $rc contradicts a summary with no unexpected failures -- one of the two is wrong and neither may be ignored"
    elif [ "$((p + f))" -lt "$expect" ]; then
        verdict="RED"; why="the gate scored $((p + f)) assertions where $expect are registered -- it ASSERTED LESS THAN IT USED TO and printed no failure saying so"
    fi

    printf '  %-14s %s / %s   exit=%s   [%s]\n' \
        "$verdict" "$p passed" "$f failed" "$rc" "$dialect"
    printf '                 assertion lines seen in body: %s ok-ish, %s fail-ish\n' "$to" "$tf"
    [ -n "$reason" ] && [ "$allow" -gt 0 ] && \
        printf '                 %s failure(s) DECLARED: %s\n' "$allow" "$reason"
    [ -n "$why" ] && printf '                 WHY RED: %s\n' "$why"
    printf '                 log: %s\n' "$log"

    TOTAL_ASSERTED=$((TOTAL_ASSERTED + p + f))
    if [ "$verdict" = "PASS" ]; then GREEN=$((GREEN+1)); else RED=$((RED+1)); fi
    VERDICTS="$VERDICTS$name $verdict ${p}/${f}\n"
    echo
}

# =============================================================================
# THE NEGATIVE CONTROL
# =============================================================================
self_test() {
    local d; d="$(mktemp -d)"
    OUT="$d"

    # (A) A gate that asserts EIGHT things and fails none, in the `ok` / `FAIL`
    #     vocabulary and the lowercase summary that the old driver scored ZERO.
    cat >"$d/eight.sh" <<'GATE'
#!/usr/bin/env bash
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1"; }
for i in 1 2 3 4 5 6 7 8; do ok "synthetic assertion $i"; done
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || exit 1
GATE

    # (B) A gate that genuinely asserts NOTHING and exits 0 -- the 43-skipped
    #     shape that was once reported as "40 of 40 pass".
    cat >"$d/nothing.sh" <<'GATE'
#!/usr/bin/env bash
echo "=== synthetic gate: preconditions not met"
echo "SKIPPED: the lane this gate asserts against was retired"
exit 0
GATE

    # (C) A gate that prints a clean summary over a body full of real failures.
    cat >"$d/liar.sh" <<'GATE'
#!/usr/bin/env bash
echo "  PASS  something true"
echo "  FAIL  something that is actually broken"
echo "  FAIL  something else that is actually broken"
echo "SUMMARY: 1 PASSED, 0 FAILED"
exit 0
GATE

    # (D) A gate that used to assert eight things and now asserts three,
    #     failing none of them and saying nothing about the five it dropped.
    #     This is scripts/verify_medium.sh's real 39 -> 38, in miniature.
    cat >"$d/shrunk.sh" <<'GATE'
#!/usr/bin/env bash
PASS=0
ok() { PASS=$((PASS+1)); echo "ok   $1"; }
for i in 1 2 3; do ok "synthetic assertion $i"; done
echo "$PASS passed, 0 failed"
GATE

    echo "=== scripts/release_gates.sh --self-test"
    echo "=== THE NEGATIVE CONTROL. Three synthetic gates; the driver must tell"
    echo "=== them apart. If A and B score the same, this driver is blind."
    echo
    run_gate ctrl_A_eight_in_ok_vocabulary   0 8 "" bash "$d/eight.sh"
    run_gate ctrl_B_asserts_nothing          0 0 "" bash "$d/nothing.sh"
    run_gate ctrl_C_summary_contradicts_body 0 0 "" bash "$d/liar.sh"
    run_gate ctrl_D_lost_an_assertion        0 8 "" bash "$d/shrunk.sh"

    local vA vB vC vD
    vA="$(printf "$VERDICTS" | awk '$1=="ctrl_A_eight_in_ok_vocabulary"{print $2" "$3}')"
    vB="$(printf "$VERDICTS" | awk '$1=="ctrl_B_asserts_nothing"{print $2}')"
    vC="$(printf "$VERDICTS" | awk '$1=="ctrl_C_summary_contradicts_body"{print $2}')"
    vD="$(printf "$VERDICTS" | awk '$1=="ctrl_D_lost_an_assertion"{print $2}')"

    local bad=0
    echo "---- SELF-TEST ASSERTIONS"
    if [ "$vA" = "PASS 8/0" ]; then
        echo "  PASS  A: the eight-assertion gate in ok/FAIL vocabulary scored 8/0 GREEN"
        echo "        (the old driver scored this same gate 'PASS-lines: 0, FAIL-lines: 0')"
    else
        echo "  FAIL  A: expected 'PASS 8/0', got '$vA'"; bad=1
    fi
    if [ "$vB" = "UNSCORABLE" ]; then
        echo "  PASS  B: the gate that asserted nothing was REFUSED, not scored zero"
    else
        echo "  FAIL  B: expected UNSCORABLE, got '$vB'"; bad=1
    fi
    if [ "$vC" = "RED" ]; then
        echo "  PASS  C: a summary claiming 0 FAILED over a body with FAIL lines is RED"
    else
        echo "  FAIL  C: expected RED, got '$vC'"; bad=1
    fi
    if [ "$vD" = "RED" ]; then
        echo "  PASS  D: a gate that scored 3 where 8 are registered was caught LOSING assertions"
    else
        echo "  FAIL  D: expected RED, got '$vD'"; bad=1
    fi
    if [ "$vA" != "$vB" ]; then
        echo "  PASS  A and B are DISTINGUISHED ('$vA' vs '$vB') -- which is the whole point"
    else
        echo "  FAIL  A and B scored identically; this driver is as blind as the one it replaces"; bad=1
    fi
    echo
    if [ "$bad" = 0 ]; then
        echo "[release_gates --self-test] RESULT: 5 PASSED / 0 FAILED"
        rm -rf "$d"; exit 0
    fi
    echo "[release_gates --self-test] RESULT: 0 PASSED / 1 FAILED"
    exit 1
}

# =============================================================================
# MAIN
# =============================================================================
HOST_ONLY=0; WANT=""
for a in "$@"; do
    case "$a" in
        --list) registry | awk -F'|' '/^[^#]/ && NF {printf "%-32s qemu=%-3s allow_fail=%s\n", $1, $2, $3}'; exit 0 ;;
        --self-test) self_test ;;
        --host-only) HOST_ONLY=1 ;;
        -*) echo "unknown option: $a" >&2; exit 2 ;;
        *) WANT="$WANT $a" ;;
    esac
done

[ -n "$OUT" ] || OUT="$(mktemp -d)"
mkdir -p "$OUT"
echo "=== scripts/release_gates.sh   $(date -Iseconds)"
echo "=== tree:     $PROJ_ROOT  @ $(git rev-parse --short HEAD 2>/dev/null || echo '?')"
echo "=== artifact: ${IMG:-<none set: HAMLINUX_RELEASE_IMG>}"
echo "=== logs:     $OUT"
echo

[ -n "$SHA" ] && export HAMLINUX_SHIPPED_SHA="$SHA"

SKIPPED_QEMU=0
while IFS='|' read -r name qemu allow expect reason cmd; do
    case "$name" in ''|\#*) continue ;; esac
    if [ -n "$WANT" ]; then
        case " $WANT " in *" $name "*) ;; *) continue ;; esac
    fi
    if [ "$HOST_ONLY" = 1 ] && [ "$qemu" = yes ]; then
        echo "########## $name -- SKIPPED (--host-only, this gate boots QEMU)"
        echo "                 A SKIP IS NOT A PASS and is counted as such below."
        echo
        SKIPPED_QEMU=$((SKIPPED_QEMU+1)); continue
    fi
    case "$cmd" in
        *@IMG@*)
            if [ -z "$IMG" ]; then
                echo "########## $name -- CANNOT RUN: needs HAMLINUX_RELEASE_IMG"
                echo "                 NOT SCORED, NOT SKIPPED QUIETLY. The release is red."
                echo
                RED=$((RED+1)); UNSCORABLE=$((UNSCORABLE+1))
                VERDICTS="$VERDICTS$name NO-ARTIFACT\n"; continue
            fi
            cmd="${cmd//@IMG@/$IMG}" ;;
    esac
    # shellcheck disable=SC2086
    run_gate "$name" "$allow" "$expect" "$reason" $cmd
done < <(registry)

echo "==============================================================="
printf "$VERDICTS"
echo "---------------------------------------------------------------"
echo "GREEN: $GREEN   RED: $RED   (of which UNSCORABLE: $UNSCORABLE)"
echo "SKIPPED because --host-only: $SKIPPED_QEMU  -- a skip is not a pass"
echo "TOTAL ASSERTIONS ACTUALLY SCORED: $TOTAL_ASSERTED"
echo "==============================================================="
[ "$RED" -eq 0 ] && [ "$SKIPPED_QEMU" -eq 0 ] && [ "$GREEN" -gt 0 ] || exit 1
exit 0
