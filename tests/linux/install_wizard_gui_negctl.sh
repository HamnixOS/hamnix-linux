#!/usr/bin/env bash
#
# REGISTRATION, 2026-08-17. Until this date scripts/test_gate_registration.sh
# globbed only scripts/test_*.sh, so this directory was invisible to the gate
# against unregistered gates and every file in it read as coverage without
# being coverage. This gate is ON-DEMAND: not in ci_battery_manifest.txt
# because it was MEASURED on 2026-08-17 and did not finish inside the 400 s sweep timeout, which is more than the 12-way-sharded 50-minute battery can spend on one gate.
#
#
# tests/linux/install_wizard_gui_negctl.sh — THE NEGATIVE CONTROL FOR
# tests/linux/install_wizard_gui.sh, AND IT IS RUN RATHER THAN DESCRIBED.
#
# WHAT IT IS FOR, AND IT IS THE MIRROR OF WHAT IT USED TO BE
# ==========================================================
# THE ASSERTIONS THIS CONTROLS FOR HAVE INVERTED, SO THIS FILE HAS TOO, and the
# old shape is recorded here rather than deleted.
#
# WHEN IT WAS WRITTEN, install_wizard_gui.sh's two load-bearing assertions were
# both of the shape "the wizard did NOT do X" -- the disk page shows NO target
# and says so in red, and three more Returns do NOT move it past the disk page
# -- because `_enumerate_disks` listed only `/dev/blk` and a booted
# hamnix-linux machine has no `/dev/blk`. So this control PATCHED IN A FAKE
# DISK and required the gate to go RED.
#
# The wizard now falls back to `/sys/block` (the same source its own installer
# reads) and the disk page is selectable from the keyboard, so the gate's
# assertions are the positive ones: a disk IS offered, and Tab+Return DOES
# advance past step 5. A control that adds a disk would now make the gate
# GREENER, which controls nothing. The inversion has to go the other way.
#
# THE TWO ARMS
# ============
#   arm NODISK    `_enumerate_disks` is patched to return with n_disks = 0
#                 before it consults ANY source. The wizard must then show "No
#                 installable target disk detected", exactly as the unfixed
#                 tree did, and install_wizard_gui.sh MUST GO RED. This proves
#                 the "THE WIZARD OFFERS A TARGET DISK" pass is a reading and
#                 not a detector that always agrees -- and it re-runs, on
#                 demand, the precise failure the fallback was written for.
#
#   arm PRESELECT `sel_disk = 0` is set at the END of a normal enumeration, so
#                 a disk is offered AND already chosen. The gate's first
#                 assertion in that section -- "three Returns with NOTHING
#                 selected left the wizard on step 5" -- must then flip to
#                 "MOVED THE WIZARD PAST THE DISK PAGE". Without this arm, that
#                 refusal check could be green because Next never works at all.
#
# NOTHING ELSE CHANGES between the arms and the real run: same image build,
# same rc, same two blank targets, same keyboard drive, same OCR, same
# thresholds. The only difference is a few lines in one function, in a SCRATCH
# COPY OF THE FILE THAT IS RESTORED BY AN EXIT TRAP.
#
# THE EXPECTED RESULT IS FAILURE, in both arms. This script inverts the
# verdict: it passes when install_wizard_gui.sh FAILS on the patched tree.
#
# AS RUN: 7 PASSED, 0 FAILED
# ==========================
#   PASS  NODISK: install_wizard_gui.sh went RED, as it must
#   PASS  NODISK: the disk-page detector SAW the empty page and said so
#   PASS  NODISK: and the ADVANCE detector went red too
#   PASS  PRESELECT: install_wizard_gui.sh went RED, as it must
#   PASS  PRESELECT: the refusal detector flipped
# Kept at /home/david/.hamnix-build/soak-evidence/wizgui-negctl-RUN.log.
#
# THE RUN BEFORE THAT ONE WAS 4 PASSED / 3 FAILED, and both reds were faults
# in the INSTRUMENT, which is the whole reason this file exists:
#
#   * install_wizard_gui.sh's ADVANCE check was
#     `grep -qiE 'Review|Target disk|ERASED|Host name'`, and the disk page's
#     own empty-state message is "No installable target DISK detected." So it
#     matched a wizard that had not advanced at all. THE ASSERTION COULD NOT
#     FAIL, on its first run, and only this arm found it. Fixed by asking
#     "still on Step 5?" first, which the summary page can never satisfy.
#
#   * the PRESELECT inversion was a NO-OP. It appended
#     `if n_disks > 0: sel_disk = 0` to the end of _enumerate_disks; the text
#     went in and the wizard behaved exactly as unpatched. The arm reported
#     the refusal detector blind -- a claim about the instrument that the run
#     did not support, since nothing had ever been put to it. It patches the
#     DECLARATION now, and reports INCONCLUSIVE rather than a verdict if the
#     patched wizard still sits on step 5.
#
#     WHY THE OLD PATCH WAS INERT IS NOT ESTABLISHED. The obvious suspect --
#     that assigning a module global declared LATER in the file creates a
#     local instead -- was TESTED AND IS FALSE: a one-file Adder probe whose
#     function assigns and whose main reads printed the global's new value.
#     Left as unexplained rather than guessed at.
#
# WHAT IS STILL NOT CONTROLLED FOR, said rather than left out: the
# BOOT-MEDIUM-EXCLUSION check. Inverting it means seeding a fake disk whose
# name equals the running root's, which is not known until the guest boots, so
# there is no static patch for it. That assertion rests on the /proc/self/
# mountinfo derivation in the gate agreeing with the wizard's own, and is
# weaker than the two above.
#
# Usage: tests/linux/install_wizard_gui_negctl.sh
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

UI=user/haminstallui.ad
BACKUP="$(mktemp --tmpdir haminstallui.orig.XXXXXX.ad)"
WORK="${HAMLINUX_WIZGUI_NEG_WORK:-$HOME/.hamnix-build/install-wizard-gui-neg}"
mkdir -p "$WORK"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  PASS  %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$*"; }
say()  { printf '\n== %s\n' "$*"; }
info() { printf '  ..    %s\n' "$*"; }

cp "$UI" "$BACKUP"
restore() {
    cp "$BACKUP" "$UI"
    rm -f "$BACKUP"
    printf '  ..    %s restored from %s\n' "$UI" "$BACKUP"
}
trap restore EXIT

# patch_ui <mode>
#   nodisk     return with n_disks = 0 before any source is consulted
#   preselect  enumerate normally, then set sel_disk = 0
patch_ui() {
    local mode="$1"
    cp "$BACKUP" "$UI"
    python3 - "$UI" "$mode" <<'PY'
import sys
p, mode = sys.argv[1], sys.argv[2]
src = open(p).read()
if mode == "nodisk":
    # THE ANCHOR IS THE FUNCTION PROLOGUE, and it is asserted to appear
    # EXACTLY ONCE. A patch that matched nothing would silently re-run the
    # positive case and this file would report a control it never applied.
    anchor = ("def _enumerate_disks():\n    n_disks = 0\n"
              "    disks_from_sysblock = 0\n    _read_rootdev()\n")
    assert src.count(anchor) == 1, "the _enumerate_disks() prologue anchor is not there exactly once"
    body = ("    # ---- NEGATIVE CONTROL ONLY "
            "(tests/linux/install_wizard_gui_negctl.sh)\n"
            "    # Return before /dev/blk OR /sys/block is consulted, so the\n"
            "    # wizard offers nothing -- the exact state the unfixed tree\n"
            "    # was in. Restored by that script's EXIT trap.\n"
            "    return\n")
    out = src.replace(anchor, anchor + body)
elif mode == "preselect":
    # THE DECLARATION, NOT A STATEMENT INSIDE _enumerate_disks.
    #
    # The first spelling appended `if n_disks > 0: sel_disk = 0` to the end of
    # _enumerate_disks. The text went in (the guard below confirmed it) and
    # the wizard's behaviour DID NOT CHANGE: three Returns still sat on step
    # 5. Why was never established -- a one-file Adder probe ruled out the
    # obvious suspect, that assigning a global declared later in the file
    # makes a local instead (it does not; the probe printed the global's new
    # value). So that arm proved nothing and said so.
    #
    # Changing the INITIALISER cannot be a no-op in the same way: sel_disk is
    # 0 from the instant the program starts, before anything runs, and
    # _page_ready's disk-page test is exactly `sel_disk >= 0`.
    anchor = "sel_disk: int64 = -1"
    assert src.count(anchor) == 1, "the sel_disk declaration anchor is not there exactly once"
    out = src.replace(
        anchor,
        "sel_disk: int64 = 0   # ---- NEGATIVE CONTROL ONLY "
        "(tests/linux/install_wizard_gui_negctl.sh)")
else:
    raise SystemExit("unknown mode %r" % mode)
assert out != src, "the patch changed nothing"
open(p, "w").write(out)
print("patched %s" % mode)
PY
}

run_arm() {  # run_arm <name> <mode> <work> <why it must be red>
    local name="$1" mode="$2" w="$3" why="$4"
    mkdir -p "$w"
    say "arm $name -- patching _enumerate_disks ($mode)"
    patch_ui "$mode" || { bad "$name: could not patch $UI"; return 1; }
    grep -q 'NEGATIVE CONTROL ONLY' "$UI" \
        && ok "$name: the inversion is really in $UI (a rebuild will compile it)" \
        || { bad "$name: the patch is not in the file -- this arm would silently re-run the positive case"; return 1; }
    info "$name: running install_wizard_gui.sh against the PATCHED tree; expected RED"
    HAMLINUX_WIZGUI_WORK="$w" tests/linux/install_wizard_gui.sh >"$w/RUN.log" 2>&1
    ARM_RC=$?
    info "$name: install_wizard_gui.sh exited $ARM_RC"
    grep -aE '^  (PASS|FAIL)|^  \.\.    d[0-9]|^== ' "$w/RUN.log" | tail -n 40
    if [ "$ARM_RC" != 0 ]; then
        ok "$name: install_wizard_gui.sh went RED, as it must ($why)"
    else
        bad "$name: install_wizard_gui.sh PASSED with $mode applied -- $why, so IT CANNOT SEE THAT and its green run on the real tree means nothing"
    fi
}

# ---- arm NODISK: the wizard offers nothing at all --------------------------
run_arm NODISK nodisk "$WORK/nodisk" \
    "a wizard that offers no target must not pass a gate whose subject is that it offers one"
if grep -q 'STILL says it has no installable target' "$WORK/nodisk/RUN.log"; then
    ok "NODISK: the disk-page detector SAW the empty page and said so -- so 'THE WIZARD OFFERS A TARGET DISK' on the real tree is a reading, not a detector that always says yes"
else
    bad "NODISK: the gate did not report the empty disk page on a wizard that lists nothing -- THE DISK-PAGE DETECTOR IS BLIND and the real tree's green result means nothing"
    grep -aE 'OCR of the wizard window|Step 5|installab' "$WORK/nodisk/RUN.log" | head -8
fi
if grep -q 'either the disk page still has no keyboard selection' "$WORK/nodisk/RUN.log"; then
    ok "NODISK: and the ADVANCE detector went red too -- with nothing to select, Tab+Return cannot pass step 5, so the green advance on the real tree is not a page that advances unconditionally"
else
    bad "NODISK: the advance detector did NOT go red on a wizard with no disk to select -- it cannot tell advanced from stuck"
fi

# ---- arm PRESELECT: a disk is offered AND already chosen --------------------
run_arm PRESELECT preselect "$WORK/preselect" \
    "a disk page that is satisfied before the person touches it must not pass the refusal check"
# THREE OUTCOMES, NOT TWO, and the difference matters. "The detector is
# blind" and "the inversion never reached the running program" are different
# faults with different fixes, and the first spelling of this arm conflated
# them: it reported the detector blind when in fact the patched wizard had
# behaved exactly like the unpatched one. A control that cannot tell those
# apart is a control that can slander a working instrument.
#
# The separator is the arm's OWN disk page: with sel_disk preset, the FIRST of
# the three Returns must leave step 5. If the log still shows the wizard
# sitting on step 5 for all three, the wizard did not act preselected and the
# arm is INCONCLUSIVE, whatever the detector said.
if grep -qE 'MOVED THE WIZARD PAST THE DISK PAGE' "$WORK/preselect/RUN.log"; then
    ok "PRESELECT: the refusal detector flipped -- with sel_disk preset, Returns moved the wizard on, so 'three Returns with NOTHING selected left it on step 5' is a reading"
elif grep -qE 'after 3 more Returns \(nothing selected\).*Step 5' "$WORK/preselect/RUN.log"; then
    bad "PRESELECT INCONCLUSIVE, NOT A VERDICT ON THE DETECTOR: the patched wizard still sat on step 5 for all three Returns, i.e. it did not behave preselected at all. The inversion did not reach the running program, so this arm says NOTHING about whether the refusal check can fail. Do not read the real tree's green as proved by it"
    grep -aE 'after 3 more Returns|Review' "$WORK/preselect/RUN.log" | head -5
else
    bad "PRESELECT: the refusal detector did not flip on a wizard that advances without a choice -- it cannot tell refused from advanced"
    grep -aE 'after 3 more Returns|Review' "$WORK/preselect/RUN.log" | head -5
fi
if grep -qE 'DID appear in the census' "$WORK/preselect/RUN.log"; then
    ok "PRESELECT: and the spawn detector flipped -- /bin/install DID appear in the census, so '/bin/install NEVER APPEARED' elsewhere is a reading and not a grep that never matches"
else
    info "PRESELECT: /bin/install did not appear in the census on this arm -- the spawn detector is NOT proved by this run"
fi

say "what the patched wizard did once it had a target (printed, not asserted)"
grep -aE "console occurrences of|NVMe target|virtio-blk target" "$WORK/preselect/RUN.log" | head -12

printf '\n%d PASSED, %d FAILED\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
